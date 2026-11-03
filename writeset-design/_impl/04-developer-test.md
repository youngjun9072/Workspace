# CBRD-27508 개발자 테스트 (목차 초안)

> [!NOTE]
> 목차만 정리한 초안이다. 각 시나리오는 설계 결정 하나를 확인하도록 골랐고, 같은 것을 두 번 확인하지 않는다. 시험은 회귀 시나리오(`ha_bench_tool/bin`)에서 골라 쓰며, 괄호 안이 그 스크립트다. 본문(목적, 방법, 판정 기준, 결과)은 목차를 확정한 뒤 채운다.

## 1. 시험 환경과 판정 방법

- 1.1 HA 구성과 설정 (master·slave 2노드, worker 10, history·메모리 설정)
- 1.2 판정 방법: master·slave 전체 표 비교, slave fail_counter, 적용 오류 로그
- 1.3 순서를 뒤집는 방법: slave에서 앞 트랜잭션의 행을 잠가 붙잡아 두고, 뒤 트랜잭션이 먼저 적용되는지 본다 (`pair_order_test.sh`)

## 2. 병렬 적용 성능

- 2.1 최선: 서로 다른 키만 건드리는 트랜잭션 (INSERT·UPDATE 백로그, develop 직렬 대비) (`backlog_pause_test.sh`, `run_backlog.sh`)
- 2.2 최악: 모든 트랜잭션이 같은 키를 건드림 (같은 행 UPDATE 연속, 직렬과 같아지는지와 추가 비용) (새 시험 필요, 예전 같은 키 UPDATE 실측 참고)
- 2.3 중간: 같은 부모를 참조하는 자식 INSERT (형제 REF가 병렬로 도는지) (`fk_multi_guard.sh`)
- 2.4 commit-order 폴백이 섞인 부하 (statement 복제·DDL이 섞일 때의 처리량) (`ddl_mix_test.sh`)

## 3. 충돌 키 순서 보장 (master 01 3~5장)

- 3.1 같은 PK의 UPDATE·DELETE 순서
- 3.2 UNIQUE 키 재사용: DELETE k 뒤 INSERT k
- 3.3 FK 앞선 WRITE와 뒤의 REF: 부모 INSERT 뒤 자식 INSERT
- 3.4 FK 앞선 REF와 뒤의 WRITE: 자식 INSERT 뒤 부모 DELETE (RESTRICT, CASCADE, SET NULL)
- 3.5 커밋 중인 부모와 자식 FK 검사의 경합 (`c3_fk_gap.sh`)
- 3.6 실패한 문장의 키: B-tree를 바꾸기 전에 모은 키는 그 문장이 실패하면 문장 rollback이 복제 레코드와 함께 지운다. 커밋한 트랜잭션에 실패한 문장의 키가 남지 않는다 (UNIQUE 중복으로 문장만 실패하고 다른 행을 넣어 커밋한 T1, 그 뒤 실패한 키를 쓰는 T2: T2 라벨이 T1을 가리키지 않고 데이터가 같아야 함. 새 `pair_order_test.sh` 케이스)
  - 3.1~3.4: `pair_order_test.sh` 케이스

## 4. 키 동등성과 해시 (master 01 3장)

- 4.1 콜레이션: ci 콜레이션, 끝 공백, NUL, binary, euckr
- 4.2 값 정규화: -0.0, MONETARY 통화, TIMESTAMPTZ 시간대, VARBIT 길이
- 4.3 단일 키·복합 키 원소·FK REF가 같은 키로 모이는지
- 4.4 상속 계층의 공유 인덱스 (class OID를 해시에서 뺀 이유)
- 4.5 NaN 키의 commit-order 폴백
  - `random_pairs.py`, `cases/pair_regress_recent.sh`

## 5. commit-order 폴백과 하한 (master 01 4.4절, 5.2절, 8장)

- 5.1 트랜잭션 키 수 초과 (`bigtx_test.sh`)
- 5.2 statement 복제와 DDL (`ddl_mix_test.sh`)
- 5.3 history 용량 초과로 비우기 (`ha_writeset_history_size`를 작게 한 부하, 새 시험 필요·master conf 변경)
- 5.4 master 서버 재시작 뒤의 하한 (새 시험 필요)

## 6. 독립 top operation (master 01 8장, slave 02 sysop fragment)

- 6.1 serial, AUTO_INCREMENT, INCR·DECR, checksumdb의 라벨 단 SYSOP_END (`sysop_all_test.sh`)
- 6.2 serial 캐시 write-back (DDL 뒤 NEXT_VALUE) (`cases/pair_serial_wb_20261102.sh`)
- 6.3 sysop ABORT와 문장 단위 rollback (새 시험 필요)

## 7. slave 적용 경계와 재시작 (slave 02)

- 7.1 frontier와 pending list: 앞 트랜잭션이 붙잡혀도 coordinator가 뒤 로그를 계속 읽고 조건 없는 task는 적용되는지
- 7.2 slave 프로세스 kill 뒤 재시작: server, applylogdb, copylogdb (`kill_slave_proc.sh`)
- 7.3 applied-tx 마커로 다시 적용하지 않음 (재시작 때 마커 읽기 실패 포함) (`marker_load_fail_repro.sh`)
- 7.4 apply info 저장이 실패할 때 마커 보존 (`marker_stat_abort_repro.sh`)
- 7.5 마커 삭제의 잠금 상승 (`marker_lock_escalation_repro.sh`)

## 8. 자원 한도 (slave 02)

- 8.1 큰 행과 worker 레코드 풀 메모리 (`recdes_pool_retain.sh`, `big_record_check.sh`)
- 8.2 in-flight 할당 실패 (`inflight_init_fail_repro.sh`)
- 8.3 worker 수 변경: 1, 2, 32 (`config_variant_test.sh`)

## 9. 범위 밖과 HA 제약

- 9.1 SHARED 컬럼, CLASS ATTRIBUTE: develop도 복제하지 않음 (`cases/pair_shared_classattr_20261102.sh`, develop 대조)
- 9.2 혼합 버전 HA: 지원하지 않음 (시험 없음)
- 9.3 failover drain: 지시가 있을 때 시험
