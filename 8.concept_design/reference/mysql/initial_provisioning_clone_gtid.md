# MySQL Replica 초기 구축(Provisioning) — Clone Plugin과 GTID Auto-Positioning

> 조사 · 2026-06-04 · 출처: MySQL 8.0 공식 문서 + 2순위 블로그

새 replica는 데이터가 비어 있으므로, (1) 도너의 데이터를 물리적으로 빠르게 적재하고(Clone Plugin), (2) 적재 시점의 복제 좌표(binlog position·`gtid_executed`)를 함께 받아, (3) 그 좌표부터 이후 binlog를 이어 받아 지속 복제로 핸드오프하는 것이 8.0의 표준 흐름이다. GTID auto-positioning(`SOURCE_AUTO_POSITION=1`)을 쓰면 파일·위치 좌표 없이 도너가 알아서 빠진 트랜잭션만 보내준다.

## 1. 초기 구축 문제: 빈 replica를 어떻게 채우고 어디서부터 복제를 시작하나

새 replica에는 소스의 기존 데이터가 없다. 따라서 두 가지를 동시에 해결해야 한다.

- **초기 적재(initial load)**: 소스의 현재 데이터 전체를 replica로 복사한다.
- **복제 시작 좌표(start coordinate)**: "스냅샷이 어느 시점의 것인가"를 정확히 잡아야 한다. 이 좌표가 틀리면 트랜잭션이 누락되거나(데이터 유실) 중복 적용된다(무결성 깨짐). 좌표는 binlog 파일/오프셋, 또는 GTID 집합(`gtid_executed`)으로 표현된다.

핵심은 **"적재된 스냅샷의 끝점"과 "이후 복제가 시작하는 점"이 정확히 맞물려야 한다**는 것이다(핸드오프). 8.0은 이 좌표 추출을 Clone Plugin이 자동으로 해주고, GTID를 쓰면 좌표 매칭 자체를 도너가 자동 계산한다.

## 2. 적재 방법들

### 2-1. Clone Plugin (8.0.17+) — 물리 스냅샷 + 좌표 자동 이전

Clone Plugin은 8.0.17에 도입되었고, **InnoDB 데이터의 물리 스냅샷**을 만든다. 공식 문서는 다음과 같이 정의한다 [1]:

> "Cloned data is a physical snapshot of data stored in InnoDB that includes schemas, tables, tablespaces, and data dictionary metadata. The cloned data comprises a fully functional data directory, which permits using the clone plugin for MySQL server provisioning."

논리 백업과 달리 페이지 단위 물리 복사이므로 대용량에서 훨씬 빠르며, 복사 결과가 곧바로 동작하는 데이터 디렉터리가 된다.

**원격 클론(remote clone)** 흐름:

- recipient(수신측)에서 `CLONE INSTANCE` 문을 실행해 donor(도너)로부터 네트워크로 데이터를 받는다 [2].
  ```sql
  CLONE INSTANCE FROM 'user'@'host':port IDENTIFIED BY 'password'
    [DATA DIRECTORY [=] 'clone_dir'] [REQUIRE [NO] SSL];
  ```
- recipient는 도너가 `clone_valid_donor_list`에 등록돼 있어야 한다. 문서: "You can only clone data from a host on the valid donor list." [3]
- `DATA DIRECTORY` 절을 생략하면 recipient의 기존 데이터가 교체된다. 문서 [3]:
  > "a cloning operation removes user-created data (schemas, tables, tablespaces) and binary logs from the recipient data directory, clones the new data to the recipient data directory, and automatically restarts the server afterward."
- 권한: 도너 측 사용자는 `BACKUP_ADMIN`, recipient 측 사용자는 `CLONE_ADMIN`이 필요하다. 문서: "On the recipient, the clone user requires the CLONE_ADMIN privilege ... The CLONE_ADMIN privilege includes BACKUP_ADMIN and SHUTDOWN privileges implicitly." [4] 두 인스턴스 모두에 `clone` 플러그인이 설치돼 있어야 한다.

**복제 좌표 자동 이전(핵심).** 클론은 데이터뿐 아니라 복제 시작에 필요한 좌표를 함께 가져온다. 문서 [5]:

> "both the binary log position (filename, offset) and the gtid_executed GTID set are extracted and transferred from the donor MySQL server instance to the recipient."

이전된 좌표는 recipient에서 다음으로 확인한다 [5]:
```sql
SELECT BINLOG_FILE, BINLOG_POSITION FROM performance_schema.clone_status;
SELECT @@GLOBAL.GTID_EXECUTED;
```

