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
| 파티션 테이블 | pruning 처리함(`sm_partitioned_class_type`) | 파티션 키 ∈ 모든 인덱스 키 규칙 → cross-partition unique/PK 충돌 **불가**(§2). FK+파티션은 CUBRID가 제약 | ✅ **구조적으로 안전** |
| 뷰(vclass) | apply 경로에 처리 없음 | 뷰 자체는 복제 안 됨(기반 테이블이 로깅됨) | ✅ 문제 없음 |
| 상속(super/sub class) | 자기 (sub)class OID로 기록 | **계층이 unique 인덱스(BTID) 공유** → cross-subclass unique 충돌 가능(FK 가족). 실무 빈도 낮음 | ⚠ FK와 동일 처리 |
| LOB 컬럼 | 행엔 ELO locator만, 데이터는 외부 저장 | LOB **데이터는 로그로 비복제**(외부 저장·별도 운영 사안), 코디네이터 무관 | ✅ 코디네이터 무관 |
| non-MVCC / reusable-OID class | 분기 처리(`is_mvcc_class`, mvcc insid/delid 보정) | 주로 카탈로그/시스템 class | ✅ 처리됨(사용자 테이블 영향 적음) |
| serial(`db_serial`) | 값은 레코드 이미지로 적용 | 카탈로그 갱신 순서 | ⚠ 경미(같은 class면 same-class가 커버) |
| PK 없는 테이블 | — | 복제 비대상 | ✅ 해당 없음 |

## 2. 파티션 테이블 — 구조적으로 안전 (확인됨) ✅

**확인된 것**:
- applier는 파티션을 인지한다 — `la_repl_add_object`에서 `sm_partitioned_class_type(classop, &pruning_type, ...)`(`log_applier.c:7635`)로 pruning type을 구해 `LC_INSERT/UPDATE_OPERATION_TYPE(pruning_type)`로 server에 넘기고, server가 알맞은 파티션 heap에 적용한다.
- 복제 로그는 **PK 인덱스에서만** 생성된다 — `repl_log_insert`는 `index->type == BTREE_PRIMARY_KEY`일 때만 호출되며 `class_oid + PK 값`을 남긴다(`locator_sr.c:8082-8088`).

**핵심 — cross-partition unique/PK 충돌은 구조적으로 불가능**:
- CUBRID는 **"파티션 키가 모든 인덱스 키에 포함되어야 한다"** 를 강제한다 (msg 1169 *"Partition key attributes must be present in the index key"*, 비교 불가능한 변경은 msg 1117/181).
- → 어떤 unique/PK 값이든 **파티션 키가 그 값의 일부**이고, 파티션 키가 파티션을 결정하므로, **같은 unique/PK 값은 정확히 한 파티션에만 존재**한다.
- → 서로 다른 파티션을 병렬 적용해도 **같은 키를 동시에 건드릴 수 없다** → cross-partition unique/PK 위반이 발생할 수 없다.

```
partitioned table ORDERS (PARTITION BY ... )
  ├ ORDERS__p0,  ├ ORDERS__p1, ...
PK/unique 키에는 항상 파티션 키가 포함됨
  → 키 값 K 는 파티션 키에 의해 단 하나의 파티션으로 매핑
  → 다른 파티션의 병렬 적용은 K를 공유하지 않음 → 충돌 없음
```

**FK + 파티션은 CUBRID에서 제한적**: "Cannot add the foreign key constraint to the partitioned class ..."(msg 997), "Altering partitioning schema is not allowed when ... referenced by a foreign key"(msg 1096). → FK+파티션 조합 자체가 제약되어, FK 경로의 cross-partition 위험도 제한적.

**결론**: 파티션은 **correctness 측면에서 안전**하다(스키마 규칙이 cross-partition unique 충돌을 막음). 남는 것은 **병렬성 튜닝** 선택뿐:
- 복제 로그가 partition class로 기록되면(가능성 높음) 코디네이터가 파티션별로 **병렬** 가능(안전).
- root class 기준으로 잡으면 테이블 통째 same-class **직렬**(더 보수적, 병렬↓).
- 어느 쪽이든 **correctness는 동일하게 보장**되므로, 1차안은 단순한 쪽을 택하고 후속 최적화로 둔다.

> (참고) 파티션 키 값을 바꾸는 UPDATE(행이 파티션 이동)는 server가 delete+insert로 처리하지만, 단일 트랜잭션이므로 1tx=1worker로 원자 적용 → 별도 cross-worker 문제 없음.

## 3. 뷰(vclass) ✅

- `log_applier.c`에 vclass/virtual class/view 처리가 없다. 뷰는 데이터를 저장하지 않으므로 **뷰에 대한 복제 로그가 생기지 않는다** — 뷰를 통한 DML은 기반 테이블 변경으로 로깅된다.
- → 코디네이터는 뷰를 볼 일이 없다. 문제 없음. (단 뷰 정의 변경 같은 DDL은 schema → barrier 대상.)

## 4. 상속 (super/sub class) — cross-class 위험 있음 (FK와 같은 가족) ⚠

