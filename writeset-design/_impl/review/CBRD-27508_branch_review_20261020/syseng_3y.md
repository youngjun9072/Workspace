# CBRD-27508 브랜치 리뷰: 시스템 엔지니어 3년차

## 1. 리뷰어 관점

운영자 입장에서 봤다. HA를 기동·정지·재시작·failover 할 때 이 브랜치가 어떻게 동작하는지, 새로 생긴 설정 파라미터와 기본값이 운영에서 위험하지 않은지, 장애가 났을 때 error log와 applyinfo/SIGUSR1 덤프로 원인을 추적할 수 있는지, 메모리·스레드·디스크(copylog 아카이브)를 어떻게 쓰는지를 중점으로 봤다.
3년차 관점에서는 함수 단위로 에러 처리가 빠진 곳, 같은 일을 하는 경로가 두 벌인 곳, develop과 동작이 달라진 곳을 하나씩 develop(`a9a0dc78d`)과 대조했다.

## 2. 검토 범위와 실제로 읽은 경로

- 범위: `git diff a9a0dc78d 0e411f10f` (HEAD = `0e411f10f`). 기준선은 `git show a9a0dc78d:<path>`로 대조했다.
- 정밀하게 읽은 곳
  - `src/transaction/log_applier.c`
    - coordinator: `la_coordinator_*` 전체(drain_ready, wait_for_commit_order_slot, cover_commit, dispatch_task, collect/record/retire, complete_without_task, wait_until_retired, wait_for_inflight_slot, release_apply_slot, advance_committed_lsa, add_result_stats, store_apply_info_at_interval, submit_task, process_sysop_end, set_commit_dependency, process_commit, commit_apply_info, init_resources, exit)
    - worker 콜백: `la_apply_worker_run_task`, `la_apply_worker_flush_task`, `la_apply_worker_commit_task`, `la_apply_worker_test_block_before_commit`
    - 주 루프와 수명: `la_apply_log_file`, `la_init`, `la_shutdown`, `la_start_apply_workers`, `la_stop_apply_workers`
    - 상태와 apply info: `la_change_state`, `la_log_commit`, `la_check_time_commit`, `la_check_mem_size`, `la_commit_transaction`, `la_lock_dbname`, `la_unlock_dbname`, `la_find_required_lsa`, `la_remove_archive_logs`, `la_get/update_ha_apply_max_committed_lsa`, `la_get_last_ha_applied_info`, `la_update_ha_last_applied_info`
    - 로그 읽기와 적용: `la_log_record_process`, `la_get_wset_label`, `la_apply_repl_log`, `la_flush_repl_items`, `la_apply_statement_log`, `la_get_next_repl_item_from_log`, `la_detach_sysop_fragment`
    - 페이지 캐시: `la_get_page_buffer`, `la_get_page`, `la_release_*`, `la_invalidate_page_buffer`, `la_decache_page_buffers`, `la_log_fetch`, `la_cache_buffer_replace`
    - 관측: `la_dump_la_info`
  - `src/transaction/applier/*`: worker, task_queue, result_queue, inflight, gate, pending, result/task/debug 헤더
  - `src/transaction/writeset.{cpp,hpp}`, `writeset_types.hpp`, `writeset_history_map.{cpp,hpp}`
  - `src/transaction/log_manager.c`: commit, sysop, label append, restart 경계, `log_dump_record`, `cdc_log_extract`
  - `log_record.hpp`, `log_impl.h`, `log_append.cpp`, `log_recovery.c`, `log_tran_table.c`, `replication.c`, `serial.c`, `btree.c`(deleter 대기 부분), `locator_sr.c`(writeset 수집 진입부)
  - `system_parameter.{c,h}`, `heartbeat.h`, `error_code.h`, `cubrid.msg`
- 호출부만 본 곳(CS 쪽)
  - `CMakeLists.txt`, `cs/sa/cubrid CMakeLists`, `work_space.{c,h}`, `file_io.c` diff
  - `db_restart_sub`의 계약 주석. 내부 구현은 보지 않았다.
  - `util_cs.c` applylogdb 진입과 재시도 루프
  - `log_applier_sql_log.c`의 `sl_write_sql`(SQL 로깅 경로라서 읽었다)
  - `schema_system_catalog_install*.cpp`(`_db_ha_apply_info`, `db_ha_apply_info` 뷰)
  - `server_support.c` `css_change_ha_server_state`(DONE 대기)

## 3. 발견 사항

