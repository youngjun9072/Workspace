# CBRD-27508 브랜치 리뷰: 어플리케이션 개발자 5년차

## 1. 리뷰어 관점

애플리케이션 쪽에서 보이는 동작을 중심으로 봤다. 확인한 것은 네 가지다. master에서 커밋된 결과가 slave에 같은 의미로 재현되는지, 사용자 DML이 받는 에러 코드와 실패 조건이 바뀌는지, 기존 DB·이전 버전 노드·클라이언트 라이브러리와 호환되는지, master 커밋 경로와 slave 적용 처리량에 성능 영향이 있는지다. 5년차 관점에서는 모듈 사이의 상호작용(locator ↔ writeset ↔ log_manager ↔ applier gate)과 경계 조건(재시작, 파티션, FK, serial)을 끝까지 따라가는 데 시간을 썼다.

## 2. 검토 범위와 실제로 읽은 경로

범위는 `git diff a9a0dc78d 0e411f10f`(12 커밋)이고, HEAD는 0e411f10f이다. 기준선과 비교할 때는 `git show a9a0dc78d:<path>`를 썼다.

- **writeset (master)**
  - `src/transaction/writeset.cpp`: 전체(해시, midxkey 축약, add_write/add_ref, find_dependency_in_range, publish_with_capacity, clear, discard/abort, sysop fallback, raise_history_start)
  - `writeset.hpp`, `writeset_types.hpp`, `writeset_history_map.{hpp,cpp}`
- **master 호출부**
  - `locator_sr.c`: `locator_wset_collect_fk_ref`, `locator_add_or_remove_index_internal`의 수집 블록, `locator_update_index`의 수집 블록과 pk 경로, `locator_is_inserter_committing`, `locator_lock_and_get_object_internal`의 대기, `xlocator_repl_force`의 deadlock 처리
  - 파티션 insert 경로(`real_class_oid`, 4909~5217행)
- **log 계층**
  - `log_manager.c`: `log_commit_local`, `log_complete_for_2pc`, `log_sysop_commit_internal`, `log_append_sysop_end_internal`, `log_append_wset_label_*`, `log_sysop_fallback_reason`, `log_initialize_internal`의 RESTART 상승, `log_dump_record`의 default 분기
  - `log_append.cpp`, `log_record.hpp`, `log_impl.h`, `log_recovery.c`, `log_tran_table.c`(clear/initialize/copy_to)
  - `replication.c`(`repl_log_insert_statement`, `repl_log_abort_after_lsa`), `log_comm.c`의 `log_does_allow_replication`
- **btree, serial, 파티션**
  - `btree.c`: `btree_is_deleter_committing`, `btree_key_find_and_lock_unique_of_unique/_of_non_unique`의 DELETE_RECORD_DELETED/CAN_DELETE 분기, `btree_check_foreign_key`, `btree_find_foreign_key`, `btree_fk_object_does_exist`, `btree_read_key_type`
  - `serial.c`의 `serial_update_serial_object`
  - `partition.c`의 `partition_prune_unique_btid`
  - `schema_template.c`의 `smt_check_type_collation_match_4_fk`
- **slave**
  - `log_applier.c`: coordinator 함수 전부(`la_coordinator_*`), `la_log_record_process`, `la_apply_repl_log`, `la_flush_repl_items`, `la_apply_worker_*`, `la_get/update_ha_apply_max_committed_lsa`, main loop의 role change와 drain 처리
  - 기준선 `la_log_commit`·`la_commit_transaction`(비교용)
  - `src/transaction/applier/*`: gate, pending, task_queue, worker, task/result/inflight 헤더
- **파라미터, 에러, 카탈로그, 빌드**
  - `system_parameter.{c,h}`, `error_code.h`, `cubrid.msg`(en/ko), `heartbeat.h`, `schema_system_catalog_install.cpp`
  - `CMakeLists.txt`의 MULTI_CONN 전역 활성
  - `db_multi_threads_connections.h`(매크로 효과만 확인)
- **CS 쪽**
  - `work_space.{c,h}`와 `file_io.c`는 diff만 봤다. 지침에 따라 내부는 분석하지 않았다.
- **테스트**
  - `unit_tests/writeset/test_writeset.cpp`의 TEST_CASE 목록과 커버 범위
  - `unit_tests/log_applier/*` 목록

## 3. 발견 사항

