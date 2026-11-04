# CBRD-27508 브랜치 리뷰: 어플리케이션 개발자 1년차

- 대상: `a9a0dc78d..0e411f10f` (12 커밋), HEAD = `0e411f10f`
- 저장소 상태: 읽기 전용으로 열람만 했다. 빌드와 실행은 하지 않았다.

## 1. 리뷰어 관점

- 역할: 애플리케이션이 실제로 보게 되는 동작을 봤다. 슬레이브에 복제된 결과가 마스터와 같은지(트랜잭션 의미가 보존되는지), 사용자 DML에 새로 나올 수 있는 에러 코드와 메시지, 기존 DB·이전 버전 바이너리·기존 운영 옵션(replica, SQL 로그)과의 호환성, 마스터 DML 경로에 더해지는 성능 비용이 대상이다.
- 연차: 이 코드를 처음 읽는 사람의 입장에서 읽었다. 이해를 막는 명명, 서로 어긋나는 주석, 테스트용 코드가 섞인 곳, 명백한 실수를 함께 표시했다.
- 근거: 모든 항목은 HEAD 코드와 `git show a9a0dc78d:<path>` 비교로 확인했다. 실행해서 재현한 항목은 없다. 실행 순서나 부하 규모에 따라 달라지는 부분은 "추정"이라고 표시했다.

## 2. 검토 범위와 실제로 읽은 경로

**마스터 (writeset 생성)**
- `src/transaction/writeset.cpp`: 전체. `wset_fnv1a`, `wset_string_hash`, `wset_midxkey_hash`, `wset_add_write_key`, `wset_add_ref_key`, `wset_make_parent_midxkey`, `wset_find_dependency_in_range`, `wset_publish_with_capacity`, `wset_clear_overflow_history`, `wset_publish_commit_to_history`, `wset_discard_sysop_keys`, `wset_abort_after_lsa`, `wset_find_sysop_fallback_dependency`, `wset_raise_history_start`
- `writeset.hpp`, `writeset_types.hpp`, `writeset_history_map.{hpp,cpp}`
- `log_manager.c` diff 전체. `log_initialize_internal`의 RESTART 하한, `log_sysop_start`, `log_sysop_commit_internal`, `log_append_sysop_end_internal`, `log_sysop_fallback_reason`, `log_append_wset_label_and_sysop_end`, `log_append_repl_info_and_commit_log`, `log_append_wset_label_with_lock`, `log_commit_local`, `log_complete_for_2pc`. 덤프와 CDC switch(`log_dump_record` 7437 부근, `cdc_log_extract` 11460 부근)도 읽었다.
- `log_record.hpp`, `log_impl.h`, `log_append.cpp`, `log_recovery.c`, `log_tran_table.c` diff, `flashback.c` switch(새 레코드 타입 처리 누락 여부 확인용)
- `locator_sr.c` diff. `locator_wset_collect_fk_ref`, `locator_add_or_remove_index_internal`, `locator_update_index`, `locator_is_inserter_committing`, `locator_lock_and_get_object_internal`, `xlocator_repl_force`
- `btree.c` diff(`btree_is_deleter_committing` 및 unique 검사 두 곳), `serial.c` diff와 `serial_cache_index_btid`, `heap_file.c`의 AUTO_INCREMENT `cached_num` 경로, `replication.c` diff(`repl_log_insert`의 flush mark, `repl_end_flush_mark`)
- `lock_manager.c`: `lock_transaction_mvccid`, `lock_unlock_transaction_mvccid` (caller 입장에서 NULL·비정상 MVCCID 처리만 확인)
- `system_parameter.{c,h}`, `heartbeat.h`, `error_code.h`, `msg/*/cubrid.msg`, `schema_system_catalog_install.cpp`

