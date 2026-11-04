---
tags: [CBRD-27508, writeset, fixes, test-result]
---
# 인덱스가 같은 키로 보는 값의 writeset 해시 전수조사

> [!NOTE]
> **현재 상태 (2026-11-02, PR 브랜치 HEAD 9b2dd61b5 기준)**
> - MONETARY 수정 c5fdd4c59는 cf8955a91(10-31)에 접혔다. e89158de1(11-01)은 해시 코드를 `writeset_key_hash.cpp`로 옮기기만 했다(동작 같음).
> - 01 문서 3.2~3.5절에 반영.


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

## 인덱스가 같은 키로 보는 범위 (단일 서버 시험)

수정 규칙을 정하려고, 콜레이션마다 어떤 두 값을 인덱스가 같은 키로 보는지 따로 확인했다. 같은 unique 컬럼에 값 A를 넣고 값 B를 넣어, B에서 unique 위반이 나면 같은 키로 판정했다. 복제는 거치지 않는다. 원자료는 [별첨 equal-key-probe-20261031](./12-evidence/equal-key-probe-20261031.md)에 있다(10-31 00:55~11-01 00:45 KST, youngjun3·youngjun4).

- `iso88591_bin`, `utf8_bin`, `utf8_ko_cs`의 VARCHAR: `'a b'`와 `'a'||NUL||'b'`, `'a '`와 `'a'||NUL`, `'a  '`와 `'a'||NUL||' '`는 같은 키다. `'a'`와 `'a'||NUL`, `'a'`와 `'a '`는 다른 키다. 즉 NUL은 어느 위치에서나 공백과 같고, VARCHAR 끝 공백은 무시하지 않는다(`ignore_trailing_space` 기본값).
- 같은 콜레이션의 CHAR: 위 쌍이 모두 같은 키다. 끝 NUL과 끝 공백을 무시한다.
- `euckr_bin` VARCHAR: `'a'`와 `'a'||NUL`은 같은 키, `'a'`와 `'a '`는 다른 키, `'a '`와 `'a'||NUL`은 같은 키다. `'a'`=`'a'||NUL`=`'a '`인데 `'a'`≠`'a '`이므로 같음 관계가 추이적이지 않다.
- `euckr_bin` CHAR: `'a'`와 `'a'||NUL||0xA1A1`(전각 공백)이 같은 키다.
- `binary`: `'ab'`와 `'ab'||NUL`은 같은 키, `'ab'`와 `'ab '`, `'ab '`와 `'ab'||NUL`, `'a b'`와 `'a'||NUL||'b'`는 다른 키다. 끝 NUL만 무시하고 NUL과 공백을 구분한다.
- `'a'||NUL`과 `'a'||NUL||NUL`은 csql이 식을 거부해 판정하지 못했다.

## 수정

커밋 `cf8955a91` "hash a key the way its index compares it"에서 VARBIT, 문자열 3건, NaN을 고쳤다. 커밋 메시지 요지는 다음과 같다.

- MONETARY는 한 통화의 금액으로, VARBIT는 비트 길이를 바이트 단위로 올려 해시한다.
- 문자열은 NUL을 공백으로 바꿔 해시한다. binary 콜레이션은 끝 NUL만 자른다.
- NaN 키는 해시로 나타낼 수 없으므로 그 트랜잭션을 commit-order로 보낸다.
- 단일 키, 복합 키 원소, FK REF 세 곳에 같은 규칙을 적용한다.

`e89158de1`은 이 규칙을 `writeset_key_hash.cpp`로 옮긴 것이며 동작은 같다.

## 수정 뒤 HA 재시험

빌드 2990-e89158d에서 같은 방법의 짝 시험을 다시 했다. 요약은 [별첨 pair-results](./12-evidence/pair-results.md), 스크립트는 같은 폴더의 `pair_hashfix_20261101.sh`, `pair_binary_20261101.sh`, `pair_order_test.sh`다.

- 2026-11-01 17:37, 12건(`ha_bench_tool/log/pair_order_20261101_1737_hashfix`): 10-31에 DIFFERENT였던 VARBIT, 문자열 중간 NUL(iso88591_bin, utf8_ko_cs), euckr_bin CHAR, NaN 두 방향과, 끝 NUL·공백, euckr VARCHAR, VARBIT·문자열 복합 키 변형. 모두 SAME, slave 적용 오류 0. NaN 건은 master trace에 `mode=COMMIT_ORDER`와 `fallback=1`이 찍힌다.
- 2026-11-01 17:46, 5건(`ha_bench_tool/log/pair_order_20261101_1746_binary`): binary 콜레이션의 끝 NUL, NUL 두 개, 복합 키, FK REF, 끝 공백과 NUL 대조. 모두 SAME, slave 적용 오류 0.

## 남은 것

- locale·UCA 콜레이션의 가중치 0 글자: 실측하지 못했다(위 "실측하지 못한 것").
- `euckr_bin`의 0xA1A1: 해시 전 정리(NUL을 공백으로, 끝 공백 자르기) 뒤 `lang_mht2str_ko`가 끝의 공백과 0xA1A1을 섞인 채로 모두 자르고, 중간의 공백과 0xA1A1은 같은 값(ZERO)으로 계산한다. 그래서 끝·중간 모두 인덱스와 같은 쪽으로 맞는다(코드 확인). VARCHAR에서는 인덱스가 다르게 보는 `'a'`와 `'a '`도 같은 해시가 되지만, 키가 합쳐질 뿐이다. 끝 0xA1A1만 있는 경우는 따로 시험하지 않았다.
- 문자열 해시가 `mht2str`(28비트 ELF 해시)로 먼저 접혀 서로 다른 키가 같은 해시가 되는 문제(11-01 발견, 순서 누락은 아니고 병렬성 저하). 남은 일 목록에 있다.

## 진행 상태

- 2026-10-31: 실측 완료. 수정은 아직(VARBIT, 문자열 3건, NaN). NaN commit-order 폴백 시안은 되돌려 두었다(scratchpad `nan_fallback_wip.patch`).
- 2026-11-01: `cf8955a91`로 수정, 빌드 2990-e89158d에서 HA 짝 시험 17건 모두 SAME. 근거 원자료를 `12-evidence/`에 모았다.
