# INSERT 복제 적용 콜체인 — 서버 스레드부터 전체

슬레이브 `cub_server` 의 **transaction 워커 스레드**가 master `applylogdb` 의 복제 INSERT 요청을
받아 적용하기까지 **서버 스레드 진입 → RPC 핸들러 → 적용 → write** 전 구간.
**구조 = 소스 코드(authoritative)**, **% = on-CPU perf inclusive 비중**.
캡처: `20260601-203144-cubserver-oncpu-config-parallel-poc-insert` (전체 147,236 sample).

> ⚠ **dwarf(8KB) 스택 truncation 주의**: 깊은 write 프레임에서 스냅샷이 소진돼 상위 프레임이 잘린다.
> 그래서 ① 상위 스레드/RPC 노드 % 가 하위보다 작게(undercount) 찍히고, ② `slocator_repl_force` 서브트리(§2)와
> `locator_insert_force` write 트리(§3)가 **서로 다른 sample 집합**으로 갈린다(연결은 소스로 확정).

> **분모**: §1·§2 = % of total(147,236) 또는 % of slocator. §3 = % of locator_insert_force(=29.78% of total).
> 구간별 분모가 다르니 직접 비교 금지(각 블록 헤더에 표기).

소스: `cubrid/src/transaction/locator_sr.c`, 서버 stub `cubrid/src/communication/network_interface_sr.cpp`,
스레드 디스패치 `cubrid/src/thread/*`, 요청 demux `cubrid/src/communication/network_sr.c`.

---

## §1. 서버 스레드 진입 (transaction worker, 소스 구조 + % of total)

```
__GI___clone                                              [24.36%]   (pthread 생성)
└─ start_thread                                           [24.35%]
   └─ execute_native_thread_routine                       [24.35%]
      └─ cubthread::worker_pool::core::worker::run        [13.70%]   워커 루프
         └─ cubthread::worker_pool::core::worker::execute_current_task  [10.92%]
            └─ css_server_task::execute                   [10.64%]   요청 디스패치
               └─ (css_internal_request_handler)          [ 0.91%]
                  └─ net_server_request                   [ 9.43%]   요청 demux (function table)
                     └─ ❰NET_SERVER_LC_REPL_FORCE❱ → slocator_repl_force   [ 6.41%⚠]  ▼ §2
```
※ `transaction` 워커는 복제 force 외 다른 요청도 처리하지만, 이 워크로드에선 거의 전량이 `slocator_repl_force` 경로.
(전체 thread 별 분포는 `analysis/calltree_full.txt` / `inclusive_total.txt` 참조)

---

## §2. slocator_repl_force 서브트리 — 모든 서버 함수 (측정, slocator_repl_force = 100%)

RPC 핸들러 본체. **`xlocator_repl_force`(적용) + topop 경계 + classrepr + 응답 송수신(css/TBB)** 등
서버 측 함수가 전부 들어있다. 아래는 `analysis/calltree_slocator_repl_force.txt` 전문
(% = of slocator_repl_force, 노드컷 0.3%, MIN_EDGE 20).

> INSERT 분기는 `xlocator_repl_force` 의 `switch(obj->operation)` → `LC_FLUSH_INSERT` → `locator_insert_force`
> (locator_sr.c:7029). 단 그 호출은 truncation 으로 이 서브트리에선 0.3% 컷 위로 거의 안 보이고(같은 sample 에
> 안 잡힘), **실제 write 본체는 §3**. 즉 §2 의 `xlocator_repl_force` ──[소스: switch LC_FLUSH_INSERT]──▶ §3 `locator_insert_force`.

