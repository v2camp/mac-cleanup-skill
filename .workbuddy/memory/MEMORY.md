# mac-cleanup-skill — 项目长期约定

## 部署与同步（最容易踩的坑）
- 开发目录 `/Users/wanghui/Code/mac-cleanup-skill` 与已安装目录 `~/.workbuddy/skills/mac-cleanup`
  是**两份独立副本**（2026-10-18 实测 inode 不同，非符号链接）。`script-reference.md` 旧文写的
  `~/.agents/skills/mac-cleanup -> ~/Code/mac-cleanup-skill` 符号链接在本机不成立。
- 后果：改仓库 ≠ 生效。曾出现「引擎 dry-run 删除 bug 已在仓库修复、用户侧仍跑旧版」的静默不一致。
- 每次改动后必须 `cp` + `diff -q` 校验，详见 `script-reference.md §同步机制`。

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
