// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ╔══════════════════════════════════════════════════════════════════════════════════════════════╗
// ║  故意有漏洞,禁止部署 —— INTENTIONALLY VULNERABLE, DO NOT DEPLOY.                             ║
// ║  Minimal model for testing the hook checker locally. Not a usable hook, not a template.      ║
// ╚══════════════════════════════════════════════════════════════════════════════════════════════╝
//
// Pattern (the smallest model of the 2025-05 Cork incident, fact sheet §8.4): a callback that books
// value on the strength of its arguments does not check that the caller is the PoolManager. Anyone
// calls it directly with made-up arguments. This is an abstract model: it is NOT a reconstruction of
// Cork's contracts and contains nothing specific to any deployed protocol.
//
// The toy: a "swap rewards" hook. beforeSwap credits reward units to a trader named in hookData, in
// proportion to the swap size; claim() pays credited units out of the reward tokens the hook holds.
//
// Expected checker result: b = FAIL (callback accepted from a non-PoolManager address and state changed).

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

interface IERC20Like {
    function transfer(address to, uint256 amount) external returns (bool);
}

abstract contract SwapRewardsBase {
    IPoolManager public immutable poolManager;
    IERC20Like public immutable rewardToken;
    /// @notice reward units owed to each trader
    mapping(address => uint256) public credit;

    error NotPoolManager();
    error NothingToClaim();

    constructor(IPoolManager _poolManager, IERC20Like _rewardToken) {
        poolManager = _poolManager;
        rewardToken = _rewardToken;
        Hooks.Permissions memory p;
        p.beforeSwap = true;
        Hooks.validateHookPermissions(IHooks(address(this)), p);
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeSwap = true;
    }

    function _book(address sender, SwapParams calldata params, bytes calldata hookData) internal {
        address trader = hookData.length >= 32 ? abi.decode(hookData[:32], (address)) : sender;
        uint256 size = params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        credit[trader] += size / 1000;
    }

    function claim() external {
        uint256 amount = credit[msg.sender];
        if (amount == 0) revert NothingToClaim();
        credit[msg.sender] = 0;
        rewardToken.transfer(msg.sender, amount);
    }
}

/// @notice VULNERABLE: beforeSwap can be called by anyone.
contract NoCallerCheckHook is SwapRewardsBase {
    constructor(IPoolManager m, IERC20Like t) SwapRewardsBase(m, t) {}

    function beforeSwap(address sender, PoolKey calldata, SwapParams calldata params, bytes calldata hookData)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // BUG: no `msg.sender == poolManager` check
        _book(sender, params, hookData);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}

/// @notice FIXED counterpart for THIS issue only (still a toy, do not deploy): the callback accepts the
///         PoolManager alone. The reward formula stays naive on purpose (it trusts the requested swap
///         size and a trader address from hookData); that is an economic-design problem the checker
///         does not look at.
contract NoCallerCheckHookFixed is SwapRewardsBase {
    constructor(IPoolManager m, IERC20Like t) SwapRewardsBase(m, t) {}

    function beforeSwap(address sender, PoolKey calldata, SwapParams calldata params, bytes calldata hookData)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _book(sender, params, hookData);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}
