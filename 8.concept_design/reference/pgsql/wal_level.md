# PostgreSQL `wal_level` 종합 정리

> 자료조사 문서 · 조사 시점 2026-06-02
> 출처: PostgreSQL 공식 문서 (1순위)
> 용도: 복제/백업 컨셉 레퍼런스 (concept_design reference/pgsql)

## 요약
- `wal_level`은 "WAL에 **얼마나 많은 정보를 쓸지**"를 정하는 enum 설정값이며, 값은 `minimal` / `replica`(기본) / `logical` 세 단계로 상위가 하위를 포함한다 [1].
- 복제 전용 설정이 아니다 — crash recovery는 모든 레벨에서 되고, **PITR 백업·WAL 양/성능**에도 직접 영향을 준다 [1].
- `minimal`은 WAL을 가장 적게 만들어 일부 대량 작업을 빠르게 하지만, PITR·아카이빙·복제가 불가능하다 [1].
- `replica`(기본)는 WAL 아카이빙·물리 스트리밍 복제·standby 읽기 쿼리를 지원하고, `logical`은 거기에 logical decoding 정보를 더한다 [1].
- **postmaster 컨텍스트라 변경 시 서버 재시작이 필요**하며(reload 불가), `minimal`은 `max_wal_senders=0`·`archive_mode=off` 등 전제 조건이 있다 [1].

## 본문

### 1. `wal_level`이란

`wal_level`은 WAL(Write-Ahead Log)에 기록되는 정보의 양을 결정하는 enum 파라미터다 [1]. WAL 자체는 `wal_level`과 무관하게 항상 기록되며(durability·crash recovery 목적), `wal_level`은 그 기본 위에 **추가 정보를 얼마나 더 담을지**를 단계로 정한다. 각 레벨은 하위 레벨의 정보를 모두 포함하는 누적 구조다 [1].

### 2. 세 가지 레벨

| 레벨 | 담기는 정보 | 가능한 것 |
|---|---|---|
| `minimal` | crash/즉시종료 복구에 필요한 최소 정보만. WAL 양 최소 | crash recovery만. **PITR·아카이빙·복제 불가** [1] |
| `replica` **(기본값)** | WAL 아카이빙·복제 지원 정보 + standby 읽기 쿼리 | **물리 스트리밍 복제**, 연속 아카이빙/PITR, hot standby [1] |
| `logical` | `replica` 정보 + logical decoding용 정보 | 위 전부 + **논리 복제 / logical decoding(CDC)** [1] |

### 3. `minimal` 레벨: 이점과 제약

`minimal`은 영구 relation을 생성·재작성하는 트랜잭션에서 행 정보를 WAL에 남기지 않아 WAL 양이 가장 적고, 다음 작업들을 훨씬 빠르게 만든다 [1]:

- `CREATE TABLE`, `TRUNCATE`, `CLUSTER`, `REINDEX`, `ALTER ... SET TABLESPACE`, `REFRESH MATERIALIZED VIEW`(CONCURRENTLY 제외) 등.

대신 다음 제약이 있다 [1]:

- **PITR(시점 복구)에 필요한 정보가 부족**하다. → 연속 아카이빙·스트리밍 복제 불가.
- `archive_mode`를 켤 수 없다. 아카이빙하려면 `replica` 이상이어야 한다.
- `max_wal_senders`가 0이 아니면 **서버가 아예 시작되지 않는다.** 즉 `minimal`을 쓰려면 `max_wal_senders=0`, `archive_mode=off`가 전제다.
- `summarize_wal=on`으로는 시작할 수 없다. 시작 후 켜더라도 `minimal`로 생성된 WAL에 대해서는 summary 파일 생성을 거부한다.
- `wal_level`을 `minimal`로 낮추면 **이전 base backup이 PITR에 쓸 수 없게 되고**, standby 서버도 정상 동작하지 않는다.

### 4. `logical` 레벨: WAL 증가

`logical`은 logical decoding을 위해 WAL에서 논리적 change set을 추출할 수 있는 정보를 추가로 남긴다. 그만큼 WAL 양이 늘어나며, 특히 **`REPLICA IDENTITY FULL`로 설정된 테이블이 많고 UPDATE/DELETE가 잦을수록** 증가폭이 크다 [1].

#### 왜 레벨이 높을수록 WAL이 많아지나

레벨이 높을수록 정보량이 느는 이유는 **"그 WAL로 복원해야 하는 대상이 얼마나 까다로운가"** 가 레벨마다 다르기 때문이다. 복원 목적이 까다로울수록 더 많은 정보를 남겨야 복원이 가능하다 [1].

- **`minimal` — "이 인스턴스의 crash만 복구"**
  crash recovery는 이미 디스크에 데이터 파일이 있는 상태에서 죽기 직전 변경만 redo하면 된다. 그래서 새로 만들거나 통째로 다시 쓴 테이블은 행 정보를 WAL에 안 남길 수 있다 — 트랜잭션이 커밋 전에 죽으면 그 파일은 어차피 버려지고, 커밋되면 데이터 파일에 직접 써서 보존하므로 WAL을 거칠 필요가 없다. → WAL 최소.

