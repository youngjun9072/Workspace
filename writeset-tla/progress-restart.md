# 재시작·크래시 복구·failover TLA+ 검사 진행 기록

대상: PR #8052 브랜치 origin/feature/CBRD-27508-parallel-applylogdb-writeset (6bd39a696). 줄 번호는 이 커밋의 src/transaction/log_applier.c 기준이다. 코드는 git show로만 읽었고 cubrid 트리는 건드리지 않았다.

## 1. 코드에서 확인한 것 (영속 상태와 재시작 규칙)

### 1.1 무엇이 언제, 어느 트랜잭션에 저장되는가

- 반영 데이터와 적용 표시(marker): 워커가 트랜잭션 하나를 적용하면, 같은 slave 트랜잭션 안에서 ha_applied_tx_marker에 (copied_log_path, commit LSA) 한 행을 넣고 커밋한다(la_apply_worker_apply_task 905~951, la_insert_applied_tx_marker 3365). 표시는 total_rows > 0일 때만 넣는다. total_rows는 필터에 걸리지 않은 항목 수이고, 실패해서 넘긴 항목도 센다(la_apply_repl_log 7039). 조각(SYSOP_END fragment)은 SYSOP_END LSA로 표시한다.
- 위치 정보: 코디네이터 연결의 트랜잭션 하나에서 _db_ha_apply_info 갱신(committed_lsa, committed_rep_lsa, required_lsa, final_lsa 등), 통계 행 저장, 그리고 committed_lsa 이하 표시 삭제를 한 번에 커밋한다(la_coordinator_commit_apply_info 1172). 통계 저장이 실패하면 전체를 abort해 표시는 남는다.
- 저장 시점: 태스크 하나가 retire될 때마다 ha_applylogdb_max_commit_interval_in_msecs 간격으로(la_coordinator_store_apply_info_at_interval 816), 그리고 la_log_commit(7994)이 불리는 곳(주기 commit, 상태 변경, HA 서버 상태 레코드, DONE 뒤 처리).
- 저장되는 committed_lsa는 메모리 committed_lsa와 기동 때 읽은 last_committed_lsa 중 큰 값이다(la_update_ha_last_applied_info 3001). 메모리 committed_lsa는 retire 때 gate frontier로만 올라간다(la_coordinator_retire_entry 753).
- required_lsa는 la_log_commit에서만 다시 계산한다(la_find_required_lsa 2312: 열린 repl_lists 슬롯의 start_lsa, in-flight·pending 태스크 슬롯의 start_lsa 중 최소, 없으면 final_lsa). retire 경로 저장은 마지막으로 계산한 값을 그대로 쓴다.

### 1.2 재시작이 읽는 것

- la_get_last_ha_applied_info(2855): 저장된 위치를 읽고 last_committed_lsa = 저장된 committed_lsa.
- la_load_applied_tx_markers(3199): 이 copied log의 표시 중 last_committed_lsa보다 큰 것을 정렬해 메모리에 올린다. 일부만 읽히면 기동 실패로 처리한다.
- 9811: committed_lsa = required_lsa, la_apply_pre(3757): final_lsa = committed_lsa. 즉 required_lsa부터 다시 읽는다. gate frontier는 첫 커밋 제출 때 committed_lsa(= required_lsa)로 시작한다(la_gate_set_initial_frontier).

### 1.3 다시 읽은 커밋을 건너뛸지 판단

- la_apply_repl_log(6976): commit LSA가 last_committed_lsa 이하이거나 기동 때 읽은 표시에 있으면 트랜잭션(또는 조각) 전체를 건너뛴다. 항목 단위 필터는 없다.
- 트랜잭션의 첫 레코드(prev_tranlsa NULL)를 읽을 때만 슬롯을 만든다(7560). 슬롯 없는 트랜잭션의 항목은 버린다(la_set_repl_log 4573). 그래서 시작이 재시작 지점보다 앞인 트랜잭션은 항목 없이 커밋만 읽힌다.
- LOG_COMMIT은 committed_lsa보다 클 때만 태스크가 되고(7621), SYSOP_END도 committed_lsa보다 클 때만 조각으로 떼어 낸다(la_coordinator_process_sysop_end 7322).

### 1.4 승격(DONE)이 기다리는 것

