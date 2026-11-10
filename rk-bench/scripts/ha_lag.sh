#!/bin/bash
#
# 실시간 복제 지연 측정 — 마스터에 일정 부하를 거는 동안 "마스터 커밋 → 슬레이브에서 보임" 까지의 시간.
#
# 방법: 마스터에서 탐침 행(ha_lag_probe.ts = SYSDATETIME)을 PROBE_INTERVAL 마다 넣고,
#       슬레이브에서 1초마다 SYSDATETIME - MAX(ts) 를 읽는다. 두 노드는 같은 호스트라 시계가 같다.
#       지연 하한 = 탐침 간격 + csql 실행 시간 (약 0.3초). 그 이하는 구분하지 못한다.
#
#   ./ha_lag.sh [부하초=120] [워커수...=1 4 10 20]
#   SCENS="A B" OUT=... ./ha_lag.sh 120 1 4 10 20
#
# 샘플러는 붙이지 않는다 (지연·처리량을 흔들지 않게). trace 는 측정 동안 0.
#
set -u

DUR=${1:-120}
shift 1 2>/dev/null || true
COUNTS=(1 4 10 20)
[ $# -gt 0 ] && COUNTS=("$@")
SCENS=${SCENS:-"A B"}
PROBE_INTERVAL=${PROBE_INTERVAL:-0.2}
TAIL_MAX=${TAIL_MAX:-240}          # 부하가 끝난 뒤 지연이 1초 아래로 내려올 때까지 기다리는 상한
SLAVE=${SLAVE:-youngjun2}
CUBRID_HOME=${CUBRID_HOME:-/home/youngjun/CUBRID_optdebug}   # 다른 설치본(예: RK 브랜치 /home/youngjun/CUBRID_26246)은 환경변수로
HACONF=$CUBRID_HOME/conf/cubrid_ha.conf
SELF=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$SELF/../results/ha_lag}
mkdir -p "$OUT"
RESULT=$OUT/summary.tsv
[ -s "$RESULT" ] || printf 'scen\tworkers\tmaster_tx_s\tslave_tx_s\tlag_p50_ms\tlag_p90_ms\tlag_p99_ms\tlag_max_ms\tlag_end_ms\tdrain_s\n' > "$RESULT"

export CUBRID=$CUBRID_HOME CUBRID_DATABASES=$CUBRID_HOME/databases
export LD_LIBRARY_PATH=$CUBRID/lib:$CUBRID/cci/lib:${LD_LIBRARY_PATH:-}
CSQL=$CUBRID/bin/csql

SSHCTL="-o BatchMode=yes -o ControlMaster=auto -o ControlPath=/tmp/ha_lag_ssh.%r@%h:%p -o ControlPersist=15m"
RSH="ssh -n $SSHCTL $SLAVE"
ENV_PREFIX="export CUBRID=$CUBRID_HOME CUBRID_DATABASES=$CUBRID_HOME/databases LD_LIBRARY_PATH=$CUBRID_HOME/lib:$CUBRID_HOME/cci/lib PATH=$CUBRID_HOME/bin:\$PATH;"
# 원격 백그라운드는 쓰지 않는다. 원격 데몬 기동은 반드시 원격 쪽에서 stdin/stdout/stderr 를 끊는다.
rcub () { $RSH "$ENV_PREFIX $*"; }

say () { printf '\n[%s] \033[1m=== %s ===\033[0m\n' "$(date +%H:%M:%S)" "$*"; }

# 슬레이브: "지연ms commit_counter" 한 줄. 탐침이 아직 없으면 지연 자리에 -
probe_slave () {
  rcub "csql -u dba -C -t -N -c 'SELECT SYSDATETIME - MAX(ts), (SELECT commit_counter FROM db_ha_apply_info) FROM ha_lag_probe;' testdb 2>/dev/null" \
    | grep -oE '(-?[0-9]+|NULL)' | tr '\n' ' '
}

# ---- 준비: 탐침 테이블 (마스터에서 만들면 슬레이브로 복제된다)
( cd /tmp && $CSQL -u dba -C -c "CREATE TABLE IF NOT EXISTS ha_lag_probe (id BIGINT AUTO_INCREMENT PRIMARY KEY, ts DATETIME);" testdb ) >/dev/null 2>&1
ORIG_TRACE=$(rcub "awk -F= '/^ha_writeset_trace_level/{print \$2}' $HACONF" | tr -d '[:space:]')
rcub "sed -i 's/^ha_writeset_trace_level=.*/ha_writeset_trace_level=0/' $HACONF"
say "실시간 지연 측정 — 시나리오 $SCENS / 부하 ${DUR}초 / 워커 ${COUNTS[*]} / 탐침 ${PROBE_INTERVAL}초 (trace ${ORIG_TRACE:-?} → 0)"

