# PostgreSQL HA(복제)에서의 병렬화

> 자료조사 문서 · 조사 시점 2026-06-02
> 출처: PostgreSQL 공식 문서(1순위) + PostgreSQL 핵심 개발자 블로그/CYBERTEC(2순위)
> 용도: 병렬 적용 컨셉 레퍼런스 (concept_design reference/pgsql)

## 요약
- **물리(스트리밍) 복제의 WAL 재생은 단일 스레드(startup process)** 다. apply 자체를 여러 스레드로 병렬화하지 않는다 [5].
- `recovery_prefetch`(PG15+)는 재생을 병렬화하는 게 아니라, 참조될 블록을 미리 **I/O 프리페치**해 단일 재생 프로세스의 디스크 대기를 줄이는 기능이다 [1][5].
- **논리 복제의 병렬성은 세 갈래**다: ① 구독(subscription)마다 apply worker 1개(여러 구독 → 병렬), ② 초기 동기화 tablesync worker, ③ large in-progress transaction의 parallel apply worker [2][3][4].
- **단일 구독 안의 일반 트랜잭션은 직렬** — leader apply worker가 publisher commit 순서대로 적용한다. MySQL식 "독립 트랜잭션 의존성 병렬 dispatch"가 아니다 [3][7].
- `streaming=parallel`(large tx 병렬 apply)은 **PG16 도입, PG18에서 기본값**이 되었다 [3][6].

> **용어 주의 — "streaming"이 두 가지 뜻으로 쓰인다.**
> 1. **물리 "스트리밍 복제(streaming replication)"** = WAL을 standby로 실시간 전송해 블록 단위로 재생하는 **물리복제 방식의 이름**. (단일 스레드 재생, 위 2절)
> 2. **논리 구독 옵션 `streaming = parallel`** = 진행 중(in-progress) **대형 트랜잭션을 commit 전에 stream 단위로 보내** parallel apply worker가 적용하게 하는 **논리복제 옵션**. (위 4·5절)
>
> 둘은 이름만 같을 뿐 서로 무관하다. 본 문서에서 "스트리밍 복제"는 1번(물리), `streaming=parallel`/`streaming` 옵션은 2번(논리)을 가리킨다.

## 본문

### 1. 큰 그림

PostgreSQL HA의 병렬화는 "물리"와 "논리"가 크게 다르다.

- **물리(스트리밍) 복제**: standby가 WAL을 받아 **단일 프로세스로 순차 재생**한다. 병렬 재생은 코어에 없다(제안만 존재) [5].
- **논리 복제**: 몇몇 지점에서 worker를 여러 개 띄워 병렬화하지만, **단일 구독 안의 일반 트랜잭션 적용은 여전히 직렬**이다 [3].

구성·아키텍처 자체가 다르므로, 먼저 둘을 한눈에 대비한다.

| 구분 | 물리(스트리밍) 복제 | 논리 복제 |
|---|---|---|
| 보내는 쪽 | **primary** (원본) | **publisher** |
| 받는 쪽 | **standby** (복제본) | **subscriber** |
| 셋업 방법 | 베이스 백업(`pg_basebackup`) + `standby.signal` + `primary_conninfo` | SQL DDL: `CREATE PUBLICATION` / `CREATE SUBSCRIPTION` [3] |
| pub/sub 객체 | **없음** | 있음 |
| 전제 `wal_level` | `replica` 이상 (publisher측) [1] | publisher가 `logical` [1] |
| 복제 범위 | 인스턴스(클러스터) 전체, 블록 단위 | 선택한 테이블, 행 단위 |
| 전송 경로 | primary `walsender` → standby `walreceiver` | publisher `walsender`(logical decoding) → subscriber `apply worker` [9] |
| 적용 주체 | standby `startup process` (replay) | subscriber `apply worker` |
| 적용 병렬성 | **없음**(단일 스레드 재생) [5] | 제한적 병렬(아래 4·5절) [3] |
| 방향 | 받는 쪽(standby)이 pull | 받는 쪽(subscriber)이 pull |

> 둘 다 **받는 쪽이 접속해 끌어오는(pull)** 구조이지만, 물리는 pub/sub 객체 없이 **인스턴스 구성**으로, 논리는 **SQL DDL**로 셋업한다는 점이 핵심 차이다.

### 2. 물리(스트리밍) 복제의 병렬성 — 사실상 없음

#### 물리복제의 두 구현: 로그 배송과 스트리밍

물리복제(WAL 기반)는 WAL을 standby로 전달하는 **두 가지 구현**이 있고, 둘 다 standby에서 WAL을 블록 단위로 replay한다는 점은 같다. 공식 문서는 WAL shipping이 file-based log shipping 또는 streaming replication, 또는 **둘의 조합**으로 구현된다고 설명한다 [10].

| 구분 | 파일 기반 로그 배송(file-based log shipping) | 스트리밍 복제(streaming replication) |
|---|---|---|
| 전달 단위 | 완성된 WAL 세그먼트 파일(기본 16MB) | WAL 레코드를 연속 전송 |
| 전달 방법 | primary `archive_command`로 보관 → standby `restore_command`로 가져와 적용 | standby `walreceiver`가 primary `walsender`에 접속해 실시간 수신 |
| 지연 | 큼(세그먼트가 차야 전달) | near real-time |
| standby 적용 | WAL replay (블록 단위) | WAL replay (블록 단위) — 동일 |

- **조합**도 흔하다: 평상시 스트리밍으로 받다가, 끊겨 밀린 구간은 아카이브(파일 배송)에서 따라잡는(catch-up) 식 [10].
- **병렬성 관점에서는 둘이 동일**하다 — 어느 쪽이든 최종 적용은 standby의 단일 startup process가 순차 replay하므로, 아래 단일 스레드 논의는 두 구현 모두에 적용된다. (이 절은 near real-time인 스트리밍을 기준으로 서술한다.)

#### 단일 스레드 재생

standby의 WAL 재생은 **startup process 한 개**가 담당한다. WAL 레코드를 순서대로 읽어 블록에 적용하며, 이 적용을 여러 스레드로 나누지 않는다 [5].

