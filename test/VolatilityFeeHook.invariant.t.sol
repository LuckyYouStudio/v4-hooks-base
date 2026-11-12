// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {VolatilityFeeHook} from "../src/VolatilityFeeHook.sol";
import {VolatilityMath} from "../src/libraries/VolatilityMath.sol";
import {HookTestBase} from "./utils/HookTestBase.sol";

/// @notice Random actor on TWO pools that share the hook: swaps of every kind and size down to 1 wei,
///         dust price limits around tick boundaries, block/time jumps, liquidity in and out - including
///         pulling EVERY position so the pool is empty (re-audit: an armed pool with no in-range
///         liquidity, where swaps move the price for free, used to be unreachable), and one-sided /
///         patchy shapes left behind when only some narrow positions are put back.
///         Keeps an independent model of what the hook state of each pool must be and flags any
///         divergence, and checks after every action that the pool that was NOT touched did not change.
///         Pool 0 starts armed and has no protocol fee; pool 1 starts unarmed and has a protocol fee.
contract Handler is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant BUCKET = 10;

    struct Model {
        uint256 variance;
        int32 lastLog;
        uint256 lastTimestamp;
        uint24 fee;
        bool armed;
    }

    IPoolManager public manager;
    VolatilityFeeHook public hook;
    PoolSwapTest public router;
    PoolModifyLiquidityTest public liqRouter;
    PoolKey[2] internal keys;
    PoolId[2] internal ids;
    Model[2] internal models;
    /// @dev protocol fee of each pool per direction [pool][0 = zeroForOne, 1 = oneForZero], pips
    uint24[2][2] internal protocolFees;

    // ghosts
    string public violation;
    uint256 public swapsOk;
    uint256 public swapsReverted;
    uint256 public dustSwaps;
    uint256 public updates;
    uint256 public armings;
    uint256 public blocksAdvanced;
    uint24 public maxFeeSeen;
    uint256 public drains;
    /// @dev successful swaps on an ARMED pool that had zero in-range liquidity when the swap started
    uint256 public swapsInEmptyArmedPool;
    /// @dev of those, the ones on which the hook made an observation that raised the variance
    uint256 public freeMovesCounted;

    struct Pos {
        int24 lower;
        int24 upper;
        int256 liq;
    }

    /// @dev every narrow position this handler added (salt 1), so that drain() can pull them all
    Pos[][2] internal extra;
    /// @dev base liquidity taken out by drain() and not yet put back
    uint256[2] public baseOut;

    constructor(
        IPoolManager _manager,
        VolatilityFeeHook _hook,
        PoolSwapTest _router,
        PoolModifyLiquidityTest _liqRouter,
        PoolKey[2] memory _keys,
        uint24[2][2] memory _protocolFees
    ) {
        manager = _manager;
        hook = _hook;
        router = _router;
        liqRouter = _liqRouter;
        protocolFees = _protocolFees;
        for (uint256 i; i < 2; i++) {
            keys[i] = _keys[i];
            ids[i] = _keys[i].toId();
            VolatilityFeeHook.PoolState memory s = _hook.poolState(ids[i]);
            models[i] = Model(s.variance, s.lastLogPrice, s.lastTimestamp, s.fee, s.armed);
            MockERC20(Currency.unwrap(_keys[i].currency0)).approve(address(_router), type(uint256).max);
            MockERC20(Currency.unwrap(_keys[i].currency1)).approve(address(_router), type(uint256).max);
            MockERC20(Currency.unwrap(_keys[i].currency0)).approve(address(_liqRouter), type(uint256).max);
            MockERC20(Currency.unwrap(_keys[i].currency1)).approve(address(_liqRouter), type(uint256).max);
        }
    }

    function model(uint256 i) external view returns (Model memory) {
        return models[i];
    }

    function _flag(string memory what) internal {
        if (bytes(violation).length == 0) violation = what;
    }

    function _hash(uint256 i) internal view returns (bytes32) {
        return keccak256(abi.encode(hook.poolState(ids[i])));
    }

    // ---- actions ----

    function swap(uint8 poolSeed, bool zeroForOne, bool exactIn, uint256 amount, bool limited, uint24 limitTicks)
        external
    {
        uint256 i = poolSeed % 2;
        // a quarter of the swaps are dust (1 .. 1e6 wei), the rest anything up to 3e23
        if (amount % 4 == 0) {
            amount = 1 + (amount >> 8) % 1e6;
            dustSwaps++;
        } else {
            amount = bound(amount, 1e9, 3e23);
        }
        (uint160 price, int24 tickBefore,,) = manager.getSlot0(ids[i]);
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        // an unlimited swap on an empty pool runs to the end of the price range and the run never comes
        // back to where liquidity can be added: always limit those
        if (limited || manager.getLiquidity(ids[i]) == 0) {
            int24 t = tickBefore + (zeroForOne ? -int24(1) : int24(1)) * int24(uint24(bound(limitTicks, 1, 4000)));
            if (t > TickMath.MIN_TICK && t < TickMath.MAX_TICK) limit = TickMath.getSqrtPriceAtTick(t);
        }
        _swapAndCheck(i, zeroForOne, exactIn ? -int256(amount) : int256(amount), price, limit);
    }

    /// @dev the H-1 move: stop a few units of sqrtPriceX96 either side of the nearest tick boundary
    function dustLimitSwap(uint8 poolSeed, uint8 offset) external {
        uint256 i = poolSeed % 2;
        (uint160 price, int24 tick,,) = manager.getSlot0(ids[i]);
        if (tick <= TickMath.MIN_TICK + 2 || tick >= TickMath.MAX_TICK - 2) return;
        uint160 boundary = TickMath.getSqrtPriceAtTick(offset % 2 == 0 ? tick : tick + 1);
        uint160 target = uint160(uint256(boundary) + (offset >> 1) % 7) - 3;
        if (target == price) return;
        dustSwaps++;
        _swapAndCheck(i, target < price, -1e30, price, target);
    }

    function _swapAndCheck(uint256 i, bool zeroForOne, int256 amountSpecified, uint160 price, uint160 limit)
        internal
    {
        if (zeroForOne ? limit >= price : limit <= price) return;
        bytes32 otherBefore = _hash(1 - i);

        // what the hook must do on this swap
        Model memory m = models[i];
        bool expectUpdate = block.timestamp / BUCKET > m.lastTimestamp / BUCKET;
        if (expectUpdate) {
            int32 x = VolatilityMath.logPrice(price);
            if (m.armed) {
                m.variance = VolatilityMath.accumulate(m.variance, block.timestamp - m.lastTimestamp, m.lastLog, x);
                m.fee = VolatilityMath.feeFromVariance(m.variance);
            } else if (manager.getLiquidity(ids[i]) != 0) {
                m.armed = true;
            }
            m.lastLog = x;
            m.lastTimestamp = block.timestamp;
        }
        if (hook.currentFee(ids[i]) != m.fee) _flag("currentFee() != model");
        bool emptyArmed = models[i].armed && manager.getLiquidity(ids[i]) == 0;

        vm.recordLogs();
        try router.swap(
            keys[i],
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {
            swapsOk++;
            if (emptyArmed) {
                swapsInEmptyArmedPool++;
                if (expectUpdate && m.variance > VolatilityMath.decay(models[i].variance, block.timestamp - models[i].lastTimestamp)) {
                    freeMovesCounted++;
                }
            }
            if (expectUpdate) {
                if (m.armed && !models[i].armed) armings++;
                models[i] = m;
                updates++;
            }
            if (m.fee > maxFeeSeen) maxFeeSeen = m.fee;
            uint24 pf = protocolFees[i][zeroForOne ? 0 : 1];
            _checkLogs(uint24(uint256(pf) + m.fee - (uint256(pf) * m.fee) / 1e6), expectUpdate);
        } catch {
            // e.g. exact-out larger than the pool can deliver: whole swap (and hook update) rolled back
            swapsReverted++;
            vm.getRecordedLogs();
        }

        VolatilityFeeHook.PoolState memory s = hook.poolState(ids[i]);
        m = models[i];
        if (s.variance != m.variance) _flag("variance != model");
        if (s.fee != m.fee) _flag("fee != model");
        if (s.lastLogPrice != m.lastLog) _flag("lastLogPrice != model");
        if (s.lastTimestamp != m.lastTimestamp) _flag("lastTimestamp != model");
        if (s.armed != m.armed) _flag("armed != model");
        if (_hash(1 - i) != otherBefore) _flag("a swap on one pool changed the other pool's hook state");
    }

    function _checkLogs(uint24 expectedFee, bool expectUpdate) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 feeUpdates;
        bool sawSwap;
        for (uint256 j; j < logs.length; j++) {
            if (logs[j].emitter == address(hook)) feeUpdates++;
            if (logs[j].emitter == address(manager) && logs[j].topics[0] == IPoolManager.Swap.selector) {
                (,,,,, uint24 charged) = abi.decode(logs[j].data, (int128, int128, uint160, uint128, int24, uint24));
                if (charged != expectedFee) _flag("fee charged by PoolManager != protocol fee + model LP fee");
                sawSwap = true;
            }
        }
        if (!sawSwap) _flag("no Swap event");
        if (feeUpdates != (expectUpdate ? 1 : 0)) _flag("FeeUpdated count");
    }

    function advance(uint8 blocks, uint16 secs) external {
        uint256 b = bound(blocks, 1, 60);
        // sub-second blocks: several blocks share a timestamp, ~50 blocks share a bucket
        uint256 s = bound(secs, 0, 2500);
        if (secs % 3 == 0) s = 0;
        else if (secs % 3 == 1) s = b / 5;
        vm.roll(block.number + b);
        vm.warp(block.timestamp + s);
        blocksAdvanced += b;
    }

    function addLiquidity(uint8 poolSeed, uint64 amount, int8 lowerSeed, uint8 widthSeed) external {
        uint256 i = poolSeed % 2;
        bytes32 h0 = _hash(0);
        bytes32 h1 = _hash(1);
        (, int24 tick,,) = manager.getSlot0(ids[i]);
        if (tick < -110_000 || tick > 110_000) return;
        int256 liq = int256(bound(amount, 1e15, 1e22));
        int24 lower = ((tick / 60) + int24(lowerSeed % 20)) * 60;
        int24 upper = lower + int24(uint24(bound(widthSeed, 1, 50))) * 60;
        try liqRouter.modifyLiquidity(keys[i], ModifyLiquidityParams(lower, upper, liq, bytes32(uint256(1))), "") {
            extra[i].push(Pos(lower, upper, liq));
        } catch {}
        if (_hash(0) != h0 || _hash(1) != h1) _flag("adding liquidity changed hook state");
    }

    function _baseLiquidity(uint256 i) internal view returns (uint128) {
        return manager.getPositionLiquidity(
            ids[i], Position.calculatePositionKey(address(liqRouter), -120_000, 120_000, bytes32(0))
        );
    }

    /// @dev pull the base liquidity partly out and put it back: LPs can always leave
    function removeAndReAddBase(uint8 poolSeed, uint64 amount) external {
        uint256 i = poolSeed % 2;
        bytes32 h0 = _hash(0);
        bytes32 h1 = _hash(1);
        int256 liq = int256(bound(amount, 1e15, 1e21));
        if (_baseLiquidity(i) < uint256(liq)) return; // drained
        // not in a try: removing liquidity must never fail, whatever the fee and the hook state
        liqRouter.modifyLiquidity(keys[i], ModifyLiquidityParams(-120_000, 120_000, -liq, 0), "");
        try liqRouter.modifyLiquidity(keys[i], ModifyLiquidityParams(-120_000, 120_000, liq, 0), "") {} catch {}
        if (_hash(0) != h0 || _hash(1) != h1) _flag("removing liquidity changed hook state");
    }

    /// @dev EVERY LP leaves: the whole base position and every narrow position. The pool is empty
    ///      afterwards, at whatever fee and hook state it had. Not in a try: a revert is a finding.
    function drain(uint8 poolSeed) external {
        uint256 i = poolSeed % 2;
        bytes32 h0 = _hash(0);
        bytes32 h1 = _hash(1);
        uint128 base = _baseLiquidity(i);
        if (base != 0) {
            liqRouter.modifyLiquidity(
                keys[i], ModifyLiquidityParams(-120_000, 120_000, -int256(uint256(base)), 0), ""
            );
            baseOut[i] += base;
        }
        Pos[] storage ps = extra[i];
        for (uint256 j = ps.length; j > 0; j--) {
            Pos memory q = ps[j - 1];
            liqRouter.modifyLiquidity(
                keys[i], ModifyLiquidityParams(q.lower, q.upper, -q.liq, bytes32(uint256(1))), ""
            );
            ps.pop();
        }
        drains++;
        if (manager.getLiquidity(ids[i]) != 0) _flag("drain left in-range liquidity behind");
        if (_hash(0) != h0 || _hash(1) != h1) _flag("draining the pool changed hook state");
    }

    /// @dev the base LPs come back (all of them, or part), wherever the price has wandered meanwhile
    function restoreBase(uint8 poolSeed, bool partly) external {
        uint256 i = poolSeed % 2;
        uint256 amount = baseOut[i];
        if (amount == 0) return;
        if (partly) amount = amount / 2 + 1;
        bytes32 h0 = _hash(0);
        bytes32 h1 = _hash(1);
        try liqRouter.modifyLiquidity(
            keys[i], ModifyLiquidityParams(-120_000, 120_000, int256(amount), 0), ""
        ) {
            baseOut[i] -= amount;
        } catch {}
        if (_hash(0) != h0 || _hash(1) != h1) _flag("adding liquidity changed hook state");
    }
}

