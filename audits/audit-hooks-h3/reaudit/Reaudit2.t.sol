// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {CheckerTestBase} from "../CheckerTestBase.sol";
import {Status, Report, CheckConfig} from "../../src/CheckerTypes.sol";
import {VBase} from "../mocks/AuditVariants.sol";
import "./Reaudit2Hooks.sol";

/// @notice hook-auditor, H3 re-audit: what the fixed checker says about a few new variants. Logging only.
contract Reaudit2Test is CheckerTestBase {
    uint160 internal constant BI = uint160(Hooks.BEFORE_INITIALIZE_FLAG);
    uint160 internal constant AI = uint160(Hooks.AFTER_INITIALIZE_FLAG);
    uint160 internal constant BR = uint160(Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG);
    uint160 internal constant BS = uint160(Hooks.BEFORE_SWAP_FLAG);
    uint160 internal constant AS = uint160(Hooks.AFTER_SWAP_FLAG);
    uint160 internal tagCounter = 1;

    function setUp() public {
        _baseSetUp();
    }

    function _at(uint160 flags, bytes memory code, uint256 mode) internal returns (address a) {
        a = address((uint160(0xA0D2) << 144) | (tagCounter++ << 16) | flags);
        vm.etch(a, code);
        VBase(a).init(manager, mode);
    }

    function _show(string memory tag, Report memory rep, uint256 mask) internal pure {
        console2.log(string.concat("#### ", tag, ": ", _oneLine(rep), rep.voided ? " VOID" : ""));
        for (uint256 i; i < 9; i++) {
            if (mask & (1 << i) == 0) continue;
            console2.log(string.concat("  ", rep.findings[i].id, " = ", statusName(rep.findings[i].status), ": ", rep.findings[i].summary));
            for (uint256 j; j < rep.findings[i].details.length; j++) {
                console2.log(string.concat("      - ", rep.findings[i].details[j]));
            }
        }
    }

    function test_N1_rateLimitExit() public {
        Report memory rep = _check(_at(BR, type(RateLimitExitHook).runtimeCode, 0));
        _show("N1 RateLimitExitHook", rep, (1 << D_REMOVE) | (1 << E_SWAP) | (1 << C_FOREIGN_POOL));
    }

    function test_N1b_maxSwapOutOfRangeBlock() public {
        Report memory rep = _check(_at(BS | BR, type(MaxSwapOutOfRangeBlockHook).runtimeCode, 0));
        _show("N1b MaxSwapOutOfRangeBlockHook", rep, (1 << D_REMOVE) | (1 << E_SWAP));
    }

    function _mimicCfg(uint256 mode) internal returns (CheckConfig memory cfg) {
        MimicToken a = new MimicToken();
        MimicToken b = new MimicToken();
        address hook = _at(BS | AS, type(PanicAfterFourHook).runtimeCode, mode);
        a.setUp_(hook, address(manager));
        b.setUp_(hook, address(manager));
        (address t0, address t1) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        cfg.manager = manager;
        cfg.hook = hook;
        cfg.hasKey = true;
        cfg.key = PoolKey(Currency.wrap(t0), Currency.wrap(t1), 3000, 60, IHooks(hook));
    }

    function test_N2_forgedCheatcodeError_control() public {
        Report memory rep = runChecks(_mimicCfg(0));
        _show("N2 control (hook panics on every swap, tokens behave)", rep, (1 << E_SWAP) | (1 << C_FOREIGN_POOL) | (1 << D_REMOVE));
        for (uint256 i; i < rep.setup.length; i++) console2.log(string.concat("   setup: ", rep.setup[i]));
    }

    function test_N2_forgedCheatcodeError_armed() public {
        Report memory rep = runChecks(_mimicCfg(1));
        _show("N2 armed (same hook; pool tokens answer balanceOf(PoolManager) with CheatcodeError-shaped data)", rep, (1 << E_SWAP) | (1 << C_FOREIGN_POOL) | (1 << D_REMOVE));
        for (uint256 i; i < rep.setup.length; i++) console2.log(string.concat("   setup: ", rep.setup[i]));
    }

    function test_N3_voidReportStillCarriesHookText() public {
        Report memory rep = _check(_at(BI | BS, type(VoidTextHook).runtimeCode, 0));
        string memory text = renderReport(rep);
        console2.log(text);
        console2.log(string.concat("#### N3 voided=", rep.voided ? "true" : "false", " contains 'PASS': ", _contains(text, "PASS") ? "YES" : "no"));
    }

    function test_N4_globalHaltVariants() public {
        for (uint256 m = 1; m <= 2; m++) {
            Report memory rep = _check(_at(AI | BR, type(GlobalHalt2Hook).runtimeCode, m));
            _show(m == 1 ? "N4 mode 1 (extreme-parameter trigger)" : "N4 mode 2 (only large exits read the switch)", rep, (1 << C_FOREIGN_POOL) | (1 << D_REMOVE));
        }
    }
}
