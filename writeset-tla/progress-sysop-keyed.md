# keyed sysop 설계안 TLA+ 검사 기록

대상 코드: PR #8052 브랜치 feature/CBRD-27508-parallel-applylogdb-writeset, HEAD 6bd39a696 (읽기 전용, git show로만 읽음). 검사 대상은 이 코드에 아직 없는 설계안("keyed sysop")이다.
모델: WritesetSysopKeyed.tla (WritesetE2E.tla 복사본에 추가, 원본과 기존 cfg·결과는 건드리지 않음), 대칭 모듈 WritesetSysopKeyedSym.tla.
설정 KS_<이름>.cfg(ks_mkcfg.py로 생성), 실행 ks_run.sh(결과 results/sysop-keyed-<이름>.txt, 메타 디렉터리는 실행 뒤 삭제, 2시간 제한), 반례 요약 ks_trace.py(마지막 상태의 마스터 로그와 slave 적용 순서).
작업일: 2026-11-09 20:25~.

## 1. 검사한 설계안

독립 복제 단위 = serial NEXT_VALUE, instant lock 모드로 끝까지 가는 INCR/DECR(그 sysop이 따로 커밋됨).

- 단위의 SYSOP_END에서 prior_lsa_mutex 안에서 자기 키(serial 행 키, INCR 행의 PK 키)만 history에 probe한다. 라벨은 커밋 경로와 같은 규칙(writeset_order.cpp 43-125: 가장 큰 후보, REF 슬롯이 최대가 아니면 prev_commit으로 상한, 다시 history_start로 하한)이다. 그 키를 SYSOP_END 위치로 발행하고 prev_commit을 SYSOP_END로 올린다. history_start는 올리지 않는다(장벽 없음). 키는 바깥 트랜잭션 키 목록에서 빠져 커밋 때 다시 발행하지 않는다.
- attach된 INCR: instant 모드가 중간에 꺼진 INCR은 attach_to_outer로 끝나 행 변경이 바깥 트랜잭션 소속이 된다(X 락 커밋까지, 키는 바깥 키 목록). 지금 코드에서는 그 복제 레코드가 LOG_REPL_NEED_FLUSH로 남아, 같은 트랜잭션의 다음 sysop 끝(항목을 쓰는 아무 sysop)에서 쓰이며 그 조각에 실린다. 바깥이 롤백되면 master는 되돌리지만 이미 조각에 실린 레코드는 slave에 남는다(develop 결함).
- AttachFix: attach 때 레코드를 LOG_REPL_COMMIT_NEED_FLUSH로 바꿔 바깥 COMMIT에만 실림(롤백이면 버려짐).
- SafetyCheck: 단위의 SYSOP_END가 이 sysop 시작 전에 만들어진 레코드(남은 레코드)를 함께 쓰면 그 SYSOP_END만 예전 commit-order 라벨 + history_start 올림.
- slave: 라벨 붙은 SYSOP_END 조각은 실린 항목 전부(남은 레코드 포함)를 자기 태스크로 라벨 순서에 따라 적용(기존 조각 경로 그대로).

## 2. 모델에 더한 것 (WritesetSysopKeyed.tla)

상수
- SysopMode: "commitOrder"(6bd39a696 현재) 또는 "keyed"(설계안).
- AllowIncr(instant INCR 단위), AllowAttach(attach된 INCR), AllowPlainSysop(자기 키 없는 커밋형 중첩 sysop), AttachFix, SafetyCheck.
- 변이 Mut="noSysopPrevRaise": keyed 단위가 prev_commit을 올리지 않음.

변수
- pend[t]: attach된 INCR 중 아직 로그에 안 쓰인(NEED_FLUSH) 레코드의 키.
- shipped[t]: 조각에 실려 이미 쓰인 attach INCR 레코드의 키(그 키는 COMMIT 항목에서 빠짐).
- 로그 레코드에 wr(그 레코드가 slave에서 적용하는 쓰기들, <<키, 쓰기 id>>)와 co(commit-order 라벨 여부) 필드 추가. 쓰기 id <<t, 0>>은 바깥 트랜잭션의 변경(DML 또는 attach INCR, abort로 되돌려짐), <<t, i>>는 SYSOP_END가 레코드 i인 독립 단위.

