---
tags: [writeset, applylogdb, idea3, ha-test, failure-analysis]
date: 2026-10-03
status: 1차 분석 완료 (log 라인바이라인) / 3개 에이전트 심층분석 병행 중
code-base:
  repo: /home/youngjun/Workspace/cubrid-applier (병합본, 미커밋)
  base: develop 441aafed9 + 측정dirty + idea-3(마스터/슬레이브/유닛테스트)
  worktree: /home/youngjun/Workspace/cubrid/.claude/worktrees/agent-a0751035226db3892
---

# 안 3 첫 HA 테스트 실패 분석 (page-corrupted 크래시 루프 → 데이터 유실)

## 0. 테스트 개요

- 도구: `ha_bench-sysop-random`, profile=smoke, seed=20261001 (기존 도구, 수정 없이 실행).
- 환경: youngjun3=master/active, youngjun4=slave/standby. 두 노드 모두 안 3 병합 빌드 배포 확인(스트립에도 남는 trace 문자열 `SYSOP slave fragment assemble`/`SERIAL master collect`로 양 노드 libcubridcs/sa에 존재 확인).
- 배포본: `/home/youngjun/CUBRID-11.5.0.2621-441aafe-Linux.x86_64`, `ha_writeset_trace_level` 소스 기본값 2(측정용 임시, conf 명시 없음)로 trace 켜짐.
- 수집 로그(정적): `scratchpad/slave_applier.err`(youngjun4 applier, 6264줄), `scratchpad/master_server.err`(youngjun3 server).

## 1. 결과 — FAIL (데이터 유실)

- 테이블 `sr_1002160018_1597719_1001_item_0`: 마스터 47행, 슬레이브 40행. 슬레이브 12초간 40행 고정(복제 지연 아님).
- 누락 id: **41, 42, 44, 45, 46, 47, 51** (7행). 전부 마스터엔 커밋된 행.
- applyinfo: **Fail count=0**, delay=0, committed_lsa==final_lsa(194|13240) → applier는 "정상 캐치업"으로 오보. committed_rep_lsa는 171|4456에 멈춤(행 적용 위치는 뒤처짐).
- fk_orphans=0, unique_violations(최종)=0, invariants_ok=true, model_master_ok=true. 즉 마스터는 정상, 슬레이브만 유실.

## 2. 근본 사건 — page 181 corrupted 크래시 루프 (로그 라인 인용)

슬레이브 applier 로그(`slave_applier.err`)를 순서대로 읽어 재구성.

```text
5607-5622  worker trid=427 commit_lsa=181|9496 rows=88 apply→flush→commit (정상, error=0)
5625       reader retire trid=427 (181|9496)
5627  ★ ERROR -81 "Internal error: logical log page 181 may be corrupted."  (log_applier.c:9555)
5633-5637  applylogdb 재접속(pid 195725) → "log applier started.
             required LSA 176|14912, last committed 176|14872, last committed repl 176|14408"
             → committed_lsa를 181 → 176 으로 되감음
5640~      재시작 후 176부터 재적용: reader commit items=0 / worker apply rows=0 연속
5985~      재적용 중 unique 위반(-670): item_1 key 40,39,38 "failed to apply insert"
6240~6246  재적용 중 unique 위반(-670): parent key 3,2,1
6248-6255  worker trid=427 (181|9496) 재적용·재커밋 (이미 한 것 또 함)
6258       worker apply trid=437 commit_lsa=181|12528 시도
6260  ★ ERROR -81 "logical log page 181 may be corrupted" 재발 (두 번째 크래시)
6263       "The previous error message is the last one" → 로그 끝
```

### 2.1 핵심 관찰

- **같은 page 181 내에서 offset 9496은 정상 읽힘(trid 427 커밋), 직후 offset 12528 읽기에서 la_get_page_buffer(181)가 NULL → corrupted.** 두 접근 사이에 page 181 캐시 버퍼가 사용 불가 상태가 됨.
- `la_get_page_buffer`(log_applier.c 약 1359행)의 NULL 반환 조건 두 가지: (a) 디스크 fetch 후 `logpage.hdr.logical_pageid != 요청pageid`, (b) **캐시된 버퍼에 `invalidate_pending` 설정됨 또는 헤더 불일치**. 증상상 (b)의 persistent-NULL로 추정.
- copylogdb(youngjun4, writer) 로그엔 page 181 손상 흔적 없음(HA 종료로 인한 네트워크 -199/-353만). 즉 writer 쪽 손상이 아니라 **applier 쪽 캐시/읽기 문제**.
- 재시작 시 required_lsa=176|14912 → copylogdb는 176+ 를 보존하므로 purge 문제 아님.

