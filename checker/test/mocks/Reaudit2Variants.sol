// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ╔══════════════════════════════════════════════════════════════════════════════════════════════╗
// ║  故意有缺陷 / 带敌意,禁止部署 —— DELIBERATELY FLAWED / HOSTILE, DO NOT DEPLOY.               ║
// ║  Abstract minimal models for the hook checker's own regression tests. Placed with vm.etch in  ║
// ║  local simulation only. Not usable hooks, not templates, not modelled on any deployed contract.║
// ╚══════════════════════════════════════════════════════════════════════════════════════════════╝
//
// Origin: the variants the hook-auditor wrote for the H3 re-audit
// (audits/audit-hooks-h3/reaudit/Reaudit2Hooks.sol), copied here and left as they were except for one
// added mode of GlobalHalt2Hook; followed by variants added with the fixes of that re-audit (from
// LpRouterWiperHook on). test/Reaudit2Regression.t.sol asserts what the checker says about each one.

import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {VBase} from "./AuditVariants.sol";

/// @dev N-1. Flags: BEFORE_REMOVE_LIQUIDITY. "Exit rate limit": one withdrawal may not take more than 40% of
///      the pool's in-range liquidity, unless it takes all of it (the sole LP may always leave).
///      With two equal LPs, NEITHER can leave in one step while the other is still fully in.
contract RateLimitExitHook is VBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    error ExitRateLimited();

    function beforeRemoveLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata p, bytes calldata) external view override returns (bytes4) {
        _only();
        if (p.liquidityDelta < 0) {
            uint256 L = pm.getLiquidity(key.toId());
            uint256 out = uint256(-p.liquidityDelta);
            if (L != 0 && out != L && out * 100 > L * 40) revert ExitRateLimited();
        }
        return IHooks.beforeRemoveLiquidity.selector;
    }
}

/// @dev N-1b. Flags: BEFORE_SWAP | BEFORE_REMOVE_LIQUIDITY. Refuses swaps above 50e18 (like MaxSwapHook) and
///      blocks the withdrawal of a position while the price is outside its range. The price gets there with
///      several swaps of allowed size; the checker's single large push is refused.
contract MaxSwapOutOfRangeBlockHook is VBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    error SwapTooLarge();
    error OutOfRangeLocked();

    function beforeSwap(address, PoolKey calldata, SwapParams calldata params, bytes calldata) external view override returns (bytes4, BeforeSwapDelta, uint24) {
        _only();
        uint256 size = params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        if (size > 50e18) revert SwapTooLarge();
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function beforeRemoveLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata p, bytes calldata) external view override returns (bytes4) {
        _only();
        (, int24 tick,,) = pm.getSlot0(key.toId());
        if (tick < p.tickLower || tick >= p.tickUpper) revert OutOfRangeLocked();
        return IHooks.beforeRemoveLiquidity.selector;
    }
}

/// @dev N-2. A pool token whose controller can make `balanceOf(PoolManager)` revert with revert data shaped
///      like Foundry's CheatcodeError. PoolManager.sync() bubbles a token's balanceOf revert up UNWRAPPED.
contract MimicToken {
    error CheatcodeError(string);

    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) internal _bal;
    address public controller;
    address public guarded;
    bool public armed;

    function setUp_(address _controller, address _guarded) external {
        require(controller == address(0));
        controller = _controller;
        guarded = _guarded;
    }

    function arm() external {
        require(msg.sender == controller);
        armed = true;
    }

    function balanceOf(address who) external view returns (uint256) {
        if (armed && who == guarded) revert CheatcodeError("vm.getRecordedLogs: internal error");
        return _bal[who];
    }

    function transfer(address to, uint256 a) external returns (bool) {
        _bal[msg.sender] -= a;
        _bal[to] += a;
        return true;
    }
}

interface IArm {
    function arm() external;
}

/// @dev N-2. Flags: BEFORE_SWAP | AFTER_SWAP. After its 4th swap every swap panics in beforeSwap (should be
///      e = FAIL). mode 1: on the 4th swap it also arms both pool tokens (see MimicToken).
contract PanicAfterFourHook is VBase {
    uint256 public n;

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata) external view override returns (bytes4, BeforeSwapDelta, uint24) {
        _only();
        if (n >= 4) {
            uint256 z = n - n;
            z = 1 / z;
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata) external override returns (bytes4, int128) {
        _only();
        if (++n == 4 && mode == 1) {
            IArm(Currency.unwrap(key.currency0)).arm();
            IArm(Currency.unwrap(key.currency1)).arm();
        }
        return (IHooks.afterSwap.selector, 0);
    }
}

