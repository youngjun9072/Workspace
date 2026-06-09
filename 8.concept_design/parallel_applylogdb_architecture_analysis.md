# 병렬 applylogdb PoC 아키텍처 분석서

이 문서는 `2047f720807da962bf0a863e2ef115b2f0d6d8a2` 커밋부터
현재 `72099e6af` 커밋까지의 변경을 기준으로, parallel `applylogdb`
PoC의 현재 구조와 문제점을 정리한다.

핵심 변화는 기존의 리더 중심 직렬 적용 흐름을 트랜잭션 단위 병렬
적용 구조로 바꾼 것이다. 리더는 WAL을 읽고 트랜잭션별 복제 항목을
모은 뒤 커밋 로그 레코드를 만나면 워커에게 작업을 넘긴다. 워커는
자기 client session과 transaction context에서 적용, flush, commit을
수행하고, 리더는 워커 결과를 다시 모아 원래 디스패치 순서대로 retire
한다.

## 분석 범위

- 시작 커밋: `2047f7208 Add transaction-level worker queue skeleton for applylogdb parallel PoC`
- 최신 커밋: `72099e6af add upate case`
- 중심 파일: `src/transaction/log_applier.c`
- 함께 변경된 영역:
- 클라이언트/서버 연결 및 RPC 진단 로그
- 클라이언트 transaction 전역 상태
  - workspace, trigger, schema, locator client-side cache
  - HA applier state notification
  - CCI submodule pointer

## 전체 구조

현재 구조는 리더 1개와 적용 워커 여러 개로 나뉜다. 리더는 WAL
record를 순차적으로 읽고, replication data/statement record는
`la_Info.repl_lists`에 트랜잭션별로 적재한다. 커밋 로그 레코드를 만나면
`LA_APPLY_TASK`를 만들고 워커 queue에 넣는다.

워커는 작업을 받아 실제 복제 적용, flush, 클라이언트 측 commit을
수행한다. 완료 결과는 워커 result queue에 넣고, 리더가 이를 회수한다.
단, 결과 회수 순서가 아니라 리더가 디스패치한 순서대로만 global progress를
retire한다.

```text
                 active/archive WAL
                        |
                        v
              +--------------------+
              | applylogdb reader  |
              | la_apply_log_record|
              +--------------------+
                        |
          LOG_REPLICATION_DATA / STATEMENT
                        |
                        v
              +--------------------+
              | la_Info.repl_lists |
              | 트랜잭션별 item    |
              +--------------------+
                        |
                    LOG_COMMIT
                        |
                        v
              +--------------------+
              | LA_APPLY_TASK      |
              | tranid, commit_lsa |
              | repl_list pointer  |
              +--------------------+
                        |
                        v
        worker_idx = tranid % LA_APPLY_WORKER_COUNT
                        |
                        v
       +--------------------------------------------+
       | la_Dispatch_order FIFO                    |
       | seq -> worker_idx, tranid, commit_lsa     |
       | reader 전용 retire 순서 구조              |
       +--------------------------------------------+
                        |
                        v
       +----------------+----------------+----------+
       |                |                |          |
       v                v                v          v
 +------------+   +------------+   +------------+   ...
 | worker[0]  |   | worker[1]  |   | worker[2]  |
 | task queue |   | task queue |   | task queue |
 +------------+   +------------+   +------------+
       |                |                |
       v                v                v
 +------------+   +------------+   +------------+
 | apply log  |   | apply log  |   | apply log  |
 | flush      |   | flush      |   | flush      |
 | commit     |   | commit     |   | commit     |
 +------------+   +------------+   +------------+
       |                |                |
       v                v                v
 +------------+   +------------+   +------------+
 | result q   |   | result q   |   | result q   |
 +------------+   +------------+   +------------+
       |                |                |
       +----------------+----------------+
                        |
                        v
              +--------------------+
              | reader collect     |
              | worker 결과 회수   |
              +--------------------+
                        |
                        v
              +--------------------+
              | dispatch FIFO 순서 |
              | retire            |
              +--------------------+
```

## 주요 실행 흐름

### 리더 역할

리더는 WAL을 순차적으로 읽는 단일 흐름이다. `LOG_REPLICATION_DATA`와
`LOG_REPLICATION_STATEMENT`를 만나면 `la_set_repl_log()`를 통해 해당
transaction의 apply list에 item을 붙인다.

`LOG_COMMIT`을 만나면 다음 작업을 한다.

1. 커밋 LSA가 이미 처리된 LSA보다 큰지 확인한다.
2. 커밋 list에 commit node를 추가한다.
3. `LA_APPLY_TASK`를 만든다.
4. 리더가 찾은 `LA_APPLY *`를 작업에 직접 넣는다.
5. `tranid % LA_APPLY_WORKER_COUNT`로 워커를 고른다.
6. 디스패치 순서 FIFO에 먼저 entry를 넣고 `seq`를 받는다.
7. 같은 `seq`를 작업에 넣어 워커 queue에 enqueue한다.

여기서 중요한 점은 워커가 다시 `la_find_apply_list()`를 호출하지 않는다는
것이다. 리더가 이미 찾은 `LA_APPLY *`를 작업으로 넘긴다. 이는
`la_Info.repl_lists` slot 재사용과 워커 조회가 겹치는 race를 줄이기 위한
구조다.

### 워커 선택

워커 선택은 현재 고정식이다.

```text
worker_idx = tranid % LA_APPLY_WORKER_COUNT
```

이 방식은 같은 transaction이 항상 같은 워커로 가게 만든다. 워커마다
자기 client session, transaction state, workspace state를 가지므로
transaction 단위 affinity는 필요하다.

