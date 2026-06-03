# UPDATE 전체 on-CPU 콜체인 — 모든 스레드·모든 함수

이 캡처에서 **on-CPU 로 샘플링된 모든 함수**를 caller-callee 호출관계 트리로 정리한 것.
특정 root(`locator_update_force`)가 아니라 **캡처 전체**를 `(ALL on-CPU)` → thread(comm) → 함수 로 묶었다.
캡처: `20260601-203730-cubserver-oncpu-config-parallel-poc-update`, 전체 126,337 sample, 17 thread.

## 읽는 법
- **노드 % = of total**(분모 126,337). 한 함수가 stack 어디든 나온 sample 비율(inclusive).
- stack truncate 대응: 각 sample 의 **최외곽 프레임을 thread 노드에 매달아 100% 커버**.
- **`↑`** = 그 함수 서브트리가 같은 thread 에서 이미 위에 전개됨(중복 전개 생략). 호출관계는 처음 전개된 곳 참조.
- **`◆덩어리#N`** = 한 스레드 안에서 **상위가 truncation 으로 끊긴 독립 호출 조각**. #1 은 보통 thread 진입(`__GI___clone`…)
  체인, 그 외는 깊은 곳에서 잘려 부모를 잃은 fragment. (끊긴 엣지를 측정으론 못 잇기에 조각으로 나눠 표시 — 함수포인터가 아니라 스택 잘림 탓)
- **`⎘소스연결`** = 측정 엣지는 truncation 으로 끊겼지만 **소스 콜관계로 이어붙인** 지점 (예: `xlocator_repl_force → locator_update_force`, locator_sr.c:7045).
- **`(기타 truncation 고아 N개)`** = 위 덩어리에 이미 전개된 함수가 다른 곳에서 또 잘려 root 로 뜬 것 → 이름만 압축 표기.
- 컷오프: 노드 0.03% / thread 0.05% / MIN_EDGE 10. → 트리에 **535 종** 함수 등장.
- ⚠ **on-CPU 측정**이라 mutex/condvar **대기(off-CPU) 시간은 미포함**. `__pthread_mutex_lock`/`wait_for` 등이 보여도
  그건 깨어난 찰나의 on-CPU 일 뿐 대기 길이가 아님.

## 전체 함수 평탄표
트리 컷(0.03%) 아래 저빈도 함수까지 **샘플된 1,616 종 전부**는 `analysis/inclusive_total.txt`(컷오프 없음) 참조.
복제 적용 경로만 따로 본 콜체인은 `repl_apply_callchain.md`.

## thread 분포 (% of total)
| % | samples | thread |
|---:|---:|---|
| 73.47 | 92,816 | `transaction` (update 적용 워커) |
| 12.26 | 15,489 | `connections` |
| 4.11 | 5,195 | `dwb-flush-block` |
| 3.47 | 4,378 | `vacuum` |
| 1.91 | 2,414 | `coordinator` |
| 1.69 | 2,137 | `log-flush` |
| 0.89 | 1,123 | `vacuum-master` |
| 0.68 | 861 | `dwb-file-sync` |
| 0.34 | 424 | `pgbuf-flush-con` |
| ~1.19 | 1,500 | 기타 8종 (deadlock-detect, pgbuf-maintain, log-clock …) |

---

