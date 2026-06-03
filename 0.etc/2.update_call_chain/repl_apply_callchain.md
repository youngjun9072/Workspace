# UPDATE 복제 적용 콜체인 — 서버 스레드부터 전체

슬레이브 `cub_server` 의 **transaction 워커 스레드**가 master `applylogdb` 의 복제 UPDATE 요청을
받아 적용하기까지 **서버 스레드 진입 → RPC 핸들러 → 적용 → write** 전 구간.
**구조 = 소스 코드(authoritative)**, **% = on-CPU perf inclusive 비중**.
캡처: `20260601-203730-cubserver-oncpu-config-parallel-poc-update` (전체 126,337 sample).

> ⚠ **dwarf(8KB) 스택 truncation 주의**: 깊은 write 프레임에서 스냅샷이 소진돼 상위 프레임이 잘린다.
> 그래서 ① 상위 스레드/RPC 노드 % 가 하위보다 작게(undercount) 찍히고, ② `slocator_repl_force` 서브트리(§2)와
> `locator_update_force` write 트리(§3)가 **서로 다른 sample 집합**으로 갈린다(연결은 소스로 확정).

> **분모**: §1·§2 = % of total(126,337) 또는 % of slocator. §3 = % of locator_update_force(=22.96% of total).
> 구간별 분모가 다르니 직접 비교 금지(각 블록 헤더에 표기).

소스: `cubrid/src/transaction/locator_sr.c`, 서버 stub `cubrid/src/communication/network_interface_sr.cpp`,
스레드 디스패치 `cubrid/src/thread/*`, 요청 demux `cubrid/src/communication/network_sr.c`.

> 전체 on-CPU(모든 스레드/함수) 콜체인은 `oncpu_full_callchain.md` 참조. 이 문서는 **복제 적용 경로**에 집중.

---

## §1. 서버 스레드 진입 (transaction worker, 소스 구조 + % of total)

```
__GI___clone                                              [33.29%]   (pthread 생성)
└─ start_thread                                           [33.28%]
   └─ execute_native_thread_routine                       [33.27%]
      └─ cubthread::worker_pool::core::worker::run        [23.21%]   워커 루프
         └─ cubthread::worker_pool::core::worker::execute_current_task  [20.37%]
            └─ css_server_task::execute                   [20.11%]   요청 디스패치
               └─ css_internal_request_handler            [19.18%]
                  └─ net_server_request                   [18.96%]   요청 demux (function table)
                     └─ ❰NET_SERVER_LC_REPL_FORCE❱ → slocator_repl_force   [17.78%⚠]  ▼ §2
```
※ `transaction` 워커는 복제 force 외 다른 요청도 처리하지만, 이 워크로드에선 거의 전량이 `slocator_repl_force` 경로.
(전체 thread 별 분포는 `analysis/calltree_full.txt` / `inclusive_total.txt` 참조)

---

## §2. slocator_repl_force 서브트리 — 모든 서버 함수 (측정, slocator_repl_force = 100%)

RPC 핸들러 본체. **`xlocator_repl_force`(적용) + PK 조회(`xbtree_find_unique`) + topop 경계 + 응답 송수신(css/TBB)** 등
서버 측 함수가 전부 들어있다. 아래는 `analysis/calltree_slocator_repl_force.txt` 전문
(% = of slocator_repl_force, 노드컷 0.3%, MIN_EDGE 20).

> UPDATE 분기는 `xlocator_repl_force` 의 `locator_repl_prepare_force`(PK→OID 조회 `xbtree_find_unique` + old record
> `heap_get_visible_version`) → `switch(obj->operation)` → `LC_FLUSH_UPDATE` → `locator_update_force` (locator_sr.c:7045).
> 단 write 호출은 truncation 으로 이 서브트리에선 거의 안 보이고(같은 sample 에 안 잡힘), **실제 write 본체는 §3**.

