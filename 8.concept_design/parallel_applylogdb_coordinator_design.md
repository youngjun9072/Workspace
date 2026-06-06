# 병렬 applylogdb 코디네이터 컨셉

이 문서는 parallel `applylogdb` PoC 이후 실제 구현으로 넘어가기 위한 병렬화
컨셉을 정리한다. 상세 자료구조나 API 설계가 아니라, 어떤 책임을 새 모듈로
분리할지와 transaction 간 충돌/순서를 어떻게 다룰지를 잡는 문서다.

본문은 발표 스토리 순서(Act A~F = 발표 요약 [1]~[16])로 구성한다.

## 발표용 요약 (1차 발표)

> 이 절은 **1차 발표용 스토리 정리**(학습 + PT 기반)다. 흐름: **CUBRID 현재(로지컬) → PoC로 병렬 가능성 확인 → "다른 DB는 어떻게?"(병렬화는 로지컬만) → 벤더 조사(PG·PGD 탈락, MySQL 채택) → 코디네이터 설계(Phase1/2) → 정확성 시나리오 → 재시작 문제**.
> 상세는 본문 Act A~F + `2.design/poc_design.md` + `reference/` + `final_report.md`. 용어는 등장 시 즉석 정리. 슬라이드 = 아래 [1]~[16] 각 1~2장.

**[1] 기존 CUBRID 복제 동작** — master가 트랜잭션 로그 기록 → **copylogdb**가 slave로 복사 → **applylogdb**가 읽어 slave DB에 적용. 현재는 단순(트랜잭션 id 기반, 거의 직렬). → Act A.1

**[2] 그게 "로지컬 복제"다** — applylogdb는 로그를 **행 단위로 다시 실행**(INSERT/UPDATE…) → **논리(logical) 복제**(물리 페이지 복사 아님 → slave LSA ≠ master LSA). → Act A.2

**[3] 피지컬 vs 로지컬 — 병렬화는 로지컬만** — 물리는 단일 스레드·경직(LSN·페이지 종속)이라 **다른 DB들도 병렬화는 논리 복제에서만** 한다. CUBRID도 논리 → **병렬화가 의미 있다.** → Act A.3

**[4] PoC 설계 & develop 비교** — PoC 구조(`poc_design.md`): **LogReader**(읽기·enqueue·결과수집·`committed_lsa`) + **ApplyWorker×N**(병렬 apply). develop은 단일 직렬. **설계 §32·34는 dependency 판별·스케줄링·정교한 오류복구를 PoC에서 의도적 제외**(`tranid%worker`). → Act B.1

**[5] PoC 결과 → "병렬화 가능성이 보인다"** — slave 반영 **약 3.4×↓·lag 4–6×↓**(워커당 시간↑, 병목 = slave on-CPU apply). → 병렬화는 효과 있다. 단 PoC는 dependency를 안 봄 → *"제대로 된 병렬화(충돌·순서)는 어떻게?"* → Act B.2

**[6] 그럼 다른 DB는 병렬화를 어떻게?** — 정식(의존성 기반) 병렬화를 위해 타 벤더 조사. → Act C

**[7] (리마인드) 병렬화는 로지컬에서만** — 조사 대상도 전부 논리 복제의 병렬 적용.

**[8] PostgreSQL — 탈락** — 단일 구독 내 트랜잭션 **직렬 적용**, 자동 의존성 병렬 없음. → 직접 모델 부적합(반면교사). → Act C.1

**[9] EDB PGD — 탈락 (한 측면 선례)** — apply 측 writer가 행 충돌을 **선행 tuple-wait 예방 + 위반 시 롤백 backstop**. 탈락: ① 멀티마스터(CUBRID는 master-slave) ② 상용 폐쇄 ③ 구조 부적합. 단 "apply 측 충돌 판단"은 선례. → Act C.2

**[10] MySQL — 가장 유사 (채택)** — source가 의존성(`sequence`/`last_committed`=watermark) 계산 → replica coordinator가 **병렬 실행** + **SPCO로 commit 순서 보존**. "병렬 실행 ↔ 순서 보존" 분리 + coordinator가 CUBRID 구조와 **1:1**. → Act C.3

**[11] 병렬화 설계 — 코디네이터, Phase 1/2** — **코디네이터 = LogReader의 enqueue 결정**(현 `tranid%worker` → 충돌(class)·순서 판단으로 대체). Phase 1(repl 로그 무변경, class 단위 보수 판단). Phase 2(정밀 row/key — **repl 로그 구조 변경 필요, 작업분량·기간 예측 어려워 분리**). → Act D

**[12] 설계 방향을 정한 근거** — **applier는 FK를 모른다**(복제 로그=class+PK), **FK/제약은 server가 검사** → 잘못 병렬화하면 복제 중단. → "충돌·순서를 applier가 보수적으로 책임". → Act D.4

