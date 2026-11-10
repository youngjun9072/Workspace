---
tags: [writeset, tla, slave]
---
# 슬레이브 coordinator / gate / worker TLA+ 검사 진행 기록

대상: PR #8052 (`origin/feature/CBRD-27508-parallel-applylogdb-writeset`)의 슬레이브 병렬 적용 경로. 코드는 git show로만 읽었다. 행 번호는 그 브랜치 기준이다.

## 1. 코드에서 읽은 동작

### task 생성
- coordinator는 로그를 순서대로 읽고 `la_log_record_process()`(log_applier.c:7540)에서 레코드 종류별로 처리한다.
- 트랜잭션의 첫 레코드(prev_tranlsa가 NULL)를 만나면 그 trid의 슬롯을 만들고 start_lsa를 그 레코드 위치로 둔다(7561~7584). 슬롯은 첫 레코드에서만 만들어지므로, 재시작해서 첫 레코드 뒤부터 읽으면 그 트랜잭션의 복제 항목은 버려진다(la_set_repl_log의 "fail to find out").
- `LOG_DUMMY_WSET_LABEL`은 단일 보관 칸에 저장되고(log_applier_wset_label.cpp), 바로 다음 같은 trid의 COMMIT 또는 SYSOP_END가 가져간다. 마스터는 라벨과 경계 레코드를 prior_lsa_mutex 안에서 연달아 쓰므로(log_manager.c:5041~5051, 4905) 보관 칸이 하나여도 다른 트랜잭션 라벨에 덮이지 않는다.
- COMMIT(committed_lsa보다 뒤): `la_coordinator_process_commit()`(7477)이 task를 만든다. apply=슬롯, has_items=슬롯에 항목이 있음. dependency는 `la_coordinator_set_commit_dependency()`(7440): 라벨 값 → 자기 fragment의 SYSOP_END 위치까지 올림 → 항목이 있는데 라벨이 없으면 ring tail(직전에 읽은 경계)까지 올림.
- 라벨 붙은 SYSOP_END(committed_lsa보다 뒤)에서 슬롯에 항목이 있으면 `la_detach_sysop_fragment()`로 항목을 떼어 fragment task를 만들고 슬롯의 last_sysop_fragment_lsa를 기록한다(7323~7370). 항목이 없으면 `la_coordinator_complete_without_task()`로 ring에 넣고 즉시 완료 표시한다(7372~7384). 라벨 없는 SYSOP_END는 아무것도 하지 않는다.
- ABORT는 슬롯 항목을 비우고 tranid를 0으로 돌린다(7644~7654, la_clear_applied_info). last_sysop_fragment_lsa는 지우지 않는다.
- committed_lsa 이하의 COMMIT은 슬롯만 비운다(7638~7641).

### 시작 조건(gate)
- `la_coordinator_submit_task()`(coordinator.cpp:611): commit-order ring 자리를 기다린 뒤 frontier가 NULL이면 committed_lsa로 시작(`la_gate_set_initial_frontier`), 라벨이 ring tail(ring이 비면 frontier)보다 크면 그 값으로 내림(`la_gate_bound_dependency`, gate.cpp:196), ring에 push.
- 워커 1개면 gate 없이 바로 task queue에 넣는다(648~656). 단일 워커가 FIFO로 꺼내므로 커밋 순서 적용이다.
- 워커 2개 이상이면 pending 중 통과한 것을 먼저 배정(drain_ready)한 뒤, 자기 gate가 통과이고 task queue가 차지 않았으면 배정, 아니면 pending에 넣는다.
- gate 조건(gate.cpp:324): dep가 NULL이거나 frontier가 NULL이 아니고 dep ≤ frontier. frontier는 ring 앞에서부터 빈틈없이 완료된 마지막 경계 LSA(gate.cpp:262).
- pending은 넣은 순서로 훑어 통과한 것부터 꺼낸다. ready_ns가 이미 찍힌 task는 gate를 다시 보지 않는다(pending.cpp:143).

