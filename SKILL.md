---
name: mac-cleanup
description: Analyze macOS directories for safe disk cleanup, execute data-driven cleanup with 18 modules, auto-discover uncovered caches, audit orphaned app leftovers by bundle identity, and generate maintainable bash cleanup scripts. Use when the user asks to clean up Mac disk space, analyze cache/log directories, manage cleanup rules, scan for stale project artifacts, clean leftovers of uninstalled apps, generate maintenance scripts, or iterate on cleanup rules. Dual-loop dual-tier architecture — agent writes only ~/.mac-cleanup/data.txt, never skill code.
version: 1.4.0
---

# Mac Cleanup Skill

macOS 磁盘清理技能：安全分析、数据驱动清理、自动发现盲区、持续迭代。

## 架构：双轮驱动 × 两级数据

```
┌──────────────────────────────────────────────────────────────┐
│                      数据轮 (Data Loop)                       │
│                                                              │
│  ┌─ Tier 1: Skill 数据 ─────────────────────────────────┐   │
│  │  scripts/cleanup-data.sh  (skill 目录内)               │   │
│  │  ● 经过验证的稳定规则                                   │   │
│  │  ● 由开发者维护、版本控制                                │   │
│  │  ● 用户不可修改                                        │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
│  ┌─ Tier 2: 用户数据 ───────────────────────────────────┐   │
│  │  ~/.mac-cleanup/data.txt  (用户主目录)                  │   │
│  │  ● agent 自动发现后追加                                 │   │
│  │  ● 用户可手动编辑微调                                   │   │
│  │  ● 不触碰 skill 代码                                   │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
│  数据轮: 新增规则 / 更新去重 / 调整阈值 → 只改数据，不改代码  │
├──────────────────────────────────────────────────────────────┤
│                      代码轮 (Code Loop)                       │
│                                                              │
│  mac-cleanup.sh  (引擎层)                                    │
│  ● 工具函数 + 模块逻辑 + 特殊处理                             │
│  ● source Tier 1 + Tier 2 数据后执行                         │
│  ● 由开发者维护和提交                                        │
│                                                              │
│  代码轮: 新增模块类型 / 修改执行逻辑 → 只改代码，不改数据      │
├──────────────────────────────────────────────────────────────┤
│                      发现层 (Discovery)                       │
│                                                              │
│  通道 A — scripts/scan-discover.sh   (pattern-first)         │
│  ● 扫描 Containers / AppSupport / dotfiles 盲区              │
│  ● --apply 追加到 ~/.mac-cleanup/data.txt                    │
│  ● 绝不修改 skill 目录中的文件                                │
│                                                              │
│  通道 B — scripts/disk-8020.sh       (size-first)            │
│  ● 全卷按占用排序，自顶向下收敛到 80% 分支                    │
│  ● 只读：不删文件、不写 data.txt、不进 -y                     │
│  ● 补通道 A 的结构性盲区（System/AssetsV2、Library/Developer、│
│    private/var/folders、/opt，以及「大文件而非缓存目录」）     │
│                                                              │
│  通道 C — scripts/app-orphans.sh     (identity-first)        │
│  ● 声明减法：候选 − 存活 bundle 声明 = 孤儿                   │
│  ● 只读；--emit-rules 才写 data.txt 的 ORPHAN_ID_RULES        │
│  ● 补「App 删了但数据还在」：Caches/Containers/Group          │
│    Containers/Preferences/Saved State/LaunchAgents           │
└──────────────────────────────────────────────────────────────┘
```

### 三个发现通道的分工

| | A `scripts/scan-discover.sh` | B `scripts/disk-8020.sh` | C `scripts/app-orphans.sh` |
|---|---|---|---|
| 判据 | 目录名模式（Cache/tmp/logs） | 占用大小排序 | bundle id 是否还有存活 bundle |
| 范围 | Containers / App Support / dotfiles | 整个卷 | 8 类 Library 根 |
| 强项 | 新装 App 的缓存 | 路径想不到的占用 | 已卸载 App 的整片残留 |
| 弱项 | 三条路径族之外看不见 | 只知大小，不知能否删 | 只认 bundle id 形态的目录 |
| 输出 | 可直接 `--apply` 成规则 | 仅供判定 | TSV 报告 + `--emit-rules` 写 A 级 |

