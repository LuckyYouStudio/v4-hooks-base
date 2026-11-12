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

/// hook-auditor H2 round 1 PoCs (temp copy only)
contract AuditH2Test is PriorityFeeTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant ATT = 1;
    uint256 internal constant OTH = 2;
    PoolKey internal k;
    CheckedSwapRouter internal checked;

    function setUp() public {
        _baseSetUp();
        checked = new CheckedSwapRouter(manager);
    }

    function _fresh(int256 othersLiquidity) internal {
        (Currency a, Currency b) = deployMintAndApprove2Currencies();
        (k,) = _initDynamicPool(a, b, SQRT_PRICE_1_1);
        MockERC20(Currency.unwrap(a)).approve(address(checked), type(uint256).max);
        MockERC20(Currency.unwrap(b)).approve(address(checked), type(uint256).max);
        if (othersLiquidity > 0) _addLiquidity(k, WIDE_LOWER, WIDE_UPPER, othersLiquidity, OTH);
    }

    function _incFees(bool zeroForOne) internal returns (int256) {
        BalanceDelta d = _collect(k, WIDE_LOWER, WIDE_UPPER, OTH);
        return zeroForOne ? int256(d.amount0()) : int256(d.amount1());
    }

    // ------------------------------------------------------------------------------------------
    // A-1: relayer with NO standing LP position: JIT add -> user's swap at the relayer's tip -> remove.
    //      Relayer P&L (valued at the pre-trade price 1) at floor tip vs cap tip.
    // ------------------------------------------------------------------------------------------
    function _relayedWithJit(uint256 tip, uint256 amountIn, uint256 minOut, int256 jitLiq)
        internal
        returns (int256 relayerPnl, uint256 userOut, int256 incumbentFees)
    {
        uint256 snap = vm.snapshotState();
        _setTip(tip);
        BalanceDelta added;
        BalanceDelta removed;
        if (jitLiq > 0) added = _addLiquidity(k, -60, 60, jitLiq, ATT);
        userOut = checked.swapExactIn(k, true, amountIn, minOut); // the user's signed order (minOut is the user's)
        if (jitLiq > 0) removed = _addLiquidity(k, -60, 60, -jitLiq, ATT);
        BalanceDelta net = added + removed;
        relayerPnl = int256(net.amount0()) + int256(net.amount1()); // price ~1, 18 decimals both
        incumbentFees = _incFees(true);
        vm.revertToState(snap);
    }

    function test_A1_relayerFlashJIT_noStandingLpNeeded() public {
        _fresh(1e21); // incumbents: 1e21 wide
        uint256 amountIn = 10e18;
        (, uint256 quoted,) = _relayedWithJit(0, amountIn, 0, 0);
        uint256 minOut = quoted * 995 / 1000; // user's 0.5% tolerance off the floor-fee quote
        uint256[4] memory tips = [uint256(0), 0, TIP_AT_CAP, TIP_AT_CAP];
        int256[4] memory liqs = [int256(0), 99e24, 0, 99e24];
        int256[4] memory pnl;
        for (uint256 i; i < 4; i++) {
            uint256 out;
            int256 inc;
            (pnl[i], out, inc) = _relayedWithJit(tips[i], amountIn, minOut, liqs[i]);
            console2.log("case (0 floor/noJIT, 1 floor/JIT, 2 cap/noJIT, 3 cap/JIT):", i);
            console2.log("  user out:", out);
            console2.log("  relayer pnl at price 1 / incumbent fees:");
            console2.logInt(pnl[i]);
            console2.logInt(inc);
        }
        assertGt(pnl[3] - pnl[1], int256(amountIn * 24 / 10000));
        assertEq(pnl[2], 0);
    }

    // ------------------------------------------------------------------------------------------
    // A-2: self-JIT, price target, generalised: JIT range may cover only part of the path, target may
    //      lie outside the JIT range, both directions, exactIn / exactOut-style, protocol fee.
    // ------------------------------------------------------------------------------------------
    struct R {
        BalanceDelta plain;
        BalanceDelta jit;
        int256 feesPlain;
        int256 feesJit;
        int256 feesFloor;
    }

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
        r.jit = added + swapped + removed;
        r.feesJit = _incFees(zeroForOne);
        vm.revertToState(snap);
    }

    function _log(string memory name, R memory r) internal pure {
        console2.log(name);
        console2.log("  incumbent fees floor / cap plain / cap self-JIT");
        console2.logInt(r.feesFloor);
        console2.logInt(r.feesPlain);
        console2.logInt(r.feesJit);
        console2.log("  attacker net token0, token1: plain then JIT");
        console2.logInt(r.plain.amount0());
        console2.logInt(r.jit.amount0());
        console2.logInt(r.plain.amount1());
        console2.logInt(r.jit.amount1());
    }

    function test_A2_selfJIT_table() public {
        _log("0->1 target -300, JIT [-120,60] 9x (swap leaves the JIT range)", _selfJit(true, -300, -120, 60, 9e21, false, 0));
        _log("0->1 target -300, JIT [-240,-120] 9x (JIT only mid-path)", _selfJit(true, -300, -240, -120, 9e21, false, 0));
        _log("1->0 target +300, JIT [-60,180] 9x", _selfJit(false, 300, -60, 180, 9e21, false, 0));
        _log("0->1 target -90, JIT [-120,60] 9x, exact-out style", _selfJit(true, -90, -120, 60, 9e21, true, 0));
        _log("0->1 target -90, JIT [-120,60] 9x, protocol fee 0.10%", _selfJit(true, -90, -120, 60, 9e21, false, 1000));
        _log("0->1 target -90, JIT [-120,60] 999x", _selfJit(true, -90, -120, 60, 999e21, false, 0));
    }

    function testFuzz_A2_selfJIT_neverHelps(
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
        int24 jl = int24(int256(bound(loSeed, 0, 120))) * 60 - 3600; // [-3600, 3600]
        int24 ju = jl + int24(int256(bound(widthSeed, 1, 60))) * 60;
        int256 jitLiq = int256(bound(liqSeed, 1e15, 1e25));
        uint24 pf = uint24(bound(pfSeed, 0, 2) * 500);
        R memory r = _selfJit(zeroForOne, targetTick, jl, ju, jitLiq, exactOut, pf);
        // incumbents get at least what they got without the JIT (tolerance: rounding per tick crossed)
        assertGe(r.feesJit + 1000, r.feesPlain, "incumbents short-changed by self-JIT");
        // attacker is not better off in either token
        assertLe(int256(r.jit.amount0()), int256(r.plain.amount0()) + 1000, "attacker saved token0");
        assertLe(int256(r.jit.amount1()), int256(r.plain.amount1()) + 1000, "attacker saved token1");
    }

    // ------------------------------------------------------------------------------------------
    // A-3: third-party JIT, swap leaves the JIT range
    // ------------------------------------------------------------------------------------------
    function test_A3_thirdPartyJIT_partialRange() public {
        _fresh(1e21);
        uint256 snap = vm.snapshotState();
        _setTip(TIP_AT_CAP);
        (BalanceDelta d0,) = _swap(k, true, -50e18);
        int256 alone = _incFees(true);
        vm.revertToState(snap);

        _setTip(0);
        _addLiquidity(k, -60, 60, 9e21, ATT);
        _setTip(TIP_AT_CAP);
        (BalanceDelta d1,) = _swap(k, true, -50e18);
        (, int24 tick,,) = manager.getSlot0(k.toId());
        _setTip(0);
        int256 jitFees = int256(_collect(k, -60, 60, ATT).amount0());
        int256 diluted = _incFees(true);
        console2.log("victim 50e18 exact-in at cap; end tick with JIT:");
        console2.logInt(tick);
        console2.log("incumbent fees alone / with 9x JIT in [-60,60] / JIT fees");
        console2.logInt(alone);
        console2.logInt(diluted);
        console2.logInt(jitFees);
        console2.log("victim out without / with JIT");
        console2.logInt(d0.amount1());
        console2.logInt(d1.amount1());
        assertLt(tick, -60, "swap left the JIT range");
        assertGt(diluted * 10, alone, "incumbents keep more than 10% when the swap leaves the JIT range");
    }
}
