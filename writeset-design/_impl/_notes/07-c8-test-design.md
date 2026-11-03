# C8 코드 설계 — 유닛테스트 + 벤치마크 (develop, TBB 맵 적응)

> C8: PoC `unit_tests/writeset/` 스위트를 develop 위 C1(TBB 맵) 기준으로 이식 + 동시성 벤치(충돌/비충돌) + config-구동 사이징 테스트 추가. 전부 미커밋. C1은 안 건드림. 상위=[`01-commit-plan.md`](01-commit-plan.md), C1=[`03-c1-code-design.md`](03-c1-code-design.md).

## 0. 핵심 결론
- ★**C1 델타 = 없음**: `history_size`는 이미 param 구동(init 1회 캐시)이고 extern struct의 **public 필드**라, 테스트가 `prm_set_integer_value(PRM_ID_HA_WRITESET_HISTORY_SIZE, N)`를 init 전에 부르면 주입 완료. 테스트 전용 setter·노출 변경 불필요.
- **접근자 API 이식 0**: PoC 테스트는 맵을 `.map.size()`와 `history_start` 읽기로만 접근(`.find`/`.latch`/순회 없음) → TBB accessor 변환 없음. 맵/락 내부는 writeset.c 안에 그대로.
- **주 기계적 편집 = tdes 필드 리네임**: `ws_hashes/ws_overflow/ws_dependency_seq` → `wset_*`. **`ws_stat_collect_ns` 삭제됨**(TEST-ONLY perf 제거) → A2/F1의 collect 타이밍은 테스트 내 `steady_clock`로 재측정. `wset_dependency_is_read=false` init 추가.
- **죽은 매크로**: `LOG_WSET_TX_LIMIT`/`LOG_WSET_HISTORY_CAP` 없어짐 → 두 캡 모두 런타임 `wset_History.history_size`. stress/bench의 매크로 참조를 런타임 값으로 교체.

## 1. PoC 테스트 이식 (correctness + stress)
- **test_writeset.cpp (correctness)**: 전 케이스 **유지** — `ws_`→`wset_` 리네임만 + 1곳 매크로→런타임캡 적응("per-tx limit flips overflow"). 유지 불변식: FNV/collation-string/FK-cast packing 동치, write_seq/read_seq 슬롯 의미, is_ref/dependency_is_read 선택, overflow 격하.
- **test_wset_bench.cpp**: ~그대로. collect 타이밍만 `ws_stat_collect_ns` 제거로 인해 in-test `steady_clock` 재측정.
- **test_wset_stress.cpp**: 매크로 치환 + collect 재측정 + **낡은 "단일 전역 latch" 전제 주석 재작성**(TBB 하에선 거짓). B4 hot-vs-disjoint가 이제 **실제 신호**가 됨. ★무거운 A4(수백만 키) 스윕은 config 테스트(작은 주입 캡)로 **결정적 대체** → 무거운 스윕 트림.
- **test_wset_common.hpp / test_main.cpp**: 헬퍼·Catch2 main, 리네임 반영.

## 2. 신규 동시성 벤치 (test_wset_concurrency.cpp)
TBB 전환의 핵심 가치 측정. **2×2 = {비충돌 disjoint / 행충돌 same-key} × {tbb 엔진 / latched 엔진}**:
- **비충돌**: 스레드마다 서로 다른 키 probe/flush → 전역 latch 제거로 얻는 **병렬 처리량**.
- **행충돌**: 모든 스레드가 **같은 키** → 같은키 경합 + accessor/rwlock 하 **정합성**.
- **A/B 기준선 방법 = 실제 probe/flush를 테스트 소유 `std::mutex` 하나로 감싸** 구 단일-latch 입도 재현. **C1 변경 0, 맵 중복구현 0.**
- 측정: ops/sec + p50/p99(스레드별 사전예약 latency 벡터). 정합성은 타이밍과 함께 inline 검증(map.size, probe로 write_seq/read_seq 단조).

## 3. 신규 config-사이징 테스트 (test_wset_config.cpp)
`ha_writeset_history_size`가 맵을 실제 제어하는지:
- (a) init이 param 캐시 → `history_size == 설정값`.
- (b) **CAP-clear**: `map.size()+count > history_size` → map.clear + `history_start` 점프.
- (c) **per-tx overflow**: 한 tx가 `wset_hashes.size() >= history_size` → `wset_overflow=true`, writeset 버려짐.
- **주입** = `prm_set_integer_value(PRM_ID_HA_WRITESET_HISTORY_SIZE, N)`를 initialize() 전에, `ws_history_guard(size)` ctor로 래핑. → 무거운 stress-A4를 작은 주입 캡으로 결정적 대체.

## 4. CMake / 빌드
- `unit_tests/writeset/CMakeLists.txt`: **TBB 추가** — `${TBB_INCLUDES}` 인클루드, `${TBB_LIBS}` 링크, `${TBB_TARGETS}` add_dependencies (cubrid/CMakeLists.txt:743-745 미러; 변수는 3rdparty/CMakeLists.txt:569-571에서 PARENT_SCOPE, unit_tests에서 보임). 신규 파일 2개(concurrency/config) 소스 추가.
- `unit_tests/CMakeLists.txt`: `option(UNIT_TEST_LOG_WRITESET)` + `add_subdirectory`.
- `cubrid` static lib 링크(packing/monitor 테스트와 동일) → **cub_server/OpenSSL 의존 없음**(그쪽 링크 블로커는 환경적, 이 테스트도 동일하게 영향받을 뿐 신규 도입 아님).

## 5. 실행자 포크 (기본값 지정)
1. **A/B 방법**: mutex-wrap vs 중복 참조구현 → **기본=mutex-wrap**(C1 변경 0).
2. **무거운 A4/near-CAP 스윕**: 유지 vs 트림 → **기본=트림**(config 테스트가 결정적으로 대체).
3. **낡은 단일-latch 주석**: → **재작성**(TBB 실제 동작으로).

## 6. 검증
-fsyntax-only / standalone 컴파일(test TU + writeset.o + TBB + Catch2). 테스트 타깃 빌드 시도(OpenSSL reconfigure에 걸릴 수 있음 — 시도·보고). 커밋 안 함, 리뷰어 검증 후.
