# CBRD-27508 브랜치 리뷰 — 시스템 개발자 1년차

## 1. 리뷰어 관점

- 역할(시스템 개발자): DB 엔진 내부 관점에서 coordinator와 worker 사이의 동기화(큐·gate·inflight·pending), 종료·재시작 경로, 메모리 수명, 락·MVCCID self-lock 대기, master 라벨과 slave gate 사이의 약속(라벨 LSA가 무엇을 가리키는가)을 중점으로 봤다.
- 연차(1년차): 코드를 처음 읽는 사람 입장에서 주석이 실제 코드와 맞는지, 이름이 일관된지, 죽은 코드나 모순된 설명이 없는지를 같이 봤다. 이해가 막힌 곳은 끝까지 caller를 따라가서 확인했고, 확인하지 못한 것은 "추정"으로 분리했다.

## 2. 검토 범위와 실제로 읽은 경로

범위: `git diff a9a0dc78d 0e411f10f` (HEAD = 0e411f10f). 기준선 비교는 `git show a9a0dc78d:src/transaction/log_applier.c`.

| 파일 | 읽은 함수·영역 |
|---|---|
| `src/transaction/applier/*` (전부) | task/result 구조체, `la_gate_*`, `la_inflight_*`, `la_pending_*`, `la_task_queue_*`, `la_result_queue_*`, `la_worker_*`, recdes pool |
| `src/transaction/log_applier.c` | `la_coordinator_*` 전부(drain_ready, wait_for_commit_order_slot, cover_commit, dispatch_task, collect/record/retire, complete_without_task, wait_until_retired, wait_for_inflight_slot, release_apply_slot, advance_committed_lsa, add_result_stats, store_apply_info_at_interval, commit_apply_info, submit_task, process_sysop_end, set_commit_dependency, process_commit, exit), `la_apply_worker_*`, `la_request_shutdown`, `la_stop_apply_workers`, `la_apply_repl_log`, `la_flush_repl_items`, `la_commit_transaction`, `la_find_required_lsa`, 페이지 캐시 pin/unpin/invalidate/decache, `la_get_page_buffer`, `la_cache_buffer_replace`, `la_get/update_ha_apply_max_committed_lsa`, `la_update_ha_apply_info_log_record_time`, `la_get_wset_label`, `la_log_record_process`(LABEL/SYSOP_END/COMMIT/ABORT/HA_SERVER_STATE), `la_change_state`(DONE 보류), `la_init`, `la_shutdown`, `la_apply_log_file` 메인 루프 diff 전체, `la_add/find_apply_list`, `la_detach_sysop_fragment`, `la_update_query_execute*` |
| `src/transaction/writeset.{cpp,hpp}`, `writeset_types.hpp`, `writeset_history_map.*` | 전부 |
| `src/transaction/log_manager.c` | restart history_start, `log_sysop_start/commit_internal`, `log_append_sysop_end_internal`, `log_sysop_fallback_reason`, `log_append_wset_label_*`, `log_commit_local`, `log_complete_for_2pc` diff |
| `src/transaction/locator_sr.c` | `xlocator_repl_force` deadlock 경로, `locator_wset_*`, `locator_add_or_remove_index_internal`, `locator_update_index`, `locator_is_inserter_committing`, `locator_lock_and_get_object_internal` diff |
| `src/storage/btree.c`, `src/query/serial.c`, `src/transaction/replication.c` | diff 전체 |
| `log_tran_table.c`, `log_impl.h`, `log_record.hpp`, `log_recovery.c`, `log_append.cpp`, `system_parameter.{c,h}`, `error_code.h`, `log_applier.h`, `heartbeat.h`, catalog install | diff 전체 |
| CS 쪽 (caller만) | `CMakeLists.txt`(MULTI_CONN), `cs/sa/cubrid CMakeLists`, `work_space.{c,h}` diff, `file_io.c` diff, `ws_intern_instances`/`ws_cull_mops`/`ws_remove_resident_class` (호출 영향 확인용) |
| unit tests | `unit_tests/log_applier/CMakeLists.txt`, `test_log_applier_common.hpp`, gate 테스트 케이스 목록, writeset 테스트의 history_start 관련 케이스 목록 |

