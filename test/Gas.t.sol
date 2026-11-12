// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {HookTestBase} from "./utils/HookTestBase.sol";

/// @notice Gas the hook adds to one swap: identical swap on (a) a hookless static-fee pool and
///         (b) the hooked dynamic-fee pool, same tokens' behaviour, same liquidity, same price, same fee.
/// @dev Every measured call starts with all touched accounts cold (vm.cool), as in a fresh transaction.
///      Numbers are for the v4-core test router (PoolSwapTest), which is the same on both sides, so the
///      difference isolates the hook. Run with -vv to print.
contract GasTest is HookTestBase {
    PoolKey internal staticKey;
    PoolKey internal dynKey;

    function setUp() public {
        _baseSetUp();
        (Currency a, Currency b) = deployMintAndApprove2Currencies();
        (dynKey,) = _initDynamicPool(a, b, SQRT_PRICE_1_1);
        _addWideLiquidity(dynKey);
        _arm(dynKey);
        staticKey = PoolKey(a, b, MIN_FEE, SPACING, IHooks(address(0)));
        manager.initialize(staticKey, SQRT_PRICE_1_1);
        _addWideLiquidity(staticKey);
        // one swap each so that fee-growth slots etc. are already non-zero on both pools
        swap(dynKey, true, -1e18, ZERO_BYTES);
        swap(staticKey, true, -1e18, ZERO_BYTES);
        // ... in BOTH directions (arming already swapped 1->0 on the hooked pool; without this the static
        // pool's first 1->0 swap pays a zero->non-zero SSTORE and the comparison is off by 17k)
        swap(dynKey, false, -1e18, ZERO_BYTES);
        swap(staticKey, false, -1e18, ZERO_BYTES);
        _nextBlock(BUCKET);
    }

    function _coolAll(PoolKey memory k) internal {
        vm.cool(address(manager));
        vm.cool(address(hook));
        vm.cool(address(swapRouter));
        vm.cool(Currency.unwrap(k.currency0));
        vm.cool(Currency.unwrap(k.currency1));
    }

    uint256 internal lastFrame;

    /// @dev gas of the router call as seen by the caller (gasleft difference). Arguments are built in
    ///      memory first; what remains outside the call (calldata encoding) is identical for both pools.
    ///      vm.lastFrameGas() (callee-side frame gas) is recorded too, as a second method.
    function _measure(PoolKey memory k, bool zeroForOne, int256 amount) internal returns (uint256 used) {
        SwapParams memory p = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amount,
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });
        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        bytes memory noData = ZERO_BYTES;
        PoolSwapTest router = swapRouter;
        _coolAll(k);
        uint256 g = gasleft();
        router.swap(k, p, ts, noData);
        used = g - gasleft();
        lastFrame = vm.lastFrameGas().gasTotalUsed;
    }

    function test_gas_swapOverhead() public {
        // exact-in 0->1
        uint256 base = _measure(staticKey, true, -1e18);
        uint256 baseFrame = lastFrame;
        uint256 first = _measure(dynKey, true, -1e18); // first swap of the bucket: log price + volatility update + SSTORE + event
        assertApproxEqAbs(first - base, lastFrame - baseFrame, 50, "two measuring methods agree on the overhead");
        uint256 later = _measure(dynKey, true, -1e18); // same bucket: cached fee, one SLOAD
        uint256 baseLater = _measure(staticKey, true, -1e18);

        console2.log("swap, no hook (static 0.05% pool)        :", base);
        console2.log("swap, hook, first swap of bucket (update):", first);
        console2.log("swap, hook, later swap in same bucket    :", later);
        console2.log("overhead, first swap of bucket           :", first - base);
        console2.log("overhead, later swap in bucket           :", later - baseLater);

        // regression guards (loose): the update path is one SLOAD + extsload + TickMath (one
        // getTickAtSqrtPrice, two getSqrtPriceAtTick) + one SSTORE + one LOG
        assertLt(first - base, 30_000);
        assertLt(later - baseLater, 12_000);
        assertGt(first, later);
    }

    /// @dev a new block inside the same bucket is NOT an update any more (before the bucket change it was)
    function test_gas_swapOverhead_newBlockSameBucket_isCachedPath() public {
        // like for like: both pools have already been swapped on once in this transaction (the first
        // write to a storage slot in a transaction costs more than later ones, hook or no hook)
        _measure(staticKey, true, -1e18);
        _measure(dynKey, true, -1e18); // the bucket's update
        _nextBlock(1);
        uint256 base = _measure(staticKey, true, -1e18);
        uint256 later = _measure(dynKey, true, -1e18);
        console2.log("overhead, first swap of a later block in the same bucket:", later - base);
        assertLt(later - base, 12_000);
    }

    function test_gas_swapOverhead_exactOut_otherDirection() public {
        uint256 base = _measure(staticKey, false, 1e18);
        uint256 first = _measure(dynKey, false, 1e18);
        uint256 later = _measure(dynKey, false, 1e18);
        uint256 baseLater = _measure(staticKey, false, 1e18);
        console2.log("1->0 exact-out overhead, first swap of bucket:", first - base);
        console2.log("1->0 exact-out overhead, later swap in bucket:", later - baseLater);
        assertLt(first - base, 30_000);
        assertLt(later - baseLater, 12_000);
    }
}
