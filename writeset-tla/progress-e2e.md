# writeset 통합(E2E) TLA+ 모델 진행 기록

대상 코드: PR #8052 브랜치 feature/CBRD-27508-parallel-applylogdb-writeset, HEAD 6bd39a696 (읽기 전용, git show로만 읽음).
모델: WritesetE2E.tla, 설정 E2E_*.cfg(e2e_mkcfg.py로 생성), 실행 e2e_run.sh / e2e_batch.sh, 결과 results/out-e2e-<이름>.txt, 요약 e2e_status.sh, 반례 요약 e2e_trace.py.
시작: 2026-11-07 11:40.

## 1. 모델이 하는 일

마스터의 실제 동작이 로그를 만들고, 슬레이브가 그 로그를 읽어 적용한다. 고정된 이상적 마스터 로그를 쓰지 않는다.

마스터
- 트랜잭션별 키 목록(LOCAL): WRITE와 REF 종류, 목록이 KeyLimit개 찬 뒤 추가하면 키를 모두 버리고 커밋 순서 모드로 전환(writeset.cpp 143-192), 그 밖의 커밋 순서 전환(NaN 키, 반복 갱신으로 한도 도달)은 아무 때나 일어날 수 있는 비결정 동작으로 둠, 문장 복제는 커밋 순서 모드(replication.c 610), 저장점 롤백은 그 뒤의 변경과 키만 지우고 락은 유지(writeset.cpp 531-542, log_manager.c 4276).
- 전역 history 맵(GLOBAL): 해시마다 write_seq/ref_seq(커밋 LSA), 용량 KeyLimit(작게 두어 차게 함), 빠른 경로는 rdlock 아래 예약 후 항목을 하나씩 발행(다른 트랜잭션의 probe와 끼어듦), 예약 실패나 용량 초과는 seq_lock+wrlock 아래 비우고 발행, 메모리 부족은 비우기만, 커밋 순서 커밋은 발행 대신 비우기, 비울 때 history_start를 그 순간의 prev_commit으로 올림(writeset_history.cpp 189-342).
- 커밋: complete_mvcc → (prior_lsa_mutex 안) 복제 레코드·의존성 계산(probe+floor)·라벨·커밋·record_commit → 발행 → 락 해제(log_manager.c 5596, 5041-5053, 5640, 5649).
- 행 락: CBRD-27034 이후 충돌하는 쓰기는 소유자의 MVCCID 자기 락을 lock_unlock_all까지 기다리므로, 키는 변경 시점부터 발행 뒤 해제까지 잡힌 것으로 둠. REF는 S, WRITE는 X.
- serial 라벨 SYSOP_END 한 경로: 같은 mutex 안에서 커밋 순서 의존성, 라벨, SYSOP_END, history_start를 SYSOP_END로 올림(log_manager.c 4905-4916). 직전에 serial 행의 복제 레코드(D)가 flush됨.
- 마스터 재시작(최대 1회): 진행 중 트랜잭션은 LOG_ABORT로 롤백, history 비움, history_start = 복구된 로그 끝(log_manager.c 1515-1519).

슬레이브
- 코디네이터가 로그를 읽고, 트랜잭션 첫 레코드에서 슬롯 생성(7561-7584), 조각(fragment) 분리(7245-7321), 커밋 의존성(7440-7466), 링·gate·pending·task queue·in-flight·워커·결과 수집·retire(coordinator.cpp, gate.cpp), committed_lsa/required_lsa(2312-2380), 적용 정보 저장(1172-1214, 마커 삭제를 같은 트랜잭션에서), 데이터와 같은 트랜잭션의 마커(936-950), 크래시 후 저장 정보로 재시작(2852-2947, 9811).
- 워커 수 NumWorkers, task queue 크기 QCap, 링 용량 RingCap(크게 두면 코드의 워커×1024보다 더 많은 동작을 허용하므로 포함 관계가 성립).

## 2. 불변식

