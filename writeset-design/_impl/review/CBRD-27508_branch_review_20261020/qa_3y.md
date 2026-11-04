# CBRD-27508 브랜치 리뷰: QA 3년차

## 1. 리뷰어 관점

QA 3년차로서 함수 하나하나가 실패 경로에서 어떻게 동작하는지(에러 반환, 대기 루프의 탈출 조건, 자원 해제)를 먼저 봤다. 그다음 "이 경로를 테스트로 재현할 수 있는가"를 기준으로 단위테스트 커버리지와 빈틈을 확인했다. 중복 코드와 일관성(같은 규칙을 두 군데서 다르게 구현한 곳)은 회귀 위험의 출처로 보고 따로 표시했다.

## 2. 검토 범위와 실제로 읽은 경로

범위: `git diff a9a0dc78d 0e411f10f` (HEAD = 0e411f10f). 행번호는 모두 HEAD 기준이다. 기준선 비교는 `git show a9a0dc78d:<path>`로 했다.

- `src/transaction/applier/` 전체
  - `log_applier_gate.cpp/.hpp`: init, set_initial_frontier, order_push, advance_frontier, mark_completed, is_satisfied, order_find
  - `log_applier_inflight.cpp/.hpp`, `log_applier_pending.cpp/.hpp`
  - `log_applier_task_queue.cpp/.hpp`, `log_applier_result_queue.cpp/.hpp`
  - `log_applier_worker.cpp/.hpp`: start, join, main, run, startup_failed, context init/final, recdes pool
  - `log_applier_task.hpp`, `log_applier_result.hpp`, `log_applier_debug.hpp`
- `src/transaction/log_applier.c` 중 신규 coordinator/worker 경로
  - coordinator: drain_ready, wait_for_commit_order_slot, cover_commit, dispatch_task, collect_and_retire, collect_results, record_result, complete_without_task, wait_until_retired, wait_for_inflight_slot, release_apply_slot, advance_committed_lsa, add_result_stats, store_apply_info_at_interval, retire_results, commit_apply_info, init_resources, submit_task, process_sysop_end, set_commit_dependency, process_commit
  - worker: apply_worker_run_task / flush_task / commit_task / test_block_before_commit
  - 그 밖에 la_log_record_process, la_detach_sysop_fragment, la_get_wset_label, la_apply_repl_log, la_flush_repl_items, la_find_required_lsa, la_change_state, la_log_commit, la_commit_transaction, la_get/update_ha_apply_max_committed_lsa, la_get_last_ha_applied_info, la_init, la_shutdown, la_apply_log_file 메인 루프, la_add_apply_list/la_find_apply_list
- 호출측: `src/executables/util_cs.c` applylogdb 재시도 루프(3500~3590)
- master: `src/transaction/writeset.cpp/.hpp`, `writeset_types.hpp`, `writeset_history_map.cpp`
  - 수집: wset_add_write_key, wset_add_ref_key, wset_make_parent_midxkey, wset_push_hash, wset_fallback_to_commit_order, wset_error
  - 의존성·게시: wset_find_dependency_in_range, wset_find_dependency_from_history, wset_publish_with_capacity, wset_publish_commit_to_history, wset_find_sysop_fallback_dependency, wset_raise_history_start, wset_discard_sysop_keys, wset_abort_after_lsa
- `log_manager.c` diff 전체: sysop commit 라벨, label append, commit_local/2pc 의 find→append→publish 순서, RESTART history_start, log_to_string, log_dump_record
- `log_recovery.c`, `log_append.cpp`, `log_record.hpp`, `log_impl.h`, `log_tran_table.c` diff 전체
- `locator_sr.c`: locator_wset_error, locator_wset_collect_fk_ref, 인덱스 루프 수집부, locator_is_inserter_committing과 그 호출부
- `btree.c`: btree_is_deleter_committing과 두 호출부, `serial.c` 수집부, `replication.c` statement fallback
- `system_parameter.c/.h`, `error_code.h`, `cubrid.msg`, `schema_system_catalog_install.cpp` diff
- CS glue(호출측만): `CMakeLists.txt`의 MULTI_CONN 정의, `cs/CMakeLists.txt`, `work_space.c`의 ws_get_repl_obj_count, `file_io.c` diff
- 단위테스트: `unit_tests/log_applier/*` 전체, `unit_tests/writeset/` 중 test_writeset.cpp, test_writeset_config.cpp, test_main.cpp, CMakeLists.txt, stress/bench 태그

