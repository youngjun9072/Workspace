---
tags: [writeset, design, cubrid, master]
date: 2026-08-15
status: 설계 검토본
baseline:
  develop: 23789cbfa78087a9edaae126b605495525b4d40d
---

# 8-1. CUBRID 마스터 writeset 상세 설계

이 장은 [6-1장](./6-1-cubrid-마스터-writeset-설계.md)의 마스터 개념을 CUBRID의 행 변경, 트랜잭션 descriptor와 COMMIT 경로에 대응시킨다. `develop` 경로에 writeset 수집, dependency 계산, WS_LABEL 기록과 history 게시를 추가해야 할 위치를 설명한다.

상세 충돌 규칙과 WS_LABEL 기록 형식은 [6-1장](./6-1-cubrid-마스터-writeset-설계.md)을 따른다. 슬레이브 구현 상세는 [8-2장](./8-2-cubrid-슬레이브-병렬-적용-상세-설계.md)으로 분리한다.

## 8-1.1 전체 변경 구조

`develop`의 마스터는 복제 변경 레코드와 COMMIT을 기록하지만 슬레이브 병렬 적용을 위한 충돌 키와 dependency를 만들지 않는다. 병렬 적용을 위해 다음 세 경계를 추가해야 한다.

1. 행 변경 경로에서 PK·UNIQUE·FK 충돌 키를 WRITE·REF entry로 수집해야 한다.
2. COMMIT 직전에 전역 history를 조회해 선행 dependency를 확정하고 WS_LABEL에 기록해야 한다.
3. 정상 COMMIT LSA가 확정된 뒤 이를 history에 게시하고 row lock을 해제해야 한다.

트랜잭션 로컬 writeset은 `LOG_TDES`, 트랜잭션 사이의 이력은 전역 history가 소유해야 한다. 다음 절부터 두 상태의 생성·소비·정리 위치를 실제 함수 흐름에 대응시킨다.

## 8-1.2 마스터 변경

### 8-1.2.1 writeset 상태의 소유·초기화·정리

마스터는 트랜잭션별 writeset과 전역 history의 소유자를 구분하고, 서버 기동·트랜잭션 종료·서버 종료에 맞춰 각 상태를 초기화하고 정리해야 한다.

writeset 상태는 수명이 다른 두 영역으로 나눠야 한다. 현재 트랜잭션의 writeset은 `LOG_TDES`가 소유해야 하고, 커밋된 트랜잭션 사이의 키별 이력은 마스터 전역 history가 소유해야 한다.

#### 두 상태의 자료구조

기존 트랜잭션 descriptor인 `LOG_TDES`에는 현재 트랜잭션만 사용하는 필드를 추가해야 한다.

```c
struct log_writeset_entry
{
  LOG_WRITESET_HASH hash;
  LOG_WRITESET_KIND kind;  /* WRITE 또는 REF */
};

/* LOG_TDES에 추가하는 트랜잭션별 상태 */
std::vector<LOG_WRITESET_ENTRY> ws_hashes;
bool ws_overflow;
LOG_LSA ws_dependency_seq;
bool ws_dependency_is_read;
```

`ws_hashes`와 `ws_overflow`는 행 처리 중 갱신해야 한다. `ws_dependency_seq`와 `ws_dependency_is_read`는 COMMIT 직전에 history를 조회한 결과를 저장해야 한다. 트랜잭션이 commit 또는 abort로 종료되면 네 필드를 비워 descriptor를 재사용해야 한다.

- `ws_hashes`: 행 연산에서 수집한 `{hash, WRITE|REF}` 항목 목록
- `ws_overflow`: 완전한 writeset을 사용할 수 없어 commit-order 폴백이 필요한 상태
- `ws_dependency_seq`: COMMIT 직전에 선택한 선행 COMMIT LSA
- `ws_dependency_is_read`: 최종 dependency가 `read_seq`에서 선택됐는지 나타내는 플래그

트랜잭션 사이에서 공유하는 이력은 별도의 서버 전역 구조로 둬야 한다.

```c
struct log_writeset_slots
{
  LOG_LSA write_seq;
  LOG_LSA read_seq;
};

typedef struct log_writeset_history LOG_WRITESET_HISTORY;

struct log_writeset_history
{
  std::unordered_map<LOG_WRITESET_HASH, LOG_WRITESET_SLOTS> map;
  LOG_LSA history_start;
  pthread_mutex_t latch;
};

LOG_WRITESET_HISTORY log_Writeset_history;
LOG_LSA log_Writeset_prev_commit_lsa;
```

- `map`: 충돌 키 해시별 WRITE·REF 슬롯과 각 COMMIT LSA
- `history_start`: map을 비운 뒤 사라진 이력을 대신하는 보수적 하한
- `latch`: history 조회·게시와 초기화를 보호하는 mutex
- `log_Writeset_prev_commit_lsa`: 최근 history 게시 COMMIT LSA이며 commit-order 폴백의 기준이다. `LOG_WRITESET_HISTORY`의 필드는 아니지만 같은 latch로 보호하는 동반 전역 상태다.

`LOG_WRITESET_ENTRY`는 현재 트랜잭션의 `LOG_TDES.ws_hashes`에 보관해야 한다. `LOG_WRITESET_SLOTS`는 전역 `history[hash]`의 값이며, `write_seq`와 `read_seq`에는 정수 순번이 아니라 해당 트랜잭션의 COMMIT LSA를 저장해야 한다.

`LOG_TDES`의 필드는 트랜잭션 수명 동안만 유지해야 하고, 전역 history는 transaction table이 운영되는 동안 유지해야 한다. 서버가 종료되면 전역 history를 정리해야 하고, 재시작 시 이전 map을 복원하지 않고 다시 초기화해야 한다.

#### 상태 생명주기 요약

두 상태는 초기화 시점과 유지 범위를 다르게 두어야 한다. `LOG_TDES`의 writeset은 개별 트랜잭션에 묶여 정리되어야 하고, 전역 history는 transaction table이 살아 있는 동안 유지되어야 한다.

