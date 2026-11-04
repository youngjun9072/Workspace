---
tags: [CBRD-27508, applier, failover, 분석]
---
# failover 승격이 to-be-active에서 멈추는 문제: la_change_state의 DONE 재평가 누락

작성: 2026-10-15. 10-14 22:07 failback 때 youngjun4가 `registered_and_to_be_active`에 남은 사건에서 확인. 코드는 slave 커밋 8a89220be(접기 전 178a68de8)에 반영(미빌드·미검증). todo: `todo/CBRD-27508 - la_change_state 조기 리턴으로 DONE 재평가 누락`.

**2026-10-16 접힘**: slave 커밋 68dedb13c(접기 재정렬로 해시 변경). 로깅·assert도 같은 커밋. 빌드·배포 전.

줄 번호는 수정 전 코드 기준(`log_applier.c`는 HEAD d43e03e13 시점). 마지막 절의 수정 코드만 수정 후 줄 번호.

## 한 줄 요약

승격되는 노드의 cub_server는 자기 applylogdb가 DONE을 보고해야 active가 된다. applylogdb의 `la_change_state`는 로그 끝에서 워커가 아직 적용 중이면 DONE을 미루는데, 미룬 사실을 기억하지 않아 다음 호출이 입구의 "입력이 그대로면 리턴"에 걸린다. 워커가 끝나도 아무도 다시 판정하지 않으므로 서버는 영원히 to-be-active에 남는다.

## 등장인물

전부 **살아남은 슬레이브 노드** 안의 프로세스다. 죽은 master는 복사 로그 헤더의 상태값으로만 등장한다.

| 프로세스 | 역할 |
|---|---|
| cub_master | 상대 노드 사망을 감지해 자기 역할을 MASTER로 올리고, 자기 cub_server에 "active 되라"를 보낸다 |
| cub_server | 요청을 받아 standby → to-be-active → active로 전이한다 |
| applylogdb (coordinator 스레드) | 죽은 master의 복사 로그를 끝까지 적용하고 DONE을 서버에 보고한다 |

## 단계별 코드

### 단계 1. cub_master가 changemode(ACTIVE)를 보낸다

`src/executables/master_heartbeat.c` → `hb_resource_job_change_mode` (5초 주기) → 3808~3818행

```c
3808  if ((hb_Resource->state == HB_NSTATE_MASTER
3809       && (proc->state == HB_PSTATE_REGISTERED_AND_STANDBY || proc->state == HB_PSTATE_REGISTERED_AND_TO_BE_ACTIVE))
3810      || ...)
3811    {
3818      error = hb_resource_send_changemode (proc);
```

- `hb_Resource->state = HB_NSTATE_MASTER`, `proc->state = REGISTERED_AND_STANDBY` → 전송.
- 서버가 `REGISTERED_AND_ACTIVE`가 될 때까지 5초마다 반복된다(3809행의 `TO_BE_ACTIVE` 조건).

`hb_resource_send_changemode` 4369·4373행에는 응답이 어긋나면 12회째 SIGTERM, 24회째 SIGKILL을 보내는 `changemode_gap` 탈출구가 있으나, `changemode_gap`을 증가시키는 코드가 없다(4301·4503행의 `= 0`뿐). 실제로는 동작하지 않는다.

### 단계 2. cub_server가 요청을 받는다

`src/connection/master_connector.cpp` → `master_connector::change_ha_mode` → 1044~1053행

```c
1044  state = (HA_SERVER_STATE) ntohl (*buf);
1051  if (state == HA_SERVER_STATE_ACTIVE || state == HA_SERVER_STATE_STANDBY)
1053      if (css_change_ha_server_state (m_entry, state, false, HA_CHANGE_MODE_IMMEDIATELY, true) != NO_ERROR)
```

- `state = ACTIVE`, `force = false`, `heartbeat = true`.

### 단계 3. 첫 요청은 입구 if문을 통과한다

`src/connection/server_support.c` → `css_change_ha_server_state` → 1569~1574행

