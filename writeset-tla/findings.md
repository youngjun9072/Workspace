# writeset TLA+ 결함 탐색 결과 (종합)

이 파일은 영역별 진행 기록을 모아, 코드로 다시 확인한 결함만 정리하는 종합 문서다. 세션이 끊겨도 진행 상황을 여기와 영역별 기록에서 이어 볼 수 있다.

## 진행 방식

- 시작: 2026-11-06 오후. 시간 제한 없이 실제 결함을 최대한 찾는 것이 목표다.
- 영역 넷을 에이전트 하나씩 맡아 병렬로 진행한다. 각 에이전트는 8052 브랜치 코드를 읽기만 하고(git show), 모델과 진행 기록을 이 폴더에만 쓴다. 커밋하지 않는다.
- 영역별 진행 기록(단계마다 갱신)
  - 마스터 의존성 계산: progress-master.md, 모델 MasterDependency.tla
  - sysop 확장: progress-sysop.md, 모델 SysopExtended.tla
  - 슬레이브 코디네이터와 워커: progress-slave.md, 모델 SlaveCoordinator.tla
  - 재시작과 failover: progress-restart.md, 모델 RestartFailover.tla
- 판정 기준: 반례의 각 단계를 코드 file:line에 대응시켜 실제로 그 순서가 가능한 경우만 결함으로 올린다. 모델을 잘못 옮긴 반례는 모델을 고쳐 다시 돌린다. 코드만으로 확정하기 어려운 것은 HA 재현 필요로 따로 둔다.

## 이미 확인된 결함

- 라벨 SYSOP_END에서 사용자 행 키 유실(11-05 코드리뷰 지적). WritesetSysop.tla에서 반례 재현, 수정안(그 SYSOP_END가 실제로 내보낸 레코드의 키만 폐기) 통과.

## 새로 확인된 결함

- 조각 슬롯이 어느 목록에도 없는 순간 오류로 빠지면 누수(경미, 정확성 영향 없음, 슬레이브 영역, 11-06 23시 코드 재확인). la_free_unretired_fragments(log_applier.c:8478)는 in-flight 목록과 pending 목록의 조각만 해제한다. 그런데 두 경로에서 조각이 두 목록 어디에도 없을 때 오류가 난다. 첫째, la_coordinator_drain_ready(log_applier_coordinator.cpp:146-153)는 la_pending_pop_ready로 pending에서 태스크를 먼저 꺼낸 뒤 la_coordinator_enqueue_task를 부르는데, enqueue 안의 before_dispatch(dbname 잠금 실패)나 la_coordinator_wait_for_inflight_slot이 종료 요청으로 실패하면 in-flight에 넣기 전에 반환한다. 둘째, la_coordinator_process_sysop_end(log_applier.c:7334-7369)가 떼어 낸 조각을 지역 태스크에 담아 submit하는데, la_coordinator_wait_for_commit_order_slot(coordinator.cpp:170-176)이 종료 요청으로 실패하거나 같은 enqueue 실패가 나면 조각 포인터를 가진 곳이 없다. 다음 실행이 required_lsa부터 다시 읽어 조각을 새로 만들므로 적용 결과는 맞고, 서버 다운으로 같은 프로세스가 재시작될 때마다 조금씩 샌다. 둘째 경로는 10-29에 "applier가 종료되는 경로라 한 번만 생기는 누수"로 보고 남겨 둔 것과 같고, 첫째 경로(pending에서 꺼낸 뒤 실패)가 이번에 새로 확인됐다. 종료 요청은 서버 다운 재시작마다 오므로 "한 번만"이라는 당시 판단은 프로세스 안 재시작에서는 맞지 않는다.

## HA 재현이 필요한 후보

