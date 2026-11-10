--------------------------- MODULE SlaveCoordinator ---------------------------
(***************************************************************************)
(* Slave side of the PR #8052 writeset parallel applier: coordinator,      *)
(* commit-order ring and gate, pending list, task queue, in-flight list,   *)
(* workers, result queue, retire, committed_lsa / required_lsa, stored     *)
(* apply info, applied-tx markers and restart.                             *)
(*                                                                         *)
(* Input is a fixed master log chosen in Init from small per-transaction   *)
(* scripts. Record kinds:                                                  *)
(*   "D" replicated data of the transaction (adds items to its slot)       *)
(*   "S" labeled SYSOP_END (serial fragment boundary)                      *)
(*   "C" COMMIT, "A" ABORT                                                 *)
(* The first record of a transaction creates its slot (log_applier.c:7561)*)
(* Labels are those an ideal master writes (lab "ok"), a missing label    *)
(* ("miss") or a raised floor that is not a commit ("floor").              *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
  Trids, Keys,
  NumWorkers,     \* ha_apply_worker_count
  QCap,           \* task queue capacity
  RingCap,        \* commit-order ring capacity (also in-flight capacity)
  MaxLog,         \* bound on log length
  MaxCrash,       \* number of restarts allowed
  ScriptMode,     \* which per-transaction scripts to enumerate
  LabSet,         \* label variants for commits with items
  ErrMode,        \* "none" | "commit" | "flush"
  Mut             \* mutation for sanity checks, "none" normally

NULL == 0 - 0 + 1000   \* frontier NULL marker (above every LSA)
NoTask == [lsa |-> 0]

ScriptSet ==
  CASE ScriptMode = "basic" -> {<<"D","C">>, <<"D","A">>, <<"D","S","C">>, <<"C">>}
    [] ScriptMode = "frag"  -> {<<"D","C">>, <<"D","S","A">>, <<"D","S","C">>, <<"D","S","D","C">>, <<"S","D","C">>}
    [] ScriptMode = "all"   -> {<<"D","C">>, <<"D","A">>, <<"C">>, <<"D","S","C">>, <<"D","S","A">>,
                                <<"D","S","D","C">>, <<"S","D","C">>, <<"D","S","S","C">>}
    [] ScriptMode = "dc"    -> {<<"D","C">>, <<"C">>}
    [] ScriptMode = "mix3"  -> {<<"D","C">>, <<"C">>, <<"D","S","A">>, <<"S","D","C">>}
    [] ScriptMode = "dca"   -> {<<"D","C">>, <<"D","A">>}

-----------------------------------------------------------------------------
(* Log generation *)

RECURSIVE Merge(_, _)
Merge(a, b) ==
  IF a = << >> THEN {b}
  ELSE IF b = << >> THEN {a}
  ELSE {<<Head(a)>> \o m : m \in Merge(Tail(a), b)}
       \cup {<<Head(b)>> \o m : m \in Merge(a, Tail(b))}

Tag(s, t) == [i \in 1..Len(s) |-> [k |-> s[i], t |-> t]]

TridSeq == CHOOSE f \in [1..Cardinality(Trids) -> Trids] : \A i, j \in DOMAIN f : i # j => f[i] # f[j]

RECURSIVE MergeAll(_, _)
MergeAll(sc, n) ==
  IF n = 0 THEN {<< >>}
  ELSE UNION {Merge(Tag(sc[TridSeq[n]], TridSeq[n]), m) : m \in MergeAll(sc, n - 1)}

SkelSet ==
  UNION {MergeAll(sc, Cardinality(Trids)) :
           sc \in {f \in [Trids -> ScriptSet] :
                    LET L == [t \in Trids |-> Len(f[t])] IN
                    (IF Cardinality(Trids) = 2
                     THEN L[TridSeq[1]] + L[TridSeq[2]]
                     ELSE L[TridSeq[1]] + L[TridSeq[2]] + L[TridSeq[3]]) <= MaxLog}}

NonEmptyKeys == (SUBSET Keys) \ {{}}

VARIABLES
  log,        \* the master log (fixed after Init)
  rd,         \* next log index the coordinator reads (final_lsa)
  slot,       \* slot[t]: [act, start, items, frag, fstart]
  ring,       \* commit-order ring: seq of [lsa, done]
  frontier,   \* gate frontier, NULL before the first submit
  pending,    \* parked tasks
  tq,         \* shared task queue
  infl,       \* in-flight list: seq of [task, res]  res \in {"none","ok","err"}
  wk,         \* wk[w]: task held by worker w or NoTask
  alive,      \* worker thread still running
  resq,       \* result queue: seq of [lsa, ok]
  committed,  \* la_Info.committed_lsa
  lastC,      \* la_Info.last_committed_lsa (stored committed at start)
  reqLsa,     \* la_Info.required_lsa (last computed)
  storedC, storedR,  \* _db_ha_apply_info committed / required
  db,         \* slave commit order of applied boundaries
  markers,    \* applied-tx markers in the slave DB
  stop,       \* la_applier_need_shutdown
  errUsed,    \* the injected error already happened
  crashes,
  ovf         \* enqueue reached a full in-flight list

vars == <<log, rd, slot, ring, frontier, pending, tq, infl, wk, alive, resq, committed,
          lastC, reqLsa, storedC, storedR, db, markers, stop, errUsed, crashes, ovf>>

N == Len(log)
Workers == 1..NumWorkers
Max(S) == IF S = {} THEN 0 ELSE CHOOSE m \in S : \A x \in S : x <= m
Min(S) == CHOOSE m \in S : \A x \in S : m <= x
Last(s) == s[Len(s)]
RemoveAt(s, j) == [i \in 1..(Len(s) - 1) |-> IF i < j THEN s[i] ELSE s[i + 1]]

-----------------------------------------------------------------------------
(* Static facts about the log *)

FirstRec(t) == Min({i \in 1..N : log[i].t = t})
IsBoundary(i) == log[i].k \in {"C", "S"}
PrevS(i) == Max({j \in 1..(i - 1) : log[j].t = log[i].t /\ log[j].k = "S"})
\* items between the previous fragment boundary of the transaction and i
HasItems(i) == \E j \in (PrevS(i) + 1)..(i - 1) : log[j].t = log[i].t /\ log[j].k = "D"
NeedApply(i) == IsBoundary(i) /\ HasItems(i)
NeedSet == {i \in 1..N : NeedApply(i)}

\* Ideal master label: latest earlier commit sharing a key, raised to every earlier labeled SYSOP_END.
IdealDep(i) ==
  IF log[i].k = "S"
  THEN Max({j \in 1..(i - 1) : IsBoundary(j)})
  ELSE Max({j \in 1..(i - 1) : log[j].k = "S" \/ (log[j].k = "C" /\ log[j].keys \cap log[i].keys # {})})

HasLabel(i) == log[i].k = "S" \/ (HasItems(i) /\ log[i].lab # "miss")
LabelVal(i) ==
  IF ~HasLabel(i) THEN 0
  ELSE IF log[i].k = "C" /\ log[i].lab = "floor" THEN Max({IdealDep(i), i - 1})
  ELSE IdealDep(i)

Conflict(a, b) ==
  \/ log[a].k = "S" \/ log[b].k = "S"
  \/ log[a].t = log[b].t
  \/ log[a].keys \cap log[b].keys # {}

-----------------------------------------------------------------------------
(* Gate *)

GateOK(dep, fr) == dep = 0 \/ (fr # NULL /\ dep <= fr)
GateOKm(dep, fr) ==
  IF Mut = "gate_off" THEN TRUE ELSE GateOK(dep, fr)

\* la_gate_advance_frontier
RECURSIVE Advance0(_, _)
Advance0(r, fr) ==
  IF r # << >> /\ Head(r).done THEN Advance0(Tail(r), Head(r).lsa) ELSE [r |-> r, fr |-> fr]

\* mutation adv_hole: the frontier jumps to the latest completed entry over a hole
Advance(r, fr) ==
  IF Mut = "adv_hole" /\ \E i \in 1..Len(r) : r[i].done
  THEN LET m == Max({i \in 1..Len(r) : r[i].done}) IN
       [r |-> [i \in 1..(Len(r) - m) |-> r[i + m]], fr |-> r[m].lsa]
  ELSE Advance0(r, fr)

MarkDone(r, lsa) == [i \in 1..Len(r) |-> IF r[i].lsa = lsa THEN [r[i] EXCEPT !.done = TRUE] ELSE r[i]]

\* la_coordinator_drain_ready: dispatch ready pending tasks in pending order while the queue has room
RECURSIVE Drain(_, _, _, _)
Drain(p, q, inf, fr) ==
  LET idx == {j \in 1..Len(p) : GateOKm(p[j].dep, fr)} IN
  IF Len(q) >= QCap \/ idx = {} THEN [p |-> p, q |-> q, inf |-> inf]
  ELSE LET j == Min(idx) IN
       Drain(RemoveAt(p, j), Append(q, p[j]), Append(inf, [task |-> p[j], res |-> "none"]), fr)

-----------------------------------------------------------------------------
(* Coordinator: read one record *)

EmptySlot == [act |-> FALSE, start |-> 0, items |-> FALSE, frag |-> 0, fstart |-> 0]

\* submit an assembled task (la_coordinator_submit_task); s1 is the slot after the record
Submit(task, s1, t) ==
  LET fr1 == IF frontier = NULL THEN committed ELSE frontier
      prev == IF ring # << >> THEN Last(ring).lsa ELSE fr1
      dep1 == IF Mut # "no_bound" /\ task.dep # 0 /\ task.dep > prev THEN prev ELSE task.dep
      tk == [task EXCEPT !.dep = dep1]
      ring1 == Append(ring, [lsa |-> tk.lsa, done |-> FALSE])
  IN
  /\ ring' = ring1
  /\ frontier' = fr1
  /\ slot' = [slot EXCEPT ![t] = s1]
  /\ IF NumWorkers = 1
     THEN /\ tq' = Append(tq, tk)
          /\ infl' = Append(infl, [task |-> tk, res |-> "none"])
          /\ pending' = pending
          /\ ovf' = (ovf \/ Len(infl) >= RingCap)
     ELSE LET d == Drain(pending, tq, infl, fr1) IN
          IF GateOKm(dep1, fr1) /\ Len(d.q) < QCap
          THEN /\ tq' = Append(d.q, tk)
               /\ infl' = Append(d.inf, [task |-> tk, res |-> "none"])
               /\ pending' = d.p
               /\ ovf' = (ovf \/ Len(d.inf) >= RingCap)
          ELSE /\ tq' = d.q
               /\ infl' = d.inf
               /\ pending' = Append(d.p, tk)
               /\ ovf' = (ovf \/ Len(d.inf) > RingCap)

\* la_coordinator_complete_without_task
CompleteWithoutTask(lsa, s1, t) ==
  LET fr1 == IF frontier = NULL THEN committed ELSE frontier
      a == Advance(Append(ring, [lsa |-> lsa, done |-> TRUE]), fr1)
      d == Drain(pending, tq, infl, a.fr)
  IN /\ ring' = a.r
     /\ frontier' = a.fr
     /\ slot' = [slot EXCEPT ![t] = s1]
     /\ tq' = d.q /\ infl' = d.inf /\ pending' = d.p
     /\ ovf' = ovf

ReadRecord ==
  /\ ~stop
  /\ rd <= N
  /\ LET i == rd
         r == log[i]
         t == r.t
         s0 == IF i = FirstRec(t) THEN [EmptySlot EXCEPT !.act = TRUE, !.start = i] ELSE slot[t]
     IN
     /\ rd' = rd + 1
     /\ CASE r.k = "D" ->
              /\ slot' = [slot EXCEPT ![t] = IF s0.act
                                              THEN [s0 EXCEPT !.items = TRUE,
                                                              !.fstart = IF s0.items THEN s0.fstart ELSE i]
                                              ELSE s0]
              /\ UNCHANGED <<ring, frontier, pending, tq, infl, ovf>>
          [] r.k = "A" ->
              /\ slot' = [slot EXCEPT ![t] = [s0 EXCEPT !.act = FALSE, !.items = FALSE, !.start = 0, !.fstart = 0]]
              /\ UNCHANGED <<ring, frontier, pending, tq, infl, ovf>>
          [] r.k = "S" /\ i > committed ->
              /\ Len(ring) < RingCap   \* la_coordinator_wait_for_commit_order_slot
              /\ IF s0.act /\ s0.items
                 THEN Submit([lsa |-> i, t |-> t, kind |-> "S", dep |-> LabelVal(i), items |-> TRUE,
                              hasApply |-> TRUE, start |-> s0.fstart],
                             [s0 EXCEPT !.items = FALSE, !.fstart = 0, !.frag = i], t)
                 ELSE CompleteWithoutTask(i, s0, t)
          [] r.k = "C" /\ i > committed ->
              /\ Len(ring) < RingCap
              /\ LET items == s0.act /\ s0.items
                     d0 == LabelVal(i)
                     d1 == IF s0.act /\ s0.frag > d0 THEN s0.frag ELSE d0
                     d2 == IF items /\ ~HasLabel(i) /\ ring # << >> /\ (d1 = 0 \/ Last(ring).lsa > d1)
                           THEN Last(ring).lsa ELSE d1
                 IN Submit([lsa |-> i, t |-> t, kind |-> "C", dep |-> d2, items |-> items,
                            hasApply |-> s0.act, start |-> s0.start], s0, t)
          [] OTHER ->   \* boundary at or below committed_lsa: only the slot is cleared
              /\ slot' = [slot EXCEPT ![t] = IF r.k = "C" THEN EmptySlot ELSE s0]
              /\ UNCHANGED <<ring, frontier, pending, tq, infl, ovf>>
  /\ UNCHANGED <<log, wk, alive, resq, committed, lastC, reqLsa, storedC, storedR, db, markers, stop,
                 errUsed, crashes>>

-----------------------------------------------------------------------------
(* Coordinator: collect results, advance, drain, retire (la_coordinator_collect_and_retire) *)

AttachAll(inf, rs) ==
  [i \in 1..Len(inf) |->
     IF \E j \in 1..Len(rs) : rs[j].lsa = inf[i].task.lsa
     THEN LET j == CHOOSE j \in 1..Len(rs) : rs[j].lsa = inf[i].task.lsa
          IN [inf[i] EXCEPT !.res = IF rs[j].ok THEN "ok" ELSE "err"]
     ELSE inf[i]]

RECURSIVE MarkAll(_, _)
MarkAll(r, rs) ==
  IF rs = << >> THEN r
  ELSE MarkAll(IF Head(rs).ok THEN MarkDone(r, Head(rs).lsa) ELSE r, Tail(rs))

\* number of head entries retired before the first one without a result or with an error
RECURSIVE RetireCount(_)
RetireCount(inf) ==
  IF inf = << >> \/ inf[1].res # "ok" THEN 0 ELSE 1 + RetireCount(Tail(inf))

\* also allowed after a shutdown request: the main loop runs one last collect_and_retire before la_shutdown
\* (log_applier.c:10350)
Collect(doStore) ==
  /\ (~stop \/ Mut # "no_final_collect")
  /\ LET inf1 == AttachAll(infl, resq)
         r1 == MarkAll(ring, resq)
         a == Advance(r1, frontier)
         d == Drain(pending, tq, inf1, a.fr)
         n == RetireCount(d.inf)
         retired == {d.inf[i].task : i \in 1..n}
         errHead == n < Len(d.inf) /\ d.inf[n + 1].res = "err"
         c1 == IF n > 0 /\ a.fr # NULL /\ a.fr > committed THEN a.fr ELSE committed
         freed == {tk.t : tk \in {x \in retired : x.kind = "C" /\ x.hasApply}}
     IN
     /\ (resq # << >> \/ n > 0 \/ d.p # pending \/ errHead)
     /\ resq' = << >>
     /\ ring' = a.r
     /\ frontier' = a.fr
     /\ pending' = d.p
     /\ tq' = d.q
     /\ infl' = [i \in 1..(Len(d.inf) - n) |-> d.inf[i + n]]
     /\ slot' = [t \in Trids |-> IF t \in freed THEN EmptySlot ELSE slot[t]]
     /\ committed' = c1
     /\ stop' = (stop \/ errHead)
     /\ IF doStore /\ n > 0
        THEN /\ storedC' = Max({c1, lastC})
             /\ storedR' = reqLsa
             /\ markers' = {m \in markers : m > c1}
        ELSE UNCHANGED <<storedC, storedR, markers>>
  /\ UNCHANGED <<log, rd, wk, alive, lastC, reqLsa, db, errUsed, crashes, ovf>>

\* la_find_required_lsa
Required ==
  LET c == {slot[t].start : t \in {u \in Trids : slot[u].act}}
           \cup (IF Mut = "req_slots_only" THEN {} ELSE
                  {infl[i].task.start : i \in {j \in 1..Len(infl) : infl[j].task.hasApply}}
                  \cup {pending[i].start : i \in {j \in 1..Len(pending) : pending[j].hasApply}})
  IN IF c = {} THEN rd ELSE Min(c)

\* la_log_commit (periodic, between pages)
LogCommit ==
  /\ ~stop
  /\ LET R == IF Mut = "req_final" THEN rd ELSE Required
         C == Max({committed, lastC})
     IN /\ <<storedC, storedR, reqLsa>> # <<C, R, R>>
        /\ reqLsa' = R
        /\ storedC' = C
        /\ storedR' = R
        /\ markers' = {m \in markers : m > committed}
  /\ UNCHANGED <<log, rd, slot, ring, frontier, pending, tq, infl, wk, alive, resq, committed, lastC, db, stop,
                 errUsed, crashes, ovf>>

-----------------------------------------------------------------------------
(* Workers *)

ErrLsa == Min({i \in 1..N : IsBoundary(i)} \cup {N + 1})

Take(w) ==
  /\ alive[w] /\ wk[w] = NoTask /\ tq # << >>
  /\ wk' = [wk EXCEPT ![w] = Head(tq)]
  /\ tq' = Tail(tq)
  /\ UNCHANGED <<log, rd, slot, ring, frontier, pending, infl, alive, resq, committed, lastC, reqLsa, storedC,
                 storedR, db, markers, stop, errUsed, crashes, ovf>>

Finish(w) ==
  /\ alive[w] /\ wk[w] # NoTask
  /\ LET tk == wk[w]
         skip == IF Mut = "no_marker" THEN tk.lsa <= lastC ELSE (tk.lsa <= lastC \/ tk.lsa \in markers)
         err == ErrMode # "none" /\ ~errUsed /\ tk.items /\ ~skip
     IN
     /\ wk' = [wk EXCEPT ![w] = NoTask]
     /\ resq' = Append(resq, [lsa |-> tk.lsa, ok |-> ~err])
     /\ IF err
        THEN /\ errUsed' = TRUE
             /\ UNCHANGED <<db, markers>>
             /\ alive' = IF ErrMode = "flush" THEN [alive EXCEPT ![w] = FALSE] ELSE alive
             /\ stop' = (stop \/ ErrMode = "flush")
        ELSE /\ IF tk.items /\ ~skip
                THEN /\ db' = Append(db, tk.lsa)
                     /\ markers' = markers \cup {tk.lsa}
                ELSE UNCHANGED <<db, markers>>
             /\ UNCHANGED <<errUsed, alive, stop>>
  /\ UNCHANGED <<log, rd, slot, ring, frontier, pending, tq, infl, committed, lastC, reqLsa, storedC, storedR,
                 crashes, ovf>>

-----------------------------------------------------------------------------
(* Restart: crash or shutdown, then start again from the stored apply info *)

Restart ==
  /\ crashes < MaxCrash
  /\ crashes' = crashes + 1
  /\ rd' = storedR
  /\ committed' = storedR
  /\ lastC' = storedC
  /\ reqLsa' = storedR
  /\ slot' = [t \in Trids |-> EmptySlot]
  /\ ring' = << >> /\ frontier' = NULL /\ pending' = << >> /\ tq' = << >> /\ infl' = << >> /\ resq' = << >>
  /\ wk' = [w \in Workers |-> NoTask] /\ alive' = [w \in Workers |-> TRUE]
  /\ stop' = FALSE
  /\ UNCHANGED <<log, storedC, storedR, db, markers, errUsed, ovf>>

-----------------------------------------------------------------------------

Init ==
  /\ \E skel \in SkelSet :
       LET CPos == {i \in 1..Len(skel) : skel[i].k = "C"} IN
       \E kf \in [CPos -> NonEmptyKeys] :
         \E lf \in [CPos -> LabSet] :
           log = [i \in 1..Len(skel) |->
                    [k |-> skel[i].k, t |-> skel[i].t,
                     keys |-> IF i \in CPos THEN kf[i] ELSE {},
                     lab |-> IF i \in CPos THEN lf[i] ELSE "ok"]]
  /\ rd = 1
  /\ slot = [t \in Trids |-> EmptySlot]
  /\ ring = << >> /\ frontier = NULL /\ pending = << >> /\ tq = << >> /\ infl = << >> /\ resq = << >>
  /\ wk = [w \in Workers |-> NoTask] /\ alive = [w \in Workers |-> TRUE]
  /\ committed = 0 /\ lastC = 0 /\ reqLsa = 1 /\ storedC = 0 /\ storedR = 1
  /\ db = << >> /\ markers = {} /\ stop = FALSE /\ errUsed = FALSE /\ crashes = 0 /\ ovf = FALSE

Progress ==
  \/ ReadRecord
  \/ Collect(TRUE) \/ Collect(FALSE)
  \/ LogCommit
  \/ \E w \in Workers : Take(w) \/ Finish(w)

Quiet ==
  /\ rd > N /\ ~stop
  /\ pending = << >> /\ tq = << >> /\ infl = << >> /\ resq = << >>
  /\ \A w \in Workers : wk[w] = NoTask

Done == Quiet /\ UNCHANGED vars

Halt == stop /\ crashes >= MaxCrash /\ UNCHANGED vars

Next == Progress \/ Restart \/ Done \/ Halt

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Properties *)

DbSet == {db[i] : i \in 1..Len(db)}
Pos(x) == CHOOSE p \in 1..Len(db) : db[p] = x

NoDuplicate == Len(db) = Cardinality(DbSet)

OnlyNeeded == DbSet \subseteq NeedSet

ConflictOrder ==
  \A p \in 1..Len(db) :
    \A a \in NeedSet :
      (a < db[p] /\ Conflict(a, db[p])) => (a \in DbSet /\ Pos(a) < p)

\* committed_lsa never passes a boundary that still has to be applied
PrefixLive == \A b \in NeedSet : b <= committed => b \in DbSet
PrefixStored == \A b \in NeedSet : b <= storedC => b \in DbSet

\* the stored required_lsa does not pass the first record of a transaction that still has to be applied
RequiredStored == \A b \in NeedSet : b \notin DbSet => storedR <= FirstRec(log[b].t)

\* when everything is read and drained, every boundary with items has been applied
QuietAllApplied == Quiet => NeedSet \subseteq DbSet

\* the coordinator is never stuck while work remains (restart excluded)
NotStuck == Quiet \/ stop \/ ENABLED Progress

NoInflightOverflow == ~ovf

\* sanity, expected to fail: the slave really runs out of commit order
SerialOrder == \A p \in 1..Len(db) : \A q \in 1..Len(db) : p < q => db[p] < db[q]
=============================================================================
