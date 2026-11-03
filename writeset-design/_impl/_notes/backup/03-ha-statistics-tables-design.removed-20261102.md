# HA 복제 통계 설계

| 항목 | 내용 |
|---|---|
| 상태 | 구현(2026-10-24), HA 미검증. 커밋 `519a02283`~`d4ae2ddd5` (7절) |
| 코드 기준 | `feature/CBRD-27508-on-26779` `d4ae2ddd5` |
| 참고 자료 | [근거와 참고 자료](./_notes/03-ha-statistics-tables-design-근거.md) (컬럼별 출처 trace, 코드 근거, 비용 추정) |

## 1. 목적

writeset 생성과 병렬 적용의 상태는 지금 `[WSET]` trace 로그로만 남는다. 이 중 운영 판단에 필요한 것을 누적 카운터로 센다. master `cub_server`의 writeset 통계와 applier의 병렬 적용 통계는 각각 따로 둔다.

- master 통계는 서버 메모리에만 두고 `SHOW WRITESET STATUS`로 조회한다. writeset history처럼 서버를 내리면 사라지는 값이라 디스크에 남기지 않는다. 기존 CUBRID가 서버 상태를 보여주는 방식(`SHOW PAGE BUFFER STATUS` 등)과 같다.
- slave 통계는 applier(클라이언트)가 `_db_ha_apply_info`처럼 카탈로그 테이블에 SQL로 쓴다.

## 2. 항목

카운터는 모두 시작 시각 이후의 누적값이다.

### 2.1 `SHOW WRITESET STATUS` (master `cub_server`, 한 행)

| 컬럼 | 뜻 |
|---|---|
| `Start_time` | 카운터를 세기 시작한 시각(서버 기동) |
| `History_size` | writeset history 크기 설정값 |
| `History_entry_count` | 지금 history에 든 키 수. `History_size`로 나눈 값이 차지 비율이다. 가득 차면 history를 비우고, 그 순간 뒤 커밋들이 비운 지점까지 기다리게 되어 병렬도가 떨어진다 |
| `Commit_count`, `Commit_fallback_count` | 라벨을 단 커밋 수, 그중 commit order로 떨어진 수 (병렬도를 잃은 비율) |
| `Fallback_key_limit_count`, `Fallback_statement_count` | commit order로 떨어진 이유별 횟수: 트랜잭션 키 수 상한 초과 / statement 복제·serial 키를 못 모음 |
| `Conflict_ref_count`, `Conflict_write_count` | history에서 자기 키와 충돌하는 커밋을 찾아 의존을 단 커밋 수: 그 키를 참조(REF)한 커밋 / 그 키를 쓴(WRITE) 커밋. history 하한만 의존으로 받은 커밋은 세지 않는다 |
| `Clear_capacity_count` | history가 가득 차서 비운 횟수 |

SHOW 문을 실행하는 순간 서버 메모리 값으로 행을 만든다. DBA만 실행할 수 있다. failover로 standby가 되어도 서버 프로세스가 살아 있는 동안은 값이 남아 조회된다. 서버를 내리면 사라진다.

slave의 두 테이블은 시스템 카탈로그다.

### 2.2 `_db_ha_apply_stat` (slave applier, applier마다 한 행)

| 컬럼 | 뜻 |
|---|---|
| `db_name`, `copied_log_path` | 어느 applier인지 (`_db_ha_apply_info`와 같은 기준) |
| `start_time`, `last_update_time` | applier 기동 시각, 마지막 갱신 시각 |
| `worker_count` | worker 수 |
| `apply_state` | applier 상태(`recovering`, `working`, `done` 등). DONE을 보류 중이면 `holding done` |
| `done_hold_since` | DONE 보류를 시작한 시각 (보류 중이 아니면 NULL) |
| `commit_read_count` | 읽은 커밋 수 (항목 있는 것). 작업량 |
| `dispatch_direct_count`, `dispatch_parked_count` | 항목 있는 커밋을 worker에 넘긴 방식별 수: 읽자마자 / 의존 때문에 먼저 보류. 의존 대기 비율. serial 조각은 세지 않는다 |
| `inflight_count`, `pending_count` | 지금 worker에 넘겨 처리 중인 작업 수, 의존 때문에 기다리는 작업 수 |

insert·update·delete·schema·commit·fail 카운터와 진행 위치(committed·final LSA, 로그 시각)는 `_db_ha_apply_info`에 이미 있으므로 두지 않는다.

### 2.3 `_db_ha_apply_worker_stat` (slave applier, worker마다 한 행)

