# wide 테이블 불일치 end-to-end 추적 (2026-10-11, F seed 20261019)

실행 `ha_bench-sysop-random/sysop_runs/20261011T083126-20261019-1398960`. 하니스 판정 DATA_DIVERGENCE, wide 외 48개 테이블·DDL은 master = slave = model.

## 관찰
| 항목 | master | slave |
|---|---|---|
| wide 행 | 1, 2, 3, 4 | 4만 |
| 카운터 | 전부 5 | 0 |
| checkdb (`--check-btree-entries --check-heap`, wide 클래스만) | 이상 없음 | 이상 없음 → 행 1~3은 인덱스뿐 아니라 heap에도 없음 |

wide 트랜잭션 20건은 `wide[ordinal] % 2 == 0`이면 commit, 대상 행은 `wide[ordinal] % 4 + 1`. 따라서 commit 10건은 행 1·3, abort 10건은 행 2·4를 INCR한다.

## 결함 B (확인): 긴 트랜잭션 안의 INCR SYSOP이 바깥 abort와 함께 버려짐
- 1,001컬럼 INCR SYSOP은 항목 1,001개라 바깥 트랜잭션이 긴 트랜잭션이 된다. `la_detach_sysop_fragment`는 바깥이 긴 트랜잭션이면 NULL을 돌려주므로 SYSOP_END가 `action=defer long=1`로 남는다.
- master에서 INCR은 SYSOP으로 따로 커밋되어 바깥 rollback 뒤에도 남는다(master 행 2·4 카운터 5). slave는 바깥 abort 때 보류한 항목을 버린다(`reader abort ... items=1`). 바깥이 commit하면 커밋 시 로그 재독으로 함께 적용된다.
- 로그 근거: slave UPDATE 실패 -711이 key 1과 3에만 각 5,005건(= commit 5건 × 1,001컬럼). 행 2·4 대상(abort)은 적용 시도 자체가 없다.

## 결함 A (미확정): preload 끝의 wide 행 1~3 누락
### 따라간 경로와 확인 사실
1. master: preload는 csql 한 트랜잭션(parent 8 + item 48,000 + wide 4). AUTO_INCREMENT 행마다 serial SYSOP, 행 복제 레코드 48,012건은 커밋 시점에 기록.
2. slave reader: serial SYSOP 48,000개는 조각(type=20, items=1)으로 적용. 바깥은 1,000건 초과로 긴 트랜잭션 전환(`la_set_repl_log`, 첫 항목만 남김), 커밋에서 `items=1`.
3. slave worker 4 (trid 3733221, dispatch 754158): 첫 항목부터 `la_get_next_repl_item_from_log`로 로그를 재독하며 적용. `rows=48012 error=0`(wide 4건 포함 처리), 1.14초, 마지막 flush `unflushed=12` error=0, commit 정상. 이 구간 ERROR 0, `-1032` 0, 진단 로그(`la_get_recdes` 실패, 레코드 타입/rcvindex 불일치) 0.
4. client INSERT 경로(`la_apply_insert_log`): 오류 없이 건너뛰는 분기 없음. 레코드 풀 칸 = `db_iopagesize`(16KB) > wide 행(약 4.2KB), 압축 레코드도 풀로 memcpy.
5. 전송(`locator_repl_flush_all` / `locator_repl_mflush(_force)` / `locator_send_copy_area` / `locator_repl_force`): develop과 동일(diff 확인). 전송 버퍼 DB_PAGESIZE 16KB.
6. server(`xlocator_repl_force` → `locator_repl_prepare_force` → `locator_insert_force`): INSERT는 repr id 교체 후 삽입. 중복 키면 반드시 오류가 reply로 돌아간다.
7. 같은 트랜잭션의 item 48,008행, 특히 마지막 flush에 같이 실린 item_47 행 8건은 slave에 있다.

### 남은 가설 (근거 수준)
- 마지막 flush 12건(item_47 8 + wide 1~4)은 크기상 wide 3 다음에서 전송이 한 번 끊긴다(첫 전송: item 8 + wide 1~3, 둘째: wide 4). 누락 행과 경계가 정확히 일치. 그러나 같은 첫 전송의 item 8건은 반영되어 있어 "첫 전송 통째 유실"과는 맞지 않는다. 추정.
- 긴 트랜잭션 재독이 wide 1~3 항목의 target_lsa를 잘못 잡아 다른 레코드 이미지로 INSERT(중복이면 오류가 남아야 하므로 맞지 않음). 추정.
- 10-08 Run 1(preload 412건, 긴 트랜잭션 아님)에서는 wide 행 4개가 slave에 있었으나 읽으면 서버가 죽는 손상 상태. 증상이 다르지만 "큰 레코드(wide 행)를 실은 flush"라는 공통점.

### 원자료 한계
F의 master trace는 로그 교체로 비었고(하니스 수정 전), master DB 로그는 이후 6GB 넘게 진행해 preload 구간이 덮였다. 확정에는 재현이 필요하다.

### 재현 실험 계획 (미실행, 지시 대기)
1. preload 소량(테이블 2 × 10행, 긴 트랜잭션 아님) + wide 4행 → wide 문제가 긴 트랜잭션과 무관한지.
2. 1과 같고 `--wide-columns 100`(작은 레코드) → 레코드 크기/전송 버퍼 경계 영향.
3. preload 대량(긴 트랜잭션) + wide 4행 → F 재현.
각 실험에서 슬레이브 trace level 2 로그로 flush 단위·서버 reply를 보고, slave wide 행을 checkdb와 PK 조회로 확인. 필요하면 `locator_repl_mflush`/`xlocator_repl_force`에 객체별 진단 로그를 임시로 추가.
