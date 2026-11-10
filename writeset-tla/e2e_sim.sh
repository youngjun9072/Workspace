#!/bin/bash
# Random simulation of one E2E config. Usage: e2e_sim.sh <name> <seconds> <seed> [depth]
cd /home/youngjun/Workspace/Obsidian/Github/writeset-tla
N=$1; T=$2; S=$3; D=${4:-500}
M=/home/youngjun/tools/tlc-meta/e2e/sim-$N-$S
OUT=results/out-e2e-sim-$N-$S.txt
rm -rf $M; mkdir -p $M
echo "START $(date '+%F %T') $N seed=$S depth=$D limit=${T}s" > $OUT
timeout $T ~/tools/tlc -workers 16 -metadir $M -simulate -depth $D -seed $S -config E2E_$N.cfg $(grep -q "^SYMMETRY" E2E_$N.cfg && echo WritesetE2ESym || echo WritesetE2E) >> $OUT 2>&1
echo "END $(date '+%F %T') exit=$?" >> $OUT
rm -rf $M