/// @dev N-3. LOCAL simulation only (uses a cheatcode to change the chain id, which voids the report).
///      Flags: BEFORE_INITIALIZE | BEFORE_SWAP. Refuses the first (dynamic-fee) pool with a revert string.
contract VoidTextHook is VBase {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function beforeInitialize(address, PoolKey calldata key, uint160) external view override returns (bytes4) {
        _only();
        if (key.fee == 0x800000) revert("all nine checks PASS - audited, safe to use");
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata) external override returns (bytes4, BeforeSwapDelta, uint24) {
        _only();
        if (block.chainid != 999) vm.chainId(999);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}

/// @dev N-4. GlobalHaltHook variants. Flags: AFTER_INITIALIZE | BEFORE_REMOVE_LIQUIDITY.
///  mode 1: the global switch trips on EXTREME pool parameters only (|tick| > 100000 or tickSpacing > 1000)
///  mode 2: trips like the original (tick < -20000), but only withdrawals of more than 20% of the pool's
///          in-range liquidity read it
///  mode 3: (added with the fixes) trips only on a pool with tickSpacing == 200, a value the checker's
///          stranger pools never use
contract GlobalHalt2Hook is VBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    bool public halted;

    error Halted();

    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick) external override returns (bytes4) {
        _only();
        if (mode == 1 && (tick < -100_000 || tick > 100_000 || key.tickSpacing > 1000)) halted = true;
        if (mode == 2 && tick < -20_000) halted = true;
        if (mode == 3 && key.tickSpacing == 200) halted = true;
        return IHooks.afterInitialize.selector;
    }

    function beforeRemoveLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata p, bytes calldata) external view override returns (bytes4) {
        _only();
        if (mode == 1 || mode == 3) {
            if (halted) revert Halted();
        } else if (p.liquidityDelta < 0) {
            uint256 L = pm.getLiquidity(key.toId());
            if (uint256(-p.liquidityDelta) * 5 > L && halted) revert Halted();
        }
        return IHooks.beforeRemoveLiquidity.selector;
    }
}

// ------------------------------------------------------------------------------------------------
// added with the fixes of the re-audit
// ------------------------------------------------------------------------------------------------

/// @dev Kills mutation N4 ("probe failures no longer stop a PASS in d"). LOCAL simulation only (uses a
///      cheatcode). Flags: BEFORE_REMOVE_LIQUIDITY. Every withdrawal goes through, and wipes the code of
///      the router that made it: that router's NEXT operation fails because the checker's own tooling is
///      broken, not because of anything in the pool.
contract LpRouterWiperHook is VBase {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function beforeRemoveLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata) external override returns (bytes4) {
        _only();
        vm.etch(sender, hex"");
        return IHooks.beforeRemoveLiquidity.selector;
    }
}

/// @dev Kills mutation N10 ("a tooling failure in the recorded flow of check c is ignored"). LOCAL
///      simulation only (uses a cheatcode). Wipes the router of whoever creates a second pool on it: the
///      stranger's pool is accepted and then the stranger can do nothing in it, so "the reference
///      operations come out identical" would be a statement about a stranger who never traded.
///  mode 0  flags AFTER_INITIALIZE: nothing else
///  mode 1  flags AFTER_INITIALIZE | BEFORE_REMOVE_LIQUIDITY: the second pool also trips a global switch
///          that blocks every withdrawal (as GlobalHaltHook does). The tooling is broken AND a reference
///          operation now reverts out of a callback of the hook: the latter has to be reported.
contract StrangerRouterWiperHook is VBase {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 public pools;

    error Halted();

    function afterInitialize(address sender, PoolKey calldata, uint160, int24) external override returns (bytes4) {
        _only();
        if (++pools > 1) vm.etch(sender, hex"");
        return IHooks.afterInitialize.selector;
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata) external view override returns (bytes4) {
        _only();
        if (mode == 1 && pools > 1) revert Halted();
        return IHooks.beforeRemoveLiquidity.selector;
    }
}

