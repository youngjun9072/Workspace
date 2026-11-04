# C17. 재시작 recovery range에서 이미 적용한 statement(DDL)를 다시 실행해 실패로 기록

## 1. 메타
| 항목 | 내용 |
|---|---|
| 등급 | High |
| 상태 | open: 관측, 원인 분석, HA 재현 완료(10-21, 12절). 수정 커밋 `74acb3ea8`(7절 설계, 적용 표시 테이블). HA 검증 통과(14절) |
| 판정 | 관측 확정(10-20 23:56). 원인 코드 확정. **HA 재현 2/2(10-21 19:11, 19:12): DDL 재실행 실패와 함께, USE_SBR UPDATE가 오류 없이 다시 실행돼 slave 값이 master와 달라짐.** develop이라면 생기지 않았으리라는 부분은 추정 |
| 신규/기존 | 신규(develop 대비 회귀). 45825ca17(Slave-side parallel applylogdb)에서 항목별 replay 필터를 트랜잭션 단위 skip과 recovery range로 바꿈 |
| 관련 이슈 | C10(저장 주기 누락으로 recovery range가 넓어짐), C9(같은 필터 제거로 serial 재적용) |
| 발견 경위 | 리뷰 종합에는 없었다. C1 재현 시나리오 첫 실행 중 slave fail_counter가 0 → 1이 된 것을 추적해 찾았다 |

## 2. 문제 요약
slave applier가 재시작하면, 저장된 committed_lsa보다 뒤이고 직전 실행이 적용했을 수 있는 구간(recovery range)의 트랜잭션을 다시 적용한다. 이때 행(DML) 항목은 다시 적용해도 되도록 일부 오류를 넘기지만, statement 항목(DDL 등)은 아무 처리 없이 다시 실행된다. 이미 적용된 DDL은 "already exists" 같은 오류로 실패하고 fail_counter가 오른다. 다시 실행해도 결과가 같지 않은 statement DML이면 slave 데이터가 master와 달라질 수 있다.

## 3. 문제 분석

### 3.1 관측 (확정)
`ha_bench_tool/log/c1_restart_20261020_235534/`, youngjun4 `testdb@localhost_applylogdb_testdb_youngjun3.err`

| 시각 | 내용 |
|---|---|
| 23:55:35 | master `DROP TABLE IF EXISTS c1_t; CREATE TABLE c1_t (...)`. slave에서 trid 285661, commit 1824170\|11504를 worker 3이 적용, `error=0` |
| 23:55:36 | `cubrid service stop` (slave, 그다음 master) |
| 23:56:02 | slave applier 재기동 후 같은 커밋(1824170\|11504)의 `CREATE TABLE c1_t`를 다시 실행 → `Class dba.c1_t already exists`, server error -492, `[WSET] worker error trid=285661 ... error=-492 item_type=4` |
| 이후 | `db_ha_apply_info.fail_counter` = 1 (직전 0) |

### 3.2 브랜치 코드 (확정)
재시작 뒤 다시 읽은 트랜잭션은 커밋 LSA에 따라 셋으로 나뉜다.

| 구간 | 처리 | 위치 |
|---|---|---|
| commit_lsa ≤ `last_committed_lsa` (기동 시 `_db_ha_apply_info`에서 읽은 값) | 트랜잭션 전체 skip | `log_applier.c:6983` |
| `last_committed_lsa` < commit_lsa ≤ `recovery_boundary_lsa` (= 저장된 max_committed_lsa) | **다시 적용**. 트랜잭션 하나씩 직렬로 | `la_is_in_recovery_range`, `1024-1028`. 직렬 경로 `7378-7411` |
| 그 위 | 정상 병렬 적용 | |

- recovery range에서 넘기는 오류는 행 flush 오류 중 두 가지뿐이다(`log_applier.c:5970-5990`).
  - INSERT의 `ER_BTREE_UNIQUE_FAILED`
  - UPDATE/DELETE의 `ER_OBJ_OBJECT_NOT_FOUND`, `ER_HEAP_UNKNOWN_OBJECT`
- statement 항목(`la_apply_statement_log`)의 오류는 그대로 실패로 기록된다. 코드 주석에도 미해결로 남아 있다(`6962-6964`).
  ```c
   *   Row items are PK-based and tolerate re-apply; a statement item may not.
   *   TODO: handle statement re-apply in the restart recovery range (errors, non-idempotent statement DML).
  ```

