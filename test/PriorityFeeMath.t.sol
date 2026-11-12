// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PriorityFeeMath} from "../src/libraries/PriorityFeeMath.sol";

contract PriorityFeeMathHarness {
    function priorityFee(uint256 gasPrice, uint256 baseFee) external pure returns (uint256) {
        return PriorityFeeMath.priorityFee(gasPrice, baseFee);
    }

    function surcharge(uint256 tip) external pure returns (uint24) {
        return PriorityFeeMath.surcharge(tip);
    }

    function lpFee(uint256 tip) external pure returns (uint24) {
        return PriorityFeeMath.lpFee(tip);
    }
}

/// @notice Unit + fuzz tests of the fee schedule. Expected values are hard-coded from the design note,
///         not derived from the library's constants.
contract PriorityFeeMathTest is Test {
    PriorityFeeMathHarness internal m;

    function setUp() public {
        m = new PriorityFeeMathHarness();
    }

    function test_constants_areTheDocumentedOnes() public pure {
        assertEq(PriorityFeeMath.MIN_FEE, 500);
        assertEq(PriorityFeeMath.MAX_FEE, 3000);
        assertEq(PriorityFeeMath.TIP_ALLOWANCE, 20_000_000);
        assertEq(PriorityFeeMath.WEI_PER_PIP, 400_000);
    }

    function test_priorityFee_saturates() public view {
        assertEq(m.priorityFee(0, 0), 0, "eth_call without fee fields: a Base node reports (0, 0)");
        assertEq(m.priorityFee(0, 5_000_000), 0, "deposit tx (gas price 0)");
        assertEq(m.priorityFee(1, 5_000_000), 0, "eth_call with an explicit gasPrice below the base fee");
        assertEq(m.priorityFee(4_999_999, 5_000_000), 0);
        assertEq(m.priorityFee(5_000_000, 5_000_000), 0);
        assertEq(m.priorityFee(5_000_001, 5_000_000), 1);
        assertEq(m.priorityFee(type(uint256).max, 0), type(uint256).max);
        assertEq(m.priorityFee(0, type(uint256).max), 0);
        assertEq(m.priorityFee(type(uint256).max, type(uint256).max), 0);
    }

    function test_lpFee_table() public view {
        // free band
        assertEq(m.lpFee(0), 500);
        assertEq(m.lpFee(1_000_000), 500, "node suggestion");
        assertEq(m.lpFee(1_500_000), 500, "Universal Router median");
        assertEq(m.lpFee(15_000_000), 500, "Universal Router p99");
        assertEq(m.lpFee(20_000_000), 500, "exactly the allowance");
        assertEq(m.lpFee(20_399_999), 500, "one wei short of the first pip");
        // linear part
        assertEq(m.lpFee(20_400_000), 501);
        assertEq(m.lpFee(20_799_999), 501);
        assertEq(m.lpFee(20_800_000), 502);
        assertEq(m.lpFee(30_000_000), 525, "block-first median (0.03 gwei)");
        assertEq(m.lpFee(50_000_000), 575);
        assertEq(m.lpFee(100_000_000), 700, "0.1 gwei");
        assertEq(m.lpFee(500_000_000), 1700);
        assertEq(m.lpFee(1_000_000_000), 2950, "1 gwei");
        // cap
        assertEq(m.lpFee(1_019_599_999), 2998);
        assertEq(m.lpFee(1_019_600_000), 2999);
        assertEq(m.lpFee(1_019_999_999), 2999, "one wei short of the cap");
        assertEq(m.lpFee(1_020_000_000), 3000, "cap reached at 1.02 gwei");
        assertEq(m.lpFee(1_020_400_000), 3000);
        assertEq(m.lpFee(16_100_000_000), 3000, "16.1 gwei, the largest tip in the researcher's examples");
        assertEq(m.lpFee(type(uint256).max), 3000);
    }

    function test_surcharge_isLpFeeMinusFloor() public view {
        assertEq(m.surcharge(0), 0);
        assertEq(m.surcharge(20_000_000), 0);
        assertEq(m.surcharge(20_400_000), 1);
        assertEq(m.surcharge(type(uint256).max), 2500);
    }

    function testFuzz_lpFee_boundsAndClosedForm(uint256 tip) public view {
        uint24 fee = m.lpFee(tip);
        assertGe(fee, 500);
        assertLe(fee, 3000);
        assertEq(fee, 500 + m.surcharge(tip));
        // independent closed form
        uint256 expected = 500;
        if (tip > 20_000_000) {
            uint256 extra = (tip - 20_000_000) / 400_000;
            expected += extra > 2500 ? 2500 : extra;
        }
        assertEq(fee, expected);
    }

    /// @dev interesting inputs are below ~1.1 gwei; the unbounded fuzz above almost never lands there
    function testFuzz_lpFee_closedForm_inTheLinearRange(uint256 tip) public view {
        tip = bound(tip, 0, 1_100_000_000);
        uint256 expected = 500;
        if (tip > 20_000_000) {
            uint256 extra = (tip - 20_000_000) / 400_000;
            expected += extra > 2500 ? 2500 : extra;
        }
        assertEq(m.lpFee(tip), expected);
    }

    function testFuzz_lpFee_monotoneInTip(uint256 a, uint256 b) public view {
        if (a > b) (a, b) = (b, a);
        assertLe(m.lpFee(a), m.lpFee(b));
    }

    function testFuzz_lpFee_monotoneInTip_linearRange(uint256 a, uint256 d) public view {
        a = bound(a, 0, 1_100_000_000);
        d = bound(d, 0, 1_100_000_000);
        assertLe(m.lpFee(a), m.lpFee(a + d));
        // one more pip costs exactly WEI_PER_PIP more tip (until the cap)
        if (a >= 20_000_000 && m.lpFee(a) < 3000) assertEq(m.lpFee(a + 400_000), m.lpFee(a) + 1);
    }

    /// @dev any (gasPrice, baseFee): no revert, in bounds, non-decreasing in gasPrice, non-increasing in baseFee
    function testFuzz_fee_anyGasPriceAndBaseFee(uint256 gasPrice, uint256 baseFee, uint256 d) public view {
        uint24 fee = m.lpFee(m.priorityFee(gasPrice, baseFee));
        assertGe(fee, 500);
        assertLe(fee, 3000);
        if (gasPrice <= baseFee) assertEq(fee, 500);
        d = bound(d, 0, type(uint256).max - gasPrice);
        assertGe(m.lpFee(m.priorityFee(gasPrice + d, baseFee)), fee, "more gas price never lowers the fee");
        d = bound(d, 0, type(uint256).max - baseFee);
        assertLe(m.lpFee(m.priorityFee(gasPrice, baseFee + d)), fee, "more base fee never raises the fee");
    }

    function testFuzz_fee_anyGasPriceAndBaseFee_realisticRange(uint256 baseFee, uint256 tip, uint256 d) public view {
        baseFee = bound(baseFee, 0, 100 gwei);
        tip = bound(tip, 0, 2 gwei);
        d = bound(d, 0, 2 gwei);
        uint24 fee = m.lpFee(m.priorityFee(baseFee + tip, baseFee));
        assertEq(fee, m.lpFee(tip), "only the difference matters");
        assertGe(m.lpFee(m.priorityFee(baseFee + tip + d, baseFee)), fee);
        assertLe(m.lpFee(m.priorityFee(baseFee + tip, baseFee + d)), fee);
    }
}