```text
트랜잭션별 writeset
descriptor 초기화
→ 행 연산 중 WRITE·REF 항목 수집
→ commit 직전: 전역 history 조회·dependency 저장
→ commit: 본인 COMMIT LSA로 history 게시 후 정리
  abort: 게시 없이 정리
→ descriptor 재사용
```

```text
전역 writeset history
서버 기동 시 초기화
→ 트랜잭션 COMMIT마다 조회·게시
→ map 포화 시 clear·history_start 갱신
→ 서버 종료 시 해제
```

다음 절부터는 이 요약의 각 단계를 실제 초기화·정리 함수와 호출 순서에 맞춰 상세히 설명한다.

#### 초기화 함수와 수행 내용

![8-1-master-init-asis-tobe](./figures/8-1-master-init-asis-tobe.svg)

*호출 관계 8-1-1. 서버 기동 시 기존 transaction descriptor 초기화 경로에 트랜잭션별 writeset 상태와 전역 history 초기화를 추가한 구조*

<details>
<summary>호출 관계 원문</summary>

```text
AS-IS

boot_restart_server()
└─ logtb_define_trantable()
   └─ logtb_define_trantable_log_latch()
      └─ logtb_expand_trantable()
         └─ logtb_allocate_tdes_area()
            └─ logtb_initialize_tdes()
               └─ 기존 LOG_TDES 상태 초기화
```

```text
TO-BE

boot_restart_server()
└─ logtb_define_trantable()
   └─ logtb_define_trantable_log_latch()
      ├─ logtb_expand_trantable()
      │  └─ logtb_allocate_tdes_area()
      │     └─ logtb_initialize_tdes()
      │        └─ log_writeset_tdes_initialize(tdes)       # 설계상 추가
      └─ log_writeset_history_initialize()     # 추가
```

</details>

`LOG_TDES` 쪽은 기존 `logtb_initialize_tdes()`에서 트랜잭션별 writeset 초기화 함수를 호출해야 한다.

```text
logtb_initialize_tdes()
└─ log_writeset_tdes_initialize(tdes)
   ├─ ws_hashes 초기화
   ├─ ws_overflow 초기화
   ├─ ws_dependency_seq 초기화
   └─ ws_dependency_is_read 초기화
```

`log_writeset_tdes_initialize()`는 정식 설계에서 사용하는 개념적 함수명이다. 현재 구현에서는 이 초기화가 `logtb_initialize_tdes()` 내부 대입으로 처리된다.

전역 history 쪽은 새 `log_writeset_history_initialize()`가 map, 기준 LSA와 latch를 초기화해야 한다.

```c
/* log_writeset_history_initialize(): 서버 전역 상태 */
log_Writeset_history.map.clear ();
LSA_SET_NULL (&log_Writeset_history.history_start);
pthread_mutex_init (&log_Writeset_history.latch, NULL);
LSA_SET_NULL (&log_Writeset_prev_commit_lsa);
```

#### 정리 함수와 수행 내용

트랜잭션 종료 시 `logtb_clear_tdes()`가 `LOG_TDES`의 writeset 필드를 초기 상태로 되돌려야 한다. commit 경로는 history 게시를 먼저 수행해야 하고, abort 경로는 게시 없이 이 정리만 수행해야 한다.

```c
/* logtb_clear_tdes() 내부: 트랜잭션별 상태 정리 */
tdes->ws_hashes.clear ();
tdes->ws_overflow = false;
LSA_SET_NULL (&tdes->ws_dependency_seq);
tdes->ws_dependency_is_read = false;
```

서버 종료 시 `logtb_undefine_trantable()`이 `log_writeset_history_finalize()`를 호출해야 한다. finalize는 map과 기준 LSA를 비우고 latch를 해제해야 한다.

```text
logtb_undefine_trantable()                      [CHANGED]
└─ log_writeset_history_finalize()             ✓ NEW
```

```c
/* log_writeset_history_finalize(): 서버 전역 상태 정리 */
log_Writeset_history.map.clear ();
LSA_SET_NULL (&log_Writeset_history.history_start);
pthread_mutex_destroy (&log_Writeset_history.latch);
LSA_SET_NULL (&log_Writeset_prev_commit_lsa);
```

### 8-1.2.2 행 연산과 writeset 수집

행 연산의 writeset 수집은 별도 순회가 아니라 기존 인덱스 처리 함수 안에 추가해야 한다. INSERT·DELETE는 `locator_add_or_remove_index_internal()`, UPDATE는 `locator_update_index()`가 인덱스 키를 이미 추출한 위치에서 WRITE·REF 수집 함수를 동기 호출해야 한다. 이 단계에서는 전역 history를 조회하지 않고 현재 트랜잭션의 `LOG_TDES.ws_hashes`만 채워야 한다.

두 함수는 복제가 필요한 데이터 변경이고 로그 적용 스레드가 아니며 복제가 허용된 경우에만 writeset을 수집해야 한다. 인덱스 종류에 따른 실제 호출은 다음과 같이 구분해야 한다.

- `locator_add_or_remove_index_internal()`은 UNIQUE·REVERSE UNIQUE의 `key_dbvalue`를 `log_writeset_add_dbvalue()`에 넘겨 WRITE로 수집해야 한다. FOREIGN KEY이면 같은 행의 `recdes`를 `locator_writeset_collect_fk_ref()`에 넘겨 부모 키 REF를 수집해야 한다. PRIMARY KEY는 기존 `repl_log_insert()`가 성공한 뒤 같은 `key_dbvalue`를 WRITE로 수집해야 한다.
- `locator_update_index()`는 UNIQUE·REVERSE UNIQUE의 `old_key`를 WRITE로 수집하고, `same_key=false`이면 `new_key`도 WRITE로 수집해야 한다. FOREIGN KEY도 old 행의 REF를 수집하고, `same_key=false`이면 new 행의 REF를 추가해야 한다. PRIMARY KEY의 정상 순회 경로는 `old_key`와 `new_key`를 모두 WRITE로 수집해야 한다. 순회 안에서 PK를 확보하지 못해 뒤에서 `repl_old_key`를 다시 구하는 예외 경로는 현재 old PK만 수집하므로 별도 보강 대상으로 관리해야 한다.

