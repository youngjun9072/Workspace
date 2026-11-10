#!/bin/bash
# run the given configs one after another; state dirs on disk, deleted after each run
cd /home/youngjun/Workspace/Obsidian/Github/writeset-tla
mkdir -p results
for c in "$@"; do
  M=/home/youngjun/tools/tlc-meta/slave/$c
  rm -rf $M
  timeout 900 ~/tools/tlc -workers 8 -metadir $M -config SlaveCoordinator_$c.cfg SlaveCoordinator > results/out-$c.txt 2>&1
  rm -rf $M
  echo "== $c: $(grep -E 'is violated|Deadlock reached|No error has been found|Error: TLC' results/out-$c.txt | head -1) | $(grep -E 'states generated,' results/out-$c.txt | tail -1)"
done
