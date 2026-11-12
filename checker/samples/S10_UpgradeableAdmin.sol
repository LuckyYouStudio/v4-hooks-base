// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ╔══════════════════════════════════════════════════════════════════════════════════════════════╗
// ║  故意有缺陷,禁止部署 —— INTENTIONALLY UNSAFE DESIGN, DO NOT DEPLOY.                          ║
// ║  Minimal model for testing the hook checker locally. Not a usable hook, not a template.      ║
// ╚══════════════════════════════════════════════════════════════════════════════════════════════╝
//
// Pattern (fact sheet §8.2 "可升级"; the opposite of this project's "hooks are not upgradeable, no admin"
// rule): the swap logic lives behind a DELEGATECALL to an address an owner can replace at any time. The
// pool's LPs and traders are trusting whoever holds that key.
//
// Expected checker result: g = UNKNOWN (signs listed: EIP-1967 implementation slot set, owner() answers,
// DELEGATECALL in the bytecode). g never says FAIL: upgradeability is a trust decision, not a bug.

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "../../src/base/BaseHook.sol";

/// @notice The replaceable logic. Runs in the hook's storage context.
contract SwapLogicV1 {
    function onSwap() external pure returns (uint24) {
        return 0;
    }
}

/// @notice UNSAFE DESIGN: owner-replaceable logic behind DELEGATECALL.
contract UpgradeableAdminHook is BaseHook {
    /// @dev EIP-1967 implementation slot
    bytes32 private constant IMPL_SLOT = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);

    address public owner;

    error NotOwner();
    error LogicFailed();

    /// @dev the owner is an explicit argument: with CREATE2 deployment msg.sender is the deployer proxy
    constructor(IPoolManager m, address _owner, address logic) BaseHook(m) {
        owner = _owner;
        _setLogic(logic);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeSwap = true;
    }

    function upgradeTo(address logic) external {
        if (msg.sender != owner) revert NotOwner();
        _setLogic(logic);
    }

    function _setLogic(address logic) private {
        bytes32 slot = IMPL_SLOT;
        assembly {
            sstore(slot, logic)
        }
    }

    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bytes32 slot = IMPL_SLOT;
        address logic;
        assembly {
            logic := sload(slot)
        }
        (bool ok, bytes memory ret) = logic.delegatecall(abi.encodeCall(SwapLogicV1.onSwap, ()));
        if (!ok || ret.length != 32) revert LogicFailed();
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, abi.decode(ret, (uint24)));
    }
}

/// @notice Counterpart without the trust assumption (still a toy, do not deploy): same behaviour, the
///         logic is part of the contract, there is no owner and nothing to replace.
contract UpgradeableAdminHookFixed is BaseHook {
    constructor(IPoolManager m) BaseHook(m) {}

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
}
