# CBRD-27508 브랜치 리뷰 — 어플리케이션 개발자 10년차

## 1. 리뷰어 관점

- 애플리케이션이 실제로 보게 되는 것에 집중했다. slave에 반영된 결과가 master와 같은지(SQL·트랜잭션 의미 보존), DML이 새로 받게 되는 에러 코드, 버전 혼용·업그레이드 호환성, master 쪽 DML/커밋 경로에 생기는 성능 비용이다.
- 10년차 관점에서는 정상 경로보다 재시작·failover·업그레이드·운영 기본값처럼 드물게 타지만 한 번 걸리면 복구가 어려운 경로를 끝까지 따라갔다. 기존 CUBRID 구조(파티션, AUTO_INCREMENT/serial, 카탈로그, 로그 레코드 타입, CS 라이브러리)와 맞물리는 곳도 같은 비중으로 봤다.

## 2. 검토 범위와 실제로 읽은 경로

범위는 `git diff a9a0dc78d 0e411f10f`(HEAD = 0e411f10f)이고, 저장소는 읽기만 했다.

| 영역 | 읽은 파일·함수 |
|---|---|
| master writeset | `writeset.cpp` 전체(`wset_push_hash`, `wset_add_write_key`, `wset_add_ref_key`, `wset_midxkey_hash`, `wset_find_dependency_in_range`, `wset_publish_with_capacity`, `wset_clear_overflow_history`, `wset_find_sysop_fallback_dependency`, `wset_raise_history_start`, `wset_abort_after_lsa`, `wset_discard_sysop_keys`), `writeset.hpp`, `writeset_types.hpp`, `writeset_history_map.{hpp,cpp}` |
| master 로그/커밋 | `log_manager.c` diff 전체(`log_initialize_internal` 재시작 raise, `log_sysop_start`, `log_sysop_commit_internal`, `log_sysop_abort`, `log_append_wset_label_and_sysop_end`, `log_append_wset_label_with_lock`, `log_commit_local`, `log_complete_for_2pc`, `log_dump_record` default 분기), `log_append.cpp`, `log_record.hpp`, `log_impl.h`, `log_recovery.c`, `log_tran_table.c`(`logtb_clear_tdes`, `copy_to`, self-lock 획득부), `replication.c`, `serial.c`(`serial_update_serial_object`, `serial_cache_index_btid`) |
| master DML | `locator_sr.c` diff 전체(`locator_wset_collect_fk_ref`, `locator_add_or_remove_index_internal`, `locator_update_index`, `locator_is_inserter_committing`, `locator_lock_and_get_object_internal`, `xlocator_repl_force`), 비교용으로 `locator_check_foreign_key`(파티션 pruning), `locator_check_primary_key_delete`(applier에서의 RESTRICT·CASCADE 동작), `locator_insert_force`(real_class_oid) |
| master btree | `btree.c` diff(`btree_is_deleter_committing`, unique 검사 DELETE_RECORD_DELETED 분기), `lock_manager.c` `lock_transaction_mvccid`·`lock_unlock_transaction_mvccid` |
| 파라미터·에러·카탈로그 | `system_parameter.{c,h}`, `error_code.h`, `cubrid.msg`, `heartbeat.h`, `schema_system_catalog_install.cpp`, `util_sa.c`(apply_info INSERT) |
| slave | `applier/*` 전체(gate, pending, task_queue, worker; inflight·result_queue는 인터페이스와 사용처), `log_applier.c`의 coordinator 경로(`la_coordinator_submit_task`, `..._process_sysop_end`, `..._set_commit_dependency`, `..._process_commit`, `..._record_result`, `..._retire_results`, `..._complete_without_task`, `..._wait_for_commit_order_slot`, `..._cover_commit`), `la_log_record_process`, `la_get_wset_label`, `la_apply_repl_log`, `la_flush_repl_items`, `la_commit_transaction`, `la_change_state`, `la_find_required_lsa`, `la_get/update_ha_apply_max_committed_lsa`, `la_detach_sysop_fragment`, `la_check_mem_size`, 메인 루프의 drain timeout·종료 경로. develop의 `la_log_record_process`(LOG_LARGER_LOGREC_TYPE 검사)와 `la_commit_transaction`도 대조했다 |
| CS glue | `CMakeLists.txt`/`cs`/`sa`/`cubrid` CMakeLists, `work_space.{c,h}`, `file_io.c` diff, `log_applier_worker.cpp`의 `db_restart_sub`/`db_shutdown_sub` 호출부, `__gv_loc_repl` 선언(TLS인지 확인). `MULTI_CONN_TO_A_SERVER` 사용 위치는 grep으로 범위만 봤고 내부 구현은 분석하지 않았다 |
| 테스트 | `unit_tests/log_applier/test_log_applier_gate.cpp`의 케이스 목록, `unit_tests/writeset`에서 partition·restart 관련 케이스가 있는지 grep |

## 3. 발견 사항

