# PostgreSQL 논리복제: tablesync worker (초기 테이블 동기화)

> 자료조사 문서 · 조사 시점 2026-06-02
> 출처: PostgreSQL 공식 문서(1순위) + Fujitsu(postgresql.fastware) 블로그·소스(2순위)
> 용도: 병렬 적용 컨셉 레퍼런스 — 초기 동기화/catchup 패턴 참고 (reference/pgsql)

## 요약
- tablesync worker는 구독 생성·테이블 추가 시 **각 테이블의 기존 데이터를 `COPY`로 초기 동기화**하는 일시적 worker다 [1].
- 동시 동기화 병렬도는 `max_sync_workers_per_subscription`(기본 2) — 테이블당 worker 1개, 여러 테이블을 병렬 동기화 [2].
- 메커니즘: **스냅샷 슬롯으로 일관된 시점에 COPY → 그 시점부터 변경을 catchup → apply worker 위치를 따라잡으면 핸드오프** [1][4].
- 진행 상태는 `pg_subscription_rel.srsubstate`(카탈로그) + `SYNCWAIT`/`CATCHUP`(공유메모리)로 추적된다 [4][5].
- 주의: 초기 `COPY`는 publication의 `publish`(연산 필터)를 **무시하고 기존 데이터를 전부 복사**한다(행 필터는 적용) [1].

## 본문

### 1. 무엇을 하나

구독을 만들면(또는 새 테이블을 publication에 추가하면) subscriber에는 그 테이블의 **기존 데이터가 없다.** 변경 스트림만으로는 과거 데이터를 못 채우므로, **각 테이블마다 tablesync worker**가 떠서 publisher의 기존 데이터를 `COPY`로 가져온다. tablesync worker는 "특수한 apply 프로세스의 병렬 인스턴스"로 기술된다 [1].

- 테이블당 1개, **일시적**(해당 테이블 동기화 동안만 존재 후 종료) [1].
- 동시에 몇 개 테이블을 동기화할지는 `max_sync_workers_per_subscription`(기본 2)로 제어 [2]. 이 worker들도 `max_logical_replication_workers` 풀에서 나온다.

### 2. 스냅샷 COPY → catchup → 핸드오프 (정합성 메커니즘)

tablesync worker가 "복사 중에 들어온 변경"을 놓치거나 중복 적용하지 않도록, 스냅샷 + catchup으로 동작한다 [1][4].

**비유**: COPY는 "사진 한 장"이다. `LSN_copy` 시점에 테이블을 찰칵 찍는다. 그런데 사진을 인화하는 동안 publisher는 계속 흘러간다. **catchup = 사진 찍은 뒤 일어난 변화들을 따로 적용해 "지금"까지 맞추는 것**이다.

```text
publisher의 WAL (LSN 왼→오 증가, 계속 전진)
────●────────────────────────●──────────▶
   LSN_copy                  apply worker 현재 위치
  (COPY 찍은 시점)            (메인 스트림, 계속 전진)
    │←──────── gap ─────────→│
    │   COPY가 못 담은 변경들    │

tablesync worker가 하는 일:
 ① 슬롯 생성   → LSN_copy 시점을 "스냅샷"으로 고정
 ② COPY        → LSN_copy 시점의 테이블 전체를 적재          (= 사진 찍기)
 ③ catchup     → gap 구간(LSN_copy 이후)의 변경(delta)을 순서대로 적용
                 → apply worker 현재 위치까지 "따라잡기"
 ④ handoff     → 따라잡은 지점을 srsublsn에 기록, 이 테이블을 메인 apply worker에 인계
```

- **LSN이 두 개인 이유**: `LSN_copy`는 COPY를 찍은 **고정 시점**, apply worker 위치는 메인 스트림이 가 있는 **현재(계속 전진) 지점**이다. 둘 사이의 **gap**이 COPY가 놓친 구간이고, 이걸 메우는 게 catchup이다.
- catchup이 따라잡아 apply worker 위치와 같아지는 순간 → handoff.

세부 단계는 다음과 같다:

