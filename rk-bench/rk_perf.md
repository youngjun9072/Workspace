# RK 브랜치(CBRD-26246) 성능 지연 조사

작성: 2026-11-09 (release 측정 2026-11-10 추가) · 측정 도구·절차는 `ha_work_log.md` 와 같다 (백로그 따라잡기, eu-stack, perf, 샘플러 없는 처리량 회차).

## 0. 결론

1. **RK 기능 자체가 만드는 지연은 작다.**
   - 마스터: 행마다 복제 옵션을 읽는 `heap_get_class_repl_on` 이 cub_server CPU 의 **0.7%**.
   - 슬레이브: 행마다 RK 인덱스를 찾는 `btree_get_rkey_btid` 와 클래스 정보 조회를 합쳐 **0.4~0.6%**.
   - 코드의 TODO (`locator_sr.c:8194`, "모든 RK 후보를 검사") 는 구조적으로는 맞는 지적이지만, 측정상 비용은 작다.
2. **슬레이브 적용 지연의 대부분은 서버가 행 변경 묶음을 적용하는 시간이다.**
   applylogdb 는 시간의 72~85% 를 `locator_repl_force` 응답 대기로 보낸다. 서버 쪽은 행 갱신, 인덱스 유지, 키로 행 찾기 같은 **논리 복제의 기본 비용**이다.
3. **측정된 서버 CPU 의 30~40%(슬레이브)와 약 15%(마스터)는 optdebug 빌드에서만 도는 검사 코드다.**
   가장 큰 것은 페이지를 고정할 때마다 부르는 `disk_is_page_sector_reserved_with_debug_crash` (슬레이브 21~25%).
   릴리스 빌드(`NDEBUG`)에서는 건너뛰는 검사다 (`page_buffer.c:11013`, `pgbuf_is_valid_page`). → **실제 처리량은 릴리스 빌드로 다시 재야 한다.**
4. **처리량을 흔든 것은 측정 환경이었다.** 같은 호스트의 다른 사용자 작업이 CPU 80개를 포화시킨 45초 동안 처리량이 절반 아래로 떨어졌다.
   디스크 쓰기가 몰린 순간 커밋이 약 2초 멈춘 적도 한 번 있었다.

### release 빌드 측정 후 (6절, 2026-11-10)

5. **release 처리량은 optdebug 의 약 2.7배** — A 3,432 tx/s (긴 회차). 3번의 디버그 검사 비용이 실제로 그만큼 컸다.
6. **release 에서도 RK 비용은 작다** — 마스터 0.2%, 슬레이브 약 1%.
7. **release B 에서는 커밋(로그 flush) 대기가 applylogdb 시간의 55% 로 가장 크다.** 행 적용이 빨라지자 디스크 동기화가 드러났다.
8. **[신규] 슬레이브 copylogdb 가 받은 로그의 약 8배를 디스크에 쓴다** (마스터 로그 1,964MB → copylogdb 15,462MB).
   같은 디스크에서 커밋 동기화와 경쟁하는 가장 큰 쓰기다. RK 가 아닌 HA 로그 복사 쪽 동작이고, 원인은 코드로 아직 확인하지 않았다.
9. **[신규, 정합성] 시나리오 B 에서 `ha_t2` 복제 적용 실패가 반복된다** (release 157건, optdebug 45건, A 는 0건).
   최종 데이터는 일치했지만, 같은 부하의 병렬 브랜치에서는 0건이었다. RK 관련 여부는 미확인 (6.7).
10. release B 처리량은 1,675 tx/s (호스트가 깨끗한 구간 기준, optdebug 의 약 2.4~3배).

## 1. 측정 대상

