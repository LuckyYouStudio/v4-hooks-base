# checker/ — Uniswap v4 Hook 安全检查工具

对任意一个 v4 Hook(本地部署的,或 fork 上已部署的地址)跑一组**通用**检查,每项给出 通过 / 失败 / 不适用 / 无法判定 和依据。Foundry 测试形式,只在本地模拟里运行。

**先读这五条:**

- **通过全部检查不等于安全,不等于审计。** 检查的是"所有 Hook 都可能犯"的那几类通用问题;一个 Hook 自己的经济模型、记账公式、链下依赖,这个工具一概不看(见"检出能力的边界")。"通过"的意思只是"这一组探测没有发现问题",每项的摘要里写了探测了多少、没探测什么。
- **"失败"不等于有漏洞。** 它的意思是"这里有一条机器看不懂、需要人看的证据"。锁仓类 Hook 的设计本来就会让 d 项报失败(误报来源见下)。
- **只做检测。** 没有任何针对线上合约的可用攻击代码;不发交易到任何公共网络,不读不用私钥;fork 是本地模拟。`samples/` 和 `test/mocks/` 里的 Hook 是故意写坏的最小模型,**禁止部署**。
- **被检的 Hook 是不可信代码,它可以针对检查器作弊。** 它能认出自己正在被检查然后装乖,这个工具防不住(见"漏报"第一张表之后的"Hook 可以认出检查器");它能回调检查器,这一条有防护(见"稳健性")。
- **经两轮内部审计(AI agent),第二轮的必须项已改、由项目负责人核对;未经外部审计。** 首轮 [`audits/audit-hooks-h3.md`](../audits/audit-hooks-h3.md),复审 [`audits/audit-hooks-h3-reaudit.md`](../audits/audit-hooks-h3-reaudit.md)(都是 `hook-auditor`,AI agent 内部审计,不等于外部审计)。复审的结论是"再改几处由项目负责人核对即可",本版是按复审意见改完的版本;这一轮改动没有再经审计员看。

## 怎么跑

Foundry 不在 PATH 时用 `~/.foundry/bin/forge`。检查器用单独的 profile,不影响 `hooks/` 默认 profile 下两个 Hook 的编译产物和原有测试:`checker` 跑检查器自己的测试,`checker-run` 是命令行入口用的(同一份编译产物,区别只在允许写文件的目录)。

```bash
# 在仓库根目录执行(文档里说的 hooks/ 就是仓库根)

# 1. 检查器自己的测试(离线)
FOUNDRY_PROFILE=checker forge build
FOUNDRY_PROFILE=checker forge test --no-match-path "checker/test/fork/*"

# 2. 检查器在 Base fork 上的测试(固定区块 56,228,000 和它的前一块,对真实 PoolManager;第一次要从公共 RPC 拉状态,耗时看 RPC——这一版没有在冷缓存下重新量过,上一版是十几到二十几分钟;状态都在本地缓存里时实测十几秒到几分钟)
FOUNDRY_PROFILE=checker BASE_RPC_URL=https://mainnet.base.org forge test --match-path "checker/test/fork/*"

# 3. 检查一个链上(fork)或本地 anvil 上的 Hook 地址,报告打印到终端,给了名字就同时写到 checker/reports-local/<名字>.md
CHECK_FORK_BLOCK=56228000 checker/script/check-hook.sh 0x<hook 地址> my-report
#    等价于:
FOUNDRY_PROFILE=checker-run HOOK=0x<hook 地址> CHECK_RPC_URL=https://mainnet.base.org CHECK_FORK_BLOCK=56228000 \
  CHECK_REPORT=my-report forge test --match-contract '^CheckHook$' -vv
```

入口的环境变量(`test/CheckHook.t.sol` 头注释是权威说明):

| 变量 | 含义 |
|---|---|
| `HOOK` | 必填。不给则该测试跳过 |
| `CHECK_RPC_URL` | fork 的 RPC(缺省取 `BASE_RPC_URL`)。本地 anvil 上的 Hook 填 `http://127.0.0.1:8545` |
| `CHECK_FORK_BLOCK` | 固定区块;不给则用最新块(报告不可复现) |
| `POOL_MANAGER` | Base(8453)/ Base Sepolia(84532)缺省用事实表 §1 的官方地址。**其他任何链必须显式给**,不给入口直接以 `PoolManagerRequired(chainId)` 报错退出。这个地址**不会**从被检 Hook 读取(Hook 自报一个它控制的"PoolManager"就能决定全部九项结果)。报告末尾注明地址是操作者给的还是文档里的 |
| `POOL_CURRENCY0` `POOL_CURRENCY1` `POOL_FEE` `POOL_TICK_SPACING` | 可选的 PoolKey。给了 `POOL_CURRENCY1` 才生效;`CURRENCY0` 缺省原生 ETH,`FEE` 缺省动态费标志 `8388608`,`TICK_SPACING` 缺省 60。池子已存在就直接用,不存在就由检查器初始化 |
| `CHECK_NATIVE=true` | 不给 PoolKey 时,自建池的 currency0 用原生 ETH |
| `CHECK_REPORT=名字` | 同时写 `checker/reports-local/<名字>.md`(该目录在 `.gitignore` 里;`checker-run` profile 只对这一个目录有写权限) |
| `CHECK_STRICT=true` | 有任何一项"失败"、或整份报告作废,就让测试失败(给自己的 Hook 做 CI 用) |

**在自己的 Foundry 测试里检查刚部署的 Hook**(不需要 RPC):继承 `HookChecker`,调 `runChecks`。

```solidity
import {HookChecker} from "checker/src/HookChecker.sol";
import {Status, Report, CheckConfig} from "checker/src/CheckerTypes.sol";

contract MyHookCheck is HookChecker {
    function test_generic() public {
        CheckConfig memory cfg;
        cfg.manager = manager;        // 本地 PoolManager,或 fork 上的真实 PoolManager
        cfg.hook = address(myHook);
        // cfg.hasKey = true; cfg.key = ...;   // 可选:指定池子
        Report memory rep = runChecks(cfg);
        console2.log(renderReport(rep));
        assertFalse(rep.voided, rep.voidReason);
        assertTrue(rep.findings[D_REMOVE].status != Status.FAIL, rep.findings[D_REMOVE].summary);
    }
}
```

`runChecks` 结束时把 EVM 状态整体回滚(时间、gas 价、建的池子、检查器自己的路由合约)。对 `VolatilityFeeHook` 连跑两次,两份报告逐字节相同(`test_runChecks_leavesNoStateBehind`;只对这一个 Hook 测过,别的 Hook 没有这条测试)。

`runChecks` 不可重入:运行期间再调它(例如被检 Hook 回调)会以 `CheckerBusy` 回滚。**你的测试合约里凡是会改模拟环境的公开函数——`vm.createSelectFork` / `vm.selectFork` / `vm.rollFork` / `vm.chainId` / `vm.warp` / `vm.roll` 之类,包括 `setUp()` 和自己写的辅助函数——请加上 `notWhileChecking` 修饰符**:被检 Hook 能在回调里调到它们,理由见"稳健性"。

**运行第三方字节码前要知道的三件事。**

1. Foundry 的 cheatcode 地址对被模拟的合约也是可调用的:在非 fork 的测试里,任何合约都能调 cheatcode(实测:测试创建的、`vm.etch` 放上去的都可以——能写文件、能改任意合约的代码和存储、能读环境变量;`test_H1_toolingFailure_isProbeFailureNotControlRevert` 里的玩具 Hook 就是用它把检查器的路由代码抹掉的);在 fork 模式下,不是测试创建的代码调 cheatcode 会被 Foundry 拒绝(`test_fork_foreignCodeHasNoCheatcodeAccess`;审计员另外试过外来代码 CREATE 出来的子合约,同样被拒,那一条没有留成测试)。所以:**检查别人的 Hook 一律走 fork 入口(上面第 3 种),不要把别人的字节码拿到本地测试里部署。**
2. **环境变量里不要放任何密钥。`BASE_RPC_URL` / `CHECK_RPC_URL` 如果带 API key,它就是环境变量里的密钥**:检查第三方代码时请用不带密钥的公共端点(例如 `https://mainnet.base.org`)。本地模式下恶意代码读环境变量再经 RPC 请求带出去,这条路径是推论,没有实测;fork 模式下外来代码调不了 cheatcode。
3. 本工具自己只读 `HOOK`、`CHECK_*`、`POOL_*`、`BASE_RPC_URL` 这几个变量。命令行入口(`checker-run` profile)只能往 `checker/reports-local/` 写文件,那个目录不入库;入库的 `checker/reports/` 只有检查器自测的两张矩阵,入口没有它的写权限。检查器自测(`checker` profile)对 `checker/reports/` 有写权限——所以第 1 条说的"不要在本地测试里跑别人的字节码"同样是在保护这些文件。

## 状态的含义

| 报告里 | 含义 |
|---|---|
| `PASS` 通过 | 这一项的探测没有发现问题。只说明"这些探测没发现",不说明没有;摘要里写了探测的范围 |
| `FAIL` 失败 | 有一条确定的、可复现的证据(具体哪一步、什么回滚原因写在明细里)。是不是漏洞要人判断 |
| `N/A` 不适用 | 这一项对这个 Hook 没有意义(例如静态费池的动态费检查) |
| `UNKNOWN` 无法判定 | 工具下不了结论,需人工:要么探测做不了(建不出池子、检查器自己的工具坏了、有场景没测成),要么看到了只能当提示的现象,要么带 Hook 的池和对照池一起回滚 |
| 报告首部 `REPORT VOID` 整份作废 | 运行过程中检查器脚下的链被别人动了:当前 fork 变了、chain id 变了,或 fork id 没变但区块号 / 时间戳不在检查器自己留下的位置(`vm.rollFork`、`vm.warp`、`vm.roll`;靠检查器自己的时钟发现,见"稳健性",那里也写了发现不了的情形)。九项全部记 `UNKNOWN`,首部写明原因;**Setup 段和明细都不输出**(两处都带着来自被检 Hook 的文字),`Report.setup` 清空。两条作废测试断言了报告全文不含 `PASS` 这个词:离线 `test_N3_voidReport_chainIdChanged_noPassAnywhere`(Hook 先让一条含 "PASS" 的回滚字符串进了 Setup,再改 chain id)和 `test_N4_clockMovedUnderTheChecker_void`,fork 上 `test_fork_reentry_unguardedForkSwitch_voidsTheReport`、`test_fork_r2_mode1_…`、`test_fork_r2_mode2_…` 三条。这句话的依据就是这几条测试,别的作废路径没有逐条测。`Report.voided` 为真 |

## 检查器怎么工作

