# 마스터측 설계 대비 구현 갭 분석 (2026-10-06)

> READ-ONLY 조사. 코드 수정·커밋 없음. 대상 base = `/home/youngjun/Workspace/cubrid-applier`,
> 브랜치 `feature/CBRD-27508-parallel-applylogdb-writeset @05365ab1e`
> (develop `c63a3b993` + PoC `feature/writeset_error_skip` squash + LOG_LSA_ATOMIC 적응 + [WSET] trace + SYSOP_END serial fragment).
>
> 러프한 in-place PoC 포트라는 전제 하에, **동작/기능** 기준으로 설계 대비 미구현을 분류한다.
> "모듈화 안 됨"은 갭으로 보고하지 않는다(설계 인수인계 governing plan이 모듈화를 4단계로 미룸).
> 모든 판정은 실제 코드(grep/read)로 검증했다.

## 조사한 코드 파일
- `src/transaction/log_writeset.c` / `.h` — 수집·history·probe·flush·fragment
- `src/transaction/log_manager.c` — commit 경로(probe/flush/WS_LABEL), SYSOP_END fragment 경로
- `src/transaction/log_record.hpp` — `LOG_DUMMY_WS_LABEL`, `LOG_REC_WS_LABEL`
- `src/transaction/log_impl.h` — `LOG_TDES`의 ws_* 필드, `log_topops_addresses::ws_mark`
- `src/query/serial.c` — serial 키 수집 hook
- `src/transaction/locator_sr.c` — WRITE/REF 수집 hook
- `src/transaction/replication.c` — statement replication overflow
- `src/base/system_parameter.c` / `.h` — `ha_writeset_trace_level`

---

## 갭 표 (설계 항목 | 설계 위치 | 상태 | 코드 근거 / 갭)

