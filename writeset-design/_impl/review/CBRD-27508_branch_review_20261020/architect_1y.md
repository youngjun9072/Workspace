# CBRD-27508 브랜치 리뷰: 아키텍트 1년차

## 1. 리뷰어 관점

- 역할(아키텍트): master의 writeset 생성(키 수집, 라벨, history)과 slave 적용(라벨 해석, gate, coordinator와 worker) 사이의 설계가 서로 맞는지 봤다. 모듈 경계와 전역 상태, 결합도, 기존 CUBRID 구조(로그 레코드 타입, 트랜잭션 기술자, 파라미터, CS 빌드 플래그)와 맞는지도 확인했다.
- 연차(1년차): 코드를 처음 읽는 입장에서 읽었다. 이름이나 주석이 실제 동작과 어긋나는 곳, 같은 일을 하는 코드가 여러 군데 흩어진 곳, 실패 경로가 조용히 삼켜지는 곳을 중점으로 봤다.
- 범위: `a9a0dc78d..0e411f10f`(HEAD = 0e411f10f). 행 번호는 모두 HEAD 기준이다.

## 2. 검토 범위와 실제로 읽은 경로

- master writeset
  - `src/transaction/writeset.hpp`, `writeset.cpp` 전문: 해시(`wset_fnv1a`, `wset_string_hash`, `wset_midxkey_hash`), 수집(`wset_add_write_key`, `wset_add_ref_key`, `wset_push_hash`, `wset_fallback_to_commit_order`), 의존 탐색(`wset_find_dependency_in_range`, `wset_find_dependency_from_history`, `wset_find_sysop_fallback_dependency`), 게시(`wset_publish_keys`, `wset_publish_with_capacity`, `wset_clear_overflow_history`, 용량 예약/해제), `wset_discard_sysop_keys`, `wset_abort_after_lsa`, `wset_raise_history_start`
  - `writeset_types.hpp`, `writeset_history_map.{hpp,cpp}` 전문
  - `log_impl.h`(tdes 필드, `wset_mark`), `log_record.hpp`(`LOG_DUMMY_WSET_LABEL`), `log_append.cpp`, `log_recovery.c`(4개 case), `log_tran_table.c`(init/clear/copy_to, history init/final)
  - `log_manager.c`: `log_initialize_internal`의 RESTART 하한, `log_sysop_start`, `log_sysop_commit_internal`, `log_sysop_abort`, `log_append_sysop_end_internal`, `log_sysop_fallback_reason`, `log_append_wset_label_and_sysop_end`, `log_append_repl_info_and_commit_log`, `log_append_wset_label_with_lock`, `log_commit_local`, `log_complete_for_2pc`. 비교를 위해 `log_dump_record`, CDC, `flashback.c`의 레코드 타입 switch도 읽었다.
  - `locator_sr.c`: `locator_wset_error`, `locator_wset_trace_key_source`, `locator_wset_collect_fk_ref`, `locator_add_or_remove_index_internal`·`locator_update_index`의 수집 블록, `locator_is_inserter_committing`, `locator_lock_and_get_object_internal`의 대기, `xlocator_repl_force`의 deadlock 처리
  - `btree.c`(`btree_is_deleter_committing`, `btree_trace_deleter_wait`, `DELETE_RECORD_DELETED` 두 곳), `serial.c`(`serial_update_serial_object`), `replication.c`(`repl_log_insert_statement`, `repl_log_abort_after_lsa`), `system_parameter.{c,h}`, `error_code.h`, `heartbeat.h`
- slave applier
  - `src/transaction/applier/*` 전문: gate, inflight, pending, task_queue, result_queue, worker, task/result/debug 헤더
  - `log_applier.c`: 전역과 선언부(440~670), `la_coordinator_*` 전부(700~1560), `la_get_wset_label`, `la_detach_sysop_fragment`, 라벨 holder와 `la_coordinator_submit_task`/`process_sysop_end`/`set_commit_dependency`/`process_commit`, `la_log_record_process`, `la_change_state`, `la_init`의 worker 수 결정, `la_shutdown`, `la_apply_log_file` 본체(9648~10425), `la_update_query_execute*`. `log_applier.h`도 읽었다.
