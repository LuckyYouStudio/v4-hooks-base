// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ╔══════════════════════════════════════════════════════════════════════════════════════════════╗
// ║  故意有漏洞,禁止部署 —— INTENTIONALLY VULNERABLE, DO NOT DEPLOY.                             ║
// ║  Minimal model for testing the hook checker locally. Not a usable hook, not a template.      ║
// ╚══════════════════════════════════════════════════════════════════════════════════════════════╝
//
// Pattern (the "accounting direction" family of return-delta mistakes, fact sheet §6.3 / §6.4 / §8.2;
// an abstract model, NOT a reconstruction of Bunni or of any deployed protocol): afterSwap returns a
// delta in the UNSPECIFIED currency, which is currency1 in two of the four direction x exactIn/exactOut
// combinations and currency0 in the other two. A hook that sizes its fee from one fixed component of the
// swap delta is right in two combinations and charges an amount measured in the wrong token in the other
// two. Away from a 1:1 price that is a different number, and the hook takes more than its design says.
//
// The toy: a 0.10% hook fee on the unspecified currency, kept by the hook.
//
// Expected checker result: i = UNKNOWN with the hint "not uniform across the four combinations".
// The checker cannot call this a failure: it does not know the intended fee. See README, "漏报".

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "../../src/base/BaseHook.sol";

abstract contract HookFeeBase is BaseHook {
    using SafeCast for uint256;

    uint256 internal constant FEE_PPM = 1000; // 0.10%

    constructor(IPoolManager m) BaseHook(m) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.afterSwap = true;
        p.afterSwapReturnDelta = true;
    }

    function _abs(int128 x) internal pure returns (uint256) {
        return x < 0 ? uint256(uint128(-x)) : uint256(uint128(x));
    }

    /// @dev takes `fee` of the unspecified currency out of PoolManager and declares it as the hook's delta
    function _collect(PoolKey calldata key, SwapParams calldata params, uint256 fee) internal returns (bytes4, int128) {
        bool unspecifiedIs1 = (params.amountSpecified < 0) == params.zeroForOne;
        Currency c = unspecifiedIs1 ? key.currency1 : key.currency0;
        if (fee > 0) poolManager.take(c, address(this), fee);
        return (BaseHook.afterSwap.selector, fee.toInt128());
    }
}

/// @notice VULNERABLE: the fee is always sized from amount1, also when the unspecified currency (the one
///         it is charged in) is currency0.
contract WrongDeltaHook is HookFeeBase {
    constructor(IPoolManager m) HookFeeBase(m) {}

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        // BUG: "the other side" is assumed to be token1 in every case
        uint256 fee = _abs(delta.amount1()) * FEE_PPM / 1e6;
        return _collect(key, params, fee);
    }
}

/// @notice FIXED counterpart (still a toy, do not deploy): sized from the unspecified component.
contract WrongDeltaHookFixed is HookFeeBase {
    constructor(IPoolManager m) HookFeeBase(m) {}

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        bool unspecifiedIs1 = (params.amountSpecified < 0) == params.zeroForOne;
        uint256 fee = _abs(unspecifiedIs1 ? delta.amount1() : delta.amount0()) * FEE_PPM / 1e6;
        return _collect(key, params, fee);
    }
}
