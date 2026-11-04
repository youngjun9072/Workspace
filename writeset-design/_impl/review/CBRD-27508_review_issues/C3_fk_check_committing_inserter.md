# C3. 자식 INSERT의 FK 검사가 커밋 도중인 부모 inserter를 기다리지 않아 slave에서 자식 행이 사라짐

> [!NOTE]
> **현재 상태 (2026-11-02, PR 브랜치 HEAD 9b2dd61b5 기준)**
> - 브랜치 수정(db599ab64 → 현재 f7078fe07, 행 경로 d1d02b9e4 → 8a23bb8f6, unique 경로 79268ae56·3269e5493 → 5ebe894ef)은 11-01 develop 병합 3b3e37e16에서 develop CBRD-27034(ef4e7e812)로 대체됐다. `btree_is_mvccid_committing`과 ROW/UNIQUE WAIT trace는 지금 코드에 없다.
> - 지금은 develop의 `logtb_is_active_other_mvccid`가 커밋 중인 트랜잭션의 MVCCID self-lock을 기다린다. writeset은 그 self-lock이 풀리기 전에 게시를 끝낸다(01 5.3절).
> - 787defb50(11-01): RETAIN LOCK 커밋에서 self-lock을 일찍 풀던 브랜치 코드를 빼고 develop과 같게 했다.


## 1. 메타
| 항목 | 내용 |
|---|---|
| 등급 | High (종합 문서의 Medium에서 올림, 7절) |
| 상태 | 수정 커밋 `db599ab64`(10-21, 1차 `d78ee1410`과 보완 `cef2bb122`를 접음. 접기 전 기록: 브랜치 `backup/c3-before-fold-20261021`). 런타임 검증 통과(10,000라운드 위반·유실 0, 10.2절), 회귀 시험(unique, fk_multi, F1, F4) 통과(10.3절) |
| 판정 | HA 런타임 재현으로 확정(10-21 14:42). 수정 전에는 2,000라운드 중 582건이 slave에서 유실됨 |
| 신규/기존 | 커밋 도중의 틈과 inverted는 기존 문제다. develop의 CBRD-26942(`741734a8f`)부터 있었다(develop 빌드 재현은 안 함). missed는 신규다. 병렬 적용에서만 드러난다 |
| 관련 | sq_uniq 근본원인(10-19)과 같은 틈이다. 행 수정 경로는 `d1d02b9e4`, unique 검사의 `DELETED` 분기는 `79268ae56`에서 이미 막았다. todo `develop - cascade 동시 INSERT orphan`(기존 Jira 케이스 A)은 같은 FK 경로의 다른 문제다 |
| 지적한 리뷰어 | 7명(종합 문서 2절) |

## 2. 용어와 예시

### 2.1 예시
문서 전체에서 다음 예시 하나만 쓴다.

```sql
CREATE TABLE c3_p (id INT PRIMARY KEY);                                          -- 부모
CREATE TABLE c3_c (id INT PRIMARY KEY, pid INT, FOREIGN KEY (pid) REFERENCES c3_p (id));  -- 자식
```

| 이름 | 하는 일 |
|---|---|
| T1 | `INSERT INTO c3_p VALUES (7)` 후 커밋 (부모) |
| T2 | `INSERT INTO c3_c VALUES (7, 7)` 후 커밋 (자식. FK 검사로 부모 7을 찾음) |

master에서 T1이 먼저 일어나므로, slave도 T1을 T2보다 먼저 적용해야 한다.

