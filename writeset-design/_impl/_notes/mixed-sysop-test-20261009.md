---
tags: [writeset, test, sysop, parallel, restart]
date: 2026-10-09
build: 11.5.0.2620-1c86f4f (2026-10-09 13:28:56, 브랜치 재구성 뒤 세 커밋 74e007835 / 5d251d4ba / 1c86f4f6f)
harness: ~/Workspace/ha_bench-sysop-random 7c0c453(검증기 수정 포함), run 1차 `sysop_runs/20261009T044608-20261006-752192`, 2차 `20261009T050534-20261006-791481`
---

# SYSOP 혼합 부하 테스트 (2026-10-09)

## 목적

지난 두 실행은 양 극단이었다. [no-sysop](./no-sysop-test-20261008.md)은 SYSOP_END가 전혀 없고, [commit-order 테스트](./sysop-commit-order-test-20261008.md)는 모든 long 트랜잭션이 AUTO_INCREMENT나 INCR을 가져 작업의 54%가 SYSOP이었다. 이번에는 둘을 한 부하에 섞어, 10-09에 반영한 변경(재시작 상한, 재시작 경계, worker 수 파라미터, READY, outstanding 상한, 비차단 queue, 용량 예약, trace reason)이 든 빌드로 데이터 일치와 순서를 본다.

## 방법

- 하니스에 `--sysop-tx-ratio`를 추가했다(84eee69). 트랜잭션마다 확률 R로 SYSOP 트랜잭션을 뽑고, 나머지는 AUTO_INCREMENT 컬럼을 두되 INSERT에 id를 직접 넣고 INCR을 UPDATE로 바꾼다. long 트랜잭션도 같은 방식으로 뽑히므로 SYSOP 있는 long과 없는 long이 섞인다.
- 명령: Run 2와 같은 seed·형태에 두 가지 추가. `--profile random --seed 20261006 --clients 4 --transactions 400 --tables 4 --preload-rows 50 --tx-weights long=50,single-explicit=30,autocommit=20 --outcome-weights commit=70,abort=30 --dml-weights insert=55,update=25,delete=10,incr=10 --relation-weights dependent=75,independent=25 --long-statements 10:25 --long-delay-ms 5:40 --sysop-tx-ratio 0.4`
- conf: 양 노드 cubrid.conf 57f0224f, cubrid_ha.conf 68235c04(`ha_apply_max_mem_size=4096`, `ha_apply_worker_count=10`). DB는 카탈로그 변경 때문에 새로 만들었다(사용자 수행).

생성된 부하의 구성:

| 형태 | SYSOP 있음 | SYSOP 없음 |
|---|---|---|
| long | 89 | 120 |
| single-explicit | 54 | 76 |
| autocommit | 31 | 30 |
| 합계 | 174 (43%) | 226 |

## 비교 대상 검증

| 항목 | 결과 |
|---|---|
| master | youngjun3 `testdb@localhost` (hb status: master, Server registered_and_active) |
| slave | youngjun4에서 ssh로 `testdb@localhost` (hb status: slave, Server registered_and_standby). 하니스 config는 `testdb@youngjun4` |
| 직접 교차 조회 | 아래 표. 테이블마다 값이 다르고 master·slave가 같다 |
| 하니스 digest | 네 테이블 모두 master_slave_ok, unique 0, FK 고아 0 |
| serial 현재값 | `_db_serial` 직접 조회 item_0..3 = 820 / 160 / 160 / 180, 양쪽 동일 |
| apply fail_counter | 0 → 0 |

| 테이블 | master (행, Σversion_no, Σhit_count, Σid) | slave |
|---|---|---|
| item_0 | 1346, 651, 110, 766998555 | 1346, 651, 110, 766998555 |
| item_1 | 191, 47, 13, 69068396 | 191, 47, 13, 69068396 |

## 판정

**PASS** (재검증 `verdict.revalidated.json`). 데이터·serial 일치, apply 오류 0, 역전 0, 지름길 0, pending 미해제 0.

하니스의 첫 판정은 `DATA_DIVERGENCE`였는데 master와 slave의 차이가 아니라 **하니스 모델과 master의 차이**였다. tx 73(client 0, long, SYSOP 없음)이 다른 클라이언트(csql 752793)와 master에서 데드락을 일으켜 희생자로 중단됐다(master err 13:46:10.117, CODE -72, 19번째 줄 `UPDATE logical_key=100035`). csql은 스크립트를 멈추지 않고 그 뒤 문장(INSERT 1000413, 1000414, UPDATE 100015, 100000)을 **새 트랜잭션으로 실행해 COMMIT**했다. master와 slave는 정확히 그 상태였고(1000413·1000414 존재, 100000·100015 version +1), 생성 시점에 만든 모델만 "전체 커밋"으로 세고 있었다. 하니스를 고쳤다. 래퍼가 stderr의 `unilaterally aborted`와 `from line N`을 모아 `client-aborted.txt`에 적고, 검증기가 preload 상태에서 journal을 다시 재생하되 그런 트랜잭션은 실패 줄 뒤 문장만 반영한다. 단위 테스트 2건 추가(총 19건 통과). 이 수정으로 같은 스냅샷을 재판정하면 PASS다.

