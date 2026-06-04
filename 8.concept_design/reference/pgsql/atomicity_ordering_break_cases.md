# PostgreSQL 논리복제: 원자성·순서·일관성이 깨지는 케이스 모음

> 자료조사 문서 · 조사 시점 2026-06-02
> 출처: PostgreSQL 공식 문서(1순위) + PostgreSQL 커밋터 블로그/AWS 문서(2순위)
> 용도: 병렬 적용 코디네이터 설계 시 "피해야 할/주의할" 깨짐 패턴 참고

## 요약
- 깨짐은 크게 **(A) 에러 없이 조용히 divergence** 와 **(B) 에러로 복제 중단(halt)** 두 부류다 — 위험한 쪽은 A다.
- **A: 조용한 divergence** — 구독 분할(cross-subscription), `REPLICA IDENTITY FULL`+중복 행, 시퀀스 미복제, publish 연산 일부만/대형 객체·DDL 미복제 [1][6][7].
- **B: 에러로 중단** — `REPLICA IDENTITY` 없는데 UPDATE/DELETE, unique 제약 충돌(로컬 쓰기/멀티 publisher), 스키마 불일치 [1][3][4].
- **parallel apply 특유** — `streaming=parallel`에서 publisher상 독립 트랜잭션이 subscriber 스키마 차이로 상호의존이 되어 **데드락**이 날 수 있다 [5].
- 대조: **행 필터(row filter)는 PostgreSQL이 UPDATE를 INSERT/DELETE로 변환해 divergence를 막아준다** — 깨지는 게 아니라 막아주는 케이스 [2].

## 본문

### 분류 기준

각 케이스를 "무엇이 깨지나(원자성/순서/divergence/halt)" + "조용한가(에러 없이)" + "재현 난이도"로 본다. 위험도는 **조용히 깨지는 것 > 에러로 멈추는 것**이다(후자는 최소한 알아챌 수 있으므로).

### A. 에러 없이 조용히 divergence (위험)

**A1. 구독을 가로지르는 트랜잭션 (cross-subscription)**
테이블을 여러 publication/구독으로 나눈 상태에서 한 트랜잭션이 두 구독의 테이블을 모두 바꾸면, 변경이 쪼개져 독립 apply worker가 적용 → 구독 간 원자성·순서 미보장 → 반쪽 적용/orphan. FK는 `session_replication_role=replica`라 미발화되어 **에러 없이** 깨진다 [9 → 별도 재현 문서 `repro_cross_subscription_atomicity.md`].
→ 깨짐: 원자성+순서 / 조용함: 예 / 재현: 쉬움(DISABLE로 결정적 재현).

**A2. `REPLICA IDENTITY FULL` + 중복(동일) 행 → 엉뚱한 행에 적용**
적절한 키가 없어 `REPLICA IDENTITY FULL`(행 전체가 키)을 쓰는 테이블에서, **완전히 동일한 행이 여러 개** 있으면 UPDATE/DELETE가 그중 매칭되는 한 행에만 적용되어 의도와 다른 결과가 날 수 있다 [7]. 또한 partition key를 동시에 UPDATE하는 경우 standby에 **중복 레코드가 생기는** 사례가 보고됐다 [7].
→ 깨짐: divergence / 조용함: 예 / 재현: 중간(중복 행·동시성 필요). (참고: FULL은 인덱스 없어 매 UPDATE/DELETE가 풀스캔이라 성능 문제도 동반 [7].)

**A3. 시퀀스(sequence) 미복제 → failover 후 값 어긋남**
serial/identity 컬럼의 "값"은 테이블 데이터로 복제되지만 **시퀀스 객체 자체는 복제되지 않는다** [1]. 평상시엔 문제없다가, subscriber로 switchover/failover하면 시퀀스가 start 값에 머물러 있어 **PK 충돌·중복 값**이 난다. failover 전 `pg_dump`나 테이블 max 값으로 시퀀스를 올려줘야 한다 [1].
→ 깨짐: divergence(후속 충돌) / 조용함: failover 전까지 예 / 재현: 쉬움(failover 시나리오).

