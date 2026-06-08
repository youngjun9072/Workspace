# PostgreSQL 논리 복제: Publisher/Subscriber · 구독 · 등록 과정 · 옵션

> 자료조사 문서 · 조사 시점 2026-06 · 출처: PostgreSQL 공식 문서(current, 1순위)
> 같은 폴더 `parallelism_in_ha.md` §3(pub-sub 모델 기초)·`tablesync_worker.md`(초기 동기화)와 짝을 이루며, 이 문서는 **구독 등록 과정과 옵션 카탈로그**에 집중한다.

## 요약

- PostgreSQL 논리 복제는 **Publisher(발행)·Subscriber(구독) 역할**의 노드와, 실제 객체인 **`PUBLICATION`**(무엇을 보낼지)·**`SUBSCRIPTION`**(무엇을 어디서 어떻게 받을지)으로 구성된다 [1][2][3].
- 구독을 만들면 내부적으로 **① publisher에 복제 슬롯 생성 → ② tablesync 워커가 기존 데이터 초기 COPY → ③ 정상 스트리밍 적용** 으로 전이한다 [1][3].
- **초기 데이터 COPY는 publication의 `publish` 연산 설정과 무관하게 전부 복사**되고, 그 이후의 스트리밍부터 `publish`(insert/update/delete/truncate) 제한이 적용된다 [1][3].
- `CREATE SUBSCRIPTION`의 동작은 `connect`·`create_slot`·`enabled`·`copy_data`·`streaming`·`origin`·`two_phase` 등 **WITH 옵션**으로 세밀하게 제어한다(기본값은 본문 표) [1].
- 진도는 publisher 측 **복제 슬롯**과 subscriber 측 **replication origin**으로 추적되어, 끊겼다 재개해도 빠짐없이 이어받는다 [3].

## 본문

### 1. 노드 역할(Publisher / Subscriber)과 객체(PUBLICATION / SUBSCRIPTION)

`publisher`/`subscriber`는 **객체가 아니라 서버(노드)의 역할**이다. 실제 데이터베이스 객체는 둘이다 [1][2][3].

- **PUBLICATION**(발행 명세) — publisher에서 `CREATE PUBLICATION`으로 정의. "어떤 테이블의, 어떤 연산을 내보낼지". 카탈로그 `pg_publication`.
- **SUBSCRIPTION**(구독 명세 + 접속 정보) — subscriber에서 `CREATE SUBSCRIPTION`으로 정의. "어느 publisher의 어떤 publication을, 어떻게 받아 적용할지". 카탈로그 `pg_subscription`.

`CREATE PUBLICATION`을 한 서버가 publisher 역할, `CREATE SUBSCRIPTION`을 한 서버가 subscriber 역할이며, 한 서버가 둘 다 가질 수도 있다(캐스케이딩/양방향). 전제로 publisher 인스턴스는 `wal_level = logical`이어야 한다 [3].

### 2. "구독(subscription)"이란

구독은 **"이 publisher의 이 publication을 받아, 내 로컬 테이블에 계속 적용하겠다"는 등록된 약속**이다. 한 subscriber 노드에 **여러 개의 SUBSCRIPTION 객체**를 둘 수 있고, 각 구독은 자기 leader apply 워커 1개로 적용된다(그래서 병렬 단위는 노드가 아니라 구독 객체 수 — 상세 `parallelism_in_ha.md` §4). 구독은 하나의 **상시 스트리밍 연결**을 subscriber가 열어(pull) 두면, 그 위로 publisher가 변경을 계속 push하는 형태로 동작한다 [3].

### 3. 구독 등록 과정 (lifecycle)

`CREATE SUBSCRIPTION`은 단순한 등록이 아니라 아래 단계를 수행한다 [1][3].

