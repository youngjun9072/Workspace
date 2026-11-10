#!/bin/bash
# Run configs one after another. Usage: e2e_batch.sh name1 name2 ...
cd /home/youngjun/Workspace/Obsidian/Github/writeset-tla
for n in "$@"; do ./e2e_run.sh $n; done