- DepCover(가정-보장): 마스터가 만든 모든 로그에서, 적용 단위(항목이 있는 커밋, serial 조각) j는 실제 키 동일성으로 충돌하는 앞선 단위 i 이상을 라벨로 가진다. 충돌 = 공통 키에 WRITE가 하나라도 있음, 문장 복제, 같은 트랜잭션.
- DepBelowSelf, BarrierWaitsAll(조각·문장 커밋은 앞선 모든 단위를 기다림).
- ConflictOrder: 슬레이브에서 충돌하는 두 단위는 마스터 로그 순서대로 적용된다(재시작을 넘어 누적).
- NoDuplicate, OnlyUnits: 재시작을 넘어 중복 적용 없음.
- QuietAllApplied: 마스터가 멈추고 슬레이브가 다 비운 상태에서 모든 단위가 적용됨(유실 없음).
- FinalState: 그 상태에서 키마다 슬레이브의 마지막 쓰기 단위 = 마스터의 실제 쓰기 순서상 마지막 단위.
- PrefixStored, RequiredStored: 저장된 committed_lsa 아래 단위는 적용됨, 저장된 required_lsa는 미적용 단위 트랜잭션의 첫 레코드를 넘지 않음.
- 교차 확인용(반례가 나야 정상): SerialOrder(슬레이브가 실제로 순서를 바꿔 적용함).

## 3. 단순화 목록 (모델이 코드와 다르게 둔 것)

1. 복제 레코드, 라벨, COMMIT을 한 레코드 C로 합침. 코드에서 셋은 한 prior_lsa_mutex 구간에서 연달아 쓰이므로 다른 트랜잭션 레코드가 끼지 않는다. 재시작 위치(required_lsa)는 슬롯 시작·조각 시작·final_lsa이므로 이 사이에 떨어지지 않는다. serial 조각만 항목 D와 라벨+SYSOP_END(S)를 나눴다(조각 start_lsa가 항목 위치라서). D와 S 사이에 다른 트랜잭션 레코드가 끼는 경우는 넣지 않음.
2. 라벨 보관 칸(la_wset_label_store/take)은 합친 레코드의 속성으로 둠. 1번 때문에 라벨과 경계 사이에서 재시작하지 않는다.
3. 트랜잭션의 첫 레코드는 항상 비복제 레코드 X(첫 변경의 heap 로그). 키 하나당 변경은 트랜잭션마다 한 번(같은 키를 다시 바꾸는 것은 키 목록 크기만 늘리므로 비결정 overflow로 덮음).
4. REF의 대기: REF는 부모 키 S, WRITE는 X로 두어 서로 기다리게 함. 코드에서 자식 INSERT와 부모 DELETE/키 변경은 btree의 진행 중 stamp 대기로 서로 기다리지만, 부모의 키 아닌 열만 바꾸는 갱신은 FK 검사와 서로 기다리지 않을 수 있다(그 경우 순서가 바뀌어도 결과가 같다). 모델의 REF/WRITE 충돌은 "의미상 충돌"을 기준으로 둔 것.
5. INCR 조각, 컨테이너 sysop, 라벨 없는 SYSOP_END, 중첩 sysop은 넣지 않음(SysopExtended.tla에서 다룸). serial 조각 하나의 경로만 둠.
6. 슬레이브 오류 주입(결과 오류, flush 오류), long transaction 분기(LA_MAX_REPL_ITEMS), 항목 재시도, 레플리카 지연, failover/승격은 넣지 않음(SlaveCoordinator.tla, RestartFailover.tla에서 다룸).
7. history 맵 probe는 CommitRecord 한 단계 안에서 원자적으로 함(코드도 prior_lsa_mutex 안이라 다른 probe·record_commit과 겹치지 않음). 발행의 빠른 경로만 항목 단위로 쪼갬(FineGrainPublish).
8. 순차 합성(Interleave=FALSE): 슬레이브는 마스터가 모두 끝난 뒤 시작하고, 그때 마스터 작업 상태를 초기화해 같은 로그를 만든 실행을 합친다. 근거: 슬레이브 동작은 이미 쓰인 로그 앞부분에만 의존하므로, 마스터와 겹친 슬레이브 실행은 같은 순서로 완성된 로그에서도 그대로 일어난다(읽기를 늦춘 것과 같다). 로그 끝에서만 가능한 동작(la_log_commit)은 모델에서 아무 때나 허용한다. 작은 크기에서 Interleave=TRUE로 같은 결과인지 확인한다(5절).
9. 마스터 정지 시점은 모든 트랜잭션이 끝났거나 시작하지 않은 상태로 한정(열린 채 남는 트랜잭션은 슬롯이 required_lsa를 낮게 붙잡는 쪽이라 더 안전하다).
10. TLC 대칭(TxnSym): 트랜잭션 이름 교환. 키는 해시 모드 때문에 숫자로 두어 대칭을 쓰지 않음.
11. 크기를 키울 때 쓴 축소: MaxOps(트랜잭션당 동작 수 상한), 기능 끄기(저장점·문장·abort·메모리 부족·마스터 재시작), MasterOnly(슬레이브 없이 마스터 보장만 검사). 각 실행 줄에 무엇을 껐는지 적었다. 모두 동작을 덜 허용하는 방향이라 "그 범위 안에서 위반 없음"만 뜻한다.
12. 링 용량 RingCap은 50~100으로 두어 사실상 막히지 않게 함(작은 링의 실행은 큰 링 실행의 부분집합).
13. 마커 테이블 TRUNCATE(AllowMarkerDdl)는 key 0을 쓰는 문장 복제로 두고, slave가 적용하면 마커가 그 트랜잭션 것만 남는다. DROP(그 뒤 적용이 영영 실패)은 진행 불가 문제라 넣지 않음.

