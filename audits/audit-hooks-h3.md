> **AI agent 内部审计,不等于外部审计。** 本文件是内部审计报告的公开副本,只做了路径与称谓清理(内部角色 "CEO" 改称"项目负责人";`research/…` 路径改成本仓库内的 `audits/…`、`docs/research/…`;本机临时目录路径删去;"agent 内部审计"前补了 "AI" 二字),结论与发现未改、未删。文中的 `hooks/` 即本仓库根目录;`hook-auditor`、`hook-engineer` 是 AI agent 的岗位名。

# 项目四 H3 首轮审计:Hook 安全检查工具(hooks/checker/)

- 日期:2026-11-11。审计人:`hook-auditor`(agent)。
- 本文件由项目负责人根据审计员的报告落盘(审计员只读,不能写文件),正文未改;PoC 与变体源码、变异脚本在 `audits/audit-hooks-h3/`(放进 hooks 副本的 `checker/test/audit/` 即可编译)。
- 项目负责人复核情况见文末。

**性质声明:这是 AI agent 内部审计,不等于外部审计。** 只读审计,仓库内文件未改动;所有变体和变异都在临时副本里做。本报告不对任何第三方项目下安全结论。

## 一、结论

**修完再审。** 现在不能作为作品集的一部分对外公开。

原因是两条"高":被检 Hook 能让检查器在推荐给第三方代码用的 fork 入口上把"撤流动性被堵"报成 PASS;d 项在一步都没成功时也会写"all N withdrawal steps went through"。两条都落在项目四红线"不得堵死撤流动性"对应的检查项上。

工程师自报的检出结论本身成立:我在副本里重跑离线 72 过 1 跳过,矩阵逐格断言属实。样本库和报告措辞没有踩红线。问题在检查器的判定逻辑、入口的可重入,以及 README 没写到的漏报面。

## 二、发现(按严重程度)

行号指 `checker/` 下的文件。

### 必须改

**H-1(高)被检 Hook 重入检查器的公开入口,切走 fork,d / e / c 被报成 PASS**
- 位置:`test/CheckHook.t.sol:45`(`test_checkHook()` 公开,53–54 行 `createSelectFork`)、`src/HookChecker.sol:148`(`runChecks` 公开、无重入保护)、`src/HookChecker.sol:528`、`src/CheckerRouter.sol:24`(`owner` 公开,Hook 从回调的 `sender` 就能找到检查器)。
- 现象:Hook 在第一次 `beforeSwap` 里调 `检查器.test_checkHook()` 并只给 300 万 gas。嵌套调用先执行 `vm.createSelectFork`,随后耗尽 gas 回滚,但 fork 的切换不随回滚恢复。之后检查器在一个新 fork 上继续跑,自己的路由合约在那里不存在,带 Hook 的池和对照池的每一步都同样回滚,于是全部"不归因于 Hook"。
- 实际结果(Base 本地 fork,区块 56,228,000,forge 1.9.0):
  - 对照组(Hook 让每次撤资回滚,不重入):d = FAIL,"36 of 36 withdrawal steps reverted"。
  - 同一个 Hook 加重入:a=UNKNOWN b=PASS c=PASS **d=PASS** e=PASS f=UNKNOWN g=PASS h=UNKNOWN。d 的依据写"all 24 withdrawal steps went through",e 写"0 of 31 swaps went through; the rest revert the same way without a hook",c 写"rejects a pool created by a stranger"。
  - 只带 `beforeSwap` 位的 Hook 加重入:a/b/c/d/e/g 全 PASS,无一项 FAIL。
  - trace 里可见嵌套的 `VM::createSelectFork` 和其后的 "call to non-contract address"。
