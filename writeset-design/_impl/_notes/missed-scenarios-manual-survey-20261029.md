# writeset 병렬 applier가 놓칠 수 있는 순서 의존 시나리오 (CUBRID 11.4 매뉴얼 기준)

근거는 scratchpad/cubman/*.rst와 매뉴얼 웹 페이지 admin/migration.html(로컬 admin_migration.rst가 404 HTML이라 웹에서 받음)이다. 매뉴얼에 직접 나오지 않고 동작을 추론한 항목은 "not confirmed"로 표시했다.

판단 기준은 하나다. 행 단위 복제에서 두 트랜잭션이 서로 다른 키만 건드리면 최종 상태는 적용 순서와 무관하다. 따라서 실제 구멍은 다음 세 경우 중 하나다.
(a) 상태가 행(PK) 바깥에 있다. 예: 클래스 수준 값, serial.
(b) 슬레이브가 재계산하거나 검사한다. 예: 문장 복제, FK 검사.
(c) writeset 해시상의 키 동등성이 인덱스의 키 동등성보다 세분화되어 있다.

## 1. 순서 독립성을 깰 가능성이 있는 항목

**1-1. SHARED 컬럼 (가장 유력)**
- 매뉴얼: "SHARED: Column values are identical in all rows. If a value different from the initial value is INSERTed, the column value is updated to a new one in every row." (sql_schema_table_stmt.rst)
- HA 복제 방식: 매뉴얼에 언급이 없다 (not confirmed). 값이 클래스 객체에 하나만 저장되므로, 행 로그로 복제된다면 슬레이브는 INSERT를 적용할 때 그 값을 덮어쓰게 된다.
- 예: T1이 `INSERT t(pk=1, s=5)`, T2가 `INSERT t(pk=2, s=7)`을 실행한다. PK가 서로 달라 의존이 없으므로 슬레이브가 T2→T1 순서로 적용할 수 있다. 그러면 마스터의 s는 7인데 슬레이브의 s는 5가 된다.

**1-2. CLASS ATTRIBUTE (클래스 속성)**
- 매뉴얼: "a class attribute is associated with the class itself ... it has only one value" (sql_oodb.rst)
- HA 복제 여부와 방식은 not confirmed. PK 행이 아니라서 writeset 키가 생기지 않는다. 행 로그 경로로 복제된다면 1-1과 같은 last-writer 문제가 생기고, 문장 복제라면 fallback으로 안전하다.

**1-3. Click counter INCR/DECR**
- 매뉴얼: "execute independent of user-defined transactions and is applied automatically to the database by the top operation ... apart from the transaction's COMMIT/ROLLBACK" 그리고 "returns an error in ... slave mode" (sql_function_click_counter_fn.rst, ha.rst HA Constraints)
- 복제 여부: 슬레이브에서 실행이 금지된다는 내용만 있고, 마스터의 INCR이 어떻게 복제되는지는 not confirmed. 현재 commit-order fallback은 "serial system op"만 대상으로 한다. INCR도 top operation이므로, 행 로그가 커밋 레코드 없이 흘러가거나 writeset 계산에서 빠질 수 있다.
- 예: board(id=1)에 대해 INCR(read_count)가 top op로 반영된 뒤 T1 `UPDATE board SET title='x' WHERE id=1`이 커밋된다. INCR 쪽 행 이미지가 해시되지 않고 UPDATE가 전체 행 이미지를 적용한다면, 적용 순서가 바뀔 때 슬레이브는 증가분이나 title 중 하나를 잃는다. 코드 확인이 1순위다.

**1-4. AUTO_INCREMENT와 SERIAL**
- 매뉴얼: "a serial cache ... does not generate replication logs" (ha.rst Serial Cache). 그리고 TRUNCATE가 AI 값을 초기화한다 (sql_query_truncate.rst).
- NOCACHE serial 갱신은 system op fallback으로 처리된다는 전제다. 확인할 점은 AUTO_INCREMENT가 내부 serial을 증가시킬 때도 같은 레코드 타입을 써서 fallback에 걸리는지다 (not confirmed).
- 예: T1과 T2가 각각 AI로 id 1과 2를 받는다. 행 PK가 달라 병렬로 적용된다. serial 갱신이 fallback 없이 역순으로 적용되면 슬레이브의 current_val이 1로 남고, failover 뒤 다음 INSERT가 id 2를 다시 발급해 중복이 생긴다. CACHE serial은 원래 복제되지 않으므로(매뉴얼 명시) 이 순서 문제와는 별개의 기존 불일치다.

**1-5. FK의 REF 범위: 자식 DELETE와 자식 UPDATE의 이전 FK 값**
- 매뉴얼: ON DELETE에 쓸 수 있는 동작은 NO ACTION/RESTRICT/CASCADE/SET NULL이다. ON UPDATE에서는 CASCADE를 쓸 수 없고 기본값은 RESTRICT다 (sql_schema_table_stmt.rst). 또 HA 슬레이브는 FK를 검사한다 (migration.html loaddb 경고: "foreign key constraints are checked during the replication process of the slave").
- 배경 설명의 "자식 행이 참조하는 부모 PK"가 삭제되는 자식 행과 FK를 바꾸는 UPDATE의 이전 값까지 포함하는지 확인해야 한다.
- 예: T1이 자식 c의 부모를 P에서 Q로 바꾸고(또는 c를 DELETE하고) 커밋한 뒤, T2가 부모 P를 DELETE한다(RESTRICT). T2의 WRITE(P)가 T1의 이전 값 REF(P)와 만나지 않으면 병렬 적용이 가능해진다. 슬레이브가 T2를 먼저 적용하면 FK 위반 에러가 나고, retry나 ignore 설정에 따라 데이터가 어긋난다.

**1-6. 슬레이브에서 재계산되는 문장 복제 (USE_SBR, checksumdb, TRUNCATE, CTAS)**
- 매뉴얼: USE_SBR은 "the corresponding statement is executed when the transaction log is applied in the slave node" (sql_tuning.rst). checksumdb는 "The calculation itself, not the calculated value, is then replicated" (ha.rst). TRUNCATE는 "generates way lesser log records"라고 되어 있어 문장 복제로 추정되며, CASCADE는 자식 테이블로 전파된다 (sql_query_truncate.rst).
- 이 문장들은 슬레이브에서 "이전 커밋은 모두 적용되고 이후 커밋은 하나도 적용되지 않은" 정확한 prefix 상태를 봐야 한다. fallback이 앞쪽 대기와 뒤쪽 차단을 모두 보장하는지 확인해야 한다. 그리고 checksumdb와 CTAS의 레코드가 실제로 statement 타입으로 분류되어 fallback에 걸리는지도 확인해야 한다 (not confirmed).
- 예: T1이 `UPDATE pk_tbl ...`, T2가 `INSERT /*+ USE_SBR */ INTO nopk SELECT * FROM pk_tbl`을 실행한다. T2가 T1보다 먼저 적용되면 nopk의 내용이 달라진다.

**1-7. 슬레이브에만 있거나 마스터와 다른 인덱스**
- 매뉴얼: "Index change and authority change ... can be performed by stopping each node and executing standalone mode" 그리고 "tasks performed in standalone mode" don't generate replication logs (ha.rst Operational Scenarios / Standalone Mode). 대량 DML도 노드별로 처리하는 시나리오가 있다.
- 슬레이브에만 UNIQUE 인덱스가 있으면 마스터의 writeset에 그 키가 들어가지 않는다.
- 예: T1이 u='a' 행을 DELETE하고, T2가 다른 PK로 u='a'를 INSERT한다. 마스터에는 u에 대한 UNIQUE가 없어서 의존이 붙지 않는다. 슬레이브가 T2를 먼저 적용하면 unique 위반이 난다.

**1-8. 콜레이션 동등성과 pseudo key의 차이**
- 매뉴얼에 나오는 동등 관계는 세 가지다. ci/ai("'ABC' and 'abc' are equal"), expansion("'æ' ... the same way as 'ae'"), 그리고 공백 weight 0("In CUBRID, space character compares as zero")이다 (sql_i18n.rst).
- 인덱스가 같다고 보는 두 문자열의 pseudo key가 다르면 의존이 누락된다. 반대로 pseudo key가 같은데 인덱스가 다르다고 보는 경우는 과직렬화일 뿐이라 안전하다. exp 콜레이션의 expansion/contraction과, 'a b'와 'ab'가 같게 비교되는지는 not confirmed이므로 테스트가 필요하다.
- 예: utf8_de_exp_ai_ci UNIQUE 컬럼에서 T1이 'æ'를 DELETE하고 T2가 'ae'를 INSERT한다.

**1-9. FK 컬럼과 부모 PK의 콜레이션·길이 차이**
- 매뉴얼: "The foreign key and the referenced primary key must have the same data type" (sql_schema_table_stmt.rst). 콜레이션과 정밀도가 같아야 하는지는 명시되어 있지 않다 (not confirmed).
- "부모 PK 타입으로 캐스트"할 때 콜레이션과 CHAR 패딩 길이까지 부모 기준으로 맞추지 않으면 REF와 WRITE 해시가 어긋난다.
- 예: 부모가 utf8_en_ci이고 자식이 utf8_bin이다. T1이 부모 'ABC'를 삭제하고 T2가 'abc'를 참조하는 자식을 INSERT한다.

**1-10. FLOAT/DOUBLE 키**
- 매뉴얼: "Extra caution is required when comparing data because the DOUBLE type stores approximate numeric" (sql_datatype.rst).
- +0.0과 -0.0은 비교상 같지만 바이트가 다르다(추론이며 매뉴얼에는 없다, not confirmed). 해시가 바이트 기반이면 T1이 0.0을 DELETE하고 T2가 -0.0을 INSERT하는 경우의 의존을 놓친다.

**1-11. 파티션 테이블과 상속 계층의 키 네임스페이스**
- 매뉴얼: "All indexes created on a partitioning table are local indexes" 그리고 "The partitioning key must be part of the primary key's and all the unique indexes' definition" (sql_partition.rst).
- 해시 네임스페이스가 파티션별 클래스나 BTID라면 두 가지가 문제가 된다. 하나는 부모가 파티션 테이블일 때 FK의 REF(루트 기준)와 WRITE(파티션 기준)가 다를 수 있다는 점이다. 다른 하나는 상속 계층에서 공유되는 UNIQUE가 클래스별로 갈라질 수 있다는 점이다. 둘 다 not confirmed이며 구현에서 확인할 항목이다.

**1-12. Function-based UNIQUE 인덱스**
- 매뉴얼에는 함수 인덱스가 설명되어 있다 (sql_tuning.rst). UNIQUE 함수 인덱스가 허용되는지는 명시되어 있지 않다 (not confirmed). filtered unique 인덱스는 금지다 ("the filtered unique index is not allowed").
- writeset이 컬럼 값을 해시하고 인덱스 키(예: LOWER(name))를 해시하지 않는다면 의존을 놓친다. 마스터가 B-tree 키를 직접 쓴다면 문제없다.

## 2. 순서 독립성을 깨지 않는다고 본 항목

- **트리거**: 매뉴얼은 "jobs performed by triggers from master node are written to the SQL log"라고 하며, 9.1 이전에는 중복 실행 문제가 있었다고 한다 (ha.rst). 따라서 트리거 효과는 같은 트랜잭션의 행 로그로 복제되고 슬레이브에서는 트리거가 실행되지 않는 것으로 읽힌다. FK CASCADE 동작도 트리거를 실행하지 않는다 ("do not activate the trigger action"). 트리거가 PK 없는 테이블에 쓰는 경우는 원래 복제되지 않는다.
- **ON DELETE CASCADE/SET NULL**: 연쇄되는 자식 행 변경이 같은 트랜잭션의 행 로그와 키 WRITE에 들어가므로 의존이 잡힌다.
- **자기 참조 FK**: REF와 WRITE가 같은 테이블의 같은 PK 해시 공간에 있으므로 잡힌다. 1-5의 REF 범위 문제는 여기에도 똑같이 적용된다.
- **PK가 아닌 UNIQUE 키를 참조하는 FK**: 매뉴얼은 "references the primary key in other tables"라고만 하므로 지원하지 않는 것으로 본다.
- **PK 없는 테이블**: 복제되지 않는다 ("only tables which have a primary key can be replicated"). 이 테이블에서 PK 테이블로 INSERT...SELECT하면 값이 행 로그에 실려 가므로 안전하다. PROMOTE된 파티션은 PK가 없어 복제되지 않는다.
- **MERGE, REPLACE, ON DUPLICATE KEY UPDATE**: 결과가 행 단위 로그로 남고, 삭제되거나 갱신되는 행의 키가 모두 WRITE에 들어가므로 안전하다.
- **LOB**: Locator만 복제되고 데이터는 복제되지 않는다 (ha.rst, sql_datatype.rst). 원래 있던 불일치이며 순서와는 무관하다.
- **ENUM**: 인덱스 번호로 저장되고 '='는 그 번호로 비교한다. 목록 변경은 DDL이라 fallback으로 처리된다.
- **JSON, 컬렉션**: 인덱스나 키로 쓸 수 있는지 매뉴얼에서 확인하지 못했다 (not confirmed). LOB은 인덱스를 만들 수 없다고 명시되어 있다.
- **OID/객체 참조 컬럼**: DONT_REUSE_OID 테이블만 참조할 수 있다. HA에서 OID 값을 어떻게 복제하는지는 not confirmed다. FK가 없으므로 객체를 만드는 쪽과 참조하는 쪽 사이의 순서가 잡히지 않는다. applier가 참조 OID를 해석하는 방식에 따라 위험할 수 있어 낮은 우선순위로 확인이 필요하다.
- **TIMESTAMPTZ/LTZ, DATETIMETZ/LTZ**: LTZ는 "stores UTC time internally"이고, TZ는 UTC로 정규화하므로 동등성이 일치한다. 별개로 "The session and server timezone should not be changed if database contains indexes ... on TIMESTAMP, TIMESTAMPLTZ, DATETIMELTZ"라는 문구가 있다 (sql_schema_index_stmt.rst). 마스터와 슬레이브의 타임존이 다르면 순서와 무관하게 불일치 위험이 있다.
- **CHAR 후행 공백**: CHAR는 패딩되어 저장되고, VARCHAR 비교는 후행 공백을 구분한다 (sql_datatype.rst). 저장된 바이트로 보면 동등성이 일치한다.
- **VARCHAR 압축(255바이트 이상)**: 압축은 내용에 따라 결정적이지만 해시는 압축을 푼 값으로 계산해야 한다 (확인 권장).
- **저장 프로시저**: PL/CSQL은 복제되고 Java SP는 선언만 복제된다 (ha.rst). SP 안의 DML은 호출한 트랜잭션에 속한다 (pl_jsp.rst). 다른 DB 연결은 별도 트랜잭션이다. 모두 행 로그로 남아 안전하다.
- **메서드**: "using method that does not generate replication logs may cause data inconsistency" (ha.rst). 원래 복제되지 않으므로 순서 문제와는 별개다.
- **DBLINK**: "DML ... in the remote DB are executed as auto commits separately" (sql_dblink.rst). 원격 DB가 자기 자신이어도 독립 트랜잭션이고 자체 writeset을 가진다.
- **동의어(synonym), 갱신 가능 뷰**: 기본 테이블의 행 로그로 바뀌므로 안전하다.
- **SAVEPOINT 부분 롤백**: 롤백된 키가 writeset에 남더라도 과직렬화일 뿐이다.
- **2PC/XA**: 매뉴얼에 설명이 없다 (not confirmed).
- **한 트랜잭션 안의 DDL+DML**: DDL도 트랜잭션에 속한다 (sql_transaction.rst 예제). 트랜잭션에 statement 레코드가 하나라도 있으면 트랜잭션 전체가 fallback되는지 확인해야 한다.
- **loaddb (-C)**: HA의 CS 모드에서는 "-d"만 쓸 수 있고, 기본 periodic-commit은 10240이다. 마스터는 FK를 검사하지 않고 슬레이브는 검사한다 (migration.html). 직렬 적용에서도 생기는 기존 문제다. 큰 트랜잭션은 history 크기를 넘어 fallback된다.
- **unloaddb**: 복제 구축 수단이 아니다 ("replication using cubrid unloaddb and cubrid loaddb is unavailable", ha.rst).
- **replica**: ha_replica_time_bound는 "only the transactions which have been run on the specified time ... are applied" (ha.rst). 병렬 적용에서도 경계 이후의 트랜잭션이 디스패치되지 않고 prefix로 끊기는지 운영상 확인이 필요하다. replica에 직접 쓴 내용(REPLICA_ONLY와 RW)은 복제되지 않는다 (admin_config.rst).
- **ha_applylogdb_ignore_error_list**: 무시된 에러로 일부 변경이 빠진 경우, 그 결과가 적용 순서에 따라 달라질 수 있다. 의존이 잡힌 키라면 순서가 유지되므로 영향이 제한적이다.
- **PK 변경 스키마 작업**: "primary key change ... replication reflection may not occur" 그리고 "must be performed during the read service" (ha.rst). DDL fallback으로 처리된다.
- **키 없이 이어지는 애플리케이션 인과 관계**: 예를 들어 주문 행을 쓴 T1을 읽고 다른 테이블에 결제 행을 쓰는 T2는 FK가 없다. 최종 상태는 같지만, 슬레이브 읽기 브로커(RO/SO, 부하 분산)는 마스터에 존재한 적 없는 중간 상태를 볼 수 있다. 정확성 문제라기보다 일관성 수준을 문서화해야 하는 항목이다.

## 3. 실제 구멍일 가능성이 높은 순서

1. **INCR/DECR click counter(top operation) 복제 경로**: writeset 해시와 fallback 양쪽에서 빠질 가능성이 있다. 같은 PK 행의 일반 UPDATE와 역전되면 증가분이나 컬럼 값이 유실된다.
2. **SHARED 컬럼과 CLASS ATTRIBUTE**: PK가 다른 트랜잭션끼리 클래스 수준의 단일 값을 놓고 last-writer 경쟁을 한다. writeset으로는 표현할 수 없다.
3. **FK REF 범위**: 자식 DELETE와 자식 UPDATE의 이전 FK 값이 REF에 들어가지 않으면, 이후의 부모 DELETE/UPDATE(RESTRICT)와 역전되어 슬레이브 FK 검사가 실패한다.
4. **AUTO_INCREMENT 내부 serial 갱신**: serial system-op fallback에 실제로 걸리는지 확인해야 한다. 걸리지 않으면 failover 뒤 AI 값이 중복된다.
5. **문장 복제(USE_SBR, checksumdb, TRUNCATE, CTAS)의 fallback 분류와 "이후 차단" 보장**: 이 레코드들이 statement 타입이 아니거나, fallback이 뒤쪽 트랜잭션을 막지 않으면 결과가 달라진다.
6. **콜레이션 pseudo key와 인덱스 동등성의 차이**: exp 콜레이션의 expansion/contraction, 공백 weight 0, ai/ci. FK 캐스트가 부모 콜레이션과 패딩을 따르는지도 포함한다.
7. **슬레이브 전용 UNIQUE 인덱스**: standalone 작업으로 노드마다 인덱스가 다른 경우다. 운영 제약으로 문서화가 필요하다.
8. **파티션/상속 테이블의 키 해시 네임스페이스**: 파티션 로컬 인덱스와 루트 기준 FK REF가 다를 수 있고, 계층 공유 UNIQUE가 클래스별로 갈라질 수 있다.
9. **±0.0 FLOAT/DOUBLE 키와 UNIQUE 함수 인덱스**: 해시 기준이 인덱스 키와 다른 경우다.
10. **슬레이브 읽기의 non-prefix 상태 노출**: 정확성 문제가 아니라 사용자에게 고지할 사항이다.

1~5는 코드 확인(log_applier, writeset 계산부, serial/INCR의 replication record 생성부)으로 바로 판정할 수 있다. 6, 8, 9는 2노드 HA에서 두 트랜잭션 역전 UT로 재현하는 것을 권장한다.
