# [WSET] 측정 트레이스 PoC-base 이식 기록

대상 브랜치: `feature/CBRD-27508-parallel-applylogdb-writeset` @ 46e7d29a6 (워킹트리, 미커밋)
백업 출처: `backup/CBRD-27508-dirty-20261004`
작업일: 2026-10-04

> **범위 확장(2026-10-04 2차)**: 최초 슬레이브 생애주기 16종 이식 후, 사용자 지시로 마스터
> writeset/충돌검사·히스토리 생애주기·SYSOP_END(양쪽)·게이트 pending 쌍·슬레이브 항목오류까지
> 확장했다. §7~§11 참조. 모든 라인은 `[WSET] <role> <event> key=value ...` 규칙과 단일 게이트
> `ha_writeset_trace_level`을 유지한다(다른 프리픽스 금지).

백업의 모듈형 applier(+coordinator)에 있던 `[WSET]` er_log 트레이스를, 리셋된 PoC 단일파일
applier(`src/transaction/log_applier.c`)의 등가 생애주기 지점으로 이식했다. ha_bench 트레이스 파서가
백업의 라인 포맷을 정확히 grep 하므로, **프리픽스/필드명/필드순서는 백업과 1:1로 보존**하고 값만 PoC
상태에서 가져왔다.

## 1. 포팅한 트레이스 매핑표 (16종)

백업 log_applier.c 21개 사이트 중 SYSOP/SERIAL(=idea-3, 미재이식) 라인은 제외. 18종 중 coordinator
apply begin/end 2종은 PoC에 산 경로가 없어 스킵(§4). 나머지 16종을 이식.

| 트레이스 종류 | 게이트 레벨 | 백업 앵커(의미) | 현재 삽입 위치 file:line | dispatch/worker 값 출처 |
|---|---|---|---|---|
| reader label | ≥2 | `LOG_DUMMY_WSET_LABEL` 디코드 후 홀더 세팅 | log_applier.c:10547 (`case LOG_DUMMY_WS_LABEL`, `la_retrieve_ws_label` 뒤) | — |
| reader commit | ≥1 | `LOG_COMMIT`에서 커밋 조립, has_label/dependency 확정 | log_applier.c:10436 (`case LOG_COMMIT`, `la_gate_order_push` 뒤·디스패치 판정 전) | items=`task.apply->num_items`, has_label=진입 시 `la_ws_label_trid==trid` 캡처 |
| reader abort | ≥1 | `LOG_ABORT` 관측 | log_applier.c:10485 (`case LOG_ABORT`, free 전) | items=`la_find_apply_list(trid)->num_items` |
| reader schedule | ≥1 | `try_schedule_task` 직후(=워커 큐 투입, status/dispatch 확정) | log_applier.c:1936 (`la_gate_dispatch_now`, `task.seq=dispatch_seq` 뒤) | dispatch=`dispatch_seq`, status=신규 `sched_status` 인자 |
| reader result | ≥1 | 회수한 결과가 에러일 때 | log_applier.c:2531 (`la_retire_ready_results`, `result->error!=NO_ERROR` 분기) | worker=`entry->worker_idx` |
| reader retire | ≥1 | 태스크 정상 은퇴 | log_applier.c:2541 (`la_retire_ready_results`, 에러체크 통과 직후) | worker=`entry->worker_idx`, dispatch=`entry->seq` |
| worker apply begin | ≥1 | `la_apply_repl_log` 직전 | log_applier.c:3441 (워커 루프, apply 호출 전) | worker=`worker-la_apply_Workers`, dispatch=`task.seq` |
| worker apply end | ≥1 | `la_apply_repl_log` 직후 | log_applier.c:3457 (apply 호출 후) | rows=`total_rows`, error=`result.error` |
| worker flush begin | ≥1 | `la_flush_repl_items` 직전 | log_applier.c:3482 (final_flush 블록 진입) | unflushed=`result.stats.num_unflushed` |
| worker flush end | ≥1 | flush 직후 | log_applier.c:3496 (final_flush 블록 끝) | error=`result.error` |
| worker commit begin | ≥1 | `db_commit_transaction` 직전 | log_applier.c:3565 (`la_commit_transaction` 전) | dispatch=`task.seq` |
| worker commit end | ≥1 | 커밋 직후 | log_applier.c:3575 (`la_commit_transaction` 후) | error=`result.error` |
| coordinator flush begin | ≥1 | apply-info 플러시 직전 | log_applier.c:3740 (`la_reader_commit_apply_info` 진입) | unflushed=`la_Info.num_unflushed`, final_lsa=`la_Info.final_lsa` |
| coordinator flush end | ≥1 | apply-info 플러시 직후 | log_applier.c:3749 (`la_update_ha_last_applied_info` 뒤) | error=`res>0?NO_ERROR:res` |
| coordinator commit begin | ≥1 | `db_commit_transaction` 직전 | log_applier.c:3760 (`res>0` 분기 내) | committed_rep_lsa=`la_Info.committed_rep_lsa` |
| coordinator commit end | ≥1 | 커밋 직후 | log_applier.c:3768 | error=`commit_error` |

