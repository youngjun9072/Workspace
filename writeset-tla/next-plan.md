# writeset TLA+ 탐색 이후 작업 계획

TLA+ 탐색(findings.md)에서 남은 항목을 HA 재현, 코드 확인, 수정으로 닫기 위한 계획이다. 대상 코드는 PR #8052 브랜치(feature/CBRD-27508-parallel-applylogdb-writeset, 6bd39a696 기준)다. 실행, 배포, conf 변경, 커밋은 지시를 받고 진행한다.

## 1. 작업 목록과 우선순위

1. 라벨 SYSOP_END 사용자 행 키 유실: HA 재현, 수정, 수정 후 미재현 확인
2. 되돌린 INCR 증가가 slave에 남음: 1번 재현 시나리오 끝에 abort 변형을 붙여 함께 확인
3. 커밋 시점에 복제가 꺼지는 경우: 코드로 도달 가능성 확인, 가능할 때만 재현 설계
4. 조각 슬롯 누수: 수정 방법 결정 후 수정, 기존 누수 측정 스크립트로 전후 비교
5. 재시도 오류 뒤 앞 항목 유실: develop 공통이라 후순위, 재현 방법만 정리
6. 재시작 뒤 미결 2PC 키 유실: 작업하지 않는다(복제 레코드 자체가 없고 develop과 같음)

## 2. 라벨 SYSOP_END 사용자 행 키 유실

### 증명하려는 것

- 수정 전: 아래 순서에서 master가 사용자 행 키를 발행하지 않아, 같은 행을 바꾼 뒤 트랜잭션이 앞 트랜잭션을 기다리지 않고 slave에서 먼저 반영된다. 그 결과 slave의 그 행 값이 master와 다르다.
- 수정 후: 같은 순서에서 키가 발행되어 뒤 트랜잭션의 의존성이 앞 트랜잭션 커밋 이상이 되고, slave 값이 master와 같다. 동시에 serial 키는 여전히 버려진다(serial 회귀 없음).

### 결함이 생기는 코드 경로

1. INCR/DECR은 시작할 때 instant lock 모드면 flush 표시를 열고 subtransaction으로 실행한다(query_executor.c:20500-20512).
2. 증가하려는 행을 같은 트랜잭션이 이미 호환되지 않는 모드로 잡고 있으면, lock manager가 instant 모드를 끈다(lock_manager.c:3984-3993, lock_stop_instant_lock_mode).
3. 그러면 INCR은 flush 표시를 닫은 뒤 log_sysop_commit 대신 log_sysop_attach_to_outer로 끝난다(query_executor.c:20543-20565). 표시 안에서 만든 복제 레코드는 NEED_FLUSH로 남고 로그에 쓰이지 않는다.
4. 같은 트랜잭션의 다음 비어 있지 않은 system operation이 끝날 때 그 레코드를 쓰고(log_manager.c:4010-4030), 라벨을 붙이며(4052-4077), 그 연산 안에서 모은 키를 버린다(4087-4094, wset_discard_sysop_keys).
5. 그 연산이 사용자 행을 바꾸는 연산이면, 커밋까지 락을 쥔 사용자 행 키가 사라진다.

### 재현 전 코드 확인 (0단계)

- 4번의 "다음 system operation" 안에서 사용자 행 키가 모이는 DML 경로를 특정한다. 후보는 행 갱신과 인덱스 갱신이 system operation 안에서 일어나는 경로다(locator_update_index, btree 분할, 새 heap 페이지 할당 등). 어느 경로가 키 수집(locator_sr.c:9031-9070, 8300-8350)을 sysop 안에서 하는지 코드로 확인해 재현 SQL을 정한다.
- 확인이 어려우면 master trace로 바로 판정한다. trace level 1에서 라벨 붙은 SYSOP_END마다 다음 줄이 남는다(log_manager.c:4114 부근).
  `[WSET] SYSOP master commit_order trid=… dependency=… sysop_lsa=… dropped_keys=N overflow=… reason=…`
  reason이 incr 또는 mixed이고 dropped_keys가 1 이상인데 그 트랜잭션이 사용자 행을 바꿨다면 결함 경로를 탄 것이다.

### 재현 시나리오 (초안, 0단계 결과로 SQL 확정)

준비: 테이블 t(id INT PRIMARY KEY, v INT, cnt INT), 행 (1, 0, 0), (2, 0, 0). HA 2노드, 8052 빌드, master trace level 1.

세션 A (autocommit off)
1. `UPDATE t SET v = v WHERE id = 1;` 행 1에 X 락을 잡는다.
2. `SELECT INCR(cnt) FROM t WHERE id = 1;` 같은 행이라 instant 모드가 꺼지고 INCR 레코드가 NEED_FLUSH로 남는다.
3. 0단계에서 정한, system operation 안에서 키를 모으는 DML로 행 2를 바꾼다. 예: `UPDATE t SET v = 100 WHERE id = 2;`
4. `COMMIT;`

