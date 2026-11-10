#!/bin/bash
#
# pstack 반복 샘플러 + 집계 — applylogdb 워커가 실제로 뭘 하고 있는지 본다.
#
# 한 번 뜬 스택은 일화일 뿐이라, 수십 번 떠서 분포를 봐야 의미가 생긴다.
# 사실상 수동 샘플링 프로파일러.
#
#   ./ha_pstack.sh <pid|패턴> [샘플수] [간격초] [출력디렉토리]
#
#   ./ha_pstack.sh applylogdb 40 1
#   ./ha_pstack.sh 2045230 60 0.5 /tmp/scenA
#
# 집계 3 종:
#   [1] 최상위 프레임     — 스레드가 무엇에 '막혀' 있나 (cond_wait / futex / epoll ...)
#   [2] 최초 작업 프레임  — 대기 primitive 를 걷어낸 뒤 '무슨 일로' 막혀 있나
#   [3] 스택 시그니처     — 상위 3 프레임 조합별 빈도
#
# STACK_TOOL=eu-stack 으로 바꾸면 더 가볍게 뜬다 (대상 정지 시간이 짧다).
#

set -u

TARGET=${1:-}
COUNT=${2:-40}
INTERVAL=${3:-1}
OUTDIR=${4:-/tmp/ha_pstack.$(id -u)}

STACK_TOOL=${STACK_TOOL:-pstack}

[ -n "$TARGET" ] || { sed -n '2,22p' "$0"; exit 1; }

# ---- 대상 PID 해석 --------------------------------------------------------

if [[ "$TARGET" =~ ^[0-9]+$ ]]; then
  PID=$TARGET
else
  # pgrep -f 는 자기 자신(이 스크립트, 감싼 셸, pgrep)도 잡으므로 걷어낸다.
  self=$(basename "$0")
  mapfile -t cands < <(
    pgrep -f "$TARGET" | while read -r p; do
      [ "$p" = "$$" ] && continue
      [ "$p" = "$PPID" ] && continue
      cl=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null) || continue
      case "$cl" in *"$self"*) continue ;; esac
      echo "$p"
    done
  )
  case ${#cands[@]} in
    0) echo "매칭되는 프로세스 없음: $TARGET" >&2
       echo "힌트: applylogdb 는 'cub_admin applylogdb ...' 로 뜨므로 pgrep -f 가 필요합니다." >&2
       exit 1 ;;
    1) PID=${cands[0]} ;;
    *) echo "여러 개 매칭됨 — PID 를 직접 지정하세요:" >&2
       for p in "${cands[@]}"; do echo "  $p  $(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | cut -c1-120)" >&2; done
       exit 1 ;;
  esac
fi

kill -0 "$PID" 2>/dev/null || { echo "PID $PID 이 없습니다" >&2; exit 1; }

CMD=$(tr '\0' ' ' < /proc/$PID/cmdline 2>/dev/null | cut -c1-140)
NTHREAD=$(ls /proc/$PID/task 2>/dev/null | wc -l)

mkdir -p "$OUTDIR"
# COUNT=0 은 "이미 모아둔 샘플만 집계" 모드다. 기존 샘플을 지우면 안 된다.
[ "$COUNT" -gt 0 ] && rm -f "$OUTDIR"/sample_*.txt

echo "대상 : $PID  ($NTHREAD threads)"
echo "       $CMD"
echo "도구 : $STACK_TOOL"
echo "수집 : ${COUNT}회 x ${INTERVAL}초 간격  ->  $OUTDIR"
echo

# ---- 수집 -----------------------------------------------------------------

taken=0
if [ "$COUNT" -eq 0 ]; then
  # 집계 전용 모드 — 다른 쪽에서 모아둔 샘플을 읽기만 한다.
  taken=$(ls "$OUTDIR"/sample_*.txt 2>/dev/null | wc -l)
  echo "집계 전용 모드 — 기존 샘플 ${taken}개"
  echo
