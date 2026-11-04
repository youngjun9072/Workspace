# C4. worker가 모두 빠지면 coordinator가 결과를 무기한 기다리고 종료 요청도 보지 않음

## 1. 메타
| 항목 | 내용 |
|---|---|
| 등급 | High |
| 상태 | HA 재현 완료, 수정 커밋 `6ae74828a`, 같은 조건에서 수정 확인(10-22) |
| 판정 | 확정. 수정 전 빌드에서 멈춤과 SIGTERM 무시를 재현했고, 멈춘 프로세스의 스택으로 대기 위치를 확인했다 |
| 신규/기존 | 신규. develop은 단일 스레드라 결과 큐가 없다 |
| 관련 | [C6](C6_failover_drain_backstop_never_runs.md)(5.2절: 재시작으로 풀리는 경우는 worker가 죽은 경우뿐이고 그것은 C4에서 처리) |
| 지적한 리뷰어 | 7명(종합 문서 2절) |
| 시험 훅 | 재현에만 쓰고 브랜치에서 뺐다(5.1절, 7.3절). 백업 브랜치 `backup/c4-with-hooks-20261022`의 `1f49bdde7`, `eab1906ac` |

## 2. 용어와 예시
- **coordinator**: applier의 메인 스레드. 로그를 읽어 커밋마다 작업을 만들고 worker에게 보낸 뒤, worker가 돌려준 결과를 받아 순서대로 retire한다.
- **결과 큐**: worker가 적용을 끝낸 결과를 넣고 coordinator가 꺼내는 큐(`log_applier_result_queue.cpp`).
- **recovery range**: applier가 비정상 종료한 뒤 다시 뜰 때, 이전 실행이 적용했을 수도 있는 커밋 구간. 이 구간의 커밋은 하나씩 보내고, 보낸 것이 모두 retire될 때까지 기다린 뒤 다음 커밋을 보낸다.
- **종료 플래그**: `la_applier_need_shutdown`. worker 실패, 적용 오류, SIGTERM이 모두 이 플래그를 세운다. 메인 루프가 이 플래그를 보고 끝난다.
- **예시**: worker 10개. applier를 kill -9한 직후 다시 띄웠는데, 서버 접속이 안 되어 worker 10개가 모두 시작에 실패한다. 다시 뜬 applier는 recovery range의 첫 커밋 `351|9808`을 보낸 뒤 그 결과를 기다리고 있다.

## 3. 문제 위치 (수정 전 코드 `74acb3ea8`)
```c
/* log_applier.c: recovery range 커밋은 보낸 것이 모두 retire될 때까지 기다린다 */
1043  la_coordinator_wait_until_retired (void)
        while (la_inflight_get_count () > 0)
          {
1050        error = la_result_queue_pop (&result);                          // ★(A) 결과가 올 때까지 무기한 대기
            ...
          }

/* log_applier_result_queue.cpp */
172   la_result_queue_pop (LA_RESULT *result)
        while (count == 0 && la_Shared_result_shutdown == false)            // ★(B) 큐 자체의 종료 플래그만 본다
          pthread_cond_wait (&la_Shared_result_not_empty, &la_Shared_result_mutex);

/* 종료를 요청하는 쪽: 모두 다른 플래그만 세운다 */
1534  la_request_shutdown (void)       { la_applier_need_shutdown = true; }      // ★(C) worker 실패·적용 오류
689   la_shutdown_by_signal (int)      { la_applier_need_shutdown = true; ... }  // ★(C) SIGTERM

/* 큐의 종료 플래그를 세우는 유일한 곳: 메인 루프가 끝난 뒤의 la_shutdown 안 */
1541  la_stop_apply_workers (void)     { ... la_result_queue_signal_shutdown (); ... }   // ★(D)
```
- (A) 결과가 오지 않으면 coordinator는 pop에서 잠든다. `la_coordinator_wait_for_inflight_slot`(1084, 1091)도 같은 pop을 쓴다.
- (B) pop을 깨우는 것은 worker의 push와 큐의 종료 플래그(`la_Shared_result_shutdown`)뿐이다.
- (C) worker가 모두 시작에 실패하면 마지막 worker가 `la_request_shutdown`을 부르지만, 이 함수는 `la_applier_need_shutdown`만 세운다. SIGTERM도 같다.
- (D) 큐의 종료 플래그는 메인 루프가 끝난 뒤에야 세워진다. 그런데 메인 루프는 (A)에서 잠들어 있어서 그곳에 도달하지 못한다.

두 플래그가 서로 이어져 있지 않은 것이 원인이다. 프로세스가 살아 있으므로 heartbeat도 다시 띄우지 않는다.

