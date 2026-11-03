---
tags: [writeset, applylogdb, sysop_end, idea3, example]
date: 2026-10-02
status: 설계 예시 (안 3 미구현, end-to-end 추적)
code-base:
  repo: /home/youngjun/Workspace/cubrid-applier
  branch: feature/CBRD-27508-parallel-applylogdb-writeset
  head: 441aafed9306856adc64d39fbd1b1e86b99bd83c
  base: origin/develop c63a3b993
---

# 안 3 혼합 시나리오 end-to-end 예시 — serial(sysop) + 일반 DML COMMIT

이 문서는 [10-sysop-end-investigation.md](../10-sysop-end-investigation.md) §13.3의 안 3(sysop 경계에서 probe/publish 하는 조각 독립 처리)을, serial 발급 sysop과 일반 DML이 한 트랜잭션에 섞이고 `SYSOP_END` 뒤에 최종 COMMIT이 오는 흐름으로 끝까지 따라간 예시다. 마스터의 history map 처리부터 슬레이브의 조각 task 적용·커밋까지 한 흐름으로 본다.

문서 안에서 현재 코드 사실은 평서문("한다/된다")으로, 안 3의 설계 요구는 "~해야 한다"로 구분한다. 안 3은 아직 구현되지 않은 설계이므로 설계 요구가 대부분이다.

## 0. 현재 코드가 어디까지 되어 있는지 (사실)

안 3을 정확히 이해하려면 현재 코드가 무엇을 하고 무엇을 하지 않는지 먼저 구분해야 한다. `feature/CBRD-27508-parallel-applylogdb-writeset` HEAD(`441aafed`) 기준으로 확인한 사실은 다음과 같다.

- 일반 DML 행의 PK·UNIQUE 키 수집은 `locator_sr.c`에 구현되어 있다. 이 파일에 `wset_add_write_key`/`wset_add_ref_key`/`locator_wset_collect_fk_ref` 호출이 10곳 있다.
- 최종 COMMIT 시점의 probe→WSET_LABEL→publish는 `log_commit_local()`에 연결되어 있다. `src/transaction/log_manager.c:5379`에서 `wset_find_dependency_from_history()`(probe), `:5381`에서 `log_append_repl_info_and_commit_log()`(REPL·WSET_LABEL·COMMIT), `:5383`에서 `wset_publish_commit_to_history()`(publish)를 순서대로 호출한다.
- `serial_update_serial_object()`(`src/query/serial.c:1148`)는 writeset을 수집하지 않는다. 이 함수에는 `wset_*` 호출이 하나도 없다. serial은 `log_sysop_start()` → `repl_start_flush_mark()` → `repl_log_insert(...RVREPL_DATA_UPDATE...)` → `repl_end_flush_mark(false)` → `log_sysop_commit()` 순서만 수행한다(serial.c:1173~1222).
- `log_sysop_commit_internal()`(`log_manager.c:3897`)는 sysop 끝에서 `NEED_FLUSH` 복제 item을 `log_append_repl_info(..., false)`로 내보내고 `log_append_sysop_end()`로 `LOG_SYSOP_END`를 기록할 뿐, probe도 WSET_LABEL도 publish도 하지 않는다. `ha_writeset_trace_level >= 1`이면 `[WSET] SYSOP master ...` 관찰 로그만 남긴다(:4005~4013).
- 슬레이브는 `LOG_SYSOP_END`를 worker task로 보내지 않는다. `la_log_record_process()`(`log_applier.c:6935~7009`)에서 `LOG_COMMIT`이고 `la_parallel_Enabled`일 때만 `la_parallel_schedule()`로 worker task를 만든다(:6998). `LOG_SYSOP_END`는 `la_add_node_into_la_commit_list()` 뒤 `la_apply_commit_list()`(:7020) 경로로 coordinator 세션에서 직렬 적용된다.
- WSET_LABEL의 dependency는 `la_parallel_schedule()`에서 `commit->type == LOG_COMMIT && la_wset_label_trid == commit->tranid`일 때만 task에 실린다(`log_applier.c:6589`). 즉 현재는 sysop 조각이 라벨을 가질 수 없다.

따라서 안 3이 요구하는 "sysop 경계 probe/publish"와 "조각 독립 task"는 현재 코드에 없다. 아래 예시에서 마스터의 sysop 조각 수집·probe·publish, 슬레이브의 조각 task 조립·gate·커밋은 전부 안 3이 추가해야 하는 동작이며 "~해야 한다"로 쓴다.

