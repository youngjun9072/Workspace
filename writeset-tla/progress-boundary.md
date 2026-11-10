# writeset 경계 시나리오 TLA+ 모델 진행 기록

대상 코드: PR #8052 브랜치 feature/CBRD-27508-parallel-applylogdb-writeset, HEAD 6bd39a696 (읽기 전용, git show로만 읽음). 행번호는 이 커밋 기준이며 파일명이 없으면 src/transaction/log_applier.c다.
모델: WritesetBoundary.tla, 설정 BND_*.cfg(bnd_mkcfg.py로 생성), 짧은 실행 bnd_run.sh, 긴 실행 results/run_bnd_queue.sh(세션과 분리된 큐), 결과 results/out-bnd-<이름>.txt, 한 줄 요약 results/bnd-summary.txt, 반례 요약 bnd_trace.py.
WritesetE2E.tla는 고치지 않았다.
시작: 2026-11-08 13:10.

## 1. 모델이 하는 일

WritesetE2E의 슬레이브 부분(링, gate, pending, in-flight, 워커, retire, required_lsa, 적용 정보 저장, 마커, 크래시 재시작)을 그대로 옮겨 오고, 마스터는 의존성 계산 대신 "sysop 주변에서 마스터가 쓸 수 있는 로그 모양"을 모두 만들어 내는 생성기로 바꿨다. 마스터 의존성 계산은 WritesetE2E에서 이미 검사했으므로, 여기서는 커밋 라벨을 정확한 writeset 값(같은 키를 쓴 마지막 커밋, 마지막 라벨 SYSOP_END floor 이상)으로 둔다.

마스터 로그 모양(코드 근거)
- X: 트랜잭션의 첫 레코드(prev_tranlsa NULL). 슬레이브는 이 레코드에서만 슬롯을 만든다(7561-7584).
- D: 복제 레코드. sysop 끝에서 NEED_FLUSH 레코드를 log_append_repl_info로 쓰고(log_manager.c 4013-4030) 그 뒤에 라벨과 SYSOP_END를 원자적으로 쓴다(4052-4077, 4905-4916). NEED_FLUSH에는 그 연산 자신의 레코드뿐 아니라 instant 모드가 도중에 꺼져 attach로 끝난 INCR이 남긴 레코드(query_executor.c 20545-20565)도 들어간다. D와 S 사이에는 다른 트랜잭션의 레코드가 낄 수 있고, 그 사이 마스터가 죽으면 D 뒤에 복구의 LOG_ABORT가 온다. WritesetE2E는 이 끼어듦을 넣지 않았다(단순화 1).
- S: 라벨 + 라벨 SYSOP_END. 같은 트랜잭션의 직전 경계 뒤에 D가 하나 이상 있어야 쓰인다(라벨은 레코드를 쓴 경우에만, 4052). 의존성은 커밋 순서 장벽 max(prev_commit, history_start)이고 history_start를 그 위치로 올린다.
- 컨테이너·중첩 sysop도 로그에는 같은 모양만 남는다. flush 표시가 열린 동안 끝나는 안쪽 연산은 아무것도 쓰지 않고(4003-4011), attach로 끝나면 쓰지 않으며(4311-4345), abort로 끝나면 라벨 없는 SYSOP_END만 쓰고 레코드를 버린다(4251-4302). 그래서 로그에 나타나는 모양은 "D 여러 개 뒤 S"뿐이다.
- C: 커밋 블록. COMMIT_NEED_FLUSH와 남은 NEED_FLUSH 레코드, 라벨, LOG_COMMIT을 prior_lsa_mutex 한 구간에서 이어 쓴다(5030-5054). 한 단계로 이어 붙인다.
- A: LOG_ABORT(사용자 롤백, 또는 마스터 복구가 쓰는 loser 롤백, log_recovery.c 5049).

