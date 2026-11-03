---
tags: [todo]
date: 2026-10-25
---

# CBRD-27508 지금 남은 일 (한 곳 목록)

남은 일은 이 파일 하나에서만 관리한다. 끝나면 줄을 지우고, 새로 생기면 여기에 더한다. 자세한 내용은 각 줄의 문서를 본다.

## 정확성 (먼저)
- [x] (완료 10-30) 최우선(10-29~): 상속 계층 공유 unique 인덱스에서 writeset 키가 행의 클래스 OID로 갈려 충돌 누락(sup 삭제 뒤 sub 삽입·역방향, 상위 PK 참조 FK에서 부모 행이 하위 클래스). 조사·비교 문서=_impl/fixes/10-inherited-index-writeset-key.md. 방안 A(해시에서 클래스 OID 제거, VFID+키) 추천·사용자 결정 대기. 할 일: wset_fnv1a, 문서 01 3.1, 단위 테스트(stress·bench VFID 분리 포함), HA 시험 3종 ★10-29 저녁: A 커밋 0ab0a6173(미푸시), 단위 테스트·stress/bench VFID 분리 미커밋, 문서 01 3.1 갱신. 남은=빌드→UT·HA 재시험(01 대조군, C3) ★10-30: A 0ab0a6173·UT 6c6fe71a8 푸시, HA 01 대조군 PASS(10-29 23:45 빌드 2956), UT PASS(10-30 16:3x 빌드 2969, writeset 47 케이스·4728 assertion, 상속 테스트 포함). 조합 C3 PASS(10-30 17:15 빌드 2969, T2 source=REF_SLOT dependency=T1 커밋 225|4240, slave 오류 0, master·slave 0:0, `cases/pair_c3_20261030.sh`, log pair_order_20261030_1715_c3). 시험 3종 통과로 완료
- [ ] 순서 의존 후보 16개 HA 재현(10-29 목록화, 모두 미시험) = _impl/fixes/11-missed-ordering-scenarios.md. 스크립트 준비됨(pair_order_test.sh, cases/pair_cases_20261029.sh). 재현은 지시 후
- [ ] **slave 서버 kill 뒤 applylogdb 7분 정지**: 10-17, 10-24 campaign 첫 서버 kill에서 한 번씩. 멈출 때 스택을 남기게 하니스를 고쳐 재현 (10-25 두 번의 회귀에서 서버 kill 5회 동안 재현 안 됨)

## Greptile 2차 리뷰 (커밋 `8d8d87c16`, 5건) — 10-28 결정 순서: 시험 끝 → 마커 문서(fixes/08) 코드 수정 → 1~3번 확인 → 4·5번
- [ ] 1번 재적용하면 이전 키가 남음(`log_applier.c:7344`): `72650ce0d` 마커, 10-28 22:56 마커 빌드 PK 시험 유효 회차에서 T1·T2 rows=0 건너뜀·데이터 일치
- [ ] 2번 statement marker 출처 구분 없음(`:10235`): `72650ce0d`에서 copied_log_path 열로 해결
- [ ] 3번 기존 DB에 `max_committed_lsa` 열 없음(`:3491`): 확인함, `fe230a932`로 열 제거(빌드 시험 전)
- [ ] 4번 페이지 고정 목록 256 초과(`:2456`): 미확인
- [x] 5번 종료 시 sysop 조각 LA_APPLY 누수(`:8997`, P2): 미확인 ★10-29 재오픈(같은 프로세스 retry 확인) ★10-30 수정(미커밋): `la_shutdown`에서 in-flight·pending의 조각 슬롯 해제(`la_free_unretired_fragments`). 빌드 2956 시험(`ha_bench_tool/bin/fragment_shutdown_leak.sh`, slave serial 행 잠금으로 종료 시 조각 ~220개 남김, 20회): 데이터 일치, 크래시 없음. gdb malloc_info로 재시작당 힙 +136~160KB → 조각 없는 대조(MODE=update, 커밋 ~230개만 남김)도 +150KB로 같음 = 조각은 해제됨, 남은 누수는 `repl_lists` 슬롯 항목(아래)
- [x] 5번 관련: `la_shutdown`이 `repl_lists` 슬롯 구조체만 free하고 항목은 안 해제(develop 코드, 병렬판에서 pending·in-flight 커밋 항목까지 남아 커짐). ★10-30 수정(미커밋, `la_free_all_repl_items` 추가). 재빌드 뒤 MODE=update·serial 재시험으로 재시작당 힙 증가 0 근처 확인 → 그 뒤 5번 정정 답글 ★10-30 01:30~01:57 재시험(빌드 01:24): 재시작당 힙 update 150→~90KB, serial 136~160→~90KB(남긴 양 무관) = 둘 다 해제됨. 커밋 fb5fb198a(조각)·78cd10ce5(repl_lists), 푸시, 정정 답글 r4415407584
- [ ] 남은 재시작당 힙 ~90KB(조각·커밋 수 무관): 잠금 없이 kill만 20회로 develop 재연결 비용인지 확인 → develop이면 todo ★10-30 02:35 야간 실행(`ha_bench_tool/bin/night_20261030.sh`: nolock kill 20회 → 06 재시험 → campaign A~F, 로그 `log/night_20261030.log`)
- [ ] 답글: 1~5번 확인 후 사용자 결정 뒤

