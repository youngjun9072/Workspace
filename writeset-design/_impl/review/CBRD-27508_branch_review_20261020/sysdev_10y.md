# CBRD-27508 브랜치 리뷰: 시스템 개발자 10년차 관점

## 1. 리뷰어 관점

DB 엔진 내부(동시성, 락, 로그/LSA, 메모리 수명, 스레드 안전)를 기준으로 봤다. 특히 **master가 만든 라벨이 slave gate의 진행 규칙과 맞물리는지**를 끝까지 확인했다. 라벨이 commit LSA가 아닌 좌표를 가리키는 경우, 락 없이 커밋 순서가 뒤집히는 구간, 폴백 경로가 history_start 바닥을 지키는지가 그 대상이다. 연차 관점에서는 재시작, failover, 롤링 업그레이드, 카탈로그 호환, 성능 절벽처럼 장기 운영에서 터질 숨은 위험과 기존 CUBRID 구조와의 정합을 함께 봤다.

## 2. 검토 범위와 실제로 읽은 경로

범위는 `git diff a9a0dc78d 0e411f10f`(12 커밋, HEAD = 0e411f10f)이다. 행 번호는 HEAD 기준이다.

- **master writeset**
  - `writeset.cpp` 전체(1~1489): fnv1a, string/midxkey hash, add_write_key/add_ref_key, find_dependency_in_range/from_history, publish_with_capacity, reserve/release_capacity, clear_overflow_history, discard_sysop_keys, abort_after_lsa, find_sysop_fallback_dependency, raise_history_start
  - `writeset.hpp`, `writeset_types.hpp`, `writeset_history_map.{hpp,cpp}`
- **log**
  - `log_manager.c`: log_initialize_internal(1503-1515), log_sysop_start(wset_mark), log_sysop_commit_internal(3928-4099), log_sysop_abort(4253-4256), log_append_sysop_end_internal, log_sysop_fallback_reason, log_append_wset_label_and_sysop_end, log_append_repl_info_and_commit_log, log_append_wset_label_with_lock, log_commit_local(5541-5630), log_complete_for_2pc, log_dump_record(7347-7470), log_dump 루프
  - `log_append.cpp`, `log_record.hpp`, `log_impl.h`, `log_tran_table.c`(init/clear/copy_to/undefine), `log_recovery.c`의 추가 case
- **키 수집과 대기**
  - `locator_sr.c`: locator_wset_collect_fk_ref, locator_add_or_remove_index_internal의 수집부, locator_update_index의 수집부와 꼬리 PK 경로, locator_is_inserter_committing, locator_lock_and_get_object_internal 대기, xlocator_repl_force 데드락 처리
  - `btree.c`: btree_is_deleter_committing, unique_of_unique/non_unique의 DELETE_RECORD_DELETED, DELETE_RECORD_CAN_DELETE 경로, btree_check_foreign_key, btree_find_foreign_key
  - `serial.c`, `replication.c`(repl_log_insert_statement, repl_log_abort_after_lsa)
- **slave**
  - `applier/*` 전부: gate, pending, inflight, task_queue, result_queue, worker, task/result/debug 헤더
  - `log_applier.c`
    - coordinator 계열(700-1290): drain_ready, wait_for_commit_order_slot, cover_commit, dispatch_task, collect/record/retire, complete_without_task, is_in_recovery_range, wait_until_retired, wait_for_inflight_slot
    - worker 계열(1308-1460): la_apply_worker_*, test hook
    - 페이지 캐시와 헤더(2036-2330, 2547-2654, 3679): la_log_fetch, la_get_page_buffer, la_find_required_lsa, la_fetch_log_hdr
    - 재적용 경계(2869-3005): max_committed_lsa 조회와 저장
    - 적용(5970-6030, 6950-7100): flush 에러 억제, la_apply_repl_log
    - 로그 처리(7236-7857): sysop fragment, submit_task, process_sysop_end, set_commit_dependency, process_commit, la_log_record_process
    - 상태와 메인 루프(7902-8000, 9557, 9840-10370): la_change_state(DONE 보류), check_reinit_copylog, la_apply_log_file 메인 루프(drain backstop)
