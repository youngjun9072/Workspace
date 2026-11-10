#!/usr/bin/env python3
# Print a compact per-step view of a TLC counterexample from out-bnd-<name>.txt: action, mlog length, rd,
# committed, storedC/storedR, slots act/start, infl lsas, sdb units.
import re, sys
txt = open(sys.argv[1]).read()
states = re.split(r'\nState (\d+): ', txt)
for i in range(1, len(states), 2):
    n, body = states[i], states[i + 1]
    head = body.split('\n', 1)[0]
    def g(v):
        m = re.search(r'/\\ ' + v + r' = (.*?)(?=\n/\\ |\n\n|\Z)', body, re.S)
        return re.sub(r'\s+', ' ', m.group(1)) if m else '?'
    act = re.sub(r' line.*', '', head)
    print(f"{n:>3} {act:28} rd={g('rd')} com={g('committed')} sC={g('storedC')} sR={g('storedR')} crash={g('crashes')} halted={g('halted')}")
    sl = re.sub(r'n \|-> [0-9]+, ', '', g('slot'))
    lsa = r'lsa \|-> ([0-9]+)'
    il, pl = re.findall(lsa, g('infl')), re.findall(lsa, g('pending'))
    print("     slot=" + sl)
    print(f"     infl={il} pend={pl} sdb={g('sdb')} markers={g('markers')}")
ms = re.findall(r"/\\ mlog = (<<.*?>>)\n", txt, re.S); m = ms[-1] if ms else None
if m:
    print('mlog:', ' '.join(f"{i+1}:{k}{t[-1]}" + (f"(dep{d})" if k in 'SC' else '') for i, (k, t, d) in enumerate(re.findall(r'k \|-> "(\w)", t \|-> (\w+), dep \|-> (\d+)', m))))