| # | 설계 항목 | 설계 위치 | 상태 | 코드 근거 / 갭 |
|---|---|---|---|---|
| 1 | WRITE 키 수집(PK/UNIQUE/REVERSE UNIQUE) | 6-1.2 | IMPLEMENTED | `locator_sr.c:8049,8190,8735,8941,9003` → `log_writeset_add_dbvalue` → `log_writeset_add_key`(KIND_WRITE) |
| 2 | 자식 FK REF 수집 | 6-1.2 / 6-1.3 | IMPLEMENTED | `locator_sr.c:7841` `log_writeset_add_ref_dbvalue`(KIND_REF). WRITE/REF 분리 존재 |
| 3 | INSERT new / DELETE old / UPDATE old+new | 6-1.2 | IMPLEMENTED | `locator_sr.c:8735/8738`(old+new), `8941/8942`(old+new). 다중 수집 경로 확인 |
| 4 | 충돌 식별자 `H(class_oid, index VFID, 정규화 키)` | 6-1.2 | PARTIAL | `log_writeset.c:107 log_writeset_fnv1a`는 **class_oid(8B)+packed key만** 해시, **index VFID 미포함**(VFID/BTID grep 0건). 부모 class_oid 기준이라 FK 매칭은 성립하나, 같은 class의 PK/다른 UNIQUE가 같은 packed값이면 거짓 충돌(안전방향, 성능만 손해). 설계는 VFID 포함 명시 |
| 5 | 문자열 collation 반영 해시 | 6-1.2 | IMPLEMENTED | `log_writeset.c:152 log_writeset_string_hash`(mht2str pseudo key, WRITE/REF 동일 helper) |
| 6 | 복합(MIDXKEY) FK REF를 부모 MIDXKEY로 재구성해 수집 | 6-1.7 "복합 FK" | MISSING | `log_writeset.c:474` `TP_DOMAIN_TYPE==DB_TYPE_MIDXKEY`면 **return(수집 건너뜀)**. 헤더 주석(l.429)도 "composite not matched yet". 설계 6-1.7 본문은 "재구성한다"고 기술 → 문서-코드 불일치. 건너뛰면 보수적 폴백(안전, FK 병렬성 손실) |
| 7 | UNIQUE NULL은 WRITE에 포함, 자식 FK NULL은 REF 안 만듦 | 6-1.2 | IMPLEMENTED | REF: `log_writeset.c:468 DB_IS_NULL` skip. WRITE: NULL 가드 없음→포함 |
| 8 | probe→WSET_LABEL→COMMIT→publish 순서 | 6-1.5 / §10 #1,#2 | IMPLEMENTED | `log_manager.c:5443 probe` → `5446 repl+commit`(내부 `4720 ws_label`) → `5452 flush` |
| 9 | WSET_LABEL을 REPL과 COMMIT 사이·같은 trid 인접 기록 | 6-1.5 / §10 #3 | IMPLEMENTED | `log_append_ws_label_with_lock`가 `log_append_repl_info_and_commit_log` 내 `prior_lsa_mutex` 구간(l.4720)에 기록 |
| 10 | WS_LABEL 레코드 필드 `dependency_seq`,`dependency_is_ref` | 6-1.5 / 7장 | IMPLEMENTED | `log_record.hpp:260 dependency_seq`,`261 dependency_is_read`. 코드 필드명=`_is_read`(설계 용어 `_is_ref`와 동일 의미, 이름만 상이) |
| 11 | abort 트랜잭션 미게시 | 6-1.7 / §10 #6 | IMPLEMENTED | probe/flush가 commit 경로(l.5437 `log_does_allow_replication`)에만 있음. abort 경로 호출 0. `log_writeset.c` flush 주석 "never on the abort path" |
| 12 | publish가 row lock 해제보다 선행 | 6-1.5 / §10 #5 | IMPLEMENTED | `flush`(l.5452)가 lock 해제 이전 |
| 13 | REF는 write_seq만, WRITE는 write_seq+ref_seq 대기 | 6-1.3/6-1.4 / §10 #7,#8 | IMPLEMENTED | `log_writeset.c:628` WRITE일 때만 read_seq 비교 |
| 14 | publish 시 write_seq/ref_seq **최댓값 단조 갱신** | §10 #9 | PARTIAL | `log_writeset.c:770` read_seq=`LSA_GT`로 max. **`764` write_seq=`LSA_COPY` 단순 대입**. §10 #9는 WRITE도 max 요구(단, "검증 코드 단순 대입과 정식 TBB 설계 구분" 명시). X-lock 직렬화로 현재 안전하나 방어적이지 않음 |
| 15 | writeset 용량 초과→writeset 폐기·ws_overflow | 6-1.7 / §10 | IMPLEMENTED | `log_writeset.c:265` TX_LIMIT 도달 시 clear+ws_overflow |
| 16 | statement replication(DDL 등)→ws_overflow | 6-1.7 | IMPLEMENTED | `replication.c:540 tdes->ws_overflow=true` |
| 17 | commit-order 폴백 라벨은 `dependency_is_ref=true`(frontier 대기) | 6-1.7 WARNING / 슬레이브 §10 #4 | **MISSING** | overflow probe 분기(`log_writeset.c:582-594`)가 `ws_parent_out=prev_commit`만 복사, **`ws_dependency_is_read`를 true로 세팅 안 함**(l.577에서 false). 라벨이 is_ref=false로 나가 슬레이브가 **개별 완료 1건**으로 통과 → prev_commit 앞 홀이 남아도 통과 가능 |
| 18 | 전역 history 포화→clear + history_start=commit_lsa | 6-1.7 "map 포화" | IMPLEMENTED | `log_writeset.c:732-747`(commit), `786-790`(overflow), `1125-1134`(fragment) |
| 19 | 전역 history = `tbb::concurrent_hash_map` | 6-1.1 / §11 / commit-plan C1 | **MISSING** | `log_writeset.h:126` `std::unordered_map` + `128` 단일 `pthread_mutex latch`. 모든 probe/flush가 한 latch 직렬화(설계의 동시성 목표 미달). 설계는 entry별 accessor 잠금 요구 |
| 20 | history 크기·per-tx 한도 = `ha_writeset_history_size` 시스템파라미터 | commit-plan C1 / handoff ①③ | **MISSING** | `log_writeset.h:101-102` `#define LOG_WRITESET_TX_LIMIT 10000000` / `HISTORY_CAP 10000000` 고정. sysparam 없음(grep상 writeset 계열 PRM은 trace_level 하나뿐) |
| 21 | serial(db_serial) sysop fragment probe/publish/WSET_LABEL | 10장 §13.6 / handoff | IMPLEMENTED | `serial.c:1232` 수집 → `log_manager.c:3995-4010` fragment probe/publish/discard, `4720/4848` ws_label, `log_append_wset_label_and_sysop_end` 원자 기록 |
| 22 | INCR()/DECR()·checksumdb SYSOP_END 생산자 처리(fragment 또는 master overflow 폴백) | commit-plan item3(l.132) / handoff 결정2 | **MISSING** | 수집 hook은 `serial.c`에만 존재. INCR/DECR/checksumdb는 키 미수집→`log_manager.c:3997` 조각조건(`ws_hashes.size()>fragment_begin`) false→**라벨 없는 평범한 SYSOP_END**. master overflow 폴백 미구현(handoff 결정2가 "아직 마스터 미구현"으로 명시). 현재는 슬레이브 drain 의존 |
| 23 | WSET_LABEL을 system recovery가 redo/undo 안 함 | 6-1.5 | IMPLEMENTED | `log_manager.c:8227` `LOG_DUMMY_WS_LABEL: break`(무동작). dummy 레코드 |
| 24 | fragment 키를 바깥 writeset에서 제거(이중 게시 방지) | 10장 §13.6 | IMPLEMENTED(가정 의존) | `log_writeset.c:1178 log_writeset_discard_fragment`가 tail 전체 erase. "serial sysop은 serial만 수집→조각은 항상 꼬리" 가정 의존(주석 명기 요청됨, handoff) |
| 25 | [WSET] trace / 성능계측 필드는 정식 설계에서 제외 | handoff ④ / 설계 CLAUDE §15 | PARTIAL(의도된 임시) | `log_writeset.c:50 WS_PERF_LOG`, `56 WS_MASTER_TRACE`, `log_impl.h:572 ws_stat_collect_ns`. `system_parameter.c:5619` `ha_writeset_trace_level` **기본값 2**. 코드 주석 다수 "TEST ONLY ... remove". 정식화 시 제거/기본 0 대상 |

