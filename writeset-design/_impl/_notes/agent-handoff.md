# 구현 작업 인수인계

이 문서는 AI와 구현자가 작업을 이어가기 위한 실행 메모다. 팀 공유용 설계의 일부가 아니다.

## ★ 개정된 작업 파이프라인 (2026-10-05 확정, governing plan)

전체 설계(마스터 writeset / 슬레이브 병렬 적용 / SYSOP_END fragment)는 그대로 두고, **작업 방식을 아래 순서로 바꾼다.** 지난 "선별 포팅"이 PoC의 안전 불변식을 반복 누락해 크래시(page 181 워커, page 217 리더)를 낸 것을 뒤집는 핵심이다 — 먼저 검증된 PoC를 통째로 올리고, 그 위에서 정식화·교체·구조화를 순서대로 쌓아 각 단계를 독립 검증한다.

1. **develop에 PoC 통째 이식 + 미구현분까지 반영** — PoC(`feature/writeset_error_skip @5277ab8ca`)를 develop(`c63a3b993`) 위에 squash로 올리고, PoC가 남긴 미구현 내용(SYSOP_END fragment = idea-3 등)도 PoC/백업 기준으로 다 반영한다. 신규 파일·모듈화 없이 **기존 파일 안에서 러프하게**, 단 정합성 예외(serial fallback, abort 시 fragment 유지, 라벨 없는 구로그 하위호환)는 유지하고 **슬레이브까지 end-to-end 동작**하게 구현한다.
   - 현재 상태: PoC 이식(`c8e315a5a`) + LOG_LSA_ATOMIC 적응(`46e7d29a6`) + [WSET] trace(`4f83ea2cc`) 커밋 완료. SYSOP_END fragment 이식 진행 중.
2. **PoC 내용 전수 정식화 리뷰** — 동작하는 베이스 위에서 아래 5종을 **먼저 목록+위치로 뽑아 사용자 검토 → 승인분만 수정**한다(읽기 우선, 안정 브랜치 5277ab8ca 기준 가능):
   - ① 하드코딩된 값
   - ② 예외처리 누락
   - ③ conf 파일로 받아야 할 것(현재 소스 상수/기본값 → 파라미터화)
   - ④ 시스템 상태·성능 기록(계측·로깅)
   - ⑤ 기존 리뷰(PR)에서 받은 피드백
3. **CS 임시코드 교체** — CS팀 작업이 완료되면 해당 코드만 바꿔치운다(다른 단계와 독립, 중간 끼어들기 가능).
   - **정정(2026-10-05)**: "PoC는 단일 클라이언트라 CS 교체 대상이 없다"던 앞선 판단은 틀렸다. PoC(`feature/writeset_error_skip`)에 멀티커넥션 워커 커밋들이 포함돼 있어(`db_restart_sub`로 워커 bring-up, `MULTI_CONN_TO_A_SERVER`, client globals 가드), 현재 베이스에 **CS팀 교체 대상 코드가 이미 들어와 있다.**
   - **squash 이식 때 CS 파일 충돌 0건**: `git merge --squash`는 3-way 머지라 PoC와 develop이 CS 파일(src/connection·communication·compat)의 서로 다른 구역을 고친 건 자동 병합됐다. (raw `git apply`였다면 충돌 가능 — 자동 머지가 조용한 드리프트를 숨길 수 있으므로 최종 보증은 벤치/실측.)
   - **교체 표면(좁음, 격리됨)**:
     - 호출 지점: `src/transaction/log_applier.c:2325` `db_restart_sub(sub_index)` (주석 "CS-team official sub-client bring-up"). 워커 bring-up 직렬화는 log_applier.c:833~838에 모여 있음.
     - 정의/선언: `src/compat/db_admin.c:995` `db_restart_sub()`, `src/compat/dbi.h:75` — 전부 `#if defined(CS_MODE) && defined(MULTI_CONN_TO_A_SERVER)` 가드 안.
     - 교체 시 바꿀 것 = `db_restart_sub` 구현체(db_admin.c)와 호출 규약뿐, applier 로직은 불변. 모듈화를 4단계로 미룬 덕에 래퍼 계층 없이 접점이 단순해 교체가 쉽다.
4. **모듈화 + 리팩토링** — 검증된 동작을 기준으로 마지막에 구조화한다.

파일 분리 자체가 과거 실패 원인이 아니다(재구현 시 불변식 소실이 원인). 모듈화는 동작이 검증된 뒤 4단계에서 한다.

## ★ 커밋/마무리 전략 (2026-10-07 확정 — 아래 "병렬 어플라이어 PR의 커밋 계획" 4커밋안을 대체)

작업 방식이 "PoC 통째 이식 + 베이스 커밋 위 증분"으로 바뀌면서 최종 이력 목표도 바뀐다. **최종 목표 = 관심사별 깔끔한 2~3 커밋**이고, 개발 중 자잘한 커밋은 체크포인트일 뿐 마지막에 squash로 접는다. (사용자가 여러 번 설명한 계획 — 재설명 방지용으로 여기 고정.)

### 최종 목표 이력
1. **마스터 writeset** — `d5f7c5213` (develop 위 1커밋, 이미 분리됨). 그대로 유지.
2. **슬레이브 병렬화** — 헤더 분리·applier·리네임·debug.hpp·큐 ops .cpp 등 **모든 병렬화 커밋을 하나로 squash**.
3. **CS 멀티커넥션** — db_restart_sub/MULTI_CONN 등 CS 커밋을 하나로 squash (별도 PR 가능).

### 개발 중 규칙 (지금)
- 리팩토링은 **HEAD 위 작은 체크포인트 커밋**으로 자유롭게 쌓는다(bisect·롤백용). 개수 무관.
- **각 커밋은 단일 관심사**(병렬화 파일만 / CS 파일만). 섞지 않는다. system_parameter처럼 혼재 파일은 `git add -p`로 줄 단위 분배.
- HEAD가 병렬화면 병렬화 리팩토링은 그 위 새 커밋으로 자동으로 병렬화 라인에 붙는다. 안 담긴 건 CS.

