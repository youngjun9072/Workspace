---
tags: [CBRD-27508, applier, fixes]
---
# 항목 오류가 트랜잭션의 마지막 항목에서만 전체 중단으로 번지는 문제

작성: 2026-10-15. 작업 목록 ① 4번 "`la_apply_repl_log` 항목 오류 정책 결정·반영". 사용자 결정: "세고 계속"(develop과 동일). 코드는 별도 커밋 9593d1131(미빌드·미검증, 접기는 승인 뒤).

**2026-10-16 접힘**: 별도 커밋 9593d1131 → slave 커밋 68dedb13c. 검증 PASS(10-15)는 접기 전 빌드 2661-a6f4f22 기준.

줄 번호는 수정 전 코드 기준(slave 커밋 8a89220be 시점). 마지막 절의 수정 코드만 수정 후 줄 번호.

## 한 줄 요약

워커의 `la_apply_repl_log`는 항목 오류를 세고 다음 항목으로 넘어가지만 반환값은 마지막 항목의 결과다. 그래서 같은 비치명 오류라도 중간 항목이면 fail_counter+1 뒤 트랜잭션이 커밋되고, 마지막 항목이면 트랜잭션이 커밋되지 않고 applylogdb가 종료된다. develop은 위치와 무관하게 세고 계속 간다.

## 발생 조건

- 워커가 적용하는 트랜잭션의 **마지막 항목**이 비치명 오류(-711 대상 행 없음, unique 중복 등 `ha_applylogdb_ignore_error_list`로 넘기는 종류)를 낸다.
- 치명 오류(flush 실패, 서버 다운, 메모리 초과, TDE)는 해당 없음. 이들은 위치와 무관하게 종료가 맞다.
- **정정(10-15 실측)**: 행 항목의 -711·unique 중복 같은 오류는 flush 경로(`la_flush_repl_items` 6016~6075)가 er_set·fail_counter++ 뒤 `error = NO_ERROR`로 스스로 삼키므로 루프의 오류 분기에 **오지 않는다**. 10-14의 -711이 런을 멈추지 않은 이유도 이것이다(항목 위치와 무관). 루프의 오류 분기에 오는 비치명 오류는 `la_apply_statement_log`가 돌려주는 statement 실패(예: slave에 이미 있는 인덱스를 CREATE INDEX → -272)와 클래스 조회 실패(`la_apply_*_log` 머리의 `er_errid()` 반환)다. statement 항목은 자기 트랜잭션 하나뿐이라 항상 "마지막 항목"이고, 수정 전에는 그 오류 하나로 applylogdb가 종료됐다.

## 단계별 코드

### 단계 1. 워커가 트랜잭션 하나를 적용하는 루프

`log_applier.c` → `la_apply_repl_log` (7013). 항목마다 `error`를 초기화하고 적용한다.

```c
7050   item = apply->head;
7051   while (item)
7052     {
7053       error = NO_ERROR;                               /* 항목마다 초기화 */
...
7076                 error = la_apply_delete_log (context, item, stats);
...
7099       if (error == NO_ERROR)
7100         {
7101           LSA_COPY (committed_rep_lsa, &item->lsa);
7102         }
7103       else
7104         {
...
7106           if (LA_IS_FLUSH_ERROR (error))              /* 치명 1 */
7107             {
7108               goto end;
7109             }
...
7135           if (ER_IS_SERVER_DOWN_ERROR (errid))        /* 치명 2 */
7136             {
7137               error = ER_NET_CANT_CONNECT_SERVER;
7138               goto end;
7139             }
7140           else if (la_ignore_on_error (errid) == false && la_retry_on_error (errid) == true)
7141             {
...
7147               LA_SLEEP (10, 0);
7148               continue;                               /* 같은 항목 재시도 */
7149             }
7150         }                                             /* 그 외 비치명 오류: error 유지한 채 다음 항목 */
7151     }
7152
7153       next_item = la_get_next_repl_item (item, apply->is_long_trans, &apply->last_lsa);
7154       la_free_repl_item (apply, item);
7155       item = next_item;
7156     }
7157
7158 end:
...
7164   return error;                                       /* = 마지막으로 처리한 항목의 결과 */
```

비치명 오류는 `la_apply_delete_log` 안에서 이미 `la_log_apply_error` (6183)가 `er_set`하고 `stats->fail_counter++` (6199)를 했다. 루프는 다음 항목으로 넘어가며 7053에서 `error`를 다시 0으로 만든다. 따라서 7164의 반환값은 **마지막 항목**의 결과만 담는다. 이 루프 자체는 develop(`la_apply_repl_log` 5742~5911)과 같다.

