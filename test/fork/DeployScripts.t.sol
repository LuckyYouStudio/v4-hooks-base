// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {BaseHook} from "../../src/base/BaseHook.sol";
import {DeployHookBase} from "../../script/DeployHookBase.sol";
import {DeployVolatilityFeeHook} from "../../script/DeployVolatilityFeeHook.s.sol";
import {DeployPriorityFeeHook} from "../../script/DeployPriorityFeeHook.s.sol";

/// @notice The two deployment scripts run end to end on a Base mainnet FORK (local simulation, pinned
///         block, nothing is sent to any network, no key). Needs BASE_RPC_URL; skipped without it.
contract DeployScriptsForkTest is Test {
    address internal constant MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    uint256 internal constant FORK_BLOCK = 56_228_000;
    // The addresses the read-only mining scripts print for Base mainnet (README, "Address mining").
    address internal constant VOL_HOOK = 0x4B7651999822ba687E96bbaE929A41f7E0AB9080;
    uint256 internal constant VOL_SALT = 4820;
    address internal constant PRIO_HOOK = 0xBeb0026Aa9eF43478b921106D56Ebc7b1eD75080;
    uint256 internal constant PRIO_SALT = 2403;

    DeployVolatilityFeeHook internal dv;
    DeployPriorityFeeHook internal dp;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "BASE_RPC_URL not set");
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        assertEq(block.chainid, 8453, "not Base mainnet");
        dv = new DeployVolatilityFeeHook();
        dp = new DeployPriorityFeeHook();
    }

    function test_fork_predict_matchesMinedAddresses() public view {
        (address pm, address hook, bytes32 salt) = dv.predict();
        assertEq(pm, MANAGER);
        assertEq(hook, VOL_HOOK);
        assertEq(uint256(salt), VOL_SALT);
        (pm, hook, salt) = dp.predict();
        assertEq(pm, MANAGER);
        assertEq(hook, PRIO_HOOK);
        assertEq(uint256(salt), PRIO_SALT);
    }

    function test_fork_deployVolatilityFeeHook() public {
        assertEq(VOL_HOOK.code.length, 0, "nothing there before");
        address hook = dv.run();
        _checkDeployed(hook, VOL_HOOK);
        // a second run must not silently deploy a second copy at the next salt
        vm.expectRevert(abi.encodeWithSelector(DeployHookBase.AlreadyDeployed.selector, VOL_HOOK));
        dv.run();
    }

    function test_fork_deployPriorityFeeHook() public {
        assertEq(PRIO_HOOK.code.length, 0, "nothing there before");
        address hook = dp.run();
        _checkDeployed(hook, PRIO_HOOK);
        vm.expectRevert(abi.encodeWithSelector(DeployHookBase.AlreadyDeployed.selector, PRIO_HOOK));
        dp.run();
    }

    function _checkDeployed(address hook, address expected) internal view {
        assertEq(hook, expected, "address");
        assertGt(hook.code.length, 0, "code");
        assertEq(uint160(hook) & Hooks.ALL_HOOK_MASK, 0x1080, "low 14 bits");
        assertEq(address(BaseHook(hook).poolManager()), MANAGER, "poolManager");
        Hooks.Permissions memory p = BaseHook(hook).getHookPermissions();
        assertTrue(p.afterInitialize && p.beforeSwap, "declared callbacks");
        Hooks.validateHookPermissions(IHooks(hook), p);
    }
}