```text
CREATE SUBSCRIPTION 실행
   │
   ├─(1) publisher에 접속 (CONNECTION 정보)           ← connect=true 일 때
   │
   ├─(2) publisher에 복제 슬롯 생성                     ← create_slot=true 일 때
   │      (슬롯 = "이 구독이 어디까지 받았나"를 publisher가 보존)
   │
   ├─(3) 초기 데이터 동기화 (copy_data=true 일 때)
   │      · tablesync 워커가 published 테이블을 COPY 로 스냅샷 복사
   │      · 테이블마다 임시 동기화 슬롯(pg_%u_sync_%u_%llu) 사용 → 끝나면 자동 삭제
   │      · ※ 초기 COPY는 publication의 publish 연산 설정과 무관하게 전부 복사
   │
   └─(4) 정상 스트리밍 적용으로 전이                     ← enabled=true 일 때 commit 시점부터
          · 메인 복제 슬롯으로 변경 stream 수신
          · 이때부터 publish 연산 제한·행 필터가 적용됨
          · apply 워커가 LSN feedback → publisher 슬롯 전진
```

핵심 전이는 **초기 COPY(스냅샷) → 정상 스트리밍**이다. tablesync 워커는 자기가 맡은 테이블을 COPY로 채운 뒤, 그 시점 이후의 변경은 메인 apply 워커가 이어받도록 핸드오프한다(정합성 메커니즘 상세는 `tablesync_worker.md`). 슬롯을 만드는 기본 모드에서는 **`CREATE SUBSCRIPTION`을 트랜잭션 블록 안에서 실행할 수 없다** [1].

등록 이후 상태 제어는 `ALTER SUBSCRIPTION`으로 한다 — `DISABLE`/`ENABLE`로 일시 정지·재개, `REFRESH PUBLICATION`으로 발행 테이블 목록 변경 반영, `SET (slot_name = NONE)`으로 슬롯 분리 후 `DROP` 등 [3].

### 4. CREATE PUBLICATION 옵션과 동작

| 절 / 옵션 | 기본값 | 동작 |
|---|---|---|
| `FOR TABLE t1, t2` | — | 지정 테이블만 발행. `ONLY`는 상속 자식 제외, `*`는 자식 포함 [2] |
| `FOR TABLES IN SCHEMA s` | — | 스키마 s의 모든 테이블(향후 생성 포함) 발행 [2] |
| `FOR ALL TABLES` | — | DB의 모든 테이블(향후 포함) 발행 [2] |
| `WITH (publish = ...)` | `insert, update, delete, truncate` | 복제할 DML 연산 선택. 예: `publish='insert'`면 UPDATE/DELETE는 스트리밍에서 제외 [2] |
| `WITH (publish_via_partition_root)` | `false` | true면 파티션 변경을 **루트 테이블 정체성**으로 발행, false면 개별 파티션으로 [2] |
| `WITH (publish_generated_columns)` | `none` | 생성 열(generated column) 복제 여부. `stored`면 stored 생성 열도 발행 [2] |
| 행 필터 `... WHERE (조건)` | — | 발행할 행을 조건으로 거름. **UPDATE/DELETE에는 `REPLICA IDENTITY` 열만** 사용 가능(괄호 필수) [2] |
| 열 목록 `(col1, col2)` | — | 복제할 열 선택. UPDATE/DELETE면 `REPLICA IDENTITY` 열 포함 필수. `FOR TABLES IN SCHEMA`와 비호환 [2] |

> 주의: **초기 COPY는 `publish` 설정과 무관하게 전부 복사**되고, `publish` 제한·행 필터는 그 이후 스트리밍 단계부터 적용된다 [1][3].

### 5. CREATE SUBSCRIPTION 옵션 카탈로그와 옵션별 동작

`CONNECTION '...'`(접속 문자열)과 `PUBLICATION p1[, p2]`(구독할 발행) 뒤에 `WITH (...)` 옵션으로 동작을 정한다 [1].