## 3. 발견 사항

등급 합계: Critical 0 / High 3 / Medium 11 / Low 17 (E 12건, M 6건, A 5건, R 8건)

### 3.1 에러

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| E1 | High | log_applier.c:1046, 1087 / log_applier_worker.cpp:382-391 / log_applier.c:1519-1522 | coordinator의 두 대기 루프가 shutdown 플래그를 보지 않고 결과 큐에서 무기한 블록한다 | `la_coordinator_wait_until_retired`·`wait_for_inflight_slot`이 `la_result_queue_pop`만 호출한다. 결과 큐를 깨우는 `la_result_queue_signal_shutdown`은 `la_stop_apply_workers`에만 있고, 워커가 부르는 `la_request_shutdown`은 `la_applier_need_shutdown = true`만 한다 | 재시작 직후 복구 구간의 첫 커밋을 dispatch하고 `wait_until_retired`에 들어간 상태에서 모든 워커가 `db_restart_sub` 실패로 빠지면, 아무도 결과를 넣지 않아 coordinator가 영구 정지한다. SIGTERM도 플래그만 세우므로 프로세스가 종료되지 않는다 | 확정 | 신규 |
| E2 | High | writeset.cpp:1106-1121 | overflow(=DDL 등 statement 복제 포함) 트랜잭션의 라벨이 history_start 하한을 적용받지 않는다 | overflow 분기는 `LSA_COPY (wset_parent_out, &wset_History.prev_commit_lsa)` 후 바로 return. 일반 경로(`wset_find_dependency_in_range`)와 `wset_find_sysop_fallback_dependency`는 history_start로 하한을 올린다 | (a) master 재시작 직후 첫 일반 커밋보다 먼저 커밋된 DDL은 prev_commit_lsa가 NULL이라 라벨이 NULL. slave에서 재시작 전 backlog DML과 병렬로 적용된다. (b) serial sysop S(라벨, history_start=S) 뒤, S의 outer commit 전에 커밋된 DDL은 라벨이 S 이전 커밋이 되어 S fragment와 순서 없이 적용된다 | 확정(코드), 충돌 발생은 시나리오 의존 | 신규 |
| E3 | High | log_manager.c:1503-1513 / log_applier_gate.cpp:281-291 | master 재시작 시 history_start를 "복구 전 append_lsa"로 올리는데, 이 LSA는 slave 게이트의 commit-order ring에 들어가는 지점이 아니다 | RESTART 직후 첫 라벨 커밋 C1의 dependency는 D(=restart append_lsa). 게이트는 `LSA_LE (dep, frontier)`만 통과시키고 frontier는 ring에 push된 commit/라벨된 SYSOP_END LSA로만 움직인다 | D와 C1 사이에 ring에 들어가는 레코드(라벨 없는 COMMIT 등)가 하나도 없으면 frontier는 D 이전에서 멈추고 C1은 영구 park된다. ring이 차면 `wait_for_commit_order_slot`이 무한 대기한다. 복구 구간 경로(log_applier.c:7386-7400)에서는 같은 원인으로 do-while이 바쁜 대기 상태로 돈다 | 추정(D~C1 사이에 commit이 끼는지 미확인) | 신규 |
| E4 | Medium | log_applier_worker.cpp:249-254 / util_cs.c:3573-3586 | 워커의 flush·server-down 에러가 프로세스 내 재시작을 막는다 | 워커가 apply 실패 시 `request_shutdown()` 호출, `la_applier_need_shutdown = true`. util_cs는 `!la_force_shutdown () && (ER_IS_SERVER_DOWN_ERROR … ER_LC_PARTIALLY_FAILED_TO_FLUSH)`일 때만 retry. develop은 flush 에러에 need_shutdown을 세우지 않는다(base log_applier.c:6248-6251) | slave 서버 재시작이나 bulk flush 실패가 나면 develop은 같은 프로세스에서 backoff 후 재접속했다. 브랜치에서는 EXIT_FAILURE로 프로세스가 종료된다. gate/pending의 "in-process restart" 대비 코드도 이 경로에서는 실행되지 않는다. 또 plain bool을 워커 스레드가 쓰고 coordinator가 읽는 데이터 레이스가 있다 | 확정 | 신규 |
| E5 | Medium | log_applier.c:4638-4666, 7817-7818, 7553-7578 | 라벨 읽기 실패가 "의존성 없음"으로 처리된다 | `la_get_wset_label`은 읽기 실패 시 `dependency_seq`를 NULL로 둔다. 호출자는 그래도 `la_wset_label_trid = lrec->trid`를 세우므로 `has_label = true`가 되어 tail fallback(`!has_label`일 때만 적용)을 건너뛴다 | 라벨 레코드가 페이지 경계에 걸리고 다음 페이지 fetch가 실패하면, 해당 커밋은 선행 커밋과 무관하게 즉시 dispatch된다. 무성 순서 위반으로 이어진다 | 확정(코드), 발생 빈도는 추정 | 신규 |
| E6 | Medium | log_applier.c:8548 / log_applier_pending.cpp:144-155 / log_applier_task_queue.cpp:155-159 | SYSOP fragment의 독립 LA_APPLY가 종료 시 해제되지 않는다 | fragment slot은 retire 시점에만 `free_and_init (entry->apply)`(log_applier.c:1131-1135)로 해제된다. `la_pending_clear`는 노드만 free하고, shutdown 시 task queue에 남은 task와 미retire in-flight 엔트리의 fragment는 누구도 해제하지 않는다 | fragment가 park되었거나 실행 중일 때 server-down 등으로 in-process 재시작하면 fragment와 그 item 리스트가 매번 누수된다 | 확정 | 신규 |
| E7 | Medium | log_applier.c:8185-8228 | 이미 커밋된 트랜잭션이 실패 결과로 보고될 수 있다 | 첫 `db_commit_transaction ()` 성공 후 cull 주기에 두 번째 `error = db_commit_transaction ();`의 결과로 error를 덮어써 반환한다(develop에는 두 번째 commit이 없다) | 두 번째 commit이 실패하면 워커 result.error ≠ NO_ERROR. coordinator는 gate에 completed 표시를 하지 않고, retire에서 에러로 applier를 멈춘다. 실제로는 slave에 반영된 트랜잭션이다 | 확정(코드), 두 번째 commit 실패 빈도는 추정 | 신규 |
| E8 | Low | log_applier.c:7330-7331, 7495-7502, 8447-8540 | 라벨 holder 정적 변수가 run마다 초기화되지 않고, 일부 경로에서 소비되지 않는다 | `la_wset_label_trid`·`la_wset_label_dependency_seq`는 `la_init`에서 초기화되지 않는다. `final <= committed_lsa`인 COMMIT·SYSOP_END 경로와 `complete_without_task` 경로는 holder를 비우지 않는다 | 이전 run이 라벨만 읽고 커밋은 못 읽은 채 끝나면, 새 run에서 같은 trid의 라벨 없는 SYSOP_END가 그 오래된 라벨을 자기 것으로 오인한다. trid가 단조 증가라 실제 피해는 작다고 본다 | 확정(상태 미초기화), 영향은 추정 | 신규 |
| E9 | Low | log_applier.c:1182 | `la_Info.log_record_time`이 0으로 리셋되거나 뒤로 간다 | `la_Info.log_record_time = result->log_record_time;`. fragment task는 `task.log_record_time = 0`(7464)이고 retire는 dispatch 순서다 | fragment가 retire될 때마다 0이 되어 adaptive commit interval의 지연 계산(9173)이 건너뛰어지고, 순서 역전 시 applyinfo 지연이 출렁인다 | 확정 | 신규 |
| E10 | Low | writeset.cpp:668-681 / locator_sr.c:7712-7724 | 키 빌드 실패 시 무관한 이전 에러 코드를 반환할 수 있다 | `if (error == ER_FAILED && er_errid () != NO_ERROR) return er_errid ();`, `locator_wset_error`도 `er_errid ()`가 있으면 그대로 반환 | `btree_read_key_type`이 NULL을 반환하면서 er_set을 하지 않으면, 앞서 처리된 경고나 에러 코드가 사용자 DML의 실패 원인으로 보고된다 | 추정 | 신규 |
| E11 | Low | log_applier.c:5931, 6019-6025 | flush 에러 루프에서 이전 iteration의 해제된 메시지를 다시 쓴다 | `server_err_msg = flush_err->error_msg;`는 NULL이 아닐 때만 갱신되고, iteration 끝에서 `ws_free_repl_flush_error`가 error_msg를 free한다. `class_name`도 루프 밖에서 한 번만 초기화된다 | 부분 flush 실패 2건 중 두 번째의 error_msg가 NULL이면 해제된 문자열이 er_set에 넘어간다(use-after-free). class_name도 앞 건의 이름이 찍힌다 | 확정 | 기존 |
| E12 | Low | log_manager.c:7347-7472 | diagdb 로그 덤프가 새 레코드 타입을 Unknown으로 출력한다 | `log_dump_record` switch에 `LOG_DUMMY_WSET_LABEL` case가 없어 default `"log_dump: Unknown record type"`으로 간다 | 모든 HA 커밋 앞에 라벨이 붙으므로 diagdb 로그 덤프가 커밋마다 Unknown 경고를 찍고 라벨 내용(dependency_seq)을 보여주지 않는다. 장애 분석 시 혼란을 준다 | 확정 | 신규 |

