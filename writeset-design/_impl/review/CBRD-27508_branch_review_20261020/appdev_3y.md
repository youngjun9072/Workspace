# CBRD-27508 브랜치 리뷰 — 어플리케이션 개발자 3년차

## 1. 리뷰어 관점

- 애플리케이션이 직접 겪는 결과를 중심으로 봤다. slave에 적용된 결과가 master와 같은지(트랜잭션 원자성, serial/AUTO_INCREMENT 값, FK 관계), 사용자 DML에 새로 노출되는 에러 코드와 메시지, 기존 DB·클라이언트와의 호환성, master·slave 양쪽의 성능을 확인했다.
- 3년차 관점에서는 함수 하나하나의 반환값·에러 경로·상태 정리(초기화와 소거)가 맞는지, 중복 코드와 일관성을 확인했다. 범위는 HEAD=`0e411f10f`(`a9a0dc78d..0e411f10f`, 12커밋)이다.

## 2. 검토 범위와 실제로 읽은 경로

| 영역 | 파일 | 읽은 함수·구간 |
|---|---|---|
| master writeset | `writeset.cpp/.hpp`, `writeset_types.hpp`, `writeset_history_map.*` | 전체 (fnv/string/midxkey 해시, add_write/ref_key, find_dependency_*, publish_*, discard/abort/sysop fallback, raise_history_start) |
| master 로그 | `log_manager.c` | `log_initialize_internal` 재시작 floor, `log_sysop_start`, `log_sysop_commit_internal`, `log_sysop_abort`, `log_append_sysop_end_internal`, `log_sysop_fallback_reason`, `log_append_wset_label_*`, `log_commit_local`, `log_complete_for_2pc` |
| master 기타 | `log_record.hpp`, `log_impl.h`, `log_append.cpp`, `log_tran_table.c`, `log_recovery.c`, `replication.c`, `serial.c`, `btree.c`, `locator_sr.c`, `system_parameter.{c,h}`, `error_code.h`, msg 2종 | diff 전체 + `locator_update_index`, `locator_add_or_remove_index_internal`, `locator_lock_and_get_object_internal`, `xlocator_repl_force`, `btree_key_find_and_lock_unique_of_*`, FK 검색 경로(`btree.c:30520~`), `serial_update_serial_object`, `repl_start/end_flush_mark`, `lock_transaction_mvccid` |
| slave | `log_applier.c` | diff 전체 (coordinator 함수군, `la_apply_repl_log`, `la_apply_*_log`, `la_flush_repl_items`, `la_commit_transaction`, `la_detach_sysop_fragment`, `la_coordinator_process_sysop_end/commit`, `la_get_wset_label`, `la_change_state`, `la_apply_log_file` 메인 루프, max_committed_lsa 저장·조회), 기준선 `la_apply_repl_log`(a9a0dc78d) 비교 |
| slave 모듈 | `applier/*` | gate, pending, inflight, task_queue, result_queue, worker 전체 |
| 기타 | `log_applier_sql_log.c`(변경 없음, worker가 호출하므로 확인), `schema_system_catalog_install.cpp`, `CMakeLists.txt`, `work_space.c` | 호출부와 반환값만 |
| 테스트 | `unit_tests/writeset/test_writeset.cpp`, `unit_tests/log_applier/*` | 케이스 목록, overflow·sysop 관련 케이스 |

## 3. 발견 사항

