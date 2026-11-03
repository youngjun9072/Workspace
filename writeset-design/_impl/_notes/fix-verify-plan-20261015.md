---
tags: [CBRD-27508, applier, 검증계획]
---
# 수정 4건 검증 계획 (작업 목록 ① 6번)

작성: 2026-10-15. 대상: `_impl/fixes/01, 02, 04, 05`. 어제(10-14) 런(fk_multi 720s, sql_surface_long 6버킷)은 정상 복제 중 회귀이고 빌드 d43e03e에는 네 수정이 없으므로, 아래는 각 수정이 고치려던 상황을 일부러 만드는 별도 시나리오다.

원칙
- 기준선: 수정 없는 빌드(d43e03e)에서 먼저 돌려 결함이 실제로 걸리는지 본다. 그래야 새 빌드 PASS가 "시나리오가 약해서"가 아님을 안다.
- 조작 단계(applylogdb 정지·재개, conf 변경, master kill)는 사용자 지시 후 실행. 이 호스트가 youngjun3(master)라 master kill은 로컬 `kill -9`.
- conf를 바꾸면 끝나고 메모리 전문대로 복원 후 md5 대조(`reference_cubrid_ha_conf`).
- 판정 전 slave(youngjun4) 직접 조회. fail_counter는 런 시작값 대비 delta. 기지 신호 목록과 대조(`project_cbrd27508_known_signals`).
- 디스크: 시작 전 /home 20G 이상, 런 중 10G 미만이면 중단.

순서: 접기 결정 → 빌드·배포 → **5 → 2 → 4** (failover 불필요) → **1** (7번 failover 테스트 첫 케이스).

## 시나리오 5. 워커 1개 = 커밋 순서 적용 (fixes/05)

**조작** [지시 필요]: slave `cubrid_ha.conf` `ha_apply_worker_count=1`, `ha_writeset_trace_level=1`, applylogdb 재시작. 끝나면 10으로 복원.

**부하** (master, csql 로컬):
1. `big` 테이블(예: 200만 행, PK id) 준비. `marker(id PK, note)` 테이블 준비.
2. 세션 A: `UPDATE big SET v = v + 1` 커밋 (L, 수 초 걸림).
3. 세션 B: L 커밋 직후 `UPDATE big SET v = v + 1 WHERE id = 1` 커밋 (T1, L에 의존).
4. 세션 C: T1 커밋 직후 `INSERT INTO marker VALUES (1, 'M')` 커밋 (M, 독립).
2~4는 L의 slave 적용이 끝나기 전에 모두 커밋돼야 한다. 스크립트로 연달아 실행.

**확인** (slave applylogdb err 로그, trace 1):
- `reader schedule ... status=2`(보류) 건수: 수정 후 워커 1에서 **0건**. 기준선(워커 1, d43e03e)에서는 T1이 보류됨.
- `worker apply end trid=` 순서: 수정 후 L → T1 → M. 기준선 L → M → T1.
- 데이터: master/slave `big` 체크섬, `marker` 일치(순서 문제라 데이터는 양쪽 다 같아야 함).

## 시나리오 2. ABORT된 트랜잭션의 조각이 읽을 아카이브 보존 (fixes/02)

**원리**: 조각은 라벨 붙은 SYSOP_END(master `log_manager.c:4039`, `LOG_SYSOP_END_COMMIT && repl_item_count > 0`). `SELECT s.NEXT_VALUE`가 트랜잭션 안에서 serial을 갱신하면 그 sysop이 조각이 된다. 바깥 트랜잭션을 ROLLBACK하면 slave에서 바깥 슬롯은 즉시 비고 조각은 별도 태스크로 남는다. 워커가 조각 항목을 적용할 때 항목 LSA의 로그 페이지를 다시 읽으므로, 그 페이지가 든 copied-log 아카이브가 지워지면 실패한다. 삭제 주체는 slave applylogdb의 `la_remove_archive_logs`(우리가 파일을 지우지 않음). `ha_copy_log_max_archives`는 conf에 없어 기본값이라 삭제가 가장 공격적이다.

**조각을 늦추는 방법**: 시나리오 5와 같은 워커 1개 설정을 쓴다. 큰 태스크들이 큐 앞에 있으면 조각은 큐 뒤에서 기다리고, 그동안 코디네이터는 앞서 읽으며 `la_log_commit`(500ms)마다 required_lsa를 갱신하고 아카이브 삭제를 돈다. 조각 위치가 required 계산에서 빠지면(기준선) 그 아카이브가 지워진다.