- 복제/적용 경로엔 상속 전용 처리가 없다(`log_applier.c`/`replication.c`) → applier는 subclass instance를 **자기 (sub)class OID**로 일반 class처럼 기록·식별.
- **그러나 UNIQUE/PK 제약은 계층 전체가 공유한다.** subclass가 superclass의 unique를 inherit할 때 **superclass의 BTID(같은 B-tree 인덱스)를 그대로 쓴다** — *"go back to the super class to get its real BTID"*(`schema_manager.c:9488-9506`, `inherit_constraint:371`, `sm_class_has_unique_constraint`가 subclass 재귀 `:6067-6096`). → **하나의 unique 인덱스가 superclass + 모든 subclass에 걸쳐 enforce**된다.
- **위험**: 같은 unique/PK 값을 서로 다른 subclass(다른 class OID)에 비순차 병렬 적용하면 **공유 unique 인덱스 위반 → server 에러 → 복제 중단.** 파티션과 달리 키를 나누는 규칙이 없어 **cross-subclass 충돌이 실제로 가능**하다.
- **applier-blind**: 계층/공유 BTID 관계는 복제 로그(class+PK)에 없고 server 스키마에만 있다 → **applier가 못 가린다 = FK와 동일한 cross-class 가족.**
- **대응**: FK와 같다 — Phase 1의 보수적 commit 순서 보존이 이미 커버(또는 계층 관계를 알면 같은 직렬 그룹). Phase 2는 server 그룹핑.
- **실무 빈도 낮음**: 상속은 CUBRID 레거시 OO 기능이라 일반 관계형 사용에선 드물다 — 위험은 실재하나 빈도 낮음.

## 5. LOB 컬럼 — 데이터는 비복제, 코디네이터 무관 ✅

- CUBRID LOB은 행에 **ELO locator(외부 저장 참조)** 만 저장하고 실제 바이트는 외부 저장(ES, `src/storage/es.c`)에 둔다. → 복제 로그/레코드 이미지에는 **locator만** 실리고 **LOB 데이터 자체는 트랜잭션 로그로 배송되지 않는다.**
- applier는 `lob_path` credential을 가진다(`log_applier.c:1604~`) = locator를 슬레이브에서 해석할 경로. 즉 **LOB 데이터의 HA 정합은 외부 저장 공유/동기 정책의 문제**(별도 운영 사안)이지 병렬 코디네이터의 문제가 아니다.
- **코디네이터 관점**: LOB 컬럼은 레코드 이미지 안의 값(locator) 하나일 뿐 → PK·class 단위로 일반 컬럼과 동일 처리. **새로운 충돌/순서 시나리오 없음.**

## 6. non-MVCC / reusable-OID class ✅(처리됨)

- applier는 `la_is_mvcc_class(ws_oid(class_obj))`(`:8178`)로 MVCC/비MVCC를 구분하고, MVCC 클래스는 `la_make_room_for_mvcc_insid` / `la_make_room_for_mvcc_delid_and_prev_ver`(`:6326~`)로 레코드 이미지에 MVCC ins/del id 공간을 보정한다.
- 비MVCC/reusable-OID class는 주로 카탈로그·시스템 class라 사용자 테이블 병렬성에는 영향이 적다. 처리 자체는 존재.

## 7. serial / db_serial ⚠(경미)

- serial 값은 재생성이 아니라 **레코드 이미지로 적용**된다(마스터에서 확정된 값). `db_serial`은 시스템 class이므로 같은 class 변경은 same-class 직렬화로 순서 유지.
- 경미하나, serial 카탈로그 갱신이 사용자 트랜잭션과 어떻게 엮이는지는 확인 가치.

## 추론 / 유추

- 파티션은 처음 우려와 달리 **correctness 안전**으로 확인됐다(← §2). CUBRID의 "파티션 키 ∈ 모든 인덱스 키" 규칙이 cross-partition unique/PK 충돌을 구조적으로 막고, FK+파티션은 CUBRID가 제약한다. 남는 것은 병렬성 튜닝뿐.
- 뷰·non-MVCC도 사실상 문제 없음(뷰는 비복제, non-MVCC는 처리됨).
- 따라서 **applier가 자기 입력만으로 못 막는 cross-class 위험은 FK와 상속(계층 공유 unique 인덱스) 두 가지**다(파티션은 스키마 규칙이 보강, LOB은 데이터 비복제로 무관). 둘 다 Phase 1의 보수적 commit 순서 보존이 커버하며, 상속은 실무 빈도가 낮다.

## 미해결 / 확인 필요 (우선순위)

1. ~~파티션 class_oid root/partition + 인덱스 local/global~~ → **확인됨**: 파티션 키 ∈ 인덱스 키 규칙으로 cross-partition unique 충돌 불가(§2). root/partition은 병렬성 튜닝 문제일 뿐.
2. ~~LOB 복제 경로~~ → **확인됨**: LOB 데이터는 로그로 비복제(locator만), 외부 저장 동기는 별도 운영 사안 → 코디네이터 무관(§5).
3. ~~상속 인덱스/제약 공유~~ → **확인됨**: 계층이 unique BTID 공유 → cross-subclass unique 충돌 가능(FK 가족, §4). Phase 1 commit 순서가 커버, 실무 빈도 낮음.
4. serial 카탈로그 갱신과 사용자 트랜잭션의 엮임.

## References (소스)

- `src/transaction/log_applier.c` — `la_repl_add_object`(:7589, 파티션 pruning :7635), `la_is_mvcc_class`(:8178), mvcc 보정(:6326~), PK 사용(`la_get_item_pk_value`:5670)
- `src/transaction/replication.c` — `repl_log_insert`(:293, PK 기반 :215/288)
- `src/transaction/locator_sr.c` — `locator_insert_force`/`locator_check_foreign_key`(글로벌 인덱스·FK 검사)
