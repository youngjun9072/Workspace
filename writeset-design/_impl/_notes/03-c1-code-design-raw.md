# C1 코드 설계 — 마스터 writeset 모듈 + 전역 history map

> 커밋 C1(마스터 writeset 모듈)의 **코드 레벨 설계**: 컴포넌트·인터페이스·동시성 프로토콜·C++ 스타일. PoC `writeset.c/.h`를 develop 위에 TBB로 이식하는 델타를 확정한다. 상위 계획은 [`01-commit-plan.md`](01-commit-plan.md), 라이브러리 결정은 [`02-develop-adaptation.md`](02-develop-adaptation.md).

> [!IMPORTANT] 2026-09-24 보정 — 해시 입력에 index VFID 추가 (구현 누락 발견)
> 이 문서는 PoC 충실 이식으로 작성돼 해시 입력이 `class_oid + packed key`였으나, 정식 설계(8-1 §해시/8-1.4.4)는 **`class_oid + index VFID + packed key`** 를 요구한다(같은 클래스의 서로 다른 인덱스가 같은 packed 표현을 만들 때 구분; 인덱스명이 아닌 VFID = rename 불변). WRITE는 현재 인덱스의 `index->btid.vfid`, 자식 FK REF는 **부모 PK의 `index->fk->ref_class_pk_btid.vfid`** (부모 WRITE와 같은 슬롯에서 만나기 위해). `wset_fnv1a(class_oid, index_vfid, packed, len)` + string_hash에도 동일 적용, add_* 시그니처에 VFID 전달. 같은 보정에서 **statement 복제(DDL) 시 `wset_overflow=true` 세팅**(PoC replication.c:540)도 C2 누락으로 확인되어 이식.

## 환경 확정 사실 (검증됨)
- 브랜치 `feature/CBRD-26482-parallel-applylogdb-writeset` @ `c63a3b993`, **C++17**.
- TBB = **oneTBB**(`3rdparty/.../include/oneapi/tbb/`). in-tree include 형태 `#include "tbb/concurrent_queue.h"`(따옴표+`tbb/` 접두, `src/connection/connection_worker.hpp:39` 선례).
- `concurrent_hash_map`의 기본 `HashCompare = tbb_hash_compare<Key>` 존재 → **UINT64 키에 explicit HashCompare 불필요**(이미 FNV 해시라 추가 정수 믹싱은 무해).
- TBB는 `cubrid`(server, `cubrid/CMakeLists.txt:740-743`)·`cubridsa`(SA, `sa/CMakeLists.txt:796-799`) 둘 다 링크됨. 모듈은 `TRANSACTION_SOURCES`(양 타깃에 공급)에 등록 → **C1에서 CMake 링크 작업 없음**. CS는 C1에서 미접촉.
- `LOG_TDES` = `src/transaction/log_impl.h`. writeset 필드는 develop에 없음 → C1이 추가.

## 1. 컴포넌트 분해
| 컴포넌트 | 책임 | 공유 상태 | 락 |
|---|---|---|---|
| 해싱(`fnv1a`,`string_hash`) | FNV-1a(class_oid 8B + packed key); CHAR/VARCHAR는 collation 의사키 fold | 없음 | 없음 |
| FK cast+pack(`add_ref_dbvalue`) | 자식 FK를 부모 PK 도메인으로 캐스트→동일 packing→REF 해시 | tx-local ws_hashes | 없음 |
| per-tx 버퍼(`add_key/add_dbvalue/add_ref`→`push/push_hash`) | {hash,kind} append; per-tx 상한 초과→ws_overflow, 버퍼 버림 | tdes->ws_hashes, ws_overflow | 없음(tdes 소유) |
| 전역 history struct | map hash→slots; floor history_start; baseline prev_commit_lsa; 캐시된 history_size | struct 전체 | §3 |
| commit_probe | dependency_seq = min(baseline, WRITE+REF map hit으로 올라간 floor); ws_dependency_is_read 설정 | map·history_start·prev_commit 읽기 | history rdlock + seq_mutex 스냅샷 |
| commit_flush | baseline 전진; WRITE→write_seq / REF→read_seq 게시; CAP·tx-overflow 시 clear+floor 점프 | map·history_start·prev_commit 쓰기 | seq_mutex; rdlock(정상)/wrlock(clear) |
| 부팅 lifecycle(init/finalize) | 락 생성/파괴, 스칼라 NULL, **param에서 history_size 1회 캐시** | struct 전체 | 없음(부팅/종료 정적) |
| 디버그 self-check(`#if !NDEBUG`) | FK 자식→부모도메인 캐스트가 부모 바이트로 packing되는지 1회 검증 | 없음 | pthread_once |