- 재시도 대상 오류 뒤 앞 항목 유실(추정, 재시작 영역에서 발견, develop과 같은 루프라 이 PR의 회귀는 아님). la_apply_repl_log의 항목 재시도는 같은 항목만 다시 적용한다. 재시도 목록에는 ER_LK_UNILATERALLY_ABORTED, ER_LK_DEADLOCK_CYCLE_DETECTED처럼 서버가 트랜잭션 전체를 롤백하는 오류가 들어 있다. 그런 오류가 statement 실행이나 클래스 조회에서 나면, 앞서 적용한 항목은 롤백으로 사라진 채 나머지 항목과 적용 표시가 커밋되고, 재기동은 표시를 보고 그 트랜잭션을 건너뛰어 앞 항목이 영구히 빠질 수 있다. 행 항목의 교착은 flush 경로에서 applier 재시작으로 바뀌므로 해당하지 않는다.

## 영역별 결과 요약

- 마스터 의존성 계산(완료, 11-06 19:4x): 실제 결함 없음. 키 수집(PK/UNIQUE/FK REF), overflow와 키 한도, NaN 폴백, 문장 복제 폴백, 저장점 롤백, abort, serial, 재시작 floor, 용량 초과·메모리 부족으로 맵을 비우는 경로, slave 반영까지 조합해 완료된 실행이 모두 통과했다(가장 큰 것은 트랜잭션 2·키 2·serial 1·모든 기능, 3,831만 고유 상태). 변이 5종은 모두 잡혔고, 기지 결함(라벨 SYSOP_END 키 유실)도 이 모델에서 같은 경로로 다시 나왔다. 확인하지 못한 부분은 두 가지다. 첫째, 커밋 시점에 log_does_allow_replication()이 거짓이 되면 라벨 없이 커밋만 쓰고 record_commit도 하지 않는데, 그런 커밋에 복제 레코드가 있는 경우가 실제로 생기는지(미확인). 둘째, complete_mvcc 뒤 lock_unlock_all 전에 다른 쓰기가 들어오지 못한다는 전제는 CBRD-27034 커밋 메시지 기준이고 heap/btree 대기 경로 전수 확인은 하지 않았다. 상세는 progress-master.md.

- 재시작·크래시 복구·승격(완료, 11-06 19:2x): 실제 결함 없음. 시나리오 6종(긴 트랜잭션과 serial 조각, 시작·커밋 순서 역전과 abort된 조각, DDL 연속, master 재기동과 C1 바닥 라벨, 라벨 붙은 조각 뒤 라벨 없는 SYSOP_END, 조각 두 개와 DDL과 열린 트랜잭션)을 크래시 최대 4회, master 종료 상태 DEAD/STANDBY, 승격 뒤 재기동까지 넣어 최대 21만 상태를 검사했다. 변이 5종은 모두 해당 불변식에 잡혔다. 정리 차원의 관찰로 라벨 보관 칸이 프로세스 안 재시작에서 비워지지 않는 점이 있으나 해롭지 않다고 판정했다. 상세는 progress-restart.md.

- sysop 확장(완료, 11-07 0시): 새 결함 없음. instant INCR/DECR(실제 키를 가진 사용자 행), 같은 serial을 두 트랜잭션이 갱신, serial X lock 아래 NEXT_VALUE와 ALTER SERIAL, 컨테이너 sysop의 commit·attach·abort, 중첩 2단계, 트랜잭션 abort, slave 조각 분리와 커밋 의존성 올림까지 넣었다. 완주한 실행은 기본 1,720만, ALTER SERIAL 3,760만, 중첩 2 1,733만, 사용자 행 2 1억 2,060만, 트랜잭션 3 1억 4,330만 상태이고 모두 위반이 없다. 반례는 남은 INCR 레코드를 켰을 때 나온 기지 결함 두 가지(라벨 SYSOP_END 키 유실, 되돌린 INCR 증가가 slave에 남음)뿐이다. 결함이 생길 수 있는 자리는 모두 "instant 모드가 꺼진 INCR이 NEED_FLUSH 레코드를 남기는" 기지 경로로 모인다. 부수 확인: slave가 바깥 커밋 의존성을 last_sysop_fragment_lsa까지 올리는 동작은 라벨이 있는 커밋에서는 마스터 floor가 이미 보장해 방어용 중복이다(올림을 뺀 모델도 위반 없음, 코드 근거 log_manager.c:4913, writeset_order.cpp:114-118). 상세는 progress-sysop.md.
- 슬레이브 코디네이터(완료, 11-06 23시): 순서·중복·prefix 관련 결함 없음, 경미한 누수 1건(위 "새로 확인된 결함"). 트랜잭션 3개 대본, 크래시·재시작 2회, result·flush 오류, 큐 1칸·ring 2칸, 라벨 누락·floor까지 완전 탐색 반례 0건(최대 306만 상태). 큰 일부 설정은 안전 불변식만으로 다시 완주했다. 이전 기록: 기본, 재시작 2회, result 오류와 flush 오류 뒤 재시작, 조각(라벨 정상·누락·floor), 워커 1개 경로, 큐 1칸·ring 2칸이 모두 통과했다. 변이 6종은 모두 잡혔고, 이미 고친 리뷰 결함 02번(조각 태스크가 in-flight인 채 ABORT가 슬롯을 비워 required_lsa가 앞질러 저장됨)도 수정 전 코드로 되돌리면 재현됐다. in-flight가 찬 채 배정하는 경로는 손으로 따져 리뷰 09번 수정이 유효함을 확인했다. 상세는 progress-slave.md.

