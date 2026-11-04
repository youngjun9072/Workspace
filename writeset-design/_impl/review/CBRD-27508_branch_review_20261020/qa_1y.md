# CBRD-27508 브랜치 리뷰: QA 1년차

## 1. 리뷰어 관점

- 역할(QA): 각 경로를 테스트할 수 있는지, 단위테스트가 무엇을 덮고 무엇을 빠뜨렸는지 봤다. 경계값과 실패 경로(워커 기동 실패, 셧다운, 재시작, 업그레이드), 회귀 위험, 재현 시나리오를 중점으로 했다.
- 연차(1년차): 코드를 처음 읽는 사람 입장에서 이름·주석·로그 문구가 실제 동작과 맞는지 확인했다. 읽다가 막히는 곳과 명백한 실수를 함께 적었다.
- 결론을 내리기 전에 caller와 반환값 처리를 끝까지 grep으로 따라갔다. 의심만 있고 경로를 닫지 못한 것은 4절로 따로 뺐다.

## 2. 검토 범위와 실제로 읽은 경로

범위는 `git diff a9a0dc78d 0e411f10f`(12 커밋)이고, HEAD는 `0e411f10f`이다.

- slave applier 모듈 (전문)
  - `src/transaction/applier/log_applier_gate.{hpp,cpp}`: init, set_initial_frontier, order_push, advance_frontier, mark_completed, is_satisfied, order_find
  - `log_applier_inflight.{hpp,cpp}`, `log_applier_pending.{hpp,cpp}`, `log_applier_task_queue.{hpp,cpp}`, `log_applier_result_queue.{hpp,cpp}`
  - `log_applier_result.hpp`, `log_applier_task.hpp`, `log_applier_debug.hpp`
  - `log_applier_worker.{hpp,cpp}`: start/join/session/main/run/startup_failed/context/recdes pool
- `src/transaction/log_applier.c`
  - coordinator 함수 전부(710~1560행): drain_ready, wait_for_commit_order_slot, cover_commit, dispatch_task, collect_and_retire, collect_results, record_result, complete_without_task, is_in_recovery_range, wait_until_retired, wait_for_inflight_slot, release_apply_slot, advance_committed_lsa, add_result_stats, store_apply_info_at_interval, retire_results, apply_worker_run/flush/commit_task, test_block_before_commit, init_resources, start/stop_apply_workers, request_shutdown, commit_apply_info
  - `la_find_required_lsa`(2541~2650), `la_get/update_ha_apply_max_committed_lsa`(2868~2990) 및 caller(3349)
  - `la_apply_repl_log`(6967~), `la_flush_repl_items`, `la_commit_transaction`
  - `la_detach_sysop_fragment`, 라벨 holder, `la_coordinator_submit_task`, `process_sysop_end`, `set_commit_dependency`, `process_commit`, `la_log_record_process`(7240~7840)
  - `la_change_state` DONE 보류부(7930~7990), `la_shutdown`(8541~), `la_coordinator_exit`, `la_apply_log_file` 메인 루프(9650~10390)
- master
  - `src/transaction/writeset.{hpp,cpp}` 전문, `writeset_types.hpp`, `writeset_history_map.{hpp,cpp}`
  - `log_manager.c`: sysop end(3990~4100), `log_sysop_fallback_reason`, label append 함수들(4873~5045), 두 commit 경로(5602, 6383)
  - `log_tran_table.c`, `log_impl.h`, `log_append.cpp`, `log_recovery.c`, `log_record.hpp` diff
  - `locator_sr.c` diff 전체: wset 수집, inserter 대기, deadlock 처리
  - `btree.c` deleter 대기, `serial.c` serial 키 수집과 `serial_cache_index_btid`
- 설정·카탈로그: `system_parameter.{c,h}`, `error_code.h`, `cubrid.msg`, `heartbeat.h`, `schema_system_catalog_install.cpp`
- CS 쪽(caller만): `work_space.{c,h}`(`ws_get_repl_obj_count`), `file_io.c` 분기 변경, CMakeLists 4개
- 단위테스트
  - `unit_tests/log_applier/*` 전부
  - `unit_tests/writeset/*`: TEST_CASE 목록 전부, `test_main.cpp`, `CMakeLists.txt`, stress 일부 본문