### 단계 2. 워커가 반환값으로 flush·commit을 결정한다

`la_apply_worker_run_task` (1326). develop에는 없는 호출자다.

```c
1337   result->error =
1338     la_apply_repl_log (context, task->apply, &task->commit_lsa, &total_rows, &result->committed_rep_lsa,
1339                        &result->stats);
...
1351   if (result->error != NO_ERROR)
1352     {
1353       return;                                         /* flush·commit 생략 */
1354     }
1355
1356   result->error = la_apply_worker_flush_task (context, task, trace_level, &result->stats);
...
1362   result->error = la_apply_worker_commit_task (context, task, trace_level, &result->stats, worker_applied_item_count);
```

마지막 항목이 비치명 오류였다면 1353에서 빠진다. 그 앞에서 성공한 항목들은 워커 세션에 올라간 채 flush·commit되지 않는다.

### 단계 3. 코디네이터가 그 결과를 오류로 돌려준다

`la_coordinator_retire_results` (1250).

```c
1256   while ((entry = la_inflight_peek ()) != NULL && entry->result_ready)
1257     {
1258       result = &entry->result;
1259
1260       if (result->error != NO_ERROR)
1261         {
...
1269           return result->error;                       /* 엔트리를 retire하지 않고 반환 */
1270         }
```

### 단계 4. 메인 루프가 applylogdb를 내린다

`la_apply_log_file` 메인 루프.

```c
9917       error = la_coordinator_collect_and_retire ();
9918       if (error != NO_ERROR)
9919         {
9920           la_coordinator_exit ("collect_and_retire", error);
9921         }
9922       if (error == ER_NET_CANT_CONNECT_SERVER)        /* 치명 종류별 처리 */
...
9942       else if (error != NO_ERROR)
9943         {
9944           la_applier_need_shutdown = true;            /* 비치명 오류도 여기로 */
9945           break;
9946         }
```

-711 같은 비치명 오류는 9922 이하의 어느 치명 분기에도 걸리지 않고 9942로 와서 applylogdb를 종료시킨다. 재시작하면 같은 트랜잭션을 다시 읽어 같은 항목에서 같은 오류를 내므로 운영자가 `ignore_error_list`를 바꾸기 전까지 반복된다.

### 단계 5. develop의 같은 자리

develop `la_apply_commit_list` (5925)와 `la_log_record_process` (6228).

```c
5935       error = la_apply_repl_log (commit->tranid, commit->type, &commit->log_lsa, &la_Info.total_rows, final_pageid);
5936       if (error != NO_ERROR)
5937         {
5938           er_log_debug (ARG_FILE_LINE, "apply_commit_list : error %d while apply_repl_log\n", error);
5939         }
5940
5941       LSA_COPY (lsa, &commit->log_lsa);               /* 오류와 무관하게 커밋 위치 반환 */
```

```c
6228           error = la_apply_commit_list (&lsa_apply, final_pageid);
6229           if (error == ER_NET_CANT_CONNECT_SERVER)   /* 치명 종류만 return */
...
6248           else if (LA_IS_FLUSH_ERROR (error))
6249             {
6250               return error;
6251             }
...
6258           if (!LSA_ISNULL (&lsa_apply))               /* 비치명이면 여기로 와서 la_log_commit */
```

develop은 비치명 오류를 로그만 남기고 트랜잭션을 커밋한다. 마지막 항목이어도 같다.

## 왜 문제인가

- **정책이 항목 위치로 갈린다.** 같은 오류가 중간이면 "세고 계속", 마지막이면 "전체 중단". 설계상 어느 쪽도 의도한 것이 아니다. 루프는 develop의 "세고 계속"을 그대로 가져왔고, 워커 호출자(단계 2)만 반환값을 치명 오류로 간주한다.
- **develop과 결과가 달라진다.** develop에서는 넘어가던 트랜잭션이 병렬 applier에서는 applylogdb 정지로 이어진다. fail_counter만 올라가야 할 상황에서 복제가 멈춘다.
- **재시작으로 풀리지 않는다.** 복구 구간 skip(`recovery_skip`)은 flush 오류 경로에만 있고, 항목 적용 단계의 -711은 재시작 뒤에도 같은 자리에서 난다.

## 해결 방안

### 채택: 비치명 오류를 센 뒤 `error`를 지운다 (세고 계속, develop 동일)

`la_apply_repl_log`의 오류 분기 끝에 `else`를 하나 더 둔다. 커밋 9593d1131, 수정 후 줄 번호.