- 테스트: `unit_tests/log_applier/CMakeLists.txt`, `unit_tests/writeset/CMakeLists.txt`, `test_writeset_stress.cpp`의 B2~B6, `test_writeset_common.hpp`
- CS 쪽(호출부만): `CMakeLists.txt`(`MULTI_CONN_TO_A_SERVER`), `cs/`·`sa/`·`cubrid/` CMakeLists, `work_space.{c,h}`(`ws_get_repl_obj_count`), `file_io.c` diff, `la_worker_start_session`/`la_worker_end_session`의 `db_restart_sub`/`db_shutdown_sub` 호출

## 3. 발견 사항

### 3.1 에러

| ID | 등급 | 위치 | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| E1 | High | `log_applier.c:4638-4666`, `:7815-7818`, `:7553-7564` | 라벨 본문을 읽지 못해도 "라벨 있음, 의존 없음"으로 처리된다 | `la_get_wset_label`은 `LSA_SET_NULL (dependency_seq)` 뒤 읽기 실패 시 `return`(void). 호출부는 결과와 무관하게 `la_wset_label_trid = lrec->trid` | 라벨 데이터가 다음 페이지로 넘어갔는데 그 페이지를 가져오지 못하면 dependency가 NULL로 남는다 → commit의 `has_label = true`, `dependency_seq = NULL` → `la_gate_is_satisfied`가 즉시 true → 충돌하는 선행 트랜잭션과 병렬로 적용된다 → 순서 위반(UPDATE/DELETE 대상 없음, 무성 skip 가능) | 코드 경로는 확정. 페이지 읽기 실패 빈도는 추정 | 신규 |
| E2 | High | `log_applier.c:1039-1068`, `:1080-1109`, `applier/log_applier_worker.cpp:379-392`, `applier/log_applier_result_queue.cpp:172-197` | 모든 worker가 시작에 실패하면 coordinator가 결과 큐에서 영원히 대기한다 | `la_coordinator_wait_until_retired`·`wait_for_inflight_slot`은 `la_result_queue_pop`(무기한 `pthread_cond_wait`)만 부르고 shutdown 플래그를 보지 않는다. `la_worker_startup_failed`는 마지막 worker일 때 `request_shutdown ()`(플래그만 설정)을 부르고 큐는 깨우지 않는다 | worker_count>1로 재시작했는데 모든 worker의 `db_restart_sub`가 실패한다(서버 재기동 중 등) → 첫 commit이 recovery range에 있어 `submit_task`가 dispatch한 뒤 `wait_until_retired`에 들어간다 → 결과를 줄 worker가 없고, 큐를 깨우는 `la_result_queue_signal_shutdown`은 coordinator 자신만 부를 수 있다 → applylogdb가 SIGTERM에도 멈춘 채 살아 있고 복제가 정지한다 | 대기 경로는 확정. 전 worker 시작 실패 조건은 추정 | 신규 |
| E3 | Medium | `log_tran_table.c:1622`, `:1706`, `writeset.cpp:520`, `:559` | 트랜잭션이 끝나도 tdes의 `wset_hashes` 용량이 반환되지 않는다 | 재사용 시 `tdes->wset_hashes.clear ()`만 한다(capacity 유지). overflow 경로만 `swap`으로 해제한다. 한도 = `history_size`(기본 1,000,000) | 한 세션이 키 99만 개짜리 트랜잭션을 한 번 커밋한다 → 엔트리 24B × 99만 ≈ 24MB가 그 tdes에 남는다. 큰 배치를 돌린 세션이 수백 개면 서버 상주 메모리가 GB 단위로 남는다 | clear 시 capacity 유지는 확정. 실제 규모는 추정 | 신규 |
| E4 | Low | `log_applier.c:8541-8548`, `:7268`, `:1128-1133` | in-process 재시작 때 serial fragment(`LA_APPLY`)가 새어 나간다 | fragment는 `la_detach_sysop_fragment`에서 별도로 malloc되고, retire 때(`la_coordinator_release_apply_slot`)만 해제된다. `la_shutdown`은 `la_pending_clear`(노드만 해제)를 부르고 inflight·task queue는 정리하지 않는다 | 서버 다운으로 applier가 같은 프로세스 안에서 재시작한다 → 아직 retire되지 않은 SYSOP_END 태스크의 fragment와 그 item이 해제되지 않는다. 재시작이 반복될수록 누적된다 | 확정 | 신규 |
| E5 | Low | `log_applier.c:445`, `:1519-1522`, `:9854` | `la_applier_need_shutdown`(plain `bool`)를 여러 스레드가 동기화 없이 쓴다 | worker 스레드가 `la_request_shutdown`을 통해 쓰고 coordinator 루프가 읽는다. atomic도 volatile도 아니다 | C/C++ 표준상 data race(UB)다. 지금은 루프 안에 함수 호출이 있어 다시 읽히지만, 최적화가 바뀌면 coordinator가 종료 요청을 놓칠 수 있다 | race는 확정. 실제 오동작은 추정 | 신규 |
| E6 | Low | `log_manager.c:7347-7471` | `log_dump_record`에 `LOG_DUMMY_WSET_LABEL` case가 없다 | `log_recovery.c`·`log_append.cpp`에는 새 타입을 추가했지만 dump switch에는 없다. 그래서 `default`로 가서 `"Unknown record type"`을 출력한다 | diagdb 로그 덤프에서 복제되는 commit마다 "Unknown record type = 53"이 찍힌다. 다음 레코드 위치는 forw_lsa로 계산하므로 덤프가 멈추지는 않지만, 운영자가 손상으로 오인할 수 있다 | 확정 | 신규 |