슬레이브에 새로 넣은 것
- la_set_repl_log(4573-4604): 슬롯이 없으면 레코드를 버린다. 항목 수가 LA_MAX_REPL_ITEMS(모델 상수 MaxItems, 코드 1000)에 이르면 긴 트랜잭션으로 바꿔 머리 항목과 last_lsa만 남기고, 적용할 때 로그에서 그 trid의 복제 레코드를 머리부터 last_lsa까지 다시 읽는다(7145-7223).
- la_detach_sysop_fragment(7245-7311): 긴 트랜잭션이면 슬롯 전체를 조각으로 옮기고 start_lsa = 머리 항목(7283), 아니면 SYSOP_END 이하 항목을 옮기고 start_lsa = 첫 항목(7307). 항목이 없으면 la_coordinator_complete_without_task.
- FixFragStart: "none"(현재 코드), "short"(리뷰 suggestion 블록대로 7307만 바깥 슬롯 start_lsa로), "both"(7283과 7307 둘 다).
- la_find_required_lsa(2312-2380): 슬롯(tranid > 0), in-flight 태스크의 apply->start_lsa, pending 태스크의 apply->start_lsa 중 최소, 없으면 final_lsa.

시나리오 2(워커 실패, FailModel=TRUE)
- 워커가 항목을 하나씩 적용한다(la_apply_repl_log 6996-7110). 결과는 성공, 비재시도 오류(항목 또는 부분 실패 flush의 행 하나가 fail_counter로 세고 버려짐, 6018-6025와 7088-7097), 재시도 오류 뒤 서버가 slave 트랜잭션을 이미 롤백한 경우(같은 항목만 다시 시도, 7077-7086) 셋이다.
- flush 실패: 재시작 대상 행 오류(6000-6015) 또는 교착 희생자로 xlocator_repl_force 호출 전체 실패(locator_sr.c 7240-7246) → goto end → 오류 결과.
- 마커 INSERT와 커밋(950-958): 성공, 커밋 전 실패, 서버는 커밋했지만 응답을 잃은 실패.
- 오류가 나면 워커가 slave 트랜잭션을 롤백하고(943-948) 오류 결과를 낸다. 코디네이터는 in-flight 머리의 오류 결과에서 멈추고(log_applier_coordinator.cpp 527-538) 재시작한다. 크래시는 어느 단계에서나 가능하며 열린 slave 트랜잭션은 롤백된다.

시나리오 3(failover, Failover=TRUE)
- 마스터가 멈춘(죽은) 뒤 슬레이브가 끝까지 읽고 la_coordinator_drain_complete(pending, in-flight, 링이 모두 비었음, log_applier_coordinator.cpp 275-278)일 때만 DONE을 보고하고(7874-7912) 승격한다. 그 뒤 슬레이브는 더 적용하지 않는다.

## 2. 불변식

- RequiredStored(시나리오 1의 질문): 저장된 required_lsa는 할 일이 남은 트랜잭션(로그에서 아직 열려 있거나, 적용 안 된 단위가 있음)의 첫 레코드를 넘지 않는다.
- QuietAllApplied: 마스터가 멈추고 슬레이브가 다 비우면 모든 단위(항목이 있는 S·C)가 적용됨(유실 없음).
- NoDuplicate, OnlyUnits: 단위는 많아야 한 번, 단위만 적용.
- UnitAtomic: 커밋된 slave 트랜잭션은 그 단위의 항목을 정확히 담는다. 빠지는 항목은 fail_counter로 센 비재시도 오류뿐이다.
- MarkerWithData: 마커는 그 단위의 데이터와 함께만 있다.
- ConflictOrder: 충돌하는 두 단위(같은 트랜잭션, 키 공유, 라벨 SYSOP_END는 장벽)는 로그 순서대로 적용된다.
- PrefixStored: 저장된 committed_lsa 이하 단위는 모두 적용됨.
- PromoteComplete: 승격했으면 모든 단위가 적용됨.
- 교차 확인용(반례가 나야 정상): NoLongFragment(긴 트랜잭션 조각 경로에 실제로 도달함), NeverPromote.

## 3. 단순화 목록