> **주석 — startup process란**
> PostgreSQL의 startup process는 postmaster(부모)가 띄우는 **보조 프로세스(auxiliary process)** 중 하나로, **WAL 재생(recovery/replay)을 담당하는 단일 프로세스**다. 이 문서에서 "물리복제 재생은 단일 프로세스"라고 할 때 그 주체가 이것이다.
> - **crash recovery**: 모든 서버 시작 시, 마지막 체크포인트 이후의 WAL을 재생해 데이터 파일을 일관 상태로 복구한다. 끝나면 primary는 정상 운영으로 전환되고 startup process는 종료된다.
> - **standby의 지속 재생**: standby(또는 archive recovery/PITR)에서는 종료되지 않고 **계속 WAL을 재생**한다. 이게 본 절에서 말하는 "물리복제 재생"이며, `PerformWalRecovery()` 단일 redo 루프를 도는 주체다.
> - `ps`에서는 `postgres: startup recovering 0000000100000...` 로 보인다. (수신측 `walreceiver`와 짝: walreceiver=받기, startup=적용하기, 둘 다 단일 프로세스.)

PG15부터 추가된 `recovery_prefetch`는 재생 자체를 병렬화하지 않는다. 재생 프로세스가 WAL 스트림을 앞서 읽어(read-ahead) 곧 참조될 블록 번호를 디코딩하고, 캐시에 없으면 OS에 **미리 읽어두라고 지시**하는 I/O 프리페치다. 모든 작업은 여전히 startup process 안에서 일어나므로 병렬성이 생기는 것은 아니며, 다만 디스크 read가 이전 레코드 처리 중에 미리 진행되도록 해 대기를 줄인다 [1][5]. read-ahead 거리와 동시 I/O 양은 `wal_decode_buffer_size`(기본 512kB), `maintenance_io_concurrency`로 조절한다 [1][5].

병렬 재생(parallel recovery/replay)은 PostgreSQL wiki에 **설계 제안**으로 존재한다(transaction worker / block worker로 분리하는 구조). 다만 이는 제안 단계이고 **코어에 반영된 기능이 아니다** [6].

#### 수신측도 단일 — walreceiver (PG 17.10 소스 직접 확인)

재생(replay)뿐 아니라 **WAL을 primary에서 끌어오는 수신측도 단일 프로세스**다. standby는 보조 프로세스 `walreceiver` **한 개**가 `primary_conninfo`로 primary에 접속해 WAL을 받는다 (PG 17.10 로컬 소스 직접 확인):

- 진입점 `WalReceiverMain()` — `walreceiver.c:183`. `MyBackendType = B_WAL_RECEIVER`로 보조 프로세스 테이블에 **단일** 등록(`launch_backend.c:206`).
- 기동도 1개만: startup 프로세스가 `RequestXLogStreaming(..., PrimaryConnInfo, ...)`로 요청(`xlogrecovery.c:3872`) → walreceiver가 그 conninfo로 `walrcv_connect()` 접속(`walreceiver.c:301`).
- 수신도 단일 루프: 한 프로세스가 `for(;;)` 안에서 `walrcv_receive()`를 반복(`walreceiver.c:475, 509`). 병렬/다중 walreceiver를 만드는 코드·파라미터는 소스에 없고, 복제 경로에 `pthread_create`도 전무하다.

즉 물리복제는 **"단일 프로세스 수신(walreceiver) → 단일 프로세스 재생(startup)"** 으로 양쪽 모두 병렬화되어 있지 않다. (PostgreSQL은 스레드가 아니라 프로세스 모델이므로 "단일 스레드"보다 "단일 프로세스"가 더 정확한 표현이다.)

> **주석 — redo는 standby(복제본)의 일이다 (마스터 아님)**
> startup process는 마스터·standby 양쪽에 다 있지만 **역할이 다르다**. 마스터에선 부팅 시 **crash recovery만** 하고 종료하며, 평상시엔 WAL을 **생성**(forward write)할 뿐 redo하지 않는다. 반면 standby에선 startup process가 **상주하며 들어오는 WAL을 끊임없이 redo**한다 — 이게 물리복제 apply다. (`StandbyMode`는 startup process에서만 유효; standby 모드에서만 walreceiver 스트리밍이 시작됨 — xlogrecovery.c.)
>
> ```text
> [마스터 primary]                          [복제본 standby]
> 백엔드가 변경 → WAL 기록(생성)
>    │
> walsender가 WAL 읽어 전송  ───────────►  walreceiver(수신, 단일 프로세스)
>                                               │ WAL을 디스크에 기록
>                                               ▼
>                                          startup process(redo, 단일 프로세스)
>                                               │ WAL 읽어 블록에 적용 ← redo는 여기!
>                                               ▼
>                                          복제본 데이터 파일 갱신
> ```
>
> 즉 redo(블록 적용)는 **받는 쪽(standby)** 의 일이고, 마스터는 WAL을 *만들어 보내는* 쪽이라 평상시 redo를 하지 않는다.

#### "단일 스레드 재생"임을 어떻게 아는가 (근거)

"없다"는 단정의 근거는 한 출처가 아니라 서로 다른 각도의 증거가 같은 결론을 가리킨다는 데 있다.