### 3.1 에러

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| E1 | High | locator_sr.c:7793, 8066 / locator_sr.c:5141 / btree.c:26240 | 부모가 파티션 테이블이면 child REF 해시와 부모 WRITE 해시가 다른 키 공간에 떨어져 의존성이 사라진다 | REF는 `wset_add_ref_key (tdes, &index->fk->ref_class_oid, &index->fk->ref_class_pk_btid.vfid, ...)`로 root class와 root PK VFID를 쓴다. 부모 행 WRITE는 `locator_add_or_remove_index (…, &real_class_oid, …)` 안에서 파티션 class OID와 파티션 로컬 PK btid로 해시된다. master FK 검사도 `partition_prune_unique_btid`로 btid를 파티션 것으로 바꿔서 찾는다. | T1이 `INSERT INTO parent_p(id=7)`(hash 파티션), T2가 `INSERT INTO child(pid=7)`을 하고 C1 < C2로 커밋한다. T2의 REF는 history에서 miss가 나므로 label이 T1을 가리키지 않는다. slave(worker>1)에서 T2가 먼저 적용되면 ER_FK_INVALID가 나고, 이 item은 fail_counter만 올린 뒤 건너뛴다(log_applier.c:7103-7110). 그 결과 child 행이 slave에서 영구히 빠진다. 부모 DELETE와 child INSERT/DELETE 사이도 같은 이유로 순서가 보장되지 않는다. | 확정(코드 경로). 실행 재현은 하지 않음 | 신규 |
| E2 | High | log_manager.c:1513, writeset.cpp:1032·1091-1095, log_applier_gate.cpp:290, log_applier.c:7378·7420 | master 서버가 재시작한 뒤 첫 커밋의 label이 slave gate를 영원히 통과하지 못할 수 있다 | 재시작 때 `wset_raise_history_start (&restart_lsa /* = append_lsa */)`로 history_start가 L이 된다. 이후 모든 label은 L 이상이 된다(`wset_parent = history_start`, 아래 바닥 처리). gate는 `dep <= frontier`이고, frontier는 ring에서 연속으로 끝난 커밋 LSA만 따라간다. 재시작 전 커밋은 모두 L보다 작다. | worker>1인 slave에서 master가 재시작한 뒤 첫 커밋 T1(커밋 C1 > L, label L)이 들어오면 T1은 park된다. frontier를 L 이상으로 올리려면 L과 C1 사이에 label 없이 끝난 커밋(예: master 쪽 applylogdb의 apply_info 커밋)이 있어야 한다. 그런 커밋이 없으면 ring 맨 앞의 T1이 끝나지 않으므로 frontier는 영원히 L 아래에 머문다. 뒤따르는 모든 커밋도 label이 L 이상이라 함께 막혀 복제 지연이 계속 커진다. worker=1이거나 복구 구간이면 gate를 거치지 않으므로 해당하지 않는다. | 추정. 논리 연쇄는 코드로 확인했지만, label 없는 커밋이 L과 C1 사이에 끼는지는 기동 순서에 따른 경합이라 미검증 | 신규 |
| E3 | Medium | btree.c:30530 (`btree_fk_object_does_exist` DELETE_RECORD_DELETED), btree.c:27508 (unique_of_unique CAN_DELETE → S lock), locator_sr.c:13303 | "커밋 중인 inserter/deleter를 기다린다"는 수정(d1d02b9e4, 79268ae56)이 FK 검사 경로에는 들어가지 않았다 | d1d02b9e4는 `lock_mode == X_LOCK` 경로만, 79268ae56은 unique 검사의 DELETE_RECORD_DELETED만 고쳤다. FK 쪽 두 경로는 그대로다. 부모 DELETE의 child 존재 검사(`btree_fk_object_does_exist`)는 DELETED면 "없음"으로 즉시 반환한다. child INSERT의 부모 검사(`xbtree_find_unique (…S_SELECT_WITH_LOCK…)`)는 MVCCID가 complete된 부모 행을 CAN_DELETE로 보고 S lock을 바로 얻는다(inserter는 행 X lock이 없음, locator_sr.c:13185-13190 주석). | (a) T1이 child 행(pid=1)을 DELETE하고 complete_mvcc를 마친 뒤 postpone 중이다. 이때 T2가 parent(id=1)를 DELETE하면 child가 "없다"고 보고 통과하여 T2가 먼저 커밋된다. slave에서는 T2가 먼저 적용되어 ER_FK_RESTRICT가 나고 item이 skip된다. (b) T1의 부모 INSERT가 커밋 중일 때 T2의 child INSERT가 먼저 커밋되면 slave에서 FK_INVALID가 난다. label로는 막을 수 없다. publish가 커밋 레코드 뒤에 일어나므로 T2의 probe가 T1을 볼 수 없기 때문이다. | 추정(경합 창 존재는 코드로 확인, 재현 안 함) | 기존(develop 직렬 적용에서도 커밋 순서가 뒤집힘). 이 브랜치가 같은 부류를 고치면서 이 경로를 빠뜨림 |
| E4 | Medium | schema_system_catalog_install.cpp:1096-1097, log_applier.c:2896-2916·3349-3353 | `db_ha_apply_info`에 컬럼 2개가 추가됐는데 기존 DB용 마이그레이션이 없다 | 카탈로그 정의에만 `max_committed_lsa_pageid/offset`이 추가됐다. applylogdb 시작 때 `SELECT max_committed_lsa_pageid … FROM db_ha_apply_info`를 실행하고 실패하면 `return res`로 끝난다. 저장소 전체를 grep해도 ALTER나 migrate 코드가 없다. | 이전 버전으로 createdb한 slave DB에 새 바이너리를 올리면 applylogdb 초기화가 "컬럼 없음"으로 실패하고 재시작을 반복하며 복제가 시작되지 않는다. 카탈로그를 `SELECT *`로 읽는 운영 도구는 열 수가 바뀐다. | 확정(코드). 실행 재현은 안 함 | 신규 |
| E5 | Medium | log_record.hpp:140, log_manager.c:5013·4888 (기준선 log_applier.c:6336) | 새 로그 레코드 타입 53이 이전 버전 applier에는 "손상된 레코드"로 보인다. master에서 이 레코드 쓰기를 끌 방법도 없다 | 기준선에서는 `LOG_LARGER_LOGREC_TYPE`이 53이었고, 이전 applier는 `lrec->type >= LOG_LARGER_LOGREC_TYPE`이면 `ER_LOG_PAGE_CORRUPTED`를 반환한다. 이 브랜치의 master는 HA active 상태에서 모든 커밋과 serial sysop 앞에 `LOG_DUMMY_WSET_LABEL(=53)`을 무조건 쓴다. | 패치 단위 롤링 업그레이드(master를 먼저 올림), 이전 버전 replica, 이전 버전 로그 분석 도구가 첫 label 레코드에서 멈춘다. 복제가 중단된다. | 확정(코드) | 신규 |
| E6 | Medium | log_applier.c:1207-1222, 777-810, 5970-5996, 6964 (기준선 la_log_commit 6536-6561) | slave 재시작 지점이 데이터 커밋과 분리되어, 재시작하면 이미 커밋된 트랜잭션이 다시 적용된다 | 기준선은 `la_update_ha_last_applied_info` 뒤에 같은 트랜잭션에서 `la_commit_transaction`을 해서 재시작 지점이 원자적이었다. 이 브랜치는 worker가 따로 커밋하고, coordinator가 일정 간격으로 committed_lsa를 저장한다. 그 사이 구간은 "recovery range"로 다시 적용하고 dup/not-found 에러는 숨긴다. 문장 재적용은 `TODO: handle statement re-apply` 상태다. | (a) T1(v=1)과 T2(v=2)가 모두 반영된 뒤 applier가 재시작하면 T1을 다시 적용하는 동안 slave 읽기에서 v=1이 잠시 보인다. 지워진 뒤 다시 INSERT된 행은 잠시 사라진다. (b) recovery range 안의 문장 복제 항목(DDL 등)이 두 번 실행되면 에러 처리는 TODO 그대로이고, 문장이 멱등이 아니면 결과가 달라질 수 있다(추정). | (a) 확정(구조). (b) 추정 | 신규 |
| E7 | Low | writeset.cpp:536-538·678-680, locator_sr.c:7793-7809·8051-8058, serial.c:1236-1239 | writeset 키를 만들다 실패하면 사용자 DML이나 NEXT VALUE가 실패한다. 새 에러 코드 -1386도 애플리케이션에 노출된다 | `wset_push_hash`의 bad_alloc은 ER_OUT_OF_VIRTUAL_MEMORY, 도메인/collation/element 추출 실패는 `ER_HA_WRITESET_KEY_BUILD_FAILED`, `btree_read_key_type`이 NULL이면 `locator_wset_error`가 되어 모두 `goto error`로 간다. 같은 파일에 안전한 대안(`wset_fallback_to_commit_order`)이 이미 있다. | HA master에서만 메모리 압박이나 page fix 실패(interrupt 등) 때 INSERT/UPDATE/DELETE/AUTO_INCREMENT가 실패한다. 같은 SQL이 HA가 아닌 서버에서는 성공한다. 복제 메타데이터 때문에 사용자 작업이 실패하는 셈이다. | 확정(경로). 빈도는 낮음 | 신규 |
| E8 | Low | log_manager.c:7466-7470 (log_dump_record default) | `log_dump_record`에 LOG_DUMMY_WSET_LABEL case가 없다 | default 분기가 `"log_dump: Unknown record type = %d"`를 출력하고 `LSA_SET_NULL (log_lsa)`을 한다. | 로그 덤프(diag)에서 커밋마다 "Unknown record type 53"이 찍히고 label 값은 안 보인다. 다음 레코드는 forw_lsa로 이어지므로 덤프 자체는 계속된다. | 확정 | 신규 |

