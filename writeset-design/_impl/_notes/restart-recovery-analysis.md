# 병렬 applylogdb 크래시 루프·데이터 유실 재구성 (run 20261002T160018-20261001-1597719)

## 0. 이 문서가 답하는 것

HA 2노드(마스터 youngjun3 active / 슬레이브 youngjun4 standby) 병렬 applylogdb 테스트에서,
마스터는 정상 커밋한 7개 사용자 행(item_0 기준 id 41,42,44,45,46,47,51)이 슬레이브에 반영되지 않았다.
아래는 슬레이브 applier 로그를 라인 단위로 읽어 "왜 유실됐는가"를 인과로 복원한 것이다.

근거 로그 (정적 수집본):
- 슬레이브 applier: `slave_applier.err` (6264줄) — youngjun4가 youngjun3 복제로그를 적용
- 마스터 서버: `master_server.err` (2883줄)
- run 디렉토리: `.../sysop_runs/20261002T160018-20261001-1597719`
- 코드: `/home/youngjun/Workspace/cubrid-applier/src/transaction/log_applier.c`

로그 라인번호와 코드 `file:line`으로만 사실을 적고, 확인 못 한 추론은 "추정"으로 표기한다.

---

## 1. 한 줄 결론

**데이터 유실의 직접 원인은 "frontier lag + 재시작 rewind + 복구창 멱등 skip 미구현"의 복합이 아니라,
그보다 상류에 있는 `181 페이지 읽기 실패(ER_LOG_PAGE_CORRUPTED, -81)로 인한 리더 크래시 루프`다.**

- 마스터가 커밋한 7개 사용자 행은 슬레이브에서 **worker가 커밋한 적이 한 번도 없다**(아예 완결 적용 안 됨). "frontier 뒤에서 worker가 커밋했는데 재시작이 skip한" 패턴이 **아니다**.
- 단, "frontier lag → rewind → 이미 적용된 데이터 재적용 → unique 위반(-670)이 skip 안 됨" 패턴은 **프리로드 88행에서 실제로 발생**했고, 이게 재시작마다 -670 소음과 재크래시를 만들어 **크래시 루프를 영속화**시켜 사용자 행이 영영 적용될 기회를 뺏었다.

즉 두 메커니즘이 겹쳐 있다: (A) 페이지 읽기 실패가 리더를 죽이고, (B) frontier가 worker 커밋보다 뒤처진 상태로 rewind되어 프리로드 재적용 -670을 유발하며, (A)가 매 재시작 반복되어 (B)의 소음 속에서 사용자 행은 적용 자체가 불가능해진다.

---

## 2. 크래시/재시작 타임라인 (라인 인용)

로그 캡처 구간 안에서 **"log applier started"는 2회** = 최소 1회 재시작. 그 뒤로도 루프는 캡처 밖에서 계속된다(마스터 로그가 01:03:23까지 connection close 반복, `master_server.err` tail).

| 시각 | 사건 | 슬레이브 라인 | required / committed / committed_rep LSA |
|---|---|---|---|
| 01:00:18~19 | 세션1 정상 적용(trid 412/413/414 등) | 5088~5610 | frontier가 171→176으로 전진 |
| 01:00:19.032 | **프리로드 88행 worker commit end error=0** | 5624 | worker 커밋 LSA = `181\|9496` |
| 01:00:19.327 | reader retire trid=427 (181\|9496) | 5627 | — |
| 01:00:21.733 | **크래시1**: ERROR -81 "logical log page 181 may be corrupted" (`log_applier.c:9555`) | 5628 | — |
| 01:00:23.749 | applylogdb 재접속(boot_cl.c:870) | 5632 | — |
| 01:00:23.775 | **세션2 start** (`log_applier.c:9343`, ER -1038) | 5637 | required `176\|14912` / committed `176\|14872` / repl `176\|14408` |
| 01:00:23.78~ | 재적용 중 프리로드 재삽입 → **-670 unique 위반 대량** | 5985~6240 | item_1 40건, item_0 40건, parent 8건 |
| 01:00:26.792 | **크래시2**: 동일 ERROR -81 page 181 (`log_applier.c:9555`) | 6261 | — |
| ~01:03:23 | 루프 지속(캡처 밖, 마스터 connection close 반복) | — | — |

