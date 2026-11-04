# CBRD-27508 브랜치 리뷰 — 아키텍트 10년차

대상: `a9a0dc78d..0e411f10f` (12 커밋), HEAD = `0e411f10f`. 행 번호는 모두 HEAD 기준.

## 1. 리뷰어 관점

- 역할(아키텍트): master의 writeset 생성(키 수집, 라벨, history)과 slave의 병렬 적용(gate, pending, inflight, worker)이 **같은 계약**을 공유하는지 봤다. 라벨 LSA가 무엇을 뜻하고 slave가 그것을 어떻게 해석하는지, 그리고 그 계약이 재시작·failover·용량 초과 같은 경계에서도 유지되는지가 중심이다.
- 연차(10년차): 기능 하나의 버그보다 **설계 전제가 어디서 깨지는지**를 먼저 봤다. 전제란 "충돌하는 두 트랜잭션은 publish가 끝날 때까지 lock으로 직렬화된다"와 "라벨은 slave ring에 반드시 나타나는 지점이다"이다. 이어서 master commit 경로에 생긴 전역 직렬화 지점, 제품 전체로 퍼지는 빌드 스위치, 로그 포맷 호환, 운영 중 진단 가능성처럼 장기 유지보수와 운영 위험을 봤다.

## 2. 검토 범위와 실제로 읽은 경로

정밀 분석:
- `src/transaction/writeset.cpp`: 전체(1–1489). `wset_fnv1a`, `wset_string_hash`, `wset_midxkey_hash`, `wset_push_hash`, `wset_fallback_to_commit_order`, `wset_add_write_key`, `wset_add_ref_key`, `wset_make_parent_midxkey`, `wset_select_candidate`, `wset_find_dependency_in_range`, `wset_publish_with_capacity`, `wset_clear_overflow_history`, `wset_discard_sysop_keys`, `wset_abort_after_lsa`, `wset_find_sysop_fallback_dependency`, `wset_raise_history_start`
- `writeset.hpp`, `writeset_types.hpp`, `writeset_history_map.{hpp,cpp}`: 전체
- `log_manager.c` diff 전체: `log_initialize_internal`(restart floor), `log_sysop_start`, `log_sysop_commit_internal`, `log_append_sysop_end_internal`, `log_sysop_fallback_reason`, `log_append_wset_label_and_sysop_end`, `log_append_repl_info_and_commit_log`, `log_append_wset_label_with_lock`, `log_commit_local`(5540–5640), `log_complete_for_2pc`. `log_dump_record`(7420–7472)과 CDC 추출 switch(11440–11720)는 새 레코드 타입 처리 여부만 확인
- `log_impl.h`, `log_record.hpp`, `log_append.cpp`, `log_recovery.c`, `log_tran_table.c`: diff 전체
- `locator_sr.c` diff 전체: `locator_wset_collect_fk_ref`, `locator_add_or_remove_index_internal`의 수집 블록, `locator_update_index`의 수집 블록, `locator_is_inserter_committing`, `locator_lock_and_get_object_internal`(대기 재시도), `xlocator_repl_force`(deadlock). caller 추적은 `locator_check_foreign_key`(4033–4175), `locator_check_primary_key_delete`(4240–4256)
- `btree.c` diff와 그 주변: `btree_is_deleter_committing`, `btree_key_find_and_lock_unique_of_unique`(27440–27570), `..._of_non_unique`(27909), `btree_check_foreign_key`(26164–), FK 객체 탐색 콜백(30515–30581)
- `serial.c`(`serial_update_serial_object` 수집 블록과 `xserial_get_next_value`의 cached_num 분기), `replication.c`(`repl_log_insert_statement`, `repl_log_abort_after_lsa`)
- `system_parameter.{c,h}`, `error_code.h`, `heartbeat.h`, `log_applier.h`: diff 전체
- `log_applier.c`: coordinator 경로 전체(680–1300: drain/dispatch/cover/collect/record/complete_without_task/retire), worker run task(1300–1470), `la_find_required_lsa`(2540–2640), `la_apply_repl_log`(6960–7120), sysop fragment와 label 처리(7300–7690), `la_log_record_process`(7690–7860), `la_change_state` DONE 보류(7940–8030), 초기화의 worker_count(8495–8505), main loop의 DONE·drain·page 처리(9860–10130, 10300–10370). 기준선 비교는 `git show a9a0dc78d:src/transaction/log_applier.c`(5742–5905, 6180–6230, 6336)
- `src/transaction/applier/*`: 헤더 전체, `log_applier_gate.cpp` 전체, `log_applier_pending.cpp` 전체, `log_applier_worker.cpp`(1–460)
- `unit_tests/log_applier/test_log_applier_gate.cpp`(TEST_CASE 목록), `unit_tests/writeset/CMakeLists.txt`, `test_writeset.cpp`(history_start 관련 케이스)

CS 쪽(caller와 반환값만):
- `CMakeLists.txt`(607행 `MULTI_CONN_TO_A_SERVER`), `cs/sa/cubrid CMakeLists`, `work_space.{c,h}`, `file_io.c` diff
- `log_applier_worker.cpp`의 `db_restart_sub`/`db_shutdown_sub`/`tr_init`/`db_disable_trigger` 호출과 오류 처리
- `MULTI_CONN_TO_A_SERVER`를 참조하는 위치 수(grep: 27개 파일 92곳). 내부 구현은 보지 않았다.