**E1 상세.** writeset 해시는 `(class OID, index VFID, key)`이다(writeset_types.hpp:31). 일반 테이블에서는 child의 `ref_class_oid / ref_class_pk_btid`가 부모 행 WRITE의 `class_oid / index->btid`와 같다. 파티션 부모에서는 그렇지 않다. 부모 행은 `locator_insert_force`에서 `real_class_oid`(파티션)로 바뀐 뒤 그 파티션의 index 목록으로 수집되고(locator_sr.c:5141), 파티션의 PK는 `partition_find_inherited_btid`가 찾는 별도 btid다. master의 FK 검사(btree.c:26240-26247)가 root btid를 파티션 btid로 바꿔 쓰는 것이 두 값이 다르다는 근거다. 단위 테스트(test_writeset.cpp:76, 119)는 호출자가 같은 OID/VFID를 넘기는 전제에서 해시가 같은지만 보므로, 이 매핑은 검증하지 못한다.

수정 방향은 둘 중 하나다. 하나는 REF를 수집할 때 부모 PK 키로 파티션을 pruning해서 파티션 OID와 btid를 쓰는 것이다. FK 검사와 같은 `partition_prune_unique_btid`를 쓰면 되고, 이미 FK 검사에서 같은 값을 구하므로 재사용할 수 있다. 다른 하나는 파티션 부모의 WRITE를 root OID와 root PK VFID로 정규화하는 것이다. 회귀 테스트는 "파티션 부모 + child INSERT/DELETE"의 HA 시나리오로 추가하는 것이 좋다.