**E1 상세.** `la_coordinator_set_commit_dependency` 주석(7545~7548)은 라벨이 없을 때 충돌을 알 수 없으므로 "이전 commit 전부를 기다린다"고 정했다. 실제로 7574~7578이 order tail로 하한을 올린다. 그런데 라벨 레코드는 있지만 본문을 읽지 못한 경우는 이 보수적 경로로 가지 않는다. master가 정상적으로 쓴 NULL 라벨(충돌 없음)과 구분할 수도 없다. `la_get_wset_label`이 에러를 반환하게 하고, 실패하면 `la_wset_label_trid`를 설정하지 않거나(라벨 없음 경로) applier를 멈춰야 설계 원칙과 맞는다. master 쪽은 라벨 append가 실패하면 라벨 없이 남아 slave가 보수적으로 처리하는데, slave 쪽 읽기 실패는 반대로 가장 공격적인 쪽(의존 없음)으로 떨어진다. 이 비대칭이 문제다.

**E2 상세.** 같은 대기라도 `la_coordinator_wait_for_commit_order_slot`(737~761)은 `la_applier_need_shutdown`을 확인하고 100ms 타임아웃 대기(`la_result_queue_wait_for_result (100)`)를 쓴다. 나머지 두 대기 함수만 무기한 대기다. 함께 확인한 사실은 이렇다. worker 시작은 비동기다(`la_worker_start` 주석 72~75 "The caller does not wait for the workers to open their sessions"). 시그널 핸들러 `la_shutdown_by_signal`도 플래그만 세운다. 따라서 이 상태에서는 외부에서 정상 종료시킬 방법이 없다. 두 blocking 대기를 플래그 확인과 timed wait로 바꾸거나, `request_shutdown`이 결과 큐의 shutdown까지 신호하도록 바꾸는 것을 제안한다.

**E3 상세.** `wset_fallback_to_commit_order`는 `std::vector<LOG_WSET_ENTRY> ().swap (tdes->wset_hashes)`로 메모리를 반환하므로, 작성자도 반환이 필요하다는 점은 알고 있다. 정상 커밋 경로(`logtb_clear_tdes`)도 같은 방식으로 하거나, 일정 크기를 넘으면 `shrink_to_fit`하는 것을 제안한다.

### 3.2 모듈화