주: 삽입으로 행번호가 이동하므로 위 수치는 이식 완료 상태의 행번호다.

### 포맷 충실도
16개 포맷 문자열 모두 백업과 프리픽스·필드명·필드순서·`%` 지정자(`%lld|%d`, `%zu`, `%llu`,
`%s`)까지 동일하다. 특히 **키 이름은 변경하지 않았다**: PoC 내부 변수는 `dependency_is_read`지만
라인의 키는 백업대로 `dependency_is_ref`로 출력(값만 PoC의 `dependency_is_read`에서 공급).

## 2. 게이팅 메커니즘

백업은 매크로가 아니라 **직접 `prm_get_integer_value(PRM_ID_HA_WRITESET_TRACE_LEVEL)` 가드 +
`_er_log_debug(ARG_FILE_LINE, ...)`** 방식이다(writeset.cpp 쪽만 `WSET_TRACE` 매크로 사용, applier는
아님). 멀티-사이트 함수는 함수 상단에서 `int trace_level`로 한 번 캐시하고 단일-사이트는 인라인
호출한다. 이 패턴을 그대로 복제:

- `la_apply_repl_log` 워커 루프: 루프 본문 상단에 `int trace_level = prm_get_integer_value(...)` 캐시 → 6개 워커 사이트에서 `if (trace_level >= 1)`.
- `la_reader_commit_apply_info`: 함수 상단 `int trace_level` 캐시 → coordinator 4개 사이트.
- 리더 스위치(label/commit/abort) 및 retire(result/retire), `la_gate_dispatch_now`(schedule): 인라인 `prm_get_integer_value(...) >= N`.

레벨 임계값도 백업과 동일: reader label만 `>= 2`, 나머지 15종은 `>= 1`.
`_er_log_debug`는 `PRM_ID_ER_LOG_DEBUG`를 우회하므로 측정빌드에서 일반 debug 로그를 끈 채 `[WSET]`만
남긴다(백업과 동일).

## 3. 시스템 파라미터 이식 (enum/table 1:1 증빙)

`PRM_ID_HA_APPLYLOGDB_DRAIN_TIMEOUT_MSEC` **뒤에** 신규 파라미터를 추가하고 `PRM_LAST_ID` 갱신.

- `src/base/system_parameter.h` enum:
  ```
  PRM_ID_HA_APPLYLOGDB_DRAIN,
  PRM_ID_HA_APPLYLOGDB_DRAIN_TIMEOUT_MSEC,
  PRM_ID_HA_WRITESET_TRACE_LEVEL,          ← 추가
  PRM_LAST_ID = PRM_ID_HA_WRITESET_TRACE_LEVEL   ← 갱신
  ```