### 2.2 master의 커밋 단계 (`log_commit_local`, `log_manager.c`, `ae19759c4` 기준)
| 단계 | 행 | 하는 일 |
|---|---|---|
| ① MVCC 완료 | 5562 `logtb_complete_mvcc` | 이때부터 다른 트랜잭션에게 T1의 행이 "커밋된 행"으로 보인다 |
| ② 커밋 기록·publish | 5602 `wset_find_dependency_from_history` → 5604 `log_append_repl_info_and_commit_log` → 5606 `wset_publish_commit_to_history` | 라벨을 정하고, 커밋 레코드를 기록하고(커밋 LSA가 이때 정해짐), 자기 키를 history에 올린다 |
| ③ 잠금 해제 | 5615 `lock_unlock_all` | MVCCID self-lock을 포함한 잠금을 푼다 |

①과 ③ 사이를 **커밋 도중의 틈**이라 한다. 이 틈에서 T1의 행은 이미 보이지만, 커밋 레코드와 키 publish는 아직 끝나지 않았다. ②의 복제 레코드 기록이 대부분의 시간을 차지하므로, 트랜잭션이 클수록 틈이 넓다.

### 2.3 부모 트랜잭션의 세 상태
| 상태 | 시점 | 자식 T2가 기다려야 하나 |
|---|---|---|
| 활성 | ① 이전 | 예 |
| 커밋 중 | ① 이후 ~ ③ 이전 | **예** (커밋 레코드와 publish가 아직 없음) |
| 커밋 끝남 | ③ 이후 | 아니요 |

### 2.4 CBRD-26942 이후의 잠금
CBRD-26942(`741734a8f`, develop) 이후 INSERT는 새 행에 X 잠금을 걸지 않는다. 대신 자기 MVCCID에 X self-lock을 잡고 ③에서 푼다. 그래서 T1이 "커밋 중"일 때 T2가 부모 7의 **행**에 S 잠금을 요청하면 막히지 않고 바로 허용된다. T2를 멈출 수 있는 것은 T1의 **MVCCID self-lock**뿐이다.

### 2.5 결과 분류
| 분류 | 뜻 |
|---|---|
| ok | T2의 커밋이 로그에서 T1 뒤에 있고, T2의 라벨이 T1의 커밋 이상 |
| inverted | T2의 커밋이 로그에서 T1보다 **앞** |
| missed | T2의 커밋은 T1 뒤에 있지만, T2의 라벨이 T1을 **놓침**(T1의 커밋보다 작음) |

## 3. 문제 위치
코드는 수정 전 `ae19759c4` 기준이다.

### 3.1 FK 검사 코드 (`btree.c` `btree_key_find_and_lock_unique_of_unique`)
T2의 FK 검사는 `locator_check_foreign_key`(locator_sr.c:4033) → `xbtree_find_unique (S_SELECT_WITH_LOCK)`(4143) → `btree_key_find_and_lock_unique`를 거쳐 이 함수로 온다. 함수는 부모 7의 행을 찾아 MVCC 상태(`satisfies_delete`)를 보고, 행에 S 잠금을 잡는다.

```c
27465  satisfies_delete = mvcc_satisfies_delete (thread_p, &mvcc_header);   // 부모 7의 상태: 이 시점에 T1이 활성이면 INSERT_IN_PROGRESS,
27466  switch (satisfies_delete)                                             //               커밋 중이거나 커밋 끝났으면 CAN_DELETE
27467    {
27468    case DELETE_RECORD_INSERT_IN_PROGRESS:
27469    case DELETE_RECORD_DELETE_IN_PROGRESS:
27476      if (satisfies_delete == DELETE_RECORD_INSERT_IN_PROGRESS)
27477        {
27479          MVCCID insert_mvccid = BTREE_MVCC_INFO_INSID (&mvcc_info);
27480          if (btree_is_active_other_inserter (thread_p, insert_mvccid))   // T1이 지금도 활성인가 (다시 확인)
27481            {
27482              return btree_key_wait_for_insert_mvccid (...);            // 활성: self-lock을 기다림 (정상)
27484            }
27485          /* No active inserter (e.g. our own in-progress insert) -- fall through to the row-lock path. */
                                                                             // ★ (B) T1이 그사이 커밋 중이 되어도 여기로 내려감
27486        }
27490      [[fallthrough]];
27491    case DELETE_RECORD_CAN_DELETE:                                      // ★ (A) T1이 커밋 중이면 처음부터 여기로 옴
27494      if (!OID_ISNULL (&find_unique_helper->locked_oid)) { ... return NO_ERROR; }
                                                                             // ★ (A)(B) 공통: T1이 커밋 중인지 확인하는 코드가 없음
27508      try_cond_lock = (satisfies_delete == DELETE_RECORD_CAN_DELETE);
27510      error_code = btree_key_lock_object (...);                          // ★ (C) 행 S 잠금: T1이 행 잠금이 없어 바로 허용 → FK 검사 통과
```

