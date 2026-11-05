---
tags: [writeset, gap, todo, plan]
date: 2026-10-08
code: cubrid-applier feature/CBRD-27508-parallel-applylogdb-writeset. 2026-10-09 저녁에 브랜치를 master 74e007835 / slave 5d251d4ba / cs 1c86f4f6f 세 커밋으로 재구성했다. 아래 표의 커밋 해시(28ea0b7ac 등)는 재구성 전 해시이고 태그 backup/CBRD-27508-pre-squash-20261009 아래에만 남아 있다.
source: 설계 대비 점검 에이전트 3갈래(master, slave, 검증·리스크) 보고 + 본 세션 코드 재확인
supersedes: design-gap-check-20261008.md (같은 내용을 기능 미구현 우선으로 재편)
---

# 미구현 목록과 작업 순서 (2026-10-08 기준)

> [!NOTE]
> **현재 상태 (2026-11-02, PR 브랜치 HEAD 8e3029e56 기준)**
> - 1-1 재시작 경계: 구현됨(a7577f913, `log_initialize_internal` → `wset_raise_history_start`). 로그 끝이 커밋 위치가 아닌 문제는 slave bc7f11b3d(C1)가 라벨을 직전 커밋으로 낮춰 막는다.
> - 1-6 history 해제: 구현됨(`logtb_undefine_trantable` → `wset_history_finalize`).
> - 1-8 용량 초과·2-10 게시 중 메모리 부족·sysop ABORT 키: 구현됨(a7577f913, `wset_history_reserve_capacity`, `wset_publish_with_capacity`, `wset_abort_after_lsa`).
> - 1-9 2PC: 구현됨(a7577f913, `log_complete_for_2pc`). "보류"는 옛 상태다.
> - 2-1 WSET_LABEL 할당 실패: 수정하지 않는다. develop의 다른 append 경로와 같은 처리(NULL이면 return)다.
> - 2-3 긴 트랜잭션의 SYSOP_END: 지금 라벨을 받는지는 확인하지 않았다.
> - 2-5 serial: 지금 코드가 의도한 동작이다. serial 키는 SYSOP_END에서 버리고 sysop 라벨로 순서를 잡는다. 폴백 이유가 STATEMENT로 기록되는 것은 01 9장 한계로 둔다.
> - 2-9 UPDATE old·new 항상 수집: 의도한 보수 정책이다(01 4.1절). PK 수집 위치는 PK와 UNIQUE를 한 로직에서 처리하도록 합친 결과다(09-30 d7bbd2765, 지금 브랜치에서는 fb82b7db6에 포함).


설계 문서(`_impl/01`~`12`, 리뷰 04·claude-review-integrated)와 코드를 대조한 결과를 한 곳에 모았다. 기준일 이후 바뀌면 이 파일을 갱신한다.

"확인" 열은 점검자가 보고한 근거를 본 세션에서 코드로 다시 본 것(확인), 보고만 받은 것(보고)이다. 작업 순서는 **기능 미구현을 먼저**, 그다음 예외 처리·에러 핸들링 결함, 마지막에 검증 미착수로 둔다.

## 1. 기능 미구현 (설계에 있으나 코드가 없음) — 작업 1순위