### 3.1 에러

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| E1 | High | log_applier.c:9817-9824, 8388-8415, 10317-10322, 9969-9976 | dbname 락을 기동할 때 한 번만 잡고, 풀린 뒤에는 다시 잡지 않는다. role change 때는 drain 없이 락을 놓는다 | `/* Take the dbname lock here, once ... */ la_lock_dbname(...)`. develop은 `la_apply_repl_log`가 트랜잭션마다 `la_lock_dbname` 호출 | ① 3노드나 replica처럼 applylogdb가 둘 이상인 노드에서는 두 번째 applier가 main loop 전에 `while(1) LA_SLEEP(3)`에 무한 대기한다. SIGTERM도 무시하고 상태도 보고하지 않는다. ② 한 번 unlock한 applier는 락 없이 적용을 계속한다. failover나 failback 때 이전 peer applier의 tail이 아직 적용되는 중에 새 peer applier가 같은 DB에 동시에 적용할 수 있다 | 코드 확정, 데이터 역전은 추정 | 신규 |
| E2 | High | log_applier.c:1312-1322, 8267-8309, 8077, 9054-9062 | `la_Info.total_rows`를 아무도 갱신하지 않아서 주기적인 `la_log_commit`이 사라졌다. 그래서 required_lsa, append/eof, log_commit_time이 갱신되지 않는다 | worker는 지역 변수 `int total_rows = 0`에만 더한다. develop은 `&la_Info.total_rows`를 넘겼다. `la_find_required_lsa`는 `la_log_commit`에서만 호출된다 | 동시 트랜잭션이 끊이지 않는 부하에서는 HA_SERVER_STATE 시점의 `la_is_repl_lists_empty()`도 거의 false라서 required_lsa가 오래된 값으로 남는다. `la_remove_archive_logs`가 required 아카이브 이후를 지우지 못해 slave의 copylog 디스크가 계속 늘고, 재기동하면 오래된 required_lsa부터 다시 읽는다 | 경로 누락은 확정, 발생 빈도는 추정 | 신규 |
| E3 | High | log_applier.c:6196-6202, 6380-6383, 6848-6859 / log_applier_sql_log.c `sl_write_sql` | `ha_sql_logging=yes`에서 여러 worker가 thread-safe하지 않은 SQL logger를 동시에 부른다 | 전역 `log_fp`, `sl_Info.last_inserted_sql_id++`, 로테이션 때 `fclose(old_fp)`. 호출부에 mutex가 없다(`la_sql_compile_mutex`는 compile에만 쓴다) | worker 두 개가 동시에 쓰다가 한쪽이 파일을 로테이션하면 다른 쪽이 닫힌 FILE*에 fwrite한다. applylogdb가 크래시하거나 SQL 로그가 섞이고, 로그 순서도 commit 순서와 달라진다 | race는 확정, 크래시는 추정 | 신규 |
| E4 | High | log_applier.c:1038-1068, 1079-1109, 7384-7411 / result_queue.cpp:171-197 / worker.cpp:378-392 | `la_result_queue_pop`이 shutdown 플래그도 시간 제한도 없이 블록된다 | `while (count == 0 && la_Shared_result_shutdown == false) pthread_cond_wait`. 이 shutdown은 coordinator 자신의 `la_stop_apply_workers`만 세운다 | 재기동 직후 recovery range에서 coordinator가 task 하나를 넘기고 `wait_until_retired`로 기다리는 사이, 모든 worker가 기동에 실패한다(예: max_clients 초과). 그러면 결과가 영영 오지 않아 영구 hang에 빠진다. SIGTERM도 깨우지 못하고 프로세스는 살아 있으니 heartbeat가 재시작하지 않는다. 복제가 조용히 멈춘다 | 경로 확정, 발생 조건은 추정 | 신규 |
| E5 | High | schema_system_catalog_install.cpp:1096-1097 / log_applier.c:2896-2916, 3349-3353 | `_db_ha_apply_info`에 컬럼을 추가했지만 기존 DB용 마이그레이션도, 컬럼이 없을 때의 fallback도 없다 | SELECT/UPDATE `max_committed_lsa_*`가 실패하면 `res < 0` → `la_get_last_ha_applied_info` 에러 → "Failed to initialize _db_ha_apply_info" | 이 바이너리로 기존 slave DB를 띄우면 applylogdb가 기동하자마자 실패하고, heartbeat 재시작 루프에 빠진다. 코드 TODO(2956)도 카탈로그 변경을 없애는 안을 남겨 두었다. 저장소 전체를 grep했지만 마이그레이션 코드는 없다 | 확정(fallback 없음), 업그레이드 절차상 영향은 추정 | 신규 |
| E6 | High | log_record.hpp:140-142 / develop log_applier.c:6336 | 새 레코드 타입 53(`LOG_DUMMY_WSET_LABEL`)이 구 바이너리의 `LOG_LARGER_LOGREC_TYPE`(=53)과 값이 같다 | develop: `lrec->type >= LOG_LARGER_LOGREC_TYPE` → `ER_LOG_PAGE_CORRUPTED` | 롤링 업그레이드에서 master를 먼저 올리면, 구버전 slave와 replica의 applylogdb가 커밋마다 붙는 label을 보고 corrupted로 판단해 멈춘다. 이 바이너리가 쓴 로그를 구버전 도구로 읽을 때도 같다 | 메커니즘 확정, 혼합 버전 지원 정책은 추정 | 신규 |
| E7 | High | log_applier.c:10317-10358, 8435-8436, 7954-7974 | failover drain backstop(30초)이 사실상 실행되지 않는 코드다 | backstop 조건은 `is_role_changed == true`인데, 같은 반복의 10317에서 `la_unlock_dbname`이 먼저 `is_role_changed = false`로 리셋한다. DONE 보류(`la_change_state`)는 master 헤더 상태가 DEAD/STANDBY일 때도 걸리는데 이 경우는 is_role_changed와 무관하다 | master가 crash한 상태(DEAD)에서 worker 하나가 멈추면 DONE을 영원히 보류한다. slave 승격은 heartbeat의 force까지 대기하고 주석이 약속한 "restart"는 일어나지 않는다 | 실행되지 않음은 확정, 촉발 빈도는 추정 | 신규 |
| E8 | High | log_applier.c:8479-8511, 8124-8159 | worker 스레드 arena 때문에 VSZ 기반 메모리 검사가 오탐하는데, 운영 가드가 없다 | `start_vsize`를 worker 시작 전에 잡는다. `max(max_mem_size, start_vsize*2)`와 비교한다. 코드 주석이 오탐을 인정하고 TODO로 남겼다 | 기본값 `ha_apply_max_mem_size=500`에서 `ha_apply_worker_count`를 수 개 이상으로 올리면, 대기 중에도 기동 유예 시간이 지나면 `ER_HA_LA_EXCEED_MAX_MEM_SIZE`로 종료한다. 이후 재시작 루프가 돈다(재시작은 E9의 직렬 구간을 늘린다). 두 파라미터의 연관 검증이나 경고 로그가 없다 | 확정(저자 주석) | 신규 |
| E9 | Medium | log_applier.c:619-636, 1023-1028, 7378-7412 | recovery 상한을 `eof_lsa`로 저장해서, backlog 중에 재시작하면 남은 backlog 전체가 직렬로 적용된다 | `bound = max(commit_lsa, act_log.log_hdr->eof_lsa)`. range 안에서는 `wait_until_retired`로 한 건씩 처리한다 | slave를 1시간 정지한 뒤 기동하면 첫 dispatch가 상한을 backlog 끝으로 저장한다. 그 뒤 applylogdb가 재시작하면(E8, 서버 순단) 나머지 backlog를 worker 하나 속도로 적용해서 지연이 다시 쌓이고 failover 손실 창이 커진다 | 확정 | 신규 |
| E10 | Medium | log_applier_worker.cpp:140-170 / util_cs.c:3528 | worker 세션은 lock timeout을 -1로 설정하지 않는다. main 세션만 `db_set_lock_timeout(-1)`을 부른다 | `la_worker_start_session`: `db_restart_sub`, `tr_init`, `db_disable_trigger`만 호출 | cubrid.conf에 `lock_timeout`을 유한값으로 둔 사이트에서는 worker의 락 대기가 timeout → flush 에러 → applylogdb 재시작으로 이어진다. develop은 무한 대기였다 | 추정(sub-client가 이 값을 상속하는지는 내부 미확인) | 신규 |
| E11 | Medium | log_applier.c:1400-1456 | 테스트용 블록 hook이 release 빌드에 남아 있다 | 커밋마다 `getenv("CUBRID_HA_TEST_BLOCK_CLASS")`를 읽고, 일치하면 `usleep(60000ms)` | 운영 환경에 이 환경변수가 남아 있으면 해당 클래스의 커밋마다 60초씩 멈춘다. 지연이 폭증해도 원인은 debug 로그 한 줄뿐이다. TODO도 제거를 명시한다 | 확정 | 신규 |
| E12 | Medium | log_applier.c:4638-4666, 7815-7818, 7553-7560 | label 읽기가 실패하면 dependency가 NULL, 즉 가장 느슨한 값이 되고 로그도 남지 않는다 | `la_get_wset_label`이 에러일 때 `LSA_SET_NULL`로 return한 뒤에도 `la_wset_label_trid = trid`로 has_label=true가 된다 | label이 페이지 경계에 걸쳐 다음 페이지를 읽지 못하면, 그 commit은 선행 commit을 기다리지 않고 바로 dispatch된다. label이 아예 없을 때의 보수 규칙(직전 commit 대기)보다 오히려 느슨하다 | 코드 확정, 촉발 조건은 추정 | 신규 |
| E13 | Medium | log_applier.c:2275-2310, 2064-2118, 9901-9943 | 공유 페이지 캐시 mutex를 잡은 채 디스크 I/O, 100ms×5 sleep, 아카이브 삭제(unlink)를 한다 | `la_get_page_buffer`가 mutex 안에서 `la_cache_buffer_replace`→`la_log_fetch`(`usleep(100*1000)` 재시도)를 부른다. main loop도 mutex 안에서 `la_remove_archive_logs`를 부른다 | backlog를 아카이브에서 읽을 때나 대용량 아카이브를 삭제할 때 coordinator와 모든 worker가 한 mutex에 직렬화된다. 병렬화 효과가 줄고 지연이 튄다 | 확정 | 신규(캐시 공유로 생긴 문제) |
| E14 | Medium | log_tran_table.c:1621-1622, 1705-1706 / writeset.cpp:520 | `tdes->wset_hashes.clear()`는 capacity를 유지한다. 트랜잭션당 키 한도는 history_size(기본 100만)다 | `std::vector::clear`는 메모리를 반환하지 않는다. 엔트리는 24B | 한 번이라도 대량 DML을 돌린 tran index마다 최대 약 25MB를 서버가 끝날 때까지 쥐고 있다. 세션 수에 비례해 master RSS가 줄지 않는다 | 확정 | 신규 |
| E15 | Medium | writeset.cpp:1243-1259, 1289-1322 | history 전체 clear를 `seq_lock`과 쓰기 rwlock 아래에서 수행한다 | 각 overflow나 statement 복제 commit이 `wset_clear_overflow_history`→`map.clear()`(최대 100만 노드 해제)를 부른다 | statement 기반 DML이 잦거나 history가 자주 차는 워크로드에서는 clear할 때마다 master의 모든 commit이 probe/publish에서 막혀 commit 지연이 튄다 | 메커니즘 확정, 크기는 추정 | 신규 |
| E16 | Low | log_applier.c:4389-4392, 3940-3946, 445, 1519-1522 | 스레드 사이 데이터 race | worker가 `apply->num_items--`를 하는 동안 coordinator가 `la_is_repl_lists_empty`로 읽는다. `la_applier_need_shutdown`은 worker가 쓰고 coordinator가 읽는 plain bool이다 | 이론상 UB다. 현재는 int/bool이라 실해 가능성은 낮지만 TSAN이 경고하고, 컴파일러 최적화에 따라 shutdown 감지가 늦어질 수 있다 | 확정 | 신규 |
| E17 | Low | log_applier.c:8545-8548 / pending.cpp:143-155 | shutdown할 때 SYSOP fragment 슬롯(별도 malloc)이 누수된다 | `la_pending_clear`는 노드만 free하고, inflight와 task queue에 남은 fragment `LA_APPLY`도 해제하지 않는다 | `util_cs.c`의 server-down 재시도(`goto retry`)는 같은 프로세스에서 반복되므로, 재시도마다 메모리가 쌓인다 | 확정 | 신규 |
| E18 | Low | log_manager.c:7464-7469 | `log_dump_record`가 새 레코드 타입을 처리하지 않는다 | default로 빠져 "Unknown record type"을 출력하고 `LSA_SET_NULL(log_lsa)` | 진단용 log dump(diagdb)가 label마다 오류 문구를 찍고 페이지 루프를 끊는다. 출력이 오염되고 page 예산이 일찍 소진된다 | 확정 | 신규 |
| E19 | Low | log_applier.c:2312-2324 | pinned 목록(256)이 넘치면 그 fix는 영구히 풀리지 않고 release 빌드에서는 흔적도 없다 | `assert(false)` + `er_log_debug`(er_log_debug=no면 출력 안 됨) | 긴 트랜잭션이 페이지를 많이 걸치면 버퍼가 영구 고정되고 캐시가 계속 늘어난다(`la_expand_cache_log_buffer`는 줄이지 않는다). 결국 E8 메모리 검사에 걸릴 수 있다 | 확정 | 신규 |

