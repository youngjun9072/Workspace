---------------------------- MODULE WritesetApply ----------------------------
(***************************************************************************)
(* Step 2 skeleton: an ideal writeset master and a parallel slave.        *)
(*                                                                         *)
(* Master: each transaction locks all the keys it writes, commits, and at  *)
(* commit records a dependency = the latest commit sequence that touched   *)
(* any of its keys (the writeset history), then publishes its keys.        *)
(* Slave: workers apply commits out of order, but a commit may start only  *)
(* when every commit up to its dependency has been applied.                *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS Txns, Keys, NumWorkers, None

VARIABLES
  ws,        \* ws[t]: keys transaction t writes (chosen in Init)
  tstate,    \* "idle" | "active" | "committed"
  holder,    \* holder[k]: transaction holding the row lock on k, or None
  history,   \* history[k]: commit sequence of the last committer of k (0 = none)
  mlog,      \* master commit log: sequence of [txn, dep, keys]; index = commit sequence
  running,   \* log indices being applied by workers; at most NumWorkers at a time
  applied    \* slave apply order: sequence of log indices

vars == <<ws, tstate, holder, history, mlog, running, applied>>

AppliedSet == {applied[i] : i \in 1..Len(applied)}

-----------------------------------------------------------------------------
(* Master *)

Init ==
  /\ ws \in [Txns -> (SUBSET Keys) \ {{}}]
  /\ tstate = [t \in Txns |-> "idle"]
  /\ holder = [k \in Keys |-> None]
  /\ history = [k \in Keys |-> 0]
  /\ mlog = << >>
  /\ running = {}
  /\ applied = << >>

\* Conservative two-phase locking: take every key of the transaction at once.
Lock(t) ==
  /\ tstate[t] = "idle"
  /\ \A k \in ws[t] : holder[k] = None
  /\ holder' = [k \in Keys |-> IF k \in ws[t] THEN t ELSE holder[k]]
  /\ tstate' = [tstate EXCEPT ![t] = "active"]
  /\ UNCHANGED <<ws, history, mlog, running, applied>>

Max(S) == IF S = {} THEN 0 ELSE CHOOSE m \in S : \A x \in S : x <= m

\* Commit: dependency from the history, publish keys, release locks, all at once.
Commit(t) ==
  /\ tstate[t] = "active"
  /\ LET seq == Len(mlog) + 1
         dep == Max({history[k] : k \in ws[t]})
     IN /\ mlog' = Append(mlog, [txn |-> t, dep |-> dep, keys |-> ws[t]])
        /\ history' = [k \in Keys |-> IF k \in ws[t] THEN seq ELSE history[k]]
  /\ holder' = [k \in Keys |-> IF k \in ws[t] THEN None ELSE holder[k]]
  /\ tstate' = [tstate EXCEPT ![t] = "committed"]
  /\ UNCHANGED <<ws, running, applied>>

-----------------------------------------------------------------------------
(* Slave *)

\* A commit may start once every commit with sequence <= its dependency is applied.
Ready(i) == \A j \in 1..mlog[i].dep : j \in AppliedSet

\* Workers are interchangeable, so only how many are busy matters.
Start(i) ==
  /\ Cardinality(running) < NumWorkers
  /\ i \notin AppliedSet
  /\ i \notin running
  /\ Ready(i)
  /\ running' = running \cup {i}
  /\ UNCHANGED <<ws, tstate, holder, history, mlog, applied>>

\* The rows of the commit take effect on the slave when the worker finishes it.
Finish(i) ==
  /\ i \in running
  /\ applied' = Append(applied, i)
  /\ running' = running \ {i}
  /\ UNCHANGED <<ws, tstate, holder, history, mlog>>

Done ==
  /\ \A t \in Txns : tstate[t] = "committed"
  /\ Len(applied) = Len(mlog)
  /\ UNCHANGED vars

Next ==
  \/ \E t \in Txns : Lock(t) \/ Commit(t)
  \/ \E i \in 1..Len(mlog) : Start(i)
  \/ \E i \in running : Finish(i)
  \/ Done

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Properties *)

TypeOK ==
  /\ tstate \in [Txns -> {"idle", "active", "committed"}]
  /\ holder \in [Keys -> Txns \cup {None}]
  /\ running \subseteq 1..Cardinality(Txns)
  /\ Cardinality(running) <= NumWorkers

Pos(i) == CHOOSE p \in 1..Len(applied) : applied[p] = i
Conflict(i, j) == mlog[i].keys \cap mlog[j].keys # {}

\* Two commits that touched a common key are applied in master commit order.
ConflictOrder ==
  \A p \in 1..Len(applied) :
    LET j == applied[p] IN
      \A i \in 1..(j - 1) :
        Conflict(i, j) => (i \in AppliedSet /\ Pos(i) < p)

\* Every commit is applied at most once.
NoDuplicate == Len(applied) = Cardinality(AppliedSet)

\* Sanity check, expected to FAIL: the slave really applies out of commit order.
SerialOrder == \A p \in 1..Len(applied) : applied[p] = p
=============================================================================
