// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {VolatilityFeeHook} from "../../src/VolatilityFeeHook.sol";
import {PriorityFeeHook} from "../../src/PriorityFeeHook.sol";
import {CheckerRouter} from "../src/CheckerRouter.sol";
import {CheckerTestBase} from "./CheckerTestBase.sol";
import {Status, Report, CheckConfig} from "../src/CheckerTypes.sol";

/// @notice The checker against this repo's two hooks: no check may report anything (false-positive
///         control), in own-pool mode, with native ETH, and against a pool somebody else created.
///         Also pins that the `checker` profile compiles both hooks to the very same init code as the
///         default profile (the hashes and salts recorded in hooks/README.md).
contract OwnHooksTest is CheckerTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant FLAGS = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
    address internal constant CREATE2_PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    VolatilityFeeHook internal vol;
    PriorityFeeHook internal prio;

    function setUp() public {
        _baseSetUp();
        vol = new VolatilityFeeHook{salt: _salt(FLAGS, type(VolatilityFeeHook).creationCode, abi.encode(manager))}(manager);
        prio = new PriorityFeeHook{salt: _salt(FLAGS, type(PriorityFeeHook).creationCode, abi.encode(manager))}(manager);
    }

    function _assertAllPass(Report memory rep) internal pure {
        for (uint256 i; i < 8; i++) {
            _assertStatus(rep, i, Status.PASS);
        }
        _assertStatus(rep, I_RETURN_DELTA, Status.NA); // neither hook has a return-delta bit
    }

    function test_volatilityFeeHook_nothingReported() public {
        Report memory rep = _check(address(vol));
        _assertAllPass(rep);
        assertTrue(_mentions(rep, C_FOREIGN_POOL, "ACCEPTED"), "serves any dynamic-fee pool, state per PoolId");
        // the fee reacts across time buckets (floor 0.05% ... cap 1% after the price was pushed out of
        // range and 15 seconds passed) and not within a block
        assertTrue(_mentions(rep, F_DYNAMIC_FEE, "500..10000 pips"), "floor and cap both observed");
        assertTrue(_mentions(rep, E_SWAP, "then +15 seconds: | 0->1 exactIn ok fee=10000"), "cap one bucket after a large move");
        assertTrue(_mentions(rep, F_DYNAMIC_FEE, "pay fee 500 -> 500 -> (after a large 1->0 swap at fee 500) -> 500"), "same block: unchanged");
    }

    function test_priorityFeeHook_nothingReported() public {
        Report memory rep = _check(address(prio));
        _assertAllPass(rep);
        // the fee follows the transaction's priority fee: seen across scenarios, not within one block
        assertTrue(_mentions(rep, F_DYNAMIC_FEE, "500..3000 pips"), "floor and cap both observed");
        assertTrue(_mentions(rep, E_SWAP, "gas price 5000 gwei, base fee 1 gwei: | 0->1 exactIn ok fee=3000"), "cap at a high tip");
        assertTrue(_mentions(rep, E_SWAP, "base fee 100 gwei above gas price 1 gwei: | 0->1 exactIn ok fee=500"), "saturating subtraction");
    }

    function test_ownHooks_nativeEthPool_nothingReported() public {
        CheckConfig memory cfg;
        cfg.manager = manager;
        cfg.nativeCurrency0 = true;
        cfg.hook = address(vol);
        _assertAllPass(runChecks(cfg));
        cfg.hook = address(prio);
        _assertAllPass(runChecks(cfg));
    }

    /// @dev a pool that already exists, created and funded by somebody else, given to the checker by key
    function test_ownHooks_givenExistingPool_nothingReported() public {
        MockERC20 a = new MockERC20("A", "A", 6); // 6 and 18 decimals: the checker has to size by decimals
        MockERC20 b = new MockERC20("B", "B", 18);
        (MockERC20 t0, MockERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);
        CheckerRouter other = new CheckerRouter(manager);
        t0.mint(address(other), 1e30);
        t1.mint(address(other), 1e30);
        for (uint256 i; i < 2; i++) {
            address hook = i == 0 ? address(vol) : address(prio);
            PoolKey memory key =
                PoolKey(Currency.wrap(address(t0)), Currency.wrap(address(t1)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, IHooks(hook));
            other.initialize(key, TickMath.getSqrtPriceAtTick(-1234));
            other.modifyLiquidity(key, ModifyLiquidityParams(-20_000, 20_000, 1e18, 0), "");
            CheckConfig memory cfg;
            cfg.manager = manager;
            cfg.hook = hook;
            cfg.hasKey = true;
            cfg.key = key;
            Report memory rep = runChecks(cfg);
            _assertAllPass(rep);
            assertEq(rep.setup.length, 2, "existing pool + positions, no setup complaint");
            assertTrue(_contains(rep.setup[0], "existing pool, tick -1234"), "used the given pool");
        }
    }

    /// @dev a key for a pool nobody initialized yet: the checker initializes it itself
    function test_ownHooks_givenUninitializedKey() public {
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (MockERC20 t0, MockERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);
        CheckConfig memory cfg;
        cfg.manager = manager;
        cfg.hook = address(prio);
        cfg.hasKey = true;
        cfg.key = PoolKey(Currency.wrap(address(t0)), Currency.wrap(address(t1)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 200, IHooks(address(prio)));
        Report memory rep = runChecks(cfg);
        _assertAllPass(rep);
        assertTrue(_contains(rep.setup[0], "was not initialized; initialize at tick 6931: ok"));
    }

    /// @dev a static-fee key: both hooks refuse it, the checker says so instead of failing
    function test_ownHooks_givenKeyTheHookRejects() public {
        CheckConfig memory cfg;
        cfg.manager = manager;
        cfg.hook = address(vol);
        cfg.hasKey = true;
        cfg.key = PoolKey(Currency.wrap(address(0x1000)), Currency.wrap(address(0x2000)), 3000, 60, IHooks(address(vol)));
        Report memory rep = runChecks(cfg);
        _assertNoFail(rep);
        _assertStatus(rep, D_REMOVE, Status.UNKNOWN);
        _assertStatus(rep, E_SWAP, Status.UNKNOWN);
        _assertStatus(rep, B_CALLER, Status.PASS); // does not need a pool
        _assertStatus(rep, G_UPGRADE, Status.PASS);
        assertTrue(_contains(rep.setup[0], "reverted"), "setup explains why there is no pool");
    }

    /// @dev runChecks rolls everything back: time, gas price, pools, the checker's own actors
    function test_runChecks_leavesNoStateBehind() public {
        uint256 t = block.timestamp;
        uint256 n = block.number;
        uint256 gp = tx.gasprice;
        uint256 bf = block.basefee;
        bytes32 before = keccak256(abi.encode(address(vol).code, address(manager).balance, vm.getNonce(address(this))));
        Report memory rep1 = _check(address(vol));
        assertEq(block.timestamp, t, "time");
        assertEq(block.number, n, "block");
        assertEq(tx.gasprice, gp, "gas price");
        assertEq(block.basefee, bf, "base fee");
        assertEq(keccak256(abi.encode(address(vol).code, address(manager).balance, vm.getNonce(address(this)))), before, "state");
        assertEq(address(_swapper), address(0), "the checker's own storage is rolled back too");
        // and it is deterministic: a second run prints the same report, byte for byte
        Report memory rep2 = _check(address(vol));
        assertEq(keccak256(bytes(renderReport(rep1))), keccak256(bytes(renderReport(rep2))), "same report twice");
    }

    // --- the checker profile does not change what the hooks compile to -----------------------------

    /// @dev sha256 of what `forge inspect <Hook> bytecode` prints (0x-hex plus newline) in the DEFAULT
    ///      profile, as recorded in hooks/README.md. Equal here means: same init code in this profile.
    function test_initCodeHashes_sameAsDefaultProfile() public pure {
        assertEq(
            sha256(bytes(string.concat(vm.toString(type(VolatilityFeeHook).creationCode), "\n"))),
            0xd0d7d802b0894f7d087f85142fc3c596f6c65dce21847120dd7fa3e3a0ae8b70,
            "VolatilityFeeHook init code"
        );
        assertEq(
            sha256(bytes(string.concat(vm.toString(type(PriorityFeeHook).creationCode), "\n"))),
            0xd37f4d4985f8087affcef738179f6bbebc13d10830df015d517524938cfe9799,
            "PriorityFeeHook init code"
        );
    }

    /// @dev the salts and (undeployed) Base addresses recorded in hooks/README.md still come out
    function test_recordedSaltsStillValid() public view {
        (address a1, bytes32 s1) =
            HookMiner.find(CREATE2_PROXY, FLAGS, type(VolatilityFeeHook).creationCode, abi.encode(BASE_POOL_MANAGER));
        assertEq(uint256(s1), 4820, "VolatilityFeeHook salt");
        assertEq(a1, 0x4B7651999822ba687E96bbaE929A41f7E0AB9080, "VolatilityFeeHook address");
        (address a2, bytes32 s2) =
            HookMiner.find(CREATE2_PROXY, FLAGS, type(PriorityFeeHook).creationCode, abi.encode(BASE_POOL_MANAGER));
        assertEq(uint256(s2), 2403, "PriorityFeeHook salt");
        assertEq(a2, 0xBeb0026Aa9eF43478b921106D56Ebc7b1eD75080, "PriorityFeeHook address");
    }
}
