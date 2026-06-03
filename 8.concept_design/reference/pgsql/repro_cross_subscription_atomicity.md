# 검증 시나리오: 구독을 가로지르는 트랜잭션의 원자성/순서 깨짐

> 작성 2026-06-02 · PostgreSQL 논리복제(다중 구독) 한계 재현
> 목적: tbl1·tbl2를 서로 다른 구독으로 분할했을 때, 두 테이블을 모두 쓰는 한 트랜잭션(Tx3)이
>       subscriber에서 **쪼개져 독립 적용**되어 원자성/순서가 깨짐을 **코드로 재현·관찰**한다.

## 핵심 아이디어

한쪽 구독을 `ALTER SUBSCRIPTION ... DISABLE`로 잠시 막으면, 그 구독으로 가는 변경만 적용이 멈춘다.
이 상태에서 두 테이블을 같이 바꾸는 원자적 트랜잭션을 publisher에서 실행하면, subscriber는
**한 테이블만 반영된 "반쪽 상태"** 가 된다 → 레이스에 의존하지 않고 **결정적으로** 깨짐을 관찰할 수 있다.

## 0. 사전 조건 / 토폴로지

- publisher DB(`pubdb`)와 subscriber DB(`subdb`). 같은 인스턴스의 두 DB여도 되고, 두 인스턴스여도 된다.
- publisher: `wal_level = logical` (postgresql.conf, **재시작 필요**), 복제 권한 role, `pg_hba.conf` 허용.
- publisher 기본값 `max_wal_senders`(기본 10), `max_replication_slots`(기본 10)면 구독 2개에 충분.
- subscriber: `max_logical_replication_workers`(기본 4)면 구독 2개에 충분.

## 1. 셋업 SQL

### publisher (`pubdb`)
```sql
CREATE TABLE tbl1 (id int PRIMARY KEY, name text);
CREATE TABLE tbl2 (id int PRIMARY KEY, tbl1_id int REFERENCES tbl1(id), amount int);

-- 테이블을 서로 다른 publication으로 분할 (구독 단위 병렬의 전제)
CREATE PUBLICATION pub_a FOR TABLE tbl1;
CREATE PUBLICATION pub_b FOR TABLE tbl2;
```

### subscriber (`subdb`)
```sql
-- publisher와 동일 스키마 (FK 포함 — 깨짐을 보여주기 위함)
CREATE TABLE tbl1 (id int PRIMARY KEY, name text);
CREATE TABLE tbl2 (id int PRIMARY KEY, tbl1_id int REFERENCES tbl1(id), amount int);

-- 같은 publisher에 구독 2개 (publication만 다르게) → 각자 leader apply worker
CREATE SUBSCRIPTION sub_a
  CONNECTION 'host=PUB_HOST port=5432 dbname=pubdb user=rep password=secret'
  PUBLICATION pub_a;
CREATE SUBSCRIPTION sub_b
  CONNECTION 'host=PUB_HOST port=5432 dbname=pubdb user=rep password=secret'
  PUBLICATION pub_b;
```

### (선택) 구독이 독립적으로 진행됨을 확인하는 모니터링
```sql
-- [subscriber] 두 구독의 수신 진도(LSN)가 따로 논다
SELECT subname, received_lsn, latest_end_lsn FROM pg_stat_subscription;

-- [publisher] 구독마다 별도 replication slot, confirmed_flush_lsn도 따로
SELECT slot_name, plugin, confirmed_flush_lsn FROM pg_replication_slots;
```
→ 두 구독이 **공유 commit-order 조정 없이 각자 진도를 갖는다**는 사실 자체가 깨짐의 근본 원인이다.

## 2. 시나리오 1 — 원자성 깨짐 (반쪽 적용)

```sql
-- [subscriber] tbl2 쪽 구독을 잠시 멈춘다
ALTER SUBSCRIPTION sub_b DISABLE;

-- [publisher] 하나의 원자적 트랜잭션으로 두 테이블에 기록 (= Tx3)
BEGIN;
  INSERT INTO tbl1 VALUES (1, 'acc-1');
  INSERT INTO tbl2 VALUES (100, 1, 500);
COMMIT;

-- [subscriber] 잠깐 기다린 뒤 관찰 (sub_a는 적용, sub_b는 멈춤)
SELECT (SELECT count(*) FROM tbl1 WHERE id  = 1)   AS tbl1_has,
       (SELECT count(*) FROM tbl2 WHERE id  = 100) AS tbl2_has;
```

**기대 결과**
```
 tbl1_has | tbl2_has
----------+----------
        1 |        0      ← publisher에선 원자적이었던 Tx3가 subscriber에선 "반만" 적용됨
```
→ **원자성 위반**: 한 트랜잭션이 subscriber에서 두 조각으로 갈려 한쪽만 보인다.

```sql
-- 복구
ALTER SUBSCRIPTION sub_b ENABLE;     -- 이후 tbl2_has = 1 로 따라잡음
```