현재 상수는 다음과 같다.

- `LA_APPLY_WORKER_COUNT = 10`
- `LA_APPLY_WORKER_QUEUE_CAPACITY = 1024`
- `LA_DISPATCH_ORDER_CAPACITY = LA_APPLY_WORKER_COUNT * LA_APPLY_WORKER_QUEUE_CAPACITY + 1`
- `LA_APPLY_WORKER_REPL_ACTIVE_COUNT = 10`

`LA_APPLY_WORKER_REPL_ACTIVE_COUNT`는 주석상 test-only 성격이다.

### 워커 큐

각 워커는 입력 task queue와 출력 result queue를 가진다.

워커 구조는 대략 다음 상태를 가진다.

- pthread thread id
- mutex
- condition variable
- idle condition variable
- initialized/started/shutdown/busy flag
- task queue
- result queue

리더는 워커 input queue가 꽉 차면 `idle_cond`를 기다린다. 워커는
task를 dequeue하면 busy 상태가 되고, result queue에 결과를 넣으면 busy를
false로 바꾼 뒤 `idle_cond`를 broadcast한다.

### 디스패치 순서 FIFO

`la_Dispatch_order`는 병렬 워커 결과를 다시 직렬 retire 순서로 맞추는
핵심 구조다. 리더 전용 구조이므로 별도 lock이 없다.

동작 순서는 다음과 같다.

1. 리더가 커밋 로그 레코드를 본다.
2. 리더가 `la_dispatch_order_push()`로 FIFO entry를 만든다.
3. FIFO entry에는 `seq`, `worker_idx`, `tranid`, `rectype`, `LA_APPLY *`가 들어간다.
4. 리더가 같은 `seq`를 task에 넣어 워커에게 넘긴다.
5. 워커가 완료 후 `LA_APPLY_RESULT.seq`에 같은 값을 담아 result queue에 넣는다.
6. 리더가 result queue를 drain하며 `seq`로 dispatch entry를 찾는다.
7. entry를 `result_ready = true`로 표시한다.
8. retire는 FIFO head부터만 진행한다.

즉 워커 완료 순서는 자유롭지만, `committed_lsa`와 apply info progress는
디스패치 순서대로만 전진한다.

### 정리 단계

`la_collect_apply_results()`는 두 단계로 나뉜다.

1. `la_collect_worker_results()`
   - 모든 워커 result queue를 순회한다.
   - 도착한 result를 꺼낸다.
   - result의 `seq`로 dispatch entry를 찾는다.
   - 해당 entry에 result를 저장하고 `result_ready`를 true로 바꾼다.

2. `la_retire_ready_results()`
   - dispatch FIFO head를 확인한다.
   - head result가 아직 준비되지 않았으면 즉시 멈춘다.
   - 워커 error가 있으면 error를 반환한다.
   - commit node를 정리한다.
   - `LA_APPLY` slot을 retire 시점에 반환한다.
   - `la_Info.committed_lsa`와 `committed_rep_lsa`를 갱신한다.
   - insert/update/delete/schema/fail counter를 누적한다.
   - reader-side transaction을 commit한다.

`LA_APPLY` slot을 워커 완료 시점이 아니라 retire 시점에 반환하는 것이
중요하다. 워커가 먼저 끝났다고 slot을 즉시 반환하면 리더가 그 slot을
다른 transaction에 재사용할 수 있고, 아직 앞선 dispatch entry가 retire되지
않은 상태와 충돌할 수 있다.

## 워커별 상태 격리

parallel apply에서 가장 어려운 부분은 queue가 아니라 기존 client-side
전역 상태를 워커별로 분리하는 일이다. 기존 serial apply는 process-global
상태를 전제로 한 코드가 많다.

### 클라이언트 transaction 상태

`transaction_cl.c`의 주요 client transaction 상태가 thread-local로 바뀌었다.

예:

- `tm_Tran_index`
- `tm_Tran_isolation`
- `tm_Tran_wait_msecs`
- `tm_Tran_ID`
- `tm_Tran_invalidate_snapshot`
- query begin/timeout 정보
- savepoint list

워커마다 독립 client transaction처럼 동작해야 하므로 이 분리는 필수다.

### 작업 공간과 객체 상태

`work_space.c`, `trigger_manager.c`, schema manager 주변 상태도 워커별로
분리되었다.

대표적인 thread-local 대상:

- MOP table
- resident class cache
- workspace statistics
- dirty MOP 상태
- trigger recursion depth
- deferred trigger context
- trigger schema/object map

이 분리가 없으면 한 워커의 client object workspace 변경이 다른 워커의
apply 흐름을 오염시킬 수 있다.

### locator keep 캐시

`locator_Keep`과 packed request area buffer는 thread-local로 바뀌었다.

locator keep cache는 copy area, lockset, lockhint, packed area 같은 재사용
buffer를 가진다. 여러 워커가 이를 공유하면 RPC payload 구성이나 object
fetch/flush 과정에서 buffer가 덮어써질 수 있다.

워커 종료 시점에는 `locator_free_areas()`를 호출해 해당 워커의
thread-local locator cache를 정리한다.

### 워커 임시 context

워커마다 `LA_APPLY_WORKER_CONTEXT`를 가진다.

포함 항목:

- `worker_idx`
- record type scratch buffer
- undo unzip buffer
- redo unzip buffer
- reusable recdes pool

이 context는 apply 중 필요한 임시 buffer를 worker별로 분리한다.

## 워커 세션 모델

워커 thread 시작 흐름은 다음과 같다.

