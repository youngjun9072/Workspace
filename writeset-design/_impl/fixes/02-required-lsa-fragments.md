---
tags: [CBRD-27508, applier, archive, 분석]
---
# required_lsa가 미retire 조각 태스크를 보지 않아 필요한 아카이브가 지워질 수 있는 문제

작성: 2026-10-15. 코드 TODO(`la_find_required_lsa` 머리 주석)에서 출발. 코드는 별도 커밋 2a8d1e9cc로 올린 뒤 10-15 승인으로 slave 커밋 8a89220be에 접힘(미빌드·미검증). todo: `todo/CBRD-27508 - required_lsa 미retire 조각 누락`.

**2026-10-16 접힘**: slave 커밋 68dedb13c(해시 변경). 이 수정이 드러낸 재시작 결함은 07. 빌드·배포 전.

줄 번호는 수정 전 코드 기준(`log_applier.c`는 접기 전 slave 커밋 178a68de8 시점). 마지막 절의 수정 코드만 수정 후 줄 번호.

## 한 줄 요약

slave는 "아직 읽어야 할 가장 오래된 로그 위치"(`required_lsa`)를 `repl_lists` 슬롯만 보고 계산하는데, 라벨 붙은 SYSOP_END에서 떼어낸 조각 태스크는 슬롯 밖의 별도 `LA_APPLY`에 산다. 바깥 트랜잭션이 ABORT되면 바깥 슬롯이 조각보다 먼저 비워져 조각의 항목 위치가 계산에서 빠지고, 그 위치가 든 아카이브가 삭제될 수 있다.

## 발생 조건

1. master가 라벨을 붙인 SYSOP_END를 품은 트랜잭션(serial INCR/DECR, checksumdb, writeset 폴백 등)이 slave에서 조각 태스크로 분리됨
2. 그 트랜잭션이 ROLLBACK
3. ABORT 처리 시점에 조각이 아직 pending, 워커 큐, 적용 중
4. slave가 밀려 있어 아카이브 삭제가 일어나는 상황

10-14 테스트들은 4가 없어(지연 수초) 걸리지 않았다. 백로그 테스트에서 걸릴 수 있다.

## 단계별 코드

### 단계 1. required_lsa를 누가 쓰나

`src/transaction/log_applier.c` → `la_remove_archive_logs` → 9058~9078행

```c
9066    int required_arv_num = -1;
9071    if (LA_LOG_IS_IN_ARCHIVE (la_Info.required_lsa.pageid))
9073        error = la_find_archive_num (&required_arv_num, la_Info.required_lsa.pageid);
9078        max_arv_count = MAX (log_max_archives, nxarv_num - required_arv_num);
```

- `required_arv_num`: required_lsa가 든 아카이브 번호. `max_arv_count`: 남겨 둘 개수. 그보다 오래된 아카이브를 지운다.
- required_lsa가 실제 필요 위치보다 **높으면** 필요한 아카이브가 지워진다. 낮으면 디스크만 더 쓴다.

### 단계 2. required_lsa를 계산하는 함수

`log_applier.c` → `la_find_required_lsa` → 2575~2602행 (`la_log_commit` 8096행에서 호출, 결과는 `la_Info.required_lsa`)

```c
2583    for (i = 0; i < la_Info.cur_repl; i++)
2585        if (la_Info.repl_lists[i]->tranid <= 0)
2587            continue;
2589        if (LSA_ISNULL (&lowest_lsa) || LSA_GT (&lowest_lsa, &la_Info.repl_lists[i]->start_lsa))
2591            LSA_COPY (&lowest_lsa, &la_Info.repl_lists[i]->start_lsa);
2595    if (LSA_ISNULL (&lowest_lsa))
2597        LSA_COPY (required_lsa, &la_Info.final_lsa);
2599    else
2601        LSA_COPY (required_lsa, &lowest_lsa);
```

- `repl_lists[]`: 트랜잭션별 슬롯 배열. `start_lsa`는 그 트랜잭션의 첫 복제 항목 위치.
- "사용 중 슬롯의 start_lsa 최솟값"이 required_lsa. 2583행 for문은 **이 배열만** 돈다.

참고: 1000항목이 넘는 트랜잭션(`la_set_repl_log` 4521행 `LA_MAX_REPL_ITEMS`)은 항목을 메모리에 두지 않고 적용 때 로그에서 다시 읽으므로(`la_get_next_repl_item_from_log`), required_lsa가 그 페이지를 지켜 주는 것이 더 중요하다. 이것은 조각과 별개의 메커니즘이다.

### 단계 3. 슬롯 밖으로 나가는 항목: SYSOP_END 조각

