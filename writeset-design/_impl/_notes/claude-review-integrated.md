# writeset 마스터측 통합 리뷰 — 4개 페르소나 병합 + end-to-end 재검증

- 대상: 커밋 74f9e0a1c `[CBRD-27508] Implement writeset dependency generation for replication` (26파일)
- 방법: 1·3·5·10년차 페르소나 리뷰 각 30건(총 120건)을 중복 병합하고, 문제로 제기된 항목 전건을 코드 end-to-end 재검증으로 판정해 기록했다. 페르소나별 원문은 이 최종본에 병합 후 폐기.
- 판정 범례: **CONFIRMED**(코드로 확정) / **REFUTED**(코드·문서로 반박) / **OPEN**(정적 분석으로 판정 불가, 실측·후속 확인 필요)
- 일자: 2026-09-30

---

## 1. 확정 결함 — 수정 필요 (CONFIRMED)

### C1. [HIGH] WSET_LABEL append 실패를 무시하고 라벨 없는 COMMIT 기록 (미완 FIXME)
- 제기: 4/4 페르소나 (1yr-1, 3yr-2, 5yr-1, 10yr-4)
- 재검증: `prior_lsa_alloc_and_copy_data`는 malloc 실패 시 er_set 후 NULL 반환(log_append.cpp:296-301). `log_append_wset_label_with_lock`(log_manager.c:4755-4759)는 NULL이면 `/* FIXME */ return;`(void)이고, 호출자(4732-4734)는 무조건 `log_append_commit_log_with_lock`으로 COMMIT을 기록한다.
- 설계 대조: 01-master §6:419 "append 실패 시 오류를 호출자에게 전달, 같은 append 경계에서 COMMIT 계속 기록 금지, history 미게시" — 정면 위반. "커밋마다 라벨 정확히 1개" 계약 붕괴. 슬레이브 라벨 누락 검사는 "방어선으로만" 규정돼 있어 마스터가 여기 기댈 수 없다.
- 조치: 실패를 int로 전파해 COMMIT 기록 중단(또는 최소 commit-order 강등+publish 차단). FIXME 해소는 커밋 전 필수.

### C2. [HIGH] 2PC 커밋 경로(log_complete_for_2pc)에 probe/publish 미배선 — NULL 라벨 + history 미게시
- 제기: 3yr-6, 10yr-1 (+이전 세션 기지 이슈)
- 재검증: 1PC 경로(log_commit_local:5320-5324)는 probe→라벨+COMMIT→publish를 수행하고, non-local 분기는 "Postpone ... to log_complete_for_2pc" 주석과 함께 빈 분기(5341-5343). `log_complete_for_2pc`(5865~)의 COMMIT 분기(6088-6090)는 `log_append_repl_info_and_commit_log`만 호출 — probe 없이 라벨이 나가므로 init/clear의 NULL `wset_dependency_seq`가 실리고("의존성 없음"으로 오독), publish가 없어 이 트랜잭션의 WRITE/REF가 history에 영원히 빠진다(후행 로컬 트랜잭션의 의존성 누락 = 무성 발산 방향).
- 설계 대조: 01-master는 2PC 경로 미기술(문서 공백).
- 조치: 2PC COMMIT 분기에 동일 배선, 또는 2PC 트랜잭션을 명시적 commit-order 폴백으로 강제(+02-slave의 NULL 라벨 구분 규칙과 정합). 2PC 담당자 리뷰 필요.

### C3. [HIGH] 설계 §6의 sysop 조각 처리(독립 top operation 라벨·조각 publish·serial 조각 수집) 전면 미구현
- 제기: 5yr-3, 10yr-5 (+main 자체 발굴)
- 재검증: writeset.cpp/log_manager.c에 sysop 배선 grep 0건. `log_append_sysop_end`(3906-3977)는 커밋에서 무변경. 키는 트랜잭션 전역 `wset_hashes`로만 쌓여 바깥 COMMIT LSA로만 게시된다. db_serial in-place 갱신의 old PK는 locator 보조 경로(9006-9012)가 트랜잭션 WRITE로 수집하지만, 설계가 요구한 "LOG_SYSOP_END 앞 WSET_LABEL + sysop-end LSA로 조각 게시"는 없다. 설계문서에 후속 단계 표기도 없음(전수 grep).
- 함의: NEED_FLUSH 복제를 가진 독립 sysop이 슬레이브에서 별도 task 경계가 되는 경우(02-slave 설계 전제) 그 조각에 라벨이 없다. serial은 같은 serial을 쓰는 다음 트랜잭션이 앞 트랜잭션의 바깥 COMMIT까지 과대기(성능)하고, 바깥 트랜잭션 ABORT 시 sysop 복제 항목과 라벨/게시의 정합은 미정의.
- 조치: 구현하거나, 이번 커밋 범위에서 제외라면 설계문서에 명시적 스코프 표기 + 슬레이브 게이트에서의 처리 규칙 확정.

