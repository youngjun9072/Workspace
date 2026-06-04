# 로깅 아키텍처: PostgreSQL WAL vs MySQL redo log + binlog

> 자료조사 문서 · 조사 시점 2026-06-04
> 출처: PostgreSQL/MySQL 공식 문서(1순위)
> 용도: "왜 PG는 WAL 하나인데 MySQL은 binlog를 쓰나"에 대한 개념 정리 (reference/base)

## 요약
- crash recovery(durability)와 복제(replication)는 **서로 다른 목적의 로그**가 담당할 수 있다.
- **PostgreSQL은 WAL 하나**가 두 역할(crash recovery + 복제)을 **겸한다** — 단일 통합 스토리지라 가능 [3].
- **MySQL은 로그가 둘**이다: **InnoDB redo log**(엔진 내부·물리·crash recovery) + **binary log(binlog)**(서버 계층·논리·복제) [1][2].
- MySQL이 둘로 나뉜 근본 이유는 **pluggable storage engine** 구조 — 복제는 엔진에 독립적인 서버 계층 로그(binlog)가 필요하기 때문 [1].
- 그래서 **MySQL 복제 = binlog(논리)** 이고, redo log(물리)는 복제에 쓰지 않는다. PG WAL의 "crash recovery" 대응물은 MySQL의 **redo log**다.

## 본문

### 1. crash recovery 로그 ≠ 복제 로그 (목적이 다름)

- **crash recovery / durability**: 서버가 비정상 종료돼도 커밋된 데이터를 잃지 않도록, 디스크 반영 전 변경을 먼저 로그에 적는다(write-ahead). 이건 **물리(블록/페이지) 수준**이면 충분하다.
- **복제 / PITR**: 다른 서버(또는 시점)로 변경을 전달한다. 받는 쪽이 재현할 수 있어야 하므로, 전달 로그는 그 목적에 맞는 형태(물리 또는 논리)여야 한다.

이 둘을 **하나의 로그로 겸하느냐, 분리하느냐**가 PostgreSQL과 MySQL의 차이다.

### 2. PostgreSQL — WAL 하나가 겸한다

PostgreSQL은 **단일 통합 스토리지**라 **WAL(Write-Ahead Log) 하나**가 모두 담당한다 [3]:

- **crash recovery**: WAL은 본래 물리(블록) 로그라 재시작 시 redo로 일관 상태 복구.
- **복제**: 같은 WAL을 그대로 보내 **물리 스트리밍 복제**, 또는 **logical decoding**으로 논리 변경을 뽑아 **논리 복제**.
- 엔진이 하나라 "엔진 독립 복제 로그"를 따로 둘 이유가 없다.

### 3. MySQL — redo log + binlog 두 개

MySQL은 로그가 **두 층**이다 [1][2]:

| 로그 | 계층 | 성격 | 용도 |
|---|---|---|---|
| **InnoDB redo log** | 스토리지 엔진 내부 | **물리(physical)** | crash recovery / durability (← PG WAL의 그 역할) [2] |
| **binary log (binlog)** | 서버(엔진 위) | **논리(logical)** | 복제 / PITR [1] |

- **redo log**: InnoDB 엔진 내부의 물리 로그. 엔진별 내부 포맷이라 다른 엔진과 호환되지 않고, **복제에 쓰지 않는다** [2].
- **binlog**: 서버 계층에서 "어떤 행/문장이 바뀌었나"라는 **논리 변경**을 기록 → 엔진이 무엇이든 복제가 됨 [1].

### 4. 왜 MySQL은 둘로 나눴나 — pluggable storage engine

MySQL은 **스토리지 엔진을 갈아끼우는 구조**(InnoDB, MyISAM 등)다. 각 엔진이 **자기만의 crash recovery**(InnoDB는 redo log)를 갖는데, 이는 엔진 내부 물리 포맷이라 엔진마다 다르다. 따라서 복제는 **특정 엔진에 묶이지 않는, 엔진 독립적인 서버 계층 로그**가 필요했고 — 그것이 **binlog**다 [1]. 그 결과:

- **MySQL 복제 = binlog 기반 = 논리복제**. 네이티브 블록 물리복제가 없다(redo log는 복제용이 아님).
- PostgreSQL은 단일 엔진이라 WAL 하나로 충분 → 이 분리가 없다.

### 5. 곁따라오는 것 — 두 로그의 정합성(MySQL)

MySQL은 로그가 둘이라 커밋 시 **redo log와 binlog를 일관되게 맞춰야** 한다(내부 XA 2-phase commit). **binlog group commit**은 이 두 로그 쓰기·sync·엔진 커밋을 묶어 최적화하는 commit 경로다. PostgreSQL은 로그가 하나라 이 조율 문제 자체가 없다.

## 대비 표

| 항목 | PostgreSQL | MySQL |
|---|---|---|
| crash recovery 로그 | **WAL**(물리) | **InnoDB redo log**(물리, 엔진 내부) |
| 복제 로그 | **같은 WAL**(물리 스트리밍 / 논리 디코딩) | **binlog**(논리, 서버 계층) |
| 로그 개수 | 1개(겸용) | 2개(분리) |
| 분리 이유 | 단일 엔진 → 불필요 | pluggable engine → 엔진 독립 복제 로그 필요 |
| 복제 성격 | 물리·논리 모두 | 논리(binlog)만 (물리는 Clone 초기 구축뿐) |
| 두 로그 정합성 | 없음(로그 1개) | redo↔binlog 2PC + group commit |

