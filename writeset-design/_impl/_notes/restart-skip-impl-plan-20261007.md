---
tags: [writeset, impl, slave, restart]
date: 2026-10-07
base: feature/CBRD-27508-parallel-applylogdb-writeset @1a611b4d5 (+ 작업트리 미커밋)
status: 구현 완료(컴파일 확인), 런타임 미검증
---

# 재시작 시 복구 구간 오류 skip 구현안

## 0. 이 문서가 답하는 것

재시작 뒤 홀이 있더라도 이전 실행이 슬레이브에 마지막으로 커밋했을 수 있는 위치까지 재적용 오류를 skip하는 방식을 정리한다. 설계 근거는 `_impl/02` §5·§6·§7이다. 같은 날 처음 쓴 완료 표식(B2 마커) 방식 초안은 이 방식으로 대체했다.

## 1. 방식

재시작은 영속된 `committed_lsa`부터 다시 읽는다. task는 `commit_lsa`에 따라 셋으로 나뉜다.

| 구간 | 처리 |
|---|---|
| `commit_lsa <= committed_lsa` | 전체 skip(기존 그대로) |
| `committed_lsa < commit_lsa <= max_committed_lsa` (복구 구간) | 다시 적용. INSERT unique 중복, UPDATE·DELETE 대상 행 없음 오류는 skip |
| `commit_lsa > max_committed_lsa` | 정상 적용, 정상 오류 처리 |

`max_committed_lsa`는 이전 실행이 슬레이브에 실제로 커밋했을 수 있는 task의 상한이다. 워커가 데이터와 같은 트랜잭션에서 자기 행에 기록하므로, 커밋된 task는 반드시 이 값 이하에 있다.

이 방식은 구간 안의 진짜 재적용 오류도 함께 skip한다. task별 반영 여부를 판정하지 않는 대신 받아들인 trade-off다.

## 2. 이전 방식과의 차이

| | 이전(PoC) | 지금 |
|---|---|---|
| 복구 구간 상한 | 저장된 `final_lsa`(reader 읽기 위치) | 워커 행 `max_committed_lsa` 최댓값 |
| 상한이 너무 큰 경우 | reader가 앞서 읽은, 적용하지 않은 task까지 구간에 포함 | 실제 커밋했을 수 있는 위치까지만 |
| 상한이 너무 작은 경우 | apply info 저장 뒤 워커가 커밋한 task가 구간 밖에 남아 dup 오류를 진짜 오류로 보고(`:3871` TODO) | 워커 커밋과 함께 기록되므로 발생하지 않음 |

완료 표식 방식은 쓰지 않는다. 표식 테이블, 부트 시 표식 로드, 표식 정리가 모두 필요 없다.

## 3. 저장 위치: `_db_ha_apply_info`에 워커 행 추가 (b1)

| 변경 | 내용 |
|---|---|
| 컬럼 추가 | `worker_id INTEGER DEFAULT -1 NOT NULL`, `max_committed_lsa_pageid BIGINT`, `max_committed_lsa_offset INTEGER` |
| UNIQUE | `(db_name, copied_log_path)` → `(db_name, copied_log_path, worker_id)` |
| reader 행 | `worker_id = -1`(`CT_HA_APPLY_INFO_READER_ID`). 기존 컬럼을 저장하며, 기존 INSERT는 기본값으로 -1이 들어간다 |
| 워커 행 | `worker_id = 0..`. `max_committed_lsa`만 의미가 있고, NOT NULL인 `committed_lsa`·`required_lsa` 컬럼에는 NULL LSA(-1, -1)를 넣는다 |

워커마다 자기 행만 갱신하므로 워커 사이에 행 경합이 없다. `_db_ha_apply_info`는 MVCC가 꺼진 클래스라 인덱스를 쓰지 않고 heap scan을 하는데, 조건을 먼저 평가한 뒤 조건에 맞는 행에만 X 락을 건다(`scan_manager.c` `scan_next_heap_scan`). 그래서 reader의 UPDATE와 워커의 UPDATE가 서로의 행 락을 기다리지 않는다.

## 4. 코드 변경

