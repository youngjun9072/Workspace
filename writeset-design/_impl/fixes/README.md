---
tags: [CBRD-27508, applier, fixes]
---
# applier 수정 항목 문서 (작업 목록 ① 순)

> [!NOTE]
> **현재 상태 (2026-11-02, PR 브랜치 HEAD 8e3029e56 기준)**
> - 10번(상속 공유 인덱스)은 닫혔다: 5ff77d416(10-29), a3c71290a(10-30). 아래 표의 "사용자 결정 대기"는 옛 상태다.
> - 6번(2PC)의 master 커밋 d449c8968은 10-28 이력 정리로 fb82b7db6에 접혔다. 함수 이름은 `log_complete_for_2pc`다.
> - 이 표의 커밋 해시는 대부분 10-28 이력 정리 전 해시다. 현재 해시는 각 문서 머리의 상태 줄을 본다.


항목마다 한 문서. 구성은 "단계별 코드(줄 번호·그 시점 변수 값) → 왜 문제인가 → 해결 방안(채택·대안·기각) → 적용·검증 상태 → 상세 설계용 요약". 작업 목록 번호는 2026-10-15 정리본 기준.

| 번호 | 문서 | 문제 | 코드 | 검증 | 설계 반영 |
|---|---|---|---|---|---|
| 1 | [01-done-deferred](./01-done-deferred.md) | `la_change_state`가 미룬 DONE을 재평가하지 않아 승격 노드가 to-be-active에 고정 | slave 커밋 68dedb13c (10-16 재접기, 미빌드) | 케이스 1(master cub_server kill) 4회: 재기동 갈래라 미경유, 재시작 경계 3/3 OK. 케이스 4에서 확인 예정 | 8-2.8 역할 전환 drain 후보 (문서 끝 요약) |
| 2 | [02-required-lsa-fragments](./02-required-lsa-fragments.md) | `la_find_required_lsa`가 미retire 조각 태스크를 보지 않아 ABORT 시 필요한 아카이브가 지워질 수 있음 | slave 커밋 68dedb13c에 접힘 (미빌드) | 백로그 테스트 예정 | 8-2.6 완료 경계 또는 7장 후보 (문서 끝 요약) |
| 3 | [03-recovery-range-serialize](./03-recovery-range-serialize.md) (보류) | 복구 구간 병렬 재적용 교착 가능성, 직렬화 호출 꺼짐 | 변경 없음. 결함 4 수정→재시작 테스트→필요 시 "넘기고 기다리기" 방식 | 재시작 테스트(7번) | 8-2.7 재시작 후보 |
| 4 | [04-item-error-policy](./04-item-error-policy.md) | `la_apply_repl_log` 반환값이 마지막 항목 결과라 마지막 항목의 비치명 오류만 트랜잭션 미커밋·applylogdb 종료로 번짐 | slave 커밋 68dedb13c에 접힘 (10-16, 원 9593d1131) | 마지막 항목 DELETE -711 시나리오 예정 | 8-2.x 워커 오류 처리 후보 (문서 끝 요약) |
| 5 | [05-single-worker-serial](./05-single-worker-serial.md) | 워커 1개여도 게이트를 타서 보관 태스크를 뒤의 독립 태스크가 추월, 커밋 순서 적용이 아님 | slave 커밋 68dedb13c에 접힘 (10-16, 원 a6f4f225c) | L→T1→M 시나리오 예정 | 8-2.3 스케줄링/설정 후보 (문서 끝 요약) |
| 6 | [06-2pc-commit-dependency](./06-2pc-commit-dependency.md) | 2PC 2단계·복구 커밋이 의존 없는 라벨로 나가고 히스토리 미등록 → slave가 독립 취급 | master 커밋 d449c8968에 접힘 (10-16, 원 57239ff43) | 코드 대조(재현 비용 큼) | 4-R08/5 §6 후보 (문서 끝 요약) |
| 7 | [07-inprocess-restart-state](./07-inprocess-restart-state.md) | 같은 프로세스 안 재시작이 이전 실행의 pending 태스크(해제된 슬롯 포인터)와 gate frontier를 물려받아 required_lsa 0\|0 저장·기동 실패 반복 | slave 커밋 68dedb13c에 접힘 (10-16, 원 4ba248708) | 케이스 2 반복에서 같은 pid 재시도 회차 확인 예정 | 8-2.7 재시작 후보 (문서 끝 요약) |
| 8 | [08-applied-tx-marker](./08-applied-tx-marker.md) | 워커 커밋과 apply info 저장이 갈라져 재시작 때 커밋된 트랜잭션을 다시 적용하고, PK·UNIQUE 변경 UPDATE가 어긋나 slave에 옛 키 행이 남음(Greptile 3차 P1) | 미착수. PoC 마커(`5926f3840d`, 보존 브랜치 `feature/parallel_applylogdb_writeset_hole_marker_drain`)를 옮겨 심는 방향 | 재현 시험 예정 | 8-2.7 재시작 |

