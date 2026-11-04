# CBRD-27508 브랜치 리뷰 — 시스템 개발자 3년차

대상: `git diff a9a0dc78d 0e411f10f` (HEAD = 0e411f10f, 12 커밋). 행 번호는 모두 HEAD 기준이다.

## 1. 리뷰어 관점

- 역할: DB 엔진 내부 관점에서 봤다. 동시성(coordinator와 worker 사이의 동기화, 공유 캐시), 락과 mutex, 로그와 LSA(라벨, frontier, committed/required/max_committed), 메모리 수명(apply slot, fragment, tdes 벡터), 스레드 안전성이 중심이다.
- 연차: 함수 하나하나가 맞게 동작하는지, 에러가 빠짐없이 전파되는지(삼키거나 fail-open이 되지 않는지), 중복 코드와 일관성을 함께 봤다.
- 특히 **master가 만든 라벨이 slave gate에서 항상 해소될 수 있는가**라는 불변식을 양쪽 끝까지 따라가 검증했다. 라벨은 master에서 생성되고(writeset.cpp/log_manager.c) slave의 commit-order ring에서 소비된다(log_applier_gate.cpp).

## 2. 검토 범위와 실제로 읽은 경로

**정밀 분석 (전문 또는 해당 함수 전체를 읽음)**
- `src/transaction/applier/` 전체: `log_applier_gate.{hpp,cpp}`, `log_applier_inflight.{hpp,cpp}`, `log_applier_pending.{hpp,cpp}`, `log_applier_task_queue.{hpp,cpp}`, `log_applier_result_queue.{hpp,cpp}`, `log_applier_worker.{hpp,cpp}`, `log_applier_task.hpp`, `log_applier_result.hpp`, `log_applier_debug.hpp`
- `src/transaction/log_applier.c`
  - 신규 coordinator 함수 전부(700–1560행): `la_coordinator_drain_ready`, `_wait_for_commit_order_slot`, `_cover_commit`, `_dispatch_task`, `_collect_and_retire`, `_collect_results`, `_record_result`, `_complete_without_task`, `la_is_in_recovery_range`, `_wait_until_retired`, `_wait_for_inflight_slot`, `_release_apply_slot`, `_advance_committed_lsa`, `_add_result_stats`, `_store_apply_info_at_interval`, `_retire_results`, `la_apply_worker_*`, `la_coordinator_init_resources`, `la_start/stop_apply_workers`, `la_coordinator_commit_apply_info`
  - 페이지 캐시: `la_cache_buffer_replace`, `la_get_page_buffer`, `la_get_page`, `la_unfix/unpin/release_page_buffer`, `la_release_pinned_page_buffers`, `la_invalidate_page_buffer`, `la_decache_page_buffers`
  - `la_find_required_lsa`, `la_lower_lsa*`, `la_get/update_ha_apply_max_committed_lsa`, `la_init_repl_lists`, `la_add/find_apply_list`, `la_clear_*`, `la_set_repl_log`(앞부분), `la_get_wset_label`, `la_apply_repl_log`, `la_get_next_repl_item_from_log`, `la_detach_sysop_fragment`, `la_coordinator_submit_task`, `_process_sysop_end`, `_set_commit_dependency`, `_process_commit`, `la_log_record_process`, `la_change_state`, `la_commit_transaction`, `la_flush_repl_items`, `la_update_query_execute*`, `la_shutdown`, `la_coordinator_exit`, `la_apply_log_file` 전체(9630–10400행)
- `src/transaction/writeset.cpp` 전문, `writeset.hpp`, `writeset_types.hpp`, `writeset_history_map.{hpp,cpp}`
- `src/transaction/log_manager.c` diff 전체(`log_initialize_internal`의 RESTART floor, `log_sysop_commit_internal`, `log_sysop_abort`, `log_append_sysop_end_internal`, `log_sysop_fallback_reason`, `log_append_wset_label_and_sysop_end`, `log_append_repl_info_and_commit_log`, `log_append_wset_label_with_lock`, `log_commit_local`, `log_complete_for_2pc`)
- `log_tran_table.c`, `log_impl.h`, `log_record.hpp`, `log_append.cpp`, `log_recovery.c`, `replication.c` diff 전체
- `locator_sr.c` diff 전체(`locator_wset_*`, `locator_add_or_remove_index_internal`, `locator_update_index`, `locator_is_inserter_committing`, `locator_lock_and_get_object_internal`, `xlocator_repl_force`)
- `btree.c` diff(`btree_is_deleter_committing`, unique 검사 두 곳), `serial.c` diff와 `serial_update_serial_object` 주변
- `system_parameter.{c,h}`, `error_code.h`, `log_applier.h`, `heartbeat.h`, `schema_system_catalog_install.cpp`, `cubrid.msg` diff
- `unit_tests/log_applier/CMakeLists.txt`, `unit_tests/writeset/test_writeset.cpp`의 overflow·history_start 관련 케이스(530–590, 956–1014행)와 TEST_CASE 목록

