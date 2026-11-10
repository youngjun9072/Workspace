# RK 복제 성능 보고서

측정 대상은 CBRD-26246 브랜치의 `f0bc3158d`다. 2026-11-09~10에 youngjun1(master)·youngjun2(slave)에서 optdebug와 release 빌드로 측정했다. applylogdb는 단일 스레드다. [초기 측정](rk-baseline/ha_rk_perf_report.md)과 [추가 분석](rk_perf.md)을 이 문서에서 함께 정리한다.

## 측정 범위와 결과

초기 회차는 pstack·perf를 슬레이브 applylogdb와 cub_server에 붙였다. 후속 회차는 마스터 cub_server에도 perf를 붙였다. 처리량은 applylogdb를 멈춰 로그를 쌓은 다음 재시작해 따라잡는 구간에서 측정했다. 초기 pstack 회차는 대상 프로세스를 멈추므로 처리량 기준에서 제외하고, release의 긴 회차를 대표값으로 사용한다.

| 항목 | A: 키 범위 분리 | B: 핫키 경합 | 의미 |
|---|---:|---:|---|
| release 슬레이브 적용 처리량 | 3,432 tx/s | 1,675 tx/s | 긴 회차. B는 호스트 CPU가 깨끗한 59초 구간 |
| release 마스터 `heap_get_class_repl_on` | CPU 샘플 0.15% | 0.18% | RK 복제 옵션 판정 비용 |
| release 마스터 `or_is_replication_candidate_key` | 0.02% | 0.02% | RK 후보 판정 비용 |
| release 슬레이브 RK 클래스 조회·인덱스 탐색 | 약 1.3% | 약 0.8% | cub_server CPU 샘플 비중 |

**이 결과는 RK 기능이 포함된 빌드의 프로파일이다.** `perf_master.data`도 RK 마스터의 결과이며 writeset 마스터 측정값이 아니다. perf 비중만으로 `develop` 대비 절대 오버헤드를 계산할 수 없다.

## 추가 발견과 처리 상태

| 항목 | 측정 결과 | 판단·후속 |
|---|---|---|
| optdebug 검사 비용 | 슬레이브 서버 CPU의 30~40%가 디버그 전용 검사에 쓰임 | release로 재측정 완료. RK 기능 결함 아님 |
| copylogdb 쓰기량 | release 회차에서 마스터 로그 약 1,964MB 대비 슬레이브 copylogdb 쓰기 약 15,462MB | **새 관찰, 원인 미확정.** RK 코드의 오버헤드나 writeset PR 리뷰로 분류하지 않음 |
| B 적용 실패 | release에서 `ha_t2` 적용 실패 157건, A는 0건 | **원인 조사 필요.** 종료 시 마스터·슬레이브 행 덤프는 일치했지만, 실패를 정상 동작으로 확정하지 않음 |
| pstack 회차 처리량 | pstack이 측정 대상을 멈춰 처리량이 낮아짐 | 처리량 비교에서 제외. perf·무계측 회차로 별도 확인 |

이 보고서는 **RK 측정 결과**를 분류한다. writeset PR #8052에 이미 보고된 문제인지 판단하는 자료가 아니다. RK의 적용 실패 157건은 `develop` 동일 부하 대조와 실패 키의 로그 순서 분석 전까지 특정 기능의 원인으로 단정할 수 없다.

## 복제 결과와 원자료

마지막 회차 뒤 행 덤프 비교는 일치했다. 이는 pstack·perf가 증명한 것이 아니라 별도로 수행한 데이터 비교 결과다. 선별한 텍스트 결과는 이 디렉터리의 `results/`와 `rk-baseline/results/`에 있다. perf 바이너리·전체 로그는 측정 호스트의 `/home/youngjun/cbrd27508_perf/`와 `/home/youngjun/cbrd26246_perf/`에 있다.