#### E1 상세
- 근거: `log_applier.c:1039-1069`(wait_until_retired), `1080-1110`(wait_for_inflight_slot). 두 루프 모두 `la_applier_need_shutdown`을 확인하지 않는다. 같은 성격의 `wait_for_commit_order_slot`(737-761)은 확인한다.
- `log_applier_worker.cpp:388-391`의 주석은 "When no worker is left nothing would ever take a task, so the applier is told to stop"이라고 하지만, 실제 전달 수단은 플래그뿐이라 블록 중인 coordinator에는 닿지 않는다.
- 재현 시나리오: `ha_apply_worker_count=2`, slave 서버의 max_clients를 coordinator+1로 제한 → 복구 구간이 있는 상태(이전 run이 비정상 종료)로 applylogdb 시작 → 두 워커 모두 `start_session_failed` → coordinator가 복구 구간 첫 커밋에서 정지. SIGTERM을 보내도 종료되지 않는다.
- 제안: `la_request_shutdown`에서 `la_result_queue_signal_shutdown ()`도 부르거나, 두 루프를 `la_result_queue_wait_for_result (100)` + `try_pop` + 플래그 확인으로 바꾼다. 이 경우 `la_result_queue_pop`은 shutdown 후에도 남은 결과를 반환하므로(183행) 그 의미를 테스트로 고정해야 한다.