## 4. 기지 결함 재현 (모델 검증)

- s1_bug(현재 코드, FixFragStart=FALSE, 트랜잭션 2·키 2·워커 2, 크래시 1): QuietAllApplied 위반, 58만 상태, 깊이 17, 10초. 반례: T1 첫 레코드 X(1) → serial 항목 D(2) → 라벨 SYSOP_END S(3) → ABORT(4). 슬레이브가 모두 읽은 뒤 조각 태스크가 아직 끝나지 않은 상태에서 la_log_commit이 required_lsa=2(조각 start_lsa=첫 항목, log_applier.c:7307)를 저장하고 크래시. 재시작은 2부터 읽어 T1 슬롯이 없으니 D를 버리고(la_set_repl_log 4580-4584), S는 슬롯이 없어 complete_without_task(7372-7383)로 끝나 serial 갱신이 영영 적용되지 않는다. hgryoo 님 리뷰(results/hgryoo-review-20261106.txt 첫 항목, INCR로 HA 3/3 재현)와 같은 경로를 serial로 낸 것이다. 1차 슬레이브 모델이 놓친 "트랜잭션 첫 레코드 ≠ 첫 항목" 차이를 이번 모델이 잡는다.
- 이후 기본 실행은 리뷰 수정안(조각 start_lsa = 바깥 슬롯 start_lsa, FixFragStart=TRUE)을 적용한 상태로 나머지 설계를 검사한다.

## 5. 실행 기록

기본값(e2e_mkcfg.py): 트랜잭션 2, 키 {1,2}, serial 1, 해시 ident, KeyLimit 2(트랜잭션 한도이자 history 용량), MaxOps 2, REF·overflow·문장 복제·저장점·abort·메모리 부족·마스터 재시작(1회)·serial 모두 켬, 빠른 경로 항목별 발행, 순차 합성, 워커 2, 큐 2, 링 50, 슬레이브 크래시 1회, FixFragStart=TRUE, 대칭 TxnSym. 각 줄은 이름: 바꾼 값 → 결과, 고유 상태, 깊이, 걸린 시간.

