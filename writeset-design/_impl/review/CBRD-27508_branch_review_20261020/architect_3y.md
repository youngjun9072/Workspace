# CBRD-27508 브랜치 리뷰: 아키텍트 3년차

## 1. 리뷰어 관점

- 아키텍트 관점에서는 master가 만드는 라벨(writeset dependency)과 slave의 gate가 같은 규칙을 쓰는지 봤다. 핵심은 "라벨 값이 slave 쪽에서 반드시 도달 가능한 좌표인가"와 "master의 '보이면 이미 publish됐다'는 불변식이 어디서 보장되는가"이다. 모듈 경계, 결합도, 기존 CUBRID 구조(로그 레코드 타입, 카탈로그, 빌드 매크로)와 맞는지도 함께 봤다.
- 3년차 관점에서는 함수 단위 에러 처리, 상태 변수 초기화와 소비, 중복 코드, 명명과 trace의 일관성을 봤다.
- 범위는 `git diff a9a0dc78d 0e411f10f`이고 HEAD는 0e411f10f다. 아래 행번호는 모두 HEAD 기준이다.

## 2. 검토 범위와 실제로 읽은 경로

| 파일 | 읽은 함수와 구간 |
|---|---|
| `src/transaction/writeset.cpp` (전체) | wset_fnv1a, wset_string_hash, wset_midxkey_hash, wset_history_initialize/finalize, wset_push_hash, wset_fallback_to_commit_order, wset_add_write_key, wset_add_ref_key, wset_make_parent_midxkey, wset_select_candidate, wset_find_dependency_in_range/_from_history, wset_publish_keys, wset_publish_with_capacity, wset_history_reserve/release_capacity, wset_clear_overflow_history, wset_publish_commit_to_history, wset_discard_sysop_keys, wset_abort_after_lsa, wset_find_sysop_fallback_dependency, wset_raise_history_start |
| `writeset.hpp`, `writeset_types.hpp`, `writeset_history_map.{hpp,cpp}` | 전체 |
| `log_manager.c` (diff 전체) | log_initialize_internal의 RESTART 하한, log_sysop_start(wset_mark), log_sysop_commit_internal, log_sysop_abort, log_append_sysop_end_internal, log_sysop_fallback_reason, log_append_wset_label_and_sysop_end, log_append_repl_info_internal(기존), log_append_repl_info_and_commit_log, log_append_wset_label_with_lock, log_commit_local, log_complete_for_2pc, log_dump switch(7437~7471) |
| `log_append.cpp`, `log_record.hpp`, `log_impl.h`, `log_recovery.c`, `log_tran_table.c`, `replication.c` | diff 전체. `log_2pc.c:2270-2350`(기존 switch)은 신규 레코드 영향만 확인 |
| `locator_sr.c` | locator_wset_error, locator_wset_trace_key_source, locator_wset_collect_fk_ref, locator_add_or_remove_index_internal(수집부), locator_update_index(수집부와 pk_btid_index 후처리, 8560-9060), locator_is_inserter_committing, locator_lock_and_get_object_internal(retry_get), xlocator_repl_force(deadlock) |
| `btree.c` | btree_is_deleter_committing, btree_trace_deleter_wait, btree_wait_for_inserter_end, unique_of_unique/_of_non_unique의 DELETE_RECORD_DELETED, btree_fk_object_does_exist(30491-30640, 기존 FK 경로), btree_read_key_type |
| `serial.c` | serial_update_serial_object(1149-1270), serial_cache_index_btid |
| `system_parameter.{c,h}`, `error_code.h`, `heartbeat.h`, msg | diff 전체 |
| `log_applier.c` | la_coordinator_* 전부(drain_ready, wait_for_commit_order_slot, cover_commit, dispatch_task, collect_and_retire, collect_results, record_result, complete_without_task, wait_until_retired, wait_for_inflight_slot, release_apply_slot, advance_committed_lsa, retire_results, store_apply_info_at_interval, submit_task, process_sysop_end, set_commit_dependency, process_commit), la_apply_worker_run/flush/commit_task, test hook, la_is_in_recovery_range, la_detach_sysop_fragment, la_get_wset_label, la_log_record_process, la_change_state(DONE 보류), la_find_required_lsa, la_get/update_ha_apply_max_committed_lsa, la_apply_repl_log, la_commit_transaction, la_shutdown, la_remove_archive_logs, 메인 루프(9895-10420) |
| `src/transaction/applier/*` | gate, inflight, pending, task_queue, result_queue, worker(전체), task/result/debug 헤더 |
| CS glue (호출부만) | CMakeLists(루트, cs, sa, cubrid), work_space ws_get_repl_obj_count 호출부(log_applier.c:5899), file_io.c diff, `db_multi_threads_connections.h` 매크로 정의 |
| unit_tests | log_applier/CMakeLists.txt, test_log_applier_common.hpp, gate 테스트 목록, writeset/CMakeLists.txt |