#### E2 상세
- `wset_find_dependency_in_range`는 `wset_parent`를 history_start에서 시작하고 마지막에 다시 하한을 적용한다(1032, 1092-1096). `wset_find_sysop_fallback_dependency`도 같다(1446-1450). overflow 분기만 빠져 있다.
- `log_manager.c:4064-4071`의 주석 "Every later transaction must wait for this operation"과, RESTART 주석 "makes every later replicated commit wait on the slave until everything written before the restart has been applied"를 overflow 트랜잭션이 위반한다.
- `replication.c:534-536`에서 statement 복제(DDL)는 모두 overflow로 강등되므로, 이 경로는 "드문 대형 트랜잭션"이 아니라 DDL 전체가 탄다.
- 단위테스트 공백: `test_writeset.cpp:530`의 overflow 테스트는 history_start가 NULL인 상태만 보고, `:980`의 raise 테스트는 일반 트랜잭션만 본다. "raise 이후 overflow 트랜잭션의 라벨"과 "RESTART 직후 overflow 트랜잭션의 라벨"이 테스트되지 않는다.
- 제안: overflow 분기에도 history_start 하한을 적용하고 위 두 케이스를 단위테스트로 추가한다.

#### E3 상세
- `wset_find_dependency_in_range`에서 재시작 직후에는 map이 비어 있고 prev_commit_lsa가 NULL이므로 결과는 history_start = D가 된다.
- slave 쪽 frontier 갱신 지점은 `la_gate_advance_frontier`(ring head의 commit_lsa로만 이동)와 `la_gate_set_initial_frontier`뿐이다. dependency가 ring에 없는 LSA인 경우를 처리하는 코드는 없다.
- 확정하지 못한 부분은 master가 재시작한 뒤 HA active가 되기 전에 라벨 없는 커밋이 로그에 남는지다. 남는다면 frontier가 D를 넘어가 문제가 사라진다. master 단독 재시작(failover 없이) 후 slave applier가 진행하는지 확인하는 테스트가 필요하다.
- 제안: slave에서 "dep가 ring tail보다 크고 자기 commit보다 작으면 ring tail로 낮춘다"는 규칙을 두거나, master가 재시작 시 D 지점에 ring에 들어가는 레코드(예: 라벨된 dummy)를 남긴다.

