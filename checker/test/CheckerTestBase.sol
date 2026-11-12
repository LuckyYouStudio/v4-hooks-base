// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {HookChecker} from "../src/HookChecker.sol";
import {Status, Finding, Report, CheckConfig} from "../src/CheckerTypes.sol";

/// @notice Shared fixture of the checker's own tests: a fresh local PoolManager, address mining with the
///         repo's HookMiner (deployer = this test contract), and assertions on a Report.
abstract contract CheckerTestBase is HookChecker {
    IPoolManager internal manager;

    function _baseSetUp() internal {
        vm.warp(1_700_000_000);
        vm.roll(1_000_000);
        manager = new PoolManager(address(this));
    }

    /// @dev Base mainnet PoolManager (docs/research/uniswap-v4-hooks-base.md §1.1) and the block the repo's
    ///      other fork tests pin
    address internal constant BASE_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    uint256 internal constant FORK_BLOCK = 56_228_000;

    /// @dev fork of Base at the pinned block, against the real PoolManager; skips without BASE_RPC_URL
    function _forkSetUp() internal {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "BASE_RPC_URL not set");
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        assertEq(block.chainid, 8453, "not Base mainnet");
        manager = IPoolManager(BASE_POOL_MANAGER);
        assertGt(address(manager).code.length, 20_000, "no PoolManager code at the documented address");
    }

    function _salt(uint160 flags, bytes memory creationCode, bytes memory args) internal view returns (bytes32 salt) {
        (, salt) = HookMiner.find(address(this), flags, creationCode, args);
    }

    function _check(address hook) internal returns (Report memory rep) {
        CheckConfig memory cfg;
        cfg.manager = manager;
        cfg.hook = hook;
        rep = runChecks(cfg);
        console2.log(_oneLine(rep));
    }

    function _oneLine(Report memory rep) internal pure returns (string memory s) {
        for (uint256 i; i < rep.findings.length; i++) {
            s = string.concat(s, rep.findings[i].id, "=", statusName(rep.findings[i].status), " ");
        }
    }

    function _assertStatus(Report memory rep, uint256 idx, Status want) internal pure {
        if (rep.findings[idx].status != want) {
            revert(
                string.concat(
                    "check ", rep.findings[idx].id, ": got ", statusName(rep.findings[idx].status), ", want ", statusName(want),
                    " - ", rep.findings[idx].summary
                )
            );
        }
    }

    /// @dev every check except the listed ones must be PASS or N/A
    function _assertCleanExcept(Report memory rep, uint256 skipMask) internal pure {
        for (uint256 i; i < rep.findings.length; i++) {
            if (skipMask & (1 << i) != 0) continue;
            Status s = rep.findings[i].status;
            if (s != Status.PASS && s != Status.NA) {
                revert(string.concat("check ", rep.findings[i].id, " is ", statusName(s), ": ", rep.findings[i].summary));
            }
        }
    }

    function _assertNoFail(Report memory rep) internal pure {
        for (uint256 i; i < rep.findings.length; i++) {
            if (rep.findings[i].status == Status.FAIL) {
                revert(string.concat("check ", rep.findings[i].id, " FAILS: ", rep.findings[i].summary));
            }
        }
    }

    /// @dev true when the summary or any detail line of check `idx` contains `needle`
    function _mentions(Report memory rep, uint256 idx, string memory needle) internal pure returns (bool) {
        Finding memory f = rep.findings[idx];
        if (_contains(f.summary, needle)) return true;
        for (uint256 i; i < f.details.length; i++) {
            if (_contains(f.details[i], needle)) return true;
        }
        return false;
    }

    function _contains(string memory hay, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(hay);
        bytes memory n = bytes(needle);
        if (n.length == 0) return true;
        if (h.length < n.length) return false;
        for (uint256 i; i + n.length <= h.length; i++) {
            bool ok = true;
            for (uint256 j; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }
}
