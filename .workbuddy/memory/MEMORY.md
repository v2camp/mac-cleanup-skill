# mac-cleanup-skill — 项目长期约定

## 版本控制
- 仓库：`git@github.com:v2camp/mac-cleanup-skill.git`（private，分支 main）。
  2026-10-18 之前本目录**不是 git 仓库**，skill 由 `userImport` 上传安装、无上游可参照。
- 本机 `gh` 需加 `env -u GITHUB_TOKEN -u GH_TOKEN` 才能用（该环境变量是失效 token，会遮蔽 keyring 凭据）。

## 部署与同步
- `~/.workbuddy/skills/mac-cleanup` 自 2026-10-18 17:19 起是**指向本仓库的符号链接**，改仓库即生效。
- 历史教训：此前它是**实目录副本**（inode 不同），导致「引擎 dry-run 删除 bug 已在仓库修复、
  用户侧仍跑旧版」的静默不一致。文档旧写的 `~/.agents/skills/mac-cleanup` 软链在本机从未存在过。
- 软链也会断，且平台对断链**静默忽略**（技能直接消失、无报错）。改完仍要
  `readlink` + `cd` 进去 `pwd -P` 确认解析到开发目录。
- 原实目录副本备份在 `~/.workbuddy/skills/.backup-mac-cleanup-20261018-1719`（含 `_user_meta.json`；
  符号链接型技能不需要该文件）。确认稳定后可删。

## 架构约定
- 三层职责不可混：数据轮（cleanup-data.sh = Tier1，~/.mac-cleanup/data.txt = Tier2）、
  代码轮（mac-cleanup.sh 引擎，18 模块）、发现层（三个通道）。
- 发现层三通道：A `scan-discover.sh` 是 pattern-first，可 `--apply` 写数据；
  B `disk-8020.sh` 是 size-first，**严格只读，永不写 data.txt**；
  C `app-orphans.sh` 是 identity-first（v1.4），只读，仅 `--emit-rules` 写 A 级规则。
- 铁律：尺寸 ≠ 可删。判定依据是「是否可重建」，不是「占多大」。
- 第二铁律（通道 C）：声明集不完整时必须输出零结果，不能给猜出来的清单。

## 孤儿判定（v1.4）
- 判据是 bundle id 是否有主，不是目录名也不是显示名。
- 声明集 = LaunchServices 存活记录 ∪ /Applications 的 CFBundleIdentifier ∪ com.apple.*。
  `lsregister -dump` 中带 `Bundle node not found on disk` 的块即「失效记录」，是唯一的卸载证据。
- 分级：A 有失效证据 / B 仅目录残留 / C 系统身份·相关 bundle·helper 组件·同 TeamID 共享容器·静默期内改写。
- 静默期 A 级 7 天、B 级 30 天；证据强度不同，闸门不能一刀切（曾因统一 30 天漏掉 1.8 GB）。
- Group Containers 必须按 TeamID 归因：`<10 位 TeamID>.xxx` 且该 Team 有存活 bundle → C，
  有证据也只在标 `stale-shared`、不 emit（曾把 Microsoft To Do 的共享容器报成孤儿）。
- `--emit-rules` 只能 `+=`，绝不能写 `ORPHAN_ID_RULES=()`（那是重置，会静默清空上次的规则）。

## 引擎安全约定
- `confirm()` 在 DRY_RUN 下恒返回 0，**不能**用它决定外部 CLI 是否执行。
  不可逆 CLI（brew / pnpm / simctl / docker）必须走 `run_cli "描述" cmd...`。
- 新增模块的检查清单：语法 + 回归测试 + PATH 探针 + 同步 + 在已安装副本上跑 dry-run。

## 测试
- `./tests/disk-8020.test.sh`（12 项断言）。覆盖两类历史缺陷：
  递归状态污染（awk 局部变量漏声明）、根层被 80% 截断。
- `./tests/app-orphans.test.sh`（18 项断言）。纯 fixture，靠
  `ORPHAN_LIBRARY_OVERRIDE` / `ORPHAN_LS_DUMP` / `ORPHAN_SKIP_APP_SCAN` / `ORPHAN_DATA_FILE`
  隔离真实环境；覆盖 A/B/C 分级、TeamID 共享容器、emit 去重、声明集为空报零。
- BWK awk 无真正的局部变量，**多余形参才是局部变量**；任何临时变量漏声明都会在递归返回时
  污染父层（`show` 改写过父层循环上界、`show_direct` 导致父层误报直属文件）。

## 数据层写作规范
- `~/.mac-cleanup/data.txt` 里用 `\$HOME/...`（转义），与 Tier1 保持一致。
- 新增 `DEDUP_*` 时注意 `set -u`：该变量由 Tier1 预声明，data.txt 里只能 `+=` 式拼接。
