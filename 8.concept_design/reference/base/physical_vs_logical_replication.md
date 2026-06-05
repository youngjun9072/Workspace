# 데이터베이스 HA에서의 물리복제(Physical Replication)와 논리복제(Logical Replication)

> 자료조사 문서 · 조사 시점 2026-06-02
> 용도: 복제 기본 컨셉 정리 (concept_design 레퍼런스 base)

## 요약
- **물리복제**는 WAL/Redo 같은 저수준 로그를 바이트·블록 단위로 그대로 전송·적용해, standby를 primary의 블록 단위 정확한 복사본으로 유지한다 [1][3].
- **논리복제**는 로그에서 행(row) 단위 데이터 변경(INSERT/UPDATE/DELETE)을 디코딩해 추출하고, 저장 형식과 독립적인 논리 변경분을 전송·적용한다 [2][3].
- 물리복제는 전체 DB 클러스터 단위로만 동작하고 동일 버전·동일 구조를 요구하며, 오버헤드가 낮아 HA·DR에 적합하다 [1][2].
- 논리복제는 테이블 단위 선택 복제·메이저 버전 간 복제·양방향/다방향 흐름이 가능해 유연하지만, 행 단위 적용으로 서버 부하가 더 클 수 있다 [2][5].
- 대표 구현: PostgreSQL(스트리밍 vs 로지컬), Oracle Data Guard(Physical standby의 Redo Apply vs Logical standby의 SQL Apply), MySQL(binlog 기반 row/statement) [1][2][3][4].

## 본문

### 1. 두 복제 방식의 기본 정의

**물리복제(Physical Replication)** 는 데이터베이스의 물리적 변경을 기록한 트랜잭션 로그(PostgreSQL의 WAL, Oracle의 Redo)를 바이트 단위·블록 주소 그대로 standby로 전송하여 적용하는 방식이다. 결과적으로 standby는 primary와 블록 단위로 일치하는 정확한 복사본이 된다 [1][3]. PostgreSQL 공식 문서는 이를 "warm/hot standby 서버가 WAL 레코드 스트림을 읽어 최신 상태를 유지하는" 방식으로 정의하며, 파일 기반 로그 시핑(file-based log shipping)과 스트리밍 복제(streaming replication) 두 가지 구현이 있다고 설명한다 [1].

**논리복제(Logical Replication)** 는 동일한 WAL/Redo에서 출발하되, 로그를 "논리적 데이터 변경분"으로 디코딩하여 행 단위 변경(어떤 행이 어떻게 바뀌었는가)을 전송하는 방식이다. PostgreSQL 문서는 논리복제를 "WAL로부터 논리적 데이터 수정 스트림을 구성"하는 것으로 정의한다 [1][2]. 전송되는 변경분은 기저 물리 저장 형식과 독립적이며, SQL 수준의 INSERT/UPDATE/DELETE만 반영한다 [2].

#### 보충: "블록 단위 재생(block-level replay)"이란

물리복제 설명에 자주 나오는 "블록 단위로 replay"가 무슨 뜻인지 풀어 둔다.

**블록(block) / 페이지(page)** 는 DB가 데이터를 디스크에 저장하는 고정 크기 단위다. PostgreSQL은 기본 8KB 페이지, Oracle은 기본 8KB 블록을 쓴다. 테이블의 각 행은 "몇 번 블록의, 몇 번째 위치(offset)"에 물리적으로 놓이며, 데이터 파일은 `블록 0, 블록 1, 블록 2 …` 가 줄지어 있는 형태다.

물리복제의 로그(WAL/Redo)는 SQL이 아니라 **"몇 번 블록의 어디를, 어떤 바이트로 바꿔라"** 라는 물리적 변경 기록이다. 예를 들어 primary에서 `INSERT INTO t VALUES (1,'foo')` 가 실행되면 WAL에는 대략 다음이 기록된다.

```text
[WAL 레코드]
  파일: t의 데이터 파일
  블록 번호: 17
  offset: 240
  기록할 바이트: <행 (1,'foo')의 바이너리 이미지>
  (인덱스 페이지 5번에도 키 삽입 …)
```

standby는 이 레코드를 받아 **그대로 자기 17번 블록의 240 위치에 똑같은 바이트를 써넣는다.** SQL을 파싱하거나 "어디에 넣을지"를 다시 계산하지 않고, 로그가 지시한 물리적 byte 변경을 해당 블록에 그대로 재현(replay)한다. 이것이 "블록 단위 재생"이다.