동작 (WritesetSysopKeyed.tla 행번호 / 대응 코드)
- KeyedDeps(es) 427행: 단위 자기 키 probe와 상한·하한. writeset_order.cpp 43-125(wset_order_find_dependency_in_range)를 그대로 옮김. commitOrder 모드와 SafetyCheck 발동 시에는 기존 CommitOrderDep(writeset_history.cpp 129-142).
- SysopUnit(t, o) 440행: 독립 단위 하나를 한 단계로 기술. o가 serial이면 serial.c 1236-1330, 행 키면 instant INCR(query_executor.c 20496-20556의 log_sysop_commit 경로, 키 수집은 locator_sr.c 9031-9070), None이면 남은 레코드만 쓰는 커밋형 중첩 sysop(페이지 할당 등, findings.md 76행 근거). 항목 D(log_manager.c 4010-4030의 flush)와 라벨+SYSOP_END S(4905-4916)를 연달아 씀. pend[t]의 남은 레코드가 같은 조각에 실림(4010-4030은 append_repl_recidx부터 NEED_FLUSH를 모두 씀). keyed면 자기 키를 SYSOP_END로 발행(용량 초과면 slow path처럼 비우고 history_start = 그 순간 prev_commit), prev_commit을 SYSOP_END로 올림. commitOrder면 history_start를 SYSOP_END로 올리고 키 버림(4052-4094, wset_discard_sysop_keys). instant INCR은 자기 행을 이미 쥔 트랜잭션에서는 instant 모드가 꺼지므로(lock_manager.c 3984-3993) 그 경우는 막고 AttachIncr로 넘김.
- AttachIncr(t, k) 482행: query_executor.c 20558-20565의 log_sysop_attach_to_outer(log_manager.c 4311-4345). 행 X 락, 바깥 키 목록에 키, 쓰기 id <<t, 0>>. AttachFix가 아니면 pend[t]에 넣음(replication.c 484-507의 NEED_FLUSH 표시).
- CommitRecord 313행: COMMIT 항목 = 손댄 키 중 shipped가 아닌 것(log_manager.c 4930-5000, 이미 쓴 항목은 DONT_NEED_FLUSH). pend 비움.
- Abort 277행: 안 쓰인 레코드는 버리고(pend 비움) 이미 조각에 실린 것은 되돌리지 않음. master 쪽은 <<t, 0>> 쓰기를 모두 되돌림.
- RollbackToSavepoint 255행: 저장점 뒤 pend만 버림(repl_log_abort_after_lsa). 이번 실행에서는 a_rstsp에서만 켬.
- slave 쪽은 E2E 그대로(조각 = 슬롯에 있던 항목 전부를 자기 태스크로, 라벨로 gate). FixFragStart=TRUE(리뷰 수정안) 기본.

불변식 (E2E에서 바꾼 것)
- Conflict 554행: 키 동일성(쓰기가 하나라도 있음)과 문장 복제만. 조각의 키 = 자기 키 + 실린 남은 레코드 키. 같은 트랜잭션이라는 것만으로는 충돌로 보지 않음(keyed 단위끼리, 단위와 자기 커밋 사이 순서는 키로만 따짐).
- DepCover 779행(모든 라벨 단위는 실제로 충돌하는 앞선 단위를 모두 기다림), ConflictOrder 793행(slave에서 충돌 단위가 로그 순서대로 적용) — 위 Conflict로 조각·남은 레코드 키까지 확장.
- BarrierWaitsAll 783행: commit-order 라벨이 붙은 조각(co)과 문장 커밋만 대상으로 좁힘.
- FinalState 810행: 키마다 slave가 마지막으로 적용한 쓰기 id = master의 살아 남은 마지막 쓰기 id(SlaveLast 806행이 wr 사용).
- 그대로: DepBelowSelf, NoDuplicate, OnlyUnits, PrefixStored, RequiredStored, QuietAllApplied, SerialOrder.
- 확인용(반례가 나야 정상): NoLeftoverInFragment 813행(AttachFix 없으면 조각에 바깥 변경이 실림), SysopIsBarrier 815행(keyed면 조각이 앞선 모든 단위를 기다리지 않음 = 장벽이 실제로 사라짐), NoSameTxnSerialTwice 817행(한 트랜잭션이 같은 serial 단위를 두 번 하는 경우에 도달함).

## 3. 단순화

- E2E의 단순화 목록(progress-e2e.md 3절)을 그대로 이어받음.
- keyed 단위의 probe·라벨·발행·prev_commit 올림을 한 단계(prior_lsa_mutex 한 구간)로 둠. 발행이 mutex 안이라는 설계안 그대로라 빠른 경로 항목별 발행과 겹치는 경우는 넣지 않음(이번 설정은 모두 FineGrainPublish=FALSE, 메모리 부족 없음).
- SafetyCheck가 발동한 SYSOP_END도 keyed 모드에서는 자기 키 발행과 prev_commit 올림을 함께 함(history_start를 SYSOP_END로 올리므로 결과에 영향 없음).
- 한 트랜잭션이 같은 행을 바깥 변경으로 두 번 바꾸는 경우는 E2E처럼 넣지 않음. instant INCR 단위는 같은 트랜잭션이 여러 번 할 수 있음(쓰기 id가 다름).
- 기본 설정: 트랜잭션 2, 키 2, serial 1, KeyLimit 2, MaxOps 2, REF·overflow·abort 켬, 문장 복제·저장점·메모리 부족·마스터 재시작 끔(표시한 실행만 켬), 워커 2, 큐 2, 링 50, 슬레이브 크래시 1, 대칭(트랜잭션·키·serial), 순차 합성(Interleave=FALSE).

