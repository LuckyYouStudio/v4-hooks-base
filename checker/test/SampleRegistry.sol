// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {CheckerTestBase} from "./CheckerTestBase.sol";
import {Status, Report} from "../src/CheckerTypes.sol";
import {ExtraBitHook, ExtraBitHookFixed} from "../samples/S1_ExtraPermissionBit.sol";
import {NoCallerCheckHook, NoCallerCheckHookFixed} from "../samples/S2_NoCallerCheck.sol";
import {GlobalStateHook, GlobalStateHookFixed} from "../samples/S3_GlobalState.sol";
import {WrongDeltaHook, WrongDeltaHookFixed} from "../samples/S4_WrongDeltaDirection.sol";
import {SharedSlotGuardHook, SharedSlotGuardHookFixed} from "../samples/S5_SharedSlotGuard.sol";
import {DonatePenaltyHook, DonatePenaltyHookFixed} from "../samples/S6_DonatePenalty.sol";
import {StaleOverflowHook, StaleOverflowHookFixed} from "../samples/S7_StaleOverflow.sol";
import {SpotFeeHook, SpotFeeHookFixed} from "../samples/S8_SpotFee.sol";
import {UncappedFeeHook, UncappedFeeHookFixed} from "../samples/S9_UncappedFee.sol";
import {UpgradeableAdminHook, UpgradeableAdminHookFixed, SwapLogicV1} from "../samples/S10_UpgradeableAdmin.sol";