```
# slocator_repl_force 콜체인 (ROOT 포함 sample 만, ROOT=100%)
# root_samples = 22464  (total = 126337, 17.78% of total)
# 노드컷 0.3% of root, MIN_EDGE 20

[100.00%] slocator_repl_force
    ├─ [ 84.77%] xlocator_repl_force
    │   ├─ [ 48.76%] xbtree_find_unique
    │   │   ├─ [ 22.63%] btree_key_find_and_lock_unique
    │   │   │   └─ [ 22.53%] btree_key_find_and_lock_unique_of_unique
    │   │   │       ├─ [ 21.52%] btree_key_lock_object
    │   │   │       │   └─ [ 24.01%] lock_object
    │   │   │       │       ├─ [ 21.26%] lock_internal_perform_lock_object
    │   │   │       │       │   ├─ [ 15.00%] cubthread::lockfree_hashmap<lk_res_key, lk_res>::find_or_insert
    │   │   │       │       │   │   └─ [ 16.60%] lf_hash_insert_internal
    │   │   │       │       │   │       ├─ [ 14.35%] lf_list_insert_internal
    │   │   │       │       │   │       │   ├─ [  8.93%] lock_res_key_compare
    │   │   │       │       │   │       │   ├─ [  5.16%] lf_freelist_claim
    │   │   │       │       │   │       │   │   ├─ [  1.96%] lf_stack_pop
    │   │   │       │       │   │       │   │   │   └─ [  0.48%] ATOMIC_CAS_ADDR<void>
    │   │   │       │       │   │       │   │   ├─ [  1.44%] lf_freelist_alloc_block
    │   │   │       │       │   │       │   │   │   ├─ [  0.77%] lock_alloc_resource
    │   │   │       │       │   │       │   │   │   │   └─ [  1.34%] cub_alloc
    │   │   │       │       │   │       │   │   │   │       └─ [  2.76%] __GI___libc_malloc
    │   │   │       │       │   │       │   │   │   │           └─ [  2.03%] _int_malloc
    │   │   │       │       │   │       │   │   │   │               ├─ [  0.47%] unlink_chunk.isra.2
    │   │   │       │       │   │       │   │   │   │               └─ [  1.04%] malloc_consolidate
    │   │   │       │       │   │       │   │   │   │                   └─ [  0.47%] unlink_chunk.isra.2
    │   │   │       │       │   │       │   │   │   └─ [  2.76%] __GI___libc_malloc
    │   │   │       │       │   │       │   │   │       └─ [  2.03%] _int_malloc
    │   │   │       │       │   │       │   │   │           ├─ [  0.47%] unlink_chunk.isra.2
    │   │   │       │       │   │       │   │   │           └─ [  1.04%] malloc_consolidate
    │   │   │       │       │   │       │   │   │               └─ [  0.47%] unlink_chunk.isra.2
    │   │   │       │       │   │       │   │   └─ [  0.45%] ATOMIC_INC_32<int, int>
    │   │   │       │       │   │       │   ├─ [  0.41%] lf_tran_start
    │   │   │       │       │   │       │   ├─ [  5.78%] __GI___pthread_mutex_lock
    │   │   │       │       │   │       │   └─ [  0.48%] ATOMIC_CAS_ADDR<void>
    │   │   │       │       │   │       ├─ [  0.55%] heap_hfid_table_entry_key_hash
    │   │   │       │       │   │       └─ [  0.35%] lock_res_key_hash
    │   │   │       │       │   ├─ [  5.16%] lf_freelist_claim
    │   │   │       │       │   │   ├─ [  1.96%] lf_stack_pop
    │   │   │       │       │   │   │   └─ [  0.48%] ATOMIC_CAS_ADDR<void>
    │   │   │       │       │   │   ├─ [  1.44%] lf_freelist_alloc_block
    │   │   │       │       │   │   │   ├─ [  0.77%] lock_alloc_resource
    │   │   │       │       │   │   │   │   └─ [  1.34%] cub_alloc
    │   │   │       │       │   │   │   │       └─ [  2.76%] __GI___libc_malloc
    │   │   │       │       │   │   │   │           └─ [  2.03%] _int_malloc
    │   │   │       │       │   │   │   │               ├─ [  0.47%] unlink_chunk.isra.2
    │   │   │       │       │   │   │   │               └─ [  1.04%] malloc_consolidate
    │   │   │       │       │   │   │   │                   └─ [  0.47%] unlink_chunk.isra.2
    │   │   │       │       │   │   │   └─ [  2.76%] __GI___libc_malloc
    │   │   │       │       │   │   │       └─ [  2.03%] _int_malloc
    │   │   │       │       │   │   │           ├─ [  0.47%] unlink_chunk.isra.2
    │   │   │       │       │   │   │           └─ [  1.04%] malloc_consolidate
    │   │   │       │       │   │   │               └─ [  0.47%] unlink_chunk.isra.2
    │   │   │       │       │   │   └─ [  0.45%] ATOMIC_INC_32<int, int>
    │   │   │       │       │   ├─ [  0.68%] lock_insert_into_tran_hold_list
    │   │   │       │       │   │   └─ [  5.78%] __GI___pthread_mutex_lock
    │   │   │       │       │   ├─ [  0.51%] lock_event_set_xasl_id_to_entry
    │   │   │       │       │   │   └─ [  1.37%] LOG_FIND_TDES
    │   │   │       │       │   ├─ [  0.97%] lock_find_class_entry
    │   │   │       │       │   │   ├─ [  5.78%] __GI___pthread_mutex_lock
    │   │   │       │       │   │   └─ [  5.19%] __pthread_mutex_unlock_usercnt
    │   │   │       │       │   ├─ [  5.19%] __pthread_mutex_unlock_usercnt
    │   │   │       │       │   └─ [  5.78%] __GI___pthread_mutex_lock
    │   │   │       │       ├─ [  1.19%] lock_get_class_lock
    │   │   │       │       │   ├─ [  5.78%] __GI___pthread_mutex_lock
    │   │   │       │       │   └─ [  5.19%] __pthread_mutex_unlock_usercnt
    │   │   │       │       └─ [  0.97%] lock_find_class_entry
    │   │   │       │           ├─ [  5.78%] __GI___pthread_mutex_lock
    │   │   │       │           └─ [  5.19%] __pthread_mutex_unlock_usercnt
    │   │   │       └─ [  0.35%] btree_leaf_get_first_object
    │   │   ├─ [ 21.31%] btree_search_key_and_apply_functions
    │   │   │   ├─ [  8.08%] btree_advance_and_find_key
    │   │   │   │   └─ [  5.56%] pgbuf_fix_release
    │   │   │   │       ├─ [  0.85%] pgbuf_latch_bcb_upon_fix
    │   │   │   │       ├─ [  0.75%] pgbuf_lockfree_fix_ro
    │   │   │   │       │   └─ [  0.35%] pgbuf_hash_func_mirror
    │   │   │   │       ├─ [  0.63%] pgbuf_search_hash_chain
    │   │   │   │       │   └─ [  1.09%] __GI___pthread_mutex_trylock
    │   │   │   │       ├─ [  5.19%] __pthread_mutex_unlock_usercnt
    │   │   │   │       └─ [  0.35%] pgbuf_hash_func_mirror
    │   │   │   ├─ [  3.99%] btree_get_root_with_key
    │   │   │   │   ├─ [  5.56%] pgbuf_fix_release
    │   │   │   │   │   ├─ [  0.85%] pgbuf_latch_bcb_upon_fix
    │   │   │   │   │   ├─ [  0.75%] pgbuf_lockfree_fix_ro
    │   │   │   │   │   │   └─ [  0.35%] pgbuf_hash_func_mirror
    │   │   │   │   │   ├─ [  0.63%] pgbuf_search_hash_chain
    │   │   │   │   │   │   └─ [  1.09%] __GI___pthread_mutex_trylock
    │   │   │   │   │   ├─ [  5.19%] __pthread_mutex_unlock_usercnt
    │   │   │   │   │   └─ [  0.35%] pgbuf_hash_func_mirror
    │   │   │   │   └─ [  1.07%] btree_fix_root_with_info
    │   │   │   │       ├─ [  0.55%] btree_glean_root_header_info
    │   │   │   │       │   └─ [  0.97%] or_get_domain
    │   │   │   │       │       └─ [  0.30%] unpack_domain
    │   │   │   │       └─ [  0.40%] btree_get_root_header
    │   │   │   │           └─ [  2.20%] spage_get_record
    │   │   │   │               └─ [  1.44%] spage_find_slot
    │   │   │   │                   └─ [  0.42%] spage_is_unknown_slot
    │   │   │   └─ [  6.60%] pgbuf_unfix
    │   │   │       ├─ [  3.36%] pgbuf_unlatch_bcb_upon_unfix
    │   │   │       │   ├─ [  0.57%] pgbuf_wakeup_reader_writer
    │   │   │       │   │   └─ [  0.56%] set_waiter_exists
    │   │   │       │   └─ [  5.19%] __pthread_mutex_unlock_usercnt
    │   │   │       ├─ [  1.43%] pgbuf_lru_move_from_private_to_shared
    │   │   │       │   ├─ [  0.75%] pgbuf_lru_remove_bcb
    │   │   │       │   └─ [  5.78%] __GI___pthread_mutex_lock
    │   │   │       ├─ [  5.78%] __GI___pthread_mutex_lock
    │   │   │       └─ [  0.45%] pgbuf_unlatch_thrd_holder
    │   │   ├─ [  5.86%] btree_search_leaf_page
    │   │   │   ├─ [  3.51%] btree_read_record_without_decompression
    │   │   │   │   ├─ [  1.14%] mr_index_readval_int
    │   │   │   │   │   └─ [  2.67%] __memmove_evex_unaligned_erms
    │   │   │   │   ├─ [  0.48%] btree_read_fixed_portion_of_non_leaf_record_from_orbuf
    │   │   │   │   │   └─ [  0.36%] or_get_int
    │   │   │   │   │       └─ [  5.52%] btree_search_nonleaf_page
    │   │   │   │   │           ├─ [  2.18%] btree_compare_key
    │   │   │   │   │           │   └─ [  0.50%] mr_cmpval_int
    │   │   │   │   │           ├─ [  2.20%] spage_get_record
    │   │   │   │   │           │   └─ [  1.44%] spage_find_slot
    │   │   │   │   │           │       └─ [  0.42%] spage_is_unknown_slot
    │   │   │   │   │           └─ [  0.93%] spage_get_record_data
    │   │   │   │   └─ [  0.39%] btree_clear_key_value
    │   │   │   ├─ [  2.18%] btree_compare_key
    │   │   │   │   └─ [  0.50%] mr_cmpval_int
    │   │   │   ├─ [  2.20%] spage_get_record
    │   │   │   │   └─ [  1.44%] spage_find_slot
    │   │   │   │       └─ [  0.42%] spage_is_unknown_slot
    │   │   │   ├─ [  0.93%] spage_get_record_data
    │   │   │   ├─ [  0.50%] mr_cmpval_int
    │   │   │   └─ [  0.39%] btree_clear_key_value
    │   │   ├─ [  5.52%] btree_search_nonleaf_page
    │   │   │   ├─ [  3.51%] btree_read_record_without_decompression
    │   │   │   │   ├─ [  1.14%] mr_index_readval_int
    │   │   │   │   │   └─ [  2.67%] __memmove_evex_unaligned_erms
    │   │   │   │   ├─ [  5.86%] btree_search_leaf_page
    │   │   │   │   │   ├─ [  2.18%] btree_compare_key
    │   │   │   │   │   │   └─ [  0.50%] mr_cmpval_int
    │   │   │   │   │   ├─ [  2.20%] spage_get_record
    │   │   │   │   │   │   └─ [  1.44%] spage_find_slot
    │   │   │   │   │   │       └─ [  0.42%] spage_is_unknown_slot
    │   │   │   │   │   ├─ [  0.93%] spage_get_record_data
    │   │   │   │   │   ├─ [  0.50%] mr_cmpval_int
    │   │   │   │   │   └─ [  0.39%] btree_clear_key_value
    │   │   │   │   ├─ [  0.48%] btree_read_fixed_portion_of_non_leaf_record_from_orbuf
    │   │   │   │   │   └─ [  0.36%] or_get_int
    │   │   │   │   └─ [  0.39%] btree_clear_key_value
    │   │   │   ├─ [  2.18%] btree_compare_key
    │   │   │   │   └─ [  0.50%] mr_cmpval_int
    │   │   │   ├─ [  2.20%] spage_get_record
    │   │   │   │   └─ [  1.44%] spage_find_slot
    │   │   │   │       └─ [  0.42%] spage_is_unknown_slot
    │   │   │   └─ [  0.93%] spage_get_record_data
    │   │   ├─ [ 24.01%] lock_object
    │   │   │   ├─ [ 21.26%] lock_internal_perform_lock_object
    │   │   │   │   ├─ [ 15.00%] cubthread::lockfree_hashmap<lk_res_key, lk_res>::find_or_insert
    │   │   │   │   │   └─ [ 16.60%] lf_hash_insert_internal
    │   │   │   │   │       ├─ [ 14.35%] lf_list_insert_internal
    │   │   │   │   │       │   ├─ [  8.93%] lock_res_key_compare
    │   │   │   │   │       │   ├─ [  5.16%] lf_freelist_claim
    │   │   │   │   │       │   │   ├─ [  1.96%] lf_stack_pop
    │   │   │   │   │       │   │   │   └─ [  0.48%] ATOMIC_CAS_ADDR<void>
    │   │   │   │   │       │   │   ├─ [  1.44%] lf_freelist_alloc_block
    │   │   │   │   │       │   │   │   ├─ [  0.77%] lock_alloc_resource
    │   │   │   │   │       │   │   │   │   └─ [  1.34%] cub_alloc
    │   │   │   │   │       │   │   │   │       └─ [  2.76%] __GI___libc_malloc
    │   │   │   │   │       │   │   │   │           └─ [  2.03%] _int_malloc
    │   │   │   │   │       │   │   │   │               ├─ [  0.47%] unlink_chunk.isra.2
    │   │   │   │   │       │   │   │   │               └─ [  1.04%] malloc_consolidate
    │   │   │   │   │       │   │   │   │                   └─ [  0.47%] unlink_chunk.isra.2
    │   │   │   │   │       │   │   │   └─ [  2.76%] __GI___libc_malloc
    │   │   │   │   │       │   │   │       └─ [  2.03%] _int_malloc
    │   │   │   │   │       │   │   │           ├─ [  0.47%] unlink_chunk.isra.2
    │   │   │   │   │       │   │   │           └─ [  1.04%] malloc_consolidate
    │   │   │   │   │       │   │   │               └─ [  0.47%] unlink_chunk.isra.2
    │   │   │   │   │       │   │   └─ [  0.45%] ATOMIC_INC_32<int, int>
    │   │   │   │   │       │   ├─ [  0.41%] lf_tran_start
    │   │   │   │   │       │   ├─ [  5.78%] __GI___pthread_mutex_lock
    │   │   │   │   │       │   └─ [  0.48%] ATOMIC_CAS_ADDR<void>
    │   │   │   │   │       ├─ [  0.55%] heap_hfid_table_entry_key_hash
    │   │   │   │   │       └─ [  0.35%] lock_res_key_hash
    │   │   │   │   ├─ [  5.16%] lf_freelist_claim
    │   │   │   │   │   ├─ [  1.96%] lf_stack_pop
    │   │   │   │   │   │   └─ [  0.48%] ATOMIC_CAS_ADDR<void>
    │   │   │   │   │   ├─ [  1.44%] lf_freelist_alloc_block
    │   │   │   │   │   │   ├─ [  0.77%] lock_alloc_resource
    │   │   │   │   │   │   │   └─ [  1.34%] cub_alloc
    │   │   │   │   │   │   │       └─ [  2.76%] __GI___libc_malloc
    │   │   │   │   │   │   │           └─ [  2.03%] _int_malloc
    │   │   │   │   │   │   │               ├─ [  0.47%] unlink_chunk.isra.2
    │   │   │   │   │   │   │               └─ [  1.04%] malloc_consolidate
    │   │   │   │   │   │   │                   └─ [  0.47%] unlink_chunk.isra.2
    │   │   │   │   │   │   └─ [  2.76%] __GI___libc_malloc
    │   │   │   │   │   │       └─ [  2.03%] _int_malloc
    │   │   │   │   │   │           ├─ [  0.47%] unlink_chunk.isra.2
    │   │   │   │   │   │           └─ [  1.04%] malloc_consolidate
    │   │   │   │   │   │               └─ [  0.47%] unlink_chunk.isra.2
    │   │   │   │   │   └─ [  0.45%] ATOMIC_INC_32<int, int>
    │   │   │   │   ├─ [  0.68%] lock_insert_into_tran_hold_list
    │   │   │   │   │   └─ [  5.78%] __GI___pthread_mutex_lock
    │   │   │   │   ├─ [  0.51%] lock_event_set_xasl_id_to_entry
    │   │   │   │   │   └─ [  1.37%] LOG_FIND_TDES
    │   │   │   │   ├─ [  0.97%] lock_find_class_entry
    │   │   │   │   │   ├─ [  5.78%] __GI___pthread_mutex_lock
    │   │   │   │   │   └─ [  5.19%] __pthread_mutex_unlock_usercnt
    │   │   │   │   ├─ [  5.19%] __pthread_mutex_unlock_usercnt
    │   │   │   │   └─ [  5.78%] __GI___pthread_mutex_lock
    │   │   │   ├─ [  1.19%] lock_get_class_lock
    │   │   │   │   ├─ [  5.78%] __GI___pthread_mutex_lock
    │   │   │   │   └─ [  5.19%] __pthread_mutex_unlock_usercnt
    │   │   │   └─ [  0.97%] lock_find_class_entry
    │   │   │       ├─ [  5.78%] __GI___pthread_mutex_lock
    │   │   │       └─ [  5.19%] __pthread_mutex_unlock_usercnt
    │   │   └─ [  0.51%] oid_check_cached_class_oid
    │   ├─ [ 16.19%] locator_repl_prepare_force
    │   │   ├─ [  8.68%] heap_get_visible_version
    │   │   │   ├─ [  4.97%] heap_get_visible_version_internal
    │   │   │   │   ├─ [  4.47%] heap_prepare_get_context
    │   │   │   │   └─ [  0.33%] heap_get_record_data_when_all_ready
    │   │   │   └─ [  3.35%] heap_clean_get_context
    │   │   │       └─ [  6.60%] pgbuf_unfix
    │   │   │           ├─ [  3.36%] pgbuf_unlatch_bcb_upon_unfix
    │   │   │           │   ├─ [  0.57%] pgbuf_wakeup_reader_writer
    │   │   │           │   │   └─ [  0.56%] set_waiter_exists
    │   │   │           │   └─ [  5.19%] __pthread_mutex_unlock_usercnt
    │   │   │           ├─ [  1.43%] pgbuf_lru_move_from_private_to_shared
    │   │   │           │   ├─ [  0.75%] pgbuf_lru_remove_bcb
    │   │   │           │   └─ [  5.78%] __GI___pthread_mutex_lock
    │   │   │           ├─ [  5.78%] __GI___pthread_mutex_lock
    │   │   │           └─ [  0.45%] pgbuf_unlatch_thrd_holder
    │   │   ├─ [  5.10%] heap_get_class_repr_id
    │   │   │   ├─ [  3.93%] heap_classrepr_get
    │   │   │   │   ├─ [  5.19%] __pthread_mutex_unlock_usercnt
    │   │   │   │   ├─ [  5.78%] __GI___pthread_mutex_lock
    │   │   │   │   └─ [  1.09%] __GI___pthread_mutex_trylock
    │   │   │   └─ [  2.54%] heap_classrepr_free
    │   │   │       ├─ [  5.19%] __pthread_mutex_unlock_usercnt
    │   │   │       └─ [  5.78%] __GI___pthread_mutex_lock
    │   │   └─ [  1.67%] btree_get_pkey_btid
    │   │       ├─ [  3.93%] heap_classrepr_get
    │   │       │   ├─ [  5.19%] __pthread_mutex_unlock_usercnt
    │   │       │   ├─ [  5.78%] __GI___pthread_mutex_lock
    │   │       │   └─ [  1.09%] __GI___pthread_mutex_trylock
    │   │       └─ [  2.54%] heap_classrepr_free
    │   │           ├─ [  5.19%] __pthread_mutex_unlock_usercnt
    │   │           └─ [  5.78%] __GI___pthread_mutex_lock
    │   ├─ [  7.61%] xtran_server_end_topop
    │   │   ├─ [  3.33%] log_sysop_attach_to_outer
    │   │   │   ├─ [  2.12%] log_tdes::unlock_topop
    │   │   │   │   ├─ [  1.99%] cubpl::get_session
    │   │   │   │   │   ├─ [  1.44%] session_get_pl_session
    │   │   │   │   │   │   ├─ [  0.88%] cubpl::session::is_sp_running
    │   │   │   │   │   │   │   ├─ [  5.78%] __GI___pthread_mutex_lock
    │   │   │   │   │   │   │   └─ [  5.19%] __pthread_mutex_unlock_usercnt
    │   │   │   │   │   │   └─ [  0.32%] session_get_session_state
    │   │   │   │   │   └─ [  0.87%] thread_get_thread_entry_info
    │   │   │   │   │       └─ [  0.53%] cubthread::get_entry
    │   │   │   │   │           └─ [  0.65%] __tls_get_addr
    │   │   │   │   └─ [  0.75%] cubpl::session::is_thread_involved
    │   │   │   │       ├─ [  5.19%] __pthread_mutex_unlock_usercnt
    │   │   │   │       └─ [  5.78%] __GI___pthread_mutex_lock
    │   │   │   ├─ [  0.48%] log_sysop_end_final
    │   │   │   └─ [  0.92%] rmutex_unlock
    │   │   │       ├─ [  5.19%] __pthread_mutex_unlock_usercnt
    │   │   │       └─ [  0.87%] thread_get_thread_entry_info
    │   │   │           └─ [  0.53%] cubthread::get_entry
    │   │   │               └─ [  0.65%] __tls_get_addr
    │   │   ├─ [  1.87%] cuberr::context::pop_error_stack_and_destroy
    │   │   │   ├─ [  1.03%] cuberr::context::pop_error_stack
    │   │   │   │   ├─ [  0.55%] cuberr::er_message::swap
    │   │   │   │   └─ [  0.53%] operator delete
    │   │   │   │       └─ [  0.57%] cub_free
    │   │   │   │           └─ [  1.25%] _int_free
    │   │   │   │               └─ [  1.04%] malloc_consolidate
    │   │   │   │                   └─ [  0.47%] unlink_chunk.isra.2
    │   │   │   ├─ [  0.38%] cuberr::er_message::~er_message
    │   │   │   └─ [  0.78%] cuberr::er_message::er_message
    │   │   ├─ [  1.28%] cuberr::context::push_error_stack
    │   │   │   ├─ [  1.30%] operator new
    │   │   │   │   ├─ [  2.76%] __GI___libc_malloc
    │   │   │   │   │   └─ [  2.03%] _int_malloc
    │   │   │   │   │       ├─ [  0.47%] unlink_chunk.isra.2
    │   │   │   │   │       └─ [  1.04%] malloc_consolidate
    │   │   │   │   │           └─ [  0.47%] unlink_chunk.isra.2
    │   │   │   │   └─ [  1.34%] cub_alloc
    │   │   │   │       └─ [  2.76%] __GI___libc_malloc
    │   │   │   │           └─ [  2.03%] _int_malloc
    │   │   │   │               ├─ [  0.47%] unlink_chunk.isra.2
    │   │   │   │               └─ [  1.04%] malloc_consolidate
    │   │   │   │                   └─ [  0.47%] unlink_chunk.isra.2
    │   │   │   └─ [  0.78%] cuberr::er_message::er_message
    │   │   └─ [  0.46%] er_stack_push
    │   │       └─ [  0.55%] cuberr::context::get_thread_local_context
    │   │           └─ [  0.65%] __tls_get_addr
    │   ├─ [  3.20%] xtran_server_start_topop
    │   │   └─ [  2.52%] log_sysop_start
    │   │       ├─ [  1.15%] log_tdes::lock_topop
    │   │       │   ├─ [  1.99%] cubpl::get_session
    │   │       │   │   ├─ [  1.44%] session_get_pl_session
    │   │       │   │   │   ├─ [  0.88%] cubpl::session::is_sp_running
    │   │       │   │   │   │   ├─ [  5.78%] __GI___pthread_mutex_lock
    │   │       │   │   │   │   └─ [  5.19%] __pthread_mutex_unlock_usercnt
    │   │       │   │   │   └─ [  0.32%] session_get_session_state
    │   │       │   │   └─ [  0.87%] thread_get_thread_entry_info
    │   │       │   │       └─ [  0.53%] cubthread::get_entry
    │   │       │   │           └─ [  0.65%] __tls_get_addr
    │   │       │   └─ [  0.75%] cubpl::session::is_thread_involved
    │   │       │       ├─ [  5.19%] __pthread_mutex_unlock_usercnt
    │   │       │       └─ [  5.78%] __GI___pthread_mutex_lock
    │   │       ├─ [  2.23%] rmutex_lock
    │   │       │   ├─ [  0.68%] tsc_getticks
    │   │       │   │   └─ [  0.46%] __clock_gettime_2
    │   │       │   ├─ [  5.78%] __GI___pthread_mutex_lock
    │   │       │   └─ [  0.87%] thread_get_thread_entry_info
    │   │       │       └─ [  0.53%] cubthread::get_entry
    │   │       │           └─ [  0.65%] __tls_get_addr
    │   │       └─ [  1.37%] LOG_FIND_TDES
    │   ├─ [  2.84%] heap_get_class_info
    │   │   └─ [  2.80%] heap_hfid_cache_get
    │   │       └─ [ 16.60%] lf_hash_insert_internal
    │   │           ├─ [ 14.35%] lf_list_insert_internal
    │   │           │   ├─ [  8.93%] lock_res_key_compare
    │   │           │   ├─ [  5.16%] lf_freelist_claim
    │   │           │   │   ├─ [  1.96%] lf_stack_pop
    │   │           │   │   │   └─ [  0.48%] ATOMIC_CAS_ADDR<void>
    │   │           │   │   ├─ [  1.44%] lf_freelist_alloc_block
    │   │           │   │   │   ├─ [  0.77%] lock_alloc_resource
    │   │           │   │   │   │   └─ [  1.34%] cub_alloc
    │   │           │   │   │   │       └─ [  2.76%] __GI___libc_malloc
    │   │           │   │   │   │           └─ [  2.03%] _int_malloc
    │   │           │   │   │   │               ├─ [  0.47%] unlink_chunk.isra.2
    │   │           │   │   │   │               └─ [  1.04%] malloc_consolidate
    │   │           │   │   │   │                   └─ [  0.47%] unlink_chunk.isra.2
    │   │           │   │   │   └─ [  2.76%] __GI___libc_malloc
    │   │           │   │   │       └─ [  2.03%] _int_malloc
    │   │           │   │   │           ├─ [  0.47%] unlink_chunk.isra.2
    │   │           │   │   │           └─ [  1.04%] malloc_consolidate
    │   │           │   │   │               └─ [  0.47%] unlink_chunk.isra.2
    │   │           │   │   └─ [  0.45%] ATOMIC_INC_32<int, int>
    │   │           │   ├─ [  0.41%] lf_tran_start
    │   │           │   ├─ [  5.78%] __GI___pthread_mutex_lock
    │   │           │   └─ [  0.48%] ATOMIC_CAS_ADDR<void>
    │   │           ├─ [  0.55%] heap_hfid_table_entry_key_hash
    │   │           └─ [  0.35%] lock_res_key_hash
    │   ├─ [  1.87%] heap_scancache_start_modify
    │   │   ├─ [  1.23%] file_get_type
    │   │   │   ├─ [  5.56%] pgbuf_fix_release
    │   │   │   │   ├─ [  0.85%] pgbuf_latch_bcb_upon_fix
    │   │   │   │   ├─ [  0.75%] pgbuf_lockfree_fix_ro
    │   │   │   │   │   └─ [  0.35%] pgbuf_hash_func_mirror
    │   │   │   │   ├─ [  0.63%] pgbuf_search_hash_chain
    │   │   │   │   │   └─ [  1.09%] __GI___pthread_mutex_trylock
    │   │   │   │   ├─ [  5.19%] __pthread_mutex_unlock_usercnt
    │   │   │   │   └─ [  0.35%] pgbuf_hash_func_mirror
    │   │   │   └─ [  6.60%] pgbuf_unfix
    │   │   │       ├─ [  3.36%] pgbuf_unlatch_bcb_upon_unfix
    │   │   │       │   ├─ [  0.57%] pgbuf_wakeup_reader_writer
    │   │   │       │   │   └─ [  0.56%] set_waiter_exists
    │   │   │       │   └─ [  5.19%] __pthread_mutex_unlock_usercnt
    │   │   │       ├─ [  1.43%] pgbuf_lru_move_from_private_to_shared
    │   │   │       │   ├─ [  0.75%] pgbuf_lru_remove_bcb
    │   │   │       │   └─ [  5.78%] __GI___pthread_mutex_lock
    │   │   │       ├─ [  5.78%] __GI___pthread_mutex_lock
    │   │   │       └─ [  0.45%] pgbuf_unlatch_thrd_holder
    │   │   └─ [  0.40%] heap_scancache_reset_modify
    │   │       └─ [  2.84%] heap_get_class_info
    │   │           └─ [  2.80%] heap_hfid_cache_get
    │   │               └─ [ 16.60%] lf_hash_insert_internal
    │   │                   ├─ [ 14.35%] lf_list_insert_internal
    │   │                   │   ├─ [  8.93%] lock_res_key_compare
    │   │                   │   ├─ [  5.16%] lf_freelist_claim
    │   │                   │   │   ├─ [  1.96%] lf_stack_pop
    │   │                   │   │   │   └─ [  0.48%] ATOMIC_CAS_ADDR<void>
    │   │                   │   │   ├─ [  1.44%] lf_freelist_alloc_block
    │   │                   │   │   │   ├─ [  0.77%] lock_alloc_resource
    │   │                   │   │   │   │   └─ [  1.34%] cub_alloc
    │   │                   │   │   │   │       └─ [  2.76%] __GI___libc_malloc
    │   │                   │   │   │   │           └─ [  2.03%] _int_malloc
    │   │                   │   │   │   │               ├─ [  0.47%] unlink_chunk.isra.2
    │   │                   │   │   │   │               └─ [  1.04%] malloc_consolidate
    │   │                   │   │   │   │                   └─ [  0.47%] unlink_chunk.isra.2
    │   │                   │   │   │   └─ [  2.76%] __GI___libc_malloc
    │   │                   │   │   │       └─ [  2.03%] _int_malloc
    │   │                   │   │   │           ├─ [  0.47%] unlink_chunk.isra.2
    │   │                   │   │   │           └─ [  1.04%] malloc_consolidate
    │   │                   │   │   │               └─ [  0.47%] unlink_chunk.isra.2
    │   │                   │   │   └─ [  0.45%] ATOMIC_INC_32<int, int>
    │   │                   │   ├─ [  0.41%] lf_tran_start
    │   │                   │   ├─ [  5.78%] __GI___pthread_mutex_lock
    │   │                   │   └─ [  0.48%] ATOMIC_CAS_ADDR<void>
    │   │                   ├─ [  0.55%] heap_hfid_table_entry_key_hash
    │   │                   └─ [  0.35%] lock_res_key_hash
    │   ├─ [  1.30%] or_unpack_mem_value
    │   │   ├─ [  0.97%] or_get_domain
    │   │   │   └─ [  0.30%] unpack_domain
    │   │   └─ [  0.31%] mr_initval_int
    │   ├─ [  0.61%] heap_scancache_quick_end
    │   │   └─ [  0.57%] heap_scancache::end_area
    │   │       └─ [  0.51%] cubmem::single_block_allocator::~single_block_allocator
    │   └─ [  0.36%] er_clear
    │       └─ [  0.55%] cuberr::context::get_thread_local_context
    │           └─ [  0.65%] __tls_get_addr
    ├─ [  6.49%] css_send_reply_and_2_data_to_client
    │   ├─ [  4.57%] css_enqueue_and_notify
    │   │   ├─ [  4.25%] cubconn::connection::worker::enqueue_and_notify
    │   │   │   ├─ [  3.11%] cubconn::connection::worker::notify
    │   │   │   │   └─ [  3.07%] __libc_write
    │   │   │   └─ [  2.90%] cubconn::connection::worker::enqueue
    │   │   │       └─ [  1.86%] tbb::detail::d2::micro_queue<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >::prepare_page(unsigned long, tbb::detail::d2::concurrent_queue_rep<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >&, tbb::detail::d1::cache_aligned_allocator<tbb::detail::d2::micro_queue<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >::padded_page>, tbb::detail::d2::micro_queue<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >::padded_page*&)::{lambda()#1}::operator()
    │   │   │           └─ [  1.85%] tbb::detail::r1::cache_aligned_allocate
    │   │   │               └─ [  1.79%] _mid_memalign
    │   │   │                   └─ [  1.58%] _int_memalign
    │   │   │                       ├─ [  1.25%] _int_free
    │   │   │                       │   └─ [  1.04%] malloc_consolidate
    │   │   │                       │       └─ [  0.47%] unlink_chunk.isra.2
    │   │   │                       └─ [  2.03%] _int_malloc
    │   │   │                           ├─ [  0.47%] unlink_chunk.isra.2
    │   │   │                           └─ [  1.04%] malloc_consolidate
    │   │   │                               └─ [  0.47%] unlink_chunk.isra.2
    │   │   └─ [  2.23%] rmutex_lock
    │   │       ├─ [  0.68%] tsc_getticks
    │   │       │   └─ [  0.46%] __clock_gettime_2
    │   │       ├─ [  5.78%] __GI___pthread_mutex_lock
    │   │       └─ [  0.87%] thread_get_thread_entry_info
    │   │           └─ [  0.53%] cubthread::get_entry
    │   │               └─ [  0.65%] __tls_get_addr
    │   ├─ [  2.23%] rmutex_lock
    │   │   ├─ [  0.68%] tsc_getticks
    │   │   │   └─ [  0.46%] __clock_gettime_2
    │   │   ├─ [  5.78%] __GI___pthread_mutex_lock
    │   │   └─ [  0.87%] thread_get_thread_entry_info
    │   │       └─ [  0.53%] cubthread::get_entry
    │   │           └─ [  0.65%] __tls_get_addr
    │   ├─ [  1.30%] operator new
    │   │   ├─ [  2.76%] __GI___libc_malloc
    │   │   │   └─ [  2.03%] _int_malloc
    │   │   │       ├─ [  0.47%] unlink_chunk.isra.2
    │   │   │       └─ [  1.04%] malloc_consolidate
    │   │   │           └─ [  0.47%] unlink_chunk.isra.2
    │   │   └─ [  1.34%] cub_alloc
    │   │       └─ [  2.76%] __GI___libc_malloc
    │   │           └─ [  2.03%] _int_malloc
    │   │               ├─ [  0.47%] unlink_chunk.isra.2
    │   │               └─ [  1.04%] malloc_consolidate
    │   │                   └─ [  0.47%] unlink_chunk.isra.2
    │   └─ [  0.92%] rmutex_unlock
    │       ├─ [  5.19%] __pthread_mutex_unlock_usercnt
    │       └─ [  0.87%] thread_get_thread_entry_info
    │           └─ [  0.53%] cubthread::get_entry
    │               └─ [  0.65%] __tls_get_addr
    ├─ [  2.59%] css_request_release_packet
    │   ├─ [  2.90%] cubconn::connection::worker::enqueue
    │   │   └─ [  1.86%] tbb::detail::d2::micro_queue<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >::prepare_page(unsigned long, tbb::detail::d2::concurrent_queue_rep<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >&, tbb::detail::d1::cache_aligned_allocator<tbb::detail::d2::micro_queue<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >::padded_page>, tbb::detail::d2::micro_queue<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >::padded_page*&)::{lambda()#1}::operator()
    │   │       └─ [  1.85%] tbb::detail::r1::cache_aligned_allocate
    │   │           └─ [  1.79%] _mid_memalign
    │   │               └─ [  1.58%] _int_memalign
    │   │                   ├─ [  1.25%] _int_free
    │   │                   │   └─ [  1.04%] malloc_consolidate
    │   │                   │       └─ [  0.47%] unlink_chunk.isra.2
    │   │                   └─ [  2.03%] _int_malloc
    │   │                       ├─ [  0.47%] unlink_chunk.isra.2
    │   │                       └─ [  1.04%] malloc_consolidate
    │   │                           └─ [  0.47%] unlink_chunk.isra.2
    │   └─ [  2.23%] rmutex_lock
    │       ├─ [  0.68%] tsc_getticks
    │       │   └─ [  0.46%] __clock_gettime_2
    │       ├─ [  5.78%] __GI___pthread_mutex_lock
    │       └─ [  0.87%] thread_get_thread_entry_info
    │           └─ [  0.53%] cubthread::get_entry
    │               └─ [  0.65%] __tls_get_addr
    ├─ [  2.67%] __memmove_evex_unaligned_erms
    ├─ [  1.71%] css_receive_data_from_client_with_timeout
    │   ├─ [  1.25%] css_receive_data
    │   │   ├─ [  1.14%] css_return_queued_data_timeout
    │   │   │   ├─ [  0.92%] rmutex_unlock
    │   │   │   │   ├─ [  5.19%] __pthread_mutex_unlock_usercnt
    │   │   │   │   └─ [  0.87%] thread_get_thread_entry_info
    │   │   │   │       └─ [  0.53%] cubthread::get_entry
    │   │   │   │           └─ [  0.65%] __tls_get_addr
    │   │   │   └─ [  2.23%] rmutex_lock
    │   │   │       ├─ [  0.68%] tsc_getticks
    │   │   │       │   └─ [  0.46%] __clock_gettime_2
    │   │   │       ├─ [  5.78%] __GI___pthread_mutex_lock
    │   │   │       └─ [  0.87%] thread_get_thread_entry_info
    │   │   │           └─ [  0.53%] cubthread::get_entry
    │   │   │               └─ [  0.65%] __tls_get_addr
    │   │   └─ [  0.40%] css_traverse_list
    │   └─ [  0.42%] css_return_queued_error
    │       ├─ [  2.23%] rmutex_lock
    │       │   ├─ [  0.68%] tsc_getticks
    │       │   │   └─ [  0.46%] __clock_gettime_2
    │       │   ├─ [  5.78%] __GI___pthread_mutex_lock
    │       │   └─ [  0.87%] thread_get_thread_entry_info
    │       │       └─ [  0.53%] cubthread::get_entry
    │       │           └─ [  0.65%] __tls_get_addr
    │       └─ [  0.92%] rmutex_unlock
    │           ├─ [  5.19%] __pthread_mutex_unlock_usercnt
    │           └─ [  0.87%] thread_get_thread_entry_info
    │               └─ [  0.53%] cubthread::get_entry
    │                   └─ [  0.65%] __tls_get_addr
    ├─ [  0.59%] locator_unpack_copy_area_descriptor
    └─ [  0.46%] locator_recv_allocate_copyarea
        └─ [  0.44%] locator_allocate_copy_area_by_length
            └─ [  1.34%] cub_alloc
                └─ [  2.76%] __GI___libc_malloc
                    └─ [  2.03%] _int_malloc
                        ├─ [  0.47%] unlink_chunk.isra.2
                        └─ [  1.04%] malloc_consolidate
                            └─ [  0.47%] unlink_chunk.isra.2
```

---

## §3. write tree — `locator_update_force` 이하 (측정, locator_update_force = 100%)

switch leaf `locator_update_force` 아래. perf 에서 안 잘려 **구조·% 정확**. 아래는 `analysis/calltree_root.txt` 전문
(% = of locator_update_force, 노드컷 0.1%, MIN_EDGE 30).

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
