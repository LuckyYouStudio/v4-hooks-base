> **AI agent 内部审计,不等于外部审计。** 本文件是内部审计报告的公开副本,只做了路径与称谓清理(内部角色 "CEO" 改称"项目负责人";`research/…` 路径改成本仓库内的 `audits/…`、`docs/research/…`;本机临时目录路径删去;"agent 内部审计"前补了 "AI" 二字),结论与发现未改、未删。文中的 `hooks/` 即本仓库根目录;`hook-auditor`、`hook-engineer` 是 AI agent 的岗位名。

# 项目四 H3 复审:Hook 安全检查工具(hooks/checker/)首轮修复

- 日期:2026-11-11。审计人:`hook-auditor`(agent)。
- **性质声明:这是 AI agent 内部审计,不等于外部审计。** 只读;仓库文件未改动(结束时对 `hooks/src`、`checker/src|test|script|samples`、README、`foundry.toml` 共 39 个文件做了 sha256 复核,全部一致)。所有变体、变异都在临时副本里做。本报告不对任何第三方项目下安全结论。

## 一、结论

**再改几处由项目负责人核对即可**,不需要第三轮完整审计;但改完之前仍不能公开。

首轮两条"高"都修到位了:我的原始变体和新写的重入变体都打不出 PASS。这一轮新打出 5 个问题,其中 2 条必须改:

- **N-1(中)**:检查器亲眼看到 Hook 回滚了一次撤资,却把它记成 "NOT TESTED",d 仍报 PASS。落在红线"不得堵死撤流动性"对应的检查项上。
- **N-2(中)**:回滚数据长得像 `CheatcodeError` 就被当成"检查器工具故障、与 Hook 无关",池内代币可以伪造;e 从 FAIL 降成 UNKNOWN。

两条的修法都是十几行、机械的。项目负责人核对的标准:第五节的 4 个 PoC 输出翻转(N1 d=FAIL、N1b d=UNKNOWN、N2 armed e=FAIL、N3 作废报告全文无 "PASS"),且原有 110 / 9 条仍全过。

## 二、首轮逐条判定

| 首轮 | 判定 | 依据 |
|---|---|---|
| H-1 重入切 fork | **已修**,有 2 处残余 | 读了三层防护的代码。新写的 fork 变体 mode 1(在每次 `beforeRemoveLiquidity` 里、即场景快照内部调未加保护的切 fork 函数)得到整份作废("2 -> 14"),快照回滚不会把 fork 悄悄切回来。残余见 N-2、N-4 |
| H-2 两边都回滚算没问题 | **已修**,有 1 处残余 | FreezerHook:d = UNKNOWN、e = UNKNOWN,摘要有各类计数。残余见 N-1 |
| M-1 c 不看撤资 | **已修** | GlobalHaltHook c = FAIL(9 步里 3 步不同)。新盲区见 N-5 |
| M-2 b 带旁路 | **部分修 + 写进文档,足够** | `hookData.length==1` → FAIL;写死的 sender / tx.origin 仍 PASS,摘要已改成"在这 200 组输入下",README 有对应行和 pinned 测试 |
| M-3 切元数据尾巴 | **已修** | 伪尾巴 b = UNKNOWN;g 用全文扫描 |
| M-4 信任 Hook 自报的 PoolManager | **已修**(读代码 + 单元测试,入口未端到端跑) | `resolveManager` 是 pure,未知链直接报错 |
| L-1 回滚文本注入 | **已修** | 白名单 + 反引号。文字内容仍进报告(README 已说明),但见 N-3 |
| L-2 费率恒 0 报 PASS | **已修**,代价见第四节问题 2 | f3 = UNKNOWN 带提示 |
| L-3 陌生池被拒即 PASS | **已修** | 检查器自己建不出池 → UNKNOWN;加了共用 currency0 的陌生池。"只接受第一个池 → c PASS"我认为合理:被 `beforeInitialize` 拒掉的池此后不会再有回调 |
| L-4 认出检查器装乖 | **只写进文档,足够** | README 有专节和特征清单,pinned 测试在 |
| L-5 扰动之外的漏报 | **只写进文档,足够** | README 逐行列出;其中 e1、f1、f2 三行已变成查得出 |
| L-6 槽数上限静默丢弃 | **已修** | 上限 1024,超出 → UNKNOWN |
| L-7 本地模式 cheatcode | **只写进文档 + 目录隔离,足够** | `checker-run` 只对 `reports-local/` 有写权限(读配置,未实测写入被拒)。我的 CheatcodeHook 在 `checker` profile 的副本里仍能写出文件,与 README 的警告一致 |
| I-1 措辞 | **已修** | 试跑表只剩地址;S5 头注释已去名;8 份报告里没有项目名 |
| 第六节说过头的话 | **已修**,新增 1 句不成立 | "harmless"、"all N went through"、"检查器不崩"、"逐字节相同"都已收窄。新的不成立句见 N-3 |
| 存活的 7 处变异 | 6 处被杀,M10 仍存活(工程师自报,我没重跑 M / R 系列) | — |

