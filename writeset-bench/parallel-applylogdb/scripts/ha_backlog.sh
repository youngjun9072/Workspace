#!/bin/bash
#
# 백로그 따라잡기 측정 — applylogdb 의 "순수 적용 처리량"
#
# ha_scale.sh 의 교란 요인(로그 도착 속도가 한계였을 가능성)을 제거한다.
#
#   1. 슬레이브의 applylogdb 만 정지한다. copylogdb 는 계속 돌므로
#      마스터 로그는 슬레이브 디스크에 계속 쌓인다.
#   2. 마스터에 부하를 걸어 백로그를 만든다.
#   3. 부하를 끝내고 copylogdb 가 다 받을 때까지 기다린다.
#   4. applylogdb 를 기동하고, commit_counter 가 멈출 때까지의
#      시간과 증분을 잰다. 로그는 이미 로컬 디스크에 다 있으므로
#      여기서 재는 건 순수한 적용 속도다.
#
# 워커 수는 applylogdb 가 기동할 때 직접 읽는다 (log_applier.c:8967).
# 따라서 conf 만 고치고 applylogdb 만 재기동하면 된다 — heartbeat 전체
# 재시작이 필요 없다.
#
#   ./ha_backlog.sh [부하초] [워커수...]
#   ./ha_backlog.sh 120 1 4 10 20
#

set -u

BUILD=${1:-120}
# 빠른 구성은 따라잡기가 순식간에 끝나 분해능이 안 나온다.
# 워커 수에 따라 백로그를 키운다 (BUILD_SCALE=0 이면 전부 동일).
BUILD_SCALE=${BUILD_SCALE:-1}
shift 1 2>/dev/null || true
COUNTS=(1 4 10 20)
[ $# -gt 0 ] && COUNTS=("$@")

SCEN=${SCEN:-A}
SLAVE=${SLAVE:-youngjun2}
CUBRID_HOME=${CUBRID_HOME:-/home/youngjun/CUBRID_optdebug}   # 다른 설치본(예: RK 브랜치 /home/youngjun/CUBRID_26246)은 환경변수로
SELF=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-/tmp/ha_backlog}
HACONF=$CUBRID_HOME/conf/cubrid_ha.conf
SETTLE=${SETTLE:-25}             # copylogdb 가 남은 로그를 다 받을 시간
QUIET_POLLS=${QUIET_POLLS:-8}    # 따라잡기 완료 판정에 쓰는 창 크기(폴링 횟수)
TRICKLE=${TRICKLE:-15}           # 그 창에서 이만큼 미만으로 늘면 "다 따라잡았다"로 본다
POLL=${POLL:-1}
MAX_CATCHUP=${MAX_CATCHUP:-1800}   # 따라잡기 상한(초) — 안 끝나면 포기하고 기록
STOPFLAG=/tmp/ha_bl_stop
# 샘플러: pstack(기존) | eustack(대상 정지 시간이 짧다) | none(처리량만 깨끗하게)
# pstack 은 덤프 동안 applylogdb 전체를 1~2초씩 멈춘다 — 처리량과 함께 재면 처리량이 오염된다.
SAMPLER=${SAMPLER:-pstack}
APPLY_INTERVAL=${APPLY_INTERVAL:-1}
# 슬레이브 cub_server 도 같이 뜬다 (초 간격, 0 = 안 뜸). eu-stack 기준 1회 약 0.8초 정지.
SRV_INTERVAL=${SRV_INTERVAL:-0}
# 측정 동안 ha_writeset_trace_level 을 이 값으로 (비우면 그대로). 끝나면 원래 값으로 되돌린다.
TRACE=${TRACE:-}

export CUBRID=$CUBRID_HOME
export CUBRID_DATABASES=$CUBRID/databases
export LD_LIBRARY_PATH=$CUBRID/lib:$CUBRID/cci/lib:${LD_LIBRARY_PATH:-}

