# 인덱스가 같은 키로 보는지 판정한 단일 서버 시험 원자료

방법: 같은 unique 컬럼에 값 A를 넣고 값 B를 넣는다. B에서 unique 위반(-670)이 나면 인덱스가 A와 B를 같은 키로 본다(SAME_KEY), 아니면 다른 키(DIFFERENT_KEY).
ERR 줄은 csql이 chr(0)||chr(0) 식을 구문 오류로 거부한 것으로, 판정이 아니다.

## euckr_bin CHAR, 끝 NUL+전각 공백(0xA1A1) (youngjun3)

시각(UTC): 2026-10-30T15:55:29.670Z

명령:

```bash
source ~/.cubrid.sh; S=/tmp/claude-11123/-home-youngjun-Workspace/3d41aa48-4137-4302-8027-b8b2a9cd4f75/scratchpad; cat > $S/e3.sql <<'EOF'
drop table if exists pc_ek;
create table pc_ek (k char(10) collate euckr_bin primary key, id int);
insert into pc_ek values (_euckr'a', 1);
insert into pc_ek values (_euckr'a' || chr(0 using euckr) || chr(41377 using euckr), 2);
select id, hex(k) from pc_ek order by 1;
drop table if exists pc_ek;
EOF
csql -u dba testdb -i $S/e3.sql 2>&1 | grep -vE "^\s*$|Execute OK|Committed|row.* selected" | cut -c1-160 | head
```

출력:

```text
In the command from line 4,
ERROR: Operation would have caused one or more unique constraint violations. INDEX pk_pc_ek_k(B+tree: 0|5056|5057) ON CLASS dba.pc_ek(CLASS_OID: 0|202|28). key:
=== <Result of SELECT Command in Line 5> ===
           id   hex(k)
===================================
            1  '61'
```

## 콜레이션 6종 x 값 쌍 6개 (youngjun4)

시각(UTC): 2026-10-31T11:31:13.918Z

명령:

```bash
mkdir -p /tmp/claude-11123/-home-youngjun-Workspace/3d41aa48-4137-4302-8027-b8b2a9cd4f75/scratchpad; cat > /tmp/claude-11123/-home-youngjun-Workspace/3d41aa48-4137-4302-8027-b8b2a9cd4f75/scratchpad/nul_trail.sh <<'EOF'
#!/bin/bash
# For each column type/collation and each pair of values: insert A then B into a unique column.
# -670 on B = the index treats A and B as one key (SAME_KEY); otherwise DIFFERENT_KEY.
source ~/.cubrid.sh
cubrid paramdump testdb 2>/dev/null | grep -i trailing
q () { csql -u dba testdb@localhost -c "$1" 2>&1; }
n=0
for col in "varchar(10) collate iso88591_bin" "char(5) collate iso88591_bin" "varchar(10) collate utf8_ko_cs" "varchar(10) collate utf8_bin" "varchar(10) collate euckr_bin" "char(5) collate euckr_bin"; do
  echo "== $col"
  while IFS='|' read -r label a b; do
    n=$((n+1)); t=nt_$n
    q "drop table if exists $t" >/dev/null
    out=$(q "create table $t (k $col unique)"); echo "$out" | grep -q ERROR && { echo "  create failed: $(echo "$out" | grep ERROR | head -1)"; break; }
    q "insert into $t values ($a)" | grep -q ERROR && { echo "  $label: first insert failed"; continue; }
    r=$(q "insert into $t values ($b)")
    if echo "$r" | grep -q "unique"; then v=SAME_KEY; elif echo "$r" | grep -q ERROR; then v="ERR $(echo "$r" | grep ERROR | head -1)"; else v=DIFFERENT_KEY; fi
    printf "  %-28s %s\n" "$label" "$v"
    q "drop table $t" >/dev/null
  done <<'P'
'a' / 'a'+NUL|'a'|'a'||chr(0)
'a' / 'a '|'a'|'a '
'a ' / 'a'+NUL|'a '|'a'||chr(0)
'a'+NUL / 'a'+NUL+NUL|'a'||chr(0)|'a'||chr(0)||chr(0)
'a  ' / 'a'+NUL+' '|'a  '|'a'||chr(0)||' '
'a b' / 'a'+NUL+'b'|'a b'|'a'||chr(0)||'b'
P
done
EOF
scp -q /tmp/claude-11123/-home-youngjun-Workspace/3d41aa48-4137-4302-8027-b8b2a9cd4f75/scratchpad/nul_trail.sh youngjun4:~/nul_trail.sh && ssh youngjun4 'bash ~/nul_trail.sh'
```

출력:

```text
== varchar(10) collate iso88591_bin
  'a' / 'a'+NUL                DIFFERENT_KEY
  'a' / 'a '                   DIFFERENT_KEY
  'a ' / 'a'+NUL               SAME_KEY
  'a'+NUL / 'a'+NUL+NUL        ERR ERROR: In line 1, column 26 before 'chr(0)|'a'||chr(0)||chr(0))'
  'a  ' / 'a'+NUL+' '          SAME_KEY
  'a b' / 'a'+NUL+'b'          SAME_KEY
== char(5) collate iso88591_bin
  'a' / 'a'+NUL                SAME_KEY
  'a' / 'a '                   SAME_KEY
  'a ' / 'a'+NUL               SAME_KEY
  'a'+NUL / 'a'+NUL+NUL        ERR ERROR: In line 1, column 27 before 'chr(0)|'a'||chr(0)||chr(0))'
  'a  ' / 'a'+NUL+' '          SAME_KEY
  'a b' / 'a'+NUL+'b'          SAME_KEY
== varchar(10) collate utf8_ko_cs
  'a' / 'a'+NUL                DIFFERENT_KEY
  'a' / 'a '                   DIFFERENT_KEY
  'a ' / 'a'+NUL               SAME_KEY
  'a'+NUL / 'a'+NUL+NUL        ERR ERROR: In line 1, column 27 before 'chr(0)|'a'||chr(0)||chr(0))'
  'a  ' / 'a'+NUL+' '          SAME_KEY
  'a b' / 'a'+NUL+'b'          SAME_KEY
== varchar(10) collate utf8_bin
  'a' / 'a'+NUL                DIFFERENT_KEY
  'a' / 'a '                   DIFFERENT_KEY
  'a ' / 'a'+NUL               SAME_KEY
  'a'+NUL / 'a'+NUL+NUL        ERR ERROR: In line 1, column 27 before 'chr(0)|'a'||chr(0)||chr(0))'
  'a  ' / 'a'+NUL+' '          SAME_KEY
  'a b' / 'a'+NUL+'b'          SAME_KEY
== varchar(10) collate euckr_bin
  'a' / 'a'+NUL                SAME_KEY
  'a' / 'a '                   DIFFERENT_KEY
  'a ' / 'a'+NUL               SAME_KEY
  'a'+NUL / 'a'+NUL+NUL        ERR ERROR: In line 1, column 27 before 'chr(0)|'a'||chr(0)||chr(0))'
  'a  ' / 'a'+NUL+' '          SAME_KEY
  'a b' / 'a'+NUL+'b'          SAME_KEY
== char(5) collate euckr_bin
  'a' / 'a'+NUL                SAME_KEY
  'a' / 'a '                   SAME_KEY
  'a ' / 'a'+NUL               SAME_KEY
  'a'+NUL / 'a'+NUL+NUL        ERR ERROR: In line 1, column 27 before 'chr(0)|'a'||chr(0)||chr(0))'
  'a  ' / 'a'+NUL+' '          SAME_KEY
  'a b' / 'a'+NUL+'b'          SAME_KEY
```

## 'a'+NUL / 'a'+NUL+NUL 재확인 (youngjun4)

시각(UTC): 2026-10-31T11:32:07.149Z

명령:

```bash
ssh youngjun4 'source ~/.cubrid.sh; q () { csql -u dba testdb@localhost -c "$1" 2>&1; }; for col in "varchar(10) collate iso88591_bin" "char(5) collate iso88591_bin" "varchar(10) collate utf8_ko_cs" "varchar(10) collate utf8_bin" "varchar(10) collate euckr_bin" "char(5) collate euckr_bin"; do q "drop table if exists nt_x" >/dev/null; q "create table nt_x (k $col unique)" >/dev/null; q "insert into nt_x values (chr(97)||chr(0))" | grep ERROR; r=$(q "insert into nt_x values (chr(97)||chr(0)||chr(0))"); echo "$col: $(echo "$r" | grep -q unique && echo SAME_KEY || echo DIFFERENT_KEY)"; done; q "drop table if exists nt_x" >/dev/null; rm -f ~/nul_trail.sh'
```

출력:

```text
varchar(10) collate iso88591_bin: DIFFERENT_KEY
char(5) collate iso88591_bin: SAME_KEY
varchar(10) collate utf8_ko_cs: DIFFERENT_KEY
varchar(10) collate utf8_bin: DIFFERENT_KEY
varchar(10) collate euckr_bin: SAME_KEY
char(5) collate euckr_bin: SAME_KEY
```

## binary 콜레이션 (youngjun3)

시각(UTC): 2026-10-31T15:45:47.820Z

명령:

```bash
source ~/.cubrid.sh; q () { csql -u dba testdb -c "$1" 2>&1; }; while IFS='|' read -r label a b; do q "drop table if exists nt_b" >/dev/null; q "create table nt_b (k varchar(10) collate binary unique)" >/dev/null; q "insert into nt_b values ($a)" | grep ERROR; r=$(q "insert into nt_b values ($b)"); printf "%-26s %s\n" "$label" "$(echo "$r" | grep -q unique && echo SAME_KEY || (echo "$r" | grep -q ERROR && echo "ERR $(echo "$r" | grep ERROR|head -1)" || echo DIFFERENT_KEY))"; done <<'P'
ab / ab+NUL|'ab'|'ab'||chr(0)
ab / ab+sp|'ab'|'ab '
ab+sp / ab+NUL|'ab '|'ab'||chr(0)
ab+NUL / ab+NUL+NUL|'ab'||chr(0)|'ab'||chr(0)||chr(0)
a b / a+NUL+b|'a b'|'a'||chr(0)||'b'
P
q "drop table if exists nt_b" >/dev/null
```

출력:

```text
ab / ab+NUL                SAME_KEY
ab / ab+sp                 DIFFERENT_KEY
ab+sp / ab+NUL             DIFFERENT_KEY
ab+NUL / ab+NUL+NUL        ERR ERROR: In line 1, column 26 before 'chr(0)|'ab'||chr(0)||chr(0))'
a b / a+NUL+b              DIFFERENT_KEY
```