- 局限:Hook 是用 `vm.etch` + `vm.makePersistent` 放上去的替身,不是真正部署在链上的合约;没有用 anvil 加 `check-hook.sh` 端到端复现。
- 建议:
  1. `runChecks` 和 `test_checkHook` 加重入保护。
  2. 运行前后及每个场景后核对 `vm.activeFork()` 没变,变了整份报告作废。
  3. 检查器自己的基础设施出错(路由无代码、`CheatcodeError`)一律记成"探测失败 → UNKNOWN",不得进入"对照池也回滚"分支。
  4. 隐藏 `owner` 没用:forge 测试合约的地址是固定的。
  5. README"稳健性"一节补上"Hook 可以回调检查器"这一类。

**H-2(高)"对照池也回滚"被当成没问题,d 的 PASS 摘要与事实相反**
- 位置:`src/HookChecker.sol:520–530`、`:743–747`、`:1304–1315`(摘要在 1314)、`:1338–1340`、`:1212–1216`。
- 现象:只要 `dFail == 0` 且 `dRan > 0`,d 就报 PASS 并写"all N withdrawal steps went through",不管这 N 步里成功了几步。
- 实际结果(离线,给定 PoolKey):一个 Hook 是池中代币的控制者,在第 3 笔 swap 后把代币冻结(禁止从 PoolManager 转出)。此后两个池的每一步撤资都回滚,明细行全是"reverts (also without hook)",但 **d = PASS,"all 28 withdrawal steps went through"**;e = PASS,"17 of 34 swaps went through"。真实后果是 LP 取不回钱,原因正是 Hook。
- 建议:
  1. d 和 e 只有在带 Hook 的池上每一步都成功时才 PASS。
  2. 出现"两边都回滚"时至少报 UNKNOWN,摘要写清成功数、两边都回滚数、未测场景数。
  3. 摘要不得在场景标了 NOT TESTED 时仍写"time, price, gas-price perturbations"。我的"限额 Hook"对照里 3 个价格场景没测,摘要仍这么写("all 27 …")。

**M-1(中)c 项不看撤流动性:陌生池可以堵死被测池的撤资而全表 PASS**
- 位置:`src/HookChecker.sol:1076–1091`(参考流程只有 6 笔 swap,`touched` 也只取这 6 笔)。
- 实际结果:`GlobalHaltHook` 里,陌生池以极端初始价建池触发全局开关,此后所有池的 `beforeRemoveLiquidity` 回滚。报告 a–h 全 PASS,c 写"shares no changed storage slot … 6 reference swaps are identical",d 写"all 39 … went through"。
- 建议:参考流程加入"只领手续费、撤一部分、再加一点",结果和 `touched` 都纳入比较;README 的漏报表写明 c 只比较 swap。

**M-2(中)b 项对"带旁路的调用方校验"报 PASS,PASS 摘要说过头**
- 位置:`src/HookChecker.sol:968–1004`、`:1055`。
- 实际结果:三种写法都得到 b = PASS,摘要是"all 10 callbacks revert for a non-PoolManager caller … and not in the way they answer the PoolManager":
  - `msg.sender == pm || sender == 可信路由`(`sender` 是回调参数,直接调用时任意填);
  - `msg.sender == pm || tx.origin == KEEPER`;
  - `msg.sender == pm || hookData.length == 1`。
- README 第 224 行只覆盖了"对 PoolManager 也同样回滚 → UNKNOWN"的情形;带 `||` 旁路的情形实际得到 PASS,没写。
- 建议:探测多变几组输入(`sender` 换成攻击者、Hook 自身、PoolManager;`vm.prank(caller, origin)` 变 `tx.origin`;hookData 长度 1 / 4 / 20 / 32);PASS 摘要改成"在这 N 组输入下被拒",README 写明带旁路的校验查不出。

