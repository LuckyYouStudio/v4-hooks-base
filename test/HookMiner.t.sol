// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {VolatilityFeeHook} from "../src/VolatilityFeeHook.sol";
import {PermissionsMockHook} from "./utils/PermissionsMockHook.sol";

/// @notice Address mining: for any set of permission bits, HookMiner (v4-periphery) finds a CREATE2 salt
///         whose address passes v4-core's own permission checks.
contract HookMinerTest is Test {
    using Hooks for IHooks;

    /// @dev any address with code: BaseHook's constructor rejects a PoolManager without code (I-1)
    function _fakeManager() internal returns (IPoolManager m) {
        m = IPoolManager(makeAddr("manager"));
        vm.etch(address(m), hex"00");
    }

    function _mineAndDeploy(uint160 flags) internal returns (PermissionsMockHook h) {
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), flags, type(PermissionsMockHook).creationCode, abi.encode(flags));
        // the constructor itself runs Hooks.validateHookPermissions and would revert on a bad address
        h = new PermissionsMockHook{salt: salt}(flags);
        assertEq(address(h), expected, "CREATE2 address");
        assertEq(uint160(address(h)) & Hooks.ALL_HOOK_MASK, flags, "low 14 bits");
        // and once more from the outside, with v4-core's library
        Hooks.validateHookPermissions(IHooks(address(h)), h.getHookPermissions());
    }

    function test_mine_fixedFlagSets() public {
        uint160[6] memory sets = [
            uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG), // H1 dynamic fee
            uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG), // H2-like
            uint160(Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG), // H3-like
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG),
            uint160(Hooks.ALL_HOOK_MASK),
            uint160(Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG) // lowest bit only
        ];
        for (uint256 i; i < sets.length; i++) {
            _mineAndDeploy(sets[i]);
        }
    }

    /// forge-config: default.fuzz.runs = 24
    function testFuzz_mine_anyFlags(uint16 raw) public {
        uint160 flags = uint160(raw) & Hooks.ALL_HOOK_MASK;
        vm.assume(flags != 0);
        _mineAndDeploy(flags);
    }

    function test_wrongAddress_failsValidation() public {
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        (, bytes32 salt) =
            HookMiner.find(address(this), flags, type(PermissionsMockHook).creationCode, abi.encode(flags));
        // same salt, different constructor arg => different address, flags no longer match
        uint160 other = uint160(Hooks.BEFORE_DONATE_FLAG);
        vm.expectPartialRevert(Hooks.HookAddressNotValid.selector);
        new PermissionsMockHook{salt: salt}(other);
    }

    function test_mine_volatilityFeeHook() public {
        IPoolManager fakeManager = _fakeManager();
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), flags, type(VolatilityFeeHook).creationCode, abi.encode(fakeManager));
        VolatilityFeeHook h = new VolatilityFeeHook{salt: salt}(fakeManager);
        assertEq(address(h), expected);
        Hooks.validateHookPermissions(IHooks(address(h)), h.getHookPermissions());
        assertTrue(IHooks(address(h)).isValidHookAddress(LPFeeLibrary.DYNAMIC_FEE_FLAG));
        // exactly these two callbacks, nothing else
        assertTrue(IHooks(address(h)).hasPermission(Hooks.AFTER_INITIALIZE_FLAG));
        assertTrue(IHooks(address(h)).hasPermission(Hooks.BEFORE_SWAP_FLAG));
        assertEq(uint160(address(h)) & Hooks.ALL_HOOK_MASK, flags);
    }

    /// @dev PoolManager.initialize only checks that return-delta bits come with their base bit; the
    ///      exact 14-bit match is enforced solely by the hook's own constructor. So: an address with one
    ///      extra bit, or one bit short, must make the constructor revert.
    function test_volatilityFeeHook_extraOrMissingBit_constructorReverts() public {
        IPoolManager fakeManager = _fakeManager();
        uint160 right = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        uint160[6] memory wrong = [
            right | uint160(Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG), // one extra: would brick withdrawals
            right | uint160(Hooks.AFTER_SWAP_FLAG), // one extra
            right | uint160(Hooks.BEFORE_INITIALIZE_FLAG), // one extra
            uint160(Hooks.BEFORE_SWAP_FLAG), // missing afterInitialize: pools would never register
            uint160(Hooks.AFTER_INITIALIZE_FLAG), // missing beforeSwap: fee would never be set
            0
        ];
        for (uint256 i; i < wrong.length; i++) {
            (address target, bytes32 salt) =
                HookMiner.find(address(this), wrong[i], type(VolatilityFeeHook).creationCode, abi.encode(fakeManager));
            assertEq(uint160(target) & Hooks.ALL_HOOK_MASK, wrong[i]);
            vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, target));
            new VolatilityFeeHook{salt: salt}(fakeManager);
        }
    }

    function test_unminedDeployment_reverts() public {
        IPoolManager fakeManager = _fakeManager();
        // a plain CREATE address almost surely does not carry the flags; pick a salt that certainly does not
        bytes memory init = abi.encodePacked(type(VolatilityFeeHook).creationCode, abi.encode(fakeManager));
        uint256 salt;
        while (
            uint160(HookMiner.computeAddress(address(this), salt, init)) & Hooks.ALL_HOOK_MASK
                == uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG)
        ) salt++;
        vm.expectPartialRevert(Hooks.HookAddressNotValid.selector);
        new VolatilityFeeHook{salt: bytes32(salt)}(fakeManager);
    }
}