세션 B (A 커밋 직후)
5. `UPDATE t SET v = 200 WHERE id = 2; COMMIT;`

반복: 1~5를 수백 회 반복하거나 B를 여러 세션으로 늘려, slave 적용 순서가 바뀔 기회를 만든다(워커 10).

### 확인 방법

- master trace: 3번 연산의 SYSOP_END에 dropped_keys가 1 이상, A 커밋 라벨의 dependency가 A의 SYSOP_END, B 커밋 라벨의 dependency가 A 커밋보다 작으면 결함 경로다.
- slave trace: B 태스크가 A 커밋 태스크보다 먼저 시작·완료된 기록이 있는지 본다.
- 데이터: 반복이 끝난 뒤 master와 slave에서 `SELECT id, v, cnt FROM t ORDER BY id`를 비교한다. 행 2의 v가 다르면 재현이다. 하니스 비교는 반드시 slave 접속값을 직접 확인한다.
- 재현이 확률적이면 회수와 불일치 건수를 함께 기록한다.

### 수정과 수정 후 확인

- 수정안: 라벨 SYSOP_END에서 버릴 키를 "그 연산 안에서 모았고, 그 SYSOP_END가 실제로 로그에 쓴 레코드의 키"로 한정한다. TLA+ 모델(WritesetSysop.tla의 FixDiscard)에서 사용자 키 보존과 serial 키 폐기가 함께 성립함을 확인했다.
- 구현 확인 사항: SYSOP_END가 쓴 레코드와 연산 안에서 모은 키를 대응시킬 정보가 지금 구조에 있는지 log_manager.c와 writeset.cpp에서 확인한다. 없으면 레코드에 키 범위를 기록하는 방식 등 대안을 먼저 제안한다.
- 수정 후 같은 시나리오에서 dropped_keys에 사용자 키가 없고, slave 데이터가 일치해야 한다.
- serial 회귀 확인: AUTO_INCREMENT 테이블 INSERT와 NEXT_VALUE를 여러 세션에서 섞어 돌려, serial 값과 행이 master와 같은지 본다(기존 하니스 serial 케이스 활용).

## 3. 되돌린 INCR 증가가 slave에 남음

### 증명하려는 것

2절 1~3단계 뒤 COMMIT 대신 ROLLBACK을 하면, master는 INCR 증가를 되돌리지만 slave는 조각으로 이미 적용해 cnt가 남는다.

### 방법

- 2절 시나리오의 4번을 `ROLLBACK;`으로 바꾼 변형을 같이 돌린다.
- 확인: master와 slave의 행 1 cnt 비교. slave cnt가 더 크면 재현이다.
- 이 결함은 기존 todo("develop - 되돌린 INCR 증가가 slave에 남음" 2번)와 같은 뿌리이고, 2절 수정만으로는 닫히지 않는다(키가 아니라 레코드가 조각에 실리는 문제). 근본 수정은 "instant 모드가 꺼진 INCR이 NEED_FLUSH 레코드를 남기지 않게" 하는 쪽이며, 별도로 방안을 제안한다.

## 4. 커밋 시점에 복제가 꺼지는 경우

### 증명하려는 것

키를 모은 트랜잭션이 커밋할 때 log_does_allow_replication()이 거짓이면 라벨 없이 커밋만 쓰고 record_commit도 하지 않는다(log_manager.c:5644 부근). 이때 그 커밋에 복제 레코드가 실릴 수 있는지, 실린다면 slave가 그 커밋을 어떤 의존성으로 적용하는지 확인한다.

### 방법

- 코드 확인만 먼저 한다. log_does_allow_replication()의 조건(HA 서버 상태, 복제 억제 플래그)이 트랜잭션 도중에 바뀌는 경로와, 바뀐 뒤에도 복제 레코드가 커밋에 실리는지 본다.
- 도달 불가면 문서에 근거와 함께 닫는다. 도달 가능하면 그 상태 전환(대개 failover 전후)을 만드는 재현을 따로 설계하고, failover가 들어가므로 실행은 지시를 받는다.

## 5. 조각 슬롯 누수

### 증명하려는 것

종료 요청이 조각 배정과 겹칠 때 조각 슬롯이 해제되지 않아, 같은 applylogdb 프로세스가 재시작할 때마다 힙 사용량이 는다. 수정 후에는 늘지 않는다.

### 수정 방법 (결정 필요)

