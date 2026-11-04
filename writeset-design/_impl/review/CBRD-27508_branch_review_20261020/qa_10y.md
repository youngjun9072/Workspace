# CBRD-27508 브랜치 리뷰 — QA 10년차

## 1. 리뷰어 관점

- 역할(QA): "이 변경을 어떻게 깨뜨릴 수 있는가, 깨졌을 때 무엇으로 알아채는가"를 기준으로 봤다. 경계·실패 경로(재시작, 장애, I/O 실패, 자원 고갈), 회귀 범위(브랜치가 HA 전체·비HA 바이너리까지 건드리는 곳), 단위테스트가 실제로 덮는 범위와 덮지 못하는 범위, 그리고 각 결함의 재현 시나리오를 중점으로 했다.
- 연차(10년): master writeset 라벨 → slave gate로 이어지는 불변식이 재시작·failover·업그레이드에서도 유지되는지, 기존 CUBRID의 exactly-once 적용 모델·로그 포맷·카탈로그와 정합하는지, 운영 중 숨은 비용(락·메모리·지연)과 장기 유지보수성을 함께 봤다.

## 2. 검토 범위와 실제로 읽은 경로

범위: `git diff a9a0dc78d 0e411f10f` (12 커밋, HEAD=0e411f10f). 기준선 비교는 `git show a9a0dc78d:<path>`.

정밀 분석으로 읽은 코드
- `src/transaction/writeset.cpp` 전체 (해시: `wset_fnv1a`, `wset_string_hash`, `wset_string_pseudo_bytes`, `wset_midxkey_hash` / 수집: `wset_push_hash`, `wset_add_write_key`, `wset_add_ref_key`, `wset_make_parent_midxkey` / 의존성: `wset_select_candidate`, `wset_find_dependency_in_range`, `wset_find_dependency_from_history` / 게시: `wset_publish_keys`, `wset_history_reserve_capacity`, `wset_publish_with_capacity`, `wset_clear_overflow_history`, `wset_publish_commit_to_history` / sysop: `wset_discard_sysop_keys`, `wset_abort_after_lsa`, `wset_find_sysop_fallback_dependency`, `wset_raise_history_start`)
- `writeset.hpp`, `writeset_types.hpp`, `writeset_history_map.{hpp,cpp}`
- `log_manager.c`: `log_initialize_internal`(재시작 floor), `log_sysop_start`, `log_sysop_commit_internal`, `log_sysop_abort`, `log_append_sysop_end_internal`, `log_sysop_fallback_reason`, `log_append_wset_label_and_sysop_end`, `log_append_repl_info_and_commit_log`, `log_append_wset_label_with_lock`, `log_commit_local`, `log_complete_for_2pc`, `log_dump_record`(switch 누락 확인), CDC switch
- `log_append.cpp`, `log_record.hpp`, `log_impl.h`, `log_recovery.c`(4개 switch), `log_tran_table.c`(init/clear/copy_to/define/undefine), `flashback.c` switch
- `locator_sr.c`: `xlocator_repl_force`(deadlock 처리), `locator_wset_error`, `locator_wset_trace_key_source`, `locator_wset_collect_fk_ref`, `locator_add_or_remove_index_internal`, `locator_update_index`(키 수집, midxkey domain, 함수 인덱스 경로), `locator_update_force`(repl LSA 부여 순서), `locator_check_foreign_key`, `locator_check_primary_key_delete`(cascade 잠금 경로), `locator_is_inserter_committing`, `locator_lock_and_get_object_internal`
- `btree.c`: `btree_is_deleter_committing`, `btree_trace_deleter_wait`, `btree_key_find_and_lock_unique_of_unique` / `_of_non_unique`의 `DELETE_RECORD_*` 분기
- `replication.c`: `repl_log_insert_statement`, `repl_add_update_lsa`, `repl_log_abort_after_lsa`
- `serial.c`: `serial_update_serial_object`
- `system_parameter.{c,h}`, `error_code.h`, `heartbeat.h`, `schema_system_catalog_install.cpp`, `cubrid.msg`
- `log_applier.c`: coordinator 전부(`la_coordinator_*`, `la_is_in_recovery_range`), worker 콜백(`la_apply_worker_*`), `la_find_required_lsa`, `la_get_ha_apply_max_committed_lsa`, `la_update_ha_apply_max_committed_lsa`, `la_get_last_ha_applied_info` 호출부, `la_get_wset_label`, `la_flush_repl_items`, `la_apply_repl_log`, `la_detach_sysop_fragment`, `la_coordinator_submit_task`, `la_coordinator_process_sysop_end`, `la_coordinator_set_commit_dependency`, `la_coordinator_process_commit`, `la_log_record_process`, `la_change_state`, `la_log_commit`, `la_commit_transaction`, `la_update_query_execute*`, `la_apply_log_file` 메인 루프 전체, 재시도·무시 오류 목록
- `src/transaction/applier/*` 전체 (gate, pending, inflight, task_queue, result_queue, worker, task/result/debug 헤더)
- `unit_tests/log_applier/*`, `unit_tests/writeset/*` (케이스 목록, main, CMake, stress/bench의 assert 유무)