1. **소스 코드 (직접 증거, 가장 확정적)** — WAL 재생의 실제 루프는 `src/backend/access/transam/xlogrecovery.c`의 `PerformWalRecovery()` 함수 하나다. 이 함수가 redo 루프를 돌며 WAL 레코드를 순차적으로 읽어 rmgr별 redo 루틴을 호출한다. 레코드를 여러 worker로 나눠 보내는 dispatch 코드가 없는, startup process의 단일 루프다 [8]. **(PG 17.10 로컬 소스 직접 확인: `PerformWalRecovery()` xlogrecovery.c:1662, 주석 "main redo apply loop" :1758–1846 구간이 레코드마다 `ApplyWalRecord()`(:1915)를 호출하는 단일 루프이며, redo 루프 내 parallel/worker dispatch 코드 없음.)**
2. **프로세스 모델 (경험적 관찰)** — 실행 중인 standby에서 `ps`로 보면 재생 worker가 여러 개 뜨지 않고 `postgres: startup recovering ...` 프로세스 1개만 보인다. 무거운 복제 지연 시 CPU도 코어 하나만 풀로 돌고 나머지는 논다(논리 복제에서 apply worker가 여러 개 뜨는 것과 대조).
3. **`recovery_prefetch`의 설계 방향 (정황 증거)** — 이 기능이 "재생을 병렬화"가 아니라 "단일 재생 프로세스의 I/O 대기를 미리 프리페치로 가린다" 방향으로 만들어졌다는 것 자체가 재생이 단일 스레드임을 전제로 한다 [1][5].
4. **Parallel Recovery가 아직 *제안*이라는 사실 (부정 증거)** — 이미 병렬이면 "병렬로 만들자"는 제안이 존재할 이유가 없다. 제안 문서는 "현재 recovery는 startup process에서 수행된다"고 명시한다 [6].

| 증거 | 성격 | 강도 |
|---|---|---|
| `PerformWalRecovery()` 단일 redo 루프 (소스) | 직접 증거 | 확정 [8] · PG 17.10 로컬 소스 직접 확인 |
| `walreceiver` 단일 프로세스 수신(`WalReceiverMain`, `primary_conninfo`) (소스) | 직접 증거 | PG 17.10 로컬 소스 직접 확인 |
| standby `ps`에 startup 프로세스 1개 / 코어 1개만 사용 | 경험적 관찰 | 재현 가능 |
| `recovery_prefetch`가 병렬화가 아닌 I/O 프리페치로 설계됨 | 정황 증거 | 보조 [1] |
| Parallel Recovery가 아직 제안 단계 | 부정 증거 | 보조 [6] |

### 3. 논리 복제 pub-sub 모델 기초

PostgreSQL 논리 복제는 publish/subscribe(발행/구독) 모델이며, 병렬성도 이 구조 위에서 나온다 [9].

- **publisher(발행자)**: 변경을 내보내는 서버. `CREATE PUBLICATION`으로 어떤 테이블의 변경을 발행할지 정의한다 [3][9].
- **subscriber(구독자)**: 변경을 받는 서버. `CREATE SUBSCRIPTION`으로 어떤 publication을 구독할지 정의한다 [3][9].
- **logical decoding / pgoutput**: publisher는 WAL을 logical decoding으로 해석하고, 기본 출력 플러그인 `pgoutput`이 publication 기준으로 변경을 필터링해 논리적 change stream을 만든다 [9].
- **walsender → apply worker**: publisher의 walsender 프로세스가 이 stream을 전송하고, subscriber의 apply worker가 받아 로컬 테이블에 적용한다 [9].
- **replication slot**: subscriber가 어디까지 받았는지를 publisher 측에서 보존해, 끊겼다 재개해도 빠진 변경 없이 이어받게 한다 [9].

> **용어 — 역할(role) vs 객체(object)**
> `publisher`/`subscriber`는 **객체가 아니라 서버(노드)의 역할**이다. 실제 데이터베이스 객체는 **`PUBLICATION`**(발행 명세, publisher의 `pg_publication`)과 **`SUBSCRIPTION`**(구독 명세+접속 정보, subscriber의 `pg_subscription`)이다.
> - `CREATE PUBLICATION` 한 서버 = publisher 역할 / `CREATE SUBSCRIPTION` 한 서버 = subscriber 역할.
> - 한 서버가 둘 다 가지면 publisher이자 subscriber(캐스케이딩/양방향) — 역할은 배타적이지 않다.
> - **그래서 "테이블별 병렬화 = subscriber를 여러 개"가 아니라, 한 subscriber 노드에 `SUBSCRIPTION` 객체를 여러 개** 두는 것이다(각 구독 = apply worker 1개 → 병렬, 4절 ①). 병렬 단위는 노드가 아니라 **SUBSCRIPTION 객체 수**다.

물리 복제와의 핵심 차이: 물리는 인스턴스(클러스터) 전체를 블록 단위로 복제하지만, 논리는 **테이블 단위로 선택**해 행 단위 변경을 복제한다. 아래의 병렬화도 모두 이 pub-sub worker 구조 위에서 일어난다.

#### 전체 흐름 (연결·스트림·진도)

별도의 "통지 후 가져오기" 2단계가 아니라, subscriber가 한 번 연 **상시 스트리밍 연결** 위로 변경이 계속 흘러내려오는 구조다.

```text
① subscriber의 apply worker가 publisher에 접속
   (CONNECTION 정보로, logical replication slot에서 START_REPLICATION)
        │  ← 연결은 subscriber가 "건다"(pull 방향)
        ▼
② publisher의 walsender가 WAL을 logical decoding
   - pgoutput이 publication 기준으로 "이 테이블 변경만" 필터링
        │
        ▼
③ 그 열린 연결 위로 변경 stream을 "계속" 흘려보냄
   (publisher에서 트랜잭션이 commit될 때마다 그 변경이 decoding되어 전송)
        │
        ▼
④ apply worker가 받아서 로컬 테이블에 적용
   + 어디까지 적용했는지 feedback(LSN)을 publisher로 보냄 → slot 전진
```

핵심: **연결 주체는 subscriber(pull)** 이지만, 일단 열리면 변경은 **publisher가 계속 push**한다. publication은 "무엇을 보낼지" 필터를 정의할 뿐이고, 실제 변경 데이터는 WAL → logical decoding → pgoutput 필터링을 거쳐 stream으로 나간다. replication slot은 subscriber의 진도(LSN)를 보존해 끊겼다 재개해도 빠짐없이 이어받게 한다 [9].

#### 실제 셋업: 무엇이 어디서 도는가 (중요)

논리복제는 **두 노드에서 서로 다른 설정/명령으로** 구성된다. 어떤 설정이 어느 쪽 것인지 헷갈리기 쉬우므로 구체적으로 본다.

