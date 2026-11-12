> **AI agent(研究员岗位)整理的事实表的公开副本,不是审计,也未经第三方复核。** 文中自报"未核实""估算""二手"的标注原样保留,引用前请自行核对出处。与整理时的原件相比,公开副本做了两类改动:① 路径与称谓清理(内部角色 "CEO" 改称"项目负责人";`research/…` 路径改成本仓库内的路径;内部项目编号和内部规则的称呼改成中性说法);② 发布前审查后,删去或改写了几处对具名第三方项目的未核实推断和内部评语,并在涉及第三方项目的章节前加了一句声明。事实读数和出处没有改。

# Base 块内优先费排序 —— "优先费归 LP" Hook 的前提核实

> **勘误(2026-11-11,项目负责人根据 `audits/audit-hooks-h2.md` 第三节补记):** §2.3 ③ 记"不带费用字段的 `eth_call` 读到 (GASPRICE, BASEFEE) = (0, 5,000,000)",Hook 工程师和 Hook 审计员各自在 Base 公共节点上复测(区块 56,260,402 与 56,264,677)读到的都是 **(0, 0)**,原读数不可复现。因此 §2.6 和 §6.3-1 里"无保护减法会让普通报价全部回滚"的推论在当前节点上不成立;它只在显式给了低于 base fee 的 `gasPrice` 时成立,存款交易那一半仍只有源码依据。"Quoter / 不带费用字段的调用读到的优先费是 0"这一结论不受影响。原文未改动。


- 调研日期:2026-11-11(UTC 约 22:40–23:30)。链上读数取自 Base 主网(chainId 8453)区块 53,556,127 – 56,242,755;各条读数的具体区块号写在该条里。
- 全部为只读调用(`eth_getBlockByNumber`、`eth_getBlockReceipts`、`eth_call`、`eth_feeHistory`),没有发送任何交易。公共 RPC `https://mainnet.base.org`,节点自报 `reth/v2.5.2-9e380dd/…/base/v1.5.4`。
- 适用对象:项目负责人(H2 是否开工)、`hook-engineer`(边界情况)、`hook-auditor`(攻击面)。
- 本文只补充 `base-ordering-and-orderflow.md`(下称 [ORDFS])、`base-dex-pools.md` §5(下称 [POOLFS])、`uniswap-v4-hooks-base.md`(下称 [HOOKFS])、`validity-tx/RESULTS.md`(下称 [VTRES])没有的内容;已有结论只引用,不重复。
- 要核实的 Hook:`beforeSwap` 里读 `tx.gasprice − block.basefee`,用它覆盖本笔 LP 费;不用 return delta,不代持资金。

单位约定:优先费一律写成"每 gas 的 wei";1,000,000 wei = 0.001 gwei。Base 当前最低 base fee 是 5,000,000 wei(0.005 gwei)。

核实标记(与 [ORDFS] 相同):**文档** = 官方文档明文;**源码** = 指定 commit 的文件;**实测** = 我在上述日期用只读 RPC 测到;**推断** = 我的推理;**未核实** = 集中列在 §7。

## 0. 出处索引

| 代号 | 出处 |
|---|---|
| [ORD] | Base 官方文档 Transaction Ordering:https://docs.base.org/specifications/transactions/transaction-ordering (2026-11-11 重新抓取) |
| [FEES] | Network Fees:https://docs.base.org/specifications/transactions/network-fees |
| [VT] / [VT-SAFE] | Validity Transactions:https://docs.base.org/specifications/build-transaction/validity-transactions ;Predicates and Safety:https://docs.base.org/specifications/build-transaction/predicates-and-safety |
| [PREDEPLOY] | Base 协议规范 Predeploys:https://docs.base.org/base-chain/specs/protocol/execution/evm/predeploys (`specs.base.org/protocol/execution/evm/predeploys` 301 跳到这里) |
| [EVEREST] | Everest 升级概览:https://docs.base.org/upgrades/everest/overview |
| [SRC] | `base/base` 仓库 main,commit `8e4fc35787e1ea51ca4185e14ac52d1ae27a95be`(2026-11-11 12:28 UTC):https://github.com/base/base 。注意:[ORDFS] 用的是同一天更早的 commit `39478b48`;本文引用的文件我都在 `8e4fc357` 上重新读过。仓库代码是"能这样配置",不等于生产定序器就是这样配置,除非另有文档或实测印证。 |
| [ANG-SRC] | `SorellaLabs/l2-angstrom` main,commit `81bd4189f4f86346c915e9e8c80bb98b9b52b123`(2026-09-24):https://github.com/SorellaLabs/l2-angstrom (许可证:Business Source License 1.1,只读不抄) |
| [ANG-DEPLOYED] | 已部署 Hook 的验证源码:Sourcify `https://sourcify.dev/server/v2/contract/8453/0x631352aaa9d6554848af674106bcd8bb9e59a5cf?fields=compilation,sources`(runtime match,2026-04-11 验证,solc 0.8.26,`src/AngstromL2.sol:AngstromL2`) |
| [PARADIGM] | Dan Robinson、Dave White,"Priority Is All You Need",2024-06-04:https://www.paradigm.xyz/2024/06/priority-is-all-you-need |
| [EIP-4337] / [EIP-7702] | https://eips.ethereum.org/EIPS/eip-4337 ;https://eips.ethereum.org/EIPS/eip-7702 |
| [MM-GAS] | MetaMask 公开的 gas 建议接口(Base):`https://gas.api.cx.metamask.io/networks/8453/suggestedGasFees`(动态值,下文数字是 2026-11-11 约 23:00 UTC 的一次读数) |
| [链上] | 本次对公共 RPC 的只读调用;复现方法见附录 A |

---

## 1. Denim 之后,块内是否仍按 priority fee 排序

### 1.1 文档与源码(升级后重新核对)

- **文档**:[ORD] 现行页面仍写 "transactions within each block are ordered by priority fee",并写 "Base builds a complete canonical block every 200ms"。该页没有提到系统交易、同发送者 nonce、同价决胜这些例外;对条件交易只写了 "competes for inclusion only after every predicate matches"。
- **源码**(排序键,与 [ORDFS] §1.2 一致,未变):默认 `BaseOrdering::coinbase_tip()` = `UnifiedTipOrdering`,按每 gas 小费排;同价时谓词少者优先,再按到达时间、交易哈希。[SRC] `crates/execution/txpool/src/ordering.rs` L1–5、L20–28、L158–211。
- **源码**(Denim 之后的新事实,[ORDFS] §8-5 当时列为未核实):
  - 构建一个区块时,交易池在开始那一刻**做快照**,构建期间新到的交易等下一个块。原文注释:"The pool snapshots every store here, so mid-build arrivals wait for the next block."([SRC] `crates/execution/payload/src/builder.rs` L320–321)。"Post-Denim the payload is built once"(同文件 L1066–1068)。
  - 条件交易(Validity Transactions)在谓词不满足时被"停放";块内某笔已提交的交易改动了它监视的状态后,它被"提升"回候选队列,**按自己的出价排在剩余候选里**。原文:"a commit that changed the state their predicate reads promotes them so the scan evaluates them at their priority position."(同文件 L1570–1575)
  - 含义(推断):一个块 = "快照里按小费降序扫一遍",加上"被块内交易唤醒的条件交易按各自小费插进尚未执行的那部分"。所以**高小费的交易可以合法地出现在低小费交易之后**,只要它是被前面某笔交易唤醒的条件交易。

### 1.2 抽样(实测)

**方法**(复现见附录 A.1):

- 总体:Denim 激活后的全部区块。激活时刻 2026-11-05 18:00:00 UTC = 时间戳 1,793,901,600;区块 53,556,126 的时间戳是 1,793,901,599(升级前最后一块,`extraData` 分母还是 100),所以取 **[53,556,127, 56,234,000]**(约 268 万个块,6.2 天)。
- 抽样:Python `random.seed(20261111)`,`random.sample(range(53556127, 56234001), 2000)`,简单随机、不放回,共 2,000 个区块;逐块 `eth_getBlockByNumber(n, true)`。
- 每笔交易的有效优先费 = 交易对象里的 `gasPrice`(已上链交易的这个字段是有效 gas 价)− 区块 `baseFeePerGas`。全样本没有出现负值。
- 剔除类型 `0x7e` 的存款交易(系统交易)。2,000 个块里每块的 `tx[0]`、`tx[1]` 都是 `0x7e`;另有 8 笔 `0x7e` 出现在 `tx[2]`/`tx[3]`(6 个块在位置 2 有一笔,其中 2 个块在位置 3 还有一笔;8 笔里 5 笔发往跨链信使 `0x4200…0007`,3 笔发往其他地址),即从 L1 发起的存款交易,全部排在普通交易之前,样本里没有出现存款交易排在普通交易之后的情况(见 §3 第 8 项)。
- 判定:块内相邻两笔用户交易,后一笔的优先费**严格大于**前一笔记为"递增对"(违例);相等不算。

