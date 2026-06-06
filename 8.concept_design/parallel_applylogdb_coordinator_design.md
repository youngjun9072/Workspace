# 병렬 applylogdb 코디네이터 컨셉

이 문서는 parallel `applylogdb` PoC 이후 실제 구현으로 넘어가기 위한 병렬화 컨셉을 정리한다.
상세 자료구조·API가 아니라, 어떤 책임을 새 모듈로 분리할지와 transaction 간 충돌/순서를 어떻게 다룰지를 잡는다.
**공부·발표 자료용 상세 문서**이며, 본문은 발표 스토리 순서(Act A~F = 발표 요약 [1]~[16])로 구성한다.
벤더별 더 깊은 근거는 같은 폴더의 `reference/{base,mysql,pgsql}/`, `coordinator_design_mapping_from_vendors.md`, `cubrid_special_table_scenarios.md`에 있고, 본 문서 끝 **참고문헌**에 링크를 모았다.

## 발표용 요약 (1차 발표)

> 흐름: **CUBRID 현재(로지컬) → PoC로 병렬 가능성 확인 → "다른 DB는 어떻게?"(병렬화는 로지컬만) → 벤더 조사(PG·PGD 탈락, MySQL 채택) → 코디네이터 설계(Phase1/2) → 정확성 시나리오 → 재시작 문제.** 각 항목 상세는 Act A~F.

| # | 핵심 | 상세 |
|---|---|---|
| [1] | master 로그 → copylogdb 복사 → applylogdb 적용. 현재 단순(tranid 기반) | A.1 |
| [2] | applylogdb는 행 단위 재실행 = **로지컬 복제**(slave LSA ≠ master LSA) | A.2 |
| [3] | 물리 vs 논리 — 물리는 단일스레드·경직, **병렬화는 로지컬만** | A.3 |
| [4] | PoC = LogReader+ApplyWorker(poc_design.md), develop 대비 worker/계측 추가, dependency는 의도적 제외 | B.1 |
| [5] | PoC 결과: slave 반영 약 3.4×↓·lag 4–6×↓ → **병렬화 가능성 확인** | B.2 |
| [6~7] | 정식(의존성) 병렬화는? → 타 벤더 조사(전부 로지컬 병렬) | C |
| [8] | PostgreSQL: 단일 구독 직렬 → **탈락**(반면교사) | C.1 |
| [9] | EDB PGD: apply측 행충돌+롤백 backstop. 멀티마스터·폐쇄·구조 부적합 → **탈락**(한 측면만 선례) | C.2 |
| [10] | MySQL: 병렬실행↔순서보존 분리+coordinator = CUBRID와 1:1 → **채택** | C.3 |
| [11] | 코디네이터 = LogReader enqueue 강화. Phase1(로그 무변경)/Phase2(로그 포맷 변경=분량·기간 미정이라 분리) | D |
| [12] | **applier는 FK를 모른다**(로그=class+PK), FK는 server 검사 → 보수적 순서 보존 | D.4 |
| [13] | commit 순서 강제 — 자식이 부모보다 먼저면 server FK 실패 → 복제 중단 | E.1 |
| [14] | 기타 충돌/순서 시나리오 + 이 설계의 동작(매트릭스) | E.2~E.3 |
| [15] | **병렬화 부작용**: out-of-order durable commit이 watermark skip 빠져나가 재시작 중복 | F.1 |
| [16] | 해결: applied set 추적 / 윈도우 bound / commit 순서 강제 중 택 | F.2 |

**예상 질문**: ▸"왜 commit 순서?"=FK/상속을 applier가 못 가려서, server가 FK 검사라 비순차면 에러 ▸"재시작 중복?"=직렬은 멱등 skip으로 해결, 병렬은 보강 필요 ▸"파티션·LOB?"=파티션 스키마 규칙으로 안전, LOB 비복제 ▸"왜 Phase2 분리?"=repl 로그 포맷 변경이라 분량·기간 예측 어려움 ▸"PGD 쓰지?"=멀티마스터·폐쇄·구조 부적합.

---

# Act A. CUBRID 복제 현황 & 로지컬 복제 (발표 [1]~[3])

## A.1 현재 CUBRID HA 복제 흐름 & 용어

CUBRID HA 노드는 `cub_master`(1) + `cub_server`(1+) + **`copylogdb`**(1+, 복제 로그 복사) + **`applylogdb`**(1+, 복제 로그 반영)로 구성된다 [C1].

```text
master                              slave
  트랜잭션 로그(active/archive)  ──►  copylogdb  : master에서 트랜잭션 로그를 받아 복사 저장
                                         │          (ha_copy_log_base, SYNC/ASYNC = ha_copy_sync_mode)
                                         ▼
                                     applylogdb : 복사된 로그를 읽어 slave DB에 반영
                                         │          (반영 진도는 내부 카탈로그 _db_ha_apply_info에 기록)
                                         ▼
                                     slave DB (cub_server)
```

- **복사와 반영을 분리**해서, 반영 지연이 진행 중 트랜잭션에 영향을 주지 않는다 [C1].
- 본 문서 개선 대상 = **applylogdb의 반영(apply) 단계**.