**[13] commit 순서 강제 필요 — FK 시나리오**
```text
master:  T1 commit INSERT orders(100)  →  T2 commit INSERT order_items(100, FK→orders)
slave 비순차 병렬: T2(자식)가 T1(부모)보다 먼저 → server FK 검사 실패 → 복제 중단
```
→ 부모 커밋 후 자식 적용(commit 순서 보존) 필요. → Act E.1

**[14] 기타 충돌/순서 시나리오 + 이 설계의 동작** — 같은 class(직렬)·독립(병렬)·FK/상속(순서 보존)·파티션(안전). → Act E.2/E.3

**[15] 재시작 문제 — "병렬화 때문에" 생기는 정합 문제 ★** — 재적용 자체는 직렬로 충분. 문제는 **병렬 운영이 남긴 out-of-order durable commit**: `commit_lsa > committed_lsa`(watermark)라 기존 멱등 skip을 빠져나가 **중복 재적용** 위험. → Act F.1

**[16] 재시작 문제 해결 — 변경 필요한 부분** — ① applied set 추가 추적 / ② out-of-order commit 윈도우 bound / ③ worker commit 순서 강제 중 택. → Act F.2

### 부록. 예상 질문
- "왜 commit 순서?" → FK/상속을 applier가 못 가려서; server가 FK 검사라 비순차면 에러.
- "재시작 중복?" → 직렬에선 멱등 skip(`commit_lsa ≤ watermark`)으로 해결, **병렬에선 보강 필요([15][16])**.
- "파티션·LOB?" → 파티션 스키마 규칙으로 안전, LOB 데이터는 비복제(외부 저장).
- "왜 Phase 2를 나눴나?" → Phase 2는 **repl 로그 포맷 변경**이라 작업분량·기간 예측이 어려움.
- "그럼 PGD 쓰지?" → 멀티마스터·상용 폐쇄·구조 부적합. apply 측 판단 한 측면만 참고.

---

# Act A. CUBRID 복제 현황 & 로지컬 복제 (발표 [1]~[3])

## A.1 현재 HA 복제 흐름 & 용어

```text
master                         slave
  트랜잭션 로그 기록    ──►   copylogdb (master 로그를 slave로 복사)
                                  │
                                  ▼
                              applylogdb (복사된 로그를 읽어 slave DB에 적용)  ← 이 문서의 개선 대상
                                  │
                                  ▼
                              slave DB
```

용어(이 문서에서 쓰는 핵심):
- **복제(replication)**: master(원본) 변경을 slave(복제본)가 따라 적용해 같은 상태 유지. master/slave = source/replica(MySQL) = publisher/subscriber(PostgreSQL).
- **복제 로그(repl log)**: master가 "무엇이 바뀌었나"를 기록. slave가 읽어 재현.
- **LSA (Log Sequence Address)**: 로그 안 위치(번호표). "어디까지 처리했나". (MySQL binlog position·PG LSN 대응)
- **class**: CUBRID에서 **테이블**. (예시 `TblA` = class A)
- **copylogdb / applylogdb**: copylogdb=master 로그를 slave로 복사 / applylogdb=읽어 적용(개선 대상).
- **코디네이터(coordinator)**: worker 앞단에서 "어떤 transaction을 지금 보내도 되나(충돌·순서)"를 판단해 분배하는 계층(새로 도입).
- **committed_lsa / 순서 정리**: "어디까지 (순서대로) 반영 완료했나" 진도. 순서 정리 = 병렬 결과를 commit 순서대로 줄 세워 committed_lsa 전진.
- **barrier**: 병렬화하지 않고 직렬로 끊는 경계(DDL 등).

> 비유: 복제 로그 = master의 "작업 지시서", 코디네이터 = "동시에 시켜도 되는 일 / 순서 지킬 일"을 나눠 일꾼(worker)에 배분하는 반장.

## A.2 로지컬 복제 = 행 재실행 (코드 확인)

applylogdb worker는 slave에 DB client session으로 붙어 복제 로그를 `la_apply_insert_log` / `la_apply_update_log` / `la_apply_delete_log` / `la_apply_statement_log`로 **다시 실행**한다(`log_applier.c:897-902`, worker client session `:1720~`). 즉 물리 페이지 redo가 아니라 행/문장 단위 재적용 → **slave LSA ≠ master LSA**.

