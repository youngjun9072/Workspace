---
tags: [CBRD-27508, master, unique, 커밋순서]
---
# unique 검사와 커밋 기록 순서 역전

> [!NOTE]
> **현재 상태 (2026-11-02, PR 브랜치 HEAD 8e3029e56 기준)**
> - 이 문서의 수정(3269e5493·79268ae56 → 현재 5ad146e8c, d1d02b9e4 → 현재 8d88cce80)은 11-01 develop 병합 3b3e37e16에서 develop CBRD-27034(ef4e7e812)의 대기로 대체됐다. 지금 코드에는 브랜치 고유 대기가 없다(01 5.3절).
> - 4절의 "INCR 서브트랜잭션 self-lock" 빈틈은 INCR sysop이 commit-order 장벽 라벨을 받게 된 뒤(fffda6ccd, 10-30) 해소됐을 가능성이 있으나 확인하지 않았다.


작성: 2026-10-19. 대상 사건: 10-19 14:20 `verify_until_error` 2라운드 unique에서 slave fail_counter 0 → 2. 사건 경과와 자료 위치는 `ha_bench_tool/log/verify_until_error_20261019_130529_report.md`에 있다. 수정은 커밋 `3269e5493`(수정 A), 대기 trace는 `18661fd25`.

## 등장 요소

아래 이름은 문서 끝까지 같은 대상을 가리킨다.

- 컬럼 하나에 unique 제약이 있고, 값 'kim'이 한 건 들어 있다.
- T1: `DELETE ... WHERE ... = 'kim'; COMMIT;`
- T2: `INSERT ... 'kim'; COMMIT;`
- 커밋 단계: ① MVCC 완료 → ② 커밋 기록 → publish(writeset 키 등록) → ③ 잠금 해제

## 1. 문제점

### 1.1 커밋은 두 번 일어난다

| | 언제 | 누가 보나 |
|---|---|---|
| ① MVCC 완료 | 커밋 처리의 앞부분 | master의 다른 트랜잭션. 이때부터 결과가 보인다 |
| ② 커밋 기록 | ① 다음에 로그에 COMMIT을 씀 | slave. slave는 로그의 COMMIT 순서로만 적용한다 |

그래서 순서도 두 가지로 나뉜다.

- 데이터 반영 순서: master의 다른 트랜잭션에게 결과가 보이기 시작하는 순서(① 시점). master의 데이터는 실행되는 순간 바뀌므로 이 순서대로 남는다.
- 커밋 기록 순서: 로그에 COMMIT이 적힌 순서(② 시점). slave는 로그를 이 순서대로 다시 적용해 데이터를 만든다.

①과 ② 사이에는 틈이 있다. T1은 이 사이에 postpone 처리, writeset 의존 계산, 로그 append를 한다. 그동안 짧은 트랜잭션이 앞질러 ②까지 갈 수 있다.

### 1.2 T2의 unique 검사가 T1을 기다리지 않는 이유

- CUBRID의 일반 테이블은 MVCC 테이블이다. MVCC를 쓰지 않는 것은 root class, `db_serial`, collation 카탈로그, `db_ha_apply_info`뿐이다(`mvcc_is_mvcc_disabled_class`).
- MVCC에서 T1의 DELETE는 키를 바로 지우지 않는다. 인덱스의 'kim' 항목에 "T1의 MVCCID가 지움" 표시를 남기고, 실제 항목은 나중에 vacuum이 치운다. UPDATE로 값을 'kim'에서 다른 값으로 바꿀 때도 옛 키에 같은 표시가 붙는다.
- T2의 INSERT는 unique 검사(`btree_key_find_and_lock_unique_of_unique`, `_of_non_unique`)에서 이 표시가 붙은 'kim'을 만난다. 이 'kim'을 아직 있는 키로 볼지는 T1의 상태로 정한다(`mvcc_satisfies_delete`).
  - T1이 active이면 "지우는 중"으로 보고 T1의 행 잠금을 기다린다.
  - T1이 ①을 지났으면 "이미 지워진 키"로 보고 잠금을 확인하지 않고 통과한다.
