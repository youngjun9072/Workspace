# HA 복제 통계 테이블 설계 — 근거와 참고 자료


이 파일은 [설계 문서](../03-ha-statistics-tables-design.md)를 줄이기 전 전문이다(2026-10-24). 컬럼별 출처 trace, 서버가 행을 직접 쓸 수 있다는 코드 근거, 기존 applyinfo 출력, 비용 추정을 참고용으로 보존한다.

| 항목 | 내용 |
|---|---|
| 상태 | 초안(2026-10-23). 미구현 |
| 코드 기준 | `feature/CBRD-27508-on-26779` `882308890` |
| 대상 | master `cub_server`의 writeset 생성, slave `applylogdb`의 병렬 적용 |

## 1. 목적

지금 writeset 생성과 병렬 적용의 상태는 `[WSET]` trace 로그로만 남는다. 처음 구현할 때 따로 통계를 두지 않고 trace로 대신했기 때문이다. trace는 `ha_writeset_trace_level`을 올려야 남고, 양이 많아 운영 중에 켜 두기 어렵고, SQL로 조회할 수 없다.

이 설계는 trace가 남기던 정보 중 운영 판단에 필요한 것을 누적 카운터로 바꾸어 DB 통계 테이블에 남긴다. 판단하려는 것은 다음 두 가지다.

- master: writeset이 병렬도를 얼마나 내주었는가. 얼마나 자주 commit order로 떨어졌고, 왜 떨어졌는가.
- slave: 실제로 얼마나 병렬로 적용했는가. 무엇 때문에 기다렸고, worker마다 일이 고르게 나뉘었는가.

## 2. 결정 사항 (2026-10-23)

1. 통계는 별도 테이블에 남긴다. `_db_ha_apply_info`에 컬럼을 더하지 않는다.
2. master `cub_server`의 writeset 통계와 applier의 병렬 적용 통계는 각각 따로 남긴다.
3. 이력을 쌓지 않고 행을 제자리에서 갱신한다.
4. worker별 처리율은 누적값과 갱신 시각을 함께 갱신해서 남긴다. 처리율은 두 시점의 차이로 계산한다.
5. 항목은 지금 남기고 있는 `[WSET]` trace에서 가져온다(4절).
6. master 통계 행 갱신 주기는 기본 1초로 하고 파라미터로 바꿀 수 있게 한다(5.1절).
7. 카운터는 서버와 applier 모두 기동할 때 0부터 센다. 각 행의 카운터는 그 행의 시작 시각(`server_start_time`, `start_time`) 이후의 값이다. 키·시각·설정 컬럼은 0으로 되돌리는 대상이 아니다.
8. applier 통계는 `cubrid applyinfo` 출력에도 붙인다. master의 writeset 통계는 SQL로 조회하고, `statdump`에는 붙이지 않는다(6절).

## 3. 테이블 구성

세 테이블 모두 시스템 카탈로그로 둔다. 이름은 가칭이다.

| 테이블 | 쓰는 주체 | 행 | 갱신 시점 |
|---|---|---|---|
| `_db_ha_writeset_stat` | master `cub_server` | 노드 DB마다 한 행 | 서버가 active일 때 갱신 주기(기본 1초)마다, 서버를 내릴 때 |
| `_db_ha_apply_stat` | slave `applylogdb` coordinator | applier마다 한 행 (`db_name`, `copied_log_path`) | `_db_ha_apply_info`를 저장할 때 같은 트랜잭션에서 |
| `_db_ha_apply_worker_stat` | slave `applylogdb` coordinator | applier의 worker마다 한 행 (`db_name`, `copied_log_path`, `worker_idx`) | 위와 같음 |

applier 전체 값과 worker별 값은 컬럼 구성이 달라서 테이블을 나눈다. 한 테이블에 넣으면 행 종류에 따라 빈 칸이 많아진다.

## 4. 항목과 출처 trace

### 4.1 `_db_ha_writeset_stat` (master)