1. 라벨과 SYSOP_END(또는 COMMIT)를 한 레코드로 합침. 둘은 prior_lsa_mutex 한 구간에서 이어 쓰이고 required_lsa는 슬롯 시작·태스크 시작·final_lsa이므로 그 사이에 떨어지지 않는다. 라벨 없는 SYSOP_END(abort 형태, 레코드 없는 sysop)는 슬레이브가 흔적만 남기므로 넣지 않음.
2. 커밋 라벨은 정확한 writeset 값으로 둠(마스터 계산은 WritesetE2E에서 검사).
3. trid 재사용 없음. trid는 log_Gl.hdr.next_trid로 단조 증가하고(log_tran_table.c 1801-1836) 복구도 그 값을 이어 간다. 2^31 순환은 넣지 않음.
4. 트랜잭션의 첫 레코드는 X. checksumdb처럼 복제 레코드가 첫 레코드인 경우는 슬롯 시작 = 첫 항목이라 X를 쓴 경우보다 위험하지 않다.
5. 마커는 시작할 때 읽은 집합(la_load_applied_tx_markers, 9772-9776)이고 실행 중 같은 단위가 두 번 제출되지 않으므로, 모델은 DB의 마커 행 집합을 바로 본다(WritesetE2E와 같음). 재시작은 프로세스 재시작이다(9850-10364의 바깥 루프는 need_shutdown이면 끝난다).
6. 슬롯 배열 크기, 링 용량(RingCap 50), 메모리 한도, 지연 복제(replica)는 넣지 않음.
7. 시나리오 2의 flush 시점: 행은 워커 workspace에 쌓였다가 LA_MAX_UNFLUSHED_REPL_ITEMS 또는 끝에서 flush된다. 롤백·크래시 때 flush 여부와 상관없이 slave 트랜잭션 전체가 사라지므로, flush 시점은 오류 종류(행 오류, 호출 실패)로만 구분한다.
8. 순차 합성(Interleave=FALSE)과 겹침(Interleave=TRUE)을 모두 돌린다. 겹침은 트랜잭션이 열린 채 저장이 일어나는 경우를 직접 본다.

## 4. 실행 기록

각 줄: 이름: 설정 → 결과, 고유 상태, 깊이, 시간, 메타디렉터리 최대. 기본값(bnd_mkcfg.py): 트랜잭션 2, 키 1, 트랜잭션당 sysop D 2·라벨 SYSOP_END 1·커밋 D 1, MaxItems 1(긴 트랜잭션 분기에 바로 닿게), 워커 2, 큐 2, 링 50, 크래시 1, 순차 합성, FixFragStart="both", 대칭(트랜잭션).

시나리오 1
- s1_bug: 현재 코드(none), MaxItems 5(긴 분기 없음), MaxCD 0 → RequiredStored 위반, 8,326, 12, 1초. 기지 결함 재현(5절 반례 1).
- s1_none: 현재 코드, RequiredStored 빼고 → QuietAllApplied 위반, 77,555, 17, 5초. 실제 유실까지 확인(반례 1과 같은 경로).
- s1_fix: 기본(both) → 위반 없음, 4,194,892, 62, 2분 30초, 352MB.
- s1_short: 리뷰 suggestion 블록만(7307) → QuietAllApplied 위반, 128,466, 19, 5초(5절 반례 2, 긴 트랜잭션 분기 7283).
- s1_short_req: 같은 설정, RequiredStored만 → 위반, 24,887, 14, 5초.
- s1_inter: 기본 + 겹침 → 위반 없음, 9,554,350, 62, 6분 51초.
- 큐(13:38 기동): s1_crash2_inter, s1_w1_inter, s1_s2(sysop D 3·S 2), s1_k2cd2(키 2·커밋 D 2), sim1_t4_none(현재 코드 시뮬레이션 검출력), sim1_t4, s1_s2_inter_c2, sim1_t6. 결과는 아래에 덧붙인다.
- s1_crash2_inter: 겹침 + 크래시 2 → 위반 없음, 20,720,740, 63, 14분, 674MB.
- s1_w1_inter: 겹침 + 워커 1(직렬 경로) → 위반 없음, 9,014,566, 56, 7분, 440MB.
- s1_s2_inter_c2: sysop D 3·S 2·커밋 D 2 + 겹침 + 크래시 2 → 37분 동안 위반 없이 120,509,370 고유 상태(큐 3,033만, 메타 13.5GB)에서 수동 중단. s1_s2와 이 실행이 두 슬롯을 모두 차지해 시나리오 2·3의 짧은 실행이 밀려 있었고, 상태 증가 속도로 보아 50GB 한도 전에 끝날 가능성이 낮아 짧은 실행을 먼저 돌리려고 멈췄다(완료 아님).
- s1_k2cd2: 키 2·커밋 D 2 → 위반 없음, 22,404,440, 66, 14분, 878MB.
- sim1_t4_none: 현재 코드(none), 트랜잭션 4·키 2·sysop D 3·S 2·커밋 D 2·MaxItems 2·겹침·워커 3·크래시 3, 시뮬레이션(seed 7, 깊이 300) → PrefixStored 위반, 3,363만 상태 검사, 5분. 시뮬레이션의 검출력 확인용이며 기지 결함이다(5절 반례 4).
- sim1_t4: 같은 크기, 리뷰 수정(both) → 1시간 시뮬레이션(seed 11, 깊이 300), 3억 2,395만 상태 검사, 위반 없음.
- sim1_t6: 트랜잭션 6·키 3·sysop D 3·S 2·커밋 D 3·MaxItems 2·겹침·워커 4·크래시 4, 리뷰 수정(both) → 1시간 시뮬레이션(seed 13, 깊이 500), 1억 6,711만 상태 검사, 위반 없음.