- 방법 1(권장): 실패 반환 지점에서 태스크가 조각(LOG_SYSOP_END)이면 슬롯을 해제한다. 대상은 la_coordinator_drain_ready의 enqueue 실패, la_coordinator_process_sysop_end의 submit 실패 두 곳이다.
- 방법 2: pending에서 꺼내기 전에 enqueue가 실패하지 않음을 확인하거나, 실패하면 pending에 되돌려 넣어 la_free_unretired_fragments가 찾게 한다.

### 테스트 방법

- 기존 스크립트 ~/ha_bench_tool/bin/fragment_shutdown_leak.sh를 쓴다. NOCACHE serial INSERT 부하 중 slave 서버 kill을 반복하고, 같은 pid 안 재시작마다 applylogdb의 RSS와 malloc 실제 사용량(gdb로 malloc_info를 불러 arena 사용 바이트)을 기록한다.
- 판정: 같은 pid에서 재시작마다 malloc 사용량이 계속 늘면 누수다. 10-29 측정에서는 재시작당 약 136KB가 늘었다. 수정 전후를 같은 회수로 비교한다.
- 누수에는 develop에도 있는 repl_lists 항목 미해제 몫이 섞여 있으므로, 수정 후에도 0이 아닐 수 있다. 차이가 조각 수에 비례해 줄어드는지로 판단한다.
- 결정적 확인이 필요하면 ASan 빌드에서 같은 시험을 돌려 LeakSanitizer 보고를 본다(빌드·배포는 직접).

## 6. 재시도 오류 뒤 앞 항목 유실 (후순위)

### 증명하려는 것

statement 실행이나 클래스 조회에서 서버가 트랜잭션 전체를 롤백하는 재시도 대상 오류(ER_LK_UNILATERALLY_ABORTED, ER_LK_DEADLOCK_CYCLE_DETECTED)가 나면, 앞서 적용한 항목이 사라진 채 나머지와 적용 표시가 커밋되어 그 트랜잭션의 앞 항목이 영구히 빠지는지 확인한다.

### 방법

- develop 공통 루프라 이 PR 범위 밖이다. 재현은 slave에서 DDL 적용 중 교착을 일으켜야 해서 비용이 크다.
- 우선 코드로 "statement 실행 전 flush가 앞 항목을 이미 서버에 반영했는지, 그 반영이 같은 slave 트랜잭션인지"를 확인해 가능성만 확정하고, todo에 기록한다.

## 7. TLA+ 모델 후속

- 2절 수정안이 코드로 정해지면 그 구현 방식을 WritesetSysop.tla와 SysopExtended.tla에 그대로 옮겨 다시 돌린다(모델 수정안과 코드 수정의 차이를 없애기 위해).
- 모델에서 단순화한 것 중 다음 후보: FK·UNIQUE 해시 규칙(REF/WRITE 슬롯, DELETE→INSERT 재사용), 키 해시 충돌. writeset v2 설계 검토 때 함께 진행한다.
- 모든 TLC 실행은 세션과 분리해 띄우고, 상태 디렉토리는 디스크(/home/youngjun/tools/tlc-meta/)에 두며 실행 후 지운다. /tmp는 RAM 기반이다.

## 8. 편향 없는 결함 탐색: 코드 커버리지와 문법 기반 무작위 생성 (2026-11-08 추가)

### 배경

TLA+ 탐색(통합 모델, 경계 모델)은 설계 핵심부에서 새 결함을 찾지 못했고, 찾은 것 대부분은 리뷰가 먼저 짚은 곳의 재확인이었다. 기존 HA 하니스의 빈칸이나 이미 나온 결함을 기준으로 새 시나리오를 짜면, 같은 곳만 다시 보게 될 위험이 있다. 그래서 시험 범위의 기준을 우리 추측이 아니라 두 가지 바깥 기준에 둔다.

- 코드 기준: 실제로 한 번도 실행되지 않은 분기
- 문법 기준: CUBRID 11.4 매뉴얼이 허용하는 스키마와 문장 조합

### 증명하려는 것

- 기존 하니스가 writeset 키 수집·해시(master)와 병렬 적용·재시작(slave) 코드 중 어디를 한 번도 밟지 않는지 목록으로 확정한다.
- 문법 기반 무작위 부하로 그 빈 분기를 밟았을 때 master와 slave의 결과가 다른 경우가 있는지 찾는다.

### 방법

1. 커버리지 빌드
   - 6bd39a696을 Debug + `--coverage`로 별도 빌드 디렉토리(build_cov)와 별도 설치본(~/CUBRID-cov)에 빌드한다. 기존 설치본과 build_* 디렉토리는 건드리지 않는다.
   - 실행 중 .gcda는 빌드 트리의 절대 경로에 쓰이므로, youngjun4에도 같은 경로에 빌드 트리(.gcno와 디렉토리)를 두거나 GCOV_PREFIX를 쓴다.
   - .gcda는 프로세스가 정상 종료할 때 쓰인다. 측정이 끝나면 `cubrid service stop`으로 내리고 모은다(SIGKILL로 죽은 프로세스의 몫은 남지 않는다).
