# RK 불일치 TLA+ 검증

[검증 보고서](REPORT.md)에 정상 RK 선택·변경 결과를 먼저 정리했다.

[정상 변경 모델](RKNormalChange.tla)과 `NormalLegacy.cfg`·`NormalGuarded.cfg`는 양쪽 DDL이 성공하는 경우를 검사한다. [기존 검증 기록](RESULTS.md)은 슬레이브 DDL 실패 조건에서 기존 경로와 PR #8366을 비교한다.

[스펙별 12개 고정 경로 모델](RKSpecCases.tla)의 24개 구성과 실행 출력은 [spec_cases](spec_cases)에 있다. [순서 조합 모델](RKConcurrentOrders.tla)은 병렬 클라이언트의 확정 순서를 4문장까지 탐색하며, [집계](ConcurrentCount.txt)를 별도로 기록했다.

예: `java -Xmx512m -jar tools/tla2tools.jar -deadlock -config LegacyConflictDelete.cfg RKReplication.tla`

모델 검증과 격리 CSQL 실험을 기록한 것이며, PR 바이너리의 2노드 HA 통합 시험 결과는 아니다.
