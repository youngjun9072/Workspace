# 병렬 applylogdb 코디네이터 컨셉

이 문서는 parallel `applylogdb` PoC 이후 실제 구현으로 넘어가기 위한 병렬화
컨셉을 정리한다. 상세 자료구조나 API 설계가 아니라, 어떤 책임을 새 모듈로
분리할지와 transaction 간 충돌/순서를 어떻게 다룰지를 잡는 문서다.

## 사전 지식 / 용어

배경 지식이 서로 다른 팀원을 위해, 이 문서에서 쓰는 핵심 용어부터 정리한다.

- **복제(replication)**: master(원본) DB의 변경을 slave(복제본) DB가 똑같이 따라 적용해 두 DB를 같은 상태로 유지하는 것. CUBRID HA의 핵심 동작이다.
- **master / slave**: 원본 / 복제본 서버. (MySQL의 source/replica, PostgreSQL의 publisher/subscriber와 같은 개념)
- **복제 로그(repl log) / 트랜잭션 로그**: master가 "무엇이 어떻게 바뀌었는지"를 순서대로 적어 둔 로그. slave는 이 로그를 읽어 변경을 재현한다. (DB가 변경을 영속화하려고 남기는 로그 = WAL 계열)
- **LSA (Log Sequence Address)**: 로그 안의 위치를 가리키는 주소(일종의 번호표). "어디까지 처리했는지"를 LSA로 표시한다. (MySQL의 binlog position, PostgreSQL의 LSN에 대응)
- **class**: CUBRID에서 **테이블**을 부르는 말. → 이 문서 예시의 `TblA`/`Tbl1`은 곧 "class A/class 1"을 뜻한다. (헷갈리기 쉬운 용어)
- **transaction / commit record**: 한 작업 묶음이 transaction이고, 로그에서 그 transaction이 끝났음(커밋)을 알리는 표시가 commit record다.
- **applylogdb / copylogdb**: CUBRID HA에서 **copylogdb**는 master의 로그를 slave로 복사해 오고, **applylogdb**는 그 복사된 로그를 읽어 slave DB에 적용한다. 이 문서가 개선하려는 대상은 applylogdb의 적용 단계다.
- **worker**: 실제로 변경을 slave DB에 적용하는 일꾼(스레드).
- **코디네이터(coordinator)**: worker 앞단에서 "어떤 transaction을 지금 보내도 되는가(충돌·순서)"를 판단해 분배하는 계층. ← 이 문서가 새로 도입하려는 모듈.
- **충돌(conflict)**: 두 transaction이 같은 데이터(1차안에선 같은 class)를 건드려, 적용 순서가 바뀌면 결과가 달라지는 관계.
- **순서 보존(commit order)**: 병렬로 적용하더라도 최종 반영(commit) 순서는 master에서의 순서와 같게 맞추는 것.
- **committed_lsa / 순서 정리**: "slave가 (순서대로) 어디까지 반영 완료했는가"를 가리키는 진도 표시가 committed_lsa. **순서 정리**는 병렬로 끝난 결과를 master 순서대로 줄 세워 committed_lsa를 전진시키는 단계다.
- **barrier**: 병렬화하지 않고 앞뒤를 끊어 직렬로 처리해야 하는 경계(예: 스키마 변경).

> 한 줄 비유: 복제 로그 = master의 "작업 지시서 묶음", 코디네이터 = 지시서를 보고 **"동시에 시켜도 되는 일"과 "순서를 지켜야 하는 일"** 을 나눠 일꾼(worker)에게 배분하는 반장.

## CUBRID 현재 상태와 한계

### 큰 그림 (현재 HA 복제 흐름)

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

### 현재 PoC의 병렬화 방식

현재 PoC는 commit record를 만나면 transaction id로 worker를 고른다.

```text
worker_idx = tranid % LA_APPLY_WORKER_COUNT
```

이 방식은 단순하지만 두 가지 문제가 있다.

- 서로 관련 있는(같은 데이터를 건드리는) transaction도 동시에 실행될 수 있다.
- 서로 독립적인 transaction도 특정 worker에 몰릴 수 있다.

가장 중요한 문제는 첫 번째다. 병렬 적용에서 worker를 고르는 방식보다 먼저
해결해야 할 것은 transaction 간 충돌과 순서 보존이다. 서로 영향을 주는
transaction을 동시에 실행하면 복제 결과가 원본 실행 순서와 달라질 수 있다.
(구체적으로 무엇이 깨지는지는 다음 장의 시나리오에서 다룬다.)

따라서 구현 단계에서는 단순 worker picker가 아니라, transaction 간 의존성을
판단하고 순차 실행이 필요한 작업을 막아 주는 코디네이터가 필요하다.

### 코드로 확인한 현재 상태 (CUBRID 소스 기준)

> 근거: `src/transaction/log_applier.c` (branch `feature/parallel_applylogdb_poc`). develop(오리지널)과의 차이는 "남은 확인 항목" 참조.

**적용 방식 = 논리(행 재실행).** applylogdb worker는 slave에 DB client session으로 붙어 복제 로그를 `la_apply_insert_log` / `la_apply_update_log` / `la_apply_delete_log` / `la_apply_statement_log`로 **다시 실행**한다(`log_applier.c:897-902`, worker client session `:1720~`). 즉 물리 페이지 redo가 아니라 행/문장 단위 재적용이며, slave는 자기 로그를 새로 생성한다 → **slave LSA ≠ master LSA**. (재시작 시 재적용 멱등성은 물리 redo처럼 자동 보장되지 않으므로 별도 점검이 필요 — 아래 "남은 확인 항목" 참조.)

**적용·가시성 동작 (정확성 판단의 전제, 코드 확인):**

- **적용 경로**: `la_apply_*_log` → `la_repl_add_object`(WS_REPL_OBJ 리스트 적재) → `locator_repl_flush_all` 벌크 flush(`:7589, :7470, :8234`). 질의 실행기(FK·트리거 경로)가 아니라 **locator 복제 경로로 레코드 이미지를 직접 반영**한다.
- **계층 구분 (중요):** `la_apply_*`는 **applier(client)** 로 변경을 모아 server에 보낼 뿐이고, FK 검사는 **slave server**의 `locator_insert_force`/`locator_update_force` 안에서 일어난다. (그래서 `log_applier.c`엔 FK 코드가 없다 — 없는 게 아니라 **server에 있고 repl 경로가 공유**한다.)
- **server는 repl 적용에도 FK를 검사한다.** `xlocator_repl_force` → `locator_insert_force(..., dont_check_fk=false)`(`locator_sr.c:7029,7256`) → `if (has_index && !skip_checking_fk) locator_check_foreign_key()`(`:5198-5201`), `skip_checking_fk = locator_Dont_check_foreign_key(false,:116) || dont_check_fk(false)`. update/PK 참조도 동일(`:6013, :8045, :8762`). → **자식을 부모보다 먼저 적용하면 FK 위반 → apply 에러 → 복제 중단.**
- **단, applier(applylogdb)는 FK를 알 방법이 없다.** 복제 로그 항목은 `la_make_repl_item`이 **class 이름 + PK 값 + operation type**만 풀어 담고(`log_applier.c:5708~`; LA_ITEM에 FK/참조 class 필드 없음), `log_applier.c`엔 FK·constraint 코드가 전무하다. FK 관계는 server 스키마(`SM_CLASS`)에만 있고 applier는 이를 조회하지 않는다. → **applier는 두 트랜잭션이 FK로 엮였는지 자기 입력(복제 로그)만으로는 판단할 수 없다.**
- (참고) `committed_lsa`는 읽기 가시성(MVCC)에 쓰이지 않는다(`src/query`·`mvcc.c`·`src/storage`에 없음). 다만 슬레이브 읽기 일관성(MVCC 가시성)은 본 설계 범위에서 제외한다.