**结果**:

| 指标 | 数值 |
|---|---|
| 抽到的区块 | 2,000 |
| 其中含 ≥ 2 笔用户交易的区块 | **1,996**(另有 3 个块 0 笔、1 个块 1 笔) |
| 用户交易总数 / 每块中位数 / 90 分位 / 最大 | 36,558 / 14 / 32 / 306 |
| 交易类型 | `0x2` 34,547;`0x0` 1,808;`0x4`(EIP-7702)112;`0x1` 91 |
| 相邻交易对 | 34,561 |
| **非递增的相邻对** | **34,255(99.11%)** |
| 递增对(违例) | 306(0.89%),分布在 188 个区块(9.4%) |
| 其中:后一笔的发送者在本块更靠前处已有交易(同一发送者 nonce 顺序) | 192 对(其中 191 对是紧邻的同一发送者且 nonce 恰好 +1) |
| 其中:**不能用同发送者 nonce 解释的** | **114 对(0.33%)**,分布在 101 个区块(5.1%) |
| 块内第一笔用户交易的优先费 = 全块最高 | 1,945 / 1,996(97.4%) |
| "被超车"的交易:其后存在一笔优先费严格更高、且发送者此前在本块没有交易的交易 | 1,549 / 36,557(4.2%) |

按天(以激活时刻为第 0 天起点,每 24 小时一段;列为:含多笔交易的块数 / 相邻对 / 递增对 / 有递增对的块数):

| 第 0 天 | 第 1 天 | 第 2 天 | 第 3 天 | 第 4 天 | 第 5 天 | 第 6 天(不足一天) |
|---|---|---|---|---|---|---|
| 324 / 6,800 / 62 / 47 | 323 / 3,935 / 19 / 18 | 327 / 3,530 / 13 / 12 | 335 / 8,121 / 111 / 54 | 304 / 5,655 / 63 / 31 | 319 / 5,502 / 33 / 21 | 64 / 1,018 / 5 / 5 |

每一天的递增对占比都在 0.4%–1.4% 之间;[ORDFS] §6 提到升级后第一周有打包延迟事故(11-09 标记解决),前后几天没有看到排序规律上的差别。

第二个独立样本(§4 的 60 个连续 100 块窗口,6,000 个块,区块 55,238,200–56,227,399,2026-11-09 15:26 – 11-11 22:24 UTC):115,936 个相邻对里递增对 680 个(0.59%),其中 550 个可由同发送者 nonce 顺序解释,其余 130 个(0.11%)。两个样本的违例率不同(0.89% 对 0.59%;不可解释部分 0.33% 对 0.11%),量级一致;这个样本是成簇抽的,窗口之间差异大,不宜与上表逐项比较)。

### 1.3 例外是什么

**(a) 系统交易。** 每块 `tx[0]`(L1 信息)、`tx[1]`(BaseTime)是 `0x7e` 存款交易,gas 价为 0,不参与排序(与 [ORDFS] §1.1 一致)。用户从 L1 发起的存款交易也是 `0x7e`,排在所有普通交易之前(样本中 8 笔)。

**(b) 同一发送者的 nonce 顺序(192 对,占违例的 63%)。** 同一地址的后一个 nonce 即使小费更高,也只能排在前一个 nonce 之后。例:区块 54,971,486,发送者 `0x3cb6ad09…c08a`,nonce 8,365,626 小费 0,紧接着 nonce 8,365,627 小费 5,000,000(交易 `0x4b52ac20…e904a`)。这类不影响"想靠前就得出高价":要让第一笔靠前,第一笔自己必须出高价。

**(c) 其余 114 对:与"被块内前序交易唤醒的条件交易"的特征一致,但链上无法直接证明。** 谓词不上链([VT]:"They do not appear in the resulting onchain transaction"),所以我只能给间接证据:

- 形态:114 对里 87 对是"单笔插入"(插入的那笔之后,小费立刻回落到插入点之前的水平以下);27 对之后跟着一串来自多个发送者、彼此之间仍按小费降序的交易。
- 位置:分布在块内各处(相对位置的四分位数 0.30 / 0.54 / 0.71),不集中在块尾。
- 关联:我取了这 101 个块的全部回执,**114 笔插入交易里有 67 笔(59%)与紧挨着的前一笔交易触及了同一个发日志的合约**(不计 WETH 和 USDC);同样这 101 个块里,其余 4,017 对"不同发送者、未违例"的相邻交易,这个比例是 384 对(9.6%)。
- 例 1(单笔插入):区块 53,790,635,块内最后一笔 `0x44f162b6…d9028`,小费 1,200,000,000(1.2 gwei),排在一笔小费 1,000,000 的交易之后。
- 例 2(成串):区块 55,356,049,用户交易第 1–7 笔小费从 20,200,000 降到 3,493,435;第 7 笔是一笔发往 `0xcaf22ce3…7c67`、选择器 `0x3593564c` 的交易(`0xd8331d94…b96d`);紧接着第 8 笔 `0xed92637c…2d29` 小费 16,100,000,000(16.1 gwei),之后 19 笔来自不同发送者的交易从 3.8 gwei 一路降到 62,799,999,然后才回到 1,150,000 及以下。即"前半段降序 → 一笔交易之后插入一段新的降序 → 回到原来的降序"。
- 与 [VTRES] 的测试网结果吻合:条件交易"小费高于触发交易时排在触发交易的正后方"(A 组 17/17)、多笔被同时唤醒时"严格按小费"(补充实验 2,18/18)。
- 114 对里有 18 对的差额极小(不到 1% 或不到 10,000 wei),其中有类型 `0x0` 的交易。推断:可能是交易池排序用的 base fee 与本块实际 base fee 有细微出入(对"小费上限由 `maxFeePerGas` 卡住"的交易会改变相对次序),我没有验证。
- 还有哪些机制可能产生这类例外、我没有逐一排除:发送者余额在块内才够(被前序交易充值)、资源计量导致的延后([SRC] `builder.rs` 里有 deferral / resource metering 逻辑)。见 §7-2。

**(d) 没有观察到的:** 没有看到"低小费交易排在整块最前面"的系统性现象(第一笔用户交易是全块最高价的占 97.4%;其余 51 个块我没有逐个追查原因,见 §7-3)。

### 1.4 小结(事实)

- Denim 之后块内仍按优先费降序:相邻对 99.11% 非递增;剔除同发送者 nonce 顺序后,剩余违例 0.33%。
- 剩余违例的形态与条件交易"被唤醒后按自己的小费插入剩余队列"一致。也就是说:**"块内位置靠前"与"优先费高"不是一一对应的 —— 位置在触发交易之后的交易可以有任意高的小费;但"想排在同一批竞争者前面就得出更高的小费"仍然成立。**
- 同一样本里 base fee 的状况:2,000 个块里 1,691 个(84.6%)正好等于最低值 5,000,000 wei,99 分位 6,892,599,最大 33,711,616。区块 gas 用量中位数 2.73M,超过 8M 目标的 161 块(8.1%),接近 40M 上限(≥ 39M)的 4 块。

---

## 2. 合约里 `tx.gasprice`、`block.basefee` 的精确语义