### 완료 보고
- worker는 task를 적용·flush·마커 INSERT·커밋하고 result를 result queue에 넣는다(worker.cpp:315, log_applier.c:911). 오류면 롤백하고 오류 코드를 result에 담는다. flush 오류·서버 다운이면 result를 넣은 뒤 워커 스레드가 끝나고 applier 종료를 요청한다.
- coordinator는 `la_coordinator_collect_and_retire()`에서 result를 모두 꺼내 in-flight entry에 붙이고, 성공한 COMMIT/SYSOP_END는 ring에서 완료 표시한 뒤 frontier를 전진시키고 drain_ready, retire를 한다(coordinator.cpp:286~352).

### committed / required 전진
- retire는 in-flight list를 배정 순서로 앞에서부터, result가 붙은 것만 처리한다. 오류 result를 만나면 그 오류를 반환해 applier가 종료된다(coordinator.cpp:516~539).
- retire 때 `la_coordinator_retire_entry()`(log_applier.c:741)가 슬롯을 비우고 committed_lsa를 frontier로 올린다. store_progress가 주기마다 committed_lsa와 그 시점 la_Info.required_lsa를 저장하고 committed_lsa 이하 마커를 지운다(1172).
- required_lsa는 `la_log_commit()`(7994)에서만 다시 계산한다(`la_find_required_lsa`, 2312): tranid>0 슬롯의 start_lsa, in-flight·pending task 슬롯의 start_lsa 중 최소, 없으면 final_lsa. store_progress는 이전에 계산한 값을 그대로 저장한다(더 낮은 값이라 보수적).
- 재시작 시 committed_lsa를 저장된 required_lsa로 두고(9811) 그 위치부터 다시 읽는다. last_committed_lsa(저장된 committed_lsa) 이하이거나 마커가 있는 경계는 worker가 통째로 건너뛴다(6976).

### 오류·재시도
- 항목 하나의 재시도 대상 오류(la_retry_on_error, 잠금 timeout·deadlock 포함)는 같은 항목을 10초 뒤 다시 적용한다(7082~7091). 무시 대상이 아닌 다른 항목 오류는 세고 넘어간다. flush 오류·서버 다운만 result 오류가 된다.
- flush 오류(`LA_IS_FLUSH_ERROR`)는 result 오류 → worker 종료 + 종료 요청 → retire에서 오류 반환 → applier 재시작.

### long transaction
- 항목이 LA_MAX_REPL_ITEMS를 넘으면 첫 항목과 last_lsa만 남기고 적용 때 로그에서 다시 읽는다. start_lsa는 그대로라 required_lsa 계산은 같다.

## 2. 모델 (SlaveCoordinator.tla)

- 입력 로그는 Init에서 트랜잭션별 대본(D=복제 항목, S=라벨 붙은 SYSOP_END, C=COMMIT, A=ABORT)을 끼워 맞춰 만든다. 트랜잭션의 첫 레코드가 슬롯을 만든다. COMMIT의 키(k1, k2 부분집합)와 라벨 종류("ok"=이상적인 마스터 라벨, "miss"=라벨 없음, "floor"=커밋이 아닌 위치로 올린 라벨)를 함께 열거한다. 이상적 라벨은 키가 겹치는 앞선 COMMIT과 앞선 모든 라벨 SYSOP_END 중 최댓값, SYSOP_END의 라벨은 앞선 모든 경계의 최댓값이다.
- coordinator 동작: ReadRecord(레코드 하나 처리, submit·bound·drain·gate·pending·ring 자리 대기 포함), Collect(result 전부 수거 → ring 완료 표시 → frontier 전진 → drain → retire → 선택적 store_progress), LogCommit(la_log_commit: required_lsa 재계산 후 저장). worker 동작: Take, Finish(마커·last_committed_lsa 확인으로 건너뛰기, 적용 시 db에 추가와 마커 기록, 오류 주입). Restart: 저장된 required/committed로 다시 시작(슬롯·ring·pending·in-flight·큐 초기화, 마커와 db는 유지).
- 워커 1개면 gate 없이 큐에 넣는 경로를 따른다.
- 불변식: NoDuplicate(경계 하나는 한 번만 적용), OnlyNeeded, ConflictOrder(키가 겹치거나 한쪽이 SYSOP_END이거나 같은 트랜잭션이면 마스터 순서대로 적용), PrefixLive / PrefixStored(committed_lsa·저장된 committed_lsa 이하의 적용 대상 경계는 모두 적용됨), RequiredStored(아직 적용 안 된 경계가 있는 트랜잭션의 첫 레코드보다 저장된 required_lsa가 크지 않음), QuietAllApplied(다 읽고 다 비었으면 모두 적용됨), NotStuck(재시작을 빼고도 할 일이 있으면 진행 가능), NoInflightOverflow(in-flight가 찬 상태에서 배정 시도 없음, 정보용).
- 오류 모드: commit(비치명 result 오류, 워커는 계속), flush(워커 종료 + 종료 요청).

