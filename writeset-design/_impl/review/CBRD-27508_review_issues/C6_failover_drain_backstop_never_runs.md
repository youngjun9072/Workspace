# C6. failover 때 DONE 보류를 끊는 30초 재시작 백스톱이 실행되지 않음

## 1. 메타
| 항목 | 내용 |
|---|---|
| 등급 | 종합 문서 Medium → **Low (정리 대상)** |
| 상태 | **백스톱 제거(10-23, `a361cca24`)**. 수정 전 HA 재현(10-22)과 제거 후 회귀 확인(10-23, 4.3절) 완료. DONE 보류는 설계대로 동작하고 develop과 같은 동작이다. 교착 희생 처리 확인(6.2절)도 마쳤고 수정할 것이 없다 |
| 판정 | 백스톱 미실행은 재현으로 확정. 처음에는 결함이 아니라 정리 대상으로 판단했다(5절). C5 수정 뒤 백스톱 조건이 성립할 수 있게 되어, 실행되면 해가 되는 코드로 보고 제거했다(3.1절) |
| 신규/기존 | 백스톱은 이 브랜치에서 추가한 코드. DONE 보류도 이 브랜치에서 추가했지만 develop의 동작(적용이 끝나야 DONE)과 결과가 같다 |
| 관련 | [C4](C4_coordinator_result_wait_ignores_shutdown.md)(worker가 모두 빠져 결과가 오지 않는 경우, 수정됨). [C5](C5_dbname_lock_taken_once.md)(수정 `bf8533de3`이 역할 변경 처리를 보낸 트랜잭션이 끝날 때까지 미뤄, 백스톱 조건이 성립할 수 있게 됨, C5 7.4절). 교착 희생 처리(6.2절) |
| 지적한 리뷰어 | 4명(종합 문서 2절) |

## 2. 용어
- **DONE**: slave의 applylogdb가 자기 서버에 "받은 로그를 다 적용했다"고 알리는 상태. slave 서버는 이 보고를 받아야 `to_be_active`에서 `active`(master)로 넘어간다.
- **DONE 보류**: 이 브랜치는 로그를 끝까지 읽었더라도 worker에게 보낸 트랜잭션이 하나라도 끝나지 않았으면 DONE을 보고하지 않는다(`la_change_state`, "applylogdb holds DONE"). 끝나지 않은 트랜잭션이 있는 채 승격하면 그 데이터가 빠지기 때문이다.
- **끝나지 않은 트랜잭션**: worker가 받았지만 아직 slave에서 커밋하지 못한 트랜잭션. 느리게 적용 중이거나, 잠금을 기다리거나, worker 스레드가 죽은 경우가 있다(5.2절). 이 문서는 "worker가 멈췄다"는 표현을 쓰지 않는다.
- **백스톱**: DONE을 보류하는 동안 frontier가 30초(`LA_DRAIN_TIMEOUT_MSEC`) 움직이지 않으면 applier를 재시작하는 장치.

## 3. 문제 위치 (코드 `74acb3ea8`, `log_applier.c`)
```c
/* 메인 루프 */
10508  if (la_Info.is_role_changed == true)
         {
           clear_owner = true;
           error = la_unlock_dbname (&la_Info.db_lockf_vdes, la_slave_db_name, clear_owner);   // is_role_changed = false, 60초 sleep
         }
       if (LSA_EQ (&old_lsa, &la_Info.final_lsa))
         {
10520      if (la_Info.is_role_changed == true && !la_coordinator_drain_complete ())          // ★ 백스톱 조건
             {
               ... frontier가 30초 움직이지 않으면 "giving up and restarting" → la_applier_need_shutdown = true
             }

/* is_role_changed를 세우는 유일한 곳: master 로그의 HA 서버 상태 기록을 읽을 때, dbname lock을 쥐고 있으면 */
7959   if (la_Info.db_lockf_vdes != NULL_VOLDES)
         {
7967       la_Info.is_role_changed = true;
           return ER_INTERRUPTED;
         }
```
- 리뷰의 지적: `is_role_changed`가 true가 되면 같은 반복의 앞부분에서 `la_unlock_dbname`이 false로 되돌리므로, 10520행 조건은 항상 거짓이다.
- 재현에서 더 확인한 것(4.2절): 정상 failover(`hb stop`)에서는 7967행의 신호 자체가 오지 않았다. 백스톱은 조건이 기대는 신호가 오지 않아서도 실행되지 않는다.

