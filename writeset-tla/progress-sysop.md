# sysop 확장 TLA+ 검사 진행 기록

대상: PR #8052 브랜치 `origin/feature/CBRD-27508-parallel-applylogdb-writeset` (HEAD 6bd39a696). 코드는 `git show`로만 읽었다. 행번호는 그 브랜치 기준이다. 이미 알려진 결함 세 가지(라벨 SYSOP_END의 사용자 행 키 유실, 바깥에 합쳐진 INCR이 abort 뒤 slave에 남는 문제(todo "develop - 되돌린 INCR 증가가 slave에 남음" 2번), ABORT로 비운 슬롯의 `last_sysop_fragment_lsa` 미초기화)는 다시 올리지 않는다.

## 1. 코드 목록 (1단계)

### 복제 레코드를 쓰거나 라벨을 붙이는 sysop 경로

- `log_sysop_start` log_manager.c:3758-3762: 연산을 쌓을 때 그 시점 키 개수를 `wset_mark`로, `repl_flushed`를 false로 둔다.
- `log_sysop_commit_internal` log_manager.c:3925-4122. 비어 있지 않은 연산 끝에서, flush 표시가 열려 있지 않으면(`fl_mark_repl_recidx == -1`, 4010-4011) `append_repl_recidx`부터 NEED_FLUSH 항목 수를 세고(4013-4023) `log_append_repl_info(…, false)`로 그 항목을 로그에 쓴다(4030). 쓴 항목이 있거나 이 연산이 가장 안쪽일 때 항목이 로그에 나갔으면(`repl_flushed`) 라벨+SYSOP_END를 원자적으로 쓰고(4052-4077), 그 연산이 모은 키를 `wset_mark`부터 버린다(4087-4094). 종료 형태(COMMIT, LOGICAL_UNDO 등)와 상관없다.
- `log_append_wset_label_and_sysop_end` log_manager.c:4905-4915: prior_lsa_mutex 안에서 `wset_order_find_sysop_dependency`(= max(prev_commit_lsa, history_start), writeset_order.cpp:172-181, writeset_history.cpp:130-141) → 라벨 → SYSOP_END → `wset_order_advance_barrier`(history_start를 SYSOP_END로 올림).
- `log_append_repl_info_internal` log_manager.c:4930-5000: `append_repl_recidx`부터 끝까지 훑으며 커밋이 아니면 NEED_FLUSH만, 커밋이면 DONT_NEED_FLUSH가 아닌 것을 쓴다. 쓴 항목은 DONT_NEED_FLUSH가 되고, 커밋 전이면 가장 안쪽 연산의 `repl_flushed`를 켠다(4994-4998). 커밋이면 인덱스를 0부터 다시 훑는다(4937-4941).
- 항목의 NEED_FLUSH 표시: `repl_log_insert_internal` replication.c:484-507. flush 표시가 열린 동안 만든 항목은 NEED_FLUSH. 단 serial이 아닌 클래스에서 같은 OID의 앞선 COMMIT_NEED_FLUSH 항목이 있으면 COMMIT_NEED_FLUSH로 둔다. 문장 항목은 replication.c:663-670.
- flush 표시 사용처 셋: INCR/DECR `qexec_execute_selupd_list` query_executor.c:20496-20565(instant lock 모드일 때만 표시, 끝나면 instant면 `log_sysop_commit`, 아니면 `log_sysop_attach_to_outer`), serial `serial_update_serial_object` serial.c:1236-1330(행 lock이 X가 아니면 sysop+표시, X면 sysop도 표시도 없이 COMMIT_NEED_FLUSH 항목), checksumdb `xchksum_insert_repl_log_and_demote_table_lock` locator_sr.c:13150-13185(표시 안에서 문장 항목을 만들고 직접 `log_append_repl_info` 후 `log_sysop_commit`).
- 키 수집: serial 행 키 serial.c:1302-1325, 갱신 때 PK/UNIQUE 옛 키·새 키 locator_sr.c:9031-9070(MVCC 클래스는 인덱스를 건너뛰지 않으므로 INCR도 그 행 PK를 모은다, 8866-8889), 삽입·삭제 locator_sr.c:8300-8350.

### 중첩 sysop

