# C11. 분할(partition) 부모 테이블의 FK에서 자식 REF 키와 부모 WRITE 키가 맞지 않아 slave에서 자식 행이 사라짐

## 1. 메타
| 항목 | 내용 |
|---|---|
| 등급 | High (종합 문서의 Medium에서 올림, 4절) |
| 상태 | 수정 커밋 `4ed4a84d0`(10-21, 안 B). HA 검증 통과(8.1절) |
| 판정 | HA 런타임 재현으로 확정(10-21 19:14). 분할 부모 500라운드에서 자식 라벨이 부모를 놓친 경우가 500건 모두였고, slave에서 자식 81행이 유실됨 |
| 신규/기존 | 신규. 병렬 적용에서만 드러난다(develop 직렬 applier는 커밋 순서대로 적용하므로 라벨과 상관없음) |
| 관련 | [C3](C3_fk_check_committing_inserter.md)(같은 결과: 자식이 부모보다 먼저 적용돼 -922로 유실). slave에서 행이 버려지는 이유는 C3 3.2절의 applier FK 넘김 결함과 같다 |
| 지적한 리뷰어 | 종합 문서 C11 |

## 2. 용어와 예시

> [!IMPORTANT]
> **용어**
> - 이 문서의 **부모/자식은 외래키 관계**다. 부모 = 참조되는 테이블(예: 주문 `orders`), 자식 = 외래키로 부모를 참조하는 **별개의** 테이블(예: 주문 항목 `order_items`).
> - **분할 쪽은 루트/분할**이라고 부른다. 루트 = 사용자가 만든 분할 테이블 이름(`orders`, 내부 B-tree는 비어 있음), 분할 = 실제 행이 저장되는 내부 테이블(`orders__p__p3`). 분할은 루트와 스키마가 같고 저장 위치만 나눈 것이다.
> - 자식은 외래키 정의상 **루트**를 가리킨다. 부모 행은 **분할**에 있다.

C3 문서와 같은 예시를 쓴다. 다만 부모 테이블을 hash 분할로 만든다.

```sql
CREATE TABLE c3_p (id INT PRIMARY KEY) PARTITION BY HASH (id) PARTITIONS 4;           -- 부모 (분할)
CREATE TABLE c3_c (id INT PRIMARY KEY, pid INT, FOREIGN KEY (pid) REFERENCES c3_p (id));  -- 자식
```

| 이름 | 하는 일 |
|---|---|
| T1 | `INSERT INTO c3_p VALUES (7)` 후 커밋. 행은 분할 하나(예: `c3_p__p__p2`)에 들어간다 |
| T2 | `INSERT INTO c3_c VALUES (7, 7)` 후 커밋 |

writeset 키는 (테이블 OID, 인덱스 VFID, 키 값)으로 만든다. master는 커밋할 때 T2의 REF 키로 history를 조회해서, 같은 키를 마지막으로 WRITE한 커밋(T1)을 라벨에 넣는다. 이 조회가 맞으려면 **T1의 WRITE 키와 T2의 REF 키가 같아야 한다.**

## 3. 문제 위치 (코드 `db599ab64`)

### 3.1 자식의 REF 키: 루트 테이블 기준
`locator_wset_collect_fk_ref` (locator_sr.c:7771):
```c
7819  error_code = wset_add_ref_key (tdes, &index->fk->ref_class_oid, &index->fk->ref_class_pk_btid.vfid,   // ★ 루트 c3_p의 OID와 PK
7820                                 fk_key, parent_pk_domain);
```
FK 정의에 저장된 참조 대상, 즉 **분할 루트 테이블** c3_p의 OID와 그 PK 인덱스로 키를 만든다.

### 3.2 부모의 WRITE 키: 분할 기준
`locator_insert_force` (locator_sr.c:4895):
```c
4921  COPY_OID (&real_class_oid, class_oid);                                       // 처음에는 루트 c3_p
4932  partition_prune_insert (thread_p, class_oid, recdes, scan_cache, pcontext, pruning_type, &real_class_oid,
4933                          &real_hfid, &superclass_oid);                        // ★ 행이 들어갈 분할로 바뀜
...
5141  && locator_add_or_remove_index (thread_p, recdes, oid, &real_class_oid, true, op_type, ...)   // ★ 분할 OID로 인덱스 갱신
```
`locator_add_or_remove_index_internal` (7855~):
```c
8051  error_code = wset_add_write_key (ws_tdes, class_oid, &index->btid.vfid, key_dbvalue);   // ★ 분할 OID와 분할의 인덱스
```
인덱스 갱신은 실제로 행이 들어간 **분할**의 OID와 그 분할의 인덱스로 하므로, WRITE 키도 분할 기준이 된다.

### 3.3 결과
| 키 | 테이블 OID | 인덱스 |
|---|---|---|
| T1의 WRITE(7) | 분할 `c3_p__p__p2` | 분할의 PK 인덱스 |
| T2의 REF(7) | 루트 `c3_p` | 루트의 PK 인덱스 |

