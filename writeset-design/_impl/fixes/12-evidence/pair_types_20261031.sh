#!/bin/bash
# Type survey (10-31, build 2985-772a6a0 with the MONETARY fix): for each indexable type, T1 deletes a key and T2
# inserts a value the index treats as the same key but which may hash differently. The slave holds T1 back
# (gate row lock); a missed dependency shows as a slave -670 and a missing row.
export OUT_ROOT=$HOME/ha_bench_tool/log/pair_order_$(date +%Y%m%d_%H%M)_types
T=~/ha_bench_tool/bin/pair_order_test.sh
$T t01_money "drop table if exists pt_money; create table pt_money (k monetary primary key, id int); insert into pt_money values (\$100, 1);" "delete from pt_money where id=1" "insert into pt_money values (\\100, 2)" "gate" "select id, k from pt_money order by 1"
$T t02_varbit "drop table if exists pt_vb; create table pt_vb (k bit varying(64) primary key, id int); insert into pt_vb values (B'1', 1);" "delete from pt_vb where id=1" "insert into pt_vb values (B'10', 2)" "gate" "select id, k from pt_vb order by 1"
$T t03_bit_fixed "drop table if exists pt_fb; create table pt_fb (k bit(8) primary key, id int); insert into pt_fb values (B'1', 1);" "delete from pt_fb where id=1" "insert into pt_fb values (X'80', 2)" "gate" "select id, k from pt_fb order by 1"
$T t04_str_mid_nul_iso "drop table if exists pt_s1; create table pt_s1 (k varchar(10) primary key, id int); insert into pt_s1 values ('a b', 1);" "delete from pt_s1 where id=1" "insert into pt_s1 values ('a'||chr(0)||'b', 2)" "gate" "select id, hex(k) from pt_s1 order by 1"
$T t05_str_mid_nul_utf8ko "drop table if exists pt_s2; create table pt_s2 (k varchar(10) collate utf8_ko_cs primary key, id int); insert into pt_s2 values (_utf8'a b', 1);" "delete from pt_s2 where id=1" "insert into pt_s2 values (_utf8'a' || chr(0 using utf8) || _utf8'b', 2)" "gate" "select id, hex(k) from pt_s2 order by 1"
$T t06_str_euckr_nul_fullwidth "drop table if exists pt_s3; create table pt_s3 (k char(10) collate euckr_bin primary key, id int); insert into pt_s3 values (_euckr'a', 1);" "delete from pt_s3 where id=1" "insert into pt_s3 values (_euckr'a' || chr(0 using euckr) || chr(41377 using euckr), 2)" "gate" "select id, hex(k) from pt_s3 order by 1"
$T t07_double_nan "drop table if exists pt_nan; create table pt_nan (k double primary key, id int); insert into pt_nan values (cast('nan' as double), 1);" "delete from pt_nan where id=1" "insert into pt_nan values (1.0, 2)" "gate" "select id, k from pt_nan order by 1"
$T t08_numeric_scale "drop table if exists pt_num; create table pt_num (k numeric(10,2) primary key, id int); insert into pt_num values (1.5, 1);" "delete from pt_num where id=1" "insert into pt_num values (cast(1.50000 as numeric(20,5)), 2)" "gate" "select id, k from pt_num order by 1"
$T t09_float_round "drop table if exists pt_fl; create table pt_fl (k float primary key, id int); insert into pt_fl values (1.0, 1);" "delete from pt_fl where id=1" "insert into pt_fl values (cast(1.0000000001 as double), 2)" "gate" "select id, k from pt_fl order by 1"
$T t10_enum "drop table if exists pt_en; create table pt_en (k enum('a','b','c') primary key, id int); insert into pt_en values ('b', 1);" "delete from pt_en where id=1" "insert into pt_en values (2, 2)" "gate" "select id, k from pt_en order by 1"
echo ALL_DONE $OUT_ROOT
