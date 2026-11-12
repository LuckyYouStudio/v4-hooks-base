> **AI agent(研究员岗位)整理的事实表的公开副本,不是审计,也未经第三方复核。** 文中自报"未核实""估算""二手"的标注原样保留,引用前请自行核对出处。与整理时的原件相比,公开副本做了两类改动:① 路径与称谓清理(内部角色 "CEO" 改称"项目负责人";`research/…` 路径改成本仓库内的路径;内部项目编号和内部规则的称呼改成中性说法);② 发布前审查后,删去或改写了几处对具名第三方项目的未核实推断和内部评语,并在涉及第三方项目的章节前加了一句声明。事实读数和出处没有改。

# 事实表:Uniswap v4 Hooks(Base / Base Sepolia)

> 状态:**第 1–9 节已完成(2026-11-11)**。未能核实的项目汇总在文末 §10(共 17 条)。
> 标注约定:**[文档]** = 官方文档写明;**[源码]** = 官方仓库指定 commit 的文件与行号;**[链上]** = 我在 2026-11-11 用 `cast` 读到;**[二手]** = 只有第三方报道,没有一手出处;**推论** = 由源码推出、没有官方文字直接这么说;**未核实** = 没找到出处或没验证。
> 读数方式:`~/.foundry/bin/cast`,公共 RPC `https://mainnet.base.org`(8453,区块 56,227,003 – 56,227,159)与 `https://sepolia.base.org`(84532,区块 57,569,588 – 57,569,699)。
> 本文只陈述事实,不含业务代码;许可证一节只陈述条款,不做法律结论。

## 出处索引

| 代号 | 内容 |
|---|---|
| [DEPLOY] | Uniswap v4 官方部署页 https://developers.uniswap.org/docs/protocols/v4/deployments (旧地址 `docs.uniswap.org/contracts/v4/deployments` 301 跳到这里;2026-11-11 抓取的是它的 `llms.mdx` 文本版) |
| [CORE] | https://github.com/Uniswap/v4-core ,行号一律指 commit `59d3ecf53afa9264a16bba0e38f4c5d2231f80bc`(2025-05-13,"bump to 1.0.2")下的 `src/`。我核对过:该 commit、`d153b048`、以及 2026-11-11 的 main(`bea7f6d1`)三者 `src/` 完全相同(`git diff --stat` 为空)。链接格式:`https://github.com/Uniswap/v4-core/blob/59d3ecf53afa9264a16bba0e38f4c5d2231f80bc/src/<路径>#L<行>` |
| [PERI] | https://github.com/Uniswap/v4-periphery ,main = `c6e4754dab11bd38c6f08ac51c3c868569e93d64`(2026-10-26);旧 commit `7ebd04b161745b75ed0c24ba2df3bc7c25f65606`(2025-10-23)单独注明 |
| [HOOKS-PUB] | Uniswap Labs 官方 Hook 仓库 https://github.com/Uniswap/v4-hooks-public ,main = `e354058156f8f4f1aff1594a932513e7064956c7`(2026-11-05) |
| [OZ] | https://github.com/OpenZeppelin/uniswap-hooks ,master = tag `v1.3.0-rc.0` = `b5f10574f943911635754dd76ed6ce95858b7d93`(2026-10-07) |
| [TEMPLATE] | https://github.com/uniswapfoundation/v4-template ,main = `1fbf95547791f0821a170b88c750cb2e04e6818b`(2025-10-28) |
| [SEC] | 官方 Hook 安全框架 https://developers.uniswap.org/docs/protocols/v4/security (源仓库 https://github.com/uniswapfoundation/security-framework ) |
| [DOC-SENDER] | https://developers.uniswap.org/docs/protocols/v4/guides/hooks/accessing-msg.sender |
| [DOC-DEPLOY-HOOK] | https://developers.uniswap.org/docs/protocols/v4/guides/hooks/hook-deployment |
| [DOC-DYNFEE] | https://developers.uniswap.org/docs/protocols/v4/concepts/dynamic-fees |
| [DOC-ROUTING] | https://developers.uniswap.org/docs/protocols/v4/concepts/hook-routing |
| [ALLOWLIST] | Uniswap 路由白名单源码 https://github.com/Uniswap/uniroute-public/blob/main/src/lib/poolCaching/util/hooksAddressesAllowlist.ts (该文件最后一次提交 `d4b590f1`,2026-11-09) |
| [HOOKLIST] | Uniswap 官方 Hook 登记库 https://github.com/Uniswap/hooklist ,commit `f4b5956d070e1fe26443e1f8f8be2c018c84bbee`(2026-11-05) |

---

## 1. 部署地址

### 1.1 Base 主网(chainId 8453)

出处均为 [DEPLOY] "Base: 8453" 一节。链上列为我在区块 56,227,003 的读数。

| 合约 | 地址 | 代码长度(字节) | `poolManager()` 返回 | 其他读数 |
|---|---|---|---|---|
| PoolManager | `0x498581ff718922c3f8e6a244956af099b2652b2b` | 24,009 | —(自身) | `owner()`=`0x31FAfd4889FA1269F7a13A66eE0fB458f27D72A9`;**`protocolFeeController()`=`0xc53DD825dedBE7814562528A1A30e8e5BCbB4b55`(非零,有 4,544 字节代码)** |
| PositionManager | `0x7c5f5a4bbd8fd63184577525326123b519429bdc` | 23,877 | 与表一致 | `permit2()`=`0x0000…8BA3`;`name()`="Uniswap v4 Positions NFT";`nextTokenId()`=3,215,924;有 `msgSender()` |
| PositionDescriptor | `0x25d093633990dc94bedeed76c8f3cdaa75f3e7d5` | 1,074 | 与表一致 | — |
| Quoter(V4Quoter) | `0xE1A6C5803e3c44368b171BD680c7D32dfc92CA47` | 6,118 | 与表一致 | 有 `msgSender()` |
| StateView | `0xa3c0c9b65bad0b08107aa264b0f3db444b867a71` | 3,531 | 与表一致 | — |
| ReservesLens | `0x0000001b173C3bbF3984D417d8614E3eed34865B` | 14,142 | 无此函数 | — |
| Universal Router | `0x6ff5693b99212da76ad316178a184ab56d299b43` | 19,499 | 与表一致 | `V4_POSITION_MANAGER()`=上面的 PositionManager;有 `msgSender()` |
| Universal Router 2.1.1 | `0xfdf682f51fe81aa4898f0ae2163d8a55c127fbc7` | 24,546 | 与表一致 | — |
| Universal Router 2.1.2 | `0xd6145b2D3F379919E8CdEda7B97e37c4b2Ca9c40` | 24,380 | 与表一致 | `V4_POSITION_MANAGER()`=上面的 PositionManager;有 `msgSender()` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` | 9,152 | 无此函数 | PositionManager 的 `permit2()` 返回它 |

- [DEPLOY] 同时列了三个 Universal Router,没有说明哪一个是前端当前在用的;见 §10-3。
- [DEPLOY] 原文:"Integrators should **no longer assume that they are deployed to the same addresses across chains**"。Base 的地址与以太坊主网不同,不要从别的链抄。

### 1.2 Base Sepolia(chainId 84532)

出处均为 [DEPLOY] "Base Sepolia: 84532" 一节。链上列为区块 57,569,588 的读数。

| 合约 | 地址 | 代码长度 | `poolManager()` / `manager()` 返回 | 其他 |
|---|---|---|---|---|
| PoolManager | `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408` | 24,009 | — | `owner()`=`0x5b73C5498c1E3b4dbA84de0F1833c4a029d90519`;`protocolFeeController()`=**零地址** |
| PositionManager | `0x4b2c77d209d3405f41a037ec6c77f7f5b8e2ca80` | 23,877 | 与表一致 | `permit2()`=`0x0000…8BA3` |
| Quoter | `0x5e6B8B8AFA7e5CEF6C09dd2A67aBA9FB12C75623` | 6,118 | 与表一致 | — |
| StateView | `0x571291b572ed32ce6751a2cb2486ebee8defb9b4` | 3,531 | 与表一致 | — |
| Universal Router | `0x492e6456d9528771018deb9e87ef7750ef184104` | 19,540 | 与表一致 | — |
| Universal Router 2.1.2 | `0x8702463e73f74d0b6765aBceb314Ef07aCb92650` | 24,380 | 与表一致 | — |
| PoolSwapTest | `0x8b5bcc363dde2614281ad875bad385e0a785d3b9` | 6,950 | `manager()` 与表一致 | v4-core 的测试路由,只在测试网有 |
| PoolModifyLiquidityTest | `0x37429cd17cb1454c34e7f50b09725202fd533039` | 6,050 | `manager()` 与表一致 | 同上 |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` | 9,152 | — | — |
| **ReservesLens** | `0x0000001b173C3bbF3984D417d8614E3eed34865B` | **0(无代码)** | — | **与文档冲突**:[DEPLOY] 列了这个地址,但区块 57,569,699 时该地址没有代码。以链上为准:Base Sepolia 上不可用 |

- [DEPLOY] 的 Base Sepolia 一节**没有列 PositionDescriptor**。
- Base Sepolia 没有协议费控制者,主网有:测试网上测不到协议费对费率的影响(见 §5.4)。

### 1.3 交叉验证方式与结论

1. `cast codesize <地址>`:除 Sepolia 的 ReservesLens 外全部有代码。
2. `cast call <地址> 'poolManager()(address)'`:PositionManager、PositionDescriptor、Quoter、StateView、三个(主网)/两个(Sepolia)Universal Router 返回的都是同链表里的 PoolManager。
3. `cast call <PositionManager> 'permit2()(address)'` 返回表里的 Permit2;`cast call <UniversalRouter> 'V4_POSITION_MANAGER()(address)'` 返回表里的 PositionManager(主网读了两个路由)。
4. 两条链的 PoolManager 运行时字节码**除一处 20 字节外逐字节相同**:长度都是 24,009,差异只在偏移 13,618–13,637,内容分别是各自合约自己的地址(即 `NoDelegateCall` 的 immutable)。主网 codehash `0x83b2af6e…f43eb6`,Sepolia `0x03c45db6…e0249f`。
5. 没有做的:没有把链上字节码与某个 v4-core commit 的编译产物比对(见 §10-1);没有在区块浏览器上逐个看"已验证源码"。

### 1.4 CREATE2 部署器

| 项 | 值 | 出处 |
|---|---|---|
| Foundry 默认的确定性部署代理 | `0x4e59b44847b379578588920cA78FbF26c0B4956C` | [HOOKS-PUB] `src/utils/HookMiner.sol` 第 18 行注释;[DOC-DEPLOY-HOOK];[TEMPLATE] `script/00_DeployHook.s.sol` 用 forge-std 的 `CREATE2_FACTORY` |
| 链上 | Base 主网与 Base Sepolia 上该地址都有 69 字节代码 | [链上] 区块 56,227,159 / 57,569,699 |

---

## 2. 版本与依赖

### 2.1 v4-core

