# C5. dbname lock을 applier 시작할 때 한 번만 잡고 다시 잡지 않음

## 1. 메타
| 항목 | 내용 |
|---|---|
| 등급 | High |
| 상태 | **수정 완료(10-22)**. 수정 전 실측(replica 구성, 3노드 slave 구성)과 수정 후 실측(3노드 slave 구성, 5.3절) 완료. 수정 커밋 `bf8533de3`(7절) |
| 판정 | 확정. ①(시작 단계 대기)과 ②(잠금 없이 씀)를 실측했다. ②의 피해(master가 바뀔 때 적용 순서가 뒤섞임)는 추정. 수정 후에는 단계마다 실제로 적용하는 applier가 소유자로 적히고, 시작 단계에서 멈추는 applier가 없다 |
| 신규/기존 | 신규(develop 대비 회귀). develop은 적용할 트랜잭션마다 잠금을 요청한다 |
| 생기는 구성 | 한 노드에 applier가 둘 이상 뜨는 구성: 3노드 이상, 또는 replica를 둔 구성. 2노드에서는 생기지 않는다 |
| 지적한 리뷰어 | 4명(종합 문서 2절) |
| 코드 기준 | 수정 전 `6ae74828a` (3·4절의 줄 번호, 빌드 2782와 같음). 수정 `bf8533de3` (7절, 빌드 2781-bf8533d) |

## 2. 구성과 dbname lock

### 2.1 한 노드에 applier가 둘 이상 뜨는 이유
각 노드는 다른 노드 중 누가 master가 될지 미리 모른다. 그래서 master가 될 수 있는 노드마다 로그 복사(copylogdb)와 적용(applylogdb)을 한 쌍씩 띄운다(`us_hb_applylogdb_start`, `util_service.c:3518`: `ha_node_list`에서 자기 노드를 뺀 노드마다 하나). 실제로 적용할 내용이 있는 것은 지금 master의 로그뿐이고, 다른 쪽 applier는 대기한다.

replica 구성(youngjun3 master, youngjun4 slave, youngjun2 replica):
```
           youngjun3 (master)                         youngjun4 (slave)
   ┌──────────────────────────────┐          ┌──────────────────────────────┐
   │ cub_server testdb  ← 쓰기    │          │ cub_server testdb            │
   │   └ 로그 (복제할 변경 있음)  │          │   └ 로그 (복제할 변경 없음)  │
   │                              │          │                              │
   │ copylogdb ◀────── youngjun4 로그 ────── │                              │
   │ applylogdb (youngjun4 로그용)│          │ copylogdb ◀── youngjun3 로그 │
   │   └ 적용할 것 없음, 대기     │          │ applylogdb (youngjun3 로그용)│
   └──────────────┬───────────────┘          │   └ youngjun3 변경을 적용    │
                  │ 로그                     └──────────────┬───────────────┘
                  │                                         │ 로그
                  ▼                                         ▼
   ┌─────────────────────────────────────────────────────────────────────┐
   │                        youngjun2 (replica)                          │
   │                                                                     │
   │  copylogdb ─▶ testdb_youngjun3/      copylogdb ─▶ testdb_youngjun4/ │
   │                    │                                    │           │
   │                    ▼                                    ▼           │
   │         applylogdb (applier-3)                applylogdb (applier-4)│
   │          youngjun3 로그를 적용                 youngjun4 로그를 적용 │
   │          (지금 실제로 일하는 쪽)               (적용할 것 없음)     │
   │                    │                                    │           │
   │                    └──────────┐          ┌──────────────┘           │
   │                               ▼          ▼                          │
   │              ┌────────────────────────────────────────┐             │
   │              │ dbname lock                            │             │
   │              │ $CUBRID/var/APPLYLOGDB/testdb          │             │
   │              │ "지금 쓸 차례 = applier-3" (소유자)    │             │
   │              └────────────────────┬───────────────────┘             │
   │                                   ▼                                 │
   │                         cub_server testdb (하나)                    │
   └─────────────────────────────────────────────────────────────────────┘
```

