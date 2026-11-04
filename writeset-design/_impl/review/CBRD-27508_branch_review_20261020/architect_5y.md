# CBRD-27508 브랜치 리뷰: 아키텍트 5년차

## 1. 리뷰어 관점

master가 만드는 writeset 라벨과 slave의 gate·coordinator가 같은 계약을 지키는지를 가장 먼저 봤다. 라벨이 가리킬 수 있는 LSA의 종류와 gate가 통과시킬 수 있는 LSA의 종류가 서로 맞는지, "충돌하는 뒤 트랜잭션은 앞 트랜잭션의 publish를 반드시 본다"는 불변식이 어디서 보장되는지도 확인했다. 그다음으로 모듈 경계와 결합도(log_manager가 writeset·replication 내부를 아는 정도, log_applier.c에 남은 coordinator 로직), 기존 CUBRID 구조와의 정합(로그 레코드 타입, 카탈로그, 빌드 플래그)을 봤다. 연차 관점에서는 모듈 사이의 상호작용, 경계 조건(restart, 복구 구간, worker 기동 실패), 그리고 설계상 확장성 한계를 중점으로 봤다.

## 2. 검토 범위와 실제로 읽은 경로

범위는 `git diff a9a0dc78d 0e411f10f`(HEAD = 0e411f10f, 12 커밋)이다. 행번호는 모두 HEAD 기준이다.

- **master writeset**
  - `src/transaction/writeset_types.hpp`, `writeset.hpp` 전체
  - `writeset.cpp` 전체: 해시(fnv1a/string/midxkey), add_write/ref_key, find_dependency_in_range, publish_with_capacity, clear, sysop fallback, raise_history_start
  - `writeset_history_map.{hpp,cpp}` 전체
- **master 커밋·로그 경로**
  - `log_manager.c` diff 전체: log_initialize_internal RESTART raise, log_sysop_start/commit_internal/abort, log_append_sysop_end_internal, log_sysop_fallback_reason, log_append_wset_label_*, log_commit_local, log_complete_for_2pc
  - `log_dump_record`의 switch(7347~)와 `log_dump` 루프
  - `log_impl.h`, `log_record.hpp`, `log_append.cpp`, `log_recovery.c`, `log_tran_table.c`의 diff
  - `log_comm.c:log_does_allow_replication`
- **키 수집과 대기 경로**
  - `locator_sr.c` diff 전체: locator_wset_collect_fk_ref, add_or_remove_index_internal, update_index, locator_is_inserter_committing, lock_and_get_object_internal, xlocator_repl_force
  - `btree.c` diff: btree_is_deleter_committing, unique_of_unique/non_unique
  - 기존 `btree_fk_object_does_exist`(30505~)와 `btree_find_foreign_key`의 lock_mode(6361)
  - `serial.c`, `replication.c`의 diff와 `repl_add_update_lsa`
- **slave 병렬 applier**
  - `log_applier.c`
    - LA_INFO와 LA_APPLY 정의
    - coordinator 함수 전부: drain_ready, wait_for_commit_order_slot, cover_commit, dispatch_task, collect/record/retire, complete_without_task, wait_until_retired, wait_for_inflight_slot, submit_task, process_sysop_end, set_commit_dependency, process_commit
    - 레코드·라벨 처리: la_log_record_process, la_get_wset_label, la_detach_sysop_fragment, la_find_required_lsa
    - 저장·복구: la_get/update_ha_apply_max_committed_lsa, la_get_last_ha_applied_info
    - 적용·종료: la_flush_repl_items, la_apply_repl_log, la_commit_transaction, la_change_state, 메인 루프(10150~10430), la_shutdown, la_apply_log_file 기동부
  - `src/transaction/applier/*` 전체(gate, worker, task, result, result_queue의 pop/wait/shutdown, pending의 clear, inflight의 init)
  - `log_applier.h`
- **CS glue (caller만)**
  - CMakeLists(top/cs), `work_space.{c,h}`, `file_io.c`, `heartbeat.h`
  - `db_restart_sub`/`db_shutdown_sub` 호출부와 `tr_init`·`db_disable_trigger` 반환값 처리
