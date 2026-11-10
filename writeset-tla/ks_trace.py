#!/usr/bin/env python3
# Compact the final master log and slave apply order of a WritesetSysopKeyed counterexample.
import sys, re
txt = open(sys.argv[1]).read()
err = re.search(r'Error: Invariant .*', txt)
print(err.group(0) if err else "no error")
states = re.split(r'\nState \d+: ', txt)
last = states[-1]
def var(name):
    m = re.search(r'^/\\ ' + name + r' = (.*?)(?=^/\\ |\n\n|\Z)', last, re.S | re.M)
    return ' '.join(m.group(1).split()) if m else None
mlog = var('mlog')
for i, r in enumerate(re.findall(r'\[ (k \|->.*?) \]', mlog or ''), 1):
    f = dict(re.findall(r'(\w+) \|-> ("[^"]*"|\{[^}]*\}|<<.*?>>(?=,|$)|[^,]+)', r))
    k = f.get('k', '').strip('"')
    print(f"  {i:2d} {k} {f.get('t','')} dep={f.get('dep','')} keys={f.get('keys','')} co={f.get('co','')}")
print("  wr per record:", re.findall(r'wr \|-> (\{.*?\}), co', mlog or ''))
for v in ['sdb', 'wseq', 'crashes', 'storedR', 'storedC']:
    print(f"  {v} = {var(v)}")