## 3. 실행 기록

모든 실행은 `timeout 900 ~/tools/tlc -workers 8`.

- base(2 트랜잭션, basic 대본, 라벨 ok, 워커 2, 큐 2, ring 3, 재시작 0): 오류 없음. 27,678 상태.
- 변이 확인: SerialOrder(기대 실패) 실패함. gate_off(gate 무시) → ConflictOrder 위반. no_bound(라벨 내리기 제거, floor 라벨) → NotStuck 위반(라벨이 자기 자신을 기다림, 리뷰 C1과 같은 현상). req_final(required를 final_lsa로) → RequiredStored 위반. no_marker(마커 무시, 재시작 1) → NoDuplicate 위반. adv_hole(frontier가 빈틈을 건너뜀)은 2 트랜잭션에서는 위반이 나오지 않았고 3 트랜잭션(dc 대본, 6레코드)에서 PrefixLive 위반. 불변식은 모두 변이에 반응한다.
- err_commit(비치명 result 오류 1회, 재시작 1): 오류 없음, 81,634 상태.
- err_flush(flush 오류 1회, 워커 종료, 재시작 1): 오류 없음, 80,722 상태.
- frag / w1 / small / three: 16:17에 동시에 띄웠다가 기계 메모리(251GB 중 여유 1GB, 스왑 소진, 다른 TLC 작업과 겹침)로 진행이 거의 멈춰 16:21에 중단했다. 하나씩 힙을 제한해 다시 돌린다.
- frag(2 트랜잭션, frag 대본, 라벨 ok·miss·floor, 6레코드, 재시작 1) 단독 재실행: 900초 timeout. 1,503,349 상태까지 위반 없음(부분 탐색). 기계 부하(load 94/80코어)로 속도가 떨어졌다. 출력은 results/out-frag-timeout.txt.
- 19:24부터 상태 디렉토리를 디스크(~/tools/tlc-meta/slave/<run>)에 두고 실행 후 지운다(/tmp가 RAM이라 메모리 압박). 동시에 두 개까지. 실행 스크립트 runq.sh, 출력 results/out-<run>.txt.
- 모델 변경(19:20): 종료 요청 뒤에도 Collect를 허용한다. 코드는 메인 루프를 빠져나온 뒤 한 번 더 collect_and_retire를 한다(log_applier.c:10350). 이 변경 전 결과(base, err_*, 변이 확인)는 종료 뒤 수거를 빼고 본 것이다.
- frag를 쪼갠다: frag_ok(라벨 ok, 재시작 1), frag_lab(라벨 3종, 재시작 0). w1은 5레코드로, small(큐 1, ring 2)은 5레코드·재시작 0으로, three(3 트랜잭션 dc)는 라벨 ok·miss·재시작 0으로 줄였다.

## 4. 발견

### 모델 검사 결과
지금까지 돌린 모든 현재 코드 모델에서 반례가 없다. 즉 이 추상화 범위(coordinator 레코드 처리, 라벨·fragment·ABORT·라벨 없음·floor 라벨, gate·pending·task queue·ring·in-flight·retire, committed/required 저장, 마커, flush·비치명 오류, 재시작, 워커 1개 경로)에서는 REAL DEFECT를 찾지 못했다. 변이를 넣으면 각 불변식이 반례를 내므로 검사 자체는 동작한다. 수정 전 required_lsa 계산(리뷰 수정 02번)은 반례로 재현된다.