| 표시 | 문제 |
|---|---|
| **(A)** 27491 | T1이 커밋 중이면 `mvcc_satisfies_delete`는 `CAN_DELETE`를 돌려준다. 이 분기는 "커밋 중"과 "커밋 끝남"을 구분하지 않는다 |
| **(B)** 27480-27485 | T2가 `INSERT_IN_PROGRESS`를 본 직후 T1이 ①을 지나면, 27480의 재확인은 "활성 아님"을 돌려주고 대기하지 않는다. 주석은 이 경우를 "자기 자신의 INSERT"로만 가정한다. 27480 자체(활성이면 대기)는 맞다. 문제는 활성이 아닐 때 "커밋 중"을 따로 보지 않고 내려보내는 것이다 |
| **(C)** 27510 | (A)나 (B)로 내려온 S 잠금 요청은 2.4절 이유로 바로 허용된다. 그래서 T2는 T1의 틈 안에서 FK 검사를 통과한다 |

`_of_non_unique`(27824행~)도 같은 구조다. 지운 트랜잭션이 커밋 중인 경우(`DELETED` 분기, 27552행)는 `79268ae56`에서 이미 대기하도록 고쳤다. 이번 문제는 그 대칭인 "넣은 트랜잭션" 쪽이 빠진 것이다.

### 3.2 slave에서 행이 버려지는 코드 (`locator_sr.c` `locator_check_foreign_key`)
```c
4142  ret =
4143    xbtree_find_unique (thread_p, &local_btid, S_SELECT_WITH_LOCK, key_dbvalue, &part_oid, &unique_oid, true);
4144  if (ret == BTREE_KEY_NOTFOUND)
4145    {
4149      er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_FK_INVALID, ...);
4151      error_code = ER_FK_INVALID;                                        // 오류 코드를 먼저 설정
4162      if (LOG_CHECK_LOG_APPLIER (thread_p))
4164        continue;                                                        // applier는 "넘긴다"는 의도지만 error_code를 지우지 않음
...
4194  return error_code;                                                     // → ER_FK_INVALID(-922)로 나감
```

종합 문서는 4162-4164행의 `continue`를 근거로 "applier는 FK 위반을 넘겨 최종 상태가 같아진다"고 보고 유실 주장을 기각했다. 실제로는 오류 코드가 남아 applier에서도 INSERT가 -922로 실패한다. develop에도 같은 코드가 있다.

## 4. 수정 전 동작 (타임라인)
열의 뜻: "master에서 보이는 것"은 다른 트랜잭션이 볼 수 있는 부모 7과 자식 (7, 7)이다. "로그의 COMMIT 순서"는 커밋 레코드가 로그에 기록된 순서다.