### LSA / 로그 위치 갱신 (진도 관리) — applylogdb가 쓰는 LSA 전수 정리

applylogdb는 여러 LSA로 "마스터가 어디까지 썼나 / applier가 어디까지 읽고·반영했나 / 어디서 재시작하나"를 추적한다(LA_INFO `log_applier.c:465-510`, 구조체들 `:282-344`).

**A. 마스터 로그 위치 (랙 계산용)**

| LSA | 의미 |
|---|---|
| `append_lsa` | 마스터 active log가 기록한 끝 위치 (마스터가 어디까지 썼나) (`:500`) |
| `eof_lsa` | 마스터 active log의 EOF (`:501`) |

→ commit 처리 시 마스터 로그 헤더에서 복사(`la_log_commit:9740-9741`). `append_lsa − committed_lsa` ≈ 복제 지연(lag).

**B. applier 진행 — 핵심 4 (영속 대상)**

| LSA | 의미 | 갱신 |
|---|---|---|
| `final_lsa` | 마지막으로 **읽어 처리한** 로그 위치(읽기 커서) | 읽기 루프에서 전진(`:11478`), 재시작 시 `required_lsa`로 초기화(`:4643`) |
| `required_lsa` | **적용할 첫 트랜잭션의 start = 복구 재시작점(LWM)** | `la_find_required_lsa()` = 진행 중 트랜잭션 최저 `start_lsa`, 없으면 `final_lsa`(`:4078-4105`) |
| `committed_lsa` | 마지막으로 반영 완료한 **commit 로그 레코드** 위치 | retire(순서 정리)에서 `result->commit_lsa`로 전진(`:2082`) |
| `committed_rep_lsa` | 마지막으로 반영 완료한 **replication(데이터 변경) 로그 레코드** 위치 | retire에서 `result->committed_rep_lsa`로 전진(`:2085`) |

> `committed_lsa`(commit 레코드 기준) vs `committed_rep_lsa`(데이터 레코드 기준): 한 트랜잭션은 여러 데이터 변경 로그 + 1개 commit 로그를 가지므로 둘을 따로 추적한다.

**C. 재시작 baseline (기동 시점 스냅샷)**

| LSA | 의미 |
|---|---|
| `last_committed_lsa` | applylogdb **기동 시점**의 `committed_lsa`(`:468`) |
| `last_committed_rep_lsa` | 기동 시점의 `committed_rep_lsa`(`:469`) |

**D. 트랜잭션 / 항목 단위 (메모리 내 처리)**

| LSA | 구조체 | 의미 |
|---|---|---|
| `start_lsa` / `last_lsa` | `LA_APPLY` (트랜잭션별 목록) | 트랜잭션의 첫/마지막 repl 로그. `start_lsa`가 `required_lsa` 산출 입력(`:292-293`) |
| `lsa` | `LA_ITEM` (변경 1건) | 그 변경의 **replication 로그** 위치(`:282`) |
| `target_lsa` | `LA_ITEM` | 그 변경의 **실제 데이터(heap) 로그** 위치 → 적용 시 여기서 **레코드 이미지를 읽어옴**(`la_get_recdes:7904`, `:283`) |
| `log_lsa` | `LA_COMMIT` (commit 큐) | `LOG_COMMIT` 레코드 LSA(`:306`) |

> `LA_ITEM.lsa`(복제 지시 위치) ≠ `target_lsa`(적용할 레코드 이미지 위치) — applier는 `target_lsa`로 가서 적용할 행 이미지를 가져온다.

**영속화 & 진도선**

- `_db_ha_apply_info` 카탈로그에 **6개**가 기록된다: `final_lsa, committed_lsa, committed_rep_lsa, append_lsa, eof_lsa, required_lsa`(`:581-586`). commit 처리 시 `la_log_commit()`→`la_reader_commit_apply_info()`로 flush, 재시작 시 `la_get_last_ha_applied_info()`로 로드(`:4566~`; 최초 기동 `required=eof`, `committed=required`로 초기화 `:4628-4643`).
- 정상 진도선(대략): **`required_lsa`(LWM) ≤ `committed_lsa` ≤ `final_lsa` ≤ `append_lsa`(마스터 끝)**.

> 설계 반영: 병렬 코디네이터의 "순서 정리 단계"는 `committed_lsa`/`committed_rep_lsa`(commit 순서대로 전진)와 `required_lsa`(LWM·복구 지점)를 이 의미로 갱신해야 한다. worker가 비순차로 끝나도 `committed_lsa`는 반드시 commit 순서로만 전진해야 한다.

### 재시작 시 재적용 멱등성 (idempotent re-apply) — 코드 확인됨

> 용어: **idempotent(멱등)** 은 DB 복구·복제의 **표준 용어**다 — ARIES의 *idempotent redo*(page-LSN 비교로 자동 멱등)와 같은 개념으로, 같은 변경을 여러 번 적용해도 결과가 한 번 적용한 것과 동일함을 뜻한다. 아래 "멱등 스킵"은 그 구현(LSA baseline으로 이미 적용분 건너뛰기)을 가리키는 본 문서의 서술 표현이다.

**왜 필요한가.** applylogdb는 논리(행 재실행)라, 재시작 시 `required_lsa`(LWM)부터 복제 로그를 **다시 읽어 적용**한다. 그런데 `required_lsa`는 "아직 안 끝난 가장 오래된 트랜잭션의 시작"이라, 그 뒤에 **이미 커밋된 트랜잭션**이 섞여 있을 수 있다(특히 롱 트랜잭션이 LWM을 뒤로 당길 때). 그대로 재적용하면 **중복**(중복키 에러/중복 행). 물리 redo는 page LSN 비교로 자동 멱등이지만 논리 재실행은 아니므로 **명시적 skip**이 필요하다.

**baseline.** 기동 시 카탈로그(`_db_ha_apply_info`)에서 읽은 마지막 반영 위치를 baseline으로 잡는다: `last_committed_lsa = committed_lsa`, `last_committed_rep_lsa = committed_rep_lsa`(`log_applier.c:4666-4667`). = "이전 실행이 어디까지 반영했나".

**2단계 skip.**

① 트랜잭션 단위 — commit이 baseline 이하면 트랜잭션 통째로 건너뜀:
```c
if (apply->head == NULL || LSA_LE (commit_lsa, &la_Info.last_committed_lsa)) {
    la_free_all_repl_items (apply);   // 이미 적용된 트랜잭션 → 아이템만 비우고 종료
    return NO_ERROR;
}
```
② 항목(행 변경) 단위 — baseline보다 새 항목만 적용:
```c
for (item = apply->head; item; item = item->next)
  if (LSA_GT (&item->lsa, &la_Info.last_committed_rep_lsa) && ...)   // baseline 이하면 skip
    la_apply_{insert,update,delete}_log (...);
```

**예시.**
```text
required_lsa(재시작점)=100   (롱tx가 100에서 미커밋이라 LWM 고정)
last_committed_lsa(baseline)=150,  크래시 @180
재시작 → 100부터 다시 읽음
  commit_lsa ≤ 150 : ① 트랜잭션 통째 skip  /  item.lsa ≤ 150 : ② 항목 skip   → 중복 없음
  > 150 : 실제 적용
```

