# C1. master 재시작 경계가 slave commit-order ring에 없어서 첫 라벨 커밋이 영구 대기

## 1. 메타
| 항목 | 내용 |
|---|---|
| 등급 | High |
| 상태 | **방어 코드로 유지(10-23).** 수정 `ac9aa4bf7`(안 A', 단위 테스트 포함). 단위 테스트 25건 통과(10-21). HA 시험 2회(10-21 수정 전, 10-23 수정 후) 모두 정지 조건이 만들어지지 않아(MASKED) 수정 경로는 HA에서 실행되지 않음(9.3절). 재현 커밋 `fc27d96b1`은 수정 커밋에 접음(접기 전 기록: 브랜치 `backup/c1c2-before-fold-20261021`) |
| 판정 | 코드 경로는 확정. HA에서는 영구 정지가 재현되지 않음(10-21, 10-23 모두 MASKED). 2노드 상호 구성에서는 재시작 직후 applylogdb의 apply info 갱신 커밋이 먼저 들어와 정지 조건을 가린다(9.3절). 단위 테스트로 정지 조건을 재현함(4.2절). 가림막이 없는 구성(replica 등)이나 순서에서 생길 수 있는 경로라 방어 코드로 둔다 |
| 신규/기존 | 신규. master 쪽은 a7577f913(Master-side writeset generation), slave gate는 45825ca17(Slave-side parallel applylogdb) |
| 관련 이슈 | C2(overflow 라벨에 하한이 빠짐, 같이 수정해야 함), C6(drain 백스톱 미동작, 이 정지를 끊지 못함) |
| 지적한 리뷰어 | 9명: architect_1y(U1), architect_5y, architect_10y(Critical), sysdev_1y, sysdev_5y, sysdev_10y, appdev_5y, qa_3y, qa_5y, qa_10y |

## 2. 문제 요약
master는 재시작할 때 writeset history 하한(history_start)을 복구 직후의 로그 끝(`append_lsa`, 이하 **R**)으로 올린다. 재시작 뒤 커밋의 라벨은 R 이상이 된다. 그런데 R은 커밋 LSA가 아니어서 slave의 commit-order ring에 올라가지 않는다. slave gate는 "frontier ≥ 라벨"일 때만 통과시키고, frontier는 ring에 있는 커밋으로만 전진한다. 그래서 재시작 뒤 **첫 커밋**의 라벨이 R이면, 그 커밋은 자기 자신이 끝나야 넘을 수 있는 조건을 기다리며 영원히 park된다. 뒤의 커밋도 모두 그 뒤에 막힌다. 오류는 남지 않는다.

## 3. 문제 분석
이 절의 코드 위치는 수정 전 `0e411f10f` 기준이다.

### 3.1 용어
| 용어 | 뜻 |
|---|---|
| 라벨(dependency) | master가 커밋 직전에 남기는 LSA. 뜻은 "이 LSA 이하의 커밋이 모두 적용된 뒤에 나를 적용하라" |
| history_start | master가 라벨 값의 하한으로 쓰는 LSA. 모든 라벨은 이 값 이상으로 올려진다 |
| R | master 재시작 시 history_start로 쓰이는 값. 복구 직후의 `log_Gl.hdr.append_lsa` |
| commit-order ring | slave coordinator가 읽은 커밋을 LSA 순서대로 넣는 링 |
| frontier | ring의 head부터 끊김 없이 적용이 끝난 마지막 커밋 LSA |

### 3.2 master: R은 로그에 남지 않는 위치다
`src/transaction/log_manager.c:1503-1514`
```c
  /* Restart boundary for the writeset history. ... Every label floors at history_start, so raising it to
   * the end of the recovered log makes every later replicated commit wait on the slave until everything
   * written before the restart has been applied ... Nothing is written to the log for this; the labels of
   * the first commits after the restart carry it. */
  {
    const LOG_LSA restart_lsa = log_Gl.hdr.append_lsa;

    wset_raise_history_start (&restart_lsa, "RESTART");
  }
```
- R은 다음에 기록될 레코드의 위치일 뿐이고, 어떤 커밋의 LSA도 아니다.
- history_start를 올리는 다른 곳은 모두 slave ring에 있는 LSA를 쓴다.
  - history clear: `wset_clear_history_locked (&wset_History.prev_commit_lsa, ...)`, `writeset.cpp:1251, 1297, 1307, 1314`. 직전 커밋 LSA다.
  - serial sysop: `wset_raise_history_start (&sysop_lsa, "SYSOP_COMMIT_ORDER")`, `log_manager.c:4071`. slave가 SYSOP_END를 task로 만들거나 `la_coordinator_complete_without_task`로 ring에 올린다(`log_applier.c:7446-7500`).
- 따라서 ring에 없는 값은 **RESTART 하나뿐**이다.

### 3.3 slave: gate는 ring에 있는 커밋으로만 전진한다
`src/transaction/applier/log_applier_gate.cpp:281-291`
```c
bool
la_gate_is_satisfied (const LOG_LSA *dep)
{
  if (LSA_ISNULL (dep))
    return true;
  return !LSA_ISNULL (&la_Gate_frontier) && LSA_LE (dep, &la_Gate_frontier);
}
```
`log_applier_gate.cpp:219-235` (`la_gate_advance_frontier`): head가 완료됐을 때만 frontier를 head의 커밋 LSA로 옮기고 head를 뺀다.

`src/transaction/log_applier.c:7371-7427` (`la_coordinator_submit_task`, worker > 1):
1. `la_gate_order_push (&task->commit_lsa)`로 자기 커밋을 ring에 먼저 넣는다.
2. `la_gate_is_satisfied (&task->dependency_seq)`가 거짓이면 pending에 park한다.
3. pending은 `la_coordinator_drain_ready`에서 같은 함수로 다시 판정한다(`log_applier_pending.cpp:107`).
- ring head를 예외로 통과시키는 경로는 없다. `la_gate_is_satisfied` 호출부는 위 두 곳뿐이다.
- `log_applier.c:733`의 주석("ring의 가장 오래된 커밋은 앞의 커밋이 모두 적용됐으므로 항상 gate를 통과한다")은 라벨이 커밋 LSA라는 전제에서만 맞다.

### 3.4 정지가 생기는 순서 (예시 하나로 고정)
| 단계 | master | slave |
|---|---|---|
| 1 | 마지막 커밋 P = 100\|0 | P까지 적용됨. frontier = 100\|0, ring 비어 있음 |
| 2 | 재시작. 복구 후 append_lsa = 105\|0 → R = 105\|0 | 대기 |
| 3 | 첫 커밋 C1 = 106\|200. 충돌 키 없음 → 라벨 = max(없음, R) = 105\|0 | C1 push → ring = [C1(미완료)] |
| 4 | | gate: 105\|0 ≤ frontier 100\|0? 아니오 → C1 park |
| 5 | C2 = 107\|0, 라벨 ≥ 105\|0 | C2 push, park |
| 6 | 이후 모든 커밋 | 모두 park. frontier는 100\|0에서 멈춤 |

C1이 끝나야 frontier가 106\|200으로 가는데, C1은 frontier가 105\|0을 넘어야 시작한다. 그래서 C1이 스스로를 기다리는 셈이 된다.

### 3.5 왜 지금까지 드러나지 않았나 (추정)
R과 C1 사이에 **라벨 없는 커밋**이 하나라도 있으면, 그 커밋은 바로 통과하고 완료되면서 frontier를 R 위로 올린다. 오늘 시험에서는 다음이 그 역할을 했다고 본다.
1. **DB 재생성 직후**: 하니스가 DDL부터 실행한다. DDL은 overflow 경로라 history_start 하한을 받지 않아 라벨이 NULL이다(C2).
2. **failback 뒤**: 옛 master가 slave로 있는 동안 적용한 트랜잭션들의 커밋(복제 로그 없음)이 새 로그 앞쪽에 있다.
3. **일반 HA 재시작**: master 쪽 applylogdb가 기동하면서 `_db_ha_apply_info`를 갱신하고 master에서 커밋한다. 이 커밋이 첫 사용자 커밋보다 먼저 오면 가려진다(확인 안 함).

**C2를 고치면 1번 가림막이 사라진다.** 그러면 이 정지는 더 쉽게 드러난다.

## 4. 발생 조건과 재현 방법

### 4.1 발생 조건 (모두 만족)
1. slave의 `ha_apply_worker_count > 1`이다. worker 1이면 FIFO 경로라 gate를 보지 않는다(`log_applier.c:7378`).
2. master 서버가 재시작했다. 장애 재시작, HA 전체 재시작, failback으로 다시 master가 되는 경우 모두 해당한다.
3. 재시작 뒤 slave가 R 이후로 처음 읽는 커밋이 라벨 있는 커밋이고, 그 라벨이 R이다. 앞에 충돌 키가 없으면 R이 된다.

### 4.2 재현 방법 A: 단위 테스트 (결정적)
`unit_tests/log_applier/test_log_applier_gate.cpp`의 `"gate passes the first commit after a master restart whose label is the restart floor"`.

| 값 | 뜻 |
|---|---|
| p = 100\|0 | 재시작 전 마지막 커밋. slave에서 적용 완료, frontier |
| r = 105\|0 | master 재시작 하한 R. 커밋이 아님 |
| c1 = 106\|200 | 재시작 뒤 첫 커밋, 라벨 = r |

- 재현 커밋(`fc27d96b1`, 지금은 `ac9aa4bf7`에 접힘)의 테스트는 지금 coordinator 순서 그대로 `la_gate_set_initial_frontier (p)` → `la_gate_order_push (c1)` → `la_gate_is_satisfied (r)`를 확인한다.
- 결과(10-21): `REQUIRE( la_gate_is_satisfied (&r) )`가 `false`로 실패했다. c1은 park되고 frontier는 p에 머문다. `[!shouldfail]` 태그를 붙여 스위트는 통과시켰다(22건 중 21 통과, 1건 예상 실패).
- 이 테스트는 입력을 직접 넣는다. 같은 입력이 실제 로그에서 생긴다는 근거는 4.4절이다. 라벨 = R인 첫 사용자 커밋이 park된 것까지는 실제로 관측했다.

### 4.3 재현 방법 B: HA 시험
1. HA 정상 상태에서 테이블 `t (id INT PRIMARY KEY)`를 미리 만들어 둔다. slave에 반영된 것을 확인한다.
2. `ha_writeset_trace_level`을 1 이상으로 둔다. master에서 `HISTORY_START raise reason=RESTART`, slave에서 schedule/park 로그를 보기 위해서다.
3. `cubrid service stop`(slave 먼저, 그다음 master) → `cubrid hb start`(master 먼저, 그다음 slave). slave가 standby가 될 때까지 기다린다.
4. **다른 쓰기 없이** master에서 `INSERT INTO t VALUES (1); COMMIT;` 한 건만 실행한다.
5. 30초 뒤 slave에서 `SELECT * FROM t WHERE id = 1`을 조회하고, `cubrid applyinfo`의 apply 지연을 본다.
6. 판정:
   - 재현: 행이 없고, apply 지연이 늘며, applier 로그에 `reader schedule trid=... dependency=<R> status=2`(park)가 남는다.
   - 가려짐: 행이 있다. 이때는 slave applier 로그에서 R과 C1 사이에 `items=0 has_label=0` 커밋이 있었는지 확인해, 3.5절의 어느 경우인지 기록한다.
- HA 재시작은 사용자 지시가 있어야 실행한다.
- 스크립트: `ha_bench_tool/bin/c1_restart_stall.sh`

### 4.4 재현 결과 (2026-10-21 00:06, `ha_bench_tool/log/c1_restart_20261021_000646/`)
판정은 **MASKED**다. 정지 조건은 로그에 그대로 나타났지만, 앞에 있던 라벨 없는 커밋이 풀어 줬다.

| LSA | 내용 | slave 처리 |
|---|---|---|
| 1824183\|10304 | master R (`HISTORY_START raise reason=RESTART`) | ring에 없음 |
| 1824183\|10688, 11080, 11456 | 라벨 없는 커밋 3건 (items=0) | 바로 dispatch(status=0) |
| 1824183\|13312 | 시나리오의 INSERT (trid 287454), dependency=1824183\|10304 | **park(status=2)**, 앞의 3건이 끝나 frontier가 R을 넘자 release(status=1, dispatch=12) |

- 행은 INSERT(00:07:24) 50초 뒤 slave에 보였다. 지연은 C1과 별개다. applier가 재시작 뒤 00:07:14~00:08:14 동안 recovering에 머물렀다(원인 미확인).
- 앞의 3건이 무엇인지는 확인하지 않았다. 재시작 직후 HA 프로세스가 master에 남긴 커밋으로 추정한다. 예를 들어 master 쪽 applylogdb의 `_db_ha_apply_info` 갱신이 있다.
- 결론: 가림막은 재시작 직후 생기는 이런 커밋이고, 이 커밋보다 사용자 커밋이 먼저 오면 정지한다(추정). 이 순서를 강제하는 재현 방법은 아직 없다. 4.2의 단위 테스트가 결정적 재현 수단이다.
- 같은 실행에서 따로 드러난 결함은 [C17](C17_recovery_range_statement_reapply.md)로 분리했다. 첫 실행에서 재시작 전 `CREATE TABLE c1_t`가 다시 적용되어 fail_counter가 1이 됐다.
- 첫 실행(23:55)은 youngjun4 `hb start`의 ssh가 원격 데몬에 출력 채널이 잡혀 끝나지 않아서 중단했다. 스크립트를 고친 뒤 위 결과를 얻었다.

## 5. 기대 결과
- master가 재시작한 뒤의 첫 커밋은, 재시작 전 커밋이 slave에 모두 적용되면 곧바로 적용된다.
- 라벨이 커밋 LSA가 아니어도 "이 LSA 이하의 커밋이 모두 적용됨"이라는 뜻대로 판정된다.
- failover 시 DONE 보류는 받은 로그를 다 적용하면 풀린다.

## 6. 실제 결과 / 예상 에러
- **에러 메시지 없음.** applier 프로세스는 살아 있고 `cubrid hb status`에서는 `registered`로 보인다.
- 증상:
  - `cubrid applyinfo`: copy 지연은 0 근처, apply 지연은 계속 증가
  - slave 데이터가 재시작 시점에서 멈춤
  - applier 로그(trace 1 이상): 첫 라벨 커밋 `status=2`(park), 이후 커밋 모두 park, `ws_gate frontier advanced` 없음
  - ring이 차면 coordinator가 `la_coordinator_wait_for_commit_order_slot`에서 결과를 기다리며 로그 읽기를 멈춤(`log_applier.c:735-760`). 결과를 낼 worker가 없어서 그대로 멈춤
- 이 상태에서 master가 죽어 failover되면:
  - slave applier는 `holds DONE: workers are still applying (pending=N ...)`를 남기고 DONE을 계속 보류한다.
  - drain 백스톱(30초)은 C6 때문에 실행되지 않는다.
  - 서버는 `to_be_active`에 머물러 승격이 무기한 막힌다.

## 7. 해결 방법

### 안 A' (채택): coordinator가 라벨을 직전 커밋으로 낮춤
- coordinator가 트랜잭션을 commit-order ring에 넣기 직전에 **직전 커밋**을 본다. 직전 커밋은 그 트랜잭션 바로 앞에 읽은 커밋으로, ring의 마지막 항목이다. ring이 비어 있으면 frontier를 직전 커밋으로 쓴다.
- 라벨이 직전 커밋보다 크면 라벨을 직전 커밋으로 낮춘다. 그렇지 않으면 그대로 둔다.
- 뜻이 바뀌지 않는 이유:
  - 라벨은 자기 커밋보다 작다.
  - 로그를 순서대로 읽으므로 직전 커밋과 자기 커밋 사이에는 다른 커밋이 없다.
  - 그래서 "라벨 이하가 모두 적용됨"과 "직전 커밋 이하가 모두 적용됨"은 같은 조건이다.
- 예시(3.4절 값):
  - C1을 읽기 직전의 커밋은 P(100)이다. 라벨 105 > 100이므로 100으로 낮추고, frontier가 100에 이르면 C1이 실행된다.
  - 다음 커밋 C2(110)의 라벨이 106(C1)이면 직전 커밋 106보다 크지 않으므로 그대로 둔다.
- **정상 라벨은 영향을 받지 않는다.** 라벨이 이미 읽은 커밋이면 항상 직전 커밋 이하다. 직전 커밋보다 큰 라벨은 커밋이 아닌 위치뿐이다.
- **gate 판정(`라벨 ≤ frontier`)과 frontier, ring은 바꾸지 않는다.** 설계의 frontier 개념을 그대로 둔다.
- 정규화는 ring에 넣는 순간에 한 번만 해야 한다. park된 작업을 나중에 다시 판정할 때는 ring 뒤에 다른 커밋이 더 들어와 있어서, ring 마지막 항목이 더는 그 작업의 직전 커밋이 아니다. 그래서 결과를 `task->dependency_seq`에 저장하고, 재판정도 같은 값을 쓴다.
- 직렬 경로(worker 1, 복구 구간)도 같은 push 지점을 거치므로 같이 적용된다. 이 경로는 gate를 보지 않아 결과는 같다.

**넣지 않은 것과 이유**
- 운영 알림 로그(NOTIFICATION): 안 A'는 커밋이 아닌 라벨이 어디서 왔든 같은 근거로 올바르게 처리한다. 로그가 남아도 운영자가 할 일이 없다. 개발 확인은 기존 WSET trace로 충분하다.
- assert(라벨 < 자기 커밋): master 코드상 깨질 수 없는 조건이다. 깨진다면 정규화가 아니라 master에서 잡아야 할 결함이다.

### 안 A: gate 판정을 ring의 가장 오래된 미완료 커밋과 비교
- 판정을 `라벨 < ring에서 가장 오래된 미완료 커밋`으로 바꾼다. ring에는 frontier보다 큰 커밋만 있으므로, 지금 규칙(`라벨 ≤ frontier`)을 포함한다.
- 채택하지 않은 이유: gate 판정의 기준이 frontier에서 ring head로 바뀐다. 설계 초기부터 써 온 frontier 개념을 바꾸는 변경이라, 같은 결과를 내는 안 A'를 택했다.

### 안 B: master가 재시작 경계를 ring에 올라가는 레코드로 남김
- 재시작 직후 라벨 없는 dummy 커밋, 또는 slave가 ring에 넣는 경계 레코드를 기록하고, history_start를 그 LSA로 둔다.
- 단점: 로그 레코드를 추가하거나 의미를 바꿔야 한다. 구 slave와 호환을 따져야 한다(C8과 같은 문제). 재시작 경로에서 로그를 쓰는 시점도 정해야 한다.

### 안 C: master가 R 대신 재시작 전 마지막 커밋 LSA를 하한으로 씀
- 뜻은 같다. 재시작 전 커밋이 모두 적용된 뒤라는 의미다.
- 단점: 재시작 뒤 마지막 커밋 LSA를 얻을 곳이 없다.
  - `wset_History.prev_commit_lsa`는 메모리 값이라 재시작하면 NULL로 초기화된다(`writeset.cpp:463, 490`).
  - 로그 헤더(`log_Gl.hdr`)에도 마지막 커밋 LSA 필드가 없다(`log_storage.hpp:140-165`).

| 얻는 방법 | 문제 |
|---|---|
| 복구 analysis에서 본 마지막 `LOG_COMMIT` | analysis는 checkpoint부터 읽는다. checkpoint 뒤에 커밋이 없으면 찾지 못한다 |
| 로그 헤더에 필드 추가 | 로그 헤더 형식이 바뀐다. slave가 받는 로그 복사본의 헤더도 같이 바뀌므로 구 버전 slave와의 호환을 따져야 한다 |
| 재시작 시 로그 끝에서 `back_lsa`로 거꾸로 찾음 | 커밋이 오래 없었으면 많이 읽어야 하고, 아카이브까지 내려갈 수 있다 |

- 나중에 다른 경로로 커밋이 아닌 하한이 생기면 같은 정지가 다시 생긴다.

### MySQL과의 비교
MySQL의 WRITESET 병렬 복제도 같은 대기 규칙(라벨 ≤ 적용 완료 위치)을 쓴다. 다만 이 정지를 막는 장치가 세 가지 있다. MySQL 9.7.0 소스(`Workspace/mysql-server-9.7`)로 확인했다.

| | CUBRID 브랜치 | MySQL |
|---|---|---|
| 커밋 번호 | 커밋 LSA (띄엄띄엄한 값) | `sequence_number` (빈틈 없는 정수 1, 2, 3, …) |
| 라벨 | dependency LSA | `last_committed` (commit parent) |
| frontier | ring head부터 끊김 없이 완료된 커밋 | lwm (low-water mark) |
| 라벨 하한 | `history_start` | `m_writeset_history_start` |

1. **라벨 하한은 언제나 실제 트랜잭션 번호다.** history를 비울 때 하한을 그 트랜잭션의 `sequence_number`로 둔다(`sql/rpl_trx_tracking.cc:321-324`). 번호에 빈틈이 없으므로, 하한에 해당하는 트랜잭션이 끝나면 lwm이 하한에 도달한다. R처럼 커밋이 아닌 위치는 하한이 될 수 없다.
2. **가장 오래된 트랜잭션은 기다리지 않는다.** 대기 조건은 `!clock_leq(last_committed, lwm_estimate) && rli->gaq->assigned_group_index != rli->gaq->entry`다(`sql/rpl_mta_submode.cc:384-385`). 대기 큐(GAQ)의 맨 앞이면 라벨과 관계없이 배정된다.
3. **재시작하면 번호를 다시 세고, 첫 트랜잭션은 전체 동기화한다.** 재시작이나 binlog 회전으로 새 파일이 시작되면 번호를 파일 기준으로 다시 세고 writeset 하한을 1로 둔다(`sql/rpl_trx_tracking.cc:199-204`, `371-379`). 이전 파일에 있는 parent는 `SEQ_UNINIT`으로 기록한다(`181-189`). slave는 `last_committed == SEQ_UNINIT`이거나 새 파일의 첫 이벤트이면 `is_new_group`으로 보고, 앞의 worker가 모두 끝난 뒤 실행한다(`sql/rpl_mta_submode.cc:347-376`). 재시작 경계를 라벨 비교가 아니라 "앞의 일이 모두 끝날 때까지 대기"로 처리하는 셈이다.

CUBRID 브랜치는 이 방식을 LSA로 옮기면서 세 장치를 모두 갖지 않았다. LSA는 띄엄띄엄한 값이라 1번이 성립하지 않고, 그래서 커밋이 아닌 R이 하한이 됐다. 2번과 3번도 없다.
- 안 A'는 1번이 지키는 성질(라벨은 실제 커밋을 가리킨다)을 slave 쪽에서 되살린다. 커밋이 아닌 라벨을 직전 커밋으로 낮춘다.
- 안 A는 2번을 일반화한 규칙이다.
- 안 C는 1번을 master 쪽에서 지키는 방식이다.

## 8. 구현 (안 A', `ac9aa4bf7`)

### 8.1 라벨 정규화 (`log_applier_gate.cpp`, `la_gate_bound_dependency`)
```c
bool
la_gate_bound_dependency (LOG_LSA *dep)
{
  LOG_LSA previous;

  assert (dep != NULL);

  if (LSA_ISNULL (dep))
    {
      return false;
    }

  if (!la_gate_get_order_tail (&previous) && !la_gate_get_frontier (&previous))
    {
      return false;
    }

  if (!LSA_GT (dep, &previous))
    {
      return false;
    }

  LSA_COPY (dep, &previous);

  return true;
}
```
- 직전 커밋은 기존 조회 함수로 얻는다. `la_gate_get_order_tail`은 ring 마지막 항목을, `la_gate_get_frontier`는 ring이 비었을 때의 frontier를 돌려준다.
- 단위 테스트에서 호출할 수 있게 gate 모듈에 두었다. gate 판정 함수 `la_gate_is_satisfied`는 바꾸지 않았다.

### 8.2 호출 위치 (`log_applier.c`, `la_coordinator_submit_task`)
```c
  la_gate_set_initial_frontier (&la_Info.committed_lsa);

  /* the master's restart floor is no commit; it becomes the latest commit read before this one */
  LSA_COPY (&label, &task->dependency_seq);
  if (la_gate_bound_dependency (&task->dependency_seq) && prm_get_integer_value (PRM_ID_HA_WRITESET_TRACE_LEVEL) >= 1)
    {
      _er_log_debug (ARG_FILE_LINE, "[WSET] reader label lowered trid=%d commit_lsa=%lld|%d label=%lld|%d "
                     "dependency=%lld|%d\n", ...);
    }

  error = la_gate_order_push (&task->commit_lsa);
```
- commit 작업과 serial SYSOP_END fragment 작업이 모두 이 함수를 거친다. 두 경우 모두 라벨이 R일 수 있으므로 한 곳에서 처리한다.
- trace(`ha_writeset_trace_level` ≥ 1)에 원래 라벨과 낮춘 값을 함께 남긴다. `reader commit` trace에는 원래 라벨이, `reader schedule` trace에는 낮춘 값이 찍힌다.

### 8.3 주석 정정
- `la_coordinator_wait_for_commit_order_slot`: "ring의 가장 오래된 커밋은 항상 gate를 통과한다"의 근거에 "라벨이 직전 커밋 이하로 유지된다(`la_gate_bound_dependency`)"를 더했다.
- `log_manager.c`의 RESTART 주석은 바꾸지 않았다. master는 그대로 R을 쓴다.

### 8.4 C2 (수정됨 `ae19759c4`, [C2 문서](C2_overflow_label_missing_history_floor.md))
```c
/* wset_find_dependency_from_history: overflow path */
if (tdes->wset_overflow)
  {
    lock seq_lock
    dep = prev_commit_lsa
    if (!LSA_ISNULL (history_start) && (LSA_ISNULL (dep) || dep < history_start))
      dep = history_start                  /* same floor as the normal path */
    unlock
    return dep
  }
```
- C2 수정으로 재시작 직후 DDL 라벨도 R이 된다. 안 A'가 들어갔으므로 이 경우도 직전 커밋으로 낮춰져 정지하지 않는다. 두 수정은 같이 배포해야 한다.

## 9. 검증

### 9.1 단위 테스트 (10-21, `build_ut_debug`, `test_log_applier`)
| 테스트 | 확인 내용 | 결과 |
|---|---|---|
| gate passes the first commit after a master restart whose label is the restart floor | 4.2절 값. 정규화 → push → 통과, frontier는 p 그대로 | 수정 전 실패(재현 커밋 `fc27d96b1`), 수정 후 통과 |
| gate lowers a restart-floor label to the latest commit on the ring and waits for it | ring [x(90), p(100)] 미완료 상태에서 라벨 r → p로 낮춤. p만 끝나면 대기, x와 p가 모두 끝나면 통과 | 통과 |
| gate keeps a label that is a commit already read | 라벨이 ring 마지막 커밋, 더 오래된 커밋, frontier, NULL이면 그대로 | 통과 |
| gate leaves a label as is before anything is read | frontier NULL, ring 비어 있음 → 그대로 | 통과 |

- 전체: 25건, 4304 assertion 통과. 기존 gate 테스트도 그대로 통과했다.
- `log_applier.c`를 포함한 `cubridcs`도 같이 다시 빌드됐다(오류 없음).
- CI 코드 스타일(`.github/workflows/codestyle.sh`, indent 2.2.11, astyle)에서 이번 변경분의 차이는 없다.

### 9.2 남은 검증
1. **HA 시험**: 4.3절. 수정 빌드를 배포한 뒤 실행한다. 이 시험으로는 수정된 동작을 보기 어렵다.
   - 라벨을 낮추는 것은 R과 첫 사용자 커밋 사이에 커밋이 하나도 없을 때뿐이다. 수정 전이라면 정지했을 경우다.
   - 가림막 커밋이 있으면(10-21 재현처럼 R 뒤에 라벨 없는 커밋이 먼저 옴) 직전 커밋이 R보다 크므로 라벨을 낮추지 않는다. 이때는 `[WSET] reader label lowered` 0건, 수정 전과 같은 park 후 release가 정상이다.
   - 가림막이 없는 순서를 만드는 절차는 아직 없다(11절 2, 3번). 그때까지 수정된 동작은 단위 테스트로 확인한 것이다. 다른 이슈의 시험에서 `label lowered`가 나오면 그 순서가 실제로 생긴 것이므로 기록한다.
2. **회귀**: 재시작 시험, F1, F4. 기준은 gate 순서 위반 0, compare 20/20.
3. **하니스 분석 확인 (10-21 완료, 코드 확인)**: `fk_multi_schema_test.py`의 `analyze()`는 slave trace의 `[WSET] reader commit ... dependency=` 값으로 순서를 판정한다. 이 줄은 `la_coordinator_submit_task` 호출 전에 찍히므로 **정규화 전 원래 라벨**이 들어간다.
   - 판정은 "dependency 이하의 적용된 커밋이 모두 끝나기 전에 시작했는가"다. P와 R 사이에 커밋이 없으므로 R 이하와 P 이하는 같은 커밋 집합이다. 수정 뒤에도 판정은 그대로 맞다.
   - 원래 라벨 기준으로 검사하므로, 정규화가 뜻을 약하게 만들었다면 위반으로 잡힌다.
   - `[WSET] reader label lowered`는 하니스 수집 패턴에 없다. 발생 여부는 applylogdb err 로그에서 직접 확인한다.
   - serial SYSOP_END fragment 작업은 `reader commit` 줄이 없어 원래부터 분석 대상이 아니다.

### 9.3 HA 시험 (10-23 17:23, 빌드 2786-8823088, `ha_bench_tool/log/c1_restart_20261023_172259/`)
하니스 `c1_restart_stall.sh`(`FIRST=ddl`)로 HA 전체를 재시작(slave → master 순 종료, master → slave 순 기동)한 뒤 DDL과 INSERT를 하나씩 실행했다.

| 항목 | 결과 |
|---|---|
| R (master `HISTORY_START raise reason=RESTART`) | `11136\|8184` |
| slave가 R 뒤에 읽은 커밋 | 29개. 그중 27개는 항목 없는 라벨 없는 커밋(items=0), 2개가 DDL과 INSERT |
| `[WSET] reader label lowered` | 0건 |
| INSERT 행 | 5초 안에 slave에 적용 |
| 판정 | MASKED (수정 경로는 실행되지 않음, 멈춤 없음) |
| 데이터, fail_counter | 양쪽 같음, 0 |

- 라벨 없는 빈 커밋이 R 뒤에 먼저 들어와 frontier를 R 위로 올렸다. 그래서 DDL의 라벨(R)은 이미 직전 커밋보다 아래라 낮출 필요가 없었다.
- 재시작한 master에 테스트 문장보다 먼저 접속한 클라이언트는 youngjun3 applylogdb(본체와 worker)뿐이었다(서버 접속 기록). 빈 커밋은 youngjun3 applylogdb가 `_db_ha_apply_info`를 갱신한 커밋이다(11절 2번).
- 이 가림막은 2노드 상호 구성에서 재시작할 때마다 생긴다. 상대 노드에 applylogdb가 없는 구성(replica)이나, 사용자 커밋이 그보다 먼저 오는 순서에서는 가림막이 없을 수 있다(추정). 그래서 수정은 그 경우를 막는 방어 코드로 둔다.

## 10. 영향 범위와 위험
- **영향**: worker > 1인 모든 slave. master 재시작은 운영에서 흔하다(장애, 패치, failback). 가림막(3.5)이 없으면 복제가 오류 없이 멈추고, 그 상태에서 failover가 나면 승격까지 막힌다.
- **수정 위험 (안 A')**: 낮춘 라벨이 원래 뜻보다 약해지면 순서 위반이 생긴다. 근거는 "직전 커밋과 자기 커밋 사이에 커밋이 없다"는 것이고, 이는 다음 두 조건에 기댄다.
  - 라벨보다 큰 커밋을 읽은 뒤에 그 라벨을 단 트랜잭션이 온다. 즉 로그를 LSA 순서로 읽는다.
  - 읽은 커밋은 모두 ring에 들어가거나 frontier 이하다.
    - 확인: `la_coordinator_process_commit`과 serial fragment는 `la_coordinator_submit_task`에서, 작업 없는 SYSOP_END는 `la_coordinator_complete_without_task`에서 push한다(`log_applier.c:982-1010`).
    - 확인: `committed_lsa` 이하의 커밋은 처리하지 않지만 frontier 시작값(`committed_lsa`) 이하다.
- 정상 라벨은 바뀌지 않으므로, 재시작 직후가 아닌 구간의 동작은 수정 전과 같다.

## 11. 열린 질문
1. ring에 올라가지 않는 커밋이 있는가? 위 10절의 경로는 확인했다. 필터(`ha_repl_filter`)로 건너뛴 트랜잭션의 커밋 경로는 아직 보지 않았다.
2. ~~가림막 커밋 3건(4.4절)의 정체는 무엇인가?~~ 확인했다(10-23, 9.3절). 재시작한 master의 applylogdb가 apply info를 갱신한 빈 커밋이다.
   - 재현 DB는 00:19에 다시 만들어져 로그가 남아 있지 않다.
   - youngjun3 서버 접속 기록(`testdb_20261021_0006.access`)상 서버 기동 뒤 INSERT 전에 접속한 클라이언트는 youngjun3 applylogdb(00:06:58, worker 연결 10개 포함)와 youngjun4 copylogdb(00:07:14)뿐이었다.
   - 그래서 youngjun3 applylogdb가 `_db_ha_apply_info`를 갱신한 커밋으로 추정한다. 다음 HA 재시작 때 확인한다.
3. 재현 B에서 가려질 때 정지를 강제하는 절차는 아직 없다. 안 A'가 들어간 뒤에는 정지 여부가 아니라 정규화 trace로 검증한다.
4. slave가 아무것도 적용하지 않은 상태(`committed_lsa` NULL, ring 비어 있음)에서 첫 커밋의 라벨이 NULL이 아니면 정규화되지 않는다. 이때 frontier가 NULL이라 `la_gate_is_satisfied`가 거짓이다. 실제로 이 상태가 생기는지는 확인하지 않았다.
