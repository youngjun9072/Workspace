# eu-stack 형식 applylogdb 분석: 워커 상태 + 코디네이터 일 분해 + 락 소유자
function flush(  k){ if(tid=="") return
  if (worker) { W++
    if (tq) k="일감 대기(굶음)"; else if (lw&&marker) k="marker 락 대기"; else if (lw&&pb) k="페이지버퍼 락 대기"; else if (lw) k="기타 락 대기"
    else if (readn&&commit) k="서버 대기: 커밋"; else if (readn&&flushr) k="서버 대기: 행 적용"; else if (readn&&marker) k="서버 대기: marker INSERT"; else if (readn) k="서버 대기: 기타"; else k="실행 중/기타"
    wc[k]++ }
  else if (coord) { C++
    if (idle) k="유휴"; else if (lw) k="락 대기"; else if (scan) k="pending/gate 스캔"; else if (parse) k="로그 레코드 파싱"; else if (fetch) k="로그 페이지 읽기"; else if (readn) k="서버 왕복"; else k="기타"
    cc[k]++ }
  tid="" }
/^TID [0-9]+:/ { flush(); tid=$2; worker=coord=tq=lw=marker=pb=readn=commit=flushr=idle=scan=parse=fetch=0; top=""; next }
/^#[0-9]+ / { fn=$0; sub(/^#[0-9]+ +0x[0-9a-f]+ /,"",fn); sub(/\(.*/,"",fn); if(top=="")top=fn
  if (fn ~ /^la_worker_main|^la_worker_run/) worker=1
  if (fn ~ /^la_apply_log_file/) coord=1
  if (fn ~ /^la_task_queue_pop/) tq=1
  if (top ~ /lll_lock_wait|pthread_mutex_lock/) lw=1
  if (fn ~ /^la_insert_applied_tx_marker/) marker=1
  if (fn ~ /^la_get_page_buffer|^la_release_page_buffer|^la_release_pinned_page_buffers/) pb=1
  if (fn ~ /^css_readn/) readn=1
  if (fn ~ /^tran_server_commit|^db_commit_transaction/) commit=1
  if (fn ~ /^la_flush_repl_items/) flushr=1
  if (top ~ /cond_timedwait/ && fn ~ /la_result_queue_wait/) idle=1
  if (fn ~ /^la_pending_pop_ready|^la_gate_is_satisfied/) scan=1
  if (fn ~ /^la_make_repl_item|^la_set_repl_log|^la_log_record_process/) parse=1
  if (fn ~ /^la_get_page$|^la_fetch_log|^la_log_fetch/) fetch=1
}
END { flush()
  printf "  [워커] 워커-샘플 %d\n", W; for(k in wc) printf "    %-26s %5d  %5.1f%%\n", k, wc[k], 100*wc[k]/W
  printf "  [코디네이터] 샘플 %d\n", C; for(k in cc) printf "    %-26s %5d  %5.1f%%\n", k, cc[k], 100*cc[k]/C }