**슬레이브 (병렬 applylogdb)**
- `log_applier.c`: coordinator 경로(`la_coordinator_submit_task`, `_dispatch_task`, `_cover_commit`, `_drain_ready`, `_collect_results`, `_retire_results`, `_record_result`, `_complete_without_task`, `_process_commit`, `_set_commit_dependency`, `_process_sysop_end`, `_wait_*`), `la_log_record_process`, `la_apply_repl_log`(develop 버전과 비교), `la_flush_repl_items`, `la_apply_statement_log`, `la_update_query_execute*`, `la_commit_transaction`(develop 버전과 비교), `la_get/update_ha_apply_max_committed_lsa`, `la_delay_replica`, `la_init`의 worker_count 처리, failover drain backstop, `la_apply_worker_*`, 테스트 훅
- `log_applier.h`, `src/transaction/applier/*` 전체(gate, pending, inflight, worker, task/result 헤더, debug)
- `log_applier_sql_log.c`: `sl_write_sql`과 전역 상태. 이 브랜치에서 바뀌지 않은 파일이지만 이제 워커 여러 개가 동시에 호출한다.
- `unit_tests/log_applier/test_log_applier_gate.cpp`의 케이스 목록, `unit_tests/CMakeLists.txt`

**CS glue (caller만 확인)**
- `CMakeLists.txt`(`MULTI_CONN_TO_A_SERVER`), `cs/CMakeLists.txt`, `work_space.{c,h}`(`ws_get_repl_obj_count`), `file_io.c` diff, `log_applier_worker.cpp`의 `db_restart_sub`/`db_shutdown_sub` 호출과 반환값 처리, `authenticate.c`의 `au_ctx` thread-local 여부(DDL 워커의 `AU_SET_USER` 영향 확인용)

---

## 3. 발견 사항

### 3.1 에러