## 3. 발견 사항

### 3.1 에러

| ID | 등급 | 위치 | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| E1 | High | log_manager.c:1511-1513, writeset.cpp:1091-1095, log_applier_gate.cpp:280-291 | master 재기동 하한(RESTART)이 slave ring에 없는 LSA라서 gate가 영원히 통과시키지 않을 수 있음 | `restart_lsa = log_Gl.hdr.append_lsa; wset_raise_history_start (&restart_lsa, "RESTART")`, gate는 `LSA_LE (dep, &la_Gate_frontier)`만 봄 | master 재기동 뒤 R 이상인 commit이 하나도 ring에 오르기 전에 첫 복제 commit C1(라벨 R)이 오면 frontier가 R 미만에 머물러 C1이 parked 상태로 남는다. 뒤 commit도 모두 R 이상이라 쌓이고, ring이 차면 coordinator가 `la_coordinator_wait_for_commit_order_slot`에서 계속 돈다 | 추정 (코드 경로는 확정, 재기동 직후 무라벨 commit이 먼저 오는지 여부는 미확인) | 신규 |
| E2 | High | btree.c:30581-30604, log_manager.c:5600-5606, locator_sr.c:8066 | 부모 INSERT를 커밋 중인 트랜잭션이 있을 때, 자식 FK 검사가 그 커밋을 기다리지 않아 자식 REF 라벨에서 부모가 빠짐 | FK 검사는 `DELETE_RECORD_CAN_DELETE`에서 부모 OID에 `lock_object (..., LK_COND_LOCK)`만 건다. inserter는 CBRD-26942 이후 행 X락이 없다(d1d02b9e4 커밋 메시지). publish는 commit 레코드 이후이고 self-lock 해제 직전이다 | 부모 T_p가 complete_mvcc 뒤 publish 전에 있을 때 자식 T_c가 FK 검사(S락 즉시 획득) → INSERT → commit한다. T_c의 REF probe가 miss해 라벨이 T_p를 포함하지 않는다. slave에서 T_c가 T_p보다 먼저 또는 동시에 적용되어 FK 위반으로 applier가 멈춘다 | 추정 (경로는 코드로 확인, 재현은 하지 않음) | 신규(라벨 누락). 대기 부재 자체는 CBRD-26942 이후 기존 |
| E3 | Medium | log_applier.c:4638-4666, 7815-7818, 7553-7560 | label을 읽지 못하면 "의존 없음(NULL)"으로 바뀌는데, 이때 holder는 라벨이 있는 것으로 표시됨 | `LSA_SET_NULL (dependency_seq)`, 페이지를 못 읽으면 바로 return한다. 그 뒤 `la_wset_label_trid = lrec->trid`, `has_label = true`, `dependency_seq = NULL`이 된다 | label 데이터가 다음 페이지로 넘어가는데 `la_get_page`가 실패하면, 그 commit은 `la_gate_is_satisfied (NULL) == true`로 바로 dispatch된다. 라벨이 아예 없을 때의 안전한 폴백(직전 commit 대기, 7574-7578)을 타지 않는다 | 확정 (발생 빈도는 추정) | 신규 |
| E4 | Medium | log_applier.c:1039-1068, 1080-1109, log_applier_worker.cpp:379-391, log_applier_result_queue.cpp:172 | 모든 worker가 시작에 실패하면 coordinator가 `la_result_queue_pop`에서 영구 대기함 | startup 실패는 `request_shutdown ()`(플래그만 설정)만 하고 result queue shutdown은 알리지 않는다. pop은 `while (count == 0 && !shutdown) pthread_cond_wait` | 재기동 직후 recovery range가 비어 있지 않고 worker가 2개 이상인데, worker 세션이 전부 실패한 경우(서버 준비 전, max_clients 초과 등)다. `la_coordinator_submit_task`가 첫 task를 dispatch하고 `la_coordinator_wait_until_retired`에 들어가면 result를 줄 worker가 없어 깨어나지 않는다. `la_applier_need_shutdown`도 확인하지 않는다 | 확정 (코드 경로) | 신규 |
| E5 | Medium | log_applier.c:7495-7502, 7520-7534, 7753-7756 | label holder(`la_wset_label_trid`)를 소비하지 않는 경로가 있음 | fragment 경로(7473)만 holder를 비운다. 항목 없는 라벨 SYSOP(`complete_without_task`), committed_lsa 이하 SYSOP 또는 COMMIT의 skip 경로는 holder를 그대로 둔다 | (a) 항목 없는 라벨 SYSOP 뒤에 같은 trid의 일반 SYSOP_END가 올 때마다 `complete_without_task`가 ring에 좌표를 하나씩 더 넣는다. (b) 재시작 경계에서 라벨 SYSOP S1이 committed_lsa 이하라 skip되고, 같은 trid의 다음 SYSOP_END가 committed_lsa보다 크면, outer apply에 남은 S1 serial 항목이 낡은 라벨을 단 별도 fragment로 떼어져 적용된다 | 확정 (영향 크기는 추정) | 신규 |
| E6 | Medium | log_applier.c:8547-8548, 1119-1133, log_applier_pending.cpp:144 | SYSOP_END fragment의 독립 slot이 applier 종료 때 해제되지 않음 | fragment slot은 retire에서만 `la_free_all_repl_items` 후 `free_and_init`한다. `la_pending_clear`는 node만 free하고, inflight는 정리하지 않는다 | 서버 다운 등으로 applier가 같은 프로세스 안에서 재시작될 때마다 parked 또는 inflight 상태의 serial fragment(LA_APPLY와 그 항목)가 누수된다 | 확정 | 신규 |
| E7 | Medium | writeset.cpp:637-650, 941-955 | 문자열이 아닌 키를 packed byte로 해시하는데, index에서 같은 값으로 보는 서로 다른 표현이 있으면 해시가 달라짐 | `or_pack_mem_value (buf, key, &packed_len); hash = wset_fnv1a (..., buf, packed_len)` | TIMESTAMPTZ unique 키(같은 순간, 다른 tz_id)나 DOUBLE의 `0.0`/`-0.0`이 그렇다. T1이 키 A를 DELETE하고 T2가 같은 값의 다른 표현을 INSERT하면 해시가 달라 의존이 없다. slave에서 INSERT가 먼저 적용되어 unique 위반이 난다 | 추정 (index 비교가 tz_id나 부호를 무시하는지는 코드로 확인하지 않음) | 신규 |