CS 쪽(호출부·반환값만): `CMakeLists.txt`(MULTI_CONN 활성화), `cs/ sa/ cubrid/ CMakeLists.txt`, `work_space.{c,h}`(`ws_get_repl_obj_count`), `file_io.c`(pread/pwrite 경로 변경), `la_worker_start_session`의 `db_restart_sub`/`db_shutdown_sub` 호출, `__gv_loc_repl`(thread-local 확인).

부수 확인(문맥 파악용): `language_support.c`의 `lang_mht2str_*`, `memory_hash.c`의 `mht_2str_pseudo_key`, `object_primitive.c`의 `ignore_trailing_space` 사용, `log_comm.c`의 `log_does_allow_replication`, `heap_file.c`의 `heap_attrvalue_get_key`(함수 인덱스).

## 3. 발견 사항

### 3.1 에러

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| E1 | High | `log_manager.c:1513`, `applier/log_applier_gate.cpp:290`, `log_applier.c:733`, `log_applier.c:7420` | master 재시작 floor(R)는 slave commit-order ring에 없는 LSA라서, R을 라벨로 받은 첫 commit이 gate를 영원히 통과하지 못한다 | master: `wset_raise_history_start (&restart_lsa, "RESTART")`, R=`log_Gl.hdr.append_lsa`. slave: `return !LSA_ISNULL (&la_Gate_frontier) && LSA_LE (dep, &la_Gate_frontier);` frontier는 ring에 push된 commit LSA로만 전진. 주석 "That commit always passes the gate" | master 재시작 후 slave applier가 계속 돌고, R 이후 첫 commit C1이 라벨 있는 commit(=라벨 dep=R) → frontier ≤ 직전 commit < R → C1 parked → 이후 모든 commit도 dep ≥ R → ring 가득 → coordinator가 `la_coordinator_wait_for_commit_order_slot`에서 무한 대기. 오류 없이 복제 지연만 증가 | 불변식 위반은 확정, 실제 도달(재시작 직후 무라벨 commit이 먼저 오지 않는 경우)은 추정 | 신규 |
| E2 | High | `btree.c:27491-27508`, `locator_sr.c:4143`, `locator_sr.c:13303` | FK 자식 INSERT가 "commit 중인 부모 inserter"를 기다리지 않아 REF가 부모 WRITE를 놓친다 | FK 검사: `xbtree_find_unique (..., S_SELECT_WITH_LOCK, ...)` → MVCC상 commit된 행은 `DELETE_RECORD_CAN_DELETE` → `btree_key_lock_object` S lock 즉시 획득(부모 행에 X lock 없음). 대기 추가는 X_LOCK 경로(`lock_mode == X_LOCK && ...`)와 `DELETE_RECORD_DELETED` 경로만 | T_p가 부모 INSERT 후 `logtb_complete_mvcc`~publish 사이에 있을 때 T_c가 자식 INSERT·commit → T_c 라벨이 T_p를 포함하지 않음 → slave에서 T_c가 T_p보다 먼저/동시에 적용 → slave는 FK 검사(`dont_check_fk=false`) → INSERT 실패가 fail_counter로만 남고 자식 행 유실 | 경로는 확정, 재현은 추정 | 신규(근원 CBRD-26942는 기존) |
| E3 | Medium | `log_applier.c:4646-4664`, `log_applier.c:7817-7818`, `log_applier.c:7562-7566` | 라벨 읽기 실패가 "의존성 없음"으로 처리된다(fail-open) | `LSA_SET_NULL (dependency_seq);` 후 `LA_LOG_READ_*` 실패 시 그냥 return. 호출부는 결과와 무관하게 `la_wset_label_trid = lrec->trid;` → `has_label` true + dep NULL | 라벨 데이터가 걸친 다음 로그 페이지 fetch가 실패(I/O 오류, 아카이브 누락) → 충돌하는 선행 트랜잭션과 병렬 적용 → unique 위반·lost update가 fail_counter로만 남음 | 확정 | 신규 |
| E4 | Medium | `log_applier.c:1046`, `log_applier.c:1087`, `applier/log_applier_result_queue.cpp:224`, `applier/log_applier_worker.cpp`(`la_worker_startup_failed`) | coordinator가 결과 큐를 무기한 블로킹 pop한다. 깨워 줄 주체가 없다 | `la_coordinator_wait_until_retired`·`wait_for_inflight_slot` → `la_result_queue_pop` → `while (count == 0 && shutdown == false) pthread_cond_wait`. shutdown은 coordinator 자신이 `la_stop_apply_workers`에서만 올림. 워커 기동 실패는 `request_shutdown()` 플래그만 세움 | 재시작 직후 recovery range(워커>1)에서 task 1건 dispatch 후 `wait_until_retired` 진입 + 모든 워커가 `db_restart_sub` 실패(서버 기동 중, max_clients 초과) → coordinator 영구 블록, SIGTERM도 플래그만 세워 무반응 → cub_master 강제 종료까지 hang | 확정 | 신규 |
| E5 | High | `schema_system_catalog_install.cpp:1096-1097`, `log_applier.c:2897`, `log_applier.c:3349-3353` | `db_ha_apply_info`에 컬럼 2개 추가, 마이그레이션 없음 → 기존 DB에서 applylogdb가 기동 불가 | `SELECT max_committed_lsa_pageid, max_committed_lsa_offset FROM db_ha_apply_info ...` 실패 시 `return res;` → `la_get_last_ha_applied_info` 실패 → "Failed to initialize _db_ha_apply_info" 후 shutdown | 이 브랜치 바이너리로 기존(develop 생성) slave DB를 올림 → 컬럼 없음 → applylogdb 기동 즉시 종료 반복 | 확정 | 신규 |
| E6 | Medium | `log_record.hpp:140`, `log_manager.c:7469` | 새 로그 레코드 타입 53을 기존 리더가 처리하지 못한다 | develop의 `LOG_LARGER_LOGREC_TYPE`가 53. develop applier: `lrec->type >= LOG_LARGER_LOGREC_TYPE` → `ER_LOG_PAGE_CORRUPTED`. HEAD `log_dump_record`에 `LOG_DUMMY_WSET_LABEL` case 없음 → default가 "Unknown record type" 출력 후 `LSA_SET_NULL (log_lsa)` | (a) master만 먼저 올린 rolling upgrade → 구버전 slave applier가 첫 라벨에서 corrupted로 정지. (b) 신규 master 로그를 `cubrid diagdb` 로그 덤프 → 첫 라벨에서 덤프 중단 | (a)(b) 코드로 확정 | 신규 |
| E7 | Medium | `log_applier.c:798`, `log_applier.c:5975-5990`, `log_applier.c:7380-7411` | recovery range 상한이 copied log의 eof로 점프 → 백로그 중 재시작하면 백로그 전체가 직렬 적용 + 오류 은폐 구간이 됨 | `LSA_COPY (&bound, &la_Info.act_log.log_hdr->eof_lsa);` 저장 후, 재시작 시 `(last_committed, max_committed]` 전 구간을 한 건씩 `la_coordinator_wait_until_retired`. 같은 구간에서 `ER_BTREE_UNIQUE_FAILED`/`ER_OBJ_OBJECT_NOT_FOUND`를 fail_counter 없이 skip | slave가 수 GB 뒤처진 상태에서 applier 크래시 → 재기동 시 그 백로그가 전부 단일 직렬 경로로 처리(병렬 효과 소멸) + 그 사이 진짜 순서 위반으로 생긴 unique 위반도 집계되지 않음 | 동작은 확정, 성능 영향 정도는 추정 | 신규 |
| E8 | Medium | `log_applier.c:7090-7100` 부근(`try it again`) | `ER_LK_UNILATERALLY_ABORTED`(deadlock victim) 등을 받으면 해당 item만 10초 뒤 재시도 → 서버에서 이미 롤백된 앞선 item들이 빠진 채 commit | `LA_RETRY_ON_ERROR`에 `ER_LK_UNILATERALLY_ABORTED`, `ER_LK_DEADLOCK_CYCLE_DETECTED` 포함, `LA_SLEEP (10, 0); continue;` | 워커 간(클래스 락·lock escalation) 또는 사용자 질의와 deadlock → victim 트랜잭션의 이전 flush분 롤백 → 남은 item만 commit → 부분 트랜잭션 적용 | 추정 | 기존(병렬화로 빈도 증가) |
| E9 | Medium | `replication.c:698-703` | sysop abort 때 LSA가 아직 없는 UPDATE repl 레코드를 모두 버리도록 바뀜. 모든 HA(직렬 applier 포함)에 영향 | `if (LSA_ISNULL (&repl_rec->lsa) && (rcvindex == RVREPL_DATA_UPDATE...)) must_flush = LOG_REPL_DONT_NEED_FLUSH;` 호출부는 `log_sysop_abort` 하나뿐이고 상위 statement 실패 여부를 보지 않음 | `locator_update_index`에서 repl 레코드 생성 후 `heap_update_logical`로 LSA가 붙기 전 사이에 내부 sysop이 정상 흐름으로 abort되면, statement는 성공했는데 그 UPDATE가 slave로 안 감 | 추정(정상 흐름 중 중첩 sysop abort 존재 여부 미확인) | 신규 |
| E10 | Low | `log_applier.c:445`, `log_applier.c:1519-1523` | 워커가 쓰고 coordinator가 읽는 종료 플래그가 일반 `bool` | `static bool la_applier_need_shutdown`, `la_request_shutdown` → `= true` (워커 스레드) | 최적화로 루프 조건이 레지스터에 고정되면 종료 요청 미인지. C/C++ 메모리 모델상 data race | 경쟁은 확정, 실제 오동작은 추정 | 신규 |
| E11 | Medium | `log_applier.c:10329-10354` | gate 정체 감시가 role change 중에만 있다 | `if (la_Info.is_role_changed == true && !la_coordinator_drain_complete ())` 일 때만 `LA_DRAIN_TIMEOUT_MSEC` 백스톱 | E1 같은 정체가 평시에 나면 오류 로그·재시작 없이 지연만 쌓임. failover 때는 DONE 보류 → 30초 타임아웃 → 재시작 → 같은 정체 반복 | 확정 | 신규 |
| E12 | Low | `writeset.cpp:287-299` | 문자열 해시가 trailing space를 정규화하지 않는다 | `pseudo = lc->mht2str (lc, s, size);` `mht_2str_pseudo_key`는 바이트 전부 해싱. 비교 함수는 `PRM_ID_IGNORE_TRAILING_SPACE`가 켜지면 trailing space 무시 | `ignore_trailing_space=yes` DB에서 T1이 UNIQUE 'a' DELETE, T2가 'a ' INSERT → 서버는 같은 키로 보고 T2를 T1 뒤로 대기시키지만 해시가 달라 라벨 누락 → slave에서 T2 먼저 적용 시 unique 위반 | 추정(숨김 파라미터, 기본값 false) | 신규 |