| 구성 | youngjun3 | youngjun4 | youngjun2 |
|---|---|---|---|
| replica (`ha_node_list=youngjun@youngjun3:youngjun4`, `ha_replica_list=youngjun@youngjun2`) | 1개 | 1개 | **2개** |
| 3노드 slave (`ha_node_list=youngjun@youngjun3:youngjun4:youngjun2`) | **2개** | **2개** | **2개** |

### 2.2 dbname lock
- 같은 DB에 쓰는 applier가 둘 이상일 때, 지금 쓸 차례인 applier를 하나로 정한다. master가 바뀌는 순간 이전 master의 남은 로그(꼬리)와 새 master의 로그가 섞여 들어가지 않게 한다.
- 잠금 파일 `$CUBRID/var/APPLYLOGDB/testdb`에 **소유자(pid, db, 로그 경로)**를 적는다(`fileio_lock_la_dbname`, `file_io.c:1539`). 다른 로그 경로가 적혀 있으면 잠금을 얻지 못한다.
- 소유자는 `la_unlock_dbname(clear_owner=true)`로 놓을 때만 지워진다. applier가 그냥 종료할 때(`la_shutdown`)는 지우지 않는다.
- OS 파일 잠금(fcntl)은 잡은 직후 같은 파일을 `fopen`/`fclose`하면서 풀린다(추정, POSIX 규칙). `/proc/locks`에 보이지 않으므로 이 문서의 실측은 파일에 적힌 소유자로 판정했다.

## 3. ① 적용할 것이 없는 applier가 시작 단계에서 멈춤
**예시:** replica youngjun2에 applier가 둘 있습니다.
- **applier-3:** youngjun3 로그용. youngjun3이 master라서 적용할 것이 있습니다.
- **applier-4:** youngjun4 로그용. youngjun4가 slave라서 적용할 것이 없습니다.

applier-3이 먼저 떠서 잠금을 잡은 상황입니다.

### 3.1 applier-4가 시작하는 경로 (브랜치, 수정 전)
```c
/* log_applier.c, la_apply_log_file (applier 시작부터 메인 루프까지) */
  ...
  error = la_get_last_ha_applied_info ();          // apply info 읽기
  ...
10040  error = la_lock_dbname (&la_Info.db_lockf_vdes, la_slave_db_name, la_Info.log_path);
       //  ★ 메인 루프에 들어가기 전에, 적용할 것이 있든 없든 잠금 요청
  ...
  /* start the main loop */
  do
    {
      ... 로그 읽기, 서버에 상태 보고(la_change_state), worker에게 보내기 ...
    }
```
applier-4는 10040행에서 잠금을 요청합니다. 여기서 돌아오지 못하면 메인 루프에 들어가지 못합니다.

### 3.2 잠금 요청이 실패하는 이유: 소유자 확인
```c
/* file_io.c:1539, fileio_lock_la_dbname */
  fp = fopen (lock_path, "r");                     // $CUBRID/var/APPLYLOGDB/testdb
  r = fscanf (fp, format_string, &pid, tmp_db_name, tmp_log_path);
  if (r == 3)
    {
      if (strcmp (db_name, tmp_db_name) || strcmp (log_path, tmp_log_path))
        {                                          // ★ 적힌 소유자의 로그 경로가 내 것과 다르면
          er_set (..., ER_IO_MOUNT_LOCKED, ...);   //   "Unable to mount ... in use"
          result = FILEIO_NOT_LOCKF;               //   실패
          goto error_return;
        }
    }
```
잠금 파일에는 applier-3의 경로(`.../testdb_youngjun3`)가 적혀 있습니다. applier-4의 경로(`.../testdb_youngjun4`)와 다르므로 실패합니다. applier-3이 소유자를 지우기 전까지는 계속 실패합니다.

### 3.3 실패하면 무한 대기 (종료 확인 없음)
```c
/* log_applier.c:8586, la_lock_dbname */
  while (1)
    {
      result = fileio_lock_la_dbname (lockf_vdes, db_name, log_path);
      if (result == FILEIO_LOCKF)
        break;
      LA_SLEEP (3, 0);           // ★ 3초 자고 다시. la_applier_need_shutdown을 보지 않음
    }
```