### 3.3 develop 코드 (확정)
- 항목마다 `item->lsa > last_committed_rep_lsa`일 때만 적용한다(develop `log_applier.c:5799`). 이 조건이 DML(`LOG_REPLICATION_DATA`)과 statement(`LOG_REPLICATION_STATEMENT`)를 함께 감싼다.
  ```c
  if (LSA_GT (&item->lsa, &la_Info.last_committed_rep_lsa) && la_need_filter_out (item) == false)
    {
      if (item->log_type == LOG_REPLICATION_DATA) { ... }
      else if (item->log_type == LOG_REPLICATION_STATEMENT) { error = la_apply_statement_log (item); }
      ...
      if (error == NO_ERROR) LSA_COPY (&la_Info.committed_rep_lsa, &item->lsa);
  ```
- 이미 적용한 항목은 **다시 실행하지 않는다.** 그래서 오류를 넘기는 처리가 필요 없다.
- `last_committed_rep_lsa`는 기동 시 `_db_ha_apply_info`에서 읽은 값이다. 이 값은 `la_check_time_commit`이 `ha_applylogdb_max_commit_interval_in_msecs`(기본 500ms)마다 `la_log_commit`으로 저장한다(develop `6744-6783`).

### 3.4 이번에 recovery range에 들어간 이유
- 브랜치에서는 `la_Info.total_rows`가 갱신되지 않는다(C10). worker는 지역 변수에만 더한다(`log_applier.c:1312-1321`). 그래서 `la_check_time_commit`의 `prev_total_rows != total_rows` 조건이 항상 거짓이고, 주기 저장이 일어나지 않는다(`8267`).
- 그 결과 저장된 committed_lsa가 DDL(1824170\|11504)보다 앞에 머물렀다. 반면 max_committed_lsa는 dispatch 전에 저장된다(`la_coordinator_cover_commit`, `764-807`). 그래서 이 DDL은 recovery range 안에 들어갔다.
- develop이라면 DDL 적용 뒤 500ms 안에 저장되어, 1초 뒤 정지에서는 건너뛰었을 가능성이 높다(추정). 정지가 500ms 안에 오면 develop에서도 같은 일이 생길 수 있다.

## 4. 발생 조건과 재현 방법
### 4.1 발생 조건
1. slave가 statement 항목(DDL, 또는 statement로 복제되는 DML)을 적용했다.
2. 그 커밋이 저장된 committed_lsa보다 뒤인 채로 applier가 재시작했다. 정지, kill, HA 재시작, failover가 모두 해당한다. 지금은 C10 때문에 저장이 거의 일어나지 않으므로 사실상 항상 해당한다.
3. 같은 statement를 다시 실행하면 실패하거나 결과가 달라진다.

### 4.2 재현 방법 (HA)
1. master에서 `CREATE TABLE c17_t (id INT PRIMARY KEY)`를 실행하고, slave에 반영된 것을 확인한다.
2. 곧바로 slave applier를 재시작한다. 방법은 `cubrid heartbeat applylogdb stop/start testdb youngjun3`, 또는 HA 재시작이다.
3. slave applier 로그에서 `already exists`(-492)를 찾고, `fail_counter` 증가를 확인한다.
- 위험이 큰 변형: `ALTER TABLE ... ADD COLUMN`(재실행 시 오류), statement 복제 DML(예: 서버 함수가 들어간 UPDATE)이 다시 실행되는지 본다.

## 5. 기대 결과
- 재시작 전에 적용한 statement는 재시작 뒤 다시 실행되지 않는다.
- fail_counter는 실제 적용 실패에만 오른다.

## 6. 실제 결과 / 예상 에러
- DDL을 다시 실행하면 실패하고 fail_counter가 오른다. 관측된 예는 `-492 Class ... already exists`(10-20), `-245`(ALTER ADD COLUMN), `-272`(CREATE INDEX)(10-21, 12절)이다.
- 예상되는 다른 실패: `DROP TABLE` 재실행 → 대상 없음 오류.
- **statement로 복제된 DML(`USE_SBR` 힌트)은 다시 실행해도 오류 없이 성공해서, slave 데이터가 조용히 master와 달라진다.** 10-21에 재현했다(12절, slave n=2 / master n=1). 어떤 문장이 해당하는지는 7.1절 예시로 정리했다.
- 운영 영향: fail_counter를 감시하는 운영자는 재시작할 때마다 원인 모를 실패를 보게 되고, USE_SBR DML이 있으면 감시로도 잡히지 않는 불일치가 남는다.

## 7. 해결 설계: 적용 표시 테이블(스킵 테이블)

### 7.1 왜 statement만 따로 막아야 하는가: 행 복제와 문장 복제의 차이
recovery range는 "직전 실행이 적용했을 수도 있는" 트랜잭션을 다시 적용하는 구간이다. 이 방식은 **다시 적용해도 결과가 같다**는 전제 위에 있다.