```c
1569  if (state == ha_Server_state
1570      || (!force && ha_Server_state == HA_SERVER_STATE_TO_BE_ACTIVE && state == HA_SERVER_STATE_ACTIVE)
1571      || (!force && ha_Server_state == HA_SERVER_STATE_TO_BE_STANDBY && state == HA_SERVER_STATE_STANDBY))
1572    {
1573      return NO_ERROR;
1574    }
```

- `ha_Server_state`: 이 서버의 현재 상태. `state`: 요청값.
- 조건 1 "이미 그 상태다", 조건 2 "active로 가는 중이다", 조건 3 "standby로 가는 중이다". 하나라도 참이면 중복 요청으로 보고 리턴.
- 첫 요청: `ha_Server_state = STANDBY`, `state = ACTIVE` → 셋 다 거짓 → 통과.

### 단계 4. STANDBY → TO_BE_ACTIVE, applier DONE 검사 한 번

`server_support.c` → `css_change_ha_server_state` → 1609~1626행

```c
1609  case HA_SERVER_STATE_ACTIVE:
1610    state = css_transit_ha_server_state (thread_p, HA_SERVER_STATE_ACTIVE);
1616    if (css_check_ha_log_applier_done ())
1619        state = css_transit_ha_server_state (thread_p, HA_SERVER_STATE_ACTIVE);
1622    if (state == HA_SERVER_STATE_ACTIVE)
1625        logtb_enable_update (thread_p);
```

- 1610: 전이표 1384행 `{STANDBY, ACTIVE 요청 → TO_BE_ACTIVE}`. `ha_Server_state = TO_BE_ACTIVE`.
- 1616: applier가 DONE이면 1619에서 전이표 1380행 `{TO_BE_ACTIVE → ACTIVE}`, 1625에서 쓰기 허용.

### 단계 5. applier DONE 검사

`server_support.c` → `css_check_ha_log_applier_done` → 1504~1515행

```c
1508    for (i = 0; i < ha_Server_num_of_hosts; i++)
1510        if (ha_Log_applier_state[i].state != HA_LOG_APPLIER_STATE_DONE)
1512            break;
1515    if (i == ha_Server_num_of_hosts) return true;
```

- `ha_Log_applier_state[]`: applylogdb가 `boot_notify_ha_log_applier_state()`로 보고한 마지막 값. 부하 중이던 slave의 applier는 WORKING.
- 1510 참 → false. 단계 4의 1619·1625는 실행되지 않고 서버는 TO_BE_ACTIVE에서 멈춘다.

### 단계 6. 두 번째 이후 요청은 입구에서 돌아간다

단계 1·2 반복 후 단계 3의 1570행:

- `ha_Server_state = TO_BE_ACTIVE`, `state = ACTIVE`, `force = false` → 조건 2 참 → 1573 리턴.
- 단계 4·5는 두 번 다시 실행되지 않는다. cub_master의 반복 요청은 승격을 재시도하지 않는다.

### 단계 7. TO_BE_ACTIVE → ACTIVE로 가는 유일한 길

`server_support.c` → `css_notify_ha_log_applier_state` → 1735~1782행. applylogdb가 상태를 보고할 때 실행된다.

```c
1757            table->state = state;
1774    if (css_check_ha_log_applier_done ())
1777        server_state = css_transit_ha_server_state (thread_p, HA_SERVER_STATE_ACTIVE);
1779        if (server_state == HA_SERVER_STATE_ACTIVE)
1782            logtb_enable_update (thread_p);
```

- 보고값이 DONE이면 1757에서 기록 → 1774 참 → 1777 ACTIVE → 1782 쓰기 허용.
- 즉 승격 완료는 전적으로 **applylogdb가 DONE을 한 번 보고하느냐**에 달려 있다.

참고: `cubrid changemode <db> --mode=active --force`는 `network_interface_sr.cpp:4427`에서 `force = true`로 들어와 단계 3의 조건을 건너뛰고 1590행에서 상태를 덮어쓴다. 운영자의 수동 탈출구이며 자동 복구가 아니다.

### 단계 8. applylogdb가 la_change_state를 부르는 주기

`src/transaction/log_applier.c` → `la_apply_log_file` (메인 루프) → 10307행, 10336~10373행

