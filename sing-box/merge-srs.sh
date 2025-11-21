#!/usr/bin/env bash
# ============================================================================
# merge-srs-unified.sh - Sing-box 规则集合并脚本 (生产级整合版)
# ============================================================================
# 版本: 2.0.0
# 作者: AI Generated (基于merge-srs.sh + merge_srs_final.sh)
#
# 主要改进:
# - 修复所有已知bug (文件锁、时间戳、数据丢失)
# - 优化并发性能 (分阶段处理、智能锁机制)
# - 完善错误处理 (详细日志、自动恢复)
# - 模块化设计 (函数解耦、配置外置)
# - 临时文件优化 (自动清理、失败回滚)
# ============================================================================

set -euo pipefail

# ============================================================================
# 第一部分: 环境检测与初始化
# ============================================================================

# [必需] 检查 Bash 版本 (需要 4.3+ 支持 nameref 和关联数组)
if [ "${BASH_VERSINFO:-0}" -lt 4 ] || ([ "${BASH_VERSINFO:-0}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 3 ]); then
  echo "❌ 错误: 需要 Bash 4.3+。macOS 请运行: brew install bash" >&2
  exit 1
fi

# 获取脚本绝对路径
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
cd "$SCRIPT_DIR" || exit 1

# ============================================================================
# 第二部分: 配置参数
# ============================================================================

# 性能配置
readonly DOWNLOAD_TIMEOUT=120
readonly MAX_CONCURRENT_DOWNLOADS=20
readonly MAX_CONCURRENT_COMPILES=10
readonly MIN_DISK_SPACE_MB=1000
readonly BACKUP_KEEP_COUNT=3

# 目录配置
readonly SOURCE_DIR="${SCRIPT_DIR}/json/source"
readonly SUBSET_DIR="${SCRIPT_DIR}/json/subset"
readonly COMMON_DIR="${SCRIPT_DIR}/json/common"
readonly SRS_DIR="${SCRIPT_DIR}/srs"
readonly TEMP_DIR="${SCRIPT_DIR}/temp"
readonly LOG_DIR="${SCRIPT_DIR}/logs"

# Python脚本路径
readonly PYTHON_SCRIPT_PATH="${TEMP_DIR}/process_rules.py"

# 全局变量
declare -g HAS_FLOCK=false
declare -g DOWNLOAD_TOOL=""
declare -g LOG_FILE=""

# 临时文件追踪 (用于清理)
declare -ga TEMP_FILES_TO_CLEAN=()

# ============================================================================
# 第三部分: 日志系统
# ============================================================================

# 初始化日志
init_logging() {
  mkdir -p "$LOG_DIR"

  # 生成唯一日志文件名
  LOG_FILE="${LOG_DIR}/merge-$(date '+%Y%m%d-%H%M%S')-$$.log"

  # 保存原始文件描述符
  exec 3>&1 4>&2

  # 重定向到 tee (同时输出到屏幕和文件)
  exec > >(tee -a "$LOG_FILE") 2>&1

  log_info "📋 日志文件: $LOG_FILE"
  log_info "🖥️  系统信息: $(uname -a)"
  log_info "🐚 Bash 版本: ${BASH_VERSION}"
}

# 彩色日志函数
log_info() {
  echo -e "\033[32m[INFO]\033[0m $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

log_warn() {
  echo -e "\033[33m[WARN]\033[0m $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
}

log_error() {
  local msg="$1"
  local detail="${2:-}"

  echo -e "\033[31m[ERROR]\033[0m $(date '+%Y-%m-%d %H:%M:%S') - $msg" >&2

  # 如果有详细错误信息,追加到日志文件
  if [ -n "$detail" ]; then
    echo "    详细信息: $detail" >> "$LOG_FILE"
    echo "    详细信息: $detail" >&2
  fi
}

log_fatal() {
  local msg="$1"
  local detail="${2:-}"
  echo -e "\033[41;37m[FATAL]\033[0m $(date '+%Y-%m-%d %H:%M:%S') - $msg" >&2

  # 恢复原始输出
  if [ -n "$detail" ]; then
    echo "    详细信息: $detail" >&2
  fi

  # 确保日志文件存在
  if [ -f "$LOG_FILE" ]; then
    echo "" >&2
    echo "📋 完整日志请查看: $LOG_FILE" >&2
    echo "最后50行日志:" >&2
    tail -50 "$LOG_FILE" >&2 || true
  fi

  exec 1>&3 2>&4

  # 执行清理
  cleanup_all

  exit 1
}

log_progress() {
  local current=$1
  local total=$2
  local item="${3:-项目}"

  local percent=$((current * 100 / total))
  echo -e "\033[36m[进度]\033[0m [$current/$total] ($percent%) - $item"
}

# ============================================================================
# 第四部分: 清理系统 (优化版)
# ============================================================================

# 注册需要清理的临时文件
register_temp_file() {
  local file="$1"
  TEMP_FILES_TO_CLEAN+=("$file")
}

# 清理临时文件
cleanup_temp_files() {
  if [ ${#TEMP_FILES_TO_CLEAN[@]} -gt 0 ]; then
    log_info "🧹 清理 ${#TEMP_FILES_TO_CLEAN[@]} 个临时文件..."
    for file in "${TEMP_FILES_TO_CLEAN[@]}"; do
      [ -f "$file" ] && rm -f "$file" 2>/dev/null || true
    done
    TEMP_FILES_TO_CLEAN=()
  fi
}

# 清理临时目录
cleanup_temp_dir() {
  if [ -d "$TEMP_DIR" ] && [[ "$TEMP_DIR" == "${SCRIPT_DIR}/temp" ]]; then
    log_info "🧹 清理临时目录: $TEMP_DIR"

    # 安全删除:先尝试删除文件,再删除目录
    find "$TEMP_DIR" -type f -delete 2>/dev/null || true
    rm -rf "$TEMP_DIR" 2>/dev/null || true
  fi
}

# 总清理函数
cleanup_all() {
  log_info "🧹 执行总清理..."
  cleanup_temp_files
  cleanup_temp_dir
}

# 设置信号捕获
trap 'cleanup_all' EXIT
trap 'log_warn "⚠️  收到中断信号"; cleanup_all; exit 130' INT
trap 'log_warn "⚠️  收到终止信号"; cleanup_all; exit 143' TERM

# ============================================================================
# 第五部分: 系统检测
# ============================================================================

# 检查磁盘空间
check_disk_space() {
  local target_dir="${1:-.}"
  local available_mb

  if available_mb=$(df -m "$target_dir" 2>/dev/null | awk 'NR==2 {print $4}'); then
    if [ "$available_mb" -lt "$MIN_DISK_SPACE_MB" ]; then
      log_fatal "磁盘空间不足: 可用 ${available_mb}MB, 需要 ${MIN_DISK_SPACE_MB}MB"
    fi
    log_info "✅ 磁盘空间检查通过: ${available_mb}MB 可用"
  else
    log_warn "⚠️  无法检查磁盘空间,继续执行"
  fi
}

# 检测文件锁工具
detect_flock() {
  if command -v flock &>/dev/null; then
    HAS_FLOCK=true
    log_info "✅ 检测到 flock,启用文件锁保护"
  else
    log_warn "⚠️  未检测到 flock,禁用文件锁"
  fi
}

# 检测下载工具
detect_download_tool() {
  if command -v curl &>/dev/null; then
    DOWNLOAD_TOOL="curl"
    log_info "✅ 使用 curl 下载"
  elif command -v wget &>/dev/null; then
    if wget --help 2>&1 | grep -q -- '--fail'; then
      DOWNLOAD_TOOL="wget"
      log_info "✅ 使用 wget (支持 --fail)"
    else
      DOWNLOAD_TOOL="wget-basic"
      log_warn "⚠️  使用 wget (不支持 --fail)"
    fi
  else
    log_fatal "未找到 curl 或 wget"
  fi
}

# 检查必需命令
check_dependencies() {
  log_info "🔍 检查依赖..."

  local missing=()
  for cmd in sing-box jq python3; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    else
      local version=$($cmd --version 2>&1 | head -1 || echo "unknown")
      log_info "  ✓ $cmd: $version"
    fi
  done

  if [ ${#missing[@]} -gt 0 ]; then
    log_fatal "缺少必需命令: ${missing[*]}"
  fi

  log_info "✅ 所有依赖满足"
}

# ============================================================================
# 第六部分: 工具函数
# ============================================================================

# 生成唯一时间戳 (修复版)
generate_timestamp() {
  if date --version 2>&1 | grep -q GNU; then
    # GNU date: 使用纳秒精度
    date -u +%Y%m%dT%H%M%S%N | cut -c1-21
  else
    # macOS date: 组合多个随机源避免冲突
    local base_time=$(date -u +%Y%m%dT%H%M%S)
    local pid=$$
    local random=$RANDOM
    local nanos=$(($(date +%s%N 2>/dev/null || echo 0) % 1000000))
    printf "%s-%05d-%05d-%06d" "$base_time" "$pid" "$random" "$nanos"
  fi
}

# 判断是否为本地路径
is_local_path() {
  local path="$1"

  [[ "$path" =~ ^/ ]] && return 0
  [[ "$path" =~ ^\./ ]] && return 0
  [[ "$path" =~ ^\.\./ ]] && return 0
  [[ "$path" == *"${SOURCE_DIR}"* ]] && return 0
  [[ "$path" == *"${SUBSET_DIR}"* ]] && return 0
  [[ "$path" == *"${COMMON_DIR}"* ]] && return 0

  return 1
}

# 检查数组是否有效
has_valid_array_elements() {
  local -n arr=$1
  [ ${#arr[@]} -gt 0 ] && [ -n "${arr[0]}" ]
}

# ============================================================================
# 第七部分: 下载功能
# ============================================================================

# 下载文件 (改进版)
download_file() {
  local url="$1"
  local output="$2"
  local timeout="${3:-$DOWNLOAD_TIMEOUT}"

  # 创建临时日志文件
  local dl_log
  dl_log=$(mktemp "${TEMP_DIR}/dl-XXXXXX.log") || {
    log_error "无法创建下载日志文件"
    return 1
  }
  register_temp_file "$dl_log"

  local ret=0

  case "$DOWNLOAD_TOOL" in
    curl)
      if ! curl -fsSL --max-time "$timeout" --retry 3 --retry-delay 2 \
           "$url" -o "$output" 2>"$dl_log"; then
        ret=1
      fi
      ;;
    wget)
      if ! wget -q --no-dns-cache --timeout="$timeout" --tries=3 \
           --wait=2 --fail "$url" -O "$output" 2>"$dl_log"; then
        ret=1
      fi
      ;;
    wget-basic)
      if ! wget -q --no-dns-cache --timeout="$timeout" --tries=3 \
           --wait=2 "$url" -O "$output" 2>"$dl_log"; then
        ret=1
      fi
      ;;
  esac

  if [ $ret -ne 0 ]; then
    local error_detail=$(cat "$dl_log" 2>/dev/null || echo "无详细信息")
    log_error "下载失败: $url" "$error_detail"
    rm -f "$output"
    return 1
  fi

  return 0
}

# ============================================================================
# 第八部分: JSON 验证 (修复版)
# ============================================================================

# JSON验证和修复 (修复文件锁访问问题 & set -u 兼容性 - 最终版)
validate_and_fix_json() {
  local file="$1"
  local group_name="${2:-unknown}"
  local need_lock="${3:-true}"

  # 验证文件存在
  if [ ! -f "$file" ] || [ ! -s "$file" ]; then
    log_error "文件不存在或为空: $file"
    return 1
  fi

  # 创建临时文件
  local temp_file jq_err_file
  temp_file=$(mktemp "${TEMP_DIR}/validate.tmp.XXXXXX.json") || return 1
  jq_err_file=$(mktemp "${TEMP_DIR}/validate.err.XXXXXX.log") || return 1
  register_temp_file "$temp_file"
  register_temp_file "$jq_err_file"

  # 文件锁 (修复: 在主shell而非子shell中加锁)
  local lock_fd=200
  local lock_file="${file}.lock"

  if [ "$need_lock" = "true" ] && [ "$HAS_FLOCK" = true ]; then
    eval "exec ${lock_fd}>\"$lock_file\""

    if ! flock -w 10 -n $lock_fd 2>/dev/null; then
      log_error "获取文件锁超时: $file"
      eval "exec ${lock_fd}>&-"
      rm -f "$lock_file"
      return 1
    fi
  fi

  # 清理函数 (修复核心: 给所有变量增加 :- 默认值保护)
  local cleanup_done=false
  cleanup_validation() {
    # 防止 cleanup_done 未绑定
    [ "${cleanup_done:-false}" = true ] && return
    cleanup_done=true

    # 防止 temp_file / jq_err_file 未绑定
    rm -f "${temp_file:-}" "${jq_err_file:-}" 2>/dev/null || true

    if [ "${need_lock:-}" = "true" ] && [ "${HAS_FLOCK:-}" = true ]; then
      # 防止 lock_fd / lock_file 未绑定
      if [ -n "${lock_fd:-}" ]; then
        eval "exec ${lock_fd}>&-" 2>/dev/null || true
      fi
      rm -f "${lock_file:-}" 2>/dev/null || true
    fi
  }
  trap cleanup_validation RETURN

  # 检测HTML错误页面
  if head -n 1 "$file" 2>/dev/null | grep -qi "<!DOCTYPE\|<html"; then
    log_error "文件是HTML页面(下载错误): $file"
    rm -f "$file"
    return 1
  fi

  # JSON验证
  if jq empty "$file" >/dev/null 2>"$jq_err_file"; then
    # 检查version字段
    if ! jq -e '.version' "$file" >/dev/null 2>&1; then
      if jq '.version = 1' "$file" > "$temp_file" 2>"$jq_err_file" && [ -s "$temp_file" ]; then
        mv -f "$temp_file" "$file"
        log_info "✅ 已添加 version 字段: $file"
      else
        log_error "无法添加 version 字段: $file" "$(cat "$jq_err_file")"
        return 1
      fi
    fi
    return 0
  else
    # 尝试修复
    log_warn "⚠️  JSON格式错误,尝试修复: $file"

    # 修复1: 使用 jq 重新格式化
    if jq '.' "$file" > "$temp_file" 2>"$jq_err_file" && [ -s "$temp_file" ]; then
      mv -f "$temp_file" "$file"
      log_info "✅ 修复成功 (方法1): $file"
      return 0
    fi

    # 修复2: 包装数组
    if jq 'if type == "array" then {version: 1, rules: .} else . end' \
       "$file" > "$temp_file" 2>"$jq_err_file" && [ -s "$temp_file" ]; then
      mv -f "$temp_file" "$file"
      log_info "✅ 修复成功 (方法2): $file"
      return 0
    fi

    # 修复失败
    log_error "JSON修复失败: $file" "$(cat "$jq_err_file")"
    rm -f "$file"
    return 1
  fi
}

# ============================================================================
# 第九部分: 子集预处理
# ============================================================================

# 预处理规则集 (base - exclude = output)
preprocess_ruleset() {
  local base_url="$1"
  local exclude_url="$2"
  local output_file="$3"

  log_info "📦 预处理子集: $(basename "$output_file")"

  # 创建临时文件
  local base_temp exclude_temp jq_log
  base_temp=$(mktemp "${TEMP_DIR}/base.XXXXXX.json") || return 1
  exclude_temp=$(mktemp "${TEMP_DIR}/exclude.XXXXXX.json") || return 1
  jq_log=$(mktemp "${TEMP_DIR}/jq.XXXXXX.log") || return 1
  register_temp_file "$base_temp" "$exclude_temp" "$jq_log"

  # 清理函数
  cleanup_preprocess() {
    rm -f "$base_temp" "$exclude_temp" "$jq_log" 2>/dev/null || true
  }
  trap cleanup_preprocess RETURN

  # 下载/复制 base 文件
  if is_local_path "$base_url"; then
    if [ -f "$base_url" ] && [ -s "$base_url" ]; then
      cp "$base_url" "$base_temp"
      log_info "  ✓ 使用本地 base: $(basename "$base_url")"
    else
      log_error "本地文件不存在: $base_url"
      return 1
    fi
  else
    log_info "  ↓ 下载 base: $(basename "$base_url")"
    if ! download_file "$base_url" "$base_temp" "$DOWNLOAD_TIMEOUT"; then
      log_error "下载 base 失败: $base_url"
      return 1
    fi
  fi

  # 验证 base JSON
  if ! jq empty "$base_temp" >/dev/null 2>"$jq_log"; then
    log_error "Base JSON 无效: $base_url" "$(cat "$jq_log")"
    return 1
  fi

  # 处理 exclude 文件
  if [ -n "$exclude_url" ]; then
    if is_local_path "$exclude_url"; then
      if [ -f "$exclude_url" ] && [ -s "$exclude_url" ]; then
        cp "$exclude_url" "$exclude_temp"
        log_info "  ✓ 使用本地 exclude: $(basename "$exclude_url")"
      else
        log_warn "  ! 本地排除文件不存在,使用空规则: $exclude_url"
        echo '{"version": 1, "rules": []}' > "$exclude_temp"
      fi
    else
      log_info "  ↓ 下载 exclude: $(basename "$exclude_url")"
      if ! download_file "$exclude_url" "$exclude_temp" "$DOWNLOAD_TIMEOUT"; then
        log_warn "  ! 下载 exclude 失败,使用空规则: $exclude_url"
        echo '{"version": 1, "rules": []}' > "$exclude_temp"
      fi
    fi
  else
    echo '{"version": 1, "rules": []}' > "$exclude_temp"
  fi

  # 验证 exclude JSON
  if ! jq empty "$exclude_temp" >/dev/null 2>"$jq_log"; then
    log_warn "Exclude JSON 无效,使用空规则"
    echo '{"version": 1, "rules": []}' > "$exclude_temp"
  fi

  # 执行规则差集计算
  mkdir -p "$(dirname "$output_file")"

  if ! jq --slurpfile exclude "$exclude_temp" '
    .rules as $base_rules |
    ($exclude[0].rules // []) as $exclude_rules |
    {
      version: 1,
      rules: $base_rules | map(
        . as $rule |
        if ($exclude[0] | has("rules")) and ($exclude_rules | any(. == $rule)) then
          empty
        else
          $rule
        end
      )
    }
  ' "$base_temp" > "$output_file" 2>"$jq_log"; then
    log_error "jq 处理失败" "$(cat "$jq_log")"
    return 1
  fi

  # 验证输出
  if ! jq empty "$output_file" >/dev/null 2>"$jq_log"; then
    log_error "生成的 JSON 无效: $output_file" "$(cat "$jq_log")"
    return 1
  fi

  log_info "✅ 子集生成成功: $(basename "$output_file")"
  return 0
}

# ============================================================================
# 第十部分: 规则集合并 (优化版)
# ============================================================================

# 合并规则集分组
merge_group() {
  local group_name="$1"
  shift
  local urls=("$@")

  local local_file="${SOURCE_DIR}/${group_name}.json"

  log_info "🔄 开始合并组: $group_name"

  # 创建临时日志
  local merge_log
  merge_log=$(mktemp "${TEMP_DIR}/merge-${group_name}.XXXXXX.log") || return 1
  register_temp_file "$merge_log"

  # 清理函数
  cleanup_merge() {
    rm -f "${TEMP_DIR}/in-${group_name}-"*.json 2>/dev/null || true
    rm -f "${TEMP_DIR}/merged-${group_name}.json" 2>/dev/null || true
    rm -f "$merge_log" 2>/dev/null || true
  }
  trap cleanup_merge RETURN

  # 分离本地和远程URL
  local -a local_files=() remote_urls=()
  for url in "${urls[@]}"; do
    [ -z "$url" ] && continue
    if is_local_path "$url"; then
      local_files+=("$url")
    else
      remote_urls+=("$url")
    fi
  done

  log_info "📊 统计: 本地文件 ${#local_files[@]} 个, 远程URL ${#remote_urls[@]} 个"

  local file_index=1

  # === 阶段1: 处理本地文件 (快速,串行) ===
  if [ ${#local_files[@]} -gt 0 ]; then
    log_info "📁 阶段1: 处理本地文件..."
    local progress=0
    for local_path in "${local_files[@]}"; do
      ((progress++))
      log_progress $progress ${#local_files[@]} "$(basename "$local_path")"

      local output="${TEMP_DIR}/in-${group_name}-${file_index}.json"

      if [ -f "$local_path" ] && [ -s "$local_path" ]; then
        cp "$local_path" "$output"

        # 本地文件需要文件锁保护
        if validate_and_fix_json "$output" "$group_name" "true"; then
          ((file_index++))
        else
          log_warn "⚠️  本地文件验证失败: $local_path"
          rm -f "$output"
        fi
      else
        log_warn "⚠️  本地文件不存在或为空: $local_path"
      fi
    done
  fi

  # === 阶段2: 并发下载远程文件 ===
  if [ ${#remote_urls[@]} -gt 0 ]; then
    log_info "🌐 阶段2: 并发下载远程文件..."

    local -a pids=()
    local download_progress=0

    for url in "${remote_urls[@]}"; do
      # 并发控制
      if [ ${#pids[@]} -ge $MAX_CONCURRENT_DOWNLOADS ]; then
        log_info "⏳ 等待当前批次完成 (${#pids[@]} 个任务)..."
        local failed=0
        for pid in "${pids[@]}"; do
          if ! wait "$pid"; then
            failed=1
          fi
        done
        if [ $failed -eq 1 ]; then
          log_error "部分下载任务失败"
          return 1
        fi
        pids=()
      fi

      # 后台下载
      (
        ((download_progress++))
        local output="${TEMP_DIR}/in-${group_name}-${file_index}.json"

        log_progress $download_progress ${#remote_urls[@]} "$(basename "$url")"

        if download_file "$url" "$output"; then
          # 临时文件跳过文件锁 (优化性能)
          if validate_and_fix_json "$output" "$group_name" "false"; then
            exit 0
          else
            rm -f "$output"
            exit 1
          fi
        else
          rm -f "$output"
          exit 1
        fi
      ) &

      pids+=($!)
      ((file_index++))
    done

    # 等待所有下载完成
    if [ ${#pids[@]} -gt 0 ]; then
      log_info "⏳ 等待最后批次完成 (${#pids[@]} 个任务)..."
      local failed=0
      for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
          failed=1
        fi
      done
      if [ $failed -eq 1 ]; then
        log_fatal "组 $group_name 存在下载失败"
      fi
    fi
  fi

  # === 阶段3: 合并所有输入文件 ===
  log_info "🔗 阶段3: 合并规则..."

  shopt -s nullglob
  local inputs=("${TEMP_DIR}/in-${group_name}-"*.json)
  shopt -u nullglob

  if [ ${#inputs[@]} -eq 0 ]; then
    log_fatal "组 $group_name 没有可用的输入文件"
  fi

  log_info "📋 合并 ${#inputs[@]} 个文件..."

  local merged_tmp="${TEMP_DIR}/merged-${group_name}.json"
  local -a config_flags=()
  for input_file in "${inputs[@]}"; do
    config_flags+=("-c" "$input_file")
  done

  if ! sing-box rule-set merge "$merged_tmp" "${config_flags[@]}" > "$merge_log" 2>&1; then
    log_error "sing-box 合并失败: $group_name" "$(cat "$merge_log")"
    return 1
  fi

  # === 阶段4: 备份并保存 ===
  if [ -f "$local_file" ]; then
    local timestamp=$(generate_timestamp)
    local backup_file="${SOURCE_DIR}/${timestamp}-${group_name}.json"

    mv -f "$local_file" "$backup_file"
    log_info "💾 已备份旧文件: $(basename "$backup_file")"
  fi

  mv -f "$merged_tmp" "$local_file"
  log_info "✅ 组合并完成: $group_name"

  return 0
}

# ============================================================================
# 第十一部分: 规则编译 (带恢复机制)
# ============================================================================

# 编译 SRS 文件 (修复版: 兼容 set -u)
compile_srs_file() {
  local group_name="$1"
  local json_file="${SOURCE_DIR}/${group_name}.json"
  local srs_file="${SRS_DIR}/${group_name}.srs"

  # 跳过不存在的文件
  if [ ! -f "$json_file" ]; then
    log_warn "⚠️  跳过编译(文件不存在): $group_name"
    return 0
  fi

  log_info "⚙️  编译: $group_name"

  # 创建编译日志
  local compile_log
  compile_log=$(mktemp "${TEMP_DIR}/compile-${group_name}.XXXXXX.log") || return 1
  register_temp_file "$compile_log"

  # 清理函数 (加固: 使用 :- 防止变量未定义报错)
  cleanup_compile() {
    rm -f "${compile_log:-}" 2>/dev/null || true
  }
  trap cleanup_compile RETURN

  # 尝试编译
  if sing-box rule-set compile "$json_file" -o "$srs_file" > "$compile_log" 2>&1; then
    log_info "✅ 编译成功: $group_name"
    return 0
  else
    log_error "编译失败: $group_name" "$(cat "$compile_log")"

    # 尝试从备份恢复
    local backup_file
    backup_file=$(find "$SOURCE_DIR" -name "*-${group_name}.json" -type f 2>/dev/null | sort -r | head -n 1)

    if [ -n "$backup_file" ] && [ -f "$backup_file" ]; then
      log_info "🔄 尝试从备份恢复: $(basename "$backup_file")"

      cp -a "$backup_file" "$json_file"

      if sing-box rule-set compile "$json_file" -o "$srs_file" >> "$compile_log" 2>&1; then
        log_info "✅ 从备份编译成功: $group_name"
        return 0
      else
        log_error "备份编译也失败: $group_name"
        return 1
      fi
    else
      log_error "无可用备份: $group_name"
      return 1
    fi
  fi
}

# ============================================================================
# 【新增】第十一点五部分: Common 目录独立编译
# ============================================================================

# 编译 Common 目录下的 JSON 文件
compile_common_srs() {
  log_info "⚙️  === 开始编译 Common 规则集 ==="

  shopt -s nullglob
  local common_files=("${COMMON_DIR}"/*.json)
  shopt -u nullglob

  if [ ${#common_files[@]} -eq 0 ]; then
    log_info "ℹ️  Common 目录为空,跳过编译"
    return 0
  fi

  local -a pids=()
  local progress=0

  for common_file in "${common_files[@]}"; do
    local name=$(basename "$common_file" .json)
    local srs_file="${SRS_DIR}/${name}.srs"

    # 并发控制
    if [ ${#pids[@]} -ge $MAX_CONCURRENT_COMPILES ]; then
      log_info "⏳ 等待编译批次..."
      for pid in "${pids[@]}"; do
        wait "$pid" || true
      done
      pids=()
    fi

    ((++progress))
    log_progress $progress ${#common_files[@]} "$name"

    # 后台编译
    (
      log_info "⚙️  编译 Common: $name"

      local compile_log
      compile_log=$(mktemp "${TEMP_DIR}/compile-common-${name}.XXXXXX.log") || exit 1
      register_temp_file "$compile_log"

      if sing-box rule-set compile "$common_file" -o "$srs_file" > "$compile_log" 2>&1; then
        log_info "✅ Common 编译成功: $name"
        exit 0
      else
        log_error "Common 编译失败: $name" "$(cat "$compile_log")"
        exit 1
      fi
    ) &
    pids+=($!)
  done

  # 等待最后批次
  if [ ${#pids[@]} -gt 0 ]; then
    log_info "⏳ 等待最后编译批次..."
    for pid in "${pids[@]}"; do
      wait "$pid" || true
    done
  fi

  log_info "✅ === Common 规则集编译完成 ==="
}

# 批量编译所有分组
compile_all_srs() {
  log_info "⚙️  === 开始编译所有 SRS 文件 ==="

  local groups=("ads" "games-cn" "games-noncn" "ai-cn" "ai-noncn" "media"
                "network-cn" "network-noncn" "cdn" "hkmotw" "private")

  local -a pids=()
  local -a failed_groups=()
  local progress=0

  for group in "${groups[@]}"; do
    # 并发控制
    if [ ${#pids[@]} -ge $MAX_CONCURRENT_COMPILES ]; then
      log_info "⏳ 等待编译批次..."
      for pid in "${pids[@]}"; do
        wait "$pid" || true
      done
      pids=()
    fi

    ((++progress))
    log_progress $progress ${#groups[@]} "$group"

    # 后台编译
    compile_srs_file "$group" &
    pids+=($!)
  done

  # 等待最后批次
  if [ ${#pids[@]} -gt 0 ]; then
    log_info "⏳ 等待最后编译批次..."
    for pid in "${pids[@]}"; do
      wait "$pid" || true
    done
  fi

  log_info "✅ === Source 目录 SRS 编译完成 ==="
}

# ============================================================================
# 第十二部分: 备份清理
# ============================================================================

# 清理旧备份文件
cleanup_old_backups() {
  log_info "🧹 === 清理旧备份 (保留 $BACKUP_KEEP_COUNT 份) ==="

  local groups=("ads" "games-cn" "games-noncn" "ai-cn" "ai-noncn" "media"
                "network-cn" "network-noncn" "cdn" "hkmotw" "private")

  for group in "${groups[@]}"; do
    local backup_count
    backup_count=$(find "$SOURCE_DIR" -name "*-${group}.json" -type f 2>/dev/null | wc -l)

    if [ "$backup_count" -gt "$BACKUP_KEEP_COUNT" ]; then
      log_info "🗑️  清理 $group 备份 (当前: $backup_count, 保留: $BACKUP_KEEP_COUNT)"

      find "$SOURCE_DIR" -name "*-${group}.json" -type f 2>/dev/null | \
        sort -r | \
        tail -n +$((BACKUP_KEEP_COUNT + 1)) | \
        xargs -r rm -f 2>/dev/null || true
    fi
  done

  log_info "✅ === 备份清理完成 ==="
}

# ============================================================================
# 第十三部分: Python 脚本生成 (修复版)
# ============================================================================

generate_python_script() {
  log_info "🐍 生成 Python 处理脚本..."

  cat << 'PYTHON_EOF' > "$PYTHON_SCRIPT_PATH"
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Sing-box 规则集处理脚本 (修复版)
修复内容:
1. get_data 函数支持字符串类型值
2. 增强错误处理和日志
3. 改进 IP 合并逻辑
"""

import json
import ipaddress
import sys
import re
import argparse
from pathlib import Path
from collections import defaultdict

# 全局错误标志
has_critical_error = False
error_counts = defaultdict(int)

# 目录配置
BASE_DIR = Path.cwd()
SOURCE_DIR = BASE_DIR / "json/source"
SUBSET_DIR = BASE_DIR / "json/subset"
COMMON_DIR = BASE_DIR / "json/common"


def mark_critical_error(msg: str):
    """标记严重错误"""
    global has_critical_error
    has_critical_error = True
    print(f"[CRITICAL] {msg}", file=sys.stderr)


def merge_cidrs(cidrs):
    """合并并优化 CIDR 列表"""
    valid_nets = []

    for cidr_str in cidrs:
        if not cidr_str:
            continue

        # 清理空白字符
        s = re.sub(r'\s+', '', cidr_str.strip())
        if not s:
            continue

        try:
            net = ipaddress.ip_network(s, strict=False)
            valid_nets.append(net)
        except ValueError as e:
            error_counts['invalid_ip'] += 1
            if error_counts['invalid_ip'] <= 5:
                print(f"[WARN] 无效 IP/CIDR: '{cidr_str}' - {e}", file=sys.stderr)

    if not valid_nets:
        return []

    # 分离 IPv4 和 IPv6
    v4_nets = [n for n in valid_nets if n.version == 4]
    v6_nets = [n for n in valid_nets if n.version == 6]

    # 合并相邻网段
    merged_v4 = list(ipaddress.collapse_addresses(v4_nets)) if v4_nets else []
    merged_v6 = list(ipaddress.collapse_addresses(v6_nets)) if v6_nets else []

    # 排序
    sorted_v4 = sorted(merged_v4, key=lambda n: (n.network_address, n.prefixlen))
    sorted_v6 = sorted(merged_v6, key=lambda n: (n.network_address, n.prefixlen))

    return [str(n) for n in sorted_v4] + [str(n) for n in sorted_v6]


def normalize_domains(items, is_domain=False):
    """规范化域名列表（增强版：过滤无效条目）"""
    result = set()

    for item in items:
        if not item: continue

        # 清理空白
        s = re.sub(r'\s+', '', item.strip())
        if not s: continue

        # ===【新增】过滤无效条目 ===
        # 1. 长度检查：至少2个字符
        if len(s) < 2: continue

        # 2. 过滤纯符号/纯数字单字符
        if len(s) == 1: continue

        # 3. 过滤纯符号字符串（如 ".", "$", "\\", "^" 等）
        if re.match(r'^[^a-zA-Z0-9\u4e00-\u9fa5]+$', s): continue

        # 4. 域名特殊检查
        if is_domain:
            # 移除 www 前缀
            s = re.sub(r'^(?:\.www\.|www\.)', '', s, flags=re.IGNORECASE)
            s = s.lstrip('.').lower()

            # 过滤无效域名：必须包含字母或数字
            if not re.search(r'[a-z0-9]', s): continue

            # 过滤纯数字域名（通常无效）
            if re.match(r'^[0-9]+$', s): continue

        # 最终长度检查
        if len(s) >= 2:
            result.add(s)

    return sorted(list(result))


def process_json_file(file_path: Path):
    """处理单个 JSON 文件: 去重、排序、规范化"""
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            data = json.load(f)
    except Exception as e:
        mark_critical_error(f"读取文件失败: {file_path.name} - {e}")
        return

    if 'rules' not in data or not isinstance(data['rules'], list):
        mark_critical_error(f"无效格式(缺少 rules 数组): {file_path.name}")
        return

    # 允许的规则键
    allowed_keys = {'domain', 'domain_suffix', 'domain_keyword', 'domain_regex', 'ip_cidr'}

    # 收集所有规则
    domains = set()
    suffixes = set()
    keywords = set()
    regexs = set()
    ips = set()

    for rule in data['rules']:
        if not isinstance(rule, dict):
            continue

        # 检查未知键
        unknown_keys = set(rule.keys()) - allowed_keys
        if unknown_keys:
            print(f"[WARN] 未知规则键 ({file_path.name}): {unknown_keys}", file=sys.stderr)

        domains.update(rule.get('domain', []))
        suffixes.update(rule.get('domain_suffix', []))
        keywords.update(rule.get('domain_keyword', []))
        regexs.update(rule.get('domain_regex', []))
        ips.update(rule.get('ip_cidr', []))

    # 规范化处理
    final_domains = normalize_domains(domains, is_domain=True)
    final_suffixes = sorted([f".{d}" for d in normalize_domains(suffixes, is_domain=True)])
    final_keywords = normalize_domains(keywords, is_domain=False)
    final_regexs = normalize_domains(regexs, is_domain=False)
    final_ips = merge_cidrs(ips)

    # 构建新规则
    new_rules = []

    # 域名规则对象
    domain_obj = {}
    if final_domains:
        domain_obj['domain'] = final_domains
    if final_suffixes:
        domain_obj['domain_suffix'] = final_suffixes
    if final_keywords:
        domain_obj['domain_keyword'] = final_keywords
    if final_regexs:
        domain_obj['domain_regex'] = final_regexs

    if domain_obj:
        new_rules.append(domain_obj)

    # IP 规则对象
    if final_ips:
        new_rules.append({'ip_cidr': final_ips})

    # 写入文件
    try:
        with open(file_path, 'w', encoding='utf-8') as f:
            json.dump({"version": 1, "rules": new_rules}, f, indent=2, ensure_ascii=False)
    except Exception as e:
        mark_critical_error(f"写入文件失败: {file_path.name} - {e}")


def get_rule_data(file_path: Path):
    """提取文件中的所有规则数据 (修复版: 支持字符串值)"""
    if not file_path.exists():
        return {}

    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            data = json.load(f)

        result = defaultdict(set)

        for rule in data.get('rules', []):
            if not isinstance(rule, dict):
                continue

            for key, value in rule.items():
                # [修复] 同时处理列表和字符串
                if isinstance(value, list):
                    result[key].update(value)
                elif isinstance(value, str):
                    result[key].add(value)

        # 转换为列表
        return {k: list(v) for k, v in result.items()}

    except Exception as e:
        mark_critical_error(f"读取规则数据失败: {file_path.name} - {e}")
        return {}


def find_and_remove_duplicates(cn_file: Path, noncn_file: Path, common_file: Path):
    """
    查找并移除 CN 和 NonCN 之间的重复项,保存到 common
    【新增】支持 Common 增量更新:新的重复项会与旧的 common 内容合并
    """

    # 检查文件存在性
    if not (cn_file.exists() and noncn_file.exists()):
        print(f"[SKIP] 缺少配对文件: {cn_file.name} / {noncn_file.name}")
        return

    print(f"[INFO] 去重: {cn_file.name} <-> {noncn_file.name}")

    # 读取数据
    data_cn = get_rule_data(cn_file)
    data_noncn = get_rule_data(noncn_file)

    # 【关键】读取旧的 common 文件(如果存在)
    data_common_old = get_rule_data(common_file) if common_file.exists() else {}

    # 新的 common 数据(用于累积)
    new_common = {}

    # 所有规则键
    all_keys = ['domain', 'domain_suffix', 'domain_keyword', 'domain_regex', 'ip_cidr']

    for key in all_keys:
        set_cn = set(data_cn.get(key, []))
        set_noncn = set(data_noncn.get(key, []))
        set_common_old = set(data_common_old.get(key, []))

        # 计算交集(新发现的重复项)
        common_new = set_cn.intersection(set_noncn)

        # 【核心增量逻辑】合并旧的 common 内容
        # 累积更新: 旧内容 + 新重复项
        common_all = common_new.union(set_common_old)

        if common_all:
            new_common[key] = list(common_all)

            # 从原始集合中移除所有 common 内容(包括旧的)
            data_cn[key] = list(set_cn - common_all)
            data_noncn[key] = list(set_noncn - common_all)

    # 保存函数
    def save_rules(path: Path, data_dict):
        """保存规则到JSON文件"""
        if not data_dict:
            # 如果数据为空,写入空规则集
            path.parent.mkdir(parents=True, exist_ok=True)
            with open(path, 'w', encoding='utf-8') as f:
                json.dump({"version": 1, "rules": []}, f, indent=2, ensure_ascii=False)
            return

        rules = []

        # 域名规则
        domain_obj = {}
        for key in ['domain', 'domain_suffix', 'domain_keyword', 'domain_regex']:
            if key in data_dict and data_dict[key]:
                domain_obj[key] = sorted(data_dict[key])

        if domain_obj:
            rules.append(domain_obj)

        # IP 规则
        if 'ip_cidr' in data_dict and data_dict['ip_cidr']:
            rules.append({'ip_cidr': merge_cidrs(data_dict['ip_cidr'])})

        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            with open(path, 'w', encoding='utf-8') as f:
                json.dump({"version": 1, "rules": rules}, f, indent=2, ensure_ascii=False)
        except IOError as e:
            mark_critical_error(f"保存去重结果失败: {path.name} - {e}")

    # 保存结果
    if new_common:
        save_rules(common_file, new_common)
        print(f"  ✓ 已更新 common: {common_file.name} (累积 {len(new_common)} 个规则类型)")

    save_rules(cn_file, data_cn)
    save_rules(noncn_file, data_noncn)


def run_step1_pre_merge():
    """步骤1: 合并前规范化"""
    print("[INFO] === Python 步骤1: 合并前规范化 ===")

    SOURCE_DIR.mkdir(parents=True, exist_ok=True)
    SUBSET_DIR.mkdir(parents=True, exist_ok=True)

    # 处理 source 目录
    for file in SOURCE_DIR.glob("*.json"):
        if file.is_file():
            print(f"[INFO] 处理: {file.name}")
            process_json_file(file)

    # 处理 subset 目录
    for file in SUBSET_DIR.glob("*.json"):
        if file.is_file():
            print(f"[INFO] 处理: {file.name}")
            process_json_file(file)


def run_step2_post_merge():
    """步骤2: 合并后处理(去重、分离 common - 增量更新版)"""
    print("[INFO] === Python 步骤2: 合并后处理 ===")

    SOURCE_DIR.mkdir(parents=True, exist_ok=True)
    COMMON_DIR.mkdir(parents=True, exist_ok=True)

    # 规范化 source 目录中的非备份文件
    for file in SOURCE_DIR.glob("*.json"):
        if file.is_file() and not re.match(r'^\d{8}T\d{6}', file.name):
            print(f"[INFO] 规范化: {file.name}")
            process_json_file(file)

    # 去重配对
    pairs = [
        ("games-cn", "games-noncn", "games-common"),
        ("ai-cn", "ai-noncn", "ai-common"),
        ("network-cn", "network-noncn", "network-common")
    ]

    for cn_name, noncn_name, common_name in pairs:
        cn_path = SOURCE_DIR / f"{cn_name}.json"
        noncn_path = SOURCE_DIR / f"{noncn_name}.json"
        common_path = COMMON_DIR / f"{common_name}.json"

        find_and_remove_duplicates(cn_path, noncn_path, common_path)

    # 规范化 common 目录
    for file in COMMON_DIR.glob("*.json"):
        if file.is_file():
            print(f"[INFO] 规范化 common: {file.name}")
            process_json_file(file)

    # 打印错误统计
    if error_counts:
        print("\n=== 错误统计 ===", file=sys.stderr)
        for error_type, count in error_counts.items():
            print(f"  {error_type}: {count}", file=sys.stderr)


def main():
    """主函数"""
    parser = argparse.ArgumentParser(description='Sing-box 规则集处理')
    parser.add_argument('--step', choices=['step1', 'step2'], required=True,
                       help='执行步骤: step1=合并前规范化, step2=合并后处理')

    args = parser.parse_args()

    try:
        if args.step == 'step1':
            run_step1_pre_merge()
        elif args.step == 'step2':
            run_step2_post_merge()

        if has_critical_error:
            print("\n[FATAL] Python 处理过程中发生严重错误", file=sys.stderr)
            sys.exit(1)
        else:
            print("[SUCCESS] Python 处理完成")
            sys.exit(0)

    except Exception as e:
        print(f"\n[FATAL] 未捕获的异常: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
PYTHON_EOF

  chmod +x "$PYTHON_SCRIPT_PATH"
  log_info "✅ Python 脚本已生成"
}

# ============================================================================
# 第十四部分: URL 配置 (集中管理)
# ============================================================================

# 初始化 URL 配置
init_url_configs() {
  log_info "📋 初始化 URL 配置..."

  # 预处理配置 (subset 文件生成)
  preprocess_configs=(
    # === 游戏相关 ===
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-games-cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-games-cn@!cn.json"
    "${SUBSET_DIR}/geosite-category-games-cn@cn2.json"

    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-games-!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-games-!cn@cn.json"
    "${SUBSET_DIR}/geosite-category-games-!cn@!cn.json"

    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-game-platforms-download.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-game-platforms-download@cn.json"
    "${SUBSET_DIR}/game-platforms-download@!cn.json"

    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-epicgames.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-epicgames@cn.json"
    "${SUBSET_DIR}/geosite-epicgames@!cn.json"

    # === AI 相关 ===
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-ai-cn.json"
    "${SUBSET_DIR}/tmp/geosite-category-ai-cn@!cn.json"
    "${SUBSET_DIR}/geosite-category-ai-cn@cn.json"

    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-doubao.json"
    "${SUBSET_DIR}/tmp/geosite-doubao@!cn.json"
    "${SUBSET_DIR}/doubao@cn.json"

    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-jetbrains.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-jetbrains@cn.json"
    "${SUBSET_DIR}/jetbrains@!cn.json"

    # === 网络服务 ===
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-social-media-cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-social-media-cn@!cn.json"
    "${SUBSET_DIR}/geosite-category-social-media-cn@cn.json"

    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-bank-cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-bank-cn@!cn.json"
    "${SUBSET_DIR}/geosite-category-bank-cn@cn.json"

    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-dev-cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-dev-cn@!cn.json"
    "${SUBSET_DIR}/geosite-category-dev-cn@cn2.json"

    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-entertainment-cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-entertainment-cn@!cn.json"
    "${SUBSET_DIR}/geosite-category-entertainment-cn@cn2.json"

    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-social-media-!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-social-media-!cn@cn.json"
    "${SUBSET_DIR}/geosite-category-social-media-!cn@!cn.json"
  )

  # 广告拦截规则
  ads_urls=(
    "${SOURCE_DIR}/ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-acfun-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-acfun-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-acfun@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-adcolony-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-adcolony-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-adjust-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-adjust-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-adobe-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-adobe-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-adobe@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-alibaba-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-alibaba-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-alibaba@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-amazon-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-amazon-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-amazon@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-apple-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-apple-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-apple@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-applovin-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-applovin-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-atom-data-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-atom-data-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-baidu-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-baidu-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-baidu@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-bytedance-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-bytedance-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-bytedance@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-ads-all.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-ads-ir.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-ai-!cn@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-ai-chat-!cn@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-cas@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-communication@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-companies@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-dev@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-ecommerce@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-entertainment-cn@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-entertainment@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-httpdns-cn@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-media-cn@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-porn@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-social-media-!cn@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-social-media-cn@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-speedtest@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-clearbitjs-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-clearbitjs-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-disney@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-dmm-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-dmm-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-dmm@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-duolingo-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-duolingo-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-duolingo@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-emogi-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-emogi-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-facebook-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-facebook-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-flurry-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-flurry-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-fqnovel@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-gamersky@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-google-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-google-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-google@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-growingio-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-growingio-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-hetzner@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-hiido-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-hiido-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-hotjar-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-hotjar-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-hunantv-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-hunantv-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-hunantv@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-inner-active-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-inner-active-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-instagram-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-instagram-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-instagram@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-iqiyi-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-iqiyi-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-iqiyi@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-jd-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-jd-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-jd@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-kuaishou-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-kuaishou-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-kuaishou@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-kugou-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-kugou-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-kugou@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-le@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-leanplum-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-leanplum-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-letv-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-letv-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-meta-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-meta-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-meta@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-microsoft@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-mixpanel-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-mixpanel-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-mopub-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-mopub-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-mxplayer-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-mxplayer-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-netease-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-netease-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-netease@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-newrelic-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-newrelic-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-ogury-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-ogury-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-onesignal-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-onesignal-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-ookla-speedtest-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-ookla-speedtest-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-ookla-speedtest@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-openai@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-openx-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-openx-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-pikpak@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-pixiv@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-pocoiq-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-pocoiq-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-pubmatic-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-pubmatic-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-pubmatic@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-qihoo360-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-qihoo360-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-qihoo360@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-samsung@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-segment-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-segment-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-sensorsdata-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-sensorsdata-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-sina-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-sina-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-sina@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-snap@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-sohu-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-sohu-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-sohu@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-speedtest@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-spotify-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-spotify-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-supersonic-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-supersonic-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-tagtic-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-tagtic-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-tappx-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-tappx-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-television-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-television-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-tencent-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-tencent-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-tencent@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-uberads-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-uberads-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-umeng-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-umeng-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-umeng@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-unity-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-unity-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-unity@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-verizon@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-whatsapp-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-whatsapp-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-whatsapp@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-win-spy.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-wteam-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-wteam-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-xhamster-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-xhamster-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-xhamster@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-xiaomi-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-xiaomi-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-xiaomi@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-ximalaya-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-ximalaya-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-yahoo-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-yahoo-ads@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-yahoo@ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-youku-ads.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-youku-ads@ads.json"
  )

  # 游戏 CN
  games_cn_urls=(
    "${SOURCE_DIR}/games-cn.json"
    "${SUBSET_DIR}/geosite-category-games-cn@cn2.json"
    "${SUBSET_DIR}/tmp/geosite-bilibili-game@cn.json"
    "${SUBSET_DIR}/tmp/geosite-bluepoch-games@cn.json"
    "${SUBSET_DIR}/tmp/geosite-tencent-games@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-game-accelerator-cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-game-platforms-download@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-games-!cn@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-games-cn@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-games@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-epicgames@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-gamersky.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-herogame.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-kurogames@cn.json"
  )

  # 游戏 NonCN
  games_noncn_urls=(
    "${SOURCE_DIR}/games-noncn.json"
    "${SUBSET_DIR}/game-platforms-download@!cn.json"
    "${SUBSET_DIR}/geosite-category-games-!cn@!cn.json"
    "${SUBSET_DIR}/geosite-epicgames@!cn.json"
    "${SUBSET_DIR}/tmp/geosite-tencent-games@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-2kgames.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-games-cn@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-games@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-cygames.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-steam.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-wbgames.json"
  )

  # AI CN
  ai_cn_urls=(
    "${SOURCE_DIR}/ai-cn.json"
    "${SUBSET_DIR}/doubao@cn.json"
    "${SUBSET_DIR}/geosite-category-ai-cn@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-aixcoder.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-apple-intelligence.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-deepseek.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-jetbrains@cn.json"
  )

  # AI NonCN
  ai_noncn_urls=(
    "${SOURCE_DIR}/ai-noncn.json"
    "${SUBSET_DIR}/jetbrains@!cn.json"
    "${SUBSET_DIR}/tmp/geosite-category-ai-cn@!cn.json"
    "${SUBSET_DIR}/tmp/geosite-doubao@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-anthropic.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-ai-!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-ai-chat-!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-google-gemini.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-jetbrains-ai.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-meta.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-openai.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-perplexity.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-poe.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-xai.json"
  )

  # 媒体
  media_urls=(
    "${SOURCE_DIR}/media.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-netflix.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-disney.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-netflix.json"
  )

  # 网络 CN
  network_cn_urls=(
    "${SOURCE_DIR}/network-cn.json"
    "${SUBSET_DIR}/geosite-category-bank-cn@cn.json"
    "${SUBSET_DIR}/geosite-category-dev-cn@cn2.json"
    "${SUBSET_DIR}/geosite-category-entertainment-cn@cn2.json"
    "${SUBSET_DIR}/geosite-category-social-media-cn@cn.json"
    "${SUBSET_DIR}/tmp/geosite-bilibili@cn.json"
    "${SUBSET_DIR}/tmp/geosite-bluepoch@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-acer@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-adidas@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-adobe@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-aerogard@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-airwick@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-akamai@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-amazon@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-amd@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-amp@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-apple-cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-apple-dev@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-apple-pki@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-apple@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-asus@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-att@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-aws-cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-aws-cn@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-aws@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-azure@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-beats@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-bestbuy@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-bing@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-bluearchive@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-bmw@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-booking@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-bridgestone@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-broadcom@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-calgoncarbon@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-canon@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-antivirus@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-automobile-cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-blog-cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-cas@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-collaborate-cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-companies@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-cryptocurrency@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-dev-cn@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-dev@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-documents-cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-ecommerce@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-education-cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-electronic-cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-enhance-gaming@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-enterprise-query-platform-cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-entertainment-cn@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-entertainment@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-finance@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-food-cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-hospital-cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-httpdns-cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-logistics-cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-media-cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-media@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-mooc-cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-netdisk-cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-network-security-cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-ntp-cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-ntp-cn@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-ntp@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-number-verification-cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-outsource-cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-remote-control@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-scholar-cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-securities-cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-social-media-!cn@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-speedtest@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-tech-media@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-wiki-cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-china-list.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-cisco@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-clearasil@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-cloudflare-cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-cloudflare-cn@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-cloudflare@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-dell@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-dettol@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-digicert@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-duolingo@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-durex@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-ebay@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-entrust@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-eset@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-familymart@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-farfetch@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-fflogs@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-finish@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-firebase@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-geolocation-cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-geolocation-cn@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-gigabyte@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-globalsign@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-gog@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-google-cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-google-play@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-google-trust-services@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-google@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-gucci@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-hketgroup@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-hm@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-hp@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-hsbc-cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-huawei-dev@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-huawei@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-icloud@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-ifast@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-ikea@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-intel@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-itunes@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-kaspersky@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-kechuang@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-kindle@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-linkedin@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-lysol@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-mapbox@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-mastercard@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-mcdonalds@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-meadjohnson@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-microsoft-dev@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-microsoft-pki@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-microsoft@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-mihoyo-cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-mihoyo-cn@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-mihoyo@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-miniso@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-mortein@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-movefree@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-msn@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-muji@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-nike@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-nintendo@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-nurofen@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-nvidia@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-okaapps@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-okx@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-openjsfoundation@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-oreilly@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-panasonic@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-paypal@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-pearson@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-primevideo@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-qnap@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-qualcomm@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-razer@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-rb@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-reabble@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-riot@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-samsung@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-sectigo@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-shopee@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-sky@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-sslcom@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-st@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-starbucks@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-steam@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-strepsils@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-swift@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-synology@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-teamviewer@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-tencent-dev@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-tencent@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-tesla@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-test-ipv6@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-thelinuxfoundation@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-thetype@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-tld-cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-tvb@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-ubiquiti@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-ubisoft@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-vanish@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-veet@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-verizon@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-visa@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-vmware@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-volvo@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-walmart@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-webex@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-westerndigital@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-woolite@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-xbox@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-yahoo@cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-youtube@cn.json"
  )

  # 网络 NonCN
  network_noncn_urls=(
    "${SOURCE_DIR}/network-noncn.json"
    "${SUBSET_DIR}/geosite-category-social-media-!cn@!cn.json"
    "${SUBSET_DIR}/tmp/geosite-trae@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-facebook.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-telegram.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-twitter.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-alibaba@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-alibabacloud@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-aliyun@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-bilibili@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-boc@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-bytedance@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-bank-cn@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-browser-!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-companies@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-dev-cn@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-entertainment-cn@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-entertainment@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-pt@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-scholar-!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-social-media-cn@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-speedtest@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-ccb@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-chinamobile@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-chinatelecom@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-chinaunicom@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-citic@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-cmb@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-ctexcel@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-ctrip@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-deepin@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-dewu@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-didi@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-eastmoney@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-geolocation-!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-gfw.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-github.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-gitlab.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-google@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-googlefcm@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-huawei@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-huaweicloud@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-icbc@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-ipip@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-iqiyi@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-jd@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-oneplus@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-oppo@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-pingan@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-qcloud@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-sina@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-tencent@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-tiktok@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-tld-!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-vivo@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-win-extra.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-win-update.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-xiaomi@!cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-zte@!cn.json"
  )

  # CDN
  cdn_urls=(
    "${SOURCE_DIR}/cdn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-cloudflare.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-cloudfront.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-fastly.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-google.json"
  )

  # 港澳台
  hkmotw_urls=(
    "${SOURCE_DIR}/hkmotw.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-hk.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-mo.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-tw.json"
  )

  # 私有网络
  private_urls=(
    "${SOURCE_DIR}/private.json"
    "${SUBSET_DIR}/geoip-private-manual.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-private.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-private.json"
  )

  log_info "✅ URL 配置完成"
}

# ============================================================================
# 第十五部分: 主流程
# ============================================================================

main() {
  log_info "=========================================="
  log_info "🚀 Sing-box 规则集合并脚本 v2.0.0"
  log_info "=========================================="
  log_info "开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
  log_info ""

  # === 初始化 ===
  log_info "🔧 === 第0步: 初始化环境 ==="
  check_disk_space "."
  detect_flock
  detect_download_tool
  check_dependencies

  # 创建目录
  mkdir -p "$TEMP_DIR" "$SRS_DIR" "$SOURCE_DIR" "$SUBSET_DIR" "$COMMON_DIR" "${SUBSET_DIR}/tmp"
  log_info "✅ 目录结构已创建"

  # 生成 Python 脚本
  generate_python_script

  # 初始化 URL 配置
  init_url_configs

  log_info ""

  # === 步骤1: 预处理子集 ===
  if has_valid_array_elements preprocess_configs; then
    log_info "📦 === 第1步: 预处理子集文件 ==="

    local total=${#preprocess_configs[@]}

    # 安全检查: 配置必须是3的倍数
    if (( total % 3 != 0 )); then
      log_fatal "预处理配置数量错误: $total (必须是3的倍数)"
    fi

    log_info "📊 总计: $((total / 3)) 个子集任务"

    local -a pids=()
    local progress=0
    local failed_tasks=0

    for ((i=0; i<total; i+=3)); do
      # 并发控制
      if [ ${#pids[@]} -ge $MAX_CONCURRENT_DOWNLOADS ]; then
        log_info "⏳ 等待预处理批次..."
        for pid in "${pids[@]}"; do
          if ! wait "$pid"; then
            ((failed_tasks++))
          log_fatal "预处理任务失败 (PID: $pid)"
          fi
        done
        pids=()
      fi

      ((++progress))
      log_progress $progress $((total / 3)) "$(basename "${preprocess_configs[i+2]}")"

      # 后台执行时捕获错误
      (
        if ! preprocess_ruleset "${preprocess_configs[i]}" "${preprocess_configs[i+1]}" "${preprocess_configs[i+2]}"; then
          log_error "预处理失败: ${preprocess_configs[i+2]}"
          exit 1
        fi
      ) &
      pids+=($!)
    done

    # 等待最后批次
    if [ ${#pids[@]} -gt 0 ]; then
      log_info "⏳ 等待最后批次..."
      for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
          ((failed_tasks++))
        fi
      done
    fi

    if [ $failed_tasks -gt 0 ]; then
      log_fatal "预处理失败: $failed_tasks 个任务失败"
    fi

    log_info "✅ === 第1步完成: 子集预处理 ==="
  else
    log_info "⏭️  === 第1步跳过: 无预处理配置 ==="
  fi

  log_info ""

  # === 步骤2: Python 预规范化 ===
  log_info "🐍 === 第2步: Python 预规范化 ==="
  if ! "$PYTHON_SCRIPT_PATH" --step step1; then
    log_fatal "Python step1 失败"
  fi
  log_info "✅ === 第2步完成 ==="
  log_info ""

  # === 步骤3: 合并规则组 ===
  log_info "🔗 === 第3步: 合并规则组 ==="

  [ ${#ads_urls[@]} -gt 0 ] && { merge_group "ads" "${ads_urls[@]}" || log_fatal "ads 合并失败"; }
  [ ${#games_cn_urls[@]} -gt 0 ] && { merge_group "games-cn" "${games_cn_urls[@]}" || log_fatal "games-cn 合并失败"; }
  [ ${#games_noncn_urls[@]} -gt 0 ] && { merge_group "games-noncn" "${games_noncn_urls[@]}" || log_fatal "games-noncn 合并失败"; }
  [ ${#ai_cn_urls[@]} -gt 0 ] && { merge_group "ai-cn" "${ai_cn_urls[@]}" || log_fatal "ai-cn 合并失败"; }
  [ ${#ai_noncn_urls[@]} -gt 0 ] && { merge_group "ai-noncn" "${ai_noncn_urls[@]}" || log_fatal "ai-noncn 合并失败"; }
  [ ${#media_urls[@]} -gt 0 ] && { merge_group "media" "${media_urls[@]}" || log_fatal "media 合并失败"; }
  [ ${#network_cn_urls[@]} -gt 0 ] && { merge_group "network-cn" "${network_cn_urls[@]}" || log_fatal "network-cn 合并失败"; }
  [ ${#network_noncn_urls[@]} -gt 0 ] && { merge_group "network-noncn" "${network_noncn_urls[@]}" || log_fatal "network-noncn 合并失败"; }
  [ ${#cdn_urls[@]} -gt 0 ] && { merge_group "cdn" "${cdn_urls[@]}" || log_fatal "cdn 合并失败"; }
  [ ${#hkmotw_urls[@]} -gt 0 ] && { merge_group "hkmotw" "${hkmotw_urls[@]}" || log_fatal "hkmotw 合并失败"; }
  [ ${#private_urls[@]} -gt 0 ] && { merge_group "private" "${private_urls[@]}" || log_fatal "private 合并失败"; }

  log_info "✅ === 第3步完成 ==="
  log_info ""

  # === 步骤4: Python 后处理 ===
  log_info "🐍 === 第4步: Python 后处理 ==="
  if ! "$PYTHON_SCRIPT_PATH" --step step2; then
    log_fatal "Python step2 失败"
  fi
  log_info "✅ === 第4步完成 ==="
  log_info ""

  # === 步骤5: 编译 Source 目录的 SRS ===
  log_info "⚙️  === 第5步: 编译 Source 规则集 ==="
  compile_all_srs
  log_info ""

  # === 步骤6: 【新增】独立编译 Common 目录的 SRS ===
  log_info "⚙️  === 第6步: 编译 Common 规则集(增量更新后) ==="
  compile_common_srs
  log_info ""

  # === 步骤7: 清理备份 ===
  cleanup_old_backups
  log_info ""

  # === 完成 ===
  log_info "=========================================="
  log_info "🎉 全部任务完成!"
  log_info "=========================================="
  log_info "📁 源文件目录: $SOURCE_DIR"
  log_info "📁 子集目录:   $SUBSET_DIR"
  log_info "📁 公共目录:   $COMMON_DIR"
  log_info "📁 编译目录:   $SRS_DIR"
  log_info "📋 日志文件:   $LOG_FILE"
  log_info "=========================================="
  log_info "结束时间: $(date '+%Y-%m-%d %H:%M:%S')"
  log_info ""

  # 恢复原始输出
  exec 1>&3 2>&4
}

# ============================================================================
# 脚本入口
# ============================================================================

# 初始化日志
init_logging

# 执行主流程
main "$@"

# 正常退出 (cleanup_all 会被 EXIT trap 自动调用)
exit 0