| 项 | 事实 | 出处 |
|---|---|---|
| 唯一的 git tag / GitHub release | `v4.0.0` = `e50237c43811bd9b526eff40f26772152a42daba`(2025-01-21),release 发布于 2025-01-23 | 仓库 tag;GitHub releases API |
| npm | `@uniswap/v4-core` latest = `1.0.2`(2025-05-13 发布),对应 commit `59d3ecf5` | npm registry;`package.json` |
| main | `bea7f6d1`(2026-10-23);`59d3ecf5` 之后的提交没有改 `src/` | `git diff --stat 59d3ecf5 main -- src` 为空 |
| `v4.0.0` → `59d3ecf5` 的 `src/` 差异(不含 `src/test`) | 5 个文件:把 `IPoolManager.ModifyLiquidityParams` / `IPoolManager.SwapParams` 两个结构体搬到新文件 `src/types/PoolOperation.sol`,并相应改 import。**没有逻辑改动,但源码层面不兼容**:按 `v4.0.0` 写的 `IPoolManager.SwapParams` 在新版里编译不过 | `git diff v4.0.0 main -- src ':!src/test'` |
| 编译器 | `foundry.toml`:`solc = "0.8.26"`、`evm_version = "cancun"`、`via_ir = true`、`optimizer_runs = 44444444`、`bytecode_hash = "none"` | [CORE] `foundry.toml` |
| pragma | `PoolManager.sol` 是**写死的** `pragma solidity 0.8.26;`;`Hooks.sol`、`Pool.sol`、`IHooks.sol` 是 `^0.8.0`;用到 transient storage 的库(`Lock`、`CurrencyDelta`、`CurrencyReserves`、`NonzeroDeltaCount`)和 `PoolOperation.sol` 是 `^0.8.24` | 各文件第 2 行 |
| EVM | 用 `tstore` / `tload`(EIP-1153),必须 cancun 及以后 | [CORE] `libraries/Lock.sol` L10–27、`CurrencyDelta.sol` L18–41 |

含义(推论):测试里如果从源码部署 PoolManager(v4-core 自带的 `test/utils/Deployers.sol`),编译器必须正好是 0.8.26;想用更新的 solc 就得改用预编译字节码(官方模板就是这么做的,见 2.4)。

### 2.2 v4-periphery

| 项 | 事实 | 出处 |
|---|---|---|
| git tag / release | **没有任何 tag,也没有 GitHub release** | 仓库;releases API 返回空 |
| npm | `@uniswap/v4-periphery` latest = `1.0.3`(2025-07-29);仓库 main 的 `package.json` 写的是 `1.0.4`(2026-03-17 "bump version"),npm 上没有 | npm registry;[PERI] `package.json` |
| main | `c6e4754d`(2026-10-26);钉的 v4-core 子模块 = `59d3ecf5`,permit2 = `cc56ad0f` | `git ls-tree HEAD lib` |
| **BaseHook / HookMiner 已搬走** | 2026-02-06 的提交 `5da22e60`("remove hooks and move to hook repo (#510)")删掉了 `src/utils/BaseHook.sol`、`src/utils/HookMiner.sol`、WETH/WstETH Hook 等 16 个文件。main 的 `src/` 里**已经没有** BaseHook 和 HookMiner(只剩 `test/shared/HookMiner.sol`);现在在 [HOOKS-PUB] 的 `src/base/BaseHook.sol` 与 `src/utils/HookMiner.sol`。[PERI] README 已改为指向 v4-hooks-public | `git show --stat 5da22e60`;[PERI] `README.md` L17 |
| 最后一个仍带 BaseHook/HookMiner 的常用 commit | `7ebd04b1`(2025-10-23),子模块 v4-core 也是 `59d3ecf5`。OZ uniswap-hooks v1.1.1 – v1.3.0-rc.0 钉的就是它 | `git ls-tree 7ebd04b1 lib`;[OZ] 各 tag 的 `lib/` |
| 之后的主要变动 | 逐跳滑点检查(2025-11、2026-03);Permissioned Pools(2026-05 起,`src/hooks/permissionedPools/`);ReservesLens(2026-07);V4Router exact-output 部分成交改为 revert(2026-08) | `git log` |
| 编译器 | `solc_version = '0.8.26'`、`evm_version = "cancun"`、`via_ir = true`;`PositionManager.sol`、`V4Router.sol` 写死 `pragma solidity 0.8.26;` | [PERI] `foundry.toml` |

**与文档冲突**:[DOC-DEPLOY-HOOK] 和 [DOC-SENDER] 的示例仍然 `import "v4-periphery/src/utils/HookMiner.sol"` / `"v4-periphery/src/utils/BaseHook.sol"`,并把 HookMiner 链到 `v4-periphery/blob/main/src/utils/HookMiner.sol`。按 v4-periphery main 这两个路径不存在。以仓库为准。

### 2.3 Uniswap/v4-hooks-public(官方 Hook 仓库,2026-02-06 建库)

- 自述:"the official Uniswap v4 hook contracts developed and maintained by Uniswap Labs"。没有 tag。子模块钉 v4-core `d153b048`(`src/` 与 `59d3ecf5` 相同)、v4-periphery `07336f21`(2026-08-10)。出处:[HOOKS-PUB] `README.md`、`git submodule status`。
- 内容:`BaseHook`、`HookMiner`(与 [PERI] `7ebd04b1` 的版本逐字相同,我 diff 过)、`HookMinerCreate3`、`PrefacedHookMiner`;成品 Hook 有 `WETHHook`、`WstETHHook`、`StablePairHook`、`VolatilePairHook`(官方的动态费 Hook)、Permissioned Pools、Aggregator Hooks。
- 注意:官方的 `StablePairHook` / `VolatilePairHook` 是 **UUPS 可升级代理**(`src/base/BaseUUPSHook.sol`、`BaseDynamicFeeHook.sol`),与本仓库"不可升级"的设计约束相反,不能照搬结构。

### 2.4 官方 v4-template

| 项 | 事实 |
|---|---|
| 仓库 | https://github.com/uniswapfoundation/v4-template ,[文档] 称由 Uniswap Foundation 维护(https://developers.uniswap.org/docs/community/tooling/v4-template ) |
| 现状 | **最后一次提交 2025-10-28**(`1fbf9554`),到今天一年多没动;README 仍写 "actively maintained" |
| 依赖方式 | 不直接依赖 v4-core / v4-periphery,而是通过 `lib/uniswap-hooks`(OZ)钉在 **v1.1.0**(`e59fe72c`,2025-07-10)间接拿到 v4-core `a7cf038c`、v4-periphery `eeb3eff2`;另依赖个人仓库 `akshatmittal/hookmate`(`33408fbc`)提供 PoolManager / PositionManager / Permit2 / 路由的**预编译字节码**和地址常量 |
| 编译器 | `solc_version = "0.8.30"`、`evm_version = "cancun"`、`via_ir = false` |
| 示例 | `src/Counter.sol` 继承的是 **OZ 的** `BaseHook`;`script/00_DeployHook.s.sol` 用 `HookMiner.find(CREATE2_FACTORY, flags, creationCode, constructorArgs)` 再 `new Counter{salt: salt}(poolManager)` |
| 许可证 | MIT(版权人 saucepoint) |

### 2.5 OpenZeppelin uniswap-hooks

| 项 | 事实 | 出处 |
|---|---|---|
| 许可证 | MIT;README 另写 "Your use of this Project is governed by the terms found at www.openzeppelin.com/tos",并声明 "experimental software" | [OZ] `LICENSE`、`README.md` |
| 最新**正式** release | **`v1.1.1`**(2025-11-27,`prerelease=false`),npm `@openzeppelin/uniswap-hooks` 的 `latest` 也是 `1.1.1` | GitHub releases API;npm registry |
| 之后的版本都标为预发布 | `v1.2.0`、`v1.2.1`(2025-11-27,GitHub 标 prerelease,npm tag 是 `dev`);`v1.3.0-rc.0`(2026-10-07)= 当前 master | 同上 |
| 钉的依赖 | v1.1.1 / v1.2.x / v1.3.0-rc.0 都钉 v4-core `d153b048`、v4-periphery `7ebd04b1` | `git ls-tree <tag> lib/` |
| 编译器 | `solc = "0.8.26"`、`evm_version = "cancun"`;源码多数 `^0.8.26` | [OZ] `foundry.toml` |
| 审计 | 仓库 `audits/` 下有 v1.0.0 RC1、v1.1.0 RC1、v1.1.0 RC2 三份 OpenZeppelin 审计 PDF;v1.2 之后的版本没有对应审计文件 | [OZ] `audits/` |
| 内容 | `base/`:BaseHook、BaseCustomAccounting、BaseCustomCurve、BaseAsyncSwap;`fee/`:BaseDynamicFee、BaseOverrideFee、BaseDynamicAfterFee、BaseHookFee;`general/`:**LimitOrderHook、LiquidityPenaltyHook、AntiSandwichHook、ReHypothecationHook**;`oracles/panoptic/`;`utils/CurrencySettler` | [OZ] `src/` |

与本仓库直接相关:最初计划的三个 Hook 里,动态费(BaseDynamicFee / BaseOverrideFee)、限价单(LimitOrderHook)、撤资罚金捐回池子(LiquidityPenaltyHook)在 OZ 库里都已有同类实现。这是事实陈述;作品集如何差异化由项目负责人定。

---

## 3. 权限位

### 3.1 14 个标志(逐位)

出处:[CORE] `libraries/Hooks.sol` L27–47。`ALL_HOOK_MASK = (1 << 14) - 1 = 0x3FFF`。

| 位 | 掩码 | 常量 | 对应回调 / 含义 |
|---|---|---|---|
| 13 | `0x2000` | `BEFORE_INITIALIZE_FLAG` | `beforeInitialize` |
| 12 | `0x1000` | `AFTER_INITIALIZE_FLAG` | `afterInitialize` |
| 11 | `0x0800` | `BEFORE_ADD_LIQUIDITY_FLAG` | `beforeAddLiquidity` |
| 10 | `0x0400` | `AFTER_ADD_LIQUIDITY_FLAG` | `afterAddLiquidity` |
| 9 | `0x0200` | `BEFORE_REMOVE_LIQUIDITY_FLAG` | `beforeRemoveLiquidity` |
| 8 | `0x0100` | `AFTER_REMOVE_LIQUIDITY_FLAG` | `afterRemoveLiquidity` |
| 7 | `0x0080` | `BEFORE_SWAP_FLAG` | `beforeSwap` |
| 6 | `0x0040` | `AFTER_SWAP_FLAG` | `afterSwap` |
| 5 | `0x0020` | `BEFORE_DONATE_FLAG` | `beforeDonate` |
| 4 | `0x0010` | `AFTER_DONATE_FLAG` | `afterDonate` |
| 3 | `0x0008` | `BEFORE_SWAP_RETURNS_DELTA_FLAG` | `beforeSwap` 返回的 `BeforeSwapDelta` 生效 |
| 2 | `0x0004` | `AFTER_SWAP_RETURNS_DELTA_FLAG` | `afterSwap` 返回的 `int128` 生效 |
| 1 | `0x0002` | `AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG` | `afterAddLiquidity` 返回的 `BalanceDelta` 生效 |
| 0 | `0x0001` | `AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG` | `afterRemoveLiquidity` 返回的 `BalanceDelta` 生效 |