이 때문에 다음 특징이 따라온다.

- **결과가 primary와 byte 단위로 동일**해진다. 같은 행이 standby에서도 정확히 같은 블록·offset에 놓인다(논리복제는 standby가 빈 자리에 알아서 넣으므로 물리 위치가 다를 수 있다).
- **SQL 실행 비용이 없다.** 파싱·플랜·제약조건 검사 없이 바이트만 덮어쓰므로 빠르고 CPU 부담이 적다.
- 대신 **저장 포맷이 같아야** 한다. 블록 레이아웃은 엔진 버전에 종속이므로, 물리복제가 동일 버전을 요구하는 이유가 바로 이것이다.

**한 줄 비유:**

- **물리(블록 재생)**: "17번 페이지 240바이트부터 이 값으로 덮어써" → 디스크 이미지를 복사하듯 똑같이 만든다.
- **논리(행 적용 / SQL 재실행)**: "테이블 t에 (1,'foo') 한 행 넣어" → 어디에 넣을지는 standby가 알아서 결정한다.

#### 보충: WAL replay(물리) vs WAL decoding(논리)

물리·논리는 **같은 WAL에서 출발**하지만, 그 WAL을 **그대로 재생하느냐 vs 디코딩해 논리 변경으로 바꾸느냐**가 갈린다. (PostgreSQL 기준 서술이나 개념은 일반적이다.)

- **물리 = WAL replay**: WAL 레코드("몇 번 블록의 어디를 이 바이트로")를 **디코딩 없이 블록 단위로 그대로 재생**. source 쪽 추가 처리 없음.
- **논리 = WAL decoding**: 같은 WAL을 **logical decoding**으로 해석해 "테이블 T에 행 INSERT/UPDATE/DELETE" 같은 **논리 변경 이벤트**로 변환(재조립 버퍼 + 출력 플러그인). subscriber는 그 행 변경을 자기 테이블에 다시 적용.

| 항목 | 물리 (WAL replay) | 논리 (WAL decoding) |
|---|---|---|
| 전송 내용 | raw WAL(블록·바이트) | 디코딩된 행 변경 |
| source 처리 | 없음(그대로 전송) | 디코딩(재조립 + 필터) |
| 단위 | 클러스터 전체, 블록 | 테이블 선택, 행 |
| 적용 | 블록 그대로 덮어씀 | 행 변경 재적용(물리 위치 무관) |
| 버전 | 동일 버전 요구 | 메이저 버전 달라도 가능 |

**가장 중요한 두 차이:**

1. **순서** — WAL은 여러 트랜잭션이 **LSN(쓰여진) 순서로 뒤섞여** 있고 commit 순서가 아니다. 물리는 그 LSN 순서대로 그대로 replay하면 되지만(블록 redo라 맞음), 논리는 소비자가 "완결된 트랜잭션을 commit 순서로" 받아야 하므로 **디코딩이 트랜잭션별로 재조립하고 commit 순서로 재정렬**해 내보낸다.
2. **정보량** — 물리는 블록을 덮어쓰니 행 식별이 불필요하지만, 논리는 UPDATE/DELETE 시 **"어떤 행인가"(REPLICA IDENTITY = 키, FULL이면 old 행 전체)** 를 WAL에 더 남겨야 디코딩이 가능하다. 이것이 논리 복제용 로그가 더 커지는 이유다. 또 물리 WAL의 vacuum·인덱스 내부 변경·FPI 같은 **물리 전용 레코드는 논리 디코딩이 무시**하고 published 테이블 DML만 추출한다.

### 2. PostgreSQL: 스트리밍 복제 vs 로지컬 복제

PostgreSQL 공식 문서의 복제 솔루션 비교에 따르면 [1]:

- **WAL 로그 시핑 / 스트리밍 복제(물리)**: WAL 레코드 스트림을 읽어 standby를 유지한다. 동기/비동기 모두 가능하며, **전체 데이터베이스 서버 단위로만** 수행된다. primary 장애 시 standby가 거의 모든 데이터를 보유하므로 신속히 새 primary로 승격할 수 있다 [1]. 스트리밍 복제는 파일 기반 로그 시핑보다 더 실시간에 가깝고 hot standby(읽기 전용 쿼리)를 지원한다 [1][2].
- **로지컬 복제**: WAL에서 logical decoding으로 변경분을 추출하며, **테이블 단위 세분화 복제**가 가능하다 [1][2]. 변경분이 물리 저장 형식과 독립적이므로 **메이저 버전이 다른 서버 간 복제**가 가능하고(물리복제는 source/destination 동일 버전 요구), 변경을 publish 하는 서버가 동시에 다른 서버의 변경을 subscribe 할 수 있어 **다방향 데이터 흐름**을 허용한다 [2].

