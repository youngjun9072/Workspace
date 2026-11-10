#!/bin/bash
# 프로세스별 디스크 I/O 기록 — pidstat 이 없는 노드용.
# 1초마다 cub_* / copylogdb / applylogdb 프로세스의 /proc/<pid>/io 누적값을 남긴다. STOP 파일이 생기면 멈춘다.
#   ./ha_procio.sh <출력파일> <stop파일>
OUT=${1:?out}; STOP=${2:?stop}
while [ ! -f "$STOP" ]; do
  t=$(date +%s)
  for p in $(pgrep -f 'cub_(server|admin|master)'); do
    c=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | awk '{print $1"_"$2}')
    awk -v t=$t -v p=$p -v c="$c" '/^read_bytes/{r=$2} /^write_bytes/{w=$2} END{print t, p, c, r, w}' /proc/$p/io 2>/dev/null
  done
  sleep 1
done >> "$OUT"
