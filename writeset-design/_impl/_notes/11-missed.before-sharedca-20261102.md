---
tags: [CBRD-27508, writeset, fixes, test-plan]
---
# writeset이 잡지 못할 수 있는 순서 의존 후보 (미검증 목록)

작성: 2026-10-29. CUBRID 11.4 매뉴얼(영문·국문 원문)에서 "PK·UNIQUE 키나 FK→부모 PK 참조가 아닌 경로로 두 트랜잭션의 순서가 결과에 영향을 주는 경우"를 찾은 목록이다. **모두 아직 시험하지 않았다.** 판정은 HA 재현 결과로만 한다. 코드만 읽고 내린 판단은 "코드 확인"으로 따로 적고 결론으로 쓰지 않는다.

관련 문서: [10-inherited-index-writeset-key](./10-inherited-index-writeset-key.md)(상속 공유 인덱스, 확인된 결함). 매뉴얼 조사 원문: `_notes/missed-scenarios-manual-survey-20261029.md`.

## 판단 기준

행 단위 복제에서 두 트랜잭션이 서로 다른 키만 건드리면 최종 상태는 적용 순서와 무관하다. 그래서 실제 누락은 다음 셋 중 하나에서 생긴다.

- 상태가 행(PK) 바깥에 있다. 예: 클래스 수준 값, serial.
- slave가 다시 계산하거나 검사한다. 예: 문장 복제, FK 검사.
- writeset 해시가 보는 키 동등성이 인덱스가 보는 키 동등성보다 잘게 나뉜다.

## 시험 방법 (후보마다 같음)

1. master에서 T1, T2를 차례로 커밋한다. T2는 T1 뒤에 반영돼야 하는 트랜잭션이다.
2. slave에서 T1이 건드리는 행을 미리 잠가(`csql --sysadm --write-on-standby`, 일정 시간 뒤 rollback) T1을 붙잡아 둔다.
3. writeset이 T2를 T1에 묶지 못했다면 slave가 T2를 먼저 반영해 오류나 데이터 차이가 생긴다.
4. 기록: master trace의 T2 dependency(T1 커밋인지), slave 반영 오류(applylogdb 로그와 `cub_client.err`), fail_counter, master·slave 최종 데이터.
5. 대조군: 이미 확인된 상속 결함을 같은 방식으로 돌려 이 방법이 결함을 드러내는지 먼저 본다.

준비한 스크립트(미실행): `~/ha_bench_tool/bin/pair_order_test.sh`(케이스 하나), `~/ha_bench_tool/bin/cases/pair_cases_20261029.sh`(케이스 15개).

## 후보 목록

