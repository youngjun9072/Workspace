# 병렬 applylogdb 코디네이터 컨셉

이 문서는 parallel `applylogdb` PoC 이후 실제 구현으로 넘어가기 위한 병렬화
컨셉을 정리한다. 상세 자료구조나 API 설계가 아니라, 어떤 책임을 새 모듈로
분리할지와 transaction 간 충돌/순서를 어떻게 다룰지를 잡는 문서다.

## 배경

현재 PoC는 commit record를 만나면 transaction id로 worker를 고른다.

```text
worker_idx = tranid % LA_APPLY_WORKER_COUNT
```

이 방식은 단순하지만 두 가지 문제가 있다.

- 서로 관련 있는 transaction도 동시에 실행될 수 있다.
- 서로 독립적인 transaction도 특정 worker에 몰릴 수 있다.

가장 중요한 문제는 첫 번째다. 병렬 적용에서 worker를 고르는 방식보다 먼저
해결해야 할 것은 transaction 간 충돌과 순서 보존이다. 서로 영향을 주는
transaction을 동시에 실행하면 복제 결과가 원본 실행 순서와 달라질 수 있다.

따라서 구현 단계에서는 단순 worker picker가 아니라, transaction 간 의존성을
판단하고 순차 실행이 필요한 작업을 막아 주는 코디네이터가 필요하다.

## 다른 DBMS의 처리 방식

### MySQL

MySQL replication은 source가 변경 내용을 binary log에 기록하고, replica가 이를
relay log로 받아 적용하는 구조다. 여기서 source는 원본 서버, replica는 복제
대상 서버를 뜻한다. Replica 내부에서는 I/O receiver thread가 source의 binary
log를 받아 relay log에 저장하고, SQL applier가 relay log의 transaction을
적용한다. 병렬 적용을 사용하는 경우에는 coordinator thread가 relay log를
순차적으로 읽고 transaction을 worker thread에 배정한다 [1][2].

설계 참고용으로 단순화하면 다음과 같다. MySQL WorkLog의 multithreaded slave
설계에서도 coordinator가 event를 읽고 `hash(E)`로 partition id를 계산한 뒤
worker queue로 전달하는 형태를 보여 준다 [13]. 다만 이 WorkLog는 database
partition/hash 기반의 초기 MTS 설계이므로, 아래 그림은 MySQL 현재 구현을 그대로
옮긴 것이 아니라 CUBRID 코디네이터 구조를 잡기 위한 참고 모델로 본다.

```text
source
  -> transaction commit 순서 확정
  -> binary log 기록
       - transaction 순서 정보 기록
       - dependency metadata 기록
         예: sequence_number, last_committed
  -> binary log 전송

replica
  -> I/O receiver thread
       - source binary log를 받아 relay log에 저장
  -> relay log
  -> coordinator thread
       - relay log를 순차적으로 읽음
       - transaction 순서/dependency metadata 확인
       - 실행 가능한 transaction을 worker queue에 배정
  -> worker queue[0] -> worker[0]
  -> worker queue[1] -> worker[1]
  -> worker queue[N] -> worker[N]
  -> commit order / recovery progress 정리
```

MySQL의 병렬 적용은 transaction 간 의존성을 기준으로 한다. Source는 transaction
dependency 정보를 binary log에 기록할 수 있으며, replica coordinator는 이 정보를
사용해 어떤 transaction을 병렬 실행할 수 있는지 판단한다. `LOGICAL_CLOCK` 방식은
transaction의 logical timestamp를 이용해 병렬 가능성을 판단하며, `WRITESET` 계열
방식은 transaction이 변경한 row/key 집합을 이용해 충돌 관계를 더 정밀하게 계산한다
[3][4].

> 병렬화 여부에 따라 source가 다른 종류의 binary log를 남기는 것은 아니다.
> MySQL은 `binlog_transaction_dependency_tracking`의 기본값인 `COMMIT_ORDER`에 따라
> transaction dependency metadata를 binary log에 기록할 수 있다. Replica에서 병렬
> 적용을 사용하지 않으면 transaction은 순차 반영되고, 병렬 적용을 사용하면
> coordinator가 이 값을 보고 의존성을 확인해 worker에 배정하는 차이로 보인다.

병렬 실행과 최종 commit 순서 보존은 분리된다. Worker는 독립적인 transaction을
병렬로 적용할 수 있지만, `replica_preserve_commit_order`를 사용하면 최종 commit
순서를 source의 commit 순서와 맞출 수 있다. 또한 MySQL은 DDL, foreign key 관련
변경, write set이 불완전한 transaction 등 충돌 판단이 어려운 경우에는 더 보수적인
방식으로 fallback한다 [4][5].