**CS 쪽 (caller와 반환값만 확인)**
- `CMakeLists.txt`(MULTI_CONN_TO_A_SERVER 활성화), `cs/sa/cubrid CMakeLists.txt`, `work_space.{c,h}`(`ws_get_repl_obj_count`), `file_io.c`(`fileio_os_read/write` 분기)
- worker의 `db_restart_sub`/`db_shutdown_sub` 호출과 반환값 처리(`log_applier_worker.cpp:141-191`), `__gv_locator_repl`와 `ws_Resident_classes`가 `CUB_THREAD_LOCAL`인지(`locator_cl.h:167`, `work_space.h:458`)

## 3. 발견 사항

### 3.1 에러

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| E-1 | High | `log_manager.c:1503-1514`, `log_applier_gate.cpp:319-329`, `log_applier.c:7371-7372` | master 재시작 floor인 `append_lsa`가 라벨로 나가는데, slave ring에는 그 LSA가 없다. 그래서 frontier가 그 라벨을 넘지 못한다 | `wset_raise_history_start (&restart_lsa,"RESTART")`(`restart_lsa = log_Gl.hdr.append_lsa`), gate는 `dep <= frontier`일 때만 통과, ring에는 LOG_COMMIT와 라벨 붙은 SYSOP_END만 push된다 | master 재시작 후 첫 LOG_COMMIT가 라벨 X(=재시작 시점 append_lsa)를 단 사용자 트랜잭션이면 T가 park된다. ring head에 미완료인 T가 있으니 frontier는 X 아래에 머물고, 이후 커밋도 전부 라벨 ≥ X라 같이 park된다. slave 복제가 영구 정지하며 applier를 재시작해도 같은 상태가 재현된다 | 메커니즘은 확정, 발생 빈도는 추정 | 신규 |
| E-2 | High | `writeset.cpp:1111-1119` | commit-order fallback(overflow) 라벨이 `history_start` floor를 무시한다 | `if (tdes->wset_overflow) { LSA_COPY (wset_parent_out, &wset_History.prev_commit_lsa); return; }` | (a) master 재시작 직후 `prev_commit_lsa`가 NULL이다. 이때 첫 overflow 트랜잭션(문장 복제, 키 100만 개 초과)은 라벨이 **NULL**이 된다. slave는 `has_label`이 true이고 dep이 NULL이므로 즉시 dispatch하고, 아직 적용 중인 재시작 이전 backlog와 병렬로 같은 행을 적용해 순서가 역전된다. (b) serial sysop이 floor를 sysop_lsa로 올린 뒤에도 overflow 트랜잭션의 라벨은 그보다 작은 prev_commit_lsa로 나간다 | 확정 | 신규 |
| E-3 | Medium | `log_applier.c:1044-1046`, `1085-1087`, `7386-7400`; `log_applier_worker.cpp:378-391` | coordinator의 blocking `la_result_queue_pop`이 종료 요청과 worker 소멸을 보지 못한다 | `la_request_shutdown`은 flag만 세우고 result queue는 깨우지 않는다. `wait_until_retired`/`wait_for_inflight_slot`은 flag 검사 없이 pop에서 대기한다. recovery-range의 `do{...}while(!la_pending_is_empty())`에도 flag 검사가 없다 | 재시작 직후 recovery range에서 모든 worker가 `db_restart_sub`에 실패하면(예: max_clients) head task를 아무도 가져가지 않는다. coordinator는 영구 대기하고 SIGTERM에도 빠져나오지 못한다 | 경로는 확정, 트리거는 추정 | 신규 |
| E-4 | Medium | `log_applier.c:7206` | worker가 `la_Info.act_log.log_hdr->eof_lsa`를 cache mutex 없이 읽는다 | coordinator는 `check_reinit_copylog`에서 헤더 페이지를 제자리에 다시 읽는다(9901-9936행, mutex 보호). worker의 `LSA_GE (&curr_lsa, &la_Info.act_log.log_hdr->eof_lsa)`는 보호되지 않는다 | long transaction(항목 1000개 이상, 로그에서 다시 읽음)을 적용하던 worker가 헤더 re-read와 겹쳐 찢어진(torn) eof_lsa를 읽으면 루프를 일찍 끊는다. 그러면 나머지 항목이 적용되지 않은 채 커밋된다 | race는 확정, 결과는 추정 | 신규 |
| E-5 | Medium | `log_tran_table.c:1622`, `1706` | `wset_hashes.clear()`가 capacity를 반환하지 않는다 | `tdes->wset_hashes.clear ();`. 한도는 `history_size`(기본 1,000,000)이고 entry는 24B다 | 한도 직전(약 24MB)까지 키를 모은 트랜잭션이 끝나도 해당 tran index의 tdes가 그 메모리를 계속 쥔다. 세션마다 큰 배치를 돌리면 tran table 슬롯 수 × 최대 24MB(파라미터 최대값이면 240MB)가 영구 상주한다. overflow 경로만 `swap`으로 해제한다 | 확정 | 신규 |
| E-6 | Medium | `log_applier.c:6705`, `10329-10357` | role change 중 frontier가 30초 동안 움직이지 않으면 applier를 재시작한다 | `LA_DRAIN_TIMEOUT_MSEC 30000`, "frontier did not move ... giving up and restarting" | 승격 시점에 worker가 적용에 30초 넘게 걸리는 대형 트랜잭션을 처리 중이면, 정상 진행 중인데도 강제 재시작한다. 거의 끝난 작업이 rollback되고 recovery range에서 처음부터 다시 직렬 적용되므로 failover가 최소 30초에 재적용 시간만큼 지연된다 | 확정 | 신규 |
| E-7 | Low | `log_applier.c:4638-4666`, `7817-7818` | 라벨 읽기에 실패하면 fail-open으로 처리한다 | 실패 시 `LSA_SET_NULL (dependency_seq)`로 return하는데, 호출자는 무조건 `la_wset_label_trid = lrec->trid` | 라벨 페이지를 읽지 못하면 "라벨은 있고 dependency는 없음"으로 판정돼 즉시 dispatch된다. 무라벨 commit처럼 "이전 전체 대기"(fail-closed)로 가야 한다. 현재는 `la_get_page`가 무한 재시도라 실제 트리거는 드물다 | 확정(트리거는 희박) | 신규 |
| E-8 | Low | `log_applier.c:8185`, `8226` | 복제 트랜잭션을 커밋한 뒤 SCH_S 해제용 두 번째 `db_commit_transaction`의 오류가 task 실패로 보고된다 | `error = db_commit_transaction ();` → `return error;` | 실제 데이터는 커밋됐는데 result error가 되어 gate에 완료로 표시되지 않고, retire가 applier를 종료시킨다. 불필요한 재시작과 재적용이 생긴다 | 확정 | 신규 |
| E-9 | Low | `log_applier.c:8548`, `log_applier_pending.cpp:144-155` | 종료 시 SYSOP fragment slot이 누수된다 | `la_pending_clear`는 노드만 해제하고 `task.apply`(malloc된 fragment)는 해제하지 않는다. in-flight/task queue에 남은 fragment도 `la_inflight_init` 재초기화로 버려진다 | applier가 같은 프로세스 안에서 재시작될 때마다 미retire fragment의 LA_APPLY와 item이 누수된다 | 확정 | 신규 |
| E-10 | Low | `log_applier_worker.cpp:87`, `95-98` | `pthread_create` 실패 시 live count가 실제와 맞지 않는다 | `la_Live_worker_count = count;`를 먼저 설정하고, 생성에 실패하면 그냥 `return ER_FAILED` | 현재 호출자는 바로 `la_shutdown`을 부르므로 영향이 없다. 다만 호출자가 부분 기동을 허용하도록 바뀌면 "남은 worker 0명" 판정이 영원히 오지 않는다 | 확정 | 신규 |

