---
tags: [CBRD-27508, applier, restart, fixes]
---
# 프로세스 안 재시작이 이전 실행의 pending 태스크와 gate frontier를 물려받는 문제

작성: 2026-10-16. 재시작 테스트 케이스 2(slave cub_server kill) 3회차에서 `required_lsa = 0|0` 저장 → applylogdb 기동 실패 반복(699회)으로 드러남. 코드는 별도 커밋 4ba248708(컴파일만 확인, 빌드·배포·실측 전, 접기는 승인 뒤). todo: `todo/CBRD-27508 - 재시작 뒤 required_lsa 0|0 크래시 루프`.

**2026-10-16 접힘**: 별도 커밋 4ba248708 → slave 커밋 68dedb13c. 빌드·배포 전, 케이스 2 반복 검증 전.

줄 번호는 수정 전 코드 기준(커밋 c2fd1022b 시점). 마지막 절의 수정 코드만 수정 후 내용.

## 한 줄 요약

slave 서버가 죽으면 applylogdb는 프로세스를 끝내지 않고 같은 프로세스 안에서 `la_apply_log_file`을 다시 시작할 수 있다. 이때 `la_Info`는 새로 초기화되지만 pending 목록과 gate frontier는 파일 static이라 이전 실행의 값이 남는다. 남은 pending 태스크는 `la_shutdown`이 free한 슬롯을 가리키므로, 새 실행의 `la_find_required_lsa`가 해제된 메모리의 `start_lsa`를 읽어 0|0을 `_db_ha_apply_info`에 저장했다. 이후 모든 기동이 로그 페이지 0을 찾다 실패한다.

이 결함은 develop에는 없다. [02-required-lsa-fragments](./02-required-lsa-fragments.md)에서 `la_find_required_lsa`가 pending 목록도 훑게 바꾸면서, 남아 있던 pending 태스크가 required_lsa 계산에 들어오게 됐다.

## 발생 조건

- slave cub_server가 죽는다(kill -9, 비정상 종료).
- 그 순간 coordinator의 pending 목록에 의존 때문에 보관된 태스크가 있다.
- applylogdb가 서버 다운 오류로 `la_apply_log_file`에서 빠져나온 뒤, cub_master가 프로세스를 내리기 전에 서버가 다시 떠서 같은 프로세스의 재시도가 접속에 성공한다.

케이스 2에서 1·2회차는 applier 프로세스가 새로 떠서(새 pid) 걸리지 않았고, 3회차만 같은 pid가 재시도해 걸렸다.

## 단계별 코드

### 단계 1. applylogdb는 같은 프로세스 안에서 다시 시작한다

`util_cs.c` → `applylogdb`. `la_apply_log_file`이 서버 다운 계열 오류로 돌아오면 sleep 뒤 `retry:`로 돌아가 `db_restart`부터 다시 한다. 프로세스는 그대로다.

```c
3502 retry:
...
3547   error = la_apply_log_file (database_name, log_path, max_mem_size);
...                                  /* error_exit: 서버 다운 계열이면 */
3584       need_er_reinit = true;
3586       goto retry;
```

재시도 뒤 `er_init`이 다시 불려 로그가 `cub_client.err`로 간다. 그래서 applylogdb 로그(`*_applylogdb_*.err`)에는 재시도한 실행의 줄이 남지 않는다.

### 단계 2. 종료 때 슬롯은 free되지만 pending 목록은 남는다

`log_applier.c` → `la_shutdown` (8667). 워커를 멈춘 뒤 `repl_lists` 슬롯을 모두 free한다.

```c
8671   la_stop_apply_workers ();
...
8739           free_and_init (la_Info.repl_lists[i]);
```

pending 목록은 `log_applier_pending.cpp`의 파일 static이다. 비우는 함수가 없다.

```c
49 static LA_PENDING_NODE *la_Pending_head = NULL;
50 static LA_PENDING_NODE *la_Pending_tail = NULL;
```

pending 노드는 태스크를 복사해 들고 있고, 태스크의 `apply`는 coordinator가 미리 붙여 둔 `repl_lists` 슬롯 포인터다(`log_applier_task.hpp` 44행 `LA_APPLY *apply;`). 종료 뒤 이 포인터는 해제된 메모리를 가리킨다.

### 단계 3. 새 실행은 la_Info만 초기화한다

`la_apply_log_file` → `la_init` (8569)이 `memset (&la_Info, 0, ...)`(8574)로 `la_Info`를 초기화하고, `la_coordinator_init_resources` (1487)가 태스크 큐, 결과 큐, in-flight list, gate ring을 다시 만든다. pending 목록과 gate frontier는 아무도 건드리지 않는다.

