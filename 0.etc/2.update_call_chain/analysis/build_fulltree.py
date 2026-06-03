#!/usr/bin/env python3
"""
전체 on-CPU 콜체인 (모든 서버 스레드·기능 포함, % of total).

locator_insert/update_force subtree 만이 아니라, 캡처된 *모든 sample* 을 thread(comm)
별로 묶어 top-down 콜트리로 렌더. 각 sample 의 최외곽 프레임을 thread 노드 밑에 매달아
(stack 이 truncate 돼도) 100% 를 덮는다.

산출 (analysis/):
  - calltree_full.txt    : (ALL) → thread(comm) → 콜트리, 노드 % = of total_samples
  - inclusive_total.txt  : 전 함수 inclusive % of total (컷오프 없음)
  - fulltree_data.json   : comm 별 sample 수

usage: build_fulltree.py <BASE_DIR> [node_min_pct] [comm_min_pct] [min_edge]
"""
import re, json, sys
from pathlib import Path
from collections import defaultdict

BASE = Path(sys.argv[1])
NODE_MIN_PCT = float(sys.argv[2]) if len(sys.argv) > 2 else 0.20   # 함수 노드 컷 (% of total)
COMM_MIN_PCT = float(sys.argv[3]) if len(sys.argv) > 3 else 0.30   # thread 노드 컷 (% of total)
MIN_EDGE     = int(sys.argv[4]) if len(sys.argv) > 4 else 30

SCRIPT = BASE / "oncpu.script"
ANALYSIS = BASE / "analysis"; ANALYSIS.mkdir(exist_ok=True)
OUT_TREE = ANALYSIS / "calltree_full.txt"
OUT_INCL = ANALYSIS / "inclusive_total.txt"
OUT_JSON = ANALYSIS / "fulltree_data.json"

frame_re  = re.compile(r'^\s+[0-9a-f]+\s+(.*?)\+0x[0-9a-f]+')
header_re = re.compile(r'^(.+?)\s+\d+\s+\d+\.\d+:')

# comm 별 집계
edges_comm = defaultdict(lambda: defaultdict(int))   # comm -> (caller,callee)->cnt
incl_comm  = defaultdict(lambda: defaultdict(int))    # comm -> func -> cnt
top_comm   = defaultdict(lambda: defaultdict(int))    # comm -> outermost frame -> cnt
comm_total = defaultdict(int)
incl_total = defaultdict(int)
total_samples = 0

def flush(comm, seq):
    global total_samples
    if not seq:
        return
    total_samples += 1
    comm_total[comm] += 1
    filt = []; prev = None
    for s in seq:
        if s != prev:
            filt.append(s); prev = s
    for f in set(filt):
        incl_comm[comm][f] += 1
        incl_total[f] += 1
    for i in range(len(filt) - 1):
        edges_comm[comm][(filt[i+1], filt[i])] += 1   # caller=filt[i+1], callee=filt[i]
    top_comm[comm][filt[-1]] += 1                       # 최외곽 프레임 = thread 노드의 자식

cur_comm = "?"
seq = []
with SCRIPT.open() as fh:
    for line in fh:
        if line == '\n':
            flush(cur_comm, seq); seq = []
            continue
        m = frame_re.match(line)
        if m:
            sym = m.group(1).strip()
            if sym and sym != '??' and not sym.startswith('['):
                seq.append(sym)
        else:
            h = header_re.match(line)
            if h:
                cur_comm = h.group(1).strip()
    flush(cur_comm, seq)

def pct(c):  # of total
    return c * 100.0 / total_samples if total_samples else 0.0

# ---- inclusive_total 표 (전 함수) ----
allf = sorted(incl_total.items(), key=lambda x: -x[1])
with OUT_INCL.open("w") as fh:
    fh.write(f"# 전체 on-CPU inclusive 함수 표 — {len(allf)}개 (컷오프 없음)\n")
    fh.write(f"# denom = total_samples = {total_samples}\n\n")
    fh.write(f"{'%total':>8}  {'samples':>8}  func\n")
    for f, c in allf:
        fh.write(f"{pct(c):8.3f}  {c:8d}  {f}\n")

# ---- 전체 콜트리: (ALL) -> comm -> 함수 ----
lines = []
lines.append(f"# 전체 on-CPU 콜체인 (모든 thread·함수, 노드 % = of total_samples={total_samples})")
lines.append(f"# 함수 노드 컷 {NODE_MIN_PCT}% / thread 컷 {COMM_MIN_PCT}% / MIN_EDGE {MIN_EDGE}")
lines.append("")
lines.append(f"[100.00%] (ALL on-CPU)   total_samples={total_samples}")

comms = sorted(comm_total.items(), key=lambda x: -x[1])
shown_comm = [c for c, n in comms if pct(n) >= COMM_MIN_PCT]
hidden_comm = [(c, n) for c, n in comms if pct(n) < COMM_MIN_PCT]

# 소스로 알려진 호출 엣지지만 dwarf truncation 으로 측정 스택에선 끊긴 것 → 트리에 이어붙임(graft).
# (xlocator_repl_force 의 switch 가 연산별 force 를 호출 — locator_sr.c:7029/7045/7057)
GRAFT_EDGES = {
    ("xlocator_repl_force", "locator_insert_force"),
    ("xlocator_repl_force", "locator_update_force"),
    ("xlocator_repl_force", "locator_delete_force"),
}

