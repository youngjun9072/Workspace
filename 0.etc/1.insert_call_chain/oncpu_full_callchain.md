# INSERT 전체 on-CPU 콜체인 — 모든 스레드·모든 함수

이 캡처에서 **on-CPU 로 샘플링된 모든 함수**를 caller-callee 호출관계 트리로 정리한 것.
특정 root(`locator_insert_force`)가 아니라 **캡처 전체**를 `(ALL on-CPU)` → thread(comm) → 함수 로 묶었다.
캡처: `20260601-203144-cubserver-oncpu-config-parallel-poc-insert`, 전체 147,236 sample, 17 thread.

## 읽는 법
- **노드 % = of total**(분모 147,236). 한 함수가 stack 어디든 나온 sample 비율(inclusive).
- stack truncate 대응: 각 sample 의 **최외곽 프레임을 thread 노드에 매달아 100% 커버**.
- **`↑`** = 그 함수 서브트리가 같은 thread 에서 이미 위에 전개됨(중복 전개 생략). 호출관계는 처음 전개된 곳 참조.
- **`◆덩어리#N`** = 한 스레드 안에서 **상위가 truncation 으로 끊긴 독립 호출 조각**. #1 은 보통 thread 진입(`__GI___clone`…)
  체인, 그 외는 깊은 곳에서 잘려 부모를 잃은 fragment. (끊긴 엣지를 측정으론 못 잇기에 조각으로 나눠 표시 — 함수포인터가 아니라 스택 잘림 탓)
- **`⎘소스연결`** = 측정 엣지는 truncation 으로 끊겼지만 **소스 콜관계로 이어붙인** 지점 (예: `xlocator_repl_force → locator_insert_force`, locator_sr.c:7029).
- **`(기타 truncation 고아 N개)`** = 위 덩어리에 이미 전개된 함수가 다른 곳에서 또 잘려 root 로 뜬 것 → 이름만 압축 표기.
- 컷오프: 노드 0.03% / thread 0.05% / MIN_EDGE 10. → 트리에 **548 종** 함수 등장.
- ⚠ **on-CPU 측정**이라 mutex/condvar **대기(off-CPU) 시간은 미포함**. `__pthread_mutex_lock`/`wait_for` 등이 보여도
  그건 깨어난 찰나의 on-CPU 일 뿐 대기 길이가 아님.

## 전체 함수 평탄표
트리 컷(0.03%) 아래 저빈도 함수까지 **샘플된 1,841 종 전부**는 `analysis/inclusive_total.txt`(컷오프 없음) 참조.
복제 적용 경로만 따로 본 콜체인은 `repl_apply_callchain.md`.

## thread 분포 (% of total)
| % | samples | thread |
|---:|---:|---|
| 69.65 | 102,544 | `transaction` (insert 적용 워커) |
| 13.16 | 19,374 | `connections` |
| 5.33 | 7,847 | `vacuum` |
| 3.82 | 5,618 | `dwb-flush-block` |
| 3.72 | 5,483 | `log-flush` |
| 1.69 | 2,488 | `coordinator` |
| 0.85 | 1,253 | `vacuum-master` |
| 0.73 | 1,080 | `dwb-file-sync` |
| ~1.05 | 1,549 | 기타 9종 (pgbuf-flush/maintain, deadlock-detect, log-clock …) |

---

