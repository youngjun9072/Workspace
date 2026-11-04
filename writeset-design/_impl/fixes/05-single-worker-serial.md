---
tags: [CBRD-27508, applier, fixes]
---
# 워커 1개 설정이 커밋 순서 적용을 뜻하지 않는 문제

작성: 2026-10-15. 작업 목록 ① 5번 "워커 1개 직렬 모드(게이트 우회)". 10-15 새벽 논의에서 1안(게이트 우회)으로 결정. 코드는 별도 커밋 a6f4f225c(미빌드·미검증, 접기는 승인 뒤). todo: `todo/CBRD-27508 - 워커 1개 직렬 모드(게이트 우회)`.

**2026-10-16 접힘**: 별도 커밋 a6f4f225c → slave 커밋 68dedb13c(지금 `45825ca17`). **2026-10-23 HA 검증 PASS**(아래 "HA 검증").

줄 번호는 수정 전 코드 기준(커밋 9593d1131 시점). 마지막 절의 수정 코드만 수정 후 줄 번호.

## 한 줄 요약

`ha_apply_worker_count=1`이어도 코디네이터는 의존 게이트를 그대로 탄다. 의존 때문에 pending에 보관된 트랜잭션을 뒤의 독립 트랜잭션이 추월하므로, 워커가 하나여도 slave 적용 순서가 커밋 순서와 다르다. 워커 1개면 게이트를 거치지 않고 FIFO 큐에 바로 넘겨 커밋 순서대로 적용하게 한다.

## 발생 조건

- `ha_apply_worker_count=1`.
- 의존 트랜잭션 T1(앞의 L에 의존) 뒤에 독립 트랜잭션 M이 커밋됨. 예: big 테이블 전체 UPDATE(L) → 같은 키 한 건 UPDATE(T1) → marker INSERT(M).
- L이 아직 적용 중일 때 T1, M이 읽히면 slave 적용 순서는 L → M → T1.
- 데이터 정확성 문제는 아니다(writeset 의존은 지켜진다). "워커 1개 = 직렬"이라는 운영상 기대와 다르고, 순서 보장이 필요한 검증·장애 분석에서 워커 1개를 기준으로 쓸 수 없다.

## 단계별 코드

### 단계 1. 코디네이터가 태스크를 넘기는 자리

`log_applier.c` → `la_coordinator_submit_task` (7473). 워커 수와 무관하게 같은 경로다.

```c
7477   error = la_coordinator_wait_for_commit_order_slot ();       /* 커밋 순서 링에 자리 확보 */
...
7486   error = la_gate_order_push (&task->commit_lsa);              /* 링에 기록 */
...
7492   error = la_coordinator_drain_ready ();                       /* pending 중 통과 가능한 것 먼저 */
...
7498   if (la_gate_is_satisfied (&task->dependency_seq) && !la_task_queue_is_full ())
7499     {
7500       return la_coordinator_dispatch_task (task, LA_SCHED_DISPATCHED);   /* 통과: 큐로 */
7501     }
7502
7503   error = la_pending_push (task);                              /* 미통과: 보관 */
7504   la_coordinator_trace_schedule (task, LA_SCHED_PARKED, UINT64_MAX);
```

### 단계 2. 게이트 판정

`log_applier_gate.cpp` → `la_gate_is_satisfied` (274). 의존이 frontier(연속 적용 완료 지점) 이하여야 통과.

```c
274 la_gate_is_satisfied (const LOG_LSA *dep)
275 {
...
278   if (LSA_ISNULL (dep))
279     {
280       return true;                                              /* 독립 트랜잭션은 항상 통과 */
281     }
282
283   return !LSA_ISNULL (&la_Gate_frontier) && LSA_LE (dep, &la_Gate_frontier);
```

L이 적용 중이면 frontier는 L 앞에 있다. T1(의존 = L)은 미통과, M(의존 NULL)은 통과.

### 단계 3. 시나리오 대입 (워커 1개)

| 코디네이터가 읽음 | 게이트 | 큐 | 워커 |
|---|---|---|---|
| L (독립) | 통과 | L | L 적용 시작 |
| T1 (의존 L) | 미통과 → pending | | L 적용 중 |
| M (독립) | 통과 | M | L 적용 중 |
| L 완료, frontier = L | `drain_ready`가 T1 방출 | M, T1 | M 적용 → T1 적용 |

워커는 큐 순서대로 M → T1을 적용한다. 큐가 FIFO라도 **큐에 들어간 순서**가 M, T1이기 때문이다. `la_coordinator_drain_ready` (732)는 "새로 읽은 커밋이 이미 통과 가능한 보관 태스크를 추월하지 않게" 하지만, M이 들어갈 때 T1은 아직 통과 불가였으므로 막지 못한다.

