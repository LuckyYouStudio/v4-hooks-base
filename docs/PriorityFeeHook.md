# PriorityFeeHook — 设计说明

**未经外部审计,不要直接用于主网资金。两轮 AI agent 内部审计([`audits/audit-hooks-h2.md`](../audits/audit-hooks-h2.md),第二轮窄范围复查附在其末尾):合约逻辑无需改;第二轮只剩措辞,已改,由项目负责人核对,审计员未再复看;不等于外部审计。没有部署到任何公共网络。**

**定位:这是一件展示设计取舍和诚实评估的作品,不宣称能给 LP 带来可观收入。** 按现有数据,它今天在 Base 上收不到多少钱(见"能收到多少")。

**用之前先看这四条:**

1. **今天收不到多少。** 研究员的数量级估算:Base 上全部 v4 兑换交易付给定序器的优先费合计约 0.6 ETH/天(20 分钟样本线性外推),这是"所有 v4 池子加起来、可供重新分配的出价"的量级,单个池子只占其中一小部分。同类的 Angstrom L2 池子当时区间内流动性为 0、样本里 0 笔成交。
2. **报价不含加收。** Quoter 和不带费用字段(或只带 `maxFeePerGas`)的 `eth_call` 读到的优先费是 0,报价永远按 0.05% 算;实际成交最多按 0.30% 算。差额最大约 0.25%:exactIn 少拿约 2,501 ppm,exactOut 多付约 2,507 ppm。按报价留 0.1% 或 0.25% 滑点余量的订单在上限处会回滚,留 0.5% 的能成交。要报价准确,报价的调用必须带 `maxPriorityFeePerGas` 或 legacy `gasPrice`(§8c)。
3. **谁填交易的小费,谁就决定这笔 swap 的费率;名义金额高于盈亏平衡点时,组装交易的人抬小费可以获利,而且不需要是 LP——但做 JIT 需要资金。** 代付 / 代发结构(4337 打包者、7702 代付者、元交易 relayer)下,Hook 读到的是他们的小费。代发者是 LP,或者在同一笔交易里做 JIT(加窄区间流动性 → 用户的 swap → 撤出,不需要常驻头寸;4337 bundler 能否这样包没有验证),**名义金额高于盈亏平衡点时,抬高小费是赚钱的**:抬到上限的成本是 `gas × 小费`,收益是名义金额的 0.25% × 他在那一刻的区间内份额。盈亏平衡点:独占 LP、20 万 gas 约 0.08 ETH;JIT 按假设的 50 万 gas、份额接近 100% 估算约 0.2 ETH(gas 数都是假设值,没有测量)。低于它抬小费是亏的:`adversarial: test_fact_5a_lpRelayer_profitsFromRaisingTheTipOnUsersSwaps` 里名义 0.01 ETH 时各份额都亏。**JIT 的份额 = JIT ÷ (JIT + 原有区间内流动性)**:要 90% / 99% 份额,需约 9 / 99 倍于原有 LP 在同一窄区间内的资金,在交易内拿出来(自有,或闪电贷;闪电贷路径没有测,它的 gas 也不在 50 万的假设里)。实测(`jit: test_fact_5a_relayerFlashJIT_noStandingLpNeeded`):用户 10e18 的 exactIn,零头寸的代发者做 99e24 的 JIT——交易内要拿出约 593,080 枚代币,是用户 10 枚名义的约 5.9 万倍——小费为 0 时净得 0.005001 枚代币、抬到上限净得 0.030001 枚(两种代币按价格 1 计);同一笔里原有 LP 只拿到 3.03e11 wei(不做 JIT 时是 0.03 枚)。只拿 9 倍于原有 LP 的资金(约 53.9 枚)时,抬小费多赚 0.0225 枚,原有 LP 留下 0.003 枚(`jit: test_fact_5a_relayerFlashJIT_capitalNeededByShare`,全表见 §9 5a)。也就是说**份额做得上去时,加收大部分进了代发者的口袋,不是原有 LP 的**(与第三方 JIT 是同一件事,见 §9 5b:能对准单笔交易做 JIT 的首先是交易的组装者)。上限是写死的 0.30% LP 费,且受用户自己签的滑点保护约束,不涉及本金。意图 / filler 类产品不在此列:那里加收由 filler 自己承担。细节、受影响的结构和没有验证的部分见 §9 5a。
4. **绕得过去。** 没人竞争的条件交易同块跟进、L1 存款交易(gas 价恒为 0)、把成交放到别的池子,都能拿到位置而只付地板费;将来 EIP-8130 的 coinbase tip 激活后,出价可以完全不经过 `tx.gasprice`。

源码:`src/PriorityFeeHook.sol`(回调与登记)、`src/libraries/PriorityFeeMath.sol`(纯数学)、`src/base/BaseHook.sol`(访问控制与权限校验,与 VolatilityFeeHook 共用,未改动)。

研究出处:`docs/research/base-priority-ordering-for-hooks.md`(下称 [H2a],数字由研究员实测或估算,项目负责人未复核,本文也没有重新抽样)、`docs/research/uniswap-v4-hooks-base.md`(下称 [HOOKFS])。测试名后面不带文件名的都在 `test/PriorityFeeHook.t.sol`;`adversarial` = `test/PriorityFeeHook.adversarial.t.sol`,`quoter` = `test/PriorityFeeHook.quoter.t.sol`,`fork` = `test/fork/PriorityFeeFork.t.sol`,`math` = `test/PriorityFeeMath.t.sol`,`jit` = `test/PriorityFeeHook.jit.t.sol`。审计报告:`audits/audit-hooks-h2.md`(下称 [审计])。

## 1. 收的是什么

Base 的定序器按每 gas 的优先费从高到低排交易([H2a] §1:Denim 之后随机 2,000 块,相邻交易 99.11% 非递增)。想排在同一批竞争者前面,就得出更高的优先费;这笔钱现在全部进定序器的费用金库。套利者抢的那个位置之所以值钱,是因为池子的报价过时了——亏的是 LP。

这个 Hook 让**一笔 swap 的 LP 费率随承载它的那笔交易的优先费上升**:

```
优先费   = max(tx.gasprice − block.basefee, 0)                      (wei / gas,饱和减法)
加收     = min( floor( max(优先费 − 免征额, 0) / 每 pip 的 wei 数 ), 上限 − 地板 )
LP 费率  = 地板 + 加收                                               (pip,1 pip = 0.0001%)
```

为什么这等于向抢排序者收费:竞争者为同一个机会出价时,要付的总成本是"给定序器的小费 + 给 LP 的加收"。加收随小费线性增长,所以每多出 1 wei/gas 的小费就多付一份给 LP;在竞争充分时,出价总额逼近机会的价值,其中一部分从定序器手里转到了 LP 手里(这是 [H2a] §5.3 引用的 "Priority Is All You Need" 的机制;"竞争充分时"是那篇文章的前提,不是我们测出来的)。`tx.gasprice − block.basefee` 正是排序所用的量:L1 数据费和 operator fee 都不在里面([H2a] §2.4、§2.7、§2.8)。

对一笔名义金额 N(以 ETH 计)、用 gas G 的 swap,在免征额以上:

```
付给 LP 的加收 ÷ 付给定序器的小费 ≈ N ÷ (G × 400,000 × 10^6 wei) = N ÷ (G × 4×10^11 wei)
```

G = 200,000 时分母是 0.08 ETH:一笔 8 ETH 的套利,每付定序器 1 份小费,就付 LP 约 100 份加收(到上限为止)。这个比值与 N 成正比,是"按费率收"的直接后果,见 §5。

## 2. 启用的回调

| 回调 | 做什么 |
|---|---|
| `afterInitialize` | 要求 `key.fee == 0x800000`(动态费标志),否则 revert `NotDynamicFee`(建池整笔失败);登记池子;调用 `poolManager.updateDynamicLPFee(key, 500)` 把 slot0 里的 LP 费从动态费池默认的 0 改成地板值(这个值不会被实际收取,只是不让链下读 slot0 的人看到 0%);发 `PoolRegistered` |
| `beforeSwap` | 未登记的池子 revert `PoolNotRegistered`;返回 `费率 \| 0x400000`(覆盖费率,只对当笔生效、不落盘)和零 delta |

其余 8 个回调和 4 个 return-delta 位全部关闭;地址低 14 位 = `0x1080`(与 VolatilityFeeHook 相同,init code 不同,所以 salt 和地址不同)。构造函数校验 14 位全等和 PoolManager 有代码(`BaseHook`)。10 个外部入口都是非 virtual + `onlyPoolManager`。

