# 슬레이브 정지 (2026-10-11 12:08:55~) — 쉬는 워커가 쥔 SCH_S 락이 DDL을 막음

추가 시나리오 A(seed 20261014, `sysop_runs/20261011T030754-20261014-1318716`)가 스키마 단계에서 "slave schema 1/49"로 10분 대기 후 실패했다. 3차 PASS 직후, HA 재배포 없이 이어서 돌린 실행이다. 증거는 같은 실행 디렉토리의 `slave-hang-evidence/`(lockdb, applylogdb 스택, 12:07 이후 applylogdb 로그).

## 상태

- applylogdb(pid 221686)는 살아 있고 모든 스레드가 CPU 0%. 재기동, 오류 로그 없음.
- 워커 1이 trid 2387180(commit 106629|6576, 항목 1개)을 12:08:55에 받은 뒤 `apply end`가 없다. frontier가 106627|8176에 묶여 그 뒤 태스크가 전부 park.
- 스택: 워커 1은 `do_create_entity` → `allocate_foreign_key` → `update_foreign_key_ref` → `locator_fetch(SCH_M_LOCK)`에서 서버 응답 대기. 시나리오 A의 FK 있는 `CREATE TABLE item_N`이 참조 대상 parent 클래스에 SCH_M을 요청한 것.
- lockdb: `sr_1011030754_1318716_1014_parent`의 holder는 tran 6(applylogdb(4), 쉬는 워커)의 SCH_S, blocked holder는 tran 5(워커 1)의 SCH_M 요청, 12:08:55부터. 나머지 워커들(tran 3,4,6,7,8)도 3차 실행 테이블들에 SCH_S를 쥔 채 `la_task_queue_pop`에서 대기.

## 원인

`la_commit_transaction`이 커밋 뒤 정리 단계에서 `ws_Resident_classes`의 모든 클래스에 `ws_intern_instances`를 부른다. 이 함수는 `locator_flush_all_instances` → `locator_fetch_class(DB_FETCH_READ)`로 **클래스마다 SCH_S 락을 다시 잡는다.** 커밋 직후라 이 락은 새 트랜잭션에 속하고, 그 워커가 다음 태스크를 받아 커밋할 때까지 풀리지 않는다.

- 이 정리 루프는 slave 커밋 e509c9d94(PoC 이식)에서 들어왔다. develop은 같은 자리에서 `ws_cull_mops()`만 부르고 클래스를 fetch하지 않는다.
- develop은 연결이 하나라 DDL도 같은 세션이 적용하므로 자기 SCH_S와 충돌하지 않는다. 병렬에서는 다른 워커 세션의 SCH_S가 DDL의 SCH_M을 막는다.
- 막힌 DDL 뒤로 gate가 모든 태스크를 park하므로 쉬는 워커는 영영 새 태스크를 못 받고 커밋도 안 한다. 서버 deadlock 탐지는 holder가 락 대기가 아니라(클라이언트 큐 대기) 잡지 못한다 → 영구 정지.
- 정리 루프는 시간·건수 간격으로만 돌기 때문에 타이밍 의존이다. 3차까지는 새 parent를 만든 직후 정리 루프가 그 클래스를 건드리지 않아 지나갔던 것으로 추정한다. 이번에는 워커 3이 parent `CREATE`(trid 2387179로 추정)를 적용·커밋한 뒤 정리 루프에서 parent에 SCH_S를 잡았다.
- 오늘 반영한 결함 1·3·4 수정과는 무관하다(해당 코드 미변경).

## 수정 (2026-10-11 반영, 미커밋·미빌드)

`la_commit_transaction`의 정리 루프 직후 `db_commit_transaction()`을 한 번 더 불러, 정리 중에 잡힌 SCH_S 락을 바로 놓는다. 정리 루프의 메모리 정리 효과는 유지한다. 이 커밋이 실패하면 그 오류를 태스크 결과로 돌려보내 재기동 경로를 탄다.

## 검토했던 다른 방향

1. 커밋 뒤 정리 루프를 develop처럼 `ws_cull_mops()`로 되돌리거나, 정리 뒤 곧바로 `db_commit_transaction()`(또는 abort)으로 그 SCH_S를 놓는다.
2. 근본적으로는 워커가 쉬는 동안 어떤 락도 쥐지 않도록 보장한다(태스크 사이에 열린 트랜잭션 금지).
3. 보조: DDL(LOG_REPLICATION_STATEMENT) 태스크는 다른 워커가 모두 비었을 때만 적용한다.
