# writeset 병렬 적용 검증 계획

## 1. 정확성 검증

- 같은 PK·UNIQUE 키의 변경 순서
- UNIQUE 값 제거 후 재사용
- 부모 PK WRITE와 자식 FK REF의 순서
- 같은 부모를 참조하는 자식 트랜잭션의 병렬 실행
- 단일·복합 FK와 NULL FK
- UPDATE의 old key와 new key

복합 FK의 부모 WRITE·자식 REF 동일 hash를 확인하는 단위 테스트 소스는 `unit_tests/writeset/test_writeset.cpp`에 추가됐다. 다만 테스트 빌드의 외부 의존성 다운로드가 네트워크 제한으로 완료되지 않아 아직 실행 결과는 없다.

## 2. 동시성 검증

- 서로 다른 키의 probe·publish 병렬 수행
- 같은 키 슬롯의 동시 갱신
- probe·publish와 전체 history clear의 경합
- worker 완료 순서가 로그 순서와 다른 경우

## 3. 용량 폴백과 오류 전파 검증

- 트랜잭션별 writeset 한도 초과가 트랜잭션 전체 commit-order 폴백으로 전환되는지 확인
- 전역 history 용량 초과가 exclusive clear와 `history_start` 갱신으로 처리되는지 확인
- statement 복제가 commit-order 폴백으로 전환되는지 확인
- 부모 도메인 조회와 FK 키 추출 실패가 locator 호출자까지 같은 오류 코드로 전달되는지 확인
- 형변환·크기 계산·패킹·메모리 할당 실패가 DML을 중단하고 COMMIT과 history publish를 막는지 확인
- NULL이 포함된 FK만 정상 제외되고, 복합 FK 전체가 부모 PK 도메인의 `MIDXKEY`로 구성되어 부모 WRITE와 같은 해시를 만드는지 확인

## 4. 복구 검증

- 재시작 시 완료된 트랜잭션 skip
- 미완 트랜잭션 재적용
- 완료 hole이 있는 상태의 영속 경계
- failover drain 중 오류 로그와 fail counter 처리
- 마스터 `cub_server` 재시작 전후의 같은 키 트랜잭션 순서 보존
- 재시작 후 첫 복제 COMMIT 하나만 history reset 경계를 갖는지 확인
- 경계 대기 중 신규 dispatch는 멈추고 worker result 수거·pending 재판정은 계속하는지 확인
- 경계 task를 Gate Order에 조기 등록하지 않아 자기 대기 교착이 없는지 확인
- 마스터·슬레이브가 경계 기록 전·후와 drain 중에 재종료되는 경로

## 5. 성능 검증

- 키 수집과 probe·publish의 트랜잭션당 비용
- 비충돌 키와 동일 키의 처리량 차이
- history 크기별 조회·갱신 비용
- worker 수에 따른 apply 처리량과 pending 체류 시간