전수 검사
- s1_bug: FixFragStart=FALSE(현재 코드), RequiredStored 제외 → QuietAllApplied 위반(4절의 기지 결함), 583,315, 17, 10초.
- s1: 기본값 → 위반 없음, 6,924,225, 74, 3분 27초.
- s1_collide: 키 1과 2가 같은 해시(충돌) → 위반 없음, 6,933,717, 74, 약 3분 30초. 충돌은 대기만 늘린다.

- s2_lite: 트랜잭션 3, 키 2, 워커 2, 저장점·메모리 부족·마스터 재시작 끔(REF·overflow·문장·abort·serial 켬), 크래시 1 → 5시간 15분(12:01~17:16)에 위반 없이 7억 344만 상태·깊이 45까지, 큐 6,652만으로 계속 늘어 중단(10시간 안에 끝나지 않을 것으로 판단). 이 범위 안 실행은 모두 위반 없음(완료 아님).
- s1_inter: 기본값 + Interleave=TRUE → 25분(12:02~12:25)에 위반 없이 7,999만 상태·깊이 27까지 진행, 큐가 계속 늘어 중단하고 더 작은 짝(s0/s0_inter)으로 순차 합성 축약을 확인하기로 함.
- s0_inter: s0 + Interleave=TRUE → 위반 없음, 31,040,964, 76, 11분 55초. 순차 합성 s0(182만)과 결과·깊이 같음: 순차 합성 축약이 이 크기에서 반례를 숨기지 않음을 확인.
- s0: 저장점·문장 복제·메모리 부족·마스터 재시작 끔 → 위반 없음, 1,820,686, 76, 42초.

변이(모두 반례가 나야 정상)
- m_noClearFloor: history 비울 때 history_start를 올리지 않음 → DepCover 위반, 277,377, 14, 6초.
- m_unlockEarly: 발행 전에 락 해제 → DepCover 위반, 74,081, 11, 4초. 반례: T1이 REF 1·2로 커밋하고 발행 전에 락을 놓자 T2가 1을 써서 probe가 빈 history를 보고 의존성 0.
- m_gateLoose: gate가 dep <= frontier+1로 한 레코드 일찍 통과 → ConflictOrder 위반, 781,076, 20, 13초.
- m_splitEq: 같은 키가 두 해시(콜레이션 결함 형태) → DepCover 위반, 594,287, 13, 9초. 반례: T1 REF 1(해시 11) 뒤 T2 WRITE 1(해시 12)이 history를 놓쳐 의존성 0.
- m_visibleAtMvcc: complete_mvcc 뒤 충돌 쓰기 허용(CBRD-27034 이전 형태) → DepCover 위반, 42,249, 10, 3초.
- m_noSysopFloor: 라벨 SYSOP_END가 history_start를 올리지 않음 → DepCover 위반, 687, -, 1초 미만.
- m_noOvfFloor: 커밋 순서 커밋이 history_start를 올리지 않음 → DepCover 위반, 24,161, 9, 3초.
- m_markerTrunc: 마스터에서 마커 테이블 TRUNCATE(문장 복제) 허용 → NoDuplicate 위반, 2,193,002, 26, 34초. 반례: T1(키 REF) 적용과 마커 기록 → 아직 적용 정보 저장 전에 T2의 TRUNCATE가 slave에서 적용되어 마커가 T2 자신 것만 남음 → 크래시 → 저장된 required_lsa(1)부터 다시 읽어 T1을 다시 적용. hgryoo 님 리뷰가 "돌려 보지는 않았다"고 남긴 TRUNCATE 경로를 모델에서 확인(HA 미재현, 추정 단계).
- san_serial(교차 확인): SerialOrder만 검사 → 위반(슬레이브가 실제로 순서를 바꿔 적용함), 700,933, 19, 12초.