| ID | 등급 | 위치 | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| D1 | Medium | `log_applier.c:700-1560`, `:7321-7652`, `unit_tests/log_applier/CMakeLists.txt` | 스케줄링 정책(coordinator)이 `log_applier.c`에 남아 있어 단위 테스트할 수 없다 | `applier/`로는 자료구조(gate, inflight, pending, 큐)만 옮겼다. `la_coordinator_submit_task`, `set_commit_dependency`, `process_sysop_end`, recovery range 직렬화, retire/committed_lsa 전진은 `log_applier.c`의 static 함수와 `la_Info`에 묶여 있다. 테스트 CMake 소스에 `log_applier.c`는 없다 | 가장 위험한 판단(라벨 없는 commit의 하한, fragment와 outer commit 순서, recovery range 진입과 해제, E1·E2 같은 경로)은 HA 실측으로만 검증된다. 회귀가 생겨도 단위 테스트로는 잡히지 않는다 | 확정 | 신규 |
| D2 | Low | `locator_sr.c:7978-7979`, `:8575-8577`, `:8748-8749` | writeset 수집 여부를 정하는 조건식이 세 곳에서 조금씩 다르게 반복된다 | `datayn && need_replication && !LOG_CHECK_LOG_APPLIER && log_does_allow_replication ()` / `repl_info != NULL && repl_info->need_replication == true && ...` / 같은 식의 변형. 그런데 `wset_add_*_key`는 안에서 다시 `wset_overflow`와 `suppress_replication`을 본다 | 수집 조건을 하나 바꿀 때(예: master 측 끄기 스위치, A4) 세 곳과 writeset 내부를 모두 맞춰야 한다. 하나라도 빠지면 키가 빠진다(= 순서 위반) | 확정 | 신규 |
| D3 | Low | `locator_sr.c:7712-7724`, `writeset.cpp:668-681` | 같은 이름의 에러 헬퍼가 두 벌 있고 의미가 다르다 | `locator_wset_error`는 `er_errid ()`가 있으면 그것을 반환한다. `wset_error`는 인자 `error`와 `ER_FAILED`를 따로 처리한다 | 같은 "키 생성 실패"인데 어느 층에서 실패했는지에 따라 반환 규칙이 다르다. 다음 수정자가 한쪽만 고치기 쉽다 | 확정 | 신규 |
| D4 | Low | `log_applier.c:1039-1068`, `:1080-1109` | 두 대기 함수의 본문이 사실상 같다 | 루프 조건(`count > 0`와 `count >= capacity`)만 다르고 pop→record→advance→retire 순서는 동일하다 | E2를 고칠 때 한쪽만 고치기 쉽다. 이미 세 번째 대기 함수(`wait_for_commit_order_slot`)는 다른 정책(플래그+timed wait)을 쓰고 있다 | 확정 | 신규 |
| D5 | Low | `applier/log_applier_task_queue.cpp:31`, `applier/log_applier_result_queue.cpp:29`, `applier/log_applier_worker.cpp:26`, `applier/log_applier_pending.cpp:32` | 하위 모듈이 상위나 형제 모듈 헤더에 기대고 있다 | task queue는 상수 하나 때문에 `log_applier_worker.hpp`를 포함한다. worker는 `LA_IS_FLUSH_ERROR` 때문에 상위 `log_applier.h`를 포함한다. pending은 `la_gate_is_satisfied`를 직접 호출한다(판정 함수를 인자로 받지 않음). 모든 모듈이 파일 static 싱글턴이다 | 모듈을 따로 테스트하거나 재사용하기 어렵다. 예를 들어 pending 테스트는 gate 전역 상태를 먼저 세팅해야 한다 | 확정 | 신규 |

**D1 상세.** 작성자도 리팩토링 방향을 TODO로 남겨 두었다(`writeset_history_map.hpp`의 "Promote the history map to a standalone history-store object"). slave 쪽에도 같은 방향이 필요하다. 다음과 같이 나누면, 이번 리뷰에서 나온 E1·E2와 미검증 U1을 단위 테스트로 재현할 수 있다.

- `la_coordinator_*`를 `applier/log_applier_coordinator.cpp`로 분리한다.
- 입력은 "레코드 이벤트(label/commit/sysop_end)"로, 출력은 "dispatch/park"로 바꾼다.
- `la_Info`와 DB 접근(`la_update_ha_apply_max_committed_lsa` 등)은 콜백으로 주입한다.

### 3.3 아키텍처