---

## 우선순위 MISSING 목록

### A. 정합성(correctness) 우선 — 병렬 production 켜기 전 반드시 해소

1. **commit-order 폴백의 대기 방식 오류 (표 #17).** overflow·statement 폴백이 `dependency_is_read=true`를 세팅하지 않아 라벨이 "prev_commit 개별 완료 1건"으로 나간다. 설계 6-1.7 WARNING은 "그 위치까지의 **연속 완료(frontier)**"를 요구한다. 폴백 트랜잭션은 writeset이 불완전/부재하므로 개별 완료 통과를 허용하면 prev_commit 이전 홀이 남은 상태에서 적용되어 같은 행 순서가 붕괴할 수 있다. `log_writeset.c:582-594`(commit)와 fragment 폴백 분기에서 `ws_parent_is_read`/`ws_dependency_is_read`를 폴백 시 true로 설정해야 한다. (주: 현 PoC 동작과 동일하며 설계 문서도 "구현 확인 필요"로 플래그한 지점)

2. **INCR/DECR·checksumdb sysop의 master 측 미처리 (표 #22).** 이들은 NEED_FLUSH로 복제되지만 키 수집도, overflow 폴백도 없어 라벨 없는 SYSOP_END를 낸다. 현재 안전성은 전적으로 슬레이브 일괄 drain에 의존하는데, handoff 결정2는 그 drain 제거를 전제로 master overflow 폴백 구현을 요구한다. master 폴백이 없는 채 슬레이브 drain만 제거하면 이 sysop들이 안전장치 없이 병렬 경로로 샌다. serial 외 NEED_FLUSH 생산자를 `ws_overflow` 커밋오더 폴백으로 보내는 구현 필요.

### B. 성능/확장성 — 설계 핵심 목표 미달이나 정합성은 안전

3. **전역 history가 TBB가 아니라 단일 latch unordered_map (표 #19).** 설계(§11/6-1.1/commit-plan C1)의 `tbb::concurrent_hash_map` entry별 accessor 잠금 대신, 모든 probe/flush가 `log_Writeset_history.latch` 하나로 직렬화된다. 병렬 커밋 스루풋이 이 latch에 묶이므로 writeset 병렬화의 마스터측 확장 목표를 달성하지 못한다. 동작/정합성은 정상.

4. **복합 FK REF 미수집 (표 #6).** MIDXKEY REF를 건너뛰어 복합키 자식-부모 FK 순서가 보수적 폴백으로 처리된다(안전, 병렬성 손실). 설계 6-1.7 본문은 "재구성해 수집한다"고 단정하므로 문서-코드 불일치도 함께 정정 필요.

5. **write_seq 단순 대입 (표 #14).** X-lock 직렬화로 현재 안전하나 §10 #9의 단조 max 갱신을 따르지 않는다. 정식 TBB 설계 전환 시 함께 max로.

6. **충돌 해시에 index VFID 미포함 (표 #4).** 거짓 충돌(안전방향)만 유발하나 설계 식별자 정의와 다름.

### C. 폴리시/정식화 — 정식 구현 전환 시 처리

7. **하드코딩 상수 (표 #20).** `LOG_WRITESET_TX_LIMIT`/`HISTORY_CAP` `#define 10000000` → `ha_writeset_*` 시스템파라미터화(PRM_FOR_SERVER|PRM_FOR_HA) 필요.

8. **계측/trace 제거 (표 #25).** `WS_PERF_LOG`, `WS_MASTER_TRACE`, `ws_stat_collect_ns`, `ha_writeset_trace_level`(기본 2) 모두 "TEST ONLY" 주석. 정식 설계에서 제외하거나 기본 0으로.

9. **빈 writeset COMMIT에도 WSET_LABEL 무조건 발행 (설계 6-1.5 "경로별 확정" 미결).** handoff가 "모든 COMMIT에서 라벨 발행(빈 writeset 포함)"으로 기록. 설계는 "복제 항목 있는 COMMIT에 정확히 하나"를 요구하고 빈 COMMIT 라벨 기록 여부는 상세설계 미확정으로 남김. 정책 확정 필요(기능 영향은 작음).

---

## 비고
- 표 #1~#3,#5,#7~#13,#15,#16,#18,#21,#23,#24는 설계 요구를 충족(IMPLEMENTED). 마스터 정상 커밋 흐름의 골격(수집→probe→라벨→커밋→게시)과 serial sysop fragment 경로는 end-to-end로 자리잡았다.
- 가장 큰 마스터측 갭은 (A1) 폴백 대기방식 플래그 누락과 (A2) INCR/DECR·checksumdb 폴백 부재 — 둘 다 정합성 영역이며 병렬 production 활성화 전 해소 대상. (B3) 단일 latch는 정합성은 안전하나 설계의 확장 목표 자체를 비운다.