## 키 유실 경로 전체

결함
- 라벨 SYSOP_END 사용자 행 키 유실(확정). instant 모드가 꺼진 INCR이 attach로 끝나며 NEED_FLUSH 레코드를 남기고, 같은 트랜잭션의 다음 system operation이 그 레코드를 쓰면서 라벨이 붙고 그 연산 안에서 모은 키를 모두 버린다. 다음 연산이 사용자 행을 바꾸는 연산이면 커밋까지 락을 쥔 키가 사라져 slave 순서가 역전된다. 실어 나르는 연산이 serial 갱신이나 컨테이너 sysop이어도 같다.

같은 뿌리의 관련 결함
- 되돌린 INCR 증가가 slave에 남음(기지 todo 2번). 남은 INCR 레코드가 다음 연산의 조각에 실려 slave에 적용된 뒤 바깥 트랜잭션이 abort되면 master만 되돌린다. 키 유실은 아니다.

미확인(추정)
- 커밋 시점에 log_does_allow_replication()이 거짓이면 라벨과 record_commit 없이 커밋만 쓴다. 그런 커밋에 복제 레코드가 실리는지 미확인.
- 재시작 뒤 복구된 미결 2PC 트랜잭션은 키와 복제 레코드가 모두 사라진 채 커밋된다. 레코드가 없어 slave에 반영할 내용이 없고 develop과 같다.

의도된 폐기(결함 아님, 모델에서 안전 확인)
- serial 키: 행 락이 SYSOP_END에서 풀리므로 커밋에서 발행하면 안 되고, 라벨로 커밋 순서 장벽을 세운다.
- overflow, 키 한도 초과, NaN 키: 키를 모두 버리고 커밋 순서 모드로 바꾼다.
- 문장 복제 폴백: 위와 같다.
- 저장점 롤백과 문장 롤백: 롤백된 변경의 키만 LSA로 지운다.
- history 맵 비우기(용량 초과, 메모리 부족, overflow 커밋): floor를 그 순간의 prev_commit으로 올려 지운 키를 덮는다.

## "위반 없음"의 의미와 한계

- 의미: 모델로 옮긴 설계에서, 정한 크기(대체로 트랜잭션 2~3, 키 1~2, 워커 2) 안의 모든 실행 순서가 불변식을 지켰다. 순서 불변식은 충돌하는 트랜잭션(같은 키, 문장 복제, 라벨 SYSOP_END)끼리 master 커밋 순서대로 반영된다는 것이고, 무관한 트랜잭션은 순서가 바뀌는 것이 정상이다(대조 검사로 확인).
- 한계 1: 알려진 키 유실 결함은 실제 코드에 남아 있고, 그 경로를 켜면 모델도 반례를 낸다. 위반 없음은 그 경로를 뺀 나머지에 대한 결과다.
- 한계 2: 크기 밖은 증명이 아니다. 순서 결함은 보통 트랜잭션 2~3개에서 드러나 강한 근거이지만 수학적 증명은 아니다.
- 한계 3: 모델은 코드를 읽고 옮긴 것이다. 놓친 동작이 있으면 결과가 달라진다. 마스터 영역은 "complete_mvcc 뒤 lock_unlock_all 전에 다른 쓰기가 못 들어온다"는 전제를 CBRD-27034 커밋 메시지에 기대고 있다.
- 한계 4: 단순화한 부분(키 해시 충돌, FK·UNIQUE 해시 세부, 실제 락 매니저 대기, 네트워크와 복사 로그, 재시도 오류 뒤 부분 반영)은 검사하지 않았다.
- 결론: 키 유실 수정을 전제로, 의존성 계산·slave 대기·재시작·승격의 핵심 규칙은 작은 크기에서 반례가 없다. 문제없음을 확정하려면 키 유실 수정과 HA 시험이 필요하다.