```
# slocator_repl_force 콜체인 (ROOT 포함 sample 만, ROOT=100%)
# root_samples = 9442  (total = 147236, 6.41% of total)
# 노드컷 0.3% of root, MIN_EDGE 20

[100.00%] slocator_repl_force
    ├─ [ 59.04%] xlocator_repl_force
    │   ├─ [ 20.21%] xtran_server_end_topop
    │   │   ├─ [  9.10%] log_sysop_attach_to_outer
    │   │   │   ├─ [  4.76%] log_tdes::unlock_topop
    │   │   │   │   ├─ [  3.99%] cubpl::get_session
    │   │   │   │   │   ├─ [  2.67%] session_get_pl_session
    │   │   │   │   │   │   ├─ [  1.71%] cubpl::session::is_sp_running
    │   │   │   │   │   │   │   ├─ [  4.47%] __GI___pthread_mutex_lock
    │   │   │   │   │   │   │   │   └─ [  0.44%] __lll_lock_wait
    │   │   │   │   │   │   │   └─ [  5.45%] __pthread_mutex_unlock_usercnt
    │   │   │   │   │   │   │       └─ [  0.37%] __lll_unlock_wake
    │   │   │   │   │   │   └─ [  0.42%] session_get_session_state
    │   │   │   │   │   └─ [  1.79%] thread_get_thread_entry_info
    │   │   │   │   │       ├─ [  0.93%] cubthread::get_entry
    │   │   │   │   │       │   └─ [  1.55%] __tls_get_addr
    │   │   │   │   │       └─ [  0.55%] cubthread::get_entry@plt
    │   │   │   │   └─ [  1.80%] cubpl::session::is_thread_involved
    │   │   │   │       ├─ [  5.45%] __pthread_mutex_unlock_usercnt
    │   │   │   │       │   └─ [  0.37%] __lll_unlock_wake
    │   │   │   │       └─ [  4.47%] __GI___pthread_mutex_lock
    │   │   │   │           └─ [  0.44%] __lll_lock_wait
    │   │   │   ├─ [  1.78%] log_sysop_end_final
    │   │   │   │   └─ [  0.52%] log_tdes::on_sysop_end
    │   │   │   │       └─ [  0.32%] log_tdes::is_system_worker_transaction@plt
    │   │   │   ├─ [  2.19%] rmutex_unlock
    │   │   │   │   ├─ [  5.45%] __pthread_mutex_unlock_usercnt
    │   │   │   │   │   └─ [  0.37%] __lll_unlock_wake
    │   │   │   │   ├─ [  0.52%] cubthread::is_single_thread@plt
    │   │   │   │   └─ [  1.79%] thread_get_thread_entry_info
    │   │   │   │       ├─ [  0.93%] cubthread::get_entry
    │   │   │   │       │   └─ [  1.55%] __tls_get_addr
    │   │   │   │       └─ [  0.55%] cubthread::get_entry@plt
    │   │   │   ├─ [  0.58%] log_sysop_end_begin
    │   │   │   │   └─ [  0.56%] log_sysop_get_tran_index_and_tdes
    │   │   │   │       └─ [  5.26%] LOG_FIND_TDES
    │   │   │   ├─ [  0.37%] LSA_ISNULL
    │   │   │   └─ [  0.35%] rmutex_unlock@plt
    │   │   ├─ [  4.19%] cuberr::context::pop_error_stack_and_destroy
    │   │   │   ├─ [  2.15%] cuberr::context::pop_error_stack
    │   │   │   │   ├─ [  1.26%] cuberr::er_message::swap
    │   │   │   │   └─ [  0.67%] operator delete
    │   │   │   │       └─ [  0.80%] cub_free
    │   │   │   │           ├─ [  0.33%] __GI___libc_free
    │   │   │   │           └─ [  0.74%] _int_free
    │   │   │   ├─ [  0.98%] cuberr::er_message::~er_message
    │   │   │   └─ [  1.48%] cuberr::er_message::er_message
    │   │   ├─ [  2.77%] cuberr::context::push_error_stack
    │   │   │   ├─ [  3.80%] operator new
    │   │   │   │   ├─ [  3.78%] __GI___libc_malloc
    │   │   │   │   │   └─ [  7.56%] _int_malloc
    │   │   │   │   │       └─ [  5.55%] sysmalloc
    │   │   │   │   │           └─ [  4.38%] __GI___mprotect
    │   │   │   │   ├─ [  1.35%] cub_alloc
    │   │   │   │   │   └─ [  3.78%] __GI___libc_malloc
    │   │   │   │   │       └─ [  7.56%] _int_malloc
    │   │   │   │   │           └─ [  5.55%] sysmalloc
    │   │   │   │   │               └─ [  4.38%] __GI___mprotect
    │   │   │   │   └─ [  0.54%] malloc@plt
    │   │   │   └─ [  1.48%] cuberr::er_message::er_message
    │   │   ├─ [  1.76%] LOG_FIND_CURRENT_TDES
    │   │   │   └─ [  5.26%] LOG_FIND_TDES
    │   │   └─ [  1.24%] er_stack_push
    │   │       └─ [  1.51%] cuberr::context::get_thread_local_context
    │   │           └─ [  1.55%] __tls_get_addr
    │   ├─ [  9.84%] xtran_server_start_topop
    │   │   ├─ [  7.52%] log_sysop_start
    │   │   │   ├─ [  2.46%] log_tdes::lock_topop
    │   │   │   │   ├─ [  3.99%] cubpl::get_session
    │   │   │   │   │   ├─ [  2.67%] session_get_pl_session
    │   │   │   │   │   │   ├─ [  1.71%] cubpl::session::is_sp_running
    │   │   │   │   │   │   │   ├─ [  4.47%] __GI___pthread_mutex_lock
    │   │   │   │   │   │   │   │   └─ [  0.44%] __lll_lock_wait
    │   │   │   │   │   │   │   └─ [  5.45%] __pthread_mutex_unlock_usercnt
    │   │   │   │   │   │   │       └─ [  0.37%] __lll_unlock_wake
    │   │   │   │   │   │   └─ [  0.42%] session_get_session_state
    │   │   │   │   │   └─ [  1.79%] thread_get_thread_entry_info
    │   │   │   │   │       ├─ [  0.93%] cubthread::get_entry
    │   │   │   │   │       │   └─ [  1.55%] __tls_get_addr
    │   │   │   │   │       └─ [  0.55%] cubthread::get_entry@plt
    │   │   │   │   └─ [  1.80%] cubpl::session::is_thread_involved
    │   │   │   │       ├─ [  5.45%] __pthread_mutex_unlock_usercnt
    │   │   │   │       │   └─ [  0.37%] __lll_unlock_wake
    │   │   │   │       └─ [  4.47%] __GI___pthread_mutex_lock
    │   │   │   │           └─ [  0.44%] __lll_lock_wait
    │   │   │   ├─ [  6.27%] rmutex_lock
    │   │   │   │   ├─ [  1.78%] tsc_getticks
    │   │   │   │   │   └─ [  1.17%] __clock_gettime_2
    │   │   │   │   ├─ [  4.47%] __GI___pthread_mutex_lock
    │   │   │   │   │   └─ [  0.44%] __lll_lock_wait
    │   │   │   │   ├─ [  1.79%] thread_get_thread_entry_info
    │   │   │   │   │   ├─ [  0.93%] cubthread::get_entry
    │   │   │   │   │   │   └─ [  1.55%] __tls_get_addr
    │   │   │   │   │   └─ [  0.55%] cubthread::get_entry@plt
    │   │   │   │   ├─ [  0.31%] cubthread::entry::get_id@plt
    │   │   │   │   └─ [  0.33%] cubthread::entry::get_id
    │   │   │   ├─ [  5.26%] LOG_FIND_TDES
    │   │   │   ├─ [  0.47%] log_tdes::on_sysop_start
    │   │   │   │   └─ [  0.46%] log_tdes::is_system_worker_transaction
    │   │   │   └─ [  0.41%] rmutex_lock@plt
    │   │   ├─ [  1.23%] log_get_parent_lsa_system_op
    │   │   │   └─ [  5.26%] LOG_FIND_TDES
    │   │   └─ [  0.47%] locator_savepoint_transient_class_name_entries
    │   ├─ [  9.46%] heap_get_class_repr_id
    │   │   ├─ [  4.89%] heap_classrepr_get
    │   │   │   ├─ [  5.45%] __pthread_mutex_unlock_usercnt
    │   │   │   │   └─ [  0.37%] __lll_unlock_wake
    │   │   │   ├─ [  4.47%] __GI___pthread_mutex_lock
    │   │   │   │   └─ [  0.44%] __lll_lock_wait
    │   │   │   └─ [  0.68%] __GI___pthread_mutex_trylock
    │   │   └─ [  4.25%] heap_classrepr_free
    │   │       ├─ [  5.45%] __pthread_mutex_unlock_usercnt
    │   │       │   └─ [  0.37%] __lll_unlock_wake
    │   │       └─ [  4.47%] __GI___pthread_mutex_lock
    │   │           └─ [  0.44%] __lll_lock_wait
    │   ├─ [  6.37%] heap_get_class_info
    │   │   └─ [  6.33%] heap_hfid_cache_get
    │   │       └─ [  3.98%] lf_hash_insert_internal
    │   │           ├─ [  1.69%] lf_list_insert_internal
    │   │           │   └─ [  0.41%] heap_hfid_table_entry_key_compare
    │   │           ├─ [  0.67%] lf_tran_start
    │   │           └─ [  0.48%] heap_hfid_table_entry_key_hash
    │   ├─ [  4.53%] heap_scancache_start_modify
    │   │   ├─ [  3.19%] file_get_type
    │   │   │   ├─ [  1.92%] pgbuf_fix_release
    │   │   │   │   └─ [  0.32%] pgbuf_search_hash_chain
    │   │   │   └─ [  1.17%] pgbuf_unfix
    │   │   │       └─ [  0.85%] pgbuf_unlatch_bcb_upon_unfix
    │   │   ├─ [  0.82%] heap_scancache_reset_modify
    │   │   │   ├─ [  6.37%] heap_get_class_info
    │   │   │   │   └─ [  6.33%] heap_hfid_cache_get
    │   │   │   │       └─ [  3.98%] lf_hash_insert_internal
    │   │   │   │           ├─ [  1.69%] lf_list_insert_internal
    │   │   │   │           │   └─ [  0.41%] heap_hfid_table_entry_key_compare
    │   │   │   │           ├─ [  0.67%] lf_tran_start
    │   │   │   │           └─ [  0.48%] heap_hfid_table_entry_key_hash
    │   │   │   └─ [  0.42%] mvcc_is_mvcc_disabled_class
    │   │   └─ [  0.37%] heap_scancache_start_internal
    │   ├─ [  2.23%] or_unpack_mem_value
    │   │   ├─ [  1.10%] or_get_domain
    │   │   │   └─ [  0.53%] unpack_domain
    │   │   └─ [  0.32%] mr_initval_int
    │   ├─ [  0.90%] er_clear
    │   │   ├─ [  0.42%] er_is_initialized@plt
    │   │   └─ [  1.51%] cuberr::context::get_thread_local_context
    │   │       └─ [  1.55%] __tls_get_addr
    │   ├─ [  0.35%] cuberr::context::clear_current_error_level
    │   ├─ [  0.71%] perfmon_inc_stat
    │   │   └─ [  0.71%] perfmon_add_stat
    │   │       └─ [  0.43%] perfmon_is_perf_tracking
    │   └─ [  0.31%] heap_get_class_info@plt
    ├─ [ 17.92%] css_send_reply_and_2_data_to_client
    │   ├─ [ 12.11%] css_enqueue_and_notify
    │   │   ├─ [ 11.15%] cubconn::connection::worker::enqueue_and_notify
    │   │   │   ├─ [  7.35%] cubconn::connection::worker::notify
    │   │   │   │   └─ [  7.27%] __libc_write
    │   │   │   └─ [  9.73%] cubconn::connection::worker::enqueue
    │   │   │       └─ [  7.10%] tbb::detail::d2::micro_queue<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >::prepare_page(unsigned long, tbb::detail::d2::concurrent_queue_rep<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >&, tbb::detail::d1::cache_aligned_allocator<tbb::detail::d2::micro_queue<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >::padded_page>, tbb::detail::d2::micro_queue<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >::padded_page*&)::{lambda()#1}::operator()
    │   │   │           └─ [  7.07%] tbb::detail::r1::cache_aligned_allocate
    │   │   │               └─ [  6.91%] _mid_memalign
    │   │   │                   └─ [  6.38%] _int_memalign
    │   │   │                       ├─ [  7.56%] _int_malloc
    │   │   │                       │   └─ [  5.55%] sysmalloc
    │   │   │                       │       └─ [  4.38%] __GI___mprotect
    │   │   │                       └─ [  0.74%] _int_free
    │   │   └─ [  6.27%] rmutex_lock
    │   │       ├─ [  1.78%] tsc_getticks
    │   │       │   └─ [  1.17%] __clock_gettime_2
    │   │       ├─ [  4.47%] __GI___pthread_mutex_lock
    │   │       │   └─ [  0.44%] __lll_lock_wait
    │   │       ├─ [  1.79%] thread_get_thread_entry_info
    │   │       │   ├─ [  0.93%] cubthread::get_entry
    │   │       │   │   └─ [  1.55%] __tls_get_addr
    │   │       │   └─ [  0.55%] cubthread::get_entry@plt
    │   │       ├─ [  0.31%] cubthread::entry::get_id@plt
    │   │       └─ [  0.33%] cubthread::entry::get_id
    │   ├─ [  6.27%] rmutex_lock
    │   │   ├─ [  1.78%] tsc_getticks
    │   │   │   └─ [  1.17%] __clock_gettime_2
    │   │   ├─ [  4.47%] __GI___pthread_mutex_lock
    │   │   │   └─ [  0.44%] __lll_lock_wait
    │   │   ├─ [  1.79%] thread_get_thread_entry_info
    │   │   │   ├─ [  0.93%] cubthread::get_entry
    │   │   │   │   └─ [  1.55%] __tls_get_addr
    │   │   │   └─ [  0.55%] cubthread::get_entry@plt
    │   │   ├─ [  0.31%] cubthread::entry::get_id@plt
    │   │   └─ [  0.33%] cubthread::entry::get_id
    │   ├─ [  3.80%] operator new
    │   │   ├─ [  3.78%] __GI___libc_malloc
    │   │   │   └─ [  7.56%] _int_malloc
    │   │   │       └─ [  5.55%] sysmalloc
    │   │   │           └─ [  4.38%] __GI___mprotect
    │   │   ├─ [  1.35%] cub_alloc
    │   │   │   └─ [  3.78%] __GI___libc_malloc
    │   │   │       └─ [  7.56%] _int_malloc
    │   │   │           └─ [  5.55%] sysmalloc
    │   │   │               └─ [  4.38%] __GI___mprotect
    │   │   └─ [  0.54%] malloc@plt
    │   ├─ [  0.70%] std::vector<cubbase::span<std::byte>, std::allocator<cubbase::span<std::byte> > >::_M_realloc_insert<std::byte*&, unsigned long>
    │   │   └─ [  3.80%] operator new
    │   │       ├─ [  3.78%] __GI___libc_malloc
    │   │       │   └─ [  7.56%] _int_malloc
    │   │       │       └─ [  5.55%] sysmalloc
    │   │       │           └─ [  4.38%] __GI___mprotect
    │   │       ├─ [  1.35%] cub_alloc
    │   │       │   └─ [  3.78%] __GI___libc_malloc
    │   │       │       └─ [  7.56%] _int_malloc
    │   │       │           └─ [  5.55%] sysmalloc
    │   │       │               └─ [  4.38%] __GI___mprotect
    │   │       └─ [  0.54%] malloc@plt
    │   ├─ [  0.47%] operator new[]
    │   │   └─ [  1.35%] cub_alloc
    │   │       └─ [  3.78%] __GI___libc_malloc
    │   │           └─ [  7.56%] _int_malloc
    │   │               └─ [  5.55%] sysmalloc
    │   │                   └─ [  4.38%] __GI___mprotect
    │   └─ [  2.19%] rmutex_unlock
    │       ├─ [  5.45%] __pthread_mutex_unlock_usercnt
    │       │   └─ [  0.37%] __lll_unlock_wake
    │       ├─ [  0.52%] cubthread::is_single_thread@plt
    │       └─ [  1.79%] thread_get_thread_entry_info
    │           ├─ [  0.93%] cubthread::get_entry
    │           │   └─ [  1.55%] __tls_get_addr
    │           └─ [  0.55%] cubthread::get_entry@plt
    ├─ [  8.29%] css_request_release_packet
    │   ├─ [  9.73%] cubconn::connection::worker::enqueue
    │   │   └─ [  7.10%] tbb::detail::d2::micro_queue<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >::prepare_page(unsigned long, tbb::detail::d2::concurrent_queue_rep<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >&, tbb::detail::d1::cache_aligned_allocator<tbb::detail::d2::micro_queue<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >::padded_page>, tbb::detail::d2::micro_queue<cubconn::connection::worker::message, tbb::detail::d1::cache_aligned_allocator<cubconn::connection::worker::message> >::padded_page*&)::{lambda()#1}::operator()
    │   │       └─ [  7.07%] tbb::detail::r1::cache_aligned_allocate
    │   │           └─ [  6.91%] _mid_memalign
    │   │               └─ [  6.38%] _int_memalign
    │   │                   ├─ [  7.56%] _int_malloc
    │   │                   │   └─ [  5.55%] sysmalloc
    │   │                   │       └─ [  4.38%] __GI___mprotect
    │   │                   └─ [  0.74%] _int_free
    │   ├─ [  6.27%] rmutex_lock
    │   │   ├─ [  1.78%] tsc_getticks
    │   │   │   └─ [  1.17%] __clock_gettime_2
    │   │   ├─ [  4.47%] __GI___pthread_mutex_lock
    │   │   │   └─ [  0.44%] __lll_lock_wait
    │   │   ├─ [  1.79%] thread_get_thread_entry_info
    │   │   │   ├─ [  0.93%] cubthread::get_entry
    │   │   │   │   └─ [  1.55%] __tls_get_addr
    │   │   │   └─ [  0.55%] cubthread::get_entry@plt
    │   │   ├─ [  0.31%] cubthread::entry::get_id@plt
    │   │   └─ [  0.33%] cubthread::entry::get_id
    │   └─ [  0.49%] std::vector<cubbase::span<std::byte>, std::allocator<cubbase::span<std::byte> > >::_M_realloc_insert<std::byte*, int>
    │       └─ [  3.80%] operator new
    │           ├─ [  3.78%] __GI___libc_malloc
    │           │   └─ [  7.56%] _int_malloc
    │           │       └─ [  5.55%] sysmalloc
    │           │           └─ [  4.38%] __GI___mprotect
    │           ├─ [  1.35%] cub_alloc
    │           │   └─ [  3.78%] __GI___libc_malloc
    │           │       └─ [  7.56%] _int_malloc
    │           │           └─ [  5.55%] sysmalloc
    │           │               └─ [  4.38%] __GI___mprotect
    │           └─ [  0.54%] malloc@plt
    ├─ [  6.55%] __memmove_evex_unaligned_erms
    ├─ [  3.73%] css_receive_data_from_client_with_timeout
    │   ├─ [  3.00%] css_receive_data
    │   │   ├─ [  2.66%] css_return_queued_data_timeout
    │   │   │   ├─ [  6.27%] rmutex_lock
    │   │   │   │   ├─ [  1.78%] tsc_getticks
    │   │   │   │   │   └─ [  1.17%] __clock_gettime_2
    │   │   │   │   ├─ [  4.47%] __GI___pthread_mutex_lock
    │   │   │   │   │   └─ [  0.44%] __lll_lock_wait
    │   │   │   │   ├─ [  1.79%] thread_get_thread_entry_info
    │   │   │   │   │   ├─ [  0.93%] cubthread::get_entry
    │   │   │   │   │   │   └─ [  1.55%] __tls_get_addr
    │   │   │   │   │   └─ [  0.55%] cubthread::get_entry@plt
    │   │   │   │   ├─ [  0.31%] cubthread::entry::get_id@plt
    │   │   │   │   └─ [  0.33%] cubthread::entry::get_id
    │   │   │   └─ [  2.19%] rmutex_unlock
    │   │   │       ├─ [  5.45%] __pthread_mutex_unlock_usercnt
    │   │   │       │   └─ [  0.37%] __lll_unlock_wake
    │   │   │       ├─ [  0.52%] cubthread::is_single_thread@plt
    │   │   │       └─ [  1.79%] thread_get_thread_entry_info
    │   │   │           ├─ [  0.93%] cubthread::get_entry
    │   │   │           │   └─ [  1.55%] __tls_get_addr
    │   │   │           └─ [  0.55%] cubthread::get_entry@plt
    │   │   └─ [  1.13%] css_traverse_list
    │   │       └─ [  0.58%] css_find_queue_entry_by_key
    │   └─ [  0.66%] css_return_queued_error
    │       └─ [  6.27%] rmutex_lock
    │           ├─ [  1.78%] tsc_getticks
    │           │   └─ [  1.17%] __clock_gettime_2
    │           ├─ [  4.47%] __GI___pthread_mutex_lock
    │           │   └─ [  0.44%] __lll_lock_wait
    │           ├─ [  1.79%] thread_get_thread_entry_info
    │           │   ├─ [  0.93%] cubthread::get_entry
    │           │   │   └─ [  1.55%] __tls_get_addr
    │           │   └─ [  0.55%] cubthread::get_entry@plt
    │           ├─ [  0.31%] cubthread::entry::get_id@plt
    │           └─ [  0.33%] cubthread::entry::get_id
    ├─ [  1.28%] locator_unpack_copy_area_descriptor
    │   └─ [  0.48%] or_unpack_int
    ├─ [  0.59%] locator_recv_allocate_copyarea
    │   └─ [  0.57%] locator_allocate_copy_area_by_length
    └─ [  0.48%] or_unpack_int
```

---

## §3. write tree — `locator_insert_force` 이하 (측정, locator_insert_force = 100%)

switch leaf `locator_insert_force` 아래. perf 에서 안 잘려 **구조·% 정확**. 아래는 `analysis/calltree_root.txt` 전문
(% = of locator_insert_force, 노드컷 0.1%, MIN_EDGE 30).

