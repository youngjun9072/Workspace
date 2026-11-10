#!/bin/bash
# Detached, resumable queue driver for the WritesetBoundary runs.
# Launch: setsid nohup bash results/run_bnd_queue.sh >> results/bnd-queue.log 2>&1 < /dev/null &
#
# Queue file results/bnd-queue.txt, one run per line:
#   <name> exh                       exhaustive run of BND_<name>.cfg
#   <name> sim <secs> <seed> <depth> simulation of BND_<name>.cfg
# Status prefixes written here: "#RUN <pid> " (started), "#DONE <result> " (finished). Other "#" lines are
# comments. A "#RUN" line whose worker pid is gone is started again.
# Parallelism: results/bnd-maxpar (default 1) TLC runs at once from this driver (the session may run one more
# short run directly; never more than 2 TLC processes in total).
# Guards: per-run metadir > 50GB, or all of /home/youngjun/tools/tlc-meta > 100GB -> stop the LARGEST running
# run by its pid (DISK_STOP, last progress line recorded, its metadir deleted); runtime > 12h -> TIME_STOP_12H.
# While cub_server/applylogdb/copylogdb processes exist, no new run starts.
# Each finished run appends one line to results/bnd-summary.txt and deletes its metadir.

DIR=/home/youngjun/Workspace/Obsidian/Github/writeset-tla
Q=$DIR/results/bnd-queue.txt
SUM=$DIR/results/bnd-summary.txt
LOCK=$DIR/results/.bnd-queue.lock
METAROOT=/home/youngjun/tools/tlc-meta
META=$METAROOT/bnd
JAVA=/home/youngjun/tools/jdk-17.0.21+9/bin/java
JAR=/home/youngjun/tools/tla2tools.jar
TIME_LIMIT=$((12 * 3600))
RUN_LIMIT_KB=$((50 * 1024 * 1024))
TOTAL_LIMIT_KB=$((100 * 1024 * 1024))

cd $DIR || exit 1
touch $SUM
log() { echo "$(date '+%F %T') $*"; }
ha_running() { ps -eo args | grep -qE '^[^ ]*(cub_server|applylogdb|copylogdb)'; }
maxpar() { local m=$(cat $DIR/results/bnd-maxpar 2>/dev/null); echo ${m:-1}; }