#### E1 상세 — 재시작 floor가 gate 교착을 만든다
- master는 재시작할 때 `history_start`를 R(복구 후 append_lsa)로 올린다(`log_manager.c:1509-1514`). R은 "다음 레코드가 써질 위치"일 뿐 commit LSA가 아니다. 재시작 직후 `prev_commit_lsa`가 NULL이므로 `wset_find_dependency_in_range`는 키 충돌이 없어도 `dependency = history_start = R`을 돌려준다(`writeset.cpp:1082-1095`). 이후 commit들도 `max(min(wset_parent, prev_commit), history_start)`라 계속 R 이상이다.
- slave gate는 `dep <= frontier`일 때만 통과시키고, frontier는 ring에 push된 commit(또는 labeled SYSOP_END) LSA로만 전진한다(`log_applier_gate.cpp:219-275`). R은 ring에 들어가는 경로가 없다(`la_gate_order_push` 호출부는 `la_coordinator_submit_task`, `la_coordinator_complete_without_task` 두 곳뿐이고 둘 다 commit/labeled sysop용).
- 따라서 R 직전 commit을 Cp, R 이후 첫 commit을 C1이라 하면 `Cp < R < C1`, C1.dep=R, frontier ≤ Cp → C1은 parked. C1이 끝나야 frontier가 R을 넘으므로 자기 자신을 기다리는 교착이다. `la_coordinator_wait_for_commit_order_slot`의 "ring의 가장 오래된 commit은 항상 gate를 통과한다"는 전제(733행 주석)가 "dep가 직전 ring 항목과 자기 commit 사이에 있는" 경우에 깨진다.
- 자연 해소 조건: R과 C1 사이에 라벨 없는 commit(HA 상태가 ACTIVE가 되기 전의 commit, 그 노드 applier의 apply_info commit 등)이 하나라도 있으면 그 commit이 dep=NULL로 통과해 frontier가 R을 넘는다. slave applier가 재시작되면 frontier 초기값이 `required_lsa`(C1 시작 이후)가 되어 풀릴 수도 있다. 그래서 도달 여부는 토폴로지·타이밍 의존이다(추정).
- 재현 제안: (1) 단위: gate에 frontier=10, ring에 push 없이 dep=15인 task를 넣고 ring에 20을 push → `la_gate_is_satisfied(15)`가 20 완료 전엔 false, 20은 dep 15라 영원히 대기함을 확인. (2) 통합: slave applier를 유지한 채 master `cub_server`만 재시작(heartbeat가 failover 하지 않는 구성) → 재시작 직후 첫 쓰기 commit → slave `[WSET] reader schedule ... status=2`만 찍히고 retire 없음 확인.
- 수정 방향: slave에서 push 직전 `dep > ring tail(없으면 frontier)`이면 dep를 ring tail로 낮춘다. 그 사이에 commit이 없으므로 의미가 같다. 또는 master가 재시작 시 라벨 기준점이 될 레코드를 남긴다.