### 3.4 소유자가 지워지는 때
applier-3은 메인 루프 안에서 이 조건일 때만 소유자를 지웁니다.
```c
/* log_applier.c:10196 부근 (메인 루프) */
  if (la_Info.apply_state == HA_LOG_APPLIER_STATE_DONE
      && final_log_hdr.ha_server_state != HA_SERVER_STATE_ACTIVE      // 상대(youngjun3)가 active가 아님
      && final_log_hdr.ha_server_state != HA_SERVER_STATE_TO_BE_STANDBY)
    {
      clear_owner = true;
      la_unlock_dbname (..., clear_owner);                            // 소유자 지움
    }
```
youngjun3이 master로 살아 있는 동안 이 조건은 거짓입니다. 그래서 applier-4는 **youngjun3이 죽을 때까지** 대기합니다.

### 3.5 실측 (replica 시험, 16:48~16:51)
| 확인 | 결과 |
|---|---|
| applier-4 스택 | `la_lock_dbname`(8604) ← `la_apply_log_file`(10040) |
| 스레드 수 | 3개 (worker를 띄우기 전) |
| applier-4 로그 | 3초마다 `Unable to mount disk volume ".../APPLYLOGDB/testdb" ... in use` |
| SIGTERM | 30초 뒤에도 살아 있음 |
| `cubrid service stop` | 다른 프로세스는 다 내려가는데 applier-4만 남음. applier-3이 종료할 때 소유자를 지우지 않아서(`la_shutdown`은 `clear_owner=false`) 영원히 못 얻음 → kill -9로 정리 |

### 3.6 develop은 왜 안 멈추나
```c
/* develop log_applier.c:5783, la_apply_commit_list (적용할 트랜잭션마다) */
  if (apply->head == NULL || LSA_LE (commit_lsa, &la_Info.last_committed_lsa))
    {
      ...
      return NO_ERROR;           // ★ 적용할 항목이 없으면 여기서 돌아감 → 잠금 요청 안 함
    }
  error = la_lock_dbname (&la_Info.db_lockf_vdes, la_slave_db_name, la_Info.log_path);
```
develop에서 applier-4는 적용할 트랜잭션이 없으므로 `la_lock_dbname`까지 가지 않습니다. 그래서 정상적으로 메인 루프를 돌면서 상태를 보고하고, SIGTERM에도 끝납니다. 같은 무한 대기가 develop에도 있지만, develop에서는 "적용할 것이 있는데 차례가 아닐 때"만 들어가므로 곧 풀립니다.

### 3.7 왜 문제인가
- 끌 수 없습니다. SIGTERM과 `service stop`이 듣지 않고 고아 프로세스로 남습니다.
- 대기하는 동안 서버에 상태를 보고하지 못합니다. 서버는 그 노드의 applier 전부가 DONE이어야 승격하므로(`css_check_ha_log_applier_done`), 승격이 이 applier가 시작을 마칠 때까지 늦어질 수 있습니다(추정, 실측 안 함).
- 얻는 것이 없습니다. 적용할 것이 없는 applier는 잠금이 필요 없습니다.

### 3.8 ①이 나타나는 조건
처음 잠금을 잡은 applier의 상대 노드가 그 순간 master(active)여야 합니다. 그러면 그 applier가 잠금을 계속 쥡니다.
- replica 시험에서는 youngjun2가 마지막에 떴고, 그때 이미 youngjun3이 active였으며, applier-3이 먼저 잡아서 나타났습니다.
- 3노드 시험에서는 기동 순서상 먼저 잡은 applier의 상대가 아직 active가 아니어서 곧 놓았고, 그래서 나타나지 않았습니다.

## 4. ② 한 번 놓은 잠금을 다시 잡지 않아서, 잠금 없이 씀
**예시:** 앞과 같은 replica youngjun2와 두 applier입니다.
- **applier-3:** youngjun3 로그용
- **applier-4:** youngjun4 로그용

