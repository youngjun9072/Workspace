---------------------------- MODULE RKSpecCases ----------------------------
EXTENDS Integers, Sequences, TLC

\* A bounded model of normal, ordered HA DDL/RBR application.
\* All DDL that the master accepts also succeeds on the slave.
\* PK is before UNIQUE in the OR_CLASSREP property installation order.
\* Among UNIQUE keys, UKA is assumed to be before UKB.
CONSTANTS Scenario, Guarded
Cases == {"UKtoPK", "PKtoUK", "PKtoPK", "UKtoUK", "UKBFirst", "NonSelectedUK",
          "LastUKReject", "LastPKReject", "NullableFallback", "NullableReject"}
ASSUME Scenario \in Cases /\ Guarded \in BOOLEAN

Rows == {"r1", "r2"}
InitialRows ==
  [r \in Rows |->
    [a |-> IF r = "r1" THEN 1 ELSE 2,
     b |-> IF r = "r1" THEN 2 ELSE 1,
     value |-> 0,
     alive |-> TRUE]]

InitialSchema ==
  CASE Scenario \in {"UKtoPK", "UKtoUK", "UKBFirst", "NullableFallback"} -> {"UKA", "UKB"}
    [] Scenario \in {"PKtoUK", "PKtoPK", "NonSelectedUK"} -> {"PKA", "UKB"}
    [] Scenario \in {"LastUKReject", "NullableReject"} -> {"UKA"}
    [] OTHER -> {"PKA"}

Steps ==
  CASE Scenario = "UKtoPK" -> <<"UpdateB", "AddPKB", "UpdateA", "UpdateValue", "Delete">>
    [] Scenario = "PKtoUK" -> <<"UpdateB", "DropPKA", "UpdateValue", "Delete">>
    [] Scenario = "PKtoPK" -> <<"UpdateB", "ReplacePK", "UpdateA", "Delete">>
    [] Scenario = "UKtoUK" -> <<"UpdateB", "DropUKA", "UpdateValue", "Delete">>
    [] Scenario = "UKBFirst" -> <<"UpdateB", "DropUKB", "UpdateValue", "Delete">>
    [] Scenario = "NonSelectedUK" -> <<"UpdateB", "AddUKA", "UpdateValue", "DropUKB", "Delete">>
    [] Scenario = "LastUKReject" -> <<"UpdateB", "DropUKA", "UpdateValue", "Delete">>
    [] Scenario = "LastPKReject" -> <<"UpdateB", "DropPKA", "UpdateValue", "Delete">>
    [] Scenario = "NullableFallback" -> <<"UpdateB", "MakeUKANullable", "UpdateValue", "Delete">>
    [] OTHER -> <<"UpdateB", "MakeUKANullable", "UpdateValue", "Delete">>

IsDML(op) == op \in {"UpdateA", "UpdateB", "UpdateValue", "Delete"}
RK(schema) ==
  IF "PKA" \in schema THEN "PKA"
  ELSE IF "PKB" \in schema THEN "PKB"
  ELSE IF Scenario = "UKBFirst" /\ "UKB" \in schema THEN "UKB"
  ELSE IF "UKA" \in schema THEN "UKA"
  ELSE "UKB"
Key(rows, rk, r) == IF rk \in {"PKA", "UKA"} THEN rows[r].a ELSE rows[r].b

SchemaAfter(schema, op) ==
  CASE op = "AddPKB" -> schema \cup {"PKB"}
    [] op = "ReplacePK" -> (schema \ {"PKA"}) \cup {"PKB"}
    [] op = "DropPKA" -> schema \ {"PKA"}
    [] op = "DropUKA" -> schema \ {"UKA"}
    [] op = "DropUKB" -> schema \ {"UKB"}
    [] op = "MakeUKANullable" -> schema \ {"UKA"}
    [] OTHER -> schema

RowsAfter(rows, op) ==
  CASE op = "UpdateB" -> [rows EXCEPT !["r1"].b = 3, !["r1"].value = 1]
    [] op = "UpdateA" -> [rows EXCEPT !["r1"].a = 4, !["r1"].value = 2]
    [] op = "UpdateValue" -> [rows EXCEPT !["r1"].value = @ + 1]
    [] op = "Delete" -> [rows EXCEPT !["r1"].alive = FALSE]
    [] OTHER -> rows