#### E2 상세 — FK 자식 INSERT와 commit 중인 부모 INSERT
- 이 브랜치는 CBRD-26942(INSERT 행 X lock 제거)로 생긴 "complete_mvcc ~ publish 틈" 문제를 두 군데만 막았다: X lock으로 행을 수정하는 경로(`locator_lock_and_get_object_internal`, `locator_sr.c:13303`)와 unique 검사에서 삭제된 키를 만난 경로(`btree.c:27552`, `27909`).
- FK 검사는 `xbtree_find_unique(..., S_SELECT_WITH_LOCK, ...)`(`locator_sr.c:4143`)로 부모 키를 찾는다. 부모 inserter가 MVCC상 완료되면 `DELETE_RECORD_CAN_DELETE`로 분류되고 S lock은 바로 잡힌다(부모 행에 X lock이 없다). 여기엔 inserter-commit 대기가 없다.
- 결과: 자식 트랜잭션의 REF probe 시점에 부모 WRITE가 아직 history에 없으면 자식 라벨이 부모를 포함하지 않는다. slave에서 두 트랜잭션이 병렬로 돌거나 자식이 먼저 돌면, slave의 `locator_insert_force`가 FK를 검사하므로(`dont_check_fk=false`) 자식 INSERT가 실패하고 `la_flush_repl_items`는 이를 fail_counter로만 센 뒤 트랜잭션을 commit한다. 자식 행이 slave에서 조용히 사라진다.
- 재현 제안: 부모 INSERT 세션의 commit postpone을 인위적으로 늘리는 fault injection(또는 디버거 정지) 상태에서 다른 세션이 자식 INSERT 후 즉시 commit, slave 워커 ≥2로 적용 → slave 자식 행 수 비교.
- 수정 방향: `DELETE_RECORD_CAN_DELETE`에서도 inserter가 "MVCC 완료·self-lock 보유"이면 `btree_key_wait_for_insert_mvccid`로 대기(deleter 대기와 같은 패턴), 또는 FK REF 수집 시점에 동일 검사.

