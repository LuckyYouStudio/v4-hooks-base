# Uniswap v4 Hooks 作品集(Base)

[English](README.md) | 中文

> **未经外部审计,不要直接用于主网资金。**
> 本仓库的代码、测试、文档和审计报告都由 AI agent 编写;做过的"内部审计"也是 **AI agent**(`hook-auditor` 岗位)做的,**不等于外部审计**,不等于任何第三方审计机构的结论。没有部署到任何公共网络。按"原样"提供,不作任何保证,见文末免责声明。

## 这是什么

三件围绕 Uniswap v4 Hook 的开源作品,目标链是 Base。它们想展示的不是"有这几个 Hook"(同类实现在 OpenZeppelin 的库里已经有了),而是**设计取舍写清楚、局限写在最前面、测试包含对抗搜索、审计过程和每一条发现都公开**。

| 作品 | 一句话 | 说明 |
|---|---|---|
| `VolatilityFeeHook` | 动态手续费:LP 费率跟着池子自己的、按 10 秒时间桶采样的已实现波动走 | [`docs/VolatilityFeeHook.md`](docs/VolatilityFeeHook.md) |
| `PriorityFeeHook` | 交易付的优先费越高,该笔 swap 的 LP 费越高。**定位是展示设计与诚实评估,不宣称能给 LP 带来可观收入** | [`docs/PriorityFeeHook.md`](docs/PriorityFeeHook.md) |
| Hook 安全检查工具 `checker/` | 对任意 v4 Hook 跑九类通用检查的 Foundry 测试工具。**通过全部检查不等于安全,不等于审计** | [`checker/README.md`](checker/README.md) |

两个 Hook 的共同点:不可升级、没有 owner / 管理员、不持有资金、不用 return delta、没有任何流动性回调(撤流动性在任何状态下都不经过 Hook)、回调只接受 PoolManager、只服务在 `afterInitialize` 里登记过的池子、参数全部写死。

## 用之前先看:已知局限

下面的文字与各设计说明顶部一致,一条都没有省。

**`VolatilityFeeHook` 的两条主要局限(用之前先看):**
- **价格紧挨零流动性区间的池子(单边建仓、LP 区间很窄而行情已走出区间、被撤空),任何人零成本就能把费率打到 1% 上限。** "抬费要花钱"的成本下界只在价格路径上流动性连续时成立,其中的 L 是路径上的最小流动性。
- **有主导 LP 的池子里,费率应视为该 LP 可在 [0.05%, 1%] 内自行设定**:它推价的手续费回到自己手里,锯齿幅度始终小于费率,不会被套利。

两条都有测试记录事实(`test/VolatilityFeeHook.reaudit.t.sol`),上限都是写死的 1% LP 费,不涉及本金,不影响撤流动性。细节见设计说明的"流动性空档(N-1)"和"主导 LP(M-1 / E-A)"。

**`PriorityFeeHook` 的四条主要局限(用之前先看,细节和出处见设计说明):**
- **今天收不到多少钱。** 研究员的数量级估算:Base 上全部 v4 兑换交易付的优先费合计约 0.6 ETH/天(20 分钟样本线性外推),单个池子只占一小部分。
- **报价不含加收。** Quoter / 不带费用字段(或只带 `maxFeePerGas`)的 `eth_call` 读到的优先费是 0,报价按 0.05%,成交最多按 0.30%:exactIn 最多少拿约 2,501 ppm,exactOut 最多多付约 2,507 ppm。**按报价留 0.1% 或 0.25% 滑点余量的订单在上限处会回滚,留 0.5% 的可成交。** 报价要准,调用必须带 `maxPriorityFeePerGas` 或 legacy `gasPrice`。
- **代付 / 代发的交易,费率由组装交易的人决定;他是 LP,或在同一笔交易里做 JIT(加流动性 → 用户的 swap → 撤出,不需要常驻头寸,但需要资金),名义金额高于盈亏平衡点时抬小费就是赚钱的**(盈亏平衡点:独占 LP、20 万 gas 约 0.08 ETH;JIT 按假设的 50 万 gas、份额接近 100% 估算约 0.2 ETH;gas 数是假设值;低于它是亏的,仓库里的测试断言了名义 0.01 ETH 时各份额都亏)。**JIT 的份额 = JIT ÷ (JIT + 原有区间内流动性)**:要 90% / 99% 份额需约 9 / 99 倍于原有 LP 在同一窄区间内的资金,自有或闪电贷(闪电贷路径没有测,它的 gas 也不在 50 万的假设里);份额做得上去时,加收大部分归他而不是原有 LP。实测:用户 10e18 的 exactIn、零头寸的代发者做 99e24 的 JIT(交易内要拿出约 593,080 枚代币,是用户 10 枚名义的约 5.9 万倍),小费 0 时净得 0.005001 枚代币,抬到上限净得 0.030001 枚(按价格 1 计),原有 LP 只拿到 3.03e11 wei(不做 JIT 时是 0.03 枚);只拿 9 倍资金(约 53.9 枚)时抬小费多赚 0.0225 枚、原有 LP 留下 0.003 枚(各资金量的表见设计说明 §9 5a)。这与"第三方 JIT 分走加收"是同一个机制:能对准单笔交易做 JIT 的首先是交易的组装者。受影响的是用户签了最小产出、由他人上链的结构(4337、7702 代付、元交易 relayer);意图 / filler 类不受影响(加收由 filler 承担)。"bundler 能否把 `handleOps` 包进自己的合约做 JIT"没有验证。上限是写死的 0.30% LP 费,受用户自己的滑点保护约束;没有做 `hookData` 最高费率(取舍见设计说明 §9 5a)。与代发无关,任何第三方都可以用 JIT 夹住一笔高小费 swap,按份额分走加收(实测:9 倍于原有区间内流动性时拿走 90%),本 Hook 不处理。
- **绕得过去**:没人竞争的条件交易同块跟进、L1 存款交易、换到别的池子成交;将来 EIP-8130 的 coinbase tip。