#### E4 상세
- 브랜치에서 `la_coordinator_process_commit`(7648-7651)도 submit 실패 시 need_shutdown을 세운다. 워커 결과로 올라온 server-down도 이 경로를 거치면 재시도가 막힌다.
- heartbeat가 프로세스를 다시 띄우므로 기능이 완전히 멈추지는 않는다고 본다(추정). 그래도 develop과 복구 경로가 달라지고(backoff, `need_er_reinit`), in-process 재시작 경로(`la_gate_init`의 frontier 리셋, `la_pending_clear`)는 실제로 거의 실행되지 않는 코드가 된다.
- 제안: 워커는 "중단 요청"과 "프로세스 종료 요청"을 구분해, 재시도 가능한 에러에는 별도 플래그를 쓴다. 플래그는 `std::atomic<bool>`로 바꾼다.

#### E5 상세
- 주석(4632)은 "NULL LSA if it cannot be read"라고만 적고, 그 NULL이 slave에서 "의존 없음"으로 해석된다는 점은 다루지 않는다.
- 제안: 읽기 실패 시 holder를 세우지 않거나(그러면 라벨 없는 커밋으로 처리되어 tail fallback을 탄다) 에러를 반환해 applier를 멈춘다.

#### E6 상세
- `la_shutdown`의 주석 "parked tasks point at the apply slots freed below"는 repl_lists slot만 염두에 둔 것이다. fragment slot은 repl_lists에 없으므로 그 아래 해제 루프에서도 빠진다.
- 제안: `la_pending_clear`에 콜백을 받아 `rectype == LOG_SYSOP_END`이면 `la_free_all_repl_items + free`하고, in-flight 잔여 엔트리와 task queue 잔여 task도 같은 방식으로 정리한다.

#### E7 상세
- 두 번째 commit은 SCH_S 락 해제가 목적(주석 8219-8223)이다. 실패해도 적용된 트랜잭션의 결과는 바뀌지 않으므로, 실패는 로그로만 남기고 첫 commit의 결과를 반환해야 한다.
- 이 경로를 막는 테스트는 없다.

### 3.2 모듈화

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| M1 | Medium | log_applier.c:1039-1110 | wait_until_retired와 wait_for_inflight_slot의 본문이 같다 | 두 함수 모두 `pop → record_result → advance_frontier → retire_results` 4단계이고 while 조건만 다르다 | E1 같은 수정이 한쪽에만 들어가면 다른 쪽에 같은 hang이 남는다 | 확정 | 신규 |
| M2 | Medium | locator_sr.c:13195-13210, 13300-13339 / btree.c:27208-27224 | "커밋 중인 inserter/deleter의 MVCCID self-lock 확인 후 대기" 규칙이 두 파일에 따로 구현되어 있다 | 둘 다 `log_does_allow_replication`, `MVCCID_IS_NORMAL`, `logtb_is_current_mvccid`, `mvcc_table.is_active`를 검사하고 `lock_transaction_mvccid (…, S_LOCK, LK_COND_LOCK)` 후 unlock하는 같은 패턴이다 | 조건 하나(예: SA_MODE 처리, retained lock 예외)를 한쪽만 고치면 insert/delete 순서 보장이 경로마다 달라진다 | 확정 | 신규 |
| M3 | Low | log_manager.c:4001-4010, 4019-4028, 4773-4783 | 미flush 복제 레코드 개수 세는 루프가 3번 반복된다 | 동일 조건 `(repl_type == DATA \|\| STATEMENT) && must_flush == LOG_REPL_NEED_FLUSH`. 두 번째 루프 결과(flushed_item_count)는 trace에서만 쓰는데 trace 레벨과 무관하게 매 sysop마다 실행된다 | 조건이 바뀌면 세 곳을 같이 고쳐야 한다. 비 trace 경로에 불필요한 O(n) 순회가 생긴다 | 확정 | 신규 |
| M4 | Low | writeset.cpp:668-681 / locator_sr.c:7712-7724 | 키 빌드 에러 헬퍼가 두 개다 | `wset_error`와 `locator_wset_error`가 같은 ER_HA_WRITESET_KEY_BUILD_FAILED를 다르게 처리한다(앞은 ER_FAILED만 er_errid로 대체, 뒤는 무조건 er_errid 우선) | 같은 실패라도 경로에 따라 반환 코드가 달라 테스트 기대값을 고정하기 어렵다 | 확정 | 신규 |
| M5 | Low | log_applier_task_queue.cpp:53, 165, 186 | 아무도 기다리지 않는 condition variable | `la_Shared_task_not_full`은 signal/broadcast만 있고 wait가 없다. coordinator는 `la_task_queue_is_full`로 폴링한다 | 동작 영향은 없지만, 주석("the coordinator waits for a free slot")이 실제 설계와 다르다 | 확정 | 신규 |
| M6 | Medium | log_applier.c:1208-1222, 7330-7331 | coordinator 스케줄링 상태가 함수 static·파일 static에 흩어져 있다 | `static UINT64 last_store_ns`, 라벨 holder 2개, `la_Drain_wait_start_ns` 등 | run마다 초기화 지점이 제각각이라 E8 같은 누락이 생긴다. 단위테스트에서 상태를 리셋할 방법이 없다 | 확정 | 신규 |

