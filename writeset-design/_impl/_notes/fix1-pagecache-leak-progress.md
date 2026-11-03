---
tags: [writeset, applylogdb, pagecache, fix1, 완료]
date: 2026-10-03
status: 구현 완료 / 디버그+릴리스 컴파일 검증 통과 / 미커밋
code-base:
  repo: /home/youngjun/Workspace/cubrid-applier (병합본, 미커밋, dirty)
  build_debug: /home/youngjun/Workspace/cubrid-applier-build (Debug, Unix Makefiles, CS+unit)
  build_ninja: /home/youngjun/Workspace/cubrid-applier/build_x86_64_release (RelWithDebInfo, Ninja)
---

# Fix 1 — page-cache fix_count 누수 교정 (ER_LOG_PAGE_CORRUPTED 크래시 루프)

## 결론 요약

레코드가 로그 페이지 경계를 넘을 때, 읽기/디코드 매크로(`LA_LOG_READ_ADVANCE_WHEN_DOESNT_FIT`,
`LA_LOG_READ_ALIGN`)가 다음 페이지를 `la_get_page(++pageid)`로 추가 fix 하는데, 적용 함수들은
시작 페이지(`old_pageid`) 한 장만 release 한다. 넘어간 페이지의 fix_count가 0으로 돌아오지
못해 지연 invalidate 상태(`invalidate_pending=true`)가 영구 고착되고, 그 페이지의 모든
`la_get_page_buffer()`가 해시히트 분기에서 NULL을 반환 → reader 재시도(~10회/3초) 소진 →
`ER_LOG_PAGE_CORRUPTED`(log_applier.c la_apply_log_file) → reader 자발 shutdown → 재시작마다
같은 페이지에서 재크래시.

교정: 경계를 넘으며 추가로 fix 한 페이지를 읽기 종료 시 모두 release 한다. 시작 페이지는
호출자가 소유하므로 건드리지 않는다. 지연 invalidate 로직 자체(병렬 모드에서 올바름)는 유지한다.

## 스코프 결정 (minimal, single-concern)

관측된 크래시 경로(워커 적용: `la_apply_insert_log` / `la_apply_update_log` →
`la_get_recdes` → `la_get_log_data` → `la_log_copy_fromlog`, UPDATE는 추가로
`la_get_undoredo_diff`)를 정확히 교정한다.

- **`la_apply_delete_log`: 누수 없음(수정 안 함).** 로그 페이지를 읽지 않는다 — `la_get_page`
  호출이 없고 이미 파싱된 `item->key` / `class_name` 만 사용한다. update/insert/delete를 대칭
  추적한 결과 delete는 페이지를 한 장도 fix 하지 않는다.
- **`la_get_undoredo_diff`: 별도 수정 불필요.** 호출부
  `la_get_undoredo_diff(context, &pg, &pageid, &offset, ...)`가 `&pageid`를 넘기고 diff가
  종료 시 `*pageid = temp_pageid`로 전진 위치를 되돌려주므로, diff의 매크로 경계 넘김은
  `la_get_log_data`의 `pageid`에 반영된다. diff 내부 `la_log_copy_fromlog`는 자기 해제한다.
  따라서 diff가 추가 fix 한 페이지는 `la_get_log_data`의 종료 해제 범위에 포함된다(아래 증명).

반면 아래는 **같은 누수 패턴이 잠재하지만 이번 최소 수정에서 제외**한다(관측 크래시 경로가
아니고, 단순 해제가 위험하거나 호출자 협조가 필요함 — "남은 작업" 참조):
`la_make_repl_item`, `la_retrieve_eot_time`, `la_retrieve_wset_label`,
`la_retrieve_sysop_end_type`, `la_get_ha_server_state`, `la_get_next_update_log`,
`la_get_next_repl_item_from_log`. 단, 공유 함수 `la_log_copy_fromlog`의 자기 해제는
이들 중 데이터 복사 경로의 경계 넘김 누수를 부수적으로 막는다.

## 변경 내용 (file:line, before→after)

### 1) 신규 헬퍼 `la_release_extra_page_buffers` (log_applier.c, `la_release_page_buffer` 직후, ~1459)