### 4.1 잠금을 잡는 곳과 놓는 곳 (브랜치, 수정 전)
```c
/* 잡는 곳: 시작할 때 한 번 (log_applier.c:10040, 메인 루프 전) */
  error = la_lock_dbname (&la_Info.db_lockf_vdes, la_slave_db_name, la_Info.log_path);

  /* start the main loop */
  do
    {
      /* 놓는 곳: 메인 루프 안 (develop과 같은 조건) */
10177  상대 노드 DEAD + 로그가 일정 시간 안 옴          → la_unlock_dbname (clear_owner=true)
10196  DONE + 상대 노드가 ACTIVE/TO_BE_STANDBY 아님    → la_unlock_dbname (clear_owner=true)
10541  is_role_changed                               → la_unlock_dbname (clear_owner=true)

      ... 로그 읽기 → worker에게 보내기 ...            // ★ 여기서 la_lock_dbname을 다시 부르지 않음
    }
```
놓는 곳은 루프 안에 세 군데 있고, 잡는 곳은 루프 밖에 한 군데뿐입니다. 그래서 루프를 도는 동안 한 번 놓으면 그 뒤로는 계속 놓인 상태입니다.

### 4.2 순서대로 보면 (replica 시험, 16:58~17:01)
| 순서 | 사건 | applier-3 | applier-4 | 잠금 소유자 |
|---|---|---|---|---|
| 1 | 처음 | 잠금을 쥐고 적용 | 시작 단계에서 대기 (①) | applier-3 |
| 2 | youngjun3 장애 (16:58:11.34) | DONE, 상대 dead → **놓음** (10196) | | 비어 있음 |
| 3 | 16:58:11.45 | | 잠금 얻고 시작 완료. youngjun4 로그 헤더가 아직 standby라 → **바로 놓음** (10196) | 비어 있음 |
| 4 | youngjun4 master, c5_v 쓰기 (16:59) | | **잠금 없이** 적용 | 비어 있음 |
| 5 | youngjun3 다시 master, c5_w 쓰기 (17:00) | **잠금 없이** 적용 | | 비어 있음 |
| 6 | 끝 (17:01) | 잠금 없음 | 잠금 없음 | 비어 있음 |

3번 이후로 두 applier 모두 다시 잡을 기회가 없습니다. 3노드 slave 시험에서는 기동할 때 이미 1~3번과 같은 일이 생겨서, **세 노드 모두 처음부터 끝까지** 소유자가 비어 있었습니다.

### 4.3 develop은 어떻게 다른가
```c
/* develop log_applier.c:5783, 적용할 트랜잭션마다 */
  if (apply->head == NULL || ...) return NO_ERROR;
  error = la_lock_dbname (&la_Info.db_lockf_vdes, ...);   // ★ 놓여 있으면 여기서 다시 잡음
  ... 항목 적용 ...
```
develop에서는 4번에서 applier-4가 c5_v를 적용하기 직전에 다시 잡고, 5번에서 applier-3이 c5_w 직전에 다시 잡습니다. 잡을 때 다른 applier가 소유자이면 그 applier가 놓을 때까지 기다립니다.

### 4.4 왜 문제인가
잠금이 지키던 것은 **master가 바뀔 때의 적용 순서**입니다. 5번 상황을 예로 들겠습니다.
- youngjun4가 장애로 죽는 순간, applier-4는 youngjun4의 남은 로그(꼬리)를 아직 적용하고 있을 수 있습니다.
- 바로 youngjun3이 master가 되어 새 쓰기를 시작합니다.
- **develop:** applier-3은 잠금을 요청하고, applier-4가 꼬리를 다 적용하고 놓을 때까지 기다립니다. → **youngjun4 꼬리 → youngjun3 새 쓰기** 순서가 지켜집니다.
- **브랜치:** applier-3은 기다리지 않고 바로 씁니다. 두 applier가 youngjun2에 동시에 쓰므로 순서가 보장되지 않습니다.
  - youngjun4 꼬리와 youngjun3 새 쓰기가 **같은 행**을 고쳤다면, 나중에 들어간 쪽 값이 남습니다. 그래서 youngjun2가 master와 달라질 수 있습니다.
  - **키가 겹치면** 적용 오류가 나서 한쪽 트랜잭션이 빠질 수 있습니다.

