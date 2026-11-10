-------------------------- MODULE WritesetE2ESym --------------------------
(* WritesetE2E with symmetry sets, for exhaustive runs only.                *)
(* Key symmetry is sound only without CollidePair: Hash is then the         *)
(* identity on keys, and no other definition names a particular key.        *)
EXTENDS WritesetE2E

TxnSym == Permutations(Txns)
TxnKeySym == Permutations(Txns) \cup Permutations(Keys)
=============================================================================
