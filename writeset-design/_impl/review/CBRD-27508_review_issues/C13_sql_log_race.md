# C13. SQL 로그를 worker 여럿이 잠금 없이 같이 씀

## 1. 메타
| 항목 | 내용 |
|---|---|
| 등급 | Medium |
| 상태 | 수정 커밋 `2d306757f`(10-23). 빌드 2786-8823088에서 수정 후 시험 통과(6절). 수정 전 섞임은 재현하지 않음 |
| 판정 | 코드로 확정. `ha_enable_sql_logging=yes`일 때만 생김(기본값 no) |
| 신규/기존 | 기존 코드 + 병렬화로 노출. develop은 applier가 스레드 하나라 문제가 없었다 |
| 지적한 리뷰어 | 2명(종합 문서 2절) |
| 코드 기준 | `882308890` |

## 2. SQL 로그
- slave applier가 적용한 변경을 SQL 문장으로 파일에 남기는 기능이다. 데이터 검증과 진단에 쓴다. 파라미터 `ha_enable_sql_logging`.
- 항목 하나는 머리줄 `-- 시각 | 번호 | select 길이 | 문장 길이`, 검증용 `-- select ...` 줄, 문장 줄로 이루어진다.
- 파일이 `ha_sql_log_max_size_in_mbytes`를 넘으면 다음 번호 파일로 넘어가고, `ha_sql_log_max_count`개를 넘는 오래된 파일은 지운다. 현재 파일 번호와 마지막 항목 번호는 카탈로그 파일(`*_applylogdb.sql.info`)에 적는다.

## 3. 문제 (수정 전)
`src/transaction/log_applier_sql_log.c`의 상태는 모두 파일 전역이고 잠금이 없다.
```c
static FILE *log_fp;                      // 지금 쓰는 SQL 로그 파일
static FILE *catalog_fp;                  // 카탈로그 파일
SL_INFO sl_Info;                          // curr_file_id, last_inserted_sql_id
```
`sl_init` 뒤에 이 상태를 건드리는 곳은 `sl_write_sql` 하나다.
```c
  fprintf (log_fp, "-- %s | %u | ...", time_buf, ++sl_Info.last_inserted_sql_id, ...);   // 머리줄 + 번호 증가
  fwrite (select ...);  fwrite (query ...);                                              // 여러 번에 나눠 씀
  fflush (log_fp);
  sl_write_catalog ();                                                                   // 카탈로그 갱신
  if (ftell (log_fp) >= SL_LOG_FILE_MAX_SIZE)
    log_fp = sl_open_next_file (log_fp);                                                 // fclose(옛 파일) → fopen(새 파일)
```
`sl_write_insert_sql`, `sl_write_update_sql`, `sl_write_delete_sql`, `sl_write_statement_sql`이 모두 `sl_write_sql`로 쓴다. 이 함수들은 `la_apply_insert_log`(`log_applier.c:6674`), `la_apply_update_log`(`:6450`), `la_apply_delete_log`(`:6361`), `la_apply_statement_log`(`:7043`)에서 불리고, 이 함수들은 worker 스레드에서 돈다.

## 4. 예시
worker 1과 worker 2가 거의 동시에 INSERT를 한 건씩 적용한다.
1. **항목이 섞임**: `-- 머리1`, `-- 머리2`, `INSERT 1`, `INSERT 2` 순서로 들어가 어느 머리줄이 어느 문장인지 알 수 없다.
2. **번호가 겹침**: `++last_inserted_sql_id`가 원자적이지 않아 두 항목이 같은 번호를 받을 수 있다.
3. **닫힌 파일에 씀**: worker 1이 파일을 넘기며 `fclose`한 순간 worker 2가 옛 `log_fp`로 `fwrite`하면 해제된 FILE을 쓴다. 프로세스가 죽을 수 있다(추정).
4. **카탈로그 파일 깨짐**: 두 worker가 동시에 `sl_write_catalog`로 덮어쓴다.

## 5. 수정 (`2d306757f`)
`sl_write_sql` 전체를 mutex로 감쌌다.
```c
/* log_applier_sql_log.c:71 */
/* the workers write SQL log entries concurrently; one entry, the catalog update and the file switch are done
 * under this lock so that entries do not interleave and no worker writes to a file another one has closed */
static pthread_mutex_t sl_write_mutex = PTHREAD_MUTEX_INITIALIZER;

/* :525 */
static int
sl_write_sql (string_buffer & query, string_buffer * select)
{
  int error;

  pthread_mutex_lock (&sl_write_mutex);
  error = sl_write_sql_locked (query, select);       /* 기존 본문 (:537) */
  pthread_mutex_unlock (&sl_write_mutex);

  return error;
}
```
- 본문 중간의 `return ER_FAILED;`로 빠져도 잠금이 풀리도록 본문을 `sl_write_sql_locked`로 옮겼다.
- 문장을 만드는 부분은 각자의 지역 버퍼라 잠그지 않는다. `sl_init`은 worker를 띄우기 전에 coordinator가 한 번 부르므로 그대로 둔다.
- 비용: SQL 로그를 켰을 때만 worker들이 이 잠금에서 줄을 선다. 꺼져 있으면 `sl_write_sql`에 들어오지 않는다.
- SQL 로그의 항목 순서는 실제로 적용된 순서이고, master의 커밋 순서와 다를 수 있다. 병렬 적용의 성질이라 바꾸지 않았다.

## 6. 시험 (10-23 15:18, 빌드 2786-8823088)
- conf: `cubrid_ha.conf.c13_c16`(md5 `5b67ebe1`) = 기준 ea141281 + `ha_enable_sql_logging=yes` + `ha_sql_log_max_size_in_mbytes=1`(최솟값, 파일을 자주 넘기게) + `ha_apply_max_mem_size=500`(C16 시험).
- 하니스 `ha_bench_tool/bin/c13_sql_log.sh`: master에서 8세션이 각 5000행을 동시에 INSERT(행마다 커밋). slave가 다 받은 뒤 남은 SQL 로그 파일을 검사한다. 항목마다 머리줄 형식, select 줄과 문장 줄의 길이가 머리줄 값과 같은지, 파일 안 번호가 1부터 빠짐없이 이어지는지, 같은 키의 INSERT가 두 번 있는지 본다.
- 검사기 확인: 정상 파일에서 한 줄을 지운 사본에 돌려 문제 4건을 잡는 것을 먼저 확인했다.

| 항목 | 결과 |
|---|---|
| 행 | master 40000 / slave 40000 |
| worker 사용 | 10개 모두 약 4000건씩 적용(동시 쓰기가 실제로 일어남) |
| 파일 교체 | 6번 (`.0`~`.6`, `ha_sql_log_max_count` 기본 2개만 남음) |
| `.5` | 항목 6175, 번호 1..6175, 문제 0 |
| `.6` | 항목 3300, 번호 1..3300, 문제 0 |
| applier | pid 그대로(재시작 없음), fail_counter 0 |

- 결과 디렉터리: `ha_bench_tool/log/c13_sql_log_20261023_151848/`
- 시험 뒤 conf는 기준(ea141281)으로 되돌렸다.

## 7. 열린 질문
1. 수정 전 빌드로 같은 시험을 돌려 섞임이나 비정상 종료가 실제로 나는지는 보지 않았다.