| 항목 | WAL 시핑(물리) | 로지컬 복제 |
|---|---|---|
| 복제 단위 | 전체 데이터베이스 클러스터 | 테이블 단위 선택 가능 [1] |
| 다중 primary | 불가 | 가능 [1] |
| Hot standby(읽기) | 지원 | 지원 [1] |
| 데이터 손실 위험 | 동기 모드 시 없음 | 비동기 모드 시 존재 [1] |
| 버전 간 복제 | 동일 버전 요구 | 메이저 버전 간 가능 [2] |

**표 해설 (각 항목이 실무에서 의미하는 것):**

- **복제 단위** — "한 번에 무엇을 복제하느냐"의 범위.
  물리는 **서버(클러스터) 전체를 통째로** 복제한다. 특정 테이블 하나만 골라서 복제하는 게 불가능하고, 시스템 카탈로그까지 전부 따라간다.
  논리는 **"이 테이블만, 이 DB의 일부만"** 처럼 골라서 복제할 수 있다. 예: 주문 테이블만 분석 서버로 보내기.

- **다중 primary** — "양쪽에서 동시에 쓰기가 가능한가".
  물리는 standby가 **읽기 전용**이라 한쪽(primary)에서만 쓰기가 일어난다. 진짜 사본이므로 standby에 직접 쓰면 사본 일관성이 깨진다.
  논리는 A→B로 보내면서 동시에 B→A도 받을 수 있어, **양쪽이 서로 쓰기를 주고받는 구성(다방향)** 이 가능하다.

- **Hot standby(읽기)** — "복제를 적용하는 중에도 standby에서 SELECT 조회가 되는가".
  둘 다 **가능**하다. 즉 복제본을 단순 대기용으로만 두지 않고 **읽기 부하 분산(리포팅·조회용 복제본)** 으로 쓸 수 있다.

- **데이터 손실 위험** — "primary가 갑자기 죽었을 때 아직 안 넘어간 변경이 사라지나".
  **동기(synchronous) 모드**면 primary가 standby의 수신을 확인한 뒤에 커밋하므로 **손실이 없다**. 대신 그만큼 커밋이 느려진다.
  **비동기(asynchronous) 모드**면 일단 primary에서 커밋하고 나중에 따라 보내므로, 장애 순간 **아직 안 보낸 변경은 유실**될 수 있다. (이건 물리/논리 공통 트레이드오프이며, 표의 표기는 PostgreSQL 문서가 각 방식에서 대표적으로 쓰는 모드를 기준으로 한 것 [1].)

- **버전 간 복제** — "primary와 standby의 DB 엔진 버전이 달라도 되는가".
  물리는 바이트·블록을 그대로 복사하므로 저장 포맷이 같아야 한다 → **양쪽 메이저 버전이 동일해야** 한다. 그래서 **무중단 메이저 업그레이드에는 부적합**.
  논리는 변경분이 저장 포맷과 무관한 논리 수준이라 **버전이 달라도 복제**된다 → 신버전 standby를 띄워 데이터를 흘려보낸 뒤 전환하는 **무중단 업그레이드/마이그레이션**에 쓸 수 있다 [2].

### 3. Oracle Data Guard: Physical Standby vs Logical Standby

Oracle Data Guard는 물리/논리 복제 구분의 대표적 사례다.

- **Physical Standby (Redo Apply)**: primary의 블록 단위 정확한 복사본을 유지한다. Redo Apply는 모든 SQL 수준 코드 계층을 우회하는 저수준 복구(recovery) 메커니즘으로 변경을 적용하기 때문에, standby를 최신 상태로 유지하는 가장 효율적인 방식으로 설명된다 [3].
- **Logical Standby (SQL Apply)**: 최초에는 primary와 동일한 복사본으로 생성되지만 이후 구조를 다르게 가져갈 수 있다. Data Guard가 archived/standby redo log의 정보를 **SQL 문으로 변환**한 뒤 logical standby에서 실행하여 갱신한다. 이 방식 덕분에 logical standby는 변경 적용과 동시에 쿼리·리포팅 용도로 읽기 접근이 가능하다 [3].