### 3.1 C5 수정 뒤 달라진 점
[C5](C5_dbname_lock_taken_once.md) 수정(`bf8533de3`)은 dbname lock을 보낸 트랜잭션이 다 끝난 뒤에만 놓도록, 10508행 조건을 바꿨다.
```c
  if (la_Info.is_role_changed == true && la_coordinator_drain_complete ())   // C5: 보낸 트랜잭션이 다 끝나야 놓음
```
그래서 보낸 트랜잭션이 남아 있으면 `is_role_changed`가 true로 남고, 10520행 백스톱 조건이 성립할 수 있다. 성립하면 다음 일이 생길 수 있다(추정, 실측 안 함).
1. 승격 중에 큰 트랜잭션 T를 적용하고 있어 frontier가 30초 넘게 움직이지 않는다.
2. 백스톱이 applier를 끄고, 서버는 T를 롤백한다.
3. heartbeat가 applier를 다시 띄우면 T를 처음부터 다시 적용하므로, 30초 뒤 다시 꺼진다.
4. T가 끝나지 않으므로 DONE이 나가지 않고, 노드는 승격하지 못한다.

실행되지 않던 코드가 실행되면 해가 되는 코드로 바뀌었으므로 제거했다(6절).

## 4. 재현 (HA)

### 4.1 방법 (`ha_bench_tool/bin/c6_drain_backstop.sh`)
1. youngjun4(slave) HA를 환경변수 `CUBRID_HA_TEST_BLOCK_CLASS=dba.c6_block`, `CUBRID_HA_TEST_BLOCK_MSEC=240000`을 넣어 다시 올린다(`cubrid service stop` → `hb start`). 브랜치에 있는 시험 훅(`la_apply_worker_test_block_before_commit`)이 c6_block 행을 적용한 worker를 커밋 직전에 240초 sleep시킨다. applylogdb 환경에 변수가 들어간 것을 `/proc/<pid>/environ`으로 확인한다.
2. master: `CREATE TABLE c6_block`, `INSERT INTO c6_block VALUES (1)`.
3. 훅이 걸린 것을 확인하고 3초 뒤 youngjun3에서 `cubrid hb stop`(정상 failover, F1과 같음).
4. youngjun4가 `active`가 될 때까지의 시간과 applier 로그(DONE 보류, 백스톱, DONE 보고)를 본다.
5. failback 뒤 c6_block 행을 비교하고, 역할을 되돌리고, youngjun4를 환경변수 없이 다시 올린다.

### 4.2 결과 (10-22 10:14~10:21, 빌드 2779-74acb3e)
| 시각 | 사건 |
|---|---|
| 10:15:26 | worker 3이 c6_block 행을 적용하고 커밋 직전에 훅에 걸림(trid 287982, commit 813205\|3400, 240초) |
| 10:15:29 | youngjun3 `hb stop` → failover. 같은 시각 applier가 "**holds DONE**: workers are still applying (pending=0 dispatch=2 order=2)" |
| 10:15:35 | youngjun4 노드 역할이 master로 바뀜. 서버는 DONE을 기다리며 `to_be_active` |
| 10:15:29 ~ 10:19:26 | 백스톱 "giving up and restarting" **0건** |
| 10:19:26 | 훅이 끝나 worker 3이 커밋 → "**reports DONE after holding it for 237 seconds**" |
| 10:19:31 | youngjun4 `active`(트리거 뒤 241초) |

- 보류 시간 237초 = 훅 240초 − 훅 시작과 failover 사이 3초. 트랜잭션이 끝난 바로 그 순간에 DONE이 나갔다.
- 승격은 DONE 보고 5초 뒤(heartbeat 확인 주기로 추정).
- failback 뒤 c6_block 행 youngjun4 1 / youngjun3 1. fail_counter 양쪽 0. youngjun4는 환경변수 없이 slave로 복귀(applier 환경 확인).
- failover 동안 7967행의 알림("the state of HA server ... is changed to")은 한 번도 없었다. 이 알림은 10:21 역할을 되돌릴 때만 나왔다. 그래서 이 failover에서 `is_role_changed`는 처음부터 true가 되지 않았다. 정상 종료하는 master가 상태 기록을 남기지 않는 이유는 코드로 따라가지 않았다(추정).
- 결과 디렉터리: `ha_bench_tool/log/c6_drain_backstop_20261022_101445/`

### 4.3 제거 후 회귀 확인 (10-23 10:12~10:17, 빌드 2782-a361cca)
4.1절과 같은 방법이다. 노드는 youngjun3·youngjun4 2노드, conf는 기준(be315c1b / ea141281)이다.

