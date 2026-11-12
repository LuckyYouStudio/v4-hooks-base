// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {CheckerTestBase} from "./CheckerTestBase.sol";
import {RevertInfo} from "../src/lib/RevertInfo.sol";
import {Status, Report, CheckConfig} from "../src/CheckerTypes.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {VBase, RouterWiperHook, MaxSwapHook} from "./mocks/AuditVariants.sol";
import {PerCurrencyVolumeHook} from "./AuditRegression.t.sol";
import "./mocks/Reaudit2Variants.sol";

/// @notice Regression tests for the H3 re-audit (audits/audit-hooks-h3-reaudit.md), N-1 .. N-5, and for
///         the mutations of that re-audit that survived. Each test names the finding it belongs to.
///         "fixed": the checker's answer changed with the fix; "pinned": a false negative the checker
///         still has, asserted as it is so that the README table cannot drift.
///         The fork part of N-4 is in test/fork/ForkReaudit2Regression.t.sol.
contract Reaudit2RegressionTest is CheckerTestBase {
    uint160 internal constant BI = uint160(Hooks.BEFORE_INITIALIZE_FLAG);
    uint160 internal constant AI = uint160(Hooks.AFTER_INITIALIZE_FLAG);
    uint160 internal constant AA = uint160(Hooks.AFTER_ADD_LIQUIDITY_FLAG);
    uint160 internal constant BR = uint160(Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG);
    uint160 internal constant AR = uint160(Hooks.AFTER_REMOVE_LIQUIDITY_FLAG);
    uint160 internal constant BS = uint160(Hooks.BEFORE_SWAP_FLAG);
    uint160 internal constant AS = uint160(Hooks.AFTER_SWAP_FLAG);
    uint160 internal constant ASRD = uint160(Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
    uint160 internal constant AARD = uint160(Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG);
    uint160 internal constant ARRD = uint160(Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG);

    uint160 internal tagCounter = 1;

    function setUp() public {
        _baseSetUp();
    }

    function _at(uint160 flags, bytes memory code, uint256 mode) internal returns (address a) {
        a = address((uint160(0xA0D2) << 144) | (tagCounter++ << 16) | flags);
        vm.etch(a, code);
        VBase(a).init(manager, mode);
    }

    function _quiet(address hook) internal returns (Report memory rep) {
        CheckConfig memory cfg;
        cfg.manager = manager;
        cfg.hook = hook;
        rep = runChecks(cfg);
    }

    function _summary(Report memory rep, uint256 idx) internal pure returns (string memory) {
        return rep.findings[idx].summary;
    }

    // =============================================================================================
    // N-1: a withdrawal that fails while a scenario is being set up is a withdrawal that failed
    // =============================================================================================

    /// @dev fixed. "Exit rate limit": with two equal LPs neither can leave in one step. The only place the
    ///      checker meets it is LP B's full withdrawal that sets up "single LP left" / "all liquidity
    ///      removed". Before the fix: d = PASS "36 of 36 succeeded ... NOT TESTED: 1 (single LP left)".
    function test_N1_rateLimitExit_setupWithdrawalIsCounted_dFails() public {
        Report memory rep = _quiet(_at(BR, type(RateLimitExitHook).runtimeCode, 0));
        _assertStatus(rep, D_REMOVE, Status.FAIL);
        string memory d = _summary(rep, D_REMOVE);
        // 36 ordinary steps went through; the second LP's full exit was refused twice (two scenarios)
        assertTrue(_contains(d, "36 of 38 succeeded on the hooked pool, 2 reverted because of the hook"), d);
        assertTrue(_contains(d, "NOT TESTED: 1 (single LP left)"), d);
        assertTrue(_mentions(rep, D_REMOVE, "single LP left, while setting the scenario up: | the second LP removes everything REVERT"), "per-scenario line");
        assertTrue(_mentions(rep, D_REMOVE, "all checker liquidity removed, while setting the scenario up: | the second LP removes everything REVERT"), "second scenario");
        assertTrue(_mentions(rep, D_REMOVE, "the second LP removes everything (scenario set-up): REVERT WrappedError{beforeRemoveLiquidity on "), "reason, once");
        assertTrue(_mentions(rep, D_REMOVE, "single LP left: NOT TESTED"), "and the scenario is still listed as not tested");
    }

    /// @dev fixed (project-lead decision on the re-audit: d is at most UNKNOWN while any scenario is NOT TESTED).
    ///      The hook refuses the large swap that would move the price, and blocks withdrawals while the
    ///      price is out of range: the three price scenarios cannot be set up, and those are the ones in
    ///      which it blocks. Before the fix: d = PASS "27 of 27 ... NOT TESTED: 3".
    function test_N1b_untestedScenarios_dIsUnknownNotPass() public {
        Report memory rep = _quiet(_at(BS | BR, type(MaxSwapOutOfRangeBlockHook).runtimeCode, 0));
        _assertStatus(rep, D_REMOVE, Status.UNKNOWN);
        string memory d = _summary(rep, D_REMOVE);
        assertTrue(_contains(d, "3 scenario(s) could NOT BE TESTED"), d);
        assertTrue(_contains(d, "27 of 27 succeeded on the hooked pool, 0 reverted because of the hook"), d);
        assertTrue(_contains(d, "NOT TESTED: 3 (price pushed below the LP range; price pushed above the LP range; price pushed below the LP range, then +15 seconds)"), d);
        assertFalse(_contains(d, "in every scenario"), "not the PASS wording");
    }

    /// @dev the PASS that is left needs every scenario: all 10 run, all 39 steps succeed (control)
    function test_N1_passNeedsEveryScenario() public {
        Report memory rep = _quiet(_at(BR, type(GlobalHalt2Hook).runtimeCode, 0)); // mode 0: nothing ever trips
        _assertStatus(rep, D_REMOVE, Status.PASS);
        assertTrue(_contains(_summary(rep, D_REMOVE), "every withdrawal step succeeded on the hooked pool in every scenario"));
        assertTrue(_contains(_summary(rep, D_REMOVE), "39 of 39 succeeded on the hooked pool"));
        assertTrue(_contains(_summary(rep, D_REMOVE), "scenarios run: 10, NOT TESTED: 0"));
    }

    // =============================================================================================
    // N-2: "probe failure" is an environment fact, never the shape of revert data
    // =============================================================================================

    function _mimicCfg(uint256 mode) internal returns (CheckConfig memory cfg) {
        MimicToken a = new MimicToken();
        MimicToken b = new MimicToken();
        address hook = _at(BS | AS, type(PanicAfterFourHook).runtimeCode, mode);
        a.setUp_(hook, address(manager));
        b.setUp_(hook, address(manager));
        (address t0, address t1) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        cfg.manager = manager;
        cfg.hook = hook;
        cfg.hasKey = true;
        cfg.key = PoolKey(Currency.wrap(t0), Currency.wrap(t1), 3000, 60, IHooks(hook));
    }

    /// @dev fixed. The hook panics on every swap after its 4th. Armed (mode 1), the pool's tokens also answer
    ///      balanceOf(PoolManager) with revert data shaped like Foundry's CheatcodeError (PoolManager.sync
    ///      bubbles that up unwrapped). Before the fix the armed run said e = UNKNOWN "PROBE FAILURE ... 0
    ///      reverted because of the hook" and "CHECKER TOOLING FAILURE (not evidence about the hook)".
    function test_N2_forgedCheatcodeError_sameVerdictAsControl() public {
        Report memory ctl = runChecks(_mimicCfg(0));
        Report memory armed = runChecks(_mimicCfg(1));
        _assertStatus(ctl, E_SWAP, Status.FAIL);
        _assertStatus(armed, E_SWAP, Status.FAIL);
        // control: all 41 swaps panic in the hook. Armed: the swap in which the hook arms the tokens is
        // itself undone by the tokens' forged revert, so the hook never gets past its 4th swap; 37 swaps
        // revert with the forged data on the hooked pool only (the 4 that settle nothing in go through).
        assertTrue(_contains(_summary(ctl, E_SWAP), "41 swap(s) reverted unexpectedly"), _summary(ctl, E_SWAP));
        string memory e = _summary(armed, E_SWAP);
        assertTrue(_contains(e, "37 swap(s) reverted unexpectedly"), e);
        assertTrue(_contains(e, "4 of 41 succeeded on the hooked pool, 37 reverted because of the hook, 0 reverted on both"), e);
        assertTrue(_contains(e, ", 0 probe failure(s)"), e);
        assertEq(_oneLine(armed), _oneLine(ctl), "all nine statuses equal those of the control");
        assertEq(_oneLine(armed), "a=PASS b=PASS c=UNKNOWN d=UNKNOWN e=FAIL f=N/A g=PASS h=PASS i=N/A ");

        string memory text = renderReport(armed);
        // the forged data is shown for what it is, and the report takes nobody's side
        assertTrue(_contains(text, "CheatcodeError(string)"), "the revert is displayed");
        assertTrue(_contains(text, "shaped like a Foundry cheatcode error; any contract in the pool can produce such data"), "with the note");
        assertFalse(_contains(text, "not evidence about the hook"), "no exculpating sentence");
        assertFalse(_contains(text, "CHECKER TOOLING"), "nothing is booked as a tooling failure");
        assertFalse(_contains(text, "PROBE FAIL"), "nor as a probe failure");
    }

    /// @dev N-2, check c: a reference operation that reverts out of a callback of the hook after the
    ///      stranger's activity is reported as a difference BEFORE any probe failure. Here the stranger's
    ///      pool trips a global withdrawal block and, in the same call, the hook wipes the stranger's
    ///      router (the checker's tooling is broken from then on). Without the rule: c = UNKNOWN "PROBE FAILURE".
    function test_N2_checkC_hookAttributedDifferenceBeatsProbeFailure() public {
        Report memory rep = _quiet(_at(AI | BR, type(StrangerRouterWiperHook).runtimeCode, 1));
        _assertStatus(rep, C_FOREIGN_POOL, Status.FAIL);
        string memory c = _summary(rep, C_FOREIGN_POOL);
        // fee collection and partial withdrawal now revert in the hook; the small add that follows comes
        // out with other amounts because those two did not happen
        assertTrue(_contains(c, "changes the outcome of 3 of 9 reference operations"), c);
        assertTrue(_contains(c, "2 of them now revert out of a callback of the hook"), c);
        assertTrue(_mentions(rep, C_FOREIGN_POOL, "reference partial withdrawal by LP A DIFFERS"), "which");
        assertTrue(_mentions(rep, C_FOREIGN_POOL, "ACCEPTED - then in that pool: add liquidity reverted, 0/5 swaps ok"), "the tooling was broken in the same flow");
    }

    /// @dev the order inside _classify, directly: a revert out of a callback of the hook is attributed to
    ///      the hook whatever the control pool did and whatever state the tooling is in; a broken tooling
    ///      on either side is a probe failure, never "reverted on both"
    function test_N2_classifyOrder() public {
        _hook = address(0xBEEF);
        OpRes memory ok;
        ok.ok = true;
        OpRes memory plain; // reverted, not out of the hook
        plain.err = RevertInfo.decode(abi.encodeWithSignature("Error(string)", "x"));
        OpRes memory infra = _copy(plain);
        infra.infra = true;
        OpRes memory fromHookPanic;
        fromHookPanic.err = RevertInfo.decode(_wrapped(address(0xBEEF), abi.encodeWithSignature("Panic(uint256)", uint256(0x12))));
        OpRes memory fromHookCustom;
        fromHookCustom.err = RevertInfo.decode(_wrapped(address(0xBEEF), abi.encodeWithSignature("Nope()")));
        OpRes memory fromOther;
        fromOther.err = RevertInfo.decode(_wrapped(address(0xCAFE), abi.encodeWithSignature("Nope()")));
        OpRes memory hookAndInfra = _copy(fromHookPanic);
        hookAndInfra.infra = true;

        assertEq(_classify(ok, infra), 0, "succeeded");
        assertEq(_classify(fromHookPanic, ok), 2, "panic in the hook");
        assertEq(_classify(fromHookPanic, plain), 2, "... control reverts too: still the hook");
        assertEq(_classify(fromHookPanic, infra), 2, "... control hit broken tooling: still the hook");
        assertEq(_classify(hookAndInfra, infra), 2, "... tooling broken on both sides: still the hook");
        assertEq(_classify(fromHookCustom, infra), 1, "explicit refusal by the hook, same rule");
        assertEq(_classify(plain, ok), 2, "hooked pool only");
        assertEq(_classify(plain, plain), 3, "both pools");
        assertEq(_classify(infra, plain), 4, "tooling broken on the hooked side");
        assertEq(_classify(plain, infra), 4, "tooling broken on the control side: a probe failure, not 'both pools'");
        assertEq(_classify(fromOther, plain), 3, "a wrapped revert of ANOTHER contract is not the hook's");
    }

    function _copy(OpRes memory r) internal pure returns (OpRes memory c) {
        c.ok = r.ok;
        c.oog = r.oog;
        c.infra = r.infra;
        c.err = r.err;
    }

    function _wrapped(address target, bytes memory reason) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector, target, IHooks.beforeSwap.selector, reason, abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /// @dev H-1 item 3 must not regress with N-2: a wiped router is still a probe failure for e. And d
    ///      (re-audit, mutation N4): the withdrawal steps that ran went through LP routers that were not
    ///      wiped, but three scenarios could not be set up, so d is UNKNOWN, not PASS.
    function test_N2_routerWiper_stillProbeFailure_andDNotPass() public {
        Report memory rep = _quiet(_at(BS, type(RouterWiperHook).runtimeCode, 0));
        _assertStatus(rep, E_SWAP, Status.UNKNOWN);
        assertTrue(_contains(_summary(rep, E_SWAP), "PROBE FAILURE"), _summary(rep, E_SWAP));
        assertTrue(_mentions(rep, E_SWAP, "CHECKER TOOLING BROKEN: one of the checker's own routers has no code"), "says what broke");
        _assertStatus(rep, D_REMOVE, Status.UNKNOWN);
        assertTrue(_contains(_summary(rep, D_REMOVE), "3 scenario(s) could NOT BE TESTED"), _summary(rep, D_REMOVE));
        _assertStatus(rep, C_FOREIGN_POOL, Status.UNKNOWN);
        assertTrue(_contains(_summary(rep, C_FOREIGN_POOL), "PROBE FAILURE"), _summary(rep, C_FOREIGN_POOL));
    }

    /// @dev mutation N4 ("probe failures no longer stop a PASS in d"). Every scenario is set up, no
    ///      withdrawal is refused by the hook, none reverts on both pools - but the hook wipes each LP
    ///      router after its first withdrawal, so the following steps fail for tooling reasons.
    function test_N4mut_lpRouterWiped_dIsProbeFailureNotPass() public {
        Report memory rep = _quiet(_at(BR, type(LpRouterWiperHook).runtimeCode, 0));
        _assertStatus(rep, D_REMOVE, Status.UNKNOWN);
        string memory d = _summary(rep, D_REMOVE);
        assertTrue(_contains(d, "PROBE FAILURE"), d);
        assertTrue(_contains(d, ", 0 reverted because of the hook, 0 reverted on both the hooked and the hook-less control pool, 20 probe failure(s)"), d);
        assertTrue(_contains(d, "NOT TESTED: 0"), d);
        assertTrue(_mentions(rep, D_REMOVE, "half PROBE FAILED"), "per-step");
    }

    // =============================================================================================
    // N-3: a void report carries nothing from the run
    // =============================================================================================

    /// @dev fixed, and the offline test of the void path (chain-id leg; mutations N1, N2). The hook
    ///      refuses the first pool with a revert string that contains "PASS" (it lands in a setup line),
    ///      then changes the chain id with a cheatcode. Before the fix the void report still printed its
    ///      Setup section, with that string in it.
    function test_N3_voidReport_chainIdChanged_noPassAnywhere() public {
        uint256 chain = block.chainid;
        Report memory rep = _quiet(_at(BI | BS, type(VoidTextHook).runtimeCode, 0));
        assertTrue(rep.voided, "void");
        assertTrue(_contains(rep.voidReason, "the chain id changed while the checks were running"), rep.voidReason);
        assertEq(_oneLine(rep), "a=UNKNOWN b=UNKNOWN c=UNKNOWN d=UNKNOWN e=UNKNOWN f=UNKNOWN g=UNKNOWN h=UNKNOWN i=UNKNOWN ");
        assertEq(rep.setup.length, 0, "no setup lines in a void report");
        for (uint256 i; i < 9; i++) {
            assertEq(rep.findings[i].details.length, 0, "no details");
        }
        string memory text = renderReport(rep);
        assertTrue(_contains(text, "REPORT VOID - DO NOT USE"), "says so at the top");
        assertFalse(_contains(text, "PASS"), "the word PASS occurs nowhere in a void report");
        assertFalse(_contains(text, "audited"), "none of the hook's text");
        assertFalse(_contains(text, "## Setup"), "no setup section");
        assertFalse(_contains(text, "## Details"), "no details section");
        assertEq(block.chainid, chain, "the run was rolled back, chain id included");
    }

    // =============================================================================================
    // N-4 (offline part): an empty comparison in check c is not a PASS
    // =============================================================================================

    /// @dev The clock leg of the footing check, offline (the fork test with vm.rollFork is
    ///      test_fork_r2_mode2_rollFork_void). mode 1: the hook moves the timestamp during setup.
    ///      mode 5: it moves it in every swap after the warm-up. mode 6: it moves it ONLY inside the
    ///      snapshot the checker takes around a single swap of a scenario; rolling that snapshot back puts
    ///      the timestamp back, so the checker has to look BEFORE it rolls back (mutation Q11).
    function test_N4_clockMovedUnderTheChecker_void() public {
        uint256[3] memory modes = [uint256(1), 5, 6];
        for (uint256 k; k < 3; k++) {
            uint256 m = modes[k];
            uint256 t = block.timestamp;
            Report memory rep = _quiet(_at(BS, type(ClockMoverHook).runtimeCode, m));
            assertTrue(rep.voided, m == 1 ? "void (moved during setup)" : m == 5 ? "void (moved after the warm-up)" : "void (moved inside a per-swap snapshot only)");
            assertTrue(_contains(rep.voidReason, "the checker's footing is gone: block number / timestamp are "), rep.voidReason);
            assertFalse(_contains(renderReport(rep), "PASS"), "no PASS in a void report");
            assertEq(block.timestamp, t, "rolled back");
        }
    }

    /// @dev control for the test above: the same hook never firing is not void
    function test_N4_clockUntouched_notVoid() public {
        Report memory rep = _quiet(_at(BS, type(ClockMoverHook).runtimeCode, 0));
        assertFalse(rep.voided, rep.voidReason);
        _assertStatus(rep, E_SWAP, Status.PASS);
    }

    /// @dev fixed. The reference swaps all fail with and without a stranger pool (the hook panics on every
    ///      swap after its 4th): "the 9 reference operations come out identical" was a PASS before.
    function test_N4_referenceFlowThatDoesNotWork_cIsUnknown() public {
        Report memory rep = runChecks(_mimicCfg(0));
        _assertStatus(rep, C_FOREIGN_POOL, Status.UNKNOWN);
        string memory c = _summary(rep, C_FOREIGN_POOL);
        assertTrue(_contains(c, "the comparison is empty: 3 of 9 succeeded without a stranger pool (0 of 6 swaps)"), c);
    }

    /// @dev the PASS summary of c says how many reference operations worked
    function test_N4_cPassSummaryCarriesTheCount() public {
        Report memory rep = _quiet(_at(BR, type(GlobalHalt2Hook).runtimeCode, 0));
        _assertStatus(rep, C_FOREIGN_POOL, Status.PASS);
        assertTrue(_contains(_summary(rep, C_FOREIGN_POOL), "9 of 9 succeeded without a stranger pool (6 of 6 swaps)"), _summary(rep, C_FOREIGN_POOL));
    }

    // =============================================================================================
    // N-5: stranger pools with extreme parameters; what the 9 reference operations still do not reach
    // =============================================================================================

    /// @dev was a false negative in the re-audit (c = PASS): a global switch that only trips on extreme
    ///      pool parameters. The stranger now also creates a pool with the largest tickSpacing one tick
    ///      above MIN_TICK and one, with the same tickSpacing, one tick below MAX_TICK.
    function test_N5_globalSwitchTrippedByExtremeParameters_detected() public {
        Report memory rep = _quiet(_at(AI | BR, type(GlobalHalt2Hook).runtimeCode, 1));
        _assertStatus(rep, C_FOREIGN_POOL, Status.FAIL);
        assertTrue(_mentions(rep, C_FOREIGN_POOL, "extreme parameters (own two tokens, initial tick -887271): fee DYNAMIC spacing 32767: ACCEPTED"), "min-tick pool");
        assertTrue(_mentions(rep, C_FOREIGN_POOL, "extreme parameters (own two tokens, initial tick 887271): fee DYNAMIC spacing 32767: ACCEPTED"), "max-tick pool");
        assertTrue(_mentions(rep, C_FOREIGN_POOL, "reference partial withdrawal by LP A DIFFERS"), "withdrawal now reverts");
        assertTrue(_mentions(rep, C_FOREIGN_POOL, "(the revert comes out of a callback of the hook)"), "attributed");
        assertTrue(_contains(_summary(rep, C_FOREIGN_POOL), "of them now revert out of a callback of the hook"), _summary(rep, C_FOREIGN_POOL));
    }

    /// @dev Found while adding the extreme pools: whether the stranger's "shared currency0" pool had the
    ///      shared token as ITS currency0 was left to the address the stranger's own token happened to get,
    ///      i.e. to how many contracts had been created before. Here currency0 of the pool under test is
    ///      a high address (three out of four fresh addresses sort below it); the hook books volume per
    ///      `key.currency0` and is only reached when the shared token is currency0 in the stranger's pool too.
    function test_N5_sharedCurrencyPool_sharedTokenIsCurrency0ThereToo() public {
        address t0 = address(0xC0FFEe0000000000000000000000000000000001);
        address t1 = address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);
        vm.etch(t0, address(new MockERC20("High 0", "H0", 18)).code);
        vm.etch(t1, address(new MockERC20("High 1", "H1", 18)).code);
        address hook = _at(BS, type(PerCurrencyVolumeHook).runtimeCode, 0);
        CheckConfig memory cfg;
        cfg.manager = manager;
        cfg.hook = hook;
        cfg.hasKey = true;
        cfg.key = PoolKey(Currency.wrap(t0), Currency.wrap(t1), 0x800000, 60, IHooks(hook));
        Report memory rep = runChecks(cfg);
        _assertStatus(rep, C_FOREIGN_POOL, Status.FAIL);
        assertTrue(_mentions(rep, C_FOREIGN_POOL, "sharing currency0 of the pool under test, other token its own: fee DYNAMIC spacing 60: ACCEPTED"), "shared token first, pool accepted");
        assertFalse(_mentions(rep, C_FOREIGN_POOL, "the shared token is currency1 in this pool"), "not the fallback");
    }

    /// @dev PINNED false negatives (README, 漏报).
    ///      mode 2: the switch trips as in GlobalHaltHook, but only withdrawals of more than 20% of the
    ///      pool read it; the reference withdrawal is a quarter of one LP = 12.5% of the pool.
    ///      mode 3: the switch trips on a pool parameter the stranger pools do not use (tickSpacing 200).
    function test_N5_pinned_c_largeExitOnly_and_untriedParameter_notDetected() public {
        for (uint256 m = 2; m <= 3; m++) {
            Report memory rep = _quiet(_at(AI | BR, type(GlobalHalt2Hook).runtimeCode, m));
            _assertStatus(rep, C_FOREIGN_POOL, Status.PASS);
            _assertStatus(rep, D_REMOVE, Status.PASS);
        }
    }

    // =============================================================================================
    // Mutations of the re-audit that survived: N5, N6, N10, N11 (and M10 of the first audit)
    // =============================================================================================

    /// @dev mutation N5 ("liquidity reference operations compared by ok / revert selector only"): once a
    ///      second pool exists, the hook keeps 1% of what a withdrawal pays out. Nothing reverts.
    function test_N5mut_strangerPoolChangesWithdrawalAmountsOnly_detected() public {
        Report memory rep = _quiet(_at(AI | AR | ARRD, type(GlobalLevyHook).runtimeCode, 1));
        _assertStatus(rep, C_FOREIGN_POOL, Status.FAIL);
        assertTrue(_mentions(rep, C_FOREIGN_POOL, "reference partial withdrawal by LP A DIFFERS after the stranger pool's activity: router delta ("), "amounts differ");
        assertTrue(_mentions(rep, C_FOREIGN_POOL, "reference fee collection by LP A (liquidityDelta 0) DIFFERS"), "fee collection too");
        assertFalse(_mentions(rep, C_FOREIGN_POOL, "->  revert"), "no operation reverts");
        assertTrue(_contains(_summary(rep, C_FOREIGN_POOL), "changes the outcome of 2 of 9 reference operations"), _summary(rep, C_FOREIGN_POOL));
    }

    /// @dev mutation N11 ("the small add, reference operation 9, is not compared"): the only thing a
    ///      second pool changes is that adding liquidity costs 1% more
    function test_N11mut_strangerPoolChangesTheSmallAddOnly_detected() public {
        Report memory rep = _quiet(_at(AI | AA | AARD, type(GlobalLevyHook).runtimeCode, 2));
        _assertStatus(rep, C_FOREIGN_POOL, Status.FAIL);
        assertTrue(_mentions(rep, C_FOREIGN_POOL, "reference small add by LP A DIFFERS after the stranger pool's activity: router delta ("), "small add");
        assertTrue(_contains(_summary(rep, C_FOREIGN_POOL), "changes the outcome of 1 of 9 reference operations"), _summary(rep, C_FOREIGN_POOL));
    }

    /// @dev mutation N6 ("the revert selector of a reference operation is not compared"): exactOut swaps
    ///      are refused with and without a stranger pool, but for a different reason once one exists
    function test_N6mut_strangerPoolChangesTheRevertReasonOnly_detected() public {
        Report memory rep = _quiet(_at(AI | BS, type(GlobalLevyHook).runtimeCode, 3));
        _assertStatus(rep, C_FOREIGN_POOL, Status.FAIL);
        assertTrue(_mentions(rep, C_FOREIGN_POOL, "reference swap #2 DIFFERS after the stranger pool's activity: revert  ->  revert"), "same outcome, other reason");
        assertTrue(_contains(_summary(rep, C_FOREIGN_POOL), "changes the outcome of 2 of 9 reference operations"), _summary(rep, C_FOREIGN_POOL));
    }

    /// @dev mutation N10 ("a tooling failure in the recorded flow of c is ignored"): the stranger's pool
    ///      is accepted and its router is wiped in the same call, so the stranger never trades. Without the
    ///      check: c = PASS "changed no hook storage slot ... come out identical".
    function test_N10mut_toolingBrokenDuringStrangerActivity_cIsProbeFailure() public {
        Report memory rep = _quiet(_at(AI, type(StrangerRouterWiperHook).runtimeCode, 0));
        _assertStatus(rep, C_FOREIGN_POOL, Status.UNKNOWN);
        assertTrue(_contains(_summary(rep, C_FOREIGN_POOL), "PROBE FAILURE"), _summary(rep, C_FOREIGN_POOL));
        assertTrue(_mentions(rep, C_FOREIGN_POOL, "ACCEPTED - then in that pool: add liquidity reverted, 0/5 swaps ok"), "the stranger could do nothing");
    }

    /// @dev mutation M10 of the first audit ("reference swaps compared without fee and pool amounts"):
    ///      a second pool moves the LP fee from 3000 to 3001 pips, and the hook rounds what the swapper
    ///      pays / receives to a multiple of 1e15, which hides the change from the swapper's own amounts.
    function test_M10mut_feeChangeHiddenFromTheRouterAmounts_detected() public {
        Report memory rep = _quiet(_at(AI | BS | AS | ASRD, type(RoundingAbsorberHook).runtimeCode, 0));
        _assertStatus(rep, C_FOREIGN_POOL, Status.FAIL);
        assertTrue(_mentions(rep, C_FOREIGN_POOL, "reference swap #1 DIFFERS after the stranger pool's activity"), "the first swap: same start state, same router amounts");
        assertTrue(_mentions(rep, C_FOREIGN_POOL, " fee 3000  ->  router delta ("), "fee before");
        assertTrue(_mentions(rep, C_FOREIGN_POOL, " fee 3001"), "fee after");
    }
}