| 항목 | 값 |
|---|---|
| 설치 | 양 노드 `/home/youngjun/CUBRID_26246` — 11.5.0.2715-f0bc315 optdebug (2026-11-09 14:42 빌드) |
| 커밋 | `f0bc3158d` (2026-10-20) — CBRD-26246 의 예전 head. 현재 원격 head 보다 93 커밋 앞 |
| applylogdb | **단일 스레드** (원래 방식). 병렬 워커·marker·pending 없음 |
| 커밋 방식 | 마스터 커밋마다가 아니라 **시간 간격마다 한 번** (`la_check_time_commit`, 최대 `ha_applylogdb_max_commit_interval_in_msecs`=500ms, 지연에 따라 적응) |
| 측정 | 2026-11-09 22:26~22:51, 시나리오 A(무충돌)·B(고충돌), 백로그 생성 90초 |
| 결과 | `results/rk_clean_{A,B}`, `rk_stack_{A,B}`, `rk_perf_{A,B}`, 호스트 기록 `rk_host/`, perf 원본 슬레이브 `/tmp/rk_p{A,B}_1/` |

## 2. 처리량 (따라잡기, 단일 스레드)

| 시나리오 | 샘플러 없음 | eu-stack 회차 | perf 회차 | 비고 |
|---|---|---|---|---|
| A | **1,297 tx/s** | 1,265 | 1,226 | 회차 간 ±3% — 안정 |
| B | ~~391~~ (오염) | **703** | **544** | 391 회차는 호스트 CPU 포화 구간 (4절) |

- A 는 초 단위 적용량이 1,300~1,400 으로 고르다. 중간 멈춤 없음.
- B 는 초당 400~900 으로 출렁인다. 핫키 갱신이 같은 인덱스 키에 몰리는 부하 특성 영향 (3.3).

## 3. 어디서 시간이 드나

### 3.1 applylogdb 메인 스레드 (eu-stack, A 34장 / B 46장)

| 상태 | A | B |
|---|---|---|
| 서버 대기: 행 변경 묶음 적용 (`la_flush_repl_items → locator_repl_force`) | **85.3%** | **71.7%** |
| 서버 대기: 커밋 (`la_log_commit`) | 11.8% | 23.9% |
| applylogdb 자체 CPU | 약 3% | 약 2% |

applylogdb 는 행 변경을 200개(`LA_MAX_UNFLUSHED_REPL_ITEMS`)씩 모아 서버에 보낸다. 자기 CPU 는 거의 안 쓴다 → **병목은 서버 쪽 적용**.

### 3.2 슬레이브 cub_server (perf, 따라잡기 구간, 포함 시간)

| 함수 | A | B | 성격 |
|---|---|---|---|
| `xlocator_repl_force` (행 변경 적용 전체) | 54.6% | 46.3% | |
| └ `locator_update_force` | 31.9% | 25.8% | 기본 |
| └ 인덱스 유지 `btree_delete_internal` / `btree_insert_internal` / `btree_update` | 11.4 / 8.9 / 8.8% | **25.1 / 20.6 / 15.0%** | 기본 (B 는 3.3) |
| └ 키로 행 찾기 `xbtree_find_unique` | 13.9% | 5.9% | 논리 복제 기본 |
| └ **RK** `btree_get_rkey_btid` + `heap_classrepr_get` + `heap_get_class_repr_id` | **0.6%** | **0.4%** | RK 추가분 |
| 커밋 로그 flush `logpb_flush_pages_direct` | 3.0% | 3.5% | 기본 |
| **디버그 전용** `disk_is_page_sector_reserved_with_debug_crash` | **21.3%** | **24.8%** | optdebug 만 |
| **디버그 전용** `pgbuf_fix_debug`(자체) · `vfprintf` · `btree_check_valid_record` · `resource_tracker` · `pgbuf_watcher_init_debug` | 약 15% | 약 14% | optdebug 만 |

### 3.3 마스터 cub_server (perf, 부하 90초, 포함 시간)

| 함수 | A | B | 성격 |
|---|---|---|---|
| 쿼리 실행 `xqmgr_execute_query` | 29.6% | 32.0% | |
| **RK** `heap_get_class_repl_on` (행마다 클래스 레코드 읽기) | **0.72%** | **0.72%** | RK 추가분 |
| **RK** `or_is_replication_candidate_key` | 0.5% 미만 | 0.5% 미만 | RK 추가분 |
| 복제 로그 생성 `repl_log_insert` | 1.55% | 1.53% | develop 에도 있음 |
| **디버그 전용** `disk_is_page_sector_reserved_with_debug_crash` | 10.5% | 11.4% | optdebug 만 |
| **디버그 전용** `pgbuf_fix_debug`(자체) · `vfprintf` 등 | 약 5% | 약 6% | optdebug 만 |

