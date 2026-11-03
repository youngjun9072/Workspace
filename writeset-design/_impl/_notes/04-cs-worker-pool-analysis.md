# 분석 1 — CS 라이브러리의 워커풀을 writeset applier에 재사용할 수 있는가

> 대상: writeset 병렬 applylogdb 정식 구현. 슬레이브 applier(`log_applier.c`)가 도는 빌드 모드에서 기존 워커풀 추상화를 재사용할 수 있는지 코드로 확인한다. 읽기 전용 조사.
> 조사 브랜치: `feature/writeset_error_skip` @ `0405c9bd8`. 근거는 file:line으로 표기하고 현재 코드 사실 / 추정 / 미확인을 구분한다.

## 결론

**기존 워커풀 두 후보(`cubthread::worker_pool`, `cubconn::connection` 워커풀)는 슬레이브 applier에 그대로 재사용할 수 없다.** 이유는 성능이나 API 모양이 아니라 **링크 경계**다. 두 워커풀 모두 `cub_server`(SERVER_MODE)에만 링크되는 코드이고, writeset applier는 `cubridcs`(CS_MODE)로 빌드되는 `log_applier.c`에서 돈다. CS_MODE 바이너리에는 두 워커풀 구현이 애초에 포함되지 않는다.

따라서 정식 구현에서도 워커풀 자체는 **applier(CS) 안에 별도로 두어야 한다.** 현재 PoC가 pthread로 손수 만든 워커·큐를 유지하거나, CS에서도 링크 가능한 TBB 컨테이너(`tbb::concurrent_queue`)로 큐만 교체하는 방향이 현실적이다. 게이트(의존성 순서)와 커밋순서 retire 로직은 어느 경우든 풀 위에 별도로 얹어야 하며, 이는 기존 워커풀을 썼더라도 마찬가지다.

아래에서 후보별로 링크 경계와 API 모델을 확인하고, applier 요구사항과 대조한다.

## 후보 1 — `cubthread::worker_pool` (범용 태스크 풀)

CUBRID의 정식 범용 스레드풀 추상화다. 구조상 applier가 원하는 "N개 워커가 태스크를 병렬 실행" 모델에 가장 가깝다.

### 링크 경계 — SERVER_MODE 전용 (재사용 불가의 핵심 근거)

- `src/thread/thread_worker_pool.hpp:26-28`
  ```c
  #if !defined (SERVER_MODE)
  #error Wrong module
  #endif // not SERVER_MODE
  ```
  워커풀 클래스 선언 자체가 SERVER_MODE가 아니면 컴파일 에러를 낸다.
- 워커풀을 생성·소유하는 매니저 `src/thread/thread_manager.hpp:9-11` 은 `SERVER_MODE || SA_MODE` 에서만 유효하고, 실제 풀 구현 헤더는 `thread_manager.hpp:18-19` 에서 **SERVER_MODE일 때만** include된다.
  ```c
  #if !defined (SERVER_MODE) && !defined (SA_MODE)
  #error Wrong module
  ...
  #if defined (SERVER_MODE)
  #include "thread_worker_pool_impl.hpp"
  ```
  즉 SA_MODE에서도 매니저는 존재하지만 워커풀 실체(`create_worker_pool`)는 없다. 워커풀이 실제로 존재하는 모드는 **SERVER_MODE 하나**다.
- `log_applier.c` 는 `cs/CMakeLists.txt:468-469` 에서 `cubridcs`(CS_MODE) 타깃으로만 컴파일된다(§분석2 참조). CS_MODE에는 위 헤더가 `#error`로 막혀 있어 링크 이전에 컴파일이 불가능하다.

**판정(현재 코드 사실)**: `cubthread::worker_pool`은 applier가 도는 CS_MODE에서 사용할 수 없다. 재사용하려면 SERVER_MODE 전용으로 묶인 `thread/` 모듈 전체를 CS에서도 빌드되도록 가드를 해제해야 하는데, 이는 applier 워커풀을 위해 스레드 인프라 전반의 빌드 경계를 바꾸는 큰 변경이다.

### API·수명주기·태스크 모델 (end-to-end, 참고용)

CS에서 못 쓰더라도 "어떤 흐름을 담을 수 있는 풀인가"는 확인해 둔다.

