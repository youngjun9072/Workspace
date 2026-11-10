#!/bin/bash
# Detached queue driver for the WritesetE2E runs. Runs without Claude.
# Launch: setsid nohup bash results/run_e2e_queue.sh > results/e2e-queue.log 2>&1 &
#
# Queue file results/e2e-queue.txt, one run per line:
#   <name> <cfg-name> <mode> [args...]
#   mode exhaustive: args ignored
#   mode simulate:   args = <seconds> <seed> <depth>
# Status prefixes written by this driver: "#RUN <pid> " (started), "#DONE <result> " (finished).
# Lines starting with "#" otherwise are comments. A "#RUN" line whose driver pid is gone is started again.
# Guards: metadir > 300GB or runtime > 24h -> kill own TLC pid, result DISK_STOP_300G / TIME_STOP_24H.
# While cub_server/applylogdb/copylogdb exist, no new run starts (all runs use a 16g heap).
# Each finished run appends one line to results/e2e-summary.txt and deletes its metadir.

DIR=/home/youngjun/Workspace/Obsidian/Github/writeset-tla
Q=$DIR/results/e2e-queue.txt
SUM=$DIR/results/e2e-summary.txt
LOCK=$DIR/results/.e2e-queue.lock
META=/home/youngjun/tools/tlc-meta/e2e
JAVA=/home/youngjun/tools/jdk-17.0.21+9/bin/java
JAR=/home/youngjun/tools/tla2tools.jar
MAXPAR=2
TIME_LIMIT=$((24 * 3600))
DISK_LIMIT_KB=$((300 * 1024 * 1024))

cd $DIR || exit 1
touch $SUM

log() { echo "$(date '+%F %T') $*"; }

ha_running() { ps -eo args | grep -qE '^[^ ]*(cub_server|applylogdb|copylogdb)'; }

# replace the line of run $1 (matched by name in field 1 after any status prefix) with prefix $2
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

cfg_field() { grep -E "^  $2 = " E2E_$1.cfg | sed "s/^  $2 = //"; }
dims() {
  local c=$1
  local t=$(cfg_field $c Txns | tr -cd ',' | wc -c); t=$((t + 1))
  local k=$(cfg_field $c Keys | tr -cd ',' | wc -c); k=$((k + 1))
  echo "Txns=$t Keys=$k Workers=$(cfg_field $c NumWorkers) Cap=$(cfg_field $c KeyLimit) MaxOps=$(cfg_field $c MaxOps) Crash=$(cfg_field $c MaxCrash) Mut=$(cfg_field $c Mut) Hash=$(cfg_field $c HashMode)"
}

run_one() {
  local name=$1 cfg=$2 mode=$3; shift 3
  local out=$DIR/results/out-e2e-$name.txt md=$META/$name
  local start=$(date +%s) result="" stats=""
  rm -rf $md; mkdir -p $md
  echo "START $(date '+%F %T') $name cfg=$cfg mode=$mode $*" > $out
  if [ "$mode" = simulate ]; then
    local secs=$1 seed=$2 depth=$3
    $JAVA -Xmx16g -XX:+UseParallelGC -cp $JAR tlc2.TLC -workers 16 -metadir $md -simulate -depth $depth -seed $seed \
      -config E2E_$cfg.cfg $(grep -q "^SYMMETRY" E2E_$cfg.cfg && echo WritesetE2ESym || echo WritesetE2E) >> $out 2>&1 &
    local limit=$secs
  else
    $JAVA -Xmx16g -XX:+UseParallelGC -cp $JAR tlc2.TLC -workers 16 -metadir $md \
      -config E2E_$cfg.cfg $(grep -q "^SYMMETRY" E2E_$cfg.cfg && echo WritesetE2ESym || echo WritesetE2E) >> $out 2>&1 &
    local limit=$TIME_LIMIT
  fi
  local pid=$!
  local stop=""
  while kill -0 $pid 2>/dev/null; do
    sleep 60
    local now=$(date +%s)
    if [ $((now - start)) -ge $limit ]; then
      stop=$([ "$mode" = simulate ] && echo SIM_TIME_END || echo TIME_STOP_24H); kill $pid; break
    fi
    local kb=$(du -sk $md 2>/dev/null | cut -f1)
    if [ -n "$kb" ] && [ $kb -gt $DISK_LIMIT_KB ]; then stop=DISK_STOP_300G; kill $pid; break; fi
  done
  wait $pid 2>/dev/null
  local end=$(date +%s)
  echo "END $(date '+%F %T') stop=${stop:-none}" >> $out
  local viol=$(grep -oE 'Invariant [A-Za-z0-9_]+ is violated' $out | head -1 | awk '{print $2}')
  if [ -n "$viol" ]; then result="VIOLATION $viol"
  elif grep -q 'Deadlock reached' $out; then result="VIOLATION Deadlock"
  elif grep -q 'No error has been found' $out; then result=OK
  elif [ "$stop" = SIM_TIME_END ]; then result=OK
  elif [ -n "$stop" ]; then result=$stop
  else result=ERROR
  fi
  if [ "$mode" = simulate ]; then
    stats="checked=$(grep -oE 'Progress: [0-9]+ states checked' $out | tail -1 | awk '{print $2}')"
  else
    local last=$(grep -E 'distinct states found' $out | tail -1)
    stats="distinct=$(echo "$last" | grep -oE '[0-9,]+ distinct states found' | awk '{print $1}') queue=$(echo "$last" | grep -oE '[0-9,]+ states left on queue' | awk '{print $1}')"
    local depth=$(grep -oE 'depth of the complete state graph search is [0-9]+' $out | awk '{print $NF}')
    [ -z "$depth" ] && depth=$(grep -oE '^Progress\([0-9]+\)' $out | tail -1 | tr -cd '0-9')
    stats="$stats depth=$depth"
  fi
  local wall=$(( (end - start) / 60 ))
  (
    flock 9
    echo "$(date '+%F %T') $name | $(dims $cfg) | $mode $* | $stats | ${wall}min | $result" >> $SUM
  ) 9> $LOCK
  mark $name "#DONE $(echo $result | tr ' ' '_') "
  rm -rf $md
  log "finished $name: $result"
}

log "driver start pid=$$"
while true; do
  # pending: plain lines, or #RUN lines whose driver is gone
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
  # running = #RUN lines whose worker is alive (also counts workers left by an earlier driver)
  running=0
  for p in $(grep -E '^#RUN ' $Q | awk '{print $2}'); do kill -0 $p 2>/dev/null && running=$((running + 1)); done
  if [ -z "$next" ] && [ $running -eq 0 ]; then log "queue empty, driver exits"; break; fi
  if [ -n "$next" ] && [ $running -lt $MAXPAR ]; then
    if ha_running; then log "HA processes present, waiting"; sleep 300; continue; fi
    set -- $next
    name=$1
    ( run_one "$@" ) &
    mark $name "#RUN $! "
    log "started $next (worker pid $!)"
    sleep 20   # TLC unpacks its standard modules on start; do not start two at the same second
    continue
  fi
  sleep 30
done
