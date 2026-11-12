// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {CheckerTestBase} from "./CheckerTestBase.sol";
import {CheckHook} from "./CheckHook.t.sol";
import {BytecodeScan} from "../src/lib/BytecodeScan.sol";
import {Status, Report, CheckConfig} from "../src/CheckerTypes.sol";
import "./mocks/AuditVariants.sol";

/// @notice Regression tests for the first H3 audit (audits/audit-hooks-h3.md). Each test names the
///         finding it belongs to. Two kinds:
///         - "fixed": the checker's answer changed with the fix, and the test fails without it;
///         - "pinned": a false negative the checker still has. The test asserts the CURRENT answer so that
///           the README's false-negative table cannot drift away from what the tool really says.
///         The H-1 tests need a fork and live in test/fork/ForkReentry.t.sol.
contract AuditRegressionTest is CheckerTestBase {
    uint160 internal constant BI = uint160(Hooks.BEFORE_INITIALIZE_FLAG);
    uint160 internal constant AI = uint160(Hooks.AFTER_INITIALIZE_FLAG);
    uint160 internal constant AA = uint160(Hooks.AFTER_ADD_LIQUIDITY_FLAG);
    uint160 internal constant BR = uint160(Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG);
    uint160 internal constant BS = uint160(Hooks.BEFORE_SWAP_FLAG);
    uint160 internal constant AS = uint160(Hooks.AFTER_SWAP_FLAG);
    uint160 internal constant BSRD = uint160(Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);

    uint160 internal tagCounter = 1;

    function setUp() public {
        _baseSetUp();
    }

    /// @dev `code` at an address with the given permission bits; `mode` != max: VBase.init(manager, mode)
    function _at(uint160 flags, bytes memory code, uint256 mode) internal returns (address a) {
        a = address((uint160(0xA0D1) << 144) | (tagCounter++ << 16) | flags);
        vm.etch(a, code);
        if (mode != type(uint256).max) VBase(a).init(manager, mode);
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
    // H-2: a revert on BOTH pools is not "fine"
    // =============================================================================================

    function _freezerConfig(bytes memory code, uint160 flags) internal returns (CheckConfig memory cfg) {
        MockERC20 a = new MockERC20("A", "A", 18);
        FreezableToken f = new FreezableToken();
        require(address(a) < address(f), "token order");
        address hook = _at(flags, code, 0);
        f.setUp_(hook, address(manager));
        cfg.manager = manager;
        cfg.hook = hook;
        cfg.hasKey = true;
        cfg.key = PoolKey(Currency.wrap(address(a)), Currency.wrap(address(f)), 3000, 60, IHooks(hook));
    }

    /// @dev fixed. The hook freezes the pool's token1 during the warm-up swaps: from then on nothing
    ///      leaves the PoolManager, on the hooked pool and on the control pool (same token) alike.
    ///      Before the fix: d = PASS "all 28 withdrawal steps went through", e = PASS.
    function test_H2_freezerHook_bothPoolsRevert_isNotPass() public {
        Report memory rep = runChecks(_freezerConfig(type(FreezerHook).runtimeCode, AS));
        _assertStatus(rep, D_REMOVE, Status.UNKNOWN);
        assertTrue(_contains(_summary(rep, D_REMOVE), "withdrawals REVERT here"), "says that withdrawals revert");
        assertTrue(_contains(_summary(rep, D_REMOVE), "not cleared"), "says the hook is not cleared");
        assertTrue(_contains(_summary(rep, D_REMOVE), " reverted on both the hooked and the hook-less control pool"), "counts them");
        // 28 withdrawal steps in the 7 scenarios that could be set up, and LP B's full withdrawal that sets
        // up "single LP left" / "all liquidity removed" (counted since the re-audit, N-1): none succeeds
        assertTrue(
            _contains(_summary(rep, D_REMOVE), "0 of 30 succeeded on the hooked pool, 0 reverted because of the hook, 30 reverted on both the hooked and the hook-less control pool"),
            _summary(rep, D_REMOVE)
        );
        assertTrue(_contains(_summary(rep, D_REMOVE), ", 0 reverted because of the hook"), "no attribution either");
        assertFalse(_contains(_summary(rep, D_REMOVE), "went through"), "the old claim is gone");
        assertTrue(_mentions(rep, D_REMOVE, "reverts (also without hook)"), "per-step lines");
        assertTrue(rep.findings[E_SWAP].status != Status.PASS, "e: swaps that pay out token1 revert too");
        assertTrue(_contains(_summary(rep, E_SWAP), "reverted on both the hooked and the hook-less control pool"), "e counts them");
    }

    /// @dev fixed, and the mutation "a control-pool revert masks a revert that came out of the hook":
    ///      the same freeze, plus a withdrawal block in the hook's own callback. The control pool reverts
    ///      as well, but the revert on the hooked pool is a WrappedError from the hook: d must be FAIL.
    function test_H2_hookRevertIsAttributedEvenWhenControlRevertsToo() public {
        Report memory rep = runChecks(_freezerConfig(type(FreezeAndBlockHook).runtimeCode, AS | BR));
        _assertStatus(rep, D_REMOVE, Status.FAIL);
        assertTrue(_mentions(rep, D_REMOVE, "beforeRemoveLiquidity"), "names the callback");
        assertFalse(_contains(_summary(rep, D_REMOVE), ", 0 reverted because of the hook"), "attributed");
    }

    /// @dev fixed (summary honesty). A hook that refuses large swaps by design: the three scenarios that
    ///      need a large swap to move the price cannot be set up. Before the fix the d summary still read
    ///      "all 27 withdrawal steps went through (... time, price, gas-price perturbations)".
    ///      Status: PASS after the first audit, UNKNOWN since the re-audit.
    function test_H2_maxSwapHook_untestedScenariosAreNamed() public {
        Report memory rep = _quiet(_at(BS, type(MaxSwapHook).runtimeCode, 0));
        string memory d = _summary(rep, D_REMOVE);
        // every step that RAN succeeded and the hook has no liquidity callback - but three scenarios did
        // not run, and since the re-audit (N-1) that is UNKNOWN, not PASS: which scenarios can be set up
        // is in the hands of the hook (README, 误报)
        _assertStatus(rep, D_REMOVE, Status.UNKNOWN);
        assertTrue(_contains(d, "3 scenario(s) could NOT BE TESTED"), "says so first");
        assertTrue(_contains(d, "27 of 27 succeeded on the hooked pool"), "what ran");
        assertTrue(_contains(d, "scenarios run: 7, NOT TESTED: 3 ("), "how many scenarios did not run");
        assertTrue(_contains(d, "price pushed below the LP range; price pushed above the LP range; price pushed below the LP range, then +15 seconds"), "which");
        assertTrue(_contains(d, "are not covered by this result"), "and what that means");
        assertFalse(_contains(d, "price, gas-price perturbations"), "no blanket coverage claim");
        _assertStatus(rep, E_SWAP, Status.UNKNOWN); // explicit refusals: by design or stuck, the tool cannot tell
        assertTrue(_contains(_summary(rep, E_SWAP), "NOT TESTED: 3 ("), "e names them too");
    }

    /// @dev the PASS summaries of d and e state the counts and claim nothing beyond them
    function test_H2_passSummariesCarryCounts() public {
        Report memory rep = _quiet(_at(BS, type(FeeVariantsHook).runtimeCode, 4)); // constant 50% fee: correct, unusual
        _assertStatus(rep, D_REMOVE, Status.PASS);
        _assertStatus(rep, E_SWAP, Status.PASS);
        assertTrue(_contains(_summary(rep, D_REMOVE), "39 of 39 succeeded on the hooked pool, 0 reverted because of the hook, 0 reverted on both"), "d");
        assertTrue(_contains(_summary(rep, D_REMOVE), "scenarios run: 10, NOT TESTED: 0"), "d scenarios");
        assertTrue(_contains(_summary(rep, E_SWAP), "50 of 50 succeeded on the hooked pool, 0 reverted because of the hook, 0 reverted on both"), "e");
        assertTrue(_contains(_summary(rep, E_SWAP), "scenarios run: 11, NOT TESTED: 0"), "e scenarios");
        _assertStatus(rep, F_DYNAMIC_FEE, Status.PASS);
    }

    // =============================================================================================
    // H-1 (item 3): a failure of the checker's own tooling is a probe failure, never "also without hook"
    // =============================================================================================

    /// @dev fixed. In local simulation a hook can reach cheatcodes; this one wipes the code of the
    ///      checker's swap router. Every later swap fails on both pools because the ROUTER is gone.
    ///      Before the fix that was "the rest revert the same way without a hook" -> e = PASS.
    ///      (d and c of the same run: test_N2_routerWiper_stillProbeFailure_andDNotPass.)
    function test_H1_toolingFailure_isProbeFailureNotControlRevert() public {
        Report memory rep = _quiet(_at(BS, type(RouterWiperHook).runtimeCode, 0));
        _assertStatus(rep, E_SWAP, Status.UNKNOWN);
        assertTrue(_contains(_summary(rep, E_SWAP), "PROBE FAILURE"), "named as a tooling failure");
        assertTrue(_contains(_summary(rep, E_SWAP), ", 0 reverted on both the hooked and the hook-less control pool"), "not booked as a control-pool revert");
        assertTrue(_mentions(rep, E_SWAP, "one of the checker's own routers has no code"), "says what broke");
        assertTrue(rep.findings[F_DYNAMIC_FEE].status != Status.PASS, "nothing downstream passes on it");
    }

    /// @dev runChecks is not re-entrant, and the guard is not cleared by the rollbacks inside a run
    function test_H1_runChecksIsNotReentrant() public {
        Report memory rep = _quiet(_at(BS, type(ReenterRunChecksHook).runtimeCode, type(uint256).max));
        assertFalse(rep.voided, "a rejected nested call does not void the run");
        assertEq(bytes4(keccak256("CheckerBusy()")), CheckerBusy.selector, "the selector the hook compares against");
        // the hook reverts its swap callback unless the nested runChecks reverted with CheckerBusy: every
        // swap went through, so every nested call was refused
        _assertStatus(rep, E_SWAP, Status.PASS);
    }

    // =============================================================================================
    // M-1: check c looks at liquidity operations too
    // =============================================================================================

    /// @dev fixed. A stranger's pool trips a global switch that blocks withdrawals in every pool; swaps
    ///      never read it. Before the fix: a..h all PASS.
    function test_M1_globalHalt_strangerPoolBlocksWithdrawals() public {
        Report memory rep = _quiet(_at(AI | BR, type(GlobalHaltHook).runtimeCode, 0));
        _assertStatus(rep, C_FOREIGN_POOL, Status.FAIL);
        assertTrue(_mentions(rep, C_FOREIGN_POOL, "reference fee collection by LP A (liquidityDelta 0) DIFFERS"), "fee collection");
        assertTrue(_mentions(rep, C_FOREIGN_POOL, "reference partial withdrawal by LP A DIFFERS"), "withdrawal");
        assertTrue(_mentions(rep, C_FOREIGN_POOL, "->  revert"), "it now reverts");
        assertTrue(_contains(_summary(rep, C_FOREIGN_POOL), "of 9 reference operations"), "summary counts operations, not swaps");
        // d on its own cannot see it (its scenarios never create a stranger pool) - that is what c is for
        _assertStatus(rep, D_REMOVE, Status.PASS);
    }

    /// @dev the slots a withdrawal touches count as "used by the pool under test" (mutation: c = UNKNOWN)
    function test_M1_sharedSlotWithoutBehaviourChange_isUnknown() public {
        Report memory rep = _quiet(_at(BS, type(GlobalCounterHook).runtimeCode, 0));
        _assertStatus(rep, C_FOREIGN_POOL, Status.UNKNOWN);
        assertTrue(_mentions(rep, C_FOREIGN_POOL, "changed by the stranger pool AND used by the reference pool"), "names the slot");
        assertTrue(_contains(_summary(rep, C_FOREIGN_POOL), "without a difference in the 9 reference operations"), "summary");
    }

    // =============================================================================================
    // M-2: caller checks with a bypass
    // =============================================================================================

    /// @dev fixed: `msg.sender == pm || hookData.length == 1` is found by the 1-byte hookData probe.
    ///      Before the fix: b = PASS.
    function test_M2_bypassOnHookDataLength_detected() public {
        Report memory rep = _quiet(_at(BS, type(WeakCallerHook).runtimeCode, 3));
        _assertStatus(rep, B_CALLER, Status.FAIL);
        assertTrue(_mentions(rep, B_CALLER, "beforeSwap: ACCEPTED from a non-PoolManager address AND CHANGED STATE"), "callback");
        assertTrue(_mentions(rep, B_CALLER, "1-byte hookData"), "says which input opened it");
    }

    /// @dev PINNED false negatives (README, 漏报): a bypass keyed on a value the probes do not contain.
    ///      mode 1: `|| sender == TRUSTED_ROUTER` (sender is an argument); mode 2: `|| tx.origin == KEEPER`.
    ///      b is PASS for both; what changed with the fix is that the summary no longer claims more than
    ///      "rejected under these N inputs".
    function test_M2_bypassOnUnknownValue_stillPass_pinned() public {
        for (uint256 m = 1; m <= 2; m++) {
            Report memory rep = _quiet(_at(BS, type(WeakCallerHook).runtimeCode, m));
            _assertStatus(rep, B_CALLER, Status.PASS);
            string memory s = _summary(rep, B_CALLER);
            assertTrue(_contains(s, "under these 200 probe inputs"), "scoped to the inputs tried");
            assertTrue(_contains(s, "is not ruled out"), "says what is not shown");
            assertFalse(_contains(s, "all 10 callbacks revert for a non-PoolManager caller"), "the old blanket sentence is gone");
            assertTrue(_mentions(rep, B_CALLER, "hookData empty and 1, 4, 20, 32, 64 bytes"), "lists the inputs");
        }
    }

    /// @dev unchanged behaviour, pinned: no caller check, effect only for one tx.origin / only in transient
    ///      storage -> accepted without visible effect -> UNKNOWN (not PASS)
    function test_M2_acceptedWithoutVisibleEffect_isUnknown() public {
        for (uint256 m = 4; m <= 5; m++) {
            Report memory rep = _quiet(_at(BS, type(WeakCallerHook).runtimeCode, m));
            _assertStatus(rep, B_CALLER, Status.UNKNOWN);
        }
    }

    /// @dev mutation "b never probes inside an unlock": the missing caller check only shows there
    function test_M2_missingCheckVisibleOnlyInsideUnlock_detected() public {
        Report memory rep = _quiet(_at(BS, type(UnlockOnlyHook).runtimeCode, 0));
        _assertStatus(rep, B_CALLER, Status.FAIL);
        assertTrue(_mentions(rep, B_CALLER, "beforeSwap: ACCEPTED from a non-PoolManager address AND CHANGED STATE - inside an unlock"), "inside an unlock");
    }

    /// @dev mutation "an effect is only a write to the hook's own storage": an event, or a write in
    ///      another contract, made on behalf of an arbitrary caller is an effect too
    function test_M2_effectOutsideTheHooksOwnStorage_detected() public {
        Report memory ev = _quiet(_at(BS, type(SideEffectHook).runtimeCode, 1));
        _assertStatus(ev, B_CALLER, Status.FAIL);
        assertTrue(_mentions(ev, B_CALLER, "0 storage slot(s) changed (0 in the hook), 1 event(s)"), "event only");

        vm.etch(address(0x1ED6E2), type(Ledger).runtimeCode); // SideEffectHook.LEDGER
        Report memory wr = _quiet(_at(BS, type(SideEffectHook).runtimeCode, 2));
        _assertStatus(wr, B_CALLER, Status.FAIL);
        assertTrue(_mentions(wr, B_CALLER, "1 storage slot(s) changed (0 in the hook), 0 event(s)"), "foreign write only");
    }

    // =============================================================================================
    // M-3: nothing is cut off the bytecode for a statement in the PASS direction
    // =============================================================================================

    /// @dev the auditor's 99 bytes: answers every call with its selector; if the last calldata word is a
    ///      magic value it jumps into code that sits inside something shaped like a Solidity CBOR trailer
    ///      and does an SSTORE
    function _trailerCode() internal pure returns (bytes memory code, bytes32 magic) {
        magic = keccak256("open sesame");
        code = abi.encodePacked(
            hex"366020900335",
            hex"7f", magic, hex"14", hex"61005a", hex"57",
            hex"600035", hex"7f", bytes32(bytes4(0xffffffff)), hex"16", hex"600052", hex"60206000f3",
            hex"a2", hex"5b", hex"6001600055", hex"00", hex"0008"
        );
    }

    /// @dev fixed. Before: b = PASS "bytecode contains no state-changing opcode at all: harmless" (89 of
    ///      99 bytes swept), while a call with the magic word writes slot 0.
    function test_M3_sstoreInsideFakeMetadataTrailer_notPass() public {
        (bytes memory code, bytes32 magic) = _trailerCode();
        assertEq(code.length, 99);
        assertTrue(BytecodeScan.scan(code).sstore, "the full sweep sees the SSTORE");
        assertEq(BytecodeScan.scan(code).scannedLength, 99, "every byte swept");
        assertFalse(BytecodeScan.scanCodePart(code).sstore, "the trailer-cut sweep (hint wording only) does not");
        assertEq(BytecodeScan.trailerLength(code), 10);

        address hook = _at(BI, code, type(uint256).max);
        Report memory rep = _quiet(hook);
        _assertStatus(rep, B_CALLER, Status.UNKNOWN);
        assertFalse(_contains(_summary(rep, B_CALLER), "harmless"), "no such word any more");
        assertFalse(_contains(_summary(rep, B_CALLER), "cannot write state"), "and not the conditional claim either: SSTORE is in the code");

        // the toy really does write for a stranger (local toy; shows the PASS would have been wrong)
        vm.prank(address(0xBAD));
        (bool ok,) = hook.call(abi.encodePacked(IHooks.beforeDonate.selector, magic));
        assertTrue(ok);
        assertEq(uint256(vm.load(hook, 0)), 1, "slot 0 written by an arbitrary caller");
    }

    /// @dev the same trick for g: a DELEGATECALL byte that occurs only inside trailer-shaped bytes still
    ///      counts as a sign (before: cut off, g could say PASS)
    function test_M3_delegatecallInsideFakeMetadataTrailer_listedInG() public {
        // PUSH1 0 CALLDATALOAD PUSH1 0 MSTORE PUSH1 0x20 PUSH1 0 RETURN | a1 5b f4 00 | 0004
        bytes memory code = hex"60003560005260206000f3a15bf4000004";
        assertFalse(BytecodeScan.scanCodePart(code).delegatecall);
        assertTrue(BytecodeScan.scan(code).delegatecall);
        Report memory rep = _quiet(_at(BI, code, type(uint256).max));
        _assertStatus(rep, G_UPGRADE, Status.UNKNOWN);
        assertTrue(_mentions(rep, G_UPGRADE, "DELEGATECALL opcode occurs in the bytecode"), "listed");
        assertTrue(_mentions(rep, G_UPGRADE, "seen ONLY inside the last bytes that are shaped like a Solidity metadata trailer"), "and says where");
    }

    /// @dev the PASS path that is left: hand-written code in which a FULL sweep finds no such opcode
    function test_M3_statelessHandWrittenCode_passWithConditionalWording() public {
        // answers every call with its selector as one word; no trailer, no state-changing opcode
        bytes memory code = hex"6000357fffffffff000000000000000000000000000000000000000000000000000000001660005260206000f3";
        assertTrue(BytecodeScan.cannotChangeState(BytecodeScan.scan(code)));
        Report memory rep = _quiet(_at(BI, code, type(uint256).max));
        _assertStatus(rep, B_CALLER, Status.PASS);
        assertTrue(_contains(_summary(rep, B_CALLER), "a full sweep of the bytecode (45 bytes, nothing cut off)"), "what the claim rests on");
        assertFalse(_contains(_summary(rep, B_CALLER), "harmless"));
    }

    // =============================================================================================
    // M-4: the PoolManager never comes from the hook under test
    // =============================================================================================

    function test_M4_unknownChainNeedsExplicitPoolManager() public {
        CheckHook entry = new CheckHook();
        vm.expectRevert(abi.encodeWithSelector(CheckHook.PoolManagerRequired.selector, uint256(1)));
        entry.resolveManager(1, address(0));
        vm.expectRevert(abi.encodeWithSelector(CheckHook.PoolManagerRequired.selector, uint256(31337)));
        entry.resolveManager(31337, address(0));
        assertEq(entry.resolveManager(31337, address(0xABCD)), address(0xABCD), "the operator's choice is used as given");
        assertEq(entry.resolveManager(8453, address(0)), 0x498581fF718922c3f8e6A244956aF099B2652b2b, "Base");
        assertEq(entry.resolveManager(84532, address(0)), 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408, "Base Sepolia");
        assertEq(entry.resolveManager(8453, address(0xABCD)), address(0xABCD), "explicit wins on known chains too");
    }

    // =============================================================================================
    // L-1 .. L-6
    // =============================================================================================

    /// @dev L-1 fixed: a revert string shaped like report content does not reach the report as markdown
    function test_L1_markdownInRevertStringIsNeutralised() public {
        Report memory rep = _quiet(_at(BS, type(MarkdownInjectionHook).runtimeCode, type(uint256).max));
        bytes memory text = bytes(renderReport(rep));
        assertTrue(_contains(string(text), "audited, safe"), "the (sanitised) text is still shown");
        // (revert strings are cut to 96 bytes before they are sanitised)
        assertTrue(_mentions(rep, E_SWAP, "Error(`ok? ?PASS - audited, safe??https://example.invalid/x? ??i??https://example.invalid/p.png? ??PASS`)"), rep.findings[E_SWAP].details[0]);
        assertFalse(_contains(string(text), "]("), "no link syntax");
        assertFalse(_contains(string(text), "!["), "no image syntax");
        assertFalse(_contains(string(text), "**"), "no bold");
        // every backtick in the report is the checker's own: they come in pairs on each line
        uint256 ticks;
        for (uint256 i; i < text.length; i++) {
            if (text[i] == "`") ticks++;
            if (text[i] == 0x0a) {
                assertEq(ticks % 2, 0, "balanced code spans on every line");
                ticks = 0;
            }
        }
    }

    /// @dev L-2 fixed: a fee hook that forgot OVERRIDE_FEE_FLAG trades at 0 forever. Before: f = PASS
    ///      "fees within [0, 100%] (0..0 pips)".
    function test_L2_forgottenOverrideFlag_feeZeroIsUnknown() public {
        Report memory rep = _quiet(_at(BS, type(FeeVariantsHook).runtimeCode, 3));
        _assertStatus(rep, F_DYNAMIC_FEE, Status.UNKNOWN);
        assertTrue(_contains(_summary(rep, F_DYNAMIC_FEE), "paid a fee of 0"));
        assertTrue(_contains(_summary(rep, F_DYNAMIC_FEE), "OVERRIDE_FEE_FLAG"));
    }

    /// @dev L-3 fixed: when the checker cannot create a pool of its own, a rejected stranger pool says
    ///      nothing. Before: c = PASS.
    function test_L3_strangerRejectedLikeTheCheckerItself_isUnknown() public {
        Report memory rep = _quiet(_at(BI | BS, type(RejectAllPoolsHook).runtimeCode, type(uint256).max));
        assertTrue(_contains(rep.setup[rep.setup.length - 1], "NO TEST POOL"), "the checker's own pool was refused");
        _assertStatus(rep, C_FOREIGN_POOL, Status.UNKNOWN);
        assertTrue(_contains(_summary(rep, C_FOREIGN_POOL), "but so was every pool the checker itself tried to create"));
    }

    /// @dev L-3: a hook that accepts exactly one pool (the first) rejects the stranger while the pool under
    ///      test exists: that is a rejection that means something -> PASS, and the note shows both tries
    function test_L3_strangerRejectedWhileTestPoolExists_isPass() public {
        Report memory rep = _quiet(_at(BI | BS, type(FirstPoolOnlyHook).runtimeCode, type(uint256).max));
        _assertStatus(rep, C_FOREIGN_POOL, Status.PASS);
        assertTrue(_contains(_summary(rep, C_FOREIGN_POOL), "while the pool under test exists on the same hook"));
        assertTrue(_mentions(rep, C_FOREIGN_POOL, "own two tokens: "), "first stranger pool");
        assertTrue(_mentions(rep, C_FOREIGN_POOL, "sharing currency0 of the pool under test"), "second stranger pool");
    }

    /// @dev L-3: the stranger pool that shares a currency with the pool under test reaches state a hook
    ///      keeps per CURRENCY. Before (stranger pools never shared a token): c = PASS.
    function test_L3_perCurrencyState_reachedBySharedCurrencyPool() public {
        Report memory rep = _quiet(_at(BS, type(PerCurrencyVolumeHook).runtimeCode, 0));
        _assertStatus(rep, C_FOREIGN_POOL, Status.FAIL);
        assertTrue(_mentions(rep, C_FOREIGN_POOL, "sharing currency0 of the pool under test, other token its own: fee DYNAMIC spacing 60: ACCEPTED"));
        assertTrue(_mentions(rep, C_FOREIGN_POOL, "DIFFERS after the stranger pool's activity"));
    }

    /// @dev L-6 fixed: more distinct hook slots than the checker tracks. Before (256, dropped silently):
    ///      the shared slot fell off the list and c = PASS.
    function test_L6_moreSlotsThanTracked_isUnknownNotPass() public {
        Report memory rep = _quiet(_at(AI | BS, type(ManySlotsHook).runtimeCode, 0));
        _assertStatus(rep, C_FOREIGN_POOL, Status.UNKNOWN);
        assertTrue(_contains(_summary(rep, C_FOREIGN_POOL), "more than 1024 distinct storage slots"), "says why");
        assertTrue(_mentions(rep, C_FOREIGN_POOL, "INCOMPLETE"), "detail line");
    }

    // =============================================================================================
    // Sizes at both ends, claims, both directions (mutations and L-5 items that are now detected)
    // =============================================================================================

    /// @dev mutation "no 1-wei swaps": a hook that only breaks on dust
    function test_dustSwapPanics_detected() public {
        Report memory rep = _quiet(_at(BS, type(DustPanicHook).runtimeCode, 0));
        _assertStatus(rep, E_SWAP, Status.FAIL);
        assertTrue(_mentions(rep, E_SWAP, "amount -1: REVERT"), "the 1-wei swap");
        assertTrue(_mentions(rep, E_SWAP, "Panic(0x12 division by zero)"), "reason");
        assertTrue(_contains(_summary(rep, E_SWAP), "2 swap(s) reverted unexpectedly"), "only the two 1-wei swaps");
    }

    /// @dev was a false negative in the audit (e1): exactOut above 100e18 panics. The baseline now has
    ///      100x exactOut swaps in both directions.
    function test_largeExactOutPanics_detected() public {
        Report memory rep = _quiet(_at(BR | BS, type(OutsidePerturbationHook).runtimeCode, 4));
        _assertStatus(rep, E_SWAP, Status.FAIL);
        assertTrue(_mentions(rep, E_SWAP, "100x 0->1 exactOut REVERT"), "which swap");
    }

    /// @dev was a false negative in the audit (f2): a fee above 100% for large exactOut swaps only
    function test_feeAbove100PercentOnLargeExactOut_detected() public {
        Report memory rep = _quiet(_at(BS, type(FeeVariantsHook).runtimeCode, 2));
        _assertStatus(rep, F_DYNAMIC_FEE, Status.FAIL);
        assertTrue(_contains(_summary(rep, F_DYNAMIC_FEE), "above 100%"));
    }

    /// @dev was a false negative in the audit (f1): a spot-price fee applied to 1->0 swaps only. The
    ///      same-block test now runs in both directions.
    function test_spotFeeOnOneDirectionOnly_hinted() public {
        Report memory rep = _quiet(_at(BS, type(FeeVariantsHook).runtimeCode, 1));
        _assertStatus(rep, F_DYNAMIC_FEE, Status.UNKNOWN);
        assertTrue(_contains(_summary(rep, F_DYNAMIC_FEE), "changes within one block"));
        assertTrue(_mentions(rep, F_DYNAMIC_FEE, "identical tiny 1->0 swaps pay fee"), "the direction that shows it");
    }

    /// @dev mutation "the same-block test ignores the swap after the large opposite swap": a surcharge
    ///      that only the swap AFTER a large one pays. The first two identical swaps pay the same.
    function test_sameBlockFeeMovedByALargeSwap_hinted() public {
        Report memory rep = _quiet(_at(BS, type(SameBlockSurchargeHook).runtimeCode, 0));
        _assertStatus(rep, F_DYNAMIC_FEE, Status.UNKNOWN);
        assertTrue(_contains(_summary(rep, F_DYNAMIC_FEE), "changes within one block"));
        assertTrue(_mentions(rep, F_DYNAMIC_FEE, "identical tiny 0->1 swaps pay fee 3000 -> 3000 -> (after a large 1->0 swap at fee 3000) -> 10000"), "0->1");
        assertTrue(_mentions(rep, F_DYNAMIC_FEE, "identical tiny 1->0 swaps pay fee 3000 -> 3000 -> (after a large 0->1 swap at fee 3000) -> 10000"), "1->0");
    }

    /// @dev mutation "h ignores ERC-6909 claims": a hook that keeps its fees as claims
    function test_claimsHeldByTheHook_reported() public {
        Report memory rep = _quiet(_at(BS | BSRD, type(SpecifiedFeeHook).runtimeCode, 0));
        _assertStatus(rep, H_BALANCES, Status.UNKNOWN);
        assertTrue(_mentions(rep, H_BALANCES, "currency0 ERC-6909 claims: 0 before the checker's operations, "), "claims line");
        assertFalse(_mentions(rep, H_BALANCES, "currency0 ERC-6909 claims: 0 before the checker's operations, 0 after"), "non-zero after");
        assertTrue(_mentions(rep, H_BALANCES, "currency0 balance: 0 before the checker's operations, 0 after"), "no ERC-20 balance: claims are the only holding");
        _assertStatus(rep, I_RETURN_DELTA, Status.PASS);
        assertTrue(_contains(_summary(rep, I_RETURN_DELTA), "uniform 1001 ppm"));
    }

    // =============================================================================================
    // PINNED false negatives and false positives (README tables). These assert what the tool says today.
    // =============================================================================================

    /// @dev c: pollution that only shows later than the reference flow looks (README 漏报)
    function test_pinned_c_delayedPollution_notDetected() public {
        for (uint256 m = 1; m <= 3; m++) {
            // 1: global read after 40 own swaps; 2: global read after 2 days; 3: mapping keyed by one byte of the PoolId
            Report memory rep = _quiet(_at(BS, type(DelayedPollutionHook).runtimeCode, m));
            _assertStatus(rep, C_FOREIGN_POOL, Status.PASS);
        }
    }

    /// @dev d: blocks that sit outside the 11 perturbations (README 漏报)
    function test_pinned_d_blocksOutsideThePerturbations_notDetected() public {
        for (uint256 m = 1; m <= 3; m++) {
            // 1: the 9th withdrawal panics; 2: blocked beyond a 4x price move; 3: blocked between 2 and 300 idle days
            Report memory rep = _quiet(_at(BR | BS, type(OutsidePerturbationHook).runtimeCode, m));
            _assertStatus(rep, D_REMOVE, Status.PASS);
            _assertStatus(rep, E_SWAP, Status.PASS);
        }
    }

    /// @dev d: a hook that recognises the checker and behaves (README 漏报: tx.origin; the router's owner())
    function test_pinned_d_hookThatRecognisesTheChecker_notDetected() public {
        for (uint256 m = 1; m <= 2; m++) {
            Report memory rep = _quiet(_at(BR, type(EvasiveHook).runtimeCode, m));
            _assertStatus(rep, D_REMOVE, Status.PASS);
            // the whole row, as the README states it (f: not a fee hook, see L-2)
            assertEq(_oneLine(rep), "a=PASS b=PASS c=PASS d=PASS e=PASS f=UNKNOWN g=PASS h=PASS i=N/A ");
        }
    }

    /// @dev a: a missing permission bit is invisible unless getHookPermissions() is exposed - for ANY bit,
    ///      not only return-delta bits (README 漏报). With it exposed, the mismatch is a FAIL.
    function test_pinned_a_missingBit_onlyVisibleThroughGetHookPermissions() public {
        // address has BEFORE_SWAP only; the contract implements afterSwap as well
        Report memory hidden = _quiet(_at(BS, type(PermVariantsHook).runtimeCode, 1 << 15));
        _assertStatus(hidden, A_PERMISSIONS, Status.PASS);
        assertTrue(_mentions(hidden, A_PERMISSIONS, "getHookPermissions(): not exposed"));
        Report memory exposed = _quiet(_at(BS, type(PermVariantsHook).runtimeCode, BS | AS));
        _assertStatus(exposed, A_PERMISSIONS, Status.FAIL);
        assertTrue(_mentions(exposed, A_PERMISSIONS, "getHookPermissions() MISMATCH"));
    }

    /// @dev false positive, pinned (README 误报): a lock with a hard 7-day cap is reported under d. The
    ///      +400 days scenario and fee collection go through.
    function test_pinned_falsePositive_timeLock() public {
        Report memory rep = _quiet(_at(AA | BR, type(TimeLockHook).runtimeCode, 0));
        _assertStatus(rep, D_REMOVE, Status.FAIL);
        assertTrue(_mentions(rep, D_REMOVE, "time +400 days: | fees-only ok | half ok | rest ok | last-LP ok"), "after the lock everything works");
        assertTrue(_mentions(rep, D_REMOVE, "baseline (one minute after the warm-up swaps): | fees-only ok | half REVERT"), "inside the lock");
    }
}

/// @dev Flags: BEFORE_INITIALIZE | BEFORE_SWAP. Refuses every pool.
contract RejectAllPoolsHook {
    error NoPools();

    fallback() external {
        if (msg.sig == IHooks.beforeInitialize.selector) revert NoPools();
        assembly {
            mstore(0, and(calldataload(0), 0xffffffff00000000000000000000000000000000000000000000000000000000))
            return(0, 0x60)
        }
    }
}

/// @dev Flags: BEFORE_INITIALIZE | BEFORE_SWAP. Serves the first pool that is initialized and no other.
contract FirstPoolOnlyHook {
    bool public taken;

    error OnePoolOnly();

    fallback() external {
        if (msg.sig == IHooks.beforeInitialize.selector) {
            if (taken) revert OnePoolOnly();
            taken = true;
            assembly {
                mstore(0, and(calldataload(0), 0xffffffff00000000000000000000000000000000000000000000000000000000))
                return(0, 0x20)
            }
        }
        assembly {
            mstore(0, and(calldataload(0), 0xffffffff00000000000000000000000000000000000000000000000000000000))
            mstore(0x20, 0)
            mstore(0x40, 0)
            return(0, 0x60)
        }
    }
}

/// @dev DELIBERATELY FLAWED toy. Flags: BEFORE_SWAP. S3's volume tier, but the volume is booked per
///      CURRENCY (currency0 of the pool) instead of per pool: any pool that shares the currency moves the
///      tier of all of them. A stranger pool with two tokens of its own never touches it.
contract PerCurrencyVolumeHook is VBase {
    mapping(Currency => uint256) public volume; // BUG: keyed by currency, shared across pools

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _only();
        uint256 size = params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint24 fee = volume[key.currency0] >= 1e24 ? 500 : 3000;
        volume[key.currency0] += size;
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }
}