每条都有测试记录事实(`test/PriorityFeeHook.adversarial.t.sol`、`test/PriorityFeeHook.jit.t.sol`、`test/PriorityFeeHook.quoter.t.sol`),不涉及本金,不影响撤流动性(Hook 没有流动性回调)。

## 三件作品

### 1. `VolatilityFeeHook` — 动态手续费

- **做什么**:`afterInitialize` 登记池子(必须是动态费池),`beforeSwap` 返回覆盖费率。每个池每个 10 秒桶最多观测一次(该桶第一笔 swap 执行之前):`variance = variance · 2^(−dt/600s) + Δ²`,`fee = clamp(500 + 25·sqrt(variance), 500, 10000)` pips,即 0.05%–1%。不接外部预言机。
- **设计取舍**:观测量是**跨桶的亚 tick 对数价之差**,不是当前 tick、现货价或单块成交量。初版用"每块一次的整数 tick",被首轮审计的 PoC 证明可以在 tick 边界上免费抖动抬费(H-1),因此换成现在的观测量;代价是费率滞后至多一个桶。权限位只开 `afterInitialize` + `beforeSwap`(地址低 14 位 `0x1080`)。
- **已知局限**:见上一节的两条,以及设计说明"已知局限"的全部 11 条(滞后一个桶、只看得见本池成交、参数没有回测、对 tick 间距和币对不敏感、起算机制只是部分缓解等)。
- **测试**:离线 108 条(单元、模糊、操纵成本对抗搜索、有状态不变量),Base fork 15 条。

### 2. `PriorityFeeHook` — 优先费归 LP

- **做什么**:`beforeSwap` 按本笔交易的优先费 `max(tx.gasprice − block.basefee, 0)` 返回覆盖费率:地板 0.05%,优先费超过 0.02 gwei 的部分线性加收,约 1 gwei 处封顶 0.30%。Hook 无状态(只有池子登记),不代持资金。
- **设计取舍**:只做"`beforeSwap` 覆盖费率"的最小版本,不用 return delta;按费率而不是按金额收;没有做"用户在 `hookData` 里声明最高费率"(代价见设计说明 §9 5a);参数不可调,要改只能重新部署。
- **诚实评估**:**它今天收不到多少钱**,而且可以被绕过,报价工具不带费用字段时报价不含加收,代发交易的一方在一定条件下能靠抬小费获利——四条都写在上一节,细节在设计说明。前提核实(Base 是否按优先费排序、Hook 里能读到什么)见 [`docs/research/base-priority-ordering-for-hooks.md`](docs/research/base-priority-ordering-for-hooks.md)。
- **测试**:离线 93 条(含对抗测试、JIT 资金表、与 V4Quoter 的报价差额、四池不变量),Base fork 13 条(真实 PoolManager、真实 V4Quoter、真实 USDC)。

### 3. Hook 安全检查工具(`checker/`)