| ID | 등급 | 위치 | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| A1 | Medium | `serial.c:1219-1251`, `log_manager.c:4036-4073`, `writeset.cpp:1386-1397` | serial 키 수집은 결과가 쓰이지 않고 부작용만 남는다 | serial 갱신(`lock_mode != X_LOCK`)은 sysop 안에서 `repl_log_insert` 후 키를 수집한다. 그런데 `log_sysop_commit_internal`은 repl item이 있는 SYSOP_END를 commit-order로 라벨링하고 `wset_discard_sysop_keys`로 그 키를 버린다. 또 `BTID_IS_NULL (&serial_Cached_btid)`이면 `wset_fallback_to_commit_order (serial_tdes, WSET_FALLBACK_STATEMENT_REPLICATION)` | (1) 수집한 serial 키는 항상 버려지므로 해시·할당 비용만 든다. (2) 캐시 BTID가 없을 때 sysop만이 아니라 바깥 트랜잭션 전체가 overflow 상태가 된다. 그 커밋은 history 전체를 비운다(`wset_clear_overflow_history`). (3) trace에는 실제와 다른 사유 `STATEMENT_REPLICATION`이 찍힌다 | (1)(2)(3) 모두 코드로 확정 | 신규 |
| A2 | Medium | `log_manager.c:4038-4073`, `writeset.cpp:1435-1487` | 복제되는 sysop마다 slave에서 전역 장벽이 생긴다 | repl item이 있는 SYSOP_END는 `wset_find_sysop_fallback_dependency`(= prev_commit, 즉 이전 전부를 기다림) 뒤 `wset_raise_history_start (&sysop_lsa, ...)`(= 이후 전부가 이것을 기다림)를 한다. 작성자 TODO(4044~4050)가 이 한계를 인정한다 | serial NEXT_VALUE, 그리고 serial을 거치는 AUTO_INCREMENT INSERT가 잦은 워크로드는 sysop 하나하나가 앞뒤를 직렬화한다. 그 결과 slave 병렬도가 commit-order 수준으로 떨어진다 | 장벽 메커니즘은 확정. AUTO_INCREMENT가 매번 이 경로를 타는지(serial 캐시 설정에 따라 다름)와 성능 영향은 추정 | 신규 |
| A3 | Medium | `writeset.hpp:47-53`, `writeset.cpp:520`, `:1208`, `:1226`, `system_parameter.c`(`ha_writeset_history_size` 기본 1,000,000) | 파라미터 하나가 서로 다른 두 한도를 겸한다 | `history_size`가 트랜잭션당 키 한도(`wset_push_hash`)이면서 전역 map 용량(`wset_history_reserve_capacity`)이다 | 키 90만 개짜리 트랜잭션은 트랜잭션 한도는 통과한다. 하지만 게시할 때 map 용량을 넘겨 history 전체를 비운다(`HISTORY_CAPACITY` clear) → history_start가 올라가 동시에 커밋하는 모든 트랜잭션이 그 지점까지 기다린다. 두 한도를 따로 조정할 방법이 없다 | 확정 | 신규 |
| A4 | Medium | `locator_sr.c:7978`, `log_manager.c:5600-5606`, `system_parameter.c` | master 쪽에는 writeset을 끄는 스위치가 없다 | 수집과 라벨은 `log_does_allow_replication ()`만으로 켜진다. 병렬 여부(`ha_apply_worker_count`)는 slave의 client 파라미터일 뿐이다. `ha_writeset_history_size`의 최소값은 1이다 | slave가 worker 1개(기본값)로 commit 순서대로 적용하는 환경에서도 master는 모든 PK/UNIQUE/FK 키마다 해시 계산, malloc/free, history 락, 라벨 레코드 기록을 한다. 회귀가 의심될 때 운영자가 기능만 끌 방법이 없다 | 확정 | 신규 |
| A5 | Medium | `CMakeLists.txt:607` | applylogdb 한 곳을 위해 `MULTI_CONN_TO_A_SERVER`를 전역으로 켰다 | `add_definitions(-DMULTI_CONN_TO_A_SERVER)`는 모든 타깃에 적용된다. 이 매크로가 걸린 곳은 `src/`에 92곳(network_cl, boot_cl, schema_manager, authenticate, error_manager 등)이다 | applylogdb 외의 모든 클라이언트(csql, broker/CAS, 유틸리티)의 CS 동작이 같은 빌드 플래그로 바뀐다. 그 영향은 이 브랜치의 테스트 범위 밖이다 | 전역 적용은 확정. 다른 클라이언트에 미치는 실제 영향은 지침상 내부 분석 범위 밖이라 미검증 | 신규 |

