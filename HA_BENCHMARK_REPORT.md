# HA 복제 성능 측정 통합 보고서

정리일: 2026-11-10. 이 문서는 기존 측정 결과를 합친 것으로, 새 벤치마크를 실행한 결과가 아니다. writeset PR은 [CUBRID/cubrid #8052](https://github.com/CUBRID/cubrid/pull/8052)이다.

## 먼저 구분할 것

| 측정 묶음 | 코드·빌드 | 측정 대상 | 원문 |
|---|---|---|---|
| writeset 병렬 적용 | CBRD-27508, 측정 당시 로컬 `bf560620e`, optdebug, 2026-11-06~08 | 슬레이브 applylogdb 처리량·스택·perf, 슬레이브 서버 스택, 재기동 정합성 | [최종 보고서](writeset-bench/parallel-applylogdb/docs/ha_final_report.md), [작업 기록](writeset-bench/parallel-applylogdb/docs/ha_work_log.md) |
| RK 초기 측정 | CBRD-26246 `f0bc3158d`, optdebug, 2026-11-09 | 단일 applylogdb, 슬레이브 서버 pstack·perf | [초기 보고서](rk-bench/rk-baseline/ha_rk_perf_report.md) |
| RK 추가 측정 | 같은 RK 커밋, optdebug·release, 2026-11-09~10 | 마스터·슬레이브 서버와 applylogdb의 스택·perf·처리량 | [상세 분석](rk-bench/rk_perf.md) |

**마스터 perf 결과가 있는 것은 RK 측정이다.** writeset 측정에는 슬레이브 applylogdb의 perf 결과가 있지만, 마스터 cub_server에 perf를 붙인 결과는 없다. RK의 `perf_master.data`를 writeset 마스터 비용으로 해석할 수 없다. `develop`과 writeset 브랜치를 같은 조건에서 대조한 결과도 없다.

## 처리량과 관찰 결과

| 측정 | 조건 | 결과 | 해석 |
|---|---|---|---|
| writeset, A(키 범위 분리) | optdebug, trace 0, 샘플러 없는 백로그 따라잡기 | 워커 1/4/10/20: **347/965/1,630/1,729 tx/s** | 10개 이후 증가폭은 작음 |
| writeset, B(핫키 경합) | 같은 방법 | **225/449/413/340 tx/s** | 4개 이후 처리량 감소. 코디네이터의 pending 재스캔이 주요 원인 |
| RK, A/B | release, 단일 applylogdb, 긴 백로그 회차 | **3,432/1,675 tx/s** | writeset의 optdebug·병렬 결과와 직접 비교할 수 없음 |
| RK 마스터 | release, 부하 중 cub_server perf | `heap_get_class_repl_on` **0.15~0.18%**, `or_is_replication_candidate_key` **0.02%** (CPU 샘플 비중) | **RK 기능의 마스터 비용**에 관한 결과이며 writeset 비용은 아님 |
| RK 슬레이브 | release, cub_server perf | RK 관련 클래스 조회·인덱스 탐색 **약 0.8~1.3%** (CPU 샘플 비중) | 단일 적용 경로의 결과 |

초기 writeset 보고서 4절의 3.74배·5.60배는 pstack이 대상 프로세스를 멈춘 회차의 수치다. 위 표는 trace를 끄고 **처리량 측정과 스택 측정을 분리한 재측정값**을 사용한다. 각 구성은 대체로 한 회차이며, 두 브랜치는 빌드 모드·시점·적용 구조가 달라 숫자 차이를 기능별 회귀율로 계산할 수 없다.

## writeset 측정에서 발견한 항목과 PR 리뷰

번호는 [작업 기록의 전체 목록](writeset-bench/parallel-applylogdb/docs/ha_work_log.md)을 따른다. 리뷰 대응은 2026-11-10의 PR #8052 리뷰 본문·인라인 댓글 기준이다. 측정 코드는 10월 29일 로컬 커밋이고 PR HEAD는 `6bd39a696`이므로, 아래 수치를 현재 PR의 재측정 결과로 읽으면 안 된다.

| # | 측정·코드에서 확인한 내용 | PR #8052 리뷰와의 관계 | 후속 판단 |
|---|---|---|---|
| 1 | 마커 INSERT가 공용 `la_sql_compile_mutex`를 잡은 채 서버 왕복. 깨끗한 A 워커 10 측정에서 워커 시간 **약 31%** | [동일 병목 지적](https://github.com/CUBRID/cubrid/pull/8052#pullrequestreview-5797924349) | 개선 검토 대상. 11/10 PR HEAD에도 실행 구간의 잠금이 남아 있음 |
| 2 | 워커가 슬레이브 서버의 행 적용·커밋 응답을 기다림 | 동일 결함 리뷰 없음 | 서버 대기 관찰. 이것만으로 버그로 분류하지 않음 |
| 3 | A는 워커 10 이후 효과 작고 B는 워커 4 이후 감소 | 동일 결함 리뷰 없음 | 부하별 운영 설정 근거. 원인은 1·5·10 등에서 따로 평가 |
| 4 | 워커 수에 따라 VSZ 약 76MB씩 증가 | 동일 결함 리뷰 없음 | 메모리 사용 관찰. 누수 판정 아님 |
| 5 | pending 연결 리스트를 반복 재스캔. B 워커 4에서 코디네이터 CPU의 **56%**가 스캔 | 동일 지적을 찾지 못함 | **새 성능 개선 후보.** 11/10 PR HEAD에도 선형 순회가 남아 있음 |
| 6 | 로그 페이지 캐시 공용 뮤텍스 대기 | 동일 지적을 찾지 못함 | 깨끗한 재측정은 0.6~1.6%. 즉시 수정 우선순위 낮음 |
| 7 | pending 태스크를 파킹할 때마다 malloc/free | 동일 지적을 찾지 못함 | 낮은 우선순위. 5번의 자료구조 개선과 함께 검토 가능 |
| 8 | FK 부모·자식 적용 순서 전용 테스트가 TODO | [관련 FK 순서 리뷰](https://github.com/CUBRID/cubrid/pull/8052#discussion_r4490729779)는 **별도 원인**을 지적 | 성능 결함으로 확정하지 않음. FK 동작별 정합성 테스트 필요 |
| 9 | trace 출력 시 공유 로그 뮤텍스 경합 | [같은 뮤텍스 비용을 지적한 리뷰](https://github.com/CUBRID/cubrid/pull/8052#discussion_r4267355303) 있음 | trace 기본값 0. 켠 경우의 진단 비용으로 관리 |
| 10 | 코디네이터가 주기적으로 적용 위치·통계 저장과 마커 삭제를 동기 실행 | [같은 공용 뮤텍스와 마커 삭제를 다룬 리뷰](https://github.com/CUBRID/cubrid/pull/8052#pullrequestreview-5797924349)는 있으나 **주기적 저장 비용 측정은 별도** | 추가 성능 개선 검토 대상. A 워커 20에서 코디네이터 시간 45% |

1·5·10번은 성능 개선을 검토할 근거가 있다. 6·7번은 측정상 우선순위가 낮다. 8번은 정합성 테스트 항목이다. **리뷰에 언급됐다는 사실과 현재 코드에서 수정이 완료됐다는 뜻은 다르다.**

## RK 측정에서 따로 확인된 항목

- release에서 슬레이브 copylogdb의 디스크 쓰기가 마스터 로그 크기의 약 **8배**였다. 원인은 아직 코드로 확정하지 않았으며 writeset PR #8052의 새 결함으로 분류하지 않는다.
- RK release의 고충돌 B에서 `ha_t2` 적용 실패 **157건**이 기록됐다. 측정 종료 뒤 행 덤프는 일치했지만 실패 원인은 미확정이다. writeset 브랜치의 같은 B 부하 재기동 시험에서는 fail counter 증가가 없었다. 빌드·적용 구조가 달라 원인을 RK 기능으로 단정할 수 없다.
- 초기 RK 보고서는 pstack 정지와 짧은 회차의 영향을 받는다. RK 처리량 기준은 [후속 release 분석](rk-bench/rk_perf.md)의 긴 회차를 사용한다.

## 복제 결과 확인과 남은 비교

pstack은 스레드 상태, perf는 CPU 샘플을 보여준다. 데이터 일치는 별도 SQL 조회·행 덤프 비교로 확인했다. writeset은 따라잡기 중 applylogdb를 **13회 강제 종료**한 뒤에도 마스터·슬레이브 데이터가 일치했다. RK release B도 종료 시 행 덤프가 일치했지만 위 적용 실패는 별도 조사 대상이다.

**마스터 writeset 오버헤드는 아직 미측정이다.** 이를 분리하려면 같은 기반 코드·빌드·부하에서 마스터 writeset 처리만 켠 경우와 끈 경우를 비교하고, 마스터 cub_server의 perf 및 처리량·지연을 함께 측정해야 한다. 현재 자료의 RK 마스터 perf나 슬레이브 병렬 처리량을 그 비교값으로 대신할 수 없다.

이 저장소에는 보고서·스크립트·선별한 텍스트 결과를 보관한다. perf 바이너리와 전체 로그는 측정 호스트의 `/home/youngjun/cbrd27508_perf/`와 `/home/youngjun/cbrd26246_perf/`에 남아 있다.