- la_change_state(7874): 로그 끝까지 읽었고 copied log가 SYNCHRONIZED이고 master가 DEAD/STANDBY/MAINTENANCE일 때, la_coordinator_drain_complete(pending 없음, in-flight 없음, commit-order ring 비어 있음)가 참일 때만 DONE을 알린다. 아니면 done_deferred로 보류한다. DONE 전에 la_log_commit으로 위치를 저장한다.
- DONE 뒤 master가 DEAD가 아니면 repl_lists를 비우고, 다음 반복에서 committed_lsa = final_lsa(frontier로 제한)로 저장한다(9997~10007).
- 백스톱 타임아웃은 없다(C6에서 제거).

### 1.5 확인했지만 결함이 아닌 것

- la_apply_pre가 final_lsa를 committed_lsa(frontier)로 되돌리는 문제: 바깥 do-while이 shutdown 없이 다시 도는 경로를 찾지 못했다. 가운데 루프를 빠져나가는 break는 모두 la_applier_need_shutdown을 세운다. 그래서 같은 런 안에서 frontier부터 다시 읽는 일은 없다.
- 라벨 보관이 한 칸뿐인 점: master가 항목, 라벨, 커밋을 prior_lsa_mutex 안에서 연속으로 쓴다(log_manager.c 5030 log_append_repl_info_and_commit_log). 라벨과 경계 사이에 다른 트랜잭션 레코드가 끼지 않는다.
- DDL 자동 커밋: la_update_query_execute는 db_execute만 부르고, applier 세션은 auto commit이 아니다. DDL과 표시가 같은 slave 트랜잭션에 들어간다.

## 2. 모델 (RestartFailover.tla)

- 고정된 master 로그를 레코드 하나씩 읽는다. 레코드 종류는 항목(ITEM), statement(STMT, DDL), 라벨(LABEL, 경계 바로 앞), 라벨 붙은 SYSOP_END(조각), 라벨 없는 SYSOP_END, COMMIT, ABORT, master 재기동 표시(MREC, 이후 라벨이 회복된 로그 끝을 바닥으로 가짐, C1)이다. LSA는 로그 위치 번호다.
- 적용 단위(unit)는 COMMIT 또는 라벨 붙은 SYSOP_END다. 단위의 항목은 같은 트랜잭션의 직전 조각 이후 항목이다. master 라벨은 앞선 단위 중 키가 겹치는 마지막 것이고(statement는 모든 단위와 겹침), MREC 뒤에서는 MREC 위치가 바닥이다.
- 코디네이터: 첫 레코드에서만 슬롯 생성, 슬롯 없으면 항목 버림, 라벨 보관 한 칸, SYSOP_END·COMMIT은 committed_lsa보다 클 때만 처리, 조각 떼어 내기, 바깥 커밋 의존을 조각까지 올림, 라벨 없는 커밋은 ring 꼬리로, la_gate_bound_dependency, 초기 frontier = committed_lsa, drain_ready, pending, in-flight FIFO, retire 때 committed_lsa = frontier와 슬롯 반환을 코드대로 옮겼다.
- 워커: 큐의 태스크 아무거나 골라 적용, 표시, 커밋을 한 번에 한다(slave 트랜잭션이 원자적이므로 커밋 전 크래시는 "안 함"과 같다). commit LSA가 last_committed_lsa 이하이거나 기동 때 읽은 표시에 있거나 항목이 없으면 건너뛴다.
- 저장: retire 때(이전에 계산한 required_lsa 사용) 또는 la_log_commit(다시 계산) 때, committed = max(메모리 committed, last_committed), required, committed 이하 표시 삭제를 한 번에 한다.
- DONE: 로그 끝, master DEAD, drain_complete일 때 저장 후 승격한다.
- 크래시: 실행 중 아무 단계에서나, MaxCrash번까지. 메모리(슬롯, 라벨, ring, frontier, pending, 큐, in-flight, 결과)는 사라지고 DB(적용 내역, 표시)와 apply info는 남는다. 재기동은 1.2절 규칙대로 한다.
- 불변식: NoDuplicate(단위 두 번 적용 없음), WholeUnits(slave 커밋 하나가 정확히 master 단위 하나, 부분 적용이나 합쳐 적용 없음), ConflictOrder(겹치는 단위는 master 순서대로), StoredPrefix(저장된 committed_lsa 이하 단위는 모두 적용됨), MarkersApplied(표시는 적용된 단위에만), PrefixOnPromote(승격 시 모든 단위 적용). ExactlyOnce = NoDuplicate + WholeUnits + PrefixOnPromote.
- 시나리오: A(긴 트랜잭션 T3과 serial 조각, T1→T2 충돌, DDL, DDL 뒤 T3 커밋, 16레코드), B(시작 순서와 커밋 순서가 반대, abort된 트랜잭션의 조각), C(DDL 연속과 사이의 독립 커밋), D(master 재기동 MREC과 loser abort, C1 바닥 라벨), E(라벨 붙은 조각 뒤 라벨 없는 SYSOP_END).
- 변이(정상 모델에서 하나씩 끈 것): BugMarkerOff(표시 안 넣음), BugNoDrainGate(DONE이 drain을 안 기다림), BugRequiredFinal(required_lsa가 열린 슬롯 무시), BugGateOff(게이트 통과), BugNoFragDetach(조각 안 떼어 냄).

