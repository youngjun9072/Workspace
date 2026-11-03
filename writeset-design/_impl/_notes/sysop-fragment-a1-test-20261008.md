---
tags: [writeset, test, sysop, fragment, gate, parallel]
date: 2026-10-08
build: 11.5.0.2637-67b110c (2026-10-08 15:43 빌드, A1 + SYSOP_END commit-order 커밋 56e757e, 조각 경로는 파라미터로 켬)
harness: ~/Workspace/ha_bench-sysop-random (sysop-random, seed 20261006, Run 2 부하)
---

# 조각(fragment) 모드 + A1 gate 테스트 결과 (2026-10-08)

## 목적

[commit-order 테스트](./sysop-commit-order-test-20261008.md)에서 slave 지연이 62초가 된 뒤, 같은 빌드에서 `ha_writeset_sysop_fragment=yes`로 조각 경로를 켜고 같은 seed를 돌렸다. A1 gate 위에서 조각 라벨을 돌린 첫 실행이다. 보려는 것은 세 가지다. A1 gate에서 조각이 역전 없이 끝나는가, 지연이 commit-order와 얼마나 다른가, 설계 문서가 예고한 원인 B(`prev_commit_lsa` 하향이 조각 LSA 후보를 건너뜀)가 실제 라벨에 나타나는가.

## 방법

- 실행 디렉터리: `sysop_runs/20261008T073857-20261006-361031`
- 명령: commit-order 테스트와 동일(Run 2 부하, `--checksumdb` 없음).
- 설정: 양 노드 `cubrid_ha.conf`에 `ha_writeset_sysop_fragment=yes` 추가, 재설치·createdb·HA 기동 뒤 실행. `cubrid paramdump` 양 노드 `y`.
- 빌드·conf는 commit-order 테스트와 같다(cubrid.conf md5 57f0224f, cubrid_ha.conf a1db3bb1 양 노드 동일).

## 비교 대상 검증

| 항목 | 결과 |
|---|---|
| HA 상태 | youngjun3 master/active, youngjun4 slave/standby |
| 실행 시작 시 fail_counter | master 0, slave 0 |
| 직접 교차 조회 | 네 테이블 모두 행 수·Σversion_no·Σid가 master와 slave에서 같음 (아래 표) |
| serial 현재값 | 네 serial 모두 master = slave |
| 부하 시간 | master 커밋 298건, 16:38:58.71 ~ 16:39:02.93 (4.2초) |

| 테이블 | master (행 수, Σversion_no, Σid) | slave |
|---|---|---|
| item_0 | 1566, 310, 1729327 | 1566, 310, 1729327 |
| item_1 | 188, 19, 22507 | 188, 19, 22507 |
| item_2 | 202, 24, 26128 | 202, 24, 26128 |
| item_3 | 197, 27, 25862 | 197, 27, 25862 |

slave `applyinfo`: Insert 2252, Update 907, Delete 91, Commit 383, **Fail 0**. slave er_log `ERROR` 0.

## 판정

**PASS.** 데이터 일치, 역전 0, 지름길 0, pending 미해제 0. 단, 라벨 값이 틀린 사례 19건이 master trace에서 확인됐다(아래 "원인 B 확인"). 이번 실행에서는 타이밍 덕에 역전으로 이어지지 않았다.

## master 라벨

`SYSOP master fragment` 497건, `commit_order` 0건, `HISTORY_START raise` 0건. 복제 항목 있는 SYSOP_END 497건이 모두 조각 라벨(행 충돌 상대 좌표)을 받았다. 복제 항목 없는 SYSOP_END는 slave에서 `items=0 action=defer` 54건. `long=1` 0건.

## 세 실행 비교 (같은 seed, 같은 부하)

| 항목 | Run 2 (조각, 지름길 gate) | 조각 + A1 (이번) | commit-order + A1 |
|---|---|---|---|
| 작업 수 | 806 | 829 | 924 |
| dependency가 바로 앞 작업인 비율 | 17% | 17% | 73% |
| frontier gate 기준 가장 긴 사슬 | 182칸 | 186칸 | 683칸 |
| pending 진입 / 미해제 | 296 / 0 | 597 / 0 | 795 / 0 |
| pending 대기 평균 / 중앙값 / 최대 | 1.86s / 1.98s / 4.67s | 5.74s / 5.55s / 12.80s | 31.3s / 31.4s / 62.2s |
| reader가 깨어나 pending을 푼 횟수 / 회당 중앙값 | 72 / 4 | 168 / 3 | 661 / 1 |
| 모든 워커 유휴 구간 수 (0.10초인 것) | 73 (59) | 170 (168) | 650 (626) |
| master 마지막 커밋 → slave 마지막 apply | 1.8s | **12.9s** | 62.3s |
| slave apply 구간 | 7.1s | 17.1s | 66.5s |
| 바쁜 동안 평균 동시 작업 / 최대 | 3.80 / 16 | 3.30 / 14 | 1.19 / 6 |
| 지름길 통과 (불건전) | 있음 | 0 | 0 |
| 역전 (`fullcheck`) | 11 | **0** | 0 |