## Greptile 3차 (head bf560620e, 10-29 00:55) — 확인함, 수정 지시 대기
- [x] P1 `log_applier.c:1084` 완료된 작업을 기다리며 멈춤: collect_results가 결과를 다 받은 뒤 retire 없이 drain → enqueue → wait_for_inflight_slot이 목록이 꽉 차면 retire 전에 새 결과를 기다림(오지 않음). 수정안: 기다리기 전에 retire_results ★10-29 문서화: _impl/fixes/09-inflight-slot-wait.md (3칸 예시 = 커밋 메시지에 사용) ★10-29 c1674aaa5 푸시·답글. HA 재현(워커2, slave 행잠금): retire 후 목록 0칸 gdb 확인
- [ ] P1 `writeset.cpp:640` TIMESTAMPTZ·DATETIMETZ 해시에 tz_id 포함(서버 비교는 tz 무시). 수정안: 해시 전 tz 뺀 값(단일·복합 원소·FK REF 3곳) + UT
- 2차 5번(종료 시 조각 슬롯)은 Greptile이 철회

## 10-29 새로 본 것
- [x] 큰 행(5MB) 시 slave applylogdb -81 재시작(2934 5회, 2939 7·8회). ★10-29 원인 확정: PoC 가드(9488a3419 "torn-page guard", `log_applier.c:10747~10769`)가 forw_lsa > 받은 끝(append)을 손상으로 판정. 실측 레코드 3755086|5168(UNDO, 330페이지)의 forw 3755416|3920은 다음 레코드 back_lsa와 일치 = 정상값. develop은 뒤로 가는 경우만 검사하고 앞선 경우는 기존 대기 코드가 처리. 수정안(develop 조건으로 되돌림) 지시 대기. (er_log_debug는 PRM_FOR_SERVER라 applylogdb에 안 먹음) ★10-29 20442b73b(develop 조건) 푸시, 큰 행 시험 -81 0건
- [ ] 워커 레코드 풀(200칸)이 큰 행 할당을 칸 재사용 때까지 붙잡음 → 워커 10개면 행 크기×2000까지(2.7MB 행이면 ~5.4GB, mem 한도 4096 초과 가능). 수정안: flush 뒤 큰 할당 즉시 해제. develop도 ×200
- [x] kill_server "7분 정지" = ★하니스 판정 오류로 확정(10-29). kill_slave_proc.sh의 server 재개 판정이 applylogdb 새 pid를 요구(`[ "$(spid)" != "$apid0" ]`)하는데, applylogdb가 죽지 않고 새 서버에 다시 붙은 회차는 이 조건을 영영 못 채워 300s 타임아웃(+스택 수집 시간)으로 FAIL. 실제로는 2939 kill 12회의 FAIL 6회 모두 kill 뒤 21~28s에 committed_lsa가 다시 움직이기 시작했고 데이터 12회 모두 일치. 하니스 수정 완료(10-29 13:58, 재개 판정에서 applylogdb 새 pid 조건 제거) → 재시험 12/12 PASS(42~54s, applylogdb 생존 6회·재시작 6회, 데이터 일치·fail_counter 0, log kill_server_loop_20261029_135906). 재접속 뒤 trace 0줄은 레벨 문제가 아니라 로그 파일이 바뀐 것(아래 develop 결함 항목). 자료 ha_bench_tool/log/kill_server_loop_20261029_104646

