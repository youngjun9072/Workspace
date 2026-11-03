# PoC vs 병합본 역추적 분석 — 페이지 캐시 크래시 / 재시작 복구 error-skip

대조 대상
- 병합본(현재 문제): `/home/youngjun/Workspace/cubrid-applier/src/transaction/log_applier.c` (미커밋, base develop 441aafed9 + 측정dirty + idea-3). 총 10567행.
- PoC(검증됨): `feature/writeset_error_skip` SHA `0405c9bd`. `git show feature/writeset_error_skip:src/transaction/log_applier.c`. 총 13798행.
- 두 결함 모두 **PoC에는 안전장치가 있었고 병합본(idea-3 재구성)이 그 장치를 빼먹은** 것으로 확정. 아래 file:line은 병합본=cubrid-applier 작업트리, PoC=위 SHA 기준.

---

## 결론 한 줄
① 페이지캐시 크래시 = 병합본이 PoC에 없던 `invalidate_pending`을 새로 넣었는데 캐시-히트 경로에 **자가치유(mht_rem 후 refetch)가 빠져** 리더가 영구 NULL을 받아 `ER_LOG_PAGE_CORRUPTED`를 올림. ② 재시작 데이터 처리 = PoC의 **복구창 error-skip(recovery_boundary_lsa / in_recovery_window)을 병합본이 통째로 이식 안 함** → 재적용 시 중복키·대상없음이 전부 `fail_count`로 집계(무성 skip 아님).

---

## 1. 페이지 캐시 동시성 — 병합본이 빠뜨린 자가치유

### 1-1. 구조체 필드 diff
- PoC `struct la_cache_buffer` (PoC 200-211): `fix_count`, `recently_free` 만. **`invalidate_pending` 없음**.
- 병합본 `struct la_cache_buffer` (병합본 185-196): `fix_count`, `recently_free`, **`invalidate_pending`(189행, 신설)**.

즉 `invalidate_pending`은 PoC에 존재하지 않던 메커니즘을 병합본(idea-3)이 새로 도입한 것이다. "PoC가 mht_rem로 자가치유하던 걸 병합본이 invalidate_pending으로 바꿔 persistent NULL을 만든다"는 가설은 **사실로 확인**.

### 1-2. 캐시-히트 경로: PoC는 자가치유, 병합본은 영구 NULL
PoC `la_get_page_buffer` 캐시-히트 분기 (PoC 4525-4539):
```
else {               /* mht_get 히트 */
  if (cache_buffer->logpage.hdr.logical_pageid != pageid) {
      (void) mht_rem (cache_pb->hash_table, &cache_buffer->pageid, NULL, NULL);  /* ← 스테일 엔트리 제거 */
      ... return NULL;                 /* 다음 호출은 MISS 경로로 떨어져 la_cache_buffer_replace 재fetch */
  }
}
```
병합본 `la_get_page_buffer` 캐시-히트 분기 (병합본 1388-1395):
```
else {
    if (cache_buffer->invalidate_pending || cache_buffer->logpage.hdr.logical_pageid != pageid) {
        pthread_mutex_unlock (&cache_pb->mutex);
        return NULL;                   /* ← mht_rem 없음. 스테일/무효 엔트리를 해시에 그대로 둔 채 NULL */
    }
}
```
병합본은 `invalidate_pending`이 서 있는 버퍼를 **해시에서 빼지 않고 NULL만 반환**한다. 같은 pageid로 다시 호출해도 또 같은 엔트리에 히트해 또 NULL → **영구 NULL 루프**. PoC는 logical_pageid 불일치 시 `mht_rem`으로 엔트리를 비워 다음 호출이 MISS→refetch로 자가치유한다(병합본은 logical_pageid 불일치에도 mht_rem을 안 함 — 1390행은 두 조건을 합쳐 그냥 NULL).

