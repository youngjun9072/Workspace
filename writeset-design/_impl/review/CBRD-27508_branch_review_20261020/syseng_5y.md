# CBRD-27508 브랜치 리뷰 — 시스템 엔지니어 5년차

## 1. 리뷰어 관점

운영자 입장에서 봤다. 중점은 HA 운영 절차(기동, 정지, switchover, failover, 업그레이드), 설정 파라미터의 기본값과 상호작용, 재시작 후 복구 경로, 로그와 관측성, 자원(메모리, 스레드, 접속, 디스크)이다. 5년차 관점에서는 applylogdb 프로세스 하나에 국한하지 않고 여러 프로세스가 엮이는 곳을 따라갔다. 한 노드의 applylogdb 여러 개, copylogdb, cub_server의 applier 상태 집계, 버전이 다른 노드가 섞인 구간, util_cs의 in-process 재시도가 그런 곳이다.

## 2. 검토 범위와 실제로 읽은 경로

범위는 `git diff a9a0dc78d 0e411f10f`(12 커밋)이고, HEAD는 0e411f10f이다.

- **master 쪽**
  - `writeset.cpp`: 전체(1–1489)
  - `writeset.hpp`, `writeset_types.hpp`, `writeset_history_map.hpp`
  - `log_manager.c` diff 전체: `log_sysop_commit_internal`, `log_append_sysop_end_internal`, `log_append_wset_label_and_sysop_end`, `log_append_wset_label_with_lock`, `log_commit_local`, `log_complete_for_2pc`, `log_dump_record`(7347–7472), `xlog_dump` 루프(7640–7710)
  - `log_tran_table.c`, `log_impl.h`, `log_record.hpp`, `log_append.cpp`, `log_recovery.c`의 diff
  - `serial.c`: `serial_update_serial_object`(1149–1250)
  - `replication.c` diff
  - `locator_sr.c` diff: `locator_wset_collect_fk_ref`, `locator_add_or_remove_index_internal`, `locator_update_index`, `locator_is_inserter_committing`, `locator_lock_and_get_object_internal`, `xlocator_repl_force`
  - `btree.c` diff: `btree_is_deleter_committing`과 그 호출 2곳
  - `system_parameter.{c,h}`, `heartbeat.h`, `error_code.h`, `msg/*/cubrid.msg`
  - `schema_system_catalog_install.cpp` diff
- **slave 쪽**
  - `log_applier.c`: 구조체와 전역(180–700), coordinator 함수군(700–1700), 페이지 캐시(2200–2560), `la_find_required_lsa`, `la_get_ha_apply_max_committed_lsa`, `la_update_ha_apply_max_committed_lsa`, `la_get_last_ha_applied_info`(2790–3360), `la_flush_repl_items`(5885–6070), `la_apply_repl_log`(6967–7140), `la_detach_sysop_fragment`, `la_coordinator_submit_task`, `la_coordinator_process_sysop_end`, `la_coordinator_set_commit_dependency`, `la_coordinator_process_commit`(7250–7660), `la_log_record_process`의 LOG_DUMMY_HA_SERVER_STATE와 LOG_DUMMY_WSET_LABEL 분기(7760–7850), `la_change_state`, `la_log_commit`, `la_check_mem_size`, `la_commit_transaction`(7900–8240), `la_lock_dbname`, `la_unlock_dbname`, `la_init`, `la_shutdown`(8388–8640), `la_remove_archive_logs`(9041–), `la_apply_log_file` 전체(9560–10420)
  - `src/transaction/applier/*`: worker, result_queue, pending, task_queue/inflight/gate의 init
- **기준선 대조**
  - `git show a9a0dc78d:src/transaction/log_applier.c`: `la_apply_repl_log`(5740–5910), dbname lock 호출 위치
  - `git show a9a0dc78d:src/transaction/log_record.hpp`: `LOG_LARGER_LOGREC_TYPE`
- **CS glue**(caller만 봤다)
  - `CMakeLists.txt`, `cs/sa/cubrid CMakeLists`, `work_space.{c,h}`(`ws_get_repl_obj_count`), `file_io.c` diff, `fileio_lock_la_dbname`/`fileio_unlock_la_dbname`(file_io.c:1539–1740, 호출 의미 확인용)
  - `util_cs.c`의 applylogdb 재시도 루프(3540–3590)
  - `server_support.c`: `css_change_ha_server_state`(1590–1660)

---

## 3. 발견 사항

### 3.1 에러