**M-3(中)字节码扫描切掉"元数据尾巴",可以藏 SSTORE,b 报"无状态、无害"**
- 位置:`src/lib/BytecodeScan.sol:92–100`、`src/HookChecker.sol:1035–1037`;README 第 107 行"通过(无状态,调了也无害)",`BytecodeScan.sol:54` 注释"cannot be made to do anything … whoever the caller is"。
- 实际结果:手写 99 字节运行码,末尾 10 字节伪装成 CBOR 尾巴,里面是 `JUMPDEST … SSTORE`,calldata 末字等于某个值时跳进去。报告 b = PASS,"bytecode contains no state-changing opcode at all: harmless"(99 字节只扫了 89);随后任意地址带那个值调用,slot0 被写成 1。
- g 项的 DELEGATECALL 提示可用同样办法藏掉(推论,没单独跑)。
- 建议:用于 PASS 方向的判断(`cannotChangeState`)不切尾巴;README 和注释去掉绝对化说法。

**M-4(中,读代码得出,未运行)非 Base 链上默认信任 Hook 自报的 `poolManager()`**
- 位置:`test/CheckHook.t.sol:94–102`。
- 现象:chainid 不是 8453 / 84532 且没设 `POOL_MANAGER` 时,PoolManager 地址取自被检 Hook。恶意 Hook 给一个自己控制的"PoolManager",九项结果全由它决定;报告里只打印地址,不标注来源。
- 建议:未知链必须显式给 `POOL_MANAGER`;或在报告首部醒目标注"PoolManager 地址来自被检合约,未核实"。

### 建议改