**조작** [지시 필요]: 워커 1 설정 유지. slave applylogdb 정지(백로그 생성) → 부하 → 재개.

**부하** (master):
1. `CREATE SERIAL s1` 준비. `big` 준비.
2. applylogdb 정지 상태에서: `UPDATE big ...` 커밋 ×N (아카이브 2개 이상 생기도록, log_volume_size=1G이므로 2G 이상 로그) → 그 뒤 트랜잭션 R: `SELECT s1.NEXT_VALUE FROM db_root; UPDATE big SET v=v+1 WHERE id BETWEEN 1 AND 1000; ROLLBACK;` → 그 뒤 다시 `UPDATE big ...` 커밋 ×N (아카이브 2개 이상).
3. applylogdb 재개.

**확인**:
- 기준선: slave 로그에 조각 적용 실패(`worker error trid=<R> ... error=` 로그 페이지 읽기 오류 계열) 또는 applylogdb 종료. `db_ha_apply_info.required_lsa_pageid`가 R의 조각 위치를 앞질러 감.
- 수정 후: 조각 적용 성공(`reader sysop_end trid=<R> ... items=1` 뒤 해당 태스크 `reader retire`), 그때까지 `required_lsa_pageid`가 조각 페이지 이하에 머묾(0.5초 간격 조회), 삭제된 아카이브 번호가 조각 페이지 아카이브보다 작음. master/slave serial 현재값과 `big` 체크섬 일치.
- 조각이 큐 뒤에서 충분히 기다리지 않으면(아카이브 삭제가 조각 적용 뒤에 돌면) 시나리오 무효. 재개 후 `required_lsa_pageid`와 `nxarv_num` 추이를 기록해 판단.

## 시나리오 4. 마지막 항목의 비치명 오류 (fixes/04) — **PASS 10-15 15:03**

실측 수정: 행 오류(-711 등)는 flush 경로가 삼켜 루프의 오류 분기에 오지 않으므로 statement 실패로 바꿈. slave에 `--sysadm --write-on-standby`로 인덱스를 먼저 만들고 master가 같은 CREATE INDEX → slave -272. 결과: `worker error` 1건, fail_counter 2→3, `reader exit` 0, pid 유지, 직후 INSERT 반영. 스크립트 `bin/verify_item_error.sh`, 로그 `log/verify_item_error_20261015_150259`. 1차 런(행 -711 마지막/중간 항목)은 둘 다 세고 계속(flush 경로) — 수정과 무관하게 같은 결과.

(원래 계획)

**조작**: 워커 수 무관. 없음(정상 복제 상태).

**부하**:
1. `t4(id PK, v)`에 id 1~10 준비, 복제 확인.
2. slave에서 직접 `DELETE FROM t4 WHERE id = 10` (slave는 standby라 csql `--sysadm` 또는 `cubrid changemode` 없이 쓰기 가능한지 확인 필요. 불가하면 대안: master에서 id=10을 지운 뒤 slave applylogdb만 멈춰 두고... 아니면 `ha_applylogdb_ignore_error_list`에 없는 다른 비치명 오류로 대체).
3. master 트랜잭션: `UPDATE t4 SET v=v+1 WHERE id IN (1,2,3); DELETE FROM t4 WHERE id = 10; COMMIT;` → DELETE가 마지막 항목.
4. 대조: `DELETE FROM t4 WHERE id = 9`(slave에서 미리 지움)를 중간에 두고 뒤에 UPDATE 하나 더 → 중간 항목 케이스.

**확인**:
- 기준선(3): slave 로그 `applylogdb reader exit: reason=collect_and_retire error=-711`, applylogdb 종료(heartbeat가 재기동), 트랜잭션 미커밋 → id 1~3의 v 미반영 후 재기동 뒤 재적용.
- 수정 후(3): fail_counter delta +1, id 1~3의 v 반영, applylogdb 계속(`reader exit` 없음).
- (4)는 수정 전후 모두 fail_counter +1·계속.

## 시나리오 1. 워커 적용 중 master 다운 → 승격 노드 DONE 재평가 (fixes/01, 7번 첫 케이스)

**조작** [지시 필요]: master kill(`kill -9 cub_server` 또는 cub_master 포함). 워커 10.

**부하**: 큰 트랜잭션 연속 커밋(`UPDATE big` ×여러 세션) 중 slave 워커가 적용 중인 순간에 kill. 조건은 "copied log가 dead를 보고할 때 slave에 미적용 태스크가 남아 있을 것". `reader retire`가 계속 증가 중일 때 kill.