## 4. 실행 기록

각 줄: 이름, 바꾼 값 → 결과, 고유 상태, 깊이, 시간.

확인용
- san_barrier: keyed, 크래시 0, SysopIsBarrier만 → 위반(정상, keyed 조각이 앞선 단위를 다 기다리지 않음), 336, 7, 1초.
- san_leftover: AttachFix=FALSE, 크래시 0, NoLeftoverInFragment만 → 위반(정상), 775, 7, 1초.
- san_twice: 크래시 0, NoSameTxnSerialTwice만 → 위반(정상, 같은 트랜잭션의 같은 serial 두 단위에 도달), 552, 7, 1초.

a) keyed + AttachFix + prev_commit 올림 + abort: 위반이 없어야 함
- a_t2: 기본값(트랜잭션 2, 키 2, serial 1, MaxOps 2, abort, 슬레이브 크래시 1; 한 트랜잭션의 같은 serial 두 단위는 san_twice로 도달 확인) → 위반 없음, 84,681,782, 74, 1시간 40분.
- a_s2nc: serial 2, 크래시 0 → 위반 없음, 7,014,078, 45, 10분 46초.
- a_rstsp: 마스터 재시작(1회)·저장점 켬, 크래시 0 → 위반 없음, 9,305,699, 45, 10분 34초.
- a_m3nc: MaxOps 3, 크래시 0 → 큐가 983만으로 계속 늘어 메타 디렉터리 예산 때문에 21:13에 손으로 중단. 그때까지 위반 없음, 4,411만 상태, 깊이 32(완료 아님).
- a_sim_t4: 시뮬레이션(-simulate, 깊이 300, seed 7, 30분), 트랜잭션 4, 키 3, serial 2, MaxOps 3, KeyLimit 3, 워커 3, 크래시 2, 마스터 재시작·저장점 켬 → 위반 없음, 1억 6,618만 상태 검사(전수 아님).

b) keyed + AttachFix + Mut="noSysopPrevRaise": 반례가 나야 함
- b_noPrevRaise: 크래시 0, 전체 불변식 → DepCover 위반, 1,064, 8, 1초. 반례: T1이 FK REF 두 개로 커밋(C 2, prev_commit=2). T2가 serial s1 단위 S(5)(s1을 5로 발행, 변이라 prev_commit은 2 그대로), 같은 T2가 s1 단위를 한 번 더 S(7): probe 후보 5가 prev_commit 2로 깎여 라벨 2 < 5. 같은 트랜잭션·같은 serial의 뒤 조각이 앞 조각보다 낮은 라벨을 받는 경우(예상한 반례).
- b_slave: 같은 설정, slave 불변식만(DepCover 등 마스터 쪽 제외) → ConflictOrder 위반, 237,039, -, 8초. 반례는 다른 경로: T1 instant INCR k1 단위 S(3)(k1을 3으로 발행, prev_commit 그대로 0) → T2가 k1 REF 후 overflow로 commit-order 커밋 C(5), 라벨 = max(history_start, prev_commit) = 0 → slave가 C(5)를 S(3)보다 먼저 적용. commit-order 트랜잭션은 prev_commit에만 기대므로, keyed 단위가 prev_commit을 올리지 않으면 commit-order 커밋도 그 단위를 건너뛴다. prev_commit 올림이 같은 serial 순서와 commit-order 커밋 양쪽에 필요하다는 뜻이다.

