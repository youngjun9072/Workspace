---
tags: [CBRD-27508, applier, fixes, 보류]
---
# 재시작 복구 구간 직렬화 (보류)

작성: 2026-10-15. 작업 목록 ① 3번. **보류 결정(10-15)**: 재시작 테스트 전에는 교착 시나리오를 확정할 수 없으므로, 결함 4 수정 → 재시작 테스트 → 직렬화 필요가 증명되면 반영. 코드 변경 없음. 관련 todo: `todo/CBRD-27508 - recovery_range_open 플래그 제거`, `todo/CBRD-27508 - 복구 구간 statement 재적용`.

줄 번호는 커밋 a6f4f225c 기준.

## 한 줄 요약

재시작 후 복구 구간(이전 런이 이미 적용했을 수 있는 커밋 범위)의 트랜잭션을 병렬로 다시 적용하면, 이미 slave에 있는 행 위에서 두 트랜잭션이 마스터에서는 공유한 적 없는 행 락을 엇갈려 잡아 교착할 수 있다. 이를 막는 `la_coordinator_serialize_recovery_range`가 있으나 호출이 꺼져 있고, 실제로 교착을 막는지도 미검증이다.

## 근거가 된 사건

10-11 load20 2차(`_notes/load20-test-20261011-run2.md` 결함 3). 재기동 후 복구 구간(74503|1928 ~ 74524|13888)에서 마스터에서 독립이던 두 트랜잭션(부모 REF 키만 공유)이 병렬 재적용되어 워커끼리 교착 9건. 정상 운영 13분 동안은 0건. 당시 영구 정지의 직접 원인은 결함 4(교착 희생자가 락을 놓지 않음)였고, 어느 락이 엇갈렸는지는 미확인. 상세: `_notes/serial-guarantee-analysis-20261012.md` §3.

## 단계별 코드

### 단계 1. 복구 구간의 정의

`log_applier.c` `LA_INFO`.

```c
325   /* upper bound of the restart recovery range: max_committed_lsa as stored in _db_ha_apply_info at boot,
326    * or NULL (empty range) when none was stored. Set once at boot; workers only read it. */
327   LOG_LSA recovery_boundary_lsa;
...
335   bool recovery_range_open;        /* 첫 커밋이 boundary를 넘을 때까지 true */
```

재시작하면 `committed_lsa`부터 다시 읽고, `recovery_boundary_lsa`(이전 런이 저장한 `max_committed_lsa`)까지가 복구 구간이다. 이 안에는 이전 런이 커밋한 것과 못 한 것이 섞여 있다.

### 단계 2. 직렬화 함수 (호출 꺼짐)

```c
1053 la_coordinator_serialize_recovery_range (LA_TASK * task)
1054 {
...
1057   if (!la_Info.recovery_range_open)
1058     {
1059       return;
1060     }
1061
1062   if (LSA_GT (&task->commit_lsa, &la_Info.recovery_boundary_lsa))
1063     {
1064       la_Info.recovery_range_open = false;         /* 구간을 넘는 첫 태스크까지 한 번 더 처리 */
1065     }
1066
1067   if (!la_gate_get_order_tail (&previous_lsa))      /* 바로 앞에 받아들인 커밋 */
1068     {
1069       return;
1070     }
1071
1073   if (LSA_ISNULL (&task->dependency_seq) || LSA_GT (&previous_lsa, &task->dependency_seq))
1074     {
1075       LSA_COPY (&task->dependency_seq, &previous_lsa);   /* 의존을 직전 커밋으로 올려 게이트가 하나씩 통과시킴 */
1076     }
```

### 단계 3. 호출 자리

`la_coordinator_submit_task`.

```c
7489   /* TODO: re-enable after the restart deadlock is analyzed; see la_coordinator_serialize_recovery_range */
7490   /* la_coordinator_serialize_recovery_range (task); */
7491   error = la_gate_order_push (&task->commit_lsa);
```

10-12에 주석 처리. 복구 구간도 지금은 일반 구간처럼 병렬 적용된다.

### 단계 4. 복구 구간의 재적용 오류 처리 (별개, 동작 중)

`la_apply_repl_log` 7043~7046에서 `stats->in_recovery_range`를 세우고, flush 오류 경로 6016~6046에서 INSERT unique 중복·UPDATE/DELETE 대상 없음을 `recovery_skipped_counter`로 삼킨다. 이는 "이미 적용된 트랜잭션의 재적용 오류"를 다루는 것이고, 교착은 다루지 않는다.

## 왜 문제인가 (가능성, 미확정)

