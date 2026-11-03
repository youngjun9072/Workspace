# PR 전 리팩토링 작업 순서 (2026-10-12~)

## 범위

- 파일 구성, 모듈 경계, 함수명, 주석만 정리한다.
- 동작을 바꾸는 구조 변경은 하지 않는다. 대상 예시는 pending 목록 고정 배열화, 4가지 자원의 `*_final` 추가다.
- 명칭 규칙: 로그를 읽고 디스패치하는 스레드는 **coordinator**로 부른다. 함수명, 주석, trace 모두 `reader`를 쓰지 않는다.
- assert 규칙: 함수 계약상 NULL이 올 수 없는 포인터 인자에만 진입부 assert를 건다. 일관성을 이유로 일괄 추가하지 않는다. 예외: `la_inflight_push`의 `apply`(빈 커밋은 NULL)와 `seq_out`(계약상 NULL 허용)은 assert하지 않는다(10-07 결정). develop에서 옮겨 온 함수(`la_realloc_recdes_data`, `la_assign_recdes_from_pool`)는 develop과 같게 둔다. 10-12에 `la_pending_push`, `la_gate_seed_frontier`, `la_gate_is_satisfied`에 추가했다. `la_worker_debug_get_state`는 미결이다. **10-12 확정:** ① 상위 함수가 이미 확인했거나 넘기는 값이 구조상 NULL일 수 없으면 assert하지 않는다(`la_apply_worker_commit_task`, `la_coordinator_release_apply_slot`, `la_coordinator_add_result_stats`, `la_get_ws_label`). ② 다른 모듈·콜백·여러 곳에서 불려 상위 보장을 믿을 수 없는 함수에만 건다(`la_apply_worker_run_task`, `la_pending_push` 등). ③ 정상적으로 NULL이 올 수 있는 값(빈 커밋의 `apply`)은 조건문으로 처리한다.
- 주석 규칙: 영어로 쓴다. 내부 단계 기호(C1, Hook A), 문서 절 번호, `PoC`, 날짜 참조를 쓰지 않고, 실제 동작으로 풀어 그 주석만 읽어도 이해되게 쓴다.

## 일정

- 10-12: 리팩토링을 마치고 PR 1차를 올린다.
- 그 뒤: 버그 수정과 테스트로 넘어간다(아래 "PR 뒤 버그 단계" 참조).

## 파일별 진행 순서

| 순서 | 파일 | 상태 | 할 일 |
|---|---|---|---|
| 1 | `applier/log_applier_gate.cpp/.hpp` | 진행 중 | completed set 해시 테이블을 정렬 링으로 교체(완료). 주석의 reader를 coordinator로 변경(완료). pending 목록을 `log_applier_pending.cpp/.hpp`로 분리(완료, 10-12 00:11 cubridcs 링크 통과). 남은 것: 주석 분량 줄이기 |
| 1-1 | `applier/log_applier_pending.cpp/.hpp` (신규) | 완료 | `la_pending_push` / `la_pending_pop_ready` / `la_pending_is_empty`. pending → gate 단방향 의존. 결정 대기: `la_coordinator_drain_ready`를 설계 문서 이름(`dispatch_ready_pending`)에 맞출지 |
| 2 | `applier/log_applier_task_queue.cpp/.hpp` | 대기 | 주석·이름 점검 |
| 3 | `applier/log_applier_result_queue.cpp/.hpp` | 대기 | 주석·이름 점검 |
| 4 | `applier/log_applier_inflight.cpp/.hpp` | 대기 | 주석·이름 점검 |
| 5 | `applier/log_applier_worker.cpp/.hpp` | 대기 | 주석·이름 점검. recdes pool 함수는 develop 이름을 유지 |
| 6 | `applier/log_applier_task.hpp`, `_result.hpp`, `_debug.hpp` | 대기 | 주석 점검 |
| 7 | `log_applier.c` | 대기 | 가장 큼. 아래 별도 목록 |

## log_applier.c 할 일

