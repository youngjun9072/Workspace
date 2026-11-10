# 마스터 의존성 계산 TLA+ 검사 진행 기록

대상: PR #8052 브랜치 `origin/feature/CBRD-27508-parallel-applylogdb-writeset` (HEAD 6bd39a696). 코드는 `git show`로만 읽었다. 행번호는 그 브랜치 기준이다.

## 1. 의존성·히스토리에 영향을 주는 마스터 동작 목록

키 수집

- 행 삽입·삭제 때 PK/UNIQUE 키를 WRITE로 수집한다: locator_sr.c:8309-8343 (`collect_wset` 조건은 8261). FK 인덱스는 REF로 수집한다: locator_sr.c:8344-8350 → `locator_wset_collect_fk_ref` (8040-8111).
- 행 갱신 때 PK/UNIQUE는 옛 키와 새 키를 모두 WRITE로, FK는 옛 값과 새 값을 모두 REF로 수집한다: locator_sr.c:9031-9070. PK 인덱스를 건너뛴 제자리 갱신(db_serial 같은 MVCC 비대상 클래스)은 9321-9334에서 옛 키를 WRITE로 수집한다.
- serial 갱신은 serial.c:1302-1325에서 serial 행 키를 WRITE로 수집한다. 캐시된 인덱스가 없으면 commit-order 폴백이다.
- 수집 함수 자체: `wset_add_write_key` writeset.cpp:208, `wset_add_ref_key` writeset.cpp:419. 둘 다 `wset_overflow`이거나 `suppress_replication`이면 아무것도 하지 않는다. NaN 키는 commit-order 폴백(232, 480).
- 트랜잭션당 키 한도: `wset_append_entry` writeset.cpp:150-155. 한도에 닿으면 `wset_switch_to_commit_order`(LIMIT).

commit-order 폴백

- `wset_switch_to_commit_order` writeset.cpp:176-192: `wset_overflow = true`, 모은 키를 모두 버린다. 한 번 서면 트랜잭션 끝까지 유지된다.
- 문장 복제: replication.c:610 (`repl_log_insert_statement`, `suppress_replication`이면 건너뜀).

키 버리기

- 라벨이 붙은 SYSOP_END에서 그 연산 안에서 모은 키를 버린다: log_manager.c:4093 → writeset.cpp:507 `wset_discard_sysop_keys`. 기준점은 연산 시작 때 저장한 `wset_mark`(log_manager.c:3761).
- 연산 중단(문장 롤백, 저장점 롤백): log_manager.c:4276 → writeset.cpp:532 `wset_discard_keys_after_lsa`. 키마다 수집 시점의 `tail_lsa`를 들고 있어(writeset.cpp:159) 부모 LSA보다 뒤인 키만 지운다.
- 트랜잭션 종료 때 tdes 초기화: log_tran_table.c:1624-1627, 1709-1712.

커밋 경로 (1PC, log_manager.c `log_commit_local` 5578-5685)

1. `logtb_complete_mvcc` 5596: 다른 트랜잭션의 스냅샷에 커밋으로 보이기 시작한다.
2. `log_append_repl_info_and_commit_log` 5030-5054, prior_lsa_mutex 안에서 차례로: 복제 레코드 → `wset_order_find_dependency` (5048) → 라벨 기록 (5049) → commit 레코드 (5050) → `wset_order_record_commit` (5051).
3. `wset_order_publish_commit_keys` 5640: mutex 밖, 락 해제 전.
4. `lock_unlock_all` 5649 (retain_lock이면 생략).

2PC 완료 경로 `log_complete_for_2pc`: 6410(라벨·commit) → 6413(발행) → 6433(락 해제). 순서는 1PC와 같다.

의존성 계산 (writeset_order.cpp)

- `wset_order_find_dependency` 128-142: overflow면 `wset_history_get_commit_order_dependency`(writeset_history.cpp:130-142, max(prev_commit, history_start)). 아니면 `wset_order_find_dependency_in_range` 43-125.
- in_range: seq_lock 아래 prev_commit 복사, history_lock 읽기잠금 아래 history_start 복사(writeset_history.cpp:104-114). dependency 시작값 = history_start. 키마다 probe(writeset_history_map.cpp:48-66): REF는 write_seq, WRITE는 max(write_seq, ref_seq)이고 ref_seq가 더 크면 "REF_SLOT". 후보가 현재값보다 크면 갱신. 마지막으로 갱신한 후보가 REF_SLOT이면 그대로 반환(94-103). 아니면 min(dependency, prev_commit)을 한 뒤 history_start 아래로 내려가지 않게 올린다(105-118).