### C4. [HIGH] 해시 충돌 시 WRITE 슬롯 역행으로 진짜 선행 의존성 소실 가능 — 코드가 아니라 설계의 구멍
- 제기: 1yr-2, 3yr-1(+4·20·28), 5yr-7(+15), 10yr-2(+3)
- 재검증(중요한 정정 포함):
  - 코드 사실: `wset_history_map::publish`는 WRITE를 무조건 `LSA_COPY` 대입, REF만 max(writeset_history_map.cpp:60-71). **이는 설계 그대로다** — 01-master §6:414 "WRITE 항목: write_seq = current commit_lsa". 네 페르소나가 인용한 "불변식 #9(WRITE 단조 최댓값)"는 **_impl 4개 문서 어디에도 실존하지 않는 허위 인용**(전수 grep)이다.
  - 그러나 위험 자체는 실재한다: 대입의 안전 근거(row X-lock 직렬화 + publish-before-unlock, 코드 순서로 확인: advance 1047→publish→unlock 5333)는 **같은 키**에만 성립한다. **다른 키가 같은 해시로 충돌**하면 두 트랜잭션 사이에 락 직렬화가 없어 publish 순서가 임의이고, 작은 commit LSA가 나중에 대입되면 write_seq가 역행한다. 이후 그 슬롯의 **진짜 충돌** 트랜잭션이 낮아진 write_seq만 기다려 실제 선행을 놓친다(위반=무성 skip → 발산).
  - 발생 확률: 비문자열 키는 64bit FNV라 1M 라이브 키 기준 전체 충돌 확률 ~1e-8(무시 가능). **문자열 키는 32bit pseudo key**(wset_string_hash: mht2str 결과 4바이트+태그만 해시, writeset.cpp:262-273 확인)라 같은 class+index 안에서 생일 역설로 ~7.7만 개 문자열에 50% 충돌 — 현실적.
  - NULL unique 다중 행(5yr-7)도 락 비직렬 동일 슬롯 대입 역행을 만들 수 있으나, NULL끼리는 의미상 충돌이 없어 그 자체는 무해측이다(단 슬롯 상태 오염은 동일).
- 판정: 구현은 설계 준수(REFUTED as code bug) / **설계가 충돌 케이스를 미고려(CONFIRMED as design defect)**.
- 조치: WRITE도 `LSA_GT`일 때만 갱신(1줄)으로 충돌을 안전측(과직렬)으로 전환하고 01-master §6:414를 같이 수정. WRITE 비순차 publish 회귀 테스트 추가(REF엔 있고 WRITE엔 없음 — 3yr-28).

### C5. [MED] cubrid dumplog(log_dump_record)에 WSET_LABEL 누락 → 덤프 순회 중단
- 제기: 1yr-8, 5yr-9 (10yr-28은 확인 필요로 표기)
- 재검증: 덤프 switch의 no-op 더미 그룹(LOG_DUMMY_HEAD_POSTPONE/CRASH_RECOVERY/OVF_RECORD/GENERIC...)에 LOG_DUMMY_WSET_LABEL 없음 → default에서 "Unknown record type" 출력 후 `LSA_SET_NULL(log_lsa)`로 순회 종료(직접 확인). log_to_string에는 케이스가 있어 이름은 찍힌다. 커밋 메시지의 "log traversal paths" 주장과 불일치.
- 조치: 더미 그룹 case 추가(1줄).

### C6. [MED] savepoint 부분 롤백이 wset_hashes를 되감지 않음 — "수집 키 == 복제 행" 불변식 위반
- 제기: 10yr-6
- 재검증: wset_hashes 정리는 log_tran_table.c:1613/1698(트랜잭션 initialize/clear, 즉 전체 commit/abort)뿐. log_manager.c의 rollback 경로에는 wset 언급 0건(grep). 부분 롤백은 repl 레코드를 트리밍하지만 롤백된 구간의 키는 커밋 시 그대로 probe·publish된다.
- 함의: 방향은 안전측(과대 의존·과게시)이나, 미복제 행의 WRITE 게시와 실제 참조 없는 REF의 ref_seq 상승은 설계 불변식 위반이고 병렬성을 갉아먹는다.
- 조치: 엔트리에 수집 시점 표식을 붙여 savepoint 되감기, 또는 부분 롤백 발생 트랜잭션의 commit-order 강등. 최소한 설계문서에 현 동작(보수적 잔존)을 명시.

### C7. [MED] or_pack_mem_value 실패가 조용히 packed_len=0 퇴화 해시로 이어짐
- 제기: 3yr-5
- 재검증: `(void) or_pack_mem_value (buf, key, &packed_len);`(writeset.cpp:455, REF 748) — 반환 무시 확인. `packed_len` 초기값 0(417 확인). or_pack_mem_value는 rc!=NO_ERROR(writeval 실패)면 *packed_len을 설정하지 않고 리턴(object_representation.c:5131-5147 확인) → len 0으로 해시 → 그 class+index의 모든 키가 같은 해시. 발생 자체는 희귀(버퍼는 OR_VALUE_ALIGNED_SIZE로 산정)하나, 단독으론 과직렬(안전측)이어도 C4의 대입 역행과 결합하면 위험이 증폭되고, 설계 §7("패킹 실패는 오류 반환")을 위반한다.
- 조치: 반환 NULL/len==0 검사 후 wset_error 경로로 전파.

