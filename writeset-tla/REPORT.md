# writeset 의존 값과 병렬 적용 검증

검토일: 2026-11-10. 기준 코드는 [PR #8052](https://github.com/CUBRID/cubrid/pull/8052) 리뷰 기준 HEAD `6bd39a696`이고, serial·INCR 설계 검사(4절 마지막)만 그 위에 올릴 설계안을 대상으로 했다. PR이 바꾸는 두 가지, 곧 **master가 커밋할 때 "어느 커밋 다음에 적용할지"(의존 값)를 로그에 적는 규칙**과 **slave가 그 값을 보고 여러 worker로 동시에 적용하는 규칙**을 TLA+로 검사했다. 실제 2노드 HA 통합 시험 결과는 아니다.

## 결과 한눈에 보기

| 검사 | 무엇을 봤나 | 결과 | 판단 |
|---|---|---|---|
| 기본 병렬 적용과 라벨 SYSOP_END 키 유실 | 같은 키를 바꾼 트랜잭션의 적용 순서, 리뷰에서 지적된 키 유실 경로와 수정안 | 기본 모델 위반 없음. 지금 코드 규칙은 키 유실 반례, 수정안은 위반 없음 | **문제점 1건(리뷰 지적 재현)** |
| 영역별 전수 탐색 | master 의존 값 계산, serial·INCR SYSOP, slave 배분·적용, 재시작·failover를 영역별로 | 네 영역 모두 순서 결함 없음 | **문제점 2건(처음 찾음): 조각 누수, 재시도 뒤 항목 유실 가능성** |
| master→slave 통합 검사 | master가 실제로 만드는 로그를 slave가 그대로 읽을 때의 조각 시작 위치와 저장 위치 | 지금 코드는 재시작 뒤 serial·INCR 유실 반례. 두 분기를 모두 고치면 위반 없음 | **문제점 2건(리뷰 지적 재현 1, 처음 찾음 1)** |
| serial·INCR 키 방식 설계 | 전체 장벽 대신 같은 키끼리만 순서를 지키는 설계와 각 구성 요소의 필요성 | 설계안 위반 없음. 요소를 빼면 반례 | **문제점 0건** |

검사에서 확인된 실제 결함은 대부분 PR 리뷰에서 이미 지적된 것이다. 처음 찾은 순서 결함은 통합 검사의 긴 트랜잭션 분기 1건이고, 이것도 리뷰 결함과 원인이 같다. "위반 없음"은 아래 **작은 모델의 조건부 결과**이고, CUBRID 코드 전체나 실제 HA 실행의 정확성을 증명한 뜻은 아니다.

## 검증 근거와 범위

| 확인 방법 | 실제로 확인한 내용 | 이 방법으로 확인하지 못한 내용 |
|---|---|---|
| **CUBRID 코드 추적** | master 커밋 경로의 순서(MVCC 완료 → 로그 mutex 안 의존 값 계산·라벨·COMMIT → 키 등록 → 락 해제), history 비우기와 하한, serial SYSOP_END 라벨, slave의 slot·조각·커밋 의존 값, gate·pending·worker, 적용 위치 저장과 재시작 | 모든 운영 환경에서 실제로 그 순서로 실행되는지 |
| **TLA+ 모델 검사** | 코드에서 추린 규칙으로 정한 크기 안의 모든 실행 순서를 탐색해 순서 위반·누락·중복·저장 위치 앞지름 여부 검사 | CUBRID 함수 자체의 실행, 코드가 설계와 다르게 구현된 부분(해시 계산, 테이블 위치 등), 실제 2노드 HA 복제 |
| **반례의 코드 대조** | 반례가 나오면 각 단계를 `6bd39a696`의 file:line에 대응시켜 실제로 가능한 순서인지 판정. 모델을 잘못 옮긴 반례는 모델을 고쳐 다시 실행 | 반례 순서를 HA에서 직접 재현한 것은 아님(리뷰어가 재현한 1건 제외) |

검사한 성질은 셋이다. 모든 모델에 같은 뜻으로 걸었다.
- **충돌 순서**: 같은 키를 바꾼 트랜잭션은 slave에서도 master 커밋 순서대로 적용된다. 관계없는 트랜잭션끼리는 순서가 바뀌어도 된다.
- **정확히 한 번**: 재시작·크래시가 있어도 master에서 커밋된 변경은 slave에 빠짐없이, 두 번 없이 적용된다.
- **저장 위치**: slave가 저장하는 `committed_lsa`, `required_lsa`는 실제로 적용이 끝난 곳을 앞지르지 않는다. 앞지르면 재시작 때 그 사이 변경이 빠진다.

## 모델이 하는 일

모델은 TLA+로 쓴 `.tla` 파일이다. CUBRID 코드를 그대로 옮긴 것이 아니라 **실행 순서에 영향을 주는 결정만 남겨** 다시 적은 것이다. 로그 페이지·버퍼·SQL은 없고, 로그는 레코드 목록, LSA는 목록의 위치로 대신한다. 검사 도구(TLC 2.19)는 이 파일을 읽어 처음 상태에서 가능한 동작을 모두 해 보며, 갈림길마다 모든 갈래를 끝까지 따라가 위 세 성질이 깨지는 순서를 찾는다. 깨지면 처음부터 그 상태까지의 순서(반례)를 보여 준다.

예: master 커밋 기록. 코드는 `log_append_repl_info_and_commit_log`(log_manager.c 5030–5054)에서 `prior_lsa_mutex`를 잡고 복제 레코드를 쓰고, `wset_order_find_dependency_in_range`(writeset_order.cpp 43–125)로 의존 LSA를 구하고, 라벨과 COMMIT을 쓰고, `prev_commit_lsa`를 올린다. 모델(`WritesetE2E.tla`의 `CommitRecord`)은 이것을 한 동작으로 적는다.
- 할 수 있는 때: 트랜잭션이 진행 중이고 MVCC 완료를 마쳤을 때
- 하는 일: 트랜잭션이 바꾼 키마다 history에서 그 키의 마지막 커밋 위치를 찾아 최댓값을 하한(`history_start`)과 상한(`prev_commit_lsa`)으로 보정해 의존 값으로 정하고, 그 값을 담은 COMMIT을 로그 끝에 붙이고, `prev_commit_lsa`를 올린다
- 그대로 두는 것: 락과 키 등록. 다음 동작(`Publish`, `Unlock`)에서 한다

모델이 결함을 정말 잡는지도 확인했다. 일부러 틀린 설계(변이)를 넣어 반례가 나오는지 먼저 봤다. 예: 키를 등록하기 전에 락을 놓기, 같은 키가 서로 다른 해시로 계산되기, gate가 앞선 커밋을 한 칸 일찍 통과시키기, required_lsa가 진행 중 task를 보지 않기. 영역마다 4~7종을 넣었고 **모두 반례가 나왔다**.

실행은 `~/tools/tlc`(TLC 2.19 래퍼)로 했다. 예: `~/tools/tlc -workers 16 -config E2E_s1.cfg WritesetE2E.tla`.

## 기본 병렬 적용과 라벨 SYSOP_END 키 유실

[WritesetApply.tla](WritesetApply.tla)는 master의 커밋·키 등록과 slave의 worker 배분·적용만 담은 첫 모델이다. 트랜잭션 5개·worker 10개까지 **217만 상태에서 위반이 없었다**. 대조로 "slave가 항상 커밋 순서 그대로 적용한다"를 성질로 걸면 반례가 나와, 관계없는 트랜잭션끼리는 실제로 순서가 바뀌어 적용됨(병렬로 동작함)을 확인했다.

[WritesetSysop.tla](WritesetSysop.tla)는 11-05 코드 리뷰에서 지적된 경로를 옮겼다. INCR이 `log_sysop_attach_to_outer`로 바깥 트랜잭션에 붙어 끝나면 복제 레코드가 `LOG_REPL_NEED_FLUSH`로 남고, 같은 트랜잭션의 다음 SYSOP_END가 그 레코드를 쓰며 라벨을 받고 그 SYSOP 안에서 모은 사용자 행 키를 버린다(log_manager.c 4010–4094, `wset_discard_sysop_keys`).

| 설정 | 크기 | 결과 |
|---|---|---|
| [지금 코드 규칙](WritesetSysop_bug.cfg) | 트랜잭션 2, 행 키 1, serial 1, worker 2 | **키 유실 반례**(73번째 상태). 뒤에 같은 행을 바꾼 트랜잭션이 앞 커밋을 기다리지 않음 |
| [수정안](WritesetSysop_fix.cfg): 버릴 키를 그 SYSOP_END가 실제로 내보낸 레코드의 키로 한정 | 트랜잭션 3, 행 키 1, serial 1, worker 10 | 위반 없음(196만 상태) |
| 대조: 아무 키도 버리지 않음 | 트랜잭션 2 | serial 키가 커밋에서 등록되는 위반. serial 키는 버려야 맞음을 확인 |

**문제점 1건(리뷰 지적 재현)**: 라벨 SYSOP_END에서 사용자 행 키 유실. 반례 순서는 코드를 읽고 추적한 순서와 같았다.

## 영역별 전수 탐색

알려진 결함이 아니라 아직 모르는 결함을 찾으려고 설계를 네 영역으로 나눴다. 각 영역은 코드에서 동작 목록을 먼저 만들고([progress-master](progress-master.md) 1절 등) 모델로 옮겼다.

| 영역 | 모델 | 넣은 것 | 가장 큰 완주 실행 | 결과 |
|---|---|---|---|---|
| master 의존 값 계산 | [MasterDependency.tla](MasterDependency.tla) | 키 수집(PK·UNIQUE·FK 참조), 키 한도 초과와 커밋 순서 전환, 문장 복제, 저장점 롤백, abort, serial, history 비우기(용량 초과·메모리 부족), master 재시작, slave 적용 | [MD_allM2](MD_allM2.cfg): 트랜잭션 2·키 2·serial 1·모든 기능, 3,831만 상태 | 위반 없음, 변이 5종 모두 반례 |
| serial·INCR SYSOP | [SysopExtended.tla](SysopExtended.tla) | instant INCR/DECR, 같은 serial을 두 트랜잭션이 갱신, ALTER SERIAL, 컨테이너 SYSOP의 commit·attach·abort, 중첩 2단계, slave 조각 | [txn3](SysopExtended_txn3.cfg): 트랜잭션 3, 1억 4,330만 상태 | 위반 없음, 변이 4종 모두 반례 |
| slave 배분과 적용 | [SlaveCoordinator.tla](SlaveCoordinator.tla) | 로그 레코드 처리, 라벨·조각·ABORT·라벨 없음, gate·pending·task queue·ring·in-flight·retire, 적용 위치 저장, marker, 적용 오류, 재시작, worker 1개 경로 | 트랜잭션 3·크래시 2, 306만 상태 | 위반 없음, 변이 6종 모두 반례 |
| 재시작과 failover | [RestartFailover.tla](RestartFailover.tla) | 시나리오 6종, 크래시 최대 4회, master DEAD/STANDBY, 승격(DONE) 뒤 재기동 | [A](RestartFailover_A.cfg) 크래시 4회, 21만 상태 | 위반 없음, 변이 5종 모두 반례 |

네 모델은 큰 크기를 무작위 실행으로 다시 확인했다([sim-SIM_slave](results/sim-SIM_slave.txt) 트랜잭션 3·크래시 3, 약 4억 2천만 상태 등). 모두 위반이 없었다.

**문제점 2건(처음 찾음)**
- **조각 누수**: `la_coordinator_drain_ready`(log_applier_coordinator.cpp 146–153)가 pending에서 task를 꺼낸 뒤 enqueue가 종료 요청으로 실패하거나, `la_coordinator_process_sysop_end`(log_applier.c 7334–7369)가 떼어 낸 조각을 submit하다 실패하면 조각이 in-flight·pending 어느 목록에도 없어 `la_free_unretired_fragments`(8478)가 해제하지 못한다. 다음 실행이 `required_lsa`부터 다시 읽어 조각을 새로 만들므로 **적용 결과에는 영향이 없다**.
- **재시도 오류 뒤 앞 항목 유실 가능성**(HA 재현 필요): `la_apply_repl_log`의 재시도는 같은 항목만 다시 적용한다. 재시도 대상에 `ER_LK_UNILATERALLY_ABORTED`처럼 서버가 트랜잭션 전체를 롤백하는 오류가 있어, 그 경우 앞서 적용한 항목이 롤백으로 사라진 채 나머지가 커밋될 수 있다. **develop applier와 같은 루프**라 이 PR이 만든 문제는 아니다.

PR 리뷰에서 HA로 찾은 결함 3건은 이 탐색에서 나오지 않았다. 이유는 다음 절과 "해석의 한계"에 적었다.

## master→slave 통합 검사

영역별 모델은 slave에 넣는 로그를 손으로 만든 대본으로 대신했다. 대본에서는 "트랜잭션의 첫 레코드 = 첫 복제 항목"이었다. [WritesetE2E.tla](WritesetE2E.tla)는 master 동작이 실제로 만드는 로그를 slave가 그대로 읽게 이어 붙였고, [WritesetBoundary.tla](WritesetBoundary.tla)는 여기에 조각, 긴 트랜잭션 분리, 적용 오류와 재시도, failover를 더했다.

| 설정 | 조각 시작 위치 | 결과 |
|---|---|---|
| [E2E 지금 코드](E2E_s1_bug.cfg) | 첫 항목 | **반례**: T1 첫 레코드(1) → serial 항목(2) → 라벨 SYSOP_END(3) → ABORT(4). 조각이 끝나기 전에 ABORT가 slot을 비워 `required_lsa`=2 저장 → 재시작이 2부터 읽어 slot이 없으니 항목을 버리고(`la_set_repl_log` 4580–4584) SYSOP_END는 task 없이 완료(7372–7383) → serial 갱신 유실. [출력](results/out-e2e-s1_bug.txt) |
| [Boundary 리뷰 제안](BND_s1_short.cfg) | 7307만 바깥 트랜잭션 시작 | **반례**: 긴 트랜잭션 분기(7283)에서 같은 유실. [출력](results/out-bnd-s1_short.txt) |
| [E2E 수정](E2E_s1.cfg), [Boundary 수정](BND_s1_k2cd2.cfg) | 7283·7307 모두 바깥 트랜잭션 시작 | 위반 없음(E2E 692만 상태, Boundary 2,240만 상태). 무작위 실행 트랜잭션 4~10개·크래시 최대 5회, 각 3억~7억 상태에서도 위반 없음 |

**문제점 2건**
- **롤백된 바깥 트랜잭션의 serial·INCR 조각이 재시작 뒤 사라짐(리뷰 지적 재현)**: 형규님이 INCR로 HA 3/3 재현한 결함과 같은 경로를 serial로 냈다.
- **같은 결함이 긴 트랜잭션 분기(log_applier.c 7283)에도 있음(처음 찾음)**: 리뷰 제안대로 7307만 고치면 남는다. 수정 커밋 `bdd1fd0a1`은 두 곳을 모두 고쳤다.

리뷰의 나머지 두 결함(utf8_gen CHAR 해시 불일치, marker 테이블 DROP)은 각각 해시 계산 코드와 테이블 위치의 구현 문제라 모델로 옮기지 않았다. 해시 불일치와 같은 모양의 변이(같은 키가 두 해시)는 반례를 냈다.

## serial·INCR 키 방식 설계 검사

지금 serial·INCR SYSOP_END는 다른 모든 커밋을 막는 장벽(커밋 순서 라벨)을 받는다. 이것을 **같은 키끼리만 순서를 지키는 라벨**로 바꾸는 설계안을 코드로 옮기기 전에 [WritesetSysopKeyed.tla](WritesetSysopKeyed.tla)로 검사했다. 설계안은 SYSOP_END에서 자기 키만 보고 라벨을 정하고, 그 키를 등록하고, `prev_commit_lsa`를 그 SYSOP_END로 올린다. SYSOP 시작 전 레코드가 섞이면 커밋 순서 라벨로 돌아가는 안전 검사를 둔다.

| 설정 | 바꾼 것 | 결과 | 의미 |
|---|---|---|---|
| [a_t2](KS_a_t2.cfg) | 설계안 그대로(트랜잭션 2·키 2·serial 1·크래시 1·abort) | 위반 없음, 8,468만 상태. 트랜잭션 4 무작위 1억 6천만 상태도 위반 없음 | 설계 채택 근거 |
| [b_noPrevRaise](KS_b_noPrevRaise.cfg) | `prev_commit_lsa` 올리기 제거 | **반례**: 같은 트랜잭션·같은 serial의 뒤 조각이 앞 조각보다 낮은 라벨, 커밋 순서 커밋이 serial 조각을 건너뜀 | 올리기가 필요함 |
| [c_noFix](KS_c_noFix.cfg) | attach된 INCR 수정과 안전 검사 둘 다 제거 | **반례**: 남은 INCR 레코드가 다른 키의 조각에 실려 앞 커밋을 기다리지 않음 | 둘 중 하나는 필요함 |
| [d_t2](KS_d_t2.cfg) | attach 수정 없이 안전 검사만 | 위반 없음, 4,005만 상태 | attach 수정은 순서에는 불필요 |

**문제점 0건**. 구성 요소를 뺀 반례는 설계 결함이 아니라 각 요소가 필요하다는 근거다. 실행 기록은 [progress-sysop-keyed](progress-sysop-keyed.md), 출력은 `results/sysop-keyed-*.txt`.

## 해석의 한계

- **TLA+ 검사의 목적은 설계 확인이다.** 모델은 순서에 영향을 주는 결정만 옮기므로, 코드가 설계와 다르게 구현된 결함은 잡지 못한다. PR 리뷰의 해시 불일치와 marker 테이블 DROP이 그런 예다.
- 이번 검사로 확인된 실제 결함은 대부분 리뷰에서 이미 지적된 것이었고, 설계 수준의 순서 결함은 이 크기에서 더 나오지 않았다. **결함 탐색은 HA 실측을 권한다.** 실제 빌드로 master와 slave를 띄우고 무작위 부하를 넣어 두 노드를 비교하는 시험을 늘리는 것이 남은 위험(구현 세부)을 찾는 데 더 효과적이다. TLA+는 설계를 바꿀 때 코드로 옮기기 전 확인용으로 쓴다.
- 전수 검사는 트랜잭션 2~3개, 키 1~3개, worker 2~10개, 크래시 최대 4회의 유한 상태다. 큰 크기(트랜잭션 4~10개)는 무작위 실행이라 전수가 아니다. 순서 결함은 보통 트랜잭션 2~3개에서 드러나 강한 근거로 보지만 증명은 아니다.
- master의 의존 값 계산은 "MVCC 완료 뒤 락 해제 전에는 충돌하는 쓰기가 들어오지 못한다"를 전제로 한다(CBRD-27034). heap·btree의 모든 대기 경로가 이 전제를 지키는지는 확인하지 않았다.
- attach된 INCR이 바깥 롤백 뒤 slave에만 남는 develop 결함은 모델에서도 그 경로를 켜면 반례가 나온다. 위 "위반 없음"은 그 경로를 뺀 결과다.
- 영역별 모델 중 master·serial·재시작의 전수 실행 출력은 진행 기록에만 남아 있다. 출력 원본이 있는 것은 slave(`results/out-*.txt`), 통합(`results/out-e2e-*`, `results/out-bnd-*`), 설계 검사(`results/sysop-keyed-*`)와 무작위 실행(`results/sim-SIM_*`)이다.
