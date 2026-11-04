# CBRD-27508 브랜치 리뷰 공통 지침 (모든 리뷰어 필독)

## 대상
- 저장소: `/home/youngjun/Workspace/cubrid-applier` (git worktree). **읽기 전용.** 파일 수정, 빌드, `git checkout`/`git stash`/`git reset` 금지. 로컬 미커밋 파일(.omc, build_ut_debug 등)은 범위 밖.
- 범위: `git diff a9a0dc78d 0e411f10f` (12 커밋, `git log --oneline a9a0dc78d..0e411f10f`).
  - fb82b7db6 master writeset 생성 / 7b844b047 composite key 정렬 / 45825ca17 slave 병렬 applylogdb / acdd6d2d3 단위테스트 / edc1918ad client glue / cb0095bf2 MULTI_CONN 활성화 / d1d02b9e4 커밋 중 inserter 대기 / edd32308a 재시작 복구 구간 직렬 적용 / 470309f59 copied log header 갱신·아카이브 삭제 mutex / 396f4966b 복구 구간 하한 / 79268ae56 unique 검사가 커밋 중 deleter 대기 / 0e411f10f 대기 trace
- 기준선(develop 쪽)과 비교할 때는 `git show a9a0dc78d:<path>`.

## 분석 깊이
- **정밀 분석 (writeset과 병렬화 관점)**: `src/transaction/writeset*.{cpp,hpp}`, `writeset_types.hpp`, `writeset_history_map.*`, `log_manager.c`, `log_append.cpp`, `log_record.hpp`, `log_impl.h`, `log_tran_table.c`, `log_recovery.c`, `locator_sr.c`, `replication.c`, `btree.c`, `serial.c`, `system_parameter.{c,h}`, `error_code.h`, `log_applier.{c,h}`, `src/transaction/applier/*`, `unit_tests/log_applier/*`, `unit_tests/writeset/*`.
  - 볼 것: 키(PK/UNIQUE/FK) 수집과 라벨 생성의 정확성, dependency/commit 순서 규칙, coordinator↔worker 간 동기화(gate, inflight, pending, task/result queue), 메모리·수명, 락 순서, 재시작·복구·failover(DONE 보류) 경로, 경계 조건.
- **CS 쪽 (client-server glue, multi-connection)**: `CMakeLists.txt`, `cs/`, `sa/`, `cubrid/` CMakeLists, `src/object/work_space.{c,h}`, `src/storage/file_io.c`, applier가 쓰는 multi-connection API. **내부 구현은 상세 분석하지 말 것.** 이 브랜치 코드가 그것을 **호출하는 곳(caller)과 반환값·에러 처리**만 본다.

## 리뷰 관점 (네 가지 모두)
1. **에러**: 잘못된 동작, 에러 무시·누락, 자원 누수, 경쟁 조건, 교착, 복구 불가 상태.
2. **모듈화**: 책임 분리, 파일·함수 경계, 전역 상태, 중복 코드, 결합도.
3. **아키텍처**: 설계 일관성(master writeset ↔ slave 적용), 확장성, 기존 CUBRID 구조와의 정합, 레이어 침범.
4. **리팩토링**: 함수 길이·복잡도, 명명, 주석 품질, 테스트 용이성을 높이는 구조 변경 제안.

## 반드시 지킬 것
- **중간에 결론 내지 말 것.** 관련 경로를 끝까지 읽고 caller를 grep/LSP로 추적한 뒤 판단한다. 총평은 맨 마지막에 쓴다.
- **할당량 없음.** 근거가 있는 것만 올린다. 어느 관점에 발견이 0건이어도 된다.
- 모든 발견에 HEAD 기준 `파일:행`, 해당 코드 인용, 이유, **구체적 실패 시나리오**(입력·상태 → 잘못된 결과)를 적는다.
- **확정**(코드로 직접 확인)과 **추정**(가능성, 미검증)을 구분한다. 추정은 "추정"이라고 쓴다.
- **신규**(이 브랜치가 만든 것)와 **기존**(a9a0dc78d에도 있음)을 구분한다.
- 등급: Critical / High / Medium / Low.
- 용어: applier의 메인 스레드는 **coordinator**라고 부른다(코드·로그에 "reader"라고 남은 곳이 있어도 "reader"로 부르지 말 것. 단 그 명칭 불일치 자체는 리팩토링 항목이 될 수 있음).
- **지적하지 말 것**: prior_lsa 할당 실패 처리(NULL→return). develop의 모든 append 경로가 같은 처리다.
- 주석은 영어·자체 완결형이 기준이다. 내부 단계번호(S1, M4)나 문서 절 번호를 참조하는 주석은 리팩토링 항목으로 올려도 된다.

## 산출물
- 파일: `/home/youngjun/Workspace/review/CBRD-27508_branch_review_20261020/<역할>_<연차>y.md` (한국어 markdown)
- 구성:
  1. 리뷰어 관점 (역할·연차에 따라 무엇을 중점으로 봤는지 2~3줄)
  2. 검토 범위와 실제로 읽은 경로 (파일·함수 목록)
  3. 발견 사항: 관점(에러/모듈화/아키텍처/리팩토링)별 표 — `ID | 등급 | 위치(파일:행) | 내용 | 근거(코드 인용 요약) | 실패 시나리오 | 확정/추정 | 신규/기존`. 표 아래에 항목별 상세 설명.
  4. 미검증 의심 (근거 부족으로 확정 못 한 것)
  5. 총평 (마지막에)
- 작업 후 호출자에게 돌려줄 것: 파일 경로, 등급별 건수, 가장 중요한 3건 한 줄 요약. **Write가 실패하면 보고서 전문을 그대로 반환.**