![9-master-insert-delete-asis-tobe_v2](./figures/9-master-insert-delete-asis-tobe_v2.svg)

*그림 8-1-1. `locator_add_or_remove_index_internal()`의 인덱스 순회 — 기존 인덱스 처리와 복제 정보 생성을 유지하면서 ① UNIQUE·REVERSE UNIQUE 키와 자식 FK의 REF(`locator_writeset_collect_fk_ref()`)를, ② 같은 함수의 PK 블록에서 `repl_log_insert()` 성공 뒤 PK 키를 `log_writeset_add_dbvalue()`로 writeset에 추가하는 비교*

**붉은 영역의 코드 대응**

- **① 인덱스별 WRITE·REF 수집 추가**: 기존 `locator_add_or_remove_index_internal()`의 인덱스 순회에 UNIQUE·REVERSE UNIQUE의 `log_writeset_add_dbvalue()` 호출과, 자식 FK의 `locator_writeset_collect_fk_ref()` → `log_writeset_add_ref_dbvalue()` 호출을 추가한다. 수집은 이 행 변경이 복제 로그를 생성해야 하는 경우에만 한다.
- **② PK WRITE 수집 추가**: 같은 함수의 PK 인덱스 블록에서 기존 `repl_log_insert()`가 성공한 뒤에 `log_writeset_add_dbvalue()`를 호출해 PK를 현재 `LOG_TDES.ws_hashes`에 보관한다. 이 블록 자체가 복제 로그를 생성하는 경우에만 실행되고, 수집은 그 안에서 `repl_log_insert()` 성공을 확인한 뒤에만 한다.

INSERT와 DELETE는 같은 `locator_add_or_remove_index_internal()`을 사용한다. 이 함수의 `recdes`와 `key_dbvalue`는 INSERT이면 새 행, DELETE이면 기존 행에서 만들어지므로 별도의 연산별 수집 함수가 필요하지 않다. UNIQUE·REVERSE UNIQUE와 FK는 해당 인덱스의 B-tree 연산 전에 수집하고, PK만 복제 정보 생성이 성공한 뒤 수집해야 한다.

![9-master-update-asis-tobe_v2](./figures/9-master-update-asis-tobe_v2.svg)

*그림 8-1-2. `locator_update_index()` — UPDATE의 기존 old/new 인덱스 처리에서 UNIQUE·REVERSE UNIQUE와 PK는 WRITE, 자식 FK는 REF로 함께 수집하는 비교*

**붉은 영역의 코드 대응**

- **① old/new WRITE·REF 수집 추가**: 기존 `locator_update_index()`의 인덱스 순회에서 `log_writeset_add_dbvalue()`와 `locator_writeset_collect_fk_ref()`를 동기 호출한다. INSERT·DELETE와 같이 이 변경이 복제 로그를 생성해야 하는 경우에만 수집한다.
- **② PK WRITE 수집 추가**: PK 인덱스 위치(`pk_btid_index`)는 복제 로그를 생성하는 경우에만 정해지므로, 아래 두 경로 모두 그 조건 안에 있다. 정상 경로에서는 순회 중 PK 인덱스를 처음 만날 때 old/new PK를 `log_writeset_add_dbvalue()`로 수집한다. `repl_old_key`를 순회 뒤 다시 구하는 기존 예외 경로는 `repl_log_insert()` 호출 뒤 old PK만 수집하며, 이때 반환값을 확인하지 않는다(INSERT·DELETE 경로는 확인한다). 정식 구현에서는 예외 경로도 성공 조건을 확인해야 한다.

UPDATE는 인덱스별로 `old_key`와 `new_key`를 만든 뒤 `btree_compare_key()`의 결과로 `same_key`를 정한다. UNIQUE·REVERSE UNIQUE와 FK는 old 값을 항상 수집하고, 값이 달라진 경우에만 new 값을 추가해야 한다. PK 정상 경로는 동일 여부와 관계없이 old/new를 모두 수집해 이전 행 식별자와 새로운 행 식별자를 보존해야 한다.

`repl_old_key`를 인덱스 순회 뒤 다시 구하는 PK 예외 경로에서는 `repl_log_insert()` 뒤 old PK만 수집한다. 이 경로는 new PK를 더 이상 보유하지 않고 수집 함수의 반환값도 확인하지 않으므로, 정식 구현에서는 정상 PK 경로와 같은 old/new 수집 및 오류 전달이 가능한 위치로 조정해야 한다. 두 행 처리 함수에서 모은 항목은 commit 또는 abort까지 현재 트랜잭션의 `LOG_TDES.ws_hashes`가 보유해야 한다.

#### FK REF 수집

INSERT·DELETE와 UPDATE의 인덱스 처리 경로는 자식 FK마다 `locator_writeset_collect_fk_ref()`를 호출해야 한다. 이 함수는 단일·복합 FK와 NULL 판정을 포함한 REF 수집 전체를 맡고, 완성한 부모 키를 공통 해시 함수로 전달해야 한다.

```text
locator_add_or_remove_index_internal() 또는 locator_update_index()
└─ locator_writeset_collect_fk_ref()
   ├─ 부모 PK index와 domain 조회
   ├─ 자식 FK 컬럼을 FK 선언 순서로 추출
   ├─ NULL 포함 여부 판정
   │  └─ NULL 있음: 부모 REF를 만들지 않고 NO_ERROR 반환
   ├─ 단일 FK: 부모 PK domain에 맞춰 값 변환
   ├─ 복합 FK: 부모 PK의 컬럼 순서·각 domain에 맞춰 MIDXKEY 구성
   └─ log_writeset_add_ref_dbvalue()
      ├─ 부모 PK WRITE와 같은 충돌 식별자 생성
      └─ log_writeset_push_hash(..., REF)
```