**publisher(발행자) 쪽**
```sql
-- 1) 인스턴스 설정 (postgresql.conf, 서버 재시작 필요)
--    wal_level = logical   ← 논리복제의 전제. publisher 쪽 설정이다.

-- 2) 무엇을 발행할지 정의 (SQL)
CREATE PUBLICATION mypub FOR TABLE t1, t2;     -- 또는 FOR ALL TABLES
```

**subscriber(구독자) 쪽**
```sql
-- 3) 무엇을 구독할지 + 어떻게 받을지 정의 (SQL)
CREATE SUBSCRIPTION mysub
  CONNECTION 'host=pub_host dbname=mydb user=rep'
  PUBLICATION mypub
  WITH (streaming = parallel);                 -- ← streaming은 여기, 구독 WITH 옵션
```

여기서 핵심:

- **`wal_level=logical`은 publisher의 인스턴스 설정**이다. subscriber의 wal_level과는 무관하다 [1].
- **`streaming`(on/off/parallel)은 subscriber의 `CREATE/ALTER SUBSCRIPTION` WITH 옵션**이다. 즉 "어떻게 받아 적용할지"를 구독자가 정하는 것이지, publisher의 wal_level이 정하는 게 아니다 [3].
- 그래서 "`streaming=parallel`이 wal_level과 묶이나?"라는 질문은 **두 노드의 설정을 섞은 것**이다. 정답: `streaming`은 subscriber 옵션이라 직접 묶이지 않고, 다만 그것이 속한 **논리복제가 동작하려면 publisher가 `wal_level=logical`** 이어야 한다(논리복제 일반 전제) [1][3].
- **물리복제에는 이 SQL 셋업(`CREATE PUBLICATION/SUBSCRIPTION`)이 아예 없다.** 물리는 standby를 `primary_conninfo` + `standby.signal`로 띄우는 인스턴스 구성이며, subscription·`streaming` 옵션 개념 자체가 없다. 따라서 `streaming=parallel`은 **논리복제 전용**이다.

**왜 publisher가 `replica`면 논리복제가 성립하지 않나 (메커니즘)**

- `CREATE SUBSCRIPTION`은 subscriber에서 실행되지만, 내부적으로 publisher에 접속해 **logical replication slot**을 만든다. 이 logical slot은 publisher의 **`wal_level >= logical`을 요구**한다 [1][9].
- 따라서 publisher가 `wal_level=replica`면 logical slot 생성·logical decoding이 안 되어, **구독이 변경을 스트리밍하지 못한다**(slot 생성 단계에서 실패). subscriber에 apply worker가 떠도 받을 stream 자체가 만들어지지 않는다 [1][9].
- 정리하면: **subscriber의 apply worker가 실제로 동작하는 전제는 "publisher `wal_level=logical`"** 이다. publisher가 `replica`면 물리복제만 가능하고 논리 subscription은 성립하지 않는다 [1][9].
- **캐스케이딩 예외**: subscriber 자신의 `wal_level`은 그 subscriber가 **다시 다른 서버로 발행(publish)** 하는 경우에만 `logical`이어야 한다. 단순히 구독만 받는 노드라면 자신의 wal_level은 논리복제 수신과 무관하다 [1].

### 4. 논리 복제의 병렬성 — 세 갈래

논리 복제 worker는 모두 `max_logical_replication_workers` 풀(기본 4)에서 나오며, 이 풀은 다시 `max_worker_processes`에서 나온다. 그래서 `max_worker_processes`는 최소 `max_logical_replication_workers + 1` 이상으로 맞춰야 한다 [2][4].

worker 종류는 다음과 같다 [3][4]:

| worker | 역할 | 수명 | 병렬도 제어 |
|---|---|---|---|
| **leader apply worker** | 구독의 변경 stream을 받아 적용. 구독당 **1개** | 구독이 살아있는 동안 상주 | 구독 수만큼 (구독마다 1개) |
| **tablesync worker** | 구독 초기화 시 published 테이블을 `COPY`로 초기 동기화 | 해당 테이블 동기화 동안만(일시적) | `max_sync_workers_per_subscription`(기본 2) |
| **parallel apply worker** | `streaming=parallel`일 때 large in-progress transaction을 직접 적용 | 필요 시 | `max_parallel_apply_workers_per_subscription`(기본 2) |

즉 병렬화가 나타나는 지점은:

1. **구독 단위 병렬** — 구독마다 leader apply worker가 1개씩 뜨므로, 구독이 여러 개면 그만큼 병렬로 적용된다. 병렬 단위는 노드가 아니라 **구독(subscription)** 이다 — subscriber 노드 1개라도 구독을 여러 개 만들면 apply worker가 그 수만큼 떠서 병렬로 돈다. 단, **테이블은 publication에 정의하고 subscription은 publication을 가리키므로**, 병렬화하려면 publication을 쪼개고 구독을 여러 개 두는 **수동 테이블 분할(샤딩)** 이 필요하다.

   ```sql
   -- publisher: 테이블을 publication으로 분할
   CREATE PUBLICATION pub_a FOR TABLE t1, t2;
   CREATE PUBLICATION pub_b FOR TABLE t3, t4;

   -- subscriber: 같은 접속(host/dbname/user)으로 구독 2개, publication만 다르게
   CREATE SUBSCRIPTION sub_a CONNECTION 'host=pub dbname=mydb user=rep' PUBLICATION pub_a;
   CREATE SUBSCRIPTION sub_b CONNECTION 'host=pub dbname=mydb user=rep' PUBLICATION pub_b;
   ```

   `sub_a`→apply worker A, `sub_b`→apply worker B로 병렬 적용된다. 다만 **한 구독 안의 트랜잭션은 직렬**이고(6절), **구독을 가로지르는 commit 순서·원자성은 보장되지 않는다**. 따라서 트랜잭션 일관성이 필요한 테이블(예: 서로 의존하는 t1·t3·t5)은 **반드시 같은 publication/구독에 묶어야** 하며, 그만큼 병렬도는 줄어든다. 의존성이 구독 경계를 넘으면 — FK는 subscriber apply가 `session_replication_role=replica`로 동작해 **검사되지 않아 조용히 깨지고**(에러 없이 부모 없는 자식 행 등), PK/UNIQUE 충돌은 **에러로 해당 구독 적용이 중단**될 수 있다 [9].

   > **예시 — 구독 수 vs leader apply worker 풀**: 구독 8개인데 `max_logical_replication_workers=4`면 **동시에 4개 구독만 실시간 복제**된다. leader apply worker는 구독당 1개씩 이 풀에서 나오고 상주(long-lived)하므로, 풀 4를 4개 구독이 점유하면 **나머지 4개 구독은 worker 슬롯을 못 받아 적용을 못 한다**(슬롯 부족으로 계속 재시도). 즉 **동시 실시간 복제 구독 수 ≤ `max_logical_replication_workers`**. 8개를 다 돌리려면 `max_logical_replication_workers ≥ 8`(+ tablesync·parallel apply 예비), `max_worker_processes ≥ 그 값 + 1`로 올려야 한다 [2][4]. (공식: 이 값은 "구독 수 + 예비" 이상으로 설정.)
