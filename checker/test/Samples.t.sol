// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {SampleRegistry} from "./SampleRegistry.sol";
import {Status, Report} from "../src/CheckerTypes.sol";
import {ExtraBitHookFixed} from "../samples/S1_ExtraPermissionBit.sol";

/// @notice The checker against its own sample library: every vulnerable sample must be reported under
///         the check it belongs to, every fixed counterpart must not be. Where the checker cannot detect
///         the sample's problem, the test pins that down as well (S4: hint only; S5: nothing), so the
///         README's false-negative table is backed by assertions.
///         Bit masks for _assertCleanExcept: bit i = check i (a=0 ... i=8).
contract SamplesTest is SampleRegistry {
    uint256 private constant ONLY_H = 1 << 7;
    /// @dev samples that are not fee hooks: the checker's own pool is a dynamic-fee pool in which every
    ///      swap then pays 0, and f says UNKNOWN with a hint (pinned in test_feeZero_isUnknownWithHint)
    uint256 private constant NO_FEE = 1 << 5;

    function setUp() public {
        _baseSetUp();
    }

    // --- S1: one permission bit too many -> a and d ------------------------------------------------

    function test_S1_vulnerable_permissionsAndRemoveFlagged() public {
        Report memory rep = _check(_deploySample(1, false));
        _assertStatus(rep, A_PERMISSIONS, Status.FAIL);
        assertTrue(_mentions(rep, A_PERMISSIONS, "beforeRemoveLiquidity: DECLARED BUT NOT USABLE"), "names the callback");
        assertTrue(_mentions(rep, A_PERMISSIONS, "liquidity is stuck"), "flags the consequence");
        assertTrue(_mentions(rep, A_PERMISSIONS, "getHookPermissions() MISMATCH"), "second leg");
        assertTrue(_mentions(rep, A_PERMISSIONS, "its selector does not occur in the bytecode") || _mentions(rep, A_PERMISSIONS, "empty revert data"), "why");
        _assertStatus(rep, D_REMOVE, Status.FAIL);
        assertTrue(_mentions(rep, D_REMOVE, "fees-only REVERT"), "fee collection is blocked too");
        _assertCleanExcept(rep, NO_FEE | ((1 << A_PERMISSIONS) | (1 << D_REMOVE)));
    }

    function test_S1_fixed_clean() public {
        _assertCleanExcept(_check(_deploySample(1, true)), NO_FEE);
    }

    function test_S1_fixed_cannotExistAtTheExtraBitAddress() public {
        bytes memory code = type(ExtraBitHookFixed).creationCode;
        bytes memory args = abi.encode(manager);
        bytes32 salt = _salt(S1_EXTRA, code, args);
        bytes memory init = abi.encodePacked(code, args);
        address a;
        assembly {
            a := create2(0, add(init, 0x20), mload(init), salt)
        }
        assertEq(a, address(0), "constructor must revert: address bits != declared permissions");
    }

    // --- S2: callback without caller check -> b ----------------------------------------------------

    function test_S2_vulnerable_callerCheckFlagged() public {
        Report memory rep = _check(_deploySample(2, false));
        _assertStatus(rep, B_CALLER, Status.FAIL);
        assertTrue(_mentions(rep, B_CALLER, "beforeSwap: ACCEPTED from a non-PoolManager address AND CHANGED STATE"), "names the callback");
        _assertCleanExcept(rep, NO_FEE | (1 << B_CALLER));
    }

    function test_S2_fixed_clean() public {
        _assertCleanExcept(_check(_deploySample(2, true)), NO_FEE);
    }

    // --- S3: global state shared by all pools -> c -------------------------------------------------

    function test_S3_vulnerable_foreignPoolFlagged() public {
        Report memory rep = _check(_deploySample(3, false));
        _assertStatus(rep, C_FOREIGN_POOL, Status.FAIL);
        assertTrue(_mentions(rep, C_FOREIGN_POOL, "DIFFERS after the stranger pool's activity"), "behavioural difference");
        assertTrue(_mentions(rep, C_FOREIGN_POOL, "changed by the stranger pool AND used by the reference pool"), "shared slot");
        _assertCleanExcept(rep, 1 << C_FOREIGN_POOL);
    }

    function test_S3_fixed_clean() public {
        Report memory rep = _check(_deploySample(3, true));
        _assertStatus(rep, C_FOREIGN_POOL, Status.PASS);
        assertTrue(_mentions(rep, C_FOREIGN_POOL, "ACCEPTED"), "the fixed hook still serves any pool, it just keeps them apart");
        _assertCleanExcept(rep, 0);
    }

    // --- S4: return delta sized from the wrong component -> i gives a hint, NOT a failure ----------

    function test_S4_vulnerable_onlyAHint() public {
        Report memory rep = _check(_deploySample(4, false));
        _assertStatus(rep, I_RETURN_DELTA, Status.UNKNOWN);
        assertTrue(_mentions(rep, I_RETURN_DELTA, "not uniform across direction x exactIn/exactOut"), "the hint");
        _assertNoFail(rep); // documented false negative: no check FAILS on this sample
        _assertStatus(rep, H_BALANCES, Status.UNKNOWN); // fact: the hook keeps its fees
        _assertCleanExcept(rep, NO_FEE | ((1 << I_RETURN_DELTA) | ONLY_H));
    }

    function test_S4_fixed_uniform() public {
        Report memory rep = _check(_deploySample(4, true));
        _assertStatus(rep, I_RETURN_DELTA, Status.PASS);
        assertTrue(_mentions(rep, I_RETURN_DELTA, "uniform 999 ppm"), "0.10% rounded down, all four combinations");
        _assertStatus(rep, H_BALANCES, Status.UNKNOWN);
        _assertCleanExcept(rep, NO_FEE | (ONLY_H));
    }

    // --- S5: lock and bookkeeping share a slot -> NOT detected -------------------------------------

    function test_S5_vulnerable_notDetected() public {
        address hook = _deploySample(5, false);
        vm.deal(hook, 10 ether);
        Report memory rep = _check(hook);
        _assertNoFail(rep); // documented false negative
        _assertStatus(rep, H_BALANCES, Status.UNKNOWN); // the only pointer: the hook holds ETH
        assertTrue(_mentions(rep, H_BALANCES, "native ETH held by the hook: 10000000000000000000"), "fact reported");
        _assertCleanExcept(rep, NO_FEE | (ONLY_H));
    }

    function test_S5_fixed_sameReport() public {
        address hook = _deploySample(5, true);
        vm.deal(hook, 10 ether);
        Report memory rep = _check(hook);
        _assertStatus(rep, H_BALANCES, Status.UNKNOWN);
        _assertCleanExcept(rep, NO_FEE | (ONLY_H));
    }

    // --- S6: exit penalty donated to nobody -> d ---------------------------------------------------

    function test_S6_vulnerable_removeFlagged() public {
        Report memory rep = _check(_deploySample(6, false));
        _assertStatus(rep, D_REMOVE, Status.FAIL);
        assertTrue(_mentions(rep, D_REMOVE, "NoLiquidityToReceiveFees()"), "reason");
        assertTrue(_mentions(rep, D_REMOVE, "afterRemoveLiquidity"), "callback");
        assertTrue(_mentions(rep, D_REMOVE, "last-LP REVERT"), "the last LP cannot leave");
        _assertCleanExcept(rep, NO_FEE | (1 << D_REMOVE));
    }

    function test_S6_fixed_clean() public {
        _assertCleanExcept(_check(_deploySample(6, true)), NO_FEE);
    }

    // --- S7: decay arithmetic overflows after a long idle period -> e ------------------------------

    function test_S7_vulnerable_swapFlagged() public {
        Report memory rep = _check(_deploySample(7, false));
        _assertStatus(rep, E_SWAP, Status.FAIL);
        assertTrue(_mentions(rep, E_SWAP, "Panic(0x11 arithmetic overflow/underflow)"), "reason");
        assertTrue(_mentions(rep, E_SWAP, "time +400 days"), "scenario");
        assertTrue(_mentions(rep, E_SWAP, "[UNEXPECTED]"), "classified as unexpected, not as a refusal");
        _assertCleanExcept(rep, NO_FEE | (1 << E_SWAP));
    }

    function test_S7_fixed_clean() public {
        _assertCleanExcept(_check(_deploySample(7, true)), NO_FEE);
    }

    // --- S8: fee from the spot tick -> f gives a hint ----------------------------------------------

    function test_S8_vulnerable_sameBlockHint() public {
        Report memory rep = _check(_deploySample(8, false));
        _assertStatus(rep, F_DYNAMIC_FEE, Status.UNKNOWN);
        assertTrue(_mentions(rep, F_DYNAMIC_FEE, "changes within one block"), "the hint");
        _assertNoFail(rep);
        _assertCleanExcept(rep, 1 << F_DYNAMIC_FEE);
    }

    function test_S8_fixed_clean() public {
        Report memory rep = _check(_deploySample(8, true));
        _assertStatus(rep, F_DYNAMIC_FEE, Status.PASS);
        _assertCleanExcept(rep, 0);
    }

    // --- S9: fee without an upper bound -> f and e -------------------------------------------------

    function test_S9_vulnerable_feeBoundFlagged() public {
        Report memory rep = _check(_deploySample(9, false));
        _assertStatus(rep, F_DYNAMIC_FEE, Status.FAIL);
        assertTrue(_mentions(rep, F_DYNAMIC_FEE, "above 100%"), "reason");
        _assertStatus(rep, E_SWAP, Status.FAIL);
        assertTrue(_mentions(rep, E_SWAP, "LPFeeTooLarge(uint24)"), "reason");
        _assertCleanExcept(rep, (1 << F_DYNAMIC_FEE) | (1 << E_SWAP));
    }

    function test_S9_fixed_clean() public {
        _assertCleanExcept(_check(_deploySample(9, true)), 0);
    }

    // --- S10: owner-replaceable logic behind DELEGATECALL -> g lists the signs ---------------------

    function test_S10_unsafeDesign_signsListed() public {
        Report memory rep = _check(_deploySample(10, false));
        _assertStatus(rep, G_UPGRADE, Status.UNKNOWN);
        assertTrue(_mentions(rep, G_UPGRADE, "EIP-1967 implementation slot is set"), "slot");
        assertTrue(_mentions(rep, G_UPGRADE, "owner() answers"), "view");
        assertTrue(_mentions(rep, G_UPGRADE, "DELEGATECALL opcode occurs"), "opcode");
        _assertCleanExcept(rep, NO_FEE | (1 << G_UPGRADE));
    }

    function test_S10_fixed_clean() public {
        _assertCleanExcept(_check(_deploySample(10, true)), NO_FEE);
    }

    /// @dev L-2: a dynamic-fee pool in which every swap paid 0 is not a PASS for check f
    function test_feeZero_isUnknownWithHint() public {
        Report memory rep = _check(_deploySample(2, true));
        _assertStatus(rep, F_DYNAMIC_FEE, Status.UNKNOWN);
        assertTrue(_mentions(rep, F_DYNAMIC_FEE, "paid a fee of 0"), "says what was seen");
        assertTrue(_mentions(rep, F_DYNAMIC_FEE, "OVERRIDE_FEE_FLAG"), "the hint");
    }

    // --- the whole matrix, written out verbatim ----------------------------------------------------

    /// @dev asserts the expected status of every check for all 20 samples (SampleRegistry._expected) and
    ///      writes the table to checker/reports/local-samples-matrix.md
    function test_matrix_writeFile() public {
        string memory out = string.concat(
            "# Checker vs. its own samples (local PoolManager)\n\n",
            "Written by `checker/test/Samples.t.sol::test_matrix_writeFile`; do not edit by hand.\n",
            "The samples are deliberately vulnerable toys (checker/samples/), never deployed anywhere.\n",
            "S5 is funded with 10 ETH before the run (the bounty its toy is about).\n\n",
            _matrix()
        );
        vm.writeFile("checker/reports/local-samples-matrix.md", out);
    }
}