- 보조 확인
  - 로컬 빌드 산출물 `build_ut_debug/cs/libcubridcs.so`에 `nm -D`를 돌려 심볼 export 여부를 확인했다(M-2 근거).

## 3. 발견 사항

### 3.1 에러

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| E-1 | High | `log_applier.c:1519-1522`, `:1039-1066`, `:1080-1110`, `log_applier_result_queue.cpp:178-183`, `log_applier_worker.cpp:378-392` | 살아 있는 워커가 하나도 없을 때 coordinator가 `la_result_queue_pop`에서 영원히 깨지 않는다 | `la_request_shutdown`은 `la_applier_need_shutdown = true;`만 한다. result queue의 shutdown 신호는 coordinator 자신이 부르는 `la_stop_apply_workers`(1529-1530)에서만 나간다. `wait_until_retired`/`wait_for_inflight_slot`은 타임아웃 없는 `la_result_queue_pop`으로 기다리고 플래그를 보지 않는다 | `ha_apply_worker_count=4`인 slave가 크래시 후 재시작해 recovery range가 비어 있지 않다. 이때 네 워커 모두 `db_restart_sub`에 실패한다(서버 재기동 경합, 접속 한도 등). 마지막 워커가 `request_shutdown`을 불러도 coordinator는 첫 recovery-range 태스크를 dispatch한 뒤 `wait_until_retired`에서 결과를 기다린다. 결과는 오지 않고 applylogdb는 살아 있는 채로 멈춘다. heartbeat가 재시작해 주지도 않고, SIGTERM 핸들러도 플래그만 세우므로 깨우지 못한다 | 경로는 확정, 발생 빈도는 추정 | 신규 |
| E-2 | High | `schema_system_catalog_install.cpp:1096-1097`, `log_applier.c:2895-2914`, `:3349-3353` | `_db_ha_apply_info`에 컬럼 두 개를 추가했지만 마이그레이션이 없다. applier는 시작할 때 이 컬럼을 SELECT하고, 실패하면 기동을 중단한다 | `"SELECT max_committed_lsa_pageid, max_committed_lsa_offset FROM %s ..."` 다음에 `if (res < 0) return res;`, caller에서 `res = la_get_ha_apply_max_committed_lsa (); if (res != NO_ERROR) return res;`. diff 안에서 이 컬럼명이 나오는 곳은 이 두 파일뿐이다. 마이그레이션 스크립트도 disk compatibility 변경도 없다 | develop 빌드로 만든 slave DB에 이 브랜치 바이너리를 올린다. 카탈로그에는 새 컬럼이 없으므로 applylogdb가 시작할 때마다 질의 컴파일 오류로 종료한다. 재시작해도 같은 오류가 나서 복제가 영구히 멈춘다. `log_applier.c:2956` TODO가 "final_lsa로 대체하면 카탈로그 변경 제거"라고 적고 있어 작성자도 인지한 상태다 | 확정(질의와 에러 전파, 마이그레이션 부재) | 신규 |
| E-3 | Low | `log_applier.c:7330-7331`, `:7495-7500`, `:7520-7533`, `:7752-7755`, `:7553-7559`, `la_init`(8447) | 라벨 holder(`la_wset_label_trid`)가 소비되지 않고 남는 경로가 있다 | holder를 비우는 곳은 fragment 경로(7473-7474)와 `set_commit_dependency`(7559, trid만 비움)뿐이다. 다음 경로는 holder를 그대로 둔다: 라벨이 있지만 item이 없는 SYSOP_END(`complete_without_task`), committed_lsa 이하 SYSOP_END(skip), committed_lsa 이하 COMMIT(`la_free_repl_items_by_tranid`만 호출). `la_init`도 holder를 초기화하지 않는다 | 라벨이 붙은 serial sysop에 item이 없으면 holder가 trid X로 남는다. 같은 X의 COMMIT에 master가 라벨을 쓰지 못했다면(주석 7584-7586이 말하는 경우) 이 commit은 남은 sysop 라벨을 자기 라벨로 쓴다. 그러면 "라벨 없음이면 직전 commit 전부를 기다린다" 폴백(7570-7574)을 건너뛴다. trace에도 `has_label=1`로 잘못 찍힌다. 실제 잘못된 순서가 나려면 라벨 누락까지 겹쳐야 하므로 영향은 낮다 | holder 미초기화는 확정, 정합성 영향은 추정 | 신규 |
| E-4 | Low | `log_applier.c:445`, `:1521`, `log_applier_task_queue.cpp:197`, `log_applier_result_queue.cpp`(`get_count`) | 스레드 사이에 공유하는 값을 동기화 없이 읽고 쓴다 | `static bool la_applier_need_shutdown`을 워커 스레드가 `la_request_shutdown`으로 쓰고 coordinator가 루프 조건으로 읽는다. volatile도 atomic도 아니다. queue의 `get_count`는 락 없이 읽는다(상태 출력 용도라고 주석에 있음) | TSan 빌드에서 data race로 보고된다. 표준상 UB라서 최적화 수준에 따라 coordinator가 플래그 변화를 늦게 볼 수 있다. x86 실측에서 문제가 될 가능성은 낮다 | 확정(race 존재), 영향은 추정 | 신규 |