## 3. 발견 사항

### 3.1 에러

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| E1 | **Critical** | `log_manager.c:1505-1514`, `writeset.cpp:1032,1091-1095`, `applier/log_applier_gate.cpp:290`, `log_applier.c:7420-7426` | master 재시작 floor(append_lsa)는 commit LSA가 아니어서 slave gate가 영원히 통과시키지 못한다 | `wset_raise_history_start (&restart_lsa, "RESTART")`, `la_gate_is_satisfied`: `LSA_LE (dep, &la_Gate_frontier)`. frontier는 ring에 올라간 commit LSA 값만 가진다 | master가 재시작한 뒤 role을 그대로 유지. 재시작 전 마지막 commit c0 < R(=append_lsa) < 재시작 뒤 첫 라벨 commit c1. c1의 라벨은 R이다. slave ring은 [c1]이고 frontier는 c0이다. R ≤ c0가 아니므로 c1은 park된다. frontier는 head인 c1이 끝나야 움직이므로 c1은 영원히 끝나지 않는다. 뒤의 모든 commit이 park되고 ring이 차면 coordinator는 log 읽기를 멈춘다. 이후 failover가 오면 DONE이 보류되고 30초 뒤 drain timeout으로 재시작하지만 같은 지점에서 다시 멈춘다 | 코드 경로 확정. 발생 조건(R과 c1 사이에 라벨 없는 commit이 하나도 없음)은 추정 | 신규 |
| E2 | Medium | `log_applier.c:4646`, `:7817-7818`, `:7553-7558` | 라벨 레코드를 읽지 못하면 "의존 없음"으로 실행한다(fail-open) | `la_get_wset_label`: 첫 줄 `LSA_SET_NULL (dependency_seq)`, 페이지 읽기 실패 시 그대로 `return`. 호출부는 결과와 무관하게 `la_wset_label_trid = lrec->trid` | label이 페이지 경계에 걸쳐 있고 다음 페이지 fetch가 실패한다. dep = NULL, has_label = true이므로 "라벨 없으면 ring tail을 기다린다"는 fallback(7574)도 타지 않는다. 같은 PK를 앞서 바꾼 트랜잭션과 병렬로 실행되고, 순서가 뒤집히면 DELETE/UPDATE 대상 없음이 fail_counter로 조용히 넘어가 slave가 갈라진다 | 확정(코드). 발생 빈도는 추정 | 신규 |
| E3 | Medium | `btree.c:30530-30533`, `btree.c:27491-27515`, `locator_sr.c:13303` | "커밋 중인 트랜잭션을 기다린다" 보강이 FK 경로를 빠뜨려 라벨 불변식이 깨진다 | FK 탐색 콜백 `case DELETE_RECORD_DELETED: ... return NO_ERROR;`(대기 없음). 자식 INSERT의 부모 확인은 `DELETE_RECORD_CAN_DELETE`에서 S_LOCK만 잡는다. 부모 INSERT 행은 per-row X-lock이 없다(`lock_manager.c:6648` 주석). 신규 대기는 `lock_mode == X_LOCK` 경로(13303)와 unique 검사의 DELETED 분기(27552, 27909)에만 있다 | (a) 자식 T_c가 자식 행을 DELETE하고 complete_mvcc를 마친 뒤 publish 전이다. 이때 부모 T_p가 부모를 DELETE하면 `btree_find_foreign_key`가 그 자식 행을 DELETED로 보고 바로 통과한다. T_p의 probe는 T_c의 REF(old)를 못 보므로 slave에서 둘이 병렬로 적용된다. (b) 부모 INSERT가 커밋 중일 때 자식 INSERT가 S-lock을 바로 얻고 REF probe가 부모 WRITE를 못 본다. 단, applier는 FK 검사를 건너뛰므로(`locator_sr.c:4162`, `:4248`) 최종 상태는 수렴한다. 영향은 slave 읽기의 일시적 FK 불일치와 "REF는 부모 WRITE 뒤에 온다"는 설계 불변식 위반이다 | 대기 누락 확정. 영향 범위는 추정 | MVCC 창 자체는 기존. 보강 범위 누락은 신규 |
| E4 | Medium | `log_applier.c:6705`, `:10329-10357` | failover drain timeout이 30초 고정이고 "frontier가 안 움직임"만 보고 재시작한다 | `#define LA_DRAIN_TIMEOUT_MSEC 30000`. 조건은 `frontier did not move` | failover 시점에 slave에서 30초 넘게 걸리는 대형 트랜잭션(대량 UPDATE)이 ring head에 있다. frontier가 30초 동안 안 움직이므로 applier가 재시작한다. 재시작하면 committed_lsa부터 다시 적용하므로 같은 트랜잭션이 다시 30초를 넘고, 승격이 무한히 지연된다. "멈춤"과 "느림"을 구분하지 못한다 | 추정(실측 없음) | 신규 |
| E5 | Low | `log_manager.c:7466-7471` | `log_dump_record`가 `LOG_DUMMY_WSET_LABEL`을 모른다 | `default: fprintf (... "log_dump: Unknown record type ...")` | `cubrid diagdb`로 로그를 덤프하면 모든 replicated commit 앞에 "Unknown record type = 53"이 찍힌다. 진단할 때 손상으로 오인할 수 있다. CDC switch(11718)는 `default: break`라 영향이 없다 | 확정 | 신규 |

