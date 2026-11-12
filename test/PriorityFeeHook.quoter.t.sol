// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {V4Quoter} from "v4-periphery/src/lens/V4Quoter.sol";
import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";

import {PriorityFeeTestBase} from "./utils/PriorityFeeTestBase.sol";
import {CheckedSwapRouter} from "./utils/CheckedSwapRouter.sol";

/// @notice Quote vs execution (docs/PriorityFeeHook.md section 8c). Uniswap's V4Quoter (pinned v4-periphery
///         source, deployed locally) runs the real swap, hook included, and reverts with the result. The
///         hook therefore prices the quote by the gas price of the QUOTING call. On a Base node an eth_call
///         without fee fields makes the contract read (GASPRICE, BASEFEE) = (0, 0), and one with only
///         maxFeePerGas reads GASPRICE == BASEFEE (engineer's probe and the auditor's independent probe,
///         audits/audit-hooks-h2.md section 3). Either way the priority fee is 0 and the quote is always
///         at MIN_FEE; the later transaction pays by its real tip.
/// @dev vm.txGasPrice(0) + vm.fee(0) models the eth_call without fee fields. Run with -vv to print the
///      differences.
contract PriorityFeeHookQuoterTest is PriorityFeeTestBase {
    V4Quoter internal quoter;
    CheckedSwapRouter internal checked;

    function setUp() public {
        _baseSetUp();
        quoter = new V4Quoter(manager);
        checked = new CheckedSwapRouter(manager);
        MockERC20(Currency.unwrap(currency0)).approve(address(checked), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(checked), type(uint256).max);
    }

    function _params(bool zeroForOne, uint128 amount) internal view returns (IV4Quoter.QuoteExactSingleParams memory) {
        return IV4Quoter.QuoteExactSingleParams({
            poolKey: hookKey,
            zeroForOne: zeroForOne,
            exactAmount: amount,
            hookData: ""
        });
    }

    /// @dev (GASPRICE, BASEFEE) = (0, 0): what a Base node reports to a call without fee fields
    function _asEthCallWithoutFeeFields() internal {
        _setGas(0, 0);
    }

    /// @dev only maxFeePerGas given: the node reports GASPRICE == BASEFEE (no tip)
    function _asEthCallWithOnlyMaxFee() internal {
        _setGas(BASEFEE, BASEFEE);
    }

    /// @dev FACT: the three "no usable fee field" shapes of a quoting call all quote at the floor and give
    ///      the same number: (0, 0) no fee fields; (basefee, basefee) only maxFeePerGas; (1, basefee) an
    ///      explicit gasPrice below the base fee.
    function test_fact_quote_withoutTipField_isAlwaysAtTheFloor() public {
        _asEthCallWithoutFeeFields();
        assertEq(hook.currentFee(), 500);
        (uint256 a,) = quoter.quoteExactInputSingle(_params(true, 1e18));
        _asEthCallWithOnlyMaxFee();
        assertEq(hook.currentFee(), 500);
        (uint256 b,) = quoter.quoteExactInputSingle(_params(true, 1e18));
        _setGas(1, BASEFEE);
        assertEq(hook.currentFee(), 500);
        (uint256 c,) = quoter.quoteExactInputSingle(_params(true, 1e18));
        assertEq(a, 999_499_001_000_748_499, "the floor-fee quote of the design note");
        assertEq(b, a);
        assertEq(c, a);
    }

    /// @dev sanity: at an ordinary tip, quote == execution, to the wei, for all four swap kinds
    function test_quote_matchesExecution_whenTipIsWithinAllowance() public {
        bool[2] memory dirs = [true, false];
        for (uint256 i; i < 2; i++) {
            _asEthCallWithoutFeeFields();
            (uint256 quotedOut,) = quoter.quoteExactInputSingle(_params(dirs[i], 1e18));
            (uint256 quotedIn,) = quoter.quoteExactOutputSingle(_params(dirs[i], 1e18));
            uint256 snap = vm.snapshotState();
            _setTip(2_000_000); // most common Universal Router tip in the researcher's sample
            assertEq(checked.swapExactIn(hookKey, dirs[i], 1e18, 0), quotedOut);
            vm.revertToState(snap);
            _setTip(20_000_000); // exactly the allowance
            assertEq(checked.swapExactOut(hookKey, dirs[i], 1e18, type(uint256).max), quotedIn);
            vm.revertToState(snap);
        }
    }

    /// @dev FACT: the quote has no surcharge, the execution has. Exact-in: less out than quoted.
    function test_fact_quoteHasNoSurcharge_exactIn() public {
        _asEthCallWithoutFeeFields();
        (uint256 quotedOut,) = quoter.quoteExactInputSingle(_params(true, 1e18));
        uint256[4] memory tips = [uint256(30_000_000), 100_000_000, 500_000_000, TIP_AT_CAP];
        uint256[4] memory expectedPpm = [uint256(25), 200, 1200, 2501];
        console2.log("exact-in 1e18: quoted out (eth_call, no fee fields):", quotedOut);
        for (uint256 i; i < tips.length; i++) {
            uint256 snap = vm.snapshotState();
            _setTip(tips[i]);
            uint256 out = checked.swapExactIn(hookKey, true, 1e18, 0);
            vm.revertToState(snap);
            uint256 ppm = (quotedOut - out) * 1e6 / quotedOut;
            console2.log("  tip (wei/gas) / executed out / shortfall (ppm of quote):");
            console2.log("   ", tips[i], out, ppm);
            assertLt(out, quotedOut);
            assertApproxEqAbs(ppm, expectedPpm[i], 1);
        }
    }

    /// @dev FACT: exact-out needs more input than quoted; a router holding the user to
    ///      maxIn = quote * (1 + tolerance) reverts when the tolerance is smaller than the surcharge.
    function test_fact_quoteHasNoSurcharge_exactOut_canExceedMaximumInput() public {
        _asEthCallWithoutFeeFields();
        (uint256 quotedIn,) = quoter.quoteExactOutputSingle(_params(true, 1e18));

        uint256 snap = vm.snapshotState();
        _setTip(TIP_AT_CAP);
        uint256 paid = checked.swapExactOut(hookKey, true, 1e18, type(uint256).max);
        vm.revertToState(snap);
        uint256 ppm = (paid - quotedIn) * 1e6 / quotedIn;
        console2.log("exact-out 1e18: quoted in / executed in at the cap / excess (ppm):", quotedIn, paid, ppm);
        assertApproxEqAbs(ppm, 2507, 1, "(1 - 0.0005) / (1 - 0.003) - 1 = 0.2508%");

        _setTip(TIP_AT_CAP);
        // 0.1% tolerance: reverts
        uint256 maxIn = quotedIn * 1001 / 1000;
        vm.expectRevert(abi.encodeWithSelector(CheckedSwapRouter.TooMuchRequested.selector, maxIn, paid));
        checked.swapExactOut(hookKey, true, 1e18, maxIn);
        // 0.25% tolerance: still reverts (the worst case is 0.2508%)
        maxIn = quotedIn * 10025 / 10000;
        vm.expectRevert(abi.encodeWithSelector(CheckedSwapRouter.TooMuchRequested.selector, maxIn, paid));
        checked.swapExactOut(hookKey, true, 1e18, maxIn);
        // 0.5% tolerance: fills
        assertEq(checked.swapExactOut(hookKey, true, 1e18, quotedIn * 1005 / 1000), paid);
    }

    /// @dev same for exact-in with a minimum out derived from the quote
    function test_fact_quoteHasNoSurcharge_exactIn_minimumOutCanFail() public {
        _asEthCallWithoutFeeFields();
        (uint256 quotedOut,) = quoter.quoteExactInputSingle(_params(false, 1e18));
        _setTip(TIP_AT_CAP);
        vm.expectRevert();
        checked.swapExactIn(hookKey, false, 1e18, quotedOut * 999 / 1000);
        uint256 out = checked.swapExactIn(hookKey, false, 1e18, quotedOut * 995 / 1000);
        assertLt(out, quotedOut);
    }

    /// @dev What an integrator can do: (a) make the quoting eth_call with the same fee fields the
    ///      transaction will use - then the Quoter's answer is exact; (b) ask the hook for the fee of a
    ///      given priority fee and price the swap off-chain.
    function test_quote_withTheTransactionsFeeFields_isExact() public {
        uint256[3] memory tips = [uint256(100_000_000), 500_000_000, TIP_AT_CAP];
        for (uint256 i; i < tips.length; i++) {
            _setTip(tips[i]);
            (uint256 quotedOut,) = quoter.quoteExactInputSingle(_params(true, 1e18));
            (uint256 quotedIn,) = quoter.quoteExactOutputSingle(_params(false, 1e18));
            uint256 snap = vm.snapshotState();
            assertEq(checked.swapExactIn(hookKey, true, 1e18, quotedOut), quotedOut);
            vm.revertToState(snap);
            assertEq(checked.swapExactOut(hookKey, false, 1e18, quotedIn), quotedIn);
            vm.revertToState(snap);
            assertEq(hook.currentFee(), hook.feeForPriorityFee(tips[i]));
        }
        _asEthCallWithoutFeeFields();
        assertEq(hook.currentFee(), 500, "currentFee() in a plain eth_call is the floor");
        assertEq(hook.feeForPriorityFee(TIP_AT_CAP), 3000, "feeForPriorityFee does not depend on the call context");
    }

    /// @dev the quote itself must not revert when gas price < base fee (an unguarded
    ///      `tx.gasprice - block.basefee` reverts here; see docs/research/base-priority-ordering-for-hooks.md 2.6)
    function testFuzz_quote_neverRevertsBelowBaseFee(uint64 gasPrice, uint64 baseFee, bool zeroForOne) public {
        _setGas(gasPrice, baseFee);
        (uint256 out,) = quoter.quoteExactInputSingle(_params(zeroForOne, 1e18));
        assertGt(out, 0);
    }
}