**develop = PoC 동일(확인).** skip 조건은 develop에도 동일하다 — `la_apply_commit_list()` 안의 `LSA_LE(commit_lsa, last_committed_lsa)`(develop `:5765`), `LSA_GT(item->lsa, last_committed_rep_lsa)`(develop `:5797`). PoC는 같은 조건을 worker 적용 경로(`:8754, :8775`)로 옮겼을 뿐 **로직은 같다**(레거시 `la_apply_commit_list`는 PoC에서 미호출).

> 의미: 물리 redo의 **page-LSN 멱등성**에 대응하는 것을, CUBRID는 **복제 진도 LSA(`commit_lsa`/`item->lsa`)를 기동 baseline과 비교**하는 방식으로 구현한다. → 병렬 설계의 "재시작 정합 · 롱tx 복구비용 수용 · 비순차 적용" 전제가 성립한다(멱등을 새로 만들 필요 없음, 기존 메커니즘 재사용).

### 남은 확인 항목

- ~~논리 재실행의 재시작 멱등성~~ → **확인됨**: 2단계 LSA skip으로 **idempotent re-apply** 보장(위 "재시작 시 재적용 멱등성" 절). develop·PoC 동일.
- **develop(오리지널) 대조:** 멱등 skip·core LSA·`required_lsa`·`_db_ha_apply_info`는 develop=PoC 동일 확인. 남은 차이는 **worker/retire(순서 정리) 구조가 PoC 추가분**이라는 점 — 적용 위치(`la_apply_commit_list` → worker 경로)와 순서 정리 단계 차이를 별도 정리.
- **파티션/LOB/상속** 등 특수 테이블 → `cubrid_special_table_scenarios.md`의 확인 항목 참조.

## 다른 DBMS의 처리 방식

### MySQL

MySQL replication은 source가 변경 내용을 binary log에 기록하고, replica가 이를
relay log로 받아 적용하는 구조다. 여기서 source는 원본 서버, replica는 복제
대상 서버를 뜻한다. Replica 내부에서는 I/O receiver thread가 source의 binary
log를 받아 relay log에 저장하고, SQL applier가 relay log의 transaction을
적용한다. 병렬 적용을 사용하는 경우에는 coordinator thread가 relay log를
순차적으로 읽고 transaction을 worker thread에 배정한다 [1][2].

설계 참고용으로 단순화하면 다음과 같다. MySQL WorkLog의 multithreaded slave
설계에서도 coordinator가 event를 읽고 `hash(E)`로 partition id를 계산한 뒤
worker queue로 전달하는 형태를 보여 준다 [13]. 다만 이 WorkLog는 database
partition/hash 기반의 초기 MTS 설계이므로, 아래 그림은 MySQL 현재 구현을 그대로
옮긴 것이 아니라 CUBRID 코디네이터 구조를 잡기 위한 참고 모델로 본다.

```text
source
  -> transaction commit 순서 확정
  -> binary log 기록
       - transaction 순서 정보 기록
       - dependency metadata 기록
         예: sequence_number, last_committed
  -> binary log 전송

replica
  -> I/O receiver thread
       - source binary log를 받아 relay log에 저장
  -> relay log
  -> coordinator thread
       - relay log를 순차적으로 읽음
       - transaction 순서/dependency metadata 확인
       - 실행 가능한 transaction을 worker queue에 배정
  -> worker queue[0] -> worker[0]
  -> worker queue[1] -> worker[1]
  -> worker queue[N] -> worker[N]
  -> commit order / recovery progress 정리
```

MySQL의 병렬 적용은 transaction 간 의존성을 기준으로 한다. Source는 transaction
dependency 정보를 binary log에 기록할 수 있으며, replica coordinator는 이 정보를
사용해 어떤 transaction을 병렬 실행할 수 있는지 판단한다. `LOGICAL_CLOCK` 방식은
transaction의 logical timestamp를 이용해 병렬 가능성을 판단하며, `WRITESET` 계열
방식은 transaction이 변경한 row/key 집합을 이용해 충돌 관계를 더 정밀하게 계산한다
[3][4].

> 병렬화 여부에 따라 source가 다른 종류의 binary log를 남기는 것은 아니다.
> MySQL은 `binlog_transaction_dependency_tracking`의 기본값인 `COMMIT_ORDER`에 따라
> transaction dependency metadata를 binary log에 기록할 수 있다. Replica에서 병렬
> 적용을 사용하지 않으면 transaction은 순차 반영되고, 병렬 적용을 사용하면
> coordinator가 이 값을 보고 의존성을 확인해 worker에 배정하는 차이로 보인다.

병렬 실행과 최종 commit 순서 보존은 분리된다. Worker는 독립적인 transaction을
병렬로 적용할 수 있지만, `replica_preserve_commit_order`를 사용하면 최종 commit
순서를 source의 commit 순서와 맞출 수 있다. 또한 MySQL은 DDL, foreign key 관련
변경, write set이 불완전한 transaction 등 충돌 판단이 어려운 경우에는 더 보수적인
방식으로 fallback한다 [4][5].

> **Note**
>
> MySQL의 binary log group commit은 여러 transaction의 binary log write, sync,
> storage engine commit을 묶어서 처리하는 commit 경로의 최적화다. 이 기능 자체가
> 병렬 복제의 필수 조건은 아니지만, 여러 transaction의 commit-time window가
> 겹치게 만들어 `LOGICAL_CLOCK` 기반 병렬 적용에 도움이 될 수 있다. MySQL 문서에서도
> 이 효과를 얻으려면 replica가 `replica_parallel_type=LOGICAL_CLOCK`을 사용해야 하며,
> `binlog_transaction_dependency_tracking=COMMIT_ORDER`일 때 효과가 더 크다고 설명한다.
> 따라서 group commit은 병렬 복제를 가능하게 하는 필수 메커니즘이라기보다,
> dependency 판단에 활용될 수 있는 commit overlap을 늘려 병렬성을 높이는 보조 요소로
> 보는 것이 적절하다 [3][4].

### PostgreSQL

PostgreSQL logical replication은 publication/subscription 모델이다. Publisher는
WAL을 logical decoding하여 logical change stream으로 만들고, subscriber의 apply
worker가 이를 받아 local table에 적용한다. Subscription은 어떤 publication을
받을지 정의하며, replication slot은 subscriber가 어디까지 변경을 수신했는지
publisher 측에서 보존하는 역할을 한다 [6][7][8].

PostgreSQL logical replication은 MySQL처럼 transaction 간 dependency metadata를
계산해 서로 독립적인 transaction을 병렬 dispatch하는 구조가 아니다. 기본 apply
모델은 publisher의 transaction stream을 subscriber apply worker가 같은 순서로
적용하여 단일 subscription 안의 transactional consistency를 보장하는 방식이다
[6][8].

PostgreSQL에서 병렬성이 나타나는 지점은 주로 두 곳이다.

- 초기 table synchronization: subscription 생성 시 subscriber에 없는 기존 table
  데이터를 copy하는 단계다. 여러 table sync worker가 기존 data copy를 병렬로
  수행할 수 있다 [6][10].
  - 원문 근거: "initial data in existing subscribed tables", "snapshotted and copied",
    "parallel instance of a special kind of apply process" [6]
  - 번역/해석: subscription 대상에 이미 존재하는 table의 초기 데이터를 snapshot으로
    잡고 copy한다. 이 copy는 일반 apply worker가 아니라 초기 동기화를 위한 특수
    apply process의 병렬 instance에서 수행될 수 있다. 또한
    `max_sync_workers_per_subscription`은 subscription 초기화 또는 새 table 추가 시
    initial data copy의 병렬도를 제어한다 [10].