## 3. 발견 사항

### 3.1 에러

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| E1 | High | `log_applier.c:1039-1068`, `log_applier.c:1080-1109`, `log_applier.c:1519-1522`, `applier/log_applier_result_queue.cpp:176-187` | coordinator가 `la_result_queue_pop`에서 시한 없이 막히는데, worker 쪽 종료 요청은 플래그만 세워 이 대기를 깨우지 못한다 | `la_request_shutdown(){ la_applier_need_shutdown = true; }` / `wait_until_retired`·`wait_for_inflight_slot`은 `la_result_queue_pop`만 호출, 플래그 검사 없음 / pop은 `count==0 && shutdown==false`인 동안 `pthread_cond_wait` | 재시작 직후 recovery range의 첫 commit을 dispatch하고 `wait_until_retired`에서 대기 → 모든 worker가 `db_restart_sub` 실패(예: max_clients 초과, 서버 재다운) → `la_worker_startup_failed`가 `request_shutdown` 호출 → 플래그만 서고 result 큐 shutdown은 안 걸림 → coordinator 영구 대기. 프로세스는 살아 있으므로 heartbeat 재기동도 안 됨. worker 하나가 서버 락 대기로 멈춘 경우도 같고, 이때 메인 루프의 drain 백스톱(`LA_DRAIN_TIMEOUT_MSEC`)은 루프에 돌아오지 못해 발동하지 않는다 | 확정(코드 경로) | 신규 |
| E2 | High | `log_manager.c:1504-1514`, `writeset.cpp:1032`, `writeset.cpp:1081-1092`, `applier/log_applier_gate.cpp:281-291` | master 재시작 시 history_start를 `log_Gl.hdr.append_lsa`로 올리는데, 이 LSA는 slave commit-order ring에 올라가는 레코드 LSA가 아니다. gate는 frontier(ring에 올라간 commit LSA)가 라벨 이상이 돼야 통과시킨다 | `restart_lsa = log_Gl.hdr.append_lsa; wset_raise_history_start(...)` / 재시작 뒤 map이 비고 `prev_commit_lsa`가 NULL이라 첫 replicated commit의 라벨 = history_start = A / gate: `LSA_LE (dep, &la_Gate_frontier)` | applylogdb가 계속 떠 있는 채로 master `cub_server`만 재시작. slave frontier = 재시작 전 마지막 commit L < A. 재시작 뒤 첫 라벨 commit C1(dep=A, LSA c1>A)이 ring head로 올라가 park → C1이 끝나지 않으니 frontier가 A에 닿지 못함 → 이후 commit(모두 dep ≥ A)도 전부 park → ring이 차면 coordinator가 `wait_for_commit_order_slot`에서 계속 돈다. A와 c1 사이에 라벨 없는 commit이 하나라도 있으면 frontier가 A를 넘으므로 피해 간다 | 추정(코드 사실은 확정, 부팅 시 라벨 없는 commit이 늘 앞에 오는지는 미확인) | 신규 |
| E3 | Medium | `log_tran_table.c:1622`, `log_tran_table.c:1706`, `writeset.cpp` `wset_push_hash` | `tdes->wset_hashes.clear()`는 capacity를 놓지 않는다. 트랜잭션별 키 상한이 `ha_writeset_history_size`(기본 1,000,000)와 같다 | `tdes->wset_hashes.clear ();` / overflow 경로만 `swap`으로 해제 / `LOG_WSET_ENTRY`는 24바이트 | 키 99만 개짜리 트랜잭션을 한 번 돌린 tran index마다 약 25MB vector가 서버 수명 동안 남는다. 배치 작업이 여러 세션에서 돌면 tran index 수만큼 누적된다 | 확정(표준 의미론), 규모는 부하 의존 | 신규 |
| E4 | Medium | `schema_system_catalog_install.cpp:1096-1097`, `log_applier.c:2898-2900`, `log_applier.c:9761-9768` | `_db_ha_apply_info`에 컬럼 2개를 추가했지만 기존 DB용 마이그레이션 경로가 보이지 않는다 | `SELECT max_committed_lsa_pageid, ... FROM _db_ha_apply_info` 실패 시 `la_get_last_ha_applied_info` 오류 → "Failed to initialize _db_ha_apply_info" → `la_shutdown` | develop으로 만든 DB에 이 바이너리를 올리면 applylogdb가 시작할 때마다 실패하고, worker 수가 1이어도 마찬가지다 | 확정(코드), 업그레이드 도구 유무는 범위 밖 | 신규 |
| E5 | Medium | `log_applier.c:8211-8226` | 주기적 workspace 정리가 클래스마다 `ws_intern_instances`를 부르고, 그 안에서 `ws_cull_mops`(workspace 전체 순회)를 매번 돈다. 순회 중 resident 클래스 리스트가 바뀔 수 있다 | `for (m = ws_Resident_classes; m; m = m->next) ws_intern_instances (m->op);` → `ws_intern_instances`: flush + `ws_filter_dirty` + `ws_cull_mops` / `ws_cull_mops`는 GC된 클래스 MOP에 `ws_remove_resident_class` → `ml_remove(&ws_Resident_classes, ...)` | (성능, 확정) resident 클래스가 N개면 cull 주기마다 전체 cull을 N번 한다(기준선은 1번). (안전, 추정) replicated DROP으로 GC 대상이 된 클래스 노드가 순회 중에 빠지면 `m->next`가 해제된 노드를 읽는다 | 성능 확정 / UAF 추정 | 신규 |
| E6 | Medium | `locator_sr.c:13195-13208`, `locator_sr.c:13303-13313` | X_LOCK으로 row를 가져올 때마다, 끝난 트랜잭션이 넣은 row(INSID 유효)이면 MVCCID self-lock에 조건부 락을 한 번 잡았다 푼다 | `locator_is_inserter_committing`: `MVCCID_IS_NORMAL && !current && !is_active` → `lock_transaction_mvccid (..., S_LOCK, LK_COND_LOCK)` + unlock | replication이 켜진 master에서 vacuum 전 row에 대한 UPDATE/DELETE마다 lock manager 왕복이 두 번 늘어난다(실제 커밋 중인 경우만이 아니다). OLTP hot path 부하 | 경로 확정 / 성능 영향 크기는 추정 | 신규 |
| E7 | Low | `log_applier.c:8226-8232` | worker의 실제 commit이 성공한 뒤 workspace 정리용으로 한 번 더 `db_commit_transaction`을 하고, 그 결과를 task 결과로 돌려준다 | `error = db_commit_transaction (); ... return error;` | 두 번째 commit이 실패하면 이미 slave에 commit된 트랜잭션이 실패로 retire되어 applier가 멈췄다가 재시작한다. 재적용은 recovery range가 흡수하지만 불필요한 재시작이다 | 확정 | 신규 |
| E8 | Low | `applier/log_applier_pending.cpp:143-155`, `log_applier.c:8545-8548`, `applier/log_applier_inflight.cpp:70-73` | 종료 시 pending/inflight에 남은 SYSOP_END fragment 슬롯(별도 malloc)과 그 item이 해제되지 않는다 | `la_pending_clear`는 노드만 free / fragment는 `la_coordinator_release_apply_slot`(retire 시)에서만 free / `la_inflight_init`은 배열만 free | 서버 다운 등으로 in-process 재시작이 반복될 때마다 남아 있던 fragment가 샌다 | 확정 | 신규 |
| E9 | Low | `log_applier.c:1182`, `log_applier.c:7464` | fragment task의 `log_record_time=0`이 retire 시 그대로 `la_Info.log_record_time`에 들어간다. retire 순서가 commit 순서와 달라 시간이 뒤로 갈 수도 있다 | `la_Info.log_record_time = result->log_record_time;` (조건 없음) | serial fragment가 retire된 직후 `la_get_adaptive_time_commit_interval`이 0을 보고 조기 return하고, 저장 시 NULL이 들어가 갱신이 빠진다. 지연 지표가 흔들린다 | 확정 | 신규 |
| E10 | Low | `log_applier.c:7495-7502` vs `7473-7474`, `7553-7559` | 라벨 붙은 SYSOP_END를 `complete_without_task`로 처리하는 경로는 label holder를 비우지 않는다(fragment 경로는 비운다) | fragment 경로: `la_wset_label_trid = NULL_TRANID;` / complete 경로: 비우지 않음 | 같은 trid의 다음 commit이 자기 라벨 없이 읽히면 sysop의 라벨을 자기 것으로 가져가 `has_label=true`가 되고, "라벨 없으면 앞선 commit 전부 대기" 폴백(7574)을 건너뛴다. 현재 master는 commit마다 라벨을 쓰므로 실제로 드러나는 경우는 좁다 | 확정(비대칭), 영향 추정 | 신규 |
| E11 | Low | `log_applier.c:4638-4664`, `log_applier.c:7817-7818` | 라벨 읽기에 실패해도 holder는 "라벨 있음"으로 표시되고 dependency는 NULL(=의존 없음)이 된다 | `LSA_SET_NULL (dependency_seq); ... if (error) return;` 후 호출자가 `la_wset_label_trid = lrec->trid` | 읽기 실패가 순서 무시(즉시 dispatch)로 이어진다. 보수적으로는 "라벨 없음"으로 처리해 앞선 commit을 모두 기다려야 한다. `la_get_page`가 무한 재시도라 실제 실패 빈도는 낮다 | 확정(경로) | 신규 |
| E12 | Low | `log_applier.c:445`, `log_applier.c:1521` | `la_applier_need_shutdown`(plain `bool`)을 worker 스레드가 쓰고 coordinator가 읽는다 | `static bool la_applier_need_shutdown`; worker → `la_request_shutdown` | C++ 메모리 모델상 data race다. 지금은 함수 호출이 끼어 있어 최적화로 사라질 가능성은 낮지만 `std::atomic<bool>`이 맞다 | 확정 | 신규 |
| E13 | Low | `applier/log_applier_worker.cpp:95-98` | `pthread_create` 실패 시 `er_set` 없이 `ER_FAILED`를 돌려준다 | `if (pthread_create (...) != 0) return ER_FAILED;` | applylogdb 시작 실패의 원인이 error log에 남지 않는다 | 확정 | 신규 |