| ID | 등급 | 위치(HEAD) | 내용 | 근거 | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| E1 | High | log_applier.c:9819, 8388–8406 | dbname lock을 기동 시 무조건 잡고, 잡을 때까지 종료 신호를 보지 않고 무한 대기한다 | `error = la_lock_dbname (&la_Info.db_lockf_vdes, ...)`가 main loop 앞에 있다. `la_lock_dbname`은 `while (1) { ... LA_SLEEP (3, 0); }`이다. develop은 적용할 item이 있는 트랜잭션에서만 잡았다(a9a0dc78d:5781) | applylogdb가 둘인 노드(replica, 3노드 이상). 한쪽 applier가 lock을 쥐면 다른 쪽은 main loop에 들어가지 못한다. applier 상태 통지, `_db_ha_apply_info` 갱신, copied archive 삭제가 모두 멈추고, `hb stop`의 SIGTERM에도 끝나지 않는다 | 확정 (archive 누적은 추정) | 신규 |
| E2 | High | log_applier.c:10317–10322, 8419–8440 | role change를 만나면 drain 없이 unlock하고, 그 뒤로는 lock을 다시 잡지 않은 채 계속 적용한다 | `if (la_Info.is_role_changed == true) { ... la_unlock_dbname (..., clear_owner) }`. lock 재획득은 9819 한 곳뿐이다 | switchover 중 replica에서 구 master applier의 in-flight·parked 작업과 to-be-standby 이후 commit이, lock을 넘겨받은 새 master applier의 작업과 동시에 적용된다. 같은 행이면 적용 순서가 뒤집힌다 | 동작은 확정, 데이터 결과는 추정 | 신규 |
| E3 | High | log_record.hpp:140, log_applier.c:7837 | 새 로그 레코드 번호 53이 develop의 `LOG_LARGER_LOGREC_TYPE`(=53)과 같다 | develop은 `LOG_SUPPLEMENTAL_INFO = 52` 다음이 `LOG_LARGER_LOGREC_TYPE`이다. 구 applier는 `lrec->type >= LOG_LARGER_LOGREC_TYPE`이면 `ER_LOG_PAGE_CORRUPTED`를 낸다 | master만 먼저 올리는 rolling upgrade에서 구 slave applier가 첫 commit label에서 손상 판정을 내린다. hb 재기동이 반복되고 복제가 멈춘다 | 확정 | 신규 |
| E4 | High | schema_system_catalog_install.cpp:1096, log_applier.c:3349, 9761 | `_db_ha_apply_info`에 컬럼 2개를 추가했지만 기존 DB 이관 경로가 없다 | 컬럼은 catalog install에만 있고 `upgrade/`에 versioned script가 없다. `SELECT max_committed_lsa_pageid ...`가 실패하면 기동이 실패한다 | 기존 slave DB에 바이너리만 교체하면 applylogdb가 "Failed to initialize _db_ha_apply_info"로 매번 기동에 실패한다 | 확정 | 신규 |
| E5 | High | log_applier.c:8125–8158, 8478–8494 | 메모리 상한을 VSZ로 검사해서 워커가 여럿이면 기본값(500MB)에서 오탐한다 | 코드 주석이 직접 인정한다("can falsely trip ... while idle"). 기본값 보정, 경고, 기동 거부가 모두 없다 | `ha_apply_worker_count=10`만 바꾸면 유휴 상태에서도 `ER_HA_LA_EXCEED_MAX_MEM_SIZE`로 종료하고 hb가 재기동하기를 반복한다. 재기동마다 E7의 직렬 구간이 붙는다 | 확정 (주석 + 코드) | 신규 |
| E6 | Medium | log_applier.c:205, 2311–2324, 4059–4108 | 스레드별 pinned 목록이 256개로 고정이다. 이를 넘긴 fix는 영구 누수된다 | `la_log_copy_fromlog`가 페이지를 넘어갈 때마다 `la_get_page`로 fix만 잡고, 목록이 차면 `assert(false)`와 "stays fixed"만 남긴다 | 16KB log page 기준 수 MB 이상 행(overflow redo 수백 건)을 적용하면 release에서는 해당 buffer가 영구 fix되어 캐시가 계속 늘어난다(최종적으로 E5 종료). debug에서는 abort한다 | 확정 | 신규 |
| E7 | Medium | log_applier.c:777–810, 7378–7408 | 복구 구간 상한이 copied log eof로 뛴다. 재시작하면 backlog 전체를 한 건씩 적용한다 | `bound = max(commit_lsa, log_hdr->eof_lsa)`로 저장한다. 다음 기동에서 그 구간은 `wait_until_retired`로 한 건씩 직렬 처리한다 | backlog가 수 GB일 때 applier가 한 번 재시작(E5, flush error, server down 재시도, 계획 정지)하면 그 backlog 전체가 병렬 없이 적용된다. failover 준비 시간이 늘어난다 | 확정 | 신규 |
| E8 | Medium | log_applier.c:6705, 10326–10356, 8435 | drain backstop(30초 후 재시작)에 도달하지 못한다. failover에는 애초에 해당하지 않는다 | `is_role_changed`를 바로 앞(10317)의 `la_unlock_dbname`이 false로 되돌린다. master가 죽으면 role-change 레코드 자체가 없다 | failover 중 워커 하나가 멈추면 DONE이 무기한 보류된다. 승격하려는 server는 applier DONE을 기다린다(server_support.c:1617). 남는 것은 "holds DONE" 알림 한 줄뿐이다 | 확정 (도달 불가). server 무기한 대기는 추정 | 신규 |
| E9 | Medium | log_applier.c:1414–1460 | 시험용 지연 훅이 release 빌드에 남아 있고, commit마다 `getenv`를 호출한다 | `CUBRID_HA_TEST_BLOCK_CLASS`가 마지막 적용 class와 같으면 `usleep(60s)`. 기동 시 경고가 없다 | 시험 shell 환경이 남은 채 `cubrid hb start`를 하면 해당 테이블 commit마다 워커가 60초 멈추고, 원인 단서는 er_log_debug 한 줄뿐이다 | 확정 | 신규 |
| E10 | Medium | log_applier.c:7600–7615 | replica 모드 지연 옵션과 병렬 적용이 충돌하는데 막는 장치가 없다 | TODO가 직접 인정한다. `la_delay_replica`가 coordinator에서 sleep하는 동안 결과 수거가 멈춘다 | `ha_mode=replica`에서 워커를 2개 이상 두면 `ha_replica_delay`가 설정보다 늘어나고, `time_bound`가 parked 트랜잭션을 남긴 채 멈춘다 | 확정 (TODO), 영향 정도는 추정 | 신규 |
| E11 | Medium | log_tran_table.c:1622, 1706; writeset.cpp:520 | `wset_hashes.clear()`가 vector capacity를 반환하지 않는다 | 트랜잭션 하나에 최대 `history_size`(기본 1M) × 24B ≈ 25MB까지 쌓이고, 그 tdes가 재사용되는 동안 계속 남는다 | 배치 접속 다수가 각자 큰 트랜잭션을 한 번씩 돌리면 cub_server RSS가 tdes 수 × 수십 MB까지 유지된다 | 동작은 확정, 규모는 추정 | 신규 |
| E12 | Medium | locator_sr.c:7768, 8021–8073, 8734–8788; writeset.cpp:536–543 | 키 수집의 기술적 실패(OOM, cast)가 master 사용자 DML의 실패로 이어진다 | 주석이 "Every technical failure is returned to the DML path"라고 명시한다. 대체 경로 `wset_fallback_to_commit_order`가 있는데도 쓰지 않는다 | 메모리 압박 중 vector push가 `bad_alloc`을 내면, develop에서는 성공했을 사용자 INSERT가 `ER_OUT_OF_VIRTUAL_MEMORY`로 실패한다. 복제 부가 정보 때문에 master 가용성이 떨어진다 | 확정 | 신규 |
| E13 | Low | log_applier_pending.cpp:140–155; log_applier_inflight.cpp:66–90 | in-process 재시작 때 SYSOP fragment 슬롯과 item이 누수된다 | `la_pending_clear`는 node만, `la_inflight_init`은 배열만 해제한다. fragment `LA_APPLY`는 `repl_lists`에 속하지 않는다 | util_cs.c:3573–3586이 server down이나 flush error 후 같은 프로세스에서 재시도할 때마다 그 시점의 parked·in-flight fragment가 누수된다 | 확정 | 신규 |
| E14 | Low | log_applier.c:9901–9941 | archive 삭제를 page cache mutex를 쥔 채로 한다 | `la_remove_archive_logs`(archive open과 `fileio_unformat`)가 mutex 구간 안에 있다 | `remove_log_archives_interval=0`이면 여러 archive를 한 번에 지우는데(`INT_MAX`), 그동안 모든 워커의 페이지 fetch가 멈춘다 | 확정 (지연 규모는 추정) | 신규 |

