#!/usr/bin/env bash
# ============================================================================
#  disk-8020.sh — 尺寸优先的 80/20 磁盘占用分析（发现层通道 B）
#
#  定位: 与 scan-discover.sh 互补。后者是「pattern-first」——在固定路径族里按
#        目录名找未覆盖缓存；本脚本是「size-first」——不预设路径，按占用排序
#        自顶向下收敛，因此能看见 scan-discover 结构上看不到的地方
#        （/System/Library/AssetsV2、/Library/Developer、/private/var/folders、
#         /opt，以及「大文件而非缓存目录」这一类）。
#
#  契约: 严格只读。不删除任何文件，不写 ~/.mac-cleanup/data.txt，
#        不参与清理流程，不接受 -y。输出是「该看哪里」，不是「能不能删」。
#
#  用法:
#    ./scripts/disk-8020.sh                       # 扫默认数据卷并分析
#    ./scripts/disk-8020.sh ~/Library             # 指定目录
#    ./scripts/disk-8020.sh --dump /tmp/x.tsv     # 复用已有 du 输出，跳过扫描
#
#  环境变量: THRESHOLD(0.8) MIN_MB(100) MAX_DEPTH(6) MAX_KIDS(8) MIN_PCT(1)
# ============================================================================

set -u

CACHE_DIR="$HOME/.mac-cleanup/cache"
DEFAULT_DUMP="$CACHE_DIR/duscan.tsv"
DEFAULT_TARGET="/System/Volumes/Data"

THRESHOLD="${THRESHOLD:-0.8}"
MIN_MB="${MIN_MB:-100}"
MAX_DEPTH="${MAX_DEPTH:-6}"
MAX_KIDS="${MAX_KIDS:-8}"
MIN_PCT="${MIN_PCT:-1}"

usage() {
  cat <<'EOF'
用法: scripts/disk-8020.sh [选项] [路径]

  路径          要分析的目录，默认 /System/Volumes/Data
  --dump FILE   复用已有 du 输出，跳过扫描（重算约 9 秒）
  -h, --help    显示本帮助

环境变量:
  THRESHOLD     下钻阈值，默认 0.8（取累计占父目录 80% 的分支继续深入）
  MIN_MB        最小下钻单位，默认 100 MB
  MAX_DEPTH     最大深度，默认 6
  MAX_KIDS      每层最多展开项数，默认 8
  MIN_PCT       降噪下限（占整盘百分比），默认 1

示例:
  ./scripts/disk-8020.sh ~/Library
  MAX_DEPTH=8 MIN_PCT=0.5 ./scripts/disk-8020.sh
  ./scripts/disk-8020.sh --dump ~/.mac-cleanup/cache/duscan.tsv

只读工具：不删除文件，不写 ~/.mac-cleanup/data.txt，不参与清理流程。
EOF
}

TARGET=""
REUSE_DUMP=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dump)
      [ -n "${2:-}" ] || { echo "--dump 需要文件路径" >&2; exit 1; }
      REUSE_DUMP="$2"; shift 2 ;;
    --*) echo "未知参数: $1（-h 查看用法）" >&2; exit 1 ;;
    *)   TARGET="$1"; shift ;;
  esac
done

TARGET="${TARGET:-$DEFAULT_TARGET}"
TARGET="${TARGET%/}"
[ -n "$TARGET" ] || TARGET="/"

if [ "$TARGET" = "/" ]; then
  echo "提示: 分析 / 会因 APFS firmlink 重复计数，建议改用 /System/Volumes/Data" >&2
fi

if [ -z "$REUSE_DUMP" ]; then
  [ -d "$TARGET" ] || { echo "目录不存在: $TARGET" >&2; exit 1; }
  mkdir -p "$CACHE_DIR"

  # 物理路径：/tmp 之类是符号链接，du 输出的是解析后的路径，不解析会导致根不匹配
  TARGET_PHYS=$(cd "$TARGET" && pwd -P)

  # dump 按目标分名保存，避免分析子目录时覆盖整卷 dump
  if [ "$TARGET_PHYS" = "$DEFAULT_TARGET" ]; then
    DUMP_OUT="$DEFAULT_DUMP"
  else
    slug=$(printf '%s' "$TARGET_PHYS" | sed 's|^/||; s|/|_|g')
    DUMP_OUT="$CACHE_DIR/duscan-${slug}.tsv"
  fi

  echo "扫描 $TARGET_PHYS ..." >&2
  START=$(date +%s)
  du -xk "$TARGET_PHYS" > "$DUMP_OUT" 2>/dev/null || true
  END=$(date +%s)
  echo "扫描完成: 用时 $((END - START)) 秒，dump $(du -h "$DUMP_OUT" | cut -f1) -> $DUMP_OUT" >&2
  REUSE_DUMP="$DUMP_OUT"
else
  [ -s "$REUSE_DUMP" ] || { echo "dump 为空或不存在: $REUSE_DUMP" >&2; exit 1; }
  TARGET_PHYS=$(cd "$TARGET" 2>/dev/null && pwd -P) || TARGET_PHYS="$TARGET"
fi