## 1. 세 값(hash, seq, lc)과 history map 표의 규칙

이 예시는 모든 단계에서 세 값을 함께 명시한다.

- **hash**: history map의 key. 아래에서는 예시용 상수(`0xA3F1` 등)로 표기한다. 실제 값이 아니라 설명용이다.
- **seq**: `write_seq`/`ref_seq`에 들어가는 좌표. 일반 COMMIT이면 그 트랜잭션의 COMMIT LSA, sysop 조각이면 `SYSOP_END`의 LSA다. LSA는 본래 `pageid|offset` 쌍이지만, 이 예시에서는 읽기 쉽게 단일 정수(500, 540, …)로 쓰고 "LSA 좌표"로 읽는다.
- **lc**: 문자열 키의 콜레이션. serial 이름 `"seq_t"` 같은 문자열 키에서만 쓰인다. `lc = lang_get_collation(coll_id)`로 얻고 `lc->mht2str(lc, s, size)`로 32비트 pseudo key를 만든 뒤 FNV-1a 해시에 넣는다.

history map 상태 표는 항상 `key(hash) | write_seq | ref_seq` 세 컬럼을 유지한다. `lc`는 표에 넣지 않는다. **`lc`는 hash를 계산할 때만 쓰고 history map에 저장하지 않는다(마스터 불변식 10).** `"seq_t"`와 `"SEQ_T"`가 같은 키인지는 콜레이션이 결정하므로 바이트를 그대로 해시하지 않고 `lc`로 정규화한 pseudo key를 해시하지만, 콜레이션 객체 자체는 history의 상태가 아니다.

### 1.1 문자열 키의 lc→pseudo→hash 산출 (현재 코드 `wset_string_hash`)

`wset_string_hash()`(`src/transaction/writeset.cpp:248`)는 다음을 한다. 안 3은 serial 이름 키를 수집할 때 이 같은 경로를 재사용해야 한다.

```text
lc     = lang_get_collation (db_get_string_collation (v))   // v = serial 이름 DB_VALUE
pseudo = lc->mht2str (lc, "seq_t", 5)                        // 32비트 유사키
pbytes = [0xC5, pseudo[0..3]]                                // 0xC5 = 문자열 태그(숫자키와 분리)
hash   = wset_fnv1a (class_oid=db_serial, index_vfid=db_serial PK, pbytes, 5)
```

숫자 PK 키(예: `t.id=100`)는 문자열이 아니므로 `lc`를 쓰지 않는다. 숫자 키는 정규화한 packed 표현을 `wset_fnv1a(class_oid, index_vfid, packed, len)`에 넣는다. 그래서 아래에서 serial 키에는 `lc` 산출 줄을 붙이고, PK 키에는 "lc 없음(숫자 키)"으로 표기한다.

## 2. 시나리오 설정

테이블과 트랜잭션은 다음과 같다. serial 이름은 설명을 위해 `"seq_t"`로 쓴다. 실제 CUBRID AUTO_INCREMENT는 내부 serial 이름을 자동 생성하므로 이름 문자열은 예시다. 중요한 것은 그 이름이 문자열 키라 `wset_string_hash` 경로를 탄다는 점이다.

```sql
CREATE TABLE t (id INT AUTO_INCREMENT PRIMARY KEY, v VARCHAR(50));
-- 내부적으로 serial "seq_t"(예시 이름)가 t.id 발급을 담당한다.
-- 시작 상태: slave 쪽 seq_t 현재값 = 100, t 에 id=100 행이 이미 있다(T0 가 넣는다).
```

세 트랜잭션을 둔다. 좌표(LSA)는 예시 정수다.

- **T0** — `INSERT INTO t(v) VALUES('a')`
  - serial `seq_t` 발급(100→101)으로 sysop 조각 발생. T0 `SYSOP_END` LSA = **500**.
  - 새 행 `id=101`은 일반 DML. T0 COMMIT LSA = **540**.
  - (시작 상태 설명을 위해 T0가 `id=100` 행도 만든다고 보지 않고, `id=100` 행은 이미 존재한다고 둔다. T0는 `id=101`을 넣는다.)
