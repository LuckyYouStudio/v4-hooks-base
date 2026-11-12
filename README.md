# Uniswap v4 Hooks portfolio (Base)

English | [中文](README.zh.md)

> **NOT EXTERNALLY AUDITED. DO NOT USE WITH MAINNET FUNDS.**
> Everything in this repository - code, tests, documentation and the audit reports - was written by AI
> agents. The "internal audits" were carried out by an **AI agent** (the `hook-auditor` role). They are
> **not an external audit** and not the opinion of any third-party audit firm. Nothing here has been
> deployed to any public network. Provided as is, with no warranty; see the disclaimer at the end.

Most of the detailed documentation (design notes, audit reports, fact sheets) is in Chinese. This page
and the source-code comments are in English.

## What this is

Three open-source pieces of work around Uniswap v4 hooks, targeting Base. The point is not "we have
these hooks" (comparable implementations already exist in OpenZeppelin's hooks library). The point is
how they are built: **the design trade-offs are written down, the limitations come first, the tests
include adversarial searches, and the whole review trail - every finding - is published.**

| Piece | In one sentence | Details |
|---|---|---|
| `VolatilityFeeHook` | Dynamic fee: the LP fee follows the pool's own realised volatility, sampled in 10-second time buckets | [`docs/VolatilityFeeHook.md`](docs/VolatilityFeeHook.md) |
| `PriorityFeeHook` | The higher the priority fee of the transaction, the higher the LP fee of that swap. **A demonstration of design and honest evaluation; it does not claim to bring LPs meaningful revenue** | [`docs/PriorityFeeHook.md`](docs/PriorityFeeHook.md) |
| Hook safety checker, `checker/` | A Foundry test tool that runs nine classes of generic checks against any v4 hook. **Passing every check does not mean a hook is safe, and it is not an audit** | [`checker/README.md`](checker/README.md) |

What the two hooks have in common: not upgradeable; no owner or admin; they hold no funds; no return
deltas; no liquidity callbacks at all (removing liquidity never goes through the hook, in any state);
callbacks accept calls from the PoolManager only; they serve only pools registered in
`afterInitialize`; every parameter is a hard-coded constant.

## Read this first: known limitations

These are the limitations stated at the top of each design note. None has been left out.

**`VolatilityFeeHook` - two main limitations:**

- **In a pool whose price sits next to a zero-liquidity range (single-sided liquidity; an LP range
  that is narrow and that the market has left; a pool that has been emptied), anyone can push the fee
  to the 1% cap at zero cost.** The lower bound on "raising the fee costs money" holds only where
  liquidity is continuous along the price path; the `L` in that bound is the minimum liquidity on the
  path.
- **In a pool with a dominant LP, treat the fee as something that LP can set anywhere in
  [0.05%, 1%]:** the fees of its own price-pushing swaps come back to it, and the saw-tooth amplitude
  always stays below the fee, so it is not arbitraged away.

Both are recorded as facts by tests (`test/VolatilityFeeHook.reaudit.t.sol`). In both cases the ceiling
is the hard-coded 1% LP fee; principal is not at risk and removing liquidity is not affected. Details:
the sections on liquidity gaps (N-1) and the dominant LP (M-1 / E-A) in the design note.

**`PriorityFeeHook` - four main limitations (details and sources in the design note):**

- **Today it collects very little.** The researcher's order-of-magnitude estimate: all v4 swap
  transactions on Base together pay roughly 0.6 ETH per day in priority fees (a linear extrapolation
  from a 20-minute sample); a single pool sees only a small part of that.
- **Quotes do not include the surcharge.** The Quoter, and any `eth_call` without fee fields (or with
  only `maxFeePerGas`), read a priority fee of 0, so the quote uses 0.05% while execution can use up
  to 0.30%: an exactIn swap receives up to about 2,501 ppm less, an exactOut swap pays up to about
  2,507 ppm more. **Orders that leave 0.1% or 0.25% slippage on top of the quote revert at the cap;
  orders that leave 0.5% go through.** For an accurate quote, the quoting call must carry
  `maxPriorityFeePerGas` or a legacy `gasPrice`.
