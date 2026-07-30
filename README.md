# Scribe

**中文** · [English](README.en.md)

> 一个由人审核的 Claude Code 长期事实与决策账本。

## 先理解它解决什么

Claude Code 擅长在当前会话内调查和执行，但新会话不天然继承已经核实过的项目背景。重复解释背景、重复调查同一条代码路径，会让工作越来越像从零开始。

直接让模型自己写"长期记忆"也有风险：一个未经验证的推测一旦被保存，下次就可能被当成既成事实引用。Scribe 的目的不是让模型记得越多，而是让真正值得复用的内容以可审查、可撤销的方式留下来。

## 核心原理

Scribe 把"发现"和"确认"拆开：

```text
Claude 发现可复用信息
        │
        ▼
candidate（候选；不是事实）
        │
        │  你审阅并执行确认命令
        ▼
active（可被后续会话发现的线索）
        │
        ├── 新证据反驳事实 → superseded
        ├── 用户更新决策   → superseded
        ├── 不再适用       → retired
        └── 已确认错误     → revoked
```

这里的关键不是 Markdown 文件，而是权限和状态含义：Claude 可以提出候选，但不能自行把候选提升为长期结论。已确认卡片也只是"调查路线图"，使用前仍要核验当前的一手证据；当场用户指令永远优先于旧卡片。

## Scribe 不是什么

- 不是自动写入的知识库；不会自动把候选提升为 active。
- 不是向量数据库；小规模时用项目范围、索引和关键词即可。
- 不是项目文档生成器；不会改你的 README、代码或设计文档。
- 不是安全沙箱；Claude Code 的 deny 规则能减少误操作，但 shell 包装仍可能绕过它。

## 安装

### 前提

- Claude Code
- Git
- Python 3.8 或更高版本

克隆到任意你管理的目录；下文用 `<scribe-dir>` 表示该目录，不假定任何机器路径。

```bash
git clone <repository-url> <scribe-dir>
cd <scribe-dir>
./scribe install claude-code
./scribe doctor
```

`install` 可以重复执行。它会：

1. 创建私有数据仓（默认在 `<home>/.claude/scribe`）；
2. 为数据仓建立本地 Git 基线；
3. 注册一个 SessionStart hook；
4. 允许 Claude 写候选；
5. 拒绝 Claude 直接执行批准、归档、停用和撤销命令。

若系统中有多个 Python，Scribe 优先使用 `SCRIBE_PYTHON` 指定的可用 Python 3.8+；否则依次扫描 `PATH` 中的 `python3` 和 `python`。找不到可用解释器时，命令会明确失败；会话 hook 仍会输出契约，但跳过记忆索引，不阻塞会话。

## 第一次使用

安装后，先正常做真实工作，不要先批量导入或手工制造大量卡片。

当 Claude 在任务中确认了一条有跨会话价值的信息，它会调用 `record-candidate` 写入候选。好的候选必须包含：

- 主张
- 证据
- 适用范围
- 不涵盖什么
- 在什么条件下失效
- 将来何时有用

定期审阅，而不是每次都被打断：

```bash
cd <scribe-dir>
./bin/review-ledger review
```

该命令显示最早的最多五条候选，并轮换抽审两条 active 卡。候选积压超过五条时，下一次会话会收到非阻塞提醒。

## 你的确认动作

确认、归档、停用和撤销是你的动作，不是 Claude 的动作。审阅后，在自己的终端执行：

```bash
./bin/review-ledger approve SCR-YYYYMMDD-XXXXXX
./bin/review-ledger archive SCR-YYYYMMDD-XXXXXX
./bin/review-ledger retire SCR-YYYYMMDD-XXXXXX '不再适用的原因'
./bin/review-ledger revoke SCR-YYYYMMDD-XXXXXX '确认错误的原因'
```

在 Claude Code 的交互终端中，可用前缀 `! ` 让命令由你的 shell 执行。例如：

```text
! ./bin/review-ledger approve SCR-YYYYMMDD-XXXXXX
```

状态含义：

| 状态 | 含义 | 会被召回？ |
|---|---|---|
| `candidate` | 等待你审核 | 否 |
| `active` | 已确认的调查线索 | 是 |
| `superseded` | 被更新卡替代 | 否 |
| `retired` | 不再适用 | 否 |
| `revoked` | 已确认错误 | 否 |
| `archived` | 审阅后不采纳 | 否 |

## 范围：项目卡与全局卡

项目卡会在当前工作目录位于该项目范围内时出现。`--project` 必填，且必须是存在的绝对目录。

