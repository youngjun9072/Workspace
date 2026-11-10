------------------------ MODULE WritesetSysopKeyedSym ------------------------
(* WritesetSysopKeyed with symmetry sets, for exhaustive runs only.          *)
(* Key and serial symmetry are sound only without CollidePair.               *)
EXTENDS WritesetSysopKeyed

TxnSym == Permutations(Txns)
TxnKeySym == Permutations(Txns) \cup Permutations(Keys) \cup Permutations(Serials)
=============================================================================
