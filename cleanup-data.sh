#!/usr/bin/env bash
# ============================================================================
#  macOS 清理脚本 — 数据层 (Data Layer)
#  本文件定义所有清理规则、去重列表和配置参数
#  由 mac-cleanup.sh 在启动时 source 加载
#
#  双轮驱动说明:
#    数据轮 (本文件): 新增/修改清理规则、去重列表、阈值 → 不改脚本
#    代码轮 (mac-cleanup.sh): 新增模块类型、修改执行逻辑 → 不改数据
#
#  格式约定:
#    数组元素用 "|" 分隔字段: "路径|显示名|类型|阈值KB"
#    去重列表用 "|" 分隔关键词
# ============================================================================

DATA_VERSION="1.4.0"

# ── 去重列表 ─────────────────────────────────────────────────────────────────
# 自动发现模块跳过已覆盖的路径，避免重复报告
# 新增手动规则后，必须同步更新对应列表

# Containers 中的 bundle id
DEDUP_CONTAINERS="com.docker.docker|com.tencent.meeting|com.tencent.qq|com.tencent.qqexdoc|cn.com.10jqka.macstockPro|org.telegram.desktop"

# Application Support 中的目录名（支持子串匹配）
DEDUP_APP_SUPPORT="TRAE SOLO CN|Trae CN|Code|BraveSoftware|QoderCN|obsidian|com.docker.install|CrashReporter"

# Home dotfiles 目录名（不含 . 前缀）
DEDUP_DOTFILES=".hermes|.workbuddy|.qoder-cn|.trae-cn|.bun|.gem|.codebuddy|.codebuddycn|.lightningx|.tke-toolkit|.tencent-cloud-toolkit|.qoderworkcn|.npm|.Trash|.ssh|.gnupg|.config"

# ── 编辑器缓存（Application Support 下的 logs + CachedData）─────────────────
# 格式: "Application Support 下的目录名|显示名"
EDITOR_AS_CACHES=(
  "TRAE SOLO CN|TRAE SOLO CN"
  "Trae CN|Trae CN"
  "Code|VS Code"
)

# ── IDE 缓存（~/Library/Caches 下的完整目录）──────────────────────────────
# 格式: "Caches 下的目录名|显示名"
IDE_LIB_CACHES=(
  "TRAE SOLO CN|TRAE SOLO CN"
  "Trae CN|Trae CN"
)

# ── ShipIt 更新包暂存（已应用的 Electron 更新包）─────────────────────────
# 格式: "Caches 下的目录名|显示名"
SHIPIT_CACHES=(
  "cn.trae.app.ShipIt|Trae CN"
  "cn.trae.solo.app.ShipIt|Trae Solo CN"
)

# ── 系统缓存（~/Library/Caches 下的特定目录）─────────────────────────────
# 格式: "Caches 下的目录名|显示名"
SYSTEM_CACHES=(
  "BraveSoftware|BraveSoftware (浏览器)"
  "Google|Google (浏览器)"
  "com.google.Chrome|Chrome"
  "org.chromium.Chromium|Chromium"
  "Homebrew|Homebrew 下载"
  "pip|pip"
  "node-gyp|node-gyp 构建"
)

# ── 应用缓存规则 ─────────────────────────────────────────────────────────
# 格式: "完整路径模板|显示名|操作类型|阈值KB"
# 路径中 \$HOME 会在运行时展开
# 操作类型: cache_remove (直接删除) / safe_remove (移入废纸篓)
APP_CACHE_RULES=(
  "\$HOME/Library/Containers/org.telegram.desktop/Data/Library/Application Support/Telegram Desktop/tdata/user_data/cache|Telegram 媒体缓存|cache_remove|10240"
  "\$HOME/Library/Containers/com.tencent.meeting/Data/Library/Global/Logs|腾讯会议日志|cache_remove|10240"
  "\$HOME/Library/Containers/com.tencent.meeting/Data/Library/Global/Data|腾讯会议资源缓存|cache_remove|10240"
  "\$HOME/Library/Application Support/QoderCN/SharedClientCache/cache|QoderCN 客户端缓存|cache_remove|10240"
  "\$HOME/Library/Application Support/obsidian/Cache|Obsidian 浏览器缓存|cache_remove|10240"
  # ── 自 Tier 2 提升 (2026-09-27): ~/.cache 纯缓存目录，删除后自动重建 ──
  "\$HOME/.cache/csbot-transformers|csbot transformers 模型缓存|cache_remove|5120"
  "\$HOME/.cache/prisma|Prisma 引擎缓存|cache_remove|5120"
  "\$HOME/.cache/fontconfig|fontconfig 字体缓存|cache_remove|5120"
)