시나리오 2 (FailModel=TRUE; 비재시도 오류·flush 실패·커밋 실패(커밋 전/커밋 후 응답 유실)·크래시)
- s2_base: 기본 크기, 오류 2회 → 직접 실행 28분 제한에 걸려 중단(TIME_STOP). 위반 없이 68,436,997 고유 상태, 큐 531만, 2.8GB. 완료가 아니므로 큐에 다시 넣었다(12시간 제한).
- s2_sar: 서버 롤백 뒤 같은 항목만 재시도(AllowServerAbortRetry) → UnitAtomic 위반, 16,807, 16, 5초(반례 3, 기지 후보).
- m_noAbortOnError(변이): 오류 뒤 워커 롤백을 뺌 → OnlyUnits 위반, 31,852, 18, 5초.
- s2_small: sysop D 1·커밋 D 1, 비재시도 오류·flush 실패·커밋 실패, 오류 2회 → 위반 없음, 9,188,931, 84, 5분, 425MB.
- sim2_t4: 트랜잭션 4·키 2·sysop D 2·S 2·커밋 D 2·MaxItems 2·겹침·워커 3·크래시 3, 비재시도 오류·flush 실패·커밋 실패(오류 3회)와 failover를 함께, 리뷰 수정(both) → 1시간 시뮬레이션(seed 17, 깊이 400), 7억 5,359만 상태 검사, 위반 없음.
- s2_mid: 기본 크기(sysop D 2, 긴 트랜잭션 분기 도달), 비재시도 오류·flush 실패·커밋 실패(커밋 전/커밋 후 응답 유실), 오류 1회 → 위반 없음, 34,444,676, 79, 16분, 1.1GB. s2_small은 sysop D가 1개라 긴 트랜잭션 분기(두 번째 항목에서 전환)에 닿지 않으므로 이 실행을 따로 넣었다.
- 큐: s2_base(오류 2회, 12시간 제한으로 다시).

시나리오 3 (Failover=TRUE; 마스터가 열린 트랜잭션을 남긴 채 죽을 수 있음)
- san_promote: NeverPromote → 위반(승격 경로 도달), 311, 8.
- s3_none: 현재 코드 → PromoteComplete 위반, 148,261, 18, 5초(반례 1과 같은 원인: 재시작으로 조각을 잃은 뒤 DONE·승격).
- m_doneNoInflight(변이): DONE이 in-flight·링을 보지 않음 → PromoteComplete 위반, 3,306, 10, 5초.
- s3_base: failover, 기본 크기 → 위반 없음, 5,565,521, 63, 3분, 329MB.
- s3_doneNoPending: DONE 검사에서 pending만 뺀 변이 → 위반 없음, 5,565,521(s3_base와 같음), 63, 3분. 예상대로다. pending 태스크도 제출 때 pending에 넣기 전에 ring(commit-order 순서표)에 먼저 들어가므로(la_coordinator_submit_task의 la_gate_order_push, src/transaction/applier/log_applier_coordinator.cpp 642가 la_pending_push 680보다 앞) ring이 비었다는 조건이 pending이 비었다는 조건을 포함한다. drain_complete의 pending 검사는 중복 방어이고, 빠져도 이 모델 범위에서는 결과가 같다.
- s3_fail: failover + 비재시도 오류·flush 실패·커밋 실패(오류 1회), D 1·커밋 D 1 → 위반 없음, 3,345,503, 70, 2분, 328MB.
- s3_inter: failover + 겹침(마스터가 도는 중에 슬레이브가 읽고 재시작) + 크래시 2 → 위반 없음, 23,672,103, 64, 15분, 861MB.

