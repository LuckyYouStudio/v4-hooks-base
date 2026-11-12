// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {VolatilityFeeHook} from "../../src/VolatilityFeeHook.sol";
import {VolatilityMath} from "../../src/libraries/VolatilityMath.sol";

/// @notice The hook against the REAL Uniswap v4 PoolManager on Base mainnet (forked, nothing is sent).
///
/// PoolManager on Base (chain 8453): 0x498581fF718922c3f8e6A244956aF099B2652b2b
///   source: Uniswap official v4 deployments page, https://docs.uniswap.org/contracts/v4/deployments
///           (section "Base: 8453", fetched 2026-11-11)
///   verified 2026-11-11 with `cast code <addr> --rpc-url https://mainnet.base.org`: ~24.0 kB of code;
///   `owner()` and `protocolFeeController()` answer.
///
/// Needs BASE_RPC_URL (e.g. https://mainnet.base.org). Without it every test here is skipped.
/// Block is pinned so results are reproducible.
contract BaseForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using Hooks for IHooks;

    IPoolManager internal constant MANAGER = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    uint256 internal constant FORK_BLOCK = 56_228_000;
    uint256 internal constant BASE_CHAIN_ID = 8453;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    int24 internal constant SPACING = 60;
    int256 internal constant TINY = 1e15;
    uint256 internal constant BUCKET = 10;

    VolatilityFeeHook internal hook;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liqRouter;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    PoolKey internal key; // mock/mock
    PoolId internal id;
    PoolKey internal ethKey; // native ETH/mock
    PoolId internal ethId;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "BASE_RPC_URL not set");
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        assertEq(block.chainid, BASE_CHAIN_ID, "not Base mainnet");
        assertGt(address(MANAGER).code.length, 20_000, "no PoolManager code at the documented address");

        // v4-core's own test routers, deployed fresh on the fork and pointed at the real manager
        swapRouter = new PoolSwapTest(MANAGER);
        liqRouter = new PoolModifyLiquidityTest(MANAGER);

        (address expected, bytes32 salt) = HookMiner.find(
            address(this),
            uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG),
            type(VolatilityFeeHook).creationCode,
            abi.encode(MANAGER)
        );
        hook = new VolatilityFeeHook{salt: salt}(MANAGER);
        assertEq(address(hook), expected);

        MockERC20 t0 = new MockERC20("A", "A", 18);
        MockERC20 t1 = new MockERC20("B", "B", 18);
        (tokenA, tokenB) = address(t0) < address(t1) ? (t0, t1) : (t1, t0);
        tokenA.mint(address(this), 1e30);
        tokenB.mint(address(this), 1e30);
        tokenA.approve(address(swapRouter), type(uint256).max);
        tokenB.approve(address(swapRouter), type(uint256).max);
        tokenA.approve(address(liqRouter), type(uint256).max);
        tokenB.approve(address(liqRouter), type(uint256).max);
        vm.deal(address(this), 1_000_000 ether);

        key = PoolKey(
            Currency.wrap(address(tokenA)),
            Currency.wrap(address(tokenB)),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            SPACING,
            IHooks(address(hook))
        );
        id = key.toId();
        MANAGER.initialize(key, SQRT_PRICE_1_1);
        liqRouter.modifyLiquidity(key, ModifyLiquidityParams(-120_000, 120_000, 1e24, 0), "");

        ethKey = PoolKey(
            CurrencyLibrary.ADDRESS_ZERO,
            Currency.wrap(address(tokenB)),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            SPACING,
            IHooks(address(hook))
        );
        ethId = ethKey.toId();
        MANAGER.initialize(ethKey, SQRT_PRICE_1_1);
        liqRouter.modifyLiquidity{value: 2000 ether}(ethKey, ModifyLiquidityParams(-120_000, 120_000, 1e21, 0), "");

        // next bucket: one swap each, seen by the hook with liquidity -> both pools are armed, at the
        // floor, with the price parked mid-milli-tick at log price 0
        _nextBucket();
        _moveTo(key, 0);
        _moveTo(ethKey, 0);
        assertTrue(hook.poolState(id).armed);
        assertTrue(hook.poolState(ethId).armed);
    }

    receive() external payable {}

    // ---- helpers ----

    /// @dev sqrt price in the middle of the milli-tick `tick * 1000`: the hook reads exactly `tick` ticks
    ///      and tiny follow-up swaps do not change that
    function _mid(int24 tick) internal pure returns (uint160 p) {
        uint256 lo = TickMath.getSqrtPriceAtTick(tick);
        uint256 hi = TickMath.getSqrtPriceAtTick(tick + 1);
        p = uint160(lo + (hi - lo) / 2000);
        require(VolatilityMath.logPrice(p) == int256(tick) * 1000);
    }

    function _fee() internal view returns (uint24 fee) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(MANAGER) && logs[i].topics[0] == IPoolManager.Swap.selector) {
                (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                found = true;
            }
        }
        assertTrue(found, "no Swap event from the real PoolManager");
    }

    function _swap(PoolKey memory k, bool zeroForOne, int256 amount, uint160 limit)
        internal
        returns (BalanceDelta d, uint24 fee)
    {
        if (limit == 0) limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        uint256 value;
        if (k.currency0.isAddressZero() && zeroForOne) value = amount < 0 ? uint256(-amount) : 500 ether;
        vm.recordLogs();
        d = swapRouter.swap{value: value}(
            k,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amount, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        fee = _fee();
    }

    function _moveTo(PoolKey memory k, int24 tick) internal returns (uint24 fee) {
        (uint160 p,,,) = MANAGER.getSlot0(k.toId());
        uint160 target = _mid(tick);
        bool zeroForOne = target < p;
        uint256 value = k.currency0.isAddressZero() && zeroForOne ? 900 ether : 0;
        vm.recordLogs();
        swapRouter.swap{value: value}(
            k,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -1e30, sqrtPriceLimitX96: target}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        fee = _fee();
        (, int24 t,,) = MANAGER.getSlot0(k.toId());
        assertEq(t, tick);
    }

    function _nextBlock(uint256 dt) internal {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + dt);
    }

    /// @dev first second of the next 10s bucket (the fork block's timestamp is not aligned)
    function _nextBucket() internal {
        vm.roll(block.number + 1);
        vm.warp((block.timestamp / BUCKET + 1) * BUCKET);
    }

    function _bal() internal view returns (uint256) {
        return tokenA.balanceOf(address(this)) + tokenB.balanceOf(address(this));
    }

    // ---- tests ----

    function test_fork_environment() public view {
        assertEq(block.number, FORK_BLOCK + 1); // setUp moved one block on to arm the pools
        assertEq(address(hook.poolManager()), address(MANAGER));
        Hooks.validateHookPermissions(IHooks(address(hook)), hook.getHookPermissions());
        assertTrue(IHooks(address(hook)).isValidHookAddress(LPFeeLibrary.DYNAMIC_FEE_FLAG));
    }

    function test_fork_initialize_registers_onRealManager() public view {
        VolatilityFeeHook.PoolState memory s = hook.poolState(id);
        assertTrue(s.registered);
        assertEq(s.fee, 500);
        assertTrue(s.armed);
        assertEq(s.variance, 0);
        assertEq(s.lastLogPrice, 0);
        assertEq(s.lastTimestamp, block.timestamp);
        // the real manager stores lpFee = 0 for a dynamic pool; the hook's override is per swap
        (uint160 p, int24 tick, uint24 protocolFee, uint24 lpFee) = MANAGER.getSlot0(id);
        assertEq(p, _mid(0));
        assertEq(tick, 0);
        assertEq(lpFee, 0);
        // Base mainnet has a protocol fee controller (0xc53D...4b55 at this block). It has not set a
        // protocol fee on our freshly created pools, which is why the Swap events in the tests below
        // show exactly the hook's LP fee. With a protocol fee the event shows protocol + lp*(1-protocol)
        // (test_fork_protocolFee_fourSwapKinds_onRealManager below).
        assertEq(protocolFee, 0);
        assertTrue(MANAGER.protocolFeeController() != address(0));
    }

    function test_fork_staticFeePool_rejectedByRealManager() public {
        PoolKey memory k = key;
        k.fee = 3000;
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterInitialize.selector,
                abi.encodeWithSelector(VolatilityFeeHook.NotDynamicFee.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        MANAGER.initialize(k, SQRT_PRICE_1_1);
    }

    function test_fork_fourSwapKinds_floorFee() public {
        uint24 fee;
        (, fee) = _swap(key, true, -1e18, 0);
        assertEq(fee, 500);
        (, fee) = _swap(key, false, -1e18, 0);
        assertEq(fee, 500);
        (, fee) = _swap(key, true, 1e18, 0);
        assertEq(fee, 500);
        (, fee) = _swap(key, false, 1e18, 0);
        assertEq(fee, 500);
    }

    function test_fork_crossBlock_update_andFourSwapKinds() public {
        assertEq(_moveTo(key, 100), 500);
        _nextBlock(1); // a new block in the same bucket changes nothing
        assertEq(hook.currentFee(id), 500);
        _nextBucket();
        assertEq(hook.currentFee(id), 3000);
        uint24 fee;
        (, fee) = _swap(key, false, -TINY, 0);
        assertEq(fee, 3000);
        assertEq(hook.poolState(id).variance, 1e10);
        (, fee) = _swap(key, true, -1e18, 0);
        assertEq(fee, 3000);
        (, fee) = _swap(key, true, 1e18, 0);
        assertEq(fee, 3000);
        (, fee) = _swap(key, false, 1e18, 0);
        assertEq(fee, 3000);

        // back to the tick the block opened on, then one half-life later
        _moveTo(key, 100);
        _nextBlock(600);
        (, fee) = _swap(key, true, -TINY, 0);
        assertEq(fee, 2267);
    }

    function test_fork_cap_andDecay() public {
        _moveTo(key, -3000);
        _nextBucket();
        (, uint24 fee) = _swap(key, true, -TINY, 0);
        assertEq(fee, 10_000);
        assertEq(hook.poolState(id).variance, VolatilityMath.VAR_CAP);
        (, fee) = _swap(key, false, 1e18, 0); // exact-out at the cap works
        assertEq(fee, 10_000);
        _moveTo(key, -3000);
        _nextBlock(2 days);
        (, fee) = _swap(key, true, -TINY, 0);
        assertEq(fee, 500);
    }

    function test_fork_sameBlockRoundTrip_noEffect() public {
        _moveTo(key, 40);
        _nextBucket();
        uint256 snap = vm.snapshotState();

        // control
        (, uint24 c0) = _swap(key, true, -TINY, 0);
        assertEq(c0, 1500);
        _nextBucket();
        (, uint24 c1) = _swap(key, true, -TINY, 0);
        bytes32 cState = keccak256(abi.encode(hook.poolState(id)));
        vm.revertToState(snap);

        // attack: +400 ticks and back inside the block
        (, uint24 a0) = _swap(key, true, -TINY, 0);
        (uint160 p,,,) = MANAGER.getSlot0(id);
        assertEq(_moveTo(key, 440), c0);
        (, uint24 back) = _swap(key, true, -1e30, p);
        assertEq(back, c0);
        _nextBucket();
        (, uint24 a1) = _swap(key, true, -TINY, 0);
        assertEq(a0, c0);
        assertEq(a1, c1);
        assertEq(keccak256(abi.encode(hook.poolState(id))), cState);
    }

    function test_fork_nativeEthPool() public {
        _moveTo(ethKey, -100); // ETH in
        _nextBucket();
        (, uint24 fee) = _swap(ethKey, true, -1 ether, 0);
        assertEq(fee, 3000);
        (, fee) = _swap(ethKey, false, -1e18, 0);
        assertEq(fee, 3000);
        assertEq(address(hook).balance, 0);
    }

    function test_fork_onlyRealManagerMayCall() public {
        SwapParams memory p = SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0});
        vm.expectRevert(bytes4(keccak256("NotPoolManager()")));
        hook.beforeSwap(address(this), key, p, "");
        vm.expectRevert(bytes4(keccak256("NotPoolManager()")));
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
    }

    function test_fork_gasOverhead_onRealManager() public {
        PoolKey memory stat = PoolKey(key.currency0, key.currency1, 500, SPACING, IHooks(address(0)));
        // the hookless (tokenA, tokenB, 500, 60) pool cannot exist yet: the tokens were just created
        MANAGER.initialize(stat, SQRT_PRICE_1_1);
        liqRouter.modifyLiquidity(stat, ModifyLiquidityParams(-120_000, 120_000, 1e24, 0), "");
        _swap(key, true, -1e18, 0);
        _swap(stat, true, -1e18, 0);
        _swap(key, false, -1e18, 0);
        _swap(stat, false, -1e18, 0);
        _nextBucket();

        uint256 base = _gas(stat);
        uint256 first = _gas(key);
        uint256 later = _gas(key);
        uint256 baseLater = _gas(stat);
        console2.log("real PoolManager, swap without hook      :", base);
        console2.log("real PoolManager, hook overhead (update) :", first - base);
        console2.log("real PoolManager, hook overhead (cached) :", later - baseLater);
        assertLt(first - base, 30_000);
        assertLt(later - baseLater, 12_000);
    }

    // ---- audit round 1 regressions, on the real PoolManager ----

    /// @dev H-1 on the real manager (the auditor's PoC was only run locally): the price is flipped one
    ///      unit of sqrtPriceX96 across the tick-0 boundary so that EVERY bucket observation sees it on
    ///      the other side, for 120 buckets (20 minutes, two half-lives), plus a flip in every block of
    ///      the first 300 blocks. The fee never leaves the floor.
    function test_fork_regression_H1_tickBoundaryFlicker() public {
        uint160 pB = TickMath.getSqrtPriceAtTick(0);
        _swap(key, true, -1e30, pB);
        uint256 b = _bal();
        for (uint256 i; i < 300; i++) {
            _swap(key, i % 2 == 0, -1e30, i % 2 == 0 ? pB - 1 : pB);
            (, int24 t,,) = MANAGER.getSlot0(id);
            assertEq(t, i % 2 == 0 ? int24(-1) : int24(0));
            vm.roll(block.number + 1);
            if (i % 5 == 4) vm.warp(block.timestamp + 1);
            assertEq(hook.currentFee(id), 500);
        }
        for (uint256 i; i < 120; i++) {
            _nextBucket();
            (, uint24 fee) = _swap(key, i % 2 == 0, -1e30, i % 2 == 0 ? pB - 1 : pB);
            assertEq(fee, 500);
            assertLe(hook.poolState(id).variance, 1);
        }
        _nextBucket();
        assertEq(hook.currentFee(id), 500);
        assertLt(b - _bal(), 1e6, "attacker's token cost stays dust; the fee did not move");
    }

    /// @dev M-1 as a recorded fact on the real manager: this contract owns all the pool's liquidity,
    ///      pushes 100 ticks over a bucket boundary and back, and collects its LP fees.
    function test_fork_fact_M1_soleLp_pushIsFree() public {
        (uint160 p,,,) = MANAGER.getSlot0(id);
        // collect whatever the position earned during setup first, so the signed net is the push's alone
        liqRouter.modifyLiquidity(key, ModifyLiquidityParams(-120_000, 120_000, 0, 0), "");
        uint256 b = _bal();
        _moveTo(key, 100);
        _nextBucket();
        (, uint24 fee) = _swap(key, true, -1e30, p);
        assertEq(fee, 3000);
        uint256 gross = b - _bal();
        assertGt(gross, 1e19); // ~0.35% of ~5e21
        liqRouter.modifyLiquidity(key, ModifyLiquidityParams(-120_000, 120_000, 0, 0), "");
        uint256 a = _bal();
        int256 net = int256(b) - int256(a); // signed (re-audit N-2): negative = came out ahead
        console2.log("real PoolManager, sole LP push 100 ticks: gross (wei)", gross);
        console2.log("  net after collecting, signed (wei):", net);
        assertLt(net, 1000);
        assertGt(net, -1000);
    }

    /// @dev Re-audit N-1 as a recorded fact on the real manager: single-sided liquidity 1e24 in [0, 6000),
    ///      price exactly on its lower edge. Two limit swaps by anybody, one bucket apart, down into the
    ///      void and back: not one wei moves and the fee is at the 1% cap for the next trader.
    function test_fork_fact_N1_priceOnLiquidityEdge_freeLiftToCap() public {
        PoolKey memory k = key;
        k.tickSpacing = 10;
        PoolId kid = k.toId();
        MANAGER.initialize(k, TickMath.getSqrtPriceAtTick(0));
        liqRouter.modifyLiquidity(k, ModifyLiquidityParams(0, 6000, 1e24, 0), "");
        assertEq(MANAGER.getLiquidity(kid), 1e24);
        int256 b = int256(_bal());

        _nextBucket();
        _swap(k, true, -1e30, TickMath.getSqrtPriceAtTick(-50_000)); // arms at tick 0, then walks the void
        assertTrue(hook.poolState(kid).armed);
        assertEq(MANAGER.getLiquidity(kid), 0);
        _nextBucket();
        assertEq(hook.currentFee(kid), 10_000);
        _swap(k, false, -1e30, TickMath.getSqrtPriceAtTick(0));
        int256 cost = b - int256(_bal());
        console2.log("real PoolManager, N-1 price on the liquidity edge: attacker net cost, signed (wei):", cost);
        assertEq(cost, 0);
        assertEq(hook.poolState(kid).fee, 10_000);
        assertEq(MANAGER.getLiquidity(kid), 1e24);
        (, uint24 fee) = _swap(k, false, -1e18, 0);
        assertEq(fee, 10_000, "the next honest buyer pays 1%");
    }

    /// @dev L-2 on the real manager: an absurd initial price on an empty pool is not counted.
    function test_fork_unarmedPool_absurdInitialPrice_startsAtFloor() public {
        PoolKey memory k = key;
        k.tickSpacing = 10;
        PoolId kid = k.toId();
        MANAGER.initialize(k, TickMath.getSqrtPriceAtTick(200_000));
        _nextBucket();
        _swap(k, true, -1e30, SQRT_PRICE_1_1); // free: no liquidity
        assertFalse(hook.poolState(kid).armed);
        liqRouter.modifyLiquidity(k, ModifyLiquidityParams(-120_000, 120_000, 1e24, 0), "");
        _nextBucket();
        (, uint24 fee) = _swap(k, true, -1e18, 0);
        assertEq(fee, 500);
        assertTrue(hook.poolState(kid).armed);
        assertEq(hook.poolState(kid).variance, 0);
    }

    /// @dev With a protocol fee set by Base's real protocol fee controller (impersonated on the fork):
    ///      the real manager charges protocol + lp * (1 - protocol), per direction, for all four swap
    ///      kinds, at an elevated LP fee.
    function test_fork_protocolFee_fourSwapKinds_onRealManager() public {
        vm.prank(MANAGER.protocolFeeController());
        MANAGER.setProtocolFee(key, (uint24(400) << 12) | 1000); // 0.10% for 0->1, 0.04% for 1->0
        _moveTo(key, 100);
        _nextBucket();
        uint24 fee;
        (, fee) = _swap(key, true, -1e18, 0);
        assertEq(fee, 3997); // 1000 + 3000 - floor(1000 * 3000 / 1e6)
        (, fee) = _swap(key, false, -1e18, 0);
        assertEq(fee, 3399); // 400 + 3000 - floor(400 * 3000 / 1e6)
        (, fee) = _swap(key, true, 1e18, 0);
        assertEq(fee, 3997);
        (, fee) = _swap(key, false, 1e18, 0);
        assertEq(fee, 3399);
        assertEq(hook.poolState(id).fee, 3000);
    }

    function _gas(PoolKey memory k) internal returns (uint256 used) {
        SwapParams memory p =
            SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        PoolSwapTest r = swapRouter;
        vm.cool(address(MANAGER));
        vm.cool(address(hook));
        vm.cool(address(r));
        vm.cool(address(tokenA));
        vm.cool(address(tokenB));
        uint256 g = gasleft();
        r.swap(k, p, ts, "");
        used = g - gasleft();
    }
}