- large in-progress transaction streaming: 큰 transaction을 commit 이후 한 번에
  보내지 않고, commit 전 변경분을 `Stream Start`/`Stream Stop` 단위로 나눠 보낸다.
  `streaming = parallel`이면 subscriber의 parallel apply worker가 이 stream 처리를
  도울 수 있다 [9][10][14].
  - 원문 근거: "streaming of in-progress transactions" [10],
    "incoming changes are directly applied via one of the parallel apply workers" [9],
    "Stream Start and Stream Stop messages" [14]
  - 번역/해석: `streaming` 옵션은 진행 중인 transaction을 commit 전에 subscriber로
    보낼지 결정한다. `streaming = parallel`이면 incoming change를 사용 가능한
    parallel apply worker가 직접 처리할 수 있다. 이 `streaming = parallel`(large
    transaction 병렬 apply) 기능 자체는 PostgreSQL 16에서 도입되었으며, 관련 worker
    수는 `max_parallel_apply_workers_per_subscription`으로 제어한다(기본값 2)
    [10][15]. 프로토콜 관점에서는
    large in-progress transaction의 변경이 `Stream Start`와 `Stream Stop` 사이에
    전달되고, 마지막 stream에는 `Stream Commit` 또는 `Stream Abort`가 포함된다
    [9][10][14].

large transaction streaming은 transaction 내부 chunk 간 dependency graph를 계산해
병렬화하는 방식은 아니다. 하나의 transaction에 속한 stream segment를 처리하는
것이므로 여러 transaction 간 충돌 판단 문제와는 성격이 다르다. Subscriber는 같은
transaction의 stream을 처리하되, 마지막 `Stream Commit` 또는 `Stream Abort`에 따라
최종 commit/abort를 맞춘다 [14].

이때 stream segment를 순서 없이 독립적으로 적용할 수 있는 것은 아니다. 같은
transaction 안에서도 앞선 변경이 뒤 변경의 전제가 될 수 있기 때문이다. 예를 들어
하나의 transaction 안에서 같은 row에 대해 `INSERT` 후 `UPDATE`가 발생했는데 두
변경이 서로 다른 stream segment에 들어갔다면, subscriber는 `INSERT` segment를
먼저 처리한 뒤 `UPDATE` segment를 처리해야 한다. `UPDATE` segment를 먼저 적용하면
대상 row가 아직 없으므로 transaction 의미가 깨질 수 있다. 따라서 PostgreSQL의
parallel apply worker는 large transaction stream 처리를 보조할 수 있지만, 같은
transaction 내부 segment를 임의 순서로 병렬 적용하는 모델은 아니다.

```text
Tx100
  segment 1: INSERT row id = 1
  segment 2: UPDATE row id = 1
  segment 3: Stream Commit

subscriber 처리 순서
  segment 1 처리
  segment 2 처리
  Stream Commit 수신 후 최종 commit
```

```text
publisher
  -> WAL
  -> walsender + logical decoding
       - pgoutput이 publication 기준으로 change filtering
       - transaction stream 생성

subscriber
  -> apply worker
       - transaction stream을 publisher 순서대로 적용
       - 단일 subscription 안의 transactional consistency 보장
  -> table synchronization worker
       - 초기 data copy 병렬화
  -> parallel apply worker
       - streaming = parallel일 때 large transaction stream 처리 보조
       - 일반 transaction 간 dependency scheduling 용도는 아님
```

PostgreSQL은 DDL을 logical replication 대상으로 자동 복제하지 않으며, schema는
사용자가 별도로 맞춰야 한다. Subscriber에서 constraint violation 같은 conflict가
발생하면 replication worker가 error를 내고 복제가 중단되며, 사용자가 직접 해결해야
한다 [11][12].

## MySQL 코디네이터

MySQL의 multithreaded replica에서 coordinator는 relay log를 순차적으로 읽고,
transaction을 worker thread에 배정하는 역할을 한다. 이때 coordinator의 핵심
역할은 단순히 비어 있는 worker를 찾는 것이 아니라, transaction 간 의존성을 기준으로
병렬 실행 가능한 transaction을 구분하는 것이다 [2][4].

MySQL에서 replica가 병렬 적용을 사용하려면 worker 수와 병렬화 방식을 설정한다.
대표적으로 `replica_parallel_workers`는 worker thread 수를 정하고,
`replica_parallel_type=LOGICAL_CLOCK`은 logical timestamp를 이용한 병렬 적용
방식을 사용하도록 한다 [4].

Logical clock 방식에서 source는 transaction마다 병렬 적용에 필요한 순서 정보를
binary log에 기록한다. 핵심 값은 `sequence_number`와 `last_committed`이다.
`sequence_number`는 binary log 안에서 transaction의 논리적 순번이고,
`last_committed`는 해당 transaction이 기다려야 하는 가장 최근 선행 transaction을
나타낸다. Replica coordinator는 relay log를 순차적으로 읽으면서 이 정보를 보고
어떤 transaction을 worker에 보낼 수 있는지 판단한다 [3][4].

MySQL은 dependency 정보를 계산하는 방식도 설정으로 분리한다.
`binlog_transaction_dependency_tracking=COMMIT_ORDER`는 commit 순서와 group
commit 정보를 기반으로 dependency를 계산한다. `WRITESET` 계열은 transaction이
변경한 row/key 집합을 이용해 충돌 여부를 더 정밀하게 판단한다.
`WRITESET_SESSION`은 write set 기반 판단에 같은 session의 transaction 순서 보존을
추가한 방식이다 [3].

병렬 실행과 최종 commit 순서 보존은 별도 개념이다. Coordinator는 logical clock과
dependency 정보를 바탕으로 worker 병렬 실행을 허용할 수 있지만,
`replica_preserve_commit_order`를 사용하면 worker들이 병렬로 처리한 transaction도
최종 commit 순서를 source의 commit 순서와 맞출 수 있다 [4].

정리하면 MySQL 코디네이터는 다음 정보를 기준으로 transaction을 스케줄링한다.

```text
relay log 순서
  - source commit 순서를 반영하는 기본 입력 순서

logical clock
  - sequence_number
  - last_committed

dependency tracking 방식
  - COMMIT_ORDER
  - WRITESET
  - WRITESET_SESSION

commit order 보존 설정
  - replica_preserve_commit_order
```

## 코디네이션 CUBRID 적용 방안

MySQL과 동일한 방식으로 병렬 적용을 구현하려면 master/source 쪽에서 복제 로그에
transaction dependency metadata를 기록해야 한다. MySQL은 source가 binary log에
`sequence_number`, `last_committed`, write set 기반 dependency 정보를 남기고,
replica coordinator가 이 정보를 읽어 병렬 실행 가능 여부를 판단한다 [3][4].

CUBRID에서 이 방식을 그대로 적용하려면 복제 로그에 다음과 같은 정보를 추가해야 한다.

```text
transaction sequence
dependency watermark
write set 또는 conflict key
barrier 여부
```

즉 MySQL과 같은 수준의 logical clock/write set 기반 병렬화를 목표로 한다면
복제 로그 포맷 또는 복제 log record 확장이 필요하다.