```c
10307  error = la_change_state ();
10336  if (LSA_EQ (&old_lsa, &la_Info.final_lsa))        /* 새 로그 없음 */
10372      (void) la_result_queue_wait_for_result (100);
10373      continue;
```

- master가 죽어 로그가 더 안 오면 100ms마다 `la_change_state()`가 불린다. 호출은 계속된다.

### 단계 9. 첫 호출: 입구 통과와 입력 기록

`log_applier.c` → `la_change_state` → 7954~7973행

```c
7954  if (la_Info.last_server_state == la_Info.act_log.log_hdr->ha_server_state
7955      && la_Info.last_file_state == la_Info.act_log.log_hdr->ha_file_status
7956      && la_Info.last_is_end_of_record == la_Info.is_end_of_record)
7959      return NO_ERROR;
7971  la_Info.last_server_state = la_Info.act_log.log_hdr->ha_server_state;
7972  la_Info.last_file_state = la_Info.act_log.log_hdr->ha_file_status;
7973  la_Info.last_is_end_of_record = la_Info.is_end_of_record;
```

- 기록값 (ACTIVE, SYNCHRONIZED, false) ↔ 지금 값 (DEAD, SYNCHRONIZED, true). copylogdb가 master 연결이 끊기면 헤더 상태를 DEAD로 쓰고, 남은 레코드를 다 읽어 `is_end_of_record = true`.
- 7954 거짓 → 통과 → 7971~7973에서 기록값이 (DEAD, SYNCHRONIZED, true)로 바뀐다. 이 세 줄은 아래 결론과 무관하게 실행된다.

### 단계 10. 첫 호출: DONE 후보지만 가드에서 미룬다

`log_applier.c` → `la_change_state` → 7976~8006행

```c
7976  if (la_Info.is_end_of_record == true && (la_Info.act_log.log_hdr->ha_file_status == LOG_HA_FILESTAT_SYNCHRONIZED))
7979      switch (la_Info.act_log.log_hdr->ha_server_state)
7991        case HA_SERVER_STATE_DEAD:
7994          if (la_Info.apply_state != HA_LOG_APPLIER_STATE_DONE)
8002              if (!la_coordinator_drain_complete ())
8004                  break;
8006              new_state = HA_LOG_APPLIER_STATE_DONE;
```

`la_coordinator_drain_complete` 909행:

```c
909  return (la_pending_is_empty () && la_inflight_get_count () == 0 && la_gate_order_get_count () == 0);
```

- 7976 참, DEAD case, `apply_state = WORKING` → 8002: 워커가 마지막 트랜잭션들을 적용 중이라 `drain_complete = false` → 8004 `break`. `new_state`는 초기값 NA.
- 8052행 `if (new_state != NA)`가 거짓이라 8068행 `boot_notify_ha_log_applier_state`는 실행되지 않는다. DONE 보고 없음.
- 8002~8005행은 이 브랜치가 넣은 가드다. develop에는 없고 7994 다음에 바로 8006이 온다. 가드 자체는 필요하다. 병렬에서는 "로그를 끝까지 읽음"과 "끝까지 적용함"이 달라서, 워커가 적용 중에 DONE을 주면 역할 전환 마무리가 repl_lists를 해체해 slave가 깨진다.

### 단계 11. 두 번째 호출: 입구에서 바로 리턴

`log_applier.c` → `la_change_state` → 7954~7960행

- 기록값 (DEAD, SYNCHRONIZED, true) ↔ 지금 값 (DEAD, SYNCHRONIZED, true). master는 계속 죽어 있고 새 레코드가 없다.
- 셋 다 같음 → 7959 리턴. 7976행 이하는 실행되지 않는다.
- 2초 뒤 워커가 다 끝나 `drain_complete = true`가 되어도, 그 사실은 7954~7956행이 비교하는 세 값 어디에도 없다. 이후 100ms마다 같은 자리에서 리턴한다.

### 단계 12. 백스톱이 잡지 못하는 이유

`log_applier.c` → `la_apply_log_file` → 10340~10363행