| 옵션 | 기본값 | 동작 |
|---|---|---|
| `connect` | `true` | false면 publisher에 접속하지 않음 → `create_slot`·`enabled`·`copy_data`가 강제로 false가 되어, 슬롯/REFRESH를 수동으로 해야 함 |
| `create_slot` | `true` | publisher에 복제 슬롯을 생성할지. 기존 슬롯에 붙일 땐 false |
| `enabled` | `true` | false면 설정만 하고 복제를 시작하지 않음(나중에 `ALTER ... ENABLE`) |
| `slot_name` | (구독 이름) | 사용할 publisher 슬롯 이름. `NONE`이면 슬롯과 연결하지 않음(분리/이전 시나리오) |
| `copy_data` | `true` | 시작 시 기존 데이터를 초기 COPY할지. false면 스냅샷 없이 이후 변경만 적용 |
| `binary` | `false` | 데이터를 바이너리 포맷으로 받을지(빠르나 이식성↓, 모든 타입에 binary send/recv 필요) |
| `streaming` | `parallel` | 진행 중(미commit) 대형 트랜잭션 처리: `off`(publisher가 commit까지 모았다 전송) / `on`(subscriber가 임시파일에 받아 commit 후 적용) / `parallel`(parallel apply 워커로 직접 적용, 없으면 임시파일) |
| `synchronous_commit` | `off` | 이 구독 apply 워커의 `synchronous_commit` 동작을 따로 지정(복제 적용 지연/내구성 트레이드오프) |
| `two_phase` | `false` | 2단계 커밋(prepared tx)을 PREPARE 시점에 전송·적용할지 |
| `disable_on_error` | `false` | apply 워커가 에러를 만나면 구독을 자동 비활성화할지(무한 재시도 루프 방지) |
| `origin` | `any` | `none`이면 origin이 없는 변경만 수신(양방향에서 되돌림 방지), `any`면 origin 무관 수신 |
| `run_as_owner` | `false` | true면 모든 적용을 구독 소유자 권한으로, false면 각 테이블 소유자 권한으로(더 안전) |
| `password_required` | `true` | publisher 접속에 암호 인증 강제(슈퍼유저는 무시; false 설정은 슈퍼유저만) |
| `failover` | `false` | 논리 복제 failover 지원을 위해 슬롯을 standby로 동기화할지 |

`streaming` 세 값의 차이가 병렬성과 직결된다 — `parallel`이 단일 대형 트랜잭션을 commit 전부터 parallel apply 워커로 적용해 지연을 줄인다(상세 `parallelism_in_ha.md` §5). 단 이는 **한 트랜잭션의 조각** 병렬일 뿐, 여러 트랜잭션을 의존성 기준으로 병렬화하는 것은 아니다.

### 6. 진도 추적 — 슬롯과 replication origin

- **복제 슬롯(publisher 측)**: 각 활성 구독은 publisher의 슬롯 1개로 변경을 받는다. 슬롯은 subscriber가 아직 안 받은 WAL이 제거되지 않도록 보존하므로, 구독을 못 받는 채로 두면 publisher에 **WAL이 쌓인다**(슬롯 분리·정리 필요) [3].
- **replication origin(subscriber 측)**: subscriber는 어디까지 적용했는지를 origin으로 기록해, 재시작 시 그 지점부터 이어 적용한다. apply가 LSN feedback을 보내면 publisher 슬롯이 전진한다 [3].

### 7. 매칭·제약 (등록 시 알아둘 점)

- **스키마(DDL)는 복제되지 않는다** — published 테이블이 subscriber에 미리 존재해야 한다 [3].
- 복제 대상은 **일반 테이블만**(뷰 불가). 테이블은 **완전한 이름**으로 매칭(다른 이름 테이블로 복제 불가), 열은 **이름**으로 매칭 [3].
- 열 타입이 정확히 같지 않아도 텍스트 표현이 변환 가능하면 됨(예: `integer→bigint`). subscriber에 추가 열이 있으면 기본값으로 채워짐 [3].

### 8. 구성 설정 (서버 GUC) — publisher / subscriber