- **For sponsored / relayed transactions the fee is decided by whoever assembles the transaction; if
  that party is an LP, or does JIT liquidity inside the same transaction (add liquidity -> the user's
  swap -> remove; no standing position is needed, but capital is), then above a break-even notional,
  raising the tip is profitable for them.** Break-even: about 0.08 ETH for a sole LP at 200k gas;
  about 0.2 ETH for JIT at an assumed 500k gas and a share close to 100%. The gas numbers are
  assumptions. Below break-even it loses money; a test in this repository asserts that at a notional
  of 0.01 ETH it loses at every share. **The JIT share is JIT / (JIT + existing in-range
  liquidity):** a 90% / 99% share needs about 9x / 99x the capital that the existing LPs have in the
  same narrow range, own funds or a flash loan (the flash-loan path was not tested, and its gas is not
  part of the 500k assumption). When the share can be made large, most of the surcharge goes to that
  party, not to the existing LPs. Measured: a user exactIn of 10e18, a relayer with no position doing
  JIT of 99e24 (about 593,080 tokens needed inside the transaction, roughly 59,000 times the user's
  10-token notional): the relayer nets 0.005001 tokens at tip 0 and 0.030001 tokens at the cap (at
  price 1), while the existing LP receives only 3.03e11 wei (0.03 tokens without the JIT). With only
  9x capital (about 53.9 tokens) raising the tip earns an extra 0.0225 tokens and leaves the existing
  LP 0.003 tokens (the table by capital is in the design note, section 9, 5a). This is the same
  mechanism as "third-party JIT takes part of the surcharge": the party best placed to aim JIT at a
  single transaction is its assembler. Affected: structures where the user signs a minimum output and
  someone else lands the transaction (ERC-4337, EIP-7702 sponsorship, meta-transaction relayers).
  Intent / filler systems are not affected (the filler bears the surcharge). Whether a bundler can
  wrap `handleOps` in its own contract to do JIT was not verified. The ceiling is the hard-coded 0.30%
  LP fee and is bounded by the user's own slippage protection; a maximum fee declared in `hookData`
  was not implemented (trade-off in the design note, section 9, 5a). Independently of relayers, any
  third party can wrap a high-tip swap with JIT liquidity and take the surcharge pro rata (measured:
  with 9x the existing in-range liquidity it takes 90%); the hook does nothing about this.
- **It can be bypassed:** an uncontested same-block follow-up with a conditional transaction, L1
  deposit transactions, trading in another pool; and in future the coinbase tip of EIP-8130.

Each point is recorded as a fact by tests (`test/PriorityFeeHook.adversarial.t.sol`,
`test/PriorityFeeHook.jit.t.sol`, `test/PriorityFeeHook.quoter.t.sol`). Principal is not at risk and
removing liquidity is not affected (the hook has no liquidity callbacks).

## The three pieces

### 1. `VolatilityFeeHook` - dynamic fee

- **What it does.** `afterInitialize` registers the pool (it must be a dynamic-fee pool); `beforeSwap`
  returns an override fee. Each pool is observed at most once per 10-second bucket, before the first
  swap of that bucket executes: `variance = variance * 2^(-dt/600s) + delta^2`,
  `fee = clamp(500 + 25 * sqrt(variance), 500, 10000)` pips, i.e. 0.05% to 1%. No external oracle.
- **Design trade-offs.** The observed quantity is the **difference of the sub-tick log price across
  buckets** - not the current tick, the spot price or single-block volume. The first version used
  "the integer tick, once per block"; the first audit round's PoC showed the fee could be raised for
  free by jittering across a tick boundary (H-1), so the observation was replaced. The price of that
  fix is a fee that lags by up to one bucket. Only `afterInitialize` and `beforeSwap` are enabled
  (low 14 address bits `0x1080`).
- **Known limitations.** The two above, plus all 11 items under "已知局限" in the design note (one
  bucket of lag; it only sees volatility that shows up in this pool's own trades; parameters are not
  backtested; not sensitive to tick spacing or the pair; arming only partly mitigates L-2; ...).
- **Tests.** 108 offline (unit, fuzz, adversarial search for the cheapest way to move the fee,
  stateful invariants) and 15 on a Base fork.

### 2. `PriorityFeeHook` - priority fee to LPs