> **Note**
>
> MySQL의 binary log group commit은 여러 transaction의 binary log write, sync,
> storage engine commit을 묶어서 처리하는 commit 경로의 최적화다. 이 기능 자체가
> 병렬 복제의 필수 조건은 아니지만, 여러 transaction의 commit-time window가
> 겹치게 만들어 `LOGICAL_CLOCK` 기반 병렬 적용에 도움이 될 수 있다. MySQL 문서에서도
> 이 효과를 얻으려면 replica가 `replica_parallel_type=LOGICAL_CLOCK`을 사용해야 하며,
> `binlog_transaction_dependency_tracking=COMMIT_ORDER`일 때 효과가 더 크다고 설명한다.
> 따라서 group commit은 병렬 복제를 가능하게 하는 필수 메커니즘이라기보다,
> dependency 판단에 활용될 수 있는 commit overlap을 늘려 병렬성을 높이는 보조 요소로
> 보는 것이 적절하다 [3][4].

### PostgreSQL

PostgreSQL logical replication은 publication/subscription 모델이다. Publisher는
WAL을 logical decoding하여 logical change stream으로 만들고, subscriber의 apply
worker가 이를 받아 local table에 적용한다. Subscription은 어떤 publication을
받을지 정의하며, replication slot은 subscriber가 어디까지 변경을 수신했는지
publisher 측에서 보존하는 역할을 한다 [6][7][8].

PostgreSQL logical replication은 MySQL처럼 transaction 간 dependency metadata를
계산해 서로 독립적인 transaction을 병렬 dispatch하는 구조가 아니다. 기본 apply
모델은 publisher의 transaction stream을 subscriber apply worker가 같은 순서로
적용하여 단일 subscription 안의 transactional consistency를 보장하는 방식이다
[6][8].

PostgreSQL에서 병렬성이 나타나는 지점은 주로 두 곳이다.

- 초기 table synchronization: subscription 생성 시 subscriber에 없는 기존 table
  데이터를 copy하는 단계다. 여러 table sync worker가 기존 data copy를 병렬로
  수행할 수 있다 [6][10].
  - 원문 근거: "initial data in existing subscribed tables", "snapshotted and copied",
    "parallel instance of a special kind of apply process" [6]
  - 번역/해석: subscription 대상에 이미 존재하는 table의 초기 데이터를 snapshot으로
    잡고 copy한다. 이 copy는 일반 apply worker가 아니라 초기 동기화를 위한 특수
    apply process의 병렬 instance에서 수행될 수 있다. 또한
    `max_sync_workers_per_subscription`은 subscription 초기화 또는 새 table 추가 시
    initial data copy의 병렬도를 제어한다 [10].
- large in-progress transaction streaming: 큰 transaction을 commit 이후 한 번에
  보내지 않고, commit 전 변경분을 `Stream Start`/`Stream Stop` 단위로 나눠 보낸다.
  `streaming = parallel`이면 subscriber의 parallel apply worker가 이 stream 처리를
  도울 수 있다 [9][10][14].
  - 원문 근거: "streaming of in-progress transactions" [10],
    "incoming changes are directly applied via one of the parallel apply workers" [9],
    "Stream Start and Stream Stop messages" [14]
  - 번역/해석: `streaming` 옵션은 진행 중인 transaction을 commit 전에 subscriber로
    보낼지 결정한다. `streaming = parallel`이면 incoming change를 사용 가능한
    parallel apply worker가 직접 처리할 수 있다. 이 `streaming = parallel`(large
    transaction 병렬 apply) 기능 자체는 PostgreSQL 16에서 도입되었으며, 관련 worker
    수는 `max_parallel_apply_workers_per_subscription`으로 제어한다(기본값 2)
    [10][15]. 프로토콜 관점에서는
    large in-progress transaction의 변경이 `Stream Start`와 `Stream Stop` 사이에
    전달되고, 마지막 stream에는 `Stream Commit` 또는 `Stream Abort`가 포함된다
    [9][10][14].

large transaction streaming은 transaction 내부 chunk 간 dependency graph를 계산해
병렬화하는 방식은 아니다. 하나의 transaction에 속한 stream segment를 처리하는
것이므로 여러 transaction 간 충돌 판단 문제와는 성격이 다르다. Subscriber는 같은
transaction의 stream을 처리하되, 마지막 `Stream Commit` 또는 `Stream Abort`에 따라
최종 commit/abort를 맞춘다 [14].