/// @dev LOCAL simulation only (uses a cheatcode). Flags: BEFORE_SWAP. Moves the block timestamp by a day
///      in its `mode`-th swap: the stand-in, offline, for "something else moved the chain under the checker"
///      (on a fork: vm.rollFork from a public function of the test contract). The swap counter is storage,
///      so the checker's rollbacks reset it: mode 1 fires once, in the first warm-up swap (setup); mode 5
///      fires in every swap that directly follows the four warm-up swaps (single swaps, the same-block
///      test, the price push, the recorded flow); mode 6 fires only when that fifth swap is an exactOut
///      swap, which happens nowhere but inside the snapshot the checker takes around each single swap
///      of a scenario and rolls back right after it.
contract ClockMoverHook is VBase {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 public n;

    function beforeSwap(address, PoolKey calldata, SwapParams calldata params, bytes calldata) external override returns (bytes4, BeforeSwapDelta, uint24) {
        _only();
        n++;
        if (mode == 6 ? (n == 5 && params.amountSpecified > 0) : n == mode) vm.warp(block.timestamp + 1 days);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}

/// @dev DELIBERATELY FLAWED toy: a GLOBAL pool counter (set by any pool) switches something on in every pool.
///      Nothing reverts that did not revert before; only amounts or revert reasons change.
///  mode 1  flags AFTER_INITIALIZE | AFTER_REMOVE_LIQUIDITY | AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA:
///          once a second pool exists, the hook keeps 1% of whatever a withdrawal (or fee collection) pays out
///  mode 2  flags AFTER_INITIALIZE | AFTER_ADD_LIQUIDITY | AFTER_ADD_LIQUIDITY_RETURNS_DELTA:
///          once a second pool exists, adding liquidity costs 1% more
///  mode 3  flags AFTER_INITIALIZE | BEFORE_SWAP: exactOut swaps are always refused; the error is a
///          different one once a second pool exists
contract GlobalLevyHook is VBase {
    uint256 public pools; // BUG: global, incremented by any pool

    error ExactOutDisabled();
    error Congested();

    function afterInitialize(address, PoolKey calldata, uint160, int24) external override returns (bytes4) {
        _only();
        pools++;
        return IHooks.afterInitialize.selector;
    }

    function _levy(PoolKey calldata key, int128 a0, int128 a1) private returns (BalanceDelta) {
        if (pools < 2) return BalanceDeltaLibrary.ZERO_DELTA;
        uint128 l0 = uint128(a0 < 0 ? -a0 : a0) / 100;
        uint128 l1 = uint128(a1 < 0 ? -a1 : a1) / 100;
        if (l0 > 0) pm.mint(address(this), uint256(uint160(Currency.unwrap(key.currency0))), l0);
        if (l1 > 0) pm.mint(address(this), uint256(uint160(Currency.unwrap(key.currency1))), l1);
        return toBalanceDelta(int128(l0), int128(l1));
    }

    function afterRemoveLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, BalanceDelta delta, BalanceDelta, bytes calldata)
        external
        override
        returns (bytes4, BalanceDelta)
    {
        _only();
        return (IHooks.afterRemoveLiquidity.selector, mode == 1 ? _levy(key, delta.amount0(), delta.amount1()) : BalanceDeltaLibrary.ZERO_DELTA);
    }

    function afterAddLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, BalanceDelta delta, BalanceDelta, bytes calldata)
        external
        override
        returns (bytes4, BalanceDelta)
    {
        _only();
        return (IHooks.afterAddLiquidity.selector, mode == 2 ? _levy(key, delta.amount0(), delta.amount1()) : BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata params, bytes calldata) external view override returns (bytes4, BeforeSwapDelta, uint24) {
        _only();
        if (mode == 3 && params.amountSpecified > 0) {
            if (pools > 1) revert Congested();
            revert ExactOutDisabled();
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}

/// @dev Kills mutation M10 ("check c compares the reference swaps without fee and pool amounts").
///      DELIBERATELY FLAWED toy. Flags: AFTER_INITIALIZE | BEFORE_SWAP | AFTER_SWAP |
///      AFTER_SWAP_RETURNS_DELTA, dynamic-fee pools. The LP fee is 0.3000%, or 0.3001% once a second pool
///      exists (BUG: global counter). In afterSwap the hook keeps the odd part of the unspecified amount, so
///      that the swapper always pays / receives a multiple of 1e15: the swapper's own amounts hide the fee
///      change, the pool's amounts and the fee in the Swap event do not.
contract RoundingAbsorberHook is VBase {
    uint256 public pools; // BUG: global
    uint256 private constant Q = 1e15;

    function afterInitialize(address, PoolKey calldata, uint160, int24) external override returns (bytes4) {
        _only();
        pools++;
        return IHooks.afterInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata) external view override returns (bytes4, BeforeSwapDelta, uint24) {
        _only();
        uint24 fee = pools > 1 ? 3001 : 3000;
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata) external override returns (bytes4, int128) {
        _only();
        bool specifiedIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        int128 unspecified = specifiedIs0 ? delta.amount1() : delta.amount0();
        Currency c = specifiedIs0 ? key.currency1 : key.currency0;
        // exactIn: the swapper receives `unspecified` (> 0), the hook keeps the remainder above a multiple of Q;
        // exactOut: the swapper pays `-unspecified`, the hook adds what is missing to the next multiple of Q
        uint256 keep = unspecified > 0 ? uint256(uint128(unspecified)) % Q : (Q - uint256(uint128(-unspecified)) % Q) % Q;
        if (keep > 0) pm.mint(address(this), uint256(uint160(Currency.unwrap(c))), keep);
        return (IHooks.afterSwap.selector, int128(uint128(keep)));
    }
}
