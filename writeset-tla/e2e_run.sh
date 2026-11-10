#!/bin/bash
# Run one E2E config detached-friendly. Usage: e2e_run.sh <name> [extra tlc flags]
cd /home/youngjun/Workspace/Obsidian/Github/writeset-tla
N=$1; shift
M=/home/youngjun/tools/tlc-meta/e2e/$N
OUT=results/out-e2e-$N.txt
rm -rf $M; mkdir -p $M
echo "START $(date '+%F %T') $N $*" > $OUT
timeout 36000 ~/tools/tlc -workers 16 -metadir $M "$@" -config E2E_$N.cfg $(grep -q "^SYMMETRY" E2E_$N.cfg && echo WritesetE2ESym || echo WritesetE2E) >> $OUT 2>&1
echo "END $(date '+%F %T') exit=$?" >> $OUT
rm -rf $M
