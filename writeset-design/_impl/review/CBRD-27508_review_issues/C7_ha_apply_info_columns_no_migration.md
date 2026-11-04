# C7. `_db_ha_apply_info` 새 컬럼에 마이그레이션이 없음

## 1. 메타
| 항목 | 내용 |
|---|---|
| 등급 | 종합 문서 High → **정책 판단(수정 안 함)** |
| 상태 | 판정 완료(10-23). 하위 버전으로 포팅하지 않으므로 다음 버전의 업그레이드 절차에 맡긴다 |
| 판정 | 사실은 확정(코드). 같은 버전으로 만든 DB에서는 생기지 않는다 |
| 신규/기존 | 신규. 원인 커밋 `45825ca17`(slave 병렬 applylogdb) |
| 관련 | [C8](C8_log_record_type_53.md)(같은 판단). [C17](C17_recovery_range_statement_reapply.md)의 표시 테이블은 해당 없음(4절) |
| 지적한 리뷰어 | 7명(종합 문서 2절) |
| 코드 기준 | `a361cca24` |

## 2. 문제
이 브랜치는 slave DB의 시스템 카탈로그 `_db_ha_apply_info`에 컬럼 2개를 추가했다.
```c
/* schema_system_catalog_install.cpp:1096, _db_ha_apply_info 정의 */
      {"max_committed_lsa_pageid", "bigint"},
      {"max_committed_lsa_offset", "integer"}
```
applier는 시작할 때 이 컬럼을 읽고, 실패하면 종료한다.
```c
/* log_applier.c:2948, la_get_ha_apply_max_committed_lsa */
  "SELECT max_committed_lsa_pageid, max_committed_lsa_offset FROM %s WHERE db_name = ? AND copied_log_path = ? ;"

/* log_applier.c:3400, la_get_last_ha_applied_info */
  res = la_get_ha_apply_max_committed_lsa ();
  if (res != NO_ERROR)
    return res;

/* log_applier.c:9966, la_apply_log_file */
  error = la_get_last_ha_applied_info ();
  if (error != NO_ERROR)
    {
      er_set (..., "Failed to initialize _db_ha_apply_info");
      la_shutdown ();
      return error;
    }
```

## 3. 언제 생기나
`_db_ha_apply_info`는 `createdb`할 때 그 바이너리의 정의대로 만들어진다.

| 경우 | 결과 |
|---|---|
| 이 브랜치 바이너리로 DB를 새로 만듦 (지금까지의 시험) | 문제없음 |
| 이전 버전으로 만든 DB를 이 브랜치 바이너리로 띄움 | 컬럼이 없어 SELECT가 실패하고, applier가 시작할 때마다 "Failed to initialize _db_ha_apply_info"로 종료. heartbeat가 다시 띄워도 같음 |

## 4. C17 표시 테이블은 해당 없음
C17에서 추가한 `ha_applied_stmt_marker`는 카탈로그가 아니다. applier가 시작할 때 `CREATE TABLE IF NOT EXISTS`와 `INSERT ... WHERE NOT EXISTS`로 직접 만든다(`la_create_applied_stmt_marker`, `log_applier.c:3638`). 그래서 이전 버전으로 만든 DB에서도 시작할 때 생긴다.

## 5. 판단
- 이 기능은 develop을 거쳐 다음 버전으로만 나간다. 하위 버전으로 포팅하지 않는다(사용자 결정, 10-23).
- 그래서 이전 버전 DB를 쓰는 경우는 버전 업그레이드뿐이고, 버전 사이의 카탈로그 변경은 업그레이드 절차가 다룬다. 코드에서 컬럼 유무를 따로 처리하지 않는다.
- 병합 직후 develop 개발·QA 환경에서 예전 develop으로 만든 DB를 쓰면 같은 증상이 난다. DB를 다시 만들면 된다. 병합할 때 알린다.

## 6. 열린 질문
1. 다음 버전의 업그레이드 절차가 카탈로그를 새로 만드는지(unloaddb/loaddb), 카탈로그를 고치는 migrate 도구를 쓰는지 확인하지 않았다. migrate 도구라면 이 두 컬럼을 추가하는 단계가 그 도구에 들어가야 한다.