- **한글 주석 50줄(약 15블록) 영문화:**
  - 482~489: 큐 구조 설명. 내용이 큐 파일로 옮겨졌으므로 해당 헤더로 옮기거나 줄인다.
  - 1130~1367: collect, retire 흐름.
  - 5658~5664: `la_retrieve_ws_label` 함수 헤더.
  - 8247, 11275: coordinator의 dbname 락 선행 획득.
  - 8636~8647, 9036~9038, 9226: WS_LABEL → COMMIT dependency 홀더.
- **`writeset PoC` / `PoC drain` 접두사 9곳과 `(C1)`, `(Hook A)` 기호를 제거한다:** 380, 491, 1144, 5658, 9050, 9362, 11802 등.
- **날짜 참조를 제거한다:** `(log diet, 2026-08-11)` 4곳, 게이트의 `(2026-10-08)` 1곳.
- **reader → coordinator로 통일한다:**
  - 주석의 `reader` 48곳.
  - 변수 `la_reader_rate_*` 3개, 매크로 `LA_READER_RATE_CHECKPOINT_INTERVAL`.
  - trace `[WSET] reader ...` 12곳. 바꾸기 전에 분석 스크립트가 이 문자열을 파싱하는지 확인한다(하니스에는 없음).
- **함수명을 정리한다:**
  - `la_is_supported_poc_item` → `la_is_parallel_apply_item`
  - `la_collect_apply_results` / `la_collect_worker_results` → 이름 구분. 제안: `la_collect_and_retire_results`
  - `la_gate_*` static 5개 → `la_coordinator_*` (완료)
  - `la_reader_*` 함수 2개 → `la_coordinator_*` (완료)

## 결정 필요 (주석·이름 범위 밖)

| 항목 | 내용 | 제안 |
|---|---|---|
| `TEST ONLY` 디버그 로그 4곳 | 4682, 11005: mark_will_del 진단, 9124, 9148: `ws_reader DISPATCH/PARK`. 로그 출력 외 동작 없음 | 제거 |
| hdr_page guard (897~) | `LA_HDR_PAGE_GUARD=1`로 켜는 mprotect 진단 | PR에서 뺄지 결정 |
| `la_apply_worker_test_block_before_commit` | `CUBRID_HA_TEST_BLOCK_CLASS` 장애 주입 훅 | 10-12 결정: PR에는 남기고 TODO(정의, 호출부). 재시작·홀·in-flight list 가득 참 테스트 뒤 제거. 계속 필요하면 debug 전용 또는 기동 시 한 번만 환경 변수 읽기. PR 설명에 명시 |

## 현재 작업 트리 상태 (`cubrid-applier`, 미커밋)

- 병렬 applier 파일 13개를 `src/transaction/applier/`로 이동했고, CMake 2곳을 고쳤다(staged). 별도 워크트리에서 release 빌드가 통과했다.
- 게이트를 정렬 링으로 바꿨고(598→453줄), `la_gate_mark_completed`는 void가 됐다.
- `log_applier.c`의 static `la_gate_*` 5개와 `la_reader_*` 2개를 `la_coordinator_*`로 바꿨다.
- 위 변경은 모두 ninja로 해당 오브젝트만 컴파일해 확인했다. 전체 빌드와 실행 검증은 아직 하지 않았다.
- 별도 워크트리 `cubrid-applier-dir` / 브랜치 `feature/CBRD-27508-applier-dir`가 남아 있다. 삭제 여부는 미정이다.

## PR 뒤 버그 단계

1. **레코드 풀 4K 결함:** 워커 기동을 `la_find_log_pagesize`, `la_init_cache_log_buffer` 뒤로 옮긴다. 근거는 [[wide-divergence-analysis-20261011]]와 X1, X3 재실행 결과(10-11 23시)다.
2. 위 수정 후 slave를 재구성하고 X1, X3를 다시 돌린다. wide 결함 B와 X3 serial 차이(1040 vs 1020)가 같은 원인인지 확인한다.
3. 결함 3(복구 구간 직렬화), 결함 4(deadlock 희생자 repl_force)의 재시작 테스트. 이때 `recovery_range_open` 플래그 제거도 함께 검증한다(todo `CBRD-27508 - recovery_range_open 플래그 제거`).
   - 10-12: `la_coordinator_serialize_recovery_range` 호출 두 곳을 주석 처리했다(함수와 TODO는 남김). 복구 구간도 이제 병렬로 적용된다. 10-11 load20 2차에서 병렬 복구 교착 9건은 실측했지만, 어느 락이 엇갈렸는지와 이 함수가 막는지는 확인하지 않았다. 당시 영구 정지의 직접 원인은 결함 4(희생자가 락을 놓지 않음)였다.
   - 순서: ① 결함 4만 고치고 호출을 끈 채 재시작 테스트(교착이 나도 재시도로 진행되는지, 데이터 일치) ② 교착이 나면 락 덤프로 원인 확정 ③ 호출을 켜고 같은 테스트 ④ 결과로 함수 유지·삭제 결정. 삭제하면 `recovery_range_open`과 관련 TODO도 정리한다.
   - 10-12: 복구 구간 이름은 recovery range로 확정하고 바꿨다(함수, `LA_INFO`/`LA_STATS` 필드, 주석, trace). 위 결정 뒤로 미룬 것은 직렬화 함수를 다시 켤지(병렬/직렬)와 그 함수 Note 재작성뿐이다.