### 코드에서 따로 확인한 관찰 (결함 판정 아님)
- 관찰 1, 라벨 보관 칸이 프로세스 안 재시작에서 초기화되지 않는다. `log_applier_wset_label.cpp`의 `la_Wset_label_stored/tranid/dependency_seq`는 파일 static이고 초기화 함수가 없다. 서버 다운으로 `la_apply_log_file`이 빠져나와 util_cs.c의 `retry:`로 같은 프로세스에서 다시 시작하면(리뷰 수정 07번과 같은 경로), LABEL(X)을 읽고 COMMIT(X)를 읽기 전에 멈춘 경우 X의 라벨이 남는다. 다시 읽기는 required_lsa(X의 첫 레코드 이하)부터라 X의 LABEL 레코드를 다시 읽어 덮어쓰므로 COMMIT(X)는 올바른 라벨을 받는다. 그 사이 X의 라벨 없는 SYSOP_END를 먼저 만나면 남은 라벨과 맞아 떨어진다. 슬롯에 항목이 없으면 complete_without_task로 이미 완료된 ring 항목만 하나 생겨 해가 없다. 항목이 있으면 바깥 트랜잭션 항목이 fragment로 떨어져 나가 따로 커밋되는데, 마스터는 트랜잭션 중간에 복제 레코드를 로그에 쓸 때 항상 그 sysop에 라벨을 붙이므로(log_manager.c:4030~4076, locator_sr.c:13181, repl_flushed) 라벨 없는 SYSOP_END 시점에 슬롯에 항목이 남아 있는 경로를 찾지 못했다. 판정: 해가 되는 경로 없음(정리 대상). 재시작 때 `la_wset_label_take(…, NULL)` 같은 초기화를 넣으면 깔끔하다.
- 관찰 2, ABORT로 비운 슬롯은 last_sysop_fragment_lsa를 지우지 않고(la_clear_applied_info, 설계 문서 3.5절도 의도라 적음), `la_add_apply_list`가 빈 슬롯을 다른 trid에 줄 때도 이 값을 지우지 않는다(log_applier.c:3948~3951). 그래서 새 트랜잭션의 COMMIT dependency가 남의 옛 fragment LSA까지 올라갈 수 있다. 그 LSA는 이번 실행에서 ring에 들어간 더 이른 경계라 frontier가 결국 지나가므로 교착이나 순서 위반은 없고, 그 fragment가 아직 안 끝났을 때 불필요하게 기다리는 성능 영향뿐이다. 판정: 결함 아님(사소한 정리 대상).
- 관찰 3, 항목 하나의 재시도(`la_retry_on_error`, log_applier.c:7082~7091)는 같은 항목만 다시 적용한다. ER_LK_UNILATERALLY_ABORTED처럼 서버가 트랜잭션 전체를 롤백한 오류라면, 이미 서버로 flush된 앞 항목은 사라진 채 뒤 항목만 적용되고 마커와 함께 커밋될 수 있다(추정). develop의 직렬 applier도 같은 코드(develop log_applier.c:5937~5946)이고, 대부분의 잠금 오류는 항목 단계가 아니라 flush 단계에서 나와 result 오류 → 재시작 경로로 간다. 병렬 워커끼리 잠금 교착이 생길 수 있는지(writeset이 못 잡는 잠금 충돌)에 따라 빈도가 달라진다. 판정: NEEDS HA REPRO, develop 상속.
- frag_ok(2 트랜잭션, frag 대본 6레코드, 라벨 ok, 재시작 1, 종료 뒤 수거 포함): 오류 없음. 980,588 상태, 완전 탐색.
- frag_lab(같은 대본, 라벨 ok·miss·floor, 재시작 0): 오류 없음. 1,075,612 상태, 완전 탐색.
- w1(워커 1개 경로, all 대본 5레코드, 라벨 ok·miss, 재시작 1): 오류 없음. 1,166,150 상태. 워커 1개일 때 gate 없이 FIFO로 넣는 경로도 커밋 순서·마커·재시작 불변식을 지킨다.
- small(큐 1칸, ring·in-flight 2칸, all 대본 5레코드, 라벨 3종, 재시작 0): 오류 없음. 483,614 상태. NoInflightOverflow도 지켜졌다. 즉 이 크기에서는 in-flight가 찬 채 배정하는 경로(wait_for_inflight_slot의 대기)가 나오지 않는다.
- in-flight가 찬 채 배정하는 경로는 손으로 따져 봤다. 커밋 순서로 W, X(W에 의존), E, F, G가 있고 E가 X보다 먼저 배정되면, X가 끝나 frontier가 X를 넘어도 E가 안 끝나 X는 retire되지 않는다. ring 3칸이면 G를 넣을 때 in-flight(E, X, F)가 차서 대기한다. 이때 현재 코드는 먼저 retire하고(coordinator.cpp:473), 그래도 차 있으면 결과 하나를 기다린다. 기다리는 대상 E, F는 이미 task queue나 worker에 있으므로 결과가 온다. 리뷰 09번(먼저 retire하지 않아 영원히 기다림)은 현재 코드에서 고쳐져 있다. 교착 없음.
- san_req02(변이: required_lsa 계산에서 in-flight·pending task를 빼 수정 전 코드로 되돌림, frag 대본, 재시작 1): RequiredStored 위반. 반례는 t1: D(1) S(2) A(3), t2: D(4) C(5). 2에서 fragment task가 in-flight인 채로 3의 ABORT가 t1 슬롯을 비우고, la_log_commit이 required_lsa=4를 저장한다. 그 뒤 재시작하면 fragment 항목(1)을 다시 읽지 못한다. 리뷰 수정 02번(required-lsa-fragments)과 같은 결함이며 모델이 이를 재현하고, 현재 코드(task도 훑음)에서는 사라진다.
- base2(basic 대본 5레코드, 재시작 2회): 오류 없음. 356,416 상태.
- err_frag(frag 대본 5레코드, flush 오류 1회, 재시작 1): 오류 없음. 80,710 상태.
- errc_frag(frag 대본 5레코드, 비치명 result 오류 1회, 재시작 1): 오류 없음. 71,398 상태.
- 종료 뒤 수거를 넣은 모델로 다시 돌림: base 오류 없음(27,678), err_commit 오류 없음(81,634), err_flush 오류 없음(92,050).
- three(3 트랜잭션 dc 대본 6레코드, 라벨 ok·miss): 19:40 세션 종료로 중단, 미완료. 다시 돌린다.
- three_ok(3 트랜잭션 dc 대본 6레코드, 라벨 ok, 재시작 0): 오류 없음. 681,606 상태.
- three_miss(같은 대본, 모든 항목 있는 COMMIT의 라벨 없음 → ring tail 대기 경로, 재시작 0): 오류 없음. 802,872 상태.
- three_floor(3 트랜잭션 dc 6레코드, 모든 항목 있는 COMMIT 라벨이 커밋 아닌 위치로 올라간 floor, 재시작 0): 오류 없음. 591,138 상태, 깊이 17. la_gate_bound_dependency 경로가 자기 대기를 막는다.
- three_crash(3 트랜잭션 dca 대본 6레코드, 재시작 1), mix3(3 트랜잭션 mix3 대본 7레코드), three_q1(3 트랜잭션 dc, 큐 1·ring 2, 라벨 ok·miss): 세션 종료와 900초 제한으로 중단, 미완료. 중단 시점까지 위반 없음(각각 약 2.64M, 2.62M, 4.40M 상태). 크기를 줄여 다시 돌린다.
- three_q1_ok(3 트랜잭션 dc 6레코드, 큐 1칸·ring 2칸, 라벨 ok, 재시작 0): 오류 없음. 576,684 상태.
- three_crash5 첫 시도는 dca 대본 최소 길이(3×2=6)가 MaxLog 5를 넘어 초기 상태 0개였다(무효). dc 대본 5레코드·재시작 1로 바꿔 다시 돌린다(NotStuck 제외, 안전 불변식만).

