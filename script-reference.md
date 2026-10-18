## 脚本架构参考

### 文件职责

| 文件 | 层级 | 职责 | 谁改 |
|------|------|------|------|
| `cleanup-data.sh` | Tier 1 数据 | 稳定清理规则、去重列表 | 开发者 |
| `~/.mac-cleanup/data.txt` | Tier 2 数据 | 用户级发现数据、本地追加 | agent / 用户 |
| `mac-cleanup.sh` | 引擎 | source 两级数据 + 执行清理；`--analyze` 直通 disk-8020 | 开发者 |
| `scan-discover.sh` | 发现通道 A | pattern-first：扫描盲区、--apply 写 Tier 2 | 开发者 |
| `disk-8020.sh` | 发现通道 B | size-first：全卷 80/20 下钻，**严格只读** | 开发者 |
| `tests/disk-8020.test.sh` | 测试 | 通道 B 回归断言（递归状态污染 / 根层截断） | 开发者 |
| `SKILL.md` | 文档 | agent 工作流指南 | 开发者 |

### 发现层双通道

| | 通道 A `scan-discover.sh` | 通道 B `disk-8020.sh` |
|---|---|---|
| 判据 | 目录名模式 | 占用大小 |
| 范围 | 3 条固定路径族 | 整个卷 |
| 可写数据层 | 是（`--apply`） | **否，永不** |
| 成本 | 1~2 秒 | ~42 秒（33 MB dump） |

`disk-8020.sh` 与引擎的契约边界：不 source `cache_remove` / `safe_remove`，不参与 `-y`，
不修改 `data.txt`。它回答「该看哪里」，引擎回答「能不能删」。

### 两级数据层

**Tier 1** (`cleanup-data.sh`): 定义基础数组，如 `APP_CACHE_RULES=()`、`DEDUP_CONTAINERS="..."`

**Tier 2** (`~/.mac-cleanup/data.txt`): bash-sourceable 文件，用 `+=` 追加到同一数组：
```bash
# ~/.mac-cleanup/data.txt
APP_CACHE_RULES+=(
  "\$HOME/Library/Application Support/NewApp/Cache|NewApp|cache_remove|5120"
)
DEDUP_APP_SUPPORT="\$DEDUP_APP_SUPPORT|NewApp"
```

mac-cleanup.sh 启动时先 source Tier 1，再 source Tier 2，数组自动合并。

### 数据层格式速查

#### 去重列表（管道分隔字符串）

```bash
DEDUP_CONTAINERS="bundle.id.1|bundle.id.2|..."
DEDUP_APP_SUPPORT="DirName1|DirName2|..."
DEDUP_DOTFILES=".dir1|.dir2|..."
```

#### 编辑器缓存

```bash
EDITOR_AS_CACHES=(
  "ApplicationSupport目录名|显示名"
)
IDE_LIB_CACHES=(
  "Caches目录名|显示名"
)
SHIPIT_CACHES=(
  "ShipIt目录名|关联App显示名"
)
```

#### 应用缓存规则

```bash
APP_CACHE_RULES=(
  "\$HOME/完整路径|显示名|cache_remove|阈值KB"
)
```

操作类型: `cache_remove` (直接rm) 或 `safe_remove` (移入废纸篓)

#### dotfile 缓存规则

```bash
DOTFILE_CACHE_RULES=(
  "\$HOME/.dir|subdir1,subdir2|显示名|阈值KB"
)
```

子目录用逗号分隔，脚本逐个检查并清理。

#### 孤儿检测规则

```bash
ORPHAN_RULES=(
  "\$HOME/.dir|显示名|app:关键字"
)
```

当 `/Applications` 中无匹配 `*关键字*` 的 App 时，标记为孤儿。

#### 代码签名缓存规则 (v1.3.0)

```bash
CODE_SIGN_RULES=(
  "bundle前缀|App显示名|安装检查路径"
)
```

