# 워커별(TID 오름차순 = 생성 순서) 상태 비율 + 샘플당 동시 활동 워커 수
function endthr(){ if(tid=="")return
  if(worker){ ids[tid]=1; n[tid]++
    if(tq) idle[tid]++; else if(lw) lk[tid]++; else work[tid]++
    if(!tq) act++; if(!tq && !lw) prod++ }
  tid="" }
function endfile(){ endthr(); if(started){ A+=act; P+=prod; F++; ha[act]++ } act=0; prod=0 }
FNR==1 { endfile(); started=1 }
/^TID [0-9]+:/ { endthr(); tid=$2+0; worker=tq=lw=0; top=""; next }
/^#[0-9]+ / { fn=$0; sub(/^#[0-9]+ +0x[0-9a-f]+ /,"",fn); sub(/\(.*/,"",fn); if(top=="")top=fn
  if(fn~/^la_worker_main|^la_worker_run/)worker=1; if(fn~/^la_task_queue_pop/)tq=1
  if(top~/lll_lock_wait|pthread_mutex_lock/)lw=1 }
END { endfile(); k=0; for(t in ids) o[++k]=t+0; asort(o)
  printf "  워커#  일(서버대기·실행)  락대기   유휴(일감없음)\n"
  for(i=1;i<=k;i++){t=o[i]; printf "  %3d     %5.1f%%        %5.1f%%   %5.1f%%\n", i, 100*work[t]/n[t], 100*lk[t]/n[t], 100*idle[t]/n[t]}
  printf "  샘플 %d장 — 샘플당 활동 워커(일감 있음) 평균 %.1f명, 그중 락 대기 아닌 '실제 일하는' 워커 %.1f명\n", F, A/F, P/F }