히스토리 갱신 (writeset_history.cpp)

- `wset_history_record_commit` 146-162 (mutex 안): prev_commit = commit_lsa. overflow 커밋이면 history_start도 commit_lsa로 올린다.
- `wset_history_publish_keys` 323-342 (mutex 밖): overflow면 `wset_history_clear_for_commit_order` 233-249 (맵 비우고 history_start = max(history_start, 그 순간의 prev_commit)). 아니면 `wset_history_publish_with_capacity` 252-320: 읽기잠금 아래 용량 예약 후 발행, 실패하면 쓰기잠금 아래 용량 초과면 비우고(floor = prev_commit) 발행, 메모리 부족이면 비우기만 한다.
- 맵 발행 `wset_history_map::publish` 69-98: WRITE면 write_seq, REF면 ref_seq를 더 큰 값으로만 갱신.

floor(history_start) 올리기

- 라벨이 붙은 SYSOP_END: log_manager.c:4052-4077 조건, `log_append_wset_label_and_sysop_end` 4905-4916 (mutex 안에서 commit-order 의존성 → 라벨 → SYSOP_END → `wset_order_advance_barrier`). prev_commit은 바꾸지 않는다.
- 재시작: log_manager.c:1515-1519, history_start = 재시작 시점 append_lsa.
- overflow 커밋: 위 record_commit과 clear.

## 2. 모델 (MasterDependency.tla)

LSA는 로그 색인(1, 2, ...)으로, NULL은 0으로 둔다. 로그 항목은 커밋("C")과 라벨이 붙은 SYSOP_END("S") 두 가지이고, 둘 다 slave 태스크가 된다. slave 규칙은 WritesetApply.tla와 같다(의존 색인 이하가 모두 반영된 뒤 시작).

모델에 넣은 동작과 대응 코드는 다음과 같다.

- Access(t, k, kind): 행 변경(W, X 락) 또는 FK 참조(R, S 락). 락은 소유자가 lock_unlock_all을 할 때까지 유지된다고 본다. CBRD-26942/27034 이후 삽입 행은 행 락 대신 MVCCID 자기 락으로 기다리게 하지만, 기다림이 끝나는 시점은 똑같이 lock_unlock_all(log_manager.c:5649)이므로 같은 추상화로 둔다. overflow면 키를 모으지 않는다(writeset.cpp:219, 434).
- Overflow(t): 키 한도·NaN 폴백(writeset.cpp:150-155, 232, 480 → 176).
- Statement(t): 문장 복제 폴백(replication.c:610). 문장은 slave에서 다시 실행되므로 앞뒤 모든 항목과 순서를 지켜야 한다고 본다.
- Savepoint / RollbackToSavepoint: 저장점 롤백은 그 뒤의 변경과 키를 함께 지우고 락은 유지한다(log_manager.c:4275-4276). overflow는 내려가지 않는다.
- SerialSysop(t, s): serial 갱신 시스템 연산. 락을 잡고 놓는 것까지 한 동작이다. 라벨 의존성 = max(prev_commit, history_start)(writeset_history.cpp:130-142), 그 뒤 history_start를 SYSOP_END로 올린다(log_manager.c:4910-4913). serial 키는 버린다(4093).
- Abort(t): 락 해제, 아무것도 발행하지 않는다.
- CompleteMvcc(t): log_manager.c:5596. 현재 코드에서는 다른 쓰기를 풀어 주지 않는다(위 락 설명).
- CommitRecord(t): prior_lsa_mutex 안의 한 덩어리(5041-5053). 의존성은 코드 그대로 계산한다. history_start에서 시작해 키마다 probe(REF는 write_seq, WRITE는 max(write_seq, ref_seq)), REF 슬롯이 최대값을 냈으면 그대로, 아니면 min(·, prev_commit) 뒤 history_start로 바닥을 올린다. 키 순회 순서에 따라 REF 플래그가 달라질 수 있어 최대값을 낸 후보 중 아무것이나 고르게 했다. prev_commit 갱신, overflow면 history_start도 올린다.
- Publish(t): overflow면 맵을 비우고 history_start = max(history_start, prev_commit). 아니면 용량 초과 시 비운 뒤 발행, 메모리 부족(AllowOOM) 시 비우기만 한다(writeset_history.cpp:252-342).
- Unlock(t): lock_unlock_all.
- Restart: 진행 중 트랜잭션은 롤백, 맵과 prev_commit은 비고 history_start = 로그 끝(log_manager.c:1515-1519).

