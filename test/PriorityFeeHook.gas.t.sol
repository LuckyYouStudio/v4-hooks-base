// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {PriorityFeeTestBase} from "./utils/PriorityFeeTestBase.sol";

/// @notice Gas PriorityFeeHook adds to one swap: the identical swap on (a) a hookless static-fee pool
///         and (b) the hooked dynamic-fee pool on the same tokens, same liquidity, same price, same fee.
/// @dev Same method as Gas.t.sol: every measured call starts with all touched accounts cold (vm.cool),
///      as in a fresh transaction; router is v4-core's PoolSwapTest on both sides, so the difference
///      isolates the hook. Run with -vv to print.
contract PriorityFeeHookGasTest is PriorityFeeTestBase {
    PoolKey internal staticFloor; // 0.05%, no hook
    PoolKey internal staticCap; // 0.30%, no hook
    PoolKey internal dynA; // hooked, compared with staticFloor
    PoolKey internal dynB; // hooked, compared with staticCap

    function setUp() public {
        _baseSetUp();
        (Currency a, Currency b) = deployMintAndApprove2Currencies();
        (dynA,) = _initDynamicPool(a, b, SQRT_PRICE_1_1);
        staticFloor = _initStaticPool(a, b, 500, SQRT_PRICE_1_1);
        (Currency c, Currency d) = deployMintAndApprove2Currencies();
        (dynB,) = _initDynamicPool(c, d, SQRT_PRICE_1_1);
        staticCap = _initStaticPool(c, d, 3000, SQRT_PRICE_1_1);
        PoolKey[4] memory all = [dynA, staticFloor, dynB, staticCap];
        for (uint256 i; i < 4; i++) {
            _addLiquidity(all[i], WIDE_LOWER, WIDE_UPPER, WIDE_LIQUIDITY, 0);
        }
        // one swap each way on every pool at its comparison fee, so fee-growth slots are non-zero
        // everywhere and both pools of a pair sit at the same price
        for (uint256 i; i < 4; i++) {
            _setTip(i >= 2 ? TIP_AT_CAP : 0);
            _swap(all[i], true, -1e18);
            _swap(all[i], false, -1e18);
        }
        assertEq(_sqrtPrice(dynA), _sqrtPrice(staticFloor));
        assertEq(_sqrtPrice(dynB), _sqrtPrice(staticCap));
    }

    function _measure(PoolKey memory k, bool zeroForOne, int256 amount) internal returns (uint256 used) {
        SwapParams memory p = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amount,
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });
        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        bytes memory noData = ZERO_BYTES;
        PoolSwapTest router = swapRouter;
        vm.cool(address(manager));
        vm.cool(address(hook));
        vm.cool(address(router));
        vm.cool(Currency.unwrap(k.currency0));
        vm.cool(Currency.unwrap(k.currency1));
        uint256 g = gasleft();
        router.swap(k, p, ts, noData);
        used = g - gasleft();
    }

    function test_gas_swapOverhead_atFloor() public {
        _setTip(1_000_000);
        uint256 base = _measure(staticFloor, true, -1e18);
        uint256 hooked = _measure(dynA, true, -1e18);
        uint256 baseOut = _measure(staticFloor, false, 1e18);
        uint256 hookedOut = _measure(dynA, false, 1e18);
        console2.log("swap 0->1 exact-in, no hook (static 0.05%):", base);
        console2.log("swap 0->1 exact-in, hook, tip in allowance:", hooked);
        console2.log("overhead                                  :", hooked - base);
        console2.log("overhead, 1->0 exact-out                  :", hookedOut - baseOut);
        // cold call to the hook (2600) + one cold SLOAD (2100) + ABI encoding / decoding of the PoolKey and
        // SwapParams + dispatch; the same on every swap (there is no "first swap" path). In the trace
        // (-vvvv) the hook's own frame is ~4.3k of it. A second swap on the pool inside the same
        // transaction would save the two cold accesses; that case is NOT measured here (in this Foundry
        // version every measured call is charged cold accesses whether or not vm.cool is used).
        assertLt(hooked - base, 9_000);
        assertLt(hookedOut - baseOut, 9_000);
    }

    function test_gas_swapOverhead_atCap() public {
        _setTip(TIP_AT_CAP);
        uint256 base = _measure(staticCap, true, -1e18);
        uint256 hooked = _measure(dynB, true, -1e18);
        uint256 baseOut = _measure(staticCap, false, 1e18);
        uint256 hookedOut = _measure(dynB, false, 1e18);
        console2.log("swap 0->1 exact-in, no hook (static 0.30%):", base);
        console2.log("swap 0->1 exact-in, hook, tip at the cap  :", hooked);
        console2.log("overhead                                  :", hooked - base);
        console2.log("overhead, 1->0 exact-out                  :", hookedOut - baseOut);
        assertLt(hooked - base, 9_000);
        assertLt(hookedOut - baseOut, 9_000);
    }
}