#### E1 상세
- master는 `log_initialize_internal`에서 회복이 끝난 log 끝(append_lsa)을 `history_start`로 올린다. 이후 history에 걸리지 않은 commit의 라벨은 `wset_find_dependency_in_range`(1091-1095)의 floor 처리로 R이 된다.
- slave의 frontier는 ring에 오른 commit LSA(그리고 `complete_without_task` 좌표) 위로만 움직인다(`la_gate_advance_frontier`). R은 commit도 SYSOP_END도 아닌 단순 append 위치라 ring에 오르지 않는다. 재기동 전 마지막 commit F는 R보다 작다.
- 그래서 R 이상인 다른 commit(라벨 없는 commit 등)이 먼저 완료되어 frontier를 R 위로 밀어 주지 않으면, C1은 `la_gate_is_satisfied` false로 parked 상태에 머문다. `la_coordinator_wait_for_commit_order_slot` 주석의 전제("가장 오래된 commit은 항상 gate를 통과한다")도 여기서 깨진다.
- 주석(log_manager.c:1500-1507)은 "the gate waits for the gap-free frontier to reach the label"이라고 설명하지만, frontier는 commit 좌표 사이를 건너뛰는 이산 값이라 R에 정확히 "도달"하지 못한다.
- 수정 방향(제안): 하한을 실제 log 레코드에 붙인다. 예를 들어 재기동 직후 LOG_DUMMY_WSET_LABEL 같은 표지 레코드를 하나 쓰고 slave가 그 좌표를 `complete_without_task`로 ring에 올리는 방식이 있다. 또는 gate가 "ring이 비어 있고 inflight와 pending도 비었으면 frontier를 dep까지 올린다" 같은 규칙을 갖게 한다. 라벨 값이 항상 slave에서 도달 가능한 좌표여야 한다는 불변식은 문서와 assert로 고정해 두는 것이 좋다.
- gate 단위 테스트(test_log_applier_gate.cpp)에는 "ring에 없는 dep" 케이스가 없다.