### 1-3. `invalidate_pending`이 영구히 서는 지점
병합본 `la_invalidate_page_buffer` (병합본 1467-1490):
```
cache_buffer->invalidate_pending = true;
if ((--cache_buffer->fix_count) <= 0) {         /* 나 혼자 fix했으면 */
    ... mht_rem ...; invalidate_pending = false; pageid = 0;   /* 즉시 정리 */
}
/* 그러나 fix_count 가 아직 >0 (다른 스레드가 fix 보유) 이면
   invalidate_pending=true 인 채로 해시에 남는다 */
```
리더+워커가 페이지 캐시를 공유하는 병렬 구조에서, 한 스레드가 invalidate를 걸 때 다른 스레드가 같은 버퍼를 fix 중이면 버퍼는 `invalidate_pending=true`로 해시에 잔류한다. 이걸 지우는 건 fix 보유자의 `la_release_page_buffer`(병합본 1444-1452)뿐이다. 그 release가 늦거나, invalidate/release 짝이 어긋나면 잔류가 영구화된다.

PoC `la_invalidate_page_buffer` (PoC 4604-4622)는 정반대다:
```
if (cache_buffer->pageid != 0) mht_rem (...);   /* 조건 없이 해시에서 제거 */
cache_buffer->fix_count = 0;                     /* 다른 fix 보유자 무시하고 0 */
cache_buffer->recently_free = false;
cache_buffer->pageid = 0;
```
PoC는 "invalidate = 지금 즉시 캐시에서 떨군다"로 단순하다. 이론상 타 스레드 fix를 무시하지만, PoC 설계에서 invalidate 호출 지점은 호출자가 단독 fix 보유자인 자리였다(추정 — 호출부 맥락상). 병합본은 이 "무시" 대신 `invalidate_pending` 지연 정리로 "안전하게" 바꾸려다, 리더 기아(영구 NULL)를 새로 만든 것이다.

### 1-4. 그 NULL이 ER_LOG_PAGE_CORRUPTED로 올라오는 인과
리더 루프 `la_apply_log_file`가 페이지를 **직접** `la_get_page_buffer`로 받는다 (병합본 9514):
```
log_buf = la_get_page_buffer (la_Info.final_lsa.pageid);
if (log_buf == NULL) {
    ... retry_count++ < LA_GET_PAGE_RETRY_COUNT 동안 usleep 재시도 ...
    er_set (... ER_LOG_PAGE_CORRUPTED, 1, la_Info.final_lsa.pageid);   /* 병합본 9555 */
    error = ER_LOG_PAGE_CORRUPTED; la_applier_need_shutdown = true; break;
}
```
리더는 `la_get_page`의 `while(NULL)` 재시도 루프가 아니라 직접 호출 + 유한 재시도만 한다. invalidate_pending이 영구 NULL을 만들면 재시도 횟수를 소진하고 9555행에서 `ER_LOG_PAGE_CORRUPTED`로 크래시. (PoC도 리더는 `la_get_page_buffer` 직접 호출 — PoC 12646 — 이지만, PoC의 get_page_buffer는 "영구 NULL" 상태를 만들지 않으므로 재시도가 결국 성공한다.)

### 소결 — 페이지캐시에서 병합본이 빠뜨린 안전처리
- (A) 캐시-히트 무효 엔트리의 **mht_rem 자가치유 누락** (병합본 1390 vs PoC 4532). → 영구 NULL의 직접 원인.
- (B) `invalidate_pending` 지연정리가 타 스레드 fix 잔류 시 해시에 무효 엔트리를 남김 (병합본 1467-1490). PoC엔 이 메커니즘 자체가 없음.

---

## 2. 재시작 복구 error-skip — 병합본에 통째로 부재

### 2-1. PoC 구현 전수 (병합본엔 grep 0건)
`recovery_boundary_lsa` / `in_recovery_window` — 병합본 log_applier.c 전체 grep **0건**(선언조차 없음). PoC는 다음을 갖춤:

1. 경계 캡처 (PoC 5192, `la_apply_info_from_catalog` 복원 직후):
   ```
   LSA_COPY (&la_Info.recovery_boundary_lsa, &apply_info.final_lsa);
   ```
   재시작 시 복원된 final_lsa(=재개 지점)를 복구창 상한으로 저장. apply info 행이 없으면(신규기동) NULL → 창 비어있음.
2. 창 판정, 트랜잭션당 1회 (PoC 9581-9583, `la_apply_repl_log` 진입부):
   ```
   stats->in_recovery_window = (!LSA_ISNULL (&la_Info.recovery_boundary_lsa)
       && LSA_LT (&la_Info.last_committed_lsa, commit_lsa)
       && LSA_LE (commit_lsa, &la_Info.recovery_boundary_lsa));
   ```
   "이 프로세스가 커밋한 지점(last_committed_lsa)보다 앞이면서 재시작 경계 이하" = 마스터에선 커밋됐으나 이 프로세스 재시작 전이라 슬레이브에 이미 반영됐을 수 있는 구간.
