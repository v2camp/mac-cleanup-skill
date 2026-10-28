#!/usr/bin/env bash
# ============================================================================
#  macOS 孤儿残留审计 — app-orphans.sh
#
#  只读工具：不删文件、不写 data.txt（除非显式 --emit-rules）。
#
#  解决的问题
#    引擎原有的 ORPHAN_RULES 判据是「/Applications 中无同名 .app」——
#    名字子串既会误判（Google 命中 Chrome 与 Drive），也会漏判
#    （bundle id 命名的目录永远匹配不上）。
#
#  本脚本改用「声明减法」：
#    1. 声明集 C = LaunchServices 中磁盘上仍存在的 bundle
#                 ∪ /Applications 与 ~/Applications 的 CFBundleIdentifier
#                 ∪ com.apple.*（系统身份，永不算孤儿）
#    2. 候选集 A = Library 下名字形如 bundle id 的条目
#    3. 孤儿 = A − C，再用「相关 bundle / 组件后缀 / 静默期」降级
#
#  置信度
#    A  有卸载证据：LaunchServices 记录已失效（磁盘上找不到该 bundle）
#    B  仅目录残留：无卸载证据，只能证明「当前没有同名 bundle 在盘上」
#    C  不建议处理：系统身份、与现存 bundle 相关、组件/助程序、静默期内被改写
#
#  安全不变式
#    声明集构建不完整（lsregister 失败且未提供 claim 文件）时，
#    所有候选降为 C 并明确告警——宁可报零，不可报猜。
#
#  用法
#    ./scripts/app-orphans.sh                  # 审计并打印报告（只读）
#    ./scripts/app-orphans.sh --top 40         # 明细多显示一些
#    ./scripts/app-orphans.sh --min-conf A      # 只看有卸载证据的
#    ./scripts/app-orphans.sh --emit-rules     # 把 A 级写成 ORPHAN_ID_RULES 追加到
#                                              #   ~/.mac-cleanup/data.txt（引擎执行仍需 dry-run）
#    ./scripts/app-orphans.sh --verify ID...   # 给引擎用：判定若干 id 是否仍存活
#
#  环境变量（测试用）
#    ORPHAN_LIBRARY_OVERRIDE  替换 ~/Library 根，指向 fixture
#    ORPHAN_CLAIM_FILE        直接用给定文件作声明集，跳过 lsregister
#    ORPHAN_LS_DUMP           解析给定的 lsregister dump，不实际调用
#    ORPHAN_QUIET_DAYS        静默期天数（默认 30）
#    ORPHAN_MIN_KB            报告最小体积（默认 1024）
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

LIB="${ORPHAN_LIBRARY_OVERRIDE:-$HOME/Library}"
QUIET_DAYS="${ORPHAN_QUIET_DAYS:-30}"
MIN_KB="${ORPHAN_MIN_KB:-1024}"
TOP_N=20
MIN_CONF="B"
MODE="report"
TSV_OUT=""
USE_LS=true

USER_DATA_DIR="$HOME/.mac-cleanup"
USER_DATA_FILE="${ORPHAN_DATA_FILE:-$USER_DATA_DIR/data.txt}"
REPORT_DIR="${ORPHAN_REPORT_DIR:-$USER_DATA_DIR/reports}"
SKIP_APP_SCAN="${ORPHAN_SKIP_APP_SCAN:-0}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/app-orphans.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

CLAIM="$TMP/claim.txt"
TEAMS="$TMP/teams.txt"
STALE="$TMP/stale.tsv"
CAND="$TMP/candidates.tsv"
CLASSIFIED="$TMP/classified.tsv"
FINAL="$TMP/final.tsv"

if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; DIM=''; NC=''
fi