카탈로그로 확인한 실제 모습(10-21, 확인용 테이블 `c11_p`, `PARTITION BY HASH (id) PARTITIONS 4`, 행 7 하나):

| 클래스 | PK 인덱스 BTID (`SHOW INDEX HEADER`) | 키 수 |
|---|---|---|
| `c11_p` (루트) | `(0\|5056\|5057)` | 0 |
| `c11_p__p__p0` | `(0\|5184\|5185)` | 0 |
| `c11_p__p__p3` | `(0\|5568\|5569)` | **1** (행 7) |

- 분할마다 **별도의 B-tree**가 있다. 루트의 PK 인덱스는 비어 있다.
- 그래서 두 키는 테이블 OID와 인덱스 VFID가 **둘 다** 다르다.
- FK 검사 자체(`locator_check_foreign_key`, 4131-4140행)는 루트 BTID에서 시작해 `partition_prune_unique_btid`로 분할 OID와 분할 BTID를 구한 뒤 찾는다. 검사는 분할 기준으로 맞게 하지만, REF 키는 따로 모으는 곳(`locator_wset_collect_fk_ref`)에서 루트 기준으로 만든다.

두 키가 다르므로 T2의 REF 조회는 T1을 **항상** 찾지 못한다. C3처럼 타이밍이 맞아야 생기는 것이 아니라, 분할 부모를 참조하는 자식은 모두 라벨에서 부모가 빠진다.

## 4. 동작 (타임라인)
C3 수정(`db599ab64`) 뒤라서 T2의 FK 검사는 T1의 커밋이 끝날 때까지 기다린다. 그래서 커밋 순서는 맞지만 라벨이 틀린다.

| 시각 | T1 (`INSERT c3_p 7`, 분할 p2) | T2 (`INSERT c3_c (7, 7)`) | history | 로그의 COMMIT 순서 |
|---|---|---|---|---|
| t0 | INSERT. WRITE 키 = (p2, p2의 PK, 7) | | | |
| t1 | 커밋: 커밋 기록, publish | | (p2, p2 PK, 7) → T1 | **T1** |
| t2 | | INSERT. FK 검사 통과(부모 7 있음). REF 키 = (c3_p, c3_p PK, 7) | | T1 |
| t3 | | 커밋: REF(7)로 history 조회 → (c3_p, …, 7)이 없어서 **못 찾음**. 라벨 = history 하한 | | T1, **T2** |

slave의 적용:
| 순서 | 적용 | 결과 |
|---|---|---|
| T2의 라벨이 T1을 가리키지 않으므로 gate가 T2를 T1과 동시에 또는 먼저 보낼 수 있다 | T2: INSERT 자식 (7, 7) | 부모 7이 아직 없으면 **-922**, 행 버려짐, fail_counter +1 |
| | T1: INSERT 부모 7 | 부모만 있음 → 자식 행 **유실** |

## 5. 재현 (HA 런타임)

### 5.1 방법
`ha_bench_tool/bin/c3_fk_gap.sh`에 `PART=<n>` 옵션을 넣었다. 부모 c3_p를 `PARTITION BY HASH (id) PARTITIONS n`으로 만든다. 나머지 절차와 분류(ok / inverted / missed)는 C3 문서 5.1절과 같다.

### 5.2 결과 (10-21 19:14, 빌드 2778-cef2bb1 = C3 수정 포함, `ROUNDS=500 FILLER=0 PART=4`)
| 항목 | 값 |
|---|---|
| ok / inverted / missed | **0 / 0 / 500** |
| 자식 라벨 | 500건 모두 같은 값 `2351300\|10808`. 부모 커밋과 상관없는 history 하한이다 |
| slave에서 자식이 부모 적용 완료 전에 시작 | 311 |
| slave c3_c 행 수 (master 500) | **419** (81행 유실) |
| fail_counter | 4 → 85 (+81) |

- inverted가 0인 것은 C3 수정 덕분이다. 커밋 순서는 맞고 라벨만 틀렸다.
- 비교: 분할하지 않은 부모로는 같은 빌드에서 10,000라운드 동안 missed 0이었다(C3 문서 10.2절). FILLER 0이면 C3 수정 전에도 20,000라운드 missed 0이었다(C3 문서 5.2절). 그래서 이번 missed 500은 분할 때문이다.
- slave 유실 81건은 311건 중 부모보다 먼저 끝난 경우다. 나머지는 부모가 먼저 끝나 우연히 성공했다.
- 결과 디렉터리: `ha_bench_tool/log/c3_fk_gap_20261021_191419/`