#### E2 상세
- d1d02b9e4(행 UPDATE/DELETE)와 79268ae56(unique 삭제 키)는 "complete_mvcc 이후 publish 이전" 구간에 들어온 트랜잭션을 self-lock으로 기다리게 했다. FK 참조 경로(`btree_fk_object_does_exist`)에는 같은 처리가 없다. INSERT_IN_PROGRESS일 때만 inserter를 기다리고, MVCC가 완료된(CAN_DELETE) 부모는 조건부 S락으로 바로 통과한다.
- 부모 PK의 WRITE 키는 부모의 publish(log_manager.c:5606) 뒤에야 history에 들어간다. 자식이 그 전에 probe하면 miss가 나고, 라벨은 history_start나 무관한 키로 정해진다.
- slave는 FK를 검사하는 서버 경유로 적용하므로 부모가 없는 상태에서 자식 INSERT가 실패한다.
- 수정 방향: FK CAN_DELETE 경로에도 `btree_is_deleter_committing`과 같은 형태의 "inserter committing" probe를 넣는다. 근본 대안은 A1을 본다.

#### E3 상세
- 마스터가 label 쓰기에 실패하면 slave는 "라벨 없음"으로 보고 직전 commit을 기다린다(안전). 반면 slave가 label을 읽지 못하면 "라벨 있음, 의존 없음"이 되어 가장 공격적인 쪽으로 처리된다. 실패 방향이 반대다.
- 제안: `la_get_wset_label`이 실패를 반환하게 하고, 실패하면 holder를 세우지 않는다(무라벨 경로). 또는 applier를 오류로 멈춘다.

#### E4 상세
- `la_coordinator_wait_until_retired`와 `la_coordinator_wait_for_inflight_slot`은 timeout 없는 `la_result_queue_pop`을 쓴다. 반면 commit-order 대기(741-758)는 `la_applier_need_shutdown`을 확인하고 100ms timedwait를 쓴다. 대기 함수 사이에 일관성이 없다.
- 제안: 두 함수도 `la_result_queue_wait_for_result (100)`과 `la_applier_need_shutdown` 확인으로 바꾼다. 또는 `la_worker_startup_failed`에서 live worker가 0이 될 때 `la_result_queue_signal_shutdown`을 호출한다.

#### E5 상세
- holder는 "label 바로 다음의 같은 trid COMMIT 또는 SYSOP_END가 소비한다"는 계약(7321-7329)으로 설계됐는데, 소비하지 않는 분기가 세 곳 있다. 다음 label이 덮어쓰기 때문에 대부분은 무해하다. 그러나 같은 trid의 무라벨 SYSOP_END가 끼면 그 레코드를 "라벨 붙은 SYSOP"으로 오인한다.
- 제안: label을 읽은 직후 다음 레코드가 같은 trid의 COMMIT 또는 SYSOP_END가 아니면 holder를 비운다. 최소한 위 세 분기 끝에서 holder를 초기화한다.

#### E6 상세
- 주석(8547)은 "parked tasks point at the apply slots freed below"라고만 하고, fragment는 repl_lists에 속하지 않는 독립 malloc이라는 점을 놓쳤다. 종료 경로에서 pending과 inflight를 돌며 `rectype == LOG_SYSOP_END`인 apply를 `la_coordinator_release_apply_slot`과 같은 방식으로 풀어야 한다.

#### E7 상세
- 문자열은 collation pseudo key로 정규화한다. 그 외 타입은 "index에서 같으면 packed byte도 같다"는 가정을 쓰는데, 이 가정이 성립하지 않으면 의존을 덜 잡는 방향(안전하지 않은 쪽)으로 틀린다. 반대로 해시 충돌은 의존을 더 잡는 방향이라 안전하다. 타입별로 이 가정을 검증하는 단위 테스트가 필요하다.

### 3.2 모듈화

