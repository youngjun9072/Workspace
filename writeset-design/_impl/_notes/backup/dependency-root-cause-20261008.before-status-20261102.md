---
tags: [writeset, analysis, root-cause]
date: 2026-10-08
base: feature/CBRD-27508-parallel-applylogdb-writeset @1a611b4d5 + 작업트리 (설치본 11.5.0.2636-1a611b4, 2026-10-07 23:15 빌드)
evidence: ~/Workspace/ha_bench-sysop-random/sysop_runs/20261007T152611-20261006-4141351
tools: ~/Workspace/ha_bench-sysop-random/tools/depcheck.py, par.py
---

# 슬레이브 데이터 불일치 원인 분석 (end-to-end)

## 0. 결론

Run 2(2026-10-08 00:26, seed 20261006, 트랜잭션 400건)에서 slave의 4개 행이 master와 달랐다. 원인은 마스터가 라벨 하나에 담는 선행 조건이 실제로 필요한 선행 트랜잭션을 모두 보장하지 못하는 데 있다. 경로는 두 가지다.

- **원인 A — 다른 키의 최댓값으로 축약.** 키별 선행 후보 중 최댓값 하나만 라벨에 싣고, 슬레이브는 그것이 WRITE 출처면 그 한 건의 완료만 확인한다. 최댓값 트랜잭션이 다른 후보 뒤에 적용된다는 보장이 없어서, 다른 키의 선행 트랜잭션을 건너뛸 수 있다.
- **원인 B — 최댓값이 `prev_commit_lsa`로 낮춰짐.** 최댓값이 직전 커밋보다 크면 마스터가 dependency를 `prev_commit_lsa`로 바꾼다. 이 경우는 최댓값이 SYSOP 조각일 때만 생겼다(19건 전부). 조각은 SYSOP_END LSA로 게시되지만 `prev_commit_lsa`는 COMMIT에서만 전진하기 때문이다. 바뀐 값은 관계없는 커밋 하나라서 개별 완료로는 아무것도 보장하지 못한다.

Run 2의 선행 관계 1369건 중 18건이 슬레이브 게이트로 보장되지 않았고(모두 WRITE 출처), 그중 8건이 실제로 선행 트랜잭션보다 먼저 시작했다. 불일치 4개 행은 모두 이 8건 중 하나와 연결된다. A는 일반 UPDATE에서도 생기며, B는 SYSOP_END 조각 도입으로 생긴 경로다.

## 1. 증상과 확인 방법

| 테이블 | 행(logical_key) | master | slave |
|---|---|---|---|
| `item_0` | 100001 | version_no 6, hit_count 7 | version_no 3, hit_count 3 |
| `item_0` | 100037 | hit_count 10 | hit_count 4 |
| `item_2` | 300002 | version_no 2 | version_no 1 |
| `item_2` | 300021 | version_no 2 | version_no 1 |

- master는 `csql testdb@localhost`, slave는 `csql testdb@youngjun4`로 각각 직접 조회했다. slave 접속이 실제 slave인지는 `_db_ha_apply_info.fail_counter`가 slave 11009, master 0으로 다르게 나오는 것으로 확인했다.
- 하니스는 600초 동안 두 값이 같아지기를 기다렸고, 수렴하지 않았다. 지연이 아니라 최종 상태가 다르다.
- slave 적용 오류(`fail_counter`) 증가는 0이다. 행이 실패한 것이 아니라 잘못된 순서로 적용됐다.
- AUTO_INCREMENT serial 값은 `_db_serial` 기준으로 양쪽이 같다(하니스의 `db_serial` 뷰 조회는 비어 판정하지 못했다).

## 2. 선행 조건이 만들어지고 소비되는 경로

```text
[마스터] UPDATE/INSERT/DELETE
locator_update_index ()                         locator_sr.c:8745~8776
└─ PK·UNIQUE 인덱스마다 old/new 키를 WRITE로, FK는 부모 키를 REF로 수집 (키 변경 여부와 무관)
   wset_add_write_key / locator_wset_collect_fk_ref

[마스터] sysop 종료 (serial, INCR)
log_sysop_end_logical ()                        log_manager.c:4011~4036
├─ 조각 조건(아이템 있음, 폴백 아님, 조각 키 있음)
├─ wset_find_fragment_dependency ()            writeset.cpp:939  → wset_find_dependency_in_range ()
├─ log_append_wset_label_and_sysop_end ()      WSET_LABEL + SYSOP_END
└─ wset_publish_fragment_to_history ()         writeset.cpp:1141 (키를 SYSOP_END LSA로 게시, prev_commit_lsa는 그대로)

[마스터] COMMIT
log_commit_local ()                             log_manager.c:5484~5488
├─ wset_find_dependency_from_history ()        writeset.cpp:905  → wset_find_dependency_in_range ()
├─ WSET_LABEL + COMMIT
└─ wset_publish_commit_to_history ()           writeset.cpp:1096 (키를 COMMIT LSA로 게시, prev_commit_lsa 전진 :1107)

wset_find_dependency_in_range ()                writeset.cpp:814~902
├─ 키마다 후보: REF→write_seq, WRITE→max(write_seq, ref_seq)        wset_select_candidate :765
├─ 모든 키의 후보 중 최댓값 하나를 선택                             :861~868   ← 원인 A
├─ 최댓값이 REF 슬롯 출처면 is_ref=true로 그대로 반환               :872~883
└─ 아니면 min(최댓값, prev_commit_lsa), 하한 history_start           :885~896   ← 원인 B

[슬레이브] reader
la_log_record_process () LOG_COMMIT             log_applier.c:9280  label → task.dependency_seq
                                                log_applier.c:9318  같은 trid 조각이 있으면 frontier 대기로 승격
la_reader_process_sysop_end ()                  log_applier.c:8874  조각 task는 label dependency만 사용

[슬레이브] gate
la_gate_can_dispatch () → la_gate_is_satisfied ()   log_applier_gate.cpp:332, 367
├─ dependency ≤ frontier → 통과
├─ is_ref → frontier까지 대기
└─ 완료 집합에 dependency 한 건이 있으면 통과          :384   ← A·B가 이 분기로 통과

[슬레이브] worker → result → la_accept_worker_result () → la_gate_mark_completed ()   log_applier.c:1232~1244
```