**적용·가시성 동작 (정확성 판단의 전제, 코드 확인):**
- **적용 경로**: `la_apply_*_log` → `la_repl_add_object`(WS_REPL_OBJ 리스트 적재) → `locator_repl_flush_all` 벌크 flush(`:7589, :7470, :8234`). 질의 실행기가 아니라 locator 복제 경로로 레코드 이미지를 직접 반영.
- **복제는 PK 기반** — 복제 로그 = `class + PK 값 + operation`(`la_make_repl_item:5708~`). → 복제 테이블 **PK 필수**, class는 OID(`db_find_class→ws_oid`)로 식별. 충돌 키로 PK·class를 항상 쓸 수 있음.
- **계층 구분 (중요)**: `la_apply_*`는 **applier(client)** 로 변경을 모아 server에 보낼 뿐, FK 검사는 **slave server**의 `locator_insert_force`/`update_force` 안에서 일어난다.
- **server는 repl 적용에도 FK를 검사한다** — `xlocator_repl_force` → `locator_insert_force(..., dont_check_fk=false)`(`locator_sr.c:7029,7256`) → `if (has_index && !skip_checking_fk) locator_check_foreign_key()`(`:5198-5201`), 전역 `locator_Dont_check_foreign_key=false`(`:116`). → **자식을 부모보다 먼저 적용하면 FK 위반 → apply 에러 → 복제 중단.** (단 applier는 FK를 모름 — Act D.4)
- **실패 처리**: ① master abort면 그 트랜잭션 repl 리스트를 비움(`LOG_ABORT → la_free_repl_items_by_tranid`, `:6014, 8744`). ② apply 에러면 재시도 가능 에러는 재시도(`la_retry_on_error`→`LA_SLEEP`+continue, `:8841-8849`), 그 외 실패는 `fail_counter`++(`:7703, 2093`). 트리거는 `db_disable_trigger`로 끔(`:1831`) → 재실행 없음.
- (참고) `committed_lsa`는 읽기 가시성(MVCC)에 안 쓰임(`src/query`·`mvcc.c`·`src/storage`에 없음). 슬레이브 읽기 일관성은 본 설계 범위 밖(사용자 결정).

## A.3 피지컬 vs 로지컬 — 병렬화는 로지컬만

| | 물리(physical) | 논리(logical) |
|---|---|---|
| 무엇을 보내나 | 로그(WAL/페이지)를 **그대로 복사·재생** | 변경을 **행 단위로 재실행** |
| 비용/속도 | 레코드당 쌈, 단 **단일 스레드 재생** | 레코드당 비쌈(파싱·인덱스·제약) |
| 유연성 | 낮음(통째·동일버전·읽기전용) | 높음(선택·버전간·이기종·쓰기) |
| 병렬화 | 어려움(LSN·페이지 종속) | **상대적으로 쉬움**(트랜잭션/행 단위) |

→ 물리가 "레코드당 싸다"고 항상 빠른 건 아니다 — 단일 스레드라 멀티코어 부하를 못 따라가고 경직됨. 그래서 유연한 논리를 택하고 속도는 **병렬로 메운다.** **다른 DB들도 병렬화는 논리 복제에서만** 제공한다(상세 `reference/base/physical_vs_logical_replication.md`). CUBRID applylogdb도 논리 → **병렬화가 의미 있다 = 이 프로젝트.**

## A.4 현 PoC 병렬화와 한계

현 PoC는 commit record를 만나면 `worker_idx = tranid % LA_APPLY_WORKER_COUNT`로 worker를 고른다. 단순하지만:
- ❌ 서로 관련 있는(같은 데이터) transaction도 동시 실행될 수 있다 ← **가장 큰 문제**
- ❌ 독립 transaction도 특정 worker에 쏠릴 수 있다

→ 단순 worker picker가 아니라 **충돌·순서를 판단하는 코디네이터**가 필요하다(Act D).

---

# Act B. PoC 설계·구현·결과 (발표 [4]~[5])

## B.1 PoC 모듈 구조 + develop 비교 + 설계↔코드 delta

**PoC 구조 (`2.design/poc_design.md` 참조)** — 2모듈:
- **LogReader**: 로그 읽기 → LA_ITEM/LA_APPLY 구성 → commit 시 worker 큐에 **enqueue** → 결과 수집·commit LSA 순서로 `committed_lsa` 갱신·`_db_ha_apply_info`·reclaim.
- **ApplyWorker × N**: 개별 큐/세션/workspace, 병렬 apply·flush·commit, completed lsa 보고.

본 설계의 "코디네이터/순서 정리"는 새 모듈이 아니라 **LogReader 책임을 기능 분해**한 것:

| 본 문서 개념 | poc_design.md 위치 |
|---|---|
| 복제 로그 리더 | LogReader의 read/build |
| **코디네이터(충돌/순서 판단)** | LogReader의 **enqueue 결정** — 현 `tranid%worker`를 충돌·순서 판단으로 **대체** |
| worker | `ApplyWorker × N` — **그대로** |
| **순서 정리** | LogReader의 **결과 수집 + committed_lsa 갱신** |

**develop vs PoC** — PoC는 develop 대비 `log_applier.c`에 약 **+3,900줄**(worker/dispatch/retire + 계측). **핵심 정합성 메커니즘(LSA·멱등 skip·FK·repl 로그)은 develop과 동일**, 더한 건 병렬 골격 + 측정 계측.