다만 1차 구현에서 반드시 복제 로그부터 변경할 필요는 없다. 현재 `applylogdb`는
복제 로그를 읽으면서 transaction별 apply list를 구성한다. 이 과정에서 slave/applylogdb
쪽 코디네이터가 보수적으로 dependency를 추론할 수 있다.

> **Note**
>
> 현재 문서의 1차 적용 방안은 transaction별 apply list를 만드는 과정에서
> "이 transaction이 어떤 class들을 변경했는지"를 함께 수집하고, commit 시점에
> 그 class set으로 transaction 간 충돌 여부를 판단하는 것이다.

1차 적용안은 다음과 같다.

```text
복제 로그에서 transaction별 변경 class 수집
  -> transaction별 touched class set 구성
  -> 같은 class를 변경하면 순차 실행
  -> 서로 다른 class만 변경하면 병렬 실행 가능
  -> schema/sysop/unknown은 barrier
```

이 방식은 MySQL처럼 source가 dependency metadata를 미리 기록하는 구조는 아니지만,
복제 로그 포맷 변경 없이 코디네이터 구조를 검증할 수 있다. 병렬성은 제한적이지만,
충돌 판단을 보수적으로 가져갈 수 있어 구현 초기 단계에 적합하다.

장기적으로 row/write-set 기반 정밀 병렬화를 목표로 한다면 repl log에 병렬 적용을
위한 정보를 추가하는 방향을 검토할 수 있다. 다만 1차 구현에서는 repl log 포맷을
바꾸지 않고 applylogdb 내부 class-level coordinator 구현에 correctness 확인과
병렬성 효과 확인을 포함한다. repl log 확장은 1차 구현 결과 병렬성이 부족할 때의
후속 고려사항으로 둔다. 따라서 적용 전략은 다음처럼 정리할 수 있다.

```text
1. applylogdb 내부 class-level coordinator 구현
   - 구현 범위 안에서 correctness 확인 포함
   - class-level 기준의 병렬성 효과 확인 포함
2. 병렬성이 부족하면 repl log에 병렬 정보 추가 검토
```

## 기본 방향

코디네이터는 복제 로그 리더와 worker 사이에 위치한다. 복제 로그 리더가
transaction 단위 작업을 만들고, 코디네이터가 그 작업의 실행 가능 여부를 판단한
뒤 worker에 분배한다.

```text
복제 로그 리더
  -> transaction 작업 생성
  -> 코디네이터
  -> worker
  -> 결과 회수
  -> 순서 정리
```

여기서 코디네이터의 목적은 worker를 고르는 것 자체가 아니다. 먼저 transaction 간
충돌과 순서 보존 필요 여부를 판단하고, 실행해도 되는 작업만 worker로 보내는 것이
핵심이다.

## 코디네이션 위치

현재 PoC에서는 복제 로그 리더가 commit record를 만나는 즉시 worker를 직접 고른다.

```text
commit record
  -> transaction 작업 생성
  -> tranid % worker_count
  -> worker queue
```

목표 구조에서는 이 결정을 코디네이터로 옮긴다.

```text
commit record
  -> transaction 작업 생성
  -> coordinator submit
  -> 충돌/순서 보존 필요 여부 판단
  -> 실행 가능하면 worker 선택
  -> worker queue
```

즉 복제 로그 리더는 입력을 읽고 transaction 작업을 만드는 역할에 집중한다.
transaction 간 관련성 판단과 worker 분배는 코디네이터가 맡는다.

> tx1, tx2 를 참조하는 tx3, 다음 들어오는 tx4(역시 tb1, tbl2 참고), 독립적인 tx5

## 목표 아키텍처

```text
+----------------------+
| 복제 로그 리더          |
| - 복제 record 스캔     |
| - transaction 구성    |
+----------+-----------+
           |
           v
+----------------------+
| transaction 작업      |
| - apply list         |
| - commit_lsa         |
| - 변경 class set      |
+----------+-----------+
           |
           v
+----------------------+
| 코디네이터              |
| - 충돌/순서 판단        |
| - 실행/대기 구분        |
| - worker 선택         |
+-----+----------+-----+
      |          |
      |          +--------------------+
      |                               |
      v                               v
+----------------------+     +----------------------+
| 실행 가능 작업          |     | 대기 작업               |
| worker queue로 이동   |     | pending 상태 유지       |
+----------+-----------+     +----------------------+
           |
           v
+----------------------+
| worker pool          |
| - worker[0]          |
| - worker[1]          |
| - worker[N]          |
+----------+-----------+
           |
           v
+----------------------+
| 결과 회수              |
| - worker result 수집  |
+----------+-----------+
           |
           v
+----------------------+
| 순서 정리              |
| - committed_lsa 갱신  |
| - apply info 갱신     |
+----------------------+
```

## 코디네이터 역할

코디네이터가 판단하는 질문은 다음 순서다.

```text
이 transaction은 이전 transaction과 충돌하는가?
충돌한다면 어떤 transaction 뒤까지 기다려야 하는가?
지금 실행 가능하다면 어느 worker에게 보낼 것인가?
```

앞의 두 질문은 correctness 문제다. 마지막 질문은 성능 문제다. 따라서 코디네이터는
worker 분배보다 충돌/순서 판단을 우선해야 한다.

코디네이터의 책임은 다음과 같다.

- transaction 간 충돌 여부를 판단한다.
- 순서를 지켜야 하는 transaction은 대기시킨다.
- 실행 가능한 transaction만 worker에 보낸다.
- worker 부하가 한쪽으로 몰리지 않도록 분배한다.
- 완료 또는 순서 정리 결과를 보고 대기 중인 transaction을 다시 판단한다.

## 트랜잭션 분배 방식

1차 분배 기준은 class 단위로 둔다. transaction별 apply list를 만드는 과정에서
해당 transaction이 변경한 class set을 함께 수집하고, commit 시점에 그 class set으로
충돌 여부를 판단한다.

```text
같은 class를 변경하는 transaction
  -> 순차 실행

서로 다른 class만 변경하는 transaction
  -> 병렬 실행 가능

schema/sysop/unknown transaction
  -> barrier
```

barrier는 앞뒤 transaction을 끊는 지점이다. barrier transaction은 앞선 작업이
정리된 뒤 실행하고, 뒤의 작업은 barrier가 정리된 뒤 실행한다.

이 방식은 row/write-set 단위보다 병렬성은 낮지만, 복제 로그 포맷 변경 없이
코디네이터 구조를 검증할 수 있다. 판단이 애매한 transaction은 병렬화하지 않는
것을 기본 원칙으로 둔다.

### 충돌 확인 방법

제안하는 1차 코디네이터는 class 단위로 충돌을 확인한다. 복제 로그 리더는 repl log를
순차적으로 읽으면서 transaction별 apply list를 구성하고, 이 과정에서 해당
transaction이 변경한 class 정보도 함께 수집한다. Commit record를 만나면 리더는
해당 transaction의 apply list가 끝났다고 보고 transaction 작업을 완성한다. 이때
리더는 apply list와 changed class set을 함께 코디네이터에 전달한다.

코디네이터는 repl log를 다시 분석하지 않는다. 리더가 넘긴 transaction 작업에 포함된
changed class set을 기준으로 충돌 여부를 판단한다. 즉 코디네이터가 받는 작업은
우선 다음 정보를 포함한다.

```text
transaction 작업
  - apply list
  - changed class set
```

`commit_lsa`, transaction type flag, schema/sysop/unknown 작업의 구분 방식은
실제 applylogdb 구조를 더 확인한 뒤 확정한다.

판단 방식은 단순하다.

