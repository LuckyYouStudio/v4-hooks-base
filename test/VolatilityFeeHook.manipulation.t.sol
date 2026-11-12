// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {VolatilityFeeHook} from "../src/VolatilityFeeHook.sol";
import {VolatilityMath} from "../src/libraries/VolatilityMath.sol";
import {HookTestBase} from "./utils/HookTestBase.sol";

/// @notice What an attacker can and cannot do to the fee, with numbers.
///         See docs/VolatilityFeeHook.md, "操纵成本分析". Run with -vv to print the tables.
///
///         Sections
///         1. inside one block / one bucket: zero effect
///         2. H-1 regression: tick-boundary flicker and other dust
///         3. adversarial: cheapest way to raise the fee, for an attacker who is not an LP
///            (lower bound on five pool shapes, its tight case, patient unwind)
///         4. M-1: the same push by an LP with share s (net cost table, signed)
///         5. sustained zig-zag; cap; the fee cannot be pushed down
///         Re-audit facts (N-1 liquidity edge, E-A self-shielded sole LP) are in
///         VolatilityFeeHook.reaudit.t.sol.
contract VolatilityFeeHookManipulationTest is HookTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev sum_{k>=0} 2^(-k*BUCKET/HALF_LIFE) = 1 / (1 - 2^(-1/60)) = 87.06: the most a per-bucket
    ///      contribution c can pile up to is 87.06 * c (+1 per step of rounding slack is not needed,
    ///      decay rounds down). 88 milli-tick^2 = 8.8e-5 tick^2 -> sqrt = 0.0094 tick -> +0.23 pips -> +0.
    uint256 internal constant DUST_VARIANCE_BOUND = 88;

    function setUp() public {
        _baseSetUp();
    }

    /// @dev some honest history so the accumulator is not trivially zero: +40 ticks, then a new bucket
    function _withHistory() internal {
        _moveTo(hookKey, 40);
        _nextBlock(BUCKET);
    }

    /// @dev fees charged by the first swap of this bucket, the next bucket and the one after
    function _threeBucketsOfHonestFlow() internal returns (uint24 f0, uint24 f1, uint24 f2, bytes32 finalState) {
        (, f0) = _swap(hookKey, true, -TINY);
        _nextBlock(BUCKET);
        (, f1) = _swap(hookKey, false, -TINY);
        _nextBlock(BUCKET);
        (, f2) = _swap(hookKey, true, -TINY);
        finalState = _stateHash(hookId);
    }

    // ------------------------------------------------------------------------------------------
    // 1. Anything that starts and ends inside one block - or one bucket - has zero effect
    // ------------------------------------------------------------------------------------------

    function test_sameBlockRoundTrip_changesNothing_attackerNotFirst() public {
        _withHistory();
        uint256 snap = vm.snapshotState();
        (uint24 c0, uint24 c1, uint24 c2, bytes32 cState) = _threeBucketsOfHonestFlow();
        assertEq(c0, 1500); // 500 + 25 * 40
        vm.revertToState(snap);

        // same three buckets, but in the first one an attacker slams the price +350 ticks and back
        (, uint24 f0) = _swap(hookKey, true, -TINY);
        uint160 p = _sqrtPrice(hookKey);
        (, uint24 fa) = _moveTo(hookKey, 390);
        (, uint24 fb) = _moveToPrice(hookKey, p);
        assertEq(f0, c0);
        assertEq(fa, c0, "attacker pays the bucket's fee");
        assertEq(fb, c0, "fee did not move inside the block");

        _nextBlock(BUCKET);
        (, uint24 f1) = _swap(hookKey, false, -TINY);
        _nextBlock(BUCKET);
        (, uint24 f2) = _swap(hookKey, true, -TINY);
        assertEq(f1, c1, "next bucket fee unchanged");
        assertEq(f2, c2, "bucket after unchanged");
        assertEq(_stateHash(hookId), cState, "hook state identical to the no-attack run");
    }

    function test_sameBlockRoundTrip_changesNothing_attackerFirst() public {
        _withHistory();
        uint256 snap = vm.snapshotState();
        (uint24 c0, uint24 c1, uint24 c2, bytes32 cState) = _threeBucketsOfHonestFlow();
        vm.revertToState(snap);

        // attacker owns the first swap of the bucket (the one that triggers the update)
        uint160 p = _sqrtPrice(hookKey);
        (, uint24 fa) = _moveTo(hookKey, -310);
        (, uint24 fb) = _moveToPrice(hookKey, p);
        (, uint24 f0) = _swap(hookKey, true, -TINY);
        assertEq(fa, c0);
        assertEq(fb, c0);
        assertEq(f0, c0);

        _nextBlock(BUCKET);
        (, uint24 f1) = _swap(hookKey, false, -TINY);
        _nextBlock(BUCKET);
        (, uint24 f2) = _swap(hookKey, true, -TINY);
        assertEq(f1, c1);
        assertEq(f2, c2);
        assertEq(_stateHash(hookId), cState);
    }

    /// @dev new with bucket sampling: the round trip may also span many blocks, as long as the price
    ///      is back before the bucket ends
    function test_sameBucketRoundTrip_acrossBlocks_changesNothing() public {
        _withHistory();
        uint256 snap = vm.snapshotState();
        (uint24 c0, uint24 c1, uint24 c2, bytes32 cState) = _threeBucketsOfHonestFlow();
        vm.revertToState(snap);

        (, uint24 f0) = _swap(hookKey, true, -TINY);
        uint160 p = _sqrtPrice(hookKey);
        _moveTo(hookKey, 390); // held across 45 block boundaries and 9 seconds
        for (uint256 i; i < 9; i++) {
            vm.roll(block.number + 5);
            vm.warp(block.timestamp + 1);
            assertEq(hook.currentFee(hookId), c0, "displaced price, same bucket: fee unchanged");
        }
        (, uint24 fb) = _moveToPrice(hookKey, p);
        assertEq(f0, c0);
        assertEq(fb, c0);

        _nextBlock(1);
        (, uint24 f1) = _swap(hookKey, false, -TINY);
        _nextBlock(BUCKET);
        (, uint24 f2) = _swap(hookKey, true, -TINY);
        assertEq(f1, c1);
        assertEq(f2, c2);
        assertEq(_stateHash(hookId), cState);
    }

    /// forge-config: default.fuzz.runs = 128
    function testFuzz_sameBucketActivity_onlyClosingPriceMatters(int16[6] memory ticks, uint16 dt, uint8 gaps)
        public
    {
        _withHistory();
        (, uint24 bucketFee) = _swap(hookKey, true, -TINY);
        VolatilityFeeHook.PoolState memory s = _state();
        bytes32 frozen = _stateHash(hookId);

        for (uint256 i; i < 6; i++) {
            int24 target = int24(bound(ticks[i], -5000, 5000));
            if (target == _tick(hookKey)) continue;
            (, uint24 fee) = _moveTo(hookKey, target);
            assertEq(fee, bucketFee, "fee is fixed for the whole bucket");
            assertEq(_stateHash(hookId), frozen, "state is fixed for the whole bucket");
            // some of the trades are in later blocks / seconds of the same bucket
            if ((gaps >> i) & 1 == 1) {
                vm.roll(block.number + 1);
                vm.warp(block.timestamp + 1); // at most 6 seconds in total: still the same bucket
            }
        }
        int32 closing = _logPrice(hookKey);

        uint256 dt_ = bound(dt, BUCKET, 5000);
        _nextBlock(dt_);
        uint256 elapsed = block.timestamp - s.lastTimestamp;
        (, uint24 next) = _swap(hookKey, true, -TINY);
        // next bucket's fee is a function of (state before, elapsed time, closing price) and nothing else
        uint256 v = VolatilityMath.accumulate(s.variance, elapsed, s.lastLogPrice, closing);
        assertEq(next, VolatilityMath.feeFromVariance(v));
        assertLe(next, MAX_FEE);
        // and no amount of same-bucket trading can push it BELOW the pure-decay path
        uint256 floor_ = VolatilityMath.feeFromVariance(VolatilityMath.decay(s.variance, elapsed));
        assertGe(next, floor_);
        // the most a D-tick displacement can add is 25 pips per tick
        uint256 d = closing > s.lastLogPrice
            ? uint256(int256(closing) - s.lastLogPrice)
            : uint256(int256(s.lastLogPrice) - closing);
        assertLe(next, floor_ + (25 * d) / 1000 + 1);
    }

    // ------------------------------------------------------------------------------------------
    // 2. H-1 regression: dust that does not really move the price contributes ~0
    // ------------------------------------------------------------------------------------------

    /// @dev The audit's PoC-1, unchanged attack, opposite assertion. One swap per block, 15,000 blocks
    ///      (50 minutes of 200ms blocks), each flipping the pool's integer tick 0 <-> -1 by moving
    ///      sqrtPriceX96 one unit across the tick boundary. Before the fix the fee went 500 -> 2118.
    ///      Threshold: the fee stays EXACTLY at the floor. Why exactly: each bucket can contribute at
    ///      most (1 milli-tick)^2 = 1 unit, the decayed pile of those is <= 87.06 units, and
    ///      25 * sqrt(88) / 1000 = 0.23 pips floors to 0.
    function test_regression_H1_tickBoundaryFlicker_15000blocks() public {
        uint160 pB = TickMath.getSqrtPriceAtTick(0);
        _moveToPrice(hookKey, pB);
        uint256 b0 = currency0.balanceOfSelf();
        uint256 b1 = currency1.balanceOfSelf();
        uint256 maxVariance;
        // 30 chunks of 500 blocks; checkpoints include the PoC's 300 / 1500 / 3000 / 6000 / 9000 / 15000
        for (uint256 c; c < 30; c++) {
            uint256 v = this.flickerChunk(pB, c * 500, 500);
            if (v > maxVariance) maxVariance = v;
            assertEq(hook.currentFee(hookId), MIN_FEE, "fee after the flicker");
        }
        uint256 spent = (b0 + b1) - (currency0.balanceOfSelf() + currency1.balanceOfSelf());
        console2.log("H-1 regression, 15000 flicker blocks: fee (pips)", hook.currentFee(hookId));
        console2.log("  max stored variance (milli-tick^2):", maxVariance, " attacker token cost (wei):", spent);
        assertEq(hook.currentFee(hookId), MIN_FEE);
        assertLe(maxVariance, DUST_VARIANCE_BOUND);
        assertLt(spent, 1e6);
    }

    /// @dev `n` flicker blocks starting at block index `from`; external only so that each chunk's
    ///      memory is released (15,000 swaps in one frame run the test out of gas on memory expansion).
    ///      Returns the largest variance the hook stored during the chunk.
    function flickerChunk(uint160 pB, uint256 from, uint256 n) external returns (uint256 maxVariance) {
        require(msg.sender == address(this));
        for (uint256 i = from; i < from + n; i++) {
            if (i % 2 == 0) _moveToPrice(hookKey, pB - 1); // tick 0 -> -1
            else _moveToPrice(hookKey, pB); // tick -1 -> 0
            assertEq(_tick(hookKey), i % 2 == 0 ? int24(-1) : int24(0), "the integer tick does flip");
            vm.roll(block.number + 1);
            if (i % 5 == 4) vm.warp(block.timestamp + 1); // 200ms blocks
            uint256 v = _state().variance;
            if (v > maxVariance) maxVariance = v;
            if (i == 299) assertEq(hook.currentFee(hookId), MIN_FEE, "fee after 300 blocks");
        }
    }

    /// @dev The same flicker timed as badly as possible for the hook: the price sits on the other side
    ///      of the boundary at EVERY bucket change, so every single observation sees a move (of one
    ///      milli-tick). 600 buckets = 100 minutes = 10 half-lives. Still exactly the floor.
    function test_regression_H1_flickerAlignedToEveryBucketBoundary() public {
        uint160 pB = TickMath.getSqrtPriceAtTick(0);
        _moveToPrice(hookKey, pB);
        uint256 seen;
        for (uint256 i; i < 600; i++) {
            _nextBlock(BUCKET);
            int32 before_ = _state().lastLogPrice;
            _moveToPrice(hookKey, i % 2 == 0 ? pB - 1 : pB);
            if (_state().lastLogPrice != before_) seen++;
            assertLe(_state().variance, DUST_VARIANCE_BOUND);
            assertEq(_state().fee, MIN_FEE);
        }
        assertGe(seen, 598, "every observation did see the 1 milli-tick move");
        // (in fact the pile never exceeds 1: decay rounds down, so a single unit is gone a bucket later)
        assertEq(_state().variance, 1);
        assertEq(hook.currentFee(hookId), MIN_FEE);
    }

    function _rand(uint256 seed, uint256 i, uint256 salt) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, i, salt)));
    }

    /// @dev Adversarial dust fuzz (audit gap 1: the old handler's smallest swap was 1e9 wei and never hit
    ///      a boundary). 150 steps of whatever dust the seed picks: swaps of 1..1e6 wei either way,
    ///      exact-in or exact-out, or a price limit a few units of sqrtPriceX96 either side of a tick
    ///      boundary, separated by 1..120 blocks. No such sequence moves the fee off the floor.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_dustAttacker_cannotLiftFee(uint256 seed) public {
        uint160 pB = TickMath.getSqrtPriceAtTick(0);
        _moveToPrice(hookKey, pB);
        for (uint256 i; i < 150; i++) {
            uint256 kind = _rand(seed, i, 0) % 3;
            if (kind == 0) {
                // a few sqrtPriceX96 units around the boundary
                uint160 target = uint160(uint256(pB) + (_rand(seed, i, 1) % 7)) - 3;
                if (target != _sqrtPrice(hookKey)) _moveToPrice(hookKey, target);
            } else {
                int256 amount = int256(1 + _rand(seed, i, 1) % 1e6);
                bool zeroForOne = _rand(seed, i, 2) % 2 == 0;
                // exact-in or exact-out; a 1-wei swap may trade nothing at all, that is fine
                _swap(hookKey, zeroForOne, kind == 1 ? -amount : amount);
            }
            uint256 blocks = 1 + _rand(seed, i, 3) % 120;
            vm.roll(block.number + blocks);
            vm.warp(block.timestamp + blocks / 5);
            assertEq(hook.currentFee(hookId), MIN_FEE);
            assertLe(_state().variance, DUST_VARIANCE_BOUND);
        }
        // the price never really went anywhere
        int256 x = _logPrice(hookKey);
        assertLe(x, 1);
        assertGe(x, -1);
    }

    // ------------------------------------------------------------------------------------------
    // 3. Adversarial: what does it cost an attacker who is NOT an LP to raise the fee?
    // ------------------------------------------------------------------------------------------

    struct Seg {
        int24 lower;
        int24 upper;
        int256 liq;
    }

    uint256 internal constant SHAPES = 5;

    /// @dev Pool shapes the lower bound is searched on (re-audit, test gap: it used to run on shape 0 only).
    ///      0 uniform        1e24 over the wide range
    ///      1 concentrated   1e24 at the spot inside [-60, 60), 1e23 everywhere else
    ///      2 stepped        1.01e24 in [-120, 120), 5.1e23 in [120, 600), 2.1e23 in [-600, -120), 1e22 beyond
    ///      3 one-sided      1e24 in [0, 6000) and NOTHING below: the price starts just above the lower edge (N-1).
    ///                       A walk that picks its directions at random steps into the void almost surely
    ///                       (third-round audit: 256 probes, Lmin = 0 every time, the bound was never
    ///                       asserted). So shape 3 also runs UP-ONLY (every target above the start, chosen
    ///                       by bit 255 of the seed, or forced): there Lmin = 1e24 and the bound is asserted.
    ///      4 gap            1e24 in [-6000, 120) and in [180, 6000), nothing in [120, 180)
    function _shape(uint256 shape) internal pure returns (Seg[] memory segs) {
        if (shape == 0) {
            segs = new Seg[](1);
            segs[0] = Seg(WIDE_LOWER, WIDE_UPPER, 1e24);
        } else if (shape == 1) {
            segs = new Seg[](2);
            segs[0] = Seg(WIDE_LOWER, WIDE_UPPER, 1e23);
            segs[1] = Seg(-60, 60, 9e23);
        } else if (shape == 2) {
            segs = new Seg[](4);
            segs[0] = Seg(WIDE_LOWER, WIDE_UPPER, 1e22);
            segs[1] = Seg(-600, -120, 2e23);
            segs[2] = Seg(-120, 120, 1e24);
            segs[3] = Seg(120, 600, 5e23);
        } else if (shape == 3) {
            segs = new Seg[](1);
            segs[0] = Seg(0, 6000, 1e24);
        } else {
            segs = new Seg[](2);
            segs[0] = Seg(-6000, 120, 1e24);
            segs[1] = Seg(180, 6000, 1e24);
        }
    }

    function _liqAt(Seg[] memory segs, int24 tick) internal pure returns (uint256 l) {
        for (uint256 i; i < segs.length; i++) {
            if (segs[i].lower <= tick && tick < segs[i].upper) l += uint256(segs[i].liq);
        }
    }

    /// @dev smallest liquidity of any tick in [tLo, tHi]: liquidity only changes at segment ends
    function _minLiq(Seg[] memory segs, int24 tLo, int24 tHi) internal pure returns (uint256 m) {
        m = _liqAt(segs, tLo);
        for (uint256 i; i < segs.length; i++) {
            int24[2] memory ends = [segs[i].lower, segs[i].upper];
            for (uint256 j; j < 2; j++) {
                if (ends[j] > tLo && ends[j] <= tHi) {
                    uint256 l = _liqAt(segs, ends[j]);
                    if (l < m) m = l;
                }
            }
        }
    }

    function _floorTick(int256 milli) internal pure returns (int24) {
        int256 t = milli / 1000;
        if (milli % 1000 < 0) t -= 1;
        return int24(t);
    }

    /// @dev fresh pool of the given shape at log price 0 (mid-milli-tick), armed, fee at the floor.
    ///      The test contract is the LP and the attacker; it never collects, so what it is down by is
    ///      exactly what an attacker who owns no liquidity would be down by.
    function _shapedPool(Seg[] memory segs) internal returns (PoolKey memory k, PoolId id) {
        (Currency a, Currency b) = deployMintAndApprove2Currencies();
        (k, id) = _initDynamicPool(a, b, SQRT_PRICE_1_1);
        for (uint256 i; i < segs.length; i++) {
            modifyLiquidityRouter.modifyLiquidity(
                k, ModifyLiquidityParams(segs[i].lower, segs[i].upper, segs[i].liq, 0), ZERO_BYTES
            );
        }
        _arm(k);
        assertEq(uint256(manager.getLiquidity(id)), _liqAt(segs, 0), "shape: liquidity at the spot");
    }

    /// @dev Lower bound for ANY strategy of an attacker who owns no liquidity. One to twelve pushes (the
    ///      count comes from the seed; a fixed twelve never produced the short walks where the bound is
    ///      tight) of any size from 1 milli-tick to 300 ticks, in any direction (`upOnly`: every target
    ///      above the start), separated by 1..150 blocks; then the attacker
    ///      returns the price to where it started and we count what it is down (SIGNED: a gain would show).
    ///      G = the highest fee above the floor, in pips, that `currentFee` shows in any block along the
    ///      way, INCLUDING the bucket after the attacker is back home (the return leg is itself a move
    ///      that the next observation books; the previous version of this test did not look there).
    ///
    ///          loss >= 1.39 * G * Lmin * 1e-9
    ///
    ///      Lmin = the SMALLEST liquidity of any tick the price visited - not the liquidity at the spot.
    ///      On a path through a zero-liquidity stretch Lmin = 0 and the bound says nothing: there the fee
    ///      can be lifted to the cap for free (N-1, see VolatilityFeeHook.reaudit.t.sol).
    ///
    ///      Where 1.39 comes from (not fitted):
    ///        - G <= 25 * sqrt(sum of squared observed bucket moves d_i, in ticks); decay only lowers it.
    ///        - The d_i that are booked or pending when G is read sum to X = (price then) - (start), and
    ///          the attacker still has to travel |X| home. With P / N the sums of the positive / negative
    ///          d_i: travelled >= sum|d_i| + |X| = 2 * max(P, N) >= sqrt(2) * sqrt(sum d_i^2).
    ///        - Each tick travelled takes >= Lmin * 4.99988e-5 * exp(-0.015) of input (the price stays
    ///          within +-300 ticks of 1, so sqrtP is within 1.5% of 1) and pays >= the 0.05% floor fee.
    ///        => loss >= sqrt(2) * G / 25 * Lmin * 4.99988e-5 * 0.98511 * 5e-4 = 1.3931 * G * Lmin * 1e-9.
    ///      The bound is tight: test_costLowerBound_tightCase_outAndBack measures 1.46. The re-audit's
    ///      "smallest ratio 2.0" is the one-push case with G read BEFORE the unwind; reading the bucket
    ///      after the unwind as well brings it down to sqrt(2) for small pushes.
    function _costLowerBound(uint256 seed, uint256 shape, bool upOnly)
        internal
        returns (uint256 lMin, uint256 peakGain)
    {
        Seg[] memory segs = _shape(shape);
        (PoolKey memory k, PoolId id) = _shapedPool(segs);
        uint160 start = _sqrtPrice(k);
        int256 before_ = int256(_bal(k));
        Walk memory w;
        w.upOnly = upOnly;
        for (uint256 i; i < 1 + (seed >> 200) % 12; i++) {
            _randomPush(k, id, seed, i, w);
        }
        if (_sqrtPrice(k) != start) _moveToPrice(k, start);
        _nextBlock(BUCKET);
        if (hook.currentFee(id) - MIN_FEE > w.peakGain) w.peakGain = hook.currentFee(id) - MIN_FEE;

        int256 loss = before_ - int256(_bal(k));
        lMin = _minLiq(segs, _floorTick(w.lo), _floorTick(w.hi));
        peakGain = w.peakGain;
        assertGe(loss, int256((peakGain * lMin * 139) / 1e11), "cost per pip of fee, path-minimum liquidity");
        // where the bound is empty (Lmin = 0) the attacker still cannot come out ahead by more than dust
        assertGe(loss, -1000, "no net gain beyond rounding");
        if (shape == 0) assertEq(lMin, 1e24);
        // an up-only walk on the one-sided shape never leaves the liquidity: the bound above was a real one
        if (shape == 3 && upOnly) {
            assertEq(w.lo, 0, "up-only: never below the start");
            assertEq(lMin, 1e24, "one-sided, up-only: Lmin is the full liquidity");
        }
    }

    struct Walk {
        uint256 peakGain; // highest currentFee above the floor seen so far, pips
        int256 lo; // lowest / highest log price visited, milli-ticks
        int256 hi;
        bool upOnly; // every target above the start
    }

    function _randomPush(PoolKey memory k, PoolId id, uint256 seed, uint256 i, Walk memory w) internal {
        // magnitude log-uniform between 1 milli-tick and 300 ticks
        uint256 mag = 1 << (_rand(seed, i, 0) % 19); // 1 .. 262144 milli-ticks
        mag = mag + _rand(seed, i, 1) % mag;
        if (mag > 300_000) mag = 300_000;
        int256 target = w.upOnly || _rand(seed, i, 2) % 2 == 0 ? int256(mag) : -int256(mag);
        uint160 p = _priceAtLog(target);
        if (p != _sqrtPrice(k)) _moveToPrice(k, p);
        if (target < w.lo) w.lo = target;
        if (target > w.hi) w.hi = target;
        uint256 blocks = 1 + _rand(seed, i, 3) % 150;
        vm.roll(block.number + blocks);
        vm.warp(block.timestamp + blocks / 5);
        uint256 fee = hook.currentFee(id);
        assertGe(fee, MIN_FEE);
        if (fee - MIN_FEE > w.peakGain) w.peakGain = fee - MIN_FEE;
    }

    /// forge-config: default.fuzz.runs = 128
    function testFuzz_attacker_notLp_costLowerBound(uint256 seed) public {
        _costLowerBound(seed, 0, false);
    }

    /// @dev the same search on the concentrated / stepped / one-sided / gap shapes. On the one-sided
    ///      shape bit 255 of the seed makes the walk up-only (see _shape); a fuzz run cannot report how
    ///      often that happened, the two tests below do.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_attacker_notLp_costLowerBound_poolShapes(uint256 seed, uint8 shapeSeed) public {
        uint256 shape = 1 + shapeSeed % (SHAPES - 1);
        _costLowerBound(seed, shape, shape == 3 && seed >> 255 == 1);
    }

    /// @dev one-sided shape, always up-only: EVERY run asserts the bound with Lmin = 1e24 (the assert
    ///      on lMin is inside _costLowerBound and repeated here).
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_attacker_notLp_costLowerBound_oneSided_upOnly(uint256 seed) public {
        (uint256 lMin,) = _costLowerBound(seed, 3, true);
        assertEq(lMin, 1e24);
    }

    /// @dev Proof that "shape 3 and Lmin != 0" really occurs and that the bound it asserts is not the
    ///      trivial `loss >= 0`: 48 fixed seeds through the same entry point as the fuzz test. Seeds with
    ///      bit 255 set walk up-only; all of them must end with Lmin = 1e24, and a fee above the floor
    ///      (G > 0) must have been seen in at least half of them. The others walk both ways and are
    ///      counted for the record (they are expected to hit the void: Lmin = 0, bound empty).
    function test_costLowerBound_oneSided_boundIsReallyAsserted() public {
        uint256 upOnlyRuns;
        uint256 upOnlyNonZeroLMin;
        uint256 upOnlyWithGain;
        uint256 bothWaysNonZeroLMin;
        for (uint256 n; n < 48; n++) {
            uint256 seed = uint256(keccak256(abi.encode("one-sided", n)));
            bool upOnly = seed >> 255 == 1;
            uint256 snap = vm.snapshotState();
            (uint256 lMin, uint256 gain) = _costLowerBound(seed, 3, upOnly);
            vm.revertToState(snap);
            if (upOnly) {
                upOnlyRuns++;
                if (lMin != 0) upOnlyNonZeroLMin++;
                if (lMin != 0 && gain != 0) upOnlyWithGain++;
            } else if (lMin != 0) {
                bothWaysNonZeroLMin++;
            }
        }
        console2.log("one-sided shape, 48 seeds: up-only runs:", upOnlyRuns);
        console2.log("   up-only with Lmin != 0:", upOnlyNonZeroLMin, " of which G > 0:", upOnlyWithGain);
        console2.log("   both-ways runs with Lmin != 0:", bothWaysNonZeroLMin, "of", 48 - upOnlyRuns);
        assertGe(upOnlyRuns, 12, "the seed bit does select the variant");
        assertEq(upOnlyNonZeroLMin, upOnlyRuns, "every up-only run has Lmin != 0");
        assertGe(upOnlyWithGain * 2, upOnlyRuns, "and the bound had a non-zero right-hand side");
    }

    /// @dev _minLiq is what the bound stands on; pin it on the shapes above
    function test_costLowerBound_minLiqHelper() public pure {
        assertEq(_minLiq(_shape(1), 0, 0), 1e24);
        assertEq(_minLiq(_shape(1), -60, 59), 1e24);
        assertEq(_minLiq(_shape(1), -61, 0), 1e23);
        assertEq(_minLiq(_shape(1), 0, 60), 1e23);
        assertEq(_minLiq(_shape(2), -300, 300), 2.1e23);
        assertEq(_minLiq(_shape(2), 0, 300), 5.1e23);
        assertEq(_minLiq(_shape(2), -601, 0), 1e22);
        assertEq(_minLiq(_shape(3), 0, 300), 1e24);
        assertEq(_minLiq(_shape(3), -1, 0), 0);
        assertEq(_minLiq(_shape(4), -300, 119), 1e24);
        assertEq(_minLiq(_shape(4), 0, 120), 0);
        assertEq(_minLiq(_shape(4), 0, 300), 0);
        assertEq(_floorTick(-1), -1);
        assertEq(_floorTick(-1000), -1);
        assertEq(_floorTick(999), 0);
    }

    /// @dev The cheapest thing found: push +1 tick at the end of a bucket, come back first thing in the
    ///      next one. The bucket after that reads both moves (G = 25 * sqrt(1 + 2^(-1/60)) = 35 pips);
    ///      the two legs paid 0.05% and 0.0525%. Ratio loss / (G * L * 1e-9) = 1.46, just above the 1.39
    ///      of the bound and well under the 2.0 of the single-push table.
    function test_costLowerBound_tightCase_outAndBack() public {
        (PoolKey memory k, PoolId id) = _shapedPool(_shape(0));
        uint160 start = _sqrtPrice(k);
        int256 before_ = int256(_bal(k));
        _moveToLog(k, 1000);
        _nextBlock(BUCKET);
        assertEq(hook.currentFee(id), 525);
        _moveToPrice(k, start);
        _nextBlock(BUCKET);
        uint256 g = hook.currentFee(id) - MIN_FEE;
        assertEq(g, 35);
        int256 loss = before_ - int256(_bal(k));
        uint256 ratioMilli = (uint256(loss) * 1000) / (g * 1e15);
        console2.log("tight case, 1 tick out and back: loss (wei)", uint256(loss), " ratio x1000:", ratioMilli);
        assertGe(ratioMilli, 1390);
        assertLe(ratioMilli, 1500);
    }

    /// @dev Re-audit: the cost table's "unwind in the very next bucket" is not the cheapest way to hold a
    ///      one-off fee spike. Patient unwind: push +D as the last trade of a bucket, book the observation
    ///      in the next bucket with a 1 wei swap (the raised fee is now live for everybody), wait until the
    ///      fee is back at the floor, then unwind at the floor fee. Cost = 2 * floor fee * notional,
    ///      i.e. ratio 2.0 for every D, against 2.0 .. 21 for the immediate unwind. The price of patience
    ///      is holding the position (inventory risk, and an arbitrageur may take the displaced price).
    function test_crossBucketPush_patientUnwind_costsTwiceTheFloorFee() public {
        uint256[7] memory ds = [uint256(40), 1000, 20_000, 50_000, 100_000, 200_000, 380_000]; // milli-ticks
        console2.log("D (milli-tick) | G (pips) | immediate unwind: loss (1e-6 token), ratio x1000 | patient unwind: loss, ratio");
        for (uint256 i; i < ds.length; i++) {
            uint256 g;
            int256 lossFast;
            int256 lossSlow;
            uint256 notional;
            uint160 p0 = _sqrtPrice(hookKey);
            int256 bal = int256(_bal(hookKey));
            {
                uint256 snap = vm.snapshotState();
                (BalanceDelta push,) = _moveToLog(hookKey, int256(ds[i]));
                notional = uint256(uint128(-push.amount1()));
                _nextBlock(BUCKET);
                g = hook.currentFee(hookId) - MIN_FEE;
                _moveToPrice(hookKey, p0);
                lossFast = bal - int256(_bal(hookKey));
                vm.revertToState(snap);
            }
            {
                uint256 snap = vm.snapshotState();
                _moveToLog(hookKey, int256(ds[i]));
                _nextBlock(BUCKET);
                (, uint24 charged) = _swap(hookKey, true, -1); // 1 wei books the observation
                assertEq(charged - MIN_FEE, g, "the raised fee is live");
                _nextBlock(600 * 70); // 70 half-lives
                _swap(hookKey, true, -1);
                assertEq(hook.currentFee(hookId), MIN_FEE);
                (, charged) = _moveToPrice(hookKey, p0);
                assertEq(charged, MIN_FEE, "unwind at the floor fee");
                lossSlow = bal - int256(_bal(hookKey));
                vm.revertToState(snap);
            }
            assertEq(g, (25 * ds[i]) / 1000);
            assertGt(lossSlow, 0);
            assertGe(lossFast, lossSlow);
            // 2 * 0.05% of the notional (the two legs differ by the price move and the 2 wei: 2% slack)
            assertApproxEqRel(uint256(lossSlow) * 1e6, notional * 1000, 0.02e18, "patient = 2 * floor * notional");
            uint256 unit = g * 1e15; // G * L * 1e-9, L = 1e24
            uint256 rFast = (uint256(lossFast) * 1000) / unit;
            uint256 rSlow = (uint256(lossSlow) * 1000) / unit;
            console2.log(ds[i], g);
            console2.log("     ", uint256(lossFast) / 1e12, rFast);
            console2.log("     ", uint256(lossSlow) / 1e12, rSlow);
            assertApproxEqAbs(rSlow, 2000, 60, "patient ratio is 2.0");
            assertGe(rFast, 1990);
        }
    }

    // ------------------------------------------------------------------------------------------
    // 4. M-1: the same push, done by an LP who owns a share s of the liquidity
    // ------------------------------------------------------------------------------------------

    bytes32 internal constant ATTACKER_SALT = bytes32(uint256(0xA77AC));

    /// @dev fresh armed pool, total liquidity 1e24 in the wide range, `shareBps` of it in a position
    ///      the attacker can collect fees from (same range, its own salt), the rest belongs to others
    function _poolWithAttackerShare(uint256 shareBps) internal returns (PoolKey memory k, PoolId id) {
        (Currency a, Currency b) = deployMintAndApprove2Currencies();
        (k, id) = _initDynamicPool(a, b, SQRT_PRICE_1_1);
        int256 mine = (WIDE_LIQUIDITY * int256(shareBps)) / 10_000;
        if (mine != 0) {
            modifyLiquidityRouter.modifyLiquidity(
                k, ModifyLiquidityParams(WIDE_LOWER, WIDE_UPPER, mine, ATTACKER_SALT), ZERO_BYTES
            );
        }
        if (mine != WIDE_LIQUIDITY) {
            modifyLiquidityRouter.modifyLiquidity(
                k, ModifyLiquidityParams(WIDE_LOWER, WIDE_UPPER, WIDE_LIQUIDITY - mine, 0), ZERO_BYTES
            );
        }
        _arm(k);
    }

    struct Cost {
        uint256 notional; // token1 the attacker had to sell to displace the price
        uint256 gross; // token0 + token1 the attacker is down after unwinding (price ~ 1:1)
        int256 net; // the same after collecting the LP fees of its own position; SIGNED, negative = came out ahead
        uint24 feeNext; // LP fee the pool charges in the bucket after the push
        uint24 feeAfterUnwind; // LP fee in the bucket after the attacker unwound
    }

    function _bal(PoolKey memory k) internal view returns (uint256) {
        return k.currency0.balanceOfSelf() + k.currency1.balanceOfSelf();
    }

    /// @dev Attacker pushes the price +D ticks as the last trade of a bucket and unwinds as the first
    ///      trade of the next one, with nobody trading against them in between (the attacker's best
    ///      case; on a real chain an arbitrageur can take the displaced price first). Then it collects
    ///      whatever LP fees its own position earned from those two swaps.
    function _pushUnwindCollect(PoolKey memory k, int24 d, bool isLp) internal returns (Cost memory c) {
        PoolId id = k.toId();
        uint160 p = _sqrtPrice(k);
        int256 target = int256(_logPrice(k)) + int256(d) * 1000;
        if (isLp) {
            // collect what the position earned BEFORE the push (the arming swap paid ~1.25e13 wei of fees);
            // otherwise the signed net below would show that as a gain of the push
            modifyLiquidityRouter.modifyLiquidity(
                k, ModifyLiquidityParams(WIDE_LOWER, WIDE_UPPER, 0, ATTACKER_SALT), ZERO_BYTES
            );
        }
        uint256 b = _bal(k);

        (BalanceDelta push,) = _moveToLog(k, target);
        c.notional = uint256(uint128(-push.amount1()));

        _nextBlock(BUCKET);
        // exactly the designed mapping of a D-tick bucket-to-bucket move, never more
        uint24 designed = _designedFee(id, int32(target));
        (, uint24 charged) = _moveToPrice(k, p); // unwind; pays the fee the push itself caused
        c.feeNext = hook.poolState(id).fee;
        assertEq(c.feeNext, designed);
        assertLe(c.feeNext, MAX_FEE);
        assertGe(charged, c.feeNext); // equal without a protocol fee

        c.gross = b - _bal(k);
        if (isLp) {
            modifyLiquidityRouter.modifyLiquidity(
                k, ModifyLiquidityParams(WIDE_LOWER, WIDE_UPPER, 0, ATTACKER_SALT), ZERO_BYTES
            );
        }
        uint256 a = _bal(k);
        c.net = int256(b) - int256(a);

        _nextBlock(BUCKET);
        c.feeAfterUnwind = hook.currentFee(id);
    }

    /// @dev fee the model assigns to observing `logNow` right now, from the stored state
    function _designedFee(PoolId id, int32 logNow) internal view returns (uint24) {
        VolatilityFeeHook.PoolState memory s = hook.poolState(id);
        return VolatilityMath.feeFromVariance(
            VolatilityMath.accumulate(s.variance, block.timestamp - s.lastTimestamp, s.lastLogPrice, logNow)
        );
    }

    /// @dev The cost table of the design note, in NET terms. Rows: target fee increase X = 25 * D.
    ///      Columns: attacker's LP share s = 0, 50%, 100%. Pool: L = 1e24, wide range, fee at the floor
    ///      before the push, no protocol fee.
    function test_crossBucketPush_netCostTable() public {
        int24[5] memory ds = [int24(20), 50, 100, 200, 380];
        uint256[3] memory shares = [uint256(0), 5000, 10_000];
        console2.log("push D ticks at the end of a bucket, unwind first thing in the next one (L = 1e24)");
        console2.log("D | fee next bucket (pips) | notional (token) | net cost (1e-6 token) at LP share 0 / 50% / 100%");
        for (uint256 i; i < ds.length; i++) {
            int256[3] memory net;
            Cost memory c;
            for (uint256 j; j < 3; j++) {
                (PoolKey memory k,) = _poolWithAttackerShare(shares[j]);
                c = _pushUnwindCollect(k, ds[i], shares[j] != 0);
                net[j] = c.net;
                uint24 expectedFee = uint24(500 + 25 * uint256(uint24(ds[i])));
                assertEq(c.feeNext, expectedFee, "fee next bucket = 500 + 25 * D");
                if (j == 0) {
                    // not an LP: pays the floor fee on the way in and the self-inflicted fee on the way
                    // out, on roughly the notional each time (5% slack: legs differ slightly in size)
                    assertEq(c.net, int256(c.gross));
                    assertApproxEqRel(c.gross * 1e6, c.notional * (500 + uint256(expectedFee)), 0.05e18);
                } else if (j == 1) {
                    assertApproxEqRel(c.net, net[0] / 2, 0.001e18, "half the fees come back");
                } else {
                    // signed (re-audit N-2): the sole LP may come out a few wei AHEAD or behind
                    assertLt(c.net, 1000, "sole LP: everything comes back except rounding dust (wei)");
                    assertGt(c.net, -1000, "sole LP: and it does not gain more than rounding dust either");
                }
            }
            console2.log(uint256(uint24(ds[i])), c.feeNext, c.notional / 1e18);
            console2.log("    ", uint256(net[0]) / 1e12, uint256(net[1]) / 1e12);
            console2.log("     sole LP net cost in wei, signed (negative = net gain):", net[2]);
            console2.log("     fee in the bucket after the unwind:", c.feeAfterUnwind);
        }
    }

    /// @dev The audit's PoC-2, kept as a record of the fact (M-1), not as something that is fixed:
    ///      an LP who owns all the liquidity pushes 100 ticks across a bucket boundary and back. The
    ///      next bucket's fee is 0.30%; before collecting its own LP fees the LP is down ~0.35% of the
    ///      notional, after collecting it is down a few wei. This is inherent to any fee that is derived
    ///      from the pool's own price.
    function test_fact_M1_soleLp_crossBucketPushIsFree() public {
        (PoolKey memory k,) = _poolWithAttackerShare(10_000);
        Cost memory c = _pushUnwindCollect(k, 100, true);
        assertEq(c.feeNext, 3000);
        assertGt(c.notional, 4.9e21);
        assertApproxEqRel(c.gross * 1e6, c.notional * 3500, 0.05e18); // ~1.76e19 before collecting
        assertLt(c.net, 1000); // wei, signed
        assertGt(c.net, -1000);
        // and the push+unwind left two 100-tick observations behind
        assertEq(c.feeAfterUnwind, VolatilityMath.feeFromVariance(VolatilityMath.decay(1e10, 10) + 1e10));
        assertEq(c.feeAfterUnwind, 4025);
    }

    /// @dev What the sole LP cannot get back is the protocol fee, if the pool has one.
    function test_fact_M1_soleLp_paysOnlyTheProtocolFee() public {
        (PoolKey memory k,) = _poolWithAttackerShare(10_000);
        _setProtocolFee(k, 1000, 1000); // 0.10% each way, the maximum
        Cost memory c = _pushUnwindCollect(k, 100, true);
        assertEq(c.feeNext, 3000);
        // 0.10% of both legs, each about the notional
        assertGt(c.net, 0);
        assertApproxEqRel(uint256(c.net) * 1e6, c.notional * 2000, 0.05e18);
        console2.log("sole LP, protocol fee 0.10%: net cost (1e-6 token)", uint256(c.net) / 1e12, "notional (token)", c.notional / 1e18);
    }

    function test_crossBucketPush_hardNumbers_100ticks_notLp() public {
        _withHistory();
        _swap(hookKey, true, -TINY); // observe the +40 history: fee 0.15%
        Cost memory c = _pushUnwindCollect(hookKey, 100, false);
        // before: variance 1600e6 (40 ticks). after a 100-tick push seen one bucket later:
        assertEq(c.feeNext, VolatilityMath.feeFromVariance(VolatilityMath.decay(1600e6, 10) + 1e10));
        assertEq(c.feeNext, 3190);
        // round trip cost: 0.15% in + 0.319% out = ~0.47% of the notional, here ~5e21 token1
        assertGt(c.net, 0);
        uint256 lossPips = (uint256(c.net) * 1e6) / c.notional;
        assertApproxEqAbs(lossPips, 1500 + 3190, 150);
        assertGt(c.notional, 4.9e21);
    }

    /// @dev Worst case for traders is the hard cap: no displacement, however large, gets past MAX_FEE.
    function test_crossBucketPush_cappedAtMaxFee() public {
        Cost memory c = _pushUnwindCollect(hookKey, 50_000, false);
        assertEq(c.feeNext, MAX_FEE);
        assertEq(c.feeAfterUnwind, MAX_FEE);
    }

    // ------------------------------------------------------------------------------------------
    // 5. Sustained zig-zag, and the fee cannot be pushed down
    // ------------------------------------------------------------------------------------------

    /// @dev Holding the fee up with a small zig-zag: the price is moved d ticks at every bucket change,
    ///      back and forth, for 300 buckets (50 minutes, 5 half-lives). The steady state is
    ///      d^2 * 87.06 tick^2. Before the fix a zig-zag was counted every BLOCK (5 per second,
    ///      d^2 * 4328 tick^2) and d = 1 tick cost 2 wei; now d must be a real move every 10 seconds and
    ///      each one pays the fee on the input that moves the price d ticks.
    function test_sustainedZigzag_costAndEffect() public {
        int24[3] memory ds = [int24(1), 3, 7];
        uint24[3] memory expected = [uint24(729), 1188, 2107];
        console2.log("zig-zag of d ticks at every bucket change, 300 buckets, attacker not an LP (L = 1e24)");
        console2.log("d | steady fee (pips) | attacker cost per bucket (1e-6 token) | per day (token)");
        for (uint256 i; i < 3; i++) {
            uint256 snap = vm.snapshotState();
            uint256 b = _bal(hookKey);
            uint256 last;
            for (uint256 n; n < 300; n++) {
                last = _bal(hookKey);
                _moveTo(hookKey, n % 2 == 0 ? ds[i] : int24(0));
                _nextBlock(BUCKET);
            }
            uint256 fee = hook.currentFee(hookId);
            uint256 total = b - _bal(hookKey);
            uint256 perBucket = total / 300;
            console2.log(uint256(uint24(ds[i])), fee, perBucket / 1e12, (perBucket * 8640) / 1e18);
            assertEq(fee, expected[i]);
            // vol = d * sqrt(87.06 * (1 - 2^-5)) = 9.18 * d ticks
            assertApproxEqAbs(fee, 500 + (25 * 9184 * uint256(uint24(ds[i]))) / 1000, 3);
            // every leg paid at least the floor fee on ~L * 5e-5 * d of input
            assertGe(perBucket, (uint256(WIDE_LIQUIDITY) * 5 * uint256(uint24(ds[i])) * 500 * 95) / 1e13);
            vm.revertToState(snap);
        }
    }

    /// @dev The fee cannot be pushed DOWN: with the price pinned, the fee follows the decay curve and
    ///      trading (any amount, same price at the bucket's close) never makes it fall faster.
    function test_cannotAccelerateDecay() public {
        _moveTo(hookKey, 400);
        _nextBlock(BUCKET);
        _swap(hookKey, true, -TINY);
        uint256 v = _state().variance;
        uint256 v0 = v;
        assertGt(v, 100_000e6);

        for (uint256 i; i < 20; i++) {
            // wash trading inside each bucket, closing on the same price
            uint160 p = _sqrtPrice(hookKey);
            _moveTo(hookKey, 400 + int24(int256(i % 3 + 1)) * 30);
            _moveToPrice(hookKey, p);
            _nextBlock(30);
            (, uint24 fee) = _swap(hookKey, true, -TINY);
            v = VolatilityMath.decay(v, 30);
            // the 20 TINY swaps drift the price by a fraction of a milli-tick; at most 1 unit shows up
            assertApproxEqAbs(_state().variance, v, 1);
            assertGe(_state().variance, v, "never below the pure-decay path");
            v = _state().variance;
            assertEq(fee, VolatilityMath.feeFromVariance(v));
        }
        // 600s = one half-life, in 20 steps of 30s: within 2% of an exact halving
        assertApproxEqRel(v, v0 / 2, 0.02e18);
    }
}
