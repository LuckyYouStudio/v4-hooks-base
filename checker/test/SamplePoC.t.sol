// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {SampleRegistry} from "./SampleRegistry.sol";
import {CheckerRouter} from "../src/CheckerRouter.sol";
import {NoCallerCheckHook} from "../samples/S2_NoCallerCheck.sol";
import {SharedSlotGuardHook} from "../samples/S5_SharedSlotGuard.sol";

/// @notice Shows, without the checker, that the toy bugs the checker does NOT fully detect (S4, S5) and
///         the one whose money impact it does not show (S2) are real in the vulnerable sample and absent
///         in the fixed one. Local toys only: none of this is aimed at, or usable against, a deployed
///         contract.
contract SamplePoCTest is SampleRegistry {
    address internal constant MALLORY = address(0xBAD);

    function setUp() public {
        _baseSetUp();
    }

    function _anyKey(address hook) internal pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0x1111)), Currency.wrap(address(0x2222)), 3000, 60, IHooks(hook));
    }

    // --- S2 ---------------------------------------------------------------------------------------

    function test_S2_vulnerable_forgedCallbackPaysOut() public {
        NoCallerCheckHook hook = NoCallerCheckHook(_deploySample(2, false));
        rewardToken.mint(address(hook), 100e18);
        vm.startPrank(MALLORY);
        // no swap, no PoolManager: just the callback, with a made-up size and a made-up trader
        hook.beforeSwap(MALLORY, _anyKey(address(hook)), SwapParams(true, -100_000e18, 0), abi.encode(MALLORY));
        hook.claim();
        vm.stopPrank();
        assertEq(rewardToken.balanceOf(MALLORY), 100e18, "the whole reward reserve");
        assertEq(rewardToken.balanceOf(address(hook)), 0);
    }

    function test_S2_fixed_forgedCallbackReverts() public {
        NoCallerCheckHook hook = NoCallerCheckHook(_deploySample(2, true));
        rewardToken.mint(address(hook), 100e18);
        vm.prank(MALLORY);
        vm.expectRevert(bytes4(keccak256("NotPoolManager()")));
        hook.beforeSwap(MALLORY, _anyKey(address(hook)), SwapParams(true, -100_000e18, 0), abi.encode(MALLORY));
    }

    // --- S4 ---------------------------------------------------------------------------------------

    /// @dev same pool shape, same 0->1 exactOut swap; returns the fee the hook kept, in token0
    function _feeKeptOnExactOut(address hook) internal returns (uint256 kept, uint256 poolIn) {
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (MockERC20 t0, MockERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);
        CheckerRouter router = new CheckerRouter(manager);
        t0.mint(address(router), 1e30);
        t1.mint(address(router), 1e30);
        PoolKey memory key = PoolKey(Currency.wrap(address(t0)), Currency.wrap(address(t1)), 3000, 60, IHooks(hook));
        router.initialize(key, TickMath.getSqrtPriceAtTick(INIT_TICK)); // price ~2 token1 per token0
        router.modifyLiquidity(key, ModifyLiquidityParams(-60_000, 60_000, 1e24, 0), "");
        uint256 before = t0.balanceOf(address(manager));
        // exactOut 0->1: the unspecified currency, the one the fee is charged in, is token0 (the input)
        router.swap(key, SwapParams(true, 1e18, TickMath.MIN_SQRT_PRICE + 1), "");
        kept = t0.balanceOf(hook);
        poolIn = t0.balanceOf(address(manager)) - before;
    }

    function test_S4_vulnerableTakesTwiceTheDesignFee_atPrice2() public {
        (uint256 keptBad, uint256 inBad) = _feeKeptOnExactOut(_deploySample(4, false));
        (uint256 keptGood, uint256 inGood) = _feeKeptOnExactOut(_deploySample(4, true));
        // design: 0.10% of the token0 input (about 0.5 token0 for 1 token1 out at price 2)
        assertApproxEqRel(keptGood, inGood / 1000, 0.01e18, "fixed: 0.10% of the input");
        // bug: 0.10% of the token1 OUTPUT amount (1e18), charged in token0
        assertEq(keptBad, 1e18 / 1000, "vulnerable: sized from amount1");
        assertApproxEqRel(keptBad, 2 * keptGood, 0.01e18, "twice the design fee at price ~2");
        assertApproxEqRel(inBad, inGood, 0.01e18, "same swap");
    }

    // --- S5 ---------------------------------------------------------------------------------------

    function test_S5_vulnerable_bountyClaimedUntilEmpty() public {
        SharedSlotGuardHook hook = SharedSlotGuardHook(payable(_deploySample(5, false)));
        vm.deal(address(hook), 5 ether);
        vm.startPrank(MALLORY);
        for (uint256 i; i < 5; i++) {
            hook.claim(); // meant to work once
        }
        vm.expectRevert(bytes4(keccak256("TransferFailed()")));
        hook.claim();
        vm.stopPrank();
        assertEq(MALLORY.balance, 5 ether);
        assertEq(address(hook).balance, 0);
    }

    function test_S5_fixed_bountyPaidOnce() public {
        SharedSlotGuardHook hook = SharedSlotGuardHook(payable(_deploySample(5, true)));
        vm.deal(address(hook), 5 ether);
        vm.startPrank(MALLORY);
        hook.claim();
        vm.expectRevert(bytes4(keccak256("AlreadyPaid()")));
        hook.claim();
        vm.stopPrank();
        assertEq(MALLORY.balance, 1 ether);
        assertEq(address(hook).balance, 4 ether);
    }
}