마스터 처리량 (부하 생성기 기준): A 659 tx/s, B 403 tx/s.

### 3.4 B 의 인덱스 비용 — 부하 특성 (RK 아님)

B 는 모든 세션이 핫키 500개를 `sess=<세션>, seq=<회차>` 로 갱신한다. 비유일 인덱스 `i_ha_t1_sess (sess, seq)` 의 키 종류가 적어
한 키에 OID 가 많이 몰리고, **오버플로 페이지 생성·삭제가 초당 수십~백여 번** 일어난다 (서버 로그 NOTIFICATION `-1126` / `-1127`).
슬레이브 인덱스 유지 비용이 A 의 2배가 넘는 이유이고, 매번 에러 로그에 NOTIFICATION 을 쓰는 비용도 붙는다.
RK 와 무관한 부하·인덱스 설계 영향이다.

## 4. 측정 중 관찰된 지연

### 4.1 호스트 CPU 포화 — 처리량 절반 (측정 환경)

B 첫 회차(샘플러 없음)가 391 tx/s 로 나왔다. 초 단위로 보면 처음 17초는 800~890/s 였다가 **22:32:33~33:18 동안 200~400/s** 로 떨어졌다.
같은 시각 호스트 vmstat: CPU user 85~88%, 유휴 0%, 실행 대기 89~103 — **다른 사용자 작업이 CPU 80개를 포화**시켰다.
RK 문제가 아니라 공유 호스트 문제다. 이 회차는 버린다.

### 4.2 커밋 중 약 2초 멈춤 (1회 관찰, 원인 미확정)

perf B 회차 22:50:03.3~05.4 동안 적용이 0 이었다.

- applylogdb 는 `la_log_commit → la_update_ha_last_applied_info → db_execute_with_values` (주기 커밋 중 진행정보 갱신) 에서
  약 1.9초 CPU 를 쓰지 않고 기다렸다 (perf 샘플 공백 + 0.5초마다 남기던 로그가 끊김).
- 같은 시간 슬레이브 서버 CPU 는 거의 쉬었고 (0.1 코어·초), 샘플의 76% 가 커널 영역.
- 호스트 디스크 쓰기가 그 순간 **약 170~214 MB/s** 로 몰렸고 I/O 대기 프로세스가 4~7 로 늘었다.

→ [추론] 커밋의 디스크 동기화가 쓰기 폭주에 밀렸다. 마스터·슬레이브가 **같은 디스크**에 로그를 여러 벌 쓴다
(마스터 로그 · 마스터 아카이브 · copylogdb 사본 · 슬레이브 로그 · 슬레이브 아카이브, 로그 볼륨 1GB 가 찰 때마다 1GB 아카이브).
누가 썼는지는 이 데이터로 가릴 수 없다. B 3회 중 1회, A 3회 중 0회.

## 6. release 빌드 측정 (2026-11-10 00:28~)

4절까지는 optdebug 빌드였다. 디버그 검사가 서버 CPU 의 15~40% 를 차지해 실제 성능을 가렸으므로 release 로 다시 쟀다.

### 6.1 환경

| 항목 | 값 |
|---|---|
| 빌드 | `/home/youngjun/cubrid/build_x86_64_release` — 11.5.0.2715-f0bc315 **release build** (2026-11-09 23:59). `pgbuf_fix_debug` 없음, `pgbuf_fix_release` 있음 |
| 설치 | 양 노드 `/home/youngjun/CUBRID_26246_rel` (라이브러리 md5 두 노드 동일). 설정 파일은 `CUBRID_26246` 과 같은 파일 |
| DB | `CUBRID_26246_rel/databases` 에 testdb 새로 생성, `ha_load.sh setup` 으로 `ha_t1` 10만 행 (슬레이브 복제 확인) |
| HA | **지금 release HA 가 떠 있다.** optdebug HA(`CUBRID_26246`)는 내렸고 파일·DB 는 그대로 있다 |
| 주의 | 마스터 실행 파일은 RPATH 로 `build_x86_64_release/_install/.../lib` 를 직접 읽는다 — 측정 중 저장소 재빌드 금지 |
| 측정 중 호스트 | 모든 회차에서 CPU user 3~5%, 포화 구간 없음 → 깨끗함 |
| 결과 | `results/rkrel_{clean,stack,perf,long}_{A,B}/`, 프로세스별 디스크 쓰기 `results/rkrel_host/pio_{master,slave}.txt`, perf 원본 슬레이브 `/tmp/rkr_p{A,B}_1/` |