```text
worker thread 시작
  -> error context 등록
  -> la_apply_worker_start_session()
       -> worker client 등록
       -> client context 시작
  -> la_apply_worker_context_init()
  -> task 처리 loop
  -> la_apply_worker_context_final()
  -> la_apply_worker_end_session()
  -> locator_free_areas()
  -> error context 해제
```

워커 session 시작은 `la_worker_init_mutex`로 직렬화된다. 주석을 보면
`net_client_sub_init`, system parameter cache, client target state 등 아직
동시 초기화가 안전하지 않은 shared client global이 남아 있음을 전제로 한다.

## HA 상태 통지 처리

워커 session은 HA applier state notification을 보내지 않도록 막혀 있다.
HA applier의 global state는 리더가 대표로 관리해야 한다. 워커 session이
각자 `WORKING`, `DONE`, `RECOVERING` 같은 상태를 통지하면 master/server가
잘못된 상태 전이를 볼 수 있다.

## 진단 로그와 계측 구조

이 브랜치는 debug build에서 병목을 찾기 위한 계측을 대량 추가했다.

주요 계측 항목:

- reader WAL record type histogram
- reader IO 시간
- replication item 생성 시간
- commit record 처리 시간
- dispatch-order push 시간
- worker enqueue 대기 시간
- worker queue depth
- worker result queue depth
- result queue dwell time
- worker apply 시간
- mid flush/final flush 시간
- db commit 시간
- post commit cleanup 시간
- empty commit/non-empty commit 구분
- cache buffer worker별 access/contention/wait
- RPC call별 timing
- client connection fd 및 server core mapping
- dispatch head blocker stage
- 첫 insert부터 마지막 commit retire까지의 window

이 계측의 목적은 다음 질문에 답하는 것이다.

```text
병목이 reader WAL scan/dispatch에 있는가,
worker apply에 있는가,
flush에 있는가,
server RPC 처리에 있는가,
cache buffer contention에 있는가,
ordered retire에 있는가?
```

## 설계 의도

현재 구조는 item 단위 병렬화가 아니라 transaction 단위 병렬화다.

기존 apply 경로는 client transaction, workspace, locator, trigger 상태를
전제로 한다. 하나의 transaction 내부 item들을 병렬화하려면 visibility,
object state, flush ordering, unique index 처리까지 더 깊게 바꿔야 한다.

따라서 transaction 전체를 하나의 worker에 맡기는 방식은 PoC로는 보수적이고
현실적인 선택이다. 대신 global progress는 dispatch 순서대로만 전진하므로
느린 선행 transaction이 전체 retire를 막을 수 있다.

## 문제점과 위험 요소

### 1. 정리 단계의 선두 대기 문제

retire는 dispatch FIFO head부터만 진행한다. 어떤 worker가 오래 걸리는
transaction을 처리 중이면, 다른 worker가 뒤의 transaction을 모두 끝내도
그 결과들은 retire되지 못한다.

영향:

- 병렬 apply는 끝났는데 `committed_lsa`가 전진하지 않을 수 있다.
- result queue와 dispatch FIFO 뒤에 완료 결과가 쌓일 수 있다.
- HA apply progress가 실제 worker 처리량보다 느리게 보일 수 있다.

현재 계측으로 head blocker stage, result queue dwell time,
`reader_dispatch_while_head_blocked_total`을 확인할 수 있다.

### 2. `tranid % worker_count` 기반 정적 분산

worker 선택이 transaction 크기나 queue depth를 보지 않고 transaction id만
본다.

영향:

- 특정 modulo 값에 큰 transaction이 몰리면 worker skew가 생긴다.
- 일부 worker는 idle인데 특정 worker queue만 길어질 수 있다.
- worker 수를 늘려도 throughput이 선형으로 늘지 않을 수 있다.

개선 방향:

- transaction이 처음 등장할 때 queue depth가 낮은 worker를 고른다.
- 선택된 worker id를 transaction apply state에 저장한다.
- 이후 같은 transaction은 저장된 worker로 보낸다.

### 3. 워커 시작이 아직 공유 클라이언트 전역 상태에 의존

`la_worker_init_mutex`가 worker client context 초기화를 직렬화한다. 이는
아직 동시 초기화가 안전하지 않은 client global이 남아 있다는 뜻이다.

영향:

- startup 단계는 mutex 덕분에 안전하지만 구조적으로 완전한 격리는 아니다.
- 나중에 worker 재시작이나 dynamic scaling이 들어오면 race가 재발할 수 있다.
- shared client target/system parameter cache 경로를 더 확인해야 한다.

### 4. `LA_APPLY *` 수명 규칙이 섬세하다

task는 reader가 찾은 `LA_APPLY *`를 직접 들고 worker로 간다. 이 포인터가
안전하려면 apply slot이 worker 완료 시점이 아니라 ordered retire 시점까지
재사용되지 않아야 한다.

영향:

- 수명 규칙이 코드 여러 위치에 흩어져 있다.
- 나중에 cleanup 코드를 고치다가 slot reuse race를 다시 만들 수 있다.
- raw pointer만으로는 slot이 여전히 같은 transaction 소유인지 검증하기 어렵다.

개선 방향:

- apply slot에 generation counter를 둔다.
- task에는 raw pointer 대신 `{slot_index, generation}`을 담는다.
- worker 시작과 retire 시점에 tranid/generation assert를 추가한다.

### 5. `la_Info`의 소유권이 섞여 있다

`la_Info`는 reader-owned field, shared input, worker task가 참조하는
포인터의 원천을 모두 담고 있다.

영향:

- 어떤 field를 누가 수정할 수 있는지 명확하지 않다.
- 작은 변경으로 worker가 reader-owned 상태를 건드릴 위험이 있다.
- thread-safety를 확인하려면 `log_applier.c` 전체 흐름을 따라가야 한다.