## 3. 실행 기록

### 3.1 1차 (11-06 16:13~16:30)

- 첫 실행에서 StoredPrefix 반례가 나왔으나 모델 오류였다. Max와 Min 정의가 뒤바뀌어 슬롯이 만들어지지 않았다. 고친 뒤 다시 돌렸다.
- 정상 모델, 크래시 1~3회: A(5.1만/10.5만/15.8만 상태), B(4.5천/9.4천/1.4만), C(2.2천/4.4천/6.6천), D(4.6천/9.2천/1.4만), E(3.7천/7.7천/1.2만) 모두 위반 없음, 교착(deadlock) 없음.
- 변이 확인(A, 크래시 1회): BugMarkerOff → NoDuplicate 위반, BugNoDrainGate → PrefixOnPromote 위반, BugRequiredFinal → StoredPrefix 위반(StoredPrefix를 빼면 PrefixOnPromote 위반), BugGateOff → ConflictOrder 위반, BugNoFragDetach → StoredPrefix 위반(WholeUnits만 넣으면 WholeUnits 위반). 불변식마다 잡을 수 있는 변이가 있다는 것을 확인했다.
- 해석: 코드대로 옮긴 재시작 규칙(저장된 committed 이하는 위치로, 그 위는 표시로 건너뜀, required_lsa부터 다시 읽음, frontier를 required_lsa에서 시작)은 이 크기에서 중복, 유실, 부분 적용, 순서 역전을 만들지 않는다. DONE은 drain_complete 때문에 빈틈 없이 승격한다. D에서 MREC 바닥 라벨도 la_gate_bound_dependency 덕분에 교착하지 않는다.

### 3.2 확장 (11-06 16:35~)

- 모델에 추가한 것: master가 끝날 때 상태(MasterEnd: DEAD 또는 STANDBY. STANDBY면 DONE에서 la_clear_all_repl_lists 뒤 저장하고, 다음 반복에서 committed_lsa = final_lsa를 frontier로 제한해 다시 저장, 9988~10019), DONE 뒤 applier 크래시와 재기동(CrashAfterDone, 승격된 노드에서 applier가 다시 뜨는 경우), 재기동 때 라벨 보관을 유지할 수 있음(KeepLabel. log_applier_wset_label.cpp의 파일 static은 la_init·la_shutdown이 지우지 않아 프로세스 안 재시작에서 남는다. 코드 확인).
- 시나리오 F 추가: 한 트랜잭션에 조각 두 개, 그 사이와 뒤에 DDL, 로그가 끝날 때 아직 열린 트랜잭션(T3, master가 커밋하지 않음).
- 실행(크래시 2회, KeepLabel, CrashAfterDone): A, B, C, D, E 각각 DEAD와 STANDBY 모두 위반·교착 없음(A 10.5만, B 9.4천, C 4.4천, D 9.3천, E 7.7천 상태). A~E는 로그 끝에 열린 트랜잭션이 없어 DEAD와 STANDBY 상태 수가 같았다.
- F: DEAD 크래시 1회 5.3만, 2회 11.0만, STANDBY 크래시 1회 5.3만, 2회 11.0만 상태, 모두 위반·교착 없음.

## 4. 판정

### 4.1 반례

- 정상 모델에서 나온 반례는 Max/Min 정의 실수 하나뿐이었고 모델 오류로 판정해 고쳤다. 코드 결함으로 이어진 반례는 없다.

### 4.2 결함 판정: REAL DEFECT 없음

이 영역(재시작, 크래시 복구, 승격)에서 코드 경로로 확인된 결함은 찾지 못했다. 모델이 확인한 범위는 다음과 같다.

