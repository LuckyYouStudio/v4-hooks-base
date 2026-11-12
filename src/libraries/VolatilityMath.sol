// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title VolatilityMath
/// @notice Pure math for VolatilityFeeHook: the sub-tick log price read from sqrtPriceX96, a time-decayed
///         sum of squared bucket-to-bucket log-price moves ("realised variance") and its deterministic
///         mapping to an LP fee.
/// @dev Everything here is pure and free of external inputs so that it can be unit- and fuzz-tested on its own.
///      Units: a tick is a 0.01% price step; log prices are in milli-ticks (1e-3 tick = 1e-7 relative);
///      fees are in pips (1e-6, the unit v4 uses for LP fees).
library VolatilityMath {
    /// @notice Length of a sampling bucket in seconds. The hook takes at most one observation per bucket
    ///         (bucket index = block.timestamp / BUCKET), so only the net move between buckets counts.
    uint256 internal constant BUCKET = 10;
    /// @notice Log-price units per tick (milli-ticks).
    int256 internal constant LOG_SCALE = 1000;
    /// @notice Fee charged when the variance accumulator is zero. 500 pips = 0.05%.
    uint24 internal constant MIN_FEE = 500;
    /// @notice Hard ceiling of the fee. 10_000 pips = 1.00%.
    uint24 internal constant MAX_FEE = 10_000;
    /// @notice Fee added per tick of realised volatility (sqrt of the accumulator). 25 pips per tick.
    uint256 internal constant FEE_PER_VOL_TICK = 25;
    /// @notice Time for the variance accumulator to halve, in seconds.
    /// @dev The table in decayFactorQ64 is computed for exactly this value.
    uint256 internal constant HALF_LIFE = 600;
    /// @notice Fixed-point scale of the stored variance (tick^2 * VAR_SCALE). Equals LOG_SCALE^2, so the
    ///         stored variance is simply a sum of squared milli-tick moves.
    uint256 internal constant VAR_SCALE = 1e6;
    /// @dev sqrt(VAR_SCALE) == LOG_SCALE
    uint256 internal constant VOL_SCALE = 1e3;
    /// @notice Volatility (in ticks) at which the fee reaches MAX_FEE: (10_000 - 500) / 25 = 380 ticks (~3.8%).
    uint256 internal constant VOL_CAP_TICKS = (uint256(MAX_FEE) - uint256(MIN_FEE)) / FEE_PER_VOL_TICK;
    /// @notice The accumulator saturates here; beyond it the fee is MAX_FEE anyway. 380^2 * 1e6 = 1.444e11 (< 2^64).
    uint256 internal constant VAR_CAP = VOL_CAP_TICKS * VOL_CAP_TICKS * VAR_SCALE;

    /// @notice Decays `variance` over `dt` seconds by the factor 2^(-dt / HALF_LIFE).
    /// @dev Whole half-lives are exact right-shifts; the remainder uses a table of Q64 factors
    ///      2^(-2^k / 600). Because the factor is a true exponential, decaying in many small steps or
    ///      in one large step gives the same result (up to 1 unit of rounding per step): how often the
    ///      pool is traded does not change how fast the fee comes down.
    function decay(uint256 variance, uint256 dt) internal pure returns (uint256) {
        uint256 halvings = dt / HALF_LIFE;
        if (halvings >= 64) return 0;
        variance >>= halvings;
        uint256 rem = dt % HALF_LIFE;
        if (rem == 0 || variance == 0) return variance;
        // variance <= type(uint64).max is not required: factor < 2^64, so the product fits for variance < 2^192.
        return (variance * decayFactorQ64(rem)) >> 64;
    }

    /// @notice 2^64 * 2^(-rem / 600) for rem < 600, rounded down. Strictly decreasing in `rem`.
    /// @dev Each table constant is floor(2^64 * 2^(-2^k / 600)) (pinned bit for bit in VolatilityMath.t.sol)
    ///      and every multiplication floors, so the result never exceeds the exact value; it is below it
    ///      by less than 10 units of 2^-64 (at most 9 floored multiplications plus the constants' own
    ///      truncation).
    function decayFactorQ64(uint256 rem) internal pure returns (uint256 f) {
        f = 1 << 64;
        if (rem & 1 != 0) f = (f * 0xffb455641fc96856) >> 64; // 2^(-1/600)
        if (rem & 2 != 0) f = (f * 0xff68c125a89b955b) >> 64; // 2^(-2/600)
        if (rem & 4 != 0) f = (f * 0xfed1dba68638bfb9) >> 64; // 2^(-4/600)
        if (rem & 8 != 0) f = (f * 0xfda51be6d4b61b15) >> 64; // 2^(-8/600)
        if (rem & 16 != 0) f = (f * 0xfb4fc3a33b08a547) >> 64; // 2^(-16/600)
        if (rem & 32 != 0) f = (f * 0xf6b5827c6a037774) >> 64; // 2^(-32/600)
        if (rem & 64 != 0) f = (f * 0xedc15778e22f2a9d) >> 64; // 2^(-64/600)
        if (rem & 128 != 0) f = (f * 0xdccf8dfad4f3c2d6) >> 64; // 2^(-128/600)
        if (rem & 256 != 0) f = (f * 0xbe75644e08659d6e) >> 64; // 2^(-256/600)
        if (rem & 512 != 0) f = (f * 0x8db276b8ab1790e9) >> 64; // 2^(-512/600)
    }

    /// @notice Log price of `sqrtPriceX96` in milli-ticks: floor(1000 * log_1.0001(price)), with the
    ///         fractional part of the tick taken by linear interpolation of sqrtPrice inside the tick.
    /// @dev A pure function of the price alone (it does not use the pool's stored tick), non-decreasing
    ///      in the price, and exactly 1000 * t at the lower boundary of tick t. Interpolating linearly
    ///      instead of taking a true logarithm is off by less than 0.007 milli-ticks (f(1-f) * 0.00005 / 2
    ///      of a tick), far below the 1 milli-tick resolution.
    ///      Moving sqrtPriceX96 by one unit across a tick boundary changes the result by 1 milli-tick,
    ///      not by 1 tick: the observation is proportional to the real price move.
    ///      Valid for MIN_SQRT_PRICE <= sqrtPriceX96 < MAX_SQRT_PRICE (every initialized v4 pool); reverts
    ///      outside. |result| <= 887_272_000 < 2^31.
    function logPrice(uint160 sqrtPriceX96) internal pure returns (int32) {
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        // getTickAtSqrtPrice returns the greatest tick with getSqrtPriceAtTick(tick) <= sqrtPriceX96, and
        // sqrtPriceX96 < MAX_SQRT_PRICE gives tick < MAX_TICK, so lo <= sqrtPriceX96 < hi.
        uint256 lo = TickMath.getSqrtPriceAtTick(tick);
        uint256 hi = TickMath.getSqrtPriceAtTick(tick + 1);
        uint256 frac = ((uint256(sqrtPriceX96) - lo) * uint256(LOG_SCALE)) / (hi - lo); // 0..999
        return int32(int256(tick) * LOG_SCALE + int256(frac));
    }

    /// @notice New accumulator value after `dt` seconds and one observed close-to-close move from
    ///         `logBefore` to `logNow` (milli-ticks). Saturates at VAR_CAP.
    function accumulate(uint256 variance, uint256 dt, int32 logBefore, int32 logNow)
        internal
        pure
        returns (uint256 next)
    {
        int256 d = int256(logNow) - int256(logBefore);
        // |d| < 2^32, so d * d < 2^64: no overflow. VAR_SCALE == LOG_SCALE^2, so no further scaling.
        next = decay(variance, dt) + uint256(d * d);
        if (next > VAR_CAP) next = VAR_CAP;
    }

    /// @notice Deterministic variance -> LP fee mapping:
    ///         fee = MIN_FEE + FEE_PER_VOL_TICK * sqrt(variance), clamped to [MIN_FEE, MAX_FEE].
    function feeFromVariance(uint256 variance) internal pure returns (uint24) {
        if (variance >= VAR_CAP) return MAX_FEE;
        uint256 fee = uint256(MIN_FEE) + (FEE_PER_VOL_TICK * sqrt(variance)) / VOL_SCALE;
        return fee >= MAX_FEE ? MAX_FEE : uint24(fee);
    }

    /// @notice floor(sqrt(x)), Babylonian method.
    function sqrt(uint256 x) internal pure returns (uint256 r) {
        if (x == 0) return 0;
        // Initial guess: a power of two >= sqrt(x).
        r = 1;
        uint256 xx = x;
        if (xx >= 1 << 128) { xx >>= 128; r <<= 64; }
        if (xx >= 1 << 64) { xx >>= 64; r <<= 32; }
        if (xx >= 1 << 32) { xx >>= 32; r <<= 16; }
        if (xx >= 1 << 16) { xx >>= 16; r <<= 8; }
        if (xx >= 1 << 8) { xx >>= 8; r <<= 4; }
        if (xx >= 1 << 4) { xx >>= 4; r <<= 2; }
        if (xx >= 1 << 2) { r <<= 1; }
        r <<= 1; // now r >= sqrt(x)
        // Newton iterations converge monotonically from above.
        while (true) {
            uint256 next = (r + x / r) >> 1;
            if (next >= r) break;
            r = next;
        }
    }
}