마스터 라벨은 "커밋 순서의 어느 지점까지 빈틈없이 반영된 상태" 위에서의 충돌 정보다. 복구 구간은 뒤 트랜잭션까지 반영된 상태 위에 앞 트랜잭션을 다시 적용하므로 이 전제가 깨진다. 마스터에서 독립이던 두 트랜잭션이 slave에서는 같은 행(이미 있는 행의 unique 검사, 상태가 바뀐 부모 행의 FK 검사 등)을 건드려 락이 엇갈릴 수 있다(추정). 결함 4를 고치면 교착이 나도 희생자가 재시도되어 진행은 되므로, 직렬화가 "정확성"에 필요한지 "교착 회피"에만 필요한지는 재시작 테스트로 가른다.

## 해결 방안

### 보류 중 결정 순서 (refactor-plan 10-12와 동일)

1. 결함 4(교착 희생자 락 해제·재시도)만 고치고 호출을 끈 채 재시작 테스트. 교착이 나도 재시도로 진행되는지, 데이터 일치하는지.
2. 교착이 나면 락 덤프로 엇갈린 락 확정.
3. 직렬화가 필요하면 아래 방식으로 반영. 아니면 함수·플래그 삭제.

### 필요해졌을 때의 방식: 하나 넘기고 retire까지 기다리기 (10-15 논의)

주석 함수를 되살리지 않고, 워커 1개 분기(05 문서)와 같은 자리에 붙인다.

```c
  if (la_Info.worker_count == 1 || la_task_is_in_recovery_range (task))
    {
      /* One worker takes the FIFO queue in commit order by itself. In the restart recovery range with more
       * workers the coordinator also waits for the task to retire, so transactions that may already be on
       * the slave never run beside each other and deadlock on rows the master never had them share. */
      error = la_coordinator_dispatch_task (task, LA_SCHED_DISPATCHED);
      if (error != NO_ERROR || la_Info.worker_count == 1)
        {
          return error;
        }
      return la_coordinator_wait_until_inflight_empty ();   /* wait_for_dispatch_slot과 같은 수거 루프, 조건만 count == 0 */
    }
```

`la_task_is_in_recovery_range` = `!LSA_ISNULL (&recovery_boundary_lsa) && LSA_LE (&task->commit_lsa, &recovery_boundary_lsa)`.

| | 주석 함수(의존 올리기) | 넘기고 기다리기 |
|---|---|---|
| 원리 | 게이트가 한 번에 하나만 통과 | 큐에 동시에 하나만 있게 코디네이터가 대기 |
| 구간 끝 | 구간 지난 첫 태스크도 한 번 대기, `recovery_range_open` 필요 | 자동. 플래그 불필요 |
| 코디네이터 | 계속 읽어 pending에 쌓음 | 구간 안에서는 읽기도 멈춤(구간이 짧아 무시 가능) |
| 코드 | 있음(30줄)+플래그 | 조건 1개+대기 함수 1개 |

직렬은 워커를 줄여서가 아니라 큐에 동시에 하나만 두어서 만든다. 큐는 원래 하나(`la_Shared_task_queue`)라 어느 워커가 집는지는 고르지 않는다. 채택 시 `la_coordinator_serialize_recovery_range`, `recovery_range_open`, 관련 TODO 삭제.

## 적용 상태와 검증

- 코드 변경 없음. 재시작 테스트(작업 목록 7번)에서 결정.
- 재시작 테스트: 백로그 중 applylogdb kill -9 → heartbeat 재기동 → 복구 구간 병렬 재적용. 확인: 교착 발생 여부(`[WSET] worker error` -72 계열), 재시도로 진행되는지, master/slave 데이터 일치, `recovery_skipped_counter`.

## 상세 설계용 요약 (8-2.7 재시작 또는 7장 후보)

### 왜 이런 처리가 필요한가(필요하다면)

병렬 적용의 정확성은 "slave가 frontier까지 빈틈없이 반영된 상태"라는 전제 위에 마스터 라벨을 적용해서 얻는다. 재시작 직후의 복구 구간은 이 전제가 깨진 유일한 구간이다. 그래서 이 구간만은 마스터 라벨을 믿지 않고 커밋 순서대로 하나씩 적용하는 것이 안전한 선택지이며, 그 비용은 재시작 직후 짧은 구간에 한정된다. 다만 이것이 정확성에 필요한지 교착 회피에만 필요한지는 미확정이고, 적용된 커밋을 기록해 재적용 자체를 건너뛰면(완료 표식 설계) 구간 자체가 없어진다.

### 설계 요구사항(후보)

- 복구 구간 = `[committed_lsa, recovery_boundary_lsa]`. 구간 안 태스크는 동시에 하나만 적용된다.
- 구간을 넘는 첫 태스크는 구간 마지막 태스크가 retire된 뒤에 적용된다.
- 구간 밖 동작은 변하지 않는다.