**행(DML) 복제는 이 전제를 만족한다.** 복제되는 것이 "실행한 문장"이 아니라 "결과 행"이기 때문이다.

| master에서 실행 | 복제되는 것 | 두 번 적용하면 |
|---|---|---|
| `UPDATE account SET balance = balance + 100 WHERE id = 1` | "id=1 행은 balance=1100" | 1100을 두 번 씀 → 1100 (같음) |
| `INSERT INTO t VALUES (7, 'a')` | "PK 7 행 (7, 'a')" | 두 번째는 중복 키 오류 → recovery range에서 넘김 |
| `DELETE FROM queue WHERE id = (SELECT MIN(id) FROM queue)` | "PK 1 행 삭제" | 두 번째는 대상 없음 오류 → 넘김. id=2는 건드리지 않음 |

recovery range는 구간의 트랜잭션을 커밋 순서대로 모두 다시 적용하므로, 중간에 옛 값이 잠깐 보여도 뒤 트랜잭션이 다시 덮어써서 최종 상태가 맞는다. 예외로 C9(serial 조각이 구간 밖에서 다시 적용됨)가 있고, 별도 이슈로 다룬다.

**문장(statement) 복제는 이 전제를 만족하지 않는다.** 복제되는 것이 문장 자체라서, slave는 문장을 다시 실행한다. 실행 가능한 문장이면 두 번 모두 성공하고, 현재 값에 따라 결과가 달라진다. 다음은 두 번 실행하면 안 되는 예시다. 모두 **오류 없이 성공**한다.

**예 1. 누적 증가 (10-21 재현, 12절)**
```sql
UPDATE /*+ USE_SBR */ account SET balance = balance + 100 WHERE id = 1;
```
- master: 1000 → 1100
- slave에서 두 번 실행: 1000 → 1100 → **1200**

**예 2. 현재 값에 따라 대상이 바뀌는 DELETE**
```sql
DELETE /*+ USE_SBR */ FROM queue WHERE id = (SELECT MIN(id) FROM queue);
```
- master: 가장 오래된 행(id=1) 하나 삭제
- slave에서 두 번 실행: id=1 삭제 후 **id=2까지 삭제**

**예 3. 조건 대상이 바뀌는 UPDATE**
```sql
UPDATE /*+ USE_SBR */ orders SET status = 'SHIPPED', ship_seq = ship_seq + 1 WHERE status = 'READY' LIMIT 10;
```
- master: READY 10건을 처리
- slave에서 두 번 실행: 처음 10건은 이미 SHIPPED라 **다른 READY 10건이 또 처리됨**

**예 4. PK 없는 INSERT ... SELECT**
```sql
INSERT /*+ USE_SBR */ INTO log_archive SELECT * FROM log WHERE created < '2026-10-01';
```
- `log_archive`에 PK나 unique가 없으면 두 번째 실행도 성공해서 **같은 행이 두 벌**이 된다.

**예 5. 시간이나 시퀀스를 쓰는 문장**
```sql
UPDATE /*+ USE_SBR */ t SET updated_at = SYS_DATETIME, ver = ver + 1 WHERE id = 7;
```
- 두 번째 실행에서 ver가 한 번 더 늘고, 시각도 slave가 다시 실행한 시점으로 바뀐다.

`UPDATE t SET status = 'X' WHERE id = 7`처럼 값을 고정으로 넣는 문장은 다시 실행해도 같다. 하지만 applier는 문장이 어느 쪽인지 구분할 수 없다. 그래서 **statement는 "적용한 것은 다시 실행하지 않는다"로만 막을 수 있다.**

### 7.2 왜 에러 스킵으로는 안 되는가
행 복제의 recovery range는 다시 적용할 때 나는 오류(중복 키, 대상 없음)를 넘겨서 해결한다. statement에 같은 방식을 쓰면 다음과 같다.

| 다시 실행된 문장 | 결과 | 에러 스킵으로 |
|---|---|---|
| `ALTER TABLE ... ADD COLUMN`, `CREATE INDEX`, `CREATE TABLE` | 오류(이미 있음) | 넘길 수 있음 |
| 7.1절 예 1~5 | **오류 없이 성공** | **막을 수 없음.** 넘길 오류가 없음 |

- 에러 스킵은 "다시 실행하면 실패한다"는 전제에서만 동작한다. 예 1~5는 그 전제가 없다.
- DDL 오류만 넘기는 것도 "slave가 이미 어긋나 있어서 테이블이 있는" 진짜 문제까지 숨긴다.

### 7.3 왜 표시를 별도 테이블에, 데이터 반영 트랜잭션 안에서 남기는가
"적용한 statement는 다시 실행하지 않는다"를 하려면, 재시작한 applier가 "이 statement는 이미 적용됐다"를 알 수 있어야 한다. 그 표시를 어디에 언제 남기느냐에 따라 틈이 생긴다.

