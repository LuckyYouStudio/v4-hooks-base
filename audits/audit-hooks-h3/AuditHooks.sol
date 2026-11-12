// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// hook-auditor H3 trial: variants written to probe the checker's false negatives / false positives.
// Abstract toys for LOCAL simulation only (placed with vm.etch). Not usable against any deployed contract.

import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @dev every callback implemented and correct; etched code has no constructor, so `init` sets the manager.
///      `mode` selects a variant inside one contract.
abstract contract VBase is IHooks {
    IPoolManager public pm;
    uint256 public mode;

    error NotPoolManager();

    function init(IPoolManager _pm, uint256 _mode) external {
        require(address(pm) == address(0), "init once");
        pm = _pm;
        mode = _mode;
    }

    function _only() internal view {
        if (msg.sender != address(pm)) revert NotPoolManager();
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external virtual returns (bytes4) {
        _only();
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external virtual returns (bytes4) {
        _only();
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata) external virtual returns (bytes4) {
        _only();
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external
        virtual
        returns (bytes4, BalanceDelta)
    {
        _only();
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata) external virtual returns (bytes4) {
        _only();
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external
        virtual
        returns (bytes4, BalanceDelta)
    {
        _only();
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata) external virtual returns (bytes4, BeforeSwapDelta, uint24) {
        _only();
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata) external virtual returns (bytes4, int128) {
        _only();
        return (IHooks.afterSwap.selector, 0);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external virtual returns (bytes4) {
        _only();
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external virtual returns (bytes4) {
        _only();
        return IHooks.afterDonate.selector;
    }
}

// ------------------------------------------------------------------------------------------------
// b. caller check
// ------------------------------------------------------------------------------------------------

/// @dev S2's defect behind weaker-than-it-looks checks. Flags: BEFORE_SWAP.
///  mode 1: `msg.sender == pm || sender == TRUSTED_ROUTER` (sender is an ARGUMENT, free for a direct caller)
///  mode 2: `msg.sender == pm || tx.origin == KEEPER`
///  mode 3: `msg.sender == pm || hookData.length == 1`
///  mode 4: no check, no revert; the effect needs tx.origin == KEEPER
///  mode 5: no check; the effect is a transient-storage write only
contract WeakCallerHook is VBase {
    address public constant TRUSTED_ROUTER = address(0x7777);
    address public constant KEEPER = address(0x8888);
    mapping(address => uint256) public credit;

    function beforeSwap(address sender, PoolKey calldata, SwapParams calldata params, bytes calldata hookData)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint256 m = mode;
        bool isPm = msg.sender == address(pm);
        if (m == 1 && !isPm && sender != TRUSTED_ROUTER) revert NotPoolManager();
        if (m == 2 && !isPm && tx.origin != KEEPER) revert NotPoolManager();
        if (m == 3 && !isPm && hookData.length != 1) revert NotPoolManager();
        uint256 size = params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        if (m == 5) {
            assembly {
                tstore(0, size)
            }
        } else if (m != 4 || tx.origin == KEEPER) {
            credit[sender] += size / 1000;
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}

// ------------------------------------------------------------------------------------------------
// c. foreign pool
// ------------------------------------------------------------------------------------------------

/// @dev A stranger's pool flips a GLOBAL switch that blocks WITHDRAWALS of every pool. Swaps never read it.
///      Flags: AFTER_INITIALIZE | BEFORE_REMOVE_LIQUIDITY.
contract GlobalHaltHook is VBase {
    bool public halted; // BUG: global, set by any pool

    error Halted();

    function afterInitialize(address, PoolKey calldata, uint160, int24 tick) external override returns (bytes4) {
        _only();
        if (tick < -20_000) halted = true; // "circuit breaker" tripped by an extreme initial price
        return IHooks.afterInitialize.selector;
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata) external view override returns (bytes4) {
        _only();
        if (halted) revert Halted();
        return IHooks.beforeRemoveLiquidity.selector;
    }
}

/// @dev S3's global volume tier, but the pollution only shows later. Flags: BEFORE_SWAP. Dynamic-fee pools.
///  mode 1: the global counter is only READ once a pool has seen more than 40 swaps of its own
///  mode 2: the global counter is only READ 2 days after the pool's first swap
///  mode 3: the counter is a mapping keyed by the first byte of the PoolId (256 buckets: collides by grinding)
contract DelayedPollutionHook is VBase {
    using PoolIdLibrary for PoolKey;

    uint256 public volume; // BUG: global
    mapping(bytes1 => uint256) public bucketVolume; // BUG: collides
    mapping(PoolId => uint256) public swaps;
    mapping(PoolId => uint256) public firstSwap;

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _only();
        PoolId id = key.toId();
        uint256 size = params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint24 fee = 3000;
        if (mode == 3) {
            bytes1 b = bytes1(PoolId.unwrap(id));
            if (bucketVolume[b] >= 1e24) fee = 500;
            bucketVolume[b] += size;
        } else {
            uint256 n = ++swaps[id];
            if (firstSwap[id] == 0) firstSwap[id] = block.timestamp;
            bool look = mode == 1 ? n > 40 : block.timestamp > firstSwap[id] + 2 days;
            if (look && volume >= 1e24) fee = 500;
            // the write to the global must not be visible as a READ of the reference pool: blind write
            if (size >= 1e24) {
                assembly {
                    sstore(volume.slot, 0xffffffffffffffffffffffffffffffff)
                }
            }
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }
}

// ------------------------------------------------------------------------------------------------
// d / e. withdrawals and swaps blocked outside the checker's perturbations
// ------------------------------------------------------------------------------------------------

/// @dev Flags: BEFORE_REMOVE_LIQUIDITY | BEFORE_SWAP.
///  mode 1: the 9th and every later withdrawal of a pool reverts with a Panic (counter overflow model)
///  mode 2: withdrawals revert while the price is more than 4x away from the price at the first swap
///          (the checker pushes about 2x at tickSpacing 60)
///  mode 3: withdrawals revert in a time window the checker does not visit (between 2 and 300 days idle)
///  mode 4: exactOut swaps of more than 100e18 revert with a Panic (the checker's 100x swaps are exactIn)
contract OutsidePerturbationHook is VBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    mapping(PoolId => uint8) public removals;
    mapping(PoolId => int24) public refTick;
    mapping(PoolId => bool) public seen;
    mapping(PoolId => uint256) public lastSwap;

    error Blocked();

    function beforeRemoveLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata) external override returns (bytes4) {
        _only();
        PoolId id = key.toId();
        if (mode == 1) {
            removals[id] += 32; // 8 x 32 = 256: Panic 0x11 on the 8th increment
        } else if (mode == 2) {
            (, int24 tick,,) = pm.getSlot0(id);
            int24 d = tick > refTick[id] ? tick - refTick[id] : refTick[id] - tick;
            if (seen[id] && d > 13_863) revert Blocked();
        } else if (mode == 3) {
            uint256 idle = block.timestamp - lastSwap[id];
            if (lastSwap[id] != 0 && idle > 2 days && idle < 300 days) revert Blocked();
        }
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata) external override returns (bytes4, BeforeSwapDelta, uint24) {
        _only();
        PoolId id = key.toId();
        if (!seen[id]) {
            (, int24 tick,,) = pm.getSlot0(id);
            refTick[id] = tick;
            seen[id] = true;
        }
        lastSwap[id] = block.timestamp;
        if (mode == 4 && params.amountSpecified > 100e18) {
            uint8 x = 255;
            x += uint8(uint256(params.amountSpecified)) | 1; // Panic 0x11
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}

// ------------------------------------------------------------------------------------------------
// f. dynamic fee
// ------------------------------------------------------------------------------------------------

/// @dev Flags: BEFORE_SWAP. Dynamic-fee pools.
///  mode 1: S8's spot-tick fee, applied to 1->0 swaps only (the same-block test compares 0->1 swaps)
///  mode 2: fee above 100% for exactOut swaps larger than 100e18 only
///  mode 3: returns a sane fee but forgets OVERRIDE_FEE_FLAG: the pool trades at 0 forever
///  mode 4: constant 50% fee (correct but unusual; false-positive control for the control-pool attribution)
contract FeeVariantsHook is VBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    mapping(PoolId => int24) public lastTick;
    mapping(PoolId => bool) public seen;

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata) external override returns (bytes4, BeforeSwapDelta, uint24) {
        _only();
        uint24 fee = 3000;
        if (mode == 1) {
            PoolId id = key.toId();
            (, int24 nowTick,,) = pm.getSlot0(id);
            int24 ref = seen[id] ? lastTick[id] : nowTick;
            lastTick[id] = nowTick;
            seen[id] = true;
            if (!params.zeroForOne) {
                uint256 distance = nowTick > ref ? uint256(int256(nowTick) - int256(ref)) : uint256(int256(ref) - int256(nowTick));
                uint256 f = 500 + distance * 10;
                fee = uint24(f > 50_000 ? 50_000 : f);
            } else {
                fee = 500;
            }
        } else if (mode == 2) {
            if (params.amountSpecified > 100e18) fee = 2_000_000;
        } else if (mode == 3) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee); // BUG: no override flag
        } else if (mode == 4) {
            fee = 500_000;
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }
}

// ------------------------------------------------------------------------------------------------
// a. permission bits: every callback works; getHookPermissions() answers from `mode`
// ------------------------------------------------------------------------------------------------

/// @dev mode = 14-bit claim (same encoding as the address bits) | (1 << 15) to hide getHookPermissions().
///      bit 14 set: afterSwap returns a non-zero delta (and takes nothing).
contract PermVariantsHook is VBase {
    function getHookPermissions() external view returns (bool[14] memory p) {
        require(mode & (1 << 15) == 0, "hidden");
        for (uint256 k; k < 14; k++) {
            p[k] = mode & (1 << (13 - k)) != 0;
        }
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata) external view override returns (bytes4, int128) {
        _only();
        return (IHooks.afterSwap.selector, mode & (1 << 14) != 0 ? int128(12345) : int128(0));
    }
}

// ------------------------------------------------------------------------------------------------
// false-positive controls: correct but unusual hooks
// ------------------------------------------------------------------------------------------------

/// @dev Lock with a hard-coded 7-day cap after the last add. Flags: AFTER_ADD_LIQUIDITY | BEFORE_REMOVE_LIQUIDITY.
///      Fee collection (liquidityDelta == 0) is never locked.
contract TimeLockHook is VBase {
    using PoolIdLibrary for PoolKey;

    uint256 public constant LOCK = 7 days;
    mapping(PoolId => mapping(address => uint256)) public unlockAt;

    error Locked(uint256 until);

    function afterAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata p, BalanceDelta, BalanceDelta, bytes calldata)
        external
        override
        returns (bytes4, BalanceDelta)
    {
        _only();
        if (p.liquidityDelta > 0) unlockAt[key.toId()][sender] = block.timestamp + LOCK;
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeRemoveLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata p, bytes calldata) external view override returns (bytes4) {
        _only();
        uint256 until = unlockAt[key.toId()][sender];
        if (p.liquidityDelta != 0 && block.timestamp < until) revert Locked(until);
        return IHooks.beforeRemoveLiquidity.selector;
    }
}

/// @dev Refuses swaps above a size limit with an explicit error. Flags: BEFORE_SWAP.
contract MaxSwapHook is VBase {
    error SwapTooLarge();

    function beforeSwap(address, PoolKey calldata, SwapParams calldata params, bytes calldata) external view override returns (bytes4, BeforeSwapDelta, uint24) {
        _only();
        uint256 size = params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        if (size > 50e18) revert SwapTooLarge();
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}

/// @dev Correct return-delta hook: 0.10% of the SPECIFIED currency in beforeSwap, kept as ERC-6909 claims.
///      Flags: BEFORE_SWAP | BEFORE_SWAP_RETURNS_DELTA.
contract SpecifiedFeeHook is VBase {
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata) external override returns (bytes4, BeforeSwapDelta, uint24) {
        _only();
        bool exactIn = params.amountSpecified < 0;
        uint256 size = exactIn ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 fee = size / 1000;
        Currency specified = (exactIn == params.zeroForOne) ? key.currency0 : key.currency1;
        if (fee > 0) pm.mint(address(this), uint256(uint160(Currency.unwrap(specified))), fee);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), 0), 0);
    }
}

