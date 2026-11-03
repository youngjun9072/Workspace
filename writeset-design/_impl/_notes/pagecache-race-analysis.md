---
tags: [코드맵, writeset, 병렬applylogdb, 크래시분석]
---

# 페이지 캐시 invalidate_pending 동시성 분석 — ER_LOG_PAGE_CORRUPTED(-81)

대상: `src/transaction/log_applier.c` (병합본, 미커밋). 비교 기준: committed HEAD `441aafed9`.
증상: 병렬 applylogdb 중 "logical log page NNN may be corrupted" (`ER_LOG_PAGE_CORRUPTED`, -81) 크래시.

## 한줄 결론

`invalidate_pending`을 **fix_count>0 상태에서 set** 하는데, 이 플래그를 **해제하는 네 지점이 모두 fix_count==0 도달을 전제**로 한다. reader가 어떤 페이지를 invalidate 하는 순간 그 페이지를 **병렬 워커가 fix 중(또는 워커가 페이지 경계를 넘으며 fix를 누수)** 이면, fix_count가 0으로 돌아오지 못해 `invalidate_pending=true`가 **영구히 남고**, 이후 그 페이지에 대한 모든 `la_get_page_buffer()`가 NULL을 반환(해당 버퍼는 self-heal도 decache도 안 됨) → reader가 10회 재시도(~3초) 소진 후 `ER_LOG_PAGE_CORRUPTED` → 크래시. HEAD에는 `invalidate_pending` 자체가 없었고 invalidate가 fix_count를 **무조건 0으로 강제**해 버퍼를 즉시 버렸기 때문에 이 상태가 생기지 않았다 — 이번 병렬화에서 들어온 "지연 invalidate"가 회귀 지점이다.

---

## 1. invalidate_pending 생명주기 (file:line)

필드 정의: `la_cache_buffer.invalidate_pending` — `log_applier.c:189`.

| 구분 | 위치 | 코드 맥락 | 조건 |
|---|---|---|---|
| **초기화 false** | `1331` `la_cache_buffer_replace` | 빈 버퍼 재사용 직전 | 스캔이 `fix_count==0`인 버퍼를 찾았을 때만 도달(1308) |
| **SET true** | `1477` `la_invalidate_page_buffer` | 진입 즉시 무조건 set, **그 다음** `--fix_count` | fix_count 값과 무관하게 먼저 set |
| 검사(NULL 반환) | `1390` `la_get_page_buffer` | 해시 히트 else 분기: `invalidate_pending || logical_pageid!=pageid` 이면 unlock 후 `return NULL` | — |
| **CLEAR false** | `1447` `la_release_page_buffer` | `if ((--fix_count)<=0)` 내부에서 mht_rem + pageid=0 + clear | **fix_count가 0 도달해야** |
| **CLEAR false** | `1485` `la_invalidate_page_buffer` | `if ((--fix_count)<=0)` 내부에서 mht_rem + pageid=0 + clear | **fix_count가 0 도달해야** |
| CLEAR false | `1518` `la_decache_page_buffers` | 버퍼 폐기 시 | 바로 위 `if (fix_count>0) continue;`(1510) 통과 = **fix_count==0** |
| CLEAR false | `1331` `la_cache_buffer_replace` | 위 초기화 | 스캔이 **fix_count==0** 버퍼 선택 |

핵심 불변식(코드로 증명): **네 CLEAR 지점이 전부 `fix_count==0`를 전제로 한다.** 반면 SET(1477)은 fix_count를 보지 않고 먼저 켠다. 따라서 "`invalidate_pending=true`인데 fix_count가 끝내 0으로 안 돌아오는" 상태가 만들어지면, 그 플래그를 끌 코드 경로가 **존재하지 않는다**.

SET/검사 호출자:
- `la_invalidate_page_buffer` 호출자 — reader 측: `9573, 9627, 9663, 9669, 9687, 9723, 9783`(모두 `la_apply_log_file` 메인 루프), `2867`(`la_does_page_exist`, reader가 9577에서 호출).
- `la_get_page_buffer`(검사) 호출자 — reader: `9514`(메인 루프), `2855`(`la_does_page_exist`). 워커: `la_get_page`(1416) 경유 → `la_apply_update_log:5412`, `la_apply_insert_log:5614`, 그리고 페이지 경계 매크로(아래 2절).

---

## 2. 동시성 위험 구간 (락 밖 접근 / 멀티콜 시퀀스)