run_one () {
  local scen=$1 n=$2
  local dir=$OUT/${scen}_w$n; rm -rf "$dir"; mkdir -p "$dir"
  say "$scen / 워커 $n — applylogdb 재기동"
  rcub "sed -i 's/^ha_apply_worker_count=.*/ha_apply_worker_count=$n/' $HACONF"
  rcub "timeout 30 cubrid heartbeat applylogdb stop testdb youngjun1 </dev/null >/dev/null 2>&1"
  sleep 3
  rcub "timeout 60 cubrid heartbeat applylogdb start testdb youngjun1 </dev/null >/dev/null 2>&1"
  sleep 20                                   # 재기동 동안 쌓인 소량 로그를 먼저 소진

  # 탐침 기록기 (마스터, 로컬)
  local stopf=$dir/probe.stop
  ( cd /tmp; while [ ! -f "$stopf" ]; do
      $CSQL -u dba -C -c "INSERT INTO ha_lag_probe (ts) VALUES (SYSDATETIME);" testdb >/dev/null 2>&1
      sleep "$PROBE_INTERVAL"; done ) &
  local ppid=$!
  sleep 5
  local base; base=$(probe_slave); echo "  부하 전 지연(ms) / commit_counter: $base"

  # 부하
  say "$scen / 워커 $n — 부하 ${DUR}초 + 지연 기록"
  ( cd "$SELF" && CUBRID_HOME=$CUBRID_HOME ./ha_load.sh "$scen" "$DUR" ) > "$dir/load.log" 2>&1 &
  local lpid=$!
  local t0; t0=$(date +%s)
  local ts=$dir/lag.txt; : > "$ts"
  while kill -0 "$lpid" 2>/dev/null; do
    printf '%s %s\n' "$(date +%s) load" "$(probe_slave)" >> "$ts"
    sleep 1
  done
  local t1; t1=$(date +%s)
  # 부하 종료 후 지연이 1초 아래로 내려올 때까지
  local drain=-1
  while [ $(( $(date +%s) - t1 )) -lt "$TAIL_MAX" ]; do
    local l; l=$(probe_slave)
    printf '%s %s\n' "$(date +%s) tail" "$l" >> "$ts"
    local ms=${l%% *}
    if [[ "$ms" =~ ^[0-9]+$ ]] && [ "$ms" -lt 1000 ]; then drain=$(( $(date +%s) - t1 )); break; fi
    sleep 1
  done
  touch "$stopf"; wait "$ppid" 2>/dev/null

  # 집계
  local mtx; mtx=$(grep -oE '총 라운드 [0-9]+' "$dir/load.log" | grep -oE '[0-9]+' | tail -1)
  mtx=$(awk -v r="${mtx:-0}" -v d="$DUR" 'BEGIN{printf "%.1f", r*100/d}')
  local stx; stx=$(awk '$2=="load" && $4 ~ /^[0-9]+$/ {if(!a){a=$4; ta=$1} b=$4; tb=$1} END{if(tb>ta) printf "%.1f", (b-a)/(tb-ta); else print "-"}' "$ts")
  local st; st=$(awk '$2=="load" && $3 ~ /^-?[0-9]+$/ {print $3}' "$ts" | sort -n | awk '
    function q(f,  i) { i = int(NR * f) + 1; if (i > NR) i = NR; return a[i] }
    { a[NR] = $1 }
    END { if (!NR) { print "- - - -"; exit } printf "%d %d %d %d\n", q(0.5), q(0.9), q(0.99), a[NR] }')
  local lend; lend=$(awk '$2=="load" && $3 ~ /^-?[0-9]+$/ {x=$3} END{print x+0}' "$ts")
  set -- $st - - - -
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$scen" "$n" "$mtx" "$stx" "$1" "$2" "$3" "$4" "$lend" "$drain" >> "$RESULT"
  echo "  마스터 ${mtx} tx/s, 슬레이브 적용 ${stx} tx/s, 지연 p50/p90/p99/max = $1/$2/$3/$4 ms, 부하 끝 시점 ${lend} ms, 소진 ${drain}초"
}

for s in $SCENS; do
  for n in "${COUNTS[@]}"; do
    run_one "$s" "$n" || echo "$s 워커 $n 실패"
  done
done

say "설정 복구 (워커 10, trace ${ORIG_TRACE:-1})"
rcub "sed -i 's/^ha_apply_worker_count=.*/ha_apply_worker_count=10/; s/^ha_writeset_trace_level=.*/ha_writeset_trace_level=${ORIG_TRACE:-1}/' $HACONF"
rcub "timeout 30 cubrid heartbeat applylogdb stop testdb youngjun1 </dev/null >/dev/null 2>&1"
sleep 3
rcub "timeout 60 cubrid heartbeat applylogdb start testdb youngjun1 </dev/null >/dev/null 2>&1"
say "결과"; column -t "$RESULT"
echo "끝 $(date +%T)"
