# RK 선택·변경과 복제 적용 검증

검토일: 2026-11-10. 기준 코드는 RK 기능 브랜치 `f0bc3158d`와 [PR #8366](https://github.com/CUBRID/cubrid/pull/8366) 검토 시 HEAD `9054d2416`이다. 홈 디렉터리의 '사용자 스펙 최종.pdf'에 명시된 RK 선택 및 HA ALTER 규칙을 기준으로 **정상 변경 10개 사례**를 TLA+로 검사했다. 기존에 논의한 슬레이브 DDL 실패는 별도 비교 사례로만 둔다. 실제 2노드 HA 통합 시험 결과는 아니다.

## 결과 한눈에 보기

| 상황 | 마스터 RK와 결과 | 기존 적용 경로 | PR #8366 적용 경로 | 판단 |
|---|---|---|---|---|
| 양쪽 DDL이 성공하고 같은 순서로 적용됨 | PK가 있으면 PK, 없으면 첫 NOT NULL UNIQUE를 선택 | 10개 모델에서 올바른 행 적용·최종 수렴 | 같은 결과. RK 비교가 정상 로그를 거부하지 않음 | **정상 변경 모델 20회 모두 통과** |
| 마지막 RK를 없애는 DDL 시도 | 마스터가 DDL을 거부하고 RK 유지 | 모델에서 뒤따르는 DML 정상 적용 | 같은 결과 | **거부 정책 모델 통과** |
| 마스터 DDL 성공, 슬레이브 DDL 실패 | 양쪽 첫 RK 후보가 달라질 수 있음 | 모델에서 다른 행 UPDATE/DELETE 반례 | RK 해시 불일치 시 행 검색 전에 오류로 중단, 적용 실패를 로깅하고 fail counter 증가 | **기존 경로 문제, PR의 차단 대상** |
| 양쪽 RK는 같지만 데이터가 이미 다름 | 같은 RK 설명자 사용 | 이 검증의 RK 불일치 범위 밖 | RK 해시가 같으므로 이 검사만으로 데이터 차이 검출 불가 | **PR의 검출 대상 아님** |

여기서 “문제 발견 안 됨”은 아래 **작은 모델의 조건부 결과**다. CUBRID 전체 DDL·인덱스 구성과 실제 HA 실행의 무결성을 증명한 뜻은 아니다. “PR의 차단”은 소스 경로와 TLA+ 추상 모델에서 확인했으며, PR 바이너리로 2노드에서 실측하지 않았다.

## 마스터가 RK를 선택하는 방식

마스터는 RK를 클래스 메타데이터에 고정 저장하지 않는다. INSERT/DELETE는 `locator_add_or_remove_index_internal()`의 인덱스 루프에서, UPDATE는 `locator_update_force()`에서 **클래스 representation 인덱스 배열을 순서대로 보며 첫 RK 후보**를 로그 키로 쓴다. 슬레이브도 `btree_get_rkey_btid()`에서 로컬 배열의 첫 후보를 고른다. 후보 판정은 `or_is_replication_candidate_key()`다.

**앞 보고서의 “PK 우선 보장 없음”은 정정한다.** 스펙은 PK가 있으면 PK를 RK로 선택한다고 명시한다. 코드도 `or_install_btids()`가 제약 프로퍼티를 `FOREIGN_KEY → PRIMARY_KEY → UNIQUE` 순서로 `OR_CLASSREP.indexes`에 설치한다(`object_representation_sr.c:2305–2312,2361–2380`). FK는 RK 후보가 아니므로 정상 representation에서는 PK가 UNIQUE보다 먼저 선택된다. PK가 없고 UK가 여러 개면 UNIQUE 프로퍼티 내부 순서상 첫 후보가 선택된다. RK가 바뀌는 이유는 제약의 추가·삭제·유효성 변경으로 **첫 후보가 바뀌기 때문**이다.

## 정상 RK 변경 검사

두 노드의 초기 스키마·행이 같고, DDL이 양쪽에서 성공하며, 로그가 순서대로 적용되는 조건을 만들었다. 모델의 대표 순서는 다음과 같다.

| 순서 | 작업 | 모델에서 선택되는 RK |
|---|---|---|
| 1 | `UNIQUE(code)`, `UNIQUE(alt)`가 있는 상태에서 UPDATE | `UNIQUE(code)` |
| 2 | `ADD PRIMARY KEY(id)` 후 UPDATE | `PRIMARY KEY(id)` |
| 3 | `DROP PRIMARY KEY` 후 UPDATE | `UNIQUE(code)` |
| 4 | `DROP UNIQUE(code)` 후 DELETE | `UNIQUE(alt)` |

[RKNormalChange.tla](RKNormalChange.tla)의 초기 연속 변경 모델도 TLC 2.19로 검사했다. [기존 경로](NormalLegacy.cfg)와 [PR 검사 경로](NormalGuarded.cfg) 모두 **36개 서로 다른 상태**에서 `NoWrongRow`, `NoRKMismatch`, `NoApplyFailure`, `ConvergesWhenCaughtUp` 위반이 없었다. 출력: [기존](NormalLegacy.out), [PR](NormalGuarded.out).

이를 [스펙별 모델](RKSpecCases.tla) 10개로 확대했다. 각 행은 기존 키값 적용(`Legacy`)과 PR #8366의 RK 비교(`Guarded`)를 각각 검사한 결과다. DML은 제약 변경 전후에 UPDATE와 DELETE를 수행하며, 키 컬럼 값도 변경한다. 마스터가 앞서 로그를 쌓는 동안 슬레이브는 로그 순서대로 적용하는 모든 인터리빙을 탐색한다.

| 모델 사례 | 스펙상 변화·제약 | 마스터 RK 변화 | 기존 / PR 결과 |
|---|---|---|---|
| `UKtoPK` | UK 사용 중 PK 추가(예시 14) | UK(a) → PK(b) | 둘 다 통과 |
| `PKtoUK` | 대체 UK가 있는 PK 삭제 | PK(a) → UK(b) | 둘 다 통과 |
| `PKtoPK` | 다중 ALTER로 PK 원자적 교체(예시 13) | PK(a) → PK(b) | 둘 다 통과 |
| `UKtoUK` | 두 UK 중 선택된 UK 삭제 | UK(a) → UK(b) | 둘 다 통과 |
| `UKBFirst` | 복수 UK의 반대 정의 순서 | UK(b) → UK(a) | 둘 다 통과 |
| `NonSelectedUK` | PK 유지 중 다른 UK 추가·삭제 | PK(a) 유지 | 둘 다 통과 |
| `LastUKReject` | 유일한 UK 삭제 시도(예시 15·16) | DDL 거부, UK(a) 유지 | 둘 다 통과 |
| `LastPKReject` | 유일한 PK 삭제 시도(예시 12) | DDL 거부, PK(a) 유지 | 둘 다 통과 |
| `NullableFallback` | 선택된 UK의 NOT NULL 해제, 대체 UK 존재 | UK(a) → UK(b) | 둘 다 통과 |
| `NullableReject` | 유일한 UK의 NOT NULL 해제 시도 | DDL 거부, UK(a) 유지 | 둘 다 통과 |

총 **20회 TLC 검사 모두 불변식 위반 없이 완료**됐다. `Last*Reject`와 `NullableReject`는 최종 RK가 없으면 DDL을 거부한다는 **스펙 정책을 모델링**한 것이며, 해당 DDL 경로가 실제 바이너리에서 모두 거부되는지 검증한 결과는 아니다. 각 사례의 설정·출력은 [spec_cases](spec_cases)에 보관했다. 예: `java -Xmx512m -jar tools/tla2tools.jar -deadlock -metadir /tmp/rk-spec-UKtoPK-Legacy -config spec_cases/UKtoPK_Legacy.cfg RKSpecCases.tla`.

## 슬레이브 DDL 실패와 PR #8366의 차단 위치

이 사례는 **의도적으로 스키마를 다르게 만드는 기존 논의**다. 마스터만 `ADD PRIMARY KEY(id)`에 성공하면 같은 숫자 키를 슬레이브가 `UNIQUE(code)`로 해석해 다른 행을 찾을 수 있다. 기존 모델은 UPDATE·DELETE 반례를 냈다. [상세 기록](RESULTS.md)에 11개 구성을 남겼다.

PR #8366은 마스터가 **실제로 로그 키를 만든 인덱스**의 설명자를 해시해 행 로그에 싣는다(`replication.c:304–353,450–525`). applylogdb가 해시를 읽어 슬레이브 서버 요청에 전달한다(`log_applier.c:3151–3186,4920–4965`). 슬레이브 서버가 로컬 첫 RK의 해시와 비교하고, 다르면 `ER_HA_GENERIC_ERROR`를 설정해 **행 검색 `locator_repl_prepare_force()` 전에 중단**한다(`locator_sr.c:6928–6998,7090–7120`). 적용 실패는 applylogdb의 오류 경로에서 기록되고 `fail_counter`가 증가한다(`log_applier.c:4771–4885`). **DDL 실패 자체를 고치거나 누락된 행을 자동 재적용하지는 않는다.**

## 해석의 한계

- 정상 모델은 2행과 선택한 제약 변경 10개를 유한 상태로 추상화했다. 실제 인덱스 배열의 모든 재배치, 동시 DDL, 실패·재시도, 파티션 및 다중 테이블 동작을 포괄하지 않는다.
- PR은 RK 설명자 전체 대신 64비트 해시를 기록하므로 이론적 충돌 가능성이 있다. 양쪽 RK가 같아도 행 데이터가 이미 다르면 RK 검사는 이를 검출하지 못한다.
- 이 검사는 **행 기반 복제 로그** 경로에 적용된다. `USE_SBR`의 SQL 재실행은 같은 RK 해시 검사를 거치지 않는다.
- PR #8366 바이너리의 정상 RK 연속 변경 및 불일치 경로는 실제 2노드 HA에서 별도 확인이 필요하다.