| 시각 | 사건 |
|---|---|
| 10:12:46 | worker 2가 c6_block 행을 적용하고 커밋 직전에 훅에 걸림(trid 860, commit 178\|848, 240초) |
| 10:12:49 | youngjun3 `hb stop` → failover. 같은 시각 applier가 "**holds DONE**: workers are still applying (pending=0 dispatch=3 order=3)" |
| 10:12:49 ~ 10:16:46 | "giving up and restarting" 0건(코드에서 지웠으므로 나올 수 없음) |
| 10:16:46 | 훅이 끝나 worker 2가 커밋 → "**reports DONE after holding it for 237 seconds**" |
| 10:16:47 | youngjun4 `active`(트리거 뒤 238초) |

- 4.2절과 같은 동작이다. 백스톱이 없어도 끝나지 않은 트랜잭션을 끝까지 기다렸다가 DONE을 보고하고 승격한다.
- failback 뒤 c6_block 행 youngjun4 1 / youngjun3 1(각 노드 DB에 직접 조회). fail_counter 양쪽 0. youngjun4는 환경변수 없이 slave로 복귀.
- 이번 failover에서도 7967행의 알림이 없었으므로 `is_role_changed`는 true가 되지 않았다. 그래서 이 시험은 지운 경로(3.1절)를 실행한 것이 아니라, 지운 뒤에도 정상 failover가 그대로 동작하는지 확인한 회귀 시험이다.
- 하니스 수정: `c6_drain_backstop.sh`에 `source ~/.cubrid.sh`가 없어 CUBRID 환경이 없는 셸에서는 csql이 모두 실패했다. 한 줄 넣어 고쳤다. 고치기 전 10:08 런은 테이블 생성 없이 끝나 무효다.
- 결과 디렉터리: `ha_bench_tool/log/c6_drain_backstop_20261023_101226/`

## 5. 판단

### 5.1 DONE 보류는 올바른 동작이고 develop과 같다
- develop의 DONE 조건은 "로그를 끝까지 읽음(`is_end_of_record`), copy 동기화, 상대 서버가 DEAD/STANDBY"다(develop `la_change_state`).
- develop은 단일 스레드이고 `la_change_state`는 메인 루프에서 트랜잭션 사이에만 불린다(develop `log_applier.c:8615`). 트랜잭션 하나의 적용이 끝나지 않으면 루프가 돌지 않아 DONE도 보고되지 않는다. 타임아웃이나 재시작 장치도 없다.
- 4.2절의 "트랜잭션 하나가 늦게 끝남 → DONE이 그만큼 늦음 → 승격이 그만큼 늦음"은 develop과 같은 동작이다. 끝나지 않은 트랜잭션이 있으면 DONE이 아닌 것이 맞는 상태다.

### 5.2 백스톱(재시작)은 실행되더라도 도움이 되지 않는다
| 트랜잭션이 끝나지 않는 이유 | 재시작하면 | 맞는 대응 |
|---|---|---|
| 큰 트랜잭션 적용 중(느림) | 하던 일을 버리고 처음부터 다시 함 | 기다림 |
| slave에서 잠금 대기 | 같은 자리에서 다시 기다림 | 잠금을 쥔 쪽이 끝나기를 기다림 |
| worker끼리 교착 | 서버 교착 감지가 이미 한쪽을 희생시킴 | 희생 처리를 바로잡음(6.2절) |
| worker 스레드가 죽음 | 풀림 | C4: 죽은 것을 감지해 종료·재시작 |

재시작으로 실제로 풀리는 경우는 worker가 죽은 경우뿐이고, 이것은 C4에서 처리한다. 나머지는 재시작이 소용없거나 해롭다. appdev_3y가 지적한 "30초 → 재시작 → 같은 트랜잭션에서 다시 30초" 루프도 백스톱을 고치면 실제로 생긴다.

### 5.3 결론
C6는 결함이 아니다. DONE 보류는 설계대로 동작했다. 남는 것은 실행되지 않는 30초 재시작 백스톱 코드였다. C5 수정 뒤에는 이 코드가 실행될 수 있게 되었고(3.1절), 실행되면 5.2절대로 해가 되므로 제거했다.

## 6. 수정 (`a361cca24`)
- 메인 루프의 30초 재시작 백스톱 블록과, 그 블록만 쓰던 상태(`la_Drain_wait_start_ns`, `la_Drain_last_frontier`, `LA_DRAIN_TIMEOUT_MSEC`)를 지웠다. `la_Drain_wait_start_ns`를 0으로 되돌리던 세 곳(`la_lock_dbname`, `la_unlock_dbname`, `la_init`)도 함께 지웠다.
- 지운 뒤에는 새 로그가 없을 때 worker 결과를 0.1초씩 기다리며 다시 확인하는 동작만 남는다. 보낸 트랜잭션이 끝날 때까지 기다리는 것은 develop과 같다.
- 진단 로그(DONE 보류 N초째, 남은 트랜잭션)는 넣지 않았다. DONE을 보류할 때와 보고할 때 남는 기존 알림("holds DONE", "reports DONE after holding it for N seconds")으로 보류 시작과 끝은 알 수 있다.