## 3. 시나리오 2 — FK 순서 깨짐 (orphan), 그런데 에러도 안 난다

이번엔 **부모 테이블(tbl1) 쪽 구독을 멈춰** 자식(tbl2)이 먼저 오게 한다.

```sql
-- [subscriber] tbl1(부모) 쪽 구독을 멈춘다
ALTER SUBSCRIPTION sub_a DISABLE;

-- [publisher] 부모+자식을 한 트랜잭션으로 (= Tx3)
BEGIN;
  INSERT INTO tbl1 VALUES (2, 'acc-2');
  INSERT INTO tbl2 VALUES (200, 2, 700);   -- tbl2.tbl1_id = 2 (부모 참조)
COMMIT;

-- [subscriber] 관찰: 자식만 들어오고 부모는 없음
SELECT * FROM tbl2 WHERE id = 200;   -- 행 존재 (tbl1_id = 2)
SELECT * FROM tbl1 WHERE id = 2;     -- 행 없음!
```

**기대 결과**: tbl2에 `id=200, tbl1_id=2` 행이 **존재**하는데 tbl1에는 `id=2`가 **없다** = **orphan**.
그리고 **FK 위반 에러가 나지 않는다.** apply worker가 `session_replication_role = replica`로 동작해
FK(RI) 트리거가 발화하지 않기 때문이다 → **에러 없이 조용히 일관성이 깨지는** 위험 사례.

```sql
-- 확인: apply 세션의 replication_role
--   (참고) 일반 세션에서 SHOW session_replication_role; 는 'origin'이지만,
--   apply worker는 내부적으로 'replica'로 동작한다.

-- 복구
ALTER SUBSCRIPTION sub_a ENABLE;     -- 부모 도착 후 orphan 해소
```

## 4. 대조군(control) — 같은 구독이면 안 깨진다

분할하지 않고 **두 테이블을 한 publication/구독**에 두면, 단일 leader apply worker가
commit 순서대로 **원자적으로** 적용하므로 위 깨짐이 발생하지 않는다.

```sql
-- 위 sub_a/sub_b를 정리한 뒤
-- [publisher]
CREATE PUBLICATION pub_all FOR TABLE tbl1, tbl2;
-- [subscriber]
CREATE SUBSCRIPTION sub_all
  CONNECTION 'host=PUB_HOST port=5432 dbname=pubdb user=rep password=secret'
  PUBLICATION pub_all;

-- 이제 Tx3가 두 테이블을 써도 한 worker가 통째로 적용 →
--   반쪽 적용/orphan이 발생하지 않는다 (시나리오 1·2를 다시 돌려 비교).
```

→ 깨짐의 원인이 "두 테이블"이 아니라 **"두 테이블을 구독으로 쪼갠 것"** 임을 대조로 증명한다.

## 5. 검증 포인트 (무엇을 확인했나)

1. **시나리오 1**: 원자적 Tx3가 subscriber에서 `tbl1_has=1, tbl2_has=0`로 **반쪽 적용** → 구독 간 원자성 미보장.
2. **시나리오 2**: 자식만 먼저 적용되어 **orphan**, 그런데 **FK 에러 없음** → 구독 간 순서 미보장 + FK 미발화로 조용히 깨짐.
3. **대조군**: 같은 구독이면 위 둘 다 발생하지 않음 → 원인은 "구독 분할".
4. **모니터링**: 두 구독이 각자 slot·LSN으로 독립 진행 → 애초에 cross-subscription 순서 보장 장치가 없음.

## 6. 정리 / 해석

- PostgreSQL은 **한 구독 안에서는** commit 순서·원자성을 보장하지만, **구독을 가로질러서는 보장하지 않는다.**
- 따라서 **구독 단위 병렬화**(tbl1↔sub_a, tbl2↔sub_b로 나눠 Tx1∥Tx2 병렬)는 가능하지만,
  **트랜잭션이 구독 경계를 넘는 순간**(Tx3가 두 테이블) 원자성·순서가 깨진다.
- 실무 규칙: **트랜잭션 일관성이 필요한 테이블은 반드시 같은 publication/구독에 묶는다.** 그만큼 병렬도는 줄어든다.

## 7. 주의사항

- `DISABLE`된 구독의 slot은 publisher에서 WAL을 잡아두므로(slot이 진도를 보존), 테스트가 길어지면 WAL이 쌓인다. 끝나면 `ENABLE` 또는 구독 삭제로 정리.
- UPDATE/DELETE까지 시험하려면 대상 테이블에 적절한 `REPLICA IDENTITY`가 필요(여기 예시는 PK 있는 테이블이라 기본으로 충분).
- 같은 인스턴스의 두 DB 간 논리복제도 동작한다(연결 문자열의 `dbname`만 publisher DB로). 더 현실적으로 보려면 두 인스턴스 권장.
- 정리: `DROP SUBSCRIPTION sub_a; DROP SUBSCRIPTION sub_b;` (subscriber) → `DROP PUBLICATION pub_a; DROP PUBLICATION pub_b;` (publisher).