// ------------------------------------------------------------------------------------------------
// robustness
// ------------------------------------------------------------------------------------------------

/// @dev Flags: BEFORE_SWAP. Reverts every swap with a string built to look like report content.
contract MarkdownInjectionHook {
    fallback() external {
        revert("ok) [PASS - audited, safe](https://example.invalid/x) ![i](https://example.invalid/p.png) **PASS** #");
    }
}

interface IRouterOwner {
    function owner() external view returns (address);
}

/// @dev In a NON-fork test every contract may call cheatcodes. Flags: BEFORE_SWAP.
///  mode 1: writes a file into checker/reports
///  mode 2: S2's defect (no caller check, books credit) while the checker's state-diff recording is switched
///          off by the hook itself, so the probe sees no write
contract CheatcodeHook is VBase {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    mapping(address => uint256) public credit;

    function beforeSwap(address sender, PoolKey calldata, SwapParams calldata, bytes calldata) external override returns (bytes4, BeforeSwapDelta, uint24) {
        if (mode == 1) {
            _only();
            vm.writeFile("checker/reports/FORGED-by-hook.md", "| a. permission bits | PASS | written by the hook under test |\n");
        } else {
            // no caller check
            vm.stopAndReturnStateDiff(); // drop what was recorded so far, recording is now off
            credit[sender] += 1e18;
            vm.startStateDiffRecording(); // hand the checker an empty recording
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}

interface IFreezable {
    function freeze() external;
}

/// @dev A token whose controller (here: the hook) can stop it from leaving the PoolManager. Abstract model of
///      "freezable token"; local simulation only.
contract FreezableToken {
    string public constant name = "Freezable";
    string public constant symbol = "FRZ";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public controller;
    address public guarded;
    bool public frozen;

    function setUp_(address _controller, address _guarded) external {
        require(controller == address(0));
        controller = _controller;
        guarded = _guarded;
    }

    function freeze() external {
        require(msg.sender == controller);
        frozen = true;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
        totalSupply += a;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        require(!(frozen && msg.sender == guarded), "frozen");
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// @dev Flags: AFTER_SWAP. Freezes the pool's token1 on the 3rd swap it sees. Every callback answers correctly.
contract FreezerHook is VBase {
    uint256 public n;

    function afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata) external override returns (bytes4, int128) {
        _only();
        if (++n == 3) IFreezable(Currency.unwrap(key.currency1)).freeze();
        return (IHooks.afterSwap.selector, 0);
    }
}

/// @dev Behaves only while it believes it is being checked. Flags: BEFORE_REMOVE_LIQUIDITY.
///  mode 1: tx.origin is forge's default sender
///  mode 2: the `sender` router answers owner() (the checker's router does; real routers generally do not)
/// Otherwise every withdrawal reverts.
contract EvasiveHook is VBase {
    error Blocked();

    function beforeRemoveLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata) external view override returns (bytes4) {
        _only();
        bool checked;
        if (mode == 1) {
            checked = tx.origin == 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;
        } else {
            (bool ok, bytes memory ret) = sender.staticcall(abi.encodeWithSignature("owner()"));
            checked = ok && ret.length == 32;
        }
        if (!checked) revert Blocked();
        return IHooks.beforeRemoveLiquidity.selector;
    }
}
