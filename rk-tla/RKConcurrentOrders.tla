------------------------- MODULE RKConcurrentOrders -------------------------
EXTENDS Integers, Sequences, TLC

\* Concurrent clients may submit statements in different orders. SCH_S and
\* SCH_M class locks serialize DML and DDL on one class; this model explores
\* their committed order, while the slave applies the resulting log FIFO.
\* A rejected last-RK DDL leaves no log. Nullable UNIQUE remains in the
\* catalog but is removed from the eligible RK candidate sequence here.
CONSTANTS Guarded, MaxOps
ASSUME Guarded \in BOOLEAN /\ MaxOps \in Nat /\ MaxOps > 0

Rows == {"r1", "r2"}
InitialRows ==
  [r \in Rows |->
    [a |-> IF r = "r1" THEN 1 ELSE 2,
     b |-> IF r = "r1" THEN 2 ELSE 1,
     value |-> 0, alive |-> TRUE]]
InitialSchemas ==
  {[pk |-> "PKA", uks |-> <<>>],
   [pk |-> "PKA", uks |-> <<"UKB">>],
   [pk |-> "none", uks |-> <<"UKA">>],
   [pk |-> "none", uks |-> <<"UKA", "UKB">>],
   [pk |-> "none", uks |-> <<"UKB", "UKA">>]}

Ops == {"UpdateA", "UpdateB", "UpdateValue", "Delete",
        "AddPKA", "AddPKB", "DropPK", "SwapPK",
        "AddUKA", "AddUKB", "DropUKA", "DropUKB",
        "MakeUKANullable", "MakeUKBNullable"}
IsDML(op) == op \in {"UpdateA", "UpdateB", "UpdateValue", "Delete"}
UKSet(uks) == {uks[i] : i \in 1..Len(uks)}
RemoveUK(uks, uk) ==
  IF Len(uks) = 1 THEN <<>>
  ELSE IF uks[1] = uk THEN <<uks[2]>> ELSE <<uks[1]>>
HasRK(schema) == schema.pk # "none" \/ Len(schema.uks) > 0
RK(schema) == IF schema.pk # "none" THEN schema.pk ELSE Head(schema.uks)
Key(rows, rk, r) == IF rk \in {"PKA", "UKA"} THEN rows[r].a ELSE rows[r].b

SchemaAfter(schema, op) ==
  CASE op = "AddPKA" -> [schema EXCEPT !.pk = "PKA"]
    [] op = "AddPKB" -> [schema EXCEPT !.pk = "PKB"]
    [] op = "DropPK" -> [schema EXCEPT !.pk = "none"]
    [] op = "SwapPK" -> [schema EXCEPT !.pk = IF @ = "PKA" THEN "PKB" ELSE "PKA"]
    [] op = "AddUKA" -> [schema EXCEPT !.uks = Append(@, "UKA")]
    [] op = "AddUKB" -> [schema EXCEPT !.uks = Append(@, "UKB")]
    [] op \in {"DropUKA", "MakeUKANullable"} ->
         [schema EXCEPT !.uks = RemoveUK(@, "UKA")]
    [] op \in {"DropUKB", "MakeUKBNullable"} ->
         [schema EXCEPT !.uks = RemoveUK(@, "UKB")]
    [] OTHER -> schema
RowsAfter(rows, op) ==
  CASE op = "UpdateA" -> [rows EXCEPT !["r1"].a = 4, !["r1"].value = @ + 1]
    [] op = "UpdateB" -> [rows EXCEPT !["r1"].b = 3, !["r1"].value = @ + 1]
    [] op = "UpdateValue" -> [rows EXCEPT !["r1"].value = @ + 1]
    [] op = "Delete" -> [rows EXCEPT !["r1"].alive = FALSE]
    [] OTHER -> rows