1. **建测试池。** 没给 PoolKey 时:部署两个 18 位小数的 mock 代币,依次尝试 (动态费, 60)、(3000, 60)、(500, 10)、(100, 1) 四种 (fee, tickSpacing),初始 tick 6931(价格约 2.0,**故意不用 1:1**:平价下 token0 / token1 记混了也看不出来),第一个 `initialize` 成功的就用。四个都被 Hook 拒绝 → 没有测试池,需要池操作的检查项报"无法判定"。给了 PoolKey 时用给定的池(fork 上的真实池子用 forge 的 `deal` 给测试路由发币;发不了的代币如实报)。
2. **对照池。** 同样的两个币、同样的 tickSpacing、**不挂 Hook** 的池子,每一步操作在两边各做一次。每一步的结果分五类:带 Hook 的池成功;Hook 明确拒绝(回滚出自 Hook 回调,带自定义 error 或字符串);意外(Hook 回调里 Panic / 空回滚 / 未实现 / 耗尽 gas,或只有带 Hook 的池回滚);**两边都回滚**(不算到 Hook 头上,**也不算没问题**:Hook 可能正是两边回滚的原因,例如它控制着池里的代币);**探测失败**(检查器自己的工具坏了)。两条判定规则(复审 N-2,`test_N2_classifyOrder` 逐条断言):
   - **先做 Hook 归因。** 回滚出自 Hook 回调(v4 的 `WrappedError`,target 是这个 Hook)就归到 Hook 头上,对照池回滚也好、工具坏了也好,都不覆盖它。
   - **"探测失败"只认环境事实,不认回滚数据长什么样**:操作失败时检查器自己的某个路由或 PoolManager 没有代码、当前 fork 或 chain id 变了、区块号 / 时间戳不在检查器自己留下的位置。回滚数据在池内合约手里——代币的 `balanceOf` 回滚会不加包装地冒到最外层——所以形状像 Foundry `CheatcodeError` 的回滚照常显示、照常按上面的规则分类,只在文字后面注明"形状像 Foundry cheatcode 报错,池内任何合约都能产生这种数据"(`test_N2_forgedCheatcodeError_sameVerdictAsControl`)。代价:检查器自己的 cheatcode 真出错时(没有遇到过),那一步会被算成"只有带 Hook 的池回滚"或"两边都回滚",要靠这条注记认出来。
3. **两个 LP 头寸**(当前 tick 两侧各 120 个 spacing,每个约 1000 单位代币)、四种 swap 各一笔、一笔 donate,前后各推进一分钟。
4. **在这个状态上做 11 种扰动**(每种做完整体回滚):基线;时间 +1 小时;+400 天;价格推到区间下方 / 上方;只剩一个 LP;检查器的流动性全部撤出;gas 价 0;gas 价 5000 gwei;basefee 高于 gas 价;价格推出区间后再过 15 秒。每种扰动下:四种 swap(两个方向 × exactIn / exactOut)各一笔,然后依次"只领手续费 → LP A 撤一半 → 撤剩下的 → LP B 全撤"。扰动本身做不成的(例如 Hook 拒绝了用来推价格的大额 swap),该场景标 `NOT TESTED`,d、e 的摘要里写明跑了几个场景、哪几个没测。扰动步骤自己就是池操作,失败了照样计数:推价格的那笔 swap 失败计入 e;"只剩一个 LP / 全部撤出"两个场景里先让 LP 全撤的那一步失败,**按普通撤资步骤分类并计入 d**(复审 N-1),然后才把场景标 `NOT TESTED`。推价格只用一笔大额 swap,没有做"大额推不动时改用多笔小额"。
5. **直接探测**:以 PoolManager 身份、以无关地址身份直接调 10 个回调,记录回滚与否、返回值、状态 diff(`vm.startStateDiffRecording`)。

操作都经过自己的 `CheckerRouter`(持有测试资金、做一步 PoolManager 操作、把自己的 delta 结清,不对结果的形状做任何断言)。

**稳健性。** 所有会碰到被检 Hook 的调用都经过 `SafeCall`:带 gas 上限(一次 PoolManager 操作 3,000 万——低于 Base 在区块 56,228,000 的区块 gas 上限 4,000 万,一次直接探测 1,000 万),返回数据最多拷贝固定字节数。回滚数据的解码是手写的带边界检查的版本(不用 `abi.decode`)。`test/Robustness.t.sol` 用 9 种恶意 / 损坏的"Hook"(返回垃圾、2 MB 返回数据、2 MB 回滚数据、死循环、`INVALID`、长度不对的返回值、带控制字符的回滚字符串、海量事件与写入、截断的 `WrappedError`)× 4 种地址位组合,加上没有代码的地址、没有代码或本身是垃圾的 PoolManager、不合法的 PoolKey:**在这些列出来的情形下**,每次运行都返回了完整的 9 项报告、报告全文是可打印 ASCII,各项具体是什么状态以该文件里的断言为准(不是每一格都断言了)。`test/Units.t.sol` 里解码器和字节码扫描各有"任意输入不回滚"的模糊测试。这些测试没有覆盖的 Hook 行为,检查器会不会出错,没有证据。

**来自 Hook 的文字。** 回滚字符串是不可信文本:截到 96 字节,只保留字母、数字、空格和 `. , : ; ' - + = / % @ &`,其余一律换成 `?`(markdown 有含义的 `[ ] ( ) ! * _ # ~ \ < > |`、反引号、双引号都在被换掉之列),再放进一对反引号里(裸 URL 不会被渲染成链接)。`test_L1_markdownInRevertStringIsNeutralised`、`test_revertInfo_asciiWhitelist`。文字内容本身(例如一句"audited, safe")仍会出现在明细里,读报告的人要知道引号里的话是 Hook 说的,不是检查器说的。

**Hook 可以回调检查器。** forge 测试合约的地址是可预测的,检查器路由的 `owner()` 也指向它,所以被检 Hook 在回调里能调到检查器的任何公开函数。首轮审计的 H-1 就是这样:Hook 调命令行入口,入口里的 `vm.createSelectFork` 不随嵌套调用的回滚而撤销,检查器此后在另一个 fork 上继续跑,自己的路由在那里不存在,每一步"两边都回滚",撤流动性被堵的 Hook 得到 d = PASS。现在有三层:

1. `runChecks` 和命令行入口 `test_checkHook` 带重入保护(`notWhileChecking`),运行期间的嵌套调用在碰到任何 cheatcode 之前以 `CheckerBusy` 回滚。保护位在外层快照之前写入,运行中的状态回滚清不掉它(`test_H1_runChecksIsNotReentrant`:Hook 在每一次 swap 回调里都重入,全程被拒)。
2. 运行前记下 `vm.activeFork()`(非 fork 模式记"无 fork")、chain id,以及**检查器自己的时钟**:区块号和时间戳只有检查器自己推进(每次推进同时记账;快照回滚时账和 EVM 状态一起回滚,两者始终一致)。setup 之后、每个场景回滚之前和之后、每一笔单独快照的 swap 回滚之前、a / b / c 各项之后、c 的录制流程结束时、整个运行结束时各核对一次:fork id 变了、chain id 变了、或区块号 / 时间戳不在检查器自己留下的位置 → **整份报告作废**(见"状态的含义"),fork 被切走的话结束前切回原来的 fork。这一层防的是第 1 层管不到的入口:**你自己测试合约里没加 `notWhileChecking` 的公开函数**(`setUp()`、辅助函数)。
   - 切到另一个 fork:fork id 那条腿,`test_fork_reentry_unguardedForkSwitch_voidsTheReport`、`test_fork_r2_mode1_switchInsideScenarioSnapshot_void`。
   - **`vm.rollFork`:fork id 不变,靠时钟。** roll 之后区块号和时间戳是目标区块的,对不上检查器的账。`test_fork_r2_mode2_rollFork_void`(作废原因里写着两组数字)。修之前这种情况不作废:c 在"被测池已不存在"的状态上报通过,e 把 `PoolNotInitialized` 算到 Hook 头上(复审 N-4)。离线没有 fork 可 roll,用 `vm.warp` 的替身测同一条腿:`test_N4_clockMovedUnderTheChecker_void`。
   - **为什么要在回滚之前也看一眼**:回滚到 roll 之前拍的快照会把旧状态和旧区块号原样放回去(临时探针实测),中间看到的东西就悄悄混进结果了。上面那条离线测试的 mode 5 就是"只在单笔 swap 的快照里动时钟"。
   - **为什么是时钟,不是复审建议的"带标记的小合约"或"检查器自己建的池是否还在"**:两种都试了,在 Base fork、forge 1.9.0 上实测都不可靠。测试期间 CREATE 出来的合约在 `vm.rollFork` 之后连同存储都还在,标记合约发现不了 roll;检查器在 PoolManager 里初始化的池,roll 发生在嵌套调用里时(Hook 回调正是嵌套调用)有时被重置、有时原样留着,取决于 roll 前后同一调用帧里读写过什么——复审 mode 2 里被测池没了而对照池还在,就是这个现象。区块号 / 时间戳在试过的每一种情形里都变了。这些是黑盒实测(临时探针测试,没有留在仓库里;复审 mode 2 那一条可以从修复前的输出里看到:带 Hook 的池上是 `PoolNotInitialized`,对照池上同样的 swap 成功),原因没有查清,换一个 forge 版本可能不一样。
   - 切到别的 fork 又在同一次调用里切回来:原 fork 的状态完好,时钟对得上,不作废,结果与对照相同(`test_fork_r2_mode3_switchAndBack_sameAsControl`)。
3. 操作失败时发现检查器自己的工具坏了(路由或 PoolManager 没有代码、fork 或 chain 变了、时钟对不上)记成"探测失败",该项 `UNKNOWN`,不进入"两边都回滚"的分支。只认这些环境事实,不认回滚数据的形状;**出自 Hook 回调的回滚仍然先归到 Hook**(见"检查器怎么工作"第 2 条)。`test_H1_toolingFailure_isProbeFailureNotControlRevert`、`test_N2_routerWiper_stillProbeFailure_andDNotPass`、`test_N4mut_lpRouterWiped_dIsProbeFailureNotPass`。