- **생성/소멸**: `thread_manager.hpp:137` `create_worker_pool<Res>(pool_size, core_count, args...)`, `:140` `destroy_worker_pool()`. 편의 래퍼 `:522` `thread_create_worker_pool(pool_size, core_count, name, ...)`.
- **워커 수 설정**: 생성 시 `pool_size`(워커 수)와 `core_count`(코어 분할)로 지정. `thread_worker_pool.hpp:66` `initialize(worker_count, core_count)`.
- **태스크 제출**: `thread_worker_pool.hpp:69` `execute(task_type *)`, `:70` `execute_on_core(task, core_hash, is_temp)`. 매니저 경유는 `thread_manager.hpp:144` `push_task(pool, entry_task *)`.
- **태스크 표현**: `thread_task.hpp:60-79` `task<Context>` 추상 클래스. `execute(Context &)` 오버라이드, 기본 `retire()`는 `delete this`. 함수객체 기반 `callable_task<Context>`(`:82-115`)도 있음. applier 워커풀의 `context_type`은 `cubthread::entry`(`thread_worker_pool.hpp:60-61`).
- **결과 반환 경로**: **없음.** `task::execute()`는 `void` 반환이고 풀은 결과를 수거하는 채널을 제공하지 않는다. 결과가 필요하면 태스크가 제출자와 공유하는 자료구조에 직접 써야 한다(현재 코드 사실).
- **수명주기**: `warmup()`(`:73`), `stop_execution()`(`:76`), `is_running()`(`:79`). 부하가 낮으면 워커를 회수하고 다시 늘리는 동적 스케일 정책(`:48-52` 주석)을 내장.

### applier 요구사항과의 대조

| applier 요구 | cubthread 풀이 담는가 |
|---|---|
| ① N개 워커가 각자 트랜잭션 하나를 통째 적용 | 담는다. 태스크 하나 = `la_apply_repl_log` 한 트랜잭션으로 매핑 가능. |
| ② 게이트가 의존 순서로 dispatch/park 결정 | **담지 않는다.** 풀은 제출된 태스크를 곧바로 실행 대기시킨다. "선행 완료 전까지 보류(park)" 개념이 없어 게이트는 풀 밖에서 제출 시점을 제어해야 한다. |
| ③ 결과를 커밋순서로 retire 수거 | **담지 않는다.** 결과 채널이 없어 completed set 등록·frontier 전진·retire는 전부 별도 자료구조로 구현해야 한다. |
| 워커별 서버 세션 | 담지 않는다. 아래 별도 항목. |

### 추가 불일치 — 워커 컨텍스트가 다르다 (현재 코드 사실)

PoC 워커는 각자 **독립된 서버 클라이언트 세션**을 연다: `log_applier.c:433-440` `LA_APPLY_WORKER_SESSION { css_started, client_registered, client_context_started, server_credential }`, 시작 함수 `:2294` `la_apply_worker_start_session()`. 각 워커가 서버에 붙어 자기 트랜잭션을 커밋하기 위한 것이다.

반면 cubthread 풀의 워커 컨텍스트는 `cubthread::entry`(서버 내부 스레드 엔트리)다. 이는 서버 프로세스 안에서 쓰는 스레드 살림 구조이지, applier처럼 **원격 서버로 붙는 클라이언트 세션**이 아니다. 태스크/컨텍스트 모델이 근본적으로 다르다.

## 후보 2 — `cubconn::connection` 워커풀 (coordinator + worker + pool)

사용자가 언급한 "CS 라이브러리 워커풀"의 가장 가까운 후보다. `connection_worker.hpp` 는 실제로 `tbb::concurrent_queue`(`:39, :242`)를 쓴다.

### 링크 경계 — 이것도 서버 타깃 전용

- `connection_worker.cpp` / `coordinator.cpp` / `connection_pool.cpp` 는 **`cubrid/CMakeLists.txt:214-216`(cub_server, SERVER_MODE) 에만** 소스로 들어간다.
- `cs/CMakeLists.txt:184-192` 의 `CONNECTION_SOURCES` 에는 이 세 파일이 없다. CS 타깃은 `connection_cl.cpp`, `connection_support.cpp` 등 클라이언트 접속용 파일만 컴파일한다.

**판정(현재 코드 사실)**: 이 워커풀도 CS(applier)에 링크되지 않는다.

### 그리고 범용 태스크 풀이 아니다

설령 링크된다 해도 형태가 맞지 않는다. 이 워커풀은 **네트워크 연결 처리 전용**이다.

