# CBRD-27508 브랜치 리뷰: QA 5년차

## 1. 리뷰어 관점

- 역할(QA): 각 결함을 "어떤 입력과 상태에서 재현되는가", "지금 단위테스트가 그 경로를 덮는가"로 봤다. 특히 실패 경로(워커 기동 실패, 결과 오류, 종료 신호), 경계(링 위에 없는 라벨, 재시작 경계, 복구 구간), 회귀(develop 동작과 달라진 곳)를 우선했다.
- 연차(5년): 모듈 사이의 상호작용(master 라벨 생성 규칙과 slave gate 판정 규칙의 정합, coordinator와 worker의 대기/종료 협조, applier와 heartbeat의 DONE 협조)과 동시성 경계를 중점으로 봤다.

## 2. 검토 범위와 실제로 읽은 경로

범위: `git diff a9a0dc78d 0e411f10f` (HEAD = 0e411f10f). 행 번호는 모두 HEAD 기준.

- slave 병렬화 모듈 전체: `src/transaction/applier/` 의 gate, inflight, pending, task_queue, result_queue, worker, task/result/debug 헤더
- `src/transaction/log_applier.c`
  - coordinator: `la_coordinator_drain_ready`, `_wait_for_commit_order_slot`, `_cover_commit`, `_dispatch_task`, `_drain_complete`, `_collect_and_retire`, `_collect_results`, `_record_result`, `_complete_without_task`, `_wait_until_retired`, `_wait_for_inflight_slot`, `_release_apply_slot`, `_advance_committed_lsa`, `_retire_results`, `_commit_apply_info`, `_submit_task`, `_process_sysop_end`, `_set_commit_dependency`, `_process_commit`
  - worker 쪽: `la_apply_worker_run_task/flush_task/commit_task/test_block_before_commit`, `la_apply_repl_log`, `la_get_next_repl_item_from_log`, `la_flush_repl_items`, `la_commit_transaction`
  - 공통: `la_log_record_process`, `la_get_wset_label`, `la_detach_sysop_fragment`, `la_is_in_recovery_range`, `la_find_required_lsa`, `la_get_ha_apply_max_committed_lsa`, `la_update_ha_apply_max_committed_lsa`, `la_get_last_ha_applied_info`, `la_change_state`, `la_log_commit`, `la_lock_dbname`, `la_unlock_dbname`, `la_init`, `la_shutdown`, `la_apply_log_file`(main loop 전체), `la_add_apply_list`, `la_init_repl_lists`
- master: `writeset.cpp`(전체), `writeset_history_map.cpp`, `writeset*.hpp`, `log_manager.c` 변경분(`log_initialize_internal` 재시작 경계, `log_sysop_commit_internal`, `log_append_wset_label*`, `log_commit_local`, `log_complete_for_2pc`), `locator_sr.c` 변경분(키 수집, inserter 대기), `btree.c` 변경분(deleter 대기), `serial.c`, `replication.c`, `log_tran_table.c`, `log_recovery.c`, `log_append.cpp`, `log_record.hpp`, `log_impl.h`
- 파라미터/에러/카탈로그: `system_parameter.{c,h}`, `error_code.h`, `cubrid.msg`, `heartbeat.h`, `schema_system_catalog_install.cpp`
- CS glue(호출부만): `CMakeLists.txt`, `cs/sa/cubrid CMakeLists`, `work_space.{c,h}`, `file_io.c` 변경분, `la_worker_start_session/end_session` 의 `db_restart_sub/db_shutdown_sub` 호출
- 대조: `server_support.c` `css_check_ha_log_applier_done`, `file_io.c` `fileio_unlock_la_dbname`, `log_2pc.c` `log_2pc_recovery_analysis_record`, develop(`a9a0dc78d`)의 `la_apply_repl_log`, `la_shutdown`, `log_record.hpp`
- 테스트: `unit_tests/log_applier/*`(전체), `unit_tests/writeset/*`(케이스 목록, common, main, CMake)

## 3. 발견 사항

