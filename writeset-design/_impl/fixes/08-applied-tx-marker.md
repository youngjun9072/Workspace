---
tags: [CBRD-27508, applier, restart, fixes]
---
# 재시작 뒤 이미 커밋된 트랜잭션을 다시 적용해 PK·UNIQUE 변경이 어긋나는 문제

작성: 2026-10-28. PR #8052 Greptile 리뷰(2차, 리뷰 대상 커밋 `8d8d87c16`)의 P1 지적 `log_applier.c:7344` "재적용하면 이전 키가 남습니다"에서 출발했다. 같은 리뷰의 P1 2건(statement marker가 출처를 구분하지 않음, 기존 DB에 `max_committed_lsa` 열이 없음)도 이 문서의 해결 방향에 묶인다.

코드 기준: `~/Workspace/cubrid`, 브랜치 `feature/CBRD-27508-parallel-applylogdb-writeset`, `b2781cd09`. 아직 코드 변경 없음.

## 한 줄 요약

병렬 applier는 워커가 각자 연결로 데이터를 커밋하고, 진행 위치(apply info)는 coordinator가 나중에 따로 저장한다. 그래서 "커밋됐지만 위치는 저장되지 않은" 구간이 생기고, applier가 그 사이에 죽으면 재시작 때 그 구간(복구 구간)의 트랜잭션을 다시 적용한다. 행 재적용은 같은 결과를 낸다고 보고 일부 오류만 무시해 왔지만, PK나 UNIQUE 값을 바꾸는 UPDATE는 두 번 적용하면 결과가 달라진다. slave에 master에 없는 행이 남는다.

develop에는 없는 문제다. develop 직렬 applier는 데이터와 apply info를 한 트랜잭션에 커밋해서, 커밋된 트랜잭션을 다시 적용하지 않는다.

## 발생 조건

- master: T1이 키 1을 INSERT하고, T2가 키 1을 2로 UPDATE한다(PK 또는 UNIQUE 키 변경).
- slave: 두 트랜잭션을 모두 커밋했지만, coordinator가 apply info를 저장하기 전에 applylogdb가 죽는다(kill, 서버 다운 뒤 같은 프로세스 재시도 포함).
- 재시작한 applylogdb가 저장된 위치 이후를 복구 구간으로 보고 T1, T2를 다시 적용한다.

## 확인한 코드

- master는 PK를 바꾸는 UPDATE도 "옛 PK로 찾아 새 행 이미지로 바꾸는 UPDATE 항목 하나"로 복제한다. `locator_update_index`가 `RVREPL_DATA_UPDATE`에 옛 키(`repl_old_key`)를 넣어 남긴다(`locator_sr.c`의 두 `repl_log_insert`). DELETE와 INSERT로 나누지 않는다.
- slave 복구 구간에서 무시하는 오류는 두 가지뿐이다(`la_flush_repl_items`).
  - INSERT의 유일 키 충돌(`ER_BTREE_UNIQUE_FAILED`)
  - UPDATE·DELETE의 대상 행 없음(`ER_OBJ_OBJECT_NOT_FOUND`, `ER_HEAP_UNKNOWN_OBJECT`)
  - UPDATE의 유일 키 충돌은 무시하지 않는다. `er_set`과 fail_counter 증가로 이어진다.
- develop의 `la_log_commit`은 데이터 flush(`la_flush_repl_items`), apply info 갱신(`la_update_ha_last_applied_info`), 커밋(`la_commit_transaction`)을 한 클라이언트 트랜잭션에서 한다.

## 왜 생기나

dependency는 제대로 잡힌다.

- T1(키 1 INSERT)은 키 1을 WRITE로 모은다.
- T2(키 1을 2로 UPDATE)는 옛 키 1과 새 키 2를 둘 다 WRITE로 모은다(`locator_update_index`, `locator_sr.c`의 "UPDATE OLD"와 "UPDATE NEW" 두 `wset_add_write_key`).
- 키 1이 겹치므로 master는 T2의 라벨을 T1의 커밋으로 정하고, slave는 T1이 끝난 뒤에 T2를 적용한다. 처음 적용할 때는 순서가 맞다.

그런데도 생기는 이유는 다음과 같다.

- 처음 적용: T1 → T2 순서로 맞게 적용되어 slave에 키 2만 남는다.
- applier가 죽는다. 이때 두 커밋은 slave에 이미 반영됐지만, 진행 위치(apply info)는 그보다 앞으로 저장돼 있다.
- 재시작: 저장된 위치 이후를 복구 구간으로 보고 T1과 T2를 다시 적용한다. 복구 구간에서는 하나씩 커밋 순서대로 돌리므로 순서도 맞다.
  - T1 다시 적용: slave에 키 1이 없으니 INSERT가 성공해 키 1 행이 되살아난다.
  - T2 다시 적용: 키 1 행을 키 2로 바꾸려다 이미 있는 키 2와 충돌한다.