- **T1** — 두 문장 트랜잭션
  - `INSERT INTO t(v) VALUES('b')` → serial `seq_t` 발급(101→102)으로 sysop 조각. T1 `SYSOP_END` LSA = **620**. 새 행 `id=102`.
  - `UPDATE t SET v='x' WHERE id=100` → 기존 PK `id=100`을 WRITE로 건드린다(일반 DML).
  - 최종 T1 COMMIT LSA = **680**.
- **T2** — `INSERT INTO t(v) VALUES('c')` (T1과 병행)
  - serial `seq_t` 발급(102→103)으로 sysop 조각. T2 `SYSOP_END` LSA = **720**. 새 행 `id=103`.
  - 최종 T2 COMMIT LSA = **760**.

이 설정은 두 종류의 dependency를 동시에 보여준다.

- **serial 조각 dependency**: T1의 serial 조각은 T0의 serial 조각에, T2의 serial 조각은 T1의 serial 조각에 걸린다. 안 3에서 이 dependency는 상대의 **COMMIT LSA가 아니라 `SYSOP_END` LSA**를 가리킨다. 그래서 T2의 serial 조각은 T1의 조각 task(SYSOP_END 620) 완료만 기다리고 T1의 최종 COMMIT(680)까지 기다리지 않아야 한다.
- **일반 COMMIT dependency**: T1의 `UPDATE id=100`은 T0가 publish한 PK=100 이력이 아니라, "id=100 행을 처음 만든 트랜잭션"의 COMMIT에 걸린다. 이 예시에서는 id=100을 만든 선행 트랜잭션의 COMMIT LSA를 **540 이전의 좌표**로 두되, 설명을 단순화하기 위해 id=100의 직전 WRITE write_seq를 **450**이라 둔다. T1 최종 COMMIT는 이 450에 dependency를 건다.

예시용 hash 상수는 다음과 같다.

| 키 | 종류 | hash(예시) | lc |
|---|---|---|---|
| serial `"seq_t"` | 문자열 | `0xA3F1` | 있음 (`lang_get_collation`) |
| PK `t.id=100` | 숫자 | `0xB210` | 없음 |
| PK `t.id=101` | 숫자 | `0xB2A4` | 없음 |
| PK `t.id=102` | 숫자 | `0xB3C8` | 없음 |
| PK `t.id=103` | 숫자 | `0xB4D0` | 없음 |

## 3. 마스터 추적

### 3.0 시작 상태

T0 처리 직전 history map 상태다. serial 키와 id=100 키만 선행 좌표가 있다고 둔다.

| key(hash) | write_seq | ref_seq |
|---|---|---|
| `0xA3F1` (serial seq_t) | 420 | NULL |
| `0xB210` (PK id=100) | 450 | NULL |

serial `0xA3F1`의 `write_seq=420`은 seq_t를 420 좌표에서 마지막으로 발급한 조각이 남긴 값이다. PK `0xB210`의 `write_seq=450`은 id=100 행을 450 좌표에서 만든 트랜잭션이 남긴 값이다.

### 3.1 T0 처리 — serial 조각 수집·probe·publish

T0가 `INSERT INTO t`를 실행하면 serial 발급 sysop이 열린다. 안 3에서 `serial_update_serial_object()`는 `repl_log_insert()`를 호출하는 자리(serial.c:1210)에서 `db_serial` 행의 serial 이름 키를 조각 writeset의 WRITE로 직접 수집해야 한다. serial은 인덱스 루프(`locator_sr.c`)를 거치지 않으므로 일반 수집 훅에 걸리지 않기 때문이다.

조각 키 산출(세 값 함께):

```text
수집(serial 조각 WRITE):
  lc     = lang_get_collation(coll_id("seq_t"))        // 문자열 키라 lc 사용
  pseudo = lc->mht2str(lc, "seq_t", 5) = 0x5EC7         // 예시 pseudo
  hash   = FNV1a(db_serial_oid, db_serial_PK_vfid, [0xC5, 0x5EC7..]) = 0xA3F1
  seq    = (아직 없음 — probe 시점엔 SYSOP_END LSA 미확정)
```

조각 probe(안 3이 `SYSOP_END` 직전에 수행해야 함):

```text
probe(hash=0xA3F1):
  map[0xA3F1].write_seq = 420, ref_seq = NULL
  WRITE 키의 후보 = max(write_seq, ref_seq) = max(420, NULL) = 420
  → dependency_seq = 420, dependency_is_ref = false
  lc 는 여기서도 해시 계산에만 쓰이고 저장되지 않음
```

