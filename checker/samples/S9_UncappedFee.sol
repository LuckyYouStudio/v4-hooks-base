// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ╔══════════════════════════════════════════════════════════════════════════════════════════════╗
// ║  故意有漏洞,禁止部署 —— INTENTIONALLY VULNERABLE, DO NOT DEPLOY.                             ║
// ║  Minimal model for testing the hook checker locally. Not a usable hook, not a template.      ║
// ╚══════════════════════════════════════════════════════════════════════════════════════════════╝
//
// Pattern (fact sheet §5.2 / §5.3): a dynamic fee without an upper bound. Once the hook returns an
// override above 1,000,000 pips PoolManager reverts the swap with LPFeeTooLarge; if the input that drove
// the fee up is only reset by a successful swap, the pool is stuck.
//
// The toy: an "idle surcharge": fee = 0.30% x (1 + hours since the last swap).
//
// Expected checker result: f = FAIL (LP fee above 100%), e = FAIL (swaps revert in "time +400 days").

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "../../src/base/BaseHook.sol";

abstract contract IdleSurchargeBase is BaseHook {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant BASE_FEE = 3000;

    mapping(PoolId => uint256) public lastSwap;

    constructor(IPoolManager m) BaseHook(m) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeSwap = true;
    }

    function _cap() internal pure virtual returns (uint256);

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        uint256 last = lastSwap[id];
        uint256 idleHours = last == 0 ? 0 : (block.timestamp - last) / 1 hours;
        uint256 fee = BASE_FEE * (1 + idleHours);
        if (fee > _cap()) fee = _cap();
        lastSwap[id] = block.timestamp;
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, uint24(fee) | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }
}

/// @notice VULNERABLE: the only bound is "fits the uint24 below the flag bits".
contract UncappedFeeHook is IdleSurchargeBase {
    constructor(IPoolManager m) IdleSurchargeBase(m) {}

    function _cap() internal pure override returns (uint256) {
        return 0x3FFFFF; // BUG: about 419%
    }
}

/// @notice FIXED counterpart (still a toy, do not deploy): hard cap at 1%.
contract UncappedFeeHookFixed is IdleSurchargeBase {
    constructor(IPoolManager m) IdleSurchargeBase(m) {}

    function _cap() internal pure override returns (uint256) {
        return 10_000;
    }
}