- 是 10 个回调 + 4 个 return-delta 标志 = 14 位。位从地址的最低位数起(位 0 = 最低位)。
- 判定:`hasPermission(self, flag) = uint160(address(self)) & flag != 0`([CORE] `Hooks.sol` L337–339)。高于第 13 位的地址位不参与。
- **与文档的小出入**:[DOC-DEPLOY-HOOK] 把 `BEFORE_SWAP_FLAG` 链到 `Hooks.sol#L37`,在 `59d3ecf5` / main 上实际是 L38。该页说"第 7 位是 AFTER_SWAP、第 8 位是 BEFORE_SWAP"是从 1 数起,对应上表的位 6、位 7。

### 3.2 两处校验,规则不同

| 校验 | 谁调用 | 规则 | 出处 |
|---|---|---|---|
| `isValidHookAddress(hooks, fee)` | **PoolManager 在 `initialize` 时**,每次建池都查 | ① 有 `BEFORE_SWAP_RETURNS_DELTA` 必须有 `BEFORE_SWAP`;② 有 `AFTER_SWAP_RETURNS_DELTA` 必须有 `AFTER_SWAP`;③ 有 `AFTER_ADD_LIQUIDITY_RETURNS_DELTA` 必须有 `AFTER_ADD_LIQUIDITY`;④ 有 `AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA` 必须有 `AFTER_REMOVE_LIQUIDITY`;⑤ hooks 为零地址时 fee 不能是动态费;⑥ hooks 非零时,要么低 14 位至少有一位为 1,要么 fee 是动态费。不满足则 `HookAddressNotValid(address)` | [CORE] `Hooks.sol` L109–127;`PoolManager.sol` L126 |
| `validateHookPermissions(hooks, Permissions)` | **只有 Hook 自己的构造函数调用时才生效**(`BaseHook` 的构造函数会调) | 14 个布尔值逐个与地址位比较,**必须全部相等**(多一位、少一位都 revert `HookAddressNotValid`) | [CORE] `Hooks.sol` L83–103;[HOOKS-PUB] `src/base/BaseHook.sol` L18–33;[OZ] `src/base/BaseHook.sol` L61–64、L100–102 |

要点:

- PoolManager **不检查** Hook 合约是否真的实现了地址位声明的函数。不继承 BaseHook、也不自己调 `validateHookPermissions` 的 Hook,如果地址多出一位(例如位 9 `BEFORE_REMOVE_LIQUIDITY`),PoolManager 每次撤流动性都会调一个不存在的函数 → 调用失败 → 整笔 revert(`Hooks.sol` L131–137)。推论:这种情况下池子里的流动性撤不出来。
- return-delta 标志没开时,Hook 返回的 delta 被**直接忽略**而不是报错(`Hooks.sol` L163、L266)。少挖一位不会 revert,只会让记账静默失效。
- 没有任何标志的 Hook 地址只有在动态费池里才合法(规则 ⑥)。

### 3.3 HookMiner

出处:[HOOKS-PUB] `src/utils/HookMiner.sol`(L1–57;与 [PERI] `7ebd04b1` `src/utils/HookMiner.sol` 相同)。

- 签名:`HookMiner.find(address deployer, uint160 flags, bytes memory creationCode, bytes memory constructorArgs) internal view returns (address hookAddress, bytes32 salt)`。
- 行为:`flags & 0x3FFF` 后,从 salt = 0 递增到 `MAX_LOOP = 160_444`,找第一个"低 14 位**等于** flags 且该地址当前无代码"的 CREATE2 地址;找不到则 `revert("HookMiner: could not find salt")`。
- 地址公式:`keccak256(0xFF ++ deployer ++ salt ++ keccak256(creationCode ++ constructorArgs))[12:]`(L48–56)。
- `deployer` 取值(L17–18 注释):`forge test` 里是测试合约 `address(this)` 或被 prank 的地址;`forge script` 里是 `0x4e59b44847b379578588920cA78FbF26c0B4956C`。部署写法 `new Hook{salt: salt}(args)`。
- 另有 `HookMinerCreate3.sol`、`PrefacedHookMiner.sol`(未细读,见 §10-6)。
- 本地测试可不挖矿:[DOC-DEPLOY-HOOK] 写明可用 Foundry 的 `deployCodeTo` 把 Hook 放到任意地址。

推论(由公式得出,官方没有逐条写):

1. 地址取决于 `creationCode` 和构造参数,任何会改变字节码的东西(编译器版本、优化参数、`bytecode_hash`、构造参数里的 PoolManager 地址)都会让地址变掉、需要重挖。主网和 Sepolia 的 PoolManager 地址不同,所以两条链上同一个 Hook 的地址必然不同。
2. 经 `0x4e59…956C` 部署时,Hook 构造函数里的 `msg.sender` 是这个代理而不是部署者的钱包;任何人拿到同样的 initcode + salt 都能替你把同一个合约部署到同一个地址。构造函数里依赖 `msg.sender` 的设计(例如把 owner 设为 `msg.sender`)在这种部署方式下不成立。
3. 平均约 2^14 = 16,384 次尝试命中一个指定的 14 位图案(概率估算,不是源码事实)。

---

## 4. 回调

### 4.1 签名与选择器

出处:[CORE] `interfaces/IHooks.sol`(行号见表);结构体见 `types/PoolKey.sol` L11–22、`types/PoolOperation.sol` L8–26。选择器是我用 `cast sig` 算的。

```
struct PoolKey { Currency currency0; Currency currency1; uint24 fee; int24 tickSpacing; IHooks hooks; }
struct ModifyLiquidityParams { int24 tickLower; int24 tickUpper; int256 liquidityDelta; bytes32 salt; }
struct SwapParams { bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96; }
// amountSpecified < 0 = exactIn(指定输入量),> 0 = exactOut(指定输出量)   [PoolOperation.sol L22]
```

| # | 签名(均为 `external`) | 返回 | 选择器 | IHooks.sol |
|---|---|---|---|---|
| 1 | `beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)` | `bytes4` | `0xdc98354e` | L21 |
| 2 | `afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)` | `bytes4` | `0x6fe7e6eb` | L29–31 |
| 3 | `beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata hookData)` | `bytes4` | `0x259982e5` | L39–44 |
| 4 | `afterAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata params, BalanceDelta delta, BalanceDelta feesAccrued, bytes calldata hookData)` | `(bytes4, BalanceDelta)` | `0x9f063efc` | L55–62 |
| 5 | `beforeRemoveLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata hookData)` | `bytes4` | `0x21d0ee70` | L70–75 |
| 6 | `afterRemoveLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata params, BalanceDelta delta, BalanceDelta feesAccrued, bytes calldata hookData)` | `(bytes4, BalanceDelta)` | `0x6c2bbe7e` | L86–93 |
| 7 | `beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)` | `(bytes4, BeforeSwapDelta, uint24)` | `0x575e24b4` | L103–105 |
| 8 | `afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata hookData)` | `(bytes4, int128)` | `0xb47b2fb1` | L115–121 |
| 9 | `beforeDonate(address sender, PoolKey calldata key, uint256 amount0, uint256 amount1, bytes calldata hookData)` | `bytes4` | `0xb6a8b0fa` | L130–136 |
| 10 | `afterDonate(address sender, PoolKey calldata key, uint256 amount0, uint256 amount1, bytes calldata hookData)` | `bytes4` | `0xe1b4af69` | L145–151 |

没有单独的"return delta 版"函数:同一个函数,返回值是否被采用由地址上的 4 个 return-delta 位决定(§3.1)。

### 4.2 返回值的校验规则

出处:[CORE] `Hooks.sol`。

| 规则 | 行号 |
|---|---|
| 调用失败(Hook revert 或函数不存在)→ PoolManager 用 ERC-7751 的 `WrappedError(target, selector, reason, details)` 包一层再 revert,附加上下文 `HookCallFailed` | L131–137;`CustomRevert.sol` L11、L83 起 |
| 返回数据长度 < 32,或第一个字不等于被调函数的选择器 → `InvalidHookResponse` | L151–154 |
| `beforeSwap` 的返回数据长度必须**正好 96 字节**,否则 `InvalidHookResponse` | L258–259 |
| 开了 return-delta 位的 `afterSwap` / `afterAddLiquidity` / `afterRemoveLiquidity`,返回数据长度必须**正好 64 字节** | L165–166 |
| 没开对应 return-delta 位:返回的 delta 一律当 0 | L163(after 系列)、L266(beforeSwap) |
| `beforeSwap` 第三个返回值(费率)只在 `key.fee` 是动态费时才被读取 | L263 |

### 4.3 调用时机(相对于池子状态更新)

出处:[CORE] `PoolManager.sol`。

**initialize(L117–142)**:① 检查 tickSpacing、币种顺序、`isValidHookAddress`(L119–126)→ ② `beforeInitialize`(L130)→ ③ 写入池子初始状态(L134;"池子已初始化"的检查在这一步里,`Pool.sol` L101)→ ④ 发 `Initialize` 事件(L139)→ ⑤ `afterInitialize`(L141)。`initialize` **不需要 unlock**,任何地址可调(L117 没有 `onlyWhenUnlocked`,也没有权限检查)。

**modifyLiquidity(L145–184)**:① `checkPoolInitialized`(L154)→ ② `beforeAddLiquidity` 或 `beforeRemoveLiquidity`(L156)→ ③ 更新 tick / 头寸 / 池内流动性,算出本金 delta 与 `feesAccrued`(L159–171)→ ④ 发 `ModifyLiquidity` 事件(L175)→ ⑤ `afterAddLiquidity` 或 `afterRemoveLiquidity`(L178)→ ⑥ 把 hookDelta 记到 Hook、把 callerDelta 记到调用方(L181–183)。即 after 回调执行时**池子状态已更新,但调用方和 Hook 的 delta 还没入账**。

- 分支判定:`liquidityDelta > 0` 走 add;**`liquidityDelta <= 0` 走 remove**(`Hooks.sol` L201–205、L220–244)。所以 `liquidityDelta == 0` 的"poke"(只收手续费)触发的是 **remove** 这一对回调。
- 传给 after 回调的 `delta` = 本金 + 手续费(`PoolManager.sol` L171、L178),**不含** Hook 自己的 delta。`IHooks.sol` L50 / L81 的注释写的是"the sum of principal delta, fees accrued, and hook delta",与代码在调用时点的实际值不一致;以代码为准。
- `feesAccrued` 可以被人为抬高:[CORE] `IPoolManager.sol` L130–132 写明单头寸池里可以"自己捐给自己"来虚增,同一次 unlock 里先 donate 再收费会更极端。不要拿它当可信输入。

**swap(L187–227)**:① `amountSpecified == 0` 则 revert(L193)→ ② `checkPoolInitialized`(L196)→ ③ `beforeSwap`(L202),此时 slot0 仍是**成交前**的价格 → ④ 执行撮合:更新 sqrtPrice / tick / 流动性 / feeGrowth、计协议费(L206–217、L230–253;`Pool.sol` L279–463)→ ⑤ 发 `Swap` 事件(L241–250)→ ⑥ `afterSwap`(L221),此时 slot0 已是**成交后**的价格 → ⑦ 把 hookDelta 记到 Hook、把 swapDelta 记到调用方(L224–226)。