**E-1 상세.**
- `la_worker_startup_failed`는 마지막 워커가 빠질 때 `request_shutdown`을 부른다. 이 콜백은 플래그만 세운다.
- 플래그를 보는 대기는 `la_coordinator_wait_for_commit_order_slot`(100ms timedwait 루프) 하나뿐이다. `la_coordinator_wait_until_retired`와 `la_coordinator_wait_for_inflight_slot`은 결과가 올 때까지 무기한 블록한다.
- recovery range 직렬 경로(7387-7411)는 태스크마다 `wait_until_retired`를 부른다. 그래서 재시작 직후에 이 조건을 가장 쉽게 밟는다.
- 수정 방향(제안):
  - `la_request_shutdown`에서 result queue에 shutdown 신호를 보내 coordinator를 깨운다. 또는 두 대기 함수가 `la_result_queue_wait_for_result(timeout)`과 플래그 검사를 같이 쓰게 한다.
  - "live worker 0" 상태를 coordinator가 직접 볼 수 있는 API를 둔다.
- 재현(제안):
  - `ha_apply_worker_count>=2`, recovery range가 있는 상태를 만든다.
  - fault injection으로 `db_restart_sub`가 실패하게 하거나 `max_clients`를 조이고 applylogdb를 재기동한다.
  - 프로세스가 살아 있는데 `la_coordinator_exit` 로그가 없는지 확인한다.

**E-2 상세.**
- QA 회귀 관점에서는 기존 HA 쌍에서 바이너리만 교체하는 업그레이드 시나리오가 깨진다.
- `la_insert_ha_apply_info`/`la_update_ha_apply_info_start_time`은 성공한 뒤에 `la_get_ha_apply_max_committed_lsa`가 실패해 시작이 중단된다. 실패 지점이 눈에 띄지 않는다.
- 운영자가 테스트 전에 slave를 재생성하지 않았다면 첫 런에서 바로 드러난다. 이 브랜치의 HA 테스트가 매번 DB를 새로 만드는 절차라면 테스트로는 잡히지 않는다.

### 3.2 모듈화