### 3.1 에러

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| E1 | High | log_manager.c:1504-1514, writeset.cpp:1032,1091-1095, log_applier.c:7371-7376,7553-7578,7420-7427, log_applier_gate.cpp:318-329 | 라벨이 slave 링 위에 없는 LSA를 가리키면 그 트랜잭션이 영원히 park된다. master 재시작 경계(history_start = 재시작 직후 append_lsa)가 바로 그런 LSA다 | master: `wset_raise_history_start (&restart_lsa, "RESTART")`, 모든 라벨은 `history_start` 이상으로 바닥이 깔림. slave: 자기 커밋을 링에 먼저 push한 뒤 `dep <= frontier` 일 때만 통과. 라벨을 링 꼬리로 내리는 처리 없음 | master 재시작 후 첫 복제 커밋 T1 앞에 다른 LOG_COMMIT이 없으면, T1.dep = restart_lsa > 링의 모든 이전 커밋, 그리고 T1 자신이 restart_lsa 다음 첫 링 항목. frontier는 T1 앞에서 멈추고 T1은 park 상태로 남는다. 이후 모든 라벨 커밋도 같은 바닥을 받아 park, 링이 가득 차면 coordinator는 로그 읽기를 멈춘다. 복제 정지, DONE 보류로 failover도 멈춘다(E4) | 메커니즘 확정, 트리거 빈도 추정 | 신규 |
| E2 | High | log_applier.c:1039-1068, 1080-1109, 7384-7411, applier/log_applier_result_queue.cpp:171-197, applier/log_applier_worker.cpp:378-392 | coordinator의 블로킹 대기가 종료 요청을 보지 않는다 | `la_coordinator_wait_until_retired`/`_wait_for_inflight_slot` 은 `la_result_queue_pop` 으로 무기한 대기. pop은 result queue shutdown일 때만 빠지는데 그 shutdown은 coordinator 자신이 `la_stop_apply_workers` 에서만 건다. 워커 전원 기동 실패 시 워커는 `request_shutdown` 으로 플래그만 세움 | 재시작 직후 복구 구간(직렬 경로)에서 task 1건 dispatch 후 `wait_until_retired` 진입. 그 사이 서버 미준비 등으로 모든 워커의 `db_restart_sub` 실패. 결과를 낼 워커가 없어 pop이 영원히 대기, SIGTERM 핸들러가 세우는 `la_applier_need_shutdown` 도 보지 않아 `hb stop` 으로도 안 끝남. 프로세스는 살아 있어 heartbeat가 재기동하지도 않는다 | 코드 경로 확정, 트리거 추정 | 신규 |
| E3 | High | log_applier.c:9817-9824, 10317-10322, 9954-9957, 9973-9976, 7792 (대조: a9a0dc78d log_applier.c:5781) | dbname 잠금을 시작 시 한 번만 잡고, 해제 뒤 다시 잡지 않는다 | HEAD: `la_lock_dbname` 호출은 9819 한 곳뿐. `la_unlock_dbname` 이 `fileio_unlock_la_dbname` 으로 `db_lockf_vdes = NULL_VOLDES`. develop은 `la_apply_repl_log` 에서 항목 있는 트랜잭션마다 `la_lock_dbname` 재획득 | 역할 변경(LOG_DUMMY_HA_SERVER_STATE), DEAD 대기 시간 초과, DONE 후 비활성 상태에서 잠금이 풀린 뒤 피어가 다시 ACTIVE가 되면 이 applier는 잠금 없이 적용을 계속한다. 같은 slave DB를 대상으로 하는 다른 applylogdb(3노드 이상, replica 구성)가 잠금을 잡고 동시에 적용 가능. 또 7792 조건 때문에 이후 역할 변경은 감지조차 안 됨. 10317에서는 DONE 보류 중(워커가 아직 적용 중)에도 잠금을 푼다 | 확정 | 신규(develop 대비 회귀) |
| E4 | Medium | log_applier.c:10317-10329, 8435-8436, 7958-7973, server_support.c:1504-1520 | DONE 보류의 백스톱 타임아웃이 사실상 동작하지 않는다 | 10317에서 `is_role_changed` 이면 `la_unlock_dbname` 호출, 이 함수가 `is_role_changed = false` 로 되돌림. 바로 아래 10329의 백스톱 조건 `la_Info.is_role_changed == true && ...` 은 거짓. master가 갑자기 죽는 DEAD 경로는 애초에 `is_role_changed` 를 세우지 않음 | master 프로세스 사망(헤더 DEAD) 시점에 E1처럼 park된 task가 있으면 `la_coordinator_drain_complete` 가 계속 거짓이라 DONE이 무기한 보류된다. 서버는 `css_check_ha_log_applier_done` 이 참이 될 때까지 TO_BE_ACTIVE에 머물러 failover가 끝나지 않는다. 30초 백스톱은 unlock 실패라는 드문 경우에만 작동 | 확정 | 신규 |
| E5 | Medium | log_applier.c:4638-4666, 7815-7818, 7553-7560 | 라벨 레코드 읽기 실패가 삼켜져 "라벨 있음, 의존 없음"이 된다 | `la_get_wset_label` 은 void, 내부 `error` 를 버리고 `dependency_seq` 는 NULL로 남김. 호출부는 결과와 무관하게 `la_wset_label_trid = lrec->trid` | 라벨 본문이 다음 페이지로 넘어가고 그 페이지 fetch가 실패(I/O, 아카이브 범위 경합)하면 해당 커밋은 `has_label = true`, dep = NULL로 즉시 dispatch. 충돌하는 선행 트랜잭션과 병렬 적용되어 UPDATE/DELETE 대상 없음, UNIQUE 위반이 발생하고 이는 fail_counter만 올리고 커밋되는 무성 불일치로 이어진다 | 코드 확정, 트리거 추정 | 신규 |
| E6 | Medium | log_applier.c:795-799, 1024-1028, 7378-7411, 5976-5988 | 복구 구간 상한이 "복사된 로그 끝(eof)"이라 백로그가 크면 재시작 후 백로그 전체가 직렬 적용되고 재적용 오류가 넓게 숨겨진다 | `la_coordinator_cover_commit`: `bound = max(commit_lsa, log_hdr->eof_lsa)` 를 저장. 구간 안 커밋은 한 건씩 dispatch 후 `wait_until_retired`. 구간 안에서는 INSERT 중복, UPDATE/DELETE 대상 없음 오류를 `recovery_skipped_counter` 로만 집계 | slave가 수 GB 뒤처진 상태에서 applier가 한 번 재시작하면 (committed, 당시 eof] 전체가 병렬 없이 적용된다. 병렬화가 가장 필요한 따라잡기 구간에서 성능이 사라지고, 그 구간에서 실제 결함으로 생긴 불일치도 같은 오류 코드면 숨겨진다. `recovery_skipped_counter` 는 `_db_ha_apply_info` 에 저장되지 않아 운영자가 볼 수 없다 | 확정 | 신규 |
| E7 | Low | log_applier.c:8545-8548, 1128-1133, 7268, applier/log_applier_pending.cpp:177-189 | applier 종료 시 SYSOP 조각(fragment) 슬롯과 그 항목이 누수된다 | 조각 슬롯은 `malloc` 후 retire에서만 `la_free_all_repl_items + free_and_init`. `la_pending_clear` 는 노드만 해제, in-flight 항목은 `la_inflight_init` 이 배열만 재할당 | serial/AUTO_INCREMENT를 쓰는 부하 중에 서버 다운, flush 오류로 applier가 같은 프로세스 안에서 재시작할 때마다 park/in-flight 상태였던 조각의 LA_APPLY와 LA_ITEM(packed key 포함)이 해제되지 않는다. 장시간 운영 시 VSZ 증가로 `ER_HA_LA_EXCEED_MAX_MEM_SIZE` 재시작을 앞당길 수 있다 | 확정 | 신규 |