### 마지막 (푸시/PR 전)
- `git rebase -i d5f7c5213`(또는 develop)로 **순서 재배열(병렬화끼리 / CS끼리) 후 그룹 squash** → 2~3 커밋.
- 섞인 커밋이 없어 재배열·squash 충돌 0.

### 파일 단위 분리 기준
- **병렬화**: `log_applier.c/.h`, `log_applier_{worker,work,work_queue,result_queue,debug}.{hpp,cpp}`, writeset/drain 파라미터. (log_applier.c의 `db_restart_sub` 호출은 "applier가 CS를 쓰는 것"이라 병렬화로 분류 — CS 라이브러리 본체는 별개 파일.)
- **CS**: boot_cl, client_support, network_cl, area_alloc, db_admin(db_restart_sub 본체), transaction_cl, work_space, object_*, locator_cl 등 ~55파일 + CMakeLists `-DMULTI_CONN_TO_A_SERVER`.

### 현재 이력 (feature/CBRD-27508-parallel-applylogdb-writeset, develop 위, 전부 로컬·미푸시)
```text
d5f7c5213  마스터 writeset            ① (그대로)
65f5e898e  모듈 헤더 4개      ┐
ae2868c98  슬레이브 applier   │  ② 병렬화 (체크포인트들)
3d53ca497  CS 멀티커넥션      ← ③ CS (현재 ② 사이에 interleave)
95fa11acd  debug.hpp          │
e16f4177d  큐 ops → .cpp      ┘  (HEAD)
```
- interleave 상태라 PR 가를 땐 rebase로 ②끼리, ③끼리 모아 각각 squash.
- 복구점 태그 `wip/pre-base`(= 65f5e898e). 베이스 되돌리려면 `git reset --soft wip/pre-base`.
- drain 파라미터는 제거, 로직은 always-on(la_drain_enabled→true)으로 둠(별도 결정분).

## 설계·조사 문서 위치

- [마스터 구현 설계](../01-master-implementation-design.md): 키 수집과 history·커밋 경로
- [슬레이브 구현 설계](../02-slave-implementation-design.md): coordinator·worker와 queue 생명주기
- [개발자 테스트](../04-developer-test.md): 검증 방법과 테스트 시나리오
- `04-cs-worker-pool-analysis.md`: CS 워커풀 재사용 조사

이전 초안과 작업 계획은 Git 이력에서 확인한다.

## 작업 원칙

- 실제 코드를 기준으로 공유용 설계를 갱신한다.
- 목표는 PoC 코드를 문자 그대로 옮기는 것이 아니다. PoC에서 검증한 핵심 병렬 동작은 보존하되 end-to-end 활성화 전에 bounded backpressure, ABORT 순서, item이 있는 `SYSOP_END`, worker별 독립 DB session, gap-free 완료 frontier, restart·`required_lsa`·drain·오류 경로를 정식 설계와 테스트로 보강한다. PoC에서 검증하지 않은 제한을 최종 설계로 간주하지 않는다.
- 브랜치명, 커밋 해시, 임시 행 번호와 작업 순서는 `_notes`에만 기록한다.
- 구현 판단이 바뀌면 공유용 설계와 검증 계획을 함께 수정한다.
- 성능 측정용 로그와 임시 계측은 정식 구현 설계에서 제외한다.
- 기존 한글 파일은 실제 파일명을 확인한 뒤 수정하고 임의로 재생성하지 않는다.

## 코드 작성·리뷰 기준

- 함수 이름과 실제 역할을 일치시키고, 새 책임으로 함수가 길어지면 별도 함수나 모듈로 분리한다.
- 주석은 코드만으로 알 수 없는 이유와 불변식을 설명한다. 긴 동작 설명은 피하고 래퍼보다 실제 본체에 우선 배치한다.
- 오류를 조용히 무시하지 말고 호출자가 처리할 수 있도록 반환한다. 같은 검증은 여러 계층에서 반복하지 않는다.
- TBB 같은 라이브러리 세부 API는 모듈 경계에서 감싸 호출부로 퍼지지 않게 한다.
- 슬레이브 worker는 worker별 queue를 두지 않는다. coordinator가 용량이 고정된 공용 task queue와 자동 성장하는 공용 result FIFO를 소유하고, worker는 두 queue의 비소유 포인터만 보관한다.
- worker와 queue는 one-shot 객체다. 동일 객체의 `start → stop → start` 재사용을 지원하지 않으며, role change는 drain 뒤 종료한다.
- 설계 문서와 코드에서 같은 개념에는 같은 용어를 사용한다.
- 기능 초안과 리뷰 정제 변경을 별도 커밋으로 남긴다. 두 커밋의 diff에서 함수 구성, 주석, 오류 처리 기준을 추출해 다음 모듈, 특히 worker 구현에 먼저 적용한다.
- PoC에서 하드코딩한 worker 수와 메모리 한도는 정식 구현에서 시스템 파라미터로 받는다. worker queue 용량과 전체 미완료 task 상한의 관계, 기본값·상한과 기동 시 메모리 계산을 production coordinator 통합 전에 확정한다.

## 슬레이브 어플라이어의 점진적 모듈화 원칙

`feature/writeset_error_skip`의 병렬 어플라이어 코드를 구현 근거로 사용하되 그대로 옮기지 않는다. 성능 측정·임시 디버깅·복구 실험 코드는 분리하고, `_impl`의 현재 설계와 develop의 실제 호출 경로를 기준으로 필요한 기능만 다시 구성한다.

첫 단계에서는 거대한 `log_applier.c`의 기존 구현을 한꺼번에 이동하지 않는다. 헤더로 모듈의 공개 경계를 먼저 선언하고 기존 함수 본체는 당분간 `log_applier.c`에 유지한다. 새로 추가하는 함수는 처음부터 해당 모듈의 `.cpp`에 구현한다. 리뷰가 끝난 기존 함수부터 후속 변경에서 모듈 `.cpp`로 옮긴다.