防不住的:
- **`vm.rollFork` 到"时钟此刻显示的那个区块号和时间戳"**:链状态被换掉了,而 fork id、chain id、区块号、时间戳都没变,不作废。最现实的情形是检查器还没推进过时间(setup 的建池和加流动性阶段)时 roll 回 fork 自己所在的区块;`test_fork_r2_pinned_sameBlockRollBeforeTheClockMoved_notVoid` 钉住了这个现状(那一次的结果恰好是"加不进流动性,d / e / f 无法判定",没有据此下结论,但这不是检查器保证的)。推进过时间之后还要碰巧 roll 到同号同时间戳的区块才躲得过;
- 本地(非 fork)模式下 Hook 直接用 cheatcode 改检查器的存储或代码(三层的状态都在存储里),或者改完环境在下一个核对点之前改回去(chain id 改了又改回、`vm.warp` 过去又 warp 回来);
- 不动 fork id、chain id、区块号、时间戳的环境改动:本地模式下 Hook 调 `vm.store` / `vm.etch` / `vm.deal` / `vm.fee` 之类;
- **所以你自己测试合约里的公开函数如果会改环境(`vm.createSelectFork`、`vm.selectFork`、`vm.rollFork`、`vm.chainId`、`vm.warp`、`vm.roll` …),请自己加 `notWhileChecking`**。第 2 层是兜底:它让结果作废,不让结果变对,而且有上面这些漏的。

所以第三方代码只走 fork 入口。在 fork 上的回归测试用的是 `vm.etch` + `vm.makePersistent` 放上去的替身 Hook,不是真正部署在链上的合约;没有用 anvil 上真实部署的 Hook 端到端复现过。

## 每项检查查什么

出处里的"§"指 `../docs/research/uniswap-v4-hooks-base.md`(事实表)。

### a. 权限位三方一致

- **查什么**:① 地址低 14 位;② `getHookPermissions()`(合约暴露且能解成 14 个布尔值时);③ 实际行为——地址位声明的每个回调,真实的 PoolManager 流程有没有走通过它。三者逐项对比,另查 4 个 return-delta 位有没有对应的基础位。
- **怎么查**:行为以真实流程为准(建池、加 / 撤流动性、swap、donate 成功,就说明这次操作涉及的已声明回调被 PoolManager 调用并接受了返回值);流程没覆盖到的回调,再以 PoolManager 身份在一次 `unlock` 里直接调。返回值按 PoolManager 的规则判(前 4 字节等于自身选择器;`beforeSwap` 必须正好 96 字节;开了 return-delta 位的 after 回调必须正好 64 字节,§4.2)。
- **判定**:声明了却没有实现(空回滚 / `HookNotImplemented()` / 字节码里找不到该选择器)或返回值会被 PoolManager 拒绝 → 失败;**`beforeRemoveLiquidity` / `afterRemoveLiquidity` 属于这种情况时单独标出"撤流动性被堵死"**;`getHookPermissions()` 与地址不一致 → 失败;return-delta 位没有基础位 → 失败。声明的回调只是在探测参数下回滚、流程也没走到 → 无法判定。
- **对应规则 / 事故**:§3.2(PoolManager 建池时只查 return-delta 配对,14 位全等的检查只在 Hook 自己的构造函数里;多挖一位而函数不存在,撤流动性永远回滚——事实表里这是推论,样本 S1 把它实测了)、§4.2、H1 复审 N-4、H1 首轮 L-1。
- **不暴露 `getHookPermissions()` 的 Hook**:第 ② 条跳过,报告里写明。**地址比合约实际实现的少任何一位(不只是 return-delta 位),只有在 ② 可用时才查得出来**;不暴露时 a 报通过(`test_pinned_a_missingBit_onlyVisibleThroughGetHookPermissions`)。少的那一位对应的回调永远不会被 PoolManager 调用,少的是 return-delta 位时返回的 delta 被静默忽略(§3.2 要点 2)。

### b. 回调可被非 PoolManager 调用

- **查什么**:10 个回调,每个用一个无关地址直接调,共 200 次(8 个带 hookData 的回调各 22 次,2 个 initialize 回调各 12 次)。变的是弱校验最常拿来代替 `msg.sender` 的三样东西,每组输入在 / 不在一次 `unlock` 里各调一次:
  - 回调的 `sender` **参数**:检查器的路由 / 调用者自己 / Hook 自身 / PoolManager;
  - `tx.origin`:不动 / 设成调用者(`sender` 是路由和是调用者各一次);
  - hookData:空、1、4、20、32、64 字节(64 字节的是"一个地址加一个数额")。

  每次记录是否回滚、改了几个存储槽(其中几个是 Hook 自己的)、发了几个事件、有没有转 ETH 或建合约。这是固定的几组值,不是搜索。
- **判定**:
  - 不回滚且有上述任何一种效果 → **失败**(Cork 事故的模式);效果不限于 Hook 自己的存储,只发事件、只改别的合约也算(`test_M2_effectOutsideTheHooksOwnStorage_detected`);
  - 不回滚、没观察到效果:对字节码**全文**(不切任何"元数据尾巴")做线性扫描,完全没有 `SSTORE / TSTORE / LOG / CALL / CALLCODE / DELEGATECALL / CREATE / SELFDESTRUCT` → 通过,摘要写的是"这段代码自己写不了状态、也调不出去(它的返回值会让调用方做什么不在判断之内)";否则 → 无法判定(本次输入下没看到效果,不代表别的输入没有;transient storage 的写入状态 diff 看不到)。**solc 编译出来、带元数据尾巴的合约走不到这个"通过"**:尾巴的第一个字节(CBOR 头 `0xa1`–`0xa4`)在全文扫描里读作 `LOG1`–`LOG4`,所以它们一律是无法判定(`test_scan_solcOutputWithTrailerIsNeverStateless`、`test_echoSelector_wrongLengths`);
  - 回滚,但**同样的调用由 PoolManager 发出时回滚数据逐字节相同**(且不是"未实现")→ 无法判定:这次回滚不是调用方校验,是参数被拒,Hook 有没有校验调用方看不出来(只对地址位声明了的回调、只对"空 hookData"和"64 字节 hookData"两组输入做这个比较);
  - 其余 → 通过,摘要是"**在这 200 组探测输入下**每个回调都拒绝了非 PoolManager 的调用者;以别的输入(某个特定的 sender、tx.origin 或 hookData 值)为条件的旁路没有排除"。
- **带旁路的调用方校验可能查不出。** `msg.sender == pm || <别的条件>` 这种写法,只有当"别的条件"恰好被上面某一组输入满足时才会被发现:`|| hookData.length == 1` 查得出(失败);`|| sender == 某个写死的路由地址`、`|| tx.origin == 某个写死的 keeper` 查不出,b 报通过(`test_M2_bypassOnUnknownValue_stillPass_pinned`)。
- **对应事故**:§8.4 Cork(2025-05-28,`beforeSwap` 没限制调用方);§4.4;H1 首轮 L-1(modifier 不随 override 继承)。
- **为什么要在 `unlock` 里再试一次**:回调真实运行时 PoolManager 处于解锁状态。会动 PoolManager 记账的回调在锁定状态下必然 `ManagerLocked`,只在锁定状态下探测会把"没有调用方校验"误判成"拒绝了"(`test_M2_missingCheckVisibleOnlyInsideUnlock_detected`)。

### c. 陌生池污染

- **查什么**:一个陌生地址拿同一个 Hook 地址建池,三种:① **自己的两个代币、不同的初始价**(先试与被测池相同的 fee / tickSpacing,被拒再换 tickSpacing、再换 fee 类型);② **极端参数两个**(各用自己的两个新代币,fee 同被测池):都用最大 tickSpacing 32767,初始 tick 一个是 MIN_TICK + 1、一个是 MAX_TICK − 1,头寸铺满全区间(没有用最小 tickSpacing:那样一笔横穿全价格区间的 swap 要走约 7,000 个 tick 位图字,在 fork 上每个都是一次 RPC 读)——"任何人可以用极端参数建池"就是这两个点,不是搜索(复审 N-5);③ **与被测池共用 currency0、另一个币是它自己的**(同样的 fee / tickSpacing;按币种而不是按池记账的状态靠这个碰到。共用的那个币在陌生池里也排在 currency0:检查器跳过若干 nonce,让自己的新代币地址排在它后面——这一点原来是碰运气的,取决于此前建过几个合约,加极端参数池时才发现,`test_N5_sharedCurrencyPool_sharedTokenIsCurrency0ThereToo`;连跳 64 个 nonce 都排不到后面时明细行注明"共用的币在这个池里是 currency1";被测池的 currency0 是真实代币而 forge `deal` 发不了它时,这个池建得出来但陌生人在里面什么也做不成,明细行会注明"could not be given a balance of the shared token",**这一路等于没测**)。每个建成的池里:加流动性、小额 swap 两笔、把价格一路推到两端、exactOut 一笔、donate 一笔。然后看被测池的 **9 步参考操作**:6 笔固定的 swap(4 种组合 + 1 小时后再 2 笔)、LP A 只领手续费、LP A 撤四分之一、LP A 再加八分之一——每一步的结果(路由的 delta、池子成交量、费率、是否回滚及回滚的选择器)与"没有陌生池"时是否逐项相同;并用状态 diff 找"陌生池活动改掉的 Hook 存储槽"与"被测池参考操作读写的 Hook 存储槽"的交集。两组各在一个必定回滚的调用帧里做,互不影响。
- **判定**:
  - 有参考操作在陌生池活动之后变成"从 Hook 回调里回滚"(而没有陌生池时不是这样)→ **失败,而且先于下面所有分支报出**,包括探测失败(复审 N-2;`test_N2_checkC_hookAttributedDifferenceBeatsProbeFailure`);
  - 录制过程中发现检查器自己的工具坏了(环境事实,同"检查器怎么工作"第 2 条)→ 无法判定(`test_N10mut_toolingBrokenDuringStrangerActivity_cIsProbeFailure`);
  - 陌生池全被拒:被测池存在(检查器自己建成了,或给定的池已存在)→ 通过;**检查器自己也一个池都没建成 → 无法判定**(那只说明"这组 mock 代币 / 参数不被接受",不说明 Hook 怎么对待陌生池);
  - 接受且 9 步参考操作有任何不同 → **失败**。比的是每一步的成败、回滚选择器、路由的数额、(swap 的)池内数额和费率:只改数额不回滚的(`test_N5mut_…`、`test_N11mut_…`)、只改回滚原因的(`test_N6mut_…`)、只改池内数额和费率而路由数额不变的(`test_M10mut_…`)各有一条测试;
  - 接受、结果相同,但**没有陌生池时 9 步里一步都没成功、或 6 笔 swap 全失败** → 无法判定:本来就不工作的操作显示不出陌生池改了什么(复审 N-4;`test_N4_referenceFlowThatDoesNotWork_cIsUnknown`)。摘要一律写"没有陌生池时 9 步成功了 N 步(6 笔 swap 成功 M 笔)";
  - 接受、结果相同、但有共用且被改掉的存储槽 → 无法判定;
  - 接受、结果相同、但某一次录制里 Hook 的不同存储槽超过 1024 个 → 无法判定(超出的没有跟踪,交集不完整,明细行标 `INCOMPLETE`;`test_L6_moreSlotsThanTracked_isUnknownNotPass`);
  - 接受、无共用槽、结果相同 → 通过;接受但没有被测池可比 → 无法判定。
