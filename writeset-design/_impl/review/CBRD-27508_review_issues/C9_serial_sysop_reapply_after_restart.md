# C9. 재시작 뒤 serial(AUTO_INCREMENT) 조각을 다시 적용해 slave의 serial 값이 되돌아갈 수 있다는 지적

## 1. 메타
| 항목 | 내용 |
|---|---|
| 등급 | 종합 문서 High → **기각 후보** |
| 상태 | HA 재현 시도 2회 모두 문제가 나타나지 않음(10-22, 10-23). 리뷰가 가정한 경로(SYSOP_END가 skip 분기로 감)는 재시작 직후에 일어나지 않는다는 것을 실제 로그로 확인했다. 수정 안 함 |
| 판정 | 코드 경로는 있으나 재시작 상황에서 도달하지 않음(로그 확인). skip 분기에 도달하는 다른 경우는 찾지 못함(추정) |
| 신규/기존 | 리뷰 지적 대상은 신규 코드(`45825ca17`이 develop의 항목별 필터를 없앰) |
| 관련 | [C17](C17_recovery_range_statement_reapply.md)(같은 필터 제거에서 나온 지적. C17은 실제 결함) |
| 지적한 리뷰어 | 1명: appdev_3y E1(High, "재시작 후 committed_lsa 이하 serial fragment가 다시 적용됨"). 같은 skip 분기에서 라벨 보관을 비우지 않는다는 점은 architect_3y E5(Medium), qa_1y E-3(Low)도 지적했다 |

## 2. 용어와 예시
- **X**: AUTO_INCREMENT 테이블 `c9_t`에 한 행을 넣고, 커밋하지 않은 채 열려 있는 긴 트랜잭션.
- **serial 조각**: AUTO_INCREMENT 값을 올리는 serial 갱신. X 안에서 일어나지만 X와 따로 커밋된다(3절). slave의 이 브랜치는 이것을 X에서 떼어 내 별도 작업(조각)으로 먼저 적용한다.
- **committed_lsa**: slave applier가 메모리에 들고 있는 "여기까지 적용됨" 위치. 저장된 값(apply info)과 구분한다.

## 3. 로그 배치: serial 갱신은 X 안에 기록되고, X와 따로 커밋된다
master 로그(모두 X의 trid):
```
LSA  90  X: INSERT c9_t 행                       prev ← X의 이전 기록
LSA  95  X: _db_serial 갱신 (sysop 안)            prev ← 90
LSA 100  X: SYSOP_END                            lastparent_lsa = 90   ← sysop이 시작되기 직전 위치
...      (다른 트랜잭션들)
LSA 500  X: COMMIT (또는 ABORT)
```
- 기록은 일어난 순서대로 X의 로그 안에 남는다. 포인터를 옮겨 다른 곳에 쓰지 않는다.
- SYSOP_END에는 `lastparent_lsa`(`log_record.hpp:318`)가 들어 있다. X가 롤백되면 기록을 뒤에서부터 되돌리다가 SYSOP_END를 만나 `lastparent_lsa`(90)로 건너뛴다. 그래서 LSA 95의 serial 갱신은 되돌려지지 않는다. 즉 serial 갱신의 커밋은 X의 결과와 상관없이 SYSOP_END에서 확정된다.
- slave applier는 trid별로 항목을 모으므로 LSA 90과 95가 모두 X의 목록에 쌓인다. LSA 100의 SYSOP_END를 만나면 이 브랜치는 X의 목록에서 serial 항목(95)만 떼어 내 조각으로 먼저 적용하고(`la_coordinator_process_sysop_end` → `la_detach_sysop_fragment`), X의 목록에는 행(90)만 남는다.