- 즉 순서는 끝까지 맞았다. 문제는 이미 반영된 T1과 T2를 다시 돌린 것이고, PK를 바꾸는 UPDATE는 두 번 돌리면 결과가 달라지는 연산이라는 점이다.

그래서 해결도 순서 쪽이 아니다.

- dependency나 gate로는 막을 수 없다.
- "이미 커밋된 트랜잭션인지"를 재시작 때 알 수 있어야 한다. 그래서 워커가 데이터와 같은 트랜잭션에 "이 커밋을 적용했다"는 기록을 남기는 방식이 맞다.
- develop은 데이터와 위치를 한 트랜잭션에 커밋해서 애초에 다시 적용하지 않으므로 이 문제가 없다.

## 결과

- slave에 master에 없는 키 1 행이 남는다.
- T2의 유일 키 충돌은 무시 대상이 아니므로 오류 로그와 fail_counter 증가로 드러난다. 조용히 지나가지는 않지만, 사용자가 보는 최종 데이터가 master와 다르다.
- UNIQUE 키 값을 바꾸는 UPDATE도 같은 경로로 보인다(추정, 재현 시험으로 확인할 것).

## 이전 시도

- **9-09 `5926f3840d`** "applied-tx marker for restart skip and failover hole drain": 파라미터 `ha_applylogdb_applied_tx_marker`를 켜면 워커가 적용 트랜잭션에 마커 INSERT를 함께 실어 커밋하고, 재시작 때 마커가 있는 트랜잭션을 건너뛰었다.
- **9-11 `a55821ea90`** "drop applied-tx marker; restart replays from the frontier": 마커를 빼고 재시작 때 frontier부터 다시 적용하도록 바꿨다. 근거는 "크래시 전에 순서 없이 적용된 커밋은 다시 적용할 때 무해하게 실패하고 상태가 수렴한다"였다. 이번 지적이 깬 가정이 바로 이것이다.
- 전체 마커 구현은 브랜치 `feature/parallel_applylogdb_writeset_hole_marker_drain`(`3601b3a5b`)에 보존돼 있다.
- 9월 측정: 마커 직접 비용은 커밋당 0.4~2.5ms(평균 약 0.7ms), 트랜잭션 처리 시간 대비 평균 0.04%(최악 0.12%). 비용의 원인은 마커 INSERT를 SQL로 해서 `la_sql_compile_mutex`에 모든 워커가 줄 서고 매번 다시 컴파일한 것이었다.
- 10-21 statement marker(`ha_applied_stmt_marker`): 마커를 statement 트랜잭션에만 좁혀 넣은 것이다. statement는 slave에서 혼자 도는 배리어라 한 행으로 충분했다.

## 해결 방안

### 채택 방향: 모든 적용 트랜잭션에 마커를 남기고, 재시작 때 마커가 있는 커밋을 워커가 건너뛴다

PoC의 다섯 조각과 지금 구조의 대응은 다음과 같다.

| 조각 | PoC 함수 | 지금 구조의 같은 자리 |
|---|---|---|
| 테이블 만들기 | `la_create_applied_tx_marker_table` | `la_create_applied_stmt_marker`, applier 시작 시 |
| 커밋마다 기록 | `la_insert_applied_tx_marker`, 데이터 커밋 직전 같은 트랜잭션 | 워커의 statement marker 갱신(`la_update_applied_stmt_marker`) |
| 시작 시 읽기 | `la_load_applied_tx_markers`, 정렬 배열 | `la_read_applied_stmt_marker` |
| 건너뛰기 | `la_applied_tx_marker_exists`, `la_apply_repl_log`에서 | `la_apply_repl_log`의 "이미 적용됨" 판단 |
| 정리 | `la_prune_applied_tx_markers`(apply info 저장 때), `la_clear_applied_tx_markers`(처음부터 다시 복제할 때) | `la_coordinator_commit_apply_info`, apply info 초기화 |

지금 구조에서의 모양:

1. **테이블**: statement marker를 넓혀 하나로 합친다(가칭 `ha_applied_tx_marker`).
   - 열: 출처(복사 로그 경로 또는 prefix), `commit_pageid`, `commit_offset`
   - 출처와 LSA에 인덱스를 둔다. PoC 리뷰에서 "인덱스가 없어 정리가 전체 스캔"이 지적됐다.
   - applier가 시작할 때 `CREATE TABLE IF NOT EXISTS`로 만드는 사용자 테이블이라 시스템 카탈로그 업그레이드가 필요 없다.
