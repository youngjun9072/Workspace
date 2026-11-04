#!/bin/bash
# binary collation fix (11-01): the binary collation ignores only trailing NULs and tells a NUL from a space.
export OUT_ROOT=${OUT_ROOT:-$HOME/ha_bench_tool/log/pair_order_$(date +%Y%m%d_%H%M)_binary}
T=~/ha_bench_tool/bin/pair_order_test.sh
$T b01_binary_trailing_nul "drop table if exists pb_1; create table pb_1 (k varchar(10) collate binary primary key, id int); insert into pb_1 values ('ab', 1);" "delete from pb_1 where id=1" "insert into pb_1 values ('ab'||chr(0), 2)" "gate" "select id from pb_1 order by 1"
$T b02_binary_two_nuls "drop table if exists pb_2; create table pb_2 (k varchar(10) collate binary primary key, id int); insert into pb_2 values ('ab'||chr(0), 1);" "delete from pb_2 where id=1" "insert into pb_2 values ('ab'||chr(0)||chr(0), 2)" "gate" "select id from pb_2 order by 1"
$T b03_binary_composite "drop table if exists pb_3; create table pb_3 (k varchar(10) collate binary, j int, id int, primary key (k, j)); insert into pb_3 values ('ab', 7, 1);" "delete from pb_3 where id=1" "insert into pb_3 values ('ab'||chr(0), 7, 2)" "gate" "select id from pb_3 order by 1"
$T b04_binary_ref "drop table if exists pb_4c; drop table if exists pb_4p; create table pb_4p (k varchar(10) collate binary primary key, id int); create table pb_4c (id int primary key, pk varchar(10) collate binary references pb_4p(k)); insert into pb_4p values ('ab', 1);" "delete from pb_4p where id=1; insert into pb_4p values ('ab'||chr(0), 2)" "insert into pb_4c values (1, 'ab')" "gate" "select p.id, c.id from pb_4p p left join pb_4c c on c.pk = p.k order by 1"
$T b05_binary_space_control "drop table if exists pb_5; create table pb_5 (k varchar(10) collate binary primary key, id int); insert into pb_5 values ('ab ', 1);" "delete from pb_5 where id=1" "insert into pb_5 values ('ab'||chr(0), 2)" "gate" "select id from pb_5 order by 1"
echo ALL_DONE $OUT_ROOT