- **对应规则**:§8.1(`initialize` 无权限,任何人可拿任意代币建挂着你 Hook 的池;状态必须按 PoolId 分开)、H2 审计 I-1。
- **注意**:"接受陌生池"本身不算问题(我们自己的两个 Hook 都接受任何动态费池,状态按 PoolId 隔离)。

### d. 撤流动性能否被堵

- **查什么**:上面 11 种扰动(除"流动性全部撤出"外)下,依次做 只领手续费(`liquidityDelta == 0`)→ LP A 撤一半 → 撤剩下的 → LP B 全撤,扰动都做得成时共 39 步。"只剩一个 LP"的场景里最后一步就是最后一个 LP 离场。另外,"只剩一个 LP"和"流动性全部撤出"两个场景在**搭场景**时要先让 LP 全撤(前者 LP B,后者 LP B 再 LP A):这几笔撤资失败时同样分类、计数(成功时不计数,所以全部顺利时总数仍是 39)。
- **判定**(按这个顺序):
  - 有任何一步"因 Hook 回滚"(回滚出自 Hook 回调——v4 的 `WrappedError` 里 target 是这个 Hook,不管对照池怎样、不管检查器的工具是什么状态;或带 Hook 的池回滚而对照池不回滚)→ **失败**,不区分原因。**搭场景时的全撤被 Hook 回滚也算**(复审 N-1:限速式的"单次撤出不得超过池子 40%"在两个等额 LP 时谁都无法一步离场,检查器只在搭场景那一步碰到它;`test_N1_rateLimitExit_setupWithdrawalIsCounted_dFails`);
  - 否则有探测失败 → 无法判定;
  - 否则有"两边都回滚"的步骤 → **无法判定**,摘要写明"撤流动性在这里回滚,带 Hook 的池和对照池都一样;没有算到 Hook 头上,但也没有排除"(`test_H2_freezerHook_bothPoolsRevert_isNotPass`);
  - 否则**有任何场景 `NOT TESTED` → 无法判定**(复审 N-1,项目负责人定)。场景做不做得成掌握在被检 Hook 手里:它拒绝了推价格的那笔 swap,价格场景就没测,而它可能正好只在价格出区间时堵撤资(`test_N1b_untestedScenarios_dIsUnknownNotPass`)。摘要写"跑过的每一步都成功,但 N 个场景没测成,不在这个结果之内";
  - **只有 10 个场景都搭成、带 Hook 的池上每一步都成功才通过**(`test_N1_passNeedsEveryScenario`)。
  - 摘要一律写全:成功几步 / 共几步、因 Hook 回滚几步、两边都回滚几步、探测失败几步、跑了几个场景、哪几个场景 `NOT TESTED`(`test_H2_maxSwapHook_untestedScenariosAreNamed`)。
  - 流动性加不进去 → 无法判定。
- **e 项不按这条降级**(项目负责人定):e 有场景没测、其余全成功时状态仍是通过,摘要末尾注明"没测的场景不在这个结果之内"。推价格的 swap 失败本身已经计入 e,所以 Hook 拒绝或弄坏那笔 swap 时 e 本来就不是通过;e 是通过而有场景没测,只出现在场景因为撤资搭不成的时候("只剩一个 LP / 全部撤出")。
- **对应规则 / 事故**:本仓库的设计约束"任何情况下不得堵死撤流动性";§8.3 第 1 条(罚金 `donate` 在区间内流动性为 0 时回滚,堵死最后一个 LP,样本 S6)、第 2 条(只领手续费也走 remove 回调)、第 6 条(remove 路径上任何可能回滚的东西都是暂停开关);§4.3。

### e. swap 能否被卡死

- **查什么**:11 种扰动下 4 种 swap 各一笔;基线另加 1 wei 的两笔(exactIn,两个方向)和 100 倍大小的四笔(两个方向 × exactIn / exactOut);扰动都做得成时共 50 笔。把价格推出区间用的大额 swap 失败时也计入。
- **判定**(给"设计上的拒绝"和"意外回滚"分类的线索):
  - **意外** → **失败**:Hook 回调里 `Panic`(溢出、除零、越界…)、空回滚、未实现、耗尽 gas;或回滚不是从回调里出来的,但只在带 Hook 的池上发生(`InvalidHookResponse`、`HookDeltaExceedsSwapAmount`、`CurrencyNotSettled`、`LPFeeTooLarge` 等);
  - 探测失败 → 无法判定;
  - **拒绝** → 无法判定:Hook 回调以自定义 error 或 `Error(string)` 回滚(可能是设计,例如只认特定路由;也可能卡死,工具分不出);基线就全被拒时摘要会提示"可能需要特定路由或 hookData";
  - **两边都回滚** → 无法判定(同 d);
  - 只有带 Hook 的池上跑过的每一笔都成功才通过。摘要的写法同 d。
- **对应规则**:§8.3 第 6 条、§4.2、§6.2(Hook 留下未清零的 delta,用户的交易 `CurrencyNotSettled`)、§5.3(100% 费率下 exactOut 回滚)。
- **"永久"两个字查不了**:工具只看到"在这个扰动下回滚",看不到之后能不能恢复。样本 S7 的"闲置 256 小时后永远回滚"是在"+400 天"场景里被看到的。

### f. 动态费

- **只在动态费池上做**(静态费池 → 不适用)。
- **查什么**:每笔成功 swap 的费率从 `Swap` 事件读(是 LP 费与协议费合成后的总费率,§4.3),各扰动下的数值都列在 e 项的明细行里。另做**同块测试,两个方向各一次**:同一区块、同一 gas 价下,先一笔预热 swap(不参与比较),再两笔完全相同的小额 swap,然后一笔反向大额 swap,再一笔相同的小额 swap,比较三笔小额的费率。
- **判定**:Hook 返回的覆盖费率超过 100%(PoolManager 以 `LPFeeTooLarge` 回滚)→ **失败**;**全程每一笔的费率都是 0 → 无法判定**,并提示两种可能:这个 Hook 不管费率(那么动态费池不是它合适的测试池,请给 PoolKey),或者它想设费率却没设上(`beforeSwap` 返回的费率漏了 `OVERRIDE_FEE_FLAG`,或从没调 `updateDynamicLPFee`);同块内相同 swap 的费率不同 → 无法判定(**只是提示**"费率依赖单笔交易能改变的量",不下结论);同块测试有一个方向跑不了 → 无法判定;看到 100% 费率会注明 exactOut 在该费率下回滚;否则通过。
- **后果要知道**:检查器自建池优先用动态费池,所以**任何不管费率的 Hook 在自建池模式下 f 都是无法判定**(样本矩阵里 S1、S2、S4–S7、S10 的 f 列都是这样)。这是噪音,换来的是"忘了 OVERRIDE 标志"不再被报成通过。
- **对应规则 / 事故**:§5.1–§5.3、§8.2"动态费"、§8.3 第 5 条(费率依据取自 slot0 可被同笔交易推走再推回);我们自己 H1 的教训。
- **这一项查不出我们自己 H1 首轮的 H-1**(tick 边界上灰尘抖动免费抬费):那是跨块、要特定金额序列的操纵,同块测试看不到。费率抗操纵的成本分析这个工具不做。

### g. 可升级 / 管理员迹象(只提示)

- **查什么**:EIP-1967 的 implementation / admin / beacon 三个槽是否非零;EIP-1167 最小代理;`owner()`、`admin()`、`getAdmin()`、`governance()`、`governor()`、`guardian()`、`pendingOwner()`、`implementation()`、`proxiableUUID()`、`paused()` 这些 view 有没有 32 字节的回答;对字节码**全文**做线性扫描(跳过 PUSH 的立即数),看有没有 `DELEGATECALL` / `CALLCODE` / `SELFDESTRUCT` 操作码。
- **判定**:一条迹象都没有 → 通过;有 → 无法判定并逐条列出。**这一项永远不报"失败"**:可升级是信任假设,不是 bug。
- **元数据尾巴不切。** 形状像 Solidity 元数据尾巴的那段字节同样参与扫描、同样算迹象:那个形状(末两字节是长度、开头是 CBOR 头)可以伪造,里面只要有一个 `JUMPDEST` 就能放可达代码。某个操作码只出现在尾巴形状的字节里时,明细行会注明"只在形似元数据尾巴的末段出现,多半是数据字节,但尾巴里可以藏代码,所以照列"(`test_M3_delegatecallInsideFakeMetadataTrailer_listedInG`)。代价是误报:真实合约的尾巴里有 34 字节的哈希,其中恰好出现 `0xf4` / `0xf2` / `0xff` 时 g 会多一条提示。
- **对应规则**:§8.2"可升级"、§2.3(事实表在那一节把两个官方 Hook 记为 UUPS 代理——**据事实表,未复核**)、本仓库的设计约束"Hook 不可升级、没有管理员能动用户资金"。

### h. Hook 持有的资金(只报事实)

- **查什么**:Hook 地址上两种池币的余额、原生 ETH、在 PoolManager 里的 ERC-6909 凭证余额,检查器操作前后各读一次。
- **判定**:都为 0 → 通过;有任何非零 → 无法判定(持有资金是设计选择,谁能把它取走这一项看不出来);没有测试池 → 不适用(只报原生 ETH)。
- **对应规则**:§6.2(ERC-6909 凭证是持久存储)、§8.1 第 3 条(代持资金要按"池 + 币"记账)。

### i. return delta:Hook 拿走多少(事实 + 一致性提示)

- **只在地址带 return-delta 位时做**(否则不适用:PoolManager 忽略 Hook 返回的 delta,§3.2)。
- **查什么**:基线 4 种 swap 各一笔,`Swap` 事件里池子的成交量减去路由实际的 delta,就是 Hook 的 delta(§6.6);换算成"占该币种池子成交量的百万分之几"。另报 LP A 基线全撤拿回的数量与对照池的对比。
- **判定**:Hook 在 4 种组合里拿的比例一致(或都不拿)→ 通过;不一致(有的拿有的不拿,或比例相差超过四分之一)→ 无法判定(**提示**:是设计上的不对称,还是方向 / 符号记错?);Hook 同时改了两个币种(接管撮合,自定义曲线)→ 无法判定(定价是经济模型,不判);LP 拿回的比对照池少 10% 以上 → 无法判定。**这一项永远不报"失败"**:工具不知道设计规定的数额。
- **对应规则 / 事故**:§6.3–§6.6、§8.2"记账"、§8.4 Bunni(舍入方向,只是同一大类,见"漏报")。