600초 대기는 모델 불일치로 `state.ok`가 끝내 참이 되지 않아 하니스가 타임아웃까지 기다린 것이고, slave 지연과는 무관하다.

## gate·순서·병렬성

| 도구 | 결과 |
|---|---|
| a1check | no-dep 311, dep≤frontier 485, 지름길 **0**. pending 진입 409 / 해제 409 / 미해제 **0**. pending 대기 평균 0.009s 최대 0.030s. A1 추가 대기 합 0.043s |
| fullcheck | ORDERED 565, PRED_BEFORE_TRACE 284, 역전 **0**, 멈춤 0 |
| par | 워커 작업 796건(워커당 78~80), 최대 동시 6, 바쁜 동안 평균 1.61, 선행 완료 전 시작 **0**, fragment→outer 역전 0 |
| SYSOP | master `commit_order` 192건 = slave `SYSOP slave` 192건. reason: incr 146, serial 46 (serial cache 때문에 INSERT 901건 대비 serial SYSOP은 46) |
| 지연 | master 마지막 부하 커밋 13:46:13.587 → slave 마지막 부하 retire 13:46:13.725, **0.14초**. 부하 자체는 4.3초(13:46:09.32~13.59) |
| slave er_log ERROR | 기동 직후의 -82·-1038 두 줄뿐(이전 실행과 같음) |

commit-order 테스트(전부 SYSOP)에서 바쁜 동안 평균 동시 1.38이었던 것이 1.61로 올랐고, no-sysop(3.99)보다는 낮다. SYSOP 비율 43%에서의 값이다.

## 이번 빌드의 새 동작 확인

- 워커 행: `_db_ha_apply_info`에 reader 행(worker_id -1)과 워커 행이 생겼고 `max_committed_lsa`가 갱신된다(부하 전 조회로 컬럼 존재 확인).
- 10 워커 모두 작업을 받았다(par 워커당 78~80). READY 핸드셰이크는 기동을 막지 않았다.
- outstanding 상한(10 × 1024)에는 닿지 않았다(최대 동시 6, pending 최대 대기 30ms).

## 2차: 테이블 8 · 클라이언트 8 · 800건 (14:05, run `20261009T050534-20261006-791481`)

같은 seed·비율에 `--tables 8 --clients 8 --transactions 800`. 하니스 판정 **PASS**(수정된 검증기, 10초 만에 종료). master 데드락 희생자 2건(tx 10 16번째 줄, tx 266 13번째 줄)은 검증기가 실패 줄 뒤 문장만 반영해 모델과 일치했다.

구성: long 157 SYSOP / 242 없음, single-explicit 111 / 150, autocommit 57 / 83. SYSOP 트랜잭션 325건(41%). master `commit_order` 324건(incr 240, serial 84).

직접 교차 조회(master youngjun3 `testdb@localhost`, slave youngjun4 ssh `testdb@localhost`), 여덟 테이블 전부 같다:

| 테이블 | 행 | Σversion_no | Σhit_count | Σid |
|---|---|---|---|---|
| item_0 | 2401 | 1236 | 180 | 1451608343 |
| item_1 | 184 | 37 | 10 | 52095507 |
| item_2 | 168 | 45 | 8 | 50097564 |
| item_3 | 171 | 35 | 12 | 60109465 |
| item_4 | 173 | 41 | 10 | 47089281 |
| item_5 | 179 | 44 | 7 | 53099154 |
| item_6 | 165 | 51 | 10 | 47092488 |
| item_7 | 172 | 48 | 6 | 47084131 |

serial 현재값 item_0 1340, item_1~6 160, item_7 180, 양쪽 동일. fail_counter 0.

| 도구 | 결과 |
|---|---|
| a1check | no-dep 10, dep≤frontier 908, 지름길 **0**. pending 805 / 805 / 미해제 **0**. 대기 평균 0.016s |
| fullcheck | ORDERED 1131, PRED_BEFORE_TRACE 569, 역전 **0** |
| par | 워커 작업 918건(워커당 89~95), 최대 동시 10, 바쁜 동안 평균 **1.98**, fragment→outer 역전 0 |
| 지연 | 트랜잭션별 (slave retire − master commit) 최대 **0.108s**, 평균 0.053s (584건). 부하 4.4초 |

