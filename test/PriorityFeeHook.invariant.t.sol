// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTestNoChecks} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTestNoChecks.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PriorityFeeHook} from "../src/PriorityFeeHook.sol";
import {PriorityFeeTestBase} from "./utils/PriorityFeeTestBase.sol";

/// @notice Random actor for the invariant run: two hooked pools with liquidity on different pairs (which
///         the run can empty), a third hooked pool that never has any liquidity and a fourth whose wide
///         liquidity is never removed; swaps of every kind from 1 wei up, at arbitrary
///         gas price / base fee (below the base fee, inside the allowance, on the linear part, at the cap
///         and far above it), with and without hookData; liquidity added and removed (pools can be
///         emptied), protocol fees changed, strangers creating more pools with the same hook.
///         After every successful swap the fee in PoolManager's Swap event must equal the schedule
///         (restated here, not imported) for the gas price and base fee in force.
/// @dev Audit round 1 (audits/audit-hooks-h2.md):
///      T-1  the min / max fee ghosts are taken from the Swap EVENT (what was really charged), never from
///           this handler's own expectation, and each event is checked against bounds that use only the
///           two hard constants and the protocol fee read from the chain.
///      T-2  a revert whose data is PoolManager's WrappedError pointing at the hook raises the flag; any
///           other revert of a swap is counted and its selector kept.
///      Audit round 2 (appended to the same report): the handler has 15 actions, 5 of them swap actions.
///      Coverage of the swap space no longer hangs on `swapsOk` (swapTwice adds 2 to it and used to step
///      over a round-robin slot). Each swap ACTION takes one "pick" from an independent counter `envPicks`:
///        - picks 0-3 and every even pick after that take the gas environment round-robin from the four
///          classes (below base fee / floor / linear / cap), first cycle: base fee up to 2^64, tip exactly
///          0, first pip, tip above 100 gwei; the other picks take it from the fuzzer;
///        - pick 1 and every 4th after it carry non-empty hookData; pick 2 and every 16th after it set a
///          non-zero protocol fee (both directions) on the pool about to be swapped;
///        - the pool is taken from `swapsOk`, read before every single swap (so swapTwice cannot step over
///          it): every 8th swap goes to the always-liquid pool, every 8th to the never-liquid pool.
///      So 4 swap actions are enough for all four classes, hookData, protocol fee and > 100 gwei, and 8
///      successful swaps (which need at least 4 swap actions) for both special pools. See
///      test_regression_swapTwiceCannotSkipAnEnvironmentClass and the comment on afterInvariant.
contract PriorityFeeHandler is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev 0, 1: with liquidity, can be emptied; 2: never any liquidity; 3: wide liquidity never removed
    uint256 internal constant POOLS = 4;

    IPoolManager public manager;
    PriorityFeeHook public hook;
    PoolSwapTest public router;
    /// @dev the variant without the test router's own sign assertions (they trip on 1-wei positions and on
    ///      adds that collect more fees than they deposit, which has nothing to do with the hook)
    PoolModifyLiquidityTestNoChecks public liqRouter;
    address public feeController;

    PoolKey[4] public keys;
    PoolId[4] public ids;
    uint24[2][4] public protocolFees; // [pool][0: zeroForOne, 1: oneForZero]
    int256[2] public narrowLiquidity; // what this handler holds in [-600, 600) of pools 0 and 1
    int256[2] public wideLiquidity;

    uint256 public gasPrice;
    uint256 public baseFee;

    // ghosts
    string public flag;
    uint256 public swapsOk;
    uint256 public swapsReverted;
    bytes4 public lastRevertSelector;
    uint256 public swapsFloor; // charged exactly the floor
    uint256 public swapsSurcharged; // charged more than the floor
    uint256 public swapsAtCap; // charged exactly the cap
    uint256 public swapsBelowBaseFee;
    uint256 public swapsAboveHundredGwei;
    /// @dev PoolManager.getLiquidity(pool) == 0 just before the swap: the never-liquid pool, an emptied
    ///      pool, or a pool whose price has left every position's range
    uint256 public swapsAtZeroActiveLiquidity;
    uint256 public swapsWithActiveLiquidity;
    uint256 public swapsAtZeroTip; // tx.gasprice == block.basefee exactly
    /// @dev swap ACTIONS so far (swapTwice counts once): drives the round-robin, independent of swapsOk
    uint256 public envPicks;
    uint256 public roundRobinPicks;
    bool internal hookDataThisPick;
    bool internal protocolFeeThisPick;
    uint256 public swapsWithHookData;
    uint256 public swapsWithProtocolFee;
    uint256 public removals;
    uint256 public strangerPools;
    /// @dev total fee (protocol + LP) in PoolManager's Swap events
    uint24 public maxFeeCharged;
    uint24 public minFeeCharged = type(uint24).max;
    /// @dev the same restricted to swaps where the chain reported protocol fee 0: the pure LP fee
    uint24 public maxLpFeeCharged;
    uint24 public minLpFeeCharged = type(uint24).max;
    uint256 public feesOutsideHardBounds;

    constructor(IPoolManager _manager, PriorityFeeHook _hook, address _feeController) {
        manager = _manager;
        hook = _hook;
        feeController = _feeController;
        router = new PoolSwapTest(_manager);
        liqRouter = new PoolModifyLiquidityTestNoChecks(_manager);
        for (uint256 i; i < POOLS; i++) {
            MockERC20 a = new MockERC20("A", "A", 18);
            MockERC20 b = new MockERC20("B", "B", 18);
            (MockERC20 t0, MockERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);
            t0.mint(address(this), 1e40);
            t1.mint(address(this), 1e40);
            t0.approve(address(router), type(uint256).max);
            t1.approve(address(router), type(uint256).max);
            t0.approve(address(liqRouter), type(uint256).max);
            t1.approve(address(liqRouter), type(uint256).max);
            keys[i] = PoolKey(
                Currency.wrap(address(t0)),
                Currency.wrap(address(t1)),
                LPFeeLibrary.DYNAMIC_FEE_FLAG,
                60,
                IHooks(address(_hook))
            );
            ids[i] = keys[i].toId();
            manager.initialize(keys[i], TickMath.getSqrtPriceAtTick(0));
            if (i != 2) {
                liqRouter.modifyLiquidity(keys[i], ModifyLiquidityParams(-120_000, 120_000, 1e22, 0), "");
                if (i < 2) wideLiquidity[i] = 1e22; // pool 3's is not tracked: no action removes it
            }
        }
    }

    /// @dev The v4-core test routers forward any ETH they hold to the caller. Nothing here uses ETH; this
    ///      exists because of a Foundry artifact: once the run has set a non-zero tx.gasprice, the address
    ///      the fuzzer uses as the top-level sender is credited a gas refund in ETH. If that sender happens
    ///      to be one of the routers, its next call forwards the ETH here. The routers are excluded as
    ///      senders in setUp and invariant_hookHoldsNothing checks this stayed 0.
    uint256 public ethReceived;

    receive() external payable {
        ethReceived += msg.value;
    }

    function _flag(string memory what) internal {
        if (bytes(flag).length == 0) flag = what;
    }

    function _expectedFee() internal view returns (uint24) {
        uint256 tip = gasPrice > baseFee ? gasPrice - baseFee : 0;
        if (tip <= 20_000_000) return 500;
        uint256 extra = (tip - 20_000_000) / 400_000;
        return uint24(500 + (extra > 2500 ? 2500 : extra));
    }

    function _total(uint24 pf, uint24 lpFee) internal pure returns (uint24) {
        return uint24(uint256(pf) + lpFee - (uint256(pf) * lpFee) / 1e6);
    }

    function _setEnv(uint256 _gasPrice, uint256 _baseFee) internal {
        gasPrice = _gasPrice;
        baseFee = _baseFee;
        vm.txGasPrice(_gasPrice);
        vm.fee(_baseFee);
    }

    /// @dev class 0: gas price below the base fee; 1: tip at or below the last value charged the floor;
    ///      2: on the linear part; 3: at the cap or above it (up to the largest gas price Foundry accepts);
    ///      anything else: keep what setGasRaw / setTip left.
    ///      `variant` 0, 1, 2 pick the boundary values of the class, anything else a random value in it:
    ///      class 0: 0 = base fee anywhere below 2^64;
    ///      class 1: 0 = tip exactly 0 (gas price == base fee), 1 = exactly the allowance, 2 = 1 wei short
    ///               of the first pip;
    ///      class 2: 0 = first pip, 1 = 1 wei short of the cap;
    ///      class 3: 0 = tip above 100 gwei, 1 = exactly the cap.
    function _setEnvClass(uint256 class, uint256 variant, uint256 seed) internal {
        uint256 a = uint256(keccak256(abi.encode(seed, "a")));
        uint256 b = uint256(keccak256(abi.encode(seed, "b")));
        if (class == 0) {
            uint256 bf = variant == 0 ? bound(b, 1, type(uint64).max) : bound(b, 1, 100_000_000);
            _setEnv(bound(a, 0, bf - 1), bf);
        } else if (class == 1) {
            uint256 bf = bound(b, 0, 100_000_000);
            uint256 tip = variant == 0
                ? 0
                : variant == 1 ? 20_000_000 : variant == 2 ? 20_399_999 : bound(a, 0, 20_399_999);
            _setEnv(bf + tip, bf);
        } else if (class == 2) {
            uint256 bf = bound(b, 0, 100_000_000);
            uint256 tip =
                variant == 0 ? 20_400_000 : variant == 1 ? 1_019_999_999 : bound(a, 20_400_000, 1_019_999_999);
            _setEnv(bf + tip, bf);
        } else if (class == 3) {
            uint256 bf = bound(b, 0, 100_000_000);
            uint256 tip = variant == 0
                ? bound(a, 100 gwei + 1, type(uint64).max - bf)
                : variant == 1 ? 1_020_000_000 : bound(a, 1_020_000_000, 3_000_000_000);
            _setEnv(bf + tip, bf);
        }
    }

    /// @dev 0,1 -> pool 0; 2,3 -> pool 1; 4 -> the pool without liquidity. Out of every 8 successful swaps
    ///      one is sent to the pool whose liquidity is never removed and one to the pool without liquidity,
    ///      so a run cannot miss either by chance. Read before every single swap, so swapTwice (which adds
    ///      2 to swapsOk) cannot step over a slot.
    function _pool(uint256 poolSeed) internal view returns (uint256) {
        if (swapsOk % 8 == 3) return 3;
        if (swapsOk % 8 == 7) return 2;
        return (poolSeed % 5) / 2;
    }

    // ---- actions: environment ----

    /// @dev arbitrary environment, including gas price below base fee
    function setGasRaw(uint64 _gasPrice, uint64 _baseFee) external {
        _setEnv(_gasPrice, _baseFee);
    }

    /// @dev realistic environment: base fee near Base's, tip inside the range where the schedule moves
    function setTip(uint256 _baseFee, uint256 tip) external {
        uint256 bf = bound(_baseFee, 0, 100_000_000);
        _setEnv(bf + bound(tip, 0, 1_300_000_000), bf);
    }

    // ---- actions: swaps ----

    function swap(uint256 poolSeed, bool zeroForOne, bool exactIn, uint256 amount, uint256 envSeed) external {
        _pickEnv(envSeed);
        amount = bound(amount, 1, 1e22);
        _doSwap(_pool(poolSeed), zeroForOne, exactIn ? -int256(amount) : int256(amount), _rotatingHookData(envSeed));
    }

    function dustSwap(uint256 poolSeed, bool zeroForOne, bool exactIn, uint256 amount, uint256 envSeed) external {
        _pickEnv(envSeed);
        amount = bound(amount, 1, 1000);
        _doSwap(_pool(poolSeed), zeroForOne, exactIn ? -int256(amount) : int256(amount), _rotatingHookData(envSeed));
    }

    function moderateSwap(uint256 poolSeed, bool zeroForOne, bool exactIn, uint256 amount, uint256 envSeed) external {
        _pickEnv(envSeed);
        amount = bound(amount, 1e12, 1e19);
        _doSwap(_pool(poolSeed), zeroForOne, exactIn ? -int256(amount) : int256(amount), _rotatingHookData(envSeed));
    }

    /// @dev two swaps in one call (one "transaction"): both are charged at the same environment
    function swapTwice(uint256 poolSeed, bool zeroForOne, bool exactIn, uint256 amount, uint256 envSeed) external {
        _pickEnv(envSeed);
        amount = bound(amount, 1, 1e20);
        bytes memory data = _rotatingHookData(envSeed);
        _doSwap(_pool(poolSeed), zeroForOne, exactIn ? -int256(amount) : int256(amount), data);
        _doSwap(_pool(poolSeed >> 8), !zeroForOne, exactIn ? -int256(amount) : int256(amount), data);
    }

    /// @dev hookData of length 32 (looks like an ABI word), 1..96, or 0: must make no difference
    function swapWithHookData(uint256 poolSeed, bool zeroForOne, uint256 amount, uint256 envSeed, bytes32 word)
        external
    {
        _pickEnv(envSeed);
        amount = bound(amount, 1, 1e20);
        bytes memory data;
        if (envSeed % 3 == 0) data = abi.encode(word);
        else if (envSeed % 3 == 1) data = abi.encodePacked(word, word, word);
        else data = abi.encodePacked(bytes4(word));
        _doSwap(_pool(poolSeed), zeroForOne, -int256(amount), data);
    }

    /// @dev One call per swap ACTION. Picks 0-3 and every even pick after them take the class round-robin
    ///      (class = n % 4, variant = (n / 4) % 4 for the n-th round-robin pick, so the first cycle is the
    ///      boundary variant 0 of each class); the others take class and variant from the fuzzer, including
    ///      "keep the current environment". Counted by `envPicks`, NOT by swapsOk: swapTwice adds 2 to
    ///      swapsOk and used to step over a round-robin slot (audit round 2).
    function _pickEnv(uint256 envSeed) internal {
        uint256 pick = envPicks++;
        if (pick < 4 || pick % 2 == 0) {
            uint256 n = roundRobinPicks++;
            _setEnvClass(n % 4, (n / 4) % 4, envSeed);
        } else {
            _setEnvClass(envSeed % 6, (envSeed >> 8) % 8, envSeed);
        }
        hookDataThisPick = pick % 4 == 1;
        protocolFeeThisPick = pick % 16 == 2;
    }

    /// @dev non-empty on pick 1 and every 4th pick after it (32 bytes, or 4 bytes), else empty
    function _rotatingHookData(uint256 seed) internal view returns (bytes memory) {
        if (!hookDataThisPick) return "";
        return seed % 2 == 0 ? abi.encode(seed) : abi.encodePacked(bytes4(uint32(seed >> 8)));
    }

    /// @dev checks before a swap; returns the direction really used and the protocol fee of that direction
    ///      as the CHAIN reports it (not this handler's bookkeeping)
    function _before(uint256 i, bool zeroForOne) internal returns (bool dir, uint24 chainPf) {
        (uint160 price,, uint24 chainProtocolFee, uint24 storedFee) = manager.getSlot0(ids[i]);
        if (storedFee != 500) _flag("stored LP fee changed");
        // already at the price limit in this direction (emptied pool): go the other way
        dir = price == (zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1) ? !zeroForOne : zeroForOne;
        if (hook.currentFee() != _expectedFee()) _flag("currentFee() != schedule");
        chainPf = dir ? chainProtocolFee & 0xfff : chainProtocolFee >> 12;
        if (chainPf != protocolFees[i][dir ? 0 : 1]) _flag("protocol fee bookkeeping");
    }

    function _registeredSlot(uint256 pool) internal view returns (bytes32) {
        return vm.load(address(hook), keccak256(abi.encode(ids[pool], uint256(0))));
    }

    function _doSwap(uint256 i, bool zeroForOne, int256 amountSpecified, bytes memory hookData) internal {
        if (protocolFeeThisPick) {
            // pick 2 and every 16th after it: a non-zero protocol fee in both directions on this pool
            protocolFeeThisPick = false;
            uint256 r = uint256(keccak256(abi.encode(envPicks, i)));
            _setProtocolFee(i, uint24(1 + r % 1000), uint24(1 + (r >> 16) % 1000));
        }
        uint24 chainPf;
        (zeroForOne, chainPf) = _before(i, zeroForOne);
        bool empty = manager.getLiquidity(ids[i]) == 0;
        bytes32 otherRegistered = _registeredSlot((i + 1) % POOLS);

        vm.recordLogs();
        try router.swap(
            keys[i],
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        ) {
            swapsOk++;
            if (empty) swapsAtZeroActiveLiquidity++;
            else swapsWithActiveLiquidity++;
            if (gasPrice == baseFee) swapsAtZeroTip++;
            if (gasPrice < baseFee) swapsBelowBaseFee++;
            if (gasPrice > 100 gwei) swapsAboveHundredGwei++;
            if (hookData.length > 0) swapsWithHookData++;
            if (chainPf > 0) swapsWithProtocolFee++;
            _checkLogs(_total(protocolFees[i][zeroForOne ? 0 : 1], _expectedFee()), chainPf);
        } catch (bytes memory err) {
            _onRevert(err);
        }
        if (_registeredSlot((i + 1) % POOLS) != otherRegistered) _flag("a swap changed another pool's hook state");
    }

    /// @dev PoolManager wraps a hook's revert as WrappedError(target, selector, reason, details). The hook
    ///      has no reachable revert path, so a revert that names the hook as the target is a failure.
    function _onRevert(bytes memory err) internal {
        swapsReverted++;
        vm.getRecordedLogs();
        bytes4 selector;
        address target;
        if (err.length >= 36) {
            assembly {
                selector := mload(add(err, 32))
                target := mload(add(err, 36))
            }
        }
        lastRevertSelector = selector;
        if (selector == CustomRevert.WrappedError.selector && target == address(hook)) {
            _flag("a swap reverted inside the hook");
        }
    }

    /// @param expectedFee what the schedule says (handler's expectation; used for the flag only)
    /// @param chainPf     protocol fee of this direction read from PoolManager before the swap
    function _checkLogs(uint24 expectedFee, uint24 chainPf) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 swaps;
        for (uint256 j; j < logs.length; j++) {
            if (logs[j].emitter == address(hook)) _flag("hook emitted an event during a swap");
            if (logs[j].emitter == address(manager) && logs[j].topics[0] == IPoolManager.Swap.selector) {
                swaps++;
                (,,,,, uint24 fee) = abi.decode(logs[j].data, (int128, int128, uint160, uint128, int24, uint24));
                if (fee != expectedFee) _flag("fee charged != schedule");
                // ---- ghosts from what was CHARGED (T-1) ----
                if (fee > maxFeeCharged) maxFeeCharged = fee;
                if (fee < minFeeCharged) minFeeCharged = fee;
                if (chainPf == 0) {
                    if (fee > maxLpFeeCharged) maxLpFeeCharged = fee;
                    if (fee < minLpFeeCharged) minLpFeeCharged = fee;
                }
                // hard bounds from the two constants and the chain's protocol fee only
                uint24 lowest = _total(chainPf, 500);
                uint24 highest = _total(chainPf, 3000);
                if (fee < lowest || fee > highest) feesOutsideHardBounds++;
                if (fee == lowest) swapsFloor++;
                if (fee > lowest) swapsSurcharged++;
                if (fee == highest) swapsAtCap++;
            }
        }
        if (swaps != 1) _flag("expected exactly one Swap event");
    }

    // ---- actions: liquidity (never in a try/catch) ----

    function addNarrow(uint256 poolSeed, uint256 liquidity) external {
        uint256 i = poolSeed % 2;
        int256 l = int256(bound(liquidity, 1, 1e24));
        liqRouter.modifyLiquidity(keys[i], ModifyLiquidityParams(-600, 600, l, bytes32(uint256(1))), "");
        narrowLiquidity[i] += l;
    }

    /// @dev NOT in a try/catch: with fail_on_revert, a removal that reverted for any gas price would fail
    ///      the run. The hook has no liquidity callbacks, so it cannot be the reason.
    ///      If the handler holds nothing there, it first adds (at the same gas price) and then removes.
    function removeNarrow(uint256 poolSeed, uint256 fraction) external {
        uint256 i = poolSeed % 2;
        if (narrowLiquidity[i] == 0) {
            int256 add = int256(bound(fraction, 1, 1e24));
            liqRouter.modifyLiquidity(keys[i], ModifyLiquidityParams(-600, 600, add, bytes32(uint256(1))), "");
            narrowLiquidity[i] = add;
        }
        int256 l = int256(bound(fraction, 1, uint256(narrowLiquidity[i])));
        liqRouter.modifyLiquidity(keys[i], ModifyLiquidityParams(-600, 600, -l, bytes32(uint256(1))), "");
        narrowLiquidity[i] -= l;
        removals++;
    }

    function removeWide(uint256 poolSeed) external {
        uint256 i = poolSeed % 2;
        if (wideLiquidity[i] == 0) return;
        liqRouter.modifyLiquidity(keys[i], ModifyLiquidityParams(-120_000, 120_000, -wideLiquidity[i], 0), "");
        wideLiquidity[i] = 0;
        removals++;
    }

    function addWide(uint256 poolSeed) external {
        uint256 i = poolSeed % 2;
        if (wideLiquidity[i] != 0) return;
        (, int24 tick,,) = manager.getSlot0(ids[i]);
        if (tick < -119_000 || tick > 119_000) return;
        liqRouter.modifyLiquidity(keys[i], ModifyLiquidityParams(-120_000, 120_000, 1e22, 0), "");
        wideLiquidity[i] = 1e22;
    }

    function setProtocolFee(uint256 poolSeed, uint24 zeroForOne, uint24 oneForZero) external {
        uint256 i = poolSeed % POOLS;
        zeroForOne = uint24(bound(zeroForOne, 0, 1000));
        oneForZero = uint24(bound(oneForZero, 0, 1000));
        _setProtocolFee(i, zeroForOne, oneForZero);
    }

    function _setProtocolFee(uint256 i, uint24 zeroForOne, uint24 oneForZero) internal {
        vm.prank(feeController);
        manager.setProtocolFee(keys[i], (oneForZero << 12) | zeroForOne);
        protocolFees[i] = [zeroForOne, oneForZero];
    }

    // ---- actions: strangers create further pools with the hook ----

    function strangerCreatesPool(uint256 seed, int24 spacing, int24 tick) external {
        address c0 = address(uint160(uint256(keccak256(abi.encode(seed, "c0")))));
        address c1 = address(uint160(uint256(keccak256(abi.encode(seed, "c1")))));
        _strangerPool(seed, c0, c1, spacing, int24(bound(tick, -100_000, 100_000)));
    }

    /// @dev currency0 = native ETH
    function strangerCreatesNativeEthPool(uint256 seed, int24 spacing, int24 tick) external {
        address c1 = address(uint160(uint256(keccak256(abi.encode(seed, "c1")))));
        _strangerPool(seed, address(0), c1, spacing, int24(bound(tick, -100_000, 100_000)));
    }

    /// @dev at the lowest / highest price PoolManager accepts
    function strangerCreatesPoolAtExtremePrice(uint256 seed, int24 spacing, bool top) external {
        address c0 = address(uint160(uint256(keccak256(abi.encode(seed, "x0")))));
        address c1 = address(uint160(uint256(keccak256(abi.encode(seed, "x1")))));
        _strangerPool(seed, c0, c1, spacing, top ? TickMath.MAX_TICK - 1 : TickMath.MIN_TICK);
    }

    function _strangerPool(uint256 seed, address c0, address c1, int24 spacing, int24 tick) internal {
        spacing = int24(bound(spacing, 1, 200));
        if (c0 == c1) return;
        if (c0 > c1) (c0, c1) = (c1, c0);
        PoolKey memory k =
            PoolKey(Currency.wrap(c0), Currency.wrap(c1), LPFeeLibrary.DYNAMIC_FEE_FLAG, spacing, IHooks(address(hook)));
        if (hook.isRegistered(k.toId())) return;
        vm.prank(address(uint160(uint256(keccak256(abi.encode(seed, "who"))))));
        manager.initialize(k, TickMath.getSqrtPriceAtTick(tick));
        if (!hook.isRegistered(k.toId())) _flag("stranger's pool not registered");
        (,,, uint24 stored) = manager.getSlot0(k.toId());
        if (stored != 500) _flag("stranger's pool: stored LP fee != floor");
        strangerPools++;
    }

    function tokenBalanceOfHook() external view returns (uint256 total) {
        for (uint256 i; i < POOLS; i++) {
            total += keys[i].currency0.balanceOf(address(hook));
            total += keys[i].currency1.balanceOf(address(hook));
            total += manager.balanceOf(address(hook), keys[i].currency0.toId());
            total += manager.balanceOf(address(hook), keys[i].currency1.toId());
        }
    }
}