2. **초기 동기화 병렬** — 구독 생성/새 테이블 추가 시 여러 tablesync worker가 기존 데이터 `COPY`를 병렬 수행 [2][4].
3. **large transaction 병렬 apply** — 큰 진행 중 트랜잭션을 commit 전에 `Stream Start`/`Stream Stop` 단위로 받아, `streaming=parallel`이면 parallel apply worker가 직접 적용 [3].

### 5. 롱(대형) 트랜잭션 처리 (publisher 감지 → 전송 → subscriber 적용)

롱트랜잭션 처리는 **publisher가 메모리 한도를 감지해 큰 트랜잭션을 골라 내보내고(stream/spill)**, **subscriber가 그것을 parallel apply worker로 적용**하는 end-to-end 흐름이다. 순서대로 본다.

#### publisher 쪽: 롱트랜잭션 "감지" — reorder buffer 메모리 한도

publisher의 logical decoding은 WAL을 디코딩하며 변경을 **트랜잭션별로 메모리(reorder buffer)에 쌓는다**. "롱트랜잭션"은 변경 개수의 절대 기준이 아니라, **reorder buffer 전체 메모리가 `logical_decoding_work_mem`(기본 64MB)를 넘는 순간, 그중 메모리를 가장 많이 쓰는 트랜잭션**을 가리키는 상대적·순간적 개념이다 [11].

```text
[PUBLISHER — walsender / logical decoding]

WAL 읽기 → 변경 레코드 디코딩
   ▼
ReorderBuffer (동시 진행 중인 "서로 다른" 트랜잭션들을 각각 따로 쌓음)
   tx100: [c1][c2][c3]…     ← 트랜잭션 A의 개별 변경들
   tx101: [c1][c2]…         ← 트랜잭션 B (A와 무관한 별개 tx)
   tx102: [c1]…             ← 트랜잭션 C
   rb->size = tx100+tx101+tx102+… 전부의 메모리 합
   │
   ▼ ← 변경 추가될 때마다 검사: ReorderBufferCheckMemoryLimit()
  rb->size ≥ logical_decoding_work_mem ?
   ├─ 아니오 → 계속 메모리에 쌓음 (정상)
   └─ 예(한도 초과) → 메모리 줄이기:
        (1) 가장 큰 top-level 트랜잭션 선택 (메모리 바이트 기준, 시간·개수 아님)
        (2) streaming 가능?  예 → STREAM(subscriber로 전송)
                              아니오(불완전 튜플 등) → SPILL(디스크 직렬화)
        (3) 그래도 초과면 다음으로 큰 tx에 반복
```

핵심 구분:

- **tx100/101/102 = 서로 다른(동시 진행) 트랜잭션** — 한 롱트랜잭션의 청크가 아니다. `[c1][c2]…`가 그 트랜잭션 *내부*의 개별 변경이다.
- 한도는 **전체 합(`rb->size`)** 에 걸리고, 희생자는 **그 순간 메모리 최다 트랜잭션 하나**. 기준은 **시간(duration)·개수가 아니라 메모리 바이트**다 [11].
- **한 롱트랜잭션이 여러 Stream 세그먼트로 나뉘는 건 "시간 축"** 에서다: 같은 tx가 반복해서 "최대"로 뽑힐 때마다 그때까지 쌓인 변경이 한 세그먼트로 나가고 메모리가 비워진다. commit 시 마지막 `Stream Commit`.

```text
시간 →
tx100(롱): 쌓임…한도초과→Stream세그1   더쌓임…한도초과→Stream세그2 … commit→Stream Commit
          (세 세그먼트 모두 같은 tx100. 시간에 걸쳐 나옴)
```

#### `streaming` 옵션 세 값 (off / on / parallel)

`streaming`은 **진행 중(in-progress) 트랜잭션을 commit 전에 보낼지, 어떻게 적용할지**를 정하는 subscriber 구독 옵션이다. 세 값의 차이는 다음과 같다 [3].

| 값 | 언제 보내나 | subscriber에서 적용 방식 | 효과 |
|---|---|---|---|
| `off` | publisher에서 **commit된 뒤** 트랜잭션을 통째로 전송 | apply worker가 받아 적용 | 큰 트랜잭션은 commit까지 publisher가 버퍼링 → publisher 메모리·지연 큼 |
| `on` | **commit 전(진행 중)** 변경을 전송 | subscriber가 **임시 파일에 써두었다가**, publisher commit + 수신 후 적용 | publisher 메모리 절감. 단 적용은 commit 후 |
| `parallel` **(PG18 기본)** | **commit 전(진행 중)** 변경을 전송 | 가용한 **parallel apply worker가 직접 적용**. 없으면 `on`처럼 임시 파일 fallback | 적용을 commit 전부터 시작 → 지연 최소 + 대형 트랜잭션 병렬 |

