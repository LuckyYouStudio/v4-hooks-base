// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Result of one check. README maps them: PASS 通过 / FAIL 失败 / NA 不适用 / UNKNOWN 无法判定(需人工).
enum Status {
    PASS,
    FAIL,
    NA,
    UNKNOWN
}

struct Finding {
    string id; // "a" .. "i"
    string title;
    Status status;
    string summary; // one line: the basis of the status
    string[] details; // evidence lines
}

struct Report {
    address hook;
    address manager;
    uint256 chainId;
    uint256 blockNumber;
    uint256 timestamp;
    uint256 codeSize;
    uint160 flags; // low 14 bits of the hook address
    string[] setup; // how the test pool was obtained, what could not be set up
    Finding[] findings; // always 9 entries, in the order a..i (see HookChecker)
    /// true: the run itself was compromised (e.g. the active fork changed under the checker). Every
    /// finding is then UNKNOWN and nothing in the report may be read as a result.
    bool voided;
    string voidReason;
}

struct CheckConfig {
    /// the PoolManager the hook is bound to (a local one, or the real one on a fork)
    IPoolManager manager;
    address hook;
    /// false: the checker creates its own pool with two fresh mock tokens (tries dynamic fee first)
    /// true:  use `key` (an existing pool on a fork, or a pool the checker should initialize itself)
    bool hasKey;
    PoolKey key;
    /// own-pool mode only: use native ETH (address 0) as currency0 instead of a mock token
    bool nativeCurrency0;
}

/// @notice Append-only list of report lines with a hard cap, kept in memory (the checker rolls EVM state
///         back between scenarios, so nothing it learns may live in storage).
struct Lines {
    string[] items;
    uint256 n;
}

library LinesLib {
    uint256 internal constant CAP = 160;

    function make() internal pure returns (Lines memory l) {
        l.items = new string[](CAP);
    }

    function add(Lines memory l, string memory s) internal pure {
        if (l.n < CAP - 1) {
            l.items[l.n++] = s;
        } else if (l.n == CAP - 1) {
            l.items[l.n++] = "... (further lines dropped)";
        }
    }

    function done(Lines memory l) internal pure returns (string[] memory out) {
        out = new string[](l.n);
        for (uint256 i; i < l.n; i++) {
            out[i] = l.items[i];
        }
    }
}