**설계(poc_design.md) ↔ 구현 코드 delta**:
- **[코드 > 설계] UPDATE 적용** — 설계 §29는 "insert만"이나 코드는 **INSERT + UPDATE** 지원(`la_is_supported_poc_item`; statement는 INSERT/UPDATE/CREATE·DROP CLASS). **DELETE는 함수만 있고 미지원.** (최종 보고서 측정도 Insert+Update)
- **[코드 > 설계] 측정 계측** — `la_Debug_progress`·`la_debug_note_*`.
- **[코드 > 설계] 측정용 제약 가드** — `LA_APPLY_WORKER_REPL_ACTIVE_COUNT`(일부 worker만 flush), `LA_SKIP_READER_COMMIT_APPLY_INFO` → **병목 측정 스캐폴딩, 정식 구현에선 제거 대상.**
- **[설계가 의도적 제외 = 코드에도 없음]** §32·34: *"dependency 판별·병렬 스케줄링·정교한 오류 복구는 PoC 제외"* → 코드도 `tranid%worker`. **→ 코디네이터(충돌/순서 판단)는 PoC가 의도적으로 비워둔 자리를 채우는 다음 단계.**

## B.2 PoC 결과 → "병렬화 가능성이 보인다"

(상세 `final_report.md`) 병렬화로 slave 반영 **약 3.4×↓, lag 4–6×↓**. 단 워커당(단일 테이블) 시간은 1.5–2×↑이고, 병목은 네트워크가 아니라 **slave on-CPU apply 로직**(로그 생성 prior_lsa·lock·page/space 할당). → **병렬화는 효과 있다**는 결론. 단 PoC는 dependency를 안 보므로 정식 병렬화(충돌·순서)는 별도 설계 필요.

## B.3 LSA / 진도 관리 (현재 상태 코드)

applylogdb가 쓰는 LSA(`log_applier.c:465-510`, 구조체 `:282-344`):

**A. 마스터 로그 위치 (랙)**: `append_lsa`(마스터가 쓴 끝)·`eof_lsa`(`:500-501`). `append_lsa − committed_lsa` ≈ lag.
**B. applier 진행 — 핵심 4 (영속)**:

| LSA | 의미 | 갱신 |
|---|---|---|
| `final_lsa` | 마지막으로 읽어 처리한 위치(읽기 커서) | 읽기 루프(`:11478`), 재시작 시 `required_lsa`로 초기화 |
| `required_lsa` | **적용할 첫 트랜잭션 start = 복구 재시작점(LWM)** | `la_find_required_lsa`=진행 중 최저 `start_lsa`, 없으면 `final_lsa`(`:4078-4105`) |
| `committed_lsa` | 마지막으로 반영 완료한 **commit 로그** 위치 | retire에서 `result->commit_lsa`로 전진(`:2082`) |
| `committed_rep_lsa` | 마지막으로 반영 완료한 **데이터 변경 로그** 위치 | retire(`:2085`) |

**C. 재시작 baseline**: `last_committed_lsa`/`last_committed_rep_lsa` = 기동 시점 committed 스냅샷(`:468-469`).
**D. 항목 단위**: `LA_ITEM.lsa`(복제 지시 위치) ≠ `target_lsa`(적용할 레코드 이미지 위치, `la_get_recdes:7904`).

- **영속**: `_db_ha_apply_info`에 6개(`final/committed/committed_rep/append/eof/required_lsa`) 기록(`la_log_commit:9734`), 재시작 시 `la_get_last_ha_applied_info`로 로드.
- 진도선: **`required_lsa`(LWM) ≤ `committed_lsa` ≤ `final_lsa` ≤ `append_lsa`**.

---

# Act C. 다른 DBMS는 병렬화를 어떻게 하나 (발표 [6]~[10])

> (리마인드) 병렬화는 **논리 복제에서만**. 조사 대상도 전부 논리 복제의 병렬 적용. 벤더↔CUBRID 매핑 상세는 `coordinator_design_mapping_from_vendors.md`, 각 벤더 상세는 `reference/{mysql,pgsql}/`.

## C.1 PostgreSQL — 탈락

publication/subscription 모델. **단일 구독 내 일반 transaction을 직렬 적용**하고, MySQL처럼 의존성 metadata로 독립 transaction을 병렬 dispatch하지 않는다 [6][8]. 병렬은 두 곳뿐:
- **초기 table synchronization**: 여러 table sync worker가 초기 data copy 병렬(`max_sync_workers_per_subscription`) [6][10].
- **large in-progress transaction streaming**: 큰 transaction을 commit 전 `Stream Start/Stop`으로 나눠 보내고 `streaming=parallel`이면 parallel apply worker가 보조(PG16+) [9][10][14]. 단 **한 transaction의 segment 처리**일 뿐, 여러 transaction 간 의존성 스케줄링이 아니다.