awk -F'\t' -v ROOT="$TARGET_PHYS" -v TH="$THRESHOLD" -v MINMB="$MIN_MB" \
    -v MAXD="$MAX_DEPTH" -v MAXKIDS="$MAX_KIDS" -v MINPCT="$MIN_PCT" '
BEGIN { TH += 0; MINMB += 0; MAXD += 0; MAXKIDS += 0; MINPCT += 0; N = 0 }

{ N++; S[$2] = $1 + 0; P[N] = $2 }

END {
  if (N == 0) { print "无数据"; exit 1 }
  root_total = S[ROOT]
  if (root_total <= 0) {
    printf "根路径未出现在 du 输出中: %s\n", ROOT > "/dev/stderr"
    exit 1
  }

  printf "%s  %s  100.0%%\n", ROOT, human(root_total)
  walk(ROOT, "", "", 0, 0, root_total, root_total)

  printf "\n总计 %s   目录条目 %d 个\n", human(root_total), N
}

# KB -> 人类可读
function human(kb) {
  if (kb >= 1048576) return sprintf("%8.1f GB", kb / 1048576)
  if (kb >= 1024)    return sprintf("%8.1f MB", kb / 1024)
  return sprintf("%8.0f KB", kb)
}

# 递归下钻
# walk(目录, 显示名, 缩进, 是否末位, 层级, 本目录总量, 整盘总量
#      [, 以下均为局部变量])
# 注意: BWK awk 没有真正的局部变量，多余形参才是局部变量。
#       任何临时变量（含布尔标记、循环上界）漏声明都会变成全局，
#       递归返回后会覆盖父层状态 —— show / show_direct 都曾因此出错。
function walk(node, name, indent, last, depth, total, root_total,   cnt, i, j, tmp, kids, acc, cut, rest, sumall, folded, direct, pct, cindent, nm, show_direct, show, is_last) {

  if (depth > 0) {
    pct = (root_total > 0) ? total / root_total * 100 : 0
    printf "%s%s%s %s  %5.1f%%\n", indent, (last ? "└─ " : "├─ "), name, human(total), pct
  }

  if (depth >= MAXD || total < MINMB * 1024) return

  # 收集直接子目录
  cnt = 0
  for (i = 1; i <= N; i++) {
    if (P[i] == node) continue
    if (index(P[i], node "/") != 1) continue
    rest = substr(P[i], length(node) + 2)
    if (index(rest, "/") > 0) continue
    cnt++; kids[cnt] = P[i]
  }
  if (cnt == 0) return

  # 降序（子目录数通常 < 50，插入排序足够）
  for (i = 1; i <= cnt; i++)
    for (j = i + 1; j <= cnt; j++)
      if (S[kids[j]] > S[kids[i]]) { tmp = kids[i]; kids[i] = kids[j]; kids[j] = tmp }

  # 下钻截断：累计到阈值，同时受「每层上限」与「降噪下限」约束
  acc = 0; cut = 0
  for (i = 1; i <= cnt; i++) {
    if (i > MAXKIDS) break
    if (i > 1 && root_total > 0 && S[kids[i]] < root_total * MINPCT / 100) break
    cut = i
    acc += S[kids[i]]
    if (acc >= TH * total) break
  }
  if (cut < 1) cut = 1

  # 根层不受 80% 约束：所有高于降噪下限的分支都下钻
  if (depth == 0) {
    cut = 1
    for (i = 1; i <= cnt; i++) {
      if (i > MAXKIDS) break
      if (i > 1 && root_total > 0 && S[kids[i]] < root_total * MINPCT / 100) break
      cut = i
    }
  }

  # 展示数：根层全列，其余层与下钻数一致
  show = cut
  if (depth == 0) { show = cnt; if (show > 20) show = 20 }

  # 直属文件（不被任何子目录覆盖的部分）
  sumall = 0
  for (i = 1; i <= cnt; i++) sumall += S[kids[i]]
  direct = total - sumall
  show_direct = (direct > 0 && direct >= total * 0.05)

  # 未展示部分的合计
  folded = 0
  for (i = show + 1; i <= cnt; i++) folded += S[kids[i]]

  cindent = indent
  if (depth > 0) cindent = indent (last ? "   " : "│  ")

  for (i = 1; i <= show; i++) {
    nm = kids[i]; sub(/^.*\//, "", nm)
    is_last = (i == show && !show_direct && folded == 0)
    if (i <= cut) {
      walk(kids[i], nm, cindent, is_last, depth + 1, S[kids[i]], root_total)
    } else {
      # 只列出、不下钻（属于父目录末位 20%）
      printf "%s%s%s %s  %5.1f%%\n", cindent, (is_last ? "└─ " : "├─ "), nm, human(S[kids[i]]), (root_total > 0 ? S[kids[i]] / root_total * 100 : 0)
    }
  }

  if (show_direct) {
    pct = direct / total * 100
    printf "%s%s<直属文件> %s  %5.1f%%\n", cindent, (folded == 0 ? "└─ " : "├─ "), human(direct), pct
  }

  if (folded > 0) {
    pct = folded / total * 100
    printf "%s└─ (折叠 %d 项) %s  %5.1f%%\n", cindent, cnt - show, human(folded), pct
  }
}
' "$REUSE_DUMP"