**E1 상세.** develop에서 dbname 락은 "지금 실제로 적용하는 applier가 그 DB를 독점한다"는 표식이었다. 그래서 적용할 트랜잭션이 생길 때마다 `la_lock_dbname`을 불렀고, role change나 DONE 때 `clear_owner`로 놓으면 다음 적용 때 상대 applier가 가져갔다. HEAD는 workers가 `db_lockf_vdes`를 건드리지 않게 하려고 기동할 때 한 번만 잡는다(9817 주석).
그 결과 세 가지가 달라졌다.
1. 기동 순간 같은 노드의 applier 둘이 경쟁하고, 진 쪽은 main loop 전 무한 루프에 갇힌다. SIGTERM 확인도 상태 보고도 없다. 이긴 쪽이 standby peer의 applier라면 DONE→unlock(60초 sleep)까지 active peer의 복제가 지연된다.
2. 한 번 놓은 뒤에는 다시 잡지 않으므로 이후 적용은 락 없이 진행된다. `la_log_record_process`의 `is_role_changed` 감지(7792)도 `db_lockf_vdes != NULL_VOLDES` 조건이라, 이후 role change를 감지하지 못한다.
3. 10317의 unlock은 worker drain을 기다리지 않는다.

develop은 단일 스레드라 unlock 시점에 앞선 트랜잭션이 모두 적용된 상태였다. 지금은 dispatch된 tail이 남은 채로 락이 넘어간다. 개선 방향은 둘이다. worker가 아니라 coordinator가 dispatch 직전에 `la_lock_dbname`을 확인하게 하고, role change unlock 경로도 `la_coordinator_drain_complete()` 뒤로 미룬다.

