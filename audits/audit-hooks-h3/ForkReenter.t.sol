// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CheckHook} from "../CheckHook.t.sol";
import {Report, CheckConfig} from "../../src/CheckerTypes.sol";
import {VBase, IRouterOwner} from "./AuditHooks.sol";

/// @dev Flags: BEFORE_SWAP. The first time PoolManager calls it, it finds the checker (the owner of the
///      checker's router, which is the `sender` argument) and calls the checker's own public test entry.
///      mode 0: gives the nested call all its gas; mode 1: 3M gas; mode 2: does nothing (control)
///      mode 3 (address also has BEFORE_REMOVE_LIQUIDITY): like 1, and EVERY withdrawal reverts; mode 4: the same
///      without the re-entry (control: the checker must report d = FAIL)
contract ReenterHook is VBase {
    uint256 public calls;
    bool public tried;
    bool public nestedOk;

    error Blocked();

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata) external view override returns (bytes4) {
        _only();
        if (mode >= 3) revert Blocked();
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function beforeSwap(address sender, PoolKey calldata, SwapParams calldata, bytes calldata) external override returns (bytes4, BeforeSwapDelta, uint24) {
        _only();
        calls++;
        if (!tried && mode != 2 && mode != 4) {
            tried = true;
            address checker = IRouterOwner(sender).owner();
            bool ok;
            if (mode == 0) (ok,) = checker.call(abi.encodeWithSignature("test_checkHook()"));
            else (ok,) = checker.call{gas: 3_000_000}(abi.encodeWithSignature("test_checkHook()"));
            nestedOk = ok;
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}

/// @dev foreign code that deploys a child which then calls a cheatcode
contract CheatChild {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function go() external {
        vm.warp(42);
    }
}

contract CheatParent {
    function spawnAndGo() external returns (bool ok) {
        CheatChild c = new CheatChild();
        (ok,) = address(c).call(abi.encodeCall(CheatChild.go, ()));
    }
}

/// @notice Run with HOOK=<address with BEFORE_SWAP bits>, CHECK_RPC_URL, CHECK_FORK_BLOCK, REENTER_MODE.
contract ForkReenterTest is CheckHook {
    address internal constant PM = 0x498581fF718922c3f8e6A244956aF099B2652b2b;

    function test_reenter() public {
        address hook = vm.envAddress("HOOK");
        // stand-in for "a hook that exists on the chain": same code and storage whatever fork is selected
        vm.etch(hook, type(ReenterHook).runtimeCode);
        vm.makePersistent(hook);
        ReenterHook(hook).init(IPoolManager(PM), vm.envOr("REENTER_MODE", uint256(0)));
        uint256 forksBefore;
        try vm.activeFork() returns (uint256 id) {
            forksBefore = id + 1;
        } catch {}
        test_checkHook();
        console2.log("active fork id after the run:", vm.activeFork(), " (0 = the fork the run started on)");
        console2.log("hook.calls / tried / nestedOk:", ReenterHook(hook).calls(), ReenterHook(hook).tried(), ReenterHook(hook).nestedOk());
        forksBefore;
    }

    /// @dev closer stand-in for an on-chain hook: the code is placed while a fork is active and made
    ///      persistent, so it is present on every fork selected later (as deployed code would be)
    function test_reenter2() public {
        address hook = vm.envAddress("HOOK");
        vm.createSelectFork(vm.envString("CHECK_RPC_URL"), vm.envUint("CHECK_FORK_BLOCK"));
        vm.etch(hook, type(ReenterHook).runtimeCode);
        vm.makePersistent(hook);
        ReenterHook(hook).init(IPoolManager(PM), vm.envOr("REENTER_MODE", uint256(0)));
        test_checkHook();
        console2.log("active fork id after the run:", vm.activeFork());
    }

    function test_fork_childOfForeignCode() public {
        vm.createSelectFork(vm.envString("CHECK_RPC_URL"), vm.envUint("CHECK_FORK_BLOCK"));
        address foreign = address(0xF0F0F1);
        vm.etch(foreign, type(CheatParent).runtimeCode);
        uint256 t = block.timestamp;
        (bool ok, bytes memory ret) = foreign.call(abi.encodeCall(CheatParent.spawnAndGo, ()));
        console2.log("call ok:", ok, " child cheatcode ok:", ok && abi.decode(ret, (bool)));
        console2.log("timestamp changed:", block.timestamp != t);
    }
}
