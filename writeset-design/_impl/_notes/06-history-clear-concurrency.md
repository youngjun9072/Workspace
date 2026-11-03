# 전역 writeset history clear 동시성 설계

이 문서는 overflow 또는 history 용량 초과로 키별 history 전체를 비울 때, COMMIT LSA 순서와 실제 publish 실행 순서가 달라도 삭제된 의존성을 `history_start`가 빠짐없이 대신하도록 하는 동시성 규칙을 정의한다.

## 1. 문제

COMMIT LSA는 `prior_lsa_mutex` 안에서 순서대로 배정되지만, 해당 COMMIT LSA를 writeset history에 게시하는 작업은 mutex를 해제한 뒤 수행한다. 따라서 먼저 COMMIT LSA를 받은 트랜잭션의 publish가 스케줄링·락 대기 등으로 늦어지고, 뒤의 트랜잭션이 먼저 history에 게시될 수 있다.

history clear가 현재 트랜잭션의 COMMIT LSA만 `history_start`에 남기면, 그 사이 더 늦은 COMMIT LSA로 게시된 키별 슬롯을 삭제하면서도 그 순서를 하한에 반영하지 못한다.

## 2. 재현 시나리오

초기 상태는 다음과 같다.

```text
history_start = 50
history       = { 기존 키별 WRITE·REF 슬롯 }
```

T1은 writeset 한도를 초과해 정상 키별 게시를 할 수 없는 트랜잭션이다.

```text
T1: COMMIT LSA=100 기록
    writeset_overflow=true
    prior_lsa_mutex 해제
    publish 전에 잠시 정지
```

그 사이 T1과 관계없는 키 `K2`를 변경한 T2가 커밋하고 먼저 게시한다.

```text
T2: COMMIT LSA=110 기록
    prev_commit_lsa=110
    history[K2].write_seq=110
```

T1이 다시 실행해 현재 구현 방식으로 전체 clear를 수행하면 다음 결과가 된다.

```text
history.clear()
history_start = max(기존 history_start, T1.commit_lsa)
              = max(50, 100)
              = 100

결과:
history       = {}
history_start = 100
```

전체 clear이므로 T1과 관계없는 `history[K2].write_seq=110`도 삭제된다. 여기서 말하는 T2의 기록은 T2 객체나 트랜잭션 전체가 아니라, **T2가 history에 게시한 키별 WRITE·REF 슬롯 값**이다.

이후 T3가 `K2`를 변경하면 정확한 슬롯 110을 찾지 못하고 `history_start=100`만 보게 된다.

```text
T3: K2 WRITE
    history[K2] 없음
    dependency=100    # 필요한 T2의 110보다 작음
```

따라서 T3가 T2보다 먼저 적용될 수 있는 잘못된 선행 관계가 만들어진다.

## 3. 지켜야 할 조건

전체 clear가 끝난 시점에는 다음 조건이 성립해야 한다.

```text
history_start >= clear로 삭제한 모든 write_seq와 ref_seq
```

키별 슬롯을 없앤 뒤에는 어떤 키가 어느 트랜잭션과 충돌했는지 복원할 수 없다. 따라서 정확한 키별 관계 대신, 삭제된 이력 전체를 포괄하는 하나의 보수적 하한을 남긴다.

overflow는 누락된 키가 무엇인지 알 수 없는 상태이므로 T1과 관련된 키만 선택해 지울 수 없다. history 용량 초과도 같은 자료구조를 재사용하기 위해 전체 map을 비운다. 두 경우 모두 관계없는 키가 함께 삭제될 수 있으며, 그 대신 `history_start`가 삭제된 모든 관계를 포괄해야 한다.

## 4. 선택한 잠금 규칙

일반 publish는 자신의 COMMIT LSA를 `prev_commit_lsa`에 먼저 등록한 뒤 키별 history에 접근한다.

```text
일반 publish
  seq_lock
    prev_commit_lsa=max(prev_commit_lsa, current_commit_lsa)
  seq_lock 해제
  history shared lock
    키별 WRITE·REF 슬롯 게시
  history shared lock 해제
```

전체 clear는 `seq_lock`을 유지한 상태에서 history exclusive lock을 획득한다.

```text
전체 clear
  seq_lock
    history exclusive lock
      history_start=max(history_start, prev_commit_lsa)
      history.clear()
    history exclusive lock 해제
  seq_lock 해제
```

두 잠금을 함께 획득하는 경로의 순서는 반드시 다음으로 통일한다.

```text
seq_lock → history_lock
```

이 규칙은 publish와 clear의 경합을 다음 세 경우로 정리한다.

1. **다른 트랜잭션이 기준 등록과 게시를 모두 끝냄**

   clear는 해당 COMMIT LSA가 포함된 `prev_commit_lsa`를 하한으로 남기고 게시된 슬롯을 삭제한다.

2. **다른 트랜잭션이 기준을 등록하고 키별 슬롯을 게시하는 중임**

   clear는 history exclusive lock에서 기다린다. 게시가 끝난 뒤 슬롯을 삭제하되, 이미 등록된 COMMIT LSA를 하한에 포함한다.