**状态**:只有 `isRegistered[poolId]` 一个只写一次的布尔。`_beforeSwap` 在源码里声明为 `view`,编译器保证它不写存储、不发事件;运行时只读这一个槽(`test_beforeSwap_isStateless`;不变量套件每笔 swap 后检查 Hook 没有发事件、另一个池的登记槽没变)。费率只取决于 `tx.gasprice` 和 `block.basefee`,与池子的价格、tick、流动性、成交量、`sender`、`hookData`、`SwapParams`、之前任何一笔 swap 都无关。其中与 `sender`、`SwapParams`、`hookData` 无关是源码直接保证的:`src/PriorityFeeHook.sol` L91 的 `_beforeSwap` 里这三个参数没有名字,函数体读不到它们。测试(`testFuzz_fee_ignoresSenderHookDataAndSwapParams`:任意 sender 含 `sender == tx.origin`、任意 tx.origin、任意 SwapParams、长度 0 / 1 / 4 / 20 / 31 / 32 / 33 / 64 / 96 / 320 及随机长度的 hookData——这些是冒充 PoolManager 直接调 `beforeSwap` 时变的;同一条测试另外经真实 swap 走一遍,但那条路只变 hookData 和方向,sender 恒为测试路由、tx.origin 是框架默认值、金额固定 1e15;`test_fee_ignoresHookData_everyLengthAroundAWord`、`test_fee_ignoresSender_includingTxOrigin`)的作用是防止以后有人给参数起名并用上;与之前的 swap 无关见 `testFuzz_5a_earlierTransactionsCannotChangeYourFee`。

**没有流动性回调和 donate 回调**:加、撤流动性和 donate 都不执行本 Hook 的任何代码,任何 gas 价下都一样(`test_liquidityAndDonate_neverTouchTheHook`、`fork: test_fork_removeLiquidity_neverBlocked_onRealManager`;不变量套件里撤流动性不在 try/catch 里,回滚即失败)。**撤流动性不可能被本 Hook 堵住。**

无 owner、不可升级、不用 return delta、不持有资金(没有 `receive`,收不了 ETH:`test_hookHoldsNothing`)、四个参数全是编译期常量。

## 3. 费率函数与常量

**四个常量都是未回测的工程起点。** 没有用历史数据回测过,没有人能在部署后调整。

| 常量 | 值 | 含义 | 选它的理由 |
|---|---|---|---|
| `MIN_FEE` | 500 pip(0.05%) | 免征额以内的 LP 费 | 主流币对常见的档位;未回测 |
| `MAX_FEE` | 3000 pip(0.30%) | LP 费上限,写死 | 最坏情况下这个池子等于一个"0.30% 的池子",是 v3 时代的标准档位之一,不是惩罚性费率;同时把"报价与成交的最大差额"限制在约 0.25%。协议费(由 Uniswap 的 protocol fee controller 设,每方向最多 0.10%,Hook 管不了)另算,**用户实付总费率最高 3,997 pip**(`test_totalFee_upperBoundWithMaxProtocolFee`、`fork: test_fork_protocolFee_totalFee_onRealManager`) |
| `TIP_ALLOWANCE` | 20,000,000 wei/gas(0.02 gwei) | 免征额:优先费不超过它(含等于)不加收 | 高于研究员测到的 Universal Router 交易 p99(0.015 gwei)和当时 MetaMask 接口的 medium 档(0.015 gwei)、等于其 high 档(0.02 gwei);是 Angstrom L2 当前地板(0.01 gwei)的 2 倍。误伤比例见 §4 |
| `WEI_PER_PIP` | 400,000 wei/gas | 免征额以上,每多这么多优先费,LP 费加 1 pip | 使上限在 1.02 gwei 处到达:[H2a] 表 4-A 里"全部用户交易的块内第 1 笔"的 p99 是 1.354 gwei、p95 是 0.41 gwei,所以绝大多数抢位出价落在线性段内,不会早早撞到上限而失去"多出价多付费"的梯度 |

形状选的是"免征额 + 线性 + 封顶"。线性的好处是越过免征额一点点只多付一点点(0.03 gwei 时加收 25 pip = 0.0025%),免征额定得不准时代价小;没有选分段或凸函数,是因为没有数据支持更复杂的形状。

舍入:除法向下取整(对交易者有利);没有乘法,没有对无界值的窄化转换,任意 `uint256` 输入都不会溢出或回滚(`math: testFuzz_lpFee_boundsAndClosedForm`、`testFuzz_fee_anyGasPriceAndBaseFee`;`testFuzz_feeForView_fullRange`)。

| 优先费(wei/gas) | 是什么水平([H2a] §4) | LP 费率(pip) | 测试 |
|---|---|---|---|
| `tx.gasprice < basefee` | 存款交易;显式带了低于 base fee 的 `gasPrice` 的 `eth_call` | 500 | `test_fee_gasPriceBelowBaseFee_chargesFloor_noRevert` |
| 0 | `tx.gasprice == basefee`;不带费用字段的 `eth_call`(节点上读到的是 (0, 0));只带 `maxFeePerGas` 的 `eth_call` | 500 | `test_fee_gasPriceEqualsBaseFee`、`quoter: test_fact_quote_withoutTipField_isAlwaysAtTheFloor` |
| 1,000,000 | 节点建议值 | 500 | `math: test_lpFee_table` |
| 1,500,000 | Universal Router 交易中位数 | 500 | 同上 |
| 15,000,000 | Universal Router 交易 p99 | 500 | 同上 |
| 20,000,000 | 免征额(含) | 500 | `test_fee_bothSidesOfTheAllowance` |
| 20,399,999 | 差 1 wei 不到第一个 pip | 500 | 同上 |
| 20,400,000 | 第一个 pip | 501 | 同上 |
| 30,000,000 | 块内第 1 笔的中位数(0.03 gwei) | 525 | `math: test_lpFee_table` |
| 100,000,000 | 0.1 gwei | 700 | 同上 |
| 500,000,000 | 0.5 gwei | 1,700 | 同上 |
| 1,019,999,999 | 差 1 wei 到上限 | 2,999 | `test_fee_reachesCapAndStaysThere` |
| 1,020,000,000 | 到上限(1.02 gwei) | 3,000 | 同上 |
| 16,100,000,000 及以上 | [H2a] §1.3 例子里最高的一笔 | 3,000 | `math: test_lpFee_table` |

性质(都有模糊测试):费率恒在 [500, 3000];对优先费单调不减、对 `tx.gasprice` 单调不减、对 `block.basefee` 单调不增;只取决于两者之差;任何 `(gasprice, basefee)` 都不回滚。

**一处测试覆盖的限制**:Foundry 的 `vm.txGasPrice` / `vm.fee` 只接受小于 2^64 的值,所以"经过真实 swap"的模糊测试范围是 `[0, 2^64)`(约 184 亿 gwei);`uint256` 全范围是在数学库和 Hook 的纯函数视图 `feeFor` 上测的,它们与 `beforeSwap` 调用同样的两个库函数。

**成交结果与同费率的静态池逐位相同**:同样的流动性、同样的输入,挂 Hook 的池子在优先费 p 下的成交量与一个费率等于 `费率(p)` 的无 Hook 静态池完全相等,四种 swap(两个方向 × exactIn / exactOut)、带或不带协议费都是(`test_fourSwapKinds_*` 6 条、`testFuzz_swap_sameAsStaticPool`、`fork: test_fork_sameAmountsAsStaticPool_onRealManager`)。

## 4. 免征额会误伤多少普通交易

数据全部来自 [H2a] 表 4-B(60 个随机 100 块窗口、2,947 笔 v4 兑换交易、2026-11-09 至 11-11;"普通用户"和"抢排序者"都只是代理变量,没有任何地址被核实身份)。我没有重新抽样。

| 组别 | 被加收(优先费 > 0.02 gwei) | 加收 ≥ 200 pip 即 ≥ 0.02%(优先费 > 0.1 gwei) |
|---|---|---|
| 直接调 Universal Router 的交易(1,049 笔) | 0.7% | 0.2% |
| 其中发送者在样本里只出现 1 次的("普通用户"代理,239 笔) | 1.3% | 0.4% |
| 带 `UserOperationEvent` 的(4337,173 笔) | 0%(最大值 0.00182 gwei) | 0% |
| 全部 v4 兑换交易(2,947 笔) | 7.2% | 1.4% |
| 块内前 3 笔("抢排序"代理,294 笔) | 31.0% | 7.8% |
| 超过门槛的交易所付优先费占 v4 兑换交易优先费总额 | 71.8% | 40.8% |

读法:

- 按"直接调 Universal Router"这个口径,约 0.7% 的交易会被加收,约 0.2% 会被加收 0.02% 以上。
- **(推算,不是研究员给出的数字)** 被加收的那 0.7% 里多数只高出免征额不多。拆分是我用表 4-B 的占比乘以 1,049 笔反推的,笔数四舍五入:高于 20M wei 的 0.7% ≈ 7 笔,高于 50M 的 0.2% ≈ 2 笔,高于 100M(0.1 gwei)的 0.2% ≈ 2 笔。即约 7 笔里约 5 笔落在 20M–50M wei(加收 0–75 pip),约 2 笔高于 0.1 gwei(加收 ≥ 200 pip);这 2 笔里有一笔是 [H2a] §4.3 列出的 1.5 gwei,按上限 0.30% 收。研究员没有给出这几笔各自的优先费,表里的百分比只有一位小数,所以"5 笔""2 笔"各有 ±1 的出入。
- 反过来,**被加收的不等于套利者**。[H2a] §4.4 第 5 条:高于 0.01 gwei 的 v4 兑换交易里 57% 来自样本内只出现一次的发送者、93% 发往 Universal Router 以外的合约,从链上分不出是套利合约还是经交易终端下单、默认小费偏高的普通用户。样本里优先费最高的几笔中就有"只出现一次的地址直接调 Universal Router、出 1.5 gwei"的——这样一笔在本 Hook 下按 0.30% 收。
- 免征额也放走了一部分抢排序者:块内前 3 笔里 69% 不被加收。
- 样本没有极端行情([H2a] §7-13)。区块变满时 base fee 每块最多涨 0.4%,拥堵价格会先体现在优先费上([H2a] §2.13,推断),那时普通用户被加收的比例会高于上表,高多少没有数据。
- 免征额是绝对的 wei 数。Base 调整费用机制(今年已把最低 base fee 从 1,000,000 调到 5,000,000;Everest 计划按 gas limit 计费)或钱包改默认小费,都会让它失准,而它不可调。最坏结果有界:定低了,普通用户最多按 0.30% 付费;定高了,这个池子就是一个 0.05% 的静态池。

## 5. 与 Angstrom L2、Aero 的区别

| | 本 Hook | Angstrom L2([H2a] §5.1) | Aero MEV 税模块([H2a] §5.2) |
|---|---|---|---|
| 收什么 | LP **费率**(加在这笔 swap 的手续费上) | 一笔**绝对金额**的 ETH:`系数 × 120,000 × (优先费 − 地板)` | 费率,封顶 10% |
| 怎么收 | `beforeSwap` 返回覆盖费率,PoolManager 照常把手续费记给区间内流动性 | `BeforeSwapDelta` 从 ETH 一侧扣,Hook 自己持有,再按扫过的 tick 分给 LP | 费用模块 |
| 权限位 | 2 个(`afterInitialize`、`beforeSwap`) | 含全部 4 个 return-delta 位 | — |
| 代持资金 | 否 | 是 | — |
| 币对限制 | 无(原生 ETH 也行) | currency0 必须是原生 ETH | — |
| 上限 | LP 费 0.30% 写死 | 税额本身无上限(审计报告记录过税相对成交额过大时 swap 回滚) | 10% |
| 参数 | 全是常量,无人可调 | owner 可调系数、地板、JIT 开关 | 可调,当前乘数为 0(未生效) |
| JIT | 不处理(见 §9 5b) | 另设 JIT 税(当前关闭) | — |

取舍:

- **按费率的好处**:不用 return delta、不代持资金,没有 delta 记账算错丢钱的那一类风险;小额交易不会因为税额超过成交额而回滚;最坏情况有写死的上限;自做 JIT 逃不掉(§9 5b)。
- **按费率的坏处**:收多少取决于名义金额,而不是出价本身。同样的小费,1 ETH 的交易和 100 ETH 的交易付的加收差 100 倍,而它们抢的位置价值未必差 100 倍。按金额收是机制设计上"正确"的做法(出价多少税多少),按费率只是它的近似。小额高小费的交易几乎不交加收,大额高小费的交易(不一定是套利)交很多。
- 换算:本 Hook 的斜率在名义金额 9.6 ETH 时与 Angstrom L2 当前参数(系数 200)收的金额相同(`200 × 120,000 × 400,000 × 10^6 wei = 9.6 ETH`;算术,不是测量);名义金额更小则本 Hook 收得更少。
- 不可调是本仓库的设计约束,代价在 §4 最后一条和"已知局限"里。

## 6. 能收到多少

**今天收不到多少钱。** 依据全部来自 [H2a],都是数量级估算:

- 全部 v4 兑换交易 20 分钟样本里付给定序器的优先费合计 0.0083 ETH,线性外推约 **0.6 ETH/天**(同期全部用户交易约 26 ETH/天)。[H2a] §4.3 写明这只能看数量级。
- 这个数是"所有 v4 池子(样本里 731 个)上的出价总额"。机制上(推断,依据同 §1),LP 能分到的是这些出价里高于免征额那部分的一个比例,不会超过出价总额本身的量级;单个池子再乘以它在其中的占比。**我没有估算单个池子的数字**,因为它取决于这个池子能吸引多少被抢的成交量,没有数据。
- Base 上 v4 的成交以发币类 Hook 池为主,块首是 v4 兑换的区块只占 1.2%;主流币对的套利主要发生在别的 DEX([H2a] §4.4 第 6 条)。
- 同类先例:Angstrom L2 在 Base 登记的唯一一个池子(ETH/USDC)当时区间内流动性为 0,样本里 0 笔成交([H2a] §5.1);Aero 的同类模块乘数为 0。
- 加收还会让路由器把普通流量导去别的池子:报价按 0.05%,但只要集成方知道这个 Hook,就会把预期费率算高。这一点没有测量。

## 7. 怎么被绕过

"绕过" = 拿到了位置,但 Hook 读到的优先费低。每条都有一条记录事实的测试(`adversarial` 里的 `test_fact_bypass_*`);排序行为本身在单元测试里复现不了,测试记录的只是"这种交易读到的费率是地板"。

| 途径 | 事实与出处 | 测试 |
|---|---|---|
| **条件交易(Validity Transactions)同块跟进** | 被触发交易唤醒后按自己的小费排进剩余队列,只需压过同时被唤醒的其他跟进者;只有一个跟进者时可按最低小费成交([H2a] §3 第 1 项;测试网实测见 内部研究记录 `validity-tx/RESULTS.md`(未随本仓库公开),主网只有间接证据) | `test_fact_bypass_conditionalFollowerWithMinimalTip_paysFloor` |
| **L1 存款交易(类型 `0x7e`)** | gas 价恒为 0,且排在块内所有普通交易之前([H2a] §2.5、§3 第 8 项;依据是源码,链上没有用 trace 验证过,[H2a] §7-7)。代价是 L1 gas 和落块时刻不可控 | `test_fact_bypass_depositTransaction_paysFloorAtTopOfBlock` |
| **EIP-8130 的 coinbase tip(Everest,未激活)** | 出价是交易里一笔转给费用金库的转账,不经过 `tx.gasprice`,而排序优先级很高([H2a] §3 第 9 项,源码已有、主网日期未定)。激活后本 Hook 会漏收这类交易,且无法修补(不可升级,也没有查到能读 coinbase tip 的接口) | `test_fact_bypass_tipPaidOutsideGasPrice_isInvisible`(只证明"gas 价之外付的钱 Hook 看不见",不是 EIP-8130 交易本身) |
| **把价差拆到别的池子成交** | 套利者可以只在没有这个 Hook 的池子里成交;同币对的无 Hook 池在任何小费下都按自己的静态费率 | `test_fact_bypass_otherPoolOnSamePair_ignoresTip` |
| **没有竞争** | 只有一个人看到的机会不需要抬价(机制本身的边界,[H2a] §3 第 11 项) | — |
| 定序器私下通道 | 没有找到公开入口,也无法从链上排除([H2a] §3 第 2 项)。属于信任假设 | — |

没有成为绕过途径的:拆成多笔小额(§9 5b)、自做 JIT(§9 5b)、同一发送者用高价小交易"占位"([H2a] §3 第 13 项,研究员的推断,没有构造交易验证,我也没有)。

## 8. 错配

**(a) 4337 / 7702 / filler / relayer:读到的是代付者或打包者的小费(其中用户签单、他人上链的结构里,组装者抬小费能获利,见 §9 5a;filler 抬小费是自己承担)。** `tx.gasprice` 是最外层那笔交易的属性,与调用层级无关([H2a] §2.14)。用户在 UserOperation 里填的小费 Hook 看不到。[H2a] §4 的样本里,带 `UserOperationEvent` 的 v4 兑换交易优先费全部在 0.002 gwei 以下,所以**现状是这类用户不被加收**;但这是打包者当前的行为,不是保证。测试:`adversarial: test_fact_5a_relayerTipIsChargedToTheUsersSwap`(同一笔 10e18 的 exactIn,打包者把小费设到 1.02 gwei 时用户少拿 2,501 ppm;用户签的最低成交量若只留 0.1% 余量则整笔回滚,留 0.5% 则成交)、`test_fact_5a_bundle_everySwapChargedAtTheBundlersTip`(同一个 bundle 里的每个用户都按 bundle 的小费收)。测试是用"把 gas 价设成打包者的"来模拟的,没有跑真实的 EntryPoint。

**(b) 一笔交易里多次 swap,每次都按同一个优先费加收。** 聚合器的多跳或拆单若两次经过本池(或经过两个挂了本 Hook 的池子),每次都收(`test_twoSwapsInOneTransaction_bothCharged`)。这是有意保留的行为:Hook 无状态,不去记"本交易是否已收过"。