- `src/base/system_parameter.c` `#define PRM_NAME_HA_WRITESET_TRACE_LEVEL "ha_writeset_trace_level"` 추가(DRAIN_TIMEOUT 바로 뒤).
- `src/base/system_parameter.c` prm_Def[] 테이블: DRAIN_TIMEOUT 엔트리 뒤에 신규 엔트리를 **마지막**으로 추가(백업 정의 그대로):
  ```
  {PRM_ID_HA_WRITESET_TRACE_LEVEL,
   PRM_NAME_HA_WRITESET_TRACE_LEVEL,
   (PRM_FOR_CLIENT | PRM_FOR_SERVER | PRM_FOR_HA),
   PRM_INTEGER, PRM_CLEAR_DYNAMIC_FLAG,
   {false, {.i = 2}}, {false, {.i = 2}},        default=2 (측정빌드)
   {false, {.i = 3}}, {false, {.i = 0}},        upper=3, lower=0
   (char *) NULL, (DUP_PRM_FUNC) NULL, (DUP_PRM_FUNC) NULL}
  ```

**1:1 순서 증빙**: enum과 prm_Def[] 모두 기존 마지막 원소(DRAIN_TIMEOUT) 바로 뒤 동일 위치에 append
했으므로 인덱스가 1:1로 유지된다. 파일 하단 `static_assert`들은 ordinal 95/100/193/194(모두 추가
지점보다 앞)을 검증하므로 영향 없음 — 빌드에서 어서션 미발화로 확인.

## 4. 스킵한 트레이스 + 사유

### coordinator apply begin / end (2종) — 스킵
백업의 coordinator apply는 직렬/문장 직접적용 경로(`la_apply_commit_list`)를 감싼다. 현재 PoC의
`la_apply_commit_list`는 소스 주석에 "현재 호출 경로가 없는 (구) 레거시 함수"로 명시된 **죽은
코드**이며, PoC 리더는 `LOG_COMMIT`을 항상 게이트(디스패치/park) 병렬 경로로만 처리해 직렬 직접적용
경로 자체가 없다. 죽은 코드에 트레이스를 넣으면 런타임에 아무것도 안 찍히고 오해만 유발하므로
스킵(task 지침 "else skip with a note"에 해당).

### writeset.cpp(마스터) 트레이스 — (1차 스킵 → 2차에서 이식)
1차에서는 백업 `writeset.cpp`의 `WSET_TRACE` 라인이 현재 재작성된 `log_writeset.c`와 함수구조가
달라 다의적이라 스킵했다. **2차 범위 확장에서 사용자가 마스터 트레이스를 명시적으로 요청**하여,
백업 포맷을 그대로 베끼는 대신 현재 `log_writeset.c` 구조에 맞는 **새 `[WSET] master ...` 포맷**을
설계해 이식했다. §7 참조.

## 5. 필드 편차(-1 또는 의미 재매핑) 기록

`-1`로 떨어뜨린 필드는 없다. 다만 아래 두 건은 PoC 상태의 값을 쓰되 백업과 **의미가 달라** 기록:

- **reader schedule `status=%d`**: 백업은 coordinator의 `LA_DISPATCH_ACCEPTED/PENDING/STOPPED`
  enum 값. PoC엔 해당 enum이 없고, dispatch 시퀀스가 schedule 시점이 아니라 **실제 디스패치 시점**에
  부여된다. 그래서 schedule 트레이스를 `la_gate_dispatch_now`(디스패치 choke point)에 두어
  worker/retire 라인과 **dispatch 값이 상관(join)되도록** 보장했고, status는 PoC 게이트 판정을
  의미하도록 재정의: `0`=의존 충족으로 리더가 즉시 디스패치, `1`=park 됐다가 의존 해소 후 drain에서
  디스패치. 라인 포맷·키는 백업과 동일, 값 의미만 PoC 정의.
- **reader commit `path=%s`**: 백업은 `la_parallel_Enabled`로 `"parallel"/"serial"` 분기. PoC엔
  직렬 토글이 없고 게이트 경로가 항상 병렬이라 상수 `"parallel"`을 출력. (reader abort의 `path`도 동일.)
- **coordinator flush begin/end**: 백업 coordinator flush는 repl item을 `la_flush_repl_items`로
  플러시하는 단계였다. PoC는 repl item flush를 **워커가 트랜잭션별로** 수행하므로 coordinator엔 해당
  단계가 없다. 대신 `la_reader_commit_apply_info`(committed_lsa를 `_db_ha_apply_info`에 기록·커밋하는
  유일한 choke point, 스로틀된 retire 경로와 `la_log_commit` 양쪽에서 도달)에서 flush=apply-info
  기록 단계로 매핑. flush end의 `error`는 `la_update_ha_last_applied_info()` 반환 `res`를 에러형으로
  변환(`res>0 ? NO_ERROR : res`). 백업은 `la_log_commit`에서만 찍었지만 PoC는 이 choke point에서
  찍히므로 호출 빈도가 다를 수 있음(둘 다 정당한 committed_lsa 영속화 지점).

