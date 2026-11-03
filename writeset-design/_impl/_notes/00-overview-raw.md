# CBRD-26482 — writeset 병렬 applylogdb 정식 구현 계획

> PoC(feature/writeset_error_skip)를 설계문서 기반으로 최신 develop 위에 **큰 덩어리 논리 커밋**으로 재구성한다. PoC 커밋 정리 대신 새 브랜치로 쌓는다.

## 브랜치

| | 값 |
|---|---|
| 새 브랜치 | `feature/CBRD-26482-parallel-applylogdb-writeset` |
| base | `upstream/develop` (CUBRID/cubrid) @ `c63a3b993` |
| PoC 레퍼런스 | `feature/writeset_error_skip` @ `0405c9bd8` (보존, 정리 안 함) |
| 설계 근거 | 6-1(마스터), 6-2(슬레이브), 8-1(마스터 상세), 8-2(슬레이브 상세), 7(LSA 관리), 11+원자료(실측) |

## 배경 — 왜 정리 대신 새 브랜치인가

- PoC 브랜치는 develop보다 **136 앞 / 220 뒤** (fork 2026-08-04). PoC·계측·crash-fix 커밋이 다수라 지금 정리(squash) 부담이 큼.
- develop이 220커밋(447파일, +56,239/−11,924) 앞서갔고, 그중 **writeset 핵심 파일을 건드린 게 있어** 어차피 적응이 필요함.
- 따라서 옛 커밋 정리보다 **develop 위 정식 구현을 큰 덩어리로 새로 쌓는 것**이 커밋 위생 + develop 적응을 한 번에 해결.
- CS 포트 브랜치(feature/parallel_applylogdb_writeset_cs)의 작업(fileio pread/pwrite 등)은 **이미 PoC 브랜치에 전부 흡수됨**(error_skip..cs = 0). 별도 누락 없음.

## 큰 덩어리 커밋 계획 (8단계)

각 커밋 = 설계문서 한 단위, 가능하면 빌드 단위.

**마스터**
1. writeset 자료구조 + history map — `writeset.c/h`, WRITE/REF 슬롯, history map은 **TBB `concurrent_hash_map`**(latch 제거). (6-1, 8-1)
2. 키 수집 + dependency probe + 게시 — 커밋 훅 키 수집, `commit_probe`(write_seq/read_seq 선택·`is_ref`), WSET_LABEL 기록. (6-1)

**슬레이브**
3. reader → task 구성 — `LA_APPLY_TASK`, 라벨 디코드, repl_list 포인터 핸드오프. (6-2, 8-2)
4. 게이트 — `is_satisfied` ①②③ + frontier + 완료집합 + pending/drain. (6-2)
5. worker + 결과 수거 + retire — 큐(**TBB `concurrent_queue`**), apply, result queue, collect→mark→advance→drain, 슬롯 반환. (6-2, 8-2)

**안정성**
6. committed_lsa(frontier 기반) + 복구 3구간 + error-skip. (7, 8-2)
7. CS 하드닝 이월 — fileio pread/pwrite, shared-fd race, page-0 가드. (PoC 검증된 실수정)

**분리**
8. 유닛테스트(Catch2, writeset 단가/경합/FK). 계측(do-not-merge 성격)은 정식엔 미포함 또는 별도.

## develop 적응 필요 지점

정식 포팅은 "체리픽"이 아니라 **develop 위 적응 포팅**이다. 미리 파악해 둘 것:

### atomic LSA 타입 (CBRD-27320, `b319ce1ab`)
- `LOG_LSA`(pageid+offset 비트필드)의 찢김 읽기 방지용 `log_lsa_atomic`(`LOG_LSA_ATOMIC`, `log_lsa.hpp`) 도입.
- `LOG_HEADER::append_lsa`, `log_append_info::prev_lsa`가 이 타입이 되고, `load()`/`store()`/`advance()`로만 접근. `log_get_append_lsa()`는 포인터 대신 **값** 반환.
- **영향**: 게이트가 append_lsa 읽는 곳은 `load()`로 전환 필요. log_applier.c 43줄 변경됨.

### 양쪽이 같이 건드린 함수 (충돌 핫스팟)
정밀 분석(`git log -L:func`) 결과 **실제 충돌은 `la_apply_log_file` 하나**다(나머지 3개는 hunk-헤더 오탐). 상세는 [`02-develop-adaptation.md`](02-develop-adaptation.md).

| 함수 | 판정 |
|---|---|
| `la_apply_log_file` | ★실제 충돌 (develop=atomic LSA ±32 / PoC ±444) — 적응 필요 |
| `la_apply_repl_log`, `la_log_commit`, `log_change_tran_as_completed` | 오탐, 충돌 없음 |