# ── 参数 ─────────────────────────────────────────────────────────────────────
VERIFY_IDS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --top)        TOP_N="${2:-20}"; shift 2 ;;
    --min-conf)   MIN_CONF="${2:-B}"; shift 2 ;;
    --tsv)        TSV_OUT="${2:-}"; shift 2 ;;
    --quiet-days) QUIET_DAYS="${2:-30}"; shift 2 ;;
    --emit-rules) MODE="emit"; shift ;;
    --verify)     MODE="verify"; shift
                  while [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; do
                    VERIFY_IDS+=("$1"); shift
                  done ;;
    --no-ls)      USE_LS=false; shift ;;
    -h|--help)    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)            echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

NOW=$(date +%s)
QUIET_SEC=$((QUIET_DAYS * 86400))

# 置信度排序：A 最高
conf_rank() {
  case "$1" in A) echo 1 ;; B) echo 2 ;; *) echo 3 ;; esac
}

human_size() {
  local kb="${1:-0}"
  [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
  if   (( kb >= 1048576 )); then echo "$((kb/1048576)).$(( (kb%1048576)*10/1048576 )) GB"
  elif (( kb >= 1024 ));    then echo "$((kb/1024)).$(( (kb%1024)*10/1024 )) MB"
  else                           echo "${kb} KB"
  fi
}

short_path() {
  local p="$1"
  printf '%s' "${p/#$HOME/~}"
}

# ── 1. 声明集 ────────────────────────────────────────────────────────────────
# 输出两份：CLAIM（存活 bundle id，一行一个）/ STALE（已失效 id<TAB>原路径）
build_claim() {
  : > "$CLAIM"
  : > "$TEAMS"
  : > "$STALE"

  if [ -n "${ORPHAN_CLAIM_FILE:-}" ] && [ -f "${ORPHAN_CLAIM_FILE}" ]; then
    sort -u "$ORPHAN_CLAIM_FILE" > "$CLAIM"
    return 0
  fi

  local dump="$TMP/ls.dump"
  if $USE_LS; then
    if [ -n "${ORPHAN_LS_DUMP:-}" ] && [ -f "${ORPHAN_LS_DUMP}" ]; then
      dump="$ORPHAN_LS_DUMP"
    else
      "$LSREG" -dump > "$dump" 2>/dev/null || : > "$dump"
    fi
    if [ -s "$dump" ]; then
      # 单次遍历切分 bundle 块：失效块（fnfErr）进 STALE，其余进 live（id + teamID）
      awk -v live="$TMP/ls-live.tsv" -v stale="$TMP/ls-stale.tsv" '
        function flush(   ) {
          if (cur_id == "") return
          if (is_stale) print cur_id "\t" cur_path > stale
          else          print cur_id "\t" cur_team > live
          cur_id = ""; cur_path = ""; cur_team = ""; is_stale = 0
        }
        /^bundle id:/ { flush() }
        /^Bundle node not found on disk/ { is_stale = 1 }
        /^identifier:[ \t]/ {
          if (cur_id == "") { v = $0; sub(/^identifier:[ \t]+/, "", v); cur_id = v }
        }
        /^teamID:[ \t]/ {
          if (cur_team == "") { v = $0; sub(/^teamID:[ \t]+/, "", v); cur_team = v }
        }
        /^path:[ \t]/ {
          if (cur_path == "") {
            v = $0; sub(/^path:[ \t]+/, "", v); sub(/ \(0x[0-9a-fA-F]+\)$/, "", v); cur_path = v
          }
        }
        END { flush() }
      ' "$dump"
      if [ -s "$TMP/ls-live.tsv" ]; then
        cut -f1 "$TMP/ls-live.tsv" | sort -u >> "$CLAIM"
        cut -f2 "$TMP/ls-live.tsv" | grep -v '^$' | sort -u >> "$TEAMS" || true
      fi
      [ -s "$TMP/ls-stale.tsv" ] && cat "$TMP/ls-stale.tsv" >> "$STALE"
    fi
  fi

  # /Applications 与 ~/Applications 兜底：即使 LaunchServices 库损坏也能拿到在装身份
  if [ "$SKIP_APP_SCAN" != "1" ]; then
    local app id
    for app in /Applications/*.app "$HOME/Applications"/*.app; do
      [ -d "$app" ] || continue
      id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
            "$app/Contents/Info.plist" 2>/dev/null) || id=""
      [ -n "$id" ] && printf '%s\n' "$id" >> "$CLAIM"
    done
  fi

  sort -u -o "$CLAIM" "$CLAIM"
}

# ── 2. 候选集 ────────────────────────────────────────────────────────────────
is_id_shaped() {
  local id="$1"
  [ ${#id} -ge 5 ] || return 1
  # 必须至少一段点分；用 bash 内建匹配，避免每条候选 fork 一次 grep
  [[ "$id" =~ ^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+$ ]]
}

scan_root() {
  local dir="$1" suffix="$2" kind="$3"
  [ -d "$dir" ] || return 0
  compgen -G "$dir/*" >/dev/null 2>&1 || return 0

  local mtime p name id
  # 一次 stat 拿到全部 mtime，避免逐条 fork
  stat -f '%m %N' "$dir"/* 2>/dev/null | while IFS= read -r line; do
    mtime="${line%% *}"
    p="${line#* }"
    name="${p##*/}"
    id="$name"
    if [ -n "$suffix" ]; then id="${name%"$suffix"}"; fi
    is_id_shaped "$id" || continue
    printf '%s\t%s\t%s\t%s\n' "$id" "$kind" "$p" "$mtime"
  done
}

