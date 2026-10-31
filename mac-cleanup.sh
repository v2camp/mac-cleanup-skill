#!/usr/bin/env bash
# ============================================================================
#  macOS 清理脚本 — mac-cleanup.sh
#  用法:  ./mac-cleanup.sh              # 交互模式，逐项确认
#         ./mac-cleanup.sh -y           # 全部执行，不逐项询问
#         ./mac-cleanup.sh -n           # 仅预览（dry-run），不做任何操作
#         ./mac-cleanup.sh --discover   # 常规清理 + 自动发现扫描
#         ./mac-cleanup.sh --analyze [路径]
#                                       # 尺寸优先的 80/20 占用分析（只读，不清理）
#
#  维护说明: 每个清理项是独立函数，以 cleanup_xxx 命名，在底部 MAIN 中注册。
#           新增清理项只需：1) 添加函数  2) 在 MAIN 中 register。
#           --discover 模式会在常规清理后扫描 Containers/Application Support/
#           Home dotfiles 中的未覆盖缓存，发现新的清理机会。
#           --analyze 直通 disk-8020.sh（发现层通道 B），不进入清理流程。
# ============================================================================

set -euo pipefail

# 加载数据层 — 两级架构
# Tier 1: skill 数据 (开发者维护，版本控制)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/scripts"
DATA_FILE="$SCRIPTS_DIR/cleanup-data.sh"
if [ -f "$DATA_FILE" ]; then
  source "$DATA_FILE"
fi

# Tier 2: 用户数据 (agent 自动发现追加，用户本地)
USER_DATA_DIR="$HOME/.mac-cleanup"
USER_DATA_FILE="$USER_DATA_DIR/data.txt"
if [ -f "$USER_DATA_FILE" ]; then
  source "$USER_DATA_FILE"
fi

# ── 全局变量 ─────────────────────────────────────────────────────────────────
DRY_RUN=false
AUTO_YES=false
DISCOVER=false
TOTAL_FREED=0
SECTION_FREED=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── 参数解析 ─────────────────────────────────────────────────────────────────
# --analyze 是只读直通，必须在数据层加载之后、清理流程之前短路，
# 避免进入 MAIN（它不涉及任何清理语义，也不接受 -y）。
if [ "${1:-}" = "--analyze" ] || [ "${1:-}" = "-a" ]; then
  shift
  ANALYZE_TARGET=""
  case "${1:-}" in
    ""|-*) ;;                      # 未指定路径，由 disk-8020.sh 用默认卷
    *)     ANALYZE_TARGET="$1" ;;
  esac
  if [ -n "$ANALYZE_TARGET" ]; then
    exec "$SCRIPTS_DIR/disk-8020.sh" "$ANALYZE_TARGET"
  else
    exec "$SCRIPTS_DIR/disk-8020.sh"
  fi
fi

for arg in "$@"; do
  case $arg in
    -y|--yes)       AUTO_YES=true ;;
    -n|--dry-run)   DRY_RUN=true ;;
    -d|--discover)  DISCOVER=true ;;
    -h|--help)
      head -9 "$0" | tail -6
      exit 0 ;;
    *) echo "未知参数: $arg"; exit 1 ;;
  esac
done

# ── 工具函数 ─────────────────────────────────────────────────────────────────

# 获取目录/文件大小（KB，纯整数）
size_of() {
  local path="$1"
  if [ -e "$path" ]; then
    local raw
    raw=$(du -sk "$path" 2>/dev/null | awk '{print $1}')
    # 确保返回纯整数，空值归零
    raw="${raw//[^0-9]/}"
    echo "${raw:-0}"
  else
    echo 0
  fi
}

