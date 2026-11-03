# C2. commit-order 대체 경로의 라벨에 history_start 하한이 빠짐

## 1. 메타
| 항목 | 내용 |
|---|---|
| 등급 | High |
| 상태 | **수정 완료, HA 검증 통과(10-23).** 수정 `ae19759c4`(단위 테스트 포함). 단위 테스트 통과(10-21). HA에서 재시작 직후 DDL의 라벨이 R인 것을 확인(9.3절). 재현 커밋 `8eff9645f`은 수정 커밋에 접음(접기 전 기록: 브랜치 `backup/c1c2-before-fold-20261021`) |
| 판정 | 코드로 확정. 단위 테스트로 두 경우를 재현함(수정 전 실패) |
| 신규/기존 | 신규. fb82b7db6(Master-side writeset generation) |
| 관련 이슈 | [C1](C1_master_restart_floor_gate_stall.md)(재시작 하한 R. C1 수정 뒤에는 이 수정만 따로 넣어도 정지하지 않음) |
| 지적한 리뷰어 | 5명(종합 문서 2절) |

## 2. 문제 요약
master는 커밋할 때 두 경로 중 하나로 라벨을 정한다. 키를 모은 보통 트랜잭션은 일반 경로를 타고, 라벨에 history_start 하한을 적용한다. 키를 다 모을 수 없는 트랜잭션(`wset_overflow`)은 commit-order 대체 경로를 타고, 직전 커밋(`prev_commit_lsa`)을 라벨로 쓴다. 대체 경로에는 하한 적용이 없다. 평소에는 `prev_commit_lsa ≥ history_start`라서 결과가 같다. 재시작 직후와 serial sysop 직후에는 `prev_commit_lsa`가 하한보다 작아지고, 이때 대체 경로 트랜잭션이 기다려야 할 것을 기다리지 않는다.

## 3. 문제 분석
이 절의 코드 위치는 수정 전 C1 수정 커밋(접기 전 `7c8e150e0`, 지금 `ac9aa4bf7`) 기준이다.

### 3.1 두 경로의 라벨 (`src/transaction/writeset.cpp`)
| 경로 | 위치 | 라벨 |
|---|---|---|
| 일반 경로 `wset_find_dependency_in_range` | 1081-1093행 | `max( min(충돌 키 후보, prev_commit_lsa), history_start )` |
| 대체 경로 `wset_find_dependency_from_history`의 `wset_overflow` 블록 | 1111-1119행 | `prev_commit_lsa` |

대체 경로로 가는 경우(`wset_fallback_to_commit_order`):
- `STATEMENT_REPLICATION`: statement로 복제되는 트랜잭션. DDL 등(`replication.c:536`), serial statement(`serial.c:1234`). 행 키가 없어서 충돌을 계산할 수 없다.
- `TRANSACTION_LIMIT`: 트랜잭션 하나가 모은 키 수가 상한을 넘음(`writeset.cpp:523`).

### 3.2 하한이 빠져도 대부분 괜찮은 이유와 예외
| history_start를 올리는 곳 | 올린 값 | `prev_commit_lsa`와의 관계 | 대체 경로 결과 |
|---|---|---|---|
| history clear (`writeset.cpp:1251, 1297, 1307, 1314`) | `prev_commit_lsa` 그 자체 | 같음 | 차이 없음 |
| master 재시작 (`log_manager.c:1513`) | R (복구 직후 로그 끝) | `prev_commit_lsa`는 재시작 때 NULL로 초기화(`writeset.cpp:463, 490`) | 라벨 NULL → 의존이 사라짐 |
| serial sysop 끝 (`log_manager.c:4071`) | 그 sysop의 LSA | sysop은 직전 커밋보다 뒤일 수 있음 | sysop을 기다리지 않음 |

### 3.3 실패 순서 (예시)
slave가 재시작 전 로그를 아직 적용하는 중이다.

| master 로그 | 라벨 | slave |
|---|---|---|
| 커밋 P(100): `INSERT INTO t ...` | | 적용 중 |
| (재시작, R = 105) | | |
| 커밋 D(106): `ALTER TABLE t DROP COLUMN c` | **NULL** | gate를 바로 통과해 P와 동시에 실행될 수 있음 |

