// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CheckerTestBase} from "./CheckerTestBase.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Status, Report, CheckConfig} from "../src/CheckerTypes.sol";
import "./mocks/HostileHooks.sol";

/// @notice The checker against the hostile / broken hooks, PoolManagers and PoolKeys listed in this file:
///         every run below has to return a complete 9-entry report that renders as printable ASCII. What
///         each hostile hook is reported as is asserted where it is unambiguous (not every cell). This
///         shows nothing about hostile behaviour that is not listed here; a hook that calls back into the
///         checker is covered in AuditRegression.t.sol and fork/ForkReentry.t.sol.
contract RobustnessTest is CheckerTestBase {
    uint160 internal constant ALL = uint160(Hooks.ALL_HOOK_MASK);
    uint160 internal constant SWAP_ONLY = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

    function setUp() public {
        _baseSetUp();
    }

    function _at(uint160 flags, bytes memory code, uint160 tag) internal returns (address a) {
        a = address((uint160(0xC0DE) << 144) | (tag << 16) | flags);
        vm.etch(a, code);
    }

    function _run(address hook) internal returns (Report memory rep) {
        rep = _check(hook);
        assertEq(rep.findings.length, 9, "complete report");
        bytes memory text = bytes(renderReport(rep));
        assertGt(text.length, 500, "renders");
        for (uint256 i; i < text.length; i++) {
            uint8 c = uint8(text[i]);
            assertTrue(c == 0x0a || (c >= 0x20 && c < 0x7f), "the report is printable ASCII whatever the hook returned");
        }
    }

    /// @dev runs the checker on `code` at four kinds of address: every bit set, swap callbacks only, no
    ///      bit at all, and a return-delta bit without its base bit (which PoolManager refuses)
    function _everywhere(bytes memory code, uint160 tag) internal returns (Report[4] memory reps) {
        uint160[4] memory flagSets = [ALL, SWAP_ONLY, uint160(0), uint160(Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG)];
        for (uint160 j; j < 4; j++) {
            reps[j] = _run(_at(flagSets[j], code, tag * 16 + j + 1));
        }
        // no bit set: PoolManager never calls the hook, whatever its code does
        // (b and g look at the code itself and may still have something to say)
        // (and f: nobody sets a fee in the checker's dynamic-fee pool)
        _assertCleanExcept(reps[2], (1 << B_CALLER) | (1 << G_UPGRADE) | (1 << F_DYNAMIC_FEE));
        _assertStatus(reps[2], D_REMOVE, Status.PASS);
        _assertStatus(reps[2], E_SWAP, Status.PASS);
        // return-delta bit without base bit
        _assertStatus(reps[3], A_PERMISSIONS, Status.FAIL);
        assertTrue(_mentions(reps[3], A_PERMISSIONS, "return-delta bit without its base bit"));
        _assertStatus(reps[3], D_REMOVE, Status.UNKNOWN); // no pool can exist
    }

    /// @dev A swap-only hook whose swaps all fail: no withdrawal step fails, but the three scenarios that
    ///      need a swap to move the price cannot be set up, and d is UNKNOWN (not PASS) while any scenario
    ///      is NOT TESTED (re-audit N-1). Was PASS before.
    function _dUntestedOnly(Report memory rep) internal pure {
        _assertStatus(rep, D_REMOVE, Status.UNKNOWN);
        string memory d = rep.findings[D_REMOVE].summary;
        assertTrue(_contains(d, "27 of 27 succeeded on the hooked pool, 0 reverted because of the hook, 0 reverted on both"), d);
        assertTrue(_contains(d, "NOT TESTED: 3 (price pushed below the LP range; price pushed above the LP range; price pushed below the LP range, then +15 seconds)"), d);
    }

    function test_garbageReturnData() public {
        Report[4] memory reps = _everywhere(type(GarbageHook).runtimeCode, 1);
        _assertStatus(reps[0], A_PERMISSIONS, Status.FAIL);
        _assertStatus(reps[1], A_PERMISSIONS, Status.FAIL);
        _assertStatus(reps[1], E_SWAP, Status.FAIL);
        assertTrue(_mentions(reps[1], E_SWAP, "InvalidHookResponse()"));
        _dUntestedOnly(reps[1]); // no liquidity callback declared: every withdrawal step that ran went through
    }

    function test_returnBomb() public {
        Report[4] memory reps = _everywhere(type(ReturnBombHook).runtimeCode, 2);
        _assertStatus(reps[1], E_SWAP, Status.FAIL);
        _dUntestedOnly(reps[1]);
    }

    function test_revertBomb() public {
        Report[4] memory reps = _everywhere(type(RevertBombHook).runtimeCode, 3);
        _assertStatus(reps[1], E_SWAP, Status.FAIL);
        _dUntestedOnly(reps[1]);
        // it reverts for everybody, PoolManager included, in the same way: that is not a caller check
        _assertStatus(reps[1], B_CALLER, Status.UNKNOWN);
        assertTrue(_mentions(reps[1], B_CALLER, "not a caller check, inconclusive"));
    }

    function test_gasBurner() public {
        Report[4] memory reps = _everywhere(type(GasBurnerHook).runtimeCode, 4);
        _assertStatus(reps[1], E_SWAP, Status.FAIL);
        assertTrue(_mentions(reps[1], E_SWAP, "gas"), "says it is about gas");
        _dUntestedOnly(reps[1]);
        _assertStatus(reps[0], D_REMOVE, Status.UNKNOWN); // with every bit set not even initialize gets through
    }

    function test_invalidOpcode() public {
        Report[4] memory reps = _everywhere(type(InvalidOpcodeHook).runtimeCode, 5);
        _assertStatus(reps[1], E_SWAP, Status.FAIL);
    }

    function test_echoSelector_wrongLengths() public {
        Report[4] memory reps = _everywhere(type(EchoSelectorHook).runtimeCode, 6);
        // 32 bytes with the right selector: fine for the plain callbacks, rejected for beforeSwap (96)
        _assertStatus(reps[1], A_PERMISSIONS, Status.FAIL);
        assertTrue(_mentions(reps[1], A_PERMISSIONS, "beforeSwap: DECLARED BUT NOT USABLE"));
        _assertStatus(reps[1], E_SWAP, Status.FAIL);
        // every bit set: initialize and plain callbacks work, the return-delta ones (64 bytes) do not
        _assertStatus(reps[0], A_PERMISSIONS, Status.FAIL);
        assertTrue(_mentions(reps[0], A_PERMISSIONS, "beforeInitialize: implemented"));
        assertTrue(_mentions(reps[0], A_PERMISSIONS, "afterRemoveLiquidity: DECLARED BUT NOT USABLE"));
        assertTrue(_mentions(reps[0], A_PERMISSIONS, "liquidity is stuck"));
        // it answers owner(), admin(), paused() ... with 32 bytes too
        _assertStatus(reps[0], G_UPGRADE, Status.UNKNOWN);
        // accepts every caller and never changes anything - but it is solc output: the first byte of its
        // metadata trailer reads as LOG1 in a full sweep, so the "no state-changing opcode" PASS is not
        // available and the answer is UNKNOWN (README, 误报; the PASS path is pinned in AuditRegression)
        _assertStatus(reps[0], B_CALLER, Status.UNKNOWN);
        assertTrue(_mentions(reps[0], B_CALLER, "ACCEPTED from a non-PoolManager address"));
    }

    function test_nastyRevertString() public {
        Report[4] memory reps = _everywhere(type(NastyStringHook).runtimeCode, 7);
        _assertStatus(reps[1], E_SWAP, Status.UNKNOWN); // an explicit Error(string): a refusal, not a crash
        assertTrue(_mentions(reps[1], E_SWAP, "already in the baseline"));
        assertFalse(_mentions(reps[1], E_SWAP, "<tag>"), "hook-supplied text is sanitised");
    }

    function test_noisyHook_manyLogsAndWrites() public {
        Report[4] memory reps = _everywhere(type(NoisyHook).runtimeCode, 8);
        _assertStatus(reps[0], B_CALLER, Status.FAIL);
        assertTrue(_mentions(reps[0], B_CALLER, "300 event(s)"));
        _assertStatus(reps[2], B_CALLER, Status.FAIL); // also at an address without any bit
    }

    function test_flakyHook_truncatedWrappedError() public {
        Report[4] memory reps = _everywhere(type(FlakyHook).runtimeCode, 9);
        _assertStatus(reps[1], B_CALLER, Status.FAIL); // counts its calls: state changed by anyone
    }

    /// @dev A limit of check b, pinned down: a callback WITHOUT a caller check that refuses the probe's
    ///      arguments looks, from the outside, like one that rejects strangers. The checker notices that
    ///      the PoolManager is turned away in exactly the same way and says UNKNOWN instead of PASS.
    function test_noCallerCheckBehindStrictHookData_isUnknownNotPass() public {
        Report memory rep = _run(_at(SWAP_ONLY, type(StrictHookDataHook).runtimeCode, 13));
        _assertStatus(rep, B_CALLER, Status.UNKNOWN);
        assertTrue(_mentions(rep, B_CALLER, "beforeSwap: reverts, but in exactly the same way when the PoolManager sends the same call"));
        assertTrue(_mentions(rep, B_CALLER, "not a caller check, inconclusive"));
    }

    function test_hookWithoutCode() public {
        Report memory rep = _run(address(uint160(0xDEAD0000) | ALL));
        for (uint256 i; i < 9; i++) {
            _assertStatus(rep, i, Status.NA);
        }
        assertEq(rep.findings[0].summary, "the hook address has no code");
    }

    function test_managerWithoutCode() public {
        address hook = _at(SWAP_ONLY, type(EchoSelectorHook).runtimeCode, 10);
        CheckConfig memory cfg;
        cfg.manager = IPoolManager(address(0xFEED));
        cfg.hook = hook;
        Report memory rep = runChecks(cfg);
        for (uint256 i; i < 9; i++) {
            _assertStatus(rep, i, Status.NA);
        }
        assertEq(rep.findings[0].summary, "the PoolManager address has no code");
    }

    /// @dev a "PoolManager" that is itself garbage: nothing works, nothing crashes
    function test_managerIsGarbage() public {
        address hook = _at(SWAP_ONLY, type(EchoSelectorHook).runtimeCode, 11);
        address fake = address(0xFA4E);
        bytes[3] memory codes = [type(GarbageHook).runtimeCode, type(GasBurnerHook).runtimeCode, type(RevertBombHook).runtimeCode];
        for (uint256 i; i < 3; i++) {
            vm.etch(fake, codes[i]);
            CheckConfig memory cfg;
            cfg.manager = IPoolManager(fake);
            cfg.hook = hook;
            Report memory rep = runChecks(cfg);
            assertEq(rep.findings.length, 9);
            _assertStatus(rep, D_REMOVE, Status.UNKNOWN);
            _assertStatus(rep, E_SWAP, Status.UNKNOWN);
        }
    }

    /// @dev PoolKeys that make no sense
    function test_nonsensePoolKeys() public {
        address hook = _at(SWAP_ONLY, type(EchoSelectorHook).runtimeCode, 12);
        CheckConfig memory cfg;
        cfg.manager = manager;
        cfg.hook = hook;
        cfg.hasKey = true;
        int24[4] memory spacings = [int24(0), int24(-60), int24(32767), int24(1)];
        for (uint256 i; i < 4; i++) {
            // currencies out of order, absurd fee, absurd spacing
            cfg.key = PoolKey(Currency.wrap(address(0x2222)), Currency.wrap(address(0x1111)), 0xFFFFFF, spacings[i], IHooks(hook));
            Report memory rep = runChecks(cfg);
            assertEq(rep.findings.length, 9);
            _assertStatus(rep, D_REMOVE, Status.UNKNOWN);
        }
        // a key that names another hook
        cfg.key = PoolKey(Currency.wrap(address(0x1111)), Currency.wrap(address(0x2222)), 3000, 60, IHooks(address(0x80)));
        Report memory r2 = runChecks(cfg);
        assertTrue(_contains(r2.setup[0], "is not the hook under test"));
    }
}