```
# 전체 on-CPU 콜체인 (모든 thread·함수, 노드 % = of total_samples=126337)
# 함수 노드 컷 0.03% / thread 컷 0.05% / MIN_EDGE 10

[100.00%] (ALL on-CPU)   total_samples=126337
├─ [ 73.47%] «transaction»  (92816 smp)
│   ├─ [ 23.21%] __GI___clone   ◆덩어리#1 (이 스레드의 독립 호출 조각 — 상위는 truncation 으로 끊김)
│   │   └─ [ 23.21%] start_thread
│   │       └─ [ 23.21%] execute_native_thread_routine
│   │           └─ [ 23.21%] cubthread::worker_pool::core::worker::run
│   │               ├─ [ 20.36%] cubthread::worker_pool::core::worker::execute_current_task
│   │               │   ├─ [ 20.11%] css_server_task::execute
│   │               │   │   ├─ [ 19.18%] css_internal_request_handler
│   │               │   │   │   ├─ [ 18.96%] net_server_request
│   │               │   │   │   │   ├─ [ 17.78%] slocator_repl_force
│   │               │   │   │   │   │   ├─ [ 15.08%] xlocator_repl_force
│   │               │   │   │   │   │   │   ├─ [  8.69%] xbtree_find_unique
│   │               │   │   │   │   │   │   │   ├─ [  4.04%] btree_key_find_and_lock_unique
│   │               │   │   │   │   │   │   │   │   └─ [  4.01%] btree_key_find_and_lock_unique_of_unique
│   │               │   │   │   │   │   │   │   │       ├─ [  3.84%] btree_key_lock_object
│   │               │   │   │   │   │   │   │   │       │   ├─ [  7.00%] lock_object
│   │               │   │   │   │   │   │   │   │       │   │   ├─ [  6.36%] lock_internal_perform_lock_object
│   │               │   │   │   │   │   │   │   │       │   │   │   ├─ [  3.12%] cubthread::lockfree_hashmap<lk_res_key, lk_res>::find_or_insert
│   │               │   │   │   │   │   │   │   │       │   │   │   │   └─ [  3.38%] lf_hash_insert_internal
│   │               │   │   │   │   │   │   │   │       │   │   │   │       ├─ [  2.90%] lf_list_insert_internal
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   ├─ [  2.26%] lock_res_key_compare
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   ├─ [  0.92%] lf_freelist_claim
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   ├─ [  0.35%] lf_stack_pop
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   └─ [  0.10%] ATOMIC_CAS_ADDR<void>
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   ├─ [  0.26%] lf_freelist_alloc_block
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   ├─ [  0.14%] lock_alloc_resource
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   │   └─ [  1.66%] cub_alloc
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   │       ├─ [  2.03%] __GI___libc_malloc
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   │       │   └─ [  1.59%] _int_malloc
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   │       │       ├─ [  0.58%] malloc_consolidate
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   │       │       │   └─ [  0.37%] unlink_chunk.isra.2
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   │       │       └─ [  0.37%] unlink_chunk.isra.2
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   │       └─ [  0.07%] malloc@plt
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   └─ [  2.03%] __GI___libc_malloc  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   ├─ [  0.22%] ATOMIC_INC_32<int, int>
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   ├─ [  0.54%] lf_freelist_transport
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   ├─ [  0.47%] lock_dealloc_entry
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   │   ├─ [  0.79%] _int_free
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   │   │   ├─ [  0.58%] malloc_consolidate  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   │   │   └─ [  0.37%] unlink_chunk.isra.2
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   │   └─ [  0.14%] __GI___libc_free
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   └─ [  0.05%] lock_dealloc_resource
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │       ├─ [  0.79%] _int_free  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │       └─ [  0.14%] __GI___libc_free
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   └─ [  0.20%] lf_tran_start
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │       └─ [  0.04%] ATOMIC_INC_64<unsigned long, int>
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   ├─ [  2.05%] __GI___pthread_mutex_lock
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   └─ [  0.14%] __lll_lock_wait
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   ├─ [  0.20%] lf_tran_start  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   ├─ [  0.03%] heap_hfid_table_entry_key_compare
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   ├─ [  0.10%] ATOMIC_CAS_ADDR<void>
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   ├─ [  0.03%] lf_tran_start@plt
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   └─ [  0.05%] lf_tran_end@plt
│   │               │   │   │   │   │   │   │   │       │   │   │   │       ├─ [  0.10%] heap_hfid_table_entry_key_hash
│   │               │   │   │   │   │   │   │   │       │   │   │   │       └─ [  0.12%] lock_res_key_hash
│   │               │   │   │   │   │   │   │   │       │   │   │   │           └─ [  0.09%] lock_get_hash_value
│   │               │   │   │   │   │   │   │   │       │   │   │   ├─ [  1.98%] lock_escalate_if_needed
│   │               │   │   │   │   │   │   │   │       │   │   │   │   └─ [  2.09%] __pthread_mutex_unlock_usercnt
│   │               │   │   │   │   │   │   │   │       │   │   │   │       └─ [  0.28%] __lll_unlock_wake
│   │               │   │   │   │   │   │   │   │       │   │   │   ├─ [  1.91%] lock_remove_all_inst_locks
│   │               │   │   │   │   │   │   │   │       │   │   │   │   ├─ [  0.95%] lock_remove_resource
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │   └─ [  0.95%] lf_hash_delete_already_locked
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │       ├─ [  0.90%] lf_list_delete
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │       │   ├─ [  2.26%] lock_res_key_compare
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │       │   ├─ [  0.67%] lf_freelist_retire
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │       │   │   ├─ [  0.54%] lf_freelist_transport  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │       │   │   ├─ [  0.22%] ATOMIC_INC_32<int, int>
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │       │   │   └─ [  0.20%] lf_tran_start  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │       │   ├─ [  0.20%] lf_tran_start  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │       │   ├─ [  0.10%] ATOMIC_CAS_ADDR<void>
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │       │   └─ [  2.09%] __pthread_mutex_unlock_usercnt  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │       └─ [  0.04%] lf_hash_delete_internal
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │           └─ [  0.12%] lock_res_key_hash  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   │   └─ [  0.76%] lock_internal_perform_unlock_object
│   │               │   │   │   │   │   │   │   │       │   │   │   │       ├─ [  0.67%] lf_freelist_retire  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   │       ├─ [  2.09%] __pthread_mutex_unlock_usercnt  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   │       ├─ [  2.05%] __GI___pthread_mutex_lock  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   │       └─ [  0.03%] lock_delete_from_tran_hold_list
│   │               │   │   │   │   │   │   │   │       │   │   │   │           └─ [  2.05%] __GI___pthread_mutex_lock  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   ├─ [  0.92%] lf_freelist_claim  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   ├─ [  0.13%] lock_event_set_xasl_id_to_entry
│   │               │   │   │   │   │   │   │   │       │   │   │   │   └─ [  0.68%] LOG_FIND_TDES
│   │               │   │   │   │   │   │   │   │       │   │   │   ├─ [  0.12%] lock_insert_into_tran_hold_list
│   │               │   │   │   │   │   │   │   │       │   │   │   │   └─ [  2.05%] __GI___pthread_mutex_lock  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   ├─ [  2.09%] __pthread_mutex_unlock_usercnt  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   ├─ [  0.26%] lock_find_class_entry
│   │               │   │   │   │   │   │   │   │       │   │   │   │   ├─ [  2.05%] __GI___pthread_mutex_lock  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   │   └─ [  2.09%] __pthread_mutex_unlock_usercnt  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   ├─ [  2.05%] __GI___pthread_mutex_lock  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   └─ [  0.08%] perfmon_inc_stat
│   │               │   │   │   │   │   │   │   │       │   │   │       └─ [  0.08%] perfmon_add_stat
│   │               │   │   │   │   │   │   │   │       │   │   │           ├─ [  0.12%] perfmon_is_perf_tracking
│   │               │   │   │   │   │   │   │   │       │   │   │           └─ [  2.18%] pgbuf_unfix
│   │               │   │   │   │   │   │   │   │       │   │   │               ├─ [  1.23%] pgbuf_unlatch_bcb_upon_unfix
│   │               │   │   │   │   │   │   │   │       │   │   │               │   ├─ [  0.18%] pgbuf_wakeup_reader_writer
│   │               │   │   │   │   │   │   │   │       │   │   │               │   │   └─ [  0.17%] set_waiter_exists
│   │               │   │   │   │   │   │   │   │       │   │   │               │   ├─ [  2.09%] __pthread_mutex_unlock_usercnt  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │               │   ├─ [  0.08%] pgbuf_lru_boost_bcb
│   │               │   │   │   │   │   │   │   │       │   │   │               │   │   └─ [  0.06%] pgbuf_remove_from_lru_list
│   │               │   │   │   │   │   │   │   │       │   │   │               │   │       └─ [  0.05%] pgbuf_bcb_change_zone
│   │               │   │   │   │   │   │   │   │       │   │   │               │   │           ├─ [  0.04%] ATOMIC_CAS_32<int, int, int>
│   │               │   │   │   │   │   │   │   │       │   │   │               │   │           └─ [  0.22%] ATOMIC_INC_32<int, int>
│   │               │   │   │   │   │   │   │   │       │   │   │               │   └─ [  0.06%] __GI___pthread_mutex_unlock
│   │               │   │   │   │   │   │   │   │       │   │   │               ├─ [  2.05%] __GI___pthread_mutex_lock  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │               ├─ [  0.26%] pgbuf_lru_move_from_private_to_shared
│   │               │   │   │   │   │   │   │   │       │   │   │               │   ├─ [  0.13%] pgbuf_lru_remove_bcb
│   │               │   │   │   │   │   │   │   │       │   │   │               │   │   ├─ [  0.06%] pgbuf_remove_from_lru_list  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │               │   │   └─ [  2.05%] __GI___pthread_mutex_lock  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │               │   ├─ [  0.05%] pgbuf_lru_add_new_bcb_to_middle
│   │               │   │   │   │   │   │   │   │       │   │   │               │   └─ [  2.05%] __GI___pthread_mutex_lock  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │               ├─ [  0.16%] pgbuf_unlatch_thrd_holder
│   │               │   │   │   │   │   │   │   │       │   │   │               │   ├─ [  0.04%] pgbuf_remove_thrd_holder
│   │               │   │   │   │   │   │   │   │       │   │   │               │   └─ [  0.07%] pgbuf_find_thrd_holder
│   │               │   │   │   │   │   │   │   │       │   │   │               ├─ [  0.11%] xdisk_get_purpose
│   │               │   │   │   │   │   │   │   │       │   │   │               ├─ [  0.12%] perfmon_is_perf_tracking
│   │               │   │   │   │   │   │   │   │       │   │   │               ├─ [  0.04%] xdisk_get_purpose@plt
│   │               │   │   │   │   │   │   │   │       │   │   │               └─ [  0.07%] pthread_mutex_lock@plt
│   │               │   │   │   │   │   │   │   │       │   │   ├─ [  0.28%] lock_get_class_lock
│   │               │   │   │   │   │   │   │   │       │   │   │   ├─ [  2.05%] __GI___pthread_mutex_lock  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   ├─ [  0.10%] logtb_get_current_tran_index
│   │               │   │   │   │   │   │   │   │       │   │   │   │   └─ [  0.29%] thread_get_thread_entry_info
│   │               │   │   │   │   │   │   │   │       │   │   │   │       ├─ [  0.23%] cubthread::get_entry
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   ├─ [  0.21%] __tls_get_addr
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   └─ [  0.05%] __tls_get_addr@plt
│   │               │   │   │   │   │   │   │   │       │   │   │   │       └─ [  0.06%] cubthread::get_entry@plt
│   │               │   │   │   │   │   │   │   │       │   │   │   └─ [  2.09%] __pthread_mutex_unlock_usercnt  ↑
│   │               │   │   │   │   │   │   │   │       │   │   ├─ [  0.26%] lock_find_class_entry  ↑
│   │               │   │   │   │   │   │   │   │       │   │   ├─ [  0.04%] logtb_find_wait_msecs
│   │               │   │   │   │   │   │   │   │       │   │   │   └─ [  0.68%] LOG_FIND_TDES
│   │               │   │   │   │   │   │   │   │       │   │   └─ [  0.05%] prm_get_integer_value
│   │               │   │   │   │   │   │   │   │       │   └─ [  0.04%] lock_object@plt
│   │               │   │   │   │   │   │   │   │       ├─ [  0.07%] btree_leaf_get_first_object
│   │               │   │   │   │   │   │   │   │       ├─ [  0.57%] spage_get_record
│   │               │   │   │   │   │   │   │   │       │   └─ [  0.38%] spage_find_slot
│   │               │   │   │   │   │   │   │   │       │       └─ [  0.11%] spage_is_unknown_slot
│   │               │   │   │   │   │   │   │   │       └─ [  1.69%] spage_get_record_data
│   │               │   │   │   │   │   │   │   │           ├─ [  4.68%] __memmove_evex_unaligned_erms
│   │               │   │   │   │   │   │   │   │           └─ [  0.04%] memcpy@plt
│   │               │   │   │   │   │   │   │   ├─ [  3.79%] btree_search_key_and_apply_functions
│   │               │   │   │   │   │   │   │   │   ├─ [  1.44%] btree_advance_and_find_key
│   │               │   │   │   │   │   │   │   │   │   ├─ [  3.26%] pgbuf_fix_release
│   │               │   │   │   │   │   │   │   │   │   │   ├─ [  0.85%] pgbuf_set_bcb_page_vpid
│   │               │   │   │   │   │   │   │   │   │   │   ├─ [  0.38%] pgbuf_search_hash_chain
│   │               │   │   │   │   │   │   │   │   │   │   │   └─ [  0.50%] __GI___pthread_mutex_trylock
│   │               │   │   │   │   │   │   │   │   │   │   ├─ [  0.31%] pgbuf_latch_bcb_upon_fix
│   │               │   │   │   │   │   │   │   │   │   │   │   ├─ [  0.04%] pgbuf_allocate_thrd_holder_entry
│   │               │   │   │   │   │   │   │   │   │   │   │   └─ [  0.07%] pgbuf_find_thrd_holder
│   │               │   │   │   │   │   │   │   │   │   │   ├─ [  0.20%] pgbuf_lockfree_fix_ro
│   │               │   │   │   │   │   │   │   │   │   │   │   ├─ [  0.06%] pgbuf_search_hash_chain_no_bcb_lock
│   │               │   │   │   │   │   │   │   │   │   │   │   └─ [  0.12%] pgbuf_hash_func_mirror
│   │               │   │   │   │   │   │   │   │   │   │   ├─ [  2.09%] __pthread_mutex_unlock_usercnt  ↑
│   │               │   │   │   │   │   │   │   │   │   │   ├─ [  0.09%] pgbuf_bcb_register_fix
│   │               │   │   │   │   │   │   │   │   │   │   │   └─ [  0.22%] ATOMIC_INC_32<int, int>
│   │               │   │   │   │   │   │   │   │   │   │   ├─ [  0.10%] logtb_is_interrupted
│   │               │   │   │   │   │   │   │   │   │   │   │   └─ [  0.68%] LOG_FIND_TDES
│   │               │   │   │   │   │   │   │   │   │   │   ├─ [  0.12%] pgbuf_hash_func_mirror
│   │               │   │   │   │   │   │   │   │   │   │   └─ [  0.06%] pgbuf_find_current_wait_msecs
│   │               │   │   │   │   │   │   │   │   │   │       └─ [  0.68%] LOG_FIND_TDES
│   │               │   │   │   │   │   │   │   │   │   └─ [  0.06%] btree_get_node_header
│   │               │   │   │   │   │   │   │   │   │       ├─ [  0.57%] spage_get_record  ↑
│   │               │   │   │   │   │   │   │   │   │       └─ [  1.69%] spage_get_record_data  ↑
│   │               │   │   │   │   │   │   │   │   ├─ [  0.71%] btree_get_root_with_key
│   │               │   │   │   │   │   │   │   │   │   ├─ [  3.26%] pgbuf_fix_release  ↑
│   │               │   │   │   │   │   │   │   │   │   ├─ [  0.19%] btree_fix_root_with_info
│   │               │   │   │   │   │   │   │   │   │   │   ├─ [  0.11%] btree_glean_root_header_info
│   │               │   │   │   │   │   │   │   │   │   │   │   └─ [  0.18%] or_get_domain
│   │               │   │   │   │   │   │   │   │   │   │   │       ├─ [  0.05%] unpack_domain
│   │               │   │   │   │   │   │   │   │   │   │   │       │   └─ [  0.07%] or_get_int
│   │               │   │   │   │   │   │   │   │   │   │   │       │       ├─ [  1.00%] btree_search_nonleaf_page
│   │               │   │   │   │   │   │   │   │   │   │   │       │       │   ├─ [  0.62%] btree_read_record_without_decompression
│   │               │   │   │   │   │   │   │   │   │   │   │       │       │   │   ├─ [  0.22%] mr_index_readval_int
│   │               │   │   │   │   │   │   │   │   │   │   │       │       │   │   │   ├─ [  4.68%] __memmove_evex_unaligned_erms
│   │               │   │   │   │   │   │   │   │   │   │   │       │       │   │   │   └─ [  0.04%] memcpy@plt
│   │               │   │   │   │   │   │   │   │   │   │   │       │       │   │   ├─ [  1.05%] btree_search_leaf_page
│   │               │   │   │   │   │   │   │   │   │   │   │       │       │   │   │   ├─ [  0.46%] btree_compare_key
│   │               │   │   │   │   │   │   │   │   │   │   │       │       │   │   │   │   └─ [  0.12%] mr_cmpval_int
│   │               │   │   │   │   │   │   │   │   │   │   │       │       │   │   │   ├─ [  0.57%] spage_get_record  ↑
│   │               │   │   │   │   │   │   │   │   │   │   │       │       │   │   │   ├─ [  1.69%] spage_get_record_data  ↑
│   │               │   │   │   │   │   │   │   │   │   │   │       │       │   │   │   ├─ [  0.12%] mr_cmpval_int
│   │               │   │   │   │   │   │   │   │   │   │   │       │       │   │   │   ├─ [  0.07%] btree_clear_key_value
│   │               │   │   │   │   │   │   │   │   │   │   │       │       │   │   │   └─ [  0.06%] btree_compare_key@plt
│   │               │   │   │   │   │   │   │   │   │   │   │       │       │   │   ├─ [  0.08%] btree_read_fixed_portion_of_non_leaf_record_from_orbuf
│   │               │   │   │   │   │   │   │   │   │   │   │       │       │   │   ├─ [  0.05%] or_init
│   │               │   │   │   │   │   │   │   │   │   │   │       │       │   │   └─ [  0.07%] btree_clear_key_value  ↑
│   │               │   │   │   │   │   │   │   │   │   │   │       │       │   ├─ [  0.46%] btree_compare_key  ↑
│   │               │   │   │   │   │   │   │   │   │   │   │       │       │   ├─ [  0.57%] spage_get_record  ↑
│   │               │   │   │   │   │   │   │   │   │   │   │       │       │   ├─ [  1.69%] spage_get_record_data  ↑
│   │               │   │   │   │   │   │   │   │   │   │   │       │       │   ├─ [  0.06%] btree_node_number_of_keys
│   │               │   │   │   │   │   │   │   │   │   │   │       │       │   ├─ [  0.06%] btree_compare_key@plt
│   │               │   │   │   │   │   │   │   │   │   │   │       │       │   ├─ [  0.07%] btree_clear_key_value  ↑
│   │               │   │   │   │   │   │   │   │   │   │   │       │       │   └─ [  0.10%] spage_get_record@plt
│   │               │   │   │   │   │   │   │   │   │   │   │       │       └─ [  0.04%] __bswap_32
│   │               │   │   │   │   │   │   │   │   │   │   │       └─ [  0.05%] tp_domain_resolve_default
│   │               │   │   │   │   │   │   │   │   │   │   └─ [  0.08%] btree_get_root_header
│   │               │   │   │   │   │   │   │   │   │   │       ├─ [  0.57%] spage_get_record  ↑
│   │               │   │   │   │   │   │   │   │   │   │       └─ [  0.10%] spage_get_record@plt
│   │               │   │   │   │   │   │   │   │   │   └─ [  0.04%] pgbuf_fix_release@plt
│   │               │   │   │   │   │   │   │   │   └─ [  2.18%] pgbuf_unfix  ↑
│   │               │   │   │   │   │   │   │   ├─ [  1.05%] btree_search_leaf_page  ↑
│   │               │   │   │   │   │   │   │   ├─ [  1.00%] btree_search_nonleaf_page  ↑
│   │               │   │   │   │   │   │   │   ├─ [  7.00%] lock_object  ↑
│   │               │   │   │   │   │   │   │   ├─ [  0.14%] oid_check_cached_class_oid
│   │               │   │   │   │   │   │   │   ├─ [  0.04%] logtb_get_mvcc_snapshot
│   │               │   │   │   │   │   │   │   ├─ [  0.04%] mvcc_snapshot::mvcc_snapshot
│   │               │   │   │   │   │   │   │   ├─ [  0.04%] oid_check_cached_class_oid@plt
│   │               │   │   │   │   │   │   │   ├─ [  0.04%] lock_object@plt
│   │               │   │   │   │   │   │   │   └─ [  0.05%] logtb_find_isolation
│   │               │   │   │   │   │   │   │       └─ [  0.68%] LOG_FIND_TDES
│   │               │   │   │   │   │   │   ├─ [  2.88%] locator_repl_prepare_force
│   │               │   │   │   │   │   │   │   ├─ [  1.56%] heap_get_visible_version
│   │               │   │   │   │   │   │   │   │   ├─ [  0.90%] heap_get_visible_version_internal
│   │               │   │   │   │   │   │   │   │   │   ├─ [  0.92%] heap_prepare_get_context
│   │               │   │   │   │   │   │   │   │   │   │   ├─ [  0.09%] heap_prepare_object_page
│   │               │   │   │   │   │   │   │   │   │   │   │   └─ [  2.66%] pgbuf_ordered_fix_release
│   │               │   │   │   │   │   │   │   │   │   │   │       ├─ [  3.26%] pgbuf_fix_release  ↑
│   │               │   │   │   │   │   │   │   │   │   │   │       └─ [  0.04%] pgbuf_fix_release@plt
│   │               │   │   │   │   │   │   │   │   │   │   └─ [  0.07%] spage_get_slot
│   │               │   │   │   │   │   │   │   │   │   │       └─ [  0.38%] spage_find_slot  ↑
│   │               │   │   │   │   │   │   │   │   │   └─ [  1.49%] heap_get_record_data_when_all_ready
│   │               │   │   │   │   │   │   │   │   │       ├─ [  1.69%] spage_get_record_data  ↑
│   │               │   │   │   │   │   │   │   │   │       ├─ [  0.10%] heap_scancache::assign_recdes_to_area
│   │               │   │   │   │   │   │   │   │   │       │   ├─ [  0.15%] cubmem::single_block_allocator::reserve
│   │               │   │   │   │   │   │   │   │   │       │   │   └─ [  0.07%] heap_scancache_block_allocate
│   │               │   │   │   │   │   │   │   │   │       │   │       ├─ [  0.04%] db_private_alloc_release
│   │               │   │   │   │   │   │   │   │   │       │   │       └─ [  0.13%] hl_lea_alloc
│   │               │   │   │   │   │   │   │   │   │       │   │           └─ [  0.09%] mspace_malloc
│   │               │   │   │   │   │   │   │   │   │       │   └─ [  0.29%] heap_scancache::reserve_area
│   │               │   │   │   │   │   │   │   │   │       │       └─ [  0.27%] heap_scancache::alloc_area
│   │               │   │   │   │   │   │   │   │   │       │           ├─ [  0.23%] cubmem::single_block_allocator::single_block_allocator
│   │               │   │   │   │   │   │   │   │   │       │           │   ├─ [  0.14%] cubmem::block_allocator::block_allocator
│   │               │   │   │   │   │   │   │   │   │       │           │   │   ├─ [  0.15%] std::_Function_base::_Base_manager<std::_Bind<void (cubmem::single_block_allocator::*(cubmem::single_block_allocator*, std::_Placeholder<1>))(cubmem::block&)> >::_M_manager
│   │               │   │   │   │   │   │   │   │   │       │           │   │   │   ├─ [  0.51%] operator new
│   │               │   │   │   │   │   │   │   │   │       │           │   │   │   │   ├─ [  2.03%] __GI___libc_malloc  ↑
│   │               │   │   │   │   │   │   │   │   │       │           │   │   │   │   ├─ [  1.66%] cub_alloc  ↑
│   │               │   │   │   │   │   │   │   │   │       │           │   │   │   │   └─ [  0.07%] malloc@plt
│   │               │   │   │   │   │   │   │   │   │       │           │   │   │   └─ [  0.11%] operator delete
│   │               │   │   │   │   │   │   │   │   │       │           │   │   │       └─ [  0.16%] cub_free
│   │               │   │   │   │   │   │   │   │   │       │           │   │   │           ├─ [  0.79%] _int_free  ↑
│   │               │   │   │   │   │   │   │   │   │       │           │   │   │           └─ [  0.14%] __GI___libc_free
│   │               │   │   │   │   │   │   │   │   │       │           │   │   └─ [  0.05%] std::_Function_base::_Base_manager<std::_Bind<void (cubmem::single_block_allocator::*(cubmem::single_block_allocator*, std::_Placeholder<1>, std::_Placeholder<2>))(cubmem::block&, unsigned long)> >::_M_manager
│   │               │   │   │   │   │   │   │   │   │       │           │   │       ├─ [  0.11%] operator delete  ↑
│   │               │   │   │   │   │   │   │   │   │       │           │   │       └─ [  0.51%] operator new  ↑
│   │               │   │   │   │   │   │   │   │   │       │           │   ├─ [  0.51%] operator new  ↑
│   │               │   │   │   │   │   │   │   │   │       │           │   ├─ [  0.05%] std::_Function_base::_Base_manager<std::_Bind<void (cubmem::single_block_allocator::*(cubmem::single_block_allocator*, std::_Placeholder<1>, std::_Placeholder<2>))(cubmem::block&, unsigned long)> >::_M_manager  ↑
│   │               │   │   │   │   │   │   │   │   │       │           │   └─ [  0.15%] std::_Function_base::_Base_manager<std::_Bind<void (cubmem::single_block_allocator::*(cubmem::single_block_allocator*, std::_Placeholder<1>))(cubmem::block&)> >::_M_manager  ↑
│   │               │   │   │   │   │   │   │   │   │       │           └─ [  0.51%] operator new  ↑
│   │               │   │   │   │   │   │   │   │   │       ├─ [  0.57%] spage_get_record  ↑
│   │               │   │   │   │   │   │   │   │   │       └─ [  0.10%] spage_get_record@plt
│   │               │   │   │   │   │   │   │   │   ├─ [  1.04%] heap_clean_get_context
│   │               │   │   │   │   │   │   │   │   │   ├─ [  2.18%] pgbuf_unfix  ↑
│   │               │   │   │   │   │   │   │   │   │   ├─ [  0.09%] pgbuf_replace_watcher
│   │               │   │   │   │   │   │   │   │   │   │   └─ [  0.06%] pgbuf_remove_watcher
│   │               │   │   │   │   │   │   │   │   │   └─ [  0.12%] pgbuf_ordered_unfix
│   │               │   │   │   │   │   │   │   │   │       └─ [  0.06%] pgbuf_remove_watcher
│   │               │   │   │   │   │   │   │   │   └─ [  0.07%] heap_init_get_context
│   │               │   │   │   │   │   │   │   ├─ [  0.92%] heap_get_class_repr_id
│   │               │   │   │   │   │   │   │   │   ├─ [  1.51%] heap_classrepr_get
│   │               │   │   │   │   │   │   │   │   │   ├─ [  2.09%] __pthread_mutex_unlock_usercnt  ↑
│   │               │   │   │   │   │   │   │   │   │   ├─ [  2.05%] __GI___pthread_mutex_lock  ↑
│   │               │   │   │   │   │   │   │   │   │   ├─ [  0.50%] __GI___pthread_mutex_trylock
│   │               │   │   │   │   │   │   │   │   │   ├─ [  0.06%] __GI___pthread_mutex_unlock
│   │               │   │   │   │   │   │   │   │   │   └─ [  0.05%] pthread_mutex_unlock@plt
│   │               │   │   │   │   │   │   │   │   ├─ [  1.05%] heap_classrepr_free
│   │               │   │   │   │   │   │   │   │   │   ├─ [  2.09%] __pthread_mutex_unlock_usercnt  ↑
│   │               │   │   │   │   │   │   │   │   │   ├─ [  2.05%] __GI___pthread_mutex_lock  ↑
│   │               │   │   │   │   │   │   │   │   │   ├─ [  0.07%] pthread_mutex_lock@plt
│   │               │   │   │   │   │   │   │   │   │   └─ [  0.06%] __GI___pthread_mutex_unlock
│   │               │   │   │   │   │   │   │   │   └─ [  0.03%] heap_classrepr_get@plt
│   │               │   │   │   │   │   │   │   ├─ [  0.30%] btree_get_pkey_btid
│   │               │   │   │   │   │   │   │   │   ├─ [  1.51%] heap_classrepr_get  ↑
│   │               │   │   │   │   │   │   │   │   └─ [  1.05%] heap_classrepr_free  ↑
│   │               │   │   │   │   │   │   │   └─ [  0.04%] or_chn
│   │               │   │   │   │   │   │   ├─ [  1.37%] xtran_server_end_topop
│   │               │   │   │   │   │   │   │   ├─ [  0.62%] log_sysop_attach_to_outer
│   │               │   │   │   │   │   │   │   │   ├─ [  0.38%] log_tdes::unlock_topop
│   │               │   │   │   │   │   │   │   │   │   ├─ [  0.38%] cubpl::get_session
│   │               │   │   │   │   │   │   │   │   │   │   ├─ [  0.27%] session_get_pl_session
│   │               │   │   │   │   │   │   │   │   │   │   │   ├─ [  0.16%] cubpl::session::is_sp_running
│   │               │   │   │   │   │   │   │   │   │   │   │   │   ├─ [  2.05%] __GI___pthread_mutex_lock  ↑
│   │               │   │   │   │   │   │   │   │   │   │   │   │   └─ [  2.09%] __pthread_mutex_unlock_usercnt  ↑
│   │               │   │   │   │   │   │   │   │   │   │   │   └─ [  0.08%] session_get_session_state
│   │               │   │   │   │   │   │   │   │   │   │   └─ [  0.29%] thread_get_thread_entry_info  ↑
│   │               │   │   │   │   │   │   │   │   │   └─ [  0.14%] cubpl::session::is_thread_involved
│   │               │   │   │   │   │   │   │   │   │       ├─ [  2.09%] __pthread_mutex_unlock_usercnt  ↑
│   │               │   │   │   │   │   │   │   │   │       └─ [  2.05%] __GI___pthread_mutex_lock  ↑
│   │               │   │   │   │   │   │   │   │   ├─ [  0.08%] log_sysop_end_final
│   │               │   │   │   │   │   │   │   │   │   ├─ [  0.04%] log_tdes::on_sysop_end
│   │               │   │   │   │   │   │   │   │   │   │   ├─ [  0.06%] log_tdes::is_system_worker_transaction@plt
│   │               │   │   │   │   │   │   │   │   │   │   └─ [  0.05%] log_tdes::is_system_worker_transaction
│   │               │   │   │   │   │   │   │   │   │   └─ [  0.08%] perfmon_inc_stat  ↑
│   │               │   │   │   │   │   │   │   │   ├─ [  0.24%] rmutex_unlock
│   │               │   │   │   │   │   │   │   │   │   ├─ [  2.09%] __pthread_mutex_unlock_usercnt  ↑
│   │               │   │   │   │   │   │   │   │   │   └─ [  0.29%] thread_get_thread_entry_info  ↑
│   │               │   │   │   │   │   │   │   │   └─ [  0.03%] LSA_ISNULL
│   │               │   │   │   │   │   │   │   ├─ [  0.34%] cuberr::context::pop_error_stack_and_destroy
│   │               │   │   │   │   │   │   │   │   ├─ [  0.18%] cuberr::context::pop_error_stack
│   │               │   │   │   │   │   │   │   │   │   ├─ [  0.10%] cuberr::er_message::swap
│   │               │   │   │   │   │   │   │   │   │   └─ [  0.11%] operator delete  ↑
│   │               │   │   │   │   │   │   │   │   ├─ [  0.09%] cuberr::er_message::~er_message
│   │               │   │   │   │   │   │   │   │   │   └─ [  0.03%] cuberr::er_message::clear_message_area
│   │               │   │   │   │   │   │   │   │   └─ [  0.14%] cuberr::er_message::er_message
│   │               │   │   │   │   │   │   │   ├─ [  0.23%] cuberr::context::push_error_stack
│   │               │   │   │   │   │   │   │   │   ├─ [  0.51%] operator new  ↑
│   │               │   │   │   │   │   │   │   │   └─ [  0.14%] cuberr::er_message::er_message
│   │               │   │   │   │   │   │   │   ├─ [  0.09%] er_stack_push
│   │               │   │   │   │   │   │   │   │   └─ [  0.12%] cuberr::context::get_thread_local_context
│   │               │   │   │   │   │   │   │   │       └─ [  0.21%] __tls_get_addr
│   │               │   │   │   │   │   │   │   └─ [  0.10%] LOG_FIND_CURRENT_TDES
│   │               │   │   │   │   │   │   │       └─ [  0.68%] LOG_FIND_TDES
│   │               │   │   │   │   │   │   ├─ [  0.58%] xtran_server_start_topop
│   │               │   │   │   │   │   │   │   ├─ [  0.47%] log_sysop_start
│   │               │   │   │   │   │   │   │   │   ├─ [  0.21%] log_tdes::lock_topop
│   │               │   │   │   │   │   │   │   │   │   ├─ [  0.38%] cubpl::get_session  ↑
│   │               │   │   │   │   │   │   │   │   │   └─ [  0.14%] cubpl::session::is_thread_involved  ↑
│   │               │   │   │   │   │   │   │   │   ├─ [  0.67%] rmutex_lock
│   │               │   │   │   │   │   │   │   │   │   ├─ [  0.18%] tsc_getticks
│   │               │   │   │   │   │   │   │   │   │   │   └─ [  0.22%] __clock_gettime_2
│   │               │   │   │   │   │   │   │   │   │   ├─ [  2.05%] __GI___pthread_mutex_lock  ↑
│   │               │   │   │   │   │   │   │   │   │   └─ [  0.29%] thread_get_thread_entry_info  ↑
│   │               │   │   │   │   │   │   │   │   ├─ [  0.68%] LOG_FIND_TDES
│   │               │   │   │   │   │   │   │   │   ├─ [  0.05%] rmutex_lock@plt
│   │               │   │   │   │   │   │   │   │   ├─ [  0.04%] log_tdes::on_sysop_start
│   │               │   │   │   │   │   │   │   │   │   ├─ [  0.06%] log_tdes::is_system_worker_transaction@plt
│   │               │   │   │   │   │   │   │   │   │   └─ [  0.05%] log_tdes::is_system_worker_transaction
│   │               │   │   │   │   │   │   │   │   └─ [  0.08%] perfmon_inc_stat  ↑
│   │               │   │   │   │   │   │   │   ├─ [  0.06%] log_get_parent_lsa_system_op
│   │               │   │   │   │   │   │   │   │   └─ [  0.68%] LOG_FIND_TDES
│   │               │   │   │   │   │   │   │   └─ [  0.06%] locator_savepoint_transient_class_name_entries
│   │               │   │   │   │   │   │   ├─ [  0.53%] heap_get_class_info
│   │               │   │   │   │   │   │   │   └─ [  0.51%] heap_hfid_cache_get
│   │               │   │   │   │   │   │   │       └─ [  3.38%] lf_hash_insert_internal  ↑
│   │               │   │   │   │   │   │   ├─ [  0.34%] heap_scancache_start_modify
│   │               │   │   │   │   │   │   │   ├─ [  0.22%] file_get_type
│   │               │   │   │   │   │   │   │   │   ├─ [  3.26%] pgbuf_fix_release  ↑
│   │               │   │   │   │   │   │   │   │   └─ [  2.18%] pgbuf_unfix  ↑
│   │               │   │   │   │   │   │   │   └─ [  0.08%] heap_scancache_reset_modify
│   │               │   │   │   │   │   │   │       ├─ [  0.53%] heap_get_class_info  ↑
│   │               │   │   │   │   │   │   │       └─ [  0.16%] mvcc_is_mvcc_disabled_class
│   │               │   │   │   │   │   │   │           ├─ [  0.14%] oid_check_cached_class_oid
│   │               │   │   │   │   │   │   │           └─ [  0.04%] oid_check_cached_class_oid@plt
│   │               │   │   │   │   │   │   ├─ [  0.24%] or_unpack_mem_value
│   │               │   │   │   │   │   │   │   ├─ [  0.18%] or_get_domain  ↑
│   │               │   │   │   │   │   │   │   └─ [  0.06%] mr_initval_int
│   │               │   │   │   │   │   │   │       └─ [  0.09%] db_value_domain_init
│   │               │   │   │   │   │   │   ├─ [  0.47%] heap_scancache_quick_end
│   │               │   │   │   │   │   │   │   ├─ [  2.18%] pgbuf_unfix  ↑
│   │               │   │   │   │   │   │   │   ├─ [  0.11%] heap_scancache::end_area
│   │               │   │   │   │   │   │   │   │   └─ [  0.10%] cubmem::single_block_allocator::~single_block_allocator
│   │               │   │   │   │   │   │   │   │       ├─ [  0.04%] heap_scancache_block_deallocate
│   │               │   │   │   │   │   │   │   │       │   └─ [  0.08%] mspace_free
│   │               │   │   │   │   │   │   │   │       ├─ [  0.05%] std::_Function_base::_Base_manager<std::_Bind<void (cubmem::single_block_allocator::*(cubmem::single_block_allocator*, std::_Placeholder<1>, std::_Placeholder<2>))(cubmem::block&, unsigned long)> >::_M_manager  ↑
│   │               │   │   │   │   │   │   │   │       └─ [  0.15%] std::_Function_base::_Base_manager<std::_Bind<void (cubmem::single_block_allocator::*(cubmem::single_block_allocator*, std::_Placeholder<1>))(cubmem::block&)> >::_M_manager  ↑
│   │               │   │   │   │   │   │   │   └─ [  0.12%] pgbuf_ordered_unfix  ↑
│   │               │   │   │   │   │   │   ├─ [  0.09%] er_clear
│   │               │   │   │   │   │   │   │   ├─ [  0.03%] er_is_initialized@plt
│   │               │   │   │   │   │   │   │   └─ [  0.12%] cuberr::context::get_thread_local_context  ↑
│   │               │   │   │   │   │   │   ├─ [  0.04%] cuberr::er_message::clear_error@plt
│   │               │   │   │   │   │   │   ├─ [  0.03%] cuberr::context::clear_current_error_level
│   │               │   │   │   │   │   │   ├─ [  0.07%] pr_clear_value
│   │               │   │   │   │   │   │   └─ [ 22.96%] locator_update_force
│   │               │   │   │   │   │   │       ├─ [ 16.47%] heap_update_logical
│   │               │   │   │   │   │   │       │   ├─ [ 22.00%] heap_log_update_physical
│   │               │   │   │   │   │   │       │   │   ├─ [ 26.25%] log_append_undoredo_recdes
│   │               │   │   │   │   │   │       │   │   │   ├─ [ 27.13%] log_append_undoredo_recdes2
│   │               │   │   │   │   │   │       │   │   │   │   └─ [ 27.14%] log_append_undoredo_crumbs
│   │               │   │   │   │   │   │       │   │   │   │       ├─ [ 25.73%] prior_lsa_alloc_and_copy_crumbs
│   │               │   │   │   │   │   │       │   │   │   │       │   ├─ [ 16.06%] prior_lsa_gen_undoredo_record_from_crumbs
│   │               │   │   │   │   │   │       │   │   │   │       │   │   ├─ [ 18.41%] log_zip
│   │               │   │   │   │   │   │       │   │   │   │       │   │   │   ├─ [ 16.65%] LZ4_compress_fast_extState
│   │               │   │   │   │   │   │       │   │   │   │       │   │   │   │   ├─ [  3.90%] LZ4_read_ARCH
│   │               │   │   │   │   │   │       │   │   │   │       │   │   │   │   ├─ [  1.16%] LZ4_read32
│   │               │   │   │   │   │   │       │   │   │   │       │   │   │   │   ├─ [  0.79%] LZ4_initStream
│   │               │   │   │   │   │   │       │   │   │   │       │   │   │   │   │   ├─ [  1.91%] __memset_evex_unaligned_erms
│   │               │   │   │   │   │   │       │   │   │   │       │   │   │   │   │   └─ [  0.04%] LZ4_isAligned
│   │               │   │   │   │   │   │       │   │   │   │       │   │   │   │   ├─ [  0.20%] LZ4_writeLE16
│   │               │   │   │   │   │   │       │   │   │   │       │   │   │   │   │   ├─ [  0.09%] LZ4_write16
│   │               │   │   │   │   │   │       │   │   │   │       │   │   │   │   │   └─ [  0.07%] LZ4_isLittleEndian
│   │               │   │   │   │   │   │       │   │   │   │       │   │   │   │   ├─ [  0.10%] LZ4_NbCommonBytes
│   │               │   │   │   │   │   │       │   │   │   │       │   │   │   │   │   └─ [  0.07%] LZ4_isLittleEndian
│   │               │   │   │   │   │   │       │   │   │   │       │   │   │   │   ├─ [  0.07%] LZ4_write32
│   │               │   │   │   │   │   │       │   │   │   │       │   │   │   │   ├─ [  4.68%] __memmove_evex_unaligned_erms
│   │               │   │   │   │   │   │       │   │   │   │       │   │   │   │   └─ [  0.04%] LZ4_compressBound
│   │               │   │   │   │   │   │       │   │   │   │       │   │   │   ├─ [  1.31%] LZ4_resetStream_fast
│   │               │   │   │   │   │   │       │   │   │   │       │   │   │   │   └─ [  1.91%] __memset_evex_unaligned_erms
│   │               │   │   │   │   │   │       │   │   │   │       │   │   │   ├─ [  0.21%] __tls_get_addr
│   │               │   │   │   │   │   │       │   │   │   │       │   │   │   ├─ [  1.16%] LZ4_read32
│   │               │   │   │   │   │   │       │   │   │   │       │   │   │   ├─ [  0.04%] log_zip_realloc_if_needed
│   │               │   │   │   │   │   │       │   │   │   │       │   │   │   ├─ [  3.90%] LZ4_read_ARCH
│   │               │   │   │   │   │   │       │   │   │   │       │   │   │   ├─ [  0.04%] LZ4_compressBound
│   │               │   │   │   │   │   │       │   │   │   │       │   │   │   ├─ [  0.12%] perfmon_is_perf_tracking
│   │               │   │   │   │   │   │       │   │   │   │       │   │   │   └─ [  0.20%] LZ4_writeLE16  ↑
│   │               │   │   │   │   │   │       │   │   │   │       │   │   ├─ [  5.36%] log_diff
│   │               │   │   │   │   │   │       │   │   │   │       │   │   ├─ [  4.68%] __memmove_evex_unaligned_erms
│   │               │   │   │   │   │   │       │   │   │   │       │   │   ├─ [  1.66%] cub_alloc  ↑
│   │               │   │   │   │   │   │       │   │   │   │       │   │   ├─ [  0.10%] LOG_FIND_CURRENT_TDES  ↑
│   │               │   │   │   │   │   │       │   │   │   │       │   │   └─ [  0.03%] pgbuf_get_vpid_ptr@plt
│   │               │   │   │   │   │   │       │   │   │   │       │   ├─ [ 18.41%] log_zip  ↑
│   │               │   │   │   │   │   │       │   │   │   │       │   ├─ [  1.66%] cub_alloc  ↑
│   │               │   │   │   │   │   │       │   │   │   │       │   ├─ [  0.28%] prior_lsa_copy_undo_data_to_node
│   │               │   │   │   │   │   │       │   │   │   │       │   │   ├─ [  1.66%] cub_alloc  ↑
│   │               │   │   │   │   │   │       │   │   │   │       │   │   └─ [  4.68%] __memmove_evex_unaligned_erms
│   │               │   │   │   │   │   │       │   │   │   │       │   ├─ [  0.27%] prior_lsa_copy_redo_data_to_node
│   │               │   │   │   │   │   │       │   │   │   │       │   │   └─ [  1.66%] cub_alloc  ↑
│   │               │   │   │   │   │   │       │   │   │   │       │   └─ [  0.05%] log_zip@plt
│   │               │   │   │   │   │   │       │   │   │   │       ├─ [  0.81%] prior_lsa_next_record_internal
│   │               │   │   │   │   │   │       │   │   │   │       │   ├─ [  2.05%] __GI___pthread_mutex_lock  ↑
│   │               │   │   │   │   │   │       │   │   │   │       │   ├─ [  2.09%] __pthread_mutex_unlock_usercnt  ↑
│   │               │   │   │   │   │   │       │   │   │   │       │   ├─ [  0.09%] vacuum_get_log_blockid
│   │               │   │   │   │   │   │       │   │   │   │       │   ├─ [  0.06%] prior_lsa_append_data
│   │               │   │   │   │   │   │       │   │   │   │       │   ├─ [  0.03%] prior_lsa_start_append
│   │               │   │   │   │   │   │       │   │   │   │       │   ├─ [  0.07%] pthread_mutex_lock@plt
│   │               │   │   │   │   │   │       │   │   │   │       │   ├─ [  0.05%] log_tdes::is_system_worker_transaction
│   │               │   │   │   │   │   │       │   │   │   │       │   └─ [  0.15%] __gthread_mutex_unlock
│   │               │   │   │   │   │   │       │   │   │   │       │       └─ [  2.09%] __pthread_mutex_unlock_usercnt  ↑
│   │               │   │   │   │   │   │       │   │   │   │       ├─ [  0.27%] pgbuf_set_lsa
│   │               │   │   │   │   │   │       │   │   │   │       │   ├─ [  0.18%] fileio_set_page_lsa
│   │               │   │   │   │   │   │       │   │   │   │       │   │   └─ [  0.20%] LSA_COPY
│   │               │   │   │   │   │   │       │   │   │   │       │   ├─ [  0.07%] pgbuf_set_dirty_buffer_ptr
│   │               │   │   │   │   │   │       │   │   │   │       │   │   ├─ [  0.07%] pgbuf_find_thrd_holder
│   │               │   │   │   │   │   │       │   │   │   │       │   │   ├─ [  0.08%] perfmon_inc_stat  ↑
│   │               │   │   │   │   │   │       │   │   │   │       │   │   └─ [  0.06%] pgbuf_set_dirty
│   │               │   │   │   │   │   │       │   │   │   │       │   └─ [  0.11%] xdisk_get_purpose
│   │               │   │   │   │   │   │       │   │   │   │       ├─ [  0.06%] pgbuf_is_lsa_temporary
│   │               │   │   │   │   │   │       │   │   │   │       │   └─ [  0.11%] xdisk_get_purpose
│   │               │   │   │   │   │   │       │   │   │   │       ├─ [  0.04%] log_can_skip_undo_logging
│   │               │   │   │   │   │   │       │   │   │   │       │   ├─ [  0.06%] log_tdes::is_system_worker_transaction@plt
│   │               │   │   │   │   │   │       │   │   │   │       │   └─ [  0.05%] log_tdes::is_system_worker_transaction
│   │               │   │   │   │   │   │       │   │   │   │       ├─ [  0.09%] logtb_find_client_type
│   │               │   │   │   │   │   │       │   │   │   │       │   └─ [  0.68%] LOG_FIND_TDES
│   │               │   │   │   │   │   │       │   │   │   │       ├─ [  0.68%] LOG_FIND_TDES
│   │               │   │   │   │   │   │       │   │   │   │       └─ [  5.36%] log_diff
│   │               │   │   │   │   │   │       │   │   │   └─ [  0.03%] log_append_undoredo_recdes2@plt
│   │               │   │   │   │   │   │       │   │   ├─ [  0.27%] heap_page_update_chain_after_mvcc_op
│   │               │   │   │   │   │   │       │   │   │   └─ [  0.57%] spage_get_record  ↑
│   │               │   │   │   │   │   │       │   │   ├─ [  0.08%] heap_page_get_vacuum_status
│   │               │   │   │   │   │   │       │   │   │   ├─ [  0.57%] spage_get_record  ↑
│   │               │   │   │   │   │   │       │   │   │   └─ [  1.69%] spage_get_record_data  ↑
│   │               │   │   │   │   │   │       │   │   └─ [  0.09%] logtb_get_current_mvccid
│   │               │   │   │   │   │   │       │   │       └─ [  0.68%] LOG_FIND_TDES
│   │               │   │   │   │   │   │       │   ├─ [  4.49%] heap_update_home
│   │               │   │   │   │   │   │       │   │   ├─ [  0.64%] spage_is_updatable
│   │               │   │   │   │   │   │       │   │   │   └─ [  0.96%] spage_check_updatable
│   │               │   │   │   │   │   │       │   │   │       ├─ [  0.87%] spage_has_enough_total_space
│   │               │   │   │   │   │   │       │   │   │       │   ├─ [  0.68%] spage_get_total_saved_spaces
│   │               │   │   │   │   │   │       │   │   │       │   │   └─ [  0.63%] spage_get_saved_spaces
│   │               │   │   │   │   │   │       │   │   │       │   │       ├─ [  0.56%] lf_hash_find
│   │               │   │   │   │   │   │       │   │   │       │   │       │   ├─ [  0.31%] lf_list_find
│   │               │   │   │   │   │   │       │   │   │       │   │       │   │   ├─ [  0.20%] lf_tran_start  ↑
│   │               │   │   │   │   │   │       │   │   │       │   │       │   │   ├─ [  0.05%] lf_tran_end@plt
│   │               │   │   │   │   │   │       │   │   │       │   │       │   │   └─ [  0.03%] lf_tran_start@plt
│   │               │   │   │   │   │   │       │   │   │       │   │       │   ├─ [  0.07%] lf_callback_vpid_hash
│   │               │   │   │   │   │   │       │   │   │       │   │       │   └─ [  4.68%] __memmove_evex_unaligned_erms
│   │               │   │   │   │   │   │       │   │   │       │   │       └─ [  0.03%] pgbuf_get_vpid_ptr@plt
│   │               │   │   │   │   │   │       │   │   │       │   ├─ [  0.12%] logtb_find_tranid
│   │               │   │   │   │   │   │       │   │   │       │   │   └─ [  0.68%] LOG_FIND_TDES
│   │               │   │   │   │   │   │       │   │   │       │   ├─ [  0.06%] logtb_find_current_tranid@plt
│   │               │   │   │   │   │   │       │   │   │       │   ├─ [  0.05%] logtb_is_active
│   │               │   │   │   │   │   │       │   │   │       │   │   └─ [  0.68%] LOG_FIND_TDES
│   │               │   │   │   │   │   │       │   │   │       │   └─ [  0.04%] log_is_in_crash_recovery
│   │               │   │   │   │   │   │       │   │   │       └─ [  0.38%] spage_find_slot  ↑
│   │               │   │   │   │   │   │       │   │   ├─ [  0.17%] heap_update_set_prev_version
│   │               │   │   │   │   │   │       │   │   │   ├─ [  0.10%] spage_get_record@plt
│   │               │   │   │   │   │   │       │   │   │   ├─ [  0.04%] or_mvcc_set_log_lsa_to_record
│   │               │   │   │   │   │   │       │   │   │   ├─ [  0.57%] spage_get_record  ↑
│   │               │   │   │   │   │   │       │   │   │   ├─ [  1.69%] spage_get_record_data  ↑
│   │               │   │   │   │   │   │       │   │   │   └─ [  0.06%] pgbuf_set_dirty  ↑
│   │               │   │   │   │   │   │       │   │   ├─ [  0.06%] heap_update_physical
│   │               │   │   │   │   │   │       │   │   │   ├─ [  0.07%] spage_get_record_type
│   │               │   │   │   │   │   │       │   │   │   │   └─ [  0.38%] spage_find_slot  ↑
│   │               │   │   │   │   │   │       │   │   │   └─ [  0.06%] pgbuf_set_dirty  ↑
│   │               │   │   │   │   │   │       │   │   └─ [  0.08%] perfmon_inc_stat  ↑
│   │               │   │   │   │   │   │       │   ├─ [  3.48%] spage_update
│   │               │   │   │   │   │   │       │   │   ├─ [  3.00%] spage_update_record_after_compact
│   │               │   │   │   │   │   │       │   │   │   ├─ [  1.95%] spage_compact
│   │               │   │   │   │   │   │       │   │   │   │   ├─ [  4.68%] __memmove_evex_unaligned_erms
│   │               │   │   │   │   │   │       │   │   │   │   ├─ [  0.20%] cub_calloc
│   │               │   │   │   │   │   │       │   │   │   │   │   └─ [  0.18%] __calloc
│   │               │   │   │   │   │   │       │   │   │   │   │       └─ [  1.59%] _int_malloc  ↑
│   │               │   │   │   │   │   │       │   │   │   │   ├─ [  0.17%] __GI___qsort_r
│   │               │   │   │   │   │   │       │   │   │   │   │   ├─ [  0.15%] msort_with_tmp.part.0
│   │               │   │   │   │   │   │       │   │   │   │   │   │   └─ [  4.68%] __memmove_evex_unaligned_erms
│   │               │   │   │   │   │   │       │   │   │   │   │   ├─ [  0.14%] __GI___libc_free
│   │               │   │   │   │   │   │       │   │   │   │   │   └─ [  4.68%] __memmove_evex_unaligned_erms
│   │               │   │   │   │   │   │       │   │   │   │   ├─ [  0.15%] msort_with_tmp.part.0  ↑
│   │               │   │   │   │   │   │       │   │   │   │   └─ [  0.79%] _int_free  ↑
│   │               │   │   │   │   │   │       │   │   │   └─ [  4.68%] __memmove_evex_unaligned_erms
│   │               │   │   │   │   │   │       │   │   ├─ [  0.96%] spage_check_updatable  ↑
│   │               │   │   │   │   │   │       │   │   ├─ [  0.09%] spage_save_space
│   │               │   │   │   │   │   │       │   │   │   ├─ [  0.12%] logtb_find_tranid  ↑
│   │               │   │   │   │   │   │       │   │   │   └─ [  0.04%] log_is_in_crash_recovery
│   │               │   │   │   │   │   │       │   │   └─ [  0.06%] pgbuf_set_dirty  ↑
│   │               │   │   │   │   │   │       │   ├─ [  2.18%] pgbuf_unfix  ↑
│   │               │   │   │   │   │   │       │   ├─ [  1.69%] spage_get_record_data  ↑
│   │               │   │   │   │   │   │       │   ├─ [  0.10%] heap_update_adjust_recdes_header
│   │               │   │   │   │   │   │       │   │   └─ [  0.09%] logtb_get_current_mvccid  ↑
│   │               │   │   │   │   │   │       │   ├─ [  0.07%] heap_get_record_location
│   │               │   │   │   │   │   │       │   ├─ [  0.16%] mvcc_is_mvcc_disabled_class  ↑
│   │               │   │   │   │   │   │       │   ├─ [  0.04%] heap_scancache_check_with_hfid
│   │               │   │   │   │   │   │       │   ├─ [  0.12%] pgbuf_ordered_unfix  ↑
│   │               │   │   │   │   │   │       │   ├─ [  0.07%] spage_get_record_type  ↑
│   │               │   │   │   │   │   │       │   ├─ [  0.57%] spage_get_record  ↑
│   │               │   │   │   │   │   │       │   ├─ [  0.14%] oid_check_cached_class_oid
│   │               │   │   │   │   │   │       │   └─ [  0.03%] pgbuf_unfix@plt
│   │               │   │   │   │   │   │       ├─ [  5.30%] locator_lock_and_get_object_with_evaluation
│   │               │   │   │   │   │   │       │   ├─ [  4.47%] locator_lock_and_get_object_internal
│   │               │   │   │   │   │   │       │   │   ├─ [  7.00%] lock_object  ↑
│   │               │   │   │   │   │   │       │   │   ├─ [  1.78%] heap_get_last_version
│   │               │   │   │   │   │   │       │   │   │   ├─ [  1.49%] heap_get_record_data_when_all_ready  ↑
│   │               │   │   │   │   │   │       │   │   │   ├─ [  0.16%] heap_get_mvcc_header
│   │               │   │   │   │   │   │       │   │   │   │   ├─ [  0.14%] or_mvcc_get_header
│   │               │   │   │   │   │   │       │   │   │   │   ├─ [  1.69%] spage_get_record_data  ↑
│   │               │   │   │   │   │   │       │   │   │   │   └─ [  0.57%] spage_get_record  ↑
│   │               │   │   │   │   │   │       │   │   │   ├─ [  0.92%] heap_prepare_get_context  ↑
│   │               │   │   │   │   │   │       │   │   │   └─ [  0.43%] heap_scan_cache_allocate_area
│   │               │   │   │   │   │   │       │   │   │       ├─ [  0.29%] heap_scancache::reserve_area  ↑
│   │               │   │   │   │   │   │       │   │   │       └─ [  0.15%] cubmem::single_block_allocator::reserve  ↑
│   │               │   │   │   │   │   │       │   │   ├─ [  0.05%] logtb_find_isolation  ↑
│   │               │   │   │   │   │   │       │   │   ├─ [  0.16%] mvcc_is_mvcc_disabled_class  ↑
│   │               │   │   │   │   │   │       │   │   └─ [  0.14%] or_mvcc_get_header
│   │               │   │   │   │   │   │       │   ├─ [  0.43%] heap_scan_cache_allocate_area  ↑
│   │               │   │   │   │   │   │       │   ├─ [  1.04%] heap_clean_get_context  ↑
│   │               │   │   │   │   │   │       │   └─ [  0.07%] heap_init_get_context
│   │               │   │   │   │   │   │       ├─ [  0.83%] locator_check_foreign_key
│   │               │   │   │   │   │   │       │   ├─ [  1.37%] heap_attrinfo_start_with_index
│   │               │   │   │   │   │   │       │   │   ├─ [  1.51%] heap_classrepr_get  ↑
│   │               │   │   │   │   │   │       │   │   ├─ [  0.26%] heap_attrinfo_recache_attrepr
│   │               │   │   │   │   │   │       │   │   │   └─ [  0.09%] db_value_domain_init
│   │               │   │   │   │   │   │       │   │   ├─ [  0.13%] hl_lea_alloc  ↑
│   │               │   │   │   │   │   │       │   │   └─ [  0.04%] db_private_alloc_release
│   │               │   │   │   │   │   │       │   ├─ [  0.91%] heap_attrinfo_end
│   │               │   │   │   │   │   │       │   │   ├─ [  1.05%] heap_classrepr_free  ↑
│   │               │   │   │   │   │   │       │   │   ├─ [  0.07%] heap_attrinfo_clear_dbvalues
│   │               │   │   │   │   │   │       │   │   │   └─ [  0.07%] pr_clear_value
│   │               │   │   │   │   │   │       │   │   ├─ [  0.08%] mspace_free
│   │               │   │   │   │   │   │       │   │   ├─ [  0.03%] heap_attrinfo_clear_dbvalues@plt
│   │               │   │   │   │   │   │       │   │   └─ [  0.05%] heap_attrinfo_recache
│   │               │   │   │   │   │   │       │   └─ [  0.65%] heap_attrinfo_read_dbvalues
│   │               │   │   │   │   │   │       │       ├─ [  0.37%] heap_attrvalue_read
│   │               │   │   │   │   │   │       │       │   ├─ [  0.15%] heap_attrvalue_point_fixed
│   │               │   │   │   │   │   │       │       │   │   └─ [  0.11%] or_header_size
│   │               │   │   │   │   │   │       │       │   └─ [  0.06%] heap_attrvalue_transform_to_dbvalue
│   │               │   │   │   │   │   │       │       ├─ [  0.18%] or_rep_id
│   │               │   │   │   │   │   │       │       │   ├─ [  0.11%] or_header_size
│   │               │   │   │   │   │   │       │       │   └─ [  0.05%] or_header_size@plt
│   │               │   │   │   │   │   │       │       ├─ [  0.07%] pr_type_from_id
│   │               │   │   │   │   │   │       │       ├─ [  0.04%] tp_domain_disk_size
│   │               │   │   │   │   │   │       │       └─ [  0.05%] heap_attrinfo_recache
│   │               │   │   │   │   │   │       ├─ [  0.08%] heap_create_update_context
│   │               │   │   │   │   │   │       │   └─ [  0.05%] heap_clear_operation_context
│   │               │   │   │   │   │   │       ├─ [  0.16%] mvcc_is_mvcc_disabled_class  ↑
│   │               │   │   │   │   │   │       ├─ [  0.14%] or_mvcc_get_header
│   │               │   │   │   │   │   │       ├─ [  0.09%] logtb_find_client_type  ↑
│   │               │   │   │   │   │   │       ├─ [  4.20%] locator_update_index
│   │               │   │   │   │   │   │       │   ├─ [  1.11%] heap_get_class_name_alloc_if_diff
│   │               │   │   │   │   │   │       │   │   ├─ [  0.36%] heap_scancache_end
│   │               │   │   │   │   │   │       │   │   │   └─ [  0.47%] heap_scancache_quick_end  ↑
│   │               │   │   │   │   │   │       │   │   ├─ [  0.29%] heap_get_class_record
│   │               │   │   │   │   │   │       │   │   │   ├─ [  1.78%] heap_get_last_version  ↑
│   │               │   │   │   │   │   │       │   │   │   ├─ [  1.04%] heap_clean_get_context  ↑
│   │               │   │   │   │   │   │       │   │   │   └─ [  0.07%] heap_init_get_context
│   │               │   │   │   │   │   │       │   │   ├─ [  0.17%] cub_strdup
│   │               │   │   │   │   │   │       │   │   │   ├─ [  1.66%] cub_alloc  ↑
│   │               │   │   │   │   │   │       │   │   │   └─ [  0.04%] __strlen_evex
│   │               │   │   │   │   │   │       │   │   ├─ [  0.15%] heap_scancache_quick_start_root_hfid
│   │               │   │   │   │   │   │       │   │   │   └─ [  0.04%] boot_find_root_heap
│   │               │   │   │   │   │   │       │   │   ├─ [  0.08%] or_class_name
│   │               │   │   │   │   │   │       │   │   │   └─ [  0.11%] or_header_size
│   │               │   │   │   │   │   │       │   │   └─ [  0.03%] or_class_name@plt
│   │               │   │   │   │   │   │       │   ├─ [  1.37%] heap_attrinfo_start_with_index  ↑
│   │               │   │   │   │   │   │       │   ├─ [  0.91%] heap_attrinfo_end  ↑
│   │               │   │   │   │   │   │       │   ├─ [  0.65%] heap_attrinfo_read_dbvalues  ↑
│   │               │   │   │   │   │   │       │   ├─ [  0.32%] heap_attrvalue_get_key
│   │               │   │   │   │   │   │       │   │   ├─ [  0.06%] heap_attrinfo_access
│   │               │   │   │   │   │   │       │   │   ├─ [  0.18%] or_rep_id  ↑
│   │               │   │   │   │   │   │       │   │   └─ [  0.03%] tp_domain_cache@plt
│   │               │   │   │   │   │   │       │   ├─ [  0.46%] btree_compare_key  ↑
│   │               │   │   │   │   │   │       │   ├─ [  0.09%] logtb_find_client_type  ↑
│   │               │   │   │   │   │   │       │   ├─ [  0.14%] __GI___libc_free
│   │               │   │   │   │   │   │       │   ├─ [  0.03%] LOG_FIND_TDES@plt
│   │               │   │   │   │   │   │       │   ├─ [  0.06%] btree_compare_key@plt
│   │               │   │   │   │   │   │       │   ├─ [  0.68%] LOG_FIND_TDES
│   │               │   │   │   │   │   │       │   ├─ [  0.09%] logtb_get_current_mvccid  ↑
│   │               │   │   │   │   │   │       │   ├─ [  0.07%] pr_type_from_id
│   │               │   │   │   │   │   │       │   ├─ [  0.16%] mvcc_is_mvcc_disabled_class  ↑
│   │               │   │   │   │   │   │       │   └─ [  0.79%] _int_free  ↑
│   │               │   │   │   │   │   │       └─ [  0.14%] oid_check_cached_class_oid
│   │               │   │   │   │   │   ├─ [  1.17%] css_send_reply_and_2_data_to_client
│   │               │   │   │   │   │   │   ├─ [  0.91%] css_enqueue_and_notify
│   │               │   │   │   │   │   │   │   ├─ [  0.85%] cubconn::connection::worker::enqueue_and_notify
│   │               │   │   │   │   │   │   │   │   ├─ [  0.77%] cubconn::connection::worker::notify
│   │               │   │   │   │   │   │   │   │   │   └─ [  0.77%] __libc_write
│   │               │   │   │   │   │   │   │   │   └─ [  0.95%] cubconn::connection::worker::enqueue
│   │               │   │   │   │   │   │   │   │       └─ [  0.59%] tbb::detail::d2::micro_queue<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >::prepare_page(unsigned long, tbb::detail::d2::concurrent_queue_rep<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >&, tbb::detail::d1::cache_aligned_allocator<tbb::detail::d2::micro_queue<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >::padded_page>, tbb::detail::d2::micro_queue<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >::padded_page*&)::{lambda()#1}::operator()
│   │               │   │   │   │   │   │   │   │           └─ [  0.60%] tbb::detail::r1::cache_aligned_allocate
│   │               │   │   │   │   │   │   │   │               └─ [  0.57%] _mid_memalign
│   │               │   │   │   │   │   │   │   │                   └─ [  0.50%] _int_memalign
│   │               │   │   │   │   │   │   │   │                       ├─ [  1.59%] _int_malloc  ↑
│   │               │   │   │   │   │   │   │   │                       └─ [  0.79%] _int_free  ↑
│   │               │   │   │   │   │   │   │   └─ [  0.67%] rmutex_lock  ↑
│   │               │   │   │   │   │   │   ├─ [  0.67%] rmutex_lock  ↑
│   │               │   │   │   │   │   │   ├─ [  0.51%] operator new  ↑
│   │               │   │   │   │   │   │   ├─ [  0.05%] std::vector<cubbase::span<std::byte>, std::allocator<cubbase::span<std::byte> > >::_M_realloc_insert<std::byte*&, unsigned long>
│   │               │   │   │   │   │   │   │   └─ [  0.51%] operator new  ↑
│   │               │   │   │   │   │   │   ├─ [  0.24%] rmutex_unlock  ↑
│   │               │   │   │   │   │   │   └─ [  0.05%] rmutex_lock@plt
│   │               │   │   │   │   │   ├─ [  1.01%] css_request_release_packet
│   │               │   │   │   │   │   │   ├─ [  0.95%] cubconn::connection::worker::enqueue  ↑
│   │               │   │   │   │   │   │   ├─ [  0.67%] rmutex_lock  ↑
│   │               │   │   │   │   │   │   ├─ [  0.08%] std::vector<cubbase::span<std::byte>, std::allocator<cubbase::span<std::byte> > >::_M_realloc_insert<std::byte*, int>
│   │               │   │   │   │   │   │   │   └─ [  0.51%] operator new  ↑
│   │               │   │   │   │   │   │   └─ [  0.24%] rmutex_unlock  ↑
│   │               │   │   │   │   │   ├─ [  4.68%] __memmove_evex_unaligned_erms
│   │               │   │   │   │   │   ├─ [  0.35%] css_receive_data_from_client_with_timeout
│   │               │   │   │   │   │   │   ├─ [  0.41%] css_receive_data
│   │               │   │   │   │   │   │   │   ├─ [  0.31%] css_return_queued_data_timeout
│   │               │   │   │   │   │   │   │   │   ├─ [  0.67%] rmutex_lock  ↑
│   │               │   │   │   │   │   │   │   │   └─ [  0.24%] rmutex_unlock  ↑
│   │               │   │   │   │   │   │   │   ├─ [  0.11%] css_traverse_list
│   │               │   │   │   │   │   │   │   │   └─ [  0.05%] css_find_queue_entry_by_key
│   │               │   │   │   │   │   │   │   ├─ [  1.66%] cub_alloc  ↑
│   │               │   │   │   │   │   │   │   ├─ [  0.04%] thread_suspend_timeout_wakeup_and_unlock_entry
│   │               │   │   │   │   │   │   │   │   └─ [  2.53%] __pthread_cond_timedwait
│   │               │   │   │   │   │   │   │   └─ [  0.16%] cub_free  ↑
│   │               │   │   │   │   │   │   └─ [  0.08%] css_return_queued_error
│   │               │   │   │   │   │   │       ├─ [  0.67%] rmutex_lock  ↑
│   │               │   │   │   │   │   │       └─ [  0.24%] rmutex_unlock  ↑
│   │               │   │   │   │   │   ├─ [  0.11%] locator_unpack_copy_area_descriptor
│   │               │   │   │   │   │   │   └─ [  0.03%] or_unpack_int
│   │               │   │   │   │   │   ├─ [  0.09%] locator_recv_allocate_copyarea
│   │               │   │   │   │   │   │   └─ [  0.14%] locator_allocate_copy_area_by_length
│   │               │   │   │   │   │   │       └─ [  1.66%] cub_alloc  ↑
│   │               │   │   │   │   │   ├─ [  0.04%] locator_send_copy_area
│   │               │   │   │   │   │   └─ [  0.03%] or_unpack_int
│   │               │   │   │   │   ├─ [  0.37%] slogwr_get_log_pages
│   │               │   │   │   │   │   └─ [  0.37%] xlogwr_get_log_pages
│   │               │   │   │   │   │       ├─ [  0.09%] thread_suspend_with_other_mutex
│   │               │   │   │   │   │       │   └─ [  0.14%] __pthread_cond_wait
│   │               │   │   │   │   │       ├─ [  0.09%] logpb_copy_page_from_log_buffer
│   │               │   │   │   │   │       │   └─ [  0.09%] logpb_copy_page
│   │               │   │   │   │   │       │       └─ [  4.68%] __memmove_evex_unaligned_erms
│   │               │   │   │   │   │       ├─ [  0.06%] logwr_pack_log_pages
│   │               │   │   │   │   │       ├─ [  0.14%] __pthread_cond_wait
│   │               │   │   │   │   │       ├─ [  0.05%] xlog_get_page_request_with_reply
│   │               │   │   │   │   │       │   └─ [  0.04%] xs_receive_data_from_client_with_timeout
│   │               │   │   │   │   │       │       └─ [  0.35%] css_receive_data_from_client_with_timeout  ↑
│   │               │   │   │   │   │       └─ [  0.05%] crypt_crc32
│   │               │   │   │   │   ├─ [  1.01%] css_request_release_packet  ↑
│   │               │   │   │   │   ├─ [  0.12%] sqmgr_execute_query
│   │               │   │   │   │   │   └─ [  0.10%] xqmgr_execute_query
│   │               │   │   │   │   │       └─ [  0.08%] qmgr_process_query
│   │               │   │   │   │   │           └─ [  0.08%] qexec_execute_query
│   │               │   │   │   │   │               └─ [  0.06%] qexec_execute_mainblock
│   │               │   │   │   │   │                   ├─ [  0.05%] qexec_execute_update
│   │               │   │   │   │   │                   └─ [  0.04%] qexec_execute_mainblock_internal
│   │               │   │   │   │   ├─ [  0.09%] slocator_fetch
│   │               │   │   │   │   │   ├─ [  0.07%] xlocator_fetch
│   │               │   │   │   │   │   │   └─ [  0.14%] locator_allocate_copy_area_by_length  ↑
│   │               │   │   │   │   │   └─ [  0.08%] css_send_data_to_client
│   │               │   │   │   │   │       └─ [  0.91%] css_enqueue_and_notify  ↑
│   │               │   │   │   │   ├─ [  0.09%] hl_clear_lea_heap
│   │               │   │   │   │   │   └─ [  0.06%] create_mspace_with_base
│   │               │   │   │   │   │       └─ [  0.04%] init_user_mstate
│   │               │   │   │   │   ├─ [  0.09%] stran_server_commit
│   │               │   │   │   │   │   ├─ [  0.06%] xtran_server_commit
│   │               │   │   │   │   │   │   └─ [  0.06%] log_commit
│   │               │   │   │   │   │   │       └─ [  0.05%] log_commit_local
│   │               │   │   │   │   │   │           ├─ [  0.04%] logpb_flush_pages
│   │               │   │   │   │   │   │           │   └─ [  2.53%] __pthread_cond_timedwait
│   │               │   │   │   │   │   │           └─ [  0.04%] log_change_tran_as_completed
│   │               │   │   │   │   │   └─ [  0.08%] css_send_data_to_client  ↑
│   │               │   │   │   │   └─ [  0.03%] logtb_is_tran_modification_disabled
│   │               │   │   │   │       └─ [  0.68%] LOG_FIND_TDES
│   │               │   │   │   ├─ [  0.41%] css_receive_data  ↑
│   │               │   │   │   └─ [  2.09%] __pthread_mutex_unlock_usercnt  ↑
│   │               │   │   ├─ [  0.57%] css_return_queued_request
│   │               │   │   │   ├─ [  1.01%] css_request_release_packet  ↑
│   │               │   │   │   ├─ [  0.67%] rmutex_lock  ↑
│   │               │   │   │   ├─ [  0.05%] css_remove_list_from_head
│   │               │   │   │   └─ [  0.24%] rmutex_unlock  ↑
│   │               │   │   ├─ [  0.20%] css_wakeup_handler
│   │               │   │   │   ├─ [  0.77%] cubconn::connection::worker::notify  ↑
│   │               │   │   │   └─ [  0.67%] rmutex_lock  ↑
│   │               │   │   ├─ [  0.03%] pgbuf_thread_variables_init
│   │               │   │   └─ [  0.24%] rmutex_unlock  ↑
│   │               │   ├─ [  0.10%] cubthread::wp_worker_statset_time_and_increment
│   │               │   │   └─ [  0.10%] std::chrono::_V2::system_clock::now
│   │               │   │       └─ [  0.22%] __clock_gettime_2
│   │               │   ├─ [  0.06%] cubthread::entry_manager::recycle_context
│   │               │   │   └─ [  0.09%] er_clear  ↑
│   │               │   └─ [  0.03%] cubthread::worker_pool::core::get_entry_manager
│   │               └─ [  2.78%] cubthread::worker_pool::core::worker::get_new_task
│   │                   ├─ [  2.53%] __pthread_cond_timedwait
│   │                   ├─ [  0.15%] __gthread_mutex_unlock  ↑
│   │                   ├─ [  0.05%] cubthread::worker_pool::core::get_task_or_become_available
│   │                   │   ├─ [  2.05%] __GI___pthread_mutex_lock  ↑
│   │                   │   └─ [  2.09%] __pthread_mutex_unlock_usercnt  ↑
│   │                   ├─ [  0.10%] std::chrono::_V2::system_clock::now  ↑
│   │                   └─ [  0.10%] cubthread::wp_worker_statset_time_and_increment  ↑
│   ├─ [  0.07%] locator_add_or_remove_index_internal   ◆덩어리#2 (이 스레드의 독립 호출 조각 — 상위는 truncation 으로 끊김)
│   │   └─ [  0.07%] btree_insert
│   │       └─ [  0.07%] btree_insert_internal
│   │           └─ [  0.07%] btree_fix_root_for_insert
│   │               └─ [  0.07%] logtb_tran_update_unique_stats
│   │                   └─ [  0.07%] logtb_tran_update_btid_unique_stats
│   │                       └─ [  0.07%] logtb_tran_find_btid_stats
│   │                           └─ [  0.07%] logtb_tran_create_btid_unique_stats
│   │                               └─ [  1.66%] cub_alloc  ↑
│   └─ (기타 truncation 고아 20개 — 서브트리는 위 덩어리에 이미 전개됨, % of total):
│          22.95%  locator_update_force
│          11.13%  heap_log_update_physical
│           4.69%  log_append_undoredo_recdes
│           4.19%  locator_update_index
│           2.64%  pgbuf_ordered_fix_release
│           1.14%  LZ4_read_ARCH
│           0.94%  log_append_undoredo_recdes2
│           0.13%  LZ4_read32
│           0.05%  heap_attrvalue_get_key
│           0.04%  lf_hash_find
│           0.04%  lock_get_class_lock
│           0.04%  __GI___pthread_mutex_lock
│           0.04%  log_append_undoredo_crumbs
│           0.04%  _int_malloc
│           0.04%  heap_update_logical
│           0.03%  or_rep_id
│           0.03%  __lll_unlock_wake
│           0.03%  logtb_get_current_tran_index
│           0.03%  __GI___pthread_mutex_trylock
│           0.03%  heap_attrinfo_recache_attrepr
├─ [ 12.26%] «connections»  (15489 smp)
│   ├─ [ 11.84%] cubconn::connection::worker::run
│   │   ├─ [  4.45%] cubconn::connection::worker::eventfd_handler
│   │   │   ├─ [  3.99%] cubconn::connection::worker::handle_message_queue
│   │   │   │   ├─ [  3.11%] cubconn::connection::worker::handle_message_queue_by_index
│   │   │   │   │   ├─ [  1.64%] cubconn::connection::worker::handle_message_queue_send_packet
│   │   │   │   │   │   ├─ [  1.28%] cubconn::transmitter::fill
│   │   │   │   │   │   │   └─ [  1.24%] __sendmsg
│   │   │   │   │   │   │       └─ [  0.04%] __pthread_enable_asynccancel
│   │   │   │   │   │   ├─ [  0.14%] cubconn::transmitter::clear
│   │   │   │   │   │   │   ├─ [  0.05%] _M_invoke
│   │   │   │   │   │   │   │   ├─ [  0.05%] operator()
│   │   │   │   │   │   │   │   │   └─ [  0.24%] operator delete
│   │   │   │   │   │   │   │   │       └─ [  0.26%] cub_free
│   │   │   │   │   │   │   │   │           ├─ [  0.34%] _int_free
│   │   │   │   │   │   │   │   │           └─ [  0.08%] __GI___libc_free
│   │   │   │   │   │   │   │   └─ [  0.04%] std::_Function_handler<void (), css_send_reply_and_2_data_to_client(css_conn_entry*, unsigned int, char*, int, char*, int, char*, int, std::function<void ()>&&)::{lambda()#1}>::_M_invoke
│   │   │   │   │   │   │   │       └─ [  0.05%] operator()  ↑
│   │   │   │   │   │   │   ├─ [  0.05%] _M_manager
│   │   │   │   │   │   │   │   └─ [  0.24%] operator delete  ↑
│   │   │   │   │   │   │   └─ [  0.04%] std::_Function_handler<void (), css_send_reply_and_2_data_to_client(css_conn_entry*, unsigned int, char*, int, char*, int, char*, int, std::function<void ()>&&)::{lambda()#1}>::_M_invoke  ↑
│   │   │   │   │   │   ├─ [  0.49%] rmutex_lock
│   │   │   │   │   │   │   ├─ [  0.10%] tsc_getticks
│   │   │   │   │   │   │   │   └─ [  0.18%] __clock_gettime_2
│   │   │   │   │   │   │   ├─ [  0.16%] __GI___pthread_mutex_lock
│   │   │   │   │   │   │   └─ [  0.03%] cubthread::entry::get_id
│   │   │   │   │   │   └─ [  0.11%] rmutex_unlock
│   │   │   │   │   │       └─ [  0.09%] __pthread_mutex_unlock_usercnt
│   │   │   │   │   ├─ [  0.78%] cubconn::connection::worker::handle_message_queue_release_packet
│   │   │   │   │   │   ├─ [  0.51%] cubconn::receiver::release
│   │   │   │   │   │   │   └─ [  0.37%] cubbase::DMRBMemoryPool::restore
│   │   │   │   │   │   │       ├─ [  0.21%] std::_Rb_tree<unsigned long, std::pair<unsigned long const, unsigned long>, std::_Select1st<std::pair<unsigned long const, unsigned long> >, std::less<unsigned long>, std::allocator<std::pair<unsigned long const, unsigned long> > >::_M_emplace_unique<unsigned long&, unsigned long&>
│   │   │   │   │   │   │       │   └─ [  0.13%] operator new
│   │   │   │   │   │   │       │       ├─ [  0.08%] __GI___libc_malloc
│   │   │   │   │   │   │       │       └─ [  0.03%] malloc@plt
│   │   │   │   │   │   │       ├─ [  0.24%] operator delete  ↑
│   │   │   │   │   │   │       └─ [  0.03%] std::_Rb_tree_rebalance_for_erase
│   │   │   │   │   │   ├─ [  0.49%] rmutex_lock  ↑
│   │   │   │   │   │   └─ [  0.11%] rmutex_unlock  ↑
│   │   │   │   │   ├─ [  0.58%] tbb::detail::d2::internal_try_pop_impl<tbb::detail::d2::concurrent_queue_rep<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >, tbb::detail::d1::cache_aligned_allocator<tbb::detail::d2::concurrent_queue_rep<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> > > >
│   │   │   │   │   │   ├─ [  0.34%] _int_free
│   │   │   │   │   │   ├─ [  0.24%] operator delete  ↑
│   │   │   │   │   │   └─ [  0.08%] __GI___libc_free
│   │   │   │   │   └─ [  0.24%] operator delete  ↑
│   │   │   │   └─ [  0.88%] cubconn::connection::worker::purge_stale_contexts
│   │   │   │       ├─ [  0.58%] cubconn::connection::coordinator::notify
│   │   │   │       │   └─ [  0.55%] __libc_write
│   │   │   │       │       ├─ [  0.04%] __pthread_enable_asynccancel
│   │   │   │       │       └─ [  0.04%] __pthread_disable_asynccancel
│   │   │   │       └─ [  0.29%] cubconn::connection::coordinator::enqueue
│   │   │   │           └─ [  0.19%] tbb::detail::d2::micro_queue<cubconn::connection::coordinator::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::coordinator::message> >::prepare_page(unsigned long, tbb::detail::d2::concurrent_queue_rep<cubconn::connection::coordinator::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::coordinator::message> >&, tbb::detail::d1::cache_aligned_allocator<tbb::detail::d2::micro_queue<cubconn::connection::coordinator::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::coordinator::message> >::padded_page>, tbb::detail::d2::micro_queue<cubconn::connection::coordinator::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::coordinator::message> >::padded_page*&)::{lambda()#1}::operator()
│   │   │   │               └─ [  0.19%] tbb::detail::r1::cache_aligned_allocate
│   │   │   │                   └─ [  0.18%] _mid_memalign
│   │   │   │                       └─ [  0.14%] _int_memalign
│   │   │   │                           ├─ [  0.11%] _int_malloc
│   │   │   │                           └─ [  0.34%] _int_free
│   │   │   ├─ [  0.38%] cubconn::connection::worker::eventfd_clear
│   │   │   │   └─ [  0.36%] __libc_read
│   │   │   │       ├─ [  0.04%] __pthread_enable_asynccancel
│   │   │   │       └─ [  0.04%] __pthread_disable_asynccancel
│   │   │   └─ [  0.04%] cubconn::connection::worker::statistics_metrics_to_coordinator
│   │   │       ├─ [  0.11%] cubconn::connection::worker::get_time_ns
│   │   │       │   └─ [  0.18%] __clock_gettime_2
│   │   │       └─ [  0.29%] cubconn::connection::coordinator::enqueue  ↑
│   │   ├─ [  3.80%] cubconn::connection::worker::handle_reception
│   │   │   ├─ [  2.26%] cubconn::receiver::drain
│   │   │   │   ├─ [  2.11%] cubconn::receiver::receive
│   │   │   │   │   └─ [  2.10%] __libc_recv
│   │   │   │   │       ├─ [  0.04%] __pthread_disable_asynccancel
│   │   │   │   │       └─ [  0.04%] __pthread_enable_asynccancel
│   │   │   │   └─ [  0.09%] cubconn::receiver::parse_size
│   │   │   │       └─ [  0.08%] cubconn::receiver::parse_packet
│   │   │   ├─ [  0.84%] cubconn::connection::worker::handle_data_packet
│   │   │   │   ├─ [  0.60%] cubthread::worker_pool::core::execute_task
│   │   │   │   │   ├─ [  0.50%] cubthread::worker_pool::core::worker::assign_task
│   │   │   │   │   │   ├─ [  0.44%] std::condition_variable::notify_one
│   │   │   │   │   │   │   └─ [  0.43%] __pthread_cond_signal
│   │   │   │   │   │   └─ [  0.16%] __GI___pthread_mutex_lock
│   │   │   │   │   ├─ [  0.16%] __GI___pthread_mutex_lock
│   │   │   │   │   └─ [  0.09%] __pthread_mutex_unlock_usercnt
│   │   │   │   ├─ [  0.13%] css_add_queue_entry
│   │   │   │   │   ├─ [  0.07%] css_make_queue_entry
│   │   │   │   │   └─ [  0.03%] css_add_list
│   │   │   │   ├─ [  0.06%] css_push_server_task
│   │   │   │   │   └─ [  0.13%] operator new  ↑
│   │   │   │   └─ [  0.04%] cubthread::worker_pool::execute_on_core
│   │   │   ├─ [  0.23%] cubconn::connection::worker::handle_header_packet
│   │   │   │   └─ [  0.51%] cubconn::receiver::release  ↑
│   │   │   ├─ [  0.49%] rmutex_lock  ↑
│   │   │   ├─ [  0.10%] cubconn::connection::worker::handle_command_header_packet
│   │   │   │   ├─ [  0.13%] css_add_queue_entry  ↑
│   │   │   │   └─ [  0.05%] css_is_request_aborted
│   │   │   │       └─ [  0.03%] css_find_queue_entry
│   │   │   │           └─ [  0.03%] css_traverse_list
│   │   │   ├─ [  0.11%] rmutex_unlock  ↑
│   │   │   └─ [  0.04%] std::chrono::_V2::steady_clock::now
│   │   │       └─ [  0.18%] __clock_gettime_2
│   │   ├─ [  3.40%] cubsocket::epoll::wait
│   │   │   └─ [  3.38%] epoll_wait
│   │   ├─ [  0.11%] cubconn::connection::worker::get_time_ns  ↑
│   │   └─ [  3.38%] epoll_wait
├─ [  4.11%] «dwb-flush-block»  (5195 smp)
│   ├─ [  4.05%] __GI___clone
│   │   └─ [  4.05%] start_thread
│   │       └─ [  4.05%] execute_native_thread_routine
│   │           └─ [  4.05%] cubthread::daemon::loop_with_context
│   │               ├─ [  3.83%] cubthread::looper::put_to_sleep
│   │               │   ├─ [  3.67%] cubthread::waiter::wait_for
│   │               │   │   ├─ [  3.21%] __pthread_cond_timedwait
│   │               │   │   ├─ [  0.24%] __pthread_mutex_unlock_usercnt
│   │               │   │   │   └─ [  0.24%] __lll_unlock_wake
│   │               │   │   └─ [  0.24%] std::chrono::_V2::system_clock::now
│   │               │   │       └─ [  0.19%] __clock_gettime_2
│   │               │   ├─ [  0.24%] std::chrono::_V2::system_clock::now  ↑
│   │               │   └─ [  0.24%] __lll_unlock_wake
│   │               ├─ [  0.08%] dwb_flush_block_daemon_task::execute
│   │               ├─ [  0.05%] cubthread::daemon::register_stat_pause
│   │               │   └─ [  0.24%] std::chrono::_V2::system_clock::now  ↑
│   │               └─ [  0.03%] cubthread::daemon::register_stat_execute
│   │                   └─ [  0.24%] std::chrono::_V2::system_clock::now  ↑
├─ [  3.47%] «vacuum»  (4378 smp)
│   ├─ [  2.84%] vacuum_heap_page   ◆덩어리#1 (이 스레드의 독립 호출 조각 — 상위는 truncation 으로 끊김)
│   │   ├─ [  1.62%] vacuum_heap_prepare_record
│   │   │   └─ [  1.49%] spage_get_record_data
│   │   │       └─ [  1.87%] __memmove_evex_unaligned_erms
│   │   ├─ [  0.73%] vacuum_heap_page_log_and_reset
│   │   │   ├─ [  0.37%] heap_stats_update
│   │   │   │   └─ [  0.36%] heap_stats_add_bestspace
│   │   │   │       ├─ [  0.19%] __GI___pthread_mutex_lock
│   │   │   │       │   └─ [  0.13%] __lll_lock_wait
│   │   │   │       ├─ [  0.12%] mht_get
│   │   │   │       │   └─ [  0.05%] heap_compare_vpid
│   │   │   │       └─ [  0.12%] __pthread_mutex_unlock_usercnt
│   │   │   │           └─ [  0.10%] __lll_unlock_wake
│   │   │   └─ [  0.33%] spage_compact
│   │   │       └─ [  1.87%] __memmove_evex_unaligned_erms
│   │   ├─ [  0.25%] pgbuf_fix_release
│   │   │   ├─ [  0.10%] pgbuf_search_hash_chain
│   │   │   └─ [  0.10%] pgbuf_set_bcb_page_vpid
│   │   └─ [  0.19%] spage_update
│   │       └─ [  0.15%] spage_update_record_in_place
│   │           └─ [  1.87%] __memmove_evex_unaligned_erms
│   ├─ [  0.45%] vacuum_process_log_block   ◆덩어리#2 (이 스레드의 독립 호출 조각 — 상위는 truncation 으로 끊김)
│   │   ├─ [  0.31%] __GI___qsort_r
│   │   │   ├─ [  0.27%] __GI___libc_malloc
│   │   │   │   └─ [  0.25%] _int_malloc
│   │   │   │       ├─ [  0.22%] malloc_consolidate
│   │   │   │       │   └─ [  0.03%] unlink_chunk.isra.2
│   │   │   │       └─ [  0.03%] unlink_chunk.isra.2
│   │   │   └─ [  0.09%] msort_with_tmp.part.0
│   │   │       └─ [  1.87%] __memmove_evex_unaligned_erms
│   │   └─ [  0.10%] logpb_fetch_page
│   │       └─ [  0.09%] logpb_copy_page
│   │           └─ [  1.87%] __memmove_evex_unaligned_erms
│   ├─ [  0.13%] vacuum_log_vacuum_heap_page   ◆덩어리#3 (이 스레드의 독립 호출 조각 — 상위는 truncation 으로 끊김)
│   │   └─ [  0.13%] log_append_redo_data
│   │       └─ [  0.13%] log_append_redo_crumbs
│   │           ├─ [  0.06%] prior_lsa_next_record_internal
│   │           │   ├─ [  0.19%] __GI___pthread_mutex_lock  ↑
│   │           │   └─ [  0.12%] __pthread_mutex_unlock_usercnt  ↑
│   │           └─ [  0.05%] prior_lsa_alloc_and_copy_crumbs
│   │               └─ [  0.04%] cub_alloc
│   │                   └─ [  0.27%] __GI___libc_malloc  ↑
├─ [  1.91%] «coordinator»  (2414 smp)
│   ├─ [  1.87%] __GI___clone
│   │   └─ [  1.87%] start_thread
│   │       └─ [  1.87%] execute_native_thread_routine
│   │           └─ [  1.87%] cubconn::connection::coordinator::attach
│   │               └─ [  1.86%] cubconn::connection::coordinator::run
│   │                   ├─ [  1.22%] cubsocket::epoll::wait
│   │                   │   └─ [  1.22%] epoll_wait
│   │                   ├─ [  0.29%] cubconn::connection::coordinator::handle_message_queue
│   │                   │   └─ [  0.23%] tbb::detail::d2::internal_try_pop_impl<tbb::detail::d2::concurrent_queue_rep<cubconn::connection::coordinator::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::coordinator::message> >, tbb::detail::d1::cache_aligned_allocator<tbb::detail::d2::concurrent_queue_rep<cubconn::connection::coordinator::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::coordinator::message> > > >
│   │                   │       └─ [  0.06%] _int_free
│   │                   ├─ [  0.26%] cubconn::connection::coordinator::eventfd_clear
│   │                   │   └─ [  0.25%] __libc_read
│   │                   └─ [  0.05%] cubconn::connection::coordinator::get_monotonic_ns
├─ [  1.69%] «log-flush»  (2137 smp)
│   ├─ [  1.18%] __GI___clone   ◆덩어리#1 (이 스레드의 독립 호출 조각 — 상위는 truncation 으로 끊김)
│   │   └─ [  1.18%] start_thread
│   │       └─ [  1.18%] execute_native_thread_routine
│   │           └─ [  1.18%] cubthread::daemon::loop_with_context
│   │               ├─ [  1.04%] log_flush_execute
│   │               │   └─ [  1.04%] logpb_flush_pages_direct
│   │               │       ├─ [  0.78%] logpb_prior_lsa_append_all_list
│   │               │       │   ├─ [  0.73%] logpb_append_prior_lsa_list
│   │               │       │   │   ├─ [  0.50%] logpb_append_next_record
│   │               │       │   │   │   ├─ [  0.05%] logpb_start_append
│   │               │       │   │   │   │   ├─ [  0.06%] LSA_EQ
│   │               │       │   │   │   │   └─ [  0.07%] logpb_set_dirty
│   │               │       │   │   │   │       └─ [  0.05%] logpb_get_log_buffer
│   │               │       │   │   │   ├─ [  0.03%] logpb_end_append
│   │               │       │   │   │   │   └─ [  0.06%] LSA_EQ
│   │               │       │   │   │   └─ [  0.06%] LSA_EQ
│   │               │       │   │   └─ [  0.21%] cub_free
│   │               │       │   │       ├─ [  0.18%] _int_free
│   │               │       │   │       └─ [  0.05%] __GI___libc_free
│   │               │       │   ├─ [  0.35%] logpb_append_data
│   │               │       │   │   ├─ [  0.16%] __memmove_evex_unaligned_erms
│   │               │       │   │   ├─ [  0.10%] logpb_next_append_page
│   │               │       │   │   │   └─ [  0.09%] logpb_locate_page
│   │               │       │   │   │       └─ [  0.09%] __memset_evex_unaligned_erms
│   │               │       │   │   └─ [  0.07%] logpb_set_dirty  ↑
│   │               │       │   ├─ [  0.10%] logpb_next_append_page  ↑
│   │               │       │   └─ [  0.07%] logpb_set_dirty  ↑
│   │               │       ├─ [  0.24%] logpb_flush_all_append_pages
│   │               │       │   └─ [  0.26%] fileio_synchronize
│   │               │       │       └─ [  0.26%] fdatasync
│   │               │       └─ [  0.18%] _int_free
│   │               └─ [  0.13%] cubthread::looper::put_to_sleep
│   │                   └─ [  0.13%] cubthread::waiter::wait_for
│   │                       └─ [  0.12%] __pthread_cond_timedwait
│   ├─ [  0.25%] logpb_write_toflush_pages_to_archive   ◆덩어리#2 (이 스레드의 독립 호출 조각 — 상위는 truncation 으로 끊김)
│   │   ├─ [  0.41%] fileio_write
│   │   │   └─ [  0.40%] __libc_pwrite64
│   │   └─ [  0.26%] fileio_synchronize  ↑
│   ├─ [  0.18%] logpb_writev_append_pages   ◆덩어리#3 (이 스레드의 독립 호출 조각 — 상위는 truncation 으로 끊김)
│   │   └─ [  0.41%] fileio_write  ↑
│   ├─ [  0.06%] logpb_write_page_to_disk   ◆덩어리#4 (이 스레드의 독립 호출 조각 — 상위는 truncation 으로 끊김)
│   │   └─ [  0.41%] fileio_write  ↑
├─ [  0.89%] «vacuum-master»  (1123 smp)
│   ├─ [  0.84%] __GI___clone
│   │   └─ [  0.83%] start_thread
│   │       └─ [  0.83%] execute_native_thread_routine
│   │           └─ [  0.83%] cubthread::daemon::loop_with_context
│   │               ├─ [  0.65%] cubthread::looper::put_to_sleep
│   │               │   └─ [  0.63%] cubthread::waiter::wait_for
│   │               │       ├─ [  0.56%] __pthread_cond_timedwait
│   │               │       └─ [  0.03%] __pthread_mutex_unlock_usercnt
│   │               │           └─ [  0.03%] __lll_unlock_wake
│   │               └─ [  0.16%] vacuum_master_task::execute
│   │                   ├─ [  0.04%] vacuum_job_cursor::force_data_update
│   │                   │   └─ [  0.03%] vacuum_data::update
│   │                   └─ [  0.05%] mvcctable::update_global_oldest_visible
│   │                       └─ [  0.04%] mvcctable::compute_oldest_visible_mvccid
├─ [  0.68%] «dwb-file-sync»  (861 smp)
│   ├─ [  0.68%] __GI___clone
│   │   └─ [  0.68%] start_thread
│   │       └─ [  0.68%] execute_native_thread_routine
│   │           └─ [  0.68%] cubthread::daemon::loop_with_context
│   │               └─ [  0.64%] cubthread::looper::put_to_sleep
│   │                   └─ [  0.61%] cubthread::waiter::wait_for
│   │                       └─ [  0.55%] __pthread_cond_timedwait
├─ [  0.34%] «pgbuf-flush-con»  (424 smp)
│   ├─ [  0.33%] __GI___clone
│   │   └─ [  0.33%] start_thread
│   │       └─ [  0.33%] execute_native_thread_routine
│   │           └─ [  0.33%] cubthread::daemon::loop_with_context
│   │               └─ [  0.31%] cubthread::looper::put_to_sleep
│   │                   └─ [  0.31%] cubthread::waiter::wait_for
│   │                       └─ [  0.29%] __pthread_cond_timedwait
├─ [  0.30%] «deadlock-detect»  (376 smp)
│   ├─ [  0.29%] __GI___clone
│   │   └─ [  0.29%] start_thread
│   │       └─ [  0.29%] execute_native_thread_routine
│   │           └─ [  0.29%] cubthread::daemon::loop_with_context
│   │               └─ [  0.28%] cubthread::looper::put_to_sleep
│   │                   └─ [  0.28%] cubthread::waiter::wait_for
│   │                       └─ [  0.26%] __pthread_cond_timedwait
├─ [  0.30%] «pgbuf-maintain»  (376 smp)
│   ├─ [  0.30%] __GI___clone
│   │   └─ [  0.30%] start_thread
│   │       └─ [  0.30%] execute_native_thread_routine
│   │           └─ [  0.30%] cubthread::daemon::loop_with_context
│   │               └─ [  0.27%] cubthread::looper::put_to_sleep
│   │                   └─ [  0.26%] cubthread::waiter::wait_for
│   │                       └─ [  0.25%] __pthread_cond_timedwait
├─ [  0.22%] «log-clock»  (273 smp)
│   ├─ [  0.22%] __GI___clone
│   │   └─ [  0.22%] start_thread
│   │       └─ [  0.22%] execute_native_thread_routine
│   │           └─ [  0.22%] cubthread::daemon::loop_with_context
│   │               └─ [  0.20%] cubthread::looper::put_to_sleep
│   │                   └─ [  0.20%] cubthread::waiter::wait_for
│   │                       └─ [  0.19%] __pthread_cond_timedwait
├─ [  0.15%] «ha-delay-check»  (186 smp)
│   ├─ [  0.14%] __GI___clone
│   │   └─ [  0.14%] start_thread
│   │       └─ [  0.14%] execute_native_thread_routine
│   │           └─ [  0.14%] cubthread::daemon::loop_with_context
│   │               ├─ [  0.09%] cubthread::looper::put_to_sleep
│   │               │   └─ [  0.09%] cubthread::waiter::wait_for
│   │               │       └─ [  0.08%] __pthread_cond_timedwait
│   │               └─ [  0.05%] log_check_ha_delay_info_execute
│   │                   └─ [  0.05%] catcls_get_apply_info_log_record_time
├─ [  0.10%] «pgbuf-page-flus»  (121 smp)
│   ├─ [  0.09%] __GI___clone
│   │   └─ [  0.09%] start_thread
│   │       └─ [  0.09%] execute_native_thread_routine
│   │           └─ [  0.09%] cubthread::daemon::loop_with_context
│   │               └─ [  0.09%] cubthread::looper::put_to_sleep
│   │                   └─ [  0.09%] cubthread::waiter::wait_for
│   │                       └─ [  0.09%] __pthread_cond_timedwait
├─ [  0.08%] «pl-monitor»  (104 smp)
│   ├─ [  0.08%] __GI___clone
│   │   └─ [  0.08%] start_thread
│   │       └─ [  0.08%] execute_native_thread_routine
│   │           └─ [  0.08%] cubthread::daemon::loop_with_context
│   │               └─ [  0.08%] cubthread::looper::put_to_sleep
│   │                   └─ [  0.07%] cubthread::waiter::wait_for
│   │                       └─ [  0.07%] __pthread_cond_timedwait
└─ [  0.05%] «기타 thread 2종»  (64 smp, 각 <0.05%)
         0.04%  cub_server  (55)
         0.01%  session-control  (9)
```
