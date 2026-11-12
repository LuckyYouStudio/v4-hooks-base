// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
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

/// @notice Sections 7-9 of docs/PriorityFeeHook.md ("who can make others pay more, who can pay less"), one
///         test or group of tests per claim. Tests named `test_fact_...` record a behaviour that is a
///         LIMITATION, so that it cannot change unnoticed. Run with -vv to print the tables.
/// @dev Amounts are in the pool's 18-decimal mock tokens; where a number is compared with a gas cost the
///      input token is treated as if it were ETH (stated at the place).
contract PriorityFeeHookAdversarialTest is PriorityFeeTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant ATT = 1; // the attacker's position
    uint256 internal constant OTH = 2; // everybody else's position
    int24 internal constant JIT_LOWER = -120;
    int24 internal constant JIT_UPPER = 60;

    PoolKey internal k;
    CheckedSwapRouter internal checked;

    function setUp() public {
        _baseSetUp();
        checked = new CheckedSwapRouter(manager);
        MockERC20(Currency.unwrap(currency0)).approve(address(checked), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(checked), type(uint256).max);
    }

    /// @dev fresh pool at price 1; wide positions for the attacker and for the others
    function _fresh(int256 attackerLiquidity, int256 othersLiquidity) internal {
        (Currency a, Currency b) = deployMintAndApprove2Currencies();
        (k,) = _initDynamicPool(a, b, SQRT_PRICE_1_1);
        if (attackerLiquidity > 0) _addLiquidity(k, WIDE_LOWER, WIDE_UPPER, attackerLiquidity, ATT);
        if (othersLiquidity > 0) _addLiquidity(k, WIDE_LOWER, WIDE_UPPER, othersLiquidity, OTH);
    }

    function _fees0(uint256 salt) internal returns (int256) {
        return int256(_collect(k, WIDE_LOWER, WIDE_UPPER, salt).amount0());
    }

    // =============================================================================================
    // 5a. Who can make SOMEONE ELSE pay more?
    // =============================================================================================

    /// @dev Whatever other transactions did before yours (high-tip swaps in either direction, down to
    ///      1 wei; adding / removing liquidity next to the price; donations), your swap is charged by
    ///      your own transaction's tip. There is no state for them to move.
    function testFuzz_5a_earlierTransactionsCannotChangeYourFee(uint256 seed, uint256 myTip, bool myDir) public {
        myTip = bound(myTip, 0, 1_200_000_000);
        for (uint256 i; i < 6; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 action = seed % 4;
            _setTip(bound(seed >> 8, 0, 20 gwei));
            if (action <= 1) {
                uint256 amount = bound(seed >> 72, 1, 1e22);
                _swap(hookKey, action == 0, (seed >> 200) % 2 == 0 ? -int256(amount) : int256(amount));
            } else if (action == 2) {
                _addLiquidity(hookKey, -60, 60, int256(bound(seed >> 72, 1, 1e24)), 100 + i);
            } else {
                donateRouter.donate(hookKey, bound(seed >> 72, 0, 1e18), bound(seed >> 136, 0, 1e18), ZERO_BYTES);
            }
        }
        _setTip(myTip);
        (, uint24 fee) = _swap(hookKey, myDir, -1e15);
        assertEq(fee, _expectedFee(myTip), "my fee depends on my transaction only");
    }

    /// @dev Same block, attacker in front with the maximum tip: the next transaction still pays its own.
    function test_5a_frontRunnerWithHugeTip_doesNotRaiseVictimFee() public {
        _setTip(type(uint64).max - BASEFEE);
        (, uint24 attacker) = _swap(hookKey, true, -1e20);
        assertEq(attacker, 3000);
        _setTip(1_500_000); // Universal Router median
        (, uint24 victim) = _swap(hookKey, true, -1e18);
        assertEq(victim, 500);
    }

    /// @dev Type-2 transaction: effective gas price = min(maxFeePerGas, baseFee + maxPriorityFeePerGas).
    ///      Whatever the base fee does between signing and inclusion, the fee is at most the fee of the
    ///      signed maxPriorityFeePerGas. A base-fee spike can only LOWER the fee (when maxFee binds).
    function testFuzz_5a_type2_baseFeeCannotPushFeeAboveSignedTip(uint256 baseFee, uint256 maxFee, uint256 tipCap)
        public
    {
        baseFee = bound(baseFee, 0, 1000 gwei);
        maxFee = bound(maxFee, baseFee, 2000 gwei); // includable only if maxFee >= baseFee
        tipCap = bound(tipCap, 0, 3 gwei);
        uint256 effective = baseFee + tipCap < maxFee ? baseFee + tipCap : maxFee;
        _setGas(effective, baseFee);
        (, uint24 fee) = _swap(hookKey, true, -1e15);
        assertLe(fee, _expectedFee(tipCap), "never above the fee of the signed tip");
        uint256 paidTip = maxFee - baseFee < tipCap ? maxFee - baseFee : tipCap;
        assertEq(fee, _expectedFee(paidTip));
    }

    /// @dev the researcher's largest sampled base fee (33.7e6) and a 100x spike, tip = wallet default
    function test_5a_baseFeeSpike_type2UserStillPaysFloor() public {
        uint256[4] memory baseFees = [uint256(5_000_000), 13_036_071, 33_711_616, 500_000_000];
        for (uint256 i; i < baseFees.length; i++) {
            uint256 tip = 2_000_000;
            _setGas(baseFees[i] + tip, baseFees[i]);
            (, uint24 fee) = _swap(hookKey, true, -1e18);
            assertEq(fee, 500);
        }
    }

    /// @dev FACT (mis-charge, not third-party manipulation): a LEGACY transaction has no tip field; all
    ///      of gasPrice above the base fee is priority fee. A user who signs a generous gasPrice "to be
    ///      safe" is surcharged, and the lower the base fee at inclusion the more. Bounded by the fee of
    ///      the signed gasPrice itself.
    function test_fact_5a_legacyTransaction_overpaysWhenBaseFeeIsLow() public {
        uint256 signedGasPrice = 60_000_000; // 0.06 gwei, e.g. 2x a spiking base fee of 0.03 gwei
        uint24 fee;
        _setGas(signedGasPrice, 33_711_616);
        (, fee) = _swap(hookKey, true, -1e18);
        assertEq(fee, 515, "tip 26.3e6 -> 15 pips");
        _setGas(signedGasPrice, 5_000_000); // base fee back at the minimum
        (, fee) = _swap(hookKey, true, -1e18);
        assertEq(fee, 587, "tip 55e6 -> 87 pips");
        assertLe(fee, _expectedFee(signedGasPrice));
    }

    function testFuzz_5a_legacy_feeBoundedBySignedGasPrice(uint256 gasPrice, uint256 baseFee) public {
        gasPrice = bound(gasPrice, 0, 5 gwei);
        baseFee = bound(baseFee, 0, gasPrice);
        _setGas(gasPrice, baseFee);
        (, uint24 fee) = _swap(hookKey, true, -1e15);
        assertLe(fee, _expectedFee(gasPrice));
    }

    /// @dev FACT: when someone else builds the transaction (4337 bundler, 7702 sponsor, intent filler,
    ///      relayer), the hook reads THEIR tip. The same user order gets less out; the user's only
    ///      protection is the minimum-out they signed. The damage is capped by MAX_FEE.
    function test_fact_5a_relayerTipIsChargedToTheUsersSwap() public {
        uint256 amountIn = 10e18;
        uint256 snap = vm.snapshotState();
        _setTip(1_000_000); // what the user's own wallet would have set
        uint256 outOwn = checked.swapExactIn(hookKey, true, amountIn, 0);
        vm.revertToState(snap);

        _setTip(TIP_AT_CAP); // the relayer bids for position
        uint256 outRelayed = checked.swapExactIn(hookKey, true, amountIn, 0);
        vm.revertToState(snap);

        uint256 lossPpm = (outOwn - outRelayed) * 1e6 / outOwn;
        console2.log("relayed at 1.02 gwei tip: user receives less by (ppm of output):", lossPpm);
        assertApproxEqAbs(lossPpm, 2501, 2, "(1 - 0.003) / (1 - 0.0005) - 1");

        // with a 0.1% minimum-out the relayed order fails instead; with 0.5% it fills
        _setTip(TIP_AT_CAP);
        uint256 minOut = outOwn * 999 / 1000;
        vm.expectRevert();
        checked.swapExactIn(hookKey, true, amountIn, minOut);
        checked.swapExactIn(hookKey, true, amountIn, outOwn * 995 / 1000);
    }

    /// @dev FACT: one bundle, two users' swaps -> both are charged at the bundle transaction's tip.
    function test_fact_5a_bundle_everySwapChargedAtTheBundlersTip() public {
        _setTip(500_000_000);
        (, uint24 userA) = _swap(hookKey, true, -1e18);
        (, uint24 userB) = _swap(hookKey, false, -3e18);
        assertEq(userA, 1700);
        assertEq(userB, 1700);
    }

    /// @dev FACT (the one real "make others pay more" lever): whoever sets the tip of a transaction that
    ///      carries SOMEONE ELSE'S swap, and is also an LP of the pool, turns tip into LP income. (A
    ///      standing position is NOT required: the same party can add just-in-time liquidity inside the
    ///      transaction, see PriorityFeeHook.jit.t.sol, audit E-1. This test is the standing-LP case.) The
    ///      tip costs gas * tip (paid to the sequencer); the surcharge is notional * pips and comes back
    ///      pro rata to the LP share. Because the schedule is linear, the break-even notional does not
    ///      depend on the tip: N* = gasUsed * WEI_PER_PIP * 1e6 / share (in wei of the input token, when
    ///      the input token is ETH). Table below assumes a 200,000-gas transaction and ETH input.
    function test_fact_5a_lpRelayer_profitsFromRaisingTheTipOnUsersSwaps() public {
        uint256 gasUsed = 200_000;
        uint256 tipCost = TIP_AT_CAP * gasUsed; // wei of ETH paid to the sequencer
        uint256[5] memory notionals = [uint256(1e16), 1e17, 1e18, 1e19, 1e20];
        uint256[3] memory sharePct = [uint256(10), 50, 100];
        console2.log("LP-relayer raising the tip from 0 to 1.02 gwei on a user's exact-in swap (input = ETH)");
        console2.log("tip cost (wei, 200k gas):", tipCost);
        for (uint256 i; i < notionals.length; i++) {
            uint256 snap = vm.snapshotState();
            _setTip(0);
            _swap(hookKey, true, -int256(notionals[i]));
            uint256 feeFloor = uint256(int256(_collect(hookKey, WIDE_LOWER, WIDE_UPPER, 0).amount0()));
            vm.revertToState(snap);
            _setTip(TIP_AT_CAP);
            _swap(hookKey, true, -int256(notionals[i]));
            uint256 feeCap = uint256(int256(_collect(hookKey, WIDE_LOWER, WIDE_UPPER, 0).amount0()));
            vm.revertToState(snap);
            uint256 extra = feeCap - feeFloor; // extra LP fee the user paid, in input token
            assertApproxEqRel(extra, notionals[i] * 2500 / 1e6, 1e15, "0.25% of the notional");
            for (uint256 j; j < 3; j++) {
                int256 profit = int256(extra * sharePct[j] / 100) - int256(tipCost);
                console2.log("  notional (wei) / LP share % :", notionals[i], sharePct[j]);
                console2.log("    net profit of the LP-relayer (wei):", profit);
                // break-even: N* = gas * WEI_PER_PIP * 1e6 * (TIP_AT_CAP / (TIP_AT_CAP - ALLOWANCE)) / share
                uint256 breakEven = gasUsed * WEI_PER_PIP * 1e6 * 100 / sharePct[j] * TIP_AT_CAP / (TIP_AT_CAP - ALLOWANCE);
                if (notionals[i] > breakEven * 101 / 100) assertGt(profit, 0);
                if (notionals[i] < breakEven * 99 / 100) assertLt(profit, 0);
            }
        }
        // sole LP: profitable from ~0.082 ETH notional upwards
        assertEq(gasUsed * WEI_PER_PIP * 1e6 * TIP_AT_CAP / (TIP_AT_CAP - ALLOWANCE), 81_600_000_000_000_000);
    }

    // =============================================================================================
    // 5b. Who can pay LESS than the schedule says?
    // =============================================================================================

    /// @dev exact-out swap (pays token0, the fee is taken in token0) at `tip`; returns what the swapper
    ///      paid net of the LP fees its own position got back. State is restored.
    function _netPaid(uint256 tip, bool hasPosition) internal returns (int256 net, uint256 gross) {
        uint256 snap = vm.snapshotState();
        _setTip(tip);
        (BalanceDelta d,) = _swap(k, true, 1e18);
        gross = uint256(uint128(-d.amount0()));
        net = int256(gross) - (hasPosition ? _fees0(ATT) : int256(0));
        vm.revertToState(snap);
    }

    /// @dev An LP that swaps with a high tip pays the surcharge partly to itself. Net cost of the
    ///      surcharge = (1 - s) of it, plus the protocol's cut. Signed numbers (H1 lesson N-2).
    function test_5b_lpOwnHighTipSwap_netSurchargeCostByShare() public {
        int256[3] memory attackerLiq = [int256(0), 5e20, 1e21];
        int256[3] memory extra;
        int256 grossFloor;
        console2.log("net cost of the surcharge (wei of token0) on an exact-out 1e18 swap at the cap, by LP share");
        for (uint256 i; i < 3; i++) {
            _fresh(attackerLiq[i], 1e21 - attackerLiq[i]);
            (int256 netFloor, uint256 gross) = _netPaid(0, i > 0);
            (int256 netCap,) = _netPaid(TIP_AT_CAP, i > 0);
            extra[i] = netCap - netFloor;
            if (i == 0) grossFloor = int256(gross);
            console2.log("  LP share %:", i * 50);
            console2.logInt(extra[i]);
        }
        assertGt(extra[0], 0);
        // s = 0: the full surcharge, (1 - 0.0005) / (1 - 0.003) - 1 = 0.25075% of what the swap costs at the floor
        assertApproxEqAbs(extra[0] * 1e7 / grossFloor, 25075, 2);
        // s = 50%: half of it
        assertApproxEqAbs(extra[1] * 2, extra[0], 4);
        // s = 100%: nothing (rounding dust only)
        assertApproxEqAbs(extra[2], 0, 2);
    }

    /// @dev same with the maximum protocol fee: the sole LP still loses the protocol's cut of the surcharge
    function test_5b_lpOwnHighTipSwap_soleLp_withProtocolFee() public {
        _fresh(1e21, 0);
        _setProtocolFee(k, 1000, 1000);
        (int256 netFloor, uint256 grossFloor) = _netPaid(0, true);
        (int256 netCap, uint256 grossCap) = _netPaid(TIP_AT_CAP, true);
        int256 extra = netCap - netFloor;
        console2.log("sole LP, protocol fee 0.10%: net cost of the surcharge (wei):");
        console2.logInt(extra);
        // the protocol takes 0.10% of the (larger) gross input: 0.1% * 0.25% of the notional
        assertApproxEqAbs(extra, int256((grossCap - grossFloor) / 1000), 3);
        assertGt(extra, 0);
    }

    /// @dev Researcher's inference (docs/research/base-priority-ordering-for-hooks.md section 3 item 14, section 7
    ///      item 14): "with a RATE surcharge, self-JIT does not let an arbitrageur escape". CONFIRMED for
    ///      the arbitrageur's case, i.e. a swap that moves the price to a target: with its own
    ///      just-in-time liquidity (9x the pool's) added before and removed after, in the same
    ///      transaction, the incumbent LPs collect the same fees and the arbitrageur ends with the same
    ///      balances, to within rounding.
    function test_5b_selfJIT_priceTarget_incumbentsGetTheSame_attackerSavesNothing() public {
        _fresh(0, 1e21);
        uint160 target = TickMath.getSqrtPriceAtTick(-90);

        // reference: what the incumbents earn from the same price move at the floor fee
        uint256 snap = vm.snapshotState();
        _setTip(0);
        _swapTo(k, true, -1e30, target);
        int256 feesFloor = _fees0(OTH);
        vm.revertToState(snap);

        // 1) no JIT, tip at the cap
        _setTip(TIP_AT_CAP);
        (BalanceDelta plain,) = _swapTo(k, true, -1e30, target);
        int256 feesPlain = _fees0(OTH);
        vm.revertToState(snap);

        // 2) JIT: add 9e21 around the price, swap to the same target, remove - all at the cap tip
        _setTip(TIP_AT_CAP);
        BalanceDelta added = _addLiquidity(k, JIT_LOWER, JIT_UPPER, 9e21, ATT);
        (BalanceDelta swapped,) = _swapTo(k, true, -1e30, target);
        assertEq(_sqrtPrice(k), target);
        BalanceDelta removed = _addLiquidity(k, JIT_LOWER, JIT_UPPER, -9e21, ATT);
        BalanceDelta jit = added + swapped + removed;
        int256 feesJit = _fees0(OTH);

        console2.log("incumbent LP fees (token0 wei): floor / cap without JIT / cap with 9x self-JIT");
        console2.logInt(feesFloor);
        console2.logInt(feesPlain);
        console2.logInt(feesJit);
        console2.log("attacker net token0 / token1: without JIT, with JIT");
        console2.logInt(plain.amount0());
        console2.logInt(jit.amount0());
        console2.logInt(plain.amount1());
        console2.logInt(jit.amount1());

        assertApproxEqRel(feesPlain, feesFloor * 6, 0.01e18, "the surcharge is real: ~6x the floor fee");
        assertApproxEqAbs(feesJit, feesPlain, 10, "incumbents collect the same with or without the JIT");
        assertApproxEqAbs(jit.amount0(), plain.amount0(), 10, "attacker pays the same token0");
        assertApproxEqAbs(jit.amount1(), plain.amount1(), 10, "attacker receives the same token1");
        assertLe(jit.amount0(), plain.amount0(), "rounding goes against the JIT, never for it");
        assertLe(jit.amount1(), plain.amount1());
    }

    /// @dev Fixed notional instead of a price target: the JIT absorbs 90% of the attacker's own swap, so
    ///      only 10% of it trades against the incumbents - and on exactly that part they are paid the
    ///      full rate. The fee RATE on volume that really trades against other LPs cannot be reduced;
    ///      what the JIT "saves" is fee on volume the attacker traded with itself (a no-op).
    function test_5b_selfJIT_fixedNotional_fullRateOnWhatTradesAgainstOthers() public {
        _fresh(0, 1e21);
        _setTip(TIP_AT_CAP);
        BalanceDelta added = _addLiquidity(k, JIT_LOWER, JIT_UPPER, 9e21, ATT);
        (BalanceDelta swapped, uint24 fee) = _swap(k, true, -1e18);
        BalanceDelta removed = _addLiquidity(k, JIT_LOWER, JIT_UPPER, -9e21, ATT);
        assertEq(fee, 3000);
        BalanceDelta net = added + swapped + removed;
        uint256 netIn = uint256(uint128(-net.amount0())); // what really left the attacker
        uint256 incumbentFees = uint256(_fees0(OTH));
        console2.log("self-JIT, fixed 1e18 exact-in: net token0 that left the attacker / incumbent fees");
        console2.log(netIn, incumbentFees);
        assertApproxEqRel(netIn, 1e17, 1e12, "10% of the swap traded against the incumbents");
        assertApproxEqAbs(incumbentFees * 1e6 / netIn, 3000, 1, "at the full 0.30%");
    }

    /// @dev FACT (limitation, standard v3/v4 behaviour made more attractive by the surcharge): a THIRD
    ///      party whose liquidity is in range during a high-tip swap takes its pro-rata share of the
    ///      whole fee, surcharge included. With 9x the incumbents' liquidity it takes 90%. Adding and
    ///      removing liquidity does not go through this hook and is never surcharged. To aim this at a
    ///      specific swap the JIT provider must know about it in advance and be ordered before it - which
    ///      the party that ASSEMBLES the transaction (bundler, sponsor, relayer) trivially can: see
    ///      test_fact_5a_relayerFlashJIT_noStandingLpNeeded in PriorityFeeHook.jit.t.sol (audit E-1).
    function test_fact_5b_thirdPartyJIT_takesProRataShareOfTheSurcharge() public {
        _fresh(0, 1e21);
        uint256 snap = vm.snapshotState();
        _setTip(TIP_AT_CAP);
        _swap(k, true, -1e18);
        int256 incumbentsAlone = _fees0(OTH);
        vm.revertToState(snap);

        _setTip(type(uint64).max - BASEFEE); // the JIT add is not a swap: no surcharge at any tip
        _addLiquidity(k, JIT_LOWER, JIT_UPPER, 9e21, ATT);
        _setTip(TIP_AT_CAP);
        _swap(k, true, -1e18); // the victim's high-tip swap
        _setTip(0);
        int256 jitFees = int256(_collect(k, JIT_LOWER, JIT_UPPER, ATT).amount0());
        _addLiquidity(k, JIT_LOWER, JIT_UPPER, -9e21, ATT);
        int256 incumbentsDiluted = _fees0(OTH);

        console2.log("fee of a 1e18 swap at the cap: incumbents alone / incumbents with 9x JIT / JIT provider");
        console2.logInt(incumbentsAlone);
        console2.logInt(incumbentsDiluted);
        console2.logInt(jitFees);
        assertApproxEqAbs(incumbentsAlone, 3e15, 2);
        assertApproxEqAbs(incumbentsDiluted * 10, incumbentsAlone, 20, "incumbents keep 10%");
        assertApproxEqAbs(jitFees * 10, incumbentsAlone * 9, 20, "the JIT provider takes 90%");
    }

    /// @dev Splitting one swap into many smaller ones in the same transaction never gives more out
    ///      (every step's fee rounds up).
    function testFuzz_5b_splittingASwap_neverCheaper(uint256 amount, uint256 parts, uint256 tip, bool zeroForOne)
        public
    {
        amount = bound(amount, 1, 1e21);
        parts = bound(parts, 2, 12);
        tip = bound(tip, 0, 1_200_000_000);
        _setTip(tip);
        uint256 snap = vm.snapshotState();
        uint256 single = checked.swapExactIn(hookKey, zeroForOne, amount, 0);
        vm.revertToState(snap);
        uint256 split;
        uint256 left = amount;
        for (uint256 i; i < parts; i++) {
            uint256 part = i == parts - 1 ? left : amount / parts;
            left -= part;
            if (part == 0) continue;
            split += checked.swapExactIn(hookKey, zeroForOne, part, 0);
        }
        assertLe(split, single, "splitting is never cheaper");
    }

    /// @dev Dust: 1 wei to 1000 wei, every swap kind, any tip. No revert, the fee is the schedule's, and
    ///      a 1-wei exact-in swap is all fee (so dust cannot be used to trade below the fee).
    function testFuzz_5b_dustSwaps(uint256 amount, uint256 tip, bool zeroForOne, bool exactIn) public {
        amount = bound(amount, 1, 1000);
        tip = bound(tip, 0, 1_200_000_000);
        _setTip(tip);
        (BalanceDelta d, uint24 fee) = _swap(hookKey, zeroForOne, exactIn ? -int256(amount) : int256(amount));
        assertEq(fee, _expectedFee(tip));
        (int256 paid, int256 got) = zeroForOne
            ? (-int256(d.amount0()), int256(d.amount1()))
            : (-int256(d.amount1()), int256(d.amount0()));
        assertGe(paid, 0);
        assertGe(got, 0);
        assertGt(paid, got, "at price 1 with a fee the trader always pays more than it gets");
    }

    function test_5b_oneWeiExactIn_isAllFee() public {
        _setTip(TIP_AT_CAP);
        (BalanceDelta d, uint24 fee) = _swap(hookKey, true, -1);
        assertEq(fee, 3000);
        assertEq(d.amount0(), -1);
        assertEq(d.amount1(), 0);
        _setTip(0);
        (d, fee) = _swap(hookKey, false, -1);
        assertEq(fee, 500);
        assertEq(d.amount1(), -1);
        assertEq(d.amount0(), 0);
    }

    // =============================================================================================
    // 5c / section 3. Ways around the surcharge, recorded as facts
    // =============================================================================================

    /// @dev FACT: an L1-originated deposit transaction has gas price 0 and is ordered before every normal
    ///      transaction of the block. A swap inside it pays the floor fee, however valuable its position.
    function test_fact_bypass_depositTransaction_paysFloorAtTopOfBlock() public {
        _setGas(0, BASEFEE);
        (, uint24 fee) = _swap(hookKey, true, -100e18);
        assertEq(fee, 500);
    }

    /// @dev FACT: a same-block follower released by a validity predicate needs no more tip than the other
    ///      followers; alone, it can use the smallest tip and pays the floor although it is the
    ///      arbitrage. (Ordering itself cannot be reproduced in a unit test; this records the fee.)
    function test_fact_bypass_conditionalFollowerWithMinimalTip_paysFloor() public {
        _setTip(TIP_AT_CAP);
        _swap(hookKey, true, -1000e18); // the trigger, which paid for its position
        _setTip(1_000_000); // the follower: node-suggested minimum
        (, uint24 fee) = _swapTo(hookKey, false, -1e30, SQRT_PRICE_1_1); // arbitrage back to the old price
        assertEq(fee, 500);
    }

    /// @dev FACT: the arbitrageur can take the trade to a pool without this hook. A hookless pool on the
    ///      same pair charges its static fee at any tip.
    function test_fact_bypass_otherPoolOnSamePair_ignoresTip() public {
        PoolKey memory other = _initStaticPool(currency0, currency1, 500, SQRT_PRICE_1_1);
        _addLiquidity(other, WIDE_LOWER, WIDE_UPPER, 1e24, 0);
        _setTip(TIP_AT_CAP);
        (, uint24 here) = _swap(hookKey, true, -1e18);
        (, uint24 there) = _swap(other, true, -1e18);
        assertEq(here, 3000);
        assertEq(there, 500);
    }

    /// @dev FACT: a tip paid outside tx.gasprice (direct transfer to the fee vault / coinbase, as the
    ///      EIP-8130 "coinbase tip" would do once active on Base) is invisible to the hook.
    function test_fact_bypass_tipPaidOutsideGasPrice_isInvisible() public {
        _setTip(0);
        vm.deal(address(this), 1 ether);
        (bool ok,) = block.coinbase.call{value: 0.01 ether}("");
        ok;
        (, uint24 fee) = _swap(hookKey, true, -1e18);
        assertEq(fee, 500);
    }
}
