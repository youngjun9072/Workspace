# RK 변경과 슬레이브 DDL 실패: 코드 및 TLA+ 검토

> 이 문서는 양쪽 스키마가 달라지는 예외 경로의 상세 기록이다. 정상적인 RK 연속 변경 검사는 [검증 보고서](REPORT.md)에 먼저 정리했다.

## 논의 기록 (2026-11-09)

- 사용자는 이 DDL 실패 및 이후 RK 불일치 시나리오가 **이미 논의된 내용**임을 확인했다.
- 격리 CSQL에서는 인덱스 이름 충돌에 따른 ALTER 실패를 확인했고, PR #8366의 행 적용 차단은 코드 및 TLA+ 모델로 검토했다. PR 빌드의 2노드 재현은 수행하지 않았다.
- 이 항목의 추가 조사·수정은 현재 보류하고 다음 주제로 넘어간다. 신규 이슈 확정이나 PR 완료 판정으로 기록하지 않는다.
- 사용자 정정에 따라 TLA+ 범위로 다시 제한했다. `LegacyConflictUpdate/Delete/Silent`는 모두 반례를 재확인했고, `GuardedConflictUpdate/Delete`는 불변식 위반 없이 완료했다. PR 빌드는 중단했고 새 HA는 시작하지 않았다. 시험 준비용 별도 DB는 양 노드에서 `cubrid deletedb`로 제거했다.

## 기준