### C8. [MED] 커밋 publish 경로의 TBB insert가 bad_alloc을 미포착 — 엔진 C 오류모델 위반
- 제기: 3yr-11
- 재검증: `wset_history_map::publish`의 `m_map.insert(acc, hash)`(TBB 노드 할당)와 그 호출 사슬(wset_publish_keys→publish_with_capacity→publish_commit_to_history→log_commit_local)에 try/catch 없음(코드 확인). 수집측 vector는 catch(bad_alloc) 방어가 있는 것과 비대칭. OOM 시 예외가 C 함수 log_commit_local을 관통해 std::terminate.
- 조치: publish 진입점에서 포착해 commit-order 폴백(clear는 이미 안전 수단)으로 전환.

### C9. [MED] dependency ≤ commit_lsa 불변식이 release에서 무방비 — 위반 시 슬레이브 영구 대기
- 제기: 1yr-23, 3yr-9, 5yr-8, 10yr-19 (4/4)
- 재검증: 유일한 방어가 log_manager.c:5322-5323의 assert. 라벨은 이미 prior list에 들어간 뒤라 release에서 위반 라벨이 그대로 로그에 남는다.
- 조치: probe 결과를 라벨 append 전에 검사해 위반 시 NULL(또는 commit-order 폴백)로 클램프 + er_log 경고.

### C10. [LOW] history 용량 검사가 공유락 하 soft-limit — 동시 publisher만큼 일시 초과
- 제기: 5yr-4(+18), 3yr-21
- 재검증: `wset_publish_with_capacity`(writeset.cpp:988-1028 확인)는 rdlock에서 `map.size()+publish_count <= history_size` 검사 후 그 rdlock 하에서 삽입. 동시 publisher N개가 각자 통과하면 합산 초과. 초과 관측자만 wrlock 재확인 후 clear. TBB size()도 동시 삽입 중 근사값.
- 판정: 정확성 무관(용량은 메모리 상한 성격), 초과 폭은 동시 커밋 수 × 키 수로 유계. 사실이므로 기록하되 우선순위 낮음.
- 조치(선택): 원자 카운터 유지 또는 문서에 "soft limit" 명시.

---

## 2. 정적 분석으로 판정 불가 — 실측/후속 확인 필요 (OPEN)

### O1. [HIGH-OPEN] FK 부모 존재검사 락이 커밋까지 유지되지 않아 REF publish-before-probe 전제가 깨질 수 있음
- 제기: 5yr-2 (btree.c:6478 S_LOCK → 6508-6510/29381-29385에서 즉시 해제 추적), 10yr-18 (MVCC 경로 의문)
- 상태: REF→부모WRITE 순서 보장은 "충돌 연산이 락으로 직렬화되어 선행 publish 후 후행 probe" 전제인데, FK 검사 락이 단기라면 자식 INSERT 커밋(publish)과 부모 DELETE probe 사이에 직렬화 지점이 없다. 반대 방향의 안전장치(부모 DELETE의 자식 검사에서의 대기/충돌)가 이를 메우는지는 정적 추적 범위를 넘는다. PoC 실측(설계 6-1: 부모 DELETE가 ref hit 1000으로 대기 성공)은 통상 타이밍의 성립만 보여줄 뿐 적대적 타이밍 미증명.
- 조치: 자식 INSERT vs 부모 DELETE(RESTRICT/CASCADE/SET NULL) 적대적 타이밍 부하 실측을 최우선으로. lock_manager 관점에서 FK 경로 락 지속시간 전수 확인.

### O2. [MED-OPEN] 복합 FK REF와 부모 PK WRITE의 바이트 동등이 실경로에서 미증명
- 제기: 10yr-12 (+1yr-3의 절반)
- 상태: 테스트(test_writeset.cpp:111-166)는 부모 키를 pr_midxkey_add_elements로 재구성해 넣으므로 "재구성 == 재구성"만 증명한다. 실운영 부모 WRITE는 btree 원본 midxkey(heap_attrvalue_get_key)로 들어온다. 원본과 재구성이 1바이트라도 다르면 복합 FK 순서가 무성으로 깨진다.
- 조치: 실제 INSERT/DELETE로 뽑은 부모 PK 키와 자식 REF 해시 일치를 확인하는 통합 테스트(또는 디버그 selfcheck) 추가.

### O3. [MED-OPEN] MIDXKEY(복합 PK/UNIQUE) 내 문자열 요소의 collation 미정규화
- 제기: 1yr-3
- 상태: 단일 문자열 키는 pseudo key로 collation-동등을 접지만, MIDXKEY는 or_pack_mem_value raw 바이트를 해시한다(writeset.cpp pack_value 경로 확인). ci collation에서 'A'/'a'는 b-tree상 같은 unique 키(같은 행 충돌, 락 직렬화됨)인데 바이트가 다르면 다른 해시 → 진짜 충돌의 의존성 누락 후보. 단 midxkey 내부 문자열 패킹이 collation 정규화를 이미 포함하는지는 미확인(1yr도 추정 표기).
- 조치: midxkey 문자열 요소의 packed 바이트를 ci collation 값 쌍으로 실검증. 미정규화 확인 시 C4와 같은 급으로 승격.

### O4. [MED-OPEN] 혼합 버전 HA/구버전 도구의 신규 rectype 53 순회
- 제기: 10yr-10, 3yr-30
- 상태: 신버전 코드의 직렬 applier(la_log_record_process default:break, log_applier.c:6330)와 flashback(499 default:break)은 안전(에이전트 확인). 문제는 **구버전 바이너리**가 신버전 로그를 읽는 조합 — 구버전 log_startof_nxrec류 sizeof-순회는 53에서 오류로 떨어진다. 이는 코드가 아니라 배포 절차 문제.
- 조치: 릴리스 노트에 업그레이드 순서(슬레이브·도구 먼저) 명시.