```text
기존 함수
  모듈 .hpp에 공개 인터페이스 선언
  구현은 log_applier.c에 유지

신규 함수
  모듈 .hpp에 공개 인터페이스 선언
  같은 모듈 .cpp에 구현
```

헤더에는 다른 모듈이 호출하는 공개 함수만 선언한다. 기존 내부 helper를 모두 외부 심볼로 만들지 않으며, 모듈 내부에서만 사용하는 함수는 계속 `static`으로 둔다. 기존 함수를 공개 인터페이스로 승격할 때만 `static`을 제거한다.

공통 자료형과 의존 방향은 다음 원칙을 따른다.

- task·result·통계처럼 모듈 사이에 전달되는 자료형은 가장 아래의 공통 헤더에 둔다.
- 포인터만 필요한 기존 자료형은 전방 선언하고, 필드 접근이 필요한 구현만 전체 정의를 포함한다.
- gate는 실행 가능 여부만 판정하고 worker 선택이나 queue 조작을 직접 하지 않는다.
- worker는 task를 적용하고 result를 반환할 뿐 gate와 coordinator 상태를 직접 참조하지 않는다.
- coordinator가 gate 판정, 공용 worker queue enqueue, result 반영과 pending 재판정을 중재한다. 특정 worker index를 선택하지 않는다.
- 신규 `.cpp`는 `la_Info` 같은 기존 전역 상태에 직접 결합하지 않고 필요한 값이나 context를 인자로 받는다.
- 헤더 상호 include로 순환 참조를 해결하지 않는다. 공통 자료형 → worker/gate → coordinator의 단방향 의존을 유지한다.

초기 모듈 경계는 다음 네 영역을 기준으로 한다.

- `log_applier_task.hpp`: `LA_APPLY_TASK`, `LA_APPLY_RESULT`, 적용 통계 등 전달 자료형
- `log_applier_queue.hpp`: 공용 task/result queue의 자료구조와 enqueue/dequeue 인터페이스
- `log_applier_worker.hpp`: worker 초기화·시작·실행·종료
- `log_applier_scheduler.hpp`: dispatch 순서 등록, result 대응, retire와 완료 경계
- `log_applier_gate.hpp`: dependency 판정, pending과 frontier

파일 이름과 최종 공개 함수 수는 실제 호출 관계를 확인한 뒤 확정한다. 자료형이나 함수가 한 모듈에서만 사용된다면 별도 헤더로 노출하지 않는다.

## 병렬 어플라이어 PR의 커밋 계획

이 작업은 하나의 PR로 올린다. 너무 잘게 나눈 커밋마다 설계 문서를 반복 수정하지 않도록 코드·테스트·해당 설계 변경을 다음 네 개의 논리 커밋으로 묶는다. 각 커밋은 단독으로 빌드되어야 하며, 그 커밋에서 구현한 범위의 설계 문서를 함께 포함한다.

1. **모듈 경계와 worker·queue 생명주기**
   - 공통 task/result 자료형과 worker 공개 인터페이스
   - worker context, task/result queue, 초기화·시작·정지·join
   - 부분 초기화 실패의 역순 정리
   - CMake의 신규 `.cpp` 등록
   - `_impl`의 모듈 책임·생명주기 설계 갱신
   - 상세 설계: [슬레이브 구현 설계](../02-slave-implementation-design.md)의 worker와 queue 생명주기

2. **task dispatch·worker 적용·완료 순서 관리**
   - coordinator의 transaction task 조립과 worker 전달
   - worker의 기존 적용 경로 재사용과 result 반환
   - in-flight list, result 대응, completed set과 frontier 계산
   - task·`LA_APPLY` 슬롯 소유권 및 retire 시점
   - 관련 구현 설계와 단위·통합 테스트
   - production coordinator의 병렬 적용 경로는 아직 활성화하지 않고 내부 테스트로 실행 기반만 검증

3. **writeset 라벨·dependency gate·pending**
   - `WSET_LABEL` 디코딩과 task 연결 검증
   - 라벨이 요구하는 개별 완료·연속 완료 dependency 판정
   - 즉시 dispatch, pending 보류, result 수거 후 재판정
   - 라벨 누락·중복·trid 불일치 처리
   - `LOG_SYSOP_END`를 별도 task 경계로 처리하고 마스터 sysop 조각과 슬레이브 task를 함께 연결
     - sysop 시작 시 writeset 조각 경계 보존
     - 복제 항목이 있는 sysop은 `WSET_LABEL → LOG_SYSOP_END`를 기록하고 SYSOP_END LSA로 조각 publish
     - 게시한 조각은 바깥 writeset에서 제거하고, 복제 항목이 없으면 라벨·history를 게시하지 않음
     - reader는 sysop item 조각을 바깥 목록에서 분리해 task가 소유하게 하고 SYSOP_END LSA를 task 좌표로 사용
     - 같은 `trid`의 다음 sysop 또는 최종 COMMIT은 직전 sysop task 완료를 기다림
     - 바깥 ABORT는 이미 task가 된 독립 sysop item을 폐기하지 않음
     - In-flight List는 같은 `trid` 전체가 아니라 확정한 commit node 하나만 retire
   - `LOG_SYSOP_END` result도 completed set과 frontier에 포함하되 최종 COMMIT 전에는 바깥 `LA_APPLY` 슬롯을 반환하지 않음
   - `db_serial`, `INCR()`·`DECR()`, checksumdb의 NEED_FLUSH 경로를 sysop 시나리오로 검증
   - 마스터·슬레이브 전달 규약과 gate 설계 갱신
   - 이 커밋에서 gate가 연결된 뒤에만 production coordinator의 병렬 적용 기능을 활성화

4. **LSA 영속화·재시작·종료와 failover 검증**
   - 연속 완료 경계에 따른 `committed_lsa` 전진과 apply-info 영속화
   - `required_lsa`, 재독, 이미 완료된 task 판정
   - 정상 종료, 오류 종료, role change drain
   - `LOG_SYSOP_END` 완료 표식·재독·error-skip 창을 일반 COMMIT과 같은 복구 규칙으로 검증
   - end-to-end·장애·성능 검증과 최종 설계 동기화

