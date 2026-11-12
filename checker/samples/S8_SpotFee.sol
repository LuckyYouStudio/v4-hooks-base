// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ╔══════════════════════════════════════════════════════════════════════════════════════════════╗
// ║  故意有漏洞,禁止部署 —— INTENTIONALLY VULNERABLE, DO NOT DEPLOY.                             ║
// ║  Minimal model for testing the hook checker locally. Not a usable hook, not a template.      ║
// ╚══════════════════════════════════════════════════════════════════════════════════════════════╝
//
// Pattern (fact sheet §8.2 "动态费" and §8.3 item 5; the lesson of our own H1 audit): a dynamic fee
// computed from the pool's current tick, which one transaction can push away and back. Whoever goes
// first in a block sets the fee the next swap pays.
//
// The toy: fee = 0.05% + 0.001% per tick of distance between the current tick and the tick seen by the
// previous swap, capped at 5%.
//
// Expected checker result: f = UNKNOWN with the hint "the fee of an identical swap changes within one
// block". A hint by design: the checker does not judge whether that is exploitable.

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "../../src/base/BaseHook.sol";

abstract contract TickDistanceFeeBase is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint24 internal constant BASE_FEE = 500;
    uint24 internal constant PER_TICK = 10;
    uint24 internal constant MAX_FEE = 50_000;

    constructor(IPoolManager m) BaseHook(m) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeSwap = true;
    }

    function _tick(PoolKey calldata key) internal view returns (int24 tick) {
        (, tick,,) = poolManager.getSlot0(key.toId());
    }

    function _fee(int24 a, int24 b) internal pure returns (uint24) {
        uint256 distance = a > b ? uint256(int256(a) - int256(b)) : uint256(int256(b) - int256(a));
        uint256 fee = uint256(BASE_FEE) + distance * PER_TICK;
        return uint24(fee > MAX_FEE ? MAX_FEE : fee) | LPFeeLibrary.OVERRIDE_FEE_FLAG;
    }
}

/// @notice VULNERABLE: the reference tick is whatever the previous swap saw, including a swap earlier in
///         the same transaction.
contract SpotFeeHook is TickDistanceFeeBase {
    using PoolIdLibrary for PoolKey;

    mapping(PoolId => int24) public lastTick;
    mapping(PoolId => bool) public seen;

    constructor(IPoolManager m) TickDistanceFeeBase(m) {}

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        int24 nowTick = _tick(key);
        int24 ref = seen[id] ? lastTick[id] : nowTick;
        lastTick[id] = nowTick; // BUG: moved by every swap, so by the swap right before the victim's
        seen[id] = true;
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, _fee(nowTick, ref));
    }
}

/// @notice FIXED counterpart for the SAME-BLOCK part only (still a toy, do not deploy): the fee is the
///         distance between the opening ticks of the two most recent blocks that had a swap, so nothing
///         done inside a block changes the fee paid inside that block. Moving the price across a block
///         boundary still moves the fee; what that costs is an economic question (see the H1 audit).
contract SpotFeeHookFixed is TickDistanceFeeBase {
    using PoolIdLibrary for PoolKey;

    struct Opening {
        uint64 blockNumber;
        int24 open;
        int24 previousOpen;
    }

    mapping(PoolId => Opening) public opening;

    constructor(IPoolManager m) TickDistanceFeeBase(m) {}

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        Opening storage o = opening[key.toId()];
        if (o.blockNumber != block.number) {
            int24 nowTick = _tick(key);
            o.previousOpen = o.blockNumber == 0 ? nowTick : o.open;
            o.open = nowTick;
            o.blockNumber = uint64(block.number);
        }
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, _fee(o.open, o.previousOpen));
    }
}