```c
10340  if (la_Info.is_role_changed == true && !la_coordinator_drain_complete ())
10353      else if ((la_clock_ns () - la_Drain_wait_start_ns) / 1000000ULL > (UINT64) LA_DRAIN_TIMEOUT_MSEC)
10362          la_applier_need_shutdown = true;
```

- "드레인이 안 끝난 채 frontier가 30초 동안 안 움직이면 재시작"이다. 워커가 멈춘 경우용.
- 이 경우는 드레인이 정상적으로 끝나 `!drain_complete`가 거짓이므로 블록에 들어가지 않는다.

## 왜 문제인가

1. DONE을 "미룬다"는 결정이 7954~7956행의 비교 입력에 들어가지 않는다. 미룬 순간 7971~7973행이 "이 입력은 봤다"고 기록하므로, 미룸을 풀어 줄 사건(드레인 완료)은 입력이 아니라서 다시는 switch까지 내려가지 못한다.
2. 시스템의 나머지는 모두 "applier가 언젠가 DONE을 준다"를 전제로 재시도하지 않는다. cub_master의 반복 요청은 단계 6에서 무시되고, `changemode_gap` 탈출구는 죽은 코드이며, 서버는 단계 7 외에는 스스로 전이하지 않는다.
3. 조건은 "승격 순간 워커에 미완 태스크가 하나라도 있을 것"이고, 부하 중 failover는 거의 항상 해당한다.
4. 원인은 이 브랜치가 가드(8002행)를 넣으면서 "다음 패스에서 다시 본다"는 주석의 전제가 develop의 조기 리턴 구조에서 성립하지 않는다는 점을 놓친 것이다.

관측: 10-14 22:07 failback 때 youngjun4가 to-be-active에 남았다. 그때는 빈 커밋 핑퐁(별도 결함, 같은 날 수정) 때문에 `is_end_of_record`가 계속 바뀌어 입구는 통과했지만 매번 8002행에서 막힌 변형이었다. 핑퐁을 고친 뒤에는 입력이 멈춰 입구에서 막힌다. 어느 쪽이든 같은 결함이다.

## 해결 방안

### 채택: 미룸을 기억하는 플래그 (done_deferred)

변경 4곳, 추가 6줄. 수정 후 줄 번호.

```c
/* ① LA_INFO, 362행 */
  bool done_deferred;		/* DONE was due but workers were still applying; re-evaluate on the next pass */

/* ② la_change_state 입구, 7956행 */
  if (!la_Info.done_deferred
      && la_Info.last_server_state == la_Info.act_log.log_hdr->ha_server_state
      && la_Info.last_file_state == la_Info.act_log.log_hdr->ha_file_status
      && la_Info.last_is_end_of_record == la_Info.is_end_of_record)
    {
      return NO_ERROR;
    }

/* ③ 판정 전 초기화, 7978행 */
  /* a deferred DONE is decided again below; any other outcome drops it */
  la_Info.done_deferred = false;

/* ④ 미룰 때 세우기, 8001~8006행 */
	      /* Workers may still be applying: hold DONE and raise done_deferred so the early return above lets
	       * the next pass come back here and decide again. */
	      if (!la_coordinator_drain_complete ())
		{
		  la_Info.done_deferred = true;
		  break;
		}
```

동작:
- 첫 호출: ② 통과(입력 변화) → ③ false → 드레인 미완 → ④ true → break.
- 100ms 뒤: ②에서 `!true`가 거짓이라 조기 리턴하지 않음 → ③ false → 드레인 아직이면 ④ true.
- 드레인 완료 후 첫 호출: ② 통과 → ③ false → 8002 통과 → DONE → 8068행 보고 → 단계 7에서 서버 ACTIVE.
- 미루는 사이 상대가 ACTIVE로 되살아나면 WORKING 분기로 가고 ③이 플래그를 지운다. 기존 동작과 같다.
- 초기값은 `la_init`의 `memset (&la_Info, 0, ...)`(8469행)으로 false.
- 비용: 미룬 동안 100ms마다 switch 한 번(정수 비교 몇 개와 카운터 3개 확인).