- `writeset.c`는 **신규 파일**이라 충돌 없음 — 그대로 이식.

### 라이브러리 결정 — TBB (상세: `02-develop-adaptation.md`, `04`, `05`)
손수 만든 concurrent 자료구조를 **Intel TBB**로 대체한다. **단 TBB 링크는 타깃별로 다르다**: 서버·SA엔 링크됨, **CS(cubridcs)엔 현재 미링크** — 슬레이브(CS)에서 TBB 쓰려면 `cs/CMakeLists.txt`에 TBB 추가 선행.
- **마스터 history map** (서버·SA, TBB 이미 링크): `std::unordered_map`+latch → **`tbb::concurrent_hash_map`**(전역 latch 제거). 추가 작업 없음.
- **슬레이브 워커/결과 큐** (CS): 손수 링버퍼 → **`tbb::concurrent_queue`** — **`cs/CMakeLists.txt`에 TBB 링크 추가 선행 필요.**
- **슬레이브 completed set** (CS): 손수 오픈어드레싱 2^18 고정(overflow=복제중단) → **`std::unordered_map`**(리더 단일스레드라 동시성 불필요 + CS에 TBB 안 끌어와도 됨. 목적은 자동 성장).
- 각 자료구조 커밋(1·5단계)에서 **처음부터 위 선택대로** 작성.

### 설정·게이팅 결정 (코드 확인 완료)
- **history map 크기 = 설정 파라미터**: `ha_writeset_history_size`(가칭) 같은 **`ha_*` 시스템 파라미터**, 플래그 **`PRM_FOR_SERVER | PRM_FOR_HA`**, **`cubrid_ha.conf`** 에 명시.
  - 근거: 맵은 **마스터 서버**에 살아서 `PRM_FOR_SERVER` 필요. `ha_apply_max_mem_size`는 `PRM_FOR_CLIENT`(슬레이브용)라 선례 부적합. 서버가 읽는 HA 파라미터 선례 = `ha_mode`(`PRM_FOR_SERVER|...|PRM_FOR_HA`).
- **비-HA 서버 오버헤드 0 — 게이팅은 이미 존재**: writeset 수집(`wset_commit_probe`)·게시(`wset_commit_flush`)가 `log_manager.c`에서 **복제 로그와 같은 `log_does_allow_replication()` 게이트 + `#if SERVER_MODE||SA_MODE`** 안에 있음. 복제 안 하면 수집 자체가 안 돎 → **추가 게이팅 불필요**(정식 이식 때 이 구조 유지).

### 보류 — 별도 태스크 (코어 먼저)
- **`db_restart_sub`(CS팀 워커 세션 부트) 포팅 = 별도 태스크로 미룸.** 이유: 단일 함수가 아니라 `net_client_sub_init`·`boot_finalize_client_sub`·session params(`sysprm_load_session_parameters`, 10+파일)에 걸친 **엉킨 다중 커밋 기능**이고, develop이 `boot_cl.c`(3커밋)·`boot_cl.h`(1커밋)를 바꿔 충돌 위험. cherry-pick·함수복사 둘 다 불가.
- **워커층(5단계)은 옵션 2 인터페이스 뒤에 단순 부트로 먼저** 구현(PoC도 임시부트→db_restart_sub 순서였음). CS팀 db_restart_sub는 코어 완성 후 **network sub-init + session params + boot_cl 충돌 해소를 한 번에** 하는 집중 포팅으로 교체.
- 관련 커밋(참고): `a615224c0`(add) · `33304dce`(net sub-init) · `7e3a1b9d`(session params, 광범위) · `f7e1da73`(boot_clxxx 정리). applier 연결 `684dd5c8`(writeset)은 우리 워커층에서 새로.

## 남은 문서 (이 디렉토리)

- `01-commit-plan.md` — 커밋 8단계를 파일·함수 목록까지 확정.
- `02-develop-adaptation.md` — atomic LSA + 충돌 함수 적응 + TBB 라이브러리 결정. (작성됨)
- `03-progress.md` — 진행 체크리스트.
- `04-cs-worker-pool-analysis.md` — CS/스레드 워커풀 재사용 가능성(에이전트 분석).
- `05-modularization-analysis.md` — writeset 별도 디렉토리 모듈화 + CMake 영향(에이전트 분석).

## 규칙 (이 repo, NFC/NFD 사고 후)

- 새로 만드는 파일·디렉토리는 **ASCII 이름**(이 `_impl/`처럼). 기존 한글 파일은 접근 시 glob/find로 실제 바이트 경로만 사용, 손 타이핑 금지.
- 브랜치 생성은 `git branch <name> upstream/develop`(ref만, checkout 안 함)로 작업트리 보존.
