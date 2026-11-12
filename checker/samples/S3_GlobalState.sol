// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ╔══════════════════════════════════════════════════════════════════════════════════════════════╗
// ║  故意有漏洞,禁止部署 —— INTENTIONALLY VULNERABLE, DO NOT DEPLOY.                             ║
// ║  Minimal model for testing the hook checker locally. Not a usable hook, not a template.      ║
// ╚══════════════════════════════════════════════════════════════════════════════════════════════╝
//
// Pattern (fact sheet §8.1): anyone can initialize a pool that names any hook address. A hook that keeps
// its state in one contract-level variable instead of per PoolId lets a stranger's pool (worthless
// tokens, any price) rewrite the state every other pool on the hook runs on.
//
// The toy: a "volume tier" dynamic fee. Once cumulative volume passes a threshold the LP fee drops from
// 0.30% to 0.05%. Volume is one global counter, so a stranger pumps it with junk tokens in his own pool
// and every pool's LPs are moved to the low tier.
//
// Expected checker result: c = FAIL (reference swaps in the pool under test change after the stranger
// pool's activity).

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "../../src/base/BaseHook.sol";

abstract contract VolumeTierBase is BaseHook {
    uint24 internal constant HIGH_FEE = 3000;
    uint24 internal constant LOW_FEE = 500;
    uint256 internal constant TIER_VOLUME = 1e24;

    constructor(IPoolManager m) BaseHook(m) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeSwap = true;
    }

    function _size(SwapParams calldata params) internal pure returns (uint256) {
        return params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
    }

    function _answer(uint256 volumeBefore) internal pure returns (bytes4, BeforeSwapDelta, uint24) {
        uint24 fee = volumeBefore >= TIER_VOLUME ? LOW_FEE : HIGH_FEE;
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }
}

/// @notice VULNERABLE: one volume counter for all pools.
contract GlobalStateHook is VolumeTierBase {
    uint256 public volume; // BUG: shared by every pool that names this hook

    constructor(IPoolManager m) VolumeTierBase(m) {}

    function _beforeSwap(address, PoolKey calldata, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint256 before = volume;
        volume = before + _size(params);
        return _answer(before);
    }
}

/// @notice FIXED counterpart for THIS issue only (still a toy, do not deploy): volume is kept per PoolId.
///         Counting the requested size as volume stays naive on purpose.
contract GlobalStateHookFixed is VolumeTierBase {
    using PoolIdLibrary for PoolKey;

    mapping(PoolId => uint256) public volume;

    constructor(IPoolManager m) VolumeTierBase(m) {}

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        uint256 before = volume[id];
        volume[id] = before + _size(params);
        return _answer(before);
    }
}