## 다음 작업

재현 우선순위, 증명하려는 내용, 테스트 방법은 next-plan.md에 정리했다. 요약하면 키 유실은 HA 재현과 수정, 되돌린 INCR은 같은 시나리오의 abort 변형, 커밋 시 복제 꺼짐은 코드 확인 먼저, 조각 누수는 수정 방법 결정 뒤 기존 누수 측정으로 전후 비교, 재시도 오류는 후순위, 미결 2PC는 작업하지 않는다.

## 11-07 코드 재확인: 키 유실 경로의 실제 도달 가능성

TLA+에서 재현한 키 유실 경로는 "사용자 행 키를 모은 system operation이 커밋 형태로 끝나며 라벨이 붙는다"는 단계를 전제로 한다. 첫 모델(WritesetSysop.tla)은 11-05 리뷰 설명을, sysop 확장 모델은 "DML을 담은 컨테이너 sysop의 커밋"을 이 단계로 추상화했다. 코드로 다시 확인한 결과는 다음과 같다.

- 사용자 행 키를 모으는 곳은 locator_add_or_remove_index_internal(locator_sr.c:8334, 8349), locator_update_index(9041-9064), 제자리 갱신(9325), serial(serial.c:1311)뿐이다.
- 이 키 수집을 감싸는 문장 단위 top operation은 모두 성공 시 바깥에 붙여(ATTACH_TO_OUTER) 끝난다. qexec_execute_update(query_executor.c:15743 시작, 성공 시 ATTACH), qexec_execute_delete, qexec_execute_insert, qexec_execute_merge, 클라이언트 flush xlocator_force(locator_sr.c:7317, 객체별·전체 모두 ATTACH 또는 ABORT)가 그렇다. LOG_RESULT_TOPOP_COMMIT을 쓰는 곳은 transaction_sr.c의 분기 하나뿐이고 DML 경로에서 쓰지 않는다.
- 붙여 끝나는 경로(log_sysop_attach_to_outer)는 레코드를 쓰지도, 라벨을 붙이지도, 키를 버리지도 않는다.
- 문장 안에서 커밋 형태로 끝나는 중첩 sysop(heap 페이지 할당, btree 분할 등)은 남은 INCR 레코드를 쓰고 라벨을 받을 수 있지만, 그 연산 안에서는 키를 모으지 않으므로 버려지는 사용자 키는 0개다.
- 커밋 형태로 끝나면서 키를 모으는 sysop은 instant 모드 INCR과 serial 갱신뿐인데, 둘 다 그 행 락이 SYSOP_END에서 풀리므로 키를 버리는 것이 맞다. instant 모드가 도중에 꺼진 INCR은 커밋이 아니라 붙여 끝나므로 키를 버리지 않는다.

판정: 사용자 행 키 유실은 지금 코드에서 도달 경로를 찾지 못했다(추정, HA trace로 확인 필요). 모델의 반례는 코드에 없는 "DML을 담고 커밋하는 sysop"을 가정한 결과일 가능성이 높다. 반면 되돌린 INCR 증가가 slave에 남는 문제는 키 수집과 무관하게 "남은 INCR 레코드가 뒤의 커밋 형태 중첩 sysop(페이지 할당 등)에서 쓰여 조각이 되는" 경로로 도달 가능하다.