3. **다른 트랜잭션이 아직 기준도 등록하지 못함**

   clear가 잡은 `seq_lock`에서 기다린 뒤, clear가 끝난 새 history에 기준 등록과 키별 게시를 수행한다.

따라서 clear 전에 삭제되는 publish는 하한에 포함되고, 하한에 포함되지 않은 publish는 clear 이후의 map에 남는다.

## 5. overflow와 capacity clear

### 5.1 overflow

overflow 트랜잭션은 키별 writeset이 완전하지 않으므로 자신의 키를 게시하지 않는다. 자신의 COMMIT LSA는 clear 전에 `prev_commit_lsa`에 단조 증가 방식으로 등록한다. clear는 동기화된 최신 `prev_commit_lsa`를 사용하므로 현재 overflow 트랜잭션과 먼저 등록된 더 늦은 COMMIT을 모두 포괄한다.

### 5.2 history 용량 초과

용량 확인은 일반 publish와 동시에 변할 수 있으므로 다음 순서를 사용한다.

```text
shared lock에서 1차 용량 확인
→ 공간 부족이면 shared lock 해제
→ seq_lock 획득
→ history exclusive lock 획득
→ 용량 재확인
→ 여전히 부족할 때만 하한 갱신과 clear
→ 현재 트랜잭션의 키별 슬롯 게시
```

shared lock을 유지한 채 exclusive lock으로 승격하지 않는다. 두 잠금 사이에 map 상태가 바뀔 수 있으므로 exclusive lock을 얻은 뒤 용량을 다시 확인한다.

## 6. `prev_commit_lsa`를 사용하는 이유

clear 시점에 map의 모든 슬롯을 순회해 최댓값을 구할 수도 있지만, 비용이 map 크기에 비례하고 동시 publish와 다시 동기화해야 한다. 모든 publish가 키별 접근보다 먼저 자신의 COMMIT LSA를 `prev_commit_lsa`에 등록하도록 하면, clear는 상수 시간에 삭제 범위를 포괄하는 하한을 얻을 수 있다.

`prev_commit_lsa`에는 실제로 슬롯이 삭제되는 키 없는 COMMIT까지 포함될 수 있다. 따라서 정확한 슬롯 최댓값보다 클 수 있지만, 이는 관계없는 트랜잭션을 추가로 기다리는 보수적 결과일 뿐 필요한 순서를 누락하지 않는다.

## 7. 구현 변경 지점

- `wset_publish_commit_to_history()`
  - 모든 publish가 history 접근 전에 COMMIT LSA를 `prev_commit_lsa`에 등록한다는 순서를 유지한다.
- overflow clear 경로
  - `seq_lock → history exclusive lock` 순서로 획득한다.
  - 현재 트랜잭션의 COMMIT LSA만 사용하지 않고 동기화된 `prev_commit_lsa`로 하한을 갱신한다.
- capacity clear 경로
  - shared lock을 해제한 뒤 위 잠금 순서로 다시 진입하고 용량을 재확인한다.
- clear 내부 함수
  - 호출자가 두 잠금을 올바른 순서로 보유한다는 전제를 이름과 주석에 드러낸다.

일반 키별 publish는 `seq_lock`을 해제한 뒤 history shared lock을 얻으므로 모든 publish가 하나의 mutex 구간에서 직렬화되지는 않는다.

## 8. 검증 시나리오

### 8.1 지연된 overflow clear

```text
T2(COMMIT=110)의 K2 WRITE를 먼저 게시
T1(COMMIT=100, overflow)을 뒤늦게 publish하여 전체 clear
T3가 K2를 probe
```

기대 결과는 다음과 같다.

```text
history       = {}
history_start = 110
T3 dependency = 110
```

스레드 타이밍 없이 publish 호출 순서를 바꾸는 단위 테스트로 핵심 회귀를 재현할 수 있다. `delayed overflow clear preserves a newer published commit as the history floor` 테스트가 이 순서와 결과를 고정한다.

### 8.2 publish 진행 중 clear

한 스레드가 `prev_commit_lsa` 등록을 끝낸 뒤 history shared lock 안에서 멈추고, 다른 스레드가 clear를 시도한다. clear는 publish가 끝날 때까지 기다린 뒤 그 COMMIT LSA 이상을 `history_start`에 남겨야 한다.

### 8.3 clear 이후 publish

clear가 `seq_lock`을 보유한 상태에서 다른 publish를 시작한다. publish는 clear가 끝난 뒤 기준을 등록하고 새 map에 슬롯을 남겨야 한다.

### 8.4 capacity 재확인

1차 용량 확인과 exclusive lock 획득 사이에 다른 clear가 실행된 경우, 용량을 다시 확인해 불필요한 두 번째 clear를 수행하지 않아야 한다.

## 9. R02와의 경계

이 문서는 **clear가 올바른 `history_start`를 남기는 문제(R01)**만 해결한다. probe가 `history_start`와 `prev_commit_lsa`를 서로 다른 시점에 읽은 뒤 `min()`으로 올바른 하한보다 dependency를 낮추는 문제(R02)는 별도의 스냅샷·후보 확정 규칙으로 다룬다.