| 위치 | 변경 |
|---|---|
| `schema_system_catalog_constants.h` | `CT_HA_APPLY_INFO_READER_ID (-1)` |
| `schema_system_catalog_install.cpp` `get_ha_apply_info` | 컬럼 3개, UNIQUE 변경, `worker_id` NOT NULL |
| `log_applier.c` reader 쿼리 4곳 | `la_get_ha_apply_info`, `la_update_ha_apply_info_start_time`, `la_update_ha_apply_info_log_record_time`, `la_update_ha_last_applied_info`의 WHERE에 `worker_id = -1` |
| `la_get_ha_apply_worker_info` (신규) | 부트(`la_get_last_ha_applied_info`)에서 워커 행을 모두 읽어 워커별 값(`la_Info.worker_max_committed_lsa[]`)과 최댓값(`recovery_boundary_lsa`)을 채운다. 저장된 `final_lsa`를 복사하던 코드와 TODO는 삭제 |
| `la_update_ha_apply_worker_info` (신규) | 워커 행 UPDATE. 0건이면 `la_insert_ha_apply_worker_info`로 행을 만든다 |
| `la_apply_worker_commit_task` | 바뀐 행이 있고 `commit_lsa`가 워커의 현재 값보다 크면, `la_commit_transaction` 직전에 같은 트랜잭션에서 워커 행을 갱신한다. 커밋 성공 뒤 워커 메모리 값을 올린다 |
| 워커별 현재 값 | `la_Info.worker_max_committed_lsa[워커]`. 워커 스레드는 `la_get_last_ha_applied_info`보다 먼저 시작하므로 context에 복사하지 않고 이 칸을 직접 쓴다. 부트 로드는 첫 task 디스패치보다 앞서고, 이후 이 칸은 해당 워커만 쓴다. 그 값 이하의 커밋은 행을 다시 쓰지 않는다 |
| 복구 구간 판정·오류 skip | 그대로 사용(`la_apply_repl_log`, flush 오류 경로). 주석만 새 의미로 수정 |

"바뀐 행"의 기준은 `insert + update + delete + schema + recovery_skipped` 카운터 합이다. 복제 항목이 없는 커밋(HA 쌍의 빈 커밋 등)은 다시 적용해도 오류가 나지 않으므로 행을 쓰지 않는다.

이전 실행보다 워커 수가 줄어 남은 행도 최댓값 계산에 들어간다. failback(`la_delete_ha_apply_info`)과 restoreslave는 `(db_name, copied_log_path)` 조건으로 지우므로 워커 행도 함께 지워진다.

## 5. 확인한 것과 남은 것

확인:
- release `cubridcs`, `cubridsa` 빌드 통과(경고 없음). `log_applier.c`는 NDEBUG를 빼고 다시 컴파일해도 통과.
- 서버의 `catcls_get_apply_info_log_record_time`은 모든 행의 `log_record_time` 최댓값을 쓴다. 워커 행은 NULL이라 영향이 없다.
- restoreslave(`util_sa.c`)는 컬럼을 명시한 INSERT라 `worker_id` 기본값 -1로 reader 행이 만들어진다.

남은 것:
- **카탈로그 변경이라 DB를 다시 만들어야 한다.** 기존 DB의 업그레이드(migrate) 경로는 없다.
- `db_ha_apply_info` 뷰에 워커 행이 함께 보인다. 뷰에 `worker_id`, `max_committed_lsa` 컬럼을 추가할지, reader 행만 보이게 할지 결정이 필요하다. 지금은 손대지 않았다.
- 워커의 UPDATE는 `la_update_query_execute_with_values`를 거쳐 전역 `la_sql_compile_mutex` 안에서 compile·execute된다. 커밋할 때마다 짧은 직렬 구간이 생기므로 처리량 영향을 측정해야 한다. 값이 커질 때만 쓰므로 빈 커밋과 값이 작은 커밋은 비용이 없다.
- statement·DDL 복제는 `la_update_query_execute`에서 auto commit을 끈 상태로 실행된다. 서버 쪽 DDL 처리에 암묵 커밋이 있는지는 확인하지 않았다. 있으면 그 task는 데이터와 워커 행이 다른 트랜잭션에서 확정된다.
- statement·DDL의 재적용 오류 whitelist는 여전히 없다(`la_apply_statement_log` TODO).
- `la_reader_commit_apply_info`가 apply info 갱신 0건을 성공처럼 넘기는 경로(02 §7)는 이번 변경에 포함하지 않았다.

## 6. 검증 계획

- 정상: 워커 행이 워커 수만큼 생기고 `max_committed_lsa`가 커밋에 따라 올라가는지.
- 재시작: debug 빌드의 `CUBRID_HA_TEST_BLOCK_CLASS` 훅으로 한 워커를 커밋 직전에 멈추게 해 홀을 만든 뒤 applylogdb를 kill한다. 재시작 후 다음을 확인한다.
  - 복구 구간 상한이 워커 행 최댓값인지.
  - 구간 안의 dup 오류가 `recovery_skipped_counter`로 가고 `fail_counter`가 늘지 않는지.
  - 최종적으로 master와 slave가 같은지.
- failback: 워커 행이 함께 지워지는지.
- 성능: 10워커 커밋 처리량을 이전 빌드와 비교한다.