| 컬럼 | 뜻 | 출처 trace (레벨) |
|---|---|---|
| `server_start_time` | 이 카운터를 세기 시작한 서버 기동 시각 | — |
| `last_update_time` | 이 행을 마지막으로 갱신한 시각 | — |
| `history_size` | writeset history 크기 설정값 | `INITIALIZE history_size=` (1) |
| `commit_count` | writeset 라벨을 단 커밋 수 | `COMMIT trid=... fallback=` (1) |
| `commit_fallback_count` | 그중 commit order로 떨어진 커밋 수 | `COMMIT ... fallback=1` (1) |
| `fallback_key_limit_count` | 대체 이유: 트랜잭션 키 수 상한 초과 | `FALLBACK reason=TRANSACTION_KEY_LIMIT` (1) |
| `fallback_statement_count` | 대체 이유: statement 복제, serial 키를 못 모음 | `FALLBACK reason=STATEMENT_REPLICATION` (1) |
| `dependency_ref_slot_count` | 의존을 REF 키(참조)에서 찾은 커밋 수 | `DEPENDENCY source=REF_SLOT` (1) |
| `dependency_write_bound_count` | 의존을 WRITE 키 또는 하한에서 찾은 커밋 수 | `DEPENDENCY source=WRITE_BOUND` (1) |
| `sysop_commit_order_count` | serial sysop을 commit order 장벽으로 처리한 횟수 | `DEPENDENCY mode=SYSOP_COMMIT_ORDER`, `SYSOP master commit_order` (1) |
| `floor_raise_restart_count` | 서버 재시작으로 history 하한을 올린 횟수 | `HISTORY_START raise reason=RESTART` (1) |
| `floor_raise_sysop_count` | serial sysop으로 history 하한을 올린 횟수 | `HISTORY_START raise reason=SYSOP_COMMIT_ORDER` (1) |
| `clear_fallback_count` | commit order 대체로 history를 비운 횟수 | `CLEAR reason=COMMIT_ORDER_FALLBACK` (1) |
| `clear_capacity_count` | history가 가득 차서 비운 횟수 | `CLEAR reason=HISTORY_CAPACITY` (1) |
| `clear_out_of_memory_count` | 메모리 부족으로 history를 비운 횟수 | `CLEAR reason=OUT_OF_MEMORY` (1) |
| `write_publish_count` | history에 등록한 WRITE 키 수 | `PUBLISH` (3), 기존 `wset_Statistics.write_publish_count` |
| `ref_publish_count` | history에 등록한 REF 키 수 | `PUBLISH` (3), 기존 `wset_Statistics.ref_publish_count` |

- `wset_Statistics`(`writeset.cpp:60`)에 이미 있는 overflow, commit-order 대체, history 비움, WRITE/REF 등록 카운터는 위 컬럼의 원천으로 쓴다. 나머지는 trace를 남기는 자리에서 같이 세도록 카운터를 추가해야 한다.
- `fallback_key_limit_count`와 `commit_fallback_count`의 비율이 높으면 큰 트랜잭션 때문에 병렬도를 잃고 있다는 뜻이다. `sysop_commit_order_count`는 C14(serial 장벽)의 빈도다.

### 4.2 `_db_ha_apply_stat` (slave, applier 전체)

| 컬럼 | 뜻 | 출처 trace (레벨) |
|---|---|---|
| `db_name`, `copied_log_path` | 어느 applier인지 (`_db_ha_apply_info`와 같은 기준) | — |
| `start_time`, `last_update_time` | 카운터를 세기 시작한 applier 기동 시각, 마지막 갱신 시각 | — |
| `worker_count` | 이 applier의 worker 수 | 기동 알림 |
| `commit_read_count` | 읽은 커밋 수 (항목 있는 것) | `reader commit ... items=N` (N>0) (1) |
| `commit_empty_count` | 읽은 커밋 중 항목 없는 것 | `reader commit ... items=0` (1) |
| `commit_unlabeled_count` | 항목이 있는데 라벨이 없는 커밋 (앞 커밋을 기다리게 처리) | `reader commit ... has_label=0` (1) |
| `dispatch_direct_count` | 읽자마자 worker에 넘긴 작업 수 | `reader schedule status=0` (1) |
| `dispatch_parked_count` | 의존 때문에 보류(park)된 작업 수 | `reader schedule status=2` (1) |
| `dispatch_released_count` | 보류에서 풀려 넘긴 작업 수 | `reader schedule status=1` (1) |
| `serial_fragment_count` | serial 조각으로 떼어 따로 적용한 수 | `SYSOP slave fragment assemble` (1) |
| `sysop_complete_count` | 적용할 항목 없이 완료로 등록한 SYSOP_END 수 | `reader complete_without_task` (1) |
| `label_lowered_count` | 라벨을 직전 커밋으로 낮춘 횟수 (C1) | `reader label lowered` (1) |
| `label_read_failure_count` | 라벨 읽기 실패 횟수 (C12) | er_set `failed to read LOG_DUMMY_WSET_LABEL` |
| `recovery_serial_count` | 재시작 recovery range에서 하나씩 적용한 작업 수 | recovery range 경로 |
| `recovery_skipped_count` | recovery range에서 건너뛴 재적용 오류 수 | 기존 `la_Info.recovery_skipped_counter` |
| `skip_update_count` | 로그 위치 없는 UPDATE 항목을 건너뛴 수 | `worker skip update without log position` (2) |
| `done_hold_count` | DONE 보고를 보류한 횟수 | `applylogdb holds DONE` |
| `done_hold_sec` | DONE 보류 누적 시간(초) | `applylogdb reports DONE after holding it for N seconds` |
| `required_lsa_held_count` | retire 안 된 작업이 required_lsa를 붙잡은 횟수 | `coordinator required_lsa held` (1) |