- 传给 `afterSwap` 的 `delta` 是池子撮合本身的结果(L206、L221),不含 Hook 的 delta。
- 传给 `afterSwap` 的 `params` 是调用方原始的 `SwapParams`,不是被 `beforeSwap` 改过的 `amountToSwap`(L221 传 `params`)。

**donate(L256–276)**:① `checkPoolInitialized` → ② `beforeDonate`(L266)→ ③ 更新 feeGrowthGlobal(L268)→ ④ 把 delta 记到调用方(L270)→ ⑤ 发 `Donate` 事件(L273)→ ⑥ `afterDonate`(L275)。当前在区间内的流动性为 0 时 `donate` 直接 revert `NoLiquidityToReceiveFees`(`Pool.sol` L466–468)。

**事件签名(topic0,`cast keccak` 计算)**,出处 [CORE] `IPoolManager.sol` L60–107:

| 事件 | topic0 |
|---|---|
| `Initialize(bytes32 indexed id, address indexed currency0, address indexed currency1, uint24 fee, int24 tickSpacing, address hooks, uint160 sqrtPriceX96, int24 tick)` | `0xdd466e674ea557f56295e2d0218a125ea4b4f0f6f3307b95f85e6110838d6438` |
| `Swap(bytes32 indexed id, address indexed sender, int128 amount0, int128 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick, uint24 fee)` | `0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f` |
| `ModifyLiquidity(bytes32 indexed id, address indexed sender, int24 tickLower, int24 tickUpper, int256 liquidityDelta, bytes32 salt)` | `0xf208f4912782fd25c7f114ca3723a2d5dd6f3bcc3ac8db5af63baa85f711d5ec` |
| `Donate(bytes32 indexed id, address indexed sender, uint256 amount0, uint256 amount1)` | `0x29ef05caaff9404b7cb6d1c0e9bbae9eaa7ab2541feba1a9c4248594c08156cb` |

`Swap` 事件里的 `fee` 是 LP 费与协议费合成后的总费率(`PoolManager.sol` L249;`Pool.sol` L307),不是单独的 LP 费。事件里不带 Hook 的 delta。

### 4.4 `sender` 是谁

- 源码:每个回调的第一个参数都是 `msg.sender`——即**调用 PoolManager 那个函数的合约**(`Hooks.sol` L180、L190、L202、L204、L225、L237、L256、L300、L323、L333)。`IHooks.sol` 的注释写 "The initial msg.sender for the swap call"(L96、L108 等),指的也是对 PoolManager 而言的 `msg.sender`。
- [DOC-SENDER] 原文:"the `sender` parameter passed to `beforeSwap()` represents the caller of `PoolManager.swap()`. This is typically a router contract";Hook 里的 `msg.sender` "is always the PoolManager contract"。
- 所以:经 Universal Router 兑换时 `sender` = Universal Router;经 PositionManager 做市时 `sender` = PositionManager;报价时 `sender` = Quoter。**都不是最终用户。**
- 官方给的取最终用户的办法([DOC-SENDER]):Hook 维护一份可信路由名单,对名单内的 `sender` 调 `IMsgSender(sender).msgSender()`。接口定义在 [PERI] `src/interfaces/IMsgSender.sol` L6–13。
  - [链上] Base 主网的 Universal Router(`0x6ff5…9b43`、`0xd614…9c40`)、PositionManager、Quoter 都能调通 `msgSender()`(交易之外读到的是零地址)。
  - 不在名单里的路由可以返回任意地址;`hookData` 也是调用方随便填的。这两者都不能当身份凭证(推论)。
- 头寸归属:PoolManager 里头寸的 owner 是 `msg.sender`(`PoolManager.sol` L161),键是 `keccak256(owner, tickLower, tickUpper, salt)`([CORE] `libraries/Position.sol` L48–60)。经 PositionManager 建的头寸,owner 都是 PositionManager,`salt = bytes32(tokenId)`([PERI] `src/PositionManager.sol` L298–300、L346–348、L442)。推论:Hook 想按"头寸"记状态,用 `(sender, tickLower, tickUpper, salt)`;经 PositionManager 的头寸对应一张可转让的 NFT,最终持有人会变。

### 4.5 Hook 自己发起的操作不触发自身回调

出处:[CORE] `Hooks.sol`。判定条件都是 **`msg.sender == address(hook)`**,即"调用 PoolManager 的就是这个池子的 Hook 本身"。

| 操作 | 被跳过的回调 | 行号 |
|---|---|---|
| Hook 调 `initialize` | `beforeInitialize`、`afterInitialize` | `noSelfCall` 修饰符 L171–175;用在 L178、L187 |
| Hook 调 `modifyLiquidity` | before/after × add/remove 四个;after 直接返回 `(delta, 0)` | L200(`noSelfCall`)、L217 |
| Hook 调 `swap` | `beforeSwap`、`afterSwap`;返回零 delta、`lpFeeOverride = 0` | L253、L293 |
| Hook 调 `donate` | `beforeDonate`、`afterDonate` | L320、L330 |

含义:

- 只跳过**自己**的回调。Hook A 去操作挂着 Hook B 的池子,B 的回调照常触发。
- Hook 在自己池子里发起的 swap 不经过自己的 `beforeSwap`,因此拿不到"每笔覆盖"的费率,按 slot0 里存的 LP 费成交;动态费池如果从没调过 `updateDynamicLPFee`,存的就是 0(§5)。
- 官方实例:[HOOKS-PUB] `src/base/BaseDynamicFeeHook.sol` 的注释写明 "afterInitialize never runs today: initializePool self-calls, and v4 skips callbacks on self-calls"。

---

## 5. 动态手续费

### 5.1 常量

出处:[CORE] `libraries/LPFeeLibrary.sol`。

| 常量 | 值 | 含义 | 行号 |
|---|---|---|---|
| `DYNAMIC_FEE_FLAG` | `0x800000` | `PoolKey.fee` **正好等于**这个值才是动态费池(`isDynamicFee` 用 `==`) | L15、L30–32 |
| `OVERRIDE_FEE_FLAG` | `0x400000` | `beforeSwap` 返回的 uint24 里带这一位,才表示"本笔覆盖费率" | L19、L61–63 |
| `REMOVE_OVERRIDE_MASK` | `0xBFFFFF` | 去掉覆盖位 | L22、L68–70 |
| `MAX_LP_FEE` | `1000000` | 单位是百分之一基点(pip),1,000,000 = 100% | L25、L37–39 |

- 动态费池的初始 LP 费是 **0**(L51–56)。L48 注释:想要非零初始费率,应在 `afterInitialize` 里调 `updateDynamicLPFee`。
- 是否动态费在建池时由 `PoolKey.fee` 决定,之后不可改([DOC-DYNFEE]:"determined at pool creation and is immutable");`fee` 是 PoolKey 的一部分,换一个值就是另一个池(`PoolKey.sol` L16–17)。
- 静态费池的 `fee` 必须 ≤ 1,000,000,否则建池 revert `LPFeeTooLarge`(L43–45、L54)。

### 5.2 两种改费方式

| | `poolManager.updateDynamicLPFee(key, newFee)` | `beforeSwap` 返回 `fee \| OVERRIDE_FEE_FLAG` |
|---|---|---|
| 谁能用 | **只有 `key.hooks` 这个地址**,且 `key.fee` 必须是动态费;否则 `UnauthorizedDynamicLPFeeUpdate` | 地址带 `BEFORE_SWAP_FLAG` 的 Hook,且池子是动态费 |
| 是否需要 unlock | 不需要,任何时刻可调(包括在任意回调里,或由 Hook 的外部函数触发) | —(在 swap 流程内) |
| 是否持久 | **写入 slot0**,之后所有 swap 都用它,直到下次更新 | **只对这一笔生效,不写 slot0**;`getSlot0` 读到的 lpFee 不变 |
| 上限 | `newFee > 1_000_000` → `LPFeeTooLarge` | 带了覆盖位而去位后 > 1,000,000 → `LPFeeTooLarge`(整笔 swap revert) |
| 不带覆盖位时 | — | 返回值被**静默忽略**,用 slot0 里存的费率 |
| 静态费池 | 调用即 revert | 返回值根本不被读取 |
| 出处 | [CORE] `PoolManager.sol` L339–346;`Pool.sol` L115–118;`IPoolManager.sol` L111 | [CORE] `Hooks.sol` L261–263;`Pool.sol` L300–305(覆盖值只进局部变量)、L439(回写 slot0 时只改 tick 和价格);`LPFeeLibrary.sol` L75–78 |

- 两种方式可以并用(例如 `afterInitialize` 里设一个基础费率,`beforeSwap` 再按笔覆盖)。[DOC-DYNFEE] 把两者分别称为 "Periodic Updates via PoolManager" 和 "Per-Swap Updates via beforeSwap Hook";该页的示意图画的是"在 beforeSwap 里调 updateDynamicLPFee",那是第三种组合,不是唯一做法。
- 报价:Quoter 是通过实际走一遍 swap 再 revert 来报价的,`sender` 是 Quoter 合约(见 §4.4)。按 `sender` 或 `hookData` 区别定价的 Hook,报价与实际成交会不一致(推论)。

### 5.3 100% 费率的边界

总费率(LP 费与协议费合成后)≥ 1,000,000 时,**exactOut 的 swap 直接 revert `InvalidFeeForExactOut`**;exactIn 仍可执行(输入全部变成手续费)。出处:[CORE] `Pool.sol` L310–316;`SwapMath.sol` L12(`MAX_SWAP_FEE = 1e6`)。

### 5.4 协议费与 LP 费

出处:[CORE] `ProtocolFees.sol`、`libraries/ProtocolFeeLibrary.sol`、`Pool.sol`、`types/Slot0.sol`。

| 事实 | 行号 |
|---|---|
| 协议费按池、按方向设置:一个 uint24 里低 12 位是 0→1 方向,高 12 位是 1→0 方向;每个方向上限 `MAX_PROTOCOL_FEE = 1000` pip(0.1%) | `ProtocolFeeLibrary.sol` L8、L17–23;`Slot0.sol` 布局注释 |
| 只有 `protocolFeeController` 能调 `setProtocolFee(key, newProtocolFee)`;controller 由 PoolManager 的 owner 设置。**Hook 无权设置,也拦不住** | `ProtocolFees.sol` L29–41 |
| 新建池的协议费初始为 0 | `Pool.sol` L105–106 |
| 先从输入里扣协议费,再对剩余部分收 LP 费。合成公式:`swapFee = protocolFee + lpFee − protocolFee × lpFee / 1_000_000`(除法向下取整,所以 swapFee 是向上取整的) | `ProtocolFeeLibrary.sol` L34–46;`Pool.sol` L307 |
| 每一步里协议费金额 = `(amountIn + feeAmount) × protocolFee / 1_000_000`,**向下取整**(注释:"this rounds down to favor LPs over the protocol");LP 费为 0 时整步手续费都归协议 | `Pool.sol` L384–397 |
| 协议费记在**输入币**上,累计到 `protocolFeesAccrued[currency]`,由 controller 用 `collectProtocolFees` 提走 | `PoolManager.sol` L237–238;`ProtocolFees.sol` L44–57、L66–70 |
| Hook 用 `beforeSwap` 覆盖的只是 LP 费;协议费照常叠加 | `Pool.sol` L303–307 |

