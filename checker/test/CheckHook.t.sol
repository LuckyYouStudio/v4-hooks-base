// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {HookChecker} from "../src/HookChecker.sol";
import {Status, Report, CheckConfig} from "../src/CheckerTypes.sol";

/// @title CheckHook: command-line entry of the hook checker
/// @notice Runs every check against the hook at $HOOK on a LOCAL FORK of the chain behind an RPC URL
///         (a public chain, or your own anvil), prints the report and optionally writes it to
///         checker/reports-local/ (git-ignored). Read-only towards the RPC: nothing is signed, nothing
///         is broadcast.
///
///   FOUNDRY_PROFILE=checker-run HOOK=0x... CHECK_RPC_URL=https://mainnet.base.org CHECK_FORK_BLOCK=56228000 \
///     CHECK_REPORT=my-hook forge test --match-contract CheckHook -vv
///
/// Env:
///   HOOK                required. Without it the test is skipped.
///   CHECK_RPC_URL       RPC to fork from (falls back to BASE_RPC_URL). For a hook on your own anvil:
///                       http://127.0.0.1:8545. An RPC URL that carries an API key IS a secret in the
///                       environment: for third-party code use a keyless public endpoint.
///   CHECK_FORK_BLOCK    block to pin (default: the RPC's latest block; pin it for reproducible reports)
///   POOL_MANAGER        default: the official PoolManager on Base (8453) / Base Sepolia (84532), from
///                       docs/research/uniswap-v4-hooks-base.md §1. On ANY OTHER chain it is REQUIRED: the
///                       entry stops with PoolManagerRequired. It is never read from the hook under test
///                       (a hook could name a "PoolManager" it controls and dictate every result).
///   POOL_CURRENCY0/1, POOL_FEE, POOL_TICK_SPACING
///                       optional PoolKey of a pool on this hook (existing, or to be initialized by the
///                       checker). POOL_CURRENCY1 switches it on; CURRENCY0 defaults to native ETH,
///                       FEE to the dynamic-fee flag (8388608), TICK_SPACING to 60.
///                       Without a key the checker creates its own pool with two mock tokens.
///   CHECK_NATIVE=true   own-pool mode: native ETH as currency0
///   CHECK_REPORT=name   also write checker/reports-local/<name>.md  ([A-Za-z0-9._-] only)
///   CHECK_STRICT=true   fail the test if any check reports FAIL or the report is void (for CI on your
///                       own hook)
///
/// A hook deployed inside your own Foundry test needs none of this: inherit HookChecker and call
/// runChecks (see checker/test/OwnHooks.t.sol).
contract CheckHook is HookChecker {
    address internal constant BASE_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant BASE_SEPOLIA_POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;

    /// @dev no default PoolManager is known for this chain and none was given
    error PoolManagerRequired(uint256 chainId);

    struct Entry {
        address hook;
        string rpc;
        uint256 pin; // 0 = latest block
        address managerGiven; // POOL_MANAGER, 0 = not given
        bool native;
        address currency0;
        address currency1; // 0 = no PoolKey given
        uint24 fee;
        int24 tickSpacing;
        string reportName;
        bool strict;
    }

    /// @dev everything the entry takes from the environment, in one place (tests override it)
    function _entry() internal virtual returns (Entry memory e) {
        e.hook = vm.envOr("HOOK", address(0));
        e.rpc = vm.envOr("CHECK_RPC_URL", vm.envOr("BASE_RPC_URL", string("")));
        e.pin = vm.envOr("CHECK_FORK_BLOCK", uint256(0));
        e.managerGiven = vm.envOr("POOL_MANAGER", address(0));
        e.native = vm.envOr("CHECK_NATIVE", false);
        e.currency0 = vm.envOr("POOL_CURRENCY0", address(0));
        e.currency1 = vm.envOr("POOL_CURRENCY1", address(0));
        e.fee = uint24(vm.envOr("POOL_FEE", uint256(LPFeeLibrary.DYNAMIC_FEE_FLAG)));
        e.tickSpacing = int24(int256(vm.envOr("POOL_TICK_SPACING", uint256(60))));
        e.reportName = vm.envOr("CHECK_REPORT", string(""));
        e.strict = vm.envOr("CHECK_STRICT", false);
    }

    /// @dev where CHECK_REPORT files go: a directory of its own, git-ignored, so that a run against
    ///      third-party code cannot overwrite the committed files in checker/reports/
    function _reportDir() internal pure virtual returns (string memory) {
        return "checker/reports-local/";
    }

    /// @notice The entry. `notWhileChecking`: the hook under test can call this function while a run is in
    ///         progress (a forge test contract sits at a predictable address); such a call must revert
    ///         before it reaches `createSelectFork`, which would not be undone by the revert.
    function test_checkHook() public notWhileChecking {
        Entry memory e = _entry();
        if (e.hook == address(0)) {
            vm.skip(true, "HOOK not set (this is the command-line entry, see the comment in CheckHook.t.sol)");
        }
        require(bytes(e.rpc).length != 0, "set CHECK_RPC_URL (or BASE_RPC_URL): the chain the hook lives on, or your anvil");
        if (e.pin == 0) vm.createSelectFork(e.rpc);
        else vm.createSelectFork(e.rpc, e.pin);

        CheckConfig memory cfg;
        cfg.hook = e.hook;
        cfg.manager = IPoolManager(resolveManager(block.chainid, e.managerGiven));
        cfg.nativeCurrency0 = e.native;
        if (e.currency1 != address(0)) {
            cfg.hasKey = true;
            cfg.key = PoolKey(Currency.wrap(e.currency0), Currency.wrap(e.currency1), e.fee, e.tickSpacing, IHooks(e.hook));
        }

        Report memory rep = runChecks(cfg);
        string memory text = string.concat(
            renderReport(rep),
            "\n---\nRun: ", e.pin == 0 ? "latest block (not pinned)" : "pinned block", ", ",
            cfg.hasKey ? "PoolKey given" : (cfg.nativeCurrency0 ? "own pool with native ETH" : "own pool with mock tokens"),
            ", PoolManager ", e.managerGiven != address(0) ? "given by the operator (POOL_MANAGER)" : "the documented one for this chain",
            ". Automated output, not reviewed by a human.\n",
            rep.voided
                ? "THIS REPORT IS VOID (see its first lines).\n"
                : "A FAIL or UNKNOWN is a line to look at, not a statement that the hook has a vulnerability; a PASS is not a statement that it is safe.\n"
        );
        console2.log(text);
        _onReport(rep, text);

        if (bytes(e.reportName).length != 0) {
            _requireSafeName(e.reportName);
            vm.writeFile(string.concat(_reportDir(), e.reportName, ".md"), text);
        }
        if (e.strict) {
            assertFalse(rep.voided, string.concat("the report is void: ", rep.voidReason));
            for (uint256 i; i < rep.findings.length; i++) {
                assertTrue(rep.findings[i].status != Status.FAIL, string.concat("check ", rep.findings[i].id, ": ", rep.findings[i].summary));
            }
        }
    }

    /// @dev called with every report the entry produces (tests that drive the entry override it)
    function _onReport(Report memory rep, string memory text) internal virtual {}

    /// @notice The PoolManager the checks run against: the operator's choice, else the documented address
    ///         for Base / Base Sepolia, else an error. Pure on purpose: nothing here can come from the
    ///         hook under test.
    function resolveManager(uint256 chainId, address given) public pure returns (address) {
        if (given != address(0)) return given;
        if (chainId == 8453) return BASE_POOL_MANAGER;
        if (chainId == 84532) return BASE_SEPOLIA_POOL_MANAGER;
        revert PoolManagerRequired(chainId);
    }

    function _requireSafeName(string memory name) private pure {
        bytes memory b = bytes(name);
        require(b.length <= 80, "CHECK_REPORT too long");
        for (uint256 i; i < b.length; i++) {
            bytes1 c = b[i];
            bool ok = (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "-" || c == "_"
                || (c == "." && i != 0);
            require(ok, "CHECK_REPORT: use [A-Za-z0-9._-]");
        }
    }
}