→ "자동 의존성 병렬 + 전역 순서 보존"의 직접 모델로 **부적합**. (cross-subscription 경계 깨짐은 "병렬 단위를 잘못 자르면 깨진다"는 반면교사) DDL 자동 복제 안 함, conflict 시 worker error로 복제 중단 [11][12].

## C.2 EDB PGD — 탈락 (한 측면만 선례)

상용 멀티마스터(구 BDR). apply 측 writer가 행 충돌을 **선행 tuple-wait로 예방 + commit 순서 위반 시 롤백 backstop**(순수 낙관적 아님). 상세 `reference/pgsql/edb_pgd_parallel_apply.md`.

**전체 모델로 채택하지 않은 이유**: ① 토폴로지 — PGD=멀티마스터, CUBRID=단방향 master-slave → 불필요·부적합 ② 상용 폐쇄(MySQL은 오픈·소스 검증) ③ 구조는 MySQL이 1:1. **단 "apply 측에서 충돌 판단"** 한 측면은 CUBRID(코디네이터가 slave 측 판단)와 닮아 선례.

## C.3 MySQL — 가장 유사 (채택)

MySQL replication: source가 binary log 기록 → replica I/O thread가 relay log로 받고 → SQL applier(병렬이면 coordinator+worker)가 적용 [1][2].

```text
source                                   replica
  binary log 기록(+ dependency metadata     I/O receiver thread → relay log
   = sequence_number, last_committed)  ─►   coordinator: relay log 순차 읽어
                                            의존성 보고 worker에 배정 → worker[0..N]
                                            → commit 순서 정리
```

- **병렬 판단 = 의존성 기준**. source가 `sequence_number`(논리 순번) + `last_committed`(기다려야 하는 선행 경계=watermark)를 binlog에 남기고, replica coordinator가 이를 읽어 병렬 가능 여부 판단(`replica_parallel_type=LOGICAL_CLOCK`, `replica_parallel_workers`) [3][4].
- **의존성 계산 모드**(`binlog_transaction_dependency_tracking`): `COMMIT_ORDER`(group commit 기반)/`WRITESET`(행 write-set 충돌로 정밀)/`WRITESET_SESSION`(+세션 순서 보존). **단 binlog엔 계산 결과(sequence/last_committed)만 실리고 write set 자체는 안 실림.**
- **병렬 실행 ↔ commit 순서 보존 분리**: worker는 병렬 적용, `replica_preserve_commit_order`(SPCO)가 최종 commit을 source 순서로 강제. DDL·FK·불완전 write set은 보수적 fallback [4][5]. (group commit은 필수 아니고 commit overlap을 늘려 병렬성을 돕는 보조 요소)

→ **"병렬 실행 ↔ 순서 보존" 분리 + coordinator 분배**가 CUBRID(코디네이터 ↔ 순서 정리/committed_lsa) 구조와 **1:1** → **MySQL 모델 차용.**

---

# Act D. CUBRID 병렬화 설계 — 코디네이터 (발표 [11]~[12])

## D.1 아키텍처 & 모듈

코디네이터는 복제 로그 리더와 worker 사이의 판단 계층(= LogReader의 enqueue 결정 강화). 현 PoC는 commit 시 `tranid % worker_count`로 바로 고르지만, 목표 구조는 그 자리에 충돌·순서 판단을 넣는다.

```text
+----------------------+
| 복제 로그 리더          |  복제 record 스캔 → transaction 구성(apply list + commit_lsa + 변경 class set)
+----------+-----------+
           v
+----------------------+
| 코디네이터              |  충돌/순서 판단 → 실행/대기 구분 → worker 선택
+-----+----------+-----+
      |          +------------------+
      v                             v
+----------------+        +------------------+
| 실행 → worker 큐 |        | 대기 → pending 유지 |
+--------+-------+        +------------------+
         v
+----------------------+
| worker pool[0..N]     |  복제 항목 적용 → flush → commit → 결과 반환
+----------+-----------+
           v
+----------------------+
| 순서 정리              |  committed_lsa 갱신 · apply info 갱신 · LA_APPLY slot 반환
+----------------------+
```

**모듈별 책임**:
- **복제 로그 리더**: record를 transaction별 apply list로 모으며 **변경 class set**도 함께 수집. commit record를 만나면 작업 완성해 코디네이터에 제출(worker에 직접 안 넣음).
- **코디네이터**: 변경 class set으로 충돌 판단 → 실행/대기 구분 → schema/sysop/unknown은 barrier → 실행 가능한 것만 worker 큐에. 대기 작업의 재실행 시점 판단.
- **worker**: 받은 작업만 적용·flush·commit·결과 반환. **충돌 판단 안 함.**
- **순서 정리**: worker 결과는 병렬 도착하나 global progress(`committed_lsa`)는 **commit LSA 순서로만** 전진. apply info 갱신·slot 반환·counter 누적.

> 코디네이터의 핵심 질문 순서: ① 이전과 충돌? ② 어디까지 대기? ③ 어느 worker? — ①②=correctness(우선), ③=성능.