**E2 상세.** 주석(log_manager.c:1503-1509)은 "gate가 frontier가 label에 닿을 때까지 기다린다"고 설명하지만, label L은 어떤 커밋의 LSA도 아니다. L 이상인 첫 커밋이 바로 그 label을 가진 트랜잭션이면 스스로를 기다리는 꼴이 된다. 다음 두 경우에는 막히지 않는다. 하나는 overflow 트랜잭션이다. label이 `prev_commit_lsa`이고 바닥 처리를 받지 않으며, 재시작 직후에는 NULL이다(writeset.cpp:1111-1118). 다른 하나는 label 없는 빈 커밋이 먼저 오는 경우다(log_applier.c:7574). 따라서 실측에서는 master 쪽 applylogdb가 시작 시점에 하는 커밋 때문에 문제가 가려질 가능성이 높다(추정).

검증 방법은 다음과 같다. slave를 worker 4로 두고 master를 재시작한 뒤, master 쪽 applylogdb를 띄우기 전에 단일 DML 트랜잭션을 하나 실행한다. 이후 slave trace에서 `status=PARKED` 상태가 계속되는지 확인한다. 수정 방향으로는 세 가지를 생각할 수 있다. RESTART floor를 "재시작 직전 마지막 커밋 LSA"로 잡거나, slave가 `dep`를 ring의 commit LSA로 내림 처리하도록(dep보다 작은 커밋이 모두 끝났으면 통과) gate 조건을 바꾸거나, 재시작 때 label 없는 표지 레코드를 하나 쓰는 것이다.