- [链上] Base 主网 PoolManager 的 `protocolFeeController` 非零(§1.1),Base Sepolia 为零。具体哪些 Base 池子已被设了协议费,我没有逐池读(§10-4)。
- 推论:Hook 设的 LP 费上限如果想让"用户实付总费率"不超过某个值,要把最多 0.1% 的协议费算进去;被 `BeforeSwapDelta` 截走、没有进入撮合的那部分数量不产生 LP 费和协议费(因为费用只在 `Pool.swap` 的循环里按实际撮合量计,`Pool.sol` L362–397)。

---

## 6. Flash accounting 与 return delta

### 6.1 delta 的符号与存放

- delta 按 `(地址, 币种)` 存在 PoolManager 的 **transient storage** 里,槽位 = `keccak256(target, currency)`。出处:[CORE] `libraries/CurrencyDelta.sol` L10–15、L28–41。
- 符号(由下面各函数的实现反推,并与 `IHooks.sol` L54、L101、L114 的注释一致):**正数 = PoolManager 欠该地址(该地址可以取走);负数 = 该地址欠 PoolManager(必须补上)**。
- 全局计数器 `NonzeroDeltaCount` 记录有多少个 `(地址, 币种)` 的 delta 不为 0:从 0 变非 0 加一,变回 0 减一。出处:[CORE] `PoolManager.sol` L368–378;`libraries/NonzeroDeltaCount.sol`。

### 6.2 各函数的规则

出处:[CORE] `PoolManager.sol`(行号见表);接口注释在 `interfaces/IPoolManager.sol` L109–216。

| 函数 | 需要 unlock | 对调用方 delta 的影响 | 其他规则 | 行号 |
|---|---|---|---|---|
| `unlock(bytes data)` | — | — | 已解锁时再调 → `AlreadyUnlocked`;回调 `IUnlockCallback(msg.sender).unlockCallback(data)`;回调返回后 `NonzeroDeltaCount != 0` → **`CurrencyNotSettled`**,整笔 revert | L104–114 |
| `swap` / `modifyLiquidity` / `donate` | 是(`ManagerLocked`) | 结果 delta 记到 `msg.sender`(和 Hook) | 见 §4.3 | L145–276 |
| `take(currency, to, amount)` | 是 | **−amount** | 立刻把币转给 `to`;可当免费闪电贷用(`IPoolManager.sol` L174–175) | L291–297 |
| `sync(currency)` | **否** | 无 | ERC20:把 PoolManager 当前余额和币种写进 transient 槽;原生币(零地址):只把"已同步币种"清零 | L279–288 |
| `settle()` payable | 是 | **+paid** | "已同步币种"为零地址时 `paid = msg.value`;否则 `msg.value` 必须为 0(`NonzeroNativeValue`),`paid = 当前余额 − sync 时记下的余额`,然后清掉已同步币种 | L300–302、L349–365 |
| `settleFor(recipient)` payable | 是 | 给 **recipient** +paid | 同上,替别人还 | L305–307 |
| `mint(to, id, amount)` | 是 | **−amount** | 给 `to` 铸 ERC-6909 凭证;`id` 取低 160 位当币种地址 | L322–329 |
| `burn(from, id, amount)` | 是 | **+amount** | 烧 `from` 的凭证;`from != msg.sender` 时需要是 operator 或有足够 allowance(`type(uint256).max` 的 allowance 不扣减) | L332–336;`ERC6909Claims.sol` L13–22 |
| `clear(currency, amount)` | 是 | −amount | `amount` 必须**正好等于**调用方当前的正 delta,否则 `MustClearExactPositiveDelta`;被 clear 的币永久留在合约里拿不回来 | L310–319;`IPoolManager.sol` L190–193 |
| `initialize`、`updateDynamicLPFee` | 否 | 无 | "The only functions callable without an unlocking are `initialize` and `updateDynamicLPFee`"(注释没提 `sync`,但 `sync` 实际上也不需要 unlock) | `IPoolManager.sol` L111;`PoolManager.sol` L117、L279、L339 |

**ERC20 的标准还款顺序**(`IPoolManager.sol` L165–171 写明 sync "MUST be called before any ERC20 tokens are sent into the contract"):`sync(currency)` → 把币转进 PoolManager → `settle()`。原生币可以跳过 sync 直接 `settle{value: x}()`,但 `PoolManager.sol` L348 的注释建议原生币也先 sync 以避免 DoS;如果之前 sync 过某个 ERC20 还没 settle,要先 `sync(零地址)` 才能用原生币 settle。

**"已同步币种"只有一个全局槽位**([CORE] `libraries/CurrencyReserves.sol` L10–31),由此得出(推论):

- 连续 sync 两个币种,后一个覆盖前一个;sync 与 settle 必须成对、中间不要插入对同一币种的其他进出。
- sync 之后、settle 之前,如果 PoolManager 该币余额减少(例如有人 `take` 走同一币种),`paid = reservesNow − reservesBefore` 是普通减法,会下溢 revert(`PoolManager.sol` L360)。
- 协议费提取在该币种处于已同步状态时会 revert `ProtocolFeeCurrencySynced`(`ProtocolFees.sol` L49–52)。

**ERC-6909 凭证**:

- 币种与 id 的换算:`toId = uint160(currency 地址)`;`fromId` 只取低 160 位,高 96 位被丢弃,两者不是互逆。出处:[CORE] `types/Currency.sol` L110–118。原生币的 id 是 0。
- 凭证是**持久存储**(普通 ERC-6909 余额),不随交易结束清零;delta 是 transient 的。Hook 代持资金用 `mint` 把正 delta 变成凭证留在 PoolManager 里,之后在某次 unlock 中 `burn` 换回正 delta 再 `take` 或抵扣(推论,由 L322–336 的符号得出)。
- 费率类 Hook 的官方参考实现用的是直接 `take`([CORE] `src/test/FeeTakingHook.sol` L49);OZ 的 `BaseHookFee` 注释写的是 "taken as ERC-6909 claims"([OZ] `src/fee/BaseHookFee.sol` L61)。两种都合法。

**Hook 何时需要自己 unlock**:

- 回调是在别人的 `unlock` 期间被调用的,此时 PoolManager 处于解锁状态,Hook 可以直接调 `take` / `settle` / `mint` / `burn` / `swap` / `modifyLiquidity` / `donate`,**不能**再调 `unlock`(会 `AlreadyUnlocked`,L105)。
- 回调之外(例如用户直接调 Hook 的"下单 / 撤单 / 领取"函数),Hook 要自己调 `unlock` 并实现 `unlockCallback`;该回调必须校验调用方是 PoolManager。参考:[PERI] `src/base/SafeCallback.sol` L10–21、`src/base/ImmutableState.sol` L16–20。
- Hook 的 delta 与用户的 delta 共用同一个 `NonzeroDeltaCount`。Hook 在回调里留下任何未清零的 delta,用户这笔交易会在 unlock 结尾 `CurrencyNotSettled`(L112)。清零的时点是**最外层 unlock 结束前**,不是每个回调结束时。

### 6.3 `BeforeSwapDelta`(需要 `BEFORE_SWAP_RETURNS_DELTA_FLAG`)

**编码**,出处 [CORE] `types/BeforeSwapDelta.sol`:

- `type BeforeSwapDelta is int256;` **高 128 位 = specified 币种的 delta,低 128 位 = unspecified 币种的 delta**(L4–6)。
- 构造:`toBeforeSwapDelta(int128 deltaSpecified, int128 deltaUnspecified)`(L9–16);取值:`getSpecifiedDelta`(L25–29)、`getUnspecifiedDelta`(L33–37)。

**符号**,出处 [CORE] `IHooks.sol` L101:"Positive: the hook is owed/took currency, negative: the hook owes/sent currency"。即两个分量都是 **Hook 自己的 delta**:正 = Hook 拿走,负 = Hook 付出。

**PoolManager 怎么用它**,出处 [CORE] `Hooks.sol`:

1. `amountToSwap = params.amountSpecified + hookDeltaSpecified`(L252、L273–275)。
2. 如果这使得成交方向翻转(原本 exactIn 即 `amountSpecified < 0`,加完后 `> 0`;或原本 exactOut,加完后 `< 0`)→ revert **`HookDeltaExceedsSwapAmount`**(L274–278)。正好等于 0 是允许的:`Pool.swap` 对 0 数量直接返回零 delta、不动价格(`Pool.sol` L318–320),这就是 [SEC] 说的 "NoOp swap"。
3. unspecified 分量在 `beforeSwap` 阶段不处理,留到 `afterSwap` 阶段与 `afterSwap` 的返回值相加(L269 注释、L295–303)。**即使 Hook 没有 `AFTER_SWAP_FLAG`,这一步仍然执行**(L295–313 不在 `if (hasPermission(AFTER_SWAP_FLAG))` 里面)。
4. 组装成按 token0/token1 排列的 `hookDelta`(L305–309):
   `(params.amountSpecified < 0) == params.zeroForOne` 为真 → `hookDelta = (specified, unspecified)`,否则 `(unspecified, specified)`。
5. `swapDelta = swapDelta − hookDelta`(L311–312,注释:"the caller has to pay for (or receive) the hook's delta");`hookDelta` 记到 Hook 地址名下(`PoolManager.sol` L224)。

**specified / unspecified 对应哪个币**(由上面第 4 步和 `SwapParams` 的定义逐格推出):

| 方向 | 类型 | `amountSpecified` | specified 币种 | unspecified 币种 |
|---|---|---|---|---|
| zeroForOne(卖 0 买 1) | exactIn | `< 0` | **currency0(输入)** | currency1(输出) |
| zeroForOne | exactOut | `> 0` | **currency1(输出)** | currency0(输入) |
| oneForZero(卖 1 买 0) | exactIn | `< 0` | **currency1(输入)** | currency0(输出) |
| oneForZero | exactOut | `> 0` | **currency0(输出)** | currency1(输入) |

规律:exactIn 时 specified = 输入币,exactOut 时 specified = 输出币;unspecified 永远是另一个。判断"specified 是不是 token0"的官方写法:`(params.amountSpecified < 0 == params.zeroForOne)`([CORE] `src/test/FeeTakingHook.sol` L42;`Hooks.sol` L307)。

**两个分量在四种情形下的含义**(X、Y 为正数):

| 情形 | `deltaSpecified = +X` | `deltaSpecified = −X` | `deltaUnspecified = +Y` | `deltaUnspecified = −Y` |
|---|---|---|---|---|
| exactIn(specified = 输入币) | Hook 拿走 X 输入币;进入撮合的输入量减少 X(X 不得超过输入量) | Hook 补贴 X 输入币;进入撮合的输入量增加 X | Hook 拿走 Y 输出币;用户到手的输出减少 Y | Hook 额外付出 Y 输出币;用户到手的输出增加 Y |
| exactOut(specified = 输出币) | Hook 拿走 X 输出币;需要从池子撮合出的输出量**增加** X | Hook 付出 X 输出币;需要撮合的输出量减少 X(X 不得超过输出量) | Hook 拿走 Y 输入币;用户要付的输入增加 Y | Hook 补贴 Y 输入币;用户要付的输入减少 Y |