c) keyed, AttachFix 없음, SafetyCheck 없음, abort 끔: 순서 반례가 나야 함
- c_noFix: 전체 불변식 → DepCover 위반, 867, 8, 1초. 반례: T1 instant INCR k1 단위 S(3)(k1=3 발행). T2가 k1을 attach INCR(레코드는 NEED_FLUSH로 남음), 이어 T2 instant INCR k2 단위 S(6): 자기 키 k2만 probe해 라벨 0, 그런데 조각에 남은 k1 레코드가 실림 → k1의 앞선 쓰기 S(3)를 기다리지 않음.
- c_slave: 같은 설정, slave 불변식만 → ConflictOrder 위반, 256,324, 22, 18초.
- c_serialOnlyNoRef: INCR 단위·keyless sysop·REF·overflow 끔, slave 불변식만 → ConflictOrder 위반, 19,855, 22, 5초. 과제에 적은 형태 그대로의 반례: T1이 k1·k2를 쓰고 커밋 C(2). T2가 k1을 attach INCR(T1 락 해제 뒤), 이어 serial s1 단위 S(5): s1 probe가 비어 라벨 0, 조각에 k1 레코드가 실림 → slave가 S(5)(T2의 k1 증가)를 C(2)(T1의 k1 쓰기)보다 먼저 적용. 최종 k1 값도 master와 달라짐.
- c_serialOnly: 위와 같되 REF 켬 → ConflictOrder 위반, 80,594, 22, 9초(T1 커밋이 k1 FK REF인 형태, 부모 행 변경이 자식 INSERT보다 먼저 적용).
- c_sim_t4: a_sim_t4 크기, AttachFix·SafetyCheck 없음, abort 끔, slave 불변식만, 시뮬레이션 → ConflictOrder 위반, 18초(시뮬레이션 검출력 확인용).

d) keyed, AttachFix 없음, SafetyCheck, abort 끔: 위반이 없어야 함
- d_t2: 기본값(트랜잭션 2, 키 2, serial 1, MaxOps 2, 크래시 1) → 위반 없음, 40,055,959, 74, 52분 13초.
- d_sim_t4: a_sim_t4 크기, abort 끔, 시뮬레이션 30분 → 위반 없음, 9,941만 상태 검사(전수 아님).
- d_abort(추가): d와 같되 abort 켬 → FinalState 위반, 169,328, 16, 17초. 반례: T1 k1 attach INCR → T1 instant INCR k2 단위 S(3)가 남은 k1 레코드를 싣고 commit-order 라벨(SafetyCheck 발동) → T1 abort → master는 k1 증가를 되돌렸지만 slave는 이미 적용. SafetyCheck는 순서만 고치고 롤백 불일치는 그대로 남는다(AttachFix가 있어야 사라짐).

e) commitOrder(현재), AttachFix 없음, abort 켬: FinalState 위반이 나야 함
- e_commitOrder: 기본값 + SysopMode="commitOrder" → FinalState 위반, 149,897, 16, 9초. 반례: T1 k1 attach INCR(NEED_FLUSH로 남음) → T1 instant INCR k2 단위 S(3)가 남은 k1 레코드를 실음 → T1 abort → slave에 k1 증가가 남음. develop HA에서 본 롤백 불일치(todo "되돌린 INCR 증가가 slave에 남음")를 모델이 재현.

## 5. 결론

- a~e 다섯 기대가 모두 맞았다. 모델 결함으로 보이는 예상 밖 결과는 없었다.
- keyed 설계안 자체(자기 키 probe, 커밋과 같은 상한, SYSOP_END 발행, prev_commit 올림, history_start 그대로)는 AttachFix를 넣으면 순서·최종 상태·재시작 불변식을 모두 지켰다(전수 최대: 트랜잭션 2·키 2·serial 1·크래시 1 8,468만 상태, serial 2, 마스터 재시작·저장점; 시뮬레이션 트랜잭션 4·키 3·serial 2).
- prev_commit 올림은 필수다. 빼면 (1) 같은 serial의 뒤 단위 라벨이 앞 단위 아래로 깎이고(b_noPrevRaise), (2) commit-order 커밋(overflow 등)이 keyed 단위를 건너뛴다(b_slave). 두 번째는 과제에 적힌 경로 외에 새로 보인 경로다.
- attach INCR의 남은 레코드가 keyed 조각에 실리면 그 행의 앞선 쓰기를 기다리지 않아 순서가 뒤집힌다(c). 남은 레코드가 실리는 조각은 serial 단위, instant INCR 단위, 자기 키 없는 중첩 sysop 어느 것이든 된다.
- SafetyCheck는 이 순서 문제를 막는다(d_t2, d_sim_t4). 하지만 바깥 abort 때 slave에 남는 develop 불일치는 그대로다(d_abort). AttachFix는 순서와 롤백 불일치를 둘 다 없앤다(a). 따라서 AttachFix가 근본 수정이고, SafetyCheck는 AttachFix가 빠진 경로를 위한 방어로만 의미가 있다.
- 현재 코드(commitOrder)에서 롤백 불일치를 모델이 재현했다(e).

한계
- 전수 검사는 트랜잭션 2개까지 완료. MaxOps 3은 중단(4,411만 상태까지 위반 없음), 큰 크기는 시뮬레이션(전수 아님).
- 빠른 경로 항목별 발행, 메모리 부족, 문장 복제는 이번 실행에서 껐다. keyed 발행이 commit의 빠른 경로 발행과 겹치는 경우는 검사하지 않았다.