mark() {
  local name=$1 prefix=$2
  (
    flock 9
    awk -v n="$name" -v p="$prefix" '
      { line=$0; core=line
        sub(/^#RUN [0-9]+ /, "", core); sub(/^#DONE [^ ]+ /, "", core)
        split(core, f, " ")
        if (f[1] == n && line !~ /^#DONE/) print p core; else print line }' $Q > $Q.tmp && cat $Q.tmp > $Q && rm -f $Q.tmp
  ) 9> $LOCK
}

run_one() {
  local name=$1 mode=$2; shift 2
  local out=$DIR/results/out-bnd-$name.txt md=$META/$name cfg=BND_$name.cfg
  local start=$(date +%s) result="" stats="" limit=$TIME_LIMIT
  rm -rf $md; mkdir -p $md
  echo "START $(date '+%F %T') $name mode=$mode $*" > $out
  if [ "$mode" = sim ]; then
    limit=$1
    $JAVA -Xmx16g -XX:+UseParallelGC -cp $JAR tlc2.TLC -workers 16 -metadir $md -simulate -depth $3 -seed $2 \
      -config $cfg WritesetBoundary >> $out 2>&1 &
  else
    $JAVA -Xmx16g -XX:+UseParallelGC -cp $JAR tlc2.TLC -workers 16 -metadir $md -config $cfg WritesetBoundary >> $out 2>&1 &
  fi
  local pid=$!
  echo $pid > $md.pid
  local stop="" maxkb=0
  while kill -0 $pid 2>/dev/null; do
    sleep 60
    [ -f $md.stop ] && { stop=$(cat $md.stop); kill $pid; break; }
    local now=$(date +%s)
    if [ $((now - start)) -ge $limit ]; then
      stop=$([ "$mode" = sim ] && echo SIM_TIME_END || echo TIME_STOP_12H); kill $pid; break
    fi
    local kb=$(du -sk $md 2>/dev/null | cut -f1)
    [ -n "$kb" ] && [ $kb -gt $maxkb ] && maxkb=$kb
    if [ -n "$kb" ] && [ $kb -gt $RUN_LIMIT_KB ]; then stop=DISK_STOP_50G; kill $pid; break; fi
  done
  wait $pid 2>/dev/null
  local end=$(date +%s)
  echo "END $(date '+%F %T') stop=${stop:-none} maxmeta_kb=$maxkb" >> $out
  [ -n "$stop" ] && echo "LAST_PROGRESS $(grep -E '^Progress|states checked' $out | tail -1)" >> $out
  local viol=$(grep -oE 'Invariant [A-Za-z0-9_]+ is violated' $out | head -1 | awk '{print $2}')
  if [ -n "$viol" ]; then result="VIOLATION $viol"
  elif grep -q 'Deadlock reached' $out; then result="VIOLATION Deadlock"
  elif grep -q 'No error has been found' $out; then result=OK
  elif [ "$stop" = SIM_TIME_END ]; then result=OK_SIM
  elif [ -n "$stop" ]; then result=$stop
  else result=ERROR; fi
  if [ "$mode" = sim ]; then
    stats="checked=$(grep -oE '[0-9,]+ states checked' $out | tail -1 | awk '{print $1}') seed=$2 depth=$3"
  else
    local last=$(grep -E 'distinct states found' $out | tail -1)
    stats="distinct=$(echo "$last" | grep -oE '[0-9,]+ distinct states found' | awk '{print $1}') queue=$(echo "$last" | grep -oE '[0-9,]+ states left on queue' | awk '{print $1}') depth=$(grep -oE 'depth of the complete state graph search is [0-9]+' $out | awk '{print $NF}')"
  fi
  local args=$(head -1 $cfg | sed 's/.*bnd_mkcfg.py: //')
  (
    flock 9
    echo "$(date '+%F %T') $name | $args | $mode $* | $stats | $((end - start))s | meta $((maxkb / 1024))MB | $result" >> $SUM
  ) 9> $LOCK
  mark $name "#DONE $(echo $result | tr ' ' '_') "
  rm -rf $md $md.pid $md.stop
  log "finished $name: $result"
}

# total-disk guard: stop the largest running run
total_guard() {
  local tot=$(du -sk $METAROOT 2>/dev/null | cut -f1)
  [ -z "$tot" ] && return
  [ $tot -le $TOTAL_LIMIT_KB ] && return
  local big="" bigkb=0
  for p in $META/*.pid; do
    [ -f "$p" ] || continue
    local d=${p%.pid} kb=$(du -sk ${p%.pid} 2>/dev/null | cut -f1)
    [ -n "$kb" ] && [ $kb -gt $bigkb ] && { bigkb=$kb; big=$d; }
  done
  [ -n "$big" ] && { echo DISK_STOP_TOTAL > $big.stop; log "total metadir ${tot}KB > limit, stopping $(basename $big)"; }
}

log "driver start pid=$$"
while true; do
  total_guard
  next=""
  while read -r line; do
    case "$line" in
      "#DONE "*|"") continue ;;
      "#RUN "*)
        p=$(echo "$line" | awk '{print $2}')
        kill -0 $p 2>/dev/null && continue
        next=$(echo "$line" | cut -d' ' -f3-); break ;;
      "#"*) continue ;;
      *) next=$line; break ;;
    esac
  done < $Q
  running=0
  for p in $(grep -E '^#RUN ' $Q | awk '{print $2}'); do kill -0 $p 2>/dev/null && running=$((running + 1)); done
  if [ -z "$next" ] && [ $running -eq 0 ]; then log "queue empty, driver exits"; break; fi
  if [ -n "$next" ] && [ $running -lt $(maxpar) ]; then
    if ha_running; then log "HA processes present, waiting"; sleep 300; continue; fi
    set -- $next
    name=$1
    ( run_one "$@" ) &
    mark $name "#RUN $! "
    log "started $next (worker pid $!)"
    sleep 20
    continue
  fi
  sleep 30
done