### 3.3 아키텍처

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| A1 | Medium | log_record.hpp:140 / log_applier.c:7837 (base 6336) / schema_system_catalog_install.cpp:1095-1097 / log_applier.c:2897, 3349 | 버전 혼합·업그레이드 호환성 처리가 없다 | 새 레코드 타입 53은 develop의 `LOG_LARGER_LOGREC_TYPE`(=53) 값과 같다. develop applier는 `lrec->type >= LOG_LARGER_LOGREC_TYPE`이면 ER_LOG_PAGE_CORRUPTED로 처리한다. `_db_ha_apply_info`에 컬럼 2개가 추가됐지만 마이그레이션이 없고, 시작 시 SELECT 실패는 그대로 에러로 반환된다 | (a) master만 먼저 올리면 develop slave applier가 첫 라벨에서 로그 손상으로 멈춘다. (b) 기존 DB에 새 바이너리를 올리면 `la_get_ha_apply_max_committed_lsa` SELECT가 실패해 applier가 "Failed to initialize _db_ha_apply_info"로 시작하지 못한다 | 확정(코드), 실제 업그레이드 절차는 미확인 | 신규 |
| A2 | Medium | log_applier.c:1431-1460, 1404 | 테스트 전용 지연 훅이 release 빌드에 남아 있다 | 매 커밋마다 `getenv ("CUBRID_HA_TEST_BLOCK_CLASS")`, 일치하면 기본 60000ms `usleep` | 운영 환경에 해당 환경변수가 남아 있으면 그 클래스의 커밋마다 1분씩 복제가 멈춘다. 커밋당 getenv 비용도 붙는다. TODO 주석이 이미 인정한 부분이다 | 확정 | 신규 |
| A3 | Medium | locator_sr.c:8051-8060, 8758-8770, 7795-7808 / serial.c:1236-1239 / writeset.cpp:530-537 | writeset 수집 실패가 master의 사용자 DML을 실패시킨다 | `wset_add_write_key`/`wset_add_ref_key` 실패 시 `goto error`. `wset_push_hash`의 bad_alloc은 ER_OUT_OF_VIRTUAL_MEMORY를 반환한다 | 복제 메타데이터(키 해시) 생성 실패나 domain 누락 assert(`wset_add_write_key`의 "composite key without a domain")가 release에서 사용자 INSERT/UPDATE 실패로 이어진다. commit-order fallback이 이미 있으므로 가용성 측면에서는 fallback이 안전하다. serial.c 주석은 의도한 설계라고 밝힌다. 설계 판단 항목으로 올린다 | 확정 | 신규 |
| A4 | Low | log_applier_pending.cpp:98-131 / log_applier_inflight.cpp:225-241 / log_applier.c:7414, 7420 | coordinator 핫패스의 선형 탐색 | `la_pending_pop_ready`는 매번 head부터 전체 스캔하고, `drain_ready`는 커밋마다 호출된다. `la_inflight_find_by_seq`는 결과마다 O(n)이다. 둘 다 최대 worker_count×1024(=32768)개다 | 느린 head 하나 뒤에 수만 개가 park되면 커밋마다 수만 번의 게이트 판정이 돌아 coordinator가 병목이 된다. seq는 단조 증가라 in-flight는 O(1) 인덱싱이 가능하다 | 확정(복잡도), 성능 영향은 추정 | 신규 |
| A5 | Low | locator_sr.c:13300-13310 / btree.c:27214-27221 | 커밋이 끝난 inserter/deleter에도 lock manager 왕복이 생긴다 | vacuum 전 INSID/DELID가 유효한 모든 행에서, UPDATE/DELETE와 unique 검사 때 조건부 S lock 요청과 해제가 1회씩 일어난다 | master 쓰기 부하에서 lock manager 경합이 늘어난다. 주석은 "costs one conditional lock request"라고 하지만 측정 근거는 코드에 없다 | 추정 | 신규 |