**(c) Quoter / `eth_call` 报价不含加收。** V4Quoter 是真的走一遍 swap(含 Hook)再 revert 取结果,所以 Hook 按**报价那次调用**的 gas 价定价。在 Base 节点上,不带费用字段的 `eth_call` 里合约读到的 `(GASPRICE, BASEFEE)` 是 **(0, 0)**;只带 `maxFeePerGas` 时读到的是 `(basefee, basefee)`。两种情况优先费都是 0,**报价恒按地板 0.05%**。**要报价准确,调用必须带 `maxPriorityFeePerGas`(type-2)或 legacy `gasPrice`。** 读数表见本节末尾(工程师探针)和 [审计] 第三节(审计员在区块 56,264,677 独立重做的 15 种调用,结论相同)。

实测(本地用钉死版本的 v4-periphery 源码部署的 V4Quoter,`quoter` 文件,报价调用按 (0, 0) 模拟;`quoter: test_fact_quote_withoutTipField_isAlwaysAtTheFloor` 断言 (0, 0)、(basefee, basefee)、(1, basefee) 三种读数下报价逐位相同。fork 上用 Base 主网已部署的真实 V4Quoter `0xE1A6…CA47`,`fork: test_fork_realQuoter_quoteHasNoSurcharge`(0→1)和 `test_fork_realQuoter_quoteHasNoSurcharge_oneForZero`(1→0),ppm 数字与本地相同;fork 测试里报价调用读到的是 (0, 区块头的 base fee),那是测试框架的读数,不是真实节点的,见 §13):

| 成交时的优先费 | LP 费率 | exactIn 1e18:成交比报价少拿 | 
|---|---|---|
| ≤ 0.02 gwei | 500 | 0(逐位相等,`test_quote_matchesExecution_whenTipIsWithinAllowance`) |
| 0.03 gwei | 525 | 25 ppm |
| 0.1 gwei | 700 | 200 ppm |
| 0.5 gwei | 1,700 | 1,200 ppm |
| ≥ 1.02 gwei | 3,000 | 2,501 ppm(报价 999,499,001,000,748,499;成交 996,999,005,991,991,025) |

exactOut 1e18 在上限处:报价要付 1,000,501,250,626,313,159,实际要付 1,003,010,030,091,273,824,多 **2,507 ppm**(`test_fact_quoteHasNoSurcharge_exactOut_canExceedMaximumInput`)。

**对集成方意味着什么:**

- 前端显示的"预计成交量"在用户小费高于免征额时偏乐观,最多偏约 0.25%。
- **exactOut**:路由器按 `最大输入 = 报价 × (1 + 容忍度)` 保护用户时,容忍度 0.1% 和 0.25% 在上限处都会回滚(`TooMuchRequested`),0.5% 能成交(同一条测试)。exactIn 对称(`test_fact_quoteHasNoSurcharge_exactIn_minimumOutCanFail`)。
- 能做的两件事(`test_quote_withTheTransactionsFeeFields_isExact`):① 报价的 `eth_call` 带上与交易相同的费用字段(必须含 `maxPriorityFeePerGas` 或 legacy `gasPrice`;只带 `maxFeePerGas` 等于没带),这时 Quoter 的结果与成交逐位相等;② 调本 Hook 的纯函数 `feeForPriorityFee(优先费)` 或 `feeFor(gasPrice, baseFee)` 取费率,自己算。`currentFee()` 读的是调用当时的上下文,在不带费用字段的 `eth_call` 里恒为地板,不要用它预估。
- 测试里的带滑点检查的路由是自写的最小测试路由(`test/utils/CheckedSwapRouter.sol`),不是 Universal Router。

**真实节点上的读数**(`script/probe-priority-fee.sh`,只读 `eth_call`,不发交易;Base 主网公共 RPC,区块 56,260,402,节点 `reth/v2.5.2…/base/v1.5.4`;探针把 `PriorityFeeHook._beforeSwap` 用的两个库调用放进一段 initcode 里执行):

| `eth_call` 的费用字段 | 合约读到的 `tx.gasprice` | `block.basefee` | 探针算出的 LP 费率 |
|---|---|---|---|
| 不带 | 0 | **0** | 500 |
| `gasPrice = 1`(低于 base fee) | 1 | 5,000,000 | 500 |
| type-2,`maxPriorityFeePerGas` 1,000,000 | 6,000,000 | 5,000,000 | 500 |
| type-2,20,000,000 | 25,000,000 | 5,000,000 | 500 |
| type-2,20,400,000 | 25,400,000 | 5,000,000 | 501 |
| type-2,100,000,000 | 105,000,000 | 5,000,000 | 700 |
| type-2,1,020,000,000 | 1,025,000,000 | 5,000,000 | 3,000 |
| type-2,`maxFee = maxPriorityFee = 26,000,000`(maxFee 卡住) | 26,000,000 | 5,000,000 | 502(实付小费 21,000,000,不是 26,000,000) |
| legacy,`gasPrice` 60,000,000 | 60,000,000 | 5,000,000 | 587 |

**与 [H2a] §2.3 ③ 的出入**:研究员记录的"不带费用字段 → `(0, 5,000,000)`"我没有复现;我在区块 56,260,1xx–56,260,4xx 的多次调用(带或不带 `from`、`latest` / `pending` / 指定区块)得到的都是 `(0, 0)`,即节点在 gas 价为 0 时把 base fee 也报成 0。审计员在区块 56,264,677 独立重做,结论相同([审计] 第三节的读数表:不带费用字段的 6 种变体都是 (0, 0);只给 `maxFeePerGas` 是 (5,000,000, 5,000,000);只给 `maxPriorityFeePerGas` 123,456 是 (5,123,456, 5,000,000);legacy `gasPrice: 1` 是 (1, 5,000,000);type-2 的 `maxFee = 1` 被节点拒绝)。研究员的 (0, 5,000,000) 在当前节点上不可复现,原因没有查。显式给一个低于 base fee 的 `gasPrice` 才读到 `tx.gasprice < block.basefee`。各种读数下本 Hook 都返回地板、不回滚。本仓库现在统一按 (0, 0) 表述(`PriorityFeeMath.sol` 的注释、`quoter` 与 `fork` 测试的注释和夹具)。

## 9. 操纵面

逐条回答"谁能让别人多付费、谁能少付费"。H1 的教训是费率类 Hook 必须有对抗测试、金额下到 1 wei、池形包含单边和有空档的、成本按扣除攻击者自己 LP 收入后的净额算。本 Hook 的费率不读池子状态,所以池形无关(`test_singleSidedAndGappedPools_feeUnchanged`、`test_zeroLiquidityPool_noRevert`);下面按主体列。数字都来自 `adversarial` 文件,`-vv` 可打印。

### 5a. 谁能让别人多付费

