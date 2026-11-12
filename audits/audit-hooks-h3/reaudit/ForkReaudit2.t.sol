// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {CheckHook} from "../CheckHook.t.sol";
import {Status, Report} from "../../src/CheckerTypes.sol";
import {VBase, IRouterOwner} from "../mocks/AuditVariants.sol";

// HOSTILE TOY for the hook-auditor's H3 re-audit. vm.etch inside a local fork simulation only. DO NOT DEPLOY.

/// @dev Flags: BEFORE_SWAP | BEFORE_REMOVE_LIQUIDITY. Every withdrawal reverts (d must be FAIL: mode 0 = control).
///  mode 1: every beforeRemoveLiquidity first calls `switchForkUnguarded()` on the checker, then reverts.
///          Withdrawals only happen inside the checker's per-scenario snapshots, never during setup.
///  mode 2: the first beforeSwap calls `rollForkUnguarded()` (same fork id, other block)
///  mode 3: the first beforeSwap calls `switchAndBackUnguarded()` (another fork and back again)
contract Reenter2Hook is VBase {
    bool public tried;

    error Blocked();

    function beforeRemoveLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata) external override returns (bytes4) {
        _only();
        if (mode == 1) {
            (bool ok,) = IRouterOwner(sender).owner().call(abi.encodeWithSignature("switchForkUnguarded()"));
            ok;
        }
        revert Blocked();
    }

    function beforeSwap(address sender, PoolKey calldata, SwapParams calldata, bytes calldata) external override returns (bytes4, BeforeSwapDelta, uint24) {
        _only();
        if (!tried && mode >= 2) {
            tried = true;
            (bool ok,) = IRouterOwner(sender).owner().call(abi.encodeWithSignature(mode == 2 ? "rollForkUnguarded()" : "switchAndBackUnguarded()"));
            ok;
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}

contract ForkReaudit2Test is CheckHook {
    address internal constant PM = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    uint256 internal constant FORK_BLOCK = 56_228_000;
    address internal constant HOOK = address((uint160(0xb00c) << 144) | uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG));

    string internal rpc;
    string internal letters;
    bool internal voided;
    string internal text;
    bool internal armed;
    uint256 public unguardedCalls;

    function setUp() public {
        rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true, "BASE_RPC_URL not set");
    }

    function _entry() internal view override returns (Entry memory e) {
        if (!armed) return e;
        e.hook = HOOK;
        e.rpc = rpc;
        e.pin = FORK_BLOCK;
        e.fee = 0x800000;
        e.tickSpacing = 60;
    }

    function _onReport(Report memory rep, string memory text_) internal override {
        delete letters;
        for (uint256 i; i < rep.findings.length; i++) {
            Status st = rep.findings[i].status;
            letters = string.concat(letters, st == Status.PASS ? "P" : st == Status.FAIL ? "F" : st == Status.NA ? "N" : "U");
        }
        voided = rep.voided;
        text = text_;
    }

    // three public functions WITHOUT the notWhileChecking guard, as a user's own test contract may have
    function switchForkUnguarded() public {
        vm.createSelectFork(rpc, FORK_BLOCK);
    }

    function rollForkUnguarded() public {
        vm.rollFork(FORK_BLOCK - 1);
    }

    function switchAndBackUnguarded() public {
        uint256 f = vm.activeFork();
        vm.createSelectFork(rpc, FORK_BLOCK);
        vm.selectFork(f);
    }

    function _run(uint256 mode) internal {
        vm.createSelectFork(rpc, FORK_BLOCK);
        vm.etch(HOOK, type(Reenter2Hook).runtimeCode);
        vm.makePersistent(HOOK);
        Reenter2Hook(HOOK).init(IPoolManager(PM), mode);
        armed = true;
        test_checkHook();
        console2.log(string.concat("#### mode ", vm.toString(mode), ": letters ", letters, voided ? " VOID" : " not void", "; active fork now ", vm.toString(vm.activeFork())));
        console2.log(text);
    }

    function test_fork_r2_mode0_control() public {
        _run(0);
    }

    function test_fork_r2_mode1_switchInsideScenarioSnapshot() public {
        _run(1);
    }

    function test_fork_r2_mode2_rollFork() public {
        _run(2);
    }

    function test_fork_r2_mode3_switchAndBack() public {
        _run(3);
    }
}
