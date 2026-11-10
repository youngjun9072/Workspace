#!/bin/bash
# Long random simulation of one model. Usage: run_sim.sh <Module> <cfg-name> [extra tlc flags]
cd /home/youngjun/Workspace/Obsidian/Github/writeset-tla
M=$1; C=$2; shift 2
META=/home/youngjun/tools/tlc-meta/sim-$C
OUT=results/sim-$C.txt
echo "START $(date '+%F %T') $M $C $*" > $OUT
timeout 14400 ~/tools/tlc "$@" -workers 4 -metadir $META -simulate -depth 300 -config $C.cfg $M >> $OUT 2>&1
echo "END $(date '+%F %T') exit=$?" >> $OUT
rm -rf $META
