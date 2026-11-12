// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PriorityFeeMath} from "../src/libraries/PriorityFeeMath.sol";

/// @notice Read-only probe, never deployed: its INIT CODE is sent as the data of an eth_call without a
///         `to` address, and the "constructor" returns (tx.gasprice, block.basefee, lpFee) computed with
///         the same library calls PriorityFeeHook._beforeSwap makes. It shows what a real node reports
///         for GASPRICE / BASEFEE to a contract and what the hook would charge. See
///         script/probe-priority-fee.sh.
contract PriorityFeeProbe {
    constructor() {
        uint256 gasPrice = tx.gasprice;
        uint256 baseFee = block.basefee;
        uint24 fee = PriorityFeeMath.lpFee(PriorityFeeMath.priorityFee(gasPrice, baseFee));
        bytes memory out = abi.encode(gasPrice, baseFee, fee);
        assembly ("memory-safe") {
            return(add(out, 32), mload(out))
        }
    }
}