**E-1 상세.** master는 재시작 후 history map이 비어 있으므로 `history_start`를 `log_Gl.hdr.append_lsa`로 올린다. 이 LSA는 **다음에 기록될 레코드의 위치**이고, 대개 LOG_COMMIT가 아니다. 주석에도 "Nothing is written to the log for this"라고 되어 있다. 이후 `wset_find_dependency_in_range`는 `wset_parent`를 `history_start`(=X)에서 시작한다. 충돌 후보가 없으면 `min(X, prev_commit)`은 X이고 floor도 X이므로 **재시작 이후의 모든 독립 커밋 라벨이 X**가 된다.

slave gate는 `!LSA_ISNULL(frontier) && LSA_LE(dep, frontier)`일 때만 통과시킨다. frontier는 ring entry의 commit_lsa로만 전진한다(`la_gate_advance_frontier`). ring에 들어가는 것은 `la_coordinator_submit_task`(LOG_COMMIT와 라벨이 붙은 SYSOP_END fragment), 그리고 `la_coordinator_complete_without_task`(라벨이 붙었지만 item이 없는 SYSOP_END)뿐이다. X에 해당하는 entry는 없다.

따라서 재시작 이전 마지막 커밋 C_last와 첫 라벨 커밋 T 사이에 **라벨 없이 완료될 수 있는 커밋**이 없으면 frontier는 C_last에서 멈춘다. 이런 커밋은 master 노드 applylogdb의 `_db_ha_apply_info` 커밋처럼 `LOG_CHECK_LOG_APPLIER` 경로에서만 나온다. 일반 트랜잭션은 item이 없어도 `log_append_repl_info_and_commit_log`가 라벨을 무조건 붙이므로(`log_manager.c:5013`) 같이 park된다. 기존 테스트가 통과한 이유는 master 쪽 applylogdb가 기동하면서 남기는 커밋이 우연히 X와 T 사이에 들어갔기 때문으로 추정한다. drain timeout도 이 상황을 풀지 못한다. 재시작하면 같은 라벨을 다시 읽기 때문이다.

