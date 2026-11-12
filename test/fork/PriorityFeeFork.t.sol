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
import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";

import {PriorityFeeHook} from "../../src/PriorityFeeHook.sol";

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

/// @notice PriorityFeeHook against the REAL Uniswap v4 PoolManager and the REAL V4Quoter on Base mainnet
///         (forked at a pinned block; nothing is sent to the network).
///
/// Addresses (docs/research/uniswap-v4-hooks-base.md section 1.1, from Uniswap's deployments page; each is
/// checked below to have code and, for the Quoter, to point at this PoolManager):
///   PoolManager 0x498581fF718922c3f8e6A244956aF099B2652b2b
///   V4Quoter    0xE1A6C5803e3c44368b171BD680c7D32dfc92CA47
///   USDC        0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 (6 decimals; symbol() read at the fork block)
///
/// Needs BASE_RPC_URL (e.g. https://mainnet.base.org). Without it every test here is skipped.
///
/// What is and is not real here: PoolManager, Quoter and USDC are the chain's contracts; the base fee is
/// the pinned block's header value (re-applied with vm.fee, see setUp). tx.gasprice is set with
/// vm.txGasPrice (a forge test has no real transaction envelope); the swap and liquidity routers are
/// v4-core's test routers deployed on the fork; the other tokens are mocks. Not used: Universal Router,
/// PositionManager, a real signed transaction.
contract PriorityFeeForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using Hooks for IHooks;

    IPoolManager internal constant MANAGER = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    IV4Quoter internal constant QUOTER = IV4Quoter(0xE1A6C5803e3c44368b171BD680c7D32dfc92CA47);
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    uint256 internal constant FORK_BLOCK = 56_228_000;
    /// @dev `cast block 56228000` -> baseFeePerGas 5000000 (Base's minimum base fee)
    uint256 internal constant FORK_BASEFEE = 5_000_000;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    int24 internal constant SPACING = 60;
    uint256 internal constant TIP_AT_CAP = 1_020_000_000;

    PriorityFeeHook internal hook;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liqRouter;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    PoolKey internal key; // mock/mock, hooked
    PoolId internal id;
    PoolKey internal ethKey; // native ETH/mock, hooked

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "BASE_RPC_URL not set");
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        assertEq(block.chainid, 8453, "not Base mainnet");
        assertGt(address(MANAGER).code.length, 20_000, "no PoolManager code at the documented address");

        // Foundry quirk (forge 1.9.0, found while writing this test): on a fork, `block.basefee` read in a
        // view context is the forked block's header value, but inside a state-changing call the BASEFEE
        // opcode returns 0 unless vm.fee() was called. Without the next line every swap below would see
        // base fee 0 and be charged for a tip 5,000,000 wei larger than it is. So the base fee the hook
        // reads in these tests is the header value RE-APPLIED BY CHEATCODE; that the real chain reports
        // GASPRICE / BASEFEE this way to a contract is checked separately with a read-only eth_call
        // against a Base node (script/probe-priority-fee.sh, results in docs/PriorityFeeHook.md).
        assertEq(block.basefee, FORK_BASEFEE, "base fee in the pinned block's header");
        vm.fee(FORK_BASEFEE);

        swapRouter = new PoolSwapTest(MANAGER);
        liqRouter = new PoolModifyLiquidityTest(MANAGER);

        (address expected, bytes32 salt) = HookMiner.find(
            address(this),
            uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG),
            type(PriorityFeeHook).creationCode,
            abi.encode(MANAGER)
        );
        hook = new PriorityFeeHook{salt: salt}(MANAGER);
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
        MANAGER.initialize(ethKey, SQRT_PRICE_1_1);
        liqRouter.modifyLiquidity{value: 2000 ether}(ethKey, ModifyLiquidityParams(-120_000, 120_000, 1e21, 0), "");
    }

    receive() external payable {}

    // ---- helpers ----

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

    function _swap(PoolKey memory k, bool zeroForOne, int256 amount) internal returns (BalanceDelta d, uint24 fee) {
        uint256 value;
        if (k.currency0.isAddressZero() && zeroForOne) value = amount < 0 ? uint256(-amount) : 500 ether;
        vm.recordLogs();
        d = swapRouter.swap{value: value}(
            k,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amount,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        fee = _fee();
    }

    /// @dev a tip on top of the fork block's REAL base fee
    function _setTip(uint256 tip) internal {
        vm.txGasPrice(block.basefee + tip);
    }

    function _quoteParams(PoolKey memory k, bool zeroForOne, uint128 amount)
        internal
        pure
        returns (IV4Quoter.QuoteExactSingleParams memory)
    {
        return IV4Quoter.QuoteExactSingleParams({poolKey: k, zeroForOne: zeroForOne, exactAmount: amount, hookData: ""});
    }

    // ---- tests ----

    function test_fork_environment_readings() public view {
        assertEq(block.number, FORK_BLOCK);
        // BASEFEE on the fork is the pinned block's header value, and it is Base's minimum
        assertEq(block.basefee, FORK_BASEFEE, "block.basefee read on the fork");
        // In this forge fork test GASPRICE reads 0 and BASEFEE is the pinned header value (re-set with
        // vm.fee in setUp), i.e. gas price BELOW the base fee. That is a property of the test harness, NOT
        // what a real node reports to an eth_call without fee fields: there the contract reads
        // (GASPRICE, BASEFEE) = (0, 0) (docs/PriorityFeeHook.md section 8, audits/audit-hooks-h2.md
        // section 3). Both readings give priority fee 0 and the floor fee.
        assertEq(tx.gasprice, 0);
        assertLt(tx.gasprice, block.basefee);
        assertEq(hook.currentFee(), 500, "saturating subtraction: floor, no revert");
        assertEq(address(hook.poolManager()), address(MANAGER));
        Hooks.validateHookPermissions(IHooks(address(hook)), hook.getHookPermissions());
        assertTrue(IHooks(address(hook)).isValidHookAddress(LPFeeLibrary.DYNAMIC_FEE_FLAG));
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, 0x1080);
    }

    function test_fork_initialize_registers_andSetsStoredFee_onRealManager() public view {
        assertTrue(hook.isRegistered(id));
        assertTrue(hook.isRegistered(ethKey.toId()));
        (uint160 p,, uint24 protocolFee, uint24 lpFee) = MANAGER.getSlot0(id);
        assertEq(p, SQRT_PRICE_1_1);
        assertEq(lpFee, 500, "updateDynamicLPFee from afterInitialize works on the real manager");
        // A newly created pool has protocol fee 0 on Base today (nothing sets it at initialization). The
        // total-fee assertion with a non-zero protocol fee is done below by impersonating the controller.
        assertEq(protocolFee, 0);
        assertTrue(MANAGER.protocolFeeController() != address(0));
    }

    function test_fork_staticFeePool_rejected_onRealManager() public {
        PoolKey memory k = key;
        k.fee = 3000;
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterInitialize.selector,
                abi.encodeWithSelector(PriorityFeeHook.NotDynamicFee.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        MANAGER.initialize(k, SQRT_PRICE_1_1);
    }

    /// @dev the surcharge follows tx.gasprice - block.basefee, with the fork's real base fee
    function test_fork_feeFollowsPriorityFee_onRealManager() public {
        uint256[9] memory tips =
            [uint256(0), 1_000_000, 20_000_000, 20_400_000, 30_000_000, 100_000_000, 1_019_999_999, TIP_AT_CAP, 16.1 gwei];
        uint24[9] memory fees = [uint24(500), 500, 500, 501, 525, 700, 2999, 3000, 3000];
        for (uint256 i; i < tips.length; i++) {
            _setTip(tips[i]);
            assertEq(tx.gasprice - block.basefee, tips[i]);
            (, uint24 fee) = _swap(key, i % 2 == 0, i % 3 == 0 ? int256(1e18) : -int256(1e18));
            assertEq(fee, fees[i]);
            assertEq(hook.currentFee(), fees[i]);
        }
        (,,, uint24 stored) = MANAGER.getSlot0(id);
        assertEq(stored, 500, "override is per swap");
    }

    /// @dev gas price below / equal to the real base fee
    function test_fork_gasPriceBelowBaseFee_onRealManager() public {
        uint256[3] memory gasPrices = [uint256(0), FORK_BASEFEE - 1, FORK_BASEFEE];
        for (uint256 i; i < 3; i++) {
            vm.txGasPrice(gasPrices[i]);
            (, uint24 fee) = _swap(key, true, -1e18);
            assertEq(fee, 500);
        }
    }

    /// @dev the hooked pool on the real manager gives exactly what a hookless static pool of the same fee gives
    function test_fork_sameAmountsAsStaticPool_onRealManager() public {
        PoolKey memory stat = PoolKey(key.currency0, key.currency1, 1700, SPACING, IHooks(address(0)));
        MANAGER.initialize(stat, SQRT_PRICE_1_1);
        liqRouter.modifyLiquidity(stat, ModifyLiquidityParams(-120_000, 120_000, 1e24, 0), "");
        bool[4] memory dirs = [true, false, true, false];
        int256[4] memory amounts = [int256(-3e18), -2e18, 1e18, 7e17];
        for (uint256 i; i < 4; i++) {
            _setTip(500_000_000); // -> 1700 pips
            (BalanceDelta a, uint24 fa) = _swap(key, dirs[i], amounts[i]);
            (BalanceDelta b, uint24 fb) = _swap(stat, dirs[i], amounts[i]);
            assertEq(fa, 1700);
            assertEq(fb, 1700);
            assertEq(BalanceDelta.unwrap(a), BalanceDelta.unwrap(b));
        }
    }

    /// @dev With a protocol fee set by Base's real protocol fee controller (IMPERSONATED on the fork;
    ///      the controller's own logic is not exercised): total = protocol + lp * (1 - protocol), per
    ///      direction, all four swap kinds, at the floor and at the cap.
    function test_fork_protocolFee_totalFee_onRealManager() public {
        vm.prank(MANAGER.protocolFeeController());
        MANAGER.setProtocolFee(key, (uint24(400) << 12) | 1000); // 0.10% for 0->1, 0.04% for 1->0
        uint24 fee;
        _setTip(TIP_AT_CAP);
        (, fee) = _swap(key, true, -1e18);
        assertEq(fee, 3997); // 1000 + 3000 - floor(1000 * 3000 / 1e6)
        (, fee) = _swap(key, false, -1e18);
        assertEq(fee, 3399); // 400 + 3000 - floor(400 * 3000 / 1e6)
        (, fee) = _swap(key, true, 1e18);
        assertEq(fee, 3997);
        (, fee) = _swap(key, false, 1e18);
        assertEq(fee, 3399);
        _setTip(0);
        (, fee) = _swap(key, true, -1e18);
        assertEq(fee, 1500); // 1000 + 500 - floor(1000 * 500 / 1e6)
        (, fee) = _swap(key, false, 1e18);
        assertEq(fee, 900); // 400 + 500 - floor(400 * 500 / 1e6)
    }

    function test_fork_nativeEthPool_onRealManager() public {
        uint24 fee;
        _setTip(100_000_000);
        (, fee) = _swap(ethKey, true, -1 ether);
        assertEq(fee, 700);
        (, fee) = _swap(ethKey, false, -1e18);
        assertEq(fee, 700);
        (, fee) = _swap(ethKey, true, 1e18);
        assertEq(fee, 700);
        (, fee) = _swap(ethKey, false, 0.5 ether);
        assertEq(fee, 700);
        assertEq(address(hook).balance, 0);
    }

    /// @dev native ETH against the REAL USDC contract (6 decimals, proxy). Balances are created with
    ///      forge's `deal`; the pool is ours, created on the fork.
    function test_fork_ethUsdcPool_realUsdc_onRealManager() public {
        assertEq(IERC20Like(USDC).decimals(), 6);
        deal(USDC, address(this), 10_000_000e6);
        IERC20Like(USDC).approve(address(swapRouter), type(uint256).max);
        IERC20Like(USDC).approve(address(liqRouter), type(uint256).max);
        PoolKey memory k = PoolKey(
            CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(USDC), LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, IHooks(address(hook))
        );
        // 1 ETH = 3000 USDC -> price (USDC units per wei) = 3000e6 / 1e18; tick ~ -196256
        int24 tick = -196_260;
        MANAGER.initialize(k, TickMath.getSqrtPriceAtTick(tick));
        liqRouter.modifyLiquidity{value: 500 ether}(k, ModifyLiquidityParams(tick - 6000, tick + 6000, 1e17, 0), "");

        _setTip(TIP_AT_CAP);
        uint256 usdcBefore = IERC20Like(USDC).balanceOf(address(this));
        (BalanceDelta d, uint24 fee) = _swap(k, true, -1 ether); // sell 1 ETH
        assertEq(fee, 3000);
        assertEq(d.amount0(), -1 ether);
        uint256 got = IERC20Like(USDC).balanceOf(address(this)) - usdcBefore;
        assertEq(got, uint256(uint128(d.amount1())), "USDC received equals the delta (no transfer fee)");
        assertGt(got, 2900e6);
        assertLt(got, 3000e6);
        _setTip(0);
        (, fee) = _swap(k, false, -100e6); // buy ETH with 100 USDC
        assertEq(fee, 500);
        assertEq(IERC20Like(USDC).balanceOf(address(hook)), 0);
    }

    /// @dev The REAL deployed V4Quoter: its quote is at the floor when the quoting call has no fee fields
    ///      (gas price 0 here, as in a plain eth_call), the execution is not.
    function test_fork_realQuoter_quoteHasNoSurcharge() public {
        assertGt(address(QUOTER).code.length, 0, "no Quoter code");
        (bool ok, bytes memory ret) = address(QUOTER).staticcall(abi.encodeWithSignature("poolManager()"));
        assertTrue(ok);
        assertEq(abi.decode(ret, (address)), address(MANAGER), "Quoter points at this PoolManager");

        assertEq(tx.gasprice, 0);
        _realQuoterVsExecution(true);
    }

    /// @dev T-6 (audit round 1): the same against the real Quoter in the other direction
    function test_fork_realQuoter_quoteHasNoSurcharge_oneForZero() public {
        assertEq(tx.gasprice, 0);
        _realQuoterVsExecution(false);
    }

    function _realQuoterVsExecution(bool zeroForOne) internal {
        (uint256 quotedOut,) = QUOTER.quoteExactInputSingle(_quoteParams(key, zeroForOne, 1e18));
        (uint256 quotedIn,) = QUOTER.quoteExactOutputSingle(_quoteParams(key, zeroForOne, 1e18));

        uint256 snap = vm.snapshotState();
        _setTip(2_000_000);
        (BalanceDelta d,) = _swap(key, zeroForOne, -1e18);
        assertEq(_received(d, zeroForOne), quotedOut, "ordinary tip: executes exactly as quoted");
        vm.revertToState(snap);
        _setTip(20_000_000);
        (d,) = _swap(key, zeroForOne, 1e18);
        assertEq(_paid(d, zeroForOne), quotedIn, "tip at the allowance: exact-out executes exactly as quoted");
        vm.revertToState(snap);

        _setTip(TIP_AT_CAP);
        (d,) = _swap(key, zeroForOne, -1e18);
        uint256 out = _received(d, zeroForOne);
        vm.revertToState(snap);
        _setTip(TIP_AT_CAP);
        (d,) = _swap(key, zeroForOne, 1e18);
        uint256 paid = _paid(d, zeroForOne);
        vm.revertToState(snap);

        console2.log("real Quoter, zeroForOne:", zeroForOne);
        console2.log("  exact-in 1e18 : quoted out / executed out at the cap:", quotedOut, out);
        console2.log("  exact-out 1e18: quoted in  / executed in  at the cap:", quotedIn, paid);
        assertEq((quotedOut - out) * 1e6 / quotedOut, 2501);
        assertEq((paid - quotedIn) * 1e6 / quotedIn, 2507);

        // quoting WITH the fee fields of the transaction gives the executed amounts
        _setTip(TIP_AT_CAP);
        (uint256 quotedOutWithFees,) = QUOTER.quoteExactInputSingle(_quoteParams(key, zeroForOne, 1e18));
        assertEq(quotedOutWithFees, out);
        (uint256 quotedInWithFees,) = QUOTER.quoteExactOutputSingle(_quoteParams(key, zeroForOne, 1e18));
        assertEq(quotedInWithFees, paid);
    }

    function _received(BalanceDelta d, bool zeroForOne) internal pure returns (uint256) {
        return uint256(uint128(zeroForOne ? d.amount1() : d.amount0()));
    }

    function _paid(BalanceDelta d, bool zeroForOne) internal pure returns (uint256) {
        return uint256(uint128(-(zeroForOne ? d.amount0() : d.amount1())));
    }

    /// @dev liquidity can always be withdrawn on the real manager, at any gas price
    function test_fork_removeLiquidity_neverBlocked_onRealManager() public {
        _setTip(TIP_AT_CAP);
        _swap(key, true, -1e18);
        vm.txGasPrice(0);
        liqRouter.modifyLiquidity(key, ModifyLiquidityParams(-120_000, 120_000, -5e23, 0), "");
        vm.txGasPrice(type(uint64).max);
        liqRouter.modifyLiquidity(key, ModifyLiquidityParams(-120_000, 120_000, -5e23, 0), "");
        assertEq(MANAGER.getLiquidity(id), 0);
        assertEq(tokenA.balanceOf(address(hook)) + tokenB.balanceOf(address(hook)), 0);
    }

    function test_fork_gas_swapOverhead_onRealManager() public {
        PoolKey memory stat = PoolKey(key.currency0, key.currency1, 500, SPACING, IHooks(address(0)));
        MANAGER.initialize(stat, SQRT_PRICE_1_1);
        liqRouter.modifyLiquidity(stat, ModifyLiquidityParams(-120_000, 120_000, 1e24, 0), "");
        _setTip(1_000_000);
        _swap(key, true, -1e18);
        _swap(stat, true, -1e18);
        _swap(key, false, -1e18);
        _swap(stat, false, -1e18);
        uint256 base = _gas(stat);
        uint256 hooked = _gas(key);
        console2.log("fork: swap gas, no hook / hook / overhead:", base, hooked, hooked - base);
        assertLt(hooked - base, 9_000);
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