scan_candidates() {
  : > "$CAND"
  local spec dir suffix
  for spec in \
    "$LIB/Caches|" \
    "$LIB/Containers|" \
    "$LIB/Group Containers|" \
    "$LIB/Application Scripts|" \
    "$LIB/HTTPStorages|.binarycookies" \
    "$LIB/WebKit|" \
    "$LIB/Preferences|.plist" \
    "$LIB/Saved Application State|.savedState" \
    "$LIB/LaunchAgents|.plist" \
  ; do
    dir="${spec%%|*}"; suffix="${spec##*|}"
    scan_root "$dir" "$suffix" "${dir##*/}"
  done >> "$CAND"
  sort -u -o "$CAND" "$CAND"
}

# ── 3. 分类 ──────────────────────────────────────────────────────────────────
classify() {
  : > "$CLASSIFIED"
  [ -s "$CAND" ] || return 0

  # 声明集不可用 → 全部降级为 C（安全不变式）
  local degraded=0
  [ -s "$CLAIM" ] || degraded=1

  # A 级证据强（LaunchServices 明确记录该 bundle 已不在磁盘），静默期可缩短；
  # B 级只有「目录还在」，必须用完整静默期兜底，防误删 CLI 工具的数据目录。
  local a_quiet_days=$QUIET_DAYS
  [ "$a_quiet_days" -gt 7 ] && a_quiet_days=7
  local a_quiet_sec=$((a_quiet_days * 86400))

  awk -F'\t' -v OFS='\t' \
      -v now="$NOW" -v quiet="$QUIET_SEC" -v aquiet="$a_quiet_sec" -v trashpre="$HOME/.Trash/" \
      -v degraded="$degraded" '
    function norm(x,   y) {
      y = x
      if (y ~ /^group\./) y = substr(y, 7)
      if (y ~ /^[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]\./) y = substr(y, 12)
      return y
    }
    function iscomp(x,   n,a,i) {
      n = split("helper agent daemon service xpc widget plugin extension login launcher updater installer uninstaller renderer gpu", a, " ")
      for (i = 1; i <= n; i++) if (x ~ ("[.]" a[i] "$")) return 1
      return 0
    }
    FILENAME == ARGV[1] { if ($1 != "") claim[$1] = 1; next }
    FILENAME == ARGV[2] { if ($1 != "") stale[$1] = $2; next }
    FILENAME == ARGV[3] { if ($1 != "") team[$1] = 1; next }
    {
      id = $1; kind = $2; path = $3; mt = $4 + 0
      key = norm(id)

      if (degraded) { print id, kind, path, mt, "C", "no-claim", "声明集不可用"; next }

      if (id ~ /^com[.]apple[.]/ || key ~ /^com[.]apple[.]/) {
        print id, kind, path, mt, "C", "system", "系统身份"; next
      }
      if ((id in claim) || (key in claim)) next

      ev = ""; sp = ""
      if (key in stale)      { ev = "stale"; sp = stale[key] }
      else if (id in stale)  { ev = "stale"; sp = stale[id] }
      if (ev != "" && trashpre != "" && index(sp, trashpre) == 1) ev = "trash"

      # 共享容器：<10 位 TeamID>.xxx 或 group.xxx
      # 只能靠 TeamID 归属判断，不能靠名字——同厂商兄弟应用会共用同一容器。
      tpre = ""
      if (id ~ /^[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][.]/) tpre = substr(id, 1, 10)
      if (ev == "" && (id ~ /^group[.]/ || (tpre != "" && (tpre in team)))) {
        print id, kind, path, mt, "C", "shared", "共享容器，归属不明"; next
      }
      if (ev != "" && tpre != "" && (tpre in team)) ev = ev "-shared"

      rel = 0
      for (c in claim) {
        if (index(c, id ".") == 1 || index(id, c ".") == 1 ||
            index(c, key ".") == 1 || index(key, c ".") == 1) { rel = 1; break }
      }
      if (rel) { print id, kind, path, mt, "C", "related", "与现存 bundle 相关"; next }
      if (iscomp(id)) { print id, kind, path, mt, "C", "component", "组件或助程序"; next }

      if (ev != "") {
        if ((now - mt) < aquiet) { print id, kind, path, mt, "C", "recent", "卸载证据存在，但静默期内被改写"; next }
        print id, kind, path, mt, "A", ev, sp
      } else {
        if ((now - mt) < quiet) { print id, kind, path, mt, "C", "recent", "静默期内被改写"; next }
        print id, kind, path, mt, "B", "dir-only", ""
      }
    }
  ' "$CLAIM" "$STALE" "$TEAMS" "$CAND" > "$CLASSIFIED"
}