### O5. [LOW-OPEN] retain_lock=true 커밋 경로에서 publish-before-unlock 불변식 유지 여부
- 제기: 10yr 영향 리포트
- 상태: 정상 경로는 publish(5324)→unlock(5333, retain_lock false일 때) 확인. retain_lock=true면 unlock이 이 함수 밖(호출자)이라 publish가 여전히 선행(더 강함)하지만, 락 이전(lock transfer) 경로들의 의미는 미검토.
- 조치: retain_lock 사용처 목록화 후 각 경로 확인(후속).

---

## 3. 설계 개선·운영 항목 (사실 확인됨, 정확성 무관)

| # | 항목 | 제기 | 요지 |
|---|---|---|---|
| D1 | `ha_writeset_history_size` 이중 용도(per-tx 한도 = 전역 map 용량) | 4/4 (1yr-4, 3yr-8, 5yr-14, 10yr-8·24) | 성격 다른 두 한도가 한 노브. 기본 1M이면 단일 트랜잭션 ~16MB 버퍼 후에야 폴백. 경계 부호도 비대칭(>= vs <=). 분리 권고 |
| D2 | overflow/용량 초과 시 전역 map 전체 clear → 병렬성 절벽 | 3yr-10, 5yr-5, 10yr-13 | 설계 §7 의도대로나, statement 복제 빈발 워크로드에서 반복 clear → commit-order 수렴. 빈도 카운터는 있으니 노출·경보 필요 |
| D3 | {hash,kind} dedup 부재 | 5yr-16, 10yr-17, 3yr-25 | 핫키 트랜잭션 조기 overflow + 중복 publish. 설계 §3 인지, 미완 |
| D4 | NULL unique 키 수집 → 무관 NULL 행 과직렬 | 1yr-12, 3yr-15, 5yr-7 일부, 10yr-7 | 설계는 보수 수집(01 §2.5는 FK NULL만 기술). 비-PK unique NULL 수집 제외 검토 |
| D5 | 매 복제 커밋 seq_lock 전역 뮤텍스 + 라벨 1건 상시 기록 | 3yr-12, 10yr-27, 1yr-21 | baseline은 CAS 단조 max로 락 프리 가능. 라벨 생략은 02-slave 누락 검사 계약과 함께 재검토 |
| D6 | 통계 카운터 미노출(TODO), trace level 3의 행당 클래스명 조회 | 1yr-15, 5yr-28·30, 10yr-14·15 | statdump 노출 전까지 폴백률 진단 불가. level 3은 개발 전용 명시 필요 |
| D7 | 수집 게이트와 커밋 게이트 조건 불일치(`is_active_worker_transaction` 편측) | 10yr-30 | 시스템 워커의 낭비 수집(안전). 게이트 정렬 권고 |
| D8 | finalize의 락 파괴가 quiesce 전제 무강제 | 1yr-10, 5yr-23, 10yr-16 | 비정상 종료 시 UB 가능성. assert 또는 파괴 생략 |
| D9 | 커밋 후 wset_hashes shrink 미수행(워터마크 점유) | 10yr-25 | 임계 초과 시 swap 검토 |
| D10 | dynamic PRM인데 initialize 1회 캐시 | 3yr-13 | non-dynamic화 또는 재읽기 |
| D11 | 에러코드 dbi_compat.h 미반영(6곳 규칙) | 3yr-14, 10yr-11 | 클라이언트 전파 가능 오류 — 반영 필요 |
| D12 | 로그 레코드의 bool 필드(+release 한정 미제로 패딩) | 10yr-9, 3yr-19 | memset은 NDEBUG 제외 확인 — release만 쓰레기 패딩, 단 기존 레코드들과 동일 관행. bool→INT는 이식성 개선으로 유효 |
| D13 | 테스트 공백: locator 배선 미검증 / WRITE 비순차 publish 테스트 부재 / 오류주입·경합 재현 부재 | 3yr-27·28·29, 10yr-12 | C4 수정과 함께 WRITE 역행 테스트가 최우선 |
| D14 | locator_sr.c 디프에 writeset 무관 브레이스 재포맷 대량 혼입 | 3yr 영향 리포트 | 리뷰·bisect·CI indent 검사 방해. 커밋 분리/원복 권고 |
| D15 | 기타 가독성(오류 헬퍼 이원화, goto 흐름, 매직상수, 이름 근접, INT64 혼용, min() 근거 주석 부재 등) | 1yr-5·6·11·14·16~29, 10yr-20·21·23 | 개별 문서 참조. min() 안전 근거(§4 참조)와 "두 스냅샷 독립 시점" 주석은 추가 가치 높음 |

---

## 4. 반박된 지적 (REFUTED — 근거 포함)

