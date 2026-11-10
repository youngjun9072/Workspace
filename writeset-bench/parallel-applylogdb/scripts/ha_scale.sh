#!/bin/bash
#
# ha_apply_worker_count 확장성 측정
#
# 워커 수를 바꿔가며 "슬레이브가 실제로 적용한 트랜잭션/초" 를 잰다.
# 스택 분포만으로는 '처리량이 안 는다'를 증명할 수 없으므로,
# db_ha_apply_info.commit_counter 의 증분을 처리량 지표로 쓴다.
#
# 판정:
#   워커를 늘려도 처리량이 안 늘고 la_insert_applied_tx_marker 대기만
#   커지면 → 그 전역 뮤텍스가 병렬도 상한이다.
#
#   ./ha_scale.sh [지속초] [샘플수] [샘플간격] [워커수...]
#   ./ha_scale.sh 90 40 2 1 4 10 20
#

set -u

DUR=${1:-90}
SAMPLES=${2:-40}
INTERVAL=${3:-2}
shift 3 2>/dev/null || true
COUNTS=(1 4 10 20)
[ $# -gt 0 ] && COUNTS=("$@")

SLAVE=${SLAVE:-youngjun2}
CUBRID_HOME=/home/youngjun/CUBRID_optdebug
SELF=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-/tmp/ha_scale}
HACONF=$CUBRID_HOME/conf/cubrid_ha.conf

export CUBRID=$CUBRID_HOME
export CUBRID_DATABASES=$CUBRID/databases
export LD_LIBRARY_PATH=$CUBRID/lib:$CUBRID/cci/lib:${LD_LIBRARY_PATH:-}

mkdir -p "$OUT"
RESULT=$OUT/summary.tsv
[ -s "$RESULT" ] || printf 'workers\tcommits\telapsed_s\ttx_per_s\tidle_pct\tmarker_pct\tnetrecv_pct\tRSS_MB\tVSZ_MB\n' > "$RESULT"

say () { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }

# 슬레이브 적용 커밋 수
commits () {
  ssh -o BatchMode=yes "$SLAVE" \
    "bash -lc 'csql -u dba -C -c \"SELECT commit_counter FROM db_ha_apply_info;\" testdb 2>/dev/null'" \
    | grep -E '^ +[0-9]+ *$' | tail -1 | tr -d ' '
}

set_workers () {
  local n=$1
  ssh -o BatchMode=yes "$SLAVE" "sed -i 's/^ha_apply_worker_count=.*/ha_apply_worker_count=$n/' $HACONF && grep ha_apply_worker_count $HACONF"
}

restart_slave_ha () {
  # heartbeat start 가 반환하지 않는 경우가 있으므로 timeout 을 걸고,
  # 성공 여부는 명령의 종료코드가 아니라 프로세스 존재로 판정한다.
  ssh -o BatchMode=yes "$SLAVE" "bash -lc 'timeout 60 cubrid heartbeat stop' >/dev/null 2>&1"
  sleep 5
  ssh -o BatchMode=yes "$SLAVE" "bash -lc 'timeout 60 cubrid heartbeat start' >/dev/null 2>&1 &
                                 sleep 25"
  local i pid=
  for i in 1 2 3 4 5 6; do
    pid=$(ssh -o BatchMode=yes "$SLAVE" 'pgrep -f "cub_admin applylogdb"' 2>/dev/null | head -1)
    [ -n "$pid" ] && break
    sleep 5
  done
  echo "$pid"
}