## D.2 충돌 판단 방식 (1차안: class-level) & 대기 방식

**충돌 판단**: 1차 분배 기준은 **class 단위**. 리더가 apply list를 만들며 수집한 changed class set으로, commit 시점에 충돌 판단(코디네이터는 repl log 재분석 안 함).
- 실행 중이거나 순서 정리 안 끝난 transaction과 **같은 class를 변경하면 충돌** → pending.
- **변경 class가 겹치지 않으면 병렬** 실행.
- schema/sysop/변경 class 불명 → **barrier**.

예) `Tx1{A}`, `Tx2{B}` → 병렬 / `Tx3{A}`는 Tx1과 충돌 → Tx1 완료·정리 후 실행. **단 class 단위라 서로 다른 row여도(`Tx4: A row1`, `Tx5: A row999`) 같은 class면 충돌로 본다(보수적).** → repl log 무변경·correctness 단순이 장점, hot class 집중 시 병렬성↓이 단점(→ 후속 row/key, D.5).

**대기 방식**: 컨셉 단계 기본은 **전역 pending queue**(선행 정리 후 재평가). owner worker queue 직렬화(같은 class를 한 worker 큐에)는 단일 class엔 단순하나 다중 class·skew에 약해 최적화 후보로만 둔다.

## D.3 Phase 1 / Phase 2

- **Phase 1 (applier, repl 로그 무변경)**: same-class 직렬 + FK/순서 의존은 commit 순서 보존 + 독립 병렬. 빠르게 검증 가능. applier가 class 단위 보수 판단(`class OID = db_find_class→ws_oid`로 확정).
- **Phase 2 (cub_server)**: FK 관련 등 cross-class 병렬화는 **FK를 아는 server가 그룹 처리**. 또는 repl log에 의존성 정보(D.5) 추가로 정밀(row/key) 병렬. **이는 repl 로그 구조 변경이라 작업분량·기간 예측이 어려워 Phase 2로 분리.**

## D.4 설계 방향을 정한 근거 (발견·에러 시나리오 driven)

- **applier는 FK를 모른다** — 복제 로그 항목(`la_make_repl_item`)은 class+PK+op만 담고, applier에 FK 코드 전무. FK 관계는 server 스키마(`SM_CLASS`)에만. → applier는 두 transaction이 FK로 엮였는지 **자기 입력만으로 못 가린다.**
- **FK/제약은 server가 검사**(A.2). → 자식을 부모보다 먼저 적용하면 **apply 에러 → 복제 중단.** FK 검사는 자식 INSERT 시점이라 "commit만 순서대로(SPCO)"로도 부족 — 부모가 **이미 커밋되어 보여야** 함.
- → 결론: applier가 FK를 못 가리므로 **보수적으로 commit 순서를 보존**(또는 별도 스키마 FK 메타 로드)해야 안전. 이 발견이 "충돌·순서를 applier가 책임"이라는 설계 방향을 확정했다.

## D.5 (장기) 정밀 병렬용 repl log 메타데이터

MySQL은 source가 write set으로 `last_committed`를 *계산*해 binlog엔 `sequence`+`last_committed`만 남긴다(write set 자체는 안 실음). CUBRID가 정밀 병렬을 목표하면 repl log에 추가할 정보:

| 항목 | 무엇 | 전송/역할 |
|---|---|---|
| **transaction sequence** (공통) | 논리 순번 | 전송 — 정체성·순서 |
| **dependency watermark** (택1-A) | 실행 가능 경계 | 전송 — source가 미리 계산한 **결과**(MySQL `last_committed`) |
| **conflict key** (택1-B) | 바꾼 행/키 집합 | 전송 — **원재료**, applier가 충돌 직접 계산 (PGD/apply측) |
| **barrier 여부** (공통) | 직렬화 플래그(DDL 등) | 전송 — 단독 실행 |

> `watermark`(결과)와 `conflict key`(원재료)는 **택1**(둘 다 싣는 게 아님). CUBRID 코디네이터가 apply 측 판단이라 **B(conflict key)가 더 자연스러운 확장**. write set은 A의 source 내부 계산 입력이라 전송 안 함.

---

# Act E. 정확성 시나리오 (발표 [13]~[14])

> 검증 기준 2가지: ① 모든 시나리오 **correctness**(올바른가) ② **병렬성** 최대 지원.

## E.1 commit 순서 강제 필요 — FK 시나리오

server가 FK를 검사(A.2)하므로, 비순차 병렬은 복제를 깬다.

```text
master (실제 commit 순서):
  T1 commit  INSERT orders(id=100)            ← 부모
  T2 commit  INSERT order_items(order_id=100) ← 자식, FK → orders(100)

slave (class-level 병렬, 순서 미보존):
  코디네이터: T1{orders}, T2{order_items} → 다른 class → "독립" 오판 → 병렬
  worker B(T2 자식)가 worker A(T1 부모)보다 먼저 commit
    → orders(100) 아직 없음 → server FK 검사 실패 → ❌ 복제 중단
고치면(순서 보존): 부모 커밋 → 자식 적용 → FK 통과 ✔
```

