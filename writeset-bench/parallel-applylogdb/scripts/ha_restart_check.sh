#!/bin/bash
#
# 재기동 정합성 — 따라잡기 도중 applylogdb 를 kill -9 로 여러 번 죽였다 살린 뒤, 마스터·슬레이브 데이터가 같은지 비교한다.
#
# 이 브랜치는 재기동 시 "이미 적용한 트랜잭션" 을 marker 테이블로 건너뛴다 (72650ce0d, fe230a932).
# 부하에 'UPDATE ha_t1 SET seq=seq+1' 같은 비멱등 갱신이 섞여 있으므로, 한 트랜잭션이 두 번 적용되거나
# 빠지면 행 값이 달라져 바로 드러난다.
#
#   ./ha_restart_check.sh [부하초=120] [워커=10]
#   SCEN=A KILL_AT="10 30 55" ./ha_restart_check.sh 120 10
#
set -u

DUR=${1:-120}
N=${2:-10}
SCEN=${SCEN:-A}
KILL_AT=${KILL_AT:-"10 30 55"}      # applylogdb 를 띄운 뒤 몇 초째에 죽일지 (누적 기준 아님, 각 재기동 시점부터)
SLAVE=${SLAVE:-youngjun2}
CUBRID_HOME=${CUBRID_HOME:-/home/youngjun/CUBRID_optdebug}   # 다른 설치본(예: RK 브랜치 /home/youngjun/CUBRID_26246)은 환경변수로
HACONF=$CUBRID_HOME/conf/cubrid_ha.conf
SELF=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$SELF/../results/ha_restart}
mkdir -p "$OUT"

export CUBRID=$CUBRID_HOME CUBRID_DATABASES=$CUBRID_HOME/databases
export LD_LIBRARY_PATH=$CUBRID/lib:$CUBRID/cci/lib:${LD_LIBRARY_PATH:-}
CSQL=$CUBRID/bin/csql
SSHCTL="-o BatchMode=yes -o ControlMaster=auto -o ControlPath=/tmp/ha_rc_ssh.%r@%h:%p -o ControlPersist=15m"
RSH="ssh -n $SSHCTL $SLAVE"
ENV_PREFIX="export CUBRID=$CUBRID_HOME CUBRID_DATABASES=$CUBRID_HOME/databases LD_LIBRARY_PATH=$CUBRID_HOME/lib:$CUBRID_HOME/cci/lib PATH=$CUBRID_HOME/bin:\$PATH;"
rcub () { $RSH "$ENV_PREFIX $*"; }
say () { printf '\n[%s] \033[1m=== %s ===\033[0m\n' "$(date +%H:%M:%S)" "$*"; }

commits () { rcub "csql -u dba -C -t -N -c 'SELECT commit_counter FROM db_ha_apply_info;' testdb 2>/dev/null" | grep -oE '[0-9]+' | tail -1; }
fails ()   { rcub "csql -u dba -C -t -N -c 'SELECT fail_counter FROM db_ha_apply_info;' testdb 2>/dev/null" | grep -oE '[0-9]+' | tail -1; }
apply_pid () { $RSH 'pgrep -f "cub_admin applylogd[b]"' 2>/dev/null | head -1; }

Q1="SELECT id, sess, seq, pad, upd_at FROM ha_t1 ORDER BY id;"
Q2="SELECT id, ref_id, val, pad FROM ha_t2 ORDER BY id;"

# 양쪽을 같은 형식으로 덤프한다. 슬레이브 덤프는 내려받아 줄 단위로 비교할 수 있게 둔다.
dump_both () {
  local tag=$1
  ( cd /tmp && $CSQL -u dba -C -t -N -c "$Q1" testdb 2>/dev/null ) > "$OUT/${tag}_master_t1.txt"
  ( cd /tmp && $CSQL -u dba -C -t -N -c "$Q2" testdb 2>/dev/null ) > "$OUT/${tag}_master_t2.txt"
  rcub "cd /tmp && csql -u dba -C -t -N -c '$Q1' testdb 2>/dev/null" > "$OUT/${tag}_slave_t1.txt"
  rcub "cd /tmp && csql -u dba -C -t -N -c '$Q2' testdb 2>/dev/null" > "$OUT/${tag}_slave_t2.txt"
  local t ok=0
  for t in t1 t2; do
    local m="$OUT/${tag}_master_$t.txt" s="$OUT/${tag}_slave_$t.txt"
    local mc sc; mc=$(grep -c . "$m"); sc=$(grep -c . "$s")
    if cmp -s "$m" "$s"; then
      echo "  [$tag] ha_$t: 일치 (행 $mc)"
    else
      ok=1
      local nd; nd=$(diff "$m" "$s" | grep -c '^[<>]')
      echo "  [$tag] ha_$t: **불일치** (마스터 $mc 행, 슬레이브 $sc 행, 다른 줄 $nd) — 예시:"
      diff "$m" "$s" | grep '^[<>]' | head -6 | sed 's/^/      /'
    fi
  done
  return $ok
}

# 슬레이브가 마스터를 다 따라잡을 때까지 (commit_counter 증가가 바닥)
wait_caught_up () {
  local prev cur same=0
  prev=$(commits)
  for _ in $(seq 1 600); do
    sleep 2; cur=$(commits)
    if [[ "$cur" =~ ^[0-9]+$ ]] && [[ "$prev" =~ ^[0-9]+$ ]] && [ $(( cur - prev )) -lt 5 ]; then
      same=$((same + 1)); [ "$same" -ge 5 ] && return 0
    else same=0; fi
    prev=$cur
  done
  return 1
}

