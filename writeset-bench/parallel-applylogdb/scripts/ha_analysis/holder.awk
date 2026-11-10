# 샘플(파일) 단위: 코디네이터가 la_update_query_execute* 안에서 락을 쥔 채(대기 아님) 있었나 + 그 순간 marker 락 대기 워커 수
function endthr(){ if(tid=="")return
  if(coord && uq && !lw) ch=1
  if(worker && marker && lw) mw++
  tid="" }
function endfile(){ endthr(); if(FNR0){ tot+=mw; if(ch){hold++; mwh+=mw} files++ } ch=0; mw=0 }
FNR==1 { endfile(); FNR0=1 }
/^TID [0-9]+:/ { endthr(); tid=$2; coord=worker=uq=lw=marker=0; top=""; next }
/^#[0-9]+ / { fn=$0; sub(/^#[0-9]+ +0x[0-9a-f]+ /,"",fn); sub(/\(.*/,"",fn); if(top=="")top=fn
  if(fn~/^la_apply_log_file/)coord=1; if(fn~/^la_worker_main|^la_worker_run/)worker=1
  if(fn~/^la_update_query_execute/)uq=1; if(fn~/^la_insert_applied_tx_marker/)marker=1
  if(top~/lll_lock_wait|pthread_mutex_lock/)lw=1 }
END { endfile(); printf "샘플 %d장 중 코디네이터가 락 쥐고 쿼리 중: %d장 (%.0f%%)\n  marker 락 대기 워커-샘플 %d 중 그 순간에 걸린 것: %d (%.0f%%)\n", files, hold, 100*hold/files, tot, mwh, (tot?100*mwh/tot:0) }
