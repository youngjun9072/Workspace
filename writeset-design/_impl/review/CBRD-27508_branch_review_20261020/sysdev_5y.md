# CBRD-27508 브랜치 리뷰: 시스템 개발자 5년차

## 1. 리뷰어 관점

DB 엔진 내부의 동시성, 락, 로그/LSA, 메모리 수명, 스레드 안전을 중심으로 봤다. 모듈 하나하나보다 **모듈 사이의 불변식**을 우선 확인했다. 마스터에서 라벨을 만드는 쪽(커밋 경로, MVCC self-lock, history)이 무엇을 보장하고, 슬레이브 게이트(frontier, commit-order ring)가 그 보장을 어떻게 받아 쓰는지 양쪽을 맞대어 봤다. 그 사이에서 생기는 경계 조건(재시작, sysop, overflow, 워커 사망)을 추적했다.

## 2. 검토 범위와 실제로 읽은 경로

범위는 `git diff a9a0dc78d 0e411f10f`이다(HEAD = 0e411f10f). 행 번호는 모두 HEAD 기준이다.

- **마스터 writeset**
  - `src/transaction/writeset.cpp`: 전체. 수집(`wset_add_write_key`, `wset_add_ref_key`, `wset_midxkey_hash`), 의존성 선택(`wset_find_dependency_in_range`, `wset_find_dependency_from_history`), 게시(`wset_publish_with_capacity`, `wset_clear_overflow_history`), sysop 처리(`wset_discard_sysop_keys`, `wset_abort_after_lsa`, `wset_find_sysop_fallback_dependency`, `wset_raise_history_start`).
  - `writeset.hpp`, `writeset_types.hpp`, `writeset_history_map.{hpp,cpp}`.
- **로그 매니저**
  - `log_manager.c`: `log_initialize_internal`의 RESTART 하한 올리기, `log_sysop_start`, `log_sysop_commit_internal`, `log_sysop_abort`, `log_append_sysop_end_internal`, `log_append_wset_label_and_sysop_end`, `log_append_repl_info_internal`, `log_append_repl_info_and_commit_log`, `log_append_wset_label_with_lock`, `log_commit_local`, `log_complete_for_2pc`.
  - `log_impl.h`, `log_record.hpp`, `log_append.cpp`, `log_recovery.c`.
  - `log_tran_table.c`: `logtb_clear_tdes`, `logtb_initialize_tdes`, `copy_to`, self-lock 관련 `logtb_acquire_mvccid_self_lock`, `logtb_complete_sub_mvcc`.
- **DML/인덱스**
  - `locator_sr.c`: `locator_add_or_remove_index_internal`, `locator_update_index`, `locator_wset_collect_fk_ref`, `locator_is_inserter_committing`, `locator_lock_and_get_object_internal`, `xlocator_repl_force`.
  - `btree.c`: `btree_is_deleter_committing`, `btree_wait_for_inserter_end`, `btree_key_wait_for_insert_mvccid`, `btree_key_find_and_lock_unique_of_unique` / `_of_non_unique`, `btree_check_foreign_key`, `btree_fk_object_does_exist`.
  - `heap_file.c`: 21119~21160 행의 insert self-lock 주석(기준선 동작 확인용).
  - `serial.c`, `replication.c`(`repl_log_insert_statement`, `repl_log_abort_after_lsa`), `system_parameter.{c,h}`, `error_code.h`, `schema_system_catalog_install.cpp`.
- **슬레이브**
  - `src/transaction/applier/*`: gate, pending, inflight, task_queue, result_queue, worker, task/result 헤더 전체.
  - `log_applier.c`
    - coordinator 계열: `la_coordinator_*` 전부, `la_is_in_recovery_range`.
    - 워커 실행: `la_apply_worker_*`.
    - 레코드 처리: `la_log_record_process`, `la_coordinator_process_commit` / `_process_sysop_end` / `_set_commit_dependency` / `_submit_task`, `la_detach_sysop_fragment`.
    - 페이지 캐시: `la_get_page_buffer`, `la_cache_buffer_replace`, `la_log_fetch`, `la_fetch_log_hdr`, `la_get_range_of_archive`.
    - 상태·메인 루프: `la_change_state`, `la_apply_log_file` 메인 루프(9839~10130).
    - 종료·복구: `la_shutdown`, `la_flush_repl_items`의 recovery skip, `la_get/update_ha_apply_max_committed_lsa`.
  - 커밋 `470309f59`, `396f4966b`의 diff와 메시지.
