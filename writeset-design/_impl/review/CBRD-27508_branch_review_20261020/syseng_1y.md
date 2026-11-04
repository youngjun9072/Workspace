# CBRD-27508 브랜치 리뷰: 시스템 엔지니어 1년차

## 1. 리뷰어 관점

- 운영자 입장에서 봤다. HA를 기동·정지·재시작·failover할 때 이 브랜치가 어떻게 동작하는지, 설정 파라미터가 기본값으로도 안전한지, 장애가 났을 때 에러 로그와 덤프만 보고 원인을 찾을 수 있는지, 메모리·스레드·연결·디스크를 얼마나 쓰는지를 중점으로 봤다.
- 코드를 처음 읽는 1년차 입장에서는 운영자가 직접 보게 되는 이름과 메시지(로그 태그, 종료 메시지, 파라미터 이름)가 코드 실제 동작과 맞는지를 함께 봤다.
- 근거 규칙: 모든 항목은 HEAD(0e411f10f) 기준 `파일:행`이다. 코드로 직접 따라가 확인한 것은 "확정", 동작 조건이나 규모를 실측하지 못한 것은 "추정"이라고 적었다. a9a0dc78d에 이미 있던 것은 "기존", 이 브랜치가 만든 것은 "신규"로 구분했다.

## 2. 검토 범위와 실제로 읽은 경로

범위는 `git diff a9a0dc78d 0e411f10f`(12 커밋)이다. 기준선과 비교할 때는 `git show a9a0dc78d:<path>`를 썼다.

| 영역 | 읽은 파일 / 함수 |
|---|---|
| 파라미터·에러 | `system_parameter.{c,h}`(ha_writeset_history_size, ha_writeset_trace_level, ha_apply_worker_count), `heartbeat.h`(HB_DEFAULT/MAX_APPLY_WORKER_COUNT), `error_code.h`, `msg/*/cubrid.msg`, `conf/cubrid_ha.conf`(템플릿 대조) |
| master writeset | `writeset.cpp` 전체(wset_push_hash, wset_add_write_key/ref_key, wset_find_dependency_in_range, wset_publish_with_capacity, wset_history_initialize/finalize, wset_raise_history_start), `writeset.hpp`, `writeset_types.hpp`, `writeset_history_map.{hpp,cpp}` |
| master 로그 | `log_manager.c` diff 전체(log_initialize_internal 재시작 경계, log_sysop_commit_internal, log_append_wset_label_*, log_commit_local, log_complete_for_2pc, log_dump_record, log_to_string), `log_append.cpp`, `log_record.hpp`(기준선 enum 대조), `log_recovery.c`, `log_tran_table.c`(logtb_clear_tdes, logtb_initialize_tdes, copy_to, define/undefine_trantable), `log_2pc.c`(log_2pc_recovery_analysis_record), `flashback.c`·CDC switch(기본 분기 확인) |
| master DML | `locator_sr.c` diff(locator_wset_collect_fk_ref, locator_add_or_remove_index_internal, locator_update_index, locator_is_inserter_committing, xlocator_repl_force), `btree.c`(btree_is_deleter_committing), `serial.c`, `replication.c` |
| slave applier | `log_applier.c`: 전역·구조체, la_coordinator_*(dispatch, cover_commit, collect/retire, wait_until_retired, wait_for_inflight_slot, wait_for_commit_order_slot, submit_task, process_sysop_end, set_commit_dependency, process_commit, store_apply_info_at_interval, commit_apply_info, exit), la_apply_worker_*(test hook 포함), la_init, la_shutdown, la_apply_log_file 본 루프 전체, la_change_state, la_log_commit, la_get_mem_size, la_check_mem_size, la_commit_transaction, la_lock/unlock_dbname, la_get_last_ha_applied_info, la_get/update_ha_apply_max_committed_lsa, la_find_required_lsa, la_remove_archive_logs, la_get_page_buffer, la_flush_repl_items, la_apply_repl_log, la_log_record_process, la_dump_la_info(필드 대조), `log_applier.h` |
| applier 모듈 | `applier/log_applier_worker.{hpp,cpp}` 전체, `log_applier_task_queue.cpp`, `log_applier_result_queue.cpp`, `log_applier_gate.cpp`, `log_applier_pending.cpp`, `log_applier_inflight.cpp`(에러 경로), `log_applier_task.hpp`, `log_applier_result.hpp`, `log_applier_debug.hpp` |
| 호출자 | `util_cs.c` applylogdb 재시도 루프(3547~3587), SIGUSR1 덤프(2839) |
| CS glue (caller만) | `CMakeLists.txt`, `cs/`·`sa/`·`cubrid/CMakeLists.txt`, `work_space.{c,h}`(ws_get_repl_obj_count), `file_io.c` diff, `db_admin.c` db_restart_sub 앞부분(sub_index 사용처와 반환값만) |
| 테스트 | `unit_tests/CMakeLists.txt`, `unit_tests/log_applier/*` TEST_CASE 목록 |

