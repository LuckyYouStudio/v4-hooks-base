// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CheckerTestBase} from "../CheckerTestBase.sol";
import {Status, Report, CheckConfig} from "../../src/CheckerTypes.sol";
import "./AuditHooks.sol";

/// @notice hook-auditor H3 trial. Exploratory: prints what the checker says, asserts nothing.
contract AuditTest is CheckerTestBase {
    uint160 internal constant BI = uint160(Hooks.BEFORE_INITIALIZE_FLAG);
    uint160 internal constant AI = uint160(Hooks.AFTER_INITIALIZE_FLAG);
    uint160 internal constant AA = uint160(Hooks.AFTER_ADD_LIQUIDITY_FLAG);
    uint160 internal constant BR = uint160(Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG);
    uint160 internal constant BS = uint160(Hooks.BEFORE_SWAP_FLAG);
    uint160 internal constant AS = uint160(Hooks.AFTER_SWAP_FLAG);
    uint160 internal constant BSRD = uint160(Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
    uint160 internal constant ASRD = uint160(Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);

    uint160 internal tagCounter = 1;

    function setUp() public {
        _baseSetUp();
    }

    function _at(uint160 flags, bytes memory code, uint256 mode) internal returns (address a) {
        a = address((uint160(0xA0D1) << 144) | (tagCounter++ << 16) | flags);
        vm.etch(a, code);
        if (mode != type(uint256).max) VBase(a).init(manager, mode);
    }

    function _show(string memory label, Report memory rep, uint256 mask) internal pure {
        console2.log(string.concat("=== ", label, " :: ", _oneLine(rep)));
        for (uint256 i; i < 9; i++) {
            if (mask & (1 << i) == 0) continue;
            console2.log(string.concat("  [", rep.findings[i].id, "] ", statusName(rep.findings[i].status), " - ", rep.findings[i].summary));
            for (uint256 j; j < rep.findings[i].details.length; j++) {
                console2.log(string.concat("      ", rep.findings[i].details[j]));
            }
        }
    }

    function _quiet(address hook) internal returns (Report memory rep) {
        CheckConfig memory cfg;
        cfg.manager = manager;
        cfg.hook = hook;
        rep = runChecks(cfg);
    }

    // ---- b ------------------------------------------------------------------------------------
    function test_b_weakCaller() public {
        string[5] memory names = ["b1 pm||sender-arg", "b2 pm||tx.origin", "b3 pm||hookData.length==1", "b4 no check, effect gated on tx.origin", "b5 no check, tstore only"];
        for (uint256 m = 1; m <= 5; m++) {
            Report memory rep = _quiet(_at(BS, type(WeakCallerHook).runtimeCode, m));
            _show(names[m - 1], rep, 1 << B_CALLER);
        }
    }

    /// @dev hand-assembled: answers every call with its selector; if the last calldata word is a magic value it
    ///      jumps into code that sits inside something shaped like a Solidity CBOR trailer and does an SSTORE
    function test_b_fakeMetadataTrailer() public {
        bytes32 magic = keccak256("open sesame");
        bytes memory code = abi.encodePacked(
            hex"366020900335",
            hex"7f", magic, hex"14", hex"61005a", hex"57",
            hex"600035", hex"7f", bytes32(bytes4(0xffffffff)), hex"16", hex"600052", hex"60206000f3",
            hex"a2", hex"5b", hex"6001600055", hex"00", hex"0008"
        );
        assertEq(code.length, 99);
        address hook = _at(BI, code, type(uint256).max);
        Report memory rep = _quiet(hook);
        _show("b fake metadata trailer hides SSTORE", rep, (1 << B_CALLER) | (1 << G_UPGRADE));
        // and anyone can make it write:
        vm.prank(address(0xBAD));
        (bool ok,) = hook.call(abi.encodePacked(IHooks.beforeDonate.selector, magic));
        console2.log("stranger call with the magic word ok:", ok, " slot0 now:", uint256(vm.load(hook, 0)));
    }

    // ---- a ------------------------------------------------------------------------------------
    function test_a_permissionCombos() public {
        // address bits, claim (mode), label
        _show("a1 addr BS|AS, claims BS (extra bit, function works)", _quiet(_at(BS | AS, type(PermVariantsHook).runtimeCode, BS)), 1);
        _show("a2 addr BS, claims BS|AS (missing bit)", _quiet(_at(BS, type(PermVariantsHook).runtimeCode, BS | AS)), 1);
        _show("a3 addr BS, getHookPermissions hidden, afterSwap exists (missing bit, undetectable)", _quiet(_at(BS, type(PermVariantsHook).runtimeCode, 1 << 15)), 1);
        _show("a4 addr AS, claims AS|ASRD, returns delta 12345 (missing RD bit)", _quiet(_at(AS, type(PermVariantsHook).runtimeCode, AS | ASRD | (1 << 14))), 1);
        _show("a5 addr AS, hidden, returns delta 12345 (missing RD bit, hidden)", _quiet(_at(AS, type(PermVariantsHook).runtimeCode, (1 << 15) | (1 << 14))), 1 | (1 << I_RETURN_DELTA));
        _show("a6 addr AS|ASRD|BSRD (unpaired BSRD), claims same", _quiet(_at(AS | ASRD | BSRD, type(PermVariantsHook).runtimeCode, AS | ASRD | BSRD)), 1);
        _show("a7 addr AS|ASRD, claims same, returns delta 12345 without taking", _quiet(_at(AS | ASRD, type(PermVariantsHook).runtimeCode, AS | ASRD | (1 << 14))), 1 | (1 << E_SWAP) | (1 << I_RETURN_DELTA));
        _show("a8 addr ALL bits incl. unpaired none, hidden", _quiet(_at(uint160(Hooks.ALL_HOOK_MASK), type(PermVariantsHook).runtimeCode, 1 << 15)), 1);
    }

    // ---- c ------------------------------------------------------------------------------------
    function test_c_globalHaltBlocksWithdrawals() public {
        address hook = _at(AI | BR, type(GlobalHaltHook).runtimeCode, 0);
        Report memory rep = _quiet(hook);
        _show("c1 stranger pool halts withdrawals globally", rep, (1 << C_FOREIGN_POOL) | (1 << D_REMOVE));
    }

    function test_c_delayedPollution() public {
        string[3] memory names = ["c2 global read after 40 own swaps", "c3 global read after 2 days", "c4 bucket = first byte of PoolId"];
        for (uint256 m = 1; m <= 3; m++) {
            _show(names[m - 1], _quiet(_at(BS, type(DelayedPollutionHook).runtimeCode, m)), 1 << C_FOREIGN_POOL);
        }
    }

    // ---- d / e ---------------------------------------------------------------------------------
    function test_de_outsidePerturbations() public {
        string[4] memory names = ["d1 9th withdrawal panics", "d2 withdrawals blocked beyond 4x price move", "d3 withdrawals blocked 2..300 days idle", "e1 exactOut > 100e18 panics"];
        for (uint256 m = 1; m <= 4; m++) {
            Report memory rep = _quiet(_at(BR | BS, type(OutsidePerturbationHook).runtimeCode, m));
            console2.log(string.concat("=== ", names[m - 1], " :: ", _oneLine(rep)));
            console2.log(string.concat("  [d] ", rep.findings[D_REMOVE].summary));
            console2.log(string.concat("  [e] ", rep.findings[E_SWAP].summary));
        }
    }

    function test_d_evasive() public {
        for (uint256 m = 1; m <= 2; m++) {
            Report memory rep = _quiet(_at(BR, type(EvasiveHook).runtimeCode, m));
            console2.log(string.concat("=== evasive mode ", vm.toString(m), " :: ", _oneLine(rep)));
            console2.log(string.concat("  [d] ", rep.findings[D_REMOVE].summary));
        }
    }

    // ---- f ------------------------------------------------------------------------------------
    function test_f_variants() public {
        string[4] memory names = ["f1 spot fee on 1->0 only", "f2 fee >100% for exactOut >100e18", "f3 forgot OVERRIDE_FEE_FLAG", "f4 constant 50% fee (FP control)"];
        for (uint256 m = 1; m <= 4; m++) {
            Report memory rep = _quiet(_at(BS, type(FeeVariantsHook).runtimeCode, m));
            _show(names[m - 1], rep, (1 << F_DYNAMIC_FEE) | (m == 4 ? (1 << E_SWAP) | (1 << D_REMOVE) : 0));
            console2.log(string.concat("  [e] ", rep.findings[E_SWAP].summary));
        }
    }

    // ---- false-positive controls -----------------------------------------------------------------
    function test_fp_timeLock() public {
        Report memory rep = _quiet(_at(AA | BR, type(TimeLockHook).runtimeCode, 0));
        _show("fp1 7-day lock with hard cap", rep, 1 | (1 << D_REMOVE) | (1 << E_SWAP) | (1 << C_FOREIGN_POOL));
    }

    function test_fp_maxSwap() public {
        Report memory rep = _quiet(_at(BS, type(MaxSwapHook).runtimeCode, 0));
        _show("fp2 explicit refusal of large swaps", rep, 1 | (1 << D_REMOVE) | (1 << E_SWAP) | (1 << C_FOREIGN_POOL));
    }

    function test_fp_specifiedFee() public {
        Report memory rep = _quiet(_at(BS | BSRD, type(SpecifiedFeeHook).runtimeCode, 0));
        _show("fp3 correct return-delta fee held as claims", rep, 0x1ff);
    }

    // ---- robustness ----------------------------------------------------------------------------
    function test_r_markdownInjection() public {
        Report memory rep = _quiet(_at(BS, type(MarkdownInjectionHook).runtimeCode, type(uint256).max));
        console2.log(renderReport(rep));
    }

    function test_r_cheatcodeHook_writesFile() public {
        Report memory rep = _quiet(_at(BS, type(CheatcodeHook).runtimeCode, 1));
        console2.log(_oneLine(rep));
        console2.log("forged file exists:", vm.exists("checker/reports/FORGED-by-hook.md"));
    }

    function test_r_cheatcodeHook_hidesWrites() public {
        Report memory rep = _quiet(_at(BS, type(CheatcodeHook).runtimeCode, 2));
        _show("r cheatcode hook hides its writes from check b", rep, 1 << B_CALLER);
    }

    // ---- d: both pools broken by a freezable token ----------------------------------------------
    function test_d_freezableToken_bothPoolsRevert() public {
        MockERC20 a = new MockERC20("A", "A", 18);
        FreezableToken f = new FreezableToken();
        require(address(a) < address(f), "order");
        address hook = _at(AS, type(FreezerHook).runtimeCode, 0);
        f.setUp_(hook, address(manager));
        CheckConfig memory cfg;
        cfg.manager = manager;
        cfg.hook = hook;
        cfg.hasKey = true;
        cfg.key = PoolKey(Currency.wrap(address(a)), Currency.wrap(address(f)), 3000, 60, IHooks(hook));
        Report memory rep = runChecks(cfg);
        for (uint256 i; i < rep.setup.length; i++) {
            console2.log(string.concat("  setup: ", rep.setup[i]));
        }
        _show("d hook freezes token1 after setup; control pool breaks too", rep, (1 << D_REMOVE) | (1 << E_SWAP));
    }
}