mkdir -p "$OUT"
RESULT=$OUT/summary.tsv
[ -s "$RESULT" ] || printf 'workers\tbacklog_tx\tcatchup_s\ttx_per_s\tbusy_pct\tmarker_pct\tmarker_of_busy\tRSS_MB\tVSZ_MB\n' > "$RESULT"

say () { printf "\n[%s]" "$(date +%H:%M:%S)"; printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }

SSHCTL="-o BatchMode=yes -o ControlMaster=auto -o ControlPath=/tmp/ha_bl_ssh.%r@%h:%p -o ControlPersist=15m"
# -n 이 없으면 루프 안의 ssh 가 스크립트 자신의 stdin 을 먹어버린다.
RSH="ssh -n $SSHCTL $SLAVE"
ENV_PREFIX="export CUBRID=$CUBRID_HOME CUBRID_DATABASES=$CUBRID_HOME/databases LD_LIBRARY_PATH=$CUBRID_HOME/lib:$CUBRID_HOME/cci/lib PATH=$CUBRID_HOME/bin:\$PATH;"
rcub () { $RSH "$ENV_PREFIX $*"; }

# rcub 는 "$*" 로 넘기므로 중첩 큰따옴표가 살아남지 않는다. SQL 은 홑따옴표로 싼다.
commits () {
  rcub "csql -u dba -C -t -N -c 'SELECT commit_counter FROM db_ha_apply_info;' testdb 2>/dev/null" \
    | grep -oE '[0-9]+' | tail -1
}

apply_pid () { $RSH 'pgrep -f "cub_admin applylogdb"' 2>/dev/null | head -1; }

pct () { awk -v a="$1" -v b="$2" 'BEGIN{ if (b+0==0) print "0.0"; else printf "%.1f", 100*a/b }'; }

# ---------------------------------------------------------------- 한 구성 측정