### 3.4 리팩토링

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| R1 | Medium | unit_tests/log_applier/CMakeLists.txt:21-25 / log_applier.c 7361-7651 | 순서 정확성을 결정하는 coordinator 로직에 단위테스트가 없다 | 테스트는 gate·pending·inflight·queue의 자료구조만 다룬다. submit_task(1-worker·복구 구간 분기), set_commit_dependency(라벨/fragment/tail fallback), process_sysop_end, detach_sysop_fragment, cover_commit, 라벨 holder는 log_applier.c의 static 함수라 테스트할 수 없다. gate의 TODO(log_applier_gate.cpp:275-278)도 parent/child 전용 테스트가 없다고 적어 두었다 | E2·E5·E8 같은 결함을 막을 회귀망이 HA 실측 하니스뿐이다 | 확정 | 신규 |
| R2 | Low | unit_tests/log_applier/test_log_applier_gate.cpp 전체 | ring wrap-around 상태의 이진 탐색이 테스트되지 않는다 | 모든 케이스가 capacity 8에 3개 이하만 push해 head가 0에서 움직이지 않는다 | `la_gate_order_find`와 `la_gate_order_at`의 modulo 계산이 바뀌어도 테스트가 잡지 못한다 | 확정 | 신규 |
| R3 | Low | unit_tests/log_applier/test_log_applier_queues.cpp | coordinator가 실제로 쓰는 블로킹 `la_result_queue_pop`이 테스트되지 않는다 | try_pop, wait_for_result, push만 다룬다. shutdown 후 pop이 남은 결과를 돌려주는 동작(result_queue.cpp:183)과, task queue가 남은 task를 버리는 동작의 비대칭도 고정되어 있지 않다 | E1 수정 시 의미가 바뀌어도 탐지되지 않는다 | 확정 | 신규 |
| R4 | Low | test_log_applier_queues.cpp:81, 93, 172, 194 | sleep 50ms로 "대기 중"을 가정한다 | `sleep_for (milliseconds (50))` 후 push/shutdown | 스레드가 아직 wait에 들어가기 전이어도 테스트가 통과하므로 "깨우기" 자체는 검증되지 않는다. 오탐은 없지만 검증력이 약하다 | 확정 | 신규 |
| R5 | Low | unit_tests/writeset/test_writeset_stress.cpp:216, 395 등 17개 TEST_CASE | stress·benchmark가 일반 단위테스트와 같은 바이너리에 숨김 태그 없이 들어 있다 | 태그가 `[stress]`, `[benchmark]`이고 Catch2 숨김 태그(`[.]`)가 아니다. 스레드 수를 512까지 돌린다 | 필터 없이 `test_writeset`을 실행하면 장시간 stress가 함께 돈다. CI에 넣으면 시간 초과나 불안정의 원인이 된다 | 확정 | 신규 |
| R6 | Low | log_applier.c:870, 1018, 1252-1264, 7505-7518, 9590, 7819 등 | 로그·trace 문자열에 "reader"가 남아 있다 | `"[WSET] reader schedule"`, `"[WSET] reader retire"`, `"applylogdb reader exit"`, `"reader defer_sysop_end"` 등 14곳 | 코드와 문서는 coordinator라 부르는데 로그는 reader라고 찍혀 장애 분석 시 grep 키워드가 어긋난다 | 확정 | 신규 |
| R7 | Low | writeset.cpp:774-786, 798 | wset_make_parent_midxkey의 불필요한 상태 | `initialized_count`는 항상 column_count가 된다. `*has_reference = true`를 두 번 쓴다 | 정리 대상. 동작 영향은 없다 | 확정 | 신규 |
| R8 | Low | unit_tests/log_applier/test_log_applier_common.hpp:32-33 | 레코드 타입 하드코딩 | `TEST_RECTYPE_COMMIT = 17`, `TEST_RECTYPE_SYSOP_END = 20` | 실제 enum과 어긋나도 모듈 테스트는 통과한다. coordinator 테스트가 생기면 rectype 분기 검증이 틀어질 수 있다. `log_record.hpp`를 include하면 된다 | 확정 | 신규 |

## 4. 미검증 의심