1. **스냅샷 슬롯 생성 + COPY** — tablesync worker가 자신의 replication slot을 `USE_SNAPSHOT` 옵션으로 만들고, 그 **일관된 스냅샷 시점(LSN)** 에서 `COPY`로 테이블 전체를 복사한다 [4]. COPY가 끝나면 그 테이블 내용이 다른 백엔드에 보이게 된다 [1].
2. **catchup(동기화 모드)** — COPY 시점 이후 publisher에서 일어난 변경을, **그 스냅샷 LSN부터** 표준 logical replication으로 받아 적용한다. 이때 변경은 **publisher에서 일어난 순서 그대로 적용·commit**된다 [1]. catchup은 "데이터를 다시 대조해 맞추는 것(reconcile)"이 아니라, 스냅샷이 멈춰 있는 동안 흘러간 **변경분(delta)을 적용해 라이브 위치까지 따라잡는(catch-up)** 것이다 — 단어 그대로 "따라잡기"다.
3. **핸드오프** — tablesync worker가 apply worker가 설정한 LSN을 따라잡으면(catchup 완료), 그 테이블의 복제 제어권이 **메인 apply worker로 넘어가고** 이후엔 일반 스트림으로 계속된다 [1][4].

이 구조 덕분에: COPY는 스냅샷 LSN의 일관된 시점을 잡고, catchup은 **정확히 그 LSN부터** 시작하므로 — 복사 중 변경이 **누락되지도, 중복되지도** 않는다.

### 3. 상태 추적 (pg_subscription_rel)

테이블별 동기화 상태는 두 곳에서 추적된다 [4][5]:

- **시스템 카탈로그 `pg_subscription_rel.srsubstate`** — 영속 상태. 대표 값:
  - `i` = initialize, `d` = data copy 중, `f` = finished copy(PG14+ 도입), `s` = synchronized, `r` = ready(일반 복제) [4][5].
  - `srsublsn` = 동기화가 완료되어 핸드오프된 LSN.
- **공유메모리 상태** — `SYNCWAIT`, `CATCHUP` 등 apply worker ↔ tablesync worker 간 **순간 조율 상태**(카탈로그엔 없음) [4][5].

`STATE_FINISHEDCOPY`(`f`)는 PG14에서 추가됐는데, 이는 **crash recovery 개선**과 관련된다 — COPY 완료 사실을 영속화해, 재시작 시 처음부터 다시 COPY하지 않고 이어가게 한다 [4].

### 4. 실패/재시작 처리

tablesync worker가 COPY 중 실패하면, **apply worker가 이를 감지해 tablesync worker를 재기동**해 동기화를 이어간다. 일시적 오류가 복제 전체를 영구히 망가뜨리지 않도록 하는 설계다 [1]. (PG14의 `FINISHEDCOPY` 상태·슬롯 영속화가 이 복구를 더 견고하게 만든다 [4].)

### 5. 주의점 (gotcha)

- **초기 COPY는 `publish`(연산 필터)를 무시한다** — publication을 `publish='insert'`로 만들어도, **초기 데이터는 전부 복사**된다. `publish`는 COPY 이후의 DML 스트림에만 적용된다 [1]. (단, **행 필터(row filter)는 초기 COPY에도 적용**된다 — 별도 동작 [참고: row filter 문서].)
- COPY는 `COPY` 명령처럼 동작하므로 대용량 테이블 초기화는 비용이 크다 — 병렬도(`max_sync_workers_per_subscription`)와 네트워크가 초기 동기화 시간을 좌우한다.

### 6. 교차 테이블 스냅샷 일관성 (기본 미보장)

질문이 자주 나오는 지점: "스냅샷 + COPY 하면 **모든 테이블이 동시에(같은 시점에) 스냅샷**이 떠지는가?" → **아니다.**