3. 에러 억제 (PoC 8277-8298, flush 에러 처리):
   ```
   if (stats->in_recovery_window == true) {
       if (LC_IS_FLUSH_INSERT)        recovery_skip = (error_code == ER_BTREE_UNIQUE_FAILED);
       else if (UPDATE || DELETE)     recovery_skip = (error_code == ER_OBJ_OBJECT_NOT_FOUND
                                                       || error_code == ER_HEAP_UNKNOWN_OBJECT);
   }
   if (recovery_skip) { stats->recovery_skipped_counter++; er_log_debug(...); }   /* er_set/fail 없음 */
   else              { er_set(... la_err_code ...); stats->fail_counter++; }
   ```
   창 안에서 화이트리스트(INSERT 중복키 / UPDATE·DELETE 대상없음)만 조용히 skip, 집계는 별도 `recovery_skipped_counter`. 그 외 모든 에러와 창 밖 에러는 그대로 보고.
4. 리셋 (PoC 11053): `LSA_SET_NULL (&la_Info.recovery_boundary_lsa);`
   추가로 statement 경로(DDL/statement DML)는 화이트리스트 미정이라 **의도적으로 창 미적용**(PoC 9480-9485 주석, `la_apply_statement_log` 에러는 항상 보고).

### 2-2. 병합본의 동일 지점 = 무조건 fail
병합본 flush 에러 처리 `la_apply_commit_log`(추정 함수명) (병합본 5078-5112):
```
if (LC_IS_FLUSH_INSERT)  la_err_code = ER_HA_LA_FAILED_TO_APPLY_INSERT; ...
...
er_stack_push ();
er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, la_err_code, 4, class_name, pkey_str,
        flush_err->error_code, server_err_msg);     /* 병합본 5108 — 무조건 */
er_stack_pop ();
stats->fail_count++;                                 /* 병합본 5112 — 무조건 */
```
PoC가 `recovery_skip` 분기를 끼워 넣은 바로 그 자리(연산별 err_code 선택 직후)에 병합본은 **게이트 없이** er_set + fail_count++를 한다. 워커측 per-item 경로(병합본 6226 `la_ignore_on_error==false && la_retry_on_error` — PoC 9669와 동일)도 복구창 개념이 없어 동일.

### 2-3. 인과: 재적용 unique 위반이 "failed"로 뜨는 이유
재시작 시 committed_lsa로 rewind 후 경계 구간(재시작 전 워커가 비순차로 이미 슬레이브에 커밋해 둔 트랜잭션들)을 다시 적용한다. 그 행들은 슬레이브에 이미 존재:
- INSERT → `ER_BTREE_UNIQUE_FAILED`
- UPDATE/DELETE 대상 → `ER_OBJ_OBJECT_NOT_FOUND` / `ER_HEAP_UNKNOWN_OBJECT`
PoC는 이걸 복구창 내 정상(중복 적용)으로 보고 무성 skip. 병합본은 복구창이 없어 **전부 `fail_count` 집계 + er_set 로그**로 올린다. 이것이 "재시작 복구 시 fail 폭증 / 재적용 unique 위반이 failed로 뜨는" 직접 원인.
- 추정(내 스코프 밖, restart-recovery 에이전트 확인 필요): `la_restart_on_bulk_flush_error`(병합본 5114)가 특정 에러에서 reconnect를 트리거하면, 창 밖 처리로 올라온 중복키가 배치 재연결을 유발해 **아직 커밋 안 된 선행 트랜잭션 롤백 → 실제 데이터 유실**로 번질 수 있음. 에러셋 미확인이라 단정 않음.

---

## 3. frontier / committed_lsa / required_lsa 대조