- 각 단계가 자기 `wset_mark`와 `repl_flushed`를 가진다(log_impl.h:361-364). 안쪽 연산이 라벨을 받으면 안쪽 mark부터 버리고, 바깥 연산의 `repl_flushed`는 켜지지 않는다.
- flush 표시가 열린 동안 끝나는 안쪽 연산은 항목을 쓰지 않는다(4003-4011, 501e5f315 수정).
- `log_sysop_attach_to_outer` log_manager.c:4311-4345: 항목 쓰기·라벨·키 버리기 없이 단계만 내린다.

### sysop abort / 부분 롤백

- `log_sysop_abort` log_manager.c:4251-4302: 변경이 있으면 `repl_log_abort_after_lsa`(replication.c:757-779, LSA가 부모 LSA보다 뒤인 항목과 LSA 없는 UPDATE 항목을 DONT_NEED_FLUSH로)와 `wset_discard_keys_after_lsa`(writeset.cpp:532-543, 수집 시점 `tail_lsa`가 부모 LSA보다 뒤인 키 삭제) → `log_rollback`(부모 LSA까지) → ABORT 형태 SYSOP_END(라벨 없음).
- `log_rollback`의 SYSOP_END 처리 log_manager.c:8318-8377: COMMIT 형태는 lastparent로 건너뛰어 되돌리지 않는다. LOGICAL_UNDO/MVCC_UNDO는 논리 undo를 실행한다. 따라서 serial·instant INCR처럼 COMMIT으로 끝난 연산은 바깥이 롤백돼도 남는다.
- `log_abort_partial` log_manager.c:5982-6058: sysop을 하나 열고 lastparent를 저장점 LSA로 바꾼 뒤 `log_sysop_abort`.

### slave 쪽

- 레코드는 trid 슬롯에 쌓인다(`la_set_repl_log` log_applier.c:4573-4604, 항목이 많으면 긴 트랜잭션으로 바꿔 머리 항목만 남김).
- `la_coordinator_process_sysop_end` log_applier.c:7323-7432: 라벨이 맞고 슬롯에 항목이 있으면 `la_detach_sysop_fragment`(7245-7311, SYSOP_END 이하 LSA의 항목을 모두 새 슬롯으로 옮김, 긴 트랜잭션이면 슬롯 전체)로 조각 태스크를 만들고 바깥 슬롯의 `last_sysop_fragment_lsa`를 SYSOP_END로 둔다. 항목이 없으면 `la_coordinator_complete_without_task`(log_applier_coordinator.cpp:364-393)로 그 위치만 링에 넣고 완료 처리.
- `la_coordinator_set_commit_dependency` log_applier.c:7440-7462: 커밋 라벨을 `last_sysop_fragment_lsa`까지 올림. 라벨이 없으면 링 꼬리까지.
- 게이트 log_applier_gate.cpp: 링에는 커밋과 라벨 SYSOP_END가 로그 순서로 들어가고, frontier는 완료된 머리만 넘는다(262-283). 디스패치 조건은 dep ≤ frontier(324-333).
- LOG_ABORT log_applier.c:7644-7653: 슬롯의 남은 항목만 버린다(`la_clear_applied_info` 4532-4543). 이미 떼어 낸 조각은 그대로 적용된다.

### 모델 설계 판단 (코드에서 확인한 것)

- 라벨이 붙은 연산의 의존성은 키가 아니라 직전 커밋/라벨 SYSOP_END 전체(커밋 순서 장벽)다. 따라서 조각 자체의 순서는 키와 무관하게 보수적이다. 결함 후보는 (가) 조각에 그 연산이 아닌 항목이 섞이는 경우, (나) 조각이 마스터에서 되돌려지는 변경을 담는 경우, (다) 버린 키의 레코드가 조각이 아니라 커밋에 실리는 경우로 좁혀진다.
- instant INCR이 같은 트랜잭션이 이미 X lock을 쥔 행을 만나면 lock manager가 instant 모드를 끈다(lock_manager.c:3984-3993). 그러면 표시 전에 끝나 COMMIT_NEED_FLUSH 경로로 간다. 그래서 replication.c:490-502의 "같은 OID 앞선 항목" 분기는 INCR에서는 사실상 안 탄다(추정: 재평가 없는 경로에서 scan 단계 lock 순서를 다 보지는 않았다).
- serial X lock 경로는 그 트랜잭션이 serial을 만들거나 바꾼 DDL(문장 복제 → commit-order 폴백)에서만 생긴다.

## 2. 모델 SysopExtended.tla (2단계)

동작과 코드 대응