- **What it does.** `beforeSwap` returns an override fee computed from the priority fee of the
  transaction, `max(tx.gasprice - block.basefee, 0)`: a floor of 0.05%, a linear surcharge on the part
  above 0.02 gwei, capped at 0.30% at roughly 1 gwei. The hook is stateless apart from pool
  registration and never holds funds.
- **Design trade-offs.** The minimal version only: an override fee in `beforeSwap`, no return delta.
  It charges by rate, not by amount. A user-declared maximum fee in `hookData` was not implemented
  (costs in the design note, section 9, 5a). Parameters cannot be changed; changing them means
  deploying a new hook.
- **Honest evaluation.** **Today it collects very little**, it can be bypassed, quoting tools that do
  not pass fee fields quote without the surcharge, and under certain conditions the party that lands a
  transaction can profit by raising the tip - all four are in the section above, with details in the
  design note. The premise check (does Base order by priority fee, what can a hook read) is in
  [`docs/research/base-priority-ordering-for-hooks.md`](docs/research/base-priority-ordering-for-hooks.md).
- **Tests.** 93 offline (including adversarial tests, the JIT capital table, the quote/execution gap
  against V4Quoter, a four-pool invariant suite) and 13 on a Base fork (real PoolManager, real
  V4Quoter, real USDC).

### 3. Hook safety checker (`checker/`)

- **What it does.** Runs nine classes of generic checks against a v4 hook (deployed locally, or an
  address on a fork) and prints a report: (a) permission bits consistent three ways, (b) callbacks
  callable by someone other than the PoolManager, (c) state pollution by a foreign pool, (d) can
  liquidity removal be blocked, (e) can swaps be jammed, (f) bounds and same-block sensitivity of a
  dynamic fee, (g) signs of upgradeability / an admin, (h) funds held by the hook, (i) how much a
  return delta takes. Each item reports PASS / FAIL / N/A / UNKNOWN with evidence.
- **Design trade-offs.** The hook under test is treated as an adversary (it may call back, and it may
  recognise and deceive the checker). Anything like "the control also failed" or "not tested" never
  lands on PASS. A PASS summary only ever says "nothing found for these inputs". Detection only: there
  is no usable attack code against any live contract.
- **Known limitations.** **Passing every check does not mean a hook is safe, and it is not an audit;
  FAIL does not mean there is a vulnerability.** A hook can recognise the checker and behave - the
  tool cannot prevent that. For hooks that serve only specific pools or allow only specific liquidity
  providers, most items can only report UNKNOWN. The false-positive / false-negative tables and the
  limits of what it can detect are in [`checker/README.md`](checker/README.md).
- **Samples.** `checker/samples/` holds 10 **deliberately vulnerable** minimal hooks (one per generic
  problem, each with a fixed counterpart); `checker/test/mocks/` holds the variants used for audit
  regression. They are abstract minimal models for testing the checker locally. **Do not deploy
  them.**
- **Tests.** The checker's own tests: 131 passed and 1 skipped offline; 14 passed and 2 skipped on a
  Base fork (the skipped ones are the command-line entry, which needs extra environment variables).
- **Runs against real addresses.** During development the checker was smoke-tested 8 times against 5
  third-party hook addresses on a Base fork. Nobody reviewed those outputs line by line; **they are
  not a security conclusion about any third-party project and are not part of this repository.** How
  to run it yourself: `checker/README.md`.

## Build and test