| # | 지적 | 제기 | 반박 근거 (main 재검증) |
|---|---|---|---|
| R1 | "설계 불변식 #9(WRITE 단조 최댓값) 위반" | 1yr-2, 3yr-1, 5yr-7, 10yr-2 | 해당 문구는 _impl 4개 문서 전체에 실존하지 않음(전수 grep). 실존 설계 01 §6:414는 "write_seq = current commit_lsa"(대입)를 명시 — 구현은 설계와 일치. 실질 위험은 C4로 별도 확정(설계 결함으로 재분류) |
| R2 | min(wset_parent, prev_commit)이 2단계 스냅샷 경합으로 과소 제약 | 3yr-3 | 락 직렬화된 진짜 충돌에서는 불가능: 선행 P의 advance_baseline(publish_commit 첫 단계, 1047)→publish→unlock 순서와, 후행 T의 probe가 T의 DML 락 획득(=P unlock 이후) 뒤에 온다는 순서로, T의 seq 스냅샷은 항상 P의 baseline 전진 이후다. 잔여 창은 락 비직렬 슬롯(해시 충돌·NULL unique)뿐이며 이는 C4로 흡수. 10yr-20("보수측 안전")과 일치 |
| R3 | 보조 PK 수집이 복제 가드 없이 실행 | 3yr-7 | `pk_btid_index`는 8558-8560에서 `need_replication && !LOG_CHECK_LOG_APPLIER && log_does_allow_replication` 하에서만 설정 — post-loop 블록(`pk_btid_index != -1`)이 동일 가드를 간접 상속. applier/복제 off에선 도달 불가. 잔존 유효분: ws_tdes assert 부재(사소), 간접 가드의 가독성(D15) |
| R4 | CS_MODE 미정의 참조 위험 | 1yr-24 | locator_sr.c는 cubrid/(457)·sa/(460) 타깃에만 포함, cs/에는 없음 — CS 빌드는 호출부를 컴파일하지 않음 |
| R5 | cub_pl 파라미터 ordinal 영향 | 1yr-30 | SysParam.java 하드코딩은 95~354 구간, 신규 2개는 enum 끝(PRM_LAST_ID 직전) 추가라 기존 ordinal 불변 + prm_Def[] 옆 static_assert가 드리프트를 빌드 실패로 잡음 |
| R6 | 라벨 무조건 기록이 설계 위반 아니냐는 의문 | 1yr-21 | 설계 §6이 항상 기록을 전제 — 동작 일치(비용 논의만 D5로) |
| R7 | heap_attrvalue_get_key/btree_read_key_type/pr_clear_value 소유권·누수 의심 | 3yr 초기 의심 | 3yr 스스로 코드로 반박 확인: 단일 컬럼은 attrinfo 소유 포인터라 조건부 clear가 정답, 도메인은 tp_domain_cache 공유라 free 금지가 정답, MIDXKEY pr_clear_value는 멱등 |

---

## 5. 기존 코드 영향 리포트 (통합)

이번 작업이 기대는 기존 코드의 특성과, 향후 그 코드가 바뀌면 writeset이 조용히 깨지는 결합점:

1. **prior_lsa_alloc_and_copy_data의 NULL 계약** (log_append.cpp:296-301) — C1의 원인. 실패 계약을 반영하는 배선 필요.
2. **row X-lock의 커밋까지 유지 + publish-before-unlock** (log_manager.c:5324→5333) — 의존성 정확성 전체의 기둥. advance_baseline이 slot publish보다 선행(writeset.cpp:1047→1066)하는 순서와 함께, 리팩토링으로 순서가 뒤집히면 무성 skip. 주석·불변식으로 고정 필요.
3. **FK 존재검사 락의 단기성** (btree.c:6478, 6508-6510, 29381-29385) — O1. REF 방향의 최대 잠재 리스크.
4. **heap_attrvalue_get_key(..., is_check_foreign=true)** (heap_file.c, locator_sr.c:7820) — dedup 컬럼 제거로 자식 FK를 부모 도메인 표현에 맞추는 결합점. 이 헬퍼가 바뀌면 부모 WRITE/자식 REF 해시 정합이 조용히 깨짐.
5. **or_pack_mem_value의 정렬 패딩 특성** — memset(0)+정렬 전체 해시로 우회 중(주석 있음). 패킹 함수 변경 시 재검증.
6. **replication의 PK 전제** — "빈 writeset=독립" 병렬화는 모든 복제 DML이 PK WRITE를 수집한다는 전제 위에 있음. PK 없는 테이블 복제가 도입되면 붕괴.
7. **prior_lsa_mutex 원자 구간의 레코드 순서** — REPL→WSET_LABEL→COMMIT(동일 trid) 순서가 새 계약으로 편승(log_manager.c:4726-4736). 이 구간을 만지는 향후 변경은 순서 유지 필수.
8. **LOG_RECTYPE switch 산재** — append/to_string/recovery(analysis·redo·undo·startof_nxrec)/rollback/postpone엔 등록, log_dump_record는 누락(C5). 새 레코드 타입 추가 시 갱신 지점이 흩어져 있는 구조적 함정.
9. **직렬 applier·flashback의 default:break** (log_applier.c:6330, flashback.c:499) — 현행 슬레이브는 rectype 53을 안전히 skip(신버전 코드 한정, 구버전은 O4).

---

## 6. 권고 우선순위 요약

