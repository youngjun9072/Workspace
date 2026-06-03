# 복제 적용 콜체인 (소스 구조 + 측정 inclusive %)

슬레이브 `cub_server` 가 master `applylogdb` 의 복제 force 요청을 적용하는 경로.
**구조는 소스 코드(authoritative), 각 노드 옆 % 는 on-CPU perf 의 inclusive 비중(% of total sample)** 이다.
INSERT 캡처(147,236 sample) / UPDATE 캡처(126,337 sample) 두 측정을 나란히 표기.

> ⚠ **상위 노드(`slocator_repl_force`, `xlocator_repl_force`) % 는 undercount.**
> `--call-graph dwarf`(8KB) 스택 스냅샷이 깊고 큰 write 프레임에서 소진돼, leaf 가 write 깊숙이 있을 때
> 상위 프레임이 잘린다. 그래서 부모(`xlocator` 3.79%)가 자식(`locator_insert_force` 29.78%)보다 작게 찍힌다.
> **leaf 쪽 force/heap/log % 는 정확**, 상위 RPC 프레임 % 만 실제보다 낮다. (구조 연결 자체는 소스로 확정)

파일 참조: 함수 정의는 `cubrid/src/transaction/locator_sr.c`, 서버 stub 은 `cubrid/src/communication/network_interface_sr.cpp`.

---

## 콜체인 (구조=소스, `[INS% | UPD%]` = inclusive % of total)

```
slocator_repl_force                                   [ 6.41%⚠ | 17.78%⚠]  network_interface_sr.cpp:1223
│   (NET_SERVER_LC_REPL_FORCE 수신 → 적용 → 응답)
├─ locator_recv_allocate_copyarea                     수신 버퍼 할당
├─ css_receive_data_from_client(_with_timeout)        [ 0.29% |  0.35%]  force_area(변경 row 묶음) 수신
├─ locator_unpack_copy_area_descriptor                obj 메타 언팩
│
├─ xlocator_repl_force                                [ 3.79%⚠ | 15.08%⚠]  locator_sr.c:6927
│  ├─ xtran_server_start_topop (바깥 topop)           [ 0.64% |  0.58%]  묶음 전체 원자화
│  │
│  └─ for (i in num_objs)  ── row 하나씩 ──
│     ├─ locator_repl_get_key_value                   [ 0.01% |  0.01%]  PK 키 언팩
│     ├─ heap_get_class_info → heap_hfid_cache_get    [ 0.44% |  0.53%]  클래스/HFID
│     ├─ locator_start_force_scan_cache               (HFID 바뀔 때만 재생성)
│     │     └─ heap_scancache_start_modify            [ 0.30% |  0.34%]
│     ├─ xtran_server_start_topop (row topop)
│     │
│     ├─ locator_repl_prepare_force                   [ 0.01% |  2.88%]  locator_sr.c:6811
│     │  ├─ heap_get_class_repr_id                    [ 0.62% |  0.92%]  (DELETE 는 skip)
│     │  ├─ ❰INSERT 아님❱ btree_get_pkey_btid         [   -   |  0.30%]
│     │  │     └─ xbtree_find_unique                  [ 0.00% |  8.69%] ★ PK→기존 OID 조회 (UPDATE/DELETE 만)
│     │  └─ ❰UPDATE❱ heap_get_visible_version         [ 0.00% |  1.56%]  old_recdes 확보
│     │
│     ├─ switch (obj->operation)                      locator_sr.c:7022  ─── 연산 분기 ───
│     │  ├─ LC_FLUSH_INSERT*  → locator_insert_force  [29.78% |  0.02%]  :7029   ▼아래 write-tree
│     │  ├─ LC_FLUSH_UPDATE*  → locator_update_force  [ 0.02% | 22.96%]  :7045   ▼아래 write-tree
│     │  └─ LC_FLUSH_DELETE   → locator_delete_force  [   -   |    -  ]  :7057
│     │        (+ 성공 시 perfmon_inc_stat: NUM_INSERTS/UPDATES/DELETES)
│     │
│     └─ xtran_server_end_topop (row: 성공 ATTACH_TO_OUTER / 실패 ABORT)
│  └─ xtran_server_end_topop (바깥)                   [ 1.32% |  1.37%]
│
└─ css_send_reply_and_2_data_to_client                [ 1.16% |  1.17%]  적용 결과 응답
   (+ css_request_release_packet                      [ 1.18% |  1.01%])
```