| ID | 등급 | 위치 | 내용 | 근거 | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| M1 | Medium | log_applier.c:700-1560, 7321-7652 | 스케줄링 핵심(submit_task, set_commit_dependency, process_sysop_end, cover_commit, recovery range, label holder 전역)이 모두 log_applier.c의 static 함수와 전역에 있음 | log_applier.c가 9409줄에서 11131줄로 늘었다. unit_tests/log_applier는 inflight, gate, pending, queue 컨테이너만 링크한다 | E1, E3, E5 같은 결함은 컨테이너 테스트로 잡히지 않는다. 스케줄 규칙을 바꿀 때 회귀 테스트 수단이 HA 실측뿐이다 | 확정 | 신규 |
| M2 | Medium | serial.c:1219-1251 vs log_manager.c:4038-4073 | serial.c의 writeset 키 수집은 항상 버려짐(사실상 죽은 코드). query 계층에서 log_tdes와 writeset을 직접 만짐 | 이 블록은 `lock_mode != X_LOCK`(sysop 안) 분기 안에 있고 `repl_end_flush_mark` 직후다. 그 sysop의 SYSOP_END는 `repl_item_count > 0`이라 commit-order로 가고 `wset_discard_sysop_keys`가 키를 버린다. `serial_Cached_btid`는 boot에서 캐시된다(boot_sr.c:2533) | 동작상 해는 없다. 다만 BTID가 NULL인 분기는 outer 트랜잭션 전체를 overflow로 만들고, 그 commit에서 전역 history를 clear한다. 실제로 일어나지 않는 경로에 가장 비싼 폴백이 붙어 있다. trace도 `_er_log_debug`를 직접 호출해 wset trace 체계와 따로 논다 | 확정 | 신규 |
| M3 | Low | log_manager.c:3756, 4038, 4072, writeset.cpp:1386-1422 | 같은 개념인 "이 sysop이 모은 키"를 commit 때는 개수 인덱스(wset_mark)로, abort 때는 LSA(`e.lsa > start_lsa`)로 식별함 | `wset_hashes.erase (begin () + sysop_key_begin, end ())` vs `remove_if (LSA_GT (&e.lsa, start_lsa))` | 지금은 중첩 abort가 앞쪽 키를 지우지 않아 두 규칙이 맞물린다. 그러나 앞으로 키 순서나 수집 위치가 바뀌면 둘이 어긋날 수 있다. 하나로 통일하는 편이 낫다 | 확정 (현재 오동작 없음) | 신규 |
| M4 | Low | log_manager.c:3998-4028, 4772-4782, 4808-4860 | log_manager.c가 replication 레코드의 내부 형식(packed key size 다음 class name)과 must_flush 의미를 직접 해석함. 같은 카운트 루프가 세 벌 있음 | `or_unpack_int (repl_record->repl_data, ...)`, `or_unpack_string_nocopy`. `log_sysop_fallback_reason`은 "Trace only"인데 trace 레벨과 무관하게 모든 sysop commit에서 호출됨 | 복제를 쓰는 서버의 모든 sysop commit에서 trace용 파싱과 루프가 돈다. 레코드 형식이 바뀌면 replication.c와 log_manager.c 두 곳을 같이 고쳐야 한다 | 확정 | 신규 |
| M5 | Low | locator_sr.c:7712-7724 vs writeset.cpp:667-681. writeset.cpp:599-659, 883-965 | 에러 보정 함수가 둘이고, pack→hash→push→trace 시퀀스가 네 번 반복됨 | `locator_wset_error`와 `wset_error`가 거의 같다 | 한쪽만 고치면 에러 코드가 달라진다(예: ER_FAILED 처리 규칙이 서로 다름) | 확정 | 신규 |
| M6 | Low | writeset.cpp:520, 1208, 1226 | `ha_writeset_history_size` 하나가 트랜잭션별 키 상한과 전역 map 용량을 함께 결정함 | 두 곳이 같은 `history_size`와 비교한다 | 큰 배치 트랜잭션을 허용하려고 값을 올리면 전역 map도 같이 커진다. 반대로 map을 줄이면 트랜잭션 폴백이 늘어난다 | 확정 | 신규 |

### 3.3 아키텍처