Enabled(op, schema, rows) ==
  CASE IsDML(op) -> rows["r1"].alive
    [] op \in {"AddPKA", "AddPKB"} -> schema.pk = "none"
    [] op \in {"DropPK", "SwapPK"} -> schema.pk # "none"
    [] op = "AddUKA" -> "UKA" \notin UKSet(schema.uks)
    [] op = "AddUKB" -> "UKB" \notin UKSet(schema.uks)
    [] op \in {"DropUKA", "MakeUKANullable"} -> "UKA" \in UKSet(schema.uks) /\
       schema.pk # "PKA"
    [] OTHER -> "UKB" \in UKSet(schema.uks) /\ schema.pk # "PKB"

VARIABLES step, history, queue, initialSchema, masterSchema, slaveSchema, masterRows,
          slaveRows, wrongRow, mismatch, applyFail, rejected
vars == <<step, history, queue, initialSchema, masterSchema, slaveSchema, masterRows,
          slaveRows, wrongRow, mismatch, applyFail, rejected>>

Init ==
  /\ step = 0 /\ history = <<>> /\ queue = <<>>
  /\ masterSchema \in InitialSchemas /\ slaveSchema = masterSchema
  /\ initialSchema = masterSchema
  /\ masterRows = InitialRows /\ slaveRows = InitialRows
  /\ wrongRow = FALSE /\ mismatch = FALSE /\ applyFail = FALSE /\ rejected = FALSE

MasterDo ==
  /\ step < MaxOps
  /\ \E op \in Ops :
      /\ Enabled(op, masterSchema, masterRows)
      /\ LET proposed == SchemaAfter(masterSchema, op)
             accepted == IsDML(op) \/ HasRK(proposed)
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
      /\ history' = Append(history, op)
      /\ UNCHANGED <<initialSchema, slaveSchema, slaveRows, wrongRow, mismatch, applyFail>>

SlaveApply ==
  /\ Len(queue) > 0
  /\ LET entry == Head(queue)
         localRK == RK(slaveSchema)
         guardRejected == Guarded /\ entry.kind = "DML" /\ entry.rk # localRK
         candidates == IF entry.kind = "DML"
                       THEN {r \in Rows : slaveRows[r].alive /\
                              Key(slaveRows, localRK, r) = entry.key}
                       ELSE {}
     IN /\ slaveSchema' = IF entry.kind = "DDL"
                          THEN SchemaAfter(slaveSchema, entry.op)
                          ELSE slaveSchema
        /\ mismatch' = (mismatch \/ (entry.kind = "DML" /\ entry.rk # localRK))
        /\ applyFail' = (applyFail \/ guardRejected \/
                         (entry.kind = "DML" /\ candidates = {}))
        /\ slaveRows' = IF entry.kind # "DML" \/ candidates = {} \/ guardRejected
                        THEN slaveRows
                        ELSE LET target == CHOOSE r \in candidates : TRUE
                             IN [slaveRows EXCEPT ![target] = entry.row]
        /\ wrongRow' = (wrongRow \/
                        (entry.kind = "DML" /\ candidates # {} /\
                         ~guardRejected /\ (CHOOSE r \in candidates : TRUE) # "r1"))
  /\ queue' = Tail(queue)
  /\ UNCHANGED <<step, history, initialSchema, masterSchema, masterRows, rejected>>

Next == MasterDo \/ SlaveApply
Spec == Init /\ [][Next]_vars
TypeOK ==
  /\ step \in 0..MaxOps /\ Len(history) = step
  /\ initialSchema \in InitialSchemas
  /\ masterSchema.pk \in {"none", "PKA", "PKB"}
  /\ slaveSchema.pk \in {"none", "PKA", "PKB"}
  /\ Len(masterSchema.uks) \in 0..2 /\ Len(slaveSchema.uks) \in 0..2
  /\ HasRK(masterSchema) /\ HasRK(slaveSchema)
  /\ wrongRow \in BOOLEAN /\ mismatch \in BOOLEAN
  /\ applyFail \in BOOLEAN /\ rejected \in BOOLEAN
  /\ Len(queue) \in 0..MaxOps
NoWrongRow == ~wrongRow
NoRKMismatch == ~mismatch
NoApplyFailure == ~applyFail
ConvergesWhenCaughtUp ==
  Len(queue) = 0 =>
    masterSchema = slaveSchema /\ masterRows = slaveRows

=============================================================================