### 단계 4. 왜 워커 1개면 게이트가 필요 없나

게이트의 역할은 "의존 트랜잭션이 선행보다 먼저 **동시에** 적용되는 것"을 막는 것이다. 워커가 하나면 동시 적용이 없다. 큐에 넣은 순서 = 커밋 순서이고, 워커 하나가 그 순서대로 꺼내 적용하므로 선행은 언제나 먼저 끝난다. 게이트와 pending은 할 일이 없고, 오히려 단계 3처럼 순서만 흐트러뜨린다.

### 단계 5. 큐가 찼을 때

게이트를 건너뛰면 큐가 찼을 때 보관할 곳이 없다. `la_task_queue_push`는 찬 큐에 넣으면 assert다(`log_applier_task_queue.cpp:97`). 그러나 `la_coordinator_dispatch_task` (846) 첫 줄이 먼저 기다린다.

```c
852   error = la_coordinator_wait_for_inflight_slot ();
```

```c
1102   while (la_inflight_get_count () >= la_inflight_get_capacity ())   /* 결과 수거하며 대기 */
```

in-flight list 용량은 `LA_COMMIT_ORDER_CAPACITY(worker_count)` = worker_count × `LA_TASK_QUEUE_CAPACITY`(1024). 워커 1개면 1024 = 큐 용량. 큐에 있는 태스크는 retire 전이라 전부 in-flight list에도 있으므로, in-flight list에 자리가 있으면 큐에도 자리가 있다. 큐 가득 참 대기를 따로 짤 필요가 없다.

## 왜 문제인가

- **운영 의미가 어긋난다.** 워커 수를 1로 두는 것은 "develop처럼 직렬로 적용하라"는 뜻인데, 실제로는 의존 트랜잭션만 뒤로 밀리는 변형 병렬이 된다.
- **검증 기준선이 없다.** 순서 관련 문제를 조사할 때 워커 1개를 "순서가 보장된 대조군"으로 쓸 수 없다.
- **별도 옵션의 필요를 만든다.** 워커 수가 직렬·병렬 선택을 뜻하면 commit-order 전용 파라미터를 두지 않아도 된다.

## 해결 방안

### 채택: 워커 1개면 게이트와 pending을 건너뛰고 바로 큐에 (1안)

커밋 a6f4f225c, 수정 후 줄 번호.

```c
7491   error = la_gate_order_push (&task->commit_lsa);              /* 링 기록은 유지 */
7492   if (error != NO_ERROR)
7493     {
7494       return error;
7495     }
7496
7497   if (la_Info.worker_count == 1)
7498     {
7499       return la_coordinator_dispatch_task (task, LA_SCHED_DISPATCHED);
7500     }
7501
7502   error = la_coordinator_drain_ready ();
```

머리 주석에 추가한 문단:

```c
 *   With a single worker every task is handed over at once, so the worker takes them from the FIFO queue
 *   in commit order and nothing is parked: a parked task would let a later independent one pass it, and
 *   one worker is meant to apply the log in commit order. The queue cannot be full here, because the
 *   in-flight list has the same capacity as the queue and la_coordinator_dispatch_task waits for room in it.
```

- 분기 위치: `la_gate_order_push` 뒤, `la_coordinator_drain_ready` 앞. 커밋 순서 링은 frontier와 재시작 지점을 만드는 장부라 워커 수와 무관하게 기록한다. pending은 워커 1개면 항상 비어 있으므로 drain 앞에서 빠져도 된다.
- trace는 `LA_SCHED_DISPATCHED`로 찍혀 하니스 파서 변경 없음.
- frontier·복구 구간·SYSOP_END 조각·DDL 폴백은 완료 순서가 커밋 순서라 그대로 동작.

### 대안(기각)

- slave에서 모든 커밋의 의존을 직전 커밋으로 강제: 커밋마다 결과 수거를 기다려 버블이 생김.
- master에서 전부 폴백(`wset_fallback_to_commit_order`): master 동작이 바뀜.
- 적용은 병렬, 커밋만 커밋 순서(MySQL preserve_commit_order): failover 홀까지 없애는 정석이지만 락 교착 처리가 필요한 큰 작업. 장기 과제.

### 범위 밖

- 재시작 복구 구간 직렬화(작업 목록 3번). 워커가 여럿일 때 복구 구간만 "하나 넘기고 retire까지 기다리기"로 같은 자리에 붙일 수 있으나, 재시작 테스트에서 직렬화 필요가 확인된 뒤 반영. 그때 `la_coordinator_serialize_recovery_range`와 `recovery_range_open`은 삭제 대상.