- `Dml(t, r)`: 사용자 행 변경. COMMIT_NEED_FLUSH 레코드, 키 유지, 행 lock은 트랜잭션 끝까지(locator_sr.c 8300-8350, 9031-9070, replication.c:444).
- `InstantSysop(t, r)`: instant lock INCR(r이 사용자 행) 또는 serial 갱신(r = SerialRow)을 한 번에 기술한다. sysop 시작(mark 저장) → NEED_FLUSH 레코드와 그 행 키 수집 → `log_sysop_commit`에서 `append_repl_recidx` 이후 NEED_FLUSH를 모두 쓰고 라벨(max(prev_commit, floor)) → floor를 SYSOP_END로 → mark 뒤 키 버림. COMMIT 형태라 롤백으로 되돌리지 않는다(8372-8376). lock은 해제. 그 행을 이미 같은 트랜잭션이 쥐고 있으면 instant 모드가 꺼져 Dml과 같아지므로 막아 둔다.
- `LeftoverIncr(t, r)`(플래그 Leftover): 이미 알려진 경로. instant 모드가 중간에 꺼져 attach_to_outer, 레코드는 NEED_FLUSH로 남고 변경은 되돌릴 수 있다(query_executor.c:20545-20565).
- `BeginSysop`, `EndSysopCommit`(논리 undo 형태 컨테이너 끝: NEED_FLUSH가 있으면 라벨·floor·키 버림, 변경은 되돌릴 수 있음), `EndSysopAttach`, `EndSysopAbort`(부모 LSA 뒤 변경 되돌림, 레코드 DROP, 키 삭제; 4270-4300).
- `Commit`: NEED_FLUSH/COMMIT_NEED_FLUSH 모두 쓰고, 라벨 = max(그 키의 history, floor), 키 발행, lock 해제(5030-5054, 5640). `Abort`: 되돌릴 수 있는 변경을 모두 되돌리고 ABORT.
- slave `Read`: rec는 trid 목록에, 라벨 SYSOP_END는 목록이 있으면 조각 태스크(dep=라벨)와 `lastFrag`, 없으면 바로 완료, commit은 dep=max(라벨, lastFrag), abort는 목록 버림. `StartTask`는 dep ≤ frontier, `FinishTask`는 행별 적용 순서에 붙인다.

불변식

- ConflictOrder: 행마다 slave 적용 순서가 master의 살아 있는 변경 순서의 앞부분이다(순서 뒤바뀜도, master가 되돌린 변경 적용도 위반).
- FinalEqual: 모두 끝나면 행마다 slave 순서 = master 순서.
- NoLostKey: 커밋 레코드가 싣는 사용자 행의 키는 그 커밋이 발행한다.
- NoSerialKeyPublished: 커밋이 serial 키를 발행하지 않는다.
- DepBelowSelf: slave 태스크의 의존 위치는 자기 위치보다 앞이다.
- 교착은 TLC 기본 deadlock 검사(끝난 상태만 `Finished`로 제자리).

## 3. 실행 기록

- 기본(SysopExtended.cfg): 트랜잭션 2, 사용자 행 1 + serial 1, 워커 2, 트랜잭션당 동작 3, 중첩 1, abort 허용, Leftover 끔. 17,153,805 distinct 상태, 깊이 39, 3분 17초, 위반·교착 없음.
- 불변식별 sanity 변이(같은 크기). 모두 몇 초 안에 반례가 나와 불변식이 실제로 검사됨을 확인했다.
  - mutFloor(라벨 SYSOP_END가 floor를 올리지 않음): ConflictOrder 위반. 조각 뒤 다른 트랜잭션 커밋이 조각보다 먼저 적용된다.
  - mutFragDep(slave가 조각 의존성을 무시): ConflictOrder 위반.
  - mutKeep(라벨 sysop 키를 버리지 않음): NoSerialKeyPublished 위반.
  - mutAbortDrop(sysop abort가 안의 레코드를 버리지 않음): NoLostKey 위반(키만 지워지고 레코드가 커밋에 실림).