def render_comm(comm, comm_last):
    ch = defaultdict(list)
    for (caller, callee), c in edges_comm[comm].items():
        if c >= MIN_EDGE:
            ch[caller].append((callee, c))
    # ── 소스 graft: 측정에서 끊긴 엣지를 callee 의 inclusive 수만큼 가중치로 주입 ──
    grafted = set()
    for ca, ce in GRAFT_EDGES:
        wt = incl_comm[comm].get(ce, 0)
        if wt <= 0:
            continue
        if all(x[0] != ce for x in ch.get(ca, [])):   # 이미 측정 엣지가 있으면 그대로 둠
            ch[ca].append((ce, wt))
            grafted.add((ca, ce))
    for k in ch: ch[k].sort(key=lambda x: -x[1])
    def cpct(f): return pct(incl_comm[comm].get(f, 0))

    cbar = "    " if comm_last else "│   "
    lines.append(f"{('└─ ' if comm_last else '├─ ')}[{pct(comm_total[comm]):6.2f}%] «{comm}»  ({comm_total[comm]} smp)")

    expanded = set()   # 스레드당 함수 서브트리 1회만 전개 (재등장은 ↑ 로 collapse)

    def walk(node, ancestors, chain, graft_in=False, chunk_no=None):
        bars = cbar + "".join("    " if last else "│   " for last in chain[:-1])
        head = "└─ " if chain[-1] else "├─ "
        gmark = "  ⎘소스연결" if graft_in else ""
        if chunk_no is not None:
            gmark += f"   ◆덩어리#{chunk_no} (이 스레드의 독립 호출 조각 — 상위는 truncation 으로 끊김)"
        has_children = any(cpct(c) >= NODE_MIN_PCT and c not in ancestors for c, _ in ch.get(node, []))
        if node in expanded and has_children:
            lines.append(f"{bars}{head}[{cpct(node):6.2f}%] {node}{gmark}  ↑")   # 위에서 이미 전개됨
            return
        lines.append(f"{bars}{head}[{cpct(node):6.2f}%] {node}{gmark}")
        expanded.add(node)
        new_anc = ancestors | {node}
        vis = []
        for c, w in ch.get(node, []):
            if cpct(c) < NODE_MIN_PCT and (node, c) not in grafted: continue
            if c == node: vis.append(("R", c))
            elif c in ancestors: continue
            else: vis.append(("O", c))
        for i, (t, c) in enumerate(vis):
            last = (i == len(vis) - 1)
            if t == "R":
                b2 = cbar + "".join("    " if lf else "│   " for lf in chain)
                lines.append(f"{b2}{'└─ ' if last else '├─ '}{c}   (재귀)")
            else:
                walk(c, new_anc, chain + [last], graft_in=((node, c) in grafted))

    # graft 로 다른 노드 밑에 붙은 callee 는 top(고아) 에서 제외 → 한 곳에서만 등장
    grafted_callees = {ce for (_, ce) in grafted}
    tops = sorted([(f, c) for f, c in top_comm[comm].items()
                   if pct(c) >= NODE_MIN_PCT and f not in grafted_callees],
                  key=lambda x: -x[1])
    # tops 를 순서대로 처리하되, 앞 덩어리에서 이미 전개된 함수는 새 덩어리로 안 만들고 "참조"로 접는다.
    real, refs = [], []
    seen_pre = set()
    # 1차: 첫 덩어리(가장 큰 것)가 전개할 함수를 미리 못 아므로, 실제 walk 하며 판단
    chunk_no = 0
    pending = list(tops)
    # 먼저 어떤 게 real 인지 결정하려면 walk 가 expanded 를 채워야 함 → 순차 walk
    for f, c in pending:
        if f in expanded:          # 앞 덩어리에서 이미 전개됨
            refs.append((f, c)); continue
        chunk_no += 1
        real.append((f, c, chunk_no))
        walk(f, set(), [False], chunk_no=chunk_no if len(pending) > 1 else None)
    # 이미 전개된 truncation 고아들: 한 줄로 압축
    if refs:
        refs.sort(key=lambda x: -x[1])
        lines.append(f"{cbar}└─ (기타 truncation 고아 {len(refs)}개 — 서브트리는 위 덩어리에 이미 전개됨, % of total):")
        for f, c in refs:
            lines.append(f"{cbar}      {pct(c):6.2f}%  {f}")

for idx, comm in enumerate(shown_comm):
    render_comm(comm, idx == len(shown_comm) - 1 and not hidden_comm)
if hidden_comm:
    other = sum(n for _, n in hidden_comm)
    lines.append(f"└─ [{pct(other):6.2f}%] «기타 thread {len(hidden_comm)}종»  ({other} smp, 각 <{COMM_MIN_PCT}%)")
    for c, n in hidden_comm[:40]:
        lines.append(f"       {pct(n):6.2f}%  {c}  ({n})")

OUT_TREE.write_text("\n".join(lines) + "\n")

OUT_JSON.write_text(json.dumps({
    "total_samples": total_samples,
    "comm_total": dict(comm_total),
    "n_funcs": len(allf),
}, indent=2))

print(f"total_samples = {total_samples}  funcs = {len(allf)}  threads = {len(comm_total)}")
print("thread 분포 (top):")
for c, n in comms[:12]:
    print(f"  {pct(n):6.2f}%  {n:7d}  {c}")
print(f"→ {OUT_TREE}\n→ {OUT_INCL}\n→ {OUT_JSON}")