이어서 안 3은 같은 `trid`의 `LOG_SYSOP_END` 바로 앞에 `WSET_LABEL(dependency_seq=420, dependency_is_ref=false)`을 기록하고 `LOG_SYSOP_END`를 기록해야 한다. `SYSOP_END` LSA가 **500**으로 확정된다.

조각 publish(안 3이 `SYSOP_END` 확정 직후 수행해야 함). publish 좌표는 COMMIT LSA가 아니라 `SYSOP_END` LSA다.

```text
publish(hash=0xA3F1, kind=WRITE, seq=SYSOP_END LSA=500):
  map[0xA3F1].write_seq = max(420, 500) = 500
  (현재 writeset_history_map::publish 는 WRITE 도 LSA_GT 로 max 갱신한다. writeset_history_map.cpp:60~66)
  publish 한 serial 키는 바깥 writeset 에서 제거 → 최종 COMMIT 의 두 번째 probe/publish 가 중복하지 않음
```

> [!NOTE]
> 설계 문서 §4의 마스터 불변식 9는 "WRITE 단순 대입, REF max"로 적혀 있으나, 이는 검증 코드 기준이다. 현재 `writeset_history_map::publish`(writeset_history_map.cpp:50~75)는 WRITE·REF 둘 다 `LSA_GT` 비교로 max 갱신한다. 이 예시는 현재 코드대로 max로 적는다.

T0의 바깥 COMMIT. 바깥 writeset에는 새 행 PK `id=101` WRITE만 남아 있다(serial 키는 조각이 가져가서 제거됨).

```text
probe(hash=0xB2A4, PK id=101):  lc 없음(숫자 키)
  map[0xB2A4] 없음 → MISS → dependency 없음(history_start 하한)
WSET_LABEL(dependency_seq=NULL)
COMMIT LSA = 540
publish(hash=0xB2A4, kind=WRITE, seq=540):
  map[0xB2A4].write_seq = 540
```

T0 처리 후 history map:

| key(hash) | write_seq | ref_seq |
|---|---|---|
| `0xA3F1` (serial) | **500** (조각 publish) | NULL |
| `0xB210` (PK id=100) | 450 | NULL |
| `0xB2A4` (PK id=101) | **540** (COMMIT publish) | NULL |

T0 마스터 로그 순서:

```text
REPL(serial seq_t UPDATE)       // repl_log_insert, NEED_FLUSH
WSET_LABEL(dep=420)             // [안3] 조각 라벨
LOG_SYSOP_END                   // LSA 500
REPL(t row id=101 INSERT)
WSET_LABEL(dep=NULL)            // 최종 커밋 라벨
LOG_COMMIT                      // LSA 540
```

### 3.2 T1 처리 — 조각 dependency(serial)와 일반 dependency(PK) 둘 다

T1의 첫 문장 `INSERT INTO t`가 serial 발급 sysop을 연다.

조각 수집·probe·publish(세 값 함께):

```text
수집(serial 조각 WRITE):
  lc     = lang_get_collation(coll_id("seq_t"))
  pseudo = lc->mht2str(lc, "seq_t", 5) = 0x5EC7   // 같은 이름 → 같은 lc → 같은 pseudo
  hash   = 0xA3F1                                   // 같은 키
probe(hash=0xA3F1):
  map[0xA3F1].write_seq = 500 (T0 조각이 남긴 SYSOP_END 좌표), ref_seq = NULL
  후보 = max(500, NULL) = 500
  → dependency_seq = 500, dependency_is_ref = false
WSET_LABEL(dep=500) → LOG_SYSOP_END (LSA=620)
publish(hash=0xA3F1, kind=WRITE, seq=620):
  map[0xA3F1].write_seq = max(500, 620) = 620
  serial 키를 바깥 writeset 에서 제거
```

여기서 핵심은 T1 serial 조각의 dependency가 **T0의 COMMIT LSA 540이 아니라 T0의 `SYSOP_END` LSA 500**을 가리킨다는 것이다. serial 이력이 조각 좌표로 publish되었기 때문이다.

T1의 둘째 문장 `UPDATE t SET v='x' WHERE id=100`은 PK `id=100`을 WRITE로 수집한다(일반 DML, 인덱스 루프 경로). 이건 바깥 writeset에 들어간다.

T1 바깥 COMMIT. 바깥 writeset에는 새 행 PK `id=102` WRITE와 UPDATE가 건드린 PK `id=100` WRITE가 있다(serial 키는 조각이 가져감).