### 3.2 모듈화

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| M1 | Medium | `locator_sr.c:7978-8073`, `:8737-8788`, `:9035-9051`, `serial.c:1218-1251`, `log_manager.c:3997-4096`, `:4815-4860`, `btree.c:27193-27255`, `replication.c:534-536` | writeset 수집 지점이 서버 모듈 6곳에 직접 박혀 있고 facade가 없다 | unique_pk 분류와 수집 블록이 insert/delete 경로와 update 경로에 따로 있다. `locator_update_index`의 primary-key 예외 수집(9035). serial은 `#if defined (SERVER_MODE)`와 `serial_Cached_btid`에 직접 의존한다. `log_sysop_fallback_reason`은 trace를 위해 replication payload를 `or_unpack_string_nocopy`로 해석한다(4839) | 새 DML 경로(MERGE 변형, 새 인덱스 유형, online index 등)가 생길 때 한 곳이라도 수집을 빠뜨리면 키 누락이 된다. 키 누락은 곧 조용한 순서 위반이다(A4). 로그 매니저가 복제 레코드 포맷을 알게 되어 레이어가 침범된다 | 확정 | 신규 |
| M2 | Medium | `log_applier.c`(11131행), `:7321-7331`, `applier/*.cpp`의 file-static 상태 | 가장 복잡한 coordinator 정책이 거대 파일과 전역 상태에 남아 있고 단위 테스트 밖이다 | 분리된 gate/pending/inflight/queue는 프로세스 싱글턴이다. 반면 `la_coordinator_submit_task`, `la_coordinator_set_commit_dependency`, `la_coordinator_process_sysop_end`, 라벨 holder(`la_wset_label_trid`)는 `la_Info`에 묶여 `log_applier.c`에 있다 | 단위 테스트는 gate의 기계적 동작만 검증한다. E1처럼 master 라벨과 slave 정책 사이의 계약 오류는 어떤 테스트에도 걸리지 않는다. gate 테스트에는 "commit 사이 LSA를 가리키는 라벨" 케이스가 없다 | 확정 | 신규 |
| M3 | Low | `log_manager.c:3999-4029`, `:4752-4770` | replication 항목을 세는 루프가 세 번 반복된다 | 같은 조건(`repl_type == DATA \|\| STATEMENT` && `must_flush == NEED_FLUSH`)의 for 루프가 flush 전, flush 후, abort trace에 각각 있다 | 조건이 바뀔 때 셋 중 하나만 고치면 trace와 판정이 어긋난다(`repl_item_count > 0`이 commit-order 판정에 쓰임) | 확정 | 신규 |
| M4 | Low | `writeset.hpp:40-50`, `test_writeset.cpp:576,682` | history의 내부(map, lock, history_start)가 `extern` 구조체로 노출된다 | `extern LOG_WSET_HISTORY wset_History;`. 테스트가 `wset_History.history_start`에 직접 쓴다 | 캡슐화가 없어 lock 규약(seq_lock → history_lock)을 지키지 않는 접근이 생길 수 있다. 코드에 있는 TODO(history-store 객체화)와 같은 방향이다 | 확정 | 신규 |

