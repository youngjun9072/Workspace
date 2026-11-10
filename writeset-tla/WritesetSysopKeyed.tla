----------------------------- MODULE WritesetSysopKeyed -----------------------------
(***************************************************************************)
(* End-to-end model of the writeset parallel replication of PR #8052       *)
(* (feature/CBRD-27508-parallel-applylogdb-writeset, HEAD 6bd39a696).     *)
(*                                                                         *)
(* The master part GENERATES the log the slave part consumes.             *)
(*                                                                         *)
(* Master (file:line at 6bd39a696):                                       *)
(*  - local key list per transaction: writeset.cpp 143-172 (append, limit *)
(*    -> commit order), 176-192 (switch_to_commit_order), 207-243 WRITE,  *)
(*    418-494 REF, 531-542 savepoint discard (log_manager.c 4276)          *)
(*  - statement replication -> commit order: replication.c 610             *)
(*  - commit path log_commit_local: complete_mvcc log_manager.c 5596,     *)
(*    then inside prior_lsa_mutex (5041-5053): repl records, find_dependency*)
(*    5048, label 5049, commit 5050, record_commit 5051; publish 5640;    *)
(*    lock_unlock_all 5649                                                 *)
(*  - dependency: writeset_order.cpp 43-142; probe writeset_history_map.cpp*)
(*    47-66; commit-order dependency writeset_history.cpp 129-142          *)
(*  - history: record_commit 145-162; publish fast path (rdlock + reserve) *)
(*    251-272; slow path (seq_lock + wrlock, capacity clear, OOM clear)    *)
(*    279-310; clear for commit order 232-249; clear floor = prev_commit  *)
(*    189-203; map publish = max per slot writeset_history_map.cpp 68-98  *)
(*  - labeled serial SYSOP_END: log_manager.c 4905-4916 (dependency =      *)
(*    commit-order dependency, history_start raised to the SYSOP_END)      *)
(*  - restart barrier: log_manager.c 1515-1519; recovery writes LOG_ABORT  *)
(*    for loser transactions (log_recovery.c 5049)                         *)
(*  - row locks: CBRD-27034 (ef4e7e812): a conflicting writer waits on the *)
(*    owner's MVCCID self-lock until lock_unlock_all, so the key is held   *)
(*    from the change to the unlock after publish.                         *)
(*                                                                         *)
(* Slave (log_applier.c unless named):                                    *)
(*  - slot created at the transaction's first record 7561-7584             *)
(*  - LOG_SYSOP_END 7323-7420, la_detach_sysop_fragment 7245-7321         *)
(*    (fragment start_lsa = first item, 7307)                              *)
(*  - LOG_COMMIT 7477-7537, dependency 7440-7466; ABORT frees the slot     *)
(*  - submit / gate / drain: applier/log_applier_coordinator.cpp submit,  *)
(*    139-164, gate.cpp 127-143, 196-229, 262-339                          *)
(*  - retire 741-760, release slot 716-739, required_lsa 2312-2380,       *)
(*    la_log_commit 7994-8010, commit_apply_info 1172-1214 (marker delete *)
(*    in the same slave transaction), restart 2852-2947 and 9811          *)
(*  - worker: marker insert in the data transaction 936-950, skip 6976    *)
(*                                                                         *)
(* Merged records (documented abstraction): the replication records, the *)
(* WSET label and the COMMIT (or the flushed serial item, the label and    *)
(* the SYSOP_END) are appended inside one prior_lsa_mutex region, so they *)
(* are one record here: "C" (commit, items = keys) or "S" (fragment). "X" *)
(* is the transaction's first, non-replicated log record (heap undo/redo).*)
(* "A" is LOG_ABORT. "D" is the serial row's replication record flushed  *)
(* right before its labeled SYSOP_END (kept apart so the fragment start   *)
(* is the item, as in the code). LSAs are record indices, 0 is NULL.      *)
(*                                                                         *)
(* ---- WritesetSysopKeyed: copy of WritesetE2E plus the "keyed sysop"    *)
(* design (proposal, not in 6bd39a696) ----                               *)
(*  - independent units: serial NEXT_VALUE (serial.c 1236-1330) and an    *)
(*    INCR/DECR that stays in instant-lock mode (query_executor.c         *)
(*    20496-20556, log_sysop_commit), both one SYSOP_END with a flushed   *)
(*    item D (log_manager.c 4010-4030) and a label (4905-4916).           *)
(*  - SysopMode "commitOrder" = today: label = commit-order dependency,   *)
(*    hs raised to the SYSOP_END, keys discarded (4052-4094).             *)
(*  - SysopMode "keyed" = proposal: inside prior_lsa_mutex probe the      *)
(*    unit's own key, label = min(max candidate, prev_commit) raised to   *)
(*    hs unless the top candidate is a REF slot (writeset_order.cpp       *)
(*    43-125), publish the key at the SYSOP_END, raise prev_commit to the *)
(*    SYSOP_END; hs is not raised. Mutant noSysopPrevRaise drops the      *)
(*    prev_commit raise.                                                  *)
(*  - attached INCR: instant mode stopped, log_sysop_attach_to_outer      *)
(*    (query_executor.c 20558-20565, log_manager.c 4311-4345): the row    *)
(*    change belongs to the outer transaction (X lock to commit, key in   *)
(*    the outer key list), its record stays LOG_REPL_NEED_FLUSH           *)
(*    (replication.c 484-507) and is written at the next SYSOP_END of the *)
(*    transaction that writes items (4010-4030), so it rides in that      *)
(*    fragment. AttachFix: the record becomes COMMIT_NEED_FLUSH (only the *)
(*    COMMIT writes it). SafetyCheck: a SYSOP_END carrying such a leftover*)
(*    uses the commit-order label and raises hs.                          *)
(*  - PlainSysop: a commit-type nested sysop with no keys of its own      *)
(*    (page allocation) that writes a leftover (findings.md 76).          *)
(*  - records carry wr = set of <<key, write id>>: write id <<t, 0>> is a *)
(*    change of the outer transaction (DML or attached INCR, undone by    *)
(*    abort), <<t, i>> the independent unit whose SYSOP_END is record i.  *)
(*  - Conflict is by key only (plus statement); same-transaction units    *)
(*    are no longer a conflict by themselves.                             *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
  Txns,               \* master transactions (model values, symmetric)
  Keys,               \* row keys (model values, symmetric); real key identity
  Serials,            \* serial keys (model values, not in Keys)
  HashMode,           \* "ident" | "splitEq" (mutant: the same key under two hashes)
  CollidePair,        \* keys that share one hash (distinct keys colliding); {} for none
  KeyLimit,           \* ha_writeset_history_size: per-transaction limit and history capacity
  MaxOps,             \* bound on DML / serial actions per transaction
  AllowRef, AllowOverflow, AllowStmt, AllowSavepoint, AllowAbort, AllowOOM,
  AllowMasterRestart, AllowSerial,
  FineGrainPublish,   \* fast-path publish entry by entry, interleaved with other probes
  Interleave,         \* slave runs while the master runs (FALSE: after the master quiesces)
  MasterOnly,         \* no slave: only the master-side properties (DepCover ...) are checked
  NumWorkers, QCap, RingCap, MaxCrash,
  AllowMarkerDdl,     \* a user statement on the master truncates ha_applied_tx_marker (review item)
  FixFragStart,       \* reviewer's fix: fragment start_lsa = outer slot start_lsa
  SysopMode,          \* "commitOrder" (6bd39a696) | "keyed" (proposal)
  AllowIncr,          \* instant-lock INCR/DECR as an independent unit on a row key
  AllowAttach,        \* INCR whose instant mode stops: attached to the outer transaction
  AllowPlainSysop,    \* keyless commit-type nested sysop that writes a pending leftover
  AttachFix,          \* attached INCR record -> COMMIT_NEED_FLUSH (never a leftover)
  SafetyCheck,        \* a SYSOP_END carrying a leftover uses commit order + raises hs
  Mut,                \* "none" or a mutant name
  None                \* model value
NULL == 1000          \* gate frontier NULL (above every LSA)
NoTask == [lsa |-> 0]

Variants == IF HashMode = "splitEq" THEN {1, 2} ELSE {1}
Hash(k, v) ==
  LET h == IF k \in CollidePair THEN "hc" ELSE k IN
  IF HashMode = "splitEq" THEN <<h, v>> ELSE h
Hashes == {Hash(k, v) : k \in Keys \cup Serials, v \in Variants}
NoSp == [st |-> "none", touched |-> {}, wl |-> {}, stmt |-> FALSE, pend |-> {}]
Kinds == IF AllowRef THEN {"W", "R"} ELSE {"W"}

Max2(a, b) == IF a >= b THEN a ELSE b
MaxOf(S) == IF S = {} THEN 0 ELSE CHOOSE m \in S : \A x \in S : x <= m
MinOf(S) == CHOOSE m \in S : \A x \in S : m <= x
Last(s) == s[Len(s)]
RemoveAt(s, j) == [i \in 1..(Len(s) - 1) |-> IF i < j THEN s[i] ELSE s[i + 1]]
SetOf(s) == {s[i] : i \in 1..Len(s)}
Remove(s, x) == SelectSeq(s, LAMBDA y : y # x)
RECURSIVE SetToSeq(_)
SetToSeq(S) == IF S = {} THEN << >> ELSE LET x == CHOOSE y \in S : TRUE IN <<x>> \o SetToSeq(S \ {x})

VARIABLES
  \* ---- master ----
  mphase,    \* active | logged | pubFast | oom | published | unlockedEarly | done | aborted | fin
  started,   \* the first log record (X) is written
  nops,      \* actions taken (bound)
  mvcc,      \* complete_mvcc ran
  xh, sh,    \* row lock: X holder / S holders (FK reference)
  touched,   \* <<k, kind>> really changed / referenced and not rolled back (ground truth)
  wl,        \* local key list: set of <<k, variant, kind>>
  ovf, stmt, \* wset_overflow, statement replication record present
  sp,        \* savepoint snapshot or None
  pubRem,    \* fast-path entries not yet published
  reserved,  \* wset_Publish_reserved
  hw, hr,    \* history map write_seq / ref_seq per hash (0 = absent)
  hs, prevCommit,
  mrestarted,
  wseq,      \* wseq[k]: real write order on the master: <<t, 0>> commit unit of t, <<t, i>> fragment i
  mlog,      \* [k: "X" | "C" | "S" | "A", t, dep, keys, stmt]
  mdone,     \* the master has quiesced (its working state is reset)
  pend,      \* pend[t]: keys of attached INCR records still LOG_REPL_NEED_FLUSH (not yet logged)
  shipped,   \* shipped[t]: keys whose attached INCR record was logged inside a fragment
  \* ---- slave ----
  rd, slot, ring, frontier, pending, tq, infl, wk, resq,
  committed, lastC, reqLsa, storedC, storedR,
  sdb,       \* slave commit order of applied units (record indices), across restarts
  markers, crashes

mvars == <<mphase, started, nops, mvcc, xh, sh, touched, wl, ovf, stmt, sp, pubRem, reserved,
           hw, hr, hs, prevCommit, mrestarted, wseq, mlog, mdone, pend, shipped>>
svars == <<rd, slot, ring, frontier, pending, tq, infl, wk, resq, committed, lastC, reqLsa,
           storedC, storedR, sdb, markers, crashes>>
vars == <<mvars, svars>>

-----------------------------------------------------------------------------
(* Master: locks *)

\* Mutant visibleAtMvcc: a conflicting writer goes once the owner ran complete_mvcc (pre CBRD-27034 shape).
Gone(u) == u # None /\ Mut = "visibleAtMvcc" /\ mvcc[u]
XFree(t, k) == (xh[k] = None \/ xh[k] = t \/ Gone(xh[k])) /\ \A u \in sh[k] : u = t \/ Gone(u)
SFree(t, k) == xh[k] = None \/ xh[k] = t \/ Gone(xh[k])

Active(t) == mphase[t] = "active" /\ ~mvcc[t] /\ nops[t] < MaxOps

XRec(t) == [k |-> "X", t |-> t, dep |-> 0, keys |-> {}, stmt |-> FALSE, wr |-> {}, co |-> FALSE]
\* the transaction's first log record, written by its first change
LogFirst(t) ==
  IF started[t] THEN /\ UNCHANGED <<mlog, started>>
  ELSE /\ mlog' = Append(mlog, XRec(t)) /\ started' = [started EXCEPT ![t] = TRUE]

\* wset_append_entry: once the list holds KeyLimit entries the transaction goes to commit order
Collect(t, e) ==
  IF ovf[t] THEN UNCHANGED <<wl, ovf>>
  ELSE IF Cardinality(wl[t]) >= KeyLimit
       THEN /\ wl' = [wl EXCEPT ![t] = {}] /\ ovf' = [ovf EXCEPT ![t] = TRUE]
       ELSE /\ wl' = [wl EXCEPT ![t] = @ \cup {e}] /\ UNCHANGED ovf

TakeLock(t, k, kind) ==
  IF kind = "W"
  THEN /\ xh' = [xh EXCEPT ![k] = t]
       /\ sh' = [sh EXCEPT ![k] = {u \in @ : u = t}]
  ELSE /\ xh' = IF xh[k] # None /\ xh[k] # t THEN [xh EXCEPT ![k] = None] ELSE xh
       /\ sh' = [sh EXCEPT ![k] = @ \cup {t}]

\* A row change (W) or an FK reference (R) of key k, hashed with variant v (locator_sr.c 8309-8350, 9031-9070)
Access(t, k, kind, v) ==
  /\ Active(t)
  /\ <<k, kind>> \notin touched[t]
  /\ IF kind = "W" THEN XFree(t, k) ELSE SFree(t, k)
  /\ TakeLock(t, k, kind)
  /\ touched' = [touched EXCEPT ![t] = @ \cup {<<k, kind>>}]
  /\ Collect(t, <<k, v, kind>>)
  /\ wseq' = IF kind = "W" THEN [wseq EXCEPT ![k] = Append(@, <<t, 0>>)] ELSE wseq
  /\ LogFirst(t)
  /\ nops' = [nops EXCEPT ![t] = @ + 1]
  /\ UNCHANGED <<mphase, mvcc, stmt, sp, pubRem, reserved, hw, hr, hs, prevCommit, mrestarted, mdone>>

\* Nondeterministic switch to commit order (key limit reached by repeated changes, NaN key)
Overflow(t) ==
  /\ AllowOverflow /\ Active(t) /\ started[t] /\ ~ovf[t]
  /\ ovf' = [ovf EXCEPT ![t] = TRUE]
  /\ wl' = [wl EXCEPT ![t] = {}]
  /\ nops' = [nops EXCEPT ![t] = @ + 1]
  /\ UNCHANGED <<mphase, started, mvcc, xh, sh, touched, stmt, sp, pubRem, reserved, hw, hr, hs, prevCommit,
                 mrestarted, wseq, mlog, mdone>>

\* A change replicated as a statement (replication.c 610): the slave re-executes it, the transaction
\* goes to commit order.
Statement(t, k) ==
  /\ AllowStmt /\ Active(t)
  /\ <<k, "W">> \notin touched[t]
  /\ XFree(t, k)
  /\ TakeLock(t, k, "W")
  /\ touched' = [touched EXCEPT ![t] = @ \cup {<<k, "W">>}]
  /\ stmt' = [stmt EXCEPT ![t] = TRUE]
  /\ ovf' = [ovf EXCEPT ![t] = TRUE]
  /\ wl' = [wl EXCEPT ![t] = {}]
  /\ wseq' = [wseq EXCEPT ![k] = Append(@, <<t, 0>>)]
  /\ LogFirst(t)
  /\ nops' = [nops EXCEPT ![t] = @ + 1]
  /\ UNCHANGED <<mphase, mvcc, sp, pubRem, reserved, hw, hr, hs, prevCommit, mrestarted, mdone>>

MarkerKey == "marker"   \* stands for the rows of ha_applied_tx_marker

\* TRUNCATE of the marker table run on the master (an ordinary DBA table, review 4489620911). It is
\* replicated as a statement.
MarkerTruncate(t) ==
  /\ AllowMarkerDdl /\ Active(t)
  /\ <<MarkerKey, "W">> \notin touched[t]
  /\ touched' = [touched EXCEPT ![t] = @ \cup {<<MarkerKey, "W">>}]
  /\ stmt' = [stmt EXCEPT ![t] = TRUE]
  /\ ovf' = [ovf EXCEPT ![t] = TRUE]
  /\ wl' = [wl EXCEPT ![t] = {}]
  /\ LogFirst(t)
  /\ nops' = [nops EXCEPT ![t] = @ + 1]
  /\ UNCHANGED <<mphase, mvcc, xh, sh, sp, pubRem, reserved, hw, hr, hs, prevCommit, mrestarted, wseq, mdone>>

Savepoint(t) ==
  /\ AllowSavepoint /\ Active(t) /\ sp[t].st = "none"
  /\ sp' = [sp EXCEPT ![t] = [st |-> "set", touched |-> touched[t], wl |-> wl[t], stmt |-> stmt[t], pend |-> pend[t]]]
  /\ nops' = [nops EXCEPT ![t] = @ + 1]
  /\ UNCHANGED <<mphase, started, mvcc, xh, sh, touched, wl, ovf, stmt, pubRem, reserved, hw, hr, hs,
                 prevCommit, mrestarted, wseq, mlog, mdone>>

\* Partial rollback: changes and keys after the savepoint go, locks stay, an overflow stays
\* (wset_discard_keys_after_lsa, repl_log_abort_after_lsa).
RollbackToSavepoint(t) ==
  /\ mphase[t] = "active" /\ ~mvcc[t] /\ sp[t].st = "set"
  /\ LET undone == {x[1] : x \in {y \in touched[t] \ sp[t].touched : y[2] = "W"}} IN
     wseq' = [k \in DOMAIN wseq |-> IF k \in undone THEN Remove(wseq[k], <<t, 0>>) ELSE wseq[k]]
  /\ touched' = [touched EXCEPT ![t] = sp[t].touched]
  /\ wl' = [wl EXCEPT ![t] = IF ovf[t] THEN {} ELSE sp[t].wl]
  /\ stmt' = [stmt EXCEPT ![t] = sp[t].stmt]
  /\ sp' = [sp EXCEPT ![t].st = "used"]
  \* repl_log_abort_after_lsa: an unwritten attached INCR record after the savepoint is dropped; one already
  \* written inside a fragment stays on the slave (same develop mismatch as an abort)
  /\ pend' = [pend EXCEPT ![t] = @ \cap sp[t].pend]
  /\ UNCHANGED shipped
  /\ UNCHANGED <<mphase, started, nops, mvcc, xh, sh, ovf, pubRem, reserved, hw, hr, hs, prevCommit,
                 mrestarted, mlog, mdone>>

\* Commit-order dependency (writeset_history.cpp 129-142)
CommitOrderDep == IF hs # 0 /\ (prevCommit = 0 \/ prevCommit < hs) THEN hs ELSE prevCommit

ReleaseLocks(t) ==
  /\ xh' = [k \in DOMAIN xh |-> IF xh[k] = t THEN None ELSE xh[k]]
  /\ sh' = [k \in DOMAIN sh |-> sh[k] \ {t}]

Abort(t) ==
  /\ AllowAbort /\ mphase[t] = "active" /\ ~mvcc[t] /\ started[t]
  /\ mphase' = [mphase EXCEPT ![t] = "aborted"]
  /\ ReleaseLocks(t)
  /\ wseq' = [k \in DOMAIN wseq |-> Remove(wseq[k], <<t, 0>>)]
  /\ mlog' = Append(mlog, [k |-> "A", t |-> t, dep |-> 0, keys |-> {}, stmt |-> FALSE, wr |-> {}, co |-> FALSE])
  \* unwritten records are dropped; a leftover already written in a fragment is not taken back
  /\ pend' = [pend EXCEPT ![t] = {}]
  /\ UNCHANGED <<started, nops, mvcc, touched, wl, ovf, stmt, sp, pubRem, reserved, hw, hr, hs, prevCommit,
                 mrestarted, mdone, shipped>>

\* logtb_complete_mvcc (log_manager.c 5596), before the commit record
CompleteMvcc(t) ==
  /\ mphase[t] = "active" /\ ~mvcc[t] /\ started[t]
  /\ mvcc' = [mvcc EXCEPT ![t] = TRUE]
  /\ UNCHANGED <<mphase, started, nops, xh, sh, touched, wl, ovf, stmt, sp, pubRem, reserved, hw, hr, hs,
                 prevCommit, mrestarted, wseq, mlog, mdone>>

\* probe (writeset_history_map.cpp 47-66): <<candidate, from ref slot>>, candidate 0 on a miss
Probe(e) ==
  LET h == Hash(e[1], e[2]) IN
  IF hw[h] = 0 /\ hr[h] = 0 THEN <<0, FALSE>>
  ELSE IF e[3] = "R" THEN <<hw[h], FALSE>>
  ELSE IF hr[h] > hw[h] THEN <<hr[h], TRUE>> ELSE <<hw[h], FALSE>>

\* wset_order_find_dependency_in_range (writeset_order.cpp 43-125). The probe loop keeps the first entry
\* (in collection order) that reaches the final maximum; the order is free, so any such entry may be it.
WsDeps(t) ==
  LET cands == {c \in {Probe(e) : e \in wl[t]} : c[1] > 0}
      top   == Max2(hs, MaxOf({c[1] : c \in cands}))
      refs  == IF top > hs THEN {c[2] : c \in {x \in cands : x[1] = top}} ELSE {FALSE}
      bound == IF prevCommit = 0 \/ top < prevCommit THEN top ELSE prevCommit
      wb    == IF hs # 0 /\ (bound = 0 \/ bound < hs) THEN hs ELSE bound
  IN {IF r THEN top ELSE wb : r \in refs}

\* log_append_repl_info_and_commit_log (log_manager.c 5030-5054), one prior_lsa_mutex region
CommitRecord(t) ==
  /\ mphase[t] = "active" /\ mvcc[t]
  /\ LET idx == Len(mlog) + 1 IN
     \E d \in (IF ovf[t] THEN {CommitOrderDep} ELSE WsDeps(t)) :
       \* items written by the COMMIT: everything not already written inside a fragment (log_manager.c 4930-5000)
       /\ LET ks == {x \in touched[t] : ~(x[2] = "W" /\ x[1] \in shipped[t])} IN
          mlog' = Append(mlog, [k |-> "C", t |-> t, dep |-> d, keys |-> ks, stmt |-> stmt[t],
                                wr |-> {<<x[1], <<t, 0>>>> : x \in {y \in ks : y[2] = "W"}}, co |-> ovf[t]])
       /\ prevCommit' = Max2(prevCommit, idx)
       /\ hs' = IF ovf[t] /\ Mut # "noOvfFloor" THEN Max2(hs, idx) ELSE hs
  /\ mphase' = [mphase EXCEPT ![t] = "logged"]
  /\ pend' = [pend EXCEPT ![t] = {}]
  /\ UNCHANGED <<started, nops, mvcc, xh, sh, touched, wl, ovf, stmt, sp, pubRem, reserved, hw, hr,
                 mrestarted, wseq, mdone, shipped>>

MapSize == Cardinality({h \in Hashes : hw[h] # 0 \/ hr[h] # 0})
ClearFloor == IF Mut = "noClearFloor" THEN hs ELSE Max2(hs, prevCommit)
CIdx(t) == CHOOSE i \in 1..Len(mlog) : mlog[i].t = t /\ mlog[i].k = "C"
Zero == [h \in Hashes |-> 0]
NoReaders == \A u \in Txns : mphase[u] # "pubFast"   \* the history wrlock waits for fast publishers

PubW(es, c) == [h \in Hashes |-> IF \E e \in es : e[3] = "W" /\ Hash(e[1], e[2]) = h THEN Max2(hw[h], c) ELSE hw[h]]
PubR(es, c) == [h \in Hashes |-> IF \E e \in es : e[3] = "R" /\ Hash(e[1], e[2]) = h THEN Max2(hr[h], c) ELSE hr[h]]
OnlyW(es, c) == [h \in Hashes |-> IF \E e \in es : e[3] = "W" /\ Hash(e[1], e[2]) = h THEN c ELSE 0]
OnlyR(es, c) == [h \in Hashes |-> IF \E e \in es : e[3] = "R" /\ Hash(e[1], e[2]) = h THEN c ELSE 0]

\* slow path under seq_lock + wrlock (writeset_history.cpp 279-310): capacity clear then publish; an
\* allocation failure clears instead of publishing
SlowPublish(t, c) ==
  LET es == wl[t] IN
  \/ /\ MapSize + Cardinality(es) > KeyLimit
     /\ hw' = OnlyW(es, c) /\ hr' = OnlyR(es, c) /\ hs' = ClearFloor
  \/ /\ MapSize + Cardinality(es) <= KeyLimit
     /\ hw' = PubW(es, c) /\ hr' = PubR(es, c) /\ UNCHANGED hs
  \/ /\ AllowOOM
     /\ hw' = Zero /\ hr' = Zero /\ hs' = ClearFloor

\* wset_order_publish_commit_keys (log_manager.c 5640) -> wset_history_publish_keys (writeset_history.cpp 322)
Publish(t) ==
  /\ mphase[t] = "logged"
  /\ LET c == CIdx(t)
         n == Cardinality(wl[t])
     IN
     IF ovf[t] THEN                         \* wset_history_clear_for_commit_order
        /\ NoReaders
        /\ hw' = Zero /\ hr' = Zero /\ hs' = ClearFloor
        /\ mphase' = [mphase EXCEPT ![t] = "published"]
        /\ UNCHANGED <<pubRem, reserved>>
     ELSE IF n = 0 THEN
        /\ mphase' = [mphase EXCEPT ![t] = "published"]
        /\ UNCHANGED <<hw, hr, hs, pubRem, reserved>>
     ELSE IF FineGrainPublish /\ MapSize + reserved + n <= KeyLimit THEN
        /\ reserved' = reserved + n
        /\ pubRem' = [pubRem EXCEPT ![t] = wl[t]]
        /\ mphase' = [mphase EXCEPT ![t] = "pubFast"]
        /\ UNCHANGED <<hw, hr, hs>>
     ELSE
        /\ NoReaders
        /\ SlowPublish(t, c)
        /\ mphase' = [mphase EXCEPT ![t] = "published"]
        /\ UNCHANGED <<pubRem, reserved>>
  /\ UNCHANGED <<started, nops, mvcc, xh, sh, touched, wl, ovf, stmt, sp, prevCommit, mrestarted, wseq,
                 mlog, mdone>>

\* fast path: one entry at a time under the history rdlock, concurrently with other probes
PublishStep(t, e) ==
  /\ mphase[t] = "pubFast" /\ e \in pubRem[t]
  /\ LET c == CIdx(t)
         n == Cardinality(wl[t])
         rest == pubRem[t] \ {e}
     IN
     \/ /\ hw' = PubW({e}, c) /\ hr' = PubR({e}, c)
        /\ pubRem' = [pubRem EXCEPT ![t] = rest]
        /\ IF rest = {}
           THEN /\ reserved' = reserved - n /\ mphase' = [mphase EXCEPT ![t] = "published"]
           ELSE UNCHANGED <<reserved, mphase>>
     \/ /\ AllowOOM      \* bad_alloc: give the reservation back, then clear on the slow path
        /\ reserved' = reserved - n
        /\ pubRem' = [pubRem EXCEPT ![t] = {}]
        /\ mphase' = [mphase EXCEPT ![t] = "oom"]
        /\ UNCHANGED <<hw, hr>>
  /\ UNCHANGED <<started, nops, mvcc, xh, sh, touched, wl, ovf, stmt, sp, hs, prevCommit, mrestarted, wseq,
                 mlog, mdone>>

OomClear(t) ==
  /\ mphase[t] = "oom" /\ NoReaders
  /\ hw' = Zero /\ hr' = Zero /\ hs' = ClearFloor
  /\ mphase' = [mphase EXCEPT ![t] = "published"]
  /\ UNCHANGED <<started, nops, mvcc, xh, sh, touched, wl, ovf, stmt, sp, pubRem, reserved, prevCommit,
                 mrestarted, wseq, mlog, mdone>>

\* lock_unlock_all (log_manager.c 5649). Mutant unlockBeforePublish: it may run before the publish.
Unlock(t) ==
  /\ IF Mut = "unlockBeforePublish" THEN mphase[t] \in {"logged", "published"} ELSE mphase[t] = "published"
  /\ ReleaseLocks(t)
  /\ mphase' = [mphase EXCEPT ![t] = IF mphase[t] = "logged" THEN "unlockedEarly" ELSE "done"]
  /\ UNCHANGED <<started, nops, mvcc, touched, wl, ovf, stmt, sp, pubRem, reserved, hw, hr, hs, prevCommit,
                 mrestarted, wseq, mlog, mdone>>

PublishLate(t) ==
  /\ mphase[t] = "unlockedEarly"
  /\ LET c == CIdx(t) IN
     IF ovf[t] THEN /\ hw' = Zero /\ hr' = Zero /\ hs' = ClearFloor
     ELSE /\ hw' = PubW(wl[t], c) /\ hr' = PubR(wl[t], c) /\ UNCHANGED hs
  /\ mphase' = [mphase EXCEPT ![t] = "done"]
  /\ UNCHANGED <<started, nops, mvcc, xh, sh, touched, wl, ovf, stmt, sp, pubRem, reserved, prevCommit,
                 mrestarted, wseq, mlog, mdone>>

-----------------------------------------------------------------------------
(* Independent replication units (serial NEXT_VALUE, instant INCR/DECR), attached INCR, keyless sysop *)

\* Keyed label of a SYSOP_END (proposal): the commit path's bound applied to the unit's own entries es
\* (writeset_order.cpp 43-125: max candidate from hs, REF-slot top unbounded, else min with prev_commit,
\* then raised to hs).
KeyedDeps(es) ==
  LET cands == {c \in {Probe(e) : e \in es} : c[1] > 0}
      top   == Max2(hs, MaxOf({c[1] : c \in cands}))
      refs  == IF top > hs THEN {c[2] : c \in {x \in cands : x[1] = top}} ELSE {FALSE}
      bound == IF prevCommit = 0 \/ top < prevCommit THEN top ELSE prevCommit
      wb    == IF hs # 0 /\ (bound = 0 \/ bound < hs) THEN hs ELSE bound
  IN {IF r THEN top ELSE wb : r \in refs}

\* One labeled SYSOP_END unit of transaction t, written in one prior_lsa_mutex region with its flushed
\* item D (log_manager.c 4010-4077, 4905-4916). o is the unit's own key: a serial (serial.c 1236-1330),
\* a row changed by an instant-lock INCR (query_executor.c 20496-20556; the row's PK key is collected,
\* locator_sr.c 9031-9070), or None for a keyless commit-type nested sysop that only writes a leftover.
\* The pending leftover records of attached INCRs (pend[t]) are written with it (4010-4030).
SysopUnit(t, o) ==
  /\ Active(t)
  /\ CASE o \in Serials -> AllowSerial
       [] o \in Keys    -> /\ AllowIncr
                           \* instant mode needs the row unlocked by t (else the lock manager turns it off,
                           \* lock_manager.c 3984-3993, which is the attached path) and free of others
                           /\ xh[o] # t /\ t \notin sh[o] /\ XFree(t, o)
       [] OTHER         -> AllowPlainSysop /\ pend[t] # {}
  /\ LET left  == pend[t]
         own   == IF o = None THEN {} ELSE {o}
         es    == {<<x, 1, "W">> : x \in own}
         base0 == IF started[t] THEN mlog ELSE Append(mlog, XRec(t))
         base  == Append(base0, [k |-> "D", t |-> t, dep |-> 0, keys |-> {}, stmt |-> FALSE, wr |-> {},
                                 co |-> FALSE])
         idx   == Len(base) + 1
         co    == SysopMode = "commitOrder" \/ (SafetyCheck /\ left # {})
         keyed == SysopMode = "keyed"
         h1    == IF co /\ Mut # "noSysopFloor" THEN Max2(hs, idx) ELSE hs
     IN
     /\ \E d \in (IF co THEN {CommitOrderDep} ELSE KeyedDeps(es)) :
          mlog' = Append(base, [k |-> "S", t |-> t, dep |-> d, keys |-> {<<x, "W">> : x \in own \cup left},
                                stmt |-> FALSE, co |-> co,
                                wr |-> {<<x, <<t, idx>>>> : x \in own} \cup {<<x, <<t, 0>>>> : x \in left}])
     \* keyed: publish the own key at the SYSOP_END (inside the mutex, capacity clear as the slow path,
     \* floor = prev_commit before the raise); commit order: the key is discarded (wset_discard_sysop_keys)
     /\ IF keyed /\ own # {}
        THEN IF MapSize + reserved + 1 > KeyLimit
             THEN /\ hw' = OnlyW(es, idx) /\ hr' = Zero /\ hs' = Max2(h1, ClearFloor)
             ELSE /\ hw' = PubW(es, idx) /\ UNCHANGED hr /\ hs' = h1
        ELSE /\ UNCHANGED <<hw, hr>> /\ hs' = h1
     /\ prevCommit' = IF keyed /\ Mut # "noSysopPrevRaise" THEN Max2(prevCommit, idx) ELSE prevCommit
     /\ wseq' = [k \in DOMAIN wseq |-> IF k \in own THEN Append(wseq[k], <<t, idx>>) ELSE wseq[k]]
     /\ pend' = [pend EXCEPT ![t] = {}]
     /\ shipped' = [shipped EXCEPT ![t] = @ \cup left]
  /\ started' = [started EXCEPT ![t] = TRUE]
  /\ nops' = [nops EXCEPT ![t] = @ + 1]
  /\ UNCHANGED <<mphase, mvcc, xh, sh, touched, wl, ovf, stmt, sp, pubRem, reserved, mrestarted, mdone>>

\* INCR whose instant mode stopped (FK check, row already locked ...): log_sysop_attach_to_outer
\* (query_executor.c 20558-20565, log_manager.c 4311-4345). The change is the outer transaction's (X lock to
\* commit, key in the outer key list, undone by abort). Its record stays LOG_REPL_NEED_FLUSH (develop) and
\* waits in pend[t] for the next SYSOP_END that writes items; with AttachFix it is COMMIT_NEED_FLUSH.
AttachIncr(t, k) ==
  /\ AllowAttach /\ Active(t)
  /\ <<k, "W">> \notin touched[t]
  /\ XFree(t, k)
  /\ TakeLock(t, k, "W")
  /\ touched' = [touched EXCEPT ![t] = @ \cup {<<k, "W">>}]
  /\ Collect(t, <<k, 1, "W">>)
  /\ wseq' = [wseq EXCEPT ![k] = Append(@, <<t, 0>>)]
  /\ LogFirst(t)
  /\ nops' = [nops EXCEPT ![t] = @ + 1]
  /\ pend' = IF AttachFix THEN pend ELSE [pend EXCEPT ![t] = @ \cup {k}]
  /\ UNCHANGED <<mphase, mvcc, stmt, sp, pubRem, reserved, hw, hr, hs, prevCommit, mrestarted, mdone, shipped>>

\* Server restart: the committed survive, the losers are rolled back with a LOG_ABORT, the in-memory
\* history is empty and history_start is raised to the end of the recovered log.
MasterRestart ==
  /\ AllowMasterRestart /\ ~mrestarted /\ Len(mlog) > 0
  /\ LET losers == {t \in Txns : mphase[t] = "active" /\ started[t]}
         won    == {t \in Txns : mphase[t] \in {"logged", "pubFast", "oom", "published", "unlockedEarly"}}
         lseq   == SetToSeq(losers)
         aborts == [i \in 1..Cardinality(losers) |->
                      [k |-> "A", t |-> lseq[i], dep |-> 0, keys |-> {}, stmt |-> FALSE, wr |-> {}, co |-> FALSE]]
     IN /\ mlog' = mlog \o aborts
        /\ hs' = Len(mlog) + Cardinality(losers)
        /\ mphase' = [t \in Txns |-> IF t \in losers THEN "aborted" ELSE IF t \in won THEN "done" ELSE mphase[t]]
        /\ wseq' = [k \in DOMAIN wseq |-> SelectSeq(wseq[k], LAMBDA x : x[1] \notin losers \/ x[2] # 0)]
  /\ mrestarted' = TRUE
  /\ xh' = [k \in DOMAIN xh |-> None] /\ sh' = [k \in DOMAIN sh |-> {}]
  /\ hw' = Zero /\ hr' = Zero /\ prevCommit' = 0 /\ reserved' = 0
  /\ pubRem' = [t \in Txns |-> {}]
  /\ pend' = [t \in Txns |-> {}]
  /\ UNCHANGED <<started, nops, mvcc, touched, wl, ovf, stmt, sp, mdone, shipped>>

MasterQuiet == \A t \in Txns : mphase[t] \in {"done", "aborted"} \/ (mphase[t] = "active" /\ ~started[t])

\* Hand-off: the master stops; its working state is reset so that runs producing the same log merge.
MasterFinish ==
  /\ ~mdone /\ MasterQuiet
  /\ mdone' = TRUE
  /\ mphase' = [t \in Txns |-> "fin"]
  /\ started' = [t \in Txns |-> FALSE] /\ nops' = [t \in Txns |-> 0] /\ mvcc' = [t \in Txns |-> FALSE]
  /\ touched' = [t \in Txns |-> {}] /\ wl' = [t \in Txns |-> {}] /\ ovf' = [t \in Txns |-> FALSE]
  /\ stmt' = [t \in Txns |-> FALSE] /\ sp' = [t \in Txns |-> NoSp]
  /\ hw' = Zero /\ hr' = Zero /\ hs' = 0 /\ prevCommit' = 0 /\ mrestarted' = FALSE
  /\ pend' = [t \in Txns |-> {}] /\ shipped' = [t \in Txns |-> {}]
  /\ UNCHANGED <<xh, sh, pubRem, reserved, wseq, mlog>>

MasterNext ==
  \/ /\ \/ \E t \in Txns, k \in Keys, kd \in Kinds, v \in Variants : Access(t, k, kd, v)
        \/ \E t \in Txns, k \in Keys : Statement(t, k)
        \/ \E t \in Txns : \/ Overflow(t) \/ MarkerTruncate(t) \/ Savepoint(t) \/ CompleteMvcc(t) \/ Publish(t)
                           \/ OomClear(t) \/ Unlock(t) \/ PublishLate(t)
        \/ \E t \in Txns : \E e \in pubRem[t] : PublishStep(t, e)
     /\ UNCHANGED <<pend, shipped>>
  \/ \E t \in Txns : RollbackToSavepoint(t) \/ Abort(t) \/ CommitRecord(t)
  \/ \E t \in Txns, o \in Serials \cup Keys \cup {None} : SysopUnit(t, o)
  \/ \E t \in Txns, k \in Keys : AttachIncr(t, k)
  \/ MasterRestart
  \/ MasterFinish

-----------------------------------------------------------------------------
(* Static facts about the master log *)

N == Len(mlog)
FirstRec(t) == MinOf({i \in 1..N : mlog[i].t = t})
\* a unit the slave must apply: a commit with replicated items, or a serial fragment
IsUnit(i) == mlog[i].k = "S" \/ (mlog[i].k = "C" /\ mlog[i].keys # {})
Units == {i \in 1..N : IsUnit(i)}

\* Real conflict, by key equality (not hash): a common key with a write (a fragment's keys are its own key
\* and any leftover it carries), or a re-executed statement. Same-transaction units are not a conflict by
\* themselves: their data order is covered by the keys.
Conflict(i, j) ==
  \/ mlog[i].stmt \/ mlog[j].stmt
  \/ \E x \in mlog[i].keys, y \in mlog[j].keys : x[1] = y[1] /\ (x[2] = "W" \/ y[2] = "W")

-----------------------------------------------------------------------------
(* Slave *)

SlaveOn == ~MasterOnly /\ (Interleave \/ mdone)
Workers == 1..NumWorkers
\* act: slot exists; start: start_lsa; frag: last_sysop_fragment_lsa; fd: LSA of a buffered fragment item
EmptySlot == [act |-> FALSE, start |-> 0, frag |-> 0, fd |-> 0]

\* mutant gateLoose: the gate lets a task go one record early
GateOK(dep, fr) == dep = 0 \/ (fr # NULL /\ (IF Mut = "gateLoose" THEN dep <= fr + 1 ELSE dep <= fr))

RECURSIVE Advance(_, _)
Advance(r, fr) ==
  IF r # << >> /\ Head(r).done THEN Advance(Tail(r), Head(r).lsa) ELSE [r |-> r, fr |-> fr]

MarkDone(r, lsa) == [i \in 1..Len(r) |-> IF r[i].lsa = lsa THEN [r[i] EXCEPT !.done = TRUE] ELSE r[i]]

\* la_coordinator_drain_ready: dispatch ready pending tasks in pending order while the queue has room
RECURSIVE Drain(_, _, _, _)
Drain(p, q, inf, fr) ==
  LET idx == {j \in 1..Len(p) : GateOK(p[j].dep, fr)} IN
  IF Len(q) >= QCap \/ idx = {} THEN [p |-> p, q |-> q, inf |-> inf]
  ELSE LET j == MinOf(idx) IN
       Drain(RemoveAt(p, j), Append(q, p[j]), Append(inf, [task |-> p[j], res |-> FALSE]), fr)

\* la_coordinator_submit_task: bound the dependency to the ring tail (gate.cpp 196-229), push to the ring,
\* drain, then dispatch or park
Submit(task, s1, t) ==
  LET fr1 == IF frontier = NULL THEN committed ELSE frontier
      prev == IF ring # << >> THEN Last(ring).lsa ELSE fr1
      dep1 == IF task.dep # 0 /\ task.dep > prev THEN prev ELSE task.dep
      tk == [task EXCEPT !.dep = dep1]
  IN
  /\ ring' = Append(ring, [lsa |-> tk.lsa, done |-> FALSE])
  /\ frontier' = fr1
  /\ slot' = [slot EXCEPT ![t] = s1]
  /\ IF NumWorkers = 1
     THEN /\ tq' = Append(tq, tk)
          /\ infl' = Append(infl, [task |-> tk, res |-> FALSE])
          /\ pending' = pending
     ELSE LET d == Drain(pending, tq, infl, fr1) IN
          IF GateOK(dep1, fr1) /\ Len(d.q) < QCap
          THEN /\ tq' = Append(d.q, tk)
               /\ infl' = Append(d.inf, [task |-> tk, res |-> FALSE])
               /\ pending' = d.p
          ELSE /\ tq' = d.q /\ infl' = d.inf
               /\ pending' = Append(d.p, tk)

\* la_coordinator_complete_without_task
CompleteWithoutTask(lsa, s1, t) ==
  LET fr1 == IF frontier = NULL THEN committed ELSE frontier
      a == Advance(Append(ring, [lsa |-> lsa, done |-> TRUE]), fr1)
      d == Drain(pending, tq, infl, a.fr)
  IN /\ ring' = a.r /\ frontier' = a.fr
     /\ slot' = [slot EXCEPT ![t] = s1]
     /\ tq' = d.q /\ infl' = d.inf /\ pending' = d.p

ReadRecord ==
  /\ SlaveOn /\ rd <= N
  /\ LET i == rd
         r == mlog[i]
         t == r.t
         s0 == IF i = FirstRec(t) THEN [EmptySlot EXCEPT !.act = TRUE, !.start = i] ELSE slot[t]
     IN
     /\ rd' = rd + 1
     /\ CASE r.k = "X" ->
              /\ slot' = [slot EXCEPT ![t] = s0]
              /\ UNCHANGED <<ring, frontier, pending, tq, infl>>
          [] r.k = "D" ->   \* la_set_repl_log: dropped when the transaction has no slot
              /\ slot' = [slot EXCEPT ![t] = IF s0.act THEN [s0 EXCEPT !.fd = IF s0.fd = 0 THEN i ELSE s0.fd] ELSE s0]
              /\ UNCHANGED <<ring, frontier, pending, tq, infl>>
          [] r.k = "A" ->
              /\ slot' = [slot EXCEPT ![t] = EmptySlot]
              /\ UNCHANGED <<ring, frontier, pending, tq, infl>>
          [] r.k = "S" /\ i > committed ->
              /\ Len(ring) < RingCap
              /\ IF s0.act /\ s0.fd # 0   \* the flushed item is in the slot: a fragment task
                 THEN Submit([lsa |-> i, t |-> t, kind |-> "S", dep |-> r.dep, items |-> TRUE, hasApply |-> TRUE,
                              start |-> IF FixFragStart THEN s0.start ELSE s0.fd],
                             [s0 EXCEPT !.frag = i, !.fd = 0], t)
                 ELSE CompleteWithoutTask(i, s0, t)
          [] r.k = "C" /\ i > committed ->
              /\ Len(ring) < RingCap
              /\ LET d == IF s0.act /\ s0.frag > r.dep THEN s0.frag ELSE r.dep IN
                 Submit([lsa |-> i, t |-> t, kind |-> "C", dep |-> d, items |-> (s0.act /\ r.keys # {}),
                         hasApply |-> s0.act, start |-> s0.start], s0, t)
          [] OTHER ->   \* boundary at or below committed_lsa
              /\ slot' = [slot EXCEPT ![t] = IF r.k = "C" THEN EmptySlot ELSE s0]
              /\ UNCHANGED <<ring, frontier, pending, tq, infl>>
  /\ UNCHANGED <<mvars, wk, resq, committed, lastC, reqLsa, storedC, storedR, sdb, markers, crashes>>

AttachAll(inf, rs) ==
  [i \in 1..Len(inf) |-> IF inf[i].task.lsa \in SetOf(rs) THEN [inf[i] EXCEPT !.res = TRUE] ELSE inf[i]]

RECURSIVE MarkAll(_, _)
MarkAll(r, rs) == IF rs = << >> THEN r ELSE MarkAll(MarkDone(r, Head(rs)), Tail(rs))

RECURSIVE RetireCount(_)
RetireCount(inf) == IF inf = << >> \/ ~inf[1].res THEN 0 ELSE 1 + RetireCount(Tail(inf))

\* la_coordinator_collect_and_retire: results mark the ring, the frontier advances, ready tasks drain,
\* finished head entries retire; committed_lsa follows the frontier; maybe store (store_progress)
CollectRetire(doStore) ==
  /\ SlaveOn
  /\ LET inf1 == AttachAll(infl, resq)
         a == Advance(MarkAll(ring, resq), frontier)
         d == Drain(pending, tq, inf1, a.fr)
         n == RetireCount(d.inf)
         retired == {d.inf[i].task : i \in 1..n}
         c1 == IF n > 0 /\ a.fr # NULL /\ a.fr > committed THEN a.fr ELSE committed
         freed == {tk.t : tk \in {x \in retired : x.kind = "C" /\ x.hasApply}}
     IN
     /\ (resq # << >> \/ n > 0 \/ d.p # pending)
     /\ resq' = << >>
     /\ ring' = a.r /\ frontier' = a.fr
     /\ pending' = d.p /\ tq' = d.q
     /\ infl' = [i \in 1..(Len(d.inf) - n) |-> d.inf[i + n]]
     /\ slot' = [t \in Txns |-> IF t \in freed THEN EmptySlot ELSE slot[t]]
     /\ committed' = c1
     /\ IF doStore /\ n > 0
        THEN /\ storedC' = Max2(c1, lastC)
             /\ storedR' = reqLsa
             /\ markers' = {m \in markers : m > c1}
        ELSE UNCHANGED <<storedC, storedR, markers>>
  /\ UNCHANGED <<mvars, rd, wk, lastC, reqLsa, sdb, crashes>>

\* la_find_required_lsa
Required ==
  LET c == {slot[t].start : t \in {u \in Txns : slot[u].act}}
           \cup {infl[i].task.start : i \in {j \in 1..Len(infl) : infl[j].task.hasApply}}
           \cup {pending[i].start : i \in {j \in 1..Len(pending) : pending[j].hasApply}}
  IN IF c = {} THEN rd ELSE MinOf(c)

\* la_log_commit (periodic, between records)
LogCommit ==
  /\ SlaveOn
  /\ LET R == Required
         C == Max2(committed, lastC)
     IN /\ <<storedC, storedR, reqLsa>> # <<C, R, R>>
        /\ reqLsa' = R /\ storedC' = C /\ storedR' = R
        /\ markers' = {m \in markers : m > committed}
  /\ UNCHANGED <<mvars, rd, slot, ring, frontier, pending, tq, infl, wk, resq, committed, lastC, sdb, crashes>>

Take(w) ==
  /\ wk[w] = NoTask /\ tq # << >>
  /\ wk' = [wk EXCEPT ![w] = Head(tq)]
  /\ tq' = Tail(tq)
  /\ UNCHANGED <<mvars, rd, slot, ring, frontier, pending, infl, resq, committed, lastC, reqLsa, storedC,
                 storedR, sdb, markers, crashes>>

\* apply, marker insert and commit in one slave transaction
Finish(w) ==
  /\ wk[w] # NoTask
  /\ LET tk == wk[w]
         skip == tk.lsa <= lastC \/ tk.lsa \in markers
     IN
     /\ wk' = [wk EXCEPT ![w] = NoTask]
     /\ resq' = Append(resq, tk.lsa)
     /\ IF tk.items /\ ~skip
        THEN /\ sdb' = Append(sdb, tk.lsa)
             /\ markers' = IF <<MarkerKey, "W">> \in mlog[tk.lsa].keys THEN {tk.lsa} ELSE markers \cup {tk.lsa}
        ELSE UNCHANGED <<sdb, markers>>
  /\ UNCHANGED <<mvars, rd, slot, ring, frontier, pending, tq, infl, committed, lastC, reqLsa, storedC,
                 storedR, crashes>>

\* crash or shutdown, then start again from the stored apply info (committed_lsa = required_lsa, 9811)
SlaveRestart ==
  /\ SlaveOn /\ crashes < MaxCrash
  /\ crashes' = crashes + 1
  /\ rd' = storedR /\ committed' = storedR /\ lastC' = storedC /\ reqLsa' = storedR
  /\ slot' = [t \in Txns |-> EmptySlot]
  /\ ring' = << >> /\ frontier' = NULL /\ pending' = << >> /\ tq' = << >> /\ infl' = << >> /\ resq' = << >>
  /\ wk' = [w \in Workers |-> NoTask]
  /\ UNCHANGED <<mvars, storedC, storedR, sdb, markers>>

SlaveQuiet ==
  /\ rd > N /\ pending = << >> /\ tq = << >> /\ infl = << >> /\ resq = << >>
  /\ \A w \in Workers : wk[w] = NoTask

SlaveNext ==
  \/ ReadRecord
  \/ CollectRetire(TRUE) \/ CollectRetire(FALSE)
  \/ LogCommit
  \/ \E w \in Workers : Take(w) \/ Finish(w)
  \/ SlaveRestart

Done == mdone /\ (MasterOnly \/ SlaveQuiet) /\ UNCHANGED vars

-----------------------------------------------------------------------------

Init ==
  /\ mphase = [t \in Txns |-> "active"]
  /\ started = [t \in Txns |-> FALSE] /\ nops = [t \in Txns |-> 0] /\ mvcc = [t \in Txns |-> FALSE]
  /\ xh = [k \in Keys |-> None] /\ sh = [k \in Keys |-> {}]
  /\ touched = [t \in Txns |-> {}] /\ wl = [t \in Txns |-> {}]
  /\ ovf = [t \in Txns |-> FALSE] /\ stmt = [t \in Txns |-> FALSE] /\ sp = [t \in Txns |-> NoSp]
  /\ pubRem = [t \in Txns |-> {}] /\ reserved = 0
  /\ hw = Zero /\ hr = Zero /\ hs = 0 /\ prevCommit = 0 /\ mrestarted = FALSE
  /\ wseq = [k \in Keys \cup Serials |-> << >>]
  /\ mlog = << >> /\ mdone = FALSE /\ pend = [t \in Txns |-> {}] /\ shipped = [t \in Txns |-> {}]
  /\ rd = 1 /\ slot = [t \in Txns |-> EmptySlot]
  /\ ring = << >> /\ frontier = NULL /\ pending = << >> /\ tq = << >> /\ infl = << >> /\ resq = << >>
  /\ wk = [w \in Workers |-> NoTask]
  /\ committed = 0 /\ lastC = 0 /\ reqLsa = 1 /\ storedC = 0 /\ storedR = 1
  /\ sdb = << >> /\ markers = {} /\ crashes = 0

Next ==
  \/ MasterNext /\ UNCHANGED svars
  \/ SlaveNext
  \/ Done

Spec == Init /\ [][Next]_vars

\* Symmetry sets live in WritesetE2ESym.tla: TLC evaluates every constant definition at start-up, and
\* Permutations of 20-30 transactions would never finish in a simulation run.

-----------------------------------------------------------------------------
(* Properties *)

\* --- master guarantee the slave relies on (assume-guarantee) ---
\* every labeled unit waits for every earlier unit it really conflicts with
DepCover == \A j \in Units : \A i \in Units : (i < j /\ Conflict(i, j)) => mlog[j].dep >= i
\* the label points before its own record (assert_release log_manager.c 5638)
DepBelowSelf == \A j \in 1..N : mlog[j].k \in {"C", "S"} => mlog[j].dep < j
\* a commit-order labeled fragment and a statement commit wait for every earlier unit
BarrierWaitsAll == \A j \in 1..N :
  ((mlog[j].k = "S" /\ mlog[j].co) \/ (mlog[j].k = "C" /\ mlog[j].stmt)) => \A i \in Units : i < j => mlog[j].dep >= i

\* --- slave ---
SdbSet == SetOf(sdb)
Pos(x) == CHOOSE p \in 1..Len(sdb) : sdb[p] = x

NoDuplicate == Len(sdb) = Cardinality(SdbSet)
OnlyUnits == SdbSet \subseteq Units

ConflictOrder ==
  \A p \in 1..Len(sdb) :
    \A i \in Units :
      (i < sdb[p] /\ Conflict(i, sdb[p])) => (i \in SdbSet /\ Pos(i) < p)

PrefixStored == \A b \in Units : b <= storedC => b \in SdbSet
RequiredStored == \A b \in Units : b \notin SdbSet => storedR <= FirstRec(mlog[b].t)

\* no lost apply: when the master has stopped and the slave has drained everything, all units are applied
QuietAllApplied == (mdone /\ SlaveQuiet) => Units \subseteq SdbSet

\* final state: for every key the write the slave applied last is the master's last surviving write, in real
\* write order (write id <<t, 0>>: the outer transaction's change, <<t, i>>: the unit ending at record i)
SlaveLast(k) ==
  LET ps == {p \in 1..Len(sdb) : \E x \in mlog[sdb[p]].wr : x[1] = k} IN
  IF ps = {} THEN << >> ELSE CHOOSE id \in {x[2] : x \in {y \in mlog[sdb[MaxOf(ps)]].wr : y[1] = k}} : TRUE
MasterLast(k) == IF wseq[k] = << >> THEN << >> ELSE Last(wseq[k])
FinalState == (mdone /\ SlaveQuiet) => \A k \in Keys \cup Serials : SlaveLast(k) = MasterLast(k)

\* sanity: with AttachFix no fragment ever carries an outer transaction's change (expected to fail without it)
NoLeftoverInFragment == \A i \in 1..N : mlog[i].k = "S" => \A x \in mlog[i].wr : x[2][2] # 0
\* sanity, expected to fail in keyed mode: every fragment still waits for every earlier unit (no barrier left)
SysopIsBarrier == \A j \in 1..N : mlog[j].k = "S" => \A i \in Units : i < j => mlog[j].dep >= i
\* sanity, expected to fail when a transaction may do two units on one serial: the case is reached
NoSameTxnSerialTwice == \A i, j \in 1..N :
  (i < j /\ mlog[i].k = "S" /\ mlog[j].k = "S" /\ mlog[i].t = mlog[j].t) =>
    ~\E s \in Serials : <<s, "W">> \in mlog[i].keys /\ <<s, "W">> \in mlog[j].keys

\* sanity, expected to fail: the slave applies out of log order
SerialOrder == \A p \in 1..(Len(sdb) - 1) : sdb[p] < sdb[p + 1]
\* sanity, expected to fail: a run reaches the end (master stopped, slave drained); checks simulation depth
NeverFinish == ~(mdone /\ SlaveQuiet /\ Len(sdb) > 0)
\* sanity, expected to fail: some run applies a unit after a restart
NoRestartApply == crashes = 0
=============================================================================
