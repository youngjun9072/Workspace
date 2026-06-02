# update on-CPU 콜체인 — config 병렬 PoC (2026-06-01)

`cub_server testdb` 단일 프로세스 on-CPU 캡처 (`-F 999`, dwarf call-graph) 에서
`locator_update_force` 를 root 로 한 콜체인. **funcset 제한 없이** script 에 등장한
모든 심볼이 후보 (커널 `[unknown]` 프레임만 제외).

> **root 선정 사유**: 이 캡처는 복제 적용(replication apply) 경로라 클라이언트 SQL UPDATE 엔트리
> `qexec_execute_update` 는 거의 부재(68 frame). 실제 hot path 인
> `slocator_repl_force`→`xlocator_repl_force`→**`locator_update_force`**→`heap_update_logical`
> 의 write 진입점 `locator_update_force` 를 root 로 잡았다. (master-update-v2 의 `qexec_execute_update`
> 함수셋과는 경로가 달라 그대로는 빈 트리가 됨)

## 캡처 정보

| 항목 | 값 |
|---|---|
| 디렉토리 | `20260601-203730-cubserver-oncpu-config-parallel-poc-update/` |
| 전체 sample | 126,337 (symbol 파싱된 stack) |
| `locator_update_force` 포함 sample | **29,001 (전체의 22.96%)** = 콜트리 분모 |
| 콜체인 함수 수 | **401개** (root 경로 inclusive) |
| 진입 경로 | `xlocator_repl_force` → `locator_update_force` (복제 적용) |

> ※ 노드 % = root 포함 sample 대비 inclusive 비율 (insert MD 와 동일 규칙).

## 설정

| 항목 | 값 |
|---|---|
| `double_write_buffer_size` | `0` |
| `data_buffer_size` | `5G` |
| `log_buffer_size` | `5G` |
| `log_volume_size` | `1G` |
| `checkpoint_interval` | `30min` |
| `csql>` | `checkpoint` 수행 |
| `addvoldb` | `100G` |
| `addvoldb` | `temp` |

## 상위 inclusive 함수 (top 24 / 401)

| % of root | samples | 함수 | 의미 |
|---:|---:|---|---|
| 100.00 | 29,001 | `locator_update_force` | update force (root) |
| 71.58 | 20,759 | `heap_update_logical` | heap update |
| 47.34 | 13,729 | `heap_log_update_physical` | heap 물리 로깅 |
| 45.46 | 13,183 | `log_append_undoredo_recdes` | **undo/redo 로그 append (recdes)** |
| 45.27 | 13,129 | `log_append_undoredo_recdes2` | 〃 |
| 45.15 | 13,094 | `log_append_undoredo_crumbs` | undo/redo 로그 append (crumbs) |
| 39.15 | 11,353 | `prior_lsa_alloc_and_copy_crumbs` | **prior LSA 레코드 생성** |
| 31.68 | 9,188 | `prior_lsa_gen_undoredo_record_from_crumbs` | prior LSA 레코드 조립 |
| 23.34 | 6,769 | `log_diff` | redo diff 계산 |
| 23.02 | 6,675 | `locator_lock_and_get_object_with_evaluation` | 대상 row lock+get |
| 19.54 | 5,666 | `heap_update_home` | home 레코드 갱신 |
| 19.36 | 5,614 | `locator_lock_and_get_object_internal` | lock+get 내부 |
| 17.70 | 5,132 | `__memmove_evex_unaligned_erms` | memmove |
| 15.11 | 4,382 | `spage_update` | slotted page update |
| 13.01 | 3,773 | `spage_update_record_after_compact` | compact 후 갱신 |
| 11.83 | 3,430 | `lock_object` | 오브젝트 lock |
| 11.18 | 3,241 | `lock_internal_perform_lock_object` | lock 수행 |
| 8.49 | 2,462 | `spage_compact` | 페이지 compaction |
| 8.47 | 2,455 | `lock_escalate_if_needed` | lock escalation |
| 8.31 | 2,410 | `lock_remove_all_inst_locks` | inst lock 해제 |
| 7.27 | 2,108 | `log_zip` | 로그 압축 |
| 6.96 | 2,018 | `heap_get_last_version` | 최신 버전 조회 |
| 6.52 | 1,892 | `spage_get_record_data` | 레코드 read |
| 6.01 | 1,743 | `heap_get_record_data_when_all_ready` | 레코드 read |

전체 401개 함수는 아래 §"전체 함수 inclusive 표" 참고.

## 관찰 (update) + insert 대비

- update 무게중심은 **로그 경로**: `heap_update_logical`(71.6%)→`heap_log_update_physical`(47.3%)→`log_append_undoredo_recdes(2)`(45%)→`log_append_undoredo_crumbs`(45%)→`prior_lsa_alloc_and_copy_crumbs`(39%). insert(`log_append_undoredo_crumbs` 27.8%)보다 **로그 append 비중이 확연히 큼**.
- `log_diff`(23.3%) 가 update 에서만 큼 — 갱신 전후 diff 로 redo 를 줄이는 경로. insert 엔 없음.
- 대상 행 확보: `locator_lock_and_get_object_with_evaluation`(23%) + `lock_escalate_if_needed`/`lock_remove_all_inst_locks`(~8%) → update 는 **기존 row lock+escalation** 부담이 별도로 존재.
- 페이지 갱신: `spage_update`→`spage_update_record_after_compact`→`spage_compact` (가변길이 레코드 compaction) 경로가 insert 의 `spage_insert_at` 자리를 대체.
- 공통: `prior_lsa_*` + malloc 체인은 insert·update 양쪽 모두 두꺼움 (로그 레코드 생성 비용).

---
## 콜트리 (locator_update_force = 100%, 노드컷 0.1%, MIN_EDGE 30)

```
# locator_update_force 콜체인 (ROOT 포함 sample 만, ROOT = 100%)
# root_samples = 29001  (total_samples = 126337)
# 노드 컷 = 0.1% of root, MIN_EDGE = 30

[100.00%] locator_update_force
    ├─ [ 71.58%] heap_update_logical
    │   ├─ [ 47.34%] heap_log_update_physical
    │   │   ├─ [ 45.46%] log_append_undoredo_recdes
    │   │   │   ├─ [ 45.27%] log_append_undoredo_recdes2
    │   │   │   │   └─ [ 45.15%] log_append_undoredo_crumbs
    │   │   │   │       ├─ [ 39.15%] prior_lsa_alloc_and_copy_crumbs
    │   │   │   │       │   ├─ [ 31.68%] prior_lsa_gen_undoredo_record_from_crumbs
    │   │   │   │       │   │   ├─ [ 23.34%] log_diff
    │   │   │   │       │   │   ├─ [  7.27%] log_zip
    │   │   │   │       │   │   │   ├─ [  5.69%] LZ4_resetStream_fast
    │   │   │   │       │   │   │   │   └─ [  5.24%] __memset_evex_unaligned_erms
    │   │   │   │       │   │   │   ├─ [  0.33%] __tls_get_addr
    │   │   │   │       │   │   │   ├─ [  0.14%] log_zip_realloc_if_needed
    │   │   │   │       │   │   │   ├─ [  0.11%] LZ4_compress_fast_extState@plt
    │   │   │   │       │   │   │   ├─ [  0.11%] LZ4_compressBound
    │   │   │   │       │   │   │   └─ [  0.11%] log_zip_realloc_if_needed@plt
    │   │   │   │       │   │   ├─ [ 17.70%] __memmove_evex_unaligned_erms
    │   │   │   │       │   │   ├─ [  4.97%] cub_alloc
    │   │   │   │       │   │   │   └─ [  5.40%] __GI___libc_malloc
    │   │   │   │       │   │   │       └─ [  3.77%] _int_malloc
    │   │   │   │       │   │   │           └─ [  1.01%] unlink_chunk.isra.2
    │   │   │   │       │   │   └─ [  0.36%] LOG_FIND_CURRENT_TDES
    │   │   │   │       │   │       └─ [  1.34%] LOG_FIND_TDES
    │   │   │   │       │   ├─ [  7.27%] log_zip
    │   │   │   │       │   │   ├─ [  5.69%] LZ4_resetStream_fast
    │   │   │   │       │   │   │   └─ [  5.24%] __memset_evex_unaligned_erms
    │   │   │   │       │   │   ├─ [  0.33%] __tls_get_addr
    │   │   │   │       │   │   ├─ [  0.14%] log_zip_realloc_if_needed
    │   │   │   │       │   │   ├─ [  0.11%] LZ4_compress_fast_extState@plt
    │   │   │   │       │   │   ├─ [  0.11%] LZ4_compressBound
    │   │   │   │       │   │   └─ [  0.11%] log_zip_realloc_if_needed@plt
    │   │   │   │       │   ├─ [  4.97%] cub_alloc
    │   │   │   │       │   │   └─ [  5.40%] __GI___libc_malloc
    │   │   │   │       │   │       └─ [  3.77%] _int_malloc
    │   │   │   │       │   │           └─ [  1.01%] unlink_chunk.isra.2
    │   │   │   │       │   ├─ [  1.20%] prior_lsa_copy_undo_data_to_node
    │   │   │   │       │   │   ├─ [  4.97%] cub_alloc
    │   │   │   │       │   │   │   └─ [  5.40%] __GI___libc_malloc
    │   │   │   │       │   │   │       └─ [  3.77%] _int_malloc
    │   │   │   │       │   │   │           └─ [  1.01%] unlink_chunk.isra.2
    │   │   │   │       │   │   └─ [ 17.70%] __memmove_evex_unaligned_erms
    │   │   │   │       │   ├─ [  1.19%] prior_lsa_copy_redo_data_to_node
    │   │   │   │       │   │   └─ [  4.97%] cub_alloc
    │   │   │   │       │   │       └─ [  5.40%] __GI___libc_malloc
    │   │   │   │       │   │           └─ [  3.77%] _int_malloc
    │   │   │   │       │   │               └─ [  1.01%] unlink_chunk.isra.2
    │   │   │   │       │   └─ [  0.22%] log_zip@plt
    │   │   │   │       ├─ [  3.49%] prior_lsa_next_record_internal
    │   │   │   │       │   ├─ [  2.59%] __GI___pthread_mutex_lock
    │   │   │   │       │   │   └─ [  0.25%] __lll_lock_wait
    │   │   │   │       │   ├─ [  2.24%] __pthread_mutex_unlock_usercnt
    │   │   │   │       │   │   └─ [  0.25%] __lll_unlock_wake
    │   │   │   │       │   ├─ [  0.35%] vacuum_get_log_blockid
    │   │   │   │       │   ├─ [  0.23%] prior_lsa_append_data
    │   │   │   │       │   └─ [  0.14%] prior_lsa_start_append
    │   │   │   │       ├─ [  1.12%] pgbuf_set_lsa
    │   │   │   │       │   ├─ [  0.75%] fileio_set_page_lsa
    │   │   │   │       │   │   └─ [  0.78%] LSA_COPY
    │   │   │   │       │   └─ [  0.29%] pgbuf_set_dirty_buffer_ptr
    │   │   │   │       ├─ [  0.27%] pgbuf_is_lsa_temporary
    │   │   │   │       │   └─ [  0.28%] xdisk_get_purpose
    │   │   │   │       ├─ [  0.18%] log_can_skip_undo_logging
    │   │   │   │       │   └─ [  0.12%] log_tdes::is_system_worker_transaction@plt
    │   │   │   │       └─ [  0.24%] logtb_find_client_type
    │   │   │   │           └─ [  1.34%] LOG_FIND_TDES
    │   │   │   └─ [  0.14%] log_append_undoredo_recdes2@plt
    │   │   ├─ [  1.18%] heap_page_update_chain_after_mvcc_op
    │   │   │   └─ [  0.52%] spage_get_record
    │   │   │       └─ [  0.48%] spage_find_slot
    │   │   │           └─ [  0.13%] spage_is_unknown_slot
    │   │   ├─ [  0.32%] heap_page_get_vacuum_status
    │   │   │   └─ [  0.52%] spage_get_record
    │   │   │       └─ [  0.48%] spage_find_slot
    │   │   │           └─ [  0.13%] spage_is_unknown_slot
    │   │   └─ [  0.11%] log_append_undoredo_recdes@plt
    │   ├─ [ 19.54%] heap_update_home
    │   │   ├─ [  2.75%] spage_is_updatable
    │   │   │   └─ [  4.16%] spage_check_updatable
    │   │   │       ├─ [  3.75%] spage_has_enough_total_space
    │   │   │       │   ├─ [  2.97%] spage_get_total_saved_spaces
    │   │   │       │   │   └─ [  2.74%] spage_get_saved_spaces
    │   │   │       │   │       └─ [  2.24%] lf_hash_find
    │   │   │       │   │           ├─ [  1.35%] lf_list_find
    │   │   │       │   │           │   ├─ [  0.19%] lf_tran_end@plt
    │   │   │       │   │           │   └─ [  0.53%] lf_tran_start
    │   │   │       │   │           │       └─ [  0.17%] ATOMIC_INC_64<unsigned long, int>
    │   │   │       │   │           └─ [  0.30%] lf_callback_vpid_hash
    │   │   │       │   ├─ [  0.52%] logtb_find_tranid
    │   │   │       │   │   └─ [  1.34%] LOG_FIND_TDES
    │   │   │       │   ├─ [  0.24%] logtb_find_current_tranid@plt
    │   │   │       │   ├─ [  0.18%] logtb_is_active
    │   │   │       │   └─ [  0.19%] log_is_in_crash_recovery
    │   │   │       └─ [  0.48%] spage_find_slot
    │   │   │           └─ [  0.13%] spage_is_unknown_slot
    │   │   ├─ [  0.68%] heap_update_set_prev_version
    │   │   │   ├─ [  0.22%] spage_get_record@plt
    │   │   │   └─ [  0.16%] or_mvcc_set_log_lsa_to_record
    │   │   ├─ [  0.25%] heap_update_physical
    │   │   │   └─ [  0.23%] spage_get_record_type
    │   │   └─ [  0.11%] spage_is_updatable@plt
    │   ├─ [ 15.11%] spage_update
    │   │   ├─ [ 13.01%] spage_update_record_after_compact
    │   │   │   ├─ [  8.49%] spage_compact
    │   │   │   │   ├─ [ 17.70%] __memmove_evex_unaligned_erms
    │   │   │   │   ├─ [  0.86%] cub_calloc
    │   │   │   │   │   └─ [  0.79%] __calloc
    │   │   │   │   │       └─ [  3.77%] _int_malloc
    │   │   │   │   │           └─ [  1.01%] unlink_chunk.isra.2
    │   │   │   │   └─ [  0.71%] __GI___qsort_r
    │   │   │   │       └─ [  0.57%] msort_with_tmp.part.0
    │   │   │   └─ [ 17.70%] __memmove_evex_unaligned_erms
    │   │   ├─ [  4.16%] spage_check_updatable
    │   │   │   ├─ [  3.75%] spage_has_enough_total_space
    │   │   │   │   ├─ [  2.97%] spage_get_total_saved_spaces
    │   │   │   │   │   └─ [  2.74%] spage_get_saved_spaces
    │   │   │   │   │       └─ [  2.24%] lf_hash_find
    │   │   │   │   │           ├─ [  1.35%] lf_list_find
    │   │   │   │   │           │   ├─ [  0.19%] lf_tran_end@plt
    │   │   │   │   │           │   └─ [  0.53%] lf_tran_start
    │   │   │   │   │           │       └─ [  0.17%] ATOMIC_INC_64<unsigned long, int>
    │   │   │   │   │           └─ [  0.30%] lf_callback_vpid_hash
    │   │   │   │   ├─ [  0.52%] logtb_find_tranid
    │   │   │   │   │   └─ [  1.34%] LOG_FIND_TDES
    │   │   │   │   ├─ [  0.24%] logtb_find_current_tranid@plt
    │   │   │   │   ├─ [  0.18%] logtb_is_active
    │   │   │   │   └─ [  0.19%] log_is_in_crash_recovery
    │   │   │   └─ [  0.48%] spage_find_slot
    │   │   │       └─ [  0.13%] spage_is_unknown_slot
    │   │   ├─ [  0.38%] spage_save_space
    │   │   │   └─ [  0.52%] logtb_find_tranid
    │   │   │       └─ [  1.34%] LOG_FIND_TDES
    │   │   └─ [  0.19%] pgbuf_set_dirty
    │   │       └─ [  0.29%] pgbuf_set_dirty_buffer_ptr
    │   ├─ [  2.94%] pgbuf_unfix
    │   │   ├─ [  1.86%] pgbuf_unlatch_bcb_upon_unfix
    │   │   │   ├─ [  0.23%] pgbuf_wakeup_reader_writer
    │   │   │   │   └─ [  0.22%] set_waiter_exists
    │   │   │   ├─ [  0.22%] pgbuf_lru_boost_bcb
    │   │   │   └─ [  2.24%] __pthread_mutex_unlock_usercnt
    │   │   │       └─ [  0.25%] __lll_unlock_wake
    │   │   ├─ [  2.59%] __GI___pthread_mutex_lock
    │   │   │   └─ [  0.25%] __lll_lock_wait
    │   │   └─ [  0.22%] pgbuf_unlatch_thrd_holder
    │   ├─ [  6.52%] spage_get_record_data
    │   │   └─ [ 17.70%] __memmove_evex_unaligned_erms
    │   ├─ [  0.46%] heap_update_adjust_recdes_header
    │   │   └─ [  0.27%] logtb_get_current_mvccid
    │   │       └─ [  1.34%] LOG_FIND_TDES
    │   ├─ [  0.21%] heap_get_record_location
    │   │   └─ [  0.11%] heap_scan_pb_lock_and_fetch
    │   ├─ [  0.50%] mvcc_is_mvcc_disabled_class
    │   ├─ [  0.17%] heap_scancache_check_with_hfid
    │   ├─ [  0.11%] check_supplemental_log
    │   └─ [  0.20%] pgbuf_ordered_unfix
    ├─ [ 23.02%] locator_lock_and_get_object_with_evaluation
    │   ├─ [ 19.36%] locator_lock_and_get_object_internal
    │   │   ├─ [ 11.83%] lock_object
    │   │   │   ├─ [ 11.18%] lock_internal_perform_lock_object
    │   │   │   │   ├─ [  8.47%] lock_escalate_if_needed
    │   │   │   │   │   └─ [  2.24%] __pthread_mutex_unlock_usercnt
    │   │   │   │   │       └─ [  0.25%] __lll_unlock_wake
    │   │   │   │   ├─ [  8.31%] lock_remove_all_inst_locks
    │   │   │   │   │   ├─ [  4.14%] lock_remove_resource
    │   │   │   │   │   │   └─ [  4.11%] lf_hash_delete_already_locked
    │   │   │   │   │   │       ├─ [  3.91%] lf_list_delete
    │   │   │   │   │   │       │   ├─ [  2.82%] lock_res_key_compare
    │   │   │   │   │   │       │   ├─ [  2.90%] lf_freelist_retire
    │   │   │   │   │   │       │   │   ├─ [  2.22%] lf_freelist_transport
    │   │   │   │   │   │       │   │   │   ├─ [  1.93%] lock_dealloc_entry
    │   │   │   │   │   │       │   │   │   │   └─ [  2.14%] _int_free
    │   │   │   │   │   │       │   │   │   │       ├─ [  1.20%] malloc_consolidate
    │   │   │   │   │   │       │   │   │   │       │   └─ [  1.01%] unlink_chunk.isra.2
    │   │   │   │   │   │       │   │   │   │       └─ [  1.01%] unlink_chunk.isra.2
    │   │   │   │   │   │       │   │   │   └─ [  0.21%] lock_dealloc_resource
    │   │   │   │   │   │       │   │   │       └─ [  2.14%] _int_free
    │   │   │   │   │   │       │   │   │           ├─ [  1.20%] malloc_consolidate
    │   │   │   │   │   │       │   │   │           │   └─ [  1.01%] unlink_chunk.isra.2
    │   │   │   │   │   │       │   │   │           └─ [  1.01%] unlink_chunk.isra.2
    │   │   │   │   │   │       │   │   ├─ [  0.20%] ATOMIC_INC_32<int, int>
    │   │   │   │   │   │       │   │   └─ [  0.53%] lf_tran_start
    │   │   │   │   │   │       │   │       └─ [  0.17%] ATOMIC_INC_64<unsigned long, int>
    │   │   │   │   │   │       │   └─ [  0.53%] lf_tran_start
    │   │   │   │   │   │       │       └─ [  0.17%] ATOMIC_INC_64<unsigned long, int>
    │   │   │   │   │   │       └─ [  0.19%] lf_hash_delete_internal
    │   │   │   │   │   │           └─ [  0.26%] lock_res_key_hash
    │   │   │   │   │   │               └─ [  0.23%] lock_get_hash_value
    │   │   │   │   │   └─ [  3.26%] lock_internal_perform_unlock_object
    │   │   │   │   │       ├─ [  2.90%] lf_freelist_retire
    │   │   │   │   │       │   ├─ [  2.22%] lf_freelist_transport
    │   │   │   │   │       │   │   ├─ [  1.93%] lock_dealloc_entry
    │   │   │   │   │       │   │   │   └─ [  2.14%] _int_free
    │   │   │   │   │       │   │   │       ├─ [  1.20%] malloc_consolidate
    │   │   │   │   │       │   │   │       │   └─ [  1.01%] unlink_chunk.isra.2
    │   │   │   │   │       │   │   │       └─ [  1.01%] unlink_chunk.isra.2
    │   │   │   │   │       │   │   └─ [  0.21%] lock_dealloc_resource
    │   │   │   │   │       │   │       └─ [  2.14%] _int_free
    │   │   │   │   │       │   │           ├─ [  1.20%] malloc_consolidate
    │   │   │   │   │       │   │           │   └─ [  1.01%] unlink_chunk.isra.2
    │   │   │   │   │       │   │           └─ [  1.01%] unlink_chunk.isra.2
    │   │   │   │   │       │   ├─ [  0.20%] ATOMIC_INC_32<int, int>
    │   │   │   │   │       │   └─ [  0.53%] lf_tran_start
    │   │   │   │   │       │       └─ [  0.17%] ATOMIC_INC_64<unsigned long, int>
    │   │   │   │   │       ├─ [  2.24%] __pthread_mutex_unlock_usercnt
    │   │   │   │   │       │   └─ [  0.25%] __lll_unlock_wake
    │   │   │   │   │       ├─ [  2.59%] __GI___pthread_mutex_lock
    │   │   │   │   │       │   └─ [  0.25%] __lll_lock_wait
    │   │   │   │   │       └─ [  0.14%] lock_delete_from_tran_hold_list
    │   │   │   │   ├─ [  1.93%] cubthread::lockfree_hashmap<lk_res_key, lk_res>::find_or_insert
    │   │   │   │   │   └─ [  1.78%] lf_hash_insert_internal
    │   │   │   │   │       ├─ [  1.49%] lf_list_insert_internal
    │   │   │   │   │       │   ├─ [  2.82%] lock_res_key_compare
    │   │   │   │   │       │   └─ [  2.59%] __GI___pthread_mutex_lock
    │   │   │   │   │       │       └─ [  0.25%] __lll_lock_wait
    │   │   │   │   │       └─ [  0.26%] lock_res_key_hash
    │   │   │   │   │           └─ [  0.23%] lock_get_hash_value
    │   │   │   │   ├─ [  0.14%] lock_event_set_xasl_id_to_entry
    │   │   │   │   ├─ [  2.24%] __pthread_mutex_unlock_usercnt
    │   │   │   │   │   └─ [  0.25%] __lll_unlock_wake
    │   │   │   │   └─ [  2.59%] __GI___pthread_mutex_lock
    │   │   │   │       └─ [  0.25%] __lll_lock_wait
    │   │   │   ├─ [  0.36%] lock_find_class_entry
    │   │   │   │   └─ [  2.59%] __GI___pthread_mutex_lock
    │   │   │   │       └─ [  0.25%] __lll_lock_wait
    │   │   │   └─ [  0.14%] lock_get_class_lock
    │   │   ├─ [  6.96%] heap_get_last_version
    │   │   │   ├─ [  6.01%] heap_get_record_data_when_all_ready
    │   │   │   │   ├─ [  6.52%] spage_get_record_data
    │   │   │   │   │   └─ [ 17.70%] __memmove_evex_unaligned_erms
    │   │   │   │   └─ [  0.38%] heap_scancache::assign_recdes_to_area
    │   │   │   ├─ [  0.43%] heap_get_mvcc_header
    │   │   │   │   └─ [  0.41%] or_mvcc_get_header
    │   │   │   └─ [  0.21%] heap_prepare_get_context
    │   │   ├─ [  0.14%] logtb_find_isolation
    │   │   │   └─ [  1.34%] LOG_FIND_TDES
    │   │   └─ [  0.50%] mvcc_is_mvcc_disabled_class
    │   ├─ [  1.84%] heap_scan_cache_allocate_area
    │   │   ├─ [  1.23%] heap_scancache::reserve_area
    │   │   │   └─ [  1.12%] heap_scancache::alloc_area
    │   │   │       └─ [  0.97%] cubmem::single_block_allocator::single_block_allocator
    │   │   │           ├─ [  0.62%] cubmem::block_allocator::block_allocator
    │   │   │           │   └─ [  0.57%] std::_Function_base::_Base_manager<std::_Bind<void (cubmem::single_block_allocator::*(cubmem::single_block_allocator*, std::_Placeholder<1>))(cubmem::block&)> >::_M_manager
    │   │   │           │       └─ [  0.88%] operator new
    │   │   │           │           └─ [  5.40%] __GI___libc_malloc
    │   │   │           │               └─ [  3.77%] _int_malloc
    │   │   │           │                   └─ [  1.01%] unlink_chunk.isra.2
    │   │   │           └─ [  0.88%] operator new
    │   │   │               └─ [  5.40%] __GI___libc_malloc
    │   │   │                   └─ [  3.77%] _int_malloc
    │   │   │                       └─ [  1.01%] unlink_chunk.isra.2
    │   │   └─ [  0.59%] cubmem::single_block_allocator::reserve
    │   │       └─ [  0.26%] heap_scancache_block_allocate
    │   └─ [  1.53%] heap_clean_get_context
    │       └─ [  2.94%] pgbuf_unfix
    │           ├─ [  1.86%] pgbuf_unlatch_bcb_upon_unfix
    │           │   ├─ [  0.23%] pgbuf_wakeup_reader_writer
    │           │   │   └─ [  0.22%] set_waiter_exists
    │           │   ├─ [  0.22%] pgbuf_lru_boost_bcb
    │           │   └─ [  2.24%] __pthread_mutex_unlock_usercnt
    │           │       └─ [  0.25%] __lll_unlock_wake
    │           ├─ [  2.59%] __GI___pthread_mutex_lock
    │           │   └─ [  0.25%] __lll_lock_wait
    │           └─ [  0.22%] pgbuf_unlatch_thrd_holder
    ├─ [  3.60%] locator_check_foreign_key
    │   ├─ [  1.57%] heap_attrinfo_start_with_index
    │   │   ├─ [  0.89%] heap_classrepr_get
    │   │   │   ├─ [  2.59%] __GI___pthread_mutex_lock
    │   │   │   │   └─ [  0.25%] __lll_lock_wait
    │   │   │   ├─ [  2.24%] __pthread_mutex_unlock_usercnt
    │   │   │   │   └─ [  0.25%] __lll_unlock_wake
    │   │   │   └─ [  0.15%] __GI___pthread_mutex_trylock
    │   │   ├─ [  0.29%] heap_attrinfo_recache_attrepr
    │   │   └─ [  0.17%] hl_lea_alloc
    │   ├─ [  0.89%] heap_attrinfo_end
    │   │   └─ [  0.60%] heap_classrepr_free
    │   │       ├─ [  2.24%] __pthread_mutex_unlock_usercnt
    │   │       │   └─ [  0.25%] __lll_unlock_wake
    │   │       └─ [  2.59%] __GI___pthread_mutex_lock
    │   │           └─ [  0.25%] __lll_lock_wait
    │   └─ [  0.69%] heap_attrinfo_read_dbvalues
    │       └─ [  0.37%] heap_attrvalue_read
    │           └─ [  0.21%] heap_attrvalue_point_fixed
    ├─ [  0.30%] heap_create_update_context
    │   └─ [  0.24%] heap_clear_operation_context
    └─ [  0.50%] mvcc_is_mvcc_disabled_class

# orphan (root 경로에 등장하나 트리 도달 불가, >= 0.1%):
  - [  0.24%] perfmon_is_perf_tracking
  - [  0.18%] oid_check_cached_class_oid
  - [  0.16%] prm_get_integer_value
  - [  0.16%] __GI___libc_free
  - [  0.15%] thread_get_thread_entry_info
  - [  0.14%] pgbuf_get_vpid_ptr@plt
  - [  0.13%] pgbuf_find_thrd_holder
  - [  0.13%] perfmon_inc_stat
  - [  0.13%] perfmon_add_stat
  - [  0.13%] std::_Function_base::_Base_manager<std::_Bind<void (cubmem::single_block_allocator::*(cubmem::single_block_allocator*, std::_Placeholder<1>, std::_Placeholder<2>))(cubmem::block&, unsigned long)> >::_M_manager
  - [  0.13%] pthread_mutex_lock@plt
  - [  0.12%] cubthread::get_entry
  - [  0.11%] lock_conv
  - [  0.11%] xdisk_get_purpose@plt
  - [  0.11%] pgbuf_is_temp_lsa
  - [  0.11%] memcpy@plt
```