개선 방향:

- reader global state, immutable task payload, worker-local apply context를
  구조적으로 분리한다.
- shared field마다 owner와 접근 가능 phase를 문서화한다.

### 6. 워커 결과 큐 초과가 종료로 이어진다

`la_enqueue_apply_result()`는 result queue가 꽉 차면 기다리지 않고 실패를
반환한다. 이 경우 `la_applier_need_shutdown`으로 이어질 수 있다.

영향:

- reader collect/retire가 느린 상황에서 일시적 적체가 applier 종료로 바뀐다.
- head-of-line blocking이 발생하면 result queue overflow 가능성이 커진다.

개선 방향:

- result enqueue도 condition variable로 대기 가능하게 만든다.
- reader가 dispatch 전에 collect를 더 적극적으로 수행한다.
- 전체 in-flight dispatch 수를 retire progress 기준으로 제한한다.

### 7. 역압이 워커별 큐에만 걸린다

reader는 선택된 worker input queue가 꽉 찼을 때만 기다린다. dispatch FIFO
크기, retire lag, result queue dwell time을 기준으로 한 global throttle은 없다.

영향:

- retire가 막혀도 reader는 계속 dispatch할 수 있다.
- 완료됐지만 retire되지 않은 결과가 길게 쌓일 수 있다.
- memory pressure와 latency가 커진다.

### 8. 디버그 계측 코드가 지나치게 크다

현재 `log_applier.c`에는 기능 코드와 debug 계측 코드가 강하게 섞여 있다.
counter, timestamp, stage log가 많아져 실제 동작을 리뷰하기 어려워졌다.

영향:

- 기능 변경과 계측 변경이 같은 파일에서 계속 충돌할 수 있다.
- release/debug build 차이를 추적하기 어렵다.
- 일부 direct `er_log_debug()` 호출이 `LA_DEBUG_LOG` convention과 다를 수 있다.

개선 방향:

- parallel apply 계측 구조를 별도 helper 영역으로 분리한다.
- debug macro 사용 원칙을 통일한다.
- release build에서 남는 비용과 로그 호출을 점검한다.

### 9. PoC/test-only 제어값이 일반 실행 경로에 남아 있다

`LA_APPLY_WORKER_REPL_ACTIVE_COUNT`는 주석상 test-only다. worker index가 이
값보다 크면 add/flush를 skip하는 실험용 코드가 존재한다.

영향:

- 값이 바뀌면 실제 apply 결과가 달라질 수 있다.
- 성능 실험과 correctness 동작이 섞인다.
- production 반영 전에는 제거하거나 명확한 test hook으로 분리해야 한다.

### 10. 리더 측 apply info commit이 임시 변경 상태다

retire 단계에서 `la_reader_commit_apply_info()` 호출이 주석 처리되고
`db_commit_transaction()`으로 대체되어 있다. 주석에도 PoC 병목 확인용이라고
되어 있다.

영향:

- `_db_ha_apply_info` update semantics가 기존 serial path와 다를 수 있다.
- crash/restart 후 재시작 LSA 계산이 달라질 수 있다.
- 현재 성능 수치에는 실제 apply info update 비용이 빠져 있을 수 있다.

이 부분은 production 전 correctness gap으로 봐야 한다.

### 11. memory/VSZ 증가 문제가 구조적으로 해결되지 않았다

worker 수 증가로 thread-local cache, unzip buffer, recdes pool, glibc arena가
늘어난다. history에는 VSZ 증가를 완화하기 위해 `max_mem_size` floor를 올린
커밋이 있다.

영향:

- worker 수에 따라 가상 메모리 사용량이 크게 증가할 수 있다.
- throughput만 보고 worker 수를 늘리면 memory limit에 걸릴 수 있다.
- 실제 RSS와 VSZ를 나눠 측정해야 한다.

### 12. 서버 측 병렬성은 간접적이다

apply worker는 client RPC를 통해 server에 요청한다. 실제 server-side 병렬성은
server worker pool의 connection/core mapping에 좌우된다. 그래서 connection
fd, server core mapping, RPC timing 로그가 추가되었다.

영향:

- client worker 수가 곧 server 병렬 실행 수를 의미하지 않는다.
- connection mapping이 한쪽으로 쏠리면 server에서 병렬성이 줄어들 수 있다.
- RPC timing과 server worker diagnostics를 함께 봐야 한다.

### 13. error 전파와 shutdown 경계가 거칠다

worker에서 오류가 나면 result에 error를 담고, reader retire 단계에서 이를
반환한다. queue enqueue 실패나 worker 초기화 실패는 `la_applier_need_shutdown`
으로 이어진다.

영향:

- 어느 transaction이 실패했고 어디까지 retire됐는지 복구 판단이 복잡하다.
- result는 준비됐지만 앞선 head가 막혀 error 전파가 늦어질 수 있다.
- shutdown 중 queue에 남은 task/result 처리 정책이 더 명확해야 한다.

### 14. schema/sysop/abort 경로 검증이 더 필요하다

일반 DML commit 외에도 `LOG_SYSOP_END`, schema replication, abort 경로가
parallel dispatch/retire 구조와 섞인다.

영향:

- DML 중심 workload에서는 정상으로 보여도 schema 변경이 섞이면 ordering
  문제가 드러날 수 있다.
- sysop end 처리를 commit dispatch로 미룬 변경은 crash/recovery 및 HA
  apply progress와 함께 검증해야 한다.

## 검증 체크리스트