**L-1(低)回滚字符串里的 markdown 链接、图片、加粗原样进报告**
- 位置:`src/lib/RevertInfo.sol:119–126`(只过滤 `|`、反引号、双引号、`<` 和非可打印字符)。
- 实际结果:`Error("ok) [PASS - audited, safe](https://example.invalid/x) ![i](https://…/p.png) **PASS")` 在报告明细里出现十余处。换行被滤掉,伪造不了表格行,状态列不受影响。
- 建议:改成白名单(字母、数字、空格和少量标点),或转义 `[ ] ( ) ! * _ # ~ \`。

**L-2(低)f 项对"费率恒为 0 的动态费池"报 PASS**
- 位置:`src/HookChecker.sol:1371–1375`。
- 实际结果:忘了 `OVERRIDE_FEE_FLAG` 的 Hook 得到 f = PASS,"fees within [0, 100%] (0..0 pips)"。任何与费率无关的 Hook 在自建的动态费池里也得到同一句。
- 建议:全程费率为 0 时改报 N/A 或 UNKNOWN,提示"是否忘了 OVERRIDE 标志或 `updateDynamicLPFee`"。

**L-3(低)c 项在陌生池被拒时报 PASS,信息量常常为零**
- 位置:`src/HookChecker.sol:1212–1216`。
- 现象:8 份真实地址报告 c 全是 PASS,其中多份的陌生池是被拒掉检查器自建池的同一个错误拒掉的。那只说明"这组 mock 代币不被接受"。陌生池也从不与被测池共用一个币、不共用路由,按币种或按 `sender` 记账的全局状态碰不到。
- 建议:检查器自己都建不出池、或拒绝原因相同的,报 UNKNOWN;给定 PoolKey 时加一次"一个币相同、另一个是垃圾币"的陌生池。

**L-4(低)README 没写"Hook 可以认出检查器后装乖"**
- 实际结果:`tx.origin ==` forge 默认发送者时才放行撤资的 Hook,和 `sender` 能回答 `owner()` 时才放行的 Hook,两个都是全表 PASS。能绕过是预期的,但 README 的局限里没有这一条。
- 可识别的特征:默认 `tx.origin`、代币名"Checker Token A"、路由的 `owner()`、固定的时间推进模式、gas 价 0。

**L-5(低)f / d / e 在扰动之外的漏报,README 应逐条列出**(结果见第三节)。

**L-6(低,推论)** `src/HookChecker.sol:1150、1169`:`_hookSlots` 最多记 256 个槽,超出的静默丢弃,陌生池先写满 256 个无关槽就能让"共用槽"提示消失。没跑。

**L-7(低)非 fork 模式下的 cheatcode**(README 第 67 行已有警告,我确认了后果)
- 实际结果:本地模式下被检 Hook 写出了 `checker/reports/FORGED-by-hook.md`;另一个 Hook 在回调里关掉检查器的状态录制,b 从应有的 FAIL 变成 UNKNOWN。
- fork 模式下外来代码及其 CREATE 出来的子合约调 cheatcode 都被拒(子合约那条是我补测的)。
- 建议:README 点明 `BASE_RPC_URL` 若带 API key 就是环境变量里的密钥(本地模式下恶意代码可读环境变量并经 RPC URL 带出——推论,没跑);第三方地址的报告写到单独的、不入库的目录,免得覆盖已提交的矩阵文件。

**I-1(提示)对外发布前的措辞**
- README 试跑表把 5 个地址与项目名并列,而归属"大多来自登记库,没有逐个核实",其中一个标着"项目归属未核实"。公开版建议只留地址。
- `samples/S5_SharedSlotGuard.sol` 头注释点了一个"二手、单一来源"的事故名,公开前要么核实要么去名。
- 这两条都不是安全结论,现有免责声明是充分的。

## 三、六个问题逐条回答

### 1. 漏报

本该 FAIL 或 UNKNOWN 却报 PASS 的(全部实测):

| 变体 | 检查器结果 | README 是否涵盖 |
|---|---|---|
| b:`pm \|\| sender 参数` / `pm \|\| tx.origin` / `pm \|\| hookData.length==1` | b PASS ×3 | 部分(只说猜不出 hookData),PASS 文案过头 → M-2 |
| b:伪元数据尾巴里藏 SSTORE | b PASS"harmless" | 否 → M-3 |
| c:陌生池触发全局开关堵撤资 | c PASS、d PASS | 否 → M-1 |
| c:全局量在本池满 40 笔 swap 后才读 / 2 天后才读 | c PASS ×2 | 否(只说"需要特定交易序列") |
| c:mapping 键取 PoolId 首字节(256 桶) | c PASS | 否 |
| d:第 9 次撤资起 Panic / 价格偏离 4 倍以上时拒撤 / 闲置 2–300 天窗口内拒撤 | d PASS ×3 | 否;11 种扰动列出来了,但"之外的都查不出"没明说 |
| e:exactOut 超过 100e18 时 Panic | e PASS | 否(100 倍大额只做了 exactIn) |
| d:认出检查器后装乖(两种) | 全 PASS | 否 → L-4 |
| f:现货价费率只作用于 1→0 方向 | f PASS | 否(同块比较只比 0→1) |
| f:exactOut 超过 100e18 时费率大于 100% | f PASS、e PASS | 否 |
| f:忘了 OVERRIDE 标志 | f PASS"0..0" | 否 → L-2 |
| d:Hook 冻结代币,两边都回滚 | d PASS"all 28 … went through" | "可冻结代币"提到了,但摘要与事实相反 → H-2 |
| fork 入口被重入 | d/e/c PASS | 否 → H-1 |

行为正确、符合 README 的:
- b:只写 transient storage → UNKNOWN;效果只在特定 `tx.origin` 下出现且不回滚 → UNKNOWN。
- a:地址多一位(函数存在)→ FAIL(MISMATCH);少一位且有 `getHookPermissions()` → FAIL;return-delta 位不配对 → FAIL;开了 return-delta 位却不 take → e FAIL(`CurrencyNotSettled`)。
- a:少一位且不暴露 `getHookPermissions()` → PASS。README 只提了"少 return-delta 位"这一种,其实任何缺位都一样,建议补一句。

### 2. 误报

- **没有发现把非 Hook 回滚算到 Hook 头上的情况。** 恒定 50% 费率的动态费 Hook(对照池 0.30%):48 笔 swap、39 步撤资全过,无误报。
- 推演:价格路径不同只影响数额;推价格用同一个限价,两池停在同一价位。残余风险在"建不出对照池"(此时一切归 Hook,setup 行里有说明)和给定池里有他人流动性这两处,没造出实例。
- 归因逻辑真正的问题在反方向:对照池回滚会掩盖问题(H-2)。
- 三个"正确但不寻常"的 Hook,输出都与误报来源表一致:
  - 7 天上限锁仓:d FAIL(24/36,+400 天场景全过,只领手续费不被锁)。
  - 显式拒绝大额 swap:e UNKNOWN、f UNKNOWN(同块测试跑不了),d 的 3 个价格场景 NOT TESTED 但摘要仍写全过(并入 H-2 的建议 3)。
  - beforeSwap 收 0.10% 并以 ERC-6909 持有:i PASS"uniform 1001 ppm"、h UNKNOWN。
- 误报来源表的 b 行、c 行我没有专门造样本验证。

### 3. 稳健性

- 崩溃或挂死:没造出来。自带的 9 种恶意 Hook 测试重跑通过,整套离线 18 秒;最重的单测约 43 亿 gas。
- `gas_limit` 开到最大加 `disable_block_gas_limit`:单步上限 3,000 万、探测 1,000 万、流程 20 亿,把总量框住了。这两项本身我没找到可利用点。
- 输出被伪造:能,见 H-1(fork 入口)、M-4(未知链)、L-7(本地模式,已有警告)、L-1(文本注入,不影响状态列)。
- `fs_permissions` 读写 `checker/reports`:本地模式下被检代码可在该目录建、改文件(实测建文件);fork 模式下外来代码及其子合约被拒。`CHECK_REPORT` 的文件名校验没问题。
- `decimals()` 作恶、代币返回数据炸弹:读代码认为走不通(有 gas 上限、定长拷贝、大于 30 回落),没跑。

### 4. 样本与红线

- S1–S10 都是抽象最小模型,文件头有禁止部署的声明,没有针对任何线上合约的地址、接口或可用攻击代码。
- `reports/base-*.md` 和 README 没有对第三方下安全结论,每份报告首尾都有免责声明。
- 抽看 4 份报告的 UNKNOWN:建不出池、加不进流动性、探测参数被拒、`owner()` 有回答、同块费率变化——理由都成立,属于工具如实说"不知道"。不成立的是其中的 c = PASS(L-3)。
- 两处发布前措辞建议见 I-1。

### 5. 测试充分性

- 矩阵确实逐格断言(20 个样本 × 9 项,`SampleRegistry.sol` 的 `_expected`)。
- 12 处变异,5 处被杀、7 处存活:

| 变异 | 结果 |
|---|---|
| Panic 不再算"意外" | 被杀(S7) |
| b 不在 unlock 内探测 | **存活** |
| b 的"效果"只看 Hook 自身存储(不看事件、ETH、别的合约) | **存活** |
| c 有共用槽不再报 UNKNOWN | **存活** |
| 对照池回滚可掩盖出自 Hook 的回滚 | **存活** |
| h 不看 ERC-6909 余额 | **存活** |
| f 同块测试不比较大额反向 swap 之后那笔 | 被杀(矩阵) |
| i 不看比例差 | 被杀(S4) |
| e 去掉 1 wei 和 100 倍 swap | **存活** |
| c 比较时不看费率和池内数额 | **存活** |
| d 去掉"只领手续费"和"最后一个 LP"两步 | 被杀(S1、S6) |
| b 的"与 PoolManager 回滚相同"比较关掉 | 被杀(2 条) |

- 缺的样本:需要 unlock 才显形的无调用方校验回调;只发事件或只动别的合约的回调;c = UNKNOWN 的样本;持有 6909 凭证的样本;只在极端金额出问题的样本;对照池回滚同时 Hook 也回滚的归因用例。

### 6. 说过头的话

- README 第 107 行"通过(无状态,调了也无害)"和 `BytecodeScan.sol:54` 的注释:被 M-3 推翻。
- `HookChecker.sol:1055` 的 b PASS 摘要、`:1314` 的 d PASS 摘要:见 M-2、H-2。
- README 第 88 行"都记成该项的结果"、第 314 行"检查器不崩":对列出的 9 种成立,但没覆盖"Hook 回调检查器"(H-1)。
- README 第 65 行"同一个 Hook 跑两次报告逐字节相同":只对一个 Hook 测过,措辞是普遍的。
- 其余("确定的、可复现的证据""把每一格都断言了""没有任何可用攻击代码")我核对过,成立。

## 四、实际跑了什么、没跑什么

跑了(全部在临时副本,forge 1.9.0):
- 离线自测 72 过 1 跳过。
- 自写变体 15 个测试函数,约 40 次 `runChecks`,离线。
- Base 本地 fork(公共 RPC,区块 56,228,000)上的重入实验 5 种模式,加"外来代码的子合约调 cheatcode"1 条。
- 12 处变异各跑一遍离线自测。
- 结束后核对:`checker/src` 与仓库一致;`hooks/src` 五个文件哈希开头仍是 fed43565 / d1287975 / 5e9d1789 / 950d98e5 / ef77c834。

没跑:
- 检查器自带的 fork 测试(5 条)和默认 profile 的 201 / 28(按你说的不重复)。
- anvil 加 `check-hook.sh` 的端到端。
- M-4、L-6、环境变量外带、`decimals()` 作恶:都是读代码的推论。
- 真实代币、Universal Router、PositionManager。
- 8 份真实地址报告只看了 4 份。
- 没发任何交易,没用任何私钥。

临时副本和日志:`<审计员的临时目录,未随仓库保存>/`
- `run1.log`、`run2.log`、`run3.log`:变体输出
- `reenter2_1.log` … `reenter2_4.log`:重入实验
- `mutation-results.txt`:变异结果

## 五、PoC 与变体源码

见 `audits/audit-hooks-h3/`:`AuditHooks.sol`、`Audit.t.sol`、`ForkReenter.t.sol`、`mutate.py`(sha256 开头 ae60063f / b25665bc / cb2779f2 / fe478f2c)。

跑法(在 hooks 的副本里,把前三个文件放到 `checker/test/audit/`):

```bash
FOUNDRY_PROFILE=checker forge test --match-contract AuditTest -vv
FOUNDRY_PROFILE=checker HOOK=0xb00B000000000000000000000000000000000280 CHECK_RPC_URL=https://mainnet.base.org \
  CHECK_FORK_BLOCK=56228000 REENTER_MODE=3 forge test --match-contract ForkReenterTest --match-test test_reenter2 -vv