§5의 WITH 옵션이 "구독 단위" 설정이라면, 아래는 논리 복제가 동작하기 위해 **양 노드의 서버 인스턴스에 두는 GUC**다. 각 GUC는 한쪽 노드에만 적용된다 [4]. *GUC(Grand Unified Configuration)는 PostgreSQL이 서버 설정 파라미터를 부르는 용어로(소스의 `guc.c`에서 유래), `postgresql.conf`/`ALTER SYSTEM`으로 설정하는 값들이다 — CUBRID의 시스템 파라미터(`cubrid.conf`)에 해당한다.*

**publisher 측**

| GUC | 기본값 | 의미 · 설정 기준 |
|---|---|---|
| `wal_level` | `replica` | 논리 복제하려면 **`logical`** 필수(값별 의미는 아래 표) |
| `max_replication_slots` | `10` | 슬롯 최대 수. **예상 구독 수 + 테이블 동기화 여유** 이상 |
| `max_wal_senders` | `10` | WAL sender 최대 수. **`max_replication_slots` + 동시 물리 복제본 수** 이상 |
| `wal_sender_timeout` | `60s` | 비활성 복제 연결 종료 시간(논리 WAL sender에도 적용) |
| `idle_replication_slot_timeout` | `0`(비활성) | 일정 시간 idle인 논리 슬롯을 무효화 |

**subscriber 측**

| GUC | 기본값 | 의미 · 설정 기준 |
|---|---|---|
| `max_active_replication_origins` | `10` | origin 최대 수. **구독 수 + 테이블 동기화 여유** 이상 |
| `max_logical_replication_workers` | `4` | 논리 복제 워커 풀. **구독 수(leader apply) + tablesync + parallel apply 여유** 이상 |
| `max_worker_processes` | `8` | 배경 프로세스 총량. 최소 **`max_logical_replication_workers + 1`**(확장·병렬쿼리도 이 풀 사용) |
| `max_sync_workers_per_subscription` | `2` | 초기 데이터 COPY(tablesync) 병렬도 |
| `max_parallel_apply_workers_per_subscription` | `2` | `streaming=parallel`일 때 진행 중 트랜잭션 병렬 적용 워커 수 |
| `wal_receiver_timeout` | `60s` | 수신 측 비활성 연결 종료 |
| `wal_receiver_status_interval` | `10s` | 진도 보고(feedback) 최소 주기 |
| `wal_retrieve_retry_interval` | `5s` | WAL 재수집 재시도 간격 |

**`wal_level` 값(publisher)** — 세 값의 차이가 "무엇을 복제할 수 있는가"를 가른다(상세는 같은 폴더 `wal_level.md`).

| 값 | WAL 양 | 무엇이 가능한가 |
|---|---|---|
| `minimal` | 최소 | crash recovery만. 아카이빙·스트리밍 복제·logical decoding **모두 불가** |
| `replica` (기본) | 중간 | 아카이빙 + **물리** 스트리밍 복제 + standby 읽기. logical decoding **불가** |
| `logical` | 최대 | `replica`의 모든 것 + **logical decoding(논리 복제)** 에 필요한 추가 정보 |

→ 논리 복제(그리고 그 위의 모든 parallel apply)는 publisher가 **`wal_level=logical`** 이어야 비로소 성립한다. 다만 **병렬도 자체는 `wal_level`이 아니라** subscriber의 워커 GUC(`max_logical_replication_workers`·`max_worker_processes`)와 구독 옵션 `streaming=parallel`이 정한다 — `wal_level=logical`은 "논리 복제가 가능해지는 전제"일 뿐, 병렬화의 직접 스위치는 아니다.

**`wal_level` 미충족 시 동작 (코드 확인 [5]).** publisher가 `minimal`/`replica`인 채로 `CREATE SUBSCRIPTION`(기본 `connect=true`·`create_slot=true`)을 하면, subscriber가 publisher에 `CREATE_REPLICATION_SLOT … LOGICAL`을 요청하는 단계에서 **에러로 실패**한다. publisher의 `walsender`가 슬롯 생성 직전 `CheckLogicalDecodingRequirements()`를 호출하는데(`src/backend/replication/walsender.c:1262`), 그 안에서 `wal_level < WAL_LEVEL_LOGICAL`이면 `ereport(ERROR, …"logical decoding requires \"wal_level\" >= \"logical\"")`로 막기 때문이다(`src/backend/replication/logical/logical.c:120-123`).

