function endthr(){ if(tid=="")return
  if(coord){ if(store)cs="진행정보 저장(apply_info+marker DELETE+commit)"; else if(scan)cs="pending 스캔"; else if(lw)cs="락 대기"; else if(idle)cs="유휴"; else cs="기타(읽기/파싱 등)" }
  if(worker && tq) st++
  tid="" }
function endfile(){ endthr(); if(files>=0 && FNR0){ S[cs]+=st; N[cs]++; T+=st } cs=""; st=0 }
FNR==1 { endfile(); FNR0=1; files++ }
/^TID [0-9]+:/ { endthr(); tid=$2; coord=worker=store=scan=lw=idle=tq=0; top=""; next }
/^#[0-9]+ / { fn=$0; sub(/^#[0-9]+ +0x[0-9a-f]+ /,"",fn); sub(/\(.*/,"",fn); if(top=="")top=fn
  if(fn~/^la_apply_log_file/)coord=1; if(fn~/^la_worker_main|^la_worker_run/)worker=1
  if(fn~/^la_coordinator_commit_apply_info|^la_coordinator_store_apply_info/)store=1
  if(fn~/^la_pending_pop_ready|^la_gate_is_satisfied/)scan=1
  if(fn~/^la_task_queue_pop/)tq=1
  if(top~/lll_lock_wait|pthread_mutex_lock/)lw=1
  if(top~/cond_timedwait/)idle=1 }
END { endfile(); printf "굶은 워커-샘플 총 %d\n", T; for(k in N) printf "  코디네이터 %-44s 샘플 %2d장, 그때 굶은 워커 합 %3d (%.0f%%), 샘플당 %.1f명\n", k, N[k], S[k], (T?100*S[k]/T:0), S[k]/N[k] }
