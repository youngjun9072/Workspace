# HA 복제 벤치마크 보고서 안내

perf·pstack 측정은 브랜치별로 따로 정리했다.

- [Writeset 병렬 applylogdb 성능 보고서](writeset-bench/BENCHMARK_REPORT.md): CBRD-27508, PR #8052 리뷰와 새 발견 항목 구분
- [RK 복제 성능 보고서](rk-bench/BENCHMARK_REPORT.md): CBRD-26246, 마스터·슬레이브 perf 및 적용 실패 관찰

두 브랜치는 측정 빌드·시점·적용 구조가 다르므로 처리량을 직접 비교해 기능별 오버헤드로 계산하지 않는다.
