// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// DELIBERATELY FLAWED / HOSTILE TOYS written by the hook-auditor for the H3 re-audit. Abstract minimal
// models, placed with vm.etch in local simulation only. DO NOT DEPLOY. Not modelled on any deployed contract.

import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {VBase} from "../mocks/AuditVariants.sol";

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
contract GlobalHalt2Hook is VBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    bool public halted;

    error Halted();

    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick) external override returns (bytes4) {
        _only();
        if (mode == 1 && (tick < -100_000 || tick > 100_000 || key.tickSpacing > 1000)) halted = true;
        if (mode == 2 && tick < -20_000) halted = true;
        return IHooks.afterInitialize.selector;
    }

    function beforeRemoveLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata p, bytes calldata) external view override returns (bytes4) {
        _only();
        if (mode == 1) {
            if (halted) revert Halted();
        } else if (p.liquidityDelta < 0) {
            uint256 L = pm.getLiquidity(key.toId());
            if (uint256(-p.liquidityDelta) * 5 > L && halted) revert Halted();
        }
        return IHooks.beforeRemoveLiquidity.selector;
    }
}