#### E1 상세

- master 쪽 근거: `log_manager.c:1504-1514` 는 재시작 직후 `log_Gl.hdr.append_lsa` 를 history_start로 올린다. `writeset.cpp:1032` 에서 후보 시작값이 history_start이고 `1091-1095` 에서 결과를 history_start 이상으로 끌어올린다. 그래서 재시작 뒤 이력에 없는 키만 건드린 트랜잭션은 모두 dep = restart_lsa를 받는다. 이 값은 커밋 레코드의 LSA가 아니다.
- slave 쪽 근거: `la_coordinator_submit_task` 는 `la_gate_order_push (&task->commit_lsa)`(7372) 뒤에 `la_gate_is_satisfied`(7420)를 본다. frontier는 링 항목의 commit LSA 값만 가진다(`la_gate_advance_frontier`). 따라서 dep가 링 항목 사이 값이면 "dep 바로 위 첫 링 항목"까지 완료돼야 통과하는데, 그 항목이 자기 자신이면 영원히 통과하지 못한다. `la_coordinator_set_commit_dependency`(7553-7578)는 라벨이 있는 커밋의 dep를 링 꼬리로 내리지 않는다.
- 복구 구간 직렬 경로(7384-7400)에서 같은 상황이면 `do { drain_ready; wait_until_retired } while (!la_pending_is_empty ())` 가 in-flight 0인 채로 바쁜 반복을 하며 종료 플래그도 보지 않는다.
- 트리거가 확정되지 않은 이유: 재시작 직후 master 노드의 applylogdb가 `_db_ha_apply_info` 를 갱신하는 커밋, 시스템 커밋 등이 첫 사용자 커밋보다 먼저 로그에 들어오면 그 빈 커밋이 링 위 사다리 역할을 해서 문제가 가려진다. 즉 경합에 따라 재현 여부가 갈린다.
- 재현 시나리오(제안): master 단독 재시작(heartbeat 비활성, applylogdb 미기동 상태로 서버만 재기동) → 첫 SQL로 PK 테이블에 INSERT 1건 커밋 → slave applylogdb의 `[WSET] reader schedule ... status=2` 가 RELEASED로 바뀌지 않는지, `la_gate_order_get_count` 가 늘기만 하는지 확인.
- 단위테스트 공백: `test_log_applier_gate.cpp` 의 7개 케이스는 모두 dep가 링 항목과 같은 값이다. "dep가 frontier와 자기 commit 사이의 비커밋 LSA"인 케이스가 없다.
- 수정 방향(제안): slave에서 push 전에 `dep > 링 꼬리` 이면 dep를 링 꼬리(링이 비면 frontier)로 내린다. 의미상 "dep 이하 모든 커밋 완료"와 같다. 또는 master가 restart 경계를 링에 올라가는 레코드(예: 라벨 + 빈 커밋, 혹은 `complete_without_task` 를 유도하는 레코드)로 남긴다.

