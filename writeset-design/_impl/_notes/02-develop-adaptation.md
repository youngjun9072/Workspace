# develop 적응 + 라이브러리(TBB) 결정

> 새 브랜치(`feature/CBRD-26482-parallel-applylogdb-writeset`, base `upstream/develop c63a3b993`)에 PoC를 얹을 때의 적응 지점과, 자료구조 라이브러리를 **TBB**로 바꾸는 결정을 정리한다.

## 1. develop 적응 — 실제 충돌은 좁다

파일 겹침(log_applier.c 2커밋 / log_manager.c 6커밋)은 거칠다. 정밀 분석(`git log -L:함수:파일`)하면, **writeset이 건드린 함수 중 develop도 실제로 바꾼 것은 `la_apply_log_file` 하나뿐**이다.

| 함수 | develop 변경 | PoC 변경 | 판정 |
|---|---|---|---|
| `la_apply_log_file` | ±32 (atomic LSA, CBRD-27320) | ±444 | **★실제 충돌 — 적응 필요** |
| `la_apply_repl_log` | ±0 | ±17 | hunk-헤더 오탐, 충돌 없음 |
| `la_log_commit` | ±0 | ±0 | 오탐, 충돌 없음 |
| `log_change_tran_as_completed` | ±0 | ±0 | 오탐, 충돌 없음 |

> [!NOTE]
> 앞서 hunk-헤더 교집합이 4개를 잡았지만, hunk 헤더는 "변경 위치의 바로 앞 함수 시그니처"라 인접 함수를 오탐한다. `-L:func` 로 함수 본문 범위를 정확히 추적하면 실제 겹침은 1개다.

develop의 log_manager.c 6커밋·log_applier.c 나머지는 **writeset이 안 건드린 함수**라 자동 병합 가능성이 높다. 즉 수작업 핵심은 **`la_apply_log_file` + atomic LSA API 전환** 두 가지로 좁혀진다.

## 2. atomic LSA 적응 (CBRD-27320, `b319ce1ab`)

- `LOG_HEADER::append_lsa`, `log_append_info::prev_lsa` 가 `LOG_LSA_ATOMIC` 타입. `load()`(acquire)·`store()`(release)·`advance()` 로만 접근. `log_get_append_lsa()`·`xrepl_log_get_append_lsa()` 는 포인터 대신 **값** 반환.
- **적응**: writeset이 append_lsa/prev_lsa 를 읽는 곳(reader 읽기 위치 판단, frontier 비교 등)은 `load()` 로 전환. `la_apply_log_file` 의 PoC 444줄 변경을 develop 의 atomic-LSA 32줄 위에 재적용한다.
- `writeset.c` 는 **신규 파일**이라 충돌 없음 — 그대로 이식.

## 3. 라이브러리 결정 — TBB로 전환

정식 구현에서 손수 만든 concurrent 자료구조를 **Intel TBB** 컨테이너로 대체한다.

**전제 (타깃별로 나눠 봐야 정확 — `04/05` 분석 반영)**: TBB는 외부에 이미 있지만(`libtbb.so.2` 설치, `connection_worker.hpp`가 `tbb::concurrent_queue` 사용) **링크는 타깃별로 다르다**:
- **cub_server / cubridsa (서버·SA)**: TBB 링크됨(`cubrid/CMakeLists.txt:730-731`, `sa/CMakeLists.txt:788-789`). → **마스터 쪽(`writeset`, 서버·SA 빌드)은 추가 작업 없이 TBB 사용 가능.**
- **cubridcs (CS)**: **TBB 링크 안 됨**(`cs/CMakeLists.txt:613-626`에 TBB_LIBS 없음). connection_worker가 TBB를 쓰지만 서버 전용이라 CS로 안 끌려옴. → **슬레이브 쪽(`log_applier`의 gate·queue, CS 빌드)에서 TBB 컨테이너를 쓰려면 `cs/CMakeLists.txt`에 TBB include·link·add_dependencies 추가가 선행돼야 한다**(변수 TBB_LIBS/INCLUDES는 PARENT_SCOPE로 노출됨).

| 구조 | 현재 | TBB 후보 | 바꾸는 이유 |
|---|---|---|---|
| 마스터 history map | `std::unordered_map` + `latch`(pthread_mutex) | `tbb::concurrent_hash_map` | 전역 latch 직렬화 제거 → probe/flush 동시성 |
| 슬레이브 completed set | 손수 오픈어드레싱 **2^18 고정** (overflow 시 `ER_FAILED`=복제 중단) | `tbb::concurrent_hash_map` 또는 `std::unordered_map` | **자동 성장** → 약 13만 초과 중단 위험 제거 |
| worker / result queue | 손수 링버퍼 + mutex/cond | `tbb::concurrent_queue` | 락 경합↓, 코드 단순화 (connection_worker와 동일 패턴) |

> [!IMPORTANT]
> **동시성 필요 여부 + CS 링크를 함께 고려** — completed set은 **리더 단일 스레드**만 접근하므로(무락 설계) concurrent 컨테이너가 정합성상 필수는 아니다. TBB의 이득은 동시성이 아니라 **자동 성장(고정 2^18 overflow 제거)** 이다. 게다가 슬레이브는 **CS 빌드라 TBB가 아직 안 링크됨**(위 전제) → completed set은 **`std::unordered_map`이 이중으로 유리**하다(동시성 불필요 + CS에 TBB 안 끌어와도 됨). 반면 **워커 큐**(리더↔워커 다중 스레드)는 `tbb::concurrent_queue` 이득이 분명하지만 **CS에 TBB 링크 추가(`cs/CMakeLists.txt`)가 선행돼야** 한다. 마스터 history map(서버·SA, TBB 이미 링크)은 `tbb::concurrent_hash_map` 바로 가능.

**커밋 계획 반영**: 이 라이브러리 전환은 각 자료구조 도입 커밋(01-commit-plan의 1·4·5단계)에서 **처음부터 TBB로** 작성한다(먼저 손수 구현 후 교체하지 않는다).

## 4. 요약

- develop 적응 실수작업 = **`la_apply_log_file` 재적용 + atomic LSA `load()` 전환** 두 가지.
- 나머지 develop 변경은 writeset 미접촉 함수라 자동 병합 기대.
- 자료구조는 **TBB**(이미 있는 의존성)로: history map=concurrent_hash_map, 큐=concurrent_queue, completed set=자동성장 맵(TBB 또는 std). completed set은 자동성장이 주목적(동시성 부차).
