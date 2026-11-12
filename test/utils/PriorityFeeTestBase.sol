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
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {PriorityFeeHook} from "../../src/PriorityFeeHook.sol";

/// @notice Shared fixture for PriorityFeeHook: fresh local PoolManager + v4-core test routers, a mined
///         hook, one dynamic-fee pool with wide, deep liquidity at price 1, and helpers to set the
///         transaction's gas price / the block's base fee the way the EVM would report them.
/// @dev The expected fee schedule is restated here from the design note (NOT imported from
///      PriorityFeeMath), so a wrong constant or formula in the library fails the tests.
abstract contract PriorityFeeTestBase is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant HOOK_FLAGS = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);

    int24 internal constant SPACING = 60;
    int24 internal constant WIDE_LOWER = -120_000;
    int24 internal constant WIDE_UPPER = 120_000;
    int256 internal constant WIDE_LIQUIDITY = 1e24;

    // ---- the schedule, restated independently ----
    uint24 internal constant MIN_FEE = 500;
    uint24 internal constant MAX_FEE = 3000;
    uint256 internal constant ALLOWANCE = 20_000_000; // 0.02 gwei
    uint256 internal constant WEI_PER_PIP = 400_000;
    /// @dev smallest priority fee that is charged MAX_FEE: 0.02 gwei + 2500 * 0.0004 gwei = 1.02 gwei
    uint256 internal constant TIP_AT_CAP = 1_020_000_000;

    /// @dev Base's minimum base fee on 2026-11-11 (docs/research/base-priority-ordering-for-hooks.md 2.10)
    uint256 internal constant BASEFEE = 5_000_000;

    PriorityFeeHook internal hook;
    PoolKey internal hookKey;
    PoolId internal hookId;

    function _baseSetUp() internal {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        hook = _deployHook(manager);
        (hookKey, hookId) = _initDynamicPool(currency0, currency1, SQRT_PRICE_1_1);
        _addLiquidity(hookKey, WIDE_LOWER, WIDE_UPPER, WIDE_LIQUIDITY, 0);
        _setTip(0);
    }

    function _deployHook(IPoolManager m) internal returns (PriorityFeeHook h) {
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(PriorityFeeHook).creationCode, abi.encode(m));
        h = new PriorityFeeHook{salt: salt}(m);
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

    /// @dev hookless static-fee pool on the same pair, same spacing; `fee` makes it a distinct pool
    function _initStaticPool(Currency c0, Currency c1, uint24 fee, uint160 sqrtPriceX96)
        internal
        returns (PoolKey memory k)
    {
        k = PoolKey(c0, c1, fee, SPACING, IHooks(address(0)));
        manager.initialize(k, sqrtPriceX96);
    }

    function _addLiquidity(PoolKey memory k, int24 lower, int24 upper, int256 liquidity, uint256 salt)
        internal
        returns (BalanceDelta delta)
    {
        uint256 value = k.currency0.isAddressZero() ? 1_000_000 ether : 0;
        delta = modifyLiquidityRouter.modifyLiquidity{value: value}(
            k,
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: liquidity, salt: bytes32(salt)}),
            ZERO_BYTES
        );
    }

    /// @dev fees owed to the position are paid out by a zero-liquidity modify (returned as the delta)
    function _collect(PoolKey memory k, int24 lower, int24 upper, uint256 salt) internal returns (BalanceDelta) {
        return _addLiquidity(k, lower, upper, 0, salt);
    }

    // ---- transaction environment ----

    /// @dev what a type-2 transaction with enough max fee reports: gas price = base fee + tip
    function _setTip(uint256 tip) internal {
        vm.fee(BASEFEE);
        vm.txGasPrice(BASEFEE + tip);
    }

    function _setGas(uint256 gasPrice, uint256 baseFee) internal {
        vm.fee(baseFee);
        vm.txGasPrice(gasPrice);
    }

    // ---- expected values, restated ----

    function _expectedFee(uint256 tip) internal pure returns (uint24) {
        if (tip <= ALLOWANCE) return MIN_FEE;
        uint256 extra = (tip - ALLOWANCE) / WEI_PER_PIP;
        if (extra > MAX_FEE - MIN_FEE) extra = MAX_FEE - MIN_FEE;
        return uint24(MIN_FEE + extra);
    }

    function _expectedFee(uint256 gasPrice, uint256 baseFee) internal pure returns (uint24) {
        return _expectedFee(gasPrice > baseFee ? gasPrice - baseFee : 0);
    }

    /// @dev what PoolManager charges in total: protocol fee first, LP fee on the remainder
    ///      (independent restatement of ProtocolFeeLibrary.calculateSwapFee)
    function _totalFee(uint24 protocolFee, uint24 lpFee) internal pure returns (uint24) {
        return uint24(uint256(protocolFee) + lpFee - (uint256(protocolFee) * lpFee) / 1e6);
    }

    // ---- swaps ----

    /// @notice Swap with no price limit; returns the delta and the total fee in PoolManager's Swap event.
    function _swap(PoolKey memory k, bool zeroForOne, int256 amountSpecified)
        internal
        returns (BalanceDelta delta, uint24 fee)
    {
        return _swapTo(k, zeroForOne, amountSpecified, zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT);
    }

    function _swapTo(PoolKey memory k, bool zeroForOne, int256 amountSpecified, uint160 limit)
        internal
        returns (BalanceDelta delta, uint24 fee)
    {
        uint256 value = zeroForOne && k.currency0.isAddressZero() ? 100_000 ether : 0;
        vm.recordLogs();
        delta = swapRouter.swap{value: value}(
            k,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        fee = _lastSwapFee();
    }

    function _lastSwapFee() internal view returns (uint24 fee) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; i++) {
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

    function _sqrtPrice(PoolKey memory k) internal view returns (uint160 p) {
        (p,,,) = manager.getSlot0(k.toId());
    }

    function _storedLpFee(PoolKey memory k) internal view returns (uint24 lpFee) {
        (,,, lpFee) = manager.getSlot0(k.toId());
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