단일 FK는 `DB_IS_NULL()`, 복합 FK는 `btree_multicol_key_has_null()`과 같은 기존 FK 검사 기준으로 NULL을 판정해야 한다. NULL이 포함된 FK에는 참조 대상 부모 행이 없으므로 부모 REF를 만들지 않아야 한다. 이는 정상 경로이므로 `ws_overflow`나 commit-order 폴백을 설정하지 않고, 자식 행의 PK·UNIQUE WRITE 수집과 복제 변경 처리는 계속 진행해야 한다.

복합 FK는 자식 컬럼 전체를 부모 PK의 컬럼 순서와 각 컬럼 domain에 맞춰 하나의 MIDXKEY로 구성해야 한다. REF의 충돌 식별자는 `부모 class_oid + 부모 PK index VFID + 정규화한 부모 키 전체 값`으로 만들고, 부모 PK WRITE에도 같은 형식을 적용해야 한다. 이를 위해 `locator_writeset_collect_fk_ref()`가 가진 `index->fk->ref_class_pk_btid`의 VFID를 REF 해시 함수까지 전달해야 한다.

`locator_writeset_collect_fk_ref()`는 처리 결과를 `int`로 반환해야 한다. 부모 domain 조회, 키 추출, 형 변환, MIDXKEY 구성 또는 packing에 실패하면 INSERT·DELETE의 `locator_add_or_remove_index_internal()`과 UPDATE의 `locator_update_index()`까지 오류를 전달하여 트랜잭션을 중단해야 한다. NULL FK만 `NO_ERROR`로 정상 반환해야 하며, 실제 처리 실패를 REF 누락으로 숨긴 채 불완전한 writeset을 커밋하면 안 된다.

WRITE와 REF의 충돌 식별자는 `대상 class_oid + 대상 index VFID + 정규화한 전체 키 값`으로 구성해야 한다. PK·UNIQUE·REVERSE UNIQUE WRITE에는 현재 인덱스의 VFID를 사용하고, 자식 FK REF에는 `ref_class_pk_btid.vfid`를 사용해야 한다. 부모 PK WRITE와 자식 FK REF가 같은 형식을 사용해야 같은 history 슬롯에서 만날 수 있다. drop/recreate·rebuild로 VFID가 바뀌면 기존 history를 무효화하고 보수적 하한을 세워야 한다.

