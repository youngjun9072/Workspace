# PoC 제품화 전에 남은 항목

- 복합 FK의 부모 PK packed image 동등성은 PoC에서 검증되지 않아 REF 수집 대상에서 제외했다.
- 해시 입력에 index VFID를 추가해 같은 클래스의 서로 다른 인덱스를 구분해야 한다.
- statement·DDL과 키 수집 실패 경로의 폴백을 전체 복제 경로에서 검증해야 한다.
- 현재 overflow 폴백은 `dependency_seq=prev_commit_lsa`를 기록하면서 `dependency_is_read=false`를 유지한다. 직전 COMMIT 한 건의 완료만으로 그 앞의 hole까지 해소됐다고 볼 수 없으므로, 연속 완료 대기를 전달하도록 보완해야 한다.
- 여러 키의 후보 중 더 작은 `read_seq`와 더 큰 `write_seq`가 함께 나오면 현재 코드는 최종 최댓값 후보의 종류만 남긴다. 앞선 REF 구간의 연속 완료 조건을 잃지 않도록 dependency 값과 대기 방식을 함께 보존해야 한다.
- 성공한 worker DB COMMIT만 completed set과 frontier의 입력으로 사용하도록 result 처리 순서를 수정해야 한다.
- 고정 크기 completed set과 In-flight List의 포화 정책, pending의 메모리 상한을 확정해야 한다.
- crash·재시작, error skip 경계와 HA 역할 전환을 장애 주입으로 반복 검증해야 한다.
- 성능 수치는 해당 장비에서 각 workload를 한 번 실행한 결과다. 단건은 10,000 commit 평균이고 대량은 10만 행 집계지만, 제품 판단에는 반복 실행과 분산값이 추가로 필요하다.