시뮬레이션(TLC -simulate, 무작위 긴 실행, 전수 아님, 대칭 없음)
- sim_big 공통 크기: 트랜잭션 8, 키 {1,2,3,4}, serial 1, KeyLimit 3(history 용량 3이라 자주 비움), MaxOps 3, 워커 10, 큐 4, 링 100, 슬레이브 크래시 최대 3, 나머지 기능 모두 켬, 깊이 상한 500.
- sim-sim_big-11(seed 11, 1시간, 12:38~13:38): 위반 없음, 4억 6,514만 상태 검사.
- 시뮬레이션 검출력 점검: sim_big_bug(현재 코드, FixFragStart=FALSE)를 90초 돌렸을 때(seed 1, 486만 상태) 기지 결함을 찾지 못함. 결함 경로가 "조각 + 바깥 abort + 저장 + 크래시 + 재시작" 다섯 사건의 조합이라 무작위 실행으로는 드물다. 1시간 실행으로 다시 잰다(아래).
- sim-sim_big_bug-12(seed 12, 현재 코드): ConflictOrder 위반, 333만 상태(약 1분). 반례(트랜잭션 8개 로그 24레코드): t3가 X(1)·D(4)·S(5)·A(8), 다른 트랜잭션 t7의 X(3)가 열려 있는 동안 required_lsa=3이 저장됨(t3 조각 start_lsa=4라 t3 첫 레코드 1을 붙잡지 못함) → 크래시 → 3부터 다시 읽어 D(4)를 버리고 S(5)를 complete_without_task로 끝냄 → 같은 serial의 뒤 조각 S(12)가 S(5) 없이 적용. 4절 기지 결함과 같은 원인이고, 다른 트랜잭션의 슬롯이 required_lsa를 잡고 있어도 생긴다는 점을 보여 준다. 시뮬레이션 검출력: 이 결함은 큰 크기 무작위 실행으로 1분 안에 잡힘(90초 seed 1 실행은 못 잡음).
- sim-sim_big_collide-13(seed 13, 1시간, 키 1·2 해시 충돌): 위반 없음, 4억 5,522만 상태.
- sim-sim_mid-14(seed 14, 1시간): 트랜잭션 6, 키 3, KeyLimit 2, MaxOps 2, 워커 10, 큐 2, 크래시 3, Interleave=TRUE(마스터와 슬레이브가 겹쳐 실행), 깊이 상한 400 → 위반 없음, 5억 5,466만 상태.
- sim-sim_big-15(seed 15, 1시간, sim_big 크기): 위반 없음, 4억 5,360만 상태.
- sim-sim_big_inter-21(seed 21, 1시간, sim_big 크기 + Interleave=TRUE, 깊이 상한 600): 위반 없음, 3억 9,458만 상태.
- sim-sim_big_crash5-22(seed 22, 1시간): 트랜잭션 10, 키 4, 슬레이브 크래시 최대 5, 그 밖은 sim_big과 같음, 깊이 상한 700 → 위반 없음, 3억 455만 상태.

마스터 단독(MasterOnly=TRUE, 슬레이브 없이 DepCover·DepBelowSelf·BarrierWaitsAll만 검사, 가정-보장의 마스터 쪽을 큰 크기에서 보기 위함)
- mo_t3k2: 트랜잭션 3, 키 2, 모든 기능 → 22분(16:39~17:01)에 위반 없이 1억 6,731만 상태·깊이 18까지, 큐 5,598만으로 계속 늘어 중단. 기능을 모두 켠 트랜잭션 3개는 마스터만으로도 전수 검사 범위를 넘는다.
- moc_t3k2: 트랜잭션 3, 키 2, 핵심 기능만(REF·overflow·serial·항목별 발행·용량 2; 저장점·문장·abort·메모리 부족·마스터 재시작 끔) → 위반 없음, 13,874,491, 24, 2분 13초.
- moc_t3k3: 트랜잭션 3, 키 3, 핵심 기능 → 위반 없음, 72,442,410, 24, 11분.
- moc_t4k3: 트랜잭션 4, 키 3, 핵심 기능 → 1시간 2분(17:15~18:17)에 위반 없이 3억 230만 상태·깊이 18까지, 큐 1억 7,796만으로 급증해 중단.
- moc_t4k2: 트랜잭션 4, 키 2, 핵심 기능 → 1시간(18:17~19:18)에 위반 없이 2억 8,101만 상태·깊이 20까지, 큐 1억 4,082만으로 늘어 중단.
- moc1_t5k3: 트랜잭션 5, 키 3, MaxOps 1, 핵심 기능, 마스터 단독 → 1시간 31분(19:18~20:49)에 위반 없이 1억 5,394만 상태·깊이 21까지, 큐 7,050만으로 늘어 중단.