- 잠금은 커밋할지 롤백할지 모르는 트랜잭션을 기다리는 장치이고, ①을 지난 T1은 MVCC 기준으로 커밋이 정해진 상태다. 그래서 잠금을 보지 않아도 master 데이터는 맞다. develop에 원래 있던 MVCC 동작이고 CBRD-26942와는 관계없다.

### 1.3 T1이 갖는 잠금

둘 다 T1이 시작할 때가 아니라 데이터를 바꿀 때 잡히고, 커밋의 ③ `lock_unlock_all`에서 함께 풀린다(`log_commit_local`).

- 행 잠금(X): T1의 DELETE가 그 행을 지우는 순간 그 행에 건다. 행마다 하나.
- MVCCID self-lock(X): T1이 처음 데이터를 바꿔 MVCCID를 받는 순간 건다(`logtb_get_current_mvccid` → `logtb_self_lock_assigned_mvccid`, INSERT·UPDATE 경로에서 `logtb_ensure_mvccid_self_lock`으로 한 번 더 확인). 트랜잭션당 하나. CBRD-26942가 INSERT 행의 X 잠금 대신 넣은 것이다.

T1이 SELECT만 하는 동안에는 둘 다 없다. 이 예에서는 T1의 DELETE가 실행될 때 함께 생긴다.

### 1.4 그래서 순서가 뒤집힌다

T1이 ①을 지난 뒤 T2가 'kim'을 넣고, T1이 ②를 쓰기 전에 T2가 먼저 ②를 쓴다. T2가 의존을 계산할 때 T1은 아직 publish 전이라 T2의 의존에도 T1이 없다. 데이터 반영 순서는 T1 → T2인데 커밋 기록 순서는 T2 → T1이 된다. master 데이터는 맞지만, 로그를 다시 적용하는 slave는 뒤집힌 순서를 따른다(아래 표).

## 2. 해결 방법 (수정 A)

T2의 unique 검사가 "이미 지워진 키"로 판정하는 자리에서, 지운 쪽 T1이 ③까지 끝났는지 한 번 더 확인한다.

1. 인덱스의 'kim'에 적힌 T1의 MVCCID로, T1의 MVCCID self-lock을 조건부(S)로 잡아 본다.
2. 잡히면 T1이 ③까지 끝난 것이다. 바로 놓고 지금처럼 진행한다.
3. 안 잡히면 T1이 ①과 ③ 사이다. 페이지 래치를 놓고 T1의 self-lock을 기다린 뒤(`btree_key_wait_for_insert_mvccid`) B-tree root부터 다시 찾는다. 다시 찾을 때는 2번이 되어 진행한다.

복제 로그를 쓰는 master에서만 동작한다(`log_does_allow_replication`). slave, SA 모드, vacuum, rollback에는 영향이 없다.

### 잠금이 순서와 이어지는 이유

잠금 자체가 순서를 정하는 장치는 아니다. T1은 ② 커밋 기록과 publish를 마친 뒤 ③에서 잠금을 푼다. 그래서 T2가 T1의 잠금 해제를 기다리면, 그 시점에는 T1의 커밋 기록이 반드시 이미 있다. T2의 커밋 기록은 그 뒤에 놓이고, T2의 의존 계산에도 T1이 잡힌다.

```
T1:  ① MVCC 완료 → ② 커밋 기록 쓰기 → publish → ③ 잠금 해제
                                                      ↑
T2:                       (여기서 잠금 대기) ──────────┘ 풀리면 진행 → T2 커밋 기록
```

### 비용

- 평소 경로: 지워진 키를 만났을 때 조건부 잠금 시도 한 번이 늘어난다. 대기는 없다.
- 대기: T1이 바로 그 틈에 있을 때만, 틈이 끝날 때까지 기다린다.

## 3. 타임라인

### 수정 전

