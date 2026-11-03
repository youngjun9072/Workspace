---
tags: [CBRD-27508, applier, 테스트계획, 재시작, failover]
---
# 재시작·failover 테스트 계획 (작업 목록 ① 7번)

작성: 2026-10-15. 사용자 제시 4종: master cub_server 종료, slave cub_server 종료, applylogdb 종료, master HA 서비스 종료(failback). 각 케이스가 어느 코드 경로를 지나는지와 무엇을 봐야 하는지를 적는다. 빌드는 a6f4f225c 이후 커밋(57239ff43 2PC, 3924469c6 로깅·assert)을 포함한 새 빌드가 필요하다.

## 공통 준비

- 컨테이너 재시작(10-15 16:0x) 뒤 `/etc/hosts`에 상대 노드 항목이 없다(youngjun3→youngjun4, youngjun4→youngjun3). root 소유라 호스트에서 넣어야 HA가 뜬다. 넣기 전엔 `ha_node_list`의 이름 해석이 안 된다.
- master 아카이브 `testdb_lgar032~044`는 HA 복구 뒤 copylogdb가 따라잡으면 master가 지운다. 지우지 말 것.
- conf 기준값(워커 10, trace 1). 테스트 훅 환경변수(`CUBRID_HA_TEST_BLOCK_*`)는 cub_master를 새로 띄우면 사라진다. 케이스 3에서 다시 쓴다.
- 부하: `fk_multi_guard.sh`(fk_multi 720s) 또는 `verify_fragment_required.sh`의 big UPDATE. "적용 중"인 순간을 만들려면 slave `reader retire`가 증가 중일 때 트리거한다.
- 판정 전 slave 직접 조회. fail_counter는 delta. 기지 신호 목록(`project_cbrd27508_known_signals`) 대조: 특히 **PR #8110 증상**(승격 직후 마지막 트랜잭션 누락, 60초 뒤 반영)은 develop 결함.
- 데이터 비교: 테이블별 `count(*)`·`sum(v)`를 양 노드에서, serial은 `db_serial.current_val`.

## 케이스 1. master cub_server 종료 (failover)

- 트리거: youngjun3에서 `kill -9 <cub_server pid>` (이 셸이 youngjun3). cub_master가 서버 재기동을 시도하지만 heartbeat가 youngjun4를 승격시킨다.
- 지나는 경로: youngjun4 applylogdb가 copied log 헤더의 `ha_server_state=DEAD`를 보고 `la_change_state` DONE 분기 → **fixes/01** `la_coordinator_drain_complete` 게이트 → 워커가 다 적용한 뒤 DONE → `css_notify_ha_log_applier_state` → 서버 to-be-active→active.
- 볼 것:
  - slave 로그 `applylogdb holds DONE: workers are still applying (...)` → `applylogdb reports DONE after holding it for N seconds`. N이 30 이상이면 백스톱(`LA_DRAIN_TIMEOUT_MSEC`)이 먼저 걸린 것(별도 로그 있음).
  - `cubrid heartbeat status`에서 youngjun4 Server가 `registered_and_active`로 가는 시간.
  - 승격 노드 데이터 = kill 직전 master 커밋분 전부(부하 스크립트가 마지막 커밋 id를 남기게).
  - 기준선(d43e03e 계열)에서는 to-be-active 고착(10-14 22:07과 동일).
- 뒷정리: youngjun3 서버를 다시 올리면 slave로 합류(failback 아님, 역할 교대). 데이터 비교.

## 케이스 2. slave cub_server 종료

- 트리거: youngjun4에서 `kill -9 <cub_server pid>`. cub_master가 서버를 재기동한다. master는 영향 없음.
- 지나는 경로: youngjun4 applylogdb 워커 연결이 끊김 → `ER_NET_CANT_CONNECT_SERVER` → 코디네이터 `la_shutdown` → cub_master가 applylogdb 재기동 → **재시작 복구 구간**(`recovery_boundary_lsa` = 저장된 `max_committed_lsa`까지 병렬 재적용, fixes/03 보류 상태 = 직렬화 없음).
- 볼 것:
  - 재기동 뒤 `recovery_skipped_counter`(재적용 오류 무시 건수)와 `[WSET] worker error` 중 -72(교착) 유무. 교착이 나면 희생자가 재시도로 진행되는지(결함 4) — 멈추면 락 덤프.
  - 복구 구간 통과 뒤 정상 적용 재개, master/slave 데이터 일치.
  - fail_counter delta: 복구 구간의 skip은 fail_counter에 안 들어가야 한다.
  - 이 케이스가 3번(복구 구간 직렬화) 결정의 근거다.

## 케이스 3. applylogdb 종료 (재시작 복구, 홀 포함)

- 트리거: youngjun4에서 applylogdb `kill -9`. 워커들이 적용 중(일부 커밋·일부 미커밋)인 순간이어야 복구 구간에 홀이 생긴다. 결정적으로 만들려면 테스트 훅: youngjun4 cub_master를 `CUBRID_HA_TEST_BLOCK_CLASS=<표 이름> CUBRID_HA_TEST_BLOCK_MSEC=60000`으로 띄워 한 워커를 commit 직전에 세우고, 다른 워커들이 그 뒤 커밋을 끝낸 상태에서 kill (`crash_precise_afhole_test.sh`, `crash_scattered_holes_test.sh`가 이 방식).
- 지나는 경로: 케이스 2와 같은 복구 구간 + 홀 재적용. 멈춘 워커의 미커밋분은 롤백되어 홀로 남고, 재기동 후 `committed_lsa`(frontier)부터 다시 읽어 홀을 채운다.
- 볼 것: 홀 N건이 전부 반영되는지, 홀 뒤 이미 커밋된 것들은 skip되는지(`recovery_skipped_counter` = 기대 건수), 교착 여부, 데이터 일치, applylogdb 로그의 `applylogdb reader exit` 뒤 재기동 라인.