### 모델에 따로 넣지 않은 시나리오와 그 이유
- long transaction: coordinator가 보는 차이는 슬롯이 첫 항목과 last_lsa만 들고 worker가 로그에서 다시 읽는다는 것뿐이다. start_lsa는 그대로라 required_lsa가 첫 항목 이하로 남고(la_set_repl_log, la_find_required_lsa), 라벨 SYSOP_END에서는 long 분기가 슬롯 전체를 fragment로 넘기며 fragment start_lsa=첫 항목으로 둔다(log_applier.c:7274~7291). 모델의 "슬롯 시작 = 트랜잭션 첫 레코드, fragment 시작 = 첫 항목" 추상화와 같아서 별도 상태를 두지 않았다.
- 항목 재시도(la_retry_on_error): worker 안에서 같은 항목을 10초 간격으로 다시 적용할 뿐이라 coordinator 입장에서는 task가 오래 걸리는 것과 같다. 모델은 worker 완료 시점을 임의로 미루는 모든 인터리빙을 이미 본다. flush 단계 재시도 대상 오류는 ER_LC_PARTIALLY_FAILED_TO_FLUSH result 오류가 되어 ErrMode flush 경로로 모델링했다. 재시도의 원자성 문제는 관찰 3에 적었다.
- in-flight가 찬 채 배정하는 대기 경로: 위 실행 기록의 손 분석 참고.