**복사되는 것 / 안 되는 것**:

- 복사됨: 복제 메타데이터 저장소가 테이블(8.0 기본 `TABLE` 설정)일 때 `mysql.slave_master_info`(8.0.17+), `mysql.slave_relay_log_info`·`mysql.slave_worker_info`(8.0.19+) [5].
- **복사 안 됨**: **binary log와 relay log(파일로 보관되는 로그)**. 문서는 "Binary logs and relay logs (held in files)"가 복사되지 않으며, 메타데이터 저장소가 deprecated `FILE` 설정이면 그것도 복사되지 않는다고 명시한다 [5]. 또한 클론은 **서버 설정을 복사하지 않는다**: "The clone plugin does not support cloning of MySQL server configurations. The recipient MySQL server instance retains its configuration, including persisted system variable settings." [6]

즉 Clone은 "데이터 + 좌표"만 옮기고, 그 좌표 **이후**의 변경은 일반 binlog 복제로 따라잡는다(2-3절 핸드오프).

**주요 제약** [6]:

- InnoDB만 클론된다. "The clone plugin only clones data stored in InnoDB. ... MyISAM and CSV tables stored in any schema including the sys schema are cloned as empty tables." → MyISAM/CSV는 **빈 테이블**로 복사되므로 별도 처리가 필요하다.
- 한 번에 한 인스턴스만 클론 가능: "Only a single MySQL instance can be cloned at a time."
- 도너·recipient는 **동일 시리즈** 버전이어야 한다(8.0↔8.4 불가). "An instance cannot be cloned from a different MySQL server series." 8.0.37 이전에는 point release까지 일치해야 했다 [6].
- 원격 클론에서 X Protocol 포트(`mysqlx_port`)는 지원되지 않는다 [6].
- DDL: 8.0.27 이전에는 도너·recipient 모두 클론 중 DDL(및 `TRUNCATE TABLE`) 금지. 8.0.27부터 도너 측 동시 DDL이 기본 허용되며 `clone_block_ddl`로 제어한다. 동시 DML은 항상 허용 [6].

### 2-2. mysqldump / 논리 백업 + binlog position (전통적 방법)

논리 백업으로 적재하고, 백업 시점의 binlog 좌표를 수동으로 잡아 복제를 시작하는 고전적 방식이다. `mysqldump --single-transaction`으로 일관 스냅샷을 뜨면서 좌표를 기록하고, recipient에서 그 좌표(`SOURCE_LOG_FILE`/`SOURCE_LOG_POS` 또는 `gtid_purged`)를 설정한 뒤 복제를 시작한다. 대용량에서는 Clone보다 느리지만, 스토리지 엔진/버전 제약에서 자유롭고 부분 적재가 쉽다. (세부 절차는 본 문서 범위 밖 — 미해결 참조.)

### 2-3. GTID Auto-Positioning (`SOURCE_AUTO_POSITION=1`) — 좌표 매칭 자동화

GTID는 파일-오프셋 좌표를 대체한다. 문서 [7]:

> "GTIDs replace the file-offset pairs previously required to determine points for starting, stopping, or resuming the flow of data between source and replica."

설정은 파일/위치 없이 [7]:
```sql
CHANGE REPLICATION SOURCE TO SOURCE_HOST='...', SOURCE_PORT=..., SOURCE_AUTO_POSITION=1 FOR CHANNEL '...';
START REPLICA ... FOR CHANNEL '...';
```
`SOURCE_AUTO_POSITION`(8.0.23 이전 `MASTER_AUTO_POSITION`)은 기본 비활성이며 [7], `SOURCE_LOG_FILE`/`SOURCE_LOG_POS`는 지정하지 않는다.

**핸드셰이크 동작** [7]:
1. replica가 자신이 이미 가진 트랜잭션 집합을 도너에 보낸다. 이 집합은 `@@GLOBAL.gtid_executed`(적용 완료)와 `replication_connection_status`의 `RECEIVED_TRANSACTION_SET`(수신했으나 미적용)의 합집합이다.
2. 소스는 보내진 GTID 집합에 포함되지 않은 트랜잭션만 골라 보낸다. 시작 binlog 파일은 각 파일 헤더의 `Previous_gtids_log_event`를 최신부터 거꾸로 검사해 결정한다.
3. 소스는 그 파일부터 현재까지 읽으며, replica가 빠뜨린 GTID만 전송하고 이미 가진 것은 건너뛴다.

