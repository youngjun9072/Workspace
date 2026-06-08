# MySQL 복제 레퍼런스 — 읽는 순서 가이드

CUBRID 병렬 applylogdb 코디네이터 설계를 위해 MySQL 복제(특히 **병렬 적용**)를 조사한 문서 모음이다.
파일명 앞 번호가 **추천 읽는 순서**다. (CUBRID 매핑 문서는 상위 폴더에 있고 넘버링하지 않는다.)

## 먼저 — 사전 배경 (복제가 처음이면)

MySQL 문서들은 "물리 vs 논리", "WAL vs binlog" 개념을 전제한다. 낯설면 base부터:

- `../base/physical_vs_logical_replication.md` — 물리 vs 논리, 그리고 "왜 논리/왜 병렬"(§7)
- `../base/logging_wal_vs_redo_binlog.md` — MySQL은 왜 redo+binlog 두 로그인가

## 읽는 순서 (단계별)

### 1단계 — 큰 그림
- **`01.replication_overview.md`** — 복제 개념/방식(비동기·반동기·GR)/좌표(binlog·GTID)/**병렬화 지원·방법** 전반. 전체 지도.

### 2단계 — 로그·식별의 토대 (병렬의 재료)
- `02.binlog_vs_relaylog_format.md` — binlog ≡ relay log 형식 (replica가 받는 게 무엇인가)
- `03.parallel_replication_writeset_logical_clock.md` — **WRITESET(의존성 계산) vs LOGICAL_CLOCK(병렬 적용)** 이 source/replica 어디에 있는지 — 가벼운 primer
- **`04.writeset_concept.md`** — write set "그 자체" 심화(정의/생성/`last_committed` 2단 합성/예시). 03을 읽고 와야 매끄럽다.

### 3단계 — 병렬 적용 메커니즘 (핵심) ★
- **`05.mts_coordinator_dispatch.md`** — 코디네이터가 **언제(의존성) + 누구에게(worker)** 분배하나 (GAQ/LWM). ← CUBRID 코디네이터 직접 대응
- **`06.replica_preserve_commit_order.md`** — 병렬 실행하면서 **commit 순서 보존(SPCO)**. ← CUBRID "순서 정리 단계" 대응

### 4단계 — 성능·운영 맥락
- `07.binlog_group_commit_and_large_tx.md` — group commit이 병렬도에 주는 영향 + 대형 트랜잭션
- `08.replication_break_cases.md` — 무엇을 잘못하면 깨지나 (correctness 점검표)

### 5단계 — 부차 주제: 초기 구축 (코디네이터와 직접 무관)
- `09.initial_provisioning_guide.md` — **비전문가용 입문**(쉬움, 사전지식 포함)
- `10.initial_provisioning_clone_gtid.md` — 전문가용 상세(09 읽고 깊게)

### 심화 — 의존성·성능 실측
- `11.writeset_fk_dependency_tracking.md` — WRITESET이 FK를 포함해 의존 계산(+FK는 보수적 fallback/과직렬)
- `12.rpco_benchmark_and_lag_measuring.md` — RPCO ON/OFF 성능 실측(차이 1~3%)·워커 수가 지배·sub-linear(왜 N배 안 되나)·lag 측정 기준
- `13.mts_performance_real_measurements.md` — "워커 N개=N배"는 상한일 뿐, 프로덕션 실측은 1.1~2.1×(JFG/Percona). 롱 tx·소스 병렬성·durability가 좌우
- `14.dependency_tracking_version_history.md` — 병렬 복제 의존성 추적의 버전 연혁(5.6 DATABASE → 5.7 LOGICAL_CLOCK v1/v2 → 8.0 WRITESET 옵션 → 8.4 WRITESET 기본·COMMIT_ORDER 제거)

### 그다음 — CUBRID로 잇기
- `../coordinator_design_mapping_from_vendors.md` — 위 전부 → CUBRID 코디네이터 설계 매핑

## 한눈 흐름

```
배경(base) → 큰그림(01) → 로그·write set(02~04) → 분배·순서보존(05·06, 핵심)
          → 성능·깨짐(07·08) → 초기구축(09·10, 부차) → CUBRID 매핑
```

## 빠른 길 (코디네이터 목표 직행)

시간이 없으면 **01 → 04 → 05 → 06 → ../coordinator_design_mapping** 만 봐도 설계 입력은 잡힌다. (07·08은 보강, 09·10은 부차)