즉 물리 standby는 Redo Apply(저수준 복구), 논리 standby는 SQL Apply(재구성된 SQL 실행)라는 점이 핵심 차이다 [3].

### 4. MySQL: Binary Log 기반 복제 포맷

MySQL 복제는 source가 데이터 변경을 binary log(binlog)에 기록하면 replica가 이를 받아 적용하는 비동기·pull 기반 구조다 [4]. 복제 포맷은 다음 세 가지를 지원한다 [4]:

- **Statement-Based Replication(SBR)**: source가 실제 SQL 문을 binlog에 기록하고, replica가 그 SQL을 재실행한다 (논리복제에 해당하는 성격).
- **Row-Based Replication(RBR)**: SQL 문 대신 어떤 행이 어떻게 바뀌었는지를 기록한다. 비결정적(non-deterministic) 함수 문제를 제거해 가장 안전·견고한 방식으로 평가되며, **MySQL 8.0의 기본값**이다 [4].
- **Mixed**: 상황에 따라 SBR/RBR을 자동 선택.

MySQL의 binlog 기반 복제는 행/문장 수준의 논리적 변경을 전송한다는 점에서 논리복제 계열에 가깝다 [4][5]. (블록 단위 물리복제와는 성격이 다르다.)

**MySQL에는 (지속) 물리복제가 없다.** PostgreSQL의 WAL 스트리밍이나 Oracle의 Redo Apply처럼 **블록 단위로 계속 흘려보내는 네이티브 물리복제 방식이 MySQL에는 존재하지 않는다** — MySQL의 지속 복제는 전적으로 binlog 기반(논리)이다 [4]. 물리복제에 가장 가까운 기능은 **Clone Plugin(MySQL 8.0.17+)** 으로, InnoDB의 데이터(스키마·테이블·테이블스페이스·데이터 딕셔너리)를 **물리 스냅샷**으로 복사한다 [6]. 다만 이는 다음과 같은 성격이다 [6]:

- 용도는 **지속 복제가 아니라 replica 초기 구축(provisioning)** 이다. 대량 트랜잭션을 처음부터 재생하는 것보다 훨씬 빠르게 새 replica/Group Replication 멤버를 만든다.
- 클론 시 복제 좌표(binlog 위치·GTID)를 함께 넘겨, 클론이 끝난 지점부터 **이후에는 다시 binlog(논리) 복제로 이어간다**. 즉 "물리 스냅샷으로 초기화 → 논리로 지속 복제"라는 핸드오프 구조다.
- binlog·relay log 파일 자체는 클론으로 복사되지 않는다.

요약하면 MySQL은 **지속 복제 = 논리(binlog), 물리 = 초기 구축용 Clone Plugin뿐**이라고 볼 수 있다 [4][6]. (블록 단위 연속 물리복제를 OS 레벨에서 흉내 내려면 DRBD 같은 외부 솔루션을 쓰지만, 이는 MySQL 자체 기능이 아니다.)

### 5. 적용 방식의 갈림: 물리 replay vs 논리(SQL 재실행 / 행 직접 적용)

앞 절들의 벤더 사례를 "변경분을 standby에 **어떻게 적용하는가**" 기준으로 한 곳에 모으면 다음과 같다. 특히 논리복제는 적용 단계에서 두 갈래로 갈린다는 점이 핵심이다.

- **물리복제** = 저수준 로그(WAL/Redo)를 받아 **블록 단위로 replay** → primary와 바이트 단위로 동일한 데이터 파일을 재현한다. SQL 파싱·플랜이 전혀 없다 [1][3].
- **논리복제** = 로그에서 **행 단위 변경분을 디코딩**해 전송한 뒤, 적용 시 다음 두 방식 중 하나를 쓴다 [2][3][4]:
  - **(a) SQL 재실행** — 원본/재구성된 SQL 문을 standby에서 다시 실행.
  - **(b) 행 직접 적용** — SQL 파싱·플랜 없이 "어떤 행이 어떻게 바뀌었나"(행 이미지)를 직접 반영.

| 적용 방식 | 전송·적용 대상 | "SQL 재실행"인가 | 대표 구현 |
|---|---|---|---|
| 물리 replay | 저수준 로그(WAL/Redo)를 블록 단위 재생 | 아니오 (블록 복구) | PostgreSQL 스트리밍, Oracle Physical Standby(Redo Apply) [1][3] |
| 논리 — SQL 재실행 | SQL 문 (원본 또는 redo→SQL 재구성) | **예** | MySQL SBR, Oracle Logical Standby(SQL Apply) [3][4] |
| 논리 — 행 직접 적용 | 행 단위 변경분(행 이미지) | 아니오 (행 변경 직접 반영) | MySQL RBR, PostgreSQL 로지컬 복제 [2][4] |