#### 상세

**E1.** worker가 모두 사라지거나 멈추면 coordinator가 빠져나올 길이 없다. `la_coordinator_wait_for_commit_order_slot`(741-758)은 100ms마다 플래그를 확인하지만, recovery range 경로(`la_coordinator_submit_task` 7394, 7411)와 inflight 만석 경로(`la_coordinator_dispatch_task` 830)는 `la_result_queue_pop`에서 깨어날 조건이 "결과 도착" 또는 "result 큐 shutdown"뿐이다. result 큐 shutdown은 `la_stop_apply_workers`(1529-1530)만 걸고, 그 함수는 coordinator가 `la_shutdown`에서 직접 부르므로 대기 중에는 걸릴 수 없다. 고칠 방향은 두 가지다. `la_request_shutdown`이 `la_result_queue_signal_shutdown()`도 부르게 하거나, 두 대기 함수를 `la_result_queue_wait_for_result(timeout)` + 플래그 확인 루프로 바꾸는 것이다. 후자는 메인 루프의 drain 백스톱과 같은 시간 기준을 이 자리에도 적용할 수 있다.

**E2.** gate 주석(`log_applier_gate.cpp:266-273`)은 "라벨은 선행 트랜잭션 하나를 가리킨다"는 전제를 깔고 있고, slave에서 그 선행은 ring의 commit(또는 라벨 붙은 SYSOP_END)이다. master가 거는 floor 가운데 `SYSOP_COMMIT_ORDER`(SYSOP_END LSA)와 history clear(`prev_commit_lsa`)는 ring에 올라오는 LSA라 이 전제가 맞는다. `RESTART`만 레코드가 아닌 append 위치다. 그런데 frontier는 ring의 commit LSA로만 움직이므로(`la_gate_advance_frontier` 225), A 바로 뒤의 첫 라벨 commit이 head가 되면 자기 자신이 끝나야 넘을 수 있는 floor를 기다리는 꼴이 된다. 다음 두 가지를 확인해 주기 바란다. (1) master 재시작 뒤 첫 라벨 commit 앞에 라벨 없는 commit 레코드가 늘 있는지(부팅 중 replication 비허용 상태의 commit 등). (2) 같은 applylogdb 프로세스가 재시작 전후의 log를 이어 읽는 시나리오를 테스트한 적이 있는지. 안전하게 고치려면 restart floor를 "재시작 뒤 첫 commit 직전의 commit LSA"로 잡거나, slave gate가 "ring에서 dep 이하 미완료 항목이 없으면 통과"하도록 바꾸면 된다. 다만 후자는 gate 의미를 바꾸므로 설계 검토가 필요하다. gate 단위 테스트(`test_log_applier_gate.cpp`)에는 이 경우가 없다.