#### E3 상세 — 라벨 fail-open
- `la_get_wset_label`은 읽기 실패 시 dep NULL을 남기고 오류를 돌려주지 않는다. 호출부는 무조건 holder에 trid를 기록하므로 `la_coordinator_set_commit_dependency`가 `has_label=true`로 판단하고, "라벨 없는 commit은 직전 commit 전부를 기다린다"는 안전 경로(7569-7573)를 타지 않는다.
- 안전한 쪽은 읽기 실패 = 라벨 없음(직렬 대기) 또는 applier 정지다. 함수 반환형을 int로 바꾸고 실패 시 holder를 세우지 않는 것을 제안.

#### E4 상세 — coordinator 무기한 블록
- 워커 기동 실패는 `la_worker_startup_failed`에서 live 카운트를 줄이고 0이면 `request_shutdown()`만 호출한다. 이 함수는 플래그만 세운다. coordinator가 이미 `la_result_queue_pop`에서 기다리는 중이면 결과를 낼 워커가 없고 큐 shutdown도 아무도 올리지 않으므로 깨어나지 못한다.
- 같은 이유로 워커 하나가 서버 락 대기 등에서 오래 멈추면 `wait_for_inflight_slot`/`wait_until_retired` 동안 SIGTERM(`la_shutdown_by_signal`)이 반영되지 않는다.
- 제안: 두 대기 루프를 `la_result_queue_wait_for_result(timeout)` + `la_applier_need_shutdown` 확인으로 바꾸고, `request_shutdown`이 `la_result_queue_signal_shutdown`도 호출하게 한다. 테스트: 워커 수 2, 세션 시작을 강제로 실패시키는 fault hook으로 recovery range 진입 → 프로세스가 N초 내 종료되는지.

#### E5 상세 — 카탈로그 변경 무마이그레이션
- `db_ha_apply_info`에 `max_committed_lsa_pageid`, `max_committed_lsa_offset`이 추가됐지만 기존 DB를 위한 ALTER/마이그레이션 코드가 diff에 없다. `la_get_ha_apply_max_committed_lsa`의 SELECT 실패가 그대로 기동 실패로 이어진다.
- 업그레이드 시나리오(기존 DB에 신규 바이너리), `unloaddb/loaddb`, 카탈로그 버전 정합 테스트가 필요하다. 코드 주석(2963-2967)에도 "final_lsa로 대체해 카탈로그 변경 제거" TODO가 있다. 릴리스 전 결정이 필요한 항목이다.

#### E6 상세 — 로그 포맷 호환
- 타입 53 추가로 develop(및 이전 버전) 리더가 새 로그를 corrupted로 판단한다. HA rolling upgrade 순서(slave 먼저)를 문서·도구로 강제하거나, master 쪽 라벨 기록을 slave 버전 협상 이후에만 켜는 장치가 필요하다.
- 같은 레코드가 `log_dump_record`(`log_manager.c:7357-7471`)에 없어 덤프가 첫 라벨에서 멈춘다. `log_recovery.c` 4곳, `log_rollback`, `log_do_postpone`, `log_append.cpp` 2곳은 추가됐으나 덤프만 빠졌다. flashback·CDC는 default가 break라 영향 없음을 확인했다.

#### E7 상세 — recovery range가 너무 넓다
- 상한을 eof까지 점프시키는 건 저장 횟수를 줄이려는 의도(791-793행 주석)지만, 재시작 후 그 구간은 (a) 한 건씩 직렬 적용, (b) 재적용 오류 whitelist가 무조건 skip되는 구간이 된다. 백로그 상황에서 재시작하면 병렬 applier의 존재 이유(캐치업 속도)가 그 구간 동안 사라지고, 같은 구간에서 실제 순서 버그로 생긴 unique 위반도 `recovery_skipped_counter`로만 남는다.
- 제안: bound를 "dispatch된 최대 commit + 고정 여유"로 제한하거나, 저장 빈도와 구간 폭을 파라미터로 노출. 테스트: 백로그 N건에서 applier kill → 재기동 처리량과 `recovery_skipped_counter` 측정.

#### E8 상세 — 부분 트랜잭션 재시도
- 기존 develop 코드와 같은 재시도 루프다. 다만 develop은 단일 applier라 deadlock 상대가 사용자 질의뿐이었고, 이 브랜치는 서로 다른 워커가 동시에 클래스 락을 잡거나 lock escalation으로 충돌할 수 있다. 서버가 트랜잭션 전체를 롤백한 뒤 item 하나만 재시도하면 이미 flush된 앞 batch가 사라진 채 commit된다.
- 제안: unilateral abort 계열은 item 재시도 대신 트랜잭션 전체를 실패로 돌려 재시작(recovery range 재적용)하게 한다. 테스트: 두 워커가 같은 클래스에 escalation을 유발하는 대량 트랜잭션.