## 적용 상태와 검증

- 코드: 별도 커밋 a6f4f225c (9593d1131 위). 번역 단위 컴파일 통과. 빌드·배포·실측 전. 접기는 사용자 승인 뒤.
- 검증 시나리오(todo 노트와 동일): big 테이블 전체 UPDATE(L) → 같은 키 한 건 UPDATE(T1) → marker INSERT(M). 워커 1에서 slave 적용 순서 L → T1 → M, 워커 2 이상에서 L → M → T1 허용. trace 1의 `reader schedule status=2`(보류)가 워커 1에서는 0건, `worker apply begin/done` 순서로 확인.
- 워커 1 경로는 게이트를 안 타므로 게이트 경로 테스트는 워커 2 이상으로 따로 돈다.

### HA 검증 (2026-10-23 17:44, 빌드 2786-8823088, `ha_bench_tool/log/verify_worker1_order_20261023_174355/`) — PASS
youngjun4에만 `cubrid_ha.conf.slave_w1_t2`(기준 ea141281에서 `ha_apply_worker_count=1`, `ha_writeset_trace_level=2`)를 배포하고 applylogdb만 재기동했다. 기동 알림 "applylogdb runs one apply worker: transactions are applied in commit order" 확인. 하니스 `verify_worker1_order.sh`.

| 트랜잭션 | master 작업 | slave trid | 적용 행 | 의존(라벨) | 스케줄 | 적용 순서 |
|---|---|---|---|---|---|---|
| L | `update big set v=v+1` (512000행) | 488913 | 512000 | `24580\|12864` | status=0 | 1 (9.0초) |
| T1 | `update big set v=v+1 where id=1` | 488945 | 1 | L의 커밋 `32793\|6200` | status=0 | 2 |
| M | `insert into marker values (1,'M')` | 488950 | 1 | L의 커밋 `32793\|6200` | status=0 | 3 |

- worker 0 하나가 L → T1 → M 순서로 begin/end 했다. 이 구간의 스케줄 10건이 모두 status=0(보류 0건)이다.
- 데이터: big 합계 512001, marker 1행으로 양쪽 같다.
- M의 라벨도 L의 커밋이었다. L이 512000개 키로 writeset 상한을 넘어 commit order로 떨어지고, master가 history 하한을 L의 커밋으로 올렸기 때문으로 보인다(추정). 그래서 이 시나리오에서는 워커가 여럿이어도 M이 L을 기다린다. "워커 2 이상에서 L → M → T1 허용"을 보려면 L을 writeset 상한 아래 크기로 줄여야 한다.
- 하니스 수정: 긴 트랜잭션은 `reader commit`에 `items=1`로 찍혀 L을 찾지 못하고 INCONCLUSIVE가 났다. `worker apply end ... rows=`로 크기를 보도록 고쳐 같은 로그를 다시 판정했다.
- 시험 뒤 youngjun4 conf를 ea141281로 되돌리고 applylogdb를 재기동했다(worker 10, trace 1).

## 로깅·assert (커밋 3924469c6)

- 기동 시 워커 수가 1이면 NOTIFICATION `applylogdb runs one apply worker: transactions are applied in commit order`.
- assert: 우회 경로에서 `la_pending_is_empty ()` (이 모드에선 아무것도 보류되지 않는다).

## 상세 설계용 요약 (8-2.3 스케줄링 또는 설정 절에 넣을 후보)

### 왜 이런 처리가 필요한가

의존 게이트는 여러 워커가 **동시에** 적용할 때 의존 트랜잭션이 선행을 앞지르지 못하게 하는 장치다. 워커가 하나면 동시 적용이 없으므로 게이트가 막을 것이 없고, 대신 게이트가 보관한 태스크를 뒤의 독립 태스크가 추월해 적용 순서를 커밋 순서에서 벗어나게 한다. 워커 수 1은 "커밋 순서대로 적용"이라는 운영상 의미를 가져야 하므로, 이 경우 게이트를 거치지 않고 FIFO 큐에 바로 넘긴다. 커밋 순서 링은 적용 방식과 무관하게 frontier와 재시작 지점을 만들므로 그대로 기록한다.

### 설계 요구사항

- `ha_apply_worker_count=1`이면 slave 적용 순서 = master 커밋 순서. 별도 commit-order 옵션은 두지 않는다.
- 워커 2 이상이면 설계대로 독립 트랜잭션은 바로, 의존 트랜잭션은 게이트에서 기다린다.
- 워커 1개 경로에서 큐 오버플로가 없도록 in-flight list 용량 = 워커 수 × 큐 용량을 유지한다.