| ID | 등급 | 위치 | 내용 | 근거 | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| A1 | High | locator_sr.c:13195-13346, btree.c:27209-27226 및 27553-27562, 27910-27919, log_manager.c:5600-5622 | "보이면 이미 publish됐다"는 불변식을 한곳에서 보장하지 않고, 읽기 경로마다 self-lock 대기를 덧붙이는 방식 | 행 UPDATE/DELETE와 unique 삭제 키에는 대기가 있고 FK 참조에는 없다(E2). 대기 조건은 `log_does_allow_replication ()`뿐이다 | 새 읽기 경로(FK, CASCADE 내부 경로 등)마다 같은 구멍이 다시 생길 수 있다. writeset 병렬 적용을 쓰지 않는 HA master(worker 1)도 매 X락 행과 삭제된 unique 키에서 조건부 lock probe 비용을 낸다 | 확정 (구조), 추정 (다른 경로의 구멍) | 신규 |
| A2 | Medium | CMakeLists.txt:607, log_applier_worker.cpp:149, 184 | `MULTI_CONN_TO_A_SERVER`를 루트 CMake에서 모든 빌드에 켬. worker는 매크로가 꺼지면 조용히 coordinator 연결을 공유함 | `add_definitions(-DMULTI_CONN_TO_A_SERVER)`, `#if defined(CS_MODE) && defined(MULTI_CONN_TO_A_SERVER)` 안에서만 `db_restart_sub` | csql, CAS 등 cubridcs를 쓰는 모든 클라이언트에서 `CUB_THREAD_LOCAL`, area_alloc, error manager, msgcat 동작이 바뀐다. 매크로를 끈 빌드에서는 컴파일은 되지만 cb0095bf2 메시지대로 applier가 hang한다 | 확정 (영향 범위는 CS 내부 미분석) | 신규 |
| A3 | Medium | schema_system_catalog_install.cpp:1095-1097, log_applier.c:2896-2933, 3349 | `_db_ha_apply_info`에 컬럼 두 개를 추가했지만 기존 DB 마이그레이션 경로가 없음 | applier 시작 시 `SELECT max_committed_lsa_pageid ...`가 실패하면 `return res` | develop으로 만든 slave DB에 이 바이너리를 올리면 applylogdb 시작 단계에서 SELECT 오류가 나 복제가 시작되지 않는다. 코드 TODO(2949-2957)도 컬럼 없이 final_lsa로 대체하는 안을 남겨 두었다 | 확정 (업그레이드 경로 부재) | 신규 |
| A4 | Medium | log_record.hpp:140-142, base log_applier.c:6336, log_manager.c:7466-7471 | 새 로그 레코드 타입 53을 추가해 혼합 버전 운용과 도구에 영향이 있음 | develop applier는 `lrec->type >= LOG_LARGER_LOGREC_TYPE(=53)`를 손상으로 본다. `log_dump` switch에는 case가 없어 default에서 "Unknown record type"을 찍고 `LSA_SET_NULL (log_lsa)` | master를 먼저 올리면 develop slave가 첫 label에서 ER_LOG_PAGE_CORRUPTED로 멈춘다(업그레이드 순서 제약). log dump(diagdb)는 첫 label에서 덤프를 중단한다 | 확정 | 신규 |
| A5 | Medium | log_manager.c:4040-4073, writeset.cpp:1466-1487 | 복제 항목을 낸 sysop(serial, AUTO_INCREMENT, INCR/DECR)마다 전역 하한을 올리고 exclusive history lock을 잡음 | `wset_raise_history_start (&sysop_lsa, ...)`가 `seq_lock`과 `wrlock`을 잡는다. 코드 TODO(4045-4051)로 보류가 명시되어 있다 | serial 캐시가 없는 AUTO_INCREMENT INSERT가 많은 부하에서는 매 INSERT가 이후 모든 트랜잭션의 하한이 되어 slave 병렬도가 무너진다. master에서도 매 commit의 rdlock과 경합한다 | 확정 (구조), 추정 (AUTO_INCREMENT 기본 캐시 값) | 신규 |
| A6 | Low | system_parameter.c:5673-5705, log_applier.c:7378 | master writeset이나 slave 새 경로를 끄는 스위치가 없음 | `ha_writeset_history_size` 최소값이 1이다. `worker_count == 1`도 새 coordinator와 worker 스레드 경로로 간다 | 현장에서 문제가 생겨도 기존 직렬 applier나 라벨 미생성 상태로 되돌릴 수 없다. A1의 master 대기도 끌 수 없다 | 확정 | 신규 |
| A7 | Low | locator_sr.c:7793, writeset.cpp:637-657, 1026-1030, 1173-1178, log_applier.c:9901-9943 | 핫 경로 비용 | FK 행마다 `btree_read_key_type`(부모 PK root page fix와 domain unpack), 키마다 malloc, commit마다 전역 `seq_lock` 2회. archive 삭제(파일 unlink, 최대 INT_MAX개)를 page cache mutex 안에서 수행 | 부모 PK root에 read latch가 몰리고 commit이 직렬화된다. archive를 대량 삭제하는 동안 모든 worker의 page fetch가 멈춘다 | 확정 (영향 크기는 추정) | 신규 |
| A8 | Low | locator_sr.c:8041-8072, 8758-8786, writeset.cpp:915-926 | 키를 만들지 못하면 사용자 DML을 실패시킴(fail-closed). 폴백 수단(`wset_fallback_to_commit_order`)은 이미 있음 | 주석은 "a key must not be silently omitted"라고 한다 | FK 캐스트 overflow 같은 기술적 실패가 복제 메타데이터 문제인데도 master의 업무 DML 실패로 바뀐다. 안전성(키 누락 금지)은 overflow 폴백으로도 지킬 수 있다 | 확정 (설계 판단 항목) | 신규 |

