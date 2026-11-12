// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title BaseHook
/// @notice Minimal base for the hooks in this repo (the pinned v4-periphery no longer ships one).
///         - every IHooks entry point is external, NOT virtual and `onlyPoolManager`; it forwards to an
///           `_xxx(...) internal virtual` function. A hook overrides the internal function only, so it
///           cannot drop the caller check by forgetting a modifier (modifiers are not inherited by
///           overrides) and it cannot replace the guarded entry point;
///         - internal callbacks a hook does not override revert with HookNotImplemented;
///         - the constructor checks that the PoolManager address has code and that the deployed hook
///           address encodes exactly getHookPermissions().
/// @dev No owner, no upgrade path, no storage.
abstract contract BaseHook is IHooks {
    IPoolManager public immutable poolManager;

    error NotPoolManager();
    error HookNotImplemented();
    /// @notice The constructor argument is not a deployed contract (zero address, EOA, wrong chain).
    error PoolManagerHasNoCode();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager _poolManager) {
        if (address(_poolManager).code.length == 0) revert PoolManagerHasNoCode();
        poolManager = _poolManager;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    /// @notice The callbacks this hook implements. Must match the low 14 bits of the hook address exactly.
    function getHookPermissions() public pure virtual returns (Hooks.Permissions memory);

    // ---------------------------------------------------------------------------------------------
    // External entry points: fixed, guarded. Do not make these virtual.
    // ---------------------------------------------------------------------------------------------

    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        onlyPoolManager
        returns (bytes4)
    {
        return _beforeInitialize(sender, key, sqrtPriceX96);
    }

    function afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        external
        onlyPoolManager
        returns (bytes4)
    {
        return _afterInitialize(sender, key, sqrtPriceX96, tick);
    }

    function beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata hookData)
        external
        onlyPoolManager
        returns (bytes4)
    {
        return _beforeAddLiquidity(sender, key, params, hookData);
    }

    function afterAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata params, BalanceDelta delta, BalanceDelta feesAccrued, bytes calldata hookData)
        external
        onlyPoolManager
        returns (bytes4, BalanceDelta)
    {
        return _afterAddLiquidity(sender, key, params, delta, feesAccrued, hookData);
    }

    function beforeRemoveLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata hookData)
        external
        onlyPoolManager
        returns (bytes4)
    {
        return _beforeRemoveLiquidity(sender, key, params, hookData);
    }

    function afterRemoveLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata params, BalanceDelta delta, BalanceDelta feesAccrued, bytes calldata hookData)
        external
        onlyPoolManager
        returns (bytes4, BalanceDelta)
    {
        return _afterRemoveLiquidity(sender, key, params, delta, feesAccrued, hookData);
    }

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return _beforeSwap(sender, key, params, hookData);
    }

    function afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata hookData)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        return _afterSwap(sender, key, params, delta, hookData);
    }

    function beforeDonate(address sender, PoolKey calldata key, uint256 amount0, uint256 amount1, bytes calldata hookData)
        external
        onlyPoolManager
        returns (bytes4)
    {
        return _beforeDonate(sender, key, amount0, amount1, hookData);
    }

    function afterDonate(address sender, PoolKey calldata key, uint256 amount0, uint256 amount1, bytes calldata hookData)
        external
        onlyPoolManager
        returns (bytes4)
    {
        return _afterDonate(sender, key, amount0, amount1, hookData);
    }

    // ---------------------------------------------------------------------------------------------
    // Internal callbacks: override the ones declared in getHookPermissions(). Only ever reached from
    // the guarded entry points above, i.e. msg.sender is the PoolManager.
    // ---------------------------------------------------------------------------------------------

    function _beforeInitialize(address, PoolKey calldata, uint160)
        internal
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function _afterInitialize(address, PoolKey calldata, uint160, int24)
        internal
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function _afterAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        internal
        virtual
        returns (bytes4, BalanceDelta)
    {
        revert HookNotImplemented();
    }

    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function _afterRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        internal
        virtual
        returns (bytes4, BalanceDelta)
    {
        revert HookNotImplemented();
    }

    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        virtual
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert HookNotImplemented();
    }

    function _afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        virtual
        returns (bytes4, int128)
    {
        revert HookNotImplemented();
    }

    function _beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        internal
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function _afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        internal
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}
