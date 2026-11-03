---
tags: [CBRD-27508, writeset, fixes, test-result]
---
# 인덱스가 같은 키로 보는 값의 writeset 해시 전수조사

작성: 2026-10-31. 인덱스를 만들 수 있는 타입마다, 인덱스 비교는 같다고 보지만 writeset 해시는 다를 수 있는 값을 찾아 HA에서 실측했다. 해시가 갈리면 T2가 T1에 dependency를 받지 못하고, slave가 T2를 먼저 적용해 unique 위반(-670)으로 행을 잃는다.

관련 문서: [10-inherited-index-writeset-key](./10-inherited-index-writeset-key.md), [11-missed-ordering-scenarios](./11-missed-ordering-scenarios.md).

## 시험 방법

- 빌드 2985-772a6a0(develop 병합 a7efa9a50 + MONETARY 수정 c5fdd4c59 포함), conf 기준값, slave trace 2.
- 타입마다 먼저 master 한 대에서 두 값을 같은 unique 키에 넣어 인덱스가 같은 키로 보는지 확인했다(unique 위반이면 같은 키).
- 그 뒤 짝 시험: T1이 첫 값을 지우고 T2가 두 번째 값을 넣는다. slave에서 관문 행을 25초 잡아 T1을 붙잡아 둔다. 결과가 master와 같으면 SAME, slave에 행이 없으면 DIFFERENT.
- 스크립트 `ha_bench_tool/bin/cases/pair_types_20261031.sh`, 기록 `ha_bench_tool/log/pair_order_20261031_0055_types`.

## 결과

해시 수정이 필요한 것(DIFFERENT, slave -670, 행 유실):
- VARBIT: `B'1'`을 지우고 `B'10'`을 넣음. 인덱스 비교(`mr_data_cmpdisk_varbit`)는 비트 길이를 바이트 수로 바꿔 바이트와 바이트 수만 비교하는데, 해시는 비트 길이까지 묶는다. `B'1'`, `B'10'`, `B'1000'`이 한 키다.
- 문자열 중간의 공백과 NUL, `iso88591_bin`(기본): `'a b'`를 지우고 `'a'||chr(0)||'b'`를 넣음. `lang_fastcmp_byte`가 공백을 `'\0'`과 같은 값으로 비교하지만 `mht2str`는 원래 바이트로 해시한다.
- 같은 경우, `utf8_ko_cs`: `lang_strmatch_utf8`도 공백을 0으로 비교한다.
- `euckr_bin` CHAR: `'a'`를 지우고 `'a'` + NUL + 전각 공백(0xA1A1)을 넣음. 끝 비교는 NUL, 공백, 0xA1A1을 모두 0으로 보는데, writeset은 맨 끝의 NUL과 공백만 자르고 `mht2str_ko`는 NUL을 자르지 않는다.
- DOUBLE NaN: NaN을 지우고 1.0을 넣음. `cast('nan' as double)`이 저장되고, 인덱스 비교(`MR_CMP`)는 NaN을 모든 값과 같다고 본다(NaN이 있으면 1.0, inf, -inf도 넣을 수 없다). 해시로 나타낼 수 없는 관계라 commit-order 폴백이 필요하다. 저장 단계에서 막는 것은 develop 결함으로 따로 다룬다(MySQL 8.0, 9.7은 `Field_real::truncate`에서 NaN을 0으로 바꾸고 경고, strict면 오류).

문제없음(SAME):
- MONETARY(수정 후): `$100`을 지우고 `\100`을 넣음. 수정 전 빌드 2968에서는 DIFFERENT였다(10-30).
- BIT 고정 길이: `B'1'`과 `X'80'`. 컬럼 길이로 맞춰져 같은 바이트가 된다.
- NUMERIC: `1.5`(numeric(10,2))와 `cast(1.50000 as numeric(20,5))`.
- FLOAT: `1.0`과 `cast(1.0000000001 as double)`.
- ENUM: `'b'`와 `2`.

실측하지 못한 것:
- 사용자 locale 콜레이션(`utf8_gen`, `utf8_gen_ai_ci` 등)과 UCA 확장 콜레이션(`utf8_de_exp_ai_ci` 등)에서 가중치 0인 글자(제로폭 공백, 결합 악센트, `'Café'`와 `'Cafe'`). 이 DB에 해당 콜레이션이 없다. 코드 분석으로만 결함으로 봤다.

확인할 필요가 없는 것: 정수, DATE/TIME/TIMESTAMP/DATETIME, LTZ 계열, OID(저장 값이 곧 비교 값), SET/JSON/BLOB/CLOB(인덱스 불가).

## 진행 상태

- 2026-10-31: 실측 완료. 수정은 아직(VARBIT, 문자열 3건, NaN). NaN commit-order 폴백 시안은 되돌려 두었다(scratchpad `nan_fallback_wip.patch`).
