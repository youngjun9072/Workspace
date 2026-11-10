#!/bin/bash
# All E2E configurations (regenerate with: bash e2e_cfgs.sh). Keys are model values k1..kn, serials s1..
cd /home/youngjun/Workspace/Obsidian/Github/writeset-tla
G=./e2e_mkcfg.py
I_NOREQ=INV=DepCover,DepBelowSelf,BarrierWaitsAll,NoDuplicate,OnlyUnits,ConflictOrder,PrefixStored,QuietAllApplied,FinalState
MI=INV=DepCover,DepBelowSelf,BarrierWaitsAll
# --- small steps and mutants (round 1) ---
$G s1
$G s1_bug FixFragStart=FALSE $I_NOREQ
$G s1_collide 'CollidePair={k1, k2}'
$G s1_inter Interleave=TRUE
$G s0 AllowOOM=FALSE AllowMasterRestart=FALSE AllowSavepoint=FALSE AllowStmt=FALSE
$G s0_inter AllowOOM=FALSE AllowMasterRestart=FALSE AllowSavepoint=FALSE AllowStmt=FALSE Interleave=TRUE
$G san_serial INV=SerialOrder
$G m_noClearFloor 'Mut="noClearFloor"'
$G m_unlockEarly 'Mut="unlockBeforePublish"'
$G m_gateLoose 'Mut="gateLoose"'
$G m_splitEq 'HashMode="splitEq"'
$G m_visibleAtMvcc 'Mut="visibleAtMvcc"'
$G m_noSysopFloor 'Mut="noSysopFloor"'
$G m_noOvfFloor 'Mut="noOvfFloor"'
$G m_markerTrunc AllowMarkerDdl=TRUE
$G s2_lite T=3 AllowOOM=FALSE AllowMasterRestart=FALSE AllowSavepoint=FALSE
# --- master only ---
CORE=(AllowSavepoint=FALSE AllowStmt=FALSE AllowAbort=FALSE AllowOOM=FALSE AllowMasterRestart=FALSE)
$G mo_t3k2 MasterOnly=TRUE T=3 $MI
$G moc_t3k2 MasterOnly=TRUE T=3 "${CORE[@]}" $MI
$G moc_t3k3 MasterOnly=TRUE T=3 K=3 "${CORE[@]}" $MI
$G moc_t4k2 MasterOnly=TRUE T=4 "${CORE[@]}" $MI
$G moc_t4k3 MasterOnly=TRUE T=4 K=3 "${CORE[@]}" $MI
$G moc1_t5k3 MasterOnly=TRUE T=5 K=3 MaxOps=1 "${CORE[@]}" $MI
# --- E2E, one action per transaction ---
ONE=(MaxOps=1 AllowSavepoint=FALSE AllowOOM=FALSE AllowMasterRestart=FALSE)
$G e1_t3k2w2 T=3 "${ONE[@]}"
$G e1_t3k3w2 T=3 K=3 "${ONE[@]}"
$G e1_t4k3w3 T=4 K=3 NumWorkers=3 "${ONE[@]}"
# scale-up ladder toward Txns 5-6 / Keys 4-5 / Workers 4 (one dimension backed off per step)
$G e1_t6k5w4 T=6 K=5 NumWorkers=4 KeyLimit=3 "${ONE[@]}"
$G e1_t5k5w4 T=5 K=5 NumWorkers=4 KeyLimit=3 "${ONE[@]}"
$G e1_t5k4w4 T=5 K=4 NumWorkers=4 KeyLimit=2 "${ONE[@]}"
$G e1_t5k4w3 T=5 K=4 NumWorkers=3 KeyLimit=2 "${ONE[@]}"
$G e1_t4k4w4 T=4 K=4 NumWorkers=4 KeyLimit=2 "${ONE[@]}"
# --- simulations (no symmetry) ---
BIG=(T=8 K=4 KeyLimit=3 MaxOps=3 NumWorkers=10 QCap=4 RingCap=100 MaxCrash=3 SYM=0)
$G sim_big "${BIG[@]}"
$G sim_big_bug "${BIG[@]}" FixFragStart=FALSE $I_NOREQ
HUGE=(KeyLimit=3 MaxOps=3 NumWorkers=10 QCap=8 RingCap=300 MaxCrash=5 'Serials={s1, s2}' SYM=0)
$G sim_t30k10 T=30 K=10 "${HUGE[@]}"
$G sim_t30k10_collide T=30 K=10 "${HUGE[@]}" 'CollidePair={k1, k2}'
$G sim_t25k8 T=25 K=8 "${HUGE[@]}"
$G sim_t25k8_inter T=25 K=8 "${HUGE[@]}" Interleave=TRUE
$G sim_t20k8_cap2 T=20 K=8 "${HUGE[@]}" KeyLimit=2
$G sim_t25k8_bug T=25 K=8 "${HUGE[@]}" FixFragStart=FALSE $I_NOREQ
