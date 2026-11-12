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
import {HookTestBase} from "./utils/HookTestBase.sol";

/// @notice Facts recorded by the re-audit (audits/audit-hooks-h1-reaudit.md), adapted from the auditor's
///         PoCs (audits/audit-hooks-h1/ReAudit.t.sol). These are NOT fixes: the contract is unchanged.
///         Each test pins a limitation that the design note states, so that the note cannot drift away
///         from what the code does. Run with -vv for the numbers quoted in docs/VolatilityFeeHook.md.
///
///         N-1  price next to a zero-liquidity stretch: anybody lifts the fee to the 1% cap for nothing
///         E-A  a dominant LP sets the fee anywhere in [0.05%, 1%]: its zig-zag shields itself from arbitrage
///
///         All balances are compared as SIGNED numbers (N-2): a net gain would be printed as negative cost.
contract VolatilityFeeHookReAuditTest is HookTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev the lower bound of the design note applied (wrongly) with the liquidity AT THE SPOT:
    ///      1.39 * G * L * 1e-9 with G = 9500 pips (floor -> cap) and L = 1e24, in wei
    uint256 internal constant NAIVE_BOUND_TO_CAP = (9500 * 1e24 * 139) / 1e11; // 13.2 token

    function setUp() public {
        _baseSetUp();
    }

    function _bal(PoolKey memory k) internal view returns (int256) {
        return int256(k.currency0.balanceOfSelf() + k.currency1.balanceOfSelf());
    }

    /// @dev single-sided "launch" liquidity: 1e24 in [0, 6000), nothing below; price exactly on the lower edge
    function _oneSidedPool() internal returns (PoolKey memory k, PoolId id) {
        (Currency a, Currency b) = deployMintAndApprove2Currencies();
        (k, id) = _initDynamicPool(a, b, TickMath.getSqrtPriceAtTick(0));
        modifyLiquidityRouter.modifyLiquidity(k, ModifyLiquidityParams(0, 6000, 1e24, 0), ZERO_BYTES);
        assertEq(manager.getLiquidity(id), 1e24, "real in-range liquidity");
    }

    // ------------------------------------------------------------------------------------------
    // N-1
    // ------------------------------------------------------------------------------------------

    /// @dev Price exactly on the edge of the liquidity. Two swaps by anybody, one bucket apart: down
    ///      into the void (the pool has nothing to sell there, so the swap moves the price and no
    ///      tokens) and back. Not one wei changes hands, and the fee is at the 1% cap.
    function test_fact_N1_priceOnLiquidityEdge_anyoneLiftsFeeToCapForNothing() public {
        (PoolKey memory k, PoolId id) = _oneSidedPool();
        int256 bal = _bal(k);

        _nextBlock(BUCKET);
        // the observation of this swap sees L = 1e24 and arms the pool at tick 0; the swap itself is free
        _moveToPrice(k, TickMath.getSqrtPriceAtTick(-50_000));
        assertTrue(hook.poolState(id).armed);
        assertEq(manager.getLiquidity(id), 0, "price now sits in the void");
        assertEq(_bal(k), bal, "walking into the void moved no tokens");

        _nextBlock(BUCKET);
        assertEq(hook.currentFee(id), MAX_FEE, "already at the cap for whoever trades next");
        _moveToPrice(k, TickMath.getSqrtPriceAtTick(0));

        int256 cost = bal - _bal(k);
        console2.log("N-1, price on the edge: attacker net cost, signed (wei):", cost);
        assertEq(cost, 0, "attacker spent exactly nothing");
        assertEq(hook.poolState(id).fee, MAX_FEE);
        assertEq(manager.getLiquidity(id), 1e24, "pool is back where it was");

        // the bound of the design note does NOT hold with the liquidity at the spot (it would demand 13.2 token)
        assertLt(uint256(cost), NAIVE_BOUND_TO_CAP);

        // honest traders now pay 1%, in this bucket and the next (the walk back is booked there)
        (, uint24 fee) = _swap(k, false, -1e18);
        assertEq(fee, MAX_FEE);
        _nextBlock(BUCKET);
        (, fee) = _swap(k, false, -1e18);
        assertEq(fee, MAX_FEE);
    }

    /// @dev The same after an honest first buy of 1e18 has armed the pool and moved the price a little
    ///      into the range: the attacker has to sell that 1e18 back through real liquidity before it
    ///      reaches the void, and buy it back at 1% afterwards. Cost ~0.0105 token (0.05% + 1% of ~1 token)
    ///      - one part in 1,250 of what the bound would demand with the liquidity at the spot.
    function test_fact_N1_afterHonestBuy_liftToCapCostsDust() public {
        (PoolKey memory k, PoolId id) = _oneSidedPool();
        _nextBlock(BUCKET);
        (, uint24 fee) = _swap(k, false, -1e18);
        assertEq(fee, MIN_FEE);
        assertTrue(hook.poolState(id).armed);
        uint160 pHonest = _sqrtPrice(k);

        // ---- attacker, any later moment ----
        int256 bal = _bal(k);
        _nextBlock(BUCKET - 1);
        _moveToPrice(k, TickMath.getSqrtPriceAtTick(-50_000));
        assertEq(manager.getLiquidity(id), 0);
        _nextBlock(1); // next bucket
        assertEq(block.timestamp % BUCKET, 0);
        assertEq(hook.currentFee(id), MAX_FEE);
        _moveToPrice(k, pHonest);
        int256 cost = bal - _bal(k);
        console2.log("N-1, after an honest 1e18 buy: attacker net cost, signed (wei):", cost);
        assertEq(hook.poolState(id).fee, MAX_FEE);
        assertEq(manager.getLiquidity(id), 1e24);
        assertGt(cost, 0.0100e18);
        assertLt(cost, 0.0110e18);
        assertLt(uint256(cost) * 1000, NAIVE_BOUND_TO_CAP, "three orders of magnitude under the spot-liquidity bound");

        // what the next traders pay, and how long it lasts
        (, fee) = _swap(k, false, -1e18);
        assertEq(fee, MAX_FEE);
        _nextBlock(BUCKET);
        (, fee) = _swap(k, false, -1e18);
        assertEq(fee, MAX_FEE);
        _nextBlock(600);
        uint24 f10 = hook.currentFee(id);
        _nextBlock(3600);
        uint24 f70 = hook.currentFee(id);
        console2.log("N-1 fee 10 min / 70 min after the last 1% trade (pips):", f10, f70);
        assertApproxEqAbs(f10, 7217, 5);
        assertApproxEqAbs(f70, 1339, 5);
    }

    /// @dev Same root cause, the other common way to get there: an LP concentrated in a narrow range and
    ///      a market that has moved out of it. The pool was armed long ago inside the range; once the
    ///      price is outside, moving it further costs nothing.
    function test_fact_N1_priceLeftTheRange_freeLift() public {
        (Currency a, Currency b) = deployMintAndApprove2Currencies();
        (PoolKey memory k, PoolId id) = _initDynamicPool(a, b, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(k, ModifyLiquidityParams(-600, 600, 1e24, 0), ZERO_BYTES);
        _arm(k);
        // the market buys the whole range out; one day passes
        _moveToPrice(k, TickMath.getSqrtPriceAtTick(600));
        assertEq(manager.getLiquidity(id), 0);
        // (limit swaps of one sqrtPrice unit: an unlimited swap in the void would run to the end of the price range)
        _nextBlock(1 days);
        // (and resting a few units above the edge: a downward swap that reaches the edge exactly re-enters the range)
        uint160 pOut = TickMath.getSqrtPriceAtTick(600) + 10;
        _moveToPrice(k, pOut + 1); // books the honest 600-tick move
        _nextBlock(1 days);
        _moveToPrice(k, pOut);
        assertEq(hook.poolState(id).fee, MIN_FEE, "fully decayed");
        assertEq(manager.getLiquidity(id), 0);

        int256 bal = _bal(k);
        _nextBlock(BUCKET);
        _moveToPrice(k, TickMath.getSqrtPriceAtTick(50_000)); // further out: free
        _nextBlock(BUCKET);
        _moveToPrice(k, pOut);
        assertEq(bal - _bal(k), 0, "attacker spent exactly nothing");
        assertEq(hook.poolState(id).fee, MAX_FEE);
        // whoever now sells into the range pays 1%
        (, uint24 fee) = _swap(k, true, -1e18);
        assertEq(fee, MAX_FEE);
    }

    // ------------------------------------------------------------------------------------------
    // E-A
    // ------------------------------------------------------------------------------------------

    /// @dev The test contract owns ALL the liquidity of hookKey. One swap per bucket, zig-zag around the
    ///      outside price (log 0), with an amplitude that always stays INSIDE the LP fee of the bucket
    ///      during which the displaced price is exposed. An arbitrageur needs displacement > fee to
    ///      profit, so there is never anything to take: the saw-tooth shields itself. Besides comparing
    ///      fee and displacement in every bucket, each time the margin reaches a new low an arbitrage is
    ///      really attempted at seven sizes (_tryArbitrage) and must lose.
    ///      Result (asserted): the fee climbs from the floor to >= 0.99% in under an hour and then stays
    ///      there with one 41-tick swap per bucket, and after collecting its own LP fees the LP is out
    ///      of pocket by a few wei. In a pool with a dominant LP the fee is whatever that LP wants it
    ///      to be within [0.05%, 1%].
    function test_fact_EA_soleLp_selfShieldedZigzag_setsFeeAtWill() public {
        modifyLiquidityRouter.modifyLiquidity(hookKey, ModifyLiquidityParams(WIDE_LOWER, WIDE_UPPER, 0, 0), ZERO_BYTES);
        int256 bal = _bal(hookKey);
        int256 pos; // current log price, milli-ticks
        uint256 worstMarginPips = type(uint256).max; // min over buckets of (fee - displacement), pips
        uint256 bucketsToCap;
        uint256 minFeeAfterCap = type(uint256).max;
        uint256 worstMarginBucket;
        uint256 arbBucketsTried;
        int256 bestArbAtWorstMargin;
        for (uint256 n; n < 600; n++) {
            // 1 tick = 100 pips of price; amplitude 3% inside the current fee, at most 41 ticks
            int256 d = int256((uint256(hook.currentFee(hookId)) * 10 * 97) / 100);
            if (d > 41_000) d = 41_000;
            int256 target = pos == 0 ? d : int256(0);
            _moveToLog(hookKey, target);
            pos = target;
            _nextBlock(BUCKET);
            uint256 fNext = hook.currentFee(hookId);
            uint256 dispPips = uint256(pos) / 10;
            if (pos != 0) {
                assertGt(fNext, dispPips, "displacement is inside the fee: nothing to arbitrage");
                if (fNext - dispPips < worstMarginPips) {
                    // a new thinnest margin (the last one of these is the thinnest bucket of the run):
                    // do not only compare two numbers, let an arbitrageur actually try
                    worstMarginPips = fNext - dispPips;
                    worstMarginBucket = n;
                    bestArbAtWorstMargin = _tryArbitrage(pos, uint24(fNext));
                    arbBucketsTried++;
                }
            }
            if (bucketsToCap == 0 && fNext >= 9900) bucketsToCap = n + 1;
            if (bucketsToCap != 0 && fNext < minFeeAfterCap) minFeeAfterCap = fNext;
        }
        if (pos != 0) _moveToLog(hookKey, 0);
        int256 gross = bal - _bal(hookKey);
        modifyLiquidityRouter.modifyLiquidity(hookKey, ModifyLiquidityParams(WIDE_LOWER, WIDE_UPPER, 0, 0), ZERO_BYTES);
        int256 net = bal - _bal(hookKey);
        console2.log("E-A sole-LP shielded zig-zag: buckets until fee >= 9900:", bucketsToCap);
        console2.log("   lowest fee in the buckets after that (pips):", minFeeAfterCap);
        console2.log("   worst (fee - displacement) margin (pips):", worstMarginPips, " in bucket", worstMarginBucket);
        console2.log("   buckets where an arbitrage was actually attempted:", arbBucketsTried);
        console2.log("   best arbitrage result in the thinnest bucket, signed (wei):", bestArbAtWorstMargin);
        assertGt(arbBucketsTried, 0);
        assertLe(bestArbAtWorstMargin, 0, "thinnest bucket: every attempted arbitrage loses");
        console2.log("   fees paid as a swapper over 600 buckets, signed (wei):", gross);
        console2.log("   net cost after collecting own LP fees, signed (wei):", net);
        assertGt(bucketsToCap, 0, "reached 0.99%");
        assertLt(bucketsToCap, 360, "in under an hour");
        assertGe(minFeeAfterCap, 9900, "and held there with one 41-tick swap per bucket");
        assertGt(worstMarginPips, 0);
        assertGt(gross, 100e18, "it did pay real fees as a swapper");
        assertLt(net, 1e6, "which all came back");
        assertGt(net, -1e6);
    }

    /// @dev A real arbitrage attempt against the displaced price of hookKey (log price `pos` > 0, outside
    ///      price = log 0), as the first trade of the current bucket: sell token0 into the pool, value
    ///      both legs at the outside price 1. Tried: three fixed sizes, a quarter / half / all of the way
    ///      back to the outside price, and past it. Each attempt is rolled back. Every one must lose
    ///      (asserted); returns the best (least negative) result in wei.
    function _tryArbitrage(int256 pos, uint24 expectedFee) internal returns (int256 best) {
        best = type(int256).min;
        int256[3] memory amounts = [int256(1e12), 1e18, 1e21];
        int256[4] memory targets = [(pos * 3) / 4, pos / 2, int256(0), -pos / 2];
        for (uint256 i; i < 7; i++) {
            uint256 snap = vm.snapshotState();
            BalanceDelta d;
            uint24 charged;
            if (i < 3) (d, charged) = _swap(hookKey, true, -amounts[i]);
            else (d, charged) = _moveToLog(hookKey, targets[i - 3]);
            assertEq(charged, expectedFee, "the arbitrageur pays the raised fee");
            assertLt(d.amount0(), 0, "it did trade");
            int256 profit = int256(d.amount0()) + int256(d.amount1());
            assertLe(profit, 0, "arbitrage against the saw-tooth is not profitable at any size tried");
            if (profit > best) best = profit;
            vm.revertToState(snap);
        }
    }

    /// @dev What "being arbitraged" really costs a sole LP after ONE big push (measured, replaces the
    ///      design note's old estimate of "about half the displacement"): the LP pushes +D ticks as the
    ///      last trade of a bucket; first thing in the next bucket an arbitrageur trades the price back
    ///      until the marginal price net of the (raised) LP fee equals the outside price. The LP gets
    ///      the fees back, so its loss is the arbitrageur's profit.
    function test_fact_EA_soleLp_singlePush_thenArbitraged() public {
        int256[4] memory ds = [int256(20), 100, 200, 380];
        // measured: 0.025%, 0.244%, 0.523%, 1.023% of the notional (pips of 1e6); 3% tolerance
        uint256[4] memory expectedPips = [uint256(250), 2440, 5230, 10_230];
        console2.log("D ticks | fee next bucket (pips) | push notional (token) | sole-LP loss = arb profit (1e-6 token) | pips of notional");
        for (uint256 i; i < 4; i++) {
            uint256 snap = vm.snapshotState();
            vm.roll(block.number + 49);
            vm.warp(block.timestamp + 9);
            (BalanceDelta push,) = _moveToLog(hookKey, ds[i] * 1000);
            uint256 notional = uint256(uint128(-push.amount1()));
            _nextBlock(1);
            uint24 f = hook.currentFee(hookId);
            assertEq(f, uint24(uint256(500 + 25 * ds[i])));
            // the arb sells token0 down to where price * (1 - fee) = 1: log price = fee (1 pip = 10 milli-ticks)
            (BalanceDelta arb, uint24 charged) = _moveToLog(hookKey, int256(uint256(f)) * 10 + 20);
            assertEq(charged, f);
            int256 profit = int256(arb.amount1()) + int256(arb.amount0());
            assertGt(profit, 0);
            uint256 pips = (uint256(profit) * 1e6) / notional;
            console2.log(uint256(ds[i]), f, notional / 1e18);
            console2.log("      ", uint256(profit) / 1e12, pips);
            assertApproxEqRel(pips, expectedPips[i], 0.03e18);
            // well under the old "half the displacement" estimate (D ticks = 100 * D pips)
            assertLt(pips, uint256(ds[i]) * 50);
            vm.revertToState(snap);
        }
    }
}
