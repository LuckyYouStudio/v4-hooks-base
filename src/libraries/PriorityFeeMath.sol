// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title PriorityFeeMath
/// @notice Pure fee schedule of PriorityFeeHook: LP fee as a function of the transaction's priority fee.
///
///   priorityFee = max(tx.gasprice - block.basefee, 0)                     (wei per gas, saturating)
///   surcharge   = min( floor( max(priorityFee - TIP_ALLOWANCE, 0) / WEI_PER_PIP ), MAX_FEE - MIN_FEE )
///   lpFee       = MIN_FEE + surcharge                                     (pips; 1 pip = 0.0001%)
///
/// @dev All four constants are UNBACKTESTED ENGINEERING STARTING POINTS (see docs/PriorityFeeHook.md).
///      There is no multiplication and no narrowing cast of an unbounded value anywhere, so nothing can
///      overflow for any uint256 input; every division rounds down (in the trader's favour).
library PriorityFeeMath {
    /// @notice LP fee of a swap whose transaction pays no more than TIP_ALLOWANCE of priority fee: 0.05%.
    uint24 internal constant MIN_FEE = 500;

    /// @notice Hard cap of the LP fee this schedule can return: 0.30%. The protocol fee (set by Uniswap's
    ///         protocol fee controller, at most 0.10% per direction) is charged on top of it.
    uint24 internal constant MAX_FEE = 3000;

    /// @notice Priority fee (wei per gas) that is free of surcharge: 0.02 gwei.
    uint256 internal constant TIP_ALLOWANCE = 20_000_000;

    /// @notice Priority fee above the allowance (wei per gas) that buys one more pip of LP fee.
    ///         1 pip per 0.0004 gwei, i.e. the cap is reached at 0.02 + 2500 * 0.0004 = 1.02 gwei.
    uint256 internal constant WEI_PER_PIP = 400_000;

    /// @notice The priority fee per gas a transaction pays: its effective gas price above the block's
    ///         base fee, 0 when the gas price is not above it. Cases where it is not: an eth_call /
    ///         eth_estimateGas without fee fields, or with only maxFeePerGas (on a Base node the contract
    ///         reads GASPRICE = BASEFEE = 0, resp. GASPRICE = BASEFEE: equal, not below); an eth_call with
    ///         an explicit gasPrice below the base fee; L1-originated deposit transactions (gas price 0).
    ///         Readings: docs/PriorityFeeHook.md section 8.
    function priorityFee(uint256 gasPrice, uint256 baseFee) internal pure returns (uint256) {
        unchecked {
            return gasPrice > baseFee ? gasPrice - baseFee : 0;
        }
    }

    /// @notice Pips added to MIN_FEE for a transaction paying `tip` wei per gas of priority fee.
    ///         0 up to and including TIP_ALLOWANCE, then linear, capped at MAX_FEE - MIN_FEE.
    function surcharge(uint256 tip) internal pure returns (uint24) {
        if (tip <= TIP_ALLOWANCE) return 0;
        uint256 pips;
        unchecked {
            pips = (tip - TIP_ALLOWANCE) / WEI_PER_PIP; // tip > TIP_ALLOWANCE; WEI_PER_PIP != 0
        }
        uint256 maxSurcharge = MAX_FEE - MIN_FEE;
        // the cast is applied to a value <= maxSurcharge < 2^24
        return uint24(pips < maxSurcharge ? pips : maxSurcharge);
    }

    /// @notice LP fee (pips) for a transaction paying `tip` wei per gas of priority fee. Always within
    ///         [MIN_FEE, MAX_FEE], non-decreasing in `tip`.
    function lpFee(uint256 tip) internal pure returns (uint24) {
        unchecked {
            return MIN_FEE + surcharge(tip); // <= MAX_FEE
        }
    }
}