- insert, update, delete, schema, commit, fail 카운터는 `_db_ha_apply_info`에 이미 있으므로 이 테이블에 다시 두지 않는다.
- `dispatch_parked_count ÷ (dispatch_direct_count + dispatch_parked_count)`가 의존 때문에 기다린 비율이다.

### 4.3 `_db_ha_apply_worker_stat` (slave, worker별)

| 컬럼 | 뜻 | 출처 trace (레벨) |
|---|---|---|
| `db_name`, `copied_log_path`, `worker_idx` | 어느 applier의 몇 번 worker인지 | — |
| `start_time`, `last_update_time` | 세기 시작한 시각, 마지막 갱신 시각 | — |
| `applied_task_count` | 적용한 작업(커밋, serial 조각) 수 | `worker apply done` (1) |
| `applied_row_count` | 적용한 행 수 | `worker apply end ... rows=` (2), 기존 `worker_applied_item_count` |
| `busy_usec` | 적용에 쓴 시간 누적 | `worker apply done ... elapsed_usec=` (1) |
| `error_count` | 항목 적용 오류 수 | `worker error` (1) |

- 처리율은 두 시점의 `applied_task_count`(또는 `applied_row_count`) 차이를 `last_update_time` 차이로 나눠 구한다.
- `busy_usec ÷ applied_task_count`가 다른 worker보다 크면, 그 worker에 큰 트랜잭션이 몰렸거나 잠금을 기다렸다는 뜻이다.

### 4.4 통계로 옮기지 않는 trace

다음은 건마다 남는 상세 기록이라 카운터로 바꾸지 않고 trace로 둔다.

- master 레벨 3: `COLLECT`, `SOURCE`, `PROBE`, `PUBLISH`의 키별 기록, `[WSET] ROW`, `[WSET] UNIQUE`, `SERIAL master collect`
- slave: 작업별 `reader schedule`, `worker apply begin/end`, `worker flush begin/end`, `worker commit begin`, `reader retire`, `reader result`

## 5. 저장 방식

### 5.1 `_db_ha_writeset_stat`: 서버가 직접 갱신

서버가 SQL을 쓰지 않고 heap 행을 직접 고친다. 근거가 되는 현재 코드는 다음과 같다.

| 근거 | 위치 |
|---|---|
| 서버가 실행 중에 카탈로그 행을 제자리에서 고치는 선례. 시스템 연산 안에서 `log_append_redo_recdes (RVHF_UPDATE)` 뒤 `spage_update` | `serial.c:1150`~`1257` |
| 행 복제는 `repl_log_insert`를 명시적으로 부를 때만 생김 | `serial.c:1211`, `locator_sr.c:8271` |
| MVCC를 끈 카탈로그 목록 (`_db_ha_apply_info`는 OID 캐시로 등록) | `mvcc.c:683` |
| 사용자 트랜잭션 없이 시스템 연산을 로그로 남기는 시스템 worker (vacuum, 인덱스 적재가 사용) | `thread_entry.cpp:446` `claim_system_worker` |
| 서버가 active일 때 매초 HA 상태 레코드를 남기는 주기 작업 | `log_manager.c:10997` `log_check_ha_delay_info_execute` |

