-------------------------- MODULE RestartFailover --------------------------
(***************************************************************************)
(* Restart, crash recovery and promotion of the writeset parallel applier *)
(* (PR #8052, log_applier.c and applier/*.cpp).                            *)
(*                                                                         *)
(* A fixed master log (copied log) is read record by record by the         *)
(* coordinator.  Workers apply tasks in any order the gate allows.  The    *)
(* slave may crash at any step: memory is lost, the slave database (data   *)
(* + applied-tx markers) and the stored apply info stay.  Restart follows  *)
(* la_get_last_ha_applied_info / la_load_applied_tx_markers / 9811.        *)
(* Promotion is the DONE report of la_change_state.                        *)
(*                                                                         *)
(* LSA = index into the log.  0 = NULL dependency, -1 = NULL frontier.     *)
(***************************************************************************)
EXTENDS Naturals, Integers, Sequences, FiniteSets

CONSTANTS
  Scenario,        \* which master log to use
  MaxCrash,        \* bound on slave crashes (applier or server)
  StoreOnRetire,   \* TRUE: retire may store apply info (la_coordinator_store_apply_info_at_interval)
  BugMarkerOff,    \* mutation: worker does not insert the marker
  BugNoDrainGate,  \* mutation: DONE does not wait for drain_complete
  BugRequiredFinal,\* mutation: required_lsa ignores open slots (always final_lsa)
  BugGateOff,      \* mutation: the gate lets every task pass
  BugNoFragDetach, \* mutation: a labeled SYSOP_END is not split off its transaction
  MasterEnd,       \* "DEAD" or "STANDBY": master state when the copied log ends
  KeepLabel,       \* TRUE: a restart may keep the label holder (in-process restart, file static)
  CrashAfterDone   \* TRUE: the applier may crash and restart after DONE (promoted node)

-----------------------------------------------------------------------------
(* Master logs.  Records: ty in {ITEM, STMT, LABEL, SYSOP, COMMIT, ABORT}.  *)
(* A LABEL is written right before its boundary (log_manager.c 5030).       *)

R(ty, t, k) == [ty |-> ty, t |-> t, k |-> k]

\* A: long txn T3 with a serial fragment, conflicting T1 -> T2, a DDL T4, T3 commit after the DDL
LogA == << R("ITEM","T3","k2"),   \* 1  T3 starts
           R("ITEM","T1","k1"),   \* 2  T1 starts
           R("ITEM","T2","k1"),   \* 3  T2 starts
           R("LABEL","T1","-"),   \* 4
           R("COMMIT","T1","-"),  \* 5  unit {2}
           R("ITEM","T3","k3"),   \* 6  serial update inside T3
           R("LABEL","T3","-"),   \* 7
           R("SYSOP","T3","-"),   \* 8  fragment unit {1,6}
           R("LABEL","T2","-"),   \* 9
           R("COMMIT","T2","-"),  \* 10 unit {3}, conflicts with 5
           R("STMT","T4","ALL"),  \* 11 DDL, T4 starts
           R("LABEL","T4","-"),   \* 12
           R("COMMIT","T4","-"),  \* 13 unit {11}
           R("ITEM","T3","k1"),   \* 14
           R("LABEL","T3","-"),   \* 15
           R("COMMIT","T3","-") >>\* 16 unit {14}

\* B: smaller; T2 starts before T1 and commits after it, fragment of an aborted T3
LogB == << R("ITEM","T2","k1"),   \* 1  T2 starts
           R("ITEM","T3","k2"),   \* 2  T3 starts
           R("ITEM","T1","k1"),   \* 3  T1 starts
           R("LABEL","T3","-"),   \* 4
           R("SYSOP","T3","-"),   \* 5  fragment unit {2}
           R("LABEL","T1","-"),   \* 6
           R("COMMIT","T1","-"),  \* 7  unit {3}
           R("LABEL","T2","-"),   \* 8
           R("COMMIT","T2","-"),  \* 9  unit {1}, conflicts with 7
           R("ABORT","T3","-") >> \* 10

\* C: DDL statements back to back with an independent row commit between
LogC == << R("ITEM","T1","k1"),   \* 1
           R("STMT","T2","ALL"),  \* 2
           R("LABEL","T2","-"),   \* 3
           R("COMMIT","T2","-"),  \* 4  unit {2}
           R("LABEL","T1","-"),   \* 5
           R("COMMIT","T1","-"),  \* 6  unit {1}
           R("ITEM","T3","k2"),   \* 7
           R("STMT","T3","ALL"),  \* 8
           R("LABEL","T3","-"),   \* 9
           R("COMMIT","T3","-") >>\* 10 unit {7,8}

\* D: master restart between commits (LOG_DUMMY_CRASH_RECOVERY = MREC); later labels carry the
\*    recovered-log floor (C1); a loser T2 is aborted by recovery
LogD == << R("ITEM","T1","k1"),   \* 1  T1 starts
           R("ITEM","T2","k2"),   \* 2  T2 starts (loser)
           R("LABEL","T1","-"),   \* 3
           R("COMMIT","T1","-"),  \* 4  unit {1}
           R("MREC","SYS","-"),   \* 5  master restarted, label floor = 5
           R("ABORT","T2","-"),   \* 6
           R("ITEM","T3","k1"),   \* 7
           R("LABEL","T3","-"),   \* 8
           R("COMMIT","T3","-"),  \* 9  unit {7}, label max(4, 5) = 5
           R("ITEM","T4","k2"),   \* 10
           R("STMT","T4","ALL"),  \* 11
           R("LABEL","T4","-"),   \* 12
           R("COMMIT","T4","-") >>\* 13 unit {10,11}

\* E: an unlabeled SYSOP_END inside a transaction whose earlier items went out in a labeled one
LogE == << R("ITEM","T1","k1"),   \* 1  T1 starts (its first record)
           R("ITEM","T2","k2"),   \* 2  T2 starts
           R("ITEM","T1","k3"),   \* 3  serial update of T1, flushed in a system operation
           R("LABEL","T1","-"),   \* 4
           R("SYSOP","T1","-"),   \* 5  labeled fragment {1,3}
           R("SYSOP","T1","-"),   \* 6  unlabeled nested top operation
           R("LABEL","T2","-"),   \* 7
           R("COMMIT","T2","-"),  \* 8  unit {2}
           R("ITEM","T1","k2"),   \* 9
           R("LABEL","T1","-"),   \* 10
           R("COMMIT","T1","-") >>\* 11 unit {9}

\* F: two fragments in one transaction, a DDL between them and the outer commit, and a transaction
\*    still open when the copied log ends (never committed by the master)
LogF == << R("ITEM","T1","k1"),   \* 1  T1 starts
           R("ITEM","T2","k2"),   \* 2  T2 starts
           R("ITEM","T1","k3"),   \* 3
           R("LABEL","T1","-"),   \* 4
           R("SYSOP","T1","-"),   \* 5  fragment {1,3}
           R("LABEL","T2","-"),   \* 6
           R("COMMIT","T2","-"),  \* 7  unit {2}
           R("ITEM","T3","k4"),   \* 8  T3 starts, never ends
           R("ITEM","T1","k3"),   \* 9
           R("LABEL","T1","-"),   \* 10
           R("SYSOP","T1","-"),   \* 11 fragment {9}, after fragment 5
           R("STMT","T4","ALL"),  \* 12 DDL, T4 starts
           R("LABEL","T4","-"),   \* 13
           R("COMMIT","T4","-"),  \* 14 unit {12}
           R("ITEM","T1","k2"),   \* 15
           R("LABEL","T1","-"),   \* 16
           R("COMMIT","T1","-") >>\* 17 unit {15}

L == CASE Scenario = "A" -> LogA
       [] Scenario = "F" -> LogF
       [] Scenario = "D" -> LogD
       [] Scenario = "E" -> LogE
       [] Scenario = "B" -> LogB
       [] Scenario = "C" -> LogC

N == Len(L)
Idx == 1..N
Txns == {L[i].t : i \in Idx}   \* "SYS" never gets a slot

Max(S) == IF S = {} THEN 0 ELSE CHOOSE m \in S : \A x \in S : x <= m
Min(S) == CHOOSE m \in S : \A x \in S : m <= x

FirstRec(t) == Min({i \in Idx : L[i].t = t})
IsData(i) == L[i].ty \in {"ITEM", "STMT"}
LabeledSysop(i) == L[i].ty = "SYSOP" /\ i > 1 /\ L[i-1].ty = "LABEL" /\ L[i-1].t = L[i].t
PrevFrag(b) == Max({j \in 1..(b-1) : LabeledSysop(j) /\ L[j].t = L[b].t})
UnitItems(b) == {j \in Idx : L[j].t = L[b].t /\ IsData(j) /\ PrevFrag(b) < j /\ j < b}
IsBoundary(b) == L[b].ty = "COMMIT" \/ LabeledSysop(b)
Units == {b \in Idx : IsBoundary(b) /\ UnitItems(b) # {}}
UKeys(b) == {L[j].k : j \in UnitItems(b)}
Conflict(a, b) == (UKeys(a) \cap UKeys(b)) # {} \/ "ALL" \in UKeys(a) \cup UKeys(b)
\* the master's label for boundary b: the latest earlier unit it conflicts with
MasterDep(b) == LET d == Max({a \in Units : a < b /\ Conflict(a, b)})
                    f == Max({i \in Idx : L[i].ty = "MREC" /\ i < b})   \* recovered-log floor (C1)
                IN IF f > d THEN f ELSE d

-----------------------------------------------------------------------------
VARIABLES
  \* persistent (slave database)
  db,          \* slave commits of applied units: sequence of [b, items]
  markers,     \* ha_applied_tx_marker rows (commit / SYSOP_END LSAs)
  sCommitted,  \* _db_ha_apply_info.committed_lsa
  sRequired,   \* _db_ha_apply_info.required_lsa
  \* applier process memory
  mode,        \* "run" | "done" (DONE reported, node promoted)
  crashes,
  final,       \* next record to read (final_lsa)
  lastC,       \* last_committed_lsa read at startup
  loaded,      \* markers loaded at startup
  mCommitted,  \* la_Info.committed_lsa
  mRequired,   \* la_Info.required_lsa (last computed)
  slots,       \* repl_lists: t -> [start, items, frag]; start = 0 means no slot
  label,       \* writeset label holder
  ring,        \* gate commit-order ring: sequence of [c, done]
  frontier,    \* gate frontier, -1 = NULL
  pending,     \* parked tasks
  queue,       \* dispatched tasks not yet taken by a worker
  inflight,    \* dispatched tasks in dispatch order: [task, res]
  results      \* result queue: boundaries finished by workers

pvars == <<db, markers, sCommitted, sRequired>>
mvars == <<final, lastC, loaded, mCommitted, mRequired, slots, label, ring, frontier,
           pending, queue, inflight, results>>
vars == <<pvars, mode, crashes, mvars>>

NoSlot == [start |-> 0, items |-> {}, frag |-> 0]
NoLabel == [on |-> FALSE, t |-> "-", dep |-> 0]
DbSet == {db[i].b : i \in 1..Len(db)}

\* volatile state of a fresh applier run from the stored apply info (la_apply_log_file)
RestartMem ==
  /\ lastC' = sCommitted
  /\ loaded' = {m \in markers : m > sCommitted}
  /\ mCommitted' = sRequired               \* 9811
  /\ mRequired' = sRequired
  /\ final' = sRequired                    \* la_apply_pre
  /\ slots' = [t \in Txns |-> NoSlot]
  /\ label' \in IF KeepLabel THEN {NoLabel, label} ELSE {NoLabel}  \* wset_label.cpp statics survive an in-process restart
  /\ ring' = << >>
  /\ frontier' = -1
  /\ pending' = << >>
  /\ queue' = {}
  /\ inflight' = << >>
  /\ results' = {}

Init ==
  /\ db = << >>
  /\ markers = {}
  /\ sCommitted = 0
  /\ sRequired = 1
  /\ mode = "run"
  /\ crashes = 0
  /\ lastC = 0
  /\ loaded = {}
  /\ mCommitted = 1
  /\ mRequired = 1
  /\ final = 1
  /\ slots = [t \in Txns |-> NoSlot]
  /\ label = NoLabel
  /\ ring = << >>
  /\ frontier = -1
  /\ pending = << >>
  /\ queue = {}
  /\ inflight = << >>
  /\ results = {}

-----------------------------------------------------------------------------
(* Gate (log_applier_gate.cpp) *)

Satisfied(dep, fr) == BugGateOff \/ dep = 0 \/ (fr # -1 /\ dep <= fr)

\* la_gate_advance_frontier over a ring
AdvRing(rg) ==
  LET k == CHOOSE n \in 0..Len(rg) :
             /\ \A i \in 1..n : rg[i].done
             /\ (n = Len(rg) \/ ~rg[n+1].done)
  IN k
AdvFrontier(rg, fr) == LET k == AdvRing(rg) IN IF k = 0 THEN fr ELSE rg[k].c
AdvRest(rg) == LET k == AdvRing(rg) IN SubSeq(rg, k + 1, Len(rg))

\* la_coordinator_drain_ready: release every parked task whose dependency is satisfied
ReadyIdx(pd, fr) == {i \in 1..Len(pd) : Satisfied(pd[i].dep, fr)}
Released(pd, fr) == SelectSeq(pd, LAMBDA x : Satisfied(x.dep, fr))
Kept(pd, fr) == SelectSeq(pd, LAMBDA x : ~Satisfied(x.dep, fr))
ToInflight(ts) == [i \in 1..Len(ts) |-> [task |-> ts[i], res |-> FALSE]]
SeqSet(s) == {s[i] : i \in 1..Len(s)}

-----------------------------------------------------------------------------
(* Coordinator reading the log (la_log_record_process) *)

\* slots after the record at `final` creates a slot (first record of the transaction, 7560)
SlotsOpen ==
  LET r == L[final] IN
  IF r.ty \notin {"LABEL", "MREC"} /\ final = FirstRec(r.t) /\ slots[r.t].start = 0
  THEN [slots EXCEPT ![r.t] = [start |-> final, items |-> {}, frag |-> 0]]
  ELSE slots

\* la_coordinator_submit_task with an already built task, from slot map sl
Submit(task, sl) ==
  LET fr0 == IF frontier = -1 THEN mCommitted ELSE frontier       \* la_gate_set_initial_frontier
      prev == IF ring # << >> THEN ring[Len(ring)].c ELSE fr0
      dep == IF task.dep # 0 /\ task.dep > prev THEN prev ELSE task.dep \* la_gate_bound_dependency
      tk == [task EXCEPT !.dep = dep]
      rel == Released(pending, fr0)
      kept == Kept(pending, fr0)
      ok == Satisfied(dep, fr0)
  IN /\ frontier' = fr0
     /\ ring' = Append(ring, [c |-> task.b, done |-> FALSE])
     /\ pending' = IF ok THEN kept ELSE Append(kept, tk)
     /\ inflight' = inflight \o ToInflight(IF ok THEN Append(rel, tk) ELSE rel)
     /\ queue' = queue \cup SeqSet(rel) \cup (IF ok THEN {tk} ELSE {})
     /\ slots' = sl

\* la_coordinator_complete_without_task
CompleteWithoutTask(s, sl) ==
  LET fr0 == IF frontier = -1 THEN mCommitted ELSE frontier
      rg == Append(ring, [c |-> s, done |-> TRUE])
      fr1 == AdvFrontier(rg, fr0)
      rel == Released(pending, fr1)
  IN /\ frontier' = fr1
     /\ ring' = AdvRest(rg)
     /\ pending' = Kept(pending, fr1)
     /\ inflight' = inflight \o ToInflight(rel)
     /\ queue' = queue \cup SeqSet(rel)
     /\ slots' = sl

ReadRecord ==
  /\ mode = "run"
  /\ final <= N
  /\ LET r == L[final]
         sl == SlotsOpen
         t == r.t
     IN
     CASE r.ty \in {"ITEM", "STMT"} ->
            /\ slots' = IF sl[t].start # 0
                        THEN [sl EXCEPT ![t].items = @ \cup {final}]
                        ELSE sl                                   \* la_set_repl_log: no slot, dropped
            /\ UNCHANGED <<label, ring, frontier, pending, queue, inflight>>
       [] r.ty = "LABEL" ->
            /\ label' = [on |-> TRUE, t |-> t, dep |-> MasterDep(final + 1)]
            /\ slots' = sl
            /\ UNCHANGED <<ring, frontier, pending, queue, inflight>>
       [] r.ty = "SYSOP" ->
            IF final > mCommitted
            THEN IF ~BugNoFragDetach /\ label.on /\ label.t = t /\ sl[t].start # 0 /\ sl[t].items # {}
                 THEN LET fitems == {i \in sl[t].items : i <= final}
                          task == [b |-> final, t |-> t, kind |-> "F", items |-> fitems,
                                   start |-> Min(fitems), dep |-> label.dep]
                      IN /\ label' = NoLabel
                         /\ Submit(task, [sl EXCEPT ![t].items = @ \ fitems, ![t].frag = final])
                 ELSE IF label.on /\ label.t = t
                      THEN /\ label' = NoLabel
                           /\ CompleteWithoutTask(final, sl)
                      ELSE /\ slots' = sl
                           /\ UNCHANGED <<label, ring, frontier, pending, queue, inflight>>
            ELSE /\ slots' = sl
                 /\ UNCHANGED <<label, ring, frontier, pending, queue, inflight>>
       [] r.ty = "COMMIT" ->
            IF final > mCommitted
            THEN LET has == sl[t].start # 0 /\ sl[t].items # {}
                     hasLabel == label.on /\ label.t = t
                     d0 == IF hasLabel THEN label.dep ELSE 0
                     d1 == IF sl[t].frag > d0 THEN sl[t].frag ELSE d0
                     d2 == IF has /\ ~hasLabel /\ ring # << >> /\ ring[Len(ring)].c > d1
                           THEN ring[Len(ring)].c ELSE d1
                     task == [b |-> final, t |-> t, kind |-> "C",
                              items |-> IF has THEN sl[t].items ELSE {},
                              start |-> sl[t].start, dep |-> d2]
                 IN /\ label' = IF hasLabel THEN NoLabel ELSE label
                    /\ Submit(task, sl)
            ELSE /\ slots' = [sl EXCEPT ![t] = NoSlot]            \* la_free_repl_items_by_tranid
                 /\ UNCHANGED <<label, ring, frontier, pending, queue, inflight>>
       [] r.ty = "MREC" ->
            /\ slots' = sl
            /\ UNCHANGED <<label, ring, frontier, pending, queue, inflight>>
       [] r.ty = "ABORT" ->
            /\ slots' = [sl EXCEPT ![t] = NoSlot]
            /\ UNCHANGED <<label, ring, frontier, pending, queue, inflight>>
  /\ final' = final + 1
  /\ UNCHANGED <<pvars, mode, crashes, lastC, loaded, mCommitted, mRequired, results>>

-----------------------------------------------------------------------------
(* Worker (la_apply_worker_apply_task): apply, marker, commit in one slave txn *)

WorkerApply ==
  /\ mode = "run"
  /\ \E tk \in queue :
       LET skip == tk.b <= lastC \/ tk.b \in loaded \/ tk.items = {}
       IN /\ db' = IF skip THEN db ELSE Append(db, [b |-> tk.b, items |-> tk.items])
          /\ markers' = IF skip \/ BugMarkerOff THEN markers ELSE markers \cup {tk.b}
          /\ queue' = queue \ {tk}
          /\ results' = results \cup {tk.b}
  /\ UNCHANGED <<sCommitted, sRequired, mode, crashes, final, lastC, loaded, mCommitted, mRequired,
                 slots, label, ring, frontier, pending, inflight>>

(* Coordinator collects results (la_coordinator_collect_results) *)
Collect ==
  /\ mode = "run"
  /\ results # {}
  /\ LET rg == [i \in 1..Len(ring) |-> IF ring[i].c \in results
                                        THEN [ring[i] EXCEPT !.done = TRUE] ELSE ring[i]]
         fr1 == AdvFrontier(rg, frontier)
         infl == [i \in 1..Len(inflight) |->
                    IF inflight[i].task.b \in results
                    THEN [inflight[i] EXCEPT !.res = TRUE] ELSE inflight[i]]
         rel == Released(pending, fr1)
     IN /\ frontier' = fr1
        /\ ring' = AdvRest(rg)
        /\ pending' = Kept(pending, fr1)
        /\ inflight' = infl \o ToInflight(rel)
        /\ queue' = queue \cup SeqSet(rel)
        /\ results' = {}
  /\ UNCHANGED <<pvars, mode, crashes, final, lastC, loaded, mCommitted, mRequired, slots, label>>

\* required_lsa (la_find_required_lsa)
ComputeRequired ==
  IF BugRequiredFinal THEN final ELSE
  LET S == {slots[t].start : t \in {u \in Txns : slots[u].start # 0}}
           \cup {inflight[i].task.start : i \in {j \in 1..Len(inflight) : inflight[j].task.start # 0}}
           \cup {pending[i].start : i \in {j \in 1..Len(pending) : pending[j].start # 0}}
  IN IF S = {} THEN final ELSE Min(S)

\* la_coordinator_commit_apply_info: apply info + marker delete in one transaction
StoreWith(mc, req) ==
  /\ sCommitted' = IF mc >= lastC THEN mc ELSE lastC
  /\ sRequired' = req
  /\ markers' = {m \in markers : m > mc}

(* Retire in dispatch order (la_coordinator_retire_results) *)
Retire(store) ==
  /\ mode = "run"
  /\ inflight # << >>
  /\ Head(inflight).res
  /\ LET tk == Head(inflight).task
         mc == IF frontier # -1 /\ frontier > mCommitted THEN frontier ELSE mCommitted
     IN /\ mCommitted' = mc
        /\ slots' = IF tk.kind = "C" /\ tk.start # 0 THEN [slots EXCEPT ![tk.t] = NoSlot] ELSE slots
        /\ inflight' = Tail(inflight)
        /\ IF store THEN StoreWith(mc, mRequired) ELSE UNCHANGED <<sCommitted, sRequired, markers>>
  /\ UNCHANGED <<db, mode, crashes, final, lastC, loaded, mRequired, label, ring, frontier,
                 pending, queue, results>>

(* la_log_commit: recompute required_lsa, then store *)
LogCommit ==
  /\ mode = "run"
  /\ mRequired' = ComputeRequired
  /\ StoreWith(mCommitted, ComputeRequired)
  /\ UNCHANGED <<db, mode, crashes, final, lastC, loaded, mCommitted, slots, label, ring, frontier,
                 pending, queue, inflight, results>>

(* DONE (la_change_state 7874): end of log, master DEAD/STANDBY, drain complete.
   Not DEAD: la_clear_all_repl_lists before la_log_commit. *)
DrainComplete == pending = << >> /\ inflight = << >> /\ ring = << >>
ClearedSlots == [t \in Txns |-> NoSlot]
Done ==
  /\ mode = "run"
  /\ final > N
  /\ (BugNoDrainGate \/ DrainComplete)
  /\ slots' = IF MasterEnd = "DEAD" THEN slots ELSE ClearedSlots
  /\ LET req == IF MasterEnd = "DEAD" THEN ComputeRequired ELSE final
     IN /\ mRequired' = req
        /\ StoreWith(mCommitted, req)
  /\ mode' = "done"
  /\ UNCHANGED <<db, crashes, final, lastC, loaded, mCommitted, label, ring, frontier,
                 pending, queue, inflight, results>>

(* main loop 9988-10019: after DONE with a master not ACTIVE: committed_lsa = final_lsa clamped
   to the frontier unless the master is DEAD, then la_log_commit *)
PostDone ==
  /\ mode = "done"
  /\ LET mc == IF MasterEnd = "DEAD" THEN mCommitted
                ELSE IF frontier # -1 /\ final > frontier THEN frontier ELSE final
     IN /\ mCommitted' = mc
        /\ mRequired' = ComputeRequired
        /\ StoreWith(mc, ComputeRequired)
  /\ mode' = "done2"
  /\ UNCHANGED <<db, crashes, final, lastC, loaded, slots, label, ring, frontier,
                 pending, queue, inflight, results>>

(* Crash at any step and restart from the stored apply info *)
CrashRestart ==
  /\ (mode = "run" \/ (CrashAfterDone /\ mode \in {"done", "done2"}))
  /\ crashes < MaxCrash
  /\ crashes' = crashes + 1
  /\ RestartMem
  /\ mode' = "run"
  /\ UNCHANGED pvars

Terminated == mode = "done2" /\ UNCHANGED vars

Next ==
  \/ ReadRecord
  \/ WorkerApply
  \/ Collect
  \/ (StoreOnRetire /\ Retire(TRUE))
  \/ Retire(FALSE)
  \/ LogCommit
  \/ Done
  \/ PostDone
  \/ CrashRestart
  \/ Terminated

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Invariants *)

NoDuplicate == \A i, j \in 1..Len(db) : i # j => db[i].b # db[j].b
\* every slave commit is a whole master unit (no partial or merged transaction)
WholeUnits == \A i \in 1..Len(db) : db[i].b \in Units /\ db[i].items = UnitItems(db[i].b)
ConflictOrder == \A i, j \in 1..Len(db) :
                   (i < j /\ Conflict(db[i].b, db[j].b)) => db[i].b < db[j].b
\* the stored position is a gap-free prefix of applied units
StoredPrefix == \A u \in Units : u <= sCommitted => u \in DbSet
MarkersApplied == markers \subseteq DbSet
\* promotion: every unit of the log applied exactly once
PrefixOnPromote == mode \in {"done", "done2"} => (\A u \in Units : u \in DbSet)
ExactlyOnce == NoDuplicate /\ WholeUnits /\ PrefixOnPromote

TypeOK ==
  /\ mode \in {"run", "done", "done2"}
  /\ final \in 1..(N + 1)
  /\ frontier \in -1..N
=============================================================================
