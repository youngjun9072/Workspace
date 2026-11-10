# HA 병렬 applylogdb 테스트 — 이어받기

갱신: 2026-11-07 / 브랜치 `feature/CBRD-27508-parallel-applylogdb-writeset`

세션이 끊겨도 아래 환경은 전부 살아 있다. 새 세션에서 이 문서만 읽으면 이어갈 수 있다.

---

> **작업 내역 · 분석 내역 · 수정 방법을 한곳에 모은 요약은 `ha_work_log.md` 를 먼저 볼 것** (2026-11-08).

## 1. 결론 요약 (먼저 읽을 것)

1. **병렬화는 동작한다.** 워커 1→4 에서 3.74배, 1→10 에서 5.60배.
2. **그러나 실용 상한은 워커 4~10 이다.** 10→20 은 두 배를 넣고 10% 만 얻는다.
3. **주 병목은 applylogdb 가 아니라 슬레이브 cub_server 다.** 워커는 자기 코드를
   도는 시간이 거의 없고, 73~96% 를 `css_readn` — 서버 응답 대기 — 로 보낸다.
4. **고칠 가치가 있는 코드 결함 1건: `la_insert_applied_tx_marker` 가 파일 전역
   뮤텍스를 쥔 채 서버 왕복을 한다** (`log_applier.c:3807`). 워커 수에 대해 가장
   빠르게 악화되는 비용이며, 구조적으로 워커 수와 무관한 처리량 천장이기도 하다.
5. **메모리 누수 징후는 없다.** RSS 23~61 MB 로 안정. 다만 VSZ 는 워커당 약 76 MB
   씩 선형 증가한다 (32워커 환산 약 2.6 GB, 한도 `ha_apply_max_mem_size=4096`).
6. **같은 샘플 재분석(2026-11-07)으로 문제 5건 추가** — 5-1절. 코디네이터가 워커 10개부터
   유휴 0% (pending 큐 재스캔), 페이지 버퍼 전역 뮤텍스, 파킹 malloc, 게이트 정합성 TODO,
   trace 로그 뮤텍스(측정 환경 오염). 워커 락 대기 전체는 12.4% 가 아니라 18.9%.

---

## 2. 환경 (구축 완료, 재진행 불필요)

```
youngjun1 (192.168.4.121)  master   /home/youngjun/CUBRID_optdebug
youngjun2 (192.168.4.122)  slave    /home/youngjun/CUBRID_optdebug
```

- 빌드: `./build.sh -t 64 -m optdebug build` → `build_x86_64_optdebug/`
  (`-O2 -ggdb3 -DCUBRID_OPTDEBUG`, assert 켜짐, 심볼 포함)
- 양 노드 md5 동일. `~/.cubrid.sh` 가 새 설치본을 가리킴
  (구버전 복구: `cp ~/.cubrid.sh.pkg-2715 ~/.cubrid.sh`)
- `cubrid_ha.conf`: `ha_apply_worker_count=10`, `ha_apply_max_mem_size=4096`,
  `ha_writeset_trace_level=1`, `ha_port_id=59901`, `ha_db_list=testdb`
- DB `testdb` 양 노드 생성, HA 기동 완료, 복제 동작 확인됨
- 부하 테이블: `ha_t1` (10만행), `ha_t2`

HA 상태: `cubrid heartbeat status`

---

## 3. 스크립트

| 파일 | 용도 |
|---|---|
| `ha_load.sh` | 부하 생성기. `setup` / `A` / `B` / `C` / `D` / `clean` |
| `ha_pstack.sh` | pstack 반복 샘플러 + 프레임 집계 (양 노드 배치됨) |
| `ha_run_all.sh` | A·B 시나리오 비교. `./ha_run_all.sh 120 50 2 A B` |
| `ha_scale.sh` | 워커 확장성 — **실시간 복제 기준. 결과 무효, 4절 참조** |
| `ha_backlog.sh` | 워커 확장성 — **백로그 따라잡기 기준. 이게 유효한 측정이다** |

**pstack 대상은 슬레이브의 applylogdb.** `cub_admin applylogdb ... testdb_youngjun1`.
`applylogdb` 는 독립 바이너리가 아니라 `cub_admin` 의 서브커맨드다 (`util_cs.c:3379`) —
`pgrep` 이 아니라 `pgrep -f` 가 필요하다.

### ha_pstack.sh 에 추가된 모드 (2026-11-07)

- `STOP_FLAG=<경로>` — 그 파일이 생기면 남은 횟수와 무관하게 수집을 멈춘다.
  따라잡기처럼 **끝나는 시점을 모르는 구간**을 샘플링할 때 쓴다.
