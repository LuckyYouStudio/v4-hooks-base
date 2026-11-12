# 发布清单(维护者用)

这份清单给仓库所有者(项目负责人)在把本目录推到公开 GitHub 仓库之前逐项过一遍。**推送、建远程仓库、对外署名、部署都由项目负责人本人操作;** 本目录里的脚本和文档只是准备好的材料。

> 未经外部审计,不要直接用于主网资金。内部审计是 AI agent 做的,不等于外部审计。

## 1. 进仓库 / 不进仓库

本目录即仓库根。下表与 `.gitignore` 一致(`git add -A` 之后用第 3 节的命令核对)。

| 路径 | 进仓库 | 说明 |
|---|---|---|
| `README.md`、`README.zh.md` | 是 | 顶层说明(英文为主,中文一份) |
| `PUBLISHING.md` | 待定 | 本文件;公开与否见第 2 节 |
| `.gitignore`、`.env.example` | 是 | `.env.example` 只有变量名,全部注释掉 |
| `foundry.toml`、`remappings.txt` | 是 | |
| `src/` | 是 | 5 个源文件,自审计起冻结(sha256 见 README) |
| `test/`、`test/fork/`、`test/utils/` | 是 | 两个 Hook 的测试 + 部署脚本的测试 |
| `script/` | 是 | 挖矿脚本、部署脚本(未审计)、依赖安装脚本、探针、链接检查脚本 |
| `checker/src/`(含 `checker/src/lib/`)、`checker/test/`、`checker/script/`、`checker/README.md` | 是 | 检查工具。注意 `checker/src/lib/` 是源码,`.gitignore` 里只忽略根目录的 `/lib/` |
| `checker/samples/`、`checker/test/mocks/` | 是 | 故意有漏洞的最小模型,文件头有"禁止部署"标注,标注要保留 |
| `checker/reports/local-samples-matrix.md`、`fork-samples-matrix.md` | 是 | 检查器自测生成的两张样本检出矩阵(自测每次会重写) |
| `docs/VolatilityFeeHook.md`、`docs/PriorityFeeHook.md` | 是 | 设计说明 |
| `docs/research/` | 是 | 两份事实表的公开副本(自报"未核实"的标注原样保留;发布前审查后删改了几处对具名第三方的推断和内部评语,见各文件首行) |
| `audits/` | 是 | 五份 AI agent 内部审计报告的公开副本 + PoC / 变体原件;`audits/README.md` 是索引和"禁止部署"说明 |
| `lib/` | **否** | 依赖,由 `script/install-deps.sh` 按钉死的 commit 拉取(里面有 BUSL-1.1 和 AGPL 的第三方源码,不随本仓库分发) |
| `out/`、`cache/`、`checker/out/`、`checker/cache/` | **否** | 构建产物 |
| `broadcast/` | **否** | forge script 的运行记录 |
| `checker/reports-local/` | **否** | 对 Base 上 5 个第三方 Hook 地址的 8 份冒烟测试输出在这里。没人逐条看过,不构成对第三方的结论,**默认不公开** |
| `.env`、`.env.*`(除 `.env.example`) | **否** | 不应存在;存在也被忽略 |
| `LICENSE` | 是 | MIT(仓库所有者 2026-11-12 定)。版权人已填(仓库所有者 2026-11-12 定);核对:`grep -n PLACEHOLDER LICENSE` 应无输出 |

## 2. 推送前要定的事