| ID | 등급 | 위치 | 내용 | 근거 | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| M-1 | Medium | `log_applier.c:710-1560`, `:7255-7660`, `unit_tests/log_applier/CMakeLists.txt:20-23`, `log_applier_gate.cpp:275-278` | 스케줄링을 결정하는 핵심 로직이 11,131행짜리 `log_applier.c` 안의 static 함수로 남아 있어 단위테스트가 하나도 없다 | 해당 함수: `la_coordinator_set_commit_dependency`(라벨, fragment 하한, 라벨 없음 폴백), `submit_task`(단일 워커 / recovery range 직렬 / park 판단), `drain_ready`, `retire_results`, `cover_commit`, `la_detach_sysop_fragment`(long trans 분기). CMake 주석은 "The workers and the coordinator itself need a server connection and are not unit tested here"라고 적고 있다. gate TODO도 "parent/child ordering ... with dedicated tests"가 아직 없다고 인정한다 | `set_commit_dependency`의 폴백 조건(`task->has_items && !has_label && la_gate_get_order_tail(...)`)이 바뀌어도 단위테스트는 통과한다. 회귀는 HA 실측에서 slave 불일치(무성 skip)로만 드러나고 원인 추적 비용이 크다 | 확정 | 신규 |
| M-2 | Low | `unit_tests/log_applier/CMakeLists.txt:20-24, 50-54` | "not exported from cubridcs"라는 주석이 사실과 다르다. 테스트가 같은 소스를 한 번 더 컴파일하므로 심볼이 두 벌 생긴다 | `nm -D --defined-only build_ut_debug/cs/libcubridcs.so` 결과에 `la_gate_init`, `la_inflight_push` 등이 `T`로 나온다. CS CMake에는 version script나 visibility 설정이 없다 | 지금은 ELF interposition으로 실행 파일 쪽 사본이 먼저 묶여서 동작한다. 나중에 cubridcs 안의 코드가 이 함수를 내부 호출하는 경로가 테스트에 들어오면 상태가 어느 사본(file static)에 쌓이는지 혼동된다. 링크 옵션(`-Bsymbolic` 등)이 바뀌면 테스트가 엉뚱한 사본을 검사한다 | 확정(export), 영향은 추정 | 신규 |
| M-3 | Low | `log_applier.c:1210`, `:7330-7331` | in-process 재시작 때 초기화되지 않는 함수 static과 파일 static이 있다 | `static UINT64 last_store_ns = 0;`(함수 안), 라벨 holder 두 개. 반면 gate, inflight, queue는 init 함수가 static을 다시 세팅하고 주석에도 그 이유를 적었다 | applier가 같은 프로세스에서 재시작하면 직전 런의 저장 시각과 holder가 이어진다. 저장 주기가 첫 retire에서 한 번 건너뛰는 정도로 영향은 작다. 다만 "init이 모든 상태를 리셋한다"는 다른 모듈의 규칙과 어긋나고, 이 함수들을 테스트로 빼낼 때 테스트끼리 격리되지 않는다 | 확정 | 신규 |

**M-1 상세(제안).**
- `set_commit_dependency`와 `submit_task`의 결정부는 gate와 pending과 비슷하게 순수 상태 함수로 떼어낼 수 있다. 입력은 (task, gate 상태, holder, worker_count, recovery range)로 정리된다.
- 그러면 다음 시나리오를 서버 없이 Catch2로 고정할 수 있다.
  - 라벨이 없는 commit
  - fragment 뒤의 outer commit
  - recovery range 경계(`last_committed_lsa`와 같음, 바로 위, `recovery_boundary_lsa`와 같음)
  - 워커 1개 FIFO
  - task queue가 꽉 찬 상태에서의 park
- 지금 테스트가 덮는 것은 컨테이너(ring, list, queue)의 동작뿐이다. 이 브랜치의 정확성을 좌우하는 것은 그 위의 규칙이다.

### 3.3 아키텍처

| ID | 등급 | 위치 | 내용 | 근거 | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| A-1 | Low | `serial.c:1219-1250`, `log_manager.c:4038-4072` | serial update가 수집한 writeset 키는 같은 sysop의 SYSOP_END에서 항상 버려진다. 수집 실패는 nextval을 실패시킨다 | serial 수집은 `lock_mode != X_LOCK` 블록 안에서 일어나는데, 이 블록은 `log_sysop_start`/`log_sysop_commit` 안쪽이다. 같은 블록의 `repl_end_flush_mark`가 item을 NEED_FLUSH로 만든다. 그래서 `log_record->type == LOG_SYSOP_END_COMMIT && repl_item_count > 0`이 성립하고 `wset_discard_sysop_keys (tdes, sysop_key_begin)`이 실행된다. 반면 `wset_add_write_key (...) != NO_ERROR`이면 `goto exit_on_error`로 sysop을 abort한다. `BTID_IS_NULL (&serial_Cached_btid)` 분기는 바깥 트랜잭션 전체를 `WSET_FALLBACK_STATEMENT_REPLICATION`으로 overflow 처리한다 | (1) 키 수집 메모리가 부족하면 결과에 쓰이지도 않는 키 때문에 `NEXT_VALUE`가 실패한다. (2) `serial_Cached_btid`는 boot 때(`boot_sr.c:2533`) 채워지므로 NULL 분기는 사실상 도달하지 않는다. 도달하면 nextval 한 번에 사용자 트랜잭션 전체가 commit-order로 강등되고 commit 시 history가 비워진다. 사유 이름(STATEMENT_REPLICATION)도 실제 원인과 다르다 | 폐기 경로는 확정(active worker 트랜잭션 기준), (1)의 발생은 추정 | 신규 |
| A-2 | Low | `log_applier.c:1415-1457` | 테스트 전용 크래시 주입 훅이 release 빌드에 들어 있고, 매 commit마다 `getenv`를 호출한다(클래스가 일치하면 한 번 더) | `const char *block_class = getenv ("CUBRID_HA_TEST_BLOCK_CLASS");` 다음에 `usleep (block_msec * 1000)`이 온다. TODO가 직접 "Test-only code. Remove it"이라고 적고 있다 | 운영 환경에 이 변수가 남아 있으면(테스트 스크립트를 재사용한 경우 등) 해당 클래스를 적용할 때마다 워커가 기본 60초 멈춘다. DONE 보류와 drain timeout(30초, 6705행)이 겹치면 failover가 지연되거나 applier 재시작이 반복된다 | 코드는 확정, 운영 발생은 추정 | 신규 |