## 4. 타임라인

### 4.1 수정 전 (2절 예시, 10-22 14:39 재현의 실제 시각)
| 시각 | coordinator | worker 10개 | 밖에서 보이는 것 |
|---|---|---|---|
| 14:39:05 | | | master 부하 시작 |
| 14:39:06 | (이전 applier kill -9) | | slave 행 682에서 멈춤 |
| 14:39:20 | 다시 뜸. 로그를 읽다가 recovery range 첫 커밋을 보내고 결과를 기다림(★A) | 서버 접속 중(훅이 10초 지연) | applier 프로세스 있음 |
| 약 14:39:30 | pop에서 잠들어 있음 | 10개 모두 시작 실패. 마지막 worker가 `la_applier_need_shutdown = true`(★C) | 로그 "0 of 10 workers remain" |
| 14:40:30 | 계속 잠들어 있음. 종료 플래그를 보지 않음(★B) | 없음 | 프로세스 살아 있음. 스레드 3개, 행 682 그대로 |
| 14:40:30 | | | SIGTERM을 보냄 |
| 14:41:05 | 계속 잠들어 있음 | | **SIGTERM 30초 뒤에도 살아 있음** |

멈춘 프로세스의 스택(gdb):
```
#0 pthread_cond_wait
#1 la_result_queue_pop                  log_applier_result_queue.cpp:180
#2 la_coordinator_wait_until_retired    log_applier.c:1050
#3 la_coordinator_submit_task           log_applier.c:7562   ← recovery range 경로
#4 la_coordinator_process_commit        log_applier.c:7813
```

### 4.2 수정 후 (같은 조건, 10-22 15:28 재현의 실제 시각)
| 시각 | coordinator | worker 10개 | 밖에서 보이는 것 |
|---|---|---|---|
| 15:28:46 | (이전 applier kill -9) | | slave 행 3919에서 멈춤 |
| 15:28:48 | 다시 뜸. recovery range 첫 커밋 `351\|9808`(저장된 last committed `351\|9640` 다음)을 보내고 결과를 기다림. 100ms마다 결과와 종료 플래그를 확인 | 서버 접속 중(훅 10초 지연) | |
| 15:28:58.204 | | 10개 모두 시작 실패. 종료 플래그가 섬 | 로그 "0 of 10 workers remain" |
| 직후 | 다음 확인에서 종료 플래그를 보고 대기를 끝냄 → 메인 루프 종료 → `la_shutdown` → 프로세스 종료 | | |
| 15:29:00.2 | heartbeat가 applier를 새로 띄움 | 새 worker 10개 시작 | 훅이 남아 있는 동안 "시작 → 실패 → 종료 → 재시작" 반복 |
| 15:30:00 | (훅 파일 제거 뒤) 정상 적용 | 정상 | 행 6000, 양쪽 같음 |

받지 못한 결과의 트랜잭션은 retire되지 않았으므로 재시작 지점이 그 앞에 머문다. 다시 뜬 applier가 그 지점부터 다시 적용한다. 행 항목은 recovery range 오류 skip으로, statement 항목은 [C17](C17_recovery_range_statement_reapply.md)의 마커로 두 번 적용되지 않는다.

## 5. 재현

### 5.1 시험 훅
worker를 일부러 시작에 실패시키는 훅을 넣어 재현했다(`la_worker_main` → `la_worker_test_fail_start`). 재현과 수정 확인이 끝난 뒤 브랜치에서 뺐다(7.3절).
| 환경변수 | 의미 |
|---|---|
| `CUBRID_HA_TEST_WORKER_FAIL_START=<파일 경로>` | 그 파일이 있으면, 시작하는 worker가 모두 `la_worker_startup_failed`로 빠진다(이유 `test_fail_start`) |
| `CUBRID_HA_TEST_WORKER_FAIL_START_MSEC=<ms>` | 실패하기 전에 그만큼 기다린다. 서버 접속을 시도하다 실패하는 시간을 흉내 낸다 |

환경변수는 HA를 올릴 때 한 번 넣고, 훅은 파일을 만들고 지우는 것으로 켜고 끈다. 환경변수가 없으면 아무 일도 하지 않는다.

