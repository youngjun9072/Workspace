# 직렬 보장 분석: 워커 1개, 마커 확인, 복구 구간 직렬, 커밋 순서 보존 (2026-10-12)

코드 기준: `cubrid-applier` `feature/CBRD-27508-parallel-applylogdb-writeset` `9e6fb60b7` + 미커밋 주석 수정. 아래 내용은 코드 읽기로 판단한 것이고, 실행으로 확인한 것은 없다. 추정은 따로 표시했다.

## 1. 워커를 1개로 기동하면 직렬인가

**결론**: 한 번에 하나씩 적용되지만, 마스터 커밋 순서와 같다는 보장은 없다. 충돌 순서만 보장된다.

- `ha_apply_worker_count=1`이어도 develop 직렬 경로로 가지 않는다(`log_applier.c` `la_Info.worker_count = MAX (1, ...)`). 게이트와 pending 목록을 그대로 거친다.
- 태스크 큐는 FIFO 링이라 워커는 큐에 들어온 순서대로 처리한다. 하지만 큐에 들어가는 순서가 로그를 읽은 순서와 다를 수 있다.
  - **dependency 대기**: T1 실행 중, T2(dependency=T1)는 pending, T3(dependency NULL)은 바로 큐. 워커는 T1 다음 T3을 꺼내고, T2는 coordinator가 T1 결과를 거둬 frontier를 올린 뒤 큐에 들어간다. 적용 순서는 T1, T3, T2다.
  - **큐가 찼을 때**: 게이트를 통과한 태스크도 큐가 차면 pending으로 간다. `la_pending_pop_ready`는 못 나가는 태스크를 건너뛰고 뒤의 준비된 태스크를 먼저 꺼낸다.
- 순서가 바뀌는 쌍은 마스터가 충돌 없다고 판정한 쌍뿐이므로 최종 결과는 같다. writeset은 충돌을 없애는 것이 아니라 누구와 충돌하는지를 라벨로 남긴다.
- 차이가 드러나는 경우: writeset이 잡지 못하는 의존이 있을 때, 그리고 적용 도중 slave를 조회할 때(마스터에 없던 중간 상태가 보인다). SYSOP_END는 커밋 순서 라벨이라 앞 트랜잭션 뒤에 적용된다. DDL·statement 복제의 라벨은 확인하지 않았다(미확인).

## 2. 마커 트랜잭션으로 복제 완료를 판단할 수 있는가

시나리오: 마스터에서 T1(1천 건 INSERT) 커밋 후 T2(마커 INSERT). slave에서 마커가 보이면 복제 완료로 판단한다.

**결론**: 보장되지 않는다. 워커 1개여도 마찬가지다.

- T2는 T1과 다른 테이블·다른 키를 쓰므로 dependency가 NULL이다. 마스터의 시간 순서는 라벨에 남지 않는다.
- 워커 여러 개: T2가 다른 워커에서 바로 커밋될 수 있고, 그때 T1은 아직 적용 중일 수 있다.
- 워커 1개: 보통은 T1, T2 순서로 처리되지만, T1이 앞 트랜잭션과 충돌해 pending에 들어가면 T2가 먼저 적용된다.

**하니스 영향**

- `ha_bench-sysop-random/bin/run_insert.sh`, `bin/run_update.sh`가 이 방식이다. 데이터 세션 종료 후 `insert_replcheck`/`update_replcheck`에 한 행을 넣고, `lib/common.sh` `wait_for_replication_marker`가 slave에서 그 행을 보면 끝난 것으로 판단한다.
- writeset 측정에서는 측정 끝 시점이 실제보다 앞당겨질 수 있다(추정). 이전 백로그 측정값(INSERT 8.75s, UPDATE 6.20s)도 같은 방식이면 영향을 받았을 수 있다(추정, 로그 미확인). 폭은 마커가 읽힐 때 실행 중이거나 pending이던 분량 정도로 작을 가능성이 높다.
- `bin/run_sysop_random.sh`는 master/slave 상태가 두 번 연속 같을 때까지 기다리므로 영향이 없다.
- 확인 방법: `tools/timeline.py`로 기존 런 로그에서 마커 트랜잭션의 `done`과 마지막 데이터 트랜잭션의 `done`을 비교한다. 아직 하지 않았다.

**마커 방식을 유지하려면**

1. 마커 트랜잭션이 데이터 테이블의 키를 건드리게 한다(테이블마다 마지막 행 UPDATE 등).
2. 하니스에서 마커를 본 뒤 slave `_db_ha_apply_info`의 `committed_lsa`가 마커 커밋 LSA 이상이 될 때까지 기다리거나, 데이터 비교가 안정될 때까지 기다린다.
3. applier에 커밋 순서 보존 기능을 둔다(아래 5절 방식 2).