수정 방향은 둘 중 하나다. (1) RESTART floor를 실제 ring에 들어가는 좌표로 정한다. 재시작 시 더미 커밋을 남기거나, floor를 "재시작 전 마지막 commit LSA"로 잡는다. (2) slave gate가 "ring에 없는 라벨"을 해석하도록 바꾼다. 예를 들어 dep보다 큰 entry보다 앞선 entry가 모두 완료되면 통과시킨다.

**E-2 상세.** `wset_find_dependency_from_history`의 overflow 분기는 `prev_commit_lsa`만 반환하고, 일반 경로(1091-1095행)나 `wset_find_sysop_fallback_dependency`(1444-1448행)와 달리 `history_start` floor를 적용하지 않는다.

- 재시작 직후 `prev_commit_lsa`는 NULL이다(`wset_history_initialize`). 따라서 첫 커밋이 overflow면 라벨이 NULL로 기록된다. slave `la_coordinator_set_commit_dependency`는 `has_label`이 true이면 dep을 그대로 쓰고, "이전 전체 대기" fallback(7574행)은 `!has_label`일 때만 적용한다. 결과적으로 문장 복제 DDL이나 대량 UPDATE 같은 overflow 트랜잭션이 재시작 이전 미적용 트랜잭션들과 **아무 순서 제약 없이** 병렬 적용된다.
- `log_manager.c:4071`의 SYSOP_COMMIT_ORDER floor는 sysop_lsa로 올라가는데 prev_commit_lsa는 그대로다. 그 뒤의 overflow 트랜잭션(예: `ALTER SERIAL`이나 `DROP SERIAL` 문장 복제)은 직전 serial fragment를 기다리지 않는다.
- 단위 테스트 "overflow demotes to commit order..."(`test_writeset.cpp:530`)와 "raising history_start..."(980행)는 이 조합을 검증하지 않는다.

수정은 overflow 분기에도 일반 경로와 같은 floor를 적용하면 된다. 문제가 E-1과 겹치므로 E-1 수정과 함께 정리하는 것이 좋다.