**제거(TEST-ONLY perf):** `wset_clock_ns`, `WS_PERF_LOG`/`_er_log_debug`, `ws_stat_collect_ns` 필드+누적 2곳, per-key 해시덤프 `er_log_debug`, 모든 타이밍/카운터 로컬, `*_internal` 타이밍 래퍼(→ `add_dbvalue`/`add_ref_dbvalue`로 접기).
**유지:** FNV-1a, `string_hash`, FK cast REF packing, `#if !NDEBUG` self-check, 두 clear 경로+부팅 init의 간결한 `er_log_debug` 각 1줄(타이밍 없음).

## 2. 헤더 인터페이스 (`writeset.h`)
PoC 헤더 대비 델타: `#include <unordered_map>` → `#include "tbb/concurrent_hash_map.h"`; `wset_clock_ns` 제거; 두 `#define` 상한 제거; HISTORY 확장(PoC의 file-static `prev_commit_lsa`를 struct로 흡수).

```c
typedef UINT64 LOG_WSET_HASH;
typedef enum { LOG_WSET_KIND_WRITE = 0, LOG_WSET_KIND_REF = 1 } LOG_WSET_KIND;
struct wset_entry { LOG_WSET_HASH hash; LOG_WSET_KIND kind; };
typedef struct wset_entry LOG_WSET_ENTRY;
/* write_seq: 키가 속한 행을 마지막으로 쓴 커밋. read_seq: 최신 FK 참조자(설계 용어 ref_seq). */
struct wset_slots { LOG_LSA write_seq; LOG_LSA read_seq; };
typedef struct wset_slots LOG_WSET_SLOTS;

struct wset_history
{
  tbb::concurrent_hash_map<LOG_WSET_HASH, LOG_WSET_SLOTS> map; /* 기본 hash compare */
  LOG_LSA          history_start;    /* clear로 evict된 키의 floor */
  LOG_LSA          prev_commit_lsa;  /* commit-order baseline, 단조 */
  pthread_rwlock_t history_lock;     /* rd: per-key 접근; wr: 전체 map clear() */
  pthread_mutex_t  seq_mutex;        /* prev_commit_lsa RMW/read 전용 */
  INT64            history_size;     /* 캐시된 ha_writeset_history_size; per-tx·map 상한 겸용 */
};
typedef struct wset_history LOG_WSET_HISTORY;

extern LOG_WSET_HISTORY wset_History;
extern void wset_history_initialize (void);
extern void wset_history_finalize (void);
extern int  wset_add_key (THREAD_ENTRY *, LOG_TDES *, const OID *, const char *packed, int len);
extern int  wset_add_dbvalue (THREAD_ENTRY *, LOG_TDES *, const OID *, DB_VALUE *pk);
extern int  wset_add_ref_dbvalue (THREAD_ENTRY *, LOG_TDES *, const OID *ref_class_oid,
                                          DB_VALUE *fk_value, struct tp_domain *parent_pk_domain);
extern void wset_commit_probe (THREAD_ENTRY *, LOG_TDES *, LOG_LSA *ws_parent_out);
extern void wset_commit_flush (THREAD_ENTRY *, LOG_TDES *, const LOG_LSA *commit_lsa);
```

`wset_history_initialize()`는 반환값이 없는 기동 초기화 함수다. 전역 락 초기화의 성공을 전제로 하며, 중복 호출에서는 락을 다시 만들지 않고 즉시 반환한다.