## 3. 발견 사항

### 3.1 에러

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| E1 | High | `log_applier.c:1038-1068`, `:1079-1109`, `applier/log_applier_result_queue.cpp:176-181`, `applier/log_applier_worker.cpp:378-392` | 워커가 모두 기동에 실패하면 coordinator가 결과 큐에서 영원히 대기한다 | `la_result_queue_pop`은 `while (count == 0 && la_Shared_result_shutdown == false) pthread_cond_wait(...)`로 기다린다. 결과 큐의 shutdown은 `la_stop_apply_workers`에서만 켜진다. 워커 기동 실패는 `request_shutdown()`, 즉 `la_applier_need_shutdown = true`만 설정한다 | 재시작 직후 복구 구간(recovery_boundary_lsa가 있음)에서 첫 commit이 `la_coordinator_submit_task`의 직렬 경로로 들어가 `la_coordinator_wait_until_retired`에 진입한다. 이때 `db_restart_sub`가 실패해(예: max_clients 소진) 워커가 0개가 되면 결과가 오지 않는다. coordinator는 cond_wait에서 깨어나지 못하고, SIGTERM 핸들러도 플래그만 바꾸므로 깨우지 못한다. 프로세스는 살아 있어 heartbeat가 재기동하지 않고, 복제는 에러 없이 멈춘다 | 확정(코드 경로). 트리거 빈도는 추정 | 신규 |
| E2 | High | `log_applier.c:10317-10357`, `:8418-8441`, `:7799` | failover 드레인 백스톱 타임아웃(30초)에 도달할 수 없다 | 같은 반복 안에서 10317의 `if (is_role_changed) la_unlock_dbname(..., clear_owner=true)`이 먼저 실행된다. `la_unlock_dbname`은 `la_Info.is_role_changed = false`로 되돌리고 60초 sleep한다. 그 뒤 10329의 `if (la_Info.is_role_changed == true && !drain_complete())`는 항상 거짓이다. is_role_changed는 `db_lockf_vdes != NULL`일 때만 true가 되므로(7792), 언락이 실패하지 않는 한 백스톱은 실행되지 않는다 | master DEAD로 failover가 시작됐는데 워커 하나가 slave에서 락 대기 등으로 멈추면, `la_change_state`가 DONE을 계속 보류(done_deferred)하고 백스톱도 동작하지 않는다. DONE이 보고되지 않아 승격이 끝나지 않고, 운영자에게는 "holds DONE" 알림 한 줄만 남는다 | 확정 | 신규 |
| E3 | High | `log_applier.c:8479-8495`, `:8095-8159`, `:8507-8511` | 워커 수가 늘면 VSZ 기준 메모리 검사가 기본 설정에서 오탐해 applylogdb가 종료·재기동을 반복한다 | `la_get_mem_size`는 `/proc/self/statm` 첫 필드(VSZ)를 읽는다. 상한은 `MAX(ha_apply_max_mem_size, start_vsize*2)`이고, start_vsize는 워커 시작 전(la_init)에 한 번만 잡힌다. 코드 주석이 직접 "with the default ha_apply_max_mem_size (500MB) the applier can falsely trip the over-limit shutdown"이라고 적고 TODO로 남겼다 | `ha_apply_worker_count=10`에 `ha_apply_max_mem_size`를 기본값으로 두면, 워커마다 malloc arena(약 64MB 예약)와 스레드 스택이 VSZ에 더해진다. 그러면 HB_START_WAITING_TIME 이후 `ER_HA_LA_EXCEED_MAX_MEM_SIZE`로 종료하고, 재기동 후 다시 같은 이유로 종료한다. 해결책(값 상향)은 코드 주석에만 있고 conf 템플릿이나 파라미터 기본값에는 반영되지 않았다 | 기전은 확정(코드와 주석). 크기 수치는 추정 | 신규(검사 자체는 기존, 오탐 조건이 신규) |
| E4 | High | `log_record.hpp:140`, 기준선 `log_record.hpp`(LOG_LARGER_LOGREC_TYPE=53), `log_applier.c:7837` | 새 로그 레코드 타입 번호 53이 구버전 applier의 상한값과 같아, 구버전 slave가 신버전 master 로그를 손상으로 판정한다 | 신규 `LOG_DUMMY_WSET_LABEL = 53`. 기준선에서는 `LOG_SUPPLEMENTAL_INFO = 52` 다음이 `LOG_LARGER_LOGREC_TYPE`(=53)이다. applier는 `lrec->type >= LOG_LARGER_LOGREC_TYPE`이면 `ER_HA_LA_INVALID_REPL_LOG_RECORD`와 `ER_LOG_PAGE_CORRUPTED`를 반환한다(기준선 6336행에도 같은 코드가 있다). master는 HA이면 모든 복제 commit 앞에 label을 쓰고, 버전·옵션 협상이 없다 | 롤링 업그레이드나 버전이 섞인 HA에서 master가 먼저 이 바이너리가 되면, 구버전 slave의 applylogdb는 첫 label에서 "log page corrupted"로 멈추고 재기동해도 같은 자리에서 다시 멈춘다 | 코드는 확정. 해당 버전 간 롤링 업그레이드 지원 여부는 추정 | 신규 |
| E5 | Medium | `schema_system_catalog_install.cpp:1095-1097`, `log_applier.c:2896-2898`, `:3351-3355`, `:9761-9769` | `db_ha_apply_info`에 컬럼 2개가 추가됐지만 기존 DB를 위한 마이그레이션이 없다 | 시작 시 `SELECT max_committed_lsa_pageid, max_committed_lsa_offset FROM db_ha_apply_info`를 실행하고, 실패하면 `"Failed to initialize _db_ha_apply_info"`로 종료한다. `git grep`으로 찾은 컬럼 사용처는 이 두 파일뿐이다 | develop으로 만든 기존 slave DB에 이 바이너리를 올리면 applylogdb가 시작할 때마다 SELECT에 실패해 종료하고 재기동을 반복한다. slave DB를 다시 만들어야 한다 | 확정 | 신규 |
| E6 | Medium | `applier/log_applier_worker.cpp:249-254`, `:357-361`, `log_applier.c:7645-7649`, `util_cs.c:3573-3587` | 워커가 flush 오류나 서버 다운을 만나면 applylogdb의 프로세스 내 재접속 재시도가 꺼진다 | 워커는 flush·server-down 오류에서 `request_shutdown()`(=`la_applier_need_shutdown = true`)을 호출한다. coordinator도 submit 실패 시 같은 플래그를 켠다. util_cs는 `if (!la_force_shutdown () && (ER_IS_SERVER_DOWN_ERROR ... ER_LC_PARTIALLY_FAILED_TO_FLUSH)) goto retry`인데, 이 플래그가 켜져 있으면 재시도 분기로 가지 못한다. 기준선의 flush·server-down 경로는 이 플래그를 켜지 않는다 | slave cub_server가 재시작되면 develop에서는 applylogdb가 1, 2, 4, 8초 백오프로 같은 프로세스에서 재접속했다. 이 브랜치에서는 워커가 먼저 오류를 보면 프로세스가 종료되고 heartbeat 재기동을 기다려야 한다. coordinator와 워커 중 누가 먼저 오류를 보느냐에 따라 결과가 달라진다. heartbeat 없이 수동으로 띄운 applylogdb는 그대로 죽는다 | 확정 | 신규 |
| E7 | Medium | `log_applier.c:1400-1401`, `:1430-1456` | 테스트 전용 지연 훅이 release 빌드에도 남아 있고, 매 commit마다 getenv를 호출한다 | `getenv ("CUBRID_HA_TEST_BLOCK_CLASS")`가 마지막에 적용한 클래스와 같으면 `usleep (block_msec*1000)`(기본 60000ms)을 수행한다. 코드에 "Kept in release builds"라는 TODO가 있다 | 테스트 스크립트에서 남은 환경변수가 cubrid 계정 프로파일에 설정돼 있으면, 해당 테이블 commit마다 워커가 60초씩 멈춘다. 복제 지연이 원인 불명으로 보이고, 남는 단서는 `ws_marker TEST` debug 줄뿐이다 | 확정 | 신규 |
| E8 | Medium | `log_tran_table.c:1621-1622`, `writeset.cpp:520-532`, `:559` | 트랜잭션이 끝난 뒤에도 writeset 벡터의 용량이 tdes 슬롯마다 남는다 | `logtb_clear_tdes`는 `tdes->wset_hashes.clear ()`만 호출해 capacity가 그대로 남는다. 반면 fallback 경로는 `std::vector<>().swap()`으로 해제한다. 트랜잭션당 상한은 `history_size`(기본 1,000,000)이고, LOG_WSET_ENTRY는 24바이트다 | 배치가 한 트랜잭션에서 키 100만 개 가까이를 수정하면 그 tdes 슬롯에 약 24MB가 남는다. 동시 배치 세션이 많으면 cub_server 메모리가 슬롯 수에 비례해 줄어들지 않는다 | 보존은 확정. 규모는 추정 | 신규 |
| E9 | Medium | `log_applier.c:2270-2290`, `:9901-9943` | 로그 페이지 디스크 읽기와 아카이브 삭제(unlink)를 공유 캐시 mutex 하나 안에서 수행한다 | `la_get_page_buffer`는 `pthread_mutex_lock (&cache_pb->mutex)` 안에서 `la_cache_buffer_replace`를 통해 `la_log_fetch`(디스크 읽기)를 호출한다. 본 루프는 같은 mutex 안에서 `la_remove_archive_logs`(`fileio_unformat`)를 수행한다 | 백로그를 따라잡느라 아카이브를 읽는 중이거나, `remove_log_archives_interval=0`에서 아카이브를 여러 개 한꺼번에 지우면, 모든 워커와 coordinator가 그 I/O가 끝날 때까지 페이지를 얻지 못한다. 병렬 적용이 주기적으로 멈추는 것처럼 보인다 | 락 범위는 확정. 성능 영향은 추정 | 신규 |
| E10 | Low | `log_manager.c:7347-7471` | `cubrid diagdb` 로그 덤프가 label 레코드를 모른다 | `log_dump_record` switch에 `LOG_DUMMY_WSET_LABEL` case가 없어 default 분기에서 `"log_dump: Unknown record type = 53"`을 출력한다. `log_to_string`에는 추가됐다 | HA master 로그를 덤프하면 복제 commit마다 "Unknown record type" 줄이 나온다. 운영자가 손상으로 오해하기 쉽고, label 내용(dependency)도 볼 수 없다 | 확정 | 신규 |
| E11 | Low | `log_2pc.c:2341-2349` | 2PC 복구 분석 switch에 label case가 없다 | `log_2pc_recovery_analysis_record`는 모르는 타입을 만나면 `ER_LOG_PAGE_CORRUPTED`를 반환하고, 호출자는 체인 탐색을 멈춘다. label은 `log_complete_for_2pc`에서 commit 바로 앞, 해당 트랜잭션 체인 위에 기록된다 | checkpoint에 잡힌 2PC 트랜잭션의 tail이 label이면(label 이후 commit 이전), 재시작 분석이 gtrid·coordinator 정보를 찾기 전에 탐색을 중단한다 | case 누락은 확정. 도달 조건과 결과는 추정 | 신규 |