run_one ()
{
  local n=$1
  local dir=$OUT/w$n
  local rdir=${RDIR_PREFIX:-/tmp/ha_bl}$n
  rm -rf "$dir"; mkdir -p "$dir"

  local build=$BUILD
  if [ "$BUILD_SCALE" = 1 ]; then
    case $n in 1) build=$BUILD ;; 4) build=$(( BUILD * 2 )) ;; *) build=$(( BUILD * 3 )) ;; esac
  fi
  say "워커 $n — 1단계: 백로그 생성 (${build}초)"

  rcub "sed -i 's/^ha_apply_worker_count=.*/ha_apply_worker_count=$n/' $HACONF && grep ha_apply_worker_count $HACONF"
  rcub "timeout 30 cubrid heartbeat applylogdb stop testdb youngjun1 </dev/null >/dev/null 2>&1"
  sleep 5
  if [ -n "$(apply_pid)" ]; then
    echo "  경고: applylogdb 가 아직 살아 있습니다. 건너뜁니다." >&2
    return 1
  fi
  echo "  applylogdb 정지 — copylogdb 는 계속 수집 중"

  local c0; c0=$(commits)
  if ! [[ "$c0" =~ ^[0-9]+$ ]]; then
    echo "  commit_counter 를 읽지 못했습니다 (받은 값: '$c0') — 중단" >&2; return 1
  fi
  echo "  정지 시점 commit_counter = $c0"

  # PERF_MASTER=1: 부하를 거는 동안 마스터(로컬) cub_server 를 perf 로 본다 — 마스터 쪽 DML 비용 (RK 검사 등)
  local mperf=""
  if [ "${PERF_MASTER:-0}" = 1 ]; then
    local mpid; mpid=$(pgrep -f "cub_serve[r] testdb" | head -1)
    if [ -n "$mpid" ]; then
      nohup perf record -F ${PERF_FREQ_SRV:-499} -g -p "$mpid" -o "$dir/perf_master.data" </dev/null > "$dir/perf_master.log" 2>&1 &
      mperf=$!
      echo "  마스터 cub_server(pid=$mpid) perf 기동"
    fi
  fi
  ( cd "$SELF" && CUBRID_HOME=$CUBRID_HOME ./ha_load.sh "$SCEN" "$build" ) > "$dir/load.log" 2>&1
  if [ -n "$mperf" ]; then kill -INT "$mperf" 2>/dev/null; wait "$mperf" 2>/dev/null; echo "  마스터 perf 종료 — $dir/perf_master.data"; fi
  echo "  부하 종료 — $(grep -iE '트랜잭션|라운드|total|txn' "$dir/load.log" | tail -2 | tr '\n' ' ')"

  echo "  copylogdb 수집 대기 ${SETTLE}초"
  sleep "$SETTLE"

  # ---------------- 2단계: 따라잡기
  say "워커 $n — 2단계: 따라잡기 측정"
  $RSH "rm -f $STOPFLAG; rm -rf $rdir; mkdir -p $rdir"
  rcub "timeout 60 cubrid heartbeat applylogdb start testdb youngjun1 </dev/null >/dev/null 2>&1"

  local pid=""
  for _ in $(seq 1 20); do pid=$(apply_pid); [ -n "$pid" ] && break; sleep 1; done
  [ -n "$pid" ] || { echo "  applylogdb 기동 실패" >&2; return 1; }
  echo "  applylogdb pid=$pid — 따라잡기 시작"

  # 샘플러를 백그라운드로. 끝나는 시점을 모르므로 STOP_FLAG 로 멈춘다.
  local started=1
  case $SAMPLER in
    pstack)
      $RSH "$ENV_PREFIX STOP_FLAG=$STOPFLAG nohup ~/ha_pstack.sh $pid 100000 $APPLY_INTERVAL $rdir \
             </dev/null > $rdir/collect.log 2>&1 &" || started=0 ;;
    eustack)
      $RSH "STOP_FLAG=$STOPFLAG MEM=1 EU_OPTS='-i -s' nohup ~/ha_eustack.sh $pid $APPLY_INTERVAL $rdir sample \
             </dev/null > $rdir/collect.log 2>&1 &" || started=0 ;;
    perf)
      # perf 는 대상을 멈추지 않는다 (on-CPU 샘플링). 따라잡기가 끝나면 SIGINT 로 멈춘다.
      # 주의: 'cd X && nohup cmd ... &' 는 && 묶음 전체가 백그라운드로 가서 ssh 의 출력을 붙잡는다 (11/8 두 번 정지).
      $RSH "nohup perf record -F ${PERF_FREQ:-999} -g -p $pid -o $rdir/perf.data </dev/null > $rdir/perf.log 2>&1 & echo \$! > $rdir/perf.pid" \
        && echo "  perf record 기동 (${PERF_FREQ:-999} Hz)"
      $RSH "nohup bash -c 'while [ ! -f $STOPFLAG ] && kill -0 $pid 2>/dev/null; do grep -E \"VmRSS|VmSize\" /proc/$pid/status >> $rdir/mem.txt; sleep 2; done' </dev/null >/dev/null 2>&1 &" ;;
    none)
      echo "  샘플러 없음 — 처리량만 측정"
      # 메모리만 가볍게 남긴다
      $RSH "nohup bash -c 'while [ ! -f $STOPFLAG ] && kill -0 $pid 2>/dev/null; do grep -E \"VmRSS|VmSize\" /proc/$pid/status >> $rdir/mem.txt; sleep 2; done' </dev/null >/dev/null 2>&1 &" ;;
  esac
  if [ "${PERF_SRV:-0}" = 1 ]; then
    local sspid; sspid=$($RSH 'pgrep -f "cub_serve[r] testdb"' | head -1)
    [ -n "$sspid" ] && $RSH "nohup perf record -F ${PERF_FREQ_SRV:-499} -g -p $sspid -o $rdir/perf_srv.data </dev/null > $rdir/perf_srv.log 2>&1 & echo \$! > $rdir/perf_srv.pid" \
      && echo "  슬레이브 cub_server(pid=$sspid) perf 기동"
  fi
  if [ "$SRV_INTERVAL" != 0 ]; then
    local spid; spid=$($RSH 'pgrep -f "cub_serve[r] testdb"' | head -1)
    if [ -n "$spid" ]; then
      $RSH "STOP_FLAG=$STOPFLAG EU_OPTS='-i' nohup ~/ha_eustack.sh $spid $SRV_INTERVAL $rdir srv \
             </dev/null > $rdir/collect_srv.log 2>&1 &" && echo "  cub_server(pid=$spid) 샘플러 기동 — ${SRV_INTERVAL}초 간격"
    else
      echo "  경고: 슬레이브 cub_server pid 를 못 찾았습니다" >&2
    fi
  fi
  if [ "$SAMPLER" != none ] && [ "$SAMPLER" != perf ]; then
    sleep 3
    local got; got=$($RSH "ls $rdir/sample_*.txt 2>/dev/null | wc -l")
    echo "  샘플러($SAMPLER) 기동 — 3초 후 샘플 ${got}개"
    [ "${got:-0}" -eq 0 ] || [ "$started" = 0 ] && echo "  경고: 샘플러가 샘플을 못 뜨고 있습니다" >&2
  fi

  local t0; t0=$(date +%s)
  local ts=$dir/series.txt; : > "$ts"
  local prev=$c0 quiet=0 cur=$c0
  # 부하가 없어도 배경 트랜잭션이 초당 1건 남짓 들어온다. 따라서
  # "증가가 완전히 멈춤"이 아니라 "최근 창에서 증가율이 바닥"으로 판정한다.
  local capped=0
  local win=()
  while :; do
    sleep "$POLL"
    cur=$(commits); [[ "$cur" =~ ^[0-9]+$ ]] || cur=$prev
    printf '%s %s\n' "$(date +%s)" "$cur" >> "$ts"
    win+=("$cur")
    if [ "${#win[@]}" -gt $(( QUIET_POLLS + 1 )) ]; then win=("${win[@]:1}"); fi
    if [ "${#win[@]}" -eq $(( QUIET_POLLS + 1 )) ] \
       && [ $(( cur - ${win[0]} )) -lt "$TRICKLE" ]; then
      echo "  [$(date +%H:%M:%S)] 최근 ${QUIET_POLLS}폴 증가 $(( cur - ${win[0]} )) tx (< $TRICKLE) — 따라잡기 완료"
      break
    fi
    [ "$cur" != "$prev" ] && printf '  [%s] 적용 %d tx\n' "$(date +%H:%M:%S)" $(( cur - c0 ))
    prev=$cur
    if [ $(( $(date +%s) - t0 )) -ge "$MAX_CATCHUP" ]; then
      echo "  상한 ${MAX_CATCHUP}초 도달 — 따라잡기 미완료"; capped=1; break
    fi
  done
  local t1; t1=$(date +%s)
  echo
  $RSH "touch $STOPFLAG"
  [ "$SAMPLER" = perf ] && $RSH "[ -f $rdir/perf.pid ] && kill -INT \$(cat $rdir/perf.pid) 2>/dev/null; sleep 3; tail -1 $rdir/perf.log"
  [ "${PERF_SRV:-0}" = 1 ] && $RSH "[ -f $rdir/perf_srv.pid ] && kill -INT \$(cat $rdir/perf_srv.pid) 2>/dev/null; sleep 5; tail -1 $rdir/perf_srv.log"
  sleep 3
  # 따라잡기가 끝난 뒤에도 메모리가 다시 줄어드는지 본다 (누수 판정 보조)
  if [ "${POST_MEM_SECS:-0}" -gt 0 ]; then
    echo "  따라잡기 후 ${POST_MEM_SECS}초 동안 RSS 추적"
    $RSH "for i in \$(seq 1 $(( POST_MEM_SECS / 5 ))); do echo \"\$(date +%s) \$(awk '/VmRSS/{print \$2}' /proc/$pid/status) \$(awk '/VmSize/{print \$2}' /proc/$pid/status)\"; sleep 5; done" > "$dir/post_mem.txt" 2>/dev/null
    awk 'NR==1{f=$2} {l=$2} END{printf "  RSS 따라잡기 직후 %d MB → %d초 후 %d MB\n", f/1024, NR*5, l/1024}' "$dir/post_mem.txt"
  fi

  # 측정 창의 양 끝은 따라잡기 시간이 아니다:
  #   앞쪽 — applylogdb 가 붙어서 실제로 적용을 시작하기까지의 지연
  #   뒤쪽 — 이미 다 따라잡고 노는 구간 (완료 판정에 쓴 창)
  # 그래서 백로그의 2% 를 넘긴 시점부터 98% 에 도달한 시점까지만 센다.
  local backlog=$(( cur - c0 ))
  local span; span=$(awk -v c0="$c0" -v bl="$backlog" '
    BEGIN { lo = c0 + bl*0.02; hi = c0 + bl*0.98 }
    $2 >= lo && tb == 0 { tb = $1; cb = $2 }
    $2 >= hi && td == 0 { td = $1; cd = $2 }
    END { if (tb && td && td > tb) printf "%d %d", td - tb, cd - cb; else print "0 0" }
  ' "$ts")
  local elapsed=${span%% *} applied=${span##* }
  if [ "${elapsed:-0}" -lt 1 ]; then
    # 증가 구간이 폴링 분해능보다 짧다 — 전체 창에서 꼬리만 빼고 하한으로 기록
    elapsed=$(( t1 - t0 - QUIET_POLLS * POLL )); [ "$elapsed" -lt 1 ] && elapsed=1
    applied=$backlog
    echo "  주의: 따라잡기가 폴링 분해능보다 짧습니다 — tx/s 는 하한이 아니라 과대치입니다"
  fi
  [ "$capped" = 1 ] && echo "  주의: 상한에 걸려 백로그를 다 못 따라잡았습니다 (하한값으로 해석할 것)"
  local rate; rate=$(awk -v b="$applied" -v e="$elapsed" 'BEGIN{printf "%.1f", b/e}')
  echo "  백로그 $backlog tx (측정구간 $applied tx) / ${elapsed}초 → $rate tx/s"

  # 따라잡기가 끝난 뒤의 샘플은 유휴만 담고 있어 분포를 왜곡한다. 잘라낸다.
  local t_done; t_done=$(awk -v c0="$c0" -v bl="$backlog" \
    'BEGIN{hi=c0+bl*0.98} $2>=hi{print $1; exit}' "$ts")
  if [ -n "$t_done" ]; then
    local nrm; nrm=$($RSH "find $rdir \( -name 'sample_*.txt' -o -name 'srv_*.txt' \) ! -name '*_timing.txt' -newermt @$t_done -print -delete 2>/dev/null | wc -l")
    echo "  따라잡기 완료 이후 샘플 ${nrm:-0}개 제외"
  fi

  # ---------------- 3단계: 스택 집계 (ha_pstack.sh 집계 전용 모드)
  # 집계는 pstack 형식 전용이다. 다른 샘플러는 결과를 내려받아 따로 분석한다.
  if [ "$SAMPLER" = pstack ]; then
    rcub "~/ha_pstack.sh $pid 0 1 $rdir" > "$dir/pstack.txt" 2>&1
    sed -n '/\[2\]/,/\[3\]/p' "$dir/pstack.txt" | head -14
  else
    : > "$dir/pstack.txt"
  fi

  local total idle mk busy
  total=$(grep -oE '스레드-샘플 총계: [0-9]+' "$dir/pstack.txt" | grep -oE '[0-9]+')
  [ -n "$total" ] || total=0
  idle=$(sed -n '/\[2\]/,/\[3\]/p' "$dir/pstack.txt" | awk '/la_task_queue_pop/{print $2; exit}')
  mk=$(sed -n '/\[2\]/,/\[3\]/p' "$dir/pstack.txt" | awk '/la_insert_applied_tx_marker/{print $2; exit}')
  idle=${idle:-0}; mk=${mk:-0}
  busy=$(( total - idle ))

  local rss vsz
  rss=$($RSH "awk '/VmRSS/{print \$2}' $rdir/mem.txt 2>/dev/null" | sort -n | awk 'NR==1{m=$1}{M=$1}END{if(NR)printf "%d-%d", m/1024, M/1024; else print "-"}')
  vsz=$($RSH "awk '/VmSize/{print \$2}' $rdir/mem.txt 2>/dev/null" | sort -n | awk 'NR==1{m=$1}{M=$1}END{if(NR)printf "%d-%d", m/1024, M/1024; else print "-"}')

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$n" "$backlog" "$elapsed" "$rate" "$(pct $busy $total)" "$(pct $mk $total)" "$(pct $mk $busy)" "$rss" "$vsz" \
    >> "$RESULT"

  # 샘플러 없음 모드에선 묶을 샘플이 없어 tar 가 실패 코드를 낸다 — 측정 실패로 보이지 않게 삼킨다.
  $RSH "cd $rdir && tar czf - sample_*.txt srv_*.txt mem.txt *.log 2>/dev/null" > "$dir/stacks.tgz" 2>/dev/null || true
  if [ "$SAMPLER" = perf ]; then
    # 슬레이브에서 바로 요약을 뽑아 온다 (심볼 해석에 슬레이브의 라이브러리가 필요)
    $RSH "cd $rdir && perf report -i perf.data --stdio --no-children --sort sym --percent-limit 0.5 -g none 2>/dev/null | grep -v '^#' | grep -v '^\$' | head -40" > "$dir/perf_all.txt" 2>/dev/null || true
    $RSH "cd $rdir && perf report -i perf.data --stdio --no-children --tid $pid --sort sym --percent-limit 0.5 -g none 2>/dev/null | grep -v '^#' | grep -v '^\$' | head -40" > "$dir/perf_coord.txt" 2>/dev/null || true
    $RSH "cd $rdir && perf report -i perf.data --stdio --no-children --sort tid -g none 2>/dev/null | grep -v '^#' | grep -v '^\$' | head -40" > "$dir/perf_tid.txt" 2>/dev/null || true
    echo "  perf 요약: $dir/perf_{all,coord,tid}.txt (원본 슬레이브 $rdir/perf.data)"
  fi
}

# ---------------------------------------------------------------- 실행

say "백로그 따라잡기 — 시나리오 $SCEN / 부하 ${BUILD}초 / 워커 ${COUNTS[*]}"
echo "슬레이브: $SLAVE   결과: $RESULT   샘플러: $SAMPLER   cub_server 간격: $SRV_INTERVAL"

ORIG_TRACE=$(rcub "awk -F= '/^ha_writeset_trace_level/{print \$2}' $HACONF" | tr -d '[:space:]')
if [ -n "$TRACE" ]; then
  rcub "sed -i 's/^ha_writeset_trace_level=.*/ha_writeset_trace_level=$TRACE/' $HACONF"
  echo "ha_writeset_trace_level: ${ORIG_TRACE:-없음} → $TRACE (측정 후 복구)"
fi

for n in "${COUNTS[@]}"; do
  run_one "$n" || echo "워커 $n 실패"
done

say "원래 설정 복구 (ha_apply_worker_count=10)"
rcub "sed -i 's/^ha_apply_worker_count=.*/ha_apply_worker_count=10/' $HACONF"
if [ -n "$TRACE" ] && [ -n "$ORIG_TRACE" ]; then
  rcub "sed -i 's/^ha_writeset_trace_level=.*/ha_writeset_trace_level=$ORIG_TRACE/' $HACONF"
  echo "ha_writeset_trace_level 복구 → $ORIG_TRACE"
fi
rcub "timeout 30 cubrid heartbeat applylogdb stop testdb youngjun1 </dev/null >/dev/null 2>&1"
sleep 3
rcub "timeout 60 cubrid heartbeat applylogdb start testdb youngjun1 </dev/null >/dev/null 2>&1"
sleep 5
rcub "cubrid heartbeat status" 2>&1 | sed -n '/HA-Process/,/^$/p'

say "결과"
column -t "$RESULT"
echo
echo "원본: $OUT/w<N>/pstack.txt , $OUT/w<N>/stacks.tgz"