- 이미 실행 중이거나 아직 순서 정리가 끝나지 않은 transaction과 같은 class를
  변경하면 충돌로 본다.
- 변경 class가 겹치지 않으면 병렬 실행할 수 있다.
- schema 변경, sysop, 변경 class를 알 수 없는 작업은 추가 확인 후 barrier 처리
  대상으로 둔다.

복제 로그 리더가 commit record를 만나 transaction 작업을 코디네이터에 넘기면,
코디네이터는 다음 순서로 판단한다.

1. 먼저 변경한 class 목록을 확인한다.
   이 목록은 apply list를 만드는 과정에서 함께 수집해 둔다.

2. 현재 실행 중이거나 아직 순서 정리가 끝나지 않은 transaction들의 변경 class와
   비교한다.

3. 같은 class가 하나라도 있으면 충돌로 판단한다.
   새 transaction은 바로 worker에 보내지 않고 pending 상태로 둔다. 이후 충돌하던
   선행 transaction의 실행과 순서 정리가 끝나면 다시 실행 가능 여부를 확인한다.

4. 같은 class가 하나도 없으면 병렬 실행할 수 있다.
   이 경우 코디네이터가 적절한 worker queue를 골라 transaction을 전달한다.

5. 변경 class를 수집할 수 없거나 class 기준 판단이 안전하지 않은 작업은 barrier로
   처리하는 방향을 검토한다. 구체적인 판별 기준은 실제 applylogdb record와
   operation type 확인 후 확정한다.

예를 들어 다음 transaction들이 있다고 가정한다.

```text
Tx1 changed_classes = {A}
Tx2 changed_classes = {B}
Tx3 changed_classes = {A}
```

Tx1은 class A를 변경하고, Tx2는 class B를 변경한다. 서로 건드리는 class가 다르므로
두 transaction은 동시에 실행할 수 있다.

```text
Tx1 -> class A 변경
Tx2 -> class B 변경

결과:
  서로 다른 class이므로 병렬 실행 가능
```

반면 Tx3도 class A를 변경한다. Tx1이 아직 실행 중이거나 순서 정리가 끝나지 않았다면,
Tx3을 동시에 실행하면 같은 class에 대한 변경 순서가 뒤섞일 수 있다. 따라서 Tx3은
Tx1 뒤로 미룬다.

```text
Tx1 -> class A 변경
Tx3 -> class A 변경

결과:
  같은 class를 변경하므로 충돌
  Tx3은 Tx1 완료/순서 정리 이후 실행
```

이 방식은 row 단위까지 들여다보지 않는다. 따라서 실제로는 서로 다른 row를 변경해서
동시에 실행해도 괜찮은 경우라도, 같은 class를 변경하면 충돌로 본다.

```text
Tx4: class A의 row 1 update
Tx5: class A의 row 999 update

실제로는 서로 다른 row라 독립일 수 있음
하지만 1차안에서는 둘 다 class A를 변경하므로 충돌로 판단
```

결과적으로 class-level 판단은 보수적인 방식이다. 장점은 repl log 포맷을 바꾸지
않고 applylogdb 내부에서 구현할 수 있으며, correctness 판단이 단순하다는 점이다.
단점은 row/write-set 기반 판단보다 병렬성이 낮다는 점이다. 특정 hot class에
transaction이 몰리면 대부분의 transaction이 순차 실행되어 병렬 적용 효과가 줄어들
수 있다. 병렬성이 부족한 경우에는 후속 단계에서 repl log에 write-set 또는 conflict
key 같은 병렬 적용 정보를 추가하는 방향을 검토한다.

### 대기 방식 선택

class 단위 충돌을 처리하는 방식은 크게 두 가지로 볼 수 있다.

첫 번째는 전역 pending queue 방식이다.

```text
Tx1 -> Tbl1
Tx2 -> Tbl2
Tx3 -> Tbl1

Tx1 실행 중
Tx3은 Tbl1 충돌 때문에 pending queue에 보관
Tx1 정리 완료 후 Tx3을 다시 평가하고 worker에 배정
```

이 방식은 선행 transaction이 끝난 뒤 다시 worker를 고를 수 있어 일반적이다.
다만 pending queue 관리와 재평가 로직이 필요하다.

두 번째는 충돌 domain의 owner worker queue에 바로 붙이는 방식이다.

```text
Tx1 -> Tbl1 -> worker[1]
Tx2 -> Tbl2 -> worker[2]
Tx3 -> Tbl1 -> worker[1] queue 뒤에 enqueue
```

이 방식은 같은 class의 순서를 worker queue 자체로 보장할 수 있어 단순하다.
하지만 특정 class에 transaction이 몰리면 worker skew가 커질 수 있고, 여러 class를
동시에 변경하는 transaction에서는 어느 worker queue에 붙일지 결정하기 어렵다.

```text
Tx4 -> Tbl1, Tbl2

Tbl1 owner = worker[1]
Tbl2 owner = worker[2]

Tx4를 어느 worker queue에 붙일지 애매해짐
```

따라서 컨셉 단계에서는 전역 pending queue 방식을 기본으로 본다. 단일 class
transaction에 대해서는 owner worker queue 직렬화가 최적화 후보가 될 수 있지만,
다중 class, schema, sysop, unknown transaction까지 고려하면 pending queue 기반
재평가 방식이 더 일반적인 모델이다.

## 모듈별 역할과 책임

### 복제 로그 리더

복제 로그 리더는 복제 record를 읽고 transaction 작업을 만든다.

- 복제 record를 transaction별 apply list로 모은다.
- apply list를 만들면서 변경 class set을 함께 수집한다.
- commit record를 만나면 transaction 작업을 완성한다.
- 완성된 작업을 worker에 직접 넣지 않고 코디네이터에 제출한다.

### 코디네이터

코디네이터는 transaction 실행 가능 여부를 판단하고 worker에 분배한다.

- 변경 class set을 기준으로 충돌 여부를 판단한다.
- 실행 가능한 작업과 대기해야 하는 작업을 구분한다.
- schema/sysop/unknown 작업은 barrier로 취급한다.
- 실행 가능한 작업을 worker queue에 넣는다.
- 대기 중인 작업을 언제 다시 실행할 수 있는지 판단한다.

### worker

worker는 코디네이터가 넘긴 transaction 작업만 실행한다.

- 복제 항목 적용
- flush
- commit
- 결과 반환

worker는 transaction 간 충돌 여부를 판단하지 않는다.

### 결과 회수와 순서 정리

worker 결과는 병렬로 도착할 수 있다. 하지만 global progress는 기존 commit LSA
순서대로만 전진해야 한다.

순서 정리 단계의 책임은 다음과 같다.

- worker 결과 회수
- `committed_lsa` 갱신
- apply info 갱신
- `LA_APPLY` slot 반환
- commit counter 누적

코디네이터가 실행 순서를 조정하더라도, 최종 progress 갱신은 순서 정리 단계가
담당한다.

## 병렬화 효과 예시

class 단위 코디네이션의 병렬화 효과는 transaction이 얼마나 여러 class로 분산되어
있는지에 좌우된다.

Best case는 서로 다른 class를 변경하는 transaction이 연속으로 들어오는 경우다.

```text
복제 로그 순서

Tx1 -> TblA
Tx2 -> TblB
Tx3 -> TblC
Tx4 -> TblD
```

각 transaction의 변경 class가 겹치지 않으므로 병렬 실행이 가능하다.

