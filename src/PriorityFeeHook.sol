// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {BaseHook} from "./base/BaseHook.sol";
import {PriorityFeeMath} from "./libraries/PriorityFeeMath.sol";

/// @title PriorityFeeHook
/// @notice Uniswap v4 hook for chains that order transactions by priority fee (Base): the LP fee of a
///         swap rises with the priority fee of the transaction that carries it, so part of what a
///         transaction bids for ordering is paid to the pool's LPs instead of only to the sequencer.
/// @dev NOT AUDITED. Not deployed. Do not use with mainnet funds. This is a portfolio piece that shows
///      a design and an honest evaluation of it; it does NOT claim to earn LPs meaningful income.
///      Read hooks/docs/PriorityFeeHook.md first: what it collects today (very little), the ways around
///      it, who is mis-charged, and that quotes (Quoter / eth_call) do not include the surcharge.
///
///      How it works
///      - afterInitialize: only dynamic-fee pools are accepted; the pool is registered and its stored
///        LP fee (slot0) is set to MIN_FEE, so off-chain readers of slot0 see the fee of a swap that
///        pays no surcharge rather than 0.
///      - beforeSwap: returns PriorityFeeMath.lpFee(max(tx.gasprice - block.basefee, 0)) with the
///        override flag. The override applies to that one swap and is not stored.
///
///      The fee depends on two transaction-level values and nothing else: not on the pool's price, tick,
///      liquidity or volume, not on `sender`, not on hookData, not on any earlier swap. The only storage
///      is the write-once registration flag. No owner, no upgradability, no parameters that can change
///      after deployment, no return deltas, holds no funds, has no liquidity callbacks (it cannot block
///      adding or removing liquidity).
contract PriorityFeeHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    /// @notice True once the pool was initialized with this hook (and the dynamic-fee flag).
    mapping(PoolId => bool) public isRegistered;

    event PoolRegistered(PoolId indexed id);

    /// @notice The pool was not created with the dynamic-fee flag.
    error NotDynamicFee();
    /// @notice beforeSwap for a pool this hook has never seen in afterInitialize.
    error PoolNotRegistered();

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------------------------------------
    // Callbacks (reached only through BaseHook's onlyPoolManager entry points)
    // ---------------------------------------------------------------------------------------------

    /// @notice Registers the pool. Reverts (and with it the pool creation) unless the pool uses the
    ///         dynamic-fee flag, because a static-fee pool would silently ignore the fee this hook returns.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();
        PoolId id = key.toId();
        // PoolManager initializes a given PoolId only once.
        isRegistered[id] = true;
        // A dynamic-fee pool starts with a stored LP fee of 0. Every swap is overridden in beforeSwap, so
        // the stored value is never charged; it is set so that slot0 does not advertise a 0% fee.
        // Allowed here: the caller is this pool's hook and the pool is already initialized.
        poolManager.updateDynamicLPFee(key, PriorityFeeMath.MIN_FEE);
        emit PoolRegistered(id);
        return this.afterInitialize.selector;
    }

    /// @notice Returns the LP fee for this swap, derived from this transaction's priority fee only.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!isRegistered[key.toId()]) revert PoolNotRegistered();
        uint24 fee = PriorityFeeMath.lpFee(PriorityFeeMath.priorityFee(tx.gasprice, block.basefee));
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    // ---------------------------------------------------------------------------------------------
    // Views (for integrators: quotes made by Quoter / eth_call without fee fields see a priority fee
    // of 0 and therefore MIN_FEE; use these to price a swap at the priority fee it will really pay)
    // ---------------------------------------------------------------------------------------------

    /// @notice LP fee (pips) of a swap in a transaction that pays `priorityFeePerGas` wei per gas.
    function feeForPriorityFee(uint256 priorityFeePerGas) external pure returns (uint24) {
        return PriorityFeeMath.lpFee(priorityFeePerGas);
    }

    /// @notice LP fee (pips) of a swap in a transaction with effective gas price `gasPrice` in a block
    ///         with base fee `baseFee`.
    function feeFor(uint256 gasPrice, uint256 baseFee) external pure returns (uint24) {
        return PriorityFeeMath.lpFee(PriorityFeeMath.priorityFee(gasPrice, baseFee));
    }

    /// @notice LP fee (pips) a swap would be charged in the CURRENT call context. In an eth_call without
    ///         fee fields this is MIN_FEE whatever the transaction will later pay.
    function currentFee() external view returns (uint24) {
        return PriorityFeeMath.lpFee(PriorityFeeMath.priorityFee(tx.gasprice, block.basefee));
    }

    function MIN_FEE() external pure returns (uint24) {
        return PriorityFeeMath.MIN_FEE;
    }

    function MAX_FEE() external pure returns (uint24) {
        return PriorityFeeMath.MAX_FEE;
    }

    function TIP_ALLOWANCE() external pure returns (uint256) {
        return PriorityFeeMath.TIP_ALLOWANCE;
    }

    function WEI_PER_PIP() external pure returns (uint256) {
        return PriorityFeeMath.WEI_PER_PIP;
    }
}
