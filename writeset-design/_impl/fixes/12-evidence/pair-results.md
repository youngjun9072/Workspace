# HA 짝 시험 결과 요약

판정: T1이 첫 값을 지우고 T2가 두 번째 값을 넣는다. slave에서 관문 행을 25초 잡아 T1을 붙잡는다. master와 slave 결과가 같으면 SAME, slave에 행이 없으면 DIFFERENT.

## pair_order_20261031_0055_types

```text
t01_money                          SAME       slave_apply_errors=0
t02_varbit                         DIFFERENT  slave_apply_errors=1
t03_bit_fixed                      SAME       slave_apply_errors=0
t04_str_mid_nul_iso                DIFFERENT  slave_apply_errors=1
t05_str_mid_nul_utf8ko             DIFFERENT  slave_apply_errors=1
t06_str_euckr_nul_fullwidth        DIFFERENT  slave_apply_errors=1
t07_double_nan                     DIFFERENT  slave_apply_errors=1
t08_numeric_scale                  SAME       slave_apply_errors=0
t09_float_round                    SAME       slave_apply_errors=0
t10_enum                           SAME       slave_apply_errors=0
```

## pair_order_20261101_1737_hashfix

```text
t01_varbit                         SAME       slave_apply_errors=0
t02_varbit_7_8                     SAME       slave_apply_errors=0
t03_str_mid_nul_iso                SAME       slave_apply_errors=0
t04_str_mid_nul_utf8ko             SAME       slave_apply_errors=0
t05_str_euckr_char                 SAME       slave_apply_errors=0
t06_double_nan                     SAME       slave_apply_errors=0
t07_nan_then_insert                SAME       slave_apply_errors=0
t08_varchar_trailing_nul           SAME       slave_apply_errors=0
t09_varchar_trailing_nul_space     SAME       slave_apply_errors=0
t10_euckr_varchar_nul              SAME       slave_apply_errors=0
t11_varbit_composite               SAME       slave_apply_errors=0
t12_str_nul_composite              SAME       slave_apply_errors=0
```

## pair_order_20261101_1746_binary

```text
b01_binary_trailing_nul            SAME       slave_apply_errors=0
b02_binary_two_nuls                SAME       slave_apply_errors=0
b03_binary_composite               SAME       slave_apply_errors=0
b04_binary_ref                     SAME       slave_apply_errors=0
b05_binary_space_control           SAME       slave_apply_errors=0
```

## 수정 전 slave 오류 예 (pair_order_20261031_0055_types/t06_str_euckr_nul_fullwidth)

```text

Time: 10/31/26 01:03:18.915 - ERROR *** file /home/youngjun/Workspace/cubrid/src/transaction/log_applier.c, line 6439 ERROR CODE = -1032, Tran = 5, EID = 12
log applier: failed to apply insert replication log. class: "dba.pt_s3", key: "_euckr'a", server error: -670, Operation would have caused one or more unique constraint violations. INDEX pk_pt_s3_k(B+tree: 0|5824|5825) ON CLASS dba.pt_s3(CLASS_OID: 0|208|4). key: _euckr'a(OID: 0|5889|2).
```

## 수정 뒤 NaN 폴백 trace 예 (pair_order_20261101_1737_hashfix/t06_double_nan)

```text
[WSET] DEPENDENCY trid=1856 mode=COMMIT_ORDER dependency=215|56
[WSET] COMMIT trid=1856 commit_lsa=215|9592 dependency=215|56 entries=0 fallback=1
[WSET] CLEAR trid=1856 reason=COMMIT_ORDER_FALLBACK old_size=0 new_size=0 commit_lsa=215|9592 history_start=215|9592
[WSET] DEPENDENCY trid=1861 source=WRITE_BOUND history_start=215|9592 prev_commit=215|9592 dependency=215|9592
[WSET] COMMIT trid=1861 commit_lsa=215|10264 dependency=215|9592 entries=1 fallback=0
```