변이(반례가 나야 정상)
- m_reqNoTasks: required_lsa가 in-flight·pending 태스크를 보지 않음(리뷰 02 수정 전 형태), FixFragStart=both → QuietAllApplied 위반, 22,973, 15, 5초. 반례: X(1) D(2) S(3) D(4) A(5), 조각 태스크가 in-flight인 채 ABORT가 슬롯을 비워 required=final(6) 저장 → 재시작 → 조각 유실.

교차 확인
- san_long: NoLongFragment → 위반(긴 트랜잭션 슬롯에서 조각이 떼어지는 경로에 도달), 4,064, 11, 5초.

## 5. 반례와 코드 대응

### 반례 1 (기지 결함, 현재 코드): 조각 start_lsa = 첫 항목, 바깥 ABORT, 재시작 (s1_bug, s1_none, s3_none)
로그: X(1) D(2) S(3) A(4), 트랜잭션 하나.
1. X(1) 읽음: prev_tranlsa NULL이라 슬롯 생성, start_lsa=1 (7562-7584).
2. D(2): 슬롯에 항목 (la_set_repl_log 4573-4604).
3. S(3): 라벨이 맞고 항목이 있어 조각 분리, 조각 start_lsa = 첫 항목 2 (7307), 태스크 제출. 앞선 커밋을 기다리거나 워커가 아직 잡지 않아 in-flight.
4. A(4): 슬롯을 비움 (7644-7653, la_clear_applied_info 4532-4543).
5. la_log_commit: 슬롯 없음, in-flight 조각 start=2 → required_lsa=2 저장 (2333-2366, 7994-8010).
6. 크래시 후 재시작: committed_lsa=required_lsa=2 (9811), 2부터 읽음.
7. D(2): prev_tranlsa가 NULL이 아니라 슬롯을 만들지 않고, 슬롯이 없어 버림 (4579-4584).
8. S(3): 라벨은 맞지만 슬롯이 없어 complete_without_task (7372-7383). 조각이 영영 적용되지 않음.
모델 인공물이 아닌 근거: 각 단계가 hgryoo 님 HA 재현 trace(`items=1 long=0` 조립 → 재시작 `required LSA` → `complete_without_task` → `items=0 action=defer`)와 그대로 맞는다. failover에서도 같은 원인으로 DONE 뒤 승격 상태에 조각이 없다(s3_none, PromoteComplete).

### 반례 2 (리뷰 suggestion을 7307에만 넣은 경우): 긴 트랜잭션 분기 7283 (s1_short, s1_short_req)
로그: X(1) D(2) D(3) S(4) A(5), MaxItems=1.
1. X(1): 슬롯 start=1.
2. D(2), D(3): 두 번째 항목에서 num_items >= LA_MAX_REPL_ITEMS라 긴 트랜잭션으로 바뀌어 머리 항목 2와 last_lsa=3만 남음 (4591-4597).
3. S(4): outer->is_long_trans라 슬롯 전체가 조각으로 가고 start_lsa = fragment->head->lsa = 2 (7274-7290, 7283). suggestion 블록은 7307만 바꾸므로 이 분기는 그대로다.
4. A(5): 슬롯 비움. la_log_commit: required_lsa=2 저장. 재시작 뒤 반례 1의 7-8과 같아 조각(항목 2개) 유실.
판정: 코드상 확정(같은 패턴의 다른 줄). 리뷰어도 "위쪽 long transaction 분기도 같은 식일 것 같습니다"라고 적었다. 수정은 7283도 `LSA_COPY (&fragment->start_lsa, &outer->start_lsa);`로 바꾸는 것이다.
도달 조건(추정): 코드의 LA_MAX_REPL_ITEMS는 1000이다. 한 라벨 SYSOP_END 앞에 같은 트랜잭션의 NEED_FLUSH 레코드가 1000개 이상 쌓여야 한다. instant INCR 한 번은 결과 행이 1개라(query_executor.c 20305의 tuple_cnt == 1 assert) 그 sysop 하나로는 1000개가 안 된다. 실제로 쌓일 수 있는 길은 instant 모드가 도중에 꺼져 attach로 끝난 INCR이 매번 NEED_FLUSH를 남기고, 그 사이에 비어 있지 않은 sysop 끝이 한 번도 없다가 다음 serial 갱신이나 페이지 할당 sysop에서 한꺼번에 쓰이는 경우다. 이 경로가 1000번 이어질 수 있는지는 확인하지 못했다(HA 미재현). 그래도 수정 비용이 한 줄이고 같은 결함 패턴이므로 둘 다 고치는 것을 권한다.