#### E2 상세

- `la_result_queue_pop`(result_queue.cpp:178-187)은 `count == 0 && shutdown == false` 동안 `pthread_cond_wait`. shutdown은 `la_result_queue_signal_shutdown` 에서만 서고 호출자는 `la_stop_apply_workers`(log_applier.c:1525-1533) 하나다.
- `la_worker_startup_failed`(worker.cpp:378-392)는 마지막 워커가 빠질 때 `request_shutdown` 만 호출한다(`la_applier_need_shutdown = true`, log_applier.c:1519-1522). 이 플래그는 `la_coordinator_wait_for_commit_order_slot`(743) 처럼 timed wait 루프에서만 읽힌다.
- 직렬 경로는 복구 구간에서만 쓰이고 복구 구간은 재시작 직후에만 있다. 재시작 원인이 서버 다운인 경우 워커 세션 수립 실패와 겹칠 확률이 낮지 않다(추정).
- 제안: blocking pop 대신 `la_result_queue_wait_for_result (100)` + `try_pop` 루프로 바꾸고 매 회 `la_applier_need_shutdown` 을 확인하거나, `la_worker_startup_failed` 의 마지막 워커가 result queue shutdown을 직접 건다.
- 단위테스트 공백: queue 테스트(`test_log_applier_queues.cpp:183`)는 shutdown이 대기자를 깨우는지만 본다. "워커 0명 + in-flight 1건" 같은 coordinator 수준 시나리오는 coordinator 코드가 static이라 테스트할 수 없다(R1).

#### E3 상세

- develop `la_apply_repl_log` 는 적용 직전마다 `la_lock_dbname` 을 불렀다(a9a0dc78d:5781). 브랜치는 워커가 `db_lockf_vdes` 를 건드리지 않게 하려고 시작 시 한 번으로 옮겼다(9817 주석). 그러나 해제 경로 세 곳(9956, 9975, 10320)은 그대로라 한 번 풀리면 다시 잡히지 않는다.
- 부수 효과: 7792 `if (la_Info.db_lockf_vdes != NULL_VOLDES)` 가 거짓이 되어 이후 HA_SERVER_STATE 기반 역할 변경 감지가 꺼진다.
- 2노드 구성에서는 노드당 applier가 하나라 증상이 없고, 3노드 이상이나 replica 구성에서 같은 slave DB를 대상으로 하는 applier가 둘 이상일 때 드러난다(구성 의존성은 추정, 잠금 미재획득은 확정).
- 제안: coordinator가 dispatch 직전(`la_coordinator_dispatch_task`) 또는 main loop 상단에서 `la_lock_dbname` 을 다시 부른다. 이 함수는 이미 잡혀 있으면 바로 반환한다. 10317의 해제는 drain 완료 후로 옮긴다.