## 6. 영향 범위
- 분할 테이블을 FK로 참조하는 모든 자식 INSERT/UPDATE. 타이밍과 상관없이 라벨에서 부모가 빠진다.
- 같은 이유로 반대 방향도 의심된다(추정, 재현 안 함):
  - 분할 부모의 DELETE/UPDATE(WRITE, 분할 기준)는 앞선 자식들의 REF(루트 기준)를 찾지 못한다. 그래서 slave에서 부모 DELETE가 자식보다 먼저 실행될 수 있다(RESTRICT 실패 또는 CASCADE 누락).
  - 분할 테이블끼리 같은 PK를 WRITE하는 경우는 같은 분할로 가므로 서로 찾는다(추정).
- 결과는 C3와 같다: slave 행 유실, fail_counter만 오름.

## 7. 해결 방향 (제안, 미구현)
| 안 | 내용 | 장단점 |
|---|---|---|
| A | WRITE 키를 만들 때 대상이 분할이면 **루트 테이블 OID와 루트의 같은 인덱스**로 바꾼다 | 분할 테이블의 모든 unique 인덱스 쓰기에 매핑이 들어간다. 분할 BTID → 루트 BTID(같은 이름의 인덱스, 비어 있음) 매핑을 인덱스 갱신 경로에서 구해야 한다 |
| B (권장, 10-21 BTID 확인 뒤) | REF 키를 만들 때 FK 검사와 같은 방식으로 `partition_prune_unique_btid`를 불러 **분할 OID와 분할 BTID**로 만든다 | FK 검사가 이미 쓰는 함수라 새 매핑이 필요 없다. 바뀌는 곳이 분할 부모를 참조하는 FK의 REF 수집뿐이다. 부모의 UPDATE/DELETE WRITE도 분할 기준이라 6절의 반대 방향도 함께 맞는다(추정). 비용은 그 FK마다 pruning 1회 |
| C | 분할 테이블이 관련되면 commit-order 대체 경로로 보낸다 | 단순하지만 분할 테이블의 병렬도를 잃는다 |

B는 FK 검사가 정한 분할과 REF 키의 분할이 같다는 점을 이용한다. A는 PK의 키 값이 루트와 분할에서 같다는 점을 이용한다. 분할 테이블의 PK에는 분할 키가 들어가야 하므로 같은 값은 같은 분할로 간다. 그래서 루트 기준으로 바꿔도 다른 분할의 같은 값과 섞이지 않는다(추정, 분할 테이블 unique 규칙 확인 필요).

## 8. 구현 (`4ed4a84d0`, 안 B)
`locator_sr.c`:
- 새 함수 `locator_wset_resolve_ref_partition`: 참조 대상이 분할 테이블(`has_partition_info > 0`)이면 `partition_load_pruning_context` → `partition_prune_unique_btid`로 키가 속한 분할의 OID와 PK BTID로 바꾼다. `locator_check_foreign_key`가 부모 행을 찾는 방식과 같다. 분할 테이블이 아니면 그대로 둔다.
- `locator_wset_collect_fk_ref`: 루트 값(`ref_class_oid`, `ref_class_pk_btid`)에서 시작해, 키에 NULL 요소가 없으면 위 함수로 분할로 바꾼 뒤 `wset_add_ref_key`에 넘긴다. NULL이 있는 키는 부모를 참조하지 않으므로 `wset_add_ref_key`가 원래대로 건너뛴다.
- 자식 INSERT, 자식 UPDATE의 OLD/NEW 이미지(8775, 8781행 호출) 모두 이 함수를 지나므로 함께 바뀐다.
- 비용: 분할 부모를 참조하는 외래키 행마다 분할 계산 1회. 외래키 검사도 같은 계산을 한다.
- 검증 계획: 배포 뒤 `ROUNDS=500 FILLER=0 PART=4 ./c3_fk_gap.sh` → missed 0, slave 유실 0. 회귀는 분할 없는 `c3_fk_gap`, fk_multi.

### 8.1 검증 (10-21 22:38~22:54, 빌드 2778-4ed4a84, DB 22:37 재생성)
| 시험 | 조건 | 결과 |
|---|---|---|
| C11 재현 조건 | `ROUNDS=500 FILLER=0 PART=4` | ok 500, missed 0 (수정 전 missed 500, 유실 81). slave c3_c 500행, master와 id 목록 같음(직접 비교), fail_counter 0 |
| 강한 조건 | `ROUNDS=2000 FILLER=500 PART=4` | ok 2000, inverted 0, missed 0, fail_counter 0 |
| C3 회귀 (분할 없음) | `ROUNDS=2000 FILLER=500` | ok 2000, inverted 0, missed 0, fail_counter 0 |
| fk_multi (12분) | 6 스키마 | 테이블 20/20 같음, fail_counter delta 0, gate 순서 위반 0 |

## 9. 열린 질문
1. ~~분할의 PK 인덱스 BTID가 루트와 다른지~~ → 10-21 확인: 분할마다 별도 B-tree, 루트 인덱스는 비어 있음(3.3절).
2. 6절의 부모 DELETE 방향은 재현하지 않았다.
3. range/list 분할도 같은지(경로가 같으므로 같을 것으로 추정).