#### E9 상세 — 중첩 sysop abort와 UPDATE repl 레코드
- 새 조건은 "LSA가 아직 없는 UPDATE 레코드 = 실패한 statement 소속"이라고 가정한다. `locator_update_force`는 `locator_update_index`(레코드 생성, 이때 B-tree 갱신과 FK 검사 수행) → `heap_update_logical` → `repl_add_update_lsa` 순서다(`locator_sr.c:5926-6016`). 이 사이에서 내부 sysop이 정상 흐름으로 abort되면(예: 재시도형 내부 연산) statement는 성공해도 그 UPDATE가 버려진다. 정상 흐름 중 abort가 있는지는 확인하지 못했다(추정).
- 이 함수는 develop 직렬 applier에도 영향을 주는 공통 경로이고 단위 테스트가 없다. 최소한 "statement 성공 + 중첩 sysop abort" 조합의 회귀 테스트가 필요하다.

### 3.2 모듈화

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| M1 | Medium | `log_applier.c:700-1290`, `7255-7660` | 스케줄링 규칙(gate 통과·park·recovery range 직렬화·sysop fragment·라벨 holder·commit dependency 보정)이 11k행 파일의 static 함수로만 존재해 단위 테스트가 불가능 | 단위 테스트는 gate/pending/inflight/queue 자료구조만 다룬다. `la_coordinator_submit_task`, `la_coordinator_set_commit_dependency`, `la_coordinator_process_sysop_end`, `la_is_in_recovery_range`는 테스트 0건 | E1·E3 같은 규칙 결함이 HA 실측 전까지 드러나지 않음. 회귀 시 원인 격리 비용 큼 | 확정 | 신규 |
| M2 | Medium | `log_applier.c:1426-1466` | 테스트 전용 crash-injection 훅이 release 빌드 commit 경로에 있다 | `getenv ("CUBRID_HA_TEST_BLOCK_CLASS")`를 commit마다 호출, 일치 시 `usleep` 기본 60초 | 운영 환경에 같은 이름 환경변수가 남아 있으면 특정 클래스 commit마다 60초 정지. commit마다 getenv 비용 | 확정 | 신규 |
| M3 | Low | `applier/*.cpp` 전역 static 상태 | gate·pending·inflight·두 큐가 모두 프로세스 전역 싱글턴이고 재초기화 규칙이 모듈마다 다르다 | `la_gate_init`은 frontier까지 초기화, `la_task_queue_init`은 고정 배열, `la_pending_clear`는 별도 호출 필요 | 같은 프로세스 내 applier 재시작 경로에서 초기화 누락 시 이전 run 상태가 섞임(현재는 주석으로 관리) | 확정(구조), 결함은 없음 | 신규 |
| M4 | Low | `log_manager.c:3998-4028`, `4329-4349`, `4365-4430` | 커밋 경로에서 repl 레코드 카운트 루프가 세 번 반복되고, trace 전용 함수가 repl 데이터를 파싱 | `repl_item_count`, `flushed_item_count`, `pending_item_count` 계산 루프 중복, `log_sysop_fallback_reason`이 `or_unpack_string_nocopy`로 클래스명 파싱 | 기능 결함은 아님. trace 레벨과 무관하게 앞의 두 루프는 항상 실행 | 확정 | 신규 |

#### M1 상세 — QA 관점 테스트 공백
현재 단위 테스트가 덮지 않는 것(우선순위 순):
1. gate: ring 항목 사이에 있는 dep(E1). frontier NULL에서 시작하는 첫 실행.
2. coordinator 규칙: 라벨 없는 commit의 dep 보정, sysop fragment dep가 outer commit dep로 올라가는지, recovery range 진입/이탈, 워커 1개 모드에서 park가 없는지, `la_coordinator_complete_without_task`.
3. writeset: `wset_abort_after_lsa`(savepoint 부분 롤백), statement replication fallback 후 history clear, 재시작 floor, `wset_publish_with_capacity`의 OOM 경로.
4. master 통합: index 종류별(PK/UNIQUE/REVERSE_UNIQUE/FK/함수·필터 인덱스/파티션) 키 수집, serial 수집과 discard, 2PC 커밋 경로.
5. 동시성: d1d02b9e4/79268ae56의 대기, E2 시나리오. 이 둘은 SQL 수준 시나리오 테스트(두 세션 + 지연 주입)가 필요하다.
제안: coordinator 결정 로직(라벨 → dep 보정 → 통과/보류 판정)을 I/O 없는 순수 함수 모듈로 빼서 `unit_tests/log_applier`에 넣는다.