### 3.1 에러

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| E1 | High | `log_applier.c:7520-7537`, `:7446-7450`, `:7815-7818`, `:6983` | 재시작 후 committed_lsa 이하 serial fragment가 다시 적용됨 | `else { LA_DEBUG_LOG(... skip_sysop_end_already_committed ...) }`에서 항목을 해제하지 않고 label holder도 비우지 않음. `la_apply_repl_log`의 per-item `last_committed_rep_lsa` 필터는 제거됨 | 장기 트랜잭션 X의 NEXT_VALUE(S1, 100→101) 이후 Y의 S2(→102) 적용, applylogdb 재시작 → X의 S1 항목이 X 슬롯에 남아 X 커밋(또는 다음 일반 SYSOP_END)에서 재적용 → slave serial이 101로 역행 → failover 후 AUTO_INCREMENT 중복 키 | 확정(코드 경로) | 신규 |
| E2 | High | `log_applier.c:6705`, `:10325-10357` | failover drain 30초 고정 타임아웃이 장기 트랜잭션에서 재시작 루프를 만듦 | `#define LA_DRAIN_TIMEOUT_MSEC 30000`, frontier가 30초 동안 움직이지 않으면 `la_applier_need_shutdown = true` | slave 적용에 30초 넘게 걸리는 대형 트랜잭션 1건 + master 다운 → 30초 후 재시작 → 같은 트랜잭션이 recovery range에서 처음부터 다시 적용 → 또 30초 초과 → DONE이 나오지 않아 승격이 끝나지 않음 | 확정(루프), 추정(HB 쪽 귀결) | 신규 |
| E3 | High | `schema_system_catalog_install.cpp:1095-1097`, `log_applier.c:2897`, `:3349` | `_db_ha_apply_info`에 컬럼 2개를 추가했지만 기존 DB용 마이그레이션이나 대체 경로가 없음 | `SELECT max_committed_lsa_pageid, max_committed_lsa_offset FROM ...` 실패 시 `la_get_last_ha_applied_info`가 에러 반환 | 기존에 만든 slave DB에 새 바이너리만 배포 → SELECT가 컬럼 없음 에러 → applylogdb가 기동되지 않음(복제 중단) | 확정(코드), 추정(업그레이드 정책) | 신규 |
| E4 | High (`ha_enable_sql_logging=yes`일 때만) | `log_applier.c:6196`, `:6377`, `:6580`, `:6848` → `log_applier_sql_log.c:539`, `:619` | 락 없는 SQL 로그 writer를 여러 worker가 동시에 호출 | `static FILE *log_fp`, `++sl_Info.last_inserted_sql_id`, 파일 회전 시 `fclose (old_fp)`, mutex 없음 | worker 2개 이상이 동시에 `sl_write_sql` → 한쪽이 회전으로 `fclose`한 FILE*에 다른 쪽이 `fprintf` → UAF·크래시, sql_id 중복, 로그 행 섞임 | 확정 | 신규(병렬화로 노출) |
| E5 | Medium | `writeset.cpp:1111-1118` | overflow(commit-order fallback) 경로만 `history_start` 하한을 적용하지 않음 | `if (tdes->wset_overflow) { LSA_COPY (wset_parent_out, &wset_History.prev_commit_lsa); ... return; }` (일반 경로와 sysop 경로는 하한 적용) | (a) master 재시작 직후 첫 DDL은 prev_commit_lsa가 NULL이라 label이 NULL → slave gate를 즉시 통과(`la_gate_is_satisfied` NULL=true)해 재시작 전 backlog와 병행 적용. (b) 미커밋 X의 serial sysop S(history_start=S) 뒤에 커밋한 `ALTER SERIAL`/DDL이 S를 기다리지 않아 slave에서 S가 DDL 뒤에 적용됨 → serial 값 불일치 | 확정(코드), 추정(b의 DDL 적용 경로) | 신규 |
| E6 | Medium | `btree.c:30530-30560`, `locator_sr.c:13303` | FK 부모 조회는 "커밋 중인 inserter"를 기다리지 않음 | X_LOCK 수정 경로(`locator_is_inserter_committing`)와 unique·삭제 경로(`btree_is_deleter_committing`)만 보강. FK 경로는 `btree_is_active_other_inserter`(active일 때만)로 판정 | 부모 P가 `complete_mvcc`를 마치고 커밋 레코드를 쓰기 전에 자식 C가 FK 검사를 통과(S 락 즉시 획득)하고 먼저 커밋 → C의 REF probe는 P를 못 찾음(publish 전) → slave에서 C가 먼저 적용 → `dont_check_fk=false`라 FK 에러 → 자식 행이 slave에서 누락(fail_counter만 증가) | 확정(경로), 추정(발생 빈도) | 기존 창 + 신규 보강 누락 |
| E7 | Medium | `log_applier.c:4638-4666`, `:7815-7818` | label 읽기 실패를 "의존성 없음"으로 처리 | `la_get_wset_label`이 실패 시 `LSA_SET_NULL (dependency_seq); return;`인데 호출부는 무조건 `la_wset_label_trid = lrec->trid` | 로그 페이지 경계 읽기 실패 → NULL dependency를 가진 label 있음으로 판정 → 바로 dispatch → 충돌 트랜잭션과 병행 적용. `la_coordinator_set_commit_dependency` 주석이 말하는 안전한 기본값(label이 없으면 이전 커밋 대기)과 반대 | 확정 | 신규 |
| E8 | Medium | `log_applier.c:1519-1522`, `:1046`, `:1087`, `log_applier_result_queue.cpp`(`la_result_queue_pop`), `log_applier_worker.cpp`(`la_worker_startup_failed`) | worker가 모두 기동에 실패하면 coordinator가 결과 큐에서 영원히 대기 | `la_request_shutdown`이 플래그만 세우고 result queue는 깨우지 않음. `la_result_queue_pop`은 count==0이고 shutdown이 아니면 `pthread_cond_wait` | 재시작 직후 recovery range에서 coordinator가 `la_coordinator_wait_until_retired` → `la_result_queue_pop` 진입, worker들이 `db_restart_sub` 실패로 전부 종료 → 결과가 영원히 오지 않음 → 프로세스는 살아 있는데 복제가 멈춤(HB 재시작도 없음) | 확정 | 신규 |
| E9 | Medium | `writeset.cpp:780`, `:887`, `:925`, `:705-707`, `locator_sr.c:8021-8070`, `:8747-8788` | 복제 내부의 키 생성 실패가 사용자 DML 실패로 노출 | `wset_error (NO_ERROR, "child FK and parent PK column counts do not match")` 등 → `goto error` → DML 실패(`ER_HA_WRITESET_KEY_BUILD_FAILED`, `ER_TP_CANT_COERCE`) | HA master에서 지금까지 성공하던 INSERT/UPDATE가 "Writeset key construction failed"로 실패. 앱은 이 에러를 예상하지 않음. overflow로 강등해도 정합성은 유지되는데 실패를 택함 | 확정(경로), 추정(도달 가능한 입력) | 신규 |
| E10 | Low | `serial.c:1225-1250`, `log_manager.c:4036-4073` | serial 키 수집이 항상 버려지는 dead work이면서 실패 경로는 남아 있음 | serial 업데이트는 sysop 안이고 `repl_item_count>0`이라 `wset_discard_sysop_keys`가 항상 버림. NULL BTID이면 `wset_fallback_to_commit_order (..., WSET_FALLBACK_STATEMENT_REPLICATION)` | 키 생성 OOM 시 NEXT_VALUE/AUTO_INCREMENT INSERT가 실패. NULL BTID 경로는 바깥 트랜잭션 전체를 overflow로 만들어 커밋 시 history 전체 clear를 유발하고, trace 사유도 STATEMENT로 잘못 남김 | 확정 | 신규 |
| E11 | Low | `log_applier.c:7495-7502` | labeled SYSOP_END에 항목이 없으면 holder를 비우지 않음 | `la_coordinator_complete_without_task (final)` 뒤 `la_wset_label_trid` 그대로 | 같은 trid의 이후 일반 SYSOP_END마다 holder가 일치해 `complete_without_task`가 반복(ring push·trace 오표시). 다음 커밋 label이 holder를 덮어써 결과 손상은 없음 | 확정 | 신규 |