두 브랜치 모두 **gap-free(연속) frontier**로 committed_lsa를 전진시킨다 — 설계 동일, 위치만 다름.
- 병합본: 별도 모듈로 분리. `log_applier_gate.cpp:68-78 la_dependency_gate_advance_frontier` — `order.front().completed`인 동안만 pop하며 frontier를 **등록순서대로 연속** 전진. collect 말미에 `la_coordinator_frontier`로 읽어 committed_lsa를 끌어올림(병합본 6576-6580).
- PoC: log_applier.c 내 인라인. `la_Gate_frontier` / `la_gate_advance_frontier`(PoC 1698-1719) — 완료집합에서 연속 하한만 전진, 그 이하는 prune. committed_lsa 승격도 "frontier가 dispatch순서 아닌 gap-free로만"(PoC 2528-2553, 비단조면 er_log + assert).

따라서 **"frontier 176인데 워커는 181까지 커밋"은 버그가 아니라 writeset 비순차 모델의 정상 속성**이다. 워커는 의존성만 맞으면 비순차로 물리 커밋하지만, 재시작 체크포인트인 committed_lsa는 선행 트랜잭션이 다 끝나야 연속으로만 올라간다(177~180 미완이면 181 완료돼도 frontier=176).
- **PoC도 이 괴리를 피하지 않는다. 받아들이고, 재시작 시 177~181 재적용으로 생기는 중복을 복구창 error-skip으로 흡수한다.** 병합본은 괴리(gap-free frontier)는 그대로 물려받고 **흡수장치(복구창)만 빠뜨려서** 재적용이 실패로 집계되는 것.
- required_lsa(LWM)/committed_rep_lsa 산출은 두 브랜치 모두 유지(병합본 6569-6573 committed_rep_lsa 최대값 전진, `la_find_required_lsa` 양쪽 존재). 이 축에서 병합본이 빠뜨린 안전장치는 발견되지 않음.

---

## 4. 병합본이 PoC 대비 빠뜨린 안전장치 (우선순위)

1. **[Critical] 복구창 error-skip 전체 부재** — `recovery_boundary_lsa`(PoC 5192 set, 11053 reset) + `in_recovery_window`(PoC 9581 판정) + flush에러 억제(PoC 8277-8298). 병합본 grep 0건. 재적용 중복키/대상없음이 전부 `fail_count`(병합본 5108-5112, 6226). → 재시작 복구 fail 폭증, 데이터 처리 괴리.
2. **[Critical] 캐시-히트 무효 엔트리 자가치유(mht_rem) 누락** — 병합본 1390은 `invalidate_pending || logical_pageid 불일치` 시 mht_rem 없이 NULL만(PoC 4532는 mht_rem로 다음 호출 refetch 유도). → 리더 영구 NULL → `ER_LOG_PAGE_CORRUPTED`(병합본 9555).
3. **[High] `invalidate_pending` 지연정리의 잔류 위험** — 병합본 1467-1490이 타 스레드 fix 보유 시 무효 엔트리를 해시에 남김. PoC엔 메커니즘 자체가 없고 invalidate는 즉시 drop(PoC 4604-4622). 2번과 결합해 영구 NULL을 지속시킴.
4. **[참고] statement 경로 창 미적용은 PoC도 의도적 제외** (PoC 9480-9485) — 병합본에 이식한다면 DML/DDL statement 화이트리스트는 별도 필요. 안전장치 누락이라기보다 PoC가 명시적으로 남겨둔 TODO.

### 이식 방향 (지목만, "그대로 복붙" 아님)
- 2·3번: 병합본 `la_get_page_buffer` 캐시-히트 분기에 무효 엔트리 mht_rem 자가치유를 넣거나, `invalidate_pending` 메커니즘을 PoC식 즉시-drop + 호출부 단독fix 불변식으로 되돌린다. 리더가 유한 재시도 후 corrupted로 죽는 경로(병합본 9514-9558)와의 상호작용 재검토 필요.
- 1번: PoC 5192/9581/8277-8298/11053 네 지점에 대응하는 코드를 병합본의 (재시작 복원부 / `la_apply_repl_log` 진입부 / flush에러 처리 5078-5112 / 종료부)에 이식. 병합본은 flush에러가 코디네이터 collect 경로(5033~)로 모이므로 `in_recovery_window`를 트랜잭션 stats에 실어 나르는 설계 확인 필요.

---
근거: 병합본 = cubrid-applier 작업트리(미커밋), PoC = `feature/writeset_error_skip` @ `0405c9bd`. 모든 행번호는 조사 시점 스냅샷. "추정" 표기 외는 코드 직접 확인.