리뷰 과정의 단순한 이름·주석·함수 분리는 해당 논리 커밋을 완료하기 전에 반영한다. 이미 공유된 커밋의 의미를 바꾸는 후속 수정만 별도 정제 커밋으로 남기며, 기계적인 리뷰 수정 때문에 커밋 수를 늘리지 않는다.

### 구현 완료 후 통합 리뷰

기존 페르소나 리뷰와 미해결 리스크는 네 구현 커밋에 미리 흩어 넣지 않는다. 커밋 4까지 어플라이어 흐름을 완성한 뒤 현재 코드 전체에 다시 대조하여, 여전히 유효한 정확성·복구·호환성·성능 항목을 한 번에 검토한다. 단순히 이전 리뷰 문구를 옮기지 않고 완성된 호출 경로와 테스트 결과로 재검증한다.

리뷰 수정은 가능하면 PR을 올리기 전에 해당 논리 커밋에 fixup하여 최종 이력을 네 커밋으로 유지한다. 이미 공유돼 이력을 고칠 수 없다면 코드·테스트·설계 문서를 포함한 별도 리뷰 정제 커밋 하나로 묶는다. 기존 리뷰 문서는 이 단계의 입력 backlog로 보존한다.

## 2026-10-02 인수인계: SYSOP 영향 검증

### 코드 위치와 상태

- 저장소: `/home/youngjun/Workspace/cubrid-applier`
- 브랜치: `feature/CBRD-27508-parallel-applylogdb-writeset`
- HEAD: `441aafed9` (`[CBRD-27508] Complete multi-connection client support for applylogdb`)
- 주요 선행 커밋:
  - `a45174afd`: 병렬 applylogdb 실행
  - `d7bbd2765`: 마스터 writeset dependency 생성
  - `1f7adb92d`, `441aafed9`: worker sub-client와 multi-connection 보완
- 작업 트리는 dirty 상태다. 사용자 변경과 현재 검증 변경이 함께 있으므로 `reset`, `checkout --`, 일괄 삭제를 하지 않는다.
- 확인 당시 변경 파일: `src/transaction/log_applier.c`, `src/transaction/log_applier_worker.cpp`, `src/base/system_parameter.c`, `src/broker/broker.c`, `util/CMakeLists.txt`, `cubrid-cci` 및 Gradle JVM crash log.

현재 `log_applier.c`의 SYSOP 기준은 다음과 같다.

```text
LOG_SYSOP_END와 LOG_COMMIT은 develop의 공통 case 경로 유지
LOG_SYSOP_END → coordinator의 기존 commit-list/apply 경로
LOG_COMMIT    → 병렬 worker dispatch
SYSOP 전역 drain 없음
SYSOP을 무시하는 별도 break 없음
추가 동작은 ha_writeset_trace_level 조건의 로그뿐
```

이전 구현에 있던 `la_parallel_prepare_serial_sysop()` 선언·구현·호출은 작업 트리에서 제거했다. 다시 넣지 않는다. 현재 목적은 해결안 구현이 아니라 develop의 SYSOP 경로가 병렬 COMMIT과 공존할 때 생기는 영향을 먼저 증명하는 것이다.

### 현재 추적 로그

- 마스터 SYSOP append 정보
- 슬레이브 SYSOP 경계와 final COMMIT 시 item 분포
- coordinator의 `trid`별 apply 시작·종료
- coordinator session의 flush·commit 시작·종료
- worker의 `trid`·worker index·dispatch sequence별 apply·flush·commit
- reader의 WSET label, dependency와 최종 COMMIT 조립

`serial`이라는 로그 용어는 혼동을 피하기 위해 `coordinator`로 바꿨다. coordinator session의 flush·commit은 worker들이 flush한 여러 트랜잭션을 합치는 것이 아니다. worker는 각자 별도 session에서 commit한다. coordinator 쪽에는 develop 경로로 처리된 여러 SYSOP `trid`가 주기적 `la_log_commit()` 전까지 함께 누적될 수 있다.

로그의 `batch`용 전역 sequence는 추가하지 않았다. coordinator 경로는 한 스레드에서 순서대로 출력되므로 `coordinator apply`의 `trid`·`boundary_lsa`와 뒤의 flush·commit을 시간 순서로 연결한다.

`ninja -C build_x86_64_release cubridcs -j2`로 현재 `log_applier.c`의 증분 컴파일과 링크는 성공했다. 전체 패키지 빌드·설치·HA 재기동은 아직 하지 않았다.

### HA bench 위치와 상태

- 저장소: `/home/youngjun/Workspace/ha_bench-sysop-random`
- 기반 커밋: `4d74cff`
- SYSOP 관련 파일은 아직 대부분 미커밋이다.
  - `bin/run_sysop_random.sh`
  - `lib/sysop_random.sh`
  - `sysop_random/`
  - `tests/test_sysop_random.py`
  - `README.md`, `ha-bench`, `.gitignore`
  - 로컬 실행 설정 `config/local.json`

`config/local.json`의 비밀값은 문서에 복사하지 않는다. 현재 비밀값을 제외한 핵심 설정은 다음과 같다.

```text
master DB: testdb, user=dba, local host
slave DB : testdb, user=dba, host=youngjun4
wait interval: 0.1초
wait timeout : 300초
```

마지막 테스트 당시 환경은 다음과 같다.

```text
youngjun3: master/active
youngjun4: slave/standby
설치 경로: /home/youngjun/CUBRID-11.5.0.2621-441aafe-Linux.x86_64
cubrid.conf: max_clients=100
cubrid.conf: ha_writeset_trace_level=2
```

소스의 `ha_writeset_trace_level` 기본값도 현재 작업 트리에서 임시로 2로 변경돼 있다. 정식 기본값으로 확정한 변경이 아니라 검증 편의를 위한 미커밋 변경이므로 PR 전에 재검토한다.