#### A1 상세
- master 라벨의 정확성은 "충돌 상대가 publish한 뒤에야 내가 그 행이나 키를 볼 수 있다"에 기대고 있다. 그런데 CUBRID는 `logtb_complete_mvcc`(가시화)가 commit 레코드와 publish보다 먼저 일어난다. 브랜치는 이 틈을 경로별로 막았다(d1d02b9e4, 79268ae56). 이 방식은 막지 않은 경로(E2)가 남고, 새 경로가 생길 때마다 같은 분석을 반복해야 한다.
- 구조적 대안(제안)은 두 가지다.
  - (a) dependency 선택과 publish를 complete_mvcc 앞으로 옮긴다. commit LSA는 commit 레코드 append 시점에 정해지므로, 대신 "커밋 중" 상태를 history에 먼저 등록하고 probe가 그것을 보게 한다.
  - (b) self-lock 대기를 locator와 btree 개별 지점이 아니라 MVCC 가시성 판정 유틸(예: "다른 트랜잭션이 커밋 중인가")로 모아, 모든 충돌 판정 경로가 한 함수를 거치게 한다.
- 대기 기능은 적어도 writeset 사용 여부(A6의 스위치)에 묶어 두는 것이 좋다.

#### A2 상세
- 이 매크로는 클라이언트 라이브러리 전역의 동시성 모델을 바꾼다. applylogdb 전용 빌드 옵션으로 두거나 `cs/` 타깃 한정 정의로 제한하는 편이 낫다. 매크로 없이 컴파일되는 worker 경로에는 `#error`나 런타임 실패를 두어, 조용히 연결을 공유하지 않게 해야 한다.

#### A3, A4 상세
- 두 변경 모두 디스크(카탈로그와 로그 형식) 호환성에 걸린다. 릴리스 노트, 업그레이드 순서(slave 먼저), 카탈로그 마이그레이션(또는 컬럼이 없을 때 범위를 비우는 폴백) 중 무엇을 택할지 결정이 필요하다. log_dump에는 LOG_DUMMY_WSET_LABEL case를 추가해야 한다.

### 3.4 리팩토링

| ID | 등급 | 위치 | 내용 | 근거 | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| R1 | Low | log_applier.c:872, 1005, 1249, 1259, 7505, 7512, 7528, 7638, 7764, 7819, 7825 등 | coordinator trace 문자열에 "reader"가 남아 있음. trace 방식이 네 가지로 섞여 있음 | `"[WSET] reader schedule ..."`. `WSET_TRACE` 매크로, `prm_get_integer_value (PRM_ID_HA_WRITESET_TRACE_LEVEL)` 직접 호출(18곳), `wset_trace_enabled`, `LA_DEBUG_LOG`, 접두어 `ws_*`가 섞임 | 로그 grep과 분석 스크립트가 명칭과 형식에 의존해 깨지기 쉽다. trace 레벨을 바꾸려면 여러 곳을 고쳐야 한다 | 확정 | 신규 |
| R2 | Low | log_applier_pending.cpp:98-133, log_applier_inflight.cpp:225-242 | pending pop과 inflight 검색이 매번 선형 탐색 | `for (cur = la_Pending_head; ...)`, `la_inflight_find_by_seq` 선형 탐색 | 최대 worker×1024개가 parked 상태면 결과마다 drain이 O(n²)이 된다. seq는 단조 증가라 `seq - head_seq`로 O(1) 인덱싱이 가능하다 | 확정 | 신규 |
| R3 | Low | log_applier.c:1414-1456 | release 빌드에서 commit마다 `getenv` 두 번을 호출하는 테스트 hook | 코드 TODO에 이미 명시됨 | 운영 환경에 변수가 남아 있으면 60초 정지가 일어난다. 시작할 때 한 번 읽거나 debug 빌드 전용으로 바꿔야 한다 | 확정 | 신규 |
| R4 | Low | writeset.cpp:145-174 | `wset_trace_collected_key`의 레벨 2 분기가 아무것도 출력하지 않음 | 첫 guard는 `< 2`인데 실제 출력은 `WSET_TRACE (3, ...)` | 레벨 2를 켜도 COLLECT 줄이 나오지 않아 문서상의 레벨 정의와 다르다 | 확정 | 신규 |
| R5 | Low | log_applier.c:1210 | 함수 static `last_store_ns`가 같은 프로세스 안의 applier 재시작 뒤에도 유지됨 | `static UINT64 last_store_ns = 0;` | 재시작 직후 첫 저장이 이전 run의 시각 기준으로 지연된다(영향 작음). 상태는 la_Info로 옮기는 편이 일관된다 | 확정 | 신규 |
| R6 | Low | log_applier_task.hpp:41, unit_tests/log_applier/test_log_applier_common.hpp | `rectype`을 `int`로 둬서 테스트가 매직 넘버(17, 20)를 씀 | `TEST_RECTYPE_COMMIT = 17` | LOG_RECTYPE 값이 바뀌면 테스트가 조용히 틀린다 | 확정 | 신규 |
| R7 | Low | applier/log_applier_worker.cpp:159-161 | 세션 시작에서 `tr_init`과 `db_disable_trigger`의 반환값을 무시함 | `tr_init (); (void) db_disable_trigger ();` | trigger 비활성화가 실패해도 worker가 그대로 적용을 시작해 slave에서 trigger가 다시 실행될 수 있다 | 확정 (실패 가능성은 추정) | 신규 |

