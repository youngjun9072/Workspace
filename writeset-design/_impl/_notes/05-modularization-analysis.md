# 분석 2 — writeset 코드를 별도 디렉토리로 모듈화할 수 있는가

> 대상: writeset 관련 소스(`writeset.c/.h`, `log_applier.c`의 `la_gate_*` 함수군)를 `src/transaction/` 안 또는 밖의 **별도 서브디렉토리**로 분리할 수 있는지, CMake 빌드 관점에서 확인한다. 읽기 전용 조사.
> 조사 브랜치: `feature/writeset_error_skip` @ `0405c9bd8`. 현재 코드 사실 / 추정 / 미확인을 구분한다.

## 결론

**난이도 판정: `writeset.c/.h`를 서브디렉토리로 옮기는 것은 "보통"(주로 기계적). `la_gate_*`를 별도 TU로 떼내는 것은 "보통~큼"(file-static 상태 노출 설계가 필요).**

CUBRID의 소스 리스트는 각 파일을 **절대 경로 변수(`${TRANSACTION_DIR}/파일`)로 명시 나열**하고, include는 **디렉토리 단위 전역 목록**으로 잡는다(`glob` 아님). 따라서 파일을 새 서브디렉토리로 옮기는 작업은 ①파일 실제 이동 ②세 타깃 CMake 소스 리스트의 경로 수정 ③새 디렉토리를 전역 `include_directories`에 한 줄 추가 — 이 세 가지의 조합이며, `#include "basename.h"` 형태는 그대로 유지된다. `writeset.c`는 신규·독립 파일이라 여기까지면 끝난다.

반면 `la_gate_*`는 지금 `log_applier.c` 안의 **정적(static) 함수 + 파일 전역(static) 상태**로 구현돼 있어, 별도 TU로 빼면 그 상태를 헤더/접근자로 노출해야 하고 게이트가 참조하는 리더 측 자료구조와의 결합을 끊어야 한다. 이 분리는 CMake 문제가 아니라 **코드 구조(가시성) 문제**이며 실제 손이 더 간다.

아래에 근거와 최소 절차를 정리한다.

## 1. 현재 빌드 구조 (현재 코드 사실)

### 소스 리스트는 절대 경로 명시 나열

- 디렉토리 변수: `CMakeLists.txt:415` `set(TRANSACTION_DIR ${CMAKE_SOURCE_DIR}/src/transaction)`.
- 세 타깃이 각자 자기 소스 리스트를 갖는다:
  - `cs/CMakeLists.txt:357` `set(TRANSACTION_SOURCES ...)` — CS_MODE(`cubridcs`)
  - `sa/CMakeLists.txt` `TRANSACTION_SOURCES` — SA_MODE(`cubridsa`)
  - `cubrid/CMakeLists.txt` `TRANSACTION_SOURCES` — SERVER_MODE(`cub_server`)
- `file(GLOB ...)`는 쓰지 않는다. 파일마다 `${TRANSACTION_DIR}/이름.c` 한 줄로 등록한다. **파일을 옮기면 그 줄의 경로를 반드시 고쳐야 한다**(자동 감지 안 됨).

### writeset 파일이 실제로 들어가는 타깃 (모드별로 다름 — 중요)

| 파일 | cub_server(SERVER) | cubridsa(SA) | cubridcs(CS) |
|---|---|---|---|
| `writeset.c` | O `cubrid/CMakeLists.txt:467` | O `sa/CMakeLists.txt:471` | X (없음) |
| `writeset.h` | O `cubrid/CMakeLists.txt:496` | O `sa/CMakeLists.txt:501` | X |
| `log_applier.c` | X | X | O `cs/CMakeLists.txt:469` (UNIX 조건부) |
| `log_applier_sql_log.c` | X | X | O `cs/CMakeLists.txt:468` |

- `writeset.c`(마스터 history)는 **서버·SA에만**, `log_applier.c`(슬레이브 gate 포함)는 **CS에만** 컴파일된다. 즉 마스터 writeset과 슬레이브 gate는 **애초에 서로 다른 타깃**에 산다.
- `log_applier.c`는 `cs/CMakeLists.txt:465-469` 의 `if(UNIX)` 블록 안에서 등록된다(Windows 미포함).

### include는 디렉토리 단위 전역 목록