### 3.1 에러

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| E1 | Critical | `log_manager.c:1503-1514`, `writeset.cpp:1032,1081-1095`, `applier/log_applier_gate.cpp:280-291`, `log_applier.c:733-764` | master가 재시작한 뒤 붙는 라벨은 어떤 commit LSA와도 같지 않다(재시작 시점의 append_lsa). slave gate는 이 라벨을 commit을 완료해서만 넘길 수 있는데, 그렇게 넘겨 줄 commit이 보장되지 않는다 | `wset_raise_history_start(&restart_lsa,"RESTART")`, `LSA_COPY(&wset_parent,&history_start_snapshot)`, `return ... LSA_LE(dep,&la_Gate_frontier)`, frontier는 ring에 올라간 commit LSA로만 이동함 | 워커 2개 이상. slave를 내린 채 master를 재시작하고 부하를 계속 준다. 재시작 뒤 commit은 모두 라벨 A를 단다(prev_commit이 NULL이므로 A). slave가 돌아오면 frontier는 재시작 전 마지막 commit P(<A)에 멈춘다. 재시작 뒤 commit은 전부 parked 상태가 되고, ring(워커 수×1024)이 차면 coordinator가 로그 읽기를 멈춘다. 이 상태를 풀어 줄 라벨 없는 commit(예: master 측 applylogdb의 apply_info 갱신)이 ring 용량보다 뒤에 있으면 영구 정지한다. applier를 재시작해도 같은 지점에서 다시 멈추고, 이 상태에서 failover가 나면 DONE을 보고하지 못한다 | 메커니즘 확정 / 실제 발생 추정(재현 안 함) | 신규 |
| E2 | High | `locator_sr.c:7819`(REF) ↔ `locator_sr.c:8051`·`5141`(WRITE), 비교 `locator_sr.c:4131-4139` | 부모가 파티션 테이블이면 FK REF 해시와 부모 PK WRITE 해시가 서로 만나지 않는다. REF는 루트 클래스 OID와 루트 PK btid로, WRITE는 파티션 OID와 파티션 btid로 만든다 | REF: `wset_add_ref_key(tdes,&index->fk->ref_class_oid,&index->fk->ref_class_pk_btid.vfid,…)`. WRITE: `wset_add_write_key(ws_tdes,class_oid,&index->btid.vfid,…)`, 여기서 class_oid는 `real_class_oid`. 실제 FK 검사는 `partition_prune_unique_btid`로 파티션 btid를 따로 찾는다 | 파티션 부모 P와 `ON DELETE CASCADE` 자식 C가 있다. Tx가 P(5)를 삭제하고(기존 자식은 cascade로 삭제), T1이 P(5)를 다시 넣고, T2가 C(10, fk=5)를 넣는다. T2의 REF(root,5)는 Tx·T1의 WRITE(P_part,5)를 찾지 못하고 C(10)도 새 키라서 의존성이 없다. slave에서 T2가 Tx보다 먼저 적용되면 Tx의 parent delete가 slave에서 cascade로 C(10)까지 지운다. 결과적으로 master에는 C(10)이 있고 slave에는 없다 | 해시 불일치 확정 / 발산은 타이밍에 달려 있어 추정 | 신규 |
| E3 | High | `log_record.hpp:140`, `log_manager.c:5013`(무조건 기록), develop `log_applier.c:6336` | 새 레코드 타입 `LOG_DUMMY_WSET_LABEL = 53`은 구버전의 `LOG_LARGER_LOGREC_TYPE`(=53)과 값이 같다. 구버전 applylogdb는 이 레코드를 손상 레코드로 판단한다. 라벨은 slave 워커 수와 관계없이 HA master의 모든 복제 commit에 기록된다 | develop: `lrec->type >= LOG_LARGER_LOGREC_TYPE → ER_LOG_PAGE_CORRUPTED`. HEAD: `log_append_wset_label_with_lock` 호출을 끄는 조건이 없다 | 롤링 업그레이드에서 master를 먼저 올리면, 구버전 slave applylogdb는 첫 commit에서 `ER_HA_LA_INVALID_REPL_LOG_RECORD`로 멈춘다 | 확정 | 신규 |
| E4 | High | `schema_system_catalog_install.cpp:1096-1097`, `log_applier.c:2896-2898`, `3349-3353` | `_db_ha_apply_info`에 컬럼 2개를 추가했지만 기존 DB용 마이그레이션은 없다. applier는 시작할 때마다 새 컬럼을 SELECT하고, 실패하면 시작하지 못한다 | `"SELECT max_committed_lsa_pageid, max_committed_lsa_offset FROM %s …"` → `if (res < 0) return res;` → `la_get_ha_apply_info ... return res` | 구버전으로 만든 DB(또는 그 백업으로 구축한 slave)에서 바이너리만 교체하면 applylogdb가 기동 단계에서 계속 실패하고 복제가 재개되지 않는다 | 확정(저장소 전체 grep 결과 마이그레이션 없음) | 신규 |
| E5 | Medium | `log_applier.c:4638-4666`, `7815-7818`, `7550-7558` | 라벨 본문을 읽지 못하면 의존성이 NULL로 남는다. 그런데 holder에는 trid가 기록되므로, 그 commit은 '라벨 있음 + 의존성 없음'으로 처리돼 바로 dispatch된다. 라벨이 없을 때 쓰는 보수적 경로(직전 commit 대기)를 타지 않는다 | `la_get_wset_label`: `if (error != NO_ERROR) return;`(dep는 NULL), 호출부: `la_wset_label_trid = lrec->trid;` 무조건 | 레코드 본문이 다음 페이지로 넘어가는데 `LA_LOG_READ_ADVANCE_WHEN_DOESNT_FIT`가 페이지를 가져오지 못하면, 해당 트랜잭션이 선행 충돌 트랜잭션을 기다리지 않고 적용된다. 그 결과 unique 위반으로 fail_counter가 늘거나 행이 조용히 어긋난다 | 코드 경로 확정 / 발생 빈도 추정 | 신규 |
| E6 | Medium | `log_tran_table.c:1622`, `1706`, `writeset.cpp:520,532` | `std::vector::clear()`는 용량을 돌려주지 않는다. 큰 트랜잭션 한 번이 그 tdes에 최대 history_size×24B(기본 약 24MB)를 서버 수명 동안 붙잡아 둔다 | `tdes->wset_hashes.clear ();`. overflow 경로에서만 `swap`으로 메모리를 해제한다 | 배치 세션 수백 개가 각각 키 90만 개 수준의 트랜잭션을 한 번씩 실행하면, 이후 유휴 상태에서도 tdes당 약 20MB가 남는다. master RSS가 이만큼 계속 높게 유지된다 | 확정 | 신규 |
| E7 | Medium | `log_applier.c:8479-8494`, `8125-8157` | 메모리 상한 검사는 VSZ 기준이다. 워커 스레드마다 malloc arena가 생기므로, 기본값 `ha_apply_max_mem_size=500`에서는 유휴 상태에서도 상한 초과로 판단해 applier를 종료할 수 있다. 코드 주석이 이 문제를 직접 적고 있다 | 주석: "with the default ha_apply_max_mem_size (500MB) the applier can falsely trip the over-limit shutdown" | `ha_apply_worker_count`만 올리고 메모리 파라미터는 그대로 둔 사이트에서 applylogdb가 주기적으로 재시작한다. 재시작할 때마다 recovery range를 직렬로 재적용하므로 지연이 늘어난다 | 메커니즘 확정(주석과 코드) / 빈도 추정 | 신규(기본값과 결합된 문제) |
| E8 | Low | `log_applier.c:1430-1460` | 테스트용 훅이 릴리스 빌드에 남아 있다. commit마다 `getenv`를 2회 호출하고, 환경변수가 설정돼 있으면 해당 클래스 commit을 60초 동안 멈춘다 | `getenv ("CUBRID_HA_TEST_BLOCK_CLASS")`, `usleep (block_msec * 1000)` | 테스트 환경 설정이 운영 환경으로 옮겨오면 특정 테이블 복제가 1분씩 멈춘다. 원인은 로그에만 남는다 | 확정 | 신규 |
| E9 | Low | `log_manager.c:7466-7471` | `log_dump_record`에 새 타입 분기가 없다. 덤프 도구가 commit마다 "Unknown record type = 53"을 출력한다 | `default: fprintf (… "Unknown record type" …); LSA_SET_NULL (log_lsa);` | 로그를 분석하는 운영자가 손상으로 오인한다. 다음 레코드로는 forw_lsa로 계속 진행한다 | 확정 | 신규 |

