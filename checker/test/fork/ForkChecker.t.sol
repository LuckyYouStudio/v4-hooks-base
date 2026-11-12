// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {VolatilityFeeHook} from "../../../src/VolatilityFeeHook.sol";
import {PriorityFeeHook} from "../../../src/PriorityFeeHook.sol";
import {SampleRegistry} from "../SampleRegistry.sol";
import {Status, Report, CheckConfig} from "../../src/CheckerTypes.sol";

contract CheatcodeUser {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function warp() external {
        vm.warp(42);
    }
}

/// @notice The checker on a fork of Base mainnet (pinned block), against the REAL PoolManager: our two
///         hooks must still come out clean, and every sample must get the same verdicts as on the local
///         PoolManager. Local simulation; nothing is sent to the chain.
///         Needs BASE_RPC_URL (e.g. https://mainnet.base.org); skipped without it.
contract ForkCheckerTest is SampleRegistry {
    uint160 internal constant FLAGS = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);

    /// @dev selects a fork, so it carries the guard the README asks for: code under test must not be able
    ///      to call it while runChecks is in progress
    function setUp() public notWhileChecking {
        _forkSetUp();
    }

    function _assertAllPass(Report memory rep) internal pure {
        for (uint256 i; i < 8; i++) {
            _assertStatus(rep, i, Status.PASS);
        }
        _assertStatus(rep, I_RETURN_DELTA, Status.NA);
    }

    function test_fork_volatilityFeeHook_nothingReported() public {
        VolatilityFeeHook hook =
            new VolatilityFeeHook{salt: _salt(FLAGS, type(VolatilityFeeHook).creationCode, abi.encode(manager))}(manager);
        Report memory rep = _check(address(hook));
        _assertAllPass(rep);
        assertTrue(_mentions(rep, F_DYNAMIC_FEE, "500..10000 pips"));
    }

    function test_fork_priorityFeeHook_nothingReported() public {
        PriorityFeeHook hook =
            new PriorityFeeHook{salt: _salt(FLAGS, type(PriorityFeeHook).creationCode, abi.encode(manager))}(manager);
        Report memory rep = _check(address(hook));
        _assertAllPass(rep);
        assertTrue(_mentions(rep, F_DYNAMIC_FEE, "500..3000 pips"));
    }

    function test_fork_ownHooks_nativeEth_nothingReported() public {
        CheckConfig memory cfg;
        cfg.manager = manager;
        cfg.nativeCurrency0 = true;
        cfg.hook = address(new PriorityFeeHook{salt: _salt(FLAGS, type(PriorityFeeHook).creationCode, abi.encode(manager))}(manager));
        _assertAllPass(runChecks(cfg));
    }

    /// @dev all 20 samples against the real PoolManager: same verdicts as locally
    function test_fork_matrix_sameAsLocal() public {
        string memory out = string.concat(
            "# Checker vs. its own samples (Base fork, real PoolManager, block 56228000)\n\n",
            "Written by `checker/test/fork/ForkChecker.t.sol::test_fork_matrix_sameAsLocal`; do not edit by hand.\n",
            "The samples are deliberately vulnerable toys, deployed only inside the local fork simulation.\n",
            "S5 is funded with 10 ETH before the run (the bounty its toy is about).\n\n",
            _matrix()
        );
        vm.writeFile("checker/reports/fork-samples-matrix.md", out);
    }

    /// @dev Records a fact the README relies on. Code the test did not create, placed at an address on
    ///      a fork, is refused by Foundry when it calls a cheatcode ("no cheatcode access"); in a non-fork
    ///      test every contract may call cheatcodes. So: check third-party hooks through a fork, never by
    ///      deploying their bytecode in a plain local test.
    function test_fork_foreignCodeHasNoCheatcodeAccess() public {
        address foreign = address(0xF0F0F0);
        vm.etch(foreign, type(CheatcodeUser).runtimeCode);
        uint256 t = block.timestamp;
        (bool ok,) = foreign.call(abi.encodeCall(CheatcodeUser.warp, ()));
        assertFalse(ok, "etched code must not reach cheatcodes on a fork");
        assertEq(block.timestamp, t);
    }
}