`cache_pb->mutex`는 **개별 함수 1회 호출 내부만** 보호한다. 보호되지 않는 것:

1. **fix → 사용 → release/invalidate의 멀티콜 시퀀스.** reader는 `9514`에서 페이지를 fix 하고 `pg_ptr=&log_buf->logpage`(9637)로 **락 없이** 내부 루프(9639~)에서 레코드를 읽는다. 이 사이 다른 스레드가 같은 버퍼를 `la_invalidate_page_buffer` 할 수 있다.
2. **reader와 병렬 워커가 동일한 전역 `la_Info.cache_pb`를 공유.** 워커 경로 `la_parallel_worker_execute(6351) → la_apply_repl_log(6098) → la_apply_update_log(5395)/la_apply_insert_log → la_get_recdes(4885) → la_get_log_data(4224) → la_get_page(1404)`. 전부 같은 싱글턴 캐시(`cache_pb = la_Info.cache_pb`, 1361/1434/1469/1496)를 fix/release 한다.
3. **★ fix 누수(leak) — 페이지 경계 넘김.** `la_get_log_data` 안의 매크로 `LA_LOG_READ_ADVANCE_WHEN_DOESNT_FIT`(126)·`LA_LOG_READ_ALIGN`(136)는 레코드가 페이지 끝을 넘으면 `pgptr = la_get_page(++pageid)`(129/140)로 **다음 페이지를 추가로 fix** 한다. 그런데 `la_apply_update_log`는 끝에서 `la_release_page_buffer(old_pageid)` **한 장만**(5489) 반납한다. `la_apply_insert_log`도 동일(5614 fix, 5685 old_pageid만 release). 즉 **멀티페이지 레코드를 적용한 워커는 2번째 이후 페이지의 fix를 영구히 누수**한다. (HEAD에서도 존재하던 누수지만, HEAD invalidate가 fix_count를 강제 0으로 밀어 매번 청소했기에 무해했다 — 5절.)

보호되는 것(배제): fix_count 증감·invalidate_pending set/clear·mht_put/rem은 각각 mutex 안에서 원자적. 버퍼 메모리 재사용(`la_cache_buffer_replace`)은 `fix_count==0`만 선택(1308)하므로, reader가 fix 들고 있는 버퍼가 다른 페이지로 덮여 use-after-free 되는 일은 없다 → 그래서 증상이 SIGSEGV가 아니라 "corrupted" 논리 오류로 나타난다.

---

## 3. persistent-NULL 재현 시나리오 (확정 — 코드로 증명)

전제: 병렬 모드, reader가 page P를 처리하며 trid T의 COMMIT 레코드를 만나 워커에게 T의 UPDATE 적용을 디스패치. T의 대상 레코드(`item->target_lsa`)도 page P에 있음.

```
T0  reader: la_get_page_buffer(P)        P.fix=1, hash에 등록           [9514]
T1  reader: COMMIT 읽고 워커에 T 디스패치 (pg_ptr로 내부 루프 진행)     [9639~]
T2  worker: la_apply_update_log → la_get_page(P)
            → la_get_page_buffer(P) 해시히트, P.fix=2                   [5412→1397]
T3  reader: 가용 로그 끝 도달(append_lsa 따라잡음 / is_end_of_record)
            → la_invalidate_page_buffer(P):
               invalidate_pending=true (먼저)                          [1477]
               --fix_count → 1  (>0 이므로 drop 안 함)                 [1478]
            log_buf=NULL 로 두고 내부 루프 break                       [9783/9663]
            ── 이 순간 P는 "poisoned": hash에 그대로, pageid=P,
               invalidate_pending=true, fix=1(워커가 보유) ──
T4  reader: 외부 루프 재진입, 아직 final_lsa.pageid==P (다음 레코드
            offset 그대로) → la_get_page_buffer(P)                     [9514]
            해시히트, invalidate_pending==true → return NULL           [1390]
T5  reader: 재시도 루프 (retry<10, usleep 300ms+α) 반복 → 매번 NULL   [9548]
T6  worker: 적용 완료 후 la_release_page_buffer(P)
            --fix_count → 0, invalidate_pending였으므로
            mht_rem + pageid=0 + clear  → P 비로소 회수               [1441-1452]
```

