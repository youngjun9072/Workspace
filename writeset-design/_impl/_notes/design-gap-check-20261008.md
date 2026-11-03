---
tags: [writeset, gap, review, todo]
date: 2026-10-08
code: cubrid-applier feature/CBRD-27508-parallel-applylogdb-writeset HEAD a9b87e443 + 작업 트리(조각 경로 제거, 미커밋)
---

# 설계 대비 미구현 점검 (2026-10-08)

> [!NOTE]
> **현재 상태 (2026-11-02, PR 브랜치 HEAD 9b2dd61b5 기준)**
> - 이 점검은 unimplemented-20261008.md가 대체했다. 항목별 현재 상태는 그 문서 머리의 상태 줄을 본다.


세 갈래(master, slave, 검증·리스크)로 설계 문서와 코드를 대조했다. "확인" 열은 점검자가 보고한 근거를 본 세션에서 코드로 다시 본 것(확인) 또는 보고만 받은 것(보고)이다. 구현 여부가 아니라 우선순위를 정하기 위한 목록이다.

## 미구현 · 부분 구현 · 문서와 불일치

| # | 항목 | 출처 | 상태 | 근거 | 확인 |
|---|---|---|---|---|---|
| 1 | WSET_LABEL 노드 할당 실패 시 `/* FIXME */ return`, COMMIT은 그대로 기록됨 | 01 §6, 05 §3.2, 리뷰 C1 | 미구현 | log_manager.c:4924~4928 | 확인 |
| 2 | 2PC 커밋 경로(`log_complete`)는 probe·publish 없이 라벨 기록 | 05 §6, 리뷰 C2 | 설계상 보류 | log_manager.c:6259 (로컬 커밋 5489~5493과 대비) | 확인 |
| 3 | `xlocator_repl_force`가 lock 오류 포함 모든 오류를 항목 단위로 삼키고 계속 | 11 §11.9-4 | 미구현 | locator_sr.c:7073~7081, `ER_LK_` 0건 | 확인 |
| 4 | `wset_history_finalize` 호출처 없음 | 01 §1.2.3 | 미구현 | grep 0건 | 확인 |
| 5 | serial 캐시 BTID NULL이면 트랜잭션 전체를 commit-order 폴백(overflow) | 10 §13.7.2 "overflow 재사용 금지" | 불일치 | serial.c:1232~1235 | 확인 |
| 6 | 원인 B: `min(최댓값, prev_commit_lsa)` 하향 유지 | 11 §11.9-2 | 설계상 TODO | writeset.cpp:879~887 | 확인 |
| 7 | 재시작 배리어·epoch 경계(05장, 12장) | 05 §2~4, 12장 | 미구현 | 심볼 없음 | 확인(grep) |
| 8 | 재시작 복구 skip 완료 조건 | 9.1.3, 03 §4 | 부분 | WIP f5e1535db는 backup 브랜치에만, HEAD 0건 | 확인 |
| 9 | slave 복구 상한이 final_lsa, worker행 max_committed_lsa 없음 | 02 §5·7 | 미구현 | log_applier.c:3836 | 확인 |
| 10 | apply info 갱신 0건을 에러 로그만 남기고 NO_ERROR 반환 | 02 §7 | **닫음 (10-16)**: 설계 전제(B2 완료 표식 정리)가 사라짐. 복구 구간 상한 저장(`la_update_ha_apply_max_committed_lsa`)은 0건을 실패로 처리. 주기적 저장(`la_coordinator_commit_apply_info`)은 0건·기타 오류 모두 develop과 같이 fail_counter+1·로그·계속(서버 다운만 반환), 별도 커밋 | log_applier.c `la_reader_commit_apply_info` res==0 | 확인 |
| 11 | task queue가 가득 차면 reader 차단 대기(설계는 비차단·outstanding 상한), pending 무제한, completed set 2^18 고정 | 02 §3, 09 §2·5, 9.1.4 | 불일치 | log_applier_task_queue.cpp:62, log_applier_gate.cpp:47 | 확인(queue), 보고(set) |
| 12 | long transaction(1000항목 초과)의 SYSOP_END는 바깥 커밋 재생 → serial 후퇴·abort 유실 잔존 | 10 §13.7.2.1 | 부분(자인) | log_applier.c:8690, :8982 | 확인 |
| 13 | 라벨 없는 COMMIT을 독립 task로 배정(설계는 금지) | 02 §2, 8-2.3 | 불일치 | log_applier.c:8821 부근 | 보고 |
| 14 | 복구 구간 error skip 뒤에도 restart 판정 진입 | 8-2.9 | 부분 | la_flush_repl_items | 보고 |
| 15 | worker READY 핸드셰이크 없음, worker 수·queue 용량 #define | 08 §5·12 | 미구현/TODO | log_applier_worker.cpp/.hpp | 보고 |
| 16 | 리뷰 "커밋 전 필수" 소수정: WSET_LABEL dump 케이스, or_pack 오류, release 클램프, bad_alloc 처리, savepoint 되감기 | 리뷰 C5~C9, C6 | 미착수 | log_manager.c dump switch, writeset.cpp:456, writeset_history_map.cpp:54 | 보고(추정) |
| 17 | rectype 호환 문서(마스터 선업그레이드 = 복제 중단), trace PII, release 패딩 | 리뷰 R10, R18, R13 | 미착수 | log_record.hpp:140 등 | 보고 |
| 18 | UPDATE 키 수집이 same_key 무관 old+new 항상 수집, PK WRITE 수집 순서가 repl 성공 전 | 01 §2.1·2.2 | 불일치(보수 측) | locator_sr.c:8052~8062, 8742~8782 | 보고 |
| 19 | trace fallback_reason 분류(serial/incr/checksum/overflow) 없음 | 10 §13.7.2 | 부분 | log_manager.c SYSOP trace | 확인 |
| 20 | 용량 집계를 동시 게시분 포함 원자 예약으로 | 8-1에만 | 미구현 | writeset.cpp:987 | 보고 |

## 검증 미착수

| 항목 | 출처 | 상태 |
|---|---|---|
| pending 계측(배정 줄에 frontier), gate 단위 테스트, 6-2.4·8-2.4 정정 | a1-test 남은 일 | 미착수 |
| long transaction·DDL 경로 부하(`--wide-transactions`, `--ddl-transactions`), fullcheck/gatesim의 SYSOP 작업 포함 | commit-order 남은 일 | 미착수 |
| 조각 모드 수정 빌드 재측정 | fragment 노트 | 조각 제거로 불필요(복귀 시 필요) |
| failover 승격·failback 실측 | 9.2, 03 §4 | 미착수 |
| 백로그(포화) 병렬성 측정 | a1-test, 03 §5 | 미착수 |
| Run 1 wide 행 손상·slave crash 원인 | sysop-end 노트 | 미착수 |
| 복합 FK 단위 테스트 실행 기록 | 9.1.2 | 바이너리만, 기록 없음 |
| cub_server 재시작 검증(12.8) | 12장 | 미착수 |

## 우선순위 제안

1. 라벨 계약을 깨는 것: #1 WSET_LABEL 실패 전파, #2 2PC 범위 결정(최소한 라벨 없이 commit-order 폴백 표시).
2. 멈춤·손실 방어: #3 repl_force lock 오류 즉시 반환, #12 long transaction SYSOP_END, #10 apply info 0건.
3. 재시작 정합: #7·#8·#9(배리어, 복구 skip, 복구 상한).
4. 조각 복귀 선결로 남겨 둘 것: #6 원인 B.
5. 나머지는 PR 정리 단계(#4, #5, #11, #13~#20)와 검증 목록.