2. **기록**: 워커가 적용 항목이 있는 모든 커밋(SYSOP_END 조각 포함)에 대해, 데이터와 같은 트랜잭션에 한 행을 넣는다. 빈 커밋에는 넣지 않는다(9월 빈 커밋 핑퐁 수정과 같은 규칙).
3. **시작**: 저장된 `committed_lsa`보다 뒤에 있는 이 출처의 마커를 읽어 둔다. 시작 뒤에는 바뀌지 않으므로 워커들이 잠금 없이 읽는다.
4. **건너뛰기**: 워커의 `la_apply_repl_log`가 지금 `last_committed_lsa` 이하 커밋을 "이미 적용됨"으로 통째로 넘기는 조건에 "마커가 있으면"을 더한다. coordinator는 바꾸지 않는다.
5. **정리**: coordinator가 apply info를 저장할 때, 같은 트랜잭션에서 이 출처의 `committed_lsa`보다 앞선 마커를 지운다. "처음부터 다시 복제"로 apply info를 초기화할 때는 이 출처의 마커를 모두 지운다.

없어지는 것:

- 복구 구간의 오류 무시(`la_flush_repl_items`의 `recovery_skip`)
- 복구 구간 하나씩 적용(`la_coordinator_run_alone`의 그 용도)
- `la_coordinator_cover_commit`과 `_db_ha_apply_info`의 `max_committed_lsa` 열. Greptile 2차 지적 중 "기존 DB에 새 열이 없다"의 원인도 함께 사라진다(통계 테이블 2개는 따로 남음).
- statement marker(이 테이블로 합쳐짐)

### 기각: 복구 구간에서 UPDATE의 유일 키 충돌도 무시

오류만 사라지고 키 1 행이 남는 것은 같다. 문제가 보이지 않게 되므로 더 나쁘다.

## 미리 풀어야 할 것과 해결책

**1. 기록 비용 (SQL 컴파일 뮤텍스와 매번 다시 컴파일)**

후보는 다음 순서로 본다.

1. 워커마다 prepared statement 한 번: 워커가 시작할 때 INSERT를 한 번 컴파일해 두고, 커밋마다 값만 바꿔 실행한다. 컴파일이 커밋 경로에서 빠진다. 워커는 각자 sub-client를 가지므로 워커별로 준비할 수 있다(추정).
   - 확인할 것: 준비된 문장을 실행할 때도 parser 공유 상태를 건드리는지. 작은 측정으로 확인한다.
2. SQL 없이 객체 API(`db_create`, `obj_set`)로 넣기: parser를 거치지 않는다. class·MOP 조회 비용이 있다.
3. 데이터와 같은 복제 경로(`ws_add_to_repl_obj_list`)에 마커 INSERT를 얹기: 가장 싸지만 마커 클래스의 레코드 이미지를 직접 만들어야 한다.

9월 측정의 비중(평균 0.04%)으로 보면 1번으로 충분할 가능성이 높다(추정).

**1-1. 기록 비용 측정 결과 (2026-10-28 18:1x)**

- 조건: 빌드 `2931-574055e`(ON), youngjun3 로컬 DB `markerdb`, HA 없이 서버만. 실험 프로그램 `unit_tests/marker_bench`(미커밋, 옵션 `UNIT_TEST_MARKER_BENCH`).
- 스레드마다 sub-client를 열고, 트랜잭션마다 마커 한 행(출처, `commit_pageid`, `commit_offset`, 세 열 PK) INSERT 뒤 커밋. 스레드당 2,000행.
- compile: applier의 지금 방식(`db_execute_with_values`를 프로세스 전역 뮤텍스 안에서 매번). prepared: 스레드마다 한 번 컴파일하고 `db_execute_and_keep_statement`로 값만 바꿔 실행, 행마다 뮤텍스 없음.

| 방식 | 스레드 | INSERT 평균 | INSERT p99 | 초당 행 | 실패 |
|---|---|---|---|---|---|
| compile | 1 | 460us | 679us | 1,618 | 0 |
| compile | 10 | 4,801us | 5,931us | 1,469 | 0 |
| prepared | 1 | 81us | 149us | 3,539 | 0 |
| prepared | 10 | 126us | 292us | 10,309 | 0 |