- **CS 쪽(호출부만)**: `CMakeLists.txt`(MULTI_CONN 정의), `cs/CMakeLists.txt`, `work_space.{c,h}`(`ws_get_repl_obj_count`)와 `la_flush_repl_items`의 호출, `file_io.c`의 `fileio_os_read/write` 분기, `la_worker_start_session`의 `db_restart_sub` 반환 처리.
- **테스트**: `unit_tests/writeset/test_writeset.cpp`. overflow와 RESTART/SYSOP 하한의 조합을 다루는 케이스가 있는지 확인했다.

## 3. 발견 사항

### 3.1 에러

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| E1 | High | btree.c:27491-27511, btree.c:30530-30533, locator_sr.c:13303 | FK 검사와 부모 삭제 시 자식 존재 검사가 커밋 중인 inserter/deleter를 기다리지 않는다. | unique 검사의 `DELETE_RECORD_CAN_DELETE`는 조건부 S lock만 잡는다(inserter에게는 행 X lock이 없다). FK 존재 검사는 `case DELETE_RECORD_DELETED: ... return NO_ERROR;`로 끝난다. 이 브랜치의 대기는 `lock_mode == X_LOCK`(행 수정)과 unique 검사의 DELETED 분기에만 있다. | (a) T1이 부모 k INSERT 후 커밋 중이다(complete_mvcc 끝, commit 레코드 전). T2가 자식 INSERT(FK=k)를 하면 S lock을 바로 얻고, T1이 아직 게시하지 않아 REF 탐색에서 T1을 놓친다. T2 커밋 LSA가 T1보다 앞서면 슬레이브는 자식을 먼저 적용해 FK 위반이 난다. (b) T1이 자식 삭제 커밋 중일 때 T2가 부모를 삭제하면 자식이 "없음"으로 보여 통과한다. 그 결과 로그 순서가 역전되어 슬레이브 부모 삭제가 실패한다. | 확정(코드 경로), 재현 미확인 | 기존(CBRD-26942 기준선). 브랜치는 일부 경로만 메웠다. |
| E2 | High | writeset.cpp:1111-1119 | overflow·statement fallback 트랜잭션의 라벨이 `history_start` 하한을 무시한다. | `if (tdes->wset_overflow) { LSA_COPY (wset_parent_out, &wset_History.prev_commit_lsa); ... return; }`. WRITE 경로(1091-1095)와 sysop 경로(1444-1448)에는 하한 적용이 있는데 이 경로에만 없다. | (a) 마스터 재시작 직후에는 prev_commit_lsa가 NULL이다. 첫 커밋이 DDL(statement 복제이므로 overflow)이면 라벨이 NULL이 되어 게이트를 즉시 통과한다. 슬레이브에 밀린 재시작 이전 DML과 병렬로 적용되어 ALTER/DROP이 선행 INSERT보다 먼저 반영된다. (b) serial sysop가 history_start를 sysop LSA로 올린 직후 overflow 트랜잭션의 라벨은 그보다 작은 prev_commit이 된다. 그러면 serial fragment와 병렬로 적용될 수 있다. | 확정 | 신규 |
| E3 | High | log_applier_gate.cpp:280-291, log_manager.c:1500-1513, log_applier.c:727-735 | 게이트는 라벨이 commit-order ring의 어느 항목 이하라고 가정한다. ring에 없는 LSA(RESTART 라벨 = 복구 후 `append_lsa`)는 통과시키지 못한다. | `return !LSA_ISNULL (&la_Gate_frontier) && LSA_LE (dep, &la_Gate_frontier);`. frontier는 ring 항목의 commit_lsa로만 움직인다. `wait_for_commit_order_slot` 주석은 "That commit always passes the gate"라고 하지만 이 경우에는 성립하지 않는다. | 마스터 재시작 후 첫 라벨 커밋 C1의 dep는 R(=append_lsa)이다. 슬레이브 ring에 [R, C1) 구간의 LOG_COMMIT이 하나도 없으면 frontier가 R 아래(P)에 머문다. C1이 ring head에서 pending으로 묶이면 frontier가 영원히 멈추고, ring이 차면 coordinator가 무한 대기한다. | 추정([R, C1)에 다른 LOG_COMMIT이 있으면 우연히 피한다) | 신규 |
| E4 | Medium | log_applier.c:1044-1046, 1085-1087, 1518-1522, log_applier_worker.cpp:378-391 | coordinator의 블로킹 `la_result_queue_pop`이 `la_applier_need_shutdown`을 보지 않는다. 워커의 shutdown 요청은 플래그만 세운다. | `la_request_shutdown`은 `{ la_applier_need_shutdown = true; }`뿐이다. `la_coordinator_wait_until_retired`는 `while (inflight>0) la_result_queue_pop (...)`로 조건변수에서 무기한 대기한다. | 서버 다운 후 applier가 재시작해 복구 구간 첫 task를 dispatch하고 `wait_until_retired`로 들어간다. 이때 워커가 모두 `db_restart_sub`에 실패하면(remaining=0) 결과를 줄 주체가 없다. 프로세스는 살아 있지만 적용도 재시작도 하지 않는 상태로 멈춘다. SIGTERM도 이 대기를 깨우지 못한다. | 확정 | 신규 |
| E5 | Medium | log_applier.c:796-798, 7911-7939, 8079-8080, 8899, 10253 vs 2051, 2112, 3683 | 워커가 `la_log_fetch` 안에서 `la_fetch_log_hdr`로 copied log header 페이지를 제자리에서 다시 읽는 동안, coordinator가 mutex 없이 그 필드를 읽는다. | 470309f59는 `check_reinit_copylog`~`memcpy (&final_log_hdr ...)`만 mutex로 감쌌다. `la_coordinator_cover_commit`(eof_lsa), `la_change_state`(ha_server_state, ha_file_status) 등은 여전히 `la_Info.act_log.log_hdr->...`를 직접 읽는다. | 워커가 header를 `pread`하는 순간 coordinator가 `la_change_state`에서 서버 상태를 읽으면 갱신 중인 값을 볼 수 있다. 최악의 경우 DONE/WORKING 판정이나 max_committed_lsa 경계가 틀어진다(영향은 추정). | 경쟁 존재는 확정, 영향은 추정 | 신규(병렬 워커가 만든 경쟁) |
| E6 | Medium | log_tran_table.c:1622, 1706, writeset.cpp:520-532 | `wset_hashes.clear ()`는 capacity를 돌려주지 않는다. 트랜잭션당 최대 `ha_writeset_history_size`(기본 1,000,000)개까지 쌓인 벡터가 tdes에 영구히 남는다. | 한도 초과 시 `swap`으로 해제하지만, 한도 바로 아래로 커밋하면 `clear()`만 불린다. 원소는 24바이트 내외다. | 배치 작업 세션 여러 개가 각각 수십만 키를 쓰고 커밋하면 tdes마다 최대 ~24MB가 반환되지 않는다. tdes 수 × 24MB만큼 cub_server RSS가 상주한다. | 확정 | 신규 |
| E7 | Medium | schema_system_catalog_install.cpp:1096-1097, log_applier.c:2896-2916, 3349-3353 | `_db_ha_apply_info`에 컬럼 2개를 추가했지만, 기존 DB에 컬럼이 없을 때의 대비가 없다. | `SELECT max_committed_lsa_pageid ...`가 실패하면 `res<0 → return res`가 되고, 시작 경로에서 `return res`로 applier 기동이 실패한다. | 기존 버전으로 만든 슬레이브 DB에 새 applylogdb를 올리면 시작할 때마다 실패하고 재기동을 반복한다. | 확정 | 신규 |
| E8 | Low | log_applier_pending.cpp:144-155, log_applier.c:1128-1133, 8545-8548, log_applier_inflight.cpp:66-73 | applier가 종료될 때 대기 중이거나 실행 중인 LOG_SYSOP_END task의 분리된 fragment(`malloc`한 LA_APPLY와 items)가 해제되지 않는다. | fragment는 retire 시점(`release_apply_slot`)에만 해제된다. `la_pending_clear`는 노드만, `la_inflight_init`은 배열만 해제한다. | 같은 프로세스 안에서 applier 재시작(서버 다운 등)이 반복될 때마다 serial fragment 메모리가 샌다. | 확정 | 신규 |
| E9 | Low | log_applier.c:5979-5982 | 복구 구간의 INSERT skip 화이트리스트가 PK 중복뿐 아니라 모든 unique 인덱스 위반(`ER_BTREE_UNIQUE_FAILED`)을 삼킨다. | `recovery_skip = (flush_err->error_code == ER_BTREE_UNIQUE_FAILED);` | 복구 구간에서 보조 unique 키가 다른 PK 행과 실제로 충돌해도(진짜 불일치) 오류 없이 넘어간다. 슬레이브 행 누락이 숨는다. | 추정(그 상태가 실제로 생길 수 있는지 미검증) | 신규 |