Requires [Foundry](https://book.getfoundry.sh/) (`forge`, `cast`, `anvil`) and git. Foundry downloads
the compiler (solc 0.8.26) itself.

```bash
git clone <this repository> && cd <this repository>
script/install-deps.sh                               # fetch the four dependencies at pinned commits into lib/
forge build

# the two hooks
forge test --no-match-path "test/fork/*"             # offline, 205 tests, no RPC needed
BASE_RPC_URL=https://mainnet.base.org \
  forge test --match-path "test/fork/*"              # Base fork, 36 tests, block pinned at 56,228,000

# the checker (its own profile)
FOUNDRY_PROFILE=checker forge test --no-match-path "checker/test/fork/*"     # offline: 131 passed, 1 skipped
FOUNDRY_PROFILE=checker BASE_RPC_URL=https://mainnet.base.org \
  forge test --match-path "checker/test/fork/*"                              # Base fork: 14 passed, 2 skipped
```

These numbers are what was actually run on this version of the repository on 2026-11-12 (Foundry
1.9.0, macOS). Offline 205 = `VolatilityFeeHook` 108 + `PriorityFeeHook` 93 + deployment scripts 4;
fork 36 = 15 + 13 + deployment scripts 8 (3 end-to-end, 5 negative). Each invariant suite counts as one test.

- Without `BASE_RPC_URL` the fork tests are skipped as a group (not failed). The RPC URL only ever
  comes from the environment. **Never commit an RPC URL that contains an API key, or any other
  secret.** Variable names are listed in [`.env.example`](.env.example).
- The fork tests run against the real PoolManager on Base mainnet,
  `0x498581fF718922c3f8e6A244956aF099B2652b2b` (source: the official Uniswap deployments page,
  https://docs.uniswap.org/contracts/v4/deployments). The state of the pinned block is only readable
  while the RPC still keeps it; public nodes do not promise that. The first run has to download state;
  with a cold cache the checker's fork tests can take ten to twenty-odd minutes.
- The hooks' fork tests use mock tokens and native ETH (`PriorityFeeHook` additionally uses real USDC
  and the real V4Quoter) through v4-core's test routers. Universal Router and PositionManager are not
  used.

More commands:

```bash
forge test --match-contract GasTest -vv             # swap gas with and without the hook
forge test --match-contract Manipulation -vv        # H-1 regression, net-cost table by LP share
forge test --match-contract ReAudit -vv             # measured numbers for N-1 and E-A
forge test --match-path "test/PriorityFee*" -vv     # PriorityFeeHook adversarial tables, quote gap, gas overhead
BASE_RPC_URL=https://mainnet.base.org script/probe-priority-fee.sh           # read-only eth_call probe, sends nothing
CHECK_FORK_BLOCK=56228000 checker/script/check-hook.sh 0x<hook address> <report name>   # check an on-chain address (local fork simulation, read-only)
```

## Review status

**Every review was an internal audit carried out by an AI agent. None of it is an external audit.**
The auditor is a read-only AI agent (`hook-auditor`), separate from the agent that wrote the code
(`hook-engineer`). Each round's report, PoCs and variant sources are in [`audits/`](audits/) (the
public copies only had internal paths and role names cleaned up; conclusions and findings are
unchanged). The "project lead re-check" paragraphs in the reports record a coordinating agent
re-running the PoCs; that is not third-party verification either.

| Piece | Rounds | Reports (Chinese) |
|---|---|---|
| `VolatilityFeeHook` | three (first audit, re-audit, narrow third pass) | [`audits/audit-hooks-h1.md`](audits/audit-hooks-h1.md), [`audits/audit-hooks-h1-reaudit.md`](audits/audit-hooks-h1-reaudit.md) (third pass appended at the end); PoCs in [`audits/audit-hooks-h1/`](audits/audit-hooks-h1/) |
| `PriorityFeeHook` | two (first audit, narrow second pass) | [`audits/audit-hooks-h2.md`](audits/audit-hooks-h2.md) (second pass appended at the end); PoC in [`audits/audit-hooks-h2/`](audits/audit-hooks-h2/) |
| Checker `checker/` | two (first audit, re-audit), then closing fixes checked by the project lead | [`audits/audit-hooks-h3.md`](audits/audit-hooks-h3.md), [`audits/audit-hooks-h3-reaudit.md`](audits/audit-hooks-h3-reaudit.md); variants in [`audits/audit-hooks-h3/`](audits/audit-hooks-h3/) |

Summary of outcomes:

- `VolatilityFeeHook`: round 1 found H-1 (free fee raising by jittering across a tick boundary) and
  others, and the contract was changed. Round 2: H-1 fixed; new findings N-1 (medium) and E-A (medium)
  had to be documented and covered by tests; the contract code did not need to change. Round 3 (docs
  and tests only): two small edits. Not fixed, only documented: N-1, M-1 / E-A, the L-2 residue.
- `PriorityFeeHook`: round 1 found nothing that required a contract change (no critical / high /
  medium); documentation, tests and comments had to change (E-1: a relayer doing JIT does not need to
  be an LP; T-1: an invariant that ran vacuously; ...). Round 2: wording only.