일반적으로 행 직접 적용(RBR)은 SQL 재실행 대비 **비결정적(non-deterministic) 함수 문제가 없어 더 안전·견고**하다고 평가되며, MySQL 8.0이 RBR을 기본값으로 채택한 이유이기도 하다 [4]. 병렬 applylogdb 설계 시, CUBRID가 (a) SQL 재실행에 해당하는지 (b) 행 직접 적용에 해당하는지가 병렬화 단위·충돌 처리 설계의 갈림길이 된다(분류는 CUBRID 코드/문서 확인 필요).

### 6. HA 관점에서의 비교

- **물리복제**: 변경을 논리 수준에서 파싱할 필요가 없어 CPU·메모리 오버헤드가 낮고 성능이 좋으며, primary와 거의 즉각적인 데이터 일관성을 유지한다. 따라서 읽기 전용 복제본 생성, HA, DR(재해 복구)처럼 "primary의 정확한 사본"이 필요한 시나리오에 적합하다 [5]. 단, 상당한 디스크 I/O를 유발해 source·target 양쪽 성능에 영향을 줄 수 있다 [5].
- **논리복제**: 데이터 종류·구조 처리에서 유연하고, 특정 테이블·일부만 복제하는 세분화된 제어가 가능하다. 반면 행 기반 적용으로 서버 부하가 더 클 수 있다 [5].

### 7. "물리가 더 빠른데 왜 논리를 택하고, 논리에 병렬을 투자하나"

**전제 교정 — 물리가 "레코드당 싸다"는 맞지만 "항상 빠르다"는 아니다.**
- 물리복제(WAL 블록 replay)는 SQL 파싱·플랜이 없어 레코드당 비용이 낮지만, 보통 **단일 프로세스 순차 재생**이다(예: PostgreSQL startup process). 멀티코어 primary가 바쁘게 쓰면 **단일 스레드 apply가 못 따라가** lag이 쌓일 수 있다.
- 또한 **경직**하다: 전체 클러스터 통째로만, 동일 메이저 버전·동일 페이지 포맷, standby는 읽기 전용. 선택·변형이 불가.

**왜 논리를 택하나 — 속도가 아니라 "물리가 못 하는 유연성" 때문.**
물리가 구조적으로 불가능한 것들이 논리의 채택 이유다:
- 선택 복제(특정 테이블/행/컬럼만)
- 버전 간 복제 / 무중단 메이저 업그레이드(구→신 버전 흘려보내고 전환)
- 이기종 복제(다른 OS/아키텍처, 다른 DBMS로 CDC)
- 쓰기 가능·다른 스키마·다른 인덱스를 가진 replica
- 통합(fan-in)/멀티소스, 양방향/멀티마스터
- CDC·데이터 파이프라인(Kafka·검색엔진·캐시로 변경 스트리밍)

→ 무중단 업그레이드·마이그레이션·데이터 통합·부분 복제 같은 현대 운영 수요가 **논리를 강제**한다. (MySQL은 애초에 네이티브 물리 지속복제가 없어 binlog 논리만 — `logging_wal_vs_redo_binlog.md` 참조.)

**왜 논리에 "병렬"을 투자하나.**
- 논리는 **레코드당 비싸다**(행 단위 재적용 + 인덱스·제약 처리 + 디코딩). 단일 워커면 물리보다 느리다.
- → **병렬로 단일 스레드 한계를 넘어선다.** 독립 트랜잭션을 여러 워커가 동시 적용하면 멀티코어에서 물리의 단일 스레드 재생을 따라잡거나 추월할 수 있다.
- **병렬화 난이도 차이**: 물리(블록 replay)는 LSN 순서·페이지 종속에 강하게 묶여 병렬화가 어렵다(PostgreSQL도 parallel recovery는 제안 단계, 코어 미반영). 반면 논리는 **트랜잭션/행 단위**라 "어떤 트랜잭션이 독립인가"를 write-set/의존성으로 판단하기 쉬워 병렬화가 tractable하다(MySQL WRITESET/LOGICAL_CLOCK). → 엔지니어링 투자가 "병렬 논리 apply"로 쏠리는 이유.