### 4.5 실측 범위
- **확인한 것:** 1~6번의 소유자 변화와, 소유자가 빈 채로 c5_v와 c5_w를 적용한 것입니다. replica와 3노드 두 구성 모두에서 봤습니다.
- **확인하지 못한 것:** 4번의 피해(순서 뒤섞임)입니다. 오늘은 꼬리가 다 적용된 뒤에 새 쓰기를 해서 겹치지 않았고, 데이터는 맞았습니다(추정으로 남김).

### 4.6 ①과의 관계
원인은 같습니다. "잠금을 시작할 때 한 번만 요청한다"입니다.
- ①은 시작 단계에서 이것이 드러난 것입니다. 적용할 것이 없어도 기다립니다.
- ②는 실행 중에 드러난 것입니다. 놓은 뒤에는 다시 요청하지 않습니다.

develop처럼 "항목이 있는 트랜잭션을 보내기 직전에 요청"으로 되돌리면 둘 다 없어집니다.

## 5. 시험 기록 (10-22)
5.1절과 5.2절은 수정 전(빌드 2782-83976cb), 5.3절은 수정 후(빌드 2781-bf8533d)입니다.

### 5.1 replica 구성 (수정 전)
- conf: 세 노드 `cubrid_ha.conf` = 기준 + `ha_replica_list=youngjun@youngjun2` (md5 `ab72136f`). youngjun2만 `cubrid.conf`의 `ha_mode=replica` (md5 `27c94254`).
- 1차(failover 없음): 3.5절. applier-4가 시작 단계에서 멈추고 SIGTERM을 무시하며 `service stop` 뒤 고아로 남았다.
- 2차(failover와 원복): 4.2절. 하니스 `ha_bench_tool/bin/c5_relock.sh`, 결과 `ha_bench_tool/log/c5_relock_20261022_165806/`(run.log, owner.txt: 2초 간격 소유자 기록).
- 데이터: c5_u, c5_v, c5_w 세 노드 모두 1000행, 합 500500.

### 5.2 3노드 slave 구성 (수정 전)
- conf: 세 노드 `cubrid_ha.conf` = 기준에서 `ha_node_list=youngjun@youngjun3:youngjun4:youngjun2` (md5 `f83545b6`), `cubrid.conf`는 기준(be315c1b).
- 하니스 `ha_bench_tool/bin/c5_3node.sh`, 결과 `ha_bench_tool/log/c5_3node_20261022_171700/`.

| 시점 | youngjun3 | youngjun4 | youngjun2 | 그때 일어난 적용 |
|---|---|---|---|---|
| 기동 직후 (17:17:03) | 비어 있음 | **비어 있음** | applier-3 | |
| c5_a 쓰기 (youngjun3 master) | 비어 있음 | **비어 있음** | applier-3 | youngjun4는 **잠금 없이** c5_a 적용 |
| failover 뒤 (youngjun4 master) | 비어 있음 | 비어 있음 | **비어 있음** | |
| c5_v 쓰기 (youngjun4 master) | (내려가 있음) | 비어 있음 | **비어 있음** | youngjun2는 **잠금 없이** c5_v 적용 |
| 원복 뒤 c5_w 쓰기 (youngjun3 master) | 비어 있음 | (내려가 있음) | **비어 있음** | youngjun2는 **잠금 없이** c5_w 적용 |
| 끝 (17:19) | 비어 있음 | 비어 있음 (다시 뜬 applier) | 비어 있음 | |

- ①은 이 기동에서는 나타나지 않았다(3.8절).
- 데이터: c5_a, c5_v, c5_w 세 노드 모두 1000행, 합 500500.

### 5.3 3노드 slave 구성 (수정 후)
- conf와 하니스는 5.2절과 같습니다. 세 노드에 새로 설치하고 DB를 새로 만들었습니다. 결과 `ha_bench_tool/log/c5_3node_20261022_221334/`.
- 아래 표는 youngjun2(applier-3, applier-4)의 소유자 변화를 수정 전과 나란히 둔 것입니다.

