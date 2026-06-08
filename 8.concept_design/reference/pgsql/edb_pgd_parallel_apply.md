# EDB Postgres Distributed (PGD) — Parallel Apply

> 자료조사 문서 · 조사 시점 2026-06-05
> 출처: EDB 공식 문서(1순위, PGD v5/v6 Reference)
> ⚠️ **이 문서는 community PostgreSQL이 아니라 EDB의 상용 제품 PGD(구 BDR)** 를 다룬다. 같은 폴더의 다른 pgsql 문서(community PG)와 혼동하지 말 것.

## 요약

- PGD(EDB Postgres Distributed, 구 BDR)는 logical replication 기반 **멀티마스터** 제품이며, community PostgreSQL이 못 하는 **단일 구독 내 병렬 적용(Parallel Apply)** 을 제공한다 [1].
- Parallel Apply는 **구독(subscription)당 writer(적용 워커)를 여러 개** 둬서 처리량을 높인다. 기본 ON이고 끄려면 writer 수를 1로 둔다 [1].
- 병렬로 적용하더라도 **각 writer가 origin 노드의 commit 순서를 위반하지 않도록 보장**하며, 위반이 감지되면 **에러를 내고 트랜잭션을 롤백**한다 [1].
- 데드락/순서는 **행(tuple) 단위 선행 검사**로 회피한다 — 현재 트랜잭션이 쓰려는 행을 이미 예약한 트랜잭션이 있으면 그것이 커밋될 때까지 대기시킨다. 대기는 `nprovisional_waits`/`ntuple_waits`/`ncommit_waits` 메트릭으로 노출된다 [1].
- 의존성/충돌 판단을 **source가 아니라 apply 측(writer)** 에서 한다는 점이 MySQL(source-side writeset) 모델과 다르고, **Group Commit과는 비호환**이다 [1][4].

## 본문

### 1. PGD의 위치 — community PG와 무엇이 다른가

PGD는 pglogical 계열의 logical replication 위에 만들어진 EDB **상용 멀티마스터** 분산 Postgres 제품이다(구 명칭 BDR, Bi-Directional Replication). community PostgreSQL의 logical replication은 (별도 문서에서 정리했듯) **단일 구독 내 일반 트랜잭션을 직렬로 적용**하지만, PGD는 그 위에 **Parallel Apply** 를 얹어 단일 구독 스트림도 여러 writer로 병렬 적용한다 [1].

### 2. Apply 아키텍처 — receiver → 큐 → writer(s)

한 구독에서 변경이 들어오면, PGD는 **receiver(수신) 프로세스**가 스트림을 받아 **공유메모리 큐**를 통해 **writer(적용) 프로세스**에 넘긴다. "The receiver uses a shared memory queue to send data to the writer process. If the writer process is stalled ... the queue might get filled up, stalling the receiver process too" [5]. writer가 느리면 큐가 차서 receiver까지 막힌다(역압).

- **writer = 변경을 실제로 DB에 적용하는 워커.** "the database server tasks a worker process, called a writer, with getting those changes applied" [5].
- 이 writer를 **여러 개** 두는 것이 Parallel Apply다. 노드 그룹 단위로 writer 수를 설정할 수 있고 **`-1`은 GUC 기본값(`bdr.writers_per_subscription`)을 사용**한다는 의미다 [5].
- **writer 0은 비-스트리밍(non-streamed) 트랜잭션 전용으로 예약**된다 [5].

### 3. Parallel Apply 동작과 기본값

"Parallel Apply is a feature of PGD that allows a PGD node to use multiple writers per subscription" 이며, 일반적으로 구독 처리량을 높이고 복제 성능을 개선한다 [1]. "Parallel Apply is always on by default and, for most operations, we recommend leaving it on" [1][2].

### 4. commit 순서 보존 — 위반 시 에러 + 롤백

병렬 적용의 정합성 핵심: "**each writer ensures that the final commit of its transaction doesn't violate the commit order as executed on the origin node. If there's a violation, an error is generated and the transaction can be rolled back**" [1].

즉 writer들이 트랜잭션을 동시에 *실행*하더라도, **최종 commit은 origin(원본 노드)에서의 commit 순서를 어기지 않도록** 각 writer가 검사하고, 어기게 되면 그 트랜잭션을 에러 처리/롤백한다. (MySQL이 `replica_preserve_commit_order`로 큐 front 대기를 강제하는 것과 목적이 같고, PGD도 §5의 **선행 tuple-wait로 순서를 예방**한다 — 즉 PGD는 "예방(대기) + **위반 시 롤백 backstop**"이지 순수 낙관적 롤백이 아니다.)

### 5. 행(tuple) 단위 충돌 회피 — 데드락 완화

순서 위반(과거에는 데드락으로 나타나던 상황)을 **선행 검사**로 막는다: "For any transaction, Parallel Apply looks at transactions already scheduled for any row (tuple) that the current transaction wants to write. If it finds one, the row is marked as needing to wait until the other transaction is committed" [1]. → 같은 행을 건드리는 트랜잭션끼리는 **선행 트랜잭션 커밋까지 대기**시켜 행 쓰기 순서를 보장한다.