### 추가 발견 (코드 추적, 모델 밖)
- 발견 A, 종료 요청과 겹친 fragment 슬롯 누수(경미, REAL DEFECT, 정확성 영향 없음). `la_free_unretired_fragments()`(log_applier.c:8478)는 프로세스 안 재시작 때 fragment 슬롯이 남지 않게 in-flight list와 pending list의 fragment만 해제한다. 그런데 fragment task가 두 목록 어디에도 없는 순간에 오류로 빠지는 경로가 있다.
  - 경로 1: `la_coordinator_drain_ready()`(coordinator.cpp:147~153)는 `la_pending_pop_ready()`로 pending에서 task를 먼저 빼고 `la_coordinator_enqueue_task()`를 부른다. enqueue 안의 `before_dispatch`(la_lock_dbname 실패) 또는 `la_coordinator_wait_for_inflight_slot()`이 종료 요청으로 ER_FAILED를 돌려주면(coordinator.cpp:218~228, 414~417) in-flight push 전에 반환하므로 task는 pending에도 in-flight에도 없다.
  - 경로 2: `la_coordinator_process_sysop_end()`(log_applier.c:7334~7369)가 `la_detach_sysop_fragment()`로 malloc한 슬롯을 지역 task에 담아 submit하는데, submit의 `la_coordinator_wait_for_commit_order_slot()`이 종료 요청으로 실패하거나(coordinator.cpp:173~176) 위와 같은 enqueue 실패가 나면 슬롯 포인터를 가진 곳이 없다.
  - 결과: 그 fragment의 LA_APPLY와 항목 목록이 해제되지 않는다. 다음 실행은 required_lsa부터 다시 읽어 fragment를 새로 만들므로 적용 결과는 맞다. 서버 다운이 반복되는 동안 같은 프로세스가 재시작할 때마다 조금씩 샌다. 조건이 좁고(종료 요청이 마침 fragment 배정 대기와 겹침) 양도 작다.
- three_q1_miss(3 트랜잭션 dc 6레코드, 큐 1·ring 2, 라벨 없음): 오류 없음. 722,520 상태.
- three_crash5(3 트랜잭션 dc 5레코드, 재시작 1, 안전 불변식): 오류 없음. 3,063,642 상태, 깊이 26.
- mix3_6(3 트랜잭션 mix3 대본: D C / C / D S A / S D C, 6레코드, 라벨 ok, 재시작 0): 900초 제한으로 중단, 약 2.18M 상태까지 위반 없음(미완료).
- mix3_k1(mix3 대본 6레코드, 키 하나뿐이라 모든 COMMIT이 충돌, 라벨 ok, 재시작 0, NotStuck 포함): 오류 없음. 133,566 상태.
- mix3_safe(mix3 대본 6레코드, 키 2개, NotStuck 제외): 오류 없음. 2,681,358 상태, 완전 탐색. mix3_6에서 끊겼던 범위를 안전 불변식으로 끝까지 봤다.
- frag_err2(frag 대본 6레코드, flush 오류 1회, 재시작 2회, 안전 불변식): 오류 없음. 1,615,502 상태, 완전 탐색.
- all_crash2(all 대본 5레코드, 큐 1·ring 2, 라벨 ok·miss, 비치명 result 오류 1회, 재시작 2회, 안전 불변식): 오류 없음. 2,455,456 상태, 완전 탐색.

