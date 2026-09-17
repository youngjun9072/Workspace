---
tags: [writeset, design, lsa, applylogdb, recovery]
date: 2026-09-16
status: 정식 설계 문서
---

# 7. 병렬화에 따른 LSA 관리 변화

[4장](./4-cubrid-develop-lsa와-직렬-처리.md)에서 설명한 LSA의 종류와 물리적 의미는 병렬화 후에도 바뀌지 않는다. 새로운 로그 좌표를 추가하는 대신, 기존 COMMIT LSA를 task의 현재 위치·선행 조건·개별 완료·연속 완료 경계로 구분해 관리한다. 이에 따라 **reader가 로그를 읽은 위치와 worker가 적용을 끝낸 위치가 더 이상 함께 움직이지 않는다.**

이 장은 이 차이를 설명하는 핵심 LSA만 다룬다. 개별 복제 항목의 LSA와 로그 레코드 연결 포인터처럼 병렬화로 의미가 바뀌지 않는 값은 4장의 정의를 따르며, 구조체와 함수의 상세 대응은 [8-2장](./8-2-cubrid-슬레이브-병렬-적용-상세-설계.md)에서 다룬다.

## 7.1 develop과 병렬 적용의 차이

develop에서는 reader가 COMMIT을 만나면 같은 실행 흐름에서 해당 트랜잭션을 DB에 적용한다. DB COMMIT이 끝난 뒤 완료 위치와 읽기 위치를 차례로 전진시키므로, 앞의 트랜잭션을 남겨 둔 채 뒤의 COMMIT을 계속 읽지 않는다.

병렬 적용에서는 reader가 COMMIT에서 task를 완성해 worker에 넘긴 뒤 결과를 기다리지 않고 다음 로그를 읽는다. 따라서 reader의 읽기 위치는 앞서가고, 실제 적용 완료 위치는 worker 결과를 따라 뒤에서 전진한다.

이 차이를 나타내는 두 값은 다음과 같다.

- **`final_lsa`**: reader가 현재 처리하거나 다음에 읽을 로그 위치다. task를 worker에 넘긴 뒤에도 다음 로그를 따라 전진하므로, 해당 위치까지 DB 반영이 끝났다는 뜻은 아니다.
- **`committed_lsa`**: 대상 DB에 앞에서부터 빠짐없이 적용됐다고 확정한 마지막 COMMIT 위치다. worker 하나가 더 뒤의 task를 먼저 끝내더라도 중간에 미완료 task가 있으면 그 앞에 머문다.

따라서 병렬 적용 중에는 일반적으로 `final_lsa`가 `committed_lsa`보다 앞설 수 있다. 그림 8-1은 reader가 먼저 전진하고, worker 완료 결과가 COMMIT 순서의 빈 구간 없이 이어질 때만 `committed_lsa`가 뒤따라 전진하는 관계를 보여준다.

![8-develop-parallel-lsa-flow](./figures/8-develop-parallel-lsa-flow.svg)

*그림 8-1. develop에서는 읽기와 적용 완료가 같은 흐름으로 전진하지만, 병렬 적용에서는 reader가 `final_lsa`를 전진시켜 다음 COMMIT 읽기를 반복하는 동안 worker의 적용 완료가 별도로 진행되는 차이*

## 7.2 핵심 LSA와 메모리 완료 상태

병렬화는 새로운 형식의 로그 좌표를 만들지 않는다. `commit_lsa`와 `dependency_seq`는 모두 마스터 로그의 COMMIT 좌표를 슬레이브 task에 보존한 값이다. `commit_lsa`는 reader가 현재 트랜잭션의 COMMIT 레코드에서 얻고, `dependency_seq`는 마스터가 `WS_LABEL`에 기록해 전달한다. 두 값은 변경 데이터를 찾는 복제 항목 위치가 아니라, task의 실행 순서와 완료 여부를 판정하는 메타데이터다.

- 슬레이브가 worker 결과를 수거하면서 메모리에 직접 유지하는 것은 **개별 완료 상태**와 **연속 완료 경계(frontier)**다.
- **개별 완료 상태(completed set) — 메모리 완료 집합**: worker가 DB COMMIT에 성공했다고 반환한 `commit_lsa`들을 보관한다. frontier보다 뒤의 특정 선행 트랜잭션이 먼저 끝났는지 확인하고, 앞쪽 홀이 닫힐 때 frontier를 연속으로 전진시키는 데 사용한다.
- **연속 완료 경계(frontier) — 메모리 경계 상태**: COMMIT 순서에서 중간 홀 없이 연속으로 완료된 마지막 COMMIT LSA다. 메모리의 COMMIT 순서 상태와 개별 완료 상태를 대조해 계산하며, `committed_lsa`는 이 경계까지만 전진해 영속된다.

개별 완료 상태는 COMMIT LSA의 존재 여부를 빠르게 확인하는 **해시 기반 집합**이고, COMMIT 순서 상태는 reader가 COMMIT을 읽은 순서대로 LSA를 넣는 **FIFO**다. 두 상태는 다음처럼 함께 사용한다.

