# audits/

本目录的 `.sol` 是审计员当时写的 PoC 和变体的原件,针对的是本仓库自己的 Hook 和检查器,只在本地模拟里用过;其中的变体是故意有缺陷的模型,**禁止部署**。报告是 AI agent 内部审计,不等于外部审计。

The `.sol` files here are the auditor's original PoCs and variants. They target this repository's own
hooks and checker and were only ever used in local simulation. The variants are deliberately defective
models: **do not deploy them**. The reports are internal audits by an AI agent, not an external audit.

## 文件索引

"H1 / H2 / H3" 分别指 `VolatilityFeeHook`、`PriorityFeeHook`、检查工具 `checker/`。报告是中文。

| 对象 | 文件 | 内容 |
|---|---|---|
| `VolatilityFeeHook` | [`audit-hooks-h1.md`](audit-hooks-h1.md) | 首轮审计报告 |
| | [`audit-hooks-h1-reaudit.md`](audit-hooks-h1-reaudit.md) | 复审报告;第三轮窄范围复查附在末尾 |
| | [`audit-hooks-h1/AuditPoC.t.sol`](audit-hooks-h1/AuditPoC.t.sol) | 首轮 PoC |
| | [`audit-hooks-h1/ReAudit.t.sol`](audit-hooks-h1/ReAudit.t.sol) | 复审 PoC |
| | [`audit-hooks-h1/logprice_check.py`](audit-hooks-h1/logprice_check.py) | 对数价计算的核对脚本 |
| `PriorityFeeHook` | [`audit-hooks-h2.md`](audit-hooks-h2.md) | 首轮审计报告;第二轮窄范围复查附在末尾 |
| | [`audit-hooks-h2/AuditH2.t.sol`](audit-hooks-h2/AuditH2.t.sol) | PoC |
| 检查工具 `checker/` | [`audit-hooks-h3.md`](audit-hooks-h3.md) | 首轮审计报告 |
| | [`audit-hooks-h3-reaudit.md`](audit-hooks-h3-reaudit.md) | 复审报告;项目负责人对收尾修复的核对记录附在末尾 |
| | [`audit-hooks-h3/AuditHooks.sol`](audit-hooks-h3/AuditHooks.sol) | 首轮用来骗检查器的变体 Hook(故意有缺陷,禁止部署) |
| | [`audit-hooks-h3/Audit.t.sol`](audit-hooks-h3/Audit.t.sol)、[`audit-hooks-h3/ForkReenter.t.sol`](audit-hooks-h3/ForkReenter.t.sol) | 首轮测试(离线 / fork 重入) |
| | [`audit-hooks-h3/mutate.py`](audit-hooks-h3/mutate.py)、[`audit-hooks-h3/mutation-results.txt`](audit-hooks-h3/mutation-results.txt) | 首轮对检查器做的变异及结果 |
| | [`audit-hooks-h3/reaudit/Reaudit2Hooks.sol`](audit-hooks-h3/reaudit/Reaudit2Hooks.sol) | 复审的变体 Hook(故意有缺陷,禁止部署) |
| | [`audit-hooks-h3/reaudit/Reaudit2.t.sol`](audit-hooks-h3/reaudit/Reaudit2.t.sol)、[`audit-hooks-h3/reaudit/ForkReaudit2.t.sol`](audit-hooks-h3/reaudit/ForkReaudit2.t.sol) | 复审测试(离线 / fork) |
| | [`audit-hooks-h3/reaudit/mutate2.py`](audit-hooks-h3/reaudit/mutate2.py) | 复审对检查器做的变异 |

- 这些 `.sol` 不在任何 Foundry profile 的编译范围内;要跑的话按各报告里的"跑法"复制到对应目录。
- 报告是公开副本:相对整理前的原件只清理了内部路径与称谓,结论和发现未改。PoC 与变体文件是原件,未改动;其中多数文件内没有"禁止部署"的标注,以本页为准。
- 部署脚本(`script/Deploy*.s.sol` 等)不在这五份报告的范围内;它们的审查状态见根目录 README 的"审计状态"一节。