용어:
- **복제(replication)**: master 변경을 slave가 따라 적용해 같은 상태 유지. master/slave = source/replica(MySQL) = publisher/subscriber(PostgreSQL).
- **복제 로그(repl log)**: master가 "무엇이 바뀌었나"를 기록. slave가 읽어 재현.
- **LSA (Log Sequence Address)**: 로그 안 위치(번호표). "어디까지 처리했나". MySQL binlog position·PG LSN에 대응.
- **class**: CUBRID에서 **테이블**(예시의 `TblA` = class A).
- **코디네이터**: worker 앞단에서 "어떤 transaction을 지금 보내도 되나(충돌·순서)"를 판단해 분배하는 계층(새로 도입).
- **committed_lsa / 순서 정리**: "어디까지 (순서대로) 반영 완료했나" 진도. 순서 정리 = 병렬 결과를 commit 순서대로 줄 세워 committed_lsa 전진.
- **barrier**: 병렬화하지 않고 직렬로 끊는 경계(DDL 등).

> 비유: 복제 로그 = master의 "작업 지시서", 코디네이터 = "동시에 시켜도 되는 일 / 순서 지킬 일"을 나눠 일꾼(worker)에 배분하는 반장.

## A.2 로지컬 복제 = 행 재실행 (CUBRID 소스 확인)

applylogdb worker는 slave에 DB client session으로 붙어 복제 로그를 **행/문장 단위로 다시 실행**한다 — `la_apply_insert_log`/`update_log`/`delete_log`/`statement_log`(`log_applier.c:897-902`, worker client session `:1720~`) [C2]. 즉 물리 페이지 redo가 아니라 **논리(logical) 적용** → **slave는 자기 로그를 새로 생성하므로 slave LSA ≠ master LSA**.

정확성 판단의 전제(코드 확인) [C2]:
- **적용 경로**: `la_apply_*_log` → `la_repl_add_object`(WS_REPL_OBJ 리스트 적재, `:7589`) → `locator_repl_flush_all` 벌크 flush(`:7470`). 질의 실행기가 아니라 locator 복제 경로로 레코드 이미지를 직접 반영.
- **복제는 PK 기반**: 복제 로그 항목 = `class + PK 값 + operation`(`la_make_repl_item:5708~`; 마스터 측 `replication.c:repl_log_insert`는 PK 인덱스에서만 기록). → 복제 테이블 **PK 필수**, class는 OID(`db_find_class→ws_oid`)로 식별.
- **applier(client) ↔ server 계층 구분**: `la_apply_*`는 변경을 모아 server에 보낼 뿐, **FK 검사는 slave server**의 `locator_insert_force`/`update_force` 안에서 일어난다.
- **server는 repl 적용에도 FK를 검사**: `xlocator_repl_force` → `locator_insert_force(..., dont_check_fk=false)`(`locator_sr.c:7029,7256`) → `if (has_index && !skip_checking_fk) locator_check_foreign_key()`(`:5198-5201`), 전역 `locator_Dont_check_foreign_key=false`(`:116`). → 자식을 부모보다 먼저 적용하면 **FK 위반 → apply 에러 → 복제 중단**(단 applier는 FK를 모름 — Act D.4).
- **실패 처리**: ① master abort면 그 트랜잭션 repl 리스트 비움(`LOG_ABORT → la_free_repl_items_by_tranid`, `:6014,8744`). ② apply 에러는 재시도 가능 시 재시도(`la_retry_on_error`→`LA_SLEEP`+continue, `:8841-8849`), 그 외 실패는 `fail_counter`++(`:7703,2093`). 트리거는 `db_disable_trigger`로 끔(`:1831`) → 재실행 없음.
- (참고) `committed_lsa`는 읽기 가시성(MVCC)에 안 쓰임 → 슬레이브 읽기 일관성은 본 설계 범위 밖(사용자 결정).

## A.3 피지컬 vs 로지컬 복제 — 병렬화는 로지컬만

| | 물리(physical) 복제 | 논리(logical) 복제 |
|---|---|---|
| 무엇을 보내나 | 로그(WAL/페이지 변경)를 **그대로 복사·재생** | 변경을 **행 단위로 재실행**(INSERT/UPDATE/DELETE) |
| 비용/속도 | 레코드당 쌈, 단 **단일 스레드 재생** | 레코드당 비쌈(파싱·인덱스·제약 처리) |
| 유연성 | 낮음(클러스터 통째·동일 버전·읽기 전용 standby) | 높음(선택 복제·버전 간·이기종·쓰기 가능 replica) |
| 병렬화 | 어려움(LSN·페이지 종속, recovery는 단일 startup process) | 상대적으로 쉬움(트랜잭션/행 단위 독립성 판단 가능) |

- **물리가 "레코드당 싸다"고 항상 빠른 건 아니다**: 단일 스레드 재생이라 멀티코어로 바쁜 master를 못 따라가 lag이 쌓일 수 있고, 클러스터 통째·동일 버전·읽기 전용이라 경직되어 *못 하는 일*(선택 복제·무중단 버전 업그레이드·이기종·CDC)이 많다 [B1][B4].
- 그래서 현대 DB는 **유연한 논리 복제**를 택하고, 논리의 약점인 적용 속도를 **병렬화로 메운다**. 물리 redo의 병렬화는 LSN·페이지 종속 때문에 어렵고(PostgreSQL도 parallel recovery는 제안 단계 [P-rec]), MySQL은 애초에 네이티브 물리 지속 복제가 없어 binlog(논리)만 쓴다 [B3].
- → **다른 DB들도 "병렬 적용"은 논리 복제 계열에서만** 제공한다(MySQL MTS, PG parallel apply, EDB PGD). **CUBRID applylogdb도 논리이므로 병렬화가 의미 있다 = 이 프로젝트.** (상세 `reference/base/physical_vs_logical_replication.md`)

## A.4 현 PoC 병렬화와 한계