### 5.2 방법 (`ha_bench_tool/bin/c4_worker_loss.sh`)
1. youngjun4(slave)를 두 환경변수와 함께 다시 올린다(파일은 없음, 정상 동작). applier 환경에 들어갔는지 `/proc/<pid>/environ`으로 확인한다.
2. master: `CREATE TABLE c4_t`, 4세션이 각각 `ROWS`행을 한 행에 커밋 하나로 넣는다.
3. 부하 시작 `KILL_AFTER`초 뒤 youngjun4에 훅 파일을 만들고 applylogdb를 kill -9한다. 비정상 종료라 recovery range가 생긴다.
4. heartbeat가 다시 띄운 첫 applier가 60초 뒤에도 살아 있으면 HANG, 종료했으면 NO HANG으로 판정한다.
5. SIGTERM을 보내고 30초 안에 끝나는지 본다.
6. 훅 파일을 지우고(남아 있으면 kill -9), 양쪽 c4_t를 비교하고, youngjun4를 환경변수 없이 다시 올린다.

### 5.3 시도 기록 (빌드 2780·2781, 수정 전)
| 시도 | 조건 | 결과 | 멈추지 않은 이유 |
|---|---|---|---|
| 1 (13:57) | 지연 없음, ROWS 5000 | 시작 → 실패 → 종료를 17번 반복. 멈추지 않음 | worker가 0ms에 실패해 종료 플래그가 먼저 섬. coordinator는 메인 루프에 들어가자마자(2ms) 플래그를 보고 끝남. 작업을 보내기 전이라 pop까지 가지 않음 |
| 2 (14:36) | 지연 10초, ROWS 5000 | 멈추지 않음 | recovery range 앞의 커밋을 9753개 읽는 동안 commit-order(용량 10240)가 가득 참. 그 대기(`la_coordinator_wait_for_commit_order_slot`)는 종료 플래그를 보므로 빠져나옴. recovery range에 닿지 못함 |
| 3 (14:39) | 지연 10초, ROWS 1500, KILL_AFTER 1 | **멈춤**(4.1절) | |

멈추려면 두 조건이 함께 있어야 한다. 하나는 worker가 coordinator보다 늦게 실패하는 것이고, 다른 하나는 coordinator가 recovery range 커밋까지 읽는 것이다. 실제로 서버 접속이 안 되는 경우는 접속 시도 시간만큼 실패가 늦으므로 첫 조건을 만족한다(추정).

### 5.4 결과 비교 (같은 조건: 지연 10초, ROWS 1500, KILL_AFTER 1)
| 항목 | 수정 전 (2781-eab1906) | 수정 후 (2782-83976cb) |
|---|---|---|
| 다시 뜬 applier가 기다린 곳 | recovery range 첫 커밋의 결과(스택 확인) | 같은 곳(로그로 확인: range 첫 커밋을 읽은 뒤 schedule 기록 없음) |
| worker 모두 실패한 뒤 | 60초 넘게 살아 있음 → **HANG** | 2초 안에 다음 applier가 뜸 → **NO HANG** |
| SIGTERM | 30초 뒤에도 살아 있음 | 종료됨 |
| 훅 파일 제거 뒤 c4_t (행 수, sum(v)) | 6000 / 4503000, 양쪽 같음 | 6000 / 4503000, 양쪽 같음 |
| fail_counter | 양쪽 0 | 양쪽 0 |

- 결과 디렉터리: `ha_bench_tool/log/c4_worker_loss_20261022_143902/`(수정 전), `c4_worker_loss_20261022_152811/`(수정 후). 시도 1·2는 `_135755/`, `_143625/`.
- 수정 후 SIGTERM에 6초가 걸린 것은 다시 뜬 applier의 worker가 훅의 10초 지연 안에서 자고 있었기 때문이다. 종료할 때 worker를 join한다.
- applier의 종료 시각은 로그에 따로 남지 않는다. "2초 안"은 worker 실패 뒤 다음 applier가 뜬 시각으로 판단했다.

## 6. 수정 (`6ae74828a`)
```c
/* log_applier.c */
static int
la_coordinator_pop_result (LA_RESULT * result)
{
  while (true)
    {
      if (la_result_queue_try_pop (result) == NO_ERROR)
	{
	  return NO_ERROR;
	}

      if (la_applier_need_shutdown)          // 종료 플래그를 직접 본다
	{
	  return ER_FAILED;
	}

      (void) la_result_queue_wait_for_result (100);   // 결과가 오면 바로 깨고, 아니면 100ms 뒤 다시 확인
    }
}
```
- `la_coordinator_wait_until_retired`와 `la_coordinator_wait_for_inflight_slot`이 `la_result_queue_pop` 대신 이 함수를 쓴다.
- 이미 있던 `la_coordinator_wait_for_commit_order_slot`(742)과 같은 방식이다. 이 함수는 원래부터 종료 플래그를 확인하고 100ms씩 기다렸다.
- 쓰는 곳이 없어진 `la_result_queue_pop`은 지웠다. 무기한 대기 함수를 남겨 두면 다시 쓰일 수 있기 때문이다.
- 시그널 핸들러는 그대로 플래그만 세운다. 핸들러 안에서 조건 변수를 깨우는 것은 안전하지 않으므로(async-signal-safe가 아님), 기다리는 쪽이 플래그를 확인하는 방식을 택했다.
- 결과가 오면 timedwait가 바로 깨므로 평소 적용 지연은 없다.