4. **DDL 시나리오 테스트:** 10-12에 slave의 statement 필터(`la_is_supported_poc_item`)를 지웠다. 이 필터는 CREATE/DROP TABLE과 statement DML 5종만 적용하고 나머지 statement를 조용히 버렸다(PoC `2047f7208`부터 있음). 이제 develop처럼 모든 statement를 적용하고, 순서는 마스터의 commit order 라벨(`repl_log_insert_statement`의 `wset_fallback_to_commit_order`)과 history 초기화가 보장한다. 병렬 경로에서 처음 실행되는 종류를 하니스로 확인한다.
   - 대상: ALTER TABLE(컬럼 추가·삭제), CREATE/DROP INDEX(unique 포함), TRUNCATE, CREATE/ALTER/DROP SERIAL, GRANT/REVOKE.
   - 확인: DDL 직후 같은 테이블 DML이 새 스키마로 적용되는지(다른 워커 연결의 스키마 캐시 갱신), master/slave 스키마·데이터·serial 일치.
   - 함께 볼 것: X3 serial 차이(1040 vs 1020)가 이 필터와 관련 있었는지.
   - 함께 볼 것: 하니스 slave 로그에서 `[WSET] reader commit`이 `items>0 has_label=0`인 건이 0건인지. 10-12에 복제 아이템이 있는데 라벨이 없는 커밋을 커밋 순서(직전 커밋 대기)로 처리하도록 바꿨다. writeset 마스터와 짝이면 이 경로는 타지 않아야 한다.
   - 함께 볼 것: statement 태스크가 다른 워커와 겹치지 않는지. 마스터 라벨 계산·커밋·이력 비우기 사이에 틈이 있어 겹칠 수 있다(10-12 코드 확인, [[serial-guarantee-analysis-20261012]] 6절). 다른 테이블 DML 부하를 DDL과 동시에 건다.
   - 10-12: `la_update_query_execute`/`_with_values`를 develop 본문(`db_execute`)으로 되돌렸다(스냅샷 무효화 복원, 디버그 로그 제거). `la_sql_compile_mutex`는 coordinator의 apply info SQL과 겹치지 않도록 남기고 TODO를 달았다.
5. 직렬 보장 관련(마커 판정이 writeset에서 보장되지 않음, 강제 직렬 모드, 커밋 순서 보존): [[serial-guarantee-analysis-20261012]]의 "남은 일".
6. 실험이 끝나면 slave conf에서 `er_log_vacuum=24`를 빼고 기준 md5(57f0224f)로 되돌린다.

## 10-12 추가 진행

- `la_gate_has_open_commits` 삭제(`la_gate_order_get_count () == 0`으로 대체), drain 타임아웃 메시지가 링 개수를 찍도록 변경.
- `la_gate_is_satisfied`에서 `dep_is_read` 인자 삭제(10-08 A1 이후 판정에 쓰이지 않음). 근거와 남은 일은 todo `CBRD-27508 - FK 부모-자식 순서 정밀 테스트`에 있다. 설계 문서 4곳 수정과 부모-자식 순서 정밀 테스트는 PR 뒤 버그 단계에서 한다.
- 위 변경 뒤 cubridcs 링크 통과(00:55). 실행 검증은 아직 하지 않았다.
- wide 진단 trace(`LA_DIAG_RECORD_*`, `LOCATOR_REPL_DIAG_RECORD_LENGTH`, `locator_repl_diag_batch`)에 제거 TODO를 달았다. 레코드 풀 4K 결함 수정을 X1/X3로 확인한 뒤 세 파일(log_applier.c, locator_cl.c, locator_sr.c)에서 함께 지우고 slave 커밋에 합친다.