불변식

- DepCover: 앞선 항목 i와 뒤 항목 j가 충돌하면(같은 키에 한쪽이라도 W, 또는 한쪽이 문장 복제) j의 의존 색인 >= i. 의존 계산만으로 판단하는 정적 성질이고, slave 규칙이 접두사 대기라서 이것이 성립하면 ConflictOrder도 성립한다.
- DepBelowSelf: 라벨 의존 색인 < 자기 색인(log_manager.c:5638 assert_release와 같은 성질).
- BarrierWaitsAll: 문장 복제가 들어간 항목과 라벨이 붙은 SYSOP_END는 바로 앞 항목까지 모두 기다린다.
- ConflictOrder: slave 반영 순서열에서 충돌하는 두 항목이 마스터 순서대로 반영된다(WritesetApply.tla와 같은 정의, 충돌 정의만 확장).
- SerialOrder: slave가 실제로 순서를 바꿔 반영하는지 보는 sanity, 실패해야 정상이다.

변이(mutant) 플래그: MutVisibleAtMvcc(complete_mvcc 뒤 다른 쓰기가 들어옴, sq_uniq 형태), MutUnlockBeforePublish(발행 전 락 해제), MutNoOverflowFloor(overflow 커밋이 floor를 안 올림), MutNoSysopFloor(라벨 SYSOP_END가 floor를 안 올림), MutNoClearFloor(맵 비울 때 floor를 안 올림).

설정 파일은 MD_<이름>.cfg이고 실행은 `-deadlock`(교착 검사 끔)을 붙였다. 트랜잭션이 서로 락을 기다려 멈추는 상태는 정상 동작이라 오류로 보지 않는다.

## 3. 실행 기록

1. MD_base: 트랜잭션 3, 키 2, REF 허용, 나머지 기능 끔, slave 끔, KeyLimit 10. DepCover·DepBelowSelf·BarrierWaitsAll 통과. 265,657 상태 생성, 162,814 고유 상태, 깊이 25.
2. 변이 sanity (모두 의도대로 실패)
   - MD_mutVis (트랜잭션 2, 키 1, REF): DepCover 위반, 깊이 8. 경로: t2가 k1을 W로 바꾸고 complete_mvcc → t1이 k1을 R로 참조(락이 이미 풀린 것으로 본 변이) → t1 complete_mvcc → t1 커밋 레코드(색인 1) → t2 커밋 레코드(색인 2, k1 미발행이라 의존 0). t1은 t2의 삽입을 보고 참조했는데 로그에서는 t1이 먼저다. 이미 알려진 sq_uniq(CBRD-27034로 해결)와 같은 모양이므로 모델이 그 틈을 잡는다는 확인이다.
   - MD_mutUnl (발행 전 락 해제): DepCover 위반, 깊이 11.
   - MD_mutOvf (문장 복제 + overflow floor 제거): DepCover 위반, 깊이 13.
   - MD_mutSys (serial 1개 + sysop floor 제거): DepCover 위반, 깊이 5. 두 serial 연산이 같은 serial을 바꾸는데 두 번째의 의존이 prev_commit(0)이라 첫 번째를 기다리지 않는다.
   - MD_mutClr (KeyLimit 1, overflow + clear floor 제거): DepCover 위반, 깊이 13.
   - MD_slaveSan (slave 켬, SerialOrder): 위반. slave가 실제로 순서를 바꿔 반영한다.
