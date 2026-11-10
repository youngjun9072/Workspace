# Writeset 병렬 applylogdb 성능 보고서

측정 대상은 CBRD-27508 브랜치의 2026-10-29 로컬 커밋 `bf560620e` optdebug 빌드다. 2026-11-06~08에 youngjun1(master)·youngjun2(slave)에서 측정했다. writeset PR은 [CUBRID/cubrid #8052](https://github.com/CUBRID/cubrid/pull/8052)이며, 리뷰 대조 기준 HEAD는 `6bd39a696`이다. 상세 방법과 원자료 해석은 [최종 보고서](parallel-applylogdb/docs/ha_final_report.md)와 [작업 기록](parallel-applylogdb/docs/ha_work_log.md)에 있다.

## 측정 범위

마스터에서 부하를 생성한 뒤 슬레이브 applylogdb의 백로그 따라잡기 처리량을 측정했다. pstack·eu-stack으로 슬레이브 스레드 상태를, perf로 슬레이브 applylogdb의 CPU 사용을 확인했다. **마스터 cub_server의 perf 결과는 없다.** 따라서 이 자료는 마스터 writeset 생성 오버헤드를 측정한 결과가 아니다.

처리량은 trace를 끄고 샘플러 없이 측정한 회차를 기준으로 한다. 초기 pstack 회차는 샘플을 뜰 때 applylogdb가 멈춰 처리량이 낮게 나왔으므로 아래 기준에서 제외했다.

| 워커 | A: 키 범위 분리 | B: 핫키 경합 |
|---:|---:|---:|
| 1 | 347 tx/s | 225 tx/s |
| 4 | 965 tx/s | 449 tx/s |
| 10 | 1,630 tx/s | 413 tx/s |
| 20 | 1,729 tx/s | 340 tx/s |

A는 워커 10 이후 증가폭이 작다. B는 워커 4 이후 오히려 느려진다. 따라잡기 중 applylogdb를 13회 강제 종료한 재기동 시험에서는 마스터·슬레이브의 데이터 비교 결과가 일치했다. 데이터 비교는 pstack·perf와 별도의 SQL·행 덤프 검사다.

## 발견 항목과 PR 리뷰

번호는 [작업 기록의 전체 목록](parallel-applylogdb/docs/ha_work_log.md)을 따른다. **리뷰 언급 여부는 수정 완료 여부와 다르다.** 측정 빌드와 PR HEAD도 다르므로, 수치를 현재 PR 코드의 재측정값으로 해석하지 않는다.

| # | 확인 내용 | PR #8052 리뷰 | 후속 판단 |
|---:|---|---|---|
| 1 | 마커 INSERT가 `la_sql_compile_mutex` 아래서 서버 왕복. A 워커 10의 워커 시간 약 31% | [동일 병목 지적](https://github.com/CUBRID/cubrid/pull/8052#pullrequestreview-5797924349) | 개선 검토. 11/10 PR HEAD에도 실행 구간 잠금 존재 |
| 2 | 워커가 슬레이브 서버의 행 적용·커밋 응답을 기다림 | 동일 결함 리뷰 없음 | 서버 대기 관찰, 버그로 확정하지 않음 |
| 3 | A는 워커 10 이후 효과가 작고 B는 워커 4 이후 감소 | 동일 결함 리뷰 없음 | 부하별 운영 설정 근거. 원인은 1·5·10에서 평가 |
| 4 | 워커당 VSZ 약 76MB 증가 | 동일 결함 리뷰 없음 | 메모리 사용 관찰, 누수 판정 아님 |
| 5 | pending 연결 리스트 반복 재스캔. B 워커 4에서 코디네이터 CPU의 56% | 동일 지적 없음 | **새 성능 개선 후보.** 11/10 PR HEAD에도 선형 순회 존재 |
| 6 | 로그 페이지 캐시 공용 뮤텍스 대기 | 동일 지적 없음 | 재측정 0.6~1.6%, 낮은 우선순위 |
| 7 | 태스크 파킹마다 malloc/free | 동일 지적 없음 | 낮은 우선순위. 5번 개선과 함께 검토 |
| 8 | FK 부모·자식 적용 순서의 전용 검증 TODO | [관련 FK 순서 리뷰](https://github.com/CUBRID/cubrid/pull/8052#discussion_r4490729779)는 별도 원인 | 성능 결함이 아님. 정합성 테스트 필요 |
| 9 | trace 출력 시 공유 로그 뮤텍스 경합 | [같은 비용 지적](https://github.com/CUBRID/cubrid/pull/8052#discussion_r4267355303) | trace 기본값 0. 켠 경우의 진단 비용 |
| 10 | 코디네이터가 적용 위치·통계 저장과 마커 삭제를 주기적으로 동기 실행. A 워커 20에서 코디네이터 시간 45% | [같은 뮤텍스·마커 삭제를 다룬 리뷰](https://github.com/CUBRID/cubrid/pull/8052#pullrequestreview-5797924349). 주기적 저장 비용은 별도 측정 | 추가 성능 개선 검토 |

**새로 확인된 수정 후보는 5번이며, 7번은 그 작업과 함께 검토할 수 있다.** 1번과 10번은 기존 리뷰와 연결된다. 6번은 우선순위가 낮고 8번은 테스트 항목이다.

## 아직 측정하지 않은 것

마스터 writeset 오버헤드와 `develop` 대비 순수 기능 비용은 미측정이다. 같은 기반 코드·빌드·부하에서 마스터 writeset 처리만 켜고 끈 대조군과 마스터 cub_server perf가 필요하다. 이 저장소에는 선별한 텍스트 결과만 있으며 perf 바이너리·전체 로그는 측정 호스트의 `/home/youngjun/cbrd27508_perf/`에 있다.