## 三、新发现

行号指 `checker/` 下的文件。

### 必须改

**N-1(中)扰动步骤里的撤资被 Hook 回滚,记成 NOT TESTED,d 仍是 PASS**

- 位置:`src/HookChecker.sol:685–694`(`_perturb` 里"只剩一个 LP / 全部撤出"两个场景先让 LP B 全撤,失败就返回"无法施加扰动")、`:1619–1625`(有场景没测时 d 仍 PASS)。
- 实际结果(离线,`RateLimitExitHook`:单次撤资不得超过池内流动性的 40%,全撤除外;两个等额 LP 时谁都无法一步离场):
  - d = **PASS**,"36 of 36 succeeded … 0 reverted because of the hook … NOT TESTED: 1 (single LP left)"。
  - 同一份报告的明细行写着 "the second LP could not withdraw: WrappedError{beforeRemoveLiquidity on 0xa0D2…}"。
  - a–e、g、h 全 PASS。
- 这与 README d 节"有任何一步因 Hook 回滚 → 失败,不区分原因"不符。
- 第二个变体回答你问的"NOT TESTED 时该不该降级"(`MaxSwapOutOfRangeBlockHook`:拒绝超过 50e18 的 swap,价格在头寸区间外时拒绝撤资):d = **PASS**,"27 of 27 … NOT TESTED: 3"。真实环境里用几笔小额 swap 就能把价格推出区间,那时撤资被堵;三个价格场景恰好因为 Hook 拒绝大额 swap 没测。
- 我的判断:**d 应该降为 UNKNOWN**。场景测不成的原因在被检 Hook 手里,和 H-2 是同一类:Hook 能决定哪些测试跑不起来。状态列会被单独摘进矩阵和汇总表,不能指望读者去读摘要。e 不用改:推价格的 swap 失败已经计入 e。
- 建议:
  1. 扰动步骤里的撤资失败按普通撤资步骤分类计数(进 `dRan` / `dFail` / `dBoth` / `dInfra`),然后再把场景标 NOT TESTED。
  2. `dSkip > 0` 时 d 最多 UNKNOWN。
  3. 可选:单笔大额推不动时改用多笔小额推价格,减少 NOT TESTED。
- 代价:`test_H2_maxSwapHook_untestedScenariosAreNamed` 的 d 断言要从 PASS 改成 UNKNOWN。8 份真实地址报告里 d = PASS 的 3 格都是 "NOT TESTED: 0",不受影响。样本矩阵和自家两个 Hook 是否有格子受影响,我没测。

**N-2(中)`CheatcodeError` 形状的回滚数据可被池内代币伪造,且优先于 Hook 归因**