ORIG_TRACE=$(rcub "awk -F= '/^ha_writeset_trace_level/{print \$2}' $HACONF" | tr -d '[:space:]')
rcub "sed -i 's/^ha_writeset_trace_level=.*/ha_writeset_trace_level=0/; s/^ha_apply_worker_count=.*/ha_apply_worker_count=$N/' $HACONF"
say "재기동 정합성 — 시나리오 $SCEN / 부하 ${DUR}초 / 워커 $N / 강제 종료 시점 [$KILL_AT]초"

# 0. 기준: 측정 전에 이미 같은가 (부하가 없는 상태에서)
rcub "timeout 30 cubrid heartbeat applylogdb stop testdb youngjun1 </dev/null >/dev/null 2>&1"; sleep 3
rcub "timeout 60 cubrid heartbeat applylogdb start testdb youngjun1 </dev/null >/dev/null 2>&1"; sleep 10
wait_caught_up
say "0단계 — 측정 전 기준 비교"
dump_both before; BEFORE=$?
F0=$(fails); echo "  fail_counter = ${F0:-?}"

# 1. 백로그 생성
say "1단계 — applylogdb 정지, 부하 ${DUR}초로 백로그 생성"
rcub "timeout 30 cubrid heartbeat applylogdb stop testdb youngjun1 </dev/null >/dev/null 2>&1"; sleep 5
[ -n "$(apply_pid)" ] && { echo "applylogdb 가 안 멈췄습니다 — 중단" >&2; exit 1; }
C0=$(commits); echo "  정지 시점 commit_counter = $C0"
( cd "$SELF" && CUBRID_HOME=$CUBRID_HOME ./ha_load.sh "$SCEN" "$DUR" ) > "$OUT/load.log" 2>&1
echo "  부하 종료 — $(grep -oE '총 라운드 [0-9]+.*' "$OUT/load.log" | tail -1)"
sleep 25

# 2. 따라잡기 도중 강제 종료 반복
say "2단계 — 따라잡기 시작, 도중에 kill -9"
rcub "timeout 60 cubrid heartbeat applylogdb start testdb youngjun1 </dev/null >/dev/null 2>&1"
k=0
for at in $KILL_AT; do
  pid=""; for _ in $(seq 1 30); do pid=$(apply_pid); [ -n "$pid" ] && break; sleep 1; done
  [ -n "$pid" ] || { echo "  applylogdb 가 없습니다 — 직접 기동"; rcub "timeout 60 cubrid heartbeat applylogdb start testdb youngjun1 </dev/null >/dev/null 2>&1"; sleep 5; pid=$(apply_pid); }
  sleep "$at"
  k=$((k + 1))
  cb=$(commits)
  $RSH "kill -9 $pid </dev/null >/dev/null 2>&1"
  echo "  [$(date +%H:%M:%S)] #$k kill -9 pid=$pid (기동 후 ${at}초, 적용 $((cb - C0)) tx 시점)"
  # heartbeat 가 다시 띄우는지 본다 (최대 30초), 아니면 직접 띄운다
  np=""; for _ in $(seq 1 30); do sleep 1; np=$(apply_pid); [ -n "$np" ] && [ "$np" != "$pid" ] && break; np=""; done
  if [ -n "$np" ]; then echo "      heartbeat 가 재기동 (pid=$np)"
  else echo "      heartbeat 가 재기동하지 않음 — 직접 기동"; rcub "timeout 60 cubrid heartbeat applylogdb start testdb youngjun1 </dev/null >/dev/null 2>&1"; fi
done

say "3단계 — 끝까지 따라잡기 대기"
wait_caught_up && echo "  따라잡기 완료 (적용 $(( $(commits) - C0 )) tx)" || echo "  경고: 20분 안에 따라잡기가 끝나지 않음"
sleep 5

say "4단계 — 마스터·슬레이브 비교"
dump_both after; AFTER=$?
F1=$(fails); echo "  fail_counter = ${F0:-?} → ${F1:-?}"
rcub "grep -c 'ERROR' $CUBRID_HOME/log/testdb@localhost_applylogdb_testdb_youngjun1.err 2>/dev/null" | sed 's/^/  applylogdb 에러 로그 ERROR 줄 수(파일 전체): /'

# 복구
rcub "sed -i 's/^ha_apply_worker_count=.*/ha_apply_worker_count=10/; s/^ha_writeset_trace_level=.*/ha_writeset_trace_level=${ORIG_TRACE:-1}/' $HACONF"
rcub "timeout 30 cubrid heartbeat applylogdb stop testdb youngjun1 </dev/null >/dev/null 2>&1"; sleep 3
rcub "timeout 60 cubrid heartbeat applylogdb start testdb youngjun1 </dev/null >/dev/null 2>&1"

say "결과"
echo "  측정 전 기준: $([ $BEFORE = 0 ] && echo 일치 || echo 불일치)   강제 종료 ${k}회 후: $([ $AFTER = 0 ] && echo 일치 || echo '**불일치**')"
echo "끝 $(date +%T)"
