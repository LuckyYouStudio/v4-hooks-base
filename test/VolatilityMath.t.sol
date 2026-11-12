// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {VolatilityMath as VM_} from "../src/libraries/VolatilityMath.sol";

contract VolatilityMathTest is Test {
    function test_constants() public pure {
        assertEq(VM_.BUCKET, 10);
        assertEq(VM_.LOG_SCALE, 1000);
        assertEq(uint256(VM_.LOG_SCALE * VM_.LOG_SCALE), VM_.VAR_SCALE, "variance unit is milli-tick^2");
        assertEq(VM_.MIN_FEE, 500);
        assertEq(VM_.MAX_FEE, 10_000);
        assertEq(VM_.VOL_CAP_TICKS, 380);
        assertEq(VM_.VAR_CAP, 144_400_000_000);
        assertLt(VM_.VAR_CAP, type(uint64).max);
        assertEq(VM_.VOL_SCALE * VM_.VOL_SCALE, VM_.VAR_SCALE);
        // the fee range sits inside what v4 accepts as an LP fee, and cannot collide with the flag bits
        assertLt(VM_.MAX_FEE, LPFeeLibrary.MAX_LP_FEE);
        assertEq(VM_.MAX_FEE & LPFeeLibrary.OVERRIDE_FEE_FLAG, 0);
    }

    // ---- sqrt ----

    function test_sqrt_knownValues() public pure {
        assertEq(VM_.sqrt(0), 0);
        assertEq(VM_.sqrt(1), 1);
        assertEq(VM_.sqrt(2), 1);
        assertEq(VM_.sqrt(3), 1);
        assertEq(VM_.sqrt(4), 2);
        assertEq(VM_.sqrt(99), 9);
        assertEq(VM_.sqrt(100), 10);
        assertEq(VM_.sqrt(1e10), 1e5);
        assertEq(VM_.sqrt(VM_.VAR_CAP), 380_000);
        assertEq(VM_.sqrt(type(uint256).max), type(uint128).max);
    }

    function testFuzz_sqrt_isFloor(uint256 x) public pure {
        uint256 r = VM_.sqrt(x);
        assertLe(r, type(uint128).max);
        assertLe(r * r, x);
        if (r < type(uint128).max) assertGt((r + 1) * (r + 1), x);
    }

    // ---- decay ----

    function test_decay_knownValues() public pure {
        assertEq(VM_.decay(1e10, 0), 1e10);
        assertEq(VM_.decay(1e10, 600), 5e9);
        assertEq(VM_.decay(1e10, 1200), 25e8);
        assertEq(VM_.decay(1e10, 6000), 1e10 >> 10);
        // 2^(-1/2) = 0.70710678118..., 2^(-3/2) = 0.35355339059...
        assertApproxEqAbs(VM_.decay(1e10, 300), 7_071_067_811, 2);
        assertApproxEqAbs(VM_.decay(1e10, 900), 3_535_533_905, 2);
        // 2^(-1/600) = 0.99884541...
        assertApproxEqAbs(VM_.decay(1e10, 1), 9_988_454_217, 2);
        assertApproxEqAbs(VM_.decay(1e10, 599), 5_005_779_564, 2);
        assertEq(VM_.decay(VM_.VAR_CAP, 64 * 600), 0);
        assertEq(VM_.decay(VM_.VAR_CAP, type(uint256).max), 0);
        assertEq(VM_.decay(0, 12345), 0);
    }

    function test_decayFactor_table() public pure {
        assertEq(VM_.decayFactorQ64(0), 1 << 64);
        uint256 prev = 1 << 64;
        for (uint256 rem = 1; rem < 600; rem++) {
            uint256 f = VM_.decayFactorQ64(rem);
            assertLt(f, prev, "strictly decreasing");
            assertGt(f, 1 << 63, "never below one half inside a half-life");
            // f(rem) == f(rem-1) * f(1) up to rounding in the 64th bit
            assertApproxEqAbs(f, (prev * VM_.decayFactorQ64(1)) >> 64, 16);
            prev = f;
        }
        // one more second completes the halving
        assertApproxEqAbs((prev * VM_.decayFactorQ64(1)) >> 64, 1 << 63, 16);
    }

    function testFuzz_decay_neverIncreases_andMonotoneInTime(uint64 v, uint32 dt1, uint32 dt2) public pure {
        if (dt1 > dt2) (dt1, dt2) = (dt2, dt1);
        uint256 a = VM_.decay(v, dt1);
        uint256 b = VM_.decay(v, dt2);
        assertLe(a, v);
        assertLe(b, a, "more time => not more variance");
    }

    function testFuzz_decay_monotoneInVariance(uint64 v1, uint64 v2, uint32 dt) public pure {
        if (v1 > v2) (v1, v2) = (v2, v1);
        assertLe(VM_.decay(v1, dt), VM_.decay(v2, dt));
    }

    function testFuzz_decay_halfLifeBound(uint64 v, uint32 dt) public pure {
        uint256 n = uint256(dt) / VM_.HALF_LIFE;
        uint256 d = VM_.decay(v, dt);
        if (n < 64) assertLe(d, uint256(v) >> n);
        if (n + 1 < 64) assertGe(d, uint256(v) >> (n + 1));
    }

    /// @dev Path independence: splitting an interval into two updates changes the result by at most
    ///      rounding. This is what makes the decay speed independent of how often the pool trades.
    function testFuzz_decay_composes(uint64 v, uint16 a, uint16 b) public pure {
        v = uint64(bound(v, 0, VM_.VAR_CAP));
        uint256 split = VM_.decay(VM_.decay(v, a), b);
        uint256 whole = VM_.decay(v, uint256(a) + b);
        assertApproxEqAbs(split, whole, 2);
    }

    function test_decay_manySmallSteps_equalsOneBigStep() public pure {
        uint256 v = VM_.VAR_CAP;
        for (uint256 i; i < 600; i++) {
            v = VM_.decay(v, 1);
        }
        // 600 one-second steps: each floors once, so at most 600 units (6e-4 tick^2) below the exact half
        assertApproxEqAbs(v, VM_.VAR_CAP / 2, 600);
        assertLe(v, VM_.VAR_CAP / 2);
    }

    /// @dev Audit gap 4: every table constant pinned, bit for bit, to floor(2^64 * 2^(-2^k/600)). The
    ///      reference values below were recomputed independently (python, 120-digit decimals) and are
    ///      written in decimal, not copied from the hex literals in the source. A one-bit change in any
    ///      constant fails here.
    function test_decayFactor_tableConstants_bitForBit() public pure {
        assertEq(VM_.decayFactorQ64(1), 18425445863997925462); // floor(2^64 * 2^(-1/600))
        assertEq(VM_.decayFactorQ64(2), 18404172244736251227); // floor(2^64 * 2^(-2/600))
        assertEq(VM_.decayFactorQ64(4), 18361698664029142969); // floor(2^64 * 2^(-4/600))
        assertEq(VM_.decayFactorQ64(8), 18277045340978158357); // floor(2^64 * 2^(-8/600))
        assertEq(VM_.decayFactorQ64(16), 18108907732517561671); // floor(2^64 * 2^(-16/600))
        assertEq(VM_.decayFactorQ64(32), 17777258574981068660); // floor(2^64 * 2^(-32/600))
        assertEq(VM_.decayFactorQ64(64), 17132070634196511389); // floor(2^64 * 2^(-64/600))
        assertEq(VM_.decayFactorQ64(128), 15911092116977337046); // floor(2^64 * 2^(-128/600))
        assertEq(VM_.decayFactorQ64(256), 13723985725792558446); // floor(2^64 * 2^(-256/600))
        assertEq(VM_.decayFactorQ64(512), 10210353840718844137); // floor(2^64 * 2^(-512/600))
        // 2^(-300/600) = 1/sqrt(2): composed from five constants, within 10 units of the exact value
        assertApproxEqAbs(VM_.decayFactorQ64(300), 13043817825332782212, 10);
        assertLe(VM_.decayFactorQ64(300), 13043817825332782212);
    }

    // ---- logPrice ----

    function test_logPrice_knownValues() public pure {
        assertEq(VM_.logPrice(uint160(1 << 96)), 0);
        assertEq(VM_.logPrice(uint160(1 << 96) - 1), -1, "one unit below a tick boundary is -0.001 tick, not -1 tick");
        int24[9] memory ticks = [int24(0), 1, -1, 100, -100, 13863, -887272, 887271, 443636];
        for (uint256 i; i < ticks.length; i++) {
            uint160 p = TickMath.getSqrtPriceAtTick(ticks[i]);
            assertEq(VM_.logPrice(p), int256(ticks[i]) * 1000, "exact on a boundary");
            if (ticks[i] > TickMath.MIN_TICK) {
                assertEq(VM_.logPrice(p - 1), int256(ticks[i]) * 1000 - 1, "just below a boundary");
            }
            // middle of the tick (in sqrt price): 0.4999.. or 0.5 tick
            uint160 q = TickMath.getSqrtPriceAtTick(ticks[i] + 1);
            assertApproxEqAbs(VM_.logPrice(p + (q - p) / 2), int256(ticks[i]) * 1000 + 500, 1);
        }
        assertEq(VM_.logPrice(TickMath.MIN_SQRT_PRICE), int256(TickMath.MIN_TICK) * 1000);
        assertEq(VM_.logPrice(TickMath.MAX_SQRT_PRICE - 1), int256(TickMath.MAX_TICK) * 1000 - 1);
    }

    function _checkLog(uint160 p, int256 expected) internal pure {
        assertApproxEqAbs(VM_.logPrice(p), expected, 1);
    }

    /// @dev Against an independent reference: floor(1000 * ln((p / 2^96)^2) / ln(1.0001)) computed in
    ///      python with 80-digit decimals for 40 log-uniform random prices over the whole range plus a
    ///      few special ones. Linear interpolation inside a tick is allowed to be 1 milli-tick off.
    function test_logPrice_matchesTrueLogarithm() public pure {
        _checkLog(12907368660193052075151, -312616511);
        _checkLog(2789121353995764, -619583504);
        _checkLog(51839110139751289986273422389462553, 267839863);
        _checkLog(2655077415761, -758730623);
        _checkLog(1911956650001286839567765808787, 63674195);
        _checkLog(529213457831564949435740, -238340927);
        _checkLog(737529760531, -784350357);
        _checkLog(153246942504125023489167712496, 13195035);
        _checkLog(119605638125, -820734305);
        _checkLog(219850717147032796749575444, -117748654);
        _checkLog(2111698301148, -763310478);
        _checkLog(13437314742136, -726297767);
        _checkLog(97828988471603148418503244, -133944021);
        _checkLog(311230752413992515768853049727251815273164, 580013476);
        _checkLog(253098419812997, -667579973);
        _checkLog(1717025872814639321, -491124635);
        _checkLog(6443352467628282006585783522981528, 226135860);
        _checkLog(14122580390564693730319556332276222090117102313, 794479217);
        _checkLog(74096126209188570428760200192745, 136822574);
        _checkLog(8275449538228962022562551, -183345044);
        _checkLog(177766244791997846535506949312745426680174709919, 845135640);
        _checkLog(267849620449, -804608984);
        _checkLog(5144189877360250657688527238323766705410326, 636118053);
        _checkLog(619648286418893730204, -373347579);
        _checkLog(1553764472872228, -631285008);
        _checkLog(148499142353893, -678244491);
        _checkLog(3306269357983406869176, -339857430);
        _checkLog(120170917406964566182628463932017623462136, 560980133);
        _checkLog(39508463480490392, -566565087);
        _checkLog(110428538556822074414592001906595, 144803080);
        _checkLog(17842944716957315009206183813422275, 246508062);
        _checkLog(959679799645237801863412, -226436175);
        _checkLog(5477219077345884971879604990221, 84724655);
        _checkLog(1128103218544, -775850202);
        _checkLog(850191877766, -781507102);
        _checkLog(370627394077312314, -521789202);
        _checkLog(707972675987379981744973529469092536, 320127690);
        _checkLog(128493244494006743881001588, -128490640);
        _checkLog(5465554890172395982029, -329804024);
        _checkLog(156939685383354083825583599930112, 151833291);
        _checkLog(79228162514264337593543950336, 0);
        _checkLog(158456325028528675187087900672, 13863636);
        _checkLog(39614081257132168796771975168, -13863637);
        _checkLog(118842243771396506390315925504, 8109707);
        _checkLog(4295128739, -887272000);
        _checkLog(1461446703485210103287273052203988822378723970341, 887272000);
    }

    function test_logPrice_outOfRange_reverts() public {
        vm.expectRevert();
        this.logPriceExt(TickMath.MIN_SQRT_PRICE - 1);
        vm.expectRevert();
        this.logPriceExt(TickMath.MAX_SQRT_PRICE);
        vm.expectRevert();
        this.logPriceExt(0);
    }

    function logPriceExt(uint160 p) external pure returns (int32) {
        return VM_.logPrice(p);
    }

    function _boundPrice(uint160 p) internal pure returns (uint160) {
        return uint160(bound(p, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
    }

    function testFuzz_logPrice_consistentWithTick(uint160 p) public pure {
        p = _boundPrice(p);
        int256 x = VM_.logPrice(p);
        int256 tick = TickMath.getTickAtSqrtPrice(p);
        assertGe(x, tick * 1000);
        assertLt(x, (tick + 1) * 1000);
        assertGe(x, int256(TickMath.MIN_TICK) * 1000);
        assertLt(x, int256(TickMath.MAX_TICK) * 1000);
    }

    function testFuzz_logPrice_monotone(uint160 p1, uint160 p2) public pure {
        p1 = _boundPrice(p1);
        p2 = _boundPrice(p2);
        if (p1 > p2) (p1, p2) = (p2, p1);
        assertLe(VM_.logPrice(p1), VM_.logPrice(p2));
    }

    /// @dev The property H-1 needs: the smallest possible price step (one unit of sqrtPriceX96) never
    ///      moves the observation by more than one milli-tick, anywhere, tick boundaries included.
    function testFuzz_logPrice_oneUnitStep_atMostOneMilliTick(uint160 p) public pure {
        p = uint160(bound(p, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 2));
        int256 d = int256(VM_.logPrice(p + 1)) - VM_.logPrice(p);
        assertTrue(d == 0 || d == 1);
    }

    /// @dev the same at every tick boundary in a band and at the extremes
    function test_logPrice_oneUnitStep_acrossTickBoundaries() public pure {
        for (int24 t = -2000; t <= 2000; t++) {
            uint160 p = TickMath.getSqrtPriceAtTick(t);
            assertEq(int256(VM_.logPrice(p)) - VM_.logPrice(p - 1), 1);
        }
        uint160 lo = TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK + 1);
        assertEq(int256(VM_.logPrice(lo)) - VM_.logPrice(lo - 1), 1);
        uint160 hi = TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK - 1);
        assertEq(int256(VM_.logPrice(hi)) - VM_.logPrice(hi - 1), 1);
    }

    /// @dev proportionality: a move of d ticks reads as d * 1000 milli-ticks wherever it starts
    function testFuzz_logPrice_proportional(int24 t, uint16 d) public pure {
        t = int24(bound(t, TickMath.MIN_TICK, TickMath.MAX_TICK - 70_000));
        int24 t2 = t + int24(uint24(d));
        assertEq(
            int256(VM_.logPrice(TickMath.getSqrtPriceAtTick(t2))) - VM_.logPrice(TickMath.getSqrtPriceAtTick(t)),
            int256(uint256(d)) * 1000
        );
    }

    // ---- accumulate ----

    int32 internal constant MIN_LOG = -887_272_000;
    int32 internal constant MAX_LOG = 887_271_999;

    function test_accumulate_knownValues() public pure {
        assertEq(VM_.accumulate(0, 0, 0, 100_000), 1e10); // 100 ticks
        assertEq(VM_.accumulate(0, 999, 100_000, 0), 1e10);
        assertEq(VM_.accumulate(1e10, 1200, -5000, -5000), 25e8);
        assertEq(VM_.accumulate(1e10, 600, 7, 7), 5e9);
        assertEq(VM_.accumulate(1e10, 600, 0, -100_000), 15e9);
        assertEq(VM_.accumulate(0, 0, 0, 1), 1); // one milli-tick
        assertEq(VM_.accumulate(0, 0, 0, 500), 250_000); // half a tick = 0.25 tick^2
        assertEq(VM_.accumulate(0, 0, 0, 379_999), 144_399_240_001);
        assertEq(VM_.accumulate(0, 0, 0, 380_000), VM_.VAR_CAP);
        assertEq(VM_.accumulate(0, 0, 0, 380_001), VM_.VAR_CAP);
        assertEq(VM_.accumulate(VM_.VAR_CAP, 0, MIN_LOG, MAX_LOG), VM_.VAR_CAP);
        assertEq(VM_.accumulate(VM_.VAR_CAP, 0, MAX_LOG, MIN_LOG), VM_.VAR_CAP);
        assertEq(VM_.accumulate(0, 0, type(int32).min, type(int32).max), VM_.VAR_CAP, "no overflow for any int32 pair");
    }

    function testFuzz_accumulate_bounded_symmetric(uint64 v, uint32 dt, int32 a, int32 b) public pure {
        v = uint64(bound(v, 0, VM_.VAR_CAP));
        uint256 n = VM_.accumulate(v, dt, a, b);
        assertLe(n, VM_.VAR_CAP);
        assertEq(n, VM_.accumulate(v, dt, b, a), "direction of the move must not matter");
        assertGe(n, VM_.decay(v, dt));
        if (a == b) assertEq(n, VM_.decay(v, dt));
    }

    // ---- fee mapping ----

    function test_fee_knownValues() public pure {
        assertEq(VM_.feeFromVariance(0), 500);
        assertEq(VM_.feeFromVariance(1e6), 525); // 1 tick
        assertEq(VM_.feeFromVariance(100e6), 750); // 10 ticks
        assertEq(VM_.feeFromVariance(1e10), 3000); // 100 ticks (1%) -> 0.30%
        assertEq(VM_.feeFromVariance(5e9), 2267); // 70.71 ticks
        assertEq(VM_.feeFromVariance(4e10), 5500); // 200 ticks
        assertEq(VM_.feeFromVariance(VM_.VAR_CAP - 1), 9999);
        assertEq(VM_.feeFromVariance(VM_.VAR_CAP), 10_000);
        assertEq(VM_.feeFromVariance(VM_.VAR_CAP + 1), 10_000);
        assertEq(VM_.feeFromVariance(type(uint256).max), 10_000);
    }

    function testFuzz_fee_bounded(uint256 v) public pure {
        uint24 fee = VM_.feeFromVariance(v);
        assertGe(fee, VM_.MIN_FEE);
        assertLe(fee, VM_.MAX_FEE);
    }

    function testFuzz_fee_monotone(uint256 v1, uint256 v2) public pure {
        if (v1 > v2) (v1, v2) = (v2, v1);
        assertLe(VM_.feeFromVariance(v1), VM_.feeFromVariance(v2));
    }

    function testFuzz_fee_singleMoveFormula(uint16 ticks) public pure {
        // one move of D ticks from a quiet state => fee = min(MAX, MIN + 25 * D), exactly
        uint256 d = bound(ticks, 0, 2000);
        uint256 v = VM_.accumulate(0, 0, 0, int32(int256(d * 1000)));
        uint256 expected = 500 + 25 * d;
        if (expected > 10_000) expected = 10_000;
        assertEq(VM_.feeFromVariance(v), expected);
    }

    /// @dev Third-round audit, last surviving mutant ("divisor of the fractional part + 1"): the first
    ///      sqrt price of milli-tick k inside a tick reads k, the one before it reads k - 1, exactly.
    function test_logPrice_firstPriceOfAMilliTick_isExact() public pure {
        int24[5] memory ts = [int24(-887272), -60, 0, 4055, 887271];
        uint256[4] memory ks = [uint256(1), 250, 500, 999];
        for (uint256 i; i < ts.length; i++) {
            uint256 lo = TickMath.getSqrtPriceAtTick(ts[i]);
            uint256 w = TickMath.getSqrtPriceAtTick(ts[i] + 1) - lo;
            for (uint256 j; j < ks.length; j++) {
                uint256 x = (ks[j] * w + 999) / 1000; // smallest x with floor(1000 x / w) >= k
                assertEq(VM_.logPrice(uint160(lo + x)), int32(int256(ts[i]) * 1000 + int256(ks[j])));
                assertEq(VM_.logPrice(uint160(lo + x - 1)), int32(int256(ts[i]) * 1000 + int256(ks[j]) - 1));
            }
        }
    }
}