| 手段 | 结论 | 测试 |
|---|---|---|
| 抢在你前面的交易(任意小费、任意方向、1 wei 起的 swap、在价格旁边加流动性、donate) | **不能。** 你的费率只取决于你这笔交易自己的 `tx.gasprice` 和本块的 `block.basefee`;Hook 没有可被改动的状态 | `testFuzz_5a_earlierTransactionsCannotChangeYourFee`、`test_5a_frontRunnerWithHugeTip_doesNotRaiseVictimFee`、`test_strangersPool_doesNotAffectOurs` |
| base fee 飙升(type-2 交易) | **不能,只会让你少付。** 有效 gas 价 = `min(maxFee, basefee + maxPriorityFee)`,所以实付小费 ≤ 你签的 `maxPriorityFeePerGas`;base fee 涨到 `maxFee` 卡住时实付小费反而变小。费率 ≤ `费率(你签的小费上限)` | `testFuzz_5a_type2_baseFeeCannotPushFeeAboveSignedTip`、`test_5a_baseFeeSpike_type2UserStillPaysFloor`;真实节点读数见 §8 表倒数第二行 |
| base fee 变化(legacy 交易) | **不是第三方操纵,但会误收。** legacy 交易没有小费字段,`gasPrice` 高出 base fee 的部分全算小费。用户为保险签了偏高的 `gasPrice`,落块时 base fee 越低加收越多:签 0.06 gwei,base fee 0.0337 gwei 时费率 515,回到最低 0.005 gwei 时 587。上界是 `费率(签的 gasPrice)`。base fee 每块最多降 0.1%([H2a] §2.13),别人压不动它 | `test_fact_5a_legacyTransaction_overpaysWhenBaseFeeIsLow`、`testFuzz_5a_legacy_feeBoundedBySignedGasPrice` |
| **打包者 / 代付者 / relayer 设高小费** | **能,这是本 Hook 唯一真实的"让别人多付"的入口。** 小费由他们定,加收由用户的成交承担,上限 0.30% LP 费,用户的保护只有自己签的滑点限制。诚实的代发者为抢排序抬小费,也会被动让用户多付。详见下两条 | `test_fact_5a_relayerTipIsChargedToTheUsersSwap`、`test_fact_5a_bundle_everySwapChargedAtTheBundlersTip` |
| **有常驻头寸的 relayer(同时是 LP)抬小费获利** | **能获利。** 把小费从 0 抬到 1.02 gwei 的成本是 `gas × 1.02 gwei`(20 万 gas = 204,000 gwei ≈ 0.0002 ETH,付给定序器);用户因此多付名义金额的 0.25% 给 LP,relayer 按份额拿回。因为费率是线性的,盈亏平衡的名义金额与小费高低无关:`N* ≈ gas × 400,000 × 10^6 wei ÷ 份额`,独占 LP、20 万 gas 时为 **0.0816 ETH**(含免征额修正)。实测净利(输入币按 ETH 计、20 万 gas 是假设值):名义 1 ETH,份额 10% / 50% / 100% → +0.000046 / +0.00105 / +0.0023 ETH;名义 100 ETH,份额 100% → +0.2498 ETH;名义 0.01 ETH 时各份额都亏 | `test_fact_5a_lpRelayer_profitsFromRaisingTheTipOnUsersSwaps` |
| **没有任何头寸的 relayer:同一笔交易里做 JIT,再抬小费**([审计] E-1) | **名义金额高于盈亏平衡点时能获利。不需要常驻头寸,但需要资金:份额 = JIT ÷ (JIT + 原有区间内流动性),资金够多时接近 100%(见表后的资金表)。** 代发者组装的一笔交易里:在现价两侧加一段窄而厚的流动性 → 执行用户签好的 swap → 撤出。实测(原有 LP 1e21 全区间;用户 exactIn 10e18,最低成交量按地板费报价留 0.5%;代发者零头寸,JIT 99e24 于 [-60, 60),交易内要拿出约 593,080 枚代币;数字的单位是枚代币,两种代币按价格 1 计):小费 0 做 JIT,代发者净得 **0.005001**,原有 LP 手续费 **5.05e10 wei**;小费到上限做 JIT,代发者净得 **0.030001**,原有 LP **3.03e11 wei**;小费到上限不做 JIT,代发者净得 **0**,原有 LP **0.03**。即:在这个资金量下,抬小费给无头寸的代发者多带来名义金额的 0.25%,原有 LP 几乎分不到加收。JIT 固定时,抬小费让用户少拿 2,501 ppm,仍在用户 0.5% 的余量内,所以能成交。**盈亏平衡是估算**:假设整笔交易(加 + swap + 撤)约 50 万 gas、输入币按 ETH 计——这个 gas 数是假设值,没有测量——抬到上限的小费成本是 0.00051 ETH,份额接近 100% 时名义金额约 0.2 ETH 起有利可图;份额低则按比例更高;用闪电贷筹资的 gas 不在这 50 万里 | `jit: test_fact_5a_relayerFlashJIT_noStandingLpNeeded`、`jit: test_fact_5a_relayerFlashJIT_capitalNeededByShare` |
| 诱导钱包抬高建议小费(LP 自己发高小费交易,把钱包按近期区块估的建议值顶过免征额) | **没有测;成本只有审计员的粗估。** 机制上可能:钱包建议值来自近期区块的小费分位数。**免征额的余量本来就薄**([审计] E-4):它等于当时 MetaMask 接口的 high 档、只比 medium 档高 33%;[H2a] 表 4-A 里窗口内全部用户交易(不只是 v4)的优先费 p75 是 15.1M wei、p90 是 30.0M wei,也就是**全链已有 10%–25% 的交易高于免征额**,行情稍忙、钱包按分位数给建议值就可能越线。越线一点的代价小(线性段:0.03 gwei 时加收 25 pip)。要靠自己发交易把块内中位小费长期顶到 0.12 gwei,审计员粗估约需 **8.7 ETH/天**(粗估,不是测量;我没有复算),按 §6 的收入量级不划算 | — |

**做 JIT 要多少资金**(`jit: test_fact_5a_relayerFlashJIT_capitalNeededByShare`,逐 wei 断言;同一个池:原有 LP 1e21 全区间,用户 exactIn 10e18,JIT 于 [-60, 60),小费 0 与到上限各做一次;单位是枚代币,按价格 1 计):

| JIT 流动性(相对原有 LP) | 交易内资金(两币合计,枚) | 抬小费多赚(枚) | 原有 LP 在上限处的手续费(枚;不做 JIT 时是 0.03) |
|---|---|---|---|
| 1e21(1 倍) | 5.99 | 0.0075(swap 走出 JIT 区间,停在 tick −139;含存货影响) | 0.0210 |
| 9e21(9 倍) | 53.9 | 0.0225 | 0.0030 |
| 99e21(99 倍) | 593 | 0.0247 | 0.0003 |
| 999e21(999 倍) | 5,985 | 0.02497 | 0.00003 |
| 99e24(99,000 倍) | 593,080 | 0.0249997 | 3.03e-7 |

读法:"不需要常驻头寸"属实,"不需要资金"不属实。**份额 = JIT ÷ (JIT + 原有区间内流动性)**(swap 留在 JIT 区间内时;表里 9 倍及以上都是):要 90% / 99% 份额,需约 9 / 99 倍于原有 LP 在同一窄区间 [-60, 60) 内的资金(原有 LP 1e21 在这个区间里约合 5.99 枚,所以是约 53.9 / 593 枚)。上面例子里的 99e24 要在交易内拿出约 593,080 枚,是用户 10 枚名义的约 5.9 万倍。资金须自有或闪电贷;**闪电贷路径没有测**,它的 gas 和费用也不在 50 万 gas 的假设里。原有 LP 的区间内流动性越厚,同样份额要的资金越多。"抬小费多赚"一列是小费到上限与小费为 0 两次的代发者净得之差,JIT 固定;1 倍那一行 swap 走出了 JIT 区间,两次的终点价格不同,差额里含 JIT 头寸撤出时两种代币构成不同的影响(按价格 1 计),不是纯手续费。

这两条的含义:**在有代付 / 代发流量的池子里,费率对这部分流量应视为"组装交易的人可在 [0.05%, 0.30%] 内选择,并且他拿得出多少倍于原有区间内流动性的资金,就能按上表的份额把加收拿走"**。前提不是"代发者碰巧是 LP",而是"代发者是 LP,**或**在同一笔交易里做 JIT"——后者拿得出这笔资金的代发者都做得到。名义金额低于盈亏平衡点时(5a 表里这两行各自的估算)抬小费是亏的。它与 5b 的"第三方 JIT 分走加收"是同一个机制的两面:能对准单笔交易做 JIT 的,首先是这笔交易的组装者,他不需要内存池,也不需要抢排序。

- **受影响的结构**:用户签了最小产出(或最大输入)、由他人上链的那些——4337(打包者定小费)、7702 代付、元交易 relayer。加收造成的那部分损失,上限是用户自己签的滑点余量与 0.25% 两者中较小的一个(组装者用别的手段吃掉滑点余量不在这个上限里,那不是本 Hook 带来的,见下面"为什么定为中")。
- **不受影响的结构**:意图 / filler 类。用户签的是结果,swap 由 filler 自己的交易去做,加收由 filler 承担,filler 抬小费是抬自己的成本。
- **没有验证**:4337 的 bundler 能否把 `handleOps` 包进自己的合约、在前后加撤流动性,我没有验证,审计员也没有([审计] E-1"待确认")。测试里是用"同一个测试合约先后做加流动性、swap、撤流动性,gas 价设成代发者的"来模拟的,没有跑真实的 EntryPoint 或任何真实的代付合约。
- **为什么定为"中"而不是"高"**(审计员的理由,我同意):有写死的 0.30% 上限且受用户自己签的滑点约束,不涉及本金,不影响撤资;能控制整笔交易的一方在任何池子里都能用原子夹击吃掉用户的滑点余量,Hook 没有给恶意代发者新的能力。Hook 新增的是两点:① 只改一个小费字段就能做到;② 诚实的代发者为抢排序抬小费,也会被动让用户多付。

**没有做的缓解:`hookData` 里的最高费率。** Angstrom L2 仓库后来加了"调用方在 `hookData` 里给出愿付的最高税额"([H2a] §5.1)。本 Hook 没有做,这是项目负责人在首轮审计后定的取舍:本轮不改合约逻辑,留作以后的可选项。审计员列的五条代价([审计] E-1):① 多一条回滚路径(现在 `_beforeSwap` 经 PoolManager 没有可达的回滚);② 必须做成可选,而"格式不对就忽略"等于静默失去保护;③ relayer 自己拼路由时可以不带或乱填,用户得不到保护;④ 与路由器的最小输出 / 最大输入功能重叠;⑤ 字节码变化,要重挖地址并重新审计。所以现在的缓解只有写死的上限和用户自己签的滑点限制。

### 5b. 谁能少付费