global SSH 설정 문제를 피하기 위해 이전 실행에서 `/tmp/wset-test-bin/ssh` 래퍼를 사용했다. 새 세션에서는 래퍼 존재와 `PATH` 적용 여부를 먼저 확인한다. runner는 다음 환경 변수로 로그 위치를 덮어쓸 수 있다.

```text
SYSOP_MASTER_LOG
SYSOP_SLAVE_SSH_HOST
SYSOP_SLAVE_ENV
SYSOP_SLAVE_LOG_GLOB
```

### 기존 실행 결과와 해석 제한

```text
PASS:
/home/youngjun/Workspace/ha_bench-sysop-random/sysop_runs/20261002T070050-424242-1277866
- profile=parallel-mix, seed=424242, transactions=12, clients=4
- master/slave 데이터 일치, fail_counter delta=0
- replication-bearing SYSOP 4개, slave 경계 4개 대응

APPLY_ERROR:
/home/youngjun/Workspace/ha_bench-sysop-random/sysop_runs/20261002T070201-9021001-1279060
- profile=random, seed=9021001, transactions=50
- 최종 master/slave 데이터는 일치
- fail_counter delta=88
- replication-bearing master SYSOP 5개, slave SYSOP 관측 9개
```

두 결과 모두 worker drain이 포함된 이전 배포 바이너리로 실행했다. no-drain SYSOP 영향의 증거가 아니다. APPLY_ERROR의 `fail_counter=88`도 현재 코드에서 재현하기 전에는 원인을 단정하지 않는다.

### 재실행 명령

먼저 현재 소스를 전체 빌드·패키징하고 두 노드에 같은 빌드를 배포한 뒤 버전과 설정을 확인한다. 이후 다음 순서로 실행한다.

```bash
cd /home/youngjun/Workspace/ha_bench-sysop-random

# 독립 키를 사용하는 작은 병렬 혼합
./ha-bench sysop-random \
  --config config/local.json \
  --profile parallel-mix \
  --seed 424242 \
  --transactions 12 \
  --clients 4 \
  --tx-weights long=50,single-explicit=0,autocommit=50 \
  --long-statements 5:20 \
  --long-delay-ms 0:20

# 기존 실패 SQL의 정확한 재실행
./ha-bench sysop-random \
  --config config/local.json \
  --replay sysop_runs/20261002T070201-9021001-1279060
```

필요하면 PASS 실행도 `--replay sysop_runs/20261002T070050-424242-1277866`으로 그대로 재현한다.

### 다음 작업과 판정 순서

1. 현재 dirty diff를 보존하고 전체 빌드한다. Gradle ANTLR worker가 `Broken pipe`/자원 부족으로 실패한 이력이 있으므로 무조건 clean build부터 하지 않는다.
2. 두 노드에 같은 패키지를 배포하고 `max_clients`, `ha_writeset_trace_level`, HA role을 확인한다.
3. `parallel-mix`를 실행해 기본 병렬 적용과 SYSOP 로그 연결을 확인한다.
4. 기존 APPLY_ERROR run을 exact replay하여 `fail_counter=88`을 재현한다.
5. 시간 순으로 다음을 연결한다.

```text
master SYSOP append
→ slave coordinator apply(trid, SYSOP_END LSA)
→ 동시에 실행된 worker apply/flush/commit
→ coordinator flush/commit
→ 같은 trid의 final worker commit
→ master/slave 데이터와 fail_counter
```

6. 문제가 재현된 뒤에만 SYSOP task화, 같은-trid 순서, coordinator 폴백 등 해결안을 비교한다. 검증 전에 drain/barrier나 SYSOP 무시 경로를 다시 넣지 않는다.
7. 중간 상태·재시작 문제가 의심되면 worker 미완료 상태에서 coordinator commit 직후 프로세스를 종료하는 별도 장애 실험을 추가한다. 이 실험 전에는 `committed_lsa` 재시작 hole을 확정 사실로 쓰지 않는다.

## 2026-10-02 인수인계: 안 3 마스터측 1차 구현

### 코드 위치와 상태

- 격리 워크트리: `/home/youngjun/Workspace/cubrid/.claude/worktrees/agent-a0751035226db3892`
- base: `441aafed9`(feature/CBRD-27508-parallel-applylogdb-writeset HEAD). 미커밋.
- 변경 파일 5개(마스터 측만, 슬레이브 log_applier.c 무변경): `src/query/serial.c`, `src/transaction/log_impl.h`, `src/transaction/log_manager.c`, `src/transaction/writeset.cpp`, `src/transaction/writeset.hpp`.
- 검증: 3개 TU(`serial.c`, `log_manager.c`, `writeset.cpp`) `-fsyntax-only` 통과(워크트리 헤더 기준). 전체 빌드·링크는 미수행.

구현 범위는 10장 §13.6의 1차 범위(마스터 측 네 가지)다. serial 키 수집, sysop 경계 probe/publish/WSET_LABEL, 조각 키 바깥 writeset 제거, serial 외 NEED_FLUSH는 기존 동작 유지.

### 추가된 심볼

- `wset_find_fragment_dependency` / `wset_publish_fragment_to_history` / `wset_discard_fragment` (writeset.cpp/hpp) — 조각 `[fragment_begin, end)` 범위의 probe·publish·제거.
- `log_append_wset_label_and_sysop_end` / `log_append_sysop_end_internal(with_lock, sysop_end_lsa_out)` (log_manager.c) — WSET_LABEL과 SYSOP_END 원자 기록, 기존 `log_append_sysop_end`는 wrapper로 유지.
- `log_topops_addresses::wset_mark` (log_impl.h) — sysop 시작 시 writeset 키 개수, 조각 경계.
- 에러코드 `ER_HA_WRITESET_KEY_BUILD_FAILED`(-1383). error_code.h·ER_LAST_ERROR(-1384)·en/ko cubrid.msg 갱신됨. dbi_compat.h에는 없음(SERVER 전용 에러라 클라이언트 복사본 불필요로 판단).