**E3 상세.** d1d02b9e4와 79268ae56은 "master에서 MVCCID complete부터 self-lock 해제까지의 틈 때문에 커밋 순서가 뒤집히는 문제"를 각각 X_LOCK DML과 unique 검사에서 막았다. FK 검사는 같은 틈을 공유하는데도 막혀 있지 않다. 이 순서 역전은 develop(직렬 적용)에서도 같은 slave FK 에러를 내므로 기존 결함이다. 다만 이 브랜치가 같은 부류를 고치는 중이므로 범위 안에서 마무리할 가치가 있다. `btree_fk_object_does_exist`의 DELETED 분기와 FK 검사 경로의 CAN_DELETE 분기에도 `btree_is_deleter_committing`과 비슷한 조건부 대기를 넣는 것이 좋다.

**E5 상세.** CUBRID HA는 보통 같은 버전으로 운영하지만, 패치 단위 롤링 업그레이드나 replica 노드의 버전 차이가 생기면 바로 복제가 끊긴다. 최소한 릴리스 노트에 "이전 버전 applier와 호환 불가"를 명시해야 한다. 가능하다면 writeset 생성을 끄는 파라미터를 두는 것이 좋다. A2와 함께 해결된다.

**E6 상세.** 재적용이 수렴한다는 사실 자체는 행 이미지 기반 재생이라 맞다. 하지만 slave를 읽기 복제로 쓰는 애플리케이션은 재시작마다 과거 값이 잠깐 보이는 동작을 처음 겪게 된다. 기준선에는 없던 동작이다. 운영 문서에 적거나 재시작 직후 복구 구간 동안 slave 읽기 가시성에 대한 안내가 필요하다.