### 3.2 모듈화

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| M1 | Medium | `log_applier.c`(11,131행), `log_applier.c:7321-7330`, `applier/log_applier_gate.cpp:56-64`, `applier/log_applier_pending.cpp:47-48` | coordinator 상태가 파일 static 전역으로 흩어져 있다(label holder, gate frontier·ring, pending, drain 타이머). 판단 로직도 거대한 `log_applier.c` 안에 남아 있다 | `static int la_wset_label_trid`, `static LOG_LSA la_Gate_frontier`, `static LA_PENDING_NODE *la_Pending_head` | E1·E5 같은 경계 조건(라벨이 ring에 없는 LSA인 경우, 라벨 읽기 실패)은 상태를 주입할 수 없어서 단위 테스트로 재현하기 어렵다. 실제로 gate 테스트에는 이 경우가 없다 | 확정 | 신규 |
| M2 | Low | `locator_sr.c:7029-7041`, `8085-8093`, `8862-8870`, `replication.c:668-704`, `log_manager.c:5615-5623` | develop의 기존 결함 수정 4건이 기능 커밋 안에 섞여 있다. 잠금 실패를 성공으로 반환하던 문제, null LSA update 레코드, retain_lock에서 MVCCID self-lock이 남는 문제, repl_force 교착 victim 처리다 | 주석: "Pre-existing defect fixed here" | 기능 브랜치가 보류되면 이 수정들도 함께 빠진다. 수정이 별도 이슈가 아니어서 백포트·회귀 추적 단위가 없다 | 확정 | 기존 결함 수정 |

