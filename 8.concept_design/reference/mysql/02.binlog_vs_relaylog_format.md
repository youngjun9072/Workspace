# 코드 분석: binlog과 relay log는 같은 형식인가? (MySQL 8.0.46)

> 코드 분석 문서 · 분석 시점 2026-06-04
> 출처: MySQL 8.0.46 로컬 소스(직접 확인, 1차 근거) + 공식 매뉴얼 "The Relay Log"
> 결론: **같은 형식이다.** 같은 `MYSQL_BIN_LOG` 클래스 + 같은 `Log_event` 포맷을 쓰며, relay log는 앞머리에 relay 전용 bookkeeping 이벤트만 더 붙는다.

## 요약
- binlog과 relay log는 **같은 `MYSQL_BIN_LOG` 클래스가 기록**한다 — `is_relay_log` 플래그 하나로만 구분(`sql/binlog.h:328`).
- 데이터 이벤트는 **동일한 `Log_event` 이벤트 포맷**이라 **둘 다 `mysqlbinlog`로 읽힌다** [공식].
- 차이는 relay log 파일 앞머리의 **relay 전용 헤더 이벤트**(relay 자신의 FDE + master를 가리키는 Rotate + master의 FDE)뿐(`sql/binlog_reader.h:426–431`).

## 본문

### 1. 배경 — 왜 확인하나

MySQL 복제에서 replica의 I/O thread는 source의 binlog 이벤트를 받아 **relay log**에 저장하고, SQL/coordinator thread가 relay log를 읽어 적용한다. "relay log가 binlog과 같은 형식인가?"는 relay log를 binlog 도구로 다룰 수 있는지, 변환 비용이 있는지와 직결된다.

### 2. 증거 1 — 같은 클래스가 둘 다 기록한다 (가장 확정적)

`MYSQL_BIN_LOG` 클래스에 **`bool is_relay_log;`** 멤버가 있다 (`sql/binlog.h:328`).

```cpp
// sql/binlog.h (요지)
class MYSQL_BIN_LOG : public TC_LOG {
  ...
  bool is_relay_log;   // :328  ← 이 인스턴스가 relay log인지 binary log인지
  ...
};
```

- **바이너리 로그**와 **relay log**가 **동일한 `MYSQL_BIN_LOG` 클래스의 인스턴스**이고, `is_relay_log` 플래그로만 구분된다(예: 쓰기 경로에서 `assert(is_relay_log)` :473 등 분기).
- → **쓰기 코드·이벤트 직렬화 경로가 동일** → 이벤트 포맷이 같을 수밖에 없다.

### 3. 증거 2 — relay log 파일 구조 (relay 전용 prefix만 추가)

`sql/binlog_reader.h:426–431` 주석이 relay log 파일 형식을 명시한다:

```text
Relay log's format looks like:
  Format_description_event   : relay log 자신의 FDE
  Previous_gtid_event
  [Rotate_event]             : (relay 전용) master 로그 파일·위치를 가리킴 (회전 시 없을 수 있음)
  Format_description_event   : master의 FDE
  ... 이후: 실제 이벤트들 (binlog과 동일한 Log_event)
```

- 즉 relay log = **앞머리에 relay 전용 헤더 이벤트**(relay FDE → Previous_gtid → [Rotate] → master FDE) + **그 뒤로는 source binlog과 동일한 `Log_event` 들**.
- reader가 master의 FDE("3rd or 4th event")를 찾아 그 포맷으로 이후 이벤트를 해석한다 → 데이터 이벤트는 source binlog 이벤트 그대로.

### 4. 그래서 차이는?

| 항목 | binary log | relay log |
|---|---|---|
| 기록 클래스 | `MYSQL_BIN_LOG` | **같은** `MYSQL_BIN_LOG`(`is_relay_log=true`) |
| 데이터 이벤트 포맷 | `Log_event` | **동일** |
| 앞머리 | 자신의 FDE + Previous_gtid | relay FDE + Previous_gtid + **[Rotate→master] + master FDE** |
| 도구 | `mysqlbinlog` | **`mysqlbinlog`로 동일하게 읽힘** [공식] |
| 성격 | source의 durable 로그 | replica 로컬·임시(적용 후 자동 purge) |
| 이름 | `mysql-bin.NNNNNN` | `<host>-relay-bin.NNNNNN` |

### 5. mysqlbinlog 호환

공식 매뉴얼 "The Relay Log"도 "relay log는 binary log와 같은 포맷이며 `mysqlbinlog`로 읽을 수 있다"고 명시한다 — 소스 증거(같은 클래스·같은 이벤트)와 일치.

## 결론
> binlog과 relay log는 **동일한 `MYSQL_BIN_LOG` 클래스 + 동일한 `Log_event` 포맷**을 쓴다(소스 확정). relay log는 앞머리에 **relay 전용 bookkeeping 이벤트(자기 FDE + master를 가리키는 Rotate + master FDE)** 만 더 붙을 뿐, **데이터 이벤트는 source binlog과 그대로 동일**하다. 따라서 변환 없이 받아 적고(I/O thread), 둘 다 `mysqlbinlog`로 읽힌다.

## References
[1] MySQL Source Code (로컬, 8.0.46). `sql/binlog.h` — `MYSQL_BIN_LOG::is_relay_log` :328(단일 클래스가 binary log·relay log 양쪽 담당), :473 분기. `sql/binlog_reader.h` :426–431(relay log 파일 구조: relay FDE + Previous_gtid + [Rotate] + master FDE + 이벤트).

[2] Oracle / MySQL. "The Relay Log" (relay log는 binary log와 같은 포맷, `mysqlbinlog`로 읽힘, relay 전용 이벤트·자동 purge). MySQL 8.0 Reference Manual, 2025. https://dev.mysql.com/doc/refman/8.0/en/relay-log.html