# ── 已安装 App 的 dotfile 缓存/日志 ──────────────────────────────────────
# 格式: "dotfile 路径|子目录1,子目录2|显示名|阈值KB"
DOTFILE_CACHE_RULES=(
  "\$HOME/.hermes|state-snapshots,logs|Hermes 快照+日志|10240"
  "\$HOME/.workbuddy|logs,traces|WorkBuddy 日志+traces|10240"
  "\$HOME/.qoder-cn|logs,cache|QoderCN 日志+缓存|10240"
  "\$HOME/.bun/install|cache|bun 包缓存|10240"
  "\$HOME/.gem|specs|gem 索引缓存|10240"
  "\$HOME/.cache/rod|browser|rod 浏览器缓存|10240"
  "\$HOME/.npm|_cacache,_npx,_logs|npm 缓存+npx+日志|1024"
)

# ── 孤儿 dotfile 检测（App 已卸载时自动标记）────────────────────────────
# 格式: "路径|显示名|app:App关键字"
# 判定: `ls /Applications/*<关键字>*` 命中 → 视为在用，跳过。
# 注意: 关键字必须能在 /Applications 里以文件名形式命中，否则 app 在用也会误判为孤儿。
ORPHAN_RULES=(
  "\$HOME/.lightningx|LightningX|app:LightningX"
  "\$HOME/.tke-toolkit|TKE Toolkit|app:TKE"
  "\$HOME/.tencent-cloud-toolkit|腾讯云工具包|app:Tencent Cloud"
  # XELive 是「鹅直播.app」(com.xet.live，内含 MacOS/xelivepro.app) 的推流数据目录，
  # 关键字必须指向宿主 App「鹅直播」，不能写 XELive（无同名 .app，会误删在用数据）。
  "\$HOME/Library/Application Support/XELive|鹅直播 XELive 推流数据|app:鹅直播"
  "\$HOME/Library/Application Support/super-creator|super-creator|app:super-creator"
)
# 已移除: ~/.codebuddy、~/.codebuddycn —— 二者是 CodeBuddy 的配置（settings.json /
# skills / code-ratio），不是缓存；且 WorkBuddy 沿用了同目录，删除即丢失配置。

# ── 孤儿数据（bundle id 级）──────────────────────────────────────────────
# 由 app-orphans.sh --emit-rules 审计后追加，勿手写。
# 格式: "bundle.id|显示名|路径1,路径2"
# 区别于 ORPHAN_RULES: 判据是「该 bundle id 是否还有存活 bundle」
# （LaunchServices + 在装清单），不是「/Applications 里有没有同名 .app」。
# 引擎执行前会再核验一次；删除走 safe_remove（废纸篓）。
ORPHAN_ID_RULES=()

# ── 代码签名缓存规则（/private/var/folders 下的 *.code_sign_clone）────────
# 格式: "bundle前缀|App显示名|安装检查路径"
# 引擎用 find 匹配 *.code_sign_clone，根据 bundle 前缀判断 App 是否仍安装
CODE_SIGN_RULES=(
  "com.google.Chrome|Google Chrome|/Applications/Google Chrome.app"
  "com.google.Browser|Google Chrome|/Applications/Google Chrome.app"
  "org.chromium.Chromium|Chromium|/Applications/Chromium.app"
  "com.brave.Browser|Brave Browser|/Applications/Brave Browser.app"
)

