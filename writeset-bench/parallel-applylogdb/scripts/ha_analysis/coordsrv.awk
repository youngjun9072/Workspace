function flush(){ if(tid!="" && coord && readn) c[sig]++; tid="" }
/^TID [0-9]+:/ { flush(); tid=$2; coord=0; readn=0; sig=""; n=0; next }
/^#[0-9]+ / { fn=$0; sub(/^#[0-9]+ +0x[0-9a-f]+ /,"",fn); sub(/\(.*/,"",fn)
  if (fn ~ /^la_apply_log_file/) coord=1
  if (fn ~ /^css_readn/) readn=1
  if (fn ~ /^(la_|db_|locator_|ws_|sm_|tran_|qmgr_|net_client_request$|log_|xlog|cubrid_log|boot_)/ && n<5) { sig = sig (sig==""?"":" <- ") fn; n++ }
}
/^TID/ { n=0 }
END { flush(); for (k in c) printf "%3d  %s\n", c[k], k }