- **기타**
  - `system_parameter.{c,h}`, `error_code.h`, `cubrid.msg`, `schema_system_catalog_install.cpp`
- **단위 테스트**
  - `unit_tests/log_applier/*`: CMakeLists, gate 테스트 케이스 목록
  - `unit_tests/writeset/*`: CMakeLists, common.hpp, test_writeset.cpp 케이스 목록
- **기준선 비교**
  - `git show a9a0dc78d:src/transaction/log_record.hpp`(LOG_LARGER_LOGREC_TYPE = 53)
  - `git show a9a0dc78d:src/transaction/log_applier.c`(6336행 레코드 타입 검사)
  - `git show a9a0dc78d:CMakeLists.txt`(605행)

## 3. 발견 사항

### 3.1 에러

| ID | 등급 | 위치 | 내용 | 근거 | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| E1 | High | `log_manager.c:1511-1513`, `applier/log_applier_gate.cpp:281-290` | master가 restart 때 올리는 history_start는 커밋 LSA가 아니다. gate는 frontier가 라벨에 도달해야 통과시키는데, frontier는 ring에 올라간 커밋 LSA로만 움직인다. | `restart_lsa = log_Gl.hdr.append_lsa; wset_raise_history_start(...)` / `return !LSA_ISNULL(&la_Gate_frontier) && LSA_LE(dep, &la_Gate_frontier);` | master 재기동 뒤 첫 라벨 커밋 T1의 dep는 restart_lsa다. restart_lsa와 T1 사이에 라벨 없는 커밋이 하나도 없으면 frontier는 restart 전 마지막 커밋(< restart_lsa)에서 멈춘다. T1은 ring head인 채로 parked 되고, 이후 커밋도 모두 dep ≥ restart_lsa라 parked 된다. 결국 ring이 차고 `la_coordinator_wait_for_commit_order_slot`이 끝없이 돈다(주석의 "always passes" 전제가 깨짐). 이때 DONE도 보류되므로 failover까지 막힌다. | gate 규칙과 restart_lsa가 ring에 들어가지 않는다는 점은 확정. 발생 조건(사이에 라벨 없는 커밋이 없음)은 추정 | 신규 |
| E2 | High | `btree.c:6361`, `btree.c:30581-30604`(기존 FK 검사), `locator_sr.c:13303`(신규 대기는 X_LOCK만) | 커밋 중인 inserter를 기다리는 장치(d1d02b9e4)는 X_LOCK 경로에만 있다. 자식 FK 검사는 부모 행을 S_LOCK으로 잡으므로, 커밋 중인 부모 inserter를 기다리지 않는다. | `find_fk_object.lock_mode = S_LOCK;`, `case DELETE_RECORD_CAN_DELETE: ... lock_object(..., find_fk_obj->lock_mode, LK_COND_LOCK)` / `if (lock_mode == X_LOCK && !is_inserter_waited && locator_is_inserter_committing(...))` | T1이 부모 P를 INSERT하고 커밋에 들어간다(complete_mvcc 완료, publish 전, P에 행 X락 없음). 그사이 T2가 P를 참조하는 자식을 INSERT한다. FK 검사에서 P는 CAN_DELETE이고 S락도 바로 잡힌다. T2의 의존성 탐색이 T1의 publish보다 먼저 일어나면 REF가 miss 되고, T2의 라벨은 T1보다 낮아진다. slave에서는 T2가 T1보다 먼저 또는 동시에 적용되어 FK 위반이 난다. `la_flush_repl_items`는 이 실패를 fail_counter++로 넘기고 커밋하므로(5885~ 부분 실패 경로) 자식 행이 **무성 유실**된다. | 대기하지 않는 경로는 확정. 경쟁 타이밍은 추정(재현 안 함) | 신규(writeset 라벨 누락). 역순 커밋 자체는 기존 CBRD-26942 계열 |
| E3 | Medium | `log_applier.c:1039-1068`, `1080-1109`, `applier/log_applier_result_queue.cpp:172-197`, `applier/log_applier_worker.cpp:379-391` | coordinator의 blocking 대기(`wait_until_retired`, `wait_for_inflight_slot`)가 `la_result_queue_pop`에서 무기한 대기하면서 shutdown 플래그를 보지 않는다. worker 기동 실패는 플래그만 세우고 결과 큐는 깨우지 않는다. | `while (count == 0 && shutdown == false) pthread_cond_wait(...)` / `la_worker_startup_failed → request_shutdown()`(la_applier_need_shutdown만 설정). `signal_shutdown`은 `la_stop_apply_workers`(coordinator 자신)에서만 호출된다. | 재기동 직후 복구 구간에서 coordinator가 task를 하나 dispatch하고 `wait_until_retired`에 들어간다. 그사이 모든 worker가 `db_restart_sub`에 실패한다(slave 서버 재기동 등). 결과는 오지 않고 pop은 깨어나지 않는다. SIGTERM도 플래그만 세우므로 applylogdb가 SIGKILL 전까지 멈춘다. | 코드 경로 확정. 발생 빈도는 추정 | 신규 |
| E4 | Medium | `log_applier.c:4638-4669`, `7815-7818`, `7553-7564` | 라벨 읽기에 실패하면 dependency를 NULL로 두고도 holder에 trid를 기록한다. 그 결과 has_label=true, dep=NULL, 즉 "의존 없음"으로 실행된다(fail-open). | `LSA_SET_NULL(dependency_seq); ... if (error) return;` → `la_wset_label_trid = lrec->trid;` → `has_label`이면 dep을 그대로 복사 | 라벨 데이터가 다음 페이지에 걸쳐 있고 그 페이지 fetch가 I/O 오류로 실패하면, 충돌 트랜잭션이 선행 트랜잭션과 병렬로 적용된다. 라벨이 없는 커밋은 ring tail까지 기다리게 하는 기존 안전장치(7574-7578)와 정반대로 동작한다. | 코드 확정. 발생은 추정(I/O 오류 시) | 신규 |
| E5 | Low | `log_manager.c:7347-7470`(log_dump_record) | `LOG_DUMMY_WSET_LABEL`에 대한 case가 없다. | default: `"log_dump: Unknown record type = %d"`, `LSA_SET_NULL(log_lsa)` | `cubrid diagdb`로 로그를 덤프하면 커밋마다 "Unknown record type" 줄이 섞여, 운영 진단 때 로그 손상으로 오인할 수 있다. 루프는 forw_lsa로 계속 진행한다. | 확정 | 신규 |