**E5.** 기준선은 `ws_filter_dirty(); ws_cull_mops();`를 한 번 불렀다. 지금은 클래스마다 flush·decache·cull을 한다. 주석은 DONT_DECACHE로 남은 MOP을 정리하려는 의도를 설명하는데, 그렇다면 루프에서는 `locator_flush_all_instances(DECACHE)`만 하고 cull은 루프 밖에서 한 번 하는 편이 비용도 순회 안전성도 낫다.

**E6.** 대기가 꼭 필요한 경우는 "MVCCID는 끝났지만 commit 레코드를 아직 쓰지 않은" 짧은 구간뿐이다. 그 구간을 lock manager를 거치지 않고 거를 방법이 있는지 검토가 필요하다. 예를 들어 tdes 상태나 commit 레코드 기록 이후 세우는 플래그를 볼 수 있다. 최소한 성능 측정 근거는 남겨야 한다. btree 쪽(`btree_is_deleter_committing`)은 unique 검사의 DELETE_RECORD_DELETED 분기에서만 돌아서 빈도가 훨씬 낮다.

### 3.2 모듈화

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| M1 | Medium | `log_applier.c:700-1560`, `log_applier.c:7236-7652` | worker와 큐는 `applier/`로 분리됐는데 coordinator 로직(약 1,000행)과 그 상태(label holder `la_wset_label_*`, drain 대기 `la_Drain_*`)는 11,131행짜리 `log_applier.c`에 남아 있다 | `static int la_wset_label_trid` (7330), `static UINT64 la_Drain_wait_start_ns` (459) 등 파일 전역 | 코드 흐름을 따라가기 어렵다. coordinator 규칙(cover→inflight→queue 순서, 라벨 소비)을 단위 테스트로 검증할 수 없어 E10·E11 같은 비대칭이 테스트로 잡히지 않는다 | 확정 | 신규 |
| M2 | Low | `applier/log_applier_gate.cpp:56-64`, `log_applier_inflight.cpp:52-53`, `log_applier_pending.cpp:49-50`, 두 큐 파일 | gate·inflight·pending·큐가 모두 파일 전역 싱글턴이고 in-process 재시작은 각 `*_init`이 상태를 비우는 데 기댄다 | 예: `la_gate_init` 주석 "applylogdb restarts the applier inside the same process..." | init 하나를 빠뜨리면 이전 run의 상태가 다음 run으로 넘어간다(gate는 이미 한 번 고친 이력이 주석에 있다). 하나의 coordinator 객체로 묶으면 수명이 명확해진다 | 확정 | 신규 |
| M3 | Low | `serial.c:1219-1250`, `log_manager.c:4038-4072` | serial 갱신 sysop 안에서 db_serial 키를 수집하지만, 그 sysop은 repl item이 있어 항상 commit-order로 라벨되고 수집한 키는 `wset_discard_sysop_keys`로 버려진다 | `wset_add_write_key (serial_tdes, ...)` → 같은 sysop의 SYSOP_END에서 `wset_discard_sysop_keys` | 쓰이지 않는 키를 만들다 실패하면(`goto exit_on_error`) serial NEXT_VALUE 자체가 실패한다. BTID가 없을 때 바깥 트랜잭션 전체를 `WSET_FALLBACK_STATEMENT_REPLICATION` 사유로 폴백시키는 것도 이름과 맞지 않는다 | 확정 | 신규 |