```text
probe(hash=0xB3C8, PK id=102):  lc 없음
  map[0xB3C8] 없음 → MISS → dependency 없음
probe(hash=0xB210, PK id=100):  lc 없음
  map[0xB210].write_seq = 450, ref_seq = NULL
  후보 = max(450, NULL) = 450
두 후보 중 가장 늦은 좌표 = 450
  → dependency_seq = 450, dependency_is_ref = false
WSET_LABEL(dep=450) → LOG_COMMIT (LSA=680)
publish(hash=0xB3C8, WRITE, 680): map[0xB3C8].write_seq = 680
publish(hash=0xB210, WRITE, 680): map[0xB210].write_seq = max(450,680) = 680
```

T1 처리 후 history map:

| key(hash) | write_seq | ref_seq |
|---|---|---|
| `0xA3F1` (serial) | **620** (T1 조각 publish) | NULL |
| `0xB210` (PK id=100) | **680** (T1 COMMIT publish) | NULL |
| `0xB2A4` (PK id=101) | 540 | NULL |
| `0xB3C8` (PK id=102) | **680** (T1 COMMIT publish) | NULL |

T1 마스터 로그 최종 순서(요구 순서 그대로):

```text
REPL(serial seq_t UPDATE)       // sysop 조각
WSET_LABEL(dep=500)             // [안3] 조각 라벨, 좌표=SYSOP_END
LOG_SYSOP_END                   // LSA 620
REPL(t row id=102 INSERT)       // 일반 DML
REPL(t row id=100 UPDATE)       // 일반 DML
WSET_LABEL(dep=450)             // 최종 커밋 라벨
LOG_COMMIT                      // LSA 680
```

### 3.3 T2 처리 — serial 조각이 T1 최종 COMMIT이 아니라 T1 조각을 가리킴

T2도 `INSERT INTO t`로 serial을 발급한다.

```text
수집(serial 조각 WRITE): lc=동일, pseudo=0x5EC7, hash=0xA3F1
probe(hash=0xA3F1):
  map[0xA3F1].write_seq = 620 (T1 조각의 SYSOP_END 좌표)
  → dependency_seq = 620, dependency_is_ref = false
WSET_LABEL(dep=620) → LOG_SYSOP_END (LSA=720)
publish(hash=0xA3F1, WRITE, 720): map[0xA3F1].write_seq = max(620,720)=720
바깥 COMMIT:
  probe(hash=0xB4D0, PK id=103): MISS → dependency 없음
  WSET_LABEL(dep=NULL) → LOG_COMMIT (LSA=760)
  publish(hash=0xB4D0, WRITE, 760)
```

T2 조각의 dependency가 **620**이라는 점이 안 3의 병렬성 이득이다. T2 serial 조각은 T1 serial 조각(SYSOP_END 620)만 기다리면 되고, T1의 최종 COMMIT(680)까지 기다릴 필요가 없다. 안 2라면 serial이 최종 COMMIT task에 묶여 probe는 sysop 시점, publish는 COMMIT 좌표로 벌어지므로 단조(max) 적용으로 그 간극을 덮어야 하지만, 안 3은 probe와 publish를 둘 다 `SYSOP_END` 시점에 수행해 간극 자체가 없다.

세 트랜잭션 처리 후 최종 history map:

| key(hash) | write_seq | ref_seq |
|---|---|---|
| `0xA3F1` (serial) | **720** | NULL |
| `0xB210` (PK id=100) | 680 | NULL |
| `0xB2A4` (PK id=101) | 540 | NULL |
| `0xB3C8` (PK id=102) | 680 | NULL |
| `0xB4D0` (PK id=103) | 760 | NULL |

serial 키는 참조가 아니라 쓰기만 발생하므로 `ref_seq`는 끝까지 NULL이다. `lc`는 세 트랜잭션 어디에서도 history에 들어가지 않았다(불변식 10).

## 4. 슬레이브 추적

슬레이브는 자기 쪽에서 sysop(`topops` 스택)을 열지 않는다. 마스터 로그를 재생할 뿐이다. 따라서 "바깥 ROLLBACK에도 serial이 살아남는다"는 마스터의 내부 트랜잭션 성질은 슬레이브에서 설계로 재현해야 한다. 안 3에서는 serial 조각을 진짜 독립 task로 만들어 이를 재현한다.

아래는 T1을 중심으로 본다. 슬레이브 reader가 보는 T1 로그 조각은 §3.2의 마스터 순서와 같다.