현 PoC는 commit record를 만나면 `worker_idx = tranid % LA_APPLY_WORKER_COUNT`로 worker를 고른다. 단순하지만:
- ❌ 서로 관련 있는(같은 데이터를 건드리는) transaction도 동시 실행될 수 있다 ← **가장 큰 문제**(복제 결과가 원본 순서와 달라질 수 있음).
- ❌ 서로 독립인 transaction도 특정 worker에 쏠릴 수 있다.

→ 단순 worker picker가 아니라, transaction 간 **충돌·순서를 판단하는 코디네이터**가 먼저 필요하다(Act D).

---

# Act B. PoC 설계·구현·결과 (발표 [4]~[5])

## B.1 PoC 모듈 구조 + develop 비교 + 설계↔코드 delta

**PoC 구조 (`2.design/poc_design.md`)** — 2모듈:
- **LogReader**: active/archive에서 복제 로그 읽기 → `LA_ITEM` 생성, transaction 단위 `LA_APPLY` 구성 → commit log를 만나면 transaction 확정 후 **worker 큐에 enqueue** → worker 완료 결과 수집 → **commit LSA 순서로 전역 완료 판정·`committed_lsa` 갱신·`_db_ha_apply_info` 갱신·item reclaim**. long transaction은 head+log range metadata만 유지.
- **ApplyWorker × N**: 개별 작업 큐·worker-local workspace·슬레이브 서버 개별 세션. row item은 workspace에 적재 후 flush, statement/DDL은 서버에 직접 실행, **flush·commit은 worker 단위 독립**, 처리 성공 시 `last_completed_lsa`를 LogReader에 보고. long transaction은 log range를 재탐색해 item 재구성.

본 설계의 "코디네이터/순서 정리"는 새 모듈이 아니라 **LogReader 책임을 기능 분해**한 것:

| 본 문서 개념 | poc_design.md 위치 |
|---|---|
| 복제 로그 리더 | LogReader의 read/build (LA_ITEM·LA_APPLY) |
| **코디네이터(충돌/순서 판단)** | LogReader의 **enqueue 결정** — 현 `tranid%worker`를 충돌·순서 판단으로 **대체** |
| worker | `ApplyWorker × N` — **그대로** |
| **순서 정리** | LogReader의 **결과 수집 + commit LSA 순서 `committed_lsa` 갱신·reclaim** |

**develop(오리지널) vs PoC** [C2]: PoC(`feature/parallel_applylogdb_poc`)는 develop 대비 `log_applier.c`에 약 **+3,900줄**(worker/dispatch/retire + 계측). **핵심 정합성 메커니즘(LSA·멱등 skip·FK·repl 로그)은 develop과 동일**(develop은 단일 직렬 `la_apply_commit_list`, PoC는 worker 경로로 이전), 더한 건 병렬 골격 + 측정 계측.

**설계(poc_design.md) ↔ 구현 코드 delta**:
- **[코드 > 설계] UPDATE 적용**: 설계 §29는 "insert 연산만 대상"이나 코드는 **INSERT + UPDATE** 지원(`la_is_supported_poc_item`: INSERT·UPDATE(+START/END); statement는 INSERT/UPDATE/CREATE·DROP CLASS). **DELETE는 함수만 있고 미지원.** (최종 보고서 측정도 Insert+Update)
- **[코드 > 설계] 측정 계측·측정용 제약 가드**: `la_Debug_progress`·`la_debug_note_*`; `LA_APPLY_WORKER_REPL_ACTIVE_COUNT`(일부 worker만 flush)·`LA_SKIP_READER_COMMIT_APPLY_INFO`(apply_info 갱신 skip) → **병목 측정 스캐폴딩, 정식 구현에선 제거 대상.**
- **[설계가 의도적 제외 = 코드에도 없음]** §32·34: *"transaction 간 dependency 판별·병렬 스케줄링·정교한 오류 복구는 PoC 범위 제외."* → 코드도 `tranid%worker`(충돌 판단 없음). **→ 코디네이터(충돌/순서 판단)는 PoC가 의도적으로 비워둔 자리를 채우는 다음 단계.**

## B.2 PoC 결과 → "병렬화 가능성이 보인다"

(상세 `final_report.md` / `7.final_test/report.md`) 동일 config(buffer 5G, dwb=0)에서 순차 대비 병렬:
- **slave 전체 반영 시간 약 3.4× 단축, 복제 지연(lag) 4–6× 감소.**
- 단 **워커당(단일 테이블) 처리 시간은 1.5–2× 증가**(insert 8.05→16.10s 등). 병목은 네트워크가 아니라 **slave on-CPU 실제 apply 로직**(로그 생성 prior_lsa, lock, page/space 할당)으로 insert/update 콜체인에서 확인.

→ **병렬화는 효과 있다**는 결론. 단 PoC는 dependency를 안 보고 단순 분배하므로(A.4), *"제대로 된 병렬화(충돌·순서 처리)는 어떻게 하나?"* → Act C.

## B.3 LSA / 진도 관리 (현재 상태 코드) [C2]

applylogdb가 쓰는 LSA(`log_applier.c:465-510`, 구조체 `:282-344`):

**A. 마스터 로그 위치(랙)**: `append_lsa`(마스터가 쓴 끝)·`eof_lsa`(`:500-501`). `append_lsa − committed_lsa` ≈ lag.

**B. applier 진행 — 핵심 4 (영속 대상)**:

| LSA | 의미 | 갱신 |
|---|---|---|
| `final_lsa` | 마지막으로 읽어 처리한 위치(읽기 커서) | 읽기 루프(`:11478`), 재시작 시 `required_lsa`로 초기화 |
| `required_lsa` | **적용할 첫 트랜잭션 start = 복구 재시작점(LWM)** | `la_find_required_lsa`=진행 중 최저 `start_lsa`, 없으면 `final_lsa`(`:4078-4105`) |
| `committed_lsa` | 마지막으로 반영 완료한 **commit 로그** 위치 | retire에서 `result->commit_lsa`로 전진(`:2082`) |
| `committed_rep_lsa` | 마지막으로 반영 완료한 **데이터 변경 로그** 위치 | retire(`:2085`) |

**C. 재시작 baseline**: `last_committed_lsa`/`last_committed_rep_lsa` = 기동 시점 committed 스냅샷(`:468-469`).
**D. 항목 단위**: `LA_ITEM.lsa`(복제 지시 위치) ≠ `target_lsa`(적용할 레코드 이미지 위치, `la_get_recdes:7904`).

- **영속**: `_db_ha_apply_info` 카탈로그에 6개(`final/committed/committed_rep/append/eof/required_lsa`) 기록(`la_log_commit:9734`), 재시작 시 `la_get_last_ha_applied_info`로 로드(최초 기동 `required=eof`, `committed=required` 초기화 `:4628-4643`).
- 정상 진도선: **`required_lsa`(LWM) ≤ `committed_lsa` ≤ `final_lsa` ≤ `append_lsa`(마스터 끝)**.

---

# Act C. 다른 DBMS는 병렬화를 어떻게 하나 (발표 [6]~[10])

> (리마인드) 병렬화는 **논리 복제에서만**. 아래 조사 대상도 전부 논리 복제의 병렬 적용. 벤더↔CUBRID 매핑은 `coordinator_design_mapping_from_vendors.md`, 벤더 상세는 `reference/{mysql,pgsql}/`.

## C.1 PostgreSQL — 탈락

publication/subscription 모델. publisher가 WAL을 logical decoding해 change stream을 만들고 subscriber의 apply worker가 적용한다 [P1]. **단일 구독 내 일반 transaction은 publisher 순서대로 직렬 적용**하며, MySQL처럼 의존성 metadata로 독립 transaction을 병렬 dispatch하지 않는다 [P1]. 병렬이 나타나는 곳은 두 곳뿐:

- **초기 table synchronization**: 구독 생성 시 기존 table 데이터를 snapshot+copy하는 단계를 여러 tablesync worker가 병렬 수행(`max_sync_workers_per_subscription`, 기본 2) [P1][P2].
- **large in-progress transaction streaming(`streaming=parallel`)**: 큰 transaction을 commit 전 `Stream Start`/`Stream Stop`으로 나눠 보내고, leader apply worker가 parallel apply worker(`max_parallel_apply_workers_per_subscription`, 기본 2)에 shm queue로 넘겨 적용. **commit 시점엔 leader가 parallel worker 완료를 기다려 commit 순서를 보존**한다 [P2][P3][P4][P5]. (PG16 비기본 도입 → **PG18부터 기본** [P5])
  - 단 이는 **한 transaction의 stream segment 처리**이지, 여러 transaction 간 의존성 스케줄링이 아니다. 같은 transaction 내 `INSERT`→`UPDATE`처럼 segment 간 순서도 지켜야 한다 [P4].

→ "자동 의존성 병렬 + 전역 순서 보존"의 **직접 모델로 부적합**. (구독 경계를 잘못 자르면 원자성·순서가 깨지는 사례는 "병렬 단위를 잘못 자르면 무엇이 깨지나"의 **반면교사**.) DDL 자동 복제 안 함, subscriber conflict(제약 위반) 시 worker error로 복제 중단 → 사용자 수동 해결 [P6]. (상세 `reference/pgsql/`)

## C.2 EDB PGD — 탈락 (한 측면만 선례)

상용 멀티마스터(구 BDR). **Parallel Apply**: 구독당 writer 여러 개(`bdr.writers_per_subscription` 기본 2 ~ `max` 8). 각 writer는 commit 순서가 origin을 위반하지 않도록 보장하며, **같은 행(tuple)을 쓰려는 선행 트랜잭션이 있으면 그것이 commit될 때까지 대기**(선행 tuple-wait 예방) + 위반 감지 시 **롤백을 backstop**으로 둔다(순수 낙관적 아님). 대기는 `nprovisional/ntuple/ncommit_waits`로 관측. Group Commit과는 비호환 [E1][E2][E3]. (상세 `reference/pgsql/edb_pgd_parallel_apply.md`)

**전체 모델로 채택하지 않은 이유**: ① 토폴로지 — PGD=멀티마스터(노드 간 충돌해소·합의), CUBRID=단방향 master-slave → 불필요·부적합 ② 상용 폐쇄(MySQL은 오픈·소스 검증) ③ 구조는 MySQL이 1:1. **단 "apply 측에서 충돌 판단"** 한 측면은 CUBRID(코디네이터가 slave 측 판단)와 닮아 선례.

## C.3 MySQL — 가장 유사 (채택)

MySQL replication: source가 변경을 binary log에 기록 → replica I/O(receiver) thread가 relay log로 받고 → 병렬 시 **coordinator thread가 relay log를 순차 읽어 worker thread에 배정**한다 [M1].

```text
source                                          replica
  트랜잭션 commit 순서 확정                       I/O receiver thread → relay log
  binary log 기록 (+ dependency metadata    ─►   coordinator: relay log 순차 읽음,
   = sequence_number, last_committed)            의존성 보고 worker에 배정 → worker[0..N]
  binary log 전송                                → commit 순서 정리(SPCO)
```