| 시각 | T1 (`DELETE 'kim'`) | T2 (`INSERT 'kim'`) | master에서 'kim'이 보이는 상태 | 로그의 COMMIT 순서 |
|---|---|---|---|---|
| t0 | DELETE 실행. 'kim'에 "T1이 지움" 표시를 남기고, 행 잠금과 MVCCID 잠금을 잡음 | | 기존 'kim' 있음 (T1이 아직 active) | |
| t1 | COMMIT 시작, ① MVCC 완료 | | 기존 'kim' 없음 ← T1의 데이터가 반영되는 시점 | |
| t2 | 커밋 처리 중 (② 전) | INSERT 실행. 기존 'kim'을 "T1이 지웠고 커밋됨"으로 보고 통과 | 기존 'kim' 없음. 새 'kim'은 T2만 봄 | |
| t3 | 커밋 처리 중 (② 전) | COMMIT: ① MVCC 완료 → ② 커밋 기록 → publish → ③ 잠금 해제 | 새 'kim' 있음 ← T2의 데이터가 반영되는 시점 | T2 |
| t4 | ② 커밋 기록, publish | | 새 'kim' 있음 | T2, T1 |
| t5 | ③ 잠금 해제 | | 새 'kim' 있음 | T2, T1 |

- 데이터 반영 순서: T1(t1) → T2(t3). master의 최종 데이터는 새 'kim' 하나로 맞다.
- 커밋 기록 순서: T2(t3) → T1(t4). 뒤집혔다.

slave는 로그 순서대로 적용한다.

| 순서 | 적용 | slave의 'kim' |
|---|---|---|
| 1 | T2: INSERT 새 'kim' | 기존 'kim'이 아직 있어서 unique 위반으로 실패 |
| 2 | T1: DELETE 기존 'kim' | 'kim' 없음 → master와 불일치 |

### 수정 A 이후

| 시각 | T1 | T2 | master에서 'kim'이 보이는 상태 | 로그의 COMMIT 순서 |
|---|---|---|---|---|
| t0 | DELETE 실행, 잠금 잡음 | | 기존 'kim' 있음 | |
| t1 | ① MVCC 완료 | | 기존 'kim' 없음 | |
| t2 | 커밋 처리 중 | INSERT 실행. T1의 잠금이 아직 잡혀 있어서 대기 | 기존 'kim' 없음 | |
| t3 | ② 커밋 기록, publish | (대기) | 기존 'kim' 없음 | T1 |
| t4 | ③ 잠금 해제 | 대기 끝, INSERT 진행 | 기존 'kim' 없음 | T1 |
| t5 | | COMMIT: ① → ② 커밋 기록 → publish → ③ | 새 'kim' 있음 | T1, T2 |

- 데이터 반영 순서: T1(t1) → T2(t5)
- 커밋 기록 순서: T1(t3) → T2(t5)

두 순서가 같아졌다. slave도 T1(지움) → T2(넣음) 순서로 적용하므로 master와 같은 결과가 된다.

## 4. 보충

- 10-19 14:20 사건에서 데이터가 같게 나온 것은 우연이다. T2가 넣은 행을 뒤의 트랜잭션이 다시 지워서, slave의 INSERT 실패(-670)와 DELETE 실패(-711)가 서로 상쇄됐다. 지우는 트랜잭션이 없었다면 불일치가 남는다.
- 같은 틈의 다른 경로: DELETE/UPDATE가 "커밋 중인 inserter가 넣은 행"을 만나는 경우는 수정 C(`d1d02b9e4`)가 같은 self-lock 대기로 막았다.
- 남은 빈틈: click counter(INCR) 같은 서브트랜잭션이 키를 지운 경우는 서브트랜잭션의 self-lock이 부모의 커밋 전에 풀려 막지 못한다.
- 확인하지 않은 것(추정): T2의 커밋 기록 뒤, T1의 커밋 기록 전에 서버가 죽으면 복구가 T1을 롤백해 'kim'이 두 건 남을 수 있다.

## 5. 시험 결과

- unique 20회(10-19 15:30~17:20, 빌드 2774-18661fd): 불일치 0, fail_counter 0. 대기 trace UNIQUE WAIT 약 740건(수정 A), ROW WAIT 약 190건(수정 C).
- 병렬도(unique 1회): 바로 앞 커밋을 기다려야 하는 비율 14.4%(수정 전 13.8%), slave 평균 동시 실행 1.60(수정 전 1.56). 수정 A의 대기가 병렬도를 떨어뜨리지 않았다.