### 4.1 reader — 조각 task와 최종 COMMIT task 조립

현재 코드는 `LOG_DUMMY_WSET_LABEL`을 만나면 전역 `la_wset_label_{trid,dependency,is_ref}`에 임시 보관하고(`log_applier.c:6914~6933`), `LOG_COMMIT`에서만 그 라벨을 task에 싣는다(:6589). `LOG_SYSOP_END`는 task가 되지 않고 coordinator가 직렬 적용한다.

안 3은 reader를 다음과 같이 바꿔야 한다.

- `WSET_LABEL`(dep=500) 다음에 오는 `LOG_SYSOP_END`(LSA 620)를 만나면, 그 sysop 범위의 복제 item(serial `db_serial` UPDATE)을 바깥 트랜잭션 목록에서 **분리**해 별도 `LA_APPLY` 슬롯으로 옮기고, `SYSOP_END` LSA 620을 task 좌표로 하는 독립 조각 task를 만들어야 한다. 이때 라벨 dependency 500, dependency_is_ref=false를 그 조각 task에 실어야 한다.
- 이어서 `WSET_LABEL`(dep=450) 다음 `LOG_COMMIT`(LSA 680)을 만나면, sysop 범위를 제외한 남은 item(t row id=102 INSERT, t row id=100 UPDATE)으로 최종 COMMIT task를 만들어야 한다. 라벨 dependency 450을 이 task에 실어야 한다.
- 바깥 리스트에서 serial item의 소유권을 조각 task로 넘기므로, reader가 뒤 item을 추가하는 목록과 worker가 앞 item을 제거하는 목록의 소유권이 분리되어야 한다(02-slave §2).

조립 결과 두 task:

```text
Task A (serial 조각)
  record_type = LOG_SYSOP_END
  commit_lsa  = 620                 // SYSOP_END LSA 가 task 좌표
  dependency_seq = 500, is_ref=false
  apply = (db_serial "seq_t" UPDATE item 1건)

Task B (최종 COMMIT)
  record_type = LOG_COMMIT
  commit_lsa  = 680
  dependency_seq = 450, is_ref=false
  apply = (t id=102 INSERT, t id=100 UPDATE)
```

### 4.2 gate — 두 task의 통과 판정과 같은 trid 순서

gate 판정은 02-slave §4 규칙을 쓴다.

```text
if dependency_seq == NULL or dependency_seq <= frontier: dispatch
else if dependency_is_ref: pending (frontier 가 그 좌표까지 전진해야)
else if completed_set 에 dependency_seq 있음: dispatch
else: pending
```

Task A(serial 조각): dependency 500은 T0 serial 조각의 `SYSOP_END` 좌표다. frontier가 500 이상이거나 completed set에 500이 있으면 통과한다. dependency_is_ref=false이므로 개별 완료 한 건으로 충분하다.

Task B(최종 COMMIT): dependency 450(id=100을 만든 선행 COMMIT)이 완료돼야 한다. **추가로** 안 3은 같은 `trid`의 직전 조각 task(Task A, SYSOP_END 620) 완료도 기다리게 해야 한다(02-slave §2: "같은 trid의 다음 sysop task나 최종 COMMIT task는 앞선 sysop task의 완료를 기다린다"). 즉 Task B는 라벨 dependency 450과 직전 조각 Task A(620) 중 더 큰 연속 완료 요구를 함께 본다. 라벨 dependency와 앞선 sysop LSA 중 하나라도 연속 완료(frontier)를 요구하면 더 큰 LSA까지 frontier를 기다리고, 그렇지 않으면 해당 선행 task의 개별 완료를 확인해야 한다.

이 "같은 trid 순서"가 안 3에서 반드시 성립해야 하는 이유는, Task A와 Task B가 서로 다른 worker 세션에서 각각 독립 DB 트랜잭션으로 커밋되기 때문이다. 순서를 보장하지 않으면 serial 조각이 커밋되기 전에 최종 행이 커밋될 수 있다.

### 4.3 worker — 각 task의 적용·DB COMMIT

Task A가 gate를 통과하면 worker 세션에서 serial `db_serial "seq_t"` UPDATE를 적용하고, 02-slave §5에 따라 `commit_lsa`(=620)의 완료 표식과 `_db_ha_apply_info.max_committed_lsa` 갱신을 같은 DB 트랜잭션에 넣어 DB COMMIT해야 한다. worker의 DB COMMIT이 성공한 뒤에만 result를 보내고 completed set에 620을 등록하며 frontier를 전진시켜야 한다.