### 6.1 함께 볼 것: C4
worker 스레드가 죽어 트랜잭션이 영원히 끝나지 않는 경우는 C4가 다룬다. coordinator가 결과 큐를 무기한 기다리고 SIGTERM으로도 깨지 않는 문제다.

### 6.2 함께 볼 것: 교착 희생 처리 (확인 완료, 수정 없음)
**확인하려던 것.** 예를 들어 트랜잭션 T에 항목(행 변경 하나) A, B, C가 있다고 하겠다.
1. worker가 A와 B를 적용하고, C에서 다른 worker와 교착해 T가 희생된다.
2. 서버는 T 전체를 롤백하므로 A와 B도 사라진다.
3. applier는 희생 오류(`ER_LK_UNILATERALLY_ABORTED`, -72)를 재시도 대상(`LA_RETRY_ON_ERROR`)으로 보고, 10초 뒤 **C 하나만** 다시 적용한다(`la_apply_repl_log`).
4. 그대로 커밋하면 slave에는 C만 남는다.

**확인한 것 (코드 `a361cca24`).**
- 2번은 맞다. 서버는 -72가 나면 트랜잭션 전체를 롤백한다(`network_interface_sr.cpp`, `return_error_to_client` → `tran_server_unilaterally_abort_tran`).
- 행 항목의 교착은 3번까지 오지 않는다. worker는 행 항목을 클라이언트에 모았다가 200개마다, 그리고 커밋할 때 한 번에 서버로 보낸다(`la_flush_repl_items`). 교착 오류는 이 묶음 결과로 돌아오고, -72와 교착 오류(-1021)는 재시작 대상이라 `ER_LC_PARTIALLY_FAILED_TO_FLUSH`(-1105) 또는 `ER_LC_FAILED_TO_FLUSH_REPL_ITEMS`(-1170)가 된다. `la_apply_repl_log`는 묶음 오류면 항목을 다시 하지 않고 끝내고, coordinator는 `la_shutdown`으로 종료한다. 재시작하면 마지막 커밋 뒤부터 T 전체(A, B, C)를 다시 적용하므로 빠지는 항목이 없다. 10-19의 "-72 → -1170 → 종료" 반복이 이 경로였다.
- 3번에 -72가 닿는 것은 statement 복제 항목뿐이다. 문장을 바로 서버에서 실행하기 때문이다. 그런데 statement 복제 트랜잭션은 master가 commit order로 떨어뜨린다(`WSET_FALLBACK_STATEMENT_REPLICATION`). 앞의 커밋을 모두 기다리고, 커밋할 때 history를 비우고 바닥을 올려 뒤의 트랜잭션도 이 트랜잭션을 기다린다(`wset_clear_overflow_history`). 그래서 slave에서 혼자 실행되고, 다른 worker와 교착할 상대가 없다.

| 경우 | 교착하면 | 빠지는 항목 |
|---|---|---|
| 행 항목 | applier 종료 → 재시작 후 T 전체를 다시 적용 | 없음 |
| statement 복제 항목 | 혼자 실행되므로 worker끼리 교착하지 않음 | 없음 |
| statement 복제 항목이 slave의 다른 세션과 교착 | 3번 경로 → 빠질 수 있음 | develop에도 같은 경로(추정) |

마지막 줄은 develop에서 물려받은 경로라 이번 범위에서 고치지 않는다.

**확인하지 않은 것.** 서버가 묶음 중간에 희생됐을 때 나머지 행을 어떻게 처리하는지(어느 쪽이든 applier가 커밋하지 않고 종료하므로 결론은 같다, 추정). statement 복제 트랜잭션 안에 행 항목이 섞이는 경우가 있는지.

## 7. 열린 질문
1. 정상 failover에서 master가 HA 서버 상태 기록을 남기지 않는 이유(4.2절).
2. ~~6.2절의 교착 희생 처리가 실제로 트랜잭션 앞 항목을 잃는지.~~ 코드로 확인했다. worker끼리의 교착으로는 잃지 않는다(6.2절).
3. ~~백스톱을 제거한 뒤에도 운영자가 승격 지연 원인을 알 수 있게 진단 로그를 둘지.~~ 넣지 않기로 했다(6절).
4. 지운 경로(3.1절: `is_role_changed`가 켜진 채 보낸 트랜잭션이 남는 상황)는 실측하지 못했다. 정상 failover에서는 `is_role_changed`가 켜지지 않았다. master 서버만 죽는 failover처럼 master가 HA 서버 상태 기록을 남기는 경우에 켜질 것으로 추정한다.
