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

// DELIBERATELY HOSTILE TOYS for the checker's own regression tests (audit finding H-1). Placed with
// vm.etch inside a local fork simulation. Never deployed; not aimed at, or usable against, anything.

/// @dev The auditor's ReenterHook (audits/audit-hooks-h3/ForkReenter.t.sol), unchanged in behaviour.
///      Flags: BEFORE_SWAP | BEFORE_REMOVE_LIQUIDITY. The first time PoolManager calls beforeSwap it finds
///      the checker (the owner of the checker's router, which is the `sender` argument) and calls the
///      checker's own public entry.
///      mode 0: gives the nested call all its gas; mode 1: 3M gas; mode 2: does nothing (control);
///      mode 3: like 1, and EVERY withdrawal reverts; mode 4: every withdrawal reverts, no re-entry
///      (control: d must be FAIL); mode 5: like 3, but calls `switchForkUnguarded()` instead - a public
///      function WITHOUT the notWhileChecking guard that selects a fork.
contract ReenterHook is VBase {
    uint256 public calls;
    bool public tried;
    bool public nestedOk;

    error Blocked();

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata) external view override returns (bytes4) {
        _only();
        if (mode >= 3) revert Blocked();
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function beforeSwap(address sender, PoolKey calldata, SwapParams calldata, bytes calldata) external override returns (bytes4, BeforeSwapDelta, uint24) {
        _only();
        calls++;
        if (!tried && mode != 2 && mode != 4) {
            tried = true;
            address checker = IRouterOwner(sender).owner();
            bool ok;
            if (mode == 0) (ok,) = checker.call(abi.encodeWithSignature("test_checkHook()"));
            else if (mode == 5) (ok,) = checker.call(abi.encodeWithSignature("switchForkUnguarded()"));
            else (ok,) = checker.call{gas: 3_000_000}(abi.encodeWithSignature("test_checkHook()"));
            nestedOk = ok;
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}

/// @notice H-1: the hook under test calls back into the checker's public entry while a run is in
///         progress. On a fork, `createSelectFork` inside that nested call is NOT undone when the nested
///         call reverts; before the fix the checker then kept going on another fork where its own routers
///         do not exist, every step reverted "also without hook", and d / e / c came out as PASS.
///         Drives the real entry (CheckHook.test_checkHook) with a fixed configuration instead of
///         environment variables. Needs BASE_RPC_URL; skipped without it.
contract ForkReentryTest is CheckHook {
    address internal constant PM = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    uint256 internal constant FORK_BLOCK = 56_228_000;
    /// @dev an address whose low 14 bits are BEFORE_SWAP | BEFORE_REMOVE_LIQUIDITY
    address internal constant HOOK = address((uint160(0xb00b) << 144) | uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG));

    string internal rpc;
    // what the entry reported (strings and flags only: a Report cannot be copied to storage)
    string internal letters;
    bool internal voided;
    string internal text;
    string internal dSummary;
    string internal eSummary;

    function setUp() public {
        rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true, "BASE_RPC_URL not set");
    }

    /// @dev set by _run. Until then the entry sees no hook, so the inherited `test_checkHook`, which forge
    ///      also runs as a test of this contract, is skipped like the plain command-line entry without $HOOK
    bool internal armed;

    function _entry() internal view override returns (Entry memory e) {
        if (!armed) return e;
        e.hook = HOOK;
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
        text = text_;
        dSummary = rep.findings[D_REMOVE].summary;
        eSummary = rep.findings[E_SWAP].summary;
    }

    /// @notice a public function that selects a fork and is NOT guarded: what a user's own test contract
    ///         may well have (a setUp, a helper). The fork-id check has to catch what it does.
    function switchForkUnguarded() public {
        vm.createSelectFork(rpc, FORK_BLOCK);
    }

    /// @dev stand-in for a hook that exists on the chain: placed while a fork is active and made
    ///      persistent, so it is there on every fork selected later, as deployed code would be
    ///      (Whatever the hook writes during the run is rolled back with the run, so its `tried` /
    ///      `nestedOk` flags cannot be read afterwards; `vm.expectCall` is what shows that it called back.)
    function _run(uint256 mode, bytes memory expectedNestedCall) internal {
        vm.createSelectFork(rpc, FORK_BLOCK);
        vm.etch(HOOK, type(ReenterHook).runtimeCode);
        vm.makePersistent(HOOK);
        ReenterHook(HOOK).init(IPoolManager(PM), mode);
        armed = true;
        if (expectedNestedCall.length != 0) vm.expectCall(address(this), expectedNestedCall);
        test_checkHook(); // an internal jump, not a call: the only CALL to this function is the hook's
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

    /// @dev control (the auditor's mode 4): every withdrawal reverts, no re-entry -> d = FAIL
    function test_fork_control_blockedWithdrawals_dFails() public {
        _run(4, "");
        assertFalse(voided, "not void");
        assertEq(bytes(letters)[D_REMOVE], bytes1("F"), dSummary);
        assertTrue(_has(dSummary, "0 of 38 succeeded on the hooked pool, 38 reverted because of the hook"), dSummary);
    }

    /// @dev THE regression (the auditor's mode 3): the same hook plus a nested call of the entry with 3M
    ///      gas. The nested call must be refused before it selects a fork, and the report must be the
    ///      control's: d = FAIL. Before the fix: d = PASS "all 24 withdrawal steps went through",
    ///      e = PASS "0 of 31 swaps went through", c = PASS.
    function test_fork_reentry_nestedEntryRefused_sameVerdictAsControl() public {
        _run(3, abi.encodeWithSignature("test_checkHook()")); // expectCall: the hook did call the entry
        uint256 forkBefore = vm.activeFork();
        assertFalse(voided, "a refused nested call does not void the run");
        assertEq(bytes(letters)[D_REMOVE], bytes1("F"), dSummary);
        assertTrue(_has(dSummary, "0 of 38 succeeded on the hooked pool, 38 reverted because of the hook"), dSummary);
        assertTrue(bytes(letters)[E_SWAP] == bytes1("P"), eSummary);
        // the two scenarios that need LP B to withdraw first cannot be set up: 9 x 4 + 6 swaps
        assertTrue(_has(eSummary, "42 of 42 succeeded on the hooked pool"), eSummary);
        assertTrue(_has(eSummary, "NOT TESTED: 2 (single LP left; all checker liquidity removed)"), eSummary);
        assertEq(forkBefore, 1, "the run ended on the fork the entry selected (id 1: 0 is the one _run made)");
    }

    /// @dev the same with all the gas the hook has (the auditor's mode 0, plus blocked withdrawals is
    ///      mode 3 only; here: no block, the report must simply not be disturbed)
    function test_fork_reentry_allGas_refused() public {
        _run(0, abi.encodeWithSignature("test_checkHook()"));
        assertFalse(voided);
        assertEq(bytes(letters)[D_REMOVE], bytes1("P"), dSummary);
        assertTrue(_has(dSummary, "39 of 39 succeeded on the hooked pool"), dSummary);
    }

    /// @dev the backstop: the nested call goes to a public function that is NOT guarded and it does
    ///      select another fork. The checker notices that the active fork changed and voids the whole
    ///      report: every check UNKNOWN, the reason at the top, the word PASS nowhere.
    function test_fork_reentry_unguardedForkSwitch_voidsTheReport() public {
        _run(5, abi.encodeWithSignature("switchForkUnguarded()"));
        assertTrue(voided, "the report is void");
        assertEq(letters, "UUUUUUUUU", "every check UNKNOWN");
        assertTrue(_has(text, "REPORT VOID - DO NOT USE"), "says so at the top");
        assertTrue(_has(text, "the active fork changed while the checks were running"), "and why");
        assertFalse(_has(text, "PASS"), "no PASS anywhere in a void report");
        assertFalse(_has(text, "went through"), "no leftover result text");
        assertEq(vm.activeFork(), 1, "the checker selected its own fork again before finishing");
    }
}
