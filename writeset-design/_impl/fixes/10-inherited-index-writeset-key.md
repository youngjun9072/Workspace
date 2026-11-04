---
tags: [CBRD-27508, writeset, master, fixes]
---
# 상속 계층이 함께 쓰는 unique 인덱스에서 writeset 키가 클래스마다 갈리는 문제

작성: 2026-10-29. HA 시험 중 발견. 코드 기준: `~/Workspace/cubrid`, 브랜치 `feature/CBRD-27508-parallel-applylogdb-writeset`, `3fd9a07fb`(develop 병합 뒤). 아직 코드 변경 없음. **최우선 처리 항목.**

## 한 줄 요약

writeset 키 해시는 `행이 들어간 클래스 OID + 인덱스 VFID + 키 값`으로 만든다. 상속 계층에서는 하위 클래스가 상위 클래스의 PK·UNIQUE B-tree를 함께 쓰므로, 같은 인덱스의 같은 키가 행의 클래스에 따라 다른 해시가 된다. 그래서 상위 클래스에서 지운 키를 하위 클래스에 다시 넣는 트랜잭션이 앞 트랜잭션에 의존하지 않고, slave가 순서를 바꿔 반영할 수 있다.

## 용어

- 클래스 OID: 테이블(클래스) 객체의 식별자. 상속에서는 상위·하위 클래스가 서로 다른 OID를 가지고, 파티션도 파티션마다 다르다.
- VFID: 디스크 파일 하나의 식별자(볼륨 번호, 파일 번호). 인덱스 하나는 B-tree 파일 하나이므로 VFID가 곧 인덱스의 정체다. BTID는 VFID에 루트 페이지 위치를 더한 것이다.
- 충돌을 놓침: 같은 인덱스의 같은 키가 다른 해시가 되는 경우. 순서가 바뀌어 정합성이 깨질 수 있다(위험).
- 추가 의존: 다른 키가 같은 해시가 되는 경우. 병렬성만 줄어든다(안전).

## 확인한 사실

- 하위 클래스 제약은 상위 클래스의 BTID를 그대로 가져간다(`schema_manager.c:11318`, `con->index_btid = super_con->index_btid`). PRIMARY KEY는 파티션이 아니면 global이다(`sm_is_global_only_constraint`, `schema_manager.c:16254~16319`).
- HA 시험: `sup2(k int primary key)`, `sub2 under sup2`. `sub2`에 `sup2`와 같은 키를 넣으면 `pk_sup2_k(B+tree: 0|13440|13441) ON CLASS dba.sub2`에서 unique 위반이 난다. 같은 B-tree를 쓴다는 근거다.
- WRITE 키 수집은 행의 클래스 OID와 공유 BTID를 넘긴다(`locator_sr.c:8197`, `8904`, `9188`).
- HA 시험: `sup2`에서 k=1을 지운 뒤 관계없는 커밋 하나를 끼우고 `sub2`에 k=1을 넣었다. 넣은 트랜잭션의 dependency가 지운 트랜잭션으로 잡히지 않았다. 반대 방향(`sub2`에서 지우고 `sup2`에 넣음)도 같았다. 이번 시험에서는 slave 반영 순서가 맞아 데이터는 일치했고 fail_counter는 0이었다.
- 같은 원인의 두 번째 경로: FK가 상위 클래스 PK를 참조하고 부모 행이 하위 클래스에 있으면, REF는 참조 대상(상위) 클래스 OID로(`locator_sr.c:7938`), 부모 WRITE는 하위 클래스 OID로 해시돼 충돌을 놓친다. 코드로만 확인했다.
- B-tree 루트 헤더에는 인덱스를 만든 클래스(`topclass_oid`, `btree_load.h:262`)가 있다. 읽으려면 루트 페이지를 고정해야 한다. 메모리의 `index->atts[0]->classoid`도 정의한 클래스를 가리키며, 파티션에서는 부모 테이블이다(`execute_schema.c:7995`).
- 매뉴얼(11.4 영문·국문)에는 상속에서 PK·UNIQUE B-tree를 공유하는지가 나와 있지 않다. 위 사실은 코드와 시험으로 확인한 것이다.

## 방안

- A: 해시에서 클래스 OID를 빼고 인덱스 VFID와 키 값만 쓴다(`wset_fnv1a`).
- B: 행의 클래스 대신 인덱스 소유 클래스 OID를 쓴다.

### 개념 비교

writeset이 막으려는 것은 같은 unique 인덱스의 같은 항목을 두 트랜잭션이 건드렸는데 slave에서 순서가 바뀌는 것이다. 그래서 충돌 키의 정체는 uniqueness가 적용되는 범위(B-tree)와 키 값이다. MySQL은 인덱스 하나가 테이블 하나에 속해서 테이블을 해시에 넣어도 범위가 같지만, CUBRID 상속 계층에서는 B-tree가 여러 클래스에 걸친다. 행의 클래스 OID를 넣으면 범위보다 잘게 나뉘어 충돌을 놓친다.