### 리뷰 때 짚어야 할 지점

1. `serial_Cached_btid` 초기화 시점. **확인 완료 — 정상.** `serial_cache_index_btid()`(serial.c:1787)가 `boot_restart_server()`(boot_sr.c:2540, `#if SERVER_MODE`)에서 기동 시 한 번 채우고 non-NULL을 assert한다. 정상 기동 마스터에서는 조각 경로를 탄다. commit-order 폴백은 백업 복구 중(workspace manager 미가용)·SA_MODE·기동 시 캐시 실패 같은 예외에서만 발생하며, 그 경우 보수적 직렬 처리가 올바른 동작이다.
2. 새 `wset_*` 함수 3개의 본체 로직. **확인 완료 — 정상, 단 가정 1건 명기.** `wset_find_fragment_dependency`는 `wset_find_dependency_in_range(tdes, fragment_begin, ...)`로 조각 범위만 probe하고 overflow·빈 범위를 방어한다. `wset_publish_fragment_to_history`는 `wset_publish_keys(begin, end, lsa)`로 `[fragment_begin, end)`만 SYSOP_END LSA로 publish한다. `wset_discard_fragment`는 `erase(begin+fragment_begin, end())` 즉 **tail 전체를 지운다**. 이는 "조각 sysop 안에서는 serial 키만 수집되어 조각이 항상 writeset 꼬리에 있다"는 가정에 의존한다. serial sysop은 serial만 수집하므로 현재 유효하나, 향후 같은 sysop에서 비-조각 키를 수집하는 코드가 생기면 깨진다. 이 가정을 주석에 명기할 것.
3. WSET_LABEL과 SYSOP_END 원자성. **확인 완료 — 정상.** `log_append_wset_label_and_sysop_end`가 `prior_lsa_mutex.lock()` 뒤 `log_append_wset_label_with_lock`(기존 커밋 경로가 쓰는 동일 helper 재사용) + `log_append_sysop_end_internal(with_lock=true)`를 호출하고 unlock한다. `with_lock=true`면 내부가 `prior_lsa_next_record_with_lock`을 써 이중락이 없다. 둘이 같은 락 구간에서 인접 기록된다.
4. 조각 조건 정확성. **확인 완료 — 정상.** serial 외 NEED_FLUSH 생산자(INCR/DECR, checksumdb)에는 이번에 수집 호출을 넣지 않았으므로 그들의 sysop은 `wset_hashes`에 키를 안 넣는다. 따라서 `tdes->wset_hashes.size () > fragment_begin`이 false가 되어 조각 경로를 타지 않고 기존 `log_append_sysop_end`로 간다. serial만 조각화된다.
5. trace 로깅이 ha_writeset_trace_level 가드 안에서만 계산되는지. **확인 완료 — 정상.** 새 조각 trace(`[WSET] SYSOP master fragment ...`)는 기존 `>= 1` 가드 블록 안에 있고 `fragment_published`일 때만 출력한다. serial.c 수집 trace도 가드 안. 새 가드 밖 카운트 루프는 추가하지 않았다.

### 마스터만 배포 시 슬레이브 동작 (확인 완료 — 안전, 단 이득 없음)

슬레이브(log_applier.c)는 미변경이다. 마스터만 배포하면 WSET_LABEL이 SYSOP_END 앞에도 나온다. 슬레이브의 `la_wset_label_*`는 단일 슬롯(last-writer-wins)인데, 마스터는 모든 COMMIT에서 `log_append_repl_info_and_commit_log`가 WSET_LABEL을 무조건 내보내므로(빈 writeset이어도) 조각 라벨은 COMMIT 직전 commit 라벨로 항상 덮인다. 슬레이브는 COMMIT·ABORT에서 슬롯을 소비·clear한다(log_applier.c:6837, 6845, 6909). 따라서 조각 라벨이 COMMIT task로 새지 않는다. SYSOP_END는 현재 coordinator 직렬 경로로 serial을 적용하고(조각 task화 없음), 조각 dependency(SYSOP_END LSA 좌표)는 슬레이브가 무시한다. 결과적으로 마스터만 배포한 상태의 슬레이브 serial 처리는 기존 혼합 상태와 동일하며 회귀가 없다. 다만 안 3의 슬레이브 측 병렬 serial 이득은 슬레이브 패스 전까지 나타나지 않는다. COMMIT task dependency는 사용자 행 키(COMMIT 좌표)에서만 오고 serial 조각 좌표를 가리키지 않으므로, 슬레이브가 등록하지 않은 SYSOP_END 좌표에 매달리는 일은 없다.

### 커밋 분리

CS 이식(multi-connection sub-client)과 별도 커밋. CS 이식분은 CS팀 정식 코드로 교체될 임시 코드이므로, serial 조각 커밋이 CS 이식에 의존하지 않도록 구성한다(10장 §13.6).

### 다음 작업

- 위 리뷰 지점 1~5를 코드로 확정한 뒤 수정.
- 전체 빌드·링크 검증(cubridsa/cubrid).
- 슬레이브 패스: reader의 조각 task 조립, 같은 trid 순서 gate, 조각 단위 재시작 완료표식(미확정 지점).

## 2026-10-02 인수인계: 안 3 슬레이브측 구현 + 검증

같은 워크트리(`/home/youngjun/Workspace/cubrid/.claude/worktrees/agent-a0751035226db3892`)에 마스터 위로 슬레이브 변경을 얹었다. 미커밋. 변경 파일에 `src/transaction/log_applier.c`(약 259줄) 추가.

### 추가 심볼
- `la_detach_sysop_fragment` — SYSOP_END 경계(`lsa <= fragment_lsa`) 이하 item을 바깥 LA_APPLY에서 분리해 독립 조각 슬롯으로 이동.
- `la_parallel_schedule_fragment_task` / `la_parallel_schedule_serial_fragment` — 조각을 독립 task로 조립·스케줄.
- `la_apply::last_sysop_fragment_lsa` — 그 트랜잭션의 최근 조각 SYSOP_END 좌표. 최종 COMMIT task가 이 조각 완료를 기다린다.