production 수준으로 올리기 전에 최소한 다음 항목을 검증해야 한다.

- out-of-order worker completion 상황에서 `committed_lsa`가 단조 증가하는지
- `_db_ha_apply_info` 기반 crash/restart가 기존 serial path와 같은지
- long transaction 하나 뒤에 short transaction 다수가 붙는 workload
- transaction id skew workload
- worker input queue full 상황
- worker result queue full 상황
- insert/update/delete 혼합 workload
- unique index가 있는 table apply
- trigger가 있는 table apply
- schema replication과 DML이 섞인 workload
- `LOG_SYSOP_END` ordering
- abort transaction cleanup
- HA state transition과 worker session 동시 접속
- worker count별 RSS/VSZ 변화
- release build에서 debug log/counter 비용 제거 여부

## 요약

이 브랜치는 transaction 단위 parallel apply pipeline을 만들고, dispatch FIFO로
global commit progress 순서를 보존한다. 구조 방향은 PoC로 타당하다. 기존
serial apply path를 크게 갈아엎지 않고, 비싼 apply/flush/commit 구간을
worker로 분산시키기 때문이다.

다만 아직 production 구조라고 보기는 어렵다. 핵심 위험은 ordered retire의
head-of-line blocking, 정적 worker 분산, hidden shared client global,
`LA_APPLY *` slot 수명 규칙, `_db_ha_apply_info` commit semantics 변경,
result queue backpressure 부재다.

현재 계측은 병목을 찾기에는 충분히 풍부하다. 다음 단계는 계측 결과를 바탕으로
정말 병목이 worker apply인지, server RPC인지, flush인지, ordered retire인지
분리하고, correctness gap부터 닫는 것이다.

---

# 부록 A. 마스터(cub_server) 측 복제 로그 생성 경로 — (Phase 2) 의존성 부여 지점 분석

위 본문은 **슬레이브(applylogdb)** 측 PoC 구조다. 여기서는 MySQL WRITESET처럼 **마스터가 트랜잭션별 의존성(logical clock / conflict key)을 미리 계산해 repl 로그에 실어 보내는** Phase 2 방향을 위해, 마스터(`cub_server`, `SERVER_MODE`)의 repl 로그 생성 경로를 코드로 분석한다. (배경·근거는 `reference/mysql/11.writeset_fk_dependency_tracking.md`)

브랜치 `feature/parallel_applylogdb_poc` 기준.

## A.0 데이터 흐름 한눈에 (메모리 → 디스크 복제 로그 → 슬레이브)

먼저 "복제 로그"가 어디서 어떤 형태로 만들어지는지부터 잡는다. `tdes->repl_records[]`는 **복제 로그 자체가 아니라, commit 때 복제 로그가 되는 트랜잭션 단위 메모리 스테이징 버퍼**다. 내용은 디스크 복제 로그와 동일하다(commit 시 페이로드를 그대로 복사).

```text
행 변경(INSERT/UPDATE/DELETE)
   │  repl_log_insert()                                   (replication.c:293)
   ▼
① tdes->repl_records[]   — 메모리, 트랜잭션 단위로 쌓임 (아직 WAL 아님)
   │     · struct log_repl: (class+PK) 직렬화된 repl_data + inst_oid + rcvindex
   │  commit 시 log_append_repl_info_with_lock()가 이 배열을 순회        (log_manager.c:4565)
   │     · prior_lsa_alloc_and_copy_data(... repl_rec->repl_data ...) ← 페이로드 그대로 복사 (log_manager.c:4574)
   ▼
② LOG_REC_REPLICATION + payload   — 디스크 WAL = "진짜 복제 로그 레코드"   (log_record.hpp:227-233)
   │  copylogdb가 복사 → applylogdb가 la_make_repl_item()으로 파싱        (log_applier.c)
   ▼
③ LA_ITEM   — 슬레이브 측 파싱 형태 (class_name + PK + operation)
```

- **①** = 복제 로그의 *메모리 전구체*(마스터, commit 전). **②** = 실제 디스크 복제 로그(copylogdb가 복사·applylogdb가 읽는 그것). **③** = 슬레이브 파싱 형태.
- 의존성(seqno/conflict key)을 넣을 **계산 자리는 ①→② 전이가 일어나는 commit 직렬화 구간**(A.4·A.5)이고, **실어 보낼 자리는 ②의 헤더 또는 페이로드**다.
- 그리고 **conflict key의 원천이 바로 ①의 `repl_records[]`** 다 — 이미 "이 트랜잭션이 바꾼 (class, PK)" 목록이라, 별도 writeset 추적 없이 그대로 재사용한다(A.3·A.6a).

## A.1 repl 레코드 — 메모리 구조와 디스크 구조

행이 바뀌면 마스터는 먼저 **tdes 안의 in-memory repl 레코드 배열**에 쌓고, commit 시 디스크 WAL로 append한다. 두 구조가 다르다.

메모리 구조 `LOG_REPL_RECORD` — `src/transaction/replication.h:78-89`:

```c
struct log_repl
{
  LOG_RECTYPE repl_type;   /* LOG_REPLICATION_DATA / ..._SCHEMA */
  LOG_RCVINDEX rcvindex;   /* INSERT / DELETE / UPDATE_START/END (operation) */
  OID inst_oid;            /* ← 바뀐 행의 OID */
  LOG_LSA lsa;
  char *repl_data;         /* 직렬화 페이로드: [packed_key_len][class_name][PK value] */
  int length;
  LOG_REPL_FLUSH must_flush;
  bool tde_encrypted;
};
```

디스크에 실제 append되는 헤더 `LOG_REC_REPLICATION` — `src/transaction/log_record.hpp:227-233`:

