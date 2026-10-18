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
  代码轮（mac-cleanup.sh 引擎，17 模块）、发现层（两个通道）。
- 发现层双通道：A `scan-discover.sh` 是 pattern-first，可 `--apply` 写数据；
  B `disk-8020.sh` 是 size-first，**严格只读，永不写 data.txt**。
- 铁律：尺寸 ≠ 可删。判定依据是「是否可重建」，不是「占多大」。

## 引擎安全约定
- `confirm()` 在 DRY_RUN 下恒返回 0，**不能**用它决定外部 CLI 是否执行。
  不可逆 CLI（brew / pnpm / simctl / docker）必须走 `run_cli "描述" cmd...`。
- 新增模块的检查清单：语法 + 回归测试 + PATH 探针 + 同步 + 在已安装副本上跑 dry-run。

## 测试
- `./tests/disk-8020.test.sh`（12 项断言）。覆盖两类历史缺陷：
  递归状态污染（awk 局部变量漏声明）、根层被 80% 截断。
- BWK awk 无真正的局部变量，**多余形参才是局部变量**；任何临时变量漏声明都会在递归返回时
  污染父层（`show` 改写过父层循环上界、`show_direct` 导致父层误报直属文件）。

## 数据层写作规范
- `~/.mac-cleanup/data.txt` 里用 `\$HOME/...`（转义），与 Tier1 保持一致。
- 新增 `DEDUP_*` 时注意 `set -u`：该变量由 Tier1 预声明，data.txt 里只能 `+=` 式拼接。