### 반례 4 (기지 결함의 다른 증상, 현재 코드): sim1_t4_none, PrefixStored
트랜잭션 4개가 섞인 시뮬레이션 반례다. 로그(LSA:종류+트랜잭션): 1:X1 2:D1 3:D1 4:C1 5:X3 6:X4 7:D3 8:D3 9:C3(dep 4) 10:D4 11:S4(dep 9) 12:A4 13:X2 14:D2 15:D2 16:C2(dep 11). 문제의 트랜잭션은 t4 하나이고 모양은 반례 1과 같은 X D S A다(X4=6, D4=10, S4=11, A4=12). 나머지 트랜잭션은 커밋 순서 대기와 저장 시점을 만들어 줄 뿐이다.
1. X4(6)를 읽어 t4 슬롯 생성, start_lsa=6 (7561-7584). D4(10)는 그 슬롯의 항목 (la_set_repl_log 4573-4604).
2. S4(11): 라벨이 맞아 조각 분리, 조각 start_lsa = 첫 항목 10 (7307). 의존 9(C3)가 아직 커밋되지 않아 pending에 들어감.
3. A4(12): t4 슬롯 비움 (7639-7650). 이제 t4를 대표하는 것은 start_lsa=10인 조각 태스크뿐이다.
4. C3(9)가 적용·retire되어 committed_lsa=9, 조각 11이 pending에서 in-flight로 감. la_log_commit이 required_lsa = 조각 start 10을 저장 (2312-2380, 7994-8010). 이 위치는 t4의 첫 레코드 6보다 뒤다(RequiredStored가 깨지는 지점, 반례 1의 5와 같음).
5. 조각이 적용되기 전에 크래시. 재시작: committed_lsa = required_lsa = 10 (9811), 10부터 읽음.
6. D4(10): prev_tranlsa가 NULL이 아니라 슬롯을 만들지 않고, 슬롯이 없어 버림 (4579-4584).
7. S4(11): 라벨은 맞지만 슬롯에 항목이 없어 la_coordinator_complete_without_task (7372-7383). ring에는 완료로 들어가지만 committed_lsa는 retire 때에만 오르므로 아직 10이다. la_log_commit이 required_lsa=11을 저장.
8. 두 번째 크래시. 재시작에서 committed_lsa = required_lsa = 11 (9811), la_log_commit이 committed_lsa=11을 저장. 조각 11은 적용되지 않았는데 저장된 committed_lsa가 그것을 넘었다(PrefixStored 위반).
판정: 새 경로가 아니라 반례 1과 같은 결함(조각 start_lsa = 첫 항목, 7307)이 다른 불변식으로 드러난 것이다. 원인 단계(2~6)는 반례 1과 같고, 7~8은 유실 뒤 저장 위치가 그 단위를 넘어가는 후속 증상이다. 조각 start_lsa를 바깥 슬롯 start(6)로 두면 4에서 required_lsa=6이 저장되고 재시작이 X4부터 읽어 슬롯과 항목을 다시 만든다. 같은 크기의 리뷰 수정 모델(sim1_t4)은 1시간 시뮬레이션에서 위반이 없었다. 시뮬레이션이 4트랜잭션·크래시 3 크기에서 이 결함을 5분 안에 찾았으므로, 같은 크기의 수정 모델 시뮬레이션 결과에 일정한 검출력이 있다는 근거로 쓴다(전수 검사는 아님).