이 대기 정도는 `bdr.stat_subscription`의 세 컬럼으로 모니터링한다 [1]:

| 컬럼 | 의미 |
|---|---|
| `nprovisional_waits` | 동시 적용 트랜잭션들이 **같은 tuple**에 작업 중인 횟수(아직 실제 대기는 아니나 대기로 갈 수 있는 잠정 상태) |
| `ntuple_waits` | tuple 쓰기가 **안전하게 적용될 때까지 실제로 대기**한 횟수 |
| `ncommit_waits` | 적용은 끝났으나 **커밋 전 대기**한(commit 순서 보존을 위해) 트랜잭션 수 |

### 6. 설정 변수

| 변수 | 기본 | 범위/변경 방법 |
|---|---|---|
| `bdr.max_writers_per_subscription` | **8** | 구독이 할당할 수 있는 writer 상한. **변경 시 서버 재시작 필요** [1] |
| `bdr.writers_per_subscription` | **2** | 구독당 기본 writer 수. **재시작 없이** 구독 disable→설정→enable로 변경 [1] |
| `num_writers` (구독별) | (위 GUC) | `bdr.subscription` 테이블에서 구독 단위로 지정. disable→`UPDATE bdr.subscription SET num_writers=N`→enable [1] |
| 노드 그룹 옵션 | `-1` | `-1`은 GUC 기본값 사용을 의미 [5] |

- **변경 절차(무중단):** `bdr.alter_subscription_disable(...)` → `UPDATE ... num_writers` → `bdr.alter_subscription_enable(...)` [1].
- **비활성화:** "To disable Parallel Apply, set `bdr.writers_per_subscription` to `1`" [1].

### 7. Transaction Streaming과의 연계 (대형 트랜잭션)

PGD는 트랜잭션을 **publisher commit 이전에** subscriber로 스트리밍할 수 있다: "Decoded transactions can be streamed directly to a writer on the subscriber" [3]. community PG는 "transactions ... aren't sent to subscribers until the transaction is committed"인 반면, PGD는 **커밋을 기다리지 않고 적용을 시작**할 수 있다("you don't need to wait for the transaction to commit before starting to apply") [3]. 단 트랜잭션이 abort되면 그동안 적용/IO한 작업은 버려진다 [3].

- 스트리밍 모드: 노드 `bdr.default_streaming_mode`(`off`/`writer`/`file`/`auto`), 그룹 옵션(같은 값 + `default`) [3].
- **Parallel Apply가 꺼져 있으면(`num_writers = 1`) 파일로 스트리밍**된다("If Parallel Apply is off (`num_writers = 1`), then it's streamed to a file") [3][5].
- "Direct streaming to writer is still an experimental feature" [3].

### 8. 한계·비호환

- **Group Commit과 비호환:** "Parallel Apply isn't currently supported in combination with Group Commit" → Group Commit 사용 시 `num_writers=1` 또는 `bdr.writers_per_subscription`로 꺼야 한다 [4]. PGD v6에서 "Parallel Apply works with CAMO and Quorum Commit. It isn't compatible with Group Commit" [1].
- **community PostgreSQL에서의 제약:** PGD가 writer에 30초 `lock_timeout`을 걸기 때문에 "writer processes may terminate unexpectedly due to lock timeouts" → 회피책은 parallel apply 비활성화 또는 EDB Postgres로 이전 [4].
- **CAMO 관련:** "CAMO isn't currently compatible with transaction streaming" 및 "decoding worker"와도 비호환 [4].
- **Quorum/streaming:** transaction streaming은 `file`/`off` 모드를 제외하면 Quorum Commit과 비호환 [4].

### 9. apply 에러 시 재시도 — 횟수 제한 없음(확인된 범위)

writer가 에러(commit 순서 위반·데드락·충돌 등)를 만나면 트랜잭션을 롤백하고 다음과 같이 동작한다(이 거동은 PGD 기반인 pglogical worker 일반 에러 처리로 확인됨 [6]).

- 워커는 에러를 **PostgreSQL 로그**에 남기고, 가능하면 **`pglogical.worker_error` 테이블에 기록**한 뒤 **종료(exit)** 한다 [6].
- 그 DB의 **manager worker가 "few seconds 후" 워커를 재기동**하고, 워커는 실패한 트랜잭션을 **마지막 recoverable 지점부터 처음부터 재실행**한다(중간 복구가 아님) [6].
- **별도의 재시도 횟수 제한(retry count)은 없다.** 문서는 이 사이클이 **"원인이 고쳐질 때까지(until the cause of the error is fixed)" 반복**된다고만 한다 → 사실상 무한 재시도. 대부분의 에러는 transient라 재시도에서 성공한다 [6].
- 재기동 rate를 제어하는 설정 `pglogical.min_worker_backoff_delay`(최소 재기동 backoff 지연)가 있다 — "횟수 카운터"가 아니라 "재기동 간격" 제어 [6].
- (배경) commit 순서 위반의 비용은 ① 데드락 감지 ② 롤백 ③ 이미 적용한 변경의 간접 GC ④ 재실행(redo)의 합이라, PGD는 §5의 선행 tuple-wait로 **애초에 에러를 줄이는** 데 무게를 둔다 [1].