## 부록 A: WAL 상세 (PostgreSQL)

- **원리(write-ahead)**: 데이터 페이지를 디스크에 반영하기 전에 **변경을 먼저 WAL에 기록**한다. 그래야 장애 시 WAL을 redo해 복구할 수 있다 [3].
- **구조**: WAL은 **세그먼트 파일**(기본 16MB)들이 `pg_wal/`에 줄지어 있고, 그 안은 **WAL 레코드**들의 연속이다 [3].
- **LSN(Log Sequence Number)**: WAL 스트림 안의 **바이트 위치**로, 단조 증가한다. "어디까지 썼나/받았나/적용했나"를 가리키는 좌표(복제 진도·체크포인트 기준)다 [3].
- **기록 내용**: **물리(블록) 변경** — "몇 번 페이지의 어디가 어떻게 바뀌었나". 체크포인트 후 첫 변경 페이지는 torn-page 방지를 위해 **Full Page Image(FPI)** 전체를 남기기도 한다. 각 서브시스템(heap, btree 등)이 자기 **redo 루틴(rmgr)** 을 가진다 [3].
- **순서**: WAL은 **쓰여진 순서(= LSN 순서, write order)** 다. 여러 트랜잭션의 변경이 섞여 들어간다(commit 순서 아님). → 물리 재생은 LSN 순서대로 하면 되고, 논리 디코딩은 commit 순서로 재정렬한다.
- **용도**: crash recovery(redo) + 물리 스트리밍 복제 + PITR(아카이브) + (`wal_level=logical`이면) logical decoding.

## 부록 B: binlog 상세 (MySQL)

- **정체**: 서버 계층의 **변경 기록 로그**로, 복제와 PITR을 위해 존재한다(엔진 내부 redo log와 별개) [1].
- **구조**: `mysql-bin.000001`, `…002` … 형태의 **바이너리 로그 파일들 + 인덱스 파일**. 각 파일 안은 **이벤트(event)** 의 연속이다 [1].
- **이벤트 예**: `Query_event`(문장), `Table_map_event` + `Write/Update/Delete_rows_event`(행 변경), `Xid_event`(커밋), `Gtid_event`(GTID), `Rotate_event`(파일 전환) 등 [1].
- **포맷**: `STATEMENT`(SQL 문) / `ROW`(행 before·after 이미지, 기본·안전) / `MIXED` [4].
- **좌표**: (파일명, 오프셋) = binlog position, 또는 **GTID** 집합 [1].
- **순서**: binlog는 **commit 순서로** 기록된다(트랜잭션이 commit될 때 그 트랜잭션 단위로 기록). → WAL이 write 순서인 것과 대비되는 핵심 차이.
- **용도**: 복제(binlog 기반 = 논리) + PITR. `binlog_format`, `binlog_row_image`, `sync_binlog` 등으로 제어.

### WAL ↔ binlog 핵심 대비 (로그 자체 관점)

| 항목 | WAL (PG) | binlog (MySQL) |
|---|---|---|
| 계층 | 스토리지 통합(엔진=1) | 서버 계층(엔진 위) |
| 성격 | 물리(블록) | 논리(행/문장) |
| 단위 | WAL 레코드 / 세그먼트(16MB) | event / 로그 파일 |
| 좌표 | **LSN**(바이트 위치) | **binlog position** 또는 **GTID** |
| 순서 | **write(LSN) 순서** (tx 섞임) | **commit 순서** (tx 단위) |
| 1차 목적 | crash recovery (+ 복제 겸용) | 복제 / PITR |
| 복제에서 | 물리 그대로 / 논리 디코딩 | 논리 그대로 |

## 추론 / 유추
- CUBRID의 복제 로그(repl log)가 "crash recovery용 로그"와 별개인지, 같은 로그를 겸하는지에 따라 PG형(겸용)에 가까운지 MySQL형(분리)에 가까운지가 갈린다 — 병렬 applylogdb가 읽는 로그의 성격(물리/논리, 엔진 종속성)을 CUBRID 코드로 확인할 필요가 있다 (← [1], [3]).

## References
[1] Oracle / MySQL. "The Binary Log" (서버 계층 논리 로그, 복제·PITR 용도). MySQL 8.0 Reference Manual, 2025. https://dev.mysql.com/doc/refman/8.0/en/binary-log.html

[2] Oracle / MySQL. "Redo Log" (InnoDB 엔진 내부 물리 로그, crash recovery). MySQL 8.0 Reference Manual, 2025. https://dev.mysql.com/doc/refman/8.0/en/innodb-redo-log.html

[3] PostgreSQL Global Development Group. "30.3. Write-Ahead Logging (WAL)" / "30.4. WAL Internals" (WAL이 crash recovery와 복제를 함께 담당, WAL 레코드·세그먼트·LSN). PostgreSQL 18 Documentation, 2025. https://www.postgresql.org/docs/current/wal-intro.html

[4] Oracle / MySQL. "19.2.1 Replication Formats" (binlog 포맷 STATEMENT/ROW/MIXED). MySQL 8.0 Reference Manual, 2025. https://dev.mysql.com/doc/refman/8.0/en/replication-formats.html