**A4. publish 연산 일부만 / 대형 객체 / DDL 미복제 → 누락**
- publication을 `publish = 'insert'`처럼 일부 연산만으로 만들면 UPDATE/DELETE가 복제되지 않아 divergence [1].
- 대형 객체(large object)는 복제되지 않는다(우회책 없음, 일반 테이블로 저장해야) [1].
- DDL/스키마는 복제되지 않는다 — additive 변경을 subscriber에 먼저 적용하면 에러는 피하지만, 누락 컬럼 등으로 의미가 어긋날 수 있다 [1].
→ 깨짐: divergence / 조용함: 예 / 재현: 쉬움.

### B. 에러로 복제 중단 (loud — 최소한 알아챔)

**B1. `REPLICA IDENTITY` 없는데 UPDATE/DELETE 발행**
PK도 없고 replica identity가 `NOTHING`/없음인 테이블이 UPDATE/DELETE를 publish하면, subscriber에서 대상 행을 식별할 수 없어 `ERROR: cannot update/delete ... because it does not have a replica identity ...`로 **복제가 멈춘다** [1][3]. 해결: PK 추가, unique 인덱스 지정, 또는 최후수단 `REPLICA IDENTITY FULL` [3].
→ 깨짐: halt / 조용함: 아니오 / 재현: 쉬움.

**B2. unique 제약 충돌 → 복제 중단**
들어온 변경이 제약을 위반하면 복제가 멈춘다. 특히 **subscriber 로컬 쓰기**가 있거나 **여러 publisher**를 구독해 같은 키가 들어오면 unique 위반이 난다. PG17부터는 이를 `insert_exists` 등 **conflict로 상세 로깅**한다 [4]. 해결: `ALTER SUBSCRIPTION ... SKIP`(finish LSN), 데이터 수정, 테이블 재구성 [4].
→ 깨짐: halt / 조용함: 아니오(로그) / 재현: 쉬움(로컬 쓰기 후 같은 키 수신).

**B3. 스키마 불일치 → 에러**
publisher에서 스키마가 바뀌어 subscriber 테이블에 안 맞는 데이터가 오면 스키마를 맞출 때까지 에러 [1]. (A4의 DDL 미복제와 동전의 양면.)
→ 깨짐: halt / 조용함: 아니오 / 재현: 쉬움.

### C. parallel apply (`streaming=parallel`) 특유

**C1. publisher 독립 → subscriber 의존 → 데드락**
publisher에서는 서로 독립이던 대형 트랜잭션이, subscriber의 **스키마 차이(예: 추가 제약·트리거·인덱스)** 때문에 상호의존하게 되어 parallel apply worker 간 **데드락**이 날 수 있다 [5]. PostgreSQL은 commit 순서 보존·진도 추적(`lowest/highest/list_remote_lsn`)으로 이를 다루지만, 병렬 적용이 **out-of-order commit**을 만들어 진도 추적이 복잡해진다 [5].
→ 깨짐: 데드락/지연 / 조용함: 아니오(에러/대기) / 재현: 어려움(스키마 차이+동시성 필요).

**C2. (과거) 같은 테이블 다중 TRUNCATE 복제 데드락**
같은 테이블을 여러 번 복제 TRUNCATE할 때 데드락이 나던 버그가 있었고 이후 수정됐다 [7]. 버전에 따라 동작이 다를 수 있어 참고로만.
→ 깨짐: 데드락 / 재현: 버전 의존.

### D. 대조 — PostgreSQL이 divergence를 막아주는 케이스

**행 필터(row filter) UPDATE 전환**
publication에 `WHERE` 행 필터가 있을 때, UPDATE로 행이 필터 경계를 넘으면(old는 매칭/ new는 비매칭 등) PostgreSQL이 그 UPDATE를 **자동으로 INSERT 또는 DELETE로 변환**해 divergence를 막는다 [2]. 즉 이건 깨지는 케이스가 아니라 **막아주는 설계**다. (단, UPDATE/DELETE를 위해 필터가 replica identity 컬럼을 참조해야 하는 제약은 있다 [2].)