## 7. 판단과 남는 점

### 7.1 worker만 다시 살리지 않는 이유
이 수정은 죽은 worker를 되살리지 않는다. applier 프로세스를 끝내고 heartbeat가 다시 띄우게 한다. 이 브랜치는 원래부터 그렇게 설계되어 있었다. 마지막 worker가 실패하면 `la_request_shutdown`을 부르게 되어 있었고, 수정은 그 요청이 대기 중인 coordinator에게 전달되게 한 것뿐이다.

| worker만 다시 살리려면 | 어려운 점 |
|---|---|
| 같은 프로세스 안에서 클라이언트 세션을 다시 열기 | 세션 재연결 경로(`db_restart_sub` 등)는 예전에 보류한 항목 |
| 죽은 worker가 들고 있던 작업 되찾기 | 큐에서 이미 꺼낸 작업이라 따로 기록해 다시 넣어야 함 |
| 원인이 남아 있을 때 재시도 | 서버 접속 불가라면 다시 살려도 또 실패. 재시도 간격·횟수 정책이 필요 |

프로세스를 다시 시작하면 모든 상태를 저장된 apply info에서 다시 만든다. 이 경로는 kill -9 시험(C1, C17, C4)으로 검증되어 있다. develop applier도 서버에 접속하지 못하면 오류로 끝나고 heartbeat가 다시 띄운다.

### 7.2 멈추지 않는 다른 경우 (코드 확인)
| 경우 | 동작 |
|---|---|
| worker 일부만 시작 실패 | 남은 worker가 작업을 가져가 계속 적용한다. 종료 요청도 없다 |
| 적용 중 서버 다운 등으로 worker가 빠짐(`apply_failed`) | worker는 결과(오류)를 큐에 넣고 빠진다(`la_worker_run`). 작업 큐는 FIFO라 꺼낸 작업이 언제나 안 꺼낸 작업보다 앞에 있다. 그래서 retire는 안 꺼낸 작업에 닿기 전에 그 오류에 먼저 닿고, coordinator가 오류로 끝난다. 종합 문서가 "추정"으로 남긴 경우이고, 수정 전에도 멈추지 않는다 |
| worker가 살아 있지만 잠금 대기 등으로 결과가 늦음 | 수정 전에는 SIGTERM이 결과가 올 때까지 미뤄졌다. 수정 후에는 coordinator가 100ms 안에 대기를 끝낸다. 종료 시 worker join은 그 worker가 끝날 때까지 기다린다 |

### 7.3 시험 훅
재현에 쓴 훅 두 커밋(`1f49bdde7`, `eab1906ac`)은 브랜치에서 뺐다. 수정 전 멈춤, 멈춘 위치, 수정 후 같은 조건에서 빠져나오는 것을 모두 확인했고, 수정이 작아 코드로도 확인할 수 있으며, 시험 전용 코드는 정식 PR 전에 어차피 빼야 하기 때문이다. 결과 대기 쪽을 다시 고칠 때(8절 2번의 worker 수 유지 등) 다시 필요하면 백업 브랜치 `backup/c4-with-hooks-20261022`에서 두 커밋을 가져오고, 5.2절의 하니스와 5.4절의 조건(지연 10초, `ROWS=1500`, `KILL_AFTER=1`)으로 돌린다.

## 8. 열린 질문
1. 실제 운영에서 worker가 모두 시작에 실패하는 원인(서버 접속 불가, `max_clients` 초과 등)에서 실패까지 걸리는 시간. 5.3절의 첫 조건을 실제로 만족하는지는 추정이다.
2. 빠진 worker를 다시 띄워 설정한 worker 수를 유지할지. 지금은 worker 일부가 시작에 실패하면 남은 worker로 계속 돌고, 병렬도가 줄어든 것은 로그 한 줄로만 남는다. 다시 띄우면 원인이 일시적인 경우 결과가 다시 들어와 C4 같은 대기 자체가 생기지 않는다. 다만 원인이 프로세스 바깥(서버 접속 불가 등)에 남아 있으면 다시 띄운 worker도 실패하므로 재시도 간격·횟수가 필요하고, 포기할 때는 지금처럼 applier를 끝내야 한다(6절의 수정 경로). 코드 TODO: `la_worker_startup_failed` 주석(C4 수정 커밋에 함께 들어감).