- `off`는 "트랜잭션이 끝나야(decode 완료) 보낸다", `on`/`parallel`은 "끝나기 전부터 흘려보낸다"는 점이 핵심 차이.
- `on`과 `parallel`은 둘 다 commit 전에 stream하지만, `on`은 **임시 파일 경유 후 commit 뒤 적용**(직렬), `parallel`은 **PA가 즉시 적용**(병렬). PA가 없으면 `parallel`도 `on` 경로로 떨어진다 [3].
- 어떤 트랜잭션이 stream 대상이 되는지는 publisher의 `logical_decoding_work_mem` 초과 여부로 결정된다(6절).

#### LA ↔ PA 동작 (streaming=parallel)

`streaming=parallel`(위 4절 ③)의 병렬 적용은 다음 구조로 동작한다 [7].

- **leader apply worker(LA)** 가 publisher의 change stream을 받아 **dispatcher 역할**을 한다.
- 대형 트랜잭션의 첫 stream이 도착하면 LA는 가용한 **parallel apply worker(PA)** 를 하나 배정하고, 변경을 **전용 공유메모리 큐(`shm_mq`)** 로 PA에 보낸다 [7].
- PA는 받은 변경을 직접 적용하고 다음 stream을 기다린다. 이 PA는 해당 트랜잭션이 **commit될 때까지 그 트랜잭션에 묶여 있다** [7].
- **여러 대형 트랜잭션을 동시에** 서로 다른 PA가 병렬 적용할 수 있다. 동시 병렬도는 `max_parallel_apply_workers_per_subscription`(기본 2) — 즉 구독당 대형 트랜잭션 2개까지 동시 적용 [7].
- **commit 순서 보존**: commit 시점에 LA는 해당 PA가 끝나기를 기다려 commit 순서를 publisher와 맞춘다(트랜잭션 의존성·데드락 회피) [7].
- **fallback**: 가용한 PA가 없으면 변경을 임시 파일에 쓴 뒤, publisher에서 commit되고 subscriber가 수신한 후 적용한다(`streaming=on`과 같은 직렬 경로) [3].

```text
publisher
  -> walsender + logical decoding(pgoutput)
  -> change stream

subscriber
  leader apply worker (LA)   ← dispatcher
    ├─ 일반(소형) 트랜잭션      -> LA가 직접 직렬 적용
    ├─ 대형 tx A (streamed)   -> shm_mq -> PA[0] 적용
    └─ 대형 tx B (streamed)   -> shm_mq -> PA[1] 적용
  commit 시점: LA가 PA 완료를 기다려 commit 순서 보존
  PA 없음    -> 임시 파일 -> commit 후 적용 (fallback)
```

#### end-to-end 예시

대형 tx A·B가 동시에 진행 중이고 소형 tx S가 섞인 상황(`streaming=parallel`):

```text
[PUBLISHER]                                   [SUBSCRIBER]
reorder buffer 채워짐
 rb->size ≥ 64MB 감지
   → 최대 tx 선택(A) → Stream세그(A)  ─────►  LA: A를 PA[0]에 배정 → PA[0] 적용 시작 (commit 전)
 또 초과 → 다음 최대(B) → Stream세그(B) ─────►  LA: B를 PA[1]에 배정 → PA[1] 적용 시작
 소형 tx S commit → 통째 전송            ─────►  LA: S를 직접 직렬 적용
 A 계속 자람 → Stream세그(A-2)          ─────►  PA[0]: 같은 A에 이어 적용
 A commit → Stream Commit(A)            ─────►  LA: PA[0] 완료 대기 → commit 순서대로 A commit
 B commit → Stream Commit(B)            ─────►  LA: 순서 맞춰 B commit
```

- A·B는 **서로 다른 PA에서 병렬** 적용(대형이라 streamed). S는 소형이라 **LA가 직렬** 적용.
- A의 여러 세그먼트(A, A-2…)는 **모두 PA[0]** 에서 순서대로(한 tx = 한 PA).
- 최종 **commit 순서는 publisher와 동일**하게 LA가 강제(PA 완료 대기).
- 만약 PA가 다 차 있으면 A/B도 **임시 파일 경로(fallback)** 로 떨어져 commit 후 적용.

### 6. 단일 구독 내 일반 트랜잭션은 직렬 (commit order)

핵심 한계: **하나의 구독 안에서 일반(비스트리밍) 트랜잭션은 leader apply worker가 publisher의 commit 순서대로 직렬 적용**한다. PostgreSQL은 MySQL의 logical clock/write-set처럼 "서로 독립적인 여러 트랜잭션을 의존성 계산해 worker로 병렬 dispatch"하는 모델이 **아니다** [3][7].

위 5절의 parallel apply worker는 여러 대형 트랜잭션을 동시 적용할 수 있으나(기본 2개), 이는 **(a)** `logical_decoding_work_mem`를 넘겨 streaming되는 **대형 트랜잭션만** 병렬 후보이고, **(b)** 소형 일반 트랜잭션은 LA가 직렬 적용하며, **(c)** commit 순서는 유지된다는 제약 위에서다. 즉 "대형 트랜잭션에 한해, commit 직렬화를 깔고" 병렬화하는 것이지, MySQL식 "임의의 독립 트랜잭션을 의존성 판단해 병렬 dispatch"와는 다르다 [3][7].

### 7. commit order를 지켜야 하는 이유

PostgreSQL 핵심 개발자(Amit Kapila) 설명에 따르면, 병렬 apply에서도 commit 순서 유지가 중요한 이유는 다음과 같다 [7]:

- **트랜잭션 의존성**: 한 트랜잭션이 행을 INSERT하고 다른 트랜잭션이 그 행을 UPDATE하는데 병렬로 적용하면 실패할 수 있다.
- **데드락**: 같은 행/테이블을 반대 순서로 갱신하는 트랜잭션을 병렬 적용하면 데드락이 생길 수 있다.

이 때문에 PostgreSQL은 병렬성을 넓히기보다 commit 순서 보존을 우선하는 보수적 모델을 택한다 [7].

### 8. 왜 병렬이 이 두 형태(구독 분할 / 대형 tx streaming)인가