→ **FK로 엮인 트랜잭션은 "부모 먼저 커밋" 순서 보존 필수.** applier가 FK를 못 가리므로(D.4) 보수적 순서 보존. (상속 계층 공유 unique 인덱스도 같은 가족 — Act E.3)

## E.2 시나리오 매트릭스 + 병렬화 효과

| 시나리오 | ① correctness | ② 병렬성 |
|---|---|---|
| 같은 class·같은 행(lost update, unique/PK 재사용) | ✅ same-class 직렬 | 직렬(불가피) |
| 같은 class·다른 행 | ✅ 보수적 직렬(안전) | ❌ 손해 → row/key 개선여지 |
| 다른 class·독립 | ✅ | ✅ **최대 병렬** |
| 다른 class·**FK** | ✅ Phase1 commit 순서 보존 | Phase1 제한 → **Phase2 server 그룹핑** |
| **상속** 공유 unique | ✅ FK와 동일(빈도 낮음) | FK와 동일 |
| **파티션** | ✅ 파티션키 ∈ 인덱스키 규칙 | ✅ 파티션별 병렬 |
| **재시작/복구** | Act F | — |
| **롱 트랜잭션** | ✅ 멱등 전제·복구비용 수용 | 단일tx = 1 worker |

**병렬화 효과(class 분산도에 좌우)**:
- Best — 서로 다른 class 연속(`Tx1:A, Tx2:B, Tx3:C, Tx4:D`) → worker 4개 풀 가동.
- Worst — hot class 집중(`Tx1~4: 모두 A`) → 사실상 순차(worker 1개만).
- 중간 — class group별(`A:Tx1,Tx3 / B:Tx2,Tx5 / C:Tx4 / D:Tx6`) → group은 병렬, group 내 순서 보존.

## E.3 기타 시나리오 / 확인 항목

판단 기준: **"applier가 자기 입력(복제 로그)만으로 식별 가능한가."**

**applier가 식별 가능 → 이미 처리**
- **Unique/PK 키 재사용(same-class)**: `DELETE pk=5` 후 `INSERT pk=5` 등. server가 unique 인덱스 유지(`locator_add_or_remove_index`)라 비순차면 중복키 에러 나지만, **같은 class라 class OID로 same-class 직렬화로 처리.**
- **트리거**: applier가 `db_disable_trigger`(`:1831`)로 끔 → 재실행 없음(해당 없음).

**applier가 식별 불가 → 별도 대응 (Phase1 commit 순서 / Phase2 그룹핑)**
- **FK** (E.1), **상속**: subclass가 superclass의 unique를 inherit하면 **같은 BTID(인덱스) 공유**(`schema_manager.c:9488-9506`) → 다른 subclass에 같은 키 비순차 적용 시 위반. FK와 동일 가족(실무 빈도 낮음).

**스키마 규칙으로 안전 / 비복제**
- **파티션**: CUBRID는 "파티션 키 ∈ 모든 인덱스 키"(msg 1169) → 같은 unique 값은 단 한 파티션에만 → **cross-partition 충돌 불가.** FK+파티션은 CUBRID가 제약.
- **뷰**: 비복제(기반 테이블이 로깅). **LOB**: 행엔 ELO locator만, 데이터는 외부 저장(ES) → **트랜잭션 로그로 비복제**(`lob_path` credential로 해석), 코디네이터 무관.

→ 상세 `cubrid_special_table_scenarios.md`. **결론: applier가 못 막는 cross-class 위험은 FK + 상속**(둘 다 Phase 1 commit 순서가 커버).

---

# Act F. 재시작 문제 (발표 [15]~[16])

## F.1 재시작 멱등성(기존 skip) + 병렬 부작용

applylogdb는 논리 재실행이라 재시작 시 `required_lsa`(LWM)부터 **재적용**한다. 이미 적용된 것 중복을 막는 **2단계 멱등 skip**이 코드에 있다(baseline = 기동 시 `last_committed_lsa`, `:4666`):
- ① 트랜잭션: `commit_lsa ≤ last_committed_lsa`면 통째 skip(`:8754`).
- ② 항목: `item.lsa > last_committed_rep_lsa`인 것만 적용(`:8775`).
- **develop = PoC 동일**(develop `la_apply_commit_list:5765/5797`). 이는 물리 redo의 page-LSN 멱등성을 **복제 진도 LSA로 구현**한 것(= idempotent re-apply).