## 재빌드 뒤 — 10-26 02:55 빌드 2863-14b244b 회귀 끝 (`ha_bench_tool/log/campaign_20261025_214920`)
- [ ] 재빌드 필요: worker sub-client 수정 3d86d075b(기동 실패 시 db_shutdown_sub)·685938ce2(오류 컨텍스트 이중 등록, debug에서 assert)·UT 95a2c42b3. HA는 아직 14b244b
- [ ] 의도치 않은 failover 4회(10-26 17:19, 18:27, 10-28 14:37 빌드 2880 campaign A bigtx 중 `campaign_20261028_143354/eof`, 10-28 15:18 campaign B 중 `campaign_20261028_151509/eof`, 모두 같은 fdatasync 스택): master active log archive 중 fileio_synchronize_all fdatasync가 공유 디스크에서 15초+ → heartbeat가 디스크 장애로 강등 (develop 경로, eof/eof_stall_182720). 대응 필요 여부 결정
- [ ] C 느려짐 원인 확정(10-26 coord_profile: 복구 구간 끝 저장이 coordinator 시간 64%) → a2안(넘길 묶음을 모아 끝 1회 저장) 결정 대기
- [ ] A안 비용 측정: 큰 트랜잭션·동시 세션 부하에서 master 처리량 (trace 0)

## 결정 필요
- [ ] 시스템 메타데이터 버전 올리기와 `cubrid upgradedb` (slave 통계 카탈로그 2개 추가분)
- [ ] C15 `MULTI_CONN_TO_A_SERVER`: develop은 option 기본 OFF, 이 브랜치는 10-28 `8bf8a3df1`로 기본 ON. develop 기본값은 CS팀 협의

## 지시가 필요한 시험
- [ ] 통계: worker 수 줄여 재기동(conf 변경), failover 뒤 새 master SHOW, 통계 행 잠금 시험