**通道 C 的证据分级（判定标准，不是体积）：**
- **A**：LaunchServices 有该 bundle 的失效记录（`Bundle node not found on disk`），且无存活同名 bundle → 可进 `safe_remove` 候选
- **B**：仅目录残留，无卸载证据 → 只报告，人工确认
- **C**：`com.apple.*`、与现存 bundle 构成父子关系、组件后缀（helper/agent/xpc…）、同 TeamID 共享容器、静默期内被改写 → 不建议处理

**铁律：声明集不完整时必须输出零结果。** 没有完全磁盘访问、`lsregister` 失败、扫描超时时，宁可报告"零孤儿"，不可给一份猜出来的清单。

**铁律：尺寸 ≠ 可删。** Docker.raw 19 GB 是运行时必需，Trae 的 `database.db` 2.5 GB 是用户数据。
通道 B 的结果只能进入「待判定清单」，安全性判定仍必须走数据层。

### 核心原则

| 变更类型 | 改哪里 | 谁改 |
|---------|--------|------|
| 发现新缓存目录 | `~/.mac-cleanup/data.txt` | agent 自动 / 用户手动 |
| 发现孤儿残留 | `~/.mac-cleanup/data.txt` 的 `ORPHAN_ID_RULES` | `scripts/app-orphans.sh --emit-rules` |
| 新增已知 App 规则 | `scripts/cleanup-data.sh` (Tier 1) | 开发者 |
| 新增模块类型 | `mac-cleanup.sh` | 开发者 |
| 调整工作流 | `SKILL.md` | 开发者 |

**用户场景的铁律：agent 只写 `~/.mac-cleanup/data.txt`，绝不修改 skill 目录中的任何文件。**

## 目录结构

```
mac-cleanup.sh        # 唯一入口（引擎 + --analyze/--discover 直通）
scripts/
  cleanup-data.sh     # Tier 1 数据层
  scan-discover.sh    # 发现通道 A
  disk-8020.sh        # 发现通道 B
  app-orphans.sh      # 发现通道 C
tests/                # 回归测试与 fixture
docs/                 # 调研记录
```

## 触发场景

用户请求以下任务时自动触发：
- 清理 Mac 磁盘空间 / 瘦身
- 分析某个目录的清理潜力
- 管理或更新清理规则
- 扫描未覆盖的缓存盲区
- 清理不活跃项目的编译产物
- 生成磁盘维护脚本 / 清理方案

## 工作流

### 1. 分析目录

```
分析 → 分类 → 评估 → 整合 → 验证 → 执行
```

1. `du -sk` 获取目录大小
2. 分析子目录结构，逐项分类：SAFE / CAUTION / RISKY
3. 检查是否已被 Tier 1 或 Tier 2 覆盖
4. 将新规则写入 `~/.mac-cleanup/data.txt`（或引导用户使用 `--apply`）
5. dry-run 验证 → 确认后执行

### 2. 自动发现 → 追加用户数据

```
扫描 → 分析 → --apply 追加 → 验证
```

```bash
# 第一步：预览未覆盖目录
./scripts/scan-discover.sh

# 第二步：追加到用户数据（不动 skill 代码）
./scripts/scan-discover.sh --apply

# 第三步：验证（dry-run）
./mac-cleanup.sh -n
```

`--apply` 会：
1. 创建 `~/.mac-cleanup/data.txt`（如不存在）
2. 追加新规则（APP_CACHE_RULES / DOTFILE_CACHE_RULES）
3. 追加去重条目（DEDUP_CONTAINERS / DEDUP_APP_SUPPORT / DEDUP_DOTFILES）
4. 下次 `mac-cleanup.sh` 自动 source 这些数据

**注意：** 自动生成的路径可能需要手动微调。agent 应提醒用户检查 `~/.mac-cleanup/data.txt` 中的路径是否准确。

### 2b. 尺寸优先分析 → 定位盲区（通道 B）

当通道 A 连续报告"无新增"，但磁盘占用仍然偏高时，说明盲区不在缓存命名模式里，而在路径族之外。此时用尺寸优先分析。

```bash
# 全卷分析（只读，约 35 秒扫描 + 9 秒分析）
./mac-cleanup.sh --analyze

# 只看某个目录
./mac-cleanup.sh --analyze ~/Library

# 复用已有扫描结果秒级重算（换阈值/深度）
./scripts/disk-8020.sh --dump ~/.mac-cleanup/cache/duscan.tsv
```