- **CS glue**(caller만 확인): `CMakeLists.txt`(MULTI_CONN 전역 define), `cs/sa/cubrid CMakeLists`, `work_space.{c,h}`(ws_get_repl_obj_count), `file_io.c`(pread/pwrite 분기), `schema_system_catalog_install.cpp`(_db_ha_apply_info 컬럼 추가), `log_applier.h`(LA_IS_FLUSH_ERROR), worker의 db_restart_sub/db_shutdown_sub 호출부
- **unit_tests**: `test_log_applier_gate.cpp` 케이스 목록(라벨이 ring 사이에 떨어지는 경우가 있는지 확인)과 writeset 테스트 목록

## 3. 발견 사항

### 3.1 에러

| ID | 등급 | 위치 | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| E-1 | High | writeset.cpp:1111-1118 | commit-order 폴백(overflow, statement 복제) 라벨이 history_start 바닥을 적용하지 않음 | `if (tdes->wset_overflow) { LSA_COPY (wset_parent_out, &wset_History.prev_commit_lsa); ... return; }`. 일반 경로(1091-1095)와 sysop 경로(1444-1448)는 history_start로 바닥을 올린다 | (a) master 재시작 직후 처음 복제되는 커밋이 DDL(statement 복제)이면 prev_commit_lsa가 NULL이라 라벨도 NULL이다. slave는 이 DDL을 즉시 dispatch하고, 재시작 전 backlog DML과 병렬로 돈다. 예: DROP/ALTER가 먼저 적용되면 뒤의 DML이 실패하거나 결과가 갈라진다. (b) 평상시에도 serial sysop이 history_start를 sysop LSA까지 올린 직후의 overflow 트랜잭션은 그보다 낮은 prev_commit_lsa를 라벨로 받는다. 예: DROP SERIAL이 다른 트랜잭션의 serial fragment보다 먼저 적용되면 fragment UPDATE가 실패한다 | 확정(코드) | 신규 |
| E-2 | High | log_manager.c:1503-1515, log_applier_gate.cpp:466-477, log_applier.c:737-761 | RESTART 바닥(append_lsa)은 slave commit-order ring에 존재하지 않는 좌표다. gate는 `dep <= frontier`만 통과시키고 frontier는 ring의 commit LSA로만 전진한다 | `wset_raise_history_start (&restart_lsa, "RESTART")`, `return !LSA_ISNULL (&la_Gate_frontier) && LSA_LE (dep, &la_Gate_frontier);`, la_gate_advance_frontier는 `ring[head].commit_lsa`만 복사한다 | master 재시작 후 첫 커밋 T1의 라벨은 R(c0 < R < c1)이다. slave의 frontier는 c0에 있고 ring head는 T1 자신이다. T1은 park되고 frontier는 T1을 넘지 못한다. 이후 모든 커밋이 park되고 ring이 가득 차서 coordinator가 log 읽기를 멈춘다. 라벨 없는 커밋(예: 같은 master에서 도는 applylogdb의 _db_ha_apply_info 커밋)이 R과 c1 사이에 우연히 끼어야만 풀린다. `wait_for_commit_order_slot` 주석의 "That commit always passes the gate"는 이 경우 거짓이다 | 추정(liveness가 우연한 커밋에 의존. gate 규칙 자체는 확정) | 신규 |
| E-3 | High | btree.c:27484-27527(DELETE_RECORD_CAN_DELETE), locator_sr.c:13301-13346 | 커밋 중인 inserter의 대기가 X_LOCK 경로에만 있다. FK 검사의 S_LOCK 경로는 대기 없이 통과한다 | `if (lock_mode == X_LOCK && !is_inserter_waited && locator_is_inserter_committing (...))`. FK 검사는 `xbtree_find_unique (..., S_SELECT_WITH_LOCK, ...)`를 거쳐 CAN_DELETE에서 행 S 락만 잡는다. inserter는 행 X 락이 없다(브랜치 자체 주석 locator_sr.c:13188-13192) | 부모 INSERT T1이 complete_mvcc와 publish 사이에 있을 때 자식 INSERT T2가 FK 검사를 통과한다. T2의 REF probe는 T1의 WRITE를 못 찾아 라벨에 T1이 빠진다. 커밋 LSA까지 T2 < T1로 뒤집힐 수도 있다. slave에서 T2가 T1보다 먼저 또는 병렬로 적용되면 ER_FK_INVALID로 apply가 실패한다 | 확정(대기 부재), 추정(재현 빈도) | 신규(대기는 이 브랜치가 도입. 창은 CBRD-26942 이후) |
| E-4 | High | locator_sr.c:7819-7820, locator_sr.c:8051 | FK REF 해시가 분할(partition) 부모 테이블의 WRITE 해시와 키 공간이 다르다 | REF는 `&index->fk->ref_class_oid, &index->fk->ref_class_pk_btid.vfid`(루트 클래스와 루트 PK btid)를 쓴다. WRITE는 `wset_add_write_key (ws_tdes, class_oid, &index->btid.vfid, ...)`로 실제 heap/파티션 class와 로컬 btid를 쓴다. btree_check_foreign_key(26240-26248)도 파티션 로컬 btid로 prune한다 | 분할 테이블을 참조하는 FK에서 부모 행 INSERT/DELETE와 자식 INSERT의 해시가 한 번도 만나지 않는다. 자식이 부모보다 먼저 적용되면 FK 오류가 나고, 부모 DELETE와 자식 DELETE가 역순이면 RESTRICT 위반이 난다. 둘 다 slave apply 실패로 이어진다 | 추정(파티션 insert의 class_oid/btid가 파티션 것이라는 점은 코드상 강하게 시사되나 실행 미확인) | 신규 |
| E-5 | Medium | log_applier_result_queue.cpp:172-197, log_applier.c:1039-1068, 1080-1109 | coordinator의 blocking `la_result_queue_pop`이 shutdown 플래그를 보지 않는다. queue shutdown 신호는 coordinator 자신만 보낸다 | `while (count == 0 && la_Shared_result_shutdown == false) pthread_cond_wait (...)`. `la_request_shutdown`은 `la_applier_need_shutdown = true`만 설정한다 | 모든 worker가 db_restart_sub에 실패하면(max_clients 초과 등) la_worker_startup_failed가 request_shutdown만 호출한다. 이때 coordinator가 recovery range에서 `wait_until_retired`에 들어가 있으면 결과가 영원히 오지 않아 무한 대기한다. SIGTERM도 이 대기를 깨우지 못한다 | 확정(코드) | 신규 |
| E-6 | Medium | log_applier.c:10327-10357, 6704-6705 | failover drain backstop이 "frontier 30초 무변화"를 stuck worker로 간주한다 | `LA_DRAIN_TIMEOUT_MSEC 30000`이 지나면 `la_applier_need_shutdown = true` | role change 시점에 30초 넘게 걸리는 대형 트랜잭션 하나가 적용 중이면 applier가 강제 재시작된다. 진행 중인 작업이 버려지고 그 범위가 재시작 후 직렬로 다시 적용되어(A-4) 승격이 더 늦어진다 | 확정(코드), 추정(영향 크기) | 신규 |
| E-7 | Low | log_applier.c:796, 7911-7943 등 act_log.log_hdr 참조 56곳, log_applier.c:3683 | worker가 cache mutex 아래에서 copied log header를 제자리 pread로 다시 읽는다(la_log_fetch → la_fetch_log_hdr). coordinator는 mutex 없이 log_hdr 필드를 읽는다. 470309f59는 check_reinit_copylog 구간만 보호한다 | `la_log_io_read (..., act_log->hdr_page, 0, ...)`. cover_commit의 `la_Info.act_log.log_hdr->eof_lsa`, la_change_state의 `ha_server_state`/`ha_file_status` | worker의 재읽기와 겹치면 coordinator가 eof_lsa나 상태값을 찢어진 상태 또는 중간 상태로 읽을 수 있다. max_committed_lsa 경계나 DONE 판정이 한 주기 어긋난다 | 추정 | 신규(멀티스레드화로 생김) |
| E-8 | Low | log_applier.c:445, 2073, 1521 | `la_applier_need_shutdown`이 일반 `static bool`인데 worker 스레드가 쓰고 coordinator가 읽는다 | `static bool la_applier_need_shutdown = false;`, worker의 `la_log_fetch_from_archive` 실패 시 `la_applier_need_shutdown = true` | 형식상 data race(UB)다. 현재는 루프 안의 외부 호출 덕에 재로딩되지만 최적화 변경에 취약하다 | 확정(race 존재) | 신규 |
| E-9 | Low | log_tran_table.c:1621-1622 | logtb_clear_tdes가 `wset_hashes.clear ()`만 호출해 capacity를 유지한다 | `tdes->wset_hashes.clear ();`. 반면 overflow 경로는 `swap`으로 해제한다(writeset.cpp:559) | 한 트랜잭션이 거의 history_size(기본 1e6)개 키를 모으면 엔트리당 24B, 약 24MB가 그 tdes에 영구히 남는다. 큰 배치를 여러 세션에서 돌리면 서버 RSS가 누적된다 | 확정 | 신규 |