- `CMakeLists.txt:425-456` `include_directories(...)` 에 `src/transaction` 을 포함한 각 소스 디렉토리가 나열돼 있다. 그래서 코드가 `#include "writeset.h"` 처럼 **basename**만 쓴다(`log_applier.c:43` `#include "log_applier.h"` 등 동일 패턴).
- **함의**: 새 서브디렉토리(예: `src/transaction/writeset`)를 만들면 그 경로를 이 목록에 **한 줄 추가**해야 그 안의 헤더를 basename으로 계속 찾을 수 있다. 추가만 하면 기존 `#include "writeset.h"` 는 수정 불필요.

## 2. `writeset.c/.h` 서브디렉토리 이동 — 난이도 "보통"(기계적)

목표 예: `src/transaction/writeset/writeset.c`, `.../writeset/writeset.h`.

필요 작업:
1. 파일 두 개를 새 디렉토리로 이동.
2. **새 경로 변수 또는 직접 경로로 소스 리스트 수정** — `cubrid/CMakeLists.txt:467,496` 과 `sa/CMakeLists.txt:471,501` 의 두 줄씩(총 4곳). 예: `set(WRITESET_DIR ${CMAKE_SOURCE_DIR}/src/transaction/writeset)` 를 `CMakeLists.txt:415` 근처에 추가하고 리스트를 `${WRITESET_DIR}/writeset.c` 로 바꾼다.
3. **`include_directories`에 `src/transaction/writeset` 한 줄 추가**(`CMakeLists.txt:425-456`). 이러면 `#include "writeset.h"` 를 쓰는 기존 코드(서버 측)는 수정 불필요.

3개 빌드모드 영향:
- **SERVER / SA**: 위 4곳 경로만 맞으면 그대로 빌드. `writeset`는 이 두 타깃에만 있으므로 실질 영향은 여기까지.
- **CS**: `writeset`가 원래 CS에 없으므로 이동해도 CS는 영향 없음.

이 범위는 include 경로도 basename 유지라 **코드 본문 수정이 거의 없다.** 그래서 "보통"보다 가벼운 기계적 작업에 가깝다(추정: 컴파일 단위로는 문제없음, 실제 빌드 검증은 미실행 — 아래 "미확인").

## 3. `la_gate_*` 분리 — 난이도 "보통~큼"(가시성 설계 필요)

`la_gate_*` 는 지금 `log_applier.c` 안에 **static 함수 + file-static 전역 상태**로 있다(현재 코드 사실).

- 함수가 static으로 선언됨: `log_applier.c:1596` `static int la_gate_dispatch_now(...)`, `:1599` `la_gate_hash_lsa`, `:1605` `la_gate_set_contains`, `:1698` `la_gate_advance_frontier`, `:1724` `la_gate_mark_completed`, `:1777` `la_gate_is_satisfied`, `:1888` `la_gate_choose_worker`, `:1932` `la_gate_init`, `:2003` `la_gate_drain_complete` 등.
- 게이트가 다루는 상태가 파일 전역 static이다: 완료집합·프론티어·pending·in-flight list(예: `la_Gate_order_head`, `la_Gate_frontier` — `:1698-1748` 참조). 같은 TU 안이라 지금은 직접 접근한다.

별도 TU(`writeset/la_gate.c` 등)로 빼면 생기는 실제 이슈:
1. **static 함수를 외부 링크로 승격** — `log_applier.c` 의 리더 루프가 호출하는 게이트 함수(`la_gate_is_satisfied`, `la_gate_mark_completed`, `la_gate_advance_frontier` 등)를 헤더에 선언하고 static을 떼야 링크된다.
2. **file-static 상태의 소유권 이전** — 완료집합/프론티어/pending을 새 TU로 옮기고, 리더가 접근하던 부분을 접근자 함수 또는 명시적 구조체 핸들로 바꿔야 한다. 지금은 같은 파일이라 전역 변수 직접 참조로 얽혀 있어, 이 결합을 끊는 것이 핵심 작업량이다.
3. **게이트↔리더 자료구조 결합** — 게이트는 워커 선택(`la_gate_choose_worker`)·dispatch(`la_gate_dispatch_now` → `la_enqueue_apply_task`)에서 워커·큐(`LA_APPLY_WORKER`)와 in-flight list FIFO를 만진다(`log_applier.c:444-449` 주석, `:1912-1921`). 이들도 리더 측 자료구조라, 게이트만 깔끔히 떼려면 인터페이스 경계를 새로 그어야 한다.

이 작업은 CMake가 아니라 **C 코드의 가시성·소유권 재설계**다. 정식 구현에서 게이트를 독립 모듈로 만들 가치는 있으나, "파일만 옮기면 되는" 수준은 아니다. 난이도 "보통~큼".