- `샘플수=0` — 수집하지 않고 **이미 모아둔 샘플만 집계**한다.
- 수집 중 `/proc/<pid>/status` 의 VmRSS/VmSize 를 `mem.txt` 에 같이 남긴다.

### applylogdb 만 따로 세우는 법 (백로그 실험의 핵심)

```bash
# 슬레이브에서. copylogdb 는 계속 돌아 로그가 쌓인다.
cubrid heartbeat applylogdb stop  testdb youngjun1
cubrid heartbeat applylogdb start testdb youngjun1
```

heartbeat 는 **명시적으로 멈춘 applylogdb 를 자동 재기동하지 않는다.**
워커 수는 applylogdb 가 기동할 때 직접 읽으므로 (`log_applier.c:8967`),
`cubrid_ha.conf` 만 고치고 applylogdb 만 재기동하면 된다 — heartbeat 전체를
내렸다 올릴 필요가 없다.

---

## 4. 측정 결과

### 4.1 1차 — 시나리오 A (무충돌), 유효

650 스레드-샘플 (50샘플 x 13스레드), 부하 57라운드 ≈ 11,400 트랜잭션 / 132초

```
40.31%  262  poll <- css_readn <- css_net_recv              워커 작업 중
34.77%  226  pthread_cond_wait <- la_task_queue_pop         워커 유휴
 7.69%   50  poll <- css_platform_independent_poll <- hb_process_master_request
 7.69%   50  read <- sigusr1_monitor_thread
 4.00%   26  pthread_cond_timedwait <- la_result_queue_wait_for_result
 4.00%   26  __lll_lock_wait <- pthread_mutex_lock <- la_insert_applied_tx_marker
```

### 4.2 1차 — 시나리오 B (고충돌), 측정 실패 → 부하 스크립트 수정

워커 75.54% 가 유휴로 나왔으나 슬롯 경합 때문이 아니었다. 마스터가 데드락으로
커밋을 못 해 보낼 로그가 없었다 (1,742초에 1,600 트랜잭션, 에러 1000건+).
**제품 버그가 아니라 부하 스크립트 결함.** 세션 8개가 핫키를 무작위 순서로 잠가
데드락 사이클이 생겼다.

조치: 트랜잭션 안의 키를 **오름차순 정렬**해 잠금 순서를 통일 (키 경합 자체는
남으므로 슬레이브 writeset 충돌은 유지), `HOT_KEYS` 50→500, `TXNS_PER_ROUND`
200→100, SQL 생성은 라운드마다 하지 않고 한 번만.
검증: 120라운드 / 12,000 트랜잭션 / 34초 / 에러 0.

### 4.3 3차 — `ha_scale.sh` 워커 확장성 (실시간 복제) — **결과 무효**

```
워커  처리량      워커 유휴  marker
1     214.4 tx/s   0.0%      0.0%
4     281.1 tx/s  28.6%      3.2%
10    134.6 tx/s  63.9%      1.5%
20    193.2 tx/s  65.0%      8.6%
```

처리량이 비단조(10워커가 1워커보다 나쁨)이고 확장성이 전혀 안 보였다.
당시 "marker 뮤텍스가 상한일 수 있다"고 해석했으나 **그 해석은 틀렸다.**

**무효 사유:** 워커가 63~65% 유휴였다. 마스터가 로그를 그만큼밖에 못 만들어
워커에게 줄 일이 없었던 것이다. 즉 이 측정이 잰 것은 applylogdb 의 처리 능력이
아니라 **마스터의 로그 생산 속도**다. 교란 요인을 제거한 것이 4.4 다.

### 4.4 4차 — `ha_backlog.sh` 백로그 따라잡기 — **유효. 이게 기준값이다**

방법: 슬레이브의 applylogdb 만 정지 → 마스터에 부하를 걸어 백로그 축적 →
copylogdb 수집 완료 대기 → applylogdb 기동 후 `db_ha_apply_info.commit_counter`
증분으로 따라잡기 속도 측정. 로그가 이미 슬레이브 디스크에 있으므로
**로그 도착 속도가 변수에서 제거된다.**

```bash
SETTLE=25 QUIET_POLLS=8 TRICKLE=15 MAX_CATCHUP=1500 BUILD_SCALE=1 \
  OUT=/home/youngjun/cbrd27508_perf/results/ha_backlog2 ./ha_backlog.sh 60 1 4 10 20
```

| 워커 | 백로그 | 측정구간 | tx/s | 배속 | 효율 |
|---|---|---|---|---|---|
| 1 | 29,329 | 201초 | **137.7** | 1.00× | 100% |
| 4 | 79,480 | 126초 | **514.5** | 3.74× | 93% |
| 10 | 119,616 | 124초 | **771.1** | 5.60× | 56% |
| 20 | 119,223 | 110초 | **850.4** | 6.18× | 31% |