master `src/transaction/log_manager.c` 4042~4055행: 트랜잭션 안의 시스템 연산이 끝날 때 복제 항목을 들고 있으면 SYSOP_END에 라벨을 붙인다.

```c
4042  if (log_record->type == LOG_SYSOP_END_COMMIT && repl_item_count > 0)
4054      sysop_commit_order = true;
4055      log_append_wset_label_and_sysop_end (thread_p, tdes, log_record, data_size, data, &sysop_lsa);
```

slave `log_applier.c` → `la_coordinator_process_sysop_end`(라벨 있고 항목 있으면) → `la_detach_sysop_fragment` → 7337~7383행

```c
7350    fragment = (LA_APPLY *) malloc (DB_SIZEOF (LA_APPLY));     /* repl_lists 밖의 새 LA_APPLY */
7370    fragment->head = outer->head;                              /* 항목을 통째로 옮김 */
7375    LSA_COPY (&fragment->start_lsa, &fragment->head->lsa);
7377    outer->head = NULL;                                        /* 바깥 슬롯은 비움 */
7381    LSA_SET_NULL (&outer->last_lsa);                           /* start_lsa 는 그대로 둠 */
```

- 항목은 `fragment`로 옮겨져 단계 2의 for문이 보지 않는 곳에 있다.
- 다만 `outer->start_lsa`는 건드리지 않으므로, **바깥 슬롯이 살아 있는 동안은** 단계 2가 그 위치를 계속 "필요"로 잡는다.

### 단계 4. ABORT가 바깥 슬롯을 조각보다 먼저 비운다

`log_applier.c` → `la_log_record_process`의 `LOG_ABORT` → `la_free_repl_items_by_tranid` → 4578~4587행

```c
4583    apply = la_find_apply_list (tranid);
4584    if (apply)
4586        la_clear_applied_info (apply);        /* tranid = 0, start_lsa = NULL */
```

| 순서 | master 로그 | slave 코디네이터 | 조각 F |
|---|---|---|---|
| ① | 트랜잭션 T 시작, serial 갱신 항목 | 바깥 슬롯 잡음, `start_lsa = L1` | |
| ② | 라벨 붙은 SYSOP_END | 단계 3: 항목을 F로 떼어 디스패치. 바깥 슬롯 `start_lsa = L1` 유지 | 적용 중 (항목 L1~) |
| ③ | T ROLLBACK → LOG_ABORT | **바깥 슬롯 초기화** | 아직 pending·큐·적용 중일 수 있음 |
| ④ | | `la_log_commit` → 단계 2: L1 사라짐 → required_lsa가 L1 뒤로 | F는 L1부터 필요 |
| ⑤ | | 단계 1: required 앞 아카이브 삭제 | F가 항목 페이지를 못 읽음 |

정상 커밋에서는 바깥 커밋 태스크가 F에 의존해 F retire 뒤에 retire되고, 바깥 슬롯은 그때 `la_coordinator_release_apply_slot`에서 비워지므로 이 틈이 없다. ABORT만 "조각이 남아 있는데 바깥을 먼저 비우는" 경로다.

### 단계 5. 조각은 그동안 어디에 있나

retire 전까지 F는 반드시 둘 중 하나에 있다.

**in-flight list** (워커에 넘긴 순서 링). `log_applier.c` 863행 `la_inflight_push (task.apply, ...)` → `log_applier_inflight.cpp` 114~140행

```c
125    entry = &la_Inflight.entries[la_Inflight.tail];
127    entry->apply = apply;             /* 조각이면 단계 3의 LA_APPLY */
129    entry->rectype = rectype;         /* LOG_SYSOP_END */
```

큐 대기, 적용 중, 적용 끝났지만 retire 전이 모두 여기 있다. retire(`la_inflight_pop`) 때 빠진다.

**pending** (의존 때문에 아직 못 넘긴 태스크). `log_applier_pending.cpp` 58~85행

```c
20   static LA_PENDING_NODE *la_Pending_head = NULL;
71     node->task = *task;               /* task.apply 가 F */
```

게이트를 통과하면 `la_pending_pop_ready`로 빠져 in-flight list로 간다.

두 구조 모두 코디네이터 스레드만 읽고 쓰는 파일 안 `static`이고, F의 `start_lsa`는 단계 3에서 한 번 쓰인 뒤 바뀌지 않는다.

## 왜 문제인가