```
# 전체 on-CPU 콜체인 (모든 thread·함수, 노드 % = of total_samples=147236)
# 함수 노드 컷 0.03% / thread 컷 0.05% / MIN_EDGE 10

[100.00%] (ALL on-CPU)   total_samples=147236
├─ [ 69.65%] «transaction»  (102544 smp)
│   ├─ [ 13.70%] __GI___clone   ◆덩어리#1 (이 스레드의 독립 호출 조각 — 상위는 truncation 으로 끊김)
│   │   └─ [ 13.70%] start_thread
│   │       └─ [ 13.70%] execute_native_thread_routine
│   │           └─ [ 13.70%] cubthread::worker_pool::core::worker::run
│   │               ├─ [ 10.92%] cubthread::worker_pool::core::worker::execute_current_task
│   │               │   ├─ [ 10.64%] css_server_task::execute
│   │               │   │   ├─ [  9.43%] net_server_request
│   │               │   │   │   ├─ [  6.41%] slocator_repl_force
│   │               │   │   │   │   ├─ [  3.79%] xlocator_repl_force
│   │               │   │   │   │   │   ├─ [ 29.78%] locator_insert_force  ⎘소스연결
│   │               │   │   │   │   │   │   ├─ [ 25.66%] heap_insert_logical
│   │               │   │   │   │   │   │   │   ├─ [ 10.24%] heap_get_insert_location_with_lock
│   │               │   │   │   │   │   │   │   │   └─ [ 11.94%] heap_stats_find_best_page
│   │               │   │   │   │   │   │   │   │       ├─ [  6.89%] heap_vpid_alloc
│   │               │   │   │   │   │   │   │   │       │   ├─ [  5.46%] file_alloc
│   │               │   │   │   │   │   │   │   │       │   │   ├─ [  3.91%] pgbuf_fix_release
│   │               │   │   │   │   │   │   │   │       │   │   │   ├─ [  1.56%] pgbuf_claim_bcb_for_fix
│   │               │   │   │   │   │   │   │   │       │   │   │   │   ├─ [  1.33%] fileio_init_lsa_of_page
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │   └─ [  1.35%] LSA_SET_NULL
│   │               │   │   │   │   │   │   │   │       │   │   │   │   ├─ [  0.13%] pgbuf_allocate_bcb
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │   └─ [  0.10%] pgbuf_get_bcb_from_invalid_list
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │       ├─ [  5.61%] __GI___pthread_mutex_lock
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │       │   └─ [  2.75%] __lll_lock_wait
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │       ├─ [  0.06%] pgbuf_bcb_change_zone
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │       │   └─ [  0.06%] ATOMIC_CAS_32<int, int, int>
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │       └─ [  4.27%] __pthread_mutex_unlock_usercnt
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │           └─ [  2.37%] __lll_unlock_wake
│   │               │   │   │   │   │   │   │   │       │   │   │   │   ├─ [  0.04%] pgbuf_lock_page
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │   └─ [  4.27%] __pthread_mutex_unlock_usercnt  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   │   ├─ [  5.61%] __GI___pthread_mutex_lock  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   │   ├─ [  0.05%] er_errid
│   │               │   │   │   │   │   │   │   │       │   │   │   │   └─ [  1.35%] LSA_SET_NULL
│   │               │   │   │   │   │   │   │   │       │   │   │   ├─ [  0.39%] pgbuf_search_hash_chain
│   │               │   │   │   │   │   │   │   │       │   │   │   │   ├─ [  0.40%] __GI___pthread_mutex_trylock
│   │               │   │   │   │   │   │   │   │       │   │   │   │   └─ [  5.61%] __GI___pthread_mutex_lock  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   ├─ [  0.30%] pgbuf_latch_bcb_upon_fix
│   │               │   │   │   │   │   │   │   │       │   │   │   │   ├─ [  0.04%] pgbuf_allocate_thrd_holder_entry
│   │               │   │   │   │   │   │   │   │       │   │   │   │   └─ [  0.19%] pgbuf_find_thrd_holder
│   │               │   │   │   │   │   │   │   │       │   │   │   ├─ [  0.18%] pgbuf_find_current_wait_msecs
│   │               │   │   │   │   │   │   │   │       │   │   │   │   └─ [  1.90%] LOG_FIND_TDES
│   │               │   │   │   │   │   │   │   │       │   │   │   ├─ [  0.16%] logtb_is_interrupted
│   │               │   │   │   │   │   │   │   │       │   │   │   │   └─ [  1.90%] LOG_FIND_TDES
│   │               │   │   │   │   │   │   │   │       │   │   │   ├─ [  4.27%] __pthread_mutex_unlock_usercnt  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   ├─ [  0.11%] pgbuf_lockfree_fix_ro
│   │               │   │   │   │   │   │   │   │       │   │   │   │   ├─ [  0.06%] pgbuf_search_hash_chain_no_bcb_lock
│   │               │   │   │   │   │   │   │   │       │   │   │   │   └─ [  0.08%] pgbuf_hash_func_mirror
│   │               │   │   │   │   │   │   │   │       │   │   │   ├─ [  0.07%] pgbuf_bcb_register_fix
│   │               │   │   │   │   │   │   │   │       │   │   │   │   └─ [  0.18%] ATOMIC_INC_32<int, int>
│   │               │   │   │   │   │   │   │   │       │   │   │   ├─ [  0.08%] pgbuf_hash_func_mirror
│   │               │   │   │   │   │   │   │   │       │   │   │   ├─ [  0.05%] pthread_mutex_unlock@plt
│   │               │   │   │   │   │   │   │   │       │   │   │   └─ [  5.61%] __GI___pthread_mutex_lock  ↑
│   │               │   │   │   │   │   │   │   │       │   │   ├─ [  1.25%] file_perm_alloc
│   │               │   │   │   │   │   │   │   │       │   │   │   ├─ [  0.62%] log_append_undoredo_data2
│   │               │   │   │   │   │   │   │   │       │   │   │   │   └─ [ 19.52%] log_append_undoredo_crumbs
│   │               │   │   │   │   │   │   │   │       │   │   │   │       ├─ [ 15.54%] prior_lsa_alloc_and_copy_crumbs
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   ├─ [ 11.92%] prior_lsa_gen_undoredo_record_from_crumbs
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   ├─ [  9.96%] log_zip
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   ├─ [  8.84%] LZ4_compress_fast_extState
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   │   ├─ [  1.72%] LZ4_read_ARCH
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   │   ├─ [  0.78%] LZ4_read32
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   │   ├─ [  0.47%] LZ4_initStream
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   │   │   └─ [  1.36%] __memset_evex_unaligned_erms
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   │   ├─ [  0.21%] LZ4_writeLE16
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   │   │   ├─ [  0.08%] LZ4_write16
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   │   │   └─ [  0.07%] LZ4_isLittleEndian
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   │   ├─ [  0.10%] LZ4_NbCommonBytes
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   │   │   └─ [  0.07%] LZ4_isLittleEndian
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   │   ├─ [  0.03%] LZ4_write32
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   │   └─ [  3.69%] __memmove_evex_unaligned_erms
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   ├─ [  1.06%] LZ4_resetStream_fast
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   │   └─ [  1.36%] __memset_evex_unaligned_erms
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   ├─ [  0.20%] __tls_get_addr
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   ├─ [  0.78%] LZ4_read32
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   ├─ [  1.72%] LZ4_read_ARCH
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   ├─ [  0.21%] LZ4_writeLE16  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   ├─ [  0.10%] LZ4_NbCommonBytes  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   └─ [  0.04%] __tls_get_addr@plt
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   ├─ [  6.08%] cub_alloc
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   ├─ [  7.24%] __GI___libc_malloc
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   │   └─ [  6.52%] _int_malloc
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   │       ├─ [  4.20%] sysmalloc
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   │       │   └─ [  3.59%] __GI___mprotect
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   │       ├─ [  0.68%] malloc_consolidate
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   │       │   └─ [  0.32%] unlink_chunk.isra.2
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   │       └─ [  0.32%] unlink_chunk.isra.2
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   └─ [  0.07%] malloc@plt
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   ├─ [  0.53%] prior_lsa_copy_undo_crumbs_to_node
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   └─ [  6.08%] cub_alloc  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   ├─ [  0.32%] prior_lsa_copy_redo_crumbs_to_node
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   └─ [  6.08%] cub_alloc  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   ├─ [  3.69%] __memmove_evex_unaligned_erms
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   ├─ [  0.24%] LOG_FIND_CURRENT_TDES
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   │   └─ [  1.90%] LOG_FIND_TDES
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   ├─ [  0.10%] log_diff
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   ├─ [  0.04%] log_zip@plt
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   ├─ [  0.04%] pgbuf_get_vpid_ptr
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   └─ [  0.04%] memcpy@plt
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   ├─ [  6.08%] cub_alloc  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   ├─ [  9.96%] log_zip  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   ├─ [  0.59%] prior_lsa_copy_undo_data_to_node
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   └─ [  6.08%] cub_alloc  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   ├─ [  0.40%] prior_lsa_copy_redo_data_to_node
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   ├─ [  6.08%] cub_alloc  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   └─ [  3.69%] __memmove_evex_unaligned_erms
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   ├─ [  3.69%] __memmove_evex_unaligned_erms
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   ├─ [  0.04%] log_zip@plt
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   └─ [  0.04%] memcpy@plt
│   │               │   │   │   │   │   │   │   │       │   │   │   │       ├─ [  7.94%] prior_lsa_next_record_internal
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   ├─ [  5.61%] __GI___pthread_mutex_lock  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   ├─ [  4.27%] __pthread_mutex_unlock_usercnt  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   ├─ [  0.22%] prior_lsa_start_append
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   ├─ [  0.11%] log_tdes::is_system_worker_transaction
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   ├─ [  0.04%] LSA_ISNULL
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   ├─ [  0.05%] LSA_COPY
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   └─ [  0.13%] log_prior_lsa_append_advance_when_doesnot_fit
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   ├─ [  0.22%] vacuum_get_log_blockid
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   ├─ [  0.18%] __gthread_mutex_unlock
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   ├─ [  0.14%] prior_lsa_append_data
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   ├─ [  0.06%] log_prior_lsa_append_align
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   └─ [  0.03%] LOG_PRIOR_LSA_LAST_APPEND_OFFSET@plt
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   ├─ [  0.13%] log_prior_lsa_append_advance_when_doesnot_fit
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   ├─ [  0.06%] logpb_get_memsize
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   ├─ [  0.03%] prior_lsa_end_append
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   ├─ [  0.06%] log_prior_lsa_append_align
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   │   └─ [  0.05%] LSA_COPY
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   ├─ [  0.03%] __gthread_mutex_lock
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   └─ [  0.06%] pthread_mutex_lock@plt
│   │               │   │   │   │   │   │   │   │       │   │   │   │       ├─ [  1.90%] LOG_FIND_TDES
│   │               │   │   │   │   │   │   │   │       │   │   │   │       ├─ [  0.16%] pgbuf_set_lsa
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   └─ [  0.20%] pgbuf_set_dirty_buffer_ptr
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │       ├─ [  0.19%] pgbuf_find_thrd_holder
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │       ├─ [  0.21%] pgbuf_set_dirty
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │       └─ [  0.08%] perfmon_inc_stat
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │           └─ [  0.08%] perfmon_add_stat
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │               ├─ [  0.10%] perfmon_is_perf_tracking
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │               └─ [  1.99%] pgbuf_unfix
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │                   ├─ [  1.23%] pgbuf_unlatch_bcb_upon_unfix
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │                   │   ├─ [  0.19%] pgbuf_unlatch_void_zone_bcb
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │                   │   │   ├─ [  0.12%] pgbuf_lru_add_new_bcb_to_top
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │                   │   │   │   └─ [  0.10%] pgbuf_lru_adjust_zones
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │                   │   │   │       ├─ [  0.04%] pgbuf_lru_fall_bcb_to_zone_3
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │                   │   │   │       │   └─ [  0.06%] pgbuf_bcb_change_zone  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │                   │   │   │       └─ [  0.04%] pgbuf_lru_adjust_zone1
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │                   │   │   │           └─ [  0.06%] pgbuf_bcb_change_zone  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │                   │   │   ├─ [  0.10%] pgbuf_bcb_register_hit_for_lru
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │                   │   │   └─ [  5.61%] __GI___pthread_mutex_lock  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │                   │   ├─ [  4.27%] __pthread_mutex_unlock_usercnt  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │                   │   ├─ [  0.11%] pgbuf_wakeup_reader_writer
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │                   │   │   └─ [  0.11%] set_waiter_exists
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │                   │   ├─ [  0.10%] pgbuf_bcb_register_hit_for_lru
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │                   │   └─ [  0.04%] __GI___pthread_mutex_unlock
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │                   ├─ [  5.61%] __GI___pthread_mutex_lock  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │                   ├─ [  0.19%] pgbuf_unlatch_thrd_holder
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │                   │   ├─ [  0.09%] pgbuf_remove_thrd_holder
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │                   │   └─ [  0.19%] pgbuf_find_thrd_holder
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │                   ├─ [  0.10%] xdisk_get_purpose
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │                   ├─ [  0.10%] perfmon_is_perf_tracking
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │                   └─ [  0.06%] pthread_mutex_lock@plt
│   │               │   │   │   │   │   │   │   │       │   │   │   │       ├─ [  0.20%] logtb_find_client_type
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   └─ [  1.90%] LOG_FIND_TDES
│   │               │   │   │   │   │   │   │   │       │   │   │   │       ├─ [  0.10%] pgbuf_is_lsa_temporary
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   └─ [  0.10%] xdisk_get_purpose
│   │               │   │   │   │   │   │   │   │       │   │   │   │       ├─ [  0.05%] log_can_skip_undo_logging
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   ├─ [  0.11%] log_tdes::is_system_worker_transaction
│   │               │   │   │   │   │   │   │   │       │   │   │   │       │   └─ [  0.04%] log_tdes::is_system_worker_transaction@plt
│   │               │   │   │   │   │   │   │   │       │   │   │   │       ├─ [  0.06%] pgbuf_notify_vacuum_follows
│   │               │   │   │   │   │   │   │   │       │   │   │   │       └─ [  2.37%] __lll_unlock_wake
│   │               │   │   │   │   │   │   │   │       │   │   │   ├─ [  7.88%] log_append_undoredo_data
│   │               │   │   │   │   │   │   │   │       │   │   │   │   ├─ [ 19.52%] log_append_undoredo_crumbs  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   │   └─ [  0.06%] log_append_undoredo_crumbs@plt
│   │               │   │   │   │   │   │   │   │       │   │   │   └─ [ 19.52%] log_append_undoredo_crumbs  ↑
│   │               │   │   │   │   │   │   │   │       │   │   ├─ [  0.88%] heap_vpid_init_new
│   │               │   │   │   │   │   │   │   │       │   │   │   ├─ [  7.88%] log_append_undoredo_data  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   ├─ [  0.23%] spage_insert
│   │               │   │   │   │   │   │   │   │       │   │   │   │   ├─ [  0.20%] spage_find_empty_slot
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │   ├─ [  0.47%] spage_has_enough_total_space
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │   │   ├─ [  0.60%] spage_get_total_saved_spaces
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │   │   │   ├─ [  0.58%] spage_get_saved_spaces
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │   │   │   │   ├─ [  0.45%] lf_hash_find
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │   │   │   │   │   ├─ [  0.26%] lf_list_find
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │   │   │   │   │   │   ├─ [  0.16%] lf_tran_start
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │   │   │   │   │   │   │   └─ [  0.04%] ATOMIC_INC_64<unsigned long, int>
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │   │   │   │   │   │   └─ [  0.04%] lf_tran_end@plt
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │   │   │   │   │   └─ [  0.06%] lf_callback_vpid_hash
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │   │   │   │   ├─ [  0.12%] logtb_find_tranid
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │   │   │   │   │   └─ [  1.90%] LOG_FIND_TDES
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │   │   │   │   └─ [  0.30%] spage_max_space_for_new_record
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │   │   │   │       └─ [  0.04%] pgbuf_get_vpid_ptr
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │   │   │   └─ [  0.30%] spage_max_space_for_new_record  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │   │   └─ [  0.12%] logtb_find_tranid  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │   └─ [  0.35%] spage_check_space
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │       └─ [  0.47%] spage_has_enough_total_space  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   │   └─ [  2.87%] spage_insert_data
│   │               │   │   │   │   │   │   │   │       │   │   │   │       ├─ [  3.69%] __memmove_evex_unaligned_erms
│   │               │   │   │   │   │   │   │   │       │   │   │   │       └─ [  0.21%] pgbuf_set_dirty  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   ├─ [  0.04%] spage_initialize
│   │               │   │   │   │   │   │   │   │       │   │   │   └─ [  0.21%] pgbuf_set_dirty  ↑
│   │               │   │   │   │   │   │   │   │       │   │   ├─ [  0.64%] log_sysop_end_logical_undo
│   │               │   │   │   │   │   │   │   │       │   │   │   └─ [  1.17%] log_sysop_commit_internal
│   │               │   │   │   │   │   │   │   │       │   │   │       ├─ [  0.99%] log_append_sysop_end
│   │               │   │   │   │   │   │   │   │       │   │   │       │   ├─ [  7.94%] prior_lsa_next_record_internal  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │       │   ├─ [  0.45%] prior_lsa_alloc_and_copy_data
│   │               │   │   │   │   │   │   │   │       │   │   │       │   │   ├─ [  6.08%] cub_alloc  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │       │   │   ├─ [  0.14%] prior_lsa_gen_record
│   │               │   │   │   │   │   │   │   │       │   │   │       │   │   │   └─ [  6.08%] cub_alloc  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │       │   │   └─ [  0.59%] prior_lsa_copy_undo_data_to_node  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │       │   └─ [  3.69%] __memmove_evex_unaligned_erms
│   │               │   │   │   │   │   │   │   │       │   │   │       ├─ [  0.39%] log_tdes::unlock_topop
│   │               │   │   │   │   │   │   │   │       │   │   │       │   ├─ [  0.38%] cubpl::get_session
│   │               │   │   │   │   │   │   │   │       │   │   │       │   │   ├─ [  0.24%] session_get_pl_session
│   │               │   │   │   │   │   │   │   │       │   │   │       │   │   │   ├─ [  0.15%] cubpl::session::is_sp_running
│   │               │   │   │   │   │   │   │   │       │   │   │       │   │   │   │   ├─ [  5.61%] __GI___pthread_mutex_lock  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │       │   │   │   │   └─ [  4.27%] __pthread_mutex_unlock_usercnt  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │       │   │   │   └─ [  0.05%] session_get_session_state
│   │               │   │   │   │   │   │   │   │       │   │   │       │   │   └─ [  0.27%] thread_get_thread_entry_info
│   │               │   │   │   │   │   │   │   │       │   │   │       │   │       ├─ [  0.21%] cubthread::get_entry
│   │               │   │   │   │   │   │   │   │       │   │   │       │   │       │   ├─ [  0.20%] __tls_get_addr
│   │               │   │   │   │   │   │   │   │       │   │   │       │   │       │   └─ [  0.04%] __tls_get_addr@plt
│   │               │   │   │   │   │   │   │   │       │   │   │       │   │       └─ [  0.05%] cubthread::get_entry@plt
│   │               │   │   │   │   │   │   │   │       │   │   │       │   └─ [  0.16%] cubpl::session::is_thread_involved
│   │               │   │   │   │   │   │   │   │       │   │   │       │       ├─ [  4.27%] __pthread_mutex_unlock_usercnt  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │       │       └─ [  5.61%] __GI___pthread_mutex_lock  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │       ├─ [  0.15%] log_sysop_end_final
│   │               │   │   │   │   │   │   │   │       │   │   │       │   ├─ [  0.04%] log_tdes::on_sysop_end
│   │               │   │   │   │   │   │   │   │       │   │   │       │   │   ├─ [  0.04%] log_tdes::is_system_worker_transaction@plt
│   │               │   │   │   │   │   │   │   │       │   │   │       │   │   └─ [  0.11%] log_tdes::is_system_worker_transaction
│   │               │   │   │   │   │   │   │   │       │   │   │       │   └─ [  0.08%] perfmon_inc_stat  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │       ├─ [  0.05%] log_sysop_end_begin
│   │               │   │   │   │   │   │   │   │       │   │   │       │   └─ [  0.06%] log_sysop_get_tran_index_and_tdes
│   │               │   │   │   │   │   │   │   │       │   │   │       │       └─ [  1.90%] LOG_FIND_TDES
│   │               │   │   │   │   │   │   │   │       │   │   │       ├─ [  0.20%] logtb_find_client_type  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │       └─ [  0.23%] rmutex_unlock
│   │               │   │   │   │   │   │   │   │       │   │   │           ├─ [  4.27%] __pthread_mutex_unlock_usercnt  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │           ├─ [  0.27%] thread_get_thread_entry_info  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │           └─ [  0.04%] cubthread::is_single_thread@plt
│   │               │   │   │   │   │   │   │   │       │   │   ├─ [  7.94%] prior_lsa_next_record_internal  ↑
│   │               │   │   │   │   │   │   │   │       │   │   ├─ [  1.99%] pgbuf_unfix  ↑
│   │               │   │   │   │   │   │   │   │       │   │   ├─ [  0.18%] log_sysop_start_atomic
│   │               │   │   │   │   │   │   │   │       │   │   │   ├─ [  0.45%] prior_lsa_alloc_and_copy_data  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   ├─ [  0.61%] log_sysop_start
│   │               │   │   │   │   │   │   │   │       │   │   │   │   ├─ [  0.22%] log_tdes::lock_topop
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │   ├─ [  0.38%] cubpl::get_session  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │   └─ [  0.16%] cubpl::session::is_thread_involved  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   │   ├─ [  0.69%] rmutex_lock
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │   ├─ [  0.18%] tsc_getticks
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │   │   └─ [  0.20%] __clock_gettime_2
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │   ├─ [  5.61%] __GI___pthread_mutex_lock  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │   ├─ [  0.27%] thread_get_thread_entry_info  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │   └─ [  0.04%] cubthread::is_single_thread@plt
│   │               │   │   │   │   │   │   │   │       │   │   │   │   ├─ [  1.90%] LOG_FIND_TDES
│   │               │   │   │   │   │   │   │   │       │   │   │   │   ├─ [  0.04%] log_tdes::on_sysop_start
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │   ├─ [  0.11%] log_tdes::is_system_worker_transaction
│   │               │   │   │   │   │   │   │   │       │   │   │   │   │   └─ [  0.04%] log_tdes::is_system_worker_transaction@plt
│   │               │   │   │   │   │   │   │   │       │   │   │   │   ├─ [  0.04%] rmutex_lock@plt
│   │               │   │   │   │   │   │   │   │       │   │   │   │   ├─ [  0.08%] perfmon_inc_stat  ↑
│   │               │   │   │   │   │   │   │   │       │   │   │   │   └─ [  0.05%] LSA_COPY
│   │               │   │   │   │   │   │   │   │       │   │   │   └─ [  0.06%] log_sysop_get_tran_index_and_tdes  ↑
│   │               │   │   │   │   │   │   │   │       │   │   ├─ [  0.04%] pgbuf_fix_release@plt
│   │               │   │   │   │   │   │   │   │       │   │   └─ [  0.05%] pgbuf_unfix@plt
│   │               │   │   │   │   │   │   │   │       │   ├─ [  7.88%] log_append_undoredo_data  ↑
│   │               │   │   │   │   │   │   │   │       │   ├─ [  0.52%] log_sysop_commit
│   │               │   │   │   │   │   │   │   │       │   │   └─ [  1.17%] log_sysop_commit_internal  ↑
│   │               │   │   │   │   │   │   │   │       │   ├─ [  0.57%] heap_stats_add_bestspace
│   │               │   │   │   │   │   │   │   │       │   │   ├─ [  0.34%] mht_get
│   │               │   │   │   │   │   │   │   │       │   │   │   └─ [  0.04%] logtb_tran_btid_hash_func
│   │               │   │   │   │   │   │   │   │       │   │   ├─ [  5.61%] __GI___pthread_mutex_lock  ↑
│   │               │   │   │   │   │   │   │   │       │   │   ├─ [  4.27%] __pthread_mutex_unlock_usercnt  ↑
│   │               │   │   │   │   │   │   │   │       │   │   └─ [  0.06%] mht_put_internal
│   │               │   │   │   │   │   │   │   │       │   ├─ [  1.99%] pgbuf_unfix  ↑
│   │               │   │   │   │   │   │   │   │       │   └─ [  0.61%] log_sysop_start  ↑
│   │               │   │   │   │   │   │   │   │       ├─ [  7.88%] log_append_undoredo_data  ↑
│   │               │   │   │   │   │   │   │   │       ├─ [  1.37%] heap_stats_find_page_in_bestspace
│   │               │   │   │   │   │   │   │   │       │   ├─ [  0.57%] heap_stats_add_bestspace  ↑
│   │               │   │   │   │   │   │   │   │       │   ├─ [  0.30%] spage_max_space_for_new_record  ↑
│   │               │   │   │   │   │   │   │   │       │   ├─ [  5.61%] __GI___pthread_mutex_lock  ↑
│   │               │   │   │   │   │   │   │   │       │   ├─ [  4.27%] __pthread_mutex_unlock_usercnt  ↑
│   │               │   │   │   │   │   │   │   │       │   ├─ [  0.12%] xlogtb_reset_wait_msecs
│   │               │   │   │   │   │   │   │   │       │   │   └─ [  1.90%] LOG_FIND_TDES
│   │               │   │   │   │   │   │   │   │       │   ├─ [  0.06%] mht_rem
│   │               │   │   │   │   │   │   │   │       │   ├─ [  0.05%] er_errid
│   │               │   │   │   │   │   │   │   │       │   ├─ [  0.03%] mht_rem2
│   │               │   │   │   │   │   │   │   │       │   └─ [  0.03%] prm_get_integer_value
│   │               │   │   │   │   │   │   │   │       ├─ [  1.99%] pgbuf_unfix  ↑
│   │               │   │   │   │   │   │   │   │       ├─ [  0.18%] mht_get2
│   │               │   │   │   │   │   │   │   │       ├─ [  0.46%] spage_get_record
│   │               │   │   │   │   │   │   │   │       │   └─ [  0.32%] spage_find_slot
│   │               │   │   │   │   │   │   │   │       │       └─ [  0.07%] spage_is_unknown_slot
│   │               │   │   │   │   │   │   │   │       ├─ [  0.06%] pgbuf_ordered_set_dirty_and_free
│   │               │   │   │   │   │   │   │   │       │   └─ [  0.21%] pgbuf_set_dirty  ↑
│   │               │   │   │   │   │   │   │   │       ├─ [  0.06%] spage_get_record@plt
│   │               │   │   │   │   │   │   │   │       ├─ [  0.08%] pgbuf_ordered_unfix
│   │               │   │   │   │   │   │   │   │       │   ├─ [  0.04%] pgbuf_remove_watcher
│   │               │   │   │   │   │   │   │   │       │   └─ [  0.03%] pgbuf_get_holder
│   │               │   │   │   │   │   │   │   │       ├─ [  0.18%] spage_get_record_data
│   │               │   │   │   │   │   │   │   │       ├─ [  0.05%] pgbuf_unfix@plt
│   │               │   │   │   │   │   │   │   │       └─ [  1.75%] pgbuf_ordered_fix_release
│   │               │   │   │   │   │   │   │   │           ├─ [  3.91%] pgbuf_fix_release  ↑
│   │               │   │   │   │   │   │   │   │           └─ [  0.04%] pgbuf_fix_release@plt
│   │               │   │   │   │   │   │   │   ├─ [  6.25%] lock_object
│   │               │   │   │   │   │   │   │   │   ├─ [  5.81%] lock_internal_perform_lock_object
│   │               │   │   │   │   │   │   │   │   │   ├─ [  3.68%] cubthread::lockfree_hashmap<lk_res_key, lk_res>::find_or_insert
│   │               │   │   │   │   │   │   │   │   │   │   ├─ [  3.83%] lf_hash_insert_internal
│   │               │   │   │   │   │   │   │   │   │   │   │   ├─ [  3.58%] lf_list_insert_internal
│   │               │   │   │   │   │   │   │   │   │   │   │   │   ├─ [  2.48%] lock_res_key_compare
│   │               │   │   │   │   │   │   │   │   │   │   │   │   ├─ [  2.53%] lf_freelist_claim
│   │               │   │   │   │   │   │   │   │   │   │   │   │   │   ├─ [  2.01%] lf_freelist_alloc_block
│   │               │   │   │   │   │   │   │   │   │   │   │   │   │   │   ├─ [  7.24%] __GI___libc_malloc  ↑
│   │               │   │   │   │   │   │   │   │   │   │   │   │   │   │   └─ [  0.92%] lock_alloc_resource
│   │               │   │   │   │   │   │   │   │   │   │   │   │   │   │       └─ [  6.08%] cub_alloc  ↑
│   │               │   │   │   │   │   │   │   │   │   │   │   │   │   ├─ [  0.25%] lf_stack_pop
│   │               │   │   │   │   │   │   │   │   │   │   │   │   │   │   └─ [  0.08%] ATOMIC_CAS_ADDR<void>
│   │               │   │   │   │   │   │   │   │   │   │   │   │   │   ├─ [  0.18%] ATOMIC_INC_32<int, int>
│   │               │   │   │   │   │   │   │   │   │   │   │   │   │   └─ [  0.16%] lf_tran_start  ↑
│   │               │   │   │   │   │   │   │   │   │   │   │   │   ├─ [  5.61%] __GI___pthread_mutex_lock  ↑
│   │               │   │   │   │   │   │   │   │   │   │   │   │   ├─ [  0.08%] ATOMIC_CAS_ADDR<void>
│   │               │   │   │   │   │   │   │   │   │   │   │   │   └─ [  0.04%] lf_tran_end@plt
│   │               │   │   │   │   │   │   │   │   │   │   │   ├─ [  0.16%] lf_tran_start  ↑
│   │               │   │   │   │   │   │   │   │   │   │   │   ├─ [  0.03%] heap_hfid_table_entry_key_hash
│   │               │   │   │   │   │   │   │   │   │   │   │   └─ [  0.04%] lock_res_key_hash
│   │               │   │   │   │   │   │   │   │   │   │   └─ [  2.48%] lock_res_key_compare
│   │               │   │   │   │   │   │   │   │   │   ├─ [  2.53%] lf_freelist_claim  ↑
│   │               │   │   │   │   │   │   │   │   │   ├─ [  0.12%] lock_initialize_entry_as_granted
│   │               │   │   │   │   │   │   │   │   │   │   └─ [  0.21%] lock_event_set_xasl_id_to_entry
│   │               │   │   │   │   │   │   │   │   │   │       └─ [  1.90%] LOG_FIND_TDES
│   │               │   │   │   │   │   │   │   │   │   ├─ [  0.21%] lock_event_set_xasl_id_to_entry  ↑
│   │               │   │   │   │   │   │   │   │   │   ├─ [  0.20%] lock_find_class_entry
│   │               │   │   │   │   │   │   │   │   │   │   ├─ [  5.61%] __GI___pthread_mutex_lock  ↑
│   │               │   │   │   │   │   │   │   │   │   │   └─ [  4.27%] __pthread_mutex_unlock_usercnt  ↑
│   │               │   │   │   │   │   │   │   │   │   ├─ [  0.09%] lock_insert_into_tran_hold_list
│   │               │   │   │   │   │   │   │   │   │   │   └─ [  5.61%] __GI___pthread_mutex_lock  ↑
│   │               │   │   │   │   │   │   │   │   │   ├─ [  4.27%] __pthread_mutex_unlock_usercnt  ↑
│   │               │   │   │   │   │   │   │   │   │   ├─ [  0.03%] lock_escalate_if_needed
│   │               │   │   │   │   │   │   │   │   │   │   └─ [  4.27%] __pthread_mutex_unlock_usercnt  ↑
│   │               │   │   │   │   │   │   │   │   │   └─ [  5.61%] __GI___pthread_mutex_lock  ↑
│   │               │   │   │   │   │   │   │   │   ├─ [  0.20%] lock_get_class_lock
│   │               │   │   │   │   │   │   │   │   │   ├─ [  5.61%] __GI___pthread_mutex_lock  ↑
│   │               │   │   │   │   │   │   │   │   │   ├─ [  0.05%] logtb_get_current_tran_index
│   │               │   │   │   │   │   │   │   │   │   │   └─ [  0.27%] thread_get_thread_entry_info  ↑
│   │               │   │   │   │   │   │   │   │   │   └─ [  4.27%] __pthread_mutex_unlock_usercnt  ↑
│   │               │   │   │   │   │   │   │   │   ├─ [  0.20%] lock_find_class_entry  ↑
│   │               │   │   │   │   │   │   │   │   ├─ [  0.04%] logtb_find_wait_msecs
│   │               │   │   │   │   │   │   │   │   │   └─ [  1.90%] LOG_FIND_TDES
│   │               │   │   │   │   │   │   │   │   └─ [  0.03%] prm_get_integer_value
│   │               │   │   │   │   │   │   │   ├─ [ 11.44%] heap_log_insert_physical
│   │               │   │   │   │   │   │   │   │   ├─ [ 19.52%] log_append_undoredo_crumbs  ↑
│   │               │   │   │   │   │   │   │   │   ├─ [  0.34%] heap_mvcc_log_insert
│   │               │   │   │   │   │   │   │   │   │   ├─ [  0.27%] logtb_get_current_mvccid
│   │               │   │   │   │   │   │   │   │   │   │   └─ [  1.90%] LOG_FIND_TDES
│   │               │   │   │   │   │   │   │   │   │   ├─ [  0.09%] heap_page_get_vacuum_status
│   │               │   │   │   │   │   │   │   │   │   │   ├─ [  0.46%] spage_get_record  ↑
│   │               │   │   │   │   │   │   │   │   │   │   ├─ [  0.18%] spage_get_record_data
│   │               │   │   │   │   │   │   │   │   │   │   └─ [  0.06%] spage_get_record@plt
│   │               │   │   │   │   │   │   │   │   │   ├─ [  0.06%] heap_page_update_chain_after_mvcc_op
│   │               │   │   │   │   │   │   │   │   │   │   ├─ [  0.46%] spage_get_record  ↑
│   │               │   │   │   │   │   │   │   │   │   │   └─ [  0.18%] spage_get_record_data
│   │               │   │   │   │   │   │   │   │   │   ├─ [  0.11%] or_header_size
│   │               │   │   │   │   │   │   │   │   │   └─ [  0.05%] or_header_size@plt
│   │               │   │   │   │   │   │   │   │   └─ [  0.06%] log_append_undoredo_crumbs@plt
│   │               │   │   │   │   │   │   │   ├─ [  3.44%] spage_insert_at
│   │               │   │   │   │   │   │   │   │   ├─ [  2.87%] spage_insert_data  ↑
│   │               │   │   │   │   │   │   │   │   └─ [  0.54%] spage_find_empty_slot_at
│   │               │   │   │   │   │   │   │   │       ├─ [  0.35%] spage_check_space  ↑
│   │               │   │   │   │   │   │   │   │       ├─ [  0.07%] spage_add_new_slot
│   │               │   │   │   │   │   │   │   │       │   └─ [  0.04%] spage_verify_header
│   │               │   │   │   │   │   │   │   │       └─ [  0.04%] spage_verify_header
│   │               │   │   │   │   │   │   │   ├─ [  1.99%] pgbuf_unfix  ↑
│   │               │   │   │   │   │   │   │   ├─ [  0.18%] mvcc_is_mvcc_disabled_class
│   │               │   │   │   │   │   │   │   ├─ [  0.27%] logtb_get_current_mvccid  ↑
│   │               │   │   │   │   │   │   │   ├─ [  0.03%] heap_insert_adjust_recdes_header
│   │               │   │   │   │   │   │   │   ├─ [  0.08%] pgbuf_ordered_unfix  ↑
│   │               │   │   │   │   │   │   │   ├─ [  0.04%] mvcc_is_mvcc_disabled_class@plt
│   │               │   │   │   │   │   │   │   ├─ [  0.21%] pgbuf_set_dirty  ↑
│   │               │   │   │   │   │   │   │   └─ [  0.03%] spage_insert_at@plt
│   │               │   │   │   │   │   │   ├─ [ 10.84%] locator_add_or_remove_index_internal
│   │               │   │   │   │   │   │   │   ├─ [  7.17%] btree_insert
│   │               │   │   │   │   │   │   │   │   ├─ [  7.07%] btree_insert_internal
│   │               │   │   │   │   │   │   │   │   │   ├─ [  4.71%] btree_search_key_and_apply_functions
│   │               │   │   │   │   │   │   │   │   │   │   ├─ [  4.05%] btree_fix_root_for_insert
│   │               │   │   │   │   │   │   │   │   │   │   │   ├─ [  3.33%] logtb_tran_update_unique_stats
│   │               │   │   │   │   │   │   │   │   │   │   │   │   ├─ [  3.68%] log_append_undo_data2
│   │               │   │   │   │   │   │   │   │   │   │   │   │   │   └─ [  3.66%] log_append_undo_crumbs
│   │               │   │   │   │   │   │   │   │   │   │   │   │   │       ├─ [ 15.54%] prior_lsa_alloc_and_copy_crumbs  ↑
│   │               │   │   │   │   │   │   │   │   │   │   │   │   │       ├─ [  7.94%] prior_lsa_next_record_internal  ↑
│   │               │   │   │   │   │   │   │   │   │   │   │   │   │       ├─ [  1.90%] LOG_FIND_TDES
│   │               │   │   │   │   │   │   │   │   │   │   │   │   │       └─ [  0.11%] log_tdes::is_system_worker_transaction
│   │               │   │   │   │   │   │   │   │   │   │   │   │   └─ [  0.28%] logtb_tran_update_btid_unique_stats
│   │               │   │   │   │   │   │   │   │   │   │   │   │       └─ [  0.24%] logtb_tran_find_btid_stats
│   │               │   │   │   │   │   │   │   │   │   │   │   │           ├─ [  0.34%] mht_get  ↑
│   │               │   │   │   │   │   │   │   │   │   │   │   │           └─ [  1.90%] LOG_FIND_TDES
│   │               │   │   │   │   │   │   │   │   │   │   │   ├─ [  3.91%] pgbuf_fix_release  ↑
│   │               │   │   │   │   │   │   │   │   │   │   │   ├─ [  0.17%] btree_fix_root_with_info
│   │               │   │   │   │   │   │   │   │   │   │   │   │   ├─ [  0.11%] btree_glean_root_header_info
│   │               │   │   │   │   │   │   │   │   │   │   │   │   │   └─ [  0.15%] or_get_domain
│   │               │   │   │   │   │   │   │   │   │   │   │   │   │       └─ [  0.06%] unpack_domain
│   │               │   │   │   │   │   │   │   │   │   │   │   │   │           └─ [  0.06%] or_get_int
│   │               │   │   │   │   │   │   │   │   │   │   │   │   │               └─ [  0.68%] btree_search_nonleaf_page
│   │               │   │   │   │   │   │   │   │   │   │   │   │   │                   ├─ [  0.46%] btree_read_record_without_decompression
│   │               │   │   │   │   │   │   │   │   │   │   │   │   │                   │   ├─ [  0.19%] mr_index_readval_int
│   │               │   │   │   │   │   │   │   │   │   │   │   │   │                   │   │   ├─ [  3.69%] __memmove_evex_unaligned_erms
│   │               │   │   │   │   │   │   │   │   │   │   │   │   │                   │   │   └─ [  0.04%] memcpy@plt
│   │               │   │   │   │   │   │   │   │   │   │   │   │   │                   │   ├─ [  0.77%] btree_search_leaf_page
│   │               │   │   │   │   │   │   │   │   │   │   │   │   │                   │   │   ├─ [  0.27%] btree_compare_key
│   │               │   │   │   │   │   │   │   │   │   │   │   │   │                   │   │   ├─ [  0.46%] spage_get_record  ↑
│   │               │   │   │   │   │   │   │   │   │   │   │   │   │                   │   │   ├─ [  0.18%] spage_get_record_data
│   │               │   │   │   │   │   │   │   │   │   │   │   │   │                   │   │   └─ [  0.05%] btree_clear_key_value
│   │               │   │   │   │   │   │   │   │   │   │   │   │   │                   │   ├─ [  0.06%] btree_read_fixed_portion_of_non_leaf_record_from_orbuf
│   │               │   │   │   │   │   │   │   │   │   │   │   │   │                   │   ├─ [  0.05%] or_init
│   │               │   │   │   │   │   │   │   │   │   │   │   │   │                   │   └─ [  0.05%] btree_clear_key_value  ↑
│   │               │   │   │   │   │   │   │   │   │   │   │   │   │                   ├─ [  0.27%] btree_compare_key
│   │               │   │   │   │   │   │   │   │   │   │   │   │   │                   ├─ [  0.46%] spage_get_record  ↑
│   │               │   │   │   │   │   │   │   │   │   │   │   │   │                   ├─ [  0.18%] spage_get_record_data
│   │               │   │   │   │   │   │   │   │   │   │   │   │   │                   └─ [  0.03%] btree_compare_key@plt
│   │               │   │   │   │   │   │   │   │   │   │   │   │   └─ [  0.04%] btree_get_root_header
│   │               │   │   │   │   │   │   │   │   │   │   │   │       └─ [  0.46%] spage_get_record  ↑
│   │               │   │   │   │   │   │   │   │   │   │   │   ├─ [  0.05%] btree_unique_stats::btree_unique_stats@plt
│   │               │   │   │   │   │   │   │   │   │   │   │   ├─ [  0.03%] logtb_tran_update_unique_stats@plt
│   │               │   │   │   │   │   │   │   │   │   │   │   └─ [  0.08%] pr_index_writeval_disk_size
│   │               │   │   │   │   │   │   │   │   │   │   │       └─ [  0.06%] pr_type_from_id
│   │               │   │   │   │   │   │   │   │   │   │   ├─ [  1.99%] pgbuf_unfix  ↑
│   │               │   │   │   │   │   │   │   │   │   │   ├─ [  0.05%] pgbuf_unfix@plt
│   │               │   │   │   │   │   │   │   │   │   │   └─ [  0.27%] btree_key_insert_new_object
│   │               │   │   │   │   │   │   │   │   │   │       ├─ [  0.18%] btree_rv_save_keyval_for_undo
│   │               │   │   │   │   │   │   │   │   │   │       │   ├─ [  0.04%] mr_index_writeval_int
│   │               │   │   │   │   │   │   │   │   │   │       │   │   └─ [  3.69%] __memmove_evex_unaligned_erms
│   │               │   │   │   │   │   │   │   │   │   │       │   └─ [  0.08%] pr_index_writeval_disk_size  ↑
│   │               │   │   │   │   │   │   │   │   │   │       ├─ [  0.04%] btree_perf_track_time<btree_insert_helper>
│   │               │   │   │   │   │   │   │   │   │   │       └─ [  0.04%] btree_perf_track_traverse_time<btree_insert_helper>
│   │               │   │   │   │   │   │   │   │   │   ├─ [  2.19%] btree_split_node_and_advance
│   │               │   │   │   │   │   │   │   │   │   │   ├─ [  0.77%] btree_search_leaf_page  ↑
│   │               │   │   │   │   │   │   │   │   │   │   ├─ [  0.68%] btree_search_nonleaf_page  ↑
│   │               │   │   │   │   │   │   │   │   │   │   ├─ [  3.91%] pgbuf_fix_release  ↑
│   │               │   │   │   │   │   │   │   │   │   │   ├─ [  0.11%] btree_get_node_header
│   │               │   │   │   │   │   │   │   │   │   │   │   ├─ [  0.46%] spage_get_record  ↑
│   │               │   │   │   │   │   │   │   │   │   │   │   ├─ [  0.18%] spage_get_record_data
│   │               │   │   │   │   │   │   │   │   │   │   │   └─ [  0.06%] spage_get_record@plt
│   │               │   │   │   │   │   │   │   │   │   │   ├─ [  5.46%] file_alloc  ↑
│   │               │   │   │   │   │   │   │   │   │   │   ├─ [  0.04%] btree_node_number_of_keys@plt
│   │               │   │   │   │   │   │   │   │   │   │   ├─ [  0.06%] pgbuf_notify_vacuum_follows
│   │               │   │   │   │   │   │   │   │   │   │   └─ [  0.06%] btree_node_number_of_keys
│   │               │   │   │   │   │   │   │   │   │   └─ [  0.07%] btree_insert_helper::btree_insert_helper
│   │               │   │   │   │   │   │   │   │   └─ [  0.03%] btree_mvcc_info_from_heap_mvcc_header
│   │               │   │   │   │   │   │   │   ├─ [  1.27%] heap_get_class_name_alloc_if_diff
│   │               │   │   │   │   │   │   │   │   ├─ [  0.53%] heap_get_class_record
│   │               │   │   │   │   │   │   │   │   │   ├─ [  0.37%] heap_get_last_version
│   │               │   │   │   │   │   │   │   │   │   │   ├─ [  0.14%] heap_get_mvcc_header
│   │               │   │   │   │   │   │   │   │   │   │   │   ├─ [  0.09%] or_mvcc_get_header
│   │               │   │   │   │   │   │   │   │   │   │   │   ├─ [  0.18%] spage_get_record_data
│   │               │   │   │   │   │   │   │   │   │   │   │   ├─ [  0.46%] spage_get_record  ↑
│   │               │   │   │   │   │   │   │   │   │   │   │   └─ [  0.06%] spage_get_record@plt
│   │               │   │   │   │   │   │   │   │   │   │   ├─ [  0.12%] heap_prepare_get_context
│   │               │   │   │   │   │   │   │   │   │   │   │   └─ [  0.05%] heap_prepare_object_page
│   │               │   │   │   │   │   │   │   │   │   │   │       └─ [  1.75%] pgbuf_ordered_fix_release  ↑
│   │               │   │   │   │   │   │   │   │   │   │   └─ [  0.05%] heap_get_record_data_when_all_ready
│   │               │   │   │   │   │   │   │   │   │   │       ├─ [  0.18%] spage_get_record_data
│   │               │   │   │   │   │   │   │   │   │   │       └─ [  0.46%] spage_get_record  ↑
│   │               │   │   │   │   │   │   │   │   │   └─ [  0.09%] heap_clean_get_context
│   │               │   │   │   │   │   │   │   │   │       └─ [  0.08%] pgbuf_replace_watcher
│   │               │   │   │   │   │   │   │   │   │           ├─ [  0.04%] pgbuf_remove_watcher
│   │               │   │   │   │   │   │   │   │   │           └─ [  0.03%] pgbuf_get_holder
│   │               │   │   │   │   │   │   │   │   ├─ [  0.35%] heap_scancache_end
│   │               │   │   │   │   │   │   │   │   │   └─ [  0.36%] heap_scancache_quick_end
│   │               │   │   │   │   │   │   │   │   │       ├─ [  1.99%] pgbuf_unfix  ↑
│   │               │   │   │   │   │   │   │   │   │       └─ [  0.08%] pgbuf_ordered_unfix  ↑
│   │               │   │   │   │   │   │   │   │   ├─ [  0.20%] cub_strdup
│   │               │   │   │   │   │   │   │   │   │   ├─ [  6.08%] cub_alloc  ↑
│   │               │   │   │   │   │   │   │   │   │   └─ [  0.07%] __strlen_evex
│   │               │   │   │   │   │   │   │   │   ├─ [  0.10%] heap_scancache_quick_start_root_hfid
│   │               │   │   │   │   │   │   │   │   │   └─ [  0.04%] boot_find_root_heap
│   │               │   │   │   │   │   │   │   │   └─ [  0.04%] or_class_name
│   │               │   │   │   │   │   │   │   ├─ [  0.93%] heap_attrinfo_end
│   │               │   │   │   │   │   │   │   │   ├─ [  1.00%] heap_classrepr_free
│   │               │   │   │   │   │   │   │   │   │   ├─ [  4.27%] __pthread_mutex_unlock_usercnt  ↑
│   │               │   │   │   │   │   │   │   │   │   ├─ [  5.61%] __GI___pthread_mutex_lock  ↑
│   │               │   │   │   │   │   │   │   │   │   └─ [  0.06%] pthread_mutex_lock@plt
│   │               │   │   │   │   │   │   │   │   ├─ [  0.07%] heap_attrinfo_clear_dbvalues
│   │               │   │   │   │   │   │   │   │   │   └─ [  0.05%] pr_clear_value
│   │               │   │   │   │   │   │   │   │   └─ [  0.04%] mspace_free
│   │               │   │   │   │   │   │   │   ├─ [  1.10%] heap_attrinfo_start_with_index
│   │               │   │   │   │   │   │   │   │   ├─ [  0.96%] heap_classrepr_get
│   │               │   │   │   │   │   │   │   │   │   ├─ [  5.61%] __GI___pthread_mutex_lock  ↑
│   │               │   │   │   │   │   │   │   │   │   ├─ [  4.27%] __pthread_mutex_unlock_usercnt  ↑
│   │               │   │   │   │   │   │   │   │   │   └─ [  0.40%] __GI___pthread_mutex_trylock
│   │               │   │   │   │   │   │   │   │   ├─ [  0.21%] heap_attrinfo_recache_attrepr
│   │               │   │   │   │   │   │   │   │   │   └─ [  0.08%] db_value_domain_init
│   │               │   │   │   │   │   │   │   │   └─ [  0.10%] hl_lea_alloc
│   │               │   │   │   │   │   │   │   │       └─ [  0.07%] mspace_malloc
│   │               │   │   │   │   │   │   │   ├─ [  0.54%] heap_attrinfo_read_dbvalues
│   │               │   │   │   │   │   │   │   │   ├─ [  0.28%] heap_attrvalue_read
│   │               │   │   │   │   │   │   │   │   │   ├─ [  0.16%] heap_attrvalue_point_fixed
│   │               │   │   │   │   │   │   │   │   │   │   └─ [  0.06%] tp_domain_disk_size
│   │               │   │   │   │   │   │   │   │   │   └─ [  0.06%] heap_attrvalue_transform_to_dbvalue
│   │               │   │   │   │   │   │   │   │   │       └─ [  0.03%] mr_data_readval_int
│   │               │   │   │   │   │   │   │   │   │           └─ [  0.06%] or_get_int  ↑
│   │               │   │   │   │   │   │   │   │   ├─ [  0.12%] or_rep_id
│   │               │   │   │   │   │   │   │   │   │   ├─ [  0.11%] or_header_size
│   │               │   │   │   │   │   │   │   │   │   └─ [  0.05%] or_header_size@plt
│   │               │   │   │   │   │   │   │   │   ├─ [  0.06%] pr_type_from_id
│   │               │   │   │   │   │   │   │   │   └─ [  0.04%] heap_attrinfo_recache
│   │               │   │   │   │   │   │   │   ├─ [  0.15%] heap_attrvalue_get_key
│   │               │   │   │   │   │   │   │   │   ├─ [  0.06%] heap_attrinfo_access
│   │               │   │   │   │   │   │   │   │   └─ [  0.12%] or_rep_id  ↑
│   │               │   │   │   │   │   │   │   ├─ [  0.27%] logtb_get_current_mvccid  ↑
│   │               │   │   │   │   │   │   │   ├─ [  0.18%] mvcc_is_mvcc_disabled_class
│   │               │   │   │   │   │   │   │   ├─ [  0.20%] logtb_find_client_type  ↑
│   │               │   │   │   │   │   │   │   ├─ [  0.04%] mvcc_is_mvcc_disabled_class@plt
│   │               │   │   │   │   │   │   │   ├─ [  0.08%] __GI___libc_free
│   │               │   │   │   │   │   │   │   ├─ [  0.04%] heap_attrinfo_read_dbvalues@plt
│   │               │   │   │   │   │   │   │   ├─ [  0.47%] _int_free
│   │               │   │   │   │   │   │   │   │   ├─ [  0.68%] malloc_consolidate  ↑
│   │               │   │   │   │   │   │   │   │   └─ [  0.32%] unlink_chunk.isra.2
│   │               │   │   │   │   │   │   │   └─ [  0.09%] cub_free
│   │               │   │   │   │   │   │   │       ├─ [  0.08%] __GI___libc_free
│   │               │   │   │   │   │   │   │       └─ [  0.47%] _int_free  ↑
│   │               │   │   │   │   │   │   ├─ [  0.99%] locator_check_foreign_key
│   │               │   │   │   │   │   │   │   ├─ [  1.10%] heap_attrinfo_start_with_index  ↑
│   │               │   │   │   │   │   │   │   ├─ [  0.93%] heap_attrinfo_end  ↑
│   │               │   │   │   │   │   │   │   ├─ [  0.54%] heap_attrinfo_read_dbvalues  ↑
│   │               │   │   │   │   │   │   │   └─ [  0.04%] heap_attrinfo_read_dbvalues@plt
│   │               │   │   │   │   │   │   └─ [  0.05%] heap_create_insert_context
│   │               │   │   │   │   │   ├─ [  1.32%] xtran_server_end_topop
│   │               │   │   │   │   │   │   ├─ [  0.59%] log_sysop_attach_to_outer
│   │               │   │   │   │   │   │   │   ├─ [  0.39%] log_tdes::unlock_topop  ↑
│   │               │   │   │   │   │   │   │   ├─ [  0.15%] log_sysop_end_final  ↑
│   │               │   │   │   │   │   │   │   ├─ [  0.23%] rmutex_unlock  ↑
│   │               │   │   │   │   │   │   │   ├─ [  0.05%] log_sysop_end_begin  ↑
│   │               │   │   │   │   │   │   │   └─ [  0.04%] LSA_ISNULL
│   │               │   │   │   │   │   │   ├─ [  0.28%] cuberr::context::pop_error_stack_and_destroy
│   │               │   │   │   │   │   │   │   ├─ [  0.14%] cuberr::context::pop_error_stack
│   │               │   │   │   │   │   │   │   │   ├─ [  0.08%] cuberr::er_message::swap
│   │               │   │   │   │   │   │   │   │   └─ [  0.05%] operator delete
│   │               │   │   │   │   │   │   │   │       └─ [  0.09%] cub_free  ↑
│   │               │   │   │   │   │   │   │   ├─ [  0.07%] cuberr::er_message::~er_message
│   │               │   │   │   │   │   │   │   └─ [  0.10%] cuberr::er_message::er_message
│   │               │   │   │   │   │   │   ├─ [  0.18%] cuberr::context::push_error_stack
│   │               │   │   │   │   │   │   │   ├─ [  0.30%] operator new
│   │               │   │   │   │   │   │   │   │   ├─ [  7.24%] __GI___libc_malloc  ↑
│   │               │   │   │   │   │   │   │   │   ├─ [  6.08%] cub_alloc  ↑
│   │               │   │   │   │   │   │   │   │   └─ [  0.07%] malloc@plt
│   │               │   │   │   │   │   │   │   └─ [  0.10%] cuberr::er_message::er_message
│   │               │   │   │   │   │   │   ├─ [  0.24%] LOG_FIND_CURRENT_TDES  ↑
│   │               │   │   │   │   │   │   └─ [  0.09%] er_stack_push
│   │               │   │   │   │   │   │       └─ [  0.14%] cuberr::context::get_thread_local_context
│   │               │   │   │   │   │   │           ├─ [  0.20%] __tls_get_addr
│   │               │   │   │   │   │   │           └─ [  0.04%] __tls_get_addr@plt
│   │               │   │   │   │   │   ├─ [  0.64%] xtran_server_start_topop
│   │               │   │   │   │   │   │   ├─ [  0.61%] log_sysop_start  ↑
│   │               │   │   │   │   │   │   ├─ [  0.09%] log_get_parent_lsa_system_op
│   │               │   │   │   │   │   │   │   └─ [  1.90%] LOG_FIND_TDES
│   │               │   │   │   │   │   │   └─ [  0.05%] locator_savepoint_transient_class_name_entries
│   │               │   │   │   │   │   ├─ [  0.62%] heap_get_class_repr_id
│   │               │   │   │   │   │   │   ├─ [  0.96%] heap_classrepr_get  ↑
│   │               │   │   │   │   │   │   └─ [  1.00%] heap_classrepr_free  ↑
│   │               │   │   │   │   │   ├─ [  0.43%] heap_get_class_info
│   │               │   │   │   │   │   │   └─ [  0.41%] heap_hfid_cache_get
│   │               │   │   │   │   │   │       ├─ [  3.83%] lf_hash_insert_internal  ↑
│   │               │   │   │   │   │   │       └─ [  0.04%] lf_tran_end@plt
│   │               │   │   │   │   │   ├─ [  0.30%] heap_scancache_start_modify
│   │               │   │   │   │   │   │   ├─ [  0.21%] file_get_type
│   │               │   │   │   │   │   │   │   ├─ [  3.91%] pgbuf_fix_release  ↑
│   │               │   │   │   │   │   │   │   └─ [  1.99%] pgbuf_unfix  ↑
│   │               │   │   │   │   │   │   └─ [  0.06%] heap_scancache_reset_modify
│   │               │   │   │   │   │   │       ├─ [  0.43%] heap_get_class_info  ↑
│   │               │   │   │   │   │   │       └─ [  0.18%] mvcc_is_mvcc_disabled_class
│   │               │   │   │   │   │   ├─ [  0.15%] or_unpack_mem_value
│   │               │   │   │   │   │   │   ├─ [  0.15%] or_get_domain  ↑
│   │               │   │   │   │   │   │   └─ [  0.03%] mr_data_readval_int  ↑
│   │               │   │   │   │   │   ├─ [  0.07%] er_clear
│   │               │   │   │   │   │   │   ├─ [  0.03%] er_is_initialized@plt
│   │               │   │   │   │   │   │   └─ [  0.14%] cuberr::context::get_thread_local_context  ↑
│   │               │   │   │   │   │   ├─ [  0.02%] locator_update_force  ⎘소스연결
│   │               │   │   │   │   │   ├─ [  0.08%] perfmon_inc_stat  ↑
│   │               │   │   │   │   │   ├─ [  0.36%] heap_scancache_quick_end  ↑
│   │               │   │   │   │   │   └─ [  0.05%] pr_clear_value
│   │               │   │   │   │   ├─ [  1.16%] css_send_reply_and_2_data_to_client
│   │               │   │   │   │   │   ├─ [  0.83%] css_enqueue_and_notify
│   │               │   │   │   │   │   │   ├─ [  0.77%] cubconn::connection::worker::enqueue_and_notify
│   │               │   │   │   │   │   │   │   ├─ [  0.65%] cubconn::connection::worker::notify
│   │               │   │   │   │   │   │   │   │   └─ [  0.64%] __libc_write
│   │               │   │   │   │   │   │   │   └─ [  1.15%] cubconn::connection::worker::enqueue
│   │               │   │   │   │   │   │   │       └─ [  0.82%] tbb::detail::d2::micro_queue<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >::prepare_page(unsigned long, tbb::detail::d2::concurrent_queue_rep<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >&, tbb::detail::d1::cache_aligned_allocator<tbb::detail::d2::micro_queue<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >::padded_page>, tbb::detail::d2::micro_queue<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >::padded_page*&)::{lambda()#1}::operator()
│   │               │   │   │   │   │   │   │           └─ [  0.82%] tbb::detail::r1::cache_aligned_allocate
│   │               │   │   │   │   │   │   │               └─ [  0.80%] _mid_memalign
│   │               │   │   │   │   │   │   │                   └─ [  0.74%] _int_memalign
│   │               │   │   │   │   │   │   │                       ├─ [  6.52%] _int_malloc  ↑
│   │               │   │   │   │   │   │   │                       └─ [  0.47%] _int_free  ↑
│   │               │   │   │   │   │   │   └─ [  0.69%] rmutex_lock  ↑
│   │               │   │   │   │   │   ├─ [  0.69%] rmutex_lock  ↑
│   │               │   │   │   │   │   ├─ [  0.30%] operator new  ↑
│   │               │   │   │   │   │   ├─ [  0.05%] std::vector<cubbase::span<std::byte>, std::allocator<cubbase::span<std::byte> > >::_M_realloc_insert<std::byte*&, unsigned long>
│   │               │   │   │   │   │   │   ├─ [  0.30%] operator new  ↑
│   │               │   │   │   │   │   │   └─ [  0.05%] operator delete  ↑
│   │               │   │   │   │   │   ├─ [  0.04%] operator new[]
│   │               │   │   │   │   │   │   └─ [  6.08%] cub_alloc  ↑
│   │               │   │   │   │   │   └─ [  0.23%] rmutex_unlock  ↑
│   │               │   │   │   │   ├─ [  1.18%] css_request_release_packet
│   │               │   │   │   │   │   ├─ [  1.15%] cubconn::connection::worker::enqueue  ↑
│   │               │   │   │   │   │   ├─ [  0.69%] rmutex_lock  ↑
│   │               │   │   │   │   │   ├─ [  0.08%] std::vector<cubbase::span<std::byte>, std::allocator<cubbase::span<std::byte> > >::_M_realloc_insert<std::byte*, int>
│   │               │   │   │   │   │   │   └─ [  0.30%] operator new  ↑
│   │               │   │   │   │   │   └─ [  0.23%] rmutex_unlock  ↑
│   │               │   │   │   │   ├─ [  3.69%] __memmove_evex_unaligned_erms
│   │               │   │   │   │   ├─ [  0.29%] css_receive_data_from_client_with_timeout
│   │               │   │   │   │   │   ├─ [  0.45%] css_receive_data
│   │               │   │   │   │   │   │   ├─ [  0.27%] css_return_queued_data_timeout
│   │               │   │   │   │   │   │   │   ├─ [  0.69%] rmutex_lock  ↑
│   │               │   │   │   │   │   │   │   └─ [  0.23%] rmutex_unlock  ↑
│   │               │   │   │   │   │   │   ├─ [  6.08%] cub_alloc  ↑
│   │               │   │   │   │   │   │   ├─ [  0.11%] css_traverse_list
│   │               │   │   │   │   │   │   │   └─ [  0.06%] css_find_queue_entry_by_key
│   │               │   │   │   │   │   │   ├─ [  0.04%] thread_suspend_timeout_wakeup_and_unlock_entry
│   │               │   │   │   │   │   │   │   └─ [  2.52%] __pthread_cond_timedwait
│   │               │   │   │   │   │   │   └─ [  0.09%] cub_free  ↑
│   │               │   │   │   │   │   └─ [  0.05%] css_return_queued_error
│   │               │   │   │   │   │       ├─ [  0.69%] rmutex_lock  ↑
│   │               │   │   │   │   │       └─ [  0.23%] rmutex_unlock  ↑
│   │               │   │   │   │   ├─ [  0.09%] locator_unpack_copy_area_descriptor
│   │               │   │   │   │   │   └─ [  0.03%] or_unpack_int
│   │               │   │   │   │   ├─ [  0.04%] locator_recv_allocate_copyarea
│   │               │   │   │   │   │   └─ [  0.07%] locator_allocate_copy_area_by_length
│   │               │   │   │   │   │       └─ [  6.08%] cub_alloc  ↑
│   │               │   │   │   │   └─ [  0.03%] or_unpack_int
│   │               │   │   │   ├─ [  1.89%] stran_server_commit
│   │               │   │   │   │   ├─ [  1.87%] xtran_server_commit
│   │               │   │   │   │   │   └─ [  1.87%] log_commit
│   │               │   │   │   │   │       └─ [  1.85%] log_commit_local
│   │               │   │   │   │   │           ├─ [  1.80%] lock_unlock_all
│   │               │   │   │   │   │           │   ├─ [  0.99%] lock_remove_resource
│   │               │   │   │   │   │           │   │   └─ [  0.98%] lf_hash_delete_already_locked
│   │               │   │   │   │   │           │   │       ├─ [  0.94%] lf_list_delete
│   │               │   │   │   │   │           │   │       │   ├─ [  2.48%] lock_res_key_compare
│   │               │   │   │   │   │           │   │       │   ├─ [  0.56%] lf_freelist_retire
│   │               │   │   │   │   │           │   │       │   │   ├─ [  0.40%] lf_freelist_transport
│   │               │   │   │   │   │           │   │       │   │   │   ├─ [  0.33%] lock_dealloc_entry
│   │               │   │   │   │   │           │   │       │   │   │   │   ├─ [  0.47%] _int_free  ↑
│   │               │   │   │   │   │           │   │       │   │   │   │   └─ [  0.08%] __GI___libc_free
│   │               │   │   │   │   │           │   │       │   │   │   └─ [  0.04%] lock_dealloc_resource
│   │               │   │   │   │   │           │   │       │   │   │       ├─ [  0.47%] _int_free  ↑
│   │               │   │   │   │   │           │   │       │   │   │       └─ [  0.08%] __GI___libc_free
│   │               │   │   │   │   │           │   │       │   │   ├─ [  0.18%] ATOMIC_INC_32<int, int>
│   │               │   │   │   │   │           │   │       │   │   └─ [  0.16%] lf_tran_start  ↑
│   │               │   │   │   │   │           │   │       │   ├─ [  0.16%] lf_tran_start  ↑
│   │               │   │   │   │   │           │   │       │   └─ [  0.08%] ATOMIC_CAS_ADDR<void>
│   │               │   │   │   │   │           │   │       └─ [  0.03%] lf_hash_delete_internal
│   │               │   │   │   │   │           │   │           └─ [  0.04%] lock_res_key_hash
│   │               │   │   │   │   │           │   └─ [  0.81%] lock_internal_perform_unlock_object
│   │               │   │   │   │   │           │       ├─ [  0.56%] lf_freelist_retire  ↑
│   │               │   │   │   │   │           │       ├─ [  5.61%] __GI___pthread_mutex_lock  ↑
│   │               │   │   │   │   │           │       └─ [  0.09%] lock_delete_from_tran_hold_list
│   │               │   │   │   │   │           │           └─ [  4.27%] __pthread_mutex_unlock_usercnt  ↑
│   │               │   │   │   │   │           ├─ [  0.05%] log_change_tran_as_completed
│   │               │   │   │   │   │           └─ [  0.04%] logpb_flush_pages
│   │               │   │   │   │   │               └─ [  2.52%] __pthread_cond_timedwait
│   │               │   │   │   │   └─ [  0.04%] css_send_data_to_client
│   │               │   │   │   │       └─ [  0.83%] css_enqueue_and_notify  ↑
│   │               │   │   │   ├─ [  0.44%] slogwr_get_log_pages
│   │               │   │   │   │   └─ [  0.44%] xlogwr_get_log_pages
│   │               │   │   │   │       ├─ [  0.18%] logpb_copy_page_from_log_buffer
│   │               │   │   │   │       │   └─ [  0.18%] logpb_copy_page
│   │               │   │   │   │       │       └─ [  3.69%] __memmove_evex_unaligned_erms
│   │               │   │   │   │       ├─ [  0.10%] logwr_pack_log_pages
│   │               │   │   │   │       ├─ [  0.10%] crypt_crc32
│   │               │   │   │   │       ├─ [  0.05%] xlog_get_page_request_with_reply
│   │               │   │   │   │       │   └─ [  0.05%] xs_receive_data_from_client_with_timeout
│   │               │   │   │   │       │       └─ [  0.29%] css_receive_data_from_client_with_timeout  ↑
│   │               │   │   │   │       ├─ [  0.05%] thread_suspend_with_other_mutex
│   │               │   │   │   │       │   └─ [  0.08%] __pthread_cond_wait
│   │               │   │   │   │       └─ [  0.08%] __pthread_cond_wait
│   │               │   │   │   ├─ [  1.18%] css_request_release_packet  ↑
│   │               │   │   │   ├─ [  0.11%] sqmgr_execute_query
│   │               │   │   │   │   └─ [  0.09%] xqmgr_execute_query
│   │               │   │   │   │       └─ [  0.08%] qmgr_process_query
│   │               │   │   │   │           └─ [  0.08%] qexec_execute_query
│   │               │   │   │   │               └─ [  0.07%] qexec_execute_mainblock
│   │               │   │   │   │                   ├─ [  0.07%] qexec_execute_update
│   │               │   │   │   │                   └─ [  0.04%] qexec_execute_mainblock_internal
│   │               │   │   │   │                       └─ [  0.04%] qexec_intprt_fnc
│   │               │   │   │   ├─ [  0.09%] hl_clear_lea_heap
│   │               │   │   │   │   └─ [  0.05%] create_mspace_with_base
│   │               │   │   │   │       └─ [  0.04%] init_user_mstate
│   │               │   │   │   ├─ [  0.05%] slocator_fetch
│   │               │   │   │   │   └─ [  0.04%] xlocator_fetch
│   │               │   │   │   │       └─ [  0.07%] locator_allocate_copy_area_by_length  ↑
│   │               │   │   │   └─ [  0.04%] logtb_is_tran_modification_disabled
│   │               │   │   │       └─ [  1.90%] LOG_FIND_TDES
│   │               │   │   ├─ [  0.91%] css_internal_request_handler
│   │               │   │   │   ├─ [  0.63%] css_return_queued_request
│   │               │   │   │   │   ├─ [  1.18%] css_request_release_packet  ↑
│   │               │   │   │   │   ├─ [  0.69%] rmutex_lock  ↑
│   │               │   │   │   │   ├─ [  0.04%] css_remove_list_from_head
│   │               │   │   │   │   ├─ [  0.23%] rmutex_unlock  ↑
│   │               │   │   │   │   └─ [  0.04%] rmutex_lock@plt
│   │               │   │   │   └─ [  0.45%] css_receive_data  ↑
│   │               │   │   ├─ [  0.19%] css_wakeup_handler
│   │               │   │   │   ├─ [  0.65%] cubconn::connection::worker::notify  ↑
│   │               │   │   │   └─ [  0.69%] rmutex_lock  ↑
│   │               │   │   ├─ [  0.03%] pgbuf_thread_variables_init
│   │               │   │   └─ [  0.23%] rmutex_unlock  ↑
│   │               │   ├─ [  0.09%] cubthread::wp_worker_statset_time_and_increment
│   │               │   │   └─ [  0.09%] std::chrono::_V2::system_clock::now
│   │               │   │       └─ [  0.20%] __clock_gettime_2
│   │               │   ├─ [  0.05%] cubthread::entry_manager::recycle_context
│   │               │   │   └─ [  0.07%] er_clear  ↑
│   │               │   └─ [  0.03%] cubthread::worker_pool::core::get_entry_manager
│   │               └─ [  2.74%] cubthread::worker_pool::core::worker::get_new_task
│   │                   ├─ [  2.52%] __pthread_cond_timedwait
│   │                   ├─ [  4.27%] __pthread_mutex_unlock_usercnt  ↑
│   │                   ├─ [  0.05%] cubthread::worker_pool::core::get_task_or_become_available
│   │                   │   ├─ [  5.61%] __GI___pthread_mutex_lock  ↑
│   │                   │   └─ [  4.27%] __pthread_mutex_unlock_usercnt  ↑
│   │                   ├─ [  0.09%] std::chrono::_V2::system_clock::now  ↑
│   │                   └─ [  0.09%] cubthread::wp_worker_statset_time_and_increment  ↑
│   ├─ [  3.75%] btree_key_insert_new_key   ◆덩어리#2 (이 스레드의 독립 호출 조각 — 상위는 truncation 으로 끊김)
│   │   ├─ [  7.88%] log_append_undoredo_data  ↑
│   │   ├─ [  3.44%] spage_insert_at  ↑
│   │   ├─ [  0.06%] btree_write_record
│   │   │   └─ [  0.04%] mr_index_writeval_int  ↑
│   │   ├─ [  0.03%] btree_rv_log_insert_object
│   │   ├─ [  0.11%] btree_get_node_header  ↑
│   │   ├─ [  0.03%] spage_insert_at@plt
│   │   ├─ [  0.08%] pr_index_writeval_disk_size  ↑
│   │   ├─ [  3.69%] __memmove_evex_unaligned_erms
│   │   └─ [  0.06%] btree_node_number_of_keys
│   ├─ [  1.20%] btree_split_node   ◆덩어리#3 (이 스레드의 독립 호출 조각 — 상위는 truncation 으로 끊김)
│   │   ├─ [  3.68%] log_append_undo_data2  ↑
│   │   ├─ [  0.37%] log_append_redo_data2
│   │   │   └─ [  0.37%] log_append_redo_crumbs
│   │   │       └─ [ 15.54%] prior_lsa_alloc_and_copy_crumbs  ↑
│   │   ├─ [  0.04%] btree_find_split_point
│   │   └─ [  3.44%] spage_insert_at  ↑
│   └─ (기타 truncation 고아 17개 — 서브트리는 위 덩어리에 이미 전개됨, % of total):
│           7.88%  locator_add_or_remove_index_internal
│           6.18%  heap_log_insert_physical
│           1.86%  heap_stats_find_best_page
│           1.73%  pgbuf_ordered_fix_release
│           0.49%  LZ4_read_ARCH
│           0.26%  btree_key_insert_new_object
│           0.25%  LZ4_compress_fast_extState
│           0.09%  LZ4_read32
│           0.07%  _int_malloc
│           0.05%  __lll_unlock_wake
│           0.04%  __GI___pthread_mutex_lock
│           0.04%  __GI___libc_malloc
│           0.04%  __lll_lock_wait
│           0.04%  logtb_get_current_mvccid
│           0.04%  cubpl::get_session
│           0.03%  heap_attrinfo_recache_attrepr
│           0.03%  log_append_undoredo_data
├─ [ 13.16%] «connections»  (19374 smp)
│   ├─ [ 12.72%] cubconn::connection::worker::run   ◆덩어리#1 (이 스레드의 독립 호출 조각 — 상위는 truncation 으로 끊김)
│   │   ├─ [  4.69%] cubconn::connection::worker::eventfd_handler
│   │   │   ├─ [  4.10%] cubconn::connection::worker::handle_message_queue
│   │   │   │   ├─ [  3.25%] cubconn::connection::worker::handle_message_queue_by_index
│   │   │   │   │   ├─ [  1.77%] cubconn::connection::worker::handle_message_queue_send_packet
│   │   │   │   │   │   ├─ [  1.41%] cubconn::transmitter::fill
│   │   │   │   │   │   │   └─ [  1.37%] __sendmsg
│   │   │   │   │   │   ├─ [  0.12%] cubconn::transmitter::clear
│   │   │   │   │   │   │   ├─ [  0.05%] _M_invoke
│   │   │   │   │   │   │   │   └─ [  0.06%] operator()
│   │   │   │   │   │   │   │       └─ [  0.22%] operator delete
│   │   │   │   │   │   │   │           └─ [  0.23%] cub_free
│   │   │   │   │   │   │   │               ├─ [  0.33%] _int_free
│   │   │   │   │   │   │   │               └─ [  0.09%] __GI___libc_free
│   │   │   │   │   │   │   └─ [  0.04%] _M_manager
│   │   │   │   │   │   │       └─ [  0.22%] operator delete  ↑
│   │   │   │   │   │   ├─ [  0.52%] rmutex_lock
│   │   │   │   │   │   │   ├─ [  0.16%] __GI___pthread_mutex_lock
│   │   │   │   │   │   │   └─ [  0.12%] tsc_getticks
│   │   │   │   │   │   │       ├─ [  0.21%] __clock_gettime_2
│   │   │   │   │   │   │       └─ [  0.03%] clock_gettime@plt
│   │   │   │   │   │   └─ [  0.12%] rmutex_unlock
│   │   │   │   │   │       └─ [  0.08%] __pthread_mutex_unlock_usercnt
│   │   │   │   │   ├─ [  0.86%] cubconn::connection::worker::handle_message_queue_release_packet
│   │   │   │   │   │   ├─ [  0.55%] cubconn::receiver::release
│   │   │   │   │   │   │   └─ [  0.40%] cubbase::DMRBMemoryPool::restore
│   │   │   │   │   │   │       ├─ [  0.22%] std::_Rb_tree<unsigned long, std::pair<unsigned long const, unsigned long>, std::_Select1st<std::pair<unsigned long const, unsigned long> >, std::less<unsigned long>, std::allocator<std::pair<unsigned long const, unsigned long> > >::_M_emplace_unique<unsigned long&, unsigned long&>
│   │   │   │   │   │   │       │   └─ [  0.11%] operator new
│   │   │   │   │   │   │       │       └─ [  0.06%] __GI___libc_malloc
│   │   │   │   │   │   │       ├─ [  0.22%] operator delete  ↑
│   │   │   │   │   │   │       └─ [  0.04%] std::_Rb_tree_rebalance_for_erase
│   │   │   │   │   │   ├─ [  0.52%] rmutex_lock  ↑
│   │   │   │   │   │   └─ [  0.12%] rmutex_unlock  ↑
│   │   │   │   │   ├─ [  0.54%] tbb::detail::d2::internal_try_pop_impl<tbb::detail::d2::concurrent_queue_rep<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >, tbb::detail::d1::cache_aligned_allocator<tbb::detail::d2::concurrent_queue_rep<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> > > >
│   │   │   │   │   │   ├─ [  0.33%] _int_free
│   │   │   │   │   │   ├─ [  0.22%] operator delete  ↑
│   │   │   │   │   │   └─ [  0.09%] __GI___libc_free
│   │   │   │   │   └─ [  0.22%] operator delete  ↑
│   │   │   │   └─ [  0.85%] cubconn::connection::worker::purge_stale_contexts
│   │   │   │       ├─ [  0.52%] cubconn::connection::coordinator::notify
│   │   │   │       │   └─ [  0.50%] __libc_write
│   │   │   │       │       └─ [  0.03%] __pthread_enable_asynccancel
│   │   │   │       └─ [  0.34%] cubconn::connection::coordinator::enqueue
│   │   │   │           └─ [  0.22%] tbb::detail::d2::micro_queue<cubconn::connection::coordinator::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::coordinator::message> >::prepare_page(unsigned long, tbb::detail::d2::concurrent_queue_rep<cubconn::connection::coordinator::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::coordinator::message> >&, tbb::detail::d1::cache_aligned_allocator<tbb::detail::d2::micro_queue<cubconn::connection::coordinator::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::coordinator::message> >::padded_page>, tbb::detail::d2::micro_queue<cubconn::connection::coordinator::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::coordinator::message> >::padded_page*&)::{lambda()#1}::operator()
│   │   │   │               └─ [  0.22%] tbb::detail::r1::cache_aligned_allocate
│   │   │   │                   └─ [  0.20%] _mid_memalign
│   │   │   │                       └─ [  0.17%] _int_memalign
│   │   │   │                           ├─ [  0.11%] _int_malloc
│   │   │   │                           └─ [  0.33%] _int_free
│   │   │   ├─ [  0.45%] cubconn::connection::worker::eventfd_clear
│   │   │   │   └─ [  0.43%] __libc_read
│   │   │   │       └─ [  0.03%] __pthread_enable_asynccancel
│   │   │   └─ [  0.07%] cubconn::connection::worker::statistics_metrics_to_coordinator
│   │   │       ├─ [  0.34%] cubconn::connection::coordinator::enqueue  ↑
│   │   │       └─ [  0.13%] cubconn::connection::worker::get_time_ns
│   │   │           ├─ [  0.21%] __clock_gettime_2
│   │   │           └─ [  0.03%] clock_gettime@plt
│   │   ├─ [  3.91%] cubsocket::epoll::wait
│   │   │   └─ [  3.88%] epoll_wait
│   │   │       └─ [  0.04%] __libc_disable_asynccancel
│   │   ├─ [  3.86%] cubconn::connection::worker::handle_reception
│   │   │   ├─ [  2.31%] cubconn::receiver::drain
│   │   │   │   ├─ [  2.15%] cubconn::receiver::receive
│   │   │   │   │   └─ [  2.13%] __libc_recv
│   │   │   │   │       └─ [  0.03%] __pthread_enable_asynccancel
│   │   │   │   └─ [  0.09%] cubconn::receiver::parse_size
│   │   │   │       └─ [  0.06%] cubconn::receiver::parse_packet
│   │   │   ├─ [  0.86%] cubconn::connection::worker::handle_data_packet
│   │   │   │   ├─ [  0.57%] cubthread::worker_pool::core::execute_task
│   │   │   │   │   ├─ [  0.48%] cubthread::worker_pool::core::worker::assign_task
│   │   │   │   │   │   ├─ [  0.45%] std::condition_variable::notify_one
│   │   │   │   │   │   │   └─ [  0.44%] __pthread_cond_signal
│   │   │   │   │   │   └─ [  0.16%] __GI___pthread_mutex_lock
│   │   │   │   │   ├─ [  0.16%] __GI___pthread_mutex_lock
│   │   │   │   │   └─ [  0.08%] __pthread_mutex_unlock_usercnt
│   │   │   │   ├─ [  0.13%] css_add_queue_entry
│   │   │   │   │   └─ [  0.08%] css_make_queue_entry
│   │   │   │   ├─ [  0.07%] css_push_server_task
│   │   │   │   │   └─ [  0.11%] operator new  ↑
│   │   │   │   └─ [  0.05%] cubthread::worker_pool::execute_on_core
│   │   │   ├─ [  0.21%] cubconn::connection::worker::handle_header_packet
│   │   │   │   └─ [  0.55%] cubconn::receiver::release  ↑
│   │   │   ├─ [  0.52%] rmutex_lock  ↑
│   │   │   ├─ [  0.10%] cubconn::connection::worker::handle_command_header_packet
│   │   │   │   ├─ [  0.13%] css_add_queue_entry  ↑
│   │   │   │   └─ [  0.06%] css_is_request_aborted
│   │   │   ├─ [  0.12%] rmutex_unlock  ↑
│   │   │   └─ [  0.04%] std::chrono::_V2::steady_clock::now
│   │   │       └─ [  0.21%] __clock_gettime_2
│   │   ├─ [  0.13%] cubconn::connection::worker::get_time_ns  ↑
│   │   ├─ [  0.03%] cubconn::connection::worker::get_time_ns@plt
│   │   └─ [  3.88%] epoll_wait  ↑
│   └─ (기타 truncation 고아 1개 — 서브트리는 위 덩어리에 이미 전개됨, % of total):
│           0.03%  cubsocket::epoll::wait
├─ [  5.33%] «vacuum»  (7847 smp)
│   ├─ [  2.33%] vacuum_process_log_block   ◆덩어리#1 (이 스레드의 독립 호출 조각 — 상위는 truncation 으로 끊김)
│   │   ├─ [  2.01%] btree_vacuum_insert_mvccid
│   │   │   └─ [  2.00%] btree_delete_internal
│   │   │       ├─ [  1.38%] btree_merge_node_and_advance
│   │   │       │   ├─ [  1.04%] pgbuf_fix_release
│   │   │       │   │   ├─ [  0.51%] pgbuf_latch_bcb_upon_fix
│   │   │       │   │   │   ├─ [  0.40%] pgbuf_block_bcb
│   │   │       │   │   │   │   ├─ [  0.36%] thread_suspend_timeout_wakeup_and_unlock_entry
│   │   │       │   │   │   │   │   ├─ [  0.33%] __pthread_cond_timedwait
│   │   │       │   │   │   │   │   └─ [  0.31%] __pthread_mutex_unlock_usercnt
│   │   │       │   │   │   │   │       └─ [  0.22%] __lll_unlock_wake
│   │   │       │   │   │   │   └─ [  0.04%] pgbuf_timed_sleep
│   │   │       │   │   │   │       └─ [  0.31%] __pthread_mutex_unlock_usercnt  ↑
│   │   │       │   │   │   └─ [  0.10%] pgbuf_find_thrd_holder
│   │   │       │   │   ├─ [  0.14%] pgbuf_search_hash_chain
│   │   │       │   │   │   ├─ [  0.07%] __GI___pthread_mutex_trylock
│   │   │       │   │   │   └─ [  0.46%] __GI___pthread_mutex_lock
│   │   │       │   │   │       └─ [  0.22%] __lll_lock_wait
│   │   │       │   │   ├─ [  0.05%] pgbuf_lockfree_fix_ro
│   │   │       │   │   └─ [  0.31%] __pthread_mutex_unlock_usercnt  ↑
│   │   │       │   ├─ [  0.30%] btree_search_leaf_page
│   │   │       │   │   ├─ [  0.20%] btree_read_record_without_decompression
│   │   │       │   │   │   └─ [  0.06%] mr_index_readval_int
│   │   │       │   │   │       └─ [  1.20%] __memmove_evex_unaligned_erms
│   │   │       │   │   ├─ [  0.12%] spage_get_record
│   │   │       │   │   │   └─ [  0.08%] spage_find_slot
│   │   │       │   │   ├─ [  0.11%] btree_compare_key
│   │   │       │   │   └─ [  0.82%] spage_get_record_data
│   │   │       │   │       └─ [  1.20%] __memmove_evex_unaligned_erms
│   │   │       │   ├─ [  0.23%] btree_search_nonleaf_page
│   │   │       │   │   ├─ [  0.20%] btree_read_record_without_decompression  ↑
│   │   │       │   │   ├─ [  0.11%] btree_compare_key
│   │   │       │   │   ├─ [  0.12%] spage_get_record  ↑
│   │   │       │   │   └─ [  0.82%] spage_get_record_data  ↑
│   │   │       │   ├─ [  0.45%] pgbuf_unfix
│   │   │       │   │   ├─ [  0.26%] pgbuf_unlatch_bcb_upon_unfix
│   │   │       │   │   │   ├─ [  0.18%] pgbuf_wakeup_reader_writer
│   │   │       │   │   │   └─ [  0.31%] __pthread_mutex_unlock_usercnt  ↑
│   │   │       │   │   ├─ [  0.13%] __pthread_cond_signal
│   │   │       │   │   ├─ [  0.46%] __GI___pthread_mutex_lock  ↑
│   │   │       │   │   ├─ [  0.04%] pgbuf_unlatch_thrd_holder
│   │   │       │   │   └─ [  0.03%] pgbuf_lockfree_unfix_ro
│   │   │       │   └─ [  0.03%] btree_get_node_header
│   │   │       │       ├─ [  0.12%] spage_get_record  ↑
│   │   │       │       └─ [  0.82%] spage_get_record_data  ↑
│   │   │       └─ [  0.58%] btree_search_key_and_apply_functions
│   │   │           ├─ [  0.45%] pgbuf_unfix  ↑
│   │   │           └─ [  0.28%] btree_fix_root_for_delete
│   │   │               ├─ [  1.04%] pgbuf_fix_release  ↑
│   │   │               └─ [  0.04%] btree_fix_root_with_info
│   │   ├─ [  0.10%] logpb_fetch_page
│   │   │   └─ [  0.10%] logpb_copy_page
│   │   │       └─ [  1.20%] __memmove_evex_unaligned_erms
│   │   ├─ [  0.09%] __GI___qsort_r
│   │   │   └─ [  0.09%] msort_with_tmp.part.0
│   │   │       └─ [  1.20%] __memmove_evex_unaligned_erms
│   │   ├─ [  0.05%] vacuum_process_log_record
│   │   └─ [  0.04%] vacuum_fetch_log_page
│   │       └─ [  1.20%] __memmove_evex_unaligned_erms
│   ├─ [  1.70%] vacuum_heap_page   ◆덩어리#2 (이 스레드의 독립 호출 조각 — 상위는 truncation 으로 끊김)
│   │   ├─ [  0.86%] vacuum_heap_prepare_record
│   │   │   └─ [  0.82%] spage_get_record_data  ↑
│   │   ├─ [  0.39%] spage_update
│   │   │   ├─ [  0.29%] spage_update_record_in_place
│   │   │   │   └─ [  1.20%] __memmove_evex_unaligned_erms
│   │   │   └─ [  0.08%] pgbuf_set_dirty
│   │   │       └─ [  0.10%] pgbuf_set_dirty_buffer_ptr
│   │   │           └─ [  0.10%] pgbuf_find_thrd_holder
│   │   ├─ [  0.29%] vacuum_heap_page_log_and_reset
│   │   │   ├─ [  0.26%] heap_stats_update
│   │   │   │   └─ [  0.26%] heap_stats_add_bestspace
│   │   │   │       ├─ [  0.10%] mht_put_internal
│   │   │   │       │   └─ [  0.05%] hl_fixed_alloc
│   │   │   │       ├─ [  0.46%] __GI___pthread_mutex_lock  ↑
│   │   │   │       ├─ [  0.31%] __pthread_mutex_unlock_usercnt  ↑
│   │   │   │       └─ [  0.36%] cub_alloc
│   │   │   │           └─ [  0.37%] __GI___libc_malloc
│   │   │   │               └─ [  0.29%] _int_malloc
│   │   │   │                   └─ [  0.21%] sysmalloc
│   │   │   │                       └─ [  0.11%] __GI___mprotect
│   │   │   └─ [  0.45%] pgbuf_unfix  ↑
│   │   └─ [  1.04%] pgbuf_fix_release  ↑
│   ├─ [  1.04%] btree_key_remove_insert_mvccid   ◆덩어리#3 (이 스레드의 독립 호출 조각 — 상위는 truncation 으로 끊김)
│   │   ├─ [  1.04%] log_append_redo_data
│   │   │   └─ [  1.03%] log_append_redo_crumbs
│   │   │       ├─ [  0.54%] prior_lsa_next_record_internal
│   │   │       │   ├─ [  0.46%] __GI___pthread_mutex_lock  ↑
│   │   │       │   └─ [  0.31%] __pthread_mutex_unlock_usercnt  ↑
│   │   │       ├─ [  0.37%] prior_lsa_alloc_and_copy_crumbs
│   │   │       │   ├─ [  0.36%] cub_alloc  ↑
│   │   │       │   └─ [  0.16%] prior_lsa_gen_undoredo_record_from_crumbs
│   │   │       │       ├─ [  0.08%] prior_lsa_copy_redo_crumbs_to_node
│   │   │       │       │   └─ [  0.36%] cub_alloc  ↑
│   │   │       │       └─ [  0.36%] cub_alloc  ↑
│   │   │       ├─ [  0.04%] pgbuf_set_lsa
│   │   │       │   └─ [  0.10%] pgbuf_set_dirty_buffer_ptr  ↑
│   │   │       ├─ [  0.03%] log_does_allow_replication
│   │   │       └─ [  0.05%] LOG_FIND_TDES
│   │   │           └─ [  0.04%] logtb_get_system_tdes
│   │   │               └─ [  0.03%] thread_get_thread_entry_info
│   │   ├─ [  0.39%] spage_update  ↑
│   │   ├─ [  0.03%] btree_find_oid_and_its_page
│   │   └─ [  0.08%] pgbuf_set_dirty  ↑
│   ├─ [  0.17%] vacuum_log_vacuum_heap_page   ◆덩어리#4 (이 스레드의 독립 호출 조각 — 상위는 truncation 으로 끊김)
│   │   └─ [  1.04%] log_append_redo_data  ↑
├─ [  3.82%] «dwb-flush-block»  (5618 smp)
│   ├─ [  3.76%] __GI___clone
│   │   └─ [  3.76%] start_thread
│   │       └─ [  3.76%] execute_native_thread_routine
│   │           └─ [  3.76%] cubthread::daemon::loop_with_context
│   │               ├─ [  3.51%] cubthread::looper::put_to_sleep
│   │               │   ├─ [  3.35%] cubthread::waiter::wait_for
│   │               │   │   ├─ [  2.81%] __pthread_cond_timedwait
│   │               │   │   │   ├─ [  0.03%] __condvar_cancel_waiting
│   │               │   │   │   └─ [  0.25%] __pthread_mutex_unlock_usercnt
│   │               │   │   │       └─ [  0.24%] __lll_unlock_wake
│   │               │   │   ├─ [  0.25%] __pthread_mutex_unlock_usercnt  ↑
│   │               │   │   ├─ [  0.24%] std::chrono::_V2::system_clock::now
│   │               │   │   │   └─ [  0.20%] __clock_gettime_2
│   │               │   │   └─ [  0.03%] __GI___pthread_mutex_lock
│   │               │   └─ [  0.24%] std::chrono::_V2::system_clock::now  ↑
│   │               ├─ [  0.07%] dwb_flush_block_daemon_task::execute
│   │               └─ [  0.04%] cubthread::daemon::register_stat_pause
│   │                   └─ [  0.24%] std::chrono::_V2::system_clock::now  ↑
├─ [  3.72%] «log-flush»  (5483 smp)
│   ├─ [  2.72%] __GI___clone   ◆덩어리#1 (이 스레드의 독립 호출 조각 — 상위는 truncation 으로 끊김)
│   │   └─ [  2.72%] start_thread
│   │       └─ [  2.72%] execute_native_thread_routine
│   │           └─ [  2.72%] cubthread::daemon::loop_with_context
│   │               ├─ [  2.66%] log_flush_execute
│   │               │   └─ [  2.65%] logpb_flush_pages_direct
│   │               │       ├─ [  2.47%] logpb_prior_lsa_append_all_list
│   │               │       │   ├─ [  2.32%] logpb_append_prior_lsa_list
│   │               │       │   │   ├─ [  1.10%] logpb_append_next_record
│   │               │       │   │   │   ├─ [  0.22%] logpb_end_append
│   │               │       │   │   │   │   ├─ [  0.23%] LSA_EQ
│   │               │       │   │   │   │   ├─ [  0.30%] logpb_set_dirty
│   │               │       │   │   │   │   │   └─ [  0.22%] logpb_get_log_buffer
│   │               │       │   │   │   │   └─ [  0.15%] logpb_next_append_page
│   │               │       │   │   │   │       └─ [  0.14%] logpb_locate_page
│   │               │       │   │   │   │           └─ [  0.14%] __memset_evex_unaligned_erms
│   │               │       │   │   │   ├─ [  0.15%] logpb_next_append_page  ↑
│   │               │       │   │   │   ├─ [  0.23%] LSA_EQ
│   │               │       │   │   │   └─ [  0.77%] logpb_append_data
│   │               │       │   │   │       ├─ [  0.30%] __memmove_evex_unaligned_erms
│   │               │       │   │   │       ├─ [  0.30%] logpb_set_dirty  ↑
│   │               │       │   │   │       ├─ [  0.11%] LOG_APPEND_PTR
│   │               │       │   │   │       └─ [  0.15%] logpb_next_append_page  ↑
│   │               │       │   │   └─ [  0.91%] cub_free
│   │               │       │   │       ├─ [  0.81%] _int_free
│   │               │       │   │       │   └─ [  0.29%] malloc_consolidate
│   │               │       │   │       │       └─ [  0.10%] unlink_chunk.isra.2
│   │               │       │   │       └─ [  0.11%] __GI___libc_free
│   │               │       │   ├─ [  0.77%] logpb_append_data  ↑
│   │               │       │   ├─ [  0.23%] logpb_start_append
│   │               │       │   │   ├─ [  0.23%] LSA_EQ
│   │               │       │   │   └─ [  0.30%] logpb_set_dirty  ↑
│   │               │       │   └─ [  0.15%] logpb_next_append_page  ↑
│   │               │       ├─ [  0.16%] logpb_flush_all_append_pages
│   │               │       │   └─ [  0.27%] fileio_synchronize
│   │               │       │       └─ [  0.27%] fdatasync
│   │               │       └─ [  0.81%] _int_free  ↑
│   │               └─ [  0.06%] cubthread::looper::put_to_sleep
│   │                   └─ [  0.06%] cubthread::waiter::wait_for
│   │                       └─ [  0.05%] __pthread_cond_timedwait
│   ├─ [  0.54%] logpb_write_toflush_pages_to_archive   ◆덩어리#2 (이 스레드의 독립 호출 조각 — 상위는 truncation 으로 끊김)
│   │   ├─ [  0.79%] fileio_write
│   │   │   └─ [  0.78%] __libc_pwrite64
│   │   └─ [  0.27%] fileio_synchronize  ↑
│   ├─ [  0.36%] logpb_writev_append_pages   ◆덩어리#3 (이 스레드의 독립 호출 조각 — 상위는 truncation 으로 끊김)
│   │   ├─ [  0.79%] fileio_write  ↑
│   │   └─ [  0.05%] logpb_set_page_checksum
│   │       └─ [  0.04%] crypt_crc32
│   ├─ [  0.07%] logpb_write_page_to_disk   ◆덩어리#4 (이 스레드의 독립 호출 조각 — 상위는 truncation 으로 끊김)
│   │   └─ [  0.79%] fileio_write  ↑
├─ [  1.69%] «coordinator»  (2488 smp)
│   ├─ [  1.64%] __GI___clone
│   │   └─ [  1.64%] start_thread
│   │       └─ [  1.64%] execute_native_thread_routine
│   │           └─ [  1.64%] cubconn::connection::coordinator::attach
│   │               ├─ [  1.64%] cubconn::connection::coordinator::run
│   │               │   ├─ [  1.11%] cubsocket::epoll::wait
│   │               │   │   └─ [  1.11%] epoll_wait
│   │               │   ├─ [  0.25%] cubconn::connection::coordinator::handle_message_queue
│   │               │   │   └─ [  0.20%] tbb::detail::d2::internal_try_pop_impl<tbb::detail::d2::concurrent_queue_rep<cubconn::connection::coordinator::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::coordinator::message> >, tbb::detail::d1::cache_aligned_allocator<tbb::detail::d2::concurrent_queue_rep<cubconn::connection::coordinator::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::coordinator::message> > > >
│   │               │   │       └─ [  0.05%] _int_free
│   │               │   ├─ [  0.21%] cubconn::connection::coordinator::eventfd_clear
│   │               │   │   └─ [  0.20%] __libc_read
│   │               │   └─ [  0.04%] cubconn::connection::coordinator::get_monotonic_ns
│   │               └─ [  1.11%] cubsocket::epoll::wait  ↑
├─ [  0.85%] «vacuum-master»  (1253 smp)
│   ├─ [  0.81%] __GI___clone
│   │   └─ [  0.80%] start_thread
│   │       └─ [  0.80%] execute_native_thread_routine
│   │           └─ [  0.80%] cubthread::daemon::loop_with_context
│   │               ├─ [  0.64%] cubthread::looper::put_to_sleep
│   │               │   └─ [  0.62%] cubthread::waiter::wait_for
│   │               │       ├─ [  0.53%] __pthread_cond_timedwait
│   │               │       ├─ [  0.04%] __pthread_mutex_unlock_usercnt
│   │               │       │   └─ [  0.04%] __lll_unlock_wake
│   │               │       └─ [  0.03%] std::chrono::_V2::system_clock::now
│   │               └─ [  0.14%] vacuum_master_task::execute
│   │                   ├─ [  0.04%] mvcctable::update_global_oldest_visible
│   │                   │   └─ [  0.03%] mvcctable::compute_oldest_visible_mvccid
│   │                   └─ [  0.04%] vacuum_job_cursor::force_data_update
│   │                       └─ [  0.03%] vacuum_data::update
├─ [  0.73%] «dwb-file-sync»  (1080 smp)
│   ├─ [  0.73%] __GI___clone
│   │   └─ [  0.73%] start_thread
│   │       └─ [  0.73%] execute_native_thread_routine
│   │           └─ [  0.73%] cubthread::daemon::loop_with_context
│   │               └─ [  0.68%] cubthread::looper::put_to_sleep
│   │                   ├─ [  0.66%] cubthread::waiter::wait_for
│   │                   │   ├─ [  0.57%] __pthread_cond_timedwait
│   │                   │   ├─ [  0.03%] __pthread_mutex_unlock_usercnt
│   │                   │   │   └─ [  0.03%] __lll_unlock_wake
│   │                   │   └─ [  0.03%] std::chrono::_V2::system_clock::now
│   │                   └─ [  0.03%] std::chrono::_V2::system_clock::now
├─ [  0.27%] «pgbuf-flush-con»  (399 smp)
│   ├─ [  0.27%] __GI___clone
│   │   └─ [  0.27%] start_thread
│   │       └─ [  0.27%] execute_native_thread_routine
│   │           └─ [  0.27%] cubthread::daemon::loop_with_context
│   │               └─ [  0.25%] cubthread::looper::put_to_sleep
│   │                   └─ [  0.24%] cubthread::waiter::wait_for
│   │                       └─ [  0.21%] __pthread_cond_timedwait
├─ [  0.25%] «deadlock-detect»  (370 smp)
│   ├─ [  0.25%] __GI___clone
│   │   └─ [  0.25%] start_thread
│   │       └─ [  0.25%] execute_native_thread_routine
│   │           └─ [  0.25%] cubthread::daemon::loop_with_context
│   │               └─ [  0.24%] cubthread::looper::put_to_sleep
│   │                   └─ [  0.23%] cubthread::waiter::wait_for
│   │                       └─ [  0.21%] __pthread_cond_timedwait
├─ [  0.22%] «pgbuf-maintain»  (324 smp)
│   ├─ [  0.22%] __GI___clone
│   │   └─ [  0.22%] start_thread
│   │       └─ [  0.22%] execute_native_thread_routine
│   │           └─ [  0.22%] cubthread::daemon::loop_with_context
│   │               └─ [  0.19%] cubthread::looper::put_to_sleep
│   │                   └─ [  0.19%] cubthread::waiter::wait_for
│   │                       └─ [  0.17%] __pthread_cond_timedwait
├─ [  0.11%] «log-clock»  (161 smp)
│   ├─ [  0.11%] __GI___clone
│   │   └─ [  0.11%] start_thread
│   │       └─ [  0.11%] execute_native_thread_routine
│   │           └─ [  0.11%] cubthread::daemon::loop_with_context
│   │               └─ [  0.10%] cubthread::looper::put_to_sleep
│   │                   └─ [  0.10%] cubthread::waiter::wait_for
│   │                       └─ [  0.10%] __pthread_cond_timedwait
├─ [  0.08%] «ha-delay-check»  (119 smp)
│   ├─ [  0.08%] __GI___clone
│   │   └─ [  0.08%] start_thread
│   │       └─ [  0.08%] execute_native_thread_routine
│   │           └─ [  0.08%] cubthread::daemon::loop_with_context
│   │               └─ [  0.04%] cubthread::looper::put_to_sleep
│   │                   └─ [  0.04%] cubthread::waiter::wait_for
│   │                       └─ [  0.04%] __pthread_cond_timedwait
└─ [  0.12%] «기타 thread 4종»  (176 smp, 각 <0.05%)
         0.04%  pl-monitor  (61)
         0.04%  cub_server  (60)
         0.03%  pgbuf-page-flus  (46)
         0.01%  session-control  (9)
```