검증 계획(1·2·4·5 시나리오, 조작 단계, 기준선/수정 후 기대): `_notes/fix-verify-plan-20261015.md`. develop PR #8110(CBRD-27563, 승격 전 copied log 끝 확인)은 01 문서 끝에 관계를 적었고, 병합 뒤 develop 싱크 때 반영한다.

1·2·5의 로깅·assert: 3924469c6 → slave 커밋 68dedb13c에 접힘 (각 문서의 "로깅·assert" 절). 재시작·failover 테스트 계획: `_notes/restart-failover-test-plan-20261015.md`.

## 2026-10-16 접기·정리 커밋

별도 커밋을 파일 기준으로 나눠 접음(백업 브랜치 `backup/pre-fold-20261016`, 트리 동일 확인). 새 체인: master d449c8968 / slave 68dedb13c / cs 5c56880b6. 모두 빌드·배포 전.

| 내용 | 원 커밋 | 접힌 곳 |
|---|---|---|
| HISTORY_START 올림 사유 로그 | c2fd1022b | master |
| `ha_apply_max_mem_size` 4000MB 바닥 제거(conf는 당분간 4096) | 17155c132 | slave |
| 라벨의 `dependency_is_ref`(slave `dependency_is_read`) 제거, 레코드·LOG_TDES 형식 변경 → 양 노드 동시 배포·DB 재생성 | 485fb7226 | master(레코드·writeset) + slave(applier) |
| develop 직렬 applier의 커밋 리스트(`LA_COMMIT`) 제거 | a69690eda | slave |
| unit test: 제거된 필드·reason 인자 반영 | 528d4de7c | master |

2차 접기(10-16 오후, 새 체인 master aa951bdbb / slave 2bda6f864 / cs d2fe5f634, 백업 `backup/pre-fold2-20261016`)로 아래 별도 커밋도 접힘: c8fc5d4d9 dispatch order 장부 → in-flight list 이름 변경(slave), ed851b00d replica 범위 주석(slave), 5a8808a86 apply info 실패 처리 develop 동일(slave), 5606d1a21 리뷰 C6·C8·C9(master), fed6c0301 워커 기본 1(slave). 문서 용어도 `_impl` 전체에서 in-flight list로 바꿈.

## 2026-10-16 unit test에서 발견

| 내용 | 커밋 | 검증 |
|---|---|---|
| `wset_midxkey_hash`가 복합 키 원소를 비정렬 위치에 패킹해 버퍼를 넘겨 씀((INT,BIGINT) 키에서 38바이트 버퍼 끝 2바이트 초과 → 다음 힙 청크 손상). develop `or_pack_value`처럼 MAX_ALIGNMENT 정렬 위치에서 패킹 | 별도 커밋 5f5f0a824 (master, 미배포) | writeset UT `[writeset]` 26건 통과, valgrind 메모리 오류 0 |
| applier unit test 새로 작성(in-flight, gate, pending, task/result 큐 21건) | 별도 커밋 fd13cc3da | 21건 통과, frontier 초기화 제거 변이로 4건 실패 확인 |

## 표 밖 추가 항목

- 9. [09-inflight-slot-wait](./09-inflight-slot-wait.md): in-flight 목록이 끝난 태스크로 꽉 찬 채 대기 태스크가 풀리면 coordinator가 오지 않을 결과를 기다림(Greptile 3차 P1, `log_applier.c:1077`). 미착수, 수정안=기다리기 전에 retire 먼저. 커밋 메시지에 문서의 3칸 예시를 쓴다.
- 10. [10-inherited-index-writeset-key](./10-inherited-index-writeset-key.md): 상속 계층이 함께 쓰는 unique 인덱스에서 writeset 키가 행의 클래스마다 갈려 충돌을 놓침(10-29 HA 확인). ★최우선. 방안 A(VFID+키) 추천, 사용자 결정 대기.
- 11. [11-missed-ordering-scenarios](./11-missed-ordering-scenarios.md): writeset이 잡지 못할 수 있는 순서 의존 후보 16개(매뉴얼 조사). 모두 미시험, 재현은 지시 후.
