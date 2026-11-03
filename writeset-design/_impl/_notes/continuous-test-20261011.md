# 연속 테스트 (2026-10-11 16:48~18:35) — 재배포 없이 시나리오 6개

빌드: HEAD 87abad1 + 미커밋 수정(결함 1 페이지 버퍼, 결함 3 복구 구간 직렬, 결함 4 repl_force 희생자, SCH_S 정지, FK 락 실패 반환 2곳), 16:36 양 노드 설치, conf md5 57f0224f / 68235c04, DB 새로 생성. 각 200,000건, `--key-start 10000000`, preload 500.

| 시나리오 | 구성 | master = slave (직접 교차 조회) | master = model | 하니스 판정 |
|---|---|---|---|---|
| A seed 20261014 | update/delete 위주, dependent 90 | 일치 289,937행 | 일치 | PASS |
| B seed 20261015 | incr 30, SYSOP 비율 0.8 | 일치 380,303행 | 일치 | PASS |
| E seed 20261018 | stmt-fail 0.3, savepoint 0.3, shuffle | 일치 413,632행 | 일치(희생 줄 보정 후) | INCONCLUSIVE_TRACE_MISSING (마스터 로그 교체) |
| F seed 20261019 | DDL 40, wide 20, stmt-fail 0.2, savepoint 0.2, shuffle | 일반 48개·DDL 일치, **wide 불일치** | 일치 | DATA_DIVERGENCE |
| C seed 20261016 | 32 clients / 16 tables, stmt-fail 0.2, shuffle | 일치 286,204행 | 일치 | PASS |
| D seed 20261017 | long 80, 문장 10~25, savepoint 0.4, shuffle | 일치 986,213행 | 일치(희생 줄 보정 후) | PASS (rc=1: 보정 전 대기 시간 초과 기록) |

## 확인된 것
- SCH_S 정지(쉬는 워커의 SCH_S가 DDL의 SCH_M을 막음) 재발 없음. F 부하 중 DDL 40건 통과.
- FK 락 실패 반환 수정: master 클라이언트 deadlock 희생자(E 131, C 12, D 888 등)가 모두 정상 rollback. 수정 전 빌드에서는 E 시작 2분 만에 master 정지.
- 결함 1: slave 오류 0, applylogdb 16:45 기동 후 재기동 없음.
- 문장 실패 시 그 문장만 되돌려지고 트랜잭션은 계속된다는 모델 가정, SAVEPOINT rollback 모델이 master와 일치.

## 남은 것
- F wide 불일치: slave에 preload 트랜잭션(약 48,000 INSERT, 긴 트랜잭션 경로) 끝의 wide 행 1~3이 없음(4는 있음), INCR 미반영, wide UPDATE -711 10,010건. 10-08 Run 1과 같은 증상(sysop-end-test-20261008). 원인 미조사. 증거 `sysop_runs/20261011T083126-20261019-1398960`, youngjun4 `/tmp/F_slave.err`.
- 재기동이 없어 결함 3·4 경로는 미검증.

## 하니스 수정 (모두 미커밋)
1. `--key-start` 전달. 2. 희생자 탐지 grep 단일 실행(30분→2초). 3. `--stmt-fail-ratio`·`--savepoint-ratio`·`--shuffle` + `sysop_random/model.py` 공용 모델, 단위 테스트 23건. 4. 로그 교체 대응: watermark inode 기록 + 실행 중 master 로그 `tail -F` 수집. 5. 희생 줄 번호: 실패 문장 뒤 희생된 경우 abort 직전 줄, 두 번 희생된 경우 마지막 abort 줄. 6. `--replay-seed`가 sysop_tx_ratio를 읽도록.