**E2 상세.** 이 브랜치에서 apply info를 저장하는 경로는 두 개다. `la_coordinator_store_apply_info_at_interval`은 committed_lsa만 앞으로 옮겨 저장한다. required/append/eof는 `la_log_commit`에서만 계산하는데, 그 호출 조건인 `prev_total_rows != total_rows`가 늘 false다. `la_dump_la_info`의 total_rows도 항상 0으로 나와 SIGUSR1 덤프 해석을 오도한다. `la_Info.total_rows += total_rows`를 retire에서 합산하거나, interval 저장 경로에서 `la_find_required_lsa`와 헤더 LSA도 같이 갱신해야 한다(M1 참고).

**E4 상세.** 정상 경로의 `la_coordinator_wait_for_commit_order_slot`은 `la_applier_need_shutdown`을 확인하므로 빠져나온다. 문제는 `la_coordinator_wait_until_retired`와 `la_coordinator_wait_for_inflight_slot`이 `la_result_queue_pop`(무한 대기)을 쓴다는 점이다. 이 둘은 worker가 반드시 결과를 줄 것이라고 가정한다. 하지만 `la_worker_startup_failed`에서 마지막 worker가 빠져도 result queue를 깨우지 않는다. pop을 `la_result_queue_wait_for_result(timeout)` + `la_applier_need_shutdown` 확인 루프로 바꾸거나, live worker가 0이 되면 result queue shutdown을 신호해야 한다.