**A1 상세.** `serial.c` 주석(1223~1226)은 "Collect the db_serial key here as this system operation's WRITE"라고 쓰여 있다. 반면 `log_manager.c` 주석(4044~4050)은 "probe and publish the keys it collected on its own SYSOP_END ... That is on hold"라고 쓴다. 두 문서가 서로 다른 설계를 말하는 상태다. 지금 설계(commit-order)를 유지한다면 다음 두 가지를 정리하는 것이 맞다.

- `serial.c`의 수집 블록을 없앤다(혹은 TODO와 함께 비활성화한다).
- 캐시 BTID가 없을 때의 fallback은 sysop 범위(이미 commit-order다)로 한정한다. 바깥 트랜잭션의 `wset_overflow`는 건드리지 않는다.

`WSET_FALLBACK_REASON`에 serial 전용 사유가 없는 것도 같은 문제의 증상이다.

**A2 상세.** 이 항목은 작성자가 인지한 한계다(TODO). 다만 아키텍처 관점에서 두 가지를 짚는다. 첫째, master의 장벽 하나가 slave 전체에 걸리는 구조라 기능 단위로 끌 수도 없다(A4). 둘째, AUTO_INCREMENT는 일반 OLTP에서 흔하다. 그러므로 출시 전에 serial 캐시 설정별로 병렬도를 측정해 두어야 한다.

### 3.4 리팩토링