#### 상세

**E1. 기동 시 무조건 잡는 dbname lock**

- lock 파일은 `$CUBRID/var/APPLYLOGDB/<slave db_name>` 하나다. `fileio_lock_la_dbname`(file_io.c:1539–1665)은 파일에 다른 `log_path` 소유자가 적혀 있거나 다른 프로세스가 fcntl lock을 쥐고 있으면 `FILEIO_NOT_LOCKF`를 돌려준다. `la_lock_dbname`(8388–8406)은 이를 3초 간격으로 끝없이 재시도하고, `la_applier_need_shutdown`은 보지 않는다.
- develop은 이 호출이 `la_apply_repl_log`에 있었다(a9a0dc78d:5781). 그래서 standby를 따라가는 applier는 적용할 item이 없으므로 lock 없이 main loop를 돌았다. HEAD는 9819에서 workers를 시작하기 전에 lock을 잡는다.
- 시나리오는 A(active), B(standby), R(replica)이다. R에는 `applylogdb(A)`와 `applylogdb(B)`가 뜬다.
  - A쪽이 먼저 lock을 잡으면, B쪽은 `la_get_last_ha_applied_info` 직후 9819에서 멈춘 채 다음을 하지 않는다.
    - `boot_notify_ha_log_applier_state`를 호출하지 않는다.
    - `_db_ha_apply_info`를 갱신하지 않는다. `cubrid applyinfo`에는 멈춘 값이 보인다.
    - `la_remove_archive_logs`를 돌리지 않는다. B의 copied archive가 R에 쌓인다. copylogdb 쪽에서도 지우는지는 확인하지 못했으므로 디스크 영향은 추정이다.
  - 반대 순서면 A쪽 복제가 B쪽 applier가 DONE을 거쳐 unlock하고 60초 sleep할 때까지 멈춘다.