워커 하나를 더 넣을 때의 한계 이득:

```
1 → 4   : 워커당 +125.6 tx/s
4 → 10  : 워커당  +42.8 tx/s
10 → 20 : 워커당   +7.9 tx/s      ← 16배 감소
```

메모리 (RSS / VSZ, MB): 23/206 → 38/446 → 54/916 → 61/1671.
**RSS 안정 = 누수 징후 없음. VSZ 는 워커당 약 76 MB 선형 증가.**

#### 워커 스레드만 분리한 프레임 분포

전체 샘플에서 main / heartbeat / sigusr1 스레드를 제외하고 워커 스레드만 집계:

| 워커 | 워커-샘플 | `css_readn` | `la_insert_applied_tx_marker` |
|---|---|---|---|
| 1 | 66 | ~100% | 0% |
| 4 | 160 | 95.6% | 1.9% |
| 10 | 390 | 89.5% | 3.6% |
| 20 | 660 | 72.9% | **12.4%** |

> 워커-샘플 = 전체 스레드-샘플 ÷ 스레드 수 × 워커 수.
> 스레드 구성은 워커 N개 + main + heartbeat + sigusr1 = N+3 개다.
> (워커 1 에서 `css_readn` 68회가 워커-샘플 66을 넘는 것은 main 스레드도
> 가끔 같은 프레임에 걸리기 때문이다.)
>
> `summary.tsv` 의 `marker_of_busy` 컬럼(0.0 / 1.1 / 2.8 / 11.5%)은 분모가
> 달라서 위 표와 값이 다르다. 그쪽은 `(전체 샘플 − 유휴 샘플)` 을 분모로 쓰므로
> heartbeat·sigusr1·main 스레드까지 포함된다. **해석에는 위 표(워커 전용)를 쓸 것.**

`css_readn` 은 **슬레이브 cub_server 의 응답 대기**다. 워커가 자기 코드를 도는
시간은 거의 없다. 따라서 워커를 늘릴수록 효율이 떨어지는 주된 이유는 applier
코드가 아니라 서버 포화다 — 워커를 늘리면 서버 앞에 줄이 길어질 뿐이다.

---

## 5. 확정된 코드 결함: 전역 뮤텍스를 쥔 채 서버 왕복

`src/transaction/log_applier.c:3807`, `la_insert_applied_tx_marker()` —
커밋마다 실행되는 마커 INSERT:

```c
/* the execution compiles the statement again when the server asks for it, for example after the table size
 * changed a lot, so it runs under the compile mutex too */
pthread_mutex_lock (&la_sql_compile_mutex);
res = db_push_values (context->marker_session, 3, in_value);
if (res == NO_ERROR)
  {
    res = db_execute_and_keep_statement (context->marker_session, context->marker_stmt_id, &result);
    ...
  }
pthread_mutex_unlock (&la_sql_compile_mutex);
```

- `la_sql_compile_mutex` 는 **파일 전역**이다 (`log_applier.c:470`).
  사용처: 3644, 3787, 3808, 3844, 7037, 7083.
- 그 안의 `db_execute_and_keep_statement` 는 **서버 왕복**을 한다.
- 결과적으로 **모든 워커의 모든 커밋이 "전역 락을 쥔 채 네트워크 왕복"을 직렬 수행**한다.
- 측정상 워커 작업시간 대비 0% → 1.9% → 3.6% → **12.4%**. 10→20 에서 3.5배.
  워커 수에 대해 가장 빠르게 악화되는 비용이다.
- 구조적으로는 **워커 수와 무관한 천장**이기도 하다. 마커 INSERT 왕복 시간을 T 라
  하면 전체 커밋 처리량은 1/T 를 넘을 수 없다. 현재 850 tx/s 는 T ≈ 1.2ms 라는 뜻으로
  아직 천장에 닿지는 않았지만, 서버가 느려지거나 워커가 늘면 바로 닿는다.

주석이 밝히듯 뮤텍스의 목적은 **클라이언트측 파서 보호**(재컴파일 가능성)인데,
재컴파일이 일어나지 않는 일반적인 경우까지 전역 직렬화 비용을 물고 있다.
→ **개선 방향: 재컴파일이 실제로 발생할 때만 락을 잡도록.**
  (단, 이 수정의 효과는 아직 측정으로 확인되지 않았다 — 6절 참조)

`la_insert_applied_tx_marker` 는 커밋 `72650ce0d` (재시작 시 이미 적용된
트랜잭션 스킵) 에서 들어온 경로다.

---

## 5-1. 추가 분석 (2026-11-07) — 같은 pstack 샘플을 스레드별로 재집계