- 기존 코드: `/home/youngjun/cubrid`의 `feature/CBRD-26246-develop` (`f0bc3158d111c7c386e4d3dbb91ea62cb160f9d4`).
- 수정 코드: [PR #8366](https://github.com/CUBRID/cubrid/pull/8366)의 검토 시 HEAD `9054d2416`. PR은 아직 열린 상태였다.
- `RKReplication.tla`의 `Guarded=FALSE`는 기존 코드, `Guarded=TRUE`는 PR의 적용 전 RK 비교를 추상화한다.

## 데이터는 같고 슬레이브 DDL만 실패하는 SQL 조건

두 노드는 같은 ON 테이블과 같은 두 행을 가진다. 유일한 RK는 `UNIQUE(code)`이다.

```sql
CREATE TABLE rk_probe (
    id INT NOT NULL,
    code INT NOT NULL,
    payload INT,
    CONSTRAINT uk_rk_probe_code UNIQUE (code)
) REPLICATION = ON;
INSERT INTO rk_probe VALUES (1, 2, 0), (2, 1, 0);
COMMIT;
```

실험 조건으로 **HA 시작 전 슬레이브에만** 다음 일반 인덱스를 둔다. 행 데이터는 그대로다. 이는 운영상 스키마가 이미 다른 비정상 상태를 의도적으로 만드는 방법이며 정상 HA 초기화 절차가 아니다. DDL 실패를 일으키는 다른 원인(인덱스 빌드 자원 오류 등)을 주입해도 이후 RK 불일치 분석은 같다.

```sql
CREATE INDEX pk_rk_probe_id ON rk_probe (payload);
```

HA 기동 후 마스터에서 다음을 실행한다고 가정한다.

```sql
ALTER TABLE rk_probe
    ADD CONSTRAINT pk_rk_probe_id PRIMARY KEY (id);
DELETE FROM rk_probe WHERE id = 1;
COMMIT;
```

마스터는 PK 추가에 성공한다. 슬레이브는 기존 일반 인덱스와 제약 이름이 충돌해 같은 ALTER에 실패한다. `src/parser/csql_grammar.y:5913-5925,9973-9995`가 문법을 받으며, `src/object/schema_template.c:2193-2197` → `classobj_check_index_exist()`(`src/object/class_object.c:8244-8250`)가 `ER_SM_INDEX_EXISTS`를 반환한다. `src/query/execute_statement.c:3998` → `do_replicate_statement()` → `src/transaction/replication.c:622`가 성공한 마스터 DDL을 SBR로 남긴다. 슬레이브의 `src/transaction/log_applier.c:5711` → `la_update_query_execute()` → `db_execute()`가 오류를 받는다.

`la_apply_statement_log():5779`는 DDL 실패를 로깅하고 fail_counter를 늘린다. `ER_SM_INDEX_EXISTS`는 `src/transaction/log_applier.h:34-47`의 기본 재시도 목록에 없다. 기본 사용자 재시도 목록도 비어 있으므로, 서버 다운 등 예외가 없다면 `la_apply_repl_log():5850-5960`은 실패한 DDL 항목을 넘기고 다음 행 로그를 처리한다.

이후 마스터는 PK(id)를, 슬레이브는 UNIQUE(code)를 RK로 고른다. 마스터의 DELETE 로그 키값 1은 슬레이브에서 `code=1`인 **다른 행** `(id=2,code=1)`을 가리킨다. `src/base/object_representation_sr.c:2305-2309,2356-2385`에서 PK가 UNIQUE보다 먼저 설치된다.

### CSQL로 확인한 범위

`f0bc315` 빌드의 격리된 단일 DB에서 `rk_master`, `rk_slave` 두 테이블을 위 두 노드의 대용으로 사용했다. 두 테이블에 같은 행을 넣고 `rk_slave`에만 `CREATE INDEX pk_rk_probe_id ON rk_slave(payload)`를 실행했다. 동일한 `ADD CONSTRAINT pk_rk_probe_id PRIMARY KEY(id)`는 `rk_master`에서 성공했고 `rk_slave`에서 다음과 같이 실패했다.

```text
ERROR: Index "pk_rk_probe_id" already defined for class "dba.rk_slave".
```

`SELECT id,code FROM rk_master WHERE id=1`은 `(1,2)`, `SELECT id,code FROM rk_slave WHERE code=1`은 `(2,1)`을 반환했다. **이 실험은 문법·이름 충돌·키값의 다른 해석만 실측했다.** 실제 HA 복제 로그와 PR #8366의 슬레이브 적용은 아직 2노드에서 실측하지 않았다.

### 다른 DDL 실패 원인

복제 OFF 소스의 데이터 차이와 `USE_SBR`로 먼저 슬레이브 ON 테이블에 중복 id가 생긴 경우에도, 마스터의 `ADD PRIMARY KEY(id)`만 성공하고 슬레이브의 PK 인덱스 빌드는 `src/storage/btree_load.c:4400-4422`의 `ER_BTREE_UNIQUE_FAILED`로 실패할 수 있다. 단, 이 경로는 PK 추가 **전부터 ON 데이터가 달라져 있으므로** RK 불일치의 독립적인 최초 원인으로 세지 않는다. `src/query/execute_statement.c:3539-3545,4340-4358,4674-4692`상 ON INSERT 대상에 `USE_SBR` 힌트가 있으면 영향 행 수가 0이어도 SQL 원문 로깅 경로에 들어간다.

## 기존 코드와 PR #8366의 차이

### 기존 코드

- `src/transaction/locator_sr.c:8010-8026,8400-8406,8801-8815`: 마스터가 첫 RK 후보로 DML 로그 키값을 만든다.
- `src/transaction/replication.c:354-407`: 행 로그에는 클래스명과 키값만 있으며 마스터 RK 식별정보는 없다.
- `src/transaction/log_applier.c:3151-3162,4938`: applylogdb가 키값을 슬레이브 서버로 보낸다.
- `src/storage/btree.c:8747-8781` → `src/transaction/locator_sr.c:6816-6828`: 슬레이브 서버가 로컬 첫 RK에서 키값으로 행을 찾는다. 양쪽 RK가 달라도 비교할 정보가 없어 잘못된 행에 DELETE/UPDATE를 적용할 수 있다.

### PR #8366

- `src/transaction/replication.c:304-353,450-525`: 마스터가 **실제로 사용한** 인덱스의 이름·종류·순서가 있는 컬럼 ID/이름·도메인·정렬 방향·NULL 속성을 설명자로 만들고 64비트 FNV-1a 해시를 키값과 함께 행 로그에 넣는다. 전체 설명자는 로그에 넣지 않는다.
- `src/base/replication_key.c:299-380` 및 `src/transaction/log_applier.c:3151-3186`: applylogdb가 키값과 해시를 분리한다. 해시 없는 구형 로그는 오류로 거부한다.
- `src/transaction/log_applier.c:4920-4965` → `src/object/work_space.c:5357` → `src/transaction/locator_cl.c:6989-7040`: 해시를 복제 객체 요청에 싣는다.
- `src/transaction/locator_sr.c:6928-6998,7090-7120`: 슬레이브가 로컬 첫 RK를 같은 방식으로 설명하고 해시를 비교한다. **행 검색 `locator_repl_prepare_force()`보다 먼저** 불일치를 오류로 만든다. INSERT도 같은 검사를 거친다.
- `src/transaction/locator_sr.c:7190-7210`은 실패한 행의 top operation을 취소하고 오류를 응답한다. `src/transaction/log_applier.c:4771-4885`가 오류를 로깅하고 fail_counter를 늘린다. 앞선 DDL 실패 count와 이후 DML 실패 count는 별개다.

따라서 위 이름 충돌 예시에서 PR 코드는 다음 DELETE/UPDATE가 **다른 행을 찾기 전에 실패**하도록 만든다. 실패한 DDL이나 이미 생긴 스키마 차이를 자동 복구하지는 않는다.

실패한 DDL 및 행 로그는 기본 재시도 대상이 아니다. `src/transaction/log_applier.c:5979-6013`은 실패 후에도 해당 커밋 항목을 목록에서 제거하고, `:6312-6319`는 치명 오류가 아니면 `committed_lsa`를 진행시킨다. **나중에 인덱스 이름 충돌만 해소해도 건너뛴 DML이 자동 재적용되는 경로는 확인되지 않았다.** 운영 복구에는 누락된 행과 스키마를 별도로 맞추는 절차가 필요하다.

## TLC 결과

TLC 2.19로 `java -Xmx512m -jar tools/tla2tools.jar -deadlock -metadir /tmp/<구성별 경로> -config <이름>.cfg RKReplication.tla`를 실행했다. 출력은 같은 이름의 `.out` 파일에 있다. `SlaveIndexNameConflict=TRUE`는 데이터가 같은 상태의 인덱스 이름 충돌, `SlaveOffHasRow=TRUE`는 앞선 OFF 소스 SBR의 행 차이를 나타낸다.

| 구성 | 결과 |
|---|---|
| `LegacyUpdate.cfg`, `LegacyDelete.cfg` | `NoWrongRow` 위반: DDL 실패 뒤 다른 행 변경 가능 |
| `LegacySilent.cfg` | DDL 실패는 기록되지만 다음 DML 자체는 오류 없이 다른 행에 적용 가능 |
| `GuardedUpdate.cfg`, `GuardedDelete.cfg` | 각각 7개 도달 상태에서 불변식 위반 없음: RK 불일치 시 DML 실패, 행 미적용 |
| `LegacyConflictUpdate.cfg`, `LegacyConflictDelete.cfg` | **초기 행 데이터가 같아도** DDL 이름 충돌 뒤 `NoWrongRow` 위반 |
| `LegacyConflictSilent.cfg` | 같은 조건에서 DDL 실패 count만 증가하고 다음 DML 실패 count 없이 다른 행을 변경하는 반례 |
| `GuardedConflictUpdate.cfg`, `GuardedConflictDelete.cfg` | 각각 7개 도달 상태에서 불변식 위반 없음: 잘못된 행 적용 차단 |
| `LegacySameSchema.cfg` | RK가 같은 경로의 조건부 수렴 불변식 통과 |

## 한계

- TLC의 `LogRK`는 RK 식별정보의 일치 여부를 추상화한다. 실제 PR은 **64비트 해시 비교**이므로 수학적으로 충돌 가능성을 0으로 만들지 못한다.
- 같은 RK 설명자를 가진 경우의 일반 데이터·스키마 불일치는 이 검사로 잡히지 않는다. 새 이름 충돌 예시는 행 데이터가 같지만 스키마에 일반 인덱스 하나가 이미 더 있는 통제된 조건이다. OFF 소스 SBR 예시는 그 전에 행 데이터까지 달라진 조건이다.
- PR 소스로 검사 위치와 실패 전파 경로를 확인했다. 이 PR HEAD를 빌드하여 2노드에서 재현한 통합 테스트는 수행하지 않았다.
- 이 PR의 검사는 INSERT/UPDATE/DELETE **행 기반 로그**에 적용된다. `USE_SBR` DML은 SQL 원문을 재실행하므로 같은 RK 해시 비교 경로를 지나지 않는다. 이 경우의 정합성은 SQL의 입력 데이터 및 로컬 스키마에 좌우된다.