### 검증 결과 (main이 코드로 확인)

- 조각 분리 경계 정합성. **정상.** 일반 DML repl은 `LOG_REPL_COMMIT_NEED_FLUSH`(replication.c:427)라 COMMIT 시 기록되어 lsa가 SYSOP_END보다 뒤다. serial만 flush mark 안에서 `LOG_REPL_NEED_FLUSH`(replication.c:489,595)라 SYSOP_END에 기록된다. 따라서 `la_detach_sysop_fragment`의 `lsa <= SYSOP_END` 경계가 serial만 정확히 잡고 일반 DML은 바깥에 남는다.
- 같은 trid 순서. **정상(보수적).** 최종 COMMIT task는 라벨 dependency와 `last_sysop_fragment_lsa` 중 max를 dependency_seq로 쓰고 `dependency_is_ref=true`로 설정해, frontier가 조각 좌표까지 전진할 때까지 기다린다. frontier 대기라 필요 이상으로 강하지만 안전하다.
- worker 조각 독립 커밋. **정상.** `should_commit = (LOG_COMMIT || LOG_SYSOP_END)`로 조각 task도 flush+db_commit한다.
- abort 조각 보존. **정상.** 조각 item을 별도 슬롯으로 미리 분리하므로 바깥 ABORT가 조각을 폐기하지 않는다.
- 재시작(E). **보수적 구현 + 미구현 명시.** committed_lsa 경계만 재사용(la_apply_repl_log가 SYSOP_END 좌표 <= last_committed_lsa면 skip). "조각은 커밋됐으나 최종 commit 전 크래시 시 committed_lsa가 조각 좌표 아래면 재시작에 조각 재적용" 구멍을 주석에 인정하고 per-coordinate 완료표식을 TODO(CBRD-27508)로 남겼다. serial 재적용은 절대값·로그순서라 멱등에 가까워 실해가 낮다. 중첩 sysop 완료표식 유일성·안쪽 abort 롤백은 미결(10장 §13.6).
- 구문 검증. `log_applier.c` `-fsyntax-only` 통과(워크트리 헤더 기준). clangd의 PRM_ID_HA_WRITESET_TRACE_LEVEL 미선언은 스테일 오탐.
- 범위. 집중됨. 신규 함수 3개 + 타겟 수정(worker/reader/schedule/구조체). 과잉 이식 없음.

### ★ 사용자 결정 필요 — drain 분기

비-조각 SYSOP_END는 여전히 `la_parallel_prepare_serial_sysop()`(drain)으로 간다. 이 함수는 committed HEAD(441aafed9)에 원래 있던 베이스 코드이고 에이전트가 그대로 유지했다. 그러나 사용자 측정 트리(cubrid-applier, 미커밋)에서는 이 drain을 제거했다. 즉 워크트리 베이스(drain 있음)와 측정 트리(drain 제거)가 갈린다.

- 결정 1: 정식 베이스를 drain 있는 committed HEAD로 둘지, 사용자의 drain 제거를 반영할지.
- 결정 2: 현재 drain은 복제 item 없는 빈 B-tree sysop 포함 모든 비-조각 SYSOP_END에 걸려 과도하다. 정식 안 3은 INCR/DECR·checksumdb를 마스터에서 `wset_overflow` 커밋오더 폴백으로 보내는 것이다(아직 마스터 미구현). 그걸 구현하면 슬레이브의 일괄 drain을 제거하고, 폴백된 트랜잭션만 커밋오더로 안전 처리할 수 있다. 현재는 그 마스터 폴백이 없어 슬레이브 drain에 의존한다.
- long transaction serial은 `!apply->is_long_trans` 조건으로 조각 경로를 안 타고 drain으로 간다(보수적).

### 다음 작업
- drain 결정(위) 반영.
- INCR/DECR·checksumdb 마스터 overflow 폴백 구현(그 후 슬레이브 일괄 drain 제거 가능).
- 마스터+슬레이브 전체 빌드·링크 검증.
- 재시작 완료표식(E) 정식 구현 또는 commit-plan 4 복구창과 통합.
- `wset_discard_fragment`의 tail-erase 가정 주석 보강.

## ★ 진행 중 테스트 (2026-10-05, 세션 끊김 대비 복구 포인터)

PoC 베이스 + idea-3 fragment 이식(커밋 05365ab1e)의 **장기 병렬 fragment 검증** 실행 중. nohup detached라 세션 죽어도 완주, 결과는 디스크 영속. 돌아오면 아래로 분석 재개.

- **run_dir**: `/home/youngjun/Workspace/ha_bench-sysop-random/sysop_runs/20261005T053433-20261006-2472255`
- **CUTOFF2(이 이후 로그만 분석)**: `scratchpad/sysop_cutoff2.txt` 참조 (대략 10/05 05:34 KST 로그tz)
- **config**: random, clients=4, tx=400, tables=4, long-statements 10:25, long-delay 5:40ms, insert75/dependent75, seed=20261006
- **배포본**: `CUBRID-11.5.0.2621-05365ab-Linux.x86_64` (양 노드), ha_writeset_trace_level=2(소스기본)
- **슬레이브 applier 로그**: youngjun4 `$CUBRID/log/testdb@localhost_applylogdb_testdb_youngjun3.err`
- **마스터 trace 위치**: youngjun3 `$CUBRID/log/server/testdb_*.err` (cub_server.err 아님 — 주의)

**완료 후 분석 체크리스트**:
1. 정합성: run_dir/verdict.json state — 전 테이블 master=slave rows·digest, serial 값 일치
2. 동일 tx 다중 fragment: 한 trid에서 `SYSOP slave fragment assemble` 여러 건 + wset_mark range-split
3. 동시 fragment 경합: 서로 다른 trid fragment 동시 적용 + 외부커밋 is_ref 대기(park status=2→release status=1)
4. 워커 타임라인/동시성 (parse_timeline.py 재사용, dur≥1s 격리)
5. 크래시 0 (CUTOFF2 이후 corrupted/ERROR grep)