**새 측정 없음.** `youngjun2:/tmp/ha_bl{1,4,10,20}` (사본 `/home/youngjun/cbrd27508_perf/results/slave/pstack_ha_bl{1,4,10,20}`) 의 샘플 441장(66/40/39/33)을 스레드(LWP)별·
락 소유자별·비워커 스레드까지 나눠 다시 셌다. 상세와 코드 인용은 `ha_final_report.md` 8절.
집계용 awk 는 세션 scratchpad 에 있었다 (per_thread / mutex / coord2 / starve / srv).

| # | 문제 | 수치 (워커 20) | 출처 |
|---|---|---|---|
| 1 | marker 전역 락 — 워커 1개 0%, 20개 각 워커 6.1~27.3% 고르게 | 락 대기 12.4%, 순간 최대 15명 대기 | 측정+코드 |
| 2 | 서버 응답 대기 내역 | 커밋 45% / 행적용(`la_flush_repl_items`) 47% | 측정 |
| 5 | 코디네이터 pending 큐 재스캔 (`log_applier_pending.cpp:101`) | 코디네이터 유휴 95.5→65→0→0%, 스캔 42~64% | 측정+코드, **큐 길이는 추론** |
| 5 | ↳ 그로 인한 워커 일감 대기 (`la_task_queue_pop`) | 0→0→1.0→6.5%, trace 제외 약 3.3% | 측정 |
| 6 | 페이지 버퍼 전역 뮤텍스 `cache_pb->mutex` (2419/2555/2584) | 0.6→2.6→4.5% | 측정+코드 |
| 7 | 파킹마다 malloc (`log_applier_pending.cpp:64`) | 비중 미산출 | 코드 |
| 8 | 게이트 정합성 TODO (`log_applier_gate.cpp:319`, FK·부모/자식 순서) | 측정 불가 | 코드 주석 |
| 9 | trace 로그 뮤텍스 (`la_coordinator_trace_schedule`, `log_applier.c:849`) | 2.0%, 일감 대기 43건 중 21건 유발 | 측정+코드 |

해석:
- 로그를 순서대로 읽는 시간은 코디네이터의 6.1% 뿐 — 순차 읽기 제약은 병목이 아니다. 대부분 pending 스캔.
- 코디네이터 때문에 워커가 노는 손실은 현재 약 3% — **지금의 손실원이 아니라 다음 천장**. 워커 10개 적정과 일치.
- pending 진입 조건은 '의존성 미충족 **또는** 워커 큐 full'(`log_applier.c:7799`). 큐 full 로 들어간 건
  맨 앞에서 바로 꺼내져 스캔 비용이 없다. 어느 쪽이 많은지가 문제 5 를 고칠지 말지를 가른다 — 미확인.
- 문제 9 는 운영 기본값(`ha_writeset_trace_level=0`)에서는 없다. 측정 conf 에 1 이 들어 있었다.
- 표본이 작다 (코디네이터는 구성당 33~66장). 워커 20 코디네이터 수치는 ±17%p 정도로 읽을 것.

---

## 5-2. 재측정 (2026-11-07 저녁) — trace 0, 샘플러 분리. 상세는 보고서 9절

- **pstack 은 applylogdb 를 매 샘플 1.3~1.9초 전부 정지시킨다.** 4·8절 처리량은 실제의 약 절반이었다.
  이제는 `SAMPLER=eustack` (`ha_eustack.sh`) 를 쓰고, 처리량은 `SAMPLER=none` 으로 따로 잰다.
- 처리량 (trace 0, 샘플러 없음): **워커 4 = 1,010.2, 워커 10 = 1,629.8 tx/s.** eu-stack 영향 2~4%.
- **원인 분리 (워커 4, 같은 시간대):** pstack+trace1 = 497.2 (어제 514.5 재현, 호스트 한가) / trace1·샘플러 없음 = 931.4 /
  trace0·샘플러 없음 = 1,010.2. → **시스템 문제 아님. pstack 이 약 47% 깎음, trace 는 약 8%.** (보고서 9.7)
- 마스터·슬레이브는 같은 물리 호스트의 컨테이너(CPU 80, 디스크 공유, 다른 사용자 작업 있음). 비교는 같은 시간대에 연달아 잴 것.
- **확장성 재계산 (깨끗한 측정, 보고서 9.8):** 워커 1 / 4 / 10 / 20 = 347 / 965 / 1,630 / 1,729 tx/s → 배속 1 / 2.78 / 4.69 / 4.98.
  4절의 3.74 / 5.60 / 6.18 은 과대. 10 → 20 은 +6% 뿐 — 실용 상한 워커 10 유지.