**E-1 상세.** `wset_find_dependency_in_range`와 `wset_find_sysop_fallback_dependency`는 둘 다 결과를 history_start로 끌어올린다. overflow 분기만 이 바닥이 없다. history_start는 "이 좌표 이전은 history로 판단할 수 없다"는 불변식이다. RESTART 바닥과 serial sysop 장벽이 이 불변식을 쓴다. commit-order 폴백은 가장 보수적이어야 할 경로인데 오히려 장벽을 뚫는다. 수정은 overflow 분기에서도 `max(prev_commit_lsa, history_start)`를 반환하면 된다. 단, 이 수정은 E-2의 RESTART liveness 문제를 같이 키우므로 E-2와 묶어서 고쳐야 한다.

**E-2 상세.** gate의 통과 조건은 "dep 이하의 모든 커밋이 완료"여야 한다. 지금 구현은 "dep 이하인 frontier가 존재"로 근사한다. dep가 ring의 두 커밋 사이(c0 < dep < c1)에 떨어지면 c0까지 완료됐을 때 이미 조건을 만족하지만 거부한다. sysop LSA는 `la_coordinator_complete_without_task`나 fragment task로 ring에 넣어 이 문제를 피하지만, RESTART 좌표는 어떤 레코드로도 log에 남지 않는다(주석: "Nothing is written to the log for this"). 권고는 두 가지 중 하나다.
- (1) gate를 "dep < 가장 오래된 미완료 ring 항목의 commit_lsa"로 바꾼다. ring이 비면 "dep ≤ 지금까지 읽은 위치"로 판정한다.
- (2) master가 재시작 경계에 더미 레코드를 남기고 slave가 이를 `complete_without_task`로 처리한다.