### 3.3 아키텍처

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| A1 | Low | `log_applier.c:1400-1401`, `log_applier.c:1430-1456` | 크래시 주입용 테스트 hook이 release 빌드의 commit 경로에 있고, commit마다 `getenv`를 두 번 부른다 | `getenv ("CUBRID_HA_TEST_BLOCK_CLASS")` ... `usleep (block_msec * 1000)` | 운영 환경에 해당 변수가 남아 있으면 그 클래스의 commit이 60초씩 멈춘다. `getenv`는 `setenv`와 동시에 불리면 스레드 안전하지 않다. TODO에 적힌 대로 debug 빌드로 한정하거나 시작 시 한 번만 읽어야 한다 | 확정 | 신규 |
| A2 | Low | `log_applier.c:6634-6648`, `log_applier.c:6680-6694` | 파서 보호용 `la_sql_compile_mutex`가 compile뿐 아니라 서버 실행(`db_execute*`) 전체를 감싼다 | `pthread_mutex_lock (...); res = db_execute (...); ... unlock` | worker가 오래 걸리는 replicated statement를 실행하는 동안 coordinator의 `la_update_ha_apply_max_committed_lsa`(cover_commit)와 `la_update_ha_last_applied_info`가 막혀, 결과 수거와 DONE 판단까지 같이 선다. 이름(compile)과 실제 범위(execute)도 다르다 | 확정 | 신규 |
| A3 | Low | `log_applier.c:6705`, 사용처 `log_applier.c:10340` | failover drain 백스톱 30초가 하드코딩되어 있고, 정의가 사용처에서 3,600행 떨어진 schema 함수 앞에 있다 | `#define LA_DRAIN_TIMEOUT_MSEC 30000` | 대형 트랜잭션 하나가 30초를 넘으면 정상 drain 중에도 applier를 재시작시킨다. 운영자가 조정할 수 없다 | 확정 | 신규 |