- 워커 20: marker 락 대기 30.9%, **굶음 20.8%**. 코디네이터는 유휴 2.6%, 자기 서버 왕복 39.5%, 스캔 28.9%.
- **[문제 10] 코디네이터가 500ms 마다 `la_coordinator_commit_apply_info()` (apply_info UPDATE + marker DELETE + 통계 + 커밋) 를
  동기로 실행하고, 그 쿼리들이 `la_sql_compile_mutex` 를 쥔다.** 워커 20 에서 코디네이터 시간의 45%, 굶음의 37%,
  marker 락 대기의 36% 가 이 순간. (보고서 9.9)
- 결과: 로컬 `/home/youngjun/cbrd27508_perf/results/ha_bl5_clean/`, `/home/youngjun/cbrd27508_perf/results/ha_bl5_stack/`, 호스트 기록 `/home/youngjun/cbrd27508_perf/results/ha_bl5_host/`.
- **marker 락: 워커 10 에서 대기 26.9% + 보유 3.8% ≈ 31%** → 어플라이어 1순위 확정.
- 페이지 버퍼 뮤텍스 0.6%, 굶음 0.6% → 작다. 코디네이터는 워커 10 에서 유휴 4%, 스캔 44%.
- pending 실측 (trace 로그 재현): 따라잡기 중 파킹률 99.5% 이상, 깊이 수천(최대 6,917), 맨 앞 해제 8% → 의존성 파킹.
  상한 = 워커 수 × 1024 (`LA_COMMIT_ORDER_CAPACITY`).
- cub_server (샘플 6~7장): 서버 내부 락 경합 거의 없음. 커밋이 WAL flush 를 기다림(group commit 꺼짐) + CPU(디버그 검사 함수 많음).
- 재현: `OUT=... RDIR_PREFIX=/tmp/ha_bl3s_ SAMPLER=eustack APPLY_INTERVAL=1 SRV_INTERVAL=5 TRACE=0 ./ha_backlog.sh 90 4 10`
  결과: `/home/youngjun/cbrd27508_perf/results/ha_bl3_clean/`, `/home/youngjun/cbrd27508_perf/results/ha_bl3_stack/` (로컬), 슬레이브 회차 디렉토리 사본 `/home/youngjun/cbrd27508_perf/results/slave/ha_bl3{c,s}_*`.

---

## 5-3. 시나리오 B (고충돌) — 2026-11-08. 상세는 보고서 10절

- 처리량 (샘플러 없음, trace 0): 워커 1 / 4 / 10 / 20 = **225 / 449 / 413 / 340 tx/s** → 배속 1 / 1.99 / 1.84 / 1.51.
  **워커 4 에서 멈추고 그 이상은 느려진다.** 같은 시간대 A 워커 10 기준점 = 1,546.9.
- 실제 일하는 워커는 워커 수와 무관하게 **2.1~2.5명**. 굶음 36% / 73.5% / 88.9%. marker 락은 0.5~2.7% 로 작음.
- 코디네이터 스캔 4% / 38% / 43%. pending 깊이는 **링 용량(워커 × 1024)까지 꽉 참** (4,095 / 10,239).
  성공한 pop 은 평균 1.5 노드, 맨 앞 해제 77% → **비용은 빈손 헛스캔** (워커 10 이면 약 9,400 노드를 매번 걷는다).
- **B 에서는 문제 5 가 1순위.** 워커 ↑ → 링 ↑ → pending ↑ → 헛스캔 비용 ↑, 병렬도는 그대로 → 처리량 ↓.
- cub_server 는 B 에서 한가함. 워커 20 에서 RSS 87 → 146 MB 증가 (파킹된 트랜잭션 항목으로 추정, 누수 판정은 못 함).
- trace 로그 보존: `/home/youngjun/cbrd27508_perf/trace_logs/B_20261108/`. pending 재현:
  `WIN="4=14:36:56-14:38:53,10=14:44:13-14:47:12" python3 ha_analysis/pending_sim.py <.err.gz>`
- 분석은 `./ha_analyze.sh <결과디렉토리/w<N>> [호스트기록]` 한 번으로 체크리스트 전부 출력.
- **헛스캔 원인 (보고서 10.6):** perf 로 확인 — B 워커 4 에서 코디네이터 CPU 의 56% 가 스캔, 그중 77% 가
  `la_coordinator_collect_results()` 경유. 이 함수가 결과를 0건 가져와도(프론티어 불변) 끝에서 무조건
  `la_coordinator_drain_ready()` 를 불러 pending 전체를 훑는다 (`log_applier.c:918`, 메인 루프에서 레코드마다 `:10364`).
  1순위 수정: 프론티어가 전진했거나 직전 drain 이 큐 full 로 멈췄을 때만 drain.

---

## 6. 아직 확인 안 된 것 (다음에 할 일)

