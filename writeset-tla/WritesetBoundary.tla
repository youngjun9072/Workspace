--------------------------- MODULE WritesetBoundary ---------------------------
(***************************************************************************)
(* Boundary model of the writeset parallel applier of PR #8052            *)
(* (feature/CBRD-27508-parallel-applylogdb-writeset, HEAD 6bd39a696).     *)
(*                                                                         *)
(* WritesetE2E.tla checks the dependency design end to end with one       *)
(* serial fragment shape. This model keeps the slave of WritesetE2E       *)
(* (ring, gate, pending, in-flight, workers, retire, required_lsa,        *)
(* stored apply info, markers, crash/restart) and replaces the master by  *)
(* a generator of every log SHAPE the master can write around system      *)
(* operations, so that the slave's slot / fragment / restart-position     *)
(* logic is checked at its boundaries:                                    *)
(*                                                                         *)
(*  1. fragments (serial, instant INCR, container sysop carrying INCR     *)
(*     leftovers), long-transaction split (LA_MAX_REPL_ITEMS), outer      *)
(*     ABORT, restart position (la_find_required_lsa);                     *)
(*  2. worker apply failures, retry/skip, marker in the same slave         *)
(*     transaction, crash at every worker step;                            *)
(*  3. failover: the DONE gate (drain_complete) before promotion.          *)
(*                                                                         *)
(* Master log shapes (code at 6bd39a696, log_manager.c unless named):     *)
(*  - "X": the transaction's first record (prev_tranlsa NULL). The slave   *)
(*    creates the transaction's slot only here (log_applier.c 7561-7584).  *)
(*  - "D": a replication record. At a non-empty sysop end the NEED_FLUSH   *)
(*    records (the operation's own, and INCR records left NEED_FLUSH by an *)
(*    INCR whose instant lock mode was stopped and that ended attached,    *)
(*    query_executor.c 20545-20565, lock_manager.c 3984) are appended by   *)
(*    log_append_repl_info (4030), then label + SYSOP_END atomically      *)
(*    (4052-4077, 4905-4916). Other transactions' records may come         *)
(*    between the D records and the SYSOP_END; a master crash in between   *)
(*    leaves D records followed by the recovery LOG_ABORT.                 *)
(*  - "S": WSET label + labeled SYSOP_END (one prior_lsa_mutex region).   *)
(*    It follows at least one D of the same transaction since its last     *)
(*    boundary (a label is written only when records were flushed, 4052). *)
(*    Its dependency is the commit-order barrier max(prev_commit,          *)
(*    history_start) (writeset_history.cpp 129-142) and history_start is  *)
(*    raised to it (4913). Container and nested sysops produce the same   *)
(*    shape: an inner operation ending while the flush mark is open        *)
(*    writes nothing (4003-4011), an attached end writes nothing          *)
(*    (4311-4345), an aborted one writes an unlabeled SYSOP_END and drops  *)
(*    its records (4251-4302), so only "D+ S" reaches the log.            *)
(*  - "C": the commit block: the COMMIT_NEED_FLUSH / remaining NEED_FLUSH  *)
(*    records, the label and LOG_COMMIT in one prior_lsa_mutex region      *)
(*    (5030-5054). Its records are appended contiguously in one step.    *)
(*  - "A": LOG_ABORT (user rollback, or master recovery of a loser,       *)
(*    log_recovery.c 5049).                                                *)
(* LSAs are record indices, 0 is NULL.                                    *)
(*                                                                         *)
(* Slave (log_applier.c unless named):                                    *)
(*  - la_set_repl_log 4573-4604: item dropped without a slot; at           *)
(*    LA_MAX_REPL_ITEMS (here MaxItems) the slot becomes a long           *)
(*    transaction: only the head item and last_lsa are kept, the items    *)
(*    are read back from the log when applied (7145-7223).                 *)
(*  - la_coordinator_process_sysop_end 7323-7432, la_detach_sysop_fragment *)
(*    7245-7311: fragment start_lsa = head item (7283 long, 7307 short);   *)
(*    without buffered items: la_coordinator_complete_without_task.        *)
(*  - LOG_COMMIT 7623-7637 / 7477-7537, LOG_ABORT 7639-7650 frees the slot.*)
(*  - la_find_required_lsa 2312-2380: slots, in-flight tasks, pending.     *)
(*  - worker la_apply_worker_apply_task 905-950, la_apply_repl_log         *)
(*    6967-7114, la_flush_repl_items 5910-6040, xlocator_repl_force        *)
(*    (locator_sr.c 7061-7270).                                            *)
(*  - retire log_applier_coordinator.cpp 516-560 (an error result at the   *)
(*    head stops the applier), restart 2852-2947, 9761-9811.               *)
(*  - DONE gate la_change_state 7874-7912 (la_coordinator_drain_complete,  *)
(*    log_applier_coordinator.cpp 275-278).                                *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
  Txns, Keys,
  MaxD,             \* D records written at sysop ends, per transaction
  MaxS,             \* labeled SYSOP_ENDs per transaction
  MaxCD,            \* D records in one commit block
  MaxItems,         \* LA_MAX_REPL_ITEMS (1000 in the code)
  AllowAbort,
  Interleave,       \* slave runs while the master runs (FALSE: after the master stops)
  NumWorkers, QCap, RingCap, MaxCrash,
  FixFragStart,     \* "none" (6bd39a696) | "short" (review suggestion on 7307 only) | "both" (7283 and 7307)
  FailModel,        \* scenario 2: stepwise worker with failures
  AllowIgnoreFail,  \* a row fails with a non-retry error: counted, dropped, the transaction goes on
  AllowFlushRestart,\* the flush fails with a restart-class error, or the whole call fails (deadlock victim)
  AllowCommitFail,  \* the marker insert or the commit fails (before, or after the server committed)
  AllowServerAbortRetry, \* a retry-class error after the server rolled the slave transaction back (known candidate)
  MaxErr,
  Failover,         \* scenario 3: the master dies, the slave reports DONE and is promoted
  Mut,              \* "none" | "reqNoTasks" | "noAbortOnError" | "doneNoInflight" | "doneNoPending"
  None
NULL == 1000
NoTask == [lsa |-> 0]

Max2(a, b) == IF a >= b THEN a ELSE b
MaxOf(S) == IF S = {} THEN 0 ELSE CHOOSE m \in S : \A x \in S : x <= m
MinOf(S) == CHOOSE m \in S : \A x \in S : m <= x
Last(s) == s[Len(s)]
RemoveAt(s, j) == [i \in 1..(Len(s) - 1) |-> IF i < j THEN s[i] ELSE s[i + 1]]
SetOf(s) == {s[i] : i \in 1..Len(s)}
RECURSIVE AppendN(_, _, _)
AppendN(s, r, n) == IF n = 0 THEN s ELSE AppendN(Append(s, r), r, n - 1)

VARIABLES
  \* ---- master ----
  mst,      \* idle | open | end
  nd, ns,   \* D records / labeled SYSOP_ENDs written
  pend,     \* a D was written since the transaction's last boundary (S or C)
  mlog,     \* [k: "X" | "D" | "S" | "C" | "A", t, dep, keys]
  mdone,
  \* ---- slave ----
  rd, slot, ring, frontier, pending, tq, infl, wk, resq,
  committed, lastC, reqLsa, storedC, storedR,
  sdb,      \* committed slave transactions: [u |-> unit LSA, its |-> items applied]
  markers, crashes,
  \* ---- worker failures (scenario 2) ----
  wapp,     \* items applied in the worker's open slave transaction
  wrem,     \* items the worker still has to apply
  wign,     \* ghost: items dropped by a counted non-retry failure
  nerr, halted,
  \* ---- failover (scenario 3) ----
  promoted

mvars == <<mst, nd, ns, pend, mlog, mdone>>
svars == <<rd, slot, ring, frontier, pending, tq, infl, wk, resq, committed, lastC, reqLsa, storedC, storedR,
           sdb, markers, crashes, wapp, wrem, wign, nerr, halted, promoted>>
vars == <<mvars, svars>>

-----------------------------------------------------------------------------
(* Master: log shapes *)

N == Len(mlog)
Rec(k, t, dep, keys) == [k |-> k, t |-> t, dep |-> dep, keys |-> keys]
\* commit-order barrier: the last COMMIT or labeled SYSOP_END
Barrier(log) == MaxOf({i \in 1..Len(log) : log[i].k \in {"S", "C"}})
LastS(log) == MaxOf({i \in 1..Len(log) : log[i].k = "S"})

Start(t) ==
  /\ mst[t] = "idle"
  /\ mst' = [mst EXCEPT ![t] = "open"]
  /\ mlog' = Append(mlog, Rec("X", t, 0, {}))
  /\ UNCHANGED <<nd, ns, pend, mdone>>

\* a NEED_FLUSH record written at a sysop end (log_manager.c 4013-4030)
SysD(t) ==
  /\ mst[t] = "open" /\ nd[t] < MaxD
  /\ mlog' = Append(mlog, Rec("D", t, 0, {}))
  /\ nd' = [nd EXCEPT ![t] = @ + 1]
  /\ pend' = [pend EXCEPT ![t] = TRUE]
  /\ UNCHANGED <<mst, ns, mdone>>

\* label + labeled SYSOP_END (log_append_wset_label_and_sysop_end 4905-4916)
SysEnd(t) ==
  /\ mst[t] = "open" /\ pend[t] /\ ns[t] < MaxS
  /\ mlog' = Append(mlog, Rec("S", t, Barrier(mlog), {}))
  /\ ns' = [ns EXCEPT ![t] = @ + 1]
  /\ pend' = [pend EXCEPT ![t] = FALSE]
  /\ UNCHANGED <<mst, nd, mdone>>

\* commit block (log_append_repl_info_and_commit_log 5030-5054). Records flushed at a sysop end are always
\* followed by their labeled SYSOP_END before the commit, so ~pend. The dependency is the exact writeset one
\* (WritesetE2E checks the master computes at least this): the last conflicting commit, raised to the last
\* labeled SYSOP_END (history_start floor, writeset_order.cpp 114-118).
Commit(t) ==
  /\ mst[t] = "open" /\ ~pend[t]
  /\ \E c \in 0..MaxCD :
       LET base == AppendN(mlog, Rec("D", t, 0, {}), c)
           idx == Len(base) + 1
       IN \E ks \in (IF c > 0 THEN {{k} : k \in Keys} ELSE {{}}) :
            LET conf == {i \in 1..Len(base) : base[i].k = "C" /\ base[i].keys \cap ks # {}}
                dep == Max2(LastS(base), MaxOf(conf))
            IN mlog' = Append(base, Rec("C", t, dep, ks))
  /\ mst' = [mst EXCEPT ![t] = "end"]
  /\ UNCHANGED <<nd, ns, pend, mdone>>

Abort(t) ==
  /\ AllowAbort /\ mst[t] = "open"
  /\ mlog' = Append(mlog, Rec("A", t, 0, {}))
  /\ mst' = [mst EXCEPT ![t] = "end"]
  /\ UNCHANGED <<nd, ns, pend, mdone>>

\* the master stops; in Failover mode it dies and may leave transactions open (no LOG_ABORT is written).
\* Its working state is reset so runs giving the same log merge.
MasterFinish ==
  /\ ~mdone /\ (Failover \/ \A t \in Txns : mst[t] \in {"idle", "end"})
  /\ mdone' = TRUE
  /\ mst' = [t \in Txns |-> "end"] /\ nd' = [t \in Txns |-> 0] /\ ns' = [t \in Txns |-> 0]
  /\ pend' = [t \in Txns |-> FALSE]
  /\ UNCHANGED mlog

MasterNext ==
  \/ \E t \in Txns : Start(t) \/ SysD(t) \/ SysEnd(t) \/ Commit(t) \/ Abort(t)
  \/ MasterFinish

-----------------------------------------------------------------------------
(* Static facts about the log *)

Started(t) == \E i \in 1..N : mlog[i].t = t
FirstRec(t) == MinOf({i \in 1..N : mlog[i].t = t})
Ended(t) == \E i \in 1..N : mlog[i].t = t /\ mlog[i].k \in {"C", "A"}
PrevBoundary(i) == MaxOf({j \in 1..(i - 1) : mlog[j].t = mlog[i].t /\ mlog[j].k \in {"S", "C"}})
\* the records a boundary carries: the transaction's D records since its previous boundary
ItemsOf(i) == {j \in (PrevBoundary(i) + 1)..(i - 1) : mlog[j].t = mlog[i].t /\ mlog[j].k = "D"}
IsUnit(i) == mlog[i].k \in {"S", "C"} /\ ItemsOf(i) # {}
Units == {i \in 1..N : IsUnit(i)}
\* a labeled SYSOP_END is a barrier both ways; commits conflict by key; same transaction is ordered
Conflict(i, j) ==
  \/ mlog[i].t = mlog[j].t
  \/ mlog[i].k = "S" \/ mlog[j].k = "S"
  \/ mlog[i].keys \cap mlog[j].keys # {}

-----------------------------------------------------------------------------
(* Slave *)

SlaveOn == Interleave \/ mdone
Workers == 1..NumWorkers
\* act: slot exists (tranid > 0); start: start_lsa; its: buffered items; lng: is_long_trans; head: head item;
\* last: last_lsa; n: num_items; frag: last_sysop_fragment_lsa
EmptySlot == [act |-> FALSE, start |-> 0, its |-> {}, lng |-> FALSE, head |-> 0, last |-> 0, n |-> 0, frag |-> 0]

\* la_set_repl_log (4573-4604)
AddItem(s, i) ==
  IF ~s.act THEN s
  ELSE IF s.lng THEN [s EXCEPT !.last = i]
  ELSE IF s.n >= MaxItems THEN [s EXCEPT !.lng = TRUE, !.last = i, !.its = {s.head}]
  ELSE [s EXCEPT !.its = @ \cup {i}, !.n = @ + 1, !.head = IF s.head = 0 THEN i ELSE s.head]

\* the items a worker applies from a slot: a long transaction reads the trid's replication records back from
\* the log from the head item up to last_lsa (la_get_next_repl_item_from_log 7160-7223)
SlotItems(t, s) ==
  IF s.lng THEN {j \in s.head..s.last : mlog[j].t = t /\ mlog[j].k = "D"} ELSE s.its

\* fragment->start_lsa: head item (7283, 7307) or the review fix (outer slot start)
FragStart(s) ==
  IF FixFragStart = "both" \/ (FixFragStart = "short" /\ ~s.lng) THEN s.start ELSE s.head

GateOK(dep, fr) == dep = 0 \/ (fr # NULL /\ dep <= fr)

RECURSIVE Advance(_, _)
Advance(r, fr) ==
  IF r # << >> /\ Head(r).done THEN Advance(Tail(r), Head(r).lsa) ELSE [r |-> r, fr |-> fr]

MarkDone(r, lsa) == [i \in 1..Len(r) |-> IF r[i].lsa = lsa THEN [r[i] EXCEPT !.done = TRUE] ELSE r[i]]

RECURSIVE Drain(_, _, _, _)
Drain(p, q, inf, fr) ==
  LET idx == {j \in 1..Len(p) : GateOK(p[j].dep, fr)} IN
  IF Len(q) >= QCap \/ idx = {} THEN [p |-> p, q |-> q, inf |-> inf]
  ELSE LET j == MinOf(idx) IN
       Drain(RemoveAt(p, j), Append(q, p[j]), Append(inf, [task |-> p[j], res |-> "none"]), fr)

\* la_coordinator_submit_task (as WritesetE2E)
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
          /\ infl' = Append(infl, [task |-> tk, res |-> "none"])
          /\ pending' = pending
     ELSE LET d == Drain(pending, tq, infl, fr1) IN
          IF GateOK(dep1, fr1) /\ Len(d.q) < QCap
          THEN /\ tq' = Append(d.q, tk)
               /\ infl' = Append(d.inf, [task |-> tk, res |-> "none"])
               /\ pending' = d.p
          ELSE /\ tq' = d.q /\ infl' = d.inf
               /\ pending' = Append(d.p, tk)

CompleteWithoutTask(lsa, s1, t) ==
  LET fr1 == IF frontier = NULL THEN committed ELSE frontier
      a == Advance(Append(ring, [lsa |-> lsa, done |-> TRUE]), fr1)
      d == Drain(pending, tq, infl, a.fr)
  IN /\ ring' = a.r /\ frontier' = a.fr
     /\ slot' = [slot EXCEPT ![t] = s1]
     /\ tq' = d.q /\ infl' = d.inf /\ pending' = d.p

CoordOn == SlaveOn /\ ~halted /\ ~promoted

ReadRecord ==
  /\ CoordOn /\ rd <= N
  /\ LET i == rd
         r == mlog[i]
         t == r.t
         \* la_add_apply_list only for a record with prev_tranlsa NULL (7561-7584)
         s0 == IF i = FirstRec(t) THEN [EmptySlot EXCEPT !.act = TRUE, !.start = i] ELSE slot[t]
     IN
     /\ rd' = rd + 1
     /\ CASE r.k = "X" ->
              /\ slot' = [slot EXCEPT ![t] = s0]
              /\ UNCHANGED <<ring, frontier, pending, tq, infl>>
          [] r.k = "D" ->
              /\ slot' = [slot EXCEPT ![t] = AddItem(s0, i)]
              /\ UNCHANGED <<ring, frontier, pending, tq, infl>>
          [] r.k = "A" ->     \* la_free_repl_items_by_tranid -> la_clear_applied_info
              /\ slot' = [slot EXCEPT ![t] = EmptySlot]
              /\ UNCHANGED <<ring, frontier, pending, tq, infl>>
          [] r.k = "S" /\ i > committed ->
              /\ Len(ring) < RingCap
              /\ IF s0.act /\ s0.head # 0
                 THEN Submit([lsa |-> i, t |-> t, kind |-> "S", dep |-> r.dep, items |-> SlotItems(t, s0),
                              hasApply |-> TRUE, start |-> FragStart(s0)],
                             [s0 EXCEPT !.its = {}, !.n = 0, !.lng = FALSE, !.head = 0, !.last = 0, !.frag = i], t)
                 ELSE CompleteWithoutTask(i, s0, t)
          [] r.k = "C" /\ i > committed ->
              /\ Len(ring) < RingCap
              /\ LET d == IF s0.act /\ s0.frag > r.dep THEN s0.frag ELSE r.dep IN
                 Submit([lsa |-> i, t |-> t, kind |-> "C", dep |-> d,
                         items |-> IF s0.act THEN SlotItems(t, s0) ELSE {},
                         hasApply |-> s0.act, start |-> s0.start], s0, t)
          [] OTHER ->   \* boundary at or below committed_lsa (7633-7636)
              /\ slot' = [slot EXCEPT ![t] = IF r.k = "C" THEN EmptySlot ELSE s0]
              /\ UNCHANGED <<ring, frontier, pending, tq, infl>>
  /\ UNCHANGED <<mvars, wk, resq, committed, lastC, reqLsa, storedC, storedR, sdb, markers, crashes,
                 wapp, wrem, wign, nerr, halted, promoted>>

AttachAll(inf, rs) ==
  [i \in 1..Len(inf) |->
     IF \E x \in SetOf(rs) : x.lsa = inf[i].task.lsa
     THEN [inf[i] EXCEPT !.res = IF \E x \in SetOf(rs) : x.lsa = inf[i].task.lsa /\ x.err THEN "err" ELSE "ok"]
     ELSE inf[i]]

\* only results without error mark the ring (la_coordinator_record_result 337-340)
RECURSIVE MarkAll(_, _)
MarkAll(r, rs) == IF rs = << >> THEN r
                  ELSE MarkAll(IF Head(rs).err THEN r ELSE MarkDone(r, Head(rs).lsa), Tail(rs))

RECURSIVE RetireCount(_)
RetireCount(inf) == IF inf = << >> \/ inf[1].res # "ok" THEN 0 ELSE 1 + RetireCount(Tail(inf))

\* la_coordinator_collect_and_retire; an error result at the head stops the applier (516-538)
CollectRetire(doStore) ==
  /\ CoordOn
  /\ LET inf1 == AttachAll(infl, resq)
         a == Advance(MarkAll(ring, resq), frontier)
         d == Drain(pending, tq, inf1, a.fr)
         n == RetireCount(d.inf)
         retired == {d.inf[i].task : i \in 1..n}
         c1 == IF n > 0 /\ a.fr # NULL /\ a.fr > committed THEN a.fr ELSE committed
         freed == {tk.t : tk \in {x \in retired : x.kind = "C" /\ x.hasApply}}
         rest == [i \in 1..(Len(d.inf) - n) |-> d.inf[i + n]]
     IN
     /\ (resq # << >> \/ n > 0 \/ d.p # pending)
     /\ resq' = << >>
     /\ ring' = a.r /\ frontier' = a.fr
     /\ pending' = d.p /\ tq' = d.q
     /\ infl' = rest
     /\ slot' = [t \in Txns |-> IF t \in freed THEN EmptySlot ELSE slot[t]]
     /\ committed' = c1
     /\ halted' = (rest # << >> /\ rest[1].res = "err")
     /\ IF doStore /\ n > 0
        THEN /\ storedC' = Max2(c1, lastC)
             /\ storedR' = reqLsa
             /\ markers' = {m \in markers : m > c1}
        ELSE UNCHANGED <<storedC, storedR, markers>>
  /\ UNCHANGED <<mvars, rd, wk, lastC, reqLsa, sdb, crashes, wapp, wrem, wign, nerr, promoted>>

\* la_find_required_lsa (2312-2380). Mutant reqNoTasks: the in-flight and pending scans are left out
\* (the shape before review item 02 was fixed).
Required ==
  LET c == {slot[t].start : t \in {u \in Txns : slot[u].act}}
           \cup (IF Mut = "reqNoTasks" THEN {}
                 ELSE {infl[i].task.start : i \in {j \in 1..Len(infl) : infl[j].task.hasApply}}
                      \cup {pending[i].start : i \in {j \in 1..Len(pending) : pending[j].hasApply}})
  IN IF c = {} THEN rd ELSE MinOf(c)

\* la_log_commit (7994-8010): required_lsa recomputed, apply info stored, markers at or below committed deleted
LogCommit ==
  /\ SlaveOn /\ ~halted /\ ~promoted
  /\ LET R == Required
         C == Max2(committed, lastC)
     IN /\ <<storedC, storedR, reqLsa>> # <<C, R, R>>
        /\ reqLsa' = R /\ storedC' = C /\ storedR' = R
        /\ markers' = {m \in markers : m > committed}
  /\ UNCHANGED <<mvars, rd, slot, ring, frontier, pending, tq, infl, wk, resq, committed, lastC, sdb, crashes,
                 wapp, wrem, wign, nerr, halted, promoted>>

Skip(tk) == tk.lsa <= lastC \/ tk.lsa \in markers

Take(w) ==
  /\ SlaveOn /\ ~promoted
  /\ wk[w] = NoTask /\ tq # << >>
  /\ wk' = [wk EXCEPT ![w] = Head(tq)]
  /\ tq' = Tail(tq)
  \* la_apply_repl_log 6976-6990: a skipped task applies nothing
  /\ wrem' = [wrem EXCEPT ![w] = IF Skip(Head(tq)) THEN {} ELSE Head(tq).items]
  /\ UNCHANGED <<mvars, rd, slot, ring, frontier, pending, infl, resq, committed, lastC, reqLsa, storedC,
                 storedR, sdb, markers, crashes, wapp, wign, nerr, halted, promoted>>

\* --- atomic worker (FailModel = FALSE): apply, marker and commit in one slave transaction ---
Finish(w) ==
  /\ ~FailModel /\ ~promoted
  /\ wk[w] # NoTask
  /\ LET tk == wk[w] IN
     /\ wk' = [wk EXCEPT ![w] = NoTask]
     /\ resq' = Append(resq, [lsa |-> tk.lsa, err |-> FALSE])
     /\ IF tk.items # {} /\ ~Skip(tk)
        THEN /\ sdb' = Append(sdb, [u |-> tk.lsa, its |-> tk.items])
             /\ markers' = markers \cup {tk.lsa}
        ELSE UNCHANGED <<sdb, markers>>
  /\ wrem' = [wrem EXCEPT ![w] = {}]
  /\ UNCHANGED <<mvars, rd, slot, ring, frontier, pending, tq, infl, committed, lastC, reqLsa, storedC,
                 storedR, crashes, wapp, wign, nerr, halted, promoted>>

\* --- stepwise worker (FailModel = TRUE) ---
\* one item of la_apply_repl_log (6996-7110), in LSA order:
\*  - applied (buffered for the flush, or a statement run)
\*  - a non-retry error (at the item, or a row of a partially failed flush 6018-6025): counted and dropped
\*  - a retry-class error (LA_RETRY_ON_ERROR, e.g. ER_LK_UNILATERALLY_ABORTED) after which the server has rolled
\*    the slave transaction back: the loop retries the same item only (7077-7086)
ApplyItemFull(w) ==
  /\ FailModel /\ ~promoted
  /\ wk[w] # NoTask /\ wrem[w] # {}
  /\ LET x == MinOf(wrem[w]) IN
     \/ /\ wapp' = [wapp EXCEPT ![w] = @ \cup {x}]
        /\ wrem' = [wrem EXCEPT ![w] = @ \ {x}]
        /\ UNCHANGED <<wign, nerr>>
     \/ /\ AllowIgnoreFail /\ nerr < MaxErr
        /\ wrem' = [wrem EXCEPT ![w] = @ \ {x}]
        /\ wign' = wign \cup {x}
        /\ nerr' = nerr + 1
        /\ UNCHANGED wapp
     \/ /\ AllowServerAbortRetry /\ nerr < MaxErr
        /\ wapp' = [wapp EXCEPT ![w] = {}]
        /\ nerr' = nerr + 1
        /\ UNCHANGED <<wrem, wign>>
  /\ UNCHANGED <<mvars, rd, slot, ring, frontier, pending, tq, infl, wk, resq, committed, lastC, reqLsa, storedC,
                 storedR, sdb, markers, crashes, halted, promoted>>

\* an error ends the task: the worker rolls its slave transaction back (943-948) and reports the error.
\* Mutant noAbortOnError: the rollback is left out, the open transaction keeps the applied rows.
FailTask(w) ==
  LET tk == wk[w] IN
  /\ wk' = [wk EXCEPT ![w] = NoTask]
  /\ wrem' = [wrem EXCEPT ![w] = {}]
  /\ wapp' = IF Mut = "noAbortOnError" THEN wapp ELSE [wapp EXCEPT ![w] = {}]
  /\ resq' = Append(resq, [lsa |-> tk.lsa, err |-> TRUE])
  /\ nerr' = nerr + 1

\* the flush fails with a restart-class row error (6000-6015), or the whole xlocator_repl_force call fails
\* (deadlock victim, locator_sr.c 7240-7246) -> ER_LC_*FLUSH* -> goto end
FlushFail(w) ==
  /\ FailModel /\ ~promoted /\ AllowFlushRestart /\ nerr < MaxErr
  /\ wk[w] # NoTask /\ wk[w].items # {} /\ ~Skip(wk[w])
  /\ FailTask(w)
  /\ UNCHANGED <<mvars, rd, slot, ring, frontier, pending, tq, infl, committed, lastC, reqLsa, storedC, storedR,
                 sdb, markers, crashes, wign, halted, promoted>>

\* flush, marker insert (when total_rows > 0) and commit (950-958). total_rows counts every item handled,
\* failed ones too, so it is > 0 exactly when the task was not skipped and had items.
CommitTask(w) ==
  /\ FailModel /\ ~promoted
  /\ wk[w] # NoTask /\ wrem[w] = {}
  /\ LET tk == wk[w]
         rows == tk.items # {} /\ ~Skip(tk)
         newSdb == IF rows \/ wapp[w] # {} THEN Append(sdb, [u |-> tk.lsa, its |-> wapp[w]]) ELSE sdb
         newMk == IF rows THEN markers \cup {tk.lsa} ELSE markers
     IN
     \/ /\ sdb' = newSdb /\ markers' = newMk
        /\ resq' = Append(resq, [lsa |-> tk.lsa, err |-> FALSE])
        /\ wk' = [wk EXCEPT ![w] = NoTask] /\ wapp' = [wapp EXCEPT ![w] = {}]
        /\ UNCHANGED <<wrem, nerr>>
     \* marker insert or commit fails before the commit
     \/ /\ AllowCommitFail /\ nerr < MaxErr
        /\ FailTask(w)
        /\ UNCHANGED <<sdb, markers>>
     \* the server committed, the reply is lost (ER_NET_CANT_CONNECT_SERVER)
     \/ /\ AllowCommitFail /\ nerr < MaxErr
        /\ sdb' = newSdb /\ markers' = newMk
        /\ resq' = Append(resq, [lsa |-> tk.lsa, err |-> TRUE])
        /\ wk' = [wk EXCEPT ![w] = NoTask] /\ wapp' = [wapp EXCEPT ![w] = {}]
        /\ nerr' = nerr + 1
        /\ UNCHANGED wrem
  /\ UNCHANGED <<mvars, rd, slot, ring, frontier, pending, tq, infl, committed, lastC, reqLsa, storedC, storedR,
                 crashes, wign, halted, promoted>>

\* process crash, or the stop after an error result, then a start from the stored apply info
\* (committed_lsa = required_lsa, 9811). Open slave transactions roll back.
Restart ==
  /\ SlaveOn /\ ~promoted
  /\ \/ halted
     \/ crashes < MaxCrash
  /\ crashes' = IF halted THEN crashes ELSE crashes + 1
  /\ rd' = storedR /\ committed' = storedR /\ lastC' = storedC /\ reqLsa' = storedR
  /\ slot' = [t \in Txns |-> EmptySlot]
  /\ ring' = << >> /\ frontier' = NULL /\ pending' = << >> /\ tq' = << >> /\ infl' = << >> /\ resq' = << >>
  /\ wk' = [w \in Workers |-> NoTask] /\ wapp' = [w \in Workers |-> {}] /\ wrem' = [w \in Workers |-> {}]
  /\ halted' = FALSE
  /\ UNCHANGED <<mvars, storedC, storedR, sdb, markers, wign, nerr, promoted>>

DrainComplete ==
  /\ (pending = << >> \/ Mut = "doneNoPending")
  /\ ((infl = << >> /\ ring = << >>) \/ Mut = "doneNoInflight")

\* la_change_state 7874-7912: the master is dead, everything is read, drain_complete -> DONE, promotion
Promote ==
  /\ Failover /\ mdone /\ ~promoted /\ ~halted
  /\ rd > N /\ DrainComplete
  /\ promoted' = TRUE
  /\ UNCHANGED <<mvars, rd, slot, ring, frontier, pending, tq, infl, wk, resq, committed, lastC, reqLsa,
                 storedC, storedR, sdb, markers, crashes, wapp, wrem, wign, nerr, halted>>

SlaveQuiet ==
  /\ rd > N /\ pending = << >> /\ tq = << >> /\ infl = << >> /\ resq = << >> /\ ~halted
  /\ \A w \in Workers : wk[w] = NoTask

SlaveNext ==
  \/ ReadRecord
  \/ CollectRetire(TRUE) \/ CollectRetire(FALSE)
  \/ LogCommit
  \/ \E w \in Workers : Take(w) \/ Finish(w) \/ ApplyItemFull(w) \/ FlushFail(w) \/ CommitTask(w)
  \/ Restart
  \/ Promote

Done == mdone /\ (SlaveQuiet \/ promoted) /\ UNCHANGED vars

-----------------------------------------------------------------------------

Init ==
  /\ mst = [t \in Txns |-> "idle"] /\ nd = [t \in Txns |-> 0] /\ ns = [t \in Txns |-> 0]
  /\ pend = [t \in Txns |-> FALSE] /\ mlog = << >> /\ mdone = FALSE
  /\ rd = 1 /\ slot = [t \in Txns |-> EmptySlot]
  /\ ring = << >> /\ frontier = NULL /\ pending = << >> /\ tq = << >> /\ infl = << >> /\ resq = << >>
  /\ wk = [w \in Workers |-> NoTask]
  /\ committed = 0 /\ lastC = 0 /\ reqLsa = 1 /\ storedC = 0 /\ storedR = 1
  /\ sdb = << >> /\ markers = {} /\ crashes = 0
  /\ wapp = [w \in Workers |-> {}] /\ wrem = [w \in Workers |-> {}] /\ wign = {} /\ nerr = 0
  /\ halted = FALSE /\ promoted = FALSE

Next ==
  \/ MasterNext /\ UNCHANGED svars
  \/ SlaveNext
  \/ Done

Spec == Init /\ [][Next]_vars

TxnSym == Permutations(Txns)

-----------------------------------------------------------------------------
(* Properties *)

Applied == {sdb[p].u : p \in 1..Len(sdb)}
Pos(x) == CHOOSE p \in 1..Len(sdb) : sdb[p].u = x

NoDuplicate == Len(sdb) = Cardinality(Applied)
OnlyUnits == Applied \subseteq Units
\* a committed slave transaction holds exactly its unit's items, less the counted failures
UnitAtomic == \A p \in 1..Len(sdb) :
  /\ sdb[p].its \subseteq ItemsOf(sdb[p].u)
  /\ ItemsOf(sdb[p].u) \ sdb[p].its \subseteq wign
\* a marker exists only together with its committed unit
MarkerWithData == markers \subseteq Applied

ConflictOrder ==
  \A p \in 1..Len(sdb) : \A i \in Units :
    (i < sdb[p].u /\ Conflict(i, sdb[p].u)) => (i \in Applied /\ Pos(i) < p)

PrefixStored == \A b \in Units : b <= storedC => b \in Applied

\* the question of scenario 1: a stored restart position never passes the first record of a transaction that
\* still has work to apply (open in the log, or a unit not applied yet)
Live(t) == Started(t) /\ (~Ended(t) \/ \E u \in Units : mlog[u].t = t /\ u \notin Applied)
RequiredStored == \A t \in Txns : Live(t) => storedR <= FirstRec(t)

QuietAllApplied == (mdone /\ SlaveQuiet) => Units \subseteq Applied

\* scenario 3: after promotion every unit of the dead master's log is on the new master
PromoteComplete == promoted => Units \subseteq Applied

\* sanity, expected to fail: a fragment is split from a long-transaction slot / a restart happens with a unit
\* applied before it / a failover reaches DONE
NoLongFragment == \A i \in 1..Len(infl) : ~(infl[i].task.kind = "S" /\ Cardinality(infl[i].task.items) > MaxItems)
NeverPromote == ~promoted
=============================================================================
