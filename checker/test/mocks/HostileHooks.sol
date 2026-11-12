// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Hostile / broken "hooks" for the checker's robustness tests. They are placed at arbitrary flag
// addresses with vm.etch. Test-only, never deployed anywhere.

/// @dev answers every call with pseudo-random bytes of a length derived from the calldata
contract GarbageHook {
    fallback() external {
        bytes32 seed = keccak256(msg.data);
        uint256 len = (uint256(seed) % 7) * 23; // 0, 23, 46, ... 138 bytes: never a clean ABI answer
        bytes memory out = new bytes(len);
        for (uint256 i; i < len; i++) {
            out[i] = seed[i % 32];
        }
        assembly {
            return(add(out, 0x20), mload(out))
        }
    }
}

/// @dev answers every call with 2 MB of zeros
contract ReturnBombHook {
    fallback() external {
        assembly {
            return(0, 0x200000)
        }
    }
}

/// @dev reverts every call with 2 MB of revert data
contract RevertBombHook {
    fallback() external {
        assembly {
            revert(0, 0x200000)
        }
    }
}

/// @dev never returns
contract GasBurnerHook {
    fallback() external {
        uint256 x;
        while (true) {
            unchecked {
                x++;
            }
        }
    }
}

/// @dev INVALID opcode: consumes all gas given, no revert data
contract InvalidOpcodeHook {
    fallback() external {
        assembly {
            invalid()
        }
    }
}

/// @dev answers every call with its own selector as one 32-byte word: valid for the 32-byte callbacks,
///      wrong length for beforeSwap (96) and for the return-delta callbacks (64)
contract EchoSelectorHook {
    fallback() external {
        assembly {
            mstore(0, and(calldataload(0), 0xffffffff00000000000000000000000000000000000000000000000000000000))
            return(0, 0x20)
        }
    }
}

/// @dev reverts with a revert string full of characters a report must not echo verbatim
contract NastyStringHook {
    fallback() external {
        revert(string(abi.encodePacked("|pipe|`tick`<tag>\n\r", bytes1(0xff), bytes1(0x00), "\"quote\" ", unicode"漏洞", " end")));
    }
}

/// @dev emits many events and writes many slots, then answers with its selector
contract NoisyHook {
    event Noise(uint256 indexed i, bytes32 data);

    uint256[] internal junk;

    fallback() external {
        for (uint256 i; i < 300; i++) {
            emit Noise(i, keccak256(abi.encode(i)));
            junk.push(i);
        }
        assembly {
            mstore(0, and(calldataload(0), 0xffffffff00000000000000000000000000000000000000000000000000000000))
            return(0, 0x20)
        }
    }
}

/// @dev works for the first `budget` calls, then reverts with a truncated WrappedError-looking blob
contract FlakyHook {
    uint256 public calls;

    fallback() external {
        calls++;
        if (calls > 6) {
            assembly {
                mstore(0, 0x90bfb86500000000000000000000000000000000000000000000000000000000)
                revert(0, 0x1c)
            }
        }
        assembly {
            mstore(0, and(calldataload(0), 0xffffffff00000000000000000000000000000000000000000000000000000000))
            return(0, 0x20)
        }
    }
}

/// @dev No caller check at all, but the callback insists on one exact hookData value before it does
///      anything. The checker's probes do not know the value, so all they see is a revert.
contract StrictHookDataHook {
    uint256 public hits;

    error BadHookData();

    fallback() external {
        // the last 32 bytes of every IHooks call that carries hookData are the tail of hookData
        bytes32 tail;
        assembly {
            tail := calldataload(sub(calldatasize(), 0x20))
        }
        if (tail != keccak256("open sesame")) revert BadHookData();
        hits++;
        assembly {
            mstore(0, and(calldataload(0), 0xffffffff00000000000000000000000000000000000000000000000000000000))
            return(0, 0x20)
        }
    }
}