## 4. 리뷰가 지적한 경로 (코드 `74acb3ea8`, `log_applier.c`)
```c
7610  la_coordinator_process_sysop_end (LOG_RECORD_HEADER * lrec, LOG_LSA * final)
7614    if (LSA_GT (final, &la_Info.committed_lsa))
          {
7620        LA_APPLY *fragment = la_detach_sysop_fragment (sysop_apply, final);   // 정상 분기: 조각을 떼어 냄
            ...
          }
        else
          {
            /* skip 분기: trace만 남기고 끝 */                                  // ★ 조각을 떼어 내지 않음, 라벨 보관도 비우지 않음
          }
```
- develop은 항목마다 `item->lsa > last_committed_rep_lsa`일 때만 적용했다(develop `log_applier.c:5799`). 이 브랜치는 이 필터를 없앴다.
- 리뷰의 우려: skip 분기로 가면 serial 항목이 X의 목록에 남고, X가 커밋될 때 다시 적용된다.

## 5. 재시작 타임라인

### 5.1 리뷰가 가정한 순서 (실제로는 일어나지 않음)
| 시각 | master | slave |
|---|---|---|
| t0 | X 시작, `INSERT c9_t` → serial 1 (SYSOP_END, LSA 100) | 조각을 떼어 적용 → serial 1 |
| t1 | 다른 세션 INSERT 100건 → serial 101 | 적용 → serial 101, committed_lsa가 LSA 100을 넘음 |
| t2 | (X는 열려 있음) | applier 재시작 |
| t3 | | X가 열려 있으므로 X의 처음(required_lsa)부터 다시 읽어 X의 목록을 다시 만듦. serial 항목도 다시 들어감 |
| t4 | | LSA 100의 SYSOP_END를 다시 만남. committed_lsa 이하라 **skip 분기**로 감 → serial 항목이 X 목록에 남음 |
| t5 | X 커밋 (LSA 500) | X를 적용하면서 serial 항목도 적용 → serial이 **1로 되돌아감** |

### 5.2 실제 순서 (10-22 09:51 재현, 실제 LSA)
X = trid 283348. X의 serial 조각 SYSOP_END = 813168\|2840, X의 COMMIT = 813173\|11048.

| 단계 | slave 로그 | 의미 |
|---|---|---|
| 1. 다른 세션 INSERT 100건 | master SYSOP 6건(serial 캐시 20 단위로 갱신) | slave가 모두 적용. 저장된 committed = 813172\|11944 |
| 2. slave applier kill → 재시작 | `unregistered → recovering, last committed LSA: 813168|2528` | X가 열려 있으므로 X의 시작(required_lsa 813168\|2528)부터 다시 읽는다. **이때 메모리의 committed_lsa도 이 값으로 설정된다**(`la_apply_log_file`: `LSA_COPY (&la_Info.committed_lsa, &la_Info.required_lsa)`) |
| 3. X의 SYSOP_END 813168\|2840을 다시 만남 | `[WSET] SYSOP slave fragment assemble trid=283348 sysop_lsa=813168|2840` | 2840 > 2528이라 **skip 분기가 아니라 정상 분기**로 간다. 조각을 X의 목록에서 떼어 낸다 |
| 4. 떼어 낸 조각 적용 | `reader retire trid=283348 commit_lsa=813168|2840 type=20` | 813168\|2840 ≤ 저장된 committed(813172\|11944)라서 worker가 "이미 적용됨"으로 통째로 건너뛴다 |
| 5. X 커밋 | `reader commit trid=283348 commit_lsa=813173|11048 items=1` | X의 목록에는 **행 1개만** 남아 있다. serial 항목은 다시 적용되지 않는다 |

5.1의 t4가 틀렸다. 재시작하면 메모리의 committed_lsa가 required_lsa로 돌아가므로, 다시 읽는 X의 SYSOP_END는 항상 그보다 뒤에 있어 정상 분기를 탄다.

## 6. 재현