### 3.4 리팩토링

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| R1 | Low | `log_applier.c:434`, `872`, `1005`, `1249`, `1259`, `7505`, `7512`, `7529`, `7638`, `7764`, `7825`, `9590` | 함수명은 `la_coordinator_*`인데 trace와 로그 문자열은 "reader"를 쓴다 | `"[WSET] reader schedule ..."`, `"applylogdb reader exit: ..."` | 로그로 원인을 찾는 사람이 코드와 로그를 맞춰 보기 어렵다 | 확정 | 신규 |
| R2 | Low | `applier/log_applier_task_queue.cpp:53`, `165`, `186` | `la_Shared_task_not_full` 조건변수는 signal/broadcast만 있고 기다리는 곳이 없다. 주석은 "the coordinator waits for a free slot"이라고 한다 | grep 결과 wait 호출 0건 / push는 대기하지 않는다고 같은 파일 77-82행이 설명 | 읽는 사람이 coordinator가 큐에서 블록된다고 오해한다. 지우거나 주석을 고쳐야 한다 | 확정 | 신규 |
| R3 | Low | `applier/log_applier_inflight.cpp:224-242`, `applier/log_applier_pending.cpp:97-132` | 결과 매칭이 inflight 전체 선형 탐색이고(용량 = worker 수 × 1024), pending 해제는 매번 head부터 다시 훑는다 | `la_inflight_find_by_seq` for-loop / `la_coordinator_drain_ready`가 `la_pending_pop_ready`를 반복 호출 | worker 32개면 결과 하나에 최대 32,768칸을 본다. seq는 연속이므로 `(head + (seq - head.seq)) % capacity`로 O(1)이 된다 | 확정 | 신규 |
| R4 | Low | `log_applier.c:612`, `log_applier.c:8161-8162` | `la_commit_transaction`의 `commit_lsa` 인자가 본문에서 쓰이지 않는다. 선언은 `static`, 정의는 `static`이 없다 | 본문에 `commit_lsa` 참조 없음 | 읽는 사람이 commit_lsa로 무언가 하는 줄 알게 된다 | 확정 | 신규 |
| R5 | Low | `applier/log_applier_gate.cpp:58-60`, `185`, `applier/log_applier_worker.hpp:43-47` | 한 곳은 "ring이 차면 coordinator가 log 읽기를 멈춘다", 다른 곳은 "ring은 실제로 찰 수 없다"고 쓴다 | `la_gate_order_push` Note: "The ring cannot actually fill (see la_Gate_order_ring)" | 뜻은 "push 시점에는 차 있지 않다"인데 문장끼리 모순으로 읽힌다 | 확정 | 신규 |
| R6 | Low | `log_manager.c:3997-4028` | trace용 계산(두 번째 집계 루프, `log_sysop_fallback_reason`의 class name 파싱)이 trace level과 상관없이 replication sysop commit마다 돈다 | 루프 2회 + `or_unpack_string_nocopy` | serial/INCR이 많은 부하에서 불필요한 비용이 든다. trace level 조건 안으로 옮기면 된다 | 확정 | 신규 |
| R7 | Low | `log_applier.c` 여러 곳(`"ws_repl ..."`, `"ws_marker TEST ..."`, `"ws_lsaguard ..."`), `worker.cpp:257`, `gate.cpp:234`, `locator_sr.c:8085-8092`, `8865-8869` | trace 접두어가 `[WSET]`와 `ws_*`로 섞여 있다. 일부 주석이 동작 대신 이력("Pre-existing defect fixed here")을 적는다 | 인용 생략 | grep 한 번으로 writeset 로그를 모을 수 없다. 이력은 커밋 메시지에 둘 내용이다 | 확정 | 신규 |
| R8 | Low | `log_applier.c:2954` vs `log_applier.c:3189-3240` | "coordinator connection에는 다른 미커밋 변경이 없다"는 주석이 사실과 다르다 | `la_update_ha_apply_info_log_record_time`는 UPDATE 후 commit 없이 `is_apply_info_updated = true` | 동작은 무해(같이 commit됨)하지만 주석을 믿고 다른 쓰기를 끼워 넣으면 의도하지 않은 시점에 commit된다 | 확정 | 신규 |
| R9 | Low | `applier/log_applier_result_queue.cpp:183` vs `applier/log_applier_task_queue.cpp:155` | 두 큐의 shutdown 의미가 다르다(task는 남은 항목을 버리고, result는 남은 항목을 계속 꺼내 준다) | `if (la_Shared_result_queue.count == 0)` vs `if (la_Shared_task_shutdown)` | 의도된 차이라면 주석으로 이유를 밝혀야 한다. 지금은 실수로 읽힌다 | 확정 | 신규 |