### 3.4 리팩토링 (가독성, 명명, 주석, 테스트 구조)

| ID | 등급 | 위치 | 내용 | 근거 | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| R-1 | Medium | `unit_tests/writeset/test_writeset_stress.cpp:128,214,256,300,337,395,434,552,590,629`, `test_writeset_bench.cpp:35,118,165`, `test_writeset_concurrency.cpp:267,277`, `writeset.cpp:1412`, `:597` | stress와 benchmark 케이스가 숨김 태그가 아니어서 기본 실행에 포함된다. 핵심 경로 일부에는 테스트가 없다 | 태그가 `"[stress]"`, `"[benchmark]"`이다. Catch2는 `[.]`나 `[.xxx]`만 숨기므로 인자 없이 `test_writeset`을 돌리면 B5(대형 map에 다중 스레드, 대형 commit)까지 모두 실행된다. `wset_abort_after_lsa`(savepoint/문장 롤백 시 키 제거)를 호출하는 테스트가 없다(grep 0건). NULL unique 키 수집 경로(597행 주석)도 테스트가 없다 | CI에서 `UNIT_TESTS=ON`으로 전체를 돌리면 시간이 길어지고, 머신 부하에 따라 시간 기반 측정이 흔들린다. `wset_abort_after_lsa`의 LSA 비교(`LSA_GT (&e.lsa, start_lsa)`)가 회귀하면 롤백된 문장의 키가 남거나 살아남아야 할 키가 사라진다. 앞의 경우는 과직렬화, 뒤의 경우는 누락이다. 키가 사라지면 slave에서 순서가 역전되는데, 이를 잡을 테스트가 없다 | 확정 | 신규 |
| R-2 | Low | `test_log_applier_gate.cpp` 전체, `test_log_applier_queues.cpp`, `log_applier_result_queue.cpp:172-197`, `log_applier_task_queue.cpp:155` | gate ring의 wraparound와 `la_result_queue_pop`(블로킹)이 테스트되지 않는다. 두 queue의 shutdown 의미가 다르다는 점도 테스트로 고정되지 않았다 | gate 테스트는 capacity 8에 3개만 push한다. head가 돈 뒤 wrap된 상태에서 `la_gate_order_find`의 이진 탐색(`la_gate_order_at`의 modulo)을 검증하는 케이스가 없다. `la_result_queue_pop`은 shutdown 뒤에도 남은 결과를 반환하지만(`if (count == 0)`), `la_task_queue_pop`은 shutdown이면 남은 태스크가 있어도 ER_FAILED를 돌려준다 | ring 인덱스 계산을 바꾸다 wrap 경계에서 `mark_completed`가 엔트리를 못 찾게 되면 frontier가 멈춘다. 그러면 DONE 보류 뒤 drain timeout으로 재시작이 반복되는데, 단위테스트는 통과한다. queue 의미가 바뀌는 회귀도 잡히지 않는다 | 확정(미커버) | 신규 |
| R-3 | Low | `log_applier.c:434, 872, 1005, 1249, 1259, 7505, 7512, 7523, 7529, 7638, 7764, 7819, 7825, 9590` | coordinator가 남기는 trace와 에러 로그 문구가 "reader"로 되어 있다 | `"[WSET] reader schedule ..."`, `"applylogdb reader exit: ..."`. 반면 함수명은 `la_coordinator_*`이다 | 로그로 장애를 분석하는 사람이 reader를 별도 스레드로 오해한다. 로그 grep 키와 코드 명칭이 달라 추적이 어렵다 | 확정 | 신규 |
| R-4 | Low | `log_applier.c:7965`, `:10348` | `pending=%d`에 개수가 아니라 bool이 찍힌다 | `"... (pending=%d dispatch=%d order=%d ..." , (int) !la_pending_is_empty (), la_inflight_get_count (), ...`. 바로 옆 필드들은 개수다 | DONE 보류 로그에서 `pending=1`을 "parked 1건"으로 읽게 된다. 실제로는 수천 건일 수 있어 원인 판단이 틀어진다 | 확정 | 신규 |
| R-5 | Low | `writeset.cpp:999-1016` vs `:1017`, `:1121`, `:1373` | 함수 헤더 주석과 실제 함수 이름이 다르다. 항상 0으로 호출되는 범위 매개변수가 있다 | 헤더는 `wset_find_dependency_from_history - ...`인데 그 아래 함수는 `wset_find_dependency_in_range (tdes, size_t begin, ...)`이다. 호출은 `(tdes, 0, ...)` 한 곳뿐이다. `wset_publish_with_capacity (tdes, 0, size, ...)`도 같다. `wset_select_candidate`(968)에는 헤더가 없다 | 처음 읽는 사람이 부분 범위 probe나 publish를 쓰는 경로가 있다고 오해하고 그 경로를 찾게 된다 | 확정 | 신규 |
| R-6 | Low | `btree.c:27558`, `:27915` | 삭제자(deleter) MVCCID를 `btree_key_wait_for_insert_mvccid`에 넘겨 재사용한다 | `return btree_key_wait_for_insert_mvccid (thread_p, BTREE_MVCC_INFO_DELID (&mvcc_info), ...)`. 함수 헤더에 "Also waits for a deleter"를 덧붙였지만 이름과 매개변수명은 insert 그대로다 | 이 함수 안의 insert 전용 가정(trace 문구, 향후 수정)이 deleter 경로에도 적용되는데, 리뷰어나 수정자가 놓치기 쉽다 | 확정 | 신규 |
| R-7 | Low | `log_applier_gate.cpp:59`, `:185`, `:37` | gate 주석끼리 말이 다르고, 사실과 다른 주석이 있다 | ring 주석은 "The coordinator stops reading the log while the ring is full"이라고 하고, push 주석은 "The ring cannot actually fill (see la_Gate_order_ring)"이라고 한다. include 주석 `system_parameter.h /* PRM_ID_ER_LOG_DEBUG, read by LA_DEBUG_LOG */`도 맞지 않는다. 매크로는 `er_log_debug`를 부를 뿐 PRM을 읽지 않는다 | 처음 읽는 사람이 ring full이 정상 상태인지 버그인지 판단하지 못한다. push 실패를 정상 흐름으로 처리하는 수정이 들어갈 수 있다 | 확정 | 신규 |
| R-8 | Low | `test_log_applier_common.hpp:32-33`, `test_writeset_*.cpp` TEST_CASE 이름 | 테스트가 enum 값을 하드코딩하고, 테스트 이름에 외부 실험 번호를 쓴다 | `static const int TEST_RECTYPE_COMMIT = 17;`, `TEST_RECTYPE_SYSOP_END = 20;`. `"A1: ..."`, `"B3s: ..."`, `"F0: ..."` | `log_record.hpp`의 enum 값이 바뀌면 테스트는 의미 없는 rectype으로 돌면서도 통과한다. A1/B2/F5 같은 번호는 외부 실험 계획서를 봐야 뜻을 알 수 있다(자체 완결형 주석 규칙에 어긋남) | 확정 | 신규 |