- **병렬 판단 = 의존성 기준** [M2][M4]: source가 transaction마다 `sequence_number`(binlog 내 논리 순번) + `last_committed`(기다려야 하는 가장 최근 선행 = watermark)를 기록. replica coordinator(`replica_parallel_type=LOGICAL_CLOCK`)가 이를 읽어, `last_committed` 이하가 끝났으면 병렬 실행. worker 수 `replica_parallel_workers`(8.0.27부터 기본 4, MTS 기본 ON). coordinator는 비어 있는 worker 큐에만 트랜잭션 첫 이벤트를 넣고, 빈 큐가 없으면 대기.
- **의존성 계산 모드**(`binlog_transaction_dependency_tracking`) [M3][M5]: `COMMIT_ORDER`(group commit 묶음 기반, 8.0.46 기본)/`WRITESET`(행 write-set 충돌로 더 정밀·병렬 넓음)/`WRITESET_SESSION`(WRITESET + 같은 세션 순서 보존). **단 binlog엔 계산 결과(`sequence`/`last_committed`)만 실리고 write set 해시 자체는 안 실린다**(source 내부 계산용).
- **병렬 실행 ↔ commit 순서 보존 분리** [M2][M4]: worker는 병렬 적용하되 `replica_preserve_commit_order`(SPCO, 8.0.27부터 기본 ON, LOGICAL_CLOCK 필수)가 최종 commit을 source 순서로 강제 → "gap"(뒤 트랜잭션이 앞보다 먼저 commit) 방지 [M6]. DDL·FK·불완전 write set은 보수적 fallback.
- (참고) group commit은 병렬의 필수 조건이 아니라, commit window를 겹치게 해 LOGICAL_CLOCK 병렬도를 높이는 **보조 요소** [M3][M5].

→ **"병렬 실행 ↔ 순서 보존" 분리 + coordinator 분배**가 CUBRID(코디네이터 ↔ 순서 정리/committed_lsa) 구조와 **1:1** → **MySQL 모델 차용.** (상세 `reference/mysql/`)

---

# Act D. CUBRID 병렬화 설계 — 코디네이터 (발표 [11]~[12])

## D.1 아키텍처 & 모듈

코디네이터는 복제 로그 리더와 worker 사이의 판단 계층(= LogReader의 enqueue 결정 강화). 현 PoC는 commit 시 `tranid % worker_count`로 바로 고르지만, 목표 구조는 그 자리에 충돌·순서 판단을 넣는다.

```text
+----------------------+
| 복제 로그 리더          |  복제 record 스캔 → transaction 구성
|                       |  (apply list + commit_lsa + 변경 class set)
+----------+-----------+
           v
+----------------------+
| 코디네이터              |  ① 충돌 여부? ② 어디까지 대기? ③ 어느 worker?
| (충돌/순서 판단)        |  (①② = correctness 우선, ③ = 성능)
+-----+----------+-----+
      |          +------------------+
      v(실행 가능)                  v(대기)
+----------------+        +------------------+
| worker 큐로 이동 |        | pending 상태 유지  |
+--------+-------+        +------------------+
         v
+----------------------+
| worker pool[0..N]     |  복제 항목 적용 → flush → commit → 결과 반환
|                       |  (충돌 판단 안 함)
+----------+-----------+
           v
+----------------------+
| 순서 정리              |  committed_lsa 갱신(commit LSA 순서) · apply info 갱신
|                       |  · LA_APPLY slot 반환 · commit counter
+----------------------+
```

**모듈별 책임**:
- **복제 로그 리더**: record를 transaction별 apply list로 모으며 **변경 class set**도 함께 수집. commit record를 만나면 작업 완성해 코디네이터에 제출(worker에 직접 안 넣음).
- **코디네이터**: 변경 class set으로 충돌 판단 → 실행/대기 구분 → schema/sysop/unknown은 barrier → 실행 가능한 것만 worker 큐에. 대기 작업의 재실행 시점 판단. worker 부하가 한쪽으로 몰리지 않게 분배.
- **worker**: 받은 transaction 작업만 적용·flush·commit·결과 반환. **충돌 판단 안 함.**
- **순서 정리**: worker 결과는 병렬 도착하나 global progress(`committed_lsa`)는 **commit LSA 순서로만** 전진.

## D.2 충돌 판단 방식 (1차안: class-level) & 대기 방식

**충돌 판단** — 1차 분배 기준은 **class 단위**. 리더가 apply list를 만들며 수집한 changed class set으로, commit 시점에 판단(코디네이터는 repl log 재분석 안 함; 받는 작업 = apply list + changed class set):
- 실행 중이거나 순서 정리 안 끝난 transaction과 **같은 class를 변경하면 충돌** → 바로 worker에 안 보내고 **pending**. 선행 transaction 정리 후 재평가.
- **변경 class가 겹치지 않으면 병렬** 실행 가능 → 적절한 worker 큐 선택.
- schema 변경·sysop·변경 class 불명 → **barrier**(앞 작업 정리 후 단독 실행, 뒤 작업은 그 다음).

예)
```text
Tx1 changed={A}, Tx2={B}, Tx3={A}
  Tx1·Tx2 → 다른 class → 병렬
  Tx3 → Tx1과 같은 class(A) → 충돌 → Tx1 완료·정리 후 실행
```
**단 class 단위라 실제로 다른 row여도 같은 class면 충돌로 본다(보수적)**:
```text
Tx4: class A의 row 1 update / Tx5: class A의 row 999 update
  → 실제론 독립이지만 1차안에선 둘 다 A라 충돌 판정(직렬)
```
→ 장점: repl log 포맷 무변경·applylogdb 내부 구현·correctness 단순. 단점: row/write-set보다 병렬성↓, hot class 집중 시 거의 순차. (→ 후속 row/key 정밀화, D.5)