2. 기준선 측정
   - 기존 하니스(random_campaign, dep_mix 전체 mix, sql_surface_long, fk_multi_schema, random_pairs)를 정해진 시간만큼 돌린다.
   - 대상 파일의 분기 커버리지를 gcov/lcov로 뽑는다. master: locator_sr.c 키 수집부, src/transaction/writeset/, log_manager.c의 writeset 경로, serial.c, replication.c. slave: log_applier.c, src/transaction/applier/.
   - 결과물: 실행되지 않은 분기 목록(파일:줄, 조건), 그 분기에 들어가려면 필요한 입력의 짐작.
3. 문법 기반 무작위 생성기
   - 매뉴얼 문법을 기준으로 스키마(타입, 콜레이션, PK/UNIQUE/복합/역순/함수/필터 인덱스, FK와 동작, 파티션, 상속, 트리거, SERIAL)와 문장(INSERT/UPDATE/DELETE/MERGE/REPLACE/ODKU, 다중 테이블, 서브쿼리, ORDER BY LIMIT, savepoint, rollback)을 고르게 무작위로 조합한다. 기존 결함을 기준으로 가중치를 두지 않는다.
   - 여러 세션 동시 실행, 일부 런은 slave applylogdb·서버 kill과 겹친다.
   - 판정은 master와 slave의 결과 일치만 본다(정답을 미리 알 필요가 없다). 비교는 PK와 hex(키) 기준 정렬, slave 조회는 slave 노드에 직접 한다.
   - 시드를 기록해 불일치가 나오면 같은 입력으로 다시 돌릴 수 있게 한다.
4. 재측정
   - 3번을 돌린 뒤 커버리지를 다시 재서 빈 분기가 얼마나 줄었는지 숫자로 본다. 여전히 비어 있는 분기는 따로 공략한다.

### 확인 방법

- 불일치가 나오면: 시드로 재현 → 해당 트랜잭션의 master 로그와 slave 적용 순서를 [WSET] 트레이스로 대조 → 원인 코드 확정. develop 빌드에서도 같은지 확인해 이 PR의 회귀인지 가른다.
- 불일치가 없으면: 커버리지 수치와 남은 빈 분기 목록을 "확인된 범위"로 기록한다.

### 실행 조건

- 빌드는 youngjun3에서 바로 진행한다.
- HA 배포·기동은 지시를 받고 진행한다. youngjun4에는 11-06부터 demodb HA(2719-bb62be5)가 떠 있으므로 내리기 전에 확인한다.
- conf는 메모리 전문(reference_cubrid_ha_conf)대로 쓴다.

### 기준선 1차 결과 (2026-11-08 22:17 ~ 11-09 02:23)

- 실행: 커버리지 빌드(6bd39a696, Debug + --coverage, ~/CUBRID-cov)를 양 노드에 배포하고 testdb를 새로 만든 뒤, 기존 하니스 random_campaign.sh를 4시간(시드 20261108) 돌렸다. youngjun3 master, youngjun4 slave, conf be315c1b/ea141281(워커 10).
- 결과: 시나리오 25개 모두 PASS(c3, surface, randpair, fkmulti, kill copylogdb, kill server, depmix, bigtx, statabort), 실패 0, slave fail_counter 0, 역할 변화 없음, 마지막 전체 비교 테이블 65개 일치. eof watcher가 master 로그 정체 덤프 2건을 남겼다(log/random_campaign_20261108_221750/eof, 미확인).
- 처리량: slave db_ha_apply_info 기준 커밋 712,081건, INSERT 3,351,394건, UPDATE 2,681,576건, DELETE 741,499건, 스키마 2,560건, 실패 0건. 카운터가 applylogdb 재시작을 넘어 누적되는 값이라고 보았으나 코드로는 확인하지 않았다(start_time은 마지막 재시작 02:13).
- 커버리지: 수집 실패. 정상 종료한 클라이언트 도구(csql, applyinfo)의 기록만 남고, cub_server(master 키 수집·writeset)와 applylogdb(코디네이터·워커·gate)의 .gcda가 쓰이지 않았다. 두 데몬이 종료할 때 일반 프로세스 종료 경로를 거치지 않아 gcov 기록 단계가 실행되지 않은 것으로 본다(추정). 수집 방식을 사전에 확인하지 않은 탓이다.
- 다음: 데몬에 gdb로 붙어 `__gcov_flush()`를 주기적으로(10분) 호출해 기록을 파일에 쓰게 하고, 기준선을 다시 잰다. flush가 실제로 기록을 쓰는지 먼저 짧게 확인한다.