### 분기 요약 (insert ↔ update ↔ delete)

| 연산 | prepare 사전작업 | force 함수 | 특징 |
|---|---|---|---|
| **INSERT** | (기존 row 조회 없음) | `locator_insert_force` | 바로 삽입. PK 조회 skip |
| **UPDATE** | `xbtree_find_unique`(PK→OID) + `heap_get_visible_version`(old) | `locator_update_force` | 기존 row 찾고 갱신 |
| **DELETE** | `xbtree_find_unique`(PK→OID) | `locator_delete_force` | 기존 row 찾고 삭제 |

→ **`xbtree_find_unique` 가 UPDATE 캡처에서 8.69%** 로 큰 이유 = UPDATE/DELETE 만 거치는 PK 조회.
INSERT 는 이 단계를 건너뛰어 0% (분기가 perf 와 정확히 일치).

---

## write-tree (switch leaf 아래, perf 로 정확히 측정된 부분)

상위와 달리 leaf~write 구간은 안 잘려서 측정 구조·% 가 정확하다. 전문은 각 캡처의
`analysis/calltree_root.txt` 참조. 상위 골격만:

### INSERT — `locator_insert_force` [29.78%]
```
locator_insert_force                       [29.78%]
├─ heap_insert_logical                     [25.66%]
│  ├─ heap_get_insert_location_with_lock → heap_stats_find_best_page  [11.94%] (free space)
│  │     └─ heap_vpid_alloc → file_alloc
│  ├─ heap_log_insert_physical             [11.44%]
│  │     └─ log_append_undoredo_crumbs     [19.52%]
│  │           └─ prior_lsa_alloc_and_copy_crumbs [15.92%] → prior_lsa_gen.. [12.09%] → log_zip / malloc
│  ├─ lock_object → lockfree_hashmap::find_or_insert  (insert 위치 lock)
│  └─ spage_insert_at
└─ locator_add_or_remove_index_internal    (인덱스 갱신)
```

### UPDATE — `locator_update_force` [22.96%]
```
locator_update_force                       [22.96%]
└─ heap_update_logical                     [→ heap_log_update_physical 22.00%]
   └─ log_append_undoredo_recdes(2)        [26.25 / 27.13%]
        └─ log_append_undoredo_crumbs      [27.14%]
              └─ prior_lsa_alloc_and_copy_crumbs [25.78%]
                    ├─ log_diff            (redo diff, update 전용)
                    └─ log_zip / __memmove / malloc
   (+ spage_update → spage_compact, 가변길이 compaction)
```

---

## 읽는 법 요약

1. **콜 구조(누가 누구를 부르나)** = 위 트리, 소스 기준 — 정확.
2. **CPU 무게** = `[INS% | UPD%]` inclusive(% of total).
   - leaf/ write 구간(`locator_*_force` 이하) % → **정확**.
   - 상위 `slocator/xlocator_repl_force` % → **undercount**(truncation). 복제 적용의 실제 CPU 무게는
     상위 6~18% 가 아니라 **각 force leaf subtree 합**(INSERT≈29.8%+, UPDATE≈23%+)으로 읽어야 함.
3. 측정값까지 상위-하위가 한 분모로 정확히 연결된 트리를 원하면 `--call-graph dwarf,65528` 또는 `fp` 로 **재측정** 필요.
