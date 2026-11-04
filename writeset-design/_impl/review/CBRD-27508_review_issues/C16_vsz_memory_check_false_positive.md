# C16. worker가 여럿이면 VSZ 메모리 검사가 놀고 있는 applier를 종료시킴

## 1. 메타
| 항목 | 내용 |
|---|---|
| 등급 | Medium |
| 상태 | 수정 커밋 `882308890`(10-23). 빌드 2786-8823088에서 `ha_apply_max_mem_size=500`으로 시험 통과(6절). 수정 전 종료는 실측하지 않음 |
| 판정 | 부분 확정. 검사 방식과 측정 시점은 코드로 확정, 수정 전 오탐 종료는 추정 |
| 신규/기존 | 기존 검사(develop과 같음) + 병렬화로 노출 |
| 지적한 리뷰어 | 3명(종합 문서 2절) |
| 코드 기준 | `882308890` |

## 2. 용어
- **VSZ**(가상 메모리 크기): 프로세스가 예약한 주소 공간 전체. 아직 쓰지 않은 영역도 포함한다. `/proc/<pid>/status`의 `VmSize`.
- **RSS**(상주 메모리 크기): 그중 실제로 물리 메모리에 올라와 쓰이는 양. `VmRSS`.
- **malloc arena**: glibc malloc이 여러 스레드가 서로 기다리지 않도록 스레드마다 만드는 할당 영역. 64비트에서 하나가 최대 64MB의 주소 공간을 미리 예약한다.

## 3. 검사 (develop과 같음)
applier는 메인 루프마다 VSZ를 재서(`la_get_mem_size`, `/proc/self/statm`) 다음보다 크면 `ER_HA_LA_EXCEED_MAX_MEM_SIZE`(-1035)를 남기고 종료한다(`la_check_mem_size`, `log_applier.c:8365`, 호출 `:10512`). heartbeat가 다시 띄운다.
```
max(ha_apply_max_mem_size, start_vsize × 2)
```
- 절대 상한(`ha_apply_max_mem_size`, 기본 500MB)과 상대 상한(시작 때의 2배, 누수 검사) 중 큰 쪽이다.
- 시작 후 `HB_START_WAITING_TIME_IN_SECS`(10초) 동안은 검사하지 않는다.
- 이 측정값은 이 검사에만 쓰인다. 진단 덤프에 `start_vsize`를 찍는 것 말고 다른 판단에는 쓰이지 않는다.

## 4. 문제 (수정 전)
- `start_vsize`를 `la_init`에서 쟀다. 이때는 worker가 아직 없다. worker는 그 뒤 `la_start_apply_workers`에서 뜬다.
- worker마다 malloc arena가 생겨 VSZ가 크게 늘어난다. 실측(worker 10개, 놀고 있음): VSZ 905MB, RSS 17~18MB.
- 그래서 기본값 500MB로 쓰면 `max(500MB, 작은 start_vsize × 2)`를 넘어 놀고 있는데도 종료하고, 재시작해도 같은 일이 반복될 수 있다(추정). 우리 시험 conf는 4096이라 드러나지 않았다.
- develop은 스레드가 하나라 `la_init`에서 잰 값이 평소 크기와 같았다.

## 5. 수정 (`882308890`)
기준을 worker가 뜬 뒤에 잰다. 검사 방식(VSZ, 2배)은 develop 그대로 둔다.
```c
/* la_check_mem_size (log_applier.c:8357) */
  vsize = la_get_mem_size ();

  /* The baseline of the growth check is taken here, at the first check after the startup wait, not in
   * la_init: the workers start later, and each reserves its own malloc arena, so an idle applier with its
   * workers is far larger in virtual size than the process la_init measured. */
  if (la_Info.start_vsize == 0)
    {
      la_Info.start_vsize = vsize;
    }

/* la_init (:8718): 시작 때 재던 코드와 static 변수를 지움 */
  /* start_vsize stays 0 here; la_check_mem_size takes it once the workers have started */
```
- `la_start_apply_workers` 바로 뒤에 재지 않은 이유: `la_worker_start`는 스레드만 만들고 돌아오고, worker 초기화(DB 접속, 버퍼)는 각 스레드에서 따로 진행된다. 바로 뒤에 재면 arena가 아직 없을 수 있다. 검사가 원래 건너뛰는 시작 10초가 지난 첫 검사에서 잰다.
- 브랜치에 있던 긴 TODO 주석(RSS로 바꾸거나 worker 시작 뒤에 재자는 내용)은 지금 동작을 설명하는 주석으로 바꿨다.

| (worker 10개, 놀고 있음, 기본 500MB) | 수정 전 | 수정 후 |
|---|---|---|
| 기준 | worker 없는 프로세스 크기 | worker가 뜬 뒤 크기(약 905MB) |
| 종료 기준 | max(500MB, 작은 값 × 2) → 905MB가 넘음(추정) | max(500MB, 1810MB) → 넘지 않음 |
| 누수 검사 | 오탐 때문에 의미 없음 | 시작 대비 2배로 불어나면 종료 |

**남는 점.** 시작 10초 안에 큰 트랜잭션을 적용해 메모리가 이미 커져 있으면 그 값이 기준이 되어 누수 검사가 느슨해진다. 절대 상한은 그대로 적용된다.

## 6. 시험 (10-23 15:16, 빌드 2786-8823088)
- conf `cubrid_ha.conf.c13_c16`(md5 `5b67ebe1`, `ha_apply_max_mem_size=500` 포함)로 양쪽 HA를 다시 올렸다.

| 노드 | applier 시작 | 1분 뒤 VmSize | VmRSS | 스레드 | -1035 |
|---|---|---|---|---|---|
| youngjun3 | 15:16:25 | 905620 kB | 17280 kB | 13 | 0건 |
| youngjun4 | 15:16:42 | 905604 kB | 17280 kB | 13 | 0건 |

- VSZ가 설정 500MB를 넘었는데 종료하지 않았다. 이어서 C13 부하(40000행)를 적용하는 동안에도 applier pid가 그대로였다.
- 시험 뒤 conf는 기준(ea141281)으로 되돌렸다.

## 7. 열린 질문
1. 수정 전 빌드에서 500MB로 실제로 종료되는지는 측정하지 않았다.
2. 검사를 RSS 기준으로 바꿀지. develop의 검사 의미가 바뀌므로 이번 범위에서는 하지 않았다.