## 3. 복구 구간 직렬화 (`la_coordinator_serialize_recovery_window`)

**하는 일** (`log_applier.c`, `la_gate_order_push` 직전에 호출: SYSOP_END 분리 조각, 일반 COMMIT 두 곳)

1. `recovery_window_open`이 false면 바로 반환한다. 정상 운영 중에는 이 줄만 실행된다.
2. 태스크 commit LSA가 `recovery_boundary_lsa`를 넘으면 플래그를 끈다. 이 태스크는 아래 처리를 한 번 받는다.
3. 커밋 순서 링의 마지막(바로 앞에 받아들인 커밋)을 읽는다. 링이 비어 있으면 반환한다.
4. 태스크 `dependency_seq`가 NULL이거나 그보다 작으면 앞 커밋으로 올린다. 게이트가 앞 커밋 완료를 기다리게 되어 하나씩 적용된다.

**복구 구간에서만 직렬인 이유 (결함 3)**

- 마스터 라벨은 커밋 순서의 어떤 지점까지 빈틈없이 반영된 상태를 전제로 한 충돌 정보다. 정상 운영에서는 slave가 frontier까지 빈틈없이 반영돼 있으므로 이 전제가 맞다.
- 재시작하면 `committed_lsa`부터 다시 읽는데, `recovery_boundary_lsa`까지는 이전 실행에서 커밋된 것과 안 된 것이 섞여 있다. 뒤 트랜잭션까지 반영된 상태 위에 앞 트랜잭션을 다시 적용하면, 이미 있는 행의 unique 검사, 없는 행의 UPDATE·DELETE, 상태가 바뀐 부모 행의 FK 검사처럼 마스터와 다른 행을 건드릴 수 있다(가능한 경로, 추정).
- 실측: `load20-test-20261011-run2.md` 결함 3. trid 1561689와 1561679는 마스터에서 독립(부모 REF 키만 공유)이었고, 둘 다 이전 프로세스에서 이미 커밋됐다. 재기동 후 복구 구간(74503|1928 ~ 74524|13888)에서 병렬 재적용되어 워커끼리 교착 9건이 났다. 정상 운영 13분 동안은 0건이었다. 정확히 어느 락에서 엇갈렸는지는 확인하지 않았다.
- 하나씩 적용하면 다툴 상대가 없어 교착이 생기지 않는다. develop 직렬 applier의 재시작과 같은 방식이고, 재적용 오류(unique 중복, 대상 행 없음)는 워커가 무시한다(`in_recovery_window`, `recovery_skipped_counter`).
- 범위: 부팅 때 `recovery_boundary_lsa`가 NULL이 아닐 때만 켜지고, 상한을 넘는 첫 커밋에서 꺼진다. 같은 프로세스 안에서 다시 켜지지 않는다. 재적용 오류 무시는 플래그가 아니라 commit LSA 비교로 판단한다.
- 재시작 테스트가 없어 실제로 교착을 막는지는 미검증이다.

## 4. 이 함수로 강제 직렬화가 가능한가

**결론**: 가능하다. 항상 켜 두면 워커 수와 관계없이 커밋 순서와 같은 직렬이 된다. SYSOP_END 분리 조각도 포함되고, 마커 시나리오도 보장된다.

- 지금은 함수 첫 줄이 `recovery_window_open`을 보고 반환하므로, `recovery_window_open || 강제 직렬 모드` 같은 조건 추가가 필요하다(몇 줄).
- 의견: "워커 1개면 자동 직렬"보다 별도 파라미터나 디버그 설정이 낫다. 워커 1개는 병렬만 줄이려는 선택일 수 있고, 강제 직렬을 워커 수와 분리하면 "워커 N개 + 커밋 순서" 비교도 할 수 있다.

## 5. 직렬 보장과 develop 대비 속도

직렬 보장에는 두 가지가 있고, 속도 영향이 다르다.