- **`replica` — "다른 인스턴스가 WAL만 보고 똑같이 재현"**
  물리 standby나 백업 복구 인스턴스는 데이터 파일을 따로 받지 못하고 오로지 WAL만 보고 자기 블록을 재현해야 한다. 따라서 minimal의 "어차피 파일이 통째로 생기니 행 로깅 생략" 최적화를 쓸 수 없다 — 행 데이터가 WAL에 없으면 standby가 만들 수 없기 때문이다. 또 standby에서 읽기 쿼리가 돌게 하려면 "현재 실행 중인 트랜잭션" 같은 추가 정보도 넣어야 한다. → minimal보다 많음.

- **`logical` — "물리 위치 말고 '어떤 행이 어떻게 바뀌었나'를 복원"**
  물리 WAL 레코드는 "17번 페이지 240바이트를 이 값으로 바꿔라" 형태라 블록 재현에는 충분하지만, "테이블 t에서 PK=5인 행을 이렇게 UPDATE 했다"는 논리적 의미는 담지 않는다. 논리복제 대상(subscriber)은 물리 레이아웃이 다를 수 있어 "몇 번 페이지"가 아니라 "어떤 행을, 어떻게"를 알아야 한다. 그래서 UPDATE/DELETE 시 변경 대상 행을 식별할 정보(old 행의 키 컬럼)를 추가로 남겨야 한다 — 물리복제는 그 자리 바이트를 덮어쓰면 되니 이게 필요 없었다. `REPLICA IDENTITY FULL`이 WAL을 크게 늘리는 이유가 바로 이것으로, 키 컬럼만이 아니라 변경 전 행 전체(old row image)를 매 UPDATE/DELETE마다 남기기 때문이다. → 가장 많음.

요약하면, WAL 정보량은 **복원 대상의 난이도에 비례**한다. minimal은 "내 파일은 이미 있으니 죽기 직전 변경만", replica는 "남이 WAL만 보고 똑같은 블록을 만들어야 하니 행 데이터 전부", logical은 "물리 위치를 무시하고 어떤 행이 어떻게까지 복원해야 하니 행 식별·old 값까지" 남긴다 [1].

### 5. 설정 방법 (서버 재시작 필요)

`wal_level`은 **postmaster 컨텍스트**라 서버 시작 시에만 설정되며, 변경 시 **reload가 아니라 재시작**이 필요하다 [1].

- 방법 1 — `postgresql.conf` 편집:
  ```conf
  wal_level = logical    # minimal | replica | logical
  ```
- 방법 2 — SQL: `ALTER SYSTEM SET wal_level = 'logical';` (값이 `postgresql.auto.conf`에 기록됨)
- 두 방법 모두 적용에는 **서버 재시작 필수** (`pg_ctl restart` / `systemctl restart`). `pg_reload_conf()`로는 적용되지 않는다 [1].
- 현재 값 확인: `SHOW wal_level;` 또는 `SELECT name, setting, context FROM pg_settings WHERE name='wal_level';` (context가 `postmaster`).

### 6. 복제 외 영향 (복제 전용 설정이 아님)

`wal_level`은 복제 외에도 다음에 영향을 준다 [1]:

- **백업/PITR**: 복제를 안 쓰더라도 `pg_basebackup` + WAL 아카이빙으로 시점 복구를 하려면 `replica` 이상이 필요하다. 백업/재해복구 영역.
- **WAL 양·쓰기 성능**: `minimal`은 일부 대량 작업의 WAL 로깅을 생략해 빠르고 WAL이 적다. `logical`은 WAL 양이 가장 많다.
- **crash recovery**: 모든 레벨에서 동작하므로 `wal_level`에 좌우되지 않는다.

### 7. 버전 히스토리

PostgreSQL 9.6 이전에는 `wal_level`에 `archive`, `hot_standby` 값이 따로 있었다. 9.6에서 이 둘이 `replica`로 통합되었고, 옛 값(`archive`/`hot_standby`)은 하위 호환을 위해 여전히 입력은 받지만 내부적으로 `replica`로 매핑된다 [1].

## 추론 / 유추
- CUBRID 복제는 PostgreSQL의 `wal_level` 같은 "WAL 정보량 레벨" 스위치를 그대로 갖지 않을 가능성이 높다 — 이 개념은 PostgreSQL WAL 아키텍처 특유의 것이므로, CUBRID 복제 로그(repl log) 설계와 직접 1:1 대응시키기보다 "복제·아카이빙에 필요한 정보를 로그에 얼마나 남기느냐"라는 일반 원리로만 참고하는 것이 적절하다 (← [1]).

## 미해결 / 자료 부족
- `summarize_wal`(증분 백업용 WAL summarizer)과 `wal_level` 상호작용의 세부 동작은 본 문서 범위 밖이며, 필요 시 별도 조사 대상.
- 각 레벨에 따른 구체적 WAL 증가량(수치/벤치마크)은 워크로드 의존적이라 1·2순위에서 확정값을 확보하지 못함 — 단정값으로 기재하지 않음.

## References
[1] PostgreSQL Global Development Group. "19.5. Write Ahead Log" (`wal_level` 파라미터: 값/기본값/minimal 제약/logical WAL 증가/재시작 요구/9.6 이전 archive·hot_standby 매핑). PostgreSQL 18 Documentation, 2025. https://www.postgresql.org/docs/current/runtime-config-wal.html