- **워커들의 ws_Resident_classes 동시 순회**: `log_applier.c:8211-8217`에서 각 워커가 `ws_Resident_classes`를 순회하며 `ws_intern_instances`를 호출한다. MULTI_CONN 모드에서 이 리스트가 sub-client별인지 프로세스 전역인지 확인하지 못했다. 전역이면 동시 순회·수정 레이스가 된다. CS 내부라 범위 밖으로 두었다.
- **MULTI_CONN_TO_A_SERVER 전역 활성화**: `CMakeLists.txt:607`의 `add_definitions`가 applylogdb뿐 아니라 csql, CAS 등 모든 클라이언트 빌드에 적용된다. 이 브랜치가 그 영향을 검증했는지 코드로는 확인할 수 없다.
- **워커 세션의 lock timeout**: util_cs는 메인 연결에 `db_set_lock_timeout (-1)`을 건다. `db_restart_sub`로 연 워커 세션의 lock timeout이 무엇인지 확인하지 못했다. 무한이면 slave에서 락 대기 중인 워커 때문에 E1과 같은 방식으로 종료가 막힌다.
- **la_get_next_repl_item_from_log의 NULL 처리(기존)**: `la_get_page` 반환값을 확인하지 않고, header malloc 실패 시 NULL을 반환해 long transaction의 나머지 item이 조용히 잘린 채 커밋될 수 있다(log_applier.c:7189-7202). develop에도 같은 코드가 있다. 워커 병렬화로 페이지 경쟁이 늘어 발생 가능성이 커졌는지는 확인하지 못했다.
- **E3의 실제 발생 여부**: master가 재시작한 뒤 첫 라벨 커밋 전에 라벨 없는 COMMIT이 로그에 남는지(boot 중 내부 트랜잭션, 2PC 정리 등) 확인하지 못했다.
- **복구 구간 INSERT duplicate 무시의 은폐 위험**: `log_applier.c:5966-5990`은 복구 구간에서 ER_BTREE_UNIQUE_FAILED를 fail_counter 없이 넘긴다. 구간 안에서 원래부터 존재하던 진짜 불일치도 함께 가려진다. 설계상 감수한 것으로 보이지만, `recovery_skipped_counter`가 운영 지표(applyinfo)에 노출되는지 확인하지 못했다.

## 5. 총평

자료구조 모듈(gate, pending, inflight, 두 큐)은 책임이 잘 나뉘어 있고 주석도 자체 완결적이다. 각 모듈의 정상 경로는 단위테스트로 덮여 있다. 문제는 그 바깥에 있다. 순서 정확성과 생존성을 실제로 결정하는 coordinator 스케줄링과 master의 라벨 계산 예외 경로에 결함과 테스트 공백이 모여 있다.

- **실패 경로의 탈출 조건**: coordinator의 두 블로킹 대기는 shutdown을 보지 않는다(E1). 워커 에러는 develop과 달리 프로세스 종료로 이어진다(E4). 정상 부하 테스트에서는 드러나지 않고 워커 기동 실패나 서버 재시작 같은 장애 주입에서만 나타나는 유형이다.
- **라벨 규칙의 일관성**: history_start 하한이 일반 경로와 sysop fallback에는 있고 overflow(DDL) 경로에는 없다(E2). RESTART 하한은 slave 게이트가 모르는 LSA를 가리킬 수 있다(E3, 추정). 라벨 읽기 실패는 "의존 없음"으로 해석된다(E5). 셋 다 "라벨이 가리키는 LSA는 항상 slave ring에 존재하고 모든 경로가 같은 하한을 쓴다"는 불변식이 코드 한 곳에 정의되어 있지 않아서 생긴 문제다.
- **호환성**: 새 로그 레코드 타입과 catalog 컬럼 추가에 버전 혼합·마이그레이션 대책이 없다(A1).

우선순위는 다음과 같이 제안한다. E1·E2를 먼저 고치고, 그 수정과 함께 "raise/restart 이후 overflow 라벨" 단위테스트와 "워커 전원 기동 실패 시 coordinator 종료" 재현 테스트를 추가한다. 이어서 master 단독 재시작 후 slave 진행 여부를 HA 실측으로 확인해 E3를 확정하거나 기각한다. 중기적으로는 coordinator 스케줄링(submit/set_dependency/sysop fragment)을 log_applier.c에서 분리해 gate 모듈처럼 단위테스트가 가능한 구조로 옮기는 것(R1, M6)이 회귀 위험을 가장 크게 줄인다.