### 4.1 inverted: 경로 (A)
| 시각 | T1 (`INSERT c3_p 7`) | T2 (`INSERT c3_c (7, 7)`) | master에서 보이는 것 | 로그의 COMMIT 순서 |
|---|---|---|---|---|
| t0 | INSERT 실행. 행 잠금 없이 MVCCID self-lock만 잡음 | | 부모 7 없음 (T1 활성) | |
| t1 | COMMIT 시작, ① MVCC 완료 | | **부모 7 있음** ← T1 데이터 반영 시점 | |
| t2 | 커밋 중 (② 전) | INSERT 실행. FK 검사가 부모 7을 `CAN_DELETE`로 보고(A) 행 S 잠금 → **바로 허용**(C) | 부모 7 있음 | |
| t3 | 커밋 중 (② 전) | COMMIT: ① → ② 라벨(history에 T1 없음), 커밋 기록, publish → ③ | 부모 7, 자식 (7, 7) | **T2** |
| t4 | ② 라벨, 커밋 기록, publish | | | T2, **T1** |
| t5 | ③ 잠금 해제 | | | T2, T1 |

- 데이터 반영 순서는 T1(t1) → T2(t3)이고, master 데이터는 맞다.
- 커밋 기록 순서는 T2(t3) → T1(t4)로 뒤집혔다.

### 4.2 missed: 경로 (A), T2의 라벨 조회가 T1의 publish보다 앞섬
| 시각 | T1 | T2 | master에서 보이는 것 | 로그의 COMMIT 순서 |
|---|---|---|---|---|
| t0 | INSERT 실행 | | 부모 7 없음 | |
| t1 | ① MVCC 완료 | | 부모 7 있음 | |
| t2 | 커밋 중 (② 전) | INSERT 실행. FK 검사 바로 통과 (4.1과 같음) | 부모 7 있음 | |
| t3 | 커밋 중 (② 전) | COMMIT: ① → ② 라벨: REF(7)로 history를 조회하지만 T1의 WRITE(7)는 아직 publish 전 → **못 찾음** | 부모 7, 자식 (7, 7) | |
| t4 | ② 라벨, 커밋 기록, publish | | | **T1** |
| t5 | | ② 커밋 기록(라벨에 T1 없음), publish | | T1, **T2** |
| t6 | ③ 잠금 해제 | ③ 잠금 해제 | | T1, T2 |

- 커밋 기록 순서는 T1 → T2로 맞지만, T2의 라벨에는 T1이 없다.
- 라벨 조회(②의 `wset_find_dependency_from_history`)와 커밋 레코드 기록은 서로 다른 시점이라 이 순서가 생긴다.

### 4.3 경로 (B): `INSERT_IN_PROGRESS`를 본 직후 T1이 ①을 지남
| 시각 | T1 | T2 | master에서 보이는 것 | 로그의 COMMIT 순서 |
|---|---|---|---|---|
| t0 | INSERT 실행 | | 부모 7 없음 | |
| t1 | | INSERT 실행. FK 검사가 부모 7을 `INSERT_IN_PROGRESS`로 봄 (27465) | 부모 7 없음 | |
| t2 | COMMIT 시작, ① MVCC 완료 | | 부모 7 있음 | |
| t3 | 커밋 중 (② 전) | 27480 재확인: T1이 "활성 아님" → 대기하지 않고 27485로 내려감(B) → 행 S 잠금 바로 허용(C) | 부모 7 있음 | |
| t4 | 이후는 4.1 또는 4.2와 같다 | | | |

t1과 t3 사이는 명령 몇 개 길이다. 그래서 (A)보다 훨씬 드물다. 1차 수정 뒤 2,000라운드에서 1건 나온 것이 이 경로다(10.1절).

### 4.4 slave의 적용
slave는 라벨과 커밋 순서대로 적용한다. inverted(4.1)는 로그에서 T2가 먼저라서, missed(4.2)는 T2의 라벨에 T1이 없어 T1을 기다리지 않아서 T2를 먼저 또는 동시에 적용할 수 있다.

| 순서 | 적용 | slave 결과 |
|---|---|---|
| 1 | T2: INSERT 자식 (7, 7) | 부모 7이 아직 없어 FK 검사 실패 → **-922**(3.2절), 행 버려짐, `fail_counter` +1 |
| 2 | T1: INSERT 부모 7 | 부모 7 있음 |
| 결과 | | master에는 자식 (7, 7)이 있고 slave에는 **없음** |