| | 방식 1: 실행을 하나씩 | 방식 2: 실행은 병렬, 커밋만 순서대로 |
|---|---|---|
| 구현 | 4절의 serialize 방식을 항상 켬 | 워커가 `db_commit_transaction` 직전에 앞 커밋 완료를 기다림 (MySQL `replica_preserve_commit_order` 방식) |
| 보장 | 실행·커밋 모두 커밋 순서 | 바깥에서 보이는 커밋 순서가 마스터와 같음. 마커 시나리오 보장 |
| 병렬 이득 | 없음 | 적용 작업(행 찾기, 인덱스 갱신, FK 검사)은 겹치고 커밋 단계만 순서대로 |
| develop 대비 | 비슷하거나 느릴 가능성이 높음(추정). 손해: 트랜잭션마다 워커 → 결과 큐 → coordinator 수거 → frontier → 다음 해제 왕복, 그동안 워커 유휴, 워커 커밋마다 `_db_ha_apply_info` UPDATE. 이득: 워커가 적용하는 동안 coordinator가 다음 로그를 미리 읽음 | 빠를 수 있음(추정). MySQL도 이 옵션을 켠 채 병렬 이득을 냄 |
| 필요한 것 | 조건 몇 줄 | 워커가 커밋 순서를 볼 수 있는 동기화(커밋 순서 링 참조 등), 커밋 대기 교착 처리 |
| 위험 | 없음 | writeset이 못 잡은 충돌이 있으면 "T2는 락을 쥔 채 T1 커밋 대기, T1은 T2의 락 대기" 교착. applier 안의 대기라 서버 교착 탐지가 못 본다. MySQL처럼 탐지 후 뒤 트랜잭션 롤백·재시도 또는 타임아웃이 필요 |
| 용도 | 정확성 비교 실험(병렬 결과와 커밋 순서 결과 비교), 마커 방식 측정 | 커밋 순서가 필요한 운영 옵션 |

**정리**: "어떤 식으로든 직렬을 보장하면 develop보다 느려진다"는 방식 1에만 해당한다. 마커 시나리오에 필요한 것은 방식 2이고, 방식 2는 지금 구조를 유지하면서 develop보다 느려지지 않게 할 수 있다(추정). 둘 다 동작 변경이라 PR 뒤 단계에서 다룬다. 방식 2는 교착 처리 설계가 먼저 필요하다.

## 6. statement 트랜잭션은 slave에서 단독 실행되는가

**배경**: 10-12에 `la_update_query_execute`와 `la_update_query_execute_with_values`를 develop 본문(`db_execute`, `db_execute_with_values`)으로 되돌리고, 바깥에 `la_sql_compile_mutex`만 남겼다. 그 전 코드는 compile·실행을 단계별로 풀어 쓰면서 develop의 MVCC 스냅샷 무효화(`db_invalidate_mvcc_snapshot_before_statement`)가 빠져 있었다. 되돌린 근거는 "statement 트랜잭션은 마스터 라벨상 배리어라 다른 워커와 겹치지 않는다"는 것이고, 이 절은 그 근거를 마스터 코드로 확인한 결과다.

**의도한 동작**

- 앞쪽: statement 트랜잭션은 commit order 대체 경로(`wset_fallback_to_commit_order`)라 dependency가 `prev_commit_lsa`다. slave 게이트는 `dep <= frontier`(빈틈없는 완료 지점)로 판정하므로(`log_applier_gate.cpp` `la_gate_is_satisfied`) 앞선 커밋이 모두 끝나야 시작한다.
- 뒤쪽: 커밋 뒤 `wset_clear_overflow_history`가 이력을 비우고 `history_start`를 `prev_commit_lsa`로 올린다. 뒤 트랜잭션은 dependency가 이 값 아래로 내려가지 않는다(`wset_find_dependency_in_range` 끝의 하한 처리).

**확인 1: writeset 키가 없는 트랜잭션도 하한을 받는가 → 받는다**

- 데이터를 바꾼 트랜잭션은 키 유무와 관계없이 커밋 때 `wset_find_dependency_from_history`를 거친다(`log_manager.c` `log_commit_local`).
- 키가 없으면 루프를 돌지 않아 후보가 `history_start` 그대로이고, `min(후보, prev_commit)` 뒤 `history_start` 하한이 걸려 dependency = `history_start`가 된다.
- 데이터를 바꾸지 않은 트랜잭션은 복제 로그가 없어 slave에서 적용할 것이 없다.

**확인 2: 마스터 동시 커밋 경합 → 틈이 있다**

