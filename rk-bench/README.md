# RK 복제 성능 측정

perf·pstack 결과와 후속 조사 항목은 [RK 성능 보고서](BENCHMARK_REPORT.md)에 정리했다.

CBRD-26246 브랜치의 단일 applylogdb HA 측정이다. pstack, perf, 처리량을 A(키 범위 분리)와 B(키 경합) 부하에서 측정했다.

- [초기 측정 보고서](rk-baseline/ha_rk_perf_report.md)
- [optdebug·release 추가 분석](rk_perf.md)

`rk-baseline/`과 `results/`에는 실행 스크립트 및 선별한 텍스트 결과를 보관한다. perf 바이너리와 전체 로그 원본은 로컬 `/home/youngjun/cbrd26246_perf/` 및 `/home/youngjun/cbrd27508_perf/results/`에 있다.