이때 stream segment를 순서 없이 독립적으로 적용할 수 있는 것은 아니다. 같은
transaction 안에서도 앞선 변경이 뒤 변경의 전제가 될 수 있기 때문이다. 예를 들어
하나의 transaction 안에서 같은 row에 대해 `INSERT` 후 `UPDATE`가 발생했는데 두
변경이 서로 다른 stream segment에 들어갔다면, subscriber는 `INSERT` segment를
먼저 처리한 뒤 `UPDATE` segment를 처리해야 한다. `UPDATE` segment를 먼저 적용하면
대상 row가 아직 없으므로 transaction 의미가 깨질 수 있다. 따라서 PostgreSQL의
parallel apply worker는 large transaction stream 처리를 보조할 수 있지만, 같은
transaction 내부 segment를 임의 순서로 병렬 적용하는 모델은 아니다.

```text
Tx100
  segment 1: INSERT row id = 1
  segment 2: UPDATE row id = 1
  segment 3: Stream Commit

subscriber 처리 순서
  segment 1 처리
  segment 2 처리
  Stream Commit 수신 후 최종 commit
```

```text
publisher
  -> WAL
  -> walsender + logical decoding
       - pgoutput이 publication 기준으로 change filtering
       - transaction stream 생성

subscriber
  -> apply worker
       - transaction stream을 publisher 순서대로 적용
       - 단일 subscription 안의 transactional consistency 보장
  -> table synchronization worker
       - 초기 data copy 병렬화
  -> parallel apply worker
       - streaming = parallel일 때 large transaction stream 처리 보조
       - 일반 transaction 간 dependency scheduling 용도는 아님
```

PostgreSQL은 DDL을 logical replication 대상으로 자동 복제하지 않으며, schema는
사용자가 별도로 맞춰야 한다. Subscriber에서 constraint violation 같은 conflict가
발생하면 replication worker가 error를 내고 복제가 중단되며, 사용자가 직접 해결해야
한다 [11][12].

## MySQL 코디네이터

MySQL의 multithreaded replica에서 coordinator는 relay log를 순차적으로 읽고,
transaction을 worker thread에 배정하는 역할을 한다. 이때 coordinator의 핵심
역할은 단순히 비어 있는 worker를 찾는 것이 아니라, transaction 간 의존성을 기준으로
병렬 실행 가능한 transaction을 구분하는 것이다 [2][4].

MySQL에서 replica가 병렬 적용을 사용하려면 worker 수와 병렬화 방식을 설정한다.
대표적으로 `replica_parallel_workers`는 worker thread 수를 정하고,
`replica_parallel_type=LOGICAL_CLOCK`은 logical timestamp를 이용한 병렬 적용
방식을 사용하도록 한다 [4].

Logical clock 방식에서 source는 transaction마다 병렬 적용에 필요한 순서 정보를
binary log에 기록한다. 핵심 값은 `sequence_number`와 `last_committed`이다.
`sequence_number`는 binary log 안에서 transaction의 논리적 순번이고,
`last_committed`는 해당 transaction이 기다려야 하는 가장 최근 선행 transaction을
나타낸다. Replica coordinator는 relay log를 순차적으로 읽으면서 이 정보를 보고
어떤 transaction을 worker에 보낼 수 있는지 판단한다 [3][4].

MySQL은 dependency 정보를 계산하는 방식도 설정으로 분리한다.
`binlog_transaction_dependency_tracking=COMMIT_ORDER`는 commit 순서와 group
commit 정보를 기반으로 dependency를 계산한다. `WRITESET` 계열은 transaction이
변경한 row/key 집합을 이용해 충돌 여부를 더 정밀하게 판단한다.
`WRITESET_SESSION`은 write set 기반 판단에 같은 session의 transaction 순서 보존을
추가한 방식이다 [3].

병렬 실행과 최종 commit 순서 보존은 별도 개념이다. Coordinator는 logical clock과
dependency 정보를 바탕으로 worker 병렬 실행을 허용할 수 있지만,
`replica_preserve_commit_order`를 사용하면 worker들이 병렬로 처리한 transaction도
최종 commit 순서를 source의 commit 순서와 맞출 수 있다 [4].

정리하면 MySQL 코디네이터는 다음 정보를 기준으로 transaction을 스케줄링한다.