- Checker: round 1 found 2 high, 4 medium, 7 low (for example, a hook could re-enter the checker's
  public entry and get "every withdrawal reverts" reported as PASS). After fixes, the re-audit
  confirmed both highs fixed and found 2 medium and 3 low more. The two mediums were fixed; the lows
  were fixed or documented as known gaps (for example one fork-roll case still yields a PASS and is
  pinned by a test, see `checker/README.md`). These closing changes were checked by the project lead
  only.
- In every case the last edits after the final round were checked by the project lead only; the
  auditor did not look again.
- **The deployment scripts (`script/Deploy*.s.sol`, `script/DeployHookBase.sol`,
  `script/verify-deploy-local.sh`) and `script/install-deps.sh` were written after the audits.**
  Before publication they had **one narrow review by the same internal AI-agent auditor** (reading the
  scripts, mutating their checks, running them on a local fork); the fixes made after that review were
  checked by the project lead only. This is not an audit of the scripts and not an external audit.
  They have only ever been run against a local fork.

The round-by-round tables are in [`README.zh.md`](README.zh.md) and at the end of each design note.

Notes for reading the reports: "H1 / H2 / H3" mean `VolatilityFeeHook`, `PriorityFeeHook` and the
checker; `hooks/` means the root of this repository. The header comment of
`src/VolatilityFeeHook.sol` still cites `research/audit-hooks-h1.md` and
`research/audit-hooks-h1-reaudit.md`: those are the pre-publication paths of
`audits/audit-hooks-h1.md` and `audits/audit-hooks-h1-reaudit.md`. The source files have been frozen
since the audits, so those two comment lines were left as they are.

sha256 of the five audited source files (`shasum -a 256 src/*.sol src/*/*.sol`):

```
fed4356589142fa9a6af605f8eb4ccf8717851716076f5c3609c15a432d2394e  src/PriorityFeeHook.sol
d12879750ee9aeca63c7525d5336c8efc5886c6a1a2c7759674ce54b017b004c  src/VolatilityFeeHook.sol
5e9d17890e2ff2537d557977ea70319d45e6b999fda351140706d0873968ac4f  src/base/BaseHook.sol
950d98e56844e6806a052b203f6e6f755cdde66e4f013df1119800b9911cf24b  src/libraries/PriorityFeeMath.sol
ef77c83444a3d8c7052ffe1f408b37613a0578c26eafc4ecd665e4cef87290ed  src/libraries/VolatilityMath.sol
```

## Layout

```
src/
  VolatilityFeeHook.sol         afterInitialize registers the pool, beforeSwap returns the override fee
  libraries/VolatilityMath.sol  pure math: sub-tick log price, decay, accumulation, variance -> fee, sqrt
  PriorityFeeHook.sol           afterInitialize registers the pool, beforeSwap returns a fee from the tx priority fee
  libraries/PriorityFeeMath.sol pure math: saturating priority fee, threshold + linear + cap schedule
  base/BaseHook.sol             shared base written for this repository (not the official one): external
                                callbacks are non-virtual + onlyPoolManager; unimplemented callbacks revert;
                                the constructor checks PoolManager code and all 14 permission bits
test/                           tests of the two hooks; test/fork/ runs against the real PoolManager on Base
script/
  install-deps.sh               fetch dependencies at pinned commits
  MineHookAddress.s.sol, MinePriorityFeeHookAddress.s.sol    read-only: print the CREATE2 salt and address
  DeployVolatilityFeeHook.s.sol, DeployPriorityFeeHook.s.sol, DeployHookBase.sol
                                deployment scripts (NOT audited, only ever run on a local fork)
  verify-deploy-local.sh        run both deployment scripts on a local anvil fork of Base and read the result back
  PriorityFeeProbe.sol, probe-priority-fee.sh                read-only eth_call probe
checker/                        the hook safety checker (separate Foundry profile), see checker/README.md
  samples/, test/mocks/         deliberately vulnerable minimal models - do not deploy
  reports/                      the two sample detection matrices generated by the checker's own tests
docs/
  VolatilityFeeHook.md, PriorityFeeHook.md   one design note per hook (Chinese)
  research/                     two fact sheets compiled before the hooks were written (by an AI agent;
                                items self-reported as unverified are marked as such)
audits/                         five internal (AI agent) audit reports with their PoC / variant sources
PUBLISHING.md                   publishing checklist (for the maintainer)
lib/                            dependencies, not committed, fetched by script/install-deps.sh
```

