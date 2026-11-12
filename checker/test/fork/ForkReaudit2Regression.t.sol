// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {CheckHook} from "../CheckHook.t.sol";
import {Status, Report} from "../../src/CheckerTypes.sol";
import {VBase, IRouterOwner} from "../mocks/AuditVariants.sol";

// DELIBERATELY HOSTILE TOY for the checker's own regression tests (re-audit finding N-4). Placed with
// vm.etch inside a local fork simulation. 故意带敌意,禁止部署. Never deployed; not aimed at, or usable
// against, anything.

/// @dev The auditor's Reenter2Hook (audits/audit-hooks-h3/reaudit/ForkReaudit2.t.sol), unchanged.
///      Flags: BEFORE_SWAP | BEFORE_REMOVE_LIQUIDITY. Every withdrawal reverts (mode 0 = control: d FAIL).
///  mode 1: every beforeRemoveLiquidity first calls `switchForkUnguarded()` on the checker, then reverts.
///          Withdrawals only happen inside the checker's per-scenario snapshots, never during setup.
///  mode 2: the first beforeSwap calls `rollForkUnguarded()` (same fork id, other block)
///  mode 3: the first beforeSwap calls `switchAndBackUnguarded()` (another fork and back again)
contract Reenter2Hook is VBase {
    bool public tried;

    error Blocked();

    function beforeRemoveLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata) external override returns (bytes4) {
        _only();
        if (mode == 1) {
            (bool ok,) = IRouterOwner(sender).owner().call(abi.encodeWithSignature("switchForkUnguarded()"));
            ok;
        }
        revert Blocked();
    }

    function beforeSwap(address sender, PoolKey calldata, SwapParams calldata, bytes calldata) external override returns (bytes4, BeforeSwapDelta, uint24) {
        _only();
        if (!tried && mode >= 2) {
            tried = true;
            (bool ok,) = IRouterOwner(sender).owner().call(abi.encodeWithSignature(mode == 2 ? "rollForkUnguarded()" : "switchAndBackUnguarded()"));
            ok;
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}

/// @dev Added with the fix. Flags: BEFORE_ADD_LIQUIDITY. The first time liquidity is added (the checker's
///      setup, before the checker has moved time at all) it calls `rollSameBlockUnguarded()`:
///      vm.rollFork to the block the fork is already at. Block number and timestamp stay what they were.
contract SetupRollHook is VBase {
    bool public tried;

    function beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata) external override returns (bytes4) {
        _only();
        if (!tried) {
            tried = true;
            (bool ok,) = IRouterOwner(sender).owner().call(abi.encodeWithSignature("rollSameBlockUnguarded()"));
            ok;
        }
        return IHooks.beforeAddLiquidity.selector;
    }
}