```

**审计员复审时要看的:** H-1、H-2 的修复各配一条回归测试(可直接用 `ReenterHook` mode 3 和 `FreezerHook`);M-1 至 M-4 的修复或在 README 里写明;存活的 7 处变异至少补上 b 的 unlock 探测、对照池掩盖、c 的 UNKNOWN 三处的样本。

## 项目负责人复核(2026-11-11)

在 `hooks/` 的临时副本里重跑了审计员的部分变体,结果与报告一致:

- H-1:Base 本地 fork(区块 56,228,000)上,对照组(每次撤资都回滚、不重入)d = FAIL;同一个 Hook 加重入后 d = PASS("all 24 withdrawal steps went through")、e = PASS("0 of 31 swaps went through")。
- H-2:冻结代币的 Hook,d = PASS("all 28 withdrawal steps went through")、e = PASS("17 of 34")。
- M-1:陌生池触发全局开关,a–h 全 PASS。
- M-2:三种带旁路的调用方校验,b 均为 PASS。
- M-3:伪元数据尾巴里藏 SSTORE,b = PASS("harmless"),随后陌生地址调用把 slot0 写成 1。

没有重跑:其余变体(a、c 的延迟污染、d/e/f 扰动之外的、误报对照、稳健性各条)、12 处变异、M-4 与 L-6(审计员自己也只是读代码的推论)。