| 순서 | 항목 | 설계 출처 | 상태 | 코드 근거 | 확인 |
|---|---|---|---|---|---|
| 1-1 | 재시작 경계 (cub_server 재시작 뒤 트랜잭션이 재시작 전 전부를 기다리게) | [12장 12.2](../../12-cub_server-재시작.md) | **반영 (5df8187ad)**, 문법 검사만, 재시작 실측 미착수 | 당시 제안한 라벨 플래그·홀더 대신 `log_initialize_internal` 복구 직후 `wset_raise_history_start (append_lsa)`. 라벨 바닥 + A1 frontier gate로 경계가 됨. 12장 12.2·12.3·12.5·12.7·12.8 고쳐 씀, 이전 장벽 플래그안은 폐기 | 확인 |
| 1-2 | 재시작 복구 skip 완료 조건 (applylogdb 재기동 후 복구 구간의 재적용 오류 skip) | 9.1.3, 당시 복구 검증 계획 §4(Git 이력), [restart-skip-impl-plan](./restart-skip-impl-plan-20261007.md) | **반영 (3725009fe)**. 1-3과 같은 변경 | HEAD에는 final_lsa 상한 판(PoC)이 이미 있었고, 처음 표에 "HEAD 0건"이라 쓴 것은 오기. 10-08 WIP f5e1535db의 재시작 부분만 떼어 HEAD에 올림 | 확인 |
| 1-3 | slave 복구 상한을 worker별 max_committed_lsa로 (apply info에 worker 행) | [02 §5·7](../02-slave-implementation-design.md) | **반영 (3725009fe)**, 문법 검사만, 빌드·런타임 미검증 | 카탈로그 `worker_id`·`max_committed_lsa_*` 컬럼, `la_get_ha_apply_worker_info` 등 3함수, `la_apply_worker_commit_task`에서 같은 트랜잭션에 행 갱신. **DB 재생성 필요(마이그레이션 없음)**. `db_ha_apply_info` 뷰에 워커 행이 함께 보이는 문제는 미결 | 확인 |
| 1-4 | task queue 비차단·outstanding 상한, pending 상한, completed set 크기 설정 | [02 §3](../02-slave-implementation-design.md), 당시 in-flight 설계 §2·5(Git 이력), 9.1.4 | **반영 (6a2494096)** | 상한 하나 `LA_OUTSTANDING_CAPACITY(worker_count)` = worker 수 × 1024 (파라미터 아님). gate의 commit-order FIFO 길이가 outstanding 수. 상한이면 reader가 task 경계에서 로그 읽기를 멈추고 결과 수거·frontier·retire·pending 재판정만 반복(`la_reader_wait_for_outstanding_room`). task queue push 비차단: 자리 없으면 ready task도 pending에 두고 다음 collect에서 배정, 신규보다 먼저 온 ready를 먼저 drain. in-flight list·result queue·completed set은 기동 때 상한 크기로 malloc. 남은 것: dependency가 영영 안 풀릴 때 상한에서 영구 대기(설계는 오류 처리) 감지 없음 | 확인 |
| 1-5 | worker READY 핸드셰이크, worker 수·queue 용량의 설정 파라미터화 | 당시 worker 설계 §5·12(Git 이력) | **반영**: worker 수 파라미터 (1cdd2016f). READY 핸드셰이크는 넣었다가(24efa298b, ea72ffbbc) 10-09 밤에 뺌 | `ha_apply_worker_count`(기본 10, 1~32). 배열 길이는 `LA_MAX_WORKER_COUNT`=32 고정, 기동 수만 런타임. 핸드셰이크 대신 살아 있는 worker 카운터: 기동 실패 worker는 ERROR 로그 남기고 빠지고, 0이 될 때만 `need_shutdown`(`la_apply_worker_startup_failed`). 당시 worker 설계 §5(Git 이력)에 결정 기록. queue 용량 설정화는 1-4로 | 확인 |
| 1-6 | `wset_history_finalize` 호출 (서버 종료 시 history 해제) | [01 §1.2.3](../01-master-implementation-design.md) | **반영 (644727743)** | `logtb_undefine_trantable`의 `lock_finalize` 옆(Reuse 아닐 때만). 01장 1.2.3의 `boot_server_all_finalize` 호출 트리는 고쳐야 함 | 확인 |
| 1-7 | trace fallback_reason 분류 (serial / incr / checksum / overflow) | [10 §13.7.2](10-sysop-end-investigation.md) | **반영 (2fc4202c0)** SYSOP 줄만 | `[WSET] SYSOP master commit_order … reason=serial\|incr\|checksum\|mixed\|overflow`. repl 레코드의 class 이름(`_db_serial`), statement 여부, `wset_overflow`로 분류. COMMIT 줄의 fallback 사유는 기존 `fallback=` 그대로 | 확인 |
| 1-8 | 용량 집계를 동시 게시분 포함 원자 예약으로 | 8-1 상세 설계에만 (파일명이 NFD라 링크 생략) | **반영 (d1b42e68e)**. 기능이 아니라 메모리 상한 정밀도 | 공유 락 경로에서 `wset_Publish_reserved`(atomic)에 자기 키 수를 더한 뒤 비교, 게시 뒤 되돌림. 독점 락 경로는 그대로 | 확인 |
| 1-9 | 2PC 커밋 경로(`log_complete`)의 probe·publish | 당시 재시작 장벽 설계 §6(Git 이력에 보존) | **보류 (2026-10-09)**. HA 복제에서 2PC를 쓰는지 확인 뒤 결정 | log_manager.c:6259 (로컬 커밋 5489~5493과 대비). 구현은 로컬 커밋 미러 두 줄(probe·publish) 또는 commit-order 폴백 한 줄. 결정 뒤 확인할 것: ① prepare~commit 사이 tdes `wset_hashes` 보존 여부 ② 슬레이브가 2PC 커밋 rectype을 COMMIT task로 받는지 ③ coordinator·participant 경로가 같은 함수인지 | 확인 |
| 1-10 | SYSOP 조각 단위 처리 | [10장 13.7.10](10-sysop-end-investigation.md) | 보류 (제거 커밋 28ea0b7ac, TODO만) | log_manager.c `log_sysop_commit_internal` 주석. 복귀 시 `git show 56e757e66:src/transaction/writeset.cpp`, 선결 = 원인 B(아래 2-6) | 확인 |