## 3. 데이터 유실 메커니즘 (크래시 루프의 귀결)

1. 병렬 워커는 **181|9496까지 커밋**(trid 427, 88행)했는데 **frontier(committed_lsa)는 176|14872에 머묾** — frontier가 worker 실제 커밋보다 크게 뒤처짐(gap-free 전진 못 함, 중간 pending/미완료 추정).
2. page 181 corrupted 크래시 → 재시작이 **안전 경계 committed_lsa=176으로 rewind**.
3. 176→181 재적용 → 이미 들어간 행에 **unique 위반(-670)**. develop/PoC에 있는 "복구창 재적용 오류 skip"이 **병합본에 미구현**이라 skip 안 되고 "failed to apply"로 표출.
4. 다시 181에서 corrupted → 크래시 루프. 최종적으로 frontier 뒤에서 worker가 커밋했으나 재시작이 skip/미적용한 행(item_0 7행) 유실.
5. applier는 committed_lsa==final_lsa(194) 기준으로 "캐치업"이라 오보 — 실제 행 적용(committed_rep_lsa=171)은 뒤처진 채.

## 4. 귀속 (정직하게)

- **첫 진단 "무성 스킵"은 부정확했음 — 정정.** 실제는 크래시 루프 + 재시작 재적용이고, `rows=0/items=0`의 다수는 재적용 아티팩트(이미 적용돼 빈 것). 순수 무성 스킵이 아니라 크래시-복구 실패가 본질.
- **트리거(page 181 corrupted) — 코드로 확정(2026-10-03).** `la_invalidate_page_buffer`의 회귀다. HEAD 441aafed9는 이 함수가 **무조건** `mht_rem + fix_count=0 + pageid=0`으로 버퍼를 즉시 drop해 fix-count 누수를 매번 흡수했다. 병합본(측정 dirty)은 `invalidate_pending=true`를 먼저 켜고 `--fix_count` 후 **`fix_count<=0`일 때만** drop하도록 바꿨다. 따라서 페이지의 fix_count가 끝내 0으로 안 돌아오면 `invalidate_pending=true`가 영구 고착되고, 그 페이지의 모든 `la_get_page_buffer()`가 해시히트 분기(1390)에서 NULL을 반환 → reader 재시도(~10회/3초, 9548) 소진 → `ER_LOG_PAGE_CORRUPTED`(9555) 크래시.
  - fix_count가 0으로 안 돌아오는 두 경로(pagecache-race-analysis.md): ①(★결정적) 레코드가 페이지 경계를 넘을 때 매크로(`LA_LOG_READ_ADVANCE_WHEN_DOESNT_FIT`:126 등)가 다음 페이지를 추가 fix하는데 `la_apply_update/insert_log`는 한 장(old_pageid)만 release(5489/5685) → fix 영구 누수. ②(경합) reader fix 중 워커가 같은 페이지 fix(fix=2) → reader invalidate 시 2→1로 남아 poisoned. "181 offset 9496 정상→직후 12528 NULL"과 정확히 일치.
  - 또한 병합본은 해시히트+헤더불일치 시 HEAD의 `mht_rem 자가치유`(HEAD 1375-1380)를 제거(1390-1394)해 persistent-NULL 2차 경로를 만듦.
  - 이 필드/로직은 **committed HEAD(441aafed9)에 0개, 병합본에 8개** — **측정 트리 dirty(병렬화 작업)에서 온 것이지 idea-3 조각 코드도 committed 베이스도 아님.**
  - 수정 방향(우선순위): ① 워커가 경계 넘으며 추가 fix한 페이지 전부 release(누수 제거) ② 해시히트 self-heal(mht_rem) 복원 ③ 병렬 모드에서 invalidate_pending發 일시 NULL을 corrupted로 승격 안 함.