| ID | 등급 | 위치 | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| R1 | Low | `writeset.cpp:106-114`, `log_manager.c:4076-4077`, `serial.c:1241`, `log_applier.c:866`, `:7481` 등, `btree.c`·`locator_sr.c`의 `wset_trace_enabled` | trace 레벨을 확인하는 방식이 세 가지다 | 캐시한 `wset_Trace_level`(WSET_TRACE), 매번 부르는 `prm_get_integer_value (PRM_ID_HA_WRITESET_TRACE_LEVEL)`, 함수 `wset_trace_enabled ()`. worker는 시작할 때 읽은 값(`config.trace_level`)을 쓴다 | 같은 로그 안에서도 줄마다 레벨 판정 시점이 다르다. 파라미터가 dynamic이 아니라 지금은 결과가 같지만, 한 곳으로 모으지 않으면 다음 변경 때 어긋난다 | 확정 | 신규 |
| R2 | Low | `log_manager.c:4000-4028`, `:4013`, `:4772-4783` | sysop commit 경로에서 trace에만 쓰는 계산을 항상 한다. 같은 집계 루프도 세 번 나온다 | `sysop_reason = log_sysop_fallback_reason (...)`(item마다 `or_unpack_string_nocopy`와 `strcmp`)와 `flushed_item_count` 루프가 trace 레벨과 무관하게 실행된다. "DATA/STATEMENT이고 NEED_FLUSH" 개수 세기 루프가 3벌 있다 | 복제되는 sysop마다 쓰지 않을 클래스명 파싱을 한다. 집계 조건을 바꿀 때 세 곳을 모두 바꿔야 한다 | 확정 | 신규 |
| R3 | Low | `writeset.cpp:1017`, `:1121`, `:1262`, `:1373` | 쓰이지 않는 범위 인자 | `wset_find_dependency_in_range (tdes, begin, ...)`와 `wset_publish_with_capacity (tdes, begin, end, ...)`의 호출부는 항상 `0`과 전체 크기다. `wset_find_dependency_in_range` 헤더 주석은 "An overflowed writeset uses prev_commit_lsa"라고 하지만 overflow 분기는 호출자(`wset_find_dependency_from_history`)에 있다 | 처음 읽는 사람은 "부분 범위 탐색이 어디서 쓰이나"를 찾게 되고, 주석을 보고 함수 안에서 overflow를 처리한다고 오해한다 | 확정 | 신규 |
| R4 | Low | `log_applier.c` 14곳(예: `:872`, `:1005`, `:1249`, `:1259`, `:7505`, `:7638`, `:9590`), `applier/*`의 `ws_gate`/`ws_worker`/`ws_marker` | coordinator를 로그·trace에서 "reader"라고 부른다. 접두어도 섞여 있다 | `"[WSET] reader schedule"`, `"applylogdb reader exit"`. `LA_DEBUG_LOG`는 `ws_gate`, worker는 `ws_worker`, 테스트 훅은 `ws_marker` | 코드는 coordinator라고 하는데 로그는 reader라서 로그로 원인을 추적할 때 이름을 맞춰 봐야 한다. grep할 접두어도 네 가지다 | 확정 | 신규 |
| R5 | Low | `unit_tests/writeset/test_writeset_stress.cpp:210-214`, `:252-261`, `:628` | 테스트 이름이 내부 단계 번호이고, 주석이 기본값과 맞지 않는다 | `TEST_CASE ("B2: ...")`~`"B6"`. 주석 "16 x 500,000 = 8M < 10M default"라고 쓰여 있지만 실제 기본값은 1,000,000이다(10M은 최대값). 주석이 옛 용어 "probe+flush"를 쓴다(코드는 publish) | 기본 설정으로 B3을 돌리면 주석의 전제(map 용량 안)와 달리 용량 clear 경로를 측정한다. 결과를 읽는 사람이 잘못 해석한다 | 기본값 불일치는 확정. B3이 guard로 크기를 바꾸는지는 확인하지 않음 | 신규 |
| R6 | Low | `writeset.cpp:145-174` | 레벨 판정이 서로 맞지 않는다 | `if (wset_Trace_level < 2) return;` 뒤에 `WSET_TRACE (3, ...)`만 출력한다 | 레벨 2에서는 함수에 들어가 아무것도 출력하지 않는다. 의도(레벨 2에서 키 없이 출력?)를 알 수 없다 | 확정 | 신규 |
| R7 | Low | `applier/log_applier_task_queue.cpp:139-141`, `log_applier.c:1170-1174` | 재적용 기준을 서로 다르게 설명하는 주석 | task queue는 "committed_rep_lsa stays behind them and a restart applies them again"라고 쓰여 있다. coordinator는 committed_rep_lsa가 "not used to decide what to re-apply"라고 쓴다 | 재시작 기준을 committed_rep_lsa로 오해하게 된다. 실제 기준은 committed_lsa/required_lsa다 | 확정 | 신규 |
| R8 | Low | `applier/log_applier_inflight.cpp:225-242`, `applier/log_applier_pending.cpp:98-132` | 결과를 찾고 준비된 태스크를 꺼낼 때 선형 탐색을 한다 | `la_inflight_find_by_seq`는 head부터 순회한다(seq는 연속 증가라 `seq - head_seq`로 바로 접근 가능). `la_pending_pop_ready`는 한 번 꺼낼 때마다 목록 처음부터 다시 스캔한다 | capacity = worker_count × 1024(최대 32,768)라서 결과 하나에 수만 번 비교할 수 있다. `drain_ready` 루프는 O(n²)이다. 병렬도가 클수록 coordinator가 병목이 된다 | 구조는 확정. 성능 영향은 추정 | 신규 |
| R9 | Low | `applier/log_applier_task_queue.cpp:53`, `:186` | 아무도 기다리지 않는 조건변수 | `la_Shared_task_not_full`은 signal과 broadcast만 있고 wait가 없다(push는 대기하지 않음) | 읽는 사람이 coordinator가 큐가 찰 때 블록한다고 오해한다 | 확정 | 신규 |

## 4. 미검증 의심

- **U1. master 재시작 직후 첫 commit이 slave에서 영원히 park될 가능성(추정, worker_count>1일 때).** 근거:
  - `log_initialize_internal`(`log_manager.c:1503-1514`)은 history_start를 재시작 시점의 `append_lsa`(R)로 올린다.
  - 재시작 직후 history map은 비어 있고 `prev_commit_lsa`는 NULL이므로, 첫 복제 commit T1의 라벨은 `wset_find_dependency_in_range`(1032, 1082-1095)에 따라 R이 된다.
  - slave gate는 `dep <= frontier`일 때만 통과한다(`la_gate_is_satisfied`). frontier는 ring에 올라간 commit/라벨된 SYSOP_END LSA로만 전진한다(`la_gate_advance_frontier`).
  - R은 commit 좌표가 아니라서 ring에 대응 항목이 없다. sysop 하한은 `la_coordinator_complete_without_task`나 fragment task로 ring에 올라가지만, RESTART 하한에는 그런 짝이 없다.
  - R과 T1 사이에 다른 LOG_COMMIT(라벨 유무 무관)이 하나도 없다면 frontier는 R 아래(재시작 전 마지막 commit)에서 멈춘다. T1은 자기 자신이 완료되어야 frontier가 R을 넘으므로 순환 대기가 된다.
  - 실제로는 재시작 후 master에서 다른 commit(예: master 측 applylogdb의 `_db_ha_apply_info` 갱신)이 끼어들어 가려질 가능성이 높다. 그래서 확정하지 못했다.
  - 검증 방법: 다른 쓰기가 없는 master를 재시작한 직후 단일 트랜잭션을 커밋하고, worker 2 이상인 slave에서 `[WSET] reader schedule status=PARKED`가 계속 유지되는지 본다.