| ID | 등급 | 위치 | 내용 | 근거 | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| E-1 | High | `log_manager.c:1513`, `writeset.cpp:1032,1108-1112`, `log_applier_gate.cpp:290`, `log_applier.c:7420` | 마스터가 재시작하면 history_start를 append_lsa로 올린다. 이 LSA는 커밋 LSA가 아니어서 슬레이브의 commit-order ring에 들어가지 않는다. 그래서 gate가 영원히 통과시키지 않는 라벨이 생길 수 있다 | `wset_raise_history_start (&restart_lsa, "RESTART")` / 라벨 하한 `LSA_COPY (wset_parent_out, &history_start_snapshot)` / gate 통과 조건 `LSA_LE (dep, &la_Gate_frontier)` | `ha_apply_worker_count>1`이고 마스터 cub_server가 재시작한 경우. 재시작 후 첫 사용자 커밋 C1의 라벨은 restart_lsa이고, 그 값은 직전 커밋 Cprev와 C1 사이에 놓인다. frontier는 Cprev에서 멈추고 C1은 park된다. C1이 ring head를 막으므로 이후 커밋도 모두 park된다. 결과 큐가 비어 coordinator는 `wait_for_commit_order_slot`에서 계속 대기하고, 에러 없이 복제가 멈춘다 | 확정(코드 경로). 재현은 하지 않음 | 신규 |
| E-2 | High | `log_applier_sql_log.c:539,562` (워커 caller는 `log_applier.c:6196,6377,6580,6848`) | `ha_enable_sql_logging=yes`일 때 여러 워커가 SQL 로그 전역 상태(`log_fp`, `sl_Info`)를 lock 없이 함께 쓴다 | `fprintf (log_fp, ..., ++sl_Info.last_inserted_sql_id, ...)` / `log_fp = sl_open_next_file (log_fp);` | 워커 A가 파일 크기 한도에 걸려 `sl_open_next_file`로 기존 fp를 닫는 동안 워커 B가 같은 `log_fp`에 `fwrite`하면 해제된 FILE을 사용하게 되어 applylogdb가 크래시한다. 크래시가 나지 않아도 sql_id가 중복되거나 빠지고, 로그 순서가 커밋 순서와 달라진다 | 확정 | 신규(병렬화로 생긴 문제) |
| E-3 | High | `schema_system_catalog_install.cpp:1096-1097`, `log_applier.c:2896-2913` | `_db_ha_apply_info`에 컬럼 두 개를 추가했지만 기존 DB용 마이그레이션이나 호환성 처리가 없다 | `{"max_committed_lsa_pageid", "bigint"}` / `SELECT max_committed_lsa_pageid, max_committed_lsa_offset FROM ...` 후 `if (res < 0) return res;` | develop으로 만든 기존 HA DB에 이 브랜치 바이너리를 올리면, applylogdb가 시작할 때 SELECT가 없는 컬럼 때문에 실패한다. 그러면 `la_get_last_ha_applied_info`가 실패하고 슬레이브 복제가 시작되지 않는다 | 확정 | 신규 |
| E-4 | Medium | `log_applier.c:7606-7618`, `10455-10489` | replica 모드의 `ha_replica_time_bound`와 `ha_replica_delay`를 coordinator가 잠자는 방식으로 처리한다. 작성자도 TODO로 남긴 미완 상태다 | `select (0, NULL, NULL, NULL, NULL);` / `while ((time (NULL) - eot_time) < replica_delay)` | worker>1인 replica에서 time bound에 도달하면 coordinator가 무기한 멈춘다. bound 이전에 park된 트랜잭션은 끝내 적용되지 않는다. 그 사이 다른 트랜잭션은 이미 적용되어 있으므로, 사용자가 보는 replica는 "bound 시점까지의 연속된 상태"가 아니다. worker=1이어도 retire가 멈추므로 `_db_ha_apply_info`(applyinfo)의 위치 정보가 갱신되지 않는다 | 확정(TODO 명시) | 신규 |
| E-5 | Medium | `log_record.hpp:140` | 새 로그 레코드 타입 53이 develop 바이너리의 `LOG_LARGER_LOGREC_TYPE` 값과 같다 | develop `log_record.hpp`: `LOG_SUPPLEMENTAL_INFO = 52`, 다음이 `LOG_LARGER_LOGREC_TYPE`(=53). develop `la_log_record_process`: `lrec->type >= LOG_LARGER_LOGREC_TYPE`이면 `ER_LOG_PAGE_CORRUPTED` | 마스터만 먼저 새 버전으로 올리고 슬레이브 applylogdb는 이전 버전인 상태(롤링 업그레이드, 버전 혼재)에서, 이전 applier가 첫 커밋 앞의 LABEL 레코드를 "손상된 로그"로 판단하고 멈춘다 | 확정 | 신규 |
| E-6 | Low | `log_manager.c:7437-7466` | 로그 덤프(`log_dump_record`)에 `LOG_DUMMY_WSET_LABEL` case가 없다 | default 분기에서 `"log_dump: Unknown record type = %d (%s).\n"` | HA 마스터 로그를 덤프하면 커밋마다 Unknown record type 줄이 출력된다. 다음 레코드는 forw_lsa로 계속 읽으므로 덤프가 중단되지는 않는다. 진단 출력만 오염된다 | 확정 | 신규 |

