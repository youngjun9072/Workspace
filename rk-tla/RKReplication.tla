----------------------------- MODULE RKReplication -----------------------------
EXTENDS Integers, TLC

\* A small model of one class with two RK candidates. The slave DDL can fail
\* because of an index-name conflict with equal row data, or because an
\* OFF-source SBR first produced a duplicate id on the slave.
\* LogRK abstracts the master RK descriptor digest in PR #8366.
\* Guarded=FALSE models the base branch; Guarded=TRUE models the PR's
\* pre-lookup comparison. Hash collisions and serialization details are omitted.
CONSTANTS Guarded, Op, SlaveOffHasRow, SlaveIndexNameConflict
ASSUME /\ Guarded \in BOOLEAN
       /\ Op \in {"Update", "Delete"}
       /\ SlaveOffHasRow \in BOOLEAN
       /\ SlaveIndexNameConflict \in BOOLEAN

Rows == {"r1", "r2", "r3"}
InitialRows == [r \in Rows |->
  [id |-> IF r = "r2" THEN 2 ELSE 1,
   code |-> IF r = "r1" THEN 2 ELSE IF r = "r2" THEN 1 ELSE 4,
   value |-> 0, alive |-> r # "r3"]]
Key(rk, rows, r) == IF rk = "id" THEN rows[r].id ELSE rows[r].code
UniqueCode(rows) ==
  \A r \in Rows : \A s \in Rows :
    (r # s /\ rows[r].alive /\ rows[s].alive) => rows[r].code # rows[s].code
UniqueId(rows) ==
  \A r \in Rows : \A s \in Rows :
    (r # s /\ rows[r].alive /\ rows[s].alive) => rows[r].id # rows[s].id

VARIABLES priorSBRDone, masterHasPK, slaveHasPK, ddlQueued, ddlDone,
          masterRows, slaveRows, dataQueued, dataDone,
          logKey, logRK, ddlFailCount, dmlFailCount, wrongRow

vars == <<priorSBRDone, masterHasPK, slaveHasPK, ddlQueued, ddlDone,
          masterRows, slaveRows, dataQueued, dataDone,
          logKey, logRK, ddlFailCount, dmlFailCount, wrongRow>>

Init ==
  /\ priorSBRDone = FALSE
  /\ masterHasPK = FALSE
  /\ slaveHasPK = FALSE
  /\ ddlQueued = FALSE
  /\ ddlDone = FALSE
  /\ masterRows = InitialRows
  /\ slaveRows = InitialRows
  /\ dataQueued = FALSE
  /\ dataDone = FALSE
  /\ logKey = 0
  /\ logRK = "none"
  /\ ddlFailCount = 0
  /\ dmlFailCount = 0
  /\ wrongRow = FALSE

PriorSBRFromOff ==
  /\ ~priorSBRDone
  /\ priorSBRDone' = TRUE
  /\ slaveRows' = IF SlaveOffHasRow
                   THEN [slaveRows EXCEPT !["r3"].alive = TRUE]
                   ELSE slaveRows
  /\ UNCHANGED <<masterHasPK, slaveHasPK, ddlQueued, ddlDone,
                  masterRows, dataQueued, dataDone, logKey, logRK,
                  ddlFailCount, dmlFailCount, wrongRow>>

MasterAddPK ==
  /\ priorSBRDone
  /\ ~masterHasPK
  /\ ~ddlQueued
  /\ masterHasPK' = TRUE
  /\ ddlQueued' = TRUE
  /\ UNCHANGED <<priorSBRDone, slaveHasPK, ddlDone, masterRows, slaveRows,
                  dataQueued, dataDone, logKey, logRK,
                  ddlFailCount, dmlFailCount, wrongRow>>

SlaveDDLSuccess ==
  /\ ddlQueued
  /\ ~ddlDone
  /\ UniqueId(slaveRows)
  /\ ~SlaveIndexNameConflict
  /\ slaveHasPK' = TRUE
  /\ ddlDone' = TRUE
  /\ UNCHANGED <<priorSBRDone, masterHasPK, ddlQueued, masterRows, slaveRows,
                  dataQueued, dataDone, logKey, logRK,
                  ddlFailCount, dmlFailCount, wrongRow>>

SlaveDDLFailure ==
  /\ ddlQueued
  /\ ~ddlDone
  /\ (~UniqueId(slaveRows) \/ SlaveIndexNameConflict)
  /\ ddlDone' = TRUE
  /\ ddlFailCount' = ddlFailCount + 1
  /\ UNCHANGED <<priorSBRDone, masterHasPK, slaveHasPK, ddlQueued, masterRows, slaveRows,
                  dataQueued, dataDone, logKey, logRK,
                  dmlFailCount, wrongRow>>

MasterDML ==
  /\ ddlQueued  \* master need not wait for the slave to apply the DDL
  /\ ~dataQueued
  /\ masterRows' = IF Op = "Update"
                    THEN [masterRows EXCEPT !["r1"].code = 3,
                                            !["r1"].value = 1]
                    ELSE [masterRows EXCEPT !["r1"].alive = FALSE]
  /\ logRK' = IF masterHasPK THEN "id" ELSE "code"
  /\ logKey' = Key(IF masterHasPK THEN "id" ELSE "code", masterRows, "r1")
  /\ dataQueued' = TRUE
  /\ UNCHANGED <<priorSBRDone, masterHasPK, slaveHasPK, ddlQueued, ddlDone,
                  slaveRows, dataDone, ddlFailCount, dmlFailCount, wrongRow>>

SlaveDML ==
  /\ dataQueued
  /\ ddlDone  \* applier processes the earlier DDL log first
  /\ ~dataDone
  /\ LET localRK == IF slaveHasPK THEN "id" ELSE "code" IN
       IF Guarded /\ localRK # logRK
       THEN /\ slaveRows' = slaveRows
            /\ dmlFailCount' = dmlFailCount + 1
            /\ wrongRow' = wrongRow
       ELSE LET target == CHOOSE r \in Rows :
                            slaveRows[r].alive /\ Key(localRK, slaveRows, r) = logKey
            IN
            /\ slaveRows' = IF Op = "Update"
                             THEN [slaveRows EXCEPT ![target] = masterRows["r1"]]
                             ELSE [slaveRows EXCEPT ![target].alive = FALSE]
            /\ dmlFailCount' = dmlFailCount
            /\ wrongRow' = (wrongRow \/ target # "r1")
  /\ dataDone' = TRUE
  /\ UNCHANGED <<priorSBRDone, masterHasPK, slaveHasPK, ddlQueued, ddlDone,
                  masterRows, dataQueued, logKey, logRK, ddlFailCount>>

Next == PriorSBRFromOff \/ MasterAddPK \/ SlaveDDLSuccess \/ SlaveDDLFailure \/ MasterDML \/ SlaveDML
Spec == Init /\ [][Next]_vars

TypeOK ==
  /\ priorSBRDone \in BOOLEAN
  /\ masterHasPK \in BOOLEAN /\ slaveHasPK \in BOOLEAN
  /\ ddlQueued \in BOOLEAN /\ ddlDone \in BOOLEAN
  /\ dataQueued \in BOOLEAN /\ dataDone \in BOOLEAN
  /\ \A r \in Rows :
       /\ masterRows[r].id \in {1, 2}
       /\ masterRows[r].code \in {1, 2, 3, 4}
       /\ masterRows[r].value \in {0, 1}
       /\ masterRows[r].alive \in BOOLEAN
       /\ slaveRows[r].id \in {1, 2}
       /\ slaveRows[r].code \in {1, 2, 3, 4}
       /\ slaveRows[r].value \in {0, 1}
       /\ slaveRows[r].alive \in BOOLEAN
  /\ UniqueCode(masterRows) /\ UniqueCode(slaveRows)
  /\ (~masterHasPK \/ UniqueId(masterRows))
  /\ (~slaveHasPK \/ UniqueId(slaveRows))
  /\ logKey \in {0, 1, 2, 3}
  /\ logRK \in {"none", "id", "code"}
  /\ ddlFailCount \in Nat /\ dmlFailCount \in Nat
  /\ wrongRow \in BOOLEAN

NoWrongRow == ~wrongRow
NoSilentDMLMismatch == (dataDone /\ masterRows # slaveRows) => dmlFailCount > 0
SameSchemaConverges == (dataDone /\ masterHasPK = slaveHasPK) => masterRows = slaveRows

=============================================================================
