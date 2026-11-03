# C2 코드 설계 — writeset를 마스터 커밋경로 + DML 키수집 + WSET_LABEL에 배선

> 커밋 C2: C1(writeset 모듈)은 그대로 두고 **호출부**를 심는다. 키수집(WRITE=PK/UNIQUE, REF=FK), 커밋경로 probe/flush, WSET_LABEL 레코드. 라인번호는 develop(=base c63a3b993) 기준, `PoC:`는 feature/writeset_error_skip. develop 커밋경로는 PoC base와 구조 동일 확인됨. 상위=[`01-commit-plan.md`](01-commit-plan.md), C1=[`03-c1-code-design.md`](03-c1-code-design.md).

## 0. 환경 확정
- C2는 C1의 `wset_*` 필드를 참조 → **C1 working tree 위에 얹음**(둘 다 미커밋 공존, 커밋 시 분리). 실행자는 C1 필드가 `wset_`인지 확인 후 작성.
- `log_manager.c`·`locator_sr.c`는 **server+SA만**(cs 아님) → TBB 품은 `writeset.h` **무가드 include 안전, C2 CMake 변경 없음**. probe/flush 감싸는 `#if SERVER_MODE||SA_MODE`는 항상참이지만 의도 문서화용으로 유지.
- develop enum 슬롯 **53 비어있음**(`LOG_SUPPLEMENTAL_INFO=52` → `LOG_LARGER_LOGREC_TYPE`) → `LOG_DUMMY_WSET_LABEL=53` 그대로.
- ★**atomic-LSA(CBRD-27320)는 C2 무관**: C2 훅은 평범한 로컬 `LOG_LSA commit_lsa`(out-param)와 `tdes->wset_dependency_seq`(평범 LOG_LSA)만 만짐. append_lsa/prev_lsa 안 건드림 → load()/store() 불필요. (atomic-LSA는 C3의 `la_apply_log_file` reader만.)

## 1. 키수집 호출부 (locator_sr.c)
공통 가드: `datayn && need_replication && !LOG_CHECK_LOG_APPLIER(thread_p) && log_does_allow_replication()` + 인덱스 타입 테스트. `datayn`=RBR만. tdes는 각 지점에서 `LOG_FIND_TDES(LOG_FIND_THREAD_TRAN_INDEX(thread_p))`; 콜리는 `tdes==NULL`/`wset_overflow`에 no-op.

| # | 키 | develop 함수 | 위치 | 호출 | 트리거 |
|---|---|---|---|---|---|
| 1 | WRITE PK (INS/DEL) | `locator_add_or_remove_index_internal`(@7763) | repl_log_insert PK 블록 뒤 @8041–8046 `if(err==NO_ERROR && datayn)` | `wset_add_dbvalue(thread_p,tdes,class_oid,key_dbvalue)` | 삽입/삭제 행의 PK b-tree |
| 2 | WRITE UNIQUE (INS/DEL) | 동 | per-index 루프 UNIQUE 테스트 뒤 ~@7918 | `add_dbvalue(...,key_dbvalue)` + `index->type==BTREE_UNIQUE\|\|REVERSE_UNIQUE` 가드 | 각 UNIQUE/REVERSE_UNIQUE 인덱스 |
| 3 | REF FK (INS/DEL) | 동 | 동 위치, `index->type==BTREE_FOREIGN_KEY` 가드 | `locator_wset_collect_fk_ref(thread_p,index,i,&index_attrinfo,recdes,inst_oid)` | 각 FK 인덱스; recdes=touched 행(insert=new, delete=old) |
| 4 | WRITE UNIQUE (UPD) | `locator_update_index`(@8263) | update 루프 UNIQUE 테스트 ~@8598 | `add_dbvalue(...,old_key)` 항상; `add_dbvalue(...,new_key)` `!same_key`일 때 | old 정체 항상, unique 값 변경 시 new |
| 5 | REF FK (UPD) | 동 | FK 테스트 ~@8652 | `collect_fk_ref(...,old_attrinfo,old_recdes,oid)` 항상; `!same_key`면 new도 | old 부모 항상, FK 변경 시 new 부모 |
| 6 | WRITE PK OLD+NEW (UPD 루프) | 동 | `if(pk_btid_index==i && repl_old_key==NULL)` 블록 | `add_dbvalue(old_key)` **및** `add_dbvalue(new_key)` | UPDATE가 PK 바꿀 수 있음 → OLD·NEW 두 정체(new_key 살아있을 때 둘 다) |
| 7 | WRITE PK OLD (UPD 엣지) | 동 | 루프 뒤 `if(repl_old_key==NULL){heap_attrvalue_get_key; repl_log_insert(UPDATE)}` ~@8781–8808 | `add_dbvalue(repl_old_key)`만 | 루프 블록 미실행 엣지, new_key 이미 해제 → OLD만. #6과 상호배타(중복 없음) |