- 位置:`src/lib/RevertInfo.sol:64`(最外层选择器等于 `CheatcodeError(string)` 就置 `cheatcode`)、`src/CheckerOps.sol:236`(`infra = cheatcode || _toolingBroken()`)、`src/HookChecker.sol:606`(`if (h.infra || ctl.infra) return 4` 排在"回滚出自 Hook 回调"之前)、`:1508`(c 项的 `infra` 判断排在比较结果之前)。
- 原理:`PoolManager.sync()` 调代币的 `balanceOf`,代币的回滚数据**不加包装**原样冒到最外层(`v4-core/src/types/Currency.sol:94`、`PoolManager.sol:285`)。路由欠款的操作(swap、加流动性、donate)都会走到这里。
- 实际结果(离线,给定 PoolKey,`PanicAfterFourHook` + 两个 `MimicToken`):
  - 对照(代币正常,Hook 第 4 笔之后每笔 swap 都 Panic):e = **FAIL**,"41 swap(s) reverted unexpectedly … 41 reverted because of the hook";c = PASS。
  - 同一个 Hook,另外让两个代币对 `balanceOf(PoolManager)` 回滚出 `CheatcodeError("…")`:e = **UNKNOWN**,"PROBE FAILURE, the checker's own tooling failed … 0 reverted because of the hook … 37 probe failure(s)";c = UNKNOWN "PROBE FAILURE";明细 37 处写 "CHECKER TOOLING FAILURE (not evidence about the hook): a Foundry cheatcode failed"。
  - 带 Hook 的池上的回滚其实是出自 Hook 回调的 Panic,被对照池那条伪造的"工具故障"盖掉了。
- 前提是 Hook 控制池里的代币、且操作者给了这个池的 PoolKey,与 H-2 的 FreezerHook 同一个前提。结果是 UNKNOWN 不是 PASS,但报告替被检合约写了一句"与 Hook 无关",而且首轮 M5 那条"出自 Hook 回调的回滚不受对照池影响"在这里失效。
- d 项:撤资路径上代币只被 `transfer`(v4 会包装),我认为伪造不到;这是推论,没单独跑。
- 建议:
  1. `infra` 只认环境事实(`_toolingBroken()`),不认回滚数据的形状。
  2. `_classify` 里先做 Hook 归因(`wrapped && target == hook`),对照池的状态不得覆盖它。
  3. `CheatcodeError` 形状的回滚照常显示,文案改成"形状像 Foundry cheatcode 报错;池内任何合约都能产生这种数据",去掉 "not evidence about the hook"。
  4. c 项同理:带 Hook 一侧有归因到 Hook 的差异时先报差异。

### 建议改

**N-3(低)作废报告仍输出 Setup 段,里面有 Hook 的文字;README 的"不出现 PASS"不成立;作废路径没有离线测试**

- 位置:`src/HookChecker.sol:211–219`(`_void` 不清 `rep.setup`)、`:1969–1973`(先打印 Setup 再 return);README 第 85 行"明细不输出,整份报告里不出现 `PASS` 这个词"。
- 实际结果(离线,`VoidTextHook`:拒绝第一个池时回滚字符串含 "PASS",之后用 cheatcode 改 chain id):`voided = true`,九项 UNKNOWN,但报告 Setup 段里有 ``Error(`all nine checks PASS - audited, safe to use`)``。
- 现有 fork 测试断言了"无 PASS",只是那个 Hook 没往 setup 里放字。
- 建议:作废时 `rep.setup` 一并清空或不渲染;补一条离线的作废测试(`vm.chainId` 即可触发)。

**N-4(低)未加保护的公开函数里 `vm.rollFork`:fork id 不变,不作废;c 在池子已消失的状态上报 PASS**

- 位置:`src/CheckerOps.sol:259–271`(只比 fork id 和 chain id)、`src/HookChecker.sol:1549–1551`(c 的"9 步相同"在 9 步全回滚时也成立)。
- 实际结果(Base 本地 fork,区块 56,228,000;Hook 在第一次 `beforeSwap` 里调测试合约上未加保护的 `rollForkUnguarded()`,其中 `vm.rollFork(FORK_BLOCK - 1)`):
  - 报告**没有作废**;setup 行出现 "donate … reverted: PoolNotInitialized()"。
  - **c = PASS**,"9 reference operations … come out identical"(被测池已不存在,两次都全回滚)。
  - e = FAIL,"33 swap(s) reverted unexpectedly … 33 reverted because of the hook",实际原因是 `PoolNotInitialized()`,与 Hook 无关。对照(不调 rollFork)e = PASS 42/42。
