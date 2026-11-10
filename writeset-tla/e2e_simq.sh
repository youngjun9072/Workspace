#!/bin/bash
# Queue of simulations after the current one
cd /home/youngjun/Workspace/Obsidian/Github/writeset-tla
until grep -q '^END' results/out-e2e-sim-sim_big-11.txt; do sleep 20; done
./e2e_sim.sh sim_big_bug 3600 12 500
./e2e_sim.sh sim_big_collide 3600 13 500
./e2e_sim.sh sim_mid 3600 14 400
./e2e_sim.sh sim_big 3600 15 500