#### 상세

- **E1**: `la_coordinator_wait_for_commit_order_slot`(736-761)은 `la_applier_need_shutdown`을 확인하지만, `wait_until_retired`와 `wait_for_inflight_slot`은 확인하지 않는다. 워커가 하나라도 살아 있으면 결과가 오므로 문제가 없다. 문제는 "워커 0개" 상태이고, 이 상태는 `la_worker_startup_failed`가 `remaining <= 0`일 때만 만든다(388-391). 수정 방향은 두 가지다. 마지막 워커가 빠질 때 `la_result_queue_signal_shutdown()`도 호출하거나, 두 대기 함수를 `la_result_queue_wait_for_result(100)` 기반 루프로 바꿔 shutdown 플래그를 확인하게 하는 것이다.
- **E2**: 백스톱의 의도는 "frontier가 30초 동안 움직이지 않으면 재시작"이다. 판단 조건을 `la_Info.done_deferred`(DONE을 보류 중이라는 플래그, 340행)로 바꾸면 의도대로 동작할 것으로 본다(추정). 지금 상태로는 DONE 보류가 끝나는 경로가 "drain 완료" 하나뿐이다.
- **E3**: 코드 주석이 대안(워커 시작 후 start_vsize 측정, RSS 기준)까지 적어 두었다. 운영자가 읽는 것은 conf와 매뉴얼이므로, 고치기 전까지는 `ha_apply_worker_count > 1`일 때 상한을 자동으로 보정하거나 시작 시 경고를 남겨야 한다.
- **E4**: 신규 타입 번호 자체는 피할 수 없다. 대신 master가 label을 쓸지를 파라미터로 선택하게 하거나, 업그레이드 순서(slave 먼저)를 릴리스 노트에 명시해야 한다. 반대 조합(구 master, 신 slave)은 label이 없는 commit을 "직전 commit 대기"로 처리하므로(`la_coordinator_set_commit_dependency` 7574-7578) 안전하다.
- **E6**: 워커가 의도적으로 "더는 task를 받지 않는다"는 것과 "프로세스 전체 shutdown 요청"을 같은 플래그로 표현한 것이 원인이다. 워커 오류는 결과 큐를 통해 coordinator에게만 알리고, `la_applier_need_shutdown`은 signal·치명 오류 전용으로 남기는 편이 기준선 재시도 의미와 맞는다.