세션1 시작값은 로그 머리(라인 9): required/committed/repl 모두 `171\|6160`.

크래시 지점 코드(`log_applier.c:9540~9557`): 페이지를 못 읽으면 `LA_GET_PAGE_RETRY_COUNT`까지 재시도(usleep) 후, 소진되면
`er_set(... ER_LOG_PAGE_CORRUPTED ...); error = ER_LOG_PAGE_CORRUPTED; la_applier_need_shutdown = true; break;`
즉 **재시도 소진 → 자발적 shutdown → 재시작**. 재시작 후 같은 페이지 181을 다시 만나 같은 자리에서 죽으므로 루프가 된다.
(참고: 세션2에서 리더가 `final_lsa=181\|15248`까지 읽어 들어간 흔적이 있다 — 프리로드(181\|9496)·432(181\|11320)·437(181\|12528)을 지나 더 읽다가 죽음. 페이지 181이 "끝 페이지라 부분적으로만 유효/copylogdb 미완충"이었을 가능성이 있으나, 재시도로 흡수 못 하고 영구 실패로 처리된 것은 로그상 사실이다. 부분기록 vs 실손상 여부는 이 로그만으로 확정 불가 — **추정**.)

---

## 3. ★ frontier(committed_lsa) vs worker 실제 커밋 LSA의 괴리

### 정량
- **frontier(coordinator commit end의 committed_lsa) 최대값 = `176\|15592`** (committed_rep `176\|14408`). 177 이후로 **단 한 번도 전진하지 못함**.
  - 진행 궤적(coordinator commit end, 중복 제거): 171\|6160 → … → 172\|8368 → 172\|16320 → 176\|8432 → 176\|14872 → 176\|14912 → **176\|15592(끝)**.
- **worker가 실제 커밋한 최대 LSA = `181\|9496`** (프리로드 88행, `worker commit end ... 181\|9496 ... error=0`, 라인 5624).
- **괴리 = 176\|15592 → 181\|9496**, 로그 페이지로 176에서 181까지 약 5페이지분.

### 왜 frontier가 176에 머물렀나
frontier는 커밋 순서대로, 선행 트랜잭션이 전부 완결돼야 전진하는 in-order 워터마크다. 리더는 커밋 레코드를 **순서대로 읽어** frontier를 올리는데, 페이지 181을 읽다 -81로 죽었다(라인 5628). 그래서:
- worker는 프리로드(181\|9496)를 **이미 적용·커밋**했지만(라인 5610 apply end rows=88 → 5624 commit end),
- 리더는 그 커밋을 frontier에 **반영하기 전에** 다음 레코드(페이지 181의 뒷부분)를 읽다 크래시 → frontier는 176에 동결.

### 대기(PENDING) 정황
reader schedule의 status 분포: `status=0`(ACCEPTED) 40건, **`status=1`(PENDING) 5건**.
코드상 status 값(`log_applier.c:6717~6727`, `la_coordinator_try_schedule_task` 반환): 0=`LA_DISPATCH_ACCEPTED`, 1=`LA_DISPATCH_PENDING`.
PENDING 5건 중 이 run의 사용자 트랜잭션:
- `reader schedule trid=432 commit_lsa=181\|10048 ... dependency=178\|1824 status=1 dispatch=0` (라인 5793)
- `reader schedule trid=432 commit_lsa=181\|11320 ... dependency=181\|9496 dependency_is_ref=1 status=1 dispatch=0` (라인 5805)
- `reader schedule trid=437 commit_lsa=181\|12528 ... dependency=181\|9496 status=1 dispatch=0` (라인 5814)