- 운영 영향: `hb stop`이나 deregister가 보내는 SIGTERM을 이 루프가 받지 않으므로, 프로세스 정리는 SIGKILL에 의존하게 된다.

**E2. role change 후 lock 미재획득, drain 없는 unlock**

- `LOG_DUMMY_HA_SERVER_STATE`(to-be-standby 등)를 읽으면 `is_role_changed = true`가 된다(7799). 같은 반복의 10317에서 `clear_owner=true`로 unlock하고 60초 sleep한다.
- 이 unlock은 `la_coordinator_drain_complete()`를 확인하지 않는다. 이후 같은 applier가 dispatch하는 작업(60초 동안 parked였던 것, to-be-standby 이후 commit)은 lock 없이 적용된다. HEAD에는 9819 말고 `la_lock_dbname` 호출이 없다.
- develop은 다음 적용 트랜잭션에서 `la_lock_dbname`을 다시 불렀으므로, 새 소유자가 있으면 거기서 기다렸다.
- switchover 시나리오(3노드 이상 또는 replica 구성): R에서 lock을 넘겨받은 `applylogdb(B)`가 B의 신규 트랜잭션을 적용하는 동안 `applylogdb(A)`의 워커가 A의 마지막 트랜잭션을 적용할 수 있다. B 위에서는 A의 마지막 트랜잭션이 B의 신규 트랜잭션보다 먼저 반영되어 있으므로, 같은 행이면 R에서만 순서가 뒤집힌다.
- 2노드 master/slave 쌍은 applier가 하나라 해당하지 않는다.

**E3. 로그 레코드 번호 충돌**

- `LOG_DUMMY_WSET_LABEL = 53`(log_record.hpp:140)이다. develop의 `LOG_LARGER_LOGREC_TYPE`은 53이었다(a9a0dc78d:log_record.hpp:140).
- 구 applylogdb의 `la_log_record_process` 말미 검사(7837과 같은 코드)는 type 53을 상한 초과로 보고 `ER_HA_LA_INVALID_REPL_LOG_RECORD`, `ER_LOG_PAGE_CORRUPTED`를 낸다.
- 운영 영향: master를 먼저 올리는 rolling patch가 불가능하다. 반대로 slave를 먼저 올리는 순서는 동작한다. label이 없으면 `la_coordinator_set_commit_dependency`가 직전 commit에 묶어 commit 순서로 내려간다(7551–7590). 업그레이드 순서 제약을 문서나 기동 검사로 강제해야 한다.

**E4. 카탈로그 컬럼 추가에 이관 경로 없음**