| # | 事实 | 标记与出处 |
|---|---|---|
| 2.1 | `GASPRICE`(`tx.gasprice`)返回交易的**有效 gas 价**:类型 `0x2`/`0x4` 是 `min(maxFeePerGas, baseFee + maxPriorityFeePerGas)`;类型 `0x0`/`0x1` 是签名里的 `gasPrice` 本身。 | 源码:[SRC] `crates/common/evm/src/transaction/core.rs` L211–222(`effective_gas_price`,注释 "what the `GASPRICE` opcode reports" 在 L337–338)。实测:见 2.3 |
| 2.2 | `BASEFEE`(`block.basefee`)是本块区块头的 `baseFeePerGas`。同一个块内所有交易读到的值相同。 | 实测:见 2.3;区块头字段见 [FEES] |
| 2.3 | **实测**(区块 ≈ 56,235,900,`eth_call`,无 `to`,`data = 0x3a5f524860205260405ff3`,即返回 `GASPRICE` 和 `BASEFEE` 两个字;`from` 用 WETH 合约地址以保证余额够):<br>① `maxFeePerGas = 1 gwei`、`maxPriorityFeePerGas = 123,456` → 返回 `(5,123,456, 5,000,000)`,差值正好 123,456;<br>② `gasPrice = 10,000,000`(legacy)→ `(10,000,000, 5,000,000)`,差值 5,000,000;<br>③ **不带任何费用字段 → `(0, 5,000,000)`**,即 `tx.gasprice < block.basefee`。 | 实测 [链上]。这是公共节点 `eth_call` 的行为,不是链上交易;与 2.1 的源码一致 |
| 2.4 | 所以对普通交易,`tx.gasprice − block.basefee` **就是该交易每 gas 实付给定序器的优先费**,与回执里的 `effectiveGasPrice − baseFeePerGas` 相同,也与交易池排序用的量相同(§1.1)。legacy 交易没有单独的小费字段,`gasPrice` 高出 base fee 的部分全部算小费。 | 2.1 + 2.3 + [SRC] `ordering.rs` L196–209(排序用 `effective_tip_per_gas(base_fee)`) |
| 2.5 | **存款交易(`0x7e`)的 gas 价为 0**:`effective_gas_price` 恒返回 0。合约在存款交易里读到 `tx.gasprice = 0 < block.basefee`。 | 源码:[SRC] `crates/common/consensus/src/transaction/deposit.rs` L225–247;`core.rs` L213–215。[ANG-SRC] `src/AngstromL2.sol` L662–663 的注释也写明这一点 |
| 2.6 | **`tx.gasprice` 可以小于 `block.basefee`**,出现在:不带费用字段的 `eth_call` / `eth_estimateGas`(2.3 ③)和存款交易(2.5)。Solidity 0.8 的 `tx.gasprice - block.basefee` 在这两种情况下会算术下溢而 revert。 | 实测 + 源码。旁证:已部署的 Angstrom L2 Hook 用的是不带保护的减法([ANG-DEPLOYED] `src/AngstromL2.sol` L651、L656),仓库 main 已改成 `tx.gasprice > block.basefee ? … : 0`([ANG-SRC] L664–666) |
| 2.7 | **L1 数据费不进入 `tx.gasprice`。** 它在执行前后由处理器单独从付款方余额扣除,转入 `L1FeeVault`;回执里是单独的 `l1Fee` 字段。 | 源码:[SRC] `crates/common/evm/src/handler.rs` L334–360(`l1_cost` → `Predeploys::L1_FEE_VAULT`)。文档:[FEES] `totalFee = gasUsed * (baseFee + priorityFee) + l1Fee + operatorFee`;[PREDEPLOY] "The `L1FeeVault` predeploy receives the L1 portion of the transaction fees." |
| 2.8 | **operator fee 也不进入 `tx.gasprice`**,单独扣、转入 `OperatorFeeVault`。**当前为 0**:`L1Block(0x4200…0015).operatorFeeScalar()` = 0、`operatorFeeConstant()` = 0;`GasPriceOracle(0x4200…000F).getOperatorFee(200000)` = 0。 | 源码:同上 L345–360。实测 [链上] 区块 ≈ 56,235,900。参数在链上可改 |
| 2.9 | 优先费的去向:`SequencerFeeVault`(`0x4200000000000000000000000000000000000011`),它就是 `block.coinbase`。base fee 不销毁,进 `BaseFeeVault`。 | 文档:[PREDEPLOY] "The `SequencerFeeVault` accumulates any transaction priority fee and is the value of `block.coinbase`."实测:区块 56,234,196 的 `miner` = `0x4200…0011` |
| 2.10 | **最低 base fee**:5,000,000 wei(0.005 gwei),写在每块 `extraData` 里(`0x01000003e80000000500000000004c4b40`,末 8 字节 `0x4c4b40` = 5,000,000)。"This value may be periodically adjusted"。2026 年内已从 1,000,000 调到 5,000,000([ORDFS] §6)。 | 文档 [FEES];实测区块 56,234,196 |
| 2.11 | **没有最低优先费。** [FEES] 没有写任何下限。实测:§1.2 样本的 36,558 笔用户交易里 1,847 笔(5.05%)优先费为 0,照样上链。 | 文档(反向:没找到)+ 实测 |
| 2.12 | **节点建议的优先费有 1,000,000 wei 的地板**:`eth_maxPriorityFeePerGas` 当时返回 `0xf4240` = 1,000,000;`eth_gasPrice` 返回 6,000,000(= base fee + 1,000,000)。源码默认值 `DEFAULT_MIN_SUGGESTED_PRIORITY_FEE = 1_000_000`。这只是建议值,不是准入门槛。 | 实测 [链上];源码 [SRC] `crates/execution/rpc/src/eth/mod.rs` L322,`crates/execution/node/src/args.rs` L550 |
| 2.13 | base fee 每块最多 +0.4% / −0.1%,翻倍至少约 35 秒([ORDFS] §1.4)。推断:块突然变满时 base fee 来不及涨,**短时间内的拥堵价格体现在优先费上**。 | 文档 [FEES];后半句是推断 |
| 2.14 | 同一笔交易里的所有 swap(多跳、聚合器拆单、4337 批量)读到的 `tx.gasprice` 和 `block.basefee` 都相同。 | 由 2.1、2.2 直接得出 |

未来变化(源码里已有、主网未激活,见 §3 第 9 项):Everest 的 EIP-8130 交易在 `GASPRICE` 上仍报 EIP-1559 口径的有效 gas 价([SRC] `core.rs` L216–221、L467–472 的测试),但它另有一种**不经过 gas 价的"coinbase tip"**参与排序。

---

## 3. 绕过方式:不付高优先费却排在前面 / 紧跟某笔交易

"逃税" = 套利者拿到了位置但 Hook 读到的优先费低;"误收" = 普通用户没有抢位置却被读到高优先费。