### 3.3 아키텍처

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| A1 | High | `applier/log_applier_gate.cpp:22-27`, `log_applier.c:7606-7611` | slave 읽기의 일관성 의미가 바뀐다. develop은 commit 순서를 지키므로 slave가 항상 master의 어떤 과거 시점과 같았다. 이제는 충돌 순서만 지키므로 slave에서 master에 한 번도 없던 상태를 읽을 수 있다. 이 차이를 고르는 옵션이나 문서가 없다 | "Only conflict order is enforced … converges on the master without keeping commit order" | 앱이 주문 T1을 commit한 뒤 FK 없는 감사 테이블에 T2를 기록한다. standby에서 읽기 전용 브로커(RO/SO)로 조회하면 감사 행은 보이는데 주문은 없는 순간이 생긴다. replica 지연 옵션도 TODO로 남아 있다 | 설계상 확정 | 신규 |
| A2 | High | `log_manager.c:4038-4074`, `writeset.cpp:1466-1487`, `serial.c:1216-1251` | AUTO_INCREMENT·serial NEXT_VALUE·INCR/DECR로 생기는 sysop마다 history_start를 끌어올리는 commit-order 장벽이 생긴다. 이때 master는 history rwlock을 배타적으로 잡는다. slave에서는 그 sysop 이전 commit이 모두 끝나야 다음 트랜잭션이 진행된다 | `wset_raise_history_start (&sysop_lsa, "SYSOP_COMMIT_ORDER")` → `pthread_rwlock_wrlock (&wset_History.history_lock)` | AUTO_INCREMENT PK에 단건 INSERT를 하는 일반적인 OLTP 스키마에서는 트랜잭션마다 sysop과 commit이 가깝다. slave 병렬도가 사실상 1로 떨어지고, master에서는 모든 committer의 probe·publish가 serial 사용 때마다 배타 락에 막힌다 | 메커니즘 확정 / 처리량 영향 추정(측정 안 함, serial cache 설정에 따라 다름) | 신규 |
| A3 | High | `CMakeLists.txt:607`, `cs/CMakeLists.txt:473-481`, `log_applier.c:8496-8498`, `writeset.cpp:592` | `MULTI_CONN_TO_A_SERVER`를 전역 `add_definitions`로 켰다. 그래서 applylogdb만이 아니라 libcubridcs를 쓰는 모든 클라이언트(CAS, csql, 유틸리티)가 multi-connection 코드 경로로 빌드된다. 워커 1개(기본값)도 새 coordinator·worker 구조를 타므로 develop applier로 돌아갈 스위치가 없다. master의 writeset 수집도 HA에서는 끌 수 없다 | `add_definitions(-DMULTI_CONN_TO_A_SERVER)`, `PRM_ID_HA_APPLY_WORKER_COUNT` 최소값 1, `wset_add_write_key`는 overflow·suppress만 검사 | 운영에서 병렬 applier 문제가 생기면 파라미터로 이전 동작을 복구할 방법이 없다. 브로커 같은 일반 클라이언트도 새 TLS 파라미터 조회와 area lock 경로를 탄다(내부 영향은 범위 밖이라 분석하지 않음) | 전역 적용 확정 / 클라이언트 영향 추정 | 신규 |
| A4 | Medium | `writeset.cpp:667-681`, `locator_sr.c:7709-7723`, `7791-7808`, `error_code.h:1789` | 복제 메타데이터(키 해시)를 만들지 못하면 사용자 DML을 실패시킨다(`-1386`). commit-order fallback이라는 안전한 대안이 있는데도 앱에 새 에러를 노출한다 | `er_set (... ER_HA_WRITESET_KEY_BUILD_FAILED ...)` → `goto error` | 알 수 없는 collation, 부모 PK 도메인을 읽지 못하는 경우, 캐스팅 실패 같은 내부 사정으로 업무 INSERT/UPDATE가 HA에서만 실패한다. 앱은 처음 보는 에러 코드라 재시도 정책을 세울 수 없다 | 확정 | 신규 |
| A5 | Medium | `locator_sr.c:13303-13346`, `13194-13206`, `btree.c` `btree_is_deleter_committing`, `writeset.cpp:1026-1030`, `1173` | HA master의 모든 X-lock fetch에 추가 비용이 붙는다. INSID가 아직 vacuum되지 않은 행에 대해 다른 트랜잭션 MVCCID에 조건부 lock 요청과 해제를 한 번 더 한다. commit 경로에는 전역 `seq_lock`이 2회 들어간다 | `lock_transaction_mvccid (…, S_LOCK, LK_COND_LOCK)`, `pthread_mutex_lock (&wset_History.seq_lock)` | 잔고·카운터처럼 같은 행을 반복 UPDATE하는 핫 로우 워크로드에서는 vacuum이 INSID를 비우지 못하므로 매 UPDATE마다 lock 관리자를 한 번 더 왕복한다. 커밋 동시성이 높으면 전역 mutex 경합이 생긴다 | 경로 확정 / 성능 영향 추정 | 신규 |