한 트랜잭션당 동작 1회(MaxOps 1, 저장점·메모리 부족·마스터 재시작 끔; REF·overflow·문장·abort·serial 켬), 전체 E2E
- e1_t3k2w2: 트랜잭션 3, 키 2, 워커 2, 크래시 1 → 위반 없음, 11,732,168, 78, 5분 33초.
- e1_t3k3w2: 트랜잭션 3, 키 3, 워커 2, 크래시 1 → 위반 없음, 32,045,063, 78, 16분.
- e1_t4k3w3: 트랜잭션 4, 키 3, 워커 3, 크래시 1 → 5시간 12분(17:37~22:49)에 위반 없이 6억 6,534만 상태·깊이 38까지, 큐 8,710만으로 계속 늘어 중단.

## 6. 결론 (2026-11-07 22:50)

검사한 것
- 마스터의 LOCAL 키 목록과 GLOBAL history 맵, 커밋 경로의 잠금 순서(probe·라벨·커밋·record_commit은 한 mutex, 발행은 그 뒤 락 해제 전), 용량 예약·비우기·floor, serial 라벨 SYSOP_END, 마스터 재시작이 만든 로그를 슬레이브 코디네이터·gate·워커·마커·재시작이 그대로 소비하는 전 과정을 한 모델로 묶었다.
- 가정-보장: 슬레이브가 기대하는 입력 성질(DepCover, BarrierWaitsAll, DepBelowSelf)은 마스터가 만든 모든 로그에서 성립했다(전수 검사한 모든 크기, 마스터 단독 트랜잭션 3·키 3까지 완료).
- 끝에서 끝: 충돌 순서(ConflictOrder), 재시작을 넘는 유실·중복 없음, 최종 상태 일치가 리뷰 수정안(조각 start_lsa = 바깥 슬롯 start_lsa)을 넣은 상태에서 모두 성립했다.

가장 큰 완료 크기
- 전수(전 기능): 트랜잭션 2, 키 2, 워커 2, 크래시 1(s1, 692만 상태).
- 전수(동작 1회): 트랜잭션 3, 키 3, 워커 2, 크래시 1(e1_t3k3w2, 3,205만 상태).
- 전수(마스터 단독, 핵심 기능): 트랜잭션 3, 키 3(moc_t3k3, 7,244만 상태).
- 중단한 큰 전수(위반 없이 진행한 범위): s2_lite 7억 344만, e1_t4k3w3 6억 6,534만, moc_t4k3 3억 230만.
- 시뮬레이션: 트랜잭션 8~10, 키 4, 워커 10, history 용량 3, 크래시 3~5, 순차·겹침 모두, 수정안 적용 6회 합계 약 26억 상태, 위반 없음.

