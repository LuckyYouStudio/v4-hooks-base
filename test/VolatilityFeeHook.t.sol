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

import {VolatilityFeeHook} from "../src/VolatilityFeeHook.sol";
import {BaseHook} from "../src/base/BaseHook.sol";
import {VolatilityMath} from "../src/libraries/VolatilityMath.sol";
import {HookTestBase} from "./utils/HookTestBase.sol";
import {AllCallbacksMockHook} from "./utils/AllCallbacksMockHook.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

contract VolatilityFeeHookTest is HookTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using Hooks for IHooks;

    event FeeUpdated(PoolId indexed id, uint24 fee, uint64 variance, int32 logPrice);

    SwapParams internal someSwap = SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0});
    ModifyLiquidityParams internal someLiq =
        ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1, salt: 0});

    function setUp() public {
        _baseSetUp();
    }

    // ------------------------------------------------------------------------------------------
    // Permissions
    // ------------------------------------------------------------------------------------------

    function test_permissions_matchAddressBits() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        Hooks.validateHookPermissions(IHooks(address(hook)), p);
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, HOOK_FLAGS);
        assertTrue(p.afterInitialize);
        assertTrue(p.beforeSwap);
        assertFalse(
            p.beforeInitialize || p.beforeAddLiquidity || p.afterAddLiquidity || p.beforeRemoveLiquidity
                || p.afterRemoveLiquidity || p.afterSwap || p.beforeDonate || p.afterDonate
                || p.beforeSwapReturnDelta || p.afterSwapReturnDelta || p.afterAddLiquidityReturnDelta
                || p.afterRemoveLiquidityReturnDelta
        );
        assertTrue(IHooks(address(hook)).isValidHookAddress(LPFeeLibrary.DYNAMIC_FEE_FLAG));
    }

    function test_immutables() public view {
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.MIN_FEE(), 500);
        assertEq(hook.MAX_FEE(), 10_000);
        assertEq(hook.HALF_LIFE(), 600);
        assertEq(hook.FEE_PER_VOL_TICK(), 25);
        assertEq(hook.BUCKET(), BUCKET);
    }

    /// @dev I-1: a PoolManager argument without code (zero address, EOA, wrong chain) is rejected at
    ///      construction, before the address-bits check.
    function test_constructor_rejectsPoolManagerWithoutCode() public {
        vm.expectRevert(BaseHook.PoolManagerHasNoCode.selector);
        new VolatilityFeeHook(IPoolManager(address(0)));
        vm.expectRevert(BaseHook.PoolManagerHasNoCode.selector);
        new VolatilityFeeHook(IPoolManager(makeAddr("an EOA")));
    }

    // ------------------------------------------------------------------------------------------
    // afterInitialize: registration
    // ------------------------------------------------------------------------------------------

    function test_afterInitialize_registersPool() public {
        (Currency a, Currency b) = deployMintAndApprove2Currencies();
        (, PoolId id) = _initDynamicPool(a, b, SQRT_PRICE_1_1);
        VolatilityFeeHook.PoolState memory s = hook.poolState(id);
        assertTrue(s.registered);
        assertFalse(s.armed);
        assertEq(s.variance, 0);
        assertEq(s.fee, MIN_FEE);
        assertEq(s.lastLogPrice, 0);
        assertEq(s.lastTimestamp, block.timestamp);
        assertEq(hook.currentFee(id), MIN_FEE);
    }

    function test_afterInitialize_recordsInitialLogPrice() public {
        (Currency a, Currency b) = deployMintAndApprove2Currencies();
        (, PoolId id) = _initDynamicPool(a, b, SQRT_PRICE_4_1);
        // ln(4) / ln(1.0001) = 13863.6...: tick 13863, and the sub-tick part is kept
        assertEq(TickMath.getTickAtSqrtPrice(SQRT_PRICE_4_1), 13863);
        assertEq(hook.poolState(id).lastLogPrice, VolatilityMath.logPrice(SQRT_PRICE_4_1));
        assertEq(hook.poolState(id).lastLogPrice, 13_863_636);
    }

    function test_baseFixture_isArmedAtFloor() public view {
        VolatilityFeeHook.PoolState memory s = _state();
        assertTrue(s.registered);
        assertTrue(s.armed);
        assertEq(s.variance, 0);
        assertEq(s.fee, MIN_FEE);
        assertEq(s.lastLogPrice, 0);
        assertEq(s.lastTimestamp, T0 + BUCKET);
    }

    function test_initialize_staticFeePool_reverts() public {
        uint24[4] memory fees = [uint24(0), 500, 3000, LPFeeLibrary.MAX_LP_FEE];
        for (uint256 i; i < fees.length; i++) {
            PoolKey memory k = PoolKey(currency0, currency1, fees[i], SPACING, IHooks(address(hook)));
            vm.expectRevert(_wrapped(IHooks.afterInitialize.selector, VolatilityFeeHook.NotDynamicFee.selector));
            manager.initialize(k, SQRT_PRICE_1_1);
            assertFalse(hook.poolState(k.toId()).registered);
        }
    }

    function test_afterInitialize_direct_staticFee_reverts() public {
        PoolKey memory k = PoolKey(currency0, currency1, 3000, SPACING, IHooks(address(hook)));
        vm.prank(address(manager));
        vm.expectRevert(VolatilityFeeHook.NotDynamicFee.selector);
        hook.afterInitialize(address(this), k, SQRT_PRICE_1_1, 0);
    }

    function test_initialize_samePoolTwice_cannotResetState() public {
        _moveTo(hookKey, 200);
        _nextBlock(BUCKET);
        _swap(hookKey, true, -TINY);
        bytes32 before_ = _stateHash(hookId);
        vm.expectRevert(); // Pool.PoolAlreadyInitialized
        manager.initialize(hookKey, SQRT_PRICE_1_1);
        assertEq(_stateHash(hookId), before_);
    }

    // ------------------------------------------------------------------------------------------
    // Access control
    // ------------------------------------------------------------------------------------------

    /// @dev every one of the ten IHooks entry points, on any BaseHook
    function _assertAllTenRevertForCaller(IHooks h, address caller) internal {
        BalanceDelta z = BalanceDeltaLibrary.ZERO_DELTA;
        bytes4 err = BaseHook.NotPoolManager.selector;
        vm.startPrank(caller);
        vm.expectRevert(err);
        h.beforeInitialize(caller, hookKey, SQRT_PRICE_1_1);
        vm.expectRevert(err);
        h.afterInitialize(caller, hookKey, SQRT_PRICE_1_1, 0);
        vm.expectRevert(err);
        h.beforeAddLiquidity(caller, hookKey, someLiq, "");
        vm.expectRevert(err);
        h.afterAddLiquidity(caller, hookKey, someLiq, z, z, "");
        vm.expectRevert(err);
        h.beforeRemoveLiquidity(caller, hookKey, someLiq, "");
        vm.expectRevert(err);
        h.afterRemoveLiquidity(caller, hookKey, someLiq, z, z, "");
        vm.expectRevert(err);
        h.beforeSwap(caller, hookKey, someSwap, "");
        vm.expectRevert(err);
        h.afterSwap(caller, hookKey, someSwap, z, "");
        vm.expectRevert(err);
        h.beforeDonate(caller, hookKey, 1, 1, "");
        vm.expectRevert(err);
        h.afterDonate(caller, hookKey, 1, 1, "");
        vm.stopPrank();
    }

    function test_allCallbacks_revertForNonPoolManager(address caller) public {
        vm.assume(caller != address(manager));
        _assertAllTenRevertForCaller(IHooks(address(hook)), caller);
    }

    /// @dev L-1. A subclass that implements ALL ten callbacks and writes no access check of its own is
    ///      still closed to everyone but the PoolManager: the check sits in BaseHook's non-virtual
    ///      external functions, which a subclass cannot override (it would not compile).
    function test_baseHook_carelessSubclass_stillOnlyPoolManager(address caller) public {
        vm.assume(caller != address(manager));
        uint160 flags = uint160(Hooks.ALL_HOOK_MASK) & ~uint160(0xF); // ten callbacks, no return-delta bits
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), flags, type(AllCallbacksMockHook).creationCode, abi.encode(manager));
        AllCallbacksMockHook m = new AllCallbacksMockHook{salt: salt}(manager);
        assertEq(address(m), expected);

        _assertAllTenRevertForCaller(IHooks(address(m)), caller);
        assertEq(m.reached(), 0, "no callback body ran");

        // the same ten calls from the PoolManager all reach the subclass
        BalanceDelta z = BalanceDeltaLibrary.ZERO_DELTA;
        vm.startPrank(address(manager));
        assertEq(m.beforeInitialize(caller, hookKey, SQRT_PRICE_1_1), IHooks.beforeInitialize.selector);
        assertEq(m.afterInitialize(caller, hookKey, SQRT_PRICE_1_1, 0), IHooks.afterInitialize.selector);
        assertEq(m.beforeAddLiquidity(caller, hookKey, someLiq, ""), IHooks.beforeAddLiquidity.selector);
        (bytes4 sel,) = m.afterAddLiquidity(caller, hookKey, someLiq, z, z, "");
        assertEq(sel, IHooks.afterAddLiquidity.selector);
        assertEq(m.beforeRemoveLiquidity(caller, hookKey, someLiq, ""), IHooks.beforeRemoveLiquidity.selector);
        (sel,) = m.afterRemoveLiquidity(caller, hookKey, someLiq, z, z, "");
        assertEq(sel, IHooks.afterRemoveLiquidity.selector);
        (sel,,) = m.beforeSwap(caller, hookKey, someSwap, "");
        assertEq(sel, IHooks.beforeSwap.selector);
        (sel,) = m.afterSwap(caller, hookKey, someSwap, z, "");
        assertEq(sel, IHooks.afterSwap.selector);
        assertEq(m.beforeDonate(caller, hookKey, 1, 1, ""), IHooks.beforeDonate.selector);
        assertEq(m.afterDonate(caller, hookKey, 1, 1, ""), IHooks.afterDonate.selector);
        vm.stopPrank();
        assertEq(m.reached(), 10);
    }

    function test_directCall_cannotReRegisterOrTouchState() public {
        _moveTo(hookKey, 150);
        _nextBlock(BUCKET);
        _swap(hookKey, true, -TINY);
        bytes32 before_ = _stateHash(hookId);
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterInitialize(address(this), hookKey, SQRT_PRICE_1_1, 0);
        _nextBlock(BUCKET);
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), hookKey, someSwap, "");
        assertEq(_stateHash(hookId), before_);
    }

    function test_unimplementedCallbacks_revertEvenForPoolManager() public {
        BalanceDelta z = BalanceDeltaLibrary.ZERO_DELTA;
        bytes4 err = BaseHook.HookNotImplemented.selector;
        vm.startPrank(address(manager));
        vm.expectRevert(err);
        hook.beforeInitialize(address(this), hookKey, SQRT_PRICE_1_1);
        vm.expectRevert(err);
        hook.beforeAddLiquidity(address(this), hookKey, someLiq, "");
        vm.expectRevert(err);
        hook.afterAddLiquidity(address(this), hookKey, someLiq, z, z, "");
        vm.expectRevert(err);
        hook.beforeRemoveLiquidity(address(this), hookKey, someLiq, "");
        vm.expectRevert(err);
        hook.afterRemoveLiquidity(address(this), hookKey, someLiq, z, z, "");
        vm.expectRevert(err);
        hook.afterSwap(address(this), hookKey, someSwap, z, "");
        vm.expectRevert(err);
        hook.beforeDonate(address(this), hookKey, 1, 1, "");
        vm.expectRevert(err);
        hook.afterDonate(address(this), hookKey, 1, 1, "");
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------------------------
    // Unknown pools
    // ------------------------------------------------------------------------------------------

    function test_beforeSwap_unregisteredPool_reverts() public {
        // A key the hook never saw in afterInitialize. The real PoolManager cannot produce this call
        // (initialize always runs afterInitialize first), so impersonate it.
        PoolKey memory stranger = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, IHooks(address(hook)));
        vm.prank(address(manager));
        vm.expectRevert(VolatilityFeeHook.PoolNotRegistered.selector);
        hook.beforeSwap(address(this), stranger, someSwap, "");
        assertFalse(hook.poolState(stranger.toId()).registered);

        vm.expectRevert(VolatilityFeeHook.PoolNotRegistered.selector);
        hook.currentFee(stranger.toId());
    }

    function test_swap_uninitializedPool_reverts() public {
        PoolKey memory stranger = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, IHooks(address(hook)));
        vm.expectRevert(); // PoolManager: PoolNotInitialized, before the hook is even called
        swap(stranger, true, -1e18, ZERO_BYTES);
    }

    function test_pools_areIsolated() public {
        // A second dynamic-fee pool on the same hook (anyone may create one) has its own state.
        (Currency a, Currency b) = deployMintAndApprove2Currencies();
        (PoolKey memory k2, PoolId id2) = _initDynamicPool(a, b, SQRT_PRICE_1_1);
        _addWideLiquidity(k2);
        _arm(k2);
        bytes32 h1 = _stateHash(hookId);

        _moveTo(k2, 500);
        _nextBlock(BUCKET);
        (, uint24 fee2) = _swap(k2, true, -TINY);
        assertEq(fee2, MAX_FEE);
        assertEq(hook.poolState(id2).variance, VolatilityMath.VAR_CAP);

        // pool 1 untouched by all of that, and still at the floor
        assertEq(_stateHash(hookId), h1);
        (, uint24 fee1) = _swap(hookKey, true, -TINY);
        assertEq(fee1, MIN_FEE);
        assertEq(_state().variance, 0);
    }

    // ------------------------------------------------------------------------------------------
    // Fee actually charged: both directions x exactIn / exactOut
    // ------------------------------------------------------------------------------------------

    function _assertAllFourCharge(uint24 expectedFee) internal {
        uint24 fee;
        (, fee) = _swap(hookKey, true, -1e18); // 0->1 exact in
        assertEq(fee, expectedFee, "0->1 exactIn");
        (, fee) = _swap(hookKey, false, -1e18); // 1->0 exact in
        assertEq(fee, expectedFee, "1->0 exactIn");
        (, fee) = _swap(hookKey, true, 1e18); // 0->1 exact out
        assertEq(fee, expectedFee, "0->1 exactOut");
        (, fee) = _swap(hookKey, false, 1e18); // 1->0 exact out
        assertEq(fee, expectedFee, "1->0 exactOut");
    }

    function test_fee_floor_allFourSwapKinds() public {
        _assertAllFourCharge(MIN_FEE);
        _moveTo(hookKey, 0); // close the bucket on the log price it opened on
        _nextBlock(BUCKET);
        _assertAllFourCharge(MIN_FEE);
        assertEq(_state().variance, 0);
    }

    function test_fee_elevated_allFourSwapKinds() public {
        _moveTo(hookKey, 100);
        _nextBlock(BUCKET);
        _assertAllFourCharge(3000);
    }

    function test_fee_cap_allFourSwapKinds() public {
        _moveTo(hookKey, -1000);
        _nextBlock(BUCKET);
        _assertAllFourCharge(MAX_FEE);
    }

    /// @dev The override really is what the pool charges: amounts on the hooked pool are identical, wei
    ///      for wei, to a hookless static-fee pool with the same fee and liquidity.
    function test_fee_amountsMatchStaticPoolWithSameFee() public {
        (Currency a, Currency b) = deployMintAndApprove2Currencies();
        PoolKey memory dyn;
        (dyn,) = _initDynamicPool(a, b, SQRT_PRICE_1_1);
        _addWideLiquidity(dyn);
        PoolKey memory stat = PoolKey(a, b, MIN_FEE, SPACING, IHooks(address(0)));
        manager.initialize(stat, SQRT_PRICE_1_1);
        _addWideLiquidity(stat);

        int256[4] memory amounts = [int256(-3e21), 2e21, -7e20, 5e20];
        bool[4] memory dirs = [true, true, false, false];
        for (uint256 i; i < 4; i++) {
            BalanceDelta d1 = swap(dyn, dirs[i], amounts[i], ZERO_BYTES);
            BalanceDelta d2 = swap(stat, dirs[i], amounts[i], ZERO_BYTES);
            assertEq(BalanceDelta.unwrap(d1), BalanceDelta.unwrap(d2), "delta");
            assertEq(_sqrtPrice(dyn), _sqrtPrice(stat), "price");
        }
        // PoolManager never stores the override: slot0.lpFee of a dynamic pool stays 0
        (,,, uint24 lpFee) = manager.getSlot0(dyn.toId());
        assertEq(lpFee, 0);
    }

    // ------------------------------------------------------------------------------------------
    // With a protocol fee: both directions x exactIn / exactOut, at the floor, elevated and at the cap
    // ------------------------------------------------------------------------------------------

    /// @dev PoolManager takes the protocol fee first and the LP fee on the remainder; the hook only
    ///      ever sets the LP part. The protocol fee is per direction.
    function _assertAllFourChargeWithProtocol(uint24 lpFee, uint24 pfZeroForOne, uint24 pfOneForZero) internal {
        uint24 fee;
        (, fee) = _swap(hookKey, true, -1e18);
        assertEq(fee, _totalFee(pfZeroForOne, lpFee), "0->1 exactIn");
        (, fee) = _swap(hookKey, false, -1e18);
        assertEq(fee, _totalFee(pfOneForZero, lpFee), "1->0 exactIn");
        (, fee) = _swap(hookKey, true, 1e18);
        assertEq(fee, _totalFee(pfZeroForOne, lpFee), "0->1 exactOut");
        (, fee) = _swap(hookKey, false, 1e18);
        assertEq(fee, _totalFee(pfOneForZero, lpFee), "1->0 exactOut");
        assertEq(_state().fee, lpFee, "hook only sets the LP part");
    }

    function test_fee_withProtocolFee_floor_allFourSwapKinds() public {
        _setProtocolFee(hookKey, 1000, 400); // 0.10% for 0->1, 0.04% for 1->0
        assertEq(_totalFee(1000, 500), 1500); // 1000 + 500 - floor(1000 * 500 / 1e6)
        assertEq(_totalFee(400, 500), 900);
        _assertAllFourChargeWithProtocol(MIN_FEE, 1000, 400);
    }

    function test_fee_withProtocolFee_elevated_allFourSwapKinds() public {
        _setProtocolFee(hookKey, 1000, 400);
        _moveTo(hookKey, 100);
        _nextBlock(BUCKET);
        assertEq(_totalFee(1000, 3000), 3997); // 1000 + 3000 - 3
        assertEq(_totalFee(400, 3000), 3399); // 400 + 3000 - 1 (1.2 floored)
        _assertAllFourChargeWithProtocol(3000, 1000, 400);
    }

    function test_fee_withProtocolFee_cap_allFourSwapKinds() public {
        _setProtocolFee(hookKey, 1000, 1000); // the maximum v4 allows, both ways
        _moveTo(hookKey, 2000);
        _nextBlock(BUCKET);
        assertEq(_totalFee(1000, MAX_FEE), 10_990); // the most a trader can ever be charged in total
        _assertAllFourChargeWithProtocol(MAX_FEE, 1000, 1000);
    }

    /// @dev setting or changing the protocol fee does not touch the hook, and the hook does not see it
    function test_protocolFee_doesNotChangeHookState() public {
        _moveTo(hookKey, 60);
        _nextBlock(BUCKET);
        _swap(hookKey, true, -TINY);
        bytes32 h = _stateHash(hookId);
        _setProtocolFee(hookKey, 777, 1);
        assertEq(_stateHash(hookId), h);
        assertEq(hook.currentFee(hookId), 2000);
        (, uint24 fee) = _swap(hookKey, false, -TINY);
        assertEq(fee, _totalFee(1, 2000));
        assertEq(_stateHash(hookId), h);
    }

    /// forge-config: default.fuzz.runs = 128
    function testFuzz_fee_withProtocolFee(uint16 pf0, uint16 pf1, int16 tick, bool zeroForOne, bool exactIn)
        public
    {
        uint24 p0 = uint24(bound(pf0, 0, 1000));
        uint24 p1 = uint24(bound(pf1, 0, 1000));
        int24 target = int24(bound(tick, -450, 450));
        _setProtocolFee(hookKey, p0, p1);
        if (target != 0) _moveTo(hookKey, target);
        _nextBlock(BUCKET);
        uint256 d = target < 0 ? uint24(-target) : uint24(target);
        uint24 lp = uint24(500 + 25 * d > 10_000 ? 10_000 : 500 + 25 * d);
        assertEq(hook.currentFee(hookId), lp);
        (, uint24 fee) = _swap(hookKey, zeroForOne, exactIn ? -int256(1e18) : int256(1e18));
        assertEq(fee, _totalFee(zeroForOne ? p0 : p1, lp));
        assertLe(fee, 10_990);
        assertEq(_state().fee, lp);
    }

    // ------------------------------------------------------------------------------------------
    // Cross-block volatility update
    // ------------------------------------------------------------------------------------------

    function test_crossBucket_exactNumbers() public {
        // bucket N: price moves 0 -> +100 ticks. Fee in this bucket stays at the floor.
        (, uint24 fee) = _moveTo(hookKey, 100);
        assertEq(fee, MIN_FEE);
        assertEq(_state().variance, 0);
        assertEq(hook.currentFee(hookId), MIN_FEE);

        // bucket N+1: first swap observes the +100 move.
        _nextBlock(BUCKET);
        assertEq(hook.currentFee(hookId), 3000, "view predicts");
        vm.expectEmit(true, false, false, true, address(hook));
        emit FeeUpdated(hookId, 3000, 1e10, 100_000);
        (, fee) = _swap(hookKey, true, -TINY);
        assertEq(fee, 3000); // 500 + 25 * 100
        VolatilityFeeHook.PoolState memory s = _state();
        assertEq(s.variance, 1e10);
        assertEq(s.lastLogPrice, 100_000);
        assertEq(s.lastTimestamp, block.timestamp);

        // one half-life later with no further move: variance halves.
        _nextBlock(600);
        (, fee) = _swap(hookKey, false, -TINY);
        assertEq(fee, 2267); // 500 + 25 * 70.71
        assertEq(_state().variance, 5e9);

        // price returns to 0 in this bucket; the next bucket sees a second 100-tick move.
        _moveTo(hookKey, 0);
        _nextBlock(BUCKET);
        (, fee) = _swap(hookKey, true, -TINY);
        assertEq(_state().variance, VolatilityMath.decay(5e9, 10) + 1e10);
        assertEq(fee, 3555); // 500 + floor(25 * sqrt(4942.57 + 10000)) = 500 + floor(25 * 122.2398)
    }

    /// @dev H-1. The observation is the log price with sub-tick resolution, read from sqrtPriceX96.
    ///      Stepping one unit of sqrtPriceX96 over a tick boundary changes the pool's integer tick by 1
    ///      but the observation by 0.001 tick, i.e. 1e-6 tick^2 instead of 1 tick^2.
    function test_tickBoundaryCross_countsAsOneMilliTick() public {
        uint160 pB = TickMath.getSqrtPriceAtTick(0);
        _moveToPrice(hookKey, pB - 1);
        assertEq(_tick(hookKey), -1, "the pool's integer tick did flip");
        assertEq(_logPrice(hookKey), -1, "the hook sees -0.001 tick");
        _nextBlock(BUCKET);
        (, uint24 fee) = _moveToPrice(hookKey, pB);
        assertEq(_tick(hookKey), 0);
        assertEq(_state().variance, 1, "1 milli-tick^2");
        assertEq(fee, MIN_FEE);
        _nextBlock(BUCKET);
        (, fee) = _swap(hookKey, true, -TINY);
        assertEq(_state().variance, 1); // decay(1, 10) floors to 0, plus the 1 milli-tick step back
        assertEq(fee, MIN_FEE);
    }

    /// @dev One observation per time bucket. Base produces a block every 200ms (about five block numbers
    ///      per block.timestamp), so a 10s bucket is ~50 blocks: however the price moves inside it, across
    ///      however many blocks and seconds, the hook neither updates nor changes the fee, and afterwards
    ///      only the net move of the bucket is counted.
    function test_sameBucket_manyBlocks_noUpdate_onlyNetMoveCounts() public {
        uint256 t0 = block.timestamp;
        bytes32 h = _stateHash(hookId);
        int24[5] memory targets = [int24(30), 70, 20, 250, -40];
        for (uint256 i; i < 5; i++) {
            (, uint24 fee) = _moveTo(hookKey, targets[i]);
            assertEq(fee, MIN_FEE);
            assertEq(lastFeeUpdates, 0, "no update inside the bucket");
            vm.roll(block.number + 3);
            vm.warp(block.timestamp + (i % 2 == 0 ? 0 : 4)); // new blocks, same or later second
            assertEq(hook.currentFee(hookId), MIN_FEE);
        }
        assertEq(block.timestamp, t0 + 8);
        assertEq(block.timestamp / BUCKET, t0 / BUCKET, "still the same bucket");
        assertEq(_stateHash(hookId), h, "state frozen for the whole bucket");

        _nextBlock(2); // t0 + 10: next bucket
        (, uint24 next) = _swap(hookKey, true, -TINY);
        assertEq(lastFeeUpdates, 1);
        // only the net -40 ticks: not 30^2 + 40^2 + 50^2 + 230^2 + 290^2
        assertEq(_state().variance, 1600e6);
        assertEq(next, 1500);
    }

    /// @dev E-2 of the audit: a one-way move executed one tick per 200ms block. Per-block sampling of
    ///      integer ticks would record 100 * 1^2 = 100 tick^2 (fee 0.075%); bucket sampling records the
    ///      two 50-tick bucket moves, close to what a single 100-tick jump gives (0.30%).
    function test_trend_choppedIntoBlocks_isNotUnderestimated() public {
        uint256 t0 = block.timestamp;
        for (uint256 i = 1; i <= 100; i++) {
            _moveTo(hookKey, int24(int256(i)));
            vm.roll(block.number + 1);
            if (i % 5 == 0) vm.warp(block.timestamp + 1); // 5 blocks per second
        }
        assertEq(block.timestamp, t0 + 20);
        (, uint24 fee) = _swap(hookKey, true, -TINY);
        assertEq(_state().variance, VolatilityMath.decay(2500e6, 10) + 2500e6);
        assertEq(fee, 2262); // 500 + 25 * sqrt(2471.3 + 2500) = 500 + 25 * 70.51
    }

    function test_crossBucket_directionDoesNotMatter() public {
        uint256 snap = vm.snapshotState();
        _moveTo(hookKey, 77);
        _nextBlock(13);
        (, uint24 up) = _swap(hookKey, true, -TINY);
        vm.revertToState(snap);
        _moveTo(hookKey, -77);
        _nextBlock(13);
        (, uint24 down) = _swap(hookKey, true, -TINY);
        assertEq(up, down);
        assertEq(up, 500 + 25 * 77);
    }

    function test_sameBucket_updateHappensOnce() public {
        _moveTo(hookKey, 100);
        _nextBlock(BUCKET);

        (, uint24 fee) = _swap(hookKey, true, -TINY);
        assertEq(fee, 3000);
        assertEq(lastFeeUpdates, 1, "first swap of the bucket updates");
        bytes32 afterFirst = _stateHash(hookId);

        // heavy trading for the rest of the bucket, incl. a 300-tick excursion, in this block and in
        // later blocks of the bucket: same fee, no update
        (, fee) = _moveTo(hookKey, 400);
        assertEq(fee, 3000);
        assertEq(lastFeeUpdates, 0);
        _nextBlock(0);
        (, fee) = _moveTo(hookKey, -50);
        assertEq(fee, 3000);
        assertEq(lastFeeUpdates, 0);
        _nextBlock(9);
        (, fee) = _swap(hookKey, false, 1e20);
        assertEq(fee, 3000);
        assertEq(lastFeeUpdates, 0);
        assertEq(_stateHash(hookId), afterFirst, "state frozen within the bucket");
    }

    function test_decay_backToFloor() public {
        _moveTo(hookKey, 2000);
        _nextBlock(BUCKET);
        (, uint24 fee) = _swap(hookKey, true, -TINY);
        assertEq(fee, MAX_FEE);

        // 10 minutes: cap/2 -> vol 268.7 ticks
        _nextBlock(600);
        (, fee) = _swap(hookKey, true, -TINY);
        assertEq(fee, 500 + (25 * VolatilityMath.sqrt(VolatilityMath.VAR_CAP / 2)) / 1000);
        assertEq(fee, 7217);

        // 1 hour later: another 6 halvings
        _nextBlock(3600);
        (, fee) = _swap(hookKey, true, -TINY);
        assertEq(fee, 1339);

        // a day of silence: indistinguishable from a fresh pool
        _nextBlock(1 days);
        (, fee) = _swap(hookKey, true, -TINY);
        assertEq(fee, MIN_FEE);
        assertEq(_state().variance, 0);
    }

    function test_cap_holdsUnderRepeatedHugeMoves() public {
        int24[6] memory targets = [int24(5000), -5000, 20_000, -20_000, 119_000, -119_000];
        for (uint256 i; i < targets.length; i++) {
            _moveTo(hookKey, targets[i]);
            _nextBlock(BUCKET);
            (, uint24 fee) = _swap(hookKey, i % 2 == 0, -TINY);
            assertEq(fee, MAX_FEE);
            assertEq(_state().variance, VolatilityMath.VAR_CAP);
        }
    }

    function test_currentFee_predictsNextSwap() public {
        int24[5] memory targets = [int24(30), -45, 10, 300, 290];
        uint256[5] memory dts = [uint256(10), 1, 45, 700, 13];
        for (uint256 i; i < targets.length; i++) {
            _moveTo(hookKey, targets[i]);
            _nextBlock(dts[i]);
            uint24 predicted = hook.currentFee(hookId);
            (, uint24 charged) = _swap(hookKey, true, -TINY);
            assertEq(charged, predicted);
            assertEq(hook.currentFee(hookId), charged, "same bucket: cached");
        }
    }

    /// @dev Re-audit N-3. block.timestamp going BACKWARDS (does not happen on a real chain): the hook
    ///      neither observes nor reverts; swaps keep being charged the cached fee. Kills the mutation
    ///      `>` -> `!=` in _isNewBucket (which would underflow `block.timestamp - lastTimestamp`).
    function test_clockGoingBackwards_noObservation_noRevert() public {
        _moveTo(hookKey, 100);
        _nextBlock(5 * BUCKET);
        (, uint24 fee) = _swap(hookKey, true, -TINY);
        assertEq(fee, 3000);
        assertEq(lastFeeUpdates, 1);
        bytes32 h = _stateHash(hookId);
        uint256 tStored = _state().lastTimestamp;

        // back by 1 second (same bucket), by one bucket, by several buckets, to before the pool existed
        uint256[4] memory back = [uint256(1), BUCKET, 4 * BUCKET, 1000 * BUCKET];
        for (uint256 i; i < back.length; i++) {
            vm.roll(block.number + 1);
            vm.warp(tStored + 1 - back[i]);
            assertLe(block.timestamp, tStored);
            assertEq(hook.currentFee(hookId), 3000, "view: cached fee");
            // a real 50-tick move each time: it must not be observed
            (, fee) = _moveTo(hookKey, i % 2 == 0 ? int24(150) : int24(100));
            assertEq(fee, 3000, "swap charged the cached fee");
            assertEq(lastFeeUpdates, 0, "no FeeUpdated");
            assertEq(_stateHash(hookId), h, "state untouched");
            // all four swap kinds go through
            _swap(hookKey, true, -TINY);
            _swap(hookKey, false, -TINY);
            _swap(hookKey, true, TINY);
            (, fee) = _swap(hookKey, false, TINY);
            assertEq(fee, 3000);
            assertEq(_stateHash(hookId), h);
        }

        // once the clock is past the stored bucket again, observation resumes from the stored anchor
        _moveTo(hookKey, 100);
        vm.roll(block.number + 1);
        vm.warp(tStored + BUCKET);
        uint24 predicted = hook.currentFee(hookId);
        (, fee) = _swap(hookKey, true, -TINY);
        assertEq(fee, predicted);
        assertEq(lastFeeUpdates, 1);
        assertEq(_state().lastTimestamp, tStored + BUCKET);
        assertEq(fee, VolatilityMath.feeFromVariance(VolatilityMath.decay(1e10, BUCKET)), "no move since: pure decay");
    }

    function test_liquidityChanges_doNotTouchHookState() public {
        _moveTo(hookKey, 100);
        _nextBlock(BUCKET);
        _swap(hookKey, true, -TINY);
        bytes32 h = _stateHash(hookId);
        _nextBlock(BUCKET);
        // add, remove and donate do not call the hook and do not move the tick
        modifyLiquidityRouter.modifyLiquidity(hookKey, ModifyLiquidityParams(-600, 600, 1e22, 0), ZERO_BYTES);
        modifyLiquidityRouter.modifyLiquidity(hookKey, ModifyLiquidityParams(-600, 600, -1e22, 0), ZERO_BYTES);
        modifyLiquidityRouter.modifyLiquidity(hookKey, ModifyLiquidityParams(WIDE_LOWER, WIDE_UPPER, -1e23, 0), ZERO_BYTES);
        donateRouter.donate(hookKey, 1e18, 1e18, ZERO_BYTES);
        assertEq(_stateHash(hookId), h);
        assertEq(_tick(hookKey), 100);
    }

    /// @dev Red line: the hook must never be able to block LPs from leaving. It has no liquidity
    ///      callbacks at all, so removal works at any fee level, including the cap.
    function test_removeAllLiquidity_atMaxFee() public {
        _moveTo(hookKey, 3000);
        _nextBlock(BUCKET);
        (, uint24 fee) = _swap(hookKey, true, -TINY);
        assertEq(fee, MAX_FEE);
        modifyLiquidityRouter.modifyLiquidity(
            hookKey, ModifyLiquidityParams(WIDE_LOWER, WIDE_UPPER, -WIDE_LIQUIDITY, 0), ZERO_BYTES
        );
        assertEq(manager.getLiquidity(hookId), 0);
    }

    // ------------------------------------------------------------------------------------------
    // Edges: zero liquidity, tick range ends, native ETH
    // ------------------------------------------------------------------------------------------

    /// @dev L-2. Until the hook has seen the pool with in-range liquidity, price moves are free (a swap
    ///      on an empty pool just walks to its limit) and are NOT counted: variance stays 0, fee at floor.
    function test_unarmed_zeroLiquidityPool_movesAreNotCounted() public {
        (Currency a, Currency b) = deployMintAndApprove2Currencies();
        (PoolKey memory k, PoolId id) = _initDynamicPool(a, b, TickMath.MIN_SQRT_PRICE + 1);
        assertEq(hook.poolState(id).lastLogPrice, int256(TickMath.MIN_TICK) * 1000);

        // No liquidity: a swap just walks the price to the limit and trades nothing.
        _nextBlock(BUCKET);
        (BalanceDelta d, uint24 fee) = _swap(k, false, -1e18);
        assertEq(BalanceDelta.unwrap(d), 0);
        assertEq(fee, MIN_FEE);
        assertEq(_tick(k), TickMath.MAX_TICK - 1);

        // Next buckets: the largest move a pool can show, twice. Still nothing accumulated.
        for (uint256 i; i < 2; i++) {
            _nextBlock(BUCKET);
            int32 seen = _logPrice(k);
            (, fee) = _swap(k, i == 0, -1e18);
            assertEq(hook.poolState(id).lastLogPrice, seen, "the anchor still follows the price");
            assertEq(fee, MIN_FEE);
            VolatilityFeeHook.PoolState memory s = hook.poolState(id);
            assertFalse(s.armed);
            assertEq(s.variance, 0);
            assertEq(s.lastTimestamp, block.timestamp, "observations still advance");
        }
    }

    /// @dev L-2, the audit's scenario: someone front-runs the pool creation with an absurd price. The
    ///      price is walked back for free on the empty pool, liquidity is added, and the pool starts at
    ///      the floor fee (before the fix: 1%, still 0.13% after 70 minutes).
    function test_frontRunInitialize_absurdPrice_thenCorrected_startsAtFloor() public {
        (Currency a, Currency b) = deployMintAndApprove2Currencies();
        (PoolKey memory k, PoolId id) = _initDynamicPool(a, b, TickMath.getSqrtPriceAtTick(200_000));

        _nextBlock(3); // same or later bucket: either way nothing is counted
        _moveToPrice(k, SQRT_PRICE_1_1); // free: no liquidity
        _addWideLiquidity(k);
        assertFalse(hook.poolState(id).armed);

        _nextBlock(BUCKET);
        assertEq(hook.currentFee(id), MIN_FEE);
        (, uint24 fee) = _swap(k, true, -1e18);
        assertEq(fee, MIN_FEE);
        VolatilityFeeHook.PoolState memory s = hook.poolState(id);
        assertTrue(s.armed);
        assertEq(s.variance, 0);
        assertEq(s.lastLogPrice, 0, "anchored at the corrected price, not at the absurd one");

        // from here on moves count as usual
        _moveTo(k, 100);
        _nextBlock(BUCKET);
        (, fee) = _swap(k, true, -TINY);
        assertEq(fee, 3000);
    }

    /// @dev arming needs IN-RANGE liquidity at an observation; a position away from the price is not enough
    function test_unarmed_outOfRangeLiquidityOnly_doesNotArm() public {
        (Currency a, Currency b) = deployMintAndApprove2Currencies();
        (PoolKey memory k, PoolId id) = _initDynamicPool(a, b, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(k, ModifyLiquidityParams(600, 1200, 1e22, 0), ZERO_BYTES);
        assertEq(manager.getLiquidity(id), 0);
        _nextBlock(BUCKET);
        _moveToPrice(k, TickMath.getSqrtPriceAtTick(-500));
        assertFalse(hook.poolState(id).armed);
        // the price is walked into the position: the next observation finds liquidity and arms
        _moveToPrice(k, _priceAtLog(900_000));
        _nextBlock(BUCKET);
        (, uint24 fee) = _swap(k, true, -TINY);
        assertEq(fee, MIN_FEE);
        assertTrue(hook.poolState(id).armed);
        assertEq(hook.poolState(id).variance, 0);
        assertEq(hook.poolState(id).lastLogPrice, 900_000);
    }

    /// @dev KNOWN RESIDUAL of L-2 (documented, not fixed): "has liquidity" cannot tell dust from real
    ///      liquidity. A griefer who initializes at an absurd price, adds a dust position and makes one
    ///      swap in a later bucket arms the pool at the absurd price; the correction then counts.
    ///      Cost: three transactions and dust. Effect: that one pool starts at up to 1% and decays.
    function test_unarmed_dustLiquidityArming_knownResidual() public {
        (Currency a, Currency b) = deployMintAndApprove2Currencies();
        (PoolKey memory k, PoolId id) = _initDynamicPool(a, b, TickMath.getSqrtPriceAtTick(60_000));
        modifyLiquidityRouter.modifyLiquidity(k, ModifyLiquidityParams(WIDE_LOWER, WIDE_UPPER, 1000, 0), ZERO_BYTES);
        _nextBlock(BUCKET);
        _swap(k, true, -1);
        assertTrue(hook.poolState(id).armed);

        _moveToPrice(k, SQRT_PRICE_1_1); // honest correction, through the dust
        _addWideLiquidity(k);
        _nextBlock(BUCKET);
        (, uint24 fee) = _swap(k, true, -TINY);
        assertEq(fee, MAX_FEE);
    }

    /// @dev the largest log-price difference a pool can show: no overflow, saturates at the cap
    function test_armedPool_fullRangeJump() public {
        (Currency a, Currency b) = deployMintAndApprove2Currencies();
        (PoolKey memory k, PoolId id) = _initDynamicPool(a, b, TickMath.MIN_SQRT_PRICE + 1);
        int24 lo = TickMath.minUsableTick(SPACING);
        int24 hi = TickMath.maxUsableTick(SPACING);
        // price starts just below the position: walk it in, then the liquidity is in range
        modifyLiquidityRouter.modifyLiquidity(k, ModifyLiquidityParams(lo, hi, 1000, 0), ZERO_BYTES);
        _moveToPrice(k, TickMath.getSqrtPriceAtTick(lo + 1));
        _nextBlock(BUCKET);
        _swap(k, false, -1e30); // arms; then runs through the whole range to the upper end
        assertTrue(hook.poolState(id).armed);
        assertEq(hook.poolState(id).lastLogPrice, int256(lo + 1) * 1000);
        assertEq(_tick(k), TickMath.MAX_TICK - 1);

        _nextBlock(BUCKET);
        (, uint24 fee) = _swap(k, true, -1e30);
        assertEq(fee, MAX_FEE);
        assertEq(hook.poolState(id).variance, VolatilityMath.VAR_CAP);
        assertEq(hook.poolState(id).lastLogPrice, VolatilityMath.logPrice(TickMath.MAX_SQRT_PRICE - 1));
        assertEq(_tick(k), TickMath.MIN_TICK);

        _nextBlock(BUCKET);
        (, fee) = _swap(k, false, -1e30);
        assertEq(fee, MAX_FEE);
        assertEq(hook.poolState(id).lastLogPrice, int256(TickMath.MIN_TICK) * 1000);
    }

    function test_nativeEthPool() public {
        (PoolKey memory k, PoolId id) = _initDynamicPool(CurrencyLibrary.ADDRESS_ZERO, currency1, SQRT_PRICE_1_1);
        vm.deal(address(this), 2_000_000 ether);
        _addWideLiquidity(k);
        _nextBlock(BUCKET);
        _moveTo(k, 0); // arms
        _moveTo(k, -100); // ETH in
        _nextBlock(BUCKET);
        vm.recordLogs();
        swapRouter.swap{value: 1 ether}(
            k,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        assertEq(_lastSwapFee(), 3000);
        (, uint24 fee) = _swap(k, false, -1e18); // ETH out
        assertEq(fee, 3000);
        assertEq(hook.poolState(id).variance, 1e10);
        assertEq(address(hook).balance, 0);
    }

    function test_hookHoldsNoFunds() public {
        _moveTo(hookKey, 250);
        _nextBlock(BUCKET);
        _assertAllFourCharge(500 + 25 * 250);
        assertEq(currency0.balanceOf(address(hook)), 0);
        assertEq(currency1.balanceOf(address(hook)), 0);
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0);
    }

    // ------------------------------------------------------------------------------------------
    // Fuzz: arbitrary cross-block paths follow the reference model exactly
    // ------------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 128
    function testFuzz_crossBucketPath_matchesModel(int32[8] memory logs, uint16[8] memory dts, bool[8] memory dirs)
        public
    {
        uint256 variance;
        int32 lastLog;
        uint256 lastTs = block.timestamp;
        uint24 expected = MIN_FEE;
        for (uint256 i; i < 8; i++) {
            // any milli-tick within +-3000 ticks, not only whole ticks
            int256 target = bound(logs[i], -3_000_000, 3_000_000);
            if (target != _logPrice(hookKey) || _sqrtPrice(hookKey) != _priceAtLog(target)) {
                _moveToLog(hookKey, target);
            }
            uint256 dt = bound(dts[i], 0, 3000);
            if (dts[i] % 4 == 0) dt = dt % BUCKET; // often stay in, or just leave, the current bucket
            _nextBlock(dt);

            if (block.timestamp / BUCKET > lastTs / BUCKET) {
                variance = VolatilityMath.accumulate(variance, block.timestamp - lastTs, lastLog, int32(target));
                lastLog = int32(target);
                lastTs = block.timestamp;
                expected = VolatilityMath.feeFromVariance(variance);
            }

            (, uint24 fee) = _swap(hookKey, dirs[i], -TINY);
            assertEq(fee, expected);
            assertGe(fee, MIN_FEE);
            assertLe(fee, MAX_FEE);
            VolatilityFeeHook.PoolState memory s = _state();
            assertEq(s.variance, variance);
            assertEq(s.lastLogPrice, lastLog);
            assertEq(s.lastTimestamp, lastTs);
            assertEq(s.fee, expected);
        }
    }
}