**E1 상세.** 라벨이 가리킬 수 있는 좌표는 네 종류다.
1. 커밋 LSA(map 슬롯, prev_commit_lsa)
2. 커밋 LSA인 clear floor(`wset_clear_history_locked(&prev_commit_lsa)`)
3. SYSOP_END LSA(`wset_raise_history_start(&sysop_lsa)`)
4. RESTART의 `append_lsa`

slave는 1~3을 모두 ring에 올린다. 1·2는 `la_coordinator_submit_task`가, 3은 fragment task나 `la_coordinator_complete_without_task`가 올린다. 4만 slave에 대응하는 레코드가 없다. gate가 맞게 동작하려면 "모든 라벨은 ring에 올라가는 LSA이거나, 그 이상의 커밋이 이미 완료되어 있다"는 불변식이 필요한데, 4가 이 불변식을 깬다.

HA에서 재기동 노드가 standby를 거쳐 그사이 applier 커밋을 남기는 일반 흐름에서는 라벨 없는 커밋이 frontier를 밀어 주므로 숨겨진다. 반면 peer 없이 단독으로 master가 되어 바로 사용자 커밋이 들어오는 경우(두 노드 정지 후 한쪽만 먼저 hb start 등)에 드러난다. gate 단위 테스트(`test_log_applier_gate.cpp` 7 케이스)에도 "frontier와 ring head 사이의 비커밋 라벨" 케이스가 없다.