unit test(test_log_applier_gate.cpp)에는 ring 사이에 떨어지는 라벨 케이스가 없다.

**E-3 상세.** d1d02b9e4와 79268ae56은 "inserter/deleter가 complete_mvcc 뒤, publish 전"이라는 무락 구간을 X_LOCK 행 수정과 unique 검사에서 막았다. 같은 구간이 FK 참조 검사(S_SELECT_WITH_LOCK → DELETE_RECORD_CAN_DELETE → btree_key_lock_object S_LOCK)에도 존재한다. 부모 행에 inserter의 X 락이 없으므로 S 락은 즉시 부여된다. 같은 `btree_is_deleter_committing` 류의 probe(insert_mvccid self-lock을 S로 조건부 시도하고 실패하면 대기 후 restart)를 CAN_DELETE 분기의 FK 경로에도 넣어야 한다.

**E-4 상세.** writeset 해시는 (class OID, index VFID, packed key)다. 부모 측 WRITE는 실제 행이 저장된 파티션 class와 그 로컬 PK btree로 수집된다. 자식 측 REF는 FK 메타의 루트 클래스와 루트 PK btid를 쓴다. 파티션 테이블에 대한 언급은 writeset.cpp와 locator_wset_* 어디에도 없다. 분할 부모를 참조하는 FK 케이스로 trace level 3에서 COLLECT/PROBE 해시를 대조해 확정해야 한다. 수정 방향은 REF 수집 시 btree_check_foreign_key처럼 `partition_prune_unique_btid`로 파티션 class와 로컬 btid를 구하는 것이다. 또는 WRITE를 항상 루트 class와 루트 btid로 정규화한다.

