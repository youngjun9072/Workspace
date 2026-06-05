# CUBRID applylogdb — 특수 테이블 유형별 병렬 적용 시나리오 분석

> 코드 분석 · 2026-06-05 · branch `feature/parallel_applylogdb_poc` (일부는 develop 공통)
> 목적: 병렬 applylogdb 코디네이터 설계 시, **일반 테이블 외 특수 유형(파티션·뷰·상속·LOB 등)** 에서 충돌/순서가 문제될 수 있는지 점검.
> 연계: `parallel_applylogdb_coordinator_design.md`의 "기타 시나리오 / 확인 항목"을 테이블 유형 축으로 확장.

## 0. 공통 전제 — 복제는 PK 기반, 식별은 class OID

- 복제 로그 항목은 **class_name + PK 값 + operation** 으로 구성된다(`replication.c:repl_log_insert:293`, PK 값으로 행 식별 `:215,288`). applier는 이 PK로 대상 행을 찾고(`la_get_item_pk_value`), class는 `db_find_class→ws_oid`로 **class OID** 를 얻는다.
- 따라서 **복제 대상 테이블은 PRIMARY KEY가 있어야 한다**(PK 없는 테이블은 복제 식별 불가 → 복제 비대상). → 코디네이터의 충돌 키(PK)·class 키는 복제 대상에 대해 항상 존재한다.

## 1. 요약 표

| 테이블 유형 | applier 처리 | 병렬 시 문제 소지 | 판정 |
|---|---|---|---|
| 파티션 테이블 | pruning 처리함(`sm_partitioned_class_type`) | **partition별 class로 기록되면** 서로 다른 class로 보여 cross-partition 병렬 → **글로벌 인덱스(unique/FK)** 위반 가능 | ⚠ **확인 필요(최우선)** |
| 뷰(vclass) | apply 경로에 처리 없음 | 뷰 자체는 복제 안 됨(기반 테이블이 로깅됨) | ✅ 문제 없음 |
| 상속(super/sub class) | 인스턴스는 자기 class heap | 파티션과 유사 — 서로 다른 class OID | ⚠ 확인 필요 |
| LOB 컬럼 | log_applier에 명시적 처리 미발견 | 외부 저장(ELO/ES) 복제 경로가 별도일 수 있음 | ⚠ 확인 필요 |
| non-MVCC / reusable-OID class | 분기 처리(`is_mvcc_class`, mvcc insid/delid 보정) | 주로 카탈로그/시스템 class | ✅ 처리됨(사용자 테이블 영향 적음) |
| serial(`db_serial`) | 값은 레코드 이미지로 적용 | 카탈로그 갱신 순서 | ⚠ 경미(같은 class면 same-class가 커버) |
| PK 없는 테이블 | — | 복제 비대상 | ✅ 해당 없음 |

## 2. 파티션 테이블 (최우선 확인) ⚠

**확인된 것**: applier는 파티션을 인지한다 — `la_repl_add_object`에서 `sm_partitioned_class_type(classop, &pruning_type, ...)`(`log_applier.c:7635`)로 pruning type을 구해 `LC_INSERT/UPDATE_OPERATION_TYPE(pruning_type)`로 server에 넘긴다. server가 알맞은 파티션 heap에 적용한다.

**열린 문제 — 충돌 판단 단위**: 마스터의 `repl_log_insert`는 **행이 실제 저장된 heap의 class_oid** 로 복제 로그를 남길 가능성이 높다(파티션 행은 파티션 heap에 저장). 그렇다면 applier가 보는 class_oid는 **root가 아니라 partition**이 된다.

```
partitioned table ORDERS  (PARTITION BY ... )
  ├ ORDERS__p0  (class_oid A)
  └ ORDERS__p1  (class_oid B)

T1: INSERT → p0 (class A)
T2: INSERT → p1 (class B)
코디네이터(class OID 기준): A ≠ B → "독립" → 병렬
```

- 파티션 인덱스가 **로컬(파티션별)** 이면: cross-partition 병렬이 안전(각 파티션 인덱스 독립).
- 파티션에 **글로벌 unique 인덱스 / 글로벌 FK** 가 있으면: 서로 다른 파티션 적용이 같은 글로벌 인덱스를 동시에 건드려 **비순차 시 unique/FK 위반(에러)** 가능 → 복제 중단.