| # | 途径 | 事实 | 对"按优先费收费"的影响 |
|---|---|---|---|
| 1 | **条件交易(Validity Transactions)同块跟进** | 文档:谓词在"交易即将执行前"求值,前序交易改了被监视的状态后"can then become eligible in the same block"[VT-SAFE]。源码:被唤醒后按自己的小费进入剩余队列(§1.1)。测试网实测:小费只有触发交易一半的跟进单 9/9 同块且紧贴;多个跟进者之间严格按小费;谓词变假的输家不上链不付费 [VTRES]。主网抽样:§1.3(c)。 | **部分逃税。** 跟进者不需要出价高过触发交易,也不需要高过块里排在触发交易之前的任何人;只需要高过"同时被唤醒、抢同一机会的其他跟进者"。只有一个跟进者时可以按最低小费成交,Hook 收不到钱。有多个竞争者时,它们之间仍然拼小费,Hook 仍能收到(§5.3 的理论前提是"竞争",不是"块首")。另一面:**被唤醒的一串交易可以带着极高的小费出现在块中部**(§1.3 例 2 的 16.1 gwei),只按"块内位置"推断谁是套利者会错。 |
| 2 | **定序器私下通道 / 特权排序** | 没有找到任何公开的私下通道、bundle 或订单流拍卖入口([ORDFS] §3.2,本次未发现新资料)。Base 只有一个定序器,排序规则是它的配置;源码里另有先到先得的 `TimestampOrdering` 选项([SRC] `ordering.rs` L251 起;`docs/guides/P2P.md` L723 写 `--rollup.txpool-ordering` 可选 `coinbase-tip` 或 `timestamp`)。 | **无法从链上排除**;若存在则是逃税。[PARADIGM] 明确把"出块者严格遵守规则"列为前提,并写 "MEV taxes are not incentive-compatible for a monopolistic block proposer"。属于信任假设,列入 §7-5。 |
| 3 | **打包器 / bundle** | Base 没有搜索者 bundle 接口([ORDFS] §3.2、§5)。原子性只能靠单笔交易内的合约逻辑。 | 当前无影响。 |
| 4 | **把 swap 包在别人的交易里:聚合器 / 路由合约** | `tx.gasprice` 是整笔交易的属性,与调用层级无关(§2.14)。用户自己签名发交易、经聚合器合约进池子时,读到的仍是用户自己设的小费。 | 不逃税也不误收。但 Hook 分不清"谁"在交易:`sender` 是路由合约([HOOKFS] §4.4)。 |
| 5 | **代发类:意图 / 限价单 / "免 gas 兑换"由第三方 filler 或 relayer 上链** | 交易由 filler 签名并出小费;用户没有设过小费。(哪些产品在 Base 的 v4 池上这样做,我没有逐个核实,§7-8。) | **误收方向**:filler 为了抢单而出的高小费会抬高这笔 swap 的 LP 费,成本最终落在用户的成交价或 filler 的利润上。filler 之间抢单本身是一种竞争,对它收费是否算"误收"取决于设计意图。 |
| 6 | **ERC-4337(账户抽象)** | [EIP-4337]:"bundlers package up a set of these objects into a transaction making a `handleOps` call to a special contract";UserOperation 自带的 `maxFeePerGas` / `maxPriorityFeePerGas` 是它自己的字段("similar to EIP-1559"),收上来的费用付给 bundler 指定的 beneficiary。由此得出(推断,EIP 正文没有直接写 `tx.gasprice`):合约里读到的 `tx.gasprice` 是 **bundler 那笔 `handleOps` 交易的**,与 UserOperation 里填的小费无关;同一个 bundle 里所有 UserOperation 读到同一个值(§2.14)。实测(§4):带 `UserOperationEvent` 的 v4 swap 交易,优先费全部贴着节点建议值:173 笔里中位数 1,000,000、最大 1,820,000,没有一笔超过 0.01 gwei;同一批窗口里全部 4,700 笔带 `UserOperationEvent` 的交易(不限 v4),中位数 1,150,000、99 分位 30,460,000、最大 1.326 gwei。 | **既不能用来抢位置,也可能双向错配。** 想靠前,bundler 的交易本身必须出高小费,所以它不是逃税通道。错配:用户愿付多少与 Hook 读到的值无关 —— bundler 出低价时(样本里的现状)用户不会被加收;bundler 若为某个 UserOperation 抬价,同 bundle 里其他人的 swap 一起被加收。 |
| 7 | **EIP-7702(类型 `0x4`)** | 交易发送者(付 gas 的人)可以不是被授权的账户:"account X pays for a transaction on behalf of account Y" [EIP-7702]。`tx.gasprice` 是外层那笔交易的。§1.2 样本里 `0x4` 占用户交易的 0.31%(112 / 36,558)。 | 与第 5、6 项相同:读到的是代付者的小费。不是抢位置的通道。 |
| 8 | **从 L1 发起的存款交易(`0x7e`)** | gas 价恒为 0(§2.5),且排在块内所有普通交易之前(§1.2:2,000 个块里 8 笔)。 | **逃税,而且是"块首 + 零优先费"。** 代价是要付 L1 gas、落块时刻由 L1 决定,不适合拼延迟的套利;对不赶时间、只想在某个块的最前面零小费成交的人可用。同时它让不带保护的减法直接 revert(§2.6)。 |
| 9 | **Everest:EIP-8130 交易的 coinbase tip** | 源码:排序键是"EIP-1559 优先费,**或**静态解码出的 EIP-8130 coinbase tip ÷ `gas_limit`"([SRC] `ordering.rs` L3–4、L161–209);coinbase tip 是交易里一笔转给费用金库的转账(`crates/execution/txpool/src/transaction.rs` L553–557),不体现在 gas 价里。文档:Everest 状态 "Planning",Sepolia 和主网日期均为 TBD [EVEREST]。实测:§1.2 样本里没有出现 `0x0/0x1/0x2/0x4/0x7e` 之外的交易类型,即主网尚未激活。 | **激活后是直接的逃税通道(推断)**:出价走 coinbase tip,`tx.gasprice − block.basefee` 可以是 0,而排序优先级很高。届时任何读 `tx.gasprice` 的 MEV 税都会漏掉这类交易,除非 Hook 能读到 coinbase tip(我没有查到有这样的接口,§7-6)。 |
| 10 | **Everest:按 gas limit 计费** | 源码仓库的设计文档:激活后用户按 `gas_limit × 有效 gas 价` 付费,而不是按实际用量([SRC] `docs/guides/GAS_LIMIT_BILLING.md`)。 | 不改变 `tx.gasprice` 的语义,但会改变套利者的出价水平(高小费的代价变大)。按今天的分布写死的阈值到时会偏。未激活。 |
| 11 | **没有竞争** | [PARADIGM] 的机制依赖"competitive priority ordering"。只有一个人看到的机会,不需要抬价。 | 逃税(机制本身的边界,不是漏洞)。 |
| 12 | **绕开这个池子** | 套利者可以只在没有这个 Hook 的池子里成交。 | Hook 只能对"这个池子自己被套利"的那部分收费;对经过它的普通路由流量,加收会让路由器把量导走。 |
| 13 | **同一发送者用一笔高价小交易"占位",后面跟低价交易** | 源码与抽样:同一发送者的后续 nonce 各按自己的小费排(§1.3(b) 观察到的是反方向:后一笔更高)。低价的后续交易不会因为前一笔出了高价而跟着靠前。 | 不构成逃税(推断,基于排序规则;我没有专门构造交易去验证)。 |
| 14 | **自己做 JIT 流动性,把加收的 LP 费收回来** | v4 的 LP 费按区间内流动性份额分([HOOKFS] §5.4)。 | **对"按费率加收"的设计基本无效(推断)**:套利者临时加流动性后,自己多付的手续费和自己多分到的手续费相抵,付给原有 LP 的那部分不变。对"收一笔固定金额再按流动性分"的设计则有效 —— Angstrom L2 为此另设了 JIT 税(§5.1)。 |

小结(事实层面):真正能"拿到位置却读不到小费"的现行途径是第 1 项(条件交易,仅在跟进者之间没有竞争时)和第 8 项(L1 存款交易);将来最要紧的是第 9 项。"误收"主要来自第 5、6、7 项的代付结构,以及 §4 里普通用户自己设的高小费。

---

## 4. 普通用户会不会被误伤:优先费分布

### 4.1 钱包和前端默认给多少(能查到的)

| 来源 | 数值 | 标记 |
|---|---|---|
| Base 节点 `eth_maxPriorityFeePerGas` | 1,000,000 wei(0.001 gwei,即源码里的建议值地板) | 实测 + 源码(§2.12) |
| Base 节点 `eth_gasPrice` | 6,000,000 wei(base fee + 1,000,000) | 实测 |
| `eth_feeHistory`(最近 20 块,各块的 10/25/50/75/90 分位) | 20 个块里中位数有 15 个落在 1,000,000–5,000,000(范围 0–43,547,588);90 分位有 17 个落在 4,400,000–30,000,000(范围 1,200,000–279,893,978) | 实测,区块 ≈ 56,235,900 |
| MetaMask 的 gas 建议接口 [MM-GAS] | low 0.001 gwei;**medium 0.015000002 gwei(15,000,002 wei)**;high 0.02 gwei;同一响应里 `estimatedBaseFee` 0.005、`latestPriorityFeeRange` 0–0.0202、`historicalPriorityFeeRange` 0.000000001–0.798607002 | 实测(一次读数,数值随行情变)。MetaMask 客户端在 Base 上是否就用这个接口的 medium 档作默认:未核实(§7-9) |
| Uniswap 前端 / Trading API、Coinbase Wallet / Base App 的默认值 | 没查到一手出处 | **未核实**(§7-9)。可用下面 4.3 的链上分布作旁证:发往 Universal Router 的 v4 swap 交易,最常见的优先费取值依次是 2,000,000(244 笔)、1,000,000(207 笔)、1,200,000(136 笔)、2,500,000(64 笔)、0(60 笔),共 1,049 笔(§4.3) |

### 4.2 样本与方法(实测,复现见附录 A.2)

- 公共端点的 `eth_getLogs` 对我一律返回 `-32011 request limit reached`(单块范围也是),所以改用 `eth_getBlockReceipts` 逐块取回执,在回执日志里筛 PoolManager(`0x498581ff718922c3f8e6a244956af099b2652b2b`)的 `Swap` 事件(topic0 `0x40e9cecb…112f`,[HOOKFS] §4.3)。
- 总体:区块 [55,236,000, 56,236,000)(最近约 55.6 小时)。按 100 块对齐切成窗口(候选 9,999 个),`random.seed(4_2026_11_11)` 后不放回随机取 60 个窗口,共 6,000 个区块(每个窗口 20 秒);60 个窗口全部取完。窗口落在 11-09、11-10、11-11 三天(UTC)。
- 一笔"v4 swap 交易" = 回执里至少有一条上述 `Swap` 事件的交易(都是成功交易,失败交易不发事件)。
- 优先费 = 回执 `effectiveGasPrice` − 该块 `baseFeePerGas`。
- "块内位置" = 剔除 `0x7e` 之后的序号,0 表示块内第一笔用户交易。
- 只是描述性统计。样本覆盖两天多一点,v4 在 Base 上的成交以发币类 Hook 池为主([HOOKFS] §9),**不代表主流币对上挂了这个 Hook 之后会吸引来的流量**。

### 4.3 结果

**样本规模**:60 个窗口、6,000 个区块(55,238,200–56,227,399;2026-11-09 15:26 – 11-11 22:24 UTC;按 UTC 日期 11-09 有 13 个窗口、11-10 有 27 个、11-11 有 20 个)。窗口内用户交易 121,915 笔(每块中位数 15 笔);其中 **v4 swap 交易 2,947 笔**(3,384 条 `Swap` 事件),来自 1,346 个发送者,`tx.to` 有 226 种(含 69 笔 `to` 为空的合约创建交易),涉及 731 个池子。交易类型:`0x2` 2,832、`0x0` 104、`0x4` 10、`0x1` 1;带 `UserOperationEvent` 的 173 笔。样本里没有存款交易(`0x7e`)触发 v4 swap。

同期环境:6,000 个块里 base fee 等于最低值的 4,694 个(78.2%),最高 13,036,071;gas 用量超过 8M 目标的 572 块(9.5%),≥ 39M 的 2 块。

**表 4-A:优先费分位数。单位:10^6 wei / gas(= 0.001 gwei);分位数取法 `sorted[int(p·n)]`。**

