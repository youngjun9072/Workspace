#!/bin/bash
cd /home/youngjun/Workspace/Obsidian/Github/writeset-tla
until grep -q '^END' results/out-e2e-sim-sim_big-15.txt 2>/dev/null; do sleep 20; done
./e2e_batch.sh mo_t3k2 mo_t3k3 mo_t4k3 mo_t4k3c