| 방법 | 표시가 남는 시점 | 틈 |
|---|---|---|
| apply info(`_db_ha_apply_info`)를 coordinator가 statement 직후 바로 저장 | worker 커밋 **뒤에** 따로 저장 | worker 커밋 ~ coordinator 저장 사이에 죽으면 다시 실행됨 (ms 단위) |
| worker가 apply info를 같은 트랜잭션에서 갱신 | 같은 커밋 | 없음. 하지만 coordinator가 주기 저장에서 옛 값으로 덮어쓸 수 있어 막는 장치가 따로 필요함 |
| **별도 표시 테이블을 worker가 같은 트랜잭션에서 갱신 (채택)** | 같은 커밋 | **없음.** coordinator는 이 테이블을 쓰지 않으므로 덮어쓰기 문제도 없음 |

데이터와 표시가 한 트랜잭션이라, 함께 커밋되거나 함께 롤백된다. "적용은 됐는데 표시는 없는" 상태가 생기지 않는다.

### 7.4 설계
**테이블**: slave 로컬 `ha_applied_stmt_marker (commit_pageid BIGINT, commit_offset INTEGER)`, **행 1개**. (PoC의 `ha_applied_tx_marker`와 구분하려고 이름을 바꿨다.)
- applier가 기동할 때 없으면 만든다(`CREATE TABLE IF NOT EXISTS`, 빈 테이블이면 행 하나를 넣음).
- applier 세션의 쓰기는 복제 로그를 만들지 않으므로(`log_manager.c:2298`, `!LOG_CHECK_LOG_APPLIER`) 상대 노드로 넘어가지 않는다. 기동 때의 CREATE도 같은지는 HA에서 확인한다.

**행 1개로 충분한 이유: statement 트랜잭션은 slave에서 양방향 장벽이다.**
- 앞쪽: master가 statement 트랜잭션에 직전 커밋을 라벨로 준다(commit-order 대체 경로). slave는 앞의 커밋이 모두 끝나야 실행한다.
- 뒤쪽: master는 statement 트랜잭션을 커밋할 때 history를 비우고 하한을 자기 커밋으로 올린다(`wset_clear_overflow_history`). 뒤의 커밋은 모두 이 트랜잭션을 기다린다.
- 그래서 statement 트랜잭션 S가 적용됐다는 것은 **S의 커밋 LSA까지 모든 커밋이 적용됐다**는 뜻이다. "마지막으로 적용한 statement의 커밋 LSA" 하나면 된다.

**동작**
1. worker: 트랜잭션에 statement 항목이 있으면, 커밋 직전에 같은 slave 트랜잭션에서 표시 행을 그 트랜잭션의 커밋 LSA로 UPDATE한다.
2. 기동: 표시 행을 읽어 `last_committed_lsa = max(apply info의 committed_lsa, 표시 LSA)`로 올린다. 그 이하의 커밋은 기존 skip 경로(`la_apply_repl_log`의 "already committed")가 트랜잭션 통째로 건너뛴다. recovery range도 그만큼 줄어든다.
3. failback 재구축(`la_delete_ha_apply_info`): apply info를 지울 때 표시 행도 비운다. 새 복제 흐름에 옛 LSA가 남지 않게 한다.
4. 정리(prune)는 필요 없다. 행이 늘지 않는다.

### 7.5 예 1에 적용하면
`UPDATE /*+ USE_SBR */ account SET balance = balance + 100 WHERE id = 1`, 커밋 LSA 100. 직전 apply info의 committed_lsa는 90이다.

| 시각 | slave worker / applier | 데이터 반영 트랜잭션 | 표시 테이블 | slave balance |
|---|---|---|---|---|
| t0 | UPDATE 문장 실행 | 진행 중 | 90 이하 값 | 1100 (미커밋) |
| t1 | 같은 트랜잭션에서 표시 행 = 100 | 진행 중 | 100 (미커밋) | 1100 (미커밋) |
| t2 | 커밋 | **함께 커밋** | **100** | **1100** |
| t3 | applier가 죽음 (apply info는 아직 90) | | 100 | 1100 |
| t4 | 재시작: `last_committed_lsa = max(90, 100) = 100` | | 100 | 1100 |
| t5 | 커밋 100을 다시 읽음 → 100 ≤ 100이라 **트랜잭션 통째로 skip** | | 100 | **1100 (master와 같음)** |