### 3.4 리팩토링

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| R1 | Low | `serial.c:1224-1251` | serial 키를 수집하지만 같은 sysop의 SYSOP_END에서 항상 버린다(`wset_discard_sysop_keys`). btid NULL 분기는 부팅 때 캐시가 채워지므로 사실상 실행되지 않는다. 주석의 "Collect … as this system operation's WRITE"는 실제 동작과 다르다 | `if (lock_mode != X_LOCK)` 블록 안에서만 실행됨, `log_manager.c:4072` discard | 코드를 읽는 사람이 serial 순서가 키로 보장된다고 오해한다. sysop마다 해시 계산과 malloc이 낭비된다 | 확정 | 신규 |
| R2 | Low | `locator_sr.c:8751-8766`, `writeset.cpp:637-657` | UPDATE에서 old/new 키가 같아도 해시 2개를 넣는다. 키마다 malloc/free를 한다 | `wset_add_write_key(…old_key)`, `wset_add_write_key(…new_key)`, `malloc (buf_len)` | PK만 있는 테이블에서 50만 행을 넘게 UPDATE하면 키가 100만 개를 넘어 overflow가 나고, 전체 history clear와 slave 장벽으로 이어진다. 중복을 제거하면 이 임계가 2배로 늘어난다 | 확정 | 신규 |
| R3 | Low | `log_applier.c:872`, `1249`, `1259`, `7505`, `7638`, `7764` | coordinator 동작을 "reader"라는 이름으로 남긴 trace·debug 문자열이 다수 있다. `ws_gate`·`ws_repl` 같은 접두사도 workspace(ws_) 명명과 겹친다 | `"[WSET] reader schedule …"`, `"reader defer_sysop_end …"` | 운영 로그 grep과 문서가 용어와 맞지 않는다 | 확정 | 신규 |
| R4 | Low | `writeset.cpp:76,465` ↔ `log_manager.c:4076-4077`, `serial.c:1240` | trace level을 어떤 곳은 캐시해 읽고 어떤 곳은 `prm_get_integer_value`로 매번 읽는다 | `wset_Trace_level` vs `prm_get_integer_value (PRM_ID_HA_WRITESET_TRACE_LEVEL)` | 같은 레벨인데 출력 여부가 엇갈릴 수 있다(동적 변경을 지원하게 되면 드러남). 판단 함수를 `wset_trace_enabled` 하나로 통일하는 것이 좋다 | 확정 | 신규 |

### 3.5 항목별 상세

**E1 — master 재시작 라벨이 slave에서 영구 대기로 이어질 수 있음 (Critical)**

- master 쪽 동작.
  - `log_initialize_internal`은 recovery 직후 `history_start`를 `log_Gl.hdr.append_lsa`(A)로 올린다.
  - `wset_find_dependency_in_range`는 `wset_parent`를 `history_start`(A)에서 시작한다. 재시작 직후에는 history map이 비어 있으므로 모든 probe가 MISS다.
  - `prev_commit_lsa`는 재시작 직후 NULL이므로 `LSA_ISNULL (&prev_commit_snapshot)` 분기를 타서 결과가 A가 된다. 이후 commit들도 `min(A, prev_commit)` 다음 floor 처리를 거쳐 A가 된다.
  - A는 END_OF_LOG 자리이므로 어떤 commit의 LSA도 아니다.
- slave 쪽 동작.
  - `la_gate_is_satisfied`는 `dep <= frontier`일 때만 통과시킨다.
  - frontier는 `la_gate_advance_frontier`에서 ring 원소(읽어 들인 commit과 라벨 붙은 SYSOP_END)의 LSA 값으로만 이동한다.
  - 재시작 전 commit은 모두 A보다 작고, 재시작 뒤 commit은 모두 A보다 크다. 따라서 frontier가 A 이상이 되려면 A보다 뒤에 있으면서 라벨이 없거나 의존성이 NULL인 commit이 완료돼야 한다.
- 통상 HA에서는 master 측 applylogdb가 `_db_ha_apply_info`를 갱신하는 commit(LOG_CHECK_LOG_APPLIER라서 라벨 없음)이 우연히 이 역할을 한다.
- 이 우연이 보장되지 않는 상황이 있다. slave가 내려간 동안 master만 재시작하고 쓰기 부하가 이어진 경우다.
  - master 측 applylogdb는 slave 로그가 없으므로 그 commit을 늦게 남긴다.
  - 재시작 뒤 commit이 `worker_count×1024`개를 넘으면 `la_coordinator_wait_for_commit_order_slot`이 무한 대기한다.
  - 이 함수의 주석("That commit always passes the gate, since every commit before it is applied")이 전제하는 조건이 여기서 깨진다.