## 4. 미검증 의심 (근거 부족으로 확정 못 한 것)

1. **E2 재현 여부.** master 재시작 뒤 첫 라벨 commit 앞에 라벨 없는 commit이 항상 있는지 확인하지 못했다. 같은 applylogdb 프로세스가 master 재시작을 넘겨 계속 읽는 HA 시나리오에서 slave가 멈추는지 실측이 필요하다.
2. **worker 간 교착이 statement item에서 날 때.** `la_apply_repl_log`(log_applier.c 7070-7085)는 FLUSH·server-down이 아닌 item 오류에서 `error = NO_ERROR`로 계속 진행한다. 서버가 deadlock victim 트랜잭션을 이미 rollback했다면 남은 item만 새 트랜잭션으로 commit되어 부분 적용될 수 있다. row DML은 flush 오류로 와서 치명 처리되므로, 해당되는 것은 statement item뿐으로 보인다. 계속 진행하는 동작 자체는 기준선에도 있었지만(기존), 병렬화로 worker끼리 교착할 가능성이 새로 생겼다.
3. **해시 동치성.** 같은 domain 안에서 비교로는 같지만 pack 결과가 다른 값(예: float/double의 -0.0과 +0.0, TZ 타입에서 같은 시각을 다른 tz로 표현한 값)이 unique/PK 키로 쓰이면 서로 다른 hash가 나와 의존이 누락될 수 있다. 실제 B-tree 비교 규칙은 확인하지 않았다.
4. **copied log header 무잠금 읽기.** `la_coordinator_cover_commit`(796-799)와 worker의 `la_get_next_repl_item_from_log`가 `la_Info.act_log.log_hdr->eof_lsa`를 cache mutex 없이 읽는다. 470309f59 커밋은 header 갱신을 mutex 아래로 옮겼으므로 찢어진 읽기가 가능해 보인다. bound가 커지는 쪽이라 정합성은 깨지지 않는다고 보지만 확인하지 않았다.
5. **E5의 순회 중 해제.** `ws_cull_mops`가 지금 순회 중인 노드 자체를 지우는 조건이 실제로 성립하는지는 MOP 참조 규칙을 끝까지 따라가지 않았다.
6. **`la_sql_compile_mutex`와 서버 락의 교차 교착.** statement를 실행하는 worker가 mutex를 쥔 채 다른 worker의 락을 기다리고, 그 worker가 mutex를 기다리는 경우다. writeset이 statement 트랜잭션을 commit-order로 직렬화하므로 성립 조건을 찾지 못했다.