- 저장된 committed_lsa 이하는 위치로, 그 위는 표시로 건너뛰는 규칙과, 표시를 committed_lsa 저장과 같은 트랜잭션에서 지우는 규칙이 맞물려 어떤 크래시 시점(최대 3회)에서도 중복 적용, 유실, 부분 적용이 없다.
- required_lsa가 아직 retire되지 않은 태스크와 열린 슬롯의 시작보다 앞에 머물러, 재기동이 미적용 트랜잭션을 중간부터 읽는 일이 없다. retire 경로 저장이 오래된 required_lsa를 쓰는 것도 하한이므로 안전하다.
- 재기동 frontier를 required_lsa에서 시작해도, required_lsa 아래의 단위는 모두 적용돼 있으므로 순서가 깨지지 않는다.
- DONE은 drain_complete를 기다리므로 승격 시 읽은 커밋은 모두 적용돼 있다. STANDBY 끝 경로와 DONE 뒤 재기동도 저장 위치를 빈틈 없는 prefix로 유지한다.
- statement(DDL)는 표시와 같은 slave 트랜잭션에서 커밋되고(applier 세션은 auto commit이 아님, la_update_query_execute → db_execute), 재기동에서 표시로 건너뛰므로 두 번 실행되지 않는다(C17 수정 74acb3ea8의 방식이 현재 코드에 남아 있음).

### 4.3 범위 밖이거나 추정으로 남기는 관찰

- 라벨 보관이 프로세스 안 재시작에서 남는다(log_applier_wset_label.cpp, 초기화 함수 없음). 남은 라벨은 다시 읽는 구간에서 그 트랜잭션의 LABEL을 다시 만나기 전에 같은 trid의 경계를 만날 때만 쓰인다. master는 복제 항목을 라벨 붙은 SYSOP_END 안이나 커밋 직전(라벨, 커밋과 같은 prior_lsa_mutex 안)에만 로그에 쓰므로(log_manager.c 4030, 5030, locator_sr.c 13181), 라벨 없는 SYSOP_END 때 슬롯 항목은 비어 있고 complete_without_task만 일어난다. 해롭지 않다고 판단했다(모델 KeepLabel 실행으로도 확인). 정리 차원에서 la_init에서 비우는 것이 깔끔하다.
- 항목 루프의 재시도(la_retry_on_error에 ER_LK_UNILATERALLY_ABORTED, ER_LK_DEADLOCK_CYCLE_DETECTED 포함)는 같은 항목만 다시 적용한다. 서버가 트랜잭션 전체를 롤백한 오류라면 앞 항목은 사라진 채 나머지와 표시가 커밋되고, 재기동은 표시를 보고 건너뛰어 앞 항목이 영구히 빠질 수 있다(추정). 행 항목의 교착은 flush 경로에서 ER_LC_PARTIALLY_FAILED_TO_FLUSH로 바뀌어 applier 재시작이 되므로 이 경로에 오지 않는다. 여기에 오는 것은 statement 실행(앞에서 flush를 먼저 함)과 클래스 조회 오류다. 루프는 develop과 같으므로 이 PR의 회귀는 아니고, statement는 master에서 barrier라 워커끼리 교착할 일도 적다. NEEDS HA REPRO, 다른 영역(항목 오류 정책).
- 커밋 태스크의 슬롯은 retire까지 tranid를 유지한다. 그 사이 같은 trid의 새 트랜잭션이 시작되면 옛 슬롯에 항목이 붙는다(la_add_apply_list). master trid는 계속 증가하므로 실제로는 일어나지 않는다고 본다(추정, 확인 안 함).
- 더 큰 범위(11-06 19:18): F, STANDBY, 크래시 3회, DONE 뒤 크래시 허용 16.6만 상태, A, DEAD, 크래시 4회, DONE 뒤 크래시 허용 21.2만 상태. 둘 다 위반·교착 없음.
- 확인: master trid는 log_Gl.hdr.next_trid에서 계속 증가하고(logtb_get_new_tran_id), 재기동 분석은 END_OF_LOG 레코드의 trid로 next_trid를 맞춘다(log_rv_analysis_log_end). 4.3절 셋째 항목(같은 trid 재사용)은 실제로 일어나지 않는다고 본다. 다만 END_OF_LOG에 어떤 trid가 들어가는지는 확인하지 않았다(추정).
- 메모: 이후 TLC 상태 디렉토리는 /home/youngjun/tools/tlc-meta/restart/<런 이름>에 두고 끝나면 지운다(/tmp가 RAM이라서).
