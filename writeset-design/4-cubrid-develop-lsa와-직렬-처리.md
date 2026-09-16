---
tags: [writeset, design, cubrid, lsa, applylogdb, develop]
date: 2026-09-16
status: 리뷰 후보
code-base:
  develop: 23789cbfa78087a9edaae126b605495525b4d40d
---

# 4. CUBRID develop의 LSA와 직렬 처리

MySQL 조사에서 도출한 요구사항을 CUBRID에 적용하려면, 먼저 `develop` applylogdb가 로그를 읽고 변경을 반영한 뒤 재시작 지점을 남기는 과정을 알아야 한다. 이 장은 병렬화 이전의 직렬 applylogdb만 다룬다.

## 4.1 LSA란 무엇인가

LSA(Log Sequence Address)는 로그 레코드의 위치를 `(pageid, offset)`으로 표현하는 좌표다. `pageid`가 작은 위치가 먼저이고, 같은 페이지에서는 `offset`이 작은 위치가 먼저다.

![4-lsa-pageid-offset-order](./figures/4-lsa-pageid-offset-order.svg)

*[그림 4-1] `pageid`와 `offset`의 사전식 비교로 로그 위치의 앞뒤를 판단하는 방법.*

LSA는 로그 레코드를 다시 찾는 좌표다. applylogdb는 이 좌표를 로그 탐색, 트랜잭션 구성, 적용 진행 기록, 로그 보존과 재시작에 서로 다른 이름으로 사용한다.

이 장의 그림은 로그 레코드를 D(변경 데이터)·R(복제 지시)·C(COMMIT) 한 글자로 표시하고, `la_Info`의 위치도 같은 방식의 한 글자 기호로 표시한다. 뒤의 숫자는 시점이며, `C0`는 직전 실행에서 끝낸 COMMIT, `C1`은 이번에 처리하는 COMMIT이다.

| 기호  | 가리키는 LSA       | 뜻                                            | 글자의 유래                                    |
| --- | -------------- | -------------------------------------------- | ----------------------------------------- |
| Q   | `required_lsa` | 가장 오래된 미완 트랜잭션의 첫 로그. 다시 읽기 시작 위치이자 로그 보존 하한 | R이 replication record에 쓰여 re**q**uired의 q |
| F   | `final_lsa`    | applier가 읽고 있는 위치                            | **f**inal                                 |
| E   | `eof_lsa`      | 유효 로그의 끝                                     | **e**of                                   |
| A   | `append_lsa`   | 다음 로그 기록 위치                                  | **a**ppend                                |

## 4.2 develop applier의 한 사이클

`develop`의 applylogdb는 마스터 로그를 순서대로 읽어 트랜잭션별 메모리 구조를 만들고, COMMIT 순서대로 변경을 적용한다. 적용 데이터와 진행 LSA가 같은 DB COMMIT으로 영속되므로, 재시작하면 영속된 완료 경계는 건너뛰고 `required_lsa`부터 미완 범위만 다시 구성할 수 있다.

![4-develop-serial-apply-roadmap](./figures/4-develop-serial-apply-roadmap.svg)

*[그림 4-2] 로그 읽기, 트랜잭션 구성, FIFO 직렬 적용, 진행 상태 영속과 재시작 시 다시 읽기로 이어지는 develop의 전체 경로.*

이 장의 나머지 절은 이 사이클을 읽기 → 구성 → 적용 → 영속 → 재시작 순서로 따라간다. 각 절은 관련 LSA를 설명한 뒤 같은 T1 예제의 장면으로 닫는다. 4.3부터 4.5까지의 장면에서는 정상 처리 중 각 LSA가 바뀌고 영속되는 시점을 하나의 트랜잭션으로 확인한다. 병렬 적용에서 종료 시 홀이 생기는 이유와 재시작 처리는 [6-2장](./6-2-cubrid-슬레이브-병렬-적용-설계.md)에서 설명한다.

마스터에는 다음 테이블과 두 행이 이미 존재하고, applylogdb에는 직전 처리 결과와 진행 위치가 영속돼 있다고 하자.

```sql
CREATE TABLE account (id INT PRIMARY KEY, balance INT);
INSERT INTO account VALUES (1, 1000), (2, 2000);

BEGIN;
UPDATE account SET balance = balance + 100 WHERE id = 1;
UPDATE account SET balance = balance - 100 WHERE id = 2;
COMMIT;
```

*[예제 4-2] 이후 여섯 단계에서 동일하게 추적할 T1의 두 행 변경.*

