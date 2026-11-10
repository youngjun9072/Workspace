-------------------------- MODULE RKNormalChange ---------------------------
EXTENDS Integers, Sequences, TLC

\* Both nodes begin with identical rows and UNIQUE(code), UNIQUE(alt).
\* The master emits ordered DDL/RBR logs. The slave applies each log in order.
\* Representation order in this model: PK(id), UNIQUE(code), UNIQUE(alt).
\* The class property installer puts PRIMARY_KEY before UNIQUE.
\* This models successful DDL on both nodes; no error injection is present.
CONSTANT Guarded
ASSUME Guarded \in BOOLEAN

Rows == {"r1", "r2"}
InitialRows ==
  [r \in Rows |->
    [id |-> IF r = "r1" THEN 1 ELSE 2,
     code |-> IF r = "r1" THEN 2 ELSE 1,
     alt |-> IF r = "r1" THEN 4 ELSE 1,
     value |-> 0,
     alive |-> TRUE]]

RK(pk, codeUnique) == IF pk THEN "id" ELSE IF codeUnique THEN "code" ELSE "alt"
Key(rows, rk, r) ==
  IF rk = "id" THEN rows[r].id ELSE IF rk = "code" THEN rows[r].code ELSE rows[r].alt

VARIABLES masterStep, log, masterPK, slavePK, masterCodeUnique, slaveCodeUnique,
          masterRows, slaveRows, wrongRow, rkMismatch, applyFail
vars == <<masterStep, log, masterPK, slavePK, masterCodeUnique, slaveCodeUnique,
          masterRows, slaveRows, wrongRow, rkMismatch, applyFail>>

Init ==
  /\ masterStep = 0
  /\ log = <<>>
  /\ masterPK = FALSE /\ slavePK = FALSE
  /\ masterCodeUnique = TRUE /\ slaveCodeUnique = TRUE
  /\ masterRows = InitialRows /\ slaveRows = InitialRows
  /\ wrongRow = FALSE /\ rkMismatch = FALSE /\ applyFail = FALSE

\* Step 0: UPDATE with UNIQUE(code). Step 1: ADD PK(id).
\* Step 2: UPDATE with PK(id). Step 3: DROP PK.
\* Step 4: UPDATE with UNIQUE(code). Step 5: DROP UNIQUE(code).
\* Step 6: DELETE with UNIQUE(alt).
MasterDo ==
  /\ masterStep < 7
  /\ LET s == masterStep
         rk == RK(masterPK, masterCodeUnique)
         after == IF s = 0 THEN [masterRows EXCEPT !["r1"].code = 3, !["r1"].value = 1]
                  ELSE IF s = 2 THEN [masterRows EXCEPT !["r1"].value = 2]
                  ELSE IF s = 4 THEN [masterRows EXCEPT !["r1"].value = 3]
                  ELSE IF s = 6 THEN [masterRows EXCEPT !["r1"].alive = FALSE]
                  ELSE masterRows
         entry == IF s = 1 THEN [kind |-> "AddPK"]
                  ELSE IF s = 3 THEN [kind |-> "DropPK"]
                  ELSE IF s = 5 THEN [kind |-> "DropCodeUnique"]
                  ELSE [kind |-> "DML", rk |-> rk,
                        key |-> Key(masterRows, rk, "r1"), row |-> after["r1"]]
     IN /\ masterRows' = after
        /\ log' = Append(log, entry)
        /\ masterPK' = IF s = 1 THEN TRUE ELSE IF s = 3 THEN FALSE ELSE masterPK
        /\ masterCodeUnique' = IF s = 5 THEN FALSE ELSE masterCodeUnique
  /\ masterStep' = masterStep + 1
  /\ UNCHANGED <<slavePK, slaveCodeUnique, slaveRows, wrongRow, rkMismatch, applyFail>>

SlaveApply ==
  /\ Len(log) > 0
  /\ LET entry == Head(log)
         localRK == RK(slavePK, slaveCodeUnique)
         guardRejected == Guarded /\ entry.kind = "DML" /\ entry.rk # localRK
         candidates == IF entry.kind = "DML"
                       THEN {r \in Rows : slaveRows[r].alive /\ Key(slaveRows, localRK, r) = entry.key}
                       ELSE {}
     IN /\ slavePK' = IF entry.kind = "AddPK" THEN TRUE
                       ELSE IF entry.kind = "DropPK" THEN FALSE ELSE slavePK
        /\ slaveCodeUnique' = IF entry.kind = "DropCodeUnique" THEN FALSE ELSE slaveCodeUnique
        /\ rkMismatch' = rkMismatch \/ (entry.kind = "DML" /\ entry.rk # localRK)
        /\ applyFail' = applyFail \/ (entry.kind = "DML" /\ candidates = {}) \/ guardRejected
        /\ slaveRows' = IF entry.kind # "DML" \/ candidates = {} \/ guardRejected
                         THEN slaveRows
                         ELSE LET target == CHOOSE r \in candidates : TRUE
                              IN [slaveRows EXCEPT ![target] = entry.row]
        /\ wrongRow' = wrongRow \/
                        (entry.kind = "DML" /\ candidates # {} /\ ~guardRejected /\
                         (CHOOSE r \in candidates : TRUE) # "r1")
  /\ log' = Tail(log)
  /\ UNCHANGED <<masterStep, masterPK, masterCodeUnique, masterRows>>

Next == MasterDo \/ SlaveApply
Spec == Init /\ [][Next]_vars

TypeOK ==
  /\ masterStep \in 0..7
  /\ masterPK \in BOOLEAN /\ slavePK \in BOOLEAN
  /\ masterCodeUnique \in BOOLEAN /\ slaveCodeUnique \in BOOLEAN
  /\ wrongRow \in BOOLEAN /\ rkMismatch \in BOOLEAN /\ applyFail \in BOOLEAN
  /\ \A r \in Rows : masterRows[r].alive \in BOOLEAN /\ slaveRows[r].alive \in BOOLEAN
  /\ Len(log) \in 0..7

NoWrongRow == ~wrongRow
NoRKMismatch == ~rkMismatch
NoApplyFailure == ~applyFail
ConvergesWhenCaughtUp ==
  Len(log) = 0 =>
    /\ masterRows = slaveRows
    /\ masterPK = slavePK
    /\ masterCodeUnique = slaveCodeUnique

=============================================================================