**E-3 상세.** `la_coordinator_wait_until_retired`와 `la_coordinator_wait_for_inflight_slot`는 `la_result_queue_pop`(무기한 `pthread_cond_wait`)을 쓴다. result queue는 `la_stop_apply_workers` 안에서만 shutdown되는데, 이 함수를 호출하는 것은 coordinator 자신이다. worker 기동 실패로 live worker가 0명이 되면 `la_request_shutdown`이 `la_applier_need_shutdown = true`만 세운다. 하지만 coordinator가 이미 pop에서 자고 있으면 깨울 주체가 없다.

recovery range 경로(7378-7411행)는 range 안의 커밋마다 `wait_until_retired`를 호출한다. 그래서 재시작 직후, 즉 worker 기동이 가장 불안정한 시점에 이 대기에 들어간다. 7386-7400행의 `do-while`에도 `la_applier_need_shutdown` 검사가 없다.

수정은 둘 중 하나다. pop 대신 `la_result_queue_wait_for_result(timeout)`과 flag 검사를 반복하는 루프로 바꾸거나, `la_request_shutdown`이 result queue에 broadcast하도록 한다.

**E-4 상세.** 470309f59 커밋은 "worker가 다른 archive 범위를 보지 않도록" 헤더 재읽기와 archive 삭제를 cache mutex 아래로 옮겼다. 하지만 같은 헤더의 `eof_lsa`를 worker가 `la_get_next_repl_item_from_log`(7206행)에서 mutex 없이 읽는다. `la_fetch_log_hdr`는 `la_log_io_read`로 `hdr_page`에 직접 덮어쓰므로, 엄밀히 말해 C++ 데이터 레이스(정의되지 않은 동작)다.

eof_lsa는 증가만 하므로 정상 값은 판정을 바꾸지 않는다. 문제는 찢어진 값을 읽었을 때 `curr_lsa`가 eof 이상으로 보여 break하는 경우다. 그러면 long transaction의 나머지 item을 조용히 건너뛰고 커밋한다. 수정은 coordinator가 eof_lsa를 원자 변수로 게시하거나 이 읽기도 mutex 안에서 하는 것이다.

**E-6 상세.** 30초 동안 frontier가 움직이지 않았다고 해서 worker가 멈췄다고 볼 수 없다. 대형 단일 트랜잭션을 정상 적용 중일 수 있다. 재시작하면 recovery range의 blocking 경로에서 결국 끝나므로 무한 반복(livelock)은 아니다. 하지만 promotion 시간이 불필요하게 늘어난다. 판정 기준을 "in-flight worker의 진행(적용 item 수 증가) 정지"로 바꾸거나, 진행 중인 task가 있으면 타이머를 갱신하는 편이 맞다.

### 3.2 모듈화

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| M-1 | Low | `log_manager.c:4000-4029`, `4774-4783` | "flush할 repl item 수 세기" 루프가 세 번 복제돼 있다 | `if ((repl_type == LOG_REPLICATION_DATA \|\| ... STATEMENT) && must_flush == LOG_REPL_NEED_FLUSH) repl_item_count++` 형태가 3회 반복된다 | 조건 하나(예: must_flush 종류)를 바꿀 때 한 곳을 놓치면 label 여부(`repl_item_count > 0`) 판정과 trace가 서로 어긋난다 | 확정 | 신규 |
| M-2 | Low | `log_applier.c:7330-7331` | 라벨 holder가 파일 중간의 전역 정적 변수이고 수명 관리가 분산돼 있다 | `static int la_wset_label_trid`, `la_wset_label_dependency_seq`. `la_init`과 `la_gate_init` 모두 초기화하지 않는다. COMMIT ≤ committed_lsa 경로(7753-7756행)에서는 소비(clear)하지 않는다 | 같은 프로세스에서 재시작할 때 이전 run의 holder가 남는다. trid가 단조 증가하므로 실제로 오매칭될 가능성은 낮다. 하지만 "라벨은 바로 다음 레코드에만 유효하다"는 불변식이 코드로 강제되지 않는다 | 확정(영향은 추정) | 신규 |
| M-3 | Low | `log_applier.c:6983`, `1026`, `7206` | worker가 `la_Info` 전역을 직접 읽는다 | `la_Info.last_committed_lsa`, `recovery_boundary_lsa`, `act_log.log_hdr` | "부팅 때 한 번 설정 후 읽기 전용"이라는 계약이 주석에만 있다. E-4처럼 실제로는 변하는 필드도 같은 방식으로 읽힌다. `LA_WORKER_CONFIG`에 값으로 넘기면 계약이 타입으로 드러난다 | 확정 | 신규 |
| M-4 | Low | `locator_sr.c:7793`, `7802-7804` | FK REF 수집이 호출자가 이미 꺼낸 키를 다시 추출하고, 행마다 부모 PK 도메인을 읽는다 | `btree_read_key_type (…ref_class_pk_btid)`, `heap_attrvalue_get_key (…btid_index…)` | 자식 행 하나, FK 하나마다 부모 PK 루트 페이지 fix와 키 재추출이 한 번씩 추가된다. 대량 FK INSERT에서 비용이 선형으로 늘어난다(성능 수치는 미측정). `key_dbvalue`/`key_domain`을 인자로 넘기면 된다 | 확정(비용은 추정) | 신규 |