/// @notice Deploys the samples of checker/samples/ at mined addresses (HookMiner, CREATE2 from this test
///         contract) on the local PoolManager of CheckerTestBase.
abstract contract SampleRegistry is CheckerTestBase {
    uint256 internal constant SAMPLES = 10;

    uint160 internal constant BEFORE_SWAP = uint160(Hooks.BEFORE_SWAP_FLAG);
    uint160 internal constant S1_EXTRA = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG);
    uint160 internal constant S4_FLAGS = uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
    uint160 internal constant S6_FLAGS =
        uint160(Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG);

    MockERC20 internal rewardToken;
    address internal constant SAMPLE_OWNER = address(0x0A11CE);

    function _sampleName(uint256 n, bool fixed_) internal pure returns (string memory) {
        string[10] memory names = [
            "S1 ExtraBitHook", "S2 NoCallerCheckHook", "S3 GlobalStateHook", "S4 WrongDeltaHook", "S5 SharedSlotGuardHook",
            "S6 DonatePenaltyHook", "S7 StaleOverflowHook", "S8 SpotFeeHook", "S9 UncappedFeeHook", "S10 UpgradeableAdminHook"
        ];
        return string.concat(names[n - 1], fixed_ ? "Fixed" : "");
    }

    /// @notice What the checker is expected to say about each sample: one letter per check a..i,
    ///         P = PASS, F = FAIL, U = UNKNOWN, N = N/A. This table IS the detection matrix of the README;
    ///         the local and the fork matrix tests both assert it.
    ///         (S5 is funded with 10 ETH before the run, which is what makes h say UNKNOWN.)
    function _expected(uint256 n, bool fixed_) internal pure returns (string memory) {
        string[10] memory vulnerable = [
            "FPPFPUPPN", // S1: permissions (a) and withdrawals (d)
            "PFPPPUPPN", // S2: caller check (b)
            "PPFPPPPPN", // S3: foreign pool (c)
            "PPPPPUPUU", // S4: only a hint in i (and the fact that the hook holds its fees in h): NO FAIL
            "PPPPPUPUN", // S5: NOT DETECTED (h only states that the hook holds ETH)
            "PPPFPUPPP", // S6: withdrawals (d)
            "PPPPFUPPN", // S7: swaps (e)
            "PPPPPUPPN", // S8: hint in f
            "PPPPFFPPN", // S9: fee bound (f) and swaps (e)
            "PPPPPUUPN" //  S10: signs listed in g
        ];
        // column f: U for every sample that is not a fee hook (S1, S2, S4-S7, S10): in the checker's own
        // dynamic-fee pool all their swaps pay a fee of 0, which is reported as UNKNOWN with a hint, not
        // as PASS (audit L-2). The fee hooks S3, S8, S9 are judged as before.
        string[10] memory fixedOnes = [
            "PPPPPUPPN", "PPPPPUPPN", "PPPPPPPPN", "PPPPPUPUP", "PPPPPUPUN", "PPPPPUPPP", "PPPPPUPPN", "PPPPPPPPN",
            "PPPPPPPPN", "PPPPPUPPN"
        ];
        return fixed_ ? fixedOnes[n - 1] : vulnerable[n - 1];
    }

    function _letters(Report memory rep) internal pure returns (string memory s) {
        for (uint256 i; i < rep.findings.length; i++) {
            Status st = rep.findings[i].status;
            s = string.concat(s, st == Status.PASS ? "P" : st == Status.FAIL ? "F" : st == Status.NA ? "N" : "U");
        }
    }

    /// @dev runs the checker on all 20 samples, asserts the expected letters, returns a markdown table
    function _matrix() internal returns (string memory out) {
        out = "| sample | a | b | c | d | e | f | g | h | i |\n|---|---|---|---|---|---|---|---|---|---|\n";
        for (uint256 n = 1; n <= SAMPLES; n++) {
            for (uint256 f; f < 2; f++) {
                address hook = _deploySample(n, f == 1);
                if (n == 5) vm.deal(hook, 10 ether); // the bounty the S5 toy is about
                Report memory rep = _check(hook);
                assertEq(_letters(rep), _expected(n, f == 1), _sampleName(n, f == 1));
                out = string.concat(out, "| ", _sampleName(n, f == 1));
                for (uint256 i; i < rep.findings.length; i++) {
                    out = string.concat(out, " | ", statusName(rep.findings[i].status));
                }
                out = string.concat(out, " |\n");
            }
        }
    }

    function _create2(uint160 flags, bytes memory creationCode, bytes memory args) internal returns (address a) {
        bytes32 salt = _salt(flags, creationCode, args);
        bytes memory init = abi.encodePacked(creationCode, args);
        assembly {
            a := create2(0, add(init, 0x20), mload(init), salt)
        }
        require(a != address(0), "sample deployment reverted");
        assertEq(uint160(a) & Hooks.ALL_HOOK_MASK, flags, "mined flags");
    }

    /// @param n 1..10, the S-number of the sample
    function _deploySample(uint256 n, bool fixed_) internal returns (address hook) {
        bytes memory m = abi.encode(manager);
        if (n == 1) {
            // the vulnerable one sits at an address with one bit too many, which is the bug
            return fixed_
                ? _create2(BEFORE_SWAP, type(ExtraBitHookFixed).creationCode, m)
                : _create2(S1_EXTRA, type(ExtraBitHook).creationCode, m);
        }
        if (n == 2) {
            if (address(rewardToken) == address(0)) rewardToken = new MockERC20("Reward", "RWD", 18);
            bytes memory args = abi.encode(manager, rewardToken);
            hook = _create2(BEFORE_SWAP, fixed_ ? type(NoCallerCheckHookFixed).creationCode : type(NoCallerCheckHook).creationCode, args);
        } else if (n == 3) {
            hook = _create2(BEFORE_SWAP, fixed_ ? type(GlobalStateHookFixed).creationCode : type(GlobalStateHook).creationCode, m);
        } else if (n == 4) {
            hook = _create2(S4_FLAGS, fixed_ ? type(WrongDeltaHookFixed).creationCode : type(WrongDeltaHook).creationCode, m);
        } else if (n == 5) {
            hook = _create2(BEFORE_SWAP, fixed_ ? type(SharedSlotGuardHookFixed).creationCode : type(SharedSlotGuardHook).creationCode, m);
        } else if (n == 6) {
            hook = _create2(S6_FLAGS, fixed_ ? type(DonatePenaltyHookFixed).creationCode : type(DonatePenaltyHook).creationCode, m);
        } else if (n == 7) {
            hook = _create2(BEFORE_SWAP, fixed_ ? type(StaleOverflowHookFixed).creationCode : type(StaleOverflowHook).creationCode, m);
        } else if (n == 8) {
            hook = _create2(BEFORE_SWAP, fixed_ ? type(SpotFeeHookFixed).creationCode : type(SpotFeeHook).creationCode, m);
        } else if (n == 9) {
            hook = _create2(BEFORE_SWAP, fixed_ ? type(UncappedFeeHookFixed).creationCode : type(UncappedFeeHook).creationCode, m);
        } else {
            hook = fixed_
                ? _create2(BEFORE_SWAP, type(UpgradeableAdminHookFixed).creationCode, m)
                : _create2(
                    BEFORE_SWAP,
                    type(UpgradeableAdminHook).creationCode,
                    abi.encode(manager, SAMPLE_OWNER, address(new SwapLogicV1()))
                );
        }
        // every sample except the S1 vulnerable one sits at an address that matches what it declares
        (bool ok, bytes memory ret) = hook.staticcall(abi.encodeWithSignature("getHookPermissions()"));
        require(ok, "getHookPermissions");
        Hooks.validateHookPermissions(IHooks(hook), abi.decode(ret, (Hooks.Permissions)));
    }
}
