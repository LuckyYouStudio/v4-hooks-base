// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ╔══════════════════════════════════════════════════════════════════════════════════════════════╗
// ║  故意有漏洞,禁止部署 —— INTENTIONALLY VULNERABLE, DO NOT DEPLOY.                             ║
// ║  Minimal model for testing the hook checker locally. Not a usable hook, not a template.      ║
// ╚══════════════════════════════════════════════════════════════════════════════════════════════╝
//
// Pattern (a class of bug: a reentrancy lock and a bookkeeping value sharing one storage slot. This is
// an abstract model of the class, written from its one-sentence description; it is not modelled on any
// particular contract or incident): two pieces of code that each pick a "private" hard-coded storage
// slot pick the same one. Leaving the lock writes NOT_ENTERED over the bookkeeping value, so the bookkeeping forgets that
// the payout already happened and the payout can be taken again and again.
//
// The toy: a hook holding an ETH bounty that is meant to be paid once.
//
// Expected checker result: NOT DETECTED. claim() is not a hook callback and the checker has no generic
// way to know what a non-callback function should do. Only h (the hook holds ETH) points at it. See
// README, "漏报".

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "../../src/base/BaseHook.sol";

abstract contract BountyBase is BaseHook {
    uint256 public constant BOUNTY = 1 ether;

    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;
    uint256 private constant PAID = 3;

    error Reentrancy();
    error AlreadyPaid();
    error TransferFailed();

    constructor(IPoolManager m) BaseHook(m) {}

    receive() external payable {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeSwap = true;
    }

    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev slot of the reentrancy lock
    function _guardSlot() internal pure virtual returns (bytes32);
    /// @dev slot of the "bounty already paid" marker
    function _paidSlot() internal pure virtual returns (bytes32);

    /// @notice Pays the bounty to the caller. Meant to work exactly once.
    function claim() external {
        bytes32 g = _guardSlot();
        bytes32 p = _paidSlot();
        uint256 v;
        assembly {
            v := sload(g)
        }
        if (v == ENTERED) revert Reentrancy();
        assembly {
            sstore(g, ENTERED)
            v := sload(p)
        }
        if (v == PAID) revert AlreadyPaid();
        assembly {
            sstore(p, PAID)
        }
        (bool ok,) = msg.sender.call{value: BOUNTY}("");
        if (!ok) revert TransferFailed();
        assembly {
            sstore(g, NOT_ENTERED) // with a shared slot this erases PAID
        }
    }
}

/// @notice VULNERABLE: lock and marker use the same slot.
contract SharedSlotGuardHook is BountyBase {
    constructor(IPoolManager m) BountyBase(m) {}

    function _guardSlot() internal pure override returns (bytes32) {
        return bytes32(uint256(0x929eee149b4bd21268));
    }

    function _paidSlot() internal pure override returns (bytes32) {
        return bytes32(uint256(0x929eee149b4bd21268)); // BUG: same slot as the lock
    }
}

/// @notice FIXED counterpart (still a toy, do not deploy): separate, namespaced slots.
contract SharedSlotGuardHookFixed is BountyBase {
    constructor(IPoolManager m) BountyBase(m) {}

    function _guardSlot() internal pure override returns (bytes32) {
        return keccak256("checker.samples.bounty.guard");
    }

    function _paidSlot() internal pure override returns (bytes32) {
        return keccak256("checker.samples.bounty.paid");
    }
}
