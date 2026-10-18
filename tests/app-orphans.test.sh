#!/usr/bin/env bash
# app-orphans.sh 回归测试
#
# 全程使用 fixture，不读取真实 ~/Library、不调用 lsregister、不写真实 data.txt。
# 覆盖六类判定与一条安全不变式：
#   1. 存活 bundle 的目录必须被声明集消掉（不能出现在报告里）
#   2. LaunchServices 失效记录 → A
#   3. 无卸载证据但有残留 → B
#   4. 静默期内的候选 → C（不因证据强就绕过）
#   5. 组件/助程序（helper）→ C，不单独立案
#   6. 同 TeamID 共享容器 → A 但标 stale-shared，且不进入 --emit-rules
#   7. 声明集为空 → 全部 C 且标注 no-claim（宁可报零，不可报猜）
#
# 用法: ./tests/app-orphans.test.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT_DIR="$(cd "$HERE/.." && pwd)"
SCRIPT="$ROOT_DIR/app-orphans.sh"
LSDUMP="$HERE/fixtures/ls-dump.txt"

FX="$(mktemp -d "${TMPDIR:-/tmp}/orphan-test.XXXXXX")"
trap 'rm -rf "$FX"' EXIT

TSV="$FX/out.tsv"
DATA="$FX/data.txt"

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

# ── fixture 目录树 ───────────────────────────────────────────────────────────
LIB="$FX/Library"
OLD=$(date -v-60d +%Y%m%d%H%M)

mkdir -p "$LIB/Containers/com.live.app" \
         "$LIB/Containers/com.gone.app" \
         "$LIB/Containers/com.recent.app" \
         "$LIB/Containers/com.uncertain.app" \
         "$LIB/Containers/com.apple.foo" \
         "$LIB/Containers/com.live.app.helper" \
         "$LIB/Containers/com.vanished.app.helper" \
         "$LIB/Preferences" \
         "$LIB/Caches/com.gone.app" \
         "$LIB/Group Containers/TEAMAAAAAA.com.gone.app" \
         "$LIB/Group Containers/OTHERB1234.com.shared.app"
: > "$LIB/Preferences/com.gone.app.plist"

# 让「已卸载」的候选都老于静默期，只留 com.recent.app 是新的
find "$LIB" -maxdepth 2 -mindepth 1 ! -name 'com.recent.app' -exec touch -t "$OLD" {} +
touch "$LIB/Containers/com.recent.app"

run_audit() {
  ORPHAN_LIBRARY_OVERRIDE="$LIB" \
  ORPHAN_LS_DUMP="$LSDUMP" \
  ORPHAN_SKIP_APP_SCAN=1 \
  ORPHAN_QUIET_DAYS=30 \
  ORPHAN_MIN_KB=0 \
  ORPHAN_DATA_FILE="$DATA" \
  ORPHAN_REPORT_DIR="$FX/reports" \
  "$SCRIPT" --tsv "$TSV" "$@" >/dev/null 2>&1
}

# 查某 id 在某根下的置信度
conf_of() {
  awk -F'\t' -v id="$1" -v loc="$2" '$3 == id && $4 == loc { print $1; exit }' "$TSV"
}

ev_of() {
  awk -F'\t' -v id="$1" -v loc="$2" '$3 == id && $4 == loc { print $5; exit }' "$TSV"
}

echo "app-orphans.sh 回归测试"
echo "─────────────────────────────"

run_audit

# ── 用例 1: 声明集消解 ──
check "存活 bundle 的容器不出现"        "0" "$(awk -F'\t' '$3=="com.live.app"' "$TSV" | wc -l | tr -d ' ')"
check "登录项等普通文件也被覆盖"        "1" "$(awk -F'\t' '$3=="com.gone.app" && $4=="Preferences"' "$TSV" | wc -l | tr -d ' ')"

# ── 用例 2/3/4: A / B / 静默期 ──
check "失效注册 → A（Containers）"      "A" "$(conf_of com.gone.app Containers)"
check "失效注册 → A（Caches）"          "A" "$(conf_of com.gone.app Caches)"
check "无证据残留 → B"                  "B" "$(conf_of com.uncertain.app Containers)"
check "静默期内的强证据仍降 C"          "C" "$(conf_of com.recent.app Containers)"
check "近改原因正确"                    "recent" "$(ev_of com.recent.app Containers)"

# ── 用例 5/6: 系统身份 / 组件 / 共享容器 ──
check "com.apple.* → C"                 "C" "$(conf_of com.apple.foo Containers)"
check "helper 组件 → C"                 "C" "$(conf_of com.vanished.app.helper Containers)"
check "同 TeamID 共享容器 → A"          "A" "$(conf_of TEAMAAAAAA.com.gone.app 'Group Containers')"
check "同 TeamID 共享容器标记 shared"   "stale-shared" "$(ev_of TEAMAAAAAA.com.gone.app 'Group Containers')"
check "未知 TeamID 前缀 → B"            "B" "$(conf_of OTHERB1234.com.shared.app 'Group Containers')"

# ── 用例 7: --emit-rules 只写非共享 A ──
run_audit --emit-rules
check "emit 写入 gone.app"              "1" "$(awk '/^  "com.gone.app[|]/{n++} END{print n+0}' "$DATA")"
check "emit 不写共享容器"               "0" "$(awk '/TEAMAAAAAA/{n++} END{print n+0}' "$DATA")"
check "emit 不写 C 级"                  "0" "$(awk '/com.recent.app/{n++} END{print n+0}' "$DATA")"
check "emit 合并多路径（3 条）"         "3" "$(grep '^  "com.gone.app|' "$DATA" | tr ',' '\n' | wc -l | tr -d ' ')"

# ── 用例 8: 声明集不可用 → 全 C ──
rm -f "$TSV"
ORPHAN_LIBRARY_OVERRIDE="$LIB" ORPHAN_SKIP_APP_SCAN=1 ORPHAN_REPORT_DIR="$FX/reports" \
  "$SCRIPT" --tsv "$TSV" --no-ls >/dev/null 2>&1
check "声明集为空时无 A"                "0" "$(awk -F'\t' '$1=="A"' "$TSV" | wc -l | tr -d ' ')"
check "声明集为空时标注 no-claim"       "1" "$(awk -F'\t' '$5=="no-claim"' "$TSV" | head -1 | grep -c no-claim)"

echo "─────────────────────────────"
printf "通过 %d / 失败 %d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