즉 사용자 트랜잭션 432/437은 프리로드(181\|9496)에 **의존(dependency)으로 묶여 PENDING(dispatch=0)으로 대기**하다가 크래시로 완결되지 못했다. frontier가 못 올라간 것과 동일 사건의 양면이다.

---

## 4. ★ 누락 7행(+1)의 trid별 마스터→슬레이브 경로와 유실 지점

### 4.1 누락 행의 정체 (스냅샷·스키마로 확정)
`schema.sql`: item_0/item_1의 PK `id`는 AUTO_INCREMENT. 프리로드가 id 1~40을 소진, 이후 사용자 트랜잭션 삽입이 그 뒤 id를 받는다.
마스터 스냅샷(`snapshot/master/table-0.rows`, 47행)에서 id 41 이후:

| 마스터 id | logical_key | payload | 트랜잭션(journal/tx) | 테이블 |
|---|---|---|---|---|
| 41 | 1000000 | tx000001-op001 | tx-000001 (commit) | item_0 |
| 42 | 1000001 | tx000002-op001 | tx-000002 (commit) | item_0 |
| (43) | 1000002 | — | tx-000003 (**abort**) → 행 없음, id만 소진 | item_0 |
| 44 | 1000003 | tx000004-op001 | tx-000004 (commit, 4행) | item_0 |
| 45 | 1000004 | tx000004-op002 | tx-000004 | item_0 |
| 46 | 1000005 | tx000004-op003 | tx-000004 | item_0 |
| 47 | 1000006 | tx000004-op004 | tx-000004 | item_0 |
| (48~50) | 1000007~9 | — | tx-000005 (**abort**) → id만 소진 | item_0 |
| 51 | 1000010 | tx000006-op001 | tx-000006 (commit) | item_0 |

`snapshot/master/table-1.rows`(41행)의 id 41 = logical 1000011 = **tx-000007(commit, item_1)** 도 동일하게 유실.
→ 누락은 정확히 **커밋된 사용자 트랜잭션 5건(tx1·tx2·tx4·tx6·tx7)의 삽입 행 8개**(item_0 7개 + item_1 1개). abort된 tx3/tx5는 애초에 행 없음(기대도 discard, journal `outcome:abort`).

### 4.2 마스터는 정상 커밋했는가 — 그렇다
마스터 로그 `[WSET] SYSOP master ... LOG_SYSOP_END_COMMIT ... repl_items=1`:
- trid=432 `sysop_lsa=181\|10048` (라인 상 END_COMMIT repl_items=1)
- trid=480 `sysop_lsa=182\|8752`
그리고 trid=480의 전체 수명(FRAGMENT→PUBLISH→COLLECT→DEPENDENCY→COMMIT `commit_lsa=182\|10024`)이 `master_server.err` 2805~2847에 정상 기록. 마스터 로그에는 corruption·fatal·abort가 **전무**(정상 HA mode 변경 3건과 standby 쪽 연결 종료 로그뿐). → **마스터 정상, 슬레이브 단독 유실** 확정.

### 4.3 슬레이브에서 어디서 끊겼나 — "완결 적용 안 됨"
- `worker commit end trid=(432|437|480)` grep 결과 **0건** (세션1·세션2 통틀어). 즉 이 run 사용자 행을 worker가 슬레이브 DB에 **커밋한 사실이 로그에 없다**.
- trid=437은 세션2에서 `worker apply begin trid=437 commit_lsa=181\|12528 ... dispatch=12`(라인 6258)로 **적용 시작**했으나 3줄 뒤 크래시2(라인 6261)로 중단 → apply end/commit end 없음.
- 재적용(세션2) 중 **사용자 logical_key(1000000대)·사용자 id(41,42,44~47,51)에 대한 -670 unique 위반은 한 건도 없다**. -670은 전부 프리로드 id(item_0 키 1~40, item_1 1~40, parent 1~3)에만 발생(라인 5985~6240, class별 집계: item_0 40 / item_1 40 / parent 8 = 88 = 프리로드 전량). → 재적용 시점에 사용자 행이 슬레이브에 **없었다** = 세션1에서 durable 커밋된 적 없음.