1. **许可证:已定 MIT(仓库所有者 2026-11-12 定)。`LICENSE` 已加,两份 README 已改,`LICENSE` 里的版权人已填。以下是当时的选项说明,留作记录。** 现状:76 个 `.sol` 文件头都是 `SPDX-License-Identifier: MIT`(含冻结的 5 个源文件);shell / Python 脚本和文档没有许可证头;仓库里没有 `LICENSE` 文件,README 写的是"待定,在加上 LICENSE 之前不授予任何许可"。选项与约束(不是法律意见):
   - **MIT**:与现有文件头一致,**唯一不需要改动冻结源文件的选项**;与 v4-periphery、OpenZeppelin uniswap-hooks 的许可证相同。定了以后要做的只有:加 `LICENSE` 文件(写上版权人和年份)、把两份 README 的"许可证"一节改掉。
   - **Apache-2.0**(多一条专利授权)、**GPL-3.0 / AGPL-3.0**(传染式)、**BUSL-1.1 之类的源码可见许可**:都要改全部 `.sol` 的 SPDX 头,包括冻结的 5 个源文件——只改注释不改字节码(`bytecode_hash = "none"`),但 sha256 会变,README、审计报告里引用的哈希对不上,需要重新核对并说明。源码可见类许可不算开源,与"开源作品集、申请资助"的目标不合。
   - **不加许可证**:默认保留所有权利,别人无权使用或修改;对作品集和资助申请不利。
   - 文档与审计报告可以与代码同许可,也可以单独标(例如 CC BY 4.0)。
   - 依赖方面的事实:① `VolatilityFeeHook` 的 import 闭包经 `StateLibrary.sol`(MIT)含 v4-core 的 `Position.sol`(BUSL-1.1);② `checker/src` 的 import 闭包含 5 个 BUSL-1.1 文件和 solmate 的 `MockERC20.sol`、`ERC20.sol`(AGPL-3.0-only)。这些文件不随本仓库分发(`lib/` 不入库)。它们对"给本仓库自己的文件选什么许可证"以及"别人编译、部署本仓库代码"各有什么约束,**我们没有做法律判断,定许可证前请找懂许可证的人确认。** 如果日后把 `lib/` 直接提交进仓库,这些文件就会随本仓库分发,上面的问题要连同各依赖自带的 LICENSE 文件一起重新确认。
2. **仓库名和归属:仓库名已定 `v4-hooks-base`(仓库所有者 2026-11-12 定);放个人账号还是组织、描述一句话,建仓库时由仓库所有者定。**README 标题现在是 "Uniswap v4 Hooks portfolio (Base)",没有写公司或个人名字。
3. **是否公开 8 份第三方地址报告。** 默认不公开(在 `checker/reports-local/`)。若要公开:先有人逐条看过每一条"无法判定",再从 `.gitignore` 里放行,并把 `checker/README.md`"真实地址试跑"一节改回带表格的写法。
4. **对外署名(名字已定,与 `LICENSE` 的版权人相同;邮箱仓库所有者已定,不写进本文件,推送时填进下面的 commit 命令)**:commit 的作者名和邮箱(会永久公开在提交历史里);是否在 README 写明作者 / 联系方式;是否在提交信息里注明由 AI agent 编写(README 已经写明)。
5. **`PUBLISHING.md` 自己要不要公开。** 内容不涉密;不想公开就在第一次提交前删掉,并把两份 README 目录树里的那一行去掉。
6. **审计报告里的岗位名和内部编号**:公开副本保留了 `hook-auditor`、`hook-engineer`、"项目负责人"和 H1 / H2 / H3 这些称呼(README 里有解释)。要不要进一步改写由项目负责人定;改写时不要动结论和发现。
7. **`src/VolatilityFeeHook.sol` 头部注释**里还写着整理前的路径 `research/audit-hooks-h1.md`。源文件冻结所以没改,README 里有说明。要改的话会改变该文件的 sha256(字节码不变),需要同步更新 README 里的哈希并说明。
8. **语言**:设计说明、审计报告、事实表都是中文;顶层 README 有英文。是否把设计说明翻成英文由项目负责人定(没有做)。

## 3. 推送步骤(由项目负责人执行)

在本目录(将成为仓库根)里:

```bash
# 0. 确认工具
forge --version && git --version

# 1. 推送前自查(都应无输出 / 0 broken / 哈希与 README 一致)
shasum -a 256 src/*.sol src/*/*.sol                      # 对照 README "Review status" 里的五行
python3 script/check-links.py                            # 文档内相对链接
grep -rnIE '/[U]sers/|/[h]ome/[a-z]|/private/[t]mp|BEGIN [A-Z ]*PRIVATE KEY' \
  --exclude-dir=lib --exclude-dir=out --exclude-dir=cache --exclude-dir=reports-local --exclude-dir=.git .
grep -rnIE '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z]{2,}' \
  --exclude-dir=lib --exclude-dir=out --exclude-dir=cache --exclude-dir=reports-local --exclude-dir=.git .
ls -a | grep -E '^\.env' | grep -v '^\.env\.example$'    # 不应有 .env

# 2. 测试(数字应与 README 一致)
forge build
forge test --no-match-path "test/fork/*"
BASE_RPC_URL=https://mainnet.base.org forge test --match-path "test/fork/*"
FOUNDRY_PROFILE=checker forge test --no-match-path "checker/test/fork/*"
FOUNDRY_PROFILE=checker BASE_RPC_URL=https://mainnet.base.org forge test --match-path "checker/test/fork/*"

# 3. 确认 LICENSE 的版权人已填:grep -n PLACEHOLDER LICENSE 应无输出

# 4. 建仓库并做第一次提交
git init -b main
git add -A
git status --short                                       # 逐行看一遍
git ls-files | grep -E '^lib/|reports-local|(^|/)\.env$|^out/|^cache/|^broadcast/'   # 应无输出
git ls-files | grep -c '^checker/src/lib/'               # 应为 3(这是源码,必须在)
git -c user.name="<与 LICENSE 版权人相同的署名>" -c user.email="<公开邮箱>" commit -m "Initial public release"

# 5. 在 GitHub 上新建一个空仓库(不要勾选自动生成 README / LICENSE),然后
git remote add origin https://github.com/<账号>/v4-hooks-base.git
git push -u origin main
```

依赖怎么让别人拿到:本仓库用的是 `script/install-deps.sh`(`lib/` 不入库,脚本按 commit 拉取并核对;已在全新目录里实测"拉依赖 → 构建 → 两个 profile 的离线测试")。如果更想用 git submodule,可以在第 4 步之前把 `.gitignore` 里的 `/lib/` 一行去掉、删掉本地 `lib/`,再对四个依赖各执行一次 `git submodule add <url> lib/<name>` 并在子模块里 `git checkout <commit>`(commit 见 README 的依赖表),不要 `--recursive`。**submodule 这条路没有实测过。**

## 4. 推送后

- 在 GitHub 页面上从头看一遍 README 的渲染、链接和表格;确认 `lib/`、`checker/reports-local/` 不在仓库里。
- 用一个全新的克隆按 README 的 "Build and test" 走一遍(这一步在推送前只用本地副本模拟过)。
- 可选:CI。下面是一个只跑离线测试的 GitHub Actions 示例(没有实测过;fork 测试依赖公共 RPC 保留历史状态,不建议放进 CI)。要用的话存成 `.github/workflows/test.yml`:

```yaml
name: test
on: [push, pull_request]
jobs:
  offline:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: foundry-rs/foundry-toolchain@v1
      - run: script/install-deps.sh
      - run: forge build
      - run: forge test --no-match-path "test/fork/*"
      - run: FOUNDRY_PROFILE=checker forge test --no-match-path "checker/test/fork/*"
      - run: python3 script/check-links.py
```

- 可选:在仓库设置里打开 secret scanning / push protection;加 `SECURITY.md` 写明"未经外部审计、如何报告问题"。
- 对外接单、提交资助申请、任何测试网或主网部署,仍由项目负责人本人操作;部署脚本未经审计。

## 5. 以后改动时要记住的

- `src/` 下五个文件改任何一个字节,sha256 就对不上审计报告;改注释以外的内容还会改变 init code、salt 和地址,需要重新挖地址并重新审计。
- `checker/src/`、`checker/samples/` 的逻辑改了要重新审计。
- 改文档后跑 `python3 script/check-links.py`;README 里的测试数量只写实际重跑得到的数字。
- 已知局限只能加、不能删、不能写轻。`PriorityFeeHook` 不得宣称能给 LP 带来可观收入。