### 3.2 모듈화

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| M1 | Medium | `writeset.cpp:520`, `:1208`, `:1226`, `system_parameter.c:5673-5683` | `ha_writeset_history_size` 하나가 전역 history 용량과 트랜잭션당 키 상한을 함께 정한다 | `if ((INT64) tdes->wset_hashes.size () >= wset_History.history_size)`(트랜잭션당 상한)와 `map.size () + publish_count <= history_size`(map 용량)가 같은 값을 쓴다 | 운영자가 master 메모리를 줄이려고 history_size를 10,000으로 낮추면, 1만 행을 넘게 수정하는 트랜잭션이 모두 commit-order fallback으로 바뀌고 history도 매번 비워진다. 결과적으로 병렬성이 사라진다. 이름만 봐서는 이 효과를 예상할 수 없다 | 확정 | 신규 |
| M2 | Low | `writeset.cpp:76`, `:465`, `log_applier.c:866` 외 다수, `:1508` | trace level을 세 가지 방식으로 읽는다 | writeset은 정적 변수 `wset_Trace_level`에 캐시하고, log_manager·serial·applier coordinator는 매번 `prm_get_integer_value`를 호출하며, 워커는 `config.trace_level` 복사본을 쓴다 | 지금은 파라미터가 동적 변경 불가라 결과가 같다. 나중에 동적 파라미터로 바꾸면 일부 모듈만 새 값을 따르게 된다 | 확정 | 신규 |
| M3 | Low | `log_manager.c:4001-4011`, `:4019-4029`, `:4772-4783`(SYSOP_END_ABORT trace 경로) | 복제 항목 개수를 세는 같은 루프가 세 번 반복된다 | `repl_type == LOG_REPLICATION_DATA \|\| ...STATEMENT && must_flush == LOG_REPL_NEED_FLUSH` 루프가 그대로 복사돼 있다 | 조건이 바뀌면 세 곳을 모두 고쳐야 하고, 하나를 빠뜨리면 trace 수치만 틀어진다 | 확정 | 신규 |
| M4 | Low | `log_applier.c:1207-1222` | 저장 주기 상태를 함수 안 static에 둔다 | `static UINT64 last_store_ns = 0;` | la_apply_log_file이 재시도로 다시 들어와도 값이 초기화되지 않아 첫 저장이 지연될 수 있다. 영향은 작다 | 확정 | 신규 |