## 5. 정리 (2026-11-06 23시)
- 현재 코드 모델의 모든 완전 탐색에서 반례 0건. 미완료로 끝난 것(frag 첫 실행, three, three_crash, mix3, three_q1, mix3_6)은 더 작은 설정이나 안전 불변식만으로 다시 돌려 완료했다.
- 변이 6종(gate_off, no_bound, req_final, req_slots_only, no_marker, adv_hole)과 SerialOrder는 모두 반례를 내 불변식이 살아 있음을 확인했다. req_slots_only는 리뷰 수정 02번, no_bound는 리뷰 C1과 같은 결함을 재현한다.
- REAL DEFECT: 발견 A(종료 요청과 겹친 fragment 슬롯 누수, 경미, 정확성 영향 없음) 1건. 그 밖은 관찰 1~3(판정은 각 항목).
- 남은 일: 관찰 3(항목 재시도의 원자성)은 HA 재현으로만 판정 가능. 발견 A는 수정 여부 사용자 판단.

## 6. 2차: 단순화 목록

2026-11-07 시작. hgryoo 님이 HA에서 재현한 "롤백된 INCR 조각 + 재시작" 결함(results/hgryoo-review-20261106.txt, log_applier.c:7307 인라인)을 1차 모델(SlaveCoordinator.tla)이 놓쳤으므로, 1차 모델이 코드와 다르게 둔 부분을 모두 적고 각각이 결함을 가릴 수 있었는지 판단한다. 코드 기준은 6bd39a696, 행 번호는 그 커밋의 log_applier.c다(다른 파일은 파일명을 붙인다).