**E7 상세.** 10317-10322의 `if (la_Info.is_role_changed == true) la_unlock_dbname(...)` 다음에 오는 10329의 `if (la_Info.is_role_changed == true && !la_coordinator_drain_complete())`는 unlock이 실패할 때만 참이 된다. 그리고 drain을 보류하는 진짜 조건은 `la_Info.done_deferred`다. backstop 조건을 `la_Info.done_deferred`로 바꿔야 의도대로 master DEAD 경로까지 덮을 수 있다.

**E8 상세.** 주석에 해결 방향(RSS 기반 측정, 또는 worker 시작 뒤 start_vsize 측정)까지 적혀 있지만 운영 쪽 가드는 없다. 최소한 기동할 때 `worker_count`와 `max_mem_size`를 같이 찍고, 위험 조합이면 경고를 남겨야 한다. 사용자 운영 conf가 worker 10개에 4096으로 우회하고 있다는 점도 이 함정이 실재한다는 근거다.

**E9 상세.** 상한이 크면 재시작 뒤 직렬 구간도 커진다. 한 번 저장할 때 늘리는 폭을 commit_order_capacity 수준으로 제한하면 직렬 구간의 크기를 묶어 둘 수 있다. 다만 저장(=slave commit) 횟수가 늘어나므로 상호 HA의 빈 commit 핑퐁 조건(1207 주석)과 함께 검토해야 한다.