**트레이드오프 정리**

| 항목 | 물리 | 논리 |
|---|---|---|
| 레코드당 비용 | 낮음 | 높음 |
| 적용 병렬화 | 어려움(단일 스레드 재생) | 상대적으로 쉬움(트랜잭션 단위) |
| 유연성 | 거의 없음(통째·동일버전·읽기전용) | 큼(선택·버전간·이기종·쓰기·CDC) |
| 적합 시나리오 | 동일 핫스탠바이(HA/DR) | 업그레이드·통합·부분복제·멀티마스터 |

> 결론: 물리는 "동일한 핫스탠바이를 싸게" 만드는 데 최적이나 **경직 + 단일 스레드**다. 현실 수요의 상당수는 물리가 *못 하는* 유연성(논리)을 요구하고, 논리의 약점인 적용 속도는 **병렬화로 메운다** — 그래서 "논리 채택 + 논리 병렬 투자"가 대세다. "물리가 더 빠른데 왜?"의 답은 **속도보다 유연성이 요구이고, 그 속도 격차는 병렬로 닫기 때문**이다.

> 근거: 물리=단일 프로세스 재생·parallel recovery 제안 단계는 `reference/pgsql/parallelism_in_ha.md`(소스 확인), MySQL 물리 부재는 `logging_wal_vs_redo_binlog.md`, 논리 병렬(WRITESET/LOGICAL_CLOCK)은 `reference/mysql/*`. "왜 택하나"의 유연성 항목은 [1][2] 기반 + 일반 업계 관행에서의 종합(추론 포함).

## 추론 / 유추
- CUBRID HA의 `applylogdb`가 트랜잭션 로그를 읽어 replica에 반영하는 구조라면, 로그에서 변경을 추출해 적용한다는 점에서 논리복제(특히 Oracle SQL Apply / MySQL binlog 적용) 계열과 개념적으로 유사한 위치에 있을 가능성이 높다 (← [3], [4]). 단, 정확한 분류는 CUBRID 코드/문서 확인이 필요하다.
- 병렬 applylogdb를 설계할 때, 논리복제 계열은 "행 단위 적용 부하가 크다"는 일반적 단점([5])이 병렬화의 주요 동기가 될 수 있다 (← [5]). 이 역시 별도 코드 분석으로 검증 대상이다.

## 미해결 / 자료 부족
- CUBRID HA의 복제가 물리/논리 중 어디에 해당하는지는 본 자료(외부 벤더 문서)만으로 단정할 수 없다 — CUBRID 공식 문서/소스 분석으로 확인 필요.
- 동기/비동기, 반동기(semi-synchronous) 복제의 세부 일관성 모델, 복제 슬롯(replication slot)·logical decoding 플러그인 등 구현 세부는 이 문서 범위 밖이며 별도 조사 필요.
- 각 벤더의 정확한 성능 수치(지연·처리량 벤치마크)는 1·2순위에서 확정값을 확보하지 못해 본문에 단정값으로 기재하지 않음.

## References
[1] PostgreSQL Global Development Group. "26.1. Comparison of Different Solutions". PostgreSQL 18 Documentation, 2025. https://www.postgresql.org/docs/current/different-replication-solutions.html

[2] PostgreSQL Global Development Group. "Streaming Replication / Logical Replication". PostgreSQL 18 Documentation, 2025. https://www.postgresql.org/docs/current/protocol-replication.html

[3] Oracle. "Managing Physical and Snapshot Standby Databases" / "Creating a Logical Standby Database" / "Log Apply Services". Oracle Database Data Guard Documentation, 2024. https://docs.oracle.com/en/database/oracle/oracle-database/19/sbydb/managing-oracle-data-guard-physical-standby-databases.html

[4] Oracle / MySQL. "19.2.1 Replication Formats". MySQL 8.0 Reference Manual, 2025. https://dev.mysql.com/doc/refman/8.0/en/replication-formats.html

[5] DBPLUS Better Performance. "The Replication Dichotomy: Logical vs Physical Replication". DBPLUS Blog, 2024-07-18. https://dbplus.tech/en/2024/07/18/the-replication-dichotomy-logical-vs-physical-replication/

[6] Oracle / MySQL. "7.6.7 The Clone Plugin" / "7.6.7.7 Cloning for Replication". MySQL 8.0 Reference Manual, 2025. https://dev.mysql.com/doc/refman/8.0/en/clone-plugin.html