> 참고: `log_applier.c` 는 `writeset.h` 를 include하지 않는다(현재 코드 사실 — grep 결과 없음). 즉 슬레이브 게이트는 마스터 writeset 구조체(`LOG_WRITESET`)에 코드 의존이 없고, 로그 레코드의 라벨을 자체 디코드한다. 따라서 `la_gate_*` 분리는 `writeset` 이동과 독립적으로 진행할 수 있다.

## 4. 보너스 — TBB를 CS 타깃에 링크해야 하는 별도 과제 (현재 코드 사실)

정식 설계(02-develop-adaptation)는 자료구조를 TBB로 전환하기로 했고, "TBB는 이미 CUBRID 의존성(`connection_worker.hpp`가 사용)"을 전제로 든다. 이 전제는 **타깃별로 구분해야 정확하다**:

- TBB는 `cub_server`(`cubrid/CMakeLists.txt:730-731`)와 `cubridsa`(`sa/CMakeLists.txt:788-789`)에만 링크된다: `target_link_libraries(... ${TBB_LIBS})`, `target_include_directories(... ${TBB_INCLUDES})`.
- **`cubridcs`(CS)에는 현재 TBB가 링크되지 않는다** — `cs/CMakeLists.txt` 의 링크 목록(`:613-626`)에 `${TBB_LIBS}`/`${TBB_INCLUDES}`가 없다. `connection_worker.cpp`가 TBB를 쓰지만 그 파일은 서버 타깃 전용이라(§분석1), CS에 TBB 링크를 끌어오지 않는다.
- 다만 변수 자체는 노출돼 있다: `3rdparty/CMakeLists.txt:536-538` 에서 `TBB_TARGETS/TBB_INCLUDES/TBB_LIBS` 를 `PARENT_SCOPE`로 내보낸다.

**함의**: 슬레이브 gate(log_applier.c, CS)에서 `tbb::concurrent_queue`/`concurrent_hash_map`을 쓰려면 `cs/CMakeLists.txt`에 다음을 추가해야 한다(추정 최소 변경): `target_include_directories(cubridcs PUBLIC ${TBB_INCLUDES})`, `target_link_libraries(cubridcs ... ${TBB_LIBS})`, 그리고 빌드 순서 보장을 위한 `add_dependencies(... ${TBB_TARGETS})`. 마스터 측 `writeset.c`(서버·SA)는 이미 TBB가 링크된 타깃에 있어 추가 불필요.

즉 "TBB는 이미 있으니 그냥 쓰면 된다"는 마스터에는 맞고, **슬레이브(CS)에는 CMake 링크 추가가 선행돼야** 성립한다. 설계 문서의 전제를 이 지점에서 보정할 필요가 있다.

## 5. 최소 절차 요약

writeset 서브디렉토리화(권장: `src/transaction/writeset/`)를 한다면:

1. `CMakeLists.txt` 근처(`:415`)에 `set(WRITESET_DIR ${CMAKE_SOURCE_DIR}/src/transaction/writeset)` 추가.
2. `CMakeLists.txt:425-456` `include_directories`에 `src/transaction/writeset` 한 줄 추가.
3. `writeset.c/.h` 이동 후 `cubrid`·`sa` 소스/헤더 리스트 4곳 경로를 `${WRITESET_DIR}/...` 로 수정.
4. (선택, 더 큼) `la_gate_*`를 `writeset/la_gate.c`로 분리 — static 해제 + file-static 상태를 헤더/접근자로 노출 + 리더 결합 정리. CS 소스 리스트(`cs/CMakeLists.txt:465-469` 블록)에 새 `.c` 추가.
5. TBB를 CS gate에서 쓸 경우 `cs/CMakeLists.txt`에 TBB include·link·dependency 추가.

## 미확인

- 위 절차대로 옮긴 뒤 **실제 빌드 통과 여부는 검증하지 않았다**(읽기 전용, 빌드 미실행). "미확인".
- `log_applier.c`를 서브디렉토리로 통째 옮기는 경우 다른 실행 파일(`util_service.c` 등 executables)이 참조하는 헤더 경로 파급은 이번에 끝까지 따라가지 않았다. 게이트 분리에 한정해 조사했다. "미확인".
- `la_gate_*`가 참조하는 file-static 전역의 정확한 전수 목록은 대표 변수만 확인했고 완전 목록은 만들지 않았다. 실제 분리 착수 시 `log_applier.c` 내 `la_Gate_*` 심볼 전수 확인이 필요하다. "미확인".