commit 순서 보존은 어디서나 당연한 요구이므로, 진짜 질문은 "왜 하필 PostgreSQL의 병렬이 ① 구독 분할과 ③ 대형 트랜잭션 streaming **두 형태로만** 나타나는가"이다. 핵심은 **두 메커니즘 모두 "병렬을 위해" 설계된 게 아니라 각자 다른 목적에서 나왔고, 병렬은 그 위에 얹혔다**는 점이다.

**③ 대형 tx streaming = 원래 메모리·apply lag 해결책 (병렬은 부산물)**

- streaming(PG14)의 원래 목적은 병렬이 아니라 large transaction의 **메모리 + apply lag** 문제였다 [11]. streaming 이전엔 logical decoding이 트랜잭션을 **commit 시점에 통째로** 보내야 해서(commit 순서로 내보내야 하므로), 거대 트랜잭션은 publisher가 전체를 버퍼링(메모리/디스크 spill)하고 subscriber는 commit 전까지 적용을 시작도 못 해 **apply lag가 급증**했다 [11].
- streaming은 진행 중 변경을 `Stream Start/Stop` 청크로 **commit 전에** 흘려보내 publisher 버퍼링을 줄이고 subscriber가 일찍 시작하게 한다. 트리거 기준이 `logical_decoding_work_mem`(기본 64MB)이다 [11].
- **그 다음 PG16**이 "이미 청크로 들어오니 임시 파일 거치지 말고 parallel apply worker로 바로 적용하자"며 병렬을 얹었다 [3]. 그래서 **병렬이 대형 트랜잭션 한정인 이유**: 청크 나누기가 원래 대형 트랜잭션 메모리/지연용이고, 병렬은 그 위에 올라탄 부산물이라서. 소형은 애초에 streaming 대상이 아니다.

**① 구독 분할 = 아키텍처에서 자연히 떨어지는 병렬 경로**

- 논리복제 기본 단위는 **1 구독 = 1 replication slot = 1 commit-ordered 스트림 = 1 apply worker**이고, 그 스트림은 순수 commit 순서 스트림이라 **트랜잭션 간 의존성/충돌 메타데이터를 담지 않는다**(MySQL의 `last_committed`/`WRITESET` 같은 게 없음) [9].
- 한 스트림 *안에서* 독립 트랜잭션을 병렬화하려면 의존성 추적(MySQL식)이 필요한데 그 정보가 스트림에 없다. 그래서 가장 자연스러운 병렬화는 **독립 스트림을 여러 개 돌리는 것**(slot/구독 여러 개)이고, 독립성 판단은 엔진이 아니라 **운영자가 테이블을 publication으로 나눠 "선언"** 한다.

**공통 분모**: 두 형태 모두 **엔진이 트랜잭션 의존성을 계산하지 않고** 병렬을 얻는다 — 구독 분할은 운영자가 독립성을 선언하고, 대형 tx streaming은 이미 메모리용으로 나뉜 청크에 병렬을 얹되 commit 순서를 강제한다. MySQL식 "publisher가 의존성 메타데이터를 로그에 심고 적용 측이 독립 트랜잭션을 자동 병렬화"를 하려면 PostgreSQL은 스트림에 **없는 정보를 새로 추가**해야 하는데, 그렇게 하지 않았기 때문에 **추가 정보 없이 가능한 두 경로**만 존재한다.

| 메커니즘 | 원래 목적 | 병렬은? | 왜 그 범위만 |
|---|---|---|---|
| 대형 tx streaming(③) | 메모리/apply lag 감소(PG14) [11] | PG16에 얹힘 [3] | streaming은 대형(`logical_decoding_work_mem` 초과)만 → 병렬도 대형만 |
| 구독 분할(①) | 논리복제 기본 단위(slot/stream/worker) | 구조 반복으로 자연 발생 | 의존성 메타데이터 부재로 한 스트림 내 자동 병렬 불가 → 스트림을 늘림 |

> **근거 구분**: ③ streaming의 "메모리/지연 목적"은 공식 문서로 확인됨 [11]. ①에 대한 "의존성 메타데이터 부재가 곧 다중 구독이 유일 경로인 이유"라는 연결은 아키텍처 기반 **추론**이며, 명시적 설계 결정문은 확보하지 못했다(아래 추론 섹션 참조).

### 9. 버전 히스토리

- **PG10**: 논리 복제(publication/subscription) 도입.
- **PG15**: `recovery_prefetch` 도입(물리 재생 I/O 프리페치) [1][5].
- **PG16**: large in-progress transaction의 `streaming=parallel`(parallel apply worker) 도입 — 단, 기본값 아님 [3].
- **PG18**: `streaming`의 **기본값이 `parallel`로 변경** [3][6].

## 추론 / 유추
- CUBRID 병렬 applylogdb가 목표하는 "독립 트랜잭션을 의존성 판단해 worker로 병렬 dispatch"는 **PostgreSQL보다 MySQL 모델(WRITESET/LOGICAL_CLOCK)에 가깝다** — PostgreSQL은 단일 구독 내 일반 트랜잭션을 직렬 적용하므로 직접 참고 모델로는 적합도가 낮다 (← [3], [7]). 다만 PostgreSQL의 "같은 트랜잭션 내 변경 순서 보존", "commit order 우선" 원칙은 코디네이터 correctness 설계에 그대로 참고 가치가 있다 (← [7]).
- PostgreSQL이 "구독 분할"을 테이블 단위 병렬의 사실상 유일한 경로로 두는 것은, logical decoding 스트림이 의존성/충돌 메타데이터를 담지 않아 **한 스트림 내 자동 병렬화에 필요한 정보가 없기 때문**으로 보인다 (← [9]). 즉 MySQL식 자동 병렬을 하려면 스트림 포맷에 의존성 정보를 추가해야 하는데, PostgreSQL은 그 대신 "독립 스트림을 여러 개" 두는 길을 택한 것으로 추정된다. 이는 8절의 아키텍처 서술에서 도출한 추론이며, 명시적 설계 결정문 1순위 자료는 확보하지 못했다.
- 물리 복제가 단일 스레드 재생인 점은, 블록 단위 replay가 본질적으로 LSN 순서에 강하게 묶여 있어 병렬화가 어렵다는 일반적 사정과 부합한다 (← [5]). CUBRID가 논리 계열 복제라면 오히려 트랜잭션 단위 병렬화 여지가 더 크다고 볼 수 있으나, 이는 CUBRID 코드 확인이 필요하다.

