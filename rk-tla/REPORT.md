# RK 불일치 TLA+ 검증 보고서

검토일: 2026-11-09~10. 대상은 RK 기능 브랜치 `f0bc3158d`와 검토 당시 [PR #8366](https://github.com/CUBRID/cubrid/pull/8366) HEAD `9054d2416`이다. 이 보고서는 **성능 측정이 아니라 모델 검사·격리 CSQL 실험**을 요약한다. 이미 논의된 DDL 실패 시나리오를 검증한 기록이며 새 이슈 확정이나 PR 완료 판정이 아니다. 상세 코드 경로와 SQL은 [RESULTS.md](RESULTS.md)에 있다.

## 검증 방법

1. [RKReplication.tla](RKReplication.tla)에 두 행, 마스터·슬레이브의 RK 선택, 마스터 DDL 성공·슬레이브 DDL 실패, 다음 UPDATE/DELETE 적용을 작은 상태 모델로 표현했다.
2. `Guarded=FALSE`는 기존 행 로그의 **키값만 전달**하는 경로, `Guarded=TRUE`는 PR #8366의 **행 검색 전 RK 식별정보 비교**를 추상화했다. `Op`는 UPDATE 또는 DELETE, `SlaveIndexNameConflict`는 슬레이브에서만 발생한 인덱스 이름 충돌을 뜻한다.
3. TLC 2.19로 `*.cfg` **11개 구성**을 실행했다. 예: `java -Xmx512m -jar tools/tla2tools.jar -deadlock -metadir /tmp/rk-tla-run -config LegacyConflictDelete.cfg RKReplication.tla`. 실행 출력은 같은 이름의 `*.out`에 보관했다.
4. 별도로 `f0bc315` 빌드의 격리된 단일 DB에서 마스터·슬레이브 대용 테이블 두 개를 만들었다. 두 테이블에 같은 행을 넣고 한쪽에만 이름이 겹치는 일반 인덱스를 만든 뒤, `ADD PRIMARY KEY(id)`의 성공·실패와 키값 `1`의 서로 다른 행 선택을 CSQL로 확인했다.

CSQL 실험은 **DDL 이름 충돌과 키값 해석**을 확인한 것이다. 실제 2노드 HA에서 잘못된 행의 UPDATE/DELETE나 PR 바이너리의 차단 동작까지 실행한 결과는 아니다.

## 결과 한눈에 보기

| 조건 | 기존 경로 모델 | PR #8366 검사 모델 |
|---|---|---|
| 초기 행이 같고 슬레이브에서만 PK 추가 DDL 실패 | `LegacyConflictUpdate/Delete`: `NoWrongRow` 위반 | `GuardedConflictUpdate/Delete`: 불변식 위반 없음, 각각 7개 상태 탐색 |
| DDL 실패가 기록된 뒤 다음 DML의 오류 없는 오적용 | `LegacyConflictSilent`: `NoSilentDMLMismatch` 위반 | RK 불일치 시 행 검색 전에 오류로 중단 |
| OFF 소스 SBR로 이미 데이터가 달라진 조건 | `LegacyUpdate/Delete/Silent`: 반례 | `GuardedUpdate/Delete`: RK 불일치에 따른 오적용 차단 |
| 양쪽 RK가 같은 조건 | `LegacySameSchema`: 검사 통과 | 이 구성은 별도 PR 모델 실행 대상이 아님 |

## 확인된 문제와 의미

**1. 키값만으로는 어느 RK의 값인지 구별할 수 없다.** 처음에는 양쪽 모두 `UNIQUE(code)`를 쓰다가 마스터만 `PRIMARY KEY(id)` 추가에 성공하면, 마스터의 `id=1` 로그 키값을 슬레이브가 `code=1`로 찾을 수 있다. 초기 두 행이 `(id=1, code=2)`, `(id=2, code=1)`이면 서로 다른 행을 가리킨다. TLC의 기존 경로에서 UPDATE·DELETE 모두 오적용 반례가 나왔다.

**2. DDL 실패 기록만으로 뒤따르는 DML을 막지는 못한다.** 모델의 슬레이브 DDL 실패는 fail counter를 늘린다. 기존 경로의 다음 DML은 RK 불일치 정보를 받지 못하므로, 다른 행에 적용하면서 그 DML 자체의 오류는 남기지 않을 수 있다. `LegacyConflictSilent`가 이를 보여준다.

**3. PR #8366의 RK 비교는 이 반례의 행 오적용을 막는다.** 모델에서 마스터 RK와 슬레이브 RK가 다르면 행을 찾기 전에 실패한다. 코드 조사에서도 PR은 마스터가 사용한 RK 설명자의 해시를 행 로그에 넣고, applylogdb를 거쳐 슬레이브 서버에서 로컬 RK 해시와 비교한다. 다만 실패한 DDL과 누락된 행을 자동 복구하지는 않는다.

## 적용 범위와 남은 검증

- 모델의 RK 일치 판정은 추상화다. 실제 PR의 **64비트 FNV-1a 해시**는 이론적으로 충돌할 수 있다.
- 검사는 INSERT/UPDATE/DELETE의 **행 기반 복제 로그** 경로를 대상으로 한다. SQL 원문을 다시 실행하는 `USE_SBR`은 같은 RK 비교를 거치지 않는다.
- 이름 충돌 실험은 HA 시작 전 슬레이브에만 일반 인덱스를 둔 **의도적으로 다른 스키마**를 사용했다. 정상 HA 초기화 절차에서 항상 발생한다는 뜻이 아니다.
- PR #8366 바이너리의 2노드 HA 통합 시험은 하지 않았다. 모델 검사 결과는 실제 복제 적용의 성공·실패를 대체하지 않는다.

재현 SQL, 함수 호출 순서, 11개 구성별 결과, 실패 후 LSA 진행과 복구 한계는 [상세 검증 기록](RESULTS.md)에 남겼다.