확인 방법: next-plan.md 2절 시나리오를 master trace level 1로 돌려, 라벨 SYSOP_END 줄의 dropped_keys가 사용자 행 키에 대해 1 이상 나오는지 본다. 0만 나오면 키 유실은 도달 불가로 닫고, TLA+ 모델의 해당 동작에 "코드에서는 발생하지 않음"을 표시한다.

## 커밋 시점에 복제가 꺼지는 경우 (코드 분석 결과)

- log_does_allow_replication()(log_comm.c:272)은 서버 모드에서 HA가 켜져 있고 서버 상태가 ACTIVE 또는 TO_BE_STANDBY일 때만 참이다.
- 정상 전환에서는 커밋 도중 거짓이 되지 않는다. ACTIVE에서 TO_BE_STANDBY로 가도 복제는 허용되고, STANDBY로는 남은 클라이언트가 없을 때만 넘어간다(server_support.c:1555-1571, 1730-1738). STANDBY에서는 갱신 자체가 막힌다(logtb_disable_update).
- 강제 전환(force)은 상태를 즉시 바꾸므로(server_support.c:1671-1690) 진행 중 트랜잭션이 STANDBY·DEAD 등에서 커밋할 수 있다. 이때 커밋은 log_append_commit_log로 라벨·record_commit·발행 없이 쓰이고, 커밋 때 쓸 복제 레코드도 쓰이지 않는다.
- 영향: 그 트랜잭션의 남은 변경은 slave에 가지 않는다(develop과 같은 동작). 이미 로그에 나간 라벨 SYSOP_END 조각은 slave에 적용된다. slave 쪽 커밋은 라벨이 없어 링 꼬리까지 기다리고 항목이 없으면 태스크 없이 끝나므로 순서 문제는 없다. history에 이 커밋이 빠지지만, 반영할 변경이 없어 기다릴 대상도 없다.
- 판정: writeset 고유 결함 아님. 강제 전환 때 진행 중 트랜잭션의 변경이 복제되지 않는 것은 develop 공통 HA 제약이다. 재현하지 않는다.

## 큰 크기 무작위 시뮬레이션 (11-07 01:21~05:21, 각 4시간)

작은 크기 전수 검사의 크기 한계를 보완하려고 TLC simulate 모드로 네 모델을 키워 돌렸다(세션과 분리 실행, 결과 results/sim-SIM_*.txt). 무작위로 긴 실행을 뽑아 불변식을 검사하는 방식이라 전수 검사는 아니다.

- 마스터 의존성(SIM_master.cfg): 트랜잭션 6, 키 3, serial 1, 워커 4, 키 한도 3, REF·overflow·문장 복제·저장점·abort·메모리 부족 비우기·재시작·slave 모두 켬. 약 72억 7천만 상태 검사, 위반 없음.
- sysop 확장(SIM_sysop.cfg): 트랜잭션 5, 사용자 행 3, 트랜잭션당 동작 4, 중첩 2, abort와 ALTER SERIAL 켬, 워커 4. 약 19억 2천만 상태, 위반 없음.
- 슬레이브 코디네이터(SIM_slave.cfg): 트랜잭션 3, 키 3, frag 대본, 로그 6레코드, 크래시 3회, 비치명 result 오류, 워커 4. 약 4억 2천만 상태, 위반 없음. 트랜잭션 4개·로그 12레코드·라벨 3종은 초기 상태 열거가 끝나지 않거나 TLC의 다음 상태 수 한도에 걸려 줄였다.
- 재시작·failover(SIM_restart.cfg): 시나리오 F, master STANDBY 종료, 크래시 최대 6회, 승격 뒤 재기동. 약 9천만 상태, 위반 없음.

한계: 모델 자체의 가정(예: 슬레이브 모델의 "트랜잭션 첫 레코드 = 첫 복제 항목")은 크기를 키워도 그대로라, hgryoo 님이 HA에서 재현한 "롤백된 INCR 조각 + 재시작" 같은 모델 밖 경로는 이 시뮬레이션으로 잡히지 않는다. 모델과 코드의 차이는 실제 HA 무작위 워크로드로 확인해야 한다.