## 전체 함수 inclusive 표 (401개 전부, 컷오프 없음)

```
# locator_update_force 경로 inclusive 함수 표 — 전체 401개 (컷오프 없음)
# denom = root_samples = 29001

 %of_root   samples  func
  100.000     29001  locator_update_force
   71.580     20759  heap_update_logical
   47.340     13729  heap_log_update_physical
   45.457     13183  log_append_undoredo_recdes
   45.271     13129  log_append_undoredo_recdes2
   45.150     13094  log_append_undoredo_crumbs
   39.147     11353  prior_lsa_alloc_and_copy_crumbs
   31.682      9188  prior_lsa_gen_undoredo_record_from_crumbs
   23.341      6769  log_diff
   23.016      6675  locator_lock_and_get_object_with_evaluation
   19.537      5666  heap_update_home
   19.358      5614  locator_lock_and_get_object_internal
   17.696      5132  __memmove_evex_unaligned_erms
   15.110      4382  spage_update
   13.010      3773  spage_update_record_after_compact
   11.827      3430  lock_object
   11.175      3241  lock_internal_perform_lock_object
    8.489      2462  spage_compact
    8.465      2455  lock_escalate_if_needed
    8.310      2410  lock_remove_all_inst_locks
    7.269      2108  log_zip
    6.958      2018  heap_get_last_version
    6.524      1892  spage_get_record_data
    6.010      1743  heap_get_record_data_when_all_ready
    5.693      1651  LZ4_resetStream_fast
    5.400      1566  __GI___libc_malloc
    5.245      1521  __memset_evex_unaligned_erms
    4.969      1441  cub_alloc
    4.158      1206  spage_check_updatable
    4.138      1200  lock_remove_resource
    4.107      1191  lf_hash_delete_already_locked
    3.914      1135  lf_list_delete
    3.765      1092  _int_malloc
    3.748      1087  spage_has_enough_total_space
    3.600      1044  locator_check_foreign_key
    3.493      1013  prior_lsa_next_record_internal
    3.262       946  lock_internal_perform_unlock_object
    2.972       862  spage_get_total_saved_spaces
    2.938       852  pgbuf_unfix
    2.896       840  lf_freelist_retire
    2.824       819  lock_res_key_compare
    2.752       798  spage_is_updatable
    2.738       794  spage_get_saved_spaces
    2.590       751  __GI___pthread_mutex_lock
    2.245       651  lf_hash_find
    2.241       650  __pthread_mutex_unlock_usercnt
    2.217       643  lf_freelist_transport
    2.145       622  _int_free
    1.934       561  lock_dealloc_entry
    1.931       560  cubthread::lockfree_hashmap<lk_res_key, lk_res>::find_or_insert
    1.862       540  pgbuf_unlatch_bcb_upon_unfix
    1.845       535  heap_scan_cache_allocate_area
    1.779       516  lf_hash_insert_internal
    1.572       456  heap_attrinfo_start_with_index
    1.528       443  heap_clean_get_context
    1.493       433  lf_list_insert_internal
    1.348       391  lf_list_find
    1.345       390  LOG_FIND_TDES
    1.231       357  heap_scancache::reserve_area
    1.203       349  prior_lsa_copy_undo_data_to_node
    1.203       349  malloc_consolidate
    1.186       344  prior_lsa_copy_redo_data_to_node
    1.176       341  heap_page_update_chain_after_mvcc_op
    1.124       326  heap_scancache::alloc_area
    1.124       326  pgbuf_set_lsa
    1.010       293  unlink_chunk.isra.2
    0.969       281  cubmem::single_block_allocator::single_block_allocator
    0.886       257  heap_classrepr_get
    0.886       257  heap_attrinfo_end
    0.883       256  operator new
    0.855       248  cub_calloc
    0.786       228  __calloc
    0.779       226  LSA_COPY
    0.752       218  fileio_set_page_lsa
    0.714       207  __GI___qsort_r
    0.686       199  heap_attrinfo_read_dbvalues
    0.679       197  heap_update_set_prev_version
    0.624       181  cubmem::block_allocator::block_allocator
    0.597       173  heap_classrepr_free
    0.586       170  cubmem::single_block_allocator::reserve
    0.572       166  std::_Function_base::_Base_manager<std::_Bind<void (cubmem::single_block_allocator::*(cubmem::single_block_allocator*, std::_Placeholder<1>))(cubmem::block&)> >::_M_manager
    0.569       165  msort_with_tmp.part.0
    0.528       153  lf_tran_start
    0.517       150  spage_get_record
    0.517       150  logtb_find_tranid
    0.500       145  mvcc_is_mvcc_disabled_class
    0.479       139  spage_find_slot
    0.455       132  heap_update_adjust_recdes_header
    0.428       124  heap_get_mvcc_header
    0.410       119  or_mvcc_get_header
    0.379       110  spage_save_space
    0.376       109  heap_scancache::assign_recdes_to_area
    0.366       106  heap_attrvalue_read
    0.359       104  LOG_FIND_CURRENT_TDES
    0.355       103  lock_find_class_entry
    0.348       101  vacuum_get_log_blockid
    0.328        95  __tls_get_addr
    0.321        93  heap_page_get_vacuum_status
    0.303        88  lf_callback_vpid_hash
    0.297        86  heap_create_update_context
    0.293        85  pgbuf_set_dirty_buffer_ptr
    0.290        84  heap_attrinfo_recache_attrepr
    0.279        81  xdisk_get_purpose
    0.269        78  logtb_get_current_mvccid
    0.269        78  pgbuf_is_lsa_temporary
    0.262        76  lock_res_key_hash
    0.255        74  heap_scancache_block_allocate
    0.252        73  heap_update_physical
    0.252        73  __lll_lock_wait
    0.248        72  __lll_unlock_wake
    0.245        71  logtb_find_current_tranid@plt
    0.245        71  perfmon_is_perf_tracking
    0.238        69  heap_clear_operation_context
    0.238        69  logtb_find_client_type
    0.234        68  spage_get_record_type
    0.231        67  pgbuf_wakeup_reader_writer
    0.228        66  prior_lsa_append_data
    0.228        66  lock_get_hash_value
    0.224        65  pgbuf_lru_boost_bcb
    0.224        65  spage_get_record@plt
    0.224        65  set_waiter_exists
    0.224        65  log_zip@plt
    0.217        63  pgbuf_unlatch_thrd_holder
    0.214        62  heap_attrvalue_point_fixed
    0.210        61  heap_prepare_get_context
    0.210        61  heap_get_record_location
    0.210        61  lock_dealloc_resource
    0.197        57  ATOMIC_INC_32<int, int>
    0.197        57  pgbuf_ordered_unfix
    0.193        56  log_is_in_crash_recovery
    0.190        55  pgbuf_set_dirty
    0.190        55  lf_hash_delete_internal
    0.186        54  lf_tran_end@plt
    0.183        53  oid_check_cached_class_oid
    0.183        53  log_can_skip_undo_logging
    0.176        51  logtb_is_active
    0.172        50  heap_scancache_check_with_hfid
    0.172        50  ATOMIC_INC_64<unsigned long, int>
    0.166        48  hl_lea_alloc
    0.159        46  prm_get_integer_value
    0.155        45  or_mvcc_set_log_lsa_to_record
    0.155        45  __GI___libc_free
    0.152        44  thread_get_thread_entry_info
    0.152        44  __GI___pthread_mutex_trylock
    0.145        42  logtb_find_isolation
    0.145        42  lock_delete_from_tran_hold_list
    0.141        41  lock_get_class_lock
    0.141        41  pgbuf_get_vpid_ptr@plt
    0.141        41  lock_event_set_xasl_id_to_entry
    0.138        40  prior_lsa_start_append
    0.138        40  log_append_undoredo_recdes2@plt
    0.138        40  log_zip_realloc_if_needed
    0.134        39  pgbuf_find_thrd_holder
    0.131        38  perfmon_inc_stat
    0.131        38  perfmon_add_stat
    0.128        37  spage_is_unknown_slot
    0.128        37  std::_Function_base::_Base_manager<std::_Bind<void (cubmem::single_block_allocator::*(cubmem::single_block_allocator*, std::_Placeholder<1>, std::_Placeholder<2>))(cubmem::block&, unsigned long)> >::_M_manager
    0.128        37  pthread_mutex_lock@plt
    0.124        36  log_tdes::is_system_worker_transaction@plt
    0.117        34  cubthread::get_entry
    0.114        33  spage_is_updatable@plt
    0.114        33  LZ4_compress_fast_extState@plt
    0.114        33  lock_conv
    0.114        33  check_supplemental_log
    0.110        32  xdisk_get_purpose@plt
    0.110        32  log_append_undoredo_recdes@plt
    0.110        32  pgbuf_is_temp_lsa
    0.110        32  heap_scan_pb_lock_and_fetch
    0.107        31  LZ4_compressBound
    0.107        31  log_zip_realloc_if_needed@plt
    0.107        31  memcpy@plt
    0.100        29  pgbuf_bcb_change_zone
    0.100        29  spage_verify_header
    0.100        29  log_is_in_crash_recovery@plt
    0.097        28  mspace_malloc
    0.097        28  memmove@plt
    0.097        28  pgbuf_remove_watcher
    0.093        27  ATOMIC_CAS_32<int, int, int>
    0.093        27  malloc@plt
    0.093        27  heap_init_get_context
    0.093        27  lf_tran_start@plt
    0.090        26  cub_free
    0.090        26  logpb_get_memsize
    0.090        26  heap_scancache::reserve_area@plt
    0.090        26  log_tdes::is_system_worker_transaction
    0.086        25  logtb_get_current_tran_index
    0.086        25  heap_attrinfo_recache
    0.086        25  db_private_alloc_release
    0.086        25  lf_tran_compute_minimum_transaction_id
    0.083        24  mvcc_is_mvcc_disabled_class@plt
    0.083        24  logtb_find_tranid@plt
    0.083        24  cubmem::single_block_allocator::get_ptr
    0.083        24  __lll_lock_wait_private
    0.079        23  pgbuf_notify_vacuum_follows
    0.079        23  pgbuf_remove_from_lru_list
    0.079        23  vacuum_is_mvccid_vacuumed
    0.076        22  spage_compact@plt
    0.076        22  spage_compare_slot_offset
    0.076        22  pgbuf_get_vpid_ptr
    0.076        22  heap_is_big_length@plt
    0.076        22  heap_attrinfo_clear_dbvalues
    0.076        22  ATOMIC_CAS_ADDR<void>
    0.076        22  log_prior_lsa_append_advance_when_doesnot_fit
    0.072        21  vacuum_is_mvccid_vacuumed@plt
    0.072        21  LZ4_compress_fast_extState
    0.072        21  heap_prepare_object_page
    0.072        21  db_private_get_heapid_from_thread
    0.072        21  cubmem::single_block_allocator::get_size@plt
    0.072        21  logtb_find_current_mvccid
    0.069        20  logtb_find_current_tran_lsa@plt
    0.069        20  pgbuf_remove_thrd_holder
    0.066        19  pgbuf_lru_add_bcb_to_top
    0.066        19  or_mvcc_get_repid_and_flags@plt
    0.062        18  operator delete
    0.062        18  db_private_alloc_release@plt
    0.062        18  or_rep_id
    0.062        18  logtb_find_current_tran_lsa
    0.062        18  heap_attrvalue_transform_to_dbvalue
    0.062        18  __lll_unlock_wake_private
    0.062        18  lf_hash_find@plt
    0.059        17  cubmem::single_block_allocator::reserve@plt
    0.059        17  or_header_size
    0.059        17  or_mvcc_set_log_lsa_to_record@plt
    0.059        17  spage_max_record_size@plt
    0.059        17  oid_is_serial
    0.059        17  log_append_undoredo_crumbs@plt
    0.059        17  logtb_is_active@plt
    0.059        17  heap_is_big_length
    0.059        17  log_prior_lsa_append_align
    0.059        17  spage_set_slot
    0.059        17  locator_update_index@plt
    0.055        16  oid_check_cached_class_oid@plt
    0.055        16  mmon_is_memory_monitor_enabled
    0.055        16  prm_get_bool_value
    0.055        16  heap_scancache::alloc_area@plt
    0.055        16  oid_is_serial@plt
    0.052        15  pgbuf_get_tde_algorithm@plt
    0.052        15  mspace_free
    0.052        15  heap_scancache::assign_recdes_to_area@plt
    0.048        14  log_append_get_zip_redo@plt
    0.048        14  logtb_find_current_mvccid@plt
    0.048        14  __GI___pthread_mutex_unlock
    0.048        14  pgbuf_unfix@plt
    0.048        14  heap_attrinfo_read_dbvalues@plt
    0.048        14  LOG_PRIOR_LSA_LAST_APPEND_OFFSET@plt
    0.048        14  or_rep_id@plt
    0.048        14  locator_lock_and_get_object_with_evaluation@plt
    0.048        14  pgbuf_get_page_ptype
    0.048        14  pgbuf_bcb_update_flags
    0.048        14  operator new@plt
    0.048        14  spage_get_slot
    0.045        13  locator_update_index
    0.045        13  prior_lsa_alloc_and_copy_crumbs@plt
    0.045        13  or_mvcc_get_repid_and_flags
    0.045        13  pgbuf_get_holder
    0.041        12  cubmem::single_block_allocator::get_ptr@plt
    0.041        12  pthread_mutex_unlock@plt
    0.041        12  log_diff@plt
    0.041        12  __gthread_mutex_unlock
    0.038        11  std::_Function_handler<void (cubmem::block&, unsigned long), void (*)(cubmem::block&, unsigned long)>::_M_invoke
    0.038        11  db_value_domain_init
    0.038        11  free@plt
    0.038        11  or_mvcc_get_prev_version_lsa
    0.038        11  pgbuf_ordered_fix_release
    0.038        11  calloc@plt
    0.038        11  logtb_get_current_mvccid@plt
    0.038        11  sys_alloc
    0.034        10  spage_max_record_size
    0.034        10  LSA_ISNULL
    0.034        10  LOG_PRIOR_LSA_LAST_APPEND_OFFSET
    0.034        10  pgbuf_ordered_fix_release@plt
    0.034        10  pgbuf_set_lsa@plt
    0.034        10  lock_check_escalate
    0.034        10  heap_page_get_vacuum_status@plt
    0.034        10  log_tdes::is_system_transaction
    0.034        10  __bswap_32
    0.034        10  memset@plt
    0.034        10  __tls_get_addr@plt
    0.034        10  css_internal_request_handler
    0.034        10  execute_native_thread_routine
    0.034        10  cubthread::worker_pool::core::worker::execute_current_task
    0.034        10  xlocator_repl_force
    0.034        10  slocator_repl_force
    0.034        10  start_thread
    0.034        10  css_server_task::execute
    0.034        10  cubthread::worker_pool::core::worker::run
    0.034        10  __GI___clone
    0.034        10  net_server_request
    0.031         9  or_mvcc_get_header@plt
    0.031         9  heap_create_update_context@plt
    0.031         9  LSA_SET_NULL
    0.031         9  qsort@plt
    0.031         9  lf_tran_end
    0.031         9  pgbuf_set_dirty@plt
    0.031         9  pgbuf_get_tde_algorithm
    0.028         8  __gthread_mutex_lock
    0.028         8  logtb_find_client_type@plt
    0.028         8  logtb_find_current_isolation
    0.028         8  heap_scan_cache_allocate_area@plt
    0.028         8  __GI_qsort
    0.028         8  heap_attrinfo_end@plt
    0.024         7  prior_lsa_end_append
    0.024         7  heap_get_mvcc_header@plt
    0.024         7  lf_hash_find_or_insert@plt
    0.024         7  vacuum_get_log_blockid@plt
    0.024         7  spage_get_record_type@plt
    0.024         7  heap_attrinfo_start_with_index@plt
    0.024         7  pgbuf_lru_advance_victim_hint
    0.024         7  pgbuf_get_page_ptype@plt
    0.024         7  logtb_find_isolation@plt
    0.024         7  heap_clean_get_context@plt
    0.024         7  pgbuf_check_bcb_page_vpid
    0.021         6  cubthread::get_entry@plt
    0.021         6  or_mvcc_get_chn
    0.021         6  prior_lsa_next_record@plt
    0.021         6  log_tdes::is_system_transaction@plt
    0.021         6  heap_prepare_get_context@plt
    0.021         6  spage_update@plt
    0.021         6  tp_domain_disk_size
    0.021         6  logtb_get_current_tran_index@plt
    0.021         6  heap_link_watchers
    0.021         6  or_mvcc_get_flag
    0.021         6  or_init
    0.017         5  prior_lsa_next_record
    0.017         5  db_private_free_release
    0.017         5  log_append_get_zip_undo@plt
    0.017         5  LZ4_resetStream_fast@plt
    0.017         5  heap_get_last_version@plt
    0.017         5  logtb_find_current_isolation@plt
    0.017         5  ATOMIC_CAS_ADDR<pgbuf_bcb>
    0.017         5  heap_unfix_watchers
    0.017         5  pr_clear_value
    0.017         5  log_append_get_zip_undo
    0.017         5  log_append_get_zip_redo
    0.017         5  lf_list_find@plt
    0.017         5  logtb_find_current_tranid
    0.017         5  LZ4_compressBound@plt
    0.017         5  pgbuf_is_lsa_temporary@plt
    0.014         4  logpb_get_memsize@plt
    0.014         4  heap_get_record_data_when_all_ready@plt
    0.014         4  pgbuf_ordered_unfix@plt
    0.014         4  log_prior_lsa_append_add_align
    0.014         4  mspace_malloc@plt
    0.014         4  or_chn@plt
    0.014         4  lock_object@plt
    0.014         4  db_value_domain_init@plt
    0.014         4  lf_hash_find_or_insert
    0.014         4  or_header_size@plt
    0.010         3  heap_scan_cache_allocate_recdes_data
    0.010         3  spage_get_slot@plt
    0.010         3  pr_clear_value@plt
    0.010         3  hl_lea_free@plt
    0.010         3  heap_attrinfo_clear_dbvalues@plt
    0.010         3  hl_lea_alloc@plt
    0.010         3  PGBUF_THREAD_HAS_PRIVATE_LRU
    0.010         3  pr_type_from_id
    0.010         3  spage_is_record_located_at_end
    0.010         3  log_append_realloc_data_ptr
    0.010         3  __GI_madvise
    0.007         2  pr_type_from_id@plt
    0.007         2  heap_classrepr_get@plt
    0.007         2  pgbuf_notify_vacuum_follows@plt
    0.007         2  mr_data_readval_int
    0.007         2  lock_compat
    0.007         2  pgbuf_is_temporary_volume
    0.007         2  pgbuf_bcb_set_dirty
    0.007         2  heap_init_get_context@plt
    0.007         2  cub_free@plt
    0.007         2  cubthread::lockfree_hashmap<lk_res_key, lk_res>::find_or_insert@plt
    0.007         2  lock_create_search_key
    0.007         2  cubmem::single_block_allocator::get_size
    0.007         2  or_chn
    0.007         2  lock_free_entry
    0.007         2  heap_is_valid_oid
    0.007         2  lf_freelist_retire@plt
    0.003         1  or_mvcc_set_repid_and_flags@plt
    0.003         1  or_mvcc_set_header
    0.003         1  pgbuf_bcb_register_hit_for_lru
    0.003         1  hl_lea_free
    0.003         1  prior_update_header_mvcc_info
    0.003         1  cubmem::block_allocator::block_allocator@plt
    0.003         1  or_get_int
    0.003         1  pgbuf_bcb_get_zone
    0.003         1  cubmem::single_block_allocator::single_block_allocator@plt
    0.003         1  pgbuf_should_move_private_to_shared
    0.003         1  heap_classrepr_entry_remove_from_LRU
    0.003         1  heap_classrepr_get_from_record
    0.003         1  vacuum_produce_log_block_data
    0.003         1  heap_classrepr_free@plt
    0.003         1  heap_get_file_type
    0.003         1  tp_domain_disk_size@plt
    0.003         1  mspace_free@plt
    0.003         1  pgbuf_lru_adjust_zone1
    0.003         1  cub_realloc
    0.003         1  lf_tran_compute_minimum_transaction_id@plt
    0.003         1  lf_hash_delete_already_locked@plt
    0.003         1  pthread_mutex_trylock@plt
    0.003         1  lock_get_class_lock@plt
    0.003         1  db_private_free_release@plt
    0.003         1  thread_get_tran_entry
    0.003         1  __GI___pthread_mutex_destroy
```