```bash
./bin/record-candidate \
  --type project_fact \
  --claim '订单状态枚举定义在 order.py:15' \
  --evidence 'app/models/order.py:15' \
  --scope '订单状态查询' \
  --not-covered '支付渠道最终结果' \
  --invalidated-by '状态枚举迁移或重命名' \
  --future-use '排查订单状态异常' \
  --project "$(git rev-parse --show-toplevel)"
```

在 Git 工作区的子目录内记录时，Scribe 默认把范围上提到仓库根，避免"卡片只在子目录可见、在仓库根悄悄消失"。确实只适用于子包的事实才使用 `--scope-exact`。

全局卡用 `--project @global`，会出现在每个会话。它只适合跨项目的 `decision`、`preference`、`correction` 和 `decision_change`；事实总应属于某一个项目。

## 替代旧结论

不要删除旧卡。若事实被新证据反驳，创建 `fact_supersession`；若用户改变已确认的决策，创建 `decision_change`。Scribe 会保留旧卡的历史，同时把它移出 active。

替代必须满足两条约束：范围相同、类型相容。事实替代只能替代事实；决策变更只能替代决策、偏好、纠正或先前的决策变更。写候选和批准时都会复验。

```bash
./bin/record-candidate \
  --type decision_change \
  --claim '新决策的简短表述' \
  --evidence '用户在当前会话明确更新了原决策' \
  --scope '该决策的适用范围' \
  --not-covered '未改变的技术细节' \
  --invalidated-by '用户再次改变决策' \
  --future-use '避免下次沿用旧决策' \
  --project @global \
  --replaces SCR-YYYYMMDD-XXXXXX \
  --new-statement '用户最新表述'
```

如果被替代的卡是 `--scope-exact` 的子目录卡，替代卡也必须带同一标志；Scribe 会在报错中说明这一点。

## 查找和使用卡片

每个会话启动时，Scribe 注入当前项目与全局 active 卡的简短索引。它只显示 ID 与主张，避免将整份账本塞进上下文。

需要细查时：

```bash
./bin/review-ledger list
./bin/review-ledger recall 订单 支付
./bin/review-ledger recall --all 订单
./bin/review-ledger show SCR-YYYYMMDD-XXXXXX
```

`list` 与 `recall` 默认只看当前项目和全局卡；`--all` 才查看全部项目。任何命中仍须回到代码、日志、数据源或用户当前表述进行核验。

## 数据、快照与隐私

默认数据目录是 `<home>/.claude/scribe`，与代码仓分离。它是一个本地 Git 仓，但账本内容不会自动提交：

```bash
./scribe snapshot 'after weekly review'
```

`backups/` 保存 settings 的原样备份，`imported/` 保存尚未审核的旧 memory；两者均被 Git 忽略，不应推送。若数据仓的旧历史曾经跟踪过它们，取消跟踪不会清除历史 blob；在重写历史或重建数据仓前，不要推送该数据仓。

安装时可能自动创建一个空基线 commit，或创建一个仅用于取消跟踪 `backups/` / `imported/` 的 housekeeping commit；这两类提交都不包含账本卡片。

## 迁移旧原生 memory

若之前使用过 Claude Code 原生 project memory，可先预演：

```bash
./scribe migrate
./scribe migrate --apply
```

`--apply` 只复制，不删除原文件；同名导入文件会被跳过，不会覆盖你的批注。导入不是确认：逐条检查后，仍然成立的内容应重新作为带证据的 candidate 记录。

## 验证与维护

运行回归测试：

```bash
./tests/run.sh
./tests/run.sh -v
```

测试使用临时数据目录、临时 settings 与临时原生 memory，不会读写真实账本或真实 Claude 配置。它覆盖写入校验、范围、去重、完整生命周期、召回、hook 模拟、抽审轮换、修复检查、迁移、解释器选择以及安装幂等。

批准流程包含多个文件操作；意外中断时，使用：

```bash
./scribe doctor --repair-check
```

该检查会报告重复出现的 ID、错误 active 状态、断裂的替代链及历史状态不一致。它报告问题，不会擅自替你修改账本。

## 已知边界

- 候选字段校验只能保证结构与证据形状，不能证明结论为真。
- deny 是防误操作的地板，不是对任意 shell 的安全隔离。
- SessionStart 的真实行为应在你的 Claude Code 环境中用一张项目卡和一张全局卡验收一次。
- 原生 memory 是否会被 Claude Code 在工具权限之外自动注入，应通过一次真实新会话验证。
- 先用三次真实任务观察摩擦；约十次不同任务后，再判断它是否真的减少重复解释与返工。