3. MD_cap3m (트랜잭션 3, 키 2, KeyLimit 1, REF + overflow + OOM): 통과. 4,870,102 상태 생성, 2,403,318 고유 상태, 깊이 28. 용량 초과로 맵을 비우는 경로와 메모리 부족으로 비우기만 하는 경로 모두에서 floor(prev_commit)가 지워진 키를 덮는다.
4. MD_full2s(트랜잭션 2, 키 2, serial 1, 모든 기능, slave 켬)와 MD_full3m(트랜잭션 3, 같은 기능, slave 끔): 16:20 무렵 각각 3천만 고유 상태를 넘긴 채 세션이 끝나 중단됐다. 그때까지 위반은 없었다(완료 아님). 이후 트랜잭션 대칭(SYMMETRY TxnSym)을 넣고 기능 조합을 나눠 다시 돌린다.
5. (트랜잭션 대칭 적용 뒤) MD_stmtOvfSp3: 트랜잭션 3, 키 1, REF + overflow + 문장 복제 + 저장점 롤백 + abort, slave 끔. 통과. 20,746,882 상태 생성, 8,886,855 고유 상태.
6. MD_serRst3: 트랜잭션 3, 키 1, serial 1, 문장 복제 + abort + 재시작, slave 끔. 통과. 367,273 상태 생성, 117,631 고유 상태.
7. MD_allM2: 트랜잭션 2, 키 2, serial 1, KeyLimit 2, 모든 기능(REF, overflow, 문장 복제, 저장점 롤백, abort, OOM 비우기, 재시작) 켬, slave 끔. 통과. 93,148,825 상태 생성, 38,312,840 고유 상태, 깊이 25.
8. MD_capOom3: 트랜잭션 3, 키 2, KeyLimit 1, REF + overflow + OOM, 대칭 적용. 통과. 815,772 상태 생성, 401,332 고유 상태, 깊이 28.
9. MD_slave2: 트랜잭션 2, 키 1, serial 1, KeyLimit 1, 모든 기능 + slave 켬(워커 2), ConflictOrder 포함. 통과. 13,481,524 상태 생성, 4,204,447 고유 상태, 깊이 29.

메모: 16:20 무렵 중단된 MD_full2s/full3m은 위 조합 실행(7~9)으로 대체했다. 이후 실행의 TLC 상태 디렉토리는 /home/youngjun/tools/tlc-meta/master/<이름>에 두고 실행이 끝나면 지운다(/tmp가 RAM 기반이라는 지시).
10. MD_slave3: 트랜잭션 3, 키 1, serial 1, REF + 문장 복제 + abort, slave 켬, ConflictOrder 포함. 통과. 20,644,053 상태 생성, 6,593,615 고유 상태, 깊이 37.
11. MD_refOvfSp3: 트랜잭션 3, 키 2, KeyLimit 2, REF + overflow + 저장점 롤백 + OOM. 900초 제한으로 끝나지 않았다(81,407,493 고유 상태, 깊이 23까지 탐색, 그때까지 위반 없음). 완료가 아니므로 통과로 보지 않는다. 같은 기능을 트랜잭션 2개로 줄인 MD_allM2는 완료·통과했다.

## 4. 코드에서 따로 확인한 경로와 판정

모델이 통과한 이유와, 모델 밖에서 코드로 확인한 후보를 적는다.