develop의 직렬 applier도 로그 순서대로 적용하므로 inverted(4.1)는 같은 유실이 생길 것으로 본다(추정, 8절). missed(4.2)는 커밋 순서가 맞으므로 직렬 applier에서는 생기지 않는다.

## 5. 재현 (HA 런타임)

### 5.1 도구
- `ha_bench_tool/bin/c3_fk_gap.c`: 클라이언트 라이브러리(`libcubridcs`)로 youngjun3 서버에 세션 두 개를 붙인다.
  - 부모 세션(T1 역할): 라운드 k마다 (`INSERT c3_f` FILLER행 +) `INSERT c3_p(k)` 후 커밋. FILLER행은 ②를 길게 만들어 틈을 넓힌다.
  - 자식 세션(T2 역할): 같은 k로 `INSERT c3_c(k, k)`를 성공할 때까지 반복하고 커밋. 실패한 시도는 롤백.
  - 라운드마다 부모 커밋 1개, 자식 커밋 1개이고, 라운드끼리 겹치지 않는다.
- `ha_bench_tool/bin/c3_fk_gap.sh`: 테이블 생성, 실행, slave 따라잡기 대기, 판정.
  - master trace `[WSET] COMMIT`의 커밋 LSA와 라벨로 라운드를 2.5절 분류대로 나눈다. 자식 커밋은 writeset 항목 2개(PK, REF), 부모 커밋은 1 + FILLER개로 구분한다.
  - slave trace `worker apply begin/done`으로 자식이 부모 적용이 끝나기 전에 시작했는지 본다.

### 5.2 수정 전 결과 (10-21 14:42, 빌드 2778-9337f6a, worker 10)
| 실행 | 라운드 | ok | inverted | missed | slave c3_c / master c3_c | fail_counter |
|---|---|---|---|---|---|---|
| FILLER 0 | 20,000 | 20,000 | 0 | 0 | 같음 | 1 → 1 |
| **FILLER 500** | 2,000 | 1,418 | **197** | **385** | **1,418 / 2,000** | **1 → 583** |

- FILLER 0: 부모 트랜잭션이 행 1개라 틈이 수 µs여서 한 번도 걸리지 않았다.
- FILLER 500: slave에서 자식이 부모보다 먼저 시작한 경우가 582건(197 + 385)이다. 582건 모두 `-922 The constraint of the foreign key 'fk_c3_c_pid' is invalid`로 실패했다. 양쪽을 직접 조회해 master c3_c 2,000, slave 1,418을 확인했다.
- missed 자식의 라벨은 모두 같은 값(`2721|2552`)이었다. REF 조회가 부모를 찾지 못해 라벨이 history 하한으로 정해졌다(4.2절 t3).
- 결과 디렉터리: `ha_bench_tool/log/c3_fk_gap_20261021_144251/`

## 6. 해결

### 6.1 방향
(A)와 (B)는 원인이 같다. 내려온 경로에서 "커밋 중"과 "커밋 끝남"을 구분하지 않는다(2.3절). 그래서 S 잠금(27510)을 잡기 전에, 부모 7을 넣은 트랜잭션(INSID)이 커밋 중인지 확인하고 커밋 중이면 그 MVCCID self-lock을 기다리게 한다. self-lock은 ②가 끝난 뒤 ③에서 풀린다. 그러므로 기다린 T2는 T1의 커밋 기록과 publish 뒤에 FK 검사를 마치고, 커밋 순서와 라벨이 모두 맞는다.

"커밋 중" 판정(`btree_is_mvccid_committing`)은 다음 조건을 모두 만족할 때 참이다.
1. 복제 로그를 쓰는 서버다.
2. INSID가 정상 MVCCID이고 자기 자신의 것이 아니다.
3. MVCC로는 활성이 아니다. ① 이후라는 뜻이다.
4. 그 MVCCID의 self-lock을 조건부 S로 요청했는데 허용되지 않는다. ③ 이전이라는 뜻이다.

