# Writeset 병렬 applylogdb 벤치마크

전체 측정 범위와 RK 자료의 차이는 [HA 복제 성능 통합 보고서](../HA_BENCHMARK_REPORT.md)에 정리했다.

`parallel-applylogdb/`에는 CBRD-27508 브랜치의 HA 처리량, pstack/perf 분석, 재기동 정합성 검증 기록과 실행 스크립트를 보관한다. 먼저 [최종 보고서](parallel-applylogdb/docs/ha_final_report.md)를 참고한다.

`results/`에는 선별한 텍스트 요약만 포함한다. perf 바이너리와 전체 로그 원본은 로컬 `/home/youngjun/cbrd27508_perf/results/`에 있다.