## 4. 미검증 의심 (근거 부족으로 확정하지 못한 것)

1. **2PC 회복 분석이 label 레코드를 만나는 경우**: `log_2pc_recovery_analysis_info`(log_2pc.c:2341-2349)의 default는 ER_LOG_PAGE_CORRUPTED다. label은 트랜잭션 체인(prev_tranlsa)에 들어간다. 2PC 트랜잭션의 label만 디스크에 남고 commit 레코드가 남지 않은 채 크래시하는 경우가 가능한지, 그 함수가 그 레코드까지 역방향으로 걷는지는 확인하지 못했다. 같은 switch는 LOG_SUPPLEMENTAL_INFO도 다루지 않아 기존에도 있던 문제일 수 있다.
2. **재시작 경계의 serial 이미지 재적용**: 라벨 SYSOP S1이 committed_lsa 이하라 skip되면 S1의 serial 항목이 outer apply에 남아 outer commit 때 다시 적용된다(log_applier.c:7520-7534). 그 사이 다른 트랜잭션의 더 새로운 serial 값이 이미 적용됐다면 current_val이 뒤로 돌아갈 수 있다. develop 직렬 applier도 같은 동작인지 비교하지 못했다.
3. **E1의 실제 발생 빈도**: master 재기동 후 첫 복제 commit 전에 R 이상인 무라벨 commit(부팅 중 내부 commit 등)이 항상 생기는지에 따라, 문제가 늘 가려질 수도 있고 늘 발생할 수도 있다. master 단독 재기동 후 HA 재합류 시나리오로 실측해야 한다.
4. **failover 직후 새 master의 history**: slave 시절에는 publish하지 않으므로, 승격 뒤 history는 오래된 boot 하한만 갖는다. 피어 applier의 frontier와 비교해 문제가 없다고 추론했지만 실측하지 않았다.
5. **CASCADE 삭제나 갱신이 `locator_lock_and_get_object_internal`을 거치는지**: 거치지 않으면 d1d02b9e4의 대기를 우회한다.

## 5. 총평

- 모듈 분리 쪽에서 worker, gate, inflight, pending, queue를 `applier/`로 나누고 소유권(coordinator 단독 대 공유 큐)을 주석으로 명확히 한 점은 좋다. master 쪽도 writeset 수집, history, 라벨 레코드의 책임이 대체로 잘 나뉘어 있다.
- 설계 일관성에는 두 군데 틈이 있다.
  1. master는 "도달할 수 없는 좌표"를 라벨로 낼 수 있다(E1, RESTART 하한).
  2. master는 "아직 publish하지 않은 충돌 상대"를 놓칠 수 있다(E2, FK 부모 INSERT).
  둘 다 slave gate의 전제(라벨은 ring 위 좌표이고, 그 좌표까지 적용되면 충돌이 해소된다)를 깨는 방향이다. 두 번째는 경로별 대기를 덧붙이는 현재 방식(A1)의 구조적 한계에서 온다.
- slave 쪽은 실패 처리가 비대칭이다. label 읽기 실패가 의존 없음으로 처리되고(E3), worker가 없을 때 무한 대기하며(E4), holder를 소비하지 않는 분기가 있다(E5). 실패는 보수적인 쪽(직렬화나 중단)으로 수렴하도록 통일하는 것이 좋다.
- 기존 구조와의 정합에서는 로그 레코드 타입(A4), 카탈로그 컬럼(A3), 전역 빌드 매크로(A2)가 업그레이드와 다른 클라이언트에 영향을 준다. 머지 전에 호환성 정책을 결정해야 한다.
- 테스트 용이성 면에서는 스케줄링 규칙이 log_applier.c의 static에 묶여 있다(M1). 위 결함들을 회귀 테스트로 고정하기 어렵다. coordinator 스케줄러를 `applier/` 모듈로 빼서 "label holder, ring, pending" 상호작용을 단위 테스트로 검증할 수 있게 하는 리팩토링을 우선 권한다.

등급별 건수: Critical 0, High 3 (E1, E2, A1), Medium 11 (E3, E4, E5, E6, E7, M1, M2, A2, A3, A4, A5), Low 14 (M3, M4, M5, M6, A6, A7, A8, R1, R2, R3, R4, R5, R6, R7). 합계 28건.