이 판정은 `79268ae56`의 `btree_is_deleter_committing`과 조건이 같으므로, 이름을 일반화해 `DELETED` 분기와 함께 쓴다.

### 6.2 수정 후 타임라인
| 시각 | T1 | T2 | master에서 보이는 것 | 로그의 COMMIT 순서 |
|---|---|---|---|---|
| t0 | INSERT 실행 | | 부모 7 없음 | |
| t1 | ① MVCC 완료 | | 부모 7 있음 | |
| t2 | 커밋 중 (② 전) | INSERT 실행. FK 검사가 T1을 "커밋 중"으로 판정 → T1의 self-lock을 **대기** | 부모 7 있음 | |
| t3 | ② 라벨, 커밋 기록, publish | (대기) | 부모 7 있음 | **T1** |
| t4 | ③ 잠금 해제 | 대기 끝, 루트부터 다시 찾음 → T1 "커밋 끝남" → 행 S 잠금, FK 검사 통과 | 부모 7 있음 | T1 |
| t5 | | COMMIT: ① → ② 라벨(REF(7)로 T1을 찾음), 커밋 기록, publish → ③ | 부모 7, 자식 (7, 7) | T1, **T2** |

- 커밋 기록 순서는 T1(t3) → T2(t5)이고, T2의 라벨은 T1의 커밋을 가리킨다. inverted와 missed가 모두 없다.
- slave는 T2를 T1 뒤에 적용하므로 FK 검사가 성공한다.
- 경로 (B)도 t3(4.3절)에서 같은 판정을 거쳐 t2 이후와 같이 진행한다.

### 6.3 다른 안
- **"커밋 중" MVCC 상태 신설(architect_10y 제안):** ①부터 ③까지를 별도 상태로 보이게 해 모든 검사 경로가 기다리게 한다. 틈을 근본적으로 없애지만 develop의 MVCC 가시성 규칙을 바꾸는 큰 변경이다. ①을 뒤로 옮기는 것은 develop 주석상 불가하다(postpone, `TRAN_UNACTIVE_WILL_COMMIT` 전에 해야 함).
- **applier의 FK 넘김 코드 수정(3.2절):** develop 결함이 맞다. 고치면 slave가 순서가 바뀐 자식을 받아들여 데이터는 같아진다. 하지만 순서 결함을 가리기만 하므로 이 수정을 대신하지 못한다. develop 별도 이슈(todo)로 기록할 대상이다.

## 7. 종합 판정과 다른 점
| 항목 | 종합 문서 | 이 문서 |
|---|---|---|
| 데이터 영향 | 기각("applier가 FK 위반을 넘겨 최종 상태가 같아진다") | **slave 행 유실 확정.** 넘김 코드가 오류 코드를 지우지 않는다(3.2절) |
| 등급 | Medium | **High** |
| 발생 | 미검증 | 큰 부모 트랜잭션과 자식 INSERT가 겹치면 쉽게 생긴다(2,000라운드 중 29%) |

## 8. develop과의 관계
| 경우 | develop | 브랜치 |
|---|---|---|
| inverted (4.1) | 틈은 같다. CBRD-26942가 develop 기반에 포함돼 있다(`git merge-base` 확인). 직렬 applier도 로그 순서대로 T2를 먼저 적용하므로 같은 유실이 생길 것으로 본다(추정, develop 빌드 미재현) | 197건 |
| missed (4.2) | 직렬 적용이라 생기지 않는다 | 385건, 브랜치에서만 |

## 9. 구현

