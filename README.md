# mac-cleanup

macOS 磁盘清理技能。入口脚本负责执行清理，`scripts/` 中的工具负责数据维护与盲区发现。

## 目录结构

```
mac-cleanup.sh          # 唯一入口：清理引擎 + --analyze / --discover 直通
scripts/
  cleanup-data.sh       # Tier 1 数据层：技能内置的稳定清理规则
  scan-discover.sh      # 发现通道 A：按目录名模式扫描未覆盖缓存
  disk-8020.sh          # 发现通道 B：按占用大小做 80/20 分析（严格只读）
  app-orphans.sh        # 发现通道 C：按 bundle id 审计已卸载 App 残留（只读）
tests/
  disk-8020.test.sh     # 通道 B 回归测试
  app-orphans.test.sh   # 通道 C 回归测试
  fixtures/             # 测试用固定样本
docs/                   # 调研与设计记录
SKILL.md                # 技能说明（agent 读取）
script-reference.md     # 脚本架构、数据格式与迭代清单
```

## 快速开始

所有命令在本技能目录下执行。

```bash
./mac-cleanup.sh -n          # 预览（dry-run，不做任何操作）
./mac-cleanup.sh             # 交互模式，逐项确认
./mac-cleanup.sh -y          # 全部执行，不再逐项询问
./mac-cleanup.sh --analyze   # 80/20 占用分析（只读）
./mac-cleanup.sh --analyze ~/Library
```

## 发现与数据维护

技能采用两级数据：`scripts/cleanup-data.sh` 是随仓库发布的稳定规则（Tier 1），
`~/.mac-cleanup/data.txt` 是本机发现后追加的用户数据（Tier 2）。运行时先加载 Tier 1，再加载 Tier 2。

**agent 与用户只写 `~/.mac-cleanup/data.txt`，不修改技能目录中的任何文件。**

```bash
# 通道 A：按目录名找未覆盖的缓存，--apply 写入 Tier 2
./scripts/scan-discover.sh
./scripts/scan-discover.sh --apply

# 通道 B：按占用大小找结构性盲区，只读，可复用已有扫描结果
./scripts/disk-8020.sh
./scripts/disk-8020.sh --dump ~/.mac-cleanup/cache/duscan.tsv

# 通道 C：审计已卸载 App 的孤儿残留，--emit-rules 只写 A 级证据
./scripts/app-orphans.sh
./scripts/app-orphans.sh --min-conf A
./scripts/app-orphans.sh --emit-rules
```

三个通道的判据、范围与强弱项对比见 [script-reference.md](script-reference.md)。

## 安全约定

- 所有清理路径使用 `$HOME`，不使用绝对路径。
- 所有模式都支持 `-n` dry-run；`disk-8020.sh` 与 `app-orphans.sh` 本身严格只读。
- 判定标准是「是否可重建」，不是「占多少空间」。大文件不等于可删。
- 声明集不完整时输出零结果：宁可报「零孤儿」，不给猜出来的清单。
- 删除孤儿数据走废纸篓（`safe_remove`），Docker prune 等不可逆操作需要二次确认。

## 测试

```bash
./tests/disk-8020.test.sh    # 12 项断言：递归状态污染、根层截断
./tests/app-orphans.test.sh  # 18 项断言：分级判定、声明集为空必须报零
```

修改任一脚本后，至少跑一遍 `bash -n` 与上述两个回归测试。

## 迭代规则

| 变更 | 改哪里 |
|------|--------|
| 发现新的缓存目录 | `~/.mac-cleanup/data.txt` |
| 发现孤儿残留 | `~/.mac-cleanup/data.txt` 的 `ORPHAN_ID_RULES`（由 `--emit-rules` 生成） |
| 沉淀稳定规则 | `scripts/cleanup-data.sh` |
| 新增模块类型 / 执行逻辑 | `mac-cleanup.sh` |
| 调整工作流 | `SKILL.md` |

完整清单见 [script-reference.md](script-reference.md)。