| 手段 | 结论 | 测试 |
|---|---|---|
| **LP 自己发高小费交易,把加收付给自己** | 加收的净成本 = `(1 − s) × 加收`,s 是它在区间内的流动性份额;另加协议抽成。exactOut 1e18、小费到上限、有符号实测:s = 0 → 净多付 2,511,288,244,425,626 wei(地板费率下成交成本的 0.25075%);s = 50% → 1,255,644,122,212,813(正好一半);**s = 100% → 0**。独占 LP 且协议费 0.10% 时净成本 2,513,300,041,336 wei,即加收的千分之一。也就是说**独占 LP 自己抢排序不交这笔"税"**(它只是把钱从左手付到右手),这与 H1 的 M-1 是同一个性质 | `test_5b_lpOwnHighTipSwap_netSurchargeCostByShare`、`test_5b_lpOwnHighTipSwap_soleLp_withProtocolFee` |
| **套利者自做 JIT(同一笔交易里:加流动性 → swap → 撤)** | **证实了研究员的推断([H2a] §3 第 14 项、§7-14):逃不掉。** 把价格推到同一个目标价(套利者的情形),不做 JIT 与做 9 倍于池子的 JIT 相比:原有 LP 收到的手续费**逐 wei 相同**(13,570,453,976,665,172 wei,同样位移在地板费率下是 2,256,085,145,028,377);套利者的净收支只差舍入,且对它更差(多付 2 wei、少收 1 wei)。原因:JIT 让同样的价格位移需要更大的成交额,多出来的手续费正好是 JIT 仓位自己收回的那部分 审计员把它推广成模糊测试并已落盘([审计] E-3):两个方向、目标价离现价 1–3000 tick、JIT 区间在 [-3600, 3600] 内任意(覆盖全部、部分或完全不在路径上)、JIT 流动性 1e15–1e25、exactIn / exactOut、协议费 0 / 0.05% / 0.10%,512 轮:原有 LP 的手续费不减少,攻击者两种代币的净收支都不改善(容差 1000 wei)。另有一条只生成"JIT 区间与价格路径重叠"情形的模糊(`jit: testFuzz_5b_selfJIT_onPath_neverHelps`,512 轮,每轮都断言 JIT 让同样的位移需要更大的成交额,即 JIT 确实在路径上;上一条模糊里有多少轮重叠没有统计)。**带协议费时自做 JIT 严格更差(JIT 在路径上时)**:协议按更大的总成交额抽成,包括自己和自己成交的那部分——协议费 0.10%、9 倍 JIT、目标 tick −90 时,不做 JIT 付 4.5280e18,做了付 4.5688e18(多 0.9%) | `test_5b_selfJIT_priceTarget_incumbentsGetTheSame_attackerSavesNothing`、`jit: testFuzz_5b_selfJIT_neverHelps`、`jit: testFuzz_5b_selfJIT_onPath_neverHelps`、`jit: test_5b_selfJIT_table`、`jit: test_5b_selfJIT_withProtocolFee_strictlyWorse` |
| 同上,但成交额固定(不是推到目标价) | JIT 吸收了自己那笔 swap 的 90%,只有 10% 真的与原有 LP 成交,而这 10% 上原有 LP 收到的正好是足额的 0.30%(实测 `原有 LP 手续费 ÷ 净流出 = 3,000 pip`)。**对"真正与别人成交的量"的费率降不下来**;被"省掉"的是自己和自己成交那部分,那等于没交易 | `test_5b_selfJIT_fixedNotional_fullRateOnWhatTradesAgainstOthers` |
| **第三方 JIT 夹在高小费交易前后,吃走加收** | **能,按流动性份额分走,这一点不是研究员推断覆盖的情形。** 第三方在高小费 swap 之前放进 9 倍于原有 LP 的区间内流动性、之后撤出:1e18 的 swap 在上限处的手续费约 3e15,原有 LP 只拿到 10%(299,999,999,999,999),JIT 方拿走 90%(2,699,999,999,999,999)。加、撤流动性不经过本 Hook,任何小费下都不被加收。这是 v3 / v4 的固有行为,不是本 Hook 引入的,但**加收让高小费交易对 JIT 更有吸引力(手续费最多是地板的 6 倍),"加收归原有 LP"并不成立,归的是那一刻在区间内的全部流动性**。**JIT 方只在自己区间内的那一段按份额分**:swap 走出 JIT 区间后的部分全归区间外的流动性——50e18 的 swap、9 倍 JIT 只放在 [-60, 60) 时,swap 走到 tick −452,原有 LP 保留 45.8%(68,638,355,372,084,260 / 149,999,999,999,999,999 wei),不是 10%。要对准某一笔 swap,JIT 方必须事先知道它并排在它前面。**能做到这一点的首先是这笔交易的组装者**(4337 打包者、7702 代付者、relayer:JIT 和用户的 swap 在他自己的同一笔交易里,见 §9 5a 的"没有任何头寸的 relayer"一条),对他来说不需要内存池,也不存在排序问题。对纯粹的外部第三方,Base 没有公开内存池(内部研究记录 `base-ordering-and-orderflow.md`(未随本仓库公开) §3),难度我没有评估;但这一点不能用来淡化本条,因为组装者这条路不受它限制。Angstrom L2 为此另设了 JIT 税(当前关闭);本 Hook 不处理,因为处理就要加流动性回调,那会碰"不得堵死撤流动性"这条本仓库的设计约束 | `test_fact_5b_thirdPartyJIT_takesProRataShareOfTheSurcharge`、`jit: test_fact_5b_thirdPartyJIT_partialRange` |
| 把一笔 swap 拆成多笔小额(同一交易内) | **不能更便宜。** 每一步的手续费向上取整,拆得越碎越亏(1–12 份、金额 1 wei 到 1e21、任意小费的模糊测试) | `testFuzz_5b_splittingASwap_neverCheaper` |
| 灰尘金额(1 wei 起) | 1–1,000 wei、四种 swap、任意小费:不回滚,费率照表;1 wei 的 exactIn 全部变成手续费,输出为 0 | `testFuzz_5b_dustSwaps`、`test_5b_oneWeiExactIn_isAllFee` |
| §7 的各种绕过 | 见 §7 | `test_fact_bypass_*` |

## 10. 信任假设

- **定序器按优先费排序,且没有未公开的优先通道。** 这是单一定序器的运营配置,不可验证([H2a] §7-1、§7-5);源码里就有先到先得的选项。配置一改,本 Hook 收的就只是"小费高的交易",与排序无关。
- **PoolManager 与 protocol fee controller**:协议费由 controller 按池、按方向设置,最多 0.10%,叠加在本 Hook 的 LP 费之上;Hook 拦不住也改不了。
- **没有人能调参数。** 谁也不能改地板、上限、免征额、斜率,包括部署者。最坏能"调"成什么样:调不了;环境变了之后的最坏结果见 §4 最后一条(池子退化成 0.05% 的静态池,或普通用户按最多 0.30% 付费)。
- **任何人都可以用本 Hook 建池。** 各池互不影响(Hook 没有每池可变状态,只有登记标志;`test_strangersPool_doesNotAffectOurs`、不变量套件里陌生人建的池)。
- **建池可以被抢先,初始价由抢先的人定**([审计] I-2)。Hook 没有 `beforeInitialize`,不限制谁建池、以什么价格建;一个 PoolKey 只能初始化一次,所以别人可以抢在你前面用同一个 PoolKey 以离谱的初始价建池。这是 v4 的通性,不是本 Hook 引入的,Hook 也拦不了(拦就要有管理员或白名单)。**第一个加流动性的人必须先读 slot0 核对价格**,价格不对就先用 swap 把它推回去(空池里推价不花钱)或换一个 tickSpacing 建新池;否则单边建仓会被套利。

## 11. 代币

Hook 不接触任何代币,不调用代币合约,不持有余额。

| 类型 | 态度 |
|---|---|
| 标准 ERC-20 | 支持(本地用 mock;fork 上用真实 USDC,6 位小数、代理合约:`fork: test_fork_ethUsdcPool_realUsdc_onRealManager`) |
| 原生 ETH(currency0 为零地址) | 支持(`test_nativeEthPool`、`fork: test_fork_nativeEthPool_onRealManager`) |
| 无返回值的代币 | 与本 Hook 无关(Hook 不做转账);没有测 |
| 收转账税的代币、rebasing 代币 | **Hook 既不支持也没有能力拒绝**:它看不到代币行为,建池时无法识别。这类代币在 v4 的记账下本身就有问题,不应该用来建池;没有测。建池的人自己负责 |

## 12. gas

与无 Hook 的静态费池做同一笔 swap 的差值(v4-core 测试路由,两边相同;`test/PriorityFeeHook.gas.t.sol`,`-vv` 打印):

| 场景 | 无 Hook | 有 Hook | 增量 |
|---|---|---|---|
| 本地,0→1 exactIn,小费在免征额内(对比 0.05% 静态池) | 130,262 | 138,568 | **8,306** |
| 本地,同上,1→0 exactOut | — | — | 8,306 |
| 本地,0→1 exactIn,小费到上限(对比 0.30% 静态池) | 130,262 | 138,731 | **8,469** |
| Base fork,真实 PoolManager,0→1 exactIn | 128,426 | 136,554 | **8,128** |

每笔 swap 都一样,没有"首笔更贵"的路径。增量里含对 Hook 的冷调用和一个冷 SLOAD;Hook 自身那一帧约 4.3k。**那个冷 SLOAD(约 2.1k,占增量的四分之一)买到的只是纵深防御**([审计] I-1):它读的是 `isRegistered`,用来在 `beforeSwap` 里拒绝未登记的池子;而经 PoolManager 调用时这个 revert 不可达——带本 Hook 的池子初始化时必然经过 `afterInitialize` 并登记(`afterInitialize` 权限位写在地址里)。保留它是因为工程标准要求"只服务登记过的池子",代价就是每笔 swap 这 2.1k gas。同一交易内第二次经过本池时两处冷访问会变热,那种情况**没有测**。测试路由的 gas 不等于 Universal Router 的 gas,差值才有意义。