1. **커밋 전 필수**: C1(FIXME 해소), C4(WRITE max 1줄 + 설계 §6:414 수정 + WRITE 역행 테스트), C5(dump case 1줄), C7(or_pack 반환 검사), C9(release 클램프), D11(dbi_compat), D14(무관 재포맷 분리)
2. **결정 필요(설계/담당자)**: C2(2PC — 담당자 리뷰), C3(sysop/serial — 스코프 확정), C6(savepoint — 되감기 vs 강등 vs 문서화), D1(파라미터 분리)
3. **실측 최우선**: O1(FK 락 타이밍 적대 실측), O2/O3(복합키 바이트 동등·collation 실검증)
4. **후속 개선**: C8, C10, D2~D10, D15

---

## 부록 — 중복 병합 매핑

| 통합 항목 | 1yr | 3yr | 5yr | 10yr |
|---|---|---|---|---|
| C1 라벨 실패 | 1 | 2 | 1 | 4 |
| C2 2PC | - | 6 | - | 1 |
| C3 sysop/serial | - | - | 3 | 5 |
| C4 WRITE 대입+충돌 | 2, 13 | 1, 4, 20, 28 | 7, 15 | 2, 3 |
| C5 dumplog | 8 | - | 9 | 28 |
| C6 savepoint | - | - | - | 6 |
| C7 or_pack | - | 5 | - | - |
| C9 release assert | 23 | 9 | 8 | 19 |
| D1 파라미터 겸용 | 4 | 8 | 14 | 8, 24 |
| O1 FK 락 | - | - | 2 | 18 |
| R1~R3 반박 | 2 | 3, 7 | (7 일부) | (2 인용부) |

---

## 7. 정정·증보 (2026-09-30, 04-persona-code-review-codex 교차검증 후)

codex 독립 리뷰(04-persona-code-review-codex.md) 21건을 전건 재검증한 결과(해당 문서 §8), 본 통합 리뷰에 다음 정정과 추가가 필요하다.

**정정**
- §4 R2(min 과소제약 반박)의 범위 축소: 락 직렬화 논증은 **슬롯(write_seq) 출처 후보에만** 유효하다. `history_start`(floor) 출처 후보는 prober와 락 직렬화가 없어, 낡은 prev_commit 스냅샷이 min으로 floor 아래 의존성을 만들 수 있다(codex R02, CONFIRMED). 3yr-3은 부분적으로 옳았다.
- §1 C7(or_pack 실패)의 수정 방향 보정: or_pack_mem_value는 실패 시에도 non-NULL을 반환할 수 있어(rc 실패 시 *packed_len만 미설정) "NULL 검사"로는 부족하다. 감지기는 `packed_len == 0`.
- §2 O4(혼합 버전) 상향: develop의 `LOG_LARGER_LOGREC_TYPE`이 정확히 53이고 구버전 applier는 `type >= LARGER`를 손상 처리(log_applier.c:6336) — **구버전 applylogdb는 새 마스터의 첫 라벨에서 즉시 종료**. 도구 순회 문제가 아니라 복제 중단이며, 마스터 선업그레이드 금지를 강하게 문서화해야 한다.

**추가 확정 결함 (codex 발견, main 재검증 CONFIRMED)**
- **C11. [HIGH] clear floor가 삭제되는 최신 게시물을 커버하지 못함** — `wset_clear_history_with_lock`은 floor를 클리어 트랜잭션 자신의 commit_lsa로만 올려(writeset.cpp:956-960), 지연 clear가 자기보다 큰 LSA의 게시물을 지우고 낡은 floor만 남긴다. 수정: floor = max(자기 commit, clear 시점 prev_commit).
- **C12. [HIGH] dependency_is_ref 단일 플래그의 의미 과부하** — overflow 폴백·floor 출처 의존성이 is_ref=false로 나가 슬레이브 게이트에서 개별 완료 통과가 허용되면 commit-order 폴백과 floor 대기가 무력화된다. 혼합 후보(REF<WRITE)에서 REF의 frontier 요구도 소실. frontier-요구 플래그로 재정의 필요.
- **C13. [MED] UPDATE UNIQUE 훅이 same_key와 무관하게 old·new 무조건 수집** — 설계 §2.2("값이 바뀌면 new key")와 불일치. `log_tdes::copy_to`의 wset 필드 누락(2PC loose-end 이전 시 유실), 테스트 오라클 2건이 결함을 정답으로 고정(overflow is_ref=false, 동시 publish "아무 값이나"), trace level 3의 실키 값(PII) 로깅도 함께 확정.

**우선순위 갱신**: §6의 "커밋 전 필수"에 C11·C12(프로토콜 재설계 — codex §6의 R01·R02·R03 통합 권고와 동일)와 O4 상향분(업그레이드 순서 강제)을 추가한다.

---

## 8. Codex 최종 검토 의견

이 절은 위 통합 리뷰의 목록을 다시 늘리기 위한 것이 아니라, 현재 브랜치의 실제 호출 경로와 하위 함수를 끝까지 확인하여 **채택할 지적, 수정해서 채택할 지적, 이번 수정에서 제외할 지적**을 구분한 결과다.

### 8.1 그대로 채택할 지적