### 3.3 아키텍처

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| A1 | Medium | `log_manager.c:5602-5606`, `locator_sr.c:7978-7979`, `:13194-13203`, `btree.c:27209-27223`, `log_applier.c:8499-8505`, `:9831` | 문제가 생겼을 때 기존 동작으로 되돌릴 kill switch가 없다 | master는 `log_does_allow_replication()`이면 키 수집, history publish, label 기록, inserter·deleter commit 대기를 항상 수행한다(`ha_writeset_history_size` 최솟값 1). slave는 `ha_apply_worker_count=1`(기본값)이어도 coordinator, 워커 스레드, `db_restart_sub` 서브 연결로 구성된 새 경로를 탄다 | 운영 중 writeset 관련 문제(예: 새 대기로 master DML 지연, E1·E2 같은 정지)가 생겨도 파라미터로 develop 방식으로 돌아갈 수 없다. 바이너리를 롤백해야 한다 | 확정 | 신규 |
| A2 | Medium | `CMakeLists.txt:607` | `MULTI_CONN_TO_A_SERVER`를 최상위에서 전역으로 켰다 | `add_definitions(-DMULTI_CONN_TO_A_SERVER)`. applylogdb 한 유틸리티에 필요한 기능 때문에 cs 라이브러리를 쓰는 모든 클라이언트(csql, CAS, 각종 유틸리티)의 컴파일 조건이 바뀐다 | applier와 무관한 클라이언트 경로에서 회귀가 생기면 원인 범위가 클라이언트 전체로 넓어진다 | 범위는 확정. 회귀 여부는 추정 | 신규 |
| A3 | Medium | `writeset.cpp:667-681`, `locator_sr.c:7768`, `:8036-8072`, `serial.c:1238-1241` | 복제용 키 생성에 실패하면 사용자 DML을 실패시킨다 | "Every technical failure is returned to the DML path". `ER_HA_WRITESET_KEY_BUILD_FAILED`, 캐스트 오류, OOM을 `goto error`로 처리한다. 같은 파일에 `wset_fallback_to_commit_order`라는 안전한 대안이 이미 있다 | master에서 FK 캐스트나 composite domain 문제로 키 생성이 실패하면, HA가 아니었다면 성공했을 사용자 INSERT·UPDATE가 에러로 끝난다. 복제 보조 기능이 가용성을 떨어뜨리는 방향이다. OOM은 실패가 맞지만, 그 밖의 오류는 commit-order fallback 후 에러 로그를 남기는 편이 운영상 낫다 | 설계는 확정. 발생 빈도는 추정 | 신규 |
| A4 | Medium | `writeset.cpp:60-70`, `:1255-1258`, `:1326-1331` | master writeset 통계가 노출되지 않는다 | `/* TODO(CBRD-27508): expose these process-local counters ... */ static wset_statistics wset_Statistics;`. overflow, history clear, fallback 건수는 `WSET_TRACE(1, ...)`에서만 보이고, 기본 trace level은 0이다 | 대형 배치나 statement 복제로 fallback·clear가 잦아져 slave 병렬성이 사라져도, 운영자는 master 쪽 원인을 볼 방법이 없다. slave 지연만 보인다 | 확정 | 신규 |
| A5 | Medium | `log_applier.c:10589-10845`(la_dump_la_info), `:1189`, `:5990-5996`, `:319` | slave의 새 상태가 진단 수단(SIGUSR1 덤프, applyinfo)에 나오지 않는다 | `la_dump_la_info`에는 worker_count, pending·inflight·gate frontier, max_committed_lsa, recovery_boundary_lsa, done_deferred가 하나도 없다. `recovery_skipped_counter`는 누적만 하고 저장·출력하지 않는다. 복구 구간에서 건너뛴 오류는 `er_log_debug`로만 남아 release 빌드에서는 보이지 않는다 | slave가 "parked 상태로 정지"(E1, E2, 미검증 U1)하면 운영자가 SIGUSR1 덤프를 떠도 원인이 나오지 않는다. 재시작 후 복구 구간에서 실제 불일치(중복 키, 행 없음)가 생겨도 흔적 없이 넘어간다 | 확정 | 신규 |
| A6 | Low | `applier/log_applier_worker.cpp:378-392` | 일부 워커만 기동에 실패하면 조용히 병렬도가 줄어든다 | ERROR 한 줄(`"%d of %d workers remain"`)만 남기고 계속 진행하며, 재시도는 없다 | 연결 한도 때문에 10개 중 3개만 뜨면, 운영자는 성능 저하의 원인을 에러 로그를 뒤져야만 알 수 있다 | 확정 | 신규 |
| A7 | Low | `log_applier.c:7606-7609` | replica 모드(`ha_replica_delay`, `ha_replica_time_bound`)를 지원하지 않는다는 사실이 TODO에만 있다 | TODO에 "ha_replica_delay delays more than configured ... Handle both before running the parallel applier on a replica"라고 적혀 있다. 그런데 replica일 때 워커 수를 1로 강제하거나 경고하는 코드가 없다 | replica에 worker_count>1을 설정하면 지연 시간이 설정값을 넘기고, time_bound에서 parked 트랜잭션이 남은 채 멈출 수 있다 | 코드는 확정. 영향 정도는 추정 | 신규 |