# ── 4. 体积与排序 ────────────────────────────────────────────────────────────
measure() {
  : > "$FINAL"

  # 只对 A/B 求体积：C 不进清理候选，不值得花 du 的时间
  local paths=() conf id kind path mt ev note
  while IFS=$'\t' read -r id kind path mt conf ev note; do
    [ "$conf" = "A" ] || [ "$conf" = "B" ] || continue
    paths+=("$path")
  done < "$CLASSIFIED"

  if [ ${#paths[@]} -eq 0 ]; then
    awk -F'\t' -v OFS='\t' '{ print $5, "0", $1, $2, $6, $3, $7 }' "$CLASSIFIED" > "$FINAL"
    return 0
  fi

  # 分批 du，避免参数过长；两次输出统一成 size<TAB>path
  local batch=() i=0
  : > "$TMP/du.tsv"
  for path in "${paths[@]}"; do
    batch+=("$path")
    i=$((i + 1))
    if [ ${#batch[@]} -ge 200 ]; then
      du -sk "${batch[@]}" 2>/dev/null >> "$TMP/du.tsv" || true
      batch=()
    fi
  done
  if [ ${#batch[@]} -gt 0 ]; then
    du -sk "${batch[@]}" 2>/dev/null >> "$TMP/du.tsv" || true
  fi

  awk -F'\t' -v OFS='\t' '
    FILENAME == ARGV[1] { sz[$2] = $1; next }
    { print $5, (($3 in sz) ? sz[$3] : 0), $1, $2, $6, $3, $7 }
  ' "$TMP/du.tsv" "$CLASSIFIED" > "$FINAL"

  sort -t "$(printf '\t')" -k2,2nr -k1,1 "$FINAL" -o "$FINAL"
}

# ── 5. 输出 ──────────────────────────────────────────────────────────────────
report() {
  local n_cand n_claim a_n b_n c_n a_kb b_kb
  n_cand=$(wc -l < "$CAND" | tr -d ' ')
  n_claim=$(wc -l < "$CLAIM" | tr -d ' ')
  a_n=$(awk -F'\t' '$1=="A"' "$FINAL" | wc -l | tr -d ' ')
  b_n=$(awk -F'\t' '$1=="B"' "$FINAL" | wc -l | tr -d ' ')
  c_n=$(awk -F'\t' '$1=="C"' "$FINAL" | wc -l | tr -d ' ')
  a_kb=$(awk -F'\t' '$1=="A"{s+=$2} END{print s+0}' "$FINAL")
  b_kb=$(awk -F'\t' '$1=="B"{s+=$2} END{print s+0}' "$FINAL")

  echo ""
  echo -e "${BOLD}${CYAN}━━━ 已卸载 App 的孤儿数据审计（只读）━━━${NC}"
  echo -e "  ${DIM}声明集 $n_claim 个 bundle id ／ 候选 $n_cand 条${NC}"
  echo ""
  echo -e "  ${GREEN}A 级${NC} 有卸载证据（LaunchServices 记录已失效）  ${BOLD}$a_n${NC} 项  $(human_size "$a_kb")"
  echo -e "  ${YELLOW}B 级${NC} 仅目录残留（无卸载证据）                ${BOLD}$b_n${NC} 项  $(human_size "$b_kb")"
  echo -e "  ${DIM}C 级${NC} 不建议处理（系统/相关/组件/近改）        $c_n 项"

  local threshold
  threshold=$(conf_rank "$MIN_CONF")

  echo ""
  echo -e "${BOLD}明细（按体积降序，最多 $TOP_N 条）${NC}"

  local shown=0 conf size id kind ev path note tag
  while IFS=$'\t' read -r conf size id kind ev path note; do
    [ "$(conf_rank "$conf")" -le "$threshold" ] || continue
    [ "$conf" = "C" ] && continue
    [ "${size:-0}" -ge "$MIN_KB" ] || continue
    shown=$((shown + 1))
    [ "$shown" -gt "$TOP_N" ] && break

    case "$conf" in
      A) tag="${GREEN}A${NC}" ;;
      *) tag="${YELLOW}B${NC}" ;;
    esac
    case "$ev" in
      trash)    ev_txt="LaunchServices 记录指向废纸篓" ;;
      stale)    ev_txt="LaunchServices 记录已失效" ;;
      *-shared) ev_txt="有卸载证据，但属同厂商共享容器，需人工确认" ;;
      dir-only) ev_txt="无卸载证据，仅目录残留" ;;
      *)        ev_txt="$ev" ;;
    esac

    printf "  %b  %-9s %s\n" "$tag" "$(human_size "${size:-0}")" "$id"
    printf "      %s  ${DIM}[%s · %s]${NC}\n" "$(short_path "$path")" "$kind" "$ev_txt"
    if [ -n "$note" ]; then
      printf "      ${DIM}原位置: %s${NC}\n" "$(short_path "$note")"
    fi
  done < "$FINAL"

  if [ "$shown" -eq 0 ]; then
    echo -e "  ${DIM}（无符合条件的项）${NC}"
  fi

  echo ""
  echo -e "  ${DIM}A/B 级合计: $(human_size $((a_kb + b_kb)))；B 级需人工确认后再处理${NC}"
  echo -e "  ${DIM}判定依据是「是否可重建」，不是「占多大」。聊天记录、离线邮件、许可证${NC}"
  echo -e "  ${DIM}都在 L2 层，本工具只报告，不自动删除。${NC}"
}