UNIQUE·REVERSE UNIQUE의 NULL은 이번 설계에서 WRITE 충돌 키로 수집해야 한다. UPDATE는 old와 new를 각각 판정해 값의 해제와 점유를 모두 남겨야 한다. 반면 NULL FK에는 참조 대상 부모 행이 없으므로 해당 REF만 만들지 않아야 한다. 구조체와 packed 표현을 포함한 코드 근거는 [[10-코드-및-실측-부록#10.6 CUBRID 마스터 writeset 코드 근거|부록 10.6]]에서 확인한다.

#### 트랜잭션별 writeset 수집과 용량 판정

WRITE와 REF는 종류와 관계없이 마지막에 `log_writeset_push_hash()`를 거쳐 `LOG_TDES.ws_hashes`에 들어간다. 이 공통 지점에서 트랜잭션별 용량을 검사한다.

![[figures/8-1-writeset-collection-overflow.svg]]

*그림 8-1-3. INSERT·DELETE와 UPDATE에서 수집한 WRITE·REF가 `log_writeset_push_hash()`로 합류하고, 이 공통 종단에서 트랜잭션별 용량을 판정하는 구조*

<details>
<summary>호출 관계 원문</summary>

**WRITE·REF 수집 경로**
```text
INSERT·DELETE
└─ locator_add_or_remove_index_internal()
   ├─ UNIQUE·REVERSE UNIQUE
   │  └─ key_dbvalue → log_writeset_add_dbvalue(..., WRITE)
   ├─ FOREIGN KEY
   │  └─ recdes → locator_writeset_collect_fk_ref()
   │              └─ log_writeset_add_ref_dbvalue(..., REF)
   └─ PRIMARY KEY
      └─ repl_log_insert() 성공
         └─ key_dbvalue → log_writeset_add_dbvalue(..., WRITE)

UPDATE
└─ locator_update_index()
   ├─ UNIQUE·REVERSE UNIQUE
   │  ├─ old_key → log_writeset_add_dbvalue(..., WRITE)
   │  └─ !same_key: new_key도 WRITE로 추가
   ├─ FOREIGN KEY
   │  ├─ old 행 → locator_writeset_collect_fk_ref(..., REF)
   │  └─ !same_key: new 행의 REF도 추가
   └─ PRIMARY KEY
      ├─ 정상 경로: old_key와 new_key를 WRITE로 추가
      └─ 예외 경로: repl_old_key만 WRITE로 추가
```

**공통 종단과 용량 처리**
```text
log_writeset_add_dbvalue() 또는 log_writeset_add_ref_dbvalue()
└─ *_internal()에서 값 정규화
   ├─ 일반 값: packing → log_writeset_push()
   │                    └─ log_writeset_push_hash()
   └─ 문자열: hash ──────────┘
         ├─ size < LOG_WRITESET_TX_LIMIT
         │  └─ LOG_TDES.ws_hashes에 추가
         └─ 한도 도달
            ├─ LOG_TDES.ws_hashes 전체 제거
            └─ LOG_TDES.ws_overflow = true
```

</details>

`log_writeset_add_dbvalue()`와 `log_writeset_add_ref_dbvalue()`는 각자 `_internal()`에서 값을 정규화·packing한 뒤 `log_writeset_push()`를 거쳐 `log_writeset_push_hash()`에 도달해야 한다. 문자열형처럼 해시가 이미 만들어진 경로는 `log_writeset_push_hash()`를 바로 호출해야 한다. 한도 검사는 이 공통 종단 한 곳에서 수행하여 WRITE와 REF가 같은 트랜잭션별 한도를 사용하게 해야 한다.

```text
log_writeset_push_hash(tdes, class_oid, hash, kind):
    if tdes 또는 class_oid가 유효하지 않음:
        return

    if tdes.ws_overflow == true:
        return                         # 이미 폐기한 트랜잭션은 추가 수집하지 않음

    if tdes.ws_hashes.size < LOG_WRITESET_TX_LIMIT:
        tdes.ws_hashes.push({hash, kind})
        return                         # WRITE·REF 항목을 정상 보관

    tdes.ws_overflow = true
    tdes.ws_hashes.clear()
    tdes.ws_hashes.shrink_to_fit()
    return                             # 불완전한 부분 writeset을 남기지 않음
```

- **한도 이내**: `{hash, kind}`를 현재 트랜잭션의 `LOG_TDES.ws_hashes`에 추가해야 한다. `kind`에는 WRITE 또는 REF가 들어가며, 이후 COMMIT의 dependency 계산에서 같은 목록을 사용해야 한다.
- **한도 도달**: `ws_overflow=true`로 전환하고 지금까지 모은 `ws_hashes` 전체를 제거해야 한다. 부분 writeset을 남기면 누락된 키를 충돌하지 않은 것으로 오판할 수 있기 때문이다.
- **overflow 전환 이후**: 같은 트랜잭션에서 WRITE·REF 수집 함수가 다시 호출되더라도 `ws_overflow`를 확인하고 항목을 더 추가하지 않아야 한다.

트랜잭션별 writeset 수집 공간이 한도에 도달하면 완전한 충돌 키 목록을 만들 수 없으므로 키별 병렬 판정을 계속하면 안 된다. 이 시점에는 `ws_overflow`를 설정하고 수집을 중단해야 한다. 실제 보수 처리는 COMMIT 단계에서 수행해야 한다. COMMIT 전 probe에서는 직전 COMMIT까지 기다리는 commit-order dependency를 만들고, COMMIT 성공 후 flush에서는 불완전한 키 이력을 제거하기 위해 전역 history를 비운 뒤 `history_start`를 본인 COMMIT LSA까지 올려야 한다. 상세 처리는 [[#dependency 계산|dependency 계산]]과 [[#COMMIT 성공 뒤 history 게시|COMMIT 성공 뒤 history 게시]]에서 설명한다.

#### statement replication

DDL 등 statement replication에는 해시할 행 키가 없다. 따라서 statement 복제 정보를 수집하는 시점에 `ws_overflow`를 설정해야 한다. COMMIT에서는 writeset 용량 초과와 같은 보수 경로를 사용해야 한다. probe는 commit-order dependency를 만들고, COMMIT 성공 뒤 flush는 전역 history를 비운 후 `history_start`를 올려야 한다.

![[figures/8-1-statement-replication-asis-tobe.svg]]

*그림 8-1-4. 기존 statement 복제 정보 수집 경로에 `ws_overflow` 설정을 추가하고, COMMIT에서 commit-order dependency와 이후 트랜잭션을 위한 history 기준을 만드는 구조*

<details>
<summary>호출 관계 원문</summary>

**AS-IS**
```text
xrepl_set_info()
└─ REPL_INFO_TYPE_SBR
   └─ repl_log_insert_statement()
      └─ LOG_REPLICATION_STATEMENT 정보 수집
```

**TO-BE**
```text
xrepl_set_info()
└─ REPL_INFO_TYPE_SBR
   └─ repl_log_insert_statement()               [CHANGED]
      ├─ LOG_TDES.ws_overflow = true            ✓ NEW
      └─ LOG_REPLICATION_STATEMENT 정보 수집
             ↓
log_commit_local()
├─ log_writeset_commit_probe()
│  └─ commit-order dependency 확정
└─ log_writeset_commit_flush()
   └─ history 제거·history_start 전진
```

</details>

`ws_overflow`는 writeset 용량 초과만 나타내는 값이 아니다. 행 단위 충돌 키로 표현할 수 없어 키별 판정을 사용하지 않는 트랜잭션도 같은 commit-order 폴백 상태로 표시해야 한다.

### 8-1.2.3 dependency 전달 로그와 COMMIT 기록

다음 절에서 설명할 COMMIT 로직은 계산한 dependency를 복제 로그에 기록한 뒤 COMMIT을 append해야 한다. 따라서 COMMIT 처리 순서를 설명하기에 앞서, dependency 정보를 슬레이브에 전달하기 위해 추가해야 하는 writeset 전용 로그 레코드와 배치 방식을 먼저 정의한다.

마스터는 전역 history에서 확정한 dependency 결과를 `LOG_DUMMY_WS_LABEL`에 기록해, 슬레이브가 충돌 키와 history를 다시 계산하지 않고 실행 순서를 판정할 수 있게 해야 한다.

dependency 전달에는 `LOG_DUMMY_WS_LABEL` 레코드를 사용하고 다음 payload를 기록해야 한다.

```c
typedef struct log_rec_ws_label LOG_REC_WS_LABEL;
struct log_rec_ws_label
{
  LOG_LSA dependency_seq;
  bool dependency_is_read;
};
```

*코드 8-1-1. 선행 COMMIT 위치와 슬레이브의 대기 판정 종류를 전달하는 WS_LABEL payload*

`dependency_seq`는 현재 트랜잭션이 기다려야 할 선행 COMMIT LSA다. `dependency_is_read=false`이면 슬레이브는 그 선행 트랜잭션의 개별 완료를 확인하고, `true`이면 해당 LSA까지 빈 구간 없이 완료된 frontier를 확인한다. 하나의 LSA와 bool로 여러 키의 후보를 축약하는 안전성은 8-1.2.4의 검증 항목으로 남긴다.

`log_append_repl_info_and_commit_log()`은 하나의 `prior_lsa_mutex` 구간에서 `log_append_repl_info_with_lock()` → `log_append_ws_label_with_lock()` → `log_append_commit_log_with_lock()` 순서로 호출해야 한다. WS_LABEL에는 COMMIT 직전 probe가 `LOG_TDES`에 저장한 `ws_dependency_seq`와 `ws_dependency_is_read`를 기록해야 한다.

![[figures/8-1-ws-label-log-layout.svg]]

*그림 8-1-5. 기존 REPL·COMMIT 기록 사이에 WS_LABEL을 추가하고, 세 레코드를 동일 `prior_lsa_mutex` 구간에서 연속 기록하는 비교*

<details>
<summary>호출 관계 원문</summary>

**AS-IS**
```text
log_append_repl_info_and_commit_log()
└─ prior_lsa_mutex 잠금
   ├─ log_append_repl_info_with_lock(tdes)
   ├─ log_append_commit_log_with_lock(tdes, commit_lsa)
   └─ prior_lsa_mutex 해제
```

**TO-BE**
```text
log_append_repl_info_and_commit_log()                 [CHANGED]
└─ prior_lsa_mutex 잠금
   ├─ log_append_repl_info_with_lock(tdes)
   ├─ log_append_ws_label_with_lock(tdes)             ✓ NEW
   │  └─ {ws_dependency_seq, ws_dependency_is_read} 기록
   ├─ log_append_commit_log_with_lock(tdes, commit_lsa)
   └─ prior_lsa_mutex 해제
```

</details>

> [!NOTE]
> **인접성 보장과 `trid` 확인**
> 위 mutex 구간은 다른 트랜잭션의 로그가 WS_LABEL과 COMMIT 사이에 들어오지 못하게 해야 한다. WS_LABEL은 공통 로그 레코드 헤더에 이미 `trid`를 가지므로 payload에 이를 중복 저장할 필요가 없다. 슬레이브 reader는 라벨의 `trid`를 보관했다가 동일한 `trid`의 COMMIT에만 연결해야 한다. 물리적 인접성은 라벨 유실을 막고, `trid` 확인은 다른 COMMIT으로의 오귀속을 막는다.

여기서는 의존성 라벨이 커밋 단위 안에서 배치되는 위치만 설명한다. 기록은 `log_append_ws_label_with_lock()`이 담당한다. 전달 형식은 [6-1장](./6-1-cubrid-마스터-writeset-설계.md#ws_label의-복제-로그-기록과-전달-규칙), 슬레이브 reader의 `la_retrieve_ws_label()` 소비 방식은 [8-2.3절](./8-2-cubrid-슬레이브-병렬-적용-상세-설계.md#8-23-reader의-로그-읽기와-task-구성)에서 설명한다. DUMMY 레코드는 system recovery에서 데이터 변경으로 redo·undo하지 않고 applylogdb가 순서 메타데이터로만 소비한다.

### 8-1.2.4 마스터 로컬 COMMIT의 dependency 계산과 history 게시

`LOG_TDES`는 transaction table이 관리하는 트랜잭션별 descriptor이며 전역 history와 구분된다. 행 처리에서 수집한 writeset은 `tdes->ws_hashes`에 보관되고, 계산한 dependency는 `tdes->ws_dependency_seq`와 `tdes->ws_dependency_is_read`에 저장된다.

`log_commit()`은 로컬 트랜잭션이면 `log_commit_local()`을 호출한다. `log_commit_local()`은 로그 적용 스레드가 아닌 일반 사용자 트랜잭션에서 복제가 허용된 경우, 먼저 `log_writeset_commit_probe()`로 dependency를 계산해야 한다. REPL·WS_LABEL·COMMIT의 기록 순서와 인접성은 앞의 [[#8-1.2.3 dependency 전달 로그와 COMMIT 기록|8-1.2.3절]]에서 설명했으므로 이 절에서는 반복하지 않는다.

`log_commit_local()`은 COMMIT 레코드에서 본인 LSA를 확정한 뒤 `log_writeset_commit_flush()`로 history를 게시한다. 그다음 row lock을 해제하고 `log_change_tran_as_completed()`로 트랜잭션 상태를 완료로 바꾼다. `logtb_clear_tdes()`는 이 커밋 임계 구간의 직접 호출이 아니며, 이후 descriptor 정리·재사용 단계에서 writeset 필드를 비운다.

![[figures/8-1-commit-local-asis-tobe.svg]]

*그림 8-1-6. 기존 `log_commit_local()`의 REPL·COMMIT 경로에 dependency probe, WS_LABEL 기록과 COMMIT LSA 기반 history 게시를 추가하는 전체 호출 흐름*

<details>
<summary>호출 관계 원문</summary>

**AS-IS**
```text
log_commit()
└─ log_commit_local()
   ├─ log_append_repl_info_and_commit_log()
   │  ├─ log_append_repl_info_with_lock()
   │  └─ log_append_commit_log_with_lock()
   ├─ lock_unlock_all()
   └─ log_change_tran_as_completed()
```

**TO-BE**
```text
log_commit()
└─ log_commit_local()                              [CHANGED]
   ├─ log_writeset_commit_probe()                  ✓ NEW
   ├─ log_append_repl_info_and_commit_log()        [CHANGED]
   │  ├─ log_append_repl_info_with_lock()
   │  ├─ log_append_ws_label_with_lock()           ✓ NEW
   │  └─ log_append_commit_log_with_lock()
   ├─ log_writeset_commit_flush()                  ✓ NEW
   ├─ lock_unlock_all()
   └─ log_change_tran_as_completed()
```

</details>

#### dependency 계산

다음 수도코드는 커밋 직전에 전역 history를 조회해 하나의 dependency 라벨을 만드는 계산을 설명한다. 알고리즘 1~3은 실제 함수 세 개가 아니라 `log_writeset_commit_probe()` 내부 로직을 나눈 것이다.

```text
log_writeset_commit_probe()
├─ writeset overflow
│  └─ [알고리즘 3] commit-order 폴백 라벨 확정
└─ 정상 writeset
   ├─ [알고리즘 1] 트랜잭션 전체에서 가장 늦은 선행 충돌 후보 선택
   │  └─ 각 entry마다 [알고리즘 2] 선행 충돌 후보 선택
   └─ [알고리즘 3] 최종 dependency 라벨 확정
```

**알고리즘 1 — 트랜잭션 전체 선행 후보 선택**

현재 트랜잭션의 각 충돌 키를 전역 history와 대조해, 현재 트랜잭션보다 먼저 완료돼야 할 과거 COMMIT LSA 중 가장 늦은 값을 선택한다.

```text
parent = {history_start, false}             # {lsa, from_read_seq}

for each entry in entries:
    candidate = select_entry_candidate(entry, history)  # 알고리즘 2
    if candidate.lsa is not NULL and candidate.lsa > parent.lsa:
        parent = candidate

return parent
```

**알고리즘 2 — entry 하나의 선행 후보 선택**

```text
select_entry_candidate(entry, history):
    slots = history.find(entry.hash)
    if slots does not exist:
        return {NULL, false}

    if entry.kind == REF:
        return {slots.write_seq, false}    # 현재 REF는 이전 WRITE만 기다림

    if slots.read_seq > slots.write_seq:
        return {slots.read_seq, true}      # 현재 WRITE는 이전 WRITE·REF 중 더 늦은 위치 선택

    return {slots.write_seq, false}
```

반환값의 boolean은 현재 entry가 REF인지를 뜻하지 않는다. 최종 후보가 `read_seq`에서 왔는지를 보존하여 슬레이브의 대기 방식을 결정하기 위한 값이다.

**알고리즘 3 — 폴백과 최종 라벨 확정**

```text
if tdes.ws_overflow:
    return {prev_commit, true}  # commit-order 폴백은 prev_commit까지 frontier 대기

parent = select_latest_transaction_candidate(entries, history, history_start)

if parent.from_read_seq:
    return {parent.lsa, true}
else:
    return {min(parent.lsa, prev_commit), false}
```

> [!WARNING]
> **다중 dependency 축약 규칙은 검증 중**
> 단일 `dependency_seq`와 종류 한 비트만으로 여러 독립 선행자를 표현하면, 더 작은 REF 후보와 더 큰 WRITE 후보가 함께 있을 때 앞선 REF 구간의 대기 조건이 사라질 수 있다. 최종 구현은 후보별 대기 방식을 보존하는 dependency 집합과 frontier를 사용하거나, 모든 dependency를 연속 완료 경계로 판정하는 안전한 단순화 중 하나를 선택해야 한다.

#### COMMIT 성공 뒤 history 게시

COMMIT LSA가 확정되면 `log_writeset_commit_flush()`가 현재 트랜잭션의 WRITE·REF 이력을 전역 history에 게시한다.

**알고리즘 4 — history 게시**

```text
log_writeset_commit_flush(tdes, my_commit_lsa):
    prev_commit_lsa = max(prev_commit_lsa, my_commit_lsa)

    if tdes.ws_overflow:
        history.clear()
        history_start = max(history_start, my_commit_lsa)
        return

    if history.size + tdes.ws_hashes.size > HISTORY_CAP:
        history.clear()
        history_start = my_commit_lsa

    for entry in tdes.ws_hashes:
        slots = history.get_or_create(entry.hash)

        if entry.kind == WRITE:
            slots.write_seq = my_commit_lsa
        else:  # REF
            slots.read_seq = max(slots.read_seq, my_commit_lsa)
```

`writeset_overflow`는 현재 트랜잭션의 writeset 용량 초과 또는 statement replication에 사용하는 폴백 상태다. 이 경우 게시할 키 목록이 없으므로 전역 history를 비우고 `history_start`를 본인 COMMIT LSA까지 단조 증가시켜야 한다. 반면 전역 history 용량 도달은 `history.size + entries.size`가 상한을 넘는지 게시 직전에 판정해야 한다. 두 경우 모두 map을 비우지만 발생 위치와 상태가 다르므로 로그 메시지와 통계를 구분해야 한다.

`log_writeset_commit_flush()`는 history 갱신까지만 수행해야 한다. row lock 해제는 이 함수가 반환된 뒤 `log_commit_local()`이 수행해야 하며, history 게시과 map 초기화는 정상 COMMIT LSA가 확정된 뒤 row lock을 해제하기 전에 끝나야 한다.

## 8-1.3 구현 위치와 보강 항목

### 8-1.3.1 미확정 및 보강 대상

- 여러 WRITE·REF 후보를 하나의 dependency와 종류로 축약하는 규칙의 정합성 검증이 진행 중이다.
- REF를 게시하지 않는다고 적힌 일부 주석은 실제 `read_seq` publish 코드와 다르다.
- 트랜잭션 writeset overflow와 전역 history map 포화를 서로 다른 상태와 로그로 구분해야 한다.
- UPDATE의 `repl_old_key` 재추출 예외 경로는 `repl_log_insert()` 반환값을 확인하지 않고 old PK를 수집한다. INSERT·DELETE 경로와 같이 성공 조건을 확인해야 한다.
- 동일한 `{hash, kind}`가 반복될 때 트랜잭션별 목록의 중복 제거 위치와 비용을 결정해야 한다.
- 다단계 cascade와 자기참조 FK를 포함한 우회 행 변경 경로에서도 WRITE·REF 수집이 빠지지 않는지 전수 검증해야 한다.

## 8-1.4 충돌 식별자의 코드 근거

### 8-1.4.1 현재 인덱스와 FK가 보유한 식별자

```c
struct or_foreign_key
{
  ...
  OID ref_class_oid;
  BTID ref_class_pk_btid;
  ...
};

struct or_index
{
  ...
  char *btname;
  ...
  BTID btid;
  ...
};
```

**코드 8-1-4 — 현재 인덱스와 자식 FK가 보유한 부모 클래스·부모 PK 식별자 (`object_representation_sr.h`)**

WRITE 수집 지점에서는 `index->btid.vfid`, REF 수집 지점에서는 `index->fk->ref_class_pk_btid.vfid`를 얻을 수 있다. 부모와 자식의 충돌 키를 같은 범위로 구성하면서 이름 변경의 영향을 피하기 위해 인덱스 이름이 아니라 VFID를 사용해야 한다.

### 8-1.4.2 인덱스 동일성 단위

```c
#define BTID_IS_EQUAL(b1,b2) \
  (((b1)->vfid.fileid == (b2)->vfid.fileid) && \
   ((b1)->vfid.volid == (b2)->vfid.volid))
```

**코드 8-1-5 — BTID를 VFID의 볼륨·파일 식별자로 비교하는 매크로 (`storage_common.h`)**

drop/recreate·rebuild로 VFID가 바뀌면 이전 충돌 이력과 새 인덱스 이력이 섞이지 않도록 history를 무효화하고 보수적 하한을 세워야 한다. 이름만 바꾸는 rename은 VFID 기반 충돌 식별자에 영향을 주지 않는다.

### 8-1.4.3 FK가 부모 PK 전체를 참조하는 근거

```c
pk = classobj_find_class_primary_key (ref_cls);
...
fk_info->ref_class_oid = *(ws_oid (ref_clsop));
fk_info->ref_class_pk_btid = pk->index_btid;

for (i = 0; pk->attributes[i]; i++)
  {
    ;
  }

if (i != n_atts)
  {
    ERROR2 (error, ER_FK_NOT_MATCH_KEY_COUNT,
            constraint_name, pk->name);
    goto err;
  }
```

**코드 8-1-6 — FK 컬럼 수와 부모 PK 컬럼 수가 다르면 정의를 거부하는 검사 (`schema_template.c`)**

CUBRID는 참조 대상 부모 PK와 그 BTID를 저장한다. 복합 부모 PK는 전체 컬럼을 같은 순서와 도메인으로 조립해야 한다.

### 8-1.4.4 해시 입력의 보완 지점

기존 해시 구성은 `class_oid + packed key`를 사용하며 인덱스 식별자를 입력으로 받지 않는다. 같은 클래스의 서로 다른 UNIQUE 인덱스가 같은 packed 표현을 만들면 불필요한 충돌이 생기므로 `index_btid.vfid`를 추가해야 한다.

```c
/* child FK REF */
parent_pk_domain =
  btree_read_key_type (thread_p, &index->fk->ref_class_pk_btid);
...
log_writeset_add_ref_dbvalue (
  thread_p, tdes, &index->fk->ref_class_oid,
  fk_key, parent_pk_domain);

/* PK·UNIQUE·REVERSE UNIQUE WRITE */
log_writeset_add_dbvalue (thread_p, ws_tdes,
                          class_oid, key_dbvalue);
```

**코드 8-1-7 — WRITE와 REF 수집 지점에서 인덱스 식별자를 추가로 전달할 수 있는 위치 (`locator_sr.c`)**

## 8-1.5 UNIQUE NULL 정책과 향후 최적화

이번 설계에서는 UNIQUE·REVERSE UNIQUE의 NULL도 WRITE 충돌 키로 해시해야 한다. 실제 NULL은 문자열 토큰이 아니라 NULL 여부가 포함된 `DB_VALUE` 또는 MIDXKEY의 packed 표현으로 구분해야 한다.

### 8-1.5.1 NULL의 packed 표현

```c
if (DB_VALUE_TYPE (value) == DB_TYPE_NULL)
  {
    domain = tp_domain_resolve_value (value, NULL);
    if (domain != NULL)
      {
        rc = or_put_domain (buf, domain, 1, 1);
      }
  }

...

if (is_null)
  {
    carrier |= OR_DOMAIN_NULL_FLAG;
  }
```

**코드 8-1-8 — packed domain에 실제 NULL 상태를 기록하는 경로 (`object_representation.c`)**

실제 NULL은 NULL flag가 켜진 domain 표현이고, 문자열 `'NULL'`은 VARCHAR domain과 문자 바이트를 가진 값이므로 서로 구분된다. 단일 NULL은 `packed(NULL DB_VALUE)`, 복합 키는 각 컬럼의 NULL 여부와 값을 포함한 전체 packed MIDXKEY를 해시한다.

자식 FK 값이 NULL이면 참조할 부모가 없으므로 REF를 수집하지 않는다.

```c
if (DB_IS_NULL (fk_value))
  {
    return NO_ERROR;
  }
```

**코드 8-1-9 — 자식 FK의 NULL을 REF 수집에서 제외하는 경로 (`log_writeset.c`)**

### 8-1.5.2 UPDATE old/new와 NULL

- `'X' → NULL`: old key `'X'`와 new `packed(NULL DB_VALUE)`를 모두 WRITE로 수집한다.
- `NULL → 'X'`: old `packed(NULL DB_VALUE)`와 new key `'X'`를 모두 WRITE로 수집한다.

old/new 중 한쪽만 수집하면 값의 해제 또는 점유가 history에서 사라질 수 있다. 특히 `'X' → NULL`에서 old key를 빠뜨리면 다른 트랜잭션이 `'X'`를 재사용할 때 필요한 선행 관계가 누락될 수 있다.

### 8-1.5.3 향후 최적화 대안

NULL을 UNIQUE writeset에서 제외하면 서로 다른 NULL 행의 불필요한 직렬화를 줄일 수 있다. 다만 UPDATE의 old/new 행을 독립적으로 판정하고, 복합 UNIQUE의 NULL 의미를 실제 B-tree 중복 판정과 일치시켜야 한다. 검증이 불완전한 상태에서 제외하면 false negative가 생길 수 있으므로 이번 설계에서는 NULL을 해시하는 보수 정책을 채택해야 한다.

후속 최적화에서는 다음을 검증해야 한다.

- 단일·복합 UNIQUE와 REVERSE UNIQUE에서 NULL 중복 허용 규칙
- 복합 키의 첫·중간·마지막 컬럼 및 전체 컬럼이 NULL인 경우
- `'X' → NULL`, `NULL → 'X'`, `NULL → NULL` UPDATE의 old/new 수집
- NULL 판별은 REF 제외 규칙과 일치하는지, key packing 실패는 호출자 오류로 전달되는지 여부