### 3.2 아키텍처 (성능·의미 포함)

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| A1 | High | log_manager.c:4038-4072, writeset.cpp:1032·1436-1454·1467-1487 | serial/AUTO_INCREMENT를 갱신하는 sysop마다 history_start가 올라간다. 그 뒤의 모든 트랜잭션 label이 그 지점 위로 바닥 처리되어 병렬도가 무너진다 | `if (LOG_SYSOP_END_COMMIT && repl_item_count > 0) { … wset_raise_history_start (&sysop_lsa, "SYSOP_COMMIT_ORDER"); }` 모든 label은 `wset_parent = history_start`에서 출발한다. 코드 TODO(4045-4051)도 이 한계를 인정한다. | AUTO_INCREMENT 테이블에 INSERT가 많은 OLTP에서 트랜잭션마다 serial sysop이 생긴다. 각 sysop 뒤의 모든 커밋은 "sysop 이전 커밋 전부 + fragment"가 적용될 때까지 기다린다. 결국 병렬 창이 연속한 두 serial 갱신 사이의 트랜잭션만으로 줄고, worker를 늘려도 처리량이 직렬에 가까워진다. slave 커밋 수도 fragment 수만큼 늘어난다. | 코드 동작은 확정, 처리량 영향 크기는 추정(serial cache 설정에 따라 다름) | 신규 |
| A2 | Medium | writeset.cpp:1026-1030·1173-1178·1248-1253·1289-1322, locator_sr.c:8747-8788·7793, system_parameter.c (on/off 파라미터 없음) | writeset 수집과 label 기록이 모든 HA master에서 항상 켜져 있다. slave가 worker 1이라 label을 쓰지 않아도 master 커밋 경로가 비용을 낸다 | 커밋마다 전역 `seq_lock`을 두 번(find, advance) 잡고 rwlock도 잡는다. UPDATE는 비키 컬럼만 바꿔도 MVCC 경로에서 모든 PK/UK의 old·new 키를 해시하고, FK마다 old·new 두 번씩 `btree_read_key_type`(부모 PK root page fix + `or_unpack_domain`)을 호출한다. 맵이 차거나(기본 1M 키) DDL/overflow 커밋이 오면 `seq_lock`과 wrlock을 잡은 채 `map.clear()`를 한다. | 쓰기가 많은 master에서 (a) 모든 커밋이 seq_lock에서 직렬화된다. (b) 부모 PK root page에 read latch가 몰린다. (c) 맵이 찰 때마다, 그리고 DDL 커밋마다 1M 노드를 clear하는 동안 다른 커밋의 dependency 탐색이 모두 막혀 커밋 지연이 주기적으로 튄다. 애플리케이션에서는 HA 구성만으로 DML·커밋 지연이 늘어난 것으로 보인다. | 경로는 확정, 수치 영향은 추정(측정 필요) | 신규 |
| A3 | Medium | log_applier_gate.cpp:25-26, log_applier.c:7414-7427 | worker가 2 이상이면 slave의 커밋 가시성 순서가 master 커밋 순서와 다를 수 있고, 이를 보존하는 옵션이 없다 | "independent transactions are dispatched at once and commute, so the slave converges on the master without keeping commit order" | 애플리케이션이 FK나 키 관계 없이 T1(주문 INSERT) 다음 T2(집계 테이블 UPDATE)를 커밋했다. slave 읽기에서는 T2가 반영됐는데 T1은 없는 상태가 보일 수 있다. master에는 존재한 적이 없는 상태다. 기준선과 worker=1에서는 일어나지 않는다. MySQL의 `replica_preserve_commit_order` 같은 선택지가 없다. | 확정(설계) | 신규 |
| A4 | Medium | CMakeLists.txt:607, db_multi_threads_connections.h(`CUB_THREAD_LOCAL`) | `MULTI_CONN_TO_A_SERVER`가 applylogdb만이 아니라 전체 빌드에 전역으로 켜져 있다 | `add_definitions(-DMULTI_CONN_TO_A_SERVER)`가 CS_MODE의 여러 전역 변수를 `thread_local`로 바꾼다(src 27개 파일, 92곳). | libcubrid를 쓰는 모든 CS 클라이언트(CAS, csql, C API 애플리케이션)의 동작이 바뀐다. 예를 들어 연결을 한 스레드에서 열고 다른 스레드에서 직렬로 쓰는 C 애플리케이션은 연결 상태가 스레드별로 갈라질 수 있다. TLS 접근 비용도 생긴다. | 추정(지침상 CS 내부는 분석하지 않음. 매크로 범위만 확인) | 신규 |
| A5 | Medium | log_tran_table.c:1622, 1706 / writeset.cpp:532 | 트랜잭션이 끝나도 `wset_hashes`의 capacity가 반환되지 않는다 | `tdes->wset_hashes.clear ()`는 std::vector의 capacity를 유지한다. 해제는 overflow 경로의 swap(writeset.cpp:559)에서만 한다. 항목은 24바이트이고 트랜잭션당 한도는 history_size(1M)다. | 키 90만 개를 다루는 배치 트랜잭션을 한 번 실행한 세션(tran index)은 약 25MB를 서버가 끝날 때까지 들고 있다. 배치 세션이 여러 개면 cub_server 메모리가 계속 늘어난다. | 확정 | 신규 |
| A6 | Low | log_applier.c:777-810 | slave가 거의 따라잡은 상태에서는 dispatch할 때마다 coordinator가 별도 UPDATE와 COMMIT을 실행할 수 있다 | bound가 `max(commit_lsa, eof_lsa)`이고, `commit_lsa > max_committed_lsa`이면 `la_update_ha_apply_max_committed_lsa` 안에서 `db_commit_transaction`을 실행한다. | 지연이 거의 없을 때 eof가 커밋 하나씩 늘어나면 master 커밋 하나마다 slave에 추가 커밋이 생기고, 그만큼 dispatch 지연과 slave 로그 플러시가 늘어난다. | 경로는 확정, 빈도는 추정 | 신규 |
| A7 | Low | log_applier_pending.cpp:98-131, log_applier.c:715 | `la_pending_pop_ready`는 매번 머리부터 선형으로 훑고, drain은 이 함수를 반복해서 부른다 | park된 작업이 n개면 drain 한 번에 O(n²)이다. n의 상한은 worker×1024다. | worker 10, 의존이 긴 사슬일 때 coordinator CPU가 pending을 훑는 데 쓰여 log 읽기가 늦어진다. | 확정(복잡도), 영향 크기는 추정 | 신규 |

**A1 상세.** 코드의 TODO가 의도를 설명하지만, 애플리케이션 관점에서는 "AUTO_INCREMENT를 쓰면 병렬 적용 효과가 거의 없다"는 결과가 된다. 기능의 목적과 정면으로 부딪친다. serial 키는 이미 수집하고 있다(serial.c:1236). 따라서 serial sysop을 "같은 serial 키 WRITE에만 순서를 거는 publish"로 바꾸는 방향(TODO의 대안)을 우선 과제로 올리는 것이 좋다. 그 전까지는 serial cache 권장을 문서화하는 것으로 완화할 수 있다.