**대기 방식** — 두 방식:
1. **전역 pending queue**(기본): 충돌하면 pending에 보관, 선행 정리 후 재평가해 worker 배정. 재평가 로직 필요하나 일반적.
2. **충돌 domain owner worker queue에 직접 enqueue**: 같은 class를 같은 worker 큐 뒤에 붙여 순서를 큐로 보장. 단순하나 hot class skew, 다중 class transaction에서 어느 큐에 붙일지 애매(`Tx4→{Tbl1,Tbl2}`).
→ 컨셉 단계 기본은 **전역 pending queue**(다중 class·schema·sysop까지 일반적). 단일 class는 owner queue 직렬화를 최적화 후보로.

## D.3 Phase 1 / Phase 2

- **Phase 1 (applier, repl 로그 무변경)**: same-class 직렬 + FK/순서 의존은 commit 순서 보존 + 독립 병렬. applier가 class 단위 보수 판단(class 식별 = `db_find_class→ws_oid`로 OID 확정). 빠르게 코디네이터 구조·correctness·병렬 효과 검증 가능.
- **Phase 2 (cub_server / repl log 확장)**: FK 관련 등 cross-class 병렬화를 **FK를 아는 server가 그룹 처리**하거나, repl log에 의존성 정보(D.5)를 실어 정밀(row/key) 병렬. **이는 repl 로그 구조 변경이라 작업분량·기간 예측이 어려워 Phase 2로 분리**한다.

## D.4 설계 방향을 정한 근거 (발견·에러 시나리오 driven)

- **applier는 FK를 모른다** [C2]: 복제 로그 항목(`la_make_repl_item`)은 class+PK+op만 담고, `log_applier.c`에 FK·constraint 코드가 전무. FK 관계는 server 스키마(`SM_CLASS`)에만 있다. → applier는 두 transaction이 FK로 엮였는지 **자기 입력(복제 로그)만으로는 판단할 수 없다.**
- **FK/제약은 server가 검사**(A.2): 자식을 부모보다 먼저 적용하면 **apply 에러 → 복제 중단.** FK 검사는 자식 INSERT 시점이라 "commit만 순서대로(SPCO)"로도 부족 — 자식 적용 순간 부모가 **이미 커밋되어 보여야** 한다.
- → 결론: applier가 FK를 못 가리므로 **보수적으로 commit 순서를 보존**(또는 별도 스키마 FK 메타 로드)해야 안전. 이 발견이 "충돌·순서를 applier가 책임"이라는 설계 방향을 확정했다.

## D.5 (장기) 정밀 병렬용 repl log 메타데이터

MySQL은 source가 write set으로 `last_committed`를 *계산*해 binlog엔 `sequence`+`last_committed`만 남긴다(write set 자체는 안 실음) [M3][M5]. CUBRID가 정밀 병렬을 목표하면 repl log에 추가할 정보:

| 항목 | 무엇 | 전송/역할 |
|---|---|---|
| **transaction sequence** (공통) | 논리 순번 | 전송 — 정체성·순서 (MySQL `sequence_number`) |
| **dependency watermark** (택1-A) | 실행 가능 경계 | 전송 — source가 미리 계산한 **결과**(MySQL `last_committed`) |
| **conflict key** (택1-B) | 바꾼 행/키 집합 | 전송 — **원재료**, applier가 충돌 직접 계산 (PGD/apply측) |
| **barrier 여부** (공통) | 직렬화 플래그(DDL 등) | 전송 — 단독 실행 |

> `watermark`(결과)와 `conflict key`(원재료)는 **택1**(둘 다 싣는 게 아님). write set은 A의 source 내부 계산 입력이라 전송 안 함. CUBRID 코디네이터가 apply 측 판단이라 **B(conflict key)가 더 자연스러운 확장**.

---

# Act E. 정확성 시나리오 (발표 [13]~[14])

> 검증 기준 2가지: ① 모든 시나리오 **correctness**(올바른가) ② **병렬성** 최대 지원.

## E.1 commit 순서 강제 필요 — FK 시나리오

server가 FK를 검사(A.2)하므로, 비순차 병렬은 복제를 깬다.

```text
master (실제 commit 순서, FK 만족):
  T1 commit  INSERT orders(id=100)            ← 부모
  T2 commit  INSERT order_items(order_id=100) ← 자식, FK → orders(100)

slave (class-level 병렬, 순서 미보존):
  코디네이터: T1{orders}, T2{order_items} → 다른 class → "독립" 오판 → 병렬
  worker B(T2 자식)가 worker A(T1 부모)보다 먼저 commit
    → orders(100) 아직 없음 → server FK 검사 실패 → ❌ 복제 중단
고치면(순서 보존): 부모 커밋 → 자식 적용 → FK 통과 ✔
```

→ **FK로 엮인 트랜잭션은 "부모 먼저 커밋" 순서 보존 필수.** applier가 FK를 못 가리므로(D.4) 보수적 순서 보존. (상속 계층 공유 unique 인덱스도 같은 가족 — E.3)

## E.2 시나리오 매트릭스 + 병렬화 효과