---

# 전체 콜체인 (모든 thread·서버 기능 포함, % of total)

위 §콜트리는 `locator_update_force` subtree(=100%)만 본 것이고, 아래는 **캡처된 전체
sample**을 thread(comm)별로 묶은 콜체인입니다. 노드 % = **전체 sample(126,337) 대비**.
stack truncate 를 감안해 각 sample 의 최외곽 프레임을 thread 노드에 매달아 100% 를 덮습니다.

원본: `analysis/calltree_full.txt`, 전 함수(1,615개) 평탄 표: `analysis/inclusive_total.txt`,
전체 flamegraph: `analysis/flame_full.svg`.

## thread(서버 스레드) 분포

| % of total | samples | thread | 역할 |
|---:|---:|---|---|
| 73.47 | 92,816 | `transaction` | 워커(update 실행) |
| 12.26 | 15,489 | `connections` | 클라이언트 연결 처리 |
| 4.11 | 5,195 | `dwb-flush-block` | double write buffer flush |
| 3.47 | 4,378 | `vacuum` | vacuum 워커 |
| 1.91 | 2,414 | `coordinator` | 트랜잭션 coordinator |
| 1.69 | 2,137 | `log-flush` | WAL flush |
| 0.89 | 1,123 | `vacuum-master` | vacuum 마스터 |
| 0.68 | 861 | `dwb-file-sync` | dwb 파일 sync |
| 0.34 | 424 | `pgbuf-flush-con` | page buffer flush |
| 1.19 | 1,500 | 기타 8종 | deadlock-detect, pgbuf-maintain, log-clock 등 |

## 전체 콜트리 (노드컷 0.2% of total, thread컷 0.3%, MIN_EDGE 30)