**신규 static** `locator_wset_collect_fk_ref`(PoC:locator_sr.c:7807): 가드 `index && type==BTREE_FOREIGN_KEY && index->fk`; tdes fetch, `wset_overflow`면 return; `parent_pk_domain=btree_read_key_type(&index->fk->ref_class_pk_btid)`; `heap_attrvalue_get_key(...)`로 `fk_key` 추출; `wset_add_ref_dbvalue(thread_p,tdes,&index->fk->ref_class_oid,fk_key,parent_pk_domain)`; dbvalue clear. 전부 best-effort(NULL이면 return, 보수적 기존 경로로 폴백). perf 부분 제거.

develop DELETE는 `is_insert` 플래그로 `locator_add_or_remove_index_internal` 재사용 → #1–#3이 INSERT·DELETE 자동 커버.

## 2. 커밋경로 배선 (log_manager.c : `log_commit_local`)
develop의 `is_local_tran` 복제 분기(@~5280–5290)는 PoC base와 동일. 기존 `log_append_repl_info_and_commit_log(thread_p,tdes,&commit_lsa)` 양옆에 두 훅. 기존 `if(!LOG_CHECK_LOG_APPLIER && tdes->is_active_worker_transaction() && log_does_allow_replication())` 블록 안(PoC:5296–5312):

```c
#if defined(SERVER_MODE) || defined(SA_MODE)
  /* 의존 라벨은 commit LSA 할당 전(prior_lsa_mutex 밖, writeset history latch 하) 계산 */
  wset_commit_probe (thread_p, tdes, &tdes->wset_dependency_seq);
#endif
  log_append_repl_info_and_commit_log (thread_p, tdes, &commit_lsa);   /* 기존; 이제 WSET_LABEL도 방출 §3 */
#if defined(SERVER_MODE) || defined(SA_MODE)
  assert (LSA_ISNULL (&tdes->wset_dependency_seq) || LSA_LE (&tdes->wset_dependency_seq, &commit_lsa));
  wset_commit_flush (thread_p, tdes, &commit_lsa);
#endif
```
- **probe**: commit-LSA 할당 전, 라벨을 `tdes->wset_dependency_seq`에 씀(mutex 구간 안 wset_label append가 읽도록).
- **flush**: `commit_lsa` 할당 **후** · **`lock_unlock_all(thread_p)` 직전**(바로 다음 문장). ★핵심 불변식: 행 X-lock 해제 전 키 게시 → 이후 같은키 tx가 이 커밋 키를 히스토리에서 보기 전엔 probe 못함(같은키 직렬화 → flush happens-before 후속 probe). **flush를 lock_unlock_all 뒤로 옮기지 말 것.**
- `else`(비복제 `log_append_commit_log`) 분기는 probe/flush/label 없음(게이트할 것 없음).