```text
time ---->

worker[0]:  [ Tx1: TblA ]
worker[1]:  [ Tx2: TblB ]
worker[2]:  [ Tx3: TblC ]
worker[3]:  [ Tx4: TblD ]
```

이 경우 worker 활용도가 높고, 병렬화 효과가 크다.

Worst case는 transaction이 하나의 hot class에 집중되는 경우다.

```text
복제 로그 순서

Tx1 -> TblA
Tx2 -> TblA
Tx3 -> TblA
Tx4 -> TblA
```

class 단위 판단에서는 모든 transaction이 같은 class에서 충돌한다. 따라서 병렬
worker가 여러 개 있어도 실행은 사실상 순차화된다.

```text
time ---->

worker[0]:  [ Tx1: TblA ][ Tx2: TblA ][ Tx3: TblA ][ Tx4: TblA ]
worker[1]:
worker[2]:
worker[3]:
```

중간 케이스는 여러 class conflict group으로 나뉘는 경우다.

```text
복제 로그 순서

Tx1 -> TblA
Tx2 -> TblB
Tx3 -> TblA
Tx4 -> TblC
Tx5 -> TblB
Tx6 -> TblD
```

class별로는 순서를 지키고, 서로 다른 class group은 병렬 실행할 수 있다.

```text
time ---->

worker[0]:  [ Tx1: TblA ][ Tx3: TblA ]
worker[1]:  [ Tx2: TblB ][ Tx5: TblB ]
worker[2]:  [ Tx4: TblC ]
worker[3]:  [ Tx6: TblD ]
```

정리하면, 서로 다른 class를 변경하는 transaction이 많을수록 병렬화 효과가 커지고,
하나의 hot class에 transaction이 집중될수록 병렬화 효과는 작아진다.

## 정확성·순서 보존 설계 (개선 방향)

> 현재 PoC는 **병렬성 측정용**이라 제약이 많다(예: 일부 worker만 flush하는 `worker_idx < LA_APPLY_WORKER_REPL_ACTIVE_COUNT` 가드, 권한 컨텍스트 TODO 등). 이 절은 PoC 스캐폴딩이 아니라 **개선/최종 구조**를 기준으로 정확성을 설계한다.

### 계층 구분 — 병렬은 applier, 그러나 applier는 FK를 알 수 없다

- **applier(client, `la_apply_*` / applylogdb)**: 복제 로그를 읽어 worker로 병렬 적용 — **병렬성 보장 주체.** 그러나 복제 로그 항목(`la_make_repl_item`)은 **class 이름 + PK 값 + operation**만 담고(LA_ITEM에 FK 필드 없음), applier에 FK·constraint 코드가 전무하다. → **applier는 두 트랜잭션이 FK로 엮였는지 자기 입력만으로 알 수 없다.**
- **server(slave `cub_server`, `locator_*_force`)**: applier가 보낸 변경을 반영하며 **FK를 검사**한다(`dont_check_fk=false`). FK 관계는 server 스키마(`SM_CLASS`)에만 존재한다.
- 따라서 applier는 server의 FK 검사를 **끄지도(현재 구조), 미리 알지도 못한다.** 제어 가능한 건 **무엇을 어떤 순서로 보내느냐**뿐이다.

### 문제 — applier가 FK를 모르므로, 안전하려면 commit 순서를 (보수적으로) 지켜야 한다

자식(order_items)을 부모(orders)보다 먼저 적용하면 server의 FK 검사가 부모를 못 찾아 **apply 에러 → 복제 중단**(시나리오 2a). 그런데 **applier는 어떤 트랜잭션이 FK로 엮였는지 모르기 때문에** "FK 관련만 콕 집어 직렬화"하는 것이 자기 입력만으로는 불가능하다. → 안전을 위해 applier는 **FK 관련을 구분하지 못한 채 commit 순서를 보수적으로 보존**해야 한다(또는 별도로 스키마 FK 메타를 로드해야 한다). 게다가 FK 검사는 **자식 INSERT 시점**에 일어나므로 "commit만 순서대로(SPCO)"로도 부족하다 — 자식이 적용되는 순간 부모가 **이미 커밋되어 보여야** 한다. → **부모 커밋 완료 후 자식 적용**이라는 *적용 직렬화*가 필요하다.

#### 시나리오 — FK로 commit 순서가 깨지는 경우

**master (실제 commit 순서 — FK 만족 상태):**

```text
T1 commit:  INSERT INTO orders(id=100)             ← 부모(parent)
T2 commit:  INSERT INTO order_items(order_id=100)  ← 자식(child), FK → orders(100)
```

master에선 T1(부모)이 먼저 커밋됐기에 T2(자식) 삽입 시 부모가 존재 → FK 통과.

**slave applier — class-level 병렬, 순서 미보존:**

```text
코디네이터 판단:
  T1.changed = {orders}, T2.changed = {order_items}
  → 다른 class → "독립" 오판 → worker A=T1, worker B=T2 병렬 배정

time ─────────────────────────────►
worker A (T1, 부모):  [ INSERT orders(100) .........느림......... commit ]
worker B (T2, 자식):  [ INSERT order_items(100) → server FK 검사 ]
                                         │
                                         ▼
                           orders(100) 아직 미커밋 → 부모 안 보임
                           → ❌ FK 위반 에러 → apply 실패 → 복제 중단
```

자식(T2)이 부모(T1)보다 먼저 적용되려 했고(= master commit 순서 역전), server FK 검사가 이를 막아 **에러로 복제가 멈춘다**(조용한 고아가 아니라 시끄러운 중단 — server가 FK를 보기 때문).

**고치면 (순서 보존 — 부모 커밋 후 자식 적용):**

```text
코디네이터가 FK 인지 → T1·T2를 같은 직렬 그룹으로:
worker: [ INSERT orders(100) → commit ]
            └─► [ INSERT order_items(100) → FK 검사: orders(100) 있음 ✔ → commit ]
```

> 정리: **FK로 엮인 트랜잭션은 "부모 먼저 커밋" 순서를 반드시 지켜야 한다.** (전부가 아니라 FK 관련 쌍만. FK 관계를 모르면 보수적으로 전체 순서를 지키게 되어 병렬성이 줄어든다.)

### 단계별 설계 (Phase 1 / Phase 2)

**Phase 1 — applier가 보수적으로 보장 (repl log 포맷·server 변경 없음)**

- 같은 class → 직렬.
- **FK/순서 의존 → 적용 직렬화 + commit 순서 보존**(부모 적용·커밋 후 자식 적용). 독립 트랜잭션만 병렬.
- 진도/복구: `committed_lsa` 순서 전진 + `required_lsa`(LWM) + **재시작 멱등 스킵**(`commit_lsa ≤ committed_lsa`면 skip).
- 한계: applier가 "무엇이 FK로 엮였는지"를 알아야 직렬 대상을 고른다 → FK 그래프(스키마 메타)를 코디네이터에 로드하거나, 모르면 보수적으로 더 직렬화(병렬↓).

**Phase 2 — FK 관련의 병렬화는 server 그룹 처리로**

- FK로 엮인 작업까지 병렬화하려면 applier가 그룹을 병렬로 흘리고, **server가 그룹 단위로 적용하며 그룹 내 FK 순서/지연 검사를 처리**하는 방향. (예: repl 적용 경로에서 그룹 경계까지 FK 검사를 지연했다가 일괄 검증, 또는 그룹 내부에서 부모→자식 순서 해소.)
- 대안: repl log에 **변경 키/의존성 정보**를 실어 server·applier가 행/키 단위로 충돌을 판단(정밀 병렬, repl log 포맷 확장 — 장기 카드).

