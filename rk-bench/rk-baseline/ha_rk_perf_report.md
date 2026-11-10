# CBRD-26246 HA 복제 성능 측정

## 대상과 방법

- 측정일: 2026-11-09. 브랜치 `feature/CBRD-26246-develop`, 커밋 `f0bc3158d111c7c386e4d3dbb91ea62cb160f9d4` (`CUBRID_26246` optdebug 빌드).
- `youngjun1` master, `youngjun2` slave, 데이터베이스 `testdb`. 직렬 `applylogdb` 1개를 측정했다.
- [부하 스크립트](scripts/ha_load.sh)는 8개 csql 세션을 60초간 실행한다. 각 트랜잭션은 20개 행 연산을 수행하며 10개 중 1개는 롤백한다. A는 세션별 키 범위를 분리하고, B는 500개 키에 경합을 만든다.
- [측정 스크립트](scripts/ha_backlog.sh)는 slave의 `applylogdb`만 정지하고 master 부하를 만든다. `copylogdb`가 로그를 수집하도록 25초 기다린 후 `applylogdb`를 재시작한다. `db_ha_apply_info.commit_counter`의 백로그 2~98% 구간 증분을 시간으로 나누어 처리량을 계산한다.
- 각 시나리오에서 샘플러 없음, pstack, applylogdb perf, slave cub_server perf를 각각 1회 실행했다. perf는 `record -F 999 -g`를 사용했다.

## 결과

| 시나리오 | 샘플러 | 백로그 tx | 측정 구간 tx / 초 | 처리량 tx/s |
|---|---|---:|---:|---:|
| A, 키 범위 분리 | 없음 | 19,361 | 14,625 / 29 | 504.3 |
| A | pstack | 17,726 | 14,731 / 109 | 135.1 |
| A | applylogdb perf | 18,451 | 12,835 / 22 | 583.4 |
| A | cub_server perf | 21,865 | 15,908 / 27 | 589.2 |
| B, 500개 키 경합 | 없음 | 15,209 | 12,724 / 44 | 289.2 |
| B | pstack | 16,490 | 12,223 / 167 | 73.2 |
| B | applylogdb perf | 10,259 | 6,973 / 21 | 332.0 |
| B | cub_server perf | 11,164 | 7,727 / 22 | 351.2 |

샘플러 없는 회차에서 B는 A의 약 57% 처리량이다. 다만 각 구성은 1회 측정했고, 60초 동안 master가 생성한 로그량도 회차별로 달라졌다. 수치를 안정적인 평균이나 다른 브랜치 대비 회귀율로 해석하면 안 된다. pstack은 샘플마다 대상 프로세스를 멈추므로 그 회차의 처리량은 성능 비교에서 제외한다.

## 대기 지점과 CPU 샘플

- A pstack: 유효 샘플 22개 중 작업 스레드 21개가 `css_readn`에 있었다. B: 32개 중 30개가 `css_readn`에 있었다. 작업 스레드는 대부분 slave 서버 응답을 기다리는 모습이다. 다른 두 스레드는 heartbeat poll 및 signal monitor다.
- applylogdb perf: A 1,770개, B 1,412개 CPU 샘플. B 상위 심볼은 `la_apply_log_file` 3.91%, `__memmove_evex_unaligned_erms` 3.68%, `malloc` 3.06%, `la_log_record_process` 3.04%, `sm_find_class_with_purpose` 2.07%다. perf는 CPU에서 실행 중인 시간만 보므로 `css_readn` 대기 시간의 비율을 뜻하지 않는다.
- slave cub_server perf: A 40,470개, B 37,274개 CPU 샘플. B 상위 심볼은 `pgbuf_fix_debug` 5.17%, `vfprintf` 4.83%, `btree_check_valid_record` 2.35%다. optdebug 빌드의 검사·진단 비용이 보이며, 이 표만으로 특정 기능의 성능 회귀를 확정할 수 없다.
- applylogdb RSS는 회차별 약 16~18 MB 범위였다. 이번 측정만으로 장기 메모리 누수를 판단할 수 없다.

## 검증과 원본

- 모든 부하 회차의 `load.log`와 마지막 생성기 로그에서 `ERROR`, `FAILED`, `deadlock`, `Exception`을 찾지 못했다.
- 마지막 회차 뒤 slave의 heartbeat 상태는 slave였고 `Server`, `Copylogdb`, `Applylogdb`가 모두 등록되어 있었다.
- 마지막 회차 뒤 양 노드의 집계가 일치했다. `ha_t1`: `COUNT(*)=100000`, `SUM(seq)=1630601`, `SUM(sess)=133691`; `ha_t2`: `COUNT(*)=4477`, `SUM(val)=73594627`. 이는 집계 일치 확인이며 행 단위 전체 비교는 아니다.
- 회차별 수치와 시계열은 [`results/`](results/) 아래 `summary.tsv`, `w1/series.txt`에 있다. pstack 원본은 `w1/stacks.tgz`, 집계는 `w1/pstack.txt`에 있다. perf 원본은 `w1/perf_applylogdb.data` 또는 `w1/perf_cub_server.data`, 심볼 집계는 `w1/perf_all.txt`에 보존했다.

다음 단계에서 브랜치 간 처리량 차이를 판단하려면 같은 빌드 설정과 데이터 초기 상태에서 구성당 여러 회차를 반복해야 한다.