- **데이터 유실·재적용 실패**: 병렬 frontier lag + 재시작 rewind + **복구창 error-skip 미구현**(committed HEAD에도 없음, grep 0건, commit-plan 4 예정분). 병렬 applier 복구 미비.
- **idea-3 조각(serial fragment) 코드와는 무관**으로 보임: 유실은 일반 INSERT(item_0/item_1/parent)이고 조각은 serial(db_serial)만 다룸. 크래시도 페이지캐시 레벨.
- **pread/pwrite(a45174afd)는 배제됨**: non-Windows pread 위치지정 읽기는 올바르고 오히려 오프셋 레이스를 막음. 커밋 메시지 "positioned I/O ... avoid cross-thread file-offset races"가 의도. 원인 아님.

## 4-A. 복구창(재시작 멱등) 장치 계보 — 코드로 확정 (2026-10-03)

재시작 멱등 장치를 세 브랜치에서 직접 grep 비교:

| 브랜치 | 재시작 멱등 장치 | recovery_boundary/in_recovery_window grep |
|---|---|---|
| develop c63a3b993 | per-item `last_committed_rep_lsa` 워터마크(LSA_GT 가드), 단일스레드용 | 0 (워터마크만 있음) |
| PoC feature/writeset_error_skip 0405c9bd | 워터마크 제거 + 트랜잭션 단위 복구창(recovery_boundary_lsa + in_recovery_window + 화이트리스트 skip), 병렬 대응 | 14 |
| feature HEAD 441aafed9 / 병합본 | 워터마크 제거했는데 복구창 미포팅 → **둘 다 없음** | 0 |

- **HEAD 441aafed9는 "정답 기준"이 아니라 미완성 포팅이다.** PoC에서 병렬성(a45174afd)만 가져오고 복구창은 안 가져왔다(복구=커밋계획 4번 미완). develop은 복구창이 없어도 per-item 워터마크로 단일스레드 안전했는데, 그 워터마크마저 제거돼 병합본은 재시작 무방비.
- **PoC가 정답 참조.** 복구창이 13곳에 완전 배선됐고 **병렬 worker 결과 경로까지 연결**됨: 필드(in_recovery_window 350, recovery_boundary_lsa 495, recovery_skipped_counter 354/496), 경계 설정(5192, 재시작 시 apply_info.final_lsa), 트랜잭션당 판정(9581-9583), flush에러 skip(8278-8294, INSERT 중복키 / UPDATE·DELETE 대상없음), **워커결과 집계(2580, `la_Info.recovery_skipped_counter += result->stats`)**, statement 경로 의도적 제외(9484), 리셋(11053).
- **frontier lag(176 vs 181)는 버그가 아님 — 정정.** poc-crossref 확인: gap-free committed_lsa 전진은 writeset 비순차 모델의 정상 속성이고 PoC도 동일하다. 차이는 PoC가 재시작 시 (committed_lsa, boundary] 재적용 중복을 복구창 error-skip으로 흡수하는데 병합본은 그 흡수장치만 빠뜨린 것. 따라서 "frontier lag"을 문제로 보지 말고 "복구창 부재"를 결함으로 본다.
- **실제 데이터 유실(추정, restart-recovery 확인 중)**: 재적용 중복키가 복구창 없이 `la_restart_on_bulk_flush_error`(병합본 5114)의 재연결을 트리거하면, 아직 커밋 안 된 선행 트랜잭션이 롤백되며 실제 행 유실로 번질 수 있음. "fail 집계"를 넘어 유실까지 가는 경로.

## 4-B. 3개 에이전트 종합 + restart-recovery 정정 (2026-10-03, 전부 완료)

세 분석을 교차 검증한 최종 그림:

| 사실 | 확정도 |
|---|---|
| 트리거 = `la_get_page_buffer(181)` 지속 NULL → ER_LOG_PAGE_CORRUPTED(9555) → 리더 자발 shutdown → 재시작마다 같은 181서 재크래시(크래시 루프, 01:03:23까지) | 확정(로그) |
| NULL 원인 = 리더↔워커의 page 181 동시접근 + invalidate_pending 캐시 poisoning(HEAD의 mht_rem 자가치유·무조건 drop 제거) | 유력. 재시작 후 fresh 캐시에서도 재발(6258 worker trid=437@181 적용 중 6260 리더 corrupted)이라 "리더+워커 181 경합이 결정적 재현". 단 page 181 내용 자체 손상 가능성은 정적 검사 전까지 미결 |
| ★누락 행 = rewind가 되돌린 게 아니라 **PENDING 상태로 끝내 완결 못 함** | 확정(정정). worker commit end trid=432/437/480 grep 0건. 누락 8행(item_0 41,42,44-47,51 + item_1 41 = 커밋된 tx1/2/4×4/6/7)은 프리로드 의존 PENDING(status=1,dispatch=0) 대기 중 크래시. 재적용(세션2)의 -670은 전부 프리로드 88행에만, 사용자키 -670 0건 |
| committed_rep_lsa는 171 아니라 **176|14408**까지 전진. state-progress slave_rows=0은 "0행"이 아니라 크래시 루프 중 **스냅샷 접속 실패** | 확정(정정) |
| frontier(committed_lsa) 최대 176|15592 동결 vs worker 실제 커밋 최대 181|9496(프리로드) 괴리 ~5페이지 — writeset 비순차 모델 정상 속성 | 확정 |
| 마스터는 전부 정상 커밋(SYSOP END_COMMIT repl_items=1, trid 432@181|10048/480@182|10024), corruption/abort 전무 → **슬레이브 단독 유실** | 확정(마스터 로그) |
| 복구창 error-skip은 **필요하나 불충분** — 181 읽기 실패 자체는 그대로라 루프·유실 잔존. 1차 교정은 페이지 읽기 재시도 정책(LA_GET_PAGE_RETRY_COUNT, 9548) + 리더↔워커 페이지캐시 경합 | 확정(restart-recovery) |
| idea-3 조각 코드 무관, HEAD 441aafed9도 미완성(복구창·자가치유 둘 다 없음), PoC(error-skip)가 정답 참조 | 확정 |

**정정 요약(내 초기 진단 대비):** ①"무성 스킵" → 실제는 크래시 루프. ②"rewind가 행을 유실" → 실제는 PENDING 미완결(worker commit 미도달). ③committed_rep_lsa 171 → 176. ④복구창만 넣으면 해결 → 복구창은 필요하나 불충분(페이지 읽기 실패 선결 필요).

**교정 우선순위(세 분석 합의):**
1. [최우선] page 181 읽기 실패 자체 — 리더↔워커 페이지캐시 경합 해소(invalidate_pending 자가치유/즉시-drop 복원, mht_rem 복원) + 끝페이지 재시도 정책. 이게 안 되면 복구창 넣어도 루프·유실 잔존.
2. [Critical] 복구창 error-skip 이식(PoC 5192/9581/8277-8298/2580/11053) — 재적용 -670 소음 흡수, 루프 영속화 방지.
3. 워커 경계-넘김 페이지 추가 fix의 release 누락 수정(fix 누수 제거).

## 5. 병행 심층분석 (에이전트 3기, 결과는 별도 파일)

- `pagecache-race-analysis.md` — invalidate_pending 생명주기·동시성·persistent-NULL 재현, committed HEAD 대비 회귀.
- `restart-recovery-analysis.md` — 크래시/재시작 타임라인 전수, frontier lag 정량, 누락 7행 trid별 경로, 재시작 전/후 rows=0 분포.
- `poc-crossref-analysis.md` — feature/writeset_error_skip(PoC, 0405c9bd, 관련 처리 39곳)와 대조해 병합본이 빠뜨린 안전장치 역추적(페이지캐시 자가치유, 복구창 error-skip).

## 6. 다음 단계 (제안)

1. 트리거 확정: la_invalidate_page_buffer 호출자 동시성 — reader 사용 중 워커/refetch가 무효화해 persistent-NULL 되는 경로.
2. 복구 확정: PoC의 복구창(recovery_boundary_lsa + in_recovery_window + 허용오류 skip)을 병합본에 이식해야 재시작 재적용이 안전해짐(commit-plan 4).
3. frontier lag 원인: committed_lsa가 worker 커밋(181) 대비 176에 머문 이유(pending/dependency/completion-boundary) 규명.
4. 귀속 확정용 베이스라인 비교 run: 측정-dirty/invalidate_pending 없이 같은 workload로 page-corrupted 재현되는지.
5. 재시작 멱등(E, idea-3 조각 완료표식)도 미구현 상태 — 복구 설계와 함께.

## 7. 미건드림 (상태 보존)

- cubrid-applier dirty, 격리 워크트리 모두 그대로. HA는 사용자가 종료. 추가 실행·배포·커밋 없음. 커밋은 사용자 리뷰 후.
