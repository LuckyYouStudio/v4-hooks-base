// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @notice Test-only contract whose claimed permissions are an arbitrary 14-bit flag set given at
///         construction. Like a real hook, its constructor reverts unless its own address encodes them.
contract PermissionsMockHook {
    uint160 public immutable flags;

    constructor(uint160 _flags) {
        flags = _flags;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    function getHookPermissions() public view returns (Hooks.Permissions memory) {
        uint160 f = flags;
        return Hooks.Permissions({
            beforeInitialize: f & Hooks.BEFORE_INITIALIZE_FLAG != 0,
            afterInitialize: f & Hooks.AFTER_INITIALIZE_FLAG != 0,
            beforeAddLiquidity: f & Hooks.BEFORE_ADD_LIQUIDITY_FLAG != 0,
            afterAddLiquidity: f & Hooks.AFTER_ADD_LIQUIDITY_FLAG != 0,
            beforeRemoveLiquidity: f & Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG != 0,
            afterRemoveLiquidity: f & Hooks.AFTER_REMOVE_LIQUIDITY_FLAG != 0,
            beforeSwap: f & Hooks.BEFORE_SWAP_FLAG != 0,
            afterSwap: f & Hooks.AFTER_SWAP_FLAG != 0,
            beforeDonate: f & Hooks.BEFORE_DONATE_FLAG != 0,
            afterDonate: f & Hooks.AFTER_DONATE_FLAG != 0,
            beforeSwapReturnDelta: f & Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG != 0,
            afterSwapReturnDelta: f & Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG != 0,
            afterAddLiquidityReturnDelta: f & Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG != 0,
            afterRemoveLiquidityReturnDelta: f & Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG != 0
        });
    }
}