#### E1 상세 — 재시작 후 serial fragment 재적용 (High)
- `la_coordinator_process_sysop_end`는 `LSA_GT (final, &la_Info.committed_lsa)`일 때만 fragment를 떼어낸다. 그 외(`:7520` else)에는 trace만 남긴다. label 레코드 처리(`:7815-7818`)에는 committed_lsa 검사가 없어서 holder(`la_wset_label_trid`)가 그대로 남는다.
- 재시작하면 required_lsa(열린 X의 시작 이하)부터 다시 읽는다. X의 serial 항목은 `la_set_repl_log`로 X 슬롯에 다시 쌓이는데, 그 SYSOP_END가 committed_lsa 이하라서 떼어내지도 해제하지도 않는다.
- 이후 경로는 둘이다. (1) X의 다음 일반 SYSOP_END(btree/heap sysop, 흔함)가 `la_wset_label_trid == lrec->trid && sysop_apply->head != NULL` 조건(`:7450`)에 걸려 낡은 dependency로 fragment가 된다. (2) X 커밋 task에 섞여 적용된다. 어느 쪽이든 `la_apply_repl_log`는 트랜잭션 단위로만 건너뛰므로(`:6983` `already_committed = LSA_LE (commit_lsa, &la_Info.last_committed_lsa)`) 이미 적용된 `_db_serial` 행 이미지를 다시 덮는다.
- 기준선은 `LSA_GT (&item->lsa, &la_Info.last_committed_rep_lsa)`로 항목 단위 필터를 했다(a9a0dc78d `la_apply_repl_log`). 이 브랜치는 그 필터를 없앴다.
- 결과: serial `current_val`이 slave에서 과거 값으로 돌아간다. failover 후 NEXT_VALUE가 이미 나간 값을 다시 내주므로 애플리케이션 INSERT가 PK 중복으로 실패한다. INCR/DECR 클릭 카운터도 같은 방식으로 역행한다.
- 제안: committed_lsa 이하 SYSOP_END도 holder가 일치하면 항목 `≤ final`을 해제하고 holder를 비운다. holder는 trid가 일치하지 않는 레코드를 만나도 소거한다.