## 4. 미검증 의심

- **pending list 해제 비용이 O(n·k)일 수 있다.** 근거: `log_applier_pending.cpp:98-131`.
  - `la_pending_pop_ready`는 매번 head부터 선형 탐색한다. `drain_ready`는 이것을 task queue가 찰 때까지 반복한다.
  - commit-order capacity는 워커 32개 기준 32,768이다. 긴 트랜잭션 하나가 frontier를 막는 동안 park가 수만 건 쌓였다가 한꺼번에 풀리면, 준비되지 않은 앞쪽 노드를 매번 다시 훑게 된다.
  - 실측하지 않았다. benchmark가 필요하다.
- **commit 두 경로의 조건이 다르다.**
  - `log_commit_local`(log_manager.c:5600)은 `tdes->is_active_worker_transaction ()`을 검사하고, 2PC commit 경로(6381)는 검사하지 않는다.
  - 2PC나 시스템 트랜잭션이 라벨이나 publish를 다르게 받을 수 있는지는 확인하지 못했다.
- **`la_coordinator_advance_committed_lsa`는 retire할 때만 불린다.** 근거: log_applier.c:1149-1166, 1264.
  - `complete_without_task`만으로 frontier가 움직인 경우(item 없는 라벨 sysop만 연속으로 올 때) committed_lsa가 다음 retire 때까지 뒤처진다.
  - 재시작 범위가 조금 넓어지는 것 말고 영향이 있는지는 확인하지 못했다.
