# writeset dependency probe 스냅샷 일관성 설계

이 문서는 dependency probe가 `prev_commit_lsa`와 `history_start`를 서로 다른 시점에 읽어, 전체 clear가 세운 하한보다 작은 dependency를 선택하는 문제를 설명하고 스냅샷·최종 후보 확정 규칙을 정의한다.

## 1. 문제

`prev_commit_lsa`는 `seq_lock`으로 보호하고, `history_start`와 키별 map은 `history_lock`으로 보호한다. 두 값을 다음처럼 별개의 잠금 구간에서 읽으면 그 사이에 전체 clear가 실행될 수 있다.

```text
seq_lock
→ prev_commit_lsa 복사
→ seq_lock 해제

          전체 clear가 들어갈 수 있는 간격

history read lock
→ history_start 복사
→ 키별 슬롯 조회
→ history read lock 해제
```

각 값은 자신의 잠금 아래에서 안전하게 읽었지만, 두 값이 같은 history 상태를 나타내지는 않는다.

## 2. 재현 시나리오

초기 상태는 다음과 같다.

```text
prev_commit_lsa = 100
history_start   = 50
```

트랜잭션 T가 dependency probe를 시작한다.

```text
T:
  seq_lock 획득
  prev_commit_snapshot=100
  seq_lock 해제
  잠시 정지
```

그 사이 다른 트랜잭션 C가 전체 clear를 수행한다. R01의 clear 동시성 규칙이 적용된 정상 결과라고 가정한다.

```text
C:
  prev_commit_lsa=200
  history_start=200
  history.clear()
```

T가 다시 실행하면 새 history의 하한을 읽는다.

```text
T:
  history read lock 획득
  history_start_snapshot=200
  조회한 키별 슬롯 없음
  wset_parent=200
  history read lock 해제
```

마지막에 키별 후보와 commit-order 기준 중 작은 값을 고르면 다음 결과가 된다.

```text
dependency=min(wset_parent, prev_commit_snapshot)
          =min(200, 100)
          =100
```

clear는 삭제된 키별 관계를 대신하기 위해 `history_start=200`을 남겼지만, probe가 과거 baseline을 결합해 그 하한을 다시 100으로 낮춘다.

## 3. 지켜야 할 조건

정상 writeset probe의 최종 결과는 다음 조건을 만족해야 한다.

```text
dependency >= probe가 관찰한 history_start
```

또한 probe가 사용하는 다음 상태는 하나의 일관된 history 시점에서 읽어야 한다.

```text
{ prev_commit_lsa, history_start, key history map }
```

R01의 clear 규칙이 유지되면 같은 시점의 전역 상태는 다음 관계를 만족한다.

```text
history_start <= prev_commit_lsa
```

따라서 서로 다른 시점의 값을 섞지만 않으면 `min(wset_parent, prev_commit_lsa)`가 `history_start` 아래로 내려가지 않는다.

## 4. 선택한 스냅샷 규칙

정상 probe는 clear와 같은 잠금 순서로 진입한다.

```text
probe
  seq_lock 획득
  history read lock 획득
  prev_commit_lsa 복사
  history_start 복사
  seq_lock 해제
  history read lock을 유지한 채 키별 슬롯 조회
  history read lock 해제
```

clear는 다음 순서를 사용한다.

```text
clear
  seq_lock 획득
  history write lock 획득
  history_start 갱신
  history.clear()
  history write lock 해제
  seq_lock 해제
```

두 경로의 잠금 순서는 동일하다.

```text
seq_lock → history_lock
```

따라서 probe는 clear 전 상태 또는 clear 후 상태 중 하나만 관찰한다.

```text
clear 전: prev_commit_lsa=100, history_start=50, 이전 map
clear 후: prev_commit_lsa=200, history_start=200, 빈 map
```

다음과 같은 혼합 상태는 관찰하지 않는다.

```text
prev_commit_lsa=100, history_start=200
```

## 5. 잠금 유지 범위와 TBB 병렬성

`seq_lock`은 키별 map 전체를 조회하는 동안 유지하지 않는다. `history read lock`을 얻고 두 LSA를 복사한 직후 해제한다.

```text
seq_lock 보유 구간
  history read lock 획득
  prev_commit_lsa·history_start 복사
  끝

history read lock 보유 구간
  현재 트랜잭션의 모든 키별 슬롯 조회
```

`history read lock`은 공유 잠금이므로 여러 probe와 일반 publish가 동시에 보유할 수 있다. 그 안에서 `wset_history_map`의 TBB accessor가 개별 해시 슬롯을 보호한다.

```text
T1: K1 probe   ─┐
T2: K2 probe   ─┼─ shared history lock 아래에서 동시 실행
T3: K3 publish ─┘   TBB accessor는 각 키만 보호
```