- `upgrade/` versioned script 메커니즘(util_sa.c:133 `v%d_to_v%d.sql.enc`)이 있는데 이 브랜치는 script를 추가하지 않았다.
- `la_get_last_ha_applied_info`가 끝에서 `la_get_ha_apply_max_committed_lsa`(3349)를 호출한다. 컬럼이 없으면 이 질의가 실패하고, 9761에서 기동이 실패한다.
- util_cs.c의 재시도 대상(server down, flush error)이 아니므로 프로세스가 종료하고, hb가 재기동하기를 반복한다.

**E5. VSZ 기준 메모리 상한 오탐**

- 주석(8478–8494)이 원인(스레드별 glibc arena 약 64MB VSZ)과 우회책(`ha_apply_max_mem_size` 상향)을 적고 있지만, 코드는 기본값 그대로다.
- `ha_apply_worker_count`의 범위만 1–32로 열어 두었다. 워커를 늘리는 설정만 바꾼 운영자는 유휴 상태에서도 재기동 루프를 만난다.
- 최소한 다음 셋 중 하나가 필요하다.
  - 기동 시 `worker_count × 64MB`와 `max_mem_size`를 비교해 경고한다.
  - `start_vsize`를 워커 시작 뒤에 측정한다.
  - RSS 기반으로 바꾼다.

**E6. pinned 목록 256 고정**

- 워커는 item 하나를 끝낼 때(7010), coordinator는 레코드 하나를 끝낼 때 `la_release_pinned_page_buffers`로 모아서 해제한다.
- 그 사이 `LA_LOG_READ_ADVANCE_WHEN_DOESNT_FIT`과 `la_log_copy_fromlog`가 다음 페이지를 fix한다. `la_get_overflow_recdes`는 레코드 시작 페이지만 pageid로 해제하고(5401, 5459), 레코드 안에서 넘어간 페이지의 fix는 item 끝까지 남는다. 큰 overflow 행은 이 fix가 256개를 넘긴다.
- release 빌드에서는 넘친 fix가 목록에 없어 영원히 해제되지 않는다. `la_cache_buffer_replace`는 fix된 buffer를 건너뛰므로 `la_expand_cache_log_buffer`로 캐시만 늘린다.
- develop의 `la_release_all_page_buffers`는 전체 buffer를 훑어 해제했으므로 개수 제한이 없었다.

**E7. 복구 구간 상한이 eof로 뜀**

- 설계 의도는 저장 횟수를 줄이는 것이다(주석 777–786). 대가는 재시작 후 [`last_committed_lsa`, 당시 eof] 전체를 직렬로 적용하는 것이다(7378–7408).
- 운영상 재시작이 잦은 경로(E5, flush error 재접속, util_cs 재시도, 계획 정지)가 모두 이 대가를 치른다.
- 상한을 "dispatch한 최대 commit + 여유"로 묶으면 재시작 비용이 현재 in-flight 폭으로 줄어든다. 대신 저장 횟수가 늘어나는데, 이것은 A5와 맞물린다.

**E8. drain backstop 도달 불가**

- 10329의 조건 `la_Info.is_role_changed == true`는 바로 앞 10317–10322의 `la_unlock_dbname`이 성공하면(8435) 항상 false가 된다. unlock 실패 시에만 참이 남는다.
- failover(master 사망)에서는 role-change 레코드가 쓰이지 않으므로 `is_role_changed`가 아예 서지 않는다.
- 결과적으로 `la_change_state`가 DONE을 보류(7956–7972)하는 동안 워커가 영구히 멈추면 시간 상한이 없다. 이 30초도 상수(6705)라 운영에서 조정할 수 없다.

**E9. release 빌드의 시험 훅**

- TODO(1424–1429)가 제거 대상이라고 적고 있다. 출고 빌드에 환경 변수 하나로 장애를 재현할 수 있는 지연이 남는다.
- 정지하는 순간의 로그는 `_er_log_debug` 한 줄(`ws_marker TEST block ...`)뿐이다.

**E10. replica 모드 미지원**

- TODO가 명시한다.
- `ha_mode=replica`이면서 `worker_count > 1`인 조합을 `la_init`(8499 부근)에서 거부하거나 1로 강제해야 운영 사고를 막을 수 있다.

**E11. 트랜잭션별 키 벡터 capacity 잔존**

- `wset_fallback_to_commit_order`만 `swap`으로 반환하고(writeset.cpp:559), 정상 종료는 `clear()`만 한다(log_tran_table.c:1622).
- 한도 바로 아래까지 키를 모은 tdes는 수십 MB를 계속 쥔다. `shrink_to_fit`이나 상한을 넘은 경우의 `swap`이 필요하다.

**E12. 키 수집 실패가 사용자 DML 실패로 이어짐**