interface IChecker {
    function runChecks(CheckConfig calldata cfg) external returns (Report memory);
}

/// @dev Flags: BEFORE_SWAP. Calls back into the checker's runChecks from inside every swap callback and
///      lets the swap through only if that nested call reverted with CheckerBusy. The checker's router
///      (the `sender` argument) tells it where the checker is.
contract ReenterRunChecksHook {
    bytes4 public constant NESTED_REVERT_SELECTOR = bytes4(keccak256("CheckerBusy()"));

    error NestedCallNotRefused();

    fallback() external {
        if (msg.sig == IHooks.beforeSwap.selector) {
            address sender;
            assembly {
                sender := calldataload(4)
            }
            address checker = IRouterOwner(sender).owner();
            CheckConfig memory cfg;
            cfg.hook = address(this);
            (bool ok, bytes memory ret) = checker.call(abi.encodeCall(IChecker.runChecks, (cfg)));
            if (ok || ret.length != 4 || bytes4(ret) != NESTED_REVERT_SELECTOR) revert NestedCallNotRefused();
        }
        assembly {
            mstore(0, and(calldataload(0), 0xffffffff00000000000000000000000000000000000000000000000000000000))
            mstore(0x20, 0)
            mstore(0x40, 0)
            return(0, 0x60)
        }
    }
}