## 3. 원인 A — 다른 키의 최댓값으로 축약

**규칙.** 트랜잭션 T가 키 K1에서 선행 P1(후보 c1), 키 K2에서 선행 P2(후보 c2 > c1)를 찾으면 라벨은 c2 하나가 된다. 슬레이브는 P2가 완료 집합에 있으면 T를 보낸다. P2가 P1 뒤에 실행됐다는 조건은 어디에도 없다. P2의 라벨은 P2 자신의 키로만 계산되기 때문이다. 같은 키 안에서도 사슬이 끊긴다. P2가 K1의 직전 작성자라도 P2의 라벨이 다른 키의 더 큰 후보였다면 P2는 K1의 앞 작성자를 기다리지 않았다.

**증거 1 — 100001 행.**

| trid | 역할 | commit LSA | 라벨 dependency | slave 적용 시작 |
|---|---|---|---|---|
| 20202 | 100001 UPDATE | 1778\|3280 | 1765\|12256 | 00:26:17.992 |
| 20427 | 다른 행 INCR 조각 | 1789\|15680 | 1767\|6840 | — |
| 20487 | 100001 UPDATE | 1795\|2544 | **1789\|15680** | 00:26:14.950 |

- 20487의 probe는 100001 행 키(`c3492c4d…`, `b4afd828…`)에서 `write_seq=1778|3280`(20202)을 찾았다.
- 다른 키(`b4afbb28…`)에서 `1789|15680`(20427의 INCR 조각)을 찾았고, 이것이 최댓값이라 라벨이 됐다.
- 1789\|15680의 dependency는 1767\|6840이며 1778\|3280과 무관하다.
- slave는 20487을 20202보다 3.0초 먼저 시작했다. 100001 행의 UPDATE 6건은 master 커밋 순서 19907 → 20054 → 20202 → 20487 → 21170 → 21433과 달리 20487 → 21170 → 19907 → 21433 → 20054 → 20202 순으로 적용돼, 20202의 행 이미지(version 3)가 남았다.

**증거 2 — 300002 행.** 21285(1867\|10264)는 300002 행 키에서 21193(1858\|3312)을 찾았지만 라벨은 다른 키의 1866\|2496이었다. 두 트랜잭션은 dispatch 917, 918로 다른 워커에서 동시에 실행됐고, 21193의 이미지가 남았다.

**증거 3 — 300021 행.** 21170(1857\|3376)이 20017(1763\|1888) 완료 0.7초 전에 시작했다. 두 트랜잭션은 300021 행을 공유한다.

## 4. 원인 B — 최댓값이 `prev_commit_lsa`로 낮춰짐

**규칙.** `writeset.cpp:885~893`은 최댓값과 `prev_commit_lsa` 중 작은 값을 고른다. 주석은 "Both candidates are safe bounds"다. 이것은 "그 위치까지 모두 끝남"을 기다릴 때만 맞다. 슬레이브는 WRITE 출처를 개별 완료로 판정하므로, `prev_commit_lsa`는 관계없는 커밋 한 건을 기다리는 조건이 된다.

**언제 생기나.** 최댓값이 `prev_commit_lsa`보다 커야 한다. history의 값은 COMMIT LSA 또는 SYSOP 조각 LSA다. `prev_commit_lsa`는 COMMIT에서만 전진하므로(`writeset.cpp:1107`), 조각 LSA는 그보다 클 수 있다. Run 2에서 dependency가 낮춰진 19건은 모두 최댓값이 조각이었다.

**증거 — 같은 트랜잭션의 조각끼리 역전.** 20202의 serial 조각 두 개 중 둘째(1777\|15320)는 첫째(1776\|15448)를 후보로 찾았다. 그런데 `prev_commit_lsa`(1776\|12496)로 낮춰진 라벨을 받았고, 첫째보다 1.6초 먼저 시작했다. 슬레이브는 같은 trid의 조각끼리 순서를 잇지 않으므로(조각 task는 라벨만 사용, `log_applier.c:8874`) 막을 장치가 없다. 9.1.1 설계는 "다음 sysop task는 같은 trid 마지막 sysop task를 기다린다"고 정했지만 코드에는 없다.