- **T6가 T5의 재시도 예산(10회 ≈ 3초) 안에 오면** reader 회복(다음 fetch는 해시 미스 → replace → refetch).
- **T6가 늦거나 오지 않으면**(워커가 락 대기/플러시로 느리거나, ★2절-3의 누수로 fix가 애초에 0으로 안 돌아오면) → poisoned 지속 → reader가 `retry_count >= LA_GET_PAGE_RETRY_COUNT`에서 `ER_LOG_PAGE_CORRUPTED` 발생(9555) → `la_applier_need_shutdown=true` → 크래시.

**결정적(누수) 변형 — 영구 persistent-NULL, 반증 불가:**
워커가 page P에서 시작한 레코드가 P+1로 넘어가면(2절-3) P+1에 누수 fix가 남는다. 이후 reader가 P+1을 invalidate(`la_does_page_exist(P+1)`의 2867, 또는 메인 루프)하면 invalidate_pending=true + fix는 누수분(≥1)만큼 남아 **절대 0 도달 불가** → P+1 영구 poisoned. reader가 P+1에 도달하는 순간 무조건 corrupted. (self-heal 없음: 아래) 이 경로는 "워커 타이밍"에 의존하지 않으므로 재시도로도 못 넘는다.

보강 증거(왜 재시도·자가치유가 안 먹나):
- `la_get_page_buffer` 해시히트 분기(1388-1395)는 NULL 반환만 하고 **poisoned 엔트리를 mht_rem 하지 않는다.** 그래서 재시도해도 같은 엔트리에 계속 걸린다.
- `la_decache_page_buffers`는 `fix_count>0` 버퍼를 건너뛴다(1510) → poisoned+누수 버퍼를 청소 못 함.
- `la_cache_buffer_replace`는 `fix_count==0` 버퍼만 재사용(1308) → 역시 손 못 댐.
  즉 네 청소 경로 전부 막혀 상태가 고착된다.

보고된 증상과의 정합: "page 181 offset 9496(trid 427 COMMIT) 정상 → 직후 offset 12528에서 la_get_page_buffer(181) NULL." T1에서 COMMIT(offset 9496)을 읽어 trid 427을 워커에 넘기고, T3에서 181을 invalidate+break, T4에서 **같은 181을 재fetch**(다음 레코드 offset 12528은 여전히 181 내부)하는데 워커가 181을 fix 중이라 NULL — 시나리오와 정확히 일치.

---

## 4. fix_count ↔ invalidate_pending 상호작용 정리

- `la_invalidate_page_buffer`(1467): `invalidate_pending=true`를 **fix_count 검사 전에** set(1477). `--fix_count<=0`이면 그 자리에서 drop+clear(1480-1488); `>0`이면 **set만 남기고 반환** → 지연 invalidate. 이 "지연"은 "남은 fixer가 반드시 release 해서 fix_count를 0으로 만든다"는 가정에서만 안전하다. 2절-3의 누수가 이 가정을 깬다.
- `la_release_page_buffer`(1431): `--fix_count<=0`이고 invalidate_pending면 drop+clear(1444-1452). 즉 **마지막 fixer의 release가 청소 책임자**. 그 마지막 release가 영영 안 오면 고착.
- SET 시점에 fix_count가 2 이상(reader+워커, 또는 누수 다수)이면 1회 decrement로는 0이 안 되어 반드시 poisoned 창(T3~T6)이 생긴다. 창의 길이는 "남은 fixer가 release할 때까지"이고, 누수면 ∞.

---

## 5. HEAD(441aafed9) 대비 차이 = 회귀 지점

| 함수 | HEAD(`441aafed9`) | 병합본 | 영향 |
|---|---|---|---|
| `la_invalidate_page_buffer` | `fix_count=0` **무조건 강제**, mht_rem, pageid=0 (HEAD 1458-1460) — fix_count 보지 않고 즉시 버림 | `invalidate_pending=true` 후 `--fix_count<=0`일 때만 버림, 아니면 플래그만 남김(1477-1488) | HEAD는 지연 없음·누수 fix까지 매 invalidate마다 청소. 병합본은 지연 상태 신설 |
| `la_get_page_buffer` 해시히트 분기 | `logical_pageid!=pageid`면 **`mht_rem`**(self-heal) 후 NULL(HEAD 1375-1380) | `invalidate_pending || logical_pageid!=pageid`면 **mht_rem 없이** NULL(1390-1394) | HEAD는 헤더 불일치 엔트리를 제거해 다음 fetch가 refetch. 병합본은 엔트리를 남겨 persistent-NULL 2번째 경로(헤더 불일치)까지 신설 |
| `la_release_page_buffer` | fix_count 감소 + recently_free만(HEAD 1427-1432) | 거기에 invalidate_pending 청소 책임 추가(1444-1452) | release가 유일 청소 책임자가 됨 |
| 필드 `invalidate_pending` | **없음** | 신설(189) | — |