## 나중에
- [ ] [[develop - la_init_repl_lists 할당 실패 처리]]: 실패 경로 이중 해제·realloc 누수·repl_cnt 불일치. 함수 재작성 크기라 범위 밖(10-30 결정)
- [x] (10-30) SYSOP_END 전수 시험(`ha_bench_tool/bin/sysop_all_test.sh`) 중 결함 발견·수정: flush 표시 구간 안에서 끝나는 시스템 연산(INCR heap 갱신 중 페이지 할당의 LOGICAL_UNDO)이 표시 항목을 위치 없이 먼저 써서 slave가 건너뜀 → INCR 3/100 유실(fail_counter 0). Greptile 5차(같은 원인의 abort 경로) 함께 해결. 커밋 501e5f315 푸시·답글. 수정 빌드 2968-b929faf(주석만 다름)에서 UT·p06·전체 26건·p07 abort PASS. 같은 INCR 안 페이지 할당+abort 겹침은 재현 못 해 코드로 확인
- [ ] (10-31 01:17 시작, 약 8시간) campaign A~F + 새 G(최근 수정 회귀: pairs 27건, sysop, inflight, markerload, markerlock, bigrecord), SOAK_HOURS=3, 빌드 2985-772a6a0, log/campaign_20261031_011702. 결과 확인 뒤 c5fdd4c59·ff85087c0·772a6a0c1 푸시와 Greptile 답글(마커 로드·MONETARY·마커 삭제 순서)
- [ ] (10-31 실측) 인덱스가 같은 키로 보는데 해시가 갈리는 타입: VARBIT, 문자열 중간 공백/NUL(iso88591_bin, utf8_ko_cs), euckr_bin NUL+전각 공백, DOUBLE NaN 모두 HA에서 -670·행 유실 확인, 미수정. 문서 _impl/fixes/12-index-equal-key-hash-survey.md. locale·UCA 콜레이션 가중치 0 글자는 미실측
- [ ] (11-01) 문자열 키 해시가 `mht2str`(develop 해시 테이블 버킷용 ELF 해시, 실제 28비트)로 먼저 접힘 → 서로 다른 문자열이 같은 키가 되어 불필요한 기다림(순서 누락은 아님). 같은 식 Python 재현: 날짜+번호 패턴 100만 개 중 47% 겹침, 무작위 12자 0.2%. 단일 문자열 키와 복합 키 문자열 원소 모두(`wset_pack_string_key`). 1안=`_bin` 계열은 정규화 바이트 전체를 FNV-1a 64비트로 바로(나머지 collation은 mht2str 유지, 9절 한계), 2안=가중치 기반 64비트(mht2str 5개 구현 재작성 ~200줄). 1안 전 `_bin` 비교가 정리 뒤 바이트 비교와 같은지 코드 확인 필요. HA 병렬성 실측 미실시. 문서 01 3.2 갱신 필요
- [ ] (develop 결함) DOUBLE NaN 저장 시 unique 인덱스가 모든 값과 같은 키로 봄(MR_CMP). MySQL 8.0·9.7은 저장 단계에서 0/NULL로 바꿈
- [ ] (후속, Greptile 4차 2번 답글에 "후속으로 남김"이라 적음 10-30) slave에서 라벨 없는 LOG_SYSOP_END도 항목이 있으면 커밋 순서로 독립 적용(A-3). 업그레이드 전 로그·라벨을 쓰지 않는 master 로그는 지금 바깥 트랜잭션으로 미뤄져 ABORT 때 버려짐. master 쪽은 3fb54e549(A-2)로 같은 버전 경로만 막음
- [ ] [[develop - 되돌린 INCR 증가가 slave에 남음]]: 여러 행 INCR 중간 실패, instant lock 모드 해제 뒤 바깥 abort. 코드로만 확인(10-30), develop·이 브랜치 재현 필요. A-2 뒤 이 브랜치도 develop과 같은 결과
- [ ] CBRD-27564 serial write-back 복제 HA 확인: 10-28 develop 3bf88f36d 병합(`16d7c411f`) 끝. 코드상 write-back도 같은 `serial_update_serial_object` sysop을 거쳐 우리 serial 조각 라벨을 받음(추정). 병합 빌드 배포 뒤 c9·c14·sysop_skip과 serial 섞인 DDL로 확인
- [ ] **A안 최적화 (A')**: A안은 history 조회 전체를 `prior_lsa_mutex` 안에서 하므로, 키가 많은 트랜잭션(키 10만 개면 약 2~30ms, 100만 개면 약 20~300ms 추정)과 history 비우기 동안 master의 모든 로그 기록이 멈춘다. 조회는 잠금 밖에서 하고, 잠금 안에서는 LSA 두 개(`last_commit_lsa` 마지막 기록 커밋, `last_barrier_lsa` 마지막 commit-order 커밋)로 라벨을 올리기만 하면 같은 결과를 잠금 안 비교 두세 번으로 얻는다. A 적용 뒤 큰 트랜잭션·동시 세션 부하에서 master 처리량을 재고, 차이가 크면 A'로 바꾼다. 주의: "최근 커밋" 변수가 `prev_commit_lsa`와 둘이 되는 것, trace가 최종 라벨을 찍어야 하는 것, serial 조각도 같이 바꿔야 하는 것
- [ ] 리뷰 미검증 주장 2~7번 코드 확인 (리뷰 종합 4절)

## 기준 해시 (10-28 17:08 PR #8052 덮어쓰기)
- 작업: `~/Workspace/cubrid` 브랜치 `feature/CBRD-27508-parallel-applylogdb-writeset` = `b2781cd09`(10-28 17:4x, 커밋 메시지의 Claude 줄 제거 후 강제 푸시), PR #8052 head도 같음. 그 전 `48afc8025`(코드 스타일 커밋), `8d8d87c16`(되돌림 기준과 같은 트리)
- (10-29 00:5x 푸시 완료, PR head bf560620e(고정 목록 realloc), 그 아래 50c1729d7 = 원격 develop merge 9d8535f35 위에 merge) 커밋: `3e6f50ff0`(history map 주석), `19e83a5d9`(map find→probe), `72650ce0d`(applied-tx 마커, 10-28 23시, 그랩타일 2차 1·2번). HA 설치 2932-19e83a5는 72650ce0d와 코드 같음(주석만 다름). `fe230a932`(재적용 대비 코드 제거, 그랩타일 3번). 다음: 빌드·DB 재생성(카탈로그 열 바뀜) 뒤 PK 시험·회귀
- 되돌림 기준(지우지 말 것): 브랜치 `feature/CBRD-27508-on-26779` `8d8d87c16`(origin에도 있음). 워크트리 `cubrid-applier`는 10-28 17:3x 정리, `~/Workspace/cubrid`에서 `git show`/`git diff`로 본다
- 덮어쓰기 전 PR 브랜치: origin `ccc63cf59`, 로컬 `fd13cc3da`
- [ ] (develop 결함, 범위 밖) applylogdb가 서버 재시작 뒤 프로세스 안에서 재접속하면 이후 에러 로그가 `testdb@localhost_applylogdb_<노드>.err` 대신 `$CUBRID/log/cub_client.err`로 감(10-29 확인, 2939에서 10:48:06부터 15만 줄). 순서: db_shutdown→boot_shutdown_client(true)→er_final(ALL)로 sticky 해제 → retry의 db_restart→boot_restart_client가 er_init(PRM_ER_LOG_FILE 기본 cub_client.err)로 sticky 설정 → util_cs.c applylogdb retry의 er_init(er_msg_file)은 sticky라 바로 return. util_cs.c·error_manager.c·boot_cl.c 해당 부분 develop과 동일. 영향: 하니스가 applylogdb 로그만 보면 재접속 뒤 오류를 못 봄(kill 시험 worker_error_lines 등). 하니스는 10-29 14:2x 수정: verify_common slog_* 4개가 두 파일을 읽고 시각순 병합(위치=applylogdb줄×1e9+cub_client줄), tail -F 수집 6개·guard 2개·ddl_mix·zero-trace 2곳도 포함(백업 bin/.bak_20261029_clientlog). 미수정=옛 단발 스크립트(crash_*, failover_*, collect_evidence, fk_rerun, fk_multiref, _marker_collect, marker_overhead, pk_reapply_repro, night2). cub_client.err엔 applyinfo·csql 기록도 소량 섞임
- [x] Greptile 3차 (b) TIMESTAMPTZ·DATETIMETZ 해시 357f0568a 푸시·답글(10-29). HA 단일·복합·FK REF 의존 확인. ★단위 테스트 미실행(UNIT_TESTS=ON 빌드 대기)
- [ ] Greptile 2차 5번(`log_applier.c:9028` 종료 시 sysop 조각 슬롯 미해제) 재오픈: 우리 답글 전제("프로세스당 la_apply_log_file 1회")가 틀림. util_cs.c retry로 같은 프로세스 재시작 확인(서버 kill 5회 pid 유지). 누적은 코드로만 확인 → 수정+시험(서버 kill 반복 중 조각 태스크 남긴 채 종료, 메모리 측정) 후 정정 답글