재시작 정합 1-1~1-3은 10-08~09에 코드로 반영됐고, 빌드·DB 재생성·재시작 실측이 남았다(3절).

남은 것: 1-9·1-10 보류. 기능 항목은 모두 반영됐고 빌드·실측이 남았다.

## 2. 예외 처리·에러 핸들링·설계 불일치 — 작업 2순위

| 순서 | 항목 | 출처 | 상태 | 코드 근거 | 확인 |
|---|---|---|---|---|---|
| 2-1 | WSET_LABEL 노드 할당 실패 시 `/* FIXME */ return`, COMMIT은 라벨 없이 그대로 기록됨 | [01 §6](../01-master-implementation-design.md), 05 §3.2, 리뷰 C1 | 미구현 | log_manager.c:4924~4928 | 확인 |
| 2-2 | `xlocator_repl_force`가 lock 오류 포함 모든 오류를 항목 단위로 삼키고 다음 항목으로 계속 | [11 §11.9-4](11-dependency-label-design.md), [dependency-root-cause](./dependency-root-cause-20261008.md) | 미구현 (develop 원본, 설계에서 변경 결정) | 아래 2-2 상세 | 확인 |
| 2-3 | long transaction(1000항목 초과)의 SYSOP_END는 바깥 커밋에서 재생 → serial 후퇴·abort 유실 잔존 | [10 §13.7.2.1](10-sysop-end-investigation.md) | 부분(자인) | log_applier.c:8690, :8982 | 확인 |
| 2-4 | apply info 갱신 0건을 에러 로그만 남기고 NO_ERROR 반환 | [02 §7](../02-slave-implementation-design.md) | **닫음 (10-16)**: 설계 전제(B2 완료 표식 정리)가 사라짐. 복구 구간 상한 저장(`la_update_ha_apply_max_committed_lsa`)은 0건을 실패로 처리. 주기적 저장(`la_coordinator_commit_apply_info`)은 0건·기타 오류 모두 develop과 같이 fail_counter+1·로그·계속(서버 다운만 반환), 별도 커밋 | log_applier.c `la_reader_commit_apply_info` res==0 | 확인 |
| 2-5 | serial 캐시 BTID NULL이면 트랜잭션 전체를 commit-order 폴백(overflow 재사용) | [10 §13.7.2](10-sysop-end-investigation.md) "overflow 재사용 금지" | 불일치 | serial.c:1232~1235 | 확인 |
| 2-6 | 원인 B: 라벨을 `min(최댓값, prev_commit_lsa)`로 낮춤 | [11 §11.9-2](11-dependency-label-design.md) | 설계상 TODO (조각 복귀 선결) | writeset.cpp:879~887 | 확인 |
| 2-7 | 라벨 없는 COMMIT을 독립 task로 배정 (설계는 금지) | [02 §2](../02-slave-implementation-design.md), 8-2.3 | 불일치 | log_applier.c:8821 부근 | 보고 |
| 2-8 | 복구 구간 error skip 뒤에도 restart 판정 진입 | 8-2.9 | 부분 | `la_flush_repl_items` | 보고 |
| 2-9 | UPDATE 키 수집이 same_key 무관 old+new 항상 수집, PK WRITE 수집 순서가 repl 성공 전 | [01 §2.1·2.2](../01-master-implementation-design.md) | 불일치(보수 측) | locator_sr.c:8052~8062, 8742~8782 | 보고 |
| 2-10 | 리뷰 "커밋 전 필수" 소수정: WSET_LABEL dump 케이스, or_pack 오류, release 클램프, bad_alloc 처리, savepoint 되감기 | 리뷰 C5~C9, C6 | **닫음 (10-16)**: C5 dump 반영 확인. C6·C8·C9는 기존 CUBRID 처리를 따라 별도 커밋 5606d1a21(C6 키에 tail LSA·`wset_abort_after_lsa`를 `repl_log_abort_after_lsa` 옆에서 호출, C8 `bad_alloc`을 history 가득 참과 같게 처리(`log_prior_inflight` 방식), C9 `assert_release`). C7은 develop 관례(`replication.c`도 검사 안 함, 버퍼 `OR_VALUE_ALIGNED_SIZE`)를 따르기로 하고 설계 문서 6-1·8-1·9의 "packing 실패 오류 전달" 문구를 고침. **닫음** | log_manager.c dump switch, writeset.cpp:456, writeset_history_map.cpp:54 | 보고(추정) |
| 2-11 | rectype 호환 문서(마스터 선업그레이드 = 복제 중단), trace PII, release 패딩 | 리뷰 R10, R18, R13 | 미착수 | log_record.hpp:140 등 | 보고 |
| 2-12 | applylogdb 메모리 상한 판정이 VSZ 기준이라 워커 arena 때문에 거짓 양성, 임시로 `MAX (max_mem_size, 4000)` 바닥 → conf `ha_apply_max_mem_size`가 4000 미만이면 무시됨 | 코드 주석 TODO (la_init) | 임시 조치 | log_applier.c `la_init`, `la_check_mem_size`. RSS 기준으로 바꾸거나 워커 기동 뒤 start_vsize를 잡고 바닥 제거 | 확인 |