#### E4 상세

- 실행 순서: 10317 `la_unlock_dbname (..., clear_owner=true)` → 8435 `is_role_changed = false`, 8440 `LA_SLEEP (60, 0)` → 10329 조건 거짓. unlock이 실패해 `FILEIO_LOCKF` 를 돌려줄 때만 플래그가 남는다.
- 60초 sleep 동안 coordinator는 결과 수집도 하지 않아 workers가 끝낸 결과가 쌓이기만 한다(동작 영향은 지연뿐).
- 서버 쪽 `css_check_ha_log_applier_done` 은 모든 applier가 DONE일 때만 TO_BE_ACTIVE→ACTIVE를 허용한다(server_support.c:1504-1520). 보류가 끝나지 않으면 승격도 끝나지 않는다.
- 제안: 백스톱 조건을 `la_Info.done_deferred` 기준으로 바꾸고 `done_deferred_since` 를 타이머로 쓴다. 이미 있는 값이다.

#### E5 상세

- `LA_LOG_READ_ALIGN`, `LA_LOG_READ_ADVANCE_WHEN_DOESNT_FIT` 는 `la_get_page` 실패 시 `error = ER_IO_READ` 만 세운다. `la_get_wset_label` 은 이를 받아 그냥 return하고 호출부(7817)는 성공으로 간주한다.
- 비교: 같은 파일의 `la_get_ha_server_state` 는 실패 시 NULL을 돌려 호출부가 처리한다.
- 제안: int를 반환하게 하고 실패 시 `la_applier_need_shutdown` 후 오류 반환. 최소한 실패 시 `la_wset_label_trid` 를 세우지 않아 "라벨 없음 → 링 꼬리 의존"(7574-7578) 경로로 떨어지게 한다.

#### E6 상세

- 의도(주석 771-775): bound를 배치 단위로 저장해 저장 횟수를 줄인다. 대가로 상한이 실제 dispatch된 최대 커밋보다 훨씬 클 수 있다.
- 재시작 시 `la_is_in_recovery_range` 가 참인 커밋은 `worker_count > 1` 이어도 한 건씩 처리(7378-7411).
- 제안: bound를 "이번 배치에서 실제로 dispatch할 마지막 커밋"에 가깝게 잡거나(예: 현재 읽은 페이지 끝, 혹은 commit_lsa + 고정 폭), 복구 구간 안에서도 gate가 허용하는 병렬을 쓰되 교착만 재시도로 처리한다. 또 `recovery_skipped_counter` 를 applyinfo나 catalog로 노출한다.

#### E7 상세

- `la_coordinator_release_apply_slot`(1128-1133)만 조각을 해제한다. `la_shutdown` 은 `la_stop_apply_workers` → `la_pending_clear` 순서로 진행하며 둘 다 `task->apply`(조각)를 해제하지 않는다.
- 제안: `la_pending_foreach` 와 `la_inflight_entry_at` 로 `rectype == LOG_SYSOP_END` 인 항목의 apply를 해제한 뒤 clear.

### 3.2 모듈화

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| M1 | Low | log_applier.c:7330-7331, 8447-8538 | 라벨 보관 전역(`la_wset_label_trid`, `la_wset_label_dependency_seq`)이 `la_init` 에서 초기화되지 않는다 | 파일 static, `LOG_ABORT` 처리(7759-7769)와 `la_init` 어디서도 지우지 않음 | 프로세스 내 재시작 직전 라벨만 읽고 커밋을 못 읽은 경우 값이 다음 run으로 넘어간다. trid가 단조 증가라 현재는 다른 커밋에 붙을 일이 거의 없지만, 상태 수명이 run과 어긋나 테스트·추론이 어렵다 | 확정(영향은 추정상 낮음) | 신규 |
| M2 | Low | serial.c:1219-1250, log_manager.c:4038-4072 | serial 갱신에서 수집한 키는 SYSOP_END에서 항상 버려지고, 캐시 BTID가 없을 때는 바깥 트랜잭션 전체를 overflow로 바꾼다 | serial 갱신 sysop은 복제 항목이 있어 `sysop_commit_order` 경로로 가고 `wset_discard_sysop_keys` 로 수집 키를 지움. `BTID_IS_NULL` 이면 `wset_fallback_to_commit_order (serial_tdes, WSET_FALLBACK_STATEMENT_REPLICATION)` | 수집 자체는 결과에 영향이 없는데 실패하면 `NEXT VALUE` 가 사용자 오류로 끝난다. BTID 미캐시 시에는 바깥 트랜잭션이 커밋할 때 `wset_clear_overflow_history` 로 전역 이력이 통째로 지워져 이후 모든 트랜잭션이 한 지점에 직렬화된다. 사유도 STATEMENT_REPLICATION으로 잘못 기록 | 확정 | 신규 |