- 命令行入口没有这样的函数,不受影响;受影响的是按 README 示例自己写测试合约、又没给辅助函数加修饰符的用户。
- 另两个模式:切到另一个 fork 再切回来,结果与对照逐项相同(无害);场景快照内切 fork → 作废(见 H-1 行)。
- 建议:
  1. 每个核对点加一个"立足点"检查:运行开始时部署一个带标记值的小合约,核对点读它,读不到就作废;或至少核对检查器自己建的池仍已初始化。
  2. c 项:参考流程在"没有陌生池"时成功的步数为 0(或 swap 全失败)时报 UNKNOWN,摘要写"N of 9 succeeded"。
  3. README"稳健性"点名 `vm.rollFork`。

**N-5(低,文档为主)9 步参考流程和陌生池参数的盲区**

- 实际结果(离线,`GlobalHalt2Hook`):
  - mode 1:全局开关只在极端参数下触发(|tick| > 100000 或 tickSpacing > 1000)→ c = **PASS**。陌生池只用与被测池相同的 spacing、初始 tick 固定 -23027。
  - mode 2:开关照旧触发,但只有"单次撤出超过池内流动性 20%"的撤资才读它 → c = **PASS**(参考撤资只撤 LP A 的四分之一,即池的 12.5%;共用槽也因为没读到而不报)。
- 建议:README 漏报表补这两行;可选给陌生池加一组极端参数(最大 tickSpacing、接近 MIN / MAX 的初始 tick),这正是"任何人可用极端参数建池"那条检查项要的。

**N-6(提示)措辞**

- README 第 282 行"仍漏报:全 PASS":实际 f = UNKNOWN、i = N/A(a–e、g、h 是 PASS)。
- README 第 188 行"官方 `StablePairHook` / `VolatilePairHook` 本身就是 UUPS 代理":出自事实表 §2.3,H0 自报有未核实项。公开前要么核实,要么标"据事实表、未复核"。
- README 第 11 行"尚未通过内部复审"和文末"没做的"第一条,落盘本报告后要更新。
- README 没写"共用币种的陌生池在 `deal` 不了真实代币时那一路等于没测"(报告明细行里有标注,漏报清单里没有)。

## 四、六个问题

### 1. 首轮逐条判定

见第二节。

### 2. 新绕过

- **其他重入路径**:检查器上其余公开函数是 `onlySelf`(`opXxx`、`opFlow`)、只认 PoolManager(`unlockCallback`)、或 view / pure;路由全部 `onlyOwner`;命令行入口 `CheckHook` 没有别的会改环境的公开函数。读代码结论,没找到能利用的。
- **fork 模式下外来代码调不了 cheatcode**:没有重测,依据是现有的 `test_fork_foreignCodeHasNoCheatcodeAccess`(etch 上去的代码被拒)和我首轮补测的子合约那条。
- **切走再切回 / rollFork / 改 chain id**:实测见 N-4。"改 chain id 再改回"只有本地模式的 cheatcode 能做,README 已承认防不住,没跑。
- **把 FAIL 大面积降成 UNKNOWN**:
  - 走"两边都回滚":只对"不是从 Hook 回调里出来的回滚"有效;出自回调的回滚仍归 Hook(FreezeAndBlock 那条测试在)。README 写了,可接受。
  - 走"探测失败":N-2,不可接受,README 没写。
  - 走"场景没测":N-1,结果是 PASS 而不是 UNKNOWN,更糟。
- **9 步 / 200 组的新盲区**:N-5。200 组探测没发现新的错判;固定值之外的旁路查不出,README 已写。
- **白名单后还能不能伪造内容**:markdown 结构伪造不了(链接、图片、加粗、表格都被换掉),文字本身仍在。唯一有后果的是 N-3。
- **作废路径是否不含 PASS**:不成立,N-3。
- **L-2 取舍是否合理**:合理,可以发布。UNKNOWN 是老实话,README 写明了。更好的办法(可选):全程费率为 0 时,以 PoolManager 身份探测 `beforeSwap` 返回的第三个字(费率覆盖值)。非零但没带 `OVERRIDE_FEE_FLAG` → UNKNOWN 并明说"返回了费率却没带标志";为零、且池的 `lpFee` 全程为 0 → N/A"这组探测里 Hook 没有设置费率的动作"。N/A 不是通过,方向安全。这是设想,没试。

### 3. 误报回归

没有发现修复引入"把没问题的报成 FAIL"。