**E-1 상세**
- 마스터 쪽 경로: 재시작하면 `log_initialize_internal`이 recovery 뒤에 `history_start = append_lsa`로 설정한다(`log_manager.c:1505-1514`). 재시작 직후에는 map과 `prev_commit_lsa`가 모두 비어 있다. 그래서 `wset_find_dependency_in_range`는 `wset_parent = history_start`에서 출발하고, `prev_commit_snapshot`이 NULL이라 그 값을 그대로 쓴 뒤 하한을 적용한다. 결과적으로 라벨은 restart_lsa가 된다(`writeset.cpp:1032, 1099-1112`). 이후 키가 겹치지 않는 커밋은 `min(history_start, prev_commit)`을 거쳐 하한으로 다시 올라가므로 계속 restart_lsa를 라벨로 받는다.
- 슬레이브 쪽 경로: ring에는 LOG_COMMIT LSA와 라벨이 붙은 SYSOP_END LSA만 들어간다(`la_gate_order_push`의 caller는 `la_coordinator_submit_task`와 `la_coordinator_complete_without_task` 둘뿐이다). frontier는 ring 위의 커밋 LSA 값만 가질 수 있다. 따라서 `Cprev < restart_lsa < C1`이면 C1이 완료되기 전에는 `frontier >= restart_lsa`가 될 수 없다. 그런데 C1은 바로 그 조건을 기다린다. 순환 대기다.
- 풀리는 경우: restart_lsa와 C1 사이에 라벨도 item도 없는 커밋(예: 마스터 측 applylogdb의 `_db_ha_apply_info` 갱신)이 먼저 ring에 들어와 완료되면 frontier가 restart_lsa를 넘어가고 문제가 생기지 않는다. 이것이 발생 여부가 실행 순서에 달린 이유다. 클러스터를 통째로 재시작하면서 마스터만 먼저 올라오는 경우에는 마스터에 peer applylogdb가 없어 사용자 커밋이 먼저 기록되기 쉽다(추정).
- worker=1 경로는 gate 없이 FIFO로 dispatch하므로(`log_applier.c:7378-7411`) 기본값에서는 발생하지 않는다. failover drain backstop(`10329-10356`)은 role change 중에만 동작하므로, 평상시 정지에는 감지나 알림 수단이 없다.
- 단위 테스트(`test_log_applier_gate.cpp`)에는 "의존 LSA가 ring 엔트리 사이에 놓이는" 경우가 없다.
- 제안: 통과 조건을 "dep 이하의 ring 엔트리가 모두 완료됨"으로 바꾼다. 즉 ring이 비었거나 ring head의 commit_lsa > dep이면 통과시킨다. 다른 방법으로, 마스터가 재시작 하한을 실제 로그 레코드(예: 라벨이 붙은 dummy 레코드)로 남겨 slave ring에 올라가게 할 수도 있다.

**E-2 상세**
- develop에서는 applier 스레드가 하나라 `sl_write_sql`의 전역 상태가 문제가 되지 않았다. 이 브랜치에서는 `la_apply_insert_log`, `la_apply_update_log`, `la_apply_delete_log`, `la_apply_statement_log`를 각 워커가 실행한다(`la_apply_worker_run_task` → `la_apply_repl_log`).
- `la_sql_compile_mutex`(`log_applier.c:480`)는 `db_execute` 호출만 감싼다. `sl_*` 호출은 그 밖에 있다.
- 제안: `sl_write_sql`(또는 `sl_write_*` 진입점)을 전용 mutex로 직렬화한다. "SQL 로그 순서 = 마스터 커밋 순서"를 보장할 수 없다는 점은 문서화한다.

**E-3 상세**
- `la_update_ha_apply_max_committed_lsa` 주석(`log_applier.c:2956-2959`)의 TODO에 "final_lsa를 쓰면 카탈로그 변경을 없앨 수 있다"는 대안이 이미 적혀 있다.
- 지금 상태로 머지하면 기존 고객 DB 업그레이드 절차(마이그레이션 스크립트나 catalog 버전 갱신)가 필요하다. 카탈로그를 바꾸지 않는 대안을 먼저 검토하는 것을 권한다.

**E-4 상세**
- 코드에 TODO로 남아 있는 미완 사항이다. 다만 기본 배포 경로를 그대로 쓰므로(worker=1이어도 coordinator/worker 구조를 탄다) replica 사용자의 기존 동작에 영향이 있다. 머지 전에 replica 모드에서 병렬 경로를 막거나, 대기 중에도 retire를 계속하도록 바꿀 필요가 있다.

---

### 3.2 모듈화