引擎用 `find /private/var/folders -name "*.code_sign_clone"` 发现目录，根据 bundle 前缀匹配规则判断 App 是否仍安装。

#### Xcode 缓存规则 (v1.3.0)

```bash
XCODE_CACHE_RULES=(
  "相对于~/Library/Developer的路径|显示名|阈值KB|提示语"
)
```

模拟器管理（xcrun simctl）为 CLI 逻辑，留在代码层。

#### Glob 模式清理规则 (v1.3.0)

```bash
GLOB_CACHE_RULES=(
  "\$HOME/目录路径|glob模式|显示名|阈值KB|提示语"
)
```

引擎统计匹配 glob 的文件总大小，超过阈值时提示删除。适用于：QQ 表情 zip、同花顺交易日志等。

#### 多用户目录遍历规则 (v1.3.0)

```bash
MULTI_USER_RULES=(
  "\$HOME/用户基础路径|用户通配符|子路径1,子路径2|显示名|阈值KB|提示语"
)
```

引擎遍历 `基础路径/通配符/` 下的每个用户目录，清理指定子路径。适用于：腾讯文档多用户 SW+Cache。

#### 独立模块路径配置 (v1.3.0)

```bash
LOGS_DIR="\$HOME/Library/Logs"
LOGS_THRESHOLD=5120
CRASH_DIR="\$HOME/Library/Application Support/CrashReporter"
CRASH_THRESHOLD=1024
```

#### 编译产物定义

```bash
STALE_ARTIFACT_DEFS=(
  "目录名|显示名"
)
```

脚本在 `STALE_PROJECT_DIR` 下查找 `STALE_DAYS` 天不活跃的项目，逐个检查这些目录。

### 引擎层模块清单

| # | 模块 | 函数 | 数据来源 | 特殊处理 |
|---|------|------|---------|---------|
| 1 | 代码签名缓存 | `cleanup_code_sign_clone` | CODE_SIGN_RULES | find + sudo rm |
| 2 | Docker | `cleanup_docker` | 无 (CLI) | docker system prune + 日志 + 下载残留 |
| 3 | Xcode | `cleanup_xcode` | XCODE_CACHE_RULES | 模拟器用 xcrun simctl (CLI) |
| 4 | 编辑器缓存 | `cleanup_editor_caches` | EDITOR_AS_CACHES, IDE_LIB_CACHES, SHIPIT_CACHES | 无 |
| 5 | Homebrew | `cleanup_homebrew` | 无 (CLI) | `brew cleanup` 命令 |
| 6 | npm | `cleanup_npm` | DOTFILE_CACHE_RULES | 仅报告总大小，清理由 dotfile 逻辑执行 |
| 7 | pnpm | `cleanup_pnpm` | 无 (CLI) | `pnpm store prune` 命令 |
| 8 | 系统缓存 | `cleanup_system_caches` | SYSTEM_CACHES | Brave SW CacheStorage 单独处理 |
| 9 | App 缓存 | `cleanup_app_caches` | APP_CACHE_RULES, DOTFILE_CACHE_RULES, ORPHAN_RULES | 无 |
| 10 | Glob 清理 | `cleanup_glob_caches` | GLOB_CACHE_RULES | glob 匹配文件删除 |
| 11 | 多用户清理 | `cleanup_multi_user_caches` | MULTI_USER_RULES | 遍历用户目录 |
| 12 | 应用日志 | `cleanup_logs` | LOGS_DIR, LOGS_THRESHOLD | 全目录清理 |
| 13 | 崩溃报告 | `cleanup_crash_reports` | CRASH_DIR, CRASH_THRESHOLD | 全目录清理 |
| 14 | 不活跃项目 | `cleanup_stale_projects` | STALE_PROJECT_DIR, STALE_DAYS, STALE_ARTIFACT_DEFS | 嵌套 node_modules、xcuserdata |
| 15 | 模拟器 dyld | `cleanup_simulator_caches` | 无 | 需要 sudo |
| 16 | 自动发现 | `cleanup_auto_discover` | DEDUP_*, DISCOVER_* | 单次 find 扫描 |
| 17 | 废纸篓 | `cleanup_trash` | 无 (CLI) | Finder AppleScript |

