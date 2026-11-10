#!/usr/bin/env python3
# Compact a TLC error trace: print action name and the changed variables per state.
import sys, re
txt = open(sys.argv[1]).read()
keep = sys.argv[2].split(",") if len(sys.argv) > 2 else None
states = re.split(r'\nState (\d+): ', txt)
prev = {}
print(re.search(r'Error: .*', txt).group(0) if re.search(r'Error: .*', txt) else "no error")
for i in range(1, len(states), 2):
    num, body = states[i], states[i+1]
    head, _, rest = body.partition('\n')
    act = re.sub(r' line.*', '', head)
    vars_ = {}
    for m in re.finditer(r'^/\\ (\w+) = (.*?)(?=^/\\ |\Z)', rest, re.S | re.M):
        vars_[m.group(1)] = ' '.join(m.group(2).split())
    ch = {k: v for k, v in vars_.items() if prev.get(k) != v and (keep is None or k in keep)}
    print(f"[{num}] {act}")
    for k, v in ch.items():
        print(f"     {k} = {v[:400]}")
    prev = vars_