- t1~t2 사이에 죽으면 데이터와 표시가 함께 롤백된다. 재시작 뒤 한 번 실행되어 1100이 된다.
- 지금 코드(수정 전)는 t5에서 문장을 다시 실행해 1200이 된다(12절에서 관측한 것과 같음).
- 예 2~5도 같은 흐름이다. 표시가 남은 statement는 두 번째 실행 자체가 일어나지 않는다.

### 7.6 다른 안과 비교
| 안 | 판단 |
|---|---|
| 초판의 안 A: `last_committed_rep_lsa`로 statement 항목 거르기 | **안전하지 않음.** 병렬 적용에서는 적용하지 않은 statement를 건너뛸 수 있다(13.1절) |
| apply info를 statement 직후 바로 저장 | 틈이 남는다(7.3절) |
| 에러 스킵(화이트리스트) | 예 1~5를 막지 못한다(7.2절) |
| C10 복구(`total_rows` 주기 저장) | 재현 빈도만 줄인다. 이 환경에서는 저장이 이미 0.5~2초마다 일어나고 있었다(13.6절) |

### 7.7 범위 밖: DML(행)에도 표시를 넓히는 것
- 행 DML은 다시 적용해도 결과가 같아서(7.1절) 정확성 문제가 아니다. 넓히면 recovery range의 재적용과 그 구간의 에러 스킵이 없어지는 최적화가 된다.
- 9월 PoC(`5926f3840d`, 브랜치 `feature/parallel_applylogdb_writeset_hole_marker_drain`)가 모든 트랜잭션에 표시를 넣었다가 09-11 `a55821ea90`에서 뺐다. 이유는 "다시 적용해도 결국 같아진다"였는데, statement에는 맞지 않는다는 것이 이번에 드러났다.
- DML로 넓히려면 PoC에서 확인된 두 문제를 풀어야 한다. ① 표시 INSERT가 전역 `la_sql_compile_mutex`로 worker끼리 직렬화된다. ② 커밋마다 표시를 쓰면 상호 HA에서 빈 커밋이 오가는 핑퐁 조건과 맞물린다. 최적화 과제로 분리한다.

## 8. 의사코드
```c
/* la_apply_repl_log: note that the transaction carries a statement */
else if (item->log_type == LOG_REPLICATION_STATEMENT)
  {
    error = la_apply_statement_log (item, stats);
    stats->has_statement = true;
  }

/* la_apply_worker_run_task: after the items are flushed, before the commit, in the same slave transaction */
if (result->stats.has_statement)
  {
    result->error = la_update_applied_stmt_marker (&task->commit_lsa);   /* UPDATE the one row, no commit */
  }
result->error = la_apply_worker_commit_task (...);                     /* data and marker commit together */

/* la_apply_log_file, after la_get_last_ha_applied_info () and before the workers start */
la_create_applied_stmt_marker ();                                        /* CREATE TABLE IF NOT EXISTS + one row */
la_read_applied_stmt_marker (&marker_lsa);
if (LSA_GT (&marker_lsa, &la_Info.last_committed_lsa))
  {
    LSA_COPY (&la_Info.last_committed_lsa, &marker_lsa);               /* commits at or below are skipped whole */
  }

/* la_delete_ha_apply_info: in the same transaction as the apply-info delete */
la_update_applied_stmt_marker (NULL LSA);
```

## 9. 검증 방법
1. `ha_bench_tool/bin/c17_stmt_reapply.sh`(12절)를 수정 전과 후에 실행한다. 수정 후: DDL 재실행 오류 0, slave n = master n, fail_counter 증가 0. 재기동 상태에서 recovering 구간이 statement 커밋 뒤에서 시작하는지 본다.
2. 표시 테이블이 상대 노드(master)에 생기거나 복제되지 않는지 본다.
3. 회귀: C3/C11 조건 `c3_fk_gap`, fk_multi, 재시작 시험, F1/F4. fail_counter delta 0, compare 일치.

## 10. 영향 범위와 위험
- **영향**: DDL이나 USE_SBR DML을 쓰는 모든 운영에서, slave applier가 재시작할 때마다(정지, 장애, failover/failback) 생길 수 있다.
- **수정 비용**: statement 트랜잭션마다 표시 UPDATE 1회. statement는 드물고 어차피 장벽이라 다른 트랜잭션과 겹치지 않는다.
- **수정 위험**:
  - 표시는 반드시 데이터와 같은 트랜잭션 안에서, 커밋 전에 써야 한다. 따로 커밋하면 7.3절의 틈이 다시 생긴다.
  - 장벽 성질(7.4절)이 깨지면 행 1개 방식이 틀린다. 예를 들어 master가 statement 트랜잭션에 더 이른 라벨을 주거나 history 하한을 올리지 않게 바뀌는 경우다. 장벽 성질에 기대고 있다는 것을 코드 주석에 남긴다.
  - **10-25: 장벽 성질이 지금도 일부 깨져 있음을 실측으로 확인했다(15절).**
  - failback 재구축 때 표시를 비우지 않으면 새 복제 흐름의 커밋을 잘못 건너뛸 수 있다.