## 13. 测试与断言对照

| 文件 | 条数 | 内容 |
|---|---|---|
| `test/PriorityFeeMath.t.sol` | 10 | 数学库:常量、饱和减法、费率表、闭式解对拍、单调性、任意 `(gasprice, basefee)`(`uint256` 全范围) |
| `test/PriorityFeeHook.t.sol` | 43 | 权限位与地址、构造函数、两个回调正常路径、10 个入口的非 PoolManager 调用、未声明回调、陌生池、非动态费池、优先费各边界、四种 swap(含协议费)与静态池逐位对拍、原生 ETH、零流动性 / 单边 / 有空档的池、tick 边界、同交易多次 swap、流动性与 donate 不经过 Hook、无状态、费率与 sender / hookData / SwapParams 无关(模糊 + 2 条定点) |
| `test/PriorityFeeHook.adversarial.t.sol` | 21 | §7、§8(a)(b)、§9 的每一条 |
| `test/PriorityFeeHook.jit.t.sol` | 7 | 审计员的 PoC 落盘:零头寸代发者的同笔 JIT(E-1)、自做 JIT 的模糊与对照表、带协议费时严格更差(E-3)、swap 走出 JIT 区间时的分成(E-2);第二轮复查后加的两条:JIT 各资金量下的份额表、只生成重叠情形的自做 JIT 模糊 |
| `test/PriorityFeeHook.quoter.t.sol` | 7 | §8(c):V4Quoter 报价与成交;不带小费字段的三种读数下报价相同 |
| `test/PriorityFeeHook.invariant.t.sol` | 1 个套件(4 条不变量 + 1 条只打印计数的 `invariant_callSummary` + 每轮结束时的 `afterInvariant` 覆盖断言)+ 2 条确定性回归测试 | 四个池(两个有流动性且可被撤空、一个始终没有流动性、一个的宽区间流动性没有动作会去撤)、任意 gas 价与 base fee、1 wei 起的四种 swap(带或不带 hookData、同一次调用里连做两笔)、加撤流动性(可撤空)、改协议费、陌生人建池(含原生 ETH、极端初始价);64 轮 × 128 步,**15 个动作里 5 个是 swap**。4 条不变量:① `invariant_feeAlwaysMatchesSchedule`——每笔成功的 swap 后 PoolManager 的 Swap 事件里的费率 = 独立重写的费率表,另一池的登记不变,Hook 不发事件,**没有任何 swap 的回滚数据是指向 Hook 的 `WrappedError`**;② `invariant_feeWithinHardBounds`——**用 Swap 事件里的实收费率**更新的最小 / 最大值:总费率在 [500, 3997],协议费为 0 时 LP 费在 [500, 3000],且每笔都落在按链上读到的协议费算出的 [total(pf, 500), total(pf, 3000)] 内(首轮审计 T-1:原来检查的是 handler 自己算的期望值,恒真;改后在临时副本里去掉封顶、或把地板改成 499,只跑这一条都会失败);③ slot0 的 LP 费恒为 500、池子保持登记;④ Hook 不持有任何代币、ERC-6909 余额或 ETH。`afterInvariant`(首轮审计 T-2:原来计数只打印不断言)在每一轮结束时断言:没有任何 swap 回滚、成功的 swap ≥ 8、swap 动作 ≥ 4、按地板 / 小费恰为 0 / 被加收 / 到上限 / gas 价低于 base fee / gas 价高于 100 gwei / 带 hookData / 带协议费 / 区间内有流动性 / 区间内流动性为 0 的 swap 各 > 0、撤流动性 > 0、陌生人建池 > 0。**哪些是保证的、哪些只是概率性的(第二轮复查后重写)**:原来的轮转按"成功 swap 数"的奇偶取类,连做两笔的动作会让计数跳过一个位置,"保证"不成立(审计员的 6 步序列:swap 数到 8 而到上限的为 0)。现在每个 swap 动作从一个独立计数器取号(不看成功 swap 数):第 0–3 号和之后的偶数号按四类 gas 环境轮转(第一圈取各类的边界:base fee 取到 2^64 以内任意值、小费恰为 0、第一个 pip、小费高于 100 gwei),第 1 号起每 4 号带 hookData,第 2 号起每 16 号给要成交的池子设非零协议费;池子按成功 swap 数取、每笔 swap 前各读一次(每 8 笔里一笔去流动性不撤的池、一笔去无流动性的池)。所以**只要有 8 笔成功的 swap(至少 4 个 swap 动作)且没有 swap 回滚,上面与 swap 有关的计数全部非零是构造保证的**——`test_regression_swapTwiceCannotSkipAnEnvironmentClass` 重放审计员的序列,`test_regression_fourSwapActionsCoverEverything` 是最短情形(4 个连做两笔的动作);审计员的序列在旧 handler 上确实是"swap 数 8、到上限 0"(临时副本里重跑过)。**仍是概率性的三项**:成功 swap ≥ 8、撤流动性 > 0、陌生人建池 > 0。若 Foundry 在 15 个动作里均匀选取(这是假设,没有对着 Foundry 源码核实;forge 打印的各动作调用次数与之相符),128 步里漏掉的概率分别约 2e-14、(13/15)^128 ≈ 1.1e-8、(12/15)^128 ≈ 4e-13,合计每轮约 1e-8、每次套件(64 轮)约 7e-7;这是算出来的,不是测出来的。改完后用 24 个不同的种子各跑一次(`--fuzz-seed`),结果见 §16 |
| `test/PriorityFeeHook.gas.t.sol` | 2 | §12 |
| `test/fork/PriorityFeeFork.t.sol` | 13 | Base 主网 fork(区块 56,228,000):真实 PoolManager 上建池、登记、各优先费下的费率、与静态池对拍、协议费(冒充真实 controller 设置)、原生 ETH、真实 USDC、真实 V4Quoter(两个方向)、撤流动性、gas |

测试里的期望值是照本文的费率表独立写的(`test/utils/PriorityFeeTestBase.sol` 的 `_expectedFee`、数学测试里的硬编码数字),没有引用被测库的常量。

**fork 测试里什么是真的、什么不是**:PoolManager、V4Quoter、USDC 是链上合约;base fee 是钉住区块的区块头值(5,000,000,最低值)。`tx.gasprice` 是用 `vm.txGasPrice` 设的。fork 测试里不设 gas 价时读到的是 (0, 5,000,000),这是测试框架的读数;真实节点对不带费用字段的 `eth_call` 报的是 (0, 0)(§8),两者都得地板。**一个 Foundry 的坑**(forge 1.9.0,写测试时发现):fork 上 `block.basefee` 在只读上下文里读到的是区块头的值,但在会改状态的调用里 `BASEFEE` 读到的是 0,除非显式调用过 `vm.fee()`;所以 fork 测试在 `setUp` 里先断言区块头的值、再用 `vm.fee` 把同一个值钉回去。也就是说 fork 测试里 Hook 读到的 base fee 是"区块头的值经 cheatcode 重新设置的",合约在真实节点上读到的 `GASPRICE` / `BASEFEE` 语义由 §8 的只读探针另行核对。新建池的协议费是 0;协议费非零的断言是冒充 controller 调 `setProtocolFee` 做的,没有经过 controller 自己的逻辑。

**首轮审计后补的变异检查**(临时副本里实际重跑,跑完确认临时副本的 `src/` 与仓库逐字节相同):审计员报告存活的两处现在都被杀死——① "`hookData` 长度为 32 时按地板":被 `testFuzz_fee_ignoresSenderHookDataAndSwapParams`、`test_fee_ignoresHookData_everyLengthAroundAWord` 和不变量套件(`fee charged != schedule`)杀死;② "`sender == tx.origin` 时按地板":被同一条模糊测试和 `test_fee_ignoresSender_includingTxOrigin` 杀死。审计员报告"只跑不变量套件时存活"的那处(gas 价高于 100 gwei 时回滚)现在只跑不变量套件也被杀死(`a swap reverted inside the hook`)。**第二轮复查后补的一处**:审计员的变异"`tx.gasprice == block.basefee` 时费率 501"(第二轮报告:只跑不变量套件时存活)——handler 的地板类加了"小费恰为 0"并排进轮转的第一圈后,在临时副本里把这处变异加进 `_beforeSwap`、只跑不变量(`--match-test invariant_`),被 `invariant_feeAlwaysMatchesSchedule` 杀死(`fee charged != schedule`)。旧 handler 在我的一次默认种子运行里也杀死了它,所以旧实现下是否存活取决于种子;新实现下第 2 个 swap 动作必然取到小费恰为 0。另外为确认 `invariant_feeWithinHardBounds` 不再空跑,做了两处变异(去掉封顶;地板改 499),只跑这一条不变量,都失败。工程师最初自报的 23 处没有在这一轮重跑。