```c
7140           else if (la_ignore_on_error (errid) == false && la_retry_on_error (errid) == true)
7141             {
...
7148               continue;
7149             }
7150           else
7151             {
7152               /* The item is already counted in fail_counter and reported. The transaction goes on with its
7153                * remaining items and is committed with the ones that applied, so only the fatal errors above
7154                * reach the worker's result; otherwise a failure on the last item alone would drop the whole
7155                * transaction and stop the applier. */
7156               error = NO_ERROR;
7157             }
```

- 치명 오류 두 종류(7106 flush, 7135 서버 다운)는 `goto end`로 그대로 반환된다.
- 재시도 분기(7140)는 `continue`라 이 `else`에 오지 않는다.
- `committed_rep_lsa`는 7099에서 성공한 항목만 갱신하므로 변화 없다.
- 호출자(단계 2~4)는 손대지 않는다. 반환값의 의미가 "치명 오류만"으로 좁혀져 그 코드들이 의도대로 동작한다.

### 대안: 첫 오류에서 중단

비치명 오류도 `goto end`로 즉시 반환하고 태스크를 커밋하지 않는다. 운영자 개입 전제. develop보다 엄격해지고, `ha_applylogdb_ignore_error_list`를 쓰지 않으면 재시작해도 같은 항목에서 멈춘다. 병렬화가 오류 정책을 바꿀 근거가 없어 기각.

### 범위 밖

- 워커 세션에 올라간 뒤 커밋되지 않은 항목의 정리(단계 2에서 빠질 때). 이 수정으로 비치명 경로는 그 상황에 가지 않고, 치명 경로는 applylogdb 종료라 세션이 사라진다.
- statement 항목의 재시작 재적용(`la_apply_repl_log` 머리 TODO). 별도 항목.

## 적용 상태와 검증

- 코드: 별도 커밋 9593d1131 (cs HEAD ae8a6acba 위). 빌드 2661-a6f4f22(10-15 14:33)에 포함, 실측 PASS(아래). 접기는 사용자 승인 뒤.
- **검증 완료(10-15 15:03, 빌드 2661-a6f4f22, `ha_bench_tool/bin/verify_item_error.sh`, 로그 `log/verify_item_error_20261015_150259`)**: slave에 `--sysadm --write-on-standby`로 인덱스 `ix_t4_v`를 먼저 만들고 master가 같은 인덱스를 CREATE INDEX. slave 로그 `[WSET] worker error trid=2423 ... error=-272 item_type=5 pk='create index ix_t4_v on t4(v)'` 1건, fail_counter 2→3, `reader exit` 0, applylogdb pid 유지(298285), 직후 master INSERT id=11이 slave에 반영. **PASS**.
- 행 오류 대조(10-15 15:00 1차 런): slave에서 id 9·10을 지운 뒤 master가 id=10 DELETE를 마지막 항목으로(A), id=9 DELETE를 중간 항목으로(B) 커밋. 둘 다 fail_counter+1, 나머지 항목 반영, applier 유지. 단 이는 flush 경로가 삼킨 것이라 이 수정의 효과가 아니다(위 정정).

## 상세 설계용 요약 (8-2.x 워커 오류 처리에 넣을 후보)

### 왜 이런 처리가 필요한가

develop의 applier는 항목 오류를 "세고 계속"으로 다룬다. 한 항목의 실패가 트랜잭션의 나머지와 복제 전체를 막지 않고, 운영자는 fail_counter와 오류 로그로 뒤따라 확인한다. 병렬 applier는 적용 함수를 워커로 옮기면서 **반환값을 태스크의 성패로 쓰기 시작**했다. 반환값은 원래 마지막 항목의 결과였으므로, 마지막 항목의 비치명 오류만 태스크 실패로 승격되어 코디네이터가 applier를 내리는 경로가 생겼다. 워커 구조에서는 "태스크 결과"가 곧 "flush·commit 여부"와 "코디네이터 종료 여부"를 결정하므로, 적용 함수는 **치명 오류만** 결과에 올리고 비치명 오류는 자기 안에서 소화해야 한다.

### 설계 요구사항

- 워커의 적용 결과(`LA_RESULT.error`)에는 치명 오류(flush 실패, 서버 다운, 메모리 초과, TDE)만 실린다. 비치명 항목 오류는 fail_counter와 오류 로그로만 남고 트랜잭션은 성공한 항목으로 커밋된다.
- 항목 오류의 처리 결과가 트랜잭션 안의 항목 위치에 의존하지 않는다.
- `ha_applylogdb_ignore_error_list` / `retry_error_list`의 의미는 develop과 같다.
