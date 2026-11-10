# RK 선택·변경과 복제 적용 검증

검토일: 2026-11-10. 기준 코드는 RK 기능 브랜치 `f0bc3158d`와 [PR #8366](https://github.com/CUBRID/cubrid/pull/8366) 검토 시 HEAD `9054d2416`이다. **정상 변경을 먼저** TLA+로 검사했다. 기존에 논의한 슬레이브 DDL 실패는 별도 비교 사례로만 둔다. 실제 2노드 HA 통합 시험 결과는 아니다.

## 결과 한눈에 보기

| 상황 | 마스터 RK와 결과 | 기존 적용 경로 | PR #8366 적용 경로 | 판단 |
|---|---|---|---|---|
| 양쪽 DDL이 성공하고 같은 순서로 적용됨 | 인덱스 배열의 첫 RK 후보가 변경될 수 있음 | 모델에서 올바른 행 적용·최종 수렴 | 모델에서 같은 결과. RK 비교가 정상 로그를 거부하지 않음 | **정상 변경에서 문제 발견 안 됨** |
| 마스터 DDL 성공, 슬레이브 DDL 실패 | 양쪽 첫 RK 후보가 달라질 수 있음 | 모델에서 다른 행 UPDATE/DELETE 반례 | RK 해시 불일치 시 행 검색 전에 오류로 중단, 적용 실패를 로깅하고 fail counter 증가 | **기존 경로 문제, PR의 차단 대상** |
| 양쪽 RK는 같지만 데이터가 이미 다름 | 같은 RK 설명자 사용 | 이 검증의 RK 불일치 범위 밖 | RK 해시가 같으므로 이 검사만으로 데이터 차이 검출 불가 | **PR의 검출 대상 아님** |

여기서 “문제 발견 안 됨”은 아래 **작은 모델의 조건부 결과**다. CUBRID 전체 DDL·인덱스 구성과 실제 HA 실행의 무결성을 증명한 뜻은 아니다. “PR의 차단”은 소스 경로와 TLA+ 추상 모델에서 확인했으며, PR 바이너리로 2노드에서 실측하지 않았다.

## 마스터가 RK를 선택하는 방식

마스터는 RK를 클래스 메타데이터에 고정 저장하지 않는다. INSERT/DELETE는 `locator_add_or_remove_index_internal()`의 인덱스 루프에서, UPDATE는 `locator_update_force()`에서 **클래스 representation 인덱스 배열을 순서대로 보며 첫 RK 후보**를 로그 키로 쓴다. 슬레이브도 `btree_get_rkey_btid()`에서 로컬 배열의 첫 후보를 고른다. 후보 판정은 `or_is_replication_candidate_key()`다.

따라서 “PK가 항상 우선”이라는 별도 우선순위 규칙으로 설명하면 부정확하다. PK 또는 유효한 UNIQUE를 추가·삭제해 **첫 후보의 배열 순서가 바뀌는 경우** RK가 자동으로 바뀔 수 있다. 어떤 제약이 실제로 첫 후보인지는 그 시점의 representation을 봐야 한다. `RKNormalChange.tla`는 이 순서가 `PK(id) → UNIQUE(code) → UNIQUE(alt)`인 구체적 한 경우를 모델링한다. 이 순서를 모든 CREATE/ALTER에서 보장한다는 검증은 아니다.

## 정상 RK 변경 검사

두 노드의 초기 스키마·행이 같고, DDL이 양쪽에서 성공하며, 로그가 순서대로 적용되는 조건을 만들었다. 모델의 대표 순서는 다음과 같다.

| 순서 | 작업 | 모델에서 선택되는 RK |
|---|---|---|
| 1 | `UNIQUE(code)`, `UNIQUE(alt)`가 있는 상태에서 UPDATE | `UNIQUE(code)` |
| 2 | `ADD PRIMARY KEY(id)` 후 UPDATE | `PRIMARY KEY(id)` |
| 3 | `DROP PRIMARY KEY` 후 UPDATE | `UNIQUE(code)` |
| 4 | `DROP UNIQUE(code)` 후 DELETE | `UNIQUE(alt)` |

[RKNormalChange.tla](RKNormalChange.tla)를 TLC 2.19로 검사했다. [기존 경로](NormalLegacy.cfg)와 [PR 검사 경로](NormalGuarded.cfg) 모두 **57개 생성 상태, 36개 서로 다른 상태, 깊이 15**에서 `NoWrongRow`, `NoRKMismatch`, `NoApplyFailure`, `ConvergesWhenCaughtUp` 위반이 없었다. 출력: [기존](NormalLegacy.out), [PR](NormalGuarded.out). 즉 모델 안에서는 RK가 여러 번 바뀌어도 양쪽이 같은 변경을 순서대로 적용하면 키 해석이 같고, PR의 비교도 정상 DML을 막지 않았다.

실행 명령: `java -Xmx512m -jar tools/tla2tools.jar -deadlock -metadir /tmp/rk-normal-legacy -config NormalLegacy.cfg RKNormalChange.tla` (`NormalGuarded.cfg`도 동일).

## 슬레이브 DDL 실패와 PR #8366의 차단 위치

이 사례는 **의도적으로 스키마를 다르게 만드는 기존 논의**다. 마스터만 `ADD PRIMARY KEY(id)`에 성공하면 같은 숫자 키를 슬레이브가 `UNIQUE(code)`로 해석해 다른 행을 찾을 수 있다. 기존 모델은 UPDATE·DELETE 반례를 냈다. [상세 기록](RESULTS.md)에 11개 구성을 남겼다.

PR #8366은 마스터가 **실제로 로그 키를 만든 인덱스**의 설명자를 해시해 행 로그에 싣는다(`replication.c:304–353,450–525`). applylogdb가 해시를 읽어 슬레이브 서버 요청에 전달한다(`log_applier.c:3151–3186,4920–4965`). 슬레이브 서버가 로컬 첫 RK의 해시와 비교하고, 다르면 `ER_HA_GENERIC_ERROR`를 설정해 **행 검색 `locator_repl_prepare_force()` 전에 중단**한다(`locator_sr.c:6928–6998,7090–7120`). 적용 실패는 applylogdb의 오류 경로에서 기록되고 `fail_counter`가 증가한다(`log_applier.c:4771–4885`). **DDL 실패 자체를 고치거나 누락된 행을 자동 재적용하지는 않는다.**

## 해석의 한계

- 정상 모델은 인덱스 순서를 한 경우로 고정한 상태 모델이다. 실제 인덱스 배열의 모든 재배치, 동시 DDL, 실패·재시도, 파티션 및 다중 테이블 동작을 포괄하지 않는다.
- PR은 RK 설명자 전체 대신 64비트 해시를 기록하므로 이론적 충돌 가능성이 있다. 양쪽 RK가 같아도 행 데이터가 이미 다르면 RK 검사는 이를 검출하지 못한다.
- 이 검사는 **행 기반 복제 로그** 경로에 적용된다. `USE_SBR`의 SQL 재실행은 같은 RK 해시 검사를 거치지 않는다.
- PR #8366 바이너리의 정상 RK 연속 변경 및 불일치 경로는 실제 2노드 HA에서 별도 확인이 필요하다.