### 9.1 1차 수정 (`d78ee1410`): 경로 (A)
- `btree_is_deleter_committing`을 `btree_is_mvccid_committing`으로, `btree_trace_deleter_wait`를 `btree_trace_committing_wait`로 이름을 바꿨다. 본문은 그대로이고 `DELETED` 분기 호출도 그대로다.
- `_of_unique`와 `_of_non_unique`의 `CAN_DELETE` 분기에서 `locked_oid` 처리 뒤에 확인과 대기를 넣었다. 조건은 `satisfies_delete == DELETE_RECORD_CAN_DELETE`일 때만이었다.
- 대기할 때만 trace를 남긴다: `[WSET] UNIQUE WAIT trid=… inserter_mvccid=… index_vfid=… key=…` (`ha_writeset_trace_level` ≥ 1).

### 9.2 보완 수정 (`cef2bb122`): 경로 (B)
1차 수정의 `satisfies_delete == DELETE_RECORD_CAN_DELETE` 조건을 뺐다. (B)로 내려온 경우에도 판정을 거친다. 지금 코드(btree.c, `cef2bb122`):

```c
27495    case DELETE_RECORD_CAN_DELETE:
27498      if (!OID_ISNULL (&find_unique_helper->locked_oid)) { ... return NO_ERROR; }
27510      if (btree_is_mvccid_committing (thread_p, BTREE_MVCC_INFO_INSID (&mvcc_info)))     // (A)(B) 모두 여기서 판정
27511        {
27516          btree_trace_committing_wait (thread_p, btid_int, key, "inserter", BTREE_MVCC_INFO_INSID (&mvcc_info));
27517          return btree_key_wait_for_insert_mvccid (thread_p, BTREE_MVCC_INFO_INSID (&mvcc_info), find_unique_helper,
27518                                                   leaf_page, NULL, restart);            // self-lock 대기 후 루트부터 다시
27519        }
27522      try_cond_lock = (satisfies_delete == DELETE_RECORD_CAN_DELETE);
```

`_of_non_unique`는 27867행에 같은 코드가 있다(대기 함수에 `&overflow_page`를 넘김).

내려오는 경우별 동작:
| 내려온 경우 | 판정 결과 | 동작 |
|---|---|---|
| 자기 자신의 INSERT (`INSERT_IN_PROGRESS`) | 조건 2에서 거짓 | 원래대로 진행 |
| T1이 방금 ①을 지남 (경로 B) | 참 | 대기 |
| T1이 커밋 중 (경로 A) | 참 | 대기 |
| 커밋 끝난 트랜잭션, `DELETE_IN_PROGRESS`로 내려온 경우의 inserter | 거짓 | 조건부 잠금 요청 1회 추가 후 원래대로 진행 |

## 10. 검증

### 10.1 1차 수정 (10-21 16:50, 빌드 2777-d78ee14, DB 재생성 직후, FILLER 500, 2,000라운드)
| 항목 | 수정 전(5.2절) | 1차 수정 뒤 |
|---|---|---|
| ok / inverted / missed | 1418 / 197 / 385 | 1999 / **1** / 0 |
| slave c3_c 행 수 (master 2000) | 1418 | 1999 |
| fail_counter 증가 | +582 | +1 |
| `UNIQUE WAIT … inserter_mvccid` 건수 | 0 | 1151 |

남은 1건은 경로 (B)로 본다(추정: 로그로는 확인할 수 없고 코드 경로로 설명된다).
- 부모 trid 74397은 c3_p 1774를 넣었고 커밋은 26057|1184이다. 자식 trid 74427은 c3_c (1774, 1774)를 넣었고 커밋은 26054|6104다. 자식이 먼저 커밋됐다(inverted).
- master 로그에 key=1774의 대기 trace가 없다. 판정을 거치지 않았다는 뜻이다.
- slave에 직접 접속해 비교했다. 빠진 행은 c3_c 1774 하나이고, slave에서 -922로 실패했다.
- 다른 가능성으로 sub-MVCCID 경로(부분 트랜잭션 끝에 self-lock을 먼저 푸는 경로)도 따져 봤다. 이 경로는 `query_executor.c`의 selupd에서만 쓰이고 이 시험에는 없어서 제외했다.