```text
relay log 순서
  - source commit 순서를 반영하는 기본 입력 순서

logical clock
  - sequence_number
  - last_committed

dependency tracking 방식
  - COMMIT_ORDER
  - WRITESET
  - WRITESET_SESSION

commit order 보존 설정
  - replica_preserve_commit_order
```

## 코디네이션 CUBRID 적용 방안

MySQL과 동일한 방식으로 병렬 적용을 구현하려면 master/source 쪽에서 복제 로그에
transaction dependency metadata를 기록해야 한다. MySQL은 source가 binary log에
`sequence_number`, `last_committed`, write set 기반 dependency 정보를 남기고,
replica coordinator가 이 정보를 읽어 병렬 실행 가능 여부를 판단한다 [3][4].

CUBRID에서 이 방식을 그대로 적용하려면 복제 로그에 다음과 같은 정보를 추가해야 한다.

```text
transaction sequence
dependency watermark
write set 또는 conflict key
barrier 여부
```

즉 MySQL과 같은 수준의 logical clock/write set 기반 병렬화를 목표로 한다면
복제 로그 포맷 또는 복제 log record 확장이 필요하다.

다만 1차 구현에서 반드시 복제 로그부터 변경할 필요는 없다. 현재 `applylogdb`는
복제 로그를 읽으면서 transaction별 apply list를 구성한다. 이 과정에서 slave/applylogdb
쪽 코디네이터가 보수적으로 dependency를 추론할 수 있다.

> **Note**
>
> 현재 문서의 1차 적용 방안은 transaction별 apply list를 만드는 과정에서
> "이 transaction이 어떤 class들을 변경했는지"를 함께 수집하고, commit 시점에
> 그 class set으로 transaction 간 충돌 여부를 판단하는 것이다.

1차 적용안은 다음과 같다.

```text
복제 로그에서 transaction별 변경 class 수집
  -> transaction별 touched class set 구성
  -> 같은 class를 변경하면 순차 실행
  -> 서로 다른 class만 변경하면 병렬 실행 가능
  -> schema/sysop/unknown은 barrier
```

이 방식은 MySQL처럼 source가 dependency metadata를 미리 기록하는 구조는 아니지만,
복제 로그 포맷 변경 없이 코디네이터 구조를 검증할 수 있다. 병렬성은 제한적이지만,
충돌 판단을 보수적으로 가져갈 수 있어 구현 초기 단계에 적합하다.

장기적으로 row/write-set 기반 정밀 병렬화를 목표로 한다면 repl log에 병렬 적용을
위한 정보를 추가하는 방향을 검토할 수 있다. 다만 1차 구현에서는 repl log 포맷을
바꾸지 않고 applylogdb 내부 class-level coordinator 구현에 correctness 확인과
병렬성 효과 확인을 포함한다. repl log 확장은 1차 구현 결과 병렬성이 부족할 때의
후속 고려사항으로 둔다. 따라서 적용 전략은 다음처럼 정리할 수 있다.

```text
1. applylogdb 내부 class-level coordinator 구현
   - 구현 범위 안에서 correctness 확인 포함
   - class-level 기준의 병렬성 효과 확인 포함
2. 병렬성이 부족하면 repl log에 병렬 정보 추가 검토
```

## 기본 방향

코디네이터는 복제 로그 리더와 worker 사이에 위치한다. 복제 로그 리더가
transaction 단위 작업을 만들고, 코디네이터가 그 작업의 실행 가능 여부를 판단한
뒤 worker에 분배한다.

```text
복제 로그 리더
  -> transaction 작업 생성
  -> 코디네이터
  -> worker
  -> 결과 회수
  -> 순서 정리
```

여기서 코디네이터의 목적은 worker를 고르는 것 자체가 아니다. 먼저 transaction 간
충돌과 순서 보존 필요 여부를 판단하고, 실행해도 되는 작업만 worker로 보내는 것이
핵심이다.

## 코디네이션 위치

현재 PoC에서는 복제 로그 리더가 commit record를 만나는 즉시 worker를 직접 고른다.

```text
commit record
  -> transaction 작업 생성
  -> tranid % worker_count
  -> worker queue
```

목표 구조에서는 이 결정을 코디네이터로 옮긴다.

```text
commit record
  -> transaction 작업 생성
  -> coordinator submit
  -> 충돌/순서 보존 필요 여부 판단
  -> 실행 가능하면 worker 선택
  -> worker queue
```