### 性能优化

**自动发现**使用单次 `find` 命令扫描 `~/Library/Containers` 和 `~/Library/Application Support`（约 1~2 秒），避免逐目录遍历 GB 级目录。

**不活跃项目**先用 `find -mtime` 快速筛选不活跃项目，再逐个扫描编译产物。嵌套 `node_modules` 通过 `find -maxdepth 3` 发现 monorepo 子包。

### bash 3.2 兼容性

- 不使用 `declare -A`（关联数组）
- 不使用 `awk` 插值变量（`human_size` 用纯 bash 算术）
- 数组用 `|` 分隔字符串模拟结构化数据
- `IFS='|' read -r` 解析字段

### 同步机制

**现状（2026-10-18 17:19 起）：`~/.workbuddy/skills/mac-cleanup` 是指向开发目录的符号链接。**

```bash
~/.workbuddy/skills/mac-cleanup -> ~/Code/mac-cleanup-skill
```

改仓库即生效，无需 cp。历史背景：此前它是**实目录副本**（inode 不同），曾导致
「引擎 dry-run 删除 bug 已在仓库修复、用户侧仍跑旧版」的静默不一致；已改为软链根治。

**仍需校验**（软链也可能断，且平台对断链是静默忽略的）：

```bash
test -L ~/.workbuddy/skills/mac-cleanup && echo "软链存在" || echo "不是软链"
readlink ~/.workbuddy/skills/mac-cleanup
cd ~/.workbuddy/skills/mac-cleanup && pwd -P     # 应解析到开发目录
```

改软链前的原副本备份在 `~/.workbuddy/skills/.backup-mac-cleanup-20261018-1719`
（含 `_user_meta.json`；符号链接型技能不需要该文件，现有链接型技能均无）。

**注意：** `pwd -P` 会把软链解析成物理路径，因此 `mac-cleanup.sh` 的 `SCRIPT_DIR`
永远指向开发目录，`--analyze` 调用 `disk-8020.sh` 不受影响。

### 迭代检查清单

新增清理规则后（Tier 2 用户数据）：

- [ ] 追加到 `~/.mac-cleanup/data.txt`
- [ ] 同步更新去重条目（DEDUP_*）
- [ ] `./mac-cleanup.sh -n` 预览验证
- [ ] `./scan-discover.sh` 确认不再重复报告

新增稳定规则后（Tier 1 提升到 skill 数据）：

- [ ] 从 `~/.mac-cleanup/data.txt` 复制到 `cleanup-data.sh`
- [ ] 在用户数据中删除对应条目（避免重复）
- [ ] `bash -n mac-cleanup.sh` 语法检查
- [ ] 提交 skill 更新

新增模块类型后：

- [ ] 在 `mac-cleanup.sh` 中添加函数
- [ ] 在 MAIN 中注册调用
- [ ] 更新 `cleanup-data.sh` 去重列表
- [ ] 更新本文件的模块清单表格
- [ ] 语法检查 + dry-run 验证

修改引擎或发现层代码后（**每次都要**）：

- [ ] `bash -n` 语法检查（`set -euo pipefail` 下尤其注意 `$1` 空值）
- [ ] `./tests/disk-8020.test.sh` 全绿
- [ ] 用 PATH 探针确认 dry-run 未调用真实 CLI（`pnpm` / `brew` / `xcrun`）
- [ ] 确认 `~/.workbuddy/skills/mac-cleanup` 软链未断（`readlink` + `pwd -P`）
- [ ] `./mac-cleanup.sh -n` 从软链路径跑一遍（软链断链时平台静默忽略，不会报错）
