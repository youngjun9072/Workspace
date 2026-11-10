--------------------------- MODULE MasterDependency ---------------------------
(***************************************************************************)
(* Master-side dependency computation of the writeset parallel applier     *)
(* (PR #8052, branch feature/CBRD-27508-parallel-applylogdb-writeset).     *)
(*                                                                         *)
(* Modeled code (file:line on that branch):                                *)
(*  - key collection, WRITE/REF kinds: locator_sr.c 8309-8350, 9031-9070   *)
(*  - commit-order fallback: writeset.cpp 176 (key limit, NaN, statement   *)
(*    replication replication.c 610)                                       *)
(*  - savepoint rollback key discard: log_manager.c 4276, writeset.cpp 532 *)
(*  - commit path log_commit_local: complete_mvcc 5596, then inside        *)
(*    prior_lsa_mutex find_dependency 5048, label 5049, commit 5050,       *)
(*    record_commit 5051; publish 5640; lock_unlock_all 5649               *)
(*  - dependency: writeset_order.cpp 43-142, probe writeset_history_map    *)
(*    48-66, commit-order dependency writeset_history.cpp 130-142          *)
(*  - history: record_commit 146-162, publish/clear 233-342                *)
(*  - labeled SYSOP_END (serial): log_manager.c 4052-4093, 4905-4916       *)
(*  - restart barrier: log_manager.c 1515-1519                             *)
(*                                                                         *)
(* LSAs are log indices (1, 2, ...); 0 stands for a NULL LSA.              *)
(* Slave rule as in WritesetApply.tla: an entry starts only when every     *)
(* entry with index <= its dependency has been applied.                    *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
  Txns, Keys, Serials, NumWorkers, None,
  KeyLimit,          \* history map capacity (writeset_config key limit)
  AllowRef,          \* REF keys (FK references) may be collected
  AllowOverflow,     \* key-limit / NaN fallback
  AllowStmt,         \* statement replication fallback (applied by re-execution)
  AllowSavepoint,    \* one partial rollback per transaction
  AllowAbort,
  AllowOOM,          \* publish may hit bad_alloc (clear without publishing)
  AllowRestart,      \* one server restart
  WithSlave,
  AllowIncrDml,      \* known defect (WritesetSysop.tla): DML sysop labeled by a pending INCR record
  \* mutants (all FALSE = current code)
  MutVisibleAtMvcc,     \* conflicting writers proceed once complete_mvcc ran (sq_uniq shape)
  MutUnlockBeforePublish,
  MutNoOverflowFloor,   \* record_commit does not raise history_start for commit-order commits
  MutNoSysopFloor,      \* labeled SYSOP_END does not raise history_start
  MutNoClearFloor       \* history clear does not raise history_start

Kinds == IF AllowRef THEN {"W", "R"} ELSE {"W"}

VARIABLES
  phase,     \* active | logged | published | done | aborted
  mvcc,      \* complete_mvcc already ran (commit started)
  xh,        \* xh[k]: X holder of k or None
  sh,        \* sh[k]: S holders of k (FK reference)
  touched,   \* touched[t]: <<k, kind>> pairs t really changed / referenced (ground truth)
  wset,      \* wset[t]: collected entries still held for this commit
  ovf,       \* wset_overflow
  stmt,      \* statement replication inside t
  sp,        \* sp[t]: savepoint snapshot <<touched, wset>> or None
  spUsed,
  serialDone,
  hw, hr,    \* history map: write_seq / ref_seq per key (0 = absent)
  hs,        \* history_start
  prevCommit,\* prev_commit_lsa
  restarted,
  pending,   \* pending[t]: an INCR record left NEED_FLUSH by an attached system operation
  mlog,      \* [kind: "C" | "S", txn, dep, keys, stmt]
  running, applied

vars == <<phase, mvcc, xh, sh, touched, wset, ovf, stmt, sp, spUsed, serialDone, hw, hr, hs, prevCommit,
          restarted, pending, mlog, running, applied>>
master == <<phase, mvcc, xh, sh, touched, wset, ovf, stmt, sp, spUsed, serialDone, hw, hr, hs, prevCommit,
            restarted, pending, mlog>>
slave == <<running, applied>>

Max2(a, b) == IF a >= b THEN a ELSE b
AppliedSet == {applied[i] : i \in 1..Len(applied)}

Init ==
  /\ phase = [t \in Txns |-> "active"]
  /\ mvcc = [t \in Txns |-> FALSE]
  /\ xh = [k \in Keys \cup Serials |-> None]
  /\ sh = [k \in Keys |-> {}]
  /\ touched = [t \in Txns |-> {}]
  /\ wset = [t \in Txns |-> {}]
  /\ ovf = [t \in Txns |-> FALSE]
  /\ stmt = [t \in Txns |-> FALSE]
  /\ sp = [t \in Txns |-> None]
  /\ spUsed = [t \in Txns |-> FALSE]
  /\ serialDone = [t \in Txns |-> FALSE]
  /\ hw = [k \in Keys \cup Serials |-> 0]
  /\ hr = [k \in Keys \cup Serials |-> 0]
  /\ hs = 0
  /\ prevCommit = 0
  /\ restarted = FALSE
  /\ pending = [t \in Txns |-> FALSE]
  /\ mlog = << >>
  /\ running = {}
  /\ applied = << >>

-----------------------------------------------------------------------------
(* Locks.  In the current code a conflicting writer (row lock, or the       *)
(* MVCCID self-lock of CBRD-26942/27034) waits until lock_unlock_all of the *)
(* owner.  MutVisibleAtMvcc lets it go once the owner ran complete_mvcc.    *)

LockGone(u) == u # None /\ (phase[u] \in {"done", "aborted"} \/ (MutVisibleAtMvcc /\ mvcc[u]))

XFree(t, k) == (xh[k] = None \/ xh[k] = t \/ LockGone(xh[k]))
              /\ \A u \in sh[k] : u = t \/ LockGone(u)
SFree(t, k) == xh[k] = None \/ xh[k] = t \/ LockGone(xh[k])

\* A row change (kind W) or an FK reference (kind R) of key k.
Access(t, k, kind) ==
  /\ phase[t] = "active" /\ ~mvcc[t]
  /\ <<k, kind>> \notin touched[t]
  /\ IF kind = "W" THEN XFree(t, k) ELSE SFree(t, k)
  /\ IF kind = "W"
       THEN /\ xh' = [xh EXCEPT ![k] = t]
            /\ sh' = [sh EXCEPT ![k] = {u \in @ : ~LockGone(u)}]
       ELSE /\ xh' = IF xh[k] # None /\ xh[k] # t THEN [xh EXCEPT ![k] = None] ELSE xh
            /\ sh' = [sh EXCEPT ![k] = @ \cup {t}]
  /\ touched' = [touched EXCEPT ![t] = @ \cup {<<k, kind>>}]
  \* wset_add_write_key / wset_add_ref_key: nothing is collected once overflowed
  /\ wset' = IF ovf[t] THEN wset ELSE [wset EXCEPT ![t] = @ \cup {<<k, kind>>}]
  /\ UNCHANGED <<phase, mvcc, ovf, stmt, sp, spUsed, serialDone, hw, hr, hs, prevCommit, restarted, mlog, pending>>

\* wset_switch_to_commit_order (writeset.cpp 176): drop the keys, keep the flag.
Overflow(t) ==
  /\ AllowOverflow
  /\ phase[t] = "active" /\ ~mvcc[t] /\ ~ovf[t]
  /\ ovf' = [ovf EXCEPT ![t] = TRUE]
  /\ wset' = [wset EXCEPT ![t] = {}]
  /\ UNCHANGED <<phase, mvcc, xh, sh, touched, stmt, sp, spUsed, serialDone, hw, hr, hs, prevCommit, restarted, mlog, pending>>

\* repl_log_insert_statement (replication.c 610): the statement is re-executed on the slave.
Statement(t) ==
  /\ AllowStmt
  /\ phase[t] = "active" /\ ~mvcc[t] /\ ~stmt[t]
  /\ stmt' = [stmt EXCEPT ![t] = TRUE]
  /\ ovf' = [ovf EXCEPT ![t] = TRUE]
  /\ wset' = [wset EXCEPT ![t] = {}]
  /\ UNCHANGED <<phase, mvcc, xh, sh, touched, sp, spUsed, serialDone, hw, hr, hs, prevCommit, restarted, mlog, pending>>

\* Savepoint and partial rollback: changes and keys after the savepoint are dropped
\* (wset_discard_keys_after_lsa); locks are kept; an overflow raised stays raised.
Savepoint(t) ==
  /\ AllowSavepoint
  /\ phase[t] = "active" /\ ~mvcc[t] /\ sp[t] = None /\ ~spUsed[t]
  /\ sp' = [sp EXCEPT ![t] = <<touched[t], wset[t], stmt[t]>>]
  /\ UNCHANGED <<phase, mvcc, xh, sh, touched, wset, ovf, stmt, spUsed, serialDone, hw, hr, hs, prevCommit, restarted, mlog, pending>>

RollbackToSavepoint(t) ==
  /\ phase[t] = "active" /\ ~mvcc[t] /\ sp[t] # None
  /\ touched' = [touched EXCEPT ![t] = sp[t][1]]
  /\ wset' = [wset EXCEPT ![t] = IF ovf[t] THEN {} ELSE sp[t][2]]
  /\ stmt' = [stmt EXCEPT ![t] = sp[t][3]]
  /\ sp' = [sp EXCEPT ![t] = None]
  /\ spUsed' = [spUsed EXCEPT ![t] = TRUE]
  /\ UNCHANGED <<phase, mvcc, xh, sh, ovf, serialDone, hw, hr, hs, prevCommit, restarted, mlog, pending>>

\* Commit-order dependency (writeset_history.cpp 130-142): prev_commit raised to history_start.
CommitOrderDep == IF hs # 0 /\ (prevCommit = 0 \/ prevCommit < hs) THEN hs ELSE prevCommit

\* A labeled serial system operation (log_append_wset_label_and_sysop_end): the serial row lock is
\* taken and released inside it, its key is discarded, and the history floor is raised to it.
SerialSysop(t, s) ==
  /\ phase[t] = "active" /\ ~mvcc[t] /\ ~serialDone[t]
  /\ xh[s] = None
  /\ LET seq == Len(mlog) + 1 IN
     /\ mlog' = Append(mlog, [kind |-> "S", txn |-> t, dep |-> CommitOrderDep,
                              keys |-> {<<s, "W">>}, stmt |-> FALSE])
     /\ hs' = IF MutNoSysopFloor THEN hs ELSE Max2(hs, seq)
  /\ serialDone' = [serialDone EXCEPT ![t] = TRUE]
  /\ UNCHANGED <<phase, mvcc, xh, sh, touched, wset, ovf, stmt, sp, spUsed, hw, hr, prevCommit, restarted, pending>>

\* INCR/DECR ending attached to its transaction leaves its record NEED_FLUSH (bounded by serialDone).
IncrAttach(t) ==
  /\ AllowIncrDml
  /\ phase[t] = "active" /\ ~mvcc[t] /\ ~pending[t] /\ ~serialDone[t]
  /\ pending' = [pending EXCEPT ![t] = TRUE]
  /\ serialDone' = [serialDone EXCEPT ![t] = TRUE]
  /\ UNCHANGED <<phase, mvcc, xh, sh, touched, wset, ovf, stmt, sp, spUsed, hw, hr, hs, prevCommit, restarted, mlog>>

\* An ordinary DML statement run in a system operation while an INCR record is pending: its SYSOP_END
\* writes the pending record and is labeled (log_manager.c 4052-4077), and the keys collected inside it
\* are discarded (4093) although its row lock is kept until the outer commit.
IncrDmlSysop(t, k) ==
  /\ AllowIncrDml
  /\ phase[t] = "active" /\ ~mvcc[t] /\ pending[t]
  /\ <<k, "W">> \notin touched[t]
  /\ XFree(t, k)
  /\ xh' = [xh EXCEPT ![k] = t]
  /\ sh' = [sh EXCEPT ![k] = {u \in @ : ~LockGone(u)}]
  /\ touched' = [touched EXCEPT ![t] = @ \cup {<<k, "W">>}]
  /\ LET seq == Len(mlog) + 1 IN
     /\ mlog' = Append(mlog, [kind |-> "S", txn |-> t, dep |-> CommitOrderDep, keys |-> {}, stmt |-> FALSE])
     /\ hs' = Max2(hs, seq)
  /\ pending' = [pending EXCEPT ![t] = FALSE]
  /\ UNCHANGED <<phase, mvcc, wset, ovf, stmt, sp, spUsed, serialDone, hw, hr, prevCommit, restarted>>

Abort(t) ==
  /\ AllowAbort
  /\ phase[t] = "active" /\ ~mvcc[t]
  /\ phase' = [phase EXCEPT ![t] = "aborted"]
  /\ xh' = [k \in DOMAIN xh |-> IF xh[k] = t THEN None ELSE xh[k]]
  /\ sh' = [k \in Keys |-> sh[k] \ {t}]
  /\ UNCHANGED <<mvcc, touched, wset, ovf, stmt, sp, spUsed, serialDone, hw, hr, hs, prevCommit, restarted, mlog, pending>>

\* logtb_complete_mvcc (log_manager.c 5596), before the commit record.
CompleteMvcc(t) ==
  /\ phase[t] = "active" /\ ~mvcc[t]
  /\ touched[t] # {} \/ ovf[t] \/ serialDone[t]
  /\ mvcc' = [mvcc EXCEPT ![t] = TRUE]
  /\ UNCHANGED <<phase, xh, sh, touched, wset, ovf, stmt, sp, spUsed, serialDone, hw, hr, hs, prevCommit, restarted, mlog, pending>>

\* probe (writeset_history_map.cpp 48-66): <<candidate, from ref slot>>, or <<0, FALSE>> on a miss.
Probe(e) ==
  LET k == e[1] IN
  IF hw[k] = 0 /\ hr[k] = 0 THEN <<0, FALSE>>
  ELSE IF e[2] = "R" THEN <<hw[k], FALSE>>
  ELSE IF hr[k] > hw[k] THEN <<hr[k], TRUE>> ELSE <<hw[k], FALSE>>

\* wset_order_find_dependency_in_range (writeset_order.cpp 43-125).  The loop keeps the first entry (in
\* collection order) that reaches the final maximum; the order is free, so any such entry may be it.
WsDeps(t) ==
  LET cands == {Probe(e) : e \in wset[t]}
      top   == Max2(hs, IF cands = {} THEN 0 ELSE
                          CHOOSE m \in {c[1] : c \in cands} : \A c \in cands : c[1] <= m)
      refs  == IF top > hs THEN {c[2] : c \in {x \in cands : x[1] = top}} ELSE {FALSE}
      bound == IF prevCommit = 0 \/ top < prevCommit THEN top ELSE prevCommit
      wb    == IF hs # 0 /\ (bound = 0 \/ bound < hs) THEN hs ELSE bound
  IN {IF r THEN top ELSE wb : r \in refs}

\* log_append_repl_info_and_commit_log (log_manager.c 5030-5054), all inside prior_lsa_mutex.
CommitRecord(t) ==
  /\ phase[t] = "active" /\ mvcc[t]
  /\ LET seq == Len(mlog) + 1 IN
     \E d \in (IF ovf[t] THEN {CommitOrderDep} ELSE WsDeps(t)) :
       /\ mlog' = Append(mlog, [kind |-> "C", txn |-> t, dep |-> d, keys |-> touched[t], stmt |-> stmt[t]])
       /\ prevCommit' = Max2(prevCommit, seq)
       /\ hs' = IF ovf[t] /\ ~MutNoOverflowFloor THEN Max2(hs, seq) ELSE hs
  /\ phase' = [phase EXCEPT ![t] = "logged"]
  /\ UNCHANGED <<mvcc, xh, sh, touched, wset, ovf, stmt, sp, spUsed, serialDone, hw, hr, restarted, pending>>

MapSize == Cardinality({k \in Keys \cup Serials : hw[k] # 0 \/ hr[k] # 0})
ClearFloor == IF MutNoClearFloor THEN hs ELSE Max2(hs, prevCommit)
CommitSeq(t) == CHOOSE i \in 1..Len(mlog) : mlog[i].txn = t /\ mlog[i].kind = "C"

PublishedW(t, c) == [k \in DOMAIN hw |-> IF <<k, "W">> \in wset[t] THEN Max2(hw[k], c) ELSE hw[k]]
PublishedR(t, c) == [k \in DOMAIN hr |-> IF <<k, "R">> \in wset[t] THEN Max2(hr[k], c) ELSE hr[k]]
Zero == [k \in Keys \cup Serials |-> 0]

\* wset_order_publish_commit_keys (log_manager.c 5640) -> wset_history_publish_keys (writeset_history.cpp 323).
Publish(t) ==
  /\ phase[t] = "logged"
  /\ LET c == CommitSeq(t) IN
     IF ovf[t] THEN
        \* wset_history_clear_for_commit_order
        /\ hw' = Zero /\ hr' = Zero /\ hs' = ClearFloor
     ELSE IF wset[t] = {} THEN UNCHANGED <<hw, hr, hs>>
     ELSE IF MapSize + Cardinality(wset[t]) > KeyLimit THEN
        \* capacity clear, then publish
        /\ hw' = [k \in DOMAIN hw |-> IF <<k, "W">> \in wset[t] THEN c ELSE 0]
        /\ hr' = [k \in DOMAIN hr |-> IF <<k, "R">> \in wset[t] THEN c ELSE 0]
        /\ hs' = ClearFloor
     ELSE
        \/ /\ hw' = PublishedW(t, c) /\ hr' = PublishedR(t, c) /\ UNCHANGED hs
        \/ /\ AllowOOM   \* bad_alloc: clear only
           /\ hw' = Zero /\ hr' = Zero /\ hs' = ClearFloor
  /\ phase' = [phase EXCEPT ![t] = "published"]
  /\ UNCHANGED <<mvcc, xh, sh, touched, wset, ovf, stmt, sp, spUsed, serialDone, prevCommit, restarted, mlog, pending>>

\* lock_unlock_all (log_manager.c 5649).  With MutUnlockBeforePublish it may run before the publish.
Unlock(t) ==
  /\ IF MutUnlockBeforePublish THEN phase[t] \in {"logged", "published"} ELSE phase[t] = "published"
  /\ xh' = [k \in DOMAIN xh |-> IF xh[k] = t THEN None ELSE xh[k]]
  /\ sh' = [k \in Keys |-> sh[k] \ {t}]
  /\ phase' = [phase EXCEPT ![t] = IF phase[t] = "logged" THEN "unlockedEarly" ELSE "done"]
  /\ UNCHANGED <<mvcc, touched, wset, ovf, stmt, sp, spUsed, serialDone, hw, hr, hs, prevCommit, restarted, mlog, pending>>

\* Publish after an early unlock (mutant only).
PublishLate(t) ==
  /\ phase[t] = "unlockedEarly"
  /\ LET c == CommitSeq(t) IN
     /\ hw' = IF ovf[t] THEN Zero ELSE PublishedW(t, c)
     /\ hr' = IF ovf[t] THEN Zero ELSE PublishedR(t, c)
     /\ hs' = IF ovf[t] THEN ClearFloor ELSE hs
  /\ phase' = [phase EXCEPT ![t] = "done"]
  /\ UNCHANGED <<mvcc, xh, sh, touched, wset, ovf, stmt, sp, spUsed, serialDone, prevCommit, restarted, mlog, pending>>

\* Server restart: in-flight transactions are rolled back, the in-memory history is empty, and
\* history_start is raised to the end of the recovered log (log_manager.c 1515-1519).
Restart ==
  /\ AllowRestart /\ ~restarted /\ Len(mlog) > 0
  /\ restarted' = TRUE
  /\ phase' = [t \in Txns |-> IF phase[t] \in {"logged", "published", "unlockedEarly", "done"} THEN "done" ELSE "aborted"]
  /\ xh' = [k \in DOMAIN xh |-> None]
  /\ sh' = [k \in Keys |-> {}]
  /\ hw' = Zero /\ hr' = Zero
  /\ prevCommit' = 0
  /\ hs' = Len(mlog)
  /\ UNCHANGED <<mvcc, touched, wset, ovf, stmt, sp, spUsed, serialDone, mlog, pending>>

-----------------------------------------------------------------------------
(* Slave *)

Ready(i) == \A j \in 1..mlog[i].dep : j \in AppliedSet

Start(i) ==
  /\ WithSlave
  /\ Cardinality(running) < NumWorkers
  /\ i \notin AppliedSet /\ i \notin running
  /\ Ready(i)
  /\ running' = running \cup {i}
  /\ UNCHANGED <<master, applied>>

Finish(i) ==
  /\ i \in running
  /\ applied' = Append(applied, i)
  /\ running' = running \ {i}
  /\ UNCHANGED master

MasterNext ==
  \/ \E t \in Txns, k \in Keys, kd \in Kinds : Access(t, k, kd)
  \/ \E t \in Txns : \/ Overflow(t) \/ Statement(t) \/ Savepoint(t) \/ RollbackToSavepoint(t)
                     \/ Abort(t) \/ CompleteMvcc(t) \/ CommitRecord(t) \/ Publish(t) \/ Unlock(t)
                     \/ PublishLate(t) \/ IncrAttach(t)
  \/ \E t \in Txns, k \in Keys : IncrDmlSysop(t, k)
  \/ \E t \in Txns, s \in Serials : SerialSysop(t, s)
  \/ Restart

Next ==
  \/ MasterNext /\ UNCHANGED slave
  \/ \E i \in 1..Len(mlog) : Start(i)
  \/ \E i \in running : Finish(i)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Properties *)

KeyConflict(a, b) == \E x \in a, y \in b : x[1] = y[1] /\ (x[2] = "W" \/ y[2] = "W")
\* Two entries must keep master order: a common key with a write, or a re-executed statement.
Conflict(i, j) == KeyConflict(mlog[i].keys, mlog[j].keys) \/ mlog[i].stmt \/ mlog[j].stmt

\* A later entry never gets a dependency below an earlier conflicting entry.
DepCover == \A j \in 1..Len(mlog) : \A i \in 1..(j - 1) : Conflict(i, j) => mlog[j].dep >= i

\* The label always points before its own record (assert_release at log_manager.c 5638).
DepBelowSelf == \A j \in 1..Len(mlog) : mlog[j].dep < j

\* A commit-order entry (statement, overflow, labeled SYSOP_END) waits for every earlier entry.
BarrierWaitsAll == \A j \in 1..Len(mlog) :
  (mlog[j].kind = "S" \/ mlog[j].stmt) => mlog[j].dep >= j - 1

Pos(i) == CHOOSE p \in 1..Len(applied) : applied[p] = i
ConflictOrder ==
  \A p \in 1..Len(applied) :
    LET j == applied[p] IN
      \A i \in 1..(j - 1) : Conflict(i, j) => (i \in AppliedSet /\ Pos(i) < p)

TxnSym == Permutations(Txns)

\* Sanity, expected to FAIL when the slave is on: entries do get applied out of log order.
SerialOrder == \A p \in 1..Len(applied) : applied[p] = p
=============================================================================