| 组别 | 笔数 | p10 | p25 | p50 | p75 | p90 | p95 | p99 | 最大 | > 10(0.01 gwei)| > 100(0.1 gwei)|
|---|---|---|---|---|---|---|---|---|---|---|---|
| 窗口内全部用户交易(对照) | 121,915 | 0.38 | 1 | **2.8** | 15.1 | 30.0 | 42.2 | 178 | 111,908 | 29.7% | 2.1% |
| 　其中块内第 1 笔 | 5,979 | 6.4 | 20.2 | **30.0** | 64.5 | 192 | 410 | 1,354 | 111,908 | 87.0% | 18.9% |
| 　其中块内第 2–3 笔 | 11,856 | 2 | 5.32 | **20.0** | 30.0 | 60.0 | 115 | 421 | 30,021 | 67.0% | 6.1% |
| 　其中块内第 4 笔起 | 104,080 | 0.3 | 1 | **2** | 6.93 | 20.2 | 30.0 | 81.0 | 54,376 | 22.1% | 0.7% |
| **v4 swap 交易:全部** | 2,947 | 0.04 | 1 | **1.3** | 2.4 | 12.0 | 30.0 | 127 | 1,995 | 11.0% | 1.4% |
| 按位置:块内第 1 笔 | 70 | 2 | 8 | **30.0** | 60.7 | 384 | 1,000 | 1,500 | 1,500 | 68.6% | 18.6% |
| 按位置:块内第 2–3 笔 | 224 | 1.2 | 1.5 | **2.5** | 12.9 | 30.0 | 60.5 | 437 | 1,995 | 30.4% | 4.5% |
| 按位置:**块内前 3 笔合计** | 294 | 1.2 | 2 | **4.99** | 27.8 | 60.5 | 197 | 1,500 | 1,995 | 39.5% | 7.8% |
| 按位置:块内第 4 笔起 | 2,653 | 0.0068 | 1 | **1.2** | 2 | 7.45 | 17.8 | 80.6 | 649 | 7.8% | 0.6% |
| 按去向:`tx.to` 是 Universal Router | 1,049 | 1 | 1 | **1.5** | 2 | 2.5 | 4.13 | 15.0 | 1,500 | 2.0% | 0.2% |
| 按去向:带 `UserOperationEvent`(4337) | 173 | 1 | 1 | **1** | 1 | 1.2 | 1.2 | 1.48 | 1.82 | 0.0% | 0.0% |
| 按去向:其他合约(含合约创建) | 1,725 | 0.0003 | 0.62 | **1.3** | 5.01 | 25.4 | 45.0 | 223 | 1,995 | 17.5% | 2.2% |
| 按类型:`0x4`(7702) | 10 | 1.15 | 1.15 | **1.2** | 1.21 | 2 | 2 | 2 | 2 | 0.0% | 0.0% |
| 按发送者:样本内 ≥ 10 笔 | 1,065 | 1 | 1 | **1.44** | 2 | 2.98 | 6.04 | 20.9 | 80.6 | 3.1% | 0.0% |
| 按发送者:样本内 2–9 笔 | 829 | 0 | 0.19 | **1** | 2.55 | 15.0 | 30.0 | 121 | 1,995 | 12.7% | 1.1% |
| 按发送者:样本内仅 1 笔 | 1,053 | 0 | 1 | **1.3** | 3.92 | 30.0 | 60.4 | 326 | 1,500 | 17.6% | 2.9% |
| 交叉:**仅 1 笔的发送者 + 直接调 Universal Router** | 239 | 1 | 1 | **1** | 1 | 2.5 | 10.0 | 26.6 | 1,500 | 4.6% | 0.4% |
| 交叉:Universal Router + 块内第 4 笔起 | 945 | 1 | 1 | **1.38** | 2 | 2.5 | 2.95 | 12.0 | 30.0 | 1.2% | 0.0% |

各组的含义和局限:
- "块内第 1 笔 / 前 3 笔"是"抢排序"的位置代理。但每块中位数只有 15 笔用户交易,低小费也常落在前三:前 3 笔的 294 笔里有 110 笔(37%)优先费 ≤ 2,000,000;按去向分,104 笔直接调 Universal Router、5 笔是 4337、185 笔发往其他合约。
- "直接调 Universal Router 且发送者在样本内只出现 1 次"是"普通用户"的代理;"发送者 ≥ 10 笔"是"程序化发送者"的代理。**没有任何地址被核实为机器人或散户**(§7-10)。Universal Router 的 1,049 笔按发送者频次分:≥ 10 笔的发送者 658 笔、2–9 笔 152 笔、仅 1 笔 239 笔。
- "其他合约"混着聚合器、交易终端、套利合约,我没有标注归属。

**表 4-B:高于各门槛的交易占比(v4 swap 交易)。**

| 门槛(wei / gas)| 块内前 3 笔(294)| Universal Router 且仅 1 笔的发送者(239)| Universal Router 全部(1,049)| 块内第 4 笔起(2,653)| 全部 v4 swap 交易(2,947)| 超过门槛的交易所付优先费占 v4 swap 交易优先费总额 |
|---|---|---|---|---|---|---|
| > 2,000,000 | 62.6% | 13.4% | 20.2% | 23.3% | 27.2% | 90.0% |
| > 3,000,000 | 53.4% | 7.9% | 6.1% | 15.3% | 19.1% | 87.9% |
| > 5,000,000 | 48.3% | 7.1% | 4.4% | 12.7% | 16.3% | 86.1% |
| > 10,000,000 | 39.5% | 4.6% | 2.0% | 7.8% | 11.0% | 80.4% |
| > 20,000,000 | 31.0% | 1.3% | 0.7% | 4.5% | 7.2% | 71.8% |
| > 50,000,000 | 11.6% | 0.4% | 0.2% | 1.6% | 2.6% | 50.2% |
| > 100,000,000 | 7.8% | 0.4% | 0.2% | 0.6% | 1.4% | 40.8% |

最后一列按 `优先费 × gasUsed` 加权。

**其他读数:**

- 最常见的优先费取值(v4 swap 交易):1,000,000(562 笔,19.1%)、2,000,000(265)、0(220,7.5%)、1,200,000(160)、1,330,000(95)、2,500,000(66)。直接调 Universal Router 的:2,000,000(244)、1,000,000(207)、1,200,000(136)、2,500,000(64)、0(60)。
- **高于 0.01 gwei 的 323 笔是谁**:302 笔(93%)发往 Universal Router 以外的合约,21 笔直接调 Universal Router,4337 的 0 笔;116 笔(36%)在块内前 3 笔;按发送者频次,仅 1 笔的 185 笔(57%)、2–9 笔的 105 笔、≥ 10 笔的 33 笔;共 245 个不同发送者、77 种 `tx.to`。
- 优先费最高的 6 笔:1.995 gwei(块内第 2 笔,`0xf8803ec6…2961`)、1.5 gwei(块内第 1 笔,**直接调 Universal Router、发送者只出现 1 次**,`0x8db597ba…e3f9`)、1.5 gwei(`0x6266b635…25f0`)、1.1 gwei(`0x67b1351f…0c30`)、1.0 gwei(`0x4f8a8b34…b78a`)、0.649 gwei(`0xb6c9b348…ae1f`)。其中三笔我回看了前 25 个块(5 秒),对应池子既没有 `Initialize` 也没有别的 swap,即不是开盘抢购;它们为什么出这么高,没有追查。
- **位置分布**:v4 swap 交易落在块内第 1 笔的占 2.4%(70 笔),前 3 笔的占 10.0%(294 笔)。5,979 个有用户交易的块里,第 1 笔用户交易是 v4 swap 的有 70 个(1.2%)。
- **优先费总额**(`优先费 × gasUsed` 求和):v4 swap 交易合计 8.32 × 10^15 wei(0.0083 ETH),占窗口内全部用户交易优先费(3.59 × 10^17 wei,0.359 ETH)的 2.3%;笔数占比是 2.4%。v4 swap 交易的这笔钱里,块内前 3 笔付了 48.2%,"Universal Router 且仅 1 笔的发送者"付了 3.6%。6,000 个块是 20 分钟的链上时间;若按比例外推到一天,v4 swap 交易付给定序器的优先费约 0.6 ETH/天、全部用户交易约 26 ETH/天 —— **这是 20 分钟随机样本的线性外推,只能看数量级**。
- **忙的时候**:60 个窗口各自的"全部用户交易优先费中位数"最小 1,150,000、中位 2,200,000、最大 12,437,992;有 3 个窗口 ≥ 10,000,000(起始块 55,636,800、55,654,200、55,655,500,其中第一个含一个满块,base fee 升到 13,036,071)。这 3 个窗口里直接调 Universal Router 的 v4 swap 交易共 47 笔,各窗口中位数 1,259,931–2,000,000,高于 0.01 gwei 的 4 笔(都在含满块的那个窗口)。

### 4.4 读法(事实 + 少量推断,推断已标明)

