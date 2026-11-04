# C12. writeset 라벨을 읽지 못하면 "의존 없음"으로 처리함

## 1. 메타
| 항목 | 내용 |
|---|---|
| 등급 | Medium |
| 상태 | 수정 커밋 `caa9d33f1`(10-23). 빌드 2786-8823088에서 회귀 확인. 읽기 실패 자체는 훅 없이 만들 수 없어 재현하지 않음 |
| 판정 | 코드로 확정. 빈도는 아주 낮음(추정), 생기면 오류 없이 데이터가 달라짐 |
| 신규/기존 | 신규. 원인 커밋 `45825ca17` |
| 지적한 리뷰어 | 4명(종합 문서 2절) |
| 코드 기준 | `882308890` |

## 2. 용어
- **라벨**: master가 커밋마다 커밋 레코드 바로 앞에 남기는 로그 레코드(`LOG_DUMMY_WSET_LABEL`). "이 트랜잭션은 어느 커밋 뒤에 실행해야 하는지"(dependency)를 담는다.
- **dependency가 NULL**: 앞의 어떤 커밋도 기다리지 않고 바로 실행해도 된다는 뜻. master가 겹치는 키가 없다고 판단하면 정상적으로 이렇게 쓴다.
- **라벨이 없음**: 충돌을 알 수 없다는 뜻. 커밋은 바로 앞 커밋을 기다린다(`la_coordinator_set_commit_dependency`, `log_applier.c:7759`).

## 3. 문제 (수정 전)
```c
/* la_get_wset_label */
  LSA_SET_NULL (dependency_seq);
  LA_LOG_READ_ALIGN (error, offset, pageid, pg);      // 라벨이 다음 페이지로 넘어가면 그 페이지를 가져옴
  if (error != NO_ERROR)
    return;                                           // 실패해도 NULL인 채로 돌아감 (반환값 없음)
  ...
/* la_log_record_process, case LOG_DUMMY_WSET_LABEL */
  la_get_wset_label (pg_ptr, final, &la_wset_label_dependency_seq);
  la_wset_label_trid = lrec->trid;                    // 성공했든 실패했든 "라벨 있음"
```
읽기에 실패하면 NULL dependency가 "라벨 있음"으로 넘어가, 라벨이 없을 때의 보호(앞 커밋 기다리기)도 타지 않는다.

## 4. 예시
T1이 `id=1` 행을 UPDATE하고, T2가 같은 행을 다시 UPDATE한다. master는 T2의 라벨에 "T1 뒤"를 적는다.
1. slave가 T2의 라벨을 읽다 다음 로그 페이지를 가져오지 못한다.
2. T2는 dependency NULL, "라벨 있음"이 된다.
3. T2가 T1을 기다리지 않고 다른 worker에서 동시에 실행된다. T2가 먼저 끝나면 slave에는 T1의 값이 남는다. 오류도 로그도 없다.

## 5. 다른 레코드 읽기와 비교
| 함수 (읽는 레코드) | 실패하면 | 결과 |
|---|---|---|
| `la_retrieve_eot_time` (트랜잭션 종료 시각) | 0을 돌려주고 호출부가 replica 지연을 건너뜀 | 해 없음 |
| `la_get_ha_server_state` (HA 서버 상태) | NULL을 돌려주고 호출부가 오류 로그를 남긴 뒤 건너뜀 | 이번 역할 변경 처리만 빠짐 |
| `la_make_repl_item` (복제 항목) | NULL을 돌려주고 호출부가 오류를 반환 | applier가 멈추고 재시작 |
| `la_get_wset_label` (수정 전) | 알리지 않음 | 순서가 뒤집힐 수 있음 |

develop 함수들은 실패하면 해가 없는 기본값으로 가거나 멈춘다. 라벨 읽기만 실패가 가장 공격적인 값("의존 없음")으로 바뀌었다.

## 6. 수정 (`caa9d33f1`)
읽지 못한 라벨은 다시 읽는다.
```c
/* la_get_wset_label: 반환형 void → int, 실패하면 error 반환, 끝에 return NO_ERROR */

/* la_log_record_process, case LOG_DUMMY_WSET_LABEL (log_applier.c:8024) */
      /* keep the label in the holder; the next LOG_COMMIT or LOG_SYSOP_END of the same trid takes it.
       * A label that cannot be read is read again: the error leaves final_lsa on this record. */
      error = la_get_wset_label (pg_ptr, final, &la_wset_label_dependency_seq);
      if (error != NO_ERROR)
	{
	  er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_HA_GENERIC_ERROR, 1, "failed to read LOG_DUMMY_WSET_LABEL");
	  return error;
	}
      la_wset_label_trid = lrec->trid;
```
- 메인 루프는 레코드 처리 오류를 받으면 `final_lsa`를 넘기지 않고 안쪽 루프를 빠져나가, 다음 반복에서 같은 레코드를 다시 읽는다. develop의 다른 레코드 처리 오류도 같은 경로를 탄다(추정).
- 라벨 처리에는 읽기 전에 바꾸는 상태가 없어 다시 읽어도 부작용이 없다.

**"라벨 없음"으로 처리하는 안을 버린 이유.** 커밋 라벨은 "라벨 없음"이면 앞 커밋을 기다리므로 안전하다. 하지만 serial 조각(SYSOP_END)은 라벨이 있어야 조각으로 떼어 먼저 적용한다(`la_coordinator_process_sysop_end`, `:7656`). 라벨이 없으면 serial 변경이 바깥 트랜잭션의 커밋과 함께 늦게 적용되고, 그 조각을 기다리도록 라벨이 붙은 뒤 트랜잭션들보다 늦어질 수 있다(추정).

## 7. 시험 (10-23, 빌드 2786-8823088)
- 라벨 읽기 실패는 로그 페이지를 못 가져오는 경우라 훅 없이 만들 수 없어 재현하지 않았다.
- 회귀: failover 하니스(`c6_drain_backstop_20261023_151324`), C9·C10·C13 시험 동안 "failed to read LOG_DUMMY_WSET_LABEL" 0건, 데이터 일치, fail_counter 0.

## 8. 열린 질문
1. 메인 루프가 레코드 처리 오류 뒤 같은 레코드를 다시 읽는지 실측하지 않았다. 확인하려면 라벨 읽기 실패를 일으키는 시험 훅이 필요하다.