### 의존성 종류 → 책임 (요약)

| 의존성 | Phase 1 (applier) | Phase 2 (server) |
|---|---|---|
| 같은 class(같은 데이터) | 직렬 | — |
| FK로 엮인 다른 class | **적용 직렬 + commit 순서** | 그룹 처리로 병렬화 |
| 독립(순서 무관) | 병렬 (단 `committed_lsa`는 순서대로) | 병렬 |

> 비-FK 인과(제약 없는 논리적 선후)와 슬레이브 읽기 일관성은 MVCC 가시성 영역이라 **본 설계 범위 밖**(사용자 결정).
>
> 한 줄: **Phase 1은 applier가 FK/순서 의존을 직렬화하고 commit 순서를 보존해 안전을 확보, FK 관련 병렬화는 Phase 2에서 server 그룹 처리로 연다.**

### 기타 시나리오 / 확인 항목

FK 외에 검토한 시나리오들. 판단 기준은 **"applier가 자기 입력(복제 로그)만으로 식별 가능한가"** 다.

**applier가 식별 가능 → 이미 처리됨**

- **Unique / PK 키 재사용 (same-class)**: 예) `DELETE accounts(pk=5)` 후 `INSERT accounts(pk=5)`. server가 unique 인덱스를 유지하므로(`locator_add_or_remove_index`) 비순차면 중복키 에러가 나지만, **둘 다 같은 class라 applier가 class OID(`db_find_class→ws_oid`, `log_applier.c:8162,7601`)로 구분해 same-class 직렬화로 처리**한다. → same-class 규칙은 lost-update뿐 아니라 **unique/PK 에러 방지**도 겸한다.
- **트리거**: applier가 세션에서 `db_disable_trigger()`(`log_applier.c:1831`)로 **트리거를 끈다** → apply 시 재실행 없음 → 숨은 cross-class 의존 없음. (해당 없음)

**applier가 식별 불가 → 별도 대응 필요**

- **FK (cross-class)**: applier 입력 밖이다(다른 class 간 관계는 server `SM_CLASS`에만). → commit 순서 보존(Phase 1) / server 그룹핑(Phase 2). (위 참조)
- **상속(super/sub class)의 계층 공유 unique 인덱스**: subclass가 superclass의 unique/PK를 inherit하면 **같은 BTID(B-tree)를 공유**해 계층 전체에 unique가 enforce된다 → 서로 다른 subclass에 같은 키를 비순차 적용하면 위반(server 에러). FK와 같은 applier-blind cross-class 위험(단 실무 빈도 낮음). 대응도 FK와 동일.

**복구 / 진도 축**

- **롱 트랜잭션 (정확성 문제 아님 — 복구 비용)**: 일찍 시작·늦게 끝나면 `required_lsa`(LWM)가 오래 고정되어 재시작 재적용 윈도우·로그 보존이 커진다. 이는 **정확성 깨짐이 아니라 복구 비용**이므로, 설계상 의도적으로 수용하면 문제가 아니다. **단 전제: 재적용이 멱등**이어야 한다(멱등이 없으면 같은 재적용이 중복=정확성 문제로 전환). CUBRID applier엔 이미 `is_long_trans`(LA_APPLY) 플래그가 있어 별도 취급 가능. PoC 워크로드(대형 단일 트랜잭션)가 이 경우.

**CUBRID 특화 — class 식별 단위에 종속(확인 필요)**

- **파티션 class**: 한 논리 테이블의 파티션이 서로 다른 class_oid면 "다른 class=병렬"로 오판할 수 있다 → 글로벌 unique 등에 영향. class 식별을 root/partition 중 무엇으로 할지 확인.
- **상속(super/sub class)**, **serial / `db_serial` 카탈로그**: 충돌 판단에 미치는 영향 확인.
- 📄 특수 테이블(파티션·뷰·상속·LOB·serial·non-MVCC) **유형별 상세 분석 → `cubrid_special_table_scenarios.md`**. 요지: **파티션은 구조적으로 안전**(파티션 키 ∈ 인덱스 키 규칙이 cross-partition unique 충돌을 막음, FK+파티션은 CUBRID가 제약), 뷰는 비복제(문제 없음), non-MVCC 처리됨, LOB은 데이터 비복제(코디네이터 무관), 파티션은 스키마 규칙으로 안전, **상속은 계층 공유 unique 인덱스라 cross-subclass 충돌 가능(FK 가족, 실무 빈도 낮음)**, 복제는 PK 필수. → applier가 못 막는 cross-class 위험은 **FK + 상속** 두 가지(둘 다 Phase 1 commit 순서가 커버).

> **class 식별자는 class OID로 확정**한다(이름은 rename/재사용 위험). applier가 이미 `ws_oid()`로 OID를 갖고 있어 추가 비용이 없다.

> 정리: 서버가 **에러로 막는 applier-blind cross-class 의존은 FK + 상속(계층 공유 unique 인덱스) 두 가지**다(같은 class 내 unique/PK는 same-class가 커버, 트리거는 비활성, 파티션은 스키마 규칙이 보강, LOB은 데이터 비복제). 둘 다 Phase 1 commit 순서 보존이 커버하며, 상속은 실무 빈도가 낮다. 나머지는 same-class 직렬화·복구(LWM/멱등)다.

## 남은 설계 쟁점

컨셉 단계에서 남겨둘 쟁점은 다음이다.

- class 식별자는 어디서 얻을 것인가
- ~~class name을 임시로 쓸 것인가, 처음부터 class OID를 쓸 것인가~~ → **class OID로 확정**(이름 rename/재사용 위험 회피, applier가 `ws_oid()`로 이미 보유). 기타 시나리오 절 참조.
- 순서 대기 해제 기준을 worker 완료로 볼 것인가, 순서 정리 완료로 볼 것인가
- pending 작업이 너무 많아질 때 리더를 어떻게 멈출 것인가
- barrier 범위를 어디까지 잡을 것인가
- 추후 row/write-set 단위로 확장할 때 기존 class 정책과 어떻게 공존시킬 것인가

1차 구현에서는 순서 대기 해제 기준을 순서 정리 완료로 두는 것이 안전하다.
worker가 끝났더라도 global progress가 아직 전진하지 않았다면 관련 후속
transaction을 실행하지 않는 방식이다. 병렬성은 줄지만 correctness 판단이 단순하다.

## 요약

코디네이터는 `tranid % worker_count`를 대체하는 단순 worker picker가 아니다.
transaction 간 충돌과 순서 보존 필요 여부를 판단하고, 실행 가능한 transaction만
worker에 분배하는 계층이다.

처음 구현 방향은 다음이 적절하다.

- 복제 로그 리더는 transaction 작업을 만든다.
- apply list 생성 과정에서 변경 class set을 수집한다.
- 코디네이터는 class set으로 충돌 여부를 판단한다.
- 같은 class를 변경하면 순차 실행한다.
- 서로 다른 class만 변경하면 병렬 실행을 허용한다.
- schema/sysop/unknown은 barrier로 둔다.
- worker는 받은 transaction 작업만 실행한다.
- 최종 progress는 순서 정리 단계에서 commit LSA 순서대로 갱신한다.

이 구조가 안정화된 뒤 row/write-set 기반 분배를 검토한다.

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

[15] PostgreSQL 16 Release Notes (large transaction에 대한 parallel apply, `streaming = parallel` 도입), https://www.postgresql.org/docs/release/16.0/
