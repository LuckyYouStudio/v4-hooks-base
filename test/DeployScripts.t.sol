// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {DeployHookBase} from "../script/DeployHookBase.sol";
import {DeployVolatilityFeeHook} from "../script/DeployVolatilityFeeHook.s.sol";
import {DeployPriorityFeeHook} from "../script/DeployPriorityFeeHook.s.sol";

/// @notice Offline part of the deployment-script tests: the chain-id table and the refusals.
///         The actual deployment is exercised on a Base fork in test/fork/DeployScripts.t.sol.
contract DeployScriptsTest is Test {
    DeployVolatilityFeeHook internal dv;
    DeployPriorityFeeHook internal dp;

    function setUp() public {
        dv = new DeployVolatilityFeeHook();
        dp = new DeployPriorityFeeHook();
    }

    function test_poolManagerTable() public view {
        assertEq(dv.poolManagerFor(8453), 0x498581fF718922c3f8e6A244956aF099B2652b2b);
        assertEq(dv.poolManagerFor(84532), 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408);
        assertEq(dp.poolManagerFor(8453), dv.poolManagerFor(8453));
        assertEq(dp.poolManagerFor(84532), dv.poolManagerFor(84532));
        assertEq(dv.expectedFlags(), 0x1080);
        assertEq(dp.expectedFlags(), 0x1080);
    }

    function testFuzz_unknownChainReverts(uint64 chainId) public {
        vm.assume(chainId != 8453 && chainId != 84532);
        vm.expectRevert(abi.encodeWithSelector(DeployHookBase.UnsupportedChain.selector, uint256(chainId)));
        dv.poolManagerFor(chainId);
    }

    /// @dev the local test chain (31337), Ethereum mainnet (1): run() and predict() revert before anything is sent
    function test_run_unknownChainReverts() public {
        vm.expectRevert(abi.encodeWithSelector(DeployHookBase.UnsupportedChain.selector, block.chainid));
        dv.run();
        vm.expectRevert(abi.encodeWithSelector(DeployHookBase.UnsupportedChain.selector, block.chainid));
        dp.run();
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(DeployHookBase.UnsupportedChain.selector, uint256(1)));
        dv.predict();
    }

    /// @dev right chain id but nothing at the table's address (wrong RPC, or a bare local chain)
    function test_run_poolManagerWithoutCodeReverts() public {
        vm.chainId(8453);
        vm.expectRevert(
            abi.encodeWithSelector(DeployHookBase.PoolManagerHasNoCode.selector, dv.poolManagerFor(8453))
        );
        dv.run();
        vm.chainId(84532);
        vm.expectRevert(
            abi.encodeWithSelector(DeployHookBase.PoolManagerHasNoCode.selector, dp.poolManagerFor(84532))
        );
        dp.run();
    }
}