```text
reader가 COMMIT을 읽음
→ COMMIT LSA를 순서 FIFO에 추가

worker 완료 결과를 수거함
→ 성공한 COMMIT LSA를 완료 해시에 추가
→ FIFO head가 완료 해시에 있는 동안
     frontier를 head까지 전진
     FIFO head 제거
→ frontier 이하의 완료 해시 항목은 안전한 시점에 정리
```

HWM은 별도 변수나 자료구조가 아니라, 개별 완료 상태에 들어 있는 COMMIT LSA 중 최댓값을 설명하기 위한 개념이다. HWM과 frontier가 같으면 읽어 온 범위가 순서대로 완료된 상태다. 앞선 task가 끝나지 않은 채 뒤의 task가 먼저 끝나면 HWM은 앞으로 이동하지만 frontier는 홀 앞에 머문다.

4장에서 설명한 기존 LSA가 병렬 적용에서 어떻게 달라지는지는 다음과 같다.

| 대상                              | develop                               | 병렬 적용                                                     | 리뷰할 핵심                                          |
| ------------------------------- | ------------------------------------- | --------------------------------------------------------- | ----------------------------------------------- |
| `la_Info.final_lsa`             | 현재 트랜잭션의 적용을 마친 뒤 다음 로그로 전진           | task를 넘긴 뒤 worker 완료 전에 먼저 전진할 수 있음                       | 읽기 위치를 적용 완료 위치로 사용하지 않는가                       |
| `LA_APPLY_TASK.commit_lsa`      | reader가 순차 적용하는 COMMIT 위치             | task가 자신의 COMMIT 위치를 끝까지 보존해 순서 밖 완료를 원래 COMMIT 순서에 다시 연결 | task 생성부터 결과 수거까지 값이 유지되는가                      |
| `la_Info.committed_lsa`         | 순차 DB COMMIT이 끝난 위치로 전진               | 연속 완료 경계까지만 전진하고 그 값을 영속                                  | 메모리 경계와 apply info 영속 성공을 구분하는가                 |
| `la_Info.required_lsa`          | reader가 보유한 미완 트랜잭션의 가장 오래된 시작 위치를 보존 | reader가 지나간 task도 retire될 때까지 미완 범위에 포함                   | pending·worker·결과 대기 task의 시작 위치를 너무 일찍 버리지 않는가 |
| `la_Info.committed_rep_lsa`     | 적용한 복제 항목의 진행 위치                      | 여러 worker 결과의 관측 최댓값이며 연속 완료를 보장하지 않음                     | 재시작 안전 경계나 hole 통과 조건으로 사용하지 않는가                |

즉 병렬화는 LSA의 물리적 의미를 바꾸지 않는다. **어떤 실행 결과를 확인한 뒤 값을 전진시킬 수 있는지**와 **그 값을 언제까지 보존해야 하는지**가 달라진다.

## 7.3 reader가 앞서갈 때 보존해야 하는 경계

T1의 COMMIT 위치가 C1이고, 그 전까지 빠짐없이 적용된 위치가 C0이라고 하자. reader가 C1에서 task를 만들어 worker에 넘기면 다음 로그로 이동할 수 있다.

```text
C1 COMMIT 읽기
→ T1 task에 commit_lsa=C1 보존
→ task를 pending 또는 worker에 전달
→ reader는 final_lsa를 다음 로그로 전진
→ T1의 성공 결과가 없으므로 frontier와 committed_lsa는 C0 유지
```

`final_lsa`가 C1을 지났다는 것은 reader가 C1을 읽었다는 뜻일 뿐이다. T1의 DB COMMIT 성공 결과가 완료 집합에 등록되고, C1이 COMMIT 순서 FIFO의 head로 확인돼야 frontier와 `committed_lsa`가 C1까지 전진한다.

T1이 아직 pending, worker queue, 실행 중 또는 결과 처리 대기 상태라면 장애 후 T1을 다시 구성할 가능성이 남아 있다. 따라서 T1의 시작 로그 위치도 `required_lsa` 계산에 계속 포함해야 한다.

## 7.4 순서 밖 완료와 COMMIT 순서의 홀

마스터의 COMMIT 순서가 `C1 → C2 → C3`이어도 worker 완료 순서는 `C3 → C1 → C2`가 될 수 있다.

아래 표의 **개별 완료 상태** 열이 completed set의 현재 내용이다. `{C3}`은 C3의 worker 결과가 먼저 수거되어, C3의 `commit_lsa`가 완료 해시에 들어 있다는 뜻이다.

| worker 결과가 도착한 시점 | 개별 완료 상태       | 연속 완료 경계             |
| ----------------- | -------------- | -------------------- |
| C3 완료             | `{C3}`         | C1이 비어 있으므로 유지       |
| C1 완료             | `{C1, C3}`     | C1까지 전진              |
| C2 완료             | `{C1, C2, C3}` | C2와 이미 끝난 C3까지 연속 전진 |