## CS 커밋 운영 방침 (10-12 결정)

- CS 커밋은 PoC에서 동작이 확인된 멀티 커넥션 코드(CS팀 4월 PoC + 우리 연결 코드)로 고정하고, 그 기준으로 테스트한다.
- CS팀 브랜치(`ctshim/CBRD-26779_multi-thread-to-applylogdb`)는 리뷰 중이라 계속 바뀌므로 지금 따라가지 않는다. 미완성 변경이 섞이면 문제 원인을 가르기 어렵고, develop 반영 때 다시 맞춰야 한다.
- CS팀 작업이 develop에 들어오면 우리 CS 커밋을 그 develop 버전으로 갈아끼운다. 그 뒤 문제가 나오면 CS팀에 리포트한다.
- 알려진 차이(CS팀 브랜치에는 있고 우리 CS 커밋에는 없음): `src/base/area_alloc.c` `area_final`이 목록 해제 시 `area_List_lock`을 잡고, 클라이언트에서는 `pthread_mutex_destroy`를 생략(CS팀 `64a0348db`, 10-05, develop 미반영). 테스트 중 CS 쪽 증상이 보이면 먼저 이런 차이에서 이미 고쳐진 것인지 대조한다.

## 10-12 오후: 복구 구간 상한을 coordinator 단독으로

- 워커 행(`worker_id`) 방식을 없애고, coordinator가 dispatch 전에 `max_committed_lsa`를 먼저 저장하는 방식으로 바꿨다. 상세는 todo `CBRD-27508 - 복구 구간 상한 coordinator 단독 영속화`의 "10-12 구현".
- 이전 스키마로 만든 테스트 DB는 다시 만들어야 한다(`_db_ha_apply_info`에 worker_id 컬럼이 없어짐).

## 10-14 계획: applier 기본 복제 테스트

10-13까지 리팩토링을 슬레이브 커밋(`db6ea4631`)에 모두 합쳤다. 동작이 바뀐 곳이 있어 기본 복제부터 다시 확인한다.

- 준비: 빌드·배포는 지시 후. `_db_ha_apply_info`에서 `worker_id` 컬럼을 뺐으므로 테스트 DB를 새로 만든다. conf는 메모리의 기준값(md5 57f0224f / 68235c04)으로 대조한다.
- 10-12~13에 동작이 바뀐 곳 (기본 복제에서 함께 본다)
  - 복구 구간 상한을 coordinator가 디스패치 전에 저장(`la_coordinator_cover_commit`), 워커 행 제거
  - statement 필터 제거: 모든 statement 적용
  - `la_update_query_execute`를 develop 본문(`db_execute`)으로 복원, `la_statement_context_mutex` 제거
  - 라벨 없는 커밋(아이템 있음)은 직전 커밋 대기: `reader commit`에서 `items>0 has_label=0`이 0건인지
  - 드레인 백스톱이 frontier 정지 기준으로 바뀜
  - DONE 상태 `committed_lsa` 블록을 develop 형태 + frontier 제한으로 되돌림
  - SYSOP_END·COMMIT 처리 함수 분리(`la_coordinator_process_sysop_end`, `la_coordinator_process_commit`, `la_coordinator_submit_task`). 동작 변화 없음