- 自家两个 Hook 和 10 个修好的样本:由 `OwnHooks.t.sol`、`SampleRegistry` 逐格断言,我在副本里重跑离线 110 过 1 跳过。fork 上那 9 条没重跑(按你说的不重复)。
- 三个"正确但不寻常"的 Hook,与首轮对比:

| Hook | 首轮 | 本轮 |
|---|---|---|
| 7 天上限锁仓 | d FAIL(24/36 回滚) | d FAIL(12 of 36 成功、24 回滚),相同 |
| 显式拒绝大额 swap | e UNKNOWN、f UNKNOWN、d PASS(摘要说过头) | 状态相同;d 摘要点名 3 个没测的场景 |
| 0.10% 费以 6909 持有 | i PASS、h UNKNOWN、f PASS | i PASS(1001 ppm)、h UNKNOWN、**f UNKNOWN**(L-2 的噪音) |
| 恒定 50% 费率(对照) | 全 PASS | 全 PASS,d 39/39,e 50/50 |

- 新增的 UNKNOWN 噪音都是 README 写明的那三类(f 费率为 0、g 尾巴字节、solc 编译的无状态合约)。
- 采纳 N-1 的建议后,"拒绝大额 swap"这类 Hook 的 d 会从 PASS 变 UNKNOWN,这是有意的。

### 4. README 漏报表与实际行为

用我的原始变体重跑,抽查 12 行,状态全部对得上:

| 行 | README 写的 | 实测 |
|---|---|---|
| b:写死的 sender / tx.origin | 仍 PASS,摘要"200 组" | b PASS ×2,摘要一致 |
| b:`hookData.length == 1` | FAIL | b FAIL |
| b:伪尾巴藏 SSTORE | UNKNOWN | b UNKNOWN(陌生地址带魔数调用后 slot0 = 1) |
| c:全局开关堵撤资 | c FAIL、d PASS | c FAIL(3 of 9)、d PASS |
| c:延迟污染三种 | 仍 PASS | c PASS ×3 |
| d:扰动之外三种 | 仍 PASS | d PASS ×3,e PASS ×3 |
| e:exactOut 超过 100e18 Panic | e FAIL | e FAIL(48 of 50) |
| f:单方向现货价 | UNKNOWN | f UNKNOWN |
| f:费率超过 100% | f FAIL | f FAIL、e FAIL |
| f:忘了 OVERRIDE | UNKNOWN | f UNKNOWN |
| d:冻结代币 | d、e UNKNOWN | d UNKNOWN(28 步两边都回滚)、e UNKNOWN |
| a:缺位且隐藏 | 仍 PASS | a PASS |

- "fork 入口被重入"一行没重跑,项目负责人已跑。
- 数字核对:200 = 8×22 + 2×12;d 39 步;e 50 笔,都对。
- 说过头的:第 85 行(N-3)、第 282 行(N-6)、d 节"有任何一步因 Hook 回滚 → 失败"(N-1)、稳健性第 3 层"一律记成探测失败"没提可伪造(N-2)。

### 5. 变异

新写 14 处,针对新增的判定逻辑。离线自测跑了全部 14 处(都跑完,N1–N13 的结果读自运行日志;N14 的存活是按它结束后变异 13 处时的日志推的,那一行我没读到);其中 5 处与作废路径有关的,又用 `ForkReentryTest` 跑了一遍。

| 变异 | 离线 | fork | 说明 |
|---|---|---|---|
| N1 作废时不重置状态 | 存活 | 被杀 | 离线没有任何作废测试 |
| N2 不比较 chain id | 存活 | **存活** | chain id 这条腿没有任何测试;N-3 的 PoC 可直接用 |
| N3 对照池的工具故障不算探测失败 | **存活** | — | 正是 N-2 建议去掉的那条腿 |
| N4 d:探测失败不再挡 PASS | **存活** | — | RouterWiper 测试只断言了 e |
| N5 c:流动性三步只比成败、不比数额 | **存活** | — | 没有"数额变了但不回滚"的样本 |
| N6 c:不比回滚选择器 | **存活** | — | 同上 |
| N7 g:DELEGATECALL 用切尾巴的扫描判 | 被杀 | — | |
| N8 场景之间不核对环境 | 存活 | 存活 | 结束时还有一次核对,对结论等价 |
| N9 e:探测失败不再挡 PASS | 被杀 | — | |
| N10 c:忽略录制流程里的工具故障 | **存活** | — | |
| N11 c:第 9 步(小额加仓)不比较 | **存活** | — | |
| N12 d:两边都回滚算成功 | 被杀 | — | |
| N13 作废报告仍打印明细 | 存活 | 存活 | 明细已被清空,等价 |
| N14 最终回滚失败不报 | 存活(见上) | 存活 | 难以触发,可接受 |