Task B가 gate를 통과하면 worker 세션에서 t row id=102 INSERT와 id=100 UPDATE를 적용하고, `commit_lsa`(=680) 완료 표식과 `max_committed_lsa` 갱신을 같은 DB 트랜잭션에 넣어 DB COMMIT해야 한다. 성공 후 completed set에 680 등록, frontier 전진.

### 4.4 핵심 흐름 — 조각 먼저, 최종 COMMIT 나중에, 각각 별도 DB 트랜잭션

안 3에서 T1의 슬레이브 처리는 다음 순서로 흐른다.

```text
1) Task A(serial 조각, SYSOP_END 620) gate 통과
   → worker 세션 W1: db_serial seq_t UPDATE 적용
   → 같은 DB 트랜잭션에 완료표식(620)+max_committed_lsa 갱신
   → DB COMMIT (#1)  ← serial 조각이 먼저 독립 커밋됨
   → completed set += 620, frontier 전진

2) Task B(최종 COMMIT 680) gate 통과
   조건: dependency 450 완료  AND  같은 trid 의 Task A(620) 완료
   → worker 세션 W2: t id=102 INSERT, id=100 UPDATE 적용
   → 같은 DB 트랜잭션에 완료표식(680)+max_committed_lsa 갱신
   → DB COMMIT (#2)  ← 그 다음 최종 COMMIT 이 별도 트랜잭션으로 커밋됨
   → completed set += 680, frontier 전진
```

두 task는 같은 `trid`에서 왔지만 서로 다른 worker 세션에서 각각의 DB 트랜잭션으로 커밋된다. 순서는 gate가 "Task B는 Task A 완료를 기다린다"로 보장한다. 그래서 "SYSOP_END 조각이 먼저 독립 커밋되고, 그 다음 같은 trid의 최종 COMMIT이 별도 task로 커밋된다"가 성립한다.

현재 코드와의 차이를 다시 분명히 한다. 현재는 `LOG_SYSOP_END`가 coordinator 세션에서 `la_apply_repl_log(rectype=LOG_SYSOP_END)`로 직렬 적용되고 그 자체는 DB COMMIT하지 않는다(DB COMMIT은 주기적 `la_log_commit()`이 따로 한다). 안 3은 이 조각을 worker task로 올려 독립 DB COMMIT하게 바꿔야 한다.

## 5. 정합성 확인

### 5.1 T2가 같은 serial을 쓸 때 — 조각만 기다림

T2 serial 조각의 dependency는 §3.3에서 620(T1 serial 조각의 `SYSOP_END` 좌표)이다. 슬레이브에서 T2 조각 task는 gate에서 620의 완료(frontier 또는 completed set)를 확인하면 통과한다. T1의 최종 COMMIT(680)은 기다리지 않는다. 그래서 T1의 일반 행 적용이 늦어져도 T2의 serial 발급은 T1 serial 조각 완료 직후 진행될 수 있다. 이것이 serial 병렬성을 최대로 유지하는 안 3의 결과다.

### 5.2 abort 변형 — 이미 task가 된 조각은 폐기되지 않음

T1의 바깥이 COMMIT이 아니라 ABORT라고 하자. 마스터에서 serial sysop은 `log_sysop_commit()`으로 이미 독립적으로 끝났고(serial.c:1222), 바깥 ROLLBACK은 `LOG_SYSOP_END_COMMIT` 지점의 parent LSA로 건너뛰므로 serial 발급은 되돌려지지 않는다. 슬레이브에서도 안 3은 이를 재현해야 한다.

```text
마스터: REPL(serial) → WSET_LABEL(dep=500) → LOG_SYSOP_END(620) → ... → LOG_ABORT
슬레이브(안3 요구):
  Task A(serial 조각 620)는 이미 reader 가 분리해 독립 task 가 됨
    → 바깥 ABORT 가 와도 Task A 는 폐기하지 않아야 한다 (02-slave §2)
    → Task A 는 정상 gate→worker→DB COMMIT 되어 seq_t 발급이 슬레이브에도 남음
  바깥 트랜잭션의 일반 행 item(id=102 INSERT, id=100 UPDATE)은 ABORT 로 폐기
```