권장 순서: 2-1 (라벨 계약) → 2-2 (영구 멈춤 방어) → 2-3·2-4 (손실 방어) → 2-5·2-7·2-8 (설계 불일치) → 2-9~2-11 (PR 정리). 2-6은 1-10과 묶는다.

### 2-2 상세: `xlocator_repl_force`의 lock 오류 처리

develop 원본(2014-10-15 e51230d0be)이고 우리 브랜치는 이 함수를 건드리지 않았다. 단일 스레드 applier는 데드락 희생자가 될 일이 없어 드러나지 않았고, 워커가 여럿이 되면서 전제가 깨졌다. [no-sysop 테스트](./no-sysop-test-20261008.md)의 영구 멈춤이 이 경로다.

서버 쪽(locator_sr.c):

| 라인 | 내용 |
|---|---|
| 6931 | `xlocator_repl_force` 시작 |
| 6967~6969 | 항목 루프, 머리에서 `er_clear ()`. 항목 처리 뒤 `er_errid ()`는 그 항목의 오류다 |
| 7009~7016 | 항목별 topop 시작, `locator_repl_prepare_force` |
| 7019~7070 | switch에서 `locator_insert_force / locator_update_force / locator_delete_force` |
| 7073~7082 | `error_code != NO_ERROR`면 응답 영역에 기록(7076), `error_code = NO_ERROR`(7078), `num_continue_on_error++`(7079), 그 항목 topop만 abort(7081), 다음 항목으로 계속. **오류 종류를 구분하지 않는다** |
| 7097~7099 | 실패가 하나라도 있으면 `ER_LC_PARTIALLY_FAILED_TO_FLUSH` 반환 |
| 7103 | `exit_on_error:` 바깥 topop까지 abort하고 오류 코드를 그대로 반환. lock 오류는 이쪽으로 보내야 한다 |

lock 오류가 올라오는 경로:

- lock manager는 에러 코드를 반환하지 않고 `LK_GRANTED / LK_NOTGRANTED_DUE_ABORTED / _TIMEOUT / _ERROR` 상태만 돌려준다(lock_manager.c:4107~4121). 데드락 희생자는 깨어난 뒤 `lock_set_error_for_aborted`(:2432 → :2308)가 `ER_LK_UNILATERALLY_ABORTED`를 er에 넣는다. 에러 코드 변환은 전부 호출처 몫이다.
- UPDATE 행 X_LOCK: `locator_update_force`(:5397) 안 :5852 `lock_object (..., X_LOCK, LK_UNCOND_LOCK) != LK_GRANTED` → :5854 `ASSERT_ERROR_AND_SET (error_code)`(= `er_errid ()`) → :6088 `error:` → `return error_code`. 그래서 :7032 호출의 반환값으로 -72가 :7073에 도착한 뒤 삼켜진다.
- FK X_LOCK: `locator_add_or_remove_index_internal` :8086~8089, `locator_update_index` :8858~8861은 `goto error`만 하고 error_code를 바꾸지 않는다. `error:` 라벨은 `return error_code`라 직전 값(보통 NO_ERROR)이 반환된다. 이 경로는 lock이 실패해도 :7073 분기에 들어가지 않고 er에만 흔적이 남는다(develop에도 있는 결함). lock 실패 뒤 실제 반환값이 무엇으로 끝나는지는 끝까지 따라가지 않았다(추정).
- `locator_lock_and_get_object_internal` :13197~13208도 `goto error`. 반환 처리 미확인.