## 漏洞样本库 `samples/`

每个文件头都有醒目的"故意有漏洞,禁止部署"。每个文件里是一个有缺陷的最小模型和一个修好的对照版本(对照版本只修这一个问题,仍然是玩具,同样不要部署)。地址用仓库里的 `HookMiner` 挖,由测试合约 CREATE2 部署。**都是抽象模型,不是任何真实协议的复刻。**

| 样本 | 缺陷模式 | 出处 | 检查器应报 |
|---|---|---|---|
| `S1_ExtraPermissionBit` | 地址多挖了 `BEFORE_REMOVE_LIQUIDITY` 位,合约没有这个函数,构造函数也不校验地址 | §3.2、H1 复审 N-4 | a 失败(标出撤资被堵)、d 失败 |
| `S2_NoCallerCheck` | `beforeSwap` 不校验调用方,凭参数记"奖励额度",`claim()` 按额度付款 | §8.4 Cork 的最小模型 | b 失败 |
| `S3_GlobalState` | "成交量分档"动态费,成交量是全合约一个变量,陌生池刷量把所有池子的费率打到低档 | §8.1 | c 失败 |
| `S4_WrongDeltaDirection` | `afterSwap` 收 0.10% Hook 费,金额永远按 `amount1` 算,但收的币种是 unspecified 币种(四种组合里有两种是 currency0) | §6.3 / §6.4;"记账方向"一类 | **只有 i 的提示,没有失败** |
| `S5_SharedSlotGuard` | 重入锁与"已付款"标记用了同一个写死的存储槽,解锁时把标记抹掉,赏金可以反复领 | "锁与记账量共用存储槽"这一类缺陷的抽象模型,不对应任何具体合约或事故 | **检不出** |
| `S6_DonatePenalty` | 撤资罚金在 `afterRemoveLiquidity` 里 `donate` 回池子,区间内没有流动性时回滚 | §8.3 第 1 条 | d 失败 |
| `S7_StaleOverflow` | 按闲置小时数做 `2**hours` 衰减,闲置 256 小时后溢出,时间戳只在成功的 swap 里更新 | §8.3 第 6 条 | e 失败 |
| `S8_SpotFee` | 动态费按"当前 tick 与上一笔 swap 时 tick 的距离"算 | §8.2、§8.3 第 5 条 | f 无法判定(同块提示) |
| `S9_UncappedFee` | "闲置加价"动态费没有上限,超过 100% | §5.2 / §5.3 | f 失败、e 失败 |
| `S10_UpgradeableAdmin` | swap 逻辑在 owner 可随时替换的 `DELEGATECALL` 目标里 | §8.2"可升级" | g 无法判定(列出三条迹象) |

S2、S4、S5 另有不经过检查器的 PoC 测试(`test/SamplePoC.t.sol`),证明这三个玩具里的缺陷是真的、对照版本里没有:S2 伪造回调后把奖励储备领空;S4 在价格约 2 时多收一倍;S5 把 5 ETH 分 5 次领空。

**回归变体 `test/mocks/AuditVariants.sol`、`test/mocks/Reaudit2Variants.sol`。** 两轮审计时审计员写的变体(原件在 `../audits/audit-hooks-h3/` 和它下面的 `reaudit/`)复制进来,加上随修复补的几个,同样是故意有缺陷的抽象最小模型、文件头写明禁止部署,用 `vm.etch` 放到测试地址上。`test/AuditRegression.t.sol`、`test/Reaudit2Regression.t.sol` 对每一个断言检查器现在的回答:修好的断言修好了,**仍然查不出的也断言"现在报的是什么"**(测试名带 `pinned`),下面的漏报表逐条引用它们。fork 上的重入回归在 `test/fork/ForkReentry.t.sol`。

## 检出情况:误报与漏报

下表是 `test/Samples.t.sol::test_matrix_writeFile` 的原样输出(`reports/local-samples-matrix.md`);`SampleRegistry._expected` 把每一格都断言了,fork 上对真实 PoolManager 再跑一遍(`reports/fork-samples-matrix.md`)要求结果相同。

| sample | a | b | c | d | e | f | g | h | i |
|---|---|---|---|---|---|---|---|---|---|
| S1 ExtraBitHook | FAIL | PASS | PASS | FAIL | PASS | UNKNOWN | PASS | PASS | N/A |
| S1 ExtraBitHookFixed | PASS | PASS | PASS | PASS | PASS | UNKNOWN | PASS | PASS | N/A |
| S2 NoCallerCheckHook | PASS | FAIL | PASS | PASS | PASS | UNKNOWN | PASS | PASS | N/A |
| S2 NoCallerCheckHookFixed | PASS | PASS | PASS | PASS | PASS | UNKNOWN | PASS | PASS | N/A |
| S3 GlobalStateHook | PASS | PASS | FAIL | PASS | PASS | PASS | PASS | PASS | N/A |
| S3 GlobalStateHookFixed | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | N/A |
| S4 WrongDeltaHook | PASS | PASS | PASS | PASS | PASS | UNKNOWN | PASS | UNKNOWN | UNKNOWN |
| S4 WrongDeltaHookFixed | PASS | PASS | PASS | PASS | PASS | UNKNOWN | PASS | UNKNOWN | PASS |
| S5 SharedSlotGuardHook | PASS | PASS | PASS | PASS | PASS | UNKNOWN | PASS | UNKNOWN | N/A |
| S5 SharedSlotGuardHookFixed | PASS | PASS | PASS | PASS | PASS | UNKNOWN | PASS | UNKNOWN | N/A |
| S6 DonatePenaltyHook | PASS | PASS | PASS | FAIL | PASS | UNKNOWN | PASS | PASS | PASS |
| S6 DonatePenaltyHookFixed | PASS | PASS | PASS | PASS | PASS | UNKNOWN | PASS | PASS | PASS |
| S7 StaleOverflowHook | PASS | PASS | PASS | PASS | FAIL | UNKNOWN | PASS | PASS | N/A |
| S7 StaleOverflowHookFixed | PASS | PASS | PASS | PASS | PASS | UNKNOWN | PASS | PASS | N/A |
| S8 SpotFeeHook | PASS | PASS | PASS | PASS | PASS | UNKNOWN | PASS | PASS | N/A |
| S8 SpotFeeHookFixed | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | N/A |
| S9 UncappedFeeHook | PASS | PASS | PASS | PASS | FAIL | FAIL | PASS | PASS | N/A |
| S9 UncappedFeeHookFixed | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | N/A |
| S10 UpgradeableAdminHook | PASS | PASS | PASS | PASS | PASS | UNKNOWN | UNKNOWN | PASS | N/A |
| S10 UpgradeableAdminHookFixed | PASS | PASS | PASS | PASS | PASS | UNKNOWN | PASS | PASS | N/A |

与首轮审计时的矩阵相比,变的只有 f 列:S1、S2、S4、S5、S6、S7、S10(有缺陷的和对照版本共 14 格)从 PASS 变成 UNKNOWN。它们都不是费率 Hook,在检查器自建的动态费池里全程费率为 0,按新规则不再报通过(f 一节"后果要知道")。原来以"失败"检出的 6 个样本(S1 的 a 和 d、S2 的 b、S3 的 c、S6 的 d、S7 的 e、S9 的 e 和 f)都还是失败。

复审之后的这一轮修改(d 在有场景没测时最多无法判定、探测失败只认环境事实、c 的极端参数池和"空比较"规则等)**没有改变矩阵里任何一格**:本地和 fork 两张矩阵重新生成后与改之前逐字节相同。20 个样本的 d 都是 10 个场景全部搭成,没有因为 `NOT TESTED` 降级的。

我们自己的两个 Hook(`VolatilityFeeHook`、`PriorityFeeHook`):本地自建池、原生 ETH 池、别人已建好的池(6 位 / 18 位小数的代币)、Base fork 上的真实 PoolManager,a–h 全部通过、i 不适用(`test/OwnHooks.t.sol`、`test/fork/ForkChecker.t.sol`),两轮审计后的新规则下都没有变化:两个都是费率 Hook,费率不为 0;检查器建得出池,陌生池(包括两个极端参数池)被接受后 9 步参考操作相同、无共用槽;d 的 10 个场景都搭得成,没有 `NOT TESTED`。

### 漏报

**样本里的问题,检查器没有报"失败"的:**

| 样本 | 检查器给出的 | 为什么 |
|---|---|---|
| S4 return delta 记错方向 | i = 无法判定(提示"四种组合里拿的比例不一致:999 / 1998 / 2000 / 999 ppm"),**没有任何一项失败** | 工具不知道设计规定 Hook 该拿多少,只能看四种组合是否一致。而且这个提示依赖测试池的价格不是 1:1(检查器自建池用价格 2);在给定的 PoolKey 恰好接近平价时连提示都没有(这一句是推论,没有专门的测试)。Hook 本来就设计成按方向不对称收费时,这个提示是误报 |
| S5 重入锁与标记共用存储槽 | h = 无法判定(只是"Hook 持有 10 ETH"这个事实),**没有任何一项指向问题** | `claim()` 不是 Hook 回调。工具不知道一个非回调函数应该做什么,没有通用的办法检查它 |
| S8 现货价动态费 | f = 无法判定(提示) | 按任务要求只提示、不下结论:同块费率变化是否可被利用取决于经济模型 |
| S10 可升级 | g = 无法判定(列迹象) | 可升级是信任假设,不判失败 |

**首轮审计(`../audits/audit-hooks-h3.md` 第三节第 1 条)列出的漏报,逐行对应。** "现在"一栏是本版检查器的实际回答,由右边的测试断言;标"仍漏报"的行,检查器今天仍然给出通过。

