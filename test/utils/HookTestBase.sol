// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {VolatilityFeeHook} from "../../src/VolatilityFeeHook.sol";
import {VolatilityMath} from "../../src/libraries/VolatilityMath.sol";

/// @notice Shared fixture: fresh local PoolManager + v4-core test routers (Deployers), a mined
///         VolatilityFeeHook, and one dynamic-fee pool with wide, deep liquidity that is already ARMED
///         (the hook has seen it with liquidity once) and sits at log price 0, in the middle of a
///         milli-tick, at the start of a time bucket.
abstract contract HookTestBase is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant HOOK_FLAGS = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);

    int24 internal constant SPACING = 60;
    int24 internal constant WIDE_LOWER = -120_000;
    int24 internal constant WIDE_UPPER = 120_000;
    int256 internal constant WIDE_LIQUIDITY = 1e24;
    /// @dev moves the price of the WIDE_LIQUIDITY pool by ~0.02 milli-ticks: a few of them do not change
    ///      the hook's log price when the price sits mid-milli-tick (see _moveTo)
    int256 internal constant TINY = 1e15;
    uint256 internal constant BUCKET = 10;
    /// @dev a multiple of BUCKET, so `_nextBlock(BUCKET)` always lands on the first second of a bucket
    uint256 internal constant T0 = 1_700_000_000;

    uint24 internal constant MIN_FEE = 500;
    uint24 internal constant MAX_FEE = 10_000;

    VolatilityFeeHook internal hook;
    PoolKey internal hookKey;
    PoolId internal hookId;
    uint256 internal lastFeeUpdates;

    function _baseSetUp() internal {
        vm.warp(T0);
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        hook = _deployHook(manager);
        (hookKey, hookId) = _initDynamicPool(currency0, currency1, SQRT_PRICE_1_1);
        _addWideLiquidity(hookKey);
        _arm(hookKey);
    }

    /// @dev next bucket; one swap that the hook sees with liquidity (arms the pool) and that parks the
    ///      price mid-milli-tick at the tick it was on. Variance is 0 and the fee is the floor afterwards.
    function _arm(PoolKey memory k) internal {
        int32 x = _logPrice(k);
        _nextBlock(BUCKET);
        _moveToPrice(k, _priceAtLog(x));
        VolatilityFeeHook.PoolState memory s = hook.poolState(k.toId());
        assertTrue(s.armed, "arm");
        assertEq(s.variance, 0, "arm: variance");
        assertEq(s.lastLogPrice, x, "arm: anchor");
    }

    function _deployHook(IPoolManager m) internal returns (VolatilityFeeHook h) {
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(VolatilityFeeHook).creationCode, abi.encode(m));
        h = new VolatilityFeeHook{salt: salt}(m);
        assertEq(address(h), expected, "mined address");
    }

    function _initDynamicPool(Currency c0, Currency c1, uint160 sqrtPriceX96)
        internal
        returns (PoolKey memory k, PoolId id)
    {
        k = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, SPACING, IHooks(address(hook)));
        id = k.toId();
        manager.initialize(k, sqrtPriceX96);
    }

    function _addWideLiquidity(PoolKey memory k) internal {
        uint256 value = k.currency0.isAddressZero() ? 1_000_000 ether : 0;
        modifyLiquidityRouter.modifyLiquidity{value: value}(
            k,
            ModifyLiquidityParams({
                tickLower: WIDE_LOWER,
                tickUpper: WIDE_UPPER,
                liquidityDelta: WIDE_LIQUIDITY,
                salt: 0
            }),
            ZERO_BYTES
        );
    }

    function _nextBlock(uint256 dt) internal {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + dt);
    }

    function _tick(PoolKey memory k) internal view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(k.toId());
    }

    function _sqrtPrice(PoolKey memory k) internal view returns (uint160 p) {
        (p,,,) = manager.getSlot0(k.toId());
    }

    /// @dev what the hook would read as the pool's log price right now (milli-ticks)
    function _logPrice(PoolKey memory k) internal view returns (int32) {
        return VolatilityMath.logPrice(_sqrtPrice(k));
    }

    /// @dev a sqrt price whose log price is exactly `milli` milli-ticks and that sits in the MIDDLE of
    ///      that milli-tick, so that tiny follow-up swaps do not change the hook's reading
    function _priceAtLog(int256 milli) internal pure returns (uint160 p) {
        int256 tick = milli / 1000;
        int256 frac = milli % 1000;
        if (frac < 0) {
            tick -= 1;
            frac += 1000;
        }
        uint256 lo = TickMath.getSqrtPriceAtTick(int24(tick));
        uint256 hi = TickMath.getSqrtPriceAtTick(int24(tick) + 1);
        p = uint160(lo + ((hi - lo) * (2 * uint256(frac) + 1)) / 2000);
        require(VolatilityMath.logPrice(p) == milli, "priceAtLog");
    }

    /// @notice Swap (through the hook) until the hook's log price of the pool is exactly `targetTick`
    ///         ticks (targetTick * 1000 milli-ticks), mid-milli-tick.
    function _moveTo(PoolKey memory k, int24 targetTick) internal returns (BalanceDelta delta, uint24 fee) {
        (delta, fee) = _moveToPrice(k, _priceAtLog(int256(targetTick) * 1000));
        assertEq(_tick(k), targetTick, "moveTo: tick");
        assertEq(_logPrice(k), int256(targetTick) * 1000, "moveTo: log price");
    }

    /// @notice Same with milli-tick resolution.
    function _moveToLog(PoolKey memory k, int256 milli) internal returns (BalanceDelta delta, uint24 fee) {
        (delta, fee) = _moveToPrice(k, _priceAtLog(milli));
    }

    function _moveToPrice(PoolKey memory k, uint160 target) internal returns (BalanceDelta delta, uint24 fee) {
        uint160 current = _sqrtPrice(k);
        require(current != target, "moveTo: already there");
        bool zeroForOne = target < current;
        vm.recordLogs();
        delta = swapRouter.swap{value: zeroForOne && k.currency0.isAddressZero() ? 100_000 ether : 0}(
            k,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -1e30, sqrtPriceLimitX96: target}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        fee = _lastSwapFee();
        assertEq(_sqrtPrice(k), target, "moveTo: price");
    }

    /// @notice Swap with no price limit and return the fee the PoolManager reports in its Swap event.
    function _swap(PoolKey memory k, bool zeroForOne, int256 amountSpecified)
        internal
        returns (BalanceDelta delta, uint24 fee)
    {
        vm.recordLogs();
        delta = swap(k, zeroForOne, amountSpecified, ZERO_BYTES);
        fee = _lastSwapFee();
    }

    /// @dev also counts the hook's FeeUpdated events in the same recording into `lastFeeUpdates`
    function _lastSwapFee() internal returns (uint24 fee) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        lastFeeUpdates = 0;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == VolatilityFeeHook.FeeUpdated.selector) {
                lastFeeUpdates++;
            }
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == IPoolManager.Swap.selector) {
                (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                found = true;
            }
        }
        assertTrue(found, "no Swap event");
    }

    /// @dev protocol fee in pips (max 1000 each way), set by the protocol fee controller
    function _setProtocolFee(PoolKey memory k, uint24 zeroForOne, uint24 oneForZero) internal {
        vm.prank(feeController);
        manager.setProtocolFee(k, (oneForZero << 12) | zeroForOne);
    }

    /// @dev what PoolManager charges in total: protocol fee first, LP fee on the remainder
    ///      (independent restatement of ProtocolFeeLibrary.calculateSwapFee)
    function _totalFee(uint24 protocolFee, uint24 lpFee) internal pure returns (uint24) {
        return uint24(uint256(protocolFee) + lpFee - (uint256(protocolFee) * lpFee) / 1e6);
    }

    function _state() internal view returns (VolatilityFeeHook.PoolState memory) {
        return hook.poolState(hookId);
    }

    function _stateHash(PoolId id) internal view returns (bytes32) {
        return keccak256(abi.encode(hook.poolState(id)));
    }

    /// @dev PoolManager wraps hook reverts as ERC-7751 WrappedError(target, selector, reason, details)
    function _wrapped(bytes4 hookSelector, bytes4 reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            hookSelector,
            abi.encodeWithSelector(reason),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }
}