else
  for (( i = 1; i <= COUNT; i++ )); do
    # STOP_FLAG 파일이 생기면 남은 횟수와 무관하게 멈춘다.
    # 따라잡기처럼 '언제 끝날지 모르는' 구간을 샘플링할 때 쓴다.
    if [ -n "${STOP_FLAG:-}" ] && [ -f "$STOP_FLAG" ]; then
      echo; echo "중지 플래그 감지 — ${taken}개 수집하고 중단"
      break
    fi
    kill -0 "$PID" 2>/dev/null || { echo; echo "PID $PID 종료됨 — ${taken}개 수집하고 중단"; break; }
    if "$STACK_TOOL" "$PID" > "$OUTDIR/sample_$(printf '%03d' "$i").txt" 2>/dev/null; then
      taken=$(( taken + 1 ))
    fi
    [ -t 1 ] && printf '\r수집 %d/%d' "$i" "$COUNT"
    # 메모리도 같이 남긴다 (RSS/VSZ 추이 확인용)
    grep -E 'VmRSS|VmSize' "/proc/$PID/status" >> "$OUTDIR/mem.txt" 2>/dev/null
    sleep "$INTERVAL"
  done
  printf '\r수집 완료 %d개          \n\n' "$taken"
fi

[ "$taken" -gt 0 ] || { echo "수집 실패 — 권한(ptrace) 또는 도구를 확인하세요" >&2; exit 1; }

# ---- 집계 -----------------------------------------------------------------

cat "$OUTDIR"/sample_*.txt | awk '
  # 대기 primitive — 여기 걸린 건 "막혀 있다"는 뜻이지 "무슨 일"인지는 아니다.
  function is_wait (f) {
    return f ~ /^(pthread_cond_(timed)?wait|pthread_mutex_(timed)?lock|pthread_join|__lll_lock_wait|futex|do_futex_wait|__futex|sem_wait|sem_timedwait|epoll_wait|epoll_pwait|poll|__poll|ppoll|select|nanosleep|clock_nanosleep|usleep|sleep|read|__read|recv|recvfrom|recvmsg|__libc_read|accept|accept4|write|__write|send|sendto|fsync|fdatasync|msync|syscall)/
  }
  function flush_thread (   k, f) {
    if (nf == 0) return
    threads++
    top[fr[0]]++
    # 대기 primitive 를 걷어낸 첫 프레임 = 실제로 하던 일
    for (k = 0; k < nf; k++) if (!is_wait(fr[k])) { work[fr[k]]++; break }
    if (k == nf) work["(all-wait)"]++
    f = fr[0]
    if (nf > 1) f = f " <- " fr[1]
    if (nf > 2) f = f " <- " fr[2]
    sig[f]++
    nf = 0
  }
  /^Thread |^TID |^PID /          { flush_thread(); next }
  /^#[0-9]+/ {
    fn = "?"
    if (match($0, / in [^ (]+/))   fn = substr($0, RSTART + 4, RLENGTH - 4)
    else if (match($0, /#[0-9]+ +0x[0-9a-f]+ +[^ (]+/)) {
      split(substr($0, RSTART, RLENGTH), a, / +/); fn = a[3]
    }
    sub(/@@?GLIBC[^ ]*/, "", fn)
    fr[nf++] = fn
    next
  }
  END {
    flush_thread()
    if (threads == 0) { print "파싱된 스레드 없음 — 출력 형식을 확인하세요"; exit }

    printf "스레드-샘플 총계: %d\n\n", threads

    print "[1] 최상위 프레임 — 무엇에 막혀 있나"
    n = asorti(top, idx, "@val_num_desc")
    for (i = 1; i <= n && i <= 12; i++)
      printf "    %6.2f%%  %6d  %s\n", 100*top[idx[i]]/threads, top[idx[i]], idx[i]

    print "\n[2] 최초 작업 프레임 — 무슨 일로 막혀 있나"
    n = asorti(work, idx2, "@val_num_desc")
    for (i = 1; i <= n && i <= 15; i++)
      printf "    %6.2f%%  %6d  %s\n", 100*work[idx2[i]]/threads, work[idx2[i]], idx2[i]

    print "\n[3] 스택 시그니처 (상위 3 프레임)"
    n = asorti(sig, idx3, "@val_num_desc")
    for (i = 1; i <= n && i <= 12; i++)
      printf "    %6.2f%%  %6d  %s\n", 100*sig[idx3[i]]/threads, sig[idx3[i]], idx3[i]
  }
'

echo
echo "원본 샘플: $OUTDIR/sample_*.txt"
echo "특정 샘플 보기:  less $OUTDIR/sample_001.txt"
echo "두 시점 비교  :  diff $OUTDIR/sample_001.txt $OUTDIR/sample_$(printf '%03d' "$taken").txt"