- **C1 — WSET_LABEL append 실패 후 COMMIT 계속 기록**: 확정 결함이다. 라벨 생성에 실패한 트랜잭션을 단순 commit-order로 강등할 수도 없다. 강등 정보도 같은 라벨에 실리기 때문이다. 실패를 호출자까지 전달하고 COMMIT과 history publish를 계속하지 않아야 한다.
- **C4 — WRITE 슬롯의 비단조 갱신**: 확정 결함이다. 실제 동일 키는 행 잠금으로 게시 순서가 정렬되지만, 서로 다른 키의 해시 충돌에는 그 전제가 없다. `write_seq`도 기존 값과 현재 COMMIT LSA 중 큰 값으로 갱신해야 한다.
- **C5 — log dump의 WSET_LABEL 누락**: 확정된 도구 결함이다. 정상 복구 로직과 별개로 dump가 첫 라벨에서 중단되므로 신규 레코드 크기만큼 건너가는 case가 필요하다.
- **C8 — TBB 예외의 C 호출 경계 이탈**: 확정 결함이다. 다만 publish는 COMMIT 로그가 이미 기록된 뒤이므로 일반 DML 오류처럼 반환해서는 안 된다. 예외를 잡은 뒤 현재 COMMIT을 포함하는 안전한 floor로 history를 비우거나, 그조차 보장할 수 없으면 서버를 치명 오류로 중단하는 계약이 필요하다.
- **C10 — history 크기의 soft limit**: 사실이다. 정확성 결함은 아니므로 엄격한 메모리 상한이 필요할 때만 수정하고, 그렇지 않으면 문서와 통계에서 soft limit임을 명시하면 된다.
- **O2·O3 — 복합 키의 실경로 바이트 및 collation 동등성**: 정적 코드만으로 닫으면 안 된다. 실제 부모 WRITE 키와 자식 REF 키, 문자열을 포함한 복합 키를 production 수집 경로로 통과시키는 테스트가 필요하다.
- **O4 — 구버전 applier와 신규 로그 타입**: OPEN이 아니라 배포 제약으로 확정할 수 있다. 구버전의 로그 타입 상한보다 신규 타입이 크므로 slave-first 업그레이드 또는 기능 방출 gate가 필요하다.

### 8.2 문제는 맞지만 해결책이나 심각도를 고쳐야 하는 지적

- **C2 — 2PC 배선 누락**: 코드상 사실이다. 다만 이번 기능에서 2PC를 지원하지 않기로 했다면 구현 필수 항목이 아니라 **명시적 범위 제외와 안전한 차단** 항목이다. NULL dependency를 가진 정상 트랜잭션처럼 통과시키는 현재 상태는 허용할 수 없다.
- **C3 — 독립 sysop 조각 미구현**: 설계와 코드의 불일치가 맞다. sysop을 이번 범위에 포함한다면 구현해야 하고, 제외한다면 문서에서 후속 구현으로 분리하고 슬레이브가 독립 task로 오인하지 않게 해야 한다.
- **C6 — savepoint rollback 뒤 키 잔존**: 직접적인 정합성 결함보다는 과대 dependency·overflow·history clear를 만드는 병렬성 문제다. 즉시 구조를 복잡하게 만들기보다 savepoint 발생 트랜잭션을 보수 경로로 보내는 대안과 비용을 비교할 수 있다.
- **C7 — 패킹 실패 처리**: 문제 제기는 유효하지만 기존 해결 설명은 부정확하다. `or_pack_mem_value()`는 오류 코드를 반환하는 함수가 아니므로 반환값의 성공·실패 검사로 해결할 수 없다. `packed_len`과 하위 error 상태를 확인하는 명시적 wrapper 계약을 먼저 만들어야 한다.
- **C9 — dependency가 자기 COMMIT보다 뒤인 경우**: append 전 검증은 필요하다. 그러나 잘못된 값을 NULL로 바꾸면 슬레이브가 이를 “의존성 없음”으로 해석하므로 제안된 clamp는 위험하다. 불변식 위반 시 COMMIT 기록을 중단하거나 치명 오류로 처리해야 한다.
- **O1 — FK 잠금 지속시간**: 원문의 “찾은 S lock을 즉시 해제한다”는 근거는 정확하지 않다. `btree_find_foreign_key()`는 오류 또는 미발견 경로에서만 직접 해제하며, 발견 성공 경로의 잠금은 남는다. 다만 격리 수준과 문장 종료 시점까지 포함해 COMMIT 전 publish를 보장하는지는 추가 검증이 필요하므로 OPEN 자체는 유지한다.
- **D5 — `prev_commit_lsa` 동기화 최적화**: `LOG_LSA`는 단순 정수 하나가 아니므로 바로 CAS로 바꾸겠다는 결론은 성급하다. 먼저 현재 mutex가 병목인지 측정하고, 필요하면 안전한 64비트 표현이나 seqlock 방식을 별도로 설계한다.
- **D12 — 로그 구조체의 bool·padding**: 기능 오류와는 별개지만 디스크 포맷의 결정성과 잔여 메모리 기록 방지 관점에서 유효하다. 고정 폭 필드와 명시적 reserved 영역을 사용하는 편이 낫다.

### 8.3 수정 항목으로 채택할 필요가 없거나 우선순위가 낮은 지적