결함
- 확정(기지, 이번 모델로 재현): 조각 start_lsa가 첫 항목이라 바깥 트랜잭션이 abort되면 저장된 required_lsa가 그 트랜잭션의 첫 레코드를 넘고, 그 사이 재시작하면 조각이 영영 적용되지 않는다(log_applier.c:7307, 7283 / 4580-4584 / 7372-7383). hgryoo 님 HA 재현(INCR)과 같은 경로이고 serial에서도 같다. 다른 트랜잭션 슬롯이 required_lsa를 잡고 있어도 생긴다(sim_big_bug 반례). 리뷰 수정안으로 모든 검사가 통과한다.
- 모델 확인·HA 미재현(추정): 마커 테이블 TRUNCATE가 복제되면 재시작 때 이미 적용한 트랜잭션을 다시 적용한다(m_markerTrunc). 리뷰의 DROP 지적과 같은 뿌리(마커가 일반 테이블).
- 변이로 확인한 민감 지점: 같은 키를 다른 해시로 보는 콜레이션 결함 형태(m_splitEq)는 의존성을 놓친다. 이는 리뷰가 HA로 재현한 utf8_gen trailing weight-0 결함이 해시 계층의 결함임을 모델에서도 보여 준다.
- 새 결함: 설계 중심부(라벨 계산, history 비우기 floor, 발행·락 해제 순서, gate, retire, 마커)에서는 찾지 못했다.

한계
- 3절 단순화 목록이 모델 밖이다. 특히 INCR 조각·컨테이너 sysop, long transaction 분기, 슬레이브 오류 주입, failover는 기존 모델에서 따로 봤고 이번 통합 모델에는 없다.
- 트랜잭션 4개 이상은 전수 검사를 끝내지 못했고 시뮬레이션은 증명이 아니다. 시뮬레이션은 기지 결함을 1분 안에 찾았지만, 90초 실행 한 번은 놓쳤다.


## 7. 2차: 규모 확대와 세션 독립 실행 큐 (2026-11-07 22:50~)

시정 사항
- 24시간 기준을 어겼다. mo_t3k2(22분), s1_inter(25분), moc_t4k3(1시간 2분), moc_t4k2(1시간), moc1_t5k3(1시간 31분), s2_lite(5시간 15분), e1_t4k3w3(5시간 12분)를 "큐가 계속 는다"는 이유로 중단했는데, 이 이유로는 멈추면 안 된다. 지시 메시지(16:08, 21:48)는 22:50에 받았다. 일곱 실행을 모두 큐에 다시 넣어 24시간까지 돌린다.
- s2_lite 최종 결과: 트랜잭션 3, 키 2, 워커 2, history 용량 2, 크래시 1, 전수 → 17:16에 5시간 15분 만에 중단. 그때까지 위반 없이 7억 344만 고유 상태, 깊이 45, 큐 6,652만. 완료가 아니다. 큐에 다시 넣었다(아래 재실행 결과로 대체 예정).

모델 변경 (규모 확대용)
- 키를 모델값(k1..kn)으로, serial을 별도 모델값(s1, s2)으로 바꿨다. 이전 숫자 키에서는 큰 시뮬레이션 설정의 Serials={9}가 행 키 9와 겹치는 문제가 있었다.
- 해시: Hash(k)=k, 서로 다른 키의 충돌은 CollidePair(같은 해시를 쓰는 키 집합)로 두고, 같은 키가 다른 해시인 변이는 HashMode="splitEq"로 둔다.
- 키 대칭: CollidePair가 비어 있으면 Hash가 키에 대해 항등이고 특정 키를 이름으로 쓰는 정의가 없으므로 키 순열이 건전하다. 트랜잭션 대칭과 함께 TxnKeySym으로 쓴다. 대칭 집합은 WritesetE2ESym.tla(WritesetE2E를 확장)로 분리했다. TLC가 시작할 때 상수 정의를 모두 계산하므로 30개 트랜잭션의 Permutations가 시뮬레이션을 시작도 못 하게 막았기 때문이다(23:02 확인). 전수 검사는 SYMMETRY가 있는 cfg에서 WritesetE2ESym을, 시뮬레이션은 WritesetE2E를 쓴다.
- 대칭의 작은 흠: 마스터 재시작에서 진행 중 트랜잭션의 LOG_ABORT 순서를 CHOOSE로 정한다. 순열 아래에서 그 순서가 바뀔 수 있으나 ABORT끼리의 순서는 슬레이브 결과에 영향이 없다.
- VIEW: 결과에 쓰이지 않는 보조 변수가 사실상 없어 쓰지 않았다. wseq는 FinalState, sdb 순서는 ConflictOrder에 필요하다. 마스터 작업 상태는 이미 넘겨주는 시점에 초기화해 합친다(3절 8번).
- 트랜잭션별 키 범위는 따로 제한하지 않고 MaxOps(동작 수)로 묶는다.
- 확인: 키 대칭을 넣은 s1이 위반 없이 3,899,930 상태(이전 6,924,225), 충돌 s1_collide가 6,933,720 상태(이전과 같음), m_splitEq와 m_markerTrunc가 이전과 같은 반례를 냈다.
- 큰 시뮬레이션 끝까지 도는지 확인: 트랜잭션 30, 키 10, 워커 10 설정에 NeverFinish(마스터 정지·슬레이브 비움·적용 1건 이상이면 위반)를 걸어 돌렸다. 317단계에서 반례가 나왔고, 그 실행에서 30개 트랜잭션이 모두 시작해 11 커밋, 19 abort, serial 조각 15개였으며, 단위 25개가 적용되고 크래시 5회를 겪었다. 따라서 깊이 상한 1,200이면 충분하다.

