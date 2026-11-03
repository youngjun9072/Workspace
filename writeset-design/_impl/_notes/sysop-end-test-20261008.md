---
tags: [writeset, test, sysop_end, parallel]
date: 2026-10-08
build: 11.5.0.2636-1a611b4 (2026-10-07 23:15 빌드, 작업트리 수정 포함: 재시작 복구 구간·SYSOP_END 조각/배리어, C1 수정 전)
harness: ~/Workspace/ha_bench-sysop-random (sysop-random)
---

# SYSOP_END 테스트 결과 (2026-10-08)

## Run 1 — 하니스 버그가 있는 상태의 실행

- 실행 디렉터리: `sysop_runs/20261007T151831-20261006-4134496`
- 명령: `--profile random --seed 20261006 --clients 4 --transactions 400 --tables 4 --preload-rows 50 --tx-weights long=50,single-explicit=30,autocommit=20 --outcome-weights commit=70,abort=30 --dml-weights insert=65,update=15,delete=10,incr=10 --relation-weights dependent=75,independent=25 --long-statements 10:25 --long-delay-ms 5:40 --wide-transactions 4`
- 하니스 판정: PASS — **무효**. 아래 하니스 버그 때문에 slave를 읽지 않았다.

### 하니스 버그

| 버그 | 영향 | 상태 |
|---|---|---|
| `config/default.json`의 `slave.host`가 비어 slave 스냅샷·`fail_counter`·스키마 대기가 모두 master(`testdb`)에 접속 | "master = slave" 비교가 master끼리 비교였다. `fail_counter`도 master 값(0). 이 설정을 쓴 이전 SYSOP_END 실행 전부 해당 | Run 2에서 수정 |
| `SELECT SLEEP(<ms>)` — CUBRID `SLEEP()`은 초 단위 | 긴 트랜잭션이 수십 초씩 잠들어 400건에 22분, slave 부하 거의 없음 | Run 1부터 수정 적용(워크로드 5.3초) |
| wide 스냅샷 쿼리가 `||` 1000단 연결로 파서 중첩 한도(400) 초과 | 스냅샷 단계 실패 | 균형 트리로 수정 |
| slave trace 판정이 새 문구(`fragment assemble`)를 인식 못 함(P6) | 항상 `SYSOP_TRACE_MISMATCH` | 수정 |

### 진짜 slave(`testdb@youngjun4`)와 직접 비교한 결과

| 항목 | 결과 |
|---|---|
| `item_1`~`item_3` | master = slave |
| `item_0` | **불일치 2행**. `logical_key=100021`: version_no master 5 / slave 4. `logical_key=100037`: hit_count master 9 / slave 3 |
| wide 테이블 | slave 행 수는 4로 같지만, slave에서 컬럼을 읽으면 **`cub_server` 비정상 종료** (`heap_attrvalue_point_fixed`, `heap_file.c:10822`, 00:21:53, `log/coredump/cub_server_20261008002153.098.coredump`). 서버는 재기동해 standby 복귀 |
| slave `fail_counter` | **11009**. 전부 wide 테이블 UPDATE 실패 `-711 An object with the supplied attribute value doesn't exist` (23:32 첫 wide 실행부터 누적) |
| 불일치 시점 | 서버 재기동 전에 찍은 비교에서도 같은 2행이 달랐다. 재기동이 원인이 아니다 |

### SYSOP_END 처리 (slave trace, trid 14981~18448 구간 전체)

| 항목 | 결과 |
|---|---|
| master SYSOP 경계 / slave 조각 | 480 / 480 (누락·중복 0) |
| 조각 종류 | 라벨 있는 조각 476, 긴 트랜잭션 조각(`long=1`) 4, **배리어 0** (라벨 없는 SYSOP_END 미발생) |
| 조각 → 같은 trid 바깥 COMMIT | 381쌍 모두 바깥 COMMIT이 조각 완료 뒤 시작 |
| preload 트랜잭션(412 아이템, wide INSERT 4 포함) | slave 적용 `rows=412 error=0` |

### 병렬성

| 항목 | 결과 |
|---|---|
| 워커 분배 | task 921개, 워커 10개에 87~96개 |
| 동시 실행 | 최대 10, 평균 2.59 (바쁜 시간 기준) |
| 순서와 다른 완료 | 인접 쌍 920 중 336 |
| 게이트 | 즉시 423, 대기 477, 해제 497 |
| 의존성 위반 | 793건 중 0 |
| **적용 소요** | 워크로드 5.3초, slave 적용 00:18:32~00:21:02 **149초**. 워커 실제 작업 0.9초 |
| **대기 시간** | 대기 477건 전부 `dependency_is_ref=1`(frontier 대기). 중앙값 3.2초, 최대 9.9초 |