### 3.3 아키텍처

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| A1 | High | CMakeLists.txt:607 | `MULTI_CONN_TO_A_SERVER` 를 최상위 `add_definitions` 로 켜서 applylogdb뿐 아니라 모든 클라이언트 바이너리(csql, CAS, 유틸리티)의 cubridcs 동작이 바뀐다 | `-#add_definitions(-DMULTI_CONN_TO_A_SERVER)` → `+add_definitions(...)` | 기본값 `ha_apply_worker_count = 1` 인 사용자도, HA를 쓰지 않는 사용자도 multi-connection 분기를 탄 클라이언트 라이브러리를 쓰게 된다. 이 브랜치의 테스트(HA 2노드 벤치)는 그 회귀 범위를 덮지 않는다 | 적용 범위 확정, 동작 영향 추정 | 신규 |
| A2 | Medium | log_record.hpp:140, log_applier.c:7837, log_manager.c:5602,6383, schema_system_catalog_install.cpp:1095-1097, log_applier.c:2896-2916,3349-3353 | 버전 혼합·업그레이드 경로가 정의되지 않았다 | (1) 새 레코드 타입 53. develop의 `LOG_LARGER_LOGREC_TYPE` 이 53이라 develop applier는 7837의 `lrec->type >= LOG_LARGER_LOGREC_TYPE` 에서 `ER_LOG_PAGE_CORRUPTED`. (2) HA master에서는 라벨과 키 수집을 끄는 방법이 없다(`ha_writeset_history_size` 최소 1). (3) `_db_ha_apply_info` 에 컬럼 2개 추가, 마이그레이션 없음. 시작 시 `la_get_ha_apply_max_committed_lsa` 실패가 `la_get_last_ha_applied_info` 실패로 이어짐 | master 먼저 올리는 순차 업그레이드에서 구 slave applylogdb가 새 master 로그를 손상으로 판단해 재시작을 반복한다. 기존 DB에 새 바이너리를 올리면 slave applylogdb가 "Failed to initialize _db_ha_apply_info"로 기동하지 못한다. slave를 worker 1개로 운용해도 master는 키 수집·라벨 기록 비용을 계속 낸다 | (1)(3) 코드 확정, 업그레이드 정책은 추정 | 신규 |

#### A1 상세

- 기본 경로도 바뀌었다는 점이 QA 관점의 핵심이다. `worker_count == 1` 이어도 적용은 `db_restart_sub` 로 연 별도 세션의 워커 스레드에서 일어나고(worker.cpp:149-163), coordinator는 자기 세션으로 `_db_ha_apply_info` 를 갱신한다. "기본값이면 develop과 같다"는 가정은 성립하지 않는다.
- 제안: applylogdb 대상(또는 cubridcs 중 applier가 쓰는 부분)에만 정의를 한정할 수 있는지 검토. 불가하면 전체 SQL/shell 회귀(CircleCI 수준)를 이 브랜치 머지 조건으로 둔다.

