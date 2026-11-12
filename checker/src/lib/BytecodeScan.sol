// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title BytecodeScan
/// @notice Linear sweep over runtime bytecode that skips PUSH immediates. Answers "does opcode X occur"
///         and "is this 4-byte selector pushed anywhere". HINTS ONLY:
///         - `scan` sweeps EVERY byte, including data the compiler placed after the code (constant
///           tables, the CBOR metadata trailer). A data byte may read as an opcode -> false positives
///           (the first byte of a Solidity metadata trailer, 0xa1..0xa4, reads as LOG1..LOG4);
///         - nothing is cut off for a statement in the "nothing found" direction: bytes shaped like a
///           metadata trailer can hold reachable code (a JUMPDEST inside it is a valid jump target).
///           `scanCodePart` (trailer cut) exists only to WORD a hint ("occurs only in what looks like
///           the trailer"); no PASS may rest on it;
///         - an opcode that occurs may be unreachable, or reachable only by the deployer;
///         - a contract can reach foreign code without DELEGATECALL in its own bytecode only through a
///           proxy in front of it, which is what the EIP-1967 slot check is for.
library BytecodeScan {
    struct Ops {
        bool sstore; // 0x55
        bool tstore; // 0x5d
        bool log; // 0xa0-0xa4
        bool create; // 0xf0, 0xf5
        bool call; // 0xf1
        bool callcode; // 0xf2
        bool delegatecall; // 0xf4
        bool selfdestruct; // 0xff
        uint256 scannedLength; // bytes swept
    }

    /// @notice Full sweep: every byte of `code`, metadata-shaped trailer included.
    function scan(bytes memory code) internal pure returns (Ops memory ops) {
        return _sweep(code, code.length);
    }

    /// @notice Sweep that stops where a Solidity-CBOR-shaped trailer starts. For wording hints only.
    function scanCodePart(bytes memory code) internal pure returns (Ops memory ops) {
        return _sweep(code, _codeEnd(code));
    }

    /// @notice Length of the part at the end of `code` that is shaped like a Solidity metadata trailer
    ///         (0 if none). Shape only: says nothing about whether those bytes are data or code.
    function trailerLength(bytes memory code) internal pure returns (uint256) {
        return code.length - _codeEnd(code);
    }

    function _sweep(bytes memory code, uint256 end) private pure returns (Ops memory ops) {
        ops.scannedLength = end;
        for (uint256 i; i < end; i++) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f; // PUSH1..PUSH32 immediates
            } else if (op == 0x55) {
                ops.sstore = true;
            } else if (op == 0x5d) {
                ops.tstore = true;
            } else if (op >= 0xa0 && op <= 0xa4) {
                ops.log = true;
            } else if (op == 0xf0 || op == 0xf5) {
                ops.create = true;
            } else if (op == 0xf1) {
                ops.call = true;
            } else if (op == 0xf2) {
                ops.callcode = true;
            } else if (op == 0xf4) {
                ops.delegatecall = true;
            } else if (op == 0xff) {
                ops.selfdestruct = true;
            }
        }
    }

    /// @dev True when none of SSTORE / TSTORE / LOGn / CREATE(2) / CALL / CALLCODE / DELEGATECALL /
    ///      SELFDESTRUCT occurs in `ops`. Meaningful ONLY for the result of the full `scan`: execution
    ///      starts at byte 0 and can only continue sequentially or jump to a JUMPDEST that the same
    ///      linear sweep sees as an instruction, so an opcode that is absent from a full sweep is never
    ///      executed by this code. Under that condition, a call into this code does not write storage,
    ///      emit events, move ETH, create contracts or call out other than by STATICCALL. It says nothing
    ///      about what the code returns, and nothing if `ops` came from `scanCodePart`.
    function cannotChangeState(Ops memory ops) internal pure returns (bool) {
        return !(ops.sstore || ops.tstore || ops.log || ops.create || ops.call || ops.callcode || ops.delegatecall
                || ops.selfdestruct);
    }

    /// @dev True when `PUSH4 <selector>` occurs anywhere (full sweep; how solc / vyper dispatch tables
    ///      compare selectors). A contract with a hand-written or packed dispatcher may implement a
    ///      function without it.
    function pushesSelector(bytes memory code, bytes4 selector) internal pure returns (bool) {
        uint256 end = code.length;
        for (uint256 i; i < end; i++) {
            uint8 op = uint8(code[i]);
            if (op == 0x63 && i + 4 < code.length) {
                if (
                    code[i + 1] == selector[0] && code[i + 2] == selector[1] && code[i + 3] == selector[2]
                        && code[i + 4] == selector[3]
                ) return true;
            }
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
        }
        return false;
    }

    /// @dev EIP-1167 minimal proxy: 363d3d373d3d3d363d73 <20-byte impl> 5af43d82803e903d91602b57fd5bf3
    function minimalProxyTarget(bytes memory code) internal pure returns (address impl) {
        if (code.length != 45) return address(0);
        bytes10 head;
        assembly ("memory-safe") {
            head := mload(add(code, 0x20))
        }
        if (head != 0x363d3d373d3d3d363d73) return address(0);
        assembly ("memory-safe") {
            impl := shr(96, mload(add(code, 0x2a)))
        }
    }

    /// @dev Where a Solidity-CBOR-shaped trailer starts: the last two bytes hold its length and it starts
    ///      with a CBOR map header (0xa1..0xa4). `code.length` if there is no such shape. The shape is
    ///      trivially forged, which is why only `scanCodePart` (hint wording) uses this.
    function _codeEnd(bytes memory code) private pure returns (uint256) {
        uint256 n = code.length;
        if (n < 4) return n;
        uint256 metaLen = (uint256(uint8(code[n - 2])) << 8) | uint256(uint8(code[n - 1]));
        if (metaLen + 2 > n || metaLen < 4 || metaLen > 128) return n;
        uint8 head = uint8(code[n - 2 - metaLen]);
        if (head < 0xa1 || head > 0xa4) return n;
        return n - 2 - metaLen;
    }
}
