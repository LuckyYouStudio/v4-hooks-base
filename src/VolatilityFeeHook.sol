// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {BaseHook} from "./base/BaseHook.sol";
import {VolatilityMath} from "./libraries/VolatilityMath.sol";

/// @title VolatilityFeeHook
/// @notice Dynamic LP fee for Uniswap v4 pools: the fee rises with the pool's own realised volatility,
///         measured between time buckets, and decays back to a floor when the price is quiet. No external
///         oracle.
/// @dev NOT EXTERNALLY AUDITED. Two internal (agent) audit rounds: research/audit-hooks-h1.md and
///      research/audit-hooks-h1-reaudit.md. Do not use with mainnet funds.
///      See hooks/docs/VolatilityFeeHook.md for the design note and the known limitations.
///
///      How it works
///      - Time is cut into buckets of VolatilityMath.BUCKET seconds (bucket = block.timestamp / BUCKET).
///      - The hook keeps, per pool, a time-decayed sum of squared bucket-to-bucket moves of the log price.
///        The log price is read from sqrtPriceX96 with sub-tick (milli-tick) resolution, so an observation
///        is proportional to the real price move; crossing a tick boundary by one unit of sqrtPriceX96
///        counts as 0.001 tick, not as 1 tick.
///      - It is updated at most once per bucket, on the pool's first swap in that bucket, BEFORE that swap
///        executes. The price read at that moment is the price the pool was left at by its last swap in an
///        earlier bucket (hence in an earlier block); nothing inside the current block or bucket can have
///        moved it, because every swap goes through beforeSwap. Whatever the price did inside a bucket,
///        only the net move between two such observations is counted.
///      - The fee derived from the accumulator is cached and returned (with the override flag) for every
///        swap in the bucket, so the fee of a bucket is fixed before the bucket's first swap.
///      - Nothing is accumulated until the hook has seen the pool with in-range liquidity at an
///        observation ("armed"): price moves of an empty pool are free and carry no information.
///
///      No owner, no upgradability, no parameters that can be changed after deployment, holds no funds.
contract VolatilityFeeHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    /// @dev one storage slot (64 + 48 + 32 + 24 + 8 + 8 = 184 bits)
    struct PoolState {
        /// @dev decayed sum of squared log-price moves in milli-tick^2 (= tick^2 * VAR_SCALE), as of
        ///      `lastTimestamp`; <= VAR_CAP < 2^64
        uint64 variance;
        /// @dev block timestamp of the last observation (or of initialization); its bucket is
        ///      lastTimestamp / BUCKET
        uint48 lastTimestamp;
        /// @dev pool log price (milli-ticks) at the last observation (or at initialization)
        int32 lastLogPrice;
        /// @dev LP fee, in pips, charged to every swap in the bucket of `lastTimestamp`
        uint24 fee;
        bool registered;
        /// @dev set at the first observation that finds in-range liquidity; variance stays 0 before
        bool armed;
    }

    mapping(PoolId => PoolState) internal _pools;

    /// @notice Emitted once per pool per bucket that has at least one swap.
    event FeeUpdated(PoolId indexed id, uint24 fee, uint64 variance, int32 logPrice);

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
    function _afterInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96, int24)
        internal
        override
        returns (bytes4)
    {
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();
        // PoolManager initializes a given PoolId only once, so this cannot overwrite live state.
        _pools[key.toId()] = PoolState({
            variance: 0,
            lastTimestamp: uint48(block.timestamp),
            lastLogPrice: VolatilityMath.logPrice(sqrtPriceX96),
            fee: VolatilityMath.MIN_FEE,
            registered: true,
            armed: false
        });
        return this.afterInitialize.selector;
    }

    /// @notice Returns the LP fee for this swap. Updates the volatility estimate if this is the pool's
    ///         first swap in the current time bucket.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        PoolState memory s = _pools[id];
        if (!s.registered) revert PoolNotRegistered();

        if (_isNewBucket(s)) {
            // First swap of this bucket: the pool price is still where the last swap of an earlier
            // bucket left it.
            s = _advance(id, s);
            _pools[id] = s;
            emit FeeUpdated(id, s.fee, s.variance, s.lastLogPrice);
        }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, s.fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice Raw stored state of a pool (all zero if the pool is not registered).
    function poolState(PoolId id) external view returns (PoolState memory) {
        return _pools[id];
    }

    /// @notice The LP fee (pips) a swap on `id` would be charged if it executed in the current block.
    function currentFee(PoolId id) external view returns (uint24) {
        PoolState memory s = _pools[id];
        if (!s.registered) revert PoolNotRegistered();
        if (!_isNewBucket(s)) return s.fee;
        return _advance(id, s).fee;
    }

    function MIN_FEE() external pure returns (uint24) {
        return VolatilityMath.MIN_FEE;
    }

    function MAX_FEE() external pure returns (uint24) {
        return VolatilityMath.MAX_FEE;
    }

    function HALF_LIFE() external pure returns (uint256) {
        return VolatilityMath.HALF_LIFE;
    }

    function FEE_PER_VOL_TICK() external pure returns (uint256) {
        return VolatilityMath.FEE_PER_VOL_TICK;
    }

    function BUCKET() external pure returns (uint256) {
        return VolatilityMath.BUCKET;
    }

    // ---------------------------------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------------------------------

    /// @dev `>` rather than `!=`: should block.timestamp ever go backwards, nothing is updated.
    function _isNewBucket(PoolState memory s) internal view returns (bool) {
        return block.timestamp / VolatilityMath.BUCKET > uint256(s.lastTimestamp) / VolatilityMath.BUCKET;
    }

    /// @dev One observation. Only called when the current bucket is later than the stored one, so
    ///      block.timestamp > s.lastTimestamp. Reads the PoolManager (extsload) and nothing else.
    function _advance(PoolId id, PoolState memory s) internal view returns (PoolState memory) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        int32 logNow = VolatilityMath.logPrice(sqrtPriceX96);

        if (s.armed) {
            uint256 variance =
                VolatilityMath.accumulate(s.variance, block.timestamp - s.lastTimestamp, s.lastLogPrice, logNow);
            s.variance = uint64(variance); // <= VAR_CAP < 2^64
            s.fee = VolatilityMath.feeFromVariance(variance);
        } else if (poolManager.getLiquidity(id) != 0) {
            // First observation with in-range liquidity: start measuring from this price. The move since
            // the previous observation happened (at least partly) in an empty pool and is not counted.
            s.armed = true;
        }
        // not armed: variance stays 0 and the fee stays at the floor it was initialized with

        s.lastTimestamp = uint48(block.timestamp);
        s.lastLogPrice = logNow;
        return s;
    }
}
