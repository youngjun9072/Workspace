#!/bin/bash
# Short direct run of one BND config (exhaustive, or simulate with: bnd_run.sh name sim <secs> <seed> <depth>).
# Writes results/out-bnd-<name>.txt and one line to results/bnd-summary.txt; deletes its metadir.
# Guards: per-run metadir 50GB, total tlc-meta 100GB, time limit (default 1800s, BND_LIMIT overrides).
DIR=/home/youngjun/Workspace/Obsidian/Github/writeset-tla
META=/home/youngjun/tools/tlc-meta
JAVA=/home/youngjun/tools/jdk-17.0.21+9/bin/java
JAR=/home/youngjun/tools/tla2tools.jar
cd $DIR || exit 1
name=$1; mode=${2:-exh}
cfg=BND_$name.cfg; out=results/out-bnd-$name.txt; md=$META/bnd/$name
limit=${BND_LIMIT:-1800}
rm -rf $md; mkdir -p $md
start=$(date +%s)
echo "START $(date '+%F %T') $name mode=$mode $3 $4 $5" > $out
if [ "$mode" = sim ]; then
  limit=$3
  $JAVA -Xmx16g -XX:+UseParallelGC -cp $JAR tlc2.TLC -workers 16 -metadir $md -simulate -depth $5 -seed $4 -config $cfg WritesetBoundary >> $out 2>&1 &
else
  $JAVA -Xmx16g -XX:+UseParallelGC -cp $JAR tlc2.TLC -workers 16 -metadir $md -config $cfg WritesetBoundary >> $out 2>&1 &
fi
pid=$!; stop=""; maxkb=0
while kill -0 $pid 2>/dev/null; do
  sleep 5
  now=$(date +%s)
  kb=$(du -sk $md 2>/dev/null | cut -f1); [ -n "$kb" ] && [ $kb -gt $maxkb ] && maxkb=$kb
  tot=$(du -sk $META 2>/dev/null | cut -f1)
  if [ $((now - start)) -ge $limit ]; then stop=$([ "$mode" = sim ] && echo SIM_TIME_END || echo TIME_STOP); kill $pid; break; fi
  if [ -n "$kb" ] && [ $kb -gt $((50*1024*1024)) ]; then stop=DISK_STOP; kill $pid; break; fi
  if [ -n "$tot" ] && [ $tot -gt $((100*1024*1024)) ]; then stop=DISK_STOP_TOTAL; kill $pid; break; fi
done
wait $pid 2>/dev/null
end=$(date +%s)
echo "END $(date '+%F %T') stop=${stop:-none} maxmeta_kb=$maxkb" >> $out
viol=$(grep -oE 'Invariant [A-Za-z0-9_]+ is violated' $out | head -1 | awk '{print $2}')
if [ -n "$viol" ]; then result="VIOLATION $viol"
elif grep -q 'Deadlock reached' $out; then result="VIOLATION Deadlock"
elif grep -q 'No error has been found' $out; then result=OK
elif [ "$stop" = SIM_TIME_END ]; then result=OK_SIM
elif [ -n "$stop" ]; then result=$stop
else result=ERROR; fi
if [ "$mode" = sim ]; then
  stats="checked=$(grep -oE '[0-9,]+ states checked' $out | tail -1 | awk '{print $1}') seed=$4 depth=$5"
else
  last=$(grep -E 'distinct states found' $out | tail -1)
  stats="distinct=$(echo "$last" | grep -oE '[0-9,]+ distinct states found' | awk '{print $1}') depth=$(grep -oE 'depth of the complete state graph search is [0-9]+' $out | awk '{print $NF}')"
fi
args=$(head -1 $cfg | sed 's/.*bnd_mkcfg.py: //')
echo "$(date '+%F %T') $name | $args | $mode | $stats | $((end-start))s | meta $((maxkb/1024))MB | $result" >> results/bnd-summary.txt
rm -rf $md
echo "$name: $result ($stats, $((end-start))s)"
