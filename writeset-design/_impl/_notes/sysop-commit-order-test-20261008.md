---
tags: [writeset, test, sysop, commit-order, gate, parallel]
date: 2026-10-08
build: 11.5.0.2637-67b110c (2026-10-08 15:43 빌드, A1 커밋 67b110c + SYSOP_END commit-order 수정, 수정분 미커밋)
harness: ~/Workspace/ha_bench-sysop-random (sysop-random, seed 20261006, Run 2 부하)
---

# SYSOP_END commit-order 테스트 결과 (2026-10-08)

## 목적

복제 항목을 낸 SYSOP_END를 commit-order 라벨의 독립 작업으로 보내는 수정([10장 13.7](10-sysop-end-investigation.md#137-결정-변경-2026-10-08--commit-order-폴백을-먼저-조각은-최적화-todo))을 A1 gate 위에서 처음 돌린다. [Run 2](./sysop-end-test-20261008.md)와 같은 부하를 같은 seed로 돌려 세 가지를 본다. 데이터가 일치하는가, SYSOP 작업이 설계대로 commit-order 라벨을 받는가, 직렬화의 대가가 얼마인가.

## 방법

- 실행 디렉터리: `sysop_runs/20261008T070116-20261006-325641`
- 명령: Run 2와 같다. `--profile random --seed 20261006 --clients 4 --transactions 400 --tables 4 --preload-rows 50 --tx-weights long=50,single-explicit=30,autocommit=20 --outcome-weights commit=70,abort=30 --dml-weights insert=65,update=15,delete=10,incr=10 --relation-weights dependent=75,independent=25 --long-statements 10:25 --long-delay-ms 5:40` (Run 2에 있던 `--checksumdb`는 뺐다. Run 2에서도 워크로드 중에는 실행되지 않았다.)
- 빌드: 양 노드 `Oct 8 2026 15:43:22`, 커밋 67b110c 위에 SYSOP_END 수정분(미커밋). 양 노드 libcubrid.so에 `SYSOP master commit_order` trace 문자열과 `ha_writeset_sysop_fragment` 파라미터가 있음을 확인했다. `cub_server` md5 양 노드 동일.
- conf: 복원값(ha_mode=on, 버퍼 5G 등) 양 노드 동일(md5 일치). `ha_writeset_sysop_fragment`는 기본값 no(= commit-order 경로).
- DB: 재배포 뒤 새로 생성, HA 기동 상태에서 실행.

## 비교 대상 검증

| 항목 | 결과 |
|---|---|
| 사용 config | `config/youngjun_ha.json` (master `testdb` = youngjun3, slave `testdb@youngjun4`) |
| HA 상태 | youngjun3 master/`active`, youngjun4 slave/`standby` |
| 실행 시작 시 fail_counter | master 0, slave 0 |
| 직접 교차 조회 (실행 종료 뒤) | 네 테이블 모두 행 수·Σversion_no·Σid가 master와 slave에서 같음 (아래 표) |
| serial 현재값 | 네 serial 모두 master = slave (2180, 260, 280, 280) |
| 부하 시간 | master 커밋 298건, 16:01:19.885 ~ 16:01:24.130 (4.2초) |

| 테이블 | master (행 수, Σversion_no, Σid) | slave |
|---|---|---|
| item_0 | 1566, 310, 1729502 | 1566, 310, 1729502 |
| item_1 | 188, 19, 22494 | 188, 19, 22494 |
| item_2 | 202, 24, 26129 | 202, 24, 26129 |
| item_3 | 197, 27, 25860 | 197, 27, 25860 |

하니스 digest도 네 테이블 모두 일치. slave `applyinfo`: Insert 2252, Update 907, Delete 91, Commit 518, **Fail 0**, 지연 페이지 0. slave er_log에 `ERROR` 줄 없음.

## 판정

**PASS.** 데이터 일치, apply 오류 0, 멈춤 없음. 단, slave 반영 지연이 Run 2의 1.8초에서 **62초**로 늘었다(아래 "병렬성과 지연").

## master가 낸 SYSOP 라벨

master trace의 `SYSOP master` 줄 548건을 종류별로 나눴다.

| SYSOP_END 종류 | 복제 항목 | 건수 | 처리 |
|---|---|---|---|
| LOG_SYSOP_END_COMMIT | 있음 | **497** | 전부 `commit_order` 라벨(`DEPENDENCY mode=SYSOP_COMMIT_ORDER` 497, `HISTORY_START raise` 497). 조각(fragment) 라벨 0 |
| LOG_SYSOP_END_COMMIT | 없음 | 9 | 라벨 없음(평범한 SYSOP_END) |
| LOGICAL_UNDO / MVCC_UNDO / COMPENSATE / RUN_POSTPONE | 없음 | 42 | 라벨 없음 |

slave 쪽: 복제 항목 있는 SYSOP_END 497건이 모두 독립 작업(type=20)으로 배정됐다. `reader sysop_end ... items=0 action=defer labeled=0 long=0` 50건은 복제 항목이 없는 SYSOP_END라 미루는 것이 맞다. `long=1`(long transaction 유예)은 0건이라 그 경로는 이번 부하에서 검증되지 않았다.

Run 2(조각 빌드)는 같은 부하에서 `SYSOP master fragment` 480건이었다.

## gate 동작 (`tools/a1check.py`, SYSOP 작업 포함하도록 보정)

| 항목 | A1 no-sysop 실행 | Run 2 (조각, 지름길 있음) | 이번 실행 |
|---|---|---|---|
| 작업 수 (커밋 + SYSOP) | 305 | 626 | 924 |
| dependency 없음 / `dependency ≤ frontier` / 지름길 통과 | 9 / 296 / 0 | (도구 미지원) | 128 / 796 / **0** |
| pending 진입 / 해제 / 미해제 | 118 / 118 / 0 | 296 / 296 / 0 | 795 / 795 / **0** |
| pending 대기 평균 / 중앙값 / 최대 | 0.302s / 0.302s / 0.608s | 1.86s / 1.98s / 4.67s | **31.3s / 31.4s / 62.2s** |

이번 실행은 전체 924 작업 중 795건(86%)이 pending에 들어갔다. SYSOP 작업의 dependency는 전부 `is_ref=1`(commit-order 좌표)이고, 바깥 커밋도 history_start가 올라가 있어 대부분 commit-order 좌표를 받았다(ref 간선 674 / 795).

## 선행 관계

- `tools/fullcheck.py`(master PROBE 후보 쌍, 커밋 작업 298건 대상): ORDERED 258, 선행이 trace 이전 281, **REVERSED 0**, 미출발 0. SYSOP 작업은 이 도구가 다루지 않는다.
- dependency 간선 직접 검사(slave trace, 작업 795건 전부): 자기 dependency가 끝나기 전에 시작한 작업 **0건**.
- SYSOP 작업 → 같은 트랜잭션의 바깥 커밋 쌍 367건: 바깥 커밋이 SYSOP 작업 완료 전에 시작한 경우 **0건**.

## 병렬성과 지연

| 항목 | A1 no-sysop 실행 | Run 2 (조각) | 이번 실행 (commit-order) |
|---|---|---|---|
| master 부하 시간 | 4.5s | 5.3s | 4.2s |
| master 마지막 커밋 → slave 마지막 apply | 0.66s | 1.8s | **62.3s** |
| slave apply 구간 | 5.1s | 7.1s | **66.5s** |
| slave 순수 apply 시간 합 | 0.8s | 1.7s | 1.3s |
| 바쁜 동안 평균 동시 작업 / 최대 | 3.90 / 10 | 3.80 / 16 | **1.19 / 6** |
| 동시 작업 1개인 시간 비율 | 17% | 37% | **87%** |

### 지연 62초의 구성

두 요인이 곱해졌다.

1. **직렬화(설계 비용).** SYSOP 작업 497건이 commit-order 라벨을 받고 history_start를 올리므로, 그 뒤 작업은 거의 모두 "frontier가 바로 앞 작업까지 닿을 때"까지 기다린다. 작업 924건이 사실상 한 줄로 늘어섰다(동시 1개 87%).
2. **해제 지연 100ms(구현 비용).** pending 작업은 reader가 워커 결과를 회수하는 `la_collect_worker_results`에서만 풀린다(`log_applier.c:1170`, frontier 전진 → `la_gate_drain_ready`). 이 회수는 reader 루프의 맨 위(`:11107`)에서 매 바퀴 돌지만, master 부하가 4초 만에 끝나 새 레코드가 없으면 reader는 루프 끝의 `usleep(100ms)` 뒤 `continue`(`:11620`, 아래 "reader sleep 위치 정밀 분석")로 다음 바퀴를 돈다. 그래서 워커가 1~3ms 만에 끝낸 작업의 다음 작업이 다음 바퀴, 즉 100ms 뒤에야 출발한다. 회수 위치가 아니라 sleep 폭이 문제다. slave trace에서 "모든 워커가 쉬는 구간" 650개 중 626개가 정확히 0.10초였다. A1 no-sysop 실행과 Run 2에도 같은 0.10초 간격이 있었지만(각 46회, 59회) 사슬이 짧아 드러나지 않았다.

reader가 깨어나 pending을 푼 횟수는 661회이고(한 번에 1개 567회, 2개 65회, 3개 이상 29회), 661 × 0.1초 ≈ 66초가 slave apply 구간 66.5초와 맞는다. 순수 apply 시간은 1.3초뿐이다. 바쁜 동안 평균 동시 작업 1.19는 13.7.3에서 Run 2 trace 재생으로 예측한 폴백 동시 워커 1.30과 같은 수준이다.

dependency 간선 795건 중 `is_ref=1`이 674건인데, A1 gate는 is_ref와 무관하게 frontier만 보므로 이 구분은 판정에 쓰이지 않는다. 기록용 수치다.

### 해석

- 데이터·순서는 설계대로다. 직렬화도 13.7.3에서 예고한 비용이다. 사슬이 긴 이유는 trace로 확인된다. dependency가 FIFO에서 바로 앞 작업인 비율이 73%(674/924, Run 2는 17%, no-sysop은 4%)이고 frontier gate 기준 가장 긴 사슬은 683칸(Run 2 182칸, no-sysop 54칸)이다. SYSOP 작업 497건이 직전 커밋 좌표를 받고 history_start를 올리므로 뒤따르는 일반 커밋의 라벨 바닥도 함께 올라가 거의 모든 작업이 한 줄에 선다.
- 이 부하는 하니스가 모든 long 트랜잭션(208건, 52%)에 AUTO_INCREMENT INSERT 또는 INCR을 강제로 넣고(`generate.py` 333행) 나머지도 insert=65라 SYSOP 밀도가 최대인 부하다. 그래서 이번 수치는 commit-order SYSOP의 최악 조건 값이다. SYSOP 밀도를 바꿔 가며 다시 재야 실무 부하의 비용을 알 수 있다.
- 다만 "SYSOP 작업 하나가 끝나면 다음 작업이 100ms 뒤에 출발"하는 해제 지연은 commit-order 설계와 무관한 reader 루프 구조다. 워커 완료 시점에 reader를 깨우거나(조건변수), 로그가 없을 때의 sleep 안에서도 결과 회수와 drain을 돌리면 사슬 한 칸이 100ms에서 수 ms로 준다. 이 수정 없이는 commit-order SYSOP의 비용이 실제보다 수십 배 크게 측정된다.
- 백로그(포화) 부하에서는 reader가 계속 페이지를 처리하므로 이 100ms 효과가 작아질 것으로 본다(추정, 미측정).

## reader sleep 위치 정밀 분석 (2026-10-08 17시)

첫 수정에서 "새 로그 페이지 없음" 분기 세 곳(`:11282`, `:11314`, `:11379`)의 `usleep`을 결과 큐 조건변수 대기로 바꿨으나, 재측정(`20261008T075940`)에서 유휴 구간 0.10초 621/652, 지연 62.4초로 변화가 없었다. 자는 자리를 잘못 짚은 것이다. 정적·동적으로 다시 확인했다.

**정적(제어 흐름)**: 따라잡은 상태에서 reader 루프 한 바퀴는 결과 회수(`:11107`) → 헤더 읽기 → `eof.pageid < final.pageid`(`:11280`, 같은 페이지라 거짓) → 페이지 읽기(`:11290`, `old_lsa = final_lsa`) → 레코드 루프에서 END_OF_LOG를 만나 `is_end_of_record`만 켜고 `final_lsa`는 그대로(`:8666`, `:11457`) → `old_lsa == final_lsa`(`:11590`) 블록 → 블록 끝 `usleep(100ms)`(`:11620`) → `continue`. 세 수정 지점은 이 경로에 없다.

**동적(slave applylogdb reader 스레드, 수정 빌드 2638)**:

| 확인 | 결과 |
|---|---|
| `/proc/<tid>/wchan` 50회 표본 | `hrtimer_nanosleep` 48, `do_poll` 2. futex 대기 0 |
| `strace -e nanosleep,futex` 유휴 2.5초 | `nanosleep({0, 100000000})` 25회, futex는 WAKE 2회뿐(timed wait 없음) |
| 한 바퀴의 시스템콜 | `pread64`(헤더, offset 0) → `pread64`(페이지) → `pread64`(헤더) → `nanosleep(100ms)` 반복. 페이지를 읽으므로 `:11282` 경로가 아님 |
| `strace -k` 호출 스택 | `__nanosleep ← usleep ← la_apply_log_file+0x2ed4`. `la_log_fetch`·`la_log_io_read`의 sleep 아님 |
| 리턴 주소 디스어셈블 | 해당 `usleep` 호출 직전이 `snprintf → er_log_debug → clock_gettime`(드레인 백스톱 블록의 `la_clock_ns`), 직후가 `la_gate_get_frontier`(루프 탈출 경로). 이 배열은 `:11590~11620` 블록뿐 |
| 사슬 구간 strace 4초 (`20261008T080849` 실행 중) | `nanosleep(100ms)` 39회(초당 약 10회), 유휴 상태와 같은 패턴 |

결론: 따라잡은 상태의 sleep은 `:11620`이다. 이 자리를 같은 조건변수 대기로 바꿨다(미빌드). `:11282`·`:11314`·`:11379`의 교체는 그대로 둔다(같은 성격의 대기이고 해는 없다).

반복 실행 `20261008T080849`(strace 동반)도 지연 62.6초, 역전 0, 지름길 0, 미해제 0으로 앞 실행과 같았다.

## reader 깨우기 수정 뒤 재측정 (2026-10-08 17:27)

`:11620`을 결과 큐 조건변수 대기로 바꾼 빌드(2638, 17:16 빌드)로 같은 seed를 돌렸다(`sysop_runs/20261008T082733-20261006-472325`). 실행 중 slave reader 스레드의 strace는 `futex(FUTEX_WAIT_BITSET|CLOCK_REALTIME, 100ms)` 반복이고 `nanosleep`은 0회였다.

| 항목 | 수정 전 (commit-order) | 수정 후 (commit-order) |
|---|---|---|
| 데이터·serial 일치 / Fail / 역전 / 지름길 / 미해제 | 일치 / 0 / 0 / 0 / 0 | 일치 / 0 / 0 / 0 / 0 |
| 가장 긴 사슬 | 683칸 | 680칸 (같은 부하) |
| pending 진입 | 795 | 760 |
| pending 대기 평균 / 중앙값 / 최대 | 31.3s / 31.4s / 62.2s | **0.068s / 0.011s / 0.998s** |
| dependency 완료 뒤 추가 대기 합 | 78~82s | **0.19s** |
| reader가 깨어나 pending을 푼 횟수 / 회당 중앙값 | 661 / 1 | 62 / 8 |
| 0.09초 이상 유휴 구간 | 626 (부하 뒤까지 계속) | 31 (**전부 master 부하 중**, master 종료 뒤 0) |
| master 마지막 커밋 → slave 마지막 apply | 62.3s | **0.08s** |
| slave apply 구간 | 66.5s | 5.4s (master 부하 5.1s) |
| 바쁜 동안 평균 동시 작업 / 최대 | 1.19 / 6 | 1.38 / 6 |

### 해석

- 사슬 680칸은 그대로인데 지연이 62초에서 0.08초가 됐다. 62초는 설계 비용이 아니라 reader sleep이었음이 확정됐다. 사슬 한 칸은 이제 워커 실행 시간 수준이다(dependency 완료 뒤 추가 대기 합 0.19초 / 760건).
- 남은 0.1초 유휴 31개는 모두 master가 아직 커밋을 내는 동안(부하 5.1초 중)이다. master 쪽 클라이언트 지연(`--long-delay-ms 5:40`)과 copylogdb 전달 주기로 slave에 할 일이 없던 구간으로 본다(추정, copylogdb 주기 미확인). master 종료 뒤에는 0.09초 이상 유휴가 없다.
- 평균 동시 작업 1.38은 commit-order 설계 비용의 실제 모습이다. 작업 805건 중 669건이 바로 앞 작업에 의존해 거의 직렬이지만, 한 칸이 수 ms라 slave가 master를 그대로 따라간다. 이 부하에서 commit-order의 비용은 "slave가 직렬로 돈다"이지 "slave가 뒤처진다"가 아니다.
- par.py의 "선행 완료 전 출발 1건"은 er_log 타임스탬프 표기(초 올림 누락) 때문이며 엄밀 검사에서는 0건이다.

이 결과로 13.7.5 조건 1의 판정이 가능해졌다. 조각 모드도 같은 빌드에서 재측정해 나란히 놓는 것이 다음이다.

## 이번 부하가 덮지 못한 것

- long transaction 유예 경로(`is_long_trans`, `long=1`): 0건. `--wide-transactions`가 있어야 생긴다.
- DDL(statement replication) 뒤 SYSOP: `--ddl-transactions` 없음.
- 조각 경로(`ha_writeset_sysop_fragment=yes`): 켜지 않았다.
- 분석 도구: `fullcheck.py`·`gatesim.py`는 커밋 작업만 다룬다. `gatesim`은 이 실행에서 dependency가 SYSOP 좌표를 가리켜 재생이 멈춘다(`stuck under rule CUR`). SYSOP 작업까지 포함하도록 고쳐야 재생 비교가 가능하다.
- slave trace 줄 이름이 아직 `SYSOP slave fragment assemble`이다(동작은 commit-order 작업 조립, 이름만 옛것).

## 결론

1. commit-order SYSOP_END는 같은 seed 부하에서 데이터 일치, 역전 0, 지름길 0, pending 미해제 0으로 끝났다.
2. slave 반영 지연이 1.8초에서 62초가 됐다. 직렬 사슬 683칸(설계 비용, SYSOP 밀도 최대 부하)에 reader의 100ms sleep 폭(구현 비용)이 곱해진 값이다. 둘을 분리해 재측정하려면 sleep 폭부터 없애야 한다.
3. long transaction·DDL·조각 경로는 아직 돌리지 않았다.

## 남은 일

- ~~reader 해제 지연 제거 뒤 같은 부하 재측정~~ (완료, 위 "재측정" 절). 조각 모드도 수정 빌드로 재측정.
- `--wide-transactions`, `--ddl-transactions`를 넣은 부하로 long/DDL 경로 확인.
- `fullcheck.py`·`gatesim.py`에 SYSOP 작업 포함. slave trace 줄 이름 정리.
- SYSOP_END 수정분 커밋.