### 4.4 유실 패턴 분류 (요청 3의 핵심 구분)
- **사용자 행 8개(id 41,42,44~47,51 + item_1 41): "아예 완결 적용 안 됨"**. 프리로드 의존으로 PENDING 대기 중 크래시 → worker commit 없음 → 재적용도 크래시 루프로 완결 불가. "frontier 뒤 worker 커밋 후 rewind-skip"이 **아님**.
- **프리로드 88행: "frontier 뒤에서 worker가 커밋 → rewind → 재적용 -670"** 패턴에 해당(세션1에서 worker commit end 181\|9496, 라인 5624 → frontier는 176 동결 → 세션2 rewind 176 → 프리로드 재삽입 → -670). 단 이 행들은 유실 대상이 아니라 **-670 소음·재크래시의 원인**.

(주의: trid는 마스터 트랜잭션 디스크립터 슬롯의 재사용 번호다 — trid=427 하나가 마스터 로그에서 778회·commit_lsa 5개(177\|2536/178\|1824/179\|600/179\|16256/181\|9496)에 걸쳐 나타난다. 그래서 trid↔tx 1:1 매핑은 불완전하며, 177/178/179의 rows=1 조각들은 LSA상 프리로드(181\|9496)보다 앞서므로 이 run이 아닌 **선행 run/드레인분으로 추정**. 결정적 사실은 trid 번호가 아니라 "432/437/480의 worker commit end 부재"와 "재적용에 사용자키 -670 부재"다.)

---

## 5. 재시작 전/후 rows=0 분포 (요청 4)

worker apply end rows 집계 전체: **rows=0 29건, rows=1 11건, rows=88 2건**.
worker commit end 세션 분할(기준선 라인 5637): **세션1 32건 / 세션2 9건**.

- **재시작 전(세션1) rows=0**: trid 22~382 등 — reader commit에서 전부 `items=0`(빈 트랜잭션: `SELECT LOCAL_TRANSACTION_ID`, abort 등 복제행 없는 커밋). 즉 **정상적으로 적용할 행이 없는 것**이지 유실이 아니다. 세션1에서 "행이 있어야 하는데 rows=0"인 사례는 없음.
- **재시작 후(세션2) rows=0**: trid 383(176\|15248), 424(176\|15592), 442(181\|13560), 425(181\|14664), 454(181\|15016) — 역시 reader commit `items=0`인 빈 트랜잭션 재처리. 정상.
- 결론: rows=0는 전부 "원래 빈 트랜잭션"이며 유실과 무관. **유실은 rows=0가 아니라, 적용돼야 할 사용자 트랜잭션(432/437/480)이 PENDING/미완결로 worker apply end·commit end에 도달하지 못한 것**이다.

---

## 6. 최종 상태와 "캐치업" 오보 (요청 6)

- 리더 final_lsa는 세션2에서 `181\|15248`까지 전진했으나 frontier(committed_lsa)는 `176\|15592`에서 동결. committed_rep_lsa는 `176\|14408`.
  - 참고: 요청에 적힌 "committed_rep가 171에 멈춤"은 로그상 **176\|14408까지는 전진**했다(초반 171\|6160→175\|1320→176\|14408). 171에 오래 머문 구간은 있으나 최종 정지점은 176\|14408. repl 워터마크가 commit 워터마크(176\|15592)보다 뒤처지는 것은 설계상 정상 lag.