- 확인: master/slave 데이터 일치(slave 접속값 확인 후 직접 교차 조회), slave 로그에 apply 오류 없음, `timeline.py` 파싱 정상
- statement 동시 수행 시 직렬화 확인
  - 목적: statement 트랜잭션(DDL 등)이 slave에서 다른 태스크와 겹치지 않고 혼자 실행되는지. 마스터 라벨(커밋 순서 대체 경로 + `history_start` 바닥값)이 앞뒤를 막는다는 전제를 확인한다. 라벨 계산·커밋 레코드·이력 비우기가 한 임계 구역이 아니어서, 락 충돌 없는 트랜잭션이 끼어들 틈이 있다([[serial-guarantee-analysis-20261012]] 6절).
  - 방법: 다른 테이블 DML 부하(여러 세션)를 거는 중에 DDL(CREATE/DROP INDEX, ALTER TABLE ADD COLUMN, CREATE TABLE)을 반복한다. 서로 다른 테이블의 DDL을 두 세션에서 동시에 내는 경우도 넣는다.
  - 판정: slave trace를 `timeline.py`로 보고, statement 태스크의 begin~done 구간에 다른 워커의 begin/done이 끼는지 센다. 마스터 `WSET_TRACE`의 `CLEAR reason=COMMIT_ORDER_FALLBACK`와 뒤 트랜잭션 `DEPENDENCY`가 그 커밋 LSA 이상인지 대조한다.
  - 겹침이 나오면: 데이터 일치 여부, slave 오류(스키마 캐시·workspace 관련) 유무를 함께 기록하고 대응(slave 배리어 등)을 정한다.

## 일정 (10-12 확정)

- 재시작 테스트는 다음 주(10-19 주)에 한다. 함께 확인할 것:
  - 복구 구간 상한 coordinator 단독 저장(`la_coordinator_cover_commit`)이 커밋된 트랜잭션을 모두 덮는지
  - 복구 구간 직렬화를 끈 상태에서 결함 3 교착이 나는지, 결함 4 수정 후 재시도로 진행되는지
  - `recovery_range_open` 플래그 제거 가능 여부
  - 복구 구간 statement 재적용: todo `CBRD-27508 - 복구 구간 statement 재적용`의 테스트 목록. develop은 데이터와 apply info를 한 트랜잭션으로 커밋해 재적용이 없고, 병렬 applier는 복구 구간을 통째로 다시 적용한다. DDL 오류는 진행을 멈추지 않지만 USE_SBR DML은 이중 반영될 수 있다.
  - 페일오버 드레인 백스톱이 frontier 정지 기준으로 동작하는지(10-12 변경: 총 대기 30초 → frontier가 30초 움직이지 않을 때 재시작)
- 테스트 DB는 새 스키마로 다시 만든다(`_db_ha_apply_info.worker_id` 제거).
- 그 전까지 PR에는 "재시작 경로는 테스트 전"이라고 명시한다.
- "워커 커밋당 UPDATE 비용 측정" 항목은 워커가 더 이상 apply info를 쓰지 않으므로 필요 없다.

## 최우선 테스트 (10-12 지정)

`la_repl_add_object`의 develop 대비 변경 두 가지를 버그 단계에서 가장 먼저 확인한다.

1. **`sm_flush_objects` 삭제:** develop은 repl 객체를 추가하기 전에 그 클래스의 dirty MOP를 flush했다. 지금은 하지 않는다(행 복제는 WS_REPL_OBJ 목록에 쌓이므로 dirty MOP가 생기지 않는다는 판단). statement 복제(DDL, statement DML)는 SQL을 직접 실행해 dirty 객체를 만들 수 있으므로, 같은 트랜잭션에서 statement 뒤에 행 복제가 이어질 때 결과가 develop과 같은지 확인한다. 10-12에 statement 필터를 없애 모든 DDL이 적용되므로 DDL 시나리오 테스트와 함께 한다.
   - 시나리오 예: 한 트랜잭션에서 ALTER TABLE ADD COLUMN 뒤 그 테이블에 INSERT/UPDATE, CREATE INDEX 뒤 DML, TRUNCATE 뒤 INSERT, statement DML(INSERT … SELECT) 뒤 행 DML.
   - 확인: master/slave 데이터·스키마 일치, 워커 오류 없음.
2. **`AU_SAVE_AND_DISABLE` 우회:** 워커 연결의 권한 컨텍스트가 초기화되지 않아 `au_fetch_class`가 실패할 수 있어 권한 검사를 끈 상태로 적용한다(코드 TODO). 워커 연결의 권한을 정식으로 세우는 방법을 CS 쪽 멀티 커넥션 구조와 함께 본다. 권한이 다른 사용자 소유 테이블, GRANT/REVOKE 직후 DML에서 결과를 확인한다.