따라서 **파일·위치 좌표가 불필요**하다: "with GTIDs the replica does not need this nonlocal data." [7] failover 시에도 새 소스를 향해 같은 `SOURCE_AUTO_POSITION=1`로 붙기만 하면 빠진 트랜잭션만 재수신되므로 토폴로지 전환이 단순해진다.

소스 코드에서도 이 좌표 협상 경로가 확인된다. 빠진 GTID는 `report_missing_purged_gtids()`에서 "도너가 잃어버린 GTID(`lost_gtids`) 중 replica가 가진 것을 뺀 차집합"으로 계산되며(`sql/binlog.cc:9170-9172`), 그 결과가 비어 있지 않으면 `ER_SOURCE_HAS_PURGED_REQUIRED_GTIDS`로 보고된다(같은 파일 9205행). auto_position 모드의 GTID 일관성 검사 분기는 `sql/rpl_binlog_sender.cc:687-700`에 있다.

## 3. 초기 적재 → 지속 복제 핸드오프 (좌표 일치)

흐름을 묶으면:

1. **적재**: recipient에서 `CLONE INSTANCE`로 도너 데이터를 받는다. 완료 시 도너의 `gtid_executed`가 recipient에 적용되고 binlog 좌표는 `clone_status`에 기록된다. recipient는 자동 재시작된다(named directory가 아닌 경우) [3][5].
2. **채널 설정**: GTID 모드(`gtid_mode=ON`)면 `SOURCE_AUTO_POSITION=1`로 채널을 만들고 `START REPLICA`만 하면 된다. recipient의 `gtid_executed`가 이미 스냅샷 끝점을 가리키므로, 핸드셰이크에서 그 이후 트랜잭션만 자동 요청된다. 문서: GTID auto-positioning 채널은 클론 후 "can resume automatically when the channel is started" [5].
3. **이어받기**: 도너는 누락분만 전송, recipient는 따라잡은 뒤 정상 복제를 지속한다.

**GTID를 안 쓰는 binlog 위치 방식의 버전 차이** [5]:
- 8.0.17–8.0.18: binlog 위치가 recipient에 적용되지 않고 `clone_status`에만 기록 → 채널을 **수동** 설정해야 하며, 자동 시작 채널로 두면 안 된다.
- 8.0.19+: binlog 위치가 recipient에 적용되고, 클론된 relay log 정보로 relay log recovery를 시도한다. 단일 스레드(`replica_parallel_workers=0`)는 보통 자동 성공하지만, 다중 스레드(`>0`)는 recovery가 실패하기 쉬워 **수동 설정**이 필요하다. 이 경우 좌표는 `clone_status`의 `BINLOG_FILE`/`BINLOG_POSITION`을 읽어 `SOURCE_LOG_FILE`/`SOURCE_LOG_POS`로 지정한다.

## 4. 일관 스냅샷 / `gtid_purged` 주의점

- **binlog 보존이 핸드오프의 전제**: 클론 시점과 복제 시작 시점 사이에, recipient가 도너를 따라잡는 데 필요한 binlog가 purge되면 안 된다. 문서 [5]:
  > "The binary logs required for the recipient to catch up to the donor must not be purged between the time that the data is cloned and the time that replication is started. If the required binary logs are not available, a replication handshake error is reported."
  → 클론 후 **지연 없이** replica를 토폴로지에 붙이고, 소스의 `binlog_expire_logs_seconds`를 충분히 길게 둔다 [7].

- **`gtid_purged`로 인한 시작 실패**: 필요한 트랜잭션이 소스 binlog에서 purge되었거나 `gtid_purged`에 들어가 있으면, 소스는 `ER_SOURCE_HAS_PURGED_REQUIRED_GTIDS`를 보내고 복제가 시작되지 않는다. 누락 GTID는 에러 로그의 `ER_FOUND_MISSING_GTIDS` 경고에 나열된다 [7]. 이때는 자동 복구가 불가능하며, 누락 트랜잭션을 다른 소스에서 받거나 더 최신 백업으로 replica를 재생성해야 한다 [7].

- **분기(divergence) 감지**: replica가 소스 UUID의 트랜잭션을 가졌으나 소스에 그 기록이 없으면 `ER_REPLICA_HAS_MORE_GTIDS_THAN_SOURCE`가 발생한다(주로 소스가 `sync_binlog=1`이 아닐 때 크래시로 발생). 수동 점검·해소가 필요하다 [7].