**A2 상세.** `ha_writeset_history_size`는 최솟값이 1이라 기능을 끌 수 없다. `ha_apply_worker_count=1`(기본값)인 사용자도 master 비용을 모두 낸다. 제안은 두 가지다. writeset 생성을 끄는 파라미터를 두어 E5의 호환성 문제와 함께 해결하고, master 비용을 따로 측정해 둔다(UPDATE·FK가 많은 부하 기준).

### 3.3 모듈화

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| M1 | Low | serial.c:1225-1250, log_manager.c:4071-4072 | serial sysop 안에서 수집한 키는 SYSOP_END에서 항상 버려진다. 수집 자체가 쓸모없는 작업이고 실패 경로만 만든다 | serial 갱신은 반드시 repl item을 만들고, 그러면 `repl_item_count > 0`이 되어 `wset_discard_sysop_keys`가 호출된다. 게다가 `serial_Cached_btid`가 NULL이면 `wset_fallback_to_commit_order`가 sysop이 아니라 바깥 사용자 트랜잭션 전체를 overflow로 만든다. | (a) 쓰이지 않을 해시 때문에 NEXT VALUE가 E7처럼 실패할 수 있다. (b) cache가 아직 비어 있을 때 사용자 트랜잭션 전체가 commit order로 바뀌고, 커밋 때 history 전체가 clear된다(A2의 비용). | 확정 | 신규 |
| M2 | Low | log_manager.c:3997-4028, 4768-4780, 4800-4870 | repl record 카운트 루프가 3군데 중복되고, trace에만 쓰는 계산이 trace가 꺼져 있어도 매번 실행된다 | sysop commit마다 `repl_item_count`, `log_sysop_fallback_reason`(packed data를 풀고 class 이름 strcmp), `flushed_item_count` 루프를 무조건 돈다. | 큰 트랜잭션에서 sysop마다 pending repl record를 기존보다 3번 더 훑는다. 상수배 비용이지만 hot path다. 같은 판정을 세 곳에서 따로 하므로 고칠 때 어긋나기 쉽다. | 확정 | 신규 |

### 3.4 리팩토링

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| R1 | Low | log_applier.c:872, 1249, 1259, 7505, 7512, 7638, 7764, 7819, 7825 | coordinator가 남기는 trace 문자열에 "reader"가 남아 있다 | `"[WSET] reader schedule …"`, `"reader defer_sysop_end …"`, `"[WSET] reader commit …"` | 운영자가 로그를 grep할 때 함수명(coordinator)과 로그 용어(reader)가 달라 추적이 어렵다. | 확정 | 신규 |
| R2 | Low | log_applier.c:1400-1456 | 테스트 전용 훅이 release 빌드에 남아 있고, 커밋마다 `getenv`를 두 번 호출한다 | `getenv ("CUBRID_HA_TEST_BLOCK_CLASS")`가 걸리면 `usleep (block_msec*1000)`(기본 60초)을 한다. | 운영 환경에 남은 환경변수 하나로 특정 테이블 적용이 커밋마다 60초씩 멈춘다. TODO에 적힌 대로 debug 전용으로 돌리거나 시작 때 한 번만 읽는 것이 좋다. | 확정 | 신규 |
| R3 | Low | writeset.cpp:998-1017, 1121 | `wset_find_dependency_in_range`의 `begin` 인자는 늘 0이고, 함수 머리 주석 블록은 `wset_find_dependency_from_history` 설명인데 다른 함수 위에 붙어 있다 | 호출부는 `wset_find_dependency_in_range (tdes, 0, …)` 하나뿐이다. | 읽는 사람이 범위 probe(부분 writeset) 기능이 있다고 오해한다. | 확정 | 신규 |
| R4 | Low | log_applier.c 전반(11,131행) | coordinator 함수(약 30개)가 아직 log_applier.c 안에 있다 | gate, pending, queue, worker는 `applier/`로 분리됐지만 dispatch, collect, retire, cover, recovery-range는 남아 있다. | 파일이 계속 커져 리뷰 단위가 흐려진다. coordinator를 `applier/log_applier_coordinator.cpp`로 옮기면 단위 테스트(현재 gate, pending, queue만 대상)를 dispatch와 retire 규칙까지 넓힐 수 있다. | 확정 | 신규 |

