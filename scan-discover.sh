#!/usr/bin/env bash
# ============================================================================
#  macOS 缓存自动发现扫描器 (两级数据层版)
#
#  读取:
#    Tier 1: cleanup-data.sh (skill 目录，开发者维护)
#    Tier 2: ~/.mac-cleanup/data.txt (用户本地，自动追加)
#
#  写入:
#    --apply 模式会将新发现追加到 ~/.mac-cleanup/data.txt
#    不修改 skill 目录中的任何文件
#
#  用法:
#    ./scan-discover.sh           # 人类可读报告
#    ./scan-discover.sh --patch   # 输出可追加的 bash 片段（不写入）
#    ./scan-discover.sh --apply   # 扫描并追加到 ~/.mac-cleanup/data.txt
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_FILE="$SCRIPT_DIR/cleanup-data.sh"

USER_DATA_DIR="$HOME/.mac-cleanup"
USER_DATA_FILE="$USER_DATA_DIR/data.txt"

# 加载 Tier 1 (skill 数据)
if [ -f "$DATA_FILE" ]; then
  source "$DATA_FILE"
else
  echo "错误: 找不到 skill 数据层 $DATA_FILE" >&2
  exit 1
fi

# 加载 Tier 2 (用户数据，追加到同一数组)
if [ -f "$USER_DATA_FILE" ]; then
  source "$USER_DATA_FILE"
fi

MODE="${1:-report}"  # report | patch | apply

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

size_of() {
  local path="$1"
  if [ -e "$path" ]; then
    local raw
    raw=$(du -sk "$path" 2>/dev/null | awk '{print $1}')
    raw="${raw//[^0-9]/}"
    echo "${raw:-0}"
  else
    echo 0
  fi
}