## 11. 열린 질문
1. ~~statement로 복제되는 DML은 언제 생기는가~~ → DDL 전부와 `USE_SBR` 힌트 DML(13.4절). 다시 실행하면 결과가 달라지는 사례는 7.1절.
2. develop에서도 500ms 저장 사이의 정지로 같은 일이 생기는지는 develop 빌드로 확인해야 한다(기존 결함 부분).
3. ~~C9와 해결을 묶을 수 있는가~~ → 원인은 같지만 고치는 방법이 달라 따로 한다(13.5절).
4. ~~applier가 기동 때 하는 표시 테이블 `CREATE`가 복제 로그를 만들지 않는지~~ → 10-22 확인: 복제되지 않음(14절).
5. 표시 테이블이 두 노드 모두에 사용자 테이블로 보인다. 각 노드의 applier(상대 로그를 적용하는 쪽 포함)가 기동 때 로컬에 만들기 때문이다. 사용자에게 보이는 테이블로 둘지, 시스템 카탈로그(`_db_*`)로 옮길지는 C7(카탈로그 마이그레이션)과 함께 정한다.

## 12. HA 재현 (10-21, 빌드 2778-cef2bb1)

### 12.1 방법 (`ha_bench_tool/bin/c17_stmt_reapply.sh`)
1. master에서 csql 한 세션으로 다음 다섯 문장을 1초 안에 실행한다. autocommit이라 문장마다 트랜잭션이 하나다.
   ```sql
   CREATE TABLE c17_t (id INT PRIMARY KEY, n INT);
   ALTER TABLE c17_t ADD COLUMN v VARCHAR(10);
   CREATE INDEX c17_t_n ON c17_t (n);
   INSERT INTO c17_t (id, n) VALUES (1, 0);
   UPDATE /*+ USE_SBR */ c17_t SET n = n + 1 WHERE id = 1;   -- 행이 아니라 문장으로 복제됨
   ```
2. slave에서 마지막 UPDATE가 적용되는 순간(n = 1을 0.1초 간격으로 확인) slave applylogdb를 `kill -9`한다. heartbeat가 다시 띄운다. failover는 하지 않는다.
3. 40초 뒤 slave 로그, fail_counter, 양쪽 n을 본다.

처음에는 `cubrid heartbeat applylogdb stop/start`로 시험했는데 재현되지 않았다. 정상 정지는 apply info를 먼저 저장해서 recovery range가 비었다(재기동 상태가 `unregistered → working`, recovering을 거치지 않음). 10-20 관측은 DDL 1초 뒤 `cubrid service stop`이었다.

### 12.2 결과
| 회차 | 재실행된 문장 (slave worker error) | fail_counter | n (master / slave) |
|---|---|---|---|
| 1 (19:11) | `ALTER ... ADD COLUMN` -245, `CREATE INDEX` -272 | 0 → 2 | 1 / **2** |
| 2 (19:12) | 같음 | 2 → 4 | 1 / **2** |

- 두 회차 모두 재기동 상태가 `unregistered → recovering → working`이었다. 다섯 문장 가운데 뒤의 넷이 recovery range에 들어갔다. `CREATE TABLE`은 다음 retire 때 저장(`la_coordinator_store_apply_info_at_interval`)된 범위 안이라 다시 실행되지 않았다.
- `INSERT`는 행 항목이라 다시 적용해도 unique 오류를 넘겨 문제가 없었다.
- **`UPDATE /*+ USE_SBR */`는 다시 실행됐고 오류가 없다.** slave의 n은 2, master는 1이다. 양쪽에 직접 접속해 확인했다. fail_counter에도 남지 않는 **무성 불일치**다.
- 결과 디렉터리: `ha_bench_tool/log/c17_stmt_reapply_20261021_19*`
- 시험 테이블 c17_t는 slave와 master가 다른 채로 남아 있다.

## 13. 수정 전 사전 확인 (10-21, 코드 `db599ab64`)