- compile은 스레드를 늘려도 처리량이 그대로이고 한 번에 걸리는 시간이 10배가 된다. 뮤텍스 줄서기다. 10스레드 4.8ms는 9월 PoC 리뷰가 지적한 "4.8ms의 정체"와 같은 값이다.
- prepared는 10스레드에서도 126us로 거의 늘지 않고 처리량이 스레드 수만큼 는다. 컴파일만 뮤텍스 안에서 하고 실행은 뮤텍스 없이 2만 번 돌았는데 오류나 크래시가 없었다. 동시 실행이 안전하다는 증거이지 증명은 아니다.
- 커밋 시간(INSERT와 별개)은 로그 flush가 지배해 두 방식 모두 들쭉날쭉하다. 실제 적용에서는 마커가 워커의 데이터 트랜잭션에 얹히므로 커밋이 하나 더 생기지 않는다.
- 결론: 워커마다 prepared statement 한 번으로 기록 비용 문제는 풀린다.

**2. "이미 적용됨" 처리 위치 (확인함)**

- `la_coordinator_complete_without_task`로 coordinator에서 건너뛰는 방법은 쓰지 않는다. in-flight 목록에 들어가지 않아 retire를 거치지 않으므로 `committed_lsa` 진행, 통계 집계, 아이템 해제를 따로 챙겨야 한다.
- 워커가 건너뛰면 태스크는 평소처럼 큐에 들어가고, 링 등록, in-flight, retire, `committed_lsa` 진행, 통계, 아이템 해제가 모두 지금 경로대로 움직인다. dependency 대기도 그대로다. PoC도 `la_apply_repl_log`에서 건너뛰었다.
- 비용은 복구 구간의 커밋만큼 빈 태스크가 한 번씩 도는 것뿐이다.

**3. 정리의 안전성**

- 지우는 기준은 `committed_lsa`(frontier, 여기까지는 모두 적용됨)보다 앞선 마커다.
- 재시작하면 `required_lsa`부터 다시 읽어 `committed_lsa` 이하 커밋도 다시 보지만, 그것들은 기존 규칙("`committed_lsa` 이하는 이미 적용")으로 건너뛰므로 마커가 필요 없다.
- 지우기는 apply info 저장과 같은 트랜잭션에서 하므로 "위치는 앞으로 갔는데 마커는 없는" 순간이 생기지 않는다.

**4. 출처 구분과 역할 전환**

- 마커 행에 출처를 넣고 읽기·지우기·초기화 모두 출처 조건을 쓴다. 노드마다 applier가 따로 뜨는 구성(replica, 3노드)에서 다른 출처의 마커를 쓰지 않는다. Greptile 2차 지적 중 "statement marker가 출처를 구분하지 않는다"가 같이 풀린다.

**5. 빈 커밋 핑퐁**

- 적용 항목이 있는 커밋에만 마커를 넣는다. 9월에 applier 출신 커밋이 상대 노드로 빈 커밋으로 흘러가 되돌아오는 순환을 겪었고, 같은 규칙으로 막았다.

**6. 정리 DELETE와 워커 INSERT의 경합**

- 서로 다른 행이고, 지우는 쪽은 frontier보다 앞선 옛 행만 건드리므로 잠금 충돌은 없을 것으로 본다(추정). 인덱스 페이지 경합은 측정으로 확인한다.

## 적용·검증 계획

1. 재현 시험을 먼저 만든다. c17과 같은 방식으로 master에서 T1(INSERT)·T2(PK 변경 UPDATE)를 커밋하고, slave가 적용한 직후 apply info 저장 전에 applylogdb를 죽인다. 기대: 수정 전에는 slave에 키 1 행이 남고 fail_counter가 1 오른다.
2. 기록 비용 실험(prepared statement): 빌드는 사용자가 한다.
3. 조각별로 따로 커밋한다: 테이블과 기록, 시작 시 읽기와 건너뛰기, 정리, 복구 구간 장치 제거.
4. 재현 시험 재실행, 재시작·kill 회귀, 처리량 측정.

## Greptile 답글 안

- 3차 P1 `log_applier.c:7344`: 맞다. 이미 알고 있던 한계이고, 워커가 적용한 커밋을 데이터와 같은 트랜잭션에 기록하고 재시작 때 기록된 커밋을 건너뛰도록 고친다.
- 3차 P1 `log_applier.c:10235`(출처 구분), `log_applier.c:3491`(`max_committed_lsa` 열): 같은 수정에 묶인다.

## 상세 설계용 요약

- 병렬 applier의 재시작 정확성은 "적용 기록을 데이터와 같은 트랜잭션에 커밋"으로 얻는다. develop의 "데이터와 apply info를 한 트랜잭션에 커밋"을 워커 단위로 옮긴 것이다.
- 행 재적용이 같은 결과를 낸다는 가정은 PK·UNIQUE 변경 UPDATE에서 깨지므로, 복구 구간 오류 무시에 기대지 않는다.