#### E1 상세: 커밋 중인 inserter/deleter를 FK 경로가 기다리지 않음

- 기준선(CBRD-26942)은 MVCC 클래스 INSERT에서 행 X lock을 없애고 MVCCID self-lock으로 대체했다(heap_file.c:21119-21160). 커밋하는 트랜잭션은 `logtb_complete_mvcc`(log_manager.c:5562)로 먼저 "committed"로 보이게 된다. 그 다음 `wset_find_dependency_from_history` → commit 레코드 → `wset_publish_commit_to_history` → `lock_unlock_all`(5602-5615) 순서로 진행한다. 이 사이에서 다른 트랜잭션은 해당 행을 committed로 본다.
- 브랜치는 이 틈을 두 군데만 막았다.
  - `locator_lock_and_get_object_internal`의 `lock_mode == X_LOCK` 경로(locator_sr.c:13303)
  - unique 검사 `DELETE_RECORD_DELETED` 분기(btree.c:27554, 27911)
- 그런데 FK 검사는 `btree_check_foreign_key` → `xbtree_find_unique (..., S_SELECT_WITH_LOCK, ...)`(btree.c:26247) → `_of_unique`의 `DELETE_RECORD_CAN_DELETE`(27491)로 간다. 이 경로는 부모 OID에 S lock만 조건부로 잡는다. inserter가 행 lock을 들고 있지 않으므로 즉시 통과한다.
- 부모 삭제·갱신 시 자식 존재 검사(`btree_fk_object_does_exist`)는 `DELETE_RECORD_DELETED`를 "존재하지 않음"으로 끝낸다(30530-30533).
- 두 경우 모두 이 틈 안에서 두 번째 트랜잭션이 먼저 커밋할 수 있다. writeset 관점에서는 REF/WRITE 게시가 아직 안 된 상태라 라벨도 놓친다. 그래서 슬레이브는 직렬이든 병렬이든 부모·자식 순서를 거꾸로 적용한다. 메모리에 기록된 sq_uniq 근본 원인과 같은 계열이고, 메운 곳이 행 수정과 unique 검사뿐이라는 점이 핵심이다.
- **제안**: "커밋 중인 MVCCID" 판정을 지점마다 따로 붙이지 말고 한 곳에서 처리한다.
  - 복제 서버에서는 `is_active == false`이면서 self-lock이 아직 잡혀 있는 MVCCID를 in-progress로 취급하는 헬퍼를 둔다.
  - 이 헬퍼를 `mvcc_satisfies_delete` 결과를 해석하는 FK, unique, 행 수정 지점에서 공통으로 쓴다.