`.c` 전체는 `#if defined(SERVER_MODE) || defined(SA_MODE)` 아래. struct가 TBB map을 품으므로 **server/SA TU만 이 헤더 include 가능** — C1/C2(log_manager.c)엔 무방; CS log_applier는 C3까지 include 안 함.

**추가할 tdes 필드**(`log_impl.h`, `struct log_tdes`):
```c
std::vector<LOG_WSET_ENTRY> ws_hashes;   /* per-tx 수집 키 */
bool ws_overflow;                            /* per-tx 상한 도달 → commit order로 격하 */
bool ws_dependency_is_read;                  /* probe 결과: 최종 의존이 ref_seq 슬롯 유래 */
```
`log_tran_table.c`(`logtb_initialize_tdes`/`logtb_clear_tdes`)에서 init/reset: `ws_overflow=false; ws_dependency_is_read=false; ws_hashes.clear();`. (PoC의 `ws_dependency_seq` LOG_LSA 필드도 있었으나 그 값은 라벨로 나가므로 C2에서 다룸.)

## 3. 동시성 프로토콜
단일 락 순서 규칙(사이클 없음): **history_lock 바깥, seq_mutex는 독립·짧게.** probe는 rdlock 전에 seq_mutex로 `prev_commit_lsa` 스냅샷; flush는 history_lock 전에 seq_mutex로 baseline 전진. → **한 스레드가 두 락을 동시 보유하는 지점이 없음 → 구조적으로 데드락프리.**

| 연산 | history_lock | seq_mutex | 읽기 | 쓰기 |
|---|---|---|---|---|
| initialize | — | — | param | map.clear, history_start=NULL, prev_commit=NULL, history_size=prm, 락 init |
| finalize | — | — | — | map.clear, 락 destroy |
| probe(정상) | rd | rdlock 전 스냅샷 | prev_commit(snap), history_start, 키별 map.find(const_accessor) | ws_parent_out, ws_dependency_is_read(tx-local) |
| probe(overflow tx) | — | 짧게 | prev_commit | ws_parent_out=prev_commit |
| flush(정상) | rd | 짧게 전진 | 키별 map | prev_commit(max), 키별 write_seq/read_seq(accessor) |
| flush(CAP full) | wr | 짧게 전진 | map.size() 재확인 | map.clear, history_start=commit_lsa, 키 게시 |
| flush(tx-overflow) | wr | 짧게 전진 | — | map.clear, history_start=max(,commit_lsa) |

**flush 형태 — 락 업그레이드 없음:**
```
seq_mutex로 prev_commit 전진;                              // 독립
if (ws_overflow)     { wrlock; clear; history_start 상향; wrunlock; return; }
if (ws_hashes.empty()) return;
rdlock;
if (map.size() + count <= history_size) { accessor로 게시; rdunlock; return; }
rdunlock;                                                  // release+acquire로 승격
wrlock;
if (map.size() + count > history_size) { clear; history_start = commit_lsa; }  // 재확인
accessor로 게시;                                           // wr 하(드묾, 배타)
wrunlock;
```

**불변식 감사(모두 성립):**
- `map.clear()`는 CAP-full·tx-overflow 두 곳만 → 둘 다 wrlock. ✔
- `history_start` 쓰기는 그 두 곳(+부팅)만 → wrlock; probe에서 rdlock 하 읽기(rd/wr 상호배타 → 찢김 없음 → 평범한 `LOG_LSA`, 여기선 `LOG_LSA_ATOMIC` 불필요). ✔
- `prev_commit_lsa` RMW/read는 seq_mutex 하만, 단조. ✔