## 6. 빌드 결과

```
cd /home/youngjun/Workspace/cubrid-applier/build_x86_64_release && ninja
NINJA_EXIT=0        (실제 종료코드, 마스킹 없음)
[802/802] 전부 링크 성공
```
수정 TU 재컴파일 확인: `system_parameter.c.o`(sa/cs/cubrid 3변형), `log_applier.c.o`(cs) 모두 빌드.
`log_applier.c`/`system_parameter.c` 관련 error·warning 0건.

2차 범위확장 재빌드: 같은 명령 `ninja` **NINJA_EXIT=0**, 49/49 링크. 재컴파일 확인:
`log_writeset.c.o`(sa/cs/cubrid)·`log_manager.c.o`(sa/cubrid)·`log_applier.c.o`(cs). 네 수정 파일
(log_writeset.c/log_manager.c/log_applier.c/system_parameter.*) 관련 error·warning 0건.

미커밋 상태 유지(사용자 git diff 검토 대기). 배포/HA·벤치 실행 안 함.

---

## 7. (확장) 마스터 writeset·충돌검사·히스토리 트레이스 — `log_writeset.c`

게이팅: 새 매크로 `WS_MASTER_TRACE(level, ...)`가 `[WSET] ` 프리픽스를 붙이고
`prm_get_integer_value(PRM_ID_HA_WRITESET_TRACE_LEVEL) >= level`로 가드, `_er_log_debug` 사용(슬레이브와
동일 규칙). `#if defined(SERVER_MODE)||defined(SA_MODE)` 블록 안에 정의 — 마스터 전용.

| 종류 | 레벨 | 삽입 함수(file) | 포맷 |
|---|---|---|---|
| master probe (키별 충돌) | 2 | `log_writeset_commit_probe` 루프, 히스토리 hit 시 | `[WSET] master probe trid=%d key=%016llx kind=%s prior_write=%lld\|%d prior_ref=%lld\|%d dep=%lld\|%d from_ref=%d` |
| master publish (tx 요약) | 1 | `log_writeset_commit_flush` 말미 | `[WSET] master publish trid=%d commit_lsa=%lld\|%d keys=%zu dep=%lld\|%d from_ref=%d` |
| master history init | 1 | `log_writeset_history_initialize` | `[WSET] master history init reason=boot cap=%d` |
| master history finalize | 1 | `log_writeset_history_finalize` | `[WSET] master history finalize reason=shutdown map_size=%zu` |
| master history clear(full) | 1 | `log_writeset_commit_flush` CAP 초과 분기 | `[WSET] master history clear reason=full trid=%d prev_count=%zu tx_keys=%zu cap=%d history_start=%lld\|%d` |
| master history clear(overflow) | 1 | `log_writeset_commit_flush` overflow 분기 | `[WSET] master history clear reason=overflow trid=%d history_start=%lld\|%d` |
| master history fallback(tx_limit) | 1 | `log_writeset_push_hash` per-tx 한도 초과 | `[WSET] master history fallback reason=tx_limit trid=%d limit=%d` |

필드 의미:
- probe의 `prior_write`/`prior_ref` = 히스토리 엔트리의 `write_seq`/`read_seq`(코드 필드명 유지, 라인 키는
  설계 용어 prior_write/prior_ref). `dep` = 이 키가 고른 후보(cand), `from_ref` = 후보가 read 슬롯에서
  왔는지(=문서의 `dependency_is_ref`). 키별이라 레벨 2(상세)로 가드.
- publish의 `dep`/`from_ref` = probe가 확정해 `tdes->ws_dependency_seq`/`ws_dependency_is_read`에 저장한
  값(= WS_LABEL 레코드가 슬레이브로 싣는 값). `keys` = `tdes->ws_hashes.size()`; overflow면 0이고 직전에
  clear(overflow) 라인이 같이 찍힌다. "label time" 요구는 이 publish 라인이 커밋 LSA와 함께 충족한다
  (라벨 레코드 append 지점 `log_append_ws_label_with_lock`에는 commit_lsa가 아직 없어 flush 지점을 택함).