- 영향은 다음과 같다.
  - 워커가 1개면 gate를 건너뛰므로 문제가 없고, 2개 이상일 때만 발생한다.
  - applier를 재시작해도 같은 결과가 반복된다.
  - 이 상태에서 master가 죽으면 `la_change_state`가 DONE을 보류하고, 30초 drain timeout 뒤 재시작을 반복한다.
- 수정 제안은 셋 중 하나다.
  - (a) 재시작 시 system trid로 경계 레코드를 기록하고, slave가 그 레코드를 `la_coordinator_complete_without_task`로 ring에 넣게 한다.
  - (b) gate가 "ring이 비어 있고 coordinator가 dep 이후까지 읽었으면 통과"로 판단하게 한다.
  - (c) master 재시작 라벨을 commit LSA가 아닌 별도 의미로 표시한다.
- 회귀 테스트로 gate 단위 테스트에 "ring 사이 LSA를 가리키는 라벨" 케이스를 추가해야 한다.

**E2 — 파티션 부모 FK의 REF가 부모 WRITE와 만나지 않음 (High)**

- `locator_insert_force`는 pruning을 거친 뒤 `real_class_oid`(파티션)로 `locator_add_or_remove_index`를 호출한다. 그래서 부모 PK의 WRITE 해시는 (파티션 OID, 파티션 PK vfid)로 만들어진다.
- 반면 `locator_wset_collect_fk_ref`는 `index->fk->ref_class_oid`와 `ref_class_pk_btid`(루트)를 쓴다.
- 실제 FK 검사(`locator_check_foreign_key`, 4120-4139행)는 `partition_prune_unique_btid`로 파티션 btid를 다시 찾는다. 즉 기존 코드도 루트 값과 파티션 값이 다르다는 사실을 알고 처리하고 있다.
- applier는 RESTRICT를 건너뛰지만(4248행) CASCADE·SET NULL은 그대로 실행한다(4266행 이후). 그래서 표의 시나리오처럼 slave에서 순서가 뒤바뀌면 cascade가 master에는 없는 삭제를 만든다.
- 비파티션 부모에서는 REF와 WRITE가 같은 (클래스, vfid)로 만들어지므로 문제가 없다.
- writeset 단위 테스트에는 partition 케이스가 없다(grep 0건).
- 수정 방향은 둘 중 하나다.
  - REF를 만들 때 부모가 파티션이면 키로 pruning해서 파티션 OID·btid를 쓴다.
  - 또는 파티션 부모를 참조하는 FK에서는 commit-order fallback을 쓴다.

**E3 — 레코드 타입 53과 구버전 applylogdb의 비호환 (High)**

- develop의 `LOG_LARGER_LOGREC_TYPE`는 53이고, develop applier는 `lrec->type >= LOG_LARGER_LOGREC_TYPE`이면 `ER_LOG_PAGE_CORRUPTED`를 반환한다.
- 새 master는 HA에서 복제 commit마다 라벨을 기록한다(`log_append_repl_info_and_commit_log`). 이 기록을 끄는 조건은 없다.
- 결과적으로 "master 먼저 업그레이드" 순서의 롤링 업그레이드, 또는 구버전 slave와 혼용하는 구성에서 복제가 즉시 멈춘다.
- 반대 방향(새 slave, 구 master)은 라벨이 없을 때 직전 commit을 기다리는 경로가 있어서 안전하다(`la_coordinator_set_commit_dependency`).
- 제안은 다음과 같다.
  - 버전 호환 정책을 명시한다.
  - 라벨 기록을 HA 파라미터로 켜고 끌 수 있게 하거나, slave 버전과 협상하게 한다.
  - CDC·flashback·logdump처럼 로그를 읽는 다른 도구가 새 타입을 어떻게 처리하는지 점검 목록에 넣는다.

**E4 — `_db_ha_apply_info` 스키마 변경에 마이그레이션이 없음 (High)**

- 새 DB는 install 단계에서 컬럼이 생기지만, 기존 DB에는 컬럼이 없다.
- `la_get_ha_apply_max_committed_lsa`는 시작 경로(`la_get_ha_apply_info` → 3349행)에서 반드시 실행되고, 실패하면 오류를 반환한다.
- `util_sa.c`의 apply_info INSERT는 새 컬럼을 쓰지 않으므로 NULL이 들어가고, 이 경우는 정상 동작한다. 컬럼 자체가 없는 경우만 문제다.
- 코드 TODO도 "final_lsa로 대체해 카탈로그 변경을 없앨 수 있다"고 적고 있다. 업그레이드 경로를 생각하면 이 대안이 우선이다.

**E5 — 라벨을 읽지 못하면 '의존성 없음'으로 처리됨 (Medium)**