1. (事实)v4 swap 交易的优先费绝大多数挤在节点建议值和钱包默认值附近:中位数 1,300,000(0.0013 gwei),72.8% 不超过 2,000,000,7.5% 为 0。比同期全部用户交易(中位数 2,800,000,29.7% 高于 0.01 gwei)还低。
2. (事实)块首与其余的差距确实存在,但主要在尾部:块内第 1 笔 v4 swap 交易的中位数是 30,000,000(0.03 gwei),与全部用户交易的块首中位数相同;第 4 笔起是 1,200,000,差 25 倍。90 分位是 384,000,000 对 7,450,000。
3. (事实)直接调 Universal Router 的交易很"干净":95 分位 4,130,000,99 分位 15,000,000,高于 0.01 gwei 的只有 2.0%;4337 的没有一笔高于 0.002 gwei。
4. (事实)以 0.01 gwei 为门槛:留在门槛以下的有 Universal Router 交易的 98.0%、"Universal Router 且仅 1 笔发送者"的 95.4%、全部 v4 swap 交易的 89.0%;门槛以上的交易(11.0%)付了 v4 swap 交易优先费总额的 80.4%,覆盖块内第 1 笔的 68.6%、前 3 笔的 39.5%。
5. (事实 + 推断)**但门槛以上的不等于套利者**:323 笔里 57% 来自样本内只出现一次的发送者,93% 发往 Universal Router 以外的合约、分散在 77 种目标合约上。这些可能是套利合约,也可能是经交易终端 / 机器人下单、默认小费设得高的普通用户 —— 从链上数据我分不出来(§7-10)。优先费最高的几笔里就有"只出现一次的地址直接调 Universal Router、出 1.5 gwei"的。
6. (事实 + 推断)**今天 v4 上被抢排序的量很小**:块首是 v4 swap 的区块只占 1.2%;v4 swap 交易在这 20 分钟里付出的全部优先费是 0.0083 ETH。Base 上的 v4 成交以发币类 Hook 池为主([HOOKFS] §9),主流币对的套利主要发生在别的 DEX(全部用户交易的块首中位数 0.03 gwei、99 分位 1.35 gwei,量级大得多)。所以这张表描述的是"现在在 v4 上交易的人",不是"主流币对挂上这个 Hook 之后会来抢的人"。后者更接近表 4-A 的"全部用户交易:块内第 1 笔"一行。
7. (事实)样本里的忙时(3 个窗口的整体中位数升到 0.01 gwei 以上)没有把 Universal Router 用户的优先费明显带高。样本里没有极端行情(只有 2 个满块),这一条不能外推(§7-13)。

---

## 5. 现有同类实现

> 本节是对公开登记库、公开源码和所注区块的链上读数的转述,由 AI agent 整理,未经相关项目确认,地址与项目的对应关系未逐个核实;不是对任何第三方项目的安全评价或归属认定,读数可能已过时。

### 5.1 Angstrom L2(Sorella)在 Base 上的 Hook `0x631352aaa9d6554848af674106bcd8bb9e59a5cf`

出处:[ANG-DEPLOYED] (链上实际运行的版本)、[ANG-SRC](仓库 main,比已部署版本新)、[链上] 区块 56,236,830。

- **按优先费定价的公式**(两个版本相同;[ANG-DEPLOYED] `src/AngstromL2.sol` L188–193,[ANG-SRC] L195–200):

  ```
  priorityFee = tx.gasprice − block.basefee
  swapTax(wei,以 ETH 计) = 0                                             若 priorityFee ≤ priorityFeeTaxFloor
                         = swapMEVTaxFactor × 120,000 × (priorityFee − priorityFeeTaxFloor)   否则
  ```

  `TAXED_GAS = 120_000` 是写死的"名义 gas 量",注释说明用常数是为了让竞争者的出价成本与实际 gas 用量无关。源码注释:税率相当于 `swapMEVTaxFactor / (swapMEVTaxFactor + 1)`(把"税 + 付给定序器的小费"看作总出价)。
- **收的是一笔绝对金额的 ETH,不是费率。** 在 `beforeSwap` 里通过 `BeforeSwapDelta` 从 ETH 一侧直接扣(所以池子的 currency0 必须是原生 ETH),`afterSwap` 里把其中归 LP 的部分按"这笔 swap 扫过的各个 tick 区间"记入逐 tick 的奖励累加器。Hook 自己持有资金,开了全部 4 个 return-delta 位([HOOKFS] §9.2)。这与我们要做的"只覆盖 LP 费、不代持"是两种做法。
- **上限**:`swapMEVTaxFactor ≤ 9999`;`priorityFeeTaxFloor ≤ 100 gwei`;协议从税里抽成上限 75%、池子创建者上限 50%(常量见 [ANG-SRC] `src/AngstromL2.sol` L106–112、`src/AngstromL2Factory.sol` L66–69)。税额本身没有上限。仓库里的审计报告记录过"税相对这笔 swap 的 ETH 数量过大时 swap 会 revert"(`audit/2025-10-01-cyfrin-sorella-l2-angstrom-v2.1.md`,标题 "Zero-for-one swaps will revert for small input amounts relative to the specified priority fee" 和 "Large priority fee relative to one-for-zero swap amounts will cause … underflow");已部署版本里这两条是否已改,我没有核对。
- **每一笔 swap 都算税,不只是块内第一笔**:已部署版本的 `beforeSwap` 无条件调用 `_getSwapTaxAmount()`,合约里没有按 `block.number` 区分首笔的逻辑([ANG-DEPLOYED] L326–345)。
- **JIT 税**:加 / 撤流动性时(`afterAddLiquidity` / `afterRemoveLiquidity`,`liquidityDelta == 0` 的只收费操作除外)按同一公式、另一个系数收税,源码注释 "Slightly higher LP JIT liquidity tax to encourage it to be lower in the block";由开关 `jitTaxEnabled` 控制。
- **此刻的链上参数**([链上] 区块 56,236,830):

  | 读数 | 值 |
  |---|---|
  | `swapMEVTaxFactor()` | **200** |
  | `priorityFeeTaxFloor()` | **10,000,000 wei(0.01 gwei)** |
  | `jitTaxEnabled()` / `jitMEVTaxFactor()` | **false** / 300 |
  | `getSwapTaxAmount(1,000,000)` | 0 |
  | `getSwapTaxAmount(50,000,000)`(0.05 gwei) | 960,000,000,000,000 wei(0.00096 ETH) |
  | `getSwapTaxAmount(1,000,000,000)`(1 gwei) | 23,760,000,000,000,000 wei(0.02376 ETH) |
  | `FACTORY()` | `0x0000000000a5f21b113A18DD18f6FbEEBD01201B`;`isVerifiedHook(hook)` = true;工厂默认 `defaultSwapMEVTaxFactor` = 99、`defaultPriorityFeeTaxFloor` = 10,000,000、`defaultJITTaxEnabled` = false |
  | `owner()`(Hook 与工厂相同) | `0x2A49fF6D0154506D0e1Eda03655F274126ceF7B6`(可调系数、地板、JIT 开关) |
  | `poolKeys(0)` | ETH(`0x0`)/ USDC(`0x8335…2913`),`fee` = 160,`tickSpacing` = 10;PoolId `0x71deb282904d0f76bc8c7867f4618ff91dcb43cf4574bc64700ffc48791d369c`。`poolKeys(1)` 调用失败,即目前只登记了这一个池 |

- **是否生效**:参数层面**生效**(系数 200、地板 0.01 gwei,优先费高于地板的 swap 会被收税)。但它登记的唯一一个池子**此刻区间内流动性为 0**:[链上] 区块 56,241,119,`StateView(0xa3c0…8a71).getSlot0(poolId)` 返回 `sqrtPriceX96` = 3,678,784,596,859,533,629,754,901、`tick` = −199,561、`lpFee` = 160(已初始化),`getLiquidity(poolId)` = **0**;用 v4 Quoter 对它报价返回 `NotEnoughLiquidity(poolId)`。§4 样本里经过这个池子的交易:**0 笔**(2,947 笔 v4 swap 交易里没有一笔的 `Swap` 事件带这个 PoolId)。即:机制是活的,但我没有看到它在 Base 上有实际成交量;它历史上收过多少税没有查(§7-11)。
- **与 §2.6 相关的实现差异**:已部署版本用 `tx.gasprice - block.basefee`(无保护),仓库 main 改成了饱和减法并加了注释说明原因;main 还新增了"调用方可在 `hookData` 里给出愿付的最高税额,超过则 revert `SwapTaxExceedsSpecifiedMax`"([ANG-SRC] L333–346)。
- 税的分成([链上] 区块 ≈ 56,241,200,`getPoolFeeConfiguration(poolKey)` 返回 `(true, 0, 0, 0, 35)`,字段顺序见 [ANG-DEPLOYED] L38–44):`creatorTaxFeeE6` = 0、`protocolTaxFeeE6` = 0,即**这个池子的税目前全部归 LP**;另有 `protocolSwapFeeE6` = 35(协议从 swap 额里抽 0.0035%),`creatorSwapFeeE6` = 0。

### 5.2 Aero 的 MEV 税模块

