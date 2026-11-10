#!/bin/bash
#
# eu-stack 반복 샘플러 — pstack 보다 대상 정지 시간이 훨씬 짧다.
#
# pstack(gdb) 은 덤프하는 동안 대상의 모든 스레드를 멈춘다 (state 't').
# 2026-11-07 실측: applylogdb 1.3~1.9초, cub_server(151 스레드) 약 6초.
# 1초 간격으로 뜨면 대상이 측정 시간의 절반 가까이 멈춰 있게 된다.
# eu-stack 은 applylogdb 약 60~85ms, cub_server 약 0.8초(-s 없이).
#
#   ./ha_eustack.sh <pid> <간격초> <출력디렉토리> [파일접두어]
#
# 환경변수:
#   STOP_FLAG  이 파일이 생기면 멈춘다
#   EU_OPTS    eu-stack 옵션 (기본 -i : 인라인 프레임 표시. -s 를 더하면 소스 줄까지, 대신 느려짐)
#   MEM=1      매 샘플마다 /proc/<pid>/status 의 VmRSS/VmSize 를 mem.txt 에 남긴다
#
# 출력: <접두어>_NNNN.txt (샘플), <접두어>_timing.txt (시각, 소요 ms — 대상 정지 시간의 상한)
#

PID=${1:?pid}
INTERVAL=${2:-1}
OUT=${3:?outdir}
PFX=${4:-sample}
OPTS=${EU_OPTS:--i}

mkdir -p "$OUT"
i=0
while kill -0 "$PID" 2>/dev/null; do
  [ -n "${STOP_FLAG:-}" ] && [ -f "$STOP_FLAG" ] && break
  i=$((i + 1))
  f=$(printf '%s/%s_%04d.txt' "$OUT" "$PFX" "$i")
  s=$(date +%s%N)
  eu-stack $OPTS -p "$PID" > "$f" 2>/dev/null
  e=$(date +%s%N)
  echo "$(date +%s) $(( (e - s) / 1000000 ))" >> "$OUT/${PFX}_timing.txt"
  [ -n "${MEM:-}" ] && grep -E 'VmRSS|VmSize' "/proc/$PID/status" >> "$OUT/mem.txt" 2>/dev/null
  sleep "$INTERVAL"
done
echo "샘플 ${i}개 — $OUT/${PFX}_*.txt"