### 3.2 모듈화

| ID | 등급 | 위치(파일:행) | 내용 | 근거 | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| M1 | Medium | log_applier.c:1207-1222, 8235-8321, 8073-8090 | apply info 주기 저장 경로가 두 벌이고, 두 경로가 갱신하는 필드도 다르다 | `store_apply_info_at_interval`(고정 PRM 간격, committed만 갱신)과 `la_check_time_commit`(adaptive 간격, `la_log_commit`이 required/append/eof/commit_time 갱신) | E2의 근본 원인이다. 한쪽만 고치면 다른 쪽과 어긋난다 | 확정 | 신규 |
| M2 | Medium | log_applier.c:10588-10830 / task_queue.cpp:190-200 / result_queue.cpp:253-263 | SIGUSR1 상태 덤프(`la_dump_la_info`)에 병렬 상태가 없다. "status output용" 함수는 호출하는 곳이 없다 | `la_task_queue_get_count`, `la_result_queue_get_count` 호출 0건. worker 수와 live 수, pending, inflight, ring, frontier, recovery_boundary, max_committed를 출력하지 않는다 | 지연이 발생해도 운영자가 "worker가 막혔는지, gate가 막혔는지, log를 못 읽는지"를 구분할 수 없다. trace_level을 켜려면 재기동해야 한다(A4) | 확정 | 신규 |
| M3 | Low | log_applier.c:1038-1068, 1079-1109 | `wait_until_retired`와 `wait_for_inflight_slot`이 종료 조건만 다르고 본문이 같다 | pop → record → advance → retire 반복 | E4를 고칠 때 두 곳을 모두 고쳐야 한다 | 확정 | 신규 |
| M4 | Low | log_applier.c:9863-9892 | collect_and_retire 에러 분기가 중복이다 | `ER_TDE_CIPHER_IS_NOT_LOADED`와 `else`가 같은 처리(need_shutdown, break). `ER_HA_LA_EXCEED_MAX_MEM_SIZE`도 동일 | 가독성 저하, 분기 의미가 불명확 | 확정 | 신규 |
| M5 | Low | writeset.cpp:520, 1208, 1226 / system_parameter.c:5673-5682 | `ha_writeset_history_size` 하나가 "트랜잭션당 키 한도"와 "전역 map 용량" 두 의미를 함께 가진다 | `tdes->wset_hashes.size () >= wset_History.history_size` | 메모리를 줄이려고 값을 낮추면 큰 트랜잭션마다 fallback과 전체 clear(E15)가 늘어난다. 튜닝 방향이 서로 충돌한다 | 확정 | 신규 |
| M6 | Low | log_applier.c:7330-7331, 1210 | 프로세스 내 재시도(`goto retry`)를 거쳐도 static 상태가 리셋되지 않는다 | `la_wset_label_trid` holder, `last_store_ns`를 `la_init`에서 초기화하지 않는다 | 재시도 직후 이전 run의 label holder가 남아 있다. 로그를 required_lsa부터 다시 읽으므로 대개 덮어쓰이지만 보장되지는 않는다 | 확정(영향은 낮음) | 신규 |

**M2 상세.** 운영에서 가장 먼저 보는 것은 applyinfo와 SIGUSR1 덤프다. 그런데 병렬화 뒤에 생긴 단계(pending → inflight → ring)가 어디에도 보이지 않는다. `holds DONE` 알림(7964)은 좋은 예다. 같은 수준의 카운터를 덤프에도 넣으면 trace_level 없이도 1차 진단이 된다.

### 3.3 아키텍처