contract VolatilityFeeHookInvariantTest is HookTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    Handler internal handler;
    PoolKey internal key2;
    PoolId internal id2;

    function setUp() public {
        _baseSetUp();
        // second pool on the same hook: other tokens, starts UNARMED, has an asymmetric protocol fee
        Currency c0 = currency0;
        Currency c1 = currency1;
        (Currency a, Currency b) = deployMintAndApprove2Currencies();
        (key2, id2) = _initDynamicPool(a, b, SQRT_PRICE_1_1);
        _setProtocolFee(key2, 800, 300);
        (currency0, currency1) = (c0, c1);

        PoolKey[2] memory ks = [hookKey, key2];
        uint24[2][2] memory pfs = [[uint24(0), 0], [uint24(800), 300]];
        handler = new Handler(manager, hook, swapRouter, modifyLiquidityRouter, ks, pfs);
        for (uint256 i; i < 2; i++) {
            MockERC20(Currency.unwrap(ks[i].currency0)).transfer(address(handler), 2 ** 200);
            MockERC20(Currency.unwrap(ks[i].currency1)).transfer(address(handler), 2 ** 200);
            // the handler owns the base position it later partially removes
            vm.prank(address(handler));
            modifyLiquidityRouter.modifyLiquidity(
                ks[i], ModifyLiquidityParams(WIDE_LOWER, WIDE_UPPER, WIDE_LIQUIDITY, 0), ZERO_BYTES
            );
        }
        targetContract(address(handler));
    }

    function invariant_stateMatchesModel_bothPools() public view {
        assertEq(handler.violation(), "");
        PoolId[2] memory ids = [hookId, id2];
        for (uint256 i; i < 2; i++) {
            VolatilityFeeHook.PoolState memory s = hook.poolState(ids[i]);
            Handler.Model memory m = handler.model(i);
            assertEq(s.variance, m.variance);
            assertEq(s.fee, m.fee);
            assertEq(s.lastLogPrice, m.lastLog);
            assertEq(s.lastTimestamp, m.lastTimestamp);
            assertEq(s.armed, m.armed);
        }
    }

    function invariant_feeWithinHardBounds_bothPools() public view {
        PoolId[2] memory ids = [hookId, id2];
        for (uint256 i; i < 2; i++) {
            VolatilityFeeHook.PoolState memory s = hook.poolState(ids[i]);
            assertGe(s.fee, MIN_FEE);
            assertLe(s.fee, MAX_FEE);
            assertLe(s.variance, VolatilityMath.VAR_CAP);
            assertEq(s.fee, VolatilityMath.feeFromVariance(s.variance));
            if (!s.armed) assertEq(s.variance, 0, "nothing accumulates before arming");
            uint24 f = hook.currentFee(ids[i]);
            assertGe(f, MIN_FEE);
            assertLe(f, MAX_FEE);
        }
        assertLe(handler.maxFeeSeen(), MAX_FEE);
    }

    function invariant_clockNeverAhead() public view {
        PoolId[2] memory ids = [hookId, id2];
        for (uint256 i; i < 2; i++) {
            VolatilityFeeHook.PoolState memory s = hook.poolState(ids[i]);
            assertTrue(s.registered);
            assertLe(s.lastTimestamp, block.timestamp);
        }
    }

    function invariant_hookHoldsNothing() public view {
        PoolKey[2] memory ks = [hookKey, key2];
        for (uint256 i; i < 2; i++) {
            assertEq(ks[i].currency0.balanceOf(address(hook)), 0);
            assertEq(ks[i].currency1.balanceOf(address(hook)), 0);
            assertEq(manager.balanceOf(address(hook), ks[i].currency0.toId()), 0);
            assertEq(manager.balanceOf(address(hook), ks[i].currency1.toId()), 0);
        }
        assertEq(address(hook).balance, 0);
    }

    function afterInvariant() public view {
        // not an assertion on a single run (fuzzer may pick few swaps), just visibility with -vv
        handler.swapsOk();
        // how often this run reached "armed pool, zero in-range liquidity" (N-1) and booked a free move there
        console2.log("handler: swaps in an empty armed pool:", handler.swapsInEmptyArmedPool());
        console2.log("handler: free moves counted there    :", handler.freeMovesCounted());
    }

    /// @dev Re-audit, test gap: "armed pool + zero in-range liquidity" was never reached by the handler.
    ///      A fuzz campaign cannot assert its own coverage, so this drives the handler by hand through
    ///      exactly that state and checks (a) the handler's model agrees with the hook there, and (b) the
    ///      state is what N-1 says it is: a free move in the empty pool IS counted and lifts the fee.
    function test_handler_reachesArmedEmptyPool_freeMoveIsCounted() public {
        assertTrue(hook.poolState(hookId).armed);
        handler.drain(0);
        assertEq(manager.getLiquidity(hookId), 0);
        assertEq(handler.drains(), 1);
        handler.advance(1, 10); // secs % 3 == 1 -> stays in the bucket; then a real jump
        handler.advance(1, 32); // secs % 3 == 2 -> +32 s
        uint256 mine = currency0.balanceOf(address(handler)) + currency1.balanceOf(address(handler));
        handler.swap(0, true, true, 1e18 + 1, true, 3000); // 3000 ticks down through the empty pool
        handler.advance(1, 32);
        handler.swap(0, false, true, 1e18 + 1, true, 3000); // and back
        assertEq(currency0.balanceOf(address(handler)) + currency1.balanceOf(address(handler)), mine, "free");
        assertEq(handler.violation(), "");
        assertEq(handler.swapsInEmptyArmedPool(), 2);
        assertEq(handler.freeMovesCounted(), 1);
        assertEq(hook.poolState(hookId).fee, MAX_FEE);
        // LPs come back to a pool whose fee is at the cap although nothing was ever traded
        handler.restoreBase(0, false);
        assertEq(manager.getLiquidity(hookId), 2e24);
        assertEq(handler.violation(), "");
        invariant_stateMatchesModel_bothPools();
        invariant_feeWithinHardBounds_bothPools();
    }
}
