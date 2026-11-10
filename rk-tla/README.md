# RK 불일치 TLA+ 검증

[검증 보고서](REPORT.md)에 실행 방법과 발견한 문제를 먼저 정리했다.

[검증 기록](RESULTS.md)에 기존 복제 경로와 PR #8366의 RK 검사 모델을 비교한 결과가 있다. `RKReplication.tla`는 모델, `*.cfg`는 실행 조건, `*.out`은 TLC 실행 결과다.

예: `java -Xmx512m -jar tools/tla2tools.jar -deadlock -config LegacyConflictDelete.cfg RKReplication.tla`

모델 검증과 격리 CSQL 실험을 기록한 것이며, PR 바이너리의 2노드 HA 통합 시험 결과는 아니다.