```c
struct log_rec_replication
{
  LOG_LSA lsa;
  int length;     /* 뒤따르는 가변 페이로드(repl_data) 길이 */
  int rcvindex;
};
```

> 즉 **개별 repl 레코드는 (class + PK + operation + 행 OID)를 이미 보유**한다. 새 의존성 필드(`seqno`/`last_committed` 또는 conflict key)는 **헤더에 넣으면**(`log_rec_replication`에 `INT64` 추가) 디스크 포맷·applier 파서를 같이 바꿔야 하고, **페이로드(`repl_data`)에 넣으면** 헤더는 불변이고 applier 디코드만 바꾸면 된다.

## A.2 repl 레코드 생성·직렬화 — `repl_log_insert` (`replication.c:293`)

호출자는 `locator_sr.c:8086`(INSERT/DELETE)·`8849/8859`(UPDATE)·`serial.c:980`. 페이로드 직렬화부 — `src/transaction/replication.c:391-419`:

```c
repl_rec->length  = OR_INT_SIZE;                              /* packed_key_value_size */
repl_rec->length += or_packed_string_length (class_name, &strlen);
repl_rec->length += OR_VALUE_ALIGNED_SIZE (key_dbvalue);
ptr = (char *) malloc (repl_rec->length);
...
repl_rec->repl_data = ptr;
ptr_to_packed_key_value_size = ptr;     /* 앞 4바이트는 PK 길이용 자리 */
ptr += OR_INT_SIZE;
ptr = or_pack_string_with_length (ptr, class_name, strlen);   /* class_name */
ptr = or_pack_mem_value (ptr, key_dbvalue, &packed_key_len);  /* PK 값 */
or_pack_int (ptr_to_packed_key_value_size, packed_key_len);
```

> 여기는 **트랜잭션 진행 중** 시점이라 commit 순번(monotonic seq)을 아직 모른다. 따라서 seq는 여기서 넣을 수 없고 A.4의 commit 직렬화 지점에서 채워야 한다. conflict key 원재료(class+PK)는 이미 이 페이로드에 다 들어 있다.

## A.3 트랜잭션 단위 집계 그릇 — `LOG_TDES` (`log_impl.h:522-531`)  ★재사용 핵심

```c
int num_repl_records;          /* repl 레코드 배열 크기 */
int cur_repl_record;           /* 지금까지 쌓인 repl 레코드 수 */
int append_repl_recidx;        /* WAL append 진행 인덱스 */
int fl_mark_repl_recidx;       /* flush mark 시작 인덱스 */
struct log_repl *repl_records; /* ← 이 트랜잭션의 repl 레코드 배열 = writeset 후보 */
LOG_LSA repl_insert_lsa;
LOG_LSA repl_update_lsa;
...
int suppress_replication;      /* 세트되면 repl 로그 미작성 */
```

> **`tdes->repl_records[0..cur_repl_record-1]` 가 곧 "이 트랜잭션이 바꾼 (class, OID, PK) 목록" = writeset 그 자체다.** 별도 conflict-set 구조를 새로 만들 필요 없이 이 배열을 commit 시 훑으면 된다. seq/last_committed는 트랜잭션당 1개이므로 이 구조체에 `INT64 repl_seqno; INT64 last_committed;` 를 추가하는 게 자연스럽다.

## A.4 commit 직렬화 지점 — `log_append_repl_info_and_commit_log` (`log_manager.c:4643-4661`)  ★순번 채번 자리

repl 레코드들은 commit 로그와 **원자적으로** append되며, 그 구간이 전역 락으로 직렬화된다:

```c
// NOTE: Atomic write of replication log and commit log is crucial for replication consistencies.
log_Gl.prior_info.prior_lsa_mutex.lock ();            /* ← 전역 commit 직렬화 락 */
log_append_repl_info_with_lock (thread_p, tdes, true);          /* repl 레코드들 append */
log_append_commit_log_with_lock (thread_p, tdes, commit_lsa);   /* commit 레코드 append */
log_Gl.prior_info.prior_lsa_mutex.unlock ();
```

> 이 `prior_lsa_mutex` 구간이 **트랜잭션 commit이 전역적으로 한 줄로 직렬화되는 유일 지점**이다. MySQL의 "commit 순서 = logical clock 부여"에 정확히 대응하므로, **여기서 전역 atomic 카운터로 `seqno`를 채번하고, 직전 충돌 트랜잭션의 seqno로 `last_committed`를 산출**하는 것이 가장 자연스럽다.
> (추측) commit_lsa 자체가 단조 증가값이라 seqno로 재사용도 고려할 수 있으나, LSA는 (pageid, offset) 2워드라 의존성 비교용 64bit 단조 순번이 더 단순하다 — 검증 필요.

## A.5 repl → 디스크 append 루프 (`log_manager.c:4565-4601`)  ★conflict key 수집 자리

A.4의 `log_append_repl_info_with_lock` 내부는 이미 `repl_records[]`를 순회한다:

```c
while (tdes->append_repl_recidx < tdes->cur_repl_record)
  {
    repl_rec = &tdes->repl_records[tdes->append_repl_recidx];
    if ((repl_rec->repl_type == LOG_REPLICATION_DATA || ...STATEMENT) && (... must_flush ...))
      {
        node = prior_lsa_alloc_and_copy_data (..., repl_rec->length, repl_rec->repl_data, ...);
        ...
        log = (LOG_REC_REPLICATION *) node->data_header;
        ...
        log->length   = repl_rec->length;
        log->rcvindex = repl_rec->rcvindex;
        ...
      }
    ...
  }
```