## 케이스 4. master HA 서비스 종료 (`cubrid heartbeat stop`, failback)

- 트리거: youngjun3에서 `cubrid heartbeat stop`(정상 정지). copied log 헤더가 `DEAD`로 바뀌고 youngjun4가 승격된다. 그 뒤 youngjun3 `cubrid heartbeat start`로 복귀시키면 youngjun3는 slave로 들어오고, failback(원래 역할 복구)은 운영자가 youngjun4를 내리거나 `changemode`로 한다.
- 지나는 경로: 케이스 1과 같은 DONE 게이트(fixes/01). 추가로 **PR #8110** 결함 경로: 정지 직전 긴 적용(CREATE INDEX 재생) 중이면 slave 코디네이터 페이지가 stale이 되어 마지막 트랜잭션을 못 읽고 DONE. 재현 순서는 PR 본문(CREATE INDEX 커밋 → 0.5초 뒤 INSERT → heartbeat stop).
- 볼 것:
  - 승격 시간, `holds DONE`/`reports DONE` 로그.
  - 마지막 트랜잭션이 승격 노드에 있는지. 없고 60초 뒤 나타나면 PR #8110(기지 신호 5). 우리 결함 아님.
  - youngjun3 복귀 뒤 양방향 데이터 일치, youngjun3 applylogdb가 youngjun4 로그를 따라잡는지.
  - 10-14 22:07 사건(복귀 노드 to-be-active 고착)이 재발하는지 — fixes/01로 막혀야 함.

## 결과: 케이스 1 (10-15 21:46~22:51, 빌드 2661-a6f4f22, 워커 10)

스크립트 `ha_bench_tool/bin/failover_master_kill.sh`. 1회 기본 + 3회 강한 런(`BACKLOG_SECS=60`: slave applylogdb 60초 정지로 백로그 → 재개 직후 master `kill -9 cub_server`).

| 런 | 결과 갈래 | 서버 복귀 | 부하 끊김 | 재시작 후 커밋 보류 수 | 경계 | 데이터 |
|---|---|---|---|---|---|---|
| 21:46 기본 | 재기동 | 21.2s | 16s | (slave가 먼저 비움) | 보류→방출 1ms | 일치 |
| 22:38 강한 1 | 재기동 | 22.1s | 16s | 23 | OK (+0.000s) | 일치 |
| 22:44 강한 2 | 재기동 | 20.9s | 16s | 30 | OK (+0.000s) | 일치 |
| 22:48 강한 3 | 재기동 | 21.7s | 16s | 26 | OK (+0.001s) | 일치 |

- **갈래**: master cub_server만 죽으면 cub_master가 재기동(`Process failure detected → Restart the process`), 노드 역할 유지. failover 아님. 따라서 fixes/01의 DONE 보류 경로는 이 케이스에서 지나가지 않는다(케이스 4에서 확인).
- **재시작 경계**: 재기동 서버가 `HISTORY_START raise history_start=<복구 로그 끝>`을 올리고 이후 모든 라벨이 그 값을 의존으로 실음. slave는 그 커밋들을 보류(status=2)했다가 재시작 전 마지막 트랜잭션의 `worker apply done` 직후 방출(status=1). 강한 런 3회 모두 역전 없음(기준: 마지막 재시작 전 apply done 시각 ≤ 첫 재시작 후 방출·apply begin 시각).
- **복제 재개**: slave applylogdb가 `active→dead`(working→done) 뒤 재기동 서버를 `dead→active`로 인식해 `recovering→working`. 인식까지 45~80초(copylogdb 재접속 간격, develop 동작으로 추정). 그 뒤 백로그·'after' 20건 전부 적용.
- marker id 공백 없음, big 합계 일치(판정 시점 lag로 400,000 차이가 2회 찍혔으나 수 초 뒤 일치 → 스크립트가 합계 동기화를 기다리도록 수정), fail_counter delta 0.
- 로그 판독 주의: 코디네이터는 한 pass에서 결과 수거→frontier 전진→보류 방출(`status=1`)→retire 순이라 방출 trace가 같은 pass의 `reader retire`보다 먼저 찍힌다. 경계 판정 기준은 `worker apply done`.
- 하니스 사고: 원격 `cubrid heartbeat applylogdb start`가 ssh 세션을 물고 안 끝남 → 원격 stdio를 `/dev/null`로 떼어 해결. 옛 백그라운드 명령이 스크립트를 덮어써 1회차가 죽고 부하 서브셸이 27분 고아로 돈 사고 있음(pid로 종료, 데이터 영향 없음).

## 순서와 기록

1. 케이스 2 → 3 (failover 없이 slave만; 복구 구간 관찰, 3번 결정 근거)
2. 케이스 1 → 4 (failover·failback; 각각 뒤에 역할 복구)
3. 케이스마다 `log/restart_<case>_<ts>/`에 양 노드 applylogdb·server 로그 사본, heartbeat status 타임라인, 데이터 비교 결과, fail_counter delta, 기지 신호 대조.
4. 결과는 `_impl/fixes/01`(케이스 1·4), `03`(케이스 2·3) 검증 절에 반영.

## 미리 짜 둘 것

- `restart_case.sh <1|2|3|4>`: 부하 시작 → 트리거 → 상태 폴링 → 로그 사본 → 데이터 비교. 케이스 1·4의 트리거는 youngjun3 로컬, 2·3은 ssh youngjun4.
- 마지막 커밋 id를 남기는 부하(`marker` 테이블에 초당 1건 INSERT)로 "kill 직전 커밋분"을 정의.