| 审计表里的变体 | 当时 | 现在 | 测试(`AuditRegression.t.sol` / `fork/ForkReentry.t.sol`) |
|---|---|---|---|
| b:`pm \|\| hookData.length == 1` | b PASS | b 失败(1 字节 hookData 的探测打开了它) | `test_M2_bypassOnHookDataLength_detected` |
| b:`pm \|\| sender 参数 == 写死的路由` | b PASS | **仍漏报:b PASS**。摘要改成"在这 200 组输入下被拒,别的输入下的旁路没有排除" | `test_M2_bypassOnUnknownValue_stillPass_pinned`(mode 1) |
| b:`pm \|\| tx.origin == 写死的 keeper` | b PASS | **仍漏报:b PASS**,同上 | 同上(mode 2) |
| b:伪元数据尾巴里藏 `SSTORE` | b PASS"harmless" | b 无法判定(全文扫描看到了 `SSTORE`) | `test_M3_sstoreInsideFakeMetadataTrailer_notPass` |
| c:陌生池触发全局开关,堵住所有池的撤资 | c PASS、d PASS | c 失败(参考操作里的只领手续费和撤资变成回滚)。d 仍是 PASS:d 的场景里没有陌生池,这正是 c 的分工 | `test_M1_globalHalt_strangerPoolBlocksWithdrawals` |
| c:全局量在本池满 40 笔 swap 后才读 | c PASS | **仍漏报:c PASS**。参考操作只有 6 笔 swap | `test_pinned_c_delayedPollution_notDetected`(mode 1) |
| c:全局量在首笔 swap 2 天后才读 | c PASS | **仍漏报:c PASS**。参考操作最多往后推 1 小时 | 同上(mode 2) |
| c:mapping 的键只取 PoolId 首字节(256 个桶) | c PASS | **仍漏报:c PASS**。陌生池的 PoolId 没有碰巧撞上同一个桶;检查器不会去凑碰撞 | 同上(mode 3) |
| d:同一个池第 9 次撤资起 Panic | d PASS | **仍漏报:d PASS**。每个场景最多 4 步撤资,做完就回滚 | `test_pinned_d_blocksOutsideThePerturbations_notDetected`(mode 1) |
| d:价格偏离 4 倍以上时拒绝撤资 | d PASS | **仍漏报:d PASS**。检查器只把价格推到自己头寸区间外两个 spacing(spacing 60 时约 2 倍) | 同上(mode 2) |
| d:闲置 2–300 天的窗口内拒绝撤资 | d PASS | **仍漏报:d PASS**。时间扰动只有 +1 小时和 +400 天两个点 | 同上(mode 3) |
| e:exactOut 超过 100e18 时 Panic | e PASS | e 失败(基线加了两个方向的 100 倍 exactOut) | `test_largeExactOutPanics_detected` |
| d:认出检查器后装乖(`tx.origin` 是 forge 默认发送者 / `sender` 能回答 `owner()`) | 全 PASS | **仍漏报:d PASS**(整行是 a–e、g、h 为 PASS;f 无法判定——这两个玩具不管费率;i 不适用),见下面"Hook 可以认出检查器" | `test_pinned_d_hookThatRecognisesTheChecker_notDetected` |
| f:现货价费率只作用于 1→0 方向 | f PASS | f 无法判定(同块测试现在两个方向都做) | `test_spotFeeOnOneDirectionOnly_hinted` |
| f:exactOut 超过 100e18 时费率大于 100% | f PASS、e PASS | f 失败 | `test_feeAbove100PercentOnLargeExactOut_detected` |
| f:忘了 `OVERRIDE_FEE_FLAG` | f PASS"0..0" | f 无法判定并给提示 | `test_L2_forgottenOverrideFlag_feeZeroIsUnknown` |
| d:Hook 冻结池里的代币,两边都回滚 | d PASS"all 28 … went through" | d 无法判定、e 无法判定,摘要写明"撤流动性在这里回滚、两边一样、未排除 Hook"。**没有报失败**:工具分不出是 Hook 冻的还是代币本来就这样 | `test_H2_freezerHook_bothPoolsRevert_isNotPass` |
| fork 入口被重入 | d / e / c PASS | 嵌套调用被拒,结果与不重入的对照相同(d 失败);经没有保护的公开函数切走 fork 时整份报告作废 | `test_fork_reentry_nestedEntryRefused_sameVerdictAsControl`、`test_fork_reentry_unguardedForkSwitch_voidsTheReport` |
| a:地址少一位且不暴露 `getHookPermissions()` | a PASS | **仍漏报:a PASS**,任何缺位都一样(不只是 return-delta 位) | `test_pinned_a_missingBit_onlyVisibleThroughGetHookPermissions` |

**复审(`../audits/audit-hooks-h3-reaudit.md`)新列出的,逐行对应。** 测试在 `test/Reaudit2Regression.t.sol` / `test/fork/ForkReaudit2Regression.t.sol`。

| 复审里的变体 | 复审时 | 现在 | 测试 |
|---|---|---|---|
| d:限速式退出(单次撤出不得超过池子 40%,全撤除外),两个等额 LP 谁都无法一步离场 | d PASS,"NOT TESTED: 1" | d 失败(搭场景的全撤被 Hook 回滚,计入 d) | `test_N1_rateLimitExit_setupWithdrawalIsCounted_dFails` |
| d:拒绝大额 swap,且价格出区间时拒绝撤资 | d PASS,"NOT TESTED: 3" | **没有报失败:d 无法判定**(三个价格场景没测成;检查器只用一笔大额 swap 推价格,没有改用多笔小额) | `test_N1b_untestedScenarios_dIsUnknownNotPass` |
| e:池内代币伪造 `CheatcodeError` 形状的回滚 | e 无法判定"探测失败" | e 失败,九项与不伪造的对照相同 | `test_N2_forgedCheatcodeError_sameVerdictAsControl` |
| c:全局开关只在极端建池参数下触发(\|tick\| > 100000 或 tickSpacing > 1000) | c PASS | c 失败(陌生池加了两个极端参数的池) | `test_N5_globalSwitchTrippedByExtremeParameters_detected` |
| c:全局开关只在检查器没试的建池参数下触发(例:tickSpacing 恰为 200) | — | **仍漏报:c PASS**。极端参数只有两个点,不是搜索 | `test_N5_pinned_c_largeExitOnly_and_untriedParameter_notDetected`(mode 3) |
| c:陌生池照常触发全局开关,但只有"单次撤出超过池内流动性 20%"的撤资才读它 | c PASS | **仍漏报:c PASS**(d 也 PASS)。参考撤资只撤 LP A 的四分之一,即池子的 12.5%;没读到的槽也不进"共用槽" | 同上(mode 2) |
| fork:未加保护的公开函数里 `vm.rollFork` 到另一个区块 | 不作废;c PASS、e 误归因 | 整份作废(检查器的时钟对不上) | `test_fork_r2_mode2_rollFork_void` |
| fork:同上,但 roll 到时钟此刻显示的同一个区块号和时间戳 | — | **仍漏报:不作废**(见"稳健性"的"防不住的") | `test_fork_r2_pinned_sameBlockRollBeforeTheClockMoved_notVoid` |

两张表里"现在"查得出的那几行,查得出的是**那一个变体**:把 100e18 的门槛换成检查器没试的金额、把 1 字节换成 2 字节,就又回到漏报。

**Hook 可以认出检查器,然后装乖。** 被检 Hook 只要在"像是被检查"时表现正常、其余时候作恶,所有检查项都会通过;上表有两个这样的玩具,全表 PASS。这个工具防不住,也没有打算防。检查器身上可识别的特征(至少这些):

- `tx.origin` 是 forge 的默认发送者 `0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38`,`msg.sender` 链上最外层是 forge 测试合约的固定地址;
- 自建池的代币名是 "Checker Token A / B"(符号 CKA / CKB),陌生池的是 "Stranger X / Y / Z / E / F";
- 检查器的路由能回答 `owner()` 和 `manager()`,没有 `msgSender()`;hookData 永远为空;
- 固定的初始 tick(6931,陌生池 -23027 以及 MIN_TICK + 1、MAX_TICK − 1 两个极端池)、固定的头寸宽度(两侧各 120 个 spacing)、固定的操作顺序和时间推进(+60 秒 / +30 块、+1 小时、+400 天、+15 秒);
- gas 价是 0(基线),区块号、时间戳是 fork 点或测试里写死的值;同一个区块里出现几十笔操作;
- 直接探测时的调用者是 `keccak256("hook-checker.attacker")` 派生的固定地址,探测参数是固定的几组;
- 运行在 Foundry 里:cheatcode 地址上有代码。

**11 种扰动之外的,d / e / f 都查不出。** 扰动是固定的 11 个点(见"检查器怎么工作"第 4 条),swap 金额是固定的三档(小额、1 wei、100 倍;把价格推出区间的那一笔更大)。只在别的时间点、别的价格距离、别的金额、第 N 次操作、别的 gas 价、多个条件组合下才出现的回滚或费率,一律看不到;上表的 d 三行就是例子。"扰动之外没有问题"不是这个工具能说的话。

**其余确定查不出的(没有样本,直接写明):**

- 需要特定交易序列才触发的记账错误("压低余额后反复小额提取放大舍入误差"这一类);
- 跨块的费率操纵及其成本(我们 H1 首轮的 H-1 就属于这类,f 项查不出);
- 回调里**没有调用方校验、但会拒绝探测参数**的 Hook:b 项看到的只是回滚。工具会比较"PoolManager 发同样的调用是否同样回滚",相同时报无法判定而不是通过(`test_noCallerCheckBehindStrictHookData_isUnknownNotPass`),但它猜不出能通过校验的 hookData;
- 只在特定 hookData、特定路由(`sender`)、特定代币(收税、rebasing、可冻结)、多跳、重入、JIT、协议费非零时才出现的行为:流程里 hookData 一律为空,路由是检查器自己的,代币是 mock 或给定池的代币,新建池的协议费是 0;
- c 项:陌生池只建三种(自己的两个币;自己的两个币 + 两组极端参数;与被测池共用 currency0)。与被测池共用 currency1、共用两个币但 fee / tickSpacing 不同、由同一个路由建的池、极端参数与共用币种的组合,都没有试;按这些维度记账的全局状态碰不到;
- c 项:**共用币种的陌生池在 `deal` 不了真实代币时那一路等于没测**。给定的池用真实代币、而 forge `deal` 找不到它的余额槽时,陌生人手里没有这个币:池建得出来,加流动性和 swap 都做不成,明细行里有 "could not be given a balance of the shared token" 和 "add liquidity reverted, 0/5 swaps ok",但 c 的状态不因此降级;
- c 项:9 步参考操作里撤资只有一笔(LP A 的四分之一,两个 LP 时是池子的 12.5%)、加仓只有一笔(八分之一):只在更大比例的撤资、全撤、或别的操作里才读到被污染状态的 Hook,c 看不到(上表 mode 2);
- d 项:推价格只用一笔大额 swap。Hook 拒绝大额但允许小额时,价格场景没测成,d 是无法判定而不是失败(上表 N-1b 一行);
- 非回调入口(下单、领取、管理函数)里的任何问题;
- 只写 transient storage 的未授权回调:b 报无法判定,不是失败(`test_M2_acceptedWithoutVisibleEffect_isUnknown`)。

### 误报

**会让没有问题的 Hook 得到"失败"或"无法判定"的情形。** 标了测试名的几行有对照样本;其余是按检查逻辑推出来的,**没有逐条用样本验证**。真实地址试跑里出现的"无法判定"大多属于 a / c / e / f 几行和"通用"一行。