#### E2 상세: overflow 라벨이 history_start 하한을 무시함

- `wset_find_dependency_in_range`는 마지막에 `history_start` 하한을 적용하고, `wset_find_sysop_fallback_dependency`도 적용한다. overflow 분기만 `prev_commit_lsa`를 그대로 돌려준다.
- 재시작 후 `wset_history_initialize`는 prev_commit_lsa를 NULL로 두고, `wset_raise_history_start`는 history_start만 올린다(log_manager.c:1513). 따라서 재시작 뒤 첫 커밋이 overflow 트랜잭션이면 라벨은 NULL이다. statement 복제, 즉 DDL이 여기에 해당한다(replication.c `repl_log_insert_statement` → `wset_fallback_to_commit_order`).
- 슬레이브 게이트는 NULL을 무조건 통과시킨다(gate.cpp:285). 이 커밋은 재시작 이전 커밋들의 적용 완료를 기다리지 않는다.
- `wset_raise_history_start (&sysop_lsa)` 직후 overflow 트랜잭션도 같은 문제가 있다. serial의 현재값 이미지를 담은 fragment와 ALTER SERIAL(statement, overflow)이 병렬로 적용되면 serial 값이 어긋날 수 있다.
- 단위 테스트(test_writeset.cpp:980-1014)는 WRITE와 sysop 경로만 검증하고, overflow와 하한의 조합은 다루지 않는다.
- **제안**: overflow 분기에서도 `history_start`를 하한으로 적용한다. 더 근본적으로는 RESTART와 SYSOP에서 history_start를 올릴 때 prev_commit_lsa도 함께 그 값 이상으로 올려서, 두 기준선이 같은 의미를 갖게 한다.

