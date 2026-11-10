#!/bin/bash
# Summarize E2E result files given as names (default: all)
cd /home/youngjun/Workspace/Obsidian/Github/writeset-tla
for n in "${@:-}"; do :; done
files=${@:+$(for n in "$@"; do echo results/out-e2e-$n.txt; done)}
for f in ${files:-results/out-e2e-*.txt}; do
  [ -f $f ] || continue
  echo "== $(basename $f .txt | sed 's/out-e2e-//'): $(grep -E 'is violated|Deadlock reached|No error has been found|Error: TLC|Error: Attempted|Error: The' $f | head -1) | $(grep -E 'distinct states found' $f | tail -1 | sed 's/.*generated, //;s/ states left.*//' | cut -c1-70) | $(grep -E 'depth of the complete' $f | sed 's/.*search is //') | $(grep -E '^(START|END)' $f | sed 's/ exit.*//;s/^\(START\|END\) 2026-//' | tr '\n' ' ')"
done
