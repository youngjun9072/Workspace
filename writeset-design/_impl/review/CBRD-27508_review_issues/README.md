# CBRD-27508 리뷰 이슈 처리

> [!NOTE]
> **현재 상태 (2026-11-02, PR 브랜치 HEAD 8e3029e56 기준)**
> - C3: 브랜치 수정(db599ab64 → 현재 b9be48cf8)은 11-01 develop 병합에서 develop CBRD-27034로 대체됐다. 지금은 develop 동작으로 처리된다(C3 문서 머리 참고).
> - 아래 표의 커밋 해시는 10-28 이력 정리 전 해시다. 현재 해시는 각 이슈 문서 머리의 상태 줄을 본다.


브랜치 리뷰(`../CBRD-27508_branch_review_20261020/00_종합_교차검증.md`)에서 나온 묶음(C1~C16)을 이슈 하나당 파일 하나로 정리한다.

- 대상 브랜치: `feature/CBRD-27508-on-26779`, 리뷰 기준 HEAD `0e411f10f` (기준선 `a9a0dc78d`)
- 저장소: `/home/youngjun/Workspace/cubrid-applier`

## 이슈 목록

| ID | 제목 | 등급 | 상태 |
|---|---|---|---|
| [C1](C1_master_restart_floor_gate_stall.md) | master 재시작 경계가 slave commit-order ring에 없어서 첫 라벨 커밋이 영구 대기 | High → 방어 코드 | 수정 `ac9aa4bf7`(안 A'), 단위 테스트 통과. HA 시험 2회 모두 MASKED(재시작 직후 applylogdb의 apply info 커밋이 정지 조건을 가림, 10-23 확인). 방어 코드로 유지 |
| [C2](C2_overflow_label_missing_history_floor.md) | commit-order 대체 경로의 라벨에 history_start 하한이 빠짐 | High | 수정 `ae19759c4`, 단위 테스트 통과. **HA 검증 통과(10-23)**: 재시작 직후 DDL 라벨 = R(NULL 아님), slave에서 DDL → INSERT 순서 유지 |
| [C3](C3_fk_check_committing_inserter.md) | 자식 INSERT의 FK 검사가 커밋 도중인 부모 inserter를 기다리지 않아 slave에서 자식 행이 사라짐 | High | 수정 커밋 `db599ab64`(1차·보완 접음), 런타임 검증과 회귀(unique, fk_multi, F1, F4) 통과 |
| [C11](C11_partitioned_parent_fk_key_mismatch.md) | 분할 부모 FK에서 자식 REF 키와 부모 WRITE 키가 맞지 않아 slave에서 자식 행이 사라짐 | High | 수정 커밋 `4ed4a84d0`(REF 키를 분할 기준으로). HA 검증 통과(missed 500→0), 회귀(C3 조건, fk_multi) 통과 |
| [C9](C9_serial_sysop_reapply_after_restart.md) | 재시작 뒤 serial 조각을 다시 적용해 slave serial 값이 되돌아갈 수 있다는 지적 | 기각 후보 | 재현 시도 2회(10-22, 10-23), 문제 나타나지 않음. 재시작 때 committed_lsa가 required_lsa로 돌아가 skip 분기에 가지 않음(로그 확인) |
| [C6](C6_failover_drain_backstop_never_runs.md) | failover 때 DONE 보류를 끊는 30초 재시작 백스톱이 실행되지 않음 | Low (정리 대상) | **백스톱 제거** `a361cca24`(10-23). 재현(10-22): DONE 보류 237초는 정상 동작(develop과 같음), 백스톱 0건. C5 수정 뒤 백스톱 조건이 성립할 수 있어 제거. 제거 후 failover 회귀 PASS(238초 승격, 데이터 일치). 교착 희생 처리 확인: 수정 없음 |
| [C4](C4_coordinator_result_wait_ignores_shutdown.md) | worker가 모두 빠지면 coordinator가 결과를 무기한 기다리고 종료 요청도 보지 않음 | High | 수정 커밋 `6ae74828a`. 재현(10-22, 시험 훅으로 재현 뒤 훅은 뺌): 수정 전 HANG·SIGTERM 무시, 수정 후 같은 조건에서 바로 종료 |
| [C5](C5_dbname_lock_taken_once.md) | dbname lock을 applier 시작할 때 한 번만 잡고 다시 잡지 않음 | High | **수정 완료** `bf8533de3`(10-22). 수정 전 3노드 실측(replica·3노드 slave): ① 시작 단계 대기·SIGTERM 무시, ② 잠금 없이 적용. 수정 후 3노드 slave: 단계마다 적용하는 applier가 소유자, 시작 대기 없음, 데이터 일치 |
| [C7](C7_ha_apply_info_columns_no_migration.md) | `_db_ha_apply_info` 새 컬럼에 마이그레이션이 없음 | 정책 판단(수정 안 함) | 판정(10-23): 하위 버전 포팅 없음 → 버전 업그레이드 절차에 맡김. 같은 버전 DB에서는 생기지 않음. C17 표시 테이블은 applier가 직접 만들어 해당 없음 |
| [C8](C8_log_record_type_53.md) | 새 로그 레코드 타입 53이 구 바이너리의 상한값과 같음 | 정책 판단(수정 안 함) | 판정(10-23): 버전이 다른 노드를 섞은 HA는 고려하지 않음 |
| [C10](C10_total_rows_not_updated.md) | worker가 적용한 행 수를 `la_Info.total_rows`에 더하지 않아 주기 저장이 꺼짐 | Low | 수정 커밋 `05d170365`(develop 동작 복원). 실제 영향 거의 없음: HA 서버 상태 레코드(1초마다)가 apply info를 저장함. 회귀 확인(10-23) |
| [C12](C12_wset_label_read_failure.md) | writeset 라벨을 읽지 못하면 "의존 없음"으로 처리함 | Medium | 수정 커밋 `caa9d33f1`(읽지 못한 라벨은 다시 읽음). 실패 상황은 훅 없이 재현 불가, 회귀 확인(10-23) |
| [C13](C13_sql_log_race.md) | SQL 로그를 worker 여럿이 잠금 없이 같이 씀 | Medium | 수정 커밋 `2d306757f`(쓰기 mutex). 시험 통과(10-23): 8×5000행, 1MB 교체 6번, 항목·번호 이상 0 |
| [C16](C16_vsz_memory_check_false_positive.md) | worker가 여럿이면 VSZ 메모리 검사가 놀고 있는 applier를 종료시킴 | Medium | 수정 커밋 `882308890`(기준을 worker 시작 뒤에 잼). 시험 통과(10-23): 500MB 설정, VSZ 905MB에서 종료 안 됨 |
| [C14](C14_serial_sysop_global_barrier.md) | serial·AUTO_INCREMENT sysop마다 slave에 전역 장벽이 생김 | 설계(이번 프로젝트 제외) | 최적화 과제로 이관(10-23). 1회 측정: 백로그 20000건 PK 2.6초, AUTO_INCREMENT(캐시 20) 7.7초, serial NOCACHE 38.5초 |
| [C15](C15_multi_conn_build_scope.md) | `MULTI_CONN_TO_A_SERVER`가 전체 빌드에 켜짐 | 판단 필요(CS팀 협의) | 이 브랜치 커밋 `cb0095bf2`가 켬(기반 브랜치는 꺼져 있음). 병렬 applier에는 필요, 켜는 범위(전체 빌드 vs applylogdb 전용)를 CS팀과 정해야 함 |
| [C17](C17_recovery_range_statement_reapply.md) | 재시작 recovery range에서 이미 적용한 statement(DDL)를 다시 실행해 실패로 기록 | High | 수정 커밋 `74acb3ea8`(statement 적용 표시 테이블). HA 검증 통과(재실행 0, 불일치 0), 회귀 통과 |

## 수정 커밋 (접지 않음)
리뷰에서 나온 결함을 고친 커밋은 원래 기능 커밋에 접지 않고 이슈마다 별도 커밋으로 남긴다(10-23 결정). 리뷰에서 오류가 발견되어 예외 처리를 넣었다는 이력이 커밋 단위로 남아야 하기 때문이다.

| 커밋 | 이슈 | 내용 |
|---|---|---|
| `ac9aa4bf7` | C1 | slave: 마지막으로 읽은 커밋보다 높은 라벨을 그 커밋으로 낮춤 (방어 코드) |
| `ae19759c4` | C2 | master: commit-order 대체 라벨을 history 하한까지 올림 |
| `db599ab64` | C3 | master: FK 검사가 커밋 중인 inserter의 키를 만나면 그 커밋을 기다림 |
| `4ed4a84d0` | C11 | master: 분할 부모를 가리키는 참조 키는 그 키를 가진 분할로 지정 |
| `74acb3ea8` | C17 | slave: 재시작 뒤 statement 트랜잭션을 두 번 적용하지 않음 |
| `6ae74828a` | C4 | slave: applier 종료 요청이 오면 coordinator가 결과 대기를 멈춤 |
| `bf8533de3` | C5 | slave: dbname lock을 쓰는 작업마다 잡음 |
| `a361cca24` | C6 | slave: failover drain 30초 백스톱 제거 |
| `05d170365` | C10 | slave: 마지막 retire 뒤에도 메인 루프가 apply info를 저장 |
| `caa9d33f1` | C12 | slave: 읽지 못한 writeset 라벨은 의존 없음으로 쓰지 않고 다시 읽음 |
| `2d306757f` | C13 | slave: SQL 로그를 worker 하나씩 씀 |
| `882308890` | C16 | slave: 메모리 검사 기준을 worker 시작 뒤에 잼 |

- 그 전에 접은 것(C1·C2의 재현 커밋, C3의 1차·보완 커밋, C4의 시험 훅)은 접기 전 상태가 백업 브랜치 `backup/c1c2-before-fold-20261021`, `backup/c3-before-fold-20261021`, `backup/c4-before-fold-20261022`, `backup/c4-with-hooks-20261022`에 남아 있다. C4 시험 훅은 다시 필요할 때 `backup/c4-with-hooks-20261022`에서 가져온다.

## 이슈 파일 구성
1. 메타 (등급, 상태, 판정, 신규/기존, 원인 커밋, 관련 이슈, 지적한 리뷰어)
2. 문제 요약
3. 문제 분석 (코드 근거 `파일:행`)
4. 발생 조건과 재현 방법
5. 기대 결과
6. 실제 결과 / 예상 에러
7. 해결 방법 (안 비교, 권장안)
8. 의사코드
9. 검증 방법 (단위 테스트, HA 시험)
10. 영향 범위와 위험
11. 열린 질문