- **做什么**:对一个 v4 Hook(本地部署的,或 fork 上已部署的地址)跑九类通用检查并出报告:a 权限位三方一致、b 回调可被非 PoolManager 调用、c 陌生池污染状态、d 撤流动性能否被堵、e swap 能否被卡死、f 动态费的上下界与同块敏感性、g 可升级 / 管理员迹象、h Hook 持有的资金、i return delta 拿走多少。每项给出 通过 / 失败 / 不适用 / 无法判定 和依据。
- **设计取舍**:被检的 Hook 当作对手(它会回调、会识别并欺骗检查器);凡是"对照组也失败""没测到"的情况都不落到"通过";"通过"的摘要只说"在这些输入下没发现"。只做检测,没有任何针对线上合约的可用攻击代码。
- **已知局限**:**通过全部检查不等于安全,不等于审计;"失败"不等于有漏洞。** Hook 可以认出检查器然后装乖,这个工具防不住;对"只服务特定池子、只允许特定方做市"的 Hook,大部分检查项只能报"无法判定"。误报漏报表和检出能力的边界在 [`checker/README.md`](checker/README.md)。
- **样本**:`checker/samples/` 是 10 个**故意有漏洞**的最小 Hook(每个通用问题一个,各配修好的对照版本),`checker/test/mocks/` 是审计回归用的变体。它们是抽象的最小模型,只用于本地测试检查器,**禁止部署**。
- **测试**:检查器自测离线 131 条通过、1 条跳过;Base fork 14 条通过、2 条跳过(跳过的是需要额外环境变量的命令行入口)。
- **对真实地址的试跑**:开发时在 Base fork 上对 5 个第三方 Hook 地址跑过 8 次冒烟测试;这些输出没人逐条看过,**不构成对任何第三方项目的安全结论,不放进本仓库**。怎么自己跑见 `checker/README.md`"真实地址试跑"。

## 构建与测试

