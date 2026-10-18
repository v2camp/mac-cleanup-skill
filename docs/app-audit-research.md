# macOS 应用审计与残留清理：成熟方法调研

> 调研日期：2026-10-18 ｜ 实测环境：macOS 26.1 (Tahoe) / Apple Silicon
> 目的：为 mac-cleanup skill 的「应用缓存 / 孤儿残留」能力选型，判断哪些方法成熟可用、哪些是营销话术。

## 0. 核心结论

macOS **没有**「应用安装数据库」，也没有卸载契约。Apple 官方立场只有一句：优先用厂商卸载器，否则把 App 拖进废纸篓（[support.apple.com/102610](https://support.apple.com/en-ng/102610)）。因此四个问题必须用四套不同的证据源回答，任何单一命令都不成立。

成熟做法可归纳为四层流水线：

```
多源证据（谁曾存在 / 谁还在） → 身份归因（bundle id 优先，名字仅在受控范围兜底）
  → 声明减法（候选 − 现存声明 = 孤儿候选） → 回收站优先 + 人工复核
```

其中「声明减法 + 静默期 + 部分扫描即零结果」是区分专业工具与营销工具的分水岭（Mole 官方方法论、Pearcleaner 三档灵敏度均体现同一原则）。

---

## 1. 应用安装历史：五类证据，各自只回答一半问题

| 证据源 | 命令 | 能回答 | 覆盖范围 | 本机实测 | 盲区 |
|---|---|---|---|---|---|
| LaunchServices 注册库 | `lsregister -dump` | 曾注册过哪些 bundle、路径、TeamID | 全量（含嵌套 helper / 框架内 App） | 797 条记录 / 23 MB / **3.1 s** | 只有「注册过」，无时间；更新器与助程序制造大量噪音 |
| 系统应用清单 | `system_profiler SPApplicationsDataType -json` | 名称、版本、路径、`obtained_from`、`lastModified`、签名链 | Spotlight/系统可见的全部 App | 365 项 | **无安装日期、无最后使用时间** |
| pkg 收据 | `pkgutil --pkgs` / `--pkg-info` / `--files` | 包 ID、版本、**精确安装时间**、**精确文件清单** | 仅 Installer 安装的 pkg | 114 个收据 | 拖拽安装、App Store、Cask 全部无收据；收据不随 App 删除而消失 |
| 安装日志 | `/private/var/log/install.log`、`softwareupdate --history --all` | pkg/系统更新流水与时间线 | Installer + 系统更新 | 2.3 MB，16 条更新记录 | 有轮转；不含拖拽安装 |
| Spotlight 元数据 | `mdls -name kMDItemDateAdded -name kMDItemLastUsedDate` | 首次被索引时间（≈安装时间）、最后使用 | 所有被索引的 .app | Safari：DateAdded 2026-08-12 | 更新会重置时间；索引关闭即失效 |
| Homebrew | `brew list --cask` + `Caskroom/<token>/.metadata` | Cask 安装清单与版本目录 mtime | 仅 Homebrew | 7 个 cask | 不覆盖普通 App |
| App Store | `find /Applications -path '*Contents/_MASReceipt/receipt'`、`mas list` | 是否 MAS 来源 | 仅 MAS | 12 个 | 无安装时间 |
| 隔离事件库 | `sqlite3 ~/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2` | 下载时间、下载 Agent、来源 URL | 走 Gatekeeper 的下载 | **仅 7 行** | URL 列常为 NULL；curl/brew 不写；**不可作可靠来源** |
| 使用度数据库 | `knowledgeC.db`（CoreDuet / 屏幕使用时间） | 真实使用时长与频次 | 系统级 | `Operation not permitted`（需 sudo + 完全磁盘访问） | 权限门槛高，非安装证据 |

**结论：**
- 问「什么时候装的」→ 只有 `pkgutil --pkg-info` 是**精确**答案，其余都是近似（Spotlight DateAdded、Caskroom mtime）。
- 问「从哪装的」→ `obtained_from`（apple / mac_app_store / identified_developer / unknown）最稳定。
- 问「还常用吗」→ `kMDItemLastUsedDate` 会被更新刷新，Jamf 社区明确指出不可靠；要准确只能读 knowledgeC。
- 问「装了又删了什么」→ **只有 LaunchServices 失效记录 + `.Trash` 里的 .app 能给出直接证据**（见 §6）。

---

## 2. 应用常用目录：标准 17 类，按「可重建性」分三层

Pearcleaner 源码（`Locations.swift`）枚举的标准 Library 子目录，可作为完备性基线：

```
Application Scripts   Application Support   Caches        Containers
Group Containers      HTTPStorages          Internet Plug-Ins  LaunchAgents
LaunchDaemons         Logs                  Preferences   PreferencePanes
PrivilegedHelperTools Saved Application State  Services    WebKit
Extensions            Frameworks
```

系统级对应物：`/Library/{Application Support,Caches,LaunchAgents,LaunchDaemons,PrivilegedHelperTools,Preferences,Logs,Extensions}`、`/private/var/db/receipts`、`/usr/local/{bin,etc,opt,var}`。

按删除风险分三层（Mole 与 Apple 文档口径一致）：

| 层 | 路径 | 性质 | 处置 |
|---|---|---|---|
| L1 可重建 | `Caches/`、`Logs/`（含 DiagnosticReports）、`Saved Application State/`、`HTTPStorages/`、`WebKit/`、容器内 `Data/Library/Caches` | 系统可在 App 未运行时清除；App 必须能在缺失时正常工作（Apple Developer 文档） | 可自动清理，但需退出 App |
| L2 需复核 | `Application Support/`、`Containers/`、`Preferences/` | 含许可证、离线邮件、项目数据库、聊天记录 | 只报告，人工确认 |
| L3 共享勿动 | `Group Containers/`（`group.*`、`<TeamID>.*`）、厂商父目录（`~/Library/Application Support/Google`） | 同厂商多产品共用 | 无精确归属证明时一律不删 |

### 活体目录追踪（给新 App 建规则用）

静态目录表只能覆盖「标准位置」。要审计某个 App 真实写了哪些路径：

```bash
lsof -p <pid>                                   # 运行中进程的已打开文件
sudo fs_usage -w -f filesys | grep -i <AppName> # 实时文件系统调用（噪音大，需短时抓取）
sudo eslogger open close | jq 'select(.process.path|test("AppName"))'  # EndpointSecurity，macOS 10.15+
```

三者均为只读观测，适合用来「为某个 App 生成候选规则」，再由人工筛掉噪音（这三个工具本机均存在：`/usr/bin/{eslogger,fs_usage,opensnoop}`）。

---

## 3. 缓存清理：判据是「可重建契约」，不是目录名

Apple 的契约很明确：Caches 目录存「App 运行不必需、但可提升性能」的数据，**系统可能在 App 未运行时清除它**，App 必须能自行重建（[Using the file system effectively](https://developer.apple.com/documentation/foundation/using-the-file-system-effectively)）。据此：

- 判据 = 「删掉后 App 能否自行重建」，而不是「目录叫 Cache」。
- 沙盒 App 的缓存有三处，容易漏：`~/Library/Containers/<id>/Data/Library/Caches`、`~/Library/Group Containers/<group>/Library/Caches`、`~/Library/Application Support/Caches`。
- 反模式：删整个 `~/Library/Caches`；按显示名匹配；不看 mtime；不先退出 App（会持续写入）。
- 代价必须提前告知：清缓存可能掉登录态、触发重新下载（按流量计费场景尤甚）、下次启动变慢。

**目录名无法证明可删**——这正是本 skill「尺寸 ≠ 可删」原则在缓存维度的同构结论。

---

## 4. 已删除应用的遗留文件：声明减法（claim subtraction）

这是唯一被成熟工具共同采用的算法。要点是**先算出「谁还活着」，再从候选里减掉**，而不是「扫描到像孤儿的就报」。

```
1. 候选集 A = Library 下名字形如 bundle id 的目录/plist
             + 已知 App 名目录（受控范围，仅 strict 精确匹配）
2. 声明集 C = 现存 .app 的 CFBundleIdentifier（含 Contents/Frameworks 内嵌套 helper）
             ∪ 运行中进程（ps/lsof）
             ∪ LaunchServices 中「磁盘上仍存在」的 bundle
             ∪ pkg 收据声明的文件所属包
             ∪ com.apple.*（系统身份，永不算孤儿）
3. 孤儿候选 O = A − C
4. 过滤：mtime 静默期（如 30 天）内改写过的一律抑制
5. 拒绝清单二次剔除（见下）
6. 若声明集构建不完整（超时、读不到的目录、无完全磁盘访问）→ O = ∅
```

第 6 条是关键安全不变式：**扫描不全时的正确结果是「零孤儿」，而不是「猜一份清单」**。

### 身份归因：bundle id 优先，名字只做兜底

- bundle id 跨改名/本地化稳定；显示名不稳定，且厂商父目录（`.../Application Support/Google`）会被同名子串误伤。
- Pearcleaner 的做法值得直接借鉴：三档灵敏度
  - `strict`：bundle id 全串包含 + App 名/路径名/字母名**精确相等**
  - `enhanced`：加入 bundle id 末两段、去尾部版本号（`Bartender 6` → `Bartender`）的包含匹配
  - `deep`：再加入厂商名、TeamID 的包含匹配
- 默认必须是 `strict`。放宽灵敏度等于放大误删面积。

### 拒绝清单（即使名字命中也不能删）

1. 同厂商仍安装的兄弟产品、Beta/渠道变体（`Foo Beta` 与 `Foo`）
2. 无精确归属的 `Group Containers`
3. `/Library` 下的 privileged helper、LaunchDaemons、receipts —— 只能由厂商卸载器处理
4. 用户文档（Library 之外）、AI 模型目录、聊天记录库
5. `com.apple.*` 身份下的任何目录

### 两种触发时机

- **事后审计**：App 已消失，只能靠「LS 失效记录 / 废纸篓里的 .app / 残留目录」反推。
- **入库即拦**：监听 `~/.Trash`，发现新 `.app` 就读其 Info.plist 身份并立刻给出残留复核面板（AppCleaner SmartDelete、Pearcleaner Sentinel 均为此设计）。设计约束：不自动删被拖入的 App 本体（Put Back 必须可用）、不对杀毒/MDM 类弹窗、自身卸载时一次性抑制。

---

## 5. 成熟工具对照

| 工具 | 形态 | 归因方式 | 能否处理「已删除 App 的遗留」 | 可借鉴 / 风险 |
|---|---|---|---|---|
| **Pearcleaner** | Swift/SwiftUI，source-available（fair-code），~11.7k star | 17 类标准目录 + 三档灵敏度 + 去版本号 + TeamID + Entitlements + Spotlight 补充查询（仅用户主目录，5 s 超时，上限 500 条） | 能（Orphaned File Search） | 全部走废纸篓 + Undo；Sentinel 监听废纸篓。工程实现最值得参考 |
| **AppCleaner** | 闭源免费 | LaunchServices + 已知路径，仅对「被选中的 App」工作 | **不能**（App 已删就无从下手） | SmartDelete 交互设计；轻量 |
| **Mole** | Go + shell，GPL-3.0，~63k star | 明确宣称 claim subtraction + 静默期 + 部分扫描即零 | 能 | 方法论文档质量最高。**风险：多数命令是永久删除**，仅 `mo analyze` 走废纸篓 |
| **CleanMyMac** | 闭源商业 | 未公开 | 能（Leftovers） | 「总能找到几十个」是营销指标的反模式，不宜作为设计目标 |
| **macOS 自带** | — | 无 | 无 | 只有「存储空间管理」按大小排序，无残留判定 |

---

## 6. 本机实测：证据链跑通的数字

在 macOS 26.1 上按上述流水线做了一次只读验证：

| 指标 | 数值 |
|---|---|
| LaunchServices bundle 记录 | 797 |
| 其中「Bundle node not found on disk」（fnfErr 失效注册） | **338 条 / 69 个唯一 identifier** |
| 失效 identifier 中「全盘无同名现存 bundle」 | 60 |
| 与 Library 路径交叉后命中的 identifier | 13，合计 **≈ 2.14 GB** |
| 其中最大一项 | `com.tencent.WeWorkMac` —— **1864 MB**（App 已不在 /Applications，容器与 4 个 Group Container 仍在） |
| 另一个直接证据 | `cn.trae.solo.app` → 路径指向 `~/.Trash/TRAE SOLO CN.app`，即「已拖入废纸篓」的实时证据 |

同时得到一个重要的**反例**，说明为什么必须做声明减法而不能做朴素差集：

- `~/Library/Containers` 有 **717** 个目录，而 `/Applications` + `/System/Applications` + CoreServices 的 bundle id 仅 **237** 个 → 朴素差集得到 **651 个「孤儿」**。
- 抽样看这 651 个：大量是 `com.apple.*` 系统代理、`*.IPCHelper`、`*.widget`、以及纯 UUID 命名的容器。
- **结论：用「顶层 .app 清单」做声明集，会产出 96% 的假阳性。** 声明集必须包含嵌套 helper、系统身份与运行中进程。

同时必须承认实测的局限：`WeWorkMac` 那 1.8 GB 是**候选**，不是**可删**——企业微信容器里可能含本地聊天记录与文件缓存，最终判定仍需人工确认。这正是 L2 层「只报告不自动删」的理由。

---

## 7. 对 mac-cleanup skill 的落地建议（v1.4 已实现）

### 现状差距

`ORPHAN_RULES` 当前判据是「`/Applications` 中无 `*关键字*` 匹配的 App → 标记孤儿」。这是**弱判据**：
- 误判：关键字子串会命中同厂商兄弟产品（`Google` 命中 Chrome 与 Drive）。
- 漏判：显示名与目录名不一致时（bundle id 命名目录）永远匹配不到。
- 无证据：不知道这个 App 是「从没装过」还是「装了又删了」。

### 建议新增只读审计模块 `app-orphans`（v1.4）

第一阶段只出报告、不动手；确认后再通过现有 `safe_remove` 走废纸篓。

数据层（Tier 1/2 均可覆盖）：

```bash
ORPHAN_QUIET_DAYS=30
ORPHAN_SCAN_ROOTS="$HOME/Library/Caches|$HOME/Library/Containers|$HOME/Library/Application Support|$HOME/Library/Group Containers|$HOME/Library/Preferences|$HOME/Library/Saved Application State|$HOME/Library/HTTPStorages|$HOME/Library/LaunchAgents"
ORPHAN_DENY_PREFIX="com.apple.|group.com.apple."
```

输出格式（TSV，便于人工复核与后续 `--apply`）：

```
置信度  证据            路径                                    大小KB  建议
A       ls-stale         ~/Library/Containers/com.x.y            1864704  review
B       dir-only         ~/Library/Caches/com.a.b                25600    safe_remove
C       shared-group     ~/Library/Group Containers/88L...z      —        skip
```

置信度定义：
- **A**：LaunchServices 有失效记录 + 全盘无同名现存 bundle + 静默期已达 → 可进 `safe_remove` 候选
- **B**：仅目录残留 + 静默期已达 + 名字为合法 bundle id 形态 → 只报告
- **C**：命中共享 Group Container / 厂商父目录 / `com.apple.*` → 永不建议删除

实现要点：
1. 声明集用「`lsregister -dump` 中无 fnfErr 的记录」+「SPApplicationsDataType 全量」+「全部 .app 内嵌 Info.plist」三者并集，避免 §6 的 96% 假阳性。
2. `lsregister -dump` 成本可接受：本机 3.1 s / 23 MB；结果可缓存到 `~/.mac-cleanup/cache/ls-bundles.tsv`，按 DB mtime 失效。
3. 读不到 `~/Library/Containers` 时（无完全磁盘访问）必须显式告警并**输出零结果**，不能输出半盲清单。
4. macOS 26 起 `lsregister -kill` 已移除；只用 `-dump`（只读）与 `-gc`（垃圾回收），不要用 `-delete`（要求重启且会被立即重建）。
5. 与现有 `ORPHAN_RULES` 并存：旧规则保留为「已知 App 的显式规则」，新模块负责「未知 App 的发现」。

---

## 8. 实现记录（v1.4.0，2026-10-18）

已落地三个文件：

| 文件 | 角色 |
|---|---|
| `app-orphans.sh` | 发现通道 C：声明减法审计，严格只读；`--emit-rules` / `--verify` 两个出口 |
| `mac-cleanup.sh` 模块 18 `cleanup_orphan_ids` | 消费 `ORPHAN_ID_RULES`，执行前二次核验，`safe_remove`（废纸篓） |
| `tests/app-orphans.test.sh` | 18 项断言，纯 fixture，不读取真实 Library |

### 实现过程中被实测推翻的三个设计

1. **静默期不能一刀切。** 初版对所有候选统一 30 天，结果 `com.tencent.WeWorkMac`
   （1.8 GB，mtime 17 天前）被降级为 C，直接漏掉最大的目标。改为：A 级（有失效注册）
   用 7 天，B 级（仅目录）保留 30 天。证据强度不同，闸门就该不同。

2. **Group Containers 必须按 TeamID 归因，不能按名字。** 初版把
   `UBF8T346G9.Office`（132 MB）报成孤儿，而本机装着 Microsoft To Do（同属 UBF8T346G9）。
   现在的规则：`<10 位 TeamID>.xxx` 若该 TeamID 还有存活 bundle，则无卸载证据的一律 C；
   即使有证据也标 `stale-shared`，不进入 `--emit-rules`。

3. **`--emit-rules` 不能每次写 `ORPHAN_ID_RULES=()`。** 那是重置而非追加，
   第二次审计会静默清空前一次的规则。改为只用 `+=`，且按 id 去重。

### 本机实测结果（审计 → 规则 → 引擎）

```
声明集 401 个 bundle id ／ 候选 2257 条
A 级 11 项 2,149 MB    B 级 101 项 59.8 MB    C 级 2,033 项
→ --emit-rules: 2 条（WeCom 1.8 GB + wwmapp 324 MB）
→ ./mac-cleanup.sh -n: 正确识别、正确走 [dry-run] 分支，未产生任何删除
```

误报清单（全部落在 C，未进入候选）：`com.apple.*` 系统代理、`*.IPCHelper`、
`*.widget`、UUID 命名容器、同 TeamID 共享容器。

未覆盖（有意为之）：`~/Library/Application Support` 下的非 id 命名目录（如 `Figma`），
因为只能靠名字匹配，误伤率过高。这类仍由 `ORPHAN_RULES` 的显式规则处理。

## 9. 主要来源

- Apple：删除/卸载 App 官方说明 — https://support.apple.com/en-ng/102610
- Apple：缓存目录契约 — https://developer.apple.com/documentation/foundation/using-the-file-system-effectively
- Mole：已删除 App 的残留判定方法论（claim subtraction / 静默期 / 部分扫描即零） — https://mole.fit/blog/how-to-remove-leftover-files-after-uninstalling-mac-apps
- Pearcleaner 源码：`Locations.swift`（标准目录枚举）、`AppPathsFetch.swift`（三档灵敏度匹配） — https://github.com/alienator88/Pearcleaner
- Pearcleaner 官方功能说明 — https://pearcleaner.com/
- Eclectic Light：`lsregister` / `lsappinfo` 在 Sequoia/Tahoe 的可用性与 `-kill` 移除 — https://eclecticlight.co/2026/08/04/fix-launchservices-problems-with-command-tools/
- Apple 平台部署指南：`sfltool dumpbtm` 与后台项审计 — https://support.apple.com/guide/deployment/depdca572563
- Eclectic Light：BTM dump 字段与 `attributions.plist` — https://eclecticlight.co/2026/02/20/in-the-background-identification/
- pkg 收据结构（`pkgutil` / `lsbom` / `/var/db/receipts`） — https://nylle.com/blog/understanding-package-receipts-on-macos/
- Quarantine 数据库字段与局限 — https://0xmachos.github.io/2019-02-01-Quarantine-Intro/
- Jamf 社区：`kMDItemDateAdded` / `kMDItemLastUsedDate` 的可靠性讨论 — https://community.jamf.com/t5/jamf-pro/capturing-the-install-date-of-apps/m-p/224028