- WRITE_BOUND의 min(dependency, prev_commit)(writeset_order.cpp:105-112)은 실제로는 아무것도 바꾸지 않는다. probe는 prior_lsa_mutex 안(log_manager.c:5048)에서 하고, 맵에 들어 있는 LSA는 모두 record_commit(5051)을 이미 마친 커밋의 것이라 prev_commit 이하다. 그래서 REF 슬롯 갈래와 WRITE 갈래의 차이도 결과에 영향이 없다. 모델에서도 REF 플래그를 아무 쪽으로 골라도 위반이 없었다. 판정: 결함 아님.
- 맵 비우기(용량 초과, 메모리 부족, overflow 커밋)는 모두 seq_lock과 쓰기잠금 아래에서 floor를 그 순간의 prev_commit으로 올린다(writeset_history.cpp:189-203, 238-243, 279-310). 맵에 있던 키는 모두 prev_commit 이하이므로 floor가 덮는다. 모델 3·7·8번이 이 경로를 포함한다. 판정: 결함 아님.
- 라벨 SYSOP_END는 prev_commit을 올리지 않고 history_start만 올린다(log_manager.c:4913). 뒤 트랜잭션의 의존 계산은 history_start에서 시작하므로 이 floor 아래로 내려가지 않는다. 판정: 결함 아님.
- complete_mvcc(5596)가 commit 레코드보다 먼저라 그 사이에 다른 쓰기가 끼면 sq_uniq와 같은 역전이 생긴다(변이 MD_mutVis로 재현). 이 브랜치에는 CBRD-27034(ef4e7e812)가 들어 있고, 커밋 메시지에 따르면 `logtb_is_active_other_mvccid`가 자기 락(MVCCID self-lock)을 아직 쥔 소유자를 진행 중으로 보아 삭제·갱신·unique·FK 검사가 lock_unlock_all까지 기다린다. 발행(5640)은 그 전이다. 판정: 결함 아님. 단, heap/btree의 모든 대기 경로를 내가 직접 추적하지는 않았으므로 "기다림이 lock_unlock_all까지 간다"는 전제는 커밋 메시지 기준이다(추정).
- 2PC 완료 경로(log_complete_for_2pc)는 라벨·commit(6410) → 발행(6413) → 락 해제(6433) 순서로 1PC와 같다. 판정: 결함 아님.
- 재시작 뒤 복구된 미결 2PC 트랜잭션은 wset_hashes도 복제 레코드도 메모리에서 사라진 채 커밋된다(log_2pc.c에 repl·wset 복원 없음). 키가 발행되지 않아 뒤 트랜잭션이 이것을 기다리지 않을 수 있지만, 복제 레코드 자체가 없어 slave에 반영할 내용이 없다. develop도 같은 레코드 유실이 있으므로 writeset 고유 결함이 아니라고 본다(추정, 복구 경로 전체는 미추적).
- 문장 복제(USE_SBR) 트랜잭션이 다른 트랜잭션의 complete_mvcc 뒤, commit 레코드 전에 그 변경을 읽고 먼저 커밋하면 slave 재실행 결과가 달라질 수 있다. 그러나 이 경우 로그 순서 자체가 그렇게 나가므로 develop의 순차 반영도 같은 결과다. writeset 결함 아님(추정, HA 문장 복제 공통 제약).
- 키를 모은 뒤 커밋 시점에 log_does_allow_replication()이 거짓이 되면 라벨 없이 commit만 쓰고(5644) record_commit도 하지 않는다. 그런 커밋이 복제 레코드를 갖는 경우가 실제로 생기는지는 확인하지 못했다(추정, 미확인).
- 재시작 floor는 append_lsa라 커밋 LSA가 아니지만, slave의 `la_gate_bound_dependency`(log_applier_gate.cpp:195-220)가 직전 커밋으로 내려 처리한다. 마스터 쪽 결함 아님.

## 5. 기지 결함 재확인 (모델 일관성 확인용)

- 모델에 AllowIncrDml을 추가했다. IncrAttach(t)는 INCR/DECR이 바깥 트랜잭션에 붙어 끝나며 레코드를 NEED_FLUSH로 남기는 동작, IncrDmlSysop(t, k)는 그 다음 일반 DML 시스템 연산이 SYSOP_END에서 남은 레코드를 쓰면서 라벨이 붙고(log_manager.c:4052-4077), 그 연산 안에서 모은 키를 버리는(4093) 동작이다. 행 락은 바깥 커밋까지 유지된다.
- MD_knownIncr (트랜잭션 2, 키 1): DepCover 위반, 깊이 13, 197 고유 상태. 경로: t1 INCR 붙임 → t1이 k1을 DML 연산 안에서 변경, SYSOP_END(색인 1)에 라벨이 붙고 k1 키 버림 → t1 커밋(색인 2, 의존 1, 발행할 키 없음) → t1 락 해제 → t2가 k1 변경 → t2 커밋(색인 3, 의존 = history_start 1). t2는 같은 k1을 바꾼 t1 커밋(2)을 기다리지 않는다. WritesetSysop.tla의 기지 결함(라벨 SYSOP_END 키 유실)과 같은 결함이며 새 발견이 아니다. 이 모델의 의존 계산(floor, prev_commit, REF 슬롯)을 다 넣어도 그대로 드러난다는 확인이다.

## 6. 결론

- 현재 코드(락이 lock_unlock_all까지 쓰기를 막는다는 전제)에서 마스터 의존성 계산의 새 결함은 찾지 못했다. 완료된 조합 실행(1, 3, 5~10)이 모두 DepCover, DepBelowSelf, BarrierWaitsAll, (slave 켠 경우) ConflictOrder를 통과했다.
- 다섯 변이가 모두 의도대로 실패해 각 불변식이 실제로 깨질 수 있음을 확인했다.
- 반례가 나온 것은 변이와 기지 결함(라벨 SYSOP_END 키 유실)뿐이다.
- 전제가 깨지는 곳, 즉 complete_mvcc 뒤 lock_unlock_all 전에 다른 쓰기가 들어오는 경로가 있으면 바로 역전이 난다(MD_mutVis). 이 전제는 CBRD-27034의 자기 락 대기에 기대고 있으며 heap/btree의 대기 경로 전수 확인은 이 작업 범위 밖이다.