```
# locator_insert_force 콜체인 (ROOT 포함 sample 만, ROOT = 100%)
# root_samples = 43840  (total_samples = 147236)
# 노드 컷 = 0.1% of root, MIN_EDGE = 30

[100.00%] locator_insert_force
    ├─ [ 86.15%] heap_insert_logical
    │   ├─ [ 34.38%] heap_get_insert_location_with_lock
    │   │   └─ [ 33.83%] heap_stats_find_best_page
    │   │       ├─ [ 23.13%] heap_vpid_alloc
    │   │       │   ├─ [ 18.15%] file_alloc
    │   │       │   │   ├─ [  5.84%] pgbuf_fix_release
    │   │       │   │   │   ├─ [  5.14%] pgbuf_claim_bcb_for_fix
    │   │       │   │   │   │   ├─ [  4.39%] fileio_init_lsa_of_page
    │   │       │   │   │   │   │   └─ [  4.46%] LSA_SET_NULL
    │   │       │   │   │   │   ├─ [  0.43%] pgbuf_allocate_bcb
    │   │       │   │   │   │   │   └─ [  0.34%] pgbuf_get_bcb_from_invalid_list
    │   │       │   │   │   │   └─ [  0.10%] pgbuf_lock_page
    │   │       │   │   │   └─ [  0.13%] pgbuf_search_hash_chain
    │   │       │   │   ├─ [  4.16%] file_perm_alloc
    │   │       │   │   │   ├─ [  2.01%] log_append_undoredo_data2
    │   │       │   │   │   │   └─ [ 27.75%] log_append_undoredo_crumbs
    │   │       │   │   │   │       ├─ [ 13.96%] prior_lsa_alloc_and_copy_crumbs
    │   │       │   │   │   │       │   ├─ [  9.86%] prior_lsa_gen_undoredo_record_from_crumbs
    │   │       │   │   │   │       │   │   ├─ [  4.42%] log_zip
    │   │       │   │   │   │       │   │   │   ├─ [  3.50%] LZ4_resetStream_fast
    │   │       │   │   │   │       │   │   │   │   └─ [  3.19%] __memset_evex_unaligned_erms
    │   │       │   │   │   │       │   │   │   └─ [  0.26%] __tls_get_addr
    │   │       │   │   │   │       │   │   ├─ [ 11.55%] cub_alloc
    │   │       │   │   │   │       │   │   │   └─ [ 14.87%] __GI___libc_malloc
    │   │       │   │   │   │       │   │   │       └─ [ 12.26%] _int_malloc
    │   │       │   │   │   │       │   │   │           ├─ [  9.37%] sysmalloc
    │   │       │   │   │   │       │   │   │           │   └─ [  8.25%] __GI___mprotect
    │   │       │   │   │   │       │   │   │           └─ [  0.30%] unlink_chunk.isra.2
    │   │       │   │   │   │       │   │   ├─ [  9.68%] __memmove_evex_unaligned_erms
    │   │       │   │   │   │       │   │   ├─ [  0.51%] prior_lsa_copy_redo_crumbs_to_node
    │   │       │   │   │   │       │   │   │   └─ [ 11.55%] cub_alloc
    │   │       │   │   │   │       │   │   │       └─ [ 14.87%] __GI___libc_malloc
    │   │       │   │   │   │       │   │   │           └─ [ 12.26%] _int_malloc
    │   │       │   │   │   │       │   │   │               ├─ [  9.37%] sysmalloc
    │   │       │   │   │   │       │   │   │               │   └─ [  8.25%] __GI___mprotect
    │   │       │   │   │   │       │   │   │               └─ [  0.30%] unlink_chunk.isra.2
    │   │       │   │   │   │       │   │   ├─ [  0.41%] prior_lsa_copy_undo_crumbs_to_node
    │   │       │   │   │   │       │   │   │   └─ [ 11.55%] cub_alloc
    │   │       │   │   │   │       │   │   │       └─ [ 14.87%] __GI___libc_malloc
    │   │       │   │   │   │       │   │   │           └─ [ 12.26%] _int_malloc
    │   │       │   │   │   │       │   │   │               ├─ [  9.37%] sysmalloc
    │   │       │   │   │   │       │   │   │               │   └─ [  8.25%] __GI___mprotect
    │   │       │   │   │   │       │   │   │               └─ [  0.30%] unlink_chunk.isra.2
    │   │       │   │   │   │       │   │   ├─ [  0.35%] log_diff
    │   │       │   │   │   │       │   │   ├─ [  0.30%] LOG_FIND_CURRENT_TDES
    │   │       │   │   │   │       │   │   │   └─ [  3.30%] LOG_FIND_TDES
    │   │       │   │   │   │       │   │   ├─ [  0.13%] log_zip@plt
    │   │       │   │   │   │       │   │   └─ [  0.12%] pgbuf_get_vpid_ptr
    │   │       │   │   │   │       │   ├─ [ 11.55%] cub_alloc
    │   │       │   │   │   │       │   │   └─ [ 14.87%] __GI___libc_malloc
    │   │       │   │   │   │       │   │       └─ [ 12.26%] _int_malloc
    │   │       │   │   │   │       │   │           ├─ [  9.37%] sysmalloc
    │   │       │   │   │   │       │   │           │   └─ [  8.25%] __GI___mprotect
    │   │       │   │   │   │       │   │           └─ [  0.30%] unlink_chunk.isra.2
    │   │       │   │   │   │       │   ├─ [  1.22%] prior_lsa_copy_redo_data_to_node
    │   │       │   │   │   │       │   │   ├─ [ 11.55%] cub_alloc
    │   │       │   │   │   │       │   │   │   └─ [ 14.87%] __GI___libc_malloc
    │   │       │   │   │   │       │   │   │       └─ [ 12.26%] _int_malloc
    │   │       │   │   │   │       │   │   │           ├─ [  9.37%] sysmalloc
    │   │       │   │   │   │       │   │   │           │   └─ [  8.25%] __GI___mprotect
    │   │       │   │   │   │       │   │   │           └─ [  0.30%] unlink_chunk.isra.2
    │   │       │   │   │   │       │   │   └─ [  9.68%] __memmove_evex_unaligned_erms
    │   │       │   │   │   │       │   ├─ [  4.42%] log_zip
    │   │       │   │   │   │       │   │   ├─ [  3.50%] LZ4_resetStream_fast
    │   │       │   │   │   │       │   │   │   └─ [  3.19%] __memset_evex_unaligned_erms
    │   │       │   │   │   │       │   │   └─ [  0.26%] __tls_get_addr
    │   │       │   │   │   │       │   └─ [  0.33%] prior_lsa_copy_undo_data_to_node
    │   │       │   │   │   │       │       └─ [ 11.55%] cub_alloc
    │   │       │   │   │   │       │           └─ [ 14.87%] __GI___libc_malloc
    │   │       │   │   │   │       │               └─ [ 12.26%] _int_malloc
    │   │       │   │   │   │       │                   ├─ [  9.37%] sysmalloc
    │   │       │   │   │   │       │                   │   └─ [  8.25%] __GI___mprotect
    │   │       │   │   │   │       │                   └─ [  0.30%] unlink_chunk.isra.2
    │   │       │   │   │   │       ├─ [ 15.04%] prior_lsa_next_record_internal
    │   │       │   │   │   │       │   ├─ [ 11.07%] __GI___pthread_mutex_lock
    │   │       │   │   │   │       │   │   └─ [  5.34%] __lll_lock_wait
    │   │       │   │   │   │       │   ├─ [  7.75%] __pthread_mutex_unlock_usercnt
    │   │       │   │   │   │       │   │   └─ [  4.29%] __lll_unlock_wake
    │   │       │   │   │   │       │   ├─ [  0.45%] prior_lsa_start_append
    │   │       │   │   │   │       │   │   └─ [  0.14%] log_tdes::is_system_worker_transaction
    │   │       │   │   │   │       │   ├─ [  0.37%] vacuum_get_log_blockid
    │   │       │   │   │   │       │   ├─ [  0.34%] __gthread_mutex_unlock
    │   │       │   │   │   │       │   ├─ [  0.25%] prior_lsa_append_data
    │   │       │   │   │   │       │   │   └─ [  0.12%] log_prior_lsa_append_align
    │   │       │   │   │   │       │   ├─ [  0.25%] log_prior_lsa_append_advance_when_doesnot_fit
    │   │       │   │   │   │       │   └─ [  0.13%] logpb_get_memsize
    │   │       │   │   │   │       ├─ [  0.39%] pgbuf_set_lsa
    │   │       │   │   │   │       │   └─ [  0.50%] pgbuf_set_dirty_buffer_ptr
    │   │       │   │   │   │       │       ├─ [  0.34%] pgbuf_find_thrd_holder
    │   │       │   │   │   │       │       └─ [  0.48%] pgbuf_set_dirty
    │   │       │   │   │   │       ├─ [  3.30%] LOG_FIND_TDES
    │   │       │   │   │   │       ├─ [  0.52%] logtb_find_client_type
    │   │       │   │   │   │       │   └─ [  3.30%] LOG_FIND_TDES
    │   │       │   │   │   │       ├─ [  0.27%] pgbuf_is_lsa_temporary
    │   │       │   │   │   │       │   └─ [  0.22%] xdisk_get_purpose
    │   │       │   │   │   │       └─ [  0.12%] log_can_skip_undo_logging
    │   │       │   │   │   └─ [  9.27%] log_append_undoredo_data
    │   │       │   │   │       └─ [ 27.75%] log_append_undoredo_crumbs
    │   │       │   │   │           ├─ [ 13.96%] prior_lsa_alloc_and_copy_crumbs
    │   │       │   │   │           │   ├─ [  9.86%] prior_lsa_gen_undoredo_record_from_crumbs
    │   │       │   │   │           │   │   ├─ [  4.42%] log_zip
    │   │       │   │   │           │   │   │   ├─ [  3.50%] LZ4_resetStream_fast
    │   │       │   │   │           │   │   │   │   └─ [  3.19%] __memset_evex_unaligned_erms
    │   │       │   │   │           │   │   │   └─ [  0.26%] __tls_get_addr
    │   │       │   │   │           │   │   ├─ [ 11.55%] cub_alloc
    │   │       │   │   │           │   │   │   └─ [ 14.87%] __GI___libc_malloc
    │   │       │   │   │           │   │   │       └─ [ 12.26%] _int_malloc
    │   │       │   │   │           │   │   │           ├─ [  9.37%] sysmalloc
    │   │       │   │   │           │   │   │           │   └─ [  8.25%] __GI___mprotect
    │   │       │   │   │           │   │   │           └─ [  0.30%] unlink_chunk.isra.2
    │   │       │   │   │           │   │   ├─ [  9.68%] __memmove_evex_unaligned_erms
    │   │       │   │   │           │   │   ├─ [  0.51%] prior_lsa_copy_redo_crumbs_to_node
    │   │       │   │   │           │   │   │   └─ [ 11.55%] cub_alloc
    │   │       │   │   │           │   │   │       └─ [ 14.87%] __GI___libc_malloc
    │   │       │   │   │           │   │   │           └─ [ 12.26%] _int_malloc
    │   │       │   │   │           │   │   │               ├─ [  9.37%] sysmalloc
    │   │       │   │   │           │   │   │               │   └─ [  8.25%] __GI___mprotect
    │   │       │   │   │           │   │   │               └─ [  0.30%] unlink_chunk.isra.2
    │   │       │   │   │           │   │   ├─ [  0.41%] prior_lsa_copy_undo_crumbs_to_node
    │   │       │   │   │           │   │   │   └─ [ 11.55%] cub_alloc
    │   │       │   │   │           │   │   │       └─ [ 14.87%] __GI___libc_malloc
    │   │       │   │   │           │   │   │           └─ [ 12.26%] _int_malloc
    │   │       │   │   │           │   │   │               ├─ [  9.37%] sysmalloc
    │   │       │   │   │           │   │   │               │   └─ [  8.25%] __GI___mprotect
    │   │       │   │   │           │   │   │               └─ [  0.30%] unlink_chunk.isra.2
    │   │       │   │   │           │   │   ├─ [  0.35%] log_diff
    │   │       │   │   │           │   │   ├─ [  0.30%] LOG_FIND_CURRENT_TDES
    │   │       │   │   │           │   │   │   └─ [  3.30%] LOG_FIND_TDES
    │   │       │   │   │           │   │   ├─ [  0.13%] log_zip@plt
    │   │       │   │   │           │   │   └─ [  0.12%] pgbuf_get_vpid_ptr
    │   │       │   │   │           │   ├─ [ 11.55%] cub_alloc
    │   │       │   │   │           │   │   └─ [ 14.87%] __GI___libc_malloc
    │   │       │   │   │           │   │       └─ [ 12.26%] _int_malloc
    │   │       │   │   │           │   │           ├─ [  9.37%] sysmalloc
    │   │       │   │   │           │   │           │   └─ [  8.25%] __GI___mprotect
    │   │       │   │   │           │   │           └─ [  0.30%] unlink_chunk.isra.2
    │   │       │   │   │           │   ├─ [  1.22%] prior_lsa_copy_redo_data_to_node
    │   │       │   │   │           │   │   ├─ [ 11.55%] cub_alloc
    │   │       │   │   │           │   │   │   └─ [ 14.87%] __GI___libc_malloc
    │   │       │   │   │           │   │   │       └─ [ 12.26%] _int_malloc
    │   │       │   │   │           │   │   │           ├─ [  9.37%] sysmalloc
    │   │       │   │   │           │   │   │           │   └─ [  8.25%] __GI___mprotect
    │   │       │   │   │           │   │   │           └─ [  0.30%] unlink_chunk.isra.2
    │   │       │   │   │           │   │   └─ [  9.68%] __memmove_evex_unaligned_erms
    │   │       │   │   │           │   ├─ [  4.42%] log_zip
    │   │       │   │   │           │   │   ├─ [  3.50%] LZ4_resetStream_fast
    │   │       │   │   │           │   │   │   └─ [  3.19%] __memset_evex_unaligned_erms
    │   │       │   │   │           │   │   └─ [  0.26%] __tls_get_addr
    │   │       │   │   │           │   └─ [  0.33%] prior_lsa_copy_undo_data_to_node
    │   │       │   │   │           │       └─ [ 11.55%] cub_alloc
    │   │       │   │   │           │           └─ [ 14.87%] __GI___libc_malloc
    │   │       │   │   │           │               └─ [ 12.26%] _int_malloc
    │   │       │   │   │           │                   ├─ [  9.37%] sysmalloc
    │   │       │   │   │           │                   │   └─ [  8.25%] __GI___mprotect
    │   │       │   │   │           │                   └─ [  0.30%] unlink_chunk.isra.2
    │   │       │   │   │           ├─ [ 15.04%] prior_lsa_next_record_internal
    │   │       │   │   │           │   ├─ [ 11.07%] __GI___pthread_mutex_lock
    │   │       │   │   │           │   │   └─ [  5.34%] __lll_lock_wait
    │   │       │   │   │           │   ├─ [  7.75%] __pthread_mutex_unlock_usercnt
    │   │       │   │   │           │   │   └─ [  4.29%] __lll_unlock_wake
    │   │       │   │   │           │   ├─ [  0.45%] prior_lsa_start_append
    │   │       │   │   │           │   │   └─ [  0.14%] log_tdes::is_system_worker_transaction
    │   │       │   │   │           │   ├─ [  0.37%] vacuum_get_log_blockid
    │   │       │   │   │           │   ├─ [  0.34%] __gthread_mutex_unlock
    │   │       │   │   │           │   ├─ [  0.25%] prior_lsa_append_data
    │   │       │   │   │           │   │   └─ [  0.12%] log_prior_lsa_append_align
    │   │       │   │   │           │   ├─ [  0.25%] log_prior_lsa_append_advance_when_doesnot_fit
    │   │       │   │   │           │   └─ [  0.13%] logpb_get_memsize
    │   │       │   │   │           ├─ [  0.39%] pgbuf_set_lsa
    │   │       │   │   │           │   └─ [  0.50%] pgbuf_set_dirty_buffer_ptr
    │   │       │   │   │           │       ├─ [  0.34%] pgbuf_find_thrd_holder
    │   │       │   │   │           │       └─ [  0.48%] pgbuf_set_dirty
    │   │       │   │   │           ├─ [  3.30%] LOG_FIND_TDES
    │   │       │   │   │           ├─ [  0.52%] logtb_find_client_type
    │   │       │   │   │           │   └─ [  3.30%] LOG_FIND_TDES
    │   │       │   │   │           ├─ [  0.27%] pgbuf_is_lsa_temporary
    │   │       │   │   │           │   └─ [  0.22%] xdisk_get_purpose
    │   │       │   │   │           └─ [  0.12%] log_can_skip_undo_logging
    │   │       │   │   ├─ [  2.96%] heap_vpid_init_new
    │   │       │   │   │   ├─ [  9.27%] log_append_undoredo_data
    │   │       │   │   │   │   └─ [ 27.75%] log_append_undoredo_crumbs
    │   │       │   │   │   │       ├─ [ 13.96%] prior_lsa_alloc_and_copy_crumbs
    │   │       │   │   │   │       │   ├─ [  9.86%] prior_lsa_gen_undoredo_record_from_crumbs
    │   │       │   │   │   │       │   │   ├─ [  4.42%] log_zip
    │   │       │   │   │   │       │   │   │   ├─ [  3.50%] LZ4_resetStream_fast
    │   │       │   │   │   │       │   │   │   │   └─ [  3.19%] __memset_evex_unaligned_erms
    │   │       │   │   │   │       │   │   │   └─ [  0.26%] __tls_get_addr
    │   │       │   │   │   │       │   │   ├─ [ 11.55%] cub_alloc
    │   │       │   │   │   │       │   │   │   └─ [ 14.87%] __GI___libc_malloc
    │   │       │   │   │   │       │   │   │       └─ [ 12.26%] _int_malloc
    │   │       │   │   │   │       │   │   │           ├─ [  9.37%] sysmalloc
    │   │       │   │   │   │       │   │   │           │   └─ [  8.25%] __GI___mprotect
    │   │       │   │   │   │       │   │   │           └─ [  0.30%] unlink_chunk.isra.2
    │   │       │   │   │   │       │   │   ├─ [  9.68%] __memmove_evex_unaligned_erms
    │   │       │   │   │   │       │   │   ├─ [  0.51%] prior_lsa_copy_redo_crumbs_to_node
    │   │       │   │   │   │       │   │   │   └─ [ 11.55%] cub_alloc
    │   │       │   │   │   │       │   │   │       └─ [ 14.87%] __GI___libc_malloc
    │   │       │   │   │   │       │   │   │           └─ [ 12.26%] _int_malloc
    │   │       │   │   │   │       │   │   │               ├─ [  9.37%] sysmalloc
    │   │       │   │   │   │       │   │   │               │   └─ [  8.25%] __GI___mprotect
    │   │       │   │   │   │       │   │   │               └─ [  0.30%] unlink_chunk.isra.2
    │   │       │   │   │   │       │   │   ├─ [  0.41%] prior_lsa_copy_undo_crumbs_to_node
    │   │       │   │   │   │       │   │   │   └─ [ 11.55%] cub_alloc
    │   │       │   │   │   │       │   │   │       └─ [ 14.87%] __GI___libc_malloc
    │   │       │   │   │   │       │   │   │           └─ [ 12.26%] _int_malloc
    │   │       │   │   │   │       │   │   │               ├─ [  9.37%] sysmalloc
    │   │       │   │   │   │       │   │   │               │   └─ [  8.25%] __GI___mprotect
    │   │       │   │   │   │       │   │   │               └─ [  0.30%] unlink_chunk.isra.2
    │   │       │   │   │   │       │   │   ├─ [  0.35%] log_diff
    │   │       │   │   │   │       │   │   ├─ [  0.30%] LOG_FIND_CURRENT_TDES
    │   │       │   │   │   │       │   │   │   └─ [  3.30%] LOG_FIND_TDES
    │   │       │   │   │   │       │   │   ├─ [  0.13%] log_zip@plt
    │   │       │   │   │   │       │   │   └─ [  0.12%] pgbuf_get_vpid_ptr
    │   │       │   │   │   │       │   ├─ [ 11.55%] cub_alloc
    │   │       │   │   │   │       │   │   └─ [ 14.87%] __GI___libc_malloc
    │   │       │   │   │   │       │   │       └─ [ 12.26%] _int_malloc
    │   │       │   │   │   │       │   │           ├─ [  9.37%] sysmalloc
    │   │       │   │   │   │       │   │           │   └─ [  8.25%] __GI___mprotect
    │   │       │   │   │   │       │   │           └─ [  0.30%] unlink_chunk.isra.2
    │   │       │   │   │   │       │   ├─ [  1.22%] prior_lsa_copy_redo_data_to_node
    │   │       │   │   │   │       │   │   ├─ [ 11.55%] cub_alloc
    │   │       │   │   │   │       │   │   │   └─ [ 14.87%] __GI___libc_malloc
    │   │       │   │   │   │       │   │   │       └─ [ 12.26%] _int_malloc
    │   │       │   │   │   │       │   │   │           ├─ [  9.37%] sysmalloc
    │   │       │   │   │   │       │   │   │           │   └─ [  8.25%] __GI___mprotect
    │   │       │   │   │   │       │   │   │           └─ [  0.30%] unlink_chunk.isra.2
    │   │       │   │   │   │       │   │   └─ [  9.68%] __memmove_evex_unaligned_erms
    │   │       │   │   │   │       │   ├─ [  4.42%] log_zip
    │   │       │   │   │   │       │   │   ├─ [  3.50%] LZ4_resetStream_fast
    │   │       │   │   │   │       │   │   │   └─ [  3.19%] __memset_evex_unaligned_erms
    │   │       │   │   │   │       │   │   └─ [  0.26%] __tls_get_addr
    │   │       │   │   │   │       │   └─ [  0.33%] prior_lsa_copy_undo_data_to_node
    │   │       │   │   │   │       │       └─ [ 11.55%] cub_alloc
    │   │       │   │   │   │       │           └─ [ 14.87%] __GI___libc_malloc
    │   │       │   │   │   │       │               └─ [ 12.26%] _int_malloc
    │   │       │   │   │   │       │                   ├─ [  9.37%] sysmalloc
    │   │       │   │   │   │       │                   │   └─ [  8.25%] __GI___mprotect
    │   │       │   │   │   │       │                   └─ [  0.30%] unlink_chunk.isra.2
    │   │       │   │   │   │       ├─ [ 15.04%] prior_lsa_next_record_internal
    │   │       │   │   │   │       │   ├─ [ 11.07%] __GI___pthread_mutex_lock
    │   │       │   │   │   │       │   │   └─ [  5.34%] __lll_lock_wait
    │   │       │   │   │   │       │   ├─ [  7.75%] __pthread_mutex_unlock_usercnt
    │   │       │   │   │   │       │   │   └─ [  4.29%] __lll_unlock_wake
    │   │       │   │   │   │       │   ├─ [  0.45%] prior_lsa_start_append
    │   │       │   │   │   │       │   │   └─ [  0.14%] log_tdes::is_system_worker_transaction
    │   │       │   │   │   │       │   ├─ [  0.37%] vacuum_get_log_blockid
    │   │       │   │   │   │       │   ├─ [  0.34%] __gthread_mutex_unlock
    │   │       │   │   │   │       │   ├─ [  0.25%] prior_lsa_append_data
    │   │       │   │   │   │       │   │   └─ [  0.12%] log_prior_lsa_append_align
    │   │       │   │   │   │       │   ├─ [  0.25%] log_prior_lsa_append_advance_when_doesnot_fit
    │   │       │   │   │   │       │   └─ [  0.13%] logpb_get_memsize
    │   │       │   │   │   │       ├─ [  0.39%] pgbuf_set_lsa
    │   │       │   │   │   │       │   └─ [  0.50%] pgbuf_set_dirty_buffer_ptr
    │   │       │   │   │   │       │       ├─ [  0.34%] pgbuf_find_thrd_holder
    │   │       │   │   │   │       │       └─ [  0.48%] pgbuf_set_dirty
    │   │       │   │   │   │       ├─ [  3.30%] LOG_FIND_TDES
    │   │       │   │   │   │       ├─ [  0.52%] logtb_find_client_type
    │   │       │   │   │   │       │   └─ [  3.30%] LOG_FIND_TDES
    │   │       │   │   │   │       ├─ [  0.27%] pgbuf_is_lsa_temporary
    │   │       │   │   │   │       │   └─ [  0.22%] xdisk_get_purpose
    │   │       │   │   │   │       └─ [  0.12%] log_can_skip_undo_logging
    │   │       │   │   │   ├─ [  0.76%] spage_insert
    │   │       │   │   │   │   └─ [  0.65%] spage_find_empty_slot
    │   │       │   │   │   │       ├─ [  1.51%] spage_has_enough_total_space
    │   │       │   │   │   │       │   ├─ [  2.01%] spage_get_total_saved_spaces
    │   │       │   │   │   │       │   │   └─ [  1.93%] spage_get_saved_spaces
    │   │       │   │   │   │       │   │       ├─ [  1.48%] lf_hash_find
    │   │       │   │   │   │       │   │       │   ├─ [  0.87%] lf_list_find
    │   │       │   │   │   │       │   │       │   └─ [  0.19%] lf_callback_vpid_hash
    │   │       │   │   │   │       │   │       └─ [  0.39%] logtb_find_tranid
    │   │       │   │   │   │       │   │           └─ [  3.30%] LOG_FIND_TDES
    │   │       │   │   │   │       │   └─ [  0.39%] logtb_find_tranid
    │   │       │   │   │   │       │       └─ [  3.30%] LOG_FIND_TDES
    │   │       │   │   │   │       └─ [  1.13%] spage_check_space
    │   │       │   │   │   │           └─ [  1.51%] spage_has_enough_total_space
    │   │       │   │   │   │               ├─ [  2.01%] spage_get_total_saved_spaces
    │   │       │   │   │   │               │   └─ [  1.93%] spage_get_saved_spaces
    │   │       │   │   │   │               │       ├─ [  1.48%] lf_hash_find
    │   │       │   │   │   │               │       │   ├─ [  0.87%] lf_list_find
    │   │       │   │   │   │               │       │   └─ [  0.19%] lf_callback_vpid_hash
    │   │       │   │   │   │               │       └─ [  0.39%] logtb_find_tranid
    │   │       │   │   │   │               │           └─ [  3.30%] LOG_FIND_TDES
    │   │       │   │   │   │               └─ [  0.39%] logtb_find_tranid
    │   │       │   │   │   │                   └─ [  3.30%] LOG_FIND_TDES
    │   │       │   │   │   ├─ [  0.15%] spage_initialize
    │   │       │   │   │   └─ [  0.48%] pgbuf_set_dirty
    │   │       │   │   │       └─ [  0.50%] pgbuf_set_dirty_buffer_ptr
    │   │       │   │   │           └─ [  0.34%] pgbuf_find_thrd_holder
    │   │       │   │   ├─ [  2.13%] log_sysop_end_logical_undo
    │   │       │   │   │   └─ [  3.85%] log_sysop_commit_internal
    │   │       │   │   │       ├─ [  3.29%] log_append_sysop_end
    │   │       │   │   │       │   ├─ [ 15.04%] prior_lsa_next_record_internal
    │   │       │   │   │       │   │   ├─ [ 11.07%] __GI___pthread_mutex_lock
    │   │       │   │   │       │   │   │   └─ [  5.34%] __lll_lock_wait
    │   │       │   │   │       │   │   ├─ [  7.75%] __pthread_mutex_unlock_usercnt
    │   │       │   │   │       │   │   │   └─ [  4.29%] __lll_unlock_wake
    │   │       │   │   │       │   │   ├─ [  0.45%] prior_lsa_start_append
    │   │       │   │   │       │   │   │   └─ [  0.14%] log_tdes::is_system_worker_transaction
    │   │       │   │   │       │   │   ├─ [  0.37%] vacuum_get_log_blockid
    │   │       │   │   │       │   │   ├─ [  0.34%] __gthread_mutex_unlock
    │   │       │   │   │       │   │   ├─ [  0.25%] prior_lsa_append_data
    │   │       │   │   │       │   │   │   └─ [  0.12%] log_prior_lsa_append_align
    │   │       │   │   │       │   │   ├─ [  0.25%] log_prior_lsa_append_advance_when_doesnot_fit
    │   │       │   │   │       │   │   └─ [  0.13%] logpb_get_memsize
    │   │       │   │   │       │   └─ [  1.49%] prior_lsa_alloc_and_copy_data
    │   │       │   │   │       │       ├─ [ 11.55%] cub_alloc
    │   │       │   │   │       │       │   └─ [ 14.87%] __GI___libc_malloc
    │   │       │   │   │       │       │       └─ [ 12.26%] _int_malloc
    │   │       │   │   │       │       │           ├─ [  9.37%] sysmalloc
    │   │       │   │   │       │       │           │   └─ [  8.25%] __GI___mprotect
    │   │       │   │   │       │       │           └─ [  0.30%] unlink_chunk.isra.2
    │   │       │   │   │       │       ├─ [  0.47%] prior_lsa_gen_record
    │   │       │   │   │       │       │   └─ [ 11.55%] cub_alloc
    │   │       │   │   │       │       │       └─ [ 14.87%] __GI___libc_malloc
    │   │       │   │   │       │       │           └─ [ 12.26%] _int_malloc
    │   │       │   │   │       │       │               ├─ [  9.37%] sysmalloc
    │   │       │   │   │       │       │               │   └─ [  8.25%] __GI___mprotect
    │   │       │   │   │       │       │               └─ [  0.30%] unlink_chunk.isra.2
    │   │       │   │   │       │       └─ [  0.33%] prior_lsa_copy_undo_data_to_node
    │   │       │   │   │       │           └─ [ 11.55%] cub_alloc
    │   │       │   │   │       │               └─ [ 14.87%] __GI___libc_malloc
    │   │       │   │   │       │                   └─ [ 12.26%] _int_malloc
    │   │       │   │   │       │                       ├─ [  9.37%] sysmalloc
    │   │       │   │   │       │                       │   └─ [  8.25%] __GI___mprotect
    │   │       │   │   │       │                       └─ [  0.30%] unlink_chunk.isra.2
    │   │       │   │   │       ├─ [  0.28%] log_tdes::unlock_topop
    │   │       │   │   │       │   └─ [  0.29%] cubpl::get_session
    │   │       │   │   │       │       └─ [  0.21%] session_get_pl_session
    │   │       │   │   │       │           └─ [  0.13%] cubpl::session::is_sp_running
    │   │       │   │   │       └─ [  0.10%] log_sysop_end_final
    │   │       │   │   ├─ [ 15.04%] prior_lsa_next_record_internal
    │   │       │   │   │   ├─ [ 11.07%] __GI___pthread_mutex_lock
    │   │       │   │   │   │   └─ [  5.34%] __lll_lock_wait
    │   │       │   │   │   ├─ [  7.75%] __pthread_mutex_unlock_usercnt
    │   │       │   │   │   │   └─ [  4.29%] __lll_unlock_wake
    │   │       │   │   │   ├─ [  0.45%] prior_lsa_start_append
    │   │       │   │   │   │   └─ [  0.14%] log_tdes::is_system_worker_transaction
    │   │       │   │   │   ├─ [  0.37%] vacuum_get_log_blockid
    │   │       │   │   │   ├─ [  0.34%] __gthread_mutex_unlock
    │   │       │   │   │   ├─ [  0.25%] prior_lsa_append_data
    │   │       │   │   │   │   └─ [  0.12%] log_prior_lsa_append_align
    │   │       │   │   │   ├─ [  0.25%] log_prior_lsa_append_advance_when_doesnot_fit
    │   │       │   │   │   └─ [  0.13%] logpb_get_memsize
    │   │       │   │   ├─ [  4.38%] pgbuf_unfix
    │   │       │   │   │   ├─ [  2.70%] pgbuf_unlatch_bcb_upon_unfix
    │   │       │   │   │   │   ├─ [  0.60%] pgbuf_unlatch_void_zone_bcb
    │   │       │   │   │   │   │   ├─ [  0.41%] pgbuf_lru_add_new_bcb_to_top
    │   │       │   │   │   │   │   │   └─ [  0.32%] pgbuf_lru_adjust_zones
    │   │       │   │   │   │   │   │       ├─ [  0.13%] pgbuf_lru_adjust_zone1
    │   │       │   │   │   │   │   │       │   └─ [  0.21%] pgbuf_bcb_change_zone
    │   │       │   │   │   │   │   │       │       └─ [  0.20%] ATOMIC_CAS_32<int, int, int>
    │   │       │   │   │   │   │   │       └─ [  0.13%] pgbuf_lru_fall_bcb_to_zone_3
    │   │       │   │   │   │   │   ├─ [  0.21%] pgbuf_bcb_register_hit_for_lru
    │   │       │   │   │   │   │   └─ [ 11.07%] __GI___pthread_mutex_lock
    │   │       │   │   │   │   │       └─ [  5.34%] __lll_lock_wait
    │   │       │   │   │   │   ├─ [  7.75%] __pthread_mutex_unlock_usercnt
    │   │       │   │   │   │   │   └─ [  4.29%] __lll_unlock_wake
    │   │       │   │   │   │   ├─ [  0.25%] pgbuf_wakeup_reader_writer
    │   │       │   │   │   │   │   └─ [  0.25%] set_waiter_exists
    │   │       │   │   │   │   └─ [  0.21%] pgbuf_bcb_register_hit_for_lru
    │   │       │   │   │   ├─ [ 11.07%] __GI___pthread_mutex_lock
    │   │       │   │   │   │   └─ [  5.34%] __lll_lock_wait
    │   │       │   │   │   ├─ [  0.38%] pgbuf_unlatch_thrd_holder
    │   │       │   │   │   │   ├─ [  0.19%] pgbuf_remove_thrd_holder
    │   │       │   │   │   │   └─ [  0.34%] pgbuf_find_thrd_holder
    │   │       │   │   │   ├─ [  0.17%] perfmon_is_perf_tracking
    │   │       │   │   │   └─ [  0.22%] xdisk_get_purpose
    │   │       │   │   └─ [  0.60%] log_sysop_start_atomic
    │   │       │   │       ├─ [  1.49%] prior_lsa_alloc_and_copy_data
    │   │       │   │       │   ├─ [ 11.55%] cub_alloc
    │   │       │   │       │   │   └─ [ 14.87%] __GI___libc_malloc
    │   │       │   │       │   │       └─ [ 12.26%] _int_malloc
    │   │       │   │       │   │           ├─ [  9.37%] sysmalloc
    │   │       │   │       │   │           │   └─ [  8.25%] __GI___mprotect
    │   │       │   │       │   │           └─ [  0.30%] unlink_chunk.isra.2
    │   │       │   │       │   ├─ [  0.47%] prior_lsa_gen_record
    │   │       │   │       │   │   └─ [ 11.55%] cub_alloc
    │   │       │   │       │   │       └─ [ 14.87%] __GI___libc_malloc
    │   │       │   │       │   │           └─ [ 12.26%] _int_malloc
    │   │       │   │       │   │               ├─ [  9.37%] sysmalloc
    │   │       │   │       │   │               │   └─ [  8.25%] __GI___mprotect
    │   │       │   │       │   │               └─ [  0.30%] unlink_chunk.isra.2
    │   │       │   │       │   └─ [  0.33%] prior_lsa_copy_undo_data_to_node
    │   │       │   │       │       └─ [ 11.55%] cub_alloc
    │   │       │   │       │           └─ [ 14.87%] __GI___libc_malloc
    │   │       │   │       │               └─ [ 12.26%] _int_malloc
    │   │       │   │       │                   ├─ [  9.37%] sysmalloc
    │   │       │   │       │                   │   └─ [  8.25%] __GI___mprotect
    │   │       │   │       │                   └─ [  0.30%] unlink_chunk.isra.2
    │   │       │   │       └─ [  0.32%] log_sysop_start
    │   │       │   │           └─ [  0.20%] log_tdes::lock_topop
    │   │       │   │               └─ [  0.29%] cubpl::get_session
    │   │       │   │                   └─ [  0.21%] session_get_pl_session
    │   │       │   │                       └─ [  0.13%] cubpl::session::is_sp_running
    │   │       │   ├─ [  9.27%] log_append_undoredo_data
    │   │       │   │   └─ [ 27.75%] log_append_undoredo_crumbs
    │   │       │   │       ├─ [ 13.96%] prior_lsa_alloc_and_copy_crumbs
    │   │       │   │       │   ├─ [  9.86%] prior_lsa_gen_undoredo_record_from_crumbs
    │   │       │   │       │   │   ├─ [  4.42%] log_zip
    │   │       │   │       │   │   │   ├─ [  3.50%] LZ4_resetStream_fast
    │   │       │   │       │   │   │   │   └─ [  3.19%] __memset_evex_unaligned_erms
    │   │       │   │       │   │   │   └─ [  0.26%] __tls_get_addr
    │   │       │   │       │   │   ├─ [ 11.55%] cub_alloc
    │   │       │   │       │   │   │   └─ [ 14.87%] __GI___libc_malloc
    │   │       │   │       │   │   │       └─ [ 12.26%] _int_malloc
    │   │       │   │       │   │   │           ├─ [  9.37%] sysmalloc
    │   │       │   │       │   │   │           │   └─ [  8.25%] __GI___mprotect
    │   │       │   │       │   │   │           └─ [  0.30%] unlink_chunk.isra.2
    │   │       │   │       │   │   ├─ [  9.68%] __memmove_evex_unaligned_erms
    │   │       │   │       │   │   ├─ [  0.51%] prior_lsa_copy_redo_crumbs_to_node
    │   │       │   │       │   │   │   └─ [ 11.55%] cub_alloc
    │   │       │   │       │   │   │       └─ [ 14.87%] __GI___libc_malloc
    │   │       │   │       │   │   │           └─ [ 12.26%] _int_malloc
    │   │       │   │       │   │   │               ├─ [  9.37%] sysmalloc
    │   │       │   │       │   │   │               │   └─ [  8.25%] __GI___mprotect
    │   │       │   │       │   │   │               └─ [  0.30%] unlink_chunk.isra.2
    │   │       │   │       │   │   ├─ [  0.41%] prior_lsa_copy_undo_crumbs_to_node
    │   │       │   │       │   │   │   └─ [ 11.55%] cub_alloc
    │   │       │   │       │   │   │       └─ [ 14.87%] __GI___libc_malloc
    │   │       │   │       │   │   │           └─ [ 12.26%] _int_malloc
    │   │       │   │       │   │   │               ├─ [  9.37%] sysmalloc
    │   │       │   │       │   │   │               │   └─ [  8.25%] __GI___mprotect
    │   │       │   │       │   │   │               └─ [  0.30%] unlink_chunk.isra.2
    │   │       │   │       │   │   ├─ [  0.35%] log_diff
    │   │       │   │       │   │   ├─ [  0.30%] LOG_FIND_CURRENT_TDES
    │   │       │   │       │   │   │   └─ [  3.30%] LOG_FIND_TDES
    │   │       │   │       │   │   ├─ [  0.13%] log_zip@plt
    │   │       │   │       │   │   └─ [  0.12%] pgbuf_get_vpid_ptr
    │   │       │   │       │   ├─ [ 11.55%] cub_alloc
    │   │       │   │       │   │   └─ [ 14.87%] __GI___libc_malloc
    │   │       │   │       │   │       └─ [ 12.26%] _int_malloc
    │   │       │   │       │   │           ├─ [  9.37%] sysmalloc
    │   │       │   │       │   │           │   └─ [  8.25%] __GI___mprotect
    │   │       │   │       │   │           └─ [  0.30%] unlink_chunk.isra.2
    │   │       │   │       │   ├─ [  1.22%] prior_lsa_copy_redo_data_to_node
    │   │       │   │       │   │   ├─ [ 11.55%] cub_alloc
    │   │       │   │       │   │   │   └─ [ 14.87%] __GI___libc_malloc
    │   │       │   │       │   │   │       └─ [ 12.26%] _int_malloc
    │   │       │   │       │   │   │           ├─ [  9.37%] sysmalloc
    │   │       │   │       │   │   │           │   └─ [  8.25%] __GI___mprotect
    │   │       │   │       │   │   │           └─ [  0.30%] unlink_chunk.isra.2
    │   │       │   │       │   │   └─ [  9.68%] __memmove_evex_unaligned_erms
    │   │       │   │       │   ├─ [  4.42%] log_zip
    │   │       │   │       │   │   ├─ [  3.50%] LZ4_resetStream_fast
    │   │       │   │       │   │   │   └─ [  3.19%] __memset_evex_unaligned_erms
    │   │       │   │       │   │   └─ [  0.26%] __tls_get_addr
    │   │       │   │       │   └─ [  0.33%] prior_lsa_copy_undo_data_to_node
    │   │       │   │       │       └─ [ 11.55%] cub_alloc
    │   │       │   │       │           └─ [ 14.87%] __GI___libc_malloc
    │   │       │   │       │               └─ [ 12.26%] _int_malloc
    │   │       │   │       │                   ├─ [  9.37%] sysmalloc
    │   │       │   │       │                   │   └─ [  8.25%] __GI___mprotect
    │   │       │   │       │                   └─ [  0.30%] unlink_chunk.isra.2
    │   │       │   │       ├─ [ 15.04%] prior_lsa_next_record_internal
    │   │       │   │       │   ├─ [ 11.07%] __GI___pthread_mutex_lock
    │   │       │   │       │   │   └─ [  5.34%] __lll_lock_wait
    │   │       │   │       │   ├─ [  7.75%] __pthread_mutex_unlock_usercnt
    │   │       │   │       │   │   └─ [  4.29%] __lll_unlock_wake
    │   │       │   │       │   ├─ [  0.45%] prior_lsa_start_append
    │   │       │   │       │   │   └─ [  0.14%] log_tdes::is_system_worker_transaction
    │   │       │   │       │   ├─ [  0.37%] vacuum_get_log_blockid
    │   │       │   │       │   ├─ [  0.34%] __gthread_mutex_unlock
    │   │       │   │       │   ├─ [  0.25%] prior_lsa_append_data
    │   │       │   │       │   │   └─ [  0.12%] log_prior_lsa_append_align
    │   │       │   │       │   ├─ [  0.25%] log_prior_lsa_append_advance_when_doesnot_fit
    │   │       │   │       │   └─ [  0.13%] logpb_get_memsize
    │   │       │   │       ├─ [  0.39%] pgbuf_set_lsa
    │   │       │   │       │   └─ [  0.50%] pgbuf_set_dirty_buffer_ptr
    │   │       │   │       │       ├─ [  0.34%] pgbuf_find_thrd_holder
    │   │       │   │       │       └─ [  0.48%] pgbuf_set_dirty
    │   │       │   │       ├─ [  3.30%] LOG_FIND_TDES
    │   │       │   │       ├─ [  0.52%] logtb_find_client_type
    │   │       │   │       │   └─ [  3.30%] LOG_FIND_TDES
    │   │       │   │       ├─ [  0.27%] pgbuf_is_lsa_temporary
    │   │       │   │       │   └─ [  0.22%] xdisk_get_purpose
    │   │       │   │       └─ [  0.12%] log_can_skip_undo_logging
    │   │       │   ├─ [  1.74%] log_sysop_commit
    │   │       │   │   └─ [  3.85%] log_sysop_commit_internal
    │   │       │   │       ├─ [  3.29%] log_append_sysop_end
    │   │       │   │       │   ├─ [ 15.04%] prior_lsa_next_record_internal
    │   │       │   │       │   │   ├─ [ 11.07%] __GI___pthread_mutex_lock
    │   │       │   │       │   │   │   └─ [  5.34%] __lll_lock_wait
    │   │       │   │       │   │   ├─ [  7.75%] __pthread_mutex_unlock_usercnt
    │   │       │   │       │   │   │   └─ [  4.29%] __lll_unlock_wake
    │   │       │   │       │   │   ├─ [  0.45%] prior_lsa_start_append
    │   │       │   │       │   │   │   └─ [  0.14%] log_tdes::is_system_worker_transaction
    │   │       │   │       │   │   ├─ [  0.37%] vacuum_get_log_blockid
    │   │       │   │       │   │   ├─ [  0.34%] __gthread_mutex_unlock
    │   │       │   │       │   │   ├─ [  0.25%] prior_lsa_append_data
    │   │       │   │       │   │   │   └─ [  0.12%] log_prior_lsa_append_align
    │   │       │   │       │   │   ├─ [  0.25%] log_prior_lsa_append_advance_when_doesnot_fit
    │   │       │   │       │   │   └─ [  0.13%] logpb_get_memsize
    │   │       │   │       │   └─ [  1.49%] prior_lsa_alloc_and_copy_data
    │   │       │   │       │       ├─ [ 11.55%] cub_alloc
    │   │       │   │       │       │   └─ [ 14.87%] __GI___libc_malloc
    │   │       │   │       │       │       └─ [ 12.26%] _int_malloc
    │   │       │   │       │       │           ├─ [  9.37%] sysmalloc
    │   │       │   │       │       │           │   └─ [  8.25%] __GI___mprotect
    │   │       │   │       │       │           └─ [  0.30%] unlink_chunk.isra.2
    │   │       │   │       │       ├─ [  0.47%] prior_lsa_gen_record
    │   │       │   │       │       │   └─ [ 11.55%] cub_alloc
    │   │       │   │       │       │       └─ [ 14.87%] __GI___libc_malloc
    │   │       │   │       │       │           └─ [ 12.26%] _int_malloc
    │   │       │   │       │       │               ├─ [  9.37%] sysmalloc
    │   │       │   │       │       │               │   └─ [  8.25%] __GI___mprotect
    │   │       │   │       │       │               └─ [  0.30%] unlink_chunk.isra.2
    │   │       │   │       │       └─ [  0.33%] prior_lsa_copy_undo_data_to_node
    │   │       │   │       │           └─ [ 11.55%] cub_alloc
    │   │       │   │       │               └─ [ 14.87%] __GI___libc_malloc
    │   │       │   │       │                   └─ [ 12.26%] _int_malloc
    │   │       │   │       │                       ├─ [  9.37%] sysmalloc
    │   │       │   │       │                       │   └─ [  8.25%] __GI___mprotect
    │   │       │   │       │                       └─ [  0.30%] unlink_chunk.isra.2
    │   │       │   │       ├─ [  0.28%] log_tdes::unlock_topop
    │   │       │   │       │   └─ [  0.29%] cubpl::get_session
    │   │       │   │       │       └─ [  0.21%] session_get_pl_session
    │   │       │   │       │           └─ [  0.13%] cubpl::session::is_sp_running
    │   │       │   │       └─ [  0.10%] log_sysop_end_final
    │   │       │   ├─ [  1.91%] heap_stats_add_bestspace
    │   │       │   │   ├─ [  0.62%] mht_get
    │   │       │   │   ├─ [ 11.07%] __GI___pthread_mutex_lock
    │   │       │   │   │   └─ [  5.34%] __lll_lock_wait
    │   │       │   │   ├─ [  7.75%] __pthread_mutex_unlock_usercnt
    │   │       │   │   │   └─ [  4.29%] __lll_unlock_wake
    │   │       │   │   └─ [  0.18%] mht_put_internal
    │   │       │   ├─ [  4.38%] pgbuf_unfix
    │   │       │   │   ├─ [  2.70%] pgbuf_unlatch_bcb_upon_unfix
    │   │       │   │   │   ├─ [  0.60%] pgbuf_unlatch_void_zone_bcb
    │   │       │   │   │   │   ├─ [  0.41%] pgbuf_lru_add_new_bcb_to_top
    │   │       │   │   │   │   │   └─ [  0.32%] pgbuf_lru_adjust_zones
    │   │       │   │   │   │   │       ├─ [  0.13%] pgbuf_lru_adjust_zone1
    │   │       │   │   │   │   │       │   └─ [  0.21%] pgbuf_bcb_change_zone
    │   │       │   │   │   │   │       │       └─ [  0.20%] ATOMIC_CAS_32<int, int, int>
    │   │       │   │   │   │   │       └─ [  0.13%] pgbuf_lru_fall_bcb_to_zone_3
    │   │       │   │   │   │   ├─ [  0.21%] pgbuf_bcb_register_hit_for_lru
    │   │       │   │   │   │   └─ [ 11.07%] __GI___pthread_mutex_lock
    │   │       │   │   │   │       └─ [  5.34%] __lll_lock_wait
    │   │       │   │   │   ├─ [  7.75%] __pthread_mutex_unlock_usercnt
    │   │       │   │   │   │   └─ [  4.29%] __lll_unlock_wake
    │   │       │   │   │   ├─ [  0.25%] pgbuf_wakeup_reader_writer
    │   │       │   │   │   │   └─ [  0.25%] set_waiter_exists
    │   │       │   │   │   └─ [  0.21%] pgbuf_bcb_register_hit_for_lru
    │   │       │   │   ├─ [ 11.07%] __GI___pthread_mutex_lock
    │   │       │   │   │   └─ [  5.34%] __lll_lock_wait
    │   │       │   │   ├─ [  0.38%] pgbuf_unlatch_thrd_holder
    │   │       │   │   │   ├─ [  0.19%] pgbuf_remove_thrd_holder
    │   │       │   │   │   └─ [  0.34%] pgbuf_find_thrd_holder
    │   │       │   │   ├─ [  0.17%] perfmon_is_perf_tracking
    │   │       │   │   └─ [  0.22%] xdisk_get_purpose
    │   │       │   └─ [  0.32%] log_sysop_start
    │   │       │       └─ [  0.20%] log_tdes::lock_topop
    │   │       │           └─ [  0.29%] cubpl::get_session
    │   │       │               └─ [  0.21%] session_get_pl_session
    │   │       │                   └─ [  0.13%] cubpl::session::is_sp_running
    │   │       ├─ [  4.60%] heap_stats_find_page_in_bestspace
    │   │       │   ├─ [  1.91%] heap_stats_add_bestspace
    │   │       │   │   ├─ [  0.62%] mht_get
    │   │       │   │   ├─ [ 11.07%] __GI___pthread_mutex_lock
    │   │       │   │   │   └─ [  5.34%] __lll_lock_wait
    │   │       │   │   ├─ [  7.75%] __pthread_mutex_unlock_usercnt
    │   │       │   │   │   └─ [  4.29%] __lll_unlock_wake
    │   │       │   │   └─ [  0.18%] mht_put_internal
    │   │       │   ├─ [  1.00%] spage_max_space_for_new_record
    │   │       │   │   └─ [  2.01%] spage_get_total_saved_spaces
    │   │       │   │       └─ [  1.93%] spage_get_saved_spaces
    │   │       │   │           ├─ [  1.48%] lf_hash_find
    │   │       │   │           │   ├─ [  0.87%] lf_list_find
    │   │       │   │           │   └─ [  0.19%] lf_callback_vpid_hash
    │   │       │   │           ├─ [  0.39%] logtb_find_tranid
    │   │       │   │           │   └─ [  3.30%] LOG_FIND_TDES
    │   │       │   │           └─ [  1.51%] spage_has_enough_total_space
    │   │       │   │               └─ [  0.39%] logtb_find_tranid
    │   │       │   │                   └─ [  3.30%] LOG_FIND_TDES
    │   │       │   ├─ [ 11.07%] __GI___pthread_mutex_lock
    │   │       │   │   └─ [  5.34%] __lll_lock_wait
    │   │       │   ├─ [  7.75%] __pthread_mutex_unlock_usercnt
    │   │       │   │   └─ [  4.29%] __lll_unlock_wake
    │   │       │   ├─ [  0.38%] xlogtb_reset_wait_msecs
    │   │       │   │   └─ [  3.30%] LOG_FIND_TDES
    │   │       │   ├─ [  0.17%] mht_rem
    │   │       │   └─ [  0.17%] er_errid
    │   │       ├─ [  9.27%] log_append_undoredo_data
    │   │       │   └─ [ 27.75%] log_append_undoredo_crumbs
    │   │       │       ├─ [ 13.96%] prior_lsa_alloc_and_copy_crumbs
    │   │       │       │   ├─ [  9.86%] prior_lsa_gen_undoredo_record_from_crumbs
    │   │       │       │   │   ├─ [  4.42%] log_zip
    │   │       │       │   │   │   ├─ [  3.50%] LZ4_resetStream_fast
    │   │       │       │   │   │   │   └─ [  3.19%] __memset_evex_unaligned_erms
    │   │       │       │   │   │   └─ [  0.26%] __tls_get_addr
    │   │       │       │   │   ├─ [ 11.55%] cub_alloc
    │   │       │       │   │   │   └─ [ 14.87%] __GI___libc_malloc
    │   │       │       │   │   │       └─ [ 12.26%] _int_malloc
    │   │       │       │   │   │           ├─ [  9.37%] sysmalloc
    │   │       │       │   │   │           │   └─ [  8.25%] __GI___mprotect
    │   │       │       │   │   │           └─ [  0.30%] unlink_chunk.isra.2
    │   │       │       │   │   ├─ [  9.68%] __memmove_evex_unaligned_erms
    │   │       │       │   │   ├─ [  0.51%] prior_lsa_copy_redo_crumbs_to_node
    │   │       │       │   │   │   └─ [ 11.55%] cub_alloc
    │   │       │       │   │   │       └─ [ 14.87%] __GI___libc_malloc
    │   │       │       │   │   │           └─ [ 12.26%] _int_malloc
    │   │       │       │   │   │               ├─ [  9.37%] sysmalloc
    │   │       │       │   │   │               │   └─ [  8.25%] __GI___mprotect
    │   │       │       │   │   │               └─ [  0.30%] unlink_chunk.isra.2
    │   │       │       │   │   ├─ [  0.41%] prior_lsa_copy_undo_crumbs_to_node
    │   │       │       │   │   │   └─ [ 11.55%] cub_alloc
    │   │       │       │   │   │       └─ [ 14.87%] __GI___libc_malloc
    │   │       │       │   │   │           └─ [ 12.26%] _int_malloc
    │   │       │       │   │   │               ├─ [  9.37%] sysmalloc
    │   │       │       │   │   │               │   └─ [  8.25%] __GI___mprotect
    │   │       │       │   │   │               └─ [  0.30%] unlink_chunk.isra.2
    │   │       │       │   │   ├─ [  0.35%] log_diff
    │   │       │       │   │   ├─ [  0.30%] LOG_FIND_CURRENT_TDES
    │   │       │       │   │   │   └─ [  3.30%] LOG_FIND_TDES
    │   │       │       │   │   ├─ [  0.13%] log_zip@plt
    │   │       │       │   │   └─ [  0.12%] pgbuf_get_vpid_ptr
    │   │       │       │   ├─ [ 11.55%] cub_alloc
    │   │       │       │   │   └─ [ 14.87%] __GI___libc_malloc
    │   │       │       │   │       └─ [ 12.26%] _int_malloc
    │   │       │       │   │           ├─ [  9.37%] sysmalloc
    │   │       │       │   │           │   └─ [  8.25%] __GI___mprotect
    │   │       │       │   │           └─ [  0.30%] unlink_chunk.isra.2
    │   │       │       │   ├─ [  1.22%] prior_lsa_copy_redo_data_to_node
    │   │       │       │   │   ├─ [ 11.55%] cub_alloc
    │   │       │       │   │   │   └─ [ 14.87%] __GI___libc_malloc
    │   │       │       │   │   │       └─ [ 12.26%] _int_malloc
    │   │       │       │   │   │           ├─ [  9.37%] sysmalloc
    │   │       │       │   │   │           │   └─ [  8.25%] __GI___mprotect
    │   │       │       │   │   │           └─ [  0.30%] unlink_chunk.isra.2
    │   │       │       │   │   └─ [  9.68%] __memmove_evex_unaligned_erms
    │   │       │       │   ├─ [  4.42%] log_zip
    │   │       │       │   │   ├─ [  3.50%] LZ4_resetStream_fast
    │   │       │       │   │   │   └─ [  3.19%] __memset_evex_unaligned_erms
    │   │       │       │   │   └─ [  0.26%] __tls_get_addr
    │   │       │       │   └─ [  0.33%] prior_lsa_copy_undo_data_to_node
    │   │       │       │       └─ [ 11.55%] cub_alloc
    │   │       │       │           └─ [ 14.87%] __GI___libc_malloc
    │   │       │       │               └─ [ 12.26%] _int_malloc
    │   │       │       │                   ├─ [  9.37%] sysmalloc
    │   │       │       │                   │   └─ [  8.25%] __GI___mprotect
    │   │       │       │                   └─ [  0.30%] unlink_chunk.isra.2
    │   │       │       ├─ [ 15.04%] prior_lsa_next_record_internal
    │   │       │       │   ├─ [ 11.07%] __GI___pthread_mutex_lock
    │   │       │       │   │   └─ [  5.34%] __lll_lock_wait
    │   │       │       │   ├─ [  7.75%] __pthread_mutex_unlock_usercnt
    │   │       │       │   │   └─ [  4.29%] __lll_unlock_wake
    │   │       │       │   ├─ [  0.45%] prior_lsa_start_append
    │   │       │       │   │   └─ [  0.14%] log_tdes::is_system_worker_transaction
    │   │       │       │   ├─ [  0.37%] vacuum_get_log_blockid
    │   │       │       │   ├─ [  0.34%] __gthread_mutex_unlock
    │   │       │       │   ├─ [  0.25%] prior_lsa_append_data
    │   │       │       │   │   └─ [  0.12%] log_prior_lsa_append_align
    │   │       │       │   ├─ [  0.25%] log_prior_lsa_append_advance_when_doesnot_fit
    │   │       │       │   └─ [  0.13%] logpb_get_memsize
    │   │       │       ├─ [  0.39%] pgbuf_set_lsa
    │   │       │       │   └─ [  0.50%] pgbuf_set_dirty_buffer_ptr
    │   │       │       │       ├─ [  0.34%] pgbuf_find_thrd_holder
    │   │       │       │       └─ [  0.48%] pgbuf_set_dirty
    │   │       │       ├─ [  3.30%] LOG_FIND_TDES
    │   │       │       ├─ [  0.52%] logtb_find_client_type
    │   │       │       │   └─ [  3.30%] LOG_FIND_TDES
    │   │       │       ├─ [  0.27%] pgbuf_is_lsa_temporary
    │   │       │       │   └─ [  0.22%] xdisk_get_purpose
    │   │       │       └─ [  0.12%] log_can_skip_undo_logging
    │   │       ├─ [  4.38%] pgbuf_unfix
    │   │       │   ├─ [  2.70%] pgbuf_unlatch_bcb_upon_unfix
    │   │       │   │   ├─ [  0.60%] pgbuf_unlatch_void_zone_bcb
    │   │       │   │   │   ├─ [  0.41%] pgbuf_lru_add_new_bcb_to_top
    │   │       │   │   │   │   └─ [  0.32%] pgbuf_lru_adjust_zones
    │   │       │   │   │   │       ├─ [  0.13%] pgbuf_lru_adjust_zone1
    │   │       │   │   │   │       │   └─ [  0.21%] pgbuf_bcb_change_zone
    │   │       │   │   │   │       │       └─ [  0.20%] ATOMIC_CAS_32<int, int, int>
    │   │       │   │   │   │       └─ [  0.13%] pgbuf_lru_fall_bcb_to_zone_3
    │   │       │   │   │   ├─ [  0.21%] pgbuf_bcb_register_hit_for_lru
    │   │       │   │   │   └─ [ 11.07%] __GI___pthread_mutex_lock
    │   │       │   │   │       └─ [  5.34%] __lll_lock_wait
    │   │       │   │   ├─ [  7.75%] __pthread_mutex_unlock_usercnt
    │   │       │   │   │   └─ [  4.29%] __lll_unlock_wake
    │   │       │   │   ├─ [  0.25%] pgbuf_wakeup_reader_writer
    │   │       │   │   │   └─ [  0.25%] set_waiter_exists
    │   │       │   │   └─ [  0.21%] pgbuf_bcb_register_hit_for_lru
    │   │       │   ├─ [ 11.07%] __GI___pthread_mutex_lock
    │   │       │   │   └─ [  5.34%] __lll_lock_wait
    │   │       │   ├─ [  0.38%] pgbuf_unlatch_thrd_holder
    │   │       │   │   ├─ [  0.19%] pgbuf_remove_thrd_holder
    │   │       │   │   └─ [  0.34%] pgbuf_find_thrd_holder
    │   │       │   ├─ [  0.17%] perfmon_is_perf_tracking
    │   │       │   └─ [  0.22%] xdisk_get_purpose
    │   │       ├─ [  0.57%] mht_get2
    │   │       ├─ [  0.39%] spage_get_record
    │   │       │   └─ [  0.31%] spage_find_slot
    │   │       ├─ [  0.17%] pgbuf_ordered_set_dirty_and_free
    │   │       │   └─ [  0.48%] pgbuf_set_dirty
    │   │       │       └─ [  0.50%] pgbuf_set_dirty_buffer_ptr
    │   │       │           └─ [  0.34%] pgbuf_find_thrd_holder
    │   │       ├─ [  0.10%] spage_get_record@plt
    │   │       └─ [  0.23%] pgbuf_ordered_unfix
    │   │           └─ [  0.15%] pgbuf_remove_watcher
    │   ├─ [ 20.90%] lock_object
    │   │   ├─ [ 19.44%] lock_internal_perform_lock_object
    │   │   │   ├─ [ 12.33%] cubthread::lockfree_hashmap<lk_res_key, lk_res>::find_or_insert
    │   │   │   │   └─ [ 11.95%] lf_hash_insert_internal
    │   │   │   │       └─ [ 11.65%] lf_list_insert_internal
    │   │   │   │           ├─ [  6.46%] lock_res_key_compare
    │   │   │   │           ├─ [  8.50%] lf_freelist_claim
    │   │   │   │           │   ├─ [  6.76%] lf_freelist_alloc_block
    │   │   │   │           │   │   ├─ [ 14.87%] __GI___libc_malloc
    │   │   │   │           │   │   │   └─ [ 12.26%] _int_malloc
    │   │   │   │           │   │   │       ├─ [  9.37%] sysmalloc
    │   │   │   │           │   │   │       │   └─ [  8.25%] __GI___mprotect
    │   │   │   │           │   │   │       └─ [  0.30%] unlink_chunk.isra.2
    │   │   │   │           │   │   └─ [  3.09%] lock_alloc_resource
    │   │   │   │           │   │       └─ [ 11.55%] cub_alloc
    │   │   │   │           │   │           └─ [ 14.87%] __GI___libc_malloc
    │   │   │   │           │   │               └─ [ 12.26%] _int_malloc
    │   │   │   │           │   │                   ├─ [  9.37%] sysmalloc
    │   │   │   │           │   │                   │   └─ [  8.25%] __GI___mprotect
    │   │   │   │           │   │                   └─ [  0.30%] unlink_chunk.isra.2
    │   │   │   │           │   ├─ [  0.83%] lf_stack_pop
    │   │   │   │           │   │   └─ [  0.19%] ATOMIC_CAS_ADDR<void>
    │   │   │   │           │   └─ [  0.32%] ATOMIC_INC_32<int, int>
    │   │   │   │           └─ [ 11.07%] __GI___pthread_mutex_lock
    │   │   │   │               └─ [  5.34%] __lll_lock_wait
    │   │   │   ├─ [  8.50%] lf_freelist_claim
    │   │   │   │   ├─ [  6.76%] lf_freelist_alloc_block
    │   │   │   │   │   ├─ [ 14.87%] __GI___libc_malloc
    │   │   │   │   │   │   └─ [ 12.26%] _int_malloc
    │   │   │   │   │   │       ├─ [  9.37%] sysmalloc
    │   │   │   │   │   │       │   └─ [  8.25%] __GI___mprotect
    │   │   │   │   │   │       └─ [  0.30%] unlink_chunk.isra.2
    │   │   │   │   │   └─ [  3.09%] lock_alloc_resource
    │   │   │   │   │       └─ [ 11.55%] cub_alloc
    │   │   │   │   │           └─ [ 14.87%] __GI___libc_malloc
    │   │   │   │   │               └─ [ 12.26%] _int_malloc
    │   │   │   │   │                   ├─ [  9.37%] sysmalloc
    │   │   │   │   │                   │   └─ [  8.25%] __GI___mprotect
    │   │   │   │   │                   └─ [  0.30%] unlink_chunk.isra.2
    │   │   │   │   ├─ [  0.83%] lf_stack_pop
    │   │   │   │   │   └─ [  0.19%] ATOMIC_CAS_ADDR<void>
    │   │   │   │   └─ [  0.32%] ATOMIC_INC_32<int, int>
    │   │   │   ├─ [  0.41%] lock_initialize_entry_as_granted
    │   │   │   │   └─ [  0.69%] lock_event_set_xasl_id_to_entry
    │   │   │   │       └─ [  3.30%] LOG_FIND_TDES
    │   │   │   ├─ [  0.69%] lock_event_set_xasl_id_to_entry
    │   │   │   │   └─ [  3.30%] LOG_FIND_TDES
    │   │   │   ├─ [  0.64%] lock_find_class_entry
    │   │   │   │   ├─ [ 11.07%] __GI___pthread_mutex_lock
    │   │   │   │   │   └─ [  5.34%] __lll_lock_wait
    │   │   │   │   └─ [  7.75%] __pthread_mutex_unlock_usercnt
    │   │   │   │       └─ [  4.29%] __lll_unlock_wake
    │   │   │   ├─ [  0.30%] lock_insert_into_tran_hold_list
    │   │   │   │   └─ [ 11.07%] __GI___pthread_mutex_lock
    │   │   │   │       └─ [  5.34%] __lll_lock_wait
    │   │   │   ├─ [  7.75%] __pthread_mutex_unlock_usercnt
    │   │   │   │   └─ [  4.29%] __lll_unlock_wake
    │   │   │   ├─ [  0.11%] lock_escalate_if_needed
    │   │   │   └─ [ 11.07%] __GI___pthread_mutex_lock
    │   │   │       └─ [  5.34%] __lll_lock_wait
    │   │   ├─ [  0.61%] lock_get_class_lock
    │   │   │   ├─ [ 11.07%] __GI___pthread_mutex_lock
    │   │   │   │   └─ [  5.34%] __lll_lock_wait
    │   │   │   ├─ [  0.10%] logtb_get_current_tran_index
    │   │   │   │   └─ [  0.18%] thread_get_thread_entry_info
    │   │   │   │       └─ [  0.14%] cubthread::get_entry
    │   │   │   │           └─ [  0.26%] __tls_get_addr
    │   │   │   └─ [  7.75%] __pthread_mutex_unlock_usercnt
    │   │   │       └─ [  4.29%] __lll_unlock_wake
    │   │   ├─ [  0.64%] lock_find_class_entry
    │   │   │   ├─ [ 11.07%] __GI___pthread_mutex_lock
    │   │   │   │   └─ [  5.34%] __lll_lock_wait
    │   │   │   └─ [  7.75%] __pthread_mutex_unlock_usercnt
    │   │   │       └─ [  4.29%] __lll_unlock_wake
    │   │   └─ [  0.15%] logtb_find_wait_msecs
    │   │       └─ [  3.30%] LOG_FIND_TDES
    │   ├─ [ 17.67%] heap_log_insert_physical
    │   │   ├─ [ 27.75%] log_append_undoredo_crumbs
    │   │   │   ├─ [ 13.96%] prior_lsa_alloc_and_copy_crumbs
    │   │   │   │   ├─ [  9.86%] prior_lsa_gen_undoredo_record_from_crumbs
    │   │   │   │   │   ├─ [  4.42%] log_zip
    │   │   │   │   │   │   ├─ [  3.50%] LZ4_resetStream_fast
    │   │   │   │   │   │   │   └─ [  3.19%] __memset_evex_unaligned_erms
    │   │   │   │   │   │   └─ [  0.26%] __tls_get_addr
    │   │   │   │   │   ├─ [ 11.55%] cub_alloc
    │   │   │   │   │   │   └─ [ 14.87%] __GI___libc_malloc
    │   │   │   │   │   │       └─ [ 12.26%] _int_malloc
    │   │   │   │   │   │           ├─ [  9.37%] sysmalloc
    │   │   │   │   │   │           │   └─ [  8.25%] __GI___mprotect
    │   │   │   │   │   │           └─ [  0.30%] unlink_chunk.isra.2
    │   │   │   │   │   ├─ [  9.68%] __memmove_evex_unaligned_erms
    │   │   │   │   │   ├─ [  0.51%] prior_lsa_copy_redo_crumbs_to_node
    │   │   │   │   │   │   └─ [ 11.55%] cub_alloc
    │   │   │   │   │   │       └─ [ 14.87%] __GI___libc_malloc
    │   │   │   │   │   │           └─ [ 12.26%] _int_malloc
    │   │   │   │   │   │               ├─ [  9.37%] sysmalloc
    │   │   │   │   │   │               │   └─ [  8.25%] __GI___mprotect
    │   │   │   │   │   │               └─ [  0.30%] unlink_chunk.isra.2
    │   │   │   │   │   ├─ [  0.41%] prior_lsa_copy_undo_crumbs_to_node
    │   │   │   │   │   │   └─ [ 11.55%] cub_alloc
    │   │   │   │   │   │       └─ [ 14.87%] __GI___libc_malloc
    │   │   │   │   │   │           └─ [ 12.26%] _int_malloc
    │   │   │   │   │   │               ├─ [  9.37%] sysmalloc
    │   │   │   │   │   │               │   └─ [  8.25%] __GI___mprotect
    │   │   │   │   │   │               └─ [  0.30%] unlink_chunk.isra.2
    │   │   │   │   │   ├─ [  0.35%] log_diff
    │   │   │   │   │   ├─ [  0.30%] LOG_FIND_CURRENT_TDES
    │   │   │   │   │   │   └─ [  3.30%] LOG_FIND_TDES
    │   │   │   │   │   ├─ [  0.13%] log_zip@plt
    │   │   │   │   │   └─ [  0.12%] pgbuf_get_vpid_ptr
    │   │   │   │   ├─ [ 11.55%] cub_alloc
    │   │   │   │   │   └─ [ 14.87%] __GI___libc_malloc
    │   │   │   │   │       └─ [ 12.26%] _int_malloc
    │   │   │   │   │           ├─ [  9.37%] sysmalloc
    │   │   │   │   │           │   └─ [  8.25%] __GI___mprotect
    │   │   │   │   │           └─ [  0.30%] unlink_chunk.isra.2
    │   │   │   │   ├─ [  1.22%] prior_lsa_copy_redo_data_to_node
    │   │   │   │   │   ├─ [ 11.55%] cub_alloc
    │   │   │   │   │   │   └─ [ 14.87%] __GI___libc_malloc
    │   │   │   │   │   │       └─ [ 12.26%] _int_malloc
    │   │   │   │   │   │           ├─ [  9.37%] sysmalloc
    │   │   │   │   │   │           │   └─ [  8.25%] __GI___mprotect
    │   │   │   │   │   │           └─ [  0.30%] unlink_chunk.isra.2
    │   │   │   │   │   └─ [  9.68%] __memmove_evex_unaligned_erms
    │   │   │   │   ├─ [  4.42%] log_zip
    │   │   │   │   │   ├─ [  3.50%] LZ4_resetStream_fast
    │   │   │   │   │   │   └─ [  3.19%] __memset_evex_unaligned_erms
    │   │   │   │   │   └─ [  0.26%] __tls_get_addr
    │   │   │   │   └─ [  0.33%] prior_lsa_copy_undo_data_to_node
    │   │   │   │       └─ [ 11.55%] cub_alloc
    │   │   │   │           └─ [ 14.87%] __GI___libc_malloc
    │   │   │   │               └─ [ 12.26%] _int_malloc
    │   │   │   │                   ├─ [  9.37%] sysmalloc
    │   │   │   │                   │   └─ [  8.25%] __GI___mprotect
    │   │   │   │                   └─ [  0.30%] unlink_chunk.isra.2
    │   │   │   ├─ [ 15.04%] prior_lsa_next_record_internal
    │   │   │   │   ├─ [ 11.07%] __GI___pthread_mutex_lock
    │   │   │   │   │   └─ [  5.34%] __lll_lock_wait
    │   │   │   │   ├─ [  7.75%] __pthread_mutex_unlock_usercnt
    │   │   │   │   │   └─ [  4.29%] __lll_unlock_wake
    │   │   │   │   ├─ [  0.45%] prior_lsa_start_append
    │   │   │   │   │   └─ [  0.14%] log_tdes::is_system_worker_transaction
    │   │   │   │   ├─ [  0.37%] vacuum_get_log_blockid
    │   │   │   │   ├─ [  0.34%] __gthread_mutex_unlock
    │   │   │   │   ├─ [  0.25%] prior_lsa_append_data
    │   │   │   │   │   └─ [  0.12%] log_prior_lsa_append_align
    │   │   │   │   ├─ [  0.25%] log_prior_lsa_append_advance_when_doesnot_fit
    │   │   │   │   └─ [  0.13%] logpb_get_memsize
    │   │   │   ├─ [  0.39%] pgbuf_set_lsa
    │   │   │   │   └─ [  0.50%] pgbuf_set_dirty_buffer_ptr
    │   │   │   │       ├─ [  0.34%] pgbuf_find_thrd_holder
    │   │   │   │       └─ [  0.48%] pgbuf_set_dirty
    │   │   │   ├─ [  3.30%] LOG_FIND_TDES
    │   │   │   ├─ [  0.52%] logtb_find_client_type
    │   │   │   │   └─ [  3.30%] LOG_FIND_TDES
    │   │   │   ├─ [  0.27%] pgbuf_is_lsa_temporary
    │   │   │   │   └─ [  0.22%] xdisk_get_purpose
    │   │   │   └─ [  0.12%] log_can_skip_undo_logging
    │   │   └─ [  1.14%] heap_mvcc_log_insert
    │   │       ├─ [  0.78%] logtb_get_current_mvccid
    │   │       │   └─ [  3.30%] LOG_FIND_TDES
    │   │       ├─ [  0.30%] heap_page_get_vacuum_status
    │   │       │   └─ [  0.39%] spage_get_record
    │   │       │       └─ [  0.31%] spage_find_slot
    │   │       ├─ [  0.19%] heap_page_update_chain_after_mvcc_op
    │   │       └─ [  0.35%] or_header_size
    │   ├─ [ 10.70%] spage_insert_at
    │   │   ├─ [  9.25%] spage_insert_data
    │   │   │   ├─ [  9.68%] __memmove_evex_unaligned_erms
    │   │   │   └─ [  0.48%] pgbuf_set_dirty
    │   │   │       └─ [  0.50%] pgbuf_set_dirty_buffer_ptr
    │   │   │           └─ [  0.34%] pgbuf_find_thrd_holder
    │   │   └─ [  1.43%] spage_find_empty_slot_at
    │   │       ├─ [  1.13%] spage_check_space
    │   │       │   └─ [  1.51%] spage_has_enough_total_space
    │   │       │       ├─ [  2.01%] spage_get_total_saved_spaces
    │   │       │       │   └─ [  1.93%] spage_get_saved_spaces
    │   │       │       │       ├─ [  1.48%] lf_hash_find
    │   │       │       │       │   ├─ [  0.87%] lf_list_find
    │   │       │       │       │   └─ [  0.19%] lf_callback_vpid_hash
    │   │       │       │       └─ [  0.39%] logtb_find_tranid
    │   │       │       │           └─ [  3.30%] LOG_FIND_TDES
    │   │       │       └─ [  0.39%] logtb_find_tranid
    │   │       │           └─ [  3.30%] LOG_FIND_TDES
    │   │       └─ [  0.14%] spage_add_new_slot
    │   ├─ [  4.38%] pgbuf_unfix
    │   │   ├─ [  2.70%] pgbuf_unlatch_bcb_upon_unfix
    │   │   │   ├─ [  0.60%] pgbuf_unlatch_void_zone_bcb
    │   │   │   │   ├─ [  0.41%] pgbuf_lru_add_new_bcb_to_top
    │   │   │   │   │   └─ [  0.32%] pgbuf_lru_adjust_zones
    │   │   │   │   │       ├─ [  0.13%] pgbuf_lru_adjust_zone1
    │   │   │   │   │       │   └─ [  0.21%] pgbuf_bcb_change_zone
    │   │   │   │   │       │       └─ [  0.20%] ATOMIC_CAS_32<int, int, int>
    │   │   │   │   │       └─ [  0.13%] pgbuf_lru_fall_bcb_to_zone_3
    │   │   │   │   ├─ [  0.21%] pgbuf_bcb_register_hit_for_lru
    │   │   │   │   └─ [ 11.07%] __GI___pthread_mutex_lock
    │   │   │   │       └─ [  5.34%] __lll_lock_wait
    │   │   │   ├─ [  7.75%] __pthread_mutex_unlock_usercnt
    │   │   │   │   └─ [  4.29%] __lll_unlock_wake
    │   │   │   ├─ [  0.25%] pgbuf_wakeup_reader_writer
    │   │   │   │   └─ [  0.25%] set_waiter_exists
    │   │   │   └─ [  0.21%] pgbuf_bcb_register_hit_for_lru
    │   │   ├─ [ 11.07%] __GI___pthread_mutex_lock
    │   │   │   └─ [  5.34%] __lll_lock_wait
    │   │   ├─ [  0.38%] pgbuf_unlatch_thrd_holder
    │   │   │   ├─ [  0.19%] pgbuf_remove_thrd_holder
    │   │   │   └─ [  0.34%] pgbuf_find_thrd_holder
    │   │   ├─ [  0.17%] perfmon_is_perf_tracking
    │   │   └─ [  0.22%] xdisk_get_purpose
    │   ├─ [  0.51%] mvcc_is_mvcc_disabled_class
    │   ├─ [  0.78%] logtb_get_current_mvccid
    │   │   └─ [  3.30%] LOG_FIND_TDES
    │   └─ [  0.11%] heap_insert_adjust_recdes_header
    ├─ [  9.97%] locator_add_or_remove_index_internal
    │   ├─ [  3.26%] heap_get_class_name_alloc_if_diff
    │   │   ├─ [  1.15%] heap_scancache_end
    │   │   │   └─ [  1.14%] heap_scancache_quick_end
    │   │   │       ├─ [  4.38%] pgbuf_unfix
    │   │   │       │   ├─ [  2.70%] pgbuf_unlatch_bcb_upon_unfix
    │   │   │       │   │   ├─ [  0.60%] pgbuf_unlatch_void_zone_bcb
    │   │   │       │   │   │   ├─ [  0.41%] pgbuf_lru_add_new_bcb_to_top
    │   │   │       │   │   │   │   └─ [  0.32%] pgbuf_lru_adjust_zones
    │   │   │       │   │   │   │       ├─ [  0.13%] pgbuf_lru_adjust_zone1
    │   │   │       │   │   │   │       │   └─ [  0.21%] pgbuf_bcb_change_zone
    │   │   │       │   │   │   │       │       └─ [  0.20%] ATOMIC_CAS_32<int, int, int>
    │   │   │       │   │   │   │       └─ [  0.13%] pgbuf_lru_fall_bcb_to_zone_3
    │   │   │       │   │   │   ├─ [  0.21%] pgbuf_bcb_register_hit_for_lru
    │   │   │       │   │   │   └─ [ 11.07%] __GI___pthread_mutex_lock
    │   │   │       │   │   │       └─ [  5.34%] __lll_lock_wait
    │   │   │       │   │   ├─ [  7.75%] __pthread_mutex_unlock_usercnt
    │   │   │       │   │   │   └─ [  4.29%] __lll_unlock_wake
    │   │   │       │   │   ├─ [  0.25%] pgbuf_wakeup_reader_writer
    │   │   │       │   │   │   └─ [  0.25%] set_waiter_exists
    │   │   │       │   │   └─ [  0.21%] pgbuf_bcb_register_hit_for_lru
    │   │   │       │   ├─ [ 11.07%] __GI___pthread_mutex_lock
    │   │   │       │   │   └─ [  5.34%] __lll_lock_wait
    │   │   │       │   ├─ [  0.38%] pgbuf_unlatch_thrd_holder
    │   │   │       │   │   ├─ [  0.19%] pgbuf_remove_thrd_holder
    │   │   │       │   │   └─ [  0.34%] pgbuf_find_thrd_holder
    │   │   │       │   ├─ [  0.17%] perfmon_is_perf_tracking
    │   │   │       │   └─ [  0.22%] xdisk_get_purpose
    │   │   │       └─ [  0.23%] pgbuf_ordered_unfix
    │   │   │           └─ [  0.15%] pgbuf_remove_watcher
    │   │   ├─ [  0.80%] heap_get_class_record
    │   │   │   ├─ [  0.30%] heap_clean_get_context
    │   │   │   │   └─ [  0.21%] pgbuf_replace_watcher
    │   │   │   └─ [  0.26%] heap_get_last_version
    │   │   ├─ [  0.65%] cub_strdup
    │   │   │   ├─ [ 11.55%] cub_alloc
    │   │   │   │   └─ [ 14.87%] __GI___libc_malloc
    │   │   │   │       └─ [ 12.26%] _int_malloc
    │   │   │   │           ├─ [  9.37%] sysmalloc
    │   │   │   │           │   └─ [  8.25%] __GI___mprotect
    │   │   │   │           └─ [  0.30%] unlink_chunk.isra.2
    │   │   │   └─ [  0.23%] __strlen_evex
    │   │   ├─ [  0.27%] heap_scancache_quick_start_root_hfid
    │   │   │   └─ [  0.13%] boot_find_root_heap
    │   │   └─ [  0.12%] or_class_name
    │   ├─ [  3.09%] heap_attrinfo_end
    │   │   ├─ [  2.41%] heap_classrepr_free
    │   │   │   ├─ [ 11.07%] __GI___pthread_mutex_lock
    │   │   │   │   └─ [  5.34%] __lll_lock_wait
    │   │   │   └─ [  7.75%] __pthread_mutex_unlock_usercnt
    │   │   │       └─ [  4.29%] __lll_unlock_wake
    │   │   ├─ [  0.19%] heap_attrinfo_clear_dbvalues
    │   │   └─ [  0.13%] mspace_free
    │   ├─ [  1.79%] heap_attrinfo_read_dbvalues
    │   │   ├─ [  0.93%] heap_attrvalue_read
    │   │   │   ├─ [  0.54%] heap_attrvalue_point_fixed
    │   │   │   │   └─ [  0.18%] tp_domain_disk_size
    │   │   │   └─ [  0.18%] heap_attrvalue_transform_to_dbvalue
    │   │   ├─ [  0.34%] or_rep_id
    │   │   │   ├─ [  0.35%] or_header_size
    │   │   │   └─ [  0.18%] or_header_size@plt
    │   │   ├─ [  0.11%] pr_type_from_id
    │   │   └─ [  0.10%] heap_attrinfo_recache
    │   ├─ [  0.47%] heap_attrvalue_get_key
    │   │   └─ [  0.20%] heap_attrinfo_access
    │   ├─ [  1.90%] heap_attrinfo_start_with_index
    │   │   ├─ [  0.83%] heap_classrepr_get
    │   │   │   ├─ [ 11.07%] __GI___pthread_mutex_lock
    │   │   │   │   └─ [  5.34%] __lll_lock_wait
    │   │   │   ├─ [  7.75%] __pthread_mutex_unlock_usercnt
    │   │   │   │   └─ [  4.29%] __lll_unlock_wake
    │   │   │   └─ [  0.15%] __GI___pthread_mutex_trylock
    │   │   ├─ [  0.29%] heap_attrinfo_recache_attrepr
    │   │   │   └─ [  0.11%] db_value_domain_init
    │   │   └─ [  0.16%] hl_lea_alloc
    │   ├─ [  0.31%] btree_insert
    │   │   └─ [  0.11%] btree_mvcc_info_from_heap_mvcc_header
    │   ├─ [  0.78%] logtb_get_current_mvccid
    │   │   └─ [  3.30%] LOG_FIND_TDES
    │   ├─ [  0.51%] mvcc_is_mvcc_disabled_class
    │   ├─ [  0.52%] logtb_find_client_type
    │   │   └─ [  3.30%] LOG_FIND_TDES
    │   └─ [  0.14%] mvcc_is_mvcc_disabled_class@plt
    ├─ [  3.32%] locator_check_foreign_key
    │   ├─ [  1.90%] heap_attrinfo_start_with_index
    │   │   ├─ [  0.83%] heap_classrepr_get
    │   │   │   ├─ [ 11.07%] __GI___pthread_mutex_lock
    │   │   │   │   └─ [  5.34%] __lll_lock_wait
    │   │   │   ├─ [  7.75%] __pthread_mutex_unlock_usercnt
    │   │   │   │   └─ [  4.29%] __lll_unlock_wake
    │   │   │   └─ [  0.15%] __GI___pthread_mutex_trylock
    │   │   ├─ [  0.29%] heap_attrinfo_recache_attrepr
    │   │   │   └─ [  0.11%] db_value_domain_init
    │   │   └─ [  0.16%] hl_lea_alloc
    │   ├─ [  3.09%] heap_attrinfo_end
    │   │   ├─ [  2.41%] heap_classrepr_free
    │   │   │   ├─ [ 11.07%] __GI___pthread_mutex_lock
    │   │   │   │   └─ [  5.34%] __lll_lock_wait
    │   │   │   └─ [  7.75%] __pthread_mutex_unlock_usercnt
    │   │   │       └─ [  4.29%] __lll_unlock_wake
    │   │   ├─ [  0.19%] heap_attrinfo_clear_dbvalues
    │   │   └─ [  0.13%] mspace_free
    │   ├─ [  1.79%] heap_attrinfo_read_dbvalues
    │   │   ├─ [  0.93%] heap_attrvalue_read
    │   │   │   ├─ [  0.54%] heap_attrvalue_point_fixed
    │   │   │   │   └─ [  0.18%] tp_domain_disk_size
    │   │   │   └─ [  0.18%] heap_attrvalue_transform_to_dbvalue
    │   │   ├─ [  0.34%] or_rep_id
    │   │   │   ├─ [  0.35%] or_header_size
    │   │   │   └─ [  0.18%] or_header_size@plt
    │   │   ├─ [  0.11%] pr_type_from_id
    │   │   └─ [  0.10%] heap_attrinfo_recache
    │   └─ [  0.12%] heap_attrinfo_read_dbvalues@plt
    └─ [  0.17%] heap_create_insert_context

# orphan (root 경로에 등장하나 트리 도달 불가, >= 0.1%):
  - [  0.16%] lf_tran_start
  - [  0.13%] spage_get_record_data
  - [  0.13%] cubpl::session::is_thread_involved
  - [  0.13%] pthread_mutex_lock@plt
  - [  0.11%] pgbuf_get_holder
  - [  0.11%] prm_get_integer_value
  - [  0.10%] perfmon_add_stat
  - [  0.10%] perfmon_inc_stat
```