- **`file_io.c`의 `fileio_os_read/write` 분기 변경.**
  - Linux의 CS/SA 빌드가 `lseek+read/write` 대신 `pread/pwrite`를 쓰게 됐다. applier 워커가 동시에 로그를 읽으려면 필요한 변경으로 보인다.
  - 이 브랜치와 무관한 SA 유틸리티 중 파일 오프셋 이동에 기대는 caller가 있는지는 범위 밖이라 보지 않았다.
- **단위테스트의 `sleep_for(50ms)` 동기화.**
  - `test_log_applier_queues.cpp`의 "wakes a waiting worker" 류 케이스는 대기자가 실제로 cond wait에 들어갔는지 보장하지 않는다.
  - 지금 assertion은 그와 무관하게 성립해서 flaky하지는 않다. 다만 "대기 중 깨움"을 검증한다는 테스트 이름과 실제 검증 내용이 다를 수 있다.

## 5. 총평

등급별 건수는 High 2, Medium 2, Low 13으로 모두 17건이다.

- 컨테이너 모듈(ring, inflight, pending, queue)은 작고 읽기 쉽다. 각 함수의 주석이 동작과 맞으며 단위테스트도 정상 경로를 잘 덮는다. worker 수명 관리와 startup 실패 처리, recdes pool의 부분 할당 해제(기존 누수 수정)도 깔끔하다.
- QA 관점에서 가장 큰 위험은 두 가지다.
  1. **실패 경로의 멈춤(E-1).** 워커가 모두 기동에 실패하면 coordinator가 깨어날 수단이 없다. 재시작 직후 recovery range에서 가장 쉽게 밟는 조건이라 실제 운영의 서버 재기동 경합에서 재현될 수 있다.
  2. **업그레이드 회귀(E-2).** 카탈로그 컬럼을 추가했지만 마이그레이션이 없어서, 기존 slave DB에서는 applylogdb가 아예 시작하지 못한다.
- 테스트 구조의 빈틈(M-1, R-1)도 크다. 정확성을 좌우하는 스케줄링 규칙(라벨 폴백, fragment 하한, recovery range 직렬화)과 master의 롤백 키 제거(`wset_abort_after_lsa`)에 단위테스트가 없다. 회귀는 HA 실측에서 "무성 skip"으로만 드러난다. writeset stress 테스트가 기본 실행에 섞여 있어 CI에서 쓰기도 어렵다.
- 나머지는 이름·로그 문구(reader, `pending=%d`), 주석 불일치, 테스트 전용 훅 같은 가독성과 유지보수 항목이다.

가장 중요한 3건:
1. E-1 (High): 워커가 모두 기동에 실패하면 `request_shutdown`이 플래그만 세운다. coordinator는 `wait_until_retired`/`wait_for_inflight_slot`의 `la_result_queue_pop`에서 영원히 블록하고, SIGTERM으로도 깨지 않는다.
2. E-2 (High): `_db_ha_apply_info`에 `max_committed_lsa_*` 컬럼을 추가했지만 마이그레이션이 없다. 기존 slave DB에서는 시작 시 SELECT가 실패해 applylogdb가 매번 기동에 실패하고 복제가 영구 정지한다.
3. M-1 (Medium): coordinator의 스케줄링 결정 로직 전체가 `log_applier.c` static 함수라 단위테스트가 0건이다. 컨테이너 테스트만으로는 의존성과 순서 규칙의 회귀를 잡지 못한다.