14 处里杀掉 4 处(N1、N7、N9、N12)。去掉等价的和难触发的,真正缺测试的是 N2、N4、N5、N6、N10、N11,加上已知的 M10。建议补:

- 一条离线作废测试(杀 N2)。
- RouterWiper 测试加 d 的断言(杀 N4)。
- 一个"陌生池活动改变被测池撤资到手数额、但不回滚"的变体(杀 N5、N11;N6 需要"回滚原因变了"的变体)。

### 6. 红线

- 守住了。S1–S10 和 `AuditVariants.sol` 都是抽象最小模型,头部有禁止部署声明,没有针对任何线上合约的地址、接口或可用攻击。
- README 试跑表只剩地址;8 份报告首尾有免责声明,结果栏 PASS 28 / UNKNOWN 35 / N/A 9,无 FAIL,无项目名。
- 仓库里对已公开事故的引用只有"模式出处"性质(S2、S4 头注释和 README 对应行),并写明不是复刻。
- 唯一要留意的是 N-6 里第 188 行那句对第三方合约的事实陈述。
- 我新写的变体同样是抽象玩具,只在本地和本地 fork 的 `vm.etch` 下运行。

## 五、实际跑了什么、没跑什么

跑了(forge 1.9.0,全部在副本):

- 离线自测:110 过 1 跳过。
- 首轮原始变体 `AuditTest`:15 条全部执行,输出与首轮逐项对比。
- 新变体离线 6 条(`Reaudit2Test`):N1、N1b、N2 对照与 armed、N3、N4 两种模式。
- 新变体 fork 4 条(`ForkReaudit2Test`,`https://mainnet.base.org`,区块 56,228,000,只读):对照、快照内切 fork、rollFork、切走再切回。
- 新变异 14 处离线;其中 5 处另跑 `ForkReentryTest`。

没跑:

- 检查器自带的 fork 9 条、默认 profile 201 / 28、工程师的 `mutate.py`(M / R 系列)、`check-hook.sh` 端到端、anvil。
- `checker-run` profile 写 `checker/reports/` 被拒:只读了配置。
- N-2 在 d 项上的推论;L-2 的替代方案;采纳 N-1 后样本矩阵和自家 Hook 哪些格子会变。
- 8 份重新生成的真实地址报告:只看了摘要行和首尾,没逐条看 UNKNOWN 的理由。
- 没发任何交易,没用任何私钥。

临时目录:`<审计员的临时目录,未随仓库保存>/`

- `<审计员的临时目录,未随仓库保存>/hooks/checker/test/audit2/Reaudit2Hooks.sol`(sha256 开头 2e128806)
- `<审计员的临时目录,未随仓库保存>/hooks/checker/test/audit2/Reaudit2.t.sol`(3006342c)
- `<审计员的临时目录,未随仓库保存>/hooks/checker/test/fork/ForkReaudit2.t.sol`(06d9dbae)
- `<审计员的临时目录,未随仓库保存>/tools/mutate2.py`(ada10f06)
- 日志(同一目录下):`offline-base.log`、`reaudit2-run1.log`、`fork-reaudit2.log`、`audit-r1-rerun.log`、`mutation2-offline.log`、`mutation2-fork.log`

跑法(在 hooks 的副本里,前两个文件放 `checker/test/audit2/`,第三个放 `checker/test/fork/`):

```bash
FOUNDRY_PROFILE=checker forge test --match-contract Reaudit2Test -vv
BASE_RPC_URL=https://mainnet.base.org FOUNDRY_PROFILE=checker forge test --match-contract ForkReaudit2Test -vv
python3 mutate2.py all                                        # 离线
BASE_RPC_URL=https://mainnet.base.org python3 mutate2.py N1,N2,N8,N13,N14 '--match-contract ForkReentryTest'
```