**잔여 플래그(검토됨, 각 수용 가능):**
1. 동시 rdlock insert 중 `map.size()` 근사 — history_size는 정합성 불변식이 아니라 소프트 메모리 상한; 경계에서 수천 오차는 clear가 약간 이르거나 늦을 뿐.
2. prev_commit 스냅샷 ↔ history_start/map이 한 원자시점 아님 — 같은 키 정합성은 map hit + 마스터 행 X-lock(선행 flush가 이 probe에 happens-before)에서 옴; baseline 스칼라는 독립 tx 라벨에만 영향, 단조라 stale 읽어도 보수적.
3. 2-accessor 데드락 없음: 키당 accessor/const_accessor 하나, 다음 순회 전 해제. 실행자는 다른 map 연산 걸친 accessor 보유 금지.
4. rwlock writer starvation: clear는 극히 드묾(상한에서만); 기본 reader-preference 수용, 선택적 `PTHREAD_RWLOCK_PREFER_WRITER_NONRECURSIVE_NP`.
5. finalize가 rwlock destroy — 호출자는 in-flight probe/flush 없음 보장(종료 정적; PoC latch도 같은 가정).
6. **신규 insert 값 초기화:** TBB `insert(acc,key)`는 POD 슬롯을 기본생성(가비지) → insert가 true 반환 분기에서 사용 전 양 슬롯 `LSA_SET_NULL`, PoC emplace-with-null과 동일.

## 4. C++ 가독성 do/don't
**DO:** 스코프 명확한 `accessor`/`const_accessor` 블록, 키 하나씩(insert→신규면 양 슬롯 null→복사); 파일 기존 명시적-latch 스타일 맞춘 `pthread_rwlock_*`/`pthread_mutex_*`; 짧고 눈에 보이는 임계구역; 평범한 이름, K&R 중괄호, `#if defined(SERVER_MODE)||defined(SA_MODE)` 가드; 자체완결 주석(내부 단계번호·절 참조 금지); 캐시된 `history_size`를 struct에서, param은 init에서 1회.
**DON'T:** 템플릿/concepts/ranges/fold/메타프로그래밍 금지; RAII 락 가드 금지(명시적 lock/unlock 맞춤); `auto` 남발 금지(TBB 타입 반복 대신 map+accessor에 `using` 별칭); 락 업그레이드 금지(release+acquire+재확인); 2-accessor 동시보유·rdlock 미만 map 접근 금지; `_er_log_debug`/타이밍/per-key 덤프 금지.

## 5. 실행자용 리스크 / 열린 질문
1. **tdes lifecycle 배선**이 `log_tran_table.c`(init/clear)를 건드림 — writeset.c 밖. `std::vector` 멤버가 tdes에서 깔끔히 생성되고 **commit·abort 둘 다**에서 reset되는지 확인.
2. **신규 param** `ha_writeset_history_size`: `system_parameter.c/.h`에 `PRM_ID_HA_WRITESET_HISTORY_SIZE` + 이름 + 기본값 + 테이블행(`PRM_FOR_SERVER | PRM_FOR_HA`, `PRM_INTEGER`, 기본 10000000) + enum + `PRM_LAST_ID`/`prm_Def` 순서. `ha_mode`(PRM_FOR_SERVER|PRM_FOR_HA) 모델; `ha_apply_max_mem_size`(PRM_FOR_CLIENT) 복사 금지. **열린 항목**: cub_server까지 실제 로드되는지(00-overview 미검증) — init에서 캐시값 `er_log_debug` 1줄로 부팅 시 확인.
3. **통합 상한:** 단일 `history_size`가 per-tx(`ws_hashes.size() >= history_size`, push_hash)와 `map.size()+count > history_size`(flush) **둘 다** 구동 — PoC의 독립 두 `#define` 대체, MySQL 패리티 결정과 일치.
4. **CMake:** `${TRANSACTION_DIR}/writeset.c`를 `cubrid/CMakeLists.txt`의 `TRANSACTION_SOURCES`(알파벳순, `log_writer.c` 뒤)와 `sa/CMakeLists.txt` 미러 리스트에 추가. `.c` 확장자 일관(CUBRID는 .c를 C++로 컴파일). 링크 변경 없음.
5. **self-check 부팅 순서:** FK self-check는 init이 아니라 **첫 FK 수집 시 `pthread_once`** 뒤 유지 — init은 recreate 부팅 경로에서 `tp_init` 전에 실행됨. PoC 배치 보존.

**C1이 건드리는 파일:** 신규 `src/transaction/writeset.{c,h}`; `log_impl.h`(tdes 필드); `log_tran_table.c`(tdes init/clear); `system_parameter.{c,h}`(param); `cubrid/CMakeLists.txt` + `sa/CMakeLists.txt`.