영구 멈춤이 되는 이유(lock_manager.c): 희생자 선정 시 `DL_victim = true`(:2639). 트랜잭션이 끝나지 않고 다음 항목에서 다시 lock을 기다리면 `lock_add_WFG_edge`(:4950)가 `DL_victim` 트랜잭션의 간선을 대기 그래프에 넣지 않아 두 번째 순환이 탐지되지 않는다. 플래그는 트랜잭션 종료 시 `lock_clear_deadlock_victim`(:9559)에서만 꺼지는데, 클라이언트(워커)는 서버 응답을 기다리고 있어 종료를 부를 수 없다.

클라이언트 쪽: `locator_repl::locator_repl_flush_all`(locator_cl.c:7118, :7131)이 부분 실패를 error link로 풀고, `la_flush_repl_items`(log_applier.c:6805, :6831~6832)가 오류 항목을 하나씩 로그로만 남기고 계속한다(:6938에서 다시 PARTIALLY_FAILED로 올림).

수정 방향: :7073 분기에서 `error_code`가 아니라 `er_errid ()`를 보고 `ER_LK_UNILATERALLY_ABORTED`, `ER_LK_OBJECT_TIMEOUT`(또는 `ER_LK_` 계열)이면 `goto exit_on_error`. er 기준으로 해야 FK 경로처럼 error_code가 올라오지 않는 경우도 잡힌다. 워커 쪽 `la_flush_repl_items`가 lock 오류를 받았을 때의 abort·재시도 경로는 아직 확인하지 않았다(추정).

## 3. 검증 미착수 — 작업 3순위

| 항목 | 출처 | 상태 |
|---|---|---|
| pending 계측(배정 줄에 frontier, FIFO 노드 trid), gate 단위 테스트, 6-2.4·8-2.4 정정 | [a1-test](./a1-test-20261008.md) 남은 일 | 미착수 |
| long transaction·DDL 경로 부하(`--wide-transactions`, `--ddl-transactions`), fullcheck/gatesim의 SYSOP 작업 포함 | [sysop-commit-order-test](./sysop-commit-order-test-20261008.md) 남은 일 | 미착수 |
| 미빌드 커밋 3개 빌드·배포·DB 재생성·재측정 (같은 seed 20261006, 기대 ~14s, lag ~0.08s) | 13.7.10, 02 §5·7, 12.2 | 빌드 대기 |
| failover 승격·failback 실측 | 9.2, 당시 복구 검증 계획 §4(Git 이력) | 미착수 |
| 백로그(포화) 병렬성 측정 | a1-test, 03 §5 | 미착수 |
| Run 1 wide 행 손상·slave crash 원인 | [sysop-end-test](./sysop-end-test-20261008.md) | 미착수 |
| 복합 FK 단위 테스트 실행 기록 | 9.1.2 | 바이너리만, 기록 없음 |
| cub_server 재시작 검증(12.8) | 12장 | 미착수 (1-1 반영됨, 빌드 뒤) |
| develop 기준선 같은 seed 측정 | 13.7.9 | 미착수 |

## 4. 작업 순서 요약

1. 미빌드 커밋 10개(조각 제거 28ea0b7ac, 재시작 상한 3725009fe, 재시작 경계 5df8187ad, history_finalize 644727743, worker 수 파라미터 1cdd2016f, READY 24efa298b, 대기 상한 ea72ffbbc, SYSOP reason 2fc4202c0, outstanding 상한 6a2494096, 용량 예약 d1b42e68e) 빌드·배포·**DB 재생성**·seed 20261006 재측정 (사용자 빌드 대기). 그 뒤 applylogdb 재시작과 cub_server 재시작 실측(당시 복구 검증 계획 §4(Git 이력), [12장 12.8](../../12-cub_server-재시작.md)).
2. 기능 미구현: 없음. 1-9(2PC)는 보류, 1-10(조각)은 보류.
3. 예외 처리: 2-1 → 2-2 → 2-3·2-4 → 2-5·2-7·2-8 → 2-9~2-11.
4. 검증 3절.
