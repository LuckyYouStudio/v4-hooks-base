// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SafeCall} from "./SafeCall.sol";

/// @title RevertInfo
/// @notice Turns (possibly truncated, possibly garbage) revert data into something a report can show,
///         and answers the one question the checks need: did the revert come out of a hook callback
///         (v4 wraps those as ERC-7751 `WrappedError(target, selector, reason, details)`), and if so
///         from which callback and with what kind of reason. Hand-rolled bounds-checked decoding: the
///         input is attacker-controlled, `abi.decode` would revert on malformed data.
///         All selectors are taken from the pinned v4-core sources, none is typed in by hand.
library RevertInfo {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    enum Kind {
        NONE, // no revert
        EMPTY, // revert without data: bare revert(), missing function, failed require() without message,
        //        or out of gas inside a sub-call
        PANIC, // Solidity Panic(uint256): overflow, division by zero, bad array index, failed assert ...
        ERROR_STRING, // Error(string): require(cond, "message")
        CUSTOM // a custom error (selector + arguments)

    }

    struct Info {
        Kind kind; // kind of the innermost reason
        bytes4 outer; // selector of the outermost revert data (0 when empty)
        bool wrapped; // outermost revert is a v4 WrappedError
        address target; // WrappedError.target (the contract PoolManager was calling)
        bytes4 callback; // WrappedError.selector (the function PoolManager was calling)
        bytes4 inner; // selector of the innermost reason (== outer when not wrapped)
        uint256 panicCode;
        string text; // human readable, ASCII only
        /// the outermost revert data has the SHAPE of Foundry's CheatcodeError(string). A shape only: any
        /// contract can revert with these bytes (a pool token's balanceOf revert reaches the outermost level
        /// unwrapped), so nothing is decided on it; it is shown with a note.
        bool cheatcode;
    }

    bytes4 internal constant ERROR_STRING_SELECTOR = 0x08c379a0; // Error(string)
    bytes4 internal constant PANIC_SELECTOR = 0x4e487b71; // Panic(uint256)
    /// @dev declared with this exact signature by v4-core's BaseTestHooks, by OpenZeppelin's BaseHook, by
    ///      the former v4-periphery BaseHook and by this repo's BaseHook
    bytes4 internal constant HOOK_NOT_IMPLEMENTED = bytes4(keccak256("HookNotImplemented()"));
    /// @dev how Foundry reports a failed cheatcode (forge-std StdChains.sol spells out the same signature).
    ///      Used for a display note only.
    bytes4 internal constant CHEATCODE_ERROR = bytes4(keccak256("CheatcodeError(string)"));

    function decode(bytes memory ret) internal pure returns (Info memory info) {
        if (ret.length < 4) {
            info.kind = Kind.EMPTY;
            info.text = ret.length == 0 ? "empty revert data" : "revert data shorter than a selector";
            return info;
        }
        info.outer = SafeCall.selector(ret);
        info.cheatcode = info.outer == CHEATCODE_ERROR;
        bytes memory reason = ret;
        string memory prefix = "";
        // unwrap up to 3 nested WrappedErrors; attribution uses the outermost one
        for (uint256 depth; depth < 3; depth++) {
            if (SafeCall.selector(reason) != CustomRevert.WrappedError.selector) break;
            (bool okT, bytes32 t) = SafeCall.wordAt(reason, 4);
            (bool okS, bytes32 s) = SafeCall.wordAt(reason, 0x24);
            (bool okO, bytes32 off) = SafeCall.wordAt(reason, 0x44);
            if (!okT || !okS || !okO) break;
            (bool okL, bytes32 len) = SafeCall.wordAt(reason, 4 + uint256(off));
            if (!okL) break;
            if (depth == 0) {
                info.wrapped = true;
                info.target = address(uint160(uint256(t)));
                info.callback = bytes4(s);
            }
            prefix = string.concat(
                prefix, "WrappedError{", callbackName(bytes4(s)), " on ", vm.toString(address(uint160(uint256(t)))), "}: "
            );
            reason = SafeCall.slice(reason, 4 + uint256(off) + 32, uint256(len));
        }
        info.inner = SafeCall.selector(reason);
        if (reason.length < 4) {
            info.kind = Kind.EMPTY;
            info.text = string.concat(prefix, "empty revert data");
        } else if (info.inner == PANIC_SELECTOR) {
            info.kind = Kind.PANIC;
            (, bytes32 code) = SafeCall.wordAt(reason, 4);
            info.panicCode = uint256(code);
            info.text = string.concat(prefix, "Panic(", panicName(uint256(code)), ")");
        } else if (info.inner == ERROR_STRING_SELECTOR) {
            info.kind = Kind.ERROR_STRING;
            // the string is untrusted: whitelisted characters only, and inside a code span so that what
            // is left of it (a bare URL, say) is not rendered as markdown
            info.text = string.concat(prefix, "Error(`", _errorString(reason), "`)");
        } else {
            info.kind = Kind.CUSTOM;
            info.text = string.concat(prefix, errorName(info.inner));
            if (reason.length > 4) {
                info.text = string.concat(info.text, " +", vm.toString(reason.length - 4), "B args");
            }
        }
    }

    /// @dev True when the innermost reason says "this function does not exist / is a stub".
    function looksUnimplemented(Info memory info) internal pure returns (bool) {
        return info.kind == Kind.EMPTY || (info.kind == Kind.CUSTOM && info.inner == HOOK_NOT_IMPLEMENTED);
    }

    function _errorString(bytes memory reason) private pure returns (string memory) {
        (bool okO, bytes32 off) = SafeCall.wordAt(reason, 4);
        if (!okO) return "?";
        (bool okL, bytes32 len) = SafeCall.wordAt(reason, 4 + uint256(off));
        if (!okL) return "?";
        bytes memory raw = SafeCall.slice(reason, 4 + uint256(off) + 32, uint256(len) > 96 ? 96 : uint256(len));
        return string(ascii(raw));
    }

    /// @dev Whitelist for text that comes from the contract under test (revert strings): letters, digits,
    ///      space and  . , : ; ' - + = / % @ &  are kept, EVERYTHING else becomes '?'. In particular none
    ///      of the characters markdown gives a meaning to survives ([ ] ( ) ! * _ # ~ \ ` < > |), nor a
    ///      double quote, nor anything outside printable ASCII.
    function ascii(bytes memory raw) internal pure returns (bytes memory out) {
        out = new bytes(raw.length);
        for (uint256 i; i < raw.length; i++) {
            bytes1 c = raw[i];
            bool fine = (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == " " || c == "."
                || c == "," || c == ":" || c == ";" || c == "'" || c == "-" || c == "+" || c == "=" || c == "/" || c == "%"
                || c == "@" || c == "&";
            out[i] = fine ? c : bytes1("?");
        }
    }

    function panicName(uint256 code) internal pure returns (string memory) {
        if (code == 0x01) return "0x01 assert";
        if (code == 0x11) return "0x11 arithmetic overflow/underflow";
        if (code == 0x12) return "0x12 division by zero";
        if (code == 0x21) return "0x21 bad enum value";
        if (code == 0x22) return "0x22 bad storage byte array";
        if (code == 0x31) return "0x31 pop on empty array";
        if (code == 0x32) return "0x32 array index out of bounds";
        if (code == 0x41) return "0x41 out of memory";
        if (code == 0x51) return "0x51 zero function pointer";
        return vm.toString(bytes32(code));
    }

    function callbackName(bytes4 s) internal pure returns (string memory) {
        if (s == IHooks.beforeInitialize.selector) return "beforeInitialize";
        if (s == IHooks.afterInitialize.selector) return "afterInitialize";
        if (s == IHooks.beforeAddLiquidity.selector) return "beforeAddLiquidity";
        if (s == IHooks.afterAddLiquidity.selector) return "afterAddLiquidity";
        if (s == IHooks.beforeRemoveLiquidity.selector) return "beforeRemoveLiquidity";
        if (s == IHooks.afterRemoveLiquidity.selector) return "afterRemoveLiquidity";
        if (s == IHooks.beforeSwap.selector) return "beforeSwap";
        if (s == IHooks.afterSwap.selector) return "afterSwap";
        if (s == IHooks.beforeDonate.selector) return "beforeDonate";
        if (s == IHooks.afterDonate.selector) return "afterDonate";
        return sel(s);
    }

    /// @dev Names for the v4-core errors a check can meet; anything else is printed as its selector.
    function errorName(bytes4 s) internal pure returns (string memory) {
        if (s == HOOK_NOT_IMPLEMENTED) return "HookNotImplemented()";
        if (s == CHEATCODE_ERROR) return "CheatcodeError(string)";
        // names used by the common hook base contracts (labels for selectors, hashed from the signature)
        if (s == bytes4(keccak256("NotPoolManager()"))) return "NotPoolManager()";
        if (s == bytes4(keccak256("InvalidPool()"))) return "InvalidPool()";
        if (s == bytes4(keccak256("NotSelf()"))) return "NotSelf()";
        if (s == bytes4(keccak256("LockFailure()"))) return "LockFailure()";
        if (s == Hooks.HookAddressNotValid.selector) return "HookAddressNotValid(address)";
        if (s == Hooks.InvalidHookResponse.selector) return "InvalidHookResponse()";
        if (s == Hooks.HookCallFailed.selector) return "HookCallFailed()";
        if (s == Hooks.HookDeltaExceedsSwapAmount.selector) return "HookDeltaExceedsSwapAmount()";
        if (s == IPoolManager.CurrencyNotSettled.selector) return "CurrencyNotSettled()";
        if (s == IPoolManager.PoolNotInitialized.selector) return "PoolNotInitialized()";
        if (s == IPoolManager.AlreadyUnlocked.selector) return "AlreadyUnlocked()";
        if (s == IPoolManager.ManagerLocked.selector) return "ManagerLocked()";
        if (s == IPoolManager.TickSpacingTooLarge.selector) return "TickSpacingTooLarge(int24)";
        if (s == IPoolManager.TickSpacingTooSmall.selector) return "TickSpacingTooSmall(int24)";
        if (s == IPoolManager.CurrenciesOutOfOrderOrEqual.selector) return "CurrenciesOutOfOrderOrEqual(address,address)";
        if (s == IPoolManager.UnauthorizedDynamicLPFeeUpdate.selector) return "UnauthorizedDynamicLPFeeUpdate()";
        if (s == IPoolManager.SwapAmountCannotBeZero.selector) return "SwapAmountCannotBeZero()";
        if (s == IPoolManager.NonzeroNativeValue.selector) return "NonzeroNativeValue()";
        if (s == LPFeeLibrary.LPFeeTooLarge.selector) return "LPFeeTooLarge(uint24)";
        if (s == Pool.PoolAlreadyInitialized.selector) return "PoolAlreadyInitialized()";
        if (s == Pool.PriceLimitAlreadyExceeded.selector) return "PriceLimitAlreadyExceeded(uint160,uint160)";
        if (s == Pool.PriceLimitOutOfBounds.selector) return "PriceLimitOutOfBounds(uint160)";
        if (s == Pool.NoLiquidityToReceiveFees.selector) return "NoLiquidityToReceiveFees()";
        if (s == Pool.InvalidFeeForExactOut.selector) return "InvalidFeeForExactOut()";
        if (s == Pool.TicksMisordered.selector) return "TicksMisordered(int24,int24)";
        if (s == Position.CannotUpdateEmptyPosition.selector) return "CannotUpdateEmptyPosition()";
        if (s == SafeCast.SafeCastOverflow.selector) return "SafeCastOverflow()";
        if (s == TickMath.InvalidTick.selector) return "InvalidTick(int24)";
        if (s == TickMath.InvalidSqrtPrice.selector) return "InvalidSqrtPrice(uint160)";
        if (s == CurrencyLibrary.ERC20TransferFailed.selector) return "ERC20TransferFailed()";
        if (s == CurrencyLibrary.NativeTransferFailed.selector) return "NativeTransferFailed()";
        return string.concat("custom error ", sel(s));
    }

    function sel(bytes4 s) internal pure returns (string memory) {
        bytes memory full = bytes(vm.toString(bytes32(s))); // 0x + 64 hex chars
        bytes memory out = new bytes(10);
        for (uint256 i; i < 10; i++) {
            out[i] = full[i];
        }
        return string(out);
    }
}