| ID | 등급 | 위치 | 내용 | 근거 | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| M-1 | Medium | `CMakeLists.txt:607`, `file_io.c:3882,4084,4123-4127` | applylogdb 하나 때문에 `MULTI_CONN_TO_A_SERVER`를 빌드 전체에 켰다. SA/CS 파일 I/O 경로도 함께 바뀌었다 | `add_definitions(-DMULTI_CONN_TO_A_SERVER)` / `#if !defined (SERVER_MODE) && defined (WINDOWS)` | 이 매크로 아래에 있는 27개 파일의 분기(에러 매니저, message catalog, system parameter, network_cl 등)가 CAS, csql, 모든 CS 유틸리티에서 함께 켜진다. applylogdb와 무관한 애플리케이션 연결 경로의 동작과 성능이 달라질 수 있다 | 확정(전역 적용). 영향 범위는 추정 | 신규 |
| M-2 | Low | `writeset.cpp:525`, `1208`, `1226` / `system_parameter.c` | `ha_writeset_history_size` 하나가 "트랜잭션당 키 한도"와 "전역 history 용량"을 함께 결정한다 | `if ((INT64) tdes->wset_hashes.size () >= wset_History.history_size)` / `map.size () + reserved <= history_size` | 큰 배치 트랜잭션 때문에 한도를 낮추면 map 용량도 같이 줄어 clear가 잦아진다. 반대로 한도를 높이면 메모리가 커진다. 두 값을 따로 조정할 수 없다 | 확정 | 신규 |
| M-3 | Low | `locator_sr.c:8085-8093,8865-8870`, `replication.c:669-704`, `locator_sr.c:7032-7042` | develop에 원래 있던 결함 수정 세 건(lock 실패 시 NO_ERROR 반환, null-LSA update repl record, `xlocator_repl_force`의 deadlock victim 처리)이 writeset 커밋 안에 섞여 있다 | 주석 "Pre-existing defect fixed here" | 수정 자체는 맞다. 하지만 별도 이슈와 커밋으로 나뉘어 있지 않아 develop 단독 백포트나 원인 추적이 어렵다 | 확정 | 기존 결함의 수정 |

**M-1 상세**: 커밋 메시지(cb0095bf2)에 따르면 워커가 `db_restart_sub()`로 자기 연결을 갖기 위해 필요한 매크로다. 이 기능을 applylogdb 타깃에만 적용하거나 런타임 옵션으로 바꿀 수 있는지 확인이 필요하다. `fileio_os_read/write`의 비 Windows SA/CS 경로가 `lseek+read`(mutex 안)에서 `pread/pwrite`로 바뀐 것도 같은 맥락의 변경이다. 의도한 변경이라면 그 이유를 커밋이나 주석에 남겨야 한다.

---

### 3.3 아키텍처 (설계 일관성과 성능 영향)