### 단계 4. required_lsa 계산이 해제된 슬롯을 읽는다

`la_log_commit` (8195) → `la_find_required_lsa` (2602).

```c
2631   la_pending_foreach (la_lower_lsa_by_pending_task, &task_lowest);   /* 남은 태스크의 task->apply->start_lsa */
...
2655       LSA_COPY (required_lsa, &lowest_lsa);
```

`la_lower_lsa` (2567)는 NULL(-1|-1)만 걸러내므로 해제된 메모리에서 읽힌 0|0은 최솟값으로 채택된다. `la_coordinator_commit_apply_info` (1562)가 이 값을 `_db_ha_apply_info`에 저장한다. 해제된 메모리에서 0|0이 읽힌 것은 malloc 재사용 상태에 달린 값이다(추정). 해제된 포인터를 읽는다는 것 자체는 코드로 확인했다.

남은 태스크는 gate가 통과시키면 `la_pending_pop_ready` (98)로 워커에 넘어가 해제된 슬롯으로 적용될 수도 있다. 실측에서 0|0 저장 2초 뒤 같은 프로세스가 죽었다(추정: 이 경로).

### 단계 5. gate frontier도 남는다

`log_applier_gate.cpp`의 `la_Gate_frontier`(56)도 파일 static이다. `la_gate_init` (75)은 ring만 다시 만들고 frontier는 두며, 79행 `assert (la_Gate_order_count == 0)`는 이전 실행의 ring이 비어 있다고 가정한다.

`la_gate_set_initial_frontier` (120)는 frontier가 NULL일 때만 재시작 지점을 넣는다.

```c
124   if (!LSA_ISNULL (&la_Gate_frontier))
125     {
126       return;                          /* 이전 실행의 frontier가 남아 있으면 새 재시작 지점을 무시 */
127     }
```

새 실행은 저장된 committed_lsa(C)부터 다시 읽는다. committed_lsa는 일정 간격으로만 저장되므로 이전 실행의 frontier(F)는 보통 C보다 뒤에 있다. 그러면 C~F 구간을 다시 적용하는 동안 `la_gate_is_satisfied` (274)가 의존 ≤ F인 태스크를 이번 실행에서 선행자가 아직 적용되지 않았는데도 통과시킨다. 같은 행을 바꾸는 두 트랜잭션이 동시에 워커로 가서 앞 트랜잭션이 나중에 끝나면 이전 값이 남는다(추정, 미재현). 새 프로세스로 재시작할 때 확인한 "재시작 지점부터 frontier를 다시 세워 복구 구간을 순서대로 적용한다"는 보장이 같은 프로세스 재시도에서만 깨진다.

debug 빌드에서는 79행 assert가 먼저 걸려 재시도 자체가 죽는다.

## 실측 근거 (2026-10-16 케이스 2 3회차, slave)

| 시각 | 근거 | 내용 |
|---|---|---|
| 00:08:15.252 | applylogdb 로그 | `reader schedule ... status=2 dispatch=18446744073709551615` (pending 보관 태스크 존재) |
| 00:08:15.355 | 하니스 | slave cub_server kill -9 |
| 00:08:16.062 | applylogdb 로그 | -199/-111 서버 다운, `Failed to flush replication items` |
| 00:08:31.069 | cub_client.err | `Program 'applylogdb' (pid 603341) connected` (같은 pid 재접속) |
| 00:08:35.299 | cub_client.err | `log applier started. required LSA: 338703\|3720` (읽은 값은 정상) |
| 00:08:35.393 | 0.2초 조회 | `_db_ha_apply_info` required가 338703\|3720 → 0\|0 |
| 00:08:37.633 | log/coredump | 같은 프로세스 종료 |
| 00:08:39~ | applylogdb 로그 | 새 pid들이 `required LSA: 0\|0` → -97 → -81로 기동 실패 반복 |

## 해결 방안

### 채택

1. `la_pending_clear()` 추가, `la_shutdown`에서 `la_stop_apply_workers ()` 바로 뒤(슬롯 free 전)에 호출. 버린 태스크의 커밋은 committed_lsa 뒤에 있으므로 다음 실행이 다시 읽는다(committed_lsa는 frontier를 넘지 않고, 보관 태스크는 frontier 뒤에 있다).
2. `la_gate_init`에서 frontier를 NULL로, ring을 비움. 79행 assert는 뺀다(재시도 때 ring이 비어 있지 않은 것은 정상 경로).
3. `la_find_required_lsa` 결과가 0|0이면 slots·tasks·final 위치를 NOTIFICATION으로 남기고 assert.

### 기각

