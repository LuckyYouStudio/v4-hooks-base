// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {BaseHook} from "../../src/base/BaseHook.sol";

/// @notice Test-only "careless subclass": implements all ten callbacks by overriding BaseHook's internal
///         functions and writes NO access check of its own. Used to show that the caller check lives in
///         BaseHook's non-virtual entry points and cannot be lost by a subclass.
contract AllCallbacksMockHook is BaseHook {
    /// @dev number of callback bodies that actually ran
    uint256 public reached;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: true,
            afterDonate: true,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeInitialize(address, PoolKey calldata, uint160) internal override returns (bytes4) {
        reached++;
        return IHooks.beforeInitialize.selector;
    }

    function _afterInitialize(address, PoolKey calldata, uint160, int24) internal override returns (bytes4) {
        reached++;
        return IHooks.afterInitialize.selector;
    }

    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata) internal override returns (bytes4) {
        reached++;
        return IHooks.beforeAddLiquidity.selector;
    }

    function _afterAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata) internal override returns (bytes4, BalanceDelta) {
        reached++;
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata) internal override returns (bytes4) {
        reached++;
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function _afterRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata) internal override returns (bytes4, BalanceDelta) {
        reached++;
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        reached++;
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata) internal override returns (bytes4, int128) {
        reached++;
        return (IHooks.afterSwap.selector, 0);
    }

    function _beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) internal override returns (bytes4) {
        reached++;
        return IHooks.beforeDonate.selector;
    }

    function _afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) internal override returns (bytes4) {
        reached++;
        return IHooks.afterDonate.selector;
    }
}
