---------------------------- MODULE SysopExtended ----------------------------
(***************************************************************************)
(* System operations in the writeset parallel applier, master and slave.  *)
(*                                                                         *)
(* Master (log_manager.c, replication.c, query_executor.c, serial.c):      *)
(*  - Dml: a user row change; record COMMIT_NEED_FLUSH ("CNF"), key kept,  *)
(*    row lock held until the end of the transaction.                      *)
(*  - InstantSysop(t, r): an instant-lock INCR/DECR on user row r, or a    *)
(*    serial update when r is the serial row. Starts a sysop, opens the    *)
(*    flush mark, changes r (record NEED_FLUSH "NF", key r collected),     *)
(*    closes the mark and ends with log_sysop_commit: every NF record from *)
(*    append_repl_recidx is written, the SYSOP_END is labeled with         *)
(*    max(prev_commit, floor), the floor is raised to it and the keys from *)
(*    the sysop's wset_mark are discarded. The change is permanent: a      *)
(*    COMMIT-type SYSOP_END is skipped by rollback. The lock is released.  *)
(*  - LeftoverIncr (flag, known defect path): instant mode stopped inside  *)
(*    the INCR, the sysop is attached to the outer transaction with its   *)
(*    record still NF and its change undoable.                             *)
(*  - Container sysops: Begin / EndCommit (logical-undo type, changes stay *)
(*    undoable) / EndAttach / EndAbort (repl_log_abort_after_lsa,          *)
(*    wset_discard_keys_after_lsa, log_rollback to the parent LSA).        *)
(*  - Commit: every NF/CNF record written, label from published keys and   *)
(*    floor, keys published, locks released. Abort: rollback, ABORT rec.   *)
(*                                                                         *)
(* Slave (log_applier.c, applier/*.cpp):                                   *)
(*  - records gather per transaction; a labeled SYSOP_END with gathered    *)
(*    items detaches all of them into a fragment task (dep = its label)    *)
(*    and sets last_sysop_fragment_lsa; without items its position is     *)
(*    completed at once. A commit task takes the rest, dep = label raised  *)
(*    to last_sysop_fragment_lsa. An abort drops the gathered items.       *)
(*  - tasks enter the ring in log order; frontier = completed prefix;      *)
(*    a task is dispatched when dep <= frontier.                           *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS Txns, Rows, SerialRow, NumWorkers, MaxOps, MaxDepth, None,
          Leftover,        \* enable the known INCR attach-to-outer path
          AllowAbort,      \* allow transaction abort
          MutNoFloor,      \* sanity: a labeled SYSOP_END does not raise the floor
          MutFragDepZero,  \* sanity: fragment task dependency ignored on the slave
          MutKeepSysopKeys,\* sanity: keys of a labeled sysop are not discarded
          MutNoAbortDrop,  \* sanity: sysop abort keeps the records made inside it
          MutNoFragRaise,  \* sanity: the commit dependency is not raised to last_sysop_fragment_lsa
          AllowDdlSerial   \* enable ALTER SERIAL (statement, commit-order) and NEXT_VALUE under its X lock

AllRows == Rows \cup {SerialRow}

VARIABLES
  tstate, opsLeft, stack, recs, aidx, wset, holder, undo, mseq, wid, clk, ovf,
  history, floor, prevCommit, mlog,
  cur, alist, lastFrag, tasks, pushed, done, running, sseq

vars == <<tstate, opsLeft, stack, recs, aidx, wset, holder, undo, mseq, wid, clk, ovf,
          history, floor, prevCommit, mlog,
          cur, alist, lastFrag, tasks, pushed, done, running, sseq>>
mvars == <<tstate, opsLeft, stack, recs, aidx, wset, holder, undo, mseq, wid, clk, ovf, ovf,
           history, floor, prevCommit, mlog>>
svars == <<cur, alist, lastFrag, tasks, pushed, done, running, sseq>>

Max(S) == IF S = {} THEN 0 ELSE CHOOSE m \in S : \A x \in S : x <= m
Range(s) == {s[i] : i \in 1..Len(s)}
SelectSeq2(s, Test(_)) ==
  LET F[i \in 0..Len(s)] == IF i = 0 THEN << >>
                            ELSE IF Test(s[i]) THEN Append(F[i-1], s[i]) ELSE F[i-1]
  IN F[Len(s)]
RemoveW(s, W) == SelectSeq2(s, LAMBDA x : x \notin W)
KeysOf(t) == {wset[t][i].k : i \in 1..Len(wset[t])}

Init ==
  /\ tstate = [t \in Txns |-> "active"]
  /\ opsLeft = [t \in Txns |-> MaxOps]
  /\ stack = [t \in Txns |-> << >>]
  /\ recs = [t \in Txns |-> << >>]
  /\ aidx = [t \in Txns |-> 0]
  /\ wset = [t \in Txns |-> << >>]
  /\ holder = [r \in AllRows |-> None]
  /\ undo = [t \in Txns |-> << >>]
  /\ mseq = [r \in AllRows |-> << >>]
  /\ wid = 0
  /\ clk = 0
  /\ ovf = [t \in Txns |-> FALSE]
  /\ history = [r \in AllRows |-> 0]
  /\ floor = 0
  /\ prevCommit = 0
  /\ mlog = << >>
  /\ cur = 0
  /\ alist = [t \in Txns |-> << >>]
  /\ lastFrag = [t \in Txns |-> 0]
  /\ tasks = {}
  /\ pushed = {}
  /\ done = {}
  /\ running = {}
  /\ sseq = [r \in AllRows |-> << >>]

-----------------------------------------------------------------------------
(* Master *)

Active(t) == tstate[t] = "active" /\ opsLeft[t] > 0

\* records written by log_append_repl_info(is_commit = FALSE) from index aidx[t]
NFFrom(t) == {i \in (aidx[t] + 1)..Len(recs[t]) : recs[t][i].mf = "NF"}
\* the log entries for a list of record indices, in array order
RecEntries(t, R, rs) ==
  LET idx == SelectSeq2([i \in 1..Len(rs) |-> i], LAMBDA i : i \in R)
  IN [j \in 1..Len(idx) |-> [kind |-> "rec", txn |-> t, w |-> rs[idx[j]].w, row |-> rs[idx[j]].row]]

Dml(t, r) ==
  /\ Active(t)
  /\ holder[r] \in {None, t}
  /\ LET w == wid + 1  l == clk + 1 IN
     /\ wid' = w /\ clk' = l
     /\ holder' = [holder EXCEPT ![r] = t]
     /\ recs' = [recs EXCEPT ![t] = Append(@, [w |-> w, row |-> r, mf |-> "CNF", lsa |-> l])]
     /\ wset' = [wset EXCEPT ![t] = IF ovf[t] THEN @ ELSE Append(@, [k |-> r, lsa |-> l])]
     /\ undo' = [undo EXCEPT ![t] = Append(@, [w |-> w, row |-> r, lsa |-> l])]
     /\ mseq' = [mseq EXCEPT ![r] = Append(@, w)]
  /\ opsLeft' = [opsLeft EXCEPT ![t] = @ - 1]
  /\ UNCHANGED <<tstate, stack, aidx, history, floor, prevCommit, mlog, ovf, svars>>

\* ALTER SERIAL: statement replication sends the transaction to commit order (replication.c:610) and keeps the
\* serial row X-locked; its record is written at commit.
AlterSerial(t) ==
  /\ AllowDdlSerial
  /\ Active(t)
  /\ holder[SerialRow] \in {None, t}
  /\ LET w == wid + 1  l == clk + 1 IN
     /\ wid' = w /\ clk' = l
     /\ holder' = [holder EXCEPT ![SerialRow] = t]
     /\ recs' = [recs EXCEPT ![t] = Append(@, [w |-> w, row |-> SerialRow, mf |-> "CNF", lsa |-> l])]
     /\ wset' = [wset EXCEPT ![t] = << >>]
     /\ ovf' = [ovf EXCEPT ![t] = TRUE]
     /\ undo' = [undo EXCEPT ![t] = Append(@, [w |-> w, row |-> SerialRow, lsa |-> l])]
     /\ mseq' = [mseq EXCEPT ![SerialRow] = Append(@, w)]
  /\ opsLeft' = [opsLeft EXCEPT ![t] = @ - 1]
  /\ UNCHANGED <<tstate, stack, aidx, history, floor, prevCommit, mlog, svars>>

\* NEXT_VALUE while t holds the serial row X lock: no sysop, no flush mark, no key (serial.c:1236-1245, 1277-1290)
SerialUnderX(t) ==
  /\ AllowDdlSerial
  /\ Active(t)
  /\ holder[SerialRow] = t
  /\ LET w == wid + 1  l == clk + 1 IN
     /\ wid' = w /\ clk' = l
     /\ recs' = [recs EXCEPT ![t] = Append(@, [w |-> w, row |-> SerialRow, mf |-> "CNF", lsa |-> l])]
     /\ undo' = [undo EXCEPT ![t] = Append(@, [w |-> w, row |-> SerialRow, lsa |-> l])]
     /\ mseq' = [mseq EXCEPT ![SerialRow] = Append(@, w)]
  /\ opsLeft' = [opsLeft EXCEPT ![t] = @ - 1]
  /\ UNCHANGED <<tstate, stack, aidx, wset, holder, history, floor, prevCommit, mlog, ovf, svars>>

\* instant INCR on a user row, or a serial update (r = SerialRow): atomic sysop with a COMMIT-type end
InstantSysop(t, r) ==
  /\ Active(t)
  /\ Len(stack[t]) < MaxDepth
  /\ holder[r] = None                \* held by t: instant mode is stopped (lock_manager.c:3984-3993) -> Dml path
  /\ LET w == wid + 1  l == clk + 1
         mark == Len(wset[t])
         rs == Append(recs[t], [w |-> w, row |-> r, mf |-> "NF", lsa |-> l])
         R == {i \in (aidx[t] + 1)..Len(rs) : rs[i].mf = "NF"}
         ents == RecEntries(t, R, rs)
         sendIdx == Len(mlog) + Len(ents) + 1
         dep == Max({prevCommit, floor})
     IN /\ wid' = w /\ clk' = l
        /\ recs' = [recs EXCEPT ![t] = [i \in 1..Len(rs) |-> IF i \in R THEN [rs[i] EXCEPT !.mf = "DONE"] ELSE rs[i]]]
        /\ aidx' = [aidx EXCEPT ![t] = Len(rs)]
        /\ mlog' = mlog \o ents \o << [kind |-> "send", txn |-> t, dep |-> dep, w |-> 0, row |-> None] >>
        /\ floor' = IF MutNoFloor THEN floor ELSE sendIdx
        /\ wset' = [wset EXCEPT ![t] = IF ovf[t] THEN @
                                       ELSE IF MutKeepSysopKeys THEN Append(@, [k |-> r, lsa |-> l])
                                       ELSE SubSeq(@, 1, mark)]
        /\ mseq' = [mseq EXCEPT ![r] = Append(@, w)]
  /\ opsLeft' = [opsLeft EXCEPT ![t] = @ - 1]
  /\ UNCHANGED <<tstate, stack, holder, undo, history, prevCommit, ovf, svars>>

\* known path: instant mode stopped mid-INCR, sysop attached to the outer transaction, record left NF
LeftoverIncr(t, r) ==
  /\ Leftover
  /\ Active(t)
  /\ r \in Rows
  /\ holder[r] = None
  /\ LET w == wid + 1  l == clk + 1 IN
     /\ wid' = w /\ clk' = l
     /\ holder' = [holder EXCEPT ![r] = t]
     /\ recs' = [recs EXCEPT ![t] = Append(@, [w |-> w, row |-> r, mf |-> "NF", lsa |-> l])]
     /\ wset' = [wset EXCEPT ![t] = IF ovf[t] THEN @ ELSE Append(@, [k |-> r, lsa |-> l])]
     /\ undo' = [undo EXCEPT ![t] = Append(@, [w |-> w, row |-> r, lsa |-> l])]
     /\ mseq' = [mseq EXCEPT ![r] = Append(@, w)]
  /\ opsLeft' = [opsLeft EXCEPT ![t] = @ - 1]
  /\ UNCHANGED <<tstate, stack, aidx, history, floor, prevCommit, mlog, ovf, svars>>

BeginSysop(t) ==
  /\ Active(t)
  /\ Len(stack[t]) < MaxDepth
  /\ stack' = [stack EXCEPT ![t] = Append(@, [mark |-> Len(wset[t]), parent |-> clk])]
  /\ opsLeft' = [opsLeft EXCEPT ![t] = @ - 1]
  /\ UNCHANGED <<tstate, recs, aidx, wset, holder, undo, mseq, wid, clk, history, floor, prevCommit, mlog, ovf, svars>>

Pop(t) == stack' = [stack EXCEPT ![t] = SubSeq(@, 1, Len(@) - 1)]
Top(t) == stack[t][Len(stack[t])]

\* container end through log_sysop_commit_internal (logical-undo type: its changes stay undoable)
EndSysopCommit(t) ==
  /\ tstate[t] = "active"
  /\ stack[t] # << >>
  /\ clk > Top(t).parent             \* not empty (an empty COMMIT-type end returns early)
  /\ LET R == NFFrom(t)
         ents == RecEntries(t, R, recs[t])
         sendIdx == Len(mlog) + Len(ents) + 1
         labeled == R # {}
     IN /\ recs' = [recs EXCEPT ![t] = [i \in 1..Len(@) |-> IF i \in R THEN [@[i] EXCEPT !.mf = "DONE"] ELSE @[i]]]
        /\ aidx' = [aidx EXCEPT ![t] = Len(recs[t])]
        /\ IF labeled
             THEN /\ mlog' = mlog \o ents \o << [kind |-> "send", txn |-> t, dep |-> Max({prevCommit, floor}),
                                                 w |-> 0, row |-> None] >>
                  /\ floor' = IF MutNoFloor THEN floor ELSE sendIdx
                  /\ wset' = [wset EXCEPT ![t] = IF MutKeepSysopKeys THEN @ ELSE SubSeq(@, 1, Top(t).mark)]
             ELSE UNCHANGED <<mlog, floor, wset>>
  /\ Pop(t)
  /\ UNCHANGED <<tstate, opsLeft, holder, undo, mseq, wid, clk, history, prevCommit, ovf, svars>>

EndSysopAttach(t) ==
  /\ tstate[t] = "active"
  /\ stack[t] # << >>
  /\ Pop(t)
  /\ UNCHANGED <<tstate, opsLeft, recs, aidx, wset, holder, undo, mseq, wid, clk, history, floor, prevCommit, mlog, ovf, svars>>

EndSysopAbort(t) ==
  /\ tstate[t] = "active"
  /\ stack[t] # << >>
  /\ LET p == Top(t).parent
         U == {undo[t][i] : i \in 1..Len(undo[t])}
         gone == {u.w : u \in {x \in U : x.lsa > p}}
     IN /\ mseq' = [r \in AllRows |-> RemoveW(mseq[r], gone)]
        /\ undo' = [undo EXCEPT ![t] = SelectSeq2(@, LAMBDA x : x.lsa <= p)]
        /\ recs' = [recs EXCEPT ![t] = [i \in 1..Len(@) |->
                       IF @[i].lsa > p /\ ~MutNoAbortDrop THEN [@[i] EXCEPT !.mf = "DROP"] ELSE @[i]]]
        /\ wset' = [wset EXCEPT ![t] = SelectSeq2(@, LAMBDA x : x.lsa <= p)]
  /\ Pop(t)
  /\ UNCHANGED <<tstate, opsLeft, aidx, holder, wid, clk, history, floor, prevCommit, mlog, ovf, svars>>

Commit(t) ==
  /\ tstate[t] = "active"
  /\ stack[t] = << >>
  /\ LET R == {i \in 1..Len(recs[t]) : recs[t][i].mf \in {"NF", "CNF"}}
         ents == RecEntries(t, R, recs[t])
         cidx == Len(mlog) + Len(ents) + 1
         keys == IF ovf[t] THEN {} ELSE KeysOf(t)
         dep == IF ovf[t] THEN Max({prevCommit, floor}) ELSE Max({history[k] : k \in keys} \cup {floor})
     IN /\ mlog' = mlog \o ents \o << [kind |-> "commit", txn |-> t, dep |-> dep, w |-> 0, row |-> None,
                                       keys |-> keys, rows |-> {recs[t][i].row : i \in R}, ovf |-> ovf[t]] >>
        /\ history' = [k \in AllRows |-> IF k \in keys THEN cidx ELSE history[k]]
        /\ prevCommit' = cidx
        /\ floor' = IF ovf[t] THEN Max({floor, cidx}) ELSE floor
  /\ holder' = [r \in AllRows |-> IF holder[r] = t THEN None ELSE holder[r]]
  /\ tstate' = [tstate EXCEPT ![t] = "committed"]
  /\ UNCHANGED <<opsLeft, stack, recs, aidx, wset, undo, mseq, wid, clk, ovf, svars>>

Abort(t) ==
  /\ AllowAbort
  /\ tstate[t] = "active"
  /\ stack[t] = << >>
  /\ LET gone == {undo[t][i].w : i \in 1..Len(undo[t])}
     IN mseq' = [r \in AllRows |-> RemoveW(mseq[r], gone)]
  /\ mlog' = Append(mlog, [kind |-> "abort", txn |-> t, dep |-> 0, w |-> 0, row |-> None])
  /\ holder' = [r \in AllRows |-> IF holder[r] = t THEN None ELSE holder[r]]
  /\ tstate' = [tstate EXCEPT ![t] = "aborted"]
  /\ UNCHANGED <<opsLeft, stack, recs, aidx, wset, undo, wid, clk, history, floor, prevCommit, ovf, svars>>

-----------------------------------------------------------------------------
(* Slave *)

Frontier == Max({p \in pushed \cup {0} : \A q \in pushed : q <= p => q \in done})

Read ==
  /\ cur < Len(mlog)
  /\ LET i == cur + 1  e == mlog[i]  t == e.txn IN
     CASE e.kind = "rec" ->
            /\ alist' = [alist EXCEPT ![t] = Append(@, [w |-> e.w, row |-> e.row])]
            /\ UNCHANGED <<lastFrag, tasks, pushed, done>>
       [] e.kind = "send" /\ alist[t] # << >> ->
            /\ tasks' = tasks \cup {[id |-> i, items |-> alist[t], dep |-> IF MutFragDepZero THEN 0 ELSE e.dep]}
            /\ alist' = [alist EXCEPT ![t] = << >>]
            /\ lastFrag' = [lastFrag EXCEPT ![t] = i]
            /\ pushed' = pushed \cup {i}
            /\ UNCHANGED done
       [] e.kind = "send" ->
            /\ pushed' = pushed \cup {i}
            /\ done' = done \cup {i}
            /\ UNCHANGED <<alist, lastFrag, tasks>>
       [] e.kind = "commit" ->
            /\ tasks' = tasks \cup {[id |-> i, items |-> alist[t], dep |-> IF MutNoFragRaise THEN e.dep ELSE Max({e.dep, lastFrag[t]})]}
            /\ alist' = [alist EXCEPT ![t] = << >>]
            /\ pushed' = pushed \cup {i}
            /\ UNCHANGED <<lastFrag, done>>
       [] e.kind = "abort" ->
            /\ alist' = [alist EXCEPT ![t] = << >>]
            /\ UNCHANGED <<lastFrag, tasks, pushed, done>>
  /\ cur' = cur + 1
  /\ UNCHANGED <<running, sseq, mvars>>

StartTask(k) ==
  /\ k \in tasks
  /\ k.id \notin done
  /\ k.id \notin {x.id : x \in running}
  /\ Cardinality(running) < NumWorkers
  /\ k.dep <= Frontier
  /\ running' = running \cup {k}
  /\ UNCHANGED <<cur, alist, lastFrag, tasks, pushed, done, sseq, mvars>>

FinishTask(k) ==
  /\ k \in running
  /\ sseq' = [r \in AllRows |->
               sseq[r] \o SelectSeq2([j \in 1..Len(k.items) |-> k.items[j].w],
                                     LAMBDA w : \E j \in 1..Len(k.items) : k.items[j].w = w /\ k.items[j].row = r)]
  /\ done' = done \cup {k.id}
  /\ running' = running \ {k}
  /\ UNCHANGED <<cur, alist, lastFrag, tasks, pushed, mvars>>

AllDone ==
  /\ \A t \in Txns : tstate[t] \in {"committed", "aborted"}
  /\ cur = Len(mlog)
  /\ running = {}
  /\ \A k \in tasks : k.id \in done

Finished == AllDone /\ UNCHANGED vars

Next ==
  \/ \E t \in Txns, r \in Rows : Dml(t, r) \/ LeftoverIncr(t, r)
  \/ \E t \in Txns, r \in AllRows : InstantSysop(t, r)
  \/ \E t \in Txns : AlterSerial(t) \/ SerialUnderX(t)
  \/ \E t \in Txns : BeginSysop(t) \/ EndSysopCommit(t) \/ EndSysopAttach(t) \/ EndSysopAbort(t)
                     \/ Commit(t) \/ Abort(t)
  \/ Read
  \/ \E k \in tasks : StartTask(k)
  \/ \E k \in running : FinishTask(k)
  \/ Finished

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Properties *)

IsPrefix(a, b) == Len(a) <= Len(b) /\ a = SubSeq(b, 1, Len(a))

\* Every row's slave apply sequence is a prefix of its master order (no reorder, no change the master undid).
ConflictOrder == \A r \in AllRows : IsPrefix(sseq[r], mseq[r])

\* At the end the slave has exactly the master's surviving changes, in order.
FinalEqual == AllDone => \A r \in AllRows : sseq[r] = mseq[r]

\* A commit publishes the key of every user row whose record it carries.
CommitEntries == {mlog[i] : i \in {j \in 1..Len(mlog) : mlog[j].kind = "commit"}}
NoLostKey == \A e \in CommitEntries : e.ovf \/ (e.rows \cap Rows) \subseteq e.keys

\* The serial key is never published at commit (its lock was released at its SYSOP_END).
NoSerialKeyPublished == \A e \in CommitEntries : SerialRow \notin e.keys

\* Every task the slave builds waits only for earlier log positions (no self-wait).
Perms == Permutations(Txns)

DepBelowSelf == \A k \in tasks : k.dep < k.id
=============================================================================
