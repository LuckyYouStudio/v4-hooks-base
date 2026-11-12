// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PriorityFeeTestBase} from "./utils/PriorityFeeTestBase.sol";
import {CheckedSwapRouter} from "./utils/CheckedSwapRouter.sol";

/// @notice Just-in-time liquidity around a surcharged swap (docs/PriorityFeeHook.md section 9). These are
///         the hook-auditor's round-1 PoCs (audits/audit-hooks-h2/AuditH2.t.sol, findings E-1, E-2, E-3),
///         kept as regression tests with the numbers the design note quotes pinned down, plus two
///         additions from the round-2 re-check (the capital a flash JIT needs; a fuzz of on-path JITs only).
///         `test_fact_...` records a LIMITATION. Run with -vv to print the tables.
/// @dev Both tokens are 18-decimal mocks and the pool starts at price 1; "P&L at price 1" adds the two
///      token amounts. Where a number is compared with a gas cost the tokens are treated as ETH and the
///      gas figure is an ASSUMPTION, stated at the place.
contract PriorityFeeHookJitTest is PriorityFeeTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant ATT = 1; // the JIT provider's position
    uint256 internal constant OTH = 2; // the incumbent LPs' position

    PoolKey internal k;
    CheckedSwapRouter internal checked;

    function setUp() public {
        _baseSetUp();
        checked = new CheckedSwapRouter(manager);
    }

    /// @dev fresh pool at price 1 with only the incumbents' wide position
    function _fresh(int256 othersLiquidity) internal {
        (Currency a, Currency b) = deployMintAndApprove2Currencies();
        (k,) = _initDynamicPool(a, b, SQRT_PRICE_1_1);
        MockERC20(Currency.unwrap(a)).approve(address(checked), type(uint256).max);
        MockERC20(Currency.unwrap(b)).approve(address(checked), type(uint256).max);
        if (othersLiquidity > 0) _addLiquidity(k, WIDE_LOWER, WIDE_UPPER, othersLiquidity, OTH);
    }

    /// @dev fees the incumbents can collect, in the swap's input token
    function _incFees(bool zeroForOne) internal returns (int256) {
        BalanceDelta d = _collect(k, WIDE_LOWER, WIDE_UPPER, OTH);
        return zeroForOne ? int256(d.amount0()) : int256(d.amount1());
    }

    // =============================================================================================
    // E-1. The party that builds the transaction needs NO standing LP position
    // =============================================================================================

    /// @dev one transaction built by the relayer: [JIT add in [-60, 60)] -> the user's signed exact-in
    ///      order (minOut is the user's) -> [JIT remove], all at the relayer's tip. State is restored.
    function _relayedWithJit(uint256 tip, uint256 amountIn, uint256 minOut, int256 jitLiq)
        internal
        returns (int256 relayerPnl, uint256 userOut, int256 incumbentFees)
    {
        (relayerPnl, userOut, incumbentFees,,) = _relayedWithJitFull(tip, amountIn, minOut, jitLiq);
    }

    /// @dev as above, also returning what the JIT add took from the relayer inside the transaction
    ///      (token0 + token1, in wei) and the tick the swap ended at
    function _relayedWithJitFull(uint256 tip, uint256 amountIn, uint256 minOut, int256 jitLiq)
        internal
        returns (int256 relayerPnl, uint256 userOut, int256 incumbentFees, uint256 capital, int24 endTick)
    {
        uint256 snap = vm.snapshotState();
        _setTip(tip);
        BalanceDelta added;
        BalanceDelta removed;
        if (jitLiq > 0) added = _addLiquidity(k, -60, 60, jitLiq, ATT);
        capital = uint256(-int256(added.amount0())) + uint256(-int256(added.amount1()));
        userOut = checked.swapExactIn(k, true, amountIn, minOut);
        (, endTick,,) = manager.getSlot0(k.toId());
        if (jitLiq > 0) removed = _addLiquidity(k, -60, 60, -jitLiq, ATT);
        BalanceDelta net = added + removed;
        relayerPnl = int256(net.amount0()) + int256(net.amount1());
        incumbentFees = _incFees(true);
        vm.revertToState(snap);
    }

    /// @dev FACT (audit E-1, limitation): whoever assembles the transaction that carries a user's signed
    ///      order (4337 bundler, 7702 sponsor, meta-transaction relayer) does not have to be an LP to
    ///      profit from raising the tip. It wraps the user's swap in its own just-in-time liquidity; its
    ///      share of the in-range liquidity is then ~100% and so is its share of the surcharge. The
    ///      incumbent LPs, for whom the surcharge was meant, get next to nothing.
    ///      Incumbents 1e21 wide; user exact-in 10e18 with a 0.5% minimum-out off the floor-fee quote;
    ///      relayer has no standing position and adds 99e24 in [-60, 60) for the one swap.
    function test_fact_5a_relayerFlashJIT_noStandingLpNeeded() public {
        _fresh(1e21);
        uint256 amountIn = 10e18;
        (, uint256 quoted,) = _relayedWithJit(0, amountIn, 0, 0);
        uint256 minOut = quoted * 995 / 1000;

        // 0: floor tip, no JIT   1: floor tip, JIT   2: cap tip, no JIT   3: cap tip, JIT
        uint256[4] memory tips = [uint256(0), 0, TIP_AT_CAP, TIP_AT_CAP];
        int256[4] memory liqs = [int256(0), 99e24, 0, 99e24];
        int256[4] memory pnl;
        uint256[4] memory out;
        int256[4] memory inc;
        for (uint256 i; i < 4; i++) {
            (pnl[i], out[i], inc[i]) = _relayedWithJit(tips[i], amountIn, minOut, liqs[i]);
            console2.log("case (0 floor/noJIT, 1 floor/JIT, 2 cap/noJIT, 3 cap/JIT):", i);
            console2.log("  user out:", out[i]);
            console2.log("  relayer P&L at price 1 (wei) / incumbent LP fees (wei):");
            console2.logInt(pnl[i]);
            console2.logInt(inc[i]);
        }

        // the numbers quoted in docs/PriorityFeeHook.md section 9
        assertEq(pnl[0], 0);
        assertEq(pnl[1], 5_000_958_566_134_010, "floor tip + JIT: 0.005001 (ordinary JIT income, 0.05%)");
        assertEq(pnl[2], 0, "cap tip without JIT: a relayer with no position gains nothing");
        assertEq(pnl[3], 30_000_701_001_868_165, "cap tip + JIT: 0.030001 (0.30%)");
        assertEq(inc[0], 4_999_999_999_999_999);
        assertEq(inc[1], 50_504_540_358, "incumbents at the floor, diluted: 5.05e10 wei");
        assertEq(inc[2], 29_999_999_999_999_999, "without JIT the incumbents get the whole 0.03");
        assertEq(inc[3], 303_027_242_149, "with JIT the incumbents get 3.03e11 wei of a 0.03 fee");

        // raising the tip is worth 0.25% of the notional to a relayer with NO standing position ...
        int256 gain = pnl[3] - pnl[1];
        assertApproxEqRel(gain, int256(amountIn * 2500 / 1e6), 1e15, "0.25% of the notional");
        // ... and the incumbents get ~1/100,000 of the surcharge
        assertLt((inc[3] - inc[1]) * 50_000, inc[2] - inc[0]);
        // what the tip does to the USER, JIT held equal: 2,501 ppm less out (the JIT's depth itself gives the
        // user a better price than no JIT at all, so the comparison must hold the JIT fixed)
        assertEq((out[1] - out[3]) * 1e6 / out[1], 2501);
        assertGe(out[3], minOut);

        // Break-even, ASSUMING the whole transaction (JIT add + swap + JIT remove) uses 500,000 gas and the
        // input token is ETH. The gas figure is an assumption, not a measurement: 500,000 * 1.02 gwei =
        // 0.00051 ETH of tip; 0.25% of N covers it from N = 0.204 ETH.
        uint256 assumedGas = 500_000;
        assertEq(assumedGas * TIP_AT_CAP * 1e6 / 2500, 0.204 ether);
        assertGt(gain, int256(assumedGas * TIP_AT_CAP));
    }

    /// @dev FACT (audit round 2): "no standing position" is not "no capital". The relayer's share of the
    ///      surcharge is JIT / (JIT + incumbent in-range liquidity), so a 90% / 99% share takes 9x / 99x
    ///      the incumbents' liquidity, and the JIT add has to be funded inside the transaction (own funds
    ///      or a flash loan; the flash-loan path is NOT tested and its gas is not in the 500,000 assumed
    ///      above). Same pool as the test above: incumbents 1e21 wide, user exact-in 10e18, JIT in
    ///      [-60, 60); tokens added at price 1. Columns of the table in docs/PriorityFeeHook.md section 9.
    function test_fact_5a_relayerFlashJIT_capitalNeededByShare() public {
        _fresh(1e21);
        uint256 amountIn = 10e18;
        int256[5] memory liqs = [int256(1e21), 9e21, 99e21, 999e21, 99e24];
        uint256[5] memory capital;
        int256[5] memory gain; // relayer P&L at the cap minus at the floor, JIT held equal
        int256[5] memory inc; // incumbents' fees at the cap
        int24[5] memory endTick;
        for (uint256 i; i < 5; i++) {
            (int256 pnlFloor,,, uint256 cap0,) = _relayedWithJitFull(0, amountIn, 0, liqs[i]);
            int256 pnlCap;
            (pnlCap,, inc[i], capital[i], endTick[i]) = _relayedWithJitFull(TIP_AT_CAP, amountIn, 0, liqs[i]);
            assertEq(capital[i], cap0, "the JIT add costs the same at either tip");
            gain[i] = pnlCap - pnlFloor;
            console2.log("JIT liquidity:", uint256(liqs[i]));
            console2.log("  capital inside the transaction (wei, token0 + token1):", capital[i]);
            console2.log("  extra relayer P&L from raising the tip (wei at price 1) / incumbent fees at the cap (wei) / end tick at the cap:");
            console2.logInt(gain[i]);
            console2.logInt(inc[i]);
            console2.logInt(endTick[i]);
        }

        // the numbers quoted in docs/PriorityFeeHook.md section 9 (wei; 1e18 wei = 1 token)
        assertEq(capital[0], 5_990_709_911_821_561_876, "1x: 5.99 tokens");
        assertEq(capital[1], 53_916_389_206_394_056_880, "9x: 53.9 tokens");
        assertEq(capital[2], 593_080_281_270_334_625_660, "99x: 593 tokens");
        assertEq(capital[3], 5_984_719_201_909_740_313_474, "999x: 5,985 tokens");
        assertEq(capital[4], 593_080_281_270_334_625_659_528, "99,000x: 593,080 tokens");
        assertEq(gain[0], 7_537_254_240_816_310, "1x: 0.0075 (the swap leaves the JIT range; includes inventory effect)");
        assertEq(gain[1], 22_455_145_924_574_989, "9x: 0.0225");
        assertEq(gain[2], 24_745_059_402_305_442, "99x: 0.0247");
        assertEq(gain[3], 24_974_501_381_591_204, "999x: 0.02497");
        assertEq(gain[4], 24_999_742_435_734_155, "99,000x: 0.0249997");
        assertEq(inc[0], 20_959_817_263_564_918, "1x: incumbents keep 0.0210 of 0.03");
        assertEq(inc[1], 2_999_999_999_999_999, "9x: 0.0030");
        assertEq(inc[2], 299_999_999_999_999, "99x: 0.0003");
        assertEq(inc[3], 29_999_999_999_999, "999x: 0.00003");
        assertEq(inc[4], 303_027_242_149, "99,000x: 3.03e-7");
        assertEq(endTick[0], -139, "1x: the swap ends outside [-60, 60)");
        for (uint256 i = 1; i < 5; i++) {
            assertGt(endTick[i], -60, "9x and up: the swap stays inside the JIT range");
            // share = JIT / (JIT + incumbents): the incumbents keep 1 / (1 + multiple) of the 0.03 fee
            assertApproxEqAbs(inc[i], int256(0.03e18 * 1e21 / (uint256(liqs[i]) + 1e21)), 2);
            // a larger share keeps more of the 0.25% (0.025 tokens here) surcharge
            assertGt(gain[i], gain[i - 1]);
            assertLt(gain[i], 0.025e18);
        }
        // the 99e24 example of the test above needs ~59,308 times the user's notional inside the transaction
        assertEq(capital[4] / amountIn, 59_308);
        // a 9x / 99x JIT (90% / 99% share) costs ~9 / ~99 times what the incumbents hold in the same range
        assertApproxEqRel(capital[1], 9 * capital[0], 1e15);
        assertApproxEqRel(capital[2], 99 * capital[0], 1e15);
    }

    // =============================================================================================
    // E-3. Self-JIT does not let a swapper escape the surcharge (generalised)
    // =============================================================================================

    struct R {
        BalanceDelta plain; // attacker's net balances: swap to the target at the cap, no JIT
        BalanceDelta jit; // attacker's net balances: JIT add + swap to the same target + JIT remove
        int256 feesFloor; // incumbents' fees for the same price move at the floor fee
        int256 feesPlain;
        int256 feesJit;
        BalanceDelta jitSwap; // the swap leg alone in the JIT case (gross, before the JIT position is removed)
    }

    /// @dev swap to `targetTick`'s price with / without the attacker's own JIT in [jl, ju)
    function _selfJit(bool zeroForOne, int24 targetTick, int24 jl, int24 ju, int256 jitLiq, bool exactOut, uint24 pf)
        internal
        returns (R memory r)
    {
        _fresh(1e21);
        if (pf > 0) _setProtocolFee(k, pf, pf);
        uint160 target = TickMath.getSqrtPriceAtTick(targetTick);
        int256 amt = exactOut ? int256(1e30) : -int256(1e30);
        uint256 snap = vm.snapshotState();
        _setTip(0);
        _swapTo(k, zeroForOne, amt, target);
        r.feesFloor = _incFees(zeroForOne);
        vm.revertToState(snap);

        _setTip(TIP_AT_CAP);
        (r.plain,) = _swapTo(k, zeroForOne, amt, target);
        assertEq(_sqrtPrice(k), target);
        r.feesPlain = _incFees(zeroForOne);
        vm.revertToState(snap);

        _setTip(TIP_AT_CAP);
        BalanceDelta added = _addLiquidity(k, jl, ju, jitLiq, ATT);
        (BalanceDelta swapped,) = _swapTo(k, zeroForOne, amt, target);
        assertEq(_sqrtPrice(k), target);
        BalanceDelta removed = _addLiquidity(k, jl, ju, -jitLiq, ATT);
        r.jitSwap = swapped;
        r.jit = added + swapped + removed;
        r.feesJit = _incFees(zeroForOne);
        vm.revertToState(snap);
    }

    function _check(string memory name, R memory r) internal pure {
        console2.log(name);
        console2.log("  incumbent fees: floor / cap without JIT / cap with self-JIT");
        console2.logInt(r.feesFloor);
        console2.logInt(r.feesPlain);
        console2.logInt(r.feesJit);
        console2.log("  attacker net token0 then token1: without JIT, with JIT");
        console2.logInt(r.plain.amount0());
        console2.logInt(r.jit.amount0());
        console2.logInt(r.plain.amount1());
        console2.logInt(r.jit.amount1());
        assertApproxEqRel(r.feesPlain, r.feesFloor * 6, 0.01e18, "the surcharge is real: ~6x the floor fee");
        assertApproxEqAbs(r.feesJit, r.feesPlain, 2, "incumbents collect the same with or without the JIT");
        assertLe(int256(r.jit.amount0()), int256(r.plain.amount0()), "attacker not better off in token0");
        assertLe(int256(r.jit.amount1()), int256(r.plain.amount1()), "attacker not better off in token1");
    }

    /// @dev named cases: the swap leaves the JIT range; the JIT covers only the middle of the path; the
    ///      other direction; exact-out; a 999x JIT
    function test_5b_selfJIT_table() public {
        _check("0->1 to tick -300, JIT [-120,60) 9x (swap leaves the JIT range)", _selfJit(true, -300, -120, 60, 9e21, false, 0));
        _check("0->1 to tick -300, JIT [-240,-120) 9x (JIT only mid-path)", _selfJit(true, -300, -240, -120, 9e21, false, 0));
        _check("1->0 to tick +300, JIT [-60,180) 9x", _selfJit(false, 300, -60, 180, 9e21, false, 0));
        _check("0->1 to tick -90, JIT [-120,60) 9x, exact-out style", _selfJit(true, -90, -120, 60, 9e21, true, 0));
        _check("0->1 to tick -90, JIT [-120,60) 999x", _selfJit(true, -90, -120, 60, 999e21, false, 0));
    }

    /// @dev With a protocol fee the self-JIT is STRICTLY worse for the attacker: the JIT makes the same
    ///      price move need a larger gross swap, and the protocol takes its cut of all of it, including
    ///      the part the attacker trades with itself. Protocol fee 0.10%, 9x JIT, target tick -90.
    function test_5b_selfJIT_withProtocolFee_strictlyWorse() public {
        R memory r = _selfJit(true, -90, -120, 60, 9e21, false, 1000);
        console2.log("protocol fee 0.10%: attacker pays token0 without JIT / with 9x self-JIT");
        console2.logInt(-r.plain.amount0());
        console2.logInt(-r.jit.amount0());
        assertApproxEqAbs(r.feesJit, r.feesPlain, 2, "incumbents collect the same");
        assertEq(-int256(r.plain.amount0()), 4_528_012_671_559_950_864);
        assertEq(-int256(r.jit.amount0()), 4_568_764_785_603_990_423, "0.9% more token0 for the same move");
        assertLe(int256(r.jit.amount1()), int256(r.plain.amount1()));
    }

    /// @dev Auditor's fuzz (E-3): both directions, target 1-3000 ticks away, JIT range anywhere in
    ///      [-3600, 3600] (covering all, part or none of the path), JIT liquidity 1e15-1e25 (1e-6x to
    ///      10,000x the incumbents'), exact-in / exact-out style, protocol fee 0 / 0.05% / 0.10%.
    ///      The incumbents never collect less than without the JIT and the attacker is never better off
    ///      in either token (tolerance 1000 wei: rounding at each tick crossed).
    function testFuzz_5b_selfJIT_neverHelps(
        bool zeroForOne,
        uint256 targetSeed,
        uint256 loSeed,
        uint256 widthSeed,
        uint256 liqSeed,
        bool exactOut,
        uint256 pfSeed
    ) public {
        int24 targetTick = int24(int256(bound(targetSeed, 1, 3000)));
        if (zeroForOne) targetTick = -targetTick;
        int24 jl = int24(int256(bound(loSeed, 0, 120))) * 60 - 3600;
        int24 ju = jl + int24(int256(bound(widthSeed, 1, 60))) * 60;
        int256 jitLiq = int256(bound(liqSeed, 1e15, 1e25));
        uint24 pf = uint24(bound(pfSeed, 0, 2) * 500);
        R memory r = _selfJit(zeroForOne, targetTick, jl, ju, jitLiq, exactOut, pf);
        assertGe(r.feesJit + 1000, r.feesPlain, "incumbents short-changed by self-JIT");
        assertLe(int256(r.jit.amount0()), int256(r.plain.amount0()) + 1000, "attacker saved token0");
        assertLe(int256(r.jit.amount1()), int256(r.plain.amount1()) + 1000, "attacker saved token1");
    }

    /// @dev Audit round 2: the fuzz above also draws JIT ranges that miss the price path, where the claim
    ///      is trivially true, and it cannot count how often the range was on the path (a fuzz test keeps
    ///      no state between runs). This one draws ONLY ranges that overlap the path: a tick `q` strictly
    ///      inside the path is drawn first and the range is built around it. The overlap is asserted from
    ///      the result, not from the construction: the gross input of the swap leg must be strictly larger
    ///      than without the JIT (the same price move through more liquidity).
    function testFuzz_5b_selfJIT_onPath_neverHelps(
        bool zeroForOne,
        uint256 targetSeed,
        uint256 qSeed,
        uint256 widthSeed,
        uint256 liqSeed,
        bool exactOut,
        uint256 pfSeed
    ) public {
        int24 targetTick = int24(int256(bound(targetSeed, 1, 3000)));
        (int24 jl, int24 ju) = _rangeOnPath(zeroForOne, targetTick, qSeed, widthSeed);
        if (zeroForOne) targetTick = -targetTick;
        R memory r = _selfJit(
            zeroForOne, targetTick, jl, ju, int256(bound(liqSeed, 1e15, 1e25)), exactOut, uint24(bound(pfSeed, 0, 2) * 500)
        );
        int256 grossPlain = zeroForOne ? -int256(r.plain.amount0()) : -int256(r.plain.amount1());
        int256 grossJit = zeroForOne ? -int256(r.jitSwap.amount0()) : -int256(r.jitSwap.amount1());
        assertGt(grossJit, grossPlain, "the JIT was on the path: the same move took a larger gross swap");
        assertGe(r.feesJit + 1000, r.feesPlain, "incumbents short-changed by self-JIT");
        assertLe(int256(r.jit.amount0()), int256(r.plain.amount0()) + 1000, "attacker saved token0");
        assertLe(int256(r.jit.amount1()), int256(r.plain.amount1()) + 1000, "attacker saved token1");
    }

    /// @dev a range (multiples of the tick spacing, up to 30 spacings to either side) around a tick `q`
    ///      that a swap from tick 0 to `distance` ticks away passes: 0->1 moves through [-distance, -1],
    ///      1->0 through [0, distance - 1]
    function _rangeOnPath(bool zeroForOne, int24 distance, uint256 qSeed, uint256 widthSeed)
        internal
        pure
        returns (int24 jl, int24 ju)
    {
        int24 q = int24(int256(bound(qSeed, 0, uint256(int256(distance)) - 1)));
        if (zeroForOne) q = -q - 1;
        int24 qFloor = q >= 0 ? (q / 60) * 60 : -((-q + 59) / 60) * 60;
        jl = qFloor - int24(int256(widthSeed % 31)) * 60;
        ju = qFloor + 60 + int24(int256((widthSeed >> 8) % 31)) * 60;
        assertTrue(jl <= q && q < ju, "generator: the range contains a tick on the path");
    }

    // =============================================================================================
    // E-2. Third-party JIT when the swap leaves the JIT range
    // =============================================================================================

    /// @dev FACT: the JIT provider's share is pro rata only on the part of the swap that happens inside
    ///      its range. A 50e18 exact-in swap at the cap against 1e21 of incumbents, with a 9x third-party
    ///      JIT in [-60, 60): the swap ends at tick -452, far outside the JIT range, and the incumbents
    ///      keep 45.8% of the fee (not the 10% of test_fact_5b_thirdPartyJIT_takesProRataShareOfTheSurcharge,
    ///      where the swap stays inside the range).
    function test_fact_5b_thirdPartyJIT_partialRange() public {
        _fresh(1e21);
        uint256 snap = vm.snapshotState();
        _setTip(TIP_AT_CAP);
        _swap(k, true, -50e18);
        int256 alone = _incFees(true);
        vm.revertToState(snap);

        _setTip(0);
        _addLiquidity(k, -60, 60, 9e21, ATT);
        _setTip(TIP_AT_CAP);
        _swap(k, true, -50e18);
        (, int24 tick,,) = manager.getSlot0(k.toId());
        _setTip(0);
        int256 jitFees = int256(_collect(k, -60, 60, ATT).amount0());
        int256 diluted = _incFees(true);
        console2.log("50e18 exact-in at the cap; end tick with the JIT in place:");
        console2.logInt(tick);
        console2.log("incumbent fees alone / with 9x JIT in [-60,60) / JIT provider's fees");
        console2.logInt(alone);
        console2.logInt(diluted);
        console2.logInt(jitFees);
        assertEq(tick, -452, "the swap left the JIT range");
        assertEq(alone, 149_999_999_999_999_999);
        assertEq(diluted, 68_638_355_372_084_260);
        assertEq(jitFees, 81_361_644_627_915_740);
        assertEq(diluted * 1000 / alone, 457, "incumbents keep 45.8% (457 per mille, rounded down)");
        assertApproxEqAbs(diluted + jitFees, alone, 2, "the same fee, split differently");
    }
}