- `la_get_wset_label`이 실패하면 dep는 NULL로 남는다. 그런데 `la_wset_label_trid = lrec->trid`는 그대로 설정되므로 `has_label=true`가 되어, `task->has_items && !has_label` 보수 분기를 타지 않는다.
- 실패한 경우에는 holder를 비우거나, 의존성을 ring tail로 두거나, 오류로 종료해야 한다. 안전한 쪽(대기)으로 기울여야 한다.

**E6 — tdes별 writeset 벡터의 용량이 유지됨 (Medium)**

- overflow 경로는 `std::vector<LOG_WSET_ENTRY> ().swap (...)`로 메모리를 반환한다. 그러나 정상 commit 뒤 `logtb_clear_tdes`는 `clear()`만 하므로 최대 history_size−1개 항목의 용량이 tdes에 남는다.
- 일정 크기(예: 4K 항목)를 넘으면 `shrink_to_fit` 또는 swap으로 정리하는 것이 좋다.

**A1 — standby 읽기 일관성 의미의 변화 (High)**

- 이 설계의 핵심 가정은 "독립 트랜잭션은 순서를 바꿔도 결과로 수렴한다"이다. 최종 상태 기준으로는 맞다.
- 하지만 CUBRID HA는 standby를 읽기 부하 분산에 쓰는 사례가 흔하다. 이런 사용자에게 "slave는 master의 어떤 commit 시점과 같은 상태"라는 기존 보장이 사라진다.
- 앱 수준의 인과 관계(FK가 없는 순차 쓰기)는 writeset으로 잡을 수 없다.
- 최소한 다음 셋 중 하나가 필요하다.
  - 릴리스 노트와 매뉴얼에 명시한다.
  - 기본 워커 1개를 유지하는 이유로 문서화한다.
  - 읽기 일관성이 필요한 사이트를 위해 commit-order 모드(워커 여러 개 + commit 순서 retire 후 가시화)를 선택지로 둔다.

**A2 — serial·AUTO_INCREMENT 장벽 (High)**

- `log_sysop_commit_internal`은 `repl_item_count > 0`인 SYSOP_END_COMMIT을 모두 commit-order로 라벨링하고 `wset_raise_history_start`를 호출한다. 여기에 해당하는 것이 serial 갱신, INCR/DECR, checksumdb다.
- 이후 모든 트랜잭션의 라벨이 그 sysop LSA 이상으로 올라간다.
- AUTO_INCREMENT가 cache 없이 매번 serial을 갱신한다면, 각 INSERT 트랜잭션은 자기 serial sysop 이전 commit이 전부 끝나야 적용된다. 그 결과 slave 병렬도가 거의 사라진다.
- 같은 함수의 TODO가 이 한계를 인정하고 있다.
- 앱 개발자에게 가장 흔한 스키마에서 이 기능의 효과가 사라질 수 있으므로, 대표 워크로드(AUTO_INCREMENT PK)로 측정하고 결과를 문서에 남겨야 한다.
- master 쪽에서도 serial 사용마다 history 배타 락이 잡히므로 committer 지연을 함께 측정해야 한다.

**A3 — 전역 컴파일 플래그와 되돌릴 경로 부재 (High)**

- 커밋 메시지에 따르면 플래그를 끄면 applier 워커가 같은 소켓을 공유해 멈춘다. 그래서 켜는 것 자체는 필요하다.
- 문제는 범위다. 전체 빌드에 적용되므로 CAS·csql 등 모든 CS 바이너리의 동작이 바뀐다.
- `ha_apply_worker_count=1`도 새 coordinator와 `db_restart_sub` 워커를 쓰므로 develop의 검증된 단일 연결 applier로 돌아갈 수 없다.
- 장애 대응을 고려하면 다음을 검토해야 한다.
  - 기존 경로를 런타임 스위치로 남긴다.
  - 플래그를 applylogdb가 쓰는 타깃에만 적용하도록 범위를 줄인다.

**A4 — 키 생성 실패 시 DML 실패 정책 (Medium)**

- `wset_fallback_to_commit_order`라는 안전한 경로가 이미 있다. 그런데 `wset_error`·`locator_wset_error`는 DML 오류로 반환한다. `log_impl.h`의 주석도 "Technical key collection failures are returned to the DML path"라고 명시한다.
- 데이터 정합성은 fallback으로도 지킬 수 있으므로, OOM 이외의 경우에는 fallback과 경고 로그로 처리하는 편이 앱 호환성 면에서 낫다.

**A5 — HA master의 경로별 추가 비용 (Medium)**

- `locator_is_inserter_committing`는 `log_does_allow_replication()`이고 INSID가 유효하며 활성이 아닌 트랜잭션이면 true다. 이 경우 `lock_transaction_mvccid(COND)`와 unlock 비용이 생긴다.
- UPDATE한 행도 INSID를 가지므로 핫 로우에서 매번 비용이 발생한다.
- 그런데 UPDATE끼리의 순서는 이미 row X-lock(commit 기록 뒤 해제)이 보장한다. 따라서 이 대기가 필요한 것은 "행 X-lock 없이 삽입된 행"뿐이다.
- 대상을 좁히는 방법을 검토할 만하다. 예를 들어 해당 MVCCID의 self-lock 자원이 존재하는지 먼저 저비용으로 확인할 수 있다.