- A는 범위(B-tree)를 그대로 해시에 쓴다.
- B는 소유 클래스가 VFID에 따라 정해지는 값이므로 범위는 A와 같다. 다만 소유 클래스를 행이 아닌 B-tree에서 얻어야만 맞고, 다중 상속과 파티션에서 소유 클래스를 무엇으로 볼지 정해야 하며, 얻는 비용(루트 페이지 고정 또는 정의 맞추기)이 든다.

### 문법별 검토 (매뉴얼 조사 + 소스 조사)

- 상속 PK·UNIQUE, `ONLY`·`ALL` DML, REPLACE, ON DUPLICATE KEY UPDATE가 상위·하위 클래스에 걸치는 경우: 지금 코드는 놓친다. A는 맞다. B는 B-tree에서 소유 클래스를 얻을 때만 맞다.
- FK가 상위 클래스 PK를 참조하고 부모 행이 하위 클래스에 있는 경우: 지금 코드는 놓친다. A는 맞다. B는 REF와 WRITE를 모두 소유 클래스로 맞출 때만 맞다.
- 다중 상속(`UNDER s1, s2`): A는 맞다. B는 소유 클래스 정의가 필요하다(코드상 B-tree마다 하나지만 매뉴얼 정의 없음).
- 파티션: 매뉴얼상 모든 인덱스가 local이고, PK·UNIQUE에는 파티션 키가 반드시 들어간다. 같은 키가 두 파티션에 생기지 않는다. A·B 모두 맞다(B는 소유 클래스를 부모로 볼지 파티션으로 볼지 정해야 함).
- 파티션 키 UPDATE(행 이동): 옛 키는 옛 파티션, 새 키는 새 파티션 B-tree로 수집된다. A·B 모두 맞다.
- 필터 인덱스: 매뉴얼상 unique 필터 인덱스는 허용되지 않는다. 해당 없음.
- 함수 기반 인덱스: B-tree 키(함수 결과)로 수집된다. A·B 모두 맞다.
- ONLINE 인덱스 생성: 만드는 중인 인덱스의 키도 수집된다. 추가 의존뿐이다.
- 한 클래스 안에서 PK·UNIQUE가 B-tree를 함께 쓰는 경우: 같은 클래스라 A·B 모두 맞다.
- REBUILD, TRUNCATE, CHANGE/MODIFY, 파티션 재구성, ADD/DROP SUPERCLASS, DROP TABLE ONLY: B-tree가 새로 만들어질 수 있지만 statement 복제라 커밋 때 history를 비운다(`replication.c:610`). 이후 VFID 재사용은 추가 의존뿐이다.
- statement 로그를 남기지 않는 DDL(SQL 문이 없는 loaddb 경로, PK 없는 테이블 TRUNCATE, 지울 게 없는 DROP IF EXISTS): history가 남는다. VFID가 재사용돼도 A는 추가 의존뿐이다. B는 소유 클래스가 다르면 이를 갈라 주는데, B의 이점은 이것뿐이다.

### 클래스·인덱스·VFID의 관계

- 클래스 하나는 VFID 여러 개를 가진다: heap 파일 1개, 인덱스마다 B-tree 파일 1개, 큰 레코드가 있으면 overflow 파일.
- 인덱스는 보통 B-tree 파일 하나 = VFID 하나다. 예외는 B-tree 하나를 여럿이 함께 쓰는 경우 두 가지다.
  - 상속 계층: 상위·하위 클래스가 PK·UNIQUE B-tree 하나를 함께 쓴다(여러 클래스 : VFID 하나).
  - 한 클래스 안: 같은 컬럼의 PK·UNIQUE 등 제약 여럿이 B-tree 하나를 함께 쓸 수 있다(`class_object.c:8086~8093`).
- B-tree 하나가 VFID 여러 개를 갖는 경우는 없다.
- 따라서 VFID는 "어느 클래스"가 아니라 "어느 B-tree(uniqueness 범위)"를 나타내고, 두 예외도 실제로 같은 B-tree이므로 같은 해시로 묶는 것이 맞다.

### VFID 유일성

- 살아 있는 파일 사이에서는 유일하다. `fileid`가 파일이 예약한 섹터의 첫 페이지 번호이기 때문이다(`file_manager.c:3466`).
- 파일이 없어진 뒤에는 다시 쓰일 수 있다. 클래스 OID도 테이블을 지우고 다시 만들면 다시 쓰일 수 있으므로 지금 조합도 같은 수준의 보장이다.
- 다시 쓰여도 해시가 같아지는 방향이라 결과는 추가 의존뿐이고, 충돌을 놓치지 않는다.

