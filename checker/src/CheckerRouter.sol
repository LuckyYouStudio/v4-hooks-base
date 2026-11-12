// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title CheckerRouter
/// @notice The actor the checker uses to talk to a PoolManager in LOCAL SIMULATION (forge test, local
///         or forked state). It holds the test funds itself, performs one PoolManager operation per
///         call and then settles whatever deltas it ended up with, whatever their sign. Unlike v4-core's
///         test routers it asserts nothing about the shape of the result, so a hook that takes a fee
///         through return deltas does not trip a router `require` and get blamed for it.
/// @dev Test tooling. Only its deployer (the checker) can use it. Not meant for, and never deployed to,
///      a public network.
contract CheckerRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    address public immutable owner;

    error NotOwner();
    error NotManager();

    enum Op {
        MODIFY,
        SWAP,
        DONATE
    }

    constructor(IPoolManager _manager) {
        manager = _manager;
        owner = msg.sender;
    }

    receive() external payable {}

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice `PoolManager.initialize` with this router as the pool creator.
    function initialize(PoolKey calldata key, uint160 sqrtPriceX96) external onlyOwner returns (int24 tick) {
        return manager.initialize(key, sqrtPriceX96);
    }

    /// @return callerDelta what this router owed / was owed for the operation (after the hook's delta)
    /// @return feesAccrued the fee part, as reported by PoolManager
    function modifyLiquidity(PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata hookData)
        external
        onlyOwner
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        bytes memory out = manager.unlock(abi.encode(Op.MODIFY, key, abi.encode(params), hookData));
        (callerDelta, feesAccrued) = abi.decode(out, (BalanceDelta, BalanceDelta));
    }

    function swap(PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        onlyOwner
        returns (BalanceDelta callerDelta)
    {
        bytes memory out = manager.unlock(abi.encode(Op.SWAP, key, abi.encode(params), hookData));
        (callerDelta,) = abi.decode(out, (BalanceDelta, BalanceDelta));
    }

    function donate(PoolKey calldata key, uint256 amount0, uint256 amount1, bytes calldata hookData)
        external
        onlyOwner
        returns (BalanceDelta callerDelta)
    {
        bytes memory out = manager.unlock(abi.encode(Op.DONATE, key, abi.encode(amount0, amount1), hookData));
        (callerDelta,) = abi.decode(out, (BalanceDelta, BalanceDelta));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotManager();
        (Op op, PoolKey memory key, bytes memory args, bytes memory hookData) =
            abi.decode(raw, (Op, PoolKey, bytes, bytes));

        BalanceDelta a;
        BalanceDelta b;
        if (op == Op.MODIFY) {
            (a, b) = manager.modifyLiquidity(key, abi.decode(args, (ModifyLiquidityParams)), hookData);
        } else if (op == Op.SWAP) {
            a = manager.swap(key, abi.decode(args, (SwapParams)), hookData);
        } else {
            (uint256 amount0, uint256 amount1) = abi.decode(args, (uint256, uint256));
            a = manager.donate(key, amount0, amount1, hookData);
        }
        _clear(key.currency0);
        _clear(key.currency1);
        return abi.encode(a, b);
    }

    /// @dev Pays or collects this router's whole delta in `currency`, read back from PoolManager rather
    ///      than derived from the operation's return value.
    function _clear(Currency currency) private {
        int256 delta = manager.currencyDelta(address(this), currency);
        if (delta > 0) {
            manager.take(currency, address(this), uint256(delta));
        } else if (delta < 0) {
            uint256 amount = uint256(-delta);
            if (currency.isAddressZero()) {
                manager.settle{value: amount}();
            } else {
                manager.sync(currency);
                // low-level: tokens without a return value, and tokens that return false, both end up
                // judged by what PoolManager actually received in settle()
                (bool ok,) =
                    Currency.unwrap(currency).call(abi.encodeWithSignature("transfer(address,uint256)", manager, amount));
                ok;
                manager.settle();
            }
        }
    }
}