slave에는 DDL을 따로 직렬화하는 경로가 없다. worker가 2개 이상이면 gate만 보고 바로 보낸다. `ALTER`가 `INSERT`보다 먼저 또는 겹쳐 실행되면 INSERT가 실패하거나 결과가 달라질 수 있다(추정, HA에서 관측하지 않음).

serial sysop 경우의 실제 영향은 확인하지 않았다(추정).

## 4. 발생 조건과 재현 방법

### 4.1 발생 조건
1. 재시작 경우: master 재시작 뒤 첫 커밋들 가운데 대체 경로 트랜잭션(DDL 등)이 있고, slave가 재시작 전 커밋을 아직 다 적용하지 않았으며, worker > 1.
2. sysop 경우: serial sysop 뒤, 다음 커밋 전에 대체 경로 트랜잭션이 커밋됨.

### 4.2 단위 테스트 (`unit_tests/writeset/test_writeset.cpp`, 재현 커밋 `8eff9645f`)
| 테스트 | 상태 | 수정 전 라벨 | 기대 |
|---|---|---|---|
| an overflowed transaction after a restart waits for the restart floor | 초기화 직후 `wset_raise_history_start (105\|0, "RESTART")`, `wset_overflow = true` | NULL | 105\|0 |
| an overflowed transaction after a sysop waits for the sysop | 커밋 10\|0 게시 뒤 `wset_raise_history_start (12\|0, "SYSOP_COMMIT_ORDER")`, `wset_overflow = true` | 10\|0 | 12\|0 |

수정 전 두 테스트 모두 실패했다(`[!shouldfail]`로 스위트 통과: 28건 중 26 통과, 2건 예상 실패).

## 5. 기대 결과
대체 경로 트랜잭션도 slave에서 history_start 이전의 것(재시작 전 커밋, serial sysop)을 기다린다.

## 6. 실제 결과 (수정 전)
- 재시작 직후 대체 경로 라벨이 NULL이 된다. 오류는 남지 않는다.
- C1 문서 3.5절의 가림막 1번(재생성 직후 하니스 DDL의 라벨이 NULL이라 frontier를 R 위로 올려 줌)이 이 결과다.

## 7. 해결 방법
대체 경로 라벨을 `max(prev_commit_lsa, history_start)`로 한다. 일반 경로와 같은 하한이다.