### 6.2 처리량 — optdebug 의 2~2.7배

| 시나리오 | 회차 | 측정 구간 | release | optdebug (2절) |
|---|---|---|---|---|
| A | **긴 회차 (부하 300초)** | **67초** | **3,432 tx/s** ← 기준값 | 1,226~1,297 |
| A | 샘플러 없음 / eu-stack / perf | 12 / 11 / 16초 | 3,204 / 3,157 / 2,758 | |
| B | 긴 회차 (부하 300초), **호스트 깨끗한 59초만** | 59초 | **1,675 tx/s** ← 기준값 | 544~703 |
| B | 긴 회차 전체 (앞 50초 호스트 포화로 오염) | 114초 | 1,213 | |
| B | 샘플러 없음 / eu-stack / perf | 5 / 27 / 15초 | 1,642 / 1,309 / 1,540 | |

- A 는 **약 2.7배**, B 는 **약 2.4~3배.** 디버그 검사 비용이 그만큼 컸다.
- B 긴 회차는 따라잡기 앞 50초(01:02:30~01:03:20) 동안 **다른 사용자 작업이 호스트 CPU 를 포화**시켰다 (user 85~88%, 유휴 0%).
  그 구간 초당 적용은 400~1,100, 호스트가 풀린 뒤에는 1,600~2,300. 깨끗한 59초만 따로 계산한 값이 1,675 tx/s.
- 짧은 회차는 따라잡기가 빨라 측정 구간이 5~16초뿐이라 ±10% 이상 흔들린다. 기준값은 긴 회차.
- perf 회차는 perf 3개를 동시에 붙인 영향으로 약 14% 낮다.

### 6.3 applylogdb 메인 스레드 (eu-stack)

| 상태 | release A (12장) | release B (29장) | optdebug A | optdebug B |
|---|---|---|---|---|
| 서버 대기: 행 변경 묶음 적용 | 83% | 41% | 85% | 72% |
| **서버 대기: 커밋 (로그 flush)** | 8% | **55%** | 12% | 24% |

**release B 에서는 커밋 대기가 가장 큰 비용이 됐다.** 서버의 행 적용이 빨라지자 다음 병목인 커밋(디스크 동기화)이 드러났다. 표본이 작아 크기는 대략으로 볼 것.

### 6.4 슬레이브 cub_server (perf, 따라잡기 구간, 포함 시간)

| 함수 | release A | release B |
|---|---|---|
| `xlocator_repl_force` (행 변경 적용 전체) | 46.9% | 39.4% |
| └ `locator_update_force` | 27.2% | 20.8% |
| └ 인덱스 `btree_delete_internal` / `btree_insert_internal` / `btree_update` | 12.2 / 6.7 / 6.4% | 23.8 / 15.0 / 10.6% |
| └ 키로 행 찾기 `xbtree_find_unique` | 11.2% | 4.7% |
| 로그 flush `logpb_flush_pages_direct` (CPU 분만. 디스크 대기는 perf 에 안 잡힘) | 6.7% | 7.2% |
| **RK** `heap_classrepr_get` + `heap_get_class_repr_id` + `btree_get_rkey_btid` | **약 1.3%** | **약 0.8%** |

디버그 검사 함수는 모두 사라졌다. 남은 비용은 행 갱신·인덱스 유지·키 조회·로그 flush — 논리 복제의 기본 비용이다.
RK 추가분은 다른 비용이 줄어든 만큼 비중이 조금 올랐지만 여전히 1% 안팎이다.

### 6.5 마스터 cub_server (perf, 부하 90초, 포함 시간)