수정 방향은 두 가지다. 하나는 gate가 "ring의 가장 오래된 미완료 커밋 > dep이면 통과"로 판정하게 하는 것이다(ring은 읽은 커밋 중 frontier가 지나지 않은 것을 모두 담으므로 정확하다). 다른 하나는 master가 restart 시점에 slave가 ring에 올릴 수 있는 레코드를 남기는 것이다.

**E2 상세.** 이 브랜치는 "충돌하는 뒤 트랜잭션은 앞 트랜잭션의 publish 이후에 의존성을 찾는다"는 불변식을 지키려고 두 곳을 막았다. 하나는 X락으로 행을 수정하는 경로(`locator_lock_and_get_object_internal`)이고, 다른 하나는 unique 검사가 커밋 중인 deleter를 만나는 경로(`btree_key_find_and_lock_unique_of_*`)다. 두 곳 모두 MVCCID self-lock을 기다린다. self-lock은 `log_commit_local`에서 publish 뒤 `lock_unlock_all`로 풀리므로 이 방식은 맞다.

그러나 같은 창을 관찰하는 세 번째 경로인 FK 부모 존재 검사는 막지 않았다. S_LOCK 경로라 `lock_mode == X_LOCK` 조건에 걸리지 않는다. `btree_fk_object_does_exist`는 INSERT_IN_PROGRESS일 때만 inserter를 기다리고, complete_mvcc가 끝난 뒤에는 CAN_DELETE로 바로 진행한다. 이 결함은 slave에서 오류로 멈추지 않고 무성 유실로 끝나므로 운영상 Critical 후보다.

### 3.2 모듈화

