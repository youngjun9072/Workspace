# `cub_server` 재시작 경계 구현 설계

> [!WARNING]
> **2026-10-09 대체됨.** 이 문서의 `history_reset_barrier` 라벨 플래그, 마스터 `restart_barrier_pending`, 슬레이브 경계 홀더와 스캔 중지는 구현하지 않는다. 재시작 경계는 복구 직후 `history_start`를 복구된 로그 끝으로 올리는 것으로 대체했다([12장 12.2](../../12-cub_server-재시작.md#122-선택한-방법-재시작-시-history의-바닥을-복구된-로그-끝으로-올림), 커밋 5df8187ad). 3.2절(라벨 기록 실패)과 6절(2PC)의 문제는 그대로 남아 있고 [미구현 목록](unimplemented-20261008.md) 2-1·1-9로 관리한다. 아래 본문은 당시 설계의 기록으로 둔다.

이 문서는 [12장](../../12-cub_server-재시작.md)의 epoch 경계를 현재 마스터 COMMIT 경로와 슬레이브 dependency gate에 연결한다. 함수명은 현재 코드의 삽입 지점을 가리키며, 아직 구현하지 않은 상태는 **추가**로 표시한다.

## 1. 현재 코드에서 확인한 경계

### 1.1 마스터

`log_commit_local()`의 지역 트랜잭션 COMMIT 경로는 다음 순서다.

```text
log_commit_local()
├─ wset_find_dependency_from_history()
├─ log_append_repl_info_and_commit_log()
│  └─ prior_lsa_mutex
│     ├─ log_append_repl_info_with_lock()
│     ├─ log_append_wset_label_with_lock()
│     └─ log_append_commit_log_with_lock()
├─ wset_publish_commit_to_history()
└─ lock_unlock_all()
```

`WSET_LABEL`과 COMMIT은 이미 `prior_lsa_mutex` 하나의 구간에서 순서대로 기록된다. 따라서 재시작 후 첫 COMMIT을 **실제 COMMIT 로그 순서**로 선택할 수 있다.

### 1.2 슬레이브

병렬 applylogdb 구현에서 reader는 순환문의 앞부에서 `la_collect_apply_results()`를 호출한다. 결과 수거는 다음 작업을 포함한다.

```text
la_collect_apply_results()
├─ la_collect_worker_results()
│  ├─ worker result queue 수거
│  ├─ completed set 갱신
│  ├─ frontier 전진
│  └─ pending task 재판정·배정
└─ la_retire_ready_results()
   └─ 안전한 committed_lsa·소유권 정리
```

`la_gate_drain_complete()`는 pending, In-flight List, Gate Order가 비었는지 확인한다. In-flight List가 배정·queue·실행·미수거 result의 수명을 끝까지 대표하고 Gate Order가 reader가 받아들인 COMMIT의 홀을 대표한다는 불변식이 유지되면, 이 함수를 epoch drain의 기본 판정으로 재사용할 수 있다. 정식 구현에서는 worker queue·busy·result queue 수를 진단값으로 함께 확인한다.

## 2. 추가할 상태

### 2.1 마스터 history 상태

```cpp
struct LOG_WSET_HISTORY
{
  // existing fields
  bool restart_barrier_pending;
};
```

- `wset_history_initialize()`: `restart_barrier_pending = true`
- 서버 실행 중 history capacity clear는 프로세스 재시작이 아니므로 이 플래그를 다시 설정하지 않는다. 기존 `history_start`가 clear 이전의 이력을 보수적으로 연결한다.
- 기동 실패 경로에서 history 초기화가 완료되지 않았다면 기존 initialized guard를 따른다.

### 2.2 복제 라벨

```cpp
struct LOG_REC_WSET_LABEL
{
  LOG_LSA dependency_seq;
  bool dependency_is_ref;
  bool history_reset_barrier;  // 추가
};
```

`history_reset_barrier`는 dependency의 출처가 아니라 epoch 경계다. `dependency_is_ref`와 합치지 않는다. 구조체 크기가 바뀌므로 master·copylogdb·applylogdb의 로그 포맷 호환 정책을 확정해야 한다.

### 2.3 슬레이브 task와 reader 상태

```cpp
struct LA_APPLY_TASK
{
  // existing fields
  bool history_reset_barrier;
};

struct LA_RESTART_BARRIER_CONTEXT
{
  bool active;
  LA_APPLY_TASK held_task;
};
```

reader의 임시 WSET label holder도 `history_reset_barrier`를 보존한다. 같은 `trid`의 COMMIT을 읽을 때 task로 이동하고 holder를 비운다.

## 3. 마스터 기록 순서

### 3.1 첫 COMMIT 선택 위치

`wset_find_dependency_from_history()`는 `prior_lsa_mutex` 밖에서 호출된다. 두 트랜잭션의 probe가 동시에 끝날 수 있으므로 이 위치에서 `restart_barrier_pending`을 소비하면 안 된다.

```text
log_append_repl_info_and_commit_log()
└─ prior_lsa_mutex.lock()
   ├─ barrier = restart_barrier_pending
   ├─ REPL 기록
   ├─ WSET_LABEL(dependency, source, barrier) 기록
   ├─ COMMIT 기록·commit_lsa 확정
   ├─ 모두 성공했을 때만 restart_barrier_pending = false
   └─ prior_lsa_mutex.unlock()
```

`restart_barrier_pending`의 기동 전 설정을 제외한 조회·해제가 모두 `prior_lsa_mutex` 안에 있다면 atomic 타입은 필요 없다.

### 3.2 라벨 기록 실패

현재 `log_append_wset_label_with_lock()`은 `prior_lsa_alloc_and_copy_data()`가 NULL을 반환하면 `FIXME` 후 복귀하고 COMMIT 기록을 계속한다. 재시작 경계에서는 COMMIT만 남으면 이전·이후 epoch이 다시 연결되므로 허용할 수 없다.

목표 규칙은 다음과 같다.

```text
WSET_LABEL 또는 COMMIT append 실패
→ restart_barrier_pending 유지
→ 해당 트랜잭션 COMMIT 성공으로 처리하지 않음
→ 오류 전파 또는 로그 기록 불가 절차로 종료
```

이를 위해 현재 `void` append 계층의 오류 반환 방식을 함께 검토한다. 배리어 플래그만 추가하고 이 실패 경로를 남겨 두면 정합성을 증명할 수 없다.

## 4. 슬레이브 처리 순서

### 4.1 WSET label에서 task까지

```text
LOG_DUMMY_WSET_LABEL
→ dependency_seq, dependency_is_ref, history_reset_barrier 디코드
→ trid와 함께 reader label holder에 보존
→ 같은 trid의 COMMIT에서 LA_APPLY_TASK로 이동
```

라벨 누락·손상·`trid` 불일치를 `barrier=false, dependency=NULL`인 독립 task로 변환하면 안 된다. 기존 라벨 오류 정책과 같이 명시적으로 적용을 중단하거나 안전한 전역 경로로 전환한다.

### 4.2 경계 task 보류

COMMIT task가 `history_reset_barrier=true`이면 기존 즉시 배정·pending 분기로 넣지 않는다.

```text
경계 COMMIT task 생성
→ restart_barrier_context.held_task에 보존
→ reader의 후속 로그 스캔 일시 중지
→ la_collect_apply_results() 반복
   ├─ 이전 worker result 수거
   ├─ completed set·frontier 갱신
   └─ 이전 pending 재판정·배정
→ la_gate_drain_complete()
→ held_task를 Gate Order에 등록
→ held_task의 정상 dependency 판정·배정
→ reader 로그 스캔 재개
```

후속 로그를 계속 읽어 별도 post-barrier queue에 쌓는 방식도 가능하지만, 메모리 상한·task 소유권·`required_lsa`·종료 처리가 추가된다. 첫 구현은 경계 COMMIT에서 reader 스캔을 잠시 멈추는 방식을 선택한다. worker 결과 수거는 멈추지 않으므로 drain은 계속 진행한다.

### 4.3 drain 완료 조건

개념적인 완료 조건은 다음과 같다.

```text
이전 epoch pending == empty
이전 epoch worker queue == empty
이전 epoch inflight worker == 0
이전 epoch result queue == empty
In-flight List == empty
Gate Order == empty
연속 완료 경계가 이전 epoch의 마지막 받은 COMMIT에 도달
```

현재 `la_gate_drain_complete()`의 pending·In-flight List·Gate Order 조건은 이 상태를 간접 대표한다. 이 불변식이 깨지는 코드가 없는지 검증하고, timeout 진단에서는 각 queue와 worker busy 상태를 직접 출력한다.

## 5. 재장애 분기

| 장애 시점 | 재시작 후 상태 | 안전성 |
|---|---|---|
| 마스터가 경계 라벨·COMMIT 전에 종료 | 다시 pending=true | 경계 재시도 |
| COMMIT append 후 pending 해제 전에 종료 | 다음 기동에 경계 하나 추가 | 보수적으로 안전 |
| 슬레이브가 경계 대기 중 종료 | 영속 committed_lsa에서 재독 | 경계 재처리 |
| 슬레이브가 이전 epoch drain 후 경계 task 전에 종료 | 경계 앞에서 재독 | 이전 epoch는 이미 완료, 재대기는 안전 |
| 경계 통과 후 종료 | 연속 완료 경계에서 재독 | 정상 복구 |

배리어를 위한 별도 DB 영속 상태는 두지 않는다. 로그에 남은 경계 라벨과 hole을 넘지 않는 `committed_lsa`가 재시작 상태를 재구성한다. 단, 이 결론은 슬레이브의 `committed_lsa`가 frontier를 앞서지 않는 기존 병렬 복구 설계를 전제로 한다.

## 6. 2PC와 비로그 트랜잭션

`log_complete_for_2pc()`도 `log_append_repl_info_and_commit_log()`를 사용하므로 첫 로그 순서 COMMIT에 경계를 실을 수는 있다. 그러나 현재 2PC 경로는 일반 지역 COMMIT처럼 writeset probe·publish를 수행하지 않는다. 재시작 경계가 이 순서 단절은 막을 수 있지만, 2PC 트랜잭션의 키별 의존성 누락은 별도 지원 문제로 남는다.

복제할 새 COMMIT이 없으면 경계를 로그에 남길 필요도 없다. 읽기 전용·복제 비활성 트랜잭션은 pending을 소비하지 않고, 첫 복제 COMMIT이 소비한다.

## 7. 구현 순서

1. `LOG_REC_WSET_LABEL`과 slave decode·holder·task에 `history_reset_barrier` 추가
2. 마스터 기동 시 `restart_barrier_pending=true` 초기화
3. `prior_lsa_mutex` 안에서 첫 라벨·COMMIT 선택과 pending 해제
4. WSET label append 실패가 COMMIT 성공으로 전환되지 않도록 오류 경로 보강
5. slave reader에 경계 task 홀더와 스캔 중지·결과 수거 루프 추가
6. drain 후에만 Gate Order 등록·정상 dispatch
7. 재장애·동시 COMMIT·빈 COMMIT·2PC 테스트 추가

## 8. 검증 시나리오

- 재시작 전 A와 재시작 후 C가 같은 PK·UNIQUE·FK 키를 사용하며 A가 느리게 적용되도록 구성한다. C가 A를 앞서지 않아야 한다.
- 재시작 후 서로 다른 키의 COMMIT을 동시에 시작해, 로그에 먼저 들어간 하나만 `barrier=true`인지 확인한다.
- 이전 epoch에 pending·queued·running·result-ready 상태를 하나씩 남긴 채 경계를 도달시킨다.
- 경계 대기 중 result 수거로 pending이 풀리고 frontier가 전진하는지 확인한다.
- 경계 대기 중 슬레이브를 종료한 뒤 영속 안전 경계에서 다시 읽어 경계를 재처리하는지 확인한다.
- WSET label 할당을 실패시켜 COMMIT만 로그에 남지 않는지 확인한다.