즉 복제 로그 리더는 입력을 읽고 transaction 작업을 만드는 역할에 집중한다.
transaction 간 관련성 판단과 worker 분배는 코디네이터가 맡는다.

> tx1, tx2 를 참조하는 tx3, 다음 들어오는 tx4(역시 tb1, tbl2 참고), 독립적인 tx5

## 목표 아키텍처

```text
+----------------------+
| 복제 로그 리더          |
| - 복제 record 스캔     |
| - transaction 구성    |
+----------+-----------+
           |
           v
+----------------------+
| transaction 작업      |
| - apply list         |
| - commit_lsa         |
| - 변경 class set      |
+----------+-----------+
           |
           v
+----------------------+
| 코디네이터              |
| - 충돌/순서 판단        |
| - 실행/대기 구분        |
| - worker 선택         |
+-----+----------+-----+
      |          |
      |          +--------------------+
      |                               |
      v                               v
+----------------------+     +----------------------+
| 실행 가능 작업          |     | 대기 작업               |
| worker queue로 이동   |     | pending 상태 유지       |
+----------+-----------+     +----------------------+
           |
           v
+----------------------+
| worker pool          |
| - worker[0]          |
| - worker[1]          |
| - worker[N]          |
+----------+-----------+
           |
           v
+----------------------+
| 결과 회수              |
| - worker result 수집  |
+----------+-----------+
           |
           v
+----------------------+
| 순서 정리              |
| - committed_lsa 갱신  |
| - apply info 갱신     |
+----------------------+
```

## 코디네이터 역할

코디네이터가 판단하는 질문은 다음 순서다.

```text
이 transaction은 이전 transaction과 충돌하는가?
충돌한다면 어떤 transaction 뒤까지 기다려야 하는가?
지금 실행 가능하다면 어느 worker에게 보낼 것인가?
```

앞의 두 질문은 correctness 문제다. 마지막 질문은 성능 문제다. 따라서 코디네이터는
worker 분배보다 충돌/순서 판단을 우선해야 한다.

코디네이터의 책임은 다음과 같다.

- transaction 간 충돌 여부를 판단한다.
- 순서를 지켜야 하는 transaction은 대기시킨다.
- 실행 가능한 transaction만 worker에 보낸다.
- worker 부하가 한쪽으로 몰리지 않도록 분배한다.
- 완료 또는 순서 정리 결과를 보고 대기 중인 transaction을 다시 판단한다.

## 트랜잭션 분배 방식

1차 분배 기준은 class 단위로 둔다. transaction별 apply list를 만드는 과정에서
해당 transaction이 변경한 class set을 함께 수집하고, commit 시점에 그 class set으로
충돌 여부를 판단한다.

```text
같은 class를 변경하는 transaction
  -> 순차 실행

서로 다른 class만 변경하는 transaction
  -> 병렬 실행 가능

schema/sysop/unknown transaction
  -> barrier
```

barrier는 앞뒤 transaction을 끊는 지점이다. barrier transaction은 앞선 작업이
정리된 뒤 실행하고, 뒤의 작업은 barrier가 정리된 뒤 실행한다.

이 방식은 row/write-set 단위보다 병렬성은 낮지만, 복제 로그 포맷 변경 없이
코디네이터 구조를 검증할 수 있다. 판단이 애매한 transaction은 병렬화하지 않는
것을 기본 원칙으로 둔다.

### 충돌 확인 방법

제안하는 1차 코디네이터는 class 단위로 충돌을 확인한다. 복제 로그 리더는 repl log를
순차적으로 읽으면서 transaction별 apply list를 구성하고, 이 과정에서 해당
transaction이 변경한 class 정보도 함께 수집한다. Commit record를 만나면 리더는
해당 transaction의 apply list가 끝났다고 보고 transaction 작업을 완성한다. 이때
리더는 apply list와 changed class set을 함께 코디네이터에 전달한다.

코디네이터는 repl log를 다시 분석하지 않는다. 리더가 넘긴 transaction 작업에 포함된
changed class set을 기준으로 충돌 여부를 판단한다. 즉 코디네이터가 받는 작업은
우선 다음 정보를 포함한다.

```text
transaction 작업
  - apply list
  - changed class set
```

`commit_lsa`, transaction type flag, schema/sysop/unknown 작업의 구분 방식은
실제 applylogdb 구조를 더 확인한 뒤 확정한다.

판단 방식은 단순하다.