### 3.3 아키텍처

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| A1 | High | `log_manager.c:5560-5606`(`logtb_complete_mvcc` → find → append → publish → unlock), `locator_sr.c:13303`, `btree.c:27552`, `:27909` | 설계 전제("충돌 쌍은 publish까지 lock으로 직렬화된다")를 MVCC가 깨고, 이를 지점별 패치로 막고 있다 | complete_mvcc 뒤에는 행이 committed로 보이지만, commit 레코드와 publish는 그 뒤에 온다. 신규 커밋 d1d02b9e4, 79268ae56이 X_LOCK 경로와 unique DELETED 경로에 self-lock 대기를 하나씩 추가했다 | E3처럼 빠진 경로가 이미 있다. 앞으로 MVCC 가시성만으로 진행하는 경로(새 lock-free 검사 등)가 생길 때마다 같은 결함이 재발한다. 회귀 테스트로 잡기 어렵다(타이밍 창) | 구조 확정. 재발 가능성은 추정 | 신규(전제), 창은 기존 |
| A2 | High | `log_manager.c:4033-4072`, `writeset.cpp:1466-1487`, `serial.c:423` | serial/AUTO_INCREMENT/INCR·DECR sysop마다 전역 barrier가 생긴다 | 복제 항목이 있는 `LOG_SYSOP_END_COMMIT`마다 `wset_raise_history_start (&sysop_lsa, ...)`가 `seq_lock` + `wrlock`을 잡는다. 이후 모든 트랜잭션 라벨은 sysop_lsa 이상이 된다 | `cached_num <= 1`(캐시 없는 serial)인 AUTO_INCREMENT 테이블에 INSERT가 몰리면, INSERT마다 sysop이 생기고 그때마다 history floor가 올라간다. slave에서는 거의 commit 순서 직렬 적용과 같아진다. master에서는 commit할 때마다 exclusive lock을 잡아 commit 경로가 직렬화된다. 코드의 TODO(4209행 근처)도 이를 인정한다 | 메커니즘 확정. AUTO_INCREMENT 기본 cached_num과 성능 영향은 추정 | 신규 |
| A3 | High | `CMakeLists.txt:607`, `log_applier.c:8499-8505` | applylogdb 하나를 위해 `MULTI_CONN_TO_A_SERVER`를 제품 전체에 켰다. worker 1개일 때도 새 스레드 구조만 남는다 | `add_definitions(-DMULTI_CONN_TO_A_SERVER)`가 전역이다. 이 매크로를 참조하는 곳은 27개 파일 92곳(error_manager, area_alloc, network_cl, boot_cl, locator 등)이다. `worker_count == 1`도 coordinator + worker 1개로 돈다 | CAS, csql 등 모든 클라이언트 바이너리의 동작과 성능이 바뀐다. 문제가 생겨도 기능을 끄는 방법이 없다. develop의 직렬 applier 경로가 사라져서 기본 설정(worker 1)의 사용자도 새 구조의 위험을 그대로 진다 | 적용 범위 확정. 영향은 추정 | 신규 |
| A4 | High | `log_applier.c:7105-7111` | 항목 적용 오류를 조용히 넘기는 기존 정책 때문에 순서 결함이 곧 조용한 데이터 불일치가 된다 | 주석 "The item is already counted in fail_counter ... committed with the ones that applied". 치명적 오류가 아니면 `error = NO_ERROR` | 병렬 적용에서는 E1·E2·E3·키 수집 누락(M1) 같은 순서 결함이 "unique 위반", "대상 행 없음"으로 나타난다. 하지만 fail_counter만 오르고 트랜잭션은 커밋된다. 불일치를 감지할 장치(복구 구간 밖 제약 오류 즉시 정지, 별도 경보)가 없다 | 확정 | 정책은 기존, 영향 확대는 신규 |
| A5 | Medium | `writeset.cpp:1026-1066`, `:1289-1290`, `:1476-1477`, `:1173` | master commit 경로에 전역 lock이 겹쳐 큰 트랜잭션 하나가 전체 commit을 멈출 수 있다 | find는 `seq_lock` → `rdlock`을 잡은 뒤 seq를 풀고, rdlock 아래에서 키 전부를 probe한다. raise/clear는 `seq_lock`을 쥔 채 `wrlock`을 기다린다. advance는 `seq_lock`을 잡는다 | 키 100만 개짜리 트랜잭션이 rdlock 아래에서 probe하는 동안 serial sysop(A2)이 raise를 시도한다. raise는 seq_lock을 쥐고 wrlock을 기다리고, 그동안 다른 모든 committer는 find와 advance의 seq_lock에서 막힌다. 결과는 master 전체 commit 지연이다. probe는 row lock을 쥔 채 진행되므로 lock 보유 시간도 늘어난다 | lock 순서 확정. 지연 크기는 추정 | 신규 |
| A6 | Medium | `writeset.cpp:520`, `:1242-1259`, `:1304-1309`, `system_parameter.c`(history_size 기본 1,000,000) | history 용량 설계: 트랜잭션별 키 한도와 map 전체 용량이 같은 값이고, 넘치면 map 전체를 지운다 | `tdes->wset_hashes.size () >= wset_History.history_size`. 넘치면 `wset_clear_history_locked`가 map을 통째로 비우고 floor를 prev_commit으로 올린다. eviction이 없다 | 쓰기 키가 많은 부하에서는 map이 주기적으로 꽉 차서 전체 clear가 반복된다. clear 직후 모든 트랜잭션이 직전 commit에 묶이므로 slave 병렬성이 주기적으로 0이 된다. 두 의미를 하나의 파라미터로 조정할 수도 없다 | 확정 | 신규 |
| A7 | Medium | `log_record.hpp:140`, `git show a9a0dc78d:src/transaction/log_applier.c:6336`, `system_parameter.c`(history_size 최소 1) | 로그 포맷 호환: 새 rectype 53을 끌 방법이 없다 | base applier: `lrec->type >= LOG_LARGER_LOGREC_TYPE`(base 값 53) → `ER_LOG_PAGE_CORRUPTED`. master는 replicated commit마다 label을 항상 쓴다 | 새 master와 구 slave가 섞인 구간(롤링 업그레이드 중 failback, 다운그레이드)에서 구 applier가 첫 label에서 corrupted로 멈춘다. writeset 생성을 끄는 파라미터도 없다 | 확정 | 신규 |
| A8 | Medium | `log_applier.c:7603-7615` | ha_mode=replica를 지원하지 않는데 막는 장치가 없다 | TODO "does not handle the replica options. The coordinator sleeps here, so worker results are not collected". `ha_apply_worker_count`는 모드와 무관하게 적용된다 | replica에서 worker를 2개 이상 쓰면 coordinator가 `la_delay_replica`에서 잠든다. 그동안 결과 회수가 멈춰 지연이 설정보다 커지고, time_bound에서 park된 트랜잭션이 남는다 | 확정(TODO 인정) | 신규 |

### 3.4 리팩토링

| ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| R1 | Low | `log_applier.c:872`, `:1005`, `:1251`, `:1262`, `:7509-7531`, `:7655-7656` | coordinator를 trace에서 "reader"라고 부른다 | `"[WSET] reader schedule ..."`, `"reader complete_without_task"`, `"reader retire"` 등. 같은 파일 2626행은 "coordinator required_lsa"라고 쓴다 | 로그 분석 도구와 문서의 용어가 엇갈린다 | 확정 | 신규 |
| R2 | Low | `applier/log_applier_task.hpp:47-49` | 필드 주석이 gate 의미와 반대다 | "the gate waits for the transaction at this LSA to finish". 실제로는 gap-free frontier(LWM) 비교(gate.cpp:260-290 주석 자체가 "finished above the frontier is not a pass") | 유지보수자가 "해당 트랜잭션만 끝나면 통과"로 고칠 위험이 있다 | 확정 | 신규 |
| R3 | Low | `log_applier.c:1426-1460` | 테스트용 crash 주입 훅이 release 경로에 있고 commit마다 `getenv`를 부른다 | `getenv ("CUBRID_HA_TEST_BLOCK_CLASS")`를 commit마다 호출하고, 기본 정지 시간은 60000ms | 운영 환경에 환경변수가 남으면 특정 클래스의 commit이 60초씩 멈춘다. TODO로 인정되어 있다 | 확정 | 신규 |
| R4 | Low | `log_applier.c:1208-1222` | 함수 안 static `last_store_ns`가 applier 재시작 사이에 남는다 | `static UINT64 last_store_ns = 0;` | 숨은 상태라 테스트하기 어렵다. 동작 영향은 거의 없다(첫 저장이 최대 한 interval 늦어질 수 있음) | 확정 | 신규 |

### 3.5 항목별 상세

**E1 — 재시작 floor가 slave gate를 영구 정지시킨다 (Critical)**

```c
/* log_manager.c:1505-1514 */
  {
    const LOG_LSA restart_lsa = log_Gl.hdr.append_lsa;
    wset_raise_history_start (&restart_lsa, "RESTART");
  }
```
```c
/* applier/log_applier_gate.cpp:290 */
  return !LSA_ISNULL (&la_Gate_frontier) && LSA_LE (dep, &la_Gate_frontier);
```

master는 복구가 끝난 뒤 `history_start`를 로그 끝(append_lsa, R)으로 올린다. 재시작 직후에는 map이 비어 있고 `prev_commit_lsa`도 NULL이다. 그래서 `wset_find_dependency_in_range`는 `wset_parent = history_start = R`을 그대로 돌려준다(1032, 1082-1095). R은 commit 레코드의 LSA가 아니고, R 이후 첫 레코드의 시작 위치다.

slave에서 frontier는 ring에 올라간 항목(LOG_COMMIT, 라벨 붙은 SYSOP_END, `complete_without_task`)의 LSA만 가질 수 있다(`la_gate_advance_frontier`). R 이전의 마지막 commit을 c0, R 이후 첫 라벨 commit을 c1이라 하면, c0 < R < c1 사이에 ring 항목이 하나도 없을 때 다음 순서로 멈춘다.

1. c1이 ring에 push된다. dep = R > frontier(c0)이므로 park된다(`la_coordinator_submit_task`, 7420-7426).
2. ring head가 c1 자신이므로 frontier는 c1이 끝나기 전에는 움직이지 않는다. c1은 frontier를 기다리므로 순환 대기가 된다.
3. 이후 commit도 전부 dep ≥ R이라 park된다. ring이 `LA_COMMIT_ORDER_CAPACITY`에 닿으면 `la_coordinator_wait_for_commit_order_slot`이 결과만 회수하며 영원히 돈다. 함수 주석의 "That commit always passes the gate"라는 가정이 여기서 깨진다.
4. 이 상태에서 failover가 오면 `la_change_state`가 DONE을 보류한다. 30초 뒤 drain timeout(E4)으로 재시작하지만 같은 로그를 다시 읽으므로 같은 자리에서 멈춘다. 결과적으로 승격이 막힌다.

발생 조건: R과 c1 사이에 라벨 없는 LOG_COMMIT(복제가 허용되기 전의 쓰기 트랜잭션 등)이 하나라도 있으면 그 항목이 완료되면서 frontier가 R을 넘으므로 정지하지 않는다. 그런 commit이 항상 생기는지는 확인하지 못했다(추정). failover로 승격된 노드는 slave 시절 applier commit이 R 뒤에 쌓이므로 대체로 안전하다. 위험한 경우는 **master가 재시작하고도 master로 남는 경우**다(양 노드 동시 재기동 뒤 같은 노드가 master, slave가 내려가 있는 동안의 master 재기동 등).

근본 원인은 계약 불일치다. master 라벨은 commit LSA일 수도, SYSOP_END LSA일 수도, 복구 끝 LSA일 수도 있다. 반면 slave는 "라벨은 ring에 나타날 지점"이라고 가정한다. SYSOP_END는 `complete_without_task`로 맞췄지만 restart R은 맞추지 않았다. 수정 방향은 두 가지다. (a) slave에서 dep를 "자기 commit_lsa보다 작은 ring 항목 중 최대값"으로 내려서 해석한다. LWM 의미에서 동등하고 가장 국소적인 수정이다. (b) master에서 R 대신 재시작 시 로그에 dummy 지점(라벨 붙은 빈 레코드)을 남겨 slave ring에 올린다. 어느 쪽이든 master 라벨과 slave gate를 잇는 계약 테스트(M2)가 필요하다.

