// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {VolatilityFeeHook} from "../src/VolatilityFeeHook.sol";

/// @notice Finds the CREATE2 salt that gives VolatilityFeeHook an address whose low 14 bits equal its
///         permission flags. Read-only: prints the salt and address, broadcasts nothing, needs no key.
///
///   POOL_MANAGER=0x... forge script script/MineHookAddress.s.sol [--rpc-url <target chain, read-only>]
///
/// Env:
///   POOL_MANAGER  constructor argument (required; it is part of the init code, so it changes the salt)
///   DEPLOYER      who will execute the CREATE2 (default: the deterministic deployment proxy
///                 0x4e59b44847b379578588920cA78FbF26c0B4956C that `forge script`/`forge create` use)
///
/// For another hook: copy `run`, swap in its creation code, constructor args and flags. HookMiner.find
/// takes any 14-bit flag set (see test/HookMiner.t.sol).
contract MineHookAddress is Script {
    function run() external view returns (address hookAddress, bytes32 salt) {
        address poolManager = vm.envAddress("POOL_MANAGER");
        address deployer = vm.envOr("DEPLOYER", CREATE2_FACTORY);
        // The hook's constructor reverts if POOL_MANAGER has no code. Run this script with --rpc-url of
        // the target chain to have that checked here as well; without a fork there is nothing to check.
        bool onChain = block.chainid != 31337;
        if (onChain) require(poolManager.code.length > 0, "POOL_MANAGER has no code on this chain");
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);

        (hookAddress, salt) =
            HookMiner.find(deployer, flags, type(VolatilityFeeHook).creationCode, abi.encode(poolManager));

        require(uint160(hookAddress) & Hooks.ALL_HOOK_MASK == flags, "flags mismatch");
        console2.log("deployer    ", deployer);
        console2.log("poolManager ", poolManager);
        console2.log("flags       ", uint256(flags));
        console2.log("hook address", hookAddress);
        console2.log("salt        ", uint256(salt));
        if (!onChain) console2.log("note: no --rpc-url given, POOL_MANAGER code not checked");
    }
}