1. required_lsa는 "살아 있는 모든 태스크의 항목 위치 최솟값"이어야 하는데, 계산이 `repl_lists` 슬롯만 보므로 슬롯 밖에 사는 조각은 바깥 슬롯이 대신 지켜 줄 때만 안전하다.
2. ABORT 처리가 바깥 슬롯을 즉시 비우므로 그 보호가 조각보다 먼저 사라진다. 그 순간 required_lsa가 조각의 항목 위치를 지나칠 수 있다.
3. 결과는 아카이브 삭제 뒤 워커가 항목 페이지를 읽지 못하는 적용 실패다. 조건이 네 개 겹쳐야 해서 빈도는 낮지만, 백로그가 있는 운영 상황에서 serial 갱신을 품은 트랜잭션의 ROLLBACK은 드문 일이 아니다.
4. `LA_APPLY`의 정의가 `log_applier.c` 안에만 있고 장부 모듈에는 전방 선언뿐이라, 장부 쪽에서 `start_lsa`를 직접 읽는 접근자는 만들 수 없다. 장부는 엔트리를 넘겨주고 계산은 `log_applier.c`가 해야 한다.

## 해결 방안

### 채택: 두 장부를 required_lsa 계산에 포함

새 자료구조나 상태는 없다. 기존 두 구조에 읽기 전용 순회 함수를 하나씩 열고, `la_find_required_lsa`가 그 둘도 훑는다. 별도 커밋 2a8d1e9cc(접힌 뒤 8a89220be), 수정 후 줄 번호.

`log_applier_inflight.cpp` 218행 (헤더 선언 추가)

```c
LA_INFLIGHT_ENTRY *
la_inflight_entry_at (int pos)
{
  if (pos < 0 || pos >= la_Inflight.count)
    {
      return NULL;
    }

  return &la_Inflight.entries[(la_Inflight.head + pos) % la_Inflight.capacity];
}
```

`log_applier_pending.cpp` 149행 (헤더 선언 추가)

```c
void
la_pending_foreach (void (*fn) (const LA_TASK * task, void *arg), void *arg)
{
  LA_PENDING_NODE *node;

  for (node = la_Pending_head; node != NULL; node = node->next)
    {
      fn (&node->task, arg);
    }
}
```

`log_applier.c` 2566행 `la_lower_lsa`(최솟값 갱신 보조), 2580행 `la_lower_lsa_by_pending_task`(pending 콜백), 2601행 `la_find_required_lsa`

```c
2612  for (i = 0; i < la_Info.cur_repl; i++)
2614      if (la_Info.repl_lists[i]->tranid <= 0) continue;
2617      la_lower_lsa (&lowest_lsa, &la_Info.repl_lists[i]->start_lsa);
2619  for (i = 0; (entry = la_inflight_entry_at (i)) != NULL; i++)
2621      if (entry->apply != NULL)
2623          la_lower_lsa (&lowest_lsa, &entry->apply->start_lsa);
2627  la_pending_foreach (la_lower_lsa_by_pending_task, &lowest_lsa);
```

동작(단계 4의 표):
- ③에서 바깥 슬롯이 비워져도 F는 in-flight list나 pending에 있으므로 2619·2627행이 `F->start_lsa = L1`을 후보에 넣는다. required_lsa는 L1에 머문다.
- F가 retire되면 장부에서 빠지고 F가 free되므로 그때 required_lsa가 앞으로 나간다. "아직 필요한 가장 오래된 위치"가 된다.
- 일반 커밋 엔트리의 `apply`는 `repl_lists` 슬롯이라 중복으로 세지만 최솟값에는 영향이 없다. 항목 없는 커밋은 `apply == NULL`로 건너뛴다.
- 비용: `la_log_commit`마다(500ms 간격) in-flight list 길이(워커 수 × 큐 용량) + pending 길이만큼 포인터 비교.
- 스레드: 세 구조와 `start_lsa` 모두 코디네이터 전용. 콜백은 순회 중 push/pop을 하지 않는다.

### 대안: ABORT 때 조각이 남아 있으면 바깥 슬롯을 지우지 않고 기다리기

바깥 슬롯에 미완 조각 수를 세는 카운터를 두고, 떼어낼 때 +1, 조각 retire 때 −1, ABORT는 0일 때만 비우고 아니면 표시만 남긴 뒤 마지막 조각 retire 때 비운다.

- 계산 함수는 그대로지만 손대는 곳이 셋(떼어내기, retire, ABORT)이고 서로 떨어져 있어 카운터가 어긋나면 슬롯 누수나 원래 결함이 된다. retire 쪽에서 `la_find_apply_list(tranid)`로 바깥 슬롯을 다시 찾아야 하는데 그 사이 tranid가 재사용되면 엉뚱한 슬롯을 건드린다. "비어 있지만 살아 있는" 제3의 슬롯 상태가 생겨 `la_is_repl_lists_empty` 등 슬롯을 세는 코드가 모두 그 상태를 알아야 한다.
- 결함의 본질이 "계산이 살아 있는 항목을 전부 보지 않는다"이므로, 슬롯 생존 규칙에 예외를 만드는 우회보다 계산을 직접 고치는 채택안을 택했다.