#### E3 상세: 게이트가 ring에 없는 라벨을 통과시키지 못함

- 마스터 라벨의 출처는 세 가지다.
  - 커밋 LSA(history map)
  - SYSOP_END LSA(fallback 및 history_start)
  - **재시작 시 `log_Gl.hdr.append_lsa`**(log_manager.c:1513, 복구 `log_recovery`(1440) 이후). 이 값은 레코드 LSA가 아니라 "다음에 쓸 위치"다.
- 슬레이브에서 frontier는 ring 항목의 commit_lsa로만 움직인다. ring 항목은 LOG_COMMIT과, 라벨이 붙은 LOG_SYSOP_END(fragment 또는 `complete_without_task`)뿐이다.
- 라벨 R이 어떤 ring 항목과도 같지 않을 때는 [R, C1) 사이에 ring 항목이 하나 이상 있어야 frontier가 R을 넘는다. 부트 트랜잭션의 커밋(boot_sr.c:2586) 등이 LOG_COMMIT을 남기면 우연히 피하지만, 그것이 보장되지는 않는다. 데이터를 바꾸지 않은 커밋은 commit 레코드를 쓰지 않는다.
- ring head가 자기 자신(C1)이면서 pending이면, `la_coordinator_wait_for_commit_order_slot`의 "head는 항상 게이트를 통과한다"는 전제가 깨져 교착이 된다.
- **제안**: 게이트 규칙을 "dep 이하의 ring 항목이 모두 완료되었고, coordinator가 dep 너머까지 읽었다"로 바꾼다. 구현은 `dep < 가장 오래된 미완료 ring 항목` 비교로 할 수 있다. 이렇게 하면 레코드가 아닌 라벨도 의미가 맞는다. 아니면 마스터가 재시작 하한으로 실제 레코드 LSA를 쓰도록 한다. 예를 들어 첫 LOG_DUMMY_HA_SERVER_STATE를 쓰고 그 LSA를 쓰되, 슬레이브가 그것을 ring에 넣게 한다.

#### E4 상세: coordinator 블로킹 대기가 종료 요청을 보지 못함

- 메인 루프는 `try_pop`과 100ms timed wait을 쓰므로 종료 플래그를 본다. 그러나 다음 두 함수는 무기한 `la_result_queue_pop`이다.
  - `la_coordinator_wait_until_retired`: 복구 구간에서 task마다 호출된다.
  - `la_coordinator_wait_for_inflight_slot`
- 워커는 시작에 실패하면 `request_shutdown` 콜백으로 플래그만 세운다. result queue의 shutdown은 coordinator 자신이 `la_stop_apply_workers`에서만 건다.
- 워커가 오류로 죽는 경우는 오류 result를 먼저 push하므로 FIFO상 retire가 그 오류에 먼저 닿아 빠져나온다. 하지만 **모든 워커가 세션 시작에 실패하는 경우**에는 result가 하나도 오지 않는다. 복구 구간은 서버 재시작 직후에 비어 있지 않은 것이 일반적이므로, 바로 그 시점에 걸린다.
- **제안**: 블로킹 pop을 timed wait과 `la_applier_need_shutdown` 확인 루프로 바꾼다. 또는 `la_request_shutdown`이 result queue에 shutdown 신호를 보내게 한다.

#### E5 상세: copied log header의 mutex 밖 읽기

- `la_get_page_buffer`는 `cache_pb->mutex` 안에서 `la_cache_buffer_replace` → `la_log_fetch`를 부른다. 여기서 `la_fetch_log_hdr`가 `act_log->hdr_page`를 `la_log_io_read`로 덮어쓴다(3683). 워커도 이 경로로 페이지를 가져온다.
- 470309f59는 coordinator의 header 갱신과 아카이브 삭제만 같은 mutex 안으로 옮겼다. 같은 header를 읽는 다른 coordinator 코드는 mutex 밖에 남아 있다(위 표의 행).
- **제안**: coordinator는 매 루프에서 mutex 안에서 복사한 `final_log_hdr`만 읽도록 통일한다. `la_change_state`, `la_coordinator_cover_commit`, `la_get_applied_log_info` 등에 복사본을 넘긴다.

#### E6~E9 상세