### 3.4 리팩토링

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| R1 | Medium | log_applier.c:700-1530, 7330-7652, unit_tests/log_applier/CMakeLists.txt:20-24 | 스케줄링 규칙(submit, park/release, 복구 구간 직렬화, drain 완료, DONE 보류, cover)이 log_applier.c static 함수에 있어 단위테스트할 수 없다. 단위테스트는 자료구조만 덮는다 | CMake 주석: "The workers and the coordinator itself need a server connection and are not unit tested here." 테스트 21건은 gate/inflight/pending/queue 단위 동작 | 이번 리뷰의 E1, E2, E4, E6은 모두 coordinator 규칙의 조합에서 나오며 기존 테스트로는 하나도 잡히지 않는다. 회귀가 HA 실측으로만 드러나 재현 비용이 크다 | 확정 | 신규 |
| R2 | Low | applier/log_applier_pending.cpp:131-166, applier/log_applier_inflight.cpp:278-296 | pending 해제와 결과 매칭이 매번 선형 탐색이다 | `la_pending_pop_ready` 는 매 pop마다 머리부터 순회, `la_coordinator_drain_ready` 가 이를 반복. `la_inflight_find_by_seq` 도 선형 | hot key 부하로 park가 수천 건(최대 worker×1024) 쌓이면 결과 1건마다 수천 회 비교. coordinator가 단일 스레드라 처리량 상한이 된다. seq는 연속이므로 `(seq - head.seq)` 로 O(1) 인덱싱 가능 | 확정(영향 규모는 추정) | 신규 |
| R3 | Low | log_applier.c:872, 1005, 1249, 1259, 7505, 7512, 7523, 9590 | 로그/trace 문자열이 coordinator를 "reader"로 부른다 | `"[WSET] reader schedule ..."`, `"applylogdb reader exit: ..."` | 코드 용어(coordinator)와 운영 로그 용어가 달라 장애 분석 시 혼동. grep 기반 하니스와 문서가 둘 다를 알아야 함 | 확정 | 신규 |
| R4 | Low | log_applier.c:1400-1456 | 테스트용 지연 훅이 release 빌드에 있고 커밋마다 `getenv` 를 부른다 | `la_apply_worker_test_block_before_commit` 은 TODO로 제거 예정 명시, 게이트는 환경변수뿐 | 운영 환경에 `CUBRID_HA_TEST_BLOCK_CLASS` 가 남아 있으면 해당 클래스 커밋마다 기본 60초 지연. 핫패스에서 매 커밋 `getenv` 2회 | 확정 | 신규 |
| R5 | Low | unit_tests/writeset/test_writeset_stress.cpp:128-629, test_writeset_bench.cpp:35-165, test_writeset_concurrency.cpp:267-277 | stress/benchmark 케이스가 숨김 태그가 아니어서 `test_writeset` 기본 실행에 포함된다 | 태그 `[stress]`, `[benchmark]` (Catch2에서 `.` 접두가 없으면 기본 실행 대상) | 기능 회귀를 보려고 바이너리를 돌리면 B5(스레드×대형 커밋×대형 맵) 같은 장시간·타이밍 의존 케이스가 함께 돌아 CI 시간과 불안정성이 늘어난다 | 확정(소요 시간은 추정) | 신규 |

#### R1 상세: 추가해야 할 테스트 목록

coordinator 규칙을 `applier/log_applier_coordinator.cpp` 같은 모듈로 빼고 dispatch·결과 대기를 콜백으로 주입하면 서버 없이 다음을 결정적으로 검증할 수 있다.

1. 라벨이 링 항목 사이 LSA를 가리킬 때(재시작 경계) 자기 커밋이 park되지 않는다(E1).
2. 라벨이 링 꼬리보다 큰 LSA일 때 동일.
3. 워커 0명, in-flight 1건, 종료 요청 시 coordinator가 제한 시간 안에 빠진다(E2).
4. 복구 구간 직렬 경로에서 pending이 비지 않는 상태가 되면 무한 반복하지 않는다(E1+7384-7400).
5. 실패 결과가 head에 오면 retire가 오류를 반환하고 그 뒤 성공 결과들도 gate에는 반영된다.
6. 라벨 SYSOP_END(항목 있음/없음) 뒤 바깥 커밋의 dep가 조각 LSA 이상으로 올라간다(`la_coordinator_set_commit_dependency`).
7. 라벨 없는 항목 있는 커밋은 링 꼬리를 dep로 받는다.
8. `worker_count == 1` 에서 park가 일어나지 않고 FIFO 순서가 유지된다.
9. DONE 보류가 drain 완료 후에만 풀리고 백스톱이 실제로 발화한다(E4).
10. long transaction 조각 분리(`la_detach_sysop_fragment` 의 `is_long_trans` 분기) 후 바깥 슬롯과 조각의 항목 경계.

