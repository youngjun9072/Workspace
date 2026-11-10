function flush(  k){ if(tid=="") return
  if (flushd) fl[flushst]++
  if (req) { if(xlogwr)k="copylogdb 로그 전송 요청"; else if(commitwait)k="커밋: 로그 flush 완료 대기"; else if(clientwait)k="클라이언트(applylogdb) 다음 요청 대기"; else if(lockw)k="락/뮤텍스 대기"; else k="CPU 실행 중"
    c[k]++; if(k=="CPU 실행 중" && dbg) d++ }
  tid="" }
/^TID [0-9]+:/ { flush(); tid=$2; req=0; xlogwr=0; commitwait=0; clientwait=0; lockw=0; dbg=0; flushd=0; flushst=""; top=""; next }
/^#[0-9]+ / { fn=$0; sub(/^#[0-9]+ +0x[0-9a-f]+ /,"",fn); sub(/\(.*/,"",fn)
  if (top=="") top=fn
  if (fn ~ /net_server_request/) req=1
  if (fn ~ /xlogwr_get_log_pages/) xlogwr=1
  if (fn ~ /logpb_flush_pages/ && top ~ /cond_timedwait|cond_wait/) commitwait=1
  if (fn ~ /css_receive_data/) clientwait=1
  if (top ~ /__lll_lock_wait|thread_suspend|lock_wait/ || fn ~ /lock_suspend/) lockw=1
  if (fn ~ /_debug$|with_debug_crash|watcher|fi_test|resource_tracker/) dbg=1
  if (fn ~ /log_flush_execute|logpb_flush_all_append_pages|flush_daemon|log_flush/ && !req) { flushd=1; if(flushst=="") flushst=top }
}
END { flush(); for(k in c) printf "  %-36s %3d  (샘플당 %.1f)\n", k, c[k], c[k]/N
  printf "  └ CPU 실행 중 가운데 디버그 빌드 전용 검사 함수가 스택에 있는 것: %d\n", d
  for(k in fl) printf "  [로그 flush 데몬] 최상위 %-28s %d\n", k, fl[k] }
