// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {VolatilityFeeHook} from "../../src/VolatilityFeeHook.sol";
import {DeployHookBase} from "../../script/DeployHookBase.sol";

// Negative tests for the post-deployment assertions of script/DeployHookBase.sol.
//
// The two real scripts cannot fail these assertions (a wrong salt, a wrong constructor argument or a
// plain CREATE is stopped earlier, by the hook's own constructor), so each harness below overrides
// `_create2` to hand `run()` a broken result and the test expects the matching assertion to fire.
// The first three tests were written by the internal AI-agent auditor in the pre-publication review;
// the last two were added afterwards.
//
// TEST-ONLY models. FakePm / FakeHook are deliberately wrong contracts placed with vm.etch inside a
// local fork simulation. DO NOT DEPLOY. Nothing here is sent to any network and no key is used.
//
// Not covered: DeployHookBase.PermissionBitsMismatch. It is unreachable once "deployed == mined" holds
// (the mined address has the bits by construction), so no test can make it fire.

/// @dev Foreign code with a different poolManager(). A constant, not a storage variable: vm.etch copies
///      code only, so a storage-backed getter would read 0 at the etched address.
contract FakePm {
    address public constant poolManager = address(0xBEEF);
}

/// @dev Right poolManager(), but declares one callback more than the address encodes (0x1080).
contract FakeHook {
    address public immutable poolManager;

    constructor(address pm) {
        poolManager = pm;
    }

    function getHookPermissions() external pure returns (Hooks.Permissions memory p) {
        p.afterInitialize = true;
        p.beforeSwap = true;
        p.beforeRemoveLiquidity = true; // not in the address bits
    }
}

abstract contract DeployHarness is DeployHookBase {
    address internal constant VOL_HOOK = 0x4B7651999822ba687E96bbaE929A41f7E0AB9080;

    function _name() internal pure override returns (string memory) {
        return "harness";
    }

    function _creationCode() internal pure override returns (bytes memory) {
        return type(VolatilityFeeHook).creationCode;
    }
}

/// @dev Deploys correctly but reports a wrong address.
contract WrongAddrDeploy is DeployHarness {
    function _create2(address pm, bytes32 salt) internal override returns (address) {
        new VolatilityFeeHook{salt: salt}(IPoolManager(pm));
        return address(0xdead);
    }
}

/// @dev Deploys nothing and returns the predicted address.
contract NoDeploy is DeployHarness {
    function _create2(address, bytes32) internal pure override returns (address) {
        return VOL_HOOK;
    }
}

/// @dev Foreign code with another poolManager() at the predicted address.
contract ForeignCodeDeploy is DeployHarness {
    function _create2(address, bytes32) internal override returns (address) {
        vm.etch(VOL_HOOK, address(new FakePm()).code);
        return VOL_HOOK;
    }
}

/// @dev Code at the predicted address that passes every earlier assertion (address, bits, code,
///      poolManager()) but declares permissions the address does not encode.
contract WrongPermissionsDeploy is DeployHarness {
    function _create2(address pm, bytes32) internal override returns (address) {
        vm.etch(VOL_HOOK, address(new FakeHook(pm)).code);
        return VOL_HOOK;
    }
}

/// @dev The real deployment, for the test of the missing deterministic deployment proxy.
contract PlainDeploy is DeployHarness {
    function _create2(address pm, bytes32 salt) internal override returns (address) {
        return address(new VolatilityFeeHook{salt: salt}(IPoolManager(pm)));
    }
}

/// @notice Runs on a Base mainnet FORK (local simulation, pinned block). Needs BASE_RPC_URL; skipped
///         without it.
contract DeployScriptsNegForkTest is Test {
    address internal constant MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant VOL_HOOK = 0x4B7651999822ba687E96bbaE929A41f7E0AB9080;
    uint256 internal constant FORK_BLOCK = 56_228_000;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "BASE_RPC_URL not set");
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        assertEq(block.chainid, 8453, "not Base mainnet");
        assertEq(VOL_HOOK.code.length, 0, "nothing there before");
    }

    /// @dev pins `if (hook != expected) revert DeployedAddressMismatch`
    function test_fork_neg_wrongAddress() public {
        WrongAddrDeploy d = new WrongAddrDeploy();
        vm.expectRevert(
            abi.encodeWithSelector(DeployHookBase.DeployedAddressMismatch.selector, VOL_HOOK, address(0xdead))
        );
        d.run();
    }

    /// @dev pins `if (hook.code.length == 0) revert HookHasNoCode`
    function test_fork_neg_noCode() public {
        NoDeploy d = new NoDeploy();
        vm.expectRevert(abi.encodeWithSelector(DeployHookBase.HookHasNoCode.selector, VOL_HOOK));
        d.run();
    }

    /// @dev pins `if (pm != poolManager) revert WrongPoolManager`
    function test_fork_neg_wrongPoolManager() public {
        ForeignCodeDeploy d = new ForeignCodeDeploy();
        vm.expectRevert(abi.encodeWithSelector(DeployHookBase.WrongPoolManager.selector, MANAGER, address(0xBEEF)));
        d.run();
    }

    /// @dev pins the final `Hooks.validateHookPermissions(...)` call: everything before it passes
    function test_fork_neg_declaredPermissionsDoNotMatchAddress() public {
        WrongPermissionsDeploy d = new WrongPermissionsDeploy();
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, VOL_HOOK));
        d.run();
    }

    /// @dev pins `if (CREATE2_FACTORY.code.length == 0) revert Create2FactoryHasNoCode` in predict()
    function test_fork_neg_create2FactoryMissing() public {
        PlainDeploy d = new PlainDeploy();
        d.predict(); // passes while the proxy is there
        address factory = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        vm.etch(factory, hex"");
        vm.expectRevert(abi.encodeWithSelector(DeployHookBase.Create2FactoryHasNoCode.selector, factory));
        d.run();
    }
}