## 결론 (제안)

A를 추천한다. 충돌의 정체(B-tree + 키)를 그대로 쓰고, 검토한 모든 문법에서 충돌을 놓치지 않는다. B는 같은 정체를 소유 클래스로 다시 표현한 것으로, 정의와 비용이 더 들고 이점은 안전한 쪽(추가 의존)을 줄이는 것뿐이다. 사용자 결정 대기.

## A로 갈 때 할 일

- 코드: `wset_fnv1a`에서 클래스 OID를 해시 입력에서 뺀다. trace에는 클래스 OID를 남긴다.
- 설계 문서 01 3.1 충돌 키: "class OID"를 빼고 이유(상속 계층의 공유 B-tree)와 VFID 유일성 범위를 적는다.
- 단위 테스트: 같은 VFID에 다른 클래스 OID로 넣은 같은 키가 같은 해시인지 확인. stress·bench에서 부모·자식이 같은 가상 VFID를 쓰는 곳(`test_writeset_stress.cpp:539~541`, `test_writeset_bench.cpp:185~235`)은 자식에 다른 VFID를 준다.
- HA 시험: 상속 PK 삭제 뒤 삽입(양방향), 상위 클래스 PK를 참조하는 FK에서 부모 행이 하위 클래스에 있는 경우, REPLACE와 ON DUPLICATE KEY UPDATE가 상위·하위 클래스에 걸치는 경우.

## 아직 확인하지 못한 것 (A에서는 모두 안전한 쪽)

- ADD SUPERCLASS 때 하위 클래스의 기존 행이 상위 클래스 B-tree로 옮겨지는지
- DROP TABLE ONLY로 상위 클래스만 지웠을 때 공유 인덱스가 어떻게 되는지
- unique 함수 인덱스가 허용되는지
- loaddb(CS 모드) 뒤 VFID가 재사용되는 경우
- FK가 하위 클래스 PK를 참조할 수 있는지(B라면 REF 쪽 소유 클래스 정규화가 필요)

## 진행 상태

- 2026-10-29: 방안 A 채택. 코드 커밋 `0ab0a6173`(`wset_fnv1a`·`wset_string_hash`·`wset_midxkey_hash`에서 class OID 제거, 주석에 이유와 예시). 단위 테스트 추가(같은 VFID에 class OID만 다른 같은 키 → 같은 해시, REF 일치, 다른 VFID는 다름, sup 삭제 뒤 sub 삽입 의존) 및 stress·bench의 자식 키를 `WS_CHILD_VFID`로 분리 — 미커밋. 설계 문서 01 3.1 갱신. 남은 것: 빌드 후 단위 테스트, HA 재시험(11번 문서의 01 대조군, 조합 C3).
- HA 근거: 11번 문서 01 대조군(관문 행 잠금으로 순서를 뒤집자 slave가 하위 클래스 삽입을 먼저 반영해 -670, 행 유실, fail_counter 0→1).
- 2026-10-30: 시험 세 가지를 모두 통과해 이 문제를 닫는다. 코드 `0ab0a6173`, 단위 테스트 `6c6fe71a8` 푸시.
  - HA 01 대조군 재시험(10-29 23:45, 빌드 2956): 관문 행 잠금으로 T1 반영을 막아도 T2의 dependency가 T1의 커밋 LSA여서 T2가 기다렸다. slave 오류 0, 데이터 일치.
  - 단위 테스트(10-30, 빌드 2969): `test_writeset` 47개 케이스, assertion 4728개 통과. 위에 적은 상속 테스트가 들어 있다.
  - 조합 C3(10-30 17:15, 빌드 2969): 상위 클래스 PK를 참조하는 FK에서 부모 행이 하위 클래스에 있는 경우다. T1이 자식 행을 지우고(`delete from pc_c3_ch where c=1`), T2가 하위 클래스의 부모 행을 지운다(`delete from pc_c3_sub where p=1`). slave에서 관문 행을 25초 잡아 T1 반영을 막았다. master trace에서 T2는 `source=REF_SLOT dependency=225|4240`으로, T1이 자식 삭제 때 남긴 부모 키 참조를 찾아 T1의 커밋(`commit_lsa=225|4240`)을 기다렸다. slave 오류 0, fail_counter 0→0, 결과는 master와 slave 모두 상위 클래스 0행·자식 0행으로 같다. 클래스 OID를 해시에서 뺀 것이 WRITE뿐 아니라 FK의 REF 키에도 적용된다는 확인이다. 스크립트 `ha_bench_tool/bin/cases/pair_c3_20261030.sh`, 기록 `ha_bench_tool/log/pair_order_20261030_1715_c3`.