### 3.3 아키텍처

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| A-1 | Medium | `log_applier.c:795-799`, `1023-1028`, `7378-7411` | recovery range의 상한이 copied log의 eof다. 그래서 재시작 후 backlog 전체가 직렬로 적용된다 | `if (LSA_GT (&log_hdr->eof_lsa, &bound)) LSA_COPY (&bound, &eof_lsa)`. range 안에서는 커밋마다 dispatch한 뒤 `wait_until_retired`를 호출한다 | slave가 크게 밀린 상태(copied log에 수십만 커밋)에서 applier가 재시작되면 실제로 dispatch된 적 없는 커밋까지 range에 포함된다. 그 결과 worker 1개와 같고 커밋마다 왕복까지 더해지는 속도로 따라잡는다. 병렬화 이득이 가장 필요한 crash 후 catch-up 구간에서 이득이 사라진다 | 확정 | 신규 |
| A-2 | Medium | `log_manager.c:5013`, `5602-5606`; `writeset.cpp:1026-1030`, `1173` | master 쪽 writeset 비용이 항상 켜져 있고 끌 방법이 없다 | 모든 복제 커밋에 label 레코드가 붙고(item이 없어도), 커밋 경로에서 전역 `seq_lock`을 두 번 잡는다(probe, baseline 갱신). `ha_apply_worker_count` 기본값이 1이어도 동일하다 | slave가 직렬 적용을 쓰는 배포에서도 master 커밋마다 전역 mutex와 로그 레코드 하나가 추가된다. 고동시성 커밋에서 직렬화 지점이 된다(수치는 미측정). 파라미터로 수집을 끄는 스위치가 필요하다 | 확정(성능은 추정) | 신규 |
| A-3 | Medium | `schema_system_catalog_install.cpp:1095-1097`, `log_applier.c:2896-2915` | `_db_ha_apply_info`에 컬럼을 추가했는데 기존 DB에 대한 이행 경로가 보이지 않는다 | `SELECT max_committed_lsa_pageid, max_committed_lsa_offset …`가 실패하면 `la_get_last_ha_applied_info` 에러로 이어지고 applylogdb가 기동하지 못한다 | 이전 버전으로 만든 DB(또는 migrate 도구가 컬럼을 추가하지 않은 DB)에서 applylogdb가 "Failed to initialize _db_ha_apply_info"로 반복 종료한다. 코드 주석의 TODO(final_lsa 재사용)로 카탈로그 변경을 피하는 안도 있다 | 추정(업그레이드 절차 미확인) | 신규 |
| A-4 | Low | `log_applier.c:2245`, `2275-2310` | 로그 페이지 I/O를 전역 cache mutex 안에서 한다 | `la_get_page_buffer`가 mutex를 잡고 `la_cache_buffer_replace`를 거쳐 `la_log_fetch`(archive open과 read 포함)를 수행한다 | worker N개와 coordinator의 페이지 miss가 모두 직렬화된다. long transaction이나 archive 구간을 재적용할 때 병렬도가 I/O 한 줄로 수렴한다 | 구조는 확정, 영향은 추정 | 신규 |
| A-5 | Low | `serial.c:1226-1250` | serial 키 수집이 사실상 쓰이지 않는다. 그런데 실패 경로는 바깥 트랜잭션 전체를 fallback시킨다 | serial 갱신은 항상 sysop 안에서 일어나고(1172-1175행), repl item이 있는 sysop은 `log_sysop_commit_internal`에서 commit-order로 라벨이 붙은 뒤 `wset_discard_sysop_keys`로 키가 버려진다. `BTID_IS_NULL`이면 `wset_fallback_to_commit_order (serial_tdes, WSET_FALLBACK_STATEMENT_REPLICATION)` | 수집한 키는 항상 버려진다. 반면 btid 캐시가 없으면 **바깥 사용자 트랜잭션 전체**가 overflow(commit order)로 강등되고 사유도 STATEMENT_REPLICATION으로 잘못 기록된다. trace도 "collect"로 남아 분석을 오도한다 | 확정 | 신규 |