뒤의 C3가 먼저 끝났지만 앞의 C1·C2가 끝나지 않은 구간이 **COMMIT 순서의 홀**이다. 개별 완료 상태는 C3 같은 특정 트랜잭션의 완료를 알려 주지만, 안전한 완료 위치는 아니다. `committed_lsa`는 이 홀을 건너뛰지 않고 연속 완료 경계까지만 전진한다.

개별 완료와 연속 완료 경계를 dependency 판정에 사용하는 방법은 [6-2.4절](./6-2-cubrid-슬레이브-병렬-적용-설계.md#6-24-dependency-판정과-task-배정), 홀 상태의 상세 자료구조와 용량 문제는 [8-2장](./8-2-cubrid-슬레이브-병렬-적용-상세-설계.md)에서 설명한다.

## 7.5 영속과 재시작

### 7.5.1 영속 완료 위치

영속된 `committed_lsa`는 다음 의미를 지켜야 한다.

> 이 위치 이하의 모든 COMMIT은 대상 DB에 빠짐없이 적용됐다.

따라서 `final_lsa`, 가장 큰 개별 완료 LSA 또는 `committed_rep_lsa`를 이 값으로 사용할 수 없다. 메모리의 연속 완료 경계를 `committed_lsa`에 반영하고 apply info 저장까지 성공한 뒤에야 재시작 시 신뢰할 수 있다.

### 7.5.2 비정상 종료 뒤의 홀 복구

비정상 종료에서는 drain을 끝내지 못할 수 있다. 완료를 추정해 경계를 앞당기는 대신 마지막으로 영속된 `committed_lsa`부터 다시 읽는다. 이때 이전 실행에서 저장한 `final_lsa`를 복구 상한 R로 고정한다. 저장된 R이 이전 실행에서 worker가 적용했을 가능성이 있는 범위를 빠짐없이 덮도록, task 공개와 `final_lsa` 영속의 순서 및 주기 저장 사이의 crash window 처리 계약은 상세 설계에서 확정해야 한다.

```text
기동
→ 영속된 committed_lsa를 재시작 기준선으로 복원
→ reader의 읽기 위치를 committed_lsa로 설정
→ 저장된 final_lsa를 recovery boundary R로 보존
→ (committed_lsa, R] 구간 재처리
→ R까지는 재적용 오류의 로그와 fail_counter 증가 생략
→ R 범위의 task와 연속 완료 경계 처리 완료
→ 정상 오류 처리로 전환
```

이 구간에는 이전 실행에서 이미 DB COMMIT된 task와 아직 적용되지 않은 hole이 섞여 있다. 이미 적용된 task의 재처리에서 발생하는 오류는 복구 구간의 관측 대상에서 제외하지만, 실패를 성공으로 바꾸거나 연속 완료 경계를 우회하지 않는다.

`required_lsa`는 복구 상한이 아니라 로그 보관 하한이다. 실행 중인 트랜잭션 가운데 가장 오래된 시작 위치를 유지한다.

### 7.5.3 복구 완료 판정

reader가 이전 실행의 읽기 위치까지 다시 도달했다는 사실만으로 복구가 끝난 것은 아니다. 그 범위의 task가 pending이나 worker에 남아 있을 수 있다.

복구 완료는 다음 조건을 함께 확인한다.

- 복구 대상 로그 범위를 다시 읽었다.
- 해당 범위의 task가 모두 처리됐다.
- 연속 완료 경계가 해당 범위의 마지막 COMMIT까지 도달했다.
- 갱신한 `committed_lsa`의 영속이 성공했다.

복구 중 오류 로그와 실패 횟수를 어떻게 집계할지는 완료 판정과 분리한다. 오류 관측을 생략하더라도 실패한 task를 성공으로 표시하거나 연속 완료 경계를 우회해서는 안 된다.

## 7.6 핵심 불변식

1. `final_lsa`는 적용 완료 위치가 아니다.
2. 개별 완료의 최댓값은 재시작 안전 경계가 아니다.
3. DB COMMIT 성공을 확인한 결과만 완료 상태에 반영한다.
4. 연속 완료 경계는 COMMIT 순서의 홀을 건너뛰지 않고 단조 증가한다.
5. `committed_lsa`는 연속 완료 경계까지만 전진하며, 영속 성공 전에는 재시작 완료 위치가 아니다.
6. 미완 task의 시작 위치는 task가 정리될 때까지 `required_lsa` 계산에 남는다.
7. drain하지 못한 비정상 종료는 영속된 `committed_lsa`부터 저장된 `final_lsa` 복구 상한까지 다시 처리한다.

이 장은 LSA의 역할과 상태 변화만 정의한다. 구조체와 함수의 상세 대응 및 홀 상태의 자료구조는 [8-2장](./8-2-cubrid-슬레이브-병렬-적용-상세-설계.md), 역할 전환 drain의 개념은 [6-2.7절](./6-2-cubrid-슬레이브-병렬-적용-설계.md#6-27-역할-전환-drain)에서 설명한다.
