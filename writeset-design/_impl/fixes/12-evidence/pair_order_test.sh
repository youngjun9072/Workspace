#!/bin/bash
# pair_order_test.sh <case> <setup_sql> <t1_sql> <t2_sql> <slave_lock_sql|-> <check_sql> [hold_s]
# T1 then T2 on the master. T1 runs in one transaction that first updates a gate row (pc_gate id=1) and then
# its own statements; the slave locks only the gate row, so T1 stops there before touching anything T2 needs,
# and a T2 the writeset does not order after T1 is applied first. Locking the contested row itself does not
# work: T2 then waits on the same row lock and runs after T1 anyway (10-29, first control run). Records the master COMMIT/DEPENDENCY trace of the window, slave applier
# errors in both log files, fail_counter, and master vs slave results of check_sql.
cd "$(dirname "$0")"; source ./verify_common.sh
C=$1; SETUP=$2; T1=$3; T2=$4; LOCK=$5; CHECK=$6; HOLD=${7:-25}
OUT=${OUT_ROOT:-$HOME/ha_bench_tool/log/pair_order_$(date +%Y%m%d)}/$C; mkdir -p "$OUT"; : > "$OUT/run.log"
L=$CUBRID/log/server/testdb_latest.err
q() { csql -u dba $DB -c "$1" > "$OUT/$2.out" 2>&1; grep -aE 'ERROR' "$OUT/$2.out" | head -2 | sed "s/^/[$2] /" | tee -a "$OUT/run.log"; }
sq() { ssh $SLAVE_HOST "source ~/.cubrid.sh; csql -u dba $DB -c \"$1\"" 2>&1; }
log "case $C"
csql -u dba $DB -c "create table if not exists pc_gate (id int primary key, v int)" >/dev/null 2>&1; csql -u dba $DB -c "insert into pc_gate select 1, 0 from db_root where not exists (select 1 from pc_gate where id = 1)" >/dev/null 2>&1
[ -n "$SETUP" ] && q "$SETUP" setup
sleep 5; for i in $(seq 1 60); do [ "$(sq "$CHECK" | grep -vE '^$|sec\)|Committed|selected|=== ' | md5sum)" = "$(csql -u dba $DB -c "$CHECK" 2>&1 | grep -vE '^$|sec\)|Committed|selected|=== ' | md5sum)" ] && break; sleep 1; done
log "setup synced"
fc0=$(sval "select fail_counter from db_ha_apply_info"); s0=$(slog_lines); L0=$(readlink -f $L); n0=$(wc -l < $L0)
if [ "$LOCK" != "-" ]; then
  ssh $SLAVE_HOST "source ~/.cubrid.sh; nohup csql --sysadm --write-on-standby -u dba $DB --no-auto-commit -c \"update pc_gate set v=v where id=1; select sleep($HOLD); rollback;\" > ~/pair_lock.out 2>&1 &"
  sleep 3; log "slave gate lock held ${HOLD}s (pc_gate id=1)"
fi
csql -u dba $DB --no-auto-commit -c "update pc_gate set v=v+1 where id=1; $T1; commit;" > "$OUT/t1.out" 2>&1; grep -aE "ERROR" "$OUT/t1.out" | head -2 | sed "s/^/[t1] /" | tee -a "$OUT/run.log"; log "T1 done (gate + T1 in one transaction)"; q "$T2" t2; log "T2 done"
sleep $((HOLD + 8))
for i in $(seq 1 60); do m=$(csql -u dba $DB -c "$CHECK" 2>&1 | grep -vE '^$|sec\)|Committed|selected|=== '); s=$(sq "$CHECK" | grep -vE '^$|sec\)|Committed|selected|=== '); [ "$m" = "$s" ] && break; sleep 1; done
echo "$m" > "$OUT/master_check.txt"; echo "$s" > "$OUT/slave_check.txt"
# the server log may rotate during the window: the rest of the starting file, then every newer one
{ tail -n +$((n0 + 1)) $L0; for f in $(ls -tr $CUBRID/log/server/testdb_*.err); do [ "$f" -nt "$L0" ] && cat "$f"; done; } | grep -a '^\[WSET\] \(COMMIT\|DEPENDENCY\|CLEAR\|SYSOP\)' > "$OUT/master_trace.txt"
slog_fetch $s0 | grep -a -B1 -A1 'ERROR CODE\|error=-[0-9]\|reader exit\|coordinator exit' > "$OUT/slave_errors.txt"
fc=$(sval "select fail_counter from db_ha_apply_info")
log "master trace commits:"; grep -a 'COMMIT trid' "$OUT/master_trace.txt" | sed 's/^/    /' | tee -a "$OUT/run.log" >/dev/null
log "slave error lines: $(grep -ac 'ERROR CODE\|error=-' "$OUT/slave_errors.txt"), fail_counter $fc0 -> $fc"
log "check master: $(echo $m | tr '\n' ' ' | cut -c1-200)"
log "check slave : $(echo $s | tr '\n' ' ' | cut -c1-200)"
log "result: $([ "$m" = "$s" ] && echo SAME || echo DIFFERENT)"