- 실패 경로: `wset_push_hash`의 `bad_alloc`(536–543), `wset_add_write_key`와 `wset_add_ref_key`의 `malloc` 실패, `wset_cast_value_to_domain` 실패. 모두 `goto error`로 사용자 DML을 실패시킨다.
- 의도("키를 조용히 빠뜨리지 않는다")는 맞다. 다만 `wset_fallback_to_commit_order`는 키를 빠뜨리지 않고도 안전한 대안이다. 운영 관점에서는 복제 보조 정보 때문에 master 트랜잭션이 실패하는 것보다 commit 순서로 내려가는 편이 낫다.

**E13. in-process 재시작 시 fragment 누수**

- util_cs.c는 server down 계열 오류나 `ER_LC_PARTIALLY_FAILED_TO_FLUSH` 이후 같은 프로세스에서 `la_apply_log_file`을 다시 호출한다(3573–3586).
- `la_shutdown`(8541–)은 `repl_lists`만 해제한다. pending, in-flight, task queue에 있던 `LOG_SYSOP_END` fragment(`la_detach_sysop_fragment`가 `malloc`한 것, 7269)와 그 item은 해제하지 않는다.

**E14. mutex 안의 archive 삭제**

- header refresh를 mutex 안으로 넣은 이유(470309f59 주석, 9897–9900)는 타당하다. 그러나 archive 삭제와 `la_find_archive_num`의 archive open은 header 스냅샷만 있으면 mutex 밖에서 할 수 있다.

### 3.2 모듈화