```c
// src/backend/replication/logical/logical.c:120
if (wal_level < WAL_LEVEL_LOGICAL)
    ereport(ERROR,
            (errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
             errmsg("logical decoding requires \"wal_level\" >= \"logical\"")));
```

두 가지 정리: ① **검사 대상은 publisher의 `wal_level`** 이다(`walsender`는 publisher 측 프로세스). subscriber의 `wal_level`이나 병렬 설정(`streaming=parallel`, 워커 GUC)과는 **무관** — subscriber가 `minimal`/`replica`여도 *수신·병렬 적용*은 정상이고, 막히는 건 오직 publisher가 logical이 아닐 때다. ② `WITH (connect=false)`로 만들면 그 순간 에러는 안 나지만(슬롯 생성을 미룸), 이후 슬롯 생성·enable 단계에서 결국 같은 검사에 걸려 logical 복제는 성립하지 못한다. (캐스케이딩 예외: subscriber가 *재발행*하는 노드라면 그 노드도 `wal_level=logical` 필요.)

## 추론 / 유추

- `connect=false`/`create_slot=false`/`slot_name=NONE` 조합은 "슬롯을 수동 관리"하는 운영 시나리오(원격 불통, 노드 이전)를 위한 것으로, CUBRID HA의 단방향 자동 구성과는 결이 다르다 — CUBRID 부트스트랩 설계에 직접 차용보다는 "초기 스냅샷 + 좌표 핸드오프" 패턴의 참고로만 유효하다 (← [1][3]).
- `streaming` 옵션이 subscriber에 있고 `publish`가 publisher에 있다는 분리는, 의존성/적용 정책 결정 주체가 양쪽에 흩어져 있음을 보여준다 — CUBRID처럼 "apply 측 코디네이터가 판단"하는 모델과 대비된다 (← [1][2]).

## 미해결 / 자료 부족

- **행 필터(WHERE)와 초기 COPY의 상호작용** — `publish` 연산이 초기 COPY에서 무시된다는 점은 공식 문서로 확인했으나, 행 필터가 초기 스냅샷에 적용되는지/무시되는지는 버전·다중 publication 조합에 따라 미묘하여 원문 추가 확인이 필요하다(본 문서는 단정하지 않음).
- `streaming=parallel`이 기본값이 된 정확한 버전 경계는 `parallelism_in_ha.md` §9의 버전 히스토리와 교차 확인 권장(현재 문서 기준 기본 `parallel`).

## References

[1] PostgreSQL Docs — CREATE SUBSCRIPTION. https://www.postgresql.org/docs/current/sql-createsubscription.html
[2] PostgreSQL Docs — CREATE PUBLICATION. https://www.postgresql.org/docs/current/sql-createpublication.html
[3] PostgreSQL Docs — Logical Replication: Subscription / Architecture. https://www.postgresql.org/docs/current/logical-replication-subscription.html , https://www.postgresql.org/docs/current/logical-replication-architecture.html
[4] PostgreSQL Docs — Logical Replication Configuration Settings(§29.12) / Replication·Resource 런타임 설정(기본값). https://www.postgresql.org/docs/current/logical-replication-config.html , https://www.postgresql.org/docs/current/runtime-config-replication.html , https://www.postgresql.org/docs/current/runtime-config-resource.html
[5] PostgreSQL 소스(로컬, `/home/youngjun/Workspace/postgres`) — `wal_level < logical` 시 logical 슬롯 생성 거부: `src/backend/replication/logical/logical.c:120-123`(`CheckLogicalDecodingRequirements`), 호출부 `src/backend/replication/walsender.c:1262`(`CREATE_REPLICATION_SLOT … LOGICAL`).