**E2 — 라벨 해석 실패 시 fail-open (Medium)**

`la_get_wset_label`은 `LSA_SET_NULL (dependency_seq)`로 시작하고, `LA_LOG_READ_ALIGN`이나 `LA_LOG_READ_ADVANCE_WHEN_DOESNT_FIT`가 실패하면 그대로 반환한다(4640-4665). 호출부(7817-7818)는 실패 여부를 보지 않고 `la_wset_label_trid`를 설정한다. 그러면 `la_coordinator_set_commit_dependency`가 `has_label = true`, dep = NULL로 판단해 즉시 dispatch한다. 라벨이 아예 없는 commit은 ring tail을 기다리는 안전한 경로(7574-7578)를 타는데, 라벨이 깨진 경우가 오히려 더 위험한 쪽으로 처리되는 셈이다. 해석에 실패하면 오류로 멈추거나 최소한 "라벨 없음"으로 취급해야 한다.

**E3 — FK 경로의 커밋 중 대기 누락 (Medium)**

```c
/* btree.c:30528-30533 (FK 자식 탐색 콜백) */
  switch (satisfy_delete)
    {
    case DELETE_RECORD_DELETED:
    case DELETE_RECORD_SELF_DELETED:
      /* Object is already deleted. It doesn't exist. */
      return NO_ERROR;
```

79268ae56은 unique 검사의 `DELETE_RECORD_DELETED`에 `btree_is_deleter_committing` 대기를 넣었다. 같은 구조인 FK 자식 탐색(부모 DELETE의 RESTRICT 검사)에는 넣지 않았다. d1d02b9e4는 `lock_mode == X_LOCK`인 행 접근에만 inserter 대기를 넣었다. 그런데 자식 INSERT의 부모 존재 확인은 `xbtree_find_unique (..., S_SELECT_WITH_LOCK ...)`, 즉 S_LOCK이고(`btree.c:26250`), 부모 INSERT 행은 per-row X-lock이 없어서 S_LOCK이 즉시 허용된다. 두 경우 모두 publish 전 창에서 상대의 키를 history에서 보지 못한다.

applier는 FK 검사와 RESTRICT 검사를 건너뛴다(`locator_sr.c:4162 if (LOG_CHECK_LOG_APPLIER) continue;`, `:4248`). 그래서 최종 상태는 수렴하고, 이 결함만으로 데이터가 갈라지지는 않는다. 다만 이 사실은 반대로 **REF 키가 무엇을 보장하려는지**를 묻게 한다. slave는 FK 순서를 검사하지도 않고, 수렴에도 필요하지 않다. REF가 지키는 것은 slave 읽기의 일시적 FK 일관성뿐인데, 병렬 적용은 이미 commit prefix가 아닌 상태를 노출한다. REF 수집 비용(FK 행마다 `btree_read_key_type`, `tp_value_cast`, 해시)을 정당화하는 보장을 문서로 정하든지, REF의 범위를 다시 판단하든지 결정이 필요하다(gate.cpp:276-279의 TODO와 연결된다).

**E4 — drain timeout 고정값 (Medium, 추정)**

`LA_DRAIN_TIMEOUT_MSEC 30000`은 컴파일 상수다. 판단 근거는 "frontier가 30초 동안 같다"뿐이다. 진행 중인 worker가 실제로 일하고 있는지(항목 수 증가, busy 플래그)를 보지 않는다. 대형 트랜잭션이 있는 실서비스 failover에서 재시작 루프에 들어갈 수 있다. worker 진행 지표를 함께 보고 시간은 파라미터로 빼는 것을 권한다.

**A1 — 설계 전제와 지점별 패치 (High)**

`log_commit_local`의 순서는 `logtb_complete_mvcc`(행이 committed로 보임) → postpone → `wset_find_dependency_from_history` → `log_append_repl_info_and_commit_log` → `wset_publish_commit_to_history` → `lock_unlock_all`이다. writeset의 정확성은 "충돌하는 상대는 내 publish가 끝날 때까지 lock 때문에 내 키를 건드리지 못한다"에 기대고 있다. 그런데 MVCC는 complete_mvcc 시점부터 lock 없이 가시성을 준다. 이 브랜치는 그 틈을 self-lock 대기로 두 군데(X_LOCK 행 접근, unique 검사 DELETED) 막았고, E3처럼 막지 않은 곳이 남아 있다.

구조적인 대안을 제안한다. (1) `mvcc_table.is_active`가 publish까지 true로 남는 "committing" 상태를 하나 두고, 모든 가시성 판정이 그 상태를 진행 중으로 보게 한다. (2) 반대로 복제가 켜진 서버에서는 complete_mvcc를 commit 레코드 append와 publish 뒤로 옮긴다. (2)는 기존 주석이 설명하는 unique 통계 로깅 순서와 충돌하므로 검토가 필요하다. 어느 쪽이든 "새 가시성 경로가 생길 때마다 대기를 추가해야 한다"는 규칙을 코드 리뷰 체크리스트가 아니라 구조로 보장해야 한다.