요구사항:

1. `createdb`는 `_db_ha_writeset_stat` 클래스와 그 DB용 행 하나를 만들어야 한다.
2. 이 클래스는 OID 캐시에 등록하고 `mvcc_is_mvcc_disabled_class`가 참을 돌려주게 해야 한다. 갱신이 버전을 쌓지 않고 제자리에서 끝나야 하기 때문이다.
3. 모든 컬럼은 고정 크기(정수, 시각)여야 한다. 제자리 갱신(`spage_is_updatable`)이 항상 되어야 하기 때문이다.
4. 서버는 기동할 때 행의 OID를 캐시하고, `server_start_time`을 기동 시각으로 바꾸고 카운터를 0으로 시작해야 한다. 메모리 카운터가 기동 때 0이 되기 때문이다.
5. 갱신은 서버가 active일 때 갱신 주기마다, 그리고 서버를 내릴 때 해야 한다. standby일 때는 갱신하지 않고 마지막 값을 둔다.
   - 갱신 주기는 서버 파라미터 `ha_writeset_stat_interval_in_secs`(가칭)로 정해야 한다. 기본값은 1초이고, 0이면 갱신하지 않는다.
   - 갱신은 1초 주기 작업 `log_check_ha_delay_info_execute`가 HA 상태 레코드를 남기는 자리에서, 지난 갱신 뒤 주기가 지났을 때 해야 한다. 이 작업은 이미 매초 로그 레코드를 남기고 `logpb_flush_pages`로 로그를 내리므로, 갱신이 더하는 것은 시스템 연산 로그와 redo 로그 레코드 몇 개다.
6. 갱신은 시스템 연산 안에서 redo 로그를 남기고 `spage_update`로 해야 하며, `repl_log_insert`를 불러서는 안 된다. 통계 행이 slave로 복제되면 안 되기 때문이다.

### 5.2 `_db_ha_apply_stat`, `_db_ha_apply_worker_stat`: applier가 SQL로 갱신

applier는 지금 `_db_ha_apply_info`를 SQL로 넣고 갱신한다. 같은 방식을 따른다.

요구사항:

1. worker는 4.2절과 4.3절의 값을 작업 결과(`LA_RESULT`)에 담아 보내고, coordinator가 retire할 때 더해야 한다. worker가 공유 카운터를 직접 고치지 않으므로 잠금이 필요 없다.
2. coordinator만 세는 값(`reader commit`, `reader schedule`, 라벨 관련)은 coordinator가 그 자리에서 더해야 한다.
3. 두 테이블의 갱신은 `_db_ha_apply_info`를 저장하는 트랜잭션(`la_coordinator_commit_apply_info`, `la_log_commit`)에 함께 넣어야 한다. 세 테이블이 같은 시점을 가리키게 하기 위해서다.
4. applier를 시작할 때 자기 행이 없으면 만들어야 한다(`_db_ha_apply_info`를 처음 넣는 경로와 같은 곳).
5. applier를 시작할 때 두 테이블의 카운터를 0으로, `start_time`을 기동 시각으로 바꿔야 한다. 테이블에 저장된 이전 값을 읽어 이어서 세면 안 된다. `_db_ha_apply_info`의 insert·update·delete·schema·commit·fail 카운터는 develop 동작대로 이어서 세며, 이 규칙과 관계없다.
6. applier를 시작할 때 자기(`db_name`, `copied_log_path`)의 `_db_ha_apply_worker_stat` 행을 모두 지우고, 지금 worker 수만큼(`worker_idx` 0 ~ worker 수−1) 카운터 0으로 새로 넣어야 한다. worker 수를 줄여 다시 띄웠을 때 지난 실행의 worker 행(예: 10개에서 4개로 줄이면 4~9번)이 남거나 0으로 남으면, 없는 worker가 일을 받지 못하는 worker처럼 보이기 때문이다. 카운터를 0부터 세므로 지워서 잃는 값은 없다.

## 6. 조회

SQL로 조회한다.

```sql
SELECT * FROM _db_ha_writeset_stat;                         -- master 노드에서
SELECT * FROM _db_ha_apply_stat;                            -- slave 노드에서
SELECT worker_idx, applied_task_count, applied_row_count, busy_usec, last_update_time
  FROM _db_ha_apply_worker_stat ORDER BY worker_idx;
```