| ID | 등급 | 위치 | 내용 | 근거 | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| A-1 | Medium | `log_manager.c:4039-4073`, `heap_file.c:17585-17587`, `serial.c:1172-1175` | 캐시 없는 AUTO_INCREMENT 컬럼과 serial NEXT VALUE는 값 하나마다 sysop을 만들고, 그 sysop은 commit-order 장벽이 된다 | `if (log_record->type == LOG_SYSOP_END_COMMIT && repl_item_count > 0)` → `wset_raise_history_start (&sysop_lsa, ...)` / heap_file 주석 "cached_num <= 1 keeps the uncached, per-row-write behavior" | AUTO_INCREMENT 테이블에 INSERT가 많으면 (1) 마스터에서 행마다 전역 `seq_lock`과 `history_lock` 배타 잠금을 잡고, (2) 슬레이브에서 행마다 "앞의 모든 커밋을 기다리고 뒤의 모든 커밋이 기다리는" 지점이 생긴다. 흔한 애플리케이션 패턴에서 병렬 적용이 거의 직렬로 떨어진다 | 경로는 확정. 처리량 저하 정도는 추정 | 신규 |
| A-2 | Medium | `writeset.cpp:1242-1259`, `1361-1366`, `replication.c:534-537` | statement replication(DDL, checksumdb 등)이나 키 한도 초과로 overflow된 커밋은 history 전체를 전역 잠금 아래에서 비운다 | `pthread_mutex_lock (&seq_lock); pthread_rwlock_wrlock (&history_lock); ... wset_History.map.clear ();` | map이 기본 최대 1,000,000개까지 찬 상태에서 DDL이 커밋되면, clear하는 동안 마스터의 모든 HA 커밋(의존성 탐색과 publish)이 멈춘다. 애플리케이션 입장에서는 DDL 때마다 커밋 지연이 튄다 | 경로는 확정. 지연 크기는 추정 | 신규 |
| A-3 | Low | `writeset.cpp:638,942`, `locator_sr.c:13301-13307`, `btree.c:27552-27560` | 마스터 DML의 hot path에 행·인덱스 단위 비용이 더해진다 | 숫자 키마다 `buf = (char *) malloc ((size_t) buf_len);`, X 잠금으로 행을 가져올 때마다 `lock_transaction_mvccid (..., LK_COND_LOCK)` probe | vacuum 전인 행(최근 INSERT된 행)을 UPDATE/DELETE할 때마다 lock manager를 한 번 왕복한다. 키 하나마다 malloc/free가 한 번 일어난다. locator는 이미 `DBVAL_BUFSIZE` 스택 버퍼 방식을 쓰고 있으니 같은 방식으로 바꿀 수 있다 | 확정(코드). 영향 정도는 추정 | 신규 |
| A-4 | Low | `writeset.cpp:597-598` | UNIQUE 컬럼이 NULL이면 모든 행이 같은 hash를 갖는다 | 주석 "A NULL unique key ... collected below as its packed NULL representation" | 선택 입력인 UNIQUE 컬럼(예: email NULL 허용)이 있는 테이블에서는 서로 무관한 INSERT끼리 거짓 의존이 생겨 직렬화된다. 정확성 문제는 없고 성능만 떨어진다 | 확정 | 신규 |
| A-5 | Low | `log_applier.c:6634-6648`, `6680-6694` | 파서가 thread-safe하지 않아 둔 mutex가 문장 실행 전체를 감싼다 | `pthread_mutex_lock (&la_sql_compile_mutex); res = db_execute (...); ... db_query_end ...; unlock` | 슬레이브에서 오래 걸리는 DDL(대형 테이블 CREATE INDEX 등)을 실행하는 동안, coordinator의 `_db_ha_apply_info` 갱신(`la_update_query_execute_with_values`)이 같은 mutex에서 기다린다. 그 동안 dispatch와 retire가 모두 멈춘다 | 확정(코드). 영향은 추정 | 신규 |
| A-6 | Low | `log_applier_pending.cpp:96-125`, `log_applier.c:691-705` | park된 목록에서 꺼낼 때마다 head부터 선형 탐색한다 | `for (cur = la_Pending_head; ...) if (!la_gate_is_satisfied ...) continue;` | 핫키 체인 때문에 수천 건이 park되면 `drain_ready` 한 번이 O(n·k) 비용을 쓴다. coordinator CPU가 병목이 될 수 있다 | 추정 | 신규 |

**A-1 상세**: `log_sysop_commit_internal`의 TODO(`log_manager.c:4042-4049`)에 "키 기반으로 바꾸는 방안은 보류"라고 적혀 있다. 애플리케이션 개발자 입장에서는 가장 흔한 스키마 패턴(AUTO_INCREMENT PK)이 병렬화 효과를 거의 받지 못한다는 점이 중요하다. 문서에 "AUTO_INCREMENT/serial에는 cache를 설정해야 병렬화 효과가 있다" 같은 운영 가이드가 필요하다. 아니면 이 보류 항목의 우선순위를 올려야 한다.

---

### 3.4 리팩토링 (가독성, 명명, 주석, 테스트 용이성)