해석(수정): 처음에는 바깥 COMMIT의 조각 frontier 대기 사슬을 원인으로 보았으나, Run 2(wide 없음)에서는 같은 워크로드가 15초 만에 적용됐다. Run 1의 149초는 wide UPDATE 실패 11009건(실패마다 오류 기록)의 영향이 큰 것으로 본다. 대기 시간 자체(중앙값 3초대)는 Run 2에도 있다.

### 별도로 발견한 것 (중단한 DDL 실행, 00:07)

- 00:07:31 slave `item_0` INSERT 실패 `server error: -1, internal client error` → 00:07:33 applylogdb 재시작. 같은 시각 slave 서버에 applylogdb 워커들의 `btree.c:31530 ERROR -670`.
- DDL(CREATE TABLE)로 시작하는 트랜잭션이 들어간 실행이었다. 원인 미조사.

### 확인 필요 (코드)

1. `item_0` 2행 불일치: INCR 조각과 같은 행 UPDATE의 적용 순서가 어긋났을 가능성. 해당 trid의 master 라벨과 slave 적용 순서를 추적해야 한다.
2. wide 행 손상: 1001개 INCR 조각(긴 트랜잭션 조각) 적용 경로, 또는 preload INSERT 적용 결과가 slave 레코드를 깨뜨렸을 가능성. slave 서버를 죽이므로 우선순위 높음.
3. frontier 대기 사슬: 바깥 COMMIT의 조각 대기 방식(9.1.1 설계는 개별 완료)과 결과 수거 주기.

## Run 2 — 하니스 수정 후 (진짜 slave 비교 + checksumdb)

- 실행 디렉터리: `sysop_runs/20261007T152611-20261006-4141351`
- 하니스: `--config config/youngjun_ha.json`(`slave.host=youngjun4`, 대기 600초), SLEEP 수정, `--checksumdb`
- wide 제외: slave에서 wide 행을 읽으면 slave 서버가 죽는다(Run 1). 나머지 조건은 Run 1과 같다.
- 실행 전 정리: Run 1 객체 DROP → master·slave 사용자 테이블 0 확인.
- 워크로드 4.2초, slave가 행이 있는 task를 적용한 구간 00:26:13~00:26:28(15초).

### 판정: 실패 (데이터 불일치)

| 항목 | 결과 |
|---|---|
| 하니스 verdict | `INCONCLUSIVE_SERIAL_SNAPSHOT` — 600초 안에 master=slave에 도달하지 못함. serial 조회가 양쪽 모두 비어 판정명이 이렇게 나왔을 뿐(하니스 문제), 실제 원인은 아래 데이터 불일치 |
| `item_1`, `item_3` | master = slave |
| `item_0` | `100001`: version_no 6/3, hit_count 7/3. `100037`: hit_count 10/4 |
| `item_2` | `300002`, `300021`: version_no 2/1 |
| slave `fail_counter` | 11009 → 11009 (이번 실행 증가 0, 적용 오류 없음) |
| SYSOP 경계 | master 497 = slave 497, 누락·중복 0 |

### 불일치 원인 (trace로 확인)

`100001` 행을 바꾼 UPDATE 6건의 master 커밋 순서는 19907 → 20054 → 20202 → 20487 → 21170 → 21433인데, slave 적용 순서는 20487 → 21170 → 19907 → 21433 → 20054 → 20202였다. slave에는 20202의 행 이미지(version 3)가 마지막으로 남았다.

- 20487의 probe는 `100001` 행 키 두 개에서 20202의 커밋 `1778|3280`을 정확히 찾았다.
- 그러나 최종 dependency는 키별 후보의 최댓값인 `1789|15680`(trid 20427의 INCR 조각) 하나였고, `dependency_source=WRITE_BOUND`라 slave는 그 한 건의 개별 완료로 통과시켰다.
- `1789|15680`은 `1778|3280`에 의존하지 않는다(다른 키, dependency `1767|6840`). 따라서 20487은 20202보다 먼저 적용될 수 있었다.

`300002`도 같다. 21285는 21193(`1858|3312`)과 키가 겹치는 것을 찾았지만 dependency는 더 큰 `1866|2496` 하나였고, 두 트랜잭션이 다른 워커에서 동시에 실행돼 21193의 이미지가 남았다.