- **논리 백업 시 일관 스냅샷**: mysqldump 경로에서는 일관 스냅샷과 그 시점 `gtid_executed`/`gtid_purged` 설정이 필수다(2-2절). Clone 경로는 이 좌표 추출을 플러그인이 대신 해준다.

## 정리

- 8.0의 빠른 provisioning 표준은 **Clone Plugin(물리 스냅샷) + GTID auto-positioning**이다. 클론이 데이터와 함께 `gtid_executed`·binlog 좌표를 자동 이전하고, `SOURCE_AUTO_POSITION=1` 채널이 그 좌표 이후 누락 트랜잭션만 자동 수신해 지속 복제로 매끄럽게 핸드오프한다.
- 클론은 **InnoDB만, binlog/relay log·서버 설정은 복사하지 않으며**, 동일 시리즈 버전·`clone_valid_donor_list`·`CLONE_ADMIN`/`BACKUP_ADMIN` 권한을 요구한다.
- GTID auto-positioning은 파일·위치 좌표를 없애 failover를 단순화하지만, **필요 binlog가 purge되면 복구 불가**(`ER_SOURCE_HAS_PURGED_REQUIRED_GTIDS`)이므로 클론 직후 신속히 복제를 붙이고 binlog 보존 기간을 넉넉히 둬야 한다.
- 소스 코드상 누락 GTID 계산(`lost_gtids − slave_executed`)과 에러 보고 경로가 문서 설명과 일치한다(`binlog.cc:9166-9205`, `rpl_binlog_sender.cc:687-700`).

## 미해결

- mysqldump/논리 백업 경로의 구체적 좌표 추출·`gtid_purged` 설정 절차(예: `--source-data`, `--set-gtid-purged`)는 본 조사에서 1차 문서로 직접 확인하지 않았다 — 별도 조사 필요.
- 8.0.27+의 `clone_block_ddl` 동작이 recipient 측에도 동일하게 적용되는지(도너 한정 표현이 있음)는 공식 문서 추가 확인이 필요하다.
- 클론된 relay log recovery가 다중 스레드 replica에서 "likely fails"라고만 기술되어, 실패 판정의 정확한 조건은 문서에 명시되지 않았다.

## References

[1] MySQL 8.0 Reference Manual — 7.6.7 The Clone Plugin. https://dev.mysql.com/doc/refman/8.0/en/clone-plugin.html

[2] MySQL 8.0 Reference Manual — 7.6.7.3 Cloning Remote Data (CLONE INSTANCE 구문). https://dev.mysql.com/doc/refman/8.0/en/clone-plugin-remote.html

[3] MySQL 8.0 Reference Manual — 7.6.7.3 Cloning Remote Data (clone_valid_donor_list, recipient 데이터 교체·재시작). https://dev.mysql.com/doc/refman/8.0/en/clone-plugin-remote.html

[4] MySQL 8.0 Reference Manual — 7.6.7.3 Remote Cloning Prerequisites (BACKUP_ADMIN / CLONE_ADMIN). https://dev.mysql.com/doc/refman/8.0/en/clone-plugin-remote.html

[5] MySQL 8.0 Reference Manual — 7.6.7.7 Cloning for Replication (좌표 이전, 복사 제외 항목, binlog 보존). https://dev.mysql.com/doc/refman/8.0/en/clone-plugin-replication.html

[6] MySQL 8.0 Reference Manual — 7.6.7.9 Clone Plugin Limitations (InnoDB 한정, 버전 호환, 설정 미복사, DDL). https://dev.mysql.com/doc/refman/8.0/en/clone-plugin-limitations.html

[7] MySQL 8.0 Reference Manual — 19.1.3.3 GTID Auto-Positioning (핸드셰이크, ER_SOURCE_HAS_PURGED_REQUIRED_GTIDS, gtid_purged). https://dev.mysql.com/doc/refman/8.0/en/replication-gtids-auto-positioning.html

[8] MySQL source 8.0.46 — `sql/binlog.cc:9166-9205` (`report_missing_purged_gtids`), `sql/rpl_binlog_sender.cc:687-700` (auto_position GTID 검사).

[9] Percona Blog — Provisioning Replication With Clone Plugin (2순위, 실무 절차 참고). https://www.percona.com/blog/provisioning-replication-with-clone-plugin/

[10] Mydbops Blog — MySQL 8.0 Clone Plugin & Its Internal Process (2순위, 클론 내부 동작 참고). https://www.mydbops.com/blog/mysql-8-0-clone-plugin-and-its-internal-process
