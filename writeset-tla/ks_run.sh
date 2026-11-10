#!/bin/bash
# Run one WritesetSysopKeyed config. Usage: ks_run.sh <name> [extra tlc flags, e.g. -simulate -depth 200 -seed 1]
# Output results/sysop-keyed-<name>.txt; metadir deleted afterwards; 2h timeout (override with KS_TIMEOUT).
cd /home/youngjun/Workspace/Obsidian/Github/writeset-tla
N=$1; shift
M=/home/youngjun/tools/tlc-meta/keyed/$N
OUT=results/sysop-keyed-$N.txt
W=${KS_WORKERS:-16}
rm -rf $M; mkdir -p $M
echo "START $(date '+%F %T') $N workers=$W $*" > $OUT
timeout ${KS_TIMEOUT:-7200} /home/youngjun/tools/jdk-17.0.21+9/bin/java -Xmx16g -XX:+UseParallelGC \
  -cp /home/youngjun/tools/tla2tools.jar tlc2.TLC -workers $W -metadir $M "$@" -config KS_$N.cfg \
  $(grep -q "^SYMMETRY" KS_$N.cfg && echo WritesetSysopKeyedSym || echo WritesetSysopKeyed) >> $OUT 2>&1
echo "END $(date '+%F %T') exit=$? metadir=$(du -sh $M 2>/dev/null | cut -f1)" >> $OUT
rm -rf $M