```c
/* 경계를 넘으며 추가로 fix 한 페이지(first 이후)를 모두 release. first는 호출자 소유라 제외.
   전진 읽기만 하므로 (first, last] 는 각각 정확히 한 번 fix 됐다. 이미 drop된 페이지에 대한
   release는 해시 미스로 no-op. */
static void
la_release_extra_page_buffers (LOG_PAGEID first_pageid, LOG_PAGEID last_pageid)
{
  LOG_PAGEID pageid;
  for (pageid = first_pageid + 1; pageid <= last_pageid; pageid++)
    {
      la_release_page_buffer (pageid);
    }
}
```

### 2) `la_log_copy_fromlog` (데이터 복사, 모든 읽기 경로가 공유)

- 진입부: `LOG_PAGEID first_pageid = log_pageid;` 추가(호출자 소유 페이지 기록).
- 두 복사 루프 종료 직후(단일 종료점)에 `la_release_extra_page_buffers (first_pageid, log_pageid);` 추가.
- 효과: 복사 중 `la_get_page(++log_pageid)`로 fix 한 페이지를 전부 release. `log_pageid`는
  값 전달 파라미터라 호출자 커서에는 영향 없음 → 호출자가 쓰던 진입 페이지는 보존.

### 3) `la_get_log_data` (레코드 레코드 디스크립션 추출 — 워커 크래시의 중심 경로)

- 지역 변수 `LOG_PAGEID first_pageid = NULL_PAGEID;` 선언, `pageid = lsa->pageid;` 직후
  `first_pageid = pageid;` 로 진입 페이지 고정.
- 7개 반환 지점 각각 앞에 `la_release_extra_page_buffers (first_pageid, pageid);` 추가:
  1. 첫 `LA_LOG_READ_ALIGN` 실패 반환
  2. `la_get_undoredo_diff` 오류 반환
  3. switch default 반환
  4. switch 직후 오류 반환
  5. `malloc` 실패(ER_OUT_OF_VIRTUAL_MEMORY) 반환
  6. unzip 실패(ER_IO_LZ4_DECOMPRESS_FAIL) 반환
  7. 정상 종료 반환
- `pageid`는 진입 후 오직 `la_get_page`(매크로 + diff의 `&pageid`)로만 증가하므로
  `(first_pageid, pageid]` 구간이 이 호출이 추가로 fix 한 전부다.

공유 매크로(`LA_LOG_READ_*`) 자체와 `la_apply_insert_log`/`la_apply_update_log`/
`la_apply_delete_log`의 기존 `la_release_page_buffer(old_pageid)`는 **변경하지 않았다**.

## fix/release 짝 증명 (fix_count 균형)

표기: 한 레코드 읽기에서 fix 되는 페이지는 `P0=old_pageid`(=`lsa->pageid`), 이어서
`P1, P2, …`(경계 넘김). 전진 읽기라 단조 증가.

### INSERT 경로 (`la_apply_insert_log`)
1. `old_pageid = item->target_lsa.pageid`; `la_get_page(old_pageid)` → fix(P0)=+1. (호출자 소유)
2. `la_get_recdes → la_get_log_data`: `first_pageid=P0`.
   - 헤더/정렬 매크로가 P0→P1→… 넘기며 fix(P1..Pk). 정상·오류 모든 반환 앞에서
     `la_release_extra_page_buffers(P0, pageid=Pk)` → release(P1..Pk). **P0은 건드리지 않음.**
   - 본문 데이터는 `la_log_copy_fromlog`가 Pk→…→Pm 넘기며 fix, 자기 종료점에서
     release(Pk+1..Pm). (copy의 first=Pk이므로 Pk 미해제 = la_get_log_data가 해제.)
3. 반환 후 `la_release_page_buffer(old_pageid=P0)` → release(P0).
- 합계: P0..Pm 각각 +1 fix / −1 release. **균형.** 지연 invalidate가 걸려 있었어도 마지막
  release에서 fix_count==0 도달 → `invalidate_pending` 해제 가능.