| 함수 | release A | release B |
|---|---|---|
| 쿼리 실행 `xqmgr_execute_query` | 20.0% | 22.2% |
| **RK** `heap_get_class_repl_on` | **0.15%** | **0.18%** |
| **RK** `or_is_replication_candidate_key` | 0.02% | 0.02% |
| 복제 로그 생성 `repl_log_insert` (develop 에도 있음) | 0.43% | 0.47% |

마스터 처리량 (부하 생성기 기준): A 762 tx/s, B 431 tx/s. **마스터 쪽 RK 비용은 0.2% 수준으로 무시할 만하다.**

### 6.6 [신규 발견] copylogdb 의 디스크 쓰기 증폭 — 약 8배

프로세스별 디스크 쓰기(`/proc/<pid>/io` 를 1초마다 기록, `scripts/ha_procio.sh`)에서 슬레이브 copylogdb 가 가장 많이 썼다.

**측정 세트 전체 (00:28~00:47, 19분):**

| 노드 · 프로세스 | 쓰기 합계 | 초당 최대 |
|---|---|---|
| 마스터 cub_server | 10,463 MB | 30 MB/s |
| 마스터 copylogdb (슬레이브 로그 복사) | 4,676 MB | 56 MB/s |
| 슬레이브 cub_server | 4,575 MB | 54 MB/s |
| **슬레이브 copylogdb (마스터 로그 복사)** | **22,947 MB** | **63 MB/s** |
| applylogdb (양쪽) | 0 | 0 |

**정밀 측정 — 긴 회차 A (부하 300초 + 따라잡기):** 회차 앞뒤의 복사된 로그 끝 페이지(`db_ha_apply_info.append_lsa_pageid`, 16KB 페이지)와 누적 쓰기 바이트 비교.

| | 양 | 마스터 로그 대비 |
|---|---|---|
| 마스터가 만든 로그 | 1,964 MB (125,697 페이지) | 1배 |
| **슬레이브 copylogdb 디스크 쓰기** | **15,462 MB** | **7.9배** |
| 슬레이브 cub_server 디스크 쓰기 | 2,455 MB | 1.3배 |
| 긴 회차 B: 마스터 로그 / copylogdb / 슬레이브 서버 | 2,113 / 14,633 / 3,367 MB | 1 / **6.9배** / 1.6배 |

- copylogdb 는 받은 로그 1MB 마다 디스크에 약 8MB 를 쓴다. 슬레이브가 실제로 적용하며 쓰는 양(1.3배)의 6배.
- 마스터·슬레이브가 **같은 디스크**를 쓰므로, 슬레이브 커밋의 디스크 동기화와 경쟁한다. 4.2절의 "커밋 중 약 2초 멈춤"(optdebug)의 유력한 원인 후보이고,
  release B 에서 커밋 대기가 55% 로 커진 것(6.3)과도 같은 방향이다 [추론].
- RK 고유 코드가 아니라 HA 로그 복사(copylogdb) 동작이다 — develop 에서도 같을 가능성이 높다 [추론, 미확인].
- **원인(왜 8배인지)은 아직 코드로 확인하지 않았다.** 후보: 마지막 부분 페이지를 요청마다 다시 쓰기, 헤더 페이지 갱신, 백그라운드 아카이브(`lgar_t`)·아카이브 생성 시 이중 기록.


### 6.7 [신규 발견] 시나리오 B 에서 복제 적용 실패가 반복된다 — 데이터는 결국 일치

B 긴 회차의 1초 멈춤(01:03:34)을 조사하다 applylogdb 에러 로그에서 **복제 적용 실패**를 발견했다.

```
log applier: failed to apply delete replication log. class: "dba.ha_t2", key: "7000760004",
             server error: -711, An object with the supplied attribute value does not exist
log applier: failed to apply insert replication log. class: "dba.ha_t2", key: "7000760004",
             server error: -670, Operation would have caused one or more unique constraint violations
```

| 환경 | 적용 실패 | 내역 |
|---|---|---|
| optdebug (`CUBRID_26246`, 11/9 17:24~) | 45건 | `ha_t2` 삭제 실패(-711) 24 · 삽입 실패(-670) 20 · 갱신 실패(-711) 1 |
| release (`CUBRID_26246_rel`, 11/10 00:27~) | **157건** | `ha_t2` 삽입 실패(-670) 78 · 삭제 실패(-711) 78 · 갱신 실패(-711) 1 |