### 13.1 초판의 안 A(`last_committed_rep_lsa`로 statement 거르기)는 병렬 적용에서 안전하지 않다
- 브랜치의 `committed_rep_lsa`는 retire한 결과 중 가장 큰 항목 LSA다(`la_coordinator_add_result_stats`, `log_applier.c:1179`). 주석도 "재적용 판단에 쓰지 않는다"고 적고 있다(1172-1174행).
- 예: statement 트랜잭션 S(항목 LSA 100, 커밋 110)는 대체 경로 라벨로 앞의 커밋을 모두 기다리며 pending에 있다. 뒤의 트랜잭션 T(항목 LSA 105, 커밋 120)는 S와 충돌이 없어 먼저 적용·retire된다. 이때 저장되는 `committed_rep_lsa`는 105다. 여기서 slave가 죽으면 재시작 뒤 S의 항목(100)은 105 이하라 **건너뛰어지는데, S는 적용된 적이 없다.**
- develop은 직렬이라 항목 LSA 순서와 적용 순서가 같아서 이 기준이 맞았다.

### 13.2 다른 기준: statement 트랜잭션끼리는 커밋 순서대로 적용된다
- statement 트랜잭션은 master에서 대체 경로(commit-order) 라벨을 받는다. 라벨이 직전 커밋이라, slave에서는 앞의 커밋이 모두 끝나야 실행된다. 그래서 statement 트랜잭션끼리는 항상 커밋 순서대로 적용된다(C2 수정 뒤에는 재시작 직후도 같다).
- 따라서 "마지막으로 적용한 statement 트랜잭션의 커밋 LSA"를 **그 트랜잭션과 같은 slave 트랜잭션 안에서** 저장하면, 재시작 때 그 값 이하의 statement 트랜잭션은 적용된 것이 확실하다.
- 같은 트랜잭션 안에서 저장해야 하는 이유: worker가 statement를 커밋한 뒤 coordinator가 따로 저장하면, 그 사이에 죽을 때 다시 실행된다(develop의 500ms 틈과 같은 성질).

### 13.3 저장 주체: worker 연결에서 `_db_ha_apply_info`를 갱신할 수 있는가
- worker는 자기 연결에서 항목을 적용하고 직접 커밋한다(`la_apply_worker_run_task` → `la_apply_worker_commit_task`, 1310-1345행). coordinator의 쓰기는 `_db_ha_apply_info` 갱신 하나뿐이다(`la_coordinator_commit_apply_info`, 1537행).
- worker가 같은 행을 갱신하면, worker 트랜잭션이 커밋할 때까지 그 행에 X 잠금을 쥔다. 그동안 coordinator의 apply info 저장은 기다린다. coordinator가 worker를 기다리는 반대 방향 대기는 없어서 교착은 없을 것으로 본다(추정).
- 기존 열을 쓰면 coordinator 저장과 값이 섞인다. 예를 들어 coordinator가 더 작은 `committed_rep_lsa`로 덮어쓸 수 있다. 그래서 전용 열이 필요한데, 이것은 카탈로그 변경이라 C7(마이그레이션 없음)과 함께 정해야 한다.
- 9월 B2 설계(적용 트랜잭션에 완료 마커를 함께 넣어 재시작 때 건너뛰기)와 같은 방식이다. 그때 마커 INSERT가 전역 뮤텍스로 직렬화되는 문제를 찾았다(메모: project_writeset_abc_bench_design). statement는 드물어서 이 비용은 작을 것으로 본다(추정).

### 13.4 statement로 복제되는 DML
- DDL은 모두 statement로 복제된다(`is_stmt_based_repl_type`, `execute_statement.c:499`).
- DML은 `/*+ USE_SBR */` 힌트가 있을 때만 statement로 복제된다(같은 함수, PT_INSERT/DELETE/UPDATE). 12.2절의 무성 불일치가 이 경우다.
- 그 밖에 `TRUNCATE`(`truncate_need_repl_log`), `UPDATE STATISTICS`도 statement다.

### 13.5 C9와 함께 풀 수 있는가
- 원인은 같다(항목별 필터 제거, `45825ca17`). 하지만 고치는 방법은 다르다.
- C9의 serial 조각은 SYSOP_END가 `committed_lsa` 이하일 때다(`la_coordinator_process_sysop_end`의 else 분기). frontier 이하라 **적용이 확실하다.** 그러므로 그 분기에서 조각 항목을 바깥 트랜잭션 목록에서 떼어 버리고 label holder를 비우면 된다. 저장할 것이 없다.
- C17은 recovery range 안이라 적용 여부가 불확실하다. 그래서 13.2절의 기록이 필요하다.
- 같은 커밋으로 묶을 필요는 없다.

### 13.6 C10과의 관계 (수정)
- 3.4절은 주기 저장이 일어나지 않는다고 적었다. 하지만 retire할 때 주기 저장(`la_coordinator_store_apply_info_at_interval`, 1209행)이 따로 있다. 다음 결과가 retire될 때 500ms가 지났으면 저장한다.
- 그래서 부하가 이어지면 저장되고, **마지막 결과 뒤에 retire가 없으면(유휴) 저장되지 않는다.** 주 루프의 `la_check_time_commit`이 `total_rows`(C10) 때문에 동작하지 않아서, 유휴 상태를 메워 줄 저장이 없다. 12.2절에서 `CREATE TABLE`만 저장된 것이 이 동작이다(추정, 저장 시각 trace 없음).