官方参考实现(1:1 自定义曲线,把整笔成交接管):先 `manager.take(inputCurrency, hook, amount)`、再向 PoolManager 结清 `amount` 的输出币,然后返回 `toBeforeSwapDelta(int128(-params.amountSpecified), int128(params.amountSpecified))`。出处:[CORE] `src/test/CustomCurveHook.sol` L33–49。把它代入上表:exactIn 时 `amountSpecified = −A`,返回 `(+A, −A)` = 拿走 A 输入、付出 A 输出;exactOut 时 `amountSpecified = +A`,返回 `(−A, +A)` = 付出 A 输出、拿走 A 输入。两种情形 `amountToSwap` 都变成 0。

**返回值只是"声明",不是"转账"**:PoolManager 只是把返回的数记到 Hook 的 delta 上(`PoolManager.sol` L224)。Hook 必须自己用 `take` / `mint`(拿)或 `sync`+转账+`settle` / `burn`(付)产生大小相等、方向相反的 delta 把它抵消,否则 unlock 结尾 `CurrencyNotSettled`。例:Hook 先 `take` 了 X(delta = −X),再返回 +X,两者相加为 0。

### 6.4 `afterSwap` 返回的 `int128`(需要 `AFTER_SWAP_RETURNS_DELTA_FLAG`)

- 币种:**unspecified 币种**(按 §6.3 的表查)。出处:[CORE] `IHooks.sol` L114("The hook's delta in unspecified currency");`Hooks.sol` L299–302、L307–309。
- 符号:同上,正 = Hook 拿走,负 = Hook 付出。
- 与 `beforeSwap` 的 unspecified 分量**相加**后一起入账(L296、L299–302),和用 `toInt128()` 做了溢出检查。
- 没有 `AFTER_SWAP_RETURNS_DELTA_FLAG` 时返回值被当 0(L163、L301)。
- `afterSwap` **改不了 specified 币种**的数量。
- 官方参考实现(对 unspecified 币收费):`manager.take(feeCurrency, hook, feeAmount)` 后 `return (selector, feeAmount.toInt128())`。出处:[CORE] `src/test/FeeTakingHook.sol` L34–52。其中 exactIn 时 unspecified 是输出币、`delta` 里对应分量为正;exactOut 时是输入币、分量为负,参考实现用取绝对值处理(L46)。

### 6.5 `afterAddLiquidity` / `afterRemoveLiquidity` 返回的 `BalanceDelta`

- 编码:`type BalanceDelta is int256`,**高 128 位 = amount0,低 128 位 = amount1**。出处:[CORE] `types/BalanceDelta.sol` L6–8、L14–18、L61–71。
- 符号:正 = Hook 拿走,负 = Hook 付出(`IHooks.sol` L54、L85)。
- 入账:`callerDelta = callerDelta − hookDelta`(`Hooks.sol` L230、L242),`hookDelta` 记到 Hook(`PoolManager.sol` L181)。
- 传入的 `delta` 的符号:加流动性时两个分量 ≤ 0(调用方欠池子),撤流动性时 ≥ 0(池子欠调用方);官方参考实现对此做了 `assert`([CORE] `src/test/FeeTakingHook.sol` L62、L81)。
- 没有 `beforeAddLiquidity` / `beforeRemoveLiquidity` 的 return delta;before 系列只能放行或 revert。

### 6.6 这几条规则对集成方的影响

`IPoolManager.sol` L142–144 的注释:带 `BEFORE_SWAP_RETURNS_DELTA_FLAG` 或 `AFTER_SWAP_RETURNS_DELTA_FLAG` 的 Hook "may alter the swap input/output. Integrators should perform checks on the returned swapDelta."。即 `swap` 返回的 `swapDelta` 已经扣过 Hook 的 delta,与 `Swap` 事件里的 `amount0/amount1`(池子撮合量)可以不同。

---

## 7. 许可证(只陈述条款)

| 仓库 | 许可证 | 出处 |
|---|---|---|
| v4-core | **按文件区分**:README 写 "licensed under the Business Source License 1.1 (`BUSL-1.1`) … and the MIT License (`MIT`) … Each file in Uniswap V4 Core states the applicable license type in the header";`package.json` 的 `license` 字段是 `BUSL-1.1` | [CORE] `README.md` "License";`licenses/BUSL_LICENSE`、`licenses/MIT_LICENSE` |
| v4-periphery | MIT(`LICENSE`;`src/` 下 69 个文件的 SPDX 头全是 MIT) | [PERI] `LICENSE` |
| v4-hooks-public | MIT(`LICENSE`,版权 2026 Universal Navigation Inc.);`src/` 下 67 个文件 MIT,另有 `aggregator-hooks/ProtocolFees.sol` 和 `interfaces/IWstETH.sol` 两个文件标的是 AGPL-3.0-only / GPL-3.0(我没有逐一对应哪个是哪个) | [HOOKS-PUB] |
| OpenZeppelin uniswap-hooks | MIT(版权 2016–2026 Zeppelin Group Ltd);README 另称使用受 openzeppelin.com/tos 约束 | [OZ] `LICENSE`、`README.md` |
| v4-template | MIT(版权 2023 saucepoint) | [TEMPLATE] `LICENSE` |
| universal-router | GPL-3.0(GitHub 仓库元数据) | GitHub API |

**v4-core 里哪些文件是 BUSL-1.1**(`src/` 下 SPDX 头统计:MIT 40、UNLICENSED 35(都在 `src/test`)、BUSL-1.1 8、GPL-3.0-or-later 1):

- `src/PoolManager.sol`
- `src/libraries/Pool.sol`、`Position.sol`、`Lock.sol`、`CurrencyDelta.sol`、`CurrencyReserves.sol`、`NonzeroDeltaCount.sol`
- `src/test/ProxyPoolManager.sol`
- (`src/test/NativeERC20.sol` 是 GPL-3.0-or-later)

**Hook 通常要 import 的文件都是 MIT**:`interfaces/IHooks.sol`、`interfaces/IPoolManager.sol`、`libraries/Hooks.sol`、`LPFeeLibrary.sol`、`StateLibrary.sol`、`TransientStateLibrary.sol`、`TickMath.sol`、`types/*`(依据:对 `src/` 全量 grep SPDX 头,BUSL 文件只有上面列的 8 个,`UNLICENSED` 的 35 个全在 `src/test`,其余非测试文件都是 MIT)。

**BUSL 的参数**(出处 [CORE] `licenses/BUSL_LICENSE`):

- Licensor:Universal Navigation Inc.;Licensed Work:Uniswap V4 Core。
- Additional Use Grant:"Any uses listed and defined at v4-core-license-grants.uniswap.eth"。
- **Change Date:"The earlier of 2027-06-15 or a date specified at v4-core-license-date.uniswap.eth"**;Change License:MIT。
- 条款正文:"The Licensor hereby grants you the right to copy, modify, create derivative works, redistribute, and make **non-production use** of the Licensed Work. The Licensor may make an Additional Use Grant, above, permitting limited production use."
- "All copies of the original and modified Licensed Work, and derivative works of the Licensed Work, are subject to this License."
- "You must conspicuously display this License on each original or modified copy of the Licensed Work."
- 末尾 Notice:"The Business Source License … is not an Open Source license."

**与"开源自己写的 Hook、接定制单"相关的事实**(不是法律结论):

1. 自己写的 Hook 合约如果只 import MIT 文件、调用链上已部署的 PoolManager,其源码里不包含 BUSL 文件。MIT 的条件是保留版权声明和许可文本。
2. 仓库里如果**拷贝或子模块引入**了 BUSL 文件(例如测试用 v4-core 的 `Deployers.sol` 从源码部署 `PoolManager`),这些文件本身仍受 BUSL 约束;BUSL 明文允许的是 "non-production use"。把 BUSL 文件原样或修改后**用于生产部署**(例如自己部署一份 PoolManager 或其分叉)需要 Additional Use Grant 或等到 Change Date。
3. Additional Use Grant 的具体内容在 ENS 记录里,我没读到(§10-7)。
4. OZ 库是 MIT,但自述为 experimental;v1.2 以后的版本在 GitHub 上都标为预发布,且 `audits/` 下没有对应审计。
5. Bunni v2 在关停后把合约从 BUSL 改成了 MIT——[二手] 出处 The Block 2025-09-04 的报道及后续转载,我没有看到 Bunni 仓库的 LICENSE 变更本身。

---

## 8. 已知坑与公开事故

### 8.1 "任何人都能用同一个 Hook 地址建池"

- 事实:`PoolManager.initialize` 没有权限检查,只校验 tickSpacing、币种顺序和 `isValidHookAddress`([CORE] `PoolManager.sol` L117–126)。`PoolKey.hooks` 由建池的人填。所以**任何人可以拿任意两个代币(包括自己发的恶意代币)、任意 fee / tickSpacing,建一个挂着你这个 Hook 的新池**,你的 Hook 会收到这个池的全部回调。
- OZ 的原话:"Every pool configured with this hook passes, whichever pool it is. Hooks that serve a single pool or keep per-pool state must check the pool id themselves."([OZ] `src/base/BaseHook.sol` L77–81);"Pool initialization is permissionless, so anyone can initialize a pool that references this hook"([OZ] `src/oracles/panoptic/OracleHookWithV3Adapters.sol` L38)。
- 含义(推论):
  1. Hook 里的状态必须按 `PoolId` 分开存;用合约级的单一变量会被别的池子串改。
  2. `msg.sender == poolManager` 只证明调用来自 PoolManager,**不证明是你认可的池子**。要限定池子,得在 `beforeInitialize` 里拦(需要位 13),或维护一份登记过的 `PoolId` 名单在每个回调里查。官方 `BaseDynamicFeeHook` 用的是前一种:开 `beforeInitialize`,不是经 Hook 自己的建池入口发起的初始化一律 revert `InvalidInitializer`([HOOKS-PUB] `src/base/BaseDynamicFeeHook.sol`)。
  3. Hook 如果代持资金或用 ERC-6909 凭证,不同池子可能共用同一种币;记账要按"池 + 币"而不是只按币。
  4. 恶意池的代币可以在转账时回调、收税、拉黑。Hook 里凡是对池内代币做 `transfer` / `balanceOf` 的地方都要假设代币是敌对的([SEC] "Token-type specific hazards")。
  5. 动态费 Hook 要在初始化时检查 `key.fee.isDynamicFee()`;OZ 的 `BaseOverrideFee` 在 `afterInitialize` 里不满足就 revert `NotDynamicFee`([OZ] `src/fee/BaseOverrideFee.sol` L35–43)。否则有人能建一个静态费池挂上你的 Hook,你的费率逻辑被静默忽略(§4.2)。

### 8.2 官方文档 / 源码注释列出的注意事项

来自 [SEC](2026-11-11 抓取):