## 8. (확장) SYSOP_END 트레이스 — 양쪽, 현재 동작만

새 의미를 만들지 않고 현재 PoC 동작을 관찰만 한다.

- **마스터** `log_manager.c` `log_sysop_commit_internal`, 복제 허용 분기에서 `log_append_repl_info` 직후:
  `[WSET] master sysop_end trid=%d type=%d repl=1 writeset=untouched`. sysop_end는 직렬/클릭카운터 복제
  항목을 여기서 내보내지만 writeset probe/flush는 돌지 않아 dependency 라벨이 없다(= `writeset=untouched`).
  `type`은 `LOG_SYSOP_END_TYPE` enum 정수.
- **슬레이브** `log_applier.c` `case LOG_SYSOP_END`: PoC는 적용·디스패치 없이 "봤다"만 기록한다. 두 분기 모두
  라인 1개:
  `[WSET] reader sysop_end trid=%d sysop_lsa=%lld|%d committed_lsa=%lld|%d items=%d action=defer|skip`.
  `action=defer`(commit 프론티어보다 위, items=apply->num_items) / `action=skip`(이미 커밋됨, items=0).

## 9. (확장) 게이트 pending→ready 쌍 — `log_applier.c`

슬레이브 schedule 포맷은 백업 verbatim 유지. 의존 블로킹을 **두 줄 쌍**으로 가시화:
- park(결정=대기): reader의 pending 분기(`la_gate_enqueue_pending` 직후)에서
  `[WSET] reader schedule ... status=2 dispatch=18446744073709551615`. dispatch는 all-ones 센티넬(=아직
  미할당) — PoC는 실제 디스패치 때만 dispatch 시퀀스를 부여하기 때문. 첫 실제 seq=0이라 0을 센티넬로 쓸 수
  없어 `(unsigned long long)-1` 사용.
- re-dispatch(해소 후 배정): `la_gate_dispatch_now`가 drain 경로에서 호출될 때 `status=1`, 실제 dispatch=seq.
- 즉시 배정(의존 충족): `status=0`, 실제 dispatch=seq.

쌍 매칭은 trid+commit_lsa. status 의미(0=즉시,1=park후 재배정,2=park)는 PoC 정의이며 §5에 기재한 편차의
연장(백업 LA_DISPATCH enum 부재).

## 10. (확장) 슬레이브 항목단위 적용오류 — `log_applier.c`

`la_apply_repl_log` 항목 적용 실패 분기(errid·pk_string 이미 계산된 지점)에서:
`[WSET] worker error trid=%d commit_lsa=%lld|%d worker=%zu error=%d item_type=%d class=%s pk=%.255s%s`.
unique 위반 등 슬레이브측 충돌이 같은 `[WSET]` 스트림에 error 코드·클래스·PK와 함께 보인다. 레벨 1(오류는
항상). worker=`context->worker_idx`, trid=`apply->tranid`.

## 11. (확장) 커버리지 체크리스트 (사용자 6개 항목)

1. 마스터 writeset·충돌검사 → §7 (probe 키별 + publish tx요약). ✔
2. 마스터 히스토리 생애주기 → §7 (init/finalize/clear-full/clear-overflow/fallback). ✔
3. SYSOP_END 양쪽 → §8 (마스터 repl emission 지점 + 슬레이브 defer/skip). ✔ 새 의미 추가 없음.
4. 슬레이브 병렬성 worker 라인에 trid+worker → §1 worker 6종 모두 `trid=%d ... worker=%zu` 포함. ✔
5. 게이트 결정 + pending→ready 쌍 → §1 reader schedule(백업 verbatim) + §9 park/redispatch 쌍. ✔
6. 슬레이브 충돌/오류 항목단위 → §10 worker error. ✔

우선순위 준수: 4·5는 백업 포맷 verbatim(파서 호환), 1·2·3·6은 신규 포맷이며 위 표로 문서화.