1. **슬레이브 서버 쪽 — 일부 확인됨 (보고서 9.5, 9.8).** eu-stack 으로 떠 보니 서버 내부 락 경합은 거의 없고,
   커밋의 로그 flush 대기 + CPU(디버그 빌드 검사 함수가 다수) 였다. 다만 샘플이 구성당 4~10장뿐이다.
   → 샘플을 더 모으려면 `SRV_INTERVAL` 을 줄이되, cub_server 는 **pstack 금지** (1회 약 6초 정지).
2. **marker 뮤텍스 수정의 실제 효과.** 실행 경로에서 락을 빼고 재측정해야
   12.4% 가 실제 처리량으로 돌아오는지 알 수 있다.
3. 시나리오 B 는 5-3 에서 완료. C(혼합)·D(대형 트랜잭션) 은 아직.
4. 각 구성 1회 측정뿐이다. 4.4 의 곡선은 매끄럽지만 반복 측정은 하지 않았다.
5. `cubrid memmon` 은 `cub_server` 만 대상이라 applylogdb 누수에는 못 쓴다.
   applylogdb 는 `/proc/<pid>/status` 의 VmRSS/VmSize 로 본다 (ha_pstack.sh 가 수집).
   본격적인 누수 추적은 ASan 별도 빌드가 필요하다.
6. **pending 헛스캔 비용 (문제 5).** pending 깊이·파킹 사유는 trace 로그 재현으로 확인됨 (보고서 9.4).
   측정 구간 로그 보존본: `/home/youngjun/cbrd27508_perf/trace_logs/A_20261107/*.gz` (처음에 '지워졌다'고 쓴 건 UTC 시각 착오였다).
   남은 건 `perf record` 로 `la_pending_pop_ready` CPU 시간 직접 측정.
7. **게이트 정합성 테스트 (문제 8).** FK 동작(RESTRICT/CASCADE/SET NULL)·부모-자식 순서 전용 테스트.
8. **기준선 비교.** 지금의 '워커 1' 은 병렬 코드를 워커 1개로 돌린 것이다. 원래 applylogdb(develop) 를 같은 조건으로
   재야 '병렬화 전보다 몇 배' 를 말할 수 있다.
9. **코디네이터 비용 직접 측정 (문제 5·10).** `perf record` 로 `la_pending_pop_ready` 헛스캔과
   `la_coordinator_commit_apply_info` 의 시간을 잰다. perf 는 대상을 멈추지 않는다 (슬레이브 `perf_event_paranoid=-1`).

---

## 6-1. 측정·분석 절차 보완 (2026-11-08 추가)

### 왜 필요한가

11/6~11/8 측정에서 발견사항이 한 번에 나오지 않고 질문을 받을 때마다 조금씩 나왔고, 앞서 말한 수치를 여러 번 고쳐야 했다.
원인은 세 가지였다.

| 원인 | 실제로 생긴 일 | 결과 |
|---|---|---|
| **분석을 처음부터 다 쪼개지 않음** | 프로세스 합산만 보고 marker 하나가 나오자 멈춤. 스레드별·코디네이터·락 소유자별·서버 대기 내역은 질문을 받을 때마다 하나씩 했다 | 같은 샘플에서 나올 결과(문제 5·6·9, 코디네이터 포화)가 다음 날에야 나옴 |
| **측정 도구·설정을 먼저 검증하지 않음** | pstack 이 대상을 1~2초씩 멈추는 걸 몰랐다. `ha_writeset_trace_level=1` 을 확인하지 않았다 | 처리량이 절반으로 나오고 락 경합이 작게 보였다. 배속·marker 비중·페이지 버퍼 락 수치를 나중에 정정 |
| **시각 기준 혼동** | 세션 기록(UTC)과 슬레이브 로그(KST)를 섞어 읽었다 | 남아 있던 trace 로그를 "지워졌다"고 잘못 판단, pending 실측이 늦어짐 |

세 번째 단계(오염을 걷어낸 뒤 다음 병목이 드러나는 것, 예: 문제 10)는 피할 수 없지만, 앞의 둘을 지켰다면 훨씬 빨리 도달했다.

### 보완 1 — 측정 전 점검 (매 회차)

- [ ] **샘플러가 대상을 얼마나 멈추는지 확인한다.** 샘플러를 한 번 돌리면서
      `/proc/<pid>/task/*/status` 의 `State` 가 `t` 인 스레드 수를 0.1~0.2초 간격으로 본다.
      - pstack(gdb) 은 쓰지 않는다 (applylogdb 1.3~1.9초, cub_server 약 6초 전 스레드 정지).
      - eu-stack 을 쓴다 (`SAMPLER=eustack`, `ha_eustack.sh`). 처리량 영향 2~4% 로 확인됨.
