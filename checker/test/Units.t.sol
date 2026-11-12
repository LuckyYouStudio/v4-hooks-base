// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {SafeCall} from "../src/lib/SafeCall.sol";
import {RevertInfo} from "../src/lib/RevertInfo.sol";
import {BytecodeScan} from "../src/lib/BytecodeScan.sol";
import {CheckerRouter} from "../src/CheckerRouter.sol";
import {LinesLib, Lines} from "../src/CheckerTypes.sol";
import "./mocks/HostileHooks.sol";

contract Reverter {
    error Custom(uint256 a);

    function panic() external pure returns (uint256) {
        uint256 z;
        return 1 / z;
    }

    function str() external pure {
        revert("plain message");
    }

    function custom() external pure {
        revert Custom(7);
    }

    function bare() external pure {
        revert();
    }

    function ok() external pure returns (uint256) {
        return 42;
    }
}

contract CheatcodeCaller {
    function warp(uint256 t) external {
        (bool ok,) = address(uint160(uint256(keccak256("hevm cheat code")))).call(abi.encodeWithSignature("warp(uint256)", t));
        require(ok);
    }
}

/// @notice Unit and fuzz tests of the checker's building blocks, in particular "never reverts on hostile
///         input" for everything that parses bytes it did not produce.
contract UnitsTest is Test {
    Reverter internal r = new Reverter();

    // --- SafeCall ---------------------------------------------------------------------------------

    function test_safeCall_okAndWord() public {
        SafeCall.Result memory res = SafeCall.call(address(r), 0, 100_000, abi.encodeCall(Reverter.ok, ()), 64);
        assertTrue(res.ok);
        assertEq(res.retSize, 32);
        assertEq(uint256(SafeCall.word0(res)), 42);
    }

    function test_safeCall_returnBombIsTruncated() public {
        address bomb = address(new ReturnBombHook());
        uint256 g = gasleft();
        SafeCall.Result memory res = SafeCall.call(bomb, 0, 10_000_000, hex"12345678", 256);
        uint256 used = g - gasleft();
        assertTrue(res.ok);
        assertEq(res.retSize, 0x200000, "full size reported");
        assertEq(res.ret.length, 256, "only 256 bytes copied");
        // the bomb paid for its own 2 MB of memory inside the capped call; the caller paid for 256 bytes
        assertLt(used - res.gasUsed, 50_000, "caller-side cost stays small");
    }

    function test_safeCall_revertBombIsTruncated() public {
        address bomb = address(new RevertBombHook());
        SafeCall.Result memory res = SafeCall.call(bomb, 0, 10_000_000, hex"12345678", 100);
        assertFalse(res.ok);
        assertEq(res.retSize, 0x200000);
        assertEq(res.ret.length, 100);
    }

    function test_safeCall_gasBurnerIsCapped() public {
        address burner = address(new GasBurnerHook());
        uint256 g = gasleft();
        SafeCall.Result memory res = SafeCall.call(burner, 0, 1_000_000, hex"12345678", 64);
        assertFalse(res.ok);
        assertLt(g - gasleft(), 1_100_000, "cost bounded by the cap");
        assertTrue(SafeCall.looksOutOfGas(res, 1_000_000));
    }

    function test_safeCall_revertIsNotOutOfGas() public {
        SafeCall.Result memory res = SafeCall.call(address(r), 0, 1_000_000, abi.encodeCall(Reverter.bare, ()), 64);
        assertFalse(res.ok);
        assertFalse(SafeCall.looksOutOfGas(res, 1_000_000));
    }

    function test_safeCall_staticcallBlocksWrites() public {
        address noisy = address(new NoisyHook());
        SafeCall.Result memory res = SafeCall.staticcall(noisy, 5_000_000, hex"12345678", 64);
        assertFalse(res.ok, "a state-changing target fails under staticcall instead of changing state");
    }

    function testFuzz_safeCall_helpersNeverRevert(bytes memory data, uint256 offset, uint256 start, uint256 len) public pure {
        SafeCall.selector(data);
        (bool inBounds, bytes32 w) = SafeCall.wordAt(data, offset);
        if (!inBounds) assertEq(w, bytes32(0));
        bytes memory s = SafeCall.slice(data, start, len);
        assertLe(s.length, data.length);
    }

    // --- RevertInfo -------------------------------------------------------------------------------

    function _revertData(bytes memory callData) internal returns (bytes memory) {
        SafeCall.Result memory res = SafeCall.call(address(r), 0, 1_000_000, callData, 1024);
        assertFalse(res.ok);
        return res.ret;
    }

    function test_revertInfo_kinds() public {
        RevertInfo.Info memory i = RevertInfo.decode(_revertData(abi.encodeCall(Reverter.panic, ())));
        assertEq(uint8(i.kind), uint8(RevertInfo.Kind.PANIC));
        assertEq(i.panicCode, 0x12);
        assertEq(i.text, "Panic(0x12 division by zero)");

        i = RevertInfo.decode(_revertData(abi.encodeCall(Reverter.str, ())));
        assertEq(uint8(i.kind), uint8(RevertInfo.Kind.ERROR_STRING));
        assertEq(i.text, "Error(`plain message`)");

        i = RevertInfo.decode(_revertData(abi.encodeCall(Reverter.custom, ())));
        assertEq(uint8(i.kind), uint8(RevertInfo.Kind.CUSTOM));
        assertEq(i.inner, Reverter.Custom.selector);
        assertFalse(i.wrapped);

        i = RevertInfo.decode(_revertData(abi.encodeCall(Reverter.bare, ())));
        assertEq(uint8(i.kind), uint8(RevertInfo.Kind.EMPTY));
        assertTrue(RevertInfo.looksUnimplemented(i));

        i = RevertInfo.decode(abi.encodeWithSelector(RevertInfo.HOOK_NOT_IMPLEMENTED));
        assertTrue(RevertInfo.looksUnimplemented(i));
    }

    /// @dev a WrappedError produced by the real PoolManager: a pool whose hook address has code that
    ///      reverts in beforeInitialize
    function test_revertInfo_realWrappedError() public {
        IPoolManager manager = new PoolManager(address(this));
        address hook = address(uint160(0xC0DE0000) << 64 | uint160(Hooks.BEFORE_INITIALIZE_FLAG));
        vm.etch(hook, address(r).code); // no beforeInitialize: falls to "function not found", empty revert
        PoolKey memory key = PoolKey(Currency.wrap(address(1)), Currency.wrap(address(2)), 3000, 60, IHooks(hook));
        SafeCall.Result memory res =
            SafeCall.call(address(manager), 0, 5_000_000, abi.encodeCall(IPoolManager.initialize, (key, 2 ** 96)), 1024);
        assertFalse(res.ok);
        RevertInfo.Info memory i = RevertInfo.decode(res.ret);
        assertTrue(i.wrapped);
        assertEq(i.outer, CustomRevert.WrappedError.selector);
        assertEq(i.target, hook);
        assertEq(i.callback, IHooks.beforeInitialize.selector);
        assertEq(uint8(i.kind), uint8(RevertInfo.Kind.EMPTY));
        assertTrue(RevertInfo.looksUnimplemented(i));
    }

    function test_revertInfo_wrappedPanic_andTruncated() public pure {
        bytes memory inner = abi.encodeWithSelector(RevertInfo.PANIC_SELECTOR, uint256(0x11));
        bytes memory wrapped = abi.encodeWithSelector(
            CustomRevert.WrappedError.selector, address(0xABCD), IHooks.beforeSwap.selector, inner, abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
        RevertInfo.Info memory i = RevertInfo.decode(wrapped);
        assertTrue(i.wrapped);
        assertEq(i.target, address(0xABCD));
        assertEq(i.callback, IHooks.beforeSwap.selector);
        assertEq(uint8(i.kind), uint8(RevertInfo.Kind.PANIC));
        assertEq(i.panicCode, 0x11);
        // every truncation of it decodes to something without reverting
        for (uint256 n; n < wrapped.length; n += 7) {
            RevertInfo.decode(SafeCall.slice(wrapped, 0, n));
        }
    }

    function test_revertInfo_untrustedTextIsSanitised() public {
        address nasty = address(new NastyStringHook());
        SafeCall.Result memory res = SafeCall.call(nasty, 0, 1_000_000, hex"12345678", 1024);
        bytes memory text = bytes(RevertInfo.decode(res.ret).text);
        for (uint256 k; k < text.length; k++) {
            uint8 c = uint8(text[k]);
            assertTrue(c >= 0x20 && c < 0x7f, "printable ASCII only");
        }
        // the checker's own frame is Error(`...`); what the hook supplied sits between the two backticks
        assertEq(string(text), "Error(`?pipe??tick??tag??????quote? ?????? end`)", "everything outside the whitelist is replaced");
    }

    /// @dev L-1: the whitelist, character by character. Only letters, digits, space and . , : ; ' - + = / % @ &
    ///      survive; in particular nothing markdown gives a meaning to.
    function test_revertInfo_asciiWhitelist() public pure {
        bytes memory all = new bytes(256);
        for (uint256 k; k < 256; k++) {
            all[k] = bytes1(uint8(k));
        }
        bytes memory out = RevertInfo.ascii(all);
        assertEq(out.length, 256);
        bytes memory kept = bytes(" %&'+,-./0123456789:;=@ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz");
        uint256 q;
        for (uint256 k; k < 256; k++) {
            if (q < kept.length && uint8(kept[q]) == k) {
                assertEq(uint8(out[k]), k, "kept as is");
                q++;
            } else {
                assertEq(out[k], bytes1("?"), "replaced");
            }
        }
        assertEq(q, kept.length, "the kept set is exactly the documented one");
        bytes memory md = RevertInfo.ascii("[x](y) ![i](z) **b** _e_ # ~s~ `c` <t> a|b \\");
        for (uint256 k; k < md.length; k++) {
            bytes1 c = md[k];
            assertTrue(
                c != "[" && c != "]" && c != "(" && c != ")" && c != "!" && c != "*" && c != "_" && c != "#" && c != "~" && c != "`"
                    && c != "<" && c != ">" && c != "|" && c != "\\",
                "no markdown punctuation survives"
            );
        }
    }

    /// @dev the flag records a SHAPE (used for a display note); nothing is decided on it (audit N-2:
    ///      test_N2_* in Reaudit2Regression.t.sol)
    function test_revertInfo_cheatcodeErrorIsFlagged() public pure {
        RevertInfo.Info memory i = RevertInfo.decode(abi.encodeWithSignature("CheatcodeError(string)", "no cheatcode access"));
        assertTrue(i.cheatcode, "shaped like Foundry's CheatcodeError");
        assertFalse(RevertInfo.decode(abi.encodeWithSignature("Error(string)", "x")).cheatcode);
        // wrapped by PoolManager around a hook callback: that is the hook's revert, not the checker's tooling
        bytes memory wrapped = abi.encodeWithSelector(
            CustomRevert.WrappedError.selector, address(0xBEEF), IHooks.beforeSwap.selector,
            abi.encodeWithSignature("CheatcodeError(string)", "x"), abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
        assertFalse(RevertInfo.decode(wrapped).cheatcode, "only the OUTERMOST revert counts");
    }

    function testFuzz_revertInfo_decodeNeverReverts(bytes memory data) public pure {
        RevertInfo.Info memory i = RevertInfo.decode(data);
        assertGt(bytes(i.text).length, 0);
    }

    /// @dev random bytes behind a real WrappedError selector: the nested-decoding path
    function testFuzz_revertInfo_wrappedGarbageNeverReverts(bytes memory tail) public pure {
        RevertInfo.decode(abi.encodePacked(CustomRevert.WrappedError.selector, tail));
    }

    // --- BytecodeScan -----------------------------------------------------------------------------

    function test_scan_skipsPushData() public pure {
        // PUSH2 0xf4ff (data, must be skipped), STOP
        BytecodeScan.Ops memory ops = BytecodeScan.scan(hex"61f4ff00");
        assertFalse(ops.delegatecall);
        assertFalse(ops.selfdestruct);
        assertTrue(BytecodeScan.cannotChangeState(ops));
        // PUSH1 0x00, DELEGATECALL
        ops = BytecodeScan.scan(hex"6000f4");
        assertTrue(ops.delegatecall);
        assertFalse(BytecodeScan.cannotChangeState(ops));
        // a PUSH32 cut off by the end of the code must not run past it
        BytecodeScan.scan(hex"7f0102");
    }

    function test_scan_eachOpcode() public pure {
        assertTrue(BytecodeScan.scan(hex"55").sstore);
        assertTrue(BytecodeScan.scan(hex"5d").tstore);
        assertTrue(BytecodeScan.scan(hex"a2").log);
        assertTrue(BytecodeScan.scan(hex"f0").create);
        assertTrue(BytecodeScan.scan(hex"f5").create);
        assertTrue(BytecodeScan.scan(hex"f1").call);
        assertTrue(BytecodeScan.scan(hex"f2").callcode);
        assertTrue(BytecodeScan.scan(hex"ff").selfdestruct);
        assertTrue(BytecodeScan.cannotChangeState(BytecodeScan.scan(hex"fa5450")), "STATICCALL, SLOAD, POP change nothing");
    }

    /// @dev M-3: `scan` sweeps everything; only `scanCodePart` (hint wording) stops at a trailer shape
    function test_scan_fullSweepIncludesMetadataShapedTrailer() public pure {
        // STOP, then a CBOR-map-shaped 6 bytes that contain 0xf4, then their length 0x0006
        bytes memory code = hex"00a1f4f4f4f4f40006";
        BytecodeScan.Ops memory full = BytecodeScan.scan(code);
        assertEq(full.scannedLength, 9, "every byte");
        assertTrue(full.delegatecall, "seen by the full sweep");
        assertTrue(full.log, "the CBOR map header 0xa1 reads as LOG1: a known false positive of a full sweep");
        assertFalse(BytecodeScan.cannotChangeState(full));
        BytecodeScan.Ops memory part = BytecodeScan.scanCodePart(code);
        assertEq(part.scannedLength, 1);
        assertFalse(part.delegatecall);
        assertEq(BytecodeScan.trailerLength(code), 8);
        assertEq(BytecodeScan.trailerLength(hex"6000"), 0);
    }

    /// @dev consequence, pinned: for solc output WITH a metadata trailer the full sweep always sees a
    ///      "LOG" (the trailer's first byte), so cannotChangeState is false for it
    function test_scan_solcOutputWithTrailerIsNeverStateless() public view {
        bytes memory code = address(r).code;
        assertGt(BytecodeScan.trailerLength(code), 0, "this build appends a (short) metadata trailer");
        assertTrue(BytecodeScan.scan(code).log);
        assertFalse(BytecodeScan.cannotChangeState(BytecodeScan.scan(code)));
    }

    function test_scan_selectorsOfARealContract() public view {
        bytes memory code = address(r).code;
        assertTrue(BytecodeScan.pushesSelector(code, Reverter.panic.selector));
        assertTrue(BytecodeScan.pushesSelector(code, Reverter.ok.selector));
        assertFalse(BytecodeScan.pushesSelector(code, IHooks.beforeRemoveLiquidity.selector));
    }

    function test_scan_minimalProxy() public pure {
        bytes memory code = abi.encodePacked(
            hex"363d3d373d3d3d363d73", address(0x00C0FfEE00000000000000000000000000000001), hex"5af43d82803e903d91602b57fd5bf3"
        );
        assertEq(BytecodeScan.minimalProxyTarget(code), address(0x00C0FfEE00000000000000000000000000000001));
        assertEq(BytecodeScan.minimalProxyTarget(hex"6000"), address(0));
    }

    function testFuzz_scan_neverReverts(bytes memory code, bytes4 sel) public pure {
        BytecodeScan.Ops memory ops = BytecodeScan.scan(code);
        assertLe(ops.scannedLength, code.length);
        BytecodeScan.pushesSelector(code, sel);
        BytecodeScan.minimalProxyTarget(code);
    }

    // --- a fact the README's safety note relies on -------------------------------------------------

    /// @dev In a NON-fork test any contract can call cheatcodes, including code placed with vm.etch.
    ///      (On a fork Foundry refuses that: test/fork/ForkChecker.t.sol.) Hence the README's rule:
    ///      third-party hooks are checked through the fork entry, never by deploying their bytecode in
    ///      a plain local test.
    function test_local_etchedCodeCanCallCheatcodes() public {
        address foreign = address(0xF0F0F0);
        vm.etch(foreign, type(CheatcodeCaller).runtimeCode);
        uint256 t = block.timestamp;
        (bool ok,) = foreign.call(abi.encodeCall(CheatcodeCaller.warp, (t + 1000)));
        assertTrue(ok);
        assertEq(block.timestamp, t + 1000);
    }

    // --- CheckerRouter, Lines ---------------------------------------------------------------------

    function test_router_onlyItsDeployer() public {
        IPoolManager manager = new PoolManager(address(this));
        CheckerRouter router = new CheckerRouter(manager);
        PoolKey memory key = PoolKey(Currency.wrap(address(1)), Currency.wrap(address(2)), 3000, 60, IHooks(address(0)));
        vm.startPrank(address(0xBAD));
        vm.expectRevert(CheckerRouter.NotOwner.selector);
        router.initialize(key, 2 ** 96);
        vm.expectRevert(CheckerRouter.NotOwner.selector);
        router.swap(key, SwapParams(true, -1, 4295128740), "");
        vm.expectRevert(CheckerRouter.NotOwner.selector);
        router.modifyLiquidity(key, ModifyLiquidityParams(-60, 60, 1, 0), "");
        vm.expectRevert(CheckerRouter.NotOwner.selector);
        router.donate(key, 1, 1, "");
        vm.expectRevert(CheckerRouter.NotManager.selector);
        router.unlockCallback("");
        vm.stopPrank();
    }

    function test_lines_capped() public pure {
        Lines memory l = LinesLib.make();
        for (uint256 i; i < 500; i++) {
            LinesLib.add(l, "x");
        }
        string[] memory out = LinesLib.done(l);
        assertEq(out.length, LinesLib.CAP);
        assertEq(out[out.length - 1], "... (further lines dropped)");
    }
}