- Leftover 켬(이미 알려진 경로 재현 확인): NoLostKey 위반(43,115 상태, 3초). 반례: 컨테이너 sysop 시작 → LeftoverIncr(r1) → Dml(r1) → 컨테이너 EndSysopCommit이 남은 INCR 레코드 때문에 라벨을 받고 Dml 키를 버림 → 커밋이 r1 레코드를 싣지만 r1 키 미발행. 알려진 결함 1과 같다.
- Leftover 켬, NoLostKey 빼고(SysopExtended_leftover_order.cfg): ConflictOrder 위반(244,875 상태, 4초). 반례: t1 LeftoverIncr(r1) → t1 serial 갱신(InstantSysop(s))의 SYSOP_END가 남은 INCR 레코드를 같이 써서 조각에 실림 → t1 ABORT로 master는 r1 변경을 되돌림 → slave는 조각을 적용해 r1 변경이 남음. 알려진 todo "되돌린 INCR 증가가 slave에 남음" 2번과 같은 경로(실어 나르는 연산이 serial이어도 같음). 새 결함 아님.
- ALTER SERIAL 켬(SysopExtended_ddl.cfg, 문장 복제로 commit-order, serial 행 X lock, 그 lock 아래 NEXT_VALUE는 sysop 없이 커밋 레코드): 37,579,885 distinct, 10분 20초, 위반·교착 없음.
- 큰 크기 세 가지(대칭 없이, /tmp metadir, 900초 시간 제한으로 중단): 중첩 2·동작 4(73,427,066 distinct까지), 사용자 행 2(55,655,138), 트랜잭션 3·동작 2(75,396,327). 중단 시점까지 위반 없음. 완주가 아니므로 결론에 쓰지 않는다. 대칭(Perms)을 넣고 크기를 줄여 다시 돌린다.
- 모델에 대칭 `Perms == Permutations(Txns)`를 추가(EXTENDS TLC). 이후 큰 크기 실행은 metadir를 /home/youngjun/tools/tlc-meta/sysop/ 아래에 두고 끝나면 지운다.
- 중첩 2·동작 3·대칭(SysopExtended_depth2.cfg): 17,331,604 distinct, 깊이 39, 3분 12초, 위반·교착 없음. 이 크기부터 instant INCR/serial이 컨테이너 sysop 안에서 일어나고, 그 뒤 컨테이너가 abort·commit·attach되는 조합이 들어간다(기본 크기는 중첩 1이라 instant 연산이 컨테이너 안에 들어가지 못했다).
- 트랜잭션 3·동작 2·대칭, 사용자 행 2·대칭: 첫 시도는 세션 종료로 중단(각각 21,958,058 / 50,196 distinct까지 위반 없음). 세션과 분리(setsid)해 1800초 제한으로 다시 실행했다.
  - 사용자 행 2·대칭(SysopExtended_rows2.cfg): 120,595,469 distinct, 깊이 39, 23분 15초, 위반·교착 없음(완주). 두 행에 걸친 Dml·INCR·serial 조합과 abort가 들어간다.
  - 트랜잭션 3·동작 2·대칭(SysopExtended_txn3.cfg): 1800초 제한에 걸림. 124,016,542 distinct, 큐 4.5M 남음, 위반 없음(미완주). 5400초 제한으로 다시 실행.
- MutNoFragRaise 플래그 추가(slave가 커밋 의존성을 `last_sysop_fragment_lsa`로 올리지 않음). 중첩 2 크기로 실행(SysopExtended_noRaise.cfg). 목적: 올림이 master 라벨에 이미 포함되어 중복인지 확인. 위반이 없으면 floor가 이미 자기 조각 이상을 보장한다는 뜻이다.
  - 결과: 17,331,604 distinct, 깊이 39, 4분 15초, 위반·교착 없음.
  - 코드 확인: 올림은 방어용 중복이다. 라벨 SYSOP_END는 `wset_order_advance_barrier`로 history_start를 그 SYSOP_END까지 올리고(log_manager.c:4913, writeset_history.cpp:190-203은 올리기만 한다), 같은 트랜잭션의 뒤 커밋 라벨은 `wset_order_find_dependency_in_range`의 마지막 단계에서 history_start 아래로 내려가지 않는다(writeset_order.cpp:114-118). commit-order 경로도 max(prev_commit, history_start)다(writeset_history.cpp:130-141). slave의 `la_gate_bound_dependency`가 라벨을 링 꼬리로 낮춰도 자기 조각은 이미 링에 들어가 있어 꼬리 ≥ 조각이다. 올림이 실제로 일하는 곳은 라벨이 없는 커밋(라벨을 쓰지 않는 master)뿐이고, 그 경우도 7455-7459행이 링 꼬리까지 올린다.
- 트랜잭션 3·동작 2·대칭, 5400초 제한 재실행(txn3b): 143,299,466 distinct, 34분 9초, 위반·교착 없음(완주).

## 4. 반례와 판정