- 라벨 계산(`wset_find_dependency_from_history`)은 `prior_lsa_mutex` 밖에서, 커밋 레코드 추가(`log_append_repl_info_and_commit_log`, `prior_lsa_mutex` 안) 전에 한다. 이력 비우기(`wset_publish_commit_to_history` → `wset_clear_overflow_history`)는 커밋 레코드 추가 뒤에 한다. 세 단계가 한 임계 구역이 아니다.
- 뒤쪽 틈: B가 라벨을 계산한 뒤 statement 트랜잭션 S가 커밋·이력 비우기를 하고, 그다음 B가 커밋 레코드를 붙이면 B의 커밋 LSA는 S보다 뒤인데 dependency는 S보다 앞이다. slave에서 B가 S와 동시에 실행될 수 있다.
- 앞쪽 틈: S가 `prev_commit_lsa`를 읽은 뒤 A가 커밋 레코드를 붙이고, 그다음 S가 붙이면 A는 S보다 앞 커밋인데 S의 dependency는 A보다 앞이다. slave에서 S가 A와 동시에 실행될 수 있다.
- 틈에 들어갈 수 있는 것은 마스터에서 S와 락 충돌이 없던 트랜잭션뿐이다. 충돌하면 S가 락을 놓을 때(이력 비우기 뒤)까지 기다리므로 라벨 계산이 비우기 뒤로 밀린다. DDL은 클래스에 SCH-M 락을 잡으므로 같은 테이블의 DML은 틈에 들어갈 수 없다.
- 같은 틈이 다른 commit order 대체 경로(writeset 한도 초과, serial)에도 해당한다. SYSOP_END 경로(`wset_find_sysop_fallback_dependency`, `wset_raise_history_start`)는 따로 보지 않았다.

**영향 (추정)**

- 데이터 의미: 마스터에서 락 충돌 없이 동시에 진행된 쌍이므로, slave에서 동시에 실행돼도 결과는 같을 가능성이 높다. 일반 writeset 병렬과 같은 성격이다.
- slave 프로세스 안 공유 상태: 워커들은 클라이언트 workspace와 스키마 캐시를 프로세스 안에서 공유한다. 다른 테이블이라도 DDL이 클래스 객체·스키마 캐시를 바꾸는 동안 다른 워커가 locator로 행을 적용하면 공유 구조를 동시에 건드릴 수 있다. `la_sql_compile_mutex`는 SQL compile끼리만 막고 locator 경로는 막지 않는다. 문제가 생긴다면 이쪽이 더 유력하다.
- "statement는 단독 실행"은 보통은 맞지만 보장은 아니다. `la_sql_compile_mutex` 선언의 주석("A statement item runs alone among the workers")도 이 전제를 쓰고 있다.

**해야 할 일**

- [ ] DDL 시나리오 테스트에서 틈이 실제로 생기는지 확인: slave trace에서 statement 태스크의 begin~done 사이에 다른 워커의 begin/done이 끼는지 `timeline.py`로 본다. 마스터 `WSET_TRACE`의 `CLEAR reason=COMMIT_ORDER_FALLBACK`와 뒤 트랜잭션 `DEPENDENCY`를 맞춰 보면 뒤쪽 틈을 직접 찾을 수 있다. 부하(다른 테이블 DML)를 DDL과 동시에 걸어야 재현된다.
- [ ] 틈이 잡히면 결정: (a) 마스터에서 라벨 계산·커밋 레코드 추가·이력 비우기를 한 임계 구역으로 묶는다(커밋 경로 직렬화 비용 측정 필요), (b) slave에서 statement 태스크를 배리어로 처리한다(게이트가 statement 태스크 전후로 in-flight가 0일 때만 통과), (c) 데이터 의미상 문제없음을 확인하고 공유 상태 경합만 따로 막는다. 의견: (b)가 마스터를 건드리지 않고 slave 안에서 끝나 가장 단순하다(추정).
- [ ] 결정 뒤 `la_sql_compile_mutex` 주석의 "runs alone" 문장을 결과에 맞게 고친다.
- [ ] 같은 틈이 writeset 한도 초과·serial 대체 경로에 주는 영향 정리, SYSOP_END 경로 확인.

## 남은 일

- [ ] `timeline.py`로 기존 run_insert/run_update 로그에서 마커와 마지막 데이터 트랜잭션의 `done` 순서 확인
- [ ] 하니스 마커 판정 보강(2절 방법 1 또는 2) 여부 결정
- [ ] 강제 직렬 모드(방식 1) 추가 여부와 파라미터 형태 결정
- [ ] 커밋 순서 보존(방식 2) 설계: 워커 커밋 대기 수단, 교착 탐지·재시도
- [ ] DDL·statement 복제 태스크의 dependency 라벨 확인
- [ ] 결함 3 재시작 테스트로 복구 구간 직렬화 검증 (`recovery_window_open` 플래그 제거 todo와 함께)
- [ ] statement 단독 실행의 마스터 경합 틈 확인과 대응 결정 (6절)