| 컬럼 | 뜻 |
|---|---|
| `db_name`, `copied_log_path`, `worker_idx` | 어느 applier의 몇 번 worker인지. `worker_idx`는 0부터 |
| `start_time`, `last_update_time` | 세기 시작한 시각, 마지막 갱신 시각 |
| `state` | `applying`(적용 중) / `idle`(대기) |
| `applied_task_count`, `applied_row_count` | 적용한 작업(커밋, serial 조각) 수, 적용한 행 수(insert·update·delete·schema). 작업량. 항목 없는 커밋은 세지 않는다 |
| `busy_usec` | 적용에 쓴 시간 누적(flush, commit 포함). 작업률 |
| `applying_commit_lsa_pageid`, `applying_commit_lsa_offset`, `applying_master_commit_time`, `applying_since` | 지금 적용 중인 트랜잭션의 master 커밋 위치, master 커밋 시각, 적용을 시작한 시각. 대기 중이면 NULL |
| `last_applied_commit_lsa_pageid`, `last_applied_commit_lsa_offset`, `last_applied_master_commit_time`, `last_applied_time` | 마지막으로 적용을 끝낸 커밋의 master 커밋 위치, master 커밋 시각, 적용을 끝낸 시각. serial 조각은 반영하지 않는다 |
| `last_error_code`, `last_error_time` | 마지막 항목 적용 오류 코드와 시각. 오류가 없었으면 NULL |

처리율은 두 시점의 누적값 차이를 `last_update_time` 차이로 나눠 구한다. 지금·마지막 커밋은 MySQL `replication_applier_status_by_worker`의 `APPLYING_TRANSACTION`, `LAST_APPLIED_TRANSACTION`에 해당하며, 트랜잭션은 GTID 대신 master 커밋 위치(commit LSA)로 표시한다. LSA는 `_db_ha_apply_info`처럼 pageid와 offset 두 컬럼에 나눠 담는다. 행은 갱신 시점의 상태다.

### 2.4 통계로 두지 않는 것

디버그, 추적, 기능 비용에 해당하는 값은 지금처럼 `[WSET]` trace로 남긴다. 예: serial sysop 장벽 횟수, history 하한 올림, 메모리 부족·대체로 인한 history 비움, WRITE/REF 키 등록 수, 항목 없는 커밋, 라벨 없는 커밋, serial 조각, 라벨 낮춤·읽기 실패, recovery range 처리, required_lsa 보류.

## 3. 쓰는 주체와 시점

### 3.1 master `cub_server`

1. 카운터는 커밋 경로에서 원자적 덧셈으로 센다. 디스크에 쓰지 않는다.
2. `History_entry_count`는 history 공유 잠금을 잡고 읽는다. history를 통째로 비우는 동작(배타 잠금)과 겹치지 않게 하기 위해서다.

### 3.2 slave applier → `_db_ha_apply_stat`, `_db_ha_apply_worker_stat`

1. 두 테이블의 갱신은 `_db_ha_apply_info`를 저장하는 트랜잭션에 함께 넣어야 한다. 커밋이 늘지 않으므로 상호 HA 쌍에서 빈 트랜잭션이 더 생기지 않는다.
2. worker는 자기 값을 작업 결과에 담아 보내고, coordinator가 retire할 때 더해야 한다. worker가 공유 카운터를 직접 고치지 않는다. 지금 적용 중인 작업만 worker가 자기 칸에 직접 적는다.
3. worker 행은 값이 바뀔 때만 갱신한다(retire한 작업이 늘었거나, 작업을 시작·종료함). 그래서 worker 행의 `last_update_time`은 그 행의 값을 마지막으로 저장한 시각이다.
4. 두 테이블은 `_db_ha_apply_info`와 달리 MVCC를 끄지 않는다. SQL로 갱신하는 일반 테이블이다.
5. 테이블이 없거나 통계 갱신이 실패해도 applier는 멈추지 않는다. 실패는 에러 로그에 한 번만 남긴다.
6. 통계 갱신은 `_db_ha_apply_info` 갱신을 막거나 되돌리면 안 된다. 그래서 통계 문장은 잠금·페이지 latch 대기를 최대 100ms로 두고, `_db_ha_apply_info` 갱신 뒤에 savepoint를 찍어 통계가 실패하면 savepoint까지만 되돌린다. 다른 세션이 통계 행을 잠가도 coordinator는 100ms 넘게 기다리지 않는다. 실패한 통계는 다음 저장 때 누적값으로 다시 쓴다. 대기를 0으로 두면 vacuum이 통계 테이블 heap 페이지를 잠깐 잡을 때마다 실패하고 에러 로그(-76)가 남아서 100ms로 정했다(10-24 campaign).

## 4. 규칙

1. 카운터는 서버와 applier 모두 기동할 때 0부터 센다. 테이블에 저장된 이전 값을 읽어 이어서 세지 않는다. 키·시각·설정 컬럼은 대상이 아니다.
2. applier는 기동할 때 자기(`db_name`, `copied_log_path`)의 worker 행을 모두 지우고, 지금 worker 수만큼 새로 넣어야 한다. worker 수를 줄여 다시 띄웠을 때 지난 실행의 worker 행이 남으면, 없는 worker가 일을 받지 못하는 worker처럼 보이기 때문이다.
3. `_db_ha_apply_info`의 기존 카운터는 develop 동작대로 이어서 센다. 위 규칙과 관계없다.