## 미해결 / 자료 부족
- `max_sync_workers_per_subscription` / `max_parallel_apply_workers_per_subscription`의 기본값(각 2)은 검색·문서 요약 기준이며, 운영 버전별로 재확인이 필요할 수 있다(공식 파라미터 페이지에서 버전별 확정 권장).
- "PG18에서 streaming 기본값 parallel" 중 PG18 릴리스 노트 원문 직접 인용은 확보하지 못했고, PG18(=docs/current) CREATE SUBSCRIPTION 문서의 "The default value is parallel" 기술로 확인했다. 정확한 도입/변경 커밋 추적은 별도 작업.
- 물리 복제 병렬 재생(parallel recovery)의 코어 반영 여부·로드맵은 제안 문서 외 확정 자료가 없어 단정하지 않는다.

> **[확인 완료 · 2026-06-02]** 물리복제 WAL 재생이 단일 스레드(startup process)라는 점(2절)을 **PostgreSQL 17.10 로컬 소스로 직접 확인**했다.
> - **재생측**: `PerformWalRecovery()`(xlogrecovery.c:1662)의 "main redo apply loop"(:1758–1846)가 레코드마다 `ApplyWalRecord()`(:1915)를 호출하는 단일 루프이며, redo 루프 내 worker dispatch 코드 없음.
> - **수신측**: `walreceiver` 단일 프로세스(`WalReceiverMain()` walreceiver.c:183, `B_WAL_RECEIVER` launch_backend.c:206)가 `primary_conninfo`로 접속(`xlogrecovery.c:3872`의 `RequestXLogStreaming(...PrimaryConnInfo...)` → `walreceiver.c:301` `walrcv_connect`)해 `walrcv_receive()` 단일 루프(:475, 509)로 수신.
> - 복제 경로에 `pthread_create` 없음(프로세스 모델). → §2의 근거 등급을 doxygen 기반에서 **로컬 소스 직접 확인**으로 격상함.

## References
[1] PostgreSQL Global Development Group. "19.5. Write Ahead Log" (`recovery_prefetch`, `wal_decode_buffer_size`, `maintenance_io_concurrency`). PostgreSQL 18 Documentation, 2025. https://www.postgresql.org/docs/current/runtime-config-wal.html

[2] PostgreSQL Global Development Group. "29.12. Configuration Settings" (logical replication worker pool, `max_worker_processes` 관계). PostgreSQL 18 Documentation, 2025. https://www.postgresql.org/docs/current/logical-replication-config.html

[3] PostgreSQL Global Development Group. "CREATE SUBSCRIPTION" (`streaming` 옵션 on/off/parallel, 기본값 parallel). PostgreSQL 18 Documentation, 2025. https://www.postgresql.org/docs/current/sql-createsubscription.html

[4] PostgreSQL Global Development Group. "19.6. Replication" (`max_logical_replication_workers` 기본 4, `max_sync_workers_per_subscription`, `max_parallel_apply_workers_per_subscription`). PostgreSQL 18 Documentation, 2025. https://www.postgresql.org/docs/current/runtime-config-replication.html

[5] CYBERTEC. "PostgreSQL Recovery Internals" / "End of the road for PostgreSQL streaming replication?" (WAL 재생이 startup process 단일 스레드, recovery_prefetch는 I/O 프리페치). CYBERTEC Blog, 2023~2024. https://www.cybertec-postgresql.com/en/postgresql-recovery-internals/

[6] PostgreSQL Wiki. "Parallel Recovery" (코어 미반영 설계 제안: transaction worker / block worker). https://wiki.postgresql.org/wiki/Parallel_Recovery

[7] Amit Kapila (PostgreSQL committer). "Parallel Apply of Large Transactions" (commit order 유지 이유: 트랜잭션 의존성·데드락). amitkapila16 blog, 2025-09. http://amitkapila16.blogspot.com/2025/09/parallel-apply-of-large-transactions.html

[8] PostgreSQL Source Code. `src/backend/access/transam/xlogrecovery.c` (`PerformWalRecovery()`: startup process 단일 redo 루프가 WAL 레코드를 순차 적용). PostgreSQL doxygen, 2025. https://doxygen.postgresql.org/xlogrecovery_8c.html

[9] PostgreSQL Global Development Group. "Chapter 29. Logical Replication" (pub/sub 모델, publication/subscription, pgoutput, walsender, apply worker, replication slot). PostgreSQL 18 Documentation, 2025. https://www.postgresql.org/docs/current/logical-replication.html

[10] PostgreSQL Global Development Group. "26.1. Comparison of Different Solutions" / "26.2. Log-Shipping Standby Servers" (WAL shipping = file-based log shipping 또는 streaming replication, 또는 조합). PostgreSQL 18 Documentation, 2025. https://www.postgresql.org/docs/current/warm-standby.html

[11] PostgreSQL Global Development Group. "47.9. Streaming of Large Transactions for Logical Decoding" (streaming 도입 목적: 대형 트랜잭션 메모리·apply lag 감소, `logical_decoding_work_mem` 기본 64MB 트리거). PostgreSQL 18 Documentation, 2025. https://www.postgresql.org/docs/current/logicaldecoding-streaming.html

[12] PostgreSQL Source Code. `src/backend/replication/logical/reorderbuffer.c` (`ReorderBufferCheckMemoryLimit()`: `rb->size ≥ logical_decoding_work_mem`일 때 가장 큰 top-level 트랜잭션을 골라 stream 또는 spill). PostgreSQL doxygen, 2025. https://doxygen.postgresql.org/reorderbuffer_8c_source.html