# ── Xcode 缓存路径（~/Library/Developer 下）─────────────────────────────
# 格式: "相对于 ~/Library/Developer 的路径|显示名|阈值KB|提示语"
XCODE_CACHE_RULES=(
  "Xcode/DerivedData|DerivedData (编译缓存)|0|清除 DerivedData?"
  "Xcode/UserData/Previews|Previews 缓存|10240|清除 Xcode Previews 缓存?"
  "Xcode/Archives|Archives (旧归档)|10240|清除旧的 Xcode Archives? (如有发布需要请保留)"
)

# ── Glob 模式清理（匹配文件模式删除）────────────────────────────────────
# 格式: "目录路径|glob模式|显示名|阈值KB|提示语"
# 引擎会统计匹配 glob 的文件总大小，超过阈值时提示删除
GLOB_CACHE_RULES=(
  "\$HOME/Library/Containers/com.tencent.qq/Data/Library/Application Support/QQ/global/nt_data/Emoji/emoji-resource|*.zip|QQ 表情冗余 zip|1024|删除 QQ 表情已解压的 zip 包?"
  "\$HOME/Library/Containers/cn.com.10jqka.macstockPro/Data/Documents|cifox_trade*.log|同花顺交易日志|10240|清除同花顺交易日志? (不影响自选股等用户数据)"
)

# ── 多用户目录遍历清理 ──────────────────────────────────────────────────
# 格式: "用户基础路径|用户通配符|子路径1,子路径2|显示名|阈值KB|提示语"
# 引擎遍历 基础路径/通配符/ 下的每个用户目录，清理指定子路径
MULTI_USER_RULES=(
  "\$HOME/Library/Containers/com.tencent.qqexdoc/Data/Library/Application Support/QQEX/users|*|Service Worker,Cache|腾讯文档 SW+缓存|10240|清除腾讯文档 Service Worker 和浏览器缓存?"
)

# ── 独立模块路径配置 ────────────────────────────────────────────────────
# 这些模块有自己的 section，路径可在此覆盖
LOGS_DIR="\$HOME/Library/Logs"
LOGS_THRESHOLD=5120
CRASH_DIR="\$HOME/Library/Application Support/CrashReporter"
CRASH_THRESHOLD=1024

# ── 不活跃项目编译产物扫描 ───────────────────────────────────────────────

# 代码根目录（脚本会扫描其一级子目录）
STALE_PROJECT_DIR="\$HOME/Code"
# 不活跃天数阈值
STALE_DAYS=10

# 编译产物定义: "目录名|显示名"
STALE_ARTIFACT_DEFS=(
  "node_modules|node_modules (npm/pnpm 依赖)"
  "dist|dist (构建产物)"
  "out|out (静态导出)"
  "build|build (构建目录)"
  ".next|.next (Next.js)"
  ".nuxt|.nuxt (Nuxt.js)"
  ".turbo|.turbo (Turborepo)"
  ".venv|.venv (Python 虚拟环境)"
  "venv|venv (Python 虚拟环境)"
  "Pods|Pods (CocoaPods)"
  "DerivedData|DerivedData (Xcode)"
  ".build|.build (Swift PM)"
  ".swiftpm|.swiftpm (Swift PM 缓存)"
  "coverage|coverage (测试覆盖率)"
  ".cache|.cache (通用缓存)"
  "__pycache__|__pycache__ (Python)"
)

# ── 自动发现参数 ─────────────────────────────────────────────────────────

# 自动发现最小报告阈值 (KB)
DISCOVER_MIN_SIZE=5120

# 通用缓存子目录名模式（用于 find -name 匹配）
DISCOVER_CACHE_NAMES=(
  cache Cache CacheStorage CachedData GPUCache ShaderCache
  "Code Cache" DawnGraphiteCache DawnWebGPUCache
  logs Logs log Log
  tmp temp Temp
  "Service Worker"
  blob_storage
)

# ── 手动操作提醒（SIP 保护或需 GUI 操作的条目）────────────────────────────
# 格式: "路径|显示名|预估大小|操作指引|原理说明"
# 脚本只展示不删除，由用户手动操作
MANUAL_REMINDERS=()