### 범위 밖

ABORT된 트랜잭션의 조각을 slave가 이미 적용해 버린 상태 자체(미구현 목록 2-3 "abort 유실")는 이 수정이 다루지 않는다. 이 수정은 "읽을 페이지가 사라지는" 문제만 막는다.

## 적용 상태와 검증

- 코드: 별도 커밋 2a8d1e9cc → 사용자 승인(10-15) 뒤 slave 커밋 8a89220be에 접힘(cs HEAD ae8a6acba). 번역 단위 3개 컴파일 통과. 빌드·배포·실측 전.
- 검증(백로그 테스트): serial 갱신을 품은 트랜잭션을 조각이 나뉘도록 보내고 ROLLBACK, 그 사이 slave applylogdb를 멈춰 백로그를 만든 뒤 재개한다. 아카이브 삭제가 일어나도 조각 적용이 실패하지 않아야 하고, applylogdb 로그의 `lowest required page id` 값이 조각 retire 전까지 조각의 start_lsa 페이지에 머물러야 한다.

## 이 수정이 드러낸 결함 (2026-10-16)

pending 순회를 넣으면서, 같은 프로세스 안 재시작 때 이전 실행의 pending 태스크(해제된 슬롯 포인터)가 required_lsa 계산에 들어와 0|0이 저장되는 결함이 생겼다. 원인과 수정은 [07-inprocess-restart-state](./07-inprocess-restart-state.md).

## 로깅·assert (커밋 3924469c6)

- `la_find_required_lsa`가 슬롯 최솟값과 태스크(in-flight list·pending) 최솟값을 따로 구해, 태스크 쪽이 더 낮을 때(= 바깥 ABORT 뒤 살아 있는 조각) trace 1에 `[WSET] coordinator required_lsa held by unretired task at P|O (slots from P|O)`를 남긴다. 이 줄이 보이면 이 수정이 실제로 일한 것이다.
- assert: 결과가 `final_lsa`를 넘지 않는다(워커가 읽을 항목은 코디네이터가 읽은 위치 이전에 있다).

## 상세 설계용 요약 (8-2.6 완료 경계 또는 7장 LSA 관리에 넣을 후보)

### 왜 이런 처리가 필요한가

1. **`required_lsa`는 재구성에 필요한 로그 하한이다.** 직렬 applier에서는 적용 중인 트랜잭션이 항상 `repl_lists` 슬롯에 있었으므로 슬롯의 최솟값이 곧 하한이었다.
2. **병렬 applier는 적용 단위가 슬롯과 1:1이 아니다.** 라벨 붙은 SYSOP_END는 트랜잭션 중간에 독립 태스크(조각)로 분리되어 바깥 커밋보다 먼저 적용되며, 조각은 자기 슬롯을 따로 가진다. 그 슬롯은 `repl_lists`가 아니라 코디네이터의 두 장부(pending, in-flight list)가 쥔다.
3. **슬롯의 생존과 태스크의 생존이 어긋나는 경로가 있다.** 바깥 트랜잭션의 ABORT는 바깥 슬롯을 즉시 비우지만 분리된 조각은 계속 산다. 하한 계산이 슬롯만 보면 이 경로에서 조각의 항목 위치를 잃는다.
4. 따라서 **하한은 "살아 있는 모든 태스크"에서 계산해야 하며**, 살아 있는 태스크의 집합은 슬롯 배열이 아니라 pending과 in-flight list다. 두 장부는 코디네이터 전용이므로 순회에 동기화가 필요 없다.

### 설계 요구사항

- coordinator는 `required_lsa`를 `repl_lists` 슬롯, pending 태스크, in-flight list 엔트리가 가리키는 모든 슬롯의 `start_lsa` 최솟값으로 계산해야 한다.
- 분리된 조각의 슬롯은 조각 태스크가 retire될 때까지 두 장부 중 하나에 남아 있어야 한다.
- 슬롯의 `start_lsa`는 슬롯이 만들어질 때 정해지고 retire 전에는 바꾸면 안 된다.
- 아카이브 삭제는 `required_lsa`가 든 아카이브와 그 이후만 남기는 기존 규칙을 유지해야 한다(기존 용어 정의의 `required_lsa`).