| ID | 등급 | 위치 | 내용 | 근거 | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| M1 | Medium | `log_manager.c:4001-4030`, `4772-4789`, `4808-4870`, `80` | log_manager가 replication record 내부를 직접 읽는다. 같은 "NEED_FLUSH 항목 세기" 루프가 3벌 있고, trace용으로 repl_data를 언팩해 클래스명을 비교하며, 이를 위해 카탈로그 상수 헤더까지 포함한다. | `for (...) if ((DATA\|\|STATEMENT) && must_flush == LOG_REPL_NEED_FLUSH) repl_item_count++;` ×2, `pending_item_count++` ×1, `or_unpack_string_nocopy(...); strcmp(class_name, CT_SERIAL_NAME)` | replication record 레이아웃(`repl_log_insert`의 packed key 뒤 클래스명)이 바뀌면 log_manager의 trace가 조용히 틀린 값을 낸다. 라벨 결정(`repl_item_count > 0`)과 trace가 같은 판정을 따로 구현하고 있어, 한쪽만 고치면 서로 어긋난다. | 확정 | 신규 |
| M2 | Medium | `log_applier.c` 전반(11131행, 이 브랜치에서 +2812/-1090) | 분리한 모듈(gate, pending, inflight, queue, worker)은 단위 테스트가 있다. 하지만 가장 복잡한 결정 로직은 여전히 log_applier.c의 static 함수와 파일 전역에 있다. submit_task(병렬, 단일 worker, 복구 구간 분기), set_commit_dependency, sysop fragment 분리, cover_commit, drain/DONE 보류가 그렇고, 전역으로는 `la_wset_label_trid`, `la_wset_label_dependency_seq`, `la_Drain_*`, `la_Info.recovery_boundary_lsa`, `max_committed_lsa`가 있다. | 7330-7331 label holder 전역, 459-460 drain 전역, 7360-7428 submit_task | E1·E4 같은 라벨·gate 계약 위반은 이 결정 로직에서 생기는데, 이 로직은 단위 테스트로 검증할 수 없다(test_log_applier CMakeLists는 applier/*.cpp만 링크한다). | 확정 | 신규 |
| M3 | Low | `writeset.hpp:56`, `writeset_history_map.hpp:188-191`, `log_tran_table.c:514,608` | `wset_History` 전역 구조체가 헤더에 노출되어 있다. history 수명이 트랜잭션 테이블 정의·해제에 붙어 있다. | `extern LOG_WSET_HISTORY wset_History;`, `logtb_define_trantable_log_latch → wset_history_initialize()` | 테스트와 다른 모듈이 map, history_start, prev_commit_lsa를 직접 만질 수 있어 seq_lock→history_lock 순서 규칙이 우회될 수 있다. 헤더의 TODO가 이미 이 문제를 인정하고 있다. | 확정 | 신규 |
| M4 | Low | `heartbeat.h` `HB_MAX_APPLY_WORKER_COUNT`, `applier/log_applier_worker.hpp:39-47` | applier의 배열 크기와 commit-order 용량이 heartbeat 헤더의 상수와 task queue 상수에서 파생된다. | `#define LA_MAX_WORKER_COUNT HB_MAX_APPLY_WORKER_COUNT`, `LA_COMMIT_ORDER_CAPACITY(wc) ((wc) * LA_TASK_QUEUE_CAPACITY)` | worker 상한을 바꾸려면 heartbeat 헤더를 고쳐야 한다. ring 크기를 바꾸면 task queue 크기도 함께 바뀐다. 둘은 서로 독립인 튜닝 축이다. | 확정 | 신규 |

### 3.3 아키텍처

| ID | 등급 | 위치 | 내용 | 근거 | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| A1 | High | `log_manager.c:4039-4072`, `writeset.cpp:1436-1487`, `log_applier.c:7442-7492` | serial(AUTO_INCREMENT, NEXT_VALUE), INCR/DECR, checksumdb의 sysop이 모두 전역 barrier가 된다. master에서는 sysop마다 `seq_lock`과 `history_lock` wrlock을 잡는다. slave에서는 fragment가 "이전 커밋 전부"를 기다리고, 이후 모든 커밋이 fragment를 기다린다. | fallback dep = max(prev_commit_lsa, history_start), 이어서 `wset_raise_history_start(&sysop_lsa)` | 캐시 없는 serial이나 AUTO_INCREMENT를 쓰는 INSERT 위주 부하에서는 트랜잭션마다 S_i(이전 전부 대기) → C_i(S_i 대기)가 이어져 slave 적용이 사실상 직렬이 된다. master 커밋 경로도 전역 wrlock 때문에 경합한다. 병렬 applier의 목적이 이 부하에서 사라진다. | barrier 동작은 확정. 기본 serial 캐시 설정에 따른 실제 빈도는 추정 | 신규(4045-4051 TODO로 인지됨) |
| A2 | Medium | `log_manager.c:5562`(complete_mvcc) → `5602`(find) → `5606`(publish) → `5622`/unlock_all, `locator_sr.c:13303`, `btree.c` 27553/27910 | 의존성의 정확성이 "가시화(complete_mvcc) → publish" 창을 각 가시성 검사 지점에서 따로 막는 방식에 달려 있다. 커밋 프로토콜 한 곳에서 보장하지 않는다. | 대기 코드가 locator(X_LOCK)와 btree(unique deleter)에 따로 들어갔고 FK(S_LOCK)에는 없다(E2) | 앞으로 생기는 가시성 경로(예: 새 인덱스 검사, 병렬 쿼리의 수정 경로)마다 같은 패치가 필요하다. 빠뜨린 곳은 E2처럼 무성 유실로 드러난다. 공통 헬퍼(예: `wset_wait_if_publishing(mvccid)`)로 모으거나, publish가 끝난 뒤에 MVCC를 완료하는 순서로 바꾸는 방안을 검토해야 한다. | 확정(구조) | 신규 |
| A3 | Medium | `log_applier.c:778-810`, `1024-1028`, `7378-7412` | 복구 구간의 상한(max_committed_lsa)이 dispatch마다 copied log의 eof_lsa로 뛴다. 재기동하면 그 eof까지 전부 "하나씩 dispatch 후 retire 대기"로 적용한다. | `if (LSA_GT(&eof_lsa, &bound)) LSA_COPY(&bound, &eof_lsa);` / `la_is_in_recovery_range` → `la_coordinator_wait_until_retired()` | slave가 백로그 1시간분을 안고 있다가 applier나 서버가 재기동되면 백로그 전체가 단일 worker보다도 느린 직렬 경로(queue 왕복과 매 건 retire 대기)로 적용된다. 따라잡기가 가장 필요한 시점에 처리량이 가장 낮아진다. | 확정 | 신규 |
| A4 | Medium | `log_record.hpp:140`, `log_manager.c:5029-5040`, 기준선 `a9a0dc78d:log_record.hpp`(LARGER=53), `a9a0dc78d:log_applier.c:6336` | 새 로그 레코드 타입 53을 slave 종류와 무관하게 무조건 기록한다. 기준선 applier는 53을 `LOG_LARGER_LOGREC_TYPE`로 보고 손상으로 판정한다. | 기준선: `LOG_SUPPLEMENTAL_INFO = 52, LOG_LARGER_LOGREC_TYPE` / `if (... lrec->type >= LOG_LARGER_LOGREC_TYPE) ... return ER_LOG_PAGE_CORRUPTED` | master를 먼저 올리는 롤링 업그레이드에서 구버전 slave의 applylogdb는 첫 라벨에서 ER_LOG_PAGE_CORRUPTED로 반복 종료된다. 로그 포맷 버전 표기나 라벨 기록을 켜고 끄는 수단이 없다. | 확정(기준선 코드 경로) | 신규 |
| A5 | Medium | `schema_system_catalog_install.cpp:1095-1097`, `log_applier.c:2896-2899`, `3349-3353` | `_db_ha_apply_info`에 컬럼 2개를 추가했지만 마이그레이션 경로가 없다. applier는 기동할 때 새 컬럼을 SELECT하고, 실패하면 기동을 중단한다. | `SELECT max_committed_lsa_pageid, ...` → `if (res != NO_ERROR) return res;` → "Failed to initialize _db_ha_apply_info" | 기존 버전으로 만든 slave DB에 새 바이너리를 올리면 applylogdb가 시작되지 않는다. 함수 주석의 TODO(final_lsa 재사용)가 이 카탈로그 변경을 피하는 방안이다. | 컬럼과 오류 경로는 확정. 별도 migrate 도구가 처리하는지는 추정(브랜치 안에는 없음) | 신규 |
| A6 | Medium | `CMakeLists.txt:607` | `MULTI_CONN_TO_A_SERVER`를 최상위에서 전역 정의로 켰다. applylogdb만이 아니라 cs, sa, server와 모든 클라이언트 유틸리티·라이브러리의 92개 `#if` 지점이 동작을 바꾼다. | `add_definitions(-DMULTI_CONN_TO_A_SERVER)`(기준선은 주석 처리) | broker CAS 같은 다른 클라이언트의 error manager, area_alloc, network, boot 경로가 다중 연결 모드로 컴파일되어, applier와 무관한 회귀 위험과 성능 영향이 생긴다. 범위를 applier 타깃이나 런타임 옵트인으로 좁혀야 한다. | 플래그가 전역이라는 점은 확정. 런타임 영향은 추정 | 신규 |

**A1 상세.** writeset 설계의 장점은 "같은 키만 기다린다"는 것인데, sysop 경로가 그 반대인 전역 commit-order barrier로 되어 있다. TODO가 밝힌 보류 이유(키 경로의 순서 문제, INCR/DECR와 overflow의 무라벨 처리)는 타당하다. 다만 이 상태로는 AUTO_INCREMENT 테이블이 흔한 일반 OLTP에서 병렬화 효과를 검증할 수 없다. 최소한 측정 문서에 "serial sysop 비율 대비 병렬도"를 지표로 두기를 권한다. 정식 해법으로는 serial 키를 SYSOP_END 좌표로 probe/publish하는 방식을 우선순위 높게 다룰 것을 제안한다.

### 3.4 리팩토링

| ID | 등급 | 위치 | 내용 | 근거 | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| R1 | Low | `log_applier.c` 872, 1005, 1248, 1259, 7484, 7505, 7512, 7523, 7638, 7764, 7819, 7825, 433-434 주석 | coordinator를 trace 문자열과 주석에서 "reader"로 부른다(`[WSET] reader schedule/retire/commit/label...`, `LA_DEBUG_LOG "reader ..."`). | `"[WSET] reader schedule trid=%d ..."` | 운영 로그와 코드·문서의 용어가 달라 분석 도구와 사람이 같은 주체를 두 이름으로 다루게 된다. | 확정 | 신규 |
| R2 | Low | `log_applier.c:1401`, `1431-1460` | 테스트용 지연 훅이 release 빌드의 커밋 경로마다 `getenv`를 두 번 호출한다. | `la_apply_worker_test_block_before_commit(...)`, TODO 주석 | 운영 환경에 `CUBRID_HA_TEST_BLOCK_CLASS`가 남아 있으면 해당 클래스 커밋이 60초씩 멈춘다. 디버그 전용으로 돌리거나 기동 때 한 번만 읽어야 한다. | 확정 | 신규 |
| R3 | Low | `unit_tests/writeset/test_writeset_common.hpp:53` | 주석에는 "ten-million-key production default"라고 되어 있지만 실제 기본값은 1,000,000이다(`system_parameter.c` `{.i = 1000000}`, 상한이 10,000,000). | 주석과 prm_Def 불일치 | 테스트를 읽는 사람이 운영 용량을 10배로 잘못 이해한다. | 확정 | 신규 |
| R4 | Low | `writeset.cpp:60-70`, `log_manager.c:4076-4078`, `4766` | 통계 카운터를 수집만 하고 노출하지 않는다(TODO). trace 레벨 판정도 writeset.cpp는 캐시 값(`wset_Trace_level`), log_manager와 log_applier는 `prm_get_integer_value`로 서로 다르다. | `/* TODO(CBRD-27508): expose these process-local counters ... */` | 운영 중에 history clear나 fallback 빈도(A1·A3 판단에 필요한 지표)를 볼 수 없다. trace 판정 경로가 둘이라 동적 변경 시 동작이 갈린다. | 확정 | 신규 |
| R5 | Low | `unit_tests/log_applier/test_log_applier_gate.cpp` | gate 테스트에 "커밋이 아닌 LSA를 가리키는 라벨" 케이스가 없다. | TEST_CASE 7개 목록 | E1 회귀를 막을 테스트가 없다. | 확정 | 신규 |

## 4. 미검증 의심 (근거 부족으로 확정하지 못한 것)

1. **분할 테이블 부모의 FK REF 해시 불일치(추정, 확인 시 High).** 부모 WRITE는 `locator_add_or_remove_index_internal`에서 실제 행이 들어간 클래스 OID와 그 인덱스 VFID로 해시된다. 자식 REF는 `index->fk->ref_class_oid`와 `ref_class_pk_btid.vfid`로 해시된다(`locator_sr.c` locator_wset_collect_fk_ref). 부모가 분할 테이블이면 앞의 것은 partition의 class_oid와 local btid이고 뒤의 것은 root의 값일 수 있다. 그러면 REF가 부모 WRITE와 만나지 않는다. 분할 테이블의 PK btid가 global인지 local인지, FK의 ref_class_oid가 root인지 확인해야 한다. 분할 테이블의 global unique 인덱스가 있다면 partition 간 같은 키도 class_oid 차이로 해시가 갈린다.
2. **label holder 잔존(추정).** 재기동 후 required_lsa부터 다시 읽을 때 상황이 다음과 같으면 holder가 소비되지 않고 남는다.
   - 라벨이 붙은 SYSOP_END(trid A)는 committed_lsa 이하라 skip 경로(`log_applier.c:7520-7534`)로 간다.
   - A의 COMMIT은 committed_lsa 위에 있다.

   그 사이 다른 라벨이 holder를 덮어쓰지 않으면, A의 COMMIT이 sysop용 라벨을 자기 라벨로 가져간다. committed_lsa가 커밋 LSA이므로 사이에 라벨이 붙은 커밋이 보통 있지만, 무라벨 커밋만 있는 경우를 배제하지 못했다.
3. **worker별 `tr_init()` 재호출(추정).** `log_applier_worker.cpp:161-162`에서 `tr_init()`은 프로세스 전역 trigger 상태를 worker마다 다시 초기화한다. `db_disable_trigger()`의 반환값(bool)은 무시된다. 비활성화가 실패하면 slave에서 trigger가 다시 실행될 수 있다. trigger_manager 전역의 스레드 안전성은 확인하지 않았다.
4. **항목 단위 재시도와 unilateral abort(기존 동작, 병렬화로 노출 가능성 증가 추정).** `la_apply_repl_log`는 `ER_LK_UNILATERALLY_ABORTED`를 재시도 대상으로 보고 같은 항목만 다시 적용한다(`log_applier.h:35`, `log_applier.c` 7080 부근). 서버가 트랜잭션 전체를 롤백한 뒤라면 앞 항목들은 사라진 채로 커밋된다. bulk flush 경로는 `xlocator_repl_force`의 deadlock 변경으로 치명 오류가 되지만, statement 항목과 즉시 실행 경로가 worker 사이 deadlock에서 이 재시도를 타는지는 확인하지 않았다.

## 5. 총평

master 쪽 writeset 계층의 기본 설계는 일관된다. 커밋 직전에 의존성을 찾고, 라벨과 COMMIT을 prior_lsa_mutex 안에서 붙여 쓰고, 커밋 LSA를 얻은 뒤 publish하고 락을 해제한다. REF·WRITE 슬롯 분리, 해시의 VFID 분리, 콜레이션 의사키, overflow와 statement fallback도 각자 근거가 주석과 테스트로 남아 있다. slave 쪽도 gate, pending, inflight, queue를 별도 모듈로 떼고 단위 테스트를 붙여, 기존 applier 구조에 무리 없이 얹었다.

이번 리뷰에서 본 핵심 위험은 두 계약이 한 곳에서 정의되지 않고 흩어져 있다는 점이다.

- **라벨 ↔ gate 계약(E1, E4).** master가 만들 수 있는 라벨 좌표와 slave gate가 통과시킬 수 있는 좌표가 명세로 묶여 있지 않다. RESTART floor가 이 틈으로 빠졌고, 라벨 읽기 실패는 fail-open으로 처리된다. gate가 "ring의 가장 오래된 미완료 커밋 > dep"로 판정하게 바꾸면 두 문제가 함께 단단해진다.
- **가시화 ↔ publish 불변식(E2, A2).** 커밋 중인 트랜잭션을 기다려야 하는 지점을 가시성 검사 경로마다 따로 패치했고, FK S_LOCK 경로가 빠졌다. 결과가 slave의 무성 유실이므로 가장 먼저 고쳐야 한다.

확장성 측면에서는 serial sysop의 전역 barrier(A1)와 재기동 뒤 백로그 전체 직렬화(A3)가 "병렬 applier가 정작 필요한 부하·상황에서 직렬로 떨어지는" 설계 한계다. 측정 계획에 이 두 상황을 꼭 넣기를 권한다. 기존 CUBRID 구조와의 정합에서는 새 로그 타입과 카탈로그 컬럼에 업그레이드 경로가 없고(A4, A5), MULTI_CONN을 전역으로 켰다(A6). 이 셋은 정식 반영 전에 범위와 호환 방침을 정해야 한다. 모듈화와 리팩토링 항목(M1, M2, R1~R5)은 기능 정확성에는 영향이 없지만, 특히 M2(coordinator 결정 로직을 테스트할 수 없음)가 E1 같은 결함이 테스트에서 걸리지 않은 직접적인 이유다.

등급별 건수: Critical 0 / High 3 (E1, E2, A1) / Medium 9 (E3, E4, A2, A3, A4, A5, A6, M1, M2) / Low 8 (E5, M3, M4, R1, R2, R3, R4, R5), 총 20건. 미검증 의심 4건은 이 건수에 넣지 않았다.