The `.sol` files under `audits/` are the auditor's original PoCs and variants (index and notice in
[`audits/README.md`](audits/README.md)). No Foundry profile
compiles them; to run them, copy them where each report's instructions say. The variants there are
deliberately defective models as well: do not deploy them.

## Dependencies (pinned)

`lib/` is not committed. `script/install-deps.sh` fetches the four repositories below into `lib/` with
git and verifies the checked-out commit. This was tested from scratch in an empty directory: fetch
dependencies, `forge build`, offline tests of both profiles - all pass.

| Directory | Source | Commit | Licence | Used for |
|---|---|---|---|---|
| `lib/v4-core` | github.com/Uniswap/v4-core | `59d3ecf53afa9264a16bba0e38f4c5d2231f80bc` (2025-05-13, npm `@uniswap/v4-core` 1.0.2; the commit v4-periphery itself pins) | mostly MIT; 8 files BUSL-1.1 (`PoolManager.sol`, `Pool.sol`, `Position.sol`, `Lock.sol`, ...); under `src/test/` one file GPL-3.0-or-later and most others UNLICENSED | The import closure of `PriorityFeeHook` is MIT files only. `VolatilityFeeHook` directly imports MIT files only, but one of them, `StateLibrary.sol`, itself imports `Position.sol` (BUSL-1.1). Tests deploy `PoolManager` (BUSL-1.1) from source. The import closure of `checker/src` contains 5 BUSL-1.1 files |
| `lib/v4-periphery` | github.com/Uniswap/v4-periphery | `c6e4754dab11bd38c6f08ac51c3c868569e93d64` (main, 2026-10-26; the repository has no tags) | MIT | `test/shared/HookMiner.sol` (tests and scripts); `src/lens/V4Quoter.sol` (deployed in tests only); `src/libraries/LiquidityAmounts.sol` (checker) |
| `lib/solmate` | github.com/transmissions11/solmate | `4b47a19038b798b4a33d9749d25e570443520647` (the submodule pointer of that v4-core commit) | AGPL-3.0-only (a few files MIT) | `MockERC20` (with the `ERC20.sol` it inherits, both AGPL-3.0-only): test-only for the two hooks; `checker/src` imports it as well |
| `lib/forge-std` | github.com/foundry-rs/forge-std | `dc647cc030d9d65910d8f1172a0cde48d7106e32` (master, 2026-11-02, ten commits after tag `v1.17.0`; `package.json` still says 1.17.0) | MIT OR Apache-2.0 | tests and scripts |

- Only the top level of each dependency is fetched; **their own submodules are not initialised**.
  `remappings.txt` points every import at the single copy under `lib/`, so there is exactly one
  v4-core in the build.
- Difference from the fact sheet's suggestion
  ([`docs/research/uniswap-v4-hooks-base.md`](docs/research/uniswap-v4-hooks-base.md), section 2.2,
  suggests pinning v4-periphery at `7ebd04b161745b75ed0c24ba2df3bc7c25f65606`): this repository pins
  main. Main has moved `BaseHook` and `src/utils/HookMiner.sol` to Uniswap/v4-hooks-public, so
  `HookMiner` is imported from `v4-periphery/test/shared/HookMiner.sol` (not diffed word for word
  against the `7ebd04b1` version) and `BaseHook` is this repository's own. Both commits pin the same
  v4-core.

## Compiler settings

`foundry.toml`: solc **0.8.26** (the pragma of `PoolManager.sol` is fixed to this version and the
tests deploy it from source), evm **cancun**, optimizer with 800 runs, no via_ir,
`bytecode_hash = "none"`. `gas_limit = 8e9` is only an execution limit for tests (one H-1 regression
test runs 15,000 swaps, about 1.2e9 gas); it is not a compiler setting and does not affect bytecode.

**Changing any compiler setting, or anything in a hook's source other than comments, changes the init
code, and the address must be mined again.** Comment-only changes do not: with
`bytecode_hash = "none"` the bytecode carries no source metadata hash. sha256 of
`forge inspect VolatilityFeeHook bytecode`: `d0d7d802…ae8b70`; of
`forge inspect PriorityFeeHook bytecode`: `d37f4d49…8cfe9799` (`checker/test/OwnHooks.t.sol` asserts
both, together with the salts).