公式、乘数、上限、三个模块的参数见 [POOLFS] §5.4,不重复。要点只有三条:它是**费率**(在 swap 费上加若干百万分之一,封顶 10%),有"高于 `max(baseFeeFactor × basefee, minThreshold)` 才收"的免税门槛,模块调用失败按 0 处理。

**此刻仍未生效**(本次在区块 56,236,830 重读,与 [POOLFS] 在区块 ≈ 55,996,400 的读数相同):Slipstream 的模块 `0x29F1…9a4a` 已接线但 `priorityFeeMultiplier()` = 0;Volatile / Stable 两个工厂的 `mevTaxModule()` 都是零地址。

### 5.3 其他公开设计

- **[PARADIGM] "Priority Is All You Need"(2024-06-04)**——这类设计的源头。
  - 定义:合约按交易的优先费另收一笔钱,称为 MEV tax;线性形式 `tax = a × priorityFeePerGas`。脚注给的取法正是 `priorityGasPrice = tx.gasprice - block.basefee`,并写明 base fee "should be ignored for purposes of MEV taxes, since it is not under the transactor's control"。
  - 用在 AMM 上的方案:对每个池子**每个区块的第一笔**交易要求 `x_end × y_end > (sqrt(x_start × y_start) + a × priorityFeePerGas)²`(即按优先费要求它给池子留下一笔绝对数量的流动性增量),之后的交易按普通固定费率。——是"绝对金额",不是"费率"。
  - 文中列的**前提**:出块遵守 competitive priority ordering(按优先费排序、抗审查、交易上链前保密、出块者没有"最后看一眼"的权利);"could be used today on OP Stack L2s like OP Mainnet, Base, and Blast";在以太坊 L1 上 "likely not work at all"。
  - 文中列的**局限**:"MEV taxes only work if block proposers strictly follow the rules";对垄断的出块者没有激励相容性;区块满时低优先级交易被挤出;抢输的交易 revert 仍上链;用户意图外泄会被绕开;抢跑交易可以不交这笔税;多个应用同时收税时怎么分取决于各自的参数。