write_tsv() {
  local out="${TSV_OUT:-$REPORT_DIR/app-orphans-$(date +%Y%m%d-%H%M%S).tsv}"
  mkdir -p "$(dirname "$out")"
  {
    printf 'confidence\tsize_kb\tbundle_id\tlocation\tevidence\tpath\toriginal_path\n'
    cat "$FINAL"
  } > "$out"
  echo ""
  echo -e "  报告: ${CYAN}$(short_path "$out")${NC}"
}

emit_rules() {
  mkdir -p "$USER_DATA_DIR"
  local stage="$TMP/emit.txt"
  awk -F'\t' -v home="$HOME" -v min="$MIN_KB" '
    $1 == "A" && $2 + 0 >= min && $5 !~ /shared/ {
      if (!($3 in paths)) { order[++n] = $3 }
      p = $6
      if (index(p, home "/") == 1) p = "\\$HOME" substr(p, length(home) + 1)
      paths[$3] = (paths[$3] == "" ? p : paths[$3] "," p)
    }
    END {
      for (i = 1; i <= n; i++) {
        id = order[i]
        print "  \"" id "|" id "|" paths[id] "\""
      }
    }
  ' "$FINAL" > "$stage"

  if [ ! -s "$stage" ]; then
    echo ""
    echo -e "  ${YELLOW}没有 A 级候选可写入。${NC}"
    return 0
  fi

  # 已写入过的 id 不重复追加（Tier 1 已声明 ORPHAN_ID_RULES=()，此处只用 +=）
  local line id
  : > "$TMP/emit-new.txt"
  while IFS= read -r line; do
    id="${line#  \"}"
    id="${id%%|*}"
    if [ -f "$USER_DATA_FILE" ] && grep -qF "\"$id|" "$USER_DATA_FILE" 2>/dev/null; then
      continue
    fi
    printf '%s\n' "$line" >> "$TMP/emit-new.txt"
  done < "$stage"

  if [ ! -s "$TMP/emit-new.txt" ]; then
    echo ""
    echo -e "  ${DIM}这些 id 已存在于 data.txt，无需重复写入。${NC}"
    return 0
  fi

  {
    echo ""
    echo "# ── 孤儿 bundle id（app-orphans.sh --emit-rules $(date +%Y-%m-%d)）──"
    echo "# 引擎执行前会再次确认该 id 无存活 bundle；删除走废纸篓。"
    echo "ORPHAN_ID_RULES+=("
    cat "$TMP/emit-new.txt"
    echo ")"
  } >> "$USER_DATA_FILE"

  local cnt
  cnt=$(wc -l < "$TMP/emit-new.txt" | tr -d ' ')
  echo ""
  echo -e "  ${GREEN}已写入 $cnt 条规则${NC} → $(short_path "$USER_DATA_FILE")"
  echo -e "  ${DIM}下一步: ./mac-cleanup.sh -n 预览（删除走废纸篓）${NC}"
}