- 이미 실행 중이거나 아직 순서 정리가 끝나지 않은 transaction과 같은 class를
  변경하면 충돌로 본다.
- 변경 class가 겹치지 않으면 병렬 실행할 수 있다.
- schema 변경, sysop, 변경 class를 알 수 없는 작업은 추가 확인 후 barrier 처리
  대상으로 둔다.

복제 로그 리더가 commit record를 만나 transaction 작업을 코디네이터에 넘기면,
코디네이터는 다음 순서로 판단한다.

1. 먼저 변경한 class 목록을 확인한다.
   이 목록은 apply list를 만드는 과정에서 함께 수집해 둔다.

2. 현재 실행 중이거나 아직 순서 정리가 끝나지 않은 transaction들의 변경 class와
   비교한다.

3. 같은 class가 하나라도 있으면 충돌로 판단한다.
   새 transaction은 바로 worker에 보내지 않고 pending 상태로 둔다. 이후 충돌하던
   선행 transaction의 실행과 순서 정리가 끝나면 다시 실행 가능 여부를 확인한다.

4. 같은 class가 하나도 없으면 병렬 실행할 수 있다.
   이 경우 코디네이터가 적절한 worker queue를 골라 transaction을 전달한다.

5. 변경 class를 수집할 수 없거나 class 기준 판단이 안전하지 않은 작업은 barrier로
   처리하는 방향을 검토한다. 구체적인 판별 기준은 실제 applylogdb record와
   operation type 확인 후 확정한다.

예를 들어 다음 transaction들이 있다고 가정한다.

```text
Tx1 changed_classes = {A}
Tx2 changed_classes = {B}
Tx3 changed_classes = {A}
```

Tx1은 class A를 변경하고, Tx2는 class B를 변경한다. 서로 건드리는 class가 다르므로
두 transaction은 동시에 실행할 수 있다.

```text
Tx1 -> class A 변경
Tx2 -> class B 변경

결과:
  서로 다른 class이므로 병렬 실행 가능
```

반면 Tx3도 class A를 변경한다. Tx1이 아직 실행 중이거나 순서 정리가 끝나지 않았다면,
Tx3을 동시에 실행하면 같은 class에 대한 변경 순서가 뒤섞일 수 있다. 따라서 Tx3은
Tx1 뒤로 미룬다.

```text
Tx1 -> class A 변경
Tx3 -> class A 변경

결과:
  같은 class를 변경하므로 충돌
  Tx3은 Tx1 완료/순서 정리 이후 실행
```

이 방식은 row 단위까지 들여다보지 않는다. 따라서 실제로는 서로 다른 row를 변경해서
동시에 실행해도 괜찮은 경우라도, 같은 class를 변경하면 충돌로 본다.

```text
Tx4: class A의 row 1 update
Tx5: class A의 row 999 update

실제로는 서로 다른 row라 독립일 수 있음
하지만 1차안에서는 둘 다 class A를 변경하므로 충돌로 판단
```

결과적으로 class-level 판단은 보수적인 방식이다. 장점은 repl log 포맷을 바꾸지
않고 applylogdb 내부에서 구현할 수 있으며, correctness 판단이 단순하다는 점이다.
단점은 row/write-set 기반 판단보다 병렬성이 낮다는 점이다. 특정 hot class에
transaction이 몰리면 대부분의 transaction이 순차 실행되어 병렬 적용 효과가 줄어들
수 있다. 병렬성이 부족한 경우에는 후속 단계에서 repl log에 write-set 또는 conflict
key 같은 병렬 적용 정보를 추가하는 방향을 검토한다.

### 대기 방식 선택

class 단위 충돌을 처리하는 방식은 크게 두 가지로 볼 수 있다.

첫 번째는 전역 pending queue 방식이다.

```text
Tx1 -> Tbl1
Tx2 -> Tbl2
Tx3 -> Tbl1

Tx1 실행 중
Tx3은 Tbl1 충돌 때문에 pending queue에 보관
Tx1 정리 완료 후 Tx3을 다시 평가하고 worker에 배정
```

이 방식은 선행 transaction이 끝난 뒤 다시 worker를 고를 수 있어 일반적이다.
다만 pending queue 관리와 재평가 로직이 필요하다.

두 번째는 충돌 domain의 owner worker queue에 바로 붙이는 방식이다.

```text
Tx1 -> Tbl1 -> worker[1]
Tx2 -> Tbl2 -> worker[2]
Tx3 -> Tbl1 -> worker[1] queue 뒤에 enqueue
```