- **Unichain 的做法(对照)**:Uniswap Labs 的公告称 Unichain 在 TEE 里构建区块、由 TEE 按优先费排序,并把"可验证的优先费排序"明确说成是为 MEV tax 这类机制提供保证(https://blog.uniswap.org/rollup-boost-is-live-on-unichain ;Flashbots:https://writings.flashbots.net/introducing-rollup-boost )。这两篇我只看到搜索摘要,没有逐字核对原文(§7-12)。与 Base 的差别(推断):Base 的排序只是定序器的运营配置,没有对外可验证的保证。
- **Blocknative 的 Gas Network 示例 Hook**(https://www.blocknative.com/blog/optimizing-uniswap-v4-swap-fees-with-gas-network ):按预言机给出的 gas 价格调 swap 费,目的是省钱而不是收 MEV 税;文章提到在一些 L2 上优先费占 gas 价的大头。我只看到搜索摘要,没有读原文和代码(§7-12)。
- 没有找到别的已上线、公开源码的"priority fee → LP 费率覆盖"Hook。检索范围:[HOOKFS] 里列的官方登记库描述、两次网页搜索。OpenZeppelin uniswap-hooks 与 Uniswap 官方 Hook 仓库里是否有同类:我没有逐文件翻(§7-12)。

---

## 6. 结论(以下是我的判断,不是事实)

### 6.1 前提是否成立

**成立,但只成立一半。**

- 成立的一半:① Denim 之后块内仍按优先费降序(相邻对 99.11% 非递增,剔除同发送者 nonce 后违例 0.33%);② `tx.gasprice − block.basefee` 在合约里读到的正是排序所用的那个量,L1 数据费和 operator fee 都不在里面;③ Base 上已有一个按同一个量收税、参数非零、正在运行的 Hook(Angstrom L2),说明这条路在工程上走得通。
- 不成立的一半:"优先费高"不等于"套利者",也不等于"位置靠前"。§4 的样本里,v4 swap 交易的优先费中位数只有 0.0013 gwei,块首交易与其余交易的差距主要在尾部;高于 0.01 gwei 的交易里 57% 来自只出现一次的发送者,我判断不了它们是套利者还是默认小费偏高的普通用户;条件交易还会让高小费交易出现在块中部(§1.3)。另外能收的盘子今天很小:块首是 v4 swap 的区块只占 1.2%,全部 v4 swap 交易 20 分钟里付给定序器的优先费合计约 0.0083 ETH,而 Base 上唯一同类 Hook(Angstrom L2)的池子此刻流动性为 0、样本里 0 笔成交。**所以:作为作品集里展示机制、测试深度和局限分析的一件,前提够用;作为能给 LP 带来可观收入的产品,现有数据不支持。** 是否开工由项目负责人定。

### 6.2 最大的三个风险

1. **信号混淆,误伤普通用户。** 优先费度量的是"急不急",不是"有没有毒"。钱包的默认档位就可能越过一个偏低的门槛(MetaMask 接口的 medium 档当时是 0.015 gwei,高于 Angstrom 的 0.01 gwei 地板;不过样本里直接调 Universal Router 的交易只有 2.0% 高于 0.01 gwei);高于 0.01 gwei 的 v4 swap 交易有 57% 来自只出现一次的发送者,其中有多少是普通用户我分不出来;区块变满时 base fee 每块最多涨 0.4%,拥堵价格会先体现在优先费上(机制上如此;§4 的样本里忙时没有把 Universal Router 用户明显带高,但样本没有极端行情);代付结构(4337、7702、filler)下用户根本没设过这个数。加上报价问题:Quoter 和不带费用字段的 `eth_call` 读到的优先费是 0,**报价永远不含加收部分**,用户实际成交会比报价差,路由器也会按偏低的费率把量导进来。
2. **该收的收不到。** 没有竞争的套利不需要抬价;条件交易的跟进者只需压过其他跟进者;L1 存款交易零小费且在块首;Everest 的 coinbase tip 激活后可以完全绕开 `tx.gasprice`。再加上套利者可以只去没有这个 Hook 的池子。而且盘子本身小:§4 的样本里块首是 v4 swap 的区块只占 1.2%,Angstrom L2 在 Base 上的池子此刻没有流动性。结果可能是:Hook 从套利者身上收到的很少,而费率门槛又不敢设低。
3. **规则在别人手里,而 Hook 不可升级。** 排序是单一定序器的配置(源码里就有先到先得的选项);最低 base fee 今年改过多次;Everest 会同时改变出价方式(coinbase tip)和出价成本(按 gas limit 计费)。本仓库的设计约束要求 Hook 不可升级、没有管理员,那么写死的门槛、斜率、上限会随这些变化而失准,且没有办法调。Angstrom 和 Aero 都保留了 owner 可调参数。

### 6.3 建议工程师必须处理的边界情况

1. **`tx.gasprice < block.basefee`**:不带费用字段的模拟调用(Quoter、`eth_call`、`eth_estimateGas`)和 L1 存款交易。必须用饱和减法,按 0 处理;否则报价和存款交易里的 swap 全部 revert。已部署的 Angstrom L2 用的是不带保护的减法([ANG-DEPLOYED] L651、L656),其仓库 main 已改为饱和减法。
2. **报价与成交不一致**:Quoter 读到的优先费是 0。至少提供一个 view,输入优先费、返回这笔会被收的费率;README 写明前端模拟时要带上真实的费用字段;测试里覆盖"报价按 0、成交按高价"时用户滑点保护触发的路径。
3. **上限**:覆盖值必须夹在一个明确的最大费率以内。超过 1,000,000 会让整笔 swap revert(`LPFeeTooLarge`);总费率达到 100% 时 exactOut 直接 revert;协议费最多再叠 0.1%([HOOKFS] §5.2–5.4)。上限应远低于这些硬边界。
4. **免税带**:门槛要盖住钱包默认值和日常波动(数据见 §4.3),并说明选这个数的依据。门槛用绝对的 wei 还是相对 base fee,各有失准方式:绝对值会随 Base 调整最低 base fee 或行情变化而过时;相对值在 base fee 贴地板时等于一个常数(84.6% 的块如此)。
5. **返回值格式**:池子必须是动态费池(`fee == 0x800000`),返回值必须带 `OVERRIDE_FEE_FLAG`,否则被静默忽略([HOOKFS] §5.2)。测试里要有"忘了带标志位"的反例。
6. **代付交易**:4337 / 7702 / filler 交易里读到的是别人的小费;`hookData` 和 `sender` 都不能当身份用([HOOKFS] §4.4)。设计上不要试图识别"谁",只按交易级的量收,并在文档里写清这一局限。
7. **同一笔交易多次经过池子**:每次读到同一个优先费,每次都加收。确认这是想要的行为并写测试。
8. **满块 / 拥堵**:优先费整体抬高时的行为(是否需要相对当块水平的基准)。Hook 在 `beforeSwap` 里拿不到"本块其他交易的小费",只能用跨块状态自己攒基准;这会引入可被操纵的状态,需要审计员单独看。
9. **条件交易造成的"块中高价"**:不要用"是不是池子本块第一笔"来判定套利者 —— 被唤醒的跟进交易在块中部,小费可以极高(§1.3 例 2)。
10. **Everest**:在 README 里写明"EIP-8130 的 coinbase tip 激活后本 Hook 会漏收",并把它列为已知局限;上线前再核一次激活日期。
11. **自做 JIT**:按费率加收的设计下,我的推断是套利者临时加流动性拿不回付给原有 LP 的那部分(§3 第 14 项)。这是推断,需要 `hook-engineer` 用测试证实或证伪;若证伪,就需要对加 / 撤流动性也做处理,而那会碰到"不得堵死撤流动性"这条本仓库的设计约束。
12. **不变量**:Hook 不持有资金、不用 return delta,所以没有 delta 守恒问题;要测的不变量是"任何输入下覆盖值 ≤ 上限"和"任何 `tx.gasprice` / `block.basefee` 组合下 `beforeSwap` 不 revert"。

---

## 7. 未核实清单

| # | 事项 | 现状 |
|---|---|---|
| 1 | 生产定序器的排序配置是否就是源码默认的 `coinbase-tip` | 文档写"按 priority fee",抽样支持(99.11%);没有办法读到生产配置本身 |
| 2 | §1.3(c) 那 114 对违例**确实**是条件交易 | 谓词不上链,只有间接证据(形态、与前一笔触及同一合约的比例 59% 对 9.6%、测试网行为)。余额在块内才到位、资源计量延后、交易池 base fee 口径差异等其他成因没有逐一排除;18 对"差额极小"的原因是猜测 |
| 3 | 51 个"第一笔用户交易不是全块最高价"的区块各是什么情况 | 没有逐个追查 |
| 4 | 主网上条件交易的使用规模(占交易的比例、谁在用) | 链上无法识别;只有 §1.3 的间接估计 |
| 5 | 定序器是否存在未公开的私下通道或对特定地址的优先处理 | 无法从链上或公开资料排除;[ORDFS] §3.2 的"没找到"仍然有效 |
| 6 | Everest(EIP-8130 / 文档称 EIP-8430)的激活日期;激活后合约里能否读到 coinbase tip | 文档写 TBD;文档与源码用的 EIP 编号不一致(8430 对 8130),我没有查清是改号还是两个东西;没有找到读取 coinbase tip 的预部署或操作码 |
| 7 | 存款交易里 `tx.gasprice` = 0 的链上实证 | 只有源码和 Angstrom 源码注释;没有找一笔真实的存款 swap 用 trace 验证(公共端点没有 trace) |
| 8 | Base 的 v4 池上有哪些代发 / 意图类产品(UniswapX、各家"免 gas 兑换"),它们的 filler 出多少小费 | 没有查;§4 只按 `tx.to` 和事件粗分 |
| 9 | 主流钱包和前端在 Base 上默认的优先费:MetaMask 客户端是否取 [MM-GAS] 的 medium 档;Uniswap 前端 / Trading API、Coinbase Wallet、Base App、Rabby 的取值逻辑 | 只有 [MM-GAS] 一次读数和节点建议值;其余没有一手出处。Uniswap Trading API 文档提到响应里有 `maxPriorityFeePerGas` 和 `gasStrategies`,具体数值需要带 key 调用 |
| 10 | §4 里"机器人"与"普通用户"的划分 | 用的是可观察的代理变量(块内位置、`tx.to` 是否为 Universal Router、发送者在样本里出现的次数),没有任何地址被核实为机器人或散户;非 Universal Router 的目标合约我都没有标注归属 |
| 11 | Angstrom L2 Hook 的历史成交量和历史收税总额 | 没有查。已部署版本与仓库 main 的差异我只比对了 `AngstromL2.sol` 一个文件(60 行 diff),其余库文件没有比对 |
| 12 | Blocknative 示例 Hook 的原文与代码;Unichain / Rollup-Boost 两篇公告的原文;OpenZeppelin uniswap-hooks、Uniswap 官方 Hook 仓库里是否有按优先费定价的实现 | 前两项只见搜索摘要;后两个仓库没有逐文件翻 |
| 13 | §4 的分布在行情剧烈时(满块、清算连锁)是什么样 | 样本是随机窗口,没有专门抽极端时段 |
| 14 | "按费率加收时自做 JIT 无法逃税"(§3 第 14 项) | 纯推断,没有在 fork 上验证 |
| 15 | 公共端点 `eth_getLogs` 为何一律返回 `request limit reached` | 没有查原因(可能是该方法被单独限额);本文因此全部改用逐块回执 |

---

## 附录 A:复现方法

工具:`python3`(标准库 `urllib`、`random`、`json`)、`~/.foundry/bin/cast`;RPC `https://mainnet.base.org`。公共端点限流,批量 JSON-RPC 每批 ≤ 20 个请求、批间停 0.05–0.2 秒,遇到 429 退避重试。

### A.1 §1.2 的排序抽样

```
import random
random.seed(20261111)
nums = sorted(random.sample(range(53556127, 56234001), 2000))
# 对每个 n:eth_getBlockByNumber(hex(n), true)
# user = [t for t in block.transactions if t.type != "0x7e"]
# tip(t) = int(t.gasPrice, 16) - int(block.baseFeePerGas, 16)
# 违例:相邻两笔 tip(后) > tip(前)
# "同发送者可解释":后一笔的 from 在本块更靠前的用户交易里出现过
```

§1.3(c) 的关联检验:对含"不可解释违例"的 101 个块调 `eth_getBlockReceipts`,取每笔交易回执里发日志的合约地址集合(去掉 WETH `0x4200…0006` 和 USDC `0x8335…2913`),比较违例交易与其紧邻前一笔的交集是否非空;对照组是同样这些块里发送者不同、未违例的相邻对。

### A.2 §4 的优先费分布

```
import random
random.seed(4_2026_11_11)
HEAD = 56236000; LO = HEAD - 1_000_000; WL = 100
starts = sorted(random.sample(range(LO, HEAD - WL, WL), 60))
# 对每个窗口 [s, s+100) 的每个块:eth_getBlockByNumber(n, false) 取 baseFeePerGas,
#   eth_getBlockReceipts(n) 取全部回执
# v4 swap 交易:回执 logs 里存在 address == 0x498581ff718922c3f8e6a244956af099b2652b2b
#   且 topics[0] == 0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f
# tip = int(effectiveGasPrice, 16) - baseFeePerGas
# 4337:回执 logs 里存在 topics[0] == 0x49628fd1471006c1482da88028e9ce4dbb080b815c9b0344d39e5a8e6ec1419f
#   (UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256),cast keccak 计算)
# Universal Router:tx.to ∈ {0x6ff5693b…9b43, 0xfdf682f5…fbc7, 0xd6145b2d…9c40}([HOOKFS] §1.1)
```

### A.3 §2 与 §5 的单次读数

```
# GASPRICE / BASEFEE 探针(§2.3):
curl -s https://mainnet.base.org -H 'content-type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"eth_call","params":[{"from":"0x4200000000000000000000000000000000000006","data":"0x3a5f524860205260405ff3","maxFeePerGas":"0x3b9aca00","maxPriorityFeePerGas":"0x1e240"},"latest"]}'
# operator fee(§2.8):
cast call 0x4200000000000000000000000000000000000015 "operatorFeeScalar()(uint32)" -r https://mainnet.base.org
cast call 0x4200000000000000000000000000000000000015 "operatorFeeConstant()(uint64)" -r https://mainnet.base.org
cast call 0x420000000000000000000000000000000000000F "getOperatorFee(uint256)(uint256)" 200000 -r https://mainnet.base.org
# 节点建议值(§2.12):
cast rpc eth_maxPriorityFeePerGas -r https://mainnet.base.org ; cast rpc eth_gasPrice -r https://mainnet.base.org
# Angstrom L2(§5.1):
H=0x631352aaa9d6554848af674106bcd8bb9e59a5cf
cast call $H "swapMEVTaxFactor()(uint256)" -r https://mainnet.base.org
cast call $H "priorityFeeTaxFloor()(uint256)" -r https://mainnet.base.org
cast call $H "jitTaxEnabled()(bool)" -r https://mainnet.base.org
cast call $H "getSwapTaxAmount(uint256)(uint256)" 1000000000 -r https://mainnet.base.org
cast call $H "poolKeys(uint256)(address,address,uint24,int24,address)" 0 -r https://mainnet.base.org
# Aero(§5.2):
cast call 0x29F12cE5Be3D88b56D245B7f4E969C518F799a4a "priorityFeeMultiplier()(uint256)" -r https://mainnet.base.org
cast call 0x8E6a9FCd1d638CC760Ffba397605Fe3355dE76D2 "mevTaxModule()(address)" -r https://mainnet.base.org
cast call 0x78589E876edcEbdce72ee3436ab3c9AD3a7cEF2D "mevTaxModule()(address)" -r https://mainnet.base.org
```