### 3.4 리팩토링

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| F-1 | Low | `log_applier.c:434`, `872`, `1005`, `1249`, `1259`, `7512`, `7638`, `7764`, `7825`, `9589` | coordinator를 trace와 로그에서 "reader"라고 부른다 | `"[WSET] reader schedule …"`, `"applylogdb reader exit: …"` | 코드는 `la_coordinator_*`인데 운영 로그는 reader라서 로그 grep과 코드 추적이 어긋난다 | 확정 | 신규 |
| F-2 | Low | `log_applier_task_queue.cpp:53`, `165`, `186` | 아무도 기다리지 않는 condvar가 있다 | `la_Shared_task_not_full`은 signal과 broadcast만 있고 wait가 없다(push는 대기하지 않는다) | 동작에는 영향이 없다. 주석("the coordinator waits for a free slot")이 실제 설계와 다르다 | 확정 | 신규 |
| F-3 | Low | `log_applier_inflight.cpp:225-242`, `log_applier_pending.cpp:105-131` | 선형 탐색이 반복된다 | seq는 연속 단조인데 결과를 붙일 때마다 O(n)으로 찾는다. 이미 frontier가 바뀐 뒤에도 `la_pending_pop_ready`를 한 번 꺼낼 때마다 전체를 훑는다 | ring 용량이 worker 32 × 1024 = 32K라 pending이 쌓이면 drain 한 번이 O(n²)이 된다. 인덱스를 `seq - head.seq`로 계산하거나 pending을 dep 기준 정렬 구조로 바꾸면 된다 | 확정(성능은 추정) | 신규 |
| F-4 | Low | `log_applier.c:6705`, `1210`, `1434` | 상수, 상태, 테스트 훅의 위치와 형태가 정리돼 있지 않다 | `#define LA_DRAIN_TIMEOUT_MSEC`가 파일 중간에 있다. `static UINT64 last_store_ns`가 함수 static이라 재시작 후에도 남는다. 테스트 훅이 release 빌드에서 커밋마다 `getenv`를 호출한다 | 프로세스 내 재시작 후 첫 store 간격이 이전 run 값에 영향을 받는다. 테스트 전용 코드가 제품 경로에 남아 있다(자체 TODO로 인지) | 확정 | 신규 |
| F-5 | Low | `unit_tests/writeset/test_writeset.cpp:530-590`, `980-1014`, `unit_tests/log_applier/test_log_applier_gate.cpp` | 핵심 불변식을 검증하는 테스트가 없다 | overflow와 history_start 조합(E-2), "ring에 없는 라벨" 처리(E-1)를 다루는 케이스가 없다 | 이번 High 2건이 기존 테스트로 잡히지 않았다 | 확정 | 신규 |

## 4. 미검증 의심