contract PriorityFeeHookInvariantTest is PriorityFeeTestBase {
    using StateLibrary for IPoolManager;

    PriorityFeeHandler internal handler;

    function setUp() public {
        _baseSetUp();
        handler = new PriorityFeeHandler(manager, hook, feeController);
        targetContract(address(handler));
        excludeSender(address(handler));
        excludeSender(address(handler.router()));
        excludeSender(address(handler.liqRouter()));
        excludeSender(address(hook));
        excludeSender(address(manager));
    }

    /// @dev the fee PoolManager charged equalled the schedule on every successful swap; no swap reverted
    ///      inside the hook; pools did not interfere; the hook emitted nothing and its stored fee never moved
    function invariant_feeAlwaysMatchesSchedule() public view {
        assertEq(handler.flag(), "");
    }

    /// @dev Hard bounds on what was really CHARGED, read from PoolManager's Swap events (not from the
    ///      handler's expectation): total fee within [500, 3997]; with protocol fee 0 the LP fee within
    ///      [500, 3000]; and for every swap, within [total(pf, 500), total(pf, 3000)] for the protocol fee
    ///      the chain reported for that direction.
    function invariant_feeWithinHardBounds() public view {
        assertEq(handler.feesOutsideHardBounds(), 0, "a charged fee outside the hard bounds");
        if (handler.swapsOk() == 0) return;
        assertGe(handler.minFeeCharged(), 500);
        assertLe(handler.maxFeeCharged(), 3997);
        if (handler.maxLpFeeCharged() == 0) return; // no swap yet with protocol fee 0
        assertGe(handler.minLpFeeCharged(), 500);
        assertLe(handler.maxLpFeeCharged(), 3000);
    }

    function invariant_poolsStayRegistered_storedFeeStaysAtFloor() public view {
        for (uint256 i; i < 4; i++) {
            (,,,, IHooks h) = handler.keys(i);
            assertEq(address(h), address(hook));
            assertTrue(hook.isRegistered(handler.ids(i)));
            (,,, uint24 lpFee) = manager.getSlot0(handler.ids(i));
            assertEq(lpFee, 500);
        }
        assertTrue(hook.isRegistered(hookId));
    }

    function invariant_hookHoldsNothing() public view {
        assertEq(handler.tokenBalanceOfHook(), 0);
        assertEq(address(hook).balance, 0);
        assertEq(handler.ethReceived(), 0);
    }

    /// @dev prints how much of the interesting space the run reached (forge test -vv)
    function invariant_callSummary() public view {
        console2.log("swaps ok / reverted           ", handler.swapsOk(), handler.swapsReverted());
        console2.log("  floor / surcharged / at cap ", handler.swapsFloor(), handler.swapsSurcharged(), handler.swapsAtCap());
        console2.log("  gas price < base fee        ", handler.swapsBelowBaseFee());
        console2.log("  gas price > 100 gwei        ", handler.swapsAboveHundredGwei());
        console2.log("  with hookData / protocol fee", handler.swapsWithHookData(), handler.swapsWithProtocolFee());
        console2.log("  active liquidity > 0 / == 0 ", handler.swapsWithActiveLiquidity(), handler.swapsAtZeroActiveLiquidity());
        console2.log("  tip exactly 0               ", handler.swapsAtZeroTip());
        console2.log("swap actions (picks)          ", handler.envPicks());
        console2.log("liquidity removals            ", handler.removals());
        console2.log("pools created by strangers    ", handler.strangerPools());
        console2.log("total fee charged, min / max  ", handler.minFeeCharged(), handler.maxFeeCharged());
    }

    /// @dev Runs after every one of the 64 runs: the run must have exercised what the invariants are about
    ///      (T-2: the counters used to be printed only).
    ///      What is GUARANTEED and what is only likely:
    ///      - Given at least 8 successful swaps (hence at least 4 swap actions, a swap action being 1 or 2
    ///        swaps) and no reverted swap, every swap counter below is non-zero by construction of the
    ///        handler (see its header); test_regression_swapTwiceCannotSkipAnEnvironmentClass replays the
    ///        auditor's sequence that broke the previous round-robin.
    ///      - "at least 8 successful swaps", "a removal" and "a stranger's pool" are probabilistic. If the
    ///        fuzzer picks uniformly among the 15 handler functions (an ASSUMPTION about Foundry's
    ///        selection, not checked against its source; the per-selector call counts forge prints are
    ///        consistent with it), over 128 calls: fewer than 8 swaps needs fewer than 8 swap actions
    ///        (~2e-14); no call of removeNarrow or removeWide: (13/15)^128 ~ 1.1e-8; no call of the three
    ///        stranger actions: (12/15)^128 ~ 4e-13. So about 1e-8 per run, 7e-7 per 64-run suite.
    ///        Calculated, not measured.
    function afterInvariant() public view {
        assertEq(handler.flag(), "");
        assertGt(handler.removals(), 0, "no liquidity removal");
        assertGt(handler.strangerPools(), 0, "no pool created by a stranger");
        _assertSwapCoverage();
    }

    function _assertSwapCoverage() internal view {
        assertEq(handler.swapsReverted(), 0, "no swap is expected to revert at all");
        assertGe(handler.swapsOk(), 8, "too few successful swaps");
        assertGe(handler.envPicks(), 4, "too few swap actions");
        assertGt(handler.swapsFloor(), 0, "no swap at the floor");
        assertGt(handler.swapsAtZeroTip(), 0, "no swap with a tip of exactly 0");
        assertGt(handler.swapsSurcharged(), 0, "no surcharged swap");
        assertGt(handler.swapsAtCap(), 0, "no swap at the cap");
        assertGt(handler.swapsBelowBaseFee(), 0, "no swap with gas price below base fee");
        assertGt(handler.swapsAboveHundredGwei(), 0, "no swap with gas price above 100 gwei");
        assertGt(handler.swapsWithHookData(), 0, "no swap with hookData");
        assertGt(handler.swapsWithProtocolFee(), 0, "no swap with a protocol fee");
        assertGt(handler.swapsWithActiveLiquidity(), 0, "no swap against liquidity");
        assertGt(handler.swapsAtZeroActiveLiquidity(), 0, "no swap at zero active liquidity");
    }

    /// @dev Audit round 2 PoC. With the previous handler the round-robin slot was read from swapsOk
    ///      ((swapsOk / 2) % 4 when swapsOk was even); swapTwice at an odd swapsOk added 2 and stepped over
    ///      an even value, so this sequence (every envSeed = 4, "keep the environment" on the fuzzer's
    ///      picks) ended with swapsOk == 8 and swapsAtCap == 0, which afterInvariant would have failed on.
    ///      With the independent pick counter the same sequence covers everything afterInvariant asks of
    ///      swaps.
    function test_regression_swapTwiceCannotSkipAnEnvironmentClass() public {
        handler.moderateSwap(0, true, true, 1e18, 4);
        handler.swapTwice(0, true, true, 1e18, 4);
        handler.moderateSwap(0, true, true, 1e18, 4);
        handler.moderateSwap(0, true, true, 1e18, 4);
        handler.swapTwice(0, true, true, 1e18, 4);
        handler.moderateSwap(0, true, true, 1e18, 4);
        assertEq(handler.swapsOk(), 8);
        assertEq(handler.envPicks(), 6);
        assertGt(handler.swapsAtCap(), 0, "the class the old round-robin skipped");
        _assertSwapCoverage();
        assertEq(handler.flag(), "");
    }

    /// @dev the shortest case: 4 swapTwice actions (8 swaps, 4 picks), with seeds that would never pick a
    ///      class themselves
    function test_regression_fourSwapActionsCoverEverything() public {
        for (uint256 i; i < 4; i++) {
            handler.swapTwice(0, i % 2 == 0, true, 1e18, 4);
        }
        assertEq(handler.swapsOk(), 8);
        assertEq(handler.envPicks(), 4);
        _assertSwapCoverage();
        assertEq(handler.flag(), "");
    }
}
