// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";

import {SafeCall} from "./lib/SafeCall.sol";
import {RevertInfo} from "./lib/RevertInfo.sol";
import {BytecodeScan} from "./lib/BytecodeScan.sol";
import {CheckerRouter} from "./CheckerRouter.sol";
import {CheckerOps} from "./CheckerOps.sol";
import {Status, Finding, Report, CheckConfig, Lines, LinesLib} from "./CheckerTypes.sol";

/// @title HookChecker
/// @notice Generic, detection-only checks for a Uniswap v4 hook: `runChecks(cfg)` exercises the hook
///         through a PoolManager in local simulation (a local deployment or a fork) and returns one
///         Finding per check, a..i. See checker/README.md for what each check does and does not show.
///         A hook that passes everything here is NOT thereby safe; this is not an audit.
/// @dev Inherit it in a Foundry test. Everything learned is kept in memory: the checker rolls EVM state
///      back between scenarios (and at the end of the run), which would also wipe its own storage.
abstract contract HookChecker is CheckerOps {
    using LinesLib for Lines;
    using PoolIdLibrary for PoolKey;

    /// @dev index of each check in Report.findings
    uint256 internal constant A_PERMISSIONS = 0;
    uint256 internal constant B_CALLER = 1;
    uint256 internal constant C_FOREIGN_POOL = 2;
    uint256 internal constant D_REMOVE = 3;
    uint256 internal constant E_SWAP = 4;
    uint256 internal constant F_DYNAMIC_FEE = 5;
    uint256 internal constant G_UPGRADE = 6;
    uint256 internal constant H_BALANCES = 7;
    uint256 internal constant I_RETURN_DELTA = 8;

    /// @dev an address with no role anywhere
    address internal constant ATTACKER = address(uint160(uint256(keccak256("hook-checker.attacker"))));
    /// @dev the checker's own pools start at price ~2.0, not 1:1: mixing up token0 and token1 amounts is
    ///      invisible at parity
    int24 internal constant INIT_TICK = 6931;
    /// @dev the stranger's pool starts elsewhere (price ~0.1)
    int24 internal constant STRANGER_TICK = -23027;
    /// @dev liquidity of the stranger's positions: ordinary pools / the two pools with extreme parameters
    ///      (a full-range position at the very edge of the price range costs about 1.8e19 tokens per unit)
    int256 private constant STRANGER_LIQ = 1e21;
    int256 private constant STRANGER_EXTREME_LIQ = 1e9;

    uint8 private constant SC_BASELINE = 0;
    uint8 private constant SC_PUSH_DOWN = 3;
    uint8 private constant SC_PUSH_UP = 4;
    uint8 private constant SC_SINGLE_LP = 5;
    uint8 private constant SC_EMPTY = 6;
    uint8 private constant SC_PUSH_THEN_WAIT = 10;
    uint8 private constant SC_COUNT = 11;

    /// @dev how a recorded flow (check c) hands its result out of a frame that is always rolled back
    error FlowDone(bytes result);

    struct Env {
        uint160 flags;
        bytes code;
        BytecodeScan.Ops ops; // FULL sweep of the bytecode (nothing cut off)
        BytecodeScan.Ops opsCode; // sweep without the metadata-shaped trailer: only to word hints
        string taint; // non-empty: the run is compromised (see _taintCheck), the report will be void
        PoolKey key; // the pool under test
        bool poolReady;
        bool poolOurs; // initialized by the checker (false: pre-existing pool)
        bool dynamicFee;
        PoolKey ctl; // control pool: same currencies and spacing, NO hook
        bool ctlReady;
        bool liqReady; // LP A's position exists
        bool hasB; // LP B's position exists
        int24 lower;
        int24 upper;
        int256 liq; // per LP
        uint256 unit0; // 10**decimals
        uint256 unit1;
        uint256 amt0; // size of a "small" swap, in token0 / token1
        uint256 amt1;
        uint256 big0; // size of a "push the price out of range" swap
        uint256 big1;
        // what real PoolManager flows showed about each callback (bit i = callback i, order of IHooks)
        uint16 evOk;
        uint16 evMissing;
        uint16 evOther;
        string[10] evNote;
        Lines setup;
        uint256[5] balBefore; // erc20/native c0, c1, claims c0, c1, readable-mask
    }

    struct Acc {
        Lines d;
        uint256 dRan;
        uint256 dOk; // succeeded on the hooked pool
        uint256 dFail; // reverted, attributed to the hook
        uint256 dBoth; // reverted on the hooked pool AND on the hook-less control pool
        uint256 dInfra; // the checker's own tooling failed
        uint256 dScen; // scenarios in which the withdrawal steps were run
        uint256 dSkip; // scenarios NOT TESTED
        string dSkipNames;
        Lines e;
        uint256 eRan;
        uint256 eOk;
        uint256 eUnexpected;
        uint256 eRefusal;
        uint256 eBaselineRefusal;
        uint256 eBoth;
        uint256 eInfra;
        uint256 eScen;
        uint256 eSkip;
        string eSkipNames;
        Lines f;
        uint256 feeSeen;
        uint24 feeMin;
        uint24 feeMax;
        bool feeTooLarge;
        bool feeFull; // saw 100%
        bool sameBlockDiff;
        bool sameBlockRan; // both directions ran
        SwapOut[4] base;
        bool[4] baseOk;
        // baseline: what LP A got back for its whole position, hooked pool vs control
        int256[2] backHook;
        int256[2] backCtl;
        bool backOk;
        // reasons already printed once (d and e), so that 40 identical reverts do not fill the report
        bytes32[48] seen;
        uint256 nSeen;
        uint256 repeats;
    }

    struct FlowArgs {
        PoolKey key;
        bool refReady; // the pool under test exists and has liquidity
        uint256 amt0;
        uint256 amt1;
        int24 lower; // LP A's position in the pool under test
        int24 upper;
        int256 liq;
        bool shareCurrency; // also try a stranger pool that shares currency0 with the pool under test
    }

    /// @dev reference operations 0..5 are swaps, 6 = LP A collects fees (liquidityDelta 0), 7 = LP A
    ///      withdraws a quarter, 8 = LP A adds an eighth
    struct FlowOut {
        bool strangerAccepted; // at least one of the stranger's pools was accepted
        string strangerNote;
        bool[9] ok;
        bytes4[9] err;
        SwapOut[6] outs;
        int128[3] l0; // router deltas of the three liquidity operations
        int128[3] l1;
        bytes32[] written; // hook slots whose value the stranger pools' activity changed
        bytes32[] touched; // hook slots the reference operations read or wrote
        bool truncated; // more distinct hook slots than SLOT_CAP: the two lists are incomplete
        bool infra; // the checker's own tooling was found broken during the flow (environment fact)
        bool[9] fromHook; // the reference operation reverted out of a callback of the hook
        bool[9] opInfra; // the reference operation failed while the checker's tooling was broken
    }

    /// @dev distinct hook storage slots tracked per recording (check c); beyond it the result is flagged
    uint256 private constant SLOT_CAP = 1024;
    uint256 private constant REF_OPS = 9;

    /// @dev set for the duration of runChecks, BEFORE its outer snapshot (so that no rollback clears it)
    bool private _busy;

    error CheckerBusy();

    /// @notice Put this on every public function of the inheriting test contract that selects a fork or
    ///         otherwise changes the simulated environment: code under test can call back into the test
    ///         contract while runChecks is in progress.
    modifier notWhileChecking() {
        if (_busy) revert CheckerBusy();
        _;
    }

    // =============================================================================================
    // Entry
    // =============================================================================================

    /// @notice Runs all checks. Leaves no state behind. Not re-entrant: a call made while a run is in
    ///         progress (e.g. by the hook under test) reverts with CheckerBusy.
    ///         If the simulated environment changes under the checker (the active fork, the chain id, or
    ///         block number / timestamp moved by something else - see CheckerOps._clockN), the whole
    ///         report is VOID: `rep.voided` is set, every finding is UNKNOWN, and nothing that was
    ///         collected during the run (details, setup lines) is kept.
    function runChecks(CheckConfig memory cfg) public notWhileChecking returns (Report memory rep) {
        _busy = true;
        _fork0 = _forkTag();
        _chain0 = block.chainid;
        _clockN = block.number;
        _clockT = block.timestamp;
        uint256 snap = vm.snapshotState();
        rep = _run(cfg);
        string memory why = rep.voidReason;
        if (bytes(why).length == 0) why = _envChange();
        if (_forkTag() != _fork0 && _fork0 != 0) {
            // go back to where the run started before rolling back; best effort
            (bool sel,) = address(vm).call(abi.encodeWithSignature("selectFork(uint256)", _fork0 - 1));
            sel;
        }
        bool rolled = _rollback(snap);
        _busy = false;
        if (bytes(why).length == 0 && !rolled) why = "the final state rollback failed";
        if (bytes(why).length == 0) why = _envChange();
        if (bytes(why).length != 0) _void(rep, why);
    }

    function _void(Report memory rep, string memory why) private pure {
        rep.voided = true;
        rep.voidReason = why;
        // setup lines carry text from the hook under test (revert strings): not in a void report
        rep.setup = new string[](0);
        for (uint256 i; i < rep.findings.length; i++) {
            rep.findings[i].status = Status.UNKNOWN;
            rep.findings[i].summary = "REPORT VOID - nothing was established (see the top of the report)";
            rep.findings[i].details = new string[](0);
        }
    }

    /// @dev true (and env.taint set) once the environment is no longer the one the run started in
    function _taintCheck(Env memory env) private view returns (bool) {
        if (bytes(env.taint).length != 0) return true;
        env.taint = _envChange();
        return bytes(env.taint).length != 0;
    }

    function _run(CheckConfig memory cfg) private returns (Report memory rep) {
        rep.hook = cfg.hook;
        rep.manager = address(cfg.manager);
        rep.chainId = block.chainid;
        rep.blockNumber = block.number;
        rep.timestamp = block.timestamp;
        rep.codeSize = cfg.hook.code.length;
        rep.flags = uint160(cfg.hook) & Hooks.ALL_HOOK_MASK;
        rep.findings = _blankFindings();

        Env memory env;
        env.setup = LinesLib.make();
        env.flags = rep.flags;
        if (cfg.hook.code.length == 0 || address(cfg.manager).code.length == 0) {
            string memory why = cfg.hook.code.length == 0 ? "the hook address has no code" : "the PoolManager address has no code";
            for (uint256 i; i < rep.findings.length; i++) {
                rep.findings[i].summary = why;
            }
            env.setup.add(why);
            rep.setup = env.setup.done();
            return rep;
        }
        env.code = cfg.hook.code;
        env.ops = BytecodeScan.scan(env.code);
        env.opsCode = BytecodeScan.scanCodePart(env.code);

        _m = cfg.manager;
        _hook = cfg.hook;
        _lpA = new CheckerRouter(cfg.manager);
        _lpB = new CheckerRouter(cfg.manager);
        _swapper = new CheckerRouter(cfg.manager);
        _stranger = new CheckerRouter(cfg.manager);

        _setupPool(cfg, env);
        Acc memory acc;
        if (!_taintCheck(env)) acc = _runScenarios(env);
        // each step below runs code of the hook; the environment is re-checked after every one of them
        if (!_taintCheck(env)) rep.findings[A_PERMISSIONS] = _checkPermissions(env);
        if (!_taintCheck(env)) rep.findings[B_CALLER] = _checkCaller(env);
        if (!_taintCheck(env)) rep.findings[C_FOREIGN_POOL] = _checkForeignPool(env);
        if (!_taintCheck(env)) {
            rep.findings[D_REMOVE] = _findRemove(env, acc);
            rep.findings[E_SWAP] = _findSwap(env, acc);
            rep.findings[F_DYNAMIC_FEE] = _findFee(env, acc);
            rep.findings[G_UPGRADE] = _checkUpgrade(env);
            rep.findings[H_BALANCES] = _checkBalances(env);
            rep.findings[I_RETURN_DELTA] = _findReturnDelta(env, acc);
        }
        _taintCheck(env);
        rep.voidReason = env.taint; // runChecks voids the report when this is set
        rep.setup = env.setup.done();
    }

    function _blankFindings() private pure returns (Finding[] memory f) {
        f = new Finding[](9);
        string[9] memory titles = [
            "permission bits: address vs getHookPermissions() vs behaviour",
            "callbacks callable by an address that is not the PoolManager",
            "foreign pool created with the same hook address",
            "can removing liquidity be blocked",
            "can swaps get stuck",
            "dynamic fee: bounds and same-block sensitivity",
            "signs of upgradeability / admin control",
            "tokens and ERC-6909 claims held by the hook",
            "return deltas: what the hook takes"
        ];
        bytes memory ids = "abcdefghi";
        for (uint256 i; i < 9; i++) {
            bytes memory id = new bytes(1);
            id[0] = ids[i];
            f[i].id = string(id);
            f[i].title = titles[i];
            f[i].status = Status.NA;
            f[i].details = new string[](0);
        }
    }

    // =============================================================================================
    // Setup: the pool under test, a hook-less control pool, two LP positions, a few swaps
    // =============================================================================================

    function _setupPool(CheckConfig memory cfg, Env memory env) private {
        (env.balBefore[0], env.balBefore[1], env.balBefore[2], env.balBefore[3], env.balBefore[4]) = (0, 0, 0, 0, 0);
        if (cfg.hasKey) {
            _givenPool(cfg, env);
        } else {
            _ownPool(cfg, env);
        }
        if (!env.poolReady) {
            env.setup.add("NO TEST POOL: checks that need pool operations are reported as UNKNOWN. Give a PoolKey the hook accepts.");
            return;
        }
        env.dynamicFee = env.key.fee == LPFeeLibrary.DYNAMIC_FEE_FLAG;
        _snapshotBalances(env, true);
        if (!_range(env)) {
            env.poolReady = false;
            return;
        }
        _control(env);
        _addLiquidity(env);
        if (env.liqReady) _warmUp(env);
    }

    function _ownPool(CheckConfig memory cfg, Env memory env) private {
        MockERC20 a = new MockERC20("Checker Token A", "CKA", 18);
        MockERC20 b = new MockERC20("Checker Token B", "CKB", 18);
        Currency c0;
        Currency c1;
        if (cfg.nativeCurrency0) {
            c0 = Currency.wrap(address(0));
            c1 = Currency.wrap(address(a));
        } else {
            (c0, c1) = address(a) < address(b)
                ? (Currency.wrap(address(a)), Currency.wrap(address(b)))
                : (Currency.wrap(address(b)), Currency.wrap(address(a)));
        }
        CheckerRouter[3] memory rs = [_lpA, _lpB, _swapper];
        for (uint256 i; i < 3; i++) {
            a.mint(address(rs[i]), 1e30);
            b.mint(address(rs[i]), 1e30);
            if (cfg.nativeCurrency0) vm.deal(address(rs[i]), 1e30);
        }
        env.unit0 = 1e18;
        env.unit1 = 1e18;

        uint24[4] memory fees = [LPFeeLibrary.DYNAMIC_FEE_FLAG, uint24(3000), uint24(500), uint24(100)];
        int24[4] memory spacings = [int24(60), int24(60), int24(10), int24(1)];
        uint160 price = TickMath.getSqrtPriceAtTick(INIT_TICK);
        for (uint256 i; i < 4; i++) {
            PoolKey memory k = PoolKey(c0, c1, fees[i], spacings[i], IHooks(_hook));
            OpRes memory r = _tryInit(_lpA, k, price);
            _evidence(env, 0, r);
            env.setup.add(
                string.concat(
                    "own pool (", cfg.nativeCurrency0 ? "native ETH / mock" : "mock / mock", ", fee ",
                    fees[i] == LPFeeLibrary.DYNAMIC_FEE_FLAG ? "DYNAMIC" : vm.toString(fees[i]),
                    ", tickSpacing ", vm.toString(spacings[i]), ", initial tick ", vm.toString(INIT_TICK), "): ",
                    r.ok ? "initialized" : string.concat("initialize reverted: ", r.err.text)
                )
            );
            if (r.ok) {
                env.key = k;
                env.poolReady = true;
                env.poolOurs = true;
                return;
            }
        }
    }

    function _givenPool(CheckConfig memory cfg, Env memory env) private {
        env.key = cfg.key;
        if (address(cfg.key.hooks) != _hook) {
            env.setup.add("given PoolKey.hooks is not the hook under test: ignored");
            return;
        }
        (bool ok, uint160 sqrtP, int24 tick,) = _slot0(cfg.key);
        if (!ok) {
            env.setup.add("given PoolKey: cannot read slot0 from the PoolManager");
            return;
        }
        if (sqrtP == 0) {
            OpRes memory r = _tryInit(_lpA, cfg.key, TickMath.getSqrtPriceAtTick(INIT_TICK));
            _evidence(env, 0, r);
            env.setup.add(
                string.concat(
                    "given PoolKey was not initialized; initialize at tick ", vm.toString(INIT_TICK), ": ",
                    r.ok ? "ok" : string.concat("reverted: ", r.err.text)
                )
            );
            if (!r.ok) return;
            env.poolOurs = true;
        } else {
            env.setup.add(
                string.concat(
                    "given PoolKey: existing pool, tick ", vm.toString(tick), ", in-range liquidity ",
                    vm.toString(uint256(_poolLiquidity(cfg.key))),
                    " (other LPs' liquidity stays in the pool: 'single LP' / 'empty pool' scenarios only remove the checker's own)"
                )
            );
        }
        env.unit0 = _unit(cfg.key.currency0);
        env.unit1 = _unit(cfg.key.currency1);
        CheckerRouter[3] memory rs = [_lpA, _lpB, _swapper];
        for (uint256 i; i < 3; i++) {
            _fund(env, cfg.key.currency0, address(rs[i]), env.unit0);
            _fund(env, cfg.key.currency1, address(rs[i]), env.unit1);
        }
        env.poolReady = true;
    }

    function _fund(Env memory env, Currency c, address to, uint256 unit) private {
        uint256 amount = 1e9 * unit;
        if (c.isAddressZero()) {
            vm.deal(to, amount);
        } else if (!_tryDeal(Currency.unwrap(c), to, amount)) {
            env.setup.add(
                string.concat("could not give test balance of token ", vm.toString(Currency.unwrap(c)), " (forge `deal` failed): pool operations will fail")
            );
        }
    }

    function _unit(Currency c) private view returns (uint256) {
        if (c.isAddressZero()) return 1e18;
        (bool ok, bytes32 w) = _viewWord(Currency.unwrap(c), abi.encodeWithSignature("decimals()"));
        if (!ok || uint256(w) > 30) return 1e18;
        return 10 ** uint256(w);
    }

    /// @dev picks the tick range of the checker's positions (120 spacings each side of the current
    ///      tick) and the liquidity that costs about 1000 units of each token
    function _range(Env memory env) private view returns (bool) {
        int24 ts = env.key.tickSpacing;
        (bool ok, uint160 sqrtP, int24 tick,) = _slot0(env.key);
        if (!ok || sqrtP == 0 || ts <= 0 || ts > TickMath.MAX_TICK_SPACING) return false;
        (env.lower, env.upper) = _bounds(tick, ts);
        uint128 l = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP,
            TickMath.getSqrtPriceAtTick(env.lower),
            TickMath.getSqrtPriceAtTick(env.upper),
            1000 * env.unit0,
            1000 * env.unit1
        );
        if (l == 0) l = 1e9;
        if (l > 1e30) l = 1e30;
        env.liq = int256(uint256(l));
        env.big0 = 1e7 * env.unit0;
        env.big1 = 1e7 * env.unit1;
        return true;
    }

    function _bounds(int24 tick, int24 ts) private pure returns (int24 lower, int24 upper) {
        int24 base = (tick / ts) * ts;
        if (tick < 0 && tick % ts != 0) base -= ts;
        int24 minT = (TickMath.MIN_TICK / ts) * ts;
        int24 maxT = (TickMath.MAX_TICK / ts) * ts;
        int256 lo = int256(base) - int256(ts) * 120;
        int256 hi = int256(base) + int256(ts) * 121;
        lower = lo < minT ? minT : int24(lo);
        upper = hi > maxT ? maxT : int24(hi);
    }

    function _control(Env memory env) private {
        (, uint160 sqrtP,,) = _slot0(env.key);
        uint24 first = env.dynamicFee ? 3000 : env.key.fee;
        uint24[4] memory fees = [first, uint24(2999), uint24(3001), uint24(2998)];
        for (uint256 i; i < 4; i++) {
            PoolKey memory k = PoolKey(env.key.currency0, env.key.currency1, fees[i], env.key.tickSpacing, IHooks(address(0)));
            (, uint160 existing,,) = _slot0(k);
            if (existing != 0) continue; // somebody else's pool: not usable as a clean control
            if (_tryInit(_lpA, k, sqrtP).ok) {
                env.ctl = k;
                env.ctlReady = true;
                return;
            }
        }
        env.setup.add("no hook-less control pool could be created: every revert on the hooked pool is attributed to the hook");
    }

    function _addLiquidity(Env memory env) private {
        ModRes memory a = _tryModify(_lpA, env.key, env.lower, env.upper, env.liq);
        _evidence(env, 1, a.op);
        if (!a.op.ok) {
            env.setup.add(string.concat("ADD LIQUIDITY FAILED on the pool under test: ", a.op.err.text));
            return;
        }
        env.liqReady = true;
        ModRes memory b = _tryModify(_lpB, env.key, env.lower, env.upper, env.liq);
        _evidence(env, 1, b.op);
        env.hasB = b.op.ok;
        if (!b.op.ok) env.setup.add(string.concat("second LP could not add liquidity: ", b.op.err.text));
        if (env.ctlReady) {
            bool ok = _tryModify(_lpA, env.ctl, env.lower, env.upper, env.liq).op.ok;
            if (env.hasB) ok = _tryModify(_lpB, env.ctl, env.lower, env.upper, env.liq).op.ok && ok;
            if (!ok) env.ctlReady = false;
        }
        uint256 paid0 = a.a0 < 0 ? uint256(uint128(-a.a0)) : 0;
        uint256 paid1 = a.a1 < 0 ? uint256(uint128(-a.a1)) : 0;
        env.amt0 = paid0 / 300 > 0 ? paid0 / 300 : (env.unit0 / 1000 > 0 ? env.unit0 / 1000 : 1);
        env.amt1 = paid1 / 300 > 0 ? paid1 / 300 : (env.unit1 / 1000 > 0 ? env.unit1 / 1000 : 1);
        env.setup.add(
            string.concat(
                "two LP positions of liquidity ", vm.toString(env.liq), " each in [", vm.toString(env.lower), ", ",
                vm.toString(env.upper), "]; small swap = ", vm.toString(env.amt0), " token0 / ", vm.toString(env.amt1),
                " token1; control pool: ", env.ctlReady ? "yes" : "NO"
            )
        );
    }

    /// @dev a few swaps and one donation so that fees have accrued and every swap/donate callback has run.
    ///      Time passes before and after (a minute, 30 blocks each): a real pool does not live in one
    ///      block, and hooks that observe "once per block / per time bucket" need to have seen a few.
    function _warmUp(Env memory env) private {
        _advance(60, 30);
        for (uint8 c; c < 4; c++) {
            SwapRes memory s = _trySwap(_swapper, env.key, c < 2, _amount(env, c), 0);
            _evidence(env, 3, s.op);
            if (env.ctlReady) _trySwap(_swapper, env.ctl, c < 2, _amount(env, c), 0);
        }
        OpRes memory d = _tryDonate(_swapper, env.key, env.amt0 / 100 + 1, env.amt1 / 100 + 1);
        _evidence(env, 4, d);
        if (!d.ok) env.setup.add(string.concat("donate on the pool under test reverted: ", d.err.text));
        if (env.ctlReady) _tryDonate(_swapper, env.ctl, env.amt0 / 100 + 1, env.amt1 / 100 + 1);
        _advance(60, 30);
    }

    /// @dev combo 0: zeroForOne exactIn, 1: zeroForOne exactOut, 2: oneForZero exactIn, 3: oneForZero exactOut
    function _amount(Env memory env, uint8 combo) private pure returns (int256) {
        if (combo == 0) return -int256(env.amt0);
        if (combo == 1) return int256(env.amt1);
        if (combo == 2) return -int256(env.amt1);
        return int256(env.amt0);
    }

    function _comboName(uint8 combo) private pure returns (string memory) {
        if (combo == 0) return "0->1 exactIn";
        if (combo == 1) return "0->1 exactOut";
        if (combo == 2) return "1->0 exactIn";
        return "1->0 exactOut";
    }

    // =============================================================================================
    // Evidence from real flows: which callbacks PoolManager really called, and how that went
    // =============================================================================================

    function _declared(uint160 flags, uint256 k) private pure returns (bool) {
        return flags & (uint160(1) << uint160(13 - k)) != 0;
    }

    function _cbSelector(uint256 k) private pure returns (bytes4) {
        bytes4[10] memory s = [
            IHooks.beforeInitialize.selector,
            IHooks.afterInitialize.selector,
            IHooks.beforeAddLiquidity.selector,
            IHooks.afterAddLiquidity.selector,
            IHooks.beforeRemoveLiquidity.selector,
            IHooks.afterRemoveLiquidity.selector,
            IHooks.beforeSwap.selector,
            IHooks.afterSwap.selector,
            IHooks.beforeDonate.selector,
            IHooks.afterDonate.selector
        ];
        return s[k];
    }

    /// @param opType 0 initialize, 1 add liquidity, 2 remove liquidity (incl. liquidityDelta == 0), 3 swap, 4 donate
    function _evidence(Env memory env, uint8 opType, OpRes memory r) private view {
        uint256 k0 = uint256(opType) * 2;
        if (r.ok) {
            // PoolManager called every declared callback of this operation and accepted its answer
            for (uint256 k = k0; k < k0 + 2; k++) {
                if (_declared(env.flags, k)) env.evOk |= uint16(1 << k);
            }
            return;
        }
        if (r.err.wrapped && r.err.target == _hook) {
            for (uint256 k; k < 10; k++) {
                if (_cbSelector(k) != r.err.callback) continue;
                if (RevertInfo.looksUnimplemented(r.err)) env.evMissing |= uint16(1 << k);
                else env.evOther |= uint16(1 << k);
                env.evNote[k] = r.err.text;
            }
        }
        // An unwrapped InvalidHookResponse does not say which of the operation's two callbacks gave the
        // bad answer: nothing is recorded here, the direct probe in check a decides per callback.
    }

    /// @return cls 0 = succeeded on the hooked pool,
    ///             1 = the hook refused with an explicit error (may be by design),
    ///             2 = unexpected: panic, empty revert, unimplemented callback, gas exhaustion, an answer
    ///                 PoolManager rejects, or accounting that does not settle - while the control pool works,
    ///             3 = reverted on the hooked pool AND on the hook-less control pool: not attributed to
    ///                 the hook, but not cleared either (the hook may be the cause of both, e.g. through
    ///                 a token it controls),
    ///             4 = the checker's own tooling is broken (an environment fact, see OpRes.infra): no
    ///                 evidence either way
    /// @dev Order matters. A revert that came out of a callback of the hook is attributed to the hook
    ///      FIRST: nothing about the control pool, and no tooling state, overrides it (audit N-2).
    function _classify(OpRes memory h, OpRes memory ctl) internal view returns (uint8 cls) {
        if (h.ok) return 0;
        if (_fromHook(h)) {
            if (h.oog) return 2;
            if (h.err.kind == RevertInfo.Kind.EMPTY || h.err.kind == RevertInfo.Kind.PANIC) return 2;
            if (h.err.inner == RevertInfo.HOOK_NOT_IMPLEMENTED) return 2;
            return 1;
        }
        if (h.infra || ctl.infra) return 4;
        if (h.oog) return 2;
        if (!ctl.ok) return 3;
        return 2;
    }

    /// @dev the operation reverted out of a callback of the hook under test (v4 wraps those)
    function _fromHook(OpRes memory r) internal view returns (bool) {
        return !r.ok && r.err.wrapped && r.err.target == _hook;
    }

    // =============================================================================================
    // Scenarios (checks d, e, f, i share them)
    // =============================================================================================

    function _scenarioName(uint8 sc) private pure returns (string memory) {
        if (sc == 0) return "baseline (one minute after the warm-up swaps)";
        if (sc == 1) return "time +1 hour";
        if (sc == 2) return "time +400 days";
        if (sc == 3) return "price pushed below the LP range";
        if (sc == 4) return "price pushed above the LP range";
        if (sc == 5) return "single LP left";
        if (sc == 6) return "all checker liquidity removed";
        if (sc == 7) return "gas price 0, base fee 0";
        if (sc == 8) return "gas price 5000 gwei, base fee 1 gwei";
        if (sc == 9) return "base fee 100 gwei above gas price 1 gwei";
        return "price pushed below the LP range, then +15 seconds";
    }

    function _runScenarios(Env memory env) private returns (Acc memory acc) {
        acc.d = LinesLib.make();
        acc.e = LinesLib.make();
        acc.f = LinesLib.make();
        acc.feeMin = type(uint24).max;
        if (!env.poolReady || !env.liqReady) return acc;
        for (uint8 sc; sc < SC_COUNT; sc++) {
            uint256 snap = vm.snapshotState();
            (bool applied, string memory note) = _perturb(env, acc, sc);
            if (applied) {
                acc.eScen++;
                _swapsIn(env, acc, sc);
                if (sc != SC_EMPTY) {
                    acc.dScen++;
                    _removalsIn(env, acc, sc);
                }
            } else {
                string memory line = string.concat(_scenarioName(sc), ": NOT TESTED, the perturbation could not be applied (", note, ")");
                acc.e.add(line);
                acc.eSkip++;
                acc.eSkipNames = string.concat(acc.eSkipNames, bytes(acc.eSkipNames).length == 0 ? "" : "; ", _scenarioName(sc));
                if (sc != SC_EMPTY) {
                    acc.d.add(line);
                    acc.dSkip++;
                    acc.dSkipNames = string.concat(acc.dSkipNames, bytes(acc.dSkipNames).length == 0 ? "" : "; ", _scenarioName(sc));
                }
            }
            // The hook ran inside this scenario: is the checker still standing where it started? Looked at
            // BEFORE the rollback too: rolling back to a snapshot taken before a vm.rollFork puts the old
            // state back, and what was observed in between would pass unnoticed.
            _taintCheck(env);
            bool rolled = _rollback(snap);
            if (_taintCheck(env)) return acc;
            if (!rolled) {
                env.taint = "a state rollback between scenarios failed";
                return acc;
            }
        }
        if (env.dynamicFee) _sameBlockFees(env, acc);
    }

    function _perturb(Env memory env, Acc memory acc, uint8 sc) private returns (bool, string memory) {
        if (sc == 1 || sc == 2) {
            uint256 dt = sc == 1 ? 1 hours : 400 days;
            _advance(dt, dt / 2);
        } else if (sc == SC_PUSH_DOWN || sc == SC_PUSH_UP) {
            return _push(env, acc, sc == SC_PUSH_DOWN);
        } else if (sc == SC_PUSH_THEN_WAIT) {
            (bool pushed, string memory why) = _push(env, acc, true);
            if (!pushed) return (false, why);
            _advance(15, 7);
        } else if (sc == SC_SINGLE_LP || sc == SC_EMPTY) {
            if (!env.hasB) return (false, "the second LP position does not exist");
            (bool gone, string memory whyNot) = _setupWithdraw(env, acc, sc, _lpB, "the second LP");
            if (!gone) return (false, whyNot);
            if (sc == SC_EMPTY) {
                (gone, whyNot) = _setupWithdraw(env, acc, sc, _lpA, "the first LP");
                if (!gone) return (false, whyNot);
            }
        } else if (sc == 7) {
            vm.txGasPrice(0);
            vm.fee(0);
        } else if (sc == 8) {
            vm.txGasPrice(5000 gwei);
            vm.fee(1 gwei);
        } else if (sc == 9) {
            vm.txGasPrice(1 gwei);
            vm.fee(100 gwei);
        }
        return (true, "");
    }

    /// @dev A full withdrawal that is part of setting a scenario up ("single LP left", "all checker
    ///      liquidity removed"). It is a withdrawal like any other: when it fails it is classified and
    ///      counted for check d exactly like a withdrawal step (audit N-1), and only then is the scenario
    ///      given up as NOT TESTED. A success is not counted (the steps of the scenarios are).
    function _setupWithdraw(Env memory env, Acc memory acc, uint8 sc, CheckerRouter r, string memory who)
        private
        returns (bool, string memory)
    {
        ModRes memory h = _tryModify(r, env.key, env.lower, env.upper, -env.liq);
        ModRes memory ctl;
        ctl.op.ok = true;
        if (env.ctlReady) ctl = _tryModify(r, env.ctl, env.lower, env.upper, -env.liq);
        if (h.op.ok) return (true, "");
        uint8 cls = _classify(h.op, ctl.op);
        acc.dRan++;
        string memory tag;
        if (cls == 3) {
            acc.dBoth++;
            tag = "reverts (also without hook)";
        } else if (cls == 4) {
            acc.dInfra++;
            tag = "PROBE FAILED";
        } else {
            acc.dFail++;
            tag = "REVERT";
        }
        string memory note = cls == 1 || cls == 2 ? "" : _clsNote(cls);
        acc.d.add(string.concat(_scenarioName(sc), ", while setting the scenario up: | ", who, " removes everything ", tag));
        _addOnce(
            acc, acc.d, "d", h.op.err.text,
            string.concat("  first seen in: ", _scenarioName(sc), ", ", who, " removes everything (scenario set-up): REVERT ", h.op.err.text, note)
        );
        return (false, string.concat(who, " could not withdraw: ", h.op.err.text, note, "; counted in check d"));
    }

    /// @dev one large exactIn swap up to a price limit two spacings beyond the checker's range. The push
    ///      itself is a swap the hook sees, so its failure counts for check e.
    function _push(Env memory env, Acc memory acc, bool down) private returns (bool, string memory) {
        int256 t = down ? int256(env.lower) - 2 * env.key.tickSpacing : int256(env.upper) + 2 * env.key.tickSpacing;
        if (t <= TickMath.MIN_TICK) t = TickMath.MIN_TICK + 1;
        if (t >= TickMath.MAX_TICK) t = TickMath.MAX_TICK - 1;
        uint160 limit = TickMath.getSqrtPriceAtTick(int24(t));
        int256 amount = -int256(down ? env.big0 : env.big1);
        SwapRes memory h = _trySwap(_swapper, env.key, down, amount, limit);
        OpRes memory ctl;
        ctl.ok = true;
        if (env.ctlReady) ctl = _trySwap(_swapper, env.ctl, down, amount, limit).op;
        _evidence(env, 3, h.op);
        if (h.op.ok) return (true, "");
        uint8 cls = _classify(h.op, ctl);
        acc.eRan++;
        if (cls == 2) acc.eUnexpected++;
        if (cls == 1) acc.eRefusal++;
        if (cls == 3) acc.eBoth++;
        if (cls == 4) acc.eInfra++;
        return (false, string.concat("large ", down ? "0->1" : "1->0", " exactIn swap reverted: ", h.op.err.text, _clsNote(cls)));
    }

    /// @dev adds `line` unless a line with the same `reason` was added before (per check)
    function _addOnce(Acc memory acc, Lines memory L, string memory check, string memory reason, string memory line) private pure {
        bytes32 h = keccak256(abi.encodePacked(check, reason));
        for (uint256 i; i < acc.nSeen; i++) {
            if (acc.seen[i] == h) {
                acc.repeats++;
                return;
            }
        }
        if (acc.nSeen < acc.seen.length) acc.seen[acc.nSeen++] = h;
        L.add(line);
    }

    function _clsNote(uint8 cls) private pure returns (string memory) {
        if (cls == 1) return " [explicit error from the hook: refusal, possibly by design]";
        if (cls == 3) return " [the hook-less control pool reverts as well: not attributed to the hook, and NOT cleared either]";
        if (cls == 4) return " [PROBE FAILURE: the checker's own tooling failed, no evidence either way]";
        return " [UNEXPECTED]";
    }

    function _swapsIn(Env memory env, Acc memory acc, uint8 sc) private {
        string memory line = string.concat(_scenarioName(sc), ":");
        for (uint8 c; c < 4; c++) {
            line = string.concat(line, " | ", _comboName(c), " ", _oneSwap(env, acc, sc, c, _amount(env, c), true));
        }
        if (sc == SC_BASELINE) {
            // sizes at both ends, baseline only
            line = string.concat(line, " | 1 wei 0->1 ", _oneSwap(env, acc, sc, 0, -1, false));
            line = string.concat(line, " | 1 wei 1->0 ", _oneSwap(env, acc, sc, 2, -1, false));
            line = string.concat(line, " | 100x 0->1 ", _oneSwap(env, acc, sc, 0, -int256(env.amt0 * 100), false));
            line = string.concat(line, " | 100x 1->0 ", _oneSwap(env, acc, sc, 2, -int256(env.amt1 * 100), false));
            line = string.concat(line, " | 100x 0->1 exactOut ", _oneSwap(env, acc, sc, 1, int256(env.amt1 * 100), false));
            line = string.concat(line, " | 100x 1->0 exactOut ", _oneSwap(env, acc, sc, 3, int256(env.amt0 * 100), false));
        }
        acc.e.add(line);
    }

    /// @dev one swap on the hooked pool and the same swap on the control pool, each rolled back
    function _oneSwap(Env memory env, Acc memory acc, uint8 sc, uint8 combo, int256 amount, bool standard)
        private
        returns (string memory token)
    {
        uint256 snap = vm.snapshotState();
        SwapRes memory h = _trySwap(_swapper, env.key, combo < 2, amount, 0);
        OpRes memory ctl;
        ctl.ok = true;
        if (env.ctlReady) ctl = _trySwap(_swapper, env.ctl, combo < 2, amount, 0).op;
        _taintCheck(env); // before the rollback, see _runScenarios
        _rollback(snap);

        _evidence(env, 3, h.op);
        acc.eRan++;
        if (sc == SC_BASELINE && standard) {
            acc.base[combo] = h.out;
            acc.baseOk[combo] = h.op.ok;
        }
        if (h.op.ok) {
            acc.eOk++;
            if (!env.dynamicFee) return "ok";
            _feeSeen(acc, h.out);
            return string.concat("ok fee=", vm.toString(h.out.fee));
        }
        if (h.op.err.outer == LPFeeLibrary.LPFeeTooLarge.selector) acc.feeTooLarge = true;
        uint8 cls = _classify(h.op, ctl);
        if (cls == 1) {
            acc.eRefusal++;
            if (sc == SC_BASELINE) acc.eBaselineRefusal++;
        } else if (cls == 3) {
            acc.eBoth++;
        } else if (cls == 4) {
            acc.eInfra++;
        } else {
            acc.eUnexpected++;
        }
        _addOnce(
            acc,
            acc.e,
            "e",
            h.op.err.text,
            string.concat("  first seen in: ", _scenarioName(sc), ", ", _comboName(combo), " amount ", vm.toString(amount), ": REVERT ", h.op.err.text, _clsNote(cls))
        );
        if (cls == 3) return "reverts (also without hook)";
        if (cls == 4) return "PROBE FAILED";
        return cls == 1 ? "REFUSED" : "REVERT";
    }

    function _feeSeen(Acc memory acc, SwapOut memory o) private pure {
        if (!o.sawEvent) return;
        acc.feeSeen++;
        if (o.fee < acc.feeMin) acc.feeMin = o.fee;
        if (o.fee > acc.feeMax) acc.feeMax = o.fee;
        if (o.fee >= LPFeeLibrary.MAX_LP_FEE) acc.feeFull = true;
    }

    function _removalsIn(Env memory env, Acc memory acc, uint8 sc) private {
        string[4] memory labels = [
            "collect fees only (liquidityDelta = 0)",
            "LP A removes half",
            "LP A removes the rest",
            "LP B removes everything (last of the checker's liquidity)"
        ];
        int256[4] memory deltas = [int256(0), -(env.liq / 2), -(env.liq - env.liq / 2), -env.liq];
        string[4] memory short = ["fees-only", "half", "rest", "last-LP"];
        string memory line = string.concat(_scenarioName(sc), ":");
        for (uint256 s; s < 4; s++) {
            if (s == 3 && (sc == SC_SINGLE_LP || !env.hasB)) continue;
            CheckerRouter r = s == 3 ? _lpB : _lpA;
            ModRes memory h = _tryModify(r, env.key, env.lower, env.upper, deltas[s]);
            ModRes memory ctl;
            ctl.op.ok = true;
            if (env.ctlReady) ctl = _tryModify(r, env.ctl, env.lower, env.upper, deltas[s]);
            _evidence(env, 2, h.op);
            acc.dRan++;
            if (sc == SC_BASELINE && (s == 1 || s == 2)) {
                acc.backHook[0] += h.a0;
                acc.backHook[1] += h.a1;
                acc.backCtl[0] += ctl.a0;
                acc.backCtl[1] += ctl.a1;
                if (s == 2) acc.backOk = h.op.ok && ctl.op.ok && env.ctlReady;
            }
            if (h.op.ok) {
                acc.dOk++;
                line = string.concat(line, " | ", short[s], " ok");
                continue;
            }
            uint8 cls = _classify(h.op, ctl.op);
            if (cls == 3) {
                // the control pool reverts as well: not counted against the hook, and not counted as fine
                acc.dBoth++;
                line = string.concat(line, " | ", short[s], " reverts (also without hook)");
            } else if (cls == 4) {
                acc.dInfra++;
                line = string.concat(line, " | ", short[s], " PROBE FAILED");
            } else {
                acc.dFail++;
                line = string.concat(line, " | ", short[s], " REVERT");
            }
            _addOnce(
                acc, acc.d, "d", h.op.err.text,
                string.concat("  first seen in: ", _scenarioName(sc), ", ", labels[s], ": REVERT ", h.op.err.text, cls == 1 || cls == 2 ? "" : _clsNote(cls))
            );
        }
        acc.d.add(line);
    }

    /// @dev Identical tiny swaps in ONE block with a large opposite swap before the last one, once per
    ///      direction. If the fee of an identical swap changes within the block, the fee depends on
    ///      something a single transaction can move.
    function _sameBlockFees(Env memory env, Acc memory acc) private {
        (bool ran0, bool diff0) = _sameBlockDir(env, acc, true);
        (bool ran1, bool diff1) = _sameBlockDir(env, acc, false);
        acc.sameBlockRan = ran0 && ran1;
        acc.sameBlockDiff = diff0 || diff1;
    }

    function _sameBlockDir(Env memory env, Acc memory acc, bool zeroForOne) private returns (bool ran, bool diff) {
        uint256 snap = vm.snapshotState();
        int256 tiny = -int256((zeroForOne ? env.amt0 : env.amt1) / 10 + 1);
        int256 large = -int256((zeroForOne ? env.amt1 : env.amt0) * 60);
        // a priming swap first: whatever the hook does once per block or per time bucket happens here
        // and is not part of the comparison
        bool primed = _trySwap(_swapper, env.key, zeroForOne, tiny, 0).op.ok;
        SwapRes memory s1 = _trySwap(_swapper, env.key, zeroForOne, tiny, 0);
        SwapRes memory s2 = _trySwap(_swapper, env.key, zeroForOne, tiny, 0);
        SwapRes memory big = _trySwap(_swapper, env.key, !zeroForOne, large, 0);
        SwapRes memory s3 = _trySwap(_swapper, env.key, zeroForOne, tiny, 0);
        _taintCheck(env); // before the rollback, see _runScenarios
        _rollback(snap);
        string memory dir = zeroForOne ? "0->1" : "1->0";
        string memory opp = zeroForOne ? "1->0" : "0->1";
        if (!(primed && s1.op.ok && s2.op.ok && big.op.ok && s3.op.ok && s1.out.sawEvent && s2.out.sawEvent && s3.out.sawEvent)) {
            acc.f.add(string.concat("same-block test, tiny ", dir, " swaps: could not run (one of the five swaps reverted)"));
            return (false, false);
        }
        ran = true;
        diff = s1.out.fee != s2.out.fee || s1.out.fee != s3.out.fee;
        acc.f.add(
            string.concat(
                "same block, same gas price, after one priming swap: identical tiny ", dir, " swaps pay fee ", vm.toString(s1.out.fee), " -> ",
                vm.toString(s2.out.fee), " -> (after a large ", opp, " swap at fee ", vm.toString(big.out.fee), ") -> ", vm.toString(s3.out.fee)
            )
        );
    }

    // =============================================================================================
    // a. permission bits
    // =============================================================================================

    function _flagNames(uint160 flags) private pure returns (string memory s) {
        string[14] memory names = [
            "beforeInitialize", "afterInitialize", "beforeAddLiquidity", "afterAddLiquidity", "beforeRemoveLiquidity",
            "afterRemoveLiquidity", "beforeSwap", "afterSwap", "beforeDonate", "afterDonate", "beforeSwapReturnDelta",
            "afterSwapReturnDelta", "afterAddLiquidityReturnDelta", "afterRemoveLiquidityReturnDelta"
        ];
        for (uint256 k; k < 14; k++) {
            if (flags & (uint160(1) << uint160(13 - k)) != 0) s = string.concat(s, bytes(s).length == 0 ? "" : ", ", names[k]);
        }
        if (bytes(s).length == 0) s = "(none)";
    }

    /// @dev calldata PoolManager would send for callback k on the pool under test
    /// @param sender the `sender` ARGUMENT of the callback (the router, when PoolManager makes the call)
    function _cbData(Env memory env, uint256 k, address sender, bytes memory hookData) private view returns (bytes memory) {
        PoolKey memory key = env.key;
        if (address(key.hooks) == address(0)) {
            // no pool: a syntactically valid key that names the hook
            key = PoolKey(Currency.wrap(address(0x1111)), Currency.wrap(address(0x2222)), 3000, 60, IHooks(_hook));
        }
        int24 lo = env.upper > env.lower ? env.lower : int24(-600);
        int24 hi = env.upper > env.lower ? env.upper : int24(600);
        int256 liq = env.liq > 0 ? env.liq : int256(1e18);
        uint160 price = TickMath.getSqrtPriceAtTick(INIT_TICK);
        if (k == 0) return abi.encodeCall(IHooks.beforeInitialize, (sender, key, price));
        if (k == 1) return abi.encodeCall(IHooks.afterInitialize, (sender, key, price, INIT_TICK));
        if (k == 2) return abi.encodeCall(IHooks.beforeAddLiquidity, (sender, key, ModifyLiquidityParams(lo, hi, liq, 0), hookData));
        if (k == 3) {
            return abi.encodeCall(
                IHooks.afterAddLiquidity,
                (sender, key, ModifyLiquidityParams(lo, hi, liq, 0), toBalanceDelta(-1e15, -1e15), toBalanceDelta(0, 0), hookData)
            );
        }
        if (k == 4) return abi.encodeCall(IHooks.beforeRemoveLiquidity, (sender, key, ModifyLiquidityParams(lo, hi, -liq, 0), hookData));
        if (k == 5) {
            return abi.encodeCall(
                IHooks.afterRemoveLiquidity,
                (sender, key, ModifyLiquidityParams(lo, hi, -liq, 0), toBalanceDelta(1e15, 1e15), toBalanceDelta(0, 0), hookData)
            );
        }
        SwapParams memory sp = SwapParams(true, -1e15, TickMath.MIN_SQRT_PRICE + 1);
        if (k == 6) return abi.encodeCall(IHooks.beforeSwap, (sender, key, sp, hookData));
        if (k == 7) return abi.encodeCall(IHooks.afterSwap, (sender, key, sp, toBalanceDelta(-1e15, 9e14), hookData));
        if (k == 8) return abi.encodeCall(IHooks.beforeDonate, (sender, key, 1e12, 1e12, hookData));
        return abi.encodeCall(IHooks.afterDonate, (sender, key, 1e12, 1e12, hookData));
    }

    /// @return st 1 answers like an implemented callback, 2 missing / stub, 3 reverts for another reason
    ///            (inconclusive), 4 answer PoolManager would reject, 5 gas exhaustion, 0 probe failed
    function _directImpl(Env memory env, uint256 k) private returns (uint8 st, string memory text) {
        Probe memory p = _probe(address(_m), address(0), _cbData(env, k, address(_swapper), ""), true);
        if (!p.infraOk) return (0, "probe did not complete");
        if (p.ok) {
            bytes32 w;
            if (p.ret.length >= 32) {
                bytes memory ret = p.ret;
                assembly ("memory-safe") {
                    w := mload(add(ret, 0x20))
                }
            }
            bool selOk = p.retSize >= 32 && w == bytes32(_cbSelector(k));
            uint256 want = k == 6 ? 96 : ((k == 3 || k == 5 || k == 7) ? 64 : 32);
            bool exact = k == 6 || (k == 7 && env.flags & Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG != 0)
                || (k == 3 && env.flags & Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG != 0)
                || (k == 5 && env.flags & Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG != 0);
            if (selOk && (!exact || p.retSize == want)) return (1, "called as PoolManager: returns its selector");
            return (4, string.concat("called as PoolManager: returned ", vm.toString(p.retSize), " bytes that PoolManager would reject (InvalidHookResponse)"));
        }
        if (p.oog) return (5, "called as PoolManager: ran out of gas");
        RevertInfo.Info memory info = RevertInfo.decode(p.ret);
        if (RevertInfo.looksUnimplemented(info)) {
            bool pushed = BytecodeScan.pushesSelector(env.code, _cbSelector(k));
            return (2, string.concat("called as PoolManager: ", info.text, pushed ? "" : "; its selector does not occur in the bytecode"));
        }
        return (3, string.concat("called as PoolManager with synthetic arguments: ", info.text));
    }

    function _checkPermissions(Env memory env) private returns (Finding memory f) {
        f = _blank(A_PERMISSIONS);
        Lines memory L = LinesLib.make();
        L.add(string.concat("address bits 0x", _hex4(env.flags), ": ", _flagNames(env.flags)));

        // leg 1: pairing rules PoolManager enforces at initialize (Hooks.isValidHookAddress)
        bool pairBad = _pairingBad(env.flags);
        if (pairBad) L.add("return-delta bit without its base bit: PoolManager.initialize rejects this address (HookAddressNotValid)");
        if (env.flags == 0) L.add("no bit set: the address is only valid for dynamic-fee pools and no callback is ever called");

        // leg 2: getHookPermissions(), if exposed
        (bool exposed, uint160 claimed) = _claimedPermissions();
        bool mismatch = exposed && claimed != env.flags;
        if (!exposed) {
            L.add("getHookPermissions(): not exposed or not decodable as 14 booleans, this leg is skipped");
        } else if (mismatch) {
            L.add(string.concat("getHookPermissions() MISMATCH: contract claims 0x", _hex4(claimed), " = ", _flagNames(claimed)));
            L.add(string.concat("  set in the address only: ", _flagNames(env.flags & ~claimed), "; claimed only: ", _flagNames(claimed & ~env.flags)));
        } else {
            L.add("getHookPermissions(): equal to the address bits");
        }

        // leg 3: behaviour of each callback
        uint256 broken;
        uint256 unclear;
        bool removeBroken;
        for (uint256 k; k < 10; k++) {
            (uint8 st, string memory text) = _implState(env, k);
            if (!_declared(env.flags, k)) {
                if (st == 1) L.add(string.concat(RevertInfo.callbackName(_cbSelector(k)), ": not declared in the address, but ", text, " (PoolManager never calls it)"));
                continue;
            }
            string memory verdict = st == 1 ? "implemented" : (st == 2 || st == 4) ? "DECLARED BUT NOT USABLE" : "inconclusive";
            L.add(string.concat(RevertInfo.callbackName(_cbSelector(k)), ": ", verdict, " - ", text));
            if (st == 2 || st == 4) {
                broken++;
                if (k == 4 || k == 5) removeBroken = true;
            } else if (st != 1) {
                unclear++;
            }
        }

        if (removeBroken) {
            f.status = Status.FAIL;
            f.summary = "a remove-liquidity callback is declared in the address but not usable: every withdrawal reverts, liquidity is stuck";
        } else if (broken > 0 || mismatch || pairBad) {
            f.status = Status.FAIL;
            f.summary = string.concat(
                vm.toString(broken), " declared callback(s) not usable", mismatch ? "; getHookPermissions() differs from the address" : "",
                pairBad ? "; return-delta bit without base bit" : ""
            );
        } else if (unclear > 0) {
            f.status = Status.UNKNOWN;
            f.summary = string.concat(vm.toString(unclear), " declared callback(s) could not be exercised (no usable pool or the hook refused the probe)");
        } else {
            f.status = Status.PASS;
            f.summary = exposed
                ? "address bits, getHookPermissions() and observed behaviour agree"
                : "address bits and observed behaviour agree (getHookPermissions() not exposed)";
        }
        f.details = L.done();
    }

    function _pairingBad(uint160 flags) private pure returns (bool) {
        if (flags & Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG != 0 && flags & Hooks.BEFORE_SWAP_FLAG == 0) return true;
        if (flags & Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG != 0 && flags & Hooks.AFTER_SWAP_FLAG == 0) return true;
        if (flags & Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG != 0 && flags & Hooks.AFTER_ADD_LIQUIDITY_FLAG == 0) return true;
        if (flags & Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG != 0 && flags & Hooks.AFTER_REMOVE_LIQUIDITY_FLAG == 0) return true;
        return false;
    }

    function _claimedPermissions() private view returns (bool exposed, uint160 claimed) {
        SafeCall.Result memory r = SafeCall.staticcall(_hook, VIEW_GAS, abi.encodeWithSignature("getHookPermissions()"), 448);
        if (!r.ok || r.retSize != 448) return (false, 0);
        for (uint256 k; k < 14; k++) {
            (, bytes32 w) = SafeCall.wordAt(r.ret, k * 32);
            if (uint256(w) > 1) return (false, 0);
            if (uint256(w) == 1) claimed |= uint160(1) << uint160(13 - k);
        }
        return (true, claimed);
    }

    /// @dev real flows first (they are what PoolManager does); a direct call only when no flow reached it
    function _implState(Env memory env, uint256 k) private returns (uint8 st, string memory text) {
        uint16 bit = uint16(1 << k);
        if (env.evOk & bit != 0) return (1, "a real PoolManager operation went through it");
        if (env.evMissing & bit != 0) return (2, string.concat("a real PoolManager operation failed in it: ", env.evNote[k]));
        (st, text) = _directImpl(env, k);
        if (env.evOther & bit != 0 && st != 1) {
            return (3, string.concat("a real PoolManager operation failed in it: ", env.evNote[k]));
        }
    }

    // =============================================================================================
    // b. callbacks callable by anyone
    // =============================================================================================

    struct CallerRes {
        uint8 worst; // 0 rejected, 1 accepted without visible effect, 2 accepted with effect
        bool indistinct; // rejected, but the PoolManager is rejected in exactly the same way
        string note;
        uint256 failed; // probes that did not complete
        uint256 tried;
    }

    /// @dev one probe input: the callback's `sender` argument, tx.origin (0 = unchanged), hookData
    struct ProbeIn {
        address sender;
        address origin;
        bytes hookData;
        string label;
    }

    /// @dev The inputs every callback is probed with by ATTACKER. They vary the three things a weak
    ///      caller check is most often keyed on instead of msg.sender; they are a handful of fixed values,
    ///      not a search. Callbacks 0 and 1 (initialize) carry no hookData.
    function _probeInputs(bool hasHookData) private view returns (ProbeIn[] memory v) {
        v = new ProbeIn[](hasHookData ? 11 : 6);
        address router = address(_swapper);
        v[0] = ProbeIn(router, address(0), "", "sender = checker router");
        v[1] = ProbeIn(ATTACKER, address(0), "", "sender = the caller");
        v[2] = ProbeIn(_hook, address(0), "", "sender = the hook");
        v[3] = ProbeIn(address(_m), address(0), "", "sender = the PoolManager");
        v[4] = ProbeIn(router, ATTACKER, "", "tx.origin = the caller");
        v[5] = ProbeIn(ATTACKER, ATTACKER, "", "sender = tx.origin = the caller");
        if (!hasHookData) return v;
        v[6] = ProbeIn(router, address(0), abi.encode(ATTACKER, uint256(1e18)), "64-byte hookData (an address and an amount)");
        v[7] = ProbeIn(router, address(0), hex"01", "1-byte hookData");
        v[8] = ProbeIn(router, address(0), hex"00000001", "4-byte hookData");
        v[9] = ProbeIn(router, address(0), abi.encodePacked(ATTACKER), "20-byte hookData");
        v[10] = ProbeIn(router, address(0), abi.encode(ATTACKER), "32-byte hookData");
    }

    /// @dev callback k called by ATTACKER with every probe input, outside and inside an unlock
    function _callerProbe(Env memory env, uint256 k) private returns (CallerRes memory c) {
        ProbeIn[] memory ins = _probeInputs(k >= 2);
        for (uint256 i; i < ins.length; i++) {
            bytes memory data = _cbData(env, k, ins[i].sender, ins[i].hookData);
            for (uint256 u; u < 2; u++) {
                c.tried++;
                Probe memory p = _probe(ATTACKER, ins[i].origin, data, u == 1);
                if (!p.infraOk) {
                    c.failed++;
                    continue;
                }
                if (!p.ok) {
                    _rejected(env, k, c, p, (i == 0 || i == 6) && u == 1 ? data : bytes(""));
                    continue;
                }
                bool effect = p.writes > 0 || p.valueMoved || p.logs > 0;
                string memory how = string.concat(u == 1 ? "inside an unlock, " : "outside an unlock, ", ins[i].label);
                if (effect && c.worst < 2) {
                    c.worst = 2;
                    c.note = string.concat(
                        how, ": ", vm.toString(p.writes), " storage slot(s) changed (", vm.toString(p.hookWrites), " in the hook), ",
                        vm.toString(p.logs), " event(s)", p.valueMoved ? ", ETH moved or contract created" : ""
                    );
                } else if (!effect && c.worst == 0) {
                    c.worst = 1;
                    c.note = how;
                }
            }
        }
    }

    /// @param cmp non-empty: also send the same call from the PoolManager and compare the revert
    function _rejected(Env memory env, uint256 k, CallerRes memory c, Probe memory p, bytes memory cmp) private {
        RevertInfo.Info memory info = RevertInfo.decode(p.ret);
        if (bytes(c.note).length == 0) c.note = info.text;
        // Same arguments, same context, but sent by the PoolManager. If a declared callback reverts in
        // exactly the same way for both, the rejection is about the arguments, not about the caller,
        // and says nothing about a caller check.
        if (cmp.length == 0 || c.indistinct || !_declared(env.flags, k) || RevertInfo.looksUnimplemented(info)) return;
        Probe memory m = _probe(address(_m), address(0), cmp, true);
        if (m.infraOk && !m.ok && m.retSize == p.retSize && keccak256(m.ret) == keccak256(p.ret)) {
            c.indistinct = true;
            c.note = info.text;
        }
    }

    function _checkCaller(Env memory env) private returns (Finding memory f) {
        f = _blank(B_CALLER);
        Lines memory L = LinesLib.make();
        uint256 accepted;
        uint256 withEffect;
        uint256 indistinct;
        uint256 failedProbes;
        uint256 tried;
        for (uint256 k; k < 10; k++) {
            CallerRes memory c = _callerProbe(env, k);
            failedProbes += c.failed;
            tried += c.tried;
            string memory name = RevertInfo.callbackName(_cbSelector(k));
            if (c.worst == 0 && c.indistinct) {
                indistinct++;
                L.add(string.concat(name, ": reverts, but in exactly the same way when the PoolManager sends the same call (", c.note, "): not a caller check, inconclusive"));
            } else if (c.worst == 0) {
                L.add(string.concat(name, ": rejected in all ", vm.toString(c.tried - c.failed), " completed probes (first reason: ", c.note, ")"));
            } else if (c.worst == 1) {
                accepted++;
                L.add(string.concat(name, ": ACCEPTED from a non-PoolManager address (first: ", c.note, "), no state change observed with these inputs"));
            } else {
                accepted++;
                withEffect++;
                L.add(string.concat(name, ": ACCEPTED from a non-PoolManager address AND CHANGED STATE - ", c.note));
            }
        }
        L.add(
            string.concat(
                "probe inputs (", vm.toString(tried),
                " calls in all, each from an address with no role): the sender ARGUMENT set to the checker's router / the caller / the hook / the PoolManager; tx.origin left alone / set to the caller; hookData empty and 1, 4, 20, 32, 64 bytes; each outside and inside an unlock"
            )
        );
        if (withEffect > 0) {
            f.status = Status.FAIL;
            f.summary = string.concat(vm.toString(withEffect), " callback(s) can be called by anyone and change state (the pattern behind the Cork incident)");
        } else if (accepted > 0 && BytecodeScan.cannotChangeState(env.ops)) {
            f.status = Status.PASS;
            f.summary = string.concat(
                vm.toString(accepted),
                " callback(s) accept any caller; a full sweep of the bytecode (", vm.toString(env.ops.scannedLength),
                " bytes, nothing cut off) finds no SSTORE / TSTORE / LOG / CALL / CALLCODE / DELEGATECALL / CREATE / SELFDESTRUCT, so this code itself cannot write state or call out (what its return values make a caller do is not judged)"
            );
        } else if (accepted > 0) {
            f.status = Status.UNKNOWN;
            f.summary = string.concat(
                vm.toString(accepted),
                " callback(s) accept any caller; no state change observed with the probe inputs, which proves nothing for other inputs (and transient storage is not visible): needs a human"
            );
        } else if (indistinct > 0) {
            f.status = Status.UNKNOWN;
            f.summary = string.concat(
                vm.toString(indistinct),
                " declared callback(s) revert for a stranger exactly as they do for the PoolManager: the probe arguments were refused before any caller check could show: needs a human"
            );
        } else if (failedProbes > 0) {
            f.status = Status.UNKNOWN;
            f.summary = string.concat(vm.toString(failedProbes), " of ", vm.toString(tried), " probe(s) did not complete");
        } else {
            f.status = Status.PASS;
            f.summary = string.concat(
                "every one of the 10 callbacks rejected a non-PoolManager caller under these ", vm.toString(tried),
                " probe inputs (listed in the details), and not in the way it answers the PoolManager. A caller check with a bypass keyed on any OTHER input (a specific sender, tx.origin or hookData value) is not ruled out"
            );
        }
        f.details = L.done();
    }

    // =============================================================================================
    // c. foreign pool
    // =============================================================================================

    /// @notice One recorded flow, always rolled back. With `withStranger`, a stranger first creates
    ///         pools on the same hook (own tokens at a different price; and one that shares currency0
    ///         with the pool under test) and trades in them; then the reference pool does a fixed sequence
    ///         of operations (6 swaps, fee collection, partial withdrawal, small add) whose outcomes are
    ///         returned.
    function opFlow(bool withStranger, FlowArgs calldata a) external onlySelf {
        FlowOut memory o;
        o.written = new bytes32[](0);
        o.touched = new bytes32[](0);
        bool cut;
        if (withStranger) {
            vm.startStateDiffRecording();
            _strangerActivity(a, o);
            (o.written, cut) = _hookSlots(vm.stopAndReturnStateDiff(), true);
            o.truncated = cut;
        }
        if (a.refReady) {
            vm.startStateDiffRecording();
            _refOps(a, o);
            (o.touched, cut) = _hookSlots(vm.stopAndReturnStateDiff(), false);
            o.truncated = o.truncated || cut;
        }
        revert FlowDone(abi.encode(o));
    }

    function _refOps(FlowArgs calldata a, FlowOut memory o) private {
        for (uint8 c; c < 6; c++) {
            if (c == 4) _advance(1 hours, 1800);
            uint8 combo = c < 4 ? c : (c == 4 ? 0 : 2);
            int256 amount = combo == 0 ? -int256(a.amt0) : combo == 1 ? int256(a.amt1) : combo == 2 ? -int256(a.amt1) : int256(a.amt0);
            SwapRes memory s = _trySwap(_swapper, a.key, combo < 2, amount, 0);
            o.ok[c] = s.op.ok;
            o.err[c] = s.op.err.inner;
            o.outs[c] = s.out;
            o.fromHook[c] = _fromHook(s.op);
            o.opInfra[c] = s.op.infra;
            o.infra = o.infra || s.op.infra;
        }
        // what an LP of the pool under test does: collect fees, take a part out, put a little in
        int256[3] memory deltas = [int256(0), -(a.liq / 4), a.liq / 8];
        for (uint256 j; j < 3; j++) {
            ModRes memory m = _tryModify(_lpA, a.key, a.lower, a.upper, deltas[j]);
            o.ok[6 + j] = m.op.ok;
            o.err[6 + j] = m.op.err.inner;
            o.l0[j] = m.a0;
            o.l1[j] = m.a1;
            o.fromHook[6 + j] = _fromHook(m.op);
            o.opInfra[6 + j] = m.op.infra;
            o.infra = o.infra || m.op.infra;
        }
        // an operation can succeed and still leave the tooling broken behind it
        o.infra = o.infra || _toolingBroken();
    }

    function _strangerActivity(FlowArgs calldata a, FlowOut memory o) private {
        (bool accepted, PoolKey memory k) = _strangerInit(a, o);
        if (accepted) {
            o.strangerAccepted = true;
            _strangerTrade(k, o, false);
        }
        _strangerExtremes(a, o);
        // the stranger's activity counts only if the tooling is still whole after it
        o.infra = o.infra || _toolingBroken();
        if (!a.shareCurrency) return;
        (accepted, k) = _strangerInitShared(a, o);
        if (accepted) {
            o.strangerAccepted = true;
            _strangerTrade(k, o, false);
        }
        o.infra = o.infra || _toolingBroken();
    }

    /// @dev Two more pools of the stranger, with its own tokens and parameters at the edge of what
    ///      PoolManager accepts (anyone can create such a pool on any hook): the largest tickSpacing, with
    ///      an initial price one tick above the minimum and one tick below the maximum. Same fee as the
    ///      pool under test. (Not the smallest tickSpacing: a swap across the whole price range then walks
    ///      some 7,000 words of the tick bitmap, each a storage read that a fork has to fetch from the RPC.)
    function _strangerExtremes(FlowArgs calldata a, FlowOut memory o) private {
        uint24 fee = address(a.key.hooks) == _hook ? a.key.fee : LPFeeLibrary.DYNAMIC_FEE_FLAG;
        int24[2] memory ticks = [TickMath.MIN_TICK + 1, TickMath.MAX_TICK - 1];
        for (uint256 i; i < 2; i++) {
            MockERC20 x = new MockERC20("Stranger E", "STE", 18);
            MockERC20 y = new MockERC20("Stranger F", "STF", 18);
            x.mint(address(_stranger), 1e30);
            y.mint(address(_stranger), 1e30);
            PoolKey memory k;
            k.currency0 = Currency.wrap(address(x) < address(y) ? address(x) : address(y));
            k.currency1 = Currency.wrap(address(x) < address(y) ? address(y) : address(x));
            k.fee = fee;
            k.tickSpacing = TickMath.MAX_TICK_SPACING;
            k.hooks = IHooks(_hook);
            OpRes memory r = _tryInit(_stranger, k, TickMath.getSqrtPriceAtTick(ticks[i]));
            o.infra = o.infra || r.infra;
            o.strangerNote = string.concat(
                o.strangerNote, " || extreme parameters (own two tokens, initial tick ", vm.toString(ticks[i]), "): ", _keyBrief(k), ": ",
                r.ok ? "ACCEPTED" : string.concat("rejected (", r.err.text, ")")
            );
            if (r.ok) {
                o.strangerAccepted = true;
                _strangerTrade(k, o, true);
            }
        }
    }

    /// @param extreme false: a position around STRANGER_TICK; true: a full-range position
    function _strangerTrade(PoolKey memory k, FlowOut memory o, bool extreme) private {
        int24 sp = k.tickSpacing;
        int24 base = (STRANGER_TICK / sp) * sp - sp;
        int24 lo = extreme ? (TickMath.MIN_TICK / sp) * sp : base - 120 * sp;
        int24 hi = extreme ? (TickMath.MAX_TICK / sp) * sp : base + 121 * sp;
        bool liq = _tryModify(_stranger, k, lo, hi, extreme ? STRANGER_EXTREME_LIQ : STRANGER_LIQ).op.ok;
        uint256 okSwaps;
        // small both ways, then all the way down and all the way up (no price limit to speak of): moves
        // the stranger pool's tick, price and volume as far as they can go
        if (_trySwap(_stranger, k, true, -1e18, 0).op.ok) okSwaps++;
        if (_trySwap(_stranger, k, false, -1e18, 0).op.ok) okSwaps++;
        if (_trySwap(_stranger, k, true, -1e27, 0).op.ok) okSwaps++;
        if (_trySwap(_stranger, k, false, -1e27, 0).op.ok) okSwaps++;
        if (_trySwap(_stranger, k, true, 1e15, 0).op.ok) okSwaps++;
        bool donated = _tryDonate(_stranger, k, 1e15, 1e15).ok;
        o.strangerNote = string.concat(
            o.strangerNote, " - then in that pool: add liquidity ", liq ? "ok" : "reverted", ", ", vm.toString(okSwaps),
            "/5 swaps ok, donate ", donated ? "ok" : "reverted"
        );
    }

    /// @dev attempt 1: same fee and spacing as the pool under test (only tokens and price differ);
    ///      attempt 2: other spacing; attempt 3: the other fee type
    function _strangerInit(FlowArgs calldata a, FlowOut memory o) private returns (bool accepted, PoolKey memory k) {
        MockERC20 x = new MockERC20("Stranger X", "STX", 18);
        MockERC20 y = new MockERC20("Stranger Y", "STY", 18);
        x.mint(address(_stranger), 1e30);
        y.mint(address(_stranger), 1e30);
        bool known = address(a.key.hooks) == _hook;
        uint24 fee = known ? a.key.fee : LPFeeLibrary.DYNAMIC_FEE_FLAG;
        int24 ts = known ? a.key.tickSpacing : int24(60);
        uint24[3] memory fees = [fee, fee, fee == LPFeeLibrary.DYNAMIC_FEE_FLAG ? uint24(3000) : LPFeeLibrary.DYNAMIC_FEE_FLAG];
        int24[3] memory spacings = [ts, ts == 10 ? int24(60) : int24(10), ts];
        k.currency0 = Currency.wrap(address(x) < address(y) ? address(x) : address(y));
        k.currency1 = Currency.wrap(address(x) < address(y) ? address(y) : address(x));
        k.hooks = IHooks(_hook);
        o.strangerNote = "own two tokens: ";
        for (uint256 i; i < 3; i++) {
            k.fee = fees[i];
            k.tickSpacing = spacings[i];
            OpRes memory r = _tryInit(_stranger, k, TickMath.getSqrtPriceAtTick(STRANGER_TICK));
            o.infra = o.infra || r.infra;
            o.strangerNote = string.concat(o.strangerNote, i == 0 ? "" : "; ", _keyBrief(k), ": ", r.ok ? "ACCEPTED" : string.concat("rejected (", r.err.text, ")"));
            if (r.ok) return (true, k);
        }
    }

    /// @dev a pool of the stranger that shares currency0 with the pool under test (the other token is the
    ///      stranger's own), same fee and spacing: reaches state a hook keeps per currency instead of per pool
    function _strangerInitShared(FlowArgs calldata a, FlowOut memory o) private returns (bool accepted, PoolKey memory k) {
        Currency shared = a.key.currency0;
        // The stranger's own token has to sort AFTER the shared one, so that the shared token is currency0
        // in this pool as it is in the pool under test: a hook that books per `key.currency0` is only
        // reached then. The address of a contract created here depends on this contract's nonce only, so
        // nonces are skipped until it fits (up to 64; left to chance before, which made the outcome of
        // this check depend on how many contracts had been created earlier).
        uint64 nonce = vm.getNonce(address(this));
        for (uint64 i; i < 64; i++) {
            if (vm.computeCreateAddress(address(this), nonce + i) > Currency.unwrap(shared)) {
                if (i != 0) vm.setNonce(address(this), nonce + i);
                break;
            }
        }
        MockERC20 z = new MockERC20("Stranger Z", "STZ", 18);
        z.mint(address(_stranger), 1e30);
        bool funded = true;
        if (shared.isAddressZero()) vm.deal(address(_stranger), 1e30);
        else funded = _tryDeal(Currency.unwrap(shared), address(_stranger), 1e30);
        bool sharedFirst = Currency.unwrap(shared) < address(z);
        k.currency0 = sharedFirst ? shared : Currency.wrap(address(z));
        k.currency1 = sharedFirst ? Currency.wrap(address(z)) : shared;
        k.fee = a.key.fee;
        k.tickSpacing = a.key.tickSpacing;
        k.hooks = IHooks(_hook);
        OpRes memory r = _tryInit(_stranger, k, TickMath.getSqrtPriceAtTick(STRANGER_TICK));
        o.infra = o.infra || r.infra;
        o.strangerNote = string.concat(
            o.strangerNote, " || sharing currency0 of the pool under test, other token its own", funded ? "" : " (could not be given a balance of the shared token)",
            sharedFirst ? "" : " (the shared token is currency1 in this pool: no fitting address for the other token)",
            ": ", _keyBrief(k), ": ", r.ok ? "ACCEPTED" : string.concat("rejected (", r.err.text, ")")
        );
        return (r.ok, k);
    }

    function _keyBrief(PoolKey memory k) private pure returns (string memory) {
        return string.concat("fee ", k.fee == LPFeeLibrary.DYNAMIC_FEE_FLAG ? "DYNAMIC" : vm.toString(k.fee), " spacing ", vm.toString(k.tickSpacing));
    }

    /// @param netWrites true: slots of the hook whose value differs between the start and the end of
    ///        the recording; false: every slot of the hook that was read or written
    /// @return out the slots, at most SLOT_CAP of them
    /// @return truncated more than SLOT_CAP distinct slots were seen: `out` is incomplete and nothing may
    ///         be concluded from a slot NOT being in it
    function _hookSlots(Vm.AccountAccess[] memory acc, bool netWrites) private view returns (bytes32[] memory out, bool truncated) {
        uint256 cap = SLOT_CAP;
        bytes32[] memory slots = new bytes32[](cap);
        bytes32[] memory first = new bytes32[](cap);
        bytes32[] memory last = new bytes32[](cap);
        uint256 n;
        for (uint256 i; i < acc.length; i++) {
            if (acc[i].reverted) continue;
            Vm.StorageAccess[] memory sa = acc[i].storageAccesses;
            for (uint256 j; j < sa.length; j++) {
                if (sa[j].account != _hook || sa[j].reverted) continue;
                if (netWrites && !sa[j].isWrite) continue;
                uint256 at = n;
                for (uint256 q; q < n; q++) {
                    if (slots[q] == sa[j].slot) {
                        at = q;
                        break;
                    }
                }
                if (at == n) {
                    if (n == cap) {
                        truncated = true;
                        continue;
                    }
                    slots[n] = sa[j].slot;
                    first[n] = sa[j].previousValue;
                    n++;
                }
                last[at] = sa[j].newValue;
            }
        }
        uint256 m;
        for (uint256 q; q < n; q++) {
            if (!netWrites || first[q] != last[q]) slots[m++] = slots[q];
        }
        out = new bytes32[](m);
        for (uint256 q; q < m; q++) {
            out[q] = slots[q];
        }
    }

    function _flow(Env memory env, bool withStranger, FlowArgs memory a) private returns (bool ok, FlowOut memory o) {
        uint256 t = block.timestamp;
        uint256 n = block.number;
        SafeCall.Result memory r =
            SafeCall.call(address(this), 0, FLOW_GAS, abi.encodeCall(this.opFlow, (withStranger, a)), 131072);
        // The frame is rolled back, block number and timestamp are not. The flow itself moves them by
        // nothing, or by one hour / 1800 blocks; anything else was not the checker. Looked at before they
        // are put back, which would hide it.
        bool moved = !(block.timestamp == t && block.number == n) && !(block.timestamp == t + 1 hours && block.number == n + 1800);
        if (moved && bytes(env.taint).length == 0) {
            env.taint = string.concat(
                "the checker's footing is gone: during a recorded flow of check c block number / timestamp went to ", vm.toString(block.number), " / ",
                vm.toString(block.timestamp), ", which is not where the checker's own moves lead from ", vm.toString(n), " / ", vm.toString(t),
                " (vm.rollFork, vm.warp or vm.roll by something else). Everything observed after that is unreliable"
            );
        }
        vm.warp(t);
        vm.roll(n);
        if (r.ok || r.retSize != r.ret.length || r.ret.length < 68 || SafeCall.selector(r.ret) != FlowDone.selector) {
            return (false, o);
        }
        o = abi.decode(abi.decode(SafeCall.slice(r.ret, 4, r.ret.length - 4), (bytes)), (FlowOut));
        ok = true;
    }

    function _refOpName(uint256 c) private pure returns (string memory) {
        if (c < 4) return string.concat("swap #", vm.toString(c + 1));
        if (c < 6) return string.concat("swap #", vm.toString(c + 1), " (1 hour later)");
        if (c == 6) return "fee collection by LP A (liquidityDelta 0)";
        if (c == 7) return "partial withdrawal by LP A";
        return "small add by LP A";
    }

    /// @dev compares the 9 reference operations with and without the stranger's activity
    /// @return diffs operations whose outcome differs
    /// @return hookDiffs of those, the ones that, after the stranger's activity, revert out of a callback
    ///         of the hook (and did not fail for tooling reasons in the flow without a stranger)
    function _refDiffs(Lines memory L, FlowOut memory without, FlowOut memory with_)
        private
        pure
        returns (uint256 diffs, uint256 hookDiffs)
    {
        for (uint256 c; c < REF_OPS; c++) {
            bool same = without.ok[c] == with_.ok[c] && without.err[c] == with_.err[c];
            string memory was;
            string memory is_;
            if (c < 6) {
                SwapOut memory x = without.outs[c];
                SwapOut memory y = with_.outs[c];
                same = same && x.c0 == y.c0 && x.c1 == y.c1 && x.p0 == y.p0 && x.p1 == y.p1 && x.fee == y.fee;
                was = _swapBrief(without.ok[c], x);
                is_ = _swapBrief(with_.ok[c], y);
            } else {
                same = same && without.l0[c - 6] == with_.l0[c - 6] && without.l1[c - 6] == with_.l1[c - 6];
                was = _modBrief(without.ok[c], without.l0[c - 6], without.l1[c - 6]);
                is_ = _modBrief(with_.ok[c], with_.l0[c - 6], with_.l1[c - 6]);
            }
            if (same) continue;
            diffs++;
            bool byHook = with_.fromHook[c] && !without.opInfra[c];
            if (byHook) hookDiffs++;
            L.add(
                string.concat(
                    "reference ", _refOpName(c), " DIFFERS after the stranger pool's activity: ", was, "  ->  ", is_,
                    byHook ? " (the revert comes out of a callback of the hook)" : ""
                )
            );
        }
    }

    function _sharedSlots(Lines memory L, FlowOut memory without, FlowOut memory with_) private pure returns (uint256 shared) {
        for (uint256 i; i < with_.written.length; i++) {
            for (uint256 j; j < without.touched.length; j++) {
                if (with_.written[i] == without.touched[j]) {
                    shared++;
                    if (shared <= 8) L.add(string.concat("hook storage slot changed by the stranger pool AND used by the reference pool: ", vm.toString(with_.written[i])));
                    break;
                }
            }
        }
        L.add(
            string.concat(
                "hook slots changed by the stranger's pools: ", vm.toString(with_.written.length), "; hook slots the reference operations use: ",
                vm.toString(without.touched.length), "; in both: ", vm.toString(shared),
                with_.truncated || without.truncated ? " (INCOMPLETE: more than 1024 distinct hook slots in one recording, the rest was not tracked)" : ""
            )
        );
    }

    function _checkForeignPool(Env memory env) private returns (Finding memory f) {
        f = _blank(C_FOREIGN_POOL);
        Lines memory L = LinesLib.make();
        FlowArgs memory a = FlowArgs(
            env.key, env.poolReady && env.liqReady, env.amt0, env.amt1, env.lower, env.upper, env.liq, env.poolReady && address(env.key.hooks) == _hook
        );
        (bool ok2, FlowOut memory with_) = _flow(env, true, a);
        if (!ok2) {
            f.status = Status.UNKNOWN;
            f.summary = "the recorded flow with a stranger pool did not complete (gas cap or oversized result)";
            return f;
        }
        L.add(string.concat("a stranger (initial tick ", vm.toString(STRANGER_TICK), ") initializes pools on this hook - ", with_.strangerNote));
        f.details = L.done();

        // the same reference operations with no stranger pool at all
        bool ok1;
        FlowOut memory without;
        uint256 diffs;
        uint256 hookDiffs;
        if (a.refReady && with_.strangerAccepted) {
            (ok1, without) = _flow(env, false, a);
            if (ok1) {
                (diffs, hookDiffs) = _refDiffs(L, without, with_);
                f.details = L.done();
            }
        }
        if (bytes(env.taint).length != 0) {
            // the report is going to be void (see _run)
            f.status = Status.UNKNOWN;
            f.summary = "the environment changed under the checker during the recorded flow";
            return f;
        }
        string memory changed = string.concat(
            "a stranger's pool on the same hook changes the outcome of ", vm.toString(diffs),
            " of 9 reference operations in the pool under test (6 swaps, fee collection, partial withdrawal, small add)"
        );
        if (hookDiffs > 0) {
            // A reference operation that now reverts out of a callback of the hook is a difference made by
            // the hook. It is reported before any probe failure: nothing else in the flow can take it back.
            f.status = Status.FAIL;
            f.summary = string.concat(changed, "; ", vm.toString(hookDiffs), " of them now revert out of a callback of the hook");
            return f;
        }
        if (with_.infra) {
            f.status = Status.UNKNOWN;
            f.summary = "PROBE FAILURE: the checker's own tooling was found broken during the recorded flow (see CHECKER TOOLING BROKEN in the report); nothing concluded";
            return f;
        }
        if (!with_.strangerAccepted) {
            if (env.poolReady) {
                f.status = Status.PASS;
                f.summary = "the hook (or PoolManager) rejected every pool the stranger tried to create on it, while the pool under test exists on the same hook";
            } else {
                f.status = Status.UNKNOWN;
                f.summary = "the stranger's pools were rejected, but so was every pool the checker itself tried to create (see setup): this only shows that these test tokens / parameters are not accepted, not how the hook treats foreign pools. Give a PoolKey the hook accepts";
            }
            return f;
        }
        if (!a.refReady) {
            f.status = Status.UNKNOWN;
            f.summary = "the hook accepts a stranger's pool, and there is no reference pool to measure the effect on";
            return f;
        }
        if (!ok1 || without.infra) {
            f.status = Status.UNKNOWN;
            f.summary = "the reference flow did not complete";
            return f;
        }
        uint256 shared = _sharedSlots(L, without, with_);
        (uint256 okOps, uint256 okSwaps) = _refOk(without);
        string memory worked = string.concat(vm.toString(okOps), " of 9 succeeded without a stranger pool (", vm.toString(okSwaps), " of 6 swaps)");
        L.add(string.concat("reference operations: ", worked));
        f.details = L.done();
        if (diffs > 0) {
            f.status = Status.FAIL;
            f.summary = string.concat(changed, "; ", worked);
        } else if (okOps == 0 || okSwaps == 0) {
            // identical, but identical failures: a flow that does not work cannot show a difference
            f.status = Status.UNKNOWN;
            f.summary = string.concat(
                "stranger pool accepted; the 9 reference operations come out the same with and without it, but the comparison is empty: ", worked,
                ". Operations that already fail without a stranger pool cannot show what a stranger pool changes: needs a human"
            );
        } else if (with_.truncated || without.truncated) {
            f.status = Status.UNKNOWN;
            f.summary = string.concat(
                "stranger pool accepted; the 9 reference operations come out identical (", worked,
                "), but the hook touched more than 1024 distinct storage slots in one recording, so the shared-slot comparison is incomplete: needs a human"
            );
        } else if (shared > 0) {
            f.status = Status.UNKNOWN;
            f.summary = string.concat(
                "stranger pool accepted; it changes hook storage that the pool under test also uses, without a difference in the 9 reference operations (", worked,
                "): needs a human"
            );
        } else {
            f.status = Status.PASS;
            f.summary = string.concat(
                "stranger pool accepted, but it changed no hook storage slot that the pool under test uses, and the 9 reference operations (6 swaps, fee collection, partial withdrawal, small add; ",
                worked, ") come out identical"
            );
        }
    }

    /// @return okOps how many of the 9 reference operations succeeded, @return okSwaps how many of the 6 swaps
    function _refOk(FlowOut memory o) private pure returns (uint256 okOps, uint256 okSwaps) {
        for (uint256 c; c < REF_OPS; c++) {
            if (!o.ok[c]) continue;
            okOps++;
            if (c < 6) okSwaps++;
        }
    }

    function _modBrief(bool ok, int128 a0, int128 a1) private pure returns (string memory) {
        if (!ok) return "revert";
        return string.concat("router delta (", vm.toString(int256(a0)), ", ", vm.toString(int256(a1)), ")");
    }

    function _swapBrief(bool ok, SwapOut memory o) private pure returns (string memory) {
        if (!ok) return "revert";
        return string.concat("router delta (", vm.toString(int256(o.c0)), ", ", vm.toString(int256(o.c1)), ") fee ", vm.toString(o.fee));
    }

    // =============================================================================================
    // d, e, f: verdicts from the scenario run
    // =============================================================================================

    function _blank(uint256 idx) private pure returns (Finding memory f) {
        f = _blankFindings()[idx];
    }

    function _noPool(Env memory env, Finding memory f) private pure returns (bool) {
        if (env.poolReady && env.liqReady) return false;
        f.status = Status.UNKNOWN;
        f.summary = env.poolReady
            ? "liquidity could not be added to the test pool, nothing to exercise (see setup)"
            : "no test pool could be created with this hook, nothing to exercise (see setup; give a PoolKey the hook accepts)";
        return true;
    }

    /// @dev "S succeeded, F attributed to the hook, B reverted on both pools, T tooling failures; N scenarios not tested: ..."
    function _counts(uint256 ran, uint256 ok, uint256 hookFail, uint256 both, uint256 infra, uint256 scen, uint256 skip, string memory skipNames)
        private
        pure
        returns (string memory s)
    {
        s = string.concat(
            vm.toString(ok), " of ", vm.toString(ran), " succeeded on the hooked pool, ", vm.toString(hookFail), " reverted because of the hook, ",
            vm.toString(both), " reverted on both the hooked and the hook-less control pool, ", vm.toString(infra), " probe failure(s)"
        );
        s = string.concat(s, "; scenarios run: ", vm.toString(scen), ", NOT TESTED: ", vm.toString(skip));
        if (skip > 0) s = string.concat(s, " (", skipNames, ")");
    }

    function _findRemove(Env memory env, Acc memory acc) private pure returns (Finding memory f) {
        f = _blank(D_REMOVE);
        if (_noPool(env, f)) return f;
        acc.d.add("steps: fees-only = liquidityDelta 0; half / rest = LP A withdraws in two steps; last-LP = LP B withdraws everything");
        f.details = acc.d.done();
        string memory counts = _counts(acc.dRan, acc.dOk, acc.dFail, acc.dBoth, acc.dInfra, acc.dScen, acc.dSkip, acc.dSkipNames);
        if (acc.dFail > 0) {
            f.status = Status.FAIL;
            f.summary = string.concat(
                "withdrawal steps reverted on the hooked pool because of the hook (a revert out of a hook callback, or one the hook-less control pool does not have): ", counts
            );
        } else if (acc.dRan == 0) {
            f.status = Status.UNKNOWN;
            f.summary = string.concat("no withdrawal step could be run: ", counts);
        } else if (acc.dInfra > 0) {
            f.status = Status.UNKNOWN;
            f.summary = string.concat("PROBE FAILURE, the checker's own tooling failed in some steps; nothing concluded: ", counts);
        } else if (acc.dBoth > 0) {
            f.status = Status.UNKNOWN;
            f.summary = string.concat(
                "withdrawals REVERT here, on the hooked pool and on the hook-less control pool alike. Not attributed to the hook, but not cleared: the hook may be the cause of both (for example through a token it controls). Needs a human: ",
                counts
            );
        } else if (acc.dSkip > 0) {
            // Not a PASS: which scenarios can be set up is in the hands of the hook under test (it can
            // refuse the swap that moves the price), so "every step that RAN succeeded" says nothing
            // about the scenarios that did not run (audit N-1).
            f.status = Status.UNKNOWN;
            f.summary = string.concat(
                "every withdrawal step that was run succeeded on the hooked pool, but ", vm.toString(acc.dSkip),
                " scenario(s) could NOT BE TESTED and are not covered by this result; whether withdrawals work there is not known (the hook itself may be what keeps them from being set up). Needs a human: ",
                counts
            );
        } else {
            // every scenario was set up and every step succeeded on the hooked pool
            f.status = Status.PASS;
            f.summary = string.concat(
                "every withdrawal step succeeded on the hooked pool in every scenario (fee collection, partial, full, last LP): ", counts
            );
        }
    }

    function _findSwap(Env memory env, Acc memory acc) private pure returns (Finding memory f) {
        f = _blank(E_SWAP);
        if (_noPool(env, f)) return f;
        if (acc.repeats > 0) {
            acc.e.add(string.concat("(", vm.toString(acc.repeats), " further reverts in checks d/e had a reason already listed once; the per-scenario lines show where)"));
        }
        f.details = acc.e.done();
        string memory counts =
            _counts(acc.eRan, acc.eOk, acc.eUnexpected + acc.eRefusal, acc.eBoth, acc.eInfra, acc.eScen, acc.eSkip, acc.eSkipNames);
        if (acc.eUnexpected > 0) {
            f.status = Status.FAIL;
            f.summary = string.concat(
                vm.toString(acc.eUnexpected),
                " swap(s) reverted unexpectedly on the hooked pool (panic / empty revert / gas / rejected answer / unsettled delta) while the control pool did not: ", counts
            );
        } else if (acc.eRan == 0) {
            f.status = Status.UNKNOWN;
            f.summary = string.concat("no swap could be run: ", counts);
        } else if (acc.eInfra > 0) {
            f.status = Status.UNKNOWN;
            f.summary = string.concat("PROBE FAILURE, the checker's own tooling failed in some swaps; nothing concluded: ", counts);
        } else if (acc.eRefusal > 0) {
            f.status = Status.UNKNOWN;
            f.summary = string.concat(
                vm.toString(acc.eRefusal), " swap(s) were refused by the hook with an explicit error",
                acc.eBaselineRefusal > 0 ? " (already in the baseline: the hook may need a specific router or hookData)" : " (only under perturbation)",
                ": by design or stuck? needs a human: ", counts
            );
        } else if (acc.eBoth > 0) {
            f.status = Status.UNKNOWN;
            f.summary = string.concat(
                "swaps REVERT here, on the hooked pool and on the hook-less control pool alike. Not attributed to the hook, but not cleared: the hook may be the cause of both. Needs a human: ", counts
            );
        } else {
            f.status = Status.PASS;
            f.summary = string.concat(
                "every swap that was run succeeded on the hooked pool: ", counts,
                acc.eSkip > 0 ? ". The scenarios listed as NOT TESTED are not covered by this result" : ""
            );
        }
    }

    function _findFee(Env memory env, Acc memory acc) private pure returns (Finding memory f) {
        f = _blank(F_DYNAMIC_FEE);
        if (env.poolReady && !env.dynamicFee) {
            f.status = Status.NA;
            f.summary = "the test pool has a static fee (the hook rejected a dynamic-fee pool, or the given PoolKey is static)";
            return f;
        }
        if (_noPool(env, f)) return f;
        Lines memory L = acc.f;
        L.add("per-scenario fees are on the lines of check e (fee= is the Swap event's total fee in pips: LP fee combined with any protocol fee)");
        if (acc.feeSeen > 0) {
            L.add(string.concat("fees observed: min ", vm.toString(acc.feeMin), ", max ", vm.toString(acc.feeMax), " pips over ", vm.toString(acc.feeSeen), " swaps"));
        }
        if (acc.feeFull) L.add("a fee of 100% was observed: exactOut swaps revert at that fee (InvalidFeeForExactOut)");
        f.details = L.done();
        if (acc.feeTooLarge) {
            f.status = Status.FAIL;
            f.summary = "the hook returned an LP fee above 100% (PoolManager reverted the swap with LPFeeTooLarge)";
        } else if (acc.feeSeen == 0) {
            f.status = Status.UNKNOWN;
            f.summary = "no swap succeeded, no fee observed";
        } else if (acc.feeMax == 0) {
            f.status = Status.UNKNOWN;
            f.summary = string.concat(
                "every one of the ", vm.toString(acc.feeSeen),
                " swaps in this DYNAMIC-fee pool paid a fee of 0. Either the hook is not a fee hook (then this pool type is the wrong test bed for it: give a PoolKey), or it means to set a fee and does not: is OVERRIDE_FEE_FLAG missing on the fee beforeSwap returns, or updateDynamicLPFee never called? Needs a human"
            );
        } else if (acc.sameBlockDiff) {
            f.status = Status.UNKNOWN;
            f.summary = "the fee of an identical swap changes within one block: it depends on something a single transaction can move. Hint, not a verdict: needs a human";
        } else if (!acc.sameBlockRan) {
            f.status = Status.UNKNOWN;
            f.summary = "fees within [0, 100%], but the same-block test could not run";
        } else {
            f.status = Status.PASS;
            f.summary = string.concat(
                "fees within [0, 100%] (", vm.toString(acc.feeMin), "..", vm.toString(acc.feeMax),
                " pips) in the swaps that were run; identical swaps in one block pay the same fee, in both directions, also after a large opposite swap"
            );
        }
    }

    // =============================================================================================
    // g. upgradeability / admin
    // =============================================================================================

    function _checkUpgrade(Env memory env) private view returns (Finding memory f) {
        f = _blank(G_UPGRADE);
        Lines memory L = LinesLib.make();
        uint256 signs;
        bytes32[3] memory slots = [
            bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1),
            bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1),
            bytes32(uint256(keccak256("eip1967.proxy.beacon")) - 1)
        ];
        string[3] memory slotNames = ["implementation", "admin", "beacon"];
        for (uint256 i; i < 3; i++) {
            bytes32 v = vm.load(_hook, slots[i]);
            if (v != 0) {
                signs++;
                L.add(string.concat("EIP-1967 ", slotNames[i], " slot is set: ", vm.toString(v)));
            }
        }
        address impl = BytecodeScan.minimalProxyTarget(env.code);
        if (impl != address(0)) {
            signs++;
            L.add(string.concat("EIP-1167 minimal proxy to ", vm.toString(impl), " (not upgradeable by itself; the logic lives elsewhere)"));
        }
        string[10] memory views = [
            "owner()", "admin()", "getAdmin()", "governance()", "governor()", "guardian()", "pendingOwner()", "implementation()",
            "proxiableUUID()", "paused()"
        ];
        for (uint256 i; i < 10; i++) {
            (bool ok, bytes32 w) = _viewWord(_hook, abi.encodeWithSignature(views[i]));
            if (!ok) continue;
            if (i == 9) {
                signs++;
                L.add(string.concat("paused() answers (", uint256(w) != 0 ? "true" : "false", "): there is a pause switch"));
            } else if (w != 0) {
                signs++;
                L.add(string.concat(views[i], " answers ", vm.toString(w)));
            }
        }
        // Decided on the FULL sweep. A byte value that occurs only inside what is shaped like a Solidity
        // metadata trailer is most likely data, but that shape can be forged to hold reachable code, so
        // it still counts as a sign; the line says where it was seen.
        string memory tail = " - seen ONLY inside the last bytes that are shaped like a Solidity metadata trailer: most likely a data byte, but a trailer can hold code, so it is listed";
        if (env.ops.delegatecall) {
            signs++;
            L.add(string.concat("DELEGATECALL opcode occurs in the bytecode (linear sweep; may be unreachable or a data byte)", env.opsCode.delegatecall ? "" : tail));
        }
        if (env.ops.callcode) {
            signs++;
            L.add(string.concat("CALLCODE opcode occurs in the bytecode (linear sweep)", env.opsCode.callcode ? "" : tail));
        }
        if (env.ops.selfdestruct) {
            signs++;
            L.add(
                string.concat(
                    "SELFDESTRUCT opcode occurs in the bytecode (linear sweep; since Cancun it no longer removes deployed code)",
                    env.opsCode.selfdestruct ? "" : tail
                )
            );
        }
        L.add(
            string.concat(
                "bytecode: ", vm.toString(env.code.length), " bytes, all of them swept (", vm.toString(BytecodeScan.trailerLength(env.code)),
                " at the end are shaped like a metadata trailer and are swept as well)"
            )
        );
        f.details = L.done();
        if (signs == 0) {
            f.status = Status.PASS;
            f.summary = "no EIP-1967 slot set, no owner/admin/implementation/paused view answers, no DELEGATECALL / CALLCODE / SELFDESTRUCT opcode anywhere in the bytecode (full sweep). Hints only: a privileged role behind another name is not seen";
        } else {
            f.status = Status.UNKNOWN;
            f.summary = string.concat(vm.toString(signs), " sign(s) of upgradeability or privileged control. Hints only, see details: needs a human");
        }
    }

    // =============================================================================================
    // h. balances (facts only)
    // =============================================================================================

    /// @dev [erc20/native c0, erc20/native c1, claims c0, claims c1, mask of readable entries]
    function _balances(Env memory env) private view returns (uint256[5] memory b) {
        bool ok;
        (ok, b[0]) = _balanceOf(env.key.currency0, _hook);
        if (ok) b[4] |= 1;
        (ok, b[1]) = _balanceOf(env.key.currency1, _hook);
        if (ok) b[4] |= 2;
        (ok, b[2]) = _claimsOf(env.key.currency0, _hook);
        if (ok) b[4] |= 4;
        (ok, b[3]) = _claimsOf(env.key.currency1, _hook);
        if (ok) b[4] |= 8;
    }

    function _snapshotBalances(Env memory env, bool before) private view {
        if (before) env.balBefore = _balances(env);
    }

    function _checkBalances(Env memory env) private view returns (Finding memory f) {
        f = _blank(H_BALANCES);
        Lines memory L = LinesLib.make();
        uint256 nativeBal = _hook.balance;
        L.add(string.concat("native ETH held by the hook: ", vm.toString(nativeBal)));
        if (!env.poolReady) {
            f.status = nativeBal == 0 ? Status.NA : Status.UNKNOWN;
            f.summary = nativeBal == 0
                ? "no test pool, so no pool currencies to look at; the hook holds no native ETH"
                : "the hook holds native ETH (fact only; whether that is intended needs a human)";
            f.details = L.done();
            return f;
        }
        uint256[5] memory now_ = _balances(env);
        string[4] memory names = ["currency0 balance", "currency1 balance", "currency0 ERC-6909 claims", "currency1 ERC-6909 claims"];
        bool holds = nativeBal != 0;
        bool unreadable;
        for (uint256 i; i < 4; i++) {
            if (now_[4] & (1 << i) == 0 || env.balBefore[4] & (1 << i) == 0) {
                unreadable = true;
                L.add(string.concat(names[i], ": could not be read"));
                continue;
            }
            if (env.balBefore[i] != 0 || now_[i] != 0) holds = true;
            L.add(string.concat(names[i], ": ", vm.toString(env.balBefore[i]), " before the checker's operations, ", vm.toString(now_[i]), " after setup (2 adds, 4 swaps, 1 donate, 2 minutes)"));
        }
        f.details = L.done();
        if (holds) {
            f.status = Status.UNKNOWN;
            f.summary = "the hook holds tokens, ETH or claims (fact only: custody is a design choice; who can move them out is not something this check can tell)";
        } else if (unreadable) {
            f.status = Status.UNKNOWN;
            f.summary = "some balances could not be read";
        } else {
            f.status = Status.PASS;
            f.summary = "the hook holds no pool currency, no native ETH and no ERC-6909 claims, before or after the checker's operations";
        }
    }

    // =============================================================================================
    // i. return deltas (facts and a consistency hint)
    // =============================================================================================

    function _findReturnDelta(Env memory env, Acc memory acc) private pure returns (Finding memory f) {
        f = _blank(I_RETURN_DELTA);
        uint160 rd = env.flags & uint160(0xF);
        if (rd == 0) {
            f.status = Status.NA;
            f.summary = "no return-delta bit in the address: PoolManager ignores any delta the hook returns";
            return f;
        }
        if (_noPool(env, f)) return f;
        Lines memory L = LinesLib.make();
        uint256 measured;
        uint256 withTake;
        uint256 bothSides;
        uint256 minPpm = type(uint256).max;
        uint256 maxPpm;
        for (uint8 c; c < 4; c++) {
            if (!acc.baseOk[c] || !acc.base[c].sawEvent) {
                L.add(string.concat(_comboName(c), ": baseline swap not available"));
                continue;
            }
            measured++;
            SwapOut memory o = acc.base[c];
            int256 h0 = int256(o.p0) - int256(o.c0); // hook's delta: + = hook takes
            int256 h1 = int256(o.p1) - int256(o.c1);
            string memory line = string.concat(_comboName(c), ": pool (", vm.toString(int256(o.p0)), ", ", vm.toString(int256(o.p1)), "), hook takes (", vm.toString(h0), ", ", vm.toString(h1), ")");
            if (h0 != 0 || h1 != 0) {
                withTake++;
                if (h0 != 0 && h1 != 0) bothSides++;
                uint256 ppm = h0 != 0 ? _ppm(h0, o.p0) : _ppm(h1, o.p1);
                if (ppm < minPpm) minPpm = ppm;
                if (ppm > maxPpm) maxPpm = ppm;
                line = string.concat(line, " = ", vm.toString(ppm), " ppm of the pool's amount in that currency");
            }
            L.add(line);
        }
        if (acc.backOk) {
            L.add(
                string.concat(
                    "LP A withdrawing its whole position (baseline) received (", vm.toString(acc.backHook[0]), ", ", vm.toString(acc.backHook[1]),
                    "); on the hook-less control pool (", vm.toString(acc.backCtl[0]), ", ", vm.toString(acc.backCtl[1]), ") - fees differ, compare orders of magnitude"
                )
            );
        }
        f.details = L.done();
        bool lpShort = acc.backOk
            && (acc.backHook[0] * 100 < acc.backCtl[0] * 90 || acc.backHook[1] * 100 < acc.backCtl[1] * 90);
        if (measured == 0) {
            f.status = Status.UNKNOWN;
            f.summary = "return-delta bits are set but no baseline swap succeeded, nothing measured";
        } else if (bothSides > 0) {
            f.status = Status.UNKNOWN;
            f.summary = "the hook changes both sides of a swap (custom curve / takes over matching): its pricing is an economic model this checker does not judge";
        } else if (withTake > 0 && (withTake < measured || maxPpm > minPpm + minPpm / 4 + 2)) {
            f.status = Status.UNKNOWN;
            f.summary = string.concat(
                "what the hook takes is not uniform across direction x exactIn/exactOut (", vm.toString(withTake), " of ", vm.toString(measured),
                " combinations, ", vm.toString(minPpm == type(uint256).max ? 0 : minPpm), "..", vm.toString(maxPpm),
                " ppm): asymmetric by design or a direction/sign mistake? Hint, not a verdict: needs a human"
            );
        } else if (lpShort) {
            f.status = Status.UNKNOWN;
            f.summary = "an LP withdrawing got back over 10% less than on the hook-less control pool: exit fee by design? needs a human";
        } else {
            f.status = Status.PASS;
            f.summary = withTake == 0
                ? "return-delta bits are set, but the hook took nothing in the 4 baseline swaps"
                : string.concat("the hook takes a uniform ", vm.toString(maxPpm), " ppm in all 4 direction x exactIn/exactOut combinations");
        }
    }

    function _ppm(int256 part, int128 whole) private pure returns (uint256) {
        uint256 p = part < 0 ? uint256(-part) : uint256(part);
        uint256 w = whole < 0 ? uint256(uint128(-whole)) : uint256(uint128(whole));
        if (w == 0) return type(uint64).max; // the pool moved nothing in that currency
        return p * 1e6 / w;
    }

    // =============================================================================================
    // Report rendering
    // =============================================================================================

    function statusName(Status s) public pure returns (string memory) {
        if (s == Status.PASS) return "PASS";
        if (s == Status.FAIL) return "FAIL";
        if (s == Status.NA) return "N/A";
        return "UNKNOWN";
    }

    function renderReport(Report memory rep) public pure returns (string memory out) {
        out = "# Hook check report\n\n";
        if (rep.voided) {
            out = string.concat(
                out, "**REPORT VOID - DO NOT USE. The run was compromised and NOTHING below is a result.**\n\n", "Reason: ", rep.voidReason, ".\n\n",
                "Every check is listed as UNKNOWN. Do not read anything into this report; find out what happened and run again.\n\n"
            );
        }
        out = string.concat(
            out, "- hook: `", vm.toString(rep.hook), "` (", vm.toString(rep.codeSize), " bytes of code)\n",
            "- PoolManager: `", vm.toString(rep.manager), "`\n", "- chain id ", vm.toString(rep.chainId), ", block ", vm.toString(rep.blockNumber),
            ", timestamp ", vm.toString(rep.timestamp), "\n", "- permission bits in the address: 0x", _hex4(rep.flags), " = ", _flagNames(rep.flags), "\n\n"
        );
        if (!rep.voided) {
            out = string.concat(
                out,
                "Statuses: PASS / FAIL / N/A / UNKNOWN (cannot be decided by the tool, needs a human).\n",
                "Generic, automated, detection-only checks run in local simulation. A FAIL is a finding to look at, not proof of a vulnerability;\n",
                "a PASS only says that these probes found nothing; passing every check does not make a hook safe. This is not an audit.\n\n"
            );
        }
        out = string.concat(out, "## Summary\n\n| check | status | basis |\n|---|---|---|\n");
        for (uint256 i; i < rep.findings.length; i++) {
            Finding memory f = rep.findings[i];
            out = string.concat(out, "| ", f.id, ". ", f.title, " | ", statusName(f.status), " | ", f.summary, " |\n");
        }
        // a void report ends here: no setup lines, no details (both carry text that came from the hook)
        if (rep.voided) return out;
        out = string.concat(out, "\n## Setup\n\n");
        for (uint256 i; i < rep.setup.length; i++) {
            out = string.concat(out, "- ", rep.setup[i], "\n");
        }
        out = string.concat(out, "\n## Details\n");
        for (uint256 i; i < rep.findings.length; i++) {
            Finding memory f = rep.findings[i];
            out = string.concat(out, "\n### ", f.id, ". ", f.title, ": ", statusName(f.status), "\n\n", f.summary, "\n\n");
            for (uint256 j; j < f.details.length; j++) {
                out = string.concat(out, "- ", f.details[j], "\n");
            }
        }
    }

    function _hex4(uint160 flags) private pure returns (string memory) {
        bytes memory digits = "0123456789abcdef";
        bytes memory out = new bytes(4);
        for (uint256 i; i < 4; i++) {
            out[i] = digits[(flags >> uint160(4 * (3 - i))) & 0xf];
        }
        return string(out);
    }
}