주석은 기존 6줄(이제는 틀린 "한 패스 더 간다", "백스톱이 덮는다" 포함)을 위 2줄로 바꿨다. slave가 깨지는 이유는 `la_coordinator_drain_complete` 주석(901행)에, 백스톱은 메인 루프 10338행 주석에 각각 있어 여기서 반복하지 않는다.

### 대안: 입력 기록을 switch 뒤로 옮기고 미룬 패스에서는 갱신하지 않기

같은 효과지만 7962행의 상대 상태 변화 알림(`er_set`)이 기록 앞에 있어 코드를 더 옮겨야 하고, 미룬 패스마다 그 알림이 중복으로 찍힐 수 있다. 기존 줄을 옮기지 않는 플래그 방식을 택했다.

### 기각: 가드 제거

develop처럼 바로 DONE을 주면 워커 적용 중에 역할 전환 마무리가 repl_lists를 해체한다. 가드가 생긴 이유 그대로라 안 된다.

## 적용 상태와 검증

- 코드: slave 커밋 8a89220be에 접힘(cs HEAD ae8a6acba). 접기 전 해시 178a68de8/9aa7f1be5. 해당 번역 단위 컴파일 통과. 빌드·배포·실측 전.
- 검증(failover 테스트 첫 케이스): 의존 체인이 있는 부하로 slave에 pending을 만든 뒤 master를 죽인다. 승격 노드가 드레인 직후 `registered_and_active`가 되고, applylogdb 로그에 `change log apply state ... to 'done'`이 드레인 직후 시각으로 찍혀야 한다. 같은 셋업에서 워커 하나를 세워(테스트 훅) 30초 백스톱이 여전히 재시작하는지도 본다.

## 관련: develop PR #8110 (CBRD-27563, 10-15 현재 APPROVED·미병합)

같은 `la_change_state` DONE 분기를 고치지만 잡는 결함이 다르다. PR은 코디네이터가 **덜 읽은** 경우(페이지를 한 번 읽은 뒤 긴 적용 중 copied log가 같은 페이지에 더 쓰이고 source가 dead가 되면 버퍼의 옛 END_OF_LOG로 `is_end_of_record`가 섬)를 `la_apply_log_file`에서 `la_change_state` 호출 직전에 `la_record_end_is_stale()`(source DEAD/STANDBY/MAINTENANCE && 헤더 `eof_lsa > final_lsa`)로 걸러 `is_end_of_record = false`로 되돌린다. 이 문서의 수정은 다 읽었지만 **워커가 덜 적용한** 경우다. 둘은 보완 관계이고 서로 간섭하지 않는다.

- 이 결함은 우리 브랜치에도 있다(DONE 게이트는 "다 적용했나"만 본다). failover 테스트에서 "승격 직후 마지막 트랜잭션 누락, 60초 뒤 반영"이 보이면 이것이다(기지 신호 5번).
- PR 병합 뒤 develop 싱크 때 DONE 분기에서 텍스트 충돌: PR이 `switch`를 `if` 체인으로 바꾸므로 `drain_complete` 보류 블록을 `la_is_done_state` 분기 안으로 옮긴다. 그 뒤 PR의 재현 순서(CREATE INDEX 커밋 → 0.5초 뒤 INSERT → `heartbeat stop`)를 failover 케이스에 추가한다.

## 로깅·assert (커밋 3924469c6)

- DONE을 처음 미루는 순간 NOTIFICATION `applylogdb holds DONE: workers are still applying (pending=.. dispatch=.. order=.. final=.. committed=..)`, 미룸이 끝나고 DONE을 보고할 때 `applylogdb reports DONE after holding it for N seconds`. 승격이 to-be-active에 머물면 slave 로그에서 이 두 줄의 유무·간격으로 역추적한다.
- assert: DONE 보고 직전 `la_pending_is_empty () && la_inflight_get_count () == 0 && la_gate_order_get_count () == 0` (drain_complete 계약).

## 실측 (10-15 케이스 1)