## 5. 조회

### 5.1 SQL

```sql
SHOW WRITESET STATUS;                                       -- master 노드에서
SELECT * FROM _db_ha_apply_stat;                            -- slave 노드에서
SELECT worker_idx, applied_task_count, applied_row_count, busy_usec, last_update_time
  FROM _db_ha_apply_worker_stat ORDER BY worker_idx;
```

master의 writeset 통계는 SHOW 문으로만 조회한다. `statdump`에는 붙이지 않는다.

### 5.2 `cubrid applyinfo`

1. `-a`일 때 Applied Info 다음에 "Parallel Apply Info" 구역을 출력해야 한다.
2. 기본 출력은 applier 요약이다: 시작 시각, 상태, worker 수, 읽은 커밋 수, 바로 넘긴 작업 수, 의존 보류 작업 수와 비율, 처리 중·대기 작업 수.
3. `-v`면 DONE 보류 시작 시각, 마지막 갱신 시각과 worker별 줄(번호, 상태, 작업 수, 행 수, 적용 시간(ms), 적용 중 LSA, 마지막 적용 LSA와 시각, 마지막 오류)을 함께 출력해야 한다.
4. 통계 테이블이나 행이 없어도 `applyinfo`가 실패하면 안 된다. 없다는 줄만 출력한다.

```text
 *** Parallel Apply Info. ***
Start time                     : 05:23:41.000 PM 10/23/2026
Apply state                    : working
Worker count                   : 10
Commits read                   : 244657
Dispatched directly            : 231004
Parked by dependency           : 13653 (5.6%)
In flight / pending            : 12 / 3
```

## 6. master를 테이블에서 SHOW 문으로 바꾼 이유

처음에는 master도 `_db_ha_writeset_stat` 테이블에 1초마다 쓰게 구현했다(`519a02283`, `6af8020ee`, `4ebd5632c`). 서버는 SQL을 실행할 수 없어서, serial처럼 heap 페이지를 직접 고쳤다. 그러려면 테이블을 MVCC를 끈 클래스로 OID 캐시에 등록하고, 주기 스레드와 시스템 연산이 필요했다. 리뷰에서 이 경로의 결함(DB에 없는 클래스의 OID 캐시, 스레드 등록 누락, 기억해 둔 행 위치)이 나왔다. 값이 서버를 내리면 0부터 다시 세는 값이라 디스크에 남길 이유가 없어, 기존 CUBRID 방식인 SHOW 문으로 바꿨다(`9d8ff25a5`, `c9741f335`).

## 7. 구현 커밋

| 커밋 | 내용 |
|---|---|
| `519a02283` | 파라미터 `ha_writeset_stat_interval_in_secs` |
| `6af8020ee` | 카탈로그 테이블 3개, `_db_ha_writeset_stat` 행 생성, MVCC 끔 |
| `4ebd5632c` | master: 카운터, daemon, 제자리 갱신, 종료 시 갱신 |
| `c126de5d2` | slave: worker 결과에 값 추가, 기동 시 행 교체, apply info 저장 때 갱신 |
| `b9017d946` | `applyinfo -a` "Parallel Apply Info" 구역 |
| `2bfe5a0e0` | 리뷰 결함: DB에 없는 클래스의 OID 캐시 칸이 앞 클래스(`_db_histogram`) OID를 받던 것 |
| `c8485457d` | 리뷰 결함: `ha-writeset-stat` daemon 등록 누락 |
| `1e3c71953` | 리뷰 결함: 바로/보류 작업 수를 커밋만 세고, serial 조각이 마지막 적용 커밋을 덮지 않게 함 |
| `9d8ff25a5` | master: `_db_ha_writeset_stat` 테이블, OID 캐시 항목, daemon, 파라미터 제거(위 2bfe5a0e0, c8485457d, 519a02283 되돌림). 카운터는 유지 |
| `c9741f335` | master: `SHOW WRITESET STATUS` (비예약 키워드 `WRITESET` 추가) |
| `a4706d3fe` | slave: 통계 문장 잠금 대기 0 + savepoint. 통계가 `_db_ha_apply_info` 저장을 막거나 되돌리지 않게 함 |
| `96dc2388f` | master: lexer에 `WRITESET` 규칙 추가 (빠져서 SHOW 문이 문법 오류였음) |
| `d4ae2ddd5` | slave: 통계 문장 대기 0 → 100ms (vacuum의 heap 페이지 latch와 충돌해 -76 에러 로그) |

남은 것:
- HA 검증(`SHOW WRITESET STATUS` 값, slave 행 갱신, worker 수를 줄여 재기동, failover, applyinfo 출력).
- 시스템 메타데이터 버전(`system_metadata_version.h`)은 올리지 않았다. slave 카탈로그 테이블 2개가 늘었으므로 배포 때 올리고 `cubrid upgradedb` 경로를 정해야 한다.