| 项 | 情形 |
|---|---|
| a | Hook 的回调只在特定条件下可用(只认自己建的池、只认特定 `sender`),流程走不到、直接探测又被拒 → 无法判定 |
| b | 回调故意不校验调用方、且会写无害状态或发事件(例如纯统计)→ 失败;回调接受任何调用方且确实无状态,但它是 solc 编译的(元数据尾巴首字节读作 `LOG`)或字节码里别处有 `CALL` → 无法判定(`test_echoSelector_wrongLengths`) |
| c | Hook 有设计上的全局状态(全局参数、全局统计):它影响了参考操作的结果 → 失败;不影响结果但被陌生池改了、被测池也用 → 无法判定(`test_M1_sharedSlotWithoutBehaviourChange_isUnknown`);检查器自己建不出池 → 无法判定;Hook 一次操作写的存储槽超过 1024 个 → 无法判定;被测池的 swap 在检查器手里本来就全部失败(只认特定路由 / hookData 的 Hook)→ 无法判定(`test_N4_referenceFlowThatDoesNotWork_cIsUnknown`;`Robustness.t.sol` 里同样那 10 次运行的 c 也从复审前的通过变成无法判定,这一格没有逐个断言,是改动前后两次运行输出的对比) |
| d | **锁仓 / 归属期 Hook 设计上就会让撤流动性回滚 → 失败**(按本仓库的设计约束这本来就该拿出来看;`test_pinned_falsePositive_timeLock`:7 天上限的锁仓,+400 天场景和只领手续费都通过,其余报失败);撤流动性必须带 hookData 或必须经特定路由的 Hook → 失败;池里的代币本身转不出来(与 Hook 无关的可冻结 / 暂停代币)→ 两边都回滚 → 无法判定;**有任何场景没测成 → 无法判定**,哪怕这个 Hook 根本没有流动性回调:设计上拒绝大额 swap 的 Hook(`test_H2_maxSwapHook_untestedScenariosAreNamed`)、swap 在检查器手里全部失败的 Hook(只认特定路由;`Robustness.t.sol` 里只声明 swap 回调的那一组运行,10 个玩具,其中 4 个的 d 有断言)都是三个价格场景搭不成,d 从复审前的通过变成无法判定;第二个 LP 加不进去时"只剩一个 LP"场景搭不成,同样 |
| e | Hook 用不带信息的 `revert()` / `require(cond)` 做设计上的拒绝 → 被归为"意外"→ 失败;只认白名单路由 → 基线全被拒 → 无法判定;设计上拒绝大额 swap → 无法判定,且三个需要大额 swap 推价格的场景做不成(`test_H2_maxSwapHook_untestedScenariosAreNamed`);一次操作确实需要超过 3,000 万 gas → 失败 |
| f | **不管费率的 Hook 在检查器自建的动态费池里 → 无法判定**(费率全为 0);设计上就按池内状态逐笔定价的费率(例如按库存偏离)→ 同块提示;设计上拒绝大额 swap → 同块测试跑不了 → 无法判定 |
| g | 线性扫描把代码后面的数据字节(常量表、元数据尾巴里的哈希)读成操作码;`owner()` 只管一个无关紧要的参数 |
| h | 收费类 Hook 持有自己的收入是正常的(`test_claimsHeldByTheHook_reported`) |
| i | 设计上不对称的 Hook 费 |
| 通用 | 对照池在被测池是动态费时用 0.30% 静态费,两边价格路径略有不同(恒定 50% 费率的对照 Hook 没有因此被误报:`test_H2_passSummariesCarryCounts`);检查器的路由没有 `msgSender()`,向 `sender` 查最终用户的 Hook 会回滚(§4.4);测试池的参数是检查器选的,不是 Hook 上线时真正用的那个池 |

## 检出能力的边界

这个工具**查不了**:

- **经济模型**:费率曲线是否合理、操纵成本、LVR、激励是否相容、自定义曲线的定价;
- **需要特定交易序列的记账错误**:舍入方向、多步操作之间的状态漂移;
- **链下依赖**:预言机、keeper、签名服务、前端;
- **未验证源码的语义**:工具只看字节码的外部行为,不知道一个函数"本来想做什么";
- **管理员和升级之后的行为**:g 项只能提示"有这个能力";
- **与真实路由、真实代币、PositionManager 的集成**;
- **针对检查器本身的规避**(上面"Hook 可以认出检查器")。

它**能**做的是:在几分钟内排除一批与具体业务无关、但已经让别人丢过钱的通用错误,并把需要人看的证据(哪一步、什么回滚原因、哪个存储槽)列出来。它是审计之前的一道筛子,不是审计。

## 真实地址试跑(冒烟测试;输出不随仓库公开)

开发期间在 Base 主网 fork(固定区块 56,228,000,不带密钥的公共 RPC `https://mainnet.base.org`,真实 PoolManager)上,对 5 个已部署的第三方 Hook 地址各用"检查器自建池"跑了一次,其中 3 个另外用一个链上已存在的池子再跑一次,共 8 份报告。发币类的没有跑。

**这 8 份输出、被检的地址和逐格结果都不放进本仓库。** 它们只用来确认检查器在真实字节码和真实 PoolManager 上跑得通(冒烟测试);输出未经人工逐条复核,"失败"或"无法判定"不等于该地址上的合约有漏洞,"通过"也不等于它安全,**不构成对任何第三方项目的安全结论**,所以不公开。

一句统计(只说工具,不说那些合约):8 次全部跑完、每次都出了完整的 9 项报告、没有一份作废(`REPORT VOID`);72 个结果是 PASS 28 / FAIL 0 / UNKNOWN 35 / N/A 9。

从这次试跑能说的、关于工具本身的事:

- **覆盖面的实际限制**:5 个地址里有 3 个在"自建池"模式下建不出池子(Hook 在 `beforeInitialize` 里拒绝了检查器的 mock 代币池);用链上已有池子跑的 3 次里有 2 次加不进流动性(Hook 在 `beforeAddLiquidity` 里拒绝)。这时 d / e / f / i 只能报"无法判定",c 在建不出池时也是"无法判定"(首轮审计 L-3:原来这里报的是通过)。**这就是工具对"只服务特定池子、只允许特定方做市"的 Hook 的实际覆盖面:只剩 b、g 和 a 的一部分有内容。**
- 复审修改前后对比,72 格状态没有一格变化;与首轮审计前相比有 6 格从 PASS 变成 UNKNOWN(没有反方向的):c 3 格(检查器自己也建不出池,陌生池被拒不再算通过)、g 2 格(`DELEGATECALL` 这个字节值只出现在形似元数据尾巴的末段——"不切尾巴"带来的误报代价)、f 1 格(自建的动态费池里费率全程为 0)。
- 首轮试跑暴露并修掉过检查器自己的一个问题:在 fork 上 Foundry 会把每个子调用的 gas 夹在被 fork 区块的 gas 上限(Base 该区块是 4,000 万)以内,c 项那一整段录制在真实池子上不够用。checker 的两个 profile 里都有 `disable_block_gas_limit = true`(单步操作的 3,000 万上限不变)。
- 没做的:这 8 份输出里的每一条"无法判定"是否合理,没有人逐条看过(首轮审计员抽看过最早那版 8 份里的 4 份,复审时审计员只看了摘要行和首尾;最后一次重新生成的 8 份没有人看过,只机器比对了 72 格状态);没有带 hookData、没有经真实路由;没有重放任何历史交易(没有归档 RPC,也不在范围内)。

**自己跑**(只读,本地 fork 模拟;报告打印到终端,给了名字就同时写到不入库的 `checker/reports-local/<名字>.md`;固定区块的状态要 RPC 还保留着才读得到,公共节点不保证长期保留):

```bash
# 检查器自建池(mock 代币)
CHECK_FORK_BLOCK=56228000 checker/script/check-hook.sh 0x<Hook 地址> <报告名>
# 用链上已存在的池子(例:ETH / USDC、动态费、tickSpacing 10;POOL_CURRENCY0 缺省为原生 ETH)
CHECK_FORK_BLOCK=56228000 POOL_CURRENCY1=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 POOL_FEE=8388608 POOL_TICK_SPACING=10 \
  checker/script/check-hook.sh 0x<Hook 地址> <报告名>
```

对别人的 Hook 跑出来的报告,发布前请自己逐条看过;本工具的输出不是对第三方的安全结论。

## 测试充分性:变异检查

`script/mutate.py` 逐个把检查器的一处判定逻辑改坏,再跑检查器自测,看有没有测试因此失败("被杀")。**只能在 `hooks/` 的副本里跑**:它原地改 `checker/src` 和 `checker/test` 下的文件。下面是复审修改之后在副本里的实际结果(forge 1.9.0;默认跑离线自测,标了"fork"的另外跑了 `ForkReentryTest` 和 `ForkReaudit2RegressionTest`)。三组:

**首轮审计的 12 处(M1–M12)**,语义照旧,模式串按改过的代码重写(M5 现在的写法是"对照池回滚时,出自 Hook 回调的回滚不再先归 Hook"):

| 变异 | 首轮 | 复审前 | 现在 | 杀掉它的测试(之一) |
|---|---|---|---|---|
| M1 Panic 不再算"意外" | 被杀 | 被杀 | 被杀 | `test_S7_vulnerable_swapFlagged` |
| M2 b 不在 unlock 内探测 | 存活 | 被杀 | 被杀 | `test_M2_missingCheckVisibleOnlyInsideUnlock_detected` |
| M3 b 的"效果"只看 Hook 自身存储 | 存活 | 被杀 | 被杀 | `test_M2_effectOutsideTheHooksOwnStorage_detected` |
| M4 c 有共用槽不再报 UNKNOWN | 存活 | 被杀 | 被杀 | `test_M1_sharedSlotWithoutBehaviourChange_isUnknown` |
| M5 对照池回滚可掩盖出自 Hook 的回滚 | 存活 | 被杀 | 被杀 | `test_H2_hookRevertIsAttributedEvenWhenControlRevertsToo` |
| M6 h 不看 ERC-6909 余额 | 存活 | 被杀 | 被杀 | `test_claimsHeldByTheHook_reported` |
| M7 f 同块测试不比较大额反向 swap 之后那笔 | 被杀 | 被杀 | 被杀 | `test_sameBlockFeeMovedByALargeSwap_hinted` |
| M8 i 不看比例差 | 被杀 | 被杀 | 被杀 | `test_S4_vulnerable_onlyAHint` |
| M9 e 去掉 1 wei 和 100 倍 swap | 存活 | 被杀 | 被杀 | `test_dustSwapPanics_detected` |
| M10 c 比较时不看费率和池内数额 | 存活 | 存活 | **被杀** | `test_M10mut_feeChangeHiddenFromTheRouterAmounts_detected` |
| M11 d 去掉"只领手续费"和"最后一个 LP"两步 | 被杀 | 被杀 | 被杀 | `test_S6_vulnerable_removeFlagged` |
| M12 b 的"与 PoolManager 回滚相同"比较关掉 | 被杀 | 被杀 | 被杀 | `test_noCallerCheckBehindStrictHookData_isUnknownNotPass` |