- **E6**: tdes 재사용 시 `std::vector<LOG_WSET_ENTRY>().swap (tdes->wset_hashes)`를 쓰거나, 일정 크기(예: 4K 원소)를 넘으면 shrink하도록 바꾼다.
- **E7**: 컬럼이 없을 때(`ER_QPROC_INVALID_COLNAME` 계열) 경계를 NULL로 두고 계속 진행하거나, 마이그레이션 경로를 명시한다. 코드의 TODO(2956-2959)대로 final_lsa로 경계를 대신하면 카탈로그 변경 자체가 없어진다.
- **E8**: shutdown 경로에서 pending, inflight, task queue에 남은 LOG_SYSOP_END task의 apply를 `la_free_all_repl_items`와 `free`로 정리한다.
- **E9**: 복구 구간 skip을 PK 인덱스 위반으로 좁힌다. 이를 위해 서버 오류에 인덱스 식별자를 함께 받거나 재조회로 PK 존재 여부를 확인하는 방법을 검토한다.

### 3.2 모듈화

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| M1 | Medium | log_applier.c 전반(약 10.7k행), 600-1560, 7321-7652 | coordinator 로직(dispatch, retire, gate 연동, recovery range, label holder)이 `log_applier.c`에 남아 있고, 분리된 applier/ 모듈은 자료구조만 가진다. | `static int la_wset_label_trid`, `la_Info.*` 전역을 coordinator 함수가 직접 다룬다. gate·pending·inflight도 각자 static 전역이다. | 단위 테스트가 자료구조만 덮고(unit_tests/log_applier) 스케줄 규칙(E3, E4 같은 경계)은 시험할 수 없다. | 확정 | 신규 |
| M2 | Low | log_manager.c:4000-4030, 4776-4790, log_sysop_fallback_reason | `LOG_REPL_NEED_FLUSH` 항목을 세는 같은 루프가 세 번 반복된다. | `repl_item_count++` / `flushed_item_count--` / `pending_item_count++`. | 판정 조건이 한 곳만 바뀌면 trace 수치와 실제 판정(`repl_item_count > 0`)이 어긋난다. | 확정 | 신규 |
| M3 | Low | applier/*.cpp 각 파일 static 전역 | gate·pending·inflight·queue가 모두 파일 static 싱글턴이다. 재시작 시 `*_init`이 이전 상태를 정리한다는 암묵 계약에 기댄다. | `la_gate_init`이 이전 ring을 free하고 frontier를 리셋하는 주석(gate.cpp:74-80). | 재시작 경로에서 init 호출 순서가 바뀌거나 하나라도 빠지면 이전 실행의 상태가 남는다(E8의 누수가 같은 계열이다). | 확정 | 신규 |

- **M1**: coordinator 스케줄러를 `applier/log_applier_coordinator.cpp`로 옮긴다. `la_Info` 의존은 필요한 필드만 인자나 컨텍스트 구조체로 받는다. 그러면 "ring에 없는 라벨", "워커 0개", "복구 구간 직렬화" 같은 규칙을 단위 테스트로 고정할 수 있다.
- **M2**: `log_count_pending_repl_items (tdes, start)` 하나로 합친다.

### 3.3 아키텍처

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| A1 | Medium | log_manager.c:5599-5606, writeset.cpp:1026-1030, 1173-1178 | 복제가 켜진 모든 마스터 커밋이 writeset 비용을 낸다. 끄는 스위치가 없다. | 커밋마다 `seq_lock` 2회, `history_lock` rdlock, LOG_DUMMY_WSET_LABEL 레코드 1개가 든다. 키가 없는 커밋도 `wset_find_dependency_in_range`를 탄다. | 슬레이브가 `ha_apply_worker_count=1`(기본값)이어서 라벨을 쓰지 않아도, 마스터 커밋 경로에 전역 mutex 직렬화 지점이 생긴다. 고동시 커밋 부하에서 처리량이 떨어질 수 있다(정도는 추정). | 구조는 확정, 성능 영향은 추정 | 신규 |
| A2 | Medium | CMakeLists.txt:607 | `MULTI_CONN_TO_A_SERVER`를 최상위 `add_definitions`로 켜서 applylogdb뿐 아니라 모든 클라이언트 바이너리와 라이브러리가 multi-connection 코드로 컴파일된다. | `-#add_definitions(...)` → `+add_definitions(-DMULTI_CONN_TO_A_SERVER)`. | csql, CAS, CCI 등 applier와 무관한 클라이언트의 동작과 성능에 영향을 줄 수 있다. 검증 범위가 클라이언트 전체로 넓어진다. | 변경은 확정, 영향은 추정 | 신규 |
| A3 | Medium | writeset.cpp:1081-1095 + log_commit_local 5602-5615 + btree/locator self-lock 대기 | 의존성 축소(`min(wset_parent, prev_commit)`)의 정확성은 "충돌 상대는 게시 전에 락을 놓지 않는다"는 엔진 전역 불변식에 기댄다. 이 불변식이 문서화·강제되지 않은 채 지점별 패치로 유지된다. | 주석: "Both candidates are safe bounds". 실제 보장은 행 X lock, self-lock, 그리고 지점별 대기(E1에서 빠진 지점)의 합이다. | 새 DML 경로나 락 최적화가 하나 추가되면 라벨이 충돌 상대보다 작아진다. 이때 슬레이브 순서가 조용히 깨진다(위반은 무성 skip). | 확정(설계 관찰) | 신규 |
| A4 | Low | writeset.cpp:597-599 | NULL unique 키를 packed NULL 하나의 해시로 모은다. | 주석: "collected below as its packed NULL representation (conservative design policy)". | nullable unique 컬럼이 대부분 NULL인 테이블에서는 모든 INSERT·DELETE가 같은 슬롯에서 충돌한다. 그 테이블의 병렬 적용이 사실상 직렬이 된다. | 확정 | 신규 |

- **A1**: 마스터 파라미터(예: writeset 수집 on/off)를 두고, 꺼져 있으면 라벨을 쓰지 않는다. 슬레이브는 라벨이 없을 때 이미 commit-order로 떨어지므로(log_applier.c:7574-7578) 호환된다.
- **A3**: 불변식을 한 곳에 명시한다. 예를 들어 "복제 서버에서 complete_mvcc 이후 self-lock 해제 전의 MVCCID는 다른 트랜잭션에게 in-progress"로 정한다. 이를 MVCC 판정 헬퍼로 강제하면 E1 계열이 한 번에 닫힌다. 그러면 `prev_commit` 축소의 근거도 코드로 보장된다.
- **A4**: unique 인덱스의 NULL은 제약상 충돌하지 않으므로 키에서 빼도 된다. 그렇게 하면 "NULL → 값" UPDATE의 old 키 쪽만 빠진다. 같은 행의 PK WRITE가 행 단위 순서는 지키므로, 이 정책을 다시 검토할 가치가 있다(정확성 검증 필요, 추정).

### 3.4 리팩토링

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| R1 | Low | log_applier.c:434, 872, 1005, 1249, 1259, 7512, 7529, 7638, 7764, 7825 | trace 문자열에 coordinator 대신 "reader"가 남아 있다. | `"[WSET] reader schedule ..."`, `"[WSET] reader retire ..."` 등. | 로그 분석 스크립트나 운영자가 코드의 coordinator 명칭과 로그를 대응시키기 어렵다. | 확정 | 신규 |
| R2 | Low | log_applier_pending.cpp:97-131, log_applier.c:709-725 | `la_pending_pop_ready`가 매번 리스트 앞부터 선형 탐색한다. drain은 O(n²)이다. | pending은 ring 용량(워커 수 × 1024, 최대 32,768)까지 찰 수 있다. | 긴 의존 사슬 뒤에 수만 건이 parked된 상태에서는 결과 하나를 수집할 때마다 coordinator CPU가 pending 길이의 제곱에 비례해 쓰인다. | 확정 | 신규 |
| R3 | Low | log_applier.c:1430-1456 | 테스트 전용 지연 훅이 release 빌드에 있고, 커밋마다 `getenv`를 부른다. | `getenv ("CUBRID_HA_TEST_BLOCK_CLASS")`, `usleep (block_msec * 1000)`. 기본값은 60초다. | 운영 환경에 해당 환경변수가 남아 있으면 특정 클래스 커밋마다 60초씩 멈춘다. | 확정 | 신규 |
| R4 | Low | log_applier.c:1207-1222 | `la_coordinator_store_apply_info_at_interval`의 `static UINT64 last_store_ns`가 applier 재시작 사이에 초기화되지 않는다. | 함수 안 static 변수. | 영향은 첫 저장이 조금 늦어지는 정도다. 상태를 전역 init 계약 밖에 두는 패턴이라 M3과 같이 정리할 대상이다. | 확정 | 신규 |

- **R2**: `dependency_seq` 기준 최소 힙이나 정렬 리스트를 두면, frontier 이하 항목만 앞에서부터 꺼낼 수 있다. 같은 dep 안의 parking 순서는 보조 키(seq)로 유지한다.

## 4. 미검증 의심(근거 부족으로 확정 못 함)

1. **E3의 실제 발생 여부**: 마스터가 재시작한 뒤 HA가 active가 되기 전후에, 데이터를 바꾼 LOG_COMMIT이 라벨 R과 첫 사용자 커밋 사이에 항상 생기는지 확인하지 못했다(boot 트랜잭션, catalog, HA state 전환 경로). 마스터 단독 재시작(failover 없음) 시나리오의 HA 테스트 기록으로 확인해야 한다.
2. **sub-MVCCID(selupd/INCR) deleter**: `logtb_complete_sub_mvcc`(log_tran_table.c:4952)는 sub-id self-lock을 하위 트랜잭션 끝에 놓는다. 그래서 `btree_is_deleter_committing`이 sub-id로 지워진 키에 대해서는 바깥 트랜잭션이 커밋 중이어도 false를 돌려줄 수 있다. INCR/DECR이 unique 키 삭제를 만들 수 있는지는 확인하지 못했다.
3. **slave fragment 분리의 경계**: `la_detach_sysop_fragment`는 바깥 apply 리스트에서 `lsa ≤ SYSOP_END`인 항목을 모두 fragment로 옮긴다. 마스터는 `is_commit=false`일 때 `LOG_REPL_NEED_FLUSH`만 로그에 쓰므로 정상 DML은 섞이지 않는다. 다만 라벨 없이 끝난 다른 sysop(예: `LOG_SYSOP_END_LOGICAL_UNDO` 등 COMMIT 외 타입으로 끝났지만 repl 항목이 있는 경우)의 항목은 다음 라벨 fragment에 섞여 먼저 커밋될 수 있다. 그런 sysop 타입이 실제로 존재하는지는 확인하지 못했다.
4. **`pthread_rwlock` 기본 reader 선호**: `wset_publish_with_capacity`가 shared에서 exclusive로 올릴 때, 쓰는 쪽은 `seq_lock`을 잡은 채 wrlock을 기다린다. 이 동안 모든 커밋의 dependency 탐색과 baseline 갱신이 `seq_lock`에서 멈춘다. 교착은 아니지만 history가 가득 찰 때마다 마스터 커밋 지연이 튈 수 있다. 측정이 필요하다.

## 5. 총평

마스터 쪽의 키 수집과 라벨 선택, 그리고 슬레이브 쪽 gate·ring·pending·inflight 분해는 각 조각만 보면 주석과 코드가 잘 맞는다. 특히 다음 세 가지는 동시성 관점에서 일관되게 설계되어 있다.

- 라벨과 commit, 라벨과 SYSOP_END를 같은 `prior_lsa_mutex` 구간에 묶은 점
- 게시를 락 해제 전에 둔 점
- frontier 기반 committed_lsa와 max_committed_lsa로 재시작 범위를 정한 점

문제는 **모듈 사이 불변식의 경계**에 몰려 있다.

- **라벨 의미의 불일치**: 마스터는 라벨로 커밋 LSA, SYSOP_END LSA, "다음 append 위치"라는 세 종류의 좌표를 쓴다. 슬레이브 게이트는 라벨이 ring 위의 레코드라고 가정한다(E3). 하한(history_start)과 기준선(prev_commit_lsa)도 경로마다 다르게 적용된다(E2). 이 둘은 재시작이나 serial 이후처럼 드물지만 반드시 오는 시점에 순서를 깨거나 applier를 멈출 수 있다.
- **락 해제 전 게시라는 엔진 전역 전제**: 의존성 축소의 정확성은 이 전제에 기대는데, CBRD-26942 이후로는 행 락 대신 self-lock 대기를 지점마다 붙여서 유지되고 있다. FK 검사와 부모 삭제 검사 경로가 빠져 있다(E1, A3).
- **슬레이브 coordinator의 대기와 공유 상태**: 블로킹 대기가 종료 요청을 보지 못하고(E4), copied log header를 mutex 밖에서 읽는다(E5). 둘 다 병렬화로 새로 생긴 위험이다.

우선순위는 E2와 E3의 라벨·게이트 의미 통일, E1의 커밋 중 MVCCID 판정 일원화, E4의 블로킹 대기 해소 순으로 제안한다. 앞의 두 가지는 단위 테스트(overflow와 RESTART/SYSOP 하한, ring에 없는 라벨)로 바로 고정할 수 있다.