| 시나리오 | ① correctness | ② 병렬성 |
|---|---|---|
| 같은 class·같은 행(lost update, unique/PK 재사용) | ✅ same-class 직렬 → 순서 보존 | 직렬(불가피) |
| 같은 class·다른 행 | ✅ 보수적 직렬(안전) | ❌ 손해 → row/key 개선여지 |
| 다른 class·독립 | ✅ | ✅ **최대 병렬** |
| 다른 class·**FK** | ✅ Phase1 commit 순서 보존 | Phase1 제한 → **Phase2 server 그룹핑** |
| **상속** 공유 unique | ✅ FK와 동일(빈도 낮음) | FK와 동일 |
| **파티션** | ✅ 파티션키 ∈ 인덱스키 규칙 | ✅ 파티션별 병렬 |
| **재시작/복구** | Act F 참조 | — |
| **롱 트랜잭션** | ✅ 멱등 전제·복구비용 수용 | 단일tx = 1 worker |

**병렬화 효과(class 분산도에 좌우)**:
```text
Best (서로 다른 class 연속):  Tx1:A Tx2:B Tx3:C Tx4:D
  worker0:[A] worker1:[B] worker2:[C] worker3:[D]   → 풀 가동

Worst (hot class 집중):       Tx1:A Tx2:A Tx3:A Tx4:A
  worker0:[A][A][A][A] worker1~3: idle               → 사실상 순차

중간 (class group):           A:Tx1,Tx3 / B:Tx2,Tx5 / C:Tx4 / D:Tx6
  worker0:[A][A] worker1:[B][B] worker2:[C] worker3:[D]  → group 병렬, group 내 순서
```

## E.3 기타 시나리오 / 확인 항목

판단 기준: **"applier가 자기 입력(복제 로그)만으로 식별 가능한가."** (상세 `cubrid_special_table_scenarios.md` [C2])

**applier가 식별 가능 → 이미 처리**
- **Unique/PK 키 재사용(same-class)**: `DELETE pk=5` 후 `INSERT pk=5` 등. server가 unique 인덱스 유지(`locator_add_or_remove_index`)라 비순차면 중복키 에러 나지만, **같은 class라 class OID로 same-class 직렬화로 처리**(lost update + unique 에러 둘 다 방지).
- **트리거**: applier가 `db_disable_trigger`(`:1831`)로 끔 → 재실행 없음(해당 없음).

**applier가 식별 불가 → 별도 대응 (Phase1 commit 순서 / Phase2 그룹핑)**
- **FK**(E.1), **상속**: subclass가 superclass의 unique를 inherit하면 **같은 BTID(인덱스) 공유**(`schema_manager.c:9488-9506`) → 다른 subclass에 같은 키 비순차 적용 시 위반. FK와 동일 가족(실무 빈도 낮음).

**스키마 규칙으로 안전 / 비복제**
- **파티션**: CUBRID는 "파티션 키 ∈ 모든 인덱스 키"(msg 1169) → 같은 unique 값은 단 한 파티션에만 → **cross-partition 충돌 불가.** FK+파티션은 CUBRID가 제약(msg 997/1096).
- **뷰**: 비복제(기반 테이블이 로깅). **LOB**: 행엔 ELO locator만, 데이터는 외부 저장(ES) → **트랜잭션 로그로 비복제**(`lob_path` credential로 해석), 코디네이터 무관. **non-MVCC/reusable-OID**: applier가 `is_mvcc_class`로 분기 처리(주로 카탈로그).

→ **결론: applier가 못 막는 cross-class 위험은 FK + 상속**(둘 다 Phase 1 commit 순서가 커버).

---

# Act F. 재시작 문제 (발표 [15]~[16])

## F.1 재시작 멱등성(기존 skip) + 병렬 부작용

applylogdb는 논리 재실행이라 재시작 시 `required_lsa`(LWM)부터 **재적용**한다. 이미 적용된 것 중복을 막는 **2단계 멱등 skip**이 코드에 있다(baseline = 기동 시 `last_committed_lsa`, `:4666`) [C2]:
- ① 트랜잭션: `commit_lsa ≤ last_committed_lsa`면 통째 skip(`:8754`).
- ② 항목: `item.lsa > last_committed_rep_lsa`인 것만 적용(`:8775`).
- **develop = PoC 동일**(develop `la_apply_commit_list:5765/5797`). 이는 물리 redo의 **page-LSN 멱등성**(`pageLSN ≥ recLSN이면 skip`, ARIES)을 **복제 진도 LSA로 구현**한 것 = idempotent re-apply.

> **⚠ 병렬화 때문에 생기는 문제 ★** — 재시작 시 **재적용 자체는 병렬일 필요 없다(직렬로 충분)**. 문제는 그 전에 **병렬 운영이 남긴 out-of-order durable commit**이다: worker가 commit 순서보다 앞서 durable commit한 transaction은 `commit_lsa > committed_lsa`(watermark)라, `required_lsa`부터 (직렬로) 재적용할 때 기존 skip(`commit_lsa ≤ watermark`)에 **안 걸려 재적용 = 중복**된다. **직렬 운영이면 watermark가 곧 durable frontier라 안 생기는, 오직 병렬화 때문에 생기는 문제.** (poc_design.md §34가 PoC에서 제외한 '정교한 오류 복구' 영역 = 미해결)

## F.2 재시작 문제 해결 — 변경 필요한 부분

재적용은 직렬로 두되, **skip 판정이 out-of-order durable commit을 정확히 반영**하게 해야 한다 → 선택지:
- ① watermark 위에 **이미 적용된 transaction을 추가 추적**(applied set 영속),
- ② out-of-order commit **윈도우 bound**(watermark에서 N 이내만 앞서 commit 허용),
- ③ worker commit 순서 강제(병렬 이득↓).

→ 정식 구현에서 결정.

---

## 남은 설계 쟁점