### 3.4 리팩토링

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| R1 | Low | `log_applier.c:434`, `:872`, `:1005`, `:1249`, `:1259`, `:7505-7638`, `:7764`, `:7819-7825`, `:9590` | 메인 스레드를 "reader"라고 부르는 이름이 운영자가 보는 메시지에 남아 있다 | 함수는 `la_coordinator_*`인데 trace 태그는 `"[WSET] reader schedule"` 등이고, release 에러 로그에 나가는 종료 알림도 `"applylogdb reader exit: reason=..."`이다 | 운영자가 에러 로그의 "reader"를 코드나 문서에서 찾으면 대응하는 개념이 없다. grep 기준도 둘로 나뉜다 | 확정 | 신규 |
| R2 | Low | `writeset.cpp:111`, `applier/log_applier_worker.cpp:257`, `log_applier.c:1452`, `:5994`, `:10258`, `applier/log_applier_gate.cpp`(ws_gate) | 로그 접두어가 통일돼 있지 않다 | `[WSET]`, `ws_worker`, `ws_marker TEST`, `ws_repl`, `ws_lsaguard`, `ws_gate`가 섞여 있다 | 장애 분석에서 `grep '\[WSET\]'` 하나로 전체 흐름을 볼 수 없다 | 확정 | 신규 |
| R3 | Low | `log_applier.c:6704-6705` | 드레인 타임아웃이 쓰는 곳에서 멀리 떨어진 하드코딩 상수다 | `#define LA_DRAIN_TIMEOUT_MSEC 30000`이 la_apply_schema_log 바로 앞(6705행)에 있고, 사용처는 10343행이다 | 큰 트랜잭션이 30초를 넘는 환경에서 조정할 수단이 없고, 읽는 사람이 정의를 찾기 어렵다. E2를 고치면 이 값이 실제로 동작하게 되므로 파라미터화를 검토해야 한다 | 확정 | 신규 |
| R4 | Low | `applier/log_applier_pending.cpp`(la_pending_pop_ready), `log_applier.c:709-725` | parked 목록을 매번 머리부터 선형 탐색한다 | `la_coordinator_drain_ready`가 `la_pending_pop_ready`를 반복 호출하고, 매 호출이 head부터 `la_gate_is_satisfied`를 확인한다 | parked가 수만 건(최대 worker_count×1024)일 때 결과를 한 번 수집할 때마다 O(n²) 탐색이 일어나 coordinator CPU가 치솟는다 | 복잡도는 확정. 실측 영향은 추정 | 신규 |
| R5 | Low | `conf/cubrid_ha.conf` | 새 파라미터 3개가 conf 템플릿에 없다 | 템플릿에는 `#ha_apply_max_mem_size=300` 등이 있지만 `ha_apply_worker_count`, `ha_writeset_history_size`, `ha_writeset_trace_level`은 없다 | 운영자가 병렬 적용을 켜는 방법이나 E3 회피값을 conf에서 알 수 없다 | 확정 | 신규 |
| R6 | Low | `log_applier.c:8479-8494` | 운영 회피책이 코드 주석에만 있다 | "Operational workaround: set ha_apply_max_mem_size large enough ..." | E3과 같다. 운영 지식이 소스에만 남는다 | 확정 | 신규 |