- 재시작 직후 DDL의 라벨은 R이 된다. slave는 C1 수정(안 A')으로 R을 직전 커밋으로 낮추므로, 재시작 전 커밋이 모두 끝난 뒤 실행한다.
- C1 수정 전에는 이 수정이 가림막을 없애 C1 정지를 드러냈다. C1 수정이 먼저 들어갔으므로 이 문제는 없다.

## 8. 구현 (`ae19759c4`, `wset_find_dependency_from_history`)
```c
  if (tdes->wset_overflow)
    {
      pthread_mutex_lock (&wset_History.seq_lock);
      LSA_COPY (wset_parent_out, &wset_History.prev_commit_lsa);
      /* The floor makes every later transaction wait on the slave for what was written before it: everything
       * before a restart, or a serial operation applied in commit order. prev_commit_lsa does not cover it
       * after a restart, where it is NULL, or after a serial operation, which can lie above it. Without the
       * floor a statement replicated after a restart, a DDL for instance, carries no dependency and can run
       * on the slave beside the transactions written before the restart. Every writer of history_start
       * holds seq_lock, so it is read consistently with prev_commit_lsa here. */
      if (!LSA_ISNULL (&wset_History.history_start)
	  && (LSA_ISNULL (wset_parent_out) || LSA_LT (wset_parent_out, &wset_History.history_start)))
	{
	  LSA_COPY (wset_parent_out, &wset_History.history_start);
	}
      pthread_mutex_unlock (&wset_History.seq_lock);
      ...
```
- 잠금은 `seq_lock`만 잡는다. history_start를 바꾸는 곳(`wset_raise_history_start`, history clear)이 모두 `seq_lock`을 먼저 잡으므로 `prev_commit_lsa`와 같은 시점의 값을 읽는다.
- 주석 번역: 하한은 이후의 모든 트랜잭션이 slave에서 그보다 먼저 기록된 것을 기다리게 한다. 재시작 전의 모든 것, 또는 커밋 순서대로 적용되는 serial 연산이 그 대상이다. `prev_commit_lsa`로는 이것이 보장되지 않는다. 재시작 뒤에는 NULL이고, serial 연산은 그보다 뒤에 있을 수 있기 때문이다. 하한이 없으면 재시작 뒤 statement로 복제되는 트랜잭션(예: DDL)은 의존이 없는 상태가 되어, slave에서 재시작 전에 기록된 트랜잭션들과 동시에 실행될 수 있다.
- 함수 머리 주석의 "An overflowed writeset uses prev_commit_lsa"도 하한을 적용한다고 고쳤다.

## 9. 검증

### 9.1 단위 테스트 (10-21, `build_ut_debug`)
- `test_writeset "[writeset]"`: 28건, 4459 assertion 모두 통과. 4.2절 두 테스트 포함. 기존 대체 경로 테스트(`overflow demotes to commit order and raises the history floor`)도 그대로 통과했다(그 테스트는 하한이 NULL).
- `test_log_applier`: 25건 통과.
- CI 코드 스타일: 이번 변경분 차이 없음.

### 9.2 남은 검증
1. HA 시험: DB 재생성 직후나 HA 재시작 직후 하니스 DDL의 master trace `DEPENDENCY ... mode=COMMIT_ORDER dependency=`가 NULL이 아니라 R인지 본다. slave에서 그 DDL이 재시작 전 커밋 뒤에 실행되는지(하니스 순서 분석) 본다.
2. C1과의 연동: 위 DDL이 R과 사이에 다른 커밋 없이 오면 slave에 `[WSET] reader label lowered`가 남는다. 가림막 커밋이 먼저 오면 남지 않는다(C1 문서 9.2절).
3. 회귀: 재시작 시험, F1, F4.

### 9.3 HA 시험 (10-23 17:23, 빌드 2786-8823088, `ha_bench_tool/log/c1_restart_20261023_172259/`)
[C1](C1_master_restart_floor_gate_stall.md) 9.3절과 같은 런이다. HA 전체 재시작 뒤 `CREATE TABLE c2_t`, 이어서 `INSERT INTO c1_t VALUES (1)`.

| 확인 | 결과 |
|---|---|
| master: 재시작 경계 R | `HISTORY_START raise reason=RESTART history_start=11136\|8184` |
| master: DDL(trid 485230)의 라벨 | `DEPENDENCY trid=485230 mode=COMMIT_ORDER dependency=11136\|8184` (R. 수정 전이라면 NULL) |
| master: INSERT(trid 485236)의 라벨 | `dependency=11137\|10448` (DDL의 커밋. DDL이 history를 비우고 하한을 올림) |
| slave: DDL | `status=0`으로 바로 실행. frontier가 이미 R을 넘어 있었음 |
| slave: INSERT | DDL 커밋을 기다리며 `status=2`(대기) → DDL 뒤 `status=1`(실행) |
| 데이터 | c2_t 양쪽 있음, c1_t 1/1, fail_counter 0 |

- 9.2절 1번(라벨이 NULL이 아니라 R)과 3번(회귀)을 확인했다. 2번(R과 DDL 사이에 커밋이 없을 때 `label lowered`)은 가림막 커밋 때문에 이번에도 생기지 않았다(C1 9.3절).

## 10. 영향 범위와 위험
- 영향: 대체 경로 트랜잭션(DDL, serial statement, 키 상한 초과)의 라벨이 재시작 직후와 serial sysop 직후에 더 늦은 값(하한)이 된다. 그 외에는 `prev_commit_lsa ≥ history_start`라서 바뀌지 않는다.
- 병렬도: 해당 트랜잭션이 하한까지 기다리게 된다. 원래 "앞의 커밋을 모두 기다리는" 경로라 병렬도 손실은 없다.
- 위험: 라벨이 커밋이 아닌 R이 될 수 있다. slave는 C1 수정(`ac9aa4bf7`)이 있어야 정지하지 않는다. 두 수정은 같이 배포해야 한다.

## 11. 열린 질문
1. serial sysop 경우의 실제 영향(slave에서 serial 값이 잠시 뒤처지는지, 최종 상태가 맞는지)은 확인하지 않았다.
2. `wset_find_sysop_fallback_dependency`(sysop 자체의 대체 라벨)는 하한 뒤의 값을 돌려주는지 테스트(`raising history_start makes later transactions wait for the sysop`)로 확인돼 있다. 재시작 직후 그 경로의 값은 따로 보지 않았다.
