----------------------------- MODULE WritesetSysop -----------------------------
(***************************************************************************)
(* Step 3: key loss at a labeled SYSOP_END (log_manager.c, log_sysop_end). *)
(*                                                                         *)
(* An INCR/DECR system operation ends attached to its transaction and      *)
(* leaves its replication record unwritten (NEED_FLUSH). The next system   *)
(* operation of the same transaction writes that record at its SYSOP_END, *)
(* so that SYSOP_END is labeled: the writeset label raises the history     *)
(* floor (commit-order barrier), and the keys collected inside the         *)
(* operation are discarded (wset_discard_sysop_keys). When that next       *)
(* operation is an ordinary DML, the discarded key is a user row whose     *)
(* lock is held until the outer commit, so it should have been published. *)
(*                                                                         *)
(* A serial system operation (AUTO_INCREMENT, NEXT_VALUE) is the case the *)
(* discard was made for: its row lock is released at SYSOP_END and its     *)
(* record is written there, so its key must not be published at commit.   *)
(*                                                                         *)
(* FixDiscard = FALSE models the current code; TRUE discards only the keys *)
(* that were collected inside the operation AND belong to a record this    *)
(* SYSOP_END actually wrote.                                               *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS Txns, Keys, SerialKeys, NumWorkers, None, FixDiscard

VARIABLES
  tstate,    \* "idle" | "active" | "committed"
  incrDone,  \* incrDone[t]: t already ran its INCR operation
  serialDone, \* serialDone[t]: t already ran its serial operation (one per transaction bounds the model)
  pending,   \* pending[t]: t has an INCR record left unwritten (NEED_FLUSH)
  written,   \* written[t]: user row keys t changed (ground truth)
  wset,      \* wset[t]: keys t still holds for publication at commit
  holder,    \* holder[k]: transaction holding the row lock on k, or None
  history,   \* history[k]: log sequence of the last commit that published k (0 = none)
  floor,     \* history floor raised by a labeled SYSOP_END (commit-order barrier)
  mlog,      \* master log entries: [kind, txn, dep, keys]; index = log sequence
  running,   \* log entries being applied by slave workers
  applied    \* slave apply order: sequence of log indices

vars == <<tstate, incrDone, serialDone, pending, written, wset, holder, history, floor, mlog, running, applied>>

AppliedSet == {applied[i] : i \in 1..Len(applied)}
Max(S) == IF S = {} THEN 0 ELSE CHOOSE m \in S : \A x \in S : x <= m

-----------------------------------------------------------------------------
(* Master *)

Init ==
  /\ tstate = [t \in Txns |-> "idle"]
  /\ incrDone = [t \in Txns |-> FALSE]
  /\ serialDone = [t \in Txns |-> FALSE]
  /\ pending = [t \in Txns |-> FALSE]
  /\ written = [t \in Txns |-> {}]
  /\ wset = [t \in Txns |-> {}]
  /\ holder = [k \in Keys |-> None]
  /\ history = [k \in Keys |-> 0]
  /\ floor = 0
  /\ mlog = << >>
  /\ running = {}
  /\ applied = << >>

\* INCR/DECR: a system operation that ends attached to its transaction. Its record stays NEED_FLUSH.
IncrAttach(t) ==
  /\ tstate[t] # "committed"
  /\ ~incrDone[t]
  /\ incrDone' = [incrDone EXCEPT ![t] = TRUE]
  /\ pending' = [pending EXCEPT ![t] = TRUE]
  /\ tstate' = [tstate EXCEPT ![t] = "active"]
  /\ UNCHANGED <<serialDone, written, wset, holder, history, floor, mlog, running, applied>>

\* End of a system operation of t that collected the keys "collected". "ownKeys" are the keys of the operation's own
\* NEED_FLUSH record ({} when its record is written at commit). A pending INCR record is written here too. The
\* SYSOP_END is labeled when it writes any record.
EndSysop(t, collected, ownNeedFlush, ownKeys) ==
  LET labeled     == pending[t] \/ ownNeedFlush
      writtenKeys == IF ownNeedFlush THEN ownKeys ELSE {}   \* the INCR record carries no key here
      discard     == IF ~labeled THEN {}
                     ELSE IF FixDiscard THEN collected \cap writtenKeys
                     ELSE collected
  IN /\ wset' = [wset EXCEPT ![t] = @ \cup (collected \ discard)]
     /\ IF labeled
          THEN /\ mlog' = Append(mlog, [kind |-> "frag", txn |-> t, dep |-> Len(mlog), keys |-> writtenKeys])
               /\ floor' = Len(mlog) + 1
               /\ pending' = [pending EXCEPT ![t] = FALSE]
          ELSE UNCHANGED <<mlog, floor, pending>>

\* An ordinary DML statement run inside a system operation: it changes user row k and keeps the row lock until
\* the outer commit; its own record is written at commit.
DmlSysop(t, k) ==
  /\ tstate[t] # "committed"
  /\ k \notin written[t]
  /\ holder[k] \in {None, t}
  /\ holder' = [holder EXCEPT ![k] = t]
  /\ written' = [written EXCEPT ![t] = @ \cup {k}]
  /\ tstate' = [tstate EXCEPT ![t] = "active"]
  /\ EndSysop(t, {k}, FALSE, {})
  /\ UNCHANGED <<incrDone, serialDone, history, running, applied>>

\* A serial update: the serial row lock is taken and released inside the operation, and its record is written at
\* its own SYSOP_END, so the slave applies it as a labeled fragment in commit order.
SerialSysop(t, sk) ==
  /\ tstate[t] # "committed"
  /\ ~serialDone[t]
  /\ serialDone' = [serialDone EXCEPT ![t] = TRUE]
  /\ tstate' = [tstate EXCEPT ![t] = "active"]
  /\ EndSysop(t, {sk}, TRUE, {sk})
  /\ UNCHANGED <<incrDone, written, holder, history, running, applied>>

\* Commit: dependency from the published keys and the history floor; publish the keys; release the locks.
Commit(t) ==
  /\ tstate[t] = "active"
  /\ LET seq == Len(mlog) + 1
         dep == Max({history[k] : k \in wset[t] \cap Keys} \cup {floor})
     IN /\ mlog' = Append(mlog, [kind |-> "commit", txn |-> t, dep |-> dep, keys |-> written[t]])
        /\ history' = [k \in Keys |-> IF k \in wset[t] THEN seq ELSE history[k]]
  /\ holder' = [k \in Keys |-> IF holder[k] = t THEN None ELSE holder[k]]
  /\ pending' = [pending EXCEPT ![t] = FALSE]
  /\ tstate' = [tstate EXCEPT ![t] = "committed"]
  /\ UNCHANGED <<incrDone, serialDone, written, wset, floor, running, applied>>

-----------------------------------------------------------------------------
(* Slave: same rule as the skeleton *)

Ready(i) == \A j \in 1..mlog[i].dep : j \in AppliedSet

Start(i) ==
  /\ Cardinality(running) < NumWorkers
  /\ i \notin AppliedSet
  /\ i \notin running
  /\ Ready(i)
  /\ running' = running \cup {i}
  /\ UNCHANGED <<tstate, incrDone, serialDone, pending, written, wset, holder, history, floor, mlog, applied>>

Finish(i) ==
  /\ i \in running
  /\ applied' = Append(applied, i)
  /\ running' = running \ {i}
  /\ UNCHANGED <<tstate, incrDone, serialDone, pending, written, wset, holder, history, floor, mlog>>

Done ==
  /\ \A t \in Txns : tstate[t] = "committed"
  /\ Len(applied) = Len(mlog)
  /\ UNCHANGED vars

Next ==
  \/ \E t \in Txns : IncrAttach(t) \/ Commit(t)
  \/ \E t \in Txns, k \in Keys : DmlSysop(t, k)
  \/ \E t \in Txns, sk \in SerialKeys : SerialSysop(t, sk)
  \/ \E i \in 1..Len(mlog) : Start(i)
  \/ \E i \in running : Finish(i)
  \/ Done

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Properties *)

Pos(i) == CHOOSE p \in 1..Len(applied) : applied[p] = i
Conflict(i, j) == mlog[i].keys \cap mlog[j].keys # {}

\* Two commits that changed a common row are applied in master commit order.
ConflictOrder ==
  \A p \in 1..Len(applied) :
    LET j == applied[p] IN
      \A i \in 1..(j - 1) :
        Conflict(i, j) => (i \in AppliedSet /\ Pos(i) < p)

\* A committed transaction published every user row it changed.
NoLostKey == \A t \in Txns : tstate[t] = "committed" => written[t] \subseteq wset[t]

\* A serial key is never held for publication at commit: its lock was released at SYSOP_END.
NoSerialKeyPublished == \A t \in Txns : wset[t] \cap SerialKeys = {}
=============================================================================