| ID | 등급 | 위치 | 내용 | 근거 | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| R-1 | Medium | `log_applier.c:1400-1455` | 테스트 전용 crash-injection 훅이 release 빌드에 남아 있다. 커밋 직전마다 `getenv` 두 번과 `strcmp`를 실행한다 | `const char *block_class = getenv ("CUBRID_HA_TEST_BLOCK_CLASS");` → `usleep (block_msec * 1000)` | 운영 환경에 같은 이름의 환경 변수가 남아 있으면 해당 클래스의 커밋마다 워커가 60초씩 멈춘다. 로그 접두어도 `ws_marker TEST`라서 원인을 찾기 어렵다 | 확정 | 신규 |
| R-2 | Low | `serial.c:1219-1251` vs `log_manager.c:4039-4072` | serial 갱신에서 수집한 WRITE 키는 같은 sysop의 SYSOP_END에서 항상 버려진다. 실행 시점에는 의미 없는 작업이고, 주석은 실제 동작과 다르다 | serial 주석 "Collect the db_serial key here as this system operation's WRITE" / serial 행은 flush mark로 `LOG_REPL_NEED_FLUSH`(`replication.c:484-489`) → `repl_item_count>0` → `wset_discard_sysop_keys` | 처음 읽는 사람은 serial이 키로 정렬된다고 오해한다. 실제로는 commit-order 장벽으로 처리된다(A-1) | 확정 | 신규 |
| R-3 | Low | `log_applier.c`의 `[WSET] reader ...` 13곳 외 | coordinator를 trace 문자열에서 "reader"라고 부른다. 로그 접두어도 `[WSET]`, `ws_repl`, `ws_worker`, `ws_gate`, `ws_marker`, `ws_lsaguard`로 섞여 있다 | 예: `"[WSET] reader schedule trid=%d ..."`, `"ws_repl skip whole txn ..."` | 함수명(`la_coordinator_*`)과 로그가 다른 이름을 써서 로그를 grep하거나 문서와 대조하기 어렵다 | 확정 | 신규 |
| R-4 | Low | `writeset.cpp:111-120` vs `log_manager.c:4078`, `serial.c:1240`, `log_applier.c` 여러 곳 | trace 레벨을 읽는 방식이 섞여 있다. 캐시된 `wset_Trace_level`/`wset_trace_enabled()`를 쓰는 곳과 `prm_get_integer_value (PRM_ID_HA_WRITESET_TRACE_LEVEL)`을 직접 쓰는 곳(19곳)이 있다 | 위와 같음 | 지금은 파라미터가 동적이지 않아 결과가 같다. 나중에 동적 파라미터로 바꾸면 일부 trace만 레벨 변경을 따라간다 | 확정 | 신규 |
| R-5 | Low | `log_applier_result.hpp:65` vs `log_applier.c:1167-1173` | `committed_rep_lsa` 설명이 서로 반대다 | "advances la_Info.committed_rep_lsa (restart point)" vs "is not used to decide what to re-apply" | 처음 읽는 사람이 재시작 기준을 잘못 이해한다(실제 기준은 committed_lsa와 max_committed_lsa) | 확정 | 신규 |
| R-6 | Low | `log_applier.c:612`, `8162` | `la_commit_transaction`의 `commit_lsa` 인자를 쓰지 않는다. 정의부에 `static`도 빠져 있다(선언부에만 있음) | 함수 본문에서 `commit_lsa`를 참조하는 곳이 없음 | 동작 문제는 없다. 읽는 사람이 commit_lsa를 어디에 쓰는지 찾게 된다 | 확정 | 신규 |
| R-7 | Low | `log_manager.c:4000-4028`, `4771-4782` | "flush가 필요한 repl item 수 세기" 루프가 세 번 복사돼 있다 | `repl_item_count++` / `flushed_item_count--` / `pending_item_count++` | 조건이 바뀌면(예: 새 repl_type 추가) 세 곳을 같이 고쳐야 한다. helper 함수 하나로 묶을 수 있다 | 확정 | 신규 |
| R-8 | Low | `log_applier.c`(11,131행) | coordinator 로직(dispatch, retire, cover, drain, label holder)이 여전히 `log_applier.c`에 있다 | `applier/`에는 자료구조만 분리됨 | coordinator 상태 전이를 단위 테스트할 수 없다. E-1 같은 gate 경계 조건도 함수 단위로 검증하기 어렵다 | 확정 | 신규(기존 파일 비대화) |

---

## 4. 미검증 의심 (근거가 부족해 확정하지 못한 것)