이 방식은 같은 class의 순서를 worker queue 자체로 보장할 수 있어 단순하다.
하지만 특정 class에 transaction이 몰리면 worker skew가 커질 수 있고, 여러 class를
동시에 변경하는 transaction에서는 어느 worker queue에 붙일지 결정하기 어렵다.

```text
Tx4 -> Tbl1, Tbl2

Tbl1 owner = worker[1]
Tbl2 owner = worker[2]

Tx4를 어느 worker queue에 붙일지 애매해짐
```

따라서 컨셉 단계에서는 전역 pending queue 방식을 기본으로 본다. 단일 class
transaction에 대해서는 owner worker queue 직렬화가 최적화 후보가 될 수 있지만,
다중 class, schema, sysop, unknown transaction까지 고려하면 pending queue 기반
재평가 방식이 더 일반적인 모델이다.

## 모듈별 역할과 책임

### 복제 로그 리더

복제 로그 리더는 복제 record를 읽고 transaction 작업을 만든다.

- 복제 record를 transaction별 apply list로 모은다.
- apply list를 만들면서 변경 class set을 함께 수집한다.
- commit record를 만나면 transaction 작업을 완성한다.
- 완성된 작업을 worker에 직접 넣지 않고 코디네이터에 제출한다.

### 코디네이터

코디네이터는 transaction 실행 가능 여부를 판단하고 worker에 분배한다.

- 변경 class set을 기준으로 충돌 여부를 판단한다.
- 실행 가능한 작업과 대기해야 하는 작업을 구분한다.
- schema/sysop/unknown 작업은 barrier로 취급한다.
- 실행 가능한 작업을 worker queue에 넣는다.
- 대기 중인 작업을 언제 다시 실행할 수 있는지 판단한다.

### worker

worker는 코디네이터가 넘긴 transaction 작업만 실행한다.

- 복제 항목 적용
- flush
- commit
- 결과 반환

worker는 transaction 간 충돌 여부를 판단하지 않는다.

### 결과 회수와 순서 정리

worker 결과는 병렬로 도착할 수 있다. 하지만 global progress는 기존 commit LSA
순서대로만 전진해야 한다.

순서 정리 단계의 책임은 다음과 같다.

- worker 결과 회수
- `committed_lsa` 갱신
- apply info 갱신
- `LA_APPLY` slot 반환
- commit counter 누적

코디네이터가 실행 순서를 조정하더라도, 최종 progress 갱신은 순서 정리 단계가
담당한다.

## 병렬화 효과 예시

class 단위 코디네이션의 병렬화 효과는 transaction이 얼마나 여러 class로 분산되어
있는지에 좌우된다.

Best case는 서로 다른 class를 변경하는 transaction이 연속으로 들어오는 경우다.

```text
복제 로그 순서

Tx1 -> TblA
Tx2 -> TblB
Tx3 -> TblC
Tx4 -> TblD
```

각 transaction의 변경 class가 겹치지 않으므로 병렬 실행이 가능하다.

```text
time ---->

worker[0]:  [ Tx1: TblA ]
worker[1]:  [ Tx2: TblB ]
worker[2]:  [ Tx3: TblC ]
worker[3]:  [ Tx4: TblD ]
```

이 경우 worker 활용도가 높고, 병렬화 효과가 크다.

Worst case는 transaction이 하나의 hot class에 집중되는 경우다.

```text
복제 로그 순서

Tx1 -> TblA
Tx2 -> TblA
Tx3 -> TblA
Tx4 -> TblA
```

class 단위 판단에서는 모든 transaction이 같은 class에서 충돌한다. 따라서 병렬
worker가 여러 개 있어도 실행은 사실상 순차화된다.

```text
time ---->

worker[0]:  [ Tx1: TblA ][ Tx2: TblA ][ Tx3: TblA ][ Tx4: TblA ]
worker[1]:
worker[2]:
worker[3]:
```

중간 케이스는 여러 class conflict group으로 나뉘는 경우다.

```text
복제 로그 순서

Tx1 -> TblA
Tx2 -> TblB
Tx3 -> TblA
Tx4 -> TblC
Tx5 -> TblB
Tx6 -> TblD
```

class별로는 순서를 지키고, 서로 다른 class group은 병렬 실행할 수 있다.

```text
time ---->

worker[0]:  [ Tx1: TblA ][ Tx3: TblA ]
worker[1]:  [ Tx2: TblB ][ Tx5: TblB ]
worker[2]:  [ Tx4: TblC ]
worker[3]:  [ Tx6: TblD ]
```

