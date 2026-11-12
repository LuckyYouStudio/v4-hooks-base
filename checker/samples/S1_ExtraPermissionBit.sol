// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ╔══════════════════════════════════════════════════════════════════════════════════════════════╗
// ║  故意有漏洞,禁止部署 —— INTENTIONALLY VULNERABLE, DO NOT DEPLOY.                             ║
// ║  Minimal model for testing the hook checker locally. Not a usable hook, not a template.      ║
// ╚══════════════════════════════════════════════════════════════════════════════════════════════╝
//
// Pattern: the hook address was mined with one permission bit too many (BEFORE_REMOVE_LIQUIDITY) and the
// contract neither implements that callback nor checks its own address. PoolManager only checks the
// return-delta pairings at initialize (fact sheet §3.2), so the pool can be created and funded; every
// later modifyLiquidity with liquidityDelta <= 0 calls a function that does not exist and reverts.
// Liquidity can be added and never removed. (H1 re-audit N-4; fact sheet §3.2 "要点" 1.)
//
// Expected checker result: a = FAIL (declared but not usable, remove-liquidity), d = FAIL.

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @notice VULNERABLE. Meant to live at an address with BEFORE_SWAP only; the sample is deployed at an
///         address that also has BEFORE_REMOVE_LIQUIDITY set.
contract ExtraBitHook {
    IPoolManager public immutable poolManager;

    error NotPoolManager();

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
        // BUG: no Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions())
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeSwap = true;
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        view
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}

/// @notice FIXED counterpart (still a toy, do not deploy): the constructor requires the address to
///         encode exactly getHookPermissions(), so the contract cannot exist at an address with an
///         extra bit.
contract ExtraBitHookFixed {
    IPoolManager public immutable poolManager;

    error NotPoolManager();

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeSwap = true;
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        view
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}