human_size() {
  local kb="${1:-0}"
  [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
  if (( kb >= 1048576 )); then
    echo "$((kb / 1048576)).$(( (kb % 1048576) * 10 / 1048576 )) GB"
  elif (( kb >= 1024 )); then
    echo "$((kb / 1024)).$(( (kb % 1024) * 10 / 1024 )) MB"
  else
    echo "${kb} KB"
  fi
}

is_in_list() {
  local needle="$1" haystack="$2"
  echo "$haystack" | tr '|' '\n' | grep -qx "$needle"
}

contains_in_list() {
  local needle="$1" haystack="$2"
  echo "$haystack" | tr '|' '\n' | while read -r item; do
    [[ "$needle" == *"$item"* && ${#item} -gt 3 ]] && exit 0
  done
}

# ── 构建 find -name 参数 ──
find_names=""
for n in "${DISCOVER_CACHE_NAMES[@]}"; do
  find_names="$find_names -name $n -o"
done
find_names="${find_names% -o}"

# ── 收集未覆盖项 ──
# 格式: path|app|rel|size|layer
uncovered_items=""

# Layer 1+2: Containers + Application Support
scan_dirs="$HOME/Library/Containers $HOME/Library/Application Support"
raw_results=$(eval "find $scan_dirs -maxdepth 4 -type d \\( $find_names \\)" 2>/dev/null || true)

if [ -n "$raw_results" ]; then
  while IFS= read -r cache_path; do
    [ -d "$cache_path" ] || continue
    local_app="" layer=""

    case "$cache_path" in
      */Containers/*)
        layer="containers"
        local_app=$(echo "$cache_path" | sed "s|$HOME/Library/Containers/||" | cut -d'/' -f1)
        is_in_list "$local_app" "$DEDUP_CONTAINERS" && continue
        ;;
      */Application\ Support/*)
        layer="appsupport"
        local_app=$(echo "$cache_path" | sed "s|$HOME/Library/Application Support/||" | cut -d'/' -f1)
        contains_in_list "$local_app" "$DEDUP_APP_SUPPORT" && continue
        ;;
      *) continue ;;
    esac

    sz=$(size_of "$cache_path")
    [ "$sz" -gt "${DISCOVER_MIN_SIZE:-5120}" ] || continue

    rel="${cache_path#"$HOME/Library/$layer/"}"
    uncovered_items="$uncovered_items|$cache_path|$local_app|$rel|$sz|$layer"
  done <<< "$raw_results"
fi

# Layer 3: Home dotfiles
for dotdir in "$HOME"/.*/ ; do
  [ -d "$dotdir" ] || continue
  dn=$(basename "$dotdir")
  is_in_list "$dn" "$DEDUP_DOTFILES" && continue

  for cn in "${DISCOVER_CACHE_NAMES[@]}"; do
    candidate="$dotdir$cn"
    if [ -d "$candidate" ]; then
      sz=$(size_of "$candidate")
      if [ "$sz" -gt "${DISCOVER_MIN_SIZE:-5120}" ]; then
        uncovered_items="$uncovered_items|$candidate|$dn|$dn/$cn|$sz|dotfile"
      fi
    fi
  done
done

# ~/.cache 子目录
if [ -d "$HOME/.cache" ]; then
  for sub in "$HOME/.cache"/*/; do
    [ -d "$sub" ] || continue
    sn=$(basename "$sub")
    [ "$sn" = "rod" ] && continue
    sz=$(size_of "$sub")
    if [ "$sz" -gt "${DISCOVER_MIN_SIZE:-5120}" ]; then
      uncovered_items="$uncovered_items|$sub|.cache/$sn|.cache/$sn|$sz|dotcache"
    fi
  done
fi

# ── 输出 / 写入 ──
if [ -z "$uncovered_items" ]; then
  if [ "$MODE" = "report" ]; then
    echo -e "${GREEN}所有缓存目录均已被数据层覆盖（Tier 1 + Tier 2），无新增发现。${NC}"
  elif [ "$MODE" = "patch" ]; then
    echo "# 无新增发现"
  elif [ "$MODE" = "apply" ]; then
    echo -e "${GREEN}无新增发现，$USER_DATA_FILE 未修改。${NC}"
  fi
  exit 0
fi

# 解析未覆盖项
IFS_BAK="$IFS"
IFS='|'
set -f
parts=($uncovered_items)
set +f
IFS="$IFS_BAK"

total_sz=0
entry_count=0
patch_lines=""

i=1
while [ $i -lt ${#parts[@]} ]; do
  p_path="${parts[$i]}"
  p_app="${parts[$((i+1))]}"
  p_rel="${parts[$((i+2))]}"
  p_sz="${parts[$((i+3))]}"
  p_layer="${parts[$((i+4))]}"

  total_sz=$((total_sz + p_sz))
  entry_count=$((entry_count + 1))

  if [ "$MODE" = "report" ]; then
    case "$p_layer" in
      containers)  tag="${CYAN}Containers${NC}" ;;
      appsupport)  tag="${YELLOW}AppSupport${NC}" ;;
      dotfile)     tag="${GREEN}dotfile${NC}" ;;
      dotcache)    tag="${GREEN}.cache${NC}" ;;
      *)           tag="$p_layer" ;;
    esac
    echo -e "  [$tag] ${BOLD}$p_app${NC}: $p_rel  $(human_size $p_sz)"
    echo -e "    ${DIM}$p_path${NC}"
  fi

  # 构建 patch 行 (bash-sourceable 格式)
  case "$p_layer" in
    containers)
      patch_lines="$patch_lines
# [$p_layer] $p_app: $p_rel ($(human_size $p_sz))
DEDUP_CONTAINERS=\"\$DEDUP_CONTAINERS|$p_app\"
APP_CACHE_RULES+=(
  \"\$HOME/Library/Containers/$p_app/Data/Library/Caches|$p_app 缓存|cache_remove|5120\"
)"
      ;;
    appsupport)
      patch_lines="$patch_lines
# [$p_layer] $p_app: $p_rel ($(human_size $p_sz))
DEDUP_APP_SUPPORT=\"\$DEDUP_APP_SUPPORT|$p_app\"
APP_CACHE_RULES+=(
  \"\$HOME/Library/Application Support/$p_app/Cache|$p_app 缓存|cache_remove|5120\"
)"
      ;;
    dotfile)
      local_dotdir=$(echo "$p_app" | sed 's|^\..*||')
      patch_lines="$patch_lines
# [$p_layer] $p_app: $p_rel ($(human_size $p_sz))
DEDUP_DOTFILES=\"\$DEDUP_DOTFILES|$p_app\"
DOTFILE_CACHE_RULES+=(
  \"\$HOME/$p_app|cache|$p_app 缓存|5120\"
)"
      ;;
    dotcache)
      patch_lines="$patch_lines
# [$p_layer] $p_app: $p_rel ($(human_size $p_sz))
DOTFILE_CACHE_RULES+=(
  \"\$HOME/$p_app||$p_app 缓存|5120\"
)"
      ;;
  esac

  i=$((i + 5))
done

if [ "$MODE" = "report" ]; then
  echo ""
  echo -e "${BOLD}未覆盖项: ${entry_count} 个，合计 $(human_size $total_sz)${NC}"
  echo -e "${DIM}提示:${NC}"
  echo -e "${DIM}  ./scan-discover.sh --patch   查看可追加的 bash 片段${NC}"
  echo -e "${DIM}  ./scan-discover.sh --apply   追加到 $USER_DATA_FILE${NC}"
fi

if [ "$MODE" = "patch" ]; then
  echo "# === 用户数据补丁 $(date +%Y-%m-%d) ==="
  echo "# 追加到 $USER_DATA_FILE"
  echo "# 注意: 路径和规则可能需要根据实际缓存结构调整"
  echo "$patch_lines"
fi

if [ "$MODE" = "apply" ]; then
  mkdir -p "$USER_DATA_DIR"

  # 如果文件不存在，写入头部
  if [ ! -f "$USER_DATA_FILE" ]; then
    cat > "$USER_DATA_FILE" << 'HEADER'
#!/usr/bin/env bash
# ~/.mac-cleanup/data.txt — 用户级清理数据 (Tier 2)
# 由 scan-discover.sh --apply 自动追加
# 可手动编辑，格式同 cleanup-data.sh
# 修改时间: HEADER_DATE
HEADER
    sed -i '' "s|HEADER_DATE|$(date '+%Y-%m-%d %H:%M')|" "$USER_DATA_FILE"
  fi

  # 追加分隔符和补丁
  echo "" >> "$USER_DATA_FILE"
  echo "# ── 发现于 $(date '+%Y-%m-%d %H:%M') ──" >> "$USER_DATA_FILE"
  echo "$patch_lines" >> "$USER_DATA_FILE"

  echo -e "${GREEN}[✓]${NC} 已追加 ${entry_count} 条规则到 ${BOLD}$USER_DATA_FILE${NC}"
  echo -e "  新增去重: $(echo "$patch_lines" | grep '^DEDUP_' | wc -l | tr -d ' ') 条"
  echo -e "  新增规则: $(echo "$patch_lines" | grep '_RULES' | wc -l | tr -d ' ') 条"
  echo -e "  ${DIM}下次执行 mac-cleanup.sh 将自动加载这些数据${NC}"
  echo -e "  ${YELLOW}提示: 路径可能需要手动微调以匹配实际缓存结构${NC}"
fi