#### E2 상세 — 고정 drain 타임아웃 (High)
- `la_Drain_wait_start_ns` 기준으로, frontier가 30초 동안 그대로이면 재시작한다. gap-free frontier라서 ring 맨 앞의 한 트랜잭션이 30초 넘게 돌면 뒤 트랜잭션이 아무리 끝나도 frontier는 움직이지 않는다.
- 재시작 후 그 트랜잭션은 recovery range에 들어가 처음부터 직렬로 다시 적용되고, 역할 변경 상태는 그대로이므로 같은 타임아웃을 다시 만난다. 직렬 applier(기준선)는 끝까지 적용한 뒤 DONE을 냈다.
- 제안: "frontier 정지"가 아니라 "worker 진행 없음"(예: in-flight 항목의 적용 건수 증가)을 기준으로 삼고, 시간은 파라미터로 둔다.

#### E3 상세 — 카탈로그 호환 (High)
- 새 DB는 `schema_system_catalog_install.cpp`로 컬럼이 생기지만, 기존 DB의 `_db_ha_apply_info`에는 없다. `la_get_ha_apply_max_committed_lsa`의 `res < 0`이 그대로 반환되어 기동이 실패한다. 리포지토리 안에서 해당 컬럼명을 쓰는 곳은 두 곳(install, applier)뿐이고 마이그레이션은 없다.
- 제안: 컬럼이 없으면 range를 비운 채(`recovery_boundary_lsa` NULL) 경고만 남기고 계속 진행하거나, 마이그레이션 스크립트를 추가한다. 코드의 TODO에 있는 final_lsa 재사용안도 검토할 만하다.

#### E4 상세 — SQL 로그 동시 쓰기 (High, 조건부)
- `la_apply_insert/update/delete_log`와 `la_apply_statement_log`는 worker 스레드에서 돈다. `la_enable_sql_logging`이면 `sl_write_*_sql` → `sl_write_sql`이 전역 `log_fp`와 `sl_Info`를 락 없이 갱신한다. 파일 회전(`sl_open_next_file`)에서 `fclose`가 일어나므로 UAF가 생긴다.
- 그 외에도 SQL 로그 순서는 더 이상 커밋 순서가 아니다. 이를 검증용으로 쓰는 운영자를 위해 문서화가 필요하다.
- 제안: `sl_write_sql` 전체를 mutex로 감싸거나, worker 수가 2 이상일 때 SQL 로깅을 거부·경고한다.

