#!/bin/bash
#
# A/B 시나리오를 끝까지 수행하고 결과를 비교한다.
#
# 마스터에서 부하를 돌리는 동안 슬레이브의 applylogdb 를 pstack 으로
# 샘플링한다. 둘이 동시에 돌아야 의미가 있으므로 한 스크립트에서 묶는다.
#
#   ./ha_run_all.sh [지속초] [샘플수] [샘플간격] [시나리오...]
#
# 기본: A 와 B 를 각각 120초, 50샘플 x 2초
# 한 시나리오만 다시 돌리려면:  ./ha_run_all.sh 120 50 2 B
#

set -u

DUR=${1:-120}
SAMPLES=${2:-50}
INTERVAL=${3:-2}
shift 3 2>/dev/null || true
SCENARIOS=("${@:-A B}")
[ $# -gt 0 ] && SCENARIOS=("$@")

SLAVE=${SLAVE:-youngjun2}
CUBRID_HOME=${CUBRID_HOME:-/home/youngjun/CUBRID_optdebug}
SELF=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-/tmp/ha_result}

export CUBRID=$CUBRID_HOME
export CUBRID_DATABASES=$CUBRID/databases
export LD_LIBRARY_PATH=$CUBRID/lib:$CUBRID/cci/lib:${LD_LIBRARY_PATH:-}
CSQL=$CUBRID/bin/csql

mkdir -p "$OUT"

say () { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }

# ---------------------------------------------------------------- 사전 점검

say "사전 점검"

"$CUBRID/bin/cubrid" heartbeat status 2>&1 | sed -n '3,12p'

SLAVE_PID=$(ssh -o BatchMode=yes "$SLAVE" 'pgrep -f "cub_admin applylogdb"' 2>/dev/null | head -1)
if [ -z "$SLAVE_PID" ]; then
  echo "슬레이브 applylogdb 를 찾지 못했습니다. HA 가 떠 있는지 확인하세요." >&2
  exit 1
fi
echo "슬레이브 applylogdb pid = $SLAVE_PID ($SLAVE)"

before_t1=$("$CSQL" -u dba -C -c "SELECT COUNT(*) FROM ha_t1;" testdb 2>/dev/null | grep -E '^ +[0-9]+ *$' | tail -1 | tr -d ' ')
echo "시작 시점 ha_t1 = ${before_t1:-?} 행"

# ---------------------------------------------------------------- 시나리오 실행

run_scenario ()
{
  local scen=$1

  say "시나리오 $scen — 부하 ${DUR}초 / 샘플 ${SAMPLES}회 x ${INTERVAL}초"

  # 부하를 백그라운드로 띄우고, 바로 슬레이브 샘플링을 시작한다.
  ( cd "$SELF" && CUBRID_HOME=$CUBRID_HOME ./ha_load.sh "$scen" "$DUR" ) \
      > "$OUT/load_$scen.log" 2>&1 &
  local load_pid=$!

  sleep 5   # 워커가 실제로 일을 받기 시작할 때까지 대기

  ssh -o BatchMode=yes "$SLAVE" \
      "~/ha_pstack.sh $SLAVE_PID $SAMPLES $INTERVAL /tmp/scen$scen" \
      > "$OUT/pstack_$scen.txt" 2>&1

  wait "$load_pid" 2>/dev/null
  echo "부하 종료. 요약:"
  tail -3 "$OUT/load_$scen.log"

  if grep -qiE "error" /tmp/ha_load/${scen}_s*.log 2>/dev/null; then
    echo "경고: 세션 로그에 에러가 있습니다"
    grep -ihE "error" /tmp/ha_load/${scen}_s*.log | sort | uniq -c | head -5
  fi
}

first=1
for s in "${SCENARIOS[@]}"; do
  [ $first -eq 1 ] || { say "다음 시나리오 전 복제 소강 대기 (20초)"; sleep 20; }
  first=0
  run_scenario "$s"
done

# ---------------------------------------------------------------- 결과

for s in "${SCENARIOS[@]}"; do
  say "시나리오 $s 결과"
  cat "$OUT/pstack_$s.txt"
done

say "복제 정합성 확인"
for host in local "$SLAVE"; do
  if [ "$host" = local ]; then
    cnt=$("$CSQL" -u dba -C -c "SELECT COUNT(*) FROM ha_t2;" testdb 2>/dev/null | grep -E '^ +[0-9]+ *$' | tail -1 | tr -d ' ')
    printf "  %-12s ha_t2 = %s\n" "youngjun1" "${cnt:-?}"
  else
    cnt=$(ssh -o BatchMode=yes "$host" "bash -lc '$CSQL -u dba -C -c \"SELECT COUNT(*) FROM ha_t2;\" testdb 2>/dev/null'" \
          | grep -E '^ +[0-9]+ *$' | tail -1 | tr -d ' ')
    printf "  %-12s ha_t2 = %s\n" "$host" "${cnt:-?}"
  fi
done
echo "  (복제 지연이 남아 있으면 슬레이브 쪽이 작을 수 있습니다)"

say "원본 위치"
echo "  집계   : $OUT/pstack_A.txt , $OUT/pstack_B.txt"
echo "  부하로그: $OUT/load_A.log , $OUT/load_B.log"
echo "  스택원본: $SLAVE:/tmp/scenA/ , $SLAVE:/tmp/scenB/"