**E-5 상세.** `la_result_queue_wait_for_result`는 타임아웃이 있지만 `la_result_queue_pop`은 없다. recovery range 경로(`la_coordinator_submit_task` 7384-7411)와 inflight 만석 경로가 pop에서 무한정 기다린다. 다음 둘 중 하나가 필요하다.
- pop에 타임아웃 루프를 두고 `la_applier_need_shutdown`과 `la_Live_worker_count`를 확인한다.
- `la_request_shutdown`이 result queue의 not_empty를 broadcast한다.

### 3.2 모듈화

| ID | 등급 | 위치 | 내용 | 근거 | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| M-1 | Medium | log_applier.c 전체(9409 → 11131행) | coordinator 로직(submit/dispatch/retire/drain/label holder/recovery range/cover_commit)이 여전히 log_applier.c 안에 file-static 상태로 남아 있다. applier/ 디렉토리는 자료구조만 가진다 | `static int la_wset_label_trid`, `static LOG_LSA la_wset_label_dependency_seq`(7330-7331), coordinator 함수 약 20개가 log_applier.c에 있다 | 스케줄링 규칙(E-2 같은 것)을 단위 테스트할 수 없다. gate 단위 테스트는 있지만 "라벨 → submit → park → drain" 경로는 log_applier.c 전체를 링크해야만 시험할 수 있다 | 확정 | 신규 |
| M-2 | Medium | log_manager.c:3997-4029, 4330-4349, 4354-4430 | log manager가 복제 레코드 포맷을 직접 파싱하고(log_sysop_fallback_reason이 repl_data에서 packed key size와 class name을 unpack), NEED_FLUSH 개수를 세는 루프를 세 번 중복한다 | `or_unpack_int (repl_record->repl_data, ...)`, `or_unpack_string_nocopy (ptr, &class_name)`. 동일한 for 루프가 4001, 4019, 4333에 있다 | repl_log_insert의 레코드 레이아웃이 바뀌면 log_manager.c의 trace 분류가 조용히 틀린다(레이어 침범). 개수 루프가 sysop commit마다 2회 추가되어 경로 비용이 는다 | 확정 | 신규 |
| M-3 | Low | writeset.cpp:579-660, 856-966 | WRITE/REF 키 해시 경로(문자열, midxkey, packed)가 거의 그대로 두 번 구현되어 있다 | 두 함수 모두 `TP_IS_CHAR_TYPE → wset_string_hash`, `MIDXKEY → wset_midxkey_hash`, `malloc/memset/or_pack_mem_value/wset_fnv1a`, push, trace의 순서다 | 한쪽만 고치면(예: E-4 정규화) WRITE와 REF 해시가 어긋나 의존성이 사라진다 | 확정 | 신규 |
| M-4 | Low | applier/*.cpp | gate, pending, inflight, queue가 모두 프로세스 전역 싱글턴이다 | `static LA_GATE_ORDER *la_Gate_order_ring`, `static LA_PENDING_NODE *la_Pending_head` 등 | 테스트 간 격리가 init 재호출에 의존한다. applier 2개 이상을 한 프로세스에서 돌리는 확장을 막는다 | 확정 | 신규 |
| M-5 | Low | log_manager.c:4077-4078, 4330 등 | trace level 판정이 `wset_trace_enabled`와 `prm_get_integer_value (PRM_ID_HA_WRITESET_TRACE_LEVEL)` 직접 호출로 섞여 있다 | writeset.cpp는 캐시된 `wset_Trace_level`을 쓰고 log_manager.c는 매번 prm을 조회한다 | 동작 차이는 없지만 hot path에서 prm 조회 비용이 들고, trace 정책을 한곳에서 바꿀 수 없다 | 확정 | 신규 |

### 3.3 아키텍처

| ID | 등급 | 위치 | 내용 | 근거 | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| A-1 | High | log_manager.c:4039-4073, writeset.cpp:1467-1487 | 복제 항목이 있는 모든 sysop(serial, AUTO_INCREMENT, INCR/DECR)이 history_start를 자기 SYSOP_END까지 올린다. 이것이 slave에서 **전역 장벽**이 되고, master에서도 sysop마다 seq_lock과 history 배타락을 잡는다 | `wset_raise_history_start (&sysop_lsa, "SYSOP_COMMIT_ORDER")`, `pthread_rwlock_wrlock (&wset_History.history_lock)` | AUTO_INCREMENT 테이블 INSERT가 섞인 워크로드에서는 serial 캐시가 없을 때 INSERT마다 sysop이 생긴다. 그 뒤의 모든 커밋 라벨이 sysop LSA 이상이 되어 slave 병렬도가 사실상 commit-order로 수렴한다. master의 커밋 경로도 배타락으로 직렬화된다 | 확정(장벽 동작), 추정(성능 영향 크기) | 신규 |
| A-2 | Medium | log_record.hpp:140, log_applier.c:7837 | 새 레코드 타입 53이 기존 LOG_LARGER_LOGREC_TYPE(develop=53) 자리를 차지한다. 이전 버전 리더는 이를 손상 레코드로 판정한다 | develop의 `LOG_SUPPLEMENTAL_INFO = 52`, 이어서 `LOG_LARGER_LOGREC_TYPE`. applier는 `lrec->type >= LOG_LARGER_LOGREC_TYPE`이면 `ER_LOG_PAGE_CORRUPTED`를 낸다 | master를 먼저 올리는 롤링 업그레이드에서 develop slave의 applylogdb가 첫 라벨에서 정지한다. 같은 이유로 log_dump는 라벨마다 "Unknown record type"을 출력한다(log_manager.c:7469, 덤프 자체는 계속됨) | 확정 | 신규 |
| A-3 | Medium | schema_system_catalog_install.cpp:1095-1097, log_applier.c:2896-2916, 3349-3353 | _db_ha_apply_info에 컬럼 2개를 추가했지만 마이그레이션 경로가 없다. 조회 실패가 applier 초기화 실패로 이어진다 | `SELECT max_committed_lsa_pageid, max_committed_lsa_offset FROM ...`. 결과가 `res < 0`이면 그대로 반환한다 | develop으로 생성한 기존 DB에 새 바이너리를 올리면 applylogdb가 시작 단계에서 실패하고 heartbeat 재기동이 반복된다. TODO(2956-2959)가 대안을 언급하지만 미해결이다 | 확정 | 신규 |
| A-4 | Medium | log_applier.c:777-810, 7378-7411 | 재적용 경계를 커밋이 아니라 그 시점의 eof_lsa까지 점프해 저장한다. 경계 안은 한 트랜잭션씩 직렬로 dispatch하고 retire까지 기다린다 | `if (... LSA_GT (&...log_hdr->eof_lsa, &bound)) LSA_COPY (&bound, &...eof_lsa);`, recovery range에서는 `la_coordinator_wait_until_retired` | slave backlog가 큰 상태에서 applier가 한 번이라도 재시작하면(E-5, E-6, 서버 재기동, 에러) 그 시점 eof까지의 backlog 전체가 develop보다 느린 직렬 경로로 처리된다. 재시작이 재시작을 부르는 성능 절벽이다 | 확정(코드), 추정(영향 크기) | 신규 |
| A-5 | Medium | CMakeLists.txt:607 | `MULTI_CONN_TO_A_SERVER`를 최상위에서 전역 정의했다. applylogdb 하나 때문에 모든 클라이언트 바이너리(csql, CAS, 유틸리티)의 client 라이브러리 동작이 바뀐다 | `-#add_definitions(-DMULTI_CONN_TO_A_SERVER)` → `+add_definitions(...)` | applier와 무관한 제품의 회귀 위험이 브랜치 범위 밖으로 번진다. 문제가 생겨도 기능 플래그로 끌 수 없다 | 확정(정의 범위), 추정(회귀 여부) | 신규 |
| A-6 | Low | log_manager.c:5599-5605 | 복제 항목이 없는 커밋도 dependency를 탐색하고 라벨을 기록한다. slave는 이를 has_label로 받아 park할 수 있다 | `wset_find_dependency_from_history`와 `log_append_repl_info_and_commit_log`가 is_active_worker 조건만 본다 | 커밋마다 log 레코드와 seq_lock/history 읽기락이 늘고, slave ring/pending에 빈 커밋이 쌓여 병렬 창을 소모한다 | 확정 | 신규 |
| A-7 | Low | log_applier_pending.cpp:97-132, log_applier_inflight.cpp:224-242 | pending 해제와 inflight 결과 매칭이 선형 탐색이다. ring 용량은 worker × 1024다 | drain_ready가 pop_ready를 반복하고, pop_ready는 매번 head부터 스캔한다 | worker 10개, park 1만 건이면 frontier가 움직일 때마다 O(n²) 스캔이 coordinator(단일 스레드)를 점유해 dispatch가 지연된다 | 확정(복잡도), 추정(체감 영향) | 신규 |

**A-1 상세.** 코드 주석(4045-4050)에도 TODO가 있다. 운영 관점에서는 "AUTO_INCREMENT를 쓰면 병렬 복제가 꺼진다"는 결과다. 확정 전에 sysbench류 AUTO_INCREMENT 워크로드에서 worker 1개와 10개의 처리량을 비교해 수치로 남길 것을 권한다. 구조적 대안은 TODO가 적은 대로 sysop 키를 SYSOP_END 좌표로 publish하는 방식이다. 그때 E-2의 gate 규칙 수정이 선행되어야 한다.

### 3.4 리팩토링

| ID | 등급 | 위치 | 내용 | 근거 | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| R-1 | Medium | log_applier.c:1430-1456, 1401 | 테스트용 커밋 지연 hook이 릴리스 빌드에 있고, worker가 커밋마다 getenv를 호출한다 | `getenv ("CUBRID_HA_TEST_BLOCK_CLASS")`, `usleep (block_msec * 1000)` | 운영 환경 변수 하나로 복제가 클래스 단위로 60초씩 멈출 수 있다. TODO가 인정한 사항이지만 머지 전 제거하거나 `#if !defined(NDEBUG)`로 막아야 한다 | 확정 | 신규 |
| R-2 | Low | log_applier.c:872, 1005, 1249, 1259, 7512, 7529, 7638, 7764, 7825, 9590 | trace와 알림 문자열이 coordinator를 "reader"로 부른다 | `"[WSET] reader schedule ..."`, `"applylogdb reader exit: ..."` | 함수명(la_coordinator_*)과 로그 키워드가 달라 grep 기반 진단과 문서가 어긋난다 | 확정 | 신규 |
| R-3 | Low | log_applier.c:737-761 주석, log_applier_gate.cpp:371 주석 | 사실과 다른 불변식 주석이 있다 | "That commit always passes the gate", "The ring cannot actually fill" | E-2 상황에서 주석을 믿고 원인 분석이 늦어진다 | 확정 | 신규 |
| R-4 | Low | writeset.cpp:1012-1015, 1081-1089 | `wset_find_dependency_in_range` 주석이 overflow를 다루지만 함수는 overflow를 보지 않는다. min(wset_parent, prev_commit) 선택의 안전성은 "충돌 commit은 락 해제 전에 baseline을 올린다"는 암묵 불변식에 의존하는데, 이것이 서술되어 있지 않다 | "An overflowed writeset uses prev_commit_lsa", "Both candidates are safe bounds" | 무락 구간(E-3)처럼 그 불변식이 깨지는 경로를 추가할 때 위험을 알아채기 어렵다 | 확정 | 신규 |
| R-5 | Low | log_applier.c:9648-10430 | `la_apply_log_file` 메인 루프가 약 780행이다(페이지 획득, 헤더 갱신, 아카이브 삭제, 상태 전이, drain backstop, 대기가 한 함수에 있음) | 함수 경계(9648 → 다음 함수 10431) | E-6, E-7 같은 수정이 루프의 continue/break 경로마다 반복되어야 한다. page release 누락류 버그가 재발하기 쉽다(주석 9856, 10367이 그 흔적이다) | 확정 | 기존 함수(신규로 확대) |

## 4. 미검증 의심 (근거 부족으로 확정 못 한 것)

1. **E-2의 실제 발생 빈도.** 2노드 HA에서는 master 쪽 applylogdb가 slave log의 HA_SERVER_STATE를 읽을 때 `la_log_commit`이 라벨 없는 커밋을 남겨 우연히 풀어 줄 가능성이 높다. replica 구성, master 측 applier 정지, 1:N 구성에서는 풀어 줄 커밋이 없을 수 있다. 전체 재시작 후 slave의 `[WSET] reader schedule ... status=PARKED`와 frontier 정지로 확인해야 한다.
2. **E-4 파티션 FK.** 파티션 INSERT에서 `locator_add_or_remove_index_internal`의 class_oid와 index->btid가 파티션 것인지 trace level 3 SOURCE 라인으로 확인이 필요하다.
3. **INCR/DECR sysop의 키 폐기.** `wset_discard_sysop_keys`는 sysop 안에서 수집된 사용자 행의 PK 키도 버리고 장벽(A-1)으로 대체한다. 장벽이 늘 앞서므로 정합성은 유지될 것으로 보이나, INCR이 잡은 행 락의 해제 시점과 장벽 상향 순서를 직접 확인하지 못했다.
4. **sysop label 경로의 원자성.** `log_append_repl_info (tdes, false)`(4017)와 `log_append_wset_label_and_sysop_end`(4055)가 별개의 prior_lsa_mutex 구간이라 사이에 다른 트랜잭션 레코드가 낄 수 있다. slave가 trid별로 item을 모으므로 문제없어 보이나, fragment 분리(`la_detach_sysop_fragment`의 `item->lsa <= fragment_lsa`)와의 상호작용은 테스트로 보지 못했다.
5. **unique NULL 키.** 다수의 NULL 값이 같은 해시로 수집된다(writeset.cpp:597-598). 정합성 문제는 아니고 거짓 의존성(병렬도 손실)이다. 규모는 미측정이다.
6. **recovery range의 statement 재적용.** TODO(6964)가 인정한 대로 statement 항목은 멱등이 아니다. recovery range에서 DDL이 두 번 적용될 때의 에러 처리 경로는 읽지 못했다.

## 5. 총평

master writeset 수집(collation pseudo key, midxkey 원소별 축약, 정렬 패딩 zero-fill, REF/WRITE 슬롯 분리, sysop abort 시 키 회수)과 slave 자료구조(gate ring, pending, inflight, 두 큐의 락 분리)는 개별적으로 꼼꼼하다. 주석 수준도 높다. 락 순서(seq_lock → history_lock)도 전 경로에서 일관된다. reserve 기반 용량 검사와 OOM 시 clear 폴백도 안전 쪽으로 설계됐다.

가장 큰 위험은 개별 코드가 아니라 **master 라벨 의미론과 slave gate 진행 규칙 사이의 계약**에 있다. history_start라는 "바닥" 개념을 도입해 놓고, 폴백 경로(E-1)는 그 바닥을 지키지 않고, 바닥이 commit이 아닌 좌표일 때(E-2) gate는 진행할 수 없다. 여기에 락 없는 커밋 구간을 경로별로 하나씩 막는 방식(d1d02b9e4, 79268ae56)은 FK 참조 경로(E-3)를 놓쳤다. 키 공간 정규화는 파티션(E-4)에서 어긋날 가능성이 크다. 네 건 모두 slave 정지나 데이터 불일치로 이어지는 유형이므로 머지 전에 해결하거나 최소한 재현 테스트로 반증해야 한다.

장기 유지보수 관점에서는 다음을 우선해야 한다.
- serial/AUTO_INCREMENT 전역 장벽(A-1)이 병렬화 효과를 실제 워크로드에서 얼마나 깎는지 수치로 확인한다.
- 롤링 업그레이드와 카탈로그 호환(A-2, A-3)의 정책을 결정한다.
- 재시작 시 직렬 재적용 범위가 eof까지 커지는 성능 절벽(A-4)을 줄인다.
- coordinator 로직을 log_applier.c에서 분리해 스케줄링 규칙을 단위 테스트 가능하게 만든다(M-1). 특히 "ring 사이 라벨" 케이스를 gate 테스트에 추가한다.

판정: **NEEDS_FIX.** High 5건(E-1~E-4, A-1)을 해결하거나 반증한 뒤 재리뷰를 권한다.