- **[측정] 시나리오 B 를 따라잡는 동안에만, 그 구간 내내 흩어져서 난다** (00:34, 00:40, 00:46, 01:02~01:04). **A 에서는 0건.**
  applylogdb 재시작 직후에 몰리지 않으므로 "재시작 후 재적용" 문제는 아니다.
- **[측정] 같은 키에 "지우려니 없음(-711)" 과 "넣으려니 이미 있음(-670)" 이 수백 ms 간격으로 짝지어 난다.**
- **[측정] 그런데 측정 후 마스터·슬레이브 데이터는 일치한다** (`ha_t1` 100,000 행, `ha_t2` 6,136 행, id 순 덤프 줄 단위 비교).
  `db_ha_apply_info.fail_counter` = 157 로 로그와 같다.
- **[측정] 같은 B 부하를 병렬 브랜치(CBRD-27508, 10/28 develop 기반)에서 돌렸을 때는 적용 실패가 0건이었다** (재기동 정합성 테스트 B 회차, fail_counter 0 → 0).
- 대상은 모두 `ha_t2` — 부하에서 `INSERT ... ON DUPLICATE KEY UPDATE` (upsert) 와 기본키가 아닌 조건의 `DELETE FROM ha_t2 WHERE ref_id=?` 를 받는 테이블.
  B 에서는 `ref_id` 가 핫키 500개라 여러 세션이 같은 `ref_id` 의 행을 서로 지우고 다시 넣는다.

**해석 (추론, 미확인):** 한 트랜잭션 안의 "upsert → 같은 행 삭제" 또는 세션 간 "삭제 → 재삽입" 순서가 슬레이브에서 다르게 재생되고,
실패한 연산이 결과적으로 서로 상쇄돼 최종 데이터는 맞는 것으로 보인다. 다만

- 운영에서는 `fail_counter` 증가와 에러 로그로 **복제 이상 경보**가 된다.
- 다른 부하 패턴에서는 상쇄되지 않고 **데이터가 어긋날 수 있다.**

**원인 후보를 가르는 방법:**
1. **develop(RK 없음, 같은 10/20 기준) 빌드로 같은 B 부하** → 실패가 나면 RK 무관, 안 나면 RK 관련.
2. 실패한 키(예: `7000760004` = 세션 7, 회차 76, 순번 4)의 마스터 로그 레코드를 디코드해 기록된 연산 순서 확인.
3. upsert + `DELETE WHERE ref_id` 만으로 최소 재현 SQL 만들기.

RK 는 복제 로그를 쓰는 조건을 바꿨다 — 인덱스마다 `or_is_replication_candidate_key()` 이고 아직 `replicated` 가 아니면 기록 (`locator_sr.c:8012`).
upsert·삭제 경로에서 이 조건이 기록을 빠뜨리거나 중복시키는지가 1순위 확인 대상이다 [추론].

## 7. 다음 측정

| 측정 | 목적 |
|---|---|
| ~~릴리스 빌드로 처리량 재측정~~ | **완료 — 6절** |
| **B 복제 적용 실패 원인 (6.7)** | develop(10/20) 빌드 같은 B 부하로 RK 관련 여부 가르기, 실패 키의 마스터 로그 디코드, 최소 재현 SQL. **정합성 문제라 성능보다 우선** |
| **copylogdb 쓰기 증폭 원인 확인** | 코드(`log_writer.c` 등)로 왜 약 8배를 쓰는지. develop 에서도 같은지 |
| 실시간 복제 지연 (`ha_lag.sh`, A·B) | 평상시 부하에서 단일 스레드가 마스터를 따라가는지 |
| ~~따라잡기 중 프로세스별 디스크 쓰기~~ | **완료 — 6.6 (`ha_procio.sh`). 가장 큰 쓰기는 슬레이브 copylogdb** |
| 구성당 3회 반복 | B 의 회차 편차 (544~703) 범위 확정 |
| 시나리오 C·D | 운영에 가까운 부하, 대형 트랜잭션 |