#### E5 상세 — overflow 경로 하한 누락 (Medium)
- `wset_find_dependency_in_range`는 두 분기 모두 `history_start`로 하한을 둔다(`:1032`, `:1091-1095`). `wset_find_sysop_fallback_dependency`도 하한을 둔다(`:1444-1448`). overflow 분기만 `prev_commit_lsa`를 그대로 쓴다.
- `log_initialize_internal`(`log_manager.c:1513`)은 재시작 floor를 `history_start`에만 올리고 `prev_commit_lsa`는 NULL로 남긴다. 그래서 재시작 뒤 첫 overflow 커밋(DDL 같은 statement 복제, 키 한도 초과 트랜잭션)은 label이 NULL이 된다.
- 단위 테스트(`test_writeset.cpp:980`)는 `raise_history_start` 뒤의 일반 트랜잭션만 검증하고 overflow 트랜잭션은 다루지 않는다.
- 제안: overflow 분기에도 동일한 `history_start` 하한을 적용하고, 테스트 1건을 추가한다.

#### E6 상세 — FK 커밋 창 (Medium, 추정)
- 커밋 순서는 `logtb_complete_mvcc` → (후처리) → 커밋 레코드 → publish → 락 해제다. MVCC insert는 행 X 락을 잡지 않으므로, 이 창에서 자식의 FK 검사는 `DELETE_RECORD_CAN_DELETE`로 판정되어 S 락을 바로 얻는다.
- 이 브랜치는 같은 창을 X 수정(d1d02b9e4)과 unique·삭제(79268ae56) 두 경로에서 막았다. FK 부모 조회 경로는 막지 않았다.
- slave의 `xlocator_repl_force`는 `dont_check_fk=false`로 insert하므로, 자식이 먼저 적용되면 실패하고 행이 누락된다.
- 제안: FK 부모 키를 찾았을 때도 `btree_is_deleter_committing`과 같은 "inserter committing" 검사를 넣어 self-lock을 기다리게 한다.

#### E8 상세 — 결과 큐 영구 대기 (Medium)
- `la_coordinator_wait_until_retired`와 `la_coordinator_wait_for_inflight_slot`은 `la_applier_need_shutdown`을 보지 않는 블로킹 `la_result_queue_pop`을 쓴다. `la_request_shutdown`(worker 콜백)은 result queue에 shutdown 신호를 보내지 않는다.
- 제안: `la_request_shutdown`에서 `la_result_queue_signal_shutdown()`을 부르거나, pop을 timed wait으로 바꾸고 플래그를 확인한다.