- class 식별자 = **class OID로 확정**(이름 rename/재사용 위험 회피, applier가 `ws_oid()`로 보유).
- 순서 대기 해제 기준 = **1차는 순서 정리 완료**가 안전(병렬↓, correctness 단순).
- pending 작업 과다 시 리더 멈춤 정책, barrier 범위, row/write-set 확장 시 class 정책 공존.
- **[F.2] 재시작 정합 보강**(병렬 부작용) — 정식 구현 필수.

## 요약

코디네이터는 `tranid % worker_count`를 대체하는 단순 picker가 아니라, **충돌·순서 보존을 판단해 실행 가능한 transaction만 분배하는 계층**(= LogReader enqueue 강화)이다. 1차 방향: 리더가 변경 class set 수집 → 코디네이터가 class set으로 충돌 판단(같은 class 직렬 / 다른 class 병렬 / schema·sysop·unknown barrier) → worker는 받은 것만 적용 → 순서 정리가 commit LSA 순서로 progress 갱신. 안정화 후 row/write-set(Phase 2) 검토. 재시작 정합은 병렬 부작용이라 별도 보강(F.2).

## 참고문헌

문서 내 코드 `file:line`은 CUBRID 로컬 소스([C2]) 기준이며, 벤더 사실의 1차 출처는 아래와 같다. 더 풍부한 인용은 `reference/{base,mysql,pgsql}/` 각 문서의 References 절 참고.

### CUBRID
- [C1] CUBRID HA — CUBRID 11.0 Manual. https://www.cubrid.org/manual/en/11.0/ha.html
- [C2] CUBRID 로컬 소스(`feature/parallel_applylogdb_poc` / `develop`): `src/transaction/log_applier.c`, `locator_sr.c`, `replication.c`, `src/object/schema_manager.c`, `work_space.c/h`; 설계 `2.design/poc_design.md`; 결과 `final_report.md`, 특수테이블 `cubrid_special_table_scenarios.md`

### 물리 vs 논리 (base)
- [B1] PostgreSQL Docs — Different Replication Solutions. https://www.postgresql.org/docs/current/different-replication-solutions.html
- [B3] MySQL 8.0 Manual — The Binary Log / InnoDB Redo Log. https://dev.mysql.com/doc/refman/8.0/en/binary-log.html , https://dev.mysql.com/doc/refman/8.0/en/innodb-redo-log.html
- [B4] dbplus — Logical vs Physical Replication. https://dbplus.tech/en/2024/07/18/the-replication-dichotomy-logical-vs-physical-replication/
- [P-rec] PostgreSQL Wiki — Parallel Recovery (제안 단계). https://wiki.postgresql.org/wiki/Parallel_Recovery

### MySQL
- [M1] MySQL 8.0 Manual — Replication Implementation / Replication Threads. https://dev.mysql.com/doc/refman/8.0/en/replication-implementation.html , https://dev.mysql.com/doc/refman/8.0/en/replication-threads.html
- [M2] MySQL 8.0 Manual — Replica Server Options and Variables(`replica_parallel_type`, `replica_parallel_workers`, `replica_preserve_commit_order`). https://dev.mysql.com/doc/refman/8.0/en/replication-options-replica.html
- [M3] MySQL 8.0 Manual — Binary Logging Options(`binlog_transaction_dependency_tracking`). https://dev.mysql.com/doc/refman/8.0/en/replication-options-binary-log.html
- [M4] MySQL WorkLog — WL#6813(MTS ordered commits/SPCO), WL#9556(writeset). https://dev.mysql.com/worklog/task/?id=6813 , https://dev.mysql.com/worklog/task/?id=9556
- [M5] MySQL Blog — Improving the Parallel Applier with Writeset-based Dependency Tracking. https://dev.mysql.com/blog-archive/improving-the-parallel-applier-with-writeset-based-dependency-tracking/
- [M6] MySQL 8.0 Manual — Replication and Transaction Inconsistencies(gap). https://dev.mysql.com/doc/refman/8.0/en/replication-features-transaction-inconsistencies.html
- (초기 구축) Clone Plugin / GTID auto-positioning. https://dev.mysql.com/doc/refman/8.0/en/clone-plugin.html , https://dev.mysql.com/doc/refman/8.0/en/replication-gtids-auto-positioning.html

### PostgreSQL
- [P1] PostgreSQL Docs — Logical Replication Architecture. https://www.postgresql.org/docs/current/logical-replication-architecture.html
- [P2] PostgreSQL Docs — Logical Replication Configuration Settings(`max_parallel_apply_workers_per_subscription`, `max_sync_workers_per_subscription`). https://www.postgresql.org/docs/current/logical-replication-config.html
- [P3] PostgreSQL Docs — CREATE SUBSCRIPTION(`streaming`). https://www.postgresql.org/docs/current/sql-createsubscription.html
- [P4] PostgreSQL Docs — Logical Streaming Replication Protocol. https://www.postgresql.org/docs/current/protocol-logical-replication.html
- [P5] Amit Kapila — Parallel Apply of Large Transactions(PG16 도입, PG18 기본). http://amitkapila16.blogspot.com/2025/09/parallel-apply-of-large-transactions.html
- [P6] PostgreSQL Docs — Logical Replication Conflicts / Restrictions. https://www.postgresql.org/docs/current/logical-replication-conflicts.html , https://www.postgresql.org/docs/current/logical-replication-restrictions.html

### EDB PGD
- [E1] EDB PGD — Parallel Apply. https://www.enterprisedb.com/docs/pgd/latest/reference/parallelapply/
- [E2] EDB PGD — Transaction streaming. https://www.enterprisedb.com/docs/pgd/latest/reference/transaction-streaming/
- [E3] EDB PGD — Known issues and limitations. https://www.enterprisedb.com/docs/pgd/latest/known_issues/