**알려진 도구 갭**: sysop-random verdict가 INCONCLUSIVE_TRACE_MISSING로 뜸 — validate.py가 신 어휘(`SYSOP slave fragment assemble`)를 slave sysop event로 집계 못 함(옛 `phase=sysop_end` 기대). 복제 결함 아님. 수동 trace+정합성으로 판정. 추후 validate.py 파서 보강 결정 대기.

## SYSOP_END fragment 검증 로그 보관 위치 (2026-10-06)

병렬 fragment 검증(seed 20261006, clients=4, 400tx, 베이스 CUBRID-11.5.0.2621-05365ab) 결과 로그를 홈 디렉토리에 영구 보관. **HA 재실행 없이 이 파일들만으로 재확인 가능**(단 코드 변경 후에는 새 HA 필요).

- **보관 경로**: `~/sysop_end_verify_20261006/` (= `/home/youngjun/sysop_end_verify_20261006/`)
  - `verdict.json` — 정합성(ok=true, 4테이블 master=slave digest 일치 = 무손실)
  - `slave.raw.log` — `SYSOP slave fragment assemble` 149건(동일 tx 다중 9), 외부커밋 is_ref 대기 96건(status=2 park→status=1 release), `may be corrupted` 0
  - `master.raw.log` — `SERIAL master collect` + `master sysop_end repl=1 writeset=untouched`
  - `correlated.json`, `manifest.json`(워크로드 재현), `README.txt`(재확인 grep)
- **원본 run_dir**: `/home/youngjun/Workspace/ha_bench-sysop-random/sysop_runs/20261005T053433-20261006-2472255`
- **시각화(볼트)**: `_impl/_notes/figures/sysop-worker-timeline-20261006.png`(전체 워커 타임라인), `sysop-fragment-zoom-20261006.png`(fragment 경합 ms 확대 — serial 순서보장 중 타 트랜잭션 무영향)
- **재확인 핵심 grep**:
  - `grep -c 'SYSOP slave fragment assemble' slave.raw.log`
  - `grep -c 'status=2 dependency_is_ref=1' slave.raw.log` (fragment 대기)
  - `grep -c 'may be corrupted' slave.raw.log` (0이어야)

## ★ 실패 경로 확인 테스트를 만들어야 함 (2026-10-07)

10-07 리팩토링 중 실패·종료 경로의 동작을 바꾼 커밋들이 있는데, 빌드만 확인했고 런타임으로는 한 번도 타 보지 않았다. 일반 HA 테스트(정상 경로)로는 이 경로들이 거의 실행되지 않으므로, **실패를 일부러 만드는 테스트를 따로 만들어야 한다.**

| 확인할 경로 | 관련 커밋 | 기대 동작 | 실패를 만드는 방법(후보) |
|---|---|---|---|
| 워커 적용 중 flush 실패 | `c95225fef` | 결과를 넣은 뒤 워커가 다음 task를 꺼내지 않고 종료(`ws_worker exit reason=apply_failed`), `la_applier_need_shutdown` → applier 재시작, 실패 트랜잭션의 일부 변경이 다른 트랜잭션 커밋에 섞이지 않음, 재시작 후 정합성 일치 | flush 에러 주입 훅 필요(현재 없음) |
| 워커 적용 중 서버 다운 | `c95225fef` | 위와 같음(develop처럼 미커밋 트랜잭션은 서버가 롤백) | 적용 중 슬레이브 cub_server kill |
| 적용 실패한 결과 | `1c68a46df` | 게이트 완료 집합에 기록되지 않음 → 그 트랜잭션에 의존하는 트랜잭션이 디스패치되지 않음 → retire에서 applier 종료 → frontier가 실패 트랜잭션 앞에 머묾 | 위 두 경로와 함께 확인 |
| 정상 종료 중 결과 넣기 실패 | `a777688f9` | 워커 종료 로그가 `reason=normal_shutdown`, 넣지 못한 결과는 재시작 시 재적용 | 대량 적용 중 applylogdb 정상 종료 |
| 디스패치 순서 가득 참 | `78d349574` | 에러 대신 `la_inflight_wait_for_space`에서 결과 회수·retire 하며 대기, 교착 없음 | 앞 트랜잭션 하나를 오래 붙잡고(`CUBRID_HA_TEST_BLOCK_CLASS`) 뒤에 10240건 이상 유입 |
| 게이트 완료 집합 가득 참 | `1f800315c` | 절반(131072) 초과 시 prune, 그래도 차면 ER_FAILED → applier 재시작(무한 루프 아님). 원인이 계속되면 재시작 반복(TODO) | 위와 같은 방식으로 frontier 위 구멍을 13만 건 이상 쌓기 |
| 재시작 복구 구간 | (기존) TODO `recovery_boundary_lsa` | 위 종료 경로 뒤 재시작에서 이미 적용된 트랜잭션은 중복 키/행 없음 스킵으로 흡수, 진짜 에러로 보고되지 않음 | 위 각 경로의 재시작에서 함께 확인 |
| 바깥 트랜잭션 abort 뒤 fragment의 로그 보존 | (TODO, `la_find_required_lsa`) | 떼어 낸 SYSOP_END fragment는 `required_lsa` 계산에 안 들어감. 바깥 abort로 슬롯이 즉시 풀리면 fragment 미완료 중 `required_lsa`가 그 항목을 넘을 수 있음 → 재시작·아카이브 삭제와 겹칠 때 항목 유실 가능성(미검증) | serial을 쓰는 트랜잭션을 abort시키고, fragment를 붙잡은 채(`CUBRID_HA_TEST_BLOCK_CLASS`) 크래시·재시작 |

공통 확인: 정합성(master=slave digest), `[WSET]` trace의 worker 번호·`elapsed_usec` 출력, debug 빌드에서 assert(게이트 init·mark_completed·워커 start·run_task rectype) 미발생.
