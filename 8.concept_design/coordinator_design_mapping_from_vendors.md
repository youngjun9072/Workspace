# 벤더 복제 연구 → CUBRID 코디네이터 설계 매핑

> 작성 2026-06-04 · 살아있는 매핑 문서(연구가 쌓이면 갱신)
> 용도: `reference/`의 벤더(MySQL·PostgreSQL) 연구 결과를 CUBRID 병렬 applylogdb 코디네이터 설계
>       (`parallel_applylogdb_coordinator_design.md`)로 잇는 대응 정리.
> 원칙: 벤더 reference 문서는 벤더 사실만(순수), CUBRID 대응·시사점은 여기로 모은다.

## 1. MySQL MTS 코디네이터 → CUBRID 코디네이터

근거 문서: `reference/mysql/05.mts_coordinator_dispatch.md`, `reference/mysql/03.parallel_replication_writeset_logical_clock.md`

MySQL MTS 분배는 CUBRID 병렬 applylogdb 코디네이터의 직접 청사진에 가깝다.

| MySQL MTS | CUBRID 코디네이터(설계) |
|---|---|
| 의존성: `last_committed ≤ LWM`이면 병렬 | 충돌 판단: changed class set 안 겹치면 병렬(1차안) |
| 의존성 정보를 **source가 binlog에 선계산**(WRITESET) | 장기안: repl log에 dependency metadata(write-set/conflict key) 추가 |
| **LWM(low water mark)** | "순서 정리 완료 지점 / committed_lsa" |
| worker 선택: 1tx=1worker, 부족하면 free worker 대기 | "전역 pending queue 재평가" 방식 |
| `replica_preserve_commit_order` | 순서 정리 단계에서 committed_lsa 순서대로 갱신 |
| barrier(gap·DDL) | schema/sysop/unknown = barrier |