for N in "${COUNTS[@]}"; do
  say "워커 $N 개"

  set_workers "$N"
  PID=$(restart_slave_ha)
  if [ -z "$PID" ]; then
    echo "applylogdb 기동 실패 — 건너뜀" >&2
    continue
  fi
  NTH=$(ssh -o BatchMode=yes "$SLAVE" "ls /proc/$PID/task | wc -l")
  echo "applylogdb pid=$PID, 스레드 $NTH 개 (워커 $N + 부속 3)"

  # 부하 시작
  ( cd "$SELF" && CUBRID_HOME=$CUBRID_HOME ./ha_load.sh A "$DUR" ) > "$OUT/load_$N.log" 2>&1 &
  LOADPID=$!
  sleep 8    # 워밍업: 워커가 실제로 일을 받기 시작할 때까지

  C1=$(commits); T1=$(date +%s)
  # 메모리 추이를 같은 창에서 기록 (VSZ 가 ha_apply_max_mem_size 판정값)
  ssh -o BatchMode=yes "$SLAVE" \
      "for i in \$(seq 1 $SAMPLES); do grep -E '^(VmRSS|VmSize)' /proc/$PID/status 2>/dev/null | tr '\\n' ' '; echo; sleep $INTERVAL; done" \
      > "$OUT/mem_$N.txt" 2>&1 &
  MEMPID=$!
  ssh -o BatchMode=yes "$SLAVE" "~/ha_pstack.sh $PID $SAMPLES $INTERVAL /tmp/scale_$N" \
      > "$OUT/pstack_$N.txt" 2>&1
  C2=$(commits); T2=$(date +%s)
  wait "$MEMPID" 2>/dev/null

  wait "$LOADPID" 2>/dev/null

  EL=$(( T2 - T1 )); [ "$EL" -lt 1 ] && EL=1
  DC=$(( ${C2:-0} - ${C1:-0} ))
  TPS=$(awk -v d="$DC" -v e="$EL" 'BEGIN{printf "%.1f", d/e}')

  pct () { grep -m1 "$1" "$OUT/pstack_$N.txt" | awk '{print $1}' | tr -d '%'; }
  IDLE=$(pct 'la_task_queue_pop'); IDLE=${IDLE:-0}
  MARK=$(pct 'la_insert_applied_tx_marker'); MARK=${MARK:-0}
  NET=$(pct 'css_readn'); NET=${NET:-0}

  # 메모리: 창 전체의 최소/최대 VSZ·RSS (kB -> MB)
  read -r RSS0 RSS1 VSZ0 VSZ1 <<< "$(awk '
    /VmRSS/ { for(i=1;i<=NF;i++) if($i=="VmRSS:"){r=$(i+1)}
              for(i=1;i<=NF;i++) if($i=="VmSize:"){v=$(i+1)}
              if(r!=""){ if(rmin==""||r<rmin)rmin=r; if(r>rmax)rmax=r }
              if(v!=""){ if(vmin==""||v<vmin)vmin=v; if(v>vmax)vmax=v } }
    END { printf "%.0f %.0f %.0f %.0f", rmin/1024, rmax/1024, vmin/1024, vmax/1024 }
  ' "$OUT/mem_$N.txt" 2>/dev/null)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s-%s\t%s-%s\n' \
    "$N" "$DC" "$EL" "$TPS" "$IDLE" "$MARK" "$NET" "${RSS0:-?}" "${RSS1:-?}" "${VSZ0:-?}" "${VSZ1:-?}" >> "$RESULT"
  echo "적용 커밋 $DC 건 / ${EL}초 = $TPS tx/s   (유휴 ${IDLE}% / marker ${MARK}% / netrecv ${NET}%)"
  echo "메모리 RSS ${RSS0:-?}-${RSS1:-?} MB / VSZ ${VSZ0:-?}-${VSZ1:-?} MB  (한도 ha_apply_max_mem_size=4096 MB, VSZ 기준)"

  sleep 10   # 다음 설정 전 복제 소강
done

say "결과 요약"
column -t -s $'\t' "$RESULT"

say "판정 기준"
cat <<'EOT'
  tx_per_s 가 워커 수에 비례해 늘면      → 병렬화가 효과를 낸다
  tx_per_s 가 평평한데 marker_pct 가 커지면 → la_sql_compile_mutex 가 상한이다
  idle_pct 가 계속 높으면(>70%)          → 슬레이브가 포화 안 됨, 부하를 더 올려야 한다
EOT

say "워커 수를 10 으로 복구"
set_workers 10
restart_slave_ha > /dev/null
echo "복구 완료"
echo
echo "원본: $OUT/pstack_<N>.txt , $OUT/load_<N>.log , $SLAVE:/tmp/scale_<N>/"
