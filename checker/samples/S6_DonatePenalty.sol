// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ╔══════════════════════════════════════════════════════════════════════════════════════════════╗
// ║  故意有漏洞,禁止部署 —— INTENTIONALLY VULNERABLE, DO NOT DEPLOY.                             ║
// ║  Minimal model for testing the hook checker locally. Not a usable hook, not a template.      ║
// ╚══════════════════════════════════════════════════════════════════════════════════════════════╝
//
// Pattern (fact sheet §8.3 item 1 and §8.2: `donate` reverts when in-range liquidity is zero): an exit
// penalty that is "donated back to the pool" in afterRemoveLiquidity. When the leaving LP is the last
// one in range, or the price sits outside every position, there is nobody to donate to, donate reverts,
// the callback reverts, and the withdrawal with it. The last LP cannot leave.
//
// The toy: 1% of the withdrawn principal is donated to the LPs that stay.
//
// Expected checker result: d = FAIL (last LP out; any withdrawal while the price is out of range).

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "../../src/base/BaseHook.sol";

abstract contract ExitPenaltyBase is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    constructor(IPoolManager m) BaseHook(m) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.afterRemoveLiquidity = true;
        p.afterRemoveLiquidityReturnDelta = true;
    }

    /// @dev whether to skip the penalty when nobody is in range to receive it
    function _skipWhenNobodyInRange() internal pure virtual returns (bool);

    function _afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        // liquidityDelta == 0 is a fee collection, not an exit (fact sheet §4.3 / §8.3 item 2)
        if (params.liquidityDelta == 0) return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
        int128 principal0 = delta.amount0() - feesAccrued.amount0();
        int128 principal1 = delta.amount1() - feesAccrued.amount1();
        int128 pen0 = principal0 > 0 ? principal0 / 100 : int128(0);
        int128 pen1 = principal1 > 0 ? principal1 / 100 : int128(0);
        if (pen0 == 0 && pen1 == 0) return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
        if (_skipWhenNobodyInRange() && poolManager.getLiquidity(key.toId()) == 0) {
            return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
        }
        // the hook owes the donation (-pen) and takes the same amount from the leaving LP (+pen): nets to 0
        poolManager.donate(key, uint256(uint128(pen0)), uint256(uint128(pen1)), "");
        return (BaseHook.afterRemoveLiquidity.selector, toBalanceDelta(pen0, pen1));
    }
}

/// @notice VULNERABLE: always donates.
contract DonatePenaltyHook is ExitPenaltyBase {
    constructor(IPoolManager m) ExitPenaltyBase(m) {}

    function _skipWhenNobodyInRange() internal pure override returns (bool) {
        return false; // BUG
    }
}

/// @notice FIXED counterpart (still a toy, do not deploy): no penalty when no in-range liquidity is left
///         to receive it, so the withdrawal always goes through.
contract DonatePenaltyHookFixed is ExitPenaltyBase {
    constructor(IPoolManager m) ExitPenaltyBase(m) {}

    function _skipWhenNobodyInRange() internal pure override returns (bool) {
        return true;
    }
}