### 6.1 방법 (`ha_bench_tool/bin/c9_serial_reapply.sh`)
1. master: `CREATE TABLE c9_t (id INT AUTO_INCREMENT PRIMARY KEY, v INT)`
2. 세션 X(autocommit off): `INSERT INTO c9_t (v) VALUES (-1)` 후 60초 동안 커밋하지 않음
3. 다른 세션(autocommit): INSERT 100건
4. slave가 모두 적용한 뒤 slave applylogdb를 한 번 kill(-9). heartbeat가 다시 띄운다. failover는 하지 않는다.
5. X 커밋. 이어서 master에서 한 건 더 INSERT
6. 양쪽 serial 값(`_db_serial.current_val`)과 행을 비교

### 6.2 결과 (10-22 09:51, 빌드 2779-74acb3e)
| 항목 | master | slave |
|---|---|---|
| `c9_t_ai_id` current_val | 120 | **120** |
| c9_t 행 수, max(id) | 102, 102 | 102, 102 |
| fail_counter 증가 | | 0 |
| 재시작 뒤 worker 오류 | | 0 |

- serial 값 120은 serial 캐시(20 단위)로 미리 올라간 값이다. 양쪽이 같다.
- 결과 디렉터리: `ha_bench_tool/log/c9_serial_reapply_20261022_095143/`
- 하니스의 serial 조회(`db_serial where name like '%c9_t%'`)는 빈 값을 돌려줬다. 위 값은 `_db_serial`을 직접 조회한 것이다. 하니스를 고쳐야 한다.

### 6.3 2회째 (10-23 15:12, 빌드 2786-8823088)
하니스의 serial 조회를 `_db_serial`로 고치고 같은 조건(N=100, HOLD_SECS=60)으로 다시 돌렸다.

| 항목 | master | slave |
|---|---|---|
| 다른 세션 INSERT 뒤 serial / 행 | 120 / 100 | 120 / 100 (slave applylogdb 강제 종료 전) |
| X 커밋 뒤 행 수, max(id) | 101, 101 | 101, 101 |
| INSERT 하나 더 한 뒤 serial / 행 수, max(id) | 120 / 102, 102 | 120 / 102, 102 |
| fail_counter | | 0 → 0 |
| 재시작 뒤 worker 오류 | | 0 |

- 결과 디렉터리: `ha_bench_tool/log/c9_serial_reapply_20261023_151210/`

## 7. 판단과 남는 점
- **재시작 상황에서는 리뷰의 경로가 일어나지 않는다**(로그 확인). 5.2절 2단계 때문이다.
- **skip 분기에 도달하는 다른 경우는 찾지 못했다**(추정). 실행 중의 committed_lsa는 frontier를 따르고, frontier는 이미 읽은 커밋 위치를 넘지 않는다. 그래서 새로 읽는 SYSOP_END는 항상 그보다 뒤에 있다.
- 그래도 skip 분기는 조각을 떼어 내지 않고 라벨 보관도 비우지 않는다. 앞으로 committed_lsa를 다루는 방식이 바뀌면 문제가 될 수 있다. 고칠 필요가 생기면 skip 분기에서도 `la_detach_sysop_fragment`로 떼어 내 버리고 라벨 보관을 비우면 된다.
- recovery range 안의 조각은 다시 적용되면서 serial이 잠깐 옛 값으로 돌아갈 수 있다. 하지만 구간의 뒤 조각들이 차례로 다시 적용되며 최종 값은 맞는다. 구간을 적용하는 도중에 failover가 나는 경우는 따로 보지 않았다.
- 재현 시도는 2회이고, 두 번 모두 문제가 나타나지 않았다. 긴 트랜잭션이 여럿이거나, X의 조각이 recovery range 안에 들어가는 조건은 시험하지 않았다.

## 8. 열린 질문
1. skip 분기에 실제로 도달하는 경로가 있는지(코드 전수 확인).
2. ~~하니스 `c9_serial_reapply.sh`의 serial 조회를 `_db_serial`로 고칠 것.~~ 고쳤다(10-23, 6.3절).
