// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {BaseHook} from "../src/base/BaseHook.sol";

/// @notice Shared logic of the two hook deployment scripts (DeployVolatilityFeeHook / DeployPriorityFeeHook).
///
/// NOT AUDITED. This script has only ever been run against a LOCAL fork (see script/verify-deploy-local.sh
/// and test/fork/DeployScripts.t.sol). Deploying to a testnet or to mainnet needs the project owner's
/// approval and is done by the project owner in person. The hooks themselves have had internal reviews by
/// AI agents only - no external audit. Do not use them with mainnet funds.
///
/// What it does:
///   1. picks the PoolManager from the chain id (table below); any other chain reverts;
///   2. mines the CREATE2 salt for the deterministic deployment proxy (forge-std's CREATE2_FACTORY,
///      0x4e59b44847b379578588920cA78FbF26c0B4956C - the deployer `forge script` uses for `new X{salt: s}`);
///   3. deploys with `new Hook{salt: salt}(poolManager)`;
///   4. asserts: deployed address == mined address, low 14 address bits == the hook's permission flags,
///      the address has code, hook.poolManager() == the table's PoolManager, and
///      Hooks.validateHookPermissions(hook, hook.getHookPermissions()) passes.
///
/// Of the five assertions in step 4, the low-14-bits one (PermissionBitsMismatch) cannot fire once
/// "deployed == mined" holds, because the mined address has those bits by construction; it is kept as
/// defence in depth. A wrong salt, a wrong constructor argument or a plain CREATE is in practice stopped
/// earlier, by the hook's own constructor (BaseHook calls Hooks.validateHookPermissions).
///
/// Signing: the script itself reads nothing from the environment (`vm.startBroadcast()` is called with
/// NO argument and there is no `vm.env*` call). The signer is whatever forge is given: a keystore
/// (`--account <name>`) or a hardware wallet (`--ledger` / `--trezor`). Note that forge itself also
/// accepts the keystore selection from the environment variables ETH_KEYSTORE, ETH_KEYSTORE_ACCOUNT and
/// ETH_PASSWORD: check that these are unset, or are what you intend, before adding `--broadcast`.
/// Do not pass `--private-key` and do not put a key in an env var or a file in this repository.
///
/// Run records: every `forge script` run, including a dry run without `--broadcast`, leaves a record
/// under broadcast/<script>/<chain id>/ (git-ignored). script/verify-deploy-local.sh refuses to run
/// while broadcast/Deploy<Hook>.s.sol/8453 exists; move or delete that directory first.
abstract contract DeployHookBase is Script {
    /// @notice The chain has no entry in the PoolManager table below.
    error UnsupportedChain(uint256 chainId);
    /// @notice The table's PoolManager address has no code on the connected chain (wrong RPC?).
    error PoolManagerHasNoCode(address poolManager);
    /// @notice The deterministic deployment proxy is missing on the connected chain.
    error Create2FactoryHasNoCode(address factory);
    /// @notice A previous run already deployed this exact init code with the first matching salt.
    error AlreadyDeployed(address hook);
    error DeployedAddressMismatch(address expected, address actual);
    error PermissionBitsMismatch(uint160 expected, uint160 actual);
    error HookHasNoCode(address hook);
    error WrongPoolManager(address expected, address actual);

    /// PoolManager addresses. Source: docs/research/uniswap-v4-hooks-base.md
    ///   - 8453  (Base mainnet): section 1.1, from the official Uniswap v4 deployments page
    ///     https://docs.uniswap.org/contracts/v4/deployments ("Base: 8453"); 24,009 bytes of code read
    ///     on chain at block 56,227,003.
    ///   - 84532 (Base Sepolia): section 1.2, same page ("Base Sepolia: 84532"); 24,009 bytes of code
    ///     read on chain at block 57,569,588.
    /// v4 addresses differ per chain - never copy one from another chain.
    address internal constant POOL_MANAGER_BASE = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant POOL_MANAGER_BASE_SEPOLIA = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;

    function poolManagerFor(uint256 chainId) public pure returns (address) {
        if (chainId == 8453) return POOL_MANAGER_BASE;
        if (chainId == 84532) return POOL_MANAGER_BASE_SEPOLIA;
        revert UnsupportedChain(chainId);
    }

    /// @dev afterInitialize + beforeSwap = 0x1080 for both hooks in this repository; taken from the
    ///      v4-core constants, and cross-checked after deployment against getHookPermissions().
    function expectedFlags() public pure returns (uint160) {
        return uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
    }

    function _name() internal pure virtual returns (string memory);
    function _creationCode() internal pure virtual returns (bytes memory);
    function _create2(address poolManager, bytes32 salt) internal virtual returns (address);

    /// @notice Read-only: the PoolManager for the connected chain and the mined (address, salt).
    function predict() public view returns (address poolManager, address hook, bytes32 salt) {
        poolManager = poolManagerFor(block.chainid);
        if (poolManager.code.length == 0) revert PoolManagerHasNoCode(poolManager);
        if (CREATE2_FACTORY.code.length == 0) revert Create2FactoryHasNoCode(CREATE2_FACTORY);
        // HookMiner skips addresses that already have code, so on a chain where this hook is already
        // deployed it would return the NEXT salt and a second copy would be deployed. Refuse instead.
        address first = _firstMatch(poolManager);
        if (first.code.length != 0) revert AlreadyDeployed(first);
        (hook, salt) = HookMiner.find(CREATE2_FACTORY, expectedFlags(), _creationCode(), abi.encode(poolManager));
    }

    function run() external returns (address hook) {
        (address poolManager, address expected, bytes32 salt) = predict();

        vm.startBroadcast(); // no key argument: the signer is whatever forge is given (see header)
        hook = _create2(poolManager, salt);
        vm.stopBroadcast();

        if (hook != expected) revert DeployedAddressMismatch(expected, hook);
        uint160 bits = uint160(hook) & Hooks.ALL_HOOK_MASK;
        // Unreachable when the check above passed (`expected` comes from HookMiner.find, which only
        // returns addresses with exactly these bits). Kept as defence in depth; no test can reach it.
        if (bits != expectedFlags()) revert PermissionBitsMismatch(expectedFlags(), bits);
        if (hook.code.length == 0) revert HookHasNoCode(hook);
        address pm = address(BaseHook(hook).poolManager());
        if (pm != poolManager) revert WrongPoolManager(poolManager, pm);
        // all 14 bits against what the deployed code itself declares (reverts on any mismatch)
        Hooks.validateHookPermissions(IHooks(hook), BaseHook(hook).getHookPermissions());

        console2.log(_name());
        console2.log("  chain id    ", block.chainid);
        console2.log("  poolManager ", poolManager);
        console2.log("  hook address", hook);
        console2.log("  salt        ", uint256(salt));
        console2.log("  low 14 bits ", uint256(bits));
    }

    /// @dev the first salt whose address has the right bits, whether or not it has code
    function _firstMatch(address poolManager) private pure returns (address a) {
        bytes memory init = abi.encodePacked(_creationCode(), abi.encode(poolManager));
        uint160 flags = expectedFlags();
        for (uint256 s; s < 160_444; s++) {
            a = HookMiner.computeAddress(CREATE2_FACTORY, s, init);
            if (uint160(a) & Hooks.ALL_HOOK_MASK == flags) return a;
        }
        revert("no salt found");
    }
}