### 3.2 모듈화

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| M1 | Medium | `log_applier.c:7321-7660` (holder, `la_coordinator_process_sysop_end`, `la_coordinator_set_commit_dependency`, `la_detach_sysop_fragment`) | coordinator의 판단 로직이 11,131행 C 파일 안의 static 함수와 static 전역(holder)으로 남아 단위 테스트가 불가능 | `static int la_wset_label_trid`, 테스트 디렉터리에는 queue/gate/pending/inflight만 있음(`grep process_sysop_end unit_tests` 결과 0건) | E1·E7·E11이 모두 이 무테스트 구간에서 나옴. 재시작·label 조합 회귀를 잡을 수단이 없음 | 확정 | 신규 |
| M2 | Low | `writeset.cpp:599-659`, `:883-965`, `:668-681` vs `locator_sr.c:7712-7724` | 값→해시(문자/MIDXKEY/그 외) 경로가 write와 ref에서 3갈래씩 복제됨. `wset_error`와 `locator_wset_error`도 거의 같음 | malloc→memset→`or_pack_mem_value`→`wset_fnv1a`→`wset_push_hash`→trace 블록 반복 | 한쪽만 고치는 실수(예: NULL·도메인 처리)가 생기기 쉬움 | 확정 | 신규 |
| M3 | Low | `log_manager.c:4000-4030`, `:4775-4783` | NEED_FLUSH 항목 수를 세는 루프 3벌 | `if ((repl_type == DATA \|\| STATEMENT) && must_flush == LOG_REPL_NEED_FLUSH) count++` 반복 | 조건이 갈라지면 label 여부와 trace가 어긋남 | 확정 | 신규 |
| M4 | Low | `log_applier.c:1039-1070` vs `:1080-1110`, `:9863-9895` | `wait_until_retired`와 `wait_for_inflight_slot` 본문(pop→record→advance→retire)이 같음. `collect_and_retire` 에러 분기 5개 중 3개가 동일한 처리 | `else if (error == ER_HA_LA_EXCEED_MAX_MEM_SIZE) { need_shutdown = true; break; } ... else if (error != NO_ERROR) { 동일 }` | E8 같은 수정을 두 곳에 해야 함 | 확정 | 신규 |
| M5 | Low | `writeset.cpp:465`(캐시) vs `log_manager.c:4076`, `serial.c:1240`, `log_applier.c` 다수(`prm_get_integer_value`) | trace level을 읽는 방식이 섞여 있음 | `wset_Trace_level` 캐시와 매번 `prm_get_integer_value` 호출이 공존 | 동적으로 바꿨을 때 서버 안에서 일부 trace만 바뀜 | 확정 | 신규 |

### 3.3 아키텍처 (성능·호환 포함)

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| A1 | Medium | `log_manager.c:4036-4073` | serial을 갱신하는 sysop마다 `history_start`가 올라가 전역 barrier가 됨 | `wset_raise_history_start (&sysop_lsa, "SYSOP_COMMIT_ORDER")`, TODO에도 명시 | AUTO_INCREMENT PK 테이블(흔함)에 동시 INSERT → 거의 모든 커밋이 직전 serial sysop 이전의 모든 커밋을 기다림 → 병렬 적용 이득이 거의 사라짐 | 확정(동작), 추정(정도) | 신규 |
| A2 | Medium | `locator_sr.c:13195-13209`, `:13303-13312`, `btree.c:27208-27225` | master의 UPDATE/DELETE마다 MVCCID self-lock을 조건부로 시도 | `return MVCCID_IS_NORMAL (insert_mvccid) && !logtb_is_current_mvccid (...) && !is_active (insert_mvccid);` 이 조건은 vacuum 전 모든 커밋 행에서 참 → `lock_transaction_mvccid (S, COND)` 후 unlock | 복제 서버의 모든 행 수정에 lock 해시 삽입·삭제가 한 번씩 추가됨(OLTP hot path). slave worker 수가 1이어도 master 쪽 비용을 끌 스위치가 없음 | 확정(경로), 추정(비용 크기) | 신규 |
| A3 | Medium | `locator_sr.c:8747-8788` | UPDATE에서 키가 그대로여도 old·new 키를 모두 수집 | "Collect both old and new keys without relying on UPDATE key-comparison equivalence." MVCC 클래스는 모든 인덱스를 순회 | PK와 UNIQUE 하나가 있는 테이블에서 60만 행 UPDATE → 240만 항목 → 기본 한도 1,000,000 초과로 overflow → 커밋 시 history 전체 clear → 이후 트랜잭션 전부 이 커밋 뒤로 직렬화. 같은 해시면 하나만 넣어도 안전함(해시가 이미 collation을 반영) | 확정 | 신규 |
| A4 | Medium | `log_tran_table.c:1622`, `:1706`, `writeset_types.hpp` | `wset_hashes.clear()`가 capacity를 유지 | `std::vector::clear` (overflow 경로만 `swap`으로 해제). 항목 24B × 최대 history_size(1M) | 대형 배치를 한 번이라도 돌린 세션마다 tdes에 약 24MB가 남음. 세션 100개면 약 2.4GB가 서버 메모리에 고정 | 확정 | 신규 |
| A5 | Medium | `CMakeLists.txt:607` | `MULTI_CONN_TO_A_SERVER`를 전역 `add_definitions`로 켬 | `add_definitions(-DMULTI_CONN_TO_A_SERVER)` → CS 라이브러리 92곳의 분기가 모든 클라이언트(CAS, csql, 유틸)에 적용 | applylogdb만 필요한 기능이 브로커 CAS 등 일반 애플리케이션 경로의 동작과 성능을 바꿀 수 있음(내부 미분석) | 확정(범위), 추정(영향) | 신규 |
| A6 | Low | `log_applier.c:9901-9943` | 캐시 mutex를 잡은 채 copied log header 재읽기와 아카이브 삭제(unlink)를 수행 | `pthread_mutex_lock (&la_Info.cache_pb->mutex); check_reinit_copylog (); ... la_remove_archive_logs (...)` | 아카이브 여러 개를 지우는 동안 모든 worker의 페이지 fetch가 멈춤 → 지연이 튐 | 확정(경로), 추정(지연 크기) | 신규 |
| A7 | Low | `log_applier_pending.cpp:98`, `log_applier_inflight.cpp:225` | 준비된 task 찾기와 결과 매칭이 선형 탐색 | `for (cur = la_Pending_head; ...) if (!la_gate_is_satisfied) continue;`, `find_by_seq` 루프 | hot key로 최대 32K task가 park되면 결과 1건마다 전체 스캔. seq는 연속이므로 `head + (seq - head.seq)`로 O(1) 가능 | 확정 | 신규 |