## 해결 방안 (다중 구독 cross-subscription, A1 중심)

A1(구독을 가로지르는 트랜잭션) 같은 cross-subscription 깨짐에 대한 해결책. 핵심 전제: **PostgreSQL엔 cross-subscription 일관성을 주는 네이티브 기능이 (아직) 없다** — 단일 구독 안에서만 commit 순서·원자성이 보장된다 [8]. 그래서 해결은 "회피 설계 + 안전한 병렬 경로 사용"으로 나뉜다.

### 지금 가능한 해결책

- **(A) 의존 테이블은 같은 구독에 묶기 (공식 권장)** — 구독 간 publication 객체가 겹치지 않게 하고, **엄격한 순서가 필요한 관련 데이터는 하나의 구독으로 합친다** [8]. 서로 트랜잭션으로 엮이는 테이블(FK·동일 Tx)은 같은 구독에, **완전히 독립적인 도메인/그룹만** 다른 구독으로 분리 → 트랜잭션이 구독 경계를 안 넘어 안전. 트레이드오프: 묶인 그룹은 병렬 안 됨(병렬 범위 = 독립 그룹 수).
- **(B) 쪼개지 말고 단일 구독 + `streaming=parallel`** — 대형 트랜잭션 병렬이 목적이면 테이블 분할 없이 단일 구독에서 얻는다. 단일 구독이라 **commit 순서·원자성 보존** + 대형 tx는 PA로 병렬. 한계: 대형 트랜잭션만 병렬(소형 OLTP엔 효과 적음), 그러나 **깨짐 위험 없음**.
- **(C) 소형 OLTP면 단일 구독 유지** — 짧은 트랜잭션이 대량이고 테이블을 넘나들면 다중 구독은 안전하게 병렬화 못 함. 단일 구독 유지 + apply 지연 자체를 줄이는 튜닝(스트리밍, 빠른 디스크/네트워크)이 옳다.
- **(D) 부득이 분리 시** — cross-subscription 트랜잭션을 배제 못 하면 subscriber에서 cross-subscription FK에 의존하지 말고(어차피 replica role이라 미enforce) 외부 reconcile/모니터링으로 보정 → 강한 일관성은 포기. **권장 아님.**

### 미래 / 제안 중 (아직 출시 안 됨)

- **비스트리밍(소형) 트랜잭션의 parallel apply** 가 커뮤니티에서 제안·논의 중이다 [5]. leader apply worker가 **트랜잭션 간 의존성을 식별**해 독립 트랜잭션을 병렬 적용하고 **commit 순서 유지 옵션**도 검토 — 즉 MySQL식 "단일 스트림 내 자동 의존성 병렬 + 전역 순서 보존". PG18 기준 **제안 단계**라 현재 해결책은 아니다.

### 정리

| 상황 | 해결책 |
|---|---|
| 관련 테이블 병렬화 필요 | (A) 같은 구독에 묶기 — 병렬 포기, 정합성 확보 |
| 대형 트랜잭션 병렬 | (B) 단일 구독 + `streaming=parallel` — 안전 |
| 소형 OLTP 대량 | (C) 단일 구독 유지 + lag 튜닝 |
| 진짜 독립 도메인 | 다중 구독 분리 OK (경계 안 넘음) |
| 자동·전역 병렬 | (미래 제안) 현재 네이티브 없음 |

> PostgreSQL에서 "다중 구독 병렬 + cross-subscription 일관성"을 동시에 주는 방법은 없다. 현실해는 **(A) 경계를 안 넘게 설계** 또는 **(B) 단일 구독 내 `streaming=parallel`**. 진짜 일반해(자동 의존성 병렬 + 순서 보존)는 PostgreSQL이 제안 중이며, 이는 **MySQL/CUBRID 코디네이터가 이미 목표로 하는 것**과 같다.