## 5. 총평

worker·큐·gate·inflight·pending을 `applier/` 아래 작은 모듈로 나눈 덕분에 처음 읽는 사람도 각 부품의 책임을 따라갈 수 있었다. 함수 머리 주석은 대부분 "왜"를 설명하고 있어 이해에 큰 도움이 됐다. master 쪽 writeset 수집과 publish(rwlock + 예약 카운터, sysop 키 버림, restart floor)도 의도가 주석에 잘 드러나 있다.

가장 먼저 다룰 것은 두 가지다.
- **E1:** coordinator의 블로킹 대기 두 곳이 종료 요청과 연결되어 있지 않다. worker가 모두 사라지거나 멈추면 applylogdb가 살아 있는 채로 영구 정지한다.
- **E2:** master가 거는 floor 가운데 restart floor만 slave ring에 존재하지 않는 LSA다. gate의 "라벨은 ring의 선행 하나를 가리킨다"는 전제와 어긋난다. 실제로 멈추는지는 추정이지만, 멈추면 복구 수단이 없는 형태라 실측이 필요하다.

그 다음은 운영 영향이 있는 Medium 항목이다. tdes별 vector capacity 잔류(E3), catalog 컬럼 추가에 마이그레이션이 없는 문제(E4), worker의 주기적 workspace 정리 비용(E5), master hot path에 추가된 self-lock 조건부 요청(E6)이다. 리팩토링 쪽에서는 coordinator를 `log_applier.c`에서 떼어 내는 것(M1)이 가장 효과가 크다. E10·E11 같은 coordinator 규칙의 비대칭이 지금은 단위 테스트로 잡히지 않는데, 분리하면 잡을 수 있게 된다. "reader" 명칭(R1)과 죽은 조건변수(R2)는 처음 읽는 사람을 확실히 헷갈리게 하므로 같이 정리하면 좋겠다.

등급별 건수: Critical 0 / High 2 / Medium 5 / Low 21