### 3.4 리팩토링

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| R1 | Low | `log_applier.c:1401`, `:1434-1453` | 테스트 전용 훅이 release 빌드에 남아 커밋마다 `getenv`를 두 번 호출 | `getenv ("CUBRID_HA_TEST_BLOCK_CLASS")`, `usleep (block_msec * 1000)` | 환경변수 하나로 운영 applier를 60초씩 멈출 수 있음. 커밋마다 비용 발생 | 확정 | 신규 |
| R2 | Low | `log_applier.c:872`, `:9590` 등 | coordinator를 "reader"로 부르는 trace와 메시지가 남아 있음 | `"[WSET] reader schedule ..."`, `"applylogdb reader exit: ..."` | 운영 로그의 용어가 코드·문서와 어긋남 | 확정 | 신규 |
| R3 | Low | `log_applier.c:8162` | `la_commit_transaction`의 `commit_lsa` 인자를 쓰지 않음 | 시그니처만 바뀌고 본문에 사용처 없음 | 읽는 사람이 commit_lsa로 무엇을 하는지 오해함 | 확정 | 신규 |
| R4 | Low | `locator_sr.c:8085-8092`, `:8865-8869` | 동작이 아니라 이력을 서술하는 주석 | "Pre-existing defect fixed here: ... Seen when ..." | 주석이 시간이 지나면 의미를 잃음. 동작 한 문장과 커밋 메시지로 분리하는 편이 낫다 | 확정 | 신규 |
| R5 | Low | `log_manager.c:4013` | trace 전용 분류(`log_sysop_fallback_reason`, repl_data unpack)를 trace level과 상관없이 수행 | `sysop_reason = log_sysop_fallback_reason (tdes, repl_start_index);` 무조건 | 복제 sysop마다 쓸모없는 unpack 비용 | 확정 | 신규 |
| R6 | Low | `log_applier.c:1210` | 함수 지역 `static UINT64 last_store_ns`를 `la_init`에서 초기화하지 않음 | 프로세스 안에서 applier 재시작 후에도 이전 값 유지 | 재시작 직후 첫 저장이 최대 interval만큼 늦어짐(재적용 범위만 넓어짐) | 확정 | 신규 |

## 4. 미검증 의심

