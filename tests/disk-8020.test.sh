#!/usr/bin/env bash
# disk-8020.sh 回归测试
#
# 覆盖三个曾经真实出错的地方：
#   1. 父层循环上界被递归调用改写（show 未声明为局部变量 → 兄弟节点消失）
#   2. 布尔标记被递归覆盖（show_direct 未声明为局部变量 → 父层误报直属文件）
#   3. 根层 80% 截断（private / Library 等顶层分支被折叠掉）
#
# 用法: ./tests/disk-8020.test.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT_DIR="$(cd "$HERE/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/disk-8020.sh"
FIXTURE="$HERE/fixtures/tree.tsv"

PASS=0
FAIL=0

check() {
  local desc="$1" expect="$2" actual="$3"
  if [ "$expect" = "$actual" ]; then
    PASS=$((PASS + 1))
    printf "  \033[0;32m✓\033[0m %s\n" "$desc"
  else
    FAIL=$((FAIL + 1))
    printf "  \033[0;31m✗\033[0m %s (期望 %s，实际 %s)\n" "$desc" "$expect" "$actual"
  fi
}

echo "disk-8020.sh 回归测试"
echo "─────────────────────────────"

# ── 用例 1: 默认阈值 0.8 ──
out=$(MAX_DEPTH=5 MIN_MB=0 MIN_PCT=0 "$SCRIPT" --dump "$FIXTURE" /t 2>/dev/null)

check "根节点总额正确"            "1" "$(printf '%s\n' "$out" | grep -c '^/t ')"
check "a 分支展开"                "1" "$(printf '%s\n' "$out" | grep -c '├─ a ')"
check "b 分支存在"                "1" "$(printf '%s\n' "$out" | grep -c '├─ b ')"
check "c 分支存在（父层循环未被子调用截断）" "1" "$(printf '%s\n' "$out" | grep -c '├─ c ')"
check "d 分支存在（末位 20% 仅列出）"        "1" "$(printf '%s\n' "$out" | grep -c '└─ d ')"
check "d 未被下钻（无子节点）"    "0" "$(printf '%s\n' "$out" | grep -c '└─ x ')"
check "直属文件仅 a 一处"         "1" "$(printf '%s\n' "$out" | grep -c '<直属文件>')"
check "默认阈值下无折叠行"        "0" "$(printf '%s\n' "$out" | grep -c '折叠')"

# ── 用例 2: 阈值 0.5，应出现折叠（根层不受阈值约束，折叠出现在子层）──
out2=$(THRESHOLD=0.5 MAX_DEPTH=5 MIN_MB=0 MIN_PCT=0 "$SCRIPT" --dump "$FIXTURE" /t 2>/dev/null)
check "低阈值触发折叠"            "1" "$(printf '%s\n' "$out2" | grep -c '折叠')"
check "低阈值下根层仍全列"        "1" "$(printf '%s\n' "$out2" | grep -c '├─ b ')"

# ── 用例 2b: 根层不受 80% 约束（顶层 private / Library 曾被折叠掉）──
out3=$(THRESHOLD=0.01 MIN_MB=0 MIN_PCT=0 "$SCRIPT" --dump "$FIXTURE" /t 2>/dev/null)
check "极小阈值下根层仍无折叠"    "0" "$(printf '%s\n' "$out3" | grep -c '^└─ (折叠')"

# ── 用例 3: 参数校验 ──
"$SCRIPT" --dump /nonexistent.tsv /t >/dev/null 2>&1
check "缺失 dump 返回非零"        "1" "$?"

echo "─────────────────────────────"
printf "通过 %d / 失败 %d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