## 4. 미검증 의심 (근거 부족)

1. **sub-MVCCID의 self-lock 범위.** `btree_is_deleter_committing`와 `locator_is_inserter_committing`는 레코드의 DELID/INSID로 lock을 요청한다. 이 값이 sysop의 sub-MVCCID라면, sub-MVCCID는 sub 종료 시점에 self-lock을 풀기 때문에(`log_tran_table.c:4952`) 대기가 바로 통과한다. 그런데 main MVCCID는 아직 commit 창 안에 있을 수 있다. 이 경로에서 순서 역전이 생기는지 확인하지 못했다.
2. **best-effort self-lock.** `logtb_self_lock_assigned_mvccid`는 이름대로 best-effort다(boot/recovery·system 트랜잭션은 건너뜀). self-lock이 없는 INSID를 만나면 조건부 lock이 즉시 GRANTED되어 대기 없이 통과한다. 사용자 트랜잭션에도 이런 경우가 있는지 확인하지 못했다.
3. **slave max_clients 소비.** 워커마다 `db_restart_sub`로 별도 서버 연결을 연다. 이 연결이 slave의 `max_clients`를 소비해서, standby 읽기용 앱 연결이 거부될 수 있는지 확인하지 못했다(최대 32+1 연결 × 피어 수).
4. **DDL 이후 다른 워커의 스키마 캐시.** 복제된 DDL은 한 워커가 적용하고 다른 워커는 각자 sub-client로 동작한다. 이후 DML이 이전 클래스 표현을 쓸 위험이 있는지 확인하지 못했다. workspace를 공유하는지는 CS 내부라서 범위 밖이다.
5. **재시작 시 serial fragment 재적용으로 값이 되돌아갈 가능성.** SYSOP_END ≤ committed_lsa < outer commit인 상태에서 재시작하면, fragment를 분리하지 않아(`la_coordinator_process_sysop_end`의 else 분기) serial 항목이 outer commit과 함께 재적용될 수 있다. 그러면 db_serial 값이 과거 값으로 되돌아갈 가능성이 있다. develop의 `LOG_SYSOP_END` 처리도 구조가 같아서 기존 문제일 수 있다.
6. **applyinfo 지연 표시.** `la_Info.log_record_time`이 retire 순서(dispatch 순서)로 덮어써진다. 그래서 `cubrid applyinfo`의 지연 표시가 단조롭지 않게 움직일 수 있다.
7. **recovery range의 오류 무시.** recovery range에서는 INSERT unique 중복을 `recovery_skipped_counter`로만 센다. slave에만 있는 발산 행 때문에 생긴 진짜 충돌도 같은 방식으로 조용히 넘어갈 수 있다. 범위가 짧아서 실제 영향은 작다고 추정한다.

## 5. 총평

writeset 수집, 라벨, gate, frontier로 이어지는 핵심 아이디어는 일관된다. 주석의 밀도와 재시작·drain·required_lsa 처리에서 보이는 신중함도 높다. develop의 기존 결함(잠금 실패를 성공으로 반환하던 문제 등)을 찾아 고친 점도 앱 입장에서 분명히 이득이다.

다만 애플리케이션과 운영 관점에서는 현재 상태로 병합하기에 위험이 크다.

1. **정합성·가용성 (E1, E2, E5).** 재시작과 파티션처럼 정상 경로 밖의 상황에서 slave가 영구 정지하거나 조용히 발산하는 경로가 코드로 확인된다. 특히 E1은 failover DONE까지 막을 수 있다. 병합 전에 재현 테스트로 확정하고 고쳐야 한다.
2. **호환성 (E3, E4).** 레코드 타입 53과 카탈로그 컬럼 추가는 업그레이드·혼용 시 복제를 바로 멈추게 한다. 업그레이드 정책과 마이그레이션이 같이 들어오지 않으면 배포할 수 없다.
3. **의미와 성능에 대한 약속 (A1, A2).** standby 읽기 일관성이 약해진다. 또 가장 흔한 AUTO_INCREMENT 스키마에서는 병렬화 효과가 거의 사라질 수 있다. 이 두 가지는 사용자 문서와 측정으로 먼저 정리해야 한다.
4. **되돌릴 경로 (A3).** 전역 컴파일 플래그와 새 applier가 기본값까지 대체하므로, 문제가 생겼을 때 운영자가 파라미터로 develop 동작에 돌아갈 방법이 없다.

판정은 NEEDS_FIX다. 우선순위는 E1 → E2 → E3/E4 → A3(되돌릴 경로) → A1/A2(문서와 측정) 순으로 제안한다.