## 六、新变体源码

见 `audits/audit-hooks-h3/reaudit/`:`Reaudit2Hooks.sol`、`Reaudit2.t.sol`、`ForkReaudit2.t.sol`、`mutate2.py`(sha256 开头 2e128806 / 3006342c / 06d9dbae / ada10f06)。故意有缺陷 / 带敌意的抽象玩具,禁止部署。

fork 四种模式的实际状态串(a–i):

- mode 0 对照:`UPPFPUPPN`,未作废
- mode 1 快照内切 fork:`UUUUUUUUU`,**作废**
- mode 2 rollFork:`UPPFFUPPN`,**未作废**(c = P 是在池子已消失的状态上得到的,e = F 是误归因)
- mode 3 切走再切回:`UPPFPUPPN`,未作废,与对照相同

**修复后要项目负责人核对的:** N-1、N-2 各配一条回归测试(可直接用 `RateLimitExitHook`、`MaxSwapOutOfRangeBlockHook`、`PanicAfterFourHook` + `MimicToken`);N-3 清掉作废报告的 Setup 并补离线作废测试;N-4、N-5 至少写进 README;README 第 85、188、282 行和 d 节措辞;然后重跑离线 110 条和 fork 9 条。

## 项目负责人复核(2026-11-11)

在 `hooks/` 的临时副本里重跑了 `Reaudit2Test` 全部 6 条,输出与报告一致:N-1(`RateLimitExitHook` d = PASS,"NOT TESTED: 1";`MaxSwapOutOfRangeBlockHook` d = PASS,"NOT TESTED: 3")、N-2(对照 e = FAIL;代币伪造 `CheatcodeError` 后 e = UNKNOWN "PROBE FAILURE")、N-3(作废报告里仍含 "PASS")、N-5(两种模式 c = PASS)。没有重跑:fork 上的 N-4 四种模式、14 处新变异。

处置(项目负责人定):N-1 至 N-6 全部交工程师处理;采纳"d 在有场景没测时最多 UNKNOWN";L-2 的替代方案这轮不做。改完由项目负责人用本目录的变体核对,不再做第三轮完整审计。


## 项目负责人核对收尾修复(2026-11-12)

- 工程师按 N-1 至 N-6 和测试缺口改完。项目负责人重跑:`hooks/src/` 五个源文件 sha256 未变;默认 profile 离线 201、fork 28 全过;检查器离线 131 过 1 跳过,fork 14 过 2 跳过。
- 在临时副本里用本目录 `reaudit/` 的变体原件(`Reaudit2Hooks.sol` 2e128806、`Reaudit2.t.sol` 3006342c、`ForkReaudit2.t.sol` 06d9dbae)重打:`RateLimitExitHook` d = FAIL(36 of 38);`MaxSwapOutOfRangeBlockHook` d = UNKNOWN;N-2 armed 与 control 九项相同,e = FAIL;N-3 作废报告全文无 "PASS"、无 Setup 段;fork 上 mode 1、2 作废,mode 0 与 mode 3 同为 `UPPFPUPPN`;`GlobalHalt2Hook` mode 1 c = FAIL,mode 2 仍 c = PASS(已写进 README 并有 pinned 测试)。
- 首轮离线变体(`Audit.t.sol`)重打无退化(冻结代币 d/e = UNKNOWN、陌生池堵撤资 c = FAIL、伪尾巴 b = UNKNOWN)。首轮的 `ForkReenter.t.sol` 原件这轮没重跑(仓库里的 `ForkReentry.t.sol` 回归通过)。
- 8 份真实地址报告:PASS 28 / UNKNOWN 35 / N/A 9,无 FAIL、无作废(项目负责人机器统计,没逐条看)。
- 没核对的:工程师自报的四组变异结果;"roll 到同一区块号和时间戳不作废"这条残留缺口的成因(工程师黑盒实测,未查清)。
- 超出任务书的一处(陌生池共用 currency0 时跳 nonce 固定排序):项目负责人定保留。
- 这一轮改动没有再经 `hook-auditor` 看。