전체 map 접근을 막는 exclusive history lock은 overflow 또는 capacity 부족으로 실제 clear를 수행하는 구간에만 사용한다. 따라서 이 변경은 TBB의 키별 병렬 접근을 제거하지 않는다. 다만 clear가 빈번하면 전역 exclusive 구간 자체가 병목이 되므로 clear 횟수를 운영 통계로 관찰해야 한다.

## 6. overflow probe

overflow 트랜잭션은 키별 map이나 `history_start`로 dependency를 계산하지 않고 `prev_commit_lsa`를 commit-order 기준으로 사용한다. 따라서 `seq_lock` 아래에서 `prev_commit_lsa`만 복사한 뒤 즉시 반환한다.

```text
seq_lock
→ prev_commit_lsa 복사
→ overflow이면 seq_lock 해제 후 반환
```

overflow dependency가 슬레이브에서 특정 트랜잭션 완료가 아니라 연속 완료 경계까지 기다려야 하는 문제는 R03의 dependency 의미 전달 설계에서 다룬다.

## 7. 최종 하한 적용

일관된 스냅샷이 R02의 원인을 제거한다. 여기에 `history_start`가 절대로 낮아질 수 없는 하한이라는 규칙을 최종 후보 계산에도 직접 반영한다.

```text
dependency=min(wset_parent, prev_commit_snapshot)
dependency=max(dependency, history_start_snapshot)
```

정상적인 일관된 스냅샷에서는 두 번째 식이 결과를 바꾸지 않아야 한다. 이 식은 향후 후보 계산이 변경되더라도 clear 하한 아래로 dependency를 내리지 않도록 하는 방어 규칙이다.

`ref_seq`에서 선택한 후보는 `wset_parent`가 `history_start`에서 시작해 더 큰 후보로만 갱신되므로 이미 하한 이상이다. REF dependency의 슬레이브 대기 방식은 R03에서 별도로 다룬다.

## 8. 구현 대응

`wset_find_dependency_from_history()`는 다음 순서를 따른다.

```text
seq_lock 획득
prev_commit_lsa 복사

overflow
  → seq_lock 해제
  → prev_commit_lsa 반환

정상 writeset
  → history read lock 획득
  → history_start 복사
  → seq_lock 해제
  → 키별 후보 조회
  → history read lock 해제
  → min 후보 계산
  → history_start 하한 적용
```

R01의 overflow·capacity clear도 `seq_lock → history write lock` 순서를 사용해야 한다. 어느 한쪽만 반영하면 다시 서로 다른 상태를 조합하거나 잠금 역순을 만들 수 있으므로 R01과 R02는 같은 잠금 프로토콜로 검토한다.

## 9. 검증 시나리오

### 9.1 혼합 스냅샷 차단

probe가 `seq_lock`을 획득한 시점에 clear를 시작한다. clear는 probe가 history read lock을 얻고 두 LSA를 복사할 때까지 기다려야 하며, probe는 clear 전 상태만 관찰해야 한다.

반대로 clear가 `seq_lock`을 먼저 획득하면 probe는 clear가 끝난 뒤 두 잠금을 얻어 clear 후 상태만 관찰해야 한다.

`probe keeps the sequence lock until the history snapshot is acquired` 테스트는 `history_lock`을 먼저 막아 probe를 두 잠금 사이에 정지시키고, probe가 `seq_lock`을 해제하지 않는지 확인한다.

### 9.2 최종 하한

후보 확정 로직에 `history_start=200`, `wset_parent=200`, 과거 baseline 100에 해당하는 입력을 주더라도 최종 dependency가 200보다 작아지지 않는지 검증한다. 실제 probe의 혼합 스냅샷은 잠금으로 차단하되, 최종 하한 규칙은 후보 계산 단위 테스트로 별도 검증할 수 있다. `probe never lowers a dependency below the observed history floor` 테스트가 이 방어 규칙을 고정한다.

### 9.3 교착과 병렬성

- probe와 clear가 모두 `seq_lock → history_lock` 순서를 지키는지 확인한다.
- 여러 probe가 서로 다른 키를 동시에 조회할 수 있는지 확인한다.
- normal publish가 서로 다른 키를 동시에 게시할 수 있는지 확인한다.
- clear 대기 중인 probe가 clear 완료 후 정상적으로 진행하는지 확인한다.

## 10. 다른 리뷰 항목과의 경계

- **R01**: clear가 삭제한 모든 publish를 포괄하는 `history_start`를 만드는 문제다. [[06-history-clear-concurrency|전역 writeset history clear 동시성 설계]]에서 다룬다.
- **R02**: 이 문서의 범위다. probe가 R01의 올바른 하한을 과거 스냅샷으로 다시 낮추지 않게 한다.
- **R03**: 확정된 dependency를 슬레이브가 개별 완료로 기다릴지 연속 완료 경계로 기다릴지를 표현하는 문제다. 잠금 스냅샷과 별도의 프로토콜 설계다.