verify() {
  local id key live
  for id in "${VERIFY_IDS[@]}"; do
    key="$id"
    case "$key" in group.*) key="${key#group.}" ;; esac
    # group container 常带 10 位 TeamID 前缀（88L2Q4487U.com.x.y）
    if [[ "$key" =~ ^[A-Z0-9]{10}\. ]]; then key="${key:11}"; fi
    live=orphan
    if grep -Fxq "$id" "$CLAIM" 2>/dev/null || grep -Fxq "$key" "$CLAIM" 2>/dev/null; then
      live=live
    else
      # 与现存 bundle 构成父子关系时同样视为存活（宿主或组件仍在）
      if awk -v id="$id" -v key="$key" '
          index($0, id ".") == 1 || index(id, $0 ".") == 1 ||
          index($0, key ".") == 1 || index(key, $0 ".") == 1 { found = 1; exit }
          END { exit(found ? 0 : 1) }
        ' "$CLAIM" 2>/dev/null; then
        live=live
      fi
    fi
    printf '%s\t%s\n' "$id" "$live"
  done
}

# ── 主流程 ───────────────────────────────────────────────────────────────────
build_claim

if [ "$MODE" = "verify" ]; then
  verify
  exit 0
fi

scan_candidates
classify
measure

case "$MODE" in
  emit)   report; write_tsv; emit_rules ;;
  *)      report; write_tsv
          echo -e "  ${DIM}确认无误后可: ./scripts/app-orphans.sh --emit-rules${NC}" ;;
esac

echo ""