- 재시도 때 프로세스를 끝내 cub_master가 새로 띄우게 하는 것: develop 동작(`util_cs.c`의 재시도)을 바꾸고, static이 남는 문제를 덮을 뿐 고치지 않는다.
- `la_lower_lsa`가 0|0도 걸러내게 하는 것: 해제된 메모리에서 0이 아닌 값이 읽히면 막지 못한다.

## 수정 코드 (커밋 4ba248708)

`log_applier_pending.cpp`

```c
void
la_pending_clear (void)
{
  LA_PENDING_NODE *node;

  while (la_Pending_head != NULL)
    {
      node = la_Pending_head;
      la_Pending_head = node->next;
      free_and_init (node);
    }
  la_Pending_tail = NULL;
}
```

`log_applier.c` → `la_shutdown`

```c
  la_stop_apply_workers ();

  /* parked tasks point at the apply slots freed below; see la_pending_clear */
  la_pending_clear ();
```

`log_applier_gate.cpp` → `la_gate_init`: `assert (la_Gate_order_count == 0)` 삭제, 끝에 `LSA_SET_NULL (&la_Gate_frontier);` 추가.

`log_applier.c` → `la_find_required_lsa` 끝:

```c
  if (required_lsa->pageid == 0 && required_lsa->offset == 0)
    {
      ... "applylogdb computed required_lsa 0|0 (slots from %lld|%d, tasks from %lld|%d, final %lld|%d)" NOTIFICATION
      assert (false);
    }
```

## 02와의 관계, 남은 구멍

- 02의 설계 요구사항("분리된 조각의 슬롯은 조각 태스크가 retire될 때까지 두 장부 중 하나에 남아 있어야 한다")은 한 실행 안에서의 규칙이다. 이 수정은 실행이 끝날 때 장부를 비우는 것이라 02와 충돌하지 않는다. 02가 다루지 않은 "실행 경계"를 이 문서가 채운다.
- **조각 슬롯 누수(미수정)**: SYSOP_END 조각의 슬롯은 `repl_lists` 밖에서 따로 malloc되고 retire 때 `la_coordinator_release_apply_slot`이 항목과 함께 free한다. 종료 때 pending이나 in-flight list에 남은 조각은 retire되지 않으므로, `la_pending_clear`(노드만 free)와 `la_inflight_init`(배열만 free)를 거치면 조각 슬롯과 그 항목이 누수된다. 해제된 메모리를 읽는 문제는 아니고, 같은 프로세스 재시도 한 번마다 남은 조각 수만큼 새는 것이다. 고치려면 `la_shutdown`에서 두 장부를 비우기 전에 조각 슬롯을 `la_free_all_repl_items` + free로 정리해야 한다.
- `repl_lists` 일반 슬롯의 항목도 `la_shutdown`이 슬롯만 free한다. develop과 같은 동작인지는 확인하지 않았다.

## 검증

- 코드: 바뀐 번역 단위 3개 release 컴파일 통과. 빌드·배포 전.
- 실측: 케이스 2를 반복해 applier가 같은 pid로 재시도하는 회차가 나와야 한다(10-16 3회 중 1회, 00:08. 10-15 23:04의 0|0도 같은 경로로 추정하나 그때 로그는 확인하지 않음). 기대: required_lsa 0|0 없음, 재시도한 실행이 복구 구간을 다시 적용하고 fail_counter 0, master·slave 데이터 일치. 재시도 여부는 `cub_client.err`의 `Program 'applylogdb' (pid <같은 pid>) connected`로 확인.

## 상세 설계용 요약 (8-2.7 재시작 후보)

### 왜 이런 처리가 필요한가

1. applylogdb는 서버 다운 뒤 프로세스를 유지한 채 applier를 다시 시작할 수 있다(develop 동작).
2. 병렬 applier는 coordinator 상태 일부(pending 목록, gate frontier)를 `la_Info` 밖의 파일 static에 둔다.
3. 재시작 지점은 저장된 committed_lsa이므로, 이전 실행의 스케줄링 상태는 새 실행에서 의미가 없고 해롭다. pending은 해제된 슬롯을 가리키고, frontier는 새 재시작 지점보다 앞서 있다.

### 설계 요구사항

- applier 종료는 coordinator가 가진 모든 스케줄링 상태(pending, in-flight list, gate ring, frontier)를 비워야 한다. 새 실행은 프로세스가 새로 뜬 것과 같은 상태에서 시작해야 한다.
- gate frontier는 매 실행마다 그 실행의 재시작 지점(committed_lsa)에서 시작해야 한다.
- 종료 때 retire되지 않은 태스크가 소유한 메모리(조각 슬롯과 항목)는 장부를 비우기 전에 정리해야 한다.