### 3.3 아키텍처

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| A1 | High | `log_applier.c:1546-1569`, `5970-5990`, `6964`, `1392-1424` | 적용 모델이 exactly-once에서 at-least-once + 오류 whitelist로 바뀌었다 | develop: `la_flush_repl_items` → `la_update_ha_last_applied_info` → `la_commit_transaction`을 한 트랜잭션으로 수행(데이터와 apply_info 원자적). HEAD: 워커가 데이터만 commit, coordinator가 별도 연결로 committed_lsa 저장 → 재시작 시 구간 재적용, 오류는 INSERT unique / UPDATE·DELETE not-found만 skip. statement 재적용은 TODO | 재적용 구간의 PK 변경 UPDATE가 같은 PK를 재사용한 이후 행을 건드리는 경우, statement(DDL) 재실행, 비결정적 statement 등에서 slave가 master와 달라질 수 있음 | 모델 변경은 확정, 발산 시나리오는 추정 | 신규 |
| A2 | Medium | `writeset.cpp:520`, `1289-1322`, `locator_sr.c:13303`, `btree.c:27209` | master 쪽 writeset·대기가 모든 HA master에서 항상 켜지며 끄는 스위치가 없다 | `wset_add_write_key`의 게이트는 `wset_overflow`·`suppress_replication`뿐. 트랜잭션당 키 상한=`ha_writeset_history_size`(기본 100만, 엔트리 24B). 용량 초과 시 `seq_lock`+`wrlock` 아래 `map.clear()`. X lock 행 조회마다 inserter MVCCID 조건부 락 요청 | 워커 1개 slave를 쓰는 기존 고객도 master 비용 부담. 대량 트랜잭션 다수 동시 실행 시 트랜잭션당 최대 수십 MB. 100만 엔트리 clear 동안 모든 commit의 probe가 대기해 지연 스파이크 | 구조는 확정, 비용 크기는 추정(측정 필요) | 신규 |
| A3 | Medium | `CMakeLists.txt:607`, `file_io.c:3882`, `4084`, `4123-4128` | `MULTI_CONN_TO_A_SERVER`를 전 빌드에 전역 활성화, 비서버 바이너리 파일 I/O 경로 변경 | `add_definitions(-DMULTI_CONN_TO_A_SERVER)`, `#if !defined (SERVER_MODE) && defined (WINDOWS)`로 Linux CS/SA가 pread/pwrite 사용 | applier만이 아니라 csql·CAS·유틸리티 전부의 클라이언트 동작이 바뀜. 회귀 범위가 HA 테스트로 덮이지 않음 | 변경 범위는 확정, 결함 여부는 범위 밖(미분석) | 신규 |
| A4 | Low | `writeset.cpp:520`, `locator_sr.c:8747-8787` | `ha_writeset_history_size`가 트랜잭션당 한도와 전역 맵 용량을 겸하고, UPDATE는 키 변경 여부와 무관하게 old/new를 모두 넣는다(중복 제거 없음) | `wset_push_hash`의 한도 비교, `/* Collect both old and new keys ... */` | PK+UNIQUE 2개 테이블의 일반 UPDATE 약 17만 행에서 키 100만 초과 → 해당 트랜잭션 commit-order 전환 + history 전체 clear → 뒤 트랜잭션 전부 그 뒤로 직렬화 | 확정 | 신규 |

#### A1 상세
- 이 브랜치의 정확성은 "재적용 구간의 오류는 이미 적용돼서 난 것"이라는 가정에 기댄다. row 이미지 기반 INSERT/UPDATE/DELETE를 commit 순서대로 직렬 재적용하면 대부분 수렴하지만, 이 가정이 깨지는 조합(PK 변경 UPDATE, statement 복제, `ha_applylogdb_ignore_error_list` 설정과 결합)에 대한 체계적 검증이 없다. QA로서는 "재적용 구간 수렴성"을 별도 테스트 축으로 요구한다: 각 DML 조합 × 커밋 직후 kill × 재기동 후 master/slave 전체 행 비교.
- 대안 검토: 워커 트랜잭션 안에서 자기 commit_lsa를 per-worker apply 테이블에 함께 기록하면(데이터와 원자적) 재적용 구간 없이 정확한 skip이 가능하다. 브랜치에도 "B2 완료마커" 설계 흔적이 있는 만큼 비교 결정이 필요하다.

#### A2 상세
- 운영 관점에서 master 쪽 수집은 slave 워커 수와 무관하게 비용을 만든다. `ha_apply_worker_count`는 client 파라미터라 master가 알지 못한다. 최소한 master 측 on/off 파라미터(꺼지면 라벨=NULL 또는 직렬 의미 라벨)와, 맵 clear를 exclusive lock 밖에서 하는(swap 후 해제) 구조를 권한다.
- 측정 항목 제안: HA master의 TPC-C류 p99 commit latency(수집 on/off), 대량 UPDATE 시 RSS, 맵 clear 빈도와 clear 순간 지연.

### 3.4 리팩토링

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| R1 | Low | `log_applier.c:868-875`, `7430` 이하, `7811-7825`, `applier/log_applier_gate.cpp:272` | coordinator 로그·trace에 "reader" 명칭과 접두어(`[WSET] reader`, `ws_gate`, `ws_repl`, `ws_worker`, `ws_marker`, `ws_lsaguard`)가 섞임. `LA_SCHED_STATUS` 주석도 "reader schedule" | 추가된 라인 중 `reader` 14건 | 로그 기반 장애 분석·자동 집계 스크립트가 접두어마다 달라짐 | 확정 | 신규 |
| R2 | Low | `log_applier.c:9648-10431` | `la_apply_log_file` 약 780행, 페이지 fetch·아카이브 삭제·상태 전이·drain 백스톱이 한 함수 | — | 수정 시 회귀 범위 판단이 어려움 | 확정 | 기존 확대 |
| R3 | Low | `unit_tests/writeset/test_writeset_stress.cpp:216`, `261`, `test_writeset_bench.cpp` | stress·benchmark 케이스가 숨김 태그(`[.]`)가 아니어서 기본 실행에 포함, 대부분 assert 없는 측정 출력 | `[stress]`, `[benchmark]`, 스레드 최대 512, 커밋당 키 50만 | CI에서 실행 시간 급증, 측정값이 판정에 쓰이지 않아 실패를 못 잡음 | 확정 | 신규 |