1. **파티션 부모 FK의 해시 불일치**: REF는 `index->fk->ref_class_oid`와 `ref_class_pk_btid.vfid`(`locator_sr.c` `locator_wset_collect_fk_ref`)로 만든다. 부모 WRITE는 실제 행이 있는 파티션의 class OID와 그 파티션 인덱스 VFID로 만든다. 부모가 파티션 테이블이면 두 해시가 만나지 않을 수 있다. CUBRID가 파티션 테이블을 FK 대상으로 허용하는지 확인하지 못했다.
2. **trailing space와 PAD 의미**: 단일 컬럼 문자열 키는 `lc->mht2str`로 해시한다. 인덱스 비교가 끝 공백을 무시하는 경우와 해시가 같은 결과를 내는지 collation별로 확인하지 못했다. 다르면 같은 키가 다른 해시로 갈라져 의존성을 놓친다.
3. **`la_apply_update_log`의 NULL target_lsa 무음 skip**(`log_applier.c:6305`): master 쪽 `repl_log_abort_after_lsa` 수정과 짝을 이루지만, 다른 master 경로가 LSA를 채우지 못한 경우에도 slave가 fail_counter 없이 건너뛴다. 기존에는 실패로 보였던 불일치가 숨을 수 있다.
4. **`wset_find_dependency_in_range`의 `min(wset_parent, prev_commit_snapshot)`**: 락으로 보호되지 않는 충돌(E6 같은 커밋 창)에서는 snapshot 이후에 publish된 후행 커밋이 더 작은 값으로 잘릴 수 있다. 정상 락 경로에서는 안전하다고 판단했다.
5. **worker의 재시도 루프**(`LA_SLEEP (10, 0); continue;`): shutdown 플래그를 보지 않으므로 `la_stop_apply_workers`의 join이 막힐 수 있다. 기준선의 단일 스레드도 같은 루프여서 동작은 같다(기존).
6. **item 단위 deadlock 에러**: `la_apply_*_log` 안의 클래스 fetch 등에서 deadlock victim 에러가 나면, retry 목록에 없는 한 "error = NO_ERROR"로 계속 진행한다. 서버가 이미 트랜잭션을 abort했다면 남은 항목만 새 트랜잭션으로 커밋되어 부분 적용이 될 수 있다. flush 경로는 이번 `xlocator_repl_force` 수정으로 전체 실패가 되지만, flush 이전 단계의 deadlock 가능성은 확인하지 못했다.

## 5. 총평

- 등급별 건수: High 4 / Medium 11 / Low 14 (총 29)
- master는 키를 수집해 label로 의존성을 전달하고, slave는 gate·pending·in-flight로 적용한다. 큰 틀은 일관되고, 큐·gate·worker의 수명 관리와 에러 반환은 대체로 꼼꼼하다.
- 애플리케이션 입장에서 결과가 달라지는 문제는 경계 상태에 몰려 있다. **재시작·복구(E1, E3, E5)와 failover(E2)** 가 그렇다. 특히 E1은 serial/AUTO_INCREMENT 값을 slave에서 되돌려 failover 뒤 중복 키 에러를 낼 수 있다. 기준선의 항목 단위 필터를 트랜잭션 단위로 바꾸면서 생긴 틈이다.
- 이 경계 로직은 단위 테스트가 없는 `log_applier.c` 안의 static 상태에 있다(M1). label holder와 sysop fragment 처리를 별도 모듈로 빼서 재시작 시나리오 테스트를 붙이는 것이 가장 효과가 크다.
- 성능 면에서 master는 slave 설정과 상관없이 항상 비용을 낸다(A2, A3, A4). slave의 병렬 이득은 AUTO_INCREMENT 부하에서 크게 줄어든다(A1). 운영 문서에 "어떤 부하에서 병렬화가 효과가 있는지"를 적고, master 쪽 비용을 줄이는 개선(키 중복 제거, capacity 해제)부터 처리하기를 권한다.
- 호환성은 E3(카탈로그)과 E9(새 사용자 에러)를 릴리스 전에 정리해야 한다.