**A2 — sysop barrier (High)**

`log_sysop_commit_internal`은 복제 항목이 있는 모든 `LOG_SYSOP_END_COMMIT`을 commit-order로 라벨링하고 `wset_raise_history_start`로 전역 floor를 올린다. serial은 `cached_num <= 1`이면 next value마다 `serial_update_serial_object`로 sysop을 만든다(`serial.c:423`). 코드의 TODO(키 기반 sysop 라벨)가 해결되기 전까지는, AUTO_INCREMENT 위주 부하에서 병렬 적용의 이득이 대부분 사라진다고 봐야 한다. master 쪽에서도 sysop마다 `seq_lock` + `wrlock`을 잡으므로 commit 처리량이 떨어진다. 최소한 성능 측정 문서에 "캐시 없는 serial/AUTO_INCREMENT"를 별도 시나리오로 넣고, 운영 가이드에 serial cache 권장을 명시할 것을 권한다.

**A3 — 전역 빌드 스위치 (High)**

`MULTI_CONN_TO_A_SERVER`는 클라이언트 공통 라이브러리 전반(오류 관리자 thread-local, area allocator, 네트워크 클라이언트, boot, locator, authenticate 등 27개 파일 92곳)의 동작을 바꾼다. 이를 루트 `add_definitions`로 켜면 CAS를 비롯한 모든 클라이언트가 영향을 받는다. 내부 구현은 이 리뷰의 범위 밖이지만, **적용 범위**는 applylogdb의 필요를 넘는다. 게다가 `worker_count == 1`도 coordinator + worker 스레드 구조로 동작하므로 기존 직렬 applier로 돌아갈 길이 없다. 권장: (a) 매크로를 applylogdb에 필요한 대상으로 좁히거나, 전 클라이언트에 대한 회귀 검증 계획을 별도 이슈로 확정한다. (b) worker 1일 때 develop 경로를 유지할지 결정을 문서로 남긴다.

**A4 — 조용한 실패 정책 (High)**

develop에서 이 정책은 "단일 applier는 순서가 정확하다"는 전제 위에 있었다. 병렬 적용에서는 순서 결함의 증상이 바로 이 오류들이다. 복구 구간(`in_recovery_range`) 밖에서 `ER_BTREE_UNIQUE_FAILED`나 대상 행 없음이 나면 즉시 정지하는 모드를 두거나, 최소한 별도 카운터와 `[WSET]` 경보로 분리해야 한다. 그래야 다음 결함이 무성 유실로 묻히지 않는다.

**A5 — master commit 경로의 전역 lock 결합 (Medium)**

lock 순서 자체는 일관되다(seq_lock → history_lock). 문제는 rwlock 아래에서 하는 일의 길이다. `wset_find_dependency_in_range`는 키 수만큼(최대 history_size) probe를 rdlock 아래에서 수행한다. writer(raise, clear)는 seq_lock을 쥔 채 wrlock을 기다리므로, 그동안 모든 committer가 seq_lock에서 막힌다. probe를 rdlock 밖의 TBB accessor 단위로 돌리고 history_start/prev_commit 스냅샷만 잠깐 잡는 구조로 바꾸면 writer와 독립된다. map은 이미 concurrent_hash_map이다.

**A6 — 용량 정책 (Medium)**

`history_size` 하나가 "트랜잭션 하나가 가질 수 있는 키 수"와 "전역 map 크기"를 함께 정한다. map이 차면 eviction 없이 전체 clear를 하고 floor를 올린다. 쓰기가 많은 부하에서는 map 크기만큼 publish될 때마다 병렬성이 0으로 떨어지는 톱니 패턴이 생긴다. 두 파라미터를 분리하고, map은 floor 이하 항목을 점진적으로 버리는 방식(LSA 기반 세대 교체)을 검토할 것을 권한다.

**A7 — 로그 포맷 호환 (Medium)**

새 레코드 타입은 피할 수 없지만 끌 수 있어야 한다. `ha_writeset_history_size`는 최소값이 1이고 label 쓰기에는 조건이 없다. 혼합 버전 HA에서 구 applier가 `ER_LOG_PAGE_CORRUPTED`로 멈추는 것은 로그 손상처럼 보이는 운영 사고다. writeset 생성 on/off 파라미터와 릴리스 노트의 업그레이드 순서 제약을 권한다.

**M1 — 수집 지점 분산 (Medium)**

키 수집 규칙("PK/UNIQUE는 old와 new 모두 WRITE, FK는 parent 도메인 REF")이 locator의 두 경로, serial, update 예외 경로에 같은 판단과 함께 반복된다. `locator_wset_collect_row_keys (tdes, index, old/new recdes, op)` 같은 단일 진입점으로 모으고, serial도 그 진입점을 쓰게 하면 새 DML 경로에서 누락될 위험이 줄어든다. `log_sysop_fallback_reason`의 payload 파싱은 replication 모듈의 헬퍼로 옮기는 것이 레이어에 맞다.

**M2 — coordinator 정책의 테스트 공백 (Medium)**