| 시점 | 수정 전 (5.2절) | 수정 후 | 그때 일어난 적용 |
|---|---|---|---|
| 기동 직후, 적용할 것 없음 (22:13:38) | applier-3 (시작하자마자 잡음) | 비어 있음 | 없음 |
| c5_a 쓰기, youngjun3 master (22:13:40) | applier-3 | **applier-3** | applier-3이 c5_a 적용 |
| failover, youngjun3 죽음 (22:13:43) | 비어 있음 | 비어 있음 (applier-3이 놓음) | |
| c5_v 쓰기, youngjun4 master (22:13:55) | **비어 있음** | **applier-4** | applier-4가 c5_v 적용 |
| youngjun4 service stop, youngjun3 master 복귀 (22:14:12) | 비어 있음 | 비어 있음 (applier-4가 놓음) | |
| c5_w 쓰기, youngjun3 master (22:14:45) | **비어 있음** | **applier-3** (다시 잡음) | applier-3이 c5_w 적용 |

- youngjun4도 c5_a를 적용할 때 자기 applier(youngjun3 로그용)가 소유자로 적혔습니다. 수정 전에는 처음부터 끝까지 비어 있었습니다.
- ①: 세 노드의 applier 6개가 모두 스레드 13개(worker를 띄운 상태)로 시작했고, `la_lock_dbname`에서 멈춘 applier는 없었습니다.
- 데이터: c5_a, c5_v, c5_w 세 노드 모두 1000행, 합 500500. 각 노드 DB에 직접 붙어 조회했습니다. 슬레이브 youngjun4·youngjun2의 fail_counter는 0입니다.
- c5_w는 youngjun3에 쓴 22:14:27부터 youngjun2에 들어간 22:14:43까지 17초 늦었습니다. 수정과 관계없는 develop 동작입니다.
  - applier-3은 failover 때 22:13:42.5에 DONE이 되면서 소유자를 지웠습니다. 소유자를 지우는 `la_unlock_dbname(clear_owner=true)`는 지운 뒤 60초를 잡니다(`LA_SLEEP (60, 0)`, develop과 같은 코드).
  - applier-3의 다음 로그는 61초 뒤인 22:14:43.79이고, c5_w는 그 직후 적용됐습니다.
  - 수정 전 시험에서는 failover 뒤 94초가 지나서 c5_w를 써서 이 대기가 드러나지 않았습니다.

### 5.4 시험 중 알게 된 것
- youngjun2는 시스템 시간대가 UTC라 `~/.bashrc`에 `export TZ=Asia/Seoul`을 넣었다. 시간대를 바꾼 뒤에는 apply info의 DB 생성 시각 비교(`la_get_last_ha_applied_info`가 로컬 시각으로 비교)가 어긋나 applier가 `Failed to initialize _db_ha_apply_info`로 시작에 실패했다. 그래서 DB를 새로 만들었다. develop과 같은 코드다.
- 새로 만든 replica는 master 로그를 현재 위치부터 받으므로, 그 전에 만든 테이블은 replica에 없다.

## 6. 판단
- C5는 확정된 결함이고 develop 대비 회귀다.
- ①의 실제 피해는 끌 수 없는 applier와 승격 지연(추정)이다. 데이터에 영향을 주는 것은 ②다.
- ②는 3노드 이상이나 replica 구성에서 결국 항상 나타난다. 3노드 slave 구성에서는 기동 직후부터 모든 노드가 잠금 없이 적용했다.
- 7절의 수정 뒤에는 같은 구성, 같은 순서에서 ①과 ② 모두 나타나지 않았다(5.3절).

## 7. 수정 (`bf8533de3`)
develop처럼 "항목이 있는 트랜잭션을 적용하기 직전에 요청"으로 되돌렸습니다. 병렬 적용에서는 coordinator가 worker에게 보내기 직전이 그 자리입니다.