## 4. 미검증 의심 (근거가 부족해 확정하지 못한 것)

- **U1. master 재시작 직후 slave가 멈출 가능성.** master는 재시작 시 `wset_raise_history_start (append_lsa)`(`log_manager.c:1510-1514`)를 호출하므로, 재시작 뒤 첫 label은 재시작 시점 LSA R 이상이다. slave의 `la_gate_is_satisfied`는 `dep <= frontier`이고, frontier는 완료된 commit LSA로만 움직인다(`log_applier_gate.cpp`). 재시작 뒤 첫 label 붙은 commit C1(> R)이 통과하려면, R 이상이면서 label이 없는 빈 commit(예: 상대 노드 applier의 apply-info 갱신)이 먼저 완료돼야 하는 것으로 읽힌다. 그런 commit이 없으면 모든 commit이 parked 상태로 남고, ring이 가득 차면 coordinator가 멈출 수 있다. mutual HA에서는 상대 applier의 갱신 commit 덕분에 풀릴 것으로 추정한다. 재시작 직후 실측으로 확인이 필요하다.
- **U2. 워커 에러 컨텍스트 이중 등록.** `la_worker_main`은 `new cuberr::context()`를 `register_thread_local`한 뒤 `db_restart_sub`를 호출하는데, `db_restart_sub`도 `er_init_sub_client_context ()`로 컨텍스트를 만든다(`db_admin.c:1142`). 소유권이 겹치는지 CS 내부라 따라가지 않았다.
- **U3. 연결 수 소모.** applylogdb 하나가 최대 33개 연결(coordinator 1개와 워커 32개)을 쓴다. slave의 `max_clients` 산정이나 운영 가이드에 반영됐는지 확인하지 못했다. 한도를 넘으면 A6처럼 조용히 병렬도가 줄거나, 모두 실패하면 E1로 이어진다.
- **U4. failover 시 60초 sleep과 parked 작업.** `la_unlock_dbname (clear_owner=true)`의 60초 sleep(기존 동작) 동안 coordinator는 결과를 수집하지 않으므로 parked 작업이 진행되지 않는다. DONE까지 걸리는 시간이 develop보다 늘어나는지 측정하지 않았다.
- **U5. HA가 아닌 서버의 동작 변화.** `log_commit_local`의 retain_lock 분기에서 `lock_unlock_transaction_mvccid`를 호출하는 코드(`log_manager.c:5617-5623`)는 복제 여부와 무관하게 실행된다. HA가 아닌 환경에서 retain_lock 세션의 동작이 바뀌는지는 sysdev 리뷰 범위로 넘긴다.
- **U6. trace level 3의 데이터 노출과 로그 양.** `wset_trace_collected_key`가 키 값을 `db_sprint_value`로 에러 로그에 쓴다(`writeset.cpp:151-174`). 모든 키 수집이 전역 `er_Log_file_mutex`를 거치므로, 운영 중에 켜면 master 처리량이 떨어지고 에러 로그 회전 때문에 다른 에러가 밀려날 수 있다(추정).
- **U7. master 기본 메모리.** history map 기본 100만 항목(TBB 노드 오버헤드 포함 수십 MB로 추정)이 HA master마다 항상 할당된다. 실측하지 않았다.