需要 [Foundry](https://book.getfoundry.sh/)(`forge`、`cast`、`anvil`)和 git。编译器由 Foundry 自动下载(solc 0.8.26)。

```bash
git clone <本仓库> && cd <本仓库>
script/install-deps.sh                               # 把四个依赖按钉死的 commit 拉到 lib/(见"依赖")
forge build

# 两个 Hook
forge test --no-match-path "test/fork/*"             # 离线,205 条,不需要 RPC
BASE_RPC_URL=https://mainnet.base.org \
  forge test --match-path "test/fork/*"              # Base fork,36 条,区块钉在 56,228,000

# 检查工具(单独的 profile)
FOUNDRY_PROFILE=checker forge test --no-match-path "checker/test/fork/*"     # 离线,131 条通过、1 条跳过
FOUNDRY_PROFILE=checker BASE_RPC_URL=https://mainnet.base.org \
  forge test --match-path "checker/test/fork/*"                              # Base fork,14 条通过、2 条跳过
```

上面的数字是 2026-11-12 在本仓库这一版上实际跑出来的(Foundry 1.9.0,macOS)。离线 205 = `VolatilityFeeHook` 108 + `PriorityFeeHook` 93 + 部署脚本 4;fork 36 = 15 + 13 + 部署脚本 8(端到端 3 条、负向 5 条);每个不变量套件算 1 条。

- 没设 `BASE_RPC_URL` 时 fork 测试整组跳过(不是失败)。RPC 地址只走环境变量;**不要把带 API key 的 RPC URL 或任何密钥写进仓库**。变量名清单见 [`.env.example`](.env.example)。
- fork 测试对的是 Base 主网真实 PoolManager `0x498581fF718922c3f8e6A244956aF099B2652b2b`(出处:Uniswap 官方部署页 https://docs.uniswap.org/contracts/v4/deployments )。固定区块的状态要 RPC 还保留着才读得到,公共节点不保证长期保留;第一次跑要从 RPC 拉状态,检查工具的 fork 测试在冷缓存下可能要十几到二十几分钟。
- 两个 Hook 的 fork 测试用的是 mock 代币和原生 ETH(`PriorityFeeHook` 另用了真实 USDC 和真实 V4Quoter),路由是 v4-core 的测试路由;没有用 Universal Router 或 PositionManager。

更多命令:

```bash
forge test --match-contract GasTest -vv             # 有 Hook / 无 Hook 的 swap gas 对比
forge test --match-contract Manipulation -vv        # H-1 回归、按 LP 份额的净成本表
forge test --match-contract ReAudit -vv             # N-1、E-A 的实测数字
forge test --match-path "test/PriorityFee*" -vv     # PriorityFeeHook 的对抗测试表、报价差额、gas 增量
BASE_RPC_URL=https://mainnet.base.org script/probe-priority-fee.sh           # 只读 eth_call 探针,不发交易
CHECK_FORK_BLOCK=56228000 checker/script/check-hook.sh 0x<Hook 地址> <报告名>  # 检查一个链上地址(本地 fork 模拟,只读)
```

## 审计状态

**全部是 AI agent 做的内部审计,不等于外部审计。** 审计员是只读的 AI agent(`hook-auditor`),与写代码的 agent(`hook-engineer`)分开;每轮的报告、PoC 和变体源码都在 [`audits/`](audits/)(公开副本只清理了内部路径与称谓,结论和发现未改)。报告里"项目负责人复核"的段落是协调者 agent 重跑 PoC 的记录,同样不是第三方复核。

| 作品 | 轮次 | 报告 |
|---|---|---|
| `VolatilityFeeHook` | 三轮(首轮、复审、第三轮窄范围复查) | [`audits/audit-hooks-h1.md`](audits/audit-hooks-h1.md)、[`audits/audit-hooks-h1-reaudit.md`](audits/audit-hooks-h1-reaudit.md)(第三轮附在末尾);PoC 在 [`audits/audit-hooks-h1/`](audits/audit-hooks-h1/) |
| `PriorityFeeHook` | 两轮(首轮、窄范围复查) | [`audits/audit-hooks-h2.md`](audits/audit-hooks-h2.md)(第二轮附在末尾);PoC 在 [`audits/audit-hooks-h2/`](audits/audit-hooks-h2/) |
| 检查工具 `checker/` | 两轮(首轮、复审)+ 项目负责人核对收尾修复 | [`audits/audit-hooks-h3.md`](audits/audit-hooks-h3.md)、[`audits/audit-hooks-h3-reaudit.md`](audits/audit-hooks-h3-reaudit.md);变体在 [`audits/audit-hooks-h3/`](audits/audit-hooks-h3/) |

每件作品最后一轮之后的小改都只由项目负责人核对、审计员没有再复看。

**部署脚本(`script/Deploy*.s.sol`、`script/DeployHookBase.sol`、`script/verify-deploy-local.sh`)和依赖安装脚本(`script/install-deps.sh`)是审计之后补的。** 发布前由同一个内部 AI agent 审计员做过**一次窄范围审查**(读脚本、对脚本里的检查做变异、在本地 fork 上运行),审查后的修改只由项目负责人核对;这不是对脚本的审计,更不是外部审计。脚本只在本地 fork 上跑过。

**`VolatilityFeeHook` 各轮结论:**

| 轮次 | 报告 | 结论 |
|---|---|---|
| 首轮(2026-11-11) | [`audits/audit-hooks-h1.md`](audits/audit-hooks-h1.md)(PoC:[`audits/audit-hooks-h1/AuditPoC.t.sol`](audits/audit-hooks-h1/AuditPoC.t.sol)) | 修完再审。H-1(tick 边界抖动免费抬费)等,已改合约 |
| 复审(2026-11-11) | [`audits/audit-hooks-h1-reaudit.md`](audits/audit-hooks-h1-reaudit.md)(PoC:[`audits/audit-hooks-h1/ReAudit.t.sol`](audits/audit-hooks-h1/ReAudit.t.sol)) | 修完再审,只需改文档和测试、合约代码可以不动。H-1 已修;新发现 N-1(中)、E-A(中)须写明并补测试;M-1、L-2 残留可作为写明的已知局限 |
| 第三轮(2026-11-11) | [`audits/audit-hooks-h1-reaudit.md`](audits/audit-hooks-h1-reaudit.md) 末尾 | 第三轮(窄范围,只看文档与测试):只剩两处小改,已改;项目负责人核对了这两处(源文件哈希未变、离线 108 条与 fork 15 条全过、措辞已限定、单边池形下界已被断言),审计员未再复看;AI agent 内部审计,不等于外部审计 |

- 三轮 AI agent 内部审计([`audits/audit-hooks-h1.md`](audits/audit-hooks-h1.md)、[`audits/audit-hooks-h1-reaudit.md`](audits/audit-hooks-h1-reaudit.md),第三轮窄范围复查的结论附在后者末尾),**不等于外部审计,未经外部审计不要用于主网资金。**
- 复审之后:合约逻辑没有改(只改了 `src/VolatilityFeeHook.sol` 头部三行注释,字节码逐位相同,salt 和地址未变);文档和测试按复审报告第七、八节改了;第三轮复查之后又按其意见改了文档和测试(`src/` 未动);最后两处小改由项目负责人核对,审计员未再复看。
- 没修、只写明的:N-1、M-1 / E-A、L-2 残留、fork 测试用 mock 代币和测试路由。I-2(审计时没有部署脚本):部署脚本是之后补的,未经审计(发布前只做过一次窄范围内部审查),只在本地 fork 上跑过。

**`PriorityFeeHook` 各轮结论:**

| 轮次 | 报告 | 结论 |
|---|---|---|
| 首轮(2026-11-11) | [`audits/audit-hooks-h2.md`](audits/audit-hooks-h2.md)(PoC:[`audits/audit-hooks-h2/AuditH2.t.sol`](audits/audit-hooks-h2/AuditH2.t.sol)) | 修完再审。合约代码没有需要改的问题;要改的是文档、测试和注释(E-1 代发者做 JIT 不需要是 LP、T-1 空跑的不变量、T-5 (0, 0) 的统一表述等)。必须项已改 |
| 第二轮(2026-11-11) | [`audits/audit-hooks-h2.md`](audits/audit-hooks-h2.md) 末尾 | 窄范围复查:合约逻辑无变化(五个源文件哈希未变),只剩措辞和不变量套件的三句说明;已改(`src/` 未动),由项目负责人核对,审计员未再复看 |

- 两轮 AI agent 内部审计([`audits/audit-hooks-h2.md`](audits/audit-hooks-h2.md),第二轮窄范围复查附在其末尾):合约逻辑无需改;第二轮只剩措辞,已改,由项目负责人核对,审计员未再复看;不等于外部审计;未经外部审计不要用于主网资金。
- 首轮之后:合约逻辑没有改。`src/` 下只改了 `src/libraries/PriorityFeeMath.sol` 的一段注释(字节码逐位相同,init code sha256 仍是 d37f4d49…8cfe9799,salt 2403 和地址未变);其余改的是文档和测试。没有采纳 `hookData` 最高费率(项目负责人定,留作以后的可选项,代价见设计说明 §9 5a)。
- 第二轮之后:`src/` 一个字节没动;改的是文档措辞(抬小费获利的盈亏平衡条件、JIT 需要的资金量)和测试(JIT 资金表的事实测试、只生成重叠情形的自做 JIT 模糊、不变量套件的轮转换成独立计数器并加两条确定性回归测试、覆盖断言补全)。这批修改没有再经审计员看过,由项目负责人核对。

**检查工具 `checker/` 各轮结论:** 首轮 2 高 4 中 7 低(例如被检 Hook 能重入检查器的公开入口,使"每次撤资都回滚"被报成通过),结论"修完再审";修复后复审确认 2 高已修,新发现 2 中 3 低,结论"再改几处由项目负责人核对即可";收尾时 2 中已修,3 低已修或写成已知缺口(例如有一种 fork 切换的情形仍会得到 PASS,由一条测试钉住,见 `checker/README.md`);收尾修复只由项目负责人核对,审计员未再复看。细节见两份报告和 [`checker/README.md`](checker/README.md) 的漏报 / 误报表。

注:`src/VolatilityFeeHook.sol` 头部注释里写的 `research/audit-hooks-h1.md`、`research/audit-hooks-h1-reaudit.md` 是整理前的内部路径,对应本仓库的 `audits/audit-hooks-h1.md`、`audits/audit-hooks-h1-reaudit.md`。源文件自审计起冻结(改一个字节都要重新核对),所以没有改这两行注释。审计报告里的"H1 / H2 / H3"分别指 `VolatilityFeeHook`、`PriorityFeeHook`、检查工具;`hooks/` 指本仓库根目录。

被审计的五个源文件的 sha256(`shasum -a 256 src/*.sol src/*/*.sol`):

```
fed4356589142fa9a6af605f8eb4ccf8717851716076f5c3609c15a432d2394e  src/PriorityFeeHook.sol
d12879750ee9aeca63c7525d5336c8efc5886c6a1a2c7759674ce54b017b004c  src/VolatilityFeeHook.sol
5e9d17890e2ff2537d557977ea70319d45e6b999fda351140706d0873968ac4f  src/base/BaseHook.sol
950d98e56844e6806a052b203f6e6f755cdde66e4f013df1119800b9911cf24b  src/libraries/PriorityFeeMath.sol
ef77c83444a3d8c7052ffe1f408b37613a0578c26eafc4ecd665e4cef87290ed  src/libraries/VolatilityMath.sol
```

## 目录

```
src/
  VolatilityFeeHook.sol         afterInitialize 登记池子,beforeSwap 返回覆盖费率(每个 10 秒桶观测一次)
  libraries/VolatilityMath.sol  纯数学:亚 tick 对数价、衰减、累加、方差→费率、sqrt
  PriorityFeeHook.sol           afterInitialize 登记池子,beforeSwap 按本交易的优先费返回覆盖费率(无状态)
  libraries/PriorityFeeMath.sol 纯数学:饱和减法取优先费、免征额 + 线性 + 封顶的费率表
  base/BaseHook.sol             公共基类(自己写的,不是官方的):外部回调非 virtual + onlyPoolManager,转调 internal virtual 的 _xxx;
                                未实现的回调 revert;构造时校验 PoolManager 有代码、地址 14 位权限位逐位一致
test/                           两个 Hook 的测试(单元、模糊、对抗、不变量、gas);test/fork/ 对 Base 主网真实 PoolManager
script/
  install-deps.sh               按钉死的 commit 拉依赖
  MineHookAddress.s.sol / MinePriorityFeeHookAddress.s.sol   只读:打印 CREATE2 salt 和地址
  DeployVolatilityFeeHook.s.sol / DeployPriorityFeeHook.s.sol / DeployHookBase.sol   部署脚本(未审计,只在本地 fork 跑过)
  verify-deploy-local.sh        在本地 anvil(fork Base)上把两个部署脚本跑一遍并读回结果
  PriorityFeeProbe.sol / probe-priority-fee.sh   只读 eth_call 探针
checker/                        Hook 安全检查工具(单独的 Foundry profile),见 checker/README.md
  samples/、test/mocks/         故意有漏洞的最小模型,禁止部署
  reports/                      检查器自测生成的两张样本检出矩阵
docs/
  VolatilityFeeHook.md / PriorityFeeHook.md   每个 Hook 的设计说明
  research/                     写 Hook 之前整理的两份事实表(AI agent 整理,自报"未核实"的标注原样保留)
audits/                         五份内部审计报告(AI agent)及其 PoC / 变体源码
PUBLISHING.md                   发布清单(维护者用)
lib/                            依赖,不入库,由 script/install-deps.sh 拉取
```

`audits/` 下的 `.sol` 是审计员当时写的 PoC 和变体的原件(索引和说明见 [`audits/README.md`](audits/README.md)),不在任何 Foundry profile 的编译范围内;要跑的话按各报告里的"跑法"复制到对应目录。其中的变体同样是故意有缺陷的模型,禁止部署。

## 依赖(钉死的版本)

`lib/` 不入库。`script/install-deps.sh` 用 git 把下面四个仓库按 commit 拉到 `lib/`,并核对检出的 commit(已在全新目录里实测:拉依赖 → `forge build` → 离线测试全过)。

| 目录 | 来源 | commit | 许可证 | 用在哪 |
|---|---|---|---|---|
| `lib/v4-core` | github.com/Uniswap/v4-core | `59d3ecf53afa9264a16bba0e38f4c5d2231f80bc`(2025-05-13,npm `@uniswap/v4-core` 1.0.2;v4-periphery 自己钉的也是它) | 多数文件 MIT;8 个文件 BUSL-1.1(`PoolManager.sol`、`Pool.sol`、`Position.sol`、`Lock.sol` 等);`src/test/` 下 1 个 GPL-3.0-or-later、其余多为 UNLICENSED | `PriorityFeeHook` 的 import 闭包全是 MIT 文件;`VolatilityFeeHook` 直接 import 的也都是 MIT 文件,但其中的 `StateLibrary.sol` 又 import 了 `Position.sol`(BUSL-1.1);测试从源码部署 `PoolManager`(BUSL-1.1);`checker/src` 的 import 闭包里有 5 个 BUSL-1.1 文件 |
| `lib/v4-periphery` | github.com/Uniswap/v4-periphery | `c6e4754dab11bd38c6f08ac51c3c868569e93d64`(main,2026-10-26;该仓库没有 tag) | MIT | `test/shared/HookMiner.sol`(测试与脚本);`src/lens/V4Quoter.sol`(只在测试里部署);`src/libraries/LiquidityAmounts.sol`(checker) |
| `lib/solmate` | github.com/transmissions11/solmate | `4b47a19038b798b4a33d9749d25e570443520647`(v4-core 该 commit 的子模块指针) | AGPL-3.0-only(个别文件 MIT) | `MockERC20`(连同它继承的 `ERC20.sol`,两个文件都是 AGPL-3.0-only):两个 Hook 只在测试里用;`checker/src` 也 import 了它 |
| `lib/forge-std` | github.com/foundry-rs/forge-std | `dc647cc030d9d65910d8f1172a0cde48d7106e32`(master,2026-11-02,tag `v1.17.0` 之后第 10 个 commit;`package.json` 写的版本仍是 1.17.0) | MIT OR Apache-2.0 | 测试与脚本 |

- 只拉每个依赖的顶层,**不初始化它们自己的子模块**:`remappings.txt` 把所有 import 指到 `lib/` 下唯一的一份,全工程只有一份 v4-core。
- 与事实表建议的差别([`docs/research/uniswap-v4-hooks-base.md`](docs/research/uniswap-v4-hooks-base.md) §2.2 建议 v4-periphery 钉 `7ebd04b161745b75ed0c24ba2df3bc7c25f65606`):这里钉的是 main。main 已把 `BaseHook` 和 `src/utils/HookMiner.sol` 移到 Uniswap/v4-hooks-public,所以 `HookMiner` 从 `v4-periphery/test/shared/HookMiner.sol` 引入(没有与 `7ebd04b1` 的版本逐字 diff),`BaseHook` 是本仓库自己写的。两个 commit 钉的 v4-core 相同。

## 编译设定

`foundry.toml`:solc **0.8.26**(`PoolManager.sol` 的 pragma 写死这个版本,测试要从源码部署它)、evm **cancun**、optimizer 800 次、不开 via_ir、`bytecode_hash = "none"`。`gas_limit = 8e9` 只是测试执行上限(H-1 回归测试一条里跑 15,000 笔 swap,约 1.2e9 gas),不是编译参数,不影响字节码。

**改任何编译参数或 Hook 源码(注释以外的任何改动)都会改变 init code,必须重新挖地址。** 只改注释不会:`bytecode_hash = "none"` 时字节码末尾不带源码元数据哈希。复审后改过一次头注释,改前改后 `forge inspect VolatilityFeeHook bytecode` 的 sha256 都是 `d0d7d802…ae8b70`,挖矿脚本输出不变。H2 首轮审计后改了 `PriorityFeeMath.sol` 的一段注释,`forge inspect PriorityFeeHook bytecode` 的 sha256 改前改后都是 `d37f4d49…8cfe9799`。

## 地址挖矿

v4 用 Hook 地址的低 14 位表示它启用了哪些回调。PoolManager 建池时只检查 return-delta 位有没有对应的基础位;**14 位完全一致的检查只在 Hook 自己的构造函数里**(`BaseHook` 构造时调 `Hooks.validateHookPermissions`),所以挖错地址的 Hook 部署不出来。

- 库:`HookMiner.find(deployer, flags, creationCode, constructorArgs)` → `(address, salt)`,然后 `new Hook{salt: salt}(args)`。`flags` 可以是任意 14 位组合。
- `deployer`:测试里是测试合约自己;`forge script` / `forge create` 走确定性部署代理 `0x4e59b44847b379578588920cA78FbF26c0B4956C`(forge-std 的 `CREATE2_FACTORY`),此时构造函数里的 `msg.sender` 是代理。
- 脚本(只读,不广播):

```bash
POOL_MANAGER=0x498581fF718922c3f8e6A244956aF099B2652b2b forge script script/MineHookAddress.s.sol \
  --rpc-url https://mainnet.base.org   # --rpc-url 可省;带上时脚本会只读地检查 POOL_MANAGER 在该链上有代码
# 2026-11-11 首轮审计修复后的源码与编译设定下的输出(复审后只改了注释,重算结果相同):
#   salt 4820 (0x12d4),地址 0x4B7651999822ba687E96bbaE929A41f7E0AB9080(低 14 位 0x1080)
# 修复前的地址 0xCb42...1080(salt 27329)已作废:源码变了,init code 就变了。
```

`PriorityFeeHook`(权限位同为 `0x1080`,init code 不同,所以要单独挖):

```bash
POOL_MANAGER=0x498581fF718922c3f8e6A244956aF099B2652b2b forge script script/MinePriorityFeeHookAddress.s.sol \
  --rpc-url https://mainnet.base.org
# 2026-11-11 当前源码与编译设定下的输出(首轮审计后只改了 PriorityFeeMath.sol 的注释,重算结果相同):
#   salt 2403 (0x963),地址 0xBeb0026Aa9eF43478b921106D56Ebc7b1eD75080(低 14 位 0x1080)
#   `forge inspect PriorityFeeHook bytecode` 的 sha256:d37f4d49…8cfe9799
```

salt 不是密钥;但它只对"这份字节码 + 这个构造参数 + 这个 deployer"有效。上面的地址只是算出来的,**没有部署**。

## 部署脚本(未审计;只在本地 fork 上验证过)

`script/DeployVolatilityFeeHook.s.sol`、`script/DeployPriorityFeeHook.s.sol`(公共逻辑在 `script/DeployHookBase.sol`):

- PoolManager 按 chain id 取:8453(Base 主网)、84532(Base Sepolia),出处是事实表 §1.1 / §1.2;**其他链直接 revert `UnsupportedChain`**。
- 现场挖 salt,`new Hook{salt: salt}(poolManager)`,然后断言:部署地址 = 挖出的地址、地址低 14 位 = 权限位、地址上有代码、`hook.poolManager()` = 表里的 PoolManager、`Hooks.validateHookPermissions` 通过;同一条链上已经部署过就 revert `AlreadyDeployed`(不会在下一个 salt 上再部署一份)。
- 这些断言是纵深防御。真正拦住错 salt、错构造参数、普通 CREATE 的是 Hook 自己的构造函数(回滚 `HookAddressNotValid`),不是脚本。负向测试(`test/fork/DeployScriptsNeg.t.sol`,做法是把一个坏的部署结果交给脚本)钉住了部署后 5 条断言里的 4 条(地址不等、无代码、PoolManager 不对、`validateHookPermissions`)和"CREATE2 代理不存在"的检查;第 5 条"低 14 位"(`PermissionBitsMismatch`)在地址检查通过之后不可能触发,没有测试,删掉它任何测试结果都不变。
- `AlreadyDeployed` 也可能是因为别人用同一 salt 抢先部署了同一份 init code。CREATE2 地址由 init code 决定,那个地址上的合约与本脚本会部署的逐字节相同,没有 owner,可以直接使用;用前用 `cast code` 和 `cast call <hook> 'poolManager()(address)'` 自行核对。
- **脚本自己不读任何环境变量**(`vm.startBroadcast()` 不带参数,全文没有 `vm.env*` 调用)。签名者是交给 forge 的那一个:keystore(`--account <名字>`)或硬件钱包(`--ledger` / `--trezor`)。注意 forge 自己还会从环境变量 `ETH_KEYSTORE`、`ETH_KEYSTORE_ACCOUNT`、`ETH_PASSWORD` 取 keystore 的选择;加 `--broadcast` 之前确认它们没有设置,或者设的正是你要用的。不要用 `--private-key`。
- 没有改 `foundry.toml`;脚本自己不写任何文件(forge 照常把运行记录写到 `broadcast/` 和 `cache/`,两者都不入库)。

**这两个脚本没有经过审计(只做过一次窄范围内部审查,见"审计状态"),只在本地跑过。测试网 / 主网部署需要项目负责人批准并由其本人操作。** 本地验证(可重复):

```bash
BASE_RPC_URL=https://mainnet.base.org forge test --match-contract "DeployScripts(Neg)?ForkTest" -vv   # fork 内模拟,3 + 5 条
script/verify-deploy-local.sh    # 起一个 fork Base 的本地 anvil,用 anvil 的解锁开发账户把两个脚本真的 --broadcast 一遍(目标是 http://127.0.0.1:<端口>),再用 cast 读回
forge script script/DeployVolatilityFeeHook.s.sol --rpc-url https://mainnet.base.org           # 不带 --broadcast:只模拟,不发任何交易
```

- `verify-deploy-local.sh` 发交易的目标只有 `http://127.0.0.1:<ANVIL_PORT>`。发任何东西之前,下面四项有一项不满足就拒绝:`ANVIL_PORT` 是纯数字(所以这个 URL 不会被拼成别的主机);该端口上还没有东西在听;它自己启动的 anvil 进程活着;该端口上的节点能回答 `anvil_nodeInfo` 且 chain id 是 8453。fork 源(`BASE_RPC_URL`)只读。
- 每次 `forge script`(包括上面最后一行这种不带 `--broadcast` 的模拟)都会在 `broadcast/Deploy<Hook>.s.sol/<chain id>/` 下留一份运行记录(不入库)。本地 fork 的 chain id 也是 8453,所以只要 `broadcast/Deploy<Hook>.s.sol/8453` 存在,`verify-deploy-local.sh` 就会拒绝运行("refusing to run: … already exists")。把那个目录移走或删掉再跑。

## 没做的事

- **没有外部审计。** 没有公开赏金。
- **没有部署到任何公共网络**(主网、测试网都没有)。README 里的 Hook 地址只是算出来的。
- **参数没有回测**:两个 Hook 的常量都是工程起点,没有用历史数据校准,没有估算任何池子的 LP 收入。
- 没有在 Universal Router、PositionManager、Permit2、真实的 4337 EntryPoint / 代付入口下测过;滑点与路由用的是 v4-core 的测试路由和自写的最小测试路由。
- 收税代币、rebasing 代币、无返回值代币没有专项测试(Hook 不碰代币,但没有测)。
- `PriorityFeeHook`:JIT 资金用闪电贷筹的路径没有测;条件交易的排序行为在测试里复现不了;盈亏平衡点里的 gas 数是假设值。
- 检查工具:没有 JSON 输出;没有在 Base Sepolia 上跑过;对真实第三方地址的输出没有人逐条复核。
- 部署脚本未审计:发布前由同一个内部 AI agent 审计员做过一次窄范围审查,审查后的修改只由项目负责人核对。在 Base 主网状态上只在本地 fork 里跑过;对 Base Sepolia 只做过一次只读的模拟(不带 `--broadcast`),模拟跑通。没有向任何公共网络发过交易。
- 事实表里研究员自报"未核实"的条目没有逐条复核。
- 没有 CI。

各设计说明里的"没做 / 没验证"清单更细。

## 许可证

MIT,见 [`LICENSE`](LICENSE)。只覆盖本仓库自己的文件(源文件头部标的是 `SPDX-License-Identifier: MIT`)。`lib/` 下的依赖不随本仓库分发,各自保留自己的许可证,其中有的不是 MIT(BUSL-1.1、AGPL-3.0-only,见上表);这些许可证对编译、部署本仓库代码有什么约束,我们没有做法律判断。

## 免责声明

本仓库是工程与审计能力的展示,不是可直接上线的产品。**未经外部审计,不要直接用于主网资金。** 内部审计由 AI agent 完成,不等于外部审计。作者不对使用这些代码造成的任何损失负责。文档里关于链上行为、费用分布和第三方协议的数字是整理时的读数或估算,可能已经过时,使用前请自行核实。本仓库的任何内容都不是投资建议。`checker/` 的输出不是对任何第三方项目的安全结论。