# 人类可读的大小（纯 bash 算术，无外部依赖）
human_size() {
  local kb="${1:-0}"
  # 兜底：非数字归零
  [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
  if (( kb >= 1048576 )); then
    local whole=$((kb / 1048576))
    local frac=$(( (kb % 1048576) * 10 / 1048576 ))
    echo "${whole}.${frac} GB"
  elif (( kb >= 1024 )); then
    local whole=$((kb / 1024))
    local frac=$(( (kb % 1024) * 10 / 1024 ))
    echo "${whole}.${frac} MB"
  else
    echo "${kb} KB"
  fi
}

# 节标题
section() {
  echo ""
  echo -e "${BOLD}${CYAN}━━━ $1 ━━━${NC}"
  SECTION_FREED=0
}

# 询问用户是否执行
confirm() {
  if $AUTO_YES; then return 0; fi
  if $DRY_RUN; then return 0; fi
  echo -ne "  ${YELLOW}? $1 [Y/n] ${NC}"
  read -r ans
  [[ -z "$ans" || "$ans" =~ ^[Yy] ]]
}

# 执行不可逆 CLI 变更（brew / pnpm / simctl 等）
# confirm() 在 dry-run 下恒返回 0，因此这类外部命令必须走本函数拦截，
# 否则 -n 预览会真的执行删除。
run_cli() {
  local desc="$1"; shift
  if $DRY_RUN; then
    echo -e "  ${YELLOW}[dry-run]${NC} 将执行: $desc"
    return 0
  fi
  "$@" 2>/dev/null || true
}

# 安全删除：移到废纸篓（macOS）
safe_remove() {
  local target="$1"
  if $DRY_RUN; then
    echo -e "  ${YELLOW}[dry-run]${NC} 将移除: $target"
    return
  fi
  if [ ! -e "$target" ]; then
    echo -e "  ${CYAN}[跳过]${NC} 不存在: $target"
    return
  fi
  # 移入废纸篓，避免冲突名
  local basename
  basename=$(basename "$target")
  local dest="$HOME/.Trash/${basename}_$(date +%Y%m%d%H%M%S)_$$"
  mv "$target" "$dest" 2>/dev/null && echo -e "  ${GREEN}[✓]${NC} 已移至废纸篓: $target" || echo -e "  ${RED}[✗]${NC} 移除失败: $target"
}

# 直接 rm（仅用于缓存/日志等纯临时文件）
cache_remove() {
  local target="$1"
  if $DRY_RUN; then
    echo -e "  ${YELLOW}[dry-run]${NC} 将清除: $target"
    return
  fi
  if [ ! -e "$target" ]; then
    return
  fi
  rm -rf "$target" && echo -e "  ${GREEN}[✓]${NC} 已清除: $target" || echo -e "  ${RED}[✗]${NC} 清除失败: $target"
}

# 报告本节释放空间
report_section() {
  if [ "$SECTION_FREED" -gt 0 ] 2>/dev/null; then
    echo -e "  ${GREEN}本节释放: $(human_size $SECTION_FREED)${NC}"
    TOTAL_FREED=$((TOTAL_FREED + SECTION_FREED))
  fi
}

# 计算并记录释放量
calc_freed() {
  local before="$1" after="$2"
  local freed=$((before - after))
  if [ "$freed" -gt 0 ] 2>/dev/null; then
    SECTION_FREED=$((SECTION_FREED + freed))
  fi
}


# ============================================================================
#  清理函数 — 每项独立，方便增删
# ============================================================================

# ────────────────────────────────────────────────────────────────────────────
# 1. 已卸载 App 的 code_sign_clone 残留
#    背景: macOS 对签名 App 做代码签名缓存，卸载 App 后缓存不会自动清理
# ────────────────────────────────────────────────────────────────────────────
cleanup_code_sign_clone() {
  section "macOS 代码签名缓存 (code_sign_clone)"

  local base="/private/var/folders"
  local dirs
  dirs=$(find "$base" -maxdepth 6 -type d -name "*.code_sign_clone" 2>/dev/null || true)

  if [ -z "$dirs" ]; then
    echo -e "  ${CYAN}[跳过]${NC} 未发现 code_sign_clone 目录"
    return
  fi

  while IFS= read -r dir; do
    local app_id
    app_id=$(basename "$dir")

    # 从 CODE_SIGN_RULES 数据层匹配 App
    local app_name="" install_path="" matched=false
    if [ ${#CODE_SIGN_RULES[@]} -gt 0 ] 2>/dev/null; then
      for rule in "${CODE_SIGN_RULES[@]}"; do
        IFS='|' read -r prefix name check_path <<< "$rule"
        case "$app_id" in
          "$prefix"*)
            app_name="$name"
            install_path="$check_path"
            matched=true
            break ;;
        esac
      done
    fi

    if ! $matched; then
      echo -e "  ${CYAN}[跳过]${NC} $dir (未知 App: $app_id)"
      continue
    fi

    local installed=false
    [ -d "$install_path" ] && installed=true

    local sz
    sz=$(size_of "$dir")

    if $installed; then
      echo -e "  ${CYAN}[保留]${NC} $app_name 仍在安装中 ($(human_size $sz))"
    else
      echo -e "  ${RED}[可删]${NC} $app_name 已卸载 ($(human_size $sz)): $dir"
      if confirm "删除 $app_name 的代码签名缓存?"; then
        local before=$sz
        if ! $DRY_RUN; then
          sudo rm -rf "$dir" 2>/dev/null || cache_remove "$dir"
        else
          cache_remove "$dir"
        fi
        local after
        after=$(size_of "$dir")
        calc_freed "$before" "$after"
      fi
    fi
  done <<< "$dirs"
  report_section
}

# ────────────────────────────────────────────────────────────────────────────
# 2. Homebrew 旧版本清理
#    背景: brew 更新后会保留旧版 portable-ruby 等，cleanup 可回收
# ────────────────────────────────────────────────────────────────────────────
cleanup_homebrew() {
  section "Homebrew 旧版本"

  if ! command -v brew &>/dev/null; then
    echo -e "  ${CYAN}[跳过]${NC} 未安装 Homebrew"
    return
  fi

  local preview
  preview=$(brew cleanup -n 2>/dev/null || true)
  if [ -z "$preview" ]; then
    echo -e "  ${CYAN}[跳过]${NC} 无需清理"
    return
  fi

  echo "  可清理内容:"
  echo "$preview" | sed 's/^/    /'

  if confirm "执行 brew cleanup?"; then
    if $DRY_RUN; then
      echo -e "  ${YELLOW}[dry-run]${NC} 将执行: brew cleanup -s"
    else
      local before
      before=$(size_of "$(brew --prefix)/Library")
      brew cleanup -s 2>/dev/null || true
      local after
      after=$(size_of "$(brew --prefix)/Library")
      calc_freed "$before" "$after"
    fi
  fi
  report_section
}

# ────────────────────────────────────────────────────────────────────────────
# 3. npm 缓存
#    背景: npm 会缓存下载的 tarball 和 npx 执行结果，持续膨胀
# ────────────────────────────────────────────────────────────────────────────
cleanup_npm() {
  section "npm 缓存"

  if ! command -v npm &>/dev/null; then
    echo -e "  ${CYAN}[跳过]${NC} 未安装 npm"
    return
  fi

  # npm 子目录已纳入 DOTFILE_CACHE_RULES 数据层
  # 此处仅做存在性提示，实际清理由 cleanup_app_caches 中的 dotfile 逻辑执行
  local npm_dir="$HOME/.npm"
  if [ ! -d "$npm_dir" ]; then
    echo -e "  ${CYAN}[跳过]${NC} 无 npm 缓存目录"
    return
  fi

  local sz
  sz=$(size_of "$npm_dir")
  echo -e "  npm 目录总大小: $(human_size $sz) (子目录清理见「常用 App 缓存」节)"
  report_section
}

# ────────────────────────────────────────────────────────────────────────────
# 4. pnpm store 修剪
#    背景: pnpm store 是全局共享的内容寻址存储，prune 可移除孤立包
#    注意: 这是安全操作，不影响任何已安装项目的 node_modules
# ────────────────────────────────────────────────────────────────────────────
cleanup_pnpm() {
  section "pnpm store 修剪"

  if ! command -v pnpm &>/dev/null; then
    echo -e "  ${CYAN}[跳过]${NC} 未安装 pnpm"
    return
  fi

  local store_path
  store_path=$(pnpm store path 2>/dev/null || true)
  if [ -z "$store_path" ] || [ ! -d "$store_path" ]; then
    echo -e "  ${CYAN}[跳过]${NC} 无法定位 pnpm store"
    return
  fi

  local sz
  sz=$(size_of "$store_path")
  echo -e "  pnpm store 位置: $store_path ($(human_size $sz))"
  echo -e "  修剪只移除不被任何项目引用的孤立包，不影响已安装项目"

  if confirm "执行 pnpm store prune?"; then
    # confirm() 在 dry-run 下恒返回 0，必须显式拦截，否则预览会真的执行 prune
    # （且 pnpm store prune 是交互式确认，非 tty 下会静默挂死）
    if $DRY_RUN; then
      echo -e "  ${YELLOW}[dry-run]${NC} 将执行: pnpm store prune"
    else
      local before=$sz
      pnpm store prune 2>/dev/null || true
      local after
      after=$(size_of "$store_path")
      calc_freed "$before" "$after"
    fi
  fi
  report_section
}

# ────────────────────────────────────────────────────────────────────────────
# 5. Docker 清理（镜像/容器/卷/构建缓存）
#    前提: Docker Desktop 需要在运行中
# ────────────────────────────────────────────────────────────────────────────
cleanup_docker() {
  section "Docker 未使用资源"

  if ! command -v docker &>/dev/null; then
    echo -e "  ${CYAN}[跳过]${NC} 未安装 Docker"
    return
  fi

  if ! docker info &>/dev/null; then
    echo -e "  ${CYAN}[跳过]${NC} Docker Desktop 未运行"
    return
  fi

  echo "  当前 Docker 资源使用情况:"
  docker system df 2>/dev/null | sed 's/^/    /'

  if confirm "清理所有未使用的 Docker 资源 (dangling 镜像、停止的容器、未用卷)?"; then
    echo -e "  ${YELLOW}[!]${NC} 这会删除停止的容器和未使用的镜像，建议先确认没有重要数据"
    if confirm "确认继续?"; then
      if $DRY_RUN; then
        echo -e "  ${YELLOW}[dry-run]${NC} 将执行: docker system prune -af --volumes"
      else
        docker system prune -af --volumes 2>/dev/null || true
        echo -e "  ${GREEN}[✓]${NC} Docker 清理完成"
        echo "  清理后:"
        docker system df 2>/dev/null | sed 's/^/    /'
      fi
    fi
  fi

  # Docker Desktop 日志
  local docker_logs="$HOME/Library/Containers/com.docker.docker/Data/log"
  if [ -d "$docker_logs" ]; then
    local sz
    sz=$(size_of "$docker_logs")
    if [ "$sz" -gt 10240 ]; then  # >10MB 才提示
      echo -e "  Docker 日志: $(human_size $sz)"
      if confirm "清除 Docker Desktop 日志?"; then
        local before=$sz
        cache_remove "$docker_logs"
        local after
        after=$(size_of "$docker_logs")
        calc_freed "$before" "$after"
      fi
    fi
  fi

  # Docker 下载残留 (com.docker.install/in_progress)
  local docker_install="$HOME/Library/Application Support/com.docker.install/in_progress"
  if [ -d "$docker_install" ]; then
    local sz
    sz=$(size_of "$docker_install")
    echo -e "  Docker 下载残留: $(human_size $sz)"
    if confirm "删除中断的 Docker 下载残留?"; then
      local before=$sz
      safe_remove "$docker_install"
      local after
      after=$(size_of "$docker_install")
      calc_freed "$before" "$after"
    fi
  fi

  report_section
}

# ────────────────────────────────────────────────────────────────────────────
# 6. Xcode 构建缓存与模拟器
#    背景: DerivedData / Previews / Archives 可安全清除，Xcode 会按需重建
# ────────────────────────────────────────────────────────────────────────────
cleanup_xcode() {
  section "Xcode 缓存与模拟器"

  local xcode_dev="$HOME/Library/Developer"
  if [ ! -d "$xcode_dev" ]; then
    echo -e "  ${CYAN}[跳过]${NC} 未检测到 Xcode 开发目录"
    return
  fi

  # 数据驱动的 Xcode 缓存路径
  if [ ${#XCODE_CACHE_RULES[@]} -gt 0 ] 2>/dev/null; then
    for rule in "${XCODE_CACHE_RULES[@]}"; do
      IFS='|' read -r rel_path display_name threshold prompt_msg <<< "$rule"
      local full_path="$xcode_dev/$rel_path"
      [ -d "$full_path" ] || continue

      local sz
      sz=$(size_of "$full_path")
      if [ "$sz" -gt "$threshold" ]; then
        echo -e "  $display_name: $(human_size $sz)"
        if confirm "$prompt_msg"; then
          local before=$sz
          cache_remove "$full_path"
          local after
          after=$(size_of "$full_path")
          calc_freed "$before" "$after"
        fi
      fi
    done
  fi

  # CoreSimulator 设备 (CLI 逻辑，必须留在代码层)
  if command -v xcrun &>/dev/null; then
    local sim_devices="$xcode_dev/CoreSimulator/Devices"
    if [ -d "$sim_devices" ]; then
      local sz
      sz=$(size_of "$sim_devices")
      if [ "$sz" -gt 102400 ]; then
        # 超过 100MB 时提供全量清理选项
        echo -e "  iOS 模拟器数据: $(human_size $sz)"
        if confirm "删除所有模拟器设备? (Xcode 需要时会自动重建)"; then
          local before=$sz
          run_cli "xcrun simctl delete all" xcrun simctl delete all
          local after
          after=$(size_of "$sim_devices")
          calc_freed "$before" "$after"
        elif confirm "仅删除不可用的模拟器设备?"; then
          local before=$sz
          run_cli "xcrun simctl delete unavailable" xcrun simctl delete unavailable
          local after
          after=$(size_of "$sim_devices")
          calc_freed "$before" "$after"
        fi
      elif [ "$sz" -gt 0 ]; then
        echo -e "  iOS 模拟器数据: $(human_size $sz)"
        if confirm "删除不可用的模拟器设备?"; then
          local before=$sz
          run_cli "xcrun simctl delete unavailable" xcrun simctl delete unavailable
          local after
          after=$(size_of "$sim_devices")
          calc_freed "$before" "$after"
        fi
      fi
    fi
  fi

  report_section
}

# ────────────────────────────────────────────────────────────────────────────
# 7. IDE / 编辑器日志与缓存 (TRAE, Trae CN, VS Code 等)
#    背景: 基于 Electron 的编辑器会累积大量日志和 CachedData
#    数据源: EDITOR_AS_CACHES, IDE_LIB_CACHES, SHIPIT_CACHES (cleanup-data.sh)
# ────────────────────────────────────────────────────────────────────────────
cleanup_editor_caches() {
  section "编辑器日志与缓存"

  local app_support="$HOME/Library/Application Support"
  local caches="$HOME/Library/Caches"

  # ── Application Support 下的 logs + CachedData ──
  if [ ${#EDITOR_AS_CACHES[@]} -gt 0 ] 2>/dev/null; then
    for entry in "${EDITOR_AS_CACHES[@]}"; do
      IFS='|' read -r dir_name display_name <<< "$entry"
      local base="$app_support/$dir_name"
      [ -d "$base" ] || continue

      local logs="$base/logs"
      local cached="$base/CachedData"
      local logs_sz=0 cached_sz=0

      [ -d "$logs" ] && logs_sz=$(size_of "$logs")
      [ -d "$cached" ] && cached_sz=$(size_of "$cached")
      local total=$((logs_sz + cached_sz))

      if [ "$total" -gt 5120 ]; then
        echo -e "  $display_name 日志+缓存: $(human_size $total)"
        if confirm "清除 $display_name 的日志和缓存?"; then
          [ -d "$logs" ] && { local b=$logs_sz; cache_remove "$logs"; calc_freed "$b" "$(size_of "$logs")"; }
          [ -d "$cached" ] && { local b=$cached_sz; cache_remove "$cached"; calc_freed "$b" "$(size_of "$cached")"; }
        fi
      fi
    done
  fi

  # ── IDE 在 ~/Library/Caches 中的缓存 ──
  if [ ${#IDE_LIB_CACHES[@]} -gt 0 ] 2>/dev/null; then
    for entry in "${IDE_LIB_CACHES[@]}"; do
      IFS='|' read -r dir_name display_name <<< "$entry"
      local ic_path="$caches/$dir_name"
      if [ -d "$ic_path" ]; then
        local sz
        sz=$(size_of "$ic_path")
        if [ "$sz" -gt 5120 ]; then
          echo -e "  $display_name 缓存 (~/Library/Caches): $(human_size $sz)"
          if confirm "清除 $display_name 的应用缓存?"; then
            local before=$sz
            cache_remove "$ic_path"
            local after
            after=$(size_of "$ic_path")
            calc_freed "$before" "$after"
          fi
        fi
      fi
    done
  fi

  # ── ShipIt 更新包暂存（已应用的 Electron 更新）──
  if [ ${#SHIPIT_CACHES[@]} -gt 0 ] 2>/dev/null; then
    for entry in "${SHIPIT_CACHES[@]}"; do
      IFS='|' read -r dir_name display_name <<< "$entry"
      local si_path="$caches/$dir_name"
      if [ -d "$si_path" ]; then
        local sz
        sz=$(size_of "$si_path")
        if [ "$sz" -gt 5120 ]; then
          echo -e "  $display_name 更新包暂存: $(human_size $sz)"
          if confirm "清除 $display_name 已应用的更新包?"; then
            local before=$sz
            cache_remove "$si_path"
            local after
            after=$(size_of "$si_path")
            calc_freed "$before" "$after"
          fi
        fi
      fi
    done
  fi

  report_section
}

# ────────────────────────────────────────────────────────────────────────────
# 8. ~/Library/Caches 中的安全项
#    背景: Caches 目录下的内容设计上就是可丢弃的
#    策略: 只清理明确安全的（浏览器缓存、构建工具缓存），不碰 App 运行时依赖
#    数据源: SYSTEM_CACHES (cleanup-data.sh)
# ────────────────────────────────────────────────────────────────────────────
cleanup_system_caches() {
  section "系统缓存 (~/Library/Caches)"

  local caches="$HOME/Library/Caches"
  if [ ! -d "$caches" ]; then
    echo -e "  ${CYAN}[跳过]${NC} 缓存目录不存在"
    return
  fi

  # ── 数据驱动的缓存目录清理 ──
  if [ ${#SYSTEM_CACHES[@]} -gt 0 ] 2>/dev/null; then
    for entry in "${SYSTEM_CACHES[@]}"; do
      IFS='|' read -r dir_name display_name <<< "$entry"
      local bc="$caches/$dir_name"
      if [ -d "$bc" ]; then
        local sz
        sz=$(size_of "$bc")
        if [ "$sz" -gt 5120 ]; then
          echo -e "  $display_name 缓存: $(human_size $sz)"
          if confirm "清除 $display_name 缓存?"; then
            local before=$sz
            cache_remove "$bc"
            local after
            after=$(size_of "$bc")
            calc_freed "$before" "$after"
          fi
        fi
      fi
    done
  fi

  # Brave Service Worker 缓存 — 网站离线缓存，删除后访问时自动重建
  # (特殊路径，保留为独立逻辑)
  local brave_sw_cache="$HOME/Library/Application Support/BraveSoftware/Brave-Browser/Default/Service Worker/CacheStorage"
  if [ -d "$brave_sw_cache" ]; then
    local sz
    sz=$(size_of "$brave_sw_cache")
    if [ "$sz" -gt 10240 ]; then
      echo -e "  Brave SW 缓存 (CacheStorage): $(human_size $sz)"
      if confirm "清除 Brave Service Worker 缓存? (建议先关闭 Brave)"; then
        local before=$sz
        cache_remove "$brave_sw_cache"
        local after
        after=$(size_of "$brave_sw_cache")
        calc_freed "$before" "$after"
      fi
    fi
  fi

  report_section
}

# ────────────────────────────────────────────────────────────────────────────
# 9. ~/Library/Logs 旧日志
#    背景: 应用日志会持续累积，旧日志通常无用
# ────────────────────────────────────────────────────────────────────────────
cleanup_logs() {
  section "应用日志 (~/Library/Logs)"

  local logs
  eval "logs=\"${LOGS_DIR:-\$HOME/Library/Logs}\""
  if [ ! -d "$logs" ]; then return; fi

  local threshold="${LOGS_THRESHOLD:-5120}"
  local sz
  sz=$(size_of "$logs")
  if [ "$sz" -le "$threshold" ]; then
    echo -e "  ${CYAN}[跳过]${NC} 日志目录很小 ($(human_size $sz))"
    return
  fi

  echo -e "  日志目录: $(human_size $sz)"
  if confirm "清除所有应用日志?"; then
    local before=$sz
    cache_remove "$logs"
    local after
    after=$(size_of "$logs")
    calc_freed "$before" "$after"
  fi
  report_section
}

# ────────────────────────────────────────────────────────────────────────────
# 10. CrashReporter 报告
#     背景: 崩溃报告长期积累无用
# ────────────────────────────────────────────────────────────────────────────
cleanup_crash_reports() {
  section "崩溃报告"

  local crash_dir
  eval "crash_dir=\"${CRASH_DIR:-\$HOME/Library/Application Support/CrashReporter}\""
  if [ ! -d "$crash_dir" ]; then return; fi

  local threshold="${CRASH_THRESHOLD:-1024}"
  local sz
  sz=$(size_of "$crash_dir")
  if [ "$sz" -le "$threshold" ]; then
    return
  fi

  echo -e "  崩溃报告: $(human_size $sz)"
  if confirm "清除旧的崩溃报告?"; then
    local before=$sz
    cache_remove "$crash_dir"
    local after
    after=$(size_of "$crash_dir")
    calc_freed "$before" "$after"
  fi
  report_section
}

# ────────────────────────────────────────────────────────────────────────────
# 11. 废纸篓
#     背景: 很多人忘了清空废纸篓
# ────────────────────────────────────────────────────────────────────────────
cleanup_trash() {
  section "废纸篓"

  local trash="$HOME/.Trash"
  if [ ! -d "$trash" ]; then return; fi

  local sz
  sz=$(size_of "$trash")
  if [ "$sz" -le 1024 ]; then
    echo -e "  ${CYAN}[跳过]${NC} 废纸篓几乎为空"
    return
  fi

  echo -e "  废纸篓: $(human_size $sz)"
  if confirm "清空废纸篓?"; then
    if $DRY_RUN; then
      echo -e "  ${YELLOW}[dry-run]${NC} 将清空废纸篓"
    else
      osascript -e 'tell application "Finder" to empty the trash' 2>/dev/null && \
        echo -e "  ${GREEN}[✓]${NC} 废纸篓已清空" || \
        echo -e "  ${RED}[✗]${NC} 清空失败，可手动在 Finder 中操作"
    fi
  fi
  report_section
}

# ────────────────────────────────────────────────────────────────────────────
# 12. 常用 App 缓存与日志
#     背景: 各 App 在 Containers 和 Application Support 中积累缓存/日志
#     策略: 只清缓存和日志，不动用户数据、设置、数据库
#     数据源: APP_CACHE_RULES, DOTFILE_CACHE_RULES, ORPHAN_RULES (cleanup-data.sh)
# ────────────────────────────────────────────────────────────────────────────
cleanup_app_caches() {
  section "常用 App 缓存与日志"

  # ── 数据驱动的简单 App 缓存规则 ──
  # 格式: "路径|显示名|操作类型|阈值KB"
  if [ ${#APP_CACHE_RULES[@]} -gt 0 ] 2>/dev/null; then
    for rule in "${APP_CACHE_RULES[@]}"; do
      IFS='|' read -r path_tmpl display_name action threshold <<< "$rule"
      # 展开 $HOME
      local path
      eval "path=\"$path_tmpl\""
      [ -d "$path" ] || continue

      local sz
      sz=$(size_of "$path")
      if [ "$sz" -gt "$threshold" ]; then
        echo -e "  $display_name: $(human_size $sz)"
        if confirm "清除 $display_name?"; then
          local before=$sz
          $action "$path"
          local after
          after=$(size_of "$path")
          calc_freed "$before" "$after"
        fi
      fi
    done
  fi


  # ── 孤儿 dotfiles：App 已卸载，数据目录残留 ──
  # 数据源: ORPHAN_RULES (cleanup-data.sh)
  # 格式: "路径|显示名|app:App关键字"
  if [ ${#ORPHAN_RULES[@]} -gt 0 ] 2>/dev/null; then
    for item in "${ORPHAN_RULES[@]}"; do
      IFS='|' read -r path_tmpl name check <<< "$item"
      # 展开 $HOME
      local path
      eval "path=\"$path_tmpl\""
      [ -e "$path" ] || continue

      # 解析检测条件
      local check_type="${check%%:*}"
      local check_val="${check#*:}"
      local installed=false

      if [ "$check_type" = "app" ]; then
        # 检查 /Applications 中是否有匹配
        if ls /Applications/*"$check_val"* 1>/dev/null 2>&1; then
          installed=true
        fi
      fi

      if $installed; then
        continue  # App 还在，跳过
      fi

      local sz
      sz=$(size_of "$path")
      if [ "$sz" -gt 10240 ]; then
        echo -e "  $name 残留数据 (App 已卸载): $(human_size $sz)"
        if confirm "删除 $name 的残留数据?"; then
          local before=$sz
          safe_remove "$path"
          local after
          after=$(size_of "$path")
          calc_freed "$before" "$after"
        fi
      fi
    done
  fi

  # ── 已安装 App 的 dotfile 缓存/日志/快照 ──
  # 数据源: DOTFILE_CACHE_RULES (cleanup-data.sh)
  # 格式: "dotfile 路径|子目录1,子目录2|显示名|阈值KB"
  if [ ${#DOTFILE_CACHE_RULES[@]} -gt 0 ] 2>/dev/null; then
    for rule in "${DOTFILE_CACHE_RULES[@]}"; do
      IFS='|' read -r base_tmpl subdirs_csv display_name threshold <<< "$rule"
      # 展开 $HOME
      local base_dir
      eval "base_dir=\"$base_tmpl\""
      [ -d "$base_dir" ] || continue

      # 计算各子目录总大小
      local total=0
      local subdir_paths=""
      local IFS_BAK="$IFS"
      IFS=','
      for sd in $subdirs_csv; do
        local sd_path="$base_dir/$sd"
        if [ -d "$sd_path" ]; then
          local sd_sz
          sd_sz=$(size_of "$sd_path")
          total=$((total + sd_sz))
          subdir_paths="$subdir_paths|$sd_path|$sd_sz"
        fi
      done
      IFS="$IFS_BAK"

      if [ "$total" -gt "$threshold" ]; then
        echo -e "  $display_name: $(human_size $total)"
        if confirm "清除 $display_name?"; then
          # 逐子目录清除
          local IFS_BAK2="$IFS"
          IFS='|'
          set -f
          local parts=($subdir_paths)
          set +f
          IFS="$IFS_BAK2"
          local i=1
          while [ $i -lt ${#parts[@]} ]; do
            local sp="${parts[$i]}"
            local ssz="${parts[$((i+1))]}"
            cache_remove "$sp"
            calc_freed "$ssz" "$(size_of "$sp")"
            i=$((i + 2))
          done
        fi
      fi
    done
  fi

  # Trae CN: browser screenshots (保留为独立逻辑)
  local trae_ss="$HOME/.trae-cn/trae-browser-screenshots"
  if [ -d "$trae_ss" ]; then
    local sz
    sz=$(size_of "$trae_ss")
    if [ "$sz" -gt 1024 ]; then
      echo -e "  Trae CN 浏览器截图: $(human_size $sz)"
      if confirm "清除 Trae CN 浏览器截图?"; then
        local before=$sz
        cache_remove "$trae_ss"
        local after
        after=$(size_of "$trae_ss")
        calc_freed "$before" "$after"
      fi
    fi
  fi

  # QoderCN Application Support: CachedData + logs + GPUCache (保留: 3 子目录特殊逻辑)
  local qcn_as="$HOME/Library/Application Support/QoderCN"
  if [ -d "$qcn_as" ]; then
    local qcd="$qcn_as/CachedData"
    local qlog="$qcn_as/logs"
    local qgpu="$qcn_as/GPUCache"
    local qcd_sz=0 qlog_sz=0 qgpu_sz=0
    [ -d "$qcd" ] && qcd_sz=$(size_of "$qcd")
    [ -d "$qlog" ] && qlog_sz=$(size_of "$qlog")
    [ -d "$qgpu" ] && qgpu_sz=$(size_of "$qgpu")
    local qcn_as_total=$((qcd_sz + qlog_sz + qgpu_sz))

    if [ "$qcn_as_total" -gt 10240 ]; then
      echo -e "  QoderCN App 缓存+日志+GPU: $(human_size $qcn_as_total)"
      if confirm "清除 QoderCN 应用缓存和日志?"; then
        [ -d "$qcd" ] && { local b=$qcd_sz; cache_remove "$qcd"; calc_freed "$b" "$(size_of "$qcd")"; }
        [ -d "$qlog" ] && { local b=$qlog_sz; cache_remove "$qlog"; calc_freed "$b" "$(size_of "$qlog")"; }
        [ -d "$qgpu" ] && { local b=$qgpu_sz; cache_remove "$qgpu"; calc_freed "$b" "$(size_of "$qgpu")"; }
      fi
    fi
  fi

  report_section
}


# ────────────────────────────────────────────────────────────────────────────
# 18. 已卸载 App 的孤儿数据（bundle id 级）
#     数据源: ORPHAN_ID_RULES（Tier 1 / Tier 2，由 app-orphans.sh --emit-rules 写入）
#     格式: "bundle.id|显示名|路径1,路径2"
#     与 ORPHAN_RULES 的差别: 判据不是「/Applications 里有没有同名 .app」，
#       而是「这个 bundle id 还有没有存活 bundle」（LaunchServices + 在装清单）。
#       执行前再核验一次，防止审计后重装 App 被误删。
#     动作: safe_remove（移入废纸篓），不做物理删除
# ────────────────────────────────────────────────────────────────────────────
cleanup_orphan_ids() {
  section "已卸载 App 的孤儿数据（bundle id 级）"

  if [ ${#ORPHAN_ID_RULES[@]} -eq 0 ] 2>/dev/null; then
    echo -e "  ${CYAN}[跳过]${NC} 无规则（可运行 scripts/app-orphans.sh --emit-rules 生成）"
    return
  fi

  local checker="$SCRIPTS_DIR/app-orphans.sh"
  if [ ! -x "$checker" ]; then
    echo -e "  ${YELLOW}[跳过]${NC} 缺少 scripts/app-orphans.sh，无法核验 bundle id"
    return
  fi

  # 一次性核验所有 id（一次 lsregister 解析），避免逐条 fork
  local ids=() rule id name paths
  for rule in "${ORPHAN_ID_RULES[@]}"; do
    IFS='|' read -r id _ _ <<< "$rule"
    [ -n "$id" ] && ids+=("$id")
  done

  local vfile
  vfile=$(mktemp "${TMPDIR:-/tmp}/orphan-verify.XXXXXX")
  "$checker" --verify "${ids[@]}" > "$vfile" 2>/dev/null || true

  for rule in "${ORPHAN_ID_RULES[@]}"; do
    IFS='|' read -r id name paths <<< "$rule"
    if [ -z "$id" ] || [ -z "$paths" ]; then
      continue
    fi

    # 审计之后 App 可能被重新安装 —— 执行前必须再确认一次
    if grep -qx "$(printf '%s\tlive' "$id")" "$vfile" 2>/dev/null; then
      echo -e "  ${CYAN}[跳过]${NC} $name — bundle id 仍存活 ($id)"
      continue
    fi

    local old_ifs parts
    old_ifs="$IFS"
    IFS=','
    read -r -a parts <<< "$paths"
    IFS="$old_ifs"

    local total=0 p sz
    for p in "${parts[@]}"; do
      eval "p=\"$p\""
      [ -e "$p" ] || continue
      sz=$(size_of "$p")
      total=$((total + sz))
    done

    [ "$total" -gt 0 ] || continue

    echo -e "  $name 残留数据 (App 已卸载): $(human_size $total)  ${DIM}$id${NC}"
    if confirm "删除 $name 的残留数据? (移入废纸篓)"; then
      local before=$total
      for p in "${parts[@]}"; do
        eval "p=\"$p\""
        safe_remove "$p"
      done
      calc_freed "$before" 0
    fi
  done

  rm -f "$vfile"
  report_section
}


# ────────────────────────────────────────────────────────────────────────────
# 13. Glob 模式清理（QQ 表情 zip、同花顺日志等）
#     数据源: GLOB_CACHE_RULES (cleanup-data.sh)
#     格式: "目录路径|glob模式|显示名|阈值KB|提示语"
# ────────────────────────────────────────────────────────────────────────────
cleanup_glob_caches() {
  section "Glob 模式清理"

  if [ ${#GLOB_CACHE_RULES[@]} -eq 0 ] 2>/dev/null; then
    echo -e "  ${CYAN}[跳过]${NC} 无 glob 规则"
    return
  fi

  for rule in "${GLOB_CACHE_RULES[@]}"; do
    IFS='|' read -r dir_tmpl glob_pattern display_name threshold prompt_msg <<< "$rule"
    local dir
    eval "dir=\"$dir_tmpl\""
    [ -d "$dir" ] || continue

    # 统计匹配 glob 的文件总大小
    local total_sz=0
    for f in "$dir"/$glob_pattern; do
      [ -f "$f" ] && total_sz=$((total_sz + $(size_of "$f")))
    done

    if [ "$total_sz" -gt "$threshold" ]; then
      echo -e "  $display_name: $(human_size $total_sz)"
      if confirm "$prompt_msg"; then
        if ! $DRY_RUN; then
          rm -f "$dir"/$glob_pattern 2>/dev/null && echo -e "  ${GREEN}[✓]${NC} 已清除"
        else
          echo -e "  ${YELLOW}[dry-run]${NC} 将清除: $dir/$glob_pattern"
        fi
        calc_freed "$total_sz" "0"
      fi
    fi
  done
  report_section
}

# ────────────────────────────────────────────────────────────────────────────
# 14. 多用户目录遍历清理（腾讯文档等）
#     数据源: MULTI_USER_RULES (cleanup-data.sh)
#     格式: "用户基础路径|用户通配符|子路径1,子路径2|显示名|阈值KB|提示语"
# ────────────────────────────────────────────────────────────────────────────
cleanup_multi_user_caches() {
  section "多用户目录清理"

  if [ ${#MULTI_USER_RULES[@]} -eq 0 ] 2>/dev/null; then
    echo -e "  ${CYAN}[跳过]${NC} 无多用户规则"
    return
  fi

  for rule in "${MULTI_USER_RULES[@]}"; do
    IFS='|' read -r base_tmpl user_glob subdirs_csv display_name threshold prompt_msg <<< "$rule"
    local base_dir
    eval "base_dir=\"$base_tmpl\""
    [ -d "$base_dir" ] || continue

    # 统计所有用户目录下指定子路径的总大小
    local total=0
    local IFS_BAK="$IFS"
    IFS=','
    for subdir in $subdirs_csv; do
      IFS="$IFS_BAK"
      for user_dir in "$base_dir"/$user_glob/; do
        [ -d "${user_dir}${subdir}" ] && total=$((total + $(size_of "${user_dir}${subdir}")))
      done
      IFS=','
    done
    IFS="$IFS_BAK"

    if [ "$total" -gt "$threshold" ]; then
      echo -e "  $display_name: $(human_size $total)"
      if confirm "$prompt_msg"; then
        IFS=','
        for subdir in $subdirs_csv; do
          IFS="$IFS_BAK"
          for user_dir in "$base_dir"/$user_glob/; do
            if [ -d "${user_dir}${subdir}" ]; then
              local b
              b=$(size_of "${user_dir}${subdir}")
              cache_remove "${user_dir}${subdir}"
              calc_freed "$b" "$(size_of "${user_dir}${subdir}")"
            fi
          done
          IFS=','
        done
        IFS="$IFS_BAK"
      fi
    fi
  done
  report_section
}


# ────────────────────────────────────────────────────────────────────────────
# 15. 自动发现 (--discover 模式)
#     职责: 扫描手动模块未覆盖的盲区，发现新的缓存/日志清理机会
#     去重: 跳过手动模块已处理的 Containers / Application Support / dotfiles
#     性能: 单次 find 扫描 + 过滤，避免逐目录遍历大目录
# ────────────────────────────────────────────────────────────────────────────
cleanup_auto_discover() {
  $DISCOVER || return 0

  section "自动发现扫描"
  echo -e "  ${DIM}扫描手动模块未覆盖的缓存/日志（单次扫描，过滤已覆盖项）${NC}"

  local min_size="${DISCOVER_MIN_SIZE:-5120}"  # 数据层配置，默认 5 MB

  # 通用缓存子目录名模式 (用于 find -name) — 数据源: DISCOVER_CACHE_NAMES (cleanup-data.sh)
  local cache_names=()
  if [ ${#DISCOVER_CACHE_NAMES[@]} -gt 0 ] 2>/dev/null; then
    cache_names=("${DISCOVER_CACHE_NAMES[@]}")
  fi

  # ── 去重列表 — 数据源: cleanup-data.sh ──
  local covered_containers="${DEDUP_CONTAINERS:-}"
  local covered_as="${DEDUP_APP_SUPPORT:-}"
  local covered_dots="${DEDUP_DOTFILES:-}"

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
  local find_names=""
  for n in "${cache_names[@]}"; do
    find_names="$find_names -name $n -o"
  done
  find_names="${find_names% -o}"  # 去掉尾部 -o

  # ── Layer 1+2: Containers + Application Support 单次扫描 ──
  echo -e "\n  ${BOLD}[Containers + Application Support]${NC}"
  local found_count=0
  local scan_dirs="$HOME/Library/Containers $HOME/Library/Application Support"

  # 单次 find，maxdepth 4 覆盖三层子目录
  local raw_results
  raw_results=$(eval "find $scan_dirs -maxdepth 4 -type d \\( $find_names \\)" 2>/dev/null || true)

  if [ -n "$raw_results" ]; then
    # 按所属应用分组
    local prev_app=""
    local group_total=0
    local group_items=""

    while IFS= read -r cache_path; do
      [ -d "$cache_path" ] || continue

      # 判断所属层
      local layer="" app_segment="" display_name=""
      case "$cache_path" in
        */Containers/*)
          layer="containers"
          app_segment=$(echo "$cache_path" | sed "s|$HOME/Library/Containers/||" | cut -d'/' -f1)
          display_name="$app_segment"
          is_in_list "$app_segment" "$covered_containers" && continue
          ;;
        */Application\ Support/*)
          layer="appsupport"
          app_segment=$(echo "$cache_path" | sed "s|$HOME/Library/Application Support/||" | cut -d'/' -f1)
          display_name="$app_segment"
          contains_in_list "$app_segment" "$covered_as" && continue
          ;;
        *) continue ;;
      esac

      local sz
      sz=$(size_of "$cache_path")
      [ "$sz" -gt "$min_size" ] || continue

      local rel="${cache_path#"$HOME/Library/$layer/"}"
      echo -e "    ${GREEN}●${NC} ${BOLD}$display_name${NC}: ${DIM}$(human_size $sz)  $rel${NC}"

      if confirm "清除 $display_name 的 $rel ?"; then
        local before=$sz
        cache_remove "$cache_path"
        local after
        after=$(size_of "$cache_path")
        calc_freed "$before" "$after"
      fi
      ((found_count++)) || true
    done <<< "$raw_results"
  fi

  [ "$found_count" -eq 0 ] && echo -e "  ${DIM}无新增发现${NC}"

  # ── Layer 3: Home dotfiles ──
  echo -e "\n  ${BOLD}[Home dotfiles]${NC}"
  local dot_found=0

  for dotdir in "$HOME"/.*/ ; do
    [ -d "$dotdir" ] || continue
    local dn
    dn=$(basename "$dotdir")
    is_in_list "$dn" "$covered_dots" && continue

    # 快速检查: 是否有缓存子目录且够大
    for cn in "${cache_names[@]}"; do
      local candidate="$dotdir$cn"
      if [ -d "$candidate" ]; then
        local sz
        sz=$(size_of "$candidate")
        if [ "$sz" -gt "$min_size" ]; then
          echo -e "    ${GREEN}●${NC} ${BOLD}~/$dn/$cn${NC}: $(human_size $sz)"
          if confirm "清除 ~/$dn/$cn ?"; then
            local before=$sz
            cache_remove "$candidate"
            local after
            after=$(size_of "$candidate")
            calc_freed "$before" "$after"
          fi
          dot_found=1
        fi
      fi
    done
  done

  # ~/.cache 子目录
  if [ -d "$HOME/.cache" ]; then
    for sub in "$HOME/.cache"/*/; do
      [ -d "$sub" ] || continue
      local sn
      sn=$(basename "$sub")
      [ "$sn" = "rod" ] && continue
      local sz
      sz=$(size_of "$sub")
      if [ "$sz" -gt "$min_size" ]; then
        echo -e "    ${YELLOW}~/.cache/$sn${NC}: $(human_size $sz)"
        if confirm "清除 ~/.cache/$sn ?"; then
          local before=$sz
          cache_remove "$sub"
          local after
          after=$(size_of "$sub")
          calc_freed "$before" "$after"
          dot_found=1
        fi
      fi
    done
  fi

  [ "$dot_found" -eq 0 ] && echo -e "  ${DIM}无新增发现${NC}"

  report_section
}


# ────────────────────────────────────────────────────────────────────────────
# 16. 不活跃项目的编译产物 (--stale-projects)
#     背景: 长期不碰的项目中 node_modules/dist/.next/.venv 等白白占用空间
#     策略: 扫描代码目录，找出 10 天以上未修改的项目，清理可重建的编译产物
#     安全: 所有产物均可通过包管理器或构建命令完整重建
#     数据源: STALE_PROJECT_DIR, STALE_DAYS, STALE_ARTIFACT_DEFS (cleanup-data.sh)
# ────────────────────────────────────────────────────────────────────────────
cleanup_stale_projects() {
  section "不活跃项目编译产物"

  # 数据层配置
  local stale_project_dir_tmpl="${STALE_PROJECT_DIR:-\$HOME/Code}"
  local code_dir
  eval "code_dir=\"$stale_project_dir_tmpl\""
  if [ ! -d "$code_dir" ]; then
    echo -e "  ${CYAN}[跳过]${NC} $code_dir 目录不存在"
    return
  fi

  local stale_days="${STALE_DAYS:-10}"

  # 查找 10+ 天不活跃的一级项目目录
  local stale_projects
  stale_projects=$(find "$code_dir" -maxdepth 1 -mindepth 1 -type d -mtime +${stale_days} 2>/dev/null | sort)

  if [ -z "$stale_projects" ]; then
    echo -e "  ${CYAN}[跳过]${NC} 所有项目均在 ${stale_days} 天内活跃"
    return
  fi

  local project_count
  project_count=$(echo "$stale_projects" | wc -l | tr -d ' ')
  echo -e "  发现 ${project_count} 个项目超过 ${stale_days} 天未修改"
  echo -e "  ${DIM}扫描编译产物: node_modules, dist, .next, .venv, .turbo 等${NC}"
  echo ""

  # 编译产物类型 — 数据源: STALE_ARTIFACT_DEFS (cleanup-data.sh)
  local artifact_defs=()
  if [ ${#STALE_ARTIFACT_DEFS[@]} -gt 0 ] 2>/dev/null; then
    artifact_defs=("${STALE_ARTIFACT_DEFS[@]}")
  fi

  local total_project_freed=0

  while IFS= read -r project; do
    [ -d "$project" ] || continue
    local proj_name
    proj_name=$(basename "$project")

    # 获取最后修改日期 (macOS stat)
    local mdate
    mdate=$(stat -f '%Sm' -t '%Y-%m-%d' "$project" 2>/dev/null || echo "unknown")

    # 扫描该项目中的编译产物
    local project_artifacts=""
    local project_total=0

    for art_def in "${artifact_defs[@]}"; do
      IFS='|' read -r art_dir art_display <<< "$art_def"
      local art_path="$project/$art_dir"
      if [ -d "$art_path" ]; then
        local sz
        sz=$(size_of "$art_path")
        if [ "$sz" -gt 5120 ]; then  # > 5 MB
          project_artifacts="$project_artifacts|$art_path|$art_display|$sz"
          project_total=$((project_total + sz))
        fi
      fi
    done

    # 也扫描二级 node_modules（monorepo 子包）
    local nested_nm
    nested_nm=$(find "$project" -maxdepth 3 -name "node_modules" -type d -not -path "$project/node_modules" 2>/dev/null || true)
    if [ -n "$nested_nm" ]; then
      while IFS= read -r nm_path; do
        [ -d "$nm_path" ] || continue
        local sz
        sz=$(size_of "$nm_path")
        if [ "$sz" -gt 5120 ]; then
          local rel="${nm_path#"$project/"}"
          project_artifacts="$project_artifacts|$nm_path|$rel (嵌套 node_modules)|$sz"
          project_total=$((project_total + sz))
        fi
      done <<< "$nested_nm"
    fi

    # 如果有可清理的产物
    if [ "$project_total" -gt 0 ]; then
      echo -e "  ${BOLD}$proj_name${NC} ${DIM}(最后修改: $mdate)${NC}"

      # 逐项显示
      local IFS_BAK="$IFS"
      IFS='|'
      set -f
      local parts=($project_artifacts)
      set +f
      IFS="$IFS_BAK"

      local i=1
      while [ $i -lt ${#parts[@]} ]; do
        local p_path="${parts[$i]}"
        local p_name="${parts[$((i+1))]}"
        local p_sz="${parts[$((i+2))]}"
        echo -e "    $p_name: $(human_size $p_sz)"
        i=$((i + 3))
      done

      echo -e "    ${YELLOW}合计: $(human_size $project_total)${NC}"

      if confirm "清理 $proj_name 的编译产物? (可通过包管理器/构建命令重建)"; then
        i=1
        while [ $i -lt ${#parts[@]} ]; do
          local p_path="${parts[$i]}"
          local before
          before=$(size_of "$p_path")
          cache_remove "$p_path"
          local after
          after=$(size_of "$p_path")
          calc_freed "$before" "$after"
          i=$((i + 3))
        done
        total_project_freed=$((total_project_freed + project_total))
      fi
      echo ""
    fi
  done <<< "$stale_projects"

  # 额外：xcuserdata（始终安全，Xcode 用户界面状态）
  local xcud
  xcud=$(find "$code_dir" -name "xcuserdata" -type d 2>/dev/null || true)
  if [ -n "$xcud" ]; then
    local xcud_total=0
    while IFS= read -r xcud_dir; do
      [ -d "$xcud_dir" ] || continue
      local sz
      sz=$(size_of "$xcud_dir")
      xcud_total=$((xcud_total + sz))
    done <<< "$xcud"

    if [ "$xcud_total" -gt 1024 ]; then
      echo -e "  Xcode xcuserdata (用户界面状态): $(human_size $xcud_total)"
      if confirm "清除所有 xcuserdata? (不影响项目代码和构建设置)"; then
        while IFS= read -r xcud_dir; do
          [ -d "$xcud_dir" ] || continue
          local before
          before=$(size_of "$xcud_dir")
          cache_remove "$xcud_dir"
          local after
          after=$(size_of "$xcud_dir")
          calc_freed "$before" "$after"
        done <<< "$xcud"
      fi
    fi
  fi

  report_section
}


# ────────────────────────────────────────────────────────────────────────────
# 17. iOS 模拟器 dyld 缓存 (/Library/Developer/CoreSimulator/Caches)
#     背景: Xcode 为模拟器预构建 dyld 共享缓存以加速启动，通常 2~3 GB
#     安全: 下次启动模拟器时自动重建，需要 sudo 权限
# ────────────────────────────────────────────────────────────────────────────
cleanup_simulator_caches() {
  section "iOS 模拟器 dyld 缓存"

  local sim_caches="/Library/Developer/CoreSimulator/Caches"
  if [ ! -d "$sim_caches" ]; then
    echo -e "  ${CYAN}[跳过]${NC} 目录不存在（可能未安装 Xcode）"
    return
  fi

  local sz
  sz=$(size_of "$sim_caches")
  if [ "$sz" -le 10240 ]; then
    echo -e "  ${CYAN}[跳过]${NC} 缓存很小 ($(human_size $sz))"
    return
  fi

  echo -e "  dyld 共享缓存: $(human_size $sz)"
  echo -e "  ${DIM}包含模拟器预链接的系统框架，删除后首次启动模拟器会较慢（自动重建）${NC}"

  if confirm "清除 iOS 模拟器 dyld 缓存? (需要 sudo)"; then
    if $DRY_RUN; then
      echo -e "  ${YELLOW}[dry-run]${NC} 将清除: $sim_caches/dyld"
    else
      if sudo -n true 2>/dev/null; then
        local before=$sz
        sudo rm -rf "$sim_caches/dyld" 2>/dev/null && \
          echo -e "  ${GREEN}[✓]${NC} 已清除模拟器 dyld 缓存" || \
          echo -e "  ${RED}[✗]${NC} 清除失败"
        local after
        after=$(size_of "$sim_caches")
        calc_freed "$before" "$after"
      else
        echo -e "  ${YELLOW}[!]${NC} 需要 sudo 权限，跳过（可手动执行: sudo rm -rf $sim_caches/dyld）"
      fi
    fi
  fi

  report_section
}



# ────────────────────────────────────────────────────────────────────────────
# 16. 手动操作提醒
#     背景: 部分清理目标受 SIP 保护或需要 GUI 操作，脚本无法自动处理
#     职责: 仅展示操作指引和原理说明，不执行任何删除
#     数据: MANUAL_REMINDERS 数组（Tier 1 定义基础，Tier 2 追加用户条目）
# ────────────────────────────────────────────────────────────────────────────
cleanup_manual_reminders() {
  # 无提醒条目时跳过
  [ "${#MANUAL_REMINDERS[@]}" -eq 0 ] 2>/dev/null && return 0

  section "手动操作提醒 (需 GUI / SIP 保护)"
  echo -e "  ${DIM}以下条目无法自动清理，请按指引手动操作${NC}"
  echo ""

  local idx=0
  for reminder in "${MANUAL_REMINDERS[@]}"; do
    IFS='|' read -r r_path r_name r_size r_how r_why <<< "$reminder"
    idx=$((idx + 1))

    # 检查路径是否存在
    local exists=""
    if [ -e "$r_path" ]; then
      exists="${GREEN}[存在]${NC}"
    else
      exists="${DIM}[已清理]${NC}"
    fi

    echo -e "  ${BOLD}${idx}. $r_name${NC}  $exists  ${YELLOW}~$r_size${NC}"
    echo -e "     ${CYAN}操作:${NC} $r_how"
    echo -e "     ${DIM}原理: $r_why${NC}"
    echo ""
  done

  echo -e "  ${DIM}提示: 清理后可从 ~/.mac-cleanup/data.txt 中删除对应条目${NC}"
}

# ============================================================================
#  MAIN — 注册所有清理项（按推荐执行顺序）
# ============================================================================

echo ""
echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
echo -e "${BOLD}║     macOS 系统清理脚本 v1.0.0       ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
echo ""
$DRY_RUN && echo -e "${YELLOW}[预览模式] 不会执行任何实际操作${NC}"
$AUTO_YES && echo -e "${YELLOW}[自动模式] 所有项目将自动执行${NC}"
$DISCOVER && echo -e "${YELLOW}[发现模式] 常规清理后将执行自动扫描${NC}"
echo ""

# ── 逐项执行 ──
cleanup_code_sign_clone     # 已卸载 App 签名缓存  (今天发现的 9.6G)
cleanup_docker              # Docker 未用资源 + 下载残留 + 日志
cleanup_xcode               # Xcode DerivedData / Previews / 模拟器
cleanup_editor_caches       # TRAE / VS Code 日志与缓存
cleanup_homebrew            # Homebrew 旧版本
cleanup_npm                 # npm 缓存 + npx 缓存 + 日志
cleanup_pnpm                # pnpm store 修剪
cleanup_system_caches       # ~/Library/Caches 浏览器/工具缓存
cleanup_app_caches           # Telegram/腾讯会议/QQ/同花顺/腾讯文档/Obsidian 等
cleanup_orphan_ids           # 已卸载 App 的孤儿数据（bundle id 级，需先审计）
cleanup_glob_caches          # Glob 模式清理 (QQ zip/同花顺日志)
cleanup_multi_user_caches    # 多用户目录遍历 (腾讯文档)
cleanup_logs                # 应用日志
cleanup_crash_reports       # 崩溃报告
cleanup_stale_projects      # 不活跃项目编译产物 (~/Code 中 10+ 天不活跃)
cleanup_simulator_caches     # iOS 模拟器 dyld 缓存 (需要 sudo)
cleanup_auto_discover        # 自动发现 (--discover 时激活)
cleanup_manual_reminders     # 手动操作提醒 (SIP/GUI)
cleanup_trash               # 废纸篓

# ── 汇总 ──
echo ""
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if $DRY_RUN; then
  echo -e "${BOLD}  预览完成 — 以上标记的项目可被清理${NC}"
else
  echo -e "${BOLD}  清理完成 — 共释放约 $(human_size $TOTAL_FREED)${NC}"
fi
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "提示: 废纸篓中的文件需在 Finder 中清空废纸篓后才真正释放磁盘空间。"
echo ""