M10 是靠新写的 `RoundingAbsorberHook` 杀掉的:陌生池把 LP 费率从 3000 改成 3001 pips,Hook 用 return delta 把交易者的数额凑成 1e15 的整数倍,路由看到的数额不变,只有池内数额和费率变了。

**"撤销首轮一项修复"的 14 处(R1–R14)**:离线 13 处被杀;R2(不再核对 fork)只在 fork 上显形,fork 上被杀。R1(去掉重入保护)离线和 fork 上都被杀。

**"撤销复审一项修复"的 12 处(Q1–Q12,本轮新写)**:

| 变异 | 结果 | 杀掉它的测试(之一) |
|---|---|---|
| Q1 搭场景时撤资失败不计入 d | 被杀 | `test_N1_rateLimitExit_setupWithdrawalIsCounted_dFails` |
| Q2 有场景没测时 d 仍报通过 | 被杀 | `test_N1b_untestedScenarios_dIsUnknownNotPass` |
| Q3 `CheatcodeError` 形状的回滚又算探测失败 | 被杀 | `test_N2_forgedCheatcodeError_sameVerdictAsControl` |
| Q4 `_classify` 先看工具状态、后做 Hook 归因 | 被杀 | `test_N2_classifyOrder` |
| Q5 c:探测失败盖住归因到 Hook 的差异 | 被杀 | `test_N2_checkC_hookAttributedDifferenceBeatsProbeFailure` |
| Q6 作废报告保留 setup 行 | 被杀 | `test_N3_voidReport_chainIdChanged_noPassAnywhere` |
| Q7 作废报告渲染 Setup 段 | 被杀 | 同上 |
| Q8 不核对检查器的时钟 | 被杀(离线和 fork) | `test_N4_clockMovedUnderTheChecker_void`、`test_fork_r2_mode2_rollFork_void` |
| Q9 c 在"参考流程一步都不成功"时仍报通过 | 被杀 | `test_N4_referenceFlowThatDoesNotWork_cIsUnknown` |
| Q10 去掉极端参数的陌生池 | 被杀 | `test_N5_globalSwitchTrippedByExtremeParameters_detected` |
| Q11 单笔 swap 的快照回滚之前不核对环境 | 被杀(离线);fork 上存活 | `test_N4_clockMovedUnderTheChecker_void`(mode 6)。fork 上没有"只在单笔快照里 roll"的变体 |
| Q12 共用币种的陌生池不管代币排序 | 被杀 | `test_N5_sharedCurrencyPool_sharedTokenIsCurrency0ThereToo` |

Q11 第一次跑是存活的(别的核对点也抓得到那个玩具),补了"只在单笔快照里动时钟"的 mode 6 之后才被杀。

**复审时审计员写的 14 处(N1–N14,`../audits/audit-hooks-h3/reaudit/mutate2.py`,模式串不用改,原样在副本里跑)**:

| 变异 | 复审时(离线 / fork) | 现在(离线 / fork) | 说明 |
|---|---|---|---|
| N1 作废时不重置状态 | 存活 / 被杀 | 被杀 / 被杀 | 离线有了作废测试 |
| N2 不比较 chain id | 存活 / 存活 | **被杀** / 存活 | `test_N3_voidReport_chainIdChanged_noPassAnywhere`;fork 上外来代码改不了 chain id,没有这条腿的 fork 测试 |
| N3 对照池的工具故障不算探测失败 | 存活 | **被杀** | `test_N2_classifyOrder` |
| N4 d:探测失败不再挡 PASS | 存活 | **被杀** | `test_N4mut_lpRouterWiped_dIsProbeFailureNotPass`(新变体;原来的 RouterWiper 只抹 swap 路由,d 没有探测失败可言,给它加 d 的断言杀不掉 N4) |
| N5 c:流动性三步只比成败 | 存活 | **被杀** | `test_N5mut_strangerPoolChangesWithdrawalAmountsOnly_detected` |
| N6 c:不比回滚选择器 | 存活 | **被杀** | `test_N6mut_strangerPoolChangesTheRevertReasonOnly_detected` |
| N7 g:DELEGATECALL 用切尾巴的扫描判 | 被杀 | 被杀 | |
| N8 场景之间不核对环境 | 存活 / 存活 | 存活 / 存活 | 等价:场景回滚之前、单笔 swap 回滚之前和运行结束时还各有核对 |
| N9 e:探测失败不再挡 PASS | 被杀 | 被杀 | |
| N10 c:忽略录制流程里的工具故障 | 存活 | **被杀** | `test_N10mut_toolingBrokenDuringStrangerActivity_cIsProbeFailure` |
| N11 c:第 9 步不比较 | 存活 | **被杀** | `test_N11mut_strangerPoolChangesTheSmallAddOnly_detected` |
| N12 d:两边都回滚算成功 | 被杀 | 被杀 | 改 N-1 之后一度存活(搭场景的撤资另有计数),给 `test_H2_freezerHook_…` 加了精确步数断言才重新被杀 |
| N13 作废报告仍打印明细 | 存活 / 存活 | 被杀 / 被杀 | 原来等价;现在作废报告在 Setup 之前就结束,测试断言了没有 Setup 段 |
| N14 最终回滚失败不报 | 存活 / 存活 | 存活 / 存活 | 没有能让最终回滚失败的测试 |

14 处里现在离线被杀 12 处;存活的是 N8(等价)和 N14(没有测试)。

变异检查只说明"这些被改坏的地方有测试盯着",不说明检查器的判定逻辑是对的。M / R / Q 三组和 N 组是在最后一次改源码之后跑的;之后只动过测试文件(给 Q11 补 mode 6、fork 回归测试改名),Q11 在那之后单独重跑过。

## 文件

```
checker/
  README.md
  src/
    HookChecker.sol        检查逻辑与报告渲染(runChecks / renderReport / notWhileChecking)
    CheckerOps.sol         带 gas 上限的操作与探测(opXxx),状态 diff 采集,环境核对(fork / chain / 检查器自己的时钟 / 自己的路由)
    CheckerRouter.sol      检查器自己的测试路由
    CheckerTypes.sol       Status / Finding / Report(含 voided)/ CheckConfig
    lib/SafeCall.sol       带 gas 上限、截断返回数据的调用
    lib/RevertInfo.sol     回滚数据解码(WrappedError / Panic / Error / 自定义 error),带边界检查;不可信文本的白名单
    lib/BytecodeScan.sol   操作码与选择器的线性扫描(全文;另有只用于措辞的"切尾巴"版本)
  samples/                 S1–S10,故意有漏洞的最小模型 + 对照版本,禁止部署
  test/
    CheckHook.t.sol        命令行入口(环境变量)
    Samples.t.sol          每个样本:有缺陷的必须被对应检查项报出,对照版本必须不报;检出矩阵
    SamplePoC.t.sol        S2 / S4 / S5 的缺陷本身的证明(不经过检查器)
    AuditRegression.t.sol  首轮审计每条发现的回归测试;仍然漏报 / 误报的变体钉住当前结果(pinned)
    Reaudit2Regression.t.sol  复审 N-1 … N-5 的回归测试、复审存活变异的补测、_classify 判定顺序的单元测试
    OwnHooks.t.sol         我们自己的两个 Hook 不得被报;init code 哈希与 salt 不变
    Robustness.t.sol       恶意 / 损坏的 Hook、PoolManager、PoolKey 下仍返回完整报告
    Units.t.sol            SafeCall / RevertInfo / BytecodeScan / CheckerRouter 的单元与模糊测试
    fork/ForkChecker.t.sol Base fork(固定区块)对真实 PoolManager:自己的 Hook、全部样本
    fork/ForkReentry.t.sol Base fork 上被检 Hook 重入命令行入口(H-1):被拒 / 报告作废
    fork/ForkReaudit2Regression.t.sol Base fork 上未加保护的公开函数切 fork / rollFork / 切走再切回(复审 N-4)
    SampleRegistry.sol, CheckerTestBase.sol
    mocks/HostileHooks.sol   稳健性测试用的恶意 / 损坏"Hook"
    mocks/AuditVariants.sol  首轮审计员的变体 + 随修复补的变体,故意有缺陷,禁止部署
    mocks/Reaudit2Variants.sol  复审时审计员的变体 + 随修复补的变体,故意有缺陷 / 带敌意,禁止部署
  script/check-hook.sh     命令行入口的薄封装(checker-run profile)
  script/mutate.py         变异检查脚本(不是检查器的一部分;只能在 hooks/ 的副本里跑)
  reports/                 入库:检出矩阵(本地 / fork),由检查器自测生成
  reports-local/           不入库(.gitignore):命令行入口写报告的唯一位置(对真实地址的试跑输出只在这里)
```

## 没做的

- **审计状态:经两轮内部审计(AI agent),第二轮的必须项已改、由项目负责人核对;未经外部审计。** 复审之后的这一轮修改(N-1 … N-6、补的测试)没有再经 `hook-auditor` 看。修改与每条发现的对应关系在 `test/AuditRegression.t.sol`、`test/Reaudit2Regression.t.sol` 的注释里。
- 复审里明确没做的:L-2 的替代方案(以 PoolManager 身份探测费率覆盖值,把"不管费率的 Hook"报成不适用)——f 仍是无法判定;N-1 的可选项(大额推不动价格时改用多笔小额)。
- 没有对接 Universal Router / PositionManager / Permit2;没有收税、rebasing、无返回值代币的专项场景。
- 没有 JSON 输出,报告只有 markdown 文本。
- 没有按 Hook 源码定制的检查(不变量模板、针对 return delta 的守恒模糊测试生成器)。
- 命令行入口只在 Base 主网 fork 上跑通过完整流程;没有在 Base Sepolia 上跑过。在本地 anvil(chain id 31337)上只验证过入口本身:不给 `POOL_MANAGER` 时以 `PoolManagerRequired(31337)` 退出;给了之后对一个没有代码的地址出了报告。没有在 anvil 上部署 PoolManager 和 Hook 跑完整流程。
- H-1 的回归测试用的是 fork 上 `vm.etch` 的替身 Hook;没有对"真正部署在链上、会重入的 Hook"做过端到端测试。
- 误报表里没有标测试名的行,仍然只是按逻辑推出来的。