## 3. WSET_LABEL 레코드
**방출 지점**: `log_append_repl_info_and_commit_log`(@4715) 안, repl-info append와 commit append **사이** → 같은 `prior_lsa_mutex` 구간, 같은 trid COMMIT 바로 앞(인접+trid가 C3 reader의 키).
```c
log_Gl.prior_info.prior_lsa_mutex.lock ();
log_append_repl_info_with_lock (thread_p, tdes, true);
log_append_wset_label_with_lock (thread_p, tdes);        /* 신규 — C2 */
log_append_commit_log_with_lock (thread_p, tdes, commit_lsa);
log_Gl.prior_info.prior_lsa_mutex.unlock ();
```
**신규 static** `log_append_wset_label_with_lock`(PoC:log_manager.c:4724): `prior_lsa_alloc_and_copy_data(thread_p, LOG_DUMMY_WSET_LABEL, RV_NOT_DEFINED, NULL,0,NULL,0,NULL)`로 prior 노드 alloc → `node->data_header`에 `dependency_seq=tdes->wset_dependency_seq`, `dependency_is_read=tdes->wset_dependency_is_read` 복사 → `prior_lsa_next_record_with_lock`. POD tdes 필드+항상가능 prior API만 → **SERVER/SA 가드 불필요**(server+SA 빌드에서 컴파일).

**레코드 정의**(log_record.hpp): enum `LOG_DUMMY_WSET_LABEL = 53,`(`LOG_LARGER_LOGREC_TYPE` 앞). `struct log_rec_ws_label { LOG_LSA dependency_seq; bool dependency_is_read; };`(PoC:258). ★코드 필드명은 **`dependency_is_read` 유지**(writeset-design CLAUDE.md: 코드=read, 문서/그림만 ref). C3가 `la_retrieve_ws_label`로 디코드.

**신규 로그레코드 보일러플레이트**(`LOG_DUMMY_HA_SERVER_STATE`를 모든 등장지점에서 미러 — 헤더전용 dummy, 고정 data_header, undo/redo 없음, 복구 skip):
- log_append.cpp: 두 switch — zero-data `break` 그룹(@358)과 `data_header_length` 그룹(@1265) → `case LOG_DUMMY_WSET_LABEL: assert(length==0 && data==NULL); node->data_header_length = sizeof(LOG_REC_WSET_LABEL); break;`.
- log_manager.c: `log_to_string`(@495) → "LOG_DUMMY_WSET_LABEL"; `log_dump_record`(@7104) → `log_dump_record_ws_label` 덤퍼; scan/undo switch @8034/@8466/@10929 → HA_SERVER_STATE 옆에 케이스.
- log_recovery.c: @2510/@3985/@4927 케이스 + read-advance @5911/@5943 → `LOG_DUMMY_WSET_LABEL`, HA_SERVER_STATE가 자기 레코드크기만큼 전진하는 곳에서 `sizeof(LOG_REC_WSET_LABEL)` 전진. (마스터 크래시복구 정합성 — 레코드는 skip 가능해야, redo/undo엔 no-op.)

## 4. develop 적응
커밋경로(`log_commit_local`,`log_append_repl_info_and_commit_log`) PoC base와 동일 → 훅 그대로, 라인만 시프트. enum 꼬리 동일 → 53 클린. atomic-LSA C2 경로 밖(§0). locator_sr.c 앵커 전부 develop에 존재, 함수 재작성 없음.

## 5. tdes 필드
- 읽기: C1의 `wset_overflow`(가드), `wset_dependency_is_read`(라벨로).
- ★**C2가 추가**: `wset_dependency_seq`(LOG_LSA) — C1이 미룸(03-c1 §2). 로컬 불가: probe가 prior_lsa_mutex 구간 전에 쓰고 `log_append_wset_label_with_lock`가 구간 안에서 읽음(commit-LSA 할당 사이로 분리). PoC명 `ws_dependency_seq`(log_impl.h:602) → `wset_dependency_seq`.
- init/reset: `LSA_SET_NULL(&tdes->wset_dependency_seq)`를 `logtb_initialize_tdes`·`logtb_clear_tdes` 둘 다(PoC 1619/1706). **commit·abort 둘 다** reset(중단/재사용 tdes가 stale 라벨 방출 방지).