- **각 tablesync worker가 자기 슬롯·자기 스냅샷·자기 LSN**을 가진다. 테이블 A는 `LSN_a`, B는 `LSN_b`로 **서로 다른 시점**에 스냅샷이 잡힌다 — 전 테이블 동시 일관 스냅샷이 아니다 [1][4].
- **의도적 설계**: 전체 DB를 한 스냅샷으로 묶으면 복사가 끝날 때까지 하나의 xid/LSN을 붙잡아야 해 publisher에 bloat·디스크 부담이 크다. 테이블별 독립 스냅샷으로 **bloat를 줄이고 병렬 복사**를 가능하게 한 것이다 [1][4].
- **대가 — 초기 동기화 중 교차 테이블 불일치**: 테이블마다 스냅샷 시점이 달라 동기화 진행 중엔 "A는 이 시점 / B는 저 시점"인 **torn/orphan 상태**가 생길 수 있다. 다만 apply가 `session_replication_role=replica`라 **FK가 enforce되지 않아 에러는 나지 않고**, 모든 테이블이 catchup을 마쳐 단일 commit-ordered 스트림에 합류하면 **스스로 수렴(self-heal)** 한다. 즉 이는 **부트스트랩(초기) 동안만의 일시적 현상**으로, 운영 중 한 트랜잭션이 영구히 쪼개지는 cross-subscription(A1)과는 성격이 다르다.
- **교차 테이블 일관 시작점이 꼭 필요하면(수동)**: `pg_create_logical_replication_slot`로 **단일 일관 시점 + 스냅샷 export** → 그 스냅샷으로 `pg_dump --snapshot=...` 해서 **전 테이블을 같은 시점에** 복사 → `CREATE SUBSCRIPTION ... WITH (copy_data = false, create_slot = false, slot_name = ...)` 로 초기 COPY를 끄고 그 슬롯에서 변경만 이어받는다 [6].

| | 기본 tablesync | 수동(단일 스냅샷) |
|---|---|---|
| 스냅샷 시점 | 테이블마다 따로(LSN 제각각) | 전 테이블 동일 LSN |
| 초기 교차 테이블 일관성 | ❌ 미보장(일시 불일치, FK 에러는 안 남, 수렴) | ✅ 보장 |
| bloat/병렬 | 낮음/병렬 가능 | 단일 스냅샷 유지 비용 |
| 방법 | `CREATE SUBSCRIPTION`(copy_data 기본) | slot export + `pg_dump --snapshot` + `copy_data=false` [6] |

### 7. 예시 — 다중 구독(구독 4개 × 테이블 6개) 초기 복제와 풀 제약

**설정**: 구독 4개, 각 구독에 테이블 6개(총 24개). `max_sync_workers_per_subscription=2`(기본).

**① 초기 복제(tablesync) 단계**
- 구독당 동시 tablesync = 2개(테이블당 worker 1개). 개념상 "구독마다 2개씩 병렬 COPY".
- **그러나 풀에 막힌다.** tablesync worker는 `max_logical_replication_workers`(기본 **4**) 풀에서 나오고, 이 풀은 **leader apply worker + parallel apply worker + tablesync worker가 공유**한다. 구독 4개면 **leader apply worker만 4개**라 기본 풀 4를 **이미 다 차지** → **tablesync 슬롯 0** → 기본값으로는 "구독당 2개 동시"가 성립하지 않는다.
- 실제로 동시 진행하려면: 필요 동시 worker ≈ leader 4 + tablesync(4구독×2) 8 = **12** → `max_logical_replication_workers ≥ 12`, `max_worker_processes`도 그 이상(+병렬쿼리 여유, 예 ≥ 16)으로 **함께 상향**해야 한다.

**② catchup → 핸드오프**
- 각 tablesync worker가 스냅샷 COPY 후 그 시점부터 밀린 변경을 **catchup**으로 따라잡고, apply worker 위치에 도달하면 그 테이블을 메인 apply worker에 **핸드오프**한다(§2).

**③ 지속(실시간) 적용 단계**
- 핸드오프 후엔 **구독마다 leader apply worker 1개**가 지속 적용 → 구독 4개면 **4-way 병렬**(구독 단위 병렬).
- 단 **한 구독 안의 6개 테이블은 그 leader worker 1개가 commit 순서대로 직렬** 적용한다(테이블별 병렬 아님). 즉 전체가 24-way(4×6)가 아니라 **4-way**. (대형 트랜잭션만 `streaming=parallel`로 추가 병렬 — 테이블 단위가 아니라 트랜잭션 단위. → `parallelism_in_ha.md` §4·§5·§6)

**정리**: "초기엔 구독당 2개씩 tablesync 병렬 → catchup → 핸드오프 → 지속은 구독별 병렬"이라는 흐름은 맞다. 단 (a) 초기 동시성은 **풀(`max_logical_replication_workers`)에 막혀** 다중 구독에서는 풀 상향이 필수이고, (b) 지속 단계 병렬도는 **구독 수만큼(4-way)** 이며 한 구독 내부는 직렬이다.