- Leftover 켬 NoLostKey 반례: 알려진 결함 1(라벨 SYSOP_END의 사용자 행 키 유실) 그대로. 새 결함 아님.
- Leftover 켬 ConflictOrder 반례: 알려진 todo "develop - 되돌린 INCR 증가가 slave에 남음" 2번 그대로. 경로: query_executor.c:20545-20565(instant 모드가 꺼져 attach, 레코드 NEED_FLUSH 유지) → 같은 트랜잭션의 다음 비어 있지 않은 sysop 끝 log_manager.c:4010-4030(serial 갱신 끝이어도 됨)에서 그 레코드가 써지고 라벨 → slave log_applier.c:7333-7372가 조각으로 떼어 적용 → 바깥 ABORT에서 master는 log_rollback으로 INCR을 되돌리고(attach라 SYSOP_END가 없어 건너뛰지 않음), slave는 7652행에서 남은 항목만 버림. 새 결함 아님(실어 나르는 연산이 serial일 수 있다는 점만 보탠다).
- 변이 반례 네 가지는 모두 의도한 sanity 위반이며 실제 코드와 다르다(모델 검증용).
- Leftover를 끈 실제 코드 모델에서는 모든 크기에서 반례가 없었다.

## 5. 정리

- 범위: instant INCR/DECR(실제 PK 키를 가진 사용자 행), serial NEXT_VALUE/AUTO_INCREMENT(같은 serial을 두 트랜잭션이), serial X lock 아래 NEXT_VALUE와 ALTER SERIAL(commit-order 폴백), 사용자 DML, 컨테이너 sysop의 commit(논리 undo 형태)·attach·abort(부분 롤백과 같은 처리), 중첩 2단계, 트랜잭션 abort, slave의 trid 목록·조각 분리·조각 없는 라벨 처리·커밋 의존성 올림·링 frontier 게이트, 워커 2.
- 불변식: ConflictOrder, FinalEqual, NoLostKey, NoSerialKeyPublished, DepBelowSelf, TLC 교착 검사. 네 sanity 변이로 각 불변식이 실제로 반례를 낼 수 있음을 확인했다.
- 완주한 실행: 기본 17.2M, ALTER SERIAL 37.6M, 중첩 2 17.3M, 사용자 행 2 120.6M, 트랜잭션 3 143.3M distinct, 모두 위반 없음.
- 새로 확인된 실제 결함: 없음. 반례는 모두 이미 알려진 두 결함(키 유실, 되돌린 INCR이 slave에 남음)의 재현이었다.
- 반례가 없는 이유(코드 근거): 라벨 SYSOP_END의 의존성은 키가 아니라 max(prev_commit, history_start)라는 전체 장벽이고 floor도 그 SYSOP_END로 올라간다. 그래서 조각은 앞뒤 모든 커밋과 순서가 고정된다. 결함이 생길 자리는 (가) 조각에 그 연산 것이 아닌 레코드가 섞임, (나) 조각이 master에서 되돌려지는 변경을 담음, (다) 버린 키의 레코드가 커밋에 실림 셋뿐이고, 세 경우 모두 "instant 모드가 꺼진 INCR이 NEED_FLUSH 레코드를 남긴다"는 알려진 경로에서만 생긴다. 그 밖의 표시 사용처(serial, checksumdb, instant INCR)는 자기 SYSOP_END에서 레코드를 모두 쓰고, 표시가 열린 동안 안쪽 sysop은 쓰지 않으며(501e5f315), COMMIT 형태 SYSOP_END는 롤백에서 건너뛰므로 master와 slave가 같다.
- 모델 밖으로 남긴 것(추정, 검사 안 함): 표시가 중첩되는 경우(`repl_start_flush_mark`의 "이미 시작됨" 분기 뒤 안쪽이 `repl_end_flush_mark`로 바깥 표시를 닫음, replication.c:697-737). 표시를 거는 세 곳이 서로 안에서 불리는 경로를 찾지 못해 도달 불가로 본다. 레코드 배열이 꽉 차 `la_set_repl_log`가 긴 트랜잭션으로 바뀐 슬롯의 조각 분리(7274-7293)는 항목을 로그에서 다시 읽는 방식이라 모델의 목록과 결과가 같다고 보고 따로 모델링하지 않았다. 재시작 때 committed_lsa 이하 SYSOP_END 건너뛰기(7400-7430)는 재시작 영역(C9)으로 넘긴다. ABORT 슬롯의 `last_sysop_fragment_lsa` 미초기화는 알려진 항목이고, 위 noRaise 결과와 같은 이유로 불필요한 대기만 만든다.