par의 "선행 완료 전 시작 2건"과 a1check의 "최대 대기 1.022s"는 둘 다 er_log 시각이 `.000`으로 찍히는 알려진 오류(ms 자리 초 올림 누락, 이번 로그에 20줄)에서 나온 값이다. 해당 두 작업(trid 6640, 540|3400·540|6592)은 park 시각이 `14:05:36.000`이고 해제·선행 완료가 `14:05:37.02x`로, 실제로는 선행 완료 직후 해제된 것이다. LSA 기준 도구(a1check 지름길 0, fullcheck 역전 0)는 이 영향을 받지 않는다.

동시 워커 평균은 4 클라이언트 1.61 → 8 클라이언트 1.98. 부하가 4.4초에 끝나 slave가 포화되지 않으므로(바쁜 시간 1.1초/구간 6.2초) 병렬성의 상한은 아직 못 본 것이고, 백로그 부하가 남는다.

## Run 3 (2026-10-11) — 리팩토링 이후 빌드 재확인

빌드 `11.5.0.2620-ef90e6e`(cs 커밋 다이어트까지 반영, 10-10 23:57 빌드)를 양 노드에 설치하고 conf를 복원(md5 57f0224f / 68235c04)한 뒤, Run 2와 같은 명령(seed 20261006, 8 tables, 8 clients, 800 tx, SYSOP 비율 0.4)을 돌렸다. 실행 디렉토리 `sysop_runs/20261010T150938-20261006-1175812`.

하니스 판정 **PASS**. master 데드락 희생자 4건(tx 48 19번째 줄, 205 18, 206 11, 471 19)은 검증기가 실패 줄 뒤 문장만 반영해 모델과 일치했다.

직접 교차 검증: youngjun3(master)과 youngjun4(slave, `testdb@localhost`)에서 9개 테이블의 COUNT·SUM(version_no)·SUM(hit_count)·MAX(id)·SUM(id)·SUM(logical_key)·SUM(LENGTH(payload))와 `_db_serial`의 AUTO_INCREMENT 현재값 8개를 각각 조회해 diff했다. 전부 일치. 두 호스트가 다른 서버라는 확인은 `_db_ha_apply_info` 행 수(master 1, slave 11 = 리더 1 + 워커 10)로 했다.

| 도구 | 결과 |
|---|---|
| a1check | no-dep 12, dep≤frontier 908, 지름길 **0**. pending 진입 824 / 해제 824 / 미해제 **0**. pending 대기 평균 0.014s 최대 0.039s. A1 추가 대기 합 0.138s |
| fullcheck | ORDERED 1114, PRED_BEFORE_TRACE 569, 역전 0, 멈춤 0 |
| par | 워커 작업 919건(워커당 98~103), 최대 동시 10, 바쁜 동안 평균 **1.94**, 선행 완료 전 시작 **0**, fragment→outer 역전 0. apply span 7.9s, busy 1.0s |
| SYSOP | master `commit_order` 324건 = slave `SYSOP slave` 324건. reason: incr 240, serial 84 |
| 지연 | master 마지막 부하 커밋 00:09:45.999(trid 5191, 601\|15904) → slave retire 00:09:46.004, **5ms**. 부하 5.5초(40.464~45.999) |
| slave er_log ERROR | 기동 직후의 -82·-1038 두 줄뿐 |
| apply 오류 | worker apply done 920건 전부 error=0, fail_counter delta 0 |

워커 행(`_db_ha_apply_info` worker_id 0~9)의 `max_committed_lsa`는 596|1880 ~ 601|15904로 워커마다 갱신돼 있었다(재시작 상한 기능이 이번 빌드에서 처음 실측됨).

Run 2와 비교하면 동시 워커 평균 1.98 → 1.94, SYSOP 324(Run 2는 918건 작업 중 SYSOP 비율 같음)로 같은 수준이다. 리팩토링(핸드셰이크 제거, 코디네이터 초기화 분리, 워커 모듈 이동, rec_type·누수 정리, cs 디버그 제거)이 동작과 성능을 바꾸지 않았다.

## 남은 일

- applylogdb 재시작(부하 중 kill → 재기동 → 일치·`recovery_skipped_counter`), cub_server 재시작(12.8) 실측.
- 백로그(포화) 부하에서 outstanding 상한과 비차단 queue의 동작.
- 하니스: 클라이언트 간 데드락이 부하 설계상 생길 수 있음을 README에 적을 것.