시나리오 시작 시점의 진행 상태는 `committed_lsa=C0`(직전에 끝낸 COMMIT), `committed_rep_lsa=R0`(직전에 적용한 replication item)이고, `_db_ha_apply_info`에도 같은 값이 영속돼 있다. 기동 시 이 두 값에서 만드는 기준선 `last_committed_lsa`·`last_committed_rep_lsa`의 역할은 [4.6](./4-cubrid-develop-lsa와-직렬-처리.md#46-재시작)에서 설명하며, 이 정상 시나리오에서는 값이 바뀌지 않는다.

그림에서는 실제 변경 data log를 D1·D2, 이를 가리키는 replication record를 R1(`target_lsa=D1`)·R2(`target_lsa=D2`), COMMIT record를 C1로 표시한다. 즉 D는 변경 데이터 로그, R은 복제 지시 로그, C는 COMMIT 로그다. `LA_APPLY.start_lsa`는 별도 START record가 아니다. D1의 `prev_tranlsa`가 NULL이므로 applylogdb는 D1을 T1에서 처음 만난 로그 레코드로 판별하고, 당시 `final_lsa`인 D1의 위치를 `LA_APPLY.start_lsa`에 복사한다. `LA_APPLY.start_lsa`는 트랜잭션별 `LA_APPLY`가 소유한다. `LA_APPLY.last_lsa`는 long transaction에서만 마지막으로 관찰한 replication record 위치를 저장하므로 이 normal transaction 시나리오에서는 표시하지 않는다. 마스터 active log header의 `eof_lsa`와 `append_lsa`는 applier가 읽을 수 있는 입력 상한을 제공한다.

## 4.3 로그 읽기와 트랜잭션 구성

applier는 로그 레코드의 연결 좌표를 따라 읽기 위치를 전진시키고, 읽은 레코드를 트랜잭션별 메모리 구조에 모은다. 이 절은 그 과정에서 쓰이는 LSA를 설명한 뒤 T1을 발견해 COMMIT을 등록하기까지의 장면 세 개를 둔다.

### 4.3.1 관련 LSA

- **`forw_lsa`**: 물리적으로 다음 로그 레코드를 가리킨다. applier는 이 값을 따라 `final_lsa`를 전진시킨다.

- **`back_lsa`**: 물리적으로 이전 로그 레코드를 가리킨다. applier는 직전 위치인 `prev_final`과 비교해 로그 체인의 연속성을 확인한다.

- **`prev_tranlsa`**: 다른 트랜잭션의 레코드를 건너 같은 트랜잭션의 이전 레코드를 가리킨다. NULL이면 applylogdb가 해당 트랜잭션에서 처음 관찰한 레코드로 판정한다.

- **`chkpt_lsa`**: active log header가 기억하는 최근 `LOG_START_CHKPT` 위치다. 서버 crash recovery의 analysis 기준이며, applylogdb의 복제 재시작 위치로 사용하지 않는다.

![4-develop-log-record-pointers_draft](./figures/4-develop-log-record-pointers_draft.svg)

*[그림 4-3] 물리 로그 체인, 트랜잭션별 로그 체인과 checkpoint 위치가 서로 다른 목적으로 기록되는 구조.*

코드상 필드와 판정 위치는 [10.2.3절](./10-코드-및-실측-부록.md#1023-로그-헤더와-레코드-연결-포인터)에서 확인한다.

`la_Info`가 보관하는 값 가운데 읽을 수 있는 로그 범위와 현재 읽는 위치에 해당하는 것은 다음 셋이다.

- **`append_lsa`**: active log header가 가리키는 다음 로그 기록 위치다. 로그 입력 상태와 applier의 읽기 지연량을 확인하는 데 사용하며 `_db_ha_apply_info`에 저장한다.

- **`eof_lsa`**: active log header가 가리키는 현재 유효 로그의 끝이다. applier는 이 위치를 넘어 읽지 않으며, 최초 실행에서는 `required_lsa`의 초기값으로도 사용한다. `_db_ha_apply_info`에 저장한다.

- **`final_lsa`**: applier가 현재 처리하거나 다음에 읽을 로그 위치다. 현재 레코드를 처리한 뒤 `forw_lsa`를 따라 전진하며, 로그를 읽은 위치일 뿐 적용 완료를 뜻하지 않는다. `_db_ha_apply_info`에 저장한다.

- **`LA_ITEM.lsa`**: replication record 자체의 위치다. item 적용 성공 경계와 재시작 시 item skip 비교에 사용한다.

- **`LA_ITEM.target_lsa`**: replication record가 가리키는 실제 data log record의 위치다. INSERT·UPDATE·DELETE에 사용할 record image를 복원한다.

- **`LA_APPLY.start_lsa`**: 해당 트랜잭션에서 처음 관찰한 로그 위치다. 미완 트랜잭션의 로그 보존 및 재구성 하한 후보가 된다.

- **`LA_APPLY.last_lsa`**: long transaction에서 마지막으로 관찰한 replication record 위치다. COMMIT 위치가 아니라, 메모리에서 해제한 item을 다시 만들기 위한 재탐색 상한이다.

- **`LA_COMMIT.log_lsa`**: 전역 FIFO commit list 노드가 보관하는 COMMIT·SYSOP_END·ABORT 레코드 위치다. 해당 노드의 처리가 끝나면 `committed_lsa`를 갱신하는 경계가 된다.

![4-develop-transaction-item-linked-list](./figures/4-develop-transaction-item-linked-list.svg)

*[그림 4-4] 하나의 normal transaction에서 `LA_APPLY.start_lsa`, 두 `LA_ITEM`의 복제 지시·변경 데이터 위치와 `LA_COMMIT.log_lsa`가 서로 다른 구조에 저장되는 관계.*

normal transaction은 여러 `LA_ITEM`을 COMMIT 처리까지 메모리에 둔다. 한 트랜잭션의 `LA_ITEM`이 `LA_MAX_REPL_ITEMS`(1000)개에 도달하면 `la_set_repl_log()`가 그 트랜잭션을 long transaction으로 전환한다. 이때 head item만 남기고 나머지를 해제하며, 이후 도착하는 replication record는 item을 만들지 않고 `LA_APPLY.last_lsa`만 갱신한다. COMMIT 시에는 head 다음부터 `LA_APPLY.last_lsa`까지 로그를 다시 읽어 item을 하나씩 재생성·적용한다. 상세 수명은 [10.2.2절](./10-코드-및-실측-부록.md#1022-item별-위치와-트랜잭션-수집-범위)에서 확인한다.

### 4.3.2 장면 1~3

#### 장면 1 — T1을 발견하고 scan을 시작한다

- 판별 조건 — applier의 `la_Info.final_lsa`가 D1에 도달하고, D1의 `LOG_RECORD_HEADER.prev_tranlsa`가 NULL이면 T1에서 처음 만난 로그 레코드로 판별한다.
- 값 변경 — 트랜잭션별 메모리 구조 `LA_APPLY(T1)`을 만들고 당시 `la_Info.final_lsa`를 `LA_APPLY.start_lsa`에 한 번 복사한다. 레코드 처리 뒤 `la_Info.final_lsa`는 `LOG_RECORD_HEADER.forw_lsa`를 따라 다음 로그로 이동한다.
- 필요한 이유와 다음 사용 — `la_find_required_lsa()`는 모든 미완 트랜잭션의 `LA_APPLY.start_lsa` 중 가장 오래된 값을 골라 `la_Info.required_lsa`의 입력으로 사용한다. 이 결과가 DB에 영속되면 필요한 로그 범위를 보존하고, 장애로 메모리의 `LA_APPLY`와 `LA_ITEM`이 사라졌을 때 그 범위부터 다시 읽어 T1을 다시 구성할 수 있다. `LA_APPLY.start_lsa` 자체가 DB에 영속되는 것은 아니다.

![4-develop-normal-step-1](./figures/4-develop-normal-step-1.svg)

*[그림 4-5] D1의 `prev_tranlsa=NULL`로 T1의 첫 로그를 판별하고 당시 scan cursor(`final_lsa`)를 `LA_APPLY.start_lsa`에 보존하는 상태.*

#### 장면 2 — replication item을 구성한다

- 판별 조건 — applier가 `LOG_REPLICATION_DATA` 레코드 R1과 R2를 읽는다.
- 값 변경 — `la_Info.final_lsa`는 각 로그 레코드의 `forw_lsa`를 따라 D1→D2→R1→R2를 순서대로 읽고 C1을 다음 처리 위치로 둔다. R1을 읽을 때 `LA_ITEM` #1에 `LA_ITEM.lsa=R1`, `LA_ITEM.target_lsa=D1`을 저장하고, R2를 읽을 때 `LA_ITEM` #2에 `LA_ITEM.lsa=R2`, `LA_ITEM.target_lsa=D2`를 저장한다. C1의 COMMIT 처리는 다음 단계에서 시작한다.
- 필요한 이유와 다음 사용 — `LA_ITEM.lsa`는 복제 지시 자체를 식별해 적용 성공 경계와, 재시작 시 이미 반영한 item을 건너뛰는 비교에 사용한다. applier는 `LA_ITEM.target_lsa`를 따라 실제 변경 데이터 D1·D2를 복원한다. 이 단계의 두 `LA_ITEM`과 scan cursor 변화는 아직 메모리에만 있다.

![4-develop-normal-step-2](./figures/4-develop-normal-step-2.svg)

*[그림 4-6] `final_lsa`가 `forw_lsa`를 따라 D1에서 C1까지 전진하는 동안 R1·R2에서 각각의 replication item을 만들고, C1을 다음 처리 위치로 남긴 상태.*

#### 장면 3 — C1을 commit list에 등록한다

- 판별 조건 — applier가 `la_Info.final_lsa=C1`에서 T1의 COMMIT 레코드를 읽는다.
- 값 변경 — `LA_COMMIT(T1).log_lsa=C1`인 노드를 전역 FIFO commit list에 넣는다. `la_Info.committed_lsa`와 `la_Info.committed_rep_lsa`는 아직 직전 적용 위치에 머문다.
- 필요한 이유와 다음 사용 — `LA_COMMIT.log_lsa`는 종료 레코드와 T1의 `LA_APPLY`를 연결한다. applier는 FIFO head의 이 노드를 꺼내 T1의 item을 적용하고, 처리를 마치면 C1을 `la_Info.committed_lsa`의 새 경계로 사용한다. 이 단계에서는 `LA_COMMIT` 메모리 구조만 추가된다.

![4-develop-normal-step-3](./figures/4-develop-normal-step-3.svg)

*[그림 4-7] C1의 로그 위치를 T1의 item 목록과 분리된 commit-list 노드에 기록한 상태.*

## 4.4 적용과 완료 경계

commit list의 head부터 트랜잭션의 item을 적용하면 `la_Info`의 두 완료 경계가 전진한다. 하나는 item 단위, 하나는 트랜잭션 단위다.

### 4.4.1 관련 LSA

- **`committed_rep_lsa`**: 적용에 성공한 replication item의 로그 위치다. item 적용이 성공하면 해당 `LA_ITEM.lsa`로 갱신하며, 다음 기동에서 이미 반영한 item을 건너뛰는 기준(`last_committed_rep_lsa`)의 원본이 된다. `_db_ha_apply_info`에 저장한다.

- **`committed_lsa`**: FIFO commit list에서 처리를 끝낸 COMMIT 계열 레코드의 위치다. 처리한 `LA_COMMIT.log_lsa`로 갱신하며, 트랜잭션 진행 상태와 다음 기동에서 이미 반영한 트랜잭션을 건너뛰는 기준(`last_committed_lsa`)의 원본이 된다. `_db_ha_apply_info`에 저장한다.

이름의 `rep`는 replication의 약자다. `la_Info`의 필드 주석 원문은 `last committed replication log lsa`이며, 여기서 replication log는 리플리카 전체의 진행이 아니라 **replication item을 지시하는 로그 레코드**(`LOG_REPLICATION_DATA` 등)를 뜻한다. 그림에서 D1은 실제 변경 데이터, R1은 D1을 적용하라는 복제 지시, C1은 트랜잭션 COMMIT이다. 따라서 `committed_rep_lsa`는 적용을 끝낸 R 계열 위치이고, `committed_lsa`는 처리를 끝낸 C 계열 위치다.

| 기호  | 로그 레코드                                  | 보관 위치                | 진행 상태로의 반영                          |
| --- | --------------------------------------- | -------------------- | ----------------------------------- |
| D   | 실제 변경 데이터 로그                            | `LA_ITEM.target_lsa` | record image 복원에만 사용하고 진행값으로 쓰지 않는다 |
| R   | `LOG_REPLICATION_DATA` — D를 적용하라는 복제 지시 | `LA_ITEM.lsa`        | item 적용 성공 시 `committed_rep_lsa`    |
| C   | COMMIT 계열 레코드                           | `LA_COMMIT.log_lsa`  | commit list 처리 완료 시 `committed_lsa` |

### 4.4.2 장면 4~5

#### 장면 4 — D1·D2를 복원해 적용한다

- 판별 조건 — applier가 FIFO head의 T1에서 `LA_ITEM` #1과 #2를 차례로 꺼낸다.
- 값 변경 — 각 `LA_ITEM.target_lsa`를 따라 D1·D2의 record image를 복원해 UPDATE하고, item 적용 함수가 성공할 때마다 `la_Info.committed_rep_lsa`를 R1, R2 순서로 전진시킨다.
- 필요한 이유와 다음 사용 — `la_Info.committed_rep_lsa`는 성공한 replication item의 경계를 기억한다. 이후 apply-info 영속화와 다음 기동의 `last_committed_rep_lsa` 복원에 사용되지만, 현재 값과 account 변경은 아직 applier의 미커밋 DB 트랜잭션에 있다.

![4-develop-normal-step-4](./figures/4-develop-normal-step-4.svg)

*[그림 4-8] target_lsa로 두 변경 데이터를 복원·적용하고 성공한 replication record까지 메모리 경계를 전진시킨 상태.*

#### 장면 5 — T1 처리를 끝내고 메모리 구조를 정리한다

- 판별 조건 — T1의 모든 `LA_ITEM` 적용이 끝나 `la_Info.committed_rep_lsa=R2`가 되고, FIFO commit-list의 T1을 완료 처리한다.
- 값 변경 — `la_Info.committed_lsa`를 `LA_COMMIT(T1).log_lsa`인 C1로 갱신하고, `la_Info.final_lsa`를 C1의 다음 로그로 전진시킨 뒤 T1의 `LA_APPLY`, `LA_ITEM`, `LA_COMMIT`을 제거한다. `la_Info.required_lsa`는 아직 이전 로그 보존 하한이다.
- 필요한 이유와 다음 사용 — `la_Info.committed_lsa=C1`은 처리한 트랜잭션 경계를 나타내며 다음 apply-info 영속화와 재시작의 트랜잭션 skip 기준에 사용된다. 제거된 T1은 더 이상 로그 보존 대상이 아니므로 다음 `la_log_commit()`이 `la_Info.required_lsa`를 다시 계산한다.

![4-develop-normal-step-5](./figures/4-develop-normal-step-5.svg)

*[그림 4-9] T1의 commit-list 처리를 끝내 C1 경계를 기록하고, 미완 작업이 사라진 뒤 required_lsa 재계산을 기다리는 상태.*

## 4.5 영속

메모리에서 전진한 진행 상태는 `la_log_commit()`이 적용 데이터와 함께 DB에 확정할 때 재시작 가능한 상태가 된다. 이때 함께 계산되는 값이 `required_lsa`다.

### 4.5.1 required_lsa와 la_log_commit()의 저장 순서

- **`required_lsa`**: 미완 트랜잭션을 다시 구성하기 위해 보존해야 하는 가장 오래된 로그 위치다. 활성 `LA_APPLY.start_lsa` 중 최솟값을 사용하고, 활성 트랜잭션이 없으면 `final_lsa`를 사용한다. archive log 보존·삭제와 재시작 범위를 결정하며 `_db_ha_apply_info`에 저장한다.

- **`lowest_lsa`**: 활성 트랜잭션들의 `LA_APPLY.start_lsa` 중 최솟값을 계산해 `required_lsa`로 반환한다.

이 값까지 계산되면 `la_log_commit()`이 다음 순서로 영속한다. 저장되는 값은 [4.7](./4-cubrid-develop-lsa와-직렬-처리.md#47-lsa-요약표)의 여섯 값과 같다. `la_log_commit()`은 다음 순서로 이 값들을 확정한다.

1. `la_find_required_lsa()`로 `required_lsa`를 다시 계산한다.
2. active log header에서 `append_lsa`와 `eof_lsa`를 복사한다.
3. 남은 replication item을 flush한다.
4. `la_update_ha_last_applied_info()`가 여섯 값을 `_db_ha_apply_info` UPDATE 인자로 전달한다.
5. UPDATE가 성공한 경우에만 DB transaction을 commit한다.

메모리 값이 먼저 바뀌어도 적용 데이터 flush, apply-info UPDATE와 DB COMMIT이 모두 성공해야 다음 기동에서 신뢰할 영속 상태가 된다. 적용 데이터와 진행 상태가 같은 DB transaction으로 확정되므로 둘 중 하나만 남는 상태는 생기지 않는다. 코드 근거는 [10.2.8절](./10-코드-및-실측-부록.md#1028-active-log-상한과-여섯-lsa의-영속-경계)에 있다.

### 4.5.2 장면 6

#### 장면 6 — 적용 데이터와 진행 상태를 함께 영속한다

- 판별 조건 — 메모리가 `la_Info.committed_lsa=C1`, `la_Info.committed_rep_lsa=R2`, `la_Info.final_lsa=C1.forw`이고 활성 `LA_APPLY`가 없는 상태에서 `la_log_commit()`이 실행된다.
- 값 변경 — `la_find_required_lsa()`는 미완 트랜잭션이 없으므로 `la_Info.required_lsa=la_Info.final_lsa`를 선택한다. active log header에서 `la_Info.append_lsa`와 `la_Info.eof_lsa`를 복사한 뒤 변경 데이터 flush, `_db_ha_apply_info` UPDATE, DB transaction COMMIT을 수행한다.
- 필요한 이유와 다음 사용 — account 변경과 DB apply-info의 `committed_lsa=C1`, `committed_rep_lsa=R2`, `required_lsa=final_lsa`가 같은 DB commit으로 확정된다. 현재 프로세스의 `last_committed_lsa`와 `last_committed_rep_lsa`는 바뀌지 않는다. 다음 기동은 DB의 `committed_lsa=C1`을 `last_committed_lsa`로 복원해 이미 반영한 트랜잭션을 통째로 건너뛰고, DB의 `committed_rep_lsa=R2`를 `last_committed_rep_lsa`로 복원해 같은 트랜잭션 안의 이미 반영한 item을 건너뛴다. DB의 `required_lsa`는 applier가 다시 읽기를 시작할 위치를 제공한다.

![4-develop-normal-step-6](./figures/4-develop-normal-step-6.svg)

*[그림 4-10] 미완 트랜잭션이 없는 상태에서 required_lsa를 scan cursor로 계산하고 데이터와 새 apply-info 상태를 함께 영속한 결과.*

## 4.6 재시작

`_db_ha_apply_info`는 applylogdb가 재시작 뒤에도 이어서 사용할 진행 상태를 보관하는 카탈로그 테이블이다. 이 절은 기동 시 저장된 값에서 기준선을 **복원**하는 순서와 그 기준선이 쓰이는 두 위치를 설명한 뒤, 같은 예제의 재시작 장면 일곱 개를 따라간다.

### 4.6.1 기동 시 고정되는 두 값

다음 두 값은 `_db_ha_apply_info`의 컬럼이 아니다. 기동 시 DB에서 복원한 `committed_lsa`와 `committed_rep_lsa`를 한 번 복사해 만들고, 실행 중 두 원본이 전진해도 함께 움직이지 않는다.

- **`last_committed_lsa`**: 기동 시 `committed_lsa`를 복사한 트랜잭션 기준선
- **`last_committed_rep_lsa`**: 기동 시 `committed_rep_lsa`를 복사한 replication item 기준선

두 기준선을 만드는 순서와 두 가지 쓰임(이미 반영한 트랜잭션·item 건너뛰기, 저장값 하한)은 바로 아래에서 설명한다.

### 4.6.2 복원 순서

`la_apply_log_file()`의 기동 순서는 세 줄로 요약된다.

```text
① last_committed_lsa ← committed_lsa   기준선을 C0로 찍고 고정한다
② committed_lsa      ← required_lsa    committed_lsa만 Q0로 되감는다
③ final_lsa          ← committed_lsa   Q0부터 다시 읽기 시작한다
```

①은 `la_get_last_ha_applied_info()`가 `_db_ha_apply_info` 행을 `LA_HA_APPLY_INFO`로 읽어 `la_Info`의 여섯 값을 채운 직후에 일어나고(`last_committed_rep_lsa ← committed_rep_lsa`도 함께), ②는 그 **뒤에** `la_apply_log_file()`이 수행하며, ③은 메인 루프 진입 시 `la_apply_pre()`가 수행한다. 기준선을 먼저 고정하고 그 다음에 되감기 때문에 `last_committed_*`는 직전 실행이 마지막으로 영속한 완료 위치(C0·R0)를 유지하고 `committed_lsa`만 Q0로 내려간다. 두 기준선은 `_db_ha_apply_info`의 컬럼이 아니라 이 복사로만 만들어지는 메모리 값이며, 실행 중 `committed_lsa`와 `committed_rep_lsa`가 전진해도 바뀌지 않는다.

예외는 최초 실행이다. DB 행의 `committed_lsa`·`committed_rep_lsa`가 NULL이면 기준선을 복사하기 전에 두 값을 `required_lsa`(이 경우 active log의 `eof_lsa`)로 채우므로, 기준선도 같은 값으로 시작한다.

코드 근거는 [10.2.7절](./10-코드-및-실측-부록.md#1027-apply-info-복원과-재시작-기준선)에 있다.

### 4.6.3 기준선의 두 가지 쓰임

`last_committed_lsa`와 `last_committed_rep_lsa`를 읽는 코드는 상태 dump를 제외하면 두 곳이다.

| 쓰임 | 함수 | 동작 |
|---|---|---|
| ① 이미 반영한 트랜잭션·item 건너뛰기 | `la_apply_repl_log()` | `commit_lsa ≤ last_committed_lsa`이면 트랜잭션의 item을 적용하지 않고 폐기한다. 그보다 뒤의 트랜잭션 안에서는 `LA_ITEM.lsa ≤ last_committed_rep_lsa`인 item만 건너뛴다. |
| ② 저장값 하한 | `la_update_ha_last_applied_info()` | DB에 쓸 `committed_lsa`·`committed_rep_lsa`가 각 기준선보다 작으면 기준선 값을 대신 저장한다. |

②가 필요한 이유는 복원 순서에 있다. 기동 직후 `committed_lsa`는 `required_lsa`로 후퇴한 상태인데, applier가 C0를 다시 지나기 전에도 `la_log_commit()`이 호출되는 경로가 있다. 역할 전환 시 `la_change_state()`의 강제 commit과, HA 서버 상태 레코드를 처리하는 `la_log_record_process()`의 commit은 트랜잭션 COMMIT 처리와 무관하게 발생한다. 이때 ②가 없으면 후퇴한 `committed_lsa`가 그대로 DB에 저장돼 안전 경계가 뒤로 밀린다. ①만으로는 재시작을 반복할 때 영속 경계가 후퇴하는 것을 막을 수 없다.

### 4.6.4 장면 1~7

위의 원리를 4.3부터 4.5까지의 장면과 같은 방식으로 따라간다. 4.2의 T1(D1·D2·R1·R2·C1) 앞에 이미 완료된 T0(D0·R0·C0)와, Q에서 시작해 아직 끝나지 않은 장기 트랜잭션이 있다고 하자. applier가 T1을 읽는 도중 프로세스가 종료되고, `_db_ha_apply_info`에는 T0 처리 뒤 `la_log_commit()`이 확정한 `committed_lsa=C0`, `committed_rep_lsa=R0`, `required_lsa=Q`가 남아 있다. 각 장면의 그림은 이번 장면에서 바뀐 값만 주황으로, 고정되거나 바뀌지 않은 값은 회색으로 표시한다. 코드 근거는 [10.2.7절](./10-코드-및-실측-부록.md#1027-apply-info-복원과-재시작-기준선)과 [10.2.8절](./10-코드-및-실측-부록.md#1028-active-log-상한과-여섯-lsa의-영속-경계)에 있다.

#### 장면 1 — 프로세스가 종료되기 직전의 상태

- 판별 조건 — 메모리는 `committed_lsa=C0`, `committed_rep_lsa=R0`, `required_lsa=Q`이고 `final_lsa`는 T1의 R2를 읽고 있다. T1의 `LA_APPLY`·`LA_ITEM`과 장기 트랜잭션의 `LA_APPLY`는 메모리에만 있다.
- 값 변경 — 종료와 함께 `final_lsa`와 모든 `LA_APPLY`·`LA_ITEM`·`LA_COMMIT`이 사라진다. DB에는 마지막 `la_log_commit()`이 확정한 세 값만 남는다.
- 필요한 이유와 다음 사용 — T0의 데이터와 apply-info는 같은 DB commit으로 확정됐으므로 재시작이 신뢰할 수 있다. T1은 확정 전이므로 재시작 뒤 로그에서 다시 만들어야 한다.

![4-develop-restart-step-1](./figures/4-develop-restart-step-1.svg)

*[그림 4-11] 종료 직전 메모리의 진행 상태와, 종료 뒤에도 DB에 남는 세 값의 구분.*

#### 장면 2 — 재시작 · DB에 남은 값으로 `la_Info`를 채운다

- 판별 조건 — `la_get_last_ha_applied_info()`가 `_db_ha_apply_info` 행을 읽는다.
- 값 변경 — `la_Info.committed_lsa=C0`, `committed_rep_lsa=R0`, `required_lsa=Q`, `final_lsa=F0`(저장 당시 applier의 읽기 위치)가 NULL에서 채워진다.
- 필요한 이유와 다음 사용 — 메모리 구조는 사라졌으므로 이 DB 행이 재시작의 유일한 기준이다. 다음 장면에서 이 값으로 기준선을 만든다.

![4-develop-restart-step-2](./figures/4-develop-restart-step-2.svg)

*[그림 4-12] DB 행의 값이 `la_Info`로 복원된 직후. 기준선과 트랜잭션 구조는 아직 없다.*

#### 장면 3 — 기준선을 찍는다

- 판별 조건 — 복원이 끝난 직후 `la_get_last_ha_applied_info()` 안에서 수행된다.
- 값 변경 — `last_committed_lsa ← committed_lsa`(C0), `last_committed_rep_lsa ← committed_rep_lsa`(R0). 두 값은 이번 실행이 끝날 때까지 바뀌지 않는다.
- 필요한 이유와 다음 사용 — 읽는 쪽에서는 이미 반영한 트랜잭션·item을 건너뛰는 기준(장면 5), 쓰는 쪽에서는 DB에 저장할 값의 하한(장면 6)으로 쓰인다.

![4-develop-restart-step-3](./figures/4-develop-restart-step-3.svg)

*[그림 4-13] 복원한 두 committed 값을 복사해 이번 실행의 고정 기준선 C0·R0를 만든 상태.*

#### 장면 4 — `committed_lsa`를 `required_lsa`까지 되감는다

- 판별 조건 — 기준선을 찍은 **뒤에** `la_apply_log_file()`이 `committed_lsa ← required_lsa`를 수행하고, 메인 루프 진입 시 `la_apply_pre()`가 `final_lsa ← committed_lsa`를 수행한다.
- 값 변경 — `committed_lsa`가 C0에서 Q로, `final_lsa`가 F0에서 Q로 내려간다. `last_committed_*`와 DB 값은 그대로다.
- 필요한 이유와 다음 사용 — 끝난 T0를 다시 반영하려는 것이 아니다. 장기 트랜잭션과 T1의 `LA_APPLY`·`LA_ITEM`은 영속되지 않으므로 그 첫 로그인 Q부터 다시 읽어 메모리에 재구성한다.

![4-develop-restart-step-4](./figures/4-develop-restart-step-4.svg)

*[그림 4-14] 기준선 C0는 고정된 채 `committed_lsa`와 `final_lsa`만 Q로 되감긴 상태.*

#### 장면 5 — 역할 ① · Q부터 다시 읽고 C0에서 T0를 통째로 버린다

- 판별 조건 — applier가 Q부터 `forw_lsa`를 따라 C0까지 읽는다. C0에서 `la_apply_repl_log()`가 `commit_lsa(C0) ≤ last_committed_lsa(C0)`를 판정한다.
- 값 변경 — `final_lsa`가 Q에서 C0로 전진하고 장기 트랜잭션·T0의 `LA_APPLY`와 R0의 `LA_ITEM`이 다시 만들어진다. T0는 item을 적용하지 않고 폐기되므로 `committed_lsa`는 Q에 머문다.
- 필요한 이유와 다음 사용 — 이미 DB에 있는 T0를 다시 반영하면 중복 적용이 된다. 기준선 이하의 COMMIT은 통째로 건너뛴다.

![4-develop-restart-step-5](./figures/4-develop-restart-step-5.svg)

*[그림 4-15] Q~C0 구간을 다시 읽어 구조를 재구성하되, 기준선 이하의 T0는 적용 없이 폐기하는 판정.*

#### 장면 6 — 역할 ② · 이 사이에 `la_log_commit()`이 불리면 기준선이 저장값의 하한이 된다 (조건부)

- 판별 조건 — `final_lsa`가 C0를 지나 T1을 읽는 중이고 `committed_lsa`는 아직 Q인 상태에서, 트랜잭션 COMMIT 처리와 무관한 경로로 `la_log_commit()`이 호출된다. `la_change_state()`의 역할 전환 강제 commit과 HA 서버 상태 레코드 처리가 그 예다.
- 값 변경 — `la_update_ha_last_applied_info()`가 `committed_lsa(Q) < last_committed_lsa(C0)`를 보고 C0를 대신 저장한다. 메모리의 `committed_lsa`는 Q 그대로이고 DB의 `committed_lsa`는 C0를 유지한다.
- 필요한 이유와 다음 사용 — 되감긴 값이 그대로 저장되면 DB의 안전 경계가 Q로 밀려, 다음 재시작이 더 앞에서 기준선을 찍게 된다. 기준선이 그것을 막는다.

![4-develop-restart-step-6](./figures/4-develop-restart-step-6.svg)

*[그림 4-16] 되감긴 `committed_lsa`가 저장되려는 순간 기준선 C0가 하한으로 작용해 DB 값이 후퇴하지 않는 조건부 장면.*

#### 장면 7 — C1을 처리한다 · 기준선을 지나면 실제 값이 저장된다

- 판별 조건 — applier가 C1에 도달해 `la_apply_repl_log()`가 T1을 처리한다. `commit_lsa(C1) > last_committed_lsa(C0)`이고 R1·R2 모두 `last_committed_rep_lsa(R0)`보다 뒤다.
- 값 변경 — R1·R2를 적용해 `committed_rep_lsa=R2`, C1 처리로 `committed_lsa=C1`이 된다. 이어지는 `la_log_commit()`은 `la_find_required_lsa()`로 `required_lsa`를 다시 계산하고(장기 트랜잭션이 남아 Q 유지) 데이터와 함께 DB에 확정한다.
- 필요한 이유와 다음 사용 — C0를 지나면 `committed_lsa > last_committed_lsa`이므로 기준선은 더 이상 걸리지 않고 실제 값이 저장된다. 다음 기동은 C1·R2로 새 기준선을 찍는다. item 기준선 `last_committed_rep_lsa`가 실제로 item을 건너뛰는 경우는 트랜잭션 안에 `LOG_SYSOP_END`가 있어 일부 item이 COMMIT보다 먼저 적용·영속된 경우다. develop의 `la_log_record_process()`는 `LOG_SYSOP_END`를 `LOG_COMMIT`과 같은 분기로 처리해 그 위치까지의 item을 즉시 적용하므로, 이는 오류가 아니라 정상 동작이다.

![4-develop-restart-step-7](./figures/4-develop-restart-step-7.svg)

*[그림 4-17] 기준선을 지난 뒤 T1을 반영하고 새 완료 위치 C1·R2를 DB에 확정한 결과.*

## 4.7 LSA 요약표

LSA 이름이 많은 이유는 하나의 진행값을 여러 이름으로 부르기 때문이 아니다. 로그에 기록된 연결 좌표, applier의 읽기 진행 상태, 트랜잭션별 작업 위치와 DB에 영속한 재시작 상태가 각각 별도로 존재하기 때문이다.

`la_Info`는 applylogdb 프로세스의 메모리 전역 구조체다. 이 구조체는 applier가 읽을 수 있는 로그 범위, 현재 읽는 위치, 적용 결과와 로그 보존 하한을 보관한다. 모든 필드는 메모리에 있지만, DB에도 저장하는 값과 현재 프로세스에서만 유지하는 값으로 나뉜다.

다음 여섯 값은 실행 중 `la_Info`에 있으며, 주기적으로 `_db_ha_apply_info`에도 저장된다.

| LSA | 소유 위치 | 영속 | 뜻 | 기호 |
|---|---|---|---|---|
| `forw_lsa` | 로그 레코드 헤더 | 로그에 기록 | 물리적으로 다음 로그 레코드. applier가 `final_lsa`를 전진시키는 경로 | — |
| `back_lsa` | 로그 레코드 헤더 | 로그에 기록 | 물리적으로 이전 로그 레코드. 로그 체인 연속성 확인 | — |
| `prev_tranlsa` | 로그 레코드 헤더 | 로그에 기록 | 같은 트랜잭션의 이전 레코드. NULL이면 그 트랜잭션에서 처음 관찰한 레코드 | — |
| `chkpt_lsa` | active log header | 로그에 기록 | 최근 `LOG_START_CHKPT` 위치. 복제 재시작 위치로 쓰지 않음 | — |
| `append_lsa` | `la_Info` | `_db_ha_apply_info` 저장 | active log header의 다음 로그 기록 위치 | A |
| `eof_lsa` | `la_Info` | `_db_ha_apply_info` 저장 | 현재 유효 로그의 끝. applier는 이 위치를 넘어 읽지 않음 | E |
| `final_lsa` | `la_Info` | `_db_ha_apply_info` 저장 | applier가 현재 처리하거나 다음에 읽을 위치. 적용 완료가 아님 | F |
| `committed_rep_lsa` | `la_Info` | `_db_ha_apply_info` 저장 | 적용에 성공한 마지막 replication item 위치 | R |
| `committed_lsa` | `la_Info` | `_db_ha_apply_info` 저장 | 처리를 끝낸 마지막 COMMIT 계열 레코드 위치 | C |
| `required_lsa` | `la_Info` | `_db_ha_apply_info` 저장 | 미완 트랜잭션 재구성을 위해 보존해야 하는 가장 오래된 로그 위치 | Q |
| `last_committed_lsa` | `la_Info` | 메모리만 (기동 시 복사) | 이미 반영한 트랜잭션을 건너뛰는 기준이자 저장값 하한 | C0 |
| `last_committed_rep_lsa` | `la_Info` | 메모리만 (기동 시 복사) | 이미 반영한 item을 건너뛰는 기준이자 저장값 하한 | R0 |
| `LA_ITEM.lsa` | `LA_ITEM` | 메모리만 | replication record 자체의 위치 | R |
| `LA_ITEM.target_lsa` | `LA_ITEM` | 메모리만 | replication record가 가리키는 data log record 위치 | D |
| `LA_APPLY.start_lsa` | `LA_APPLY` | 메모리만 | 트랜잭션에서 처음 관찰한 로그 위치. `required_lsa` 후보 | — |
| `LA_APPLY.last_lsa` | `LA_APPLY` | 메모리만 | long transaction의 마지막 replication record 위치. 재탐색 상한 | — |
| `LA_COMMIT.log_lsa` | `LA_COMMIT` | 메모리만 | COMMIT·SYSOP_END·ABORT 레코드 위치. `committed_lsa` 갱신 경계 | C |

<img src="./figures/4-la-info-global-progress_draft.svg" alt="4-la-info-global-progress_draft" width="700">

*[그림 4-18] `la_Info`가 active log의 입력 범위 안에서 applier의 읽기 위치, item·트랜잭션 처리 경계와 로그 보존 하한을 각각 관리하는 구조.*

세부 갱신 경로는 [10.2.4절](./10-코드-및-실측-부록.md#1024-scan-cursor-전진과-로컬-검증값)부터 [10.2.8절](./10-코드-및-실측-부록.md#1028-active-log-상한과-여섯-lsa의-영속-경계)까지 확인한다.

### 4.7.1 함수 안에서만 사용하는 보조 LSA

- **`old_lsa`**: page fetch 전후의 `final_lsa`를 비교해 applier가 전진했는지 확인한다.
- **`last_eof_lsa`**: 직전에 본 `eof_lsa`와 현재 값을 비교해 새 로그 유입 여부를 확인한다.
- **`prev_final`**: 직전 레코드 위치를 보관해 현재 레코드의 `back_lsa`와 비교한다.
- **`lsa_apply`**: commit-list 적용 함수가 반환한 종료 레코드 위치를 받아 `committed_lsa` 갱신에 사용한다.

이 값들은 계산 중에만 존재하고 DB에는 영속되지 않는다. 실제 사용 위치는 [10.2절](./10-코드-및-실측-부록.md#102-cubrid-develop-lsa-코드-근거)에 모았다.

이 값들이 병렬 적용에서 어떻게 달라지는지는 [7.2](./7-writeset-병렬화에-따른-lsa-관리-변화.md#72-핵심-lsa와-메모리-완료-상태)에서 다룬다.