정리: HEAD는 (a) invalidate가 fix_count를 강제 0으로 밀어 **누수 fix를 매번 흡수**했고, (b) 해시히트+헤더불일치를 **mht_rem으로 자가치유**했으며, (c) `invalidate_pending` 게이트가 없어 캐시에 올바른 페이지가 있으면 **항상 fix+반환**(persistent-NULL 불가능)이었다. 병렬화하면서 "워커가 fix 중인 페이지를 reader가 즉시 버리면 워커가 freed 버퍼를 쓰게 되니 지연 invalidate가 필요"했는데, 그 지연을 **(a) 누수 fix와 (b) 자가치유 제거**와 결합시키면서 고착 가능 상태를 만들었다.

---

## 6. 수정 방향 제안 (개념)

1. **fix 누수 제거(근본).** `la_get_log_data`의 페이지 경계 매크로가 추가로 fix한 페이지를 적용 종료 시 전부 release 하도록 수정. 현재 `old_pageid` 한 장만 반납(5489/5685)하는 구조를, "이 적용이 fix한 모든 pageid" 추적 후 일괄 release로 바꾼다. 누수가 사라지면 지연 invalidate의 "언젠가 fix_count==0 도달" 가정이 성립해 고착이 사라진다.
2. **해시히트 self-heal 복원.** `la_get_page_buffer` 해시히트 분기에서 `invalidate_pending` 또는 헤더 불일치면 NULL 반환 전에 `mht_rem(cache_buffer->pageid)` (fix_count==0일 때) 하여 다음 fetch가 replace로 refetch 하게 한다. 단, fix_count>0(워커 보유 중)이면 메모리 재사용은 막아야 하므로 "해시에서만 떼고 버퍼는 fixer가 release 때 회수" 분리가 필요.
3. **재시도를 corrupted로 승격하지 않기.** 병렬 모드에서 poisoned/경합으로 인한 일시 NULL은 정상이므로, `la_apply_log_file`의 10회·3초 예산(9548/87행 `LA_GET_PAGE_RETRY_COUNT`)을 병렬 모드에서 늘리거나, "invalidate_pending로 인한 NULL"과 "실제 디스크 corrupted"를 구분해 전자는 corrupted로 집계하지 않도록 한다. (1·2 없이 이것만 하면 누수 경로는 여전히 영구 고착 → 완화일 뿐.)
4. **invalidate 소유권 명확화.** reader가 아직 fix 들고 있는(pg_ptr 사용 중) 페이지를 워커가 fix한 상태에서 reader가 invalidate하는 패턴 자체를 재검토 — reader 페이지 life-cycle과 워커 페이지 life-cycle을 분리(워커 전용 fetch 또는 스냅샷 복사)하면 교차 poisoning이 구조적으로 사라진다.

우선순위: **1(누수 제거)이 근본 해결**이고 2는 2차 persistent-NULL(헤더 불일치) 차단, 3은 완화책.

---

## 부록 — 핵심 좌표

- 필드: `log_applier.c:189`
- `la_cache_buffer_replace` 1292 (clear 1331, fix_count==0 선택 1308)
- `la_get_page_buffer` 1359 (검사 1390, self-heal 제거된 else분기 1388-1395)
- `la_get_page` 1404 (NULL이면 무한 재시도 1414-1418 — 워커는 여기서 corrupted 안 냄)
- `la_release_page_buffer` 1432 (clear 1444-1452)
- `la_invalidate_page_buffer` 1467 (SET 1477, 지연조건 1478)
- `la_decache_page_buffers` 1493 (fix_count>0 skip 1510)
- 에러 발생점: `la_apply_log_file` 9514 fetch, 9548 재시도, 9555 `ER_LOG_PAGE_CORRUPTED`
- 누수 매크로: 126 `LA_LOG_READ_ADVANCE_WHEN_DOESNT_FIT`, 136 `LA_LOG_READ_ALIGN` (la_get_page 129/140)
- 워커 경로: 6351 → 6098 → 5395(update, release 5489)/insert(release 5685) → 4885 → 4224
- HEAD 비교: `git show 441aafed9:src/transaction/log_applier.c` — invalidate 1444-1462, get_page_buffer self-heal 1375-1380
