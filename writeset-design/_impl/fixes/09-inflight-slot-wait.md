---
tags: [CBRD-27508, applier, fixes]
---
# in-flight 목록이 끝난 태스크로 꽉 찼을 때 coordinator가 오지 않을 결과를 기다리는 문제

작성: 2026-10-29. PR #8052 Greptile 리뷰(3차, 리뷰 대상 커밋 `ccae929b5`)의 P1 지적 `log_applier.c:1084`에서 출발했다. 코드 순서로 확인했고, 시험에서 실제로 난 적은 없다.

코드 기준: `~/Workspace/cubrid`, 브랜치 `feature/CBRD-27508-parallel-applylogdb-writeset`, `ccae929b5`. 아직 코드 변경 없음.

## 한 줄 요약

coordinator는 결과를 거둔 직후, 풀려난 대기 태스크를 retire보다 먼저 워커에게 넘긴다. 이때 in-flight 목록이 끝난 태스크로 꽉 차 있으면 빈칸을 기다리는데, 기다리는 방식이 "새 결과가 오면 그때 retire"라서, 목록 안의 태스크가 모두 끝난 경우에는 새 결과가 오지 않아 영원히 기다린다.

## 용어

- 태스크: coordinator가 워커에게 넘기는 반영 작업 하나. 보통 트랜잭션 하나.
- in-flight 목록: 넘긴 태스크를 넘긴 순서대로 적어 두는 장부. 크기는 워커 수 × 1024(워커 10개면 10,240칸).
- 결과 큐: 워커가 태스크를 끝내면 결과를 넣는 큐.
- retire: in-flight 목록 맨 앞 태스크가 끝났으면 목록에서 빼고 `committed_lsa`를 올리는 일. 맨 앞이 안 끝났으면 뒤가 끝났어도 빼지 못한다.
- 대기 태스크: coordinator가 읽었지만 아직 워커에게 넘기지 못하고 pending 목록(`la_pending`)에 둔 태스크. 이유는 두 가지다.
  - dependency 이하의 커밋이 아직 다 안 끝남(기본 경우)
  - dependency는 풀렸지만 작업 큐(1024칸)가 가득 참(보조 경우)
  - pending 목록은 coordinator만 쓰는 연결 목록이고 칸 수 제한이 없다. coordinator가 읽기를 멈추는 한도는 commit-order ring(워커 수 × 1024)과 `ha_apply_max_mem_size`다.

## 확인한 코드

- `la_coordinator_collect_and_retire`: `la_coordinator_collect_results` → `la_coordinator_retire_results` 순서.
- `la_coordinator_collect_results`: 결과 큐를 비울 때까지 꺼내 in-flight 칸에 "끝남"을 표시하고(`la_coordinator_record_result`), frontier를 올린 뒤 `la_coordinator_drain_ready`로 풀린 대기 태스크를 넘긴다.
- `la_coordinator_drain_ready` → `la_coordinator_enqueue_task` → `la_coordinator_wait_for_inflight_slot`.
- `la_coordinator_wait_for_inflight_slot`(`log_applier.c:1077`): 목록이 가득 찬 동안 `la_coordinator_pop_result`로 새 결과를 기다리고, 받을 때마다 기록·frontier·retire를 한다. 기다리기 전에 retire를 하지 않는다.
- `la_coordinator_pop_result`: 결과가 없으면 100ms씩 기다리며 `la_applier_need_shutdown`만 확인한다. 종료 신호가 없으면 끝나지 않는다.

## 예시 (in-flight 목록을 3칸으로 줄여서)

설정: 목록에 A, B, C가 순서대로 있고, 대기 태스크 P는 A가 끝나기를 기다리며 pending 목록에 있다.

1. 시작 상태
   - 목록: [A 실행 중] [B 끝남] [C 끝남]
   - B와 C는 끝났지만 맨 앞 A가 안 끝나서 retire하지 못했다. 목록 3칸이 다 차 있다.
2. A가 끝남
   - 워커가 결과 큐에 "A 끝" 결과를 넣는다.
   - 이제 일하는 워커가 하나도 없다. 결과 큐에 새 결과가 더 들어올 일이 없는 상태다.
3. coordinator 1단계: 결과 꺼내기
   - 결과 큐에서 "A 끝"을 꺼내 목록에 표시한다.
   - 목록: [A 끝남] [B 끝남] [C 끝남]. 결과 큐는 비었다.
   - A가 끝났으니 P가 풀려난다.
4. coordinator 2단계: P를 워커에게 넘기려 함
   - 넘기기 전에 목록에 빈칸이 있는지 본다. 3칸이 다 차 있어서 빈칸이 없다.
   - 그래서 빈칸이 생길 때까지 기다리는데, 기다리는 방식이 "결과 큐에 새 결과가 오면 꺼내고, 그때 retire해서 칸을 비운다"이다.
   - 결과 큐는 비었고 일하는 워커도 없어서 새 결과는 영영 오지 않는다.
5. 멈춤
   - 지금 바로 retire하면 A, B, C 세 칸이 다 비워진다.
   - 그런데 retire는 3단계에서 하게 되어 있고, coordinator는 2단계에서 결과를 기다리느라 3단계로 가지 못한다.
   - 칸을 비울 방법(retire)은 바로 앞에 있는데, 오지 않을 결과를 기다리고 있는 상태다.

한 줄로: "목록이 다 찼으면 새 결과를 기다린다"는 규칙이, 목록 안의 태스크가 이미 다 끝나 있는 경우를 고려하지 않았다.

실제 크기(10,240칸)에서는 큰 트랜잭션이 맨 앞에서 오래 도는 동안 뒤의 끝난 태스크가 목록을 다 채우고, 그 큰 트랜잭션에 dependency가 걸린 대기 태스크가 있을 때 생긴다. 지금까지 시험의 백로그에서는 맨 앞 하나가 이만큼 붙잡은 적이 없었던 것으로 보인다(추정).

## 수정안

`la_coordinator_wait_for_inflight_slot`에서 새 결과를 기다리기 전에, 이미 끝난 태스크를 먼저 retire한다(`la_coordinator_retire_results`). 그래도 빈칸이 없을 때만 새 결과를 기다린다. 그 경우는 맨 앞 태스크가 실제로 실행 중이라 결과가 반드시 온다.

- 기존 호출을 지우거나 옮기지 않고, 루프 맨 앞에 retire 호출 하나와 빈칸 재확인을 더하는 변경이다.
- 이 함수는 지금도 결과를 하나 받을 때마다 retire를 부르므로(apply info 저장 포함), 같은 자리에서 retire를 한 번 더 부르는 것은 새 동작이 아니다.

## 커밋 메시지용

위 "예시"의 3칸 설명을 커밋 메시지 본문에 줄여 넣는다(목적: 왜 retire를 먼저 하는지 드러나게).

## 상태

- 코드 수정: 미착수(지시 대기)
- 검증: 미정. 재현은 맨 앞 큰 트랜잭션 + 뒤 작은 트랜잭션 10,240개 + 대기 태스크 조합이 필요하고, unit test(in-flight 목록 작은 크기)로 만드는 쪽이 현실적이다.
- Greptile 답글: 수정 뒤 작성