## 추론 / 유추
- 위 케이스 중 **A1(cross-subscription), A2(FULL+중복), C1(데드락)** 는 "병렬/분산 적용에서 식별·순서가 약해질 때 생기는 깨짐"으로, **CUBRID 병렬 applylogdb 코디네이터 설계에서 직접 대응되는 위험**이다 (← [5], [7]). 특히 class-level 코디네이터가 행 식별을 class 단위로만 하면 A2 유형(같은 class 내 동일/모호 행)에 주의가 필요할 수 있다 — CUBRID 코드 확인 대상.
- A3(시퀀스)·A4(DDL/large object)는 PostgreSQL **논리복제 일반 한계**라 물리복제(전체 블록 복제)에는 없는 문제다. CUBRID 복제가 논리 계열이면 유사 한계 가능성 — 별도 확인 필요 (← [1]).

## 미해결 / 자료 부족
- A2의 "REPLICA IDENTITY FULL + 동일 행 → 엉뚱한 행 적용"의 정확한 매칭 규칙(첫 매칭 행 선택 등)은 버전별 구현 확인이 필요. 본문은 보고된 동작 수준으로 기술.
- C1 데드락의 정확한 탐지·복구 메커니즘(commit 순서 강제와의 상호작용)은 커밋터 블로그·메일링 수준이며 공식 문서 단정 기술은 확보 못함 — 별도 정밀 조사 대상.
- 각 케이스의 버전별 동작 차이(특히 PG16 parallel apply 이후, PG17 conflict 로깅, PG18 streaming 기본화)는 운영 버전 기준 재확인 권장.

## References
[1] PostgreSQL Global Development Group. "29.8. Restrictions" (DDL·시퀀스·대형 객체 미복제, publish 연산, 스키마 변경 시 에러). PostgreSQL 18 Documentation, 2025. https://www.postgresql.org/docs/current/logical-replication-restrictions.html

[2] PostgreSQL Global Development Group. "29.4. Row Filters" (UPDATE가 필터 경계 넘을 때 INSERT/DELETE로 변환해 divergence 방지). PostgreSQL 18 Documentation, 2025. https://www.postgresql.org/docs/current/logical-replication-row-filter.html

[3] PostgreSQL Global Development Group. "29.1. Publication" (REPLICA IDENTITY 없는 테이블의 UPDATE/DELETE 제약). PostgreSQL 18 Documentation, 2025. https://www.postgresql.org/docs/current/logical-replication-publication.html

[4] PostgreSQL Global Development Group. "29.7. Conflicts" (제약 위반 시 복제 중단, 멀티 publisher/로컬 쓰기 unique 충돌, ALTER SUBSCRIPTION SKIP, PG17 conflict 로깅). PostgreSQL 18 Documentation, 2025. https://www.postgresql.org/docs/current/logical-replication-conflicts.html

[5] Amit Kapila (PostgreSQL committer). "Parallel Apply of Large Transactions" (스키마 차이로 인한 데드락, out-of-order commit 진도 추적 lowest/highest/list_remote_lsn). amitkapila16 blog, 2025-09. http://amitkapila16.blogspot.com/2025/09/parallel-apply-of-large-transactions.html

[6] pgDash. "PostgreSQL Logical Replication Gotchas". pgDash Blog. https://pgdash.io/blog/postgres-replication-gotchas.html

[7] Amazon Web Services. "Avoiding performance issues with REPLICA IDENTITY FULL in RDS for PostgreSQL" / PostgreSQL pgsql-hackers "concurrent update of partition key creates a duplicate record on standby". AWS Docs / PostgreSQL mailing list, 2023~2024. https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/PostgreSQL.ReplicaIdentityFull.html

[8] PostgreSQL Global Development Group. "29.2. Subscription" (단일 구독 내 트랜잭션 일관성 보장, 다중 구독 시 publication 객체 비중첩 권장). PostgreSQL 18 Documentation, 2025. https://www.postgresql.org/docs/current/logical-replication-subscription.html
