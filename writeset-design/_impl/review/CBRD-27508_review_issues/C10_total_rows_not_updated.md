# C10. worker가 적용한 행 수를 `la_Info.total_rows`에 더하지 않아 주기 저장이 꺼짐

## 1. 메타
| 항목 | 내용 |
|---|---|
| 등급 | 종합 문서 Medium → **Low** (결함은 확정, 실제 영향은 거의 없음, 5절) |
| 상태 | 수정 커밋 `05d170365`(10-23). 빌드 2786-8823088에서 회귀 확인. 수정 효과를 드러내는 시험은 만들지 못함(6절) |
| 판정 | 갱신 누락은 코드로 확정. 다른 저장 경로가 같은 일을 하므로 영향은 거의 없음 |
| 신규/기존 | 신규. 원인 커밋 `45825ca17`(slave 병렬 applylogdb) |
| 관련 | [C17](C17_recovery_range_statement_reapply.md)(10-20의 statement 재실행. 그 재실행은 C17이 막았다) |
| 지적한 리뷰어 | 1명(종합 문서 2절) |
| 코드 기준 | `882308890` |

## 2. 용어
- **apply info**: slave DB의 `_db_ha_apply_info`에 저장하는 "여기까지 적용했다"는 위치(committed_lsa 등). applier가 재시작하면 이 위치부터 다시 읽는다. 아카이브 로그를 지우는 기준도 된다.
- **retire**: coordinator가 worker의 결과를 받아 "이 트랜잭션은 끝났다"고 처리하는 단계.

## 3. 문제
apply info를 저장하는 곳은 세 군데다.

| 저장하는 곳 | 조건 | 출처 |
|---|---|---|
| ① retire할 때 (`la_coordinator_store_apply_info_at_interval`, `log_applier.c:1310`) | 지난 저장 뒤 `ha_applylogdb_max_commit_interval_in_msecs`(기본 500ms)가 지났을 때 | 브랜치 |
| ② 메인 루프의 주기 확인 (`la_check_time_commit`, `:8488`) | `la_Info.prev_total_rows != la_Info.total_rows`, 즉 적용한 행 수가 늘었을 때 | develop |
| ③ HA 서버 상태 레코드를 읽을 때 (`la_log_record_process`, `:8013`) | 적용할 목록이 비어 있을 때 `la_log_commit (true)` | develop |

②가 동작하지 않았다.
- develop은 `la_apply_repl_log (..., &la_Info.total_rows, ...)`로 전역 값을 직접 올렸다.
- 브랜치 worker는 지역 변수에만 더했다(`la_apply_worker_run_task`의 `int total_rows = 0;`). 전역 `la_Info.total_rows`는 아무도 올리지 않았다.
- 그래서 ②의 조건은 늘 거짓이었다.

## 4. 예시
master에서 T1, T2를 연달아 커밋하고 그 뒤 쓰기가 없다고 하자.
1. T1이 retire된다. 500ms가 지났으므로 ①이 T1까지 저장한다.
2. 200ms 뒤 T2가 retire된다. 500ms가 안 지났으므로 ①은 저장하지 않는다.
3. 그 뒤 retire가 없으므로 ①은 다시 불리지 않고, ②는 조건이 거짓이다.
4. ③이 없다면 apply info는 T1에 머물고, 이때 재시작하면 T2를 다시 적용한다.

## 5. 실제 영향
- ③ 때문에 꼬리는 1~2초 안에 저장된다. master는 `LOG_DUMMY_HA_SERVER_STATE`를 1초마다 남기고(`flashback.c:350` 주석), slave는 적용할 것이 없을 때 이 레코드를 읽으면 apply info를 저장한다. 실측에서도 쓰기가 없는데 slave의 final_lsa가 2초마다 96바이트씩 늘었다.
- 2노드 상호 구성에서는 양쪽 applier가 apply info를 저장한 빈 커밋을 서로 주고받는다(핑퐁, items=0). 이 빈 커밋도 retire를 일으키므로 ①도 계속 저장한다.
- 그래서 master가 살아 있는 한 꼬리가 오래 남지 않는다. master가 죽으면 상대 DEAD 경로(`:10219`)가 저장한다.
- 10-20의 "1초 전에 적용한 CREATE TABLE이 재시작 뒤 다시 실행됨"은 적용 1초 안에 재시작한 경우였다. ③의 주기보다 짧아서, C10을 고쳐도 막히지 않는다. statement 재실행 자체는 C17이 막았다.

## 6. 수정 (`05d170365`)
develop과 같은 동작으로 되돌렸다.
```c
/* applier/log_applier_result.hpp, struct la_result */
+ int total_rows;   /* items the worker went through, as the serial applier counted them; summed into
+                    * la_Info.total_rows at retire, where a change makes the main loop store the apply info */

/* log_applier.c:1364, la_apply_worker_run_task */
+ result->total_rows = total_rows;

/* log_applier.c:1231, la_coordinator_add_result_stats */
+ la_Info.total_rows += result->total_rows;
```
- 상대가 apply info를 저장한 빈 커밋은 항목이 없어 `total_rows`가 늘지 않는다. 그래서 핑퐁이 ②를 더 자주 부르지는 않는다.

## 7. 시험 (10-23, 빌드 2786-8823088)
하니스 `ha_bench_tool/bin/c10_apply_info_tail.sh`: master에 INSERT 5건을 연달아 커밋하고 30초 동안 slave의 저장값과 마지막 retire 위치를 1초마다 비교한다.

| 런 | 빌드 | 조건 | 결과 |
|---|---|---|---|
| `c10_apply_info_tail_20261023_110749` | 2782-a361cca (수정 전) | 2노드 그대로 (빈 커밋 28개) | 1초 안에 꼬리 저장 |
| `c10_apply_info_tail_20261023_150822` | 2786-8823088 (수정 후) | youngjun3 applylogdb를 내려 핑퐁을 끊음 (빈 커밋 0개) | 1초 안에 꼬리(`173\|4368`) 저장 |

- 두 런 모두 저장됐지만 수정 효과를 보인 것은 아니다. 수정 전에도 ③이 저장하기 때문이다(5절). ③을 끊으려면 master의 HA 서버 상태 레코드가 멈춰야 하는데, 그것은 master가 죽은 상황이고 그때는 다른 경로가 저장한다.
- 행 수는 양쪽 5건, fail_counter 0.

## 8. 열린 질문
1. 없음. 수정은 develop과 같은 동작을 되돌린 것으로 두고 닫는다.