이것은 1차 수정의 부작용이 아니다. 수정 전에도 이 경로는 같은 방식으로 통과했다(수정 전 inverted 197건에 섞여 있었다고 추정). 원인과 증상이 같고 들어오는 입구만 달라서 C3에 포함한다.

### 10.2 보완 수정 (10-21 17:24~17:31, 빌드 2778-cef2bb1, DB 재생성 직후, FILLER 500, 2,000라운드 × 5회)
| 항목 | 수정 전 | 1차 수정 뒤 | 보완 수정 뒤 (5회 각각) |
|---|---|---|---|
| ok / inverted / missed | 1418 / 197 / 385 | 1999 / 1 / 0 | **2000 / 0 / 0** |
| slave에서 자식이 부모 적용 완료 전에 시작 | - | 1 | **0** |
| fail_counter 증가 | +582 | +1 | **0** |
| `UNIQUE WAIT … inserter_mvccid` 건수 | 0 | 1151 | 1039 (1회차), 5회 합계 5053 |

- 경로 (B)는 2,000라운드에 1번 꼴이라 같은 조건으로 5회(합계 10,000라운드)를 돌렸다. 위반 0건이다.
- 첫 회차와 마지막 회차 뒤 master와 slave에 직접 접속해 c3_p, c3_c의 id 목록 전체를 비교했다. 둘 다 2000행이고 같다.

### 10.3 회귀 시험 (10-21 17:34~18:46, 빌드 2778-cef2bb1)
| 시험 | 판정 | 핵심 수치 |
|---|---|---|
| unique 반복 5회 | PASS | 불일치 0, fail_counter 0, UNIQUE WAIT 436 / ROW WAIT 55 |
| fk_multi (12분) | PASS | 테이블 20/20 같음, fail_counter delta 0, gate 순서 위반 0 |
| F1 | PASS | 승격 7초, marker 손실 없음, failover·failback 뒤 20/20 같음 |
| F4 | PASS | 승격 41초(DONE 대기 37초), marker 손실 없음, failover·failback 뒤 20/20 같음 |

- unique 반복의 1회당 UNIQUE WAIT는 87회로, 10-19 같은 조건(38회)보다 많다. 이번 수정의 inserter 대기가 더해진 것으로 본다(추정).
- 상세: `ha_bench_tool/log/chain_regress_20261021_181402_report.md`

### 10.4 남은 검증
1. (선택) develop 빌드로 FILLER 500을 실행해 inverted 유실을 재현하고 "기존 결함"을 확정한다.

## 11. 영향 범위와 위험
- 영향: 부모 INSERT와 그 키를 참조하는 자식 INSERT가 거의 동시에 일어나는 모든 부하. 부모 트랜잭션이 클수록 잘 생긴다. 결과는 slave 행 유실이고 `fail_counter`만 오른다.
- 같은 분기를 지나는 X 잠금 경로(`S_UPDATE`, `S_DELETE`)도 커밋 중인 inserter를 기다리게 된다.
- 수정 위험: FK 검사와 unique 검사가 커밋 중인 inserter를 ③까지 기다린다(커밋 로그 flush 전). 교착 가능성은 `DELETED` 분기와 같은 수준으로 본다(추정). 10-20의 FK 교착 todo와 같은 대기 경로(`btree_wait_for_inserter_end`)라 함께 확인한다.
- 비용: vacuum이 끝난 오래된 행은 INSID가 정상 MVCCID가 아니라 바로 넘어간다. 최근 행이면 조건부 잠금 요청 1회가 추가된다.

## 12. 열린 질문
1. CASCADE/SET NULL, 트리거가 있는 경우의 결과는 보지 않았다.
2. develop 빌드에서 inverted 경우가 실제로 유실되는지(8절 추정).