## 4. 미검증 의심 (근거 부족으로 확정 못 한 것)

1. **FK와 PK의 정밀도가 다를 때 에러 코드가 바뀌는지.** `smt_check_type_collation_match_4_fk`는 type id와 collation만 비교하므로 VARCHAR(20)인 child가 VARCHAR(10)인 parent를 참조할 수 있다. 이때 `wset_cast_value_to_domain`(writeset.cpp:689-711)이 DOMAIN_OVERFLOW를 내면, 원래 `ER_FK_INVALID`가 나와야 할 INSERT가 HA master에서만 `ER_TP_CANT_COERCE_OVERFLOW`로 실패할 수 있다. 키 수집(5141행)이 FK 검사(5158행)보다 먼저 실행되기 때문이다. `tp_value_cast`가 문자열 초과 길이에 OVERFLOW를 내는지는 확인하지 않았다.
2. **trailing space를 무시하는 collation에서 parent 'abc'와 child 'abc '의 해시.** btree 비교에서는 같은 값이라 FK가 통과하지만, `mht2str`가 trailing space를 같게 취급하는지 확인하지 않았다. 다르게 취급하면 E1과 같은 유형으로 의존성이 빠진다.
3. **`btree_read_key_type`의 unconditional root latch.** index 루프 안에서 다른 page latch를 잡은 상태로 호출되는지 확인하지 못했다. 잡은 상태라면 latch 순서 문제가 생길 수 있다.
4. **DDL 직후 다른 worker의 클라이언트 workspace 스키마 캐시가 낡을 가능성.** worker마다 sub-connection을 쓰므로 한 worker가 DDL을 적용한 뒤 다른 worker가 낡은 class 표현으로 DML을 flush할 수 있다. label로 순서는 지켜지지만 캐시 무효화는 CS 내부라 분석하지 않았다.
5. **OO 상속으로 unique btree를 공유하는 super/sub class.** 해시에 class OID가 들어가므로, super에서 키 K를 DELETE하고 sub에서 K를 INSERT하는 충돌을 놓칠 수 있다. 상속에서 btid를 공유하는지는 확인하지 않았다.
6. **E2가 실제 운영 기동 순서에서 재현되는지.** master 쪽 applylogdb의 시작 커밋이 애플리케이션 트랜잭션보다 먼저 들어오는지에 달려 있다.

## 5. 총평

writeset 수집과 gate 규칙의 뼈대는 일관되게 설계됐다. label을 commit LSA 공간에 두고 slave는 gap-free frontier(watermark)로 통과를 판단하므로 "최댓값 하나로 여러 선행자를 대표"하는 근거가 성립한다. worker=1에서 커밋 순서를 그대로 보존하는 점, label 없는 이전 master 로그를 직렬로 처리하는 점, 기존 결함 두 가지를 고친 점(lock 실패가 성공으로 보고되던 문제, 실패한 UPDATE의 repl record가 남던 문제)도 좋다.

다만 애플리케이션 관점에서는 세 가지를 먼저 해결해야 한다.

1. **E1.** 파티션 부모 FK에서 의존성이 빠지는 문제는 지원되는 스키마에서 slave 데이터가 조용히 어긋나는 결과로 이어진다.
2. **E2.** master 재시작 뒤 label floor가 gate에서 스스로를 기다리는 구조다. worker를 2 이상으로 둔 사용자에게 복제가 멈추는 위험이 있다(추정, 재현 권장).
3. **A1.** serial/AUTO_INCREMENT sysop마다 history_start가 올라가 일반 OLTP에서 병렬 효과가 사라진다.

호환성 쪽에서는 E4(카탈로그 마이그레이션 없음), E5(레코드 타입 53을 이전 버전이 손상으로 판단), A4(MULTI_CONN 전역 활성)가 배포 전에 정리돼야 한다. A2(writeset을 끌 수 없음)를 해결하면 E5와 비용 문제를 함께 완화할 수 있다.

slave에서 커밋 순서 가시성이 바뀌는 점(A3)과 재시작 때 재적용이 생기는 점(E6)은 설계상 선택일 수 있다. 그렇다면 운영 문서와 파라미터 설명에 반드시 남겨야 한다.