**读法：** 每层列出子项及占整盘百分比，累计到 80% 的分支会继续下钻，其余折叠为一行；
`<直属文件>` 表示该目录下未被任何子目录覆盖的文件；`(折叠 N 项)` 表示剩余部分合计。

**处置流程：**

```
disk-8020 报告 → 逐项判定 SAFE / CAUTION / RISKY → SAFE 项写入 data.txt → dry-run 验证
```

**禁止：** 不因"大"就直接删除。判定标准是「是否可重建」，不是「占多少空间」：
- 可重建（可安全清理）：代码签名克隆、构建缓存、已下载更新包、临时目录
- 不可重建（需谨慎）：数据库文件、应用本地数据、构建产物中的 rollback 快照
- 必需（不可删）：Docker.raw、运行中应用的活跃数据

**参数：** `THRESHOLD`(0.8) `MIN_MB`(100) `MAX_DEPTH`(6) `MAX_KIDS`(8) `MIN_PCT`(1)，按环境变量传入。
回退方式：`./tests/disk-8020.test.sh`（12 项断言，覆盖递归状态污染与根层截断两类历史缺陷）。

### 2c. 孤儿残留审计 → 生成 bundle id 规则（通道 C）

```bash
./scripts/app-orphans.sh                 # 只读审计，TSV 报告写入 ~/.mac-cleanup/reports/
./scripts/app-orphans.sh --min-conf A    # 只看有卸载证据的
./scripts/app-orphans.sh --emit-rules    # A 级写入 ~/.mac-cleanup/data.txt
./mac-cleanup.sh -n              # 预览；确认后 -y 才真正移入废纸篓
```

**读法：** A 级＝有卸载证据（该 bundle id 的 LaunchServices 记录已失效）；B 级＝仅目录残留；
C 级＝不建议处理（系统身份／与现存 bundle 相关／helper 组件／同 TeamID 共享容器／静默期内被改写）。

**约束：**
- 只按 bundle id 归因，不按显示名。`Application Support/Google` 这类厂商父目录会被名字匹配误伤。
- Group Containers 只有在 stripped id 有失效证据时才进 A，并标 `shared`，不自动 emit。
- 静默期：A 级 7 天，B 级 30 天（`--quiet-days` 可调）。近期被写过的候选一律降 C。
- 迁移/换机后 `com.apple.*` 之外的容器可能被系统复用 —— 报告永远是「候选」，不是「可删」。
- 回退：`./tests/app-orphans.test.sh`（18 项断言，含「声明集为空必须报零」这条安全不变式）。

### 3. 从用户数据提升到 Skill 数据

当某个用户数据条目被多次验证（稳定、通用），开发者可将其"提升"到 Tier 1：

1. 从 `~/.mac-cleanup/data.txt` 复制规则到 `scripts/cleanup-data.sh`
2. 在 `scripts/cleanup-data.sh` 的去重列表中添加对应条目
3. 从用户数据文件中删除（避免重复）
4. 提交 skill 更新

### 4. 新增清理规则（直接编辑用户数据）

当 agent 分析出新的清理目标时，直接写入 `~/.mac-cleanup/data.txt`：

```bash
# 简单缓存
APP_CACHE_RULES+=(
  "\$HOME/Library/Application Support/Figma/Cache|Figma 缓存|cache_remove|5120"
)
DEDUP_APP_SUPPORT="\$DEDUP_APP_SUPPORT|Figma"

# dotfile 子目录
DOTFILE_CACHE_RULES+=(
  "\$HOME/.newapp|logs,cache|NewApp 缓存|10240"
)
DEDUP_DOTFILES="\$DEDUP_DOTFILES|.newapp"

# 孤儿检测
ORPHAN_RULES+=(
  "\$HOME/.oldapp|OldApp 残留|app:OldApp"
)

# Glob 模式删除（匹配文件模式）
GLOB_CACHE_RULES+=(
  "\$HOME/Library/Containers/com.example.app/Data/Documents|*.tmp|Example 临时文件|1024|清除 Example 临时文件?"
)

# 多用户目录遍历
MULTI_USER_RULES+=(
  "\$HOME/Library/Containers/com.example.app/Data/users|*|Cache,Logs|Example 多用户缓存|5120|清除 Example 用户缓存?"
)
```