## 추론 / 유추
- tablesync의 "스냅샷 시점 COPY → 그 LSN부터 catchup → apply worker와 합류" 패턴은 **초기 적재 후 무중단으로 스트림에 합류하는 일반적 정합성 패턴**이라, CUBRID에서 기존 데이터 초기화 + 복제 합류를 설계할 때 참고 가치가 있다 (← [1], [4]). 단 이는 "정상 운영 중 트랜잭션 병렬 적용"과는 축이 다른, **부트스트랩(1회성) 단계**의 병렬이다.
- `max_sync_workers_per_subscription` 병렬은 **테이블 단위**라, 테이블이 적거나 한 테이블이 거대하면 초기 동기화가 사실상 직렬화된다 — 병렬 효과가 테이블 분포에 좌우되는 점은 class-level 코디네이터의 hot-class 한계와 구조적으로 유사하다 (← [2]).

## 미해결 / 자료 부족
- tablesync 슬롯의 "임시(temporary) vs 영속(permanent)" 처리와 정리 시점은 버전에 따라 바뀌어 왔다(PG14 전후). 본문은 "테이블당 슬롯 생성 후 동기화 완료 시 정리 + FINISHEDCOPY로 crash recovery 개선" 수준으로만 기술 — 정확한 버전별 슬롯 수명은 별도 확인 권장.
- 초기 `COPY`가 트리거(row/statement)를 발화하는지 여부는 자료마다 진술이 갈린다(일부는 "INSERT 트리거 발화", 한편 apply는 `session_replication_role=replica`로 트리거 미발화). 버전·경로별 동작 확정은 별도 조사 대상.
- `pg_subscription_rel.srsubstate` 상태 코드의 전체 목록·전이는 버전별로 다를 수 있어 운영 버전 카탈로그 문서로 재확인 권장.

> **[CODE 분석 필요]** 본 문서의 메커니즘 상세 — catchup 상태 전이(`SYNCWAIT`/`CATCHUP` 조율), tablesync 슬롯의 생성·정리 수명, 스냅샷/LSN 처리, 핸드오프 시 `srsublsn` 기준으로 메인 apply worker가 이전 변경을 skip하는 로직, 교차 테이블 불일치의 수렴 경로 — 는 공식 문서+2순위 자료 수준이며 정확한 동작은 **소스 코드 분석으로 확정 필요**하다. 출발점: `src/backend/replication/logical/tablesync.c`(상태 머신·catchup), `worker.c`(apply worker의 per-table LSN 처리), 그리고 스냅샷 export 경로(`snapbuild.c`/`SnapBuildExportSnapshot`).

## References
[1] PostgreSQL Global Development Group. "29.9. Architecture" (tablesync worker, USE_SNAPSHOT COPY, catchup, 핸드오프, 실패 시 재기동, publish 무시). PostgreSQL 18 Documentation, 2025. https://www.postgresql.org/docs/current/logical-replication-architecture.html

[2] PostgreSQL Global Development Group. "19.6. Replication" / "29.12. Configuration Settings" (`max_sync_workers_per_subscription` 기본 2, worker 풀). PostgreSQL 18 Documentation, 2025. https://www.postgresql.org/docs/current/runtime-config-replication.html

[3] PostgreSQL Global Development Group. "pg_subscription_rel" (`srsubstate`, `srsublsn`). PostgreSQL 18 Documentation, 2025. https://www.postgresql.org/docs/current/catalog-pg-subscription-rel.html

[4] Fujitsu (postgresql.fastware). "Logical Replication Tablesync Workers" (상태 머신 SYNCWAIT/CATCHUP, FINISHEDCOPY(PG14), 슬롯·crash recovery). Fastware Blog. https://www.postgresql.fastware.com/blog/logical-replication-tablesync-workers

[5] PostgreSQL Source Code. `src/backend/replication/logical/tablesync.c` (tablesync 상태 머신·catchup 구현). PostgreSQL doxygen, 2025. https://doxygen.postgresql.org/tablesync_8c_source.html

[6] PostgreSQL 마이그레이션 패턴(2순위). 단일 일관 스냅샷 부트스트랩: `pg_create_logical_replication_slot` 스냅샷 export + `pg_dump --snapshot` + `CREATE SUBSCRIPTION ... WITH (copy_data=false)`. (예: pgcopydb 문서, Cloud SQL/마이그레이션 가이드) https://www.postgresql.org/docs/current/sql-createsubscription.html (copy_data 옵션) · https://pgcopydb.readthedocs.io/
