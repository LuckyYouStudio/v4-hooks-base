// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {SafeCall} from "./lib/SafeCall.sol";
import {RevertInfo} from "./lib/RevertInfo.sol";
import {CheckerRouter} from "./CheckerRouter.sol";

/// @title CheckerOps
/// @notice The checker's hands. Every interaction that can reach the hook under test is an `opXxx`
///         function that the checker calls ON ITSELF through SafeCall with a gas cap, so that a revert,
///         a return bomb or an endless loop inside the hook becomes a recorded result instead of a
///         crash. Local simulation only (forge test on local or forked state): nothing here signs or
///         broadcasts anything.
abstract contract CheckerOps is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev gas given to one PoolManager operation (initialize / modifyLiquidity / swap / donate),
    ///      including everything the hook does inside it. Base blocks are larger than this, so an
    ///      operation that needs more is reported as "gas cap exceeded", not silently accepted.
    uint256 internal constant OP_GAS = 30_000_000;
    /// @dev gas given to one direct call of a hook callback
    uint256 internal constant PROBE_GAS = 10_000_000;
    /// @dev gas for the frame around a probe (the probe itself + reading back the state diff)
    uint256 internal constant PROBE_FRAME_GAS = 80_000_000;
    /// @dev gas for a multi-operation recorded flow (check c)
    uint256 internal constant FLOW_GAS = 2_000_000_000;
    /// @dev gas for a view call into untrusted code
    uint256 internal constant VIEW_GAS = 2_000_000;

    IPoolManager internal _m;
    address internal _hook;
    CheckerRouter internal _lpA;
    CheckerRouter internal _lpB;
    CheckerRouter internal _swapper;
    CheckerRouter internal _stranger;
    /// @dev the environment the run started in: active fork id + 1 (0 = no fork) and chain id. Written
    ///      by runChecks BEFORE its outer state snapshot, so no rollback inside the run touches them.
    uint256 internal _fork0;
    uint256 internal _chain0;
    /// @dev The checker's footing: its own clock. Where block.number and block.timestamp have to be,
    ///      given that only the checker moves them (through _advance). Set by runChecks before its outer
    ///      snapshot; moved inside the run, and rolled back together with the EVM state by every snapshot
    ///      rollback, so the two always agree unless somebody else moved the chain.
    ///      Why a clock and not a marker in chain state: measured on a Base fork with forge 1.9.0, a
    ///      `vm.rollFork` made from inside a nested call (which is where a hook's callback is) leaves
    ///      contracts created during the test in place, storage included, and may or may not reset a pool
    ///      the checker initialized in the PoolManager, depending on what was read and written around the
    ///      roll. Block number and timestamp changed in every case tried - unless the roll goes to the
    ///      very block number and timestamp the clock shows, which this does NOT detect (README).
    uint256 internal _clockN;
    uint256 internal _clockT;

    error OnlySelf();
    error OnlyManager();
    /// @dev how a probe hands its result out of a frame whose state changes must not survive
    error ProbeDone(bytes result);

    struct SwapOut {
        int128 c0; // what the router paid (-) / received (+), i.e. after the hook's delta
        int128 c1;
        int128 p0; // the pool's own amounts, from the Swap event (before the hook's delta)
        int128 p1;
        uint24 fee; // total swap fee in pips from the Swap event (LP fee combined with protocol fee)
        int24 tick;
        bool sawEvent;
    }

    struct OpRes {
        bool ok;
        bool oog; // the whole operation hit the gas cap
        /// the operation failed while a FACT about the environment says the checker's own tooling is broken
        /// (see _toolingBroken): one of the checker's routers or the PoolManager has no code, the fork or
        /// chain changed, block number / timestamp were moved by something else. Decided from the environment only, never from the
        /// shape of the revert data: revert data is under the control of the contracts in the pool.
        bool infra;
        uint256 gasUsed;
        RevertInfo.Info err;
    }

    struct SwapRes {
        OpRes op;
        SwapOut out;
    }

    struct ModRes {
        OpRes op;
        int128 a0; // router's delta: negative = paid in, positive = received
        int128 a1;
    }

    struct Probe {
        bool infraOk; // the probe frame itself worked (false: treat everything else as unknown)
        bool ok; // the hook call did not revert
        bool oog;
        bytes ret; // first 256 bytes
        uint256 retSize;
        uint256 gasUsed;
        uint256 writes; // storage slots (any contract) whose value changed, not counting reverted frames
        uint256 hookWrites; // of those, slots of the hook itself
        bool valueMoved; // ETH transferred, contract created or self-destructed
        uint256 logs; // events emitted
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlySelf();
        _;
    }

    /// @dev routers refund / receive native ETH through here in some flows
    receive() external payable {}

    // ---------------------------------------------------------------------------------------------
    // Operations (external so that they can be called with a gas cap; callable only by the checker)
    // ---------------------------------------------------------------------------------------------

    function opInit(CheckerRouter r, PoolKey calldata key, uint160 sqrtPriceX96) external onlySelf returns (int24) {
        return r.initialize(key, sqrtPriceX96);
    }

    function opModify(CheckerRouter r, PoolKey calldata key, ModifyLiquidityParams calldata p, bytes calldata hookData)
        external
        onlySelf
        returns (int128, int128)
    {
        (BalanceDelta d,) = r.modifyLiquidity(key, p, hookData);
        return (d.amount0(), d.amount1());
    }

    function opSwap(CheckerRouter r, PoolKey calldata key, SwapParams calldata p, bytes calldata hookData)
        external
        onlySelf
        returns (SwapOut memory o)
    {
        vm.recordLogs();
        BalanceDelta d = r.swap(key, p, hookData);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        o.c0 = d.amount0();
        o.c1 = d.amount1();
        bytes32 id = PoolId.unwrap(key.toId());
        bytes32 sender = bytes32(uint256(uint160(address(r))));
        // the last Swap event of this pool whose `sender` is our router (a hook may swap in its own pool)
        for (uint256 i = logs.length; i > 0; i--) {
            Vm.Log memory l = logs[i - 1];
            if (
                l.emitter == address(_m) && l.topics.length == 3 && l.topics[0] == IPoolManager.Swap.selector
                    && l.topics[1] == id && l.topics[2] == sender && l.data.length == 192
            ) {
                (o.p0, o.p1,,, o.tick, o.fee) = abi.decode(l.data, (int128, int128, uint160, uint128, int24, uint24));
                o.sawEvent = true;
                break;
            }
        }
    }

    function opDonate(CheckerRouter r, PoolKey calldata key, uint256 amount0, uint256 amount1, bytes calldata hookData)
        external
        onlySelf
    {
        r.donate(key, amount0, amount1, hookData);
    }

    /// @dev forge-std `deal` for an ERC-20 on a fork; it searches for the balance slot and reverts for
    ///      tokens whose storage layout it cannot find, which is why it runs as a guarded operation
    function opDeal(address token, address to, uint256 amount) external onlySelf {
        deal(token, to, amount);
    }

    /// @notice Calls `data` on the hook as `caller` and reports what happened, then ALWAYS reverts with
    ///         the result, so that whatever the hook did is rolled back.
    /// @param unlocked run the call inside a PoolManager.unlock, the context a callback really runs in
    ///        (a hook that touches PoolManager accounting reverts with ManagerLocked outside of it)
    /// @param origin tx.origin for the call; address(0) leaves tx.origin as it is
    function opProbe(address caller, address origin, bytes calldata data, bool unlocked) external onlySelf {
        if (unlocked) {
            _m.unlock(abi.encode(caller, origin, data)); // -> unlockCallback below, which reverts with the result
        }
        revert ProbeDone(abi.encode(_probeCore(caller, origin, data)));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(_m)) revert OnlyManager();
        (address caller, address origin, bytes memory data) = abi.decode(raw, (address, address, bytes));
        revert ProbeDone(abi.encode(_probeCore(caller, origin, data)));
    }

    function _probeCore(address caller, address origin, bytes memory data) private returns (Probe memory p) {
        vm.recordLogs();
        vm.startStateDiffRecording();
        if (origin == address(0)) vm.prank(caller);
        else vm.prank(caller, origin);
        SafeCall.Result memory r = SafeCall.call(_hook, 0, PROBE_GAS, data, 256);
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        p.logs = vm.getRecordedLogs().length;
        p.ok = r.ok;
        p.oog = SafeCall.looksOutOfGas(r, PROBE_GAS);
        p.ret = r.ret;
        p.retSize = r.retSize;
        p.gasUsed = r.gasUsed;
        for (uint256 i; i < acc.length; i++) {
            Vm.AccountAccess memory a = acc[i];
            if (a.reverted) continue;
            if (a.kind == VmSafe.AccountAccessKind.Create || a.kind == VmSafe.AccountAccessKind.SelfDestruct) {
                p.valueMoved = true;
            }
            if ((a.kind == VmSafe.AccountAccessKind.Call || a.kind == VmSafe.AccountAccessKind.CallCode) && a.value > 0) {
                p.valueMoved = true;
            }
            for (uint256 j; j < a.storageAccesses.length; j++) {
                Vm.StorageAccess memory s = a.storageAccesses[j];
                if (s.isWrite && !s.reverted && s.previousValue != s.newValue) {
                    p.writes++;
                    if (s.account == _hook) p.hookWrites++;
                }
            }
        }
    }

    function viewSlot0(PoolKey calldata key) external view returns (uint160, int24, uint24, uint24) {
        return _m.getSlot0(key.toId());
    }

    function viewLiquidity(PoolKey calldata key) external view returns (uint128) {
        return _m.getLiquidity(key.toId());
    }

    // ---------------------------------------------------------------------------------------------
    // Guarded wrappers
    // ---------------------------------------------------------------------------------------------

    function _exec(bytes memory callData, uint256 gasCap) internal returns (OpRes memory res, bytes memory ret) {
        SafeCall.Result memory r = SafeCall.call(address(this), 0, gasCap, callData, 2048);
        res.ok = r.ok;
        res.gasUsed = r.gasUsed;
        ret = r.ret;
        if (!r.ok) {
            res.oog = SafeCall.looksOutOfGas(r, gasCap);
            res.err = RevertInfo.decode(r.ret);
            // an environment fact only; what the revert data looks like plays no part (audit N-2)
            res.infra = _toolingBroken();
            if (res.err.cheatcode) {
                res.err.text = string.concat(
                    res.err.text,
                    " [shaped like a Foundry cheatcode error; any contract in the pool can produce such data]"
                );
            }
            if (res.infra) {
                res.err.text = string.concat("CHECKER TOOLING BROKEN: ", _toolingNote(), res.err.text);
            } else if (res.oog) {
                res.err.text = "ran out of gas: the operation used the whole gas cap";
            } else if (r.gasUsed > gasCap / 2) {
                res.err.text = string.concat(res.err.text, " [used more than half of the gas cap: likely gas exhaustion in a sub-call]");
            }
        }
    }

    // ---------------------------------------------------------------------------------------------
    // The checker's own footing
    // ---------------------------------------------------------------------------------------------

    /// @return active fork id + 1, or 0 when no fork is active (`vm.activeFork()` reverts then)
    function _forkTag() internal view returns (uint256) {
        (bool ok, bytes memory ret) = address(vm).staticcall(abi.encodeWithSignature("activeFork()"));
        if (!ok || ret.length != 32) return 0;
        return abi.decode(ret, (uint256)) + 1;
    }

    /// @return why non-empty when the chain state under the checker is no longer the one it started on
    function _envChange() internal view returns (string memory why) {
        uint256 f = _forkTag();
        if (f != _fork0) {
            return string.concat(
                "the active fork changed while the checks were running (fork id + 1, 0 = none: ", vm.toString(_fork0), " -> ",
                vm.toString(f),
                "). Code under test can cause this by calling back into a public function of the test contract that selects a fork. Everything observed after the switch came from another chain state"
            );
        }
        if (block.chainid != _chain0) {
            return string.concat("the chain id changed while the checks were running (", vm.toString(_chain0), " -> ", vm.toString(block.chainid), ")");
        }
        if (_clockOff()) {
            return string.concat(
                "the checker's footing is gone: block number / timestamp are ", vm.toString(block.number), " / ", vm.toString(block.timestamp),
                " where the checker left them at ", vm.toString(_clockN), " / ", vm.toString(_clockT),
                ", although the fork id and the chain id are unchanged. Something else moved the chain under the checker: vm.rollFork (which also replaces the chain state), vm.warp or vm.roll, for example in a public function of the test contract that code under test called. Everything observed after that is unreliable"
            );
        }
    }

    /// @dev the only way the checker moves time; keeps its clock in step
    function _advance(uint256 dt, uint256 dn) internal {
        vm.warp(block.timestamp + dt);
        vm.roll(block.number + dn);
        _clockT += dt;
        _clockN += dn;
    }

    /// @return true when block.number / block.timestamp are not where the checker's own moves left them
    function _clockOff() internal view returns (bool) {
        return block.number != _clockN || block.timestamp != _clockT;
    }

    function _toolingBroken() internal view returns (bool) {
        return address(_m).code.length == 0 || address(_lpA).code.length == 0 || address(_lpB).code.length == 0
            || address(_swapper).code.length == 0 || address(_stranger).code.length == 0 || _forkTag() != _fork0
            || block.chainid != _chain0 || _clockOff();
    }

    function _toolingNote() private view returns (string memory) {
        if (_forkTag() != _fork0 || block.chainid != _chain0) return "the active fork or chain changed; ";
        if (address(_m).code.length == 0) return "the PoolManager address has no code; ";
        if (
            address(_lpA).code.length == 0 || address(_lpB).code.length == 0 || address(_swapper).code.length == 0
                || address(_stranger).code.length == 0
        ) return "one of the checker's own routers has no code; ";
        return "block number / timestamp are not where the checker left them; ";
    }

    /// @dev `vm.revertToStateAndDelete` through a low-level call: a failing cheatcode must not take the
    ///      checker down with it
    function _rollback(uint256 snap) internal returns (bool) {
        (bool ok, bytes memory ret) = address(vm).call(abi.encodeWithSignature("revertToStateAndDelete(uint256)", snap));
        return ok && ret.length == 32 && abi.decode(ret, (bool));
    }

    function _tryInit(CheckerRouter r, PoolKey memory key, uint160 sqrtPriceX96) internal returns (OpRes memory res) {
        (res,) = _exec(abi.encodeCall(this.opInit, (r, key, sqrtPriceX96)), OP_GAS);
    }

    function _tryModify(CheckerRouter r, PoolKey memory key, int24 lower, int24 upper, int256 liquidityDelta)
        internal
        returns (ModRes memory m)
    {
        bytes memory ret;
        (m.op, ret) = _exec(
            abi.encodeCall(this.opModify, (r, key, ModifyLiquidityParams(lower, upper, liquidityDelta, bytes32(0)), "")),
            OP_GAS
        );
        if (m.op.ok && ret.length == 64) (m.a0, m.a1) = abi.decode(ret, (int128, int128));
    }

    /// @param limit 0 = the widest price limit for the direction
    function _trySwap(CheckerRouter r, PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 limit)
        internal
        returns (SwapRes memory s)
    {
        if (limit == 0) limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        bytes memory ret;
        (s.op, ret) =
            _exec(abi.encodeCall(this.opSwap, (r, key, SwapParams(zeroForOne, amountSpecified, limit), "")), OP_GAS);
        if (s.op.ok && ret.length == 224) s.out = abi.decode(ret, (SwapOut));
    }

    function _tryDonate(CheckerRouter r, PoolKey memory key, uint256 amount0, uint256 amount1)
        internal
        returns (OpRes memory res)
    {
        (res,) = _exec(abi.encodeCall(this.opDonate, (r, key, amount0, amount1, "")), OP_GAS);
    }

    function _tryDeal(address token, address to, uint256 amount) internal returns (bool) {
        (OpRes memory res,) = _exec(abi.encodeCall(this.opDeal, (token, to, amount)), OP_GAS);
        return res.ok;
    }

    function _probe(address caller, address origin, bytes memory data, bool unlocked) internal returns (Probe memory p) {
        SafeCall.Result memory r = SafeCall.call(
            address(this), 0, PROBE_FRAME_GAS, abi.encodeCall(this.opProbe, (caller, origin, data, unlocked)), 4096
        );
        if (!r.ok && r.retSize == r.ret.length && r.ret.length > 68 && SafeCall.selector(r.ret) == ProbeDone.selector) {
            bytes memory inner = abi.decode(SafeCall.slice(r.ret, 4, r.ret.length - 4), (bytes));
            p = abi.decode(inner, (Probe));
            p.infraOk = true;
        }
    }

    function _slot0(PoolKey memory key) internal view returns (bool ok, uint160 sqrtPriceX96, int24 tick, uint24 lpFee) {
        SafeCall.Result memory r =
            SafeCall.staticcall(address(this), VIEW_GAS, abi.encodeCall(this.viewSlot0, (key)), 128);
        if (r.ok && r.ret.length == 128) {
            (sqrtPriceX96, tick,, lpFee) = abi.decode(r.ret, (uint160, int24, uint24, uint24));
            ok = true;
        }
    }

    function _poolLiquidity(PoolKey memory key) internal view returns (uint128 liq) {
        SafeCall.Result memory r =
            SafeCall.staticcall(address(this), VIEW_GAS, abi.encodeCall(this.viewLiquidity, (key)), 32);
        if (r.ok && r.ret.length == 32) liq = abi.decode(r.ret, (uint128));
    }

    /// @dev 32-byte answer of a view on untrusted code; ok only for exactly-32-byte returns
    function _viewWord(address target, bytes memory callData) internal view returns (bool ok, bytes32 w) {
        SafeCall.Result memory r = SafeCall.staticcall(target, VIEW_GAS, callData, 64);
        if (r.ok && r.retSize == 32) return (true, SafeCall.word0(r));
    }

    function _balanceOf(Currency c, address who) internal view returns (bool ok, uint256 bal) {
        if (c.isAddressZero()) return (true, who.balance);
        if (Currency.unwrap(c).code.length == 0) return (false, 0);
        bytes32 w;
        (ok, w) = _viewWord(Currency.unwrap(c), abi.encodeWithSignature("balanceOf(address)", who));
        bal = uint256(w);
    }

    /// @dev ERC-6909 claim balance held at the PoolManager
    function _claimsOf(Currency c, address who) internal view returns (bool ok, uint256 bal) {
        bytes32 w;
        (ok, w) = _viewWord(
            address(_m), abi.encodeWithSignature("balanceOf(address,uint256)", who, uint256(uint160(Currency.unwrap(c))))
        );
        bal = uint256(w);
    }
}