- **문자열 키 해시의 등가성.** `wset_string_pseudo_bytes`는 `lc->mht2str`를 쓴다. 인덱스가 같은 키로 보는 두 문자열(예: PAD SPACE 비교에서 끝 공백만 다른 경우)이 항상 같은 pseudo key를 내는지는 확인하지 못했다. 다른 값이 나오면 충돌을 놓쳐 라벨이 누락된다(위험한 방향). collation별 `mht2str`를 직접 확인해야 한다.
- **라벨 없는 SYSOP_END의 item이 이후 fragment로 옮겨질 가능성.** `LOG_SYSOP_END_COMMIT`가 아닌 sysop 종료 유형이 repl item을 flush하면 라벨이 붙지 않아 item이 outer slot에 남는다. 그 뒤 같은 트랜잭션에서 라벨이 붙은 sysop이 나오면 `la_detach_sysop_fragment`가 `lsa <= fragment_lsa`인 item을 모두 fragment로 옮긴다(7304-7309행). 그러면 outer가 abort해도 적용된다. 이런 sysop 유형이 실제로 repl item을 내는지는 확인하지 못했다.
- **`min(wset_parent, prev_commit_snapshot)`의 안전성.** 이 선택(`writeset.cpp:1082-1089`)이 안전하려면 "실제로 충돌하는 선행 트랜잭션의 커밋은 항상 probe 시점의 prev_commit 이하"여야 한다. 이 전제는 d1d02b9e4와 79268ae56의 self-lock 대기(삽입자·삭제자 커밋 대기)에 기대고 있다. 행 락으로 직렬화되지 않는 다른 충돌 경로(예: FK 부모 키 S-lock 해제 시점)가 있으면 라벨이 낮아질 수 있다. 직접 반례는 찾지 못했다.
- **`la_worker_run`이 비치명 오류 뒤 같은 연결에서 다음 task를 계속 처리하는 것.** `la_commit_transaction` 실패처럼 flush나 server-down이 아닌 오류에서, 서버 쪽 트랜잭션 상태가 다음 task에 섞이지 않는지는 CS 내부라 확인하지 않았다.
- **`xlocator_repl_force`의 deadlock victim 처리.** `xtran_server_end_topop(ABORT)` 뒤 `goto exit_on_error`(`locator_sr.c:7036-7041`)에서 copyarea 응답이 부분적으로 채워진 상태로 반환된다. 클라이언트(`locator_repl_flush_all`)가 이를 전체 실패로 해석하는지 caller를 끝까지 추적하지 못했다.

## 5. 총평

slave 쪽 모듈 분리는 3년차 시각에서 보기에 잘 되어 있다. task/result queue, in-flight list, gate, pending이 각각 한 파일, 한 책임이고, coordinator 혼자 쓰는 구조물은 lock 없이, 공유 queue만 mutex로 보호한다는 원칙이 일관된다. 페이지 캐시의 fix/pin 관리, required_lsa 계산(fragment 포함), DONE 보류 경로도 주석과 코드가 맞아떨어진다. 충돌 의존이 있는 쌍에서 "retire 후 재시작 시 재적용 누락"이 생기지 않는다는 점도 추적해서 확인했다. 의존 때문에 frontier가 먼저 넘어가기 때문이다.

가장 큰 문제는 **master가 만드는 라벨과 slave ring의 계약이 문서화되어 있지 않고 강제되지도 않는다**는 점이다. slave gate는 "라벨은 ring에 존재하는 좌표"라는 전제로 동작한다. 그런데 master는 재시작 floor(append_lsa)처럼 ring에 절대 들어오지 않는 좌표를 라벨로 내보낸다(E-1). 반대로 commit-order fallback 경로는 floor를 빠뜨려 NULL이나 너무 낮은 라벨을 내보낸다(E-2). 앞의 것은 영구 정지로, 뒤의 것은 조용한 순서 역전으로 이어지며 둘 다 단위 테스트에 없다(F-5).

다음으로 중요한 것은 coordinator의 blocking 대기가 종료 신호를 보지 못하는 문제(E-3)다. 재시작 직후의 recovery range 경로에 몰려 있어 실제 장애 상황에서 드러나기 쉽다. 그 밖에 worker가 헤더를 잠금 없이 읽는 문제(E-4)와 recovery range 상한이 eof라서 crash 후 catch-up이 직렬화되는 문제(A-1)는 운영 품질에 직접 영향을 준다.

권장 순서는 다음과 같다.
1. 라벨 좌표 계약을 정한다. "ring에 들어가는 LSA만 라벨이 된다" 또는 "gate가 ring에 없는 라벨을 해석한다" 중 하나를 고르고, E-1과 E-2를 함께 수정한 뒤 해당 테스트를 추가한다.
2. coordinator의 모든 대기 지점을 timed wait와 shutdown 검사로 통일한다(E-3).
3. worker가 읽는 `la_Info` 필드를 config나 원자 변수로 정리한다(E-4, M-3).
4. 나머지 Medium과 Low는 정식 구현 단계에서 정리한다.