**最初的变异检查**(临时副本里,23 处,只跑本 Hook 的离线测试;首轮审计前做的,审计员没有重跑):21 处被杀死,2 处存活,都是等价变异——`tip <= TIP_ALLOWANCE` 改成 `<`(等于免征额时两条路径都得 0)、封顶比较 `<` 改成 `<=`(相等时两个分支取值相同)。被杀死的包括:去掉饱和(两种写法)、四个常量各 ±1、去掉封顶、加收改向上取整、去掉覆盖标志位、接受静态费池、服务未登记的池、不设 slot0 费率、gas 价与 base fee 调换、忽略 base fee、返回非零 delta、视图函数写错。覆盖最薄的几处:静态费池被拒、返回非零 delta、不发事件这 3 处各只有 1 条测试能杀死;`afterInitialize` 返回错的 selector 是被 PoolManager 自己的检查拦下的(所有夹具的 `setUp` 都失败),不是被专门的测试。

## 14. 已知局限

1. **收不到多少**(§6);参数未回测。
2. **报价不含加收**,最大差约 0.25%;按报价留 0.1% / 0.25% 余量的订单在上限处回滚,0.5% 可成交;不带小费字段的报价恒按地板(§8c)。
3. **代付 / 代发流量的费率由组装交易的人决定;他是 LP、或在同一笔交易里做 JIT(不需要常驻头寸,但需要资金),名义金额高于盈亏平衡点时抬小费就获利**(独占 LP、20 万 gas 约 0.08 ETH;JIT 按假设的 50 万 gas、份额接近 100% 估算约 0.2 ETH;低于它是亏的)。JIT 的份额 = JIT ÷ (JIT + 原有区间内流动性),要 90% / 99% 份额需约 9 / 99 倍于原有 LP 在同一窄区间内的资金(自有或闪电贷,闪电贷路径没有测);份额做得上去时,加收大部分归他而不是原有 LP(§9 5a 的资金表;与第 6 条是同一机制)。没有做 `hookData` 最高费率这项缓解(§9 5a 末尾)。
4. **信号混淆**:优先费高不等于套利者。默认小费偏高的终端用户、急着成交的用户、签了偏高 `gasPrice` 的 legacy 交易都会被加收;反过来条件交易跟进者、L1 存款交易、没有对手的套利不被加收(§4、§7)。
5. **独占 LP 或大份额 LP 自己抢排序,加收大部分回到自己手里**(§9 5b)。
6. **第三方 JIT 可以按份额分走加收**,本 Hook 不处理(§9 5b)。能对准单笔交易做 JIT 的首先是交易的组装者(第 3 条)。
7. **按费率不按金额**:加收与名义金额成正比,与出价的对应关系因交易大小而异(§5)。
8. **同一交易多次 swap 每次都收**(§8b)。
9. **不可调**:免征额、斜率、上限都是今天的工程起点。Base 改费用机制、钱包改默认小费、Everest 激活(coinbase tip、按 gas limit 计费)之后会失准,只能重新部署一个新 Hook、迁移流动性。
10. **依赖单一定序器遵守排序规则**(§10)。
11. slot0 里的 LP 费恒为 500,**不代表下一笔的费率**;链下只读 slot0 的工具会低估。
12. **免征额余量薄**:全链已有 10%–25% 的交易优先费高于免征额([H2a] 表 4-A 的 p75 15.1M、p90 30.0M wei),行情稍忙普通用户就会越线(§9 5a)。
13. **建池可被抢先、初始价由抢先者定**(v4 通性);第一个 LP 要先核对 slot0 的价格(§10)。

## 15. 没做 / 没验证

- 参数没有回测;没有估算任何池子的收入。
- 没有重新抽样核对 [H2a] 的任何分布数字;§4、§6 的数字全部是引用。
- 没有用 Universal Router、PositionManager、真实的 4337 EntryPoint、真实签名交易测过;滑点回滚用的是自写的最小测试路由。
- "存款交易里 `tx.gasprice` = 0"只有源码依据([H2a] §7-7),测试里是把 gas 价设成 0 来模拟的。
- 条件交易的排序行为没有在测试里复现(单元测试复现不了排序)。
- 纯外部第三方(不是交易组装者)在 Base 上对准单笔交易做 JIT 的可行性没有评估。
- "bundler 能否把 `handleOps` 包进自己的合约做 JIT"没有验证;零头寸代发者做 JIT 的测试是在测试合约里模拟的,没有真实的 EntryPoint / 代付合约。
- "名义约 0.2 ETH 起有利可图"按假设的 50 万 gas 估算,整笔交易的 gas 没有测量;独占 LP 的 0.08 ETH 同样按假设的 20 万 gas。
- JIT 的资金用闪电贷筹的路径没有测(测试里代发者直接持有代币);闪电贷的 gas 和费用不在任何盈亏平衡估算里。
- `testFuzz_5b_selfJIT_neverHelps` 里 JIT 区间与价格路径重叠的轮数没有统计(模糊测试跨轮不留状态);重叠情形由另一条模糊单独覆盖。
- 不变量套件的覆盖断言里"成功 swap ≥ 8、撤流动性 > 0、陌生人建池 > 0"是概率性的,漏掉的概率是按"Foundry 均匀选动作"这个假设算的(§13)。
- "诱导钱包建议值"这条操纵没有测;成本只有审计员的粗估(约 8.7 ETH/天),没有复算。
- §4 里"约 5 笔 / 约 2 笔"的拆分是从表 4-B 的百分比反推的,不是研究员的原始数据。
- 工程师最初自报的 23 处变异在首轮审计后没有重跑(只重跑了审计员点名的 3 处和为 T-1 新做的 2 处)。
- 同一交易内第二次经过本池的 gas 没有测。
- `[H2a]` §2.3 ③ 的读数与我的探针、审计员的探针都不一致,原因没有查(§8)。
- 收税代币、rebasing 代币、无返回值代币没有测。
- 部署脚本是整理公开仓库时后补的(`script/DeployPriorityFeeHook.s.sol`),**未经审计,只在本地 Base fork 上跑过**(`test/fork/DeployScripts.t.sol`、`script/verify-deploy-local.sh`);没有部署到任何公共网络。
- 经过真实 swap 的 gas 价 / base fee 模糊测试范围受 Foundry 限制在 2^64 以内(§3)。

## 16. 审计状态

**两轮 AI agent 内部审计(`audits/audit-hooks-h2.md`,第二轮窄范围复查附在其末尾):合约逻辑无需改;第二轮只剩措辞,已改,由项目负责人核对,审计员未再复看;不等于外部审计;未经外部审计不要用于主网资金。**

- 首轮(PoC 在 `audits/audit-hooks-h2/AuditH2.t.sol`),结论"修完再审":合约代码没有需要改的问题(无严重 / 高 / 中);要改的是文档、测试和注释。
- 首轮之后改了什么:`src/` 下只改了 `src/libraries/PriorityFeeMath.sol` 里 `priorityFee` 的注释(T-5),合约逻辑没有动;`bytecode_hash = "none"`,改前改后 `forge inspect PriorityFeeHook bytecode` 的 sha256 都是 d37f4d49…8cfe9799,挖矿脚本仍给出 salt 2403 / `0xBeb0026Aa9eF43478b921106D56Ebc7b1eD75080`。文档与测试:E-1(本文"用之前先看"第 3 条、§9 5a、§14 第 3 条,事实测试 `jit: test_fact_5a_relayerFlashJIT_noStandingLpNeeded`)、T-1 / T-2(不变量套件)、T-3(模糊)、T-4(JIT 模糊落盘)、T-5((0, 0) 的统一表述)、T-6(真实 Quoter 的 1→0)、§4 的推算标注、E-4、I-1、I-2。
- 第二轮(窄范围复查,附在同一份报告末尾):合约逻辑无变化,只剩措辞和测试说明。第二轮之后改了什么(**`src/` 一个字节没动**,五个源文件的 sha256 与复查时相同):① "抬小费就是赚钱的"加了盈亏平衡条件;② JIT 需要的资金量写明,加了资金表和事实测试 `jit: test_fact_5a_relayerFlashJIT_capitalNeededByShare`;③ 不变量套件:动作数更正为 15,轮转换成独立计数器并加了两条确定性回归测试,概率的说法照实重写,地板类加了"小费恰为 0",`afterInvariant` 补了五项断言,`swapsInEmptyPool` 改名为 `swapsAtZeroActiveLiquidity`;④ 加了只生成重叠情形的自做 JIT 模糊;⑤ 几处措辞限定(损失上限、带协议费时严格更差、§2 的两条路)。
- 第二轮之后的修改**没有再经审计员看过**,由项目负责人核对。改完后:不变量套件用 24 个不同的种子(`--fuzz-seed`)各跑一次,24 次全过(每次 64 轮 × 128 步);各次最后一轮的计数:成功 swap 40–66 笔、回滚 0 笔、被加收 15–37 笔、到上限 6–19 笔。
- 没有采纳、只写明的:`hookData` 最高费率(§9 5a 末尾,项目负责人定,留作以后的可选项)。
- H1 的经验是"工程师自报的结论在审计员用自己的 PoC 打过之前不算数";第二轮之后这批修改没有经过这一步。