**확인 항목**:
1. `repl_log_insert` 호출부의 `class_oid` 가 **partition인지 root인지**.
2. CUBRID 파티션 테이블의 PK/unique 인덱스가 **로컬인지 글로벌인지**(글로벌이면 cross-partition 충돌).
3. 코디네이터가 충돌 키를 **partition OID로 잡으면** 위 위험, **root OID로 잡으면** 한 테이블 전체가 same-class로 직렬화(안전하나 병렬↓).

→ 1차안에서는 보수적으로 **root class 기준(또는 partition을 같은 그룹으로)** 직렬화하는 것이 안전. 정밀 병렬은 인덱스 로컬/글로벌 여부 확인 후.

## 3. 뷰(vclass) ✅

- `log_applier.c`에 vclass/virtual class/view 처리가 없다. 뷰는 데이터를 저장하지 않으므로 **뷰에 대한 복제 로그가 생기지 않는다** — 뷰를 통한 DML은 기반 테이블 변경으로 로깅된다.
- → 코디네이터는 뷰를 볼 일이 없다. 문제 없음. (단 뷰 정의 변경 같은 DDL은 schema → barrier 대상.)

## 4. 상속 (super/sub class) ⚠

- CUBRID 클래스 상속에서 인스턴스는 자신의 class heap에 저장된다 → 파티션과 유사하게 super/sub가 **서로 다른 class OID**.
- super/sub 간 인덱스·제약 공유 여부에 따라 cross-class 충돌 가능성. → 파티션과 같은 축의 확인 필요(인덱스 단위).

## 5. LOB 컬럼 ⚠

- `log_applier.c`에서 LOB/ELO/ES 전용 처리를 찾지 못했다. CUBRID LOB은 **외부 저장(ELO locator, `src/storage/es.c`)** 이라, LOB 데이터의 복제가 일반 레코드 이미지 적용과 다른 경로일 수 있다.
- **확인 항목**: LOB 값이 복제 로그/레코드 이미지에 포함되는지, 별도 복제 메커니즘인지. 병렬 적용 시 LOB locator 정합성.

## 6. non-MVCC / reusable-OID class ✅(처리됨)

- applier는 `la_is_mvcc_class(ws_oid(class_obj))`(`:8178`)로 MVCC/비MVCC를 구분하고, MVCC 클래스는 `la_make_room_for_mvcc_insid` / `la_make_room_for_mvcc_delid_and_prev_ver`(`:6326~`)로 레코드 이미지에 MVCC ins/del id 공간을 보정한다.
- 비MVCC/reusable-OID class는 주로 카탈로그·시스템 class라 사용자 테이블 병렬성에는 영향이 적다. 처리 자체는 존재.

## 7. serial / db_serial ⚠(경미)

- serial 값은 재생성이 아니라 **레코드 이미지로 적용**된다(마스터에서 확정된 값). `db_serial`은 시스템 class이므로 같은 class 변경은 same-class 직렬화로 순서 유지.
- 경미하나, serial 카탈로그 갱신이 사용자 트랜잭션과 어떻게 엮이는지는 확인 가치.

## 추론 / 유추

- 특수 테이블에서 "에러로 깨질" 위험이 가장 큰 것은 **파티션 + 글로벌 인덱스** 조합이다(← §2). FK와 같은 "server 에러" 가족이며, 코디네이터가 class OID를 partition 단위로 잡으면 노출된다.
- 뷰·non-MVCC는 사실상 문제 없음(뷰는 비복제, non-MVCC는 처리됨).
- LOB·상속은 추가 코드 확인 전까지 보수적으로(직렬/barrier) 두는 것이 안전.

## 미해결 / 확인 필요 (우선순위)

1. **(최우선)** `repl_log_insert`의 class_oid = partition vs root + 파티션 인덱스 local/global.
2. LOB 복제 경로(레코드 이미지 포함 여부, locator 정합성).
3. 상속 class의 인덱스/제약 공유와 cross-class 충돌.
4. serial 카탈로그 갱신과 사용자 트랜잭션의 엮임.

## References (소스)

- `src/transaction/log_applier.c` — `la_repl_add_object`(:7589, 파티션 pruning :7635), `la_is_mvcc_class`(:8178), mvcc 보정(:6326~), PK 사용(`la_get_item_pk_value`:5670)
- `src/transaction/replication.c` — `repl_log_insert`(:293, PK 기반 :215/288)
- `src/transaction/locator_sr.c` — `locator_insert_force`/`locator_check_foreign_key`(글로벌 인덱스·FK 검사)