1. 트랜잭션의 첫 로그 레코드를 첫 복제 항목과 같게 두었다. 대본이 거의 모두 D(복제 항목)로 시작하고, 데이터 undo/redo 같은 비복제 레코드가 없다. 코드는 prev_tranlsa가 NULL인 레코드라면 종류와 상관없이 슬롯을 만들고 start_lsa를 그 위치로 둔다(la_log_record_process 7561~7584). 비복제 레코드는 switch에서 아무 일도 하지 않지만 슬롯 시작 위치를 정한다. 결함을 가릴 수 있음: 그렇다. 리뷰 결함이 바로 이 차이에서 생긴다(조각 start_lsa=첫 항목 > 트랜잭션 첫 레코드).
2. 조각 start_lsa를 "그 조각의 첫 D 위치"로 두었는데, 1번 때문에 첫 조각이면 트랜잭션 첫 레코드와 같아져 required_lsa가 첫 레코드 위로 올라가는 경우가 생기지 않았다. 코드는 la_detach_sysop_fragment(7245)의 짧은 분기 LSA_COPY(&fragment->start_lsa, &fragment->head->lsa)(7307)와 긴 분기(7283)다. 결함을 가릴 수 있음: 그렇다(1번과 함께).
3. long transaction을 넣지 않았다. 코드는 항목이 LA_MAX_REPL_ITEMS를 넘으면 머리 항목과 last_lsa만 남기고(la_set_repl_log 4591~4596), 라벨 SYSOP_END에서는 슬롯 전체를 조각으로 넘긴다(7274~7291). required_lsa에 들어가는 조각 start_lsa는 짧은 분기와 같이 첫 항목이다. 결함을 가릴 수 있음: 그렇다. 리뷰도 같은 결함이 이 분기에 있다고 본다. 워커가 로그를 다시 읽는 부분(la_get_next_repl_item_from_log)은 coordinator 영역 밖이다.
4. 라벨 레코드(LOG_DUMMY_WSET_LABEL)를 따로 두지 않고 경계 레코드의 속성으로 붙였다. 코드는 라벨을 단일 보관 칸에 두고 바로 다음 같은 trid의 COMMIT/SYSOP_END가 가져간다(log_applier_wset_label.cpp). 재시작 위치가 라벨과 경계 사이에 떨어지면 라벨을 잃는다. 재시작 위치는 열린 슬롯 시작, 조각 시작, final_lsa 중 하나이고, 라벨을 가진 트랜잭션은 그 시점에 슬롯이 열려 있으므로 그 사이에 떨어지지 않는다(슬롯이 없을 때는 1·2번 결함 경로뿐). 결함을 가릴 수 있음: 낮다.
5. 모든 S를 라벨 붙은 SYSOP_END로 두었다. 라벨 없는 SYSOP_END(7372 이후 아무것도 안 함)와 LOG_SYSOP_END의 결과 종류(커밋, attach, abort)는 넣지 않았다. coordinator는 종류를 보지 않고 라벨 일치만 본다. 결함을 가릴 수 있음: 낮다(1차 관찰 1에서 따로 분석).
6. 슬롯을 trid마다 하나씩 고정하고 재사용하지 않았다. 코드는 tranid=0인 슬롯을 다른 trid에 주며 last_sysop_fragment_lsa를 지우지 않는다(la_add_apply_list 3924, la_clear_applied_info 4532). 결함을 가릴 수 있음: 낮다(1차 관찰 2, 불필요한 대기뿐).
7. la_log_commit(required_lsa 재계산과 저장)을 레코드 사이 아무 때나 허용했다. 코드는 페이지 단위 주기 커밋(la_check_time_commit 8232, 메인 루프 10277), 상태 변경(7961), 슬롯이 빌 때의 HA_SERVER_STATE(7692), 로그 끝(10014)에서만 부른다. 실제보다 넓게 허용한 것이라 결함을 가리지 않는다(거짓 반례 가능성만 있음).
8. final_lsa를 "다음에 읽을 레코드"로 두었다. 코드도 레코드 처리 뒤 final_lsa를 forw_lsa로 옮기므로(10271) 같다.
9. DONE 상태이고 마스터가 ACTIVE가 아닐 때 committed_lsa를 min(final_lsa, frontier)로 올리는 경로(9995~10005)를 넣지 않았다. failover 영역(RestartFailover.tla)에서 다룬다. 이 모델 범위에서 결함을 가릴 수 있음: 낮다.
10. 재시작을 프로세스 재기동으로만 두어 모든 메모리 상태를 비웠다. 서버 다운 뒤 같은 프로세스 안 재시작(util_cs.c retry)은 라벨 보관 칸(파일 static)이 남는다. 결함을 가릴 수 있음: 낮다(1차 관찰 1).
11. 워커의 적용·마커 INSERT·커밋을 한 단계로 두었고, 오류는 태스크 단위로 한 번만 넣었다. 항목 단위 재시도(7082~7091)와 부분 반영은 넣지 않았다. 결함을 가릴 수 있음: 있다(1차 관찰 3, develop 공통이라 HA 재현 대상으로 남김).
12. 조각 누수, before_dispatch(dbname 잠금) 실패, 종료 요청과 겹친 enqueue 실패를 넣지 않았다. 정확성보다 자원 문제이고 1차 발견 A로 따로 정리했다. 결함을 가릴 수 있음: 정확성 결함은 낮다.
13. ring 용량과 in-flight 용량을 같은 RingCap으로 두었다. 코드는 ring이 워커 수×1024이고 in-flight는 별도 한도다. 작게 잡은 것이라 대기 경로를 더 자주 본다. 결함을 가릴 수 있음: 낮다.
14. 키는 추상 집합, 라벨 값은 이상적 마스터 값·없음·floor 세 가지로만 두었다. 마스터 영역 모델이 실제 라벨 계산을 본다. 결함을 가릴 수 있음: 슬레이브 범위에서는 낮다.
15. 로그 보관(아카이브 삭제가 required_lsa를 기준으로 함)과 long transaction 워커의 로그 다시 읽기는 넣지 않았다. required_lsa가 첫 항목 아래에 머무는 한 문제가 없고, 이 값의 정확성은 RequiredStored로 본다. 결함을 가릴 수 있음: 낮다.
16. 레플리카 지연(la_delay_replica), DDL·문장 복제의 잠금 대기, 실제 잠금 교착은 넣지 않았다. coordinator 입장에서는 워커 완료가 늦어지는 것과 같다. 결함을 가릴 수 있음: 낮다.
17. trid 재사용, LOG_SYSTEM_TRANID 레코드, END_OF_LOG·CRASH_RECOVERY 같은 제어 레코드는 넣지 않았다. 결함을 가릴 수 있음: 낮다.

이 가운데 결함을 가릴 수 있다고 본 1·2·3번을 2차 모델(SlaveCoordinator2.tla)에서 없앤다. 11번은 coordinator 상태로 옮기기 어려워 그대로 둔다.