> **⚠ 병렬화 때문에 생기는 문제 ★** — 재시작 시 **재적용 자체는 병렬일 필요 없다(직렬로 충분)**. 문제는 그 전에 **병렬 운영이 남긴 out-of-order durable commit**이다: worker가 commit 순서보다 앞서 durable commit한 transaction은 `commit_lsa > committed_lsa`(watermark)라, `required_lsa`부터 (직렬로) 재적용할 때 기존 skip(`commit_lsa ≤ watermark`)에 안 걸려 **재적용 = 중복**된다. **직렬 운영이면 watermark가 곧 durable frontier라 안 생기는, 오직 병렬화 때문에 생기는 문제.** (poc_design.md §34가 PoC에서 제외한 '정교한 오류 복구' 영역 = 미해결)

## F.2 재시작 문제 해결 — 변경 필요한 부분

재적용은 직렬로 두되, **skip 판정이 out-of-order durable commit을 정확히 반영**하게 해야 한다 → 선택지:
- ① watermark 위에 **이미 적용된 transaction을 추가 추적**(applied set 영속),
- ② out-of-order commit **윈도우 bound**(watermark에서 N 이내만 앞서 commit 허용),
- ③ worker commit 순서 강제(병렬 이득↓).

→ 정식 구현에서 결정.

---

## 남은 설계 쟁점

- class 식별자 = **class OID로 확정**(이름 rename/재사용 위험 회피, applier가 `ws_oid()`로 보유).
- 순서 대기 해제 기준을 worker 완료 vs 순서 정리 완료 — **1차는 순서 정리 완료**가 안전(병렬↓, correctness 단순).
- pending 작업 과다 시 리더 멈춤 정책, barrier 범위.
- row/write-set 확장 시 기존 class 정책과 공존 방법.
- **[F.2] 재시작 정합 보강**(병렬 부작용) — 정식 구현 필수 항목.

## 요약

코디네이터는 `tranid % worker_count`를 대체하는 단순 picker가 아니라, **충돌·순서 보존을 판단해 실행 가능한 transaction만 분배하는 계층**(= LogReader enqueue 강화)이다. 1차 방향: 리더가 변경 class set 수집 → 코디네이터가 class set으로 충돌 판단(같은 class 직렬 / 다른 class 병렬 / schema·sysop·unknown barrier) → worker는 받은 것만 적용 → 순서 정리가 commit LSA 순서로 progress 갱신. 안정화 후 row/write-set 기반(Phase 2) 검토. 재시작 정합은 병렬 부작용이라 별도 보강(F.2).

## 참고문헌

[1] MySQL 8.0 Reference Manual, "Replication Implementation", https://dev.mysql.com/doc/refman/8.0/en/replication-implementation.html

[2] MySQL 8.0 Reference Manual, "Replication Threads", https://dev.mysql.com/doc/refman/8.0/en/replication-threads.html

[3] MySQL 8.0 Reference Manual, "Binary Logging Options and Variables", https://dev.mysql.com/doc/refman/8.0/en/replication-options-binary-log.html

[4] MySQL 8.0 Reference Manual, "Replica Server Options and Variables", https://dev.mysql.com/doc/refman/8.0/en/replication-options-replica.html

[5] MySQL 8.0 Reference Manual, "Replication and Transaction Inconsistencies", https://dev.mysql.com/doc/refman/8.0/en/replication-features-transaction-inconsistencies.html

[6] PostgreSQL 17 Documentation, "Logical Replication Architecture", https://www.postgresql.org/docs/17/logical-replication-architecture.html

[7] PostgreSQL 17 Documentation, "Publication", https://www.postgresql.org/docs/17/logical-replication-publication.html

[8] PostgreSQL 17 Documentation, "Subscription", https://www.postgresql.org/docs/17/logical-replication-subscription.html

[9] PostgreSQL 17 Documentation, "CREATE SUBSCRIPTION", https://www.postgresql.org/docs/17/sql-createsubscription.html

[10] PostgreSQL 17 Documentation, "Logical Replication Configuration Settings", https://www.postgresql.org/docs/17/logical-replication-config.html

[11] PostgreSQL 17 Documentation, "Logical Replication Restrictions", https://www.postgresql.org/docs/17/logical-replication-restrictions.html

[12] PostgreSQL 17 Documentation, "Logical Replication Conflicts", https://www.postgresql.org/docs/17/logical-replication-conflicts.html

[13] MySQL WorkLog WL#5569, "Replication events parallel execution via hashing per database name", https://dev.mysql.com/worklog/task/?id=5569

[14] PostgreSQL 17 Documentation, "Logical Streaming Replication Protocol", https://www.postgresql.org/docs/17/protocol-logical-replication.html

[15] PostgreSQL 16 Release Notes (large transaction parallel apply, `streaming = parallel`), https://www.postgresql.org/docs/release/16.0/

[16] CUBRID PoC/develop 로컬 소스: `src/transaction/log_applier.c`, `src/transaction/locator_sr.c`, `src/transaction/replication.c`, `src/object/schema_manager.c` (인라인 `file:line`), `2.design/poc_design.md`