VARIABLES step, queue, masterSchema, slaveSchema, masterRows, slaveRows,
          wrongRow, mismatch, applyFail, rejected
vars == <<step, queue, masterSchema, slaveSchema, masterRows, slaveRows,
          wrongRow, mismatch, applyFail, rejected>>

Init ==
  /\ step = 1 /\ queue = <<>>
  /\ masterSchema = InitialSchema /\ slaveSchema = InitialSchema
  /\ masterRows = InitialRows /\ slaveRows = InitialRows
  /\ wrongRow = FALSE /\ mismatch = FALSE /\ applyFail = FALSE /\ rejected = FALSE

MasterDo ==
  /\ step <= Len(Steps)
  /\ LET op == Steps[step]
         proposed == SchemaAfter(masterSchema, op)
         accepted == IsDML(op) \/ proposed # {}
         after == RowsAfter(masterRows, op)
         entry == IF IsDML(op)
                  THEN [kind |-> "DML", op |-> op, rk |-> RK(masterSchema),
                        key |-> Key(masterRows, RK(masterSchema), "r1"),
                        row |-> after["r1"]]
                  ELSE [kind |-> "DDL", op |-> op]
     IN /\ masterSchema' = IF accepted THEN proposed ELSE masterSchema
        /\ masterRows' = IF accepted THEN after ELSE masterRows
        /\ queue' = IF accepted THEN Append(queue, entry) ELSE queue
        /\ rejected' = (rejected \/ ~accepted)
  /\ step' = step + 1
  /\ UNCHANGED <<slaveSchema, slaveRows, wrongRow, mismatch, applyFail>>

SlaveApply ==
  /\ Len(queue) > 0
  /\ LET entry == Head(queue)
         localRK == RK(slaveSchema)
         rejectedByGuard == Guarded /\ entry.kind = "DML" /\ entry.rk # localRK
         candidates == IF entry.kind = "DML"
                       THEN {r \in Rows : slaveRows[r].alive /\
                              Key(slaveRows, localRK, r) = entry.key}
                       ELSE {}
     IN /\ slaveSchema' = IF entry.kind = "DDL"
                          THEN SchemaAfter(slaveSchema, entry.op)
                          ELSE slaveSchema
        /\ mismatch' = (mismatch \/ (entry.kind = "DML" /\ entry.rk # localRK))
        /\ applyFail' = (applyFail \/ rejectedByGuard \/
                         (entry.kind = "DML" /\ candidates = {}))
        /\ slaveRows' = IF entry.kind # "DML" \/ candidates = {} \/ rejectedByGuard
                        THEN slaveRows
                        ELSE LET target == CHOOSE r \in candidates : TRUE
                             IN [slaveRows EXCEPT ![target] = entry.row]
        /\ wrongRow' = (wrongRow \/
                        (entry.kind = "DML" /\ candidates # {} /\
                         ~rejectedByGuard /\ (CHOOSE r \in candidates : TRUE) # "r1"))
  /\ queue' = Tail(queue)
  /\ UNCHANGED <<step, masterSchema, masterRows, rejected>>

Next == MasterDo \/ SlaveApply
Spec == Init /\ [][Next]_vars

TypeOK ==
  /\ step \in 1..(Len(Steps) + 1)
  /\ masterSchema \subseteq {"PKA", "PKB", "UKA", "UKB"}
  /\ slaveSchema \subseteq {"PKA", "PKB", "UKA", "UKB"}
  /\ masterSchema # {} /\ slaveSchema # {}
  /\ wrongRow \in BOOLEAN /\ mismatch \in BOOLEAN
  /\ applyFail \in BOOLEAN /\ rejected \in BOOLEAN
  /\ Len(queue) \in 0..Len(Steps)
NoWrongRow == ~wrongRow
NoRKMismatch == ~mismatch
NoApplyFailure == ~applyFail
ConvergesWhenCaughtUp ==
  Len(queue) = 0 => masterSchema = slaveSchema /\ masterRows = slaveRows
ExpectedRejection ==
  step = Len(Steps) + 1 =>
    rejected = (Scenario \in {"LastUKReject", "LastPKReject", "NullableReject"})

=============================================================================