1. **FK 값을 부모 도메인으로 cast하다가 사용자 DML이 실패하는 경우**: `wset_cast_value_to_domain`(`writeset.cpp:687-710`)이 DOMAIN_OVERFLOW나 ER_TP_CANT_COERCE를 반환하면, 그 에러가 HA 마스터의 INSERT/UPDATE/DELETE를 실패시킨다. 비 HA 서버에서는 같은 DML이 성공한다. CUBRID가 FK와 PK의 도메인을 항상 cast 가능한 조합으로만 허용하는지는 확인하지 못했다. 허용하지 않는다면 이 경로는 실제로 실행되지 않는다.
2. **CHAR/VARCHAR 뒤쪽 공백과 collation pseudo key**: 문자열 키는 `lc->mht2str` 32비트 pseudo key로 hash한다. hash 충돌은 거짓 의존만 만들 뿐이라 안전하다. 문제는 그 반대, 즉 collation상 같은 값이 서로 다른 pseudo key를 갖는 경우(놓친 의존)가 없는지다. `mht2str` 구현은 범위 밖이라 확인하지 못했다.
3. **새 에러 `ER_HA_WRITESET_KEY_BUILD_FAILED`(-1386)의 노출 범위**: 대부분 assert로 막힌 경로(domain 없는 midxkey, 알 수 없는 collation, 컬럼 수 불일치)에서만 나온다. 메시지 "Writeset key construction failed: %s"만으로는 애플리케이션 개발자가 HA 복제 메타데이터 문제라는 것을 알기 어렵다. JDBC/CCI 쪽 에러 코드표에 반영할 필요가 있는지는 확인하지 못했다.
4. **재시작 복구 구간에서 INSERT 중복 에러를 skip하는 것**: `la_flush_repl_items`(`log_applier.c:5970-5986`)는 `ER_BTREE_UNIQUE_FAILED`가 어느 인덱스에서 났는지 구분하지 않고 skip한다. PK가 아닌 다른 UNIQUE 인덱스에서 난 진짜 충돌도 복구 구간에서는 조용히 넘어갈 수 있다. 재적용 순서상 그런 상황이 실제로 생기는지는 검증하지 못했다.
5. **MULTI_CONN 아래에서 DDL 이후 다른 워커의 workspace(class MOP 캐시)가 낡은 상태로 남는지**: CS 내부 구현이라 범위 밖이다. caller 쪽에서 `ws_intern_instances`와 commit으로 정리하는 코드(`log_applier.c:8212-8226`)는 확인했다.

---

## 5. 총평

마스터 쪽 writeset 수집(collation pseudo key, composite key의 원소별 축약, FK의 부모 도메인 변환)과 슬레이브 쪽 gate/pending/inflight 분리는 주석이 자세해서 처음 읽는 사람도 따라가기 쉬운 편이다. 수집 실패를 숨기지 않고 DML 에러로 돌려보내는 원칙과, 라벨이 없는 커밋을 직렬로 처리하는 하위 호환 설계도 애플리케이션 관점에서 바람직하다.

머지 전에 반드시 다뤄야 할 것은 세 가지다.
- **E-1**: 마스터 재시작 후 gate가 영구 대기에 빠질 수 있다. worker>1에서 에러 없이 복제가 멈춘다.
- **E-2**: SQL 로그를 켠 환경에서 워커 간 경쟁으로 applylogdb가 크래시할 수 있다.
- **E-3**: 기존 DB를 업그레이드하면 카탈로그 컬럼이 없어 applylogdb가 시작되지 않는다.

이어서 replica 옵션 미지원(E-4), 이전 버전 applier와의 로그 호환(E-5), 빌드 전역 MULTI_CONN(M-1)은 운영 가이드나 제한 조건으로 명시해야 한다.

성능 면에서는 AUTO_INCREMENT/serial이 값마다 commit-order 장벽이 되는 설계(A-1)와 DDL 때마다 history 전체를 지우는 동작(A-2)이 실제 애플리케이션 부하에서 병렬화 효과를 크게 깎을 수 있다(추정). 측정 시나리오에 "캐시 없는 AUTO_INCREMENT 테이블 INSERT"와 "DDL이 섞인 부하"를 포함할 것을 권한다.

가독성 면에서는 release 빌드에 남은 테스트 훅(R-1), 실행 시점에 항상 버려지는 serial 키 수집 코드(R-2), coordinator를 reader라고 부르는 로그(R-3)를 정리하면 처음 읽는 사람의 오해가 크게 줄어든다.

등급별 건수: High 3 / Medium 6 / Low 14 (합계 23)