### UPDATE 경로 (`la_apply_update_log`)
INSERT와 동일하되 DIFF_UNDOREDO면 `la_get_log_data`가 `la_get_undoredo_diff` 호출.
- diff는 `&pageid`로 `la_get_log_data`의 `pageid`를 전진시킴(diff의 매크로 fix가 상위 커서에 반영).
- diff 내부 `la_log_copy_fromlog`(undo 복사)는 자기 해제.
- diff 종료 후 `la_get_log_data`의 `pageid`=diff 최종 페이지 → 종료 시 `la_release_extra_page_buffers`가
  diff가 넘긴 페이지까지 release. **같은 페이지가 copy(자기)와 ADD_ALIGN(상위)로 각각 fix/‐release
  돼도 각 fix가 정확히 한 번의 release와 짝**이므로 과해제 없음.
- 나머지는 INSERT와 동일. **균형.**

### DELETE 경로 (`la_apply_delete_log`)
페이지 fix 자체가 없음 → 불균형 소지 없음. (수정 불필요 확정.)

## self-heal 복원 결정 — **복원하지 않음**

- 누수가 제거되면 지연 invalidate의 전제("남은 fixer가 반드시 release 해 fix_count==0 도달")가
  성립한다. reader+worker 동시 fix(fix=2) 경합도: reader invalidate(pending, fix=2→1) 후
  worker release(fix→0)에서 `la_release_page_buffer`가 `invalidate_pending`을 보고 drop+clear →
  정상 회수. 누수만 없으면 이 경로로 항상 해소되므로 self-heal 없이 충분하다.
- HEAD의 해시히트 self-heal(`mht_rem`)을 지금 복원하면 위험하다: `fix_count>0`(워커 보유)인
  버퍼를 해시에서 떼면 이후 그 fixer의 `la_release_page_buffer`가 `mht_get` 미스로 no-op가 되어
  fix_count가 오히려 영구히 >0로 남고 버퍼가 재사용 불가가 된다(pagecache-race-analysis §6-2가
  지적한 "fix_count>0이면 메모리 재사용 차단" 충돌). 따라서 최소·안전 원칙상 추가하지 않는다.
- `la_get_page_buffer`의 헤더불일치(`logical_pageid != pageid`) 분기는 방어용으로 남긴다.
  현재 해시에 들어가는 버퍼는 `la_get_page_buffer`가 fetch 후 헤더 일치를 확인하고 put 하므로
  (불일치 시 put 전에 NULL 반환), "해시에 있으면서 헤더 불일치 + fix_count>0 영구고착"을 만드는
  알려진 경로는 없다. 잔여 검토 대상으로만 둔다(아래).

## 빌드 결과 (디버그 전용, 배포/실행 없음)

컴파일 전용 검증(링크/배포/HA 실행 안 함). `log_applier.c`는 이 두 빌드 구성에서 CS 모드로만
컴파일된다(applier는 client/standalone 코드; server 모드 미포함).

- Debug (Unix Makefiles, gcc, `cubrid-applier-build`):
  `make -f cs/CMakeFiles/cubridcs.dir/build.make .../log_applier.c.o`
  → `Building CXX object ... log_applier.c.o`, **EXIT=0**, 오브젝트 mtime 갱신 확인.
- RelWithDebInfo (Ninja, `build_x86_64_release`):
  `ninja .../log_applier.c.o` → `Building CXX object ... log_applier.c.o`, **EXIT=0**.
- 경고/에러 없음(프로젝트 strict 플래그로 컴파일). `first_pageid` 미사용 경고 없음 → 모든 경로에서 사용됨.

주: 이 두 빌드 구성에는 `cubridsa`(SA) / `cub_server`(SERVER) 의 log_applier 오브젝트 규칙이
없어 세 모드 전수 컴파일은 못 했으나, 변경은 `#ifdef`(SERVER/SA/CS)와 무관한 평범한 static 함수
+ 일반 호출이라 모드 의존성이 없다.

## 남은 불확실 / 사용자 검토 필요