## 4. 미검증 의심 (근거 부족으로 확정 못 한 것)

1. 2PC: 참가 트랜잭션이 MVCC를 완료한 뒤 coordinator 결정을 오래 기다리는 상태가 있다면, d1d02b9e4/79268ae56의 self-lock 대기가 그 시간 동안 걸린다. 2PC prepare 단계에서 `logtb_complete_mvcc` 호출 시점을 확인하지 못했다.
2. `serial.c:1215-1251`: serial 키 수집은 `lock_mode != X_LOCK` 분기 안에서만 한다. 트랜잭션이 이미 db_serial 행 X lock을 가진 경우(같은 트랜잭션에서 db_serial을 직접 UPDATE 후 NEXT VALUE) 그 갱신은 키 없이 outer commit에 실리고, 이후 다른 트랜잭션의 db_serial DML 라벨이 이를 놓칠 수 있다. 실제 발생 경로가 있는지 미확인.
3. 파티션 테이블: 키 해시에 파티션 클래스 OID와 파티션별 btid가 들어간다. 행이 파티션 간 이동하거나 전역 unique가 파티션 키를 포함하지 않는 구성이 가능하다면 같은 키가 서로 다른 해시가 된다. CUBRID의 파티션 unique 제약 규칙을 확인하지 못했다.
4. `log_manager.c:5620-5626`: `retain_lock` commit에서 MVCCID self-lock을 HA 여부와 무관하게 해제하도록 바뀌었다. 비HA 환경에서 동작 변화가 의도된 것인지 확인 필요.
5. DDL(statement) 적용은 `la_sql_compile_mutex`를 실행 내내 잡는다(`log_applier.c:6876` → `6634`). 긴 DDL 동안 coordinator의 apply_info 저장이 막혀 결과 수거·role change 처리가 지연된다. develop도 단일 스레드라 같은 지연이 있었는지 비교 필요.
6. `la_inflight_find_by_seq`는 결과마다 최대 `워커수×1024` 선형 탐색이다. 32 워커에서 결과 처리 비용이 체감될 수준인지 측정 필요.
7. E9의 전제(중첩 sysop이 정상 흐름에서 abort되는 경로) 존재 여부.

## 5. 총평

설계의 큰 줄기(master가 commit 직전에 키 이력으로 라벨을 붙이고, slave가 gap-free frontier로 라벨을 통과시키는 구조)는 일관되고, history 락 순서(`seq_lock` → `history_lock`)와 sysop fragment 라벨링, failover DONE 보류는 코드로 따라가 봤을 때 정합했다. gate·pending·queue·inflight를 별도 모듈로 떼고 단위 테스트를 붙인 것도 이전 PoC 대비 분명한 진전이다.

다만 QA 관점에서 출시 판단을 막는 것은 세 가지다.
1. **liveness 불변식의 틈(E1, E11, E4)**: "ring의 가장 오래된 commit은 항상 통과한다"는 전제가 재시작 floor에서 깨지고, 평시에는 정체 감시가 없으며, coordinator 대기는 종료 신호로도 풀리지 않는다. 복제가 오류 없이 멈추는 유형이라 운영에서 가장 늦게 발견된다.
2. **순서 보장의 남은 틈(E2, E3)**: CBRD-26942 이후 틈을 X lock 수정과 unique-삭제 두 경로만 막았고 FK 참조 경로가 남았다. 라벨 읽기 실패는 fail-open이다. 둘 다 결과가 fail_counter 증가와 행 유실로만 드러난다.
3. **배포 호환성(E5, E6, A3)**: 카탈로그 컬럼 추가에 마이그레이션이 없고, 새 로그 레코드는 구버전 리더와 로그 덤프를 멈추며, MULTI_CONN 전역 활성화로 회귀 범위가 HA 밖까지 넓다.

구조적으로는 at-least-once 전환(A1)과 넓은 recovery range(E7)가 정확성을 "재적용 오류 whitelist"에 기대게 만든다. 이 축은 단위 테스트로는 못 잡고, DML 조합 × kill 시점 × 재기동 후 전체 행 비교라는 별도 회귀 매트릭스로 검증해야 한다. 그 전에 coordinator 결정 로직을 테스트 가능한 순수 모듈로 분리(M1)하면 E1·E3 같은 규칙 결함을 HA 실측 전에 잡을 수 있다.

등급별 건수: High 4 (E1, E2, E5, A1) / Medium 11 (E3, E4, E6, E7, E8, E9, E11, M1, M2, A2, A3) / Low 8 (E10, E12, M3, M4, A4, R1, R2, R3). 합계 23건, Critical 0건.