| 类别 | 要点(原文意译,括号内为该页小节名) |
|---|---|
| 记账 | delta 算错、舍入方向错、依赖两次回调之间的旧 delta;fee-on-transfer / rebasing / ERC-777 / 可暂停可冻结代币会破坏记账("Accounting & token handling failures") |
| 外部调用与重入 | 回调里任何外部调用都会重新打开执行环境;要测同池重入、**同一 Hook 的其他池**重入、外部协议状态漂移("External calls, reentrancy, and state drift") |
| return delta | 返回把用户输入吃完的 `BeforeSwapDelta` 会让集中流动性数学被跳过(NoOp swap),此时 Hook 等于自己实现了一条曲线,任何精度或余额错误直接变成错价("BeforeSwapDelta and NoOp override risks") |
| 权限位 | salt 算错会导致需要的回调没开、或多开了不想要的权限;要求在部署流程里计算并核对预期的权限位图("Permission encoding & salt grinding pitfalls") |
| 动态费 | 费率可以在看到用户交易之后被选择性抬高;可以用重入或拆分流动性操纵费率计算;要按最坏的对抗流建模("Price impacting behavior and dynamic fees") |
| 自动调参 | 要有变化速率上限、明确的时间/状态门控、单调性约束("Autonomous behavior or parameter updates") |
| 多池与路由 | 一笔交易里 Hook 可能被调用多次(多跳路由),要测跨跳的状态假设("Multi-pool and routing interactions") |
| 可升级 | "Prefer immutability";必须升级时用标准代理、多签或时间锁、校验存储布局("Upgradeability hazards") |
| 清单 | "Invariant & Integration Testing use invariant and stateful fuzz testing … to check properties such as delta conservation, fee bounds, and balance consistency across full PoolManager flows."("Security Best Practices Checklist") |

该页声明:这是自评框架,"The Uniswap Foundation does not review, audit, or certify any submissions"。

来自源码注释:

| 事实 | 出处 |
|---|---|
| `donate` 可以被 JIT 流动性抢跑分走一部分 | [CORE] `IPoolManager.sol` L150–151 |
| `donate` 捐给的是 `slot0.tick` 所在区间的 LP;在 swap 刚好停在 tick 边界的边缘情形下,`slot0.tick` 会比按价格算出的 tick 小 1,"donation calls should verify both price and tick" | [CORE] `IPoolManager.sol` L152–155;`Pool.sol` L409–412 |
| 在区间内流动性为 0 时 `donate` revert | [CORE] `Pool.sol` L466–468 |
| `feesAccrued` 可被人为抬高 | [CORE] `IPoolManager.sol` L130–132 |
| 流动性不足的池子里,实际成交量可能小于 `amountSpecified` | [CORE] `IPoolManager.sol` L142 |
| 对空头寸(流动性为 0)做 `liquidityDelta == 0` 的 poke 会 revert `CannotUpdateEmptyPosition` | [CORE] `libraries/Position.sol` L84–86 |
| afterSwap 里读到的 PoolManager 状态都是成交后的 | [OZ] `src/fee/BaseDynamicAfterFee.sol` L116 |
| Hook 用 `BeforeSwapDelta` 吃掉部分或全部成交时,预言机类 Hook 记录的池内 tick 不反映真实成交价 | [OZ] `src/oracles/panoptic/BaseOracleHook.sol` L120 起 |
| `block.number` 在某些链上不是每块加一,按块号做"每块一次"判断的 Hook 要考虑覆写 | [OZ] `src/general/AntiSandwichHook.sol` L116;`LiquidityPenaltyHook.sol` L186 |

### 8.3 对我们三个 Hook 直接相关的坑(由上面的事实推出)

1. **锁仓 / 罚金 Hook 可能堵死最后一个 LP**:罚金"捐回池子"要调 `donate`,而区间内流动性为 0 时 `donate` 会 revert。OZ 的 `LiquidityPenaltyHook` 在这种情况下主动 revert `NoLiquidityToReceiveDonation`([OZ] `src/general/LiquidityPenaltyHook.sol` L58–60、L165)——即罚金窗口内,池子里最后一份在区间内的流动性撤不出来。这与本仓库"任何情况下不得堵死撤流动性"的设计约束冲突,照搬不行。OZ 自己也注明罚金会捐给"包括撤资者自己控制的"区间内流动性(L35)。
2. **只收手续费的 poke 也走 remove 回调**(§4.3):`beforeRemoveLiquidity` 里按"撤资"处理一切调用的 Hook,会把领手续费也拦住或罚款。
3. **限价单 Hook 用 `afterSwap` 判断 tick 穿越时**,读到的是成交后的 tick;zeroForOne 方向停在边界时 `slot0.tick` 是 `tickNext − 1`(`Pool.sol` L409–432)。穿越多个 tick 的大单只触发一次 `afterSwap`。
4. **限价单 Hook 在 `afterSwap` 里替用户撤流动性**是 Hook 自己调 `modifyLiquidity`:头寸 owner 是 Hook(`PoolManager.sol` L161),不触发自己的 liquidity 回调(§4.5),产生的正 delta 记在 Hook 名下,要在同一次 unlock 里 `mint` 成凭证或 `take` 走。
5. **动态费的依据如果取自 slot0**(现价、当前 tick),同一笔交易里可以先用一笔 swap 把它推走再回来;"跨块的量"要靠 Hook 自己按块记录,PoolManager 不存历史价格(v4-core 没有内置预言机;`Slot0.sol` 布局里只有价格、tick、两种费率)。
6. **Hook 回调里 revert 会让整笔用户交易 revert**(§4.2),包括撤流动性。任何在 remove 路径上可能 revert 的外部依赖(预言机、外部合约、算术溢出)都等于一个暂停开关。

### 8.4 已公开的 v4 Hook 相关安全事故

| 时间 | 项目 / 链 | 损失 | 原因(一句话) | 出处与可信度 |
|---|---|---|---|---|
| 2025-05-28 | Cork Protocol / Ethereum | 约 3,761 wstETH(二手报道折合约 1,100–1,200 万美元) | Cork 的 Hook 的 `beforeSwap` 没有限制调用方,攻击者直接调用并传入伪造的 hookData,经闪兑路由把金库储备转走;Cork 称 v4-periphery 后来加了显式授权检查,而它用的版本没有 | **一手**:https://www.cork.tech/blog/post-mortem ;分析:https://blocksec.com/blog/cork-protocol-incident-two-independent-flaws-combine-into-one-devastating-exploit-chain |
| 2025-09-02 | Bunni v2 / Ethereum + Unichain | 约 840 万美元(一说 240 万 + 590 万) | 自定义流动性分布(Hook 接管撮合)在撤流动性时更新闲置余额的舍入方向有误,用闪电贷把池内余额压到极小后反复小额提取放大误差;之后项目关停 | [二手] https://blocksec.com/blog/bunni-incident-repeated-small-withdrawals-compound-a-rounding-error-into-an-8.4m-drain ;https://www.theblock.co/post/369564/bunni-smart-contract-rounding-error ;[SEC] 也引用了它。Bunni 自己的事后报告原文我没有取到 |
| 2026-05-12 | Boost Hook / Ethereum | 约 4.68 万美元 | 杠杆多单按池子实时 slot0 价格记账,闪电贷拉价后在虚高价格上开仓 | [二手,单一来源] https://olympix.security/exploits ;该页没有明说它是 v4 Hook,金额取自链接 slug |
| 2026-06-04 | ATOHook / Ethereum | 约 55.12 ETH | Hook 里 Solady 重入锁与余额共用了同一个存储槽,辅助合约可以一次次领取 | [二手,单一来源] 同上 |
| 2026-09-15 | 某用户的 Safe(rsETH 头寸)/ Ethereum | 约 2,900 rsETH(约 770 万美元) | 用户授权的自定义 v4 LP 模块可被公开的 keeper multicall 重定向到攻击者建的、挂恶意 Hook 的池子;资金被一个 MEV 机器人抢先取走。漏洞在用户模块,不在 v4 核心 | [二手] https://shattered.io/yoink-mev-bot-beats-hacker-rseth-2026/ (转引 Blockaid、BlockSec、SlowMist);没有官方事后报告,各家细节有出入 |
| 2026-10-02 | GoldPesa / **Base** | 约 11.5 万美元 | Hook 销毁流动性时按会话净余额结算,把攻击者未付的头寸也算了进去 | [二手,单一来源] https://olympix.security/exploits ;该页没有明说是 v4 Hook |

- 没有查到 v4-core / PoolManager 本身被攻破的公开事故;上表各出处也都把原因归在 Hook 或外围合约上。
- 二手报道还提到 Unistreet(1.78 万美元)、Malt(1.34 万美元)两起小额事件,只有搜索摘要、没有可核对的页面,未列入表中(§10-9)。
- [二手] 有安全公司称截至 2026-09-11 分析的 84,163 个 v4 Hook 里 54.2% 带恶意风险特征;出处是搜索摘要转述,原报告我没读到(§10-10)。

---

## 9. Base 上的 Hook 生态与资助

### 9.1 规模(官方登记库)

[HOOKLIST] 在 commit `f4b5956d`(2026-11-05)共登记 5,019 个 Hook,其中 **Base 1,150 个**(仅次于 Robinhood Chain 的 1,206,略多于 Ethereum 的 1,133)。登记库的说明写明名称和描述可由 AI 根据已验证源码生成,所以下面的"做什么"一栏当线索用,不当已核实事实。

Base 这 1,150 个的权限位统计(我用脚本数的,权限位是从地址解码的确定事实):

| 标志 | 个数 | | 属性 | 个数 |
|---|---|---|---|---|
| beforeSwap | 864 | | `dynamicFee = true` | 163 |
| beforeInitialize | 800 | | `upgradeable = true` | 36 |
| beforeSwapReturnsDelta | 726 | | `requiresCustomSwapData = true` | 54 |
| beforeAddLiquidity | 705 | | `vanillaSwap = true` | 136 |
| afterSwap | 529 | | | |
| afterSwapReturnsDelta | 374 | | | |
| afterInitialize | 220 | | | |
| beforeRemoveLiquidity | 141 | | | |
| afterAddLiquidity / afterRemoveLiquidity | 65 / 57 | | | |
| afterDonate / beforeDonate | 33 / 25 | | | |
| 两个 liquidity return delta | 各 10 | | | |

观察(事实层面):Base 上约六成登记 Hook 带 `beforeSwapReturnsDelta`,带 remove-liquidity 回调的不到一成半。按名称和描述做关键词粗筛,描述里出现 launch / memecoin / bonding / tax 一类词的有 298 个,出现 "limit order" 的 21 个(粗筛,会有误判)。

### 9.2 有代表性的项目

> 本节是对公开登记库、公开源码和所注区块的链上读数的转述,由 AI agent 整理,未经相关项目确认,地址与项目的对应关系未逐个核实;不是对任何第三方项目的安全评价或归属认定,读数可能已过时。

地址出处:[ALLOWLIST](Uniswap 自家路由的白名单,变量名带 `_ON_BASE`)。权限位由我从地址低 14 位解码。"做什么"来自 [HOOKLIST] 的描述或 [二手] 报道。