- 마스터는 이미 `182\|10024`(trid 480)까지 진행 — 슬레이브는 5페이지 이상 뒤처진 채 크래시 루프.
- **applier 로그 자체에는 "caught up / up-to-date" 류의 캐치업 선언 메시지가 없다**(grep 0건). "캐치업 오보"는 applier 로그가 아니라 검증/판정 쪽 산출물의 해석으로 보인다 — run 판정은 `INCONCLUSIVE_SERIAL_SNAPSHOT`, `master_slave_ok=false`, 그리고 **슬레이브 스냅샷은 애초에 접속 실패**(`snapshot/slave/table-0.rows`: "Failed to connect to database server 'testdb' on youngjun4") 상태에서 `slave_rows=0`으로 기록됨. 즉 state-progress.json의 slave_rows=0은 "슬레이브에 0행"이 아니라 **크래시 루프 중이라 스냅샷이 슬레이브를 읽지 못한 것**일 수 있다(실제 슬레이브에는 최소 프리로드 88행이 세션1에 커밋돼 있을 것 — **추정**, 접속 실패로 직접 확인 불가). 사용자 행 8개가 없다는 결론은 접속 여부와 무관하게 §4.3(worker commit 부재·재적용 -670 부재)로 독립 확정된다.

---

## 7. 인과 요약 (입증/반증)

입증된 인과 사슬:
1. 세션1에서 리더가 커밋 순서대로 읽으며 frontier를 176까지 전진, worker는 그보다 앞선 프리로드(181\|9496)를 적용·커밋.
2. 리더가 페이지 181을 더 읽다 재시도 소진 → `ER_LOG_PAGE_CORRUPTED(-81)` → 자발적 shutdown (`log_applier.c:9555`, 라인 5628). **frontier는 176\|15592에 동결.**
3. 재시작은 durable frontier(≈176\|14912)로 rewind. 프리로드는 이미 슬레이브에 커밋돼 있으므로 재삽입 → `-670` unique 위반 88건. 코드에 **복구창 멱등 skip이 없다**(`la_ignore_on_error`는 `PRM_ID_HA_APPLYLOGDB_IGNORE_ERROR_LIST` 의존이며 -670 기본 무시 아님; `log_applier.c:5108`에서 `ER_HA_LA_FAILED_TO_APPLY_INSERT`로 표출). 따라서 "failed to apply"로 드러남.
4. 사용자 트랜잭션 432/437은 프리로드 의존으로 PENDING 대기 중이었고, 매 재시작마다 같은 페이지 181에서 다시 크래시(라인 6261) → **worker commit에 도달 불가** → 마스터가 커밋한 8개 행이 슬레이브에 영영 적용 안 됨.

따라서 요청의 가설 "데이터 유실 = 병렬 frontier lag + 재시작 rewind + 복구창 error-skip 미구현":
- **부분 입증**: frontier lag·rewind·멱등 skip 미구현은 모두 사실이고 -670 크래시 루프를 영속화함.
- **정정**: 그 사슬이 "worker가 커밋한 사용자 행을 rewind가 되돌려 유실"시킨 것은 아니다. 사용자 행은 worker 커밋 자체에 도달하지 못했다(완결 적용 실패). 유실의 **최상류 트리거는 페이지 181 읽기 실패(-81)**이고, frontier lag/멱등 미구현은 그 트리거가 매 재시작 반복되게 만드는 **악화 인자**다.

### 설계 함의(짧게)
- 복구창 멱등 skip(이미 적용된 LSA ≤ worker 최대 커밋 구간의 -670/중복은 무시)이 있었다면 재시작 후 -670 소음은 사라졌겠지만, **페이지 181 읽기 실패 자체는 그대로**라 크래시 루프와 사용자 행 유실은 남는다. 즉 멱등 skip은 필요하되 충분하지 않다.
- 페이지 읽기 실패(끝 페이지 부분기록/copylogdb 미완충 race 가능성 — 추정)에 대한 재시도/대기 정책(`LA_GET_PAGE_RETRY_COUNT`, `log_applier.c:9548`)이 이 상황을 흡수하지 못한 점이 1차 교정 대상.