| ID | 등급 | 위치(파일:행) | 내용 | 근거 | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| A1 | Medium | CMakeLists.txt:607 | `MULTI_CONN_TO_A_SERVER`를 최상위에서 전역으로 켰다 | `add_definitions(-DMULTI_CONN_TO_A_SERVER)` | cubridcs를 쓰는 모든 클라이언트(CAS, csql, 유틸리티)의 빌드 구성이 바뀐다. applylogdb 하나 때문에 전 제품의 회귀 범위가 넓어진다. 대상만 `target_compile_definitions`로 좁히는 안을 검토해야 한다 | 플래그 범위는 확정, 영향은 추정 | 신규 |
| A2 | Medium | log_applier.c:7605-7617 | `ha_mode=replica`(delay, time bound) 미지원을 TODO로만 적었고 런타임 가드가 없다 | coordinator가 `la_delay_replica`에서 sleep하거나 `select(…NULL)` 무한 대기 | replica에서 worker를 2개 이상 쓰면 delay가 설정값보다 커지고, time bound에 걸리면 parked된 이전 commit이 적용되지 않은 채 멈춘다. 기동할 때 worker_count를 1로 강제하거나 거부해야 한다 | 확정 | 신규 |
| A3 | Medium | locator_sr.c:7978-7979, 8036-8058 / writeset.cpp:667-681 / system_parameter.c:5673-5682 | master writeset을 끌 스위치가 없고, 키 생성이 실패하면 사용자 DML이 실패한다 | 수집 조건은 `need_replication && log_does_allow_replication()`뿐이다. history_size 최소값은 1이다. `ER_HA_WRITESET_KEY_BUILD_FAILED`가 DML에 반환된다 | slave가 worker 1개(직렬)로 돌아도 master는 수집, publish, 커밋 대기(btree deleter/inserter 대기) 비용을 항상 낸다. writeset 버그가 생기면 설정으로 우회할 수 없고 애플리케이션 에러로 드러난다. 키 생성 실패는 commit-order fallback으로 낮추는 편이 가용성 면에서 안전하다 | 확정 | 신규 |
| A4 | Medium | writeset.cpp:69-70, 465 / system_parameter.c:5684-5694 / log_applier.c:1508 | 관측성이 부족하다: master 통계를 노출하지 않고, trace level은 동적으로 바꿀 수 없다 | `wset_Statistics` TODO. `PRM_CLEAR_DYNAMIC_FLAG`. 서버는 init 때, worker는 시작 때 trace level을 캐시한다 | master에서 fallback이나 history clear가 늘어 병렬도가 떨어져도 알 방법이 없다. 추적하려면 master 서버를 재기동해야 한다(운영 중단) | 확정 | 신규 |
| A5 | Low | log_applier.c:8501-8505 / worker.cpp:378-392 | 실제 worker 수를 기동 로그로 알 수 없다 | worker가 1개일 때만 notification을 남긴다. 일부 worker가 기동에 실패하면 "n of m remain"이 ERROR로 한 번만 찍힌다 | 설정이 반영됐는지, 병렬도가 줄었는지를 운영자가 사후에 확인하기 어렵다 | 확정 | 신규 |

### 3.4 리팩토링

| ID | 등급 | 위치(파일:행) | 내용 | 근거 | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| R1 | Low | log_applier.c:9590, 1249, 1259, 7638, 7764, 7819 등 | 로그에 "reader" 명칭이 남아 있고 prefix가 섞여 있다 | "applylogdb reader exit", "[WSET] reader …", "ws_repl", "ws_lsaguard", "ws_worker", "ws_marker" | error log를 grep하는 운영 스크립트가 일관된 키를 쓸 수 없다. 함수명(coordinator)과 로그 표기가 다르다 | 확정 | 신규 |
| R2 | Low | log_applier_result.hpp:63 / task_queue.cpp:139-141 / log_applier.c:1171-1173 | 주석이 서로 모순된다 | 결과 헤더는 committed_rep_lsa가 "restart point"라고 하고, task_queue는 "committed_rep_lsa stays behind… restart applies them again"이라고 한다. 반면 1171은 "not used to decide what to re-apply"라고 한다 | 재시작 지점을 오해하게 만든다 | 확정 | 신규 |
| R3 | Low | log_applier.c:10184-10185, 10264-10265, 10280-10283, 10297-10300 | exit 로그가 일관되지 않는다 | 일부 종료 경로만 `la_coordinator_exit`를 부른다. collect 실패는 9866과 10378에서 두 번 찍힌다 | release error log에서 종료 원인이 빠지거나 중복된다 | 확정 | 신규 |
| R4 | Low | log_applier.c:2996-3000 vs 3492-3504 | 0행 갱신 처리가 일관되지 않는다 | `la_update_ha_apply_max_committed_lsa`는 0행이면 실패한다. `la_update_ha_last_applied_info`는 행을 재삽입한다 | 운영자가 apply info 행을 지운 직후에는 cover 저장이 실패해 applylogdb가 재시작한다(재시작 뒤에는 회복된다) | 확정 | 신규 |
| R5 | Low | schema_system_catalog_install_query_spec.cpp:1435-1471 | `db_ha_apply_info` 뷰에 새 컬럼이 없다 | 뷰 SELECT 목록이 기존 26개 컬럼 그대로다 | 운영자가 뷰로는 recovery 상한(max_committed_lsa)을 볼 수 없다 | 확정 | 신규 |

## 4. 미검증 의심