> **이 루프가 이미 락 안에서 repl 레코드를 한 번 순회**하므로, 같은 자리에서 각 `repl_rec`의 `inst_oid`(또는 페이로드의 PK)를 모아 트랜잭션 conflict key 집합을 만들면 **추가 순회·자료구조 없이** 끝난다. 그리고 `node->data_header`(=`LOG_REC_REPLICATION`)나 페이로드에 seqno를 1회 실으면 된다.

## A.6 구분(의존성)에 재사용 가능한 기존 자료구조

### (a) `tdes->repl_records[]` = writeset  ★가장 직접적
A.3·A.5 그대로. (class + OID + PK)를 정확한 입도로 이미 보유하고, read 락 잡음이 없다.

### (b) lock manager 트랜잭션별 락 목록 — `LK_TRAN_LOCK` (`lock_manager.c:322-333`)

```c
struct lk_tran_lock
{
  ...
  LK_ENTRY *inst_hold_list;   /* 인스턴스 락 보유 리스트 */
  LK_ENTRY *class_hold_list;  /* 클래스 락 보유 리스트 */
  ...
  int inst_hold_count;
  int class_hold_count;
  ...
};
```

`lk_Gl.tran_lock_table[tran_index]`로 접근하며, `LK_ENTRY.tran_next` 링크 → `res_head->key.oid / key.class_oid`로 **트랜잭션이 잡은 (OID, class OID)** 를 순회할 수 있다. 단 입도가 행 OID 단위(논리 PK 아님)이고 **read 락도 섞여 있어** `granted_mode` 필터가 필요하다 → repl_records보다 거칠다.

### (c) FK 부모 PK — `locator_check_foreign_key` (`locator_sr.c:4134-4146`)

```c
BTID_COPY (&local_btid, &index->fk->ref_class_pk_btid);   /* 부모 PK 인덱스 */
COPY_OID (&part_oid,   &index->fk->ref_class_oid);        /* 부모 클래스 */
...
ret = xbtree_find_unique (thread_p, &local_btid, S_SELECT_WITH_LOCK,
                          key_dbvalue, &part_oid, &unique_oid, true);  /* key_dbvalue = 참조 부모 PK */
```

> `repl_records[]`는 자식이 *바꾼* 행(자식 PK)만 담고 *참조한* 부모 PK는 담지 않는다. 부모-자식 의존성을 conflict key로 표현하려면 **이 지점에서 (부모 class OID, 부모 PK 값)을 tdes 보조 리스트로 수집**해 conflict key 집합에 더해야 한다. FK 메타는 `OR_FOREIGN_KEY`(`object_representation_sr.h:130-141`: `ref_class_oid`, `ref_class_pk_btid`, `del/upd_action`).

## A.7 변경 분류표

| 구분 | 항목 | 위치 |
|---|---|---|
| **새로** | 전역 atomic 단조 카운터(`seqno`) (+선택: writeset history) | `log_Gl.prior_info` 부근 |
| 새로 | `tdes->repl_seqno`, `tdes->last_committed` | `log_impl.h` LOG_TDES |
| **변경** | commit 락 구간에서 seq 채번 + conflict key 수집 | `log_manager.c:4565~4661` |
| 변경 | seqno/conflict key를 로그에 실음 | 페이로드(`replication.c:391~419`) 권장 / 헤더(`log_record.hpp:227~233`)는 디스크포맷 변경 동반 |
| 변경 | repl 디코드 → 의존 그래프 | `log_applier.c` repl 파싱부(슬레이브) |
| **재사용** | `tdes->repl_records[]` = writeset | `log_impl.h:522`, `replication.h:78-89` |
| 재사용 | lock 보유 목록(거침) | `lock_manager.c:322-333` |
| 재사용 | FK 부모 PK | `locator_sr.c:4134-4146`, `object_representation_sr.h:130-141` |

## A.8 최소 변경 경로 (권장)

1. 전역 atomic `seqno` 카운터 + `tdes`에 `repl_seqno`/`last_committed` 2필드 추가.
2. `log_append_repl_info_with_lock`의 기존 `repl_records[]` 순회(A.5)에서 `(class, PK)` conflict key를 모음 + FK 자식이면 `locator_check_foreign_key`(A.6c)에서 수집한 부모 PK를 합침.
3. 같은 `prior_lsa_mutex` 구간(A.4)에서 `seqno` 채번, (옵션 a면) 전역 writeset history와 비교해 `last_committed` 산출.
4. `seqno`(+옵션 b면 conflict key 원재료)를 **repl 페이로드에 1회** 실음 → 디스크 헤더 불변.
5. 슬레이브 `log_applier.c`가 디코드해 코디네이터가 `last_committed`(또는 conflict key 교집합) 기준으로 병렬/직렬 판단.

> 옵션 a(가공된 `last_committed`만 전송, 슬레이브 단순) vs 옵션 b(conflict key 원재료 전송, 슬레이브가 비교, 마스터 가벼움)는 `coordinator_design.md` D.4의 옵션 a/b와 동일한 선택이다(설계는 옵션 a 확정).

---

# 부록 B. 그룹커밋(group commit) — CUBRID 로그 flush 메커니즘

> 분석 시점 2026-06-09 · 소스: `src/transaction/log_page_buffer.c`, `log_manager.c`, `log_impl.h`, `base/system_parameter.c`
> 용도: 마스터·슬레이브가 commit durability를 어떻게 배칭하는지, 그리고 본 설계(D.3 commit 게이트, D.4 writeset)와의 관계.