1. **대조군: 상속 공유 인덱스** — `sup`에서 k=1 삭제 → `sub`에 k=1 삽입. 이미 dependency 누락을 trace로 확인함(10번 문서). slave 잠금으로 순서를 뒤집었을 때 오류가 나는지는 미시험.
2. **FK: 자식 삭제 → 부모 삭제(RESTRICT)** — 매뉴얼: HA slave는 FK를 검사함. 코드 확인: 자식 DELETE와 UPDATE의 옛 FK 값도 REF로 수집함(`locator_sr.c:8213`, `8922`, `8928`). 미시험.
3. **SHARED 컬럼** — 매뉴얼: "Column values are identical in all rows". PK가 다른 두 행에서 공유 값을 바꾸면 writeset 키가 없어 순서가 안 묶일 수 있음. 복제 방식 미확인. 미시험.
4. **CLASS ATTRIBUTE** — 매뉴얼: 클래스에 값이 하나. 행이 아니라 writeset 키가 없음. 복제 여부 미확인. 미시험.
5. **INCR/DECR(조회수 카운터)** — 매뉴얼: 사용자 트랜잭션과 독립된 top operation으로 반영, slave에서는 실행 불가. 같은 행의 일반 UPDATE와의 순서, 복제 경로와 writeset 포함 여부 미확인. 미시험.
6. **AUTO_INCREMENT 내부 serial** — serial 갱신이 commit-order 폴백에 걸리는지 미확인. 역순이면 failover 뒤 값이 겹칠 수 있음. 미시험.
7. **USE_SBR 힌트(문장 복제 DML)** — 코드 확인: statement 복제 경로(`execute_statement.c:514~526`). 폴백이 앞선 커밋을 기다리게 하는지 미시험. 예: T1 `UPDATE src`, T2 `INSERT /*+ USE_SBR */ INTO dst SELECT … FROM src`.
8. **확장·악센트 무시 collation** — `utf8_de_exp_ai_ci`('æ'와 'ae'), `utf8_gen_ai_ci`('é'와 'e'). 인덱스가 같다고 보는 두 문자열의 해시가 다르면 누락. 해당 collation 사용 가능 여부도 미확인. 미시험.
9. **공백 처리** — collation에서 공백 weight가 0인 경우('a b'와 'ab'), VARCHAR 뒤 공백('ab '와 'ab'). 인덱스 동등성과 해시가 맞는지 미시험.
10. **FK 부모·자식 collation이 다른 경우** — 부모 `utf8_en_ci`, 자식 `utf8_bin`. 만들 수 있는지와 REF·WRITE 해시 일치 여부 미시험.
11. **DOUBLE 키 0.0과 -0.0** — 비교로는 같고 바이트는 다를 수 있음(매뉴얼 근거 없음, 추론). 미시험.
12. **함수 기반 unique 인덱스** — 허용 여부 미확인. 허용되면 해시가 컬럼 값이 아닌 인덱스 키(함수 결과)를 쓰는지 확인 필요. 미시험.
13. **TRUNCATE(문장 복제)와 앞선 UPDATE** — 폴백이 앞선 커밋을 기다리게 하는지 미시험.
14. **checksumdb** — 매뉴얼: 계산 자체가 복제됨. statement 폴백으로 분류되는지 미확인. 미시험.
15. **slave에만 있는 UNIQUE 인덱스** — standalone 작업으로 노드마다 인덱스가 다를 때 master writeset에 그 키가 없음. 운영 제약으로 문서화 대상. 시험 대상 아님.
16. **slave 읽기에서 중간 상태 노출** — 키로 묶이지 않은 애플리케이션 인과 관계는 slave 읽기에서 master에 없던 중간 상태로 보일 수 있음. 정합성 문제가 아니라 고지 대상.

## 매뉴얼 조사에서 안전하다고 본 항목 (참고, 미시험)

트리거(효과가 같은 트랜잭션의 행 로그로 복제), ON DELETE CASCADE/SET NULL, 자기 참조 FK, PK 없는 테이블(복제 안 됨), MERGE/REPLACE/ON DUPLICATE KEY UPDATE, LOB(locator만 복제), ENUM, 저장 프로시저(DML이 호출 트랜잭션에 속함), DBLINK(원격은 별도 트랜잭션), 동의어·갱신 가능 뷰, SAVEPOINT 부분 롤백(남은 키는 추가 의존뿐), loaddb(직렬에서도 있던 문제), PK 변경 스키마 작업(DDL 폴백). 2PC/XA는 매뉴얼에 설명 없음.

## 진행 상태

- 2026-10-29: 목록과 시험 방법만 정리. 재현은 사용자 지시 후 진행.
- 2026-10-29 23:45 (빌드 2956, 01 수정·-0.0 수정 포함): 01 대조군과 11 DOUBLE -0.0 재시험 모두 T2 dependency가 T1 커밋으로 잡히고 slave 오류 없이 일치.
- 2026-10-30 02:3x: 12 함수 기반 unique 인덱스는 CUBRID 문법에서 허용되지 않음(`create unique index … (lower(name))` → `invalid create index`, 복합 `(lower(name), id)`도 같음). 일반 함수 인덱스는 만들어지나 writeset 수집 대상(PK·UNIQUE)이 아님 → 해당 없음. 06 AUTO_INCREMENT는 serial이 `db_serial` 뷰에 보이지 않고 `_db_serial`에 `pc_ai_ai_id`로 있어 검사 SQL을 고쳐 재시험(`ha_bench_tool/bin/cases/pair_retest_20261030_06.sh`).