정리하면, 서로 다른 class를 변경하는 transaction이 많을수록 병렬화 효과가 커지고,
하나의 hot class에 transaction이 집중될수록 병렬화 효과는 작아진다.

## 남은 설계 쟁점

컨셉 단계에서 남겨둘 쟁점은 다음이다.

- class 식별자는 어디서 얻을 것인가
- class name을 임시로 쓸 것인가, 처음부터 class OID를 쓸 것인가
- 순서 대기 해제 기준을 worker 완료로 볼 것인가, 순서 정리 완료로 볼 것인가
- pending 작업이 너무 많아질 때 리더를 어떻게 멈출 것인가
- barrier 범위를 어디까지 잡을 것인가
- 추후 row/write-set 단위로 확장할 때 기존 class 정책과 어떻게 공존시킬 것인가

1차 구현에서는 순서 대기 해제 기준을 순서 정리 완료로 두는 것이 안전하다.
worker가 끝났더라도 global progress가 아직 전진하지 않았다면 관련 후속
transaction을 실행하지 않는 방식이다. 병렬성은 줄지만 correctness 판단이 단순하다.

## 요약

코디네이터는 `tranid % worker_count`를 대체하는 단순 worker picker가 아니다.
transaction 간 충돌과 순서 보존 필요 여부를 판단하고, 실행 가능한 transaction만
worker에 분배하는 계층이다.

처음 구현 방향은 다음이 적절하다.

- 복제 로그 리더는 transaction 작업을 만든다.
- apply list 생성 과정에서 변경 class set을 수집한다.
- 코디네이터는 class set으로 충돌 여부를 판단한다.
- 같은 class를 변경하면 순차 실행한다.
- 서로 다른 class만 변경하면 병렬 실행을 허용한다.
- schema/sysop/unknown은 barrier로 둔다.
- worker는 받은 transaction 작업만 실행한다.
- 최종 progress는 순서 정리 단계에서 commit LSA 순서대로 갱신한다.

이 구조가 안정화된 뒤 row/write-set 기반 분배를 검토한다.

## 참고문헌

[1] MySQL 8.0 Reference Manual, "Replication Implementation", https://dev.mysql.com/doc/refman/8.0/en/replication-implementation.html

[2] MySQL 8.0 Reference Manual, "Replication Threads", https://dev.mysql.com/doc/refman/8.0/en/replication-threads.html

[3] MySQL 8.0 Reference Manual, "Binary Logging Options and Variables", https://dev.mysql.com/doc/refman/8.0/en/replication-options-binary-log.html

[4] MySQL 8.0 Reference Manual, "Replica Server Options and Variables", https://dev.mysql.com/doc/refman/8.0/en/replication-options-replica.html

[5] MySQL 8.0 Reference Manual, "Replication and Transaction Inconsistencies", https://dev.mysql.com/doc/refman/8.0/en/replication-features-transaction-inconsistencies.html

[6] PostgreSQL 17 Documentation, "Logical Replication Architecture", https://www.postgresql.org/docs/17/logical-replication-architecture.html

[7] PostgreSQL 17 Documentation, "Publication", https://www.postgresql.org/docs/17/logical-replication-publication.html

[8] PostgreSQL 17 Documentation, "Subscription", https://www.postgresql.org/docs/17/logical-replication-subscription.html

[9] PostgreSQL 17 Documentation, "CREATE SUBSCRIPTION", https://www.postgresql.org/docs/17/sql-createsubscription.html

[10] PostgreSQL 17 Documentation, "Logical Replication Configuration Settings", https://www.postgresql.org/docs/17/logical-replication-config.html

[11] PostgreSQL 17 Documentation, "Logical Replication Restrictions", https://www.postgresql.org/docs/17/logical-replication-restrictions.html

[12] PostgreSQL 17 Documentation, "Logical Replication Conflicts", https://www.postgresql.org/docs/17/logical-replication-conflicts.html

[13] MySQL WorkLog WL#5569, "Replication events parallel execution via hashing per database name", https://dev.mysql.com/worklog/task/?id=5569

[14] PostgreSQL 17 Documentation, "Logical Streaming Replication Protocol", https://www.postgresql.org/docs/17/protocol-logical-replication.html

[15] PostgreSQL 16 Release Notes (large transaction에 대한 parallel apply, `streaming = parallel` 도입), https://www.postgresql.org/docs/release/16.0/