### 6.1 `cubrid applyinfo`

지금 `applyinfo`는 slave에서 다음 구역을 출력한다. 모두 "어디까지 받았고 어디까지 적용했는가"이며, 어떻게 적용했는지(병렬도, 대기, worker 분배)는 없다.

| 구역 | 내용 | 출처 |
|---|---|---|
| Applied Info | Insert / Update / Delete / Schema / Commit / Fail count. `-v`면 LSA 위치와 시각 | `_db_ha_apply_info` |
| Copied Active Info | 복사한 master 로그 헤더(EOF·Append LSA, HA 서버 상태 등) | slave의 copylog (`-L`) |
| Active Info | master 로그 헤더 | master 접속 (`-r`) |
| Delay in Copying Active Log | 복사 지연 페이지 수와 예상 시간 | Active와 Copied의 차이 |
| Delay in Applying Copied Log | 적용 지연 페이지 수와 예상 시간 | Copied와 적용 위치의 차이 |

요구사항:

1. `applyinfo`는 `-a`일 때 Applied Info 다음에 "Parallel Apply Info" 구역을 출력해야 한다. 값은 `_db_ha_apply_stat`과 `_db_ha_apply_worker_stat`에서 읽는다.
2. 기본 출력은 applier 전체 요약이어야 한다: 시작 시각, worker 수, 읽은 커밋 수, 바로 넘긴 작업 수, 의존 대기(park) 작업 수와 비율, serial 조각 수, DONE 보류 횟수와 누적 시간.
3. `-v`면 `_db_ha_apply_stat`의 나머지 컬럼과 worker별 행(`worker_idx`, 적용 작업 수, 적용 행 수, 적용 시간, 오류 수, 마지막 갱신 시각)을 함께 출력해야 한다.
4. 통계 행이 없으면(통계 테이블이 생기기 전 DB이거나 applier가 아직 한 번도 갱신하지 않음) 구역을 출력하지 않거나 값이 없다고 표시해야 한다. `applyinfo`가 이 때문에 실패하면 안 된다.

출력 예시(값은 가상):

```text
 *** Parallel Apply Info. ***
Start time                     : 05:23:41.000 PM 10/23/2026
Worker count                   : 10
Commits read                   : 244657
Dispatched directly            : 231004
Parked by dependency           : 13653 (5.6%)
Serial fragments               : 1000
DONE held                      : 1 time(s), 57 second(s)
```

master의 writeset 통계는 master DB에 있으므로 SQL로 조회한다. `applyinfo -r`로 master에 접속하기는 하지만, 출력 범위가 slave 적용 상태에서 벗어나므로 붙이지 않는다. `statdump`는 서버 성능 카운터 체계이고 이번 설계는 DB 테이블에 남기는 것이므로 붙이지 않는다.

## 7. 영향과 위험

- 카탈로그 추가: 이전 버전으로 만든 DB에는 테이블이 없다. C7과 같은 경우이고, 다음 버전으로만 나가므로 버전 업그레이드 절차에 맡긴다.
- master 비용: 커밋 경로의 카운터 증가는 원자적 덧셈이다. 행 갱신은 기본 1초마다 한 번이고, 시스템 연산 로그와 수백 바이트짜리 redo 로그 레코드가 늘어난다. 하루 수십 MB 수준으로 추정하며, 쓰기가 없는 master에서도 로그가 그만큼 늘어나고 slave의 copylogdb·applier가 그 로그를 읽는다. 구현 뒤 쓰기 없는 상태에서 로그 증가량을 재서 확인해야 한다.
- slave 비용: 기존 apply info 저장 트랜잭션에 UPDATE 두 개(applier 행, worker 행들)가 더해진다.
- 핑퐁: slave의 통계 갱신은 standby 서버에 대한 쓰기라 복제 로그를 만들지 않는다. 지금 `_db_ha_apply_info` 갱신과 같다.

## 8. 미확정

1. 구현하면서 확인할 것.
   - 1초 주기 작업 스레드에서 시스템 worker를 얻고 반납하는 것이 그 작업 구조에서 안전한지. vacuum은 전용 스레드다.
   - 서버를 내리는 도중이나 failover 순간의 갱신이 안전한지.
   - 장애 복구 때 이 갱신이 serial 갱신처럼 redo되는지.