- [ ] **처리량 회차와 스택 회차를 나눈다.** 처리량은 `SAMPLER=none` 회차에서만 잰다.
- [ ] **설정을 확인하고 결과 디렉토리에 같이 남긴다.**
      `ha_writeset_trace_level` (성능 측정은 0, pending 분석이 필요할 때만 1), `ha_apply_worker_count`,
      `group_commit_interval_in_msecs`, `async_commit`, 빌드 종류(optdebug / release).
- [ ] **호스트 상태를 같이 기록한다.** 마스터·슬레이브가 같은 물리 호스트의 컨테이너라 다른 사용자 작업의 영향을 받는다.
      측정 동안 `vmstat -t 5`, `iostat -dxt 5` 를 돌려 둔다 (`/home/youngjun/cbrd27508_perf/results/ha_bl5_host` 처럼).
- [ ] **시각은 슬레이브 로컬(KST)로 통일한다.** 측정 창은 epoch 로도 남긴다 (`series.txt`).
- [ ] **trace 를 켠 회차는 끝나자마자 applylogdb 에러 로그를 복사한다.** 크기가 차면 `.bak` 로 밀리고 결국 사라진다.

### 보완 2 — 측정 설계

- [ ] **비교는 같은 시간대에 조건만 바꿔 연달아 잰다.** 다른 날 수치끼리 직접 비교하지 않는다.
- [ ] **기준점을 한 번 더 잰다.** 예: 워커 4 를 매 묶음에 포함 → 시간대 흔들림을 확인 (11/8 에 약 5% 확인).
- [ ] **구성당 3회 반복한다.** 공식 수치는 중앙값과 범위로 낸다.
- [ ] **비교 기준을 분명히 한다.** '워커 1' 과 '원래 applylogdb(develop)' 는 다르다.

### 보완 3 — 분석은 한 번에 전부 (체크리스트)

측정 하나가 끝나면 아래를 **모두** 돌린 뒤에 결과를 한 번에 보고한다. 질문을 받고 하나씩 하지 않는다.

| # | 항목 | 보는 것 |
|---|---|---|
| 1 | 처리량 | tx/s, 배속, 효율, 워커 1개 늘 때 증가분 |
| 2 | 워커 상태 분해 | 일 / 락 대기(소유 뮤텍스별) / 서버 대기(커밋·행 적용·marker·기타) / 굶음 |
| 3 | 워커별 분포 | TID 순서별 일·락·유휴 비율, **샘플당 실제로 일하는 워커 수(병렬도)** |
| 4 | 코디네이터 | 유휴 / pending 스캔 / 파싱 / 페이지 읽기 / 자기 서버 왕복(진행정보 저장) / 락 대기 |
| 5 | 락 보유자 상관 | 락 대기가 생긴 순간 누가 그 락을 쥐고 있었나 (워커끼리 / 코디네이터) |
| 6 | 굶음 원인 상관 | 워커가 놀던 순간 코디네이터가 무엇을 하고 있었나 |
| 7 | pending 큐 | (trace 1 회차만) 파킹률, 깊이, pop 당 스캔 길이, 맨 앞 해제 비율 |
| 8 | cub_server | 요청 처리 스레드의 커밋 flush 대기 / CPU / 락 대기, flush 데몬 상태 |
| 9 | 메모리 | RSS, VSZ |
| 10 | 호스트 | 측정 창의 CPU·iowait·디스크 await |

- 모든 수치에 출처를 붙인다: **[측정] / [코드] / [추론]**.
- 표본 수를 같이 적는다. 코디네이터·cub_server 처럼 샘플이 수십 장 이하면 "대략의 크기"로만 쓴다.

### 보완 4 — 보고 방식

- 문제 번호는 한 번 정하면 바꾸지 않는다 (현재 문제 1~10). 다른 목록을 만들 때도 그 번호를 그대로 쓴다.
- 앞서 말한 수치가 바뀌면 "정정" 으로 명시하고, 무엇이 왜 바뀌었는지 한 줄로 적는다.
- 측정·코드·추론을 섞어 한 문장으로 쓰지 않는다.

### 보완 5 — 분석 스크립트를 저장소로

지금 위 분석에 쓴 awk·python 스크립트(`per_thread.awk`, `apply_eu.awk`, `holder.awk`, `starvecause.awk`, `perworker.awk`,
`srvcls.awk`, `pending_sim.py` 등)는 **세션 임시 디렉토리(scratchpad)** 에 있어 세션이 끝나면 사라진다.
→ **완료 (11/8):** `/home/youngjun/cbrd27508_perf/scripts/ha_analyze.sh <결과/w<N>> [호스트기록]` 와 `scripts/ha_analysis/` 로 묶었다. 보완 3 의 항목을 한 번에 출력한다.