**핵심 차이 — 의존성 판단의 단위·위치**
- MySQL: **row/key write set을 source가 선계산**(정밀·넓은 병렬).
- CUBRID 1차안: **class-level을 코디네이터(slave)가 판단**(보수적·구현 단순, repl log 포맷 변경 불필요).
- → CUBRID가 정밀 병렬을 원하면 MySQL처럼 **복제 로그에 의존성 정보(write-set/conflict key)를 심는 방향**으로 가야 한다 (← MySQL WL#9556).

**그대로 참고 가능한 점**
- "1tx=1worker"(한 트랜잭션의 모든 변경은 같은 worker)와 "가용 worker 없으면 먼저 비는 worker에 배정/대기"는 CUBRID worker 분배·pending queue 설계에 직접 참고.
- "병렬 실행 결정"과 "최종 commit 순서 보존"을 **분리**하는 구조(MySQL: LOGICAL_CLOCK ↔ SPCO)는 CUBRID에서도 "코디네이터 분배 ↔ 순서 정리 단계"로 동일하게 분리하는 것이 옳다.

### 1.2 추가 심화 주제 → CUBRID 시사점

근거 문서: `reference/mysql/06.replica_preserve_commit_order.md`, `07.binlog_group_commit_and_large_tx.md`, `10.initial_provisioning_clone_gtid.md`, `08.replication_break_cases.md`

- **commit 순서 보존(SPCO) → CUBRID 순서 정리 단계**: MySQL은 "병렬 실행 / 직렬 commit"을 ① 분배 시 worker를 **commit 순서 큐에 등록**(=source 순서) → ② commit 직전 **자기 차례(front)까지 대기** → ③ commit 후 **다음 worker를 grant** 로 구현한다. CUBRID의 "순서 정리 단계 / committed_lsa 순서 갱신"을 이 큐+차례대기+grant 구조로 설계하면 검증된 패턴을 그대로 쓸 수 있다. 또한 SPCO가 만드는 **인위적 의존성 데드락**(앞 트랜잭션이 commit 차례를 기다리는데 뒤 트랜잭션이 락을 쥠)을 MySQL은 wait-for 그래프 + worker 최저 weight victim + 자동 재시도로 푸는데, CUBRID도 "순서 대기 + 행 락"이 만나는 데드락을 동일하게 대비해야 한다.
- **group commit / 대형 트랜잭션 → CUBRID 병렬도·로그 설계**: MySQL은 source의 commit window(같은 group commit 묶음)가 replica 병렬도를 좌우한다 → CUBRID도 "source(master)가 복제 로그에 의존성/병렬 정보를 심을수록" replica 병렬이 넓어진다는 방향성 확인. 대형 트랜잭션은 (streaming 부재로) **단일 worker에 직렬 적용**되어 병렬화 불가 → CUBRID도 대형 트랜잭션은 병렬 이득이 제한된다는 점을 설계 가정에 반영.
- **초기 구축(Clone/GTID) → CUBRID 부트스트랩**: "물리 스냅샷으로 빠르게 적재 + 그 시점 좌표 함께 이전 + 좌표 이후를 로그 복제로 핸드오프"라는 패턴은 CUBRID 신규 slave 구축·재구축 설계에 참고. 좌표(GTID/위치) 일치가 핸드오프 정확성의 핵심.
- **깨짐 케이스 → CUBRID correctness 점검표**: SPCO off 순서 역전, errant 트랜잭션(로컬 쓰기), 무키/FK에서의 write-set 오판(부모보다 자식 먼저 적용), STATEMENT 비결정성 등은 CUBRID 코디네이터가 **"무엇을 잘못하면 조용히 깨지나"** 의 체크리스트. 특히 "행 식별 키가 없으면 병렬 판단이 부정확해진다"는 점은 class-level 판단의 보수성과 직접 연결.

## 2. PostgreSQL → CUBRID (요약 — 상세는 reference/pgsql)

근거 문서: `reference/pgsql/parallelism_in_ha.md`, `reference/pgsql/atomicity_ordering_break_cases.md`

- PostgreSQL은 **단일 구독 내 일반 트랜잭션을 직렬 적용**하고, 자동 의존성 기반 트랜잭션 병렬을 (아직) 하지 않는다 → CUBRID가 목표하는 "자동 의존성 병렬 + 전역 순서 보존"의 **직접 모델로는 부적합**. (그쪽은 MySQL 모델이 적합.)
- 다만 PostgreSQL에서 **참고할 원칙**:
  - "같은 트랜잭션 내 변경 순서 보존", "commit order 우선"의 보수적 correctness 우선.
  - **cross-subscription 깨짐 사례**(한 트랜잭션이 경계를 넘으면 원자성·순서 깨짐)는 "병렬 단위를 잘못 자르면 무엇이 깨지는가"의 반면교사 → CUBRID가 class/트랜잭션 경계를 자를 때 동일 위험 점검 필요.

### 2.1 EDB PGD(상용) Parallel Apply → CUBRID 시사점

근거 문서: `reference/pgsql/edb_pgd_parallel_apply.md`

community PG는 단일 구독 직렬이지만, **EDB의 상용 멀티마스터 제품 PGD(구 BDR)** 는 단일 구독 내 병렬 적용(Parallel Apply)을 제공한다. 즉 PG 생태계에서도 병렬 apply는 가능하되 **코어가 아닌 상용 레이어**에 있다. 설계 모델로서 PGD는 **MySQL과 다른 축**을 보여준다 — **의존성/충돌 판단을 source가 아니라 apply 측(writer)에서, 행 단위로** 한다.

| 항목 | MySQL MTS | EDB PGD | CUBRID 코디네이터(설계) 시사점 |
|---|---|---|---|
| 의존성 판단 **위치** | source(binlog) 선계산 | **apply 측 writer** | CUBRID가 "코디네이터(slave)에서 판단"을 택하므로, **이 판단 위치(apply 측)에 한해 PGD가 직접 선례**(전체 모델은 MySQL) |
| 판단 **단위** | row write-set 해시 | 행(tuple) | class-level(1차안) → row-level로 갈 때 PGD식 **tuple 대기** 채택 가능 |
| commit 순서 | 큐 front 차례까지 **선제 대기**(SPCO) | **선행 tuple-wait 예방 + 위반 시 롤백 backstop** | 둘 다 선제 순서화. CUBRID는 코디네이터 직렬화(예방) + 에러 시 재시도/`fail_counter` |
| 관측 지표 | — | `nprovisional/ntuple/ncommit_waits` | CUBRID 병렬 효율 관측 지표 설계에 참고 |

- **PGD는 "apply 측 판단"의 선례일 뿐, 전체 모델은 아니다.** PGD는 같은 행 선행 **tuple-wait로 순서를 예방**하고, commit 순서 위반 시 **롤백을 backstop**으로 둔다("each writer ensures the final commit doesn't violate origin commit order; 위반 시 error/rollback"). → **순수 낙관적이 아니라 예방 + 백스톱.**
  - **PGD를 전체 모델로 채택하지 않은 이유**: ① 토폴로지 — PGD=멀티마스터(노드 간 충돌해소·합의), CUBRID HA=단방향 master-slave → 불필요·부적합. ② 상용 폐쇄(MySQL은 오픈·소스 검증). ③ 구조는 MySQL의 "병렬↔순서 분리+coordinator"가 CUBRID와 1:1. PGD가 기여하는 건 **"apply 측 충돌 판단이 실동작한다"는 방증 한 가지**(CUBRID도 복제 로그에 의존성이 없어 apply 측 판단이 강제됨).
  - **CUBRID의 실제 실패 처리(현재)** 는 PGD식 롤백도 아니다 — master abort면 그 tx repl 리스트를 비우고, apply 에러면 재시도 후 실패는 `fail_counter`++. (코디네이터의 충돌 직렬화 = 디스패치 순서 제어로, 이 실패 처리와는 별개 층위)
- **대형 트랜잭션 옵션.** PGD는 transaction streaming으로 **커밋 전부터 writer에 병렬 적용**(실험적)한다 → CUBRID 대형 트랜잭션(병렬 이득이 제한되는 케이스)의 한 가지 돌파 방향.
- **한계 참고.** PGD도 **Group Commit과는 병렬 apply 비호환**, community PG에서는 writer lock_timeout 이슈 등 → "강한 동기/합의"와 "병렬 apply"는 상충하기 쉽다는 점을 CUBRID 동기화 수준 설계에 반영.

## 미해결 / 확인 필요
- CUBRID 복제 로그(repl log)의 성격(물리/논리, 엔진 종속성)과 현재 식별 단위(class/row) — CUBRID 코드로 확인 후 위 매핑의 적합도를 확정.
- class-level 충돌 판단이 MySQL WRITESET 대비 병렬성을 얼마나 잃는지(hot class 집중 시) — 실측·시뮬레이션 대상.