- 태스크 단위가 함수객체가 아니라 연결 이벤트 메시지다: `connection_worker.hpp:108-128` `message_type { NEW_CLIENT, HANDOFF_CLIENT, TAKEOVER_CLIENT, SHUTDOWN_CLIENT, ... }`.
- 워커 루프는 epoll·eventfd·소켓 수신/송신을 돌린다: `:226` `cubsocket::epoll m_events`, `:296-307` `eventfd_*`, `:339-355` `handle_reception`/`handle_transmission`. 워커가 다루는 대상은 `context *`(= `css_conn_entry` 기반 클라이언트 연결, `:157`)다.
- coordinator는 연결을 워커 간에 재분배(hand-off)하고 워커 수를 자동 스케일하는 역할(`coordinator.hpp:315-323`)이지, 임의 계산 태스크를 커밋순서로 수거하는 장치가 아니다.

즉 "트랜잭션을 적용하고 결과를 커밋순서로 회수"하는 applier 흐름을 여기에 얹으려면 사실상 연결 처리 로직을 걷어내고 껍데기만 남겨야 한다. 재사용 이득이 없다.

## 후보 3 — `thread/` 나머지 (전수 확인 결과)

- `thread_daemon.*`, `thread_looper.*` : 단일 스레드를 주기적으로 도는 데몬(looper)이다. 워커 여러 개로 태스크를 분배하는 풀이 아니다.
- `thread_worker_pool_taskcap.*`, `thread_worker_pool_impl.*` : 후보 1의 구현체. 동일하게 SERVER_MODE 전용.
- `thread_entry_task.*`, `thread_task.hpp` : 태스크 추상만 제공. 풀이 아니며 컨텍스트가 `entry`.

새로운 CS_MODE용 범용 워커풀 추상화는 확인되지 않았다.

## 재사용 시 이득과 제약 정리

- **이득(가정: 링크 경계를 뚫었을 때)**: 워커 생성/소멸/동적 스케일·태스크 큐잉 같은 검증된 인프라를 재사용해 손수 만든 pthread 워커·링버퍼 코드를 줄일 수 있다. 다만 게이트(②)와 커밋순서 retire(③)는 어차피 직접 구현해야 하므로 줄어드는 코드는 "워커 스레드 살림 + 큐" 정도다.
- **제약(현재 코드 사실)**:
  1. **CS_MODE 링크 불가** — 두 풀 모두 서버 타깃 전용. applier가 쓰려면 스레드/커넥션 인프라의 빌드 가드를 CS까지 확장해야 하고, 이는 워커풀 재사용으로 얻는 이득보다 변경 범위가 크다.
  2. **결과 채널 부재** — 두 풀 다 태스크 결과를 커밋순서로 수거하는 경로가 없다. completed set·frontier·retire는 풀 위에 별도 로직으로 얹어야 한다.
  3. **park/게이트 부재** — "의존성 미충족이면 보류"를 풀이 대신 해주지 않는다. 제출 시점 제어(pending 큐 + 재판정)는 여전히 applier 몫이다.
  4. **컨텍스트 불일치** — 워커 컨텍스트가 서버 내부 `entry`이지 원격 서버로 붙는 클라이언트 세션이 아니다(후보 1). 후보 2는 아예 연결 처리 전용.

## 권고

1. **워커풀은 applier(CS) 내부에 유지한다.** 기존 SERVER_MODE 워커풀을 재사용하지 않는다. 재사용의 유일한 실질 이득(워커·큐 살림 코드 절감)은 빌드 경계 확장 비용과 게이트/retire를 어차피 직접 만들어야 하는 사실 앞에서 상쇄된다.
2. **동시성 자료구조만 라이브러리로 교체**하는 편이 이득이 분명하다. TBB 컨테이너(`tbb::concurrent_queue`)는 CS에서도 링크 가능하다(단, 현재 `cubridcs` 타깃은 TBB를 링크하지 않으므로 CMake에 링크·include 추가가 필요하다 — §분석2의 TBB 항목 참조). 손수 만든 링버퍼(`log_applier.c:400-416`)를 `tbb::concurrent_queue`로 바꾸면 락 경합·코드가 줄고, `connection_worker`가 이미 쓰는 패턴과 일치한다.
3. **게이트·커밋순서 retire·워커별 서버 세션은 정식 설계 요구사항으로 계속 applier 안에 둔다.** 이 부분은 어떤 풀을 쓰든 재사용 대상이 아니다.

### 미확인

- TBB 컨테이너로 큐만 교체했을 때의 실측 성능 차이는 이번 조사 범위(정적 코드)로는 확인하지 못했다. "미확인".
- SERVER_MODE 스레드풀을 CS까지 확장하는 변경의 실제 파급(전역 상태·매니저 초기화 의존성)은 코드 경로를 끝까지 따라가지 않았다. 재사용을 재고할 경우 별도 조사가 필요하다. "미확인".