/// @notice Re-audit N-4: public functions of the test contract that change the simulated environment and
///         do NOT carry `notWhileChecking`, called by the hook under test while a run is in progress.
///         The fork-id check catches a switch to another fork; `vm.rollFork` keeps the fork id, and is
///         caught by the checker's clock (CheckerOps._clockN / _clockT): the block number and timestamp
///         are no longer where the checker's own moves left them. Before the fix, mode 2 was not void:
///         c = PASS on a state in which the pool under test no longer existed, e = FAIL attributed to the
///         hook for reverts that were PoolNotInitialized.
///         NOT caught, and pinned as such: a roll to the very block number and timestamp the clock shows.
///         Needs BASE_RPC_URL; skipped without it.
contract ForkReaudit2RegressionTest is CheckHook {
    address internal constant PM = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    uint256 internal constant FORK_BLOCK = 56_228_000;
    address internal constant HOOK = address((uint160(0xb00c) << 144) | uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG));
    address internal constant HOOK2 = address((uint160(0xb00d) << 144) | uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG));
    address internal hookUnderTest = HOOK;
    /// @dev what the control (mode 0) is reported as, a..i
    string internal constant CONTROL = "UPPFPUPPN";

    string internal rpc;
    string internal letters;
    bool internal voided;
    string internal reason;
    string internal text;
    string internal dSummary;
    bool internal armed;

    function setUp() public {
        rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true, "BASE_RPC_URL not set");
    }

    function _entry() internal view override returns (Entry memory e) {
        if (!armed) return e;
        e.hook = hookUnderTest;
        e.rpc = rpc;
        e.pin = FORK_BLOCK;
        e.fee = 0x800000;
        e.tickSpacing = 60;
    }

    function _onReport(Report memory rep, string memory text_) internal override {
        delete letters;
        for (uint256 i; i < rep.findings.length; i++) {
            Status st = rep.findings[i].status;
            letters = string.concat(letters, st == Status.PASS ? "P" : st == Status.FAIL ? "F" : st == Status.NA ? "N" : "U");
        }
        voided = rep.voided;
        reason = rep.voidReason;
        text = text_;
        dSummary = rep.findings[D_REMOVE].summary;
    }

    // Three public functions WITHOUT the notWhileChecking guard, as a user's own test contract may have.
    // (Do not copy this: README, "稳健性".)
    function switchForkUnguarded() public {
        vm.createSelectFork(rpc, FORK_BLOCK);
    }

    function rollForkUnguarded() public {
        vm.rollFork(FORK_BLOCK - 1);
    }

    function rollSameBlockUnguarded() public {
        vm.rollFork(FORK_BLOCK);
    }

    function switchAndBackUnguarded() public {
        uint256 f = vm.activeFork();
        vm.createSelectFork(rpc, FORK_BLOCK);
        vm.selectFork(f);
    }

    function _run(uint256 mode, bytes memory expectedNestedCall) internal {
        vm.createSelectFork(rpc, FORK_BLOCK);
        vm.etch(HOOK, type(Reenter2Hook).runtimeCode);
        vm.makePersistent(HOOK);
        Reenter2Hook(HOOK).init(IPoolManager(PM), mode);
        armed = true;
        if (expectedNestedCall.length != 0) vm.expectCall(address(this), expectedNestedCall);
        test_checkHook();
    }

    function _has(string memory hay, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(hay);
        bytes memory n = bytes(needle);
        if (h.length < n.length) return false;
        for (uint256 i; i + n.length <= h.length; i++) {
            bool ok = true;
            for (uint256 j; j < n.length && ok; j++) {
                ok = h[i + j] == n[j];
            }
            if (ok) return true;
        }
        return false;
    }

    function _assertVoid(string memory why) internal view {
        assertTrue(voided, "the report is void");
        assertEq(letters, "UUUUUUUUU", "every check UNKNOWN");
        assertTrue(_has(reason, why), reason);
        assertTrue(_has(text, "REPORT VOID - DO NOT USE"), "says so at the top");
        assertFalse(_has(text, "PASS"), "no PASS anywhere in a void report");
        assertFalse(_has(text, "## Setup"), "no setup section");
        assertFalse(_has(text, "reverted because of the hook"), "no leftover result text");
    }

    /// @dev control: every withdrawal reverts, nothing else happens -> d = FAIL. The 36 withdrawal steps
    ///      and the two full withdrawals of LP B that set up "single LP left" / "all liquidity removed".
    function test_fork_r2_mode0_control() public {
        _run(0, "");
        assertFalse(voided, "not void");
        assertEq(letters, CONTROL, text);
        assertTrue(_has(dSummary, "0 of 38 succeeded on the hooked pool, 38 reverted because of the hook"), dSummary);
    }

    /// @dev the switch happens inside a scenario snapshot (first withdrawal of the baseline scenario):
    ///      rolling the snapshot back does not quietly put the old fork back -> void
    function test_fork_r2_mode1_switchInsideScenarioSnapshot_void() public {
        _run(1, abi.encodeWithSignature("switchForkUnguarded()"));
        _assertVoid("the active fork changed while the checks were running");
    }

    /// @dev THE regression for N-4: vm.rollFork keeps the fork id. The clock is off -> void.
    function test_fork_r2_mode2_rollFork_void() public {
        _run(2, abi.encodeWithSignature("rollForkUnguarded()"));
        _assertVoid("the checker's footing is gone");
        assertTrue(_has(reason, "vm.rollFork"), "names the likely cause");
    }

    /// @dev another fork and back again within one call: the state of the original fork is intact, the
    ///      clock agrees, and the report is the control's
    function test_fork_r2_mode3_switchAndBack_sameAsControl() public {
        _run(3, abi.encodeWithSignature("switchAndBackUnguarded()"));
        assertFalse(voided, reason);
        assertEq(letters, CONTROL, text);
        assertTrue(_has(dSummary, "0 of 38 succeeded on the hooked pool, 38 reverted because of the hook"), dSummary);
    }

    /// @dev PINNED limit of the clock (README, 防不住的). vm.rollFork to the block the fork is already at,
    ///      made before the checker has moved time (in the first beforeAddLiquidity of its setup): block
    ///      number and timestamp are unchanged, the report is NOT void. In this instance nothing is
    ///      concluded from the replaced state (the add fails, d / e / f say UNKNOWN), but that is how this
    ///      toy happens to come out, not something the checker makes sure of.
    function test_fork_r2_pinned_sameBlockRollBeforeTheClockMoved_notVoid() public {
        vm.createSelectFork(rpc, FORK_BLOCK);
        vm.etch(HOOK2, type(SetupRollHook).runtimeCode);
        vm.makePersistent(HOOK2);
        SetupRollHook(HOOK2).init(IPoolManager(PM), 0);
        hookUnderTest = HOOK2;
        armed = true;
        vm.expectCall(address(this), abi.encodeWithSignature("rollSameBlockUnguarded()"));
        test_checkHook();
        assertFalse(voided, "not noticed");
        assertEq(letters, "PPUUUUPPN", text);
        assertTrue(_has(text, "ADD LIQUIDITY FAILED on the pool under test"), "what the roll did to the run");
    }
}