현재 단위 테스트는 gate, pending, inflight, queue의 기계적 동작과 master history를 각각 검증한다. 둘을 잇는 계약, 즉 "master가 만든 라벨 수열을 slave 정책에 넣으면 정지 없이, 순서를 지키며 모두 적용된다"는 검증이 없다. coordinator 정책(submit, set_commit_dependency, sysop fragment, recovery range)을 `la_Info`와 분리된 순수 상태 기계로 빼면, master 쪽 `wset_*` 호출 결과를 그대로 넣는 계약 테스트를 만들 수 있다. 그런 테스트가 있었다면 E1은 자동으로 잡혔을 것이다.

## 4. 미검증 의심

- **SYSOP_END ≤ committed_lsa일 때 serial 항목 재적용(기존 추정)**: `la_coordinator_process_sysop_end`의 skip 분기(7518-7533)는 fragment 항목을 outer apply list에서 떼어내지 않는다. 재시작 시 s ≤ committed_lsa < c(outer commit)이면, 이미 적용된 serial 값 v1이 outer commit 때 다시 적용된다. 그 사이 다른 fragment가 v2를 적용했다면 serial 값이 v1으로 되돌아갈 수 있다. base(`a9a0dc78d` 6187-6230)도 같은 skip 구조라 기존 동작으로 보인다. 다만 병렬 구조에서는 committed_lsa가 frontier라서 창이 넓어진다. 재현하지 않았다.
- **문자열 키 해시와 trailing space**: `wset_string_hash`는 `lc->mht2str`을 쓰는데, `lang_mht2str_utf8`/`_byte`는 trailing space까지 해시한다. `ignore_trailing_space=yes`에서 unique 인덱스가 'a'와 'a '를 같은 키로 본다면, DELETE 'a'와 INSERT 'a '가 서로 다른 해시가 되어 의존을 놓친다. collation 비교 규칙을 확인하지 못했다.
- **worker의 비치명 오류 뒤 트랜잭션 경계**: `la_worker_run`은 flush 오류와 서버 다운 오류일 때만 멈춘다. `la_commit_transaction`이 다른 오류를 돌려주면 worker는 다음 task를 계속 받는다. 실패한 트랜잭션의 서버 쪽 잔여 상태가 다음 task와 섞이는지는 multi-connection 내부를 봐야 확인할 수 있다(범위 밖).
- **slave worker 간 deadlock과 항목 단위 재시도**: `ER_LK_UNILATERALLY_ABORTED`는 `LA_RETRY_ON_ERROR`에 포함되어 항목 단위로 `continue` 재시도한다(7090-7100). 서버가 트랜잭션 전체를 abort한 뒤 남은 항목만 새 트랜잭션에 적용하면 부분 적용이 될 수 있다. 복구 구간 밖에서 worker 간 deadlock이 실제로 생기는지(비키 자원 경합)는 확인하지 못했다.
- **rwlock writer 기아**: Linux 기본 pthread rwlock은 reader 우선이다. publish(rdlock, seq_lock 없음)가 계속 들어오면 clear/raise가 seq_lock을 쥔 채 오래 기다릴 수 있다(A5와 겹침). 실측하지 않았다.
- **2PC 경로의 조건 차이**: `log_complete_for_2pc`(6383)는 `tdes->is_active_worker_transaction ()`을 검사하지 않고 find와 publish를 호출한다. local commit(5599)과 조건이 다르다. 의도인지 확인하지 못했다.

## 5. 총평

master writeset과 slave gate의 기본 골격은 일관되다. 라벨은 최대 충돌 commit, slave는 gap-free frontier(LWM)로 통과를 판단한다. WRITE/REF slot 분리, 용량 초과와 statement 복제의 commit-order fallback, sysop fragment의 별도 task화, DONE 보류도 같은 원리 위에 있다. 모듈 분리(gate/pending/inflight/queue)와 주석 품질도 PoC 수준을 넘는다.

그러나 10년차 관점에서 머지 전에 막아야 할 것은 계약의 경계다.

1. **E1(Critical)**: master 재시작 floor가 slave ring에 나타나지 않는 LSA라서, 조건이 맞으면 slave가 영구 정지하고 failover까지 막힌다. 라벨 계약("라벨은 slave ring 위의 지점이거나 그 사이 값이다")을 명문화하고 slave에서 해석을 견고하게 해야 한다.
2. **A1/E3(High/Medium)**: 정확성 전제("publish까지 lock으로 직렬화")가 MVCC 가시성 때문에 구조적으로 깨져 있고, 지점별 대기 패치로 메우고 있다. 이미 빠진 경로가 있다. 다음 결함이 생기면 A4(조용한 실패 정책) 때문에 무성 불일치로 나타난다.
3. **A2/A3/A5(High/Medium)**: AUTO_INCREMENT/serial barrier, 제품 전역 `MULTI_CONN_TO_A_SERVER`, master commit 경로의 전역 lock 결합은 기능 결함은 아니지만 성능과 위험 범위를 제품 전체로 넓힌다. 운영 전환 전에 측정과 범위 조정이 필요하다.

권장 순서: E1 수정과 master-slave 계약 테스트(M2) → A4의 불일치 감지 장치 → A1 구조 대안 검토(E3 포함) → A2/A5 성능 측정 → A3 적용 범위 결정 → 나머지 Medium/Low.

등급별 건수: Critical 1 / High 4 / Medium 9 / Low 7 (총 21건)
