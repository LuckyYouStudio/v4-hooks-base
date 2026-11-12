// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Vm} from "forge-std/Vm.sol";

import {PriorityFeeHook} from "../src/PriorityFeeHook.sol";
import {BaseHook} from "../src/base/BaseHook.sol";
import {PriorityFeeTestBase} from "./utils/PriorityFeeTestBase.sol";

contract PriorityFeeHookTest is PriorityFeeTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function setUp() public {
        _baseSetUp();
    }

    // ---------------------------------------------------------------------------------------------
    // Permissions / deployment
    // ---------------------------------------------------------------------------------------------

    function test_permissions_matchAddressAndImplementation() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.afterInitialize);
        assertTrue(p.beforeSwap);
        assertFalse(p.beforeInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.afterSwap);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.beforeSwapReturnDelta);
        assertFalse(p.afterSwapReturnDelta);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
        // all 14 bits of the mined address
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, 0x1080);
        Hooks.validateHookPermissions(IHooks(address(hook)), p);
        assertEq(address(hook.poolManager()), address(manager));
    }

    function test_constructor_revertsAtAddressWithWrongBits() public {
        // an address that carries one extra permission bit (afterSwap)
        address wrong = address(uint160(0x4444000000000000000000000000000000000000) | 0x1080 | 0x40);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, wrong));
        deployCodeTo("PriorityFeeHook.sol:PriorityFeeHook", abi.encode(manager), wrong);
        // and one with a bit missing (no beforeSwap)
        wrong = address(uint160(0x4444000000000000000000000000000000000000) | 0x1000);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, wrong));
        deployCodeTo("PriorityFeeHook.sol:PriorityFeeHook", abi.encode(manager), wrong);
    }

    function test_constructor_revertsWithoutPoolManagerCode() public {
        vm.expectRevert(BaseHook.PoolManagerHasNoCode.selector);
        new PriorityFeeHook(IPoolManager(address(0)));
        vm.expectRevert(BaseHook.PoolManagerHasNoCode.selector);
        new PriorityFeeHook(IPoolManager(makeAddr("eoa")));
    }

    function test_constants_exposed() public view {
        assertEq(hook.MIN_FEE(), 500);
        assertEq(hook.MAX_FEE(), 3000);
        assertEq(hook.TIP_ALLOWANCE(), 20_000_000);
        assertEq(hook.WEI_PER_PIP(), 400_000);
    }

    // ---------------------------------------------------------------------------------------------
    // afterInitialize
    // ---------------------------------------------------------------------------------------------

    function test_afterInitialize_registersAndSetsStoredFee() public {
        (Currency a, Currency b) = deployMintAndApprove2Currencies();
        PoolKey memory k = PoolKey(a, b, LPFeeLibrary.DYNAMIC_FEE_FLAG, SPACING, IHooks(address(hook)));
        assertFalse(hook.isRegistered(k.toId()));
        vm.expectEmit(true, false, false, false, address(hook));
        emit PriorityFeeHook.PoolRegistered(k.toId());
        manager.initialize(k, SQRT_PRICE_1_1);
        assertTrue(hook.isRegistered(k.toId()));
        // slot0 advertises the floor, not the 0 a dynamic-fee pool starts with
        assertEq(_storedLpFee(k), 500);
    }

    function test_afterInitialize_rejectsStaticFeePool() public {
        PoolKey memory k = PoolKey(currency0, currency1, 3000, SPACING, IHooks(address(hook)));
        vm.expectRevert(_wrapped(IHooks.afterInitialize.selector, PriorityFeeHook.NotDynamicFee.selector));
        manager.initialize(k, SQRT_PRICE_1_1);
        assertFalse(hook.isRegistered(k.toId()));
        // a static fee of 0 is not the dynamic flag either
        k.fee = 0;
        vm.expectRevert(_wrapped(IHooks.afterInitialize.selector, PriorityFeeHook.NotDynamicFee.selector));
        manager.initialize(k, SQRT_PRICE_1_1);
    }

    function test_afterInitialize_anySpacingAndPrice() public {
        PoolKey memory k = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 1, IHooks(address(hook)));
        manager.initialize(k, TickMath.MIN_SQRT_PRICE);
        assertTrue(hook.isRegistered(k.toId()));
        k.tickSpacing = TickMath.MAX_TICK_SPACING;
        manager.initialize(k, TickMath.MAX_SQRT_PRICE - 1);
        assertTrue(hook.isRegistered(k.toId()));
    }

    // ---------------------------------------------------------------------------------------------
    // Access control
    // ---------------------------------------------------------------------------------------------

    function test_callbacks_revertForNonPoolManager() public {
        SwapParams memory sp = SwapParams(true, -1, MIN_PRICE_LIMIT);
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(-60, 60, 1, 0);
        address[3] memory callers = [address(this), makeAddr("stranger"), address(swapRouter)];
        for (uint256 i; i < callers.length; i++) {
            vm.startPrank(callers[i]);
            vm.expectRevert(BaseHook.NotPoolManager.selector);
            hook.afterInitialize(address(this), hookKey, SQRT_PRICE_1_1, 0);
            vm.expectRevert(BaseHook.NotPoolManager.selector);
            hook.beforeSwap(address(this), hookKey, sp, "");
            vm.expectRevert(BaseHook.NotPoolManager.selector);
            hook.beforeInitialize(address(this), hookKey, SQRT_PRICE_1_1);
            vm.expectRevert(BaseHook.NotPoolManager.selector);
            hook.beforeAddLiquidity(address(this), hookKey, lp, "");
            vm.expectRevert(BaseHook.NotPoolManager.selector);
            hook.afterAddLiquidity(address(this), hookKey, lp, BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA, "");
            vm.expectRevert(BaseHook.NotPoolManager.selector);
            hook.beforeRemoveLiquidity(address(this), hookKey, lp, "");
            vm.expectRevert(BaseHook.NotPoolManager.selector);
            hook.afterRemoveLiquidity(address(this), hookKey, lp, BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA, "");
            vm.expectRevert(BaseHook.NotPoolManager.selector);
            hook.afterSwap(address(this), hookKey, sp, BalanceDeltaLibrary.ZERO_DELTA, "");
            vm.expectRevert(BaseHook.NotPoolManager.selector);
            hook.beforeDonate(address(this), hookKey, 0, 0, "");
            vm.expectRevert(BaseHook.NotPoolManager.selector);
            hook.afterDonate(address(this), hookKey, 0, 0, "");
            vm.stopPrank();
        }
    }

    /// @dev a stranger cannot register a pool by calling afterInitialize directly
    function test_afterInitialize_directCallCannotRegister() public {
        PoolKey memory k = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, IHooks(address(hook)));
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterInitialize(address(this), k, SQRT_PRICE_1_1, 0);
        assertFalse(hook.isRegistered(k.toId()));
    }

    function test_callbacksNotDeclared_revertEvenFromPoolManager() public {
        SwapParams memory sp = SwapParams(true, -1, MIN_PRICE_LIMIT);
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(-60, 60, 1, 0);
        vm.startPrank(address(manager));
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hook.beforeInitialize(address(this), hookKey, SQRT_PRICE_1_1);
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hook.beforeAddLiquidity(address(this), hookKey, lp, "");
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hook.afterAddLiquidity(address(this), hookKey, lp, BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA, "");
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hook.beforeRemoveLiquidity(address(this), hookKey, lp, "");
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hook.afterRemoveLiquidity(address(this), hookKey, lp, BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA, "");
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hook.afterSwap(address(this), hookKey, sp, BalanceDeltaLibrary.ZERO_DELTA, "");
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hook.beforeDonate(address(this), hookKey, 0, 0, "");
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hook.afterDonate(address(this), hookKey, 0, 0, "");
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------
    // Unknown pools
    // ---------------------------------------------------------------------------------------------

    /// @dev PoolManager only calls beforeSwap for pools that went through afterInitialize, so this is
    ///      defence in depth: a key the hook never registered is refused.
    function test_beforeSwap_revertsForUnregisteredPool() public {
        PoolKey memory k = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, IHooks(address(hook)));
        vm.prank(address(manager));
        vm.expectRevert(PriorityFeeHook.PoolNotRegistered.selector);
        hook.beforeSwap(address(this), k, SwapParams(true, -1, MIN_PRICE_LIMIT), "");
        // a key that differs from the registered one in any field is a different pool
        k = hookKey;
        k.hooks = IHooks(address(0));
        vm.prank(address(manager));
        vm.expectRevert(PriorityFeeHook.PoolNotRegistered.selector);
        hook.beforeSwap(address(this), k, SwapParams(true, -1, MIN_PRICE_LIMIT), "");
    }

    function test_beforeSwap_directReturnValue() public {
        _setTip(100_000_000);
        vm.prank(address(manager));
        (bytes4 sel, BeforeSwapDelta d, uint24 fee) =
            hook.beforeSwap(address(this), hookKey, SwapParams(true, -1, MIN_PRICE_LIMIT), "");
        assertEq(sel, IHooks.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(d), 0, "no return delta");
        assertEq(fee, 700 | 0x400000, "fee with the override flag");
    }

    /// @dev Anyone can create more pools with this hook. They register, and nothing they do can change
    ///      another pool's fee: the hook has no per-pool state besides the registration flag.
    function test_strangersPool_doesNotAffectOurs() public {
        (, uint24 before) = _swap(hookKey, true, -1e18);
        assertEq(before, 500);

        address stranger = makeAddr("stranger");
        (Currency a, Currency b) = deployMintAndApprove2Currencies();
        PoolKey memory k = PoolKey(a, b, LPFeeLibrary.DYNAMIC_FEE_FLAG, 1, IHooks(address(hook)));
        vm.prank(stranger);
        manager.initialize(k, TickMath.getSqrtPriceAtTick(50_000));
        _addLiquidity(k, -60, 60, 1e18, 0); // single-sided: price is far above the range
        _setTip(TIP_AT_CAP);
        (, uint24 theirs) = _swap(k, true, -1e18);
        assertEq(theirs, 3000);

        _setTip(0);
        (, uint24 afterwards) = _swap(hookKey, true, -1e18);
        assertEq(afterwards, 500, "our pool's fee depends on our transaction only");
        assertEq(_storedLpFee(hookKey), 500);
    }

    /// @dev The hook writes nothing in beforeSwap and reads exactly one slot (the registration flag).
    function test_beforeSwap_isStateless() public {
        _setTip(TIP_AT_CAP);
        vm.record();
        _swap(hookKey, true, -1e18);
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(hook));
        assertEq(writes.length, 0, "no storage writes");
        assertEq(reads.length, 1, "one read");
        assertEq(reads[0], keccak256(abi.encode(hookId, uint256(0))), "isRegistered[id]");
    }

    // ---------------------------------------------------------------------------------------------
    // beforeSwap: the fee at the priority-fee boundaries, through real swaps
    // ---------------------------------------------------------------------------------------------

    function test_fee_gasPriceBelowBaseFee_chargesFloor_noRevert() public {
        // L1-originated deposit transactions: gas price 0 under a non-zero base fee
        _setGas(0, BASEFEE);
        (, uint24 fee) = _swap(hookKey, true, -1e18);
        assertEq(fee, 500);
        // eth_call without fee fields on a Base node: (GASPRICE, BASEFEE) = (0, 0)
        _setGas(0, 0);
        (, fee) = _swap(hookKey, true, -1e18);
        assertEq(fee, 500);
        // eth_call with an explicit gasPrice below the base fee
        _setGas(1, BASEFEE);
        (, fee) = _swap(hookKey, true, -1e18);
        assertEq(fee, 500);
        _setGas(BASEFEE - 1, BASEFEE);
        (, fee) = _swap(hookKey, false, -1e18);
        assertEq(fee, 500);
        _setGas(1, type(uint64).max);
        (, fee) = _swap(hookKey, true, 1e18);
        assertEq(fee, 500);
        assertEq(hook.currentFee(), 500);
    }

    function test_fee_gasPriceEqualsBaseFee() public {
        _setGas(BASEFEE, BASEFEE);
        (, uint24 fee) = _swap(hookKey, true, -1e18);
        assertEq(fee, 500);
        _setGas(0, 0);
        (, fee) = _swap(hookKey, true, -1e18);
        assertEq(fee, 500);
    }

    function test_fee_bothSidesOfTheAllowance() public {
        uint24 fee;
        _setTip(1);
        (, fee) = _swap(hookKey, true, -1e18);
        assertEq(fee, 500);
        _setTip(20_000_000 - 1);
        (, fee) = _swap(hookKey, true, -1e18);
        assertEq(fee, 500);
        _setTip(20_000_000);
        (, fee) = _swap(hookKey, true, -1e18);
        assertEq(fee, 500, "the allowance itself is free");
        _setTip(20_000_001);
        (, fee) = _swap(hookKey, true, -1e18);
        assertEq(fee, 500, "less than one pip above");
        _setTip(20_399_999);
        (, fee) = _swap(hookKey, true, -1e18);
        assertEq(fee, 500);
        _setTip(20_400_000);
        (, fee) = _swap(hookKey, true, -1e18);
        assertEq(fee, 501, "first pip");
        assertEq(hook.currentFee(), 501);
    }

    function test_fee_reachesCapAndStaysThere() public {
        uint24 fee;
        _setTip(1_019_999_999);
        (, fee) = _swap(hookKey, true, -1e18);
        assertEq(fee, 2999);
        _setTip(1_020_000_000);
        (, fee) = _swap(hookKey, true, -1e18);
        assertEq(fee, 3000);
        _setTip(1_020_000_001);
        (, fee) = _swap(hookKey, true, -1e18);
        assertEq(fee, 3000);
        _setTip(1000 gwei);
        (, fee) = _swap(hookKey, true, -1e18);
        assertEq(fee, 3000);
    }

    /// @dev Foundry's vm.txGasPrice / vm.fee only accept values below 2^64 (18.4 gwei * 1e9), so through a
    ///      real swap the extremes are 2^64 - 1. The full uint256 range is covered on the library
    ///      (PriorityFeeMath.t.sol) and on the hook's pure view feeFor (test_views_agreeWithCharge,
    ///      testFuzz_feeForView_fullRange), which run the same two library functions.
    function test_fee_extremeValues_noOverflow() public {
        uint24 fee;
        _setGas(type(uint64).max, 0);
        (, fee) = _swap(hookKey, true, -1e18);
        assertEq(fee, 3000);
        _setGas(type(uint64).max, type(uint64).max);
        (, fee) = _swap(hookKey, false, -1e18);
        assertEq(fee, 500);
        _setGas(type(uint64).max, type(uint64).max - 20_400_000);
        (, fee) = _swap(hookKey, true, 1e18);
        assertEq(fee, 501);
        _setGas(0, type(uint64).max);
        (, fee) = _swap(hookKey, false, 1e18);
        assertEq(fee, 500);
    }

    /// @dev only the difference matters: the same tip at very different base fees gives the same fee
    function test_fee_independentOfBaseFeeLevel() public {
        uint256[4] memory baseFees = [uint256(0), 5_000_000, 33_711_616, 500 gwei];
        for (uint256 i; i < baseFees.length; i++) {
            _setGas(baseFees[i] + 100_000_000, baseFees[i]);
            (, uint24 fee) = _swap(hookKey, i % 2 == 0, -1e18);
            assertEq(fee, 700);
        }
    }

    function test_views_agreeWithCharge() public {
        assertEq(hook.feeForPriorityFee(0), 500);
        assertEq(hook.feeForPriorityFee(100_000_000), 700);
        assertEq(hook.feeForPriorityFee(type(uint256).max), 3000);
        assertEq(hook.feeFor(type(uint256).max, 0), 3000);
        assertEq(hook.feeFor(0, type(uint256).max), 500);
        assertEq(hook.feeFor(type(uint256).max, type(uint256).max), 500);
        assertEq(hook.feeFor(105_000_000, 5_000_000), 700);
        assertEq(hook.feeFor(0, 5_000_000), 500);
        _setTip(300_000_000);
        (, uint24 fee) = _swap(hookKey, true, -1e18);
        assertEq(fee, 1200);
        assertEq(hook.currentFee(), 1200);
        assertEq(hook.feeForPriorityFee(300_000_000), 1200);
    }

    /// @dev the override is per swap: slot0 keeps the floor whatever was charged
    function test_storedFee_neverChanges() public {
        _setTip(TIP_AT_CAP);
        _swap(hookKey, true, -1e18);
        assertEq(_storedLpFee(hookKey), 500);
        _setTip(0);
        _swap(hookKey, false, 1e18);
        assertEq(_storedLpFee(hookKey), 500);
    }

    // ---------------------------------------------------------------------------------------------
    // Four swap kinds: the hooked pool behaves exactly like a static-fee pool of the same fee
    // ---------------------------------------------------------------------------------------------

    PoolKey internal dynK;
    PoolKey internal statK;

    function _freshPair(uint24 staticFee, uint24 pf0, uint24 pf1) internal {
        // fresh pair per case so both pools start from identical state
        (Currency a, Currency b) = deployMintAndApprove2Currencies();
        (dynK,) = _initDynamicPool(a, b, SQRT_PRICE_1_1);
        statK = _initStaticPool(a, b, staticFee, SQRT_PRICE_1_1);
        _addLiquidity(dynK, WIDE_LOWER, WIDE_UPPER, 1e21, 0);
        _addLiquidity(statK, WIDE_LOWER, WIDE_UPPER, 1e21, 0);
        if (pf0 != 0 || pf1 != 0) {
            _setProtocolFee(dynK, pf0, pf1);
            _setProtocolFee(statK, pf0, pf1);
        }
    }

    function _oneKind(uint256 tip, uint24 total, bool zeroForOne, int256 amount) internal {
        _setTip(tip);
        (BalanceDelta d1, uint24 f1) = _swap(dynK, zeroForOne, amount);
        _setTip(0); // the static pool must not care
        (BalanceDelta d2, uint24 f2) = _swap(statK, zeroForOne, amount);
        assertEq(f1, total, "total fee in the Swap event");
        assertEq(f2, total, "reference pool fee");
        assertEq(BalanceDelta.unwrap(d1), BalanceDelta.unwrap(d2), "same amounts as a static pool of that fee");
        assertEq(_sqrtPrice(dynK), _sqrtPrice(statK), "same price afterwards");
    }

    function _assertSameAsStatic(uint256 tip, uint24 expectedFee, uint24 pf0, uint24 pf1) internal {
        _freshPair(expectedFee, pf0, pf1);
        _oneKind(tip, _totalFee(pf0, expectedFee), true, -3e18); // exact in, 0 -> 1
        _oneKind(tip, _totalFee(pf1, expectedFee), false, -2e18); // exact in, 1 -> 0
        _oneKind(tip, _totalFee(pf0, expectedFee), true, 1e18); // exact out, 0 -> 1
        _oneKind(tip, _totalFee(pf1, expectedFee), false, 7e17); // exact out, 1 -> 0
    }

    function test_fourSwapKinds_atFloor() public {
        _assertSameAsStatic(0, 500, 0, 0);
    }

    function test_fourSwapKinds_midRange() public {
        _assertSameAsStatic(420_000_000, 1500, 0, 0);
    }

    function test_fourSwapKinds_atCap() public {
        _assertSameAsStatic(TIP_AT_CAP, 3000, 0, 0);
    }

    function test_fourSwapKinds_withProtocolFee_atFloor() public {
        _assertSameAsStatic(0, 500, 1000, 400);
    }

    function test_fourSwapKinds_withProtocolFee_midRange() public {
        _assertSameAsStatic(420_000_000, 1500, 250, 1000);
    }

    function test_fourSwapKinds_withProtocolFee_atCap() public {
        _assertSameAsStatic(TIP_AT_CAP, 3000, 1000, 400);
    }

    /// @dev the most a swap can be charged in total: 0.30% LP + 0.10% protocol = 3997 pips
    function test_totalFee_upperBoundWithMaxProtocolFee() public {
        _setProtocolFee(hookKey, 1000, 1000);
        _setGas(type(uint64).max, 0);
        (, uint24 fee) = _swap(hookKey, true, -1e18);
        assertEq(fee, 3997);
        (, fee) = _swap(hookKey, false, 1e18);
        assertEq(fee, 3997);
        _setTip(0);
        (, fee) = _swap(hookKey, true, -1e18);
        assertEq(fee, 1500, "1000 + 500 - floor(1000 * 500 / 1e6)");
    }

    function testFuzz_swap_sameAsStaticPool(uint256 tip, bool zeroForOne, bool exactIn, uint256 amount, uint24 pf)
        public
    {
        tip = bound(tip, 0, 1_200_000_000);
        amount = bound(amount, 1, 1e20);
        pf = uint24(bound(pf, 0, 1000));
        _freshPair(_expectedFee(tip), pf, pf);
        _oneKind(tip, _totalFee(pf, _expectedFee(tip)), zeroForOne, exactIn ? -int256(amount) : int256(amount));
    }

    /// @dev any gas price and base fee, through a real swap: never reverts, fee as specified
    function testFuzz_feeForView_fullRange(uint256 gasPrice, uint256 baseFee) public view {
        uint24 fee = hook.feeFor(gasPrice, baseFee);
        assertEq(fee, _expectedFee(gasPrice, baseFee));
        assertGe(fee, 500);
        assertLe(fee, 3000);
    }

    function testFuzz_swap_anyGasPriceAndBaseFee(uint64 gasPrice, uint64 baseFee, bool zeroForOne, bool exactIn)
        public
    {
        _setGas(gasPrice, baseFee);
        (, uint24 fee) = _swap(hookKey, zeroForOne, exactIn ? -int256(1e18) : int256(1e18));
        assertEq(fee, _expectedFee(gasPrice, baseFee));
        assertGe(fee, 500);
        assertLe(fee, 3000);
        assertEq(hook.feeFor(gasPrice, baseFee), fee);
    }

    function testFuzz_swap_realisticGasPriceAndBaseFee(uint256 baseFee, uint256 tip, uint256 d, bool zeroForOne)
        public
    {
        baseFee = bound(baseFee, 0, 50 gwei);
        tip = bound(tip, 0, 1_200_000_000);
        d = bound(d, 0, 1_200_000_000);
        _setGas(baseFee + tip, baseFee);
        (, uint24 fee) = _swap(hookKey, zeroForOne, -1e15);
        assertEq(fee, _expectedFee(tip));
        _setGas(baseFee + tip + d, baseFee);
        (, uint24 higher) = _swap(hookKey, zeroForOne, -1e15);
        assertGe(higher, fee, "monotone in the tip");
    }

    // ---------------------------------------------------------------------------------------------
    // Edges
    // ---------------------------------------------------------------------------------------------

    function test_nativeEthPool() public {
        (PoolKey memory k,) = _initDynamicPool(CurrencyLibrary.ADDRESS_ZERO, currency1, SQRT_PRICE_1_1);
        _addLiquidity(k, WIDE_LOWER, WIDE_UPPER, 1e21, 0);
        uint24 fee;
        _setTip(100_000_000);
        (, fee) = _swap(k, true, -1e18); // ETH in, exact in
        assertEq(fee, 700);
        (, fee) = _swap(k, false, -1e18); // ETH out, exact in
        assertEq(fee, 700);
        (, fee) = _swap(k, true, 1e18); // ETH in, exact out (router refunds the excess)
        assertEq(fee, 700);
        (, fee) = _swap(k, false, 1e18); // ETH out, exact out
        assertEq(fee, 700);
        assertEq(address(hook).balance, 0);
    }

    /// @dev no liquidity at all: the swap runs to the price limit with zero amounts; the hook does not care
    function test_zeroLiquidityPool_noRevert() public {
        (Currency a, Currency b) = deployMintAndApprove2Currencies();
        (PoolKey memory k,) = _initDynamicPool(a, b, SQRT_PRICE_1_1);
        _setTip(TIP_AT_CAP);
        (BalanceDelta d, uint24 fee) = _swapTo(k, true, -1e18, TickMath.getSqrtPriceAtTick(-1000));
        assertEq(fee, 3000);
        assertEq(BalanceDelta.unwrap(d), 0);
        _setTip(0);
        (d, fee) = _swapTo(k, false, 1e18, TickMath.getSqrtPriceAtTick(1000));
        assertEq(fee, 500);
        assertEq(BalanceDelta.unwrap(d), 0);
    }

    /// @dev single-sided and gapped pools (the shapes that broke H1's cost bound): the fee is the same
    ///      function of the tip, because the hook does not read the pool
    function test_singleSidedAndGappedPools_feeUnchanged() public {
        (Currency a, Currency b) = deployMintAndApprove2Currencies();
        (PoolKey memory k,) = _initDynamicPool(a, b, SQRT_PRICE_1_1);
        _addLiquidity(k, 0, 6000, 1e21, 0); // price at the lower edge
        _addLiquidity(k, 12_000, 18_000, 1e21, 1); // gap between 6000 and 12000
        uint24 fee;
        _setTip(100_000_000);
        (, fee) = _swapTo(k, true, -1e18, TickMath.getSqrtPriceAtTick(-50_000)); // into the empty side
        assertEq(fee, 700);
        (, fee) = _swapTo(k, false, -1e30, TickMath.getSqrtPriceAtTick(9000)); // across the range into the gap
        assertEq(fee, 700);
        (, fee) = _swapTo(k, false, -1e30, TickMath.getSqrtPriceAtTick(15_000)); // through the gap
        assertEq(fee, 700);
        _setTip(0);
        (, fee) = _swap(k, true, -1e18);
        assertEq(fee, 500, "nothing done before changes the next transaction's fee");
    }

    /// @dev swaps that run into the extreme ticks
    function test_tickBoundaries_noRevert() public {
        (Currency a, Currency b) = deployMintAndApprove2Currencies();
        (PoolKey memory k,) = _initDynamicPool(a, b, SQRT_PRICE_1_1);
        _addLiquidity(k, -887_220, 887_220, 1e9, 0);
        _setTip(TIP_AT_CAP);
        (, uint24 fee) = _swapTo(k, true, -1e30, TickMath.MIN_SQRT_PRICE + 1);
        assertEq(fee, 3000);
        assertEq(_sqrtPrice(k), TickMath.MIN_SQRT_PRICE + 1);
        (, fee) = _swapTo(k, false, -1e30, TickMath.MAX_SQRT_PRICE - 1);
        assertEq(fee, 3000);
        assertEq(_sqrtPrice(k), TickMath.MAX_SQRT_PRICE - 1);
        _setTip(0);
        (, fee) = _swap(k, true, -1e10);
        assertEq(fee, 500);
    }

    /// @dev two swaps on the pool inside ONE transaction are each charged at the transaction's tip
    function test_twoSwapsInOneTransaction_bothCharged() public {
        _setTip(TIP_AT_CAP);
        (, uint24 f1) = _swap(hookKey, true, -1e18);
        (, uint24 f2) = _swap(hookKey, false, -1e18); // e.g. the second leg of an aggregator route
        assertEq(f1, 3000);
        assertEq(f2, 3000);
    }

    /// @dev The hook has no liquidity or donate callbacks: adding, removing and donating never call it,
    ///      whatever the gas price. (Red line: withdrawing liquidity must never be blocked.)
    function test_liquidityAndDonate_neverTouchTheHook() public {
        uint256[3] memory gasPrices = [uint256(0), BASEFEE + TIP_AT_CAP, type(uint64).max];
        for (uint256 i; i < gasPrices.length; i++) {
            _setGas(gasPrices[i], BASEFEE);
            vm.record();
            _addLiquidity(hookKey, -600, 600, 1e18, 7);
            donateRouter.donate(hookKey, 1e15, 1e15, ZERO_BYTES);
            _addLiquidity(hookKey, -600, 600, -1e18, 7);
            (bytes32[] memory reads,) = vm.accesses(address(hook));
            assertEq(reads.length, 0, "hook not executed");
        }
        // the whole pool can be emptied
        _setTip(TIP_AT_CAP);
        _addLiquidity(hookKey, WIDE_LOWER, WIDE_UPPER, -WIDE_LIQUIDITY, 0);
        assertEq(manager.getLiquidity(hookId), 0);
    }

    function test_hookHoldsNothing() public {
        _setTip(TIP_AT_CAP);
        _swap(hookKey, true, -1e18);
        _swap(hookKey, false, 1e18);
        assertEq(currency0.balanceOf(address(hook)), 0);
        assertEq(currency1.balanceOf(address(hook)), 0);
        assertEq(address(hook).balance, 0);
        // it cannot be sent ETH either (no receive / fallback)
        (bool ok,) = address(hook).call{value: 1}("");
        assertFalse(ok);
    }

    /// @dev hookData and the swap's `sender` play no role
    // ---------------------------------------------------------------------------------------------
    // The fee does not depend on sender, hookData or SwapParams. In the source this holds by
    // construction (src/PriorityFeeHook.sol L91: these three parameters of _beforeSwap are unnamed, the
    // body cannot read them). The tests below are what would catch a later edit that names and uses them.
    // ---------------------------------------------------------------------------------------------

    function _hookData(uint256 lenSeed, bytes32 fill) internal pure returns (bytes memory data) {
        uint16[10] memory lens = [uint16(0), 1, 4, 20, 31, 32, 33, 64, 96, 320];
        uint256 len = lenSeed % 12 < 10 ? lens[lenSeed % 12] : (lenSeed >> 8) % 600;
        data = new bytes(len);
        for (uint256 i; i < len; i++) {
            data[i] = fill[i % 32];
        }
    }

    function _assertBeforeSwap(address sender, address origin, SwapParams memory params, bytes memory data, uint24 want)
        internal
    {
        vm.prank(address(manager), origin);
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) = hook.beforeSwap(sender, hookKey, params, data);
        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(delta), 0);
        assertEq(fee, want | LPFeeLibrary.OVERRIDE_FEE_FLAG, "fee depends on the tip only");
    }

    /// @dev direct calls as PoolManager: any sender (including sender == tx.origin, sender == the hook,
    ///      == PoolManager, == 0), any tx.origin, any SwapParams, hookData of any length (0, 1, 4, 20, 31,
    ///      32, 33, 64, 96, 320 and random lengths) and content
    function testFuzz_fee_ignoresSenderHookDataAndSwapParams(
        uint256 tip,
        address sender,
        address origin,
        uint8 senderKind,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        uint256 lenSeed,
        bytes32 fill
    ) public {
        tip = bound(tip, 0, 1_300_000_000);
        _setTip(tip);
        if (senderKind % 5 == 0) sender = origin;
        else if (senderKind % 5 == 1) sender = address(hook);
        else if (senderKind % 5 == 2) sender = address(manager);
        else if (senderKind % 5 == 3) sender = address(0);
        bytes memory data = _hookData(lenSeed, fill);
        uint24 want = _expectedFee(tip);
        _assertBeforeSwap(sender, origin, SwapParams(zeroForOne, amountSpecified, sqrtPriceLimitX96), data, want);
        // and through a real swap carrying the same hookData
        vm.recordLogs();
        swapRouter.swap(
            hookKey,
            SwapParams(zeroForOne, -1e15, zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            data
        );
        assertEq(_lastSwapFee(), want);
    }

    /// @dev kills the mutant "hookData of length 32 is charged the floor" (survived audit round 1): every
    ///      length around a word boundary, with a tip at the cap, directly and through a real swap
    function test_fee_ignoresHookData_everyLengthAroundAWord() public {
        _setTip(TIP_AT_CAP);
        uint16[12] memory lens = [uint16(0), 1, 3, 4, 20, 31, 32, 33, 63, 64, 65, 320];
        for (uint256 i; i < lens.length; i++) {
            bytes memory zeros = new bytes(lens[i]);
            bytes memory ones = new bytes(lens[i]);
            for (uint256 j; j < lens[i]; j++) {
                ones[j] = 0xff;
            }
            _assertBeforeSwap(address(swapRouter), tx.origin, SwapParams(true, -1e18, MIN_PRICE_LIMIT), zeros, 3000);
            _assertBeforeSwap(address(swapRouter), tx.origin, SwapParams(true, -1e18, MIN_PRICE_LIMIT), ones, 3000);
            vm.recordLogs();
            swapRouter.swap(
                hookKey,
                SwapParams(i % 2 == 0, -1e15, i % 2 == 0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ones
            );
            assertEq(_lastSwapFee(), 3000);
        }
        // a 32-byte hookData that looks like "my maximum fee is 500 pips" changes nothing
        _assertBeforeSwap(address(1), tx.origin, SwapParams(true, -1e18, MIN_PRICE_LIMIT), abi.encode(uint256(500)), 3000);
    }

    /// @dev kills the mutant "sender == tx.origin is charged the floor" (survived audit round 1)
    function test_fee_ignoresSender_includingTxOrigin() public {
        _setTip(TIP_AT_CAP);
        SwapParams memory params = SwapParams(true, -1e18, MIN_PRICE_LIMIT);
        address origin = makeAddr("origin");
        _assertBeforeSwap(origin, origin, params, "", 3000); // sender == tx.origin
        _assertBeforeSwap(tx.origin, tx.origin, params, "", 3000); // with forge's default origin
        _assertBeforeSwap(address(1), origin, params, "", 3000);
        _assertBeforeSwap(address(hook), origin, params, "", 3000);
        _assertBeforeSwap(address(manager), origin, params, "", 3000);
        _assertBeforeSwap(address(0), origin, params, "", 3000);
        _assertBeforeSwap(address(swapRouter), address(swapRouter), params, "", 3000);
        _setTip(100_000_000);
        _assertBeforeSwap(origin, origin, SwapParams(false, 5, MAX_PRICE_LIMIT), hex"deadbeef", 700);
    }
}