> ⚠️ **확인 못한 상세(명시):** 위는 pglogical worker **일반** 에러 처리 기준이며, **Parallel Apply writer 전용의 재시도 동작이 별도로 다른지**, `min_worker_backoff_delay`의 기본값·증가(backoff) 곡선, "원인 해결까지" 외의 **상한/포기 조건**은 공식 문서에서 **구체 내용을 찾지 못했다**(상용·소스 비공개). 정확한 동작은 EDB 문서/지원 확인 필요.

## 추론 / 유추

- PGD의 가장 큰 차별점은 **의존성/충돌 판단을 apply 측(writer)에서 행 단위로 한다**는 것이다. MySQL은 source(binlog writeset)에서 의존성을 미리 계산해 내려보내지만, PGD writer는 **적용 시점에 "같은 tuple을 쓰는 선행 트랜잭션"을 직접 보고** 대기를 건다 (← [1], [5]).
- commit 순서 보존 전략은 **"선행 tuple-wait 예방 + 위반 시 롤백 backstop"의 혼합**이다 — 같은 행 선행 트랜잭션을 대기시켜 순서를 예방하고(§5), 그래도 commit 순서가 어긋나면 롤백으로 막는다(§4). 순수 낙관적이 아니며, MySQL SPCO의 선제 대기와 목적이 같되 롤백 backstop이 더해진 형태로 보인다 (← [1]).
- transaction streaming + Parallel Apply를 함께 켜면 **대형 트랜잭션을 커밋 전부터 여러 writer로 적용**하는 셈이라, "대형 단일 트랜잭션"이 병목인 워크로드에서 이득이 클 가능성이 있다(단 abort 시 작업 폐기 비용) (← [3]).
- community PG(단일 구독 직렬) 대비, PGD는 "단일 구독 내 병렬"을 상용 기능으로 채운 사례다 — 즉 PG 생태계에서 병렬 apply는 **코어가 아닌 상용 확장 레이어**에서 제공된다 (← [1] + 같은 폴더 community PG 문서).

## 미해결 / 자료 부족

- **writer에 트랜잭션을 배정하는 스케줄링 규칙**(해시/라운드로빈/세션 고정 등)의 구체는 공식 문서에서 확인하지 못함 — 소스 비공개(상용).
- **"violation → error → rollback" 이후 재시도(retry) 메커니즘**: §9에서 "워커 재기동 → 처음부터 재시도 → 횟수 제한 없음(원인 해결까지)·`min_worker_backoff_delay`"까지는 확인. 다만 **Parallel Apply writer 전용 동작인지, backoff 기본값·상한/포기 조건은 공식 문서에서 찾지 못함**(상용·비공개).
- **commit 순서를 강제하는 내부 자료구조**(MySQL의 commit-order 큐에 대응하는 구조)의 세부 미확인.
- **v5 vs v6 정확한 호환성 차이**(예: v5에서 CAMO/Quorum과의 호환 여부) 원문 추가 확인 필요 — 본 문서의 호환성 진술은 주로 v6 기준 [1].
- §2의 receiver↔writer 공유메모리 큐 서술은 EDB docs 검색 색인 기반 요약이라, 단일 페이지 직접 인용으로 보강하면 더 정확하다 [5].

## References

[1] EDB. "Parallel Apply" (PGD v6 Reference). EDB Postgres Distributed Documentation, 2025. https://www.enterprisedb.com/docs/pgd/latest/reference/parallelapply/

[2] EDB. "Parallel Apply" (PGD v5). EDB Postgres Distributed Documentation, 2025. https://www.enterprisedb.com/docs/pgd/latest/parallelapply/

[3] EDB. "Transaction streaming" (PGD v6 Reference). EDB Postgres Distributed Documentation, 2025. https://www.enterprisedb.com/docs/pgd/latest/reference/transaction-streaming/

[4] EDB. "Known issues and limitations" (PGD v6). EDB Postgres Distributed Documentation, 2025. https://www.enterprisedb.com/docs/pgd/latest/known_issues/

[5] EDB. "PGD settings" / "Node management interfaces" (receiver–writer 아키텍처, `writers_per_subscription` 기본/`-1`, writer 0 예약). EDB Postgres Distributed Documentation, 2025. https://www.enterprisedb.com/docs/pgd/latest/reference/pgd-settings/

[6] EDB. "Error handling in pglogical"(워커 에러→`pglogical.worker_error` 기록·exit→manager 재기동·처음부터 재시도·원인 해결까지 반복·`min_worker_backoff_delay`). EDB Postgres Distributed Documentation. https://www.enterprisedb.com/docs/pgd/3.7/pglogical/troubleshooting/