## Address mining

v4 encodes the callbacks a hook enables in the low 14 bits of its address. When a pool is created the
PoolManager only checks that return-delta bits come with their base bits; **the check that all 14 bits
match exactly lives in the hook's own constructor** (`BaseHook` calls
`Hooks.validateHookPermissions`), so a hook mined to the wrong address cannot be deployed at all.

- Library: `HookMiner.find(deployer, flags, creationCode, constructorArgs)` returns
  `(address, salt)`; then `new Hook{salt: salt}(args)`.
- `deployer`: in tests, the test contract; with `forge script` / `forge create`, the deterministic
  deployment proxy `0x4e59b44847b379578588920cA78FbF26c0B4956C` (forge-std's `CREATE2_FACTORY`).
- Read-only scripts (no broadcast, no key):

```bash
POOL_MANAGER=0x498581fF718922c3f8e6A244956aF099B2652b2b forge script script/MineHookAddress.s.sol \
  --rpc-url https://mainnet.base.org
#   VolatilityFeeHook: salt 4820 (0x12d4), address 0x4B7651999822ba687E96bbaE929A41f7E0AB9080 (low 14 bits 0x1080)
POOL_MANAGER=0x498581fF718922c3f8e6A244956aF099B2652b2b forge script script/MinePriorityFeeHookAddress.s.sol \
  --rpc-url https://mainnet.base.org
#   PriorityFeeHook:   salt 2403 (0x963),  address 0xBeb0026Aa9eF43478b921106D56Ebc7b1eD75080 (low 14 bits 0x1080)
```

A salt is not a secret, but it is only valid for "this bytecode + this constructor argument + this
deployer". The addresses above are computed only. **Nothing is deployed there.**

## Deployment scripts (NOT audited; verified on a local fork only)

`script/DeployVolatilityFeeHook.s.sol` and `script/DeployPriorityFeeHook.s.sol` (shared logic in
`script/DeployHookBase.sol`):

- The PoolManager is chosen by chain id: 8453 (Base mainnet) and 84532 (Base Sepolia), from the fact
  sheet, sections 1.1 / 1.2. **Any other chain reverts with `UnsupportedChain`.**
- The script mines the salt, runs `new Hook{salt: salt}(poolManager)`, then asserts: deployed address
  equals the mined address; the low 14 address bits equal the permission flags; the address has code;
  `hook.poolManager()` equals the table's PoolManager; `Hooks.validateHookPermissions` passes. If the
  hook is already deployed on that chain it reverts with `AlreadyDeployed` instead of deploying a
  second copy at the next salt.
- These assertions are defence in depth. What actually stops a wrong salt, a wrong constructor
  argument or a plain CREATE is the hook's own constructor (it reverts with `HookAddressNotValid`),
  not the script. Negative tests (`test/fork/DeployScriptsNeg.t.sol`, which hand the script a broken
  deployment result) pin four of the five post-deployment assertions - address mismatch, no code,
  wrong PoolManager, `validateHookPermissions` - and the missing-CREATE2-proxy check. The fifth, the
  low-14-bits check (`PermissionBitsMismatch`), cannot fire once the address check has passed and has
  no test; deleting it changes no test result.
- `AlreadyDeployed` can also mean that someone else deployed the same init code with the same salt
  first. A CREATE2 address is determined by the init code, so the contract at that address is
  byte-for-byte the one this script would deploy; it has no owner and can be used as it is. Before
  using it, check for yourself with `cast code` and `cast call <hook> 'poolManager()(address)'`.
- **The scripts themselves read nothing from the environment** (`vm.startBroadcast()` is called
  without arguments, and there is no `vm.env*` call). The signer is whatever forge is given: a
  keystore (`--account <name>`) or a hardware wallet (`--ledger` / `--trezor`). Note that forge itself
  also accepts the keystore selection from `ETH_KEYSTORE`, `ETH_KEYSTORE_ACCOUNT` and `ETH_PASSWORD`;
  check that these are unset, or are what you intend, before adding `--broadcast`. Do not use
  `--private-key`.
- `foundry.toml` was not changed for them. The scripts write no files themselves (forge keeps its
  usual run records under `broadcast/` and `cache/`, both git-ignored).

**These scripts have not been audited (one narrow internal review, see "Audit status") and have only
been run locally. Deploying to a testnet or to mainnet requires the project owner's approval and is
done by the project owner in person.** Reproducible local verification:

```bash
BASE_RPC_URL=https://mainnet.base.org forge test --match-contract "DeployScripts(Neg)?ForkTest" -vv   # simulated inside a fork, 3 + 5 tests
script/verify-deploy-local.sh   # starts a local anvil forking Base, really --broadcasts both scripts to
                                # http://127.0.0.1:<port> from anvil's unlocked dev account, then reads the result back with cast
forge script script/DeployVolatilityFeeHook.s.sol --rpc-url https://mainnet.base.org   # no --broadcast: simulation only, nothing is sent
```

- `verify-deploy-local.sh` only ever talks to `http://127.0.0.1:<ANVIL_PORT>` for sending. Before it
  sends anything it refuses unless: `ANVIL_PORT` is a plain number (so the URL cannot be turned into
  another host); nothing is listening on that port yet; the anvil process it started is alive; and
  the node on that port answers `anvil_nodeInfo` with chain id 8453. The fork source (`BASE_RPC_URL`)
  is only read from.
- Every `forge script` run, including a dry run without `--broadcast` such as the last line above,
  leaves a record under `broadcast/Deploy<Hook>.s.sol/<chain id>/` (git-ignored). The local fork has
  chain id 8453 too, so `verify-deploy-local.sh` refuses to run while
  `broadcast/Deploy<Hook>.s.sol/8453` exists ("refusing to run: ... already exists"). Move or delete
  that directory, then run it again.

## What has not been done

- **No external audit.** No public bug bounty.
- **Nothing is deployed to any public network** - neither mainnet nor a testnet. The hook addresses in
  this README are computed, not deployed.
- **Parameters are not backtested.** The constants of both hooks are engineering starting points. They
  were not calibrated on historical data and no LP revenue was estimated for any pool.
- Not tested with Universal Router, PositionManager, Permit2, or a real ERC-4337 EntryPoint /
  sponsorship entry. Slippage and routing use v4-core's test routers and a minimal test router
  written for this repository.
- No dedicated tests with fee-on-transfer, rebasing or no-return-value tokens (the hooks never touch
  tokens, but it was not tested).
- `PriorityFeeHook`: the path where JIT capital comes from a flash loan was not tested; the ordering
  behaviour of conditional transactions cannot be reproduced in tests; the gas figures in the
  break-even estimates are assumptions.
- Checker: no JSON output; never run on Base Sepolia; its outputs for real third-party addresses were
  not reviewed line by line by anyone.
- The deployment scripts are not audited: they had one narrow pre-publication review by the same
  internal AI-agent auditor, and the fixes made after it were checked by the project lead only. On
  Base mainnet state they were only run inside a local fork; against Base Sepolia only as a read-only
  dry run (no `--broadcast`), which completed. No transaction was ever sent to a public network.
- Items the researcher self-reported as unverified in the fact sheets were not re-checked one by one.
- No CI.

The "not done / not verified" lists in each design note are more detailed.

## Licence

MIT, see [`LICENSE`](LICENSE). This covers the files in this repository only (the source files carry
`SPDX-License-Identifier: MIT` headers). The dependencies under `lib/` are not distributed with this
repository and keep their own licences, some of which are not MIT (BUSL-1.1, AGPL-3.0-only; see the
table above). We have made no legal assessment of what those licences mean for compiling or deploying
this code. The dependencies'
licences are in the table above; `lib/` is not distributed with this repository.

## Disclaimer

This repository demonstrates engineering and review practice. It is not a product ready for
production. **It has not been externally audited; do not use it with mainnet funds.** The internal
audits were done by AI agents and are not an external audit. The authors accept no liability for any
loss arising from the use of this code. Figures in the documentation about on-chain behaviour, fee
distributions and third-party protocols are readings or estimates from the time of writing and may be
out of date; verify them yourself before relying on them. Nothing here is investment advice. Output of
`checker/` is not a security conclusion about any third-party project.