**100037 행.** 21225의 두 조각(1860\|3144, 1860\|4416)이 같은 방식으로 역전됐고, 두 조각은 100037 행을 공유한다. 다만 hit_count가 6만큼 빠진 것을 이 한 건만으로는 다 설명하지 못한다.

## 5. 정량

`tools/depcheck.py`가 master trace의 PROBE 후보(필요한 선행)와 slave trace의 실제 dependency·적용 시각을 대조한다. "보장됨"은 slave 게이트 규칙(frontier 대기면 dependency 이하 전체, 개별이면 그 한 건과 그 한 건이 보장하는 것)으로 그 선행이 반드시 먼저 끝나는 경우다.

| 항목 | 건수 |
|---|---|
| master probe 정보가 있는 task | 795 |
| 필요한 선행 관계 | 1369 |
| 게이트가 보장하지 못하는 관계 | 18 (전부 WRITE 출처) |
| — A 유형 | 7 (실제 역전 4) |
| — B 유형 | 11 (실제 역전 4) |
| 실제로 선행보다 먼저 시작 | 8 |

실제 역전 8건과 공유 행:

| task(trid) | 선행(trid) | 유형 | 공유 행 |
|---|---|---|---|
| 1795\|2544 (20487) | 1778\|3280 (20202) | A | item_0 100001, 150015 |
| 1795\|2544 (20487) | 1776\|11128 (20195) | A | 없음 |
| 1857\|3376 (21170) | 1763\|1888 (20017) | A | item_1 250047, item_2 300021 |
| 1867\|10264 (21285) | 1858\|3312 (21193) | A | item_2 300002 |
| 1777\|15320 (20202) | 1776\|15448 (20202) | B | 같은 trid 조각(serial) |
| 1860\|4416 (21225) | 1860\|3144 (21225) | B | 같은 trid 조각, item_0 100037 포함 |
| 1829\|5752 (20903) | 1827\|12264 (20898) | B | 없음 |
| 1845\|7624 (21089) | 1844\|3312 (21084) | B | 없음 |

공유 행이 없는 역전은 키가 겹친 대상이 serial이나 부모 키(FK) 쪽이라 이번 비교 대상 테이블에 흔적이 남지 않은 경우로 본다(미확인).

## 6. 설계 문서와의 관계

- 6-1 132행: "여러 entry에서 얻은 후보 가운데 … 가장 늦은 COMMIT LSA와 대기 방식을 최종 dependency로 선택한다." 원인 A의 축약이 설계 규칙이다.
- 6-1 140행: `ref_seq` 최댓값이 앞선 REF 완료를 보장하지 않는다고 인정한다. 같은 논리가 WRITE 후보 사이(키가 다를 때, 또는 사슬이 끊긴 같은 키)에도 성립한다는 점은 다루지 않는다.
- 6-2.4: WRITE 출처 dependency는 완료 집합의 한 건으로 통과시킨다. 원인 A·B가 이 분기로 통과한다.
- 04 리뷰 R03: REF 후보와 WRITE 후보가 섞인 경우, 폴백, `history_start`를 다룬다. WRITE끼리의 축약(원인 A)과 조각 LSA의 `prev_commit` 하향(원인 B)은 범위에 없다.
- 9.1.1: 같은 trid의 sysop task 사슬을 요구하지만 코드에 없다(원인 B의 같은 trid 역전).

## 7. 배제한 가설

| 가설 | 판단 근거 |
|---|---|
| slave가 아직 따라오는 중 | 600초 대기 후에도 같고, 이후 재조회도 같다 |
| 적용 오류로 행 누락 | 이번 실행 `fail_counter` 증가 0 |
| history clear로 키 유실 | master trace `CLEAR` 0건 |
| UPDATE가 키를 수집하지 않음 | 키 컬럼을 바꾸지 않는 UPDATE도 PK·UNIQUE 키를 수집한다(`locator_sr.c:8745`). probe가 실제로 20202를 찾았다 |
| 재시작 복구 구간의 재적용 | 이번 실행 중 applylogdb 재시작 없음 |
| serial 역전으로 인한 값 손상 | `_db_serial` 값 양쪽 동일(뒤 조각이 절대값을 덮어씀) |

## 8. 확인하지 못한 것

- 100037 행 hit_count 차이 6을 역전 1건으로는 다 설명하지 못한다. 추가 역전이 trace에 남지 않았거나 다른 경로가 있을 수 있다.
- checksumdb 리포트가 `item_2`를 일치로 보고한 이유.
- Run 1의 wide 행 손상과 slave `cub_server` crash는 별도 문제로 남는다.
- 이전 실행들(10-07 이전)은 하니스가 master끼리 비교해 같은 문제가 있었는지 판단할 수 없다.