측정(10-21 19:20, slave `_db_ha_apply_info`를 0.5초 간격 조회): 부하 중에는 committed LSA가 약 0.5초마다 저장됐고, 유휴 중에도 1~2초마다 저장됐다. 유휴 중 저장은 상대 노드 applier가 자기 apply info를 갱신하는 작은 커밋이 계속 복제되어 retire가 생기기 때문이다(추정, 커밋 출처는 확인하지 않음). 그래서 이 환경에서는 저장되지 않는 틈이 1~2초 안쪽이고, 12절 재현도 applier를 바로 kill해야 했다. 주기 저장이 빠진 C10의 실제 영향은 이 환경에서 작다.

## 14. 수정 검증 (10-21 23:45 ~ 10-22 00:06, 빌드 2779-74acb3e, DB 재생성 직후)
| 시험 | 결과 |
|---|---|
| 표시 테이블 생성 | 두 노드 모두 applier가 로컬에 만듦(초기 행 -1, -1). master에 statement 복제 trace(`mode=COMMIT_ORDER`) 0건 → 복제되지 않음 |
| **C17 재현 조건 2회** (`c17_stmt_reapply.sh`, 문장 적용 직후 applier kill) | **DDL 재실행 오류 0, slave n = master n = 1, fail_counter 0.** 수정 전에는 같은 조건 2회 모두 -245/-272 오류와 n=2(12.2절). 표시 행은 statement 커밋 LSA로 갱신됨(예: 176\|15680) |
| C3 회귀 (`c3_fk_gap`, FILLER 500, 2000라운드) | ok 2000, inverted 0, missed 0, fail_counter 0 |
| C11 회귀 (분할 부모, 500라운드) | ok 500, missed 0, fail_counter 0 |
| fk_multi (12분) | 테이블 20/20 같음, fail_counter delta 0, gate 순서 위반 0. 하니스 DDL로 slave 표시 행이 29283\|10192까지 갱신됨 |

## 15. 장벽 성질의 틈 (10-25 확인)
DDL 혼합 부하 분석(`ddl_mix_analyze.py`)에서 statement 트랜잭션이 양방향 장벽이 아닌 경우가 나왔다. 10-17 campaign에도 같은 수치가 있었는데 그때는 보지 못했다.

| 항목 | 10-17 (2768-cb0095b) | 10-24 (2797-a4706d3) |
|---|---|---|
| statement 커밋 수 | 830 | 887 |
| 앞쪽 틈: statement 라벨 < 로그상 바로 앞 커밋 | 7 | 11 |
| 뒤쪽 틈: statement 바로 뒤 커밋의 라벨 < statement | 9 | 9 |
| slave에서 statement와 다른 작업의 적용 구간이 실제로 겹침 | 10 | 12 |

- 예(10-24): statement `3145849|7432`의 라벨은 `3145807|5432`, 로그상 바로 앞 커밋은 `3145849|7184`. slave에서 둘이 동시에 적용됐다.
- 원인: master의 라벨 결정과 하한 올림이 커밋 기록 잠금(`prior_lsa_mutex`) 밖에서 따로 일어나, 그 사이에 다른 커밋이 끼어든다. 처음엔 코드 순서로 추정했고, 10-24 master trace에서 틈 10건(앞쪽 5, 뒤쪽 5)의 `DEPENDENCY`·`COMMIT`·`CLEAR` 줄 순서를 대조해 추정 그대로임을 확인했다(10-25). 앞쪽 틈은 모두 "S 라벨 결정 → 앞 커밋 A의 COMMIT → S의 COMMIT", 뒤쪽 틈 중 3건은 "S의 COMMIT → B 라벨 결정 → S의 하한 올림(CLEAR)" 순서였다. 줄 번호 표는 설계 문서 9.1.10.
- 이 이슈에 주는 영향(추정, 재현 안 함): 앞쪽 틈에서 statement S가 바로 앞 커밋 A보다 먼저 slave에 커밋되고 applier가 죽으면, 재시작 때 표시 행이 S의 위치까지 올라가 A를 통째로 건너뛴다. A의 변경이 slave에서 빠진다.
- 수정(10-25): master에서 라벨 결정과 하한 올림을 커밋·SYSOP_END 기록 잠금 안으로 옮겼다(`bf467ccd5`, `f58c10a17`). 장벽 성질이 다시 성립한다. 남은 것: 재빌드 뒤 DDL 혼합 부하로 틈 0 확인.