master cub_server `kill -9`는 failover가 아니라 cub_master 재기동이라 이 수정의 DONE 보류 경로를 지나지 않았다(4회). 대신 재시작 경계(`log_manager.c` `wset_raise_history_start (&restart_lsa, …)`)가 3회 강한 런에서 모두 역전 없이 걸림. 상세: `_notes/restart-failover-test-plan-20261015.md` 결과 절. DONE 보류는 케이스 4(`heartbeat stop`)에서 본다.

## 상세 설계용 요약 (8-2.8 역할 전환 drain에 넣을 후보)

어디에 합칠지는 미정. `CLAUDE.md` §12의 "정식 설계에서는 `drain_pending`과 같은 지속 상태를 두고 HA 헤더 상태가 변하지 않아도 완료 여부를 반복 확인해야 한다"는 메모가 바로 이 항목이며, 코드의 `done_deferred`가 그 지속 상태다.

### 왜 이런 처리가 필요한가

1. **직렬 applier에서는 "로그 끝"이 곧 "적용 끝"이었다.** develop의 applier는 레코드를 읽는 스레드가 적용까지 하므로, 복사 로그 끝에 닿은 순간 모든 트랜잭션이 DB에 반영돼 있다. 그래서 상대 서버가 DEAD/STANDBY이고 로그 끝이면 즉시 DONE을 보고해도 안전했다.
2. **병렬 applier에서는 둘이 분리된다.** coordinator가 로그 끝에 닿아도 worker는 마지막 트랜잭션들을 아직 적용 중일 수 있고, 의존 때문에 pending에 묶인 트랜잭션도 남아 있을 수 있다. 이 상태에서 DONE을 보고하면 서버는 쓰기를 열고 역할 전환 마무리가 repl_lists를 해체하므로, worker가 적용하던 트랜잭션이 유실되거나 깨진다. 따라서 **DONE은 drain 완료(pending, in-flight list, COMMIT 순서 링이 모두 빈 상태) 뒤에만 보고해야 한다.**
3. **drain 완료는 로그 헤더의 입력이 아니다.** 상태 판정 함수는 비용을 줄이려고 "상대 서버 상태, 파일 상태, 로그 끝 여부"가 바뀔 때만 다시 계산한다. drain은 worker 쪽 사건이라 이 세 입력을 바꾸지 않고, 상대가 죽은 뒤에는 세 입력이 다시 바뀔 일도 없다. 그러므로 "DONE을 미뤘다"는 사실을 **헤더 입력과 별개의 지속 상태**로 들고 있다가, 그 상태가 켜져 있는 동안은 입력이 그대로여도 판정을 반복해야 한다. 미룸이 입력에 종속되면 한 번 미룬 DONE은 영원히 보고되지 않는다.
4. **승격 완료는 DONE 보고 한 번에만 의존한다.** cub_master의 주기 요청은 서버가 to-be-active가 된 뒤에는 무시되고, 서버는 applier의 DONE 통지에서만 active로 전이한다. 재시도 경로가 없으므로 applier 쪽의 재평가가 유일한 복구 수단이다.
5. **백스톱은 다른 경우를 맡는다.** drain이 끝나지 않는 경우(worker 정지로 frontier가 멈춤)는 타임아웃으로 applier를 재시작한다. drain이 정상 완료된 경우는 백스톱 조건에 들어가지 않으므로, 3의 지속 상태가 없으면 어떤 안전장치도 작동하지 않는다.

### 설계 요구사항

- coordinator는 역할 전환 판정에서 drain이 끝나지 않아 DONE을 미룬 경우 그 사실을 지속 상태(`done_deferred`)로 유지해야 한다.
- 지속 상태가 켜져 있는 동안 상태 판정은 로그 헤더 입력이 바뀌지 않아도 매 패스 다시 실행해야 하며, drain이 끝난 첫 패스에서 DONE을 보고해야 한다.
- 지속 상태는 판정이 DONE 외의 결론(상대 서버가 다시 ACTIVE 등)에 이르면 해제해야 한다.
- drain이 끝나지 않는 경우의 처리(frontier 정지 타임아웃 뒤 재시작)는 이 지속 상태와 별개로 유지해야 한다.
- 역할 전환 drain 중에는 dependency 판정을 무시하지 말고 평소와 같은 gate 판정을 반복해야 한다(기존 불변식 11).
