# MySQL 병렬 복제: WRITESET vs LOGICAL_CLOCK vs commit order 보존

> 자료조사 메모 · 조사 시점 2026-06-02
> 출처: MySQL 8.0/8.4 공식 매뉴얼 (1순위)
> ※ 정리 구조는 추후 재검토 예정. 우선 Q&A 내용 그대로 보존.

## 핵심 질문

"logical_clock으로 병렬복제를 수행하면 writeset으로 순서 보장을 하는 건가?"

→ 질문에 두 개념이 섞여 있다. 결론: **WRITESET은 "순서 보장"이 아니라 "의존성(충돌) 판단을 정밀하게 해서 병렬성을 늘리는" 역할이다.** 그리고 두 설정은 서로 대체 관계가 아니라 **source/replica 양쪽에서 함께 동작**한다.

## 두 설정은 위치가 다르다

| 설정 | 위치 | 하는 일 |
|---|---|---|
| `binlog_transaction_dependency_tracking` (WRITESET / COMMIT_ORDER / WRITESET_SESSION) | **source(master)** | 트랜잭션 의존성을 **어떻게 계산해서 binlog에 기록할지** 결정. 결과를 `last_committed` / `sequence_number`(= logical clock 값)로 인코딩 [1] |
| `replica_parallel_type=LOGICAL_CLOCK` | **replica** | binlog에 적힌 `last_committed`/`sequence_number`를 **읽어서 병렬 실행 가능 여부를 판단** [2] |

즉:

- **source가 WRITESET으로 계산** → "어떤 트랜잭션끼리 row/key가 겹치지 않는지"를 보고, 겹치지 않으면 병렬 가능하다고 binlog에 표시.
- **replica가 LOGICAL_CLOCK으로 적용** → 그 표시(logical clock)를 보고 병렬 dispatch.

따라서 "둘 중 뭘로 순서 보장하냐"가 아니라, **WRITESET(계산) → logical clock(전달) → LOGICAL_CLOCK(적용)** 한 파이프라인이다. WRITESET은 source가 logical clock 값을 만드는 방식이고, LOGICAL_CLOCK은 replica가 그 값을 쓰는 방식이다.

## "순서"는 세 갈래로 나눠서 봐야 한다

1. **충돌 트랜잭션의 순서(correctness)** — 같은 row를 건드린 트랜잭션은 WRITESET이 의존성으로 잡아 같은/연속 logical clock을 주므로, replica에서 병렬로 안 돌고 순서가 지켜진다. → WRITESET이 보장 [1].
2. **독립 트랜잭션의 병렬성** — row가 안 겹치면 WRITESET이 "독립"으로 표시 → 병렬 실행. COMMIT_ORDER보다 더 많이 병렬화된다(WRITESET의 핵심 이점) [1].
3. **최종 commit 가시 순서(global commit order)** — 병렬로 돌린 독립 트랜잭션이라도 최종 커밋 순서를 source와 똑같이 맞추는 건 **`replica_preserve_commit_order`** 가 담당한다. WRITESET이 아니다 [2].

## 정리

- WRITESET = "누가 누구랑 충돌하나"를 정밀(row/key)하게 판단 → 충돌하는 것만 순서 강제, 나머지는 병렬 허용.
- LOGICAL_CLOCK = replica가 그 판단 결과(logical clock)를 읽어 병렬 적용.
- 전체 commit 순서 일치는 별도로 `replica_preserve_commit_order`.

질문을 정확히 다시 쓰면:

> "지금은 (source가) WRITESET으로 의존성을 계산하고, (replica가) LOGICAL_CLOCK으로 그 결과를 읽어 병렬 적용한다. 충돌(같은 row) 트랜잭션의 순서는 WRITESET 의존성으로 지켜지고, 전체 commit 순서는 replica_preserve_commit_order로 맞춘다."

## CUBRID 코디네이터와의 대응 (참고)

- CUBRID 1차안의 "class-level 충돌 판단"은 MySQL WRITESET을 **class 단위로 거칠게 한 버전**에 해당한다.
- "순서 정리 단계의 committed_lsa 갱신"은 MySQL **`replica_preserve_commit_order`** 에 해당한다.

## References
[1] Oracle / MySQL. "Binary Logging Options and Variables" (`binlog_transaction_dependency_tracking`). MySQL 8.0 Reference Manual, 2025. https://dev.mysql.com/doc/refman/8.0/en/replication-options-binary-log.html

[2] Oracle / MySQL. "Replica Server Options and Variables" (`replica_parallel_type`, `replica_parallel_workers`, `replica_preserve_commit_order`). MySQL 8.4 Reference Manual, 2025. https://dev.mysql.com/doc/refman/8.4/en/replication-options-replica.html
