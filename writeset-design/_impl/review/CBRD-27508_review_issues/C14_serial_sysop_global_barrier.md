# C14. serial·AUTO_INCREMENT sysop마다 slave에 전역 장벽이 생김

## 1. 메타
| 항목 | 내용 |
|---|---|
| 등급 | Medium(설계) → **이번 프로젝트 제외, 최적화 과제로 이관(10-23)** |
| 상태 | 원인은 코드로 확인. 1회 측정(10-23). 수정 안 함 |
| 판정 | 결함이 아니라 정확성을 위해 고른 보수적 설계의 비용 |
| 신규/기존 | 신규 |
| 관련 | 종합 문서 4절의 미검증 주장 "serial 키 수집이 현재 설계와 맞지 않아 늘 버려진다"(architect_1y)도 같은 영역이라 함께 이관 |
| 지적한 리뷰어 | 5명(종합 문서 2절) |
| 코드 기준 | `882308890` |

## 2. 원인 (master, `log_manager.c:4040`~`4072`)
serial 값을 바꾸는 시스템 연산(SYSOP_END_COMMIT, 복제 항목 있음)은 키 단위로 처리하지 않고 commit order로 처리한다.
```c
    /* Commit order: label the operation with the latest coordinate published so far ... the history floor
     * raised below makes every later transaction wait for it. No key is published. */
    wset_find_sysop_fallback_dependency (tdes, &tdes->wset_dependency_seq);   // 앞의 모든 커밋 뒤
    log_append_wset_label_and_sysop_end (...);
  ...
  if (sysop_commit_order)
    {
      wset_raise_history_start (&sysop_lsa, "SYSOP_COMMIT_ORDER");   // 뒤의 모든 트랜잭션이 이것을 기다림
      wset_discard_sysop_keys (tdes, sysop_key_begin);              // serial 키는 버림
    }
```
- slave에서 serial 갱신 한 번이 "앞뒤 모든 트랜잭션이 줄을 서는" 장벽이 된다. serial과 상관없는 테이블의 트랜잭션도 기다린다.
- AUTO_INCREMENT는 serial 캐시(기본 20)를 다시 채울 때마다 serial 행을 갱신하므로, INSERT 20건마다 장벽이 하나 생긴다. 캐시가 없는 serial은 매 건마다 생긴다.
- AUTO_INCREMENT용 serial은 `ALTER SERIAL`로 바꿀 수 없다("is an 'auto_increment' object, which is not allowed to be altered as a serial").

## 3. 측정 (10-23, 빌드 2786-8823088, youngjun3 master / youngjun4 slave, worker 10)
하니스 `ha_bench_tool/bin/c14_serial_barrier.sh`: youngjun4 applylogdb를 멈춘 채 master에서 8세션 × 2500행(행마다 커밋)을 쌓고, applylogdb를 켜서 백로그를 다 적용하는 시간을 잰다. 적용 시간은 slave trace의 첫 retire부터 마지막 retire까지다.

| 경우 | 테이블 | slave의 serial 조각 수 | slave 적용 시간 | PK 대비 |
|---|---|---|---|---|
| PK 직접 | `id INT PRIMARY KEY`, 값을 세션이 줌 | 0 | 2.6초 | 1배 |
| AUTO_INCREMENT | `id INT AUTO_INCREMENT PRIMARY KEY` (serial 캐시 20) | 1000 | 7.7초 | 약 3배 |
| serial NOCACHE | `id = c14_s.NEXT_VALUE`, `CREATE SERIAL c14_s NOCACHE` | 20000 | 38.5초 | 약 15배 |

- 세 런 모두 데이터 20000/20000, fail_counter 0.
- 1회치다. youngjun3과 youngjun4는 같은 호스트를 나눠 쓰는 것으로 보이고(uptime·load가 같음), load가 100을 넘는 순간이 있어 시간이 흔들린다. NOCACHE 런 도중 load가 9에서 41로 올랐다. 그 전에 돌린 런(load 100 이상)은 버렸다.
- 결과 디렉터리: `ha_bench_tool/log/c14_serial_barrier_{pk,ai,serial_nocache}_20261023_1654*`

## 4. 최적화 방향 (이관 내용)
같은 자리 TODO에 적힌 키 단위 처리다. serial 조각이 자기 serial 행의 키만 등록하고, 같은 serial을 다시 바꾸는 조각만 그 뒤에 서게 한다. AUTO_INCREMENT 테이블의 일반 INSERT 행은 서로 병렬로 돌 수 있다.

보류 사유(TODO):
- serial `INCR/DECR`, checksumdb, overflow 트랜잭션은 라벨이 없어 commit-order 장벽이 여전히 필요하다.
- 라벨이 `prev_commit_lsa`로 낮춰져 SYSOP_END 위치보다 아래가 되는 경우, 한 트랜잭션 안의 여러 조각 사이의 순서, 재시작 때의 멱등성이 정리되지 않았다.

## 5. 열린 질문
1. 측정 반복(부하가 낮을 때 3회 이상)과 worker 1개(직렬) 기준값.