### 5. 不活跃项目编译产物

在 `~/.mac-cleanup/data.txt` 中覆盖默认值：

```bash
STALE_DAYS=7                          # 改为 7 天
STALE_PROJECT_DIR="\$HOME/Projects"   # 改目录
STALE_ARTIFACT_DEFS+=(                # 新增产物类型
  ".parcel-cache|.parcel-cache (Parcel)"
)
```

### 6. 格式不支持时的处理

当 agent 发现的清理目标超出当前数组类型的表达能力时（如需要条件判断、多步操作、特殊 CLI 命令），不应强行塞入数据层。正确做法：

1. 告知用户："此项需要代码轮支持（新增模块类型），当前数据格式无法表达"
2. 在 `~/.mac-cleanup/data.txt` 头部用注释记录待办：`# TODO(code): 描述...`
3. 由开发者决定是否在 `mac-cleanup.sh` 中新增专用函数

**当前必须留在代码层的逻辑：** Docker prune（CLI+二次确认）、Homebrew cleanup、pnpm store prune、废纸篓 AppleScript、模拟器 dyld（sudo）、xcrun simctl。

### 7. 手动操作提醒（SIP / GUI 条目）

分析中发现受 SIP 保护或需要 GUI 操作的清理目标时，写入 `~/.mac-cleanup/data.txt` 的 `MANUAL_REMINDERS` 数组：

```bash
MANUAL_REMINDERS=(
  "路径|显示名|预估大小|操作指引|原理说明"
)
```

脚本运行时自动展示这些提醒（只展示不删除），包括：
- 路径是否仍存在（`[存在]` / `[已清理]`）
- 具体操作步骤（如 Xcode → Settings → Components）
- 原理说明（为什么会累积、为什么安全）

用户手动清理后，从 `data.txt` 中删除对应条目即可。

**典型场景：** `/System/Library/AssetsV2/` 下的 Xcode 文档索引、模拟器运行时等，受 SIP 保护无法脚本删除，但可通过 Xcode GUI 安全清理。

## 安全策略

| 级别 | 操作 | 适用 |
|------|------|------|
| `cache_remove` | 直接 rm | 纯缓存/日志 |
| `safe_remove` | 移入废纸篓 | 孤儿数据，可恢复 |
| `sudo rm` | 需 root | 系统目录 |
| 二次确认 | confirm×2 | Docker prune |

**硬性规则：** 路径使用 `$HOME`；所有操作支持 `-n` dry-run；macOS bash 3.2 兼容。

## 脚本速查

```bash
./mac-cleanup.sh              # 交互模式
./mac-cleanup.sh -n           # 预览
./mac-cleanup.sh -y           # 自动执行
./mac-cleanup.sh -n --discover  # 预览 + 发现
./mac-cleanup.sh --analyze    # 80/20 占用分析（只读）
./mac-cleanup.sh --analyze ~/Library   # 只分析指定目录
./scripts/scan-discover.sh            # 扫描报告
./scripts/scan-discover.sh --patch    # 查看补丁（不写入）
./scripts/scan-discover.sh --apply    # 追加到 ~/.mac-cleanup/data.txt
./scripts/disk-8020.sh --dump <file>  # 复用 dump 重算
./scripts/app-orphans.sh              # 孤儿残留审计（只读）
./scripts/app-orphans.sh --emit-rules # A 级写入 data.txt
./scripts/app-orphans.sh --verify ID  # 判定这些 bundle id 是否仍有主
./tests/disk-8020.test.sh     # 回归测试
./tests/app-orphans.test.sh   # 回归测试
```

## 工具函数

| 函数 | 用途 |
|------|------|
| `size_of <path>` | 目录大小 (KB) |
| `human_size <kb>` | KB → 人类可读 |
| `confirm "问题"` | 交互确认（dry-run 下恒返回 0，**不可**直接决定外部 CLI 是否执行） |
| `run_cli "描述" cmd...` | 执行不可逆 CLI（brew/pnpm/simctl），dry-run 下只打印 |
| `cache_remove <path>` | rm (dry-run 安全) |
| `safe_remove <path>` | 移入废纸篓 |
| `calc_freed <b> <a>` | 累计释放量 |
| `section "标题"` | 开始新节 |
| `report_section` | 打印汇总 |

## 参考文档

- 脚本架构与模块详情: [script-reference.md](script-reference.md)