- **D8 — finalize의 동시 호출 방어**: 현재 호출자는 transaction table의 종료·재생성 경계에서 실행되며 quiesce가 선행한다. 호출 계약을 assert로 문서화할 수는 있지만, 지금 확인된 동시 파괴 결함은 아니다.
- **D9 — descriptor vector의 capacity 유지**: descriptor 재사용 구조에서는 재할당 감소라는 이점도 있다. 메모리 워터마크를 측정한 뒤 큰 capacity만 축소하는 정책을 검토할 항목이지 일괄 수정 대상은 아니다.
- **D10 — dynamic parameter 캐시 문제**: `ha_writeset_history_size`는 `PRM_CLEAR_DYNAMIC_FLAG`로 등록돼 있다. 런타임 변경 가능한 parameter라는 전제의 지적은 제거해야 한다.
- **D11 — 오류 코드 등록 누락**: 전용 오류 코드는 `error_code.h`와 영문·한글 메시지 카탈로그에 이미 추가돼 있다. `dbi_compat.h` 추가가 반드시 필요하다는 근거도 확인되지 않았으므로 제거한다.
- **C13의 UPDATE old/new 무조건 수집 부분**: old key와 new key를 모두 수집하는 것은 현재 선택한 보수 정책이며 정합성 오류가 아니다. 값이 같을 때의 중복은 dedup·성능 문제로 분류하고 설계 문구를 구현에 맞추면 된다. 반면 `log_tdes::copy_to()` 누락, 잘못된 테스트 oracle, trace의 실제 키 노출은 서로 다른 항목으로 분리해 각각 수정해야 한다.
- **O5 — retain_lock 경로**: 확인된 순서에서는 publish가 unlock보다 앞선다. 호출자별 잠금 이전 검토는 회귀 검증 항목으로 남길 수 있지만 현재 결함 목록에서는 내린다.

### 8.4 통합 리뷰에서 빠진 필수 항목

#### N1. 지연된 과거 COMMIT의 clear가 최신 게시물을 삭제하는 경쟁 조건

현재 clear는 자기 `commit_lsa`와 기존 `history_start`만 비교한다. COMMIT LSA 200의 트랜잭션이 먼저 history에 게시된 뒤, 지연된 LSA 100 트랜잭션이 overflow clear를 수행하면 200의 키별 이력을 삭제하고 floor 100만 남길 수 있다.

단순히 clear 함수 안에서 `prev_commit_lsa`를 한 번 읽는 것만으로는 부족하다. 스냅샷 뒤 다른 publisher가 먼저 history lock을 얻어 게시하면 같은 문제가 반복된다. 다음 잠금 순서를 하나의 동작으로 보장해야 한다.

```text
seq_lock 획득
→ 현재 COMMIT을 prev_commit_lsa에 반영
→ history write lock 획득
→ history_start = max(history_start, prev_commit_lsa)
→ map clear
→ history lock 해제
→ seq_lock 해제
```

기존 경로도 `seq_lock → history_lock` 순서이므로 역순 잠금은 만들지 않는다. 회귀 테스트는 “LSA 200 게시 완료 후 LSA 100 clear”를 결정적으로 재현해야 한다.

#### N2. `dependency_is_ref`는 후보 출처가 아니라 대기 조건을 표현해야 한다

슬레이브가 알아야 하는 것은 최종 숫자가 `ref_seq`에서 왔는지가 아니라 **특정 트랜잭션 하나의 완료로 충분한지, 해당 LSA까지 홀 없이 완료돼야 하는지**다.

- `write_seq`에서 온 직접 충돌: 특정 선행 트랜잭션 완료 확인
- `ref_seq`: 여러 독립 REF의 최댓값을 대표하므로 연속 완료 경계 필요
- `history_start`: clear로 사라진 여러 이력을 대표하므로 연속 완료 경계 필요
- overflow·statement fallback의 `prev_commit_lsa`: commit-order 범위를 대표하므로 연속 완료 경계 필요

또한 여러 키를 합칠 때 최종 최대값이 WRITE 슬롯에서 왔더라도, 더 작은 REF 후보가 함께 있었다면 그 REF 범위의 홀을 건너뛰면 안 된다. 따라서 플래그를 `dependency_requires_frontier`처럼 의미 중심으로 바꾸고, 모든 후보의 요구를 OR로 집계하거나 exact dependency와 frontier dependency를 분리해야 한다.

#### N3. cub_server 재시작 전후 history epoch를 연결하는 장벽

서버 재시작 시 map, `history_start`, `prev_commit_lsa`가 모두 빈 상태가 된다. 승격 failover drain과 달리, 짧은 재시작 뒤 같은 마스터 역할을 유지하는 경우에는 슬레이브에 재시작 전 backlog가 남아 있을 수 있다. 이때 재시작 후 동일 키 트랜잭션이 NULL dependency로 기록되면 과거 task를 추월할 수 있다.

첫 재시작 후 복제 COMMIT에 epoch reset barrier를 기록하고, 슬레이브가 그 장벽 이전 task의 연속 완료를 확인한 뒤 새 epoch를 열도록 해야 한다. 검토한 대안과 폐기 이유는 [[05-cub-server-restart-barrier]]와 [[../../../12-cub_server-재시작|12장]]에 정리돼 있다.

### 8.5 최종 수정 우선순위

1. **병합 전 필수**: C1, C4, C8, C9, N1, N2, N3
2. **지원 범위 결정 후 필수**: C2(2PC), C3(sysop), O4(rolling upgrade)
3. **테스트로 닫아야 함**: O1, O2, O3, C7
4. **운영·성능 개선**: C5, C6, C10, D1~D7, D9, D12~D15
5. **삭제 또는 재분류**: D8의 결함 표현, D10, D11, C13의 UPDATE 수집 오류 주장, O5의 현재 결함 표현
