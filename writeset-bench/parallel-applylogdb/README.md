# CBRD-27508 병렬 applylogdb 성능 측정 — 모음

브랜치 `feature/CBRD-27508-parallel-applylogdb-writeset`, 측정 2026-11-06 ~ 2026-11-08.

**먼저 읽을 것: `docs/ha_work_log.md`** — 작업 내역 · 분석 내역(문제 1~10) · 수정 방법 · 남은 일 · 자료 위치.

| 디렉토리 | 내용 |
|---|---|
| `docs/` | **`rk_perf.md` (RK 브랜치 CBRD-26246 성능 지연 조사)**, `ha_work_log.md` (요약), `ha_final_report.md` (상세 보고서), `ha_test_resume.md` (작업계획서 · 이어받기 · 측정 절차 보완) |
| `scripts/` | `ha_backlog.sh` (백로그 따라잡기 측정), `ha_load.sh` (부하, 시나리오 A/B/C/D), `ha_eustack.sh` (샘플러), `ha_analyze.sh` + `ha_analysis/` (분석), `ha_pstack.sh` (**사용 금지** — 대상 정지), `ha_run_all.sh`·`ha_scale.sh` (초기 측정, 결과 무효) |
| `results/` | 회차별 측정 결과와 실행 로그. `slave/` 는 슬레이브 회차 디렉토리·perf 원본·1차 pstack 샘플의 사본 |
| `trace_logs/` | `ha_writeset_trace_level=1` 회차의 applylogdb 에러 로그 (pending 큐 재현용) — `A_20261107`, `B_20261108` |

실행은 `scripts/` 안에서 한다 (`ha_backlog.sh` 가 같은 디렉토리의 `ha_load.sh` 를 부른다). 슬레이브에는 `~/ha_eustack.sh`, `~/ha_pstack.sh` 가 따로 배포되어 있다.