## 6. C++ 스타일
C1과 동일: 가독성 우선, K&R, 평범한 이름, 자체완결 주석(S1/§ 내부참조 금지). PoC 주석은 이미 이 스타일 — TEST ONLY/perf만 빼고 이식. probe/flush의 `#if SERVER_MODE||SA_MODE` 가드 유지. RAII·템플릿 없음.

## 7. 리스크 / 열린 질문 (플래그, 사용자 부재)
1. **2PC/분산트랜잭션 경로가 stale/NULL 의존 WSET_LABEL 방출.** `log_append_wset_label_with_lock`는 local 분기(probe됨)와 2PC 호출자(@6053) 둘 다서 발사되나 probe/flush는 local만 배선. 글로벌 tx는 `dependency_seq=NULL`(init값) → C3가 독립으로 취급 → 즉시 dispatch. **PoC 동작 그대로**(PoC도 local만). ★**플랜 기본값=PoC 미러(local만 배선, 2PC는 NULL/독립 라벨)**. HA+분산 tx는 드문 조합, 나중 사용자 확인. 안전 필요시 2PC 분기도 probe/flush 하거나 라벨 억제+C3 "WSET_LABEL 없음" 드레인 폴백.
2. **DELETE FK REF는 OLD recdes 사용**(#3/#5가 touched 행 recdes 전달) — 맞음(삭제 시 삭제된 자식이 가리킨 부모 뒤로 정렬). develop delete 경로가 pre-image recdes 넘기는지 실행자 확인. 저위험.
3. **복합(MIDXKEY) 부모키·NULL FK는 조용히 skip**(C1 add_ref_dbvalue) → 보수적 정렬 폴백. 문서화됨, 수용. C2 조치 없음.
4. **same_key/엣지 이중카운트**(#6 vs #7 상호배타; #4 old+new): PoC 가드 정확 이식 — 틀리면 과직렬화(무해) 또는 과소수집(무성 divergence). per-tx overflow 캡이 과수집을 안전하게 만듦 → 애매하면 수집.
5. 실행자는 C2 작성 전 C1 tdes 필드가 `wset_*`(PoC `ws_*` 아님)인지 확인.

**PoC 참조**: locator_sr.c:7807/8046/8187/8732/8938/9000, log_manager.c:5301/5310/4724/4708, log_record.hpp:140/258, log_append.cpp:341/1252, log_tran_table.c:1619/1706.

## 8. SBR(suppress_replication)과 수집 훅의 상관관계 (2026-09-26 분석)

행 복제(RBR)를 억제하는 장치가 **둘** 있고, 수집 훅과의 관계가 다르다.

| 억제 장치 | 대상 | 수집 훅이 인지하나 |
|---|---|---|
| `datayn=false` (+need_replication=false) | DDL의 카탈로그 행 부수효과 (catalog_class.c:3950/4042) | ✅ 가드가 datayn·need_replication 검사 |
| **`tdes->suppress_replication`** | **SBR 문장의 행 변경 전체** (DDL + `USE_SBR` 힌트 INSERT/DELETE/UPDATE — 사용자 테이블 행 포함) | ❌ **검사 없음 — 구멍** |

### SBR 문장 하나의 콜트리 (클라이언트 → 서버)

```
[클라이언트 do_execute_statement (execute_statement.c)]
① is_stmt_based_repl_type(stmt) == true
   db_set_suppress_repl_on_transaction(true)
   → 서버 tdes->suppress_replication = 1

② 문장 실행(행 변경) + locator_all_flush()
   → 서버 xlocator_force
     → locator_insert/delete_force
       → locator_add_or_remove_index_internal
          (datayn=true, need_replication=true — 호출자는 SBR인지 모름)
          인덱스 루프 i마다:
          ├ 수집 훅(UNIQUE→add_dbvalue, FK→collect_fk_ref)
          │   ★suppress 검사 없음 → 키 수집됨
          └ PK: repl_log_insert(...)
              → 내부에서 suppress 검사 → RBR 레코드 억제,
                단 NO_ERROR 반환
              → 훅의 error_code==NO_ERROR && datayn 가드 통과
                ★PK 키도 수집됨 (레코드는 안 나갔는데)

③ locator_all_flush() → suppress 해제
   → tdes->suppress_replication = 0   (execute_statement.c:4536)

④ do_replicate_statement (4541) → repl_set_info
   → 서버 xrepl_set_info (locator_sr.c:11867)
   → repl_log_insert_statement (replication.c)
      → suppress=0이라 통과 → SBR 레코드(문장 텍스트) 큐잉
        + wset_overflow = true   ← C2의 statement 격하

⑤ 커밋: log_commit_local
   → probe: overflow → commit-order 라벨
   → WSET_LABEL + COMMIT 기록
   → flush: overflow 경로 → history clear + floor 상향
```

### 현재 구조의 평가
- **비대칭**: `repl_log_insert`와 수집 훅은 같은 함수의 같은 인덱스 루프에 나란히 있는데, 전자만 suppress를 검사한다. suppress 창(②)에서 "레코드는 억제됐는데 키는 수집되는" 상태가 생겨 **"수집된 키 == 복제되는 행" 불변식이 깨진다**.
- **발산이 없는 이유**: ④의 격하(`wset_overflow=true`)가 ②의 오수집 키를 통째로 무효화한다(⑤에서 commit-order 직렬화). 문장이 실패한 경우도 행은 롤백되고 남은 키는 과직렬 방향의 가짜 의존뿐이다. 즉 정합성은 "④가 반드시 ② 뒤에 온다"는 **순서 의존**으로 유지된다.
- **수정 반영됨(2026-09-26)**: replication.c와 대칭으로 **수집 경로의 wset_overflow 가드 4곳(push_hash·push·add_dbvalue·add_ref_dbvalue)과 `collect_fk_ref`의 tdes 가드에 `tdes->suppress_replication != 0` 조건 추가** — suppress 창에서는 수집 자체를 생략한다(push_hash의 가드에 이유 주석). probe/flush의 wset_overflow 검사는 수집이 아니므로 건드리지 않았다. 효과 = "수집된 키 == 복제되는 행" 불변식 복원, suppress 창 수집 메모리 제거, 격하 순서 의존 제거.

### 8.1 datayn의 의미와 호출자

`datayn`은 `locator_add_or_remove_index_internal`의 파라미터로, **"이 행 변경을 행 기반(RBR) 복제 레코드로 내보낼 것인가"** 를 뜻한다. 호출자가 정해서 넘긴다.

| 호출자 | datayn | need_replication | 의미 |
|---|---|---|---|
| 일반 사용자 DML (locator force 경로) | true | true | RBR로 복제 — 수집 대상 |
| 카탈로그 내부 갱신 (catalog_class.c:3950/4042) | false | false | 복제 대상 아님(문장 복제가 커버) |
| (존재하지 않는 조합) | false | true | 도달 불가 — 아래 8.2의 방어 대상 |

이 값으로 갈리는 곳 둘: ① 기존 코드의 `repl_log_insert(..., datayn ? LOG_REPLICATION_DATA : LOG_REPLICATION_STATEMENT, ...)` 레코드 타입 선택, ② 우리 수집 가드(`datayn && need_replication && ...`). writeset은 슬레이브의 **행 단위 적용** 순서를 보장하는 장치이므로 RBR일 때만 수집이 의미 있고, 수집이 datayn에 묶이는 것이 맞다.

★단 8절의 결론대로, SBR 문장의 사용자 테이블 행 변경은 datayn=true로 들어오고 `suppress_replication`으로만 구분된다. **datayn은 "카탈로그 부수효과" 구분자이고, "SBR 문장의 행 변경" 구분자는 suppress_replication이다.** 두 장치를 혼동하지 말 것.

### 8.2 locator의 `!datayn` STATEMENT 분기 (C2의 B 방어선)의 정체

PK 복제 블록의 `repl_log_insert`가 `!datayn`일 때 `LOG_REPLICATION_STATEMENT` 타입으로 호출되는데, 이때 replication.c의 else 분기는:

```c
repl_rec->repl_type = LOG_REPLICATION_STATEMENT;
repl_rec->rcvindex  = RVREPL_DATA_INSERT/DELETE;   /* 데이터용 rcvindex */
repl_rec->repl_data = NULL;  repl_rec->length = 0; /* 페이로드 없음 */
```

즉 **문장 텍스트도 행 이미지도 없는 퇴화된 레코드**다. 정상 SBR 레코드(REPL_INFO_SBR: 문장 텍스트+유저+시스템파라미터)는 `repl_log_insert_statement`가 만들며, 그 함수의 호출자는 엔진 전체에서 `xrepl_set_info`(locator_sr.c:11867) **한 곳뿐**이다. 따라서:
- 이 `!datayn` 분기는 **SBR 경로가 아니라** repl_log_insert의 레거시 파라미터화 잔재이고, **도달 불가가 정적으로 증명된다**: `_internal`은 static이고 진입로는 래퍼 2개(`locator_add_or_remove_index`/`_for_moving`)뿐이며, 그 호출자는 repo 전체 6곳이 전부인데 인자가 모두 리터럴이다 — catalog_class.c:3950/4042=(datayn F, need_repl F), locator_sr.c:5185/6003/6353/6359=(T, T). 분기의 필요조건 (need_repl T ∧ datayn F) 조합은 0곳. 덤: F/F 두 곳은 PK 복제 블록 진입 자체가 안 되므로 오늘날 repl_log_insert가 STATEMENT 타입으로 호출되는 일 자체가 없다. ★실제 SBR 문장도 이 분기를 안 탄다(인덱스 처리 시 datayn=true+suppress로 들어오므로) — SBR 격하는 오직 repl_log_insert_statement에서.
- C2가 여기 넣은 격하(`wset_overflow=true`)는 **순수 방어선**: 미래에 이 조합이 열리면 해시로 표현 못 하는 statement 타입 레코드가 나가므로 같은 규칙으로 격하한다.
- (미결) 이 분기 주석이 "여기가 SBR 처리 지점"으로 오독될 수 있어 "Unreachable today: statement replication goes through repl_log_insert_statement (which already demotes)..." 식 명확화가 제안돼 있다.

### 8.3 DDL의 두 갈래와 카탈로그 행

DDL 한 문장은 복제 관점에서 두 갈래로 처리된다:

```
CREATE TABLE ... (DDL)
├ [복제] 클라이언트 pt_is_ddl_statement → do_replicate_statement
│        → repl_log_insert_statement (SBR 레코드) + wset_overflow=true
└ [부수효과] 서버가 시스템 카탈로그 행(_db_class 등)을 삽입/삭제
         → catalog_class.c → locator_add_or_remove_index(datayn=false, need_replication=false)
         → RBR 레코드도, 키 수집도 없음
```

카탈로그 행을 RBR로 보내지 않는 이유: **슬레이브는 SBR로 받은 DDL 문장을 재실행하면서 자기 카탈로그 행을 스스로 재생성**하므로, 행까지 보내면 이중 적용이 된다. 같은 이유로 카탈로그 행의 writeset 키도 수집하지 않는 것이 맞다 — DDL 트랜잭션은 SBR 격하로 통째로 commit-order 직렬화되므로 카탈로그 행 충돌에 해시가 필요 없다.

`is_stmt_based_repl_type`의 범위 = **모든 DDL + `USE_SBR` 힌트가 붙은 INSERT/DELETE/UPDATE** (execute_statement.c). 후자 때문에 suppress 창에서 사용자 테이블 행이 변경될 수 있다는 점이 8절 분석의 출발점이다.