1. **리더 경로 잠재 누수(이번 범위 제외)**: `la_make_repl_item`(3243/3249/3259 경계 넘김),
   `la_retrieve_eot_time`, `la_retrieve_wset_label`, `la_retrieve_sysop_end_type`,
   `la_get_next_repl_item_from_log`(7043 재fetch, 7066에서 break 시 7073 release 건너뜀) 도
   경계 넘김 시 추가 페이지를 누수한다. 관측 크래시는 워커 경로라 우선 제외했으나, 리더가
   그 페이지를 뒤에 invalidate 하면 같은 persistent-NULL이 가능. 동일 `first_pageid` + 종료
   해제 패턴으로 확장 가능(각 함수는 값 복사 후 반환하므로 해제 안전). 다음 라운드 권장.
2. **`la_get_ha_server_state`(5012): 특수 — 페이지 내부 포인터 반환.** `state`가
   `pg->area` 내부를 가리켜 반환되므로 호출자(7398)가 그 페이지를 계속 쓴다. 이 함수가 경계를
   넘으면 반환 포인터는 next 페이지에 있는데 호출자는 그 pageid를 모른다. 해제 소유권을
   호출자로 넘기는 설계(반환 pageid 전달)가 필요 → 단독 처리. 지금은 변경하지 않음.
3. **`la_get_next_update_log`(REC_ASSIGN_ADDRESS/RELOCATION 경로): 복잡 — 보류.** 매크로
   전진(`pg` 재대입)을 forw_lsa 페이지 추적 수단으로 겸용하고, 내부 루프 각 매칭 레코드마다
   `pageid`를 재설정하며, 4826에서 outer 페이지를 재fetch(현재 무해제)한다. 단순 범위 해제가
   "읽는 중인 페이지"를 떼어낼 위험이 있어 전용 분석+HA 테스트가 필요. 이번 최소 수정 제외.
   (단 내부 `la_log_copy_fromlog`의 데이터 복사 누수는 공유 자기해제로 이미 막힘.)
4. **검증 한계**: 컴파일만 확인했고 HA 2노드 실측(page-corrupted 재현/소멸)은 미실시(지시대로
   실행/배포/재시작 안 함). 재개 시 동일 workload로 크래시 루프 소멸 + fail=0 유실 재현 여부
   확인 필요.

## 리뷰용 greppable 마커

리뷰 시 아래 한 문자열로 모든 핵심 수정 지점을 바로 찾을 수 있다.

```
writeset parallel: page-cache fix_count leak fix
```

찾기: `grep -n "writeset parallel: page-cache fix_count leak fix" src/transaction/log_applier.c`

배치 지점(`src/transaction/log_applier.c`, 줄 번호는 동시 편집으로 어긋날 수 있으니 grep 기준):

| 줄 | 위치 | 역할 |
|---|---|---|
| ~1460 | `la_release_extra_page_buffers` 정의 주석 | 누수 교정 메커니즘 + 이유 설명 |
| ~3154 | `la_log_copy_fromlog` 종료 release | 데이터가 페이지 경계를 넘는 복사의 추가 페이지 해제(이유 전문) |
| ~4562 | `la_get_log_data` 정상 종료 release | INSERT/UPDATE 레코드 읽기의 추가 페이지 해제 — 관측 크래시의 결정적 경로(이유 전문) |
| ~5338 | `la_apply_delete_log` 선두 | DELETE는 페이지를 fix 하지 않아 누수 없음을 명시(대칭 리뷰용 hit) |
| ~5545 | `la_apply_update_log` old_pageid release | 첫 페이지만 해제, 추가 페이지는 읽기 경로에서 해제됨을 안내 |
| ~5744 | `la_apply_insert_log` old_pageid release | 위와 동일 |

마커 뒤 설명은 실제 동작만 서술(내부 단계번호·문서 절 참조 없음). `la_get_log_data`의 7개
release 호출은 모두 같은 헬퍼를 부르므로 `grep la_release_extra_page_buffers`로 전수 확인 가능.
마커 추가 후 debug 재컴파일 EXIT=0 유지.

## 미커밋 상태

커밋/병합/배포/HA 실행 없음. cubrid-applier dirty 그대로. 변경 파일: `src/transaction/log_applier.c`
한 곳(헬퍼 1개 + `la_log_copy_fromlog`/`la_get_log_data` 해제 호출). 사용자 리뷰 대기.
