# RK 선택·변경과 복제 적용 검증

검토일: 2026-11-10. 기준 코드는 RK 기능 브랜치 `f0bc3158d`와 [PR #8366](https://github.com/CUBRID/cubrid/pull/8366) 검토 시 HEAD `9054d2416`이다. 홈 디렉터리의 '사용자 스펙 최종.pdf'에 명시된 RK 선택 및 HA ALTER 규칙을 기준으로 **고정 경로 12개와 4문장 순서 조합**을 TLA+로 검사했다. 기존에 논의한 슬레이브 DDL 실패는 별도 비교 사례로만 둔다. 실제 2노드 HA 통합 시험 결과는 아니다.

## 결론

**검사한 정상 경로에서는 새 RK 복제 결함을 발견하지 못했다.** 양쪽이 같은 초기 스키마·데이터에서 시작하고 DDL이 모두 성공해 로그 순서대로 적용되면, RK를 변경하거나 RK 컬럼 값을 변경해도 모델에서는 잘못된 행 적용과 최종 데이터 불일치가 없었다.

반례는 슬레이브 DDL 실패로 스키마가 달라지거나, 별도 조작·선행 장애로 데이터가 이미 달라진 조건에서만 나왔다. 전자는 기존에 논의한 문제이며 PR #8366이 RK 불일치에 따른 잘못된 행 적용을 막는 경로다. 후자는 이번 RK 변경 결함으로 집계하지 않는다.

이 결론은 아래 코드 추적과 TLA+ 유한 상태 모델의 범위에 한정된다. 실제 병렬 클라이언트·2노드 HA에서 모든 경로에 결함이 없음을 입증한 결과는 아니다.

## 결과 한눈에 보기

| 상황 | 마스터 RK와 결과 | 기존 적용 경로 | PR #8366 적용 경로 | 판단 |
|---|---|---|---|---|
| 양쪽 DDL이 성공하고 같은 순서로 적용됨 | PK가 있으면 PK, 없으면 첫 NOT NULL UNIQUE를 선택 | 고정 경로 12개와 4문장 순서 조합에서 올바른 행 적용·최종 수렴 | 같은 결과. RK 비교가 정상 로그를 거부하지 않음 | **검사한 정상 모델에서 문제 발견 안 됨** |
| 마지막 RK를 없애는 DDL 시도 | 마스터가 DDL을 거부하고 RK 유지 | 모델에서 뒤따르는 DML 정상 적용 | 같은 결과 | **거부 정책 모델 통과** |
| 마스터 DDL 성공, 슬레이브 DDL 실패 | 양쪽 첫 RK 후보가 달라질 수 있음 | 모델에서 다른 행 UPDATE/DELETE 반례 | RK 해시 불일치 시 행 검색 전에 오류로 중단, 적용 실패를 로깅하고 fail counter 증가 | **기존 경로 문제, PR의 차단 대상** |
| 양쪽 RK는 같지만 데이터가 이미 다름(별도로 만든 선행 불일치) | 같은 RK 설명자 사용 | 정상 RK 변경 사례가 아님 | RK 해시가 같으므로 이 검사만으로 기존 데이터 차이 검출 불가 | **RK 변경 결함으로 집계하지 않음** |

여기서 “문제 발견 안 됨”은 아래 **작은 모델의 조건부 결과**다. CUBRID 전체 DDL·인덱스 구성과 실제 HA 실행의 무결성을 증명한 뜻은 아니다. “PR의 차단”은 소스 경로와 TLA+ 추상 모델에서 확인했으며, PR 바이너리로 2노드에서 실측하지 않았다. 마지막 행은 강제로 데이터를 다르게 두거나 다른 선행 장애로 이미 불일치가 생긴 경우의 **검사 범위 설명**이다. 정상 RK 변경 테스트에서 관찰된 결함이 아니다.

## 검증 근거와 범위

| 확인 방법 | 실제로 확인한 내용 | 이 방법으로 확인하지 못한 내용 |
|---|---|---|
| **CUBRID 코드 추적** | `or_install_btids()`의 PK→UNIQUE 설치 순서, 마스터 INSERT/DELETE·UPDATE의 첫 RK 후보 사용, 슬레이브의 첫 RK 후보 조회, DDL·DML 클래스 잠금의 비호환성 | 모든 운영 환경에서 양 노드의 실행이 항상 성공하는지 |
| **PR #8366 코드 추적** | 마스터가 사용한 RK의 해시 기록 → applylogdb 전달 → 슬레이브 행 검색 전 비교 → 오류 반환·로깅·fail counter 경로 | PR 바이너리를 실행했을 때의 실제 오류 메시지·복제 결과 |
| **TLA+ 모델 검사** | 코드와 스펙에서 추린 규칙으로 고정 경로 12개와 4문장 순서 조합을 탐색해 잘못된 행 적용·RK 불일치·적용 실패·최종 불수렴 여부 검사 | CUBRID 함수 자체의 실행, 잠금 대기·데드락, 실제 2노드 HA 복제 |

따라서 **코드 경로 조사와 모델 검사는 함께 수행했지만, 23,238개 경로를 CUBRID에 SQL로 실행한 결과는 아니다.** 모델에서 마지막 RK 제거 DDL을 거부하는 동작은 스펙상 전제이며, 각 실제 DDL 진입점의 구현 검증과 구분한다.

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

이를 [스펙별 모델](RKSpecCases.tla) 12개로 확대했다. 각 행은 기존 키값 적용(`Legacy`)과 PR #8366의 RK 비교(`Guarded`)를 각각 검사한 결과다. DML은 제약 변경 전후에 UPDATE와 DELETE를 수행하며, **선택된 RK 컬럼 값 자체를 바꾼 뒤 다음 DML**도 검사한다. 마스터가 앞서 로그를 쌓는 동안 슬레이브는 로그 순서대로 적용하는 모든 인터리빙을 탐색한다.

| 모델 사례 | 스펙상 변화·제약 | 마스터 RK 변화 | 기존 / PR 결과 |
|---|---|---|---|
| `UKtoPK` | UK 사용 중 PK 추가, 새 PK 컬럼 값 변경(예시 14) | UK(a) → PK(b) | 둘 다 통과 |
| `PKtoUK` | 대체 UK가 있는 PK 삭제, 새 UK 컬럼 값 변경 | PK(a) → UK(b) | 둘 다 통과 |
| `PKtoPK` | 다중 ALTER로 PK 원자적 교체, 새 PK 컬럼 값 변경(예시 13) | PK(a) → PK(b) | 둘 다 통과 |
| `PKValueChange` | PK 컬럼 값만 UPDATE하고 다음 DML | PK(a) 유지 | 둘 다 통과 |
| `UKKeyChange` | 선택된 NOT NULL UK 컬럼 값만 UPDATE하고 다음 DML | UK(a) 유지 | 둘 다 통과 |
| `UKtoUK` | 두 UK 중 선택된 UK 삭제, 새 UK 컬럼 값 변경 | UK(a) → UK(b) | 둘 다 통과 |
| `UKBFirst` | 복수 UK의 반대 정의 순서 | UK(b) → UK(a) | 둘 다 통과 |
| `NonSelectedUK` | PK 유지 중 다른 UK 추가·삭제 | PK(a) 유지 | 둘 다 통과 |
| `LastUKReject` | 유일한 UK 삭제 시도(예시 15·16) | DDL 거부, UK(a) 유지 | 둘 다 통과 |
| `LastPKReject` | 유일한 PK 삭제 시도(예시 12) | DDL 거부, PK(a) 유지 | 둘 다 통과 |
| `NullableFallback` | NOT NULL UNIQUE(a) → nullable UNIQUE(a), 대체 UK(b) 존재 | UK(a) → UK(b) | 둘 다 통과 |
| `NullableReject` | 유일한 NOT NULL UNIQUE(a) → nullable UNIQUE(a) 시도 | DDL 거부, UK(a) 유지 | 둘 다 통과 |

총 **24회 TLC 검사 모두 불변식 위반 없이 완료**됐다. `Last*Reject`와 `NullableReject`는 최종 RK가 없으면 DDL을 거부한다는 **스펙 정책을 모델링**한 것이며, 해당 DDL 경로가 실제 바이너리에서 모두 거부되는지 검증한 결과는 아니다. nullable UNIQUE는 제약 자체가 남아 있지만 RK 후보에서 제외되는 것으로 추상화했다. 각 사례의 설정·출력은 [spec_cases](spec_cases)에 보관했다. 예: `java -Xmx512m -jar tools/tla2tools.jar -deadlock -metadir /tmp/rk-spec-UKtoPK-Legacy -config spec_cases/UKtoPK_Legacy.cfg RKSpecCases.tla`.

## 병렬 클라이언트의 확정 순서 검사

같은 클래스에서 DDL은 `sm_update_class() → update_class() → au_fetch_class(..., AU_FETCH_UPDATE)`를 거쳐 스키마 변경 잠금(`SCH_M_LOCK`)을 요청한다. UPDATE는 `update_real_class()`에서 `locator_fetch_class(..., DB_FETCH_READ)`로 스키마 안정 잠금(`SCH_S_LOCK`)을 얻는다. 다른 DML 경로도 클래스 쓰기 잠금(`IX_LOCK` 등)을 사용한다. `lock_table.c`의 호환성 표에서 `SCH_M_LOCK`은 `SCH_S_LOCK`·`IX_LOCK`과 호환되지 않는다. 따라서 이 모델은 병렬 요청의 **잠금 획득·커밋 후 확정 순서**를 비결정적으로 탐색하고, DDL과 DML의 내부 단계를 동시에 실행하는 상태는 가정하지 않는다.

[순서 조합 모델](RKConcurrentOrders.tla)은 초기 RK 구성 5종에서 DDL·DML 시도 4개를 동적으로 고른다. 후보에는 PK/UK 추가·삭제, PK 교체, UNIQUE의 NOT NULL 해제, 키 컬럼 UPDATE, 일반 UPDATE, DELETE가 포함된다. 마스터는 로그를 앞서 쌓을 수 있고 슬레이브는 FIFO로 적용한다. 초기 스키마와 4문장 시도 순서를 함께 세면 **23,238개**의 서로 다른 완전 적용 경로가 있다. 이 중 **20,384개**는 DDL과 DML을 함께 포함하고, **7,119개**는 마지막 RK 제거 등으로 DDL 거부가 포함된다. [집계 출력](ConcurrentCount.txt)은 TLC 상태 덤프에서 [집계 스크립트](count_concurrent_sequences.py)로 계산했다.

TLC 2.19의 [기존 적용](ConcurrentLegacy4.cfg)과 [PR 적용](ConcurrentGuarded4.cfg) 모두 각각 **119,450개 서로 다른 상태**를 끝까지 탐색했고, 잘못된 행 적용·RK 불일치·적용 실패·로그 적용 완료 시 불수렴 불변식 위반이 없었다. 출력: [기존](ConcurrentLegacy4.out), [PR](ConcurrentGuarded4.out). **23,238은 실행한 CSQL 수가 아니라 모델의 순서 경로 수**다. 두 적용 방식에 같은 경로를 각각 검사했다.

## 슬레이브 DDL 실패와 PR #8366의 차단 위치

이 사례는 **의도적으로 스키마를 다르게 만드는 기존 논의**다. 마스터만 `ADD PRIMARY KEY(id)`에 성공하면 같은 숫자 키를 슬레이브가 `UNIQUE(code)`로 해석해 다른 행을 찾을 수 있다. 기존 모델은 UPDATE·DELETE 반례를 냈다. [상세 기록](RESULTS.md)에 11개 구성을 남겼다.

PR #8366은 마스터가 **실제로 로그 키를 만든 인덱스**의 설명자를 해시해 행 로그에 싣는다(`replication.c:304–353,450–525`). applylogdb가 해시를 읽어 슬레이브 서버 요청에 전달한다(`log_applier.c:3151–3186,4920–4965`). 슬레이브 서버가 로컬 첫 RK의 해시와 비교하고, 다르면 `ER_HA_GENERIC_ERROR`를 설정해 **행 검색 `locator_repl_prepare_force()` 전에 중단**한다(`locator_sr.c:6928–6998,7090–7120`). 적용 실패는 applylogdb의 오류 경로에서 기록되고 `fail_counter`가 증가한다(`log_applier.c:4771–4885`). **DDL 실패 자체를 고치거나 누락된 행을 자동 재적용하지는 않는다.**

## 해석의 한계

- 정상 모델은 2행과 최대 4문장 시도의 유한 상태다. 병렬 클라이언트의 커밋 가능한 순서를 탐색하지만, 실행 중인 두 트랜잭션의 잠금 대기·데드락·롤백 내부 단계나 파티션·다중 테이블 동작까지 재현하지 않는다.
- PR은 RK 설명자 전체 대신 64비트 해시를 기록하므로 이론적 충돌 가능성이 있다. 양쪽 RK가 같아도 행 데이터가 이미 다르면 RK 검사는 이를 검출하지 못한다.
- 이 검사는 **행 기반 복제 로그** 경로에 적용된다. `USE_SBR`의 SQL 재실행은 같은 RK 해시 검사를 거치지 않는다.
- PR #8366 바이너리의 정상 RK 연속 변경 및 불일치 경로는 실제 2노드 HA에서 별도 확인이 필요하다.
