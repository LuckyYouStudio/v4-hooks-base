// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ╔══════════════════════════════════════════════════════════════════════════════════════════════╗
// ║  故意有漏洞,禁止部署 —— INTENTIONALLY VULNERABLE, DO NOT DEPLOY.                             ║
// ║  Minimal model for testing the hook checker locally. Not a usable hook, not a template.      ║
// ╚══════════════════════════════════════════════════════════════════════════════════════════════╝
//
// Pattern (fact sheet §8.3 item 6: a revert in a callback is a pause switch): time-decay arithmetic that
// overflows once the pool has been idle long enough. The timestamp is only refreshed by a successful
// swap, so after the first overflow every swap reverts forever.
//
// The toy: beforeSwap keeps an activity score that halves every idle hour, computed as
// score / 2**hours. 2**hours overflows uint256 at 256 idle hours (about 11 days).
//
// Expected checker result: e = FAIL (Panic 0x11 in beforeSwap in the "time +400 days" scenario).

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "../../src/base/BaseHook.sol";

abstract contract ActivityScoreBase is BaseHook {
    using PoolIdLibrary for PoolKey;

    struct Activity {
        uint64 lastSwap;
        uint192 score;
    }

    mapping(PoolId => Activity) public activity;

    constructor(IPoolManager m) BaseHook(m) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeSwap = true;
    }

    function _maxHalvings() internal pure virtual returns (uint256);

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        Activity storage a = activity[key.toId()];
        uint256 idleHours = a.lastSwap == 0 ? 0 : (block.timestamp - a.lastSwap) / 1 hours;
        if (idleHours > _maxHalvings()) idleHours = _maxHalvings();
        uint256 decayed = uint256(a.score) / (2 ** idleHours); // overflows at idleHours >= 256
        a.score = uint192(decayed + 1e18);
        a.lastSwap = uint64(block.timestamp);
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}

/// @notice VULNERABLE: no bound on the exponent.
contract StaleOverflowHook is ActivityScoreBase {
    constructor(IPoolManager m) ActivityScoreBase(m) {}

    function _maxHalvings() internal pure override returns (uint256) {
        return type(uint256).max; // BUG
    }
}

/// @notice FIXED counterpart (still a toy, do not deploy): the exponent is capped.
contract StaleOverflowHookFixed is ActivityScoreBase {
    constructor(IPoolManager m) ActivityScoreBase(m) {}

    function _maxHalvings() internal pure override returns (uint256) {
        return 192;
    }
}
