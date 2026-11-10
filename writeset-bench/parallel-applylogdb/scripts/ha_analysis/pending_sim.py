# WSET trace 로 pending 리스트를 재현한다.
#   status 0 = 즉시 디스패치, 2 = 파킹(리스트 꼬리에 붙음), 1 = 파킹됐다가 해제
# la_pending_pop_ready() 는 head 부터 훑으므로, 해제된 태스크가 리스트에서 몇 번째였는지가
# 그 pop 한 번이 걸은 노드 수다 (성공한 pop 기준. 아무것도 못 꺼낸 헛스캔은 로그에 안 남는다).
import gzip, re, sys, statistics as st
files = sys.argv[1:]
import os
# 측정 창 (슬레이브 로컬 시각). WIN="4=13:50:00-13:52:00,10=..." 로 덮어쓴다.
win = {
  1: ("00:44:36", "00:48:06"), 4: ("00:50:59", "00:53:16"),
  10: ("00:57:07", "00:59:23"), 20: ("01:03:14", "01:05:16")}
if os.environ.get("WIN"):
    win = {}
    for part in os.environ["WIN"].split(","):
        k, ab = part.split("="); a, b = ab.split("-"); win[int(k)] = (a, b)
def sec(h): a=h.split(':'); return int(a[0])*3600+int(a[1])*60+int(a[2])
W = {k:(sec(a),sec(b)) for k,(a,b) in win.items()}
rt = re.compile(r'^Time: \S+ (\d\d:\d\d:\d\d)')
rs = re.compile(r'\[WSET\] reader schedule trid=(\d+) commit_lsa=(\S+) type=\d+ dependency=(\S+) status=(\d)')

class BIT:
    def __init__(s,n): s.n=n; s.t=[0]*(n+1)
    def add(s,i,v):
        i+=1
        while i<=s.n: s.t[i]+=v; i+=i&-i
    def sum(s,i):  # [0,i)
        r=0
        while i>0: r+=s.t[i]; i-=i&-i
        return r

cur=None; now=0
stats={}
def newtier(k):
    return dict(n0=0,n1=0,n2=0,nulldep=0,depth=[],scan=[],orphan=0,bit=BIT(2_000_000),seq=0,where={},live=0,maxd=0,parkt={},wait=[])
for fn in files:
    with gzip.open(fn,'rt',errors='replace') as f:
        for line in f:
            m=rt.match(line)
            if m: now=sec(m.group(1)); continue
            m=rs.search(line)
            if not m: continue
            k=None
            for t,(a,b) in W.items():
                if a<=now<=b: k=t
            if k is None: cur=None; continue
            if cur!=k: cur=k; stats[k]=newtier(k)   # 창 시작 = applylogdb 재기동 직후, 리스트 비어 있음
            S=stats[k]; key=(m.group(1),m.group(2)); dep=m.group(3); s=m.group(4)
            if s=='0': S['n0']+=1
            elif s=='2':
                S['n2']+=1
                if dep in ('-1|-1','0|0'): S['nulldep']+=1
                S['where'][key]=S['seq']; S['bit'].add(S['seq'],1); S['seq']+=1; S['live']+=1
                S['parkt'][key]=now
                S['maxd']=max(S['maxd'],S['live']); S['depth'].append(S['live'])
            elif s=='1':
                S['n1']+=1
                q=S['where'].pop(key,None)
                if q is None: S['orphan']+=1; continue
                pos=S['bit'].sum(q)          # 앞에 남아 있는 노드 수
                S['scan'].append(pos+1)
                S['bit'].add(q,-1); S['live']-=1
                S['wait'].append(now-S['parkt'].pop(key))
                S['depth'].append(S['live'])
def pct(a,p):
    a=sorted(a); return a[min(len(a)-1,int(len(a)*p))] if a else 0
print(f"{'워커':>4} {'즉시':>8} {'파킹':>8} {'파킹률':>6} {'dep없음':>7} {'최대깊이':>8} {'평균깊이':>8} {'스캔 평균':>9} {'p50':>5} {'p90':>5} {'p99':>6} {'최대':>6} {'맨앞해제':>8} {'파킹시간p50/p90(s)':>18}")
for k in sorted(stats):
    S=stats[k]; tot=S['n0']+S['n2']; sc=S['scan']
    head=sum(1 for x in sc if x==1)
    print(f"{k:>4} {S['n0']:>8} {S['n2']:>8} {100*S['n2']/max(tot,1):>5.1f}% {S['nulldep']:>7} {S['maxd']:>8} {st.mean(S['depth']) if S['depth'] else 0:>8.1f} "
          f"{st.mean(sc) if sc else 0:>9.1f} {pct(sc,.5):>5} {pct(sc,.9):>5} {pct(sc,.99):>6} {max(sc) if sc else 0:>6} {100*head/max(len(sc),1):>7.1f}% "
          f"{pct(S['wait'],.5):>8}/{pct(S['wait'],.9):<8} (해제 {S['n1']}, 짝없음 {S['orphan']})")