| ID | 등급 | 위치 | 내용 | 근거 | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| M1 | Medium | writeset.cpp:520, 1221–1236, 1344–1366; system_parameter.c:5673 | `ha_writeset_history_size` 하나가 트랜잭션별 키 상한과 history map 용량을 겸한다 | `tdes->wset_hashes.size () >= history_size`와 `map.size () + reserved <= history_size`가 같은 값을 쓴다. overflow된 commit은 map 전체를 exclusive lock으로 비운다 | 메모리를 아끼려고 값을 10만으로 낮추면, 키 10만 개를 넘는 트랜잭션마다 commit 시점에 map 전체를 clear한다. 그때마다 `history_start`가 올라가고 slave는 그 지점까지 직렬화된다 | 확정 | 신규 |
| M2 | Low | log_applier.c:2442–2470 외 다수, applier/*.cpp | 같은 파일 안 로그 태그가 제각각이다 | `[WSET]`, `ws_repl`, `ws_worker`, `ws_marker`, `ws_lsaguard`, `reader ...`가 섞여 있다 | 장애 분석 때 grep 한 번으로 applier 흐름을 모을 수 없다 | 확정 | 신규 |

#### 상세

**M1.** 의미가 다른 두 한도를 분리해야 한다. 예를 들면 `ha_writeset_tran_key_limit`와 `ha_writeset_history_size`로 나눈다. overflow commit도 `wset_raise_history_start`처럼 floor만 올리면 map을 비울 필요가 없다. 이 판단은 코드상으로는 가능하지만 정합성 검증은 하지 않았다.

### 3.3 아키텍처

| ID | 등급 | 위치 | 내용 | 근거 | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| A1 | Medium | serial.c:1205–1250; log_manager.c:4048–4071; writeset.cpp:1467–1488 | AUTO_INCREMENT와 serial을 갱신할 때마다 history_lock을 exclusive로 잡고, slave에서는 commit 순서로 묶인다 | `repl_item_count > 0`인 SYSOP_END마다 `wset_raise_history_start`가 `seq_lock`과 `wrlock`을 잡는다. 이후 모든 label이 그 위치 아래로 내려가지 못한다 | 캐시 없는 AUTO_INCREMENT PK에 INSERT가 몰리는 OLTP에서 master는 commit 경로가 직렬화되고, slave 병렬도는 거의 1이 된다 | 확정 (TODO 4045–4051이 인정). 정량 영향은 추정 | 신규 |
| A2 | Medium | log_applier.c:8499–8505; writeset 수집 경로 | 끄는 스위치가 없다. `worker_count=1`도 새 coordinator·worker 구조로 돌고, master 키 수집은 HA이면 항상 켜진다 | `worker_count == 1`일 때 알림만 남기고 같은 경로를 탄다. master 쪽 활성화 조건은 `log_does_allow_replication()`뿐이다 | 신규 경로에서 결함이 나도 설정으로 develop 방식으로 되돌릴 수 없다. 바이너리를 되돌리는 것도 E4(카탈로그)와 미적용 로그 처리 때문에 간단하지 않다 | 확정 | 신규 |
| A3 | Medium | writeset.cpp:69, 52–66; log_applier.c:319, 1189 | 운영 지표가 노출되지 않는다 | `wset_Statistics`(overflow, clear, fallback, publish)에 "TODO expose"가 붙어 있다. `recovery_skipped_counter`는 누적만 하고 저장도 출력도 하지 않는다(grep 결과 3곳) | 병렬도가 무너지거나(fallback, clear 급증) 재시작 후 재적용 오류를 삼킨 건수를 trace를 켜지 않고는 알 수 없다. trace 레벨은 동적이 아니어서 켜려면 재시작해야 한다 | 확정 | 신규 |
| A4 | Low | system_parameter.c:5684–5694; writeset.cpp:96–103; log_manager.c:242–260 | trace가 운영 로그 체계를 우회한다 | `_er_log_debug`를 직접 호출해 `er_log_debug` 파라미터와 무관하게 전역 mutex와 `fflush`로 줄마다 쓴다. 레벨 1에서도 slave는 트랜잭션당 약 5줄, master는 2줄을 쓴다. 레벨 3은 history exclusive lock 안에서도 쓴다(`wset_publish_keys`, 1151). `PRM_CLEAR_DYNAMIC_FLAG`라 재시작이 필요하다 | 장애 진단 차 레벨 3을 켜면 master commit 경로가 로그 I/O에 직렬화된다 | 확정 | 신규 |
| A5 | Medium | log_applier.c:787–810 | catch-up 상태에서 새 commit 묶음마다 coordinator가 동기 UPDATE+COMMIT을 한다 | 직전 상한이 당시 eof였으므로 새로 읽은 commit은 항상 그보다 크다 → `la_update_ha_apply_max_committed_lsa` → `db_commit_transaction()` | 지연이 거의 없는 정상 운영에서 copylogdb flush 단위마다 slave에 commit이 하나 더 생기고, 그 commit이 dispatch 앞을 막는다 | 동작은 확정, 빈도와 지연 규모는 추정 | 신규 |
| A6 | Low | log_manager.c:7347–7472 | `log_dump_record`에 label 분기가 없다 | default로 빠져 "Unknown record type = 53"을 출력한다 | `cubrid diagdb`로 로그를 덤프하면 commit마다 Unknown 줄이 섞여 장애 분석을 오도한다 | 확정 | 신규 |

#### 상세

**A1.** 코드가 제약을 인정하고 보류해 두었다(log_manager.c:4045–4051). 운영 문서에는 "AUTO_INCREMENT(cache 없음)와 serial을 많이 쓰는 워크로드에서는 병렬 이득이 거의 없다"는 제약을 적어야 하고, 출시 기준에도 넣어야 한다. serial cache를 쓰면 영향이 줄어든다. cache가 다시 채워질 때만 sysop이 생긴다고 보지만, 이 부분은 추정이다.

**A2.** 최소한 다음이 필요하다.
- master: HA여도 키 수집과 label을 끌 수 있는 파라미터. 끄면 label이 없으므로 slave는 commit 순서로 동작한다.
- slave: `worker_count=1`이면 develop과 동등한 경로임을 시험으로 보증한다.

### 3.4 리팩토링

| ID | 등급 | 위치 | 내용 | 근거 | 실패 시나리오 | 확정/추정 | 신규/기존 |
|---|---|---|---|---|---|---|---|
| R1 | Low | log_applier.c:9590, 870–876, 1247–1260, 7815–7829 등 | coordinator를 로그에서 "reader"로 적는다 | `"applylogdb reader exit"`, `"[WSET] reader schedule/retire/commit/label"` | 운영 문서와 코드 용어가 어긋난다. coordinator로 통일해야 한다 | 확정 | 신규 |
| R2 | Low | log_applier_pending.cpp:85–120; log_applier.c:714–724 | parked 목록에서 꺼낼 때마다 선형 탐색하고, `drain_ready`가 이를 반복한다 | 최대 parked 수는 `worker_count × 1024`(최대 32768)이다 | 직렬화 의존이 긴 backlog에서 coordinator 루프 한 번마다 수만 개 노드를 훑어 coordinator CPU가 병목이 될 수 있다 | 추정 | 신규 |
| R3 | Low | log_applier.c:6705 | `LA_DRAIN_TIMEOUT_MSEC`가 상수다 | `#define LA_DRAIN_TIMEOUT_MSEC 30000` | E8을 고친 뒤에도 긴 단일 트랜잭션(수 분짜리 배치)을 정상적으로 적용하는 중에 오판할 수 있다. 파라미터화와 "frontier 정지"·"워커 진행 없음"의 구분이 필요하다 | 추정 | 신규 |

---

## 4. 미검증 의심 (근거 부족)

1. **slave 접속 수 증가**: applier 하나가 `worker_count + 1`개의 접속을 쓴다(`db_restart_sub`, worker.cpp:152). replica처럼 applier가 여럿이면 `(worker + 1) × peer 수`가 된다. 이 접속이 cub_server의 `max_clients`에 들어가는지, HA 내부 client로 예약되는지는 확인하지 못했다. 들어간다면 `ha_apply_worker_count=32`에서 사용자 접속 한도를 잠식한다.
2. **`btree_is_deleter_committing`의 비용**(btree.c:27208–27225): unique 검사 중 vacuum되지 않은 삭제 버전마다 조건부 mvccid lock 요청이 1회 생긴다. vacuum이 밀린 상태에서 같은 키를 반복 DELETE·INSERT하는 패턴이면 lock manager 부하가 커질 수 있다. 측정하지 않았다.
3. **E1의 디스크 영향**: copylogdb가 copied archive를 스스로 지우는지(`ha_copy_log_max_archives` 등) 확인하지 못했다. 스스로 지우지 않으면 applier가 멈춘 쪽 peer의 archive가 무한히 쌓인다.
4. **E8의 server 쪽 대기 상한**: 승격 중인 cub_server가 applier DONE을 기다리는 데 시간 상한이 있는지(heartbeat 쪽 timeout 포함) 확인하지 못했다.
5. **재시작 구간의 statement 복제 재적용**: TODO(6964). 행 단위가 아닌 statement 복제 DML 가운데 멱등이 아닌 것(예: `c = c + 1`)이 복구 구간에서 두 번 적용될 수 있다. 실제로 그런 statement가 복제되는 경로(checksumdb 외)가 있는지 확인하지 못했다.
6. **`la_applier_need_shutdown`이 일반 `bool`이다**(log_applier.c:445). 워커 콜백이 쓰고 coordinator가 읽는다. 기존 관행과 같지만 C++ 메모리 모델상 data race다. 실제 증상으로 이어지는지는 판단하지 않았다.

## 5. 총평

master writeset(키 수집, label, history)과 slave의 coordinator·worker·gate 구조는 의도가 주석에 잘 남아 있다. 한 트랜잭션 안의 정합성, 재시작 직렬 구간, DONE 보류처럼 정확성을 지키는 장치도 대부분 갖춰져 있다.

다만 운영 관점에서는 출시 전에 막아야 할 것이 네 가지 있다.

1. **업그레이드 경로가 막혀 있다.** E3(레코드 번호 53이 구 상한과 충돌)과 E4(카탈로그 컬럼 이관 없음) 때문에 master 우선 rolling patch도, 기존 DB에 바이너리만 교체하는 것도 실패한다.
2. **dbname lock 의미가 develop과 달라졌다.** E1과 E2 때문에 replica나 3노드 이상 구성에서 applier 하나가 기동 단계에서 멈추거나, switchover 때 두 applier가 lock 없이 겹쳐 적용할 수 있다. 2노드만으로 시험하면 드러나지 않는 유형이다.
3. **기본 설정 그대로 기능을 켜면 재시작 루프에 빠진다.** E5의 VSZ 오탐이 E7(재시작마다 backlog 직렬 재적용)과 E6(대형 행의 fix 누수)과 맞물려, 워커 수만 올린 운영자가 "지연이 줄지 않고 applier가 계속 재기동하는" 상태를 보게 된다.
4. **failover 안전장치와 관측성이 비어 있다.** E8의 drain backstop은 실제로 도달하지 않고, A3대로 병렬도 붕괴나 삼킨 오류 건수를 볼 지표가 없다. 끄는 스위치(A2)도 없어 문제가 나면 바이너리를 되돌리는 것밖에 없는데, 그 길은 1번이 막는다.

A1(AUTO_INCREMENT와 serial의 commit 순서 강제)은 결함이라기보다 기능의 적용 한계다. 운영 문서와 성능 기대치에 명시해야 한다. E9(release 시험 훅)과 E10(replica 미지원)은 코드가 TODO로 인정한 것이므로, 설정 검사로 조합을 막는 것이 가장 싸다.

건수: Critical 0 / High 5 / Medium 12 / Low 8 (E·M·A·R 합계 25건, 미검증 6건 별도).