---

## 7. 측정 방법상의 함정 (반복할 사람을 위해)

이번에 실제로 겪어 시간을 많이 잡아먹은 것들:

- **ssh 가 원격 자식의 stdout 을 쥐고 안 돌아온다.** `ssh host "cmd" >/dev/null`
  의 리다이렉트는 *로컬* 이다. 데몬을 띄우는 원격 명령은 **원격 쪽에서** 끊어야 한다:
  `ssh host "cmd </dev/null >/dev/null 2>&1"`. `timeout` 을 걸어도 소용없다 —
  timeout 이 부모를 죽여도 자식이 파이프를 쥐고 있으면 ssh 는 계속 기다린다.
- **`pgrep -f <패턴>` 이 자기 자신을 잡는다.** 패턴이 자기 명령줄에 들어있기 때문.
  셸이 단일 명령을 exec 최적화하면 안 걸리지만 복합 명령에서는 걸린다.
  `pgrep -f 'ha_back[l]og'` 처럼 문자 클래스로 깨뜨릴 것. `pkill -f` 로 자기
  자신을 죽이는 사고가 실제로 두 번 났다.
- **루프 안의 ssh 가 스크립트의 stdin 을 먹는다.** `ssh -n` 필수.
  폴링이 잦으면 `ControlMaster=auto` + `ControlPersist` 로 왕복 비용을 줄일 것.
- **부하가 없어도 슬레이브에 초당 1건 남짓 배경 트랜잭션이 들어온다.**
  따라서 "따라잡기 완료"를 `commit_counter` 증가 정지로 판정하면 영원히 안 끝난다.
  "최근 N폴 증가량 < 임계치"로 판정해야 한다 (`TRICKLE`).
- **측정 창의 양 끝을 잘라야 한다.** 앞쪽은 applylogdb 가 붙어 실제 적용을
  시작하기까지의 지연, 뒤쪽은 이미 다 따라잡고 노는 구간. 자르지 않으면 빠른
  구성일수록 심하게 왜곡된다 (1차 시도에서 워커 20이 4,059 tx/s 로 나왔다).
  `ha_backlog.sh` 는 백로그의 2%~98% 구간만 센다.
- **따라잡기 완료 후의 pstack 샘플은 유휴만 담아 분포를 왜곡한다.**
  `find -newermt @<완료시각> -delete` 로 잘라낸다.
- **pstack 으로 샘플링하면서 처리량을 재지 말 것.** pstack(gdb) 은 덤프 동안 대상 전 스레드를 멈춘다
  (applylogdb 1.3~1.9초, cub_server 약 6초). eu-stack 을 쓰고, 처리량은 샘플러 없는 회차에서 잰다.
- **대화/로그 시각 착오 주의.** 세션 기록은 UTC, 슬레이브 로그는 KST 다.
- **`ha_writeset_trace_level` 을 켠 채 성능을 재면 결과가 오염된다.** 코디네이터가 trace 한 줄을
  쓰는 동안 std::mutex 에 막혀 워커 18/20 이 동시에 노는 순간이 잡혔다. 측정 전 0 으로.
  반대로 파킹 분석이 필요하면 켜되, 해당 로그 파일을 측정 직후 따로 복사해 둘 것 (금방 교체된다).
- **csql 에서 `"..."` 는 식별자다.** 문자열은 홑따옴표.
  `CREATE TABLE IF NOT EXISTS` 는 되지만 `CREATE INDEX IF NOT EXISTS` 는 안 된다.

---

## 8. 결과 원본 위치

```
/home/youngjun/cbrd27508_perf/results/ha_backlog2/summary.tsv      4.4 요약표
/home/youngjun/cbrd27508_perf/results/ha_backlog2/w<N>/pstack.txt  구성별 프레임 집계
/home/youngjun/cbrd27508_perf/results/ha_backlog2/w<N>/series.txt  시각별 commit_counter (따라잡기 곡선)
/home/youngjun/cbrd27508_perf/results/ha_backlog2/w<N>/stacks.tgz  원본 스택 샘플
/home/youngjun/cbrd27508_perf/results/ha_backlog2.log              실행 전체 로그
/home/youngjun/cbrd27508_perf/results/ha_scale/summary.tsv         4.3 (무효) 요약표
/home/youngjun/cbrd27508_perf/results/ha_result/pstack_{A,B}.txt   4.1/4.2 집계
```

## 9. 정리할 때

```bash
# 양 노드
cubrid heartbeat stop
cubrid service stop
```

유령 프로세스: 초기에 띄운 `cubrid heartbeat start` 가 반환하지 않고 남아 있을 수
있다 (HA 동작에는 영향 없음). `pgrep -f "heartbea[t] start"` 로 확인 후 kill.