```
# 전체 on-CPU 콜체인 (모든 thread·함수, 노드 % = of total_samples=126337)
# 함수 노드 컷 0.2% / thread 컷 0.3% / MIN_EDGE 30

[100.00%] (ALL on-CPU)   total_samples=126337
├─ [ 73.47%] «transaction»  (92816 smp)
│   ├─ [ 23.21%] __GI___clone
│   │   └─ [ 23.21%] start_thread
│   │       └─ [ 23.21%] execute_native_thread_routine
│   │           └─ [ 23.21%] cubthread::worker_pool::core::worker::run
│   │               ├─ [ 20.36%] cubthread::worker_pool::core::worker::execute_current_task
│   │               │   └─ [ 20.11%] css_server_task::execute
│   │               │       ├─ [ 19.18%] css_internal_request_handler
│   │               │       │   ├─ [ 18.96%] net_server_request
│   │               │       │   │   ├─ [ 17.78%] slocator_repl_force
│   │               │       │   │   │   ├─ [ 15.08%] xlocator_repl_force
│   │               │       │   │   │   │   ├─ [  8.69%] xbtree_find_unique
│   │               │       │   │   │   │   │   ├─ [  4.04%] btree_key_find_and_lock_unique
│   │               │       │   │   │   │   │   │   └─ [  4.01%] btree_key_find_and_lock_unique_of_unique
│   │               │       │   │   │   │   │   │       └─ [  3.84%] btree_key_lock_object
│   │               │       │   │   │   │   │   │           └─ [  7.00%] lock_object
│   │               │       │   │   │   │   │   │               ├─ [  6.36%] lock_internal_perform_lock_object
│   │               │       │   │   │   │   │   │               │   ├─ [  3.12%] cubthread::lockfree_hashmap<lk_res_key, lk_res>::find_or_insert
│   │               │       │   │   │   │   │   │               │   │   └─ [  3.38%] lf_hash_insert_internal
│   │               │       │   │   │   │   │   │               │   │       └─ [  2.90%] lf_list_insert_internal
│   │               │       │   │   │   │   │   │               │   │           ├─ [  2.26%] lock_res_key_compare
│   │               │       │   │   │   │   │   │               │   │           ├─ [  0.92%] lf_freelist_claim
│   │               │       │   │   │   │   │   │               │   │           │   ├─ [  0.35%] lf_stack_pop
│   │               │       │   │   │   │   │   │               │   │           │   ├─ [  0.26%] lf_freelist_alloc_block
│   │               │       │   │   │   │   │   │               │   │           │   │   └─ [  2.03%] __GI___libc_malloc
│   │               │       │   │   │   │   │   │               │   │           │   │       └─ [  1.59%] _int_malloc
│   │               │       │   │   │   │   │   │               │   │           │   │           ├─ [  0.58%] malloc_consolidate
│   │               │       │   │   │   │   │   │               │   │           │   │           │   └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │   │   │               │   │           │   │           └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │   │   │               │   │           │   ├─ [  0.22%] ATOMIC_INC_32<int, int>
│   │               │       │   │   │   │   │   │               │   │           │   └─ [  0.54%] lf_freelist_transport
│   │               │       │   │   │   │   │   │               │   │           │       └─ [  0.47%] lock_dealloc_entry
│   │               │       │   │   │   │   │   │               │   │           │           └─ [  0.79%] _int_free
│   │               │       │   │   │   │   │   │               │   │           │               ├─ [  0.58%] malloc_consolidate
│   │               │       │   │   │   │   │   │               │   │           │               │   └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │   │   │               │   │           │               └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │   │   │               │   │           └─ [  2.05%] __GI___pthread_mutex_lock
│   │               │       │   │   │   │   │   │               │   ├─ [  1.98%] lock_escalate_if_needed
│   │               │       │   │   │   │   │   │               │   │   └─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │               │       │   │   │   │   │   │               │   │       └─ [  0.28%] __lll_unlock_wake
│   │               │       │   │   │   │   │   │               │   ├─ [  1.91%] lock_remove_all_inst_locks
│   │               │       │   │   │   │   │   │               │   │   ├─ [  0.95%] lock_remove_resource
│   │               │       │   │   │   │   │   │               │   │   │   └─ [  0.95%] lf_hash_delete_already_locked
│   │               │       │   │   │   │   │   │               │   │   │       └─ [  0.90%] lf_list_delete
│   │               │       │   │   │   │   │   │               │   │   │           ├─ [  2.26%] lock_res_key_compare
│   │               │       │   │   │   │   │   │               │   │   │           └─ [  0.67%] lf_freelist_retire
│   │               │       │   │   │   │   │   │               │   │   │               ├─ [  0.54%] lf_freelist_transport
│   │               │       │   │   │   │   │   │               │   │   │               │   └─ [  0.47%] lock_dealloc_entry
│   │               │       │   │   │   │   │   │               │   │   │               │       └─ [  0.79%] _int_free
│   │               │       │   │   │   │   │   │               │   │   │               │           ├─ [  0.58%] malloc_consolidate
│   │               │       │   │   │   │   │   │               │   │   │               │           │   └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │   │   │               │   │   │               │           └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │   │   │               │   │   │               └─ [  0.22%] ATOMIC_INC_32<int, int>
│   │               │       │   │   │   │   │   │               │   │   └─ [  0.76%] lock_internal_perform_unlock_object
│   │               │       │   │   │   │   │   │               │   │       ├─ [  0.67%] lf_freelist_retire
│   │               │       │   │   │   │   │   │               │   │       │   ├─ [  0.54%] lf_freelist_transport
│   │               │       │   │   │   │   │   │               │   │       │   │   └─ [  0.47%] lock_dealloc_entry
│   │               │       │   │   │   │   │   │               │   │       │   │       └─ [  0.79%] _int_free
│   │               │       │   │   │   │   │   │               │   │       │   │           ├─ [  0.58%] malloc_consolidate
│   │               │       │   │   │   │   │   │               │   │       │   │           │   └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │   │   │               │   │       │   │           └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │   │   │               │   │       │   └─ [  0.22%] ATOMIC_INC_32<int, int>
│   │               │       │   │   │   │   │   │               │   │       ├─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │               │       │   │   │   │   │   │               │   │       │   └─ [  0.28%] __lll_unlock_wake
│   │               │       │   │   │   │   │   │               │   │       └─ [  2.05%] __GI___pthread_mutex_lock
│   │               │       │   │   │   │   │   │               │   ├─ [  0.92%] lf_freelist_claim
│   │               │       │   │   │   │   │   │               │   │   ├─ [  0.35%] lf_stack_pop
│   │               │       │   │   │   │   │   │               │   │   ├─ [  0.26%] lf_freelist_alloc_block
│   │               │       │   │   │   │   │   │               │   │   │   └─ [  2.03%] __GI___libc_malloc
│   │               │       │   │   │   │   │   │               │   │   │       └─ [  1.59%] _int_malloc
│   │               │       │   │   │   │   │   │               │   │   │           ├─ [  0.58%] malloc_consolidate
│   │               │       │   │   │   │   │   │               │   │   │           │   └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │   │   │               │   │   │           └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │   │   │               │   │   ├─ [  0.22%] ATOMIC_INC_32<int, int>
│   │               │       │   │   │   │   │   │               │   │   └─ [  0.54%] lf_freelist_transport
│   │               │       │   │   │   │   │   │               │   │       └─ [  0.47%] lock_dealloc_entry
│   │               │       │   │   │   │   │   │               │   │           └─ [  0.79%] _int_free
│   │               │       │   │   │   │   │   │               │   │               ├─ [  0.58%] malloc_consolidate
│   │               │       │   │   │   │   │   │               │   │               │   └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │   │   │               │   │               └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │   │   │               │   ├─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │               │       │   │   │   │   │   │               │   │   └─ [  0.28%] __lll_unlock_wake
│   │               │       │   │   │   │   │   │               │   ├─ [  0.26%] lock_find_class_entry
│   │               │       │   │   │   │   │   │               │   │   ├─ [  2.05%] __GI___pthread_mutex_lock
│   │               │       │   │   │   │   │   │               │   │   └─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │               │       │   │   │   │   │   │               │   │       └─ [  0.28%] __lll_unlock_wake
│   │               │       │   │   │   │   │   │               │   └─ [  2.05%] __GI___pthread_mutex_lock
│   │               │       │   │   │   │   │   │               ├─ [  0.28%] lock_get_class_lock
│   │               │       │   │   │   │   │   │               │   ├─ [  2.05%] __GI___pthread_mutex_lock
│   │               │       │   │   │   │   │   │               │   └─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │               │       │   │   │   │   │   │               │       └─ [  0.28%] __lll_unlock_wake
│   │               │       │   │   │   │   │   │               └─ [  0.26%] lock_find_class_entry
│   │               │       │   │   │   │   │   │                   ├─ [  2.05%] __GI___pthread_mutex_lock
│   │               │       │   │   │   │   │   │                   └─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │               │       │   │   │   │   │   │                       └─ [  0.28%] __lll_unlock_wake
│   │               │       │   │   │   │   │   ├─ [  3.79%] btree_search_key_and_apply_functions
│   │               │       │   │   │   │   │   │   ├─ [  1.44%] btree_advance_and_find_key
│   │               │       │   │   │   │   │   │   │   └─ [  3.26%] pgbuf_fix_release
│   │               │       │   │   │   │   │   │   │       ├─ [  0.85%] pgbuf_set_bcb_page_vpid
│   │               │       │   │   │   │   │   │   │       ├─ [  0.38%] pgbuf_search_hash_chain
│   │               │       │   │   │   │   │   │   │       │   └─ [  0.50%] __GI___pthread_mutex_trylock
│   │               │       │   │   │   │   │   │   │       ├─ [  0.31%] pgbuf_latch_bcb_upon_fix
│   │               │       │   │   │   │   │   │   │       └─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │               │       │   │   │   │   │   │   │           └─ [  0.28%] __lll_unlock_wake
│   │               │       │   │   │   │   │   │   ├─ [  0.71%] btree_get_root_with_key
│   │               │       │   │   │   │   │   │   │   └─ [  3.26%] pgbuf_fix_release
│   │               │       │   │   │   │   │   │   │       ├─ [  0.85%] pgbuf_set_bcb_page_vpid
│   │               │       │   │   │   │   │   │   │       ├─ [  0.38%] pgbuf_search_hash_chain
│   │               │       │   │   │   │   │   │   │       │   └─ [  0.50%] __GI___pthread_mutex_trylock
│   │               │       │   │   │   │   │   │   │       ├─ [  0.31%] pgbuf_latch_bcb_upon_fix
│   │               │       │   │   │   │   │   │   │       └─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │               │       │   │   │   │   │   │   │           └─ [  0.28%] __lll_unlock_wake
│   │               │       │   │   │   │   │   │   └─ [  2.18%] pgbuf_unfix
│   │               │       │   │   │   │   │   │       ├─ [  1.23%] pgbuf_unlatch_bcb_upon_unfix
│   │               │       │   │   │   │   │   │       │   └─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │               │       │   │   │   │   │   │       │       └─ [  0.28%] __lll_unlock_wake
│   │               │       │   │   │   │   │   │       ├─ [  2.05%] __GI___pthread_mutex_lock
│   │               │       │   │   │   │   │   │       └─ [  0.26%] pgbuf_lru_move_from_private_to_shared
│   │               │       │   │   │   │   │   │           └─ [  2.05%] __GI___pthread_mutex_lock
│   │               │       │   │   │   │   │   ├─ [  1.05%] btree_search_leaf_page
│   │               │       │   │   │   │   │   │   ├─ [  0.62%] btree_read_record_without_decompression
│   │               │       │   │   │   │   │   │   │   └─ [  0.22%] mr_index_readval_int
│   │               │       │   │   │   │   │   │   │       └─ [  4.68%] __memmove_evex_unaligned_erms
│   │               │       │   │   │   │   │   │   ├─ [  0.46%] btree_compare_key
│   │               │       │   │   │   │   │   │   ├─ [  0.57%] spage_get_record
│   │               │       │   │   │   │   │   │   │   └─ [  0.38%] spage_find_slot
│   │               │       │   │   │   │   │   │   └─ [  1.69%] spage_get_record_data
│   │               │       │   │   │   │   │   │       └─ [  4.68%] __memmove_evex_unaligned_erms
│   │               │       │   │   │   │   │   ├─ [  1.00%] btree_search_nonleaf_page
│   │               │       │   │   │   │   │   │   ├─ [  0.62%] btree_read_record_without_decompression
│   │               │       │   │   │   │   │   │   │   ├─ [  0.22%] mr_index_readval_int
│   │               │       │   │   │   │   │   │   │   │   └─ [  4.68%] __memmove_evex_unaligned_erms
│   │               │       │   │   │   │   │   │   │   └─ [  1.05%] btree_search_leaf_page
│   │               │       │   │   │   │   │   │   │       ├─ [  0.46%] btree_compare_key
│   │               │       │   │   │   │   │   │   │       ├─ [  0.57%] spage_get_record
│   │               │       │   │   │   │   │   │   │       │   └─ [  0.38%] spage_find_slot
│   │               │       │   │   │   │   │   │   │       └─ [  1.69%] spage_get_record_data
│   │               │       │   │   │   │   │   │   │           └─ [  4.68%] __memmove_evex_unaligned_erms
│   │               │       │   │   │   │   │   │   ├─ [  0.46%] btree_compare_key
│   │               │       │   │   │   │   │   │   ├─ [  0.57%] spage_get_record
│   │               │       │   │   │   │   │   │   │   └─ [  0.38%] spage_find_slot
│   │               │       │   │   │   │   │   │   └─ [  1.69%] spage_get_record_data
│   │               │       │   │   │   │   │   │       └─ [  4.68%] __memmove_evex_unaligned_erms
│   │               │       │   │   │   │   │   └─ [  7.00%] lock_object
│   │               │       │   │   │   │   │       ├─ [  6.36%] lock_internal_perform_lock_object
│   │               │       │   │   │   │   │       │   ├─ [  3.12%] cubthread::lockfree_hashmap<lk_res_key, lk_res>::find_or_insert
│   │               │       │   │   │   │   │       │   │   └─ [  3.38%] lf_hash_insert_internal
│   │               │       │   │   │   │   │       │   │       └─ [  2.90%] lf_list_insert_internal
│   │               │       │   │   │   │   │       │   │           ├─ [  2.26%] lock_res_key_compare
│   │               │       │   │   │   │   │       │   │           ├─ [  0.92%] lf_freelist_claim
│   │               │       │   │   │   │   │       │   │           │   ├─ [  0.35%] lf_stack_pop
│   │               │       │   │   │   │   │       │   │           │   ├─ [  0.26%] lf_freelist_alloc_block
│   │               │       │   │   │   │   │       │   │           │   │   └─ [  2.03%] __GI___libc_malloc
│   │               │       │   │   │   │   │       │   │           │   │       └─ [  1.59%] _int_malloc
│   │               │       │   │   │   │   │       │   │           │   │           ├─ [  0.58%] malloc_consolidate
│   │               │       │   │   │   │   │       │   │           │   │           │   └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │   │       │   │           │   │           └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │   │       │   │           │   ├─ [  0.22%] ATOMIC_INC_32<int, int>
│   │               │       │   │   │   │   │       │   │           │   └─ [  0.54%] lf_freelist_transport
│   │               │       │   │   │   │   │       │   │           │       └─ [  0.47%] lock_dealloc_entry
│   │               │       │   │   │   │   │       │   │           │           └─ [  0.79%] _int_free
│   │               │       │   │   │   │   │       │   │           │               ├─ [  0.58%] malloc_consolidate
│   │               │       │   │   │   │   │       │   │           │               │   └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │   │       │   │           │               └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │   │       │   │           └─ [  2.05%] __GI___pthread_mutex_lock
│   │               │       │   │   │   │   │       │   ├─ [  1.98%] lock_escalate_if_needed
│   │               │       │   │   │   │   │       │   │   └─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │               │       │   │   │   │   │       │   │       └─ [  0.28%] __lll_unlock_wake
│   │               │       │   │   │   │   │       │   ├─ [  1.91%] lock_remove_all_inst_locks
│   │               │       │   │   │   │   │       │   │   ├─ [  0.95%] lock_remove_resource
│   │               │       │   │   │   │   │       │   │   │   └─ [  0.95%] lf_hash_delete_already_locked
│   │               │       │   │   │   │   │       │   │   │       └─ [  0.90%] lf_list_delete
│   │               │       │   │   │   │   │       │   │   │           ├─ [  2.26%] lock_res_key_compare
│   │               │       │   │   │   │   │       │   │   │           └─ [  0.67%] lf_freelist_retire
│   │               │       │   │   │   │   │       │   │   │               ├─ [  0.54%] lf_freelist_transport
│   │               │       │   │   │   │   │       │   │   │               │   └─ [  0.47%] lock_dealloc_entry
│   │               │       │   │   │   │   │       │   │   │               │       └─ [  0.79%] _int_free
│   │               │       │   │   │   │   │       │   │   │               │           ├─ [  0.58%] malloc_consolidate
│   │               │       │   │   │   │   │       │   │   │               │           │   └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │   │       │   │   │               │           └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │   │       │   │   │               └─ [  0.22%] ATOMIC_INC_32<int, int>
│   │               │       │   │   │   │   │       │   │   └─ [  0.76%] lock_internal_perform_unlock_object
│   │               │       │   │   │   │   │       │   │       ├─ [  0.67%] lf_freelist_retire
│   │               │       │   │   │   │   │       │   │       │   ├─ [  0.54%] lf_freelist_transport
│   │               │       │   │   │   │   │       │   │       │   │   └─ [  0.47%] lock_dealloc_entry
│   │               │       │   │   │   │   │       │   │       │   │       └─ [  0.79%] _int_free
│   │               │       │   │   │   │   │       │   │       │   │           ├─ [  0.58%] malloc_consolidate
│   │               │       │   │   │   │   │       │   │       │   │           │   └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │   │       │   │       │   │           └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │   │       │   │       │   └─ [  0.22%] ATOMIC_INC_32<int, int>
│   │               │       │   │   │   │   │       │   │       ├─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │               │       │   │   │   │   │       │   │       │   └─ [  0.28%] __lll_unlock_wake
│   │               │       │   │   │   │   │       │   │       └─ [  2.05%] __GI___pthread_mutex_lock
│   │               │       │   │   │   │   │       │   ├─ [  0.92%] lf_freelist_claim
│   │               │       │   │   │   │   │       │   │   ├─ [  0.35%] lf_stack_pop
│   │               │       │   │   │   │   │       │   │   ├─ [  0.26%] lf_freelist_alloc_block
│   │               │       │   │   │   │   │       │   │   │   └─ [  2.03%] __GI___libc_malloc
│   │               │       │   │   │   │   │       │   │   │       └─ [  1.59%] _int_malloc
│   │               │       │   │   │   │   │       │   │   │           ├─ [  0.58%] malloc_consolidate
│   │               │       │   │   │   │   │       │   │   │           │   └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │   │       │   │   │           └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │   │       │   │   ├─ [  0.22%] ATOMIC_INC_32<int, int>
│   │               │       │   │   │   │   │       │   │   └─ [  0.54%] lf_freelist_transport
│   │               │       │   │   │   │   │       │   │       └─ [  0.47%] lock_dealloc_entry
│   │               │       │   │   │   │   │       │   │           └─ [  0.79%] _int_free
│   │               │       │   │   │   │   │       │   │               ├─ [  0.58%] malloc_consolidate
│   │               │       │   │   │   │   │       │   │               │   └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │   │       │   │               └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │   │       │   ├─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │               │       │   │   │   │   │       │   │   └─ [  0.28%] __lll_unlock_wake
│   │               │       │   │   │   │   │       │   ├─ [  0.26%] lock_find_class_entry
│   │               │       │   │   │   │   │       │   │   ├─ [  2.05%] __GI___pthread_mutex_lock
│   │               │       │   │   │   │   │       │   │   └─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │               │       │   │   │   │   │       │   │       └─ [  0.28%] __lll_unlock_wake
│   │               │       │   │   │   │   │       │   └─ [  2.05%] __GI___pthread_mutex_lock
│   │               │       │   │   │   │   │       ├─ [  0.28%] lock_get_class_lock
│   │               │       │   │   │   │   │       │   ├─ [  2.05%] __GI___pthread_mutex_lock
│   │               │       │   │   │   │   │       │   └─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │               │       │   │   │   │   │       │       └─ [  0.28%] __lll_unlock_wake
│   │               │       │   │   │   │   │       └─ [  0.26%] lock_find_class_entry
│   │               │       │   │   │   │   │           ├─ [  2.05%] __GI___pthread_mutex_lock
│   │               │       │   │   │   │   │           └─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │               │       │   │   │   │   │               └─ [  0.28%] __lll_unlock_wake
│   │               │       │   │   │   │   ├─ [  2.88%] locator_repl_prepare_force
│   │               │       │   │   │   │   │   ├─ [  1.56%] heap_get_visible_version
│   │               │       │   │   │   │   │   │   ├─ [  0.90%] heap_get_visible_version_internal
│   │               │       │   │   │   │   │   │   │   ├─ [  0.92%] heap_prepare_get_context
│   │               │       │   │   │   │   │   │   │   └─ [  1.49%] heap_get_record_data_when_all_ready
│   │               │       │   │   │   │   │   │   │       ├─ [  1.69%] spage_get_record_data
│   │               │       │   │   │   │   │   │   │       │   └─ [  4.68%] __memmove_evex_unaligned_erms
│   │               │       │   │   │   │   │   │   │       └─ [  0.57%] spage_get_record
│   │               │       │   │   │   │   │   │   │           └─ [  0.38%] spage_find_slot
│   │               │       │   │   │   │   │   │   └─ [  1.04%] heap_clean_get_context
│   │               │       │   │   │   │   │   │       └─ [  2.18%] pgbuf_unfix
│   │               │       │   │   │   │   │   │           ├─ [  1.23%] pgbuf_unlatch_bcb_upon_unfix
│   │               │       │   │   │   │   │   │           │   └─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │               │       │   │   │   │   │   │           │       └─ [  0.28%] __lll_unlock_wake
│   │               │       │   │   │   │   │   │           ├─ [  2.05%] __GI___pthread_mutex_lock
│   │               │       │   │   │   │   │   │           └─ [  0.26%] pgbuf_lru_move_from_private_to_shared
│   │               │       │   │   │   │   │   │               └─ [  2.05%] __GI___pthread_mutex_lock
│   │               │       │   │   │   │   │   ├─ [  0.92%] heap_get_class_repr_id
│   │               │       │   │   │   │   │   │   ├─ [  1.51%] heap_classrepr_get
│   │               │       │   │   │   │   │   │   │   ├─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │               │       │   │   │   │   │   │   │   │   └─ [  0.28%] __lll_unlock_wake
│   │               │       │   │   │   │   │   │   │   ├─ [  2.05%] __GI___pthread_mutex_lock
│   │               │       │   │   │   │   │   │   │   └─ [  0.50%] __GI___pthread_mutex_trylock
│   │               │       │   │   │   │   │   │   └─ [  1.05%] heap_classrepr_free
│   │               │       │   │   │   │   │   │       ├─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │               │       │   │   │   │   │   │       │   └─ [  0.28%] __lll_unlock_wake
│   │               │       │   │   │   │   │   │       └─ [  2.05%] __GI___pthread_mutex_lock
│   │               │       │   │   │   │   │   └─ [  0.30%] btree_get_pkey_btid
│   │               │       │   │   │   │   │       ├─ [  1.51%] heap_classrepr_get
│   │               │       │   │   │   │   │       │   ├─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │               │       │   │   │   │   │       │   │   └─ [  0.28%] __lll_unlock_wake
│   │               │       │   │   │   │   │       │   ├─ [  2.05%] __GI___pthread_mutex_lock
│   │               │       │   │   │   │   │       │   └─ [  0.50%] __GI___pthread_mutex_trylock
│   │               │       │   │   │   │   │       └─ [  1.05%] heap_classrepr_free
│   │               │       │   │   │   │   │           ├─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │               │       │   │   │   │   │           │   └─ [  0.28%] __lll_unlock_wake
│   │               │       │   │   │   │   │           └─ [  2.05%] __GI___pthread_mutex_lock
│   │               │       │   │   │   │   ├─ [  1.37%] xtran_server_end_topop
│   │               │       │   │   │   │   │   ├─ [  0.62%] log_sysop_attach_to_outer
│   │               │       │   │   │   │   │   │   ├─ [  0.38%] log_tdes::unlock_topop
│   │               │       │   │   │   │   │   │   │   └─ [  0.38%] cubpl::get_session
│   │               │       │   │   │   │   │   │   │       ├─ [  0.27%] session_get_pl_session
│   │               │       │   │   │   │   │   │   │       └─ [  0.29%] thread_get_thread_entry_info
│   │               │       │   │   │   │   │   │   │           └─ [  0.23%] cubthread::get_entry
│   │               │       │   │   │   │   │   │   │               └─ [  0.21%] __tls_get_addr
│   │               │       │   │   │   │   │   │   └─ [  0.24%] rmutex_unlock
│   │               │       │   │   │   │   │   │       ├─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │               │       │   │   │   │   │   │       │   └─ [  0.28%] __lll_unlock_wake
│   │               │       │   │   │   │   │   │       └─ [  0.29%] thread_get_thread_entry_info
│   │               │       │   │   │   │   │   │           └─ [  0.23%] cubthread::get_entry
│   │               │       │   │   │   │   │   │               └─ [  0.21%] __tls_get_addr
│   │               │       │   │   │   │   │   ├─ [  0.34%] cuberr::context::pop_error_stack_and_destroy
│   │               │       │   │   │   │   │   └─ [  0.23%] cuberr::context::push_error_stack
│   │               │       │   │   │   │   │       └─ [  0.51%] operator new
│   │               │       │   │   │   │   │           ├─ [  2.03%] __GI___libc_malloc
│   │               │       │   │   │   │   │           │   └─ [  1.59%] _int_malloc
│   │               │       │   │   │   │   │           │       ├─ [  0.58%] malloc_consolidate
│   │               │       │   │   │   │   │           │       │   └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │   │           │       └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │   │           └─ [  1.66%] cub_alloc
│   │               │       │   │   │   │   │               └─ [  2.03%] __GI___libc_malloc
│   │               │       │   │   │   │   │                   └─ [  1.59%] _int_malloc
│   │               │       │   │   │   │   │                       ├─ [  0.58%] malloc_consolidate
│   │               │       │   │   │   │   │                       │   └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │   │                       └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │   ├─ [  0.58%] xtran_server_start_topop
│   │               │       │   │   │   │   │   └─ [  0.47%] log_sysop_start
│   │               │       │   │   │   │   │       ├─ [  0.21%] log_tdes::lock_topop
│   │               │       │   │   │   │   │       │   └─ [  0.38%] cubpl::get_session
│   │               │       │   │   │   │   │       │       ├─ [  0.27%] session_get_pl_session
│   │               │       │   │   │   │   │       │       └─ [  0.29%] thread_get_thread_entry_info
│   │               │       │   │   │   │   │       │           └─ [  0.23%] cubthread::get_entry
│   │               │       │   │   │   │   │       │               └─ [  0.21%] __tls_get_addr
│   │               │       │   │   │   │   │       ├─ [  0.67%] rmutex_lock
│   │               │       │   │   │   │   │       │   ├─ [  2.05%] __GI___pthread_mutex_lock
│   │               │       │   │   │   │   │       │   └─ [  0.29%] thread_get_thread_entry_info
│   │               │       │   │   │   │   │       │       └─ [  0.23%] cubthread::get_entry
│   │               │       │   │   │   │   │       │           └─ [  0.21%] __tls_get_addr
│   │               │       │   │   │   │   │       └─ [  0.68%] LOG_FIND_TDES
│   │               │       │   │   │   │   ├─ [  0.53%] heap_get_class_info
│   │               │       │   │   │   │   │   └─ [  0.51%] heap_hfid_cache_get
│   │               │       │   │   │   │   │       └─ [  3.38%] lf_hash_insert_internal
│   │               │       │   │   │   │   │           └─ [  2.90%] lf_list_insert_internal
│   │               │       │   │   │   │   │               ├─ [  2.26%] lock_res_key_compare
│   │               │       │   │   │   │   │               ├─ [  0.92%] lf_freelist_claim
│   │               │       │   │   │   │   │               │   ├─ [  0.35%] lf_stack_pop
│   │               │       │   │   │   │   │               │   ├─ [  0.26%] lf_freelist_alloc_block
│   │               │       │   │   │   │   │               │   │   └─ [  2.03%] __GI___libc_malloc
│   │               │       │   │   │   │   │               │   │       └─ [  1.59%] _int_malloc
│   │               │       │   │   │   │   │               │   │           ├─ [  0.58%] malloc_consolidate
│   │               │       │   │   │   │   │               │   │           │   └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │   │               │   │           └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │   │               │   ├─ [  0.22%] ATOMIC_INC_32<int, int>
│   │               │       │   │   │   │   │               │   └─ [  0.54%] lf_freelist_transport
│   │               │       │   │   │   │   │               │       └─ [  0.47%] lock_dealloc_entry
│   │               │       │   │   │   │   │               │           └─ [  0.79%] _int_free
│   │               │       │   │   │   │   │               │               ├─ [  0.58%] malloc_consolidate
│   │               │       │   │   │   │   │               │               │   └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │   │               │               └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │   │               └─ [  2.05%] __GI___pthread_mutex_lock
│   │               │       │   │   │   │   ├─ [  0.34%] heap_scancache_start_modify
│   │               │       │   │   │   │   │   └─ [  0.22%] file_get_type
│   │               │       │   │   │   │   │       ├─ [  3.26%] pgbuf_fix_release
│   │               │       │   │   │   │   │       │   ├─ [  0.85%] pgbuf_set_bcb_page_vpid
│   │               │       │   │   │   │   │       │   ├─ [  0.38%] pgbuf_search_hash_chain
│   │               │       │   │   │   │   │       │   │   └─ [  0.50%] __GI___pthread_mutex_trylock
│   │               │       │   │   │   │   │       │   ├─ [  0.31%] pgbuf_latch_bcb_upon_fix
│   │               │       │   │   │   │   │       │   └─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │               │       │   │   │   │   │       │       └─ [  0.28%] __lll_unlock_wake
│   │               │       │   │   │   │   │       └─ [  2.18%] pgbuf_unfix
│   │               │       │   │   │   │   │           ├─ [  1.23%] pgbuf_unlatch_bcb_upon_unfix
│   │               │       │   │   │   │   │           │   └─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │               │       │   │   │   │   │           │       └─ [  0.28%] __lll_unlock_wake
│   │               │       │   │   │   │   │           ├─ [  2.05%] __GI___pthread_mutex_lock
│   │               │       │   │   │   │   │           └─ [  0.26%] pgbuf_lru_move_from_private_to_shared
│   │               │       │   │   │   │   │               └─ [  2.05%] __GI___pthread_mutex_lock
│   │               │       │   │   │   │   ├─ [  0.24%] or_unpack_mem_value
│   │               │       │   │   │   │   └─ [  0.47%] heap_scancache_quick_end
│   │               │       │   │   │   │       └─ [  2.18%] pgbuf_unfix
│   │               │       │   │   │   │           ├─ [  1.23%] pgbuf_unlatch_bcb_upon_unfix
│   │               │       │   │   │   │           │   └─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │               │       │   │   │   │           │       └─ [  0.28%] __lll_unlock_wake
│   │               │       │   │   │   │           ├─ [  2.05%] __GI___pthread_mutex_lock
│   │               │       │   │   │   │           └─ [  0.26%] pgbuf_lru_move_from_private_to_shared
│   │               │       │   │   │   │               └─ [  2.05%] __GI___pthread_mutex_lock
│   │               │       │   │   │   ├─ [  1.17%] css_send_reply_and_2_data_to_client
│   │               │       │   │   │   │   ├─ [  0.91%] css_enqueue_and_notify
│   │               │       │   │   │   │   │   ├─ [  0.85%] cubconn::connection::worker::enqueue_and_notify
│   │               │       │   │   │   │   │   │   ├─ [  0.77%] cubconn::connection::worker::notify
│   │               │       │   │   │   │   │   │   │   └─ [  0.77%] __libc_write
│   │               │       │   │   │   │   │   │   └─ [  0.95%] cubconn::connection::worker::enqueue
│   │               │       │   │   │   │   │   │       └─ [  0.59%] tbb::detail::d2::micro_queue<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >::prepare_page(unsigned long, tbb::detail::d2::concurrent_queue_rep<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >&, tbb::detail::d1::cache_aligned_allocator<tbb::detail::d2::micro_queue<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >::padded_page>, tbb::detail::d2::micro_queue<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >::padded_page*&)::{lambda()#1}::operator()
│   │               │       │   │   │   │   │   │           └─ [  0.60%] tbb::detail::r1::cache_aligned_allocate
│   │               │       │   │   │   │   │   │               └─ [  0.57%] _mid_memalign
│   │               │       │   │   │   │   │   │                   └─ [  0.50%] _int_memalign
│   │               │       │   │   │   │   │   │                       ├─ [  1.59%] _int_malloc
│   │               │       │   │   │   │   │   │                       │   ├─ [  0.58%] malloc_consolidate
│   │               │       │   │   │   │   │   │                       │   │   └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │   │   │                       │   └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │   │   │                       └─ [  0.79%] _int_free
│   │               │       │   │   │   │   │   │                           ├─ [  0.58%] malloc_consolidate
│   │               │       │   │   │   │   │   │                           │   └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │   │   │                           └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │   │   └─ [  0.67%] rmutex_lock
│   │               │       │   │   │   │   │       ├─ [  2.05%] __GI___pthread_mutex_lock
│   │               │       │   │   │   │   │       └─ [  0.29%] thread_get_thread_entry_info
│   │               │       │   │   │   │   │           └─ [  0.23%] cubthread::get_entry
│   │               │       │   │   │   │   │               └─ [  0.21%] __tls_get_addr
│   │               │       │   │   │   │   ├─ [  0.67%] rmutex_lock
│   │               │       │   │   │   │   │   ├─ [  2.05%] __GI___pthread_mutex_lock
│   │               │       │   │   │   │   │   └─ [  0.29%] thread_get_thread_entry_info
│   │               │       │   │   │   │   │       └─ [  0.23%] cubthread::get_entry
│   │               │       │   │   │   │   │           └─ [  0.21%] __tls_get_addr
│   │               │       │   │   │   │   └─ [  0.51%] operator new
│   │               │       │   │   │   │       ├─ [  2.03%] __GI___libc_malloc
│   │               │       │   │   │   │       │   └─ [  1.59%] _int_malloc
│   │               │       │   │   │   │       │       ├─ [  0.58%] malloc_consolidate
│   │               │       │   │   │   │       │       │   └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │       │       └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │       └─ [  1.66%] cub_alloc
│   │               │       │   │   │   │           └─ [  2.03%] __GI___libc_malloc
│   │               │       │   │   │   │               └─ [  1.59%] _int_malloc
│   │               │       │   │   │   │                   ├─ [  0.58%] malloc_consolidate
│   │               │       │   │   │   │                   │   └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │                   └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   ├─ [  1.01%] css_request_release_packet
│   │               │       │   │   │   │   ├─ [  0.95%] cubconn::connection::worker::enqueue
│   │               │       │   │   │   │   │   └─ [  0.59%] tbb::detail::d2::micro_queue<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >::prepare_page(unsigned long, tbb::detail::d2::concurrent_queue_rep<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >&, tbb::detail::d1::cache_aligned_allocator<tbb::detail::d2::micro_queue<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >::padded_page>, tbb::detail::d2::micro_queue<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >::padded_page*&)::{lambda()#1}::operator()
│   │               │       │   │   │   │   │       └─ [  0.60%] tbb::detail::r1::cache_aligned_allocate
│   │               │       │   │   │   │   │           └─ [  0.57%] _mid_memalign
│   │               │       │   │   │   │   │               └─ [  0.50%] _int_memalign
│   │               │       │   │   │   │   │                   ├─ [  1.59%] _int_malloc
│   │               │       │   │   │   │   │                   │   ├─ [  0.58%] malloc_consolidate
│   │               │       │   │   │   │   │                   │   │   └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │   │                   │   └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │   │                   └─ [  0.79%] _int_free
│   │               │       │   │   │   │   │                       ├─ [  0.58%] malloc_consolidate
│   │               │       │   │   │   │   │                       │   └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │   │                       └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │   │   ├─ [  0.67%] rmutex_lock
│   │               │       │   │   │   │   │   ├─ [  2.05%] __GI___pthread_mutex_lock
│   │               │       │   │   │   │   │   └─ [  0.29%] thread_get_thread_entry_info
│   │               │       │   │   │   │   │       └─ [  0.23%] cubthread::get_entry
│   │               │       │   │   │   │   │           └─ [  0.21%] __tls_get_addr
│   │               │       │   │   │   │   └─ [  0.24%] rmutex_unlock
│   │               │       │   │   │   │       ├─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │               │       │   │   │   │       │   └─ [  0.28%] __lll_unlock_wake
│   │               │       │   │   │   │       └─ [  0.29%] thread_get_thread_entry_info
│   │               │       │   │   │   │           └─ [  0.23%] cubthread::get_entry
│   │               │       │   │   │   │               └─ [  0.21%] __tls_get_addr
│   │               │       │   │   │   ├─ [  4.68%] __memmove_evex_unaligned_erms
│   │               │       │   │   │   └─ [  0.35%] css_receive_data_from_client_with_timeout
│   │               │       │   │   │       └─ [  0.41%] css_receive_data
│   │               │       │   │   │           ├─ [  0.31%] css_return_queued_data_timeout
│   │               │       │   │   │           │   ├─ [  0.67%] rmutex_lock
│   │               │       │   │   │           │   │   ├─ [  2.05%] __GI___pthread_mutex_lock
│   │               │       │   │   │           │   │   └─ [  0.29%] thread_get_thread_entry_info
│   │               │       │   │   │           │   │       └─ [  0.23%] cubthread::get_entry
│   │               │       │   │   │           │   │           └─ [  0.21%] __tls_get_addr
│   │               │       │   │   │           │   └─ [  0.24%] rmutex_unlock
│   │               │       │   │   │           │       ├─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │               │       │   │   │           │       │   └─ [  0.28%] __lll_unlock_wake
│   │               │       │   │   │           │       └─ [  0.29%] thread_get_thread_entry_info
│   │               │       │   │   │           │           └─ [  0.23%] cubthread::get_entry
│   │               │       │   │   │           │               └─ [  0.21%] __tls_get_addr
│   │               │       │   │   │           └─ [  1.66%] cub_alloc
│   │               │       │   │   │               └─ [  2.03%] __GI___libc_malloc
│   │               │       │   │   │                   └─ [  1.59%] _int_malloc
│   │               │       │   │   │                       ├─ [  0.58%] malloc_consolidate
│   │               │       │   │   │                       │   └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │                       └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   ├─ [  0.37%] slogwr_get_log_pages
│   │               │       │   │   │   └─ [  0.37%] xlogwr_get_log_pages
│   │               │       │   │   └─ [  1.01%] css_request_release_packet
│   │               │       │   │       ├─ [  0.95%] cubconn::connection::worker::enqueue
│   │               │       │   │       │   └─ [  0.59%] tbb::detail::d2::micro_queue<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >::prepare_page(unsigned long, tbb::detail::d2::concurrent_queue_rep<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >&, tbb::detail::d1::cache_aligned_allocator<tbb::detail::d2::micro_queue<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >::padded_page>, tbb::detail::d2::micro_queue<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >::padded_page*&)::{lambda()#1}::operator()
│   │               │       │   │       │       └─ [  0.60%] tbb::detail::r1::cache_aligned_allocate
│   │               │       │   │       │           └─ [  0.57%] _mid_memalign
│   │               │       │   │       │               └─ [  0.50%] _int_memalign
│   │               │       │   │       │                   ├─ [  1.59%] _int_malloc
│   │               │       │   │       │                   │   ├─ [  0.58%] malloc_consolidate
│   │               │       │   │       │                   │   │   └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │       │                   │   └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │       │                   └─ [  0.79%] _int_free
│   │               │       │   │       │                       ├─ [  0.58%] malloc_consolidate
│   │               │       │   │       │                       │   └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │       │                       └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │       ├─ [  0.67%] rmutex_lock
│   │               │       │   │       │   ├─ [  2.05%] __GI___pthread_mutex_lock
│   │               │       │   │       │   └─ [  0.29%] thread_get_thread_entry_info
│   │               │       │   │       │       └─ [  0.23%] cubthread::get_entry
│   │               │       │   │       │           └─ [  0.21%] __tls_get_addr
│   │               │       │   │       └─ [  0.24%] rmutex_unlock
│   │               │       │   │           ├─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │               │       │   │           │   └─ [  0.28%] __lll_unlock_wake
│   │               │       │   │           └─ [  0.29%] thread_get_thread_entry_info
│   │               │       │   │               └─ [  0.23%] cubthread::get_entry
│   │               │       │   │                   └─ [  0.21%] __tls_get_addr
│   │               │       │   └─ [  0.41%] css_receive_data
│   │               │       │       ├─ [  0.31%] css_return_queued_data_timeout
│   │               │       │       │   ├─ [  0.67%] rmutex_lock
│   │               │       │       │   │   ├─ [  2.05%] __GI___pthread_mutex_lock
│   │               │       │       │   │   └─ [  0.29%] thread_get_thread_entry_info
│   │               │       │       │   │       └─ [  0.23%] cubthread::get_entry
│   │               │       │       │   │           └─ [  0.21%] __tls_get_addr
│   │               │       │       │   └─ [  0.24%] rmutex_unlock
│   │               │       │       │       ├─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │               │       │       │       │   └─ [  0.28%] __lll_unlock_wake
│   │               │       │       │       └─ [  0.29%] thread_get_thread_entry_info
│   │               │       │       │           └─ [  0.23%] cubthread::get_entry
│   │               │       │       │               └─ [  0.21%] __tls_get_addr
│   │               │       │       └─ [  1.66%] cub_alloc
│   │               │       │           └─ [  2.03%] __GI___libc_malloc
│   │               │       │               └─ [  1.59%] _int_malloc
│   │               │       │                   ├─ [  0.58%] malloc_consolidate
│   │               │       │                   │   └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │                   └─ [  0.37%] unlink_chunk.isra.2
│   │               │       ├─ [  0.57%] css_return_queued_request
│   │               │       │   ├─ [  1.01%] css_request_release_packet
│   │               │       │   │   ├─ [  0.95%] cubconn::connection::worker::enqueue
│   │               │       │   │   │   └─ [  0.59%] tbb::detail::d2::micro_queue<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >::prepare_page(unsigned long, tbb::detail::d2::concurrent_queue_rep<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >&, tbb::detail::d1::cache_aligned_allocator<tbb::detail::d2::micro_queue<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >::padded_page>, tbb::detail::d2::micro_queue<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >::padded_page*&)::{lambda()#1}::operator()
│   │               │       │   │   │       └─ [  0.60%] tbb::detail::r1::cache_aligned_allocate
│   │               │       │   │   │           └─ [  0.57%] _mid_memalign
│   │               │       │   │   │               └─ [  0.50%] _int_memalign
│   │               │       │   │   │                   ├─ [  1.59%] _int_malloc
│   │               │       │   │   │                   │   ├─ [  0.58%] malloc_consolidate
│   │               │       │   │   │                   │   │   └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │                   │   └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │                   └─ [  0.79%] _int_free
│   │               │       │   │   │                       ├─ [  0.58%] malloc_consolidate
│   │               │       │   │   │                       │   └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   │                       └─ [  0.37%] unlink_chunk.isra.2
│   │               │       │   │   ├─ [  0.67%] rmutex_lock
│   │               │       │   │   │   ├─ [  2.05%] __GI___pthread_mutex_lock
│   │               │       │   │   │   └─ [  0.29%] thread_get_thread_entry_info
│   │               │       │   │   │       └─ [  0.23%] cubthread::get_entry
│   │               │       │   │   │           └─ [  0.21%] __tls_get_addr
│   │               │       │   │   └─ [  0.24%] rmutex_unlock
│   │               │       │   │       ├─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │               │       │   │       │   └─ [  0.28%] __lll_unlock_wake
│   │               │       │   │       └─ [  0.29%] thread_get_thread_entry_info
│   │               │       │   │           └─ [  0.23%] cubthread::get_entry
│   │               │       │   │               └─ [  0.21%] __tls_get_addr
│   │               │       │   └─ [  0.67%] rmutex_lock
│   │               │       │       ├─ [  2.05%] __GI___pthread_mutex_lock
│   │               │       │       └─ [  0.29%] thread_get_thread_entry_info
│   │               │       │           └─ [  0.23%] cubthread::get_entry
│   │               │       │               └─ [  0.21%] __tls_get_addr
│   │               │       └─ [  0.20%] css_wakeup_handler
│   │               │           ├─ [  0.77%] cubconn::connection::worker::notify
│   │               │           │   └─ [  0.77%] __libc_write
│   │               │           └─ [  0.67%] rmutex_lock
│   │               │               ├─ [  2.05%] __GI___pthread_mutex_lock
│   │               │               └─ [  0.29%] thread_get_thread_entry_info
│   │               │                   └─ [  0.23%] cubthread::get_entry
│   │               │                       └─ [  0.21%] __tls_get_addr
│   │               └─ [  2.78%] cubthread::worker_pool::core::worker::get_new_task
│   │                   └─ [  2.53%] __pthread_cond_timedwait
│   ├─ [ 22.96%] locator_update_force
│   │   ├─ [ 16.47%] heap_update_logical
│   │   │   ├─ [ 22.00%] heap_log_update_physical
│   │   │   │   ├─ [ 26.25%] log_append_undoredo_recdes
│   │   │   │   │   └─ [ 27.13%] log_append_undoredo_recdes2
│   │   │   │   │       └─ [ 27.14%] log_append_undoredo_crumbs
│   │   │   │   │           ├─ [ 25.73%] prior_lsa_alloc_and_copy_crumbs
│   │   │   │   │           │   ├─ [ 16.06%] prior_lsa_gen_undoredo_record_from_crumbs
│   │   │   │   │           │   │   ├─ [ 18.41%] log_zip
│   │   │   │   │           │   │   │   ├─ [ 16.65%] LZ4_compress_fast_extState
│   │   │   │   │           │   │   │   │   ├─ [  3.90%] LZ4_read_ARCH
│   │   │   │   │           │   │   │   │   ├─ [  1.16%] LZ4_read32
│   │   │   │   │           │   │   │   │   └─ [  0.79%] LZ4_initStream
│   │   │   │   │           │   │   │   │       └─ [  1.91%] __memset_evex_unaligned_erms
│   │   │   │   │           │   │   │   ├─ [  1.31%] LZ4_resetStream_fast
│   │   │   │   │           │   │   │   │   └─ [  1.91%] __memset_evex_unaligned_erms
│   │   │   │   │           │   │   │   ├─ [  0.21%] __tls_get_addr
│   │   │   │   │           │   │   │   ├─ [  1.16%] LZ4_read32
│   │   │   │   │           │   │   │   └─ [  3.90%] LZ4_read_ARCH
│   │   │   │   │           │   │   ├─ [  5.36%] log_diff
│   │   │   │   │           │   │   ├─ [  4.68%] __memmove_evex_unaligned_erms
│   │   │   │   │           │   │   └─ [  1.66%] cub_alloc
│   │   │   │   │           │   │       └─ [  2.03%] __GI___libc_malloc
│   │   │   │   │           │   │           └─ [  1.59%] _int_malloc
│   │   │   │   │           │   │               ├─ [  0.58%] malloc_consolidate
│   │   │   │   │           │   │               │   └─ [  0.37%] unlink_chunk.isra.2
│   │   │   │   │           │   │               └─ [  0.37%] unlink_chunk.isra.2
│   │   │   │   │           │   ├─ [ 18.41%] log_zip
│   │   │   │   │           │   │   ├─ [ 16.65%] LZ4_compress_fast_extState
│   │   │   │   │           │   │   │   ├─ [  3.90%] LZ4_read_ARCH
│   │   │   │   │           │   │   │   ├─ [  1.16%] LZ4_read32
│   │   │   │   │           │   │   │   └─ [  0.79%] LZ4_initStream
│   │   │   │   │           │   │   │       └─ [  1.91%] __memset_evex_unaligned_erms
│   │   │   │   │           │   │   ├─ [  1.31%] LZ4_resetStream_fast
│   │   │   │   │           │   │   │   └─ [  1.91%] __memset_evex_unaligned_erms
│   │   │   │   │           │   │   ├─ [  0.21%] __tls_get_addr
│   │   │   │   │           │   │   ├─ [  1.16%] LZ4_read32
│   │   │   │   │           │   │   └─ [  3.90%] LZ4_read_ARCH
│   │   │   │   │           │   ├─ [  1.66%] cub_alloc
│   │   │   │   │           │   │   └─ [  2.03%] __GI___libc_malloc
│   │   │   │   │           │   │       └─ [  1.59%] _int_malloc
│   │   │   │   │           │   │           ├─ [  0.58%] malloc_consolidate
│   │   │   │   │           │   │           │   └─ [  0.37%] unlink_chunk.isra.2
│   │   │   │   │           │   │           └─ [  0.37%] unlink_chunk.isra.2
│   │   │   │   │           │   ├─ [  0.28%] prior_lsa_copy_undo_data_to_node
│   │   │   │   │           │   │   ├─ [  1.66%] cub_alloc
│   │   │   │   │           │   │   │   └─ [  2.03%] __GI___libc_malloc
│   │   │   │   │           │   │   │       └─ [  1.59%] _int_malloc
│   │   │   │   │           │   │   │           ├─ [  0.58%] malloc_consolidate
│   │   │   │   │           │   │   │           │   └─ [  0.37%] unlink_chunk.isra.2
│   │   │   │   │           │   │   │           └─ [  0.37%] unlink_chunk.isra.2
│   │   │   │   │           │   │   └─ [  4.68%] __memmove_evex_unaligned_erms
│   │   │   │   │           │   └─ [  0.27%] prior_lsa_copy_redo_data_to_node
│   │   │   │   │           │       └─ [  1.66%] cub_alloc
│   │   │   │   │           │           └─ [  2.03%] __GI___libc_malloc
│   │   │   │   │           │               └─ [  1.59%] _int_malloc
│   │   │   │   │           │                   ├─ [  0.58%] malloc_consolidate
│   │   │   │   │           │                   │   └─ [  0.37%] unlink_chunk.isra.2
│   │   │   │   │           │                   └─ [  0.37%] unlink_chunk.isra.2
│   │   │   │   │           ├─ [  0.81%] prior_lsa_next_record_internal
│   │   │   │   │           │   ├─ [  2.05%] __GI___pthread_mutex_lock
│   │   │   │   │           │   └─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │   │   │   │           │       └─ [  0.28%] __lll_unlock_wake
│   │   │   │   │           └─ [  0.27%] pgbuf_set_lsa
│   │   │   │   └─ [  0.27%] heap_page_update_chain_after_mvcc_op
│   │   │   │       └─ [  0.57%] spage_get_record
│   │   │   │           └─ [  0.38%] spage_find_slot
│   │   │   ├─ [  4.49%] heap_update_home
│   │   │   │   └─ [  0.64%] spage_is_updatable
│   │   │   │       └─ [  0.96%] spage_check_updatable
│   │   │   │           ├─ [  0.87%] spage_has_enough_total_space
│   │   │   │           │   └─ [  0.68%] spage_get_total_saved_spaces
│   │   │   │           │       └─ [  0.63%] spage_get_saved_spaces
│   │   │   │           │           └─ [  0.56%] lf_hash_find
│   │   │   │           │               └─ [  0.31%] lf_list_find
│   │   │   │           └─ [  0.38%] spage_find_slot
│   │   │   │               └─ [  0.57%] spage_get_record
│   │   │   ├─ [  3.48%] spage_update
│   │   │   │   ├─ [  3.00%] spage_update_record_after_compact
│   │   │   │   │   ├─ [  1.95%] spage_compact
│   │   │   │   │   │   └─ [  4.68%] __memmove_evex_unaligned_erms
│   │   │   │   │   └─ [  4.68%] __memmove_evex_unaligned_erms
│   │   │   │   └─ [  0.96%] spage_check_updatable
│   │   │   │       ├─ [  0.87%] spage_has_enough_total_space
│   │   │   │       │   └─ [  0.68%] spage_get_total_saved_spaces
│   │   │   │       │       └─ [  0.63%] spage_get_saved_spaces
│   │   │   │       │           └─ [  0.56%] lf_hash_find
│   │   │   │       │               └─ [  0.31%] lf_list_find
│   │   │   │       └─ [  0.38%] spage_find_slot
│   │   │   │           └─ [  0.57%] spage_get_record
│   │   │   ├─ [  2.18%] pgbuf_unfix
│   │   │   │   ├─ [  1.23%] pgbuf_unlatch_bcb_upon_unfix
│   │   │   │   │   └─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │   │   │   │       └─ [  0.28%] __lll_unlock_wake
│   │   │   │   ├─ [  2.05%] __GI___pthread_mutex_lock
│   │   │   │   └─ [  0.26%] pgbuf_lru_move_from_private_to_shared
│   │   │   │       └─ [  2.05%] __GI___pthread_mutex_lock
│   │   │   └─ [  1.69%] spage_get_record_data
│   │   │       └─ [  4.68%] __memmove_evex_unaligned_erms
│   │   ├─ [  5.30%] locator_lock_and_get_object_with_evaluation
│   │   │   ├─ [  4.47%] locator_lock_and_get_object_internal
│   │   │   │   ├─ [  7.00%] lock_object
│   │   │   │   │   ├─ [  6.36%] lock_internal_perform_lock_object
│   │   │   │   │   │   ├─ [  3.12%] cubthread::lockfree_hashmap<lk_res_key, lk_res>::find_or_insert
│   │   │   │   │   │   │   └─ [  3.38%] lf_hash_insert_internal
│   │   │   │   │   │   │       └─ [  2.90%] lf_list_insert_internal
│   │   │   │   │   │   │           ├─ [  2.26%] lock_res_key_compare
│   │   │   │   │   │   │           ├─ [  0.92%] lf_freelist_claim
│   │   │   │   │   │   │           │   ├─ [  0.35%] lf_stack_pop
│   │   │   │   │   │   │           │   ├─ [  0.26%] lf_freelist_alloc_block
│   │   │   │   │   │   │           │   │   └─ [  2.03%] __GI___libc_malloc
│   │   │   │   │   │   │           │   │       └─ [  1.59%] _int_malloc
│   │   │   │   │   │   │           │   │           ├─ [  0.58%] malloc_consolidate
│   │   │   │   │   │   │           │   │           │   └─ [  0.37%] unlink_chunk.isra.2
│   │   │   │   │   │   │           │   │           └─ [  0.37%] unlink_chunk.isra.2
│   │   │   │   │   │   │           │   ├─ [  0.22%] ATOMIC_INC_32<int, int>
│   │   │   │   │   │   │           │   └─ [  0.54%] lf_freelist_transport
│   │   │   │   │   │   │           │       └─ [  0.47%] lock_dealloc_entry
│   │   │   │   │   │   │           │           └─ [  0.79%] _int_free
│   │   │   │   │   │   │           │               ├─ [  0.58%] malloc_consolidate
│   │   │   │   │   │   │           │               │   └─ [  0.37%] unlink_chunk.isra.2
│   │   │   │   │   │   │           │               └─ [  0.37%] unlink_chunk.isra.2
│   │   │   │   │   │   │           └─ [  2.05%] __GI___pthread_mutex_lock
│   │   │   │   │   │   ├─ [  1.98%] lock_escalate_if_needed
│   │   │   │   │   │   │   └─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │   │   │   │   │   │       └─ [  0.28%] __lll_unlock_wake
│   │   │   │   │   │   ├─ [  1.91%] lock_remove_all_inst_locks
│   │   │   │   │   │   │   ├─ [  0.95%] lock_remove_resource
│   │   │   │   │   │   │   │   └─ [  0.95%] lf_hash_delete_already_locked
│   │   │   │   │   │   │   │       └─ [  0.90%] lf_list_delete
│   │   │   │   │   │   │   │           ├─ [  2.26%] lock_res_key_compare
│   │   │   │   │   │   │   │           └─ [  0.67%] lf_freelist_retire
│   │   │   │   │   │   │   │               ├─ [  0.54%] lf_freelist_transport
│   │   │   │   │   │   │   │               │   └─ [  0.47%] lock_dealloc_entry
│   │   │   │   │   │   │   │               │       └─ [  0.79%] _int_free
│   │   │   │   │   │   │   │               │           ├─ [  0.58%] malloc_consolidate
│   │   │   │   │   │   │   │               │           │   └─ [  0.37%] unlink_chunk.isra.2
│   │   │   │   │   │   │   │               │           └─ [  0.37%] unlink_chunk.isra.2
│   │   │   │   │   │   │   │               └─ [  0.22%] ATOMIC_INC_32<int, int>
│   │   │   │   │   │   │   └─ [  0.76%] lock_internal_perform_unlock_object
│   │   │   │   │   │   │       ├─ [  0.67%] lf_freelist_retire
│   │   │   │   │   │   │       │   ├─ [  0.54%] lf_freelist_transport
│   │   │   │   │   │   │       │   │   └─ [  0.47%] lock_dealloc_entry
│   │   │   │   │   │   │       │   │       └─ [  0.79%] _int_free
│   │   │   │   │   │   │       │   │           ├─ [  0.58%] malloc_consolidate
│   │   │   │   │   │   │       │   │           │   └─ [  0.37%] unlink_chunk.isra.2
│   │   │   │   │   │   │       │   │           └─ [  0.37%] unlink_chunk.isra.2
│   │   │   │   │   │   │       │   └─ [  0.22%] ATOMIC_INC_32<int, int>
│   │   │   │   │   │   │       ├─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │   │   │   │   │   │       │   └─ [  0.28%] __lll_unlock_wake
│   │   │   │   │   │   │       └─ [  2.05%] __GI___pthread_mutex_lock
│   │   │   │   │   │   ├─ [  0.92%] lf_freelist_claim
│   │   │   │   │   │   │   ├─ [  0.35%] lf_stack_pop
│   │   │   │   │   │   │   ├─ [  0.26%] lf_freelist_alloc_block
│   │   │   │   │   │   │   │   └─ [  2.03%] __GI___libc_malloc
│   │   │   │   │   │   │   │       └─ [  1.59%] _int_malloc
│   │   │   │   │   │   │   │           ├─ [  0.58%] malloc_consolidate
│   │   │   │   │   │   │   │           │   └─ [  0.37%] unlink_chunk.isra.2
│   │   │   │   │   │   │   │           └─ [  0.37%] unlink_chunk.isra.2
│   │   │   │   │   │   │   ├─ [  0.22%] ATOMIC_INC_32<int, int>
│   │   │   │   │   │   │   └─ [  0.54%] lf_freelist_transport
│   │   │   │   │   │   │       └─ [  0.47%] lock_dealloc_entry
│   │   │   │   │   │   │           └─ [  0.79%] _int_free
│   │   │   │   │   │   │               ├─ [  0.58%] malloc_consolidate
│   │   │   │   │   │   │               │   └─ [  0.37%] unlink_chunk.isra.2
│   │   │   │   │   │   │               └─ [  0.37%] unlink_chunk.isra.2
│   │   │   │   │   │   ├─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │   │   │   │   │   │   └─ [  0.28%] __lll_unlock_wake
│   │   │   │   │   │   ├─ [  0.26%] lock_find_class_entry
│   │   │   │   │   │   │   ├─ [  2.05%] __GI___pthread_mutex_lock
│   │   │   │   │   │   │   └─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │   │   │   │   │   │       └─ [  0.28%] __lll_unlock_wake
│   │   │   │   │   │   └─ [  2.05%] __GI___pthread_mutex_lock
│   │   │   │   │   ├─ [  0.28%] lock_get_class_lock
│   │   │   │   │   │   ├─ [  2.05%] __GI___pthread_mutex_lock
│   │   │   │   │   │   └─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │   │   │   │   │       └─ [  0.28%] __lll_unlock_wake
│   │   │   │   │   └─ [  0.26%] lock_find_class_entry
│   │   │   │   │       ├─ [  2.05%] __GI___pthread_mutex_lock
│   │   │   │   │       └─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │   │   │   │           └─ [  0.28%] __lll_unlock_wake
│   │   │   │   └─ [  1.78%] heap_get_last_version
│   │   │   │       ├─ [  1.49%] heap_get_record_data_when_all_ready
│   │   │   │       │   ├─ [  1.69%] spage_get_record_data
│   │   │   │       │   │   └─ [  4.68%] __memmove_evex_unaligned_erms
│   │   │   │       │   └─ [  0.57%] spage_get_record
│   │   │   │       │       └─ [  0.38%] spage_find_slot
│   │   │   │       └─ [  0.92%] heap_prepare_get_context
│   │   │   ├─ [  0.43%] heap_scan_cache_allocate_area
│   │   │   │   └─ [  0.29%] heap_scancache::reserve_area
│   │   │   │       └─ [  0.27%] heap_scancache::alloc_area
│   │   │   │           ├─ [  0.23%] cubmem::single_block_allocator::single_block_allocator
│   │   │   │           │   └─ [  0.51%] operator new
│   │   │   │           │       ├─ [  2.03%] __GI___libc_malloc
│   │   │   │           │       │   └─ [  1.59%] _int_malloc
│   │   │   │           │       │       ├─ [  0.58%] malloc_consolidate
│   │   │   │           │       │       │   └─ [  0.37%] unlink_chunk.isra.2
│   │   │   │           │       │       └─ [  0.37%] unlink_chunk.isra.2
│   │   │   │           │       └─ [  1.66%] cub_alloc
│   │   │   │           │           └─ [  2.03%] __GI___libc_malloc
│   │   │   │           │               └─ [  1.59%] _int_malloc
│   │   │   │           │                   ├─ [  0.58%] malloc_consolidate
│   │   │   │           │                   │   └─ [  0.37%] unlink_chunk.isra.2
│   │   │   │           │                   └─ [  0.37%] unlink_chunk.isra.2
│   │   │   │           └─ [  0.51%] operator new
│   │   │   │               ├─ [  2.03%] __GI___libc_malloc
│   │   │   │               │   └─ [  1.59%] _int_malloc
│   │   │   │               │       ├─ [  0.58%] malloc_consolidate
│   │   │   │               │       │   └─ [  0.37%] unlink_chunk.isra.2
│   │   │   │               │       └─ [  0.37%] unlink_chunk.isra.2
│   │   │   │               └─ [  1.66%] cub_alloc
│   │   │   │                   └─ [  2.03%] __GI___libc_malloc
│   │   │   │                       └─ [  1.59%] _int_malloc
│   │   │   │                           ├─ [  0.58%] malloc_consolidate
│   │   │   │                           │   └─ [  0.37%] unlink_chunk.isra.2
│   │   │   │                           └─ [  0.37%] unlink_chunk.isra.2
│   │   │   └─ [  1.04%] heap_clean_get_context
│   │   │       └─ [  2.18%] pgbuf_unfix
│   │   │           ├─ [  1.23%] pgbuf_unlatch_bcb_upon_unfix
│   │   │           │   └─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │   │           │       └─ [  0.28%] __lll_unlock_wake
│   │   │           ├─ [  2.05%] __GI___pthread_mutex_lock
│   │   │           └─ [  0.26%] pgbuf_lru_move_from_private_to_shared
│   │   │               └─ [  2.05%] __GI___pthread_mutex_lock
│   │   └─ [  0.83%] locator_check_foreign_key
│   │       ├─ [  1.37%] heap_attrinfo_start_with_index
│   │       │   ├─ [  1.51%] heap_classrepr_get
│   │       │   │   ├─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │       │   │   │   └─ [  0.28%] __lll_unlock_wake
│   │       │   │   ├─ [  2.05%] __GI___pthread_mutex_lock
│   │       │   │   └─ [  0.50%] __GI___pthread_mutex_trylock
│   │       │   └─ [  0.26%] heap_attrinfo_recache_attrepr
│   │       ├─ [  0.91%] heap_attrinfo_end
│   │       │   └─ [  1.05%] heap_classrepr_free
│   │       │       ├─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │       │       │   └─ [  0.28%] __lll_unlock_wake
│   │       │       └─ [  2.05%] __GI___pthread_mutex_lock
│   │       └─ [  0.65%] heap_attrinfo_read_dbvalues
│   │           └─ [  0.37%] heap_attrvalue_read
│   ├─ [ 22.00%] heap_log_update_physical
│   │   ├─ [ 26.25%] log_append_undoredo_recdes
│   │   │   └─ [ 27.13%] log_append_undoredo_recdes2
│   │   │       └─ [ 27.14%] log_append_undoredo_crumbs
│   │   │           ├─ [ 25.73%] prior_lsa_alloc_and_copy_crumbs
│   │   │           │   ├─ [ 16.06%] prior_lsa_gen_undoredo_record_from_crumbs
│   │   │           │   │   ├─ [ 18.41%] log_zip
│   │   │           │   │   │   ├─ [ 16.65%] LZ4_compress_fast_extState
│   │   │           │   │   │   │   ├─ [  3.90%] LZ4_read_ARCH
│   │   │           │   │   │   │   ├─ [  1.16%] LZ4_read32
│   │   │           │   │   │   │   └─ [  0.79%] LZ4_initStream
│   │   │           │   │   │   │       └─ [  1.91%] __memset_evex_unaligned_erms
│   │   │           │   │   │   ├─ [  1.31%] LZ4_resetStream_fast
│   │   │           │   │   │   │   └─ [  1.91%] __memset_evex_unaligned_erms
│   │   │           │   │   │   ├─ [  0.21%] __tls_get_addr
│   │   │           │   │   │   ├─ [  1.16%] LZ4_read32
│   │   │           │   │   │   └─ [  3.90%] LZ4_read_ARCH
│   │   │           │   │   ├─ [  5.36%] log_diff
│   │   │           │   │   ├─ [  4.68%] __memmove_evex_unaligned_erms
│   │   │           │   │   └─ [  1.66%] cub_alloc
│   │   │           │   │       └─ [  2.03%] __GI___libc_malloc
│   │   │           │   │           └─ [  1.59%] _int_malloc
│   │   │           │   │               ├─ [  0.58%] malloc_consolidate
│   │   │           │   │               │   └─ [  0.37%] unlink_chunk.isra.2
│   │   │           │   │               └─ [  0.37%] unlink_chunk.isra.2
│   │   │           │   ├─ [ 18.41%] log_zip
│   │   │           │   │   ├─ [ 16.65%] LZ4_compress_fast_extState
│   │   │           │   │   │   ├─ [  3.90%] LZ4_read_ARCH
│   │   │           │   │   │   ├─ [  1.16%] LZ4_read32
│   │   │           │   │   │   └─ [  0.79%] LZ4_initStream
│   │   │           │   │   │       └─ [  1.91%] __memset_evex_unaligned_erms
│   │   │           │   │   ├─ [  1.31%] LZ4_resetStream_fast
│   │   │           │   │   │   └─ [  1.91%] __memset_evex_unaligned_erms
│   │   │           │   │   ├─ [  0.21%] __tls_get_addr
│   │   │           │   │   ├─ [  1.16%] LZ4_read32
│   │   │           │   │   └─ [  3.90%] LZ4_read_ARCH
│   │   │           │   ├─ [  1.66%] cub_alloc
│   │   │           │   │   └─ [  2.03%] __GI___libc_malloc
│   │   │           │   │       └─ [  1.59%] _int_malloc
│   │   │           │   │           ├─ [  0.58%] malloc_consolidate
│   │   │           │   │           │   └─ [  0.37%] unlink_chunk.isra.2
│   │   │           │   │           └─ [  0.37%] unlink_chunk.isra.2
│   │   │           │   ├─ [  0.28%] prior_lsa_copy_undo_data_to_node
│   │   │           │   │   ├─ [  1.66%] cub_alloc
│   │   │           │   │   │   └─ [  2.03%] __GI___libc_malloc
│   │   │           │   │   │       └─ [  1.59%] _int_malloc
│   │   │           │   │   │           ├─ [  0.58%] malloc_consolidate
│   │   │           │   │   │           │   └─ [  0.37%] unlink_chunk.isra.2
│   │   │           │   │   │           └─ [  0.37%] unlink_chunk.isra.2
│   │   │           │   │   └─ [  4.68%] __memmove_evex_unaligned_erms
│   │   │           │   └─ [  0.27%] prior_lsa_copy_redo_data_to_node
│   │   │           │       └─ [  1.66%] cub_alloc
│   │   │           │           └─ [  2.03%] __GI___libc_malloc
│   │   │           │               └─ [  1.59%] _int_malloc
│   │   │           │                   ├─ [  0.58%] malloc_consolidate
│   │   │           │                   │   └─ [  0.37%] unlink_chunk.isra.2
│   │   │           │                   └─ [  0.37%] unlink_chunk.isra.2
│   │   │           ├─ [  0.81%] prior_lsa_next_record_internal
│   │   │           │   ├─ [  2.05%] __GI___pthread_mutex_lock
│   │   │           │   └─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │   │           │       └─ [  0.28%] __lll_unlock_wake
│   │   │           └─ [  0.27%] pgbuf_set_lsa
│   │   └─ [  0.27%] heap_page_update_chain_after_mvcc_op
│   │       └─ [  0.57%] spage_get_record
│   │           └─ [  0.38%] spage_find_slot
│   ├─ [ 26.25%] log_append_undoredo_recdes
│   │   └─ [ 27.13%] log_append_undoredo_recdes2
│   │       └─ [ 27.14%] log_append_undoredo_crumbs
│   │           ├─ [ 25.73%] prior_lsa_alloc_and_copy_crumbs
│   │           │   ├─ [ 16.06%] prior_lsa_gen_undoredo_record_from_crumbs
│   │           │   │   ├─ [ 18.41%] log_zip
│   │           │   │   │   ├─ [ 16.65%] LZ4_compress_fast_extState
│   │           │   │   │   │   ├─ [  3.90%] LZ4_read_ARCH
│   │           │   │   │   │   ├─ [  1.16%] LZ4_read32
│   │           │   │   │   │   └─ [  0.79%] LZ4_initStream
│   │           │   │   │   │       └─ [  1.91%] __memset_evex_unaligned_erms
│   │           │   │   │   ├─ [  1.31%] LZ4_resetStream_fast
│   │           │   │   │   │   └─ [  1.91%] __memset_evex_unaligned_erms
│   │           │   │   │   ├─ [  0.21%] __tls_get_addr
│   │           │   │   │   ├─ [  1.16%] LZ4_read32
│   │           │   │   │   └─ [  3.90%] LZ4_read_ARCH
│   │           │   │   ├─ [  5.36%] log_diff
│   │           │   │   ├─ [  4.68%] __memmove_evex_unaligned_erms
│   │           │   │   └─ [  1.66%] cub_alloc
│   │           │   │       └─ [  2.03%] __GI___libc_malloc
│   │           │   │           └─ [  1.59%] _int_malloc
│   │           │   │               ├─ [  0.58%] malloc_consolidate
│   │           │   │               │   └─ [  0.37%] unlink_chunk.isra.2
│   │           │   │               └─ [  0.37%] unlink_chunk.isra.2
│   │           │   ├─ [ 18.41%] log_zip
│   │           │   │   ├─ [ 16.65%] LZ4_compress_fast_extState
│   │           │   │   │   ├─ [  3.90%] LZ4_read_ARCH
│   │           │   │   │   ├─ [  1.16%] LZ4_read32
│   │           │   │   │   └─ [  0.79%] LZ4_initStream
│   │           │   │   │       └─ [  1.91%] __memset_evex_unaligned_erms
│   │           │   │   ├─ [  1.31%] LZ4_resetStream_fast
│   │           │   │   │   └─ [  1.91%] __memset_evex_unaligned_erms
│   │           │   │   ├─ [  0.21%] __tls_get_addr
│   │           │   │   ├─ [  1.16%] LZ4_read32
│   │           │   │   └─ [  3.90%] LZ4_read_ARCH
│   │           │   ├─ [  1.66%] cub_alloc
│   │           │   │   └─ [  2.03%] __GI___libc_malloc
│   │           │   │       └─ [  1.59%] _int_malloc
│   │           │   │           ├─ [  0.58%] malloc_consolidate
│   │           │   │           │   └─ [  0.37%] unlink_chunk.isra.2
│   │           │   │           └─ [  0.37%] unlink_chunk.isra.2
│   │           │   ├─ [  0.28%] prior_lsa_copy_undo_data_to_node
│   │           │   │   ├─ [  1.66%] cub_alloc
│   │           │   │   │   └─ [  2.03%] __GI___libc_malloc
│   │           │   │   │       └─ [  1.59%] _int_malloc
│   │           │   │   │           ├─ [  0.58%] malloc_consolidate
│   │           │   │   │           │   └─ [  0.37%] unlink_chunk.isra.2
│   │           │   │   │           └─ [  0.37%] unlink_chunk.isra.2
│   │           │   │   └─ [  4.68%] __memmove_evex_unaligned_erms
│   │           │   └─ [  0.27%] prior_lsa_copy_redo_data_to_node
│   │           │       └─ [  1.66%] cub_alloc
│   │           │           └─ [  2.03%] __GI___libc_malloc
│   │           │               └─ [  1.59%] _int_malloc
│   │           │                   ├─ [  0.58%] malloc_consolidate
│   │           │                   │   └─ [  0.37%] unlink_chunk.isra.2
│   │           │                   └─ [  0.37%] unlink_chunk.isra.2
│   │           ├─ [  0.81%] prior_lsa_next_record_internal
│   │           │   ├─ [  2.05%] __GI___pthread_mutex_lock
│   │           │   └─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │           │       └─ [  0.28%] __lll_unlock_wake
│   │           └─ [  0.27%] pgbuf_set_lsa
│   ├─ [  4.20%] locator_update_index
│   │   ├─ [  1.11%] heap_get_class_name_alloc_if_diff
│   │   │   ├─ [  0.36%] heap_scancache_end
│   │   │   │   └─ [  0.47%] heap_scancache_quick_end
│   │   │   │       └─ [  2.18%] pgbuf_unfix
│   │   │   │           ├─ [  1.23%] pgbuf_unlatch_bcb_upon_unfix
│   │   │   │           │   └─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │   │   │           │       └─ [  0.28%] __lll_unlock_wake
│   │   │   │           ├─ [  2.05%] __GI___pthread_mutex_lock
│   │   │   │           └─ [  0.26%] pgbuf_lru_move_from_private_to_shared
│   │   │   │               └─ [  2.05%] __GI___pthread_mutex_lock
│   │   │   └─ [  0.29%] heap_get_class_record
│   │   │       ├─ [  1.78%] heap_get_last_version
│   │   │       │   ├─ [  1.49%] heap_get_record_data_when_all_ready
│   │   │       │   │   ├─ [  1.69%] spage_get_record_data
│   │   │       │   │   │   └─ [  4.68%] __memmove_evex_unaligned_erms
│   │   │       │   │   └─ [  0.57%] spage_get_record
│   │   │       │   │       └─ [  0.38%] spage_find_slot
│   │   │       │   └─ [  0.92%] heap_prepare_get_context
│   │   │       └─ [  1.04%] heap_clean_get_context
│   │   │           └─ [  2.18%] pgbuf_unfix
│   │   │               ├─ [  1.23%] pgbuf_unlatch_bcb_upon_unfix
│   │   │               │   └─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │   │               │       └─ [  0.28%] __lll_unlock_wake
│   │   │               ├─ [  2.05%] __GI___pthread_mutex_lock
│   │   │               └─ [  0.26%] pgbuf_lru_move_from_private_to_shared
│   │   │                   └─ [  2.05%] __GI___pthread_mutex_lock
│   │   ├─ [  1.37%] heap_attrinfo_start_with_index
│   │   │   ├─ [  1.51%] heap_classrepr_get
│   │   │   │   ├─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │   │   │   │   └─ [  0.28%] __lll_unlock_wake
│   │   │   │   ├─ [  2.05%] __GI___pthread_mutex_lock
│   │   │   │   └─ [  0.50%] __GI___pthread_mutex_trylock
│   │   │   └─ [  0.26%] heap_attrinfo_recache_attrepr
│   │   ├─ [  0.91%] heap_attrinfo_end
│   │   │   └─ [  1.05%] heap_classrepr_free
│   │   │       ├─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │   │       │   └─ [  0.28%] __lll_unlock_wake
│   │   │       └─ [  2.05%] __GI___pthread_mutex_lock
│   │   ├─ [  0.65%] heap_attrinfo_read_dbvalues
│   │   │   └─ [  0.37%] heap_attrvalue_read
│   │   ├─ [  0.32%] heap_attrvalue_get_key
│   │   ├─ [  0.46%] btree_compare_key
│   │   └─ [  0.68%] LOG_FIND_TDES
│   ├─ [  2.66%] pgbuf_ordered_fix_release
│   │   └─ [  3.26%] pgbuf_fix_release
│   │       ├─ [  0.85%] pgbuf_set_bcb_page_vpid
│   │       ├─ [  0.38%] pgbuf_search_hash_chain
│   │       │   └─ [  0.50%] __GI___pthread_mutex_trylock
│   │       ├─ [  0.31%] pgbuf_latch_bcb_upon_fix
│   │       └─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │           └─ [  0.28%] __lll_unlock_wake
│   ├─ [  3.90%] LZ4_read_ARCH
│   └─ [ 27.13%] log_append_undoredo_recdes2
│       └─ [ 27.14%] log_append_undoredo_crumbs
│           ├─ [ 25.73%] prior_lsa_alloc_and_copy_crumbs
│           │   ├─ [ 16.06%] prior_lsa_gen_undoredo_record_from_crumbs
│           │   │   ├─ [ 18.41%] log_zip
│           │   │   │   ├─ [ 16.65%] LZ4_compress_fast_extState
│           │   │   │   │   ├─ [  3.90%] LZ4_read_ARCH
│           │   │   │   │   ├─ [  1.16%] LZ4_read32
│           │   │   │   │   └─ [  0.79%] LZ4_initStream
│           │   │   │   │       └─ [  1.91%] __memset_evex_unaligned_erms
│           │   │   │   ├─ [  1.31%] LZ4_resetStream_fast
│           │   │   │   │   └─ [  1.91%] __memset_evex_unaligned_erms
│           │   │   │   ├─ [  0.21%] __tls_get_addr
│           │   │   │   ├─ [  1.16%] LZ4_read32
│           │   │   │   └─ [  3.90%] LZ4_read_ARCH
│           │   │   ├─ [  5.36%] log_diff
│           │   │   ├─ [  4.68%] __memmove_evex_unaligned_erms
│           │   │   └─ [  1.66%] cub_alloc
│           │   │       └─ [  2.03%] __GI___libc_malloc
│           │   │           └─ [  1.59%] _int_malloc
│           │   │               ├─ [  0.58%] malloc_consolidate
│           │   │               │   └─ [  0.37%] unlink_chunk.isra.2
│           │   │               └─ [  0.37%] unlink_chunk.isra.2
│           │   ├─ [ 18.41%] log_zip
│           │   │   ├─ [ 16.65%] LZ4_compress_fast_extState
│           │   │   │   ├─ [  3.90%] LZ4_read_ARCH
│           │   │   │   ├─ [  1.16%] LZ4_read32
│           │   │   │   └─ [  0.79%] LZ4_initStream
│           │   │   │       └─ [  1.91%] __memset_evex_unaligned_erms
│           │   │   ├─ [  1.31%] LZ4_resetStream_fast
│           │   │   │   └─ [  1.91%] __memset_evex_unaligned_erms
│           │   │   ├─ [  0.21%] __tls_get_addr
│           │   │   ├─ [  1.16%] LZ4_read32
│           │   │   └─ [  3.90%] LZ4_read_ARCH
│           │   ├─ [  1.66%] cub_alloc
│           │   │   └─ [  2.03%] __GI___libc_malloc
│           │   │       └─ [  1.59%] _int_malloc
│           │   │           ├─ [  0.58%] malloc_consolidate
│           │   │           │   └─ [  0.37%] unlink_chunk.isra.2
│           │   │           └─ [  0.37%] unlink_chunk.isra.2
│           │   ├─ [  0.28%] prior_lsa_copy_undo_data_to_node
│           │   │   ├─ [  1.66%] cub_alloc
│           │   │   │   └─ [  2.03%] __GI___libc_malloc
│           │   │   │       └─ [  1.59%] _int_malloc
│           │   │   │           ├─ [  0.58%] malloc_consolidate
│           │   │   │           │   └─ [  0.37%] unlink_chunk.isra.2
│           │   │   │           └─ [  0.37%] unlink_chunk.isra.2
│           │   │   └─ [  4.68%] __memmove_evex_unaligned_erms
│           │   └─ [  0.27%] prior_lsa_copy_redo_data_to_node
│           │       └─ [  1.66%] cub_alloc
│           │           └─ [  2.03%] __GI___libc_malloc
│           │               └─ [  1.59%] _int_malloc
│           │                   ├─ [  0.58%] malloc_consolidate
│           │                   │   └─ [  0.37%] unlink_chunk.isra.2
│           │                   └─ [  0.37%] unlink_chunk.isra.2
│           ├─ [  0.81%] prior_lsa_next_record_internal
│           │   ├─ [  2.05%] __GI___pthread_mutex_lock
│           │   └─ [  2.09%] __pthread_mutex_unlock_usercnt
│           │       └─ [  0.28%] __lll_unlock_wake
│           └─ [  0.27%] pgbuf_set_lsa
├─ [ 12.26%] «connections»  (15489 smp)
│   └─ [ 11.84%] cubconn::connection::worker::run
│       ├─ [  4.45%] cubconn::connection::worker::eventfd_handler
│       │   ├─ [  3.99%] cubconn::connection::worker::handle_message_queue
│       │   │   ├─ [  3.11%] cubconn::connection::worker::handle_message_queue_by_index
│       │   │   │   ├─ [  1.64%] cubconn::connection::worker::handle_message_queue_send_packet
│       │   │   │   │   ├─ [  1.28%] cubconn::transmitter::fill
│       │   │   │   │   │   └─ [  1.24%] __sendmsg
│       │   │   │   │   └─ [  0.49%] rmutex_lock
│       │   │   │   ├─ [  0.78%] cubconn::connection::worker::handle_message_queue_release_packet
│       │   │   │   │   ├─ [  0.51%] cubconn::receiver::release
│       │   │   │   │   │   └─ [  0.37%] cubbase::DMRBMemoryPool::restore
│       │   │   │   │   │       ├─ [  0.21%] std::_Rb_tree<unsigned long, std::pair<unsigned long const, unsigned long>, std::_Select1st<std::pair<unsigned long const, unsigned long> >, std::less<unsigned long>, std::allocator<std::pair<unsigned long const, unsigned long> > >::_M_emplace_unique<unsigned long&, unsigned long&>
│       │   │   │   │   │       └─ [  0.24%] operator delete
│       │   │   │   │   │           └─ [  0.26%] cub_free
│       │   │   │   │   │               └─ [  0.34%] _int_free
│       │   │   │   │   └─ [  0.49%] rmutex_lock
│       │   │   │   ├─ [  0.58%] tbb::detail::d2::internal_try_pop_impl<tbb::detail::d2::concurrent_queue_rep<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >, tbb::detail::d1::cache_aligned_allocator<tbb::detail::d2::concurrent_queue_rep<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> > > >
│       │   │   │   │   ├─ [  0.34%] _int_free
│       │   │   │   │   └─ [  0.24%] operator delete
│       │   │   │   │       └─ [  0.26%] cub_free
│       │   │   │   │           └─ [  0.34%] _int_free
│       │   │   │   └─ [  0.24%] operator delete
│       │   │   │       └─ [  0.26%] cub_free
│       │   │   │           └─ [  0.34%] _int_free
│       │   │   └─ [  0.88%] cubconn::connection::worker::purge_stale_contexts
│       │   │       ├─ [  0.58%] cubconn::connection::coordinator::notify
│       │   │       │   └─ [  0.55%] __libc_write
│       │   │       └─ [  0.29%] cubconn::connection::coordinator::enqueue
│       │   └─ [  0.38%] cubconn::connection::worker::eventfd_clear
│       │       └─ [  0.36%] __libc_read
│       ├─ [  3.80%] cubconn::connection::worker::handle_reception
│       │   ├─ [  2.26%] cubconn::receiver::drain
│       │   │   └─ [  2.11%] cubconn::receiver::receive
│       │   │       └─ [  2.10%] __libc_recv
│       │   ├─ [  0.84%] cubconn::connection::worker::handle_data_packet
│       │   │   └─ [  0.60%] cubthread::worker_pool::core::execute_task
│       │   │       └─ [  0.50%] cubthread::worker_pool::core::worker::assign_task
│       │   │           └─ [  0.44%] std::condition_variable::notify_one
│       │   │               └─ [  0.43%] __pthread_cond_signal
│       │   ├─ [  0.23%] cubconn::connection::worker::handle_header_packet
│       │   │   └─ [  0.51%] cubconn::receiver::release
│       │   │       └─ [  0.37%] cubbase::DMRBMemoryPool::restore
│       │   │           ├─ [  0.21%] std::_Rb_tree<unsigned long, std::pair<unsigned long const, unsigned long>, std::_Select1st<std::pair<unsigned long const, unsigned long> >, std::less<unsigned long>, std::allocator<std::pair<unsigned long const, unsigned long> > >::_M_emplace_unique<unsigned long&, unsigned long&>
│       │   │           └─ [  0.24%] operator delete
│       │   │               └─ [  0.26%] cub_free
│       │   │                   └─ [  0.34%] _int_free
│       │   └─ [  0.49%] rmutex_lock
│       └─ [  3.40%] cubsocket::epoll::wait
│           └─ [  3.38%] epoll_wait
├─ [  4.11%] «dwb-flush-block»  (5195 smp)
│   └─ [  4.05%] __GI___clone
│       └─ [  4.05%] start_thread
│           └─ [  4.05%] execute_native_thread_routine
│               └─ [  4.05%] cubthread::daemon::loop_with_context
│                   └─ [  3.83%] cubthread::looper::put_to_sleep
│                       ├─ [  3.67%] cubthread::waiter::wait_for
│                       │   ├─ [  3.21%] __pthread_cond_timedwait
│                       │   ├─ [  0.24%] __pthread_mutex_unlock_usercnt
│                       │   │   └─ [  0.24%] __lll_unlock_wake
│                       │   └─ [  0.24%] std::chrono::_V2::system_clock::now
│                       └─ [  0.24%] std::chrono::_V2::system_clock::now
├─ [  3.47%] «vacuum»  (4378 smp)
│   ├─ [  2.84%] vacuum_heap_page
│   │   ├─ [  1.62%] vacuum_heap_prepare_record
│   │   │   └─ [  1.49%] spage_get_record_data
│   │   │       └─ [  1.87%] __memmove_evex_unaligned_erms
│   │   ├─ [  0.73%] vacuum_heap_page_log_and_reset
│   │   │   ├─ [  0.37%] heap_stats_update
│   │   │   │   └─ [  0.36%] heap_stats_add_bestspace
│   │   │   └─ [  0.33%] spage_compact
│   │   │       └─ [  1.87%] __memmove_evex_unaligned_erms
│   │   └─ [  0.25%] pgbuf_fix_release
│   └─ [  0.45%] vacuum_process_log_block
│       └─ [  0.31%] __GI___qsort_r
│           └─ [  0.27%] __GI___libc_malloc
│               └─ [  0.25%] _int_malloc
│                   └─ [  0.22%] malloc_consolidate
├─ [  1.91%] «coordinator»  (2414 smp)
│   └─ [  1.87%] __GI___clone
│       └─ [  1.87%] start_thread
│           └─ [  1.87%] execute_native_thread_routine
│               └─ [  1.87%] cubconn::connection::coordinator::attach
│                   └─ [  1.86%] cubconn::connection::coordinator::run
│                       ├─ [  1.22%] cubsocket::epoll::wait
│                       │   └─ [  1.22%] epoll_wait
│                       ├─ [  0.29%] cubconn::connection::coordinator::handle_message_queue
│                       │   └─ [  0.23%] tbb::detail::d2::internal_try_pop_impl<tbb::detail::d2::concurrent_queue_rep<cubconn::connection::coordinator::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::coordinator::message> >, tbb::detail::d1::cache_aligned_allocator<tbb::detail::d2::concurrent_queue_rep<cubconn::connection::coordinator::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::coordinator::message> > > >
│                       └─ [  0.26%] cubconn::connection::coordinator::eventfd_clear
│                           └─ [  0.25%] __libc_read
├─ [  1.69%] «log-flush»  (2137 smp)
│   ├─ [  1.18%] __GI___clone
│   │   └─ [  1.18%] start_thread
│   │       └─ [  1.18%] execute_native_thread_routine
│   │           └─ [  1.18%] cubthread::daemon::loop_with_context
│   │               └─ [  1.04%] log_flush_execute
│   │                   └─ [  1.04%] logpb_flush_pages_direct
│   │                       ├─ [  0.78%] logpb_prior_lsa_append_all_list
│   │                       │   ├─ [  0.73%] logpb_append_prior_lsa_list
│   │                       │   │   ├─ [  0.50%] logpb_append_next_record
│   │                       │   │   └─ [  0.21%] cub_free
│   │                       │   └─ [  0.35%] logpb_append_data
│   │                       └─ [  0.24%] logpb_flush_all_append_pages
│   │                           └─ [  0.26%] fileio_synchronize
│   │                               └─ [  0.26%] fdatasync
│   └─ [  0.25%] logpb_write_toflush_pages_to_archive
│       ├─ [  0.41%] fileio_write
│       │   └─ [  0.40%] __libc_pwrite64
│       └─ [  0.26%] fileio_synchronize
│           └─ [  0.26%] fdatasync
├─ [  0.89%] «vacuum-master»  (1123 smp)
│   └─ [  0.84%] __GI___clone
│       └─ [  0.83%] start_thread
│           └─ [  0.83%] execute_native_thread_routine
│               └─ [  0.83%] cubthread::daemon::loop_with_context
│                   └─ [  0.65%] cubthread::looper::put_to_sleep
│                       └─ [  0.63%] cubthread::waiter::wait_for
│                           └─ [  0.56%] __pthread_cond_timedwait
├─ [  0.68%] «dwb-file-sync»  (861 smp)
│   └─ [  0.68%] __GI___clone
│       └─ [  0.68%] start_thread
│           └─ [  0.68%] execute_native_thread_routine
│               └─ [  0.68%] cubthread::daemon::loop_with_context
│                   └─ [  0.64%] cubthread::looper::put_to_sleep
│                       └─ [  0.61%] cubthread::waiter::wait_for
│                           └─ [  0.55%] __pthread_cond_timedwait
├─ [  0.34%] «pgbuf-flush-con»  (424 smp)
│   └─ [  0.33%] __GI___clone
│       └─ [  0.33%] start_thread
│           └─ [  0.33%] execute_native_thread_routine
│               └─ [  0.33%] cubthread::daemon::loop_with_context
│                   └─ [  0.31%] cubthread::looper::put_to_sleep
│                       └─ [  0.31%] cubthread::waiter::wait_for
│                           └─ [  0.29%] __pthread_cond_timedwait
└─ [  1.19%] «기타 thread 8종»  (1500 smp, 각 <0.3%)
         0.30%  deadlock-detect  (376)
         0.30%  pgbuf-maintain  (376)
         0.22%  log-clock  (273)
         0.15%  ha-delay-check  (186)
         0.10%  pgbuf-page-flus  (121)
         0.08%  pl-monitor  (104)
         0.04%  cub_server  (55)
         0.01%  session-control  (9)
```