현재 코드의 `la_apply_repl_log(rectype=LOG_ABORT)`는 apply 목록 전체를 해제한다(`log_applier.c:6103~6113`). 안 3은 sysop 조각을 미리 별도 task로 분리해 두었으므로 ABORT가 조각을 건드리지 않는 구조가 되어야 한다. 조각을 분리하지 못하고 한 목록에 두면 ABORT가 serial까지 폐기해 마스터와 달라진다.

### 5.3 재시작 — 조각은 커밋, 최종 COMMIT 전에 크래시 (까다로운 지점)

이 경우가 안 3에서 트랜잭션 단위보다 판정이 까다로운 지점이다.

```text
상황: Task A(serial 620) DB COMMIT(#1) 완료, Task B(최종 680) DB COMMIT 전에 슬레이브 크래시
```

02-slave §5·§7의 완료 표식 설계를 따르면 다음이 요구된다. Task A는 DB COMMIT 시 `commit_lsa`=620으로 완료 표식을 같은 트랜잭션에 남겼다. 재시작하면 reader는 영속된 `committed_lsa`부터 다시 읽는다.

```text
재시작 재적용(안3 요구):
  SYSOP_END 620 조각 재조립 → commit_lsa 620 완료표식 조회
    → 표식 있음 → 재적용하지 않고 완료 상태에만 반영  (serial 중복 발급 방지)
  최종 COMMIT 680 재조립 → commit_lsa 680 완료표식 조회
    → 표식 없음 → 정상 재적용 (id=102 INSERT, id=100 UPDATE)
```

즉 완료 판정이 "트랜잭션(trid) 단위"가 아니라 "조각(SYSOP_END LSA 620)과 최종 COMMIT(680)의 혼합 단위"로 이루어져야 한다. 같은 `trid` 안에서 조각은 skip, 최종 COMMIT은 재적용이라는 서로 다른 판정이 공존해야 한다.

> [!CAUTION]
> **미확인.** 위 재시작 판정은 02-slave §5·§7의 완료 표식·`committed_lsa`·`max_committed_lsa` 설계를 조각 단위로 확장한 **설계 요구**다. 현재 코드에는 조각 단위 완료 표식도, 조각 단위 재적용 skip도 없다(§0 참조). 또한 10-sysop-end §13.3이 지적하듯 sysop 중첩(`tdes->topops` 스택)과 조각 단위 재시작은 PoC가 검증하지 않은 경로다. 완료 표식 유일성 키를 `SYSOP_END` LSA로 둘 때 중첩 sysop에서 조각이 여럿이면 각 조각이 별도 표식을 가져야 하는지, 안쪽 sysop abort 시 조각 writeset 롤백을 어떻게 스택과 연동하는지는 이 예시 범위에서 확정하지 않는다.

## 6. 요약

| 관점 | 현재 코드 사실 | 안 3 설계 요구 |
|---|---|---|
| serial 키 수집 | `serial_update_serial_object()`는 writeset 미수집 | `repl_log_insert()` 자리에서 serial 이름 키를 조각 WRITE로 수집해야 함 |
| sysop 경계 probe/publish | 없음(`LOG_SYSOP_END`는 관찰 로그만) | `SYSOP_END` 좌표로 probe→WSET_LABEL→publish, 바깥 writeset에서 조각 키 제거 |
| 슬레이브 sysop 처리 | coordinator 세션 직렬 적용, DB COMMIT은 주기적으로 따로 | 독립 조각 task로 worker 세션에서 적용+DB COMMIT |
| 같은 trid 순서 | 라벨은 COMMIT task에만 실림 | 최종 COMMIT task가 직전 조각 task 완료를 기다려야 함 |
| abort | apply 목록 전체 해제 | 이미 task가 된 조각은 폐기하지 않아야 함 |
| 재시작 | 조각 단위 완료 표식 없음 | 조각(SYSOP_END LSA)과 최종 COMMIT을 각각 완료 표식으로 판정해야 함(미확인 지점 포함) |

세 값은 예시 전체에서 함께 추적했다. hash는 history map key(`0xA3F1` 등 예시 상수), seq는 `write_seq`/`ref_seq`에 들어가는 좌표로 일반 COMMIT이면 COMMIT LSA·sysop 조각이면 `SYSOP_END` LSA, lc는 serial 같은 문자열 키에서 `lang_get_collation`→`mht2str`로 pseudo key를 만들 때만 쓰고 history map에는 저장하지 않는다(불변식 10).
