#!/bin/bash
#
# ha_backlog.sh 결과 한 구성(w<N>)을 한 번에 분석한다 — 작업계획서(ha_test_resume.md) 6-1 보완 3 의 체크리스트.
#
#   ./ha_analyze.sh <결과디렉토리/w<N>> [호스트기록디렉토리]
#
# 입력: stacks.tgz (eu-stack 형식 sample_*.txt / srv_*.txt / mem.txt), series.txt
# pstack 형식(어제 이전 측정) 샘플에는 쓰지 말 것 — 프레임 형식이 다르다.
#
set -u
DIR=${1:?결과 디렉토리 (예: /tmp/ha_bl5_stack/w20)}
HOST=${2:-}
A=$(cd "$(dirname "$0")" && pwd)/ha_analysis
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
tar xzf "$DIR/stacks.tgz" -C "$T" 2>/dev/null
na=$(ls "$T"/sample_0*.txt 2>/dev/null | wc -l); ns=$(ls "$T"/srv_0*.txt 2>/dev/null | wc -l)
echo "## $DIR — applylogdb 샘플 $na, cub_server 샘플 $ns"
[ "$na" -gt 0 ] && head -1 "$T"/sample_0001.txt | grep -q '^PID' || { [ "$na" -gt 0 ] && echo "경고: eu-stack 형식이 아닙니다" >&2; }

echo; echo "### 1. 처리량 / 메모리"
grep -h '' "$DIR/../summary.tsv" 2>/dev/null | awk -v w="$(basename "$DIR" | tr -dc 0-9)" 'NR==1||$1==w' | column -t
if [ -f "$T/mem.txt" ]; then
  awk '/VmRSS/{r=$2} /VmSize/{v=$2} END{printf "마지막 RSS %d MB, VSZ %d MB\n", r/1024, v/1024}' "$T/mem.txt"
fi
[ "$na" -eq 0 ] && { echo "(스택 샘플 없음 — 처리량 전용 회차)"; exit 0; }

echo; echo "### 2·4. 워커 상태 / 코디네이터 일 분해"
cat "$T"/sample_0*.txt | awk -f "$A/apply_eu.awk" | sort -k1,1 -s
echo; echo "### 3. 워커별 분포 / 병렬도"
awk -f "$A/perworker.awk" "$T"/sample_0*.txt
echo; echo "### 5. 락 보유자 상관 (코디네이터가 la_sql_compile_mutex 쥔 순간)"
awk -f "$A/holder.awk" "$T"/sample_0*.txt
echo; echo "### 6. 굶음 원인 상관"
awk -f "$A/starvecause.awk" "$T"/sample_0*.txt
echo; echo "### 4-1. 코디네이터가 서버를 기다릴 때 호출 경로"
cat "$T"/sample_0*.txt | awk -f "$A/coordsrv.awk" | sort -rn | head -5 | cut -c1-200
if [ "$ns" -gt 0 ]; then
  echo; echo "### 8. cub_server (요청 처리 스레드, 샘플당 평균)"
  cat "$T"/srv_0*.txt | awk -v N="$ns" -f "$A/srvcls.awk" | sort
fi
if [ -n "$HOST" ] && [ -f "$DIR/series.txt" ]; then
  echo; echo "### 10. 호스트 (측정 창)"
  a=$(head -1 "$DIR/series.txt" | cut -d' ' -f1); b=$(tail -1 "$DIR/series.txt" | cut -d' ' -f1)
  awk -v a="$(date -d @$a +%T)" -v b="$(date -d @$b +%T)" 'NR>2 && $NF>=a && $NF<=b {us+=$13; wa+=$16; c++} END{if(c) printf "CPU user %.1f%%  iowait %.1f%%  (vmstat %d개)\n", us/c, wa/c, c}' "$HOST/vmstat.txt"
fi
echo; echo "### 7. pending 큐 — trace 1 회차의 applylogdb 에러 로그로: python3 ha_analysis/pending_sim.py <log.gz...> (창 시각은 스크립트 안 win 수정)"