### 변이 반례
- m_reqNoTasks (QuietAllApplied): X(1) D(2) S(3) D(4) A(5). required_lsa가 태스크를 보지 않으면 ABORT 뒤 슬롯이 없어 required = final(6)이 저장되고, 재시작이 6부터 읽어 in-flight였던 조각(3)이 사라진다. 리뷰 02 수정(2338-2345)이 막는 경로다.
- m_noAbortOnError (OnlyUnits): X1(1) D1(2) C1(3) X2(4) C2(5). 워커가 C1의 항목 2를 적용한 뒤 flush 실패로 오류를 내면서 롤백을 빼면, 같은 워커가 다음에 잡은 C2(항목 없음)의 커밋에 항목 2가 실려 C2 이름으로 커밋된다. 943-948의 db_abort_transaction이 막는 경로다(주석이 이 경우를 그대로 설명한다).
- m_doneNoInflight (PromoteComplete): DONE이 in-flight와 링을 보지 않으면 조각 태스크가 적용되기 전에 승격한다. drain_complete(log_applier_coordinator.cpp 275-278)가 막는다.

### 반례 3 (기지 후보, develop과 같은 루프): 서버 롤백 뒤 같은 항목만 재시도 (s2_sar, UnitAtomic)
로그: X(1) D(2) D(3) C(4).
1. 워커가 C(4)를 잡아 항목 2를 적용(행은 workspace에 쌓이거나 flush됨).
2. 항목 3에서 재시도 대상 오류(LA_RETRY_ON_ERROR, log_applier.h 34-46의 ER_LK_UNILATERALLY_ABORTED 등)가 나고, 그 오류가 서버의 트랜잭션 롤백을 동반한 경우 항목 2의 변경은 사라진다.
3. 7082-7090이 같은 항목 3만 다시 시도하고 통과.
4. flush, 마커 INSERT(938-941), 커밋 성공 → 항목 2 없이 C(4)가 마커와 함께 커밋. 재시작해도 마커 때문에 건너뛰므로 항목 2는 영구 유실.
판정: findings.md "HA 재현이 필요한 후보"의 재시도 오류 항목과 같다. develop의 직렬 루프와 같은 동작이라 이 PR의 회귀는 아니다. 행 항목의 교착은 xlocator_repl_force가 호출 전체를 실패시켜(locator_sr.c 7240-7246) flush 오류 → 롤백 → 재시작으로 가므로 이 경로가 아니다. 남는 자리는 문장 항목 실행이나 클래스 조회에서 서버가 트랜잭션을 롤백하는 오류이고, 그런 오류가 실제로 이 지점에서 나는지는 확인하지 못했다(추정). 락 타임아웃(ER_LK_OBJECT_TIMEOUT_*)은 트랜잭션을 롤백하지 않으므로 재시도해도 유실이 없다.

## 6. 중간 결론 (2026-11-08 15:50, 큐 진행 중)

- 리뷰 수정을 7283·7307 둘 다 넣으면 시나리오 1·3에서 완료한 전수 실행(최대 2,240만 상태, s1_k2cd2)과 트랜잭션 4개 1시간 시뮬레이션(sim1_t4, 3억 2,395만 상태 검사)에 반례가 없다. 같은 크기의 현재 코드 시뮬레이션(sim1_t4_none)은 5분 만에 기지 결함을 다시 찾았다(반례 4, 반례 1과 같은 원인). 저장된 재시작 위치가 할 일이 남은 트랜잭션의 첫 레코드를 넘는 경우는 조각 start_lsa 두 줄 말고는 찾지 못했다.
- 리뷰 suggestion 블록(7307만)만 넣으면 긴 트랜잭션 분기(7283)로 같은 유실이 남는다(반례 2). 도달 조건은 한 조각에 1000개 이상 레코드라 HA 도달성은 추정.
- 시나리오 2는 기지 후보(반례 3) 외에 위반이 없으나 기본 크기 전수가 아직 끝나지 않았다.
- 큐에 남은 실행 결과는 results/bnd-summary.txt에 한 줄씩 쌓인다.
