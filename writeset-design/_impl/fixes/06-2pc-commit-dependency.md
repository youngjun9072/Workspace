---
tags: [CBRD-27508, writeset, master, fixes]
---
# 2PC 커밋이 의존 없는 라벨로 나가고 히스토리에 등록되지 않는 문제

> [!NOTE]
> **현재 상태 (2026-11-02, PR 브랜치 HEAD 9b2dd61b5 기준)**
> - 수정은 fb82b7db6(10-09 master 커밋)에 들어 있다. 57239ff43, d449c8968은 지금 브랜치에 없다.
> - 대상 함수는 `log_complete_for_2pc`다. COMMIT 갈래가 `log_append_repl_info_and_commit_log` → `assert_release` → `wset_publish_commit_to_history` 순서로 1PC와 같다.
> - `copy_to`가 복사하는 writeset 필드는 `wset_hashes`, `wset_overflow`, `wset_fallback_reason`, `wset_dependency_seq` 넷이다. 이 문서의 `wset_dependency_is_ref`는 라벨 형식에서 없어졌다.
> - 01 문서 5.4절에 반영.


작성: 2026-10-15. gap-e2e C3에서 출발. 사용자 지시("2pc부터 처리하자")로 분석 후 반영. 코드는 별도 커밋 57239ff43(미빌드·미검증, 접기는 승인 뒤).

**2026-10-16 접힘**: 별도 커밋 57239ff43 → master 커밋 d449c8968. 빌드·배포 전, 실측 없음(코드 대조).

## 한 줄 요약

마스터의 커밋 경로는 두 가지다. 일반 커밋(`log_commit_local`, `is_local_tran = true`)은 **의존 찾기 → 복제·라벨·commit 쓰기 → 히스토리 등록** 세 단계를 하지만, 2PC 2단계 결정 커밋과 재시작 복구는 `log_commit_local (…, false)`로 그 블록을 건너뛰고 `log_complete_for_2pc`가 **쓰기 한 단계만** 대신한다. 라벨의 `dependency_seq`는 트랜잭션 시작 때 NULL로 둔 값 그대로 나가고 키도 등록되지 않는다.

## 복제는 되는가

된다. `log_complete_for_2pc`의 COMMIT 분기도 `log_append_repl_info_and_commit_log`를 불러 repl 레코드·라벨·commit을 한 뮤텍스 안에서 쓴다(develop 동일). 빠진 것은 writeset 메타뿐이다.

## 콜스택 비교

**A. 일반 커밋** — `xtran_server_commit` → `log_commit` → (참여자 없음) → `log_commit_local (…, true)` → `wset_find_dependency_from_history` / `log_append_repl_info_and_commit_log` / `wset_publish_commit_to_history` → `log_complete`. XA로 prepared된 참여자 트랜잭션도 attach 뒤 커밋하면 이 경로(coord 없음).

**B. 2PC 2단계 결정 커밋** — `log_commit` → (참여자 있음 && prepared) → `log_2pc_commit (COMMIT_DECISION)` → `log_2pc_commit_second_phase` → `log_commit_local (…, false)`(아무것도 안 씀) → `log_2pc_send_commit_decision` → `log_complete_for_2pc (LOG_COMMIT)` → `log_append_repl_info_and_commit_log` **만**.

**C. 재시작 복구** — `log_2pc_recovery` → `log_2pc_recovery_commit_decision` → `log_commit_local (…, false)` → `log_complete_for_2pc (LOG_COMMIT)` → 같음.

DBLink 조정자의 보통 커밋(`EXECUTE_FULL`)은 1단계 `log_2pc_commit_first_phase`에서 `log_commit_local (…, true)`로 끝내므로 A와 같다(`-DCCI_XA` 빌드).

## 왜 문제인가

`tdes->wset_dependency_seq`는 트랜잭션 중 쌓이는 값이 아니라 커밋 직전 `wset_find_dependency_from_history` 한 곳에서만 채워지고(`log_tran_table.c` 시작 시 NULL), 그 호출이 B·C가 안 지나가는 블록 안에만 있다. 라벨 쓰기(`log_append_wset_label_with_lock`)는 그 값을 그대로 복사하고, slave 게이트(`la_gate_is_satisfied`)는 NULL을 "기다릴 것 없음"으로 읽는다. 결과는 직렬도 에러도 아닌 **독립 트랜잭션 취급**이다.

- 앞 트랜잭션 T1이 부모 행, 2PC T2가 자식 행이면 T2가 먼저 적용될 수 있고 FK 위반은 flush 경로가 세고 넘어가므로 자식 행이 slave에서 유실된다(fail_counter +1만 남음).
- T2가 등록되지 않으므로 뒤의 T3(같은 키)이 T2를 기다리지 않는다. 반대 방향 유실.

경로 B는 중첩 조정자(위에 prepared되면서 아래 참여자를 거느림), C는 미결 2PC의 복구라 빈도는 낮다. 그러나 이 브랜치가 막으려는 "조용한 유실 + fail_counter 1"이 그대로라 닫는다.

## 수정 (커밋 57239ff43)

1. `log_manager.c` `log_complete_for_2pc` COMMIT 분기: `log_append_repl_info_and_commit_log` 앞에 `wset_find_dependency_from_history`, 뒤에 `wset_publish_commit_to_history`(일반 커밋과 같은 순서, 같은 assert).
2. `log_tran_table.c` `log_tdes::copy_to`: `wset_hashes`, `wset_overflow`, `wset_dependency_is_ref`, `wset_dependency_seq` 복사 추가. 조정자가 참여자 응답을 기다리며 트랜잭션을 다른 슬롯으로 옮길 때(`log_complete_for_2pc` 안 `copy_to`) 해시가 따라가야 뒤의 커밋이 등록할 키를 가진다.
3. `log_commit_local`의 미룸 주석에 의존·publish도 미룬다고 명시.

## 적용 상태와 검증

- cubrid(server) 번역 단위 2개 컴파일 통과. 빌드·배포·실측 전.
- B·C 재현 비용이 커서 검증은 코드 대조(두 경로의 세 호출 순서 동일)로 한다. 일반 경로에는 영향이 없다.
- XA 참여자 경로 실측은 JDBC XA(`CUBRIDXADataSource`)로 가능하나 설치본에 JDBC jar가 없어 서브모듈 빌드가 필요하다(보류).

## 상세 설계용 요약 (4-R08 또는 5 §6 후보)

마스터는 커밋 레코드를 쓰는 경로마다 같은 세 단계를 지켜야 한다: 히스토리에서 의존 선택 → 라벨·commit 쓰기 → 키 등록. 어느 경로든 한 단계라도 빠지면 slave는 그 커밋을 독립으로 보고 순서 보장이 없어진다. 2PC는 commit 쓰기를 별도 함수로 미루므로 그 함수가 세 단계를 다 가져야 하며, 트랜잭션 디스크립터를 복사해 옮기는 경로는 writeset 상태도 함께 옮겨야 한다.