## 5. 총평

등급별 건수: Critical 0 / High 4 / Medium 11 / Low 13 (미검증 7건 별도)

운영 관점에서 이 브랜치의 약점은 정상 경로보다 **멈춤·재시작·업그레이드 경로**에 몰려 있다. 정상 경로에서는 coordinator와 worker 사이 큐와 gate가 자료구조 단위 테스트와 trace를 갖추고 있어 따라가기 쉽다. 반면 다음 경로는 운영자가 개입할 수단이 부족하다.

- 워커가 0개가 되는 경우(E1)
- failover에서 DONE을 보류하는 경우(E2)
- 워커 수에 비례해 늘어나는 VSZ(E3)
- 버전이 섞이거나 기존 DB 위에 올리는 경우(E4, E5)
- 서버 재시작 시 재접속 의미가 바뀐 것(E6)

이 경우들은 모두 "프로세스는 살아 있는데 복제가 멈춤" 또는 "재기동 반복"으로 나타나는데, SIGUSR1 덤프와 applyinfo에 새 상태가 없고(A5), master 통계도 노출되지 않아(A4) 원인을 현장에서 찾기 어렵다. 기본값으로 되돌릴 kill switch가 없다는 점(A1)은 이 위험을 키운다.

정식 반영 전에 우선할 일은 세 가지로 본다.

1. E1과 E2를 고친다. 결과 대기에 shutdown과 타임아웃을 넣고, 백스톱 조건을 done_deferred 기준으로 바꾼다.
2. E3·E4·E5의 운영 가이드와 호환성 대책(메모리 상한 보정, label 기록 on/off, catalog 마이그레이션)을 정한다.
3. 진단 덤프에 gate·pending·inflight·worker 상태와 recovery_skipped_counter를 넣는다.

명명(R1, R2)과 conf 템플릿(R5)은 작업량은 작지만, 운영자가 처음 보는 접점이므로 함께 정리하는 것이 좋다.