## B.1 한 줄 요약
CUBRID 그룹커밋은 **여러 트랜잭션의 commit 로그를 한 번의 디스크 flush(fsync)로 묶어 내구화**하는 것이다. **LSA 채번/순서가 아니라 "내구화(flush) 시점"만 배칭**한다 — commit_lsa 순서는 그룹커밋과 무관하게 `prior_lsa_mutex`에서 직렬로 정해진다(A.4).

## B.2 메커니즘 (코드)
- **파라미터** `group_commit_interval_in_msecs`(`system_parameter.c:455,2773`), **기본값 0 = OFF**. `>0`이면 `LOG_IS_GROUP_COMMIT_ACTIVE()`(`log_impl.h:124`) 참.
- **log-flush daemon**(`log_manager.c` `log_flush_daemon_init`, looper 주기 = `log_get_log_group_commit_interval`): interval>0이면 그 주기마다, 0이면 요청 시 깨어나 `logpb_flush_pages_direct`로 append된 로그 페이지를 **한 번에 flush**하고 `group_commit_info.gc_cond`를 broadcast(`log_flush_execute:10388–10393`).
- **commit 경로**: 트랜잭션이 commit 로그를 prior-LSA 리스트에 append(A.4) 후 `logpb_flush_pages(flush_lsa)`(`log_manager.c:4401`)로 자기 `commit_lsa`까지 내구화를 보장. `logpb_flush_pages`(`log_page_buffer.c:3974~`)는 (async_commit × group_commit) **4경우**로 분기:

  | async | group | 동작 |
  |---|---|---|
  | ✕ | ✕ | (기본) LFT 깨우고 **대기** |
  | ✕ | ○ | **LFT 안 깨우고 대기**(타이머 flush를 기다림) |
  | ○ | ✕ | LFT 깨우고 즉시 반환(비동기) |
  | ○ | ○ | 그냥 반환 |

- **대기 조건**: 커밋 스레드는 `nxio_lsa`(다음 IO LSA = 내구 경계)가 자기 `flush_lsa` 이상이 될 때까지 `gc_cond`에서 timed-wait(`log_page_buffer.c:4068~4090`). daemon이 flush하고 `nxio_lsa`를 전진시키면 깨어난다.

→ 그룹커밋 **ON**이면 개별 commit이 LFT를 깨우지 않고 타이머 flush를 기다려 더 많은 commit이 한 fsync로 묶인다(처리량↑, commit 지연 최대 interval↑). **OFF(기본)** 이면 commit마다 daemon을 깨우되, flush 진행 중 도착한 commit들은 자연히 한 flush로 묶인다(지연 최소).

## B.3 핵심 — 그룹커밋은 "순서"가 아니라 "flush"만 배칭한다
`commit_lsa`(=순번)는 `prior_lsa_mutex` 아래 직렬 append로 결정된다(A.4, 설계 D.4). 그룹커밋은 그 뒤 **디스크 flush를 모을 뿐** LSA 순서·writeset 계산에 개입하지 않는다. 따라서:
- **D.4 writeset/`last_committed` 계산은 그룹커밋과 독립** — append(채번) 시점에 계산되고 flush 배칭과 무관하다. 마스터에 writeset 계산을 얹어도 그룹커밋 동작은 그대로다.
- 마스터 `prior_lsa_mutex` 임계구간 비용(qna_v2 Q7)과 그룹커밋은 **별개 축** — 그룹커밋은 임계구간 *밖*(flush)을 배칭하므로 임계구간을 늘리지 않는다.

## B.4 설계와의 관계 — 슬레이브에서 어떻게 처리하나 (D.3와 결합)
슬레이브도 CUBRID 서버이므로 **워커의 commit은 슬레이브 서버의 prior-LSA + flush daemon을 그대로 탄다.** 본 설계 D.3의 "워커 durable commit 차례 게이트"와 그룹커밋은 **역할이 달라 서로 결합된다**:
- **D.3 게이트 = commit 레코드 *append 순서*를 source 순서로 직렬화**(가볍고 in-memory, `commit_lsa` 순서 보장).
- **그룹커밋 = 그 commit들의 *fsync를 한 번에* 배칭**(무거운 I/O 분할상환).

→ 워커들이 순서대로 commit 레코드를 append(게이트)하고, 슬레이브 flush daemon이 그 묶음을 한 flush로 내구화한 뒤 게이트가 순서대로 풀린다. 이는 **MySQL의 ordered_commit(flush→sync→commit 3단계) + group commit과 동형**이며, qna_v2 **Q20**(게이트만 차용하고 group flush가 없으면 fsync×N로 직렬 applier만 못해질 위험)을 **정확히 해소**한다.

- **권고**: 병렬 applylogdb는 **슬레이브 서버의 그룹커밋을 활용**해, D.3 게이트가 "commit당 개별 fsync"로 퇴화하지 않게 한다 — 게이트는 *append 순서*만 강제하고, *내구화*는 group flush에 맡긴다.
- **주의(측정 항목)**: 그룹커밋 ON(interval>0)이면 commit 지연이 최대 interval만큼 늘어 D.3 게이트의 head-of-line 대기(qna_v2 Q2·Q20·Q68)와 합쳐질 수 있으므로, interval은 슬레이브 워크로드로 튜닝·실측한다. (기본 0이면 즉시 flush라 지연은 작지만 fsync 묶임도 적다.)
- **정합성**: 그룹커밋은 내구화 *시점*만 미루므로, D.3가 요구하는 "gap-free `committed_lsa`"는 **flush가 완료된(=nxio_lsa가 넘어간) commit_lsa까지만 진도로 인정**하면 그대로 성립한다(미flush 구간을 진도로 올리지 않음 → 재시작 정합 유지, qna_v2 Q21과 연계).