**확인**:
- 기준선(d43e03e): youngjun4가 `registered_and_to_be_active`에 머묾(10-14 22:07 사건과 동일), DONE 미보고. `LA_DRAIN_TIMEOUT_MSEC` 30초 뒤 백스톱이 걸리는지도 기록.
- 수정 후: 워커가 다 적용한 뒤 `done` 보고, `registered_and_active` 전환. 승격 노드 데이터 = kill 직전 master 커밋분 전부. 전환까지 시간 기록.
- 주의: develop PR #8110 결함(copied log 끝 stale)은 "승격 직후 마지막 트랜잭션 누락, 60초 뒤 반영"으로 나타난다. 이건 기지 신호 5번이며 이 수정의 실패가 아니다. `heartbeat stop`(정상 정지)보다 kill이 그 결함을 덜 건드린다(dead 전환 경로가 다름, 추정).

## 시나리오 6. 부분 롤백·문장 롤백 구간의 복제 레코드와 키 (10-16 추가)

**대상**: develop `repl_log_abort_after_lsa`가 롤백된 구간의 복제 레코드를 버리는지(10-14 리뷰에서 "`log_abort_partial` repl 처리 미검증"으로 미룬 항목), 그리고 같은 자리에 넣은 `wset_abort_after_lsa`(리뷰 C6, 별도 커밋 5606d1a21)가 같은 구간의 키를 버리는지. 코드 경로는 10-16 확인: `log_abort_partial` → savepoint LSA를 부모로 한 sysop → `log_sysop_abort` → 두 함수를 같은 LSA로 호출. 문장 단위 롤백도 같은 `log_sysop_abort`를 지난다. 남은 것은 실행 확인뿐이다.

**조작**: 없음(정상 복제 중 부하만). master trace 레벨 3(키 단위 PROBE/PUBLISH)이 필요하므로 이 시나리오 동안만 master `cubrid_ha.conf` `ha_writeset_trace_level=3` [지시 필요], 끝나면 1로 복원·md5 대조. 레벨 3은 처리량이 떨어지므로 다른 시나리오와 같이 돌리지 않는다.

**부하** (master, csql 한 세션, autocommit off):
1. 부분 롤백: `INSERT t VALUES (1,'a')` → `SAVEPOINT s1` → `INSERT t VALUES (2,'b')`, `UPDATE t SET v='x' WHERE id=1` → `ROLLBACK TO SAVEPOINT s1` → `INSERT t VALUES (3,'c')` → `COMMIT`.
2. 문장 롤백: 부모 `p(id PK)`·자식 `c(id PK, pid FK→p)`에서 `INSERT c VALUES (10, 999)`(부모 없음, FK 위반으로 문장 실패) → `INSERT c VALUES (11, 1)`(p에 1 있음) → `COMMIT`.
3. 뒤따르는 트랜잭션: 롤백된 키(t id=2, c id=10)를 쓰는 트랜잭션을 하나씩 커밋해 의존이 어디로 잡히는지 본다.

**확인**:
- slave 데이터: t = {1:'a', 3:'c'}(2 없음, 1은 UPDATE 전 값), c = {11}. fail_counter delta 0.
- master trace 레벨 3: 1·2 트랜잭션의 `PUBLISH` 키에 t id=2, UPDATE된 id=1의 새 값 키, c id=10이 없을 것. 수정 전 빌드(5606d1a21 없음)라면 이 키들이 게시된다(기준선으로 쓸 수 있으면 비교).
- 3의 트랜잭션 `DEPENDENCY`가 1·2 트랜잭션을 가리키지 않을 것(롤백된 키로 생긴 가짜 의존이 없음).
- 기지 신호: `develop - FK 실패로 롤백된 UPDATE가 slave로 복제됨`의 우회 처리(LSA NULL UPDATE 폐기)가 이 경로와 겹치므로, slave에 -48 오류가 없는지도 본다.

## 필요한 스크립트 (신규)

- `verify_worker1_order.sh`: 시나리오 5 부하(세션 3개 연쇄) + 로그 순서 추출.
- `verify_fragment_archive.sh`: 시나리오 2 부하(백로그 + serial ROLLBACK) + `required_lsa_pageid`/`nxarv_num` 0.5초 폴링.
- `verify_last_item_error.sh`: 시나리오 4 부하 + fail_counter delta + `reader exit` 검사.
- 시나리오 1은 `fk_multi_guard.sh` 부하 + 수동 kill + `watch_slave.sh`.
- `verify_rollback_keys.sh`: 시나리오 6 부하(부분 롤백·문장 롤백·뒤따르는 트랜잭션) + slave 대조 + master trace에서 해당 trid의 PUBLISH 키 추출.
