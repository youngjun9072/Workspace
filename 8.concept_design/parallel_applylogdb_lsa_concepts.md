# 병렬 applylogdb 컨셉 설명에 필요한 LSA

이 문서는 병렬 applylogdb의 컨셉을 설명할 때 필요한 LSA만 정리한다. 코드 설계 단계에서 필요한 세부 LSA(`committed_rep_lsa`, `required_lsa`, `append_lsa`, `eof_lsa`, `LA_ITEM.lsa`, `target_lsa` 등)는 여기서 다루지 않는다.

## 기본 전제

여기서 말하는 LSA는 모두 **master log stream 기준 LSA**이다.

master log stream은 master DB가 생성했고 `copylogdb`가 slave 쪽으로 복사한 로그 흐름을 의미한다.

```text
master log stream = copied archive log + copied active log
```

따라서 아래 LSA들은 slave DB의 local transaction log LSA가 아니다. applylogdb가 slave DB에 변경을 반영하면서 slave local log도 생성되지만, 병렬 apply의 순서와 진도 판단에는 master log stream 기준 LSA를 사용한다.

## 컨셉 설명에 필요한 LSA

### 1. final_lsa

`final_lsa`는 applylogdb reader가 master log stream을 어디까지 읽었는지를 나타낸다.

```text
final_lsa = reader가 읽은 master log 위치
```

이 값은 읽기 진행률이다. slave DB에 반영 완료됐다는 뜻이 아니다.

병렬화 이후에는 reader가 worker보다 앞서 로그를 읽을 수 있으므로, `final_lsa`와 실제 반영 완료 위치는 더 명확히 분리해서 설명해야 한다.

### 2. commit_lsa

`commit_lsa`는 각 트랜잭션의 commit log record 위치이다.

```text
commit_lsa = 해당 트랜잭션의 master log상 commit 위치
```

병렬 apply에서는 `commit_lsa`를 전역 commit 순서로 사용한다. 별도의 `sequence_number`를 추가하지 않는 이유는 applylogdb reader가 단일 흐름으로 master log stream을 LSA 순서대로 읽기 때문이다.

즉 CUBRID에서는 다음처럼 볼 수 있다.

```text
MySQL sequence_number 역할 = CUBRID commit_lsa
```

`commit_lsa`는 worker의 고유 값이 아니라 트랜잭션의 고유 값이다. worker는 현재 맡은 트랜잭션의 `commit_lsa`를 들고 apply를 수행한다.

### 3. committed_lsa

`committed_lsa`는 slave DB에 commit 순서대로 반영 완료된 마지막 master log 위치이다.

```text
committed_lsa = slave가 반영 완료한 마지막 commit_lsa
```

이 값도 slave local log LSA가 아니다. applylogdb가 master log stream 기준으로 어디까지 slave DB에 반영 완료했는지를 나타내는 진도값이다.

## worker commit 순서 보장

병렬 apply에서는 apply 단계와 commit 단계를 구분한다.

```text
apply  = worker들이 병렬 수행 가능
commit = commit_lsa 순서대로 직렬화
```

worker가 자기 트랜잭션의 apply 작업을 먼저 끝내더라도 즉시 commit하지 않는다. commit 직전에 coordinator가 관리하는 전역 commit 순서를 확인한다. 자신의 `commit_lsa`가 현재 commit 가능한 순서가 아니면, 앞선 `commit_lsa`를 가진 트랜잭션들이 commit 완료될 때까지 대기한다.

예를 들어 master log stream의 commit 순서가 다음과 같다고 하자.

```text
T1 commit_lsa = 100
T2 commit_lsa = 120
T3 commit_lsa = 140
```

worker 실행은 병렬이므로 apply 완료 순서는 달라질 수 있다.

```text
T2 apply 완료
T3 apply 완료
T1 아직 apply 중
```

하지만 commit은 순서대로만 가능하다.

```text
T2: commit_lsa 120 차례가 아니므로 commit 대기
T3: commit_lsa 140 차례가 아니므로 commit 대기
T1: apply 완료 후 commit_lsa 100 차례이므로 commit 수행
```

이후 commit은 다음 순서로 진행된다.

```text
T1 commit 완료 -> committed_lsa = 100
T2 commit 완료 -> committed_lsa = 120
T3 commit 완료 -> committed_lsa = 140
```

따라서 병렬 apply의 핵심은 다음 한 문장으로 정리할 수 있다.

```text
worker는 병렬로 apply하고, commit은 coordinator가 commit_lsa 순서대로 허용한다.
```

## 왜 commit 순서를 강제하는가

commit 순서를 강제하는 이유는 장애 복구 시 apply info와 slave DB 상태가 같은 prefix를 가리키게 하기 위해서다.

만약 T2, T3가 T1보다 먼저 slave DB에 commit된 뒤 applylogdb 장애가 발생하면 문제가 생긴다.

```text
apply info 기준: T1 이전까지만 완료
slave DB 실제 상태: T2, T3 변경은 이미 commit됨
```

재시작 후 applylogdb는 T1부터 다시 적용하려고 하지만, slave DB에는 이미 T2/T3 변경이 들어가 있다. 이 경우 중복 반영이나 제약 위반이 발생할 수 있다.

따라서 `committed_lsa`는 실제 slave DB commit 상태와 항상 같은 prefix를 유지해야 한다. 이를 위해 worker의 commit 요청은 `commit_lsa` 순서대로 직렬화한다.

## 컨셉 설명에서 제외할 LSA

아래 LSA들은 실제 구현과 복구 설계에서는 중요하지만, 병렬화 컨셉 설명에서는 제외한다.

```text
committed_rep_lsa
required_lsa
append_lsa
eof_lsa
LA_ITEM.lsa
LA_ITEM.target_lsa
LA_APPLY.start_lsa
LA_APPLY.last_lsa
```

이 값들은 중복 적용 방지, 재시작 기준, 로그 수신 경계, replication item 재구성에 필요하다. 그러나 병렬 apply의 핵심 컨셉을 설명할 때는 `final_lsa`, `commit_lsa`, `committed_lsa`만으로 충분하다.