## 4. 미검증 의심

- U1. 2PC 복구 분석이 라벨 레코드에서 실패할 가능성(추정, Low): `log_2pc_recovery_analysis_record`(log_2pc.c:2253-2348)의 switch에 `LOG_DUMMY_WSET_LABEL` 이 없어 default에서 `ER_LOG_PAGE_CORRUPTED` 를 반환한다. 라벨은 `log_complete_for_2pc` 에서 해당 trid 체인에 붙는다. 라벨만 flush되고 커밋 레코드는 flush되기 전에 죽은 2PC 트랜잭션을 분석할 때 이 경로를 타는지는 확인하지 못했다. 같은 switch에 `LOG_SUPPLEMENTAL_INFO` 도 없어 develop에도 같은 유형의 공백이 있다.
- U2. 워커가 `la_Info.act_log.log_hdr->eof_lsa` 를 cache mutex 없이 읽는다(log_applier.c:7206). coordinator는 `check_reinit_copylog` 에서 헤더를 같은 버퍼에 다시 읽어 쓴다(9901-9902). LSA 읽기가 찢어질 수 있는지는 플랫폼·버퍼 갱신 방식에 따라 달라 확인하지 못했다.
- U3. `la_commit_transaction`(8210-8227)이 워커 스레드마다 `ws_Resident_classes` 를 순회하며 `ws_intern_instances` 를 부른다. MULTI_CONN에서 이 목록과 workspace가 스레드별인지 공유인지는 CS 내부라 범위 밖으로 두었다. 공유라면 워커 간 경쟁이다.
- U4. `la_applier_need_shutdown`(log_applier.c:445)은 워커가 쓰고 coordinator가 읽는 일반 bool이다. 호출 경계마다 mutex가 있어 실사용 영향은 없어 보이나 TSan 기준으로는 data race다. `la_task_queue_get_count`, `la_result_queue_get_count`, worker의 `busy` 도 같다.
- U5. E1의 실제 발생 빈도. master 재시작 직후 첫 커밋이 사용자 커밋인지 시스템/applier 커밋인지에 따라 갈린다. 실측으로 확인이 필요하다.
- U6. 복구 구간 안의 statement 항목 재적용(log_applier.c:6964 TODO). DDL 재실행 오류는 fail_counter로만 남고 계속 진행하지만, 비멱등 statement(예: checksumdb 갱신) 재적용 결과는 확인하지 못했다.

## 5. 총평

master의 키 수집·라벨 생성과 slave의 gate·in-flight·pending 구조는 각각 주석이 충실하고 자료구조 단위 테스트도 의도한 성질을 정확히 짚는다. 실패 결과를 gate에 반영하지 않는 규칙, 커밋 전 bound 저장, DONE 보류처럼 정확성을 위한 장치도 일관된 방향으로 들어가 있다.

QA 관점에서 문제는 경계에서 두 모듈이 만나는 지점이다. master는 "라벨 = 이 LSA 이하 전부 완료"라는 의미로 커밋이 아닌 LSA(재시작 경계)를 라벨로 내보내는데, slave gate는 "라벨 = 링 위 커밋 LSA"를 전제로 판정해 그 차이에서 영구 정지가 생긴다(E1). 여기에 블로킹 대기의 종료 무시(E2), 작동하지 않는 DONE 백스톱(E4)이 겹치면 복제 정지가 failover 정지로 번진다. dbname 잠금 미재획득(E3)은 develop 대비 분명한 회귀다. 이 결함들은 모두 static coordinator 규칙 안에 있어 현재 단위테스트로는 잡을 수 없으므로(R1), 수정과 함께 coordinator 규칙을 테스트 가능한 모듈로 분리하는 것을 권한다.

또한 `MULTI_CONN_TO_A_SERVER` 전역 활성화(A1)와 로그 레코드 타입·카탈로그 변경(A2)은 HA를 쓰지 않는 사용자와 업그레이드 경로까지 회귀 범위를 넓히므로, 머지 전 전체 회귀와 업그레이드 시나리오(순차 업그레이드, 기존 DB에 새 바이너리) 검증이 필요하다.

등급별 건수: High 4 (E1, E2, E3, A1) / Medium 5 (E4, E5, E6, A2, R1) / Low 7 (E7, M1, M2, R2, R3, R4, R5). 미검증 의심 6건.
