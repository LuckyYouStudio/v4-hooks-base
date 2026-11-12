# Checker vs. its own samples (Base fork, real PoolManager, block 56228000)

Written by `checker/test/fork/ForkChecker.t.sol::test_fork_matrix_sameAsLocal`; do not edit by hand.
The samples are deliberately vulnerable toys, deployed only inside the local fork simulation.
S5 is funded with 10 ETH before the run (the bounty its toy is about).

| sample | a | b | c | d | e | f | g | h | i |
|---|---|---|---|---|---|---|---|---|---|
| S1 ExtraBitHook | FAIL | PASS | PASS | FAIL | PASS | UNKNOWN | PASS | PASS | N/A |
| S1 ExtraBitHookFixed | PASS | PASS | PASS | PASS | PASS | UNKNOWN | PASS | PASS | N/A |
| S2 NoCallerCheckHook | PASS | FAIL | PASS | PASS | PASS | UNKNOWN | PASS | PASS | N/A |
| S2 NoCallerCheckHookFixed | PASS | PASS | PASS | PASS | PASS | UNKNOWN | PASS | PASS | N/A |
| S3 GlobalStateHook | PASS | PASS | FAIL | PASS | PASS | PASS | PASS | PASS | N/A |
| S3 GlobalStateHookFixed | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | N/A |
| S4 WrongDeltaHook | PASS | PASS | PASS | PASS | PASS | UNKNOWN | PASS | UNKNOWN | UNKNOWN |
| S4 WrongDeltaHookFixed | PASS | PASS | PASS | PASS | PASS | UNKNOWN | PASS | UNKNOWN | PASS |
| S5 SharedSlotGuardHook | PASS | PASS | PASS | PASS | PASS | UNKNOWN | PASS | UNKNOWN | N/A |
| S5 SharedSlotGuardHookFixed | PASS | PASS | PASS | PASS | PASS | UNKNOWN | PASS | UNKNOWN | N/A |
| S6 DonatePenaltyHook | PASS | PASS | PASS | FAIL | PASS | UNKNOWN | PASS | PASS | PASS |
| S6 DonatePenaltyHookFixed | PASS | PASS | PASS | PASS | PASS | UNKNOWN | PASS | PASS | PASS |
| S7 StaleOverflowHook | PASS | PASS | PASS | PASS | FAIL | UNKNOWN | PASS | PASS | N/A |
| S7 StaleOverflowHookFixed | PASS | PASS | PASS | PASS | PASS | UNKNOWN | PASS | PASS | N/A |
| S8 SpotFeeHook | PASS | PASS | PASS | PASS | PASS | UNKNOWN | PASS | PASS | N/A |
| S8 SpotFeeHookFixed | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | N/A |
| S9 UncappedFeeHook | PASS | PASS | PASS | PASS | FAIL | FAIL | PASS | PASS | N/A |
| S9 UncappedFeeHookFixed | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | N/A |
| S10 UpgradeableAdminHook | PASS | PASS | PASS | PASS | PASS | UNKNOWN | UNKNOWN | PASS | N/A |
| S10 UpgradeableAdminHookFixed | PASS | PASS | PASS | PASS | PASS | UNKNOWN | PASS | PASS | N/A |