### 해석

- 조각 라벨은 사슬을 거의 만들지 않는다(186칸, Run 2와 같음). commit-order의 683칸과 정반대다. 라벨이 행 충돌 상대를 가리키므로 history_start가 올라가지 않고, 의존이 바로 앞 작업인 비율이 17%에 그친다.
- 그래도 12.9초가 걸린 이유는 같은 reader 100ms다. 깨어난 횟수 168 × 0.1초 ≈ 17초가 apply 구간 17.1초와 맞는다. Run 2보다 깨어난 횟수가 두 배 이상인 것은 지름길이 없어진 값이다. Run 2는 completed set 멤버십으로 바로 통과시켰고(그래서 역전 11건), A1은 frontier가 닿을 때까지 pending에 넣으므로 pending 진입이 296에서 597로 늘고 그만큼 reader 기상을 더 기다렸다.
- 즉 "조각 + A1"의 12.9초도 설계 비용이 아니라 reader 100ms가 지배한다. 100ms를 없애면 조각은 사슬 186칸 × 수 ms 수준(추정, 산술)이 된다.

## 원인 B 확인

master가 조각 후보를 건너뛰고 라벨을 낮춘 사례를 trace에서 셌다. 기준은 "WRITE 후보 중 조각 LSA가 있는데 최종 dependency가 그보다 작다".

| 구분 | 건수 |
|---|---|
| 라벨이 조각 후보 아래로 내려간 작업 | 19 |
| 건너뛴 조각이 자기 트랜잭션의 앞 조각 | 9쌍 |
| 건너뛴 조각이 **다른 트랜잭션**의 조각 | **10쌍** |
| 이번 실행에서 그 작업이 건너뛴 조각 완료 전에 출발 | 0 |

다른 트랜잭션 조각을 건너뛴 10쌍은 라벨 값이 틀린 것이다. 예를 들어 trid 662의 조각(241|14576)은 trid 664의 조각(241|4720)과 같은 행을 건드렸는데 라벨은 240|15936이다. A1 gate는 frontier가 240|15936에 닿으면 이 작업을 보내므로 664의 조각이 끝나기 전에 출발할 수 있다. 이번에는 reader 100ms로 전체가 느려서 0.7초 뒤에 출발했을 뿐이다. `gatesim` 재생(백로그 포화, 워커 10)에서는 현재 라벨 그대로 돌리면 선행 완료 전 출발이 14건 나온다(건전한 규칙들은 0).

원인은 `wset_find_dependency_in_range`의 `min(최댓값, prev_commit_lsa)` 하향이다(writeset.cpp:879~887). prev_commit_lsa는 마지막 **커밋** LSA라서, 그보다 뒤에 게시된 조각 LSA가 후보일 때 라벨이 조각 아래로 내려간다. [11장 11.9-2](11-dependency-label-design.md#119-todo--개선-포인트)에 적힌 대로 기준값을 "마지막 게시 LSA"로 바꾸거나 하향을 없애야 한다. 조각 모드를 기본으로 쓰려면 선결이다.

자기 조각을 건너뛴 9쌍은 같은 trid 조각 사이 순서(설계 9.1.1) 문제다. 이번에는 역전되지 않았지만 보장은 없다.

## 결론

1. A1 gate 위에서 조각 라벨은 역전 0, 지름길 0으로 끝났고 데이터가 일치한다. Run 2의 역전 11건은 gate 지름길 탓이었음이 다시 확인된다.
2. 지연 12.9초는 commit-order 62초의 5분의 1이지만, 둘 다 reader 100ms가 지배한다. 설계 비용 비교는 100ms 제거 뒤에 해야 한다. 사슬 길이(186 대 683)는 그 비교의 예고다.
3. 원인 B는 실제 라벨 19건(다른 트랜잭션 조각 10쌍)으로 확인됐다. 조각 모드는 이 수정 없이는 건전하지 않다.

## 남은 일

- reader 100ms 해제 지연 제거 뒤 두 모드 재측정.
- 원인 B 수정(기준값 변경 또는 하향 제거) 뒤 조각 모드 재측정.
- 같은 trid 조각 순서(9.1.1), long transaction 유예, DDL 경로.