- **U2. `file_io.c` 변경(`!SERVER_MODE && WINDOWS`일 때만 lseek+read, 나머지는 pread/pwrite).** SA/CS 모드 Linux에서 lseek 경로가 사라진 것이다. multi-connection을 위한 변경으로 보이지만, 지침상 내부 분석 범위 밖이라 SA 유틸리티에 미치는 영향은 확인하지 않았다.
- **U3. history rwlock 기아.** `wset_find_dependency_in_range`는 키 전체(최대 history_size개)를 도는 동안 shared lock을 잡는다. glibc rwlock 기본 정책(reader 우선)에서는 clear/raise의 wrlock이 계속 밀릴 수 있다. 측정 근거가 없어 추정으로만 남긴다.

## 5. 총평

- **설계의 큰 틀은 일관된다.** master는 "키 충돌의 최대 commit LSA를 라벨로 단다". slave는 "gap-free frontier가 라벨에 닿으면 실행한다". 모르면 보수적으로 처리하는 원칙(overflow나 statement는 commit-order, 라벨이 없으면 이전 전부를 기다림)도 지켜진다.
  - 라벨과 commit/SYSOP_END를 같은 prior_lsa_mutex 구간에 쓰는 인접성 보장이 있다.
  - publish는 commit LSA를 받은 뒤, 락을 풀기 전에 한다.
  - 1 worker일 때는 FIFO로 commit 순서를 지킨다.
  - 이 구조는 기존 CUBRID 경계(log record type, tdes, prior list)를 크게 침범하지 않고 얹혔다.
- **그러나 "보수적으로 처리" 원칙에 구멍이 두 군데 있다.**
  - 라벨 본문을 읽지 못하면 오히려 의존 없음이 된다(E1).
  - RESTART 하한은 slave ring에 대응 좌표가 없다(U1, 추정).
  - 대기 경로마다 종료 정책이 다르다. 그래서 worker가 전멸하면 coordinator가 빠져나올 수 없다(E2).
- **모듈화는 절반만 됐다.** 자료구조는 `applier/`로 분리되고 단위 테스트까지 붙었다. 하지만 가장 판단이 많은 coordinator 정책은 11,000줄짜리 `log_applier.c`(`la_apply_log_file`은 611줄에서 783줄로 늘었다)에 static 함수와 전역 상태로 남아 테스트 대상이 아니다(D1). master 쪽도 serial 키 수집이 현재 설계(commit-order로 버림)와 맞지 않는 코드로 남아 있다(A1). 수집 조건과 trace 판정은 여러 곳에 흩어져 있다(D2, R1).
- **운영 관점의 아키텍처 결정 세 가지가 남아 있다.**
  - 파라미터 하나가 두 한도를 겸한다(A3).
  - master에 기능 스위치가 없다(A4).
  - `MULTI_CONN_TO_A_SERVER`를 전역으로 켰다(A5).
  - 이 셋은 코드 수정보다 설계 합의가 먼저 필요하다.
- **우선순위.** E1과 E2(작은 수정으로 막을 수 있는 정확성·가용성 문제)를 가장 먼저 고친다. 다음으로 A1(설계와 코드 불일치 정리)과 D1(coordinator 분리로 E1·E2·U1을 테스트할 수 있게 만들기) 순서를 제안한다.

### 등급별 건수

| 등급 | 건수 | ID |
|---|---|---|
| Critical | 0 | |
| High | 2 | E1, E2 |
| Medium | 7 | E3, D1, A1, A2, A3, A4, A5 |
| Low | 17 | E4, E5, E6, D2, D3, D4, D5, R1~R9 |
| 미검증 | 3 | U1, U2, U3 |