- **worker의 헤더 비동기 읽기.** worker가 `la_get_next_repl_item_from_log`(7206)에서 `la_Info.act_log.log_hdr->eof_lsa`를 mutex 없이 읽는다. 같은 시각 coordinator는 mutex 아래에서 헤더를 제자리 갱신한다(`la_fetch_log_hdr`). 정렬된 8바이트 읽기라 실해 가능성은 낮지만 확인하지 못했다.
- **backlog 중 선읽기 메모리.** coordinator는 최대 `worker_count*1024`개의 "커밋됐지만 아직 적용되지 않은" 트랜잭션 item을 메모리에 들고 있을 수 있다. 큰 트랜잭션이 많은 backlog라면 E8과 별개로 실제 RSS가 늘어 `ER_HA_LA_EXCEED_MAX_MEM_SIZE`가 날 수 있다. 측정하지 않았다.
- **E1-①의 서버 상태 전이 영향.** 기동 때 락 루프에 갇힌 applier는 `boot_notify_ha_log_applier_state`를 한 번도 호출하지 않는다. 이것이 서버의 `css_check_ha_log_applier_working/done` 판정에 영향을 주는지(미등록 applier를 집계에서 빼는지)는 서버 등록 경로를 확인하지 못했다.
- **E10의 상속 여부.** `db_restart_sub`/`boot_restart_client_sub`가 main 클라이언트의 lock timeout(-1)을 상속하는지는 CS 내부라서 보지 않았다.
- **label 레코드의 로그량 영향.** 복제 대상 commit마다 label 레코드(헤더 + 8B)가 하나씩 늘어난다. 소형 트랜잭션 위주라면 master 로그량, copylog 전송량, 아카이브 수가 몇 % 늘 수 있다. 측정하지 않았다.
- **`file_io.c` 변경의 부수 효과.** 비서버 Linux 빌드가 lseek+read에서 pread/pwrite로 바뀌었다. 이로 인해 SA 모드 debug 빌드의 `pwrite_with_injected_fault` 경로가 빠졌다. SA 디버그 fault-injection 테스트가 이 경로에 의존하는지는 확인하지 못했다.

## 5. 총평

설계 쪽(gate, inflight, pending의 역할 분리, DONE 보류 알림, `la_coordinator_exit` 같은 release 로그 보강, 모듈별 단위 테스트)은 운영자가 읽기에도 의도가 잘 드러난다. 그러나 운영 관점에서는 병합 전에 막아야 할 문제가 여러 개다.

1. **develop의 운영 메커니즘이 병렬화 과정에서 조용히 끊겼다.** dbname 락은 매 적용마다 다시 잡던 것이 기동 시 1회로 바뀌었다(E1). `total_rows`가 끊겨 required_lsa와 아카이브 정리가 멈췄다(E2). SQL 로깅은 thread-safety 없이 병렬 호출된다(E3). 셋 다 단일 스레드 가정 위에 있던 기능이고 2노드 기본 테스트에서는 잘 드러나지 않는다. 3노드/replica, 장시간 부하, `ha_sql_logging` 같은 운영 구성에서 터진다.
2. **"멈추지 않고 재시작한다"는 장애 대응 약속이 일부 경로에서 성립하지 않는다.** 무한 pop(E4), 실행되지 않는 drain backstop(E7), 락 무한 루프(E1)는 프로세스를 살아 있는 채로 멈추게 한다. 그러면 heartbeat의 자동 복구가 동작하지 않는다.
3. **업그레이드와 호환성.** 카탈로그 컬럼 추가(E5)와 로그 레코드 타입 추가(E6)는 기존 DB 기동과 혼합 버전 운영을 깨뜨린다. 마이그레이션과 버전 정책을 함께 정해야 한다.
4. **설정 함정.** worker 수를 올리면 기본 메모리 한도로 재시작 루프에 빠진다(E8). 재시작이 잦으면 backlog를 직렬로 다시 처리하게 된다(E9). 그런데 기동 로그나 상태 덤프로는 이를 알아차리기 어렵다(M2, A4, A5).

정리하면 High 8건 중 E1~E4, E7은 코드 수정이 필요하다. E5, E6, E8은 수정하거나 최소한 운영 가드와 문서를 갖춰야 한다. 데이터 정합성 자체보다 운영 연속성(hang, 재시작 루프, 디스크 증가, 업그레이드 불가) 쪽 위험이 크므로, 3노드/replica 구성, 장시간 부하, 롤링 업그레이드, `ha_sql_logging=yes` 시나리오를 검증 매트릭스에 추가할 것을 권한다.