| 项目 | Base 上的 Hook 地址(举例) | 权限位(解码) | 做什么 |
|---|---|---|---|
| Uniswap WETHHook | `0xb08211d57032dd10b1974d4b876851a7f7596888` | beforeInitialize、beforeAddLiquidity、beforeSwap、beforeSwapReturnsDelta | ETH↔WETH 1:1 包装,零费;官方出品。出处:[HOOKS-PUB] README "Deployments";[链上] 有 6,257 字节代码 |
| Flaunch | `0x23321f11a6d44fd1ab790044fdfde5758c902fdc`(PositionManager v4) | beforeInitialize、add/remove 的 before+after、beforeSwap、afterSwap、afterDonate、两个 swap return delta | memecoin 发射台:公平发射期、内部兑换池回收手续费、创作者分成、回购墙 |
| Clanker | `0xd60d6b218116cfd801e28f78d011a203d2b068cc`(dynamic fee v2)、`0xb429d62f8f3bffb98cdb9569533ea23bf0ba28cc`(static fee v2) | beforeInitialize、beforeAddLiquidity、beforeSwap、afterSwap、两个 swap return delta | 代币发射 Hook:按波动率累加器调 LP 费、用 return delta 抽协议费、可选 MEV 模块。发币类 |
| Zora Coins | `0x1258e5f3c71ca9dce95ce734ba5759532e46d040`(creator v2.2.1)、`0xf6d0a13609bb5779bc5d639f2ba3bfda83d4d0c0`(post v2.4.0) | afterInitialize、afterSwap(post v2.4.0 另有 beforeSwap) | 建池时铺多段流动性,每笔 swap 后收取 LP 费换成支付币并分给创作者 / 推荐人。[ALLOWLIST] 里 Base 上列了 18 个版本。发币类 |
| Doppler | `0xbb7784a4d481184283ed89619a3e3ed143e1adc0`(V2)、`0xbdf938149ac6a781f94faa0ed45e6a0e984c6544`(V3) | V2:beforeInitialize、beforeAddLiquidity、afterAdd/RemoveLiquidity、beforeSwap、afterSwap;V3:beforeInitialize、afterAdd/RemoveLiquidity、afterSwap、afterSwapReturnsDelta | 荷兰式拍卖的流动性引导 / 价格发现。Uniswap Foundation 的 Research 类受资助项目(https://www.uniswapfoundation.org/grants )。发币类 |
| Aegis(Solo Labs) | `0x8f29bd5c8429730fa4c46e6295c4e679ededd0cc` | afterInitialize、beforeSwap、afterSwap、两个 swap return delta | 每笔由 DynamicFeeManager 设动态费,另收 Hook 费并定期复投为全区间流动性;带预言机。**与我们的动态费 Hook 同类** |
| Angstrom L2(Sorella) | `0x631352aaa9d6554848af674106bcd8bb9e59a5cf`([ALLOWLIST] 变量名拼作 `ANSTROM_HOOK_ON_BASE`) | beforeInitialize、afterAdd/RemoveLiquidity、beforeSwap、afterSwap、**全部 4 个 return delta** | 按 gas priority fee 收"MEV 税"并通过逐 tick 的奖励累加器补偿 LP,对 JIT 流动性也收税 |
| Arrakis Private Hook | `0xf9527fb5a34ac6fbc579e4fbc3bf292ed57d4880` | beforeAddLiquidity、beforeSwap | 只允许金库模块加流动性,并按方向覆盖 LP 费 |
| 限价单 | `0x9d11f9505ca92f4b6983c1285d1ac0aaff7ec0c0`([ALLOWLIST] `LIMIT_ORDER_HOOKS_ADDRESS_ON_BASE`) | beforeSwap、afterSwap | [ALLOWLIST] 只有变量名,项目归属未核实(§10-12)。[HOOKLIST] 另有 `0xeeee3da335342996ab288fbcf70fbe5f9ed81040` "LimitOrderHook"(afterInitialize、afterSwap) |
| TWAMM | `0xed1698c29928a6c44cddb0c75ab0e5d47eb72a80`([ALLOWLIST] `TWAMM_HOOKS_ADDRESS_ON_BASE`) | beforeInitialize、beforeAddLiquidity、beforeRemoveLiquidity、beforeSwap | 项目归属未核实 |
| Uniswap Labs DualPoolHook | `0x000000258c397d8f759f70444d6dbf3622c22ac0` | beforeInitialize、beforeAdd/RemoveLiquidity、beforeSwap、afterSwap | JIT 流动性 + ERC-4626 金库再抵押;出处 [HOOKLIST] |
| Aggregator Hooks(Uniswap Labs) | 地址未取 | — | 把外部流动性(Fluid、Curve、PancakeSwap 等)包成 v4 池,2026-10-22 在 Ethereum、Base、Robinhood Chain 上线。[二手] https://theblock.co/news/defi/2026-10-22-uniswaps-aggregator-hooks-go-live-ethereum-base-robinhood-chain-421932 ;源码在 [HOOKS-PUB] `src/aggregator-hooks/` |
| Bunni v2 | `0x000052423c1db6b7ff8641b85a7eefc7b2791888`(登记库) | afterInitialize、beforeAddLiquidity、beforeSwap、beforeSwapReturnsDelta | 自定义流动性分布;2025-09 被攻击后关停(§8.4) |

[ALLOWLIST] 里 Base 上带名字的 Hook 约 57 个,其中多数是发币 / 代币税 / launchpad 类(Flaunch ×7、Clanker ×4、Zora ×18、Doppler ×2,另有 Basememe、Claunch、Liquid Launch、Seedify Spark、Simple Sell Tax 等)。

### 9.3 被 Uniswap 前端路由的条件

[DOC-ROUTING]:"Uniswap Labs routing picks up many hooks automatically. Some hooks have to be reviewed and allowlisted by Uniswap Labs first.";需要审核的通过 hook allowlisting 表单提交;另一条路是自己为挂 Hook 的池子跑 UniswapX filler。具体的判定标准在帮助中心文章里(https://support.uniswap.org/hc/en-us/articles/48291859140621-Routing-for-hooked-pools ),该页对我返回 403,没读到(§10-13)。[HOOKLIST] 的 `vanillaSwap` 字段与仓库里的 `hooklist-vanilla-swap.json` 看起来与此有关,未细读。

### 9.4 资助与孵化项目的开放状态(查询日期 2026-11-11)

| 项目 | 状态 | 出处 |
|---|---|---|
| Uniswap Hook Incubator(Atrium Academy 办,Uniswap Foundation 出学费) | **当前报名关闭**。页面原文 "Applications are currently closed.";最近一期 2026-10-01 开营、报名截止 2026-09-21。2026 年的开营日是 1 月 15 日、4 月 9 日、7 月 2 日、10 月 1 日(约每季度一期)。下一期的日期页面上没有 | https://atrium.academy/uniswap ;https://atrium.academy/sponsors (经搜索摘要) |
| Uniswap Foundation Grants | **查不到是否开放**。https://www.uniswapfoundation.org/grants 只列已资助项目和四个类别(Ecosystem / Research / Security / Governance),没有申请入口、截止日期或 RFP。已资助的 v4 相关项目包括:Hook Incubator、OpenZeppelin Hooks Library、Uniswap Foundation Security Fund(资助 Hook 审计)、v4 Hooks Registry、Doppler | 同左 |
| Uniswap v4 Hook Design Lab | **查不到当前是否开放**。公告(日期写作 "6.9.2025")称其为试点资助计划,提供里程碑式资金、审计补贴、路由返佣;首期主题是 JIT 流动性、动态费、再抵押;只留了"登记以了解后续批次"的表单,没有金额和截止日期 | https://uniswapfoundation.org/blog/introducing-the-uniswap-v4-hook-design-lab ;项目页 https://www.uniswapfoundation.org/v4-hooks (未抓取) |

---

## 10. 未核实清单

1. **链上字节码对应哪个源码版本**:没有把 Base 上的 PoolManager / PositionManager / Universal Router 字节码与某个 commit 的编译产物比对。"PoolManager = v4-core `v4.0.0`"是按发布时间的合理推断,不是核实过的事实。已核实的只有:主网与 Sepolia 的 PoolManager 字节码除自身地址外相同。
2. **已部署的 PositionManager 是 v4-periphery 哪个 commit**:periphery 没有 tag,main 在部署之后又改过多次(逐跳滑点、V4Router 行为等)。按 main 的源码推断已部署合约的行为不可靠;要以链上合约的已验证源码为准,我没有去区块浏览器逐个读。
3. **三个 Universal Router 哪个是 Uniswap 前端当前在用的**,以及 2.1.1 / 2.1.2 与未标版本那个的差别。
4. **Base 上具体哪些池子已被设置协议费、数值多少**:只读到 controller 非零,没有逐池读 slot0。
5. **Base 的 `block.number` / `block.timestamp` 语义在 2026-11-05 之后(内部项目记录 所述 200ms 完整区块)对"按块计"的 Hook 逻辑的影响**:本文没有查。动态费 Hook 的"跨块的量"直接依赖这一点,H1 开工前应由研究员或 SRE 单独核实。
6. `HookMinerCreate3.sol`、`PrefacedHookMiner.sol` 的用法没有细读。
7. **BUSL 的 Additional Use Grant 具体内容**:`v4-core-license-grants.uniswap.eth` 在以太坊区块 26,394,667 有 resolver(`0x4976fb03…Ba41`),但我试的几个 text key(`notice`、`description`、`url` 等)都是空的,不知道正确的 key;`v4-core-license-date.uniswap.eth` 在该区块**没有设置 resolver**(据此,Change Date 目前应按许可证正文的 2027-06-15 理解,但这是我的读法,未经确认)。
8. Bunni 关停后改为 MIT 许可:只有二手报道。
9. 2026 年的几起小额 Hook 事故(Boost Hook、ATOHook、GoldPesa、Unistreet、Malt):只有单一二手来源,没有交易哈希或官方事后报告;其中 Boost Hook 和 GoldPesa 是否确为 **v4** Hook 该来源没有明说。
10. "54.2% 的 v4 Hook 带恶意风险特征"的原始报告没读到。
11. 2026-09-15 rsETH 事件的细节各家说法不一,没有官方事后报告。
12. [ALLOWLIST] 里 `LIMIT_ORDER_HOOKS_ADDRESS_ON_BASE`、`TWAMM_HOOKS_ADDRESS_ON_BASE` 等只有变量名,背后的项目、源码和审计情况没查。§9.2 "做什么"一栏整体来自登记库的(可能由 AI 生成的)描述或二手报道,没有逐个读合约源码。
13. Uniswap 前端路由对 Hook 池的自动收录 / 审核标准(帮助中心文章 403)。
14. Uniswap Foundation Grants 与 Hook Design Lab 当前是否接受申请、金额范围、申请条件:官网页面上查不到。Hook Incubator 下一期的开营和截止日期:查不到。
15. OZ uniswap-hooks v1.2.x / v1.3.0-rc.0 是否经过审计:仓库里只有到 v1.1.0 RC2 的审计 PDF;master 最近的提交信息里出现了 "M-07" 这类审计编号,说明可能有在进行的审计,但没有公开报告可引。
16. v4-core / v4-periphery 自身的审计报告(periphery 仓库 `audits/` 下有 ABDK、Spearbit 的 **DRAFT** 版和 OpenZeppelin 的 periphery + universal-router 报告;v4-core 仓库的 `docs/` 我没有翻)里列出的、与 Hook 相关的具体发现:没有逐份读。§8.2 只覆盖了安全框架页面和源码注释。
17. 不用 `via_ir` 时从源码编译 PoolManager 是否超过 24,576 字节的合约大小上限(官方配置是 `via_ir = true`、链上实测 24,009 字节;官方模板关了 `via_ir` 并改用预编译字节码):我没有实际编译验证。同理,第三方仓库 `akshatmittal/hookmate` 里的预编译字节码是否与官方部署一致,没有核对。