**결론: "dependency = 키별 후보 최댓값 하나, WRITE 출처면 개별 완료로 통과" 규칙이 성립하지 않는다.** 최댓값 트랜잭션이 다른 후보들 뒤에 적용됐다는 보장이 없다. 키가 여럿인 트랜잭션이 서로 다른 선행 트랜잭션과 겹치면 순서가 뒤집힌다. INCR와 무관하게 일반 UPDATE에서도 생긴다. hit_count 손실도 같은 경로(INCR 조각과 UPDATE의 행 이미지 순서 역전)로 설명된다.

이 결함은 발표 설계(6-2 gate 판정, CLAUDE.md 슬레이브 불변식 5)에 있는 규칙이다. 지금까지는 하니스가 master끼리 비교해 드러나지 않았다. 이전 SYSOP_END·병렬 PASS 기록은 모두 재검증이 필요하다.

수정 방향(결정 필요):
- frontier 대기로 통일(MySQL 방식). 안전하지만 병렬성이 줄어든다.
- 라벨에 후보 여러 개(서로 다른 선행 커밋 전부)를 싣는다. 로그 형식 변경.
- 마스터가 후보들 사이의 선후를 보장하도록 dependency를 고른다(예: 모든 후보가 최댓값의 선행 사슬 안에 있을 때만 개별 완료 허용, 아니면 frontier 대기 표시).

### SYSOP_END 수정 내용 처리

| 항목 | 결과 |
|---|---|
| 라벨 있는 조각 | 497건, 모두 slave 조각 task로 적용 |
| 조각 → 같은 trid 바깥 COMMIT | 365쌍 모두 조각 완료 뒤 시작 |
| 바깥 abort | 롤백된 트랜잭션의 INCR도 master에 남고 slave에도 적용(100037 hit_count 10 중 slave 4는 순서 역전 때문이며, 조각 자체는 적용됨) |
| 긴 트랜잭션 조각 | 이번 실행은 wide를 빼서 0건. Run 1에서 4건 발생했으나 그 결과 wide 행이 손상됨(Run 1 참조) |

### 라벨 없는 SYSOP_END (checksumdb)

하니스 `--checksumdb`는 테이블 이름 형식(`owner.class` 필요) 때문에 Run 2 워크로드 중에는 실행되지 않았다(하니스 수정 완료). 워크로드 뒤 Run 2 테이블에 대해 단독 실행했다.

| 항목 | 결과 |
|---|---|
| checksumdb 청크 | 23개(item_0 16, item_1 2, item_2 3, item_3 2) |
| slave 처리 | 23건 모두 배리어 조각(`barrier=1 long=0`), 적용 오류 0 |
| checksumdb 리포트(slave 기준) | `item_0` 청크 0 불일치 1건 — 위 데이터 불일치와 일치. `item_2`는 불일치 0으로 보고됐으나 직접 비교로는 2행이 다르다(원인 미확인) |

워크로드와 동시에 실행한 배리어(뒤 트랜잭션을 실제로 막는 상황)는 아직 확인하지 못했다.

### 병렬성

| 항목 | 결과 |
|---|---|
| 워커 분배 | task 1224개, 워커 10개에 118~126개 |
| 동시 실행 | 최대 10, 평균 3.33 (바쁜 시간 기준). 2개 이상 동시 실행 비율 60% |
| 순서와 다른 완료 | 인접 쌍 1223 중 338 |
| 게이트 | 즉시 734, 대기 490, 해제 490 |
| 대기 시간 | 중앙값 3.64초, 최대 10.79초 (대기 중 frontier 대기 156건) |
| 의존성 위반 | 라벨 dependency 기준 598건 중 0 — **그러나 위와 같이 라벨이 담지 못한 선행 관계 때문에 실제 순서는 깨졌다** |

병렬 적용 자체(워커 분배, 동시 실행, 라벨 기준 순서 준수)는 동작한다. 문제는 라벨이 필요한 선행 관계를 모두 담지 못한다는 점이다.

## 남은 일

1. **dependency 규칙 결함 수정 방향 결정** (위 Run 2 결론). 가장 중요.
2. wide 행 손상과 slave 서버 crash 원인 조사 (긴 트랜잭션 조각 또는 1001 컬럼 행 적용).
3. 대기 시간이 수 초인 이유 (task 적용은 ms 단위).
4. DDL 트랜잭션 실행 중 slave INSERT 실패와 applylogdb 재시작(00:07) 원인.
5. checksumdb를 워크로드와 동시에 실행해 배리어의 뒤 트랜잭션 차단 확인.
6. 하니스: serial 스냅샷이 비는 문제, 기본 config의 `slave.host`.
7. Run 2 객체는 조사용으로 남겨 둠(정리 안 함).