세션 독립 큐
- results/run_e2e_queue.sh, 큐 results/e2e-queue.txt, 결과 한 줄 요약 results/e2e-summary.txt, 드라이버 로그 results/e2e-queue.log.
- 동시 2개, -workers 16, 메타디렉터리 tlc-meta/e2e/<이름>.
- 가드: 메타디렉터리 300GB 초과 → DISK_STOP_300G, 24시간 → TIME_STOP_24H, 둘 다 자기 TLC PID만 종료하고 다시 돌리지 않는다. 시뮬레이션은 줄에 적은 초만큼 돌린다.
- HA 프로세스가 있으면 새 실행을 시작하지 않고 5분마다 다시 본다.
- 결과 종류는 OK / VIOLATION <불변식> / TIME_STOP_24H / DISK_STOP_300G / ERROR이고, ERROR만 원인을 고친 뒤 손으로 다시 넣는다.
- 큐 줄에 #RUN <pid> / #DONE <결과>를 붙인다. 드라이버를 다시 띄우면 살아 있는 #RUN은 그대로 세고, 죽은 #RUN은 다시 시작한다.
- 23:17 기동, 23:19 통계 파싱 수정 뒤 드라이버만 재기동(TLC는 그대로). 처음 두 실행(moc_t4k3, sim_t30k10-101)은 수정 전 작업자가 돌리므로, 24시간에서 멈추면 요약 줄의 상태 수가 비어 있을 수 있다. 그때는 out 파일의 마지막 Progress 줄을 기준으로 한다.
- 큐 순서는 다음과 같다. 시뮬레이션이 한 칸에서 4시간씩 돌아 긴 전수와 섞인다.
  - 다시 넣은 실행: moc_t4k3, moc1_t5k3, moc_t4k2, s2_lite, e1_t4k3w3, mo_t3k2, s1_inter
  - 규모 확대 사다리: e1_t6k5w4(용량 3), e1_t5k5w4(용량 3), e1_t5k4w4(용량 2), e1_t5k4w3, e1_t4k4w4. 한 단계마다 차원을 하나씩 줄인다.
  - 큰 시뮬레이션: 트랜잭션 30·키 10, 25·8, 25·8 겹침 모드, 30·10 해시 충돌, 20·8 용량 2, 25·8 현재 코드(검출력 확인, 2시간). 모두 워커 10, 용량 3(따로 적은 것 제외), 크래시 5, serial 2, 각 4시간, seed 101~109.
- iCloud 동기화가 .conflictN 사본을 만든다. 본 파일 이름에만 쓰고 사본은 무시한다.
