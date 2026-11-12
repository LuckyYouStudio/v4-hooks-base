// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

/// @notice TEST-ONLY minimal swap router with the slippage checks a real router has (minimum out for
///         exact-in, maximum in for exact-out). ERC-20 only. It stands in for a production router in the
///         tests that show what a quote/execution fee mismatch does to an integrator; it is NOT the
///         Universal Router and has not been reviewed for any other use.
contract CheckedSwapRouter is IUnlockCallback {
    using CurrencySettler for Currency;

    IPoolManager public immutable manager;

    error TooLittleReceived(uint256 minimumOut, uint256 amountOut);
    error TooMuchRequested(uint256 maximumIn, uint256 amountIn);
    error NotManager();

    struct Data {
        address payer;
        PoolKey key;
        bool zeroForOne;
        bool exactIn;
        uint256 amount;
        uint256 limit;
    }

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function swapExactIn(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 minimumOut)
        external
        returns (uint256 amountOut)
    {
        return abi.decode(
            manager.unlock(abi.encode(Data(msg.sender, key, zeroForOne, true, amountIn, minimumOut))), (uint256)
        );
    }

    function swapExactOut(PoolKey calldata key, bool zeroForOne, uint256 amountOut, uint256 maximumIn)
        external
        returns (uint256 amountIn)
    {
        return abi.decode(
            manager.unlock(abi.encode(Data(msg.sender, key, zeroForOne, false, amountOut, maximumIn))), (uint256)
        );
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotManager();
        Data memory d = abi.decode(raw, (Data));
        BalanceDelta delta = manager.swap(
            d.key,
            SwapParams({
                zeroForOne: d.zeroForOne,
                amountSpecified: d.exactIn ? -int256(d.amount) : int256(d.amount),
                sqrtPriceLimitX96: d.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        (int128 inDelta, int128 outDelta) =
            d.zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        uint256 amountIn = uint256(uint128(-inDelta));
        uint256 amountOut = uint256(uint128(outDelta));
        if (d.exactIn) {
            if (amountOut < d.limit) revert TooLittleReceived(d.limit, amountOut);
        } else {
            if (amountIn > d.limit) revert TooMuchRequested(d.limit, amountIn);
        }
        (Currency cIn, Currency cOut) =
            d.zeroForOne ? (d.key.currency0, d.key.currency1) : (d.key.currency1, d.key.currency0);
        cIn.settle(manager, d.payer, amountIn, false);
        cOut.take(manager, d.payer, amountOut, false);
        return abi.encode(d.exactIn ? amountOut : amountIn);
    }
}