### 7.1 잡는 곳: worker에게 보내기 직전
```c
/* log_applier.c, la_coordinator_dispatch_task */
  if (task.has_items && LSA_GT (&task.commit_lsa, &la_Info.last_committed_lsa))
    {                                                // develop과 같은 조건: 적용할 항목이 있을 때만
      error = la_lock_dbname (&la_Info.db_lockf_vdes, la_slave_db_name, la_Info.log_path);
      if (error != NO_ERROR)
        return error;
    }
```
- 시작할 때의 호출(수정 전 10040행)은 없앴습니다. 적용할 것이 없는 applier는 잠금을 요청하지 않으므로 ①이 없어집니다.
- 놓은 뒤 다음 트랜잭션을 보낼 때 다시 요청하므로 ②가 없어집니다. 이미 쥐고 있으면 `la_lock_dbname`은 바로 돌아옵니다.
- coordinator만 부르므로 worker는 잠금 상태를 건드리지 않습니다. 수정 전 코드가 시작할 때 한 번만 잡았던 이유가 이것이었고, 이 의도는 그대로 지켜집니다.

### 7.2 기다리는 중에도 종료
```c
/* log_applier.c, la_lock_dbname */
  while (1)
    {
      result = fileio_lock_la_dbname (lockf_vdes, db_name, log_path);
      if (result == FILEIO_LOCKF)
        break;
      if (la_applier_need_shutdown)                  // ★ 추가: SIGTERM이면 기다리지 않고 끝냄
        return ER_FAILED;
      LA_SLEEP (3, 0);
    }
```
다른 applier가 소유자인 동안에는 여전히 기다립니다. 그 사이 SIGTERM이 오면 끝납니다([C4](C4_coordinator_result_wait_ignores_shutdown.md)와 같은 방식).

### 7.3 놓는 곳: 보낸 트랜잭션이 다 끝난 뒤에만
develop은 트랜잭션 하나를 끝까지 적용한 뒤에만 루프로 돌아오므로, 잠금을 놓는 순간 적용 중인 것이 없습니다. 병렬 적용에서는 worker가 아직 적용 중인데 coordinator가 잠금을 놓을 수 있습니다. 그러면 다른 applier가 소유자를 얻어, 이전 master의 꼬리와 새 master의 쓰기가 다시 섞입니다(8절 수정 전 2번 질문).

| 놓는 곳 | 수정 전 조건 | 수정 후 조건 |
|---|---|---|
| 상대 DEAD + 로그가 일정 시간 안 옴 | 그대로 | + `la_coordinator_drain_complete ()` |
| DONE + 상대가 ACTIVE/TO_BE_STANDBY 아님 | DONE 자체가 보낸 트랜잭션이 다 끝나야 됨 | 그대로 |
| `is_role_changed` | 그대로 | + `la_coordinator_drain_complete ()` |

보낸 트랜잭션이 남아 있으면 이번 루프에서는 놓지 않고, 다 끝난 뒤의 루프에서 놓습니다.

### 7.4 C6에 미치는 영향
`is_role_changed`를 바로 처리하지 않고 보낸 트랜잭션이 끝날 때까지 미루면서, [C6](C6_failover_drain_backstop_never_runs.md)의 30초 백스톱 조건(`is_role_changed && !drain_complete`)이 실제로 성립할 수 있게 됐습니다. 수정 전에는 `is_role_changed`를 같은 루프에서 바로 처리하고 지웠기 때문에 성립하지 않았습니다. 백스톱을 정리할지는 C6에서 정합니다.

## 8. 열린 질문
1. ②의 피해(master가 바뀔 때 이전 master의 꼬리와 새 master의 쓰기가 겹쳐 순서가 뒤섞임)를 실측할지. 꼬리를 길게 만든 상태에서 failover와 쓰기를 겹쳐야 한다.
2. ~~병렬 적용에서 "보내기 직전에 잠금"이 develop의 "적용 직전에 잠금"과 같은 순서를 보장하는지.~~ 수정에서 처리했습니다. 놓는 곳 세 군데 모두 보낸 트랜잭션이 다 끝난 뒤에만 놓습니다(7.3절).
3. 소유자를 지운 뒤 60초를 자는 develop 동작(5.3절)은 그 동안 그 applier가 로그를 읽지 않게 만듭니다. master가 금방 돌아오면 그만큼 적용이 늦습니다. develop과 같은 동작이라 이번 범위에서는 고치지 않았습니다.
