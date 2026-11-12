// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SafeCall
/// @notice Calls into code the checker does not trust (the hook under test, tokens on a fork, and the
///         checker's own operations that pass through the hook). Every call has a gas cap and copies at
///         most `maxRet` bytes of return data, so a target that reverts, returns garbage, returns a huge
///         blob ("return bomb") or spins until it runs out of gas costs a bounded amount and never makes
///         the checker itself revert.
library SafeCall {
    /// @param ok       the call did not revert
    /// @param ret      the first min(retSize, maxRet) bytes of return / revert data
    /// @param retSize  the full RETURNDATASIZE (can be far larger than ret.length)
    /// @param gasUsed  gas consumed by the call, measured around the CALL opcode
    struct Result {
        bool ok;
        bytes ret;
        uint256 retSize;
        uint256 gasUsed;
    }

    function call(address target, uint256 value, uint256 gasCap, bytes memory data, uint256 maxRet)
        internal
        returns (Result memory r)
    {
        bool ok;
        bytes memory ret;
        uint256 retSize;
        uint256 gasUsed;
        assembly ("memory-safe") {
            let g := gas()
            ok := call(gasCap, target, value, add(data, 0x20), mload(data), 0, 0)
            gasUsed := sub(g, gas())
            retSize := returndatasize()
            let n := retSize
            if gt(n, maxRet) { n := maxRet }
            ret := mload(0x40)
            mstore(ret, n)
            returndatacopy(add(ret, 0x20), 0, n)
            mstore(0x40, and(add(add(ret, 0x3f), n), not(0x1f)))
        }
        r.ok = ok;
        r.ret = ret;
        r.retSize = retSize;
        r.gasUsed = gasUsed;
    }

    function staticcall(address target, uint256 gasCap, bytes memory data, uint256 maxRet)
        internal
        view
        returns (Result memory r)
    {
        bool ok;
        bytes memory ret;
        uint256 retSize;
        uint256 gasUsed;
        assembly ("memory-safe") {
            let g := gas()
            ok := staticcall(gasCap, target, add(data, 0x20), mload(data), 0, 0)
            gasUsed := sub(g, gas())
            retSize := returndatasize()
            let n := retSize
            if gt(n, maxRet) { n := maxRet }
            ret := mload(0x40)
            mstore(ret, n)
            returndatacopy(add(ret, 0x20), 0, n)
            mstore(0x40, and(add(add(ret, 0x3f), n), not(0x1f)))
        }
        r.ok = ok;
        r.ret = ret;
        r.retSize = retSize;
        r.gasUsed = gasUsed;
    }

    /// @dev True when a failed call most likely died of gas exhaustion: no revert data and (nearly) the
    ///      whole cap was spent. A heuristic: `INVALID` also burns everything.
    function looksOutOfGas(Result memory r, uint256 gasCap) internal pure returns (bool) {
        return !r.ok && r.retSize == 0 && r.gasUsed >= gasCap - gasCap / 32;
    }

    /// @dev First 32-byte word of the (possibly truncated) return data, 0 if shorter.
    function word0(Result memory r) internal pure returns (bytes32 w) {
        bytes memory ret = r.ret;
        if (ret.length >= 32) {
            assembly ("memory-safe") {
                w := mload(add(ret, 0x20))
            }
        }
    }

    function selector(bytes memory data) internal pure returns (bytes4 s) {
        if (data.length >= 4) {
            assembly ("memory-safe") {
                s := mload(add(data, 0x20))
            }
        }
    }

    /// @dev Reads the 32-byte word at `offset` of `data`; (false, 0) if out of bounds. Never reverts.
    function wordAt(bytes memory data, uint256 offset) internal pure returns (bool inBounds, bytes32 w) {
        if (offset > type(uint128).max || data.length < offset + 32) return (false, 0);
        assembly ("memory-safe") {
            w := mload(add(add(data, 0x20), offset))
        }
        return (true, w);
    }

    /// @dev data[start : start+len], clipped to the available bytes. Never reverts.
    function slice(bytes memory data, uint256 start, uint256 len) internal pure returns (bytes memory out) {
        if (start >= data.length) return new bytes(0);
        if (len > data.length - start) len = data.length - start;
        out = new bytes(len);
        for (uint256 i; i < len; i++) {
            out[i] = data[start + i];
        }
    }
}
