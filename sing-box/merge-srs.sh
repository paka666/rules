#!/usr/bin/env bash
# ============================================================================
# merge-srs.sh - Sing-box Rule Set Merge Script
# ============================================================================

# 检查 Bash 版本
if [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
  echo "Error: Bash 4.0+ is required. On macOS, install via 'brew install bash'." >&2
  exit 1
fi

set -euo pipefail

# ============================================================================
# 1. 基础环境与日志配置
# ============================================================================

# 获取脚本所在目录的绝对路径
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

# 日志配置
readonly LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "$LOG_DIR"
readonly LOG_FILE="${LOG_DIR}/merge-$(date '+%Y%m%d-%H%M%S').log"

# 保存原始文件描述符
exec 3>&1
exec 4>&2

# 重定向所有输出到屏幕和日志文件 (兼容 Linux/macOS 进程替换)
echo "--- Logging initialized: $LOG_FILE ---"
exec > >(tee -a "$LOG_FILE") 2>&1

# 定义带颜色的日志函数
log_info() {
  echo -e "\033[32m[INFO]\033[0m $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

log_warn() {
  echo -e "\033[33m[WARN]\033[0m $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
}

log_error() {
  local msg="[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $*"
  echo -e "\033[31m${msg}\033[0m" >&2
  if [ $# -gt 1 ]; then
    shift
    echo "$*" >> "$LOG_FILE"
  fi
}

log_fatal() {
  local msg="[FATAL] $(date '+%Y-%m-%d %H:%M:%S') - $*"
  echo -e "\033[41;37m${msg}\033[0m" >&2
  exec 1>&3 2>&4
  exit 1
}

log_info "=== Script started at $(date) ==="
log_info "Logging to: $LOG_FILE"

# ============================================================================
# 2. 常量定义
# ============================================================================
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
readonly PYTHON_SCRIPT_PATH="${TEMP_DIR}/process_rules.py"

# ============================================================================
# 3. 清理与信号处理
# ============================================================================
cleanup_temp() {
  if [ -d "$TEMP_DIR" ] && [[ "$TEMP_DIR" == "${SCRIPT_DIR}/temp" ]]; then
    log_info "Cleaning up temporary directory: $TEMP_DIR"
    rm -rf "$TEMP_DIR"
  fi
}

trap 'cleanup_temp' EXIT
trap 'cleanup_temp; exit 130' INT
trap 'cleanup_temp; exit 143' TERM

# ============================================================================
# 4. 系统检查
# ============================================================================
check_disk_space() {
  local target_dir="${1:-.}"
  local available_mb
  if available_mb=$(df -m "$target_dir" 2>/dev/null | awk 'NR==2 {print $4}'); then
    if [ "$available_mb" -lt "$MIN_DISK_SPACE_MB" ]; then
      log_fatal "Insufficient disk space: ${available_mb}MB available, ${MIN_DISK_SPACE_MB}MB required"
    fi
    log_info "Disk space check passed: ${available_mb}MB available"
  else
    log_warn "Could not check disk space, proceeding anyway"
  fi
}

# 工具检测
HAS_FLOCK=false
if command -v flock &>/dev/null; then
  HAS_FLOCK=true
  log_info "flock detected, file locking enabled"
fi

log_info "Checking dependencies..."
for cmd in sing-box jq python3; do
  if ! command -v "$cmd" &>/dev/null; then
    log_fatal "Missing required command: $cmd"
  fi
done
log_info "All dependencies satisfied"

detect_download_tool() {
  if command -v curl &>/dev/null; then
    echo "curl"
    log_info "Using curl for downloads"
  elif command -v wget &>/dev/null; then
    if wget --help 2>&1 | grep -q -- '--fail'; then
      echo "wget"
      log_info "Using wget (with --fail support) for downloads"
    else
      echo "wget-basic"
      log_warn "Using wget (without --fail support) for downloads"
    fi
  else
    log_fatal "Neither curl nor wget found"
  fi
}

readonly DOWNLOAD_TOOL=$(detect_download_tool)

# ============================================================================
# 5. 核心函数
# ============================================================================

download_file() {
  local url="$1"
  local output="$2"
  local timeout="${3:-$DOWNLOAD_TIMEOUT}"
  local dl_log
  dl_log=$(mktemp "${TEMP_DIR}/dl-XXXXXX.log") || return 1

  case "$DOWNLOAD_TOOL" in
    curl)
      if ! curl -fsSL --max-time "$timeout" --retry 3 "$url" -o "$output" 2>"$dl_log"; then
        log_error "Download failed: $url" "$(cat "$dl_log")"
        rm -f "$dl_log"
        return 1
      fi
      ;;
    wget)
      if ! wget -q --no-dns-cache --timeout="$timeout" --tries=3 --fail "$url" -O "$output" 2>"$dl_log"; then
        log_error "Download failed: $url" "$(cat "$dl_log")"
        rm -f "$dl_log"
        return 1
      fi
      ;;
    wget-basic)
      if ! wget -q --no-dns-cache --timeout="$timeout" --tries=3 "$url" -O "$output" 2>"$dl_log"; then
        log_error "Download failed: $url" "$(cat "$dl_log")"
        rm -f "$dl_log"
        return 1
      fi
      ;;
  esac
  rm -f "$dl_log"
  return 0
}

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

# ============================================================================
# 6. Python 脚本生成
# ============================================================================
log_info "=== Step 0: Setting up environment ==="
check_disk_space "."
mkdir -p "$TEMP_DIR" "$SRS_DIR" "$SOURCE_DIR" "$SUBSET_DIR" "$COMMON_DIR" "${SUBSET_DIR}/tmp"

cat << 'PYTHON_SCRIPT_EOF' > "$PYTHON_SCRIPT_PATH"
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Sing-box Rule Set Processing Script
全局错误标志 has_critical_error，确保传播到 Bash
"""

import json
import ipaddress
import sys
import re
import argparse
from pathlib import Path
from typing import List, Set, Dict, Any, Tuple
from collections import defaultdict

has_critical_error = False
error_counts = defaultdict(int)

BASE_DIR = Path.cwd()
SOURCE_DIR = BASE_DIR / "json/source"
SUBSET_DIR = BASE_DIR / "json/subset"
COMMON_DIR = BASE_DIR / "json/common"

def mark_critical_error(msg: str):
    """标记发生严重错误"""
    global has_critical_error
    has_critical_error = True
    print(f"[CRITICAL ERROR] {msg}", file=sys.stderr)

def merge_cidrs(cidrs_list: Set[str]) -> List[str]:
    """合并和验证 CIDR 地址列表"""
    valid_ip_nets = []

    for cidr_str in cidrs_list:
        if not cidr_str:
            continue

        s_clean = re.sub(r'\s+', '', cidr_str.strip())
        if not s_clean:
            continue

        try:
            net = ipaddress.ip_network(s_clean, strict=False)
            valid_ip_nets.append(net)
        except ValueError as e:
            error_counts['invalid_ip'] += 1
            if error_counts['invalid_ip'] <= 10:
                print(f"[WARNING] Invalid IP/CIDR ignored: '{cidr_str}' - {e}", file=sys.stderr)

    if not valid_ip_nets:
        return []

    v4_nets = [n for n in valid_ip_nets if n.version == 4]
    v6_nets = [n for n in valid_ip_nets if n.version == 6]

    merged_v4 = list(ipaddress.collapse_addresses(v4_nets)) if v4_nets else []
    merged_v6 = list(ipaddress.collapse_addresses(v6_nets)) if v6_nets else []

    sorted_v4 = sorted(merged_v4, key=lambda n: (n.network_address, n.prefixlen))
    sorted_v6 = sorted(merged_v6, key=lambda n: (n.network_address, n.prefixlen))

    return [str(n) for n in sorted_v4] + [str(n) for n in sorted_v6]

def normalize_domains_and_suffixes(
    all_domains: Set[str],
    all_domain_suffixes: Set[str]
) -> Tuple[List[str], List[str]]:
    """规范化域名和后缀"""

    def _normalize_item(raw: str) -> str | None:
        if not raw:
            return None

        s = re.sub(r'\s+', '', raw.strip())
        if not s:
            return None

        s = re.sub(r'^(?:\.www\.|www\.)', '', s, flags=re.IGNORECASE)
        s = s.lstrip('.').lower()

        return s if s else None

    normalized_set: Set[str] = set()
    for item in all_domains | all_domain_suffixes:
        cleaned = _normalize_item(item)
        if cleaned:
            normalized_set.add(cleaned)

    final_domains = sorted(list(normalized_set))
    final_domain_suffixes = sorted([f".{d}" for d in normalized_set])

    return final_domains, final_domain_suffixes

def process_json_file(file_path: Path):
    """处理单个 JSON 文件"""
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            data = json.load(f)
    except json.JSONDecodeError as e:
        mark_critical_error(f"Invalid JSON: {file_path.name} - {e}")
        return
    except IOError as e:
        mark_critical_error(f"Cannot read file: {file_path.name} - {e}")
        return

    if 'rules' not in data or not isinstance(data['rules'], list):
        mark_critical_error(f"Invalid format (no 'rules' list): {file_path.name}")
        return

    allowed_keys = {
        'domain',
        'domain_suffix',
        'domain_keyword',
        'domain_regex',
        'ip_cidr'
    }

    all_domains = set()
    all_domain_suffixes = set()
    all_domain_keywords = set()
    all_domain_regex = set()
    all_ip_cidrs = set()

    for rule_obj in data.get('rules', []):
        if not isinstance(rule_obj, dict):
            continue

        unknown_keys = set(rule_obj.keys()) - allowed_keys
        if unknown_keys:
            mark_critical_error(f"Unknown rule keys in {file_path.name}: {unknown_keys}")
            print("Script aborted. Please check JSON format or update 'allowed_keys'.", file=sys.stderr)
            sys.exit(1)

        all_domains.update(rule_obj.get('domain', []))
        all_domain_suffixes.update(rule_obj.get('domain_suffix', []))
        all_domain_keywords.update(rule_obj.get('domain_keyword', []))
        all_domain_regex.update(rule_obj.get('domain_regex', []))
        all_ip_cidrs.update(rule_obj.get('ip_cidr', []))

    sorted_domains, sorted_suffixes = normalize_domains_and_suffixes(all_domains, all_domain_suffixes)
    sorted_keywords = sorted(list(all_domain_keywords))
    sorted_regex = sorted(list(all_domain_regex))
    sorted_ips = merge_cidrs(all_ip_cidrs)

    domain_rule_obj = {}
    ip_rule_obj = {}

    if sorted_domains:
        domain_rule_obj['domain'] = sorted_domains
    if sorted_suffixes:
        domain_rule_obj['domain_suffix'] = sorted_suffixes
    if sorted_keywords:
        domain_rule_obj['domain_keyword'] = sorted_keywords
    if sorted_regex:
        domain_rule_obj['domain_regex'] = sorted_regex

    if sorted_ips:
        ip_rule_obj['ip_cidr'] = sorted_ips

    new_rules = []
    if domain_rule_obj:
        new_rules.append(domain_rule_obj)
    if ip_rule_obj:
        new_rules.append(ip_rule_obj)

    new_data = {"version": 1, "rules": new_rules}

    try:
        with open(file_path, 'w', encoding='utf-8') as f:
            json.dump(new_data, f, indent=2, ensure_ascii=False)
    except IOError as e:
        mark_critical_error(f"Cannot write file: {file_path.name} - {e}")

def get_rule_data(file_path: Path) -> Dict[str, Dict[str, Any]]:
    """获取规则数据"""
    domain_obj = {}
    ip_obj = {}
    all_keys_obj = {}

    if not file_path.exists():
        return {"domain": {}, "ip": {}, "all_keys": {}}

    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            data = json.load(f)

        for rule in data.get('rules', []):
            if not isinstance(rule, dict):
                continue

            for key, values in rule.items():
                if isinstance(values, list):
                    all_keys_obj.setdefault(key, set()).update(values)
                elif isinstance(values, str):
                    all_keys_obj.setdefault(key, set()).add(values)
                else:
                    print(f"[WARNING] Invalid value type for key '{key}': {type(values).__name__}", file=sys.stderr)

            if 'ip_cidr' in rule:
                ip_obj = rule
            else:
                domain_obj.update(rule)

    except Exception as e:
        mark_critical_error(f"Failed to load rule data: {file_path.name} - {e}")
        return {"domain": {}, "ip": {}, "all_keys": {}}

    all_keys_list_obj = {k: list(v) for k, v in all_keys_obj.items()}

    return {"domain": domain_obj, "ip": ip_obj, "all_keys": all_keys_list_obj}

def find_and_remove_dupes(file_cn_path: Path, file_noncn_path: Path, common_path: Path):
    """查找并移除重复规则"""
    data_cn = get_rule_data(file_cn_path)
    data_noncn = get_rule_data(file_noncn_path)
    data_common_old = get_rule_data(common_path)

    new_common_all_keys = {}
    all_rule_keys = ['domain', 'domain_suffix', 'domain_keyword', 'domain_regex', 'ip_cidr']

    for key in all_rule_keys:
        set_cn = set(data_cn["all_keys"].get(key, []))
        set_noncn = set(data_noncn["all_keys"].get(key, []))
        set_common_old = set(data_common_old["all_keys"].get(key, []))

        common_items_new = set_cn.intersection(set_noncn)
        common_items_all = common_items_new.union(set_common_old)

        if common_items_all:
            new_common_all_keys[key] = list(common_items_all)

            remaining_cn = set_cn - common_items_all
            remaining_noncn = set_noncn - common_items_all

            if remaining_cn:
                data_cn["all_keys"][key] = list(remaining_cn)
            else:
                data_cn["all_keys"].pop(key, None)

            if remaining_noncn:
                data_noncn["all_keys"][key] = list(remaining_noncn)
            else:
                data_noncn["all_keys"].pop(key, None)

    def write_rules_from_all_keys(file_path: Path, all_keys_data: Dict[str, Any]):
        domain_rule_obj = {}
        ip_rule_obj = {}

        domain_keys = ['domain', 'domain_suffix', 'domain_keyword', 'domain_regex']
        ip_keys = ['ip_cidr']

        for key in domain_keys:
            if key in all_keys_data:
                domain_rule_obj[key] = sorted(all_keys_data[key])

        for key in ip_keys:
            if key in all_keys_data and all_keys_data[key]:
                sorted_merged_ips = merge_cidrs(set(all_keys_data[key]))
                if sorted_merged_ips:
                    ip_rule_obj[key] = sorted_merged_ips

        new_rules = []
        if domain_rule_obj:
            new_rules.append(domain_rule_obj)
        if ip_rule_obj:
            new_rules.append(ip_rule_obj)

        new_data = {"version": 1, "rules": new_rules}

        try:
            file_path.parent.mkdir(parents=True, exist_ok=True)
            with open(file_path, 'w', encoding='utf-8') as f:
                json.dump(new_data, f, indent=2, ensure_ascii=False)
        except IOError as e:
            mark_critical_error(f"Cannot write common file: {file_path.name} - {e}")

    # 写新 common
    write_rules_from_all_keys(common_path, new_common_all_keys)

    # 写更新后的 cn/noncn
    write_rules_from_all_keys(file_cn_path, data_cn["all_keys"])
    write_rules_from_all_keys(file_noncn_path, data_noncn["all_keys"])

def run_step1_pre_merge():
    """预合并规范化"""
    SOURCE_DIR.mkdir(exist_ok=True)
    SUBSET_DIR.mkdir(exist_ok=True)
    for f in SOURCE_DIR.glob("*.json"):
        if f.is_file():
            process_json_file(f)
    for f in SUBSET_DIR.glob("*.json"):
        if f.is_file():
            process_json_file(f)

def run_step2_post_merge():
    """后合并处理，包括去重"""
    SOURCE_DIR.mkdir(exist_ok=True)
    COMMON_DIR.mkdir(exist_ok=True)

    # 处理 source JSON (排除备份)
    for f in SOURCE_DIR.glob("*.json"):
        if f.is_file() and not re.match(r'^\d{8}T\d{6}', f.name):
            process_json_file(f)

    # 处理对称组去重 (e.g., games-cn/noncn, ai-cn/noncn, network-cn/noncn)
    groups = [("games-cn", "games-noncn"), ("ai-cn", "ai-noncn"), ("network-cn", "network-noncn")]
    for cn_group, noncn_group in groups:
        cn_path = SOURCE_DIR / f"{cn_group}.json"
        noncn_path = SOURCE_DIR / f"{noncn_group}.json"
        common_path = COMMON_DIR / f"{cn_group.rsplit('-',1)[0]}-common.json"
        if cn_path.exists() and noncn_path.exists():
            find_and_remove_dupes(cn_path, noncn_path, common_path)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--step', choices=['step1', 'step2'], required=True)
    args = parser.parse_args()

    if args.step == 'step1':
        run_step1_pre_merge()
    elif args.step == 'step2':
        run_step2_post_merge()

    # 退出码检查
    if has_critical_error:
        print("\n[FATAL] Critical errors occurred during Python processing.", file=sys.stderr)
        sys.exit(1)
    else:
        sys.exit(0)

if __name__ == "__main__":
    main()
PYTHON_SCRIPT_EOF
chmod +x "$PYTHON_SCRIPT_PATH"

# ============================================================================
# 7. JSON 验证函数
# ============================================================================
validate_and_fix_json() {
  local file="$1"
  local group_name="${2:-unknown}"
  local skip_lock="${3:-false}"

  local temp_file
  temp_file=$(mktemp "${TEMP_DIR}/validate.tmp.XXXXXX.json") || return 1
  local jq_err_file
  jq_err_file=$(mktemp "${TEMP_DIR}/validate.err.XXXXXX.log") || return 1
  local lock_file="${file}.lock"

  cleanup_validate() { rm -f "$temp_file" "$jq_err_file" "$lock_file"; }
  trap cleanup_validate RETURN

  (
    # 仅非跳过时加锁
    if [ "$HAS_FLOCK" = true ] && [ "$skip_lock" != "true" ]; then
      exec 200>"$lock_file"
      if ! flock -n 200; then
        log_error "File is locked: $file"
        exit 1
      fi
    fi

    if [ ! -f "$file" ] || [ ! -s "$file" ]; then
      log_error "File not found or empty: $file"
      exit 1
    fi

    if head -n 1 "$file" 2>/dev/null | grep -qi "<!DOCTYPE\|<html"; then
      log_error "File is HTML (download error): $file"
      rm -f "$file"
      exit 1
    fi

    if jq empty "$file" >/dev/null 2>"$jq_err_file"; then
      # 检查 version
      if ! jq -e '.version' "$file" >/dev/null 2>&1; then
        if jq '.version = 1' "$file" > "$temp_file" 2>"$jq_err_file"; then
          mv -f "$temp_file" "$file"
        else
          log_error "Failed to add version: $file" "$(cat "$jq_err_file")"  # [优化3] 详情
          exit 1
        fi
      fi
      exit 0
    else

      if jq '.' "$file" > "$temp_file" 2>"$jq_err_file" && [ -s "$temp_file" ]; then
        mv -f "$temp_file" "$file"; exit 0
      fi
      if jq 'if type == "array" then {version: 1, rules: .} else . end' "$file" > "$temp_file" 2>"$jq_err_file" && [ -s "$temp_file" ]; then
        mv -f "$temp_file" "$file"; exit 0
      fi

      log_error "Invalid JSON and fix failed: $file" "$(cat "$jq_err_file")"
      rm -f "$file"
      exit 1
    fi
  )
  return $?
}

# ============================================================================
# 8. 预处理配置
# ============================================================================
preprocess_ruleset() {
  local base_url="$1"
  local exclude_url="$2"
  local output_file="$3"
  local base_temp
  base_temp=$(mktemp "${TEMP_DIR}/preprocess-base.XXXXXX.json") || return 1
  local exclude_temp
  exclude_temp=$(mktemp "${TEMP_DIR}/preprocess-exclude.XXXXXX.json") || return 1
  local jq_err_file
  jq_err_file=$(mktemp "${TEMP_DIR}/preprocess-jq.XXXXXX.err") || return 1

  cleanup_preprocess() { rm -f "$base_temp" "$exclude_temp" "$jq_err_file"; }
  trap cleanup_preprocess RETURN

  # 下载 base
  if ! download_file "$base_url" "$base_temp"; then
    log_error "Failed to download base: $base_url"
    return 1
  fi

  if ! jq empty "$base_temp" >/dev/null 2>"$jq_err_file"; then
    log_error "Invalid JSON from base URL: $base_url" "$(cat "$jq_err_file")"
    return 1
  fi

  # 下载 exclude
  if [ -n "$exclude_url" ]; then
    if ! download_file "$exclude_url" "$exclude_temp" "$DOWNLOAD_TIMEOUT"; then
      log_warn "Failed to download exclude: $exclude_url, using empty rules"
      echo '{"version": 1, "rules": []}' > "$exclude_temp"
    fi
  else
    echo '{"version": 1, "rules": []}' > "$exclude_temp"
  fi

  if ! jq empty "$exclude_temp" >/dev/null 2>"$jq_err_file"; then
    log_error "Invalid JSON from exclude URL: $exclude_url" "$(cat "$jq_err_file")"
    echo '{"version": 1, "rules": []}' > "$exclude_temp"
  fi

  # 处理规则 (排除)
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
  ' "$base_temp" > "$output_file" 2>"$jq_err_file"; then
    log_error "jq processing failed for preprocess: $base_url" "$(cat "$jq_err_file")"
    return 1
  fi

  if ! jq empty "$output_file" >/dev/null 2>"$jq_err_file"; then
    log_error "Generated JSON invalid: $output_file" "$(cat "$jq_err_file")"
    return 1
  fi

  log_info "Successfully generated subset: $output_file"
}

has_valid_array_elements() {
  local -n arr=$1
  [ ${#arr[@]} -gt 0 ] && [ -n "${arr[0]}" ]
}

# 预处理配置
preprocess_configs=(
  # game
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

  # ai
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-ai-cn.json"
  "${SUBSET_DIR}/tmp/geosite-category-ai-cn@!cn.json"
  "${SUBSET_DIR}/geosite-category-ai-cn@cn.json"

  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-doubao.json"
  "${SUBSET_DIR}/tmp/geosite-doubao@!cn.json"
  "${SUBSET_DIR}/doubao@cn.json"

  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-jetbrains.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-jetbrains@cn.json"
  "${SUBSET_DIR}/jetbrains@!cn.json"

  # network
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
# ============================================================================
# 步骤 1: 执行预处理
# ============================================================================
if has_valid_array_elements preprocess_configs; then
  log_info "=== Step 1: Running 'subset' file preprocessing ==="

  total=${#preprocess_configs[@]}
  pids=()

  for ((i=0; i<total; i+=3)); do
    if [ ${#pids[@]} -ge $MAX_CONCURRENT_DOWNLOADS ]; then
      log_info "Waiting for current batch (${#pids[@]} jobs)..."
      failed=0
      for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
          failed=1
          log_error "Preprocessing job failed (PID: $pid)"
        fi
      done

      if [ $failed -eq 1 ]; then
        log_fatal "Some preprocessing tasks failed, aborting"
      fi

      pids=()
    fi

    preprocess_ruleset "${preprocess_configs[i]}" "${preprocess_configs[i+1]}" "${preprocess_configs[i+2]}" &
    pids+=($!)
  done

  if [ ${#pids[@]} -gt 0 ]; then
    log_info "Waiting for final batch (${#pids[@]} jobs)..."
    failed=0
    for pid in "${pids[@]}"; do
      if ! wait "$pid"; then
        failed=1
        log_error "Preprocessing job failed (PID: $pid)"
      fi
    done

    if [ $failed -eq 1 ]; then
      log_fatal "Some preprocessing tasks failed"
    fi
  fi

  log_info "=== Step 1: 'subset' file preprocessing completed ==="
else
  log_info "=== Step 1: Skipped (no preprocess_configs) ==="
fi

# ============================================================================
# 步骤 2: Python 预合并
# ============================================================================
log_info "=== Step 2: Running [Python Step 1] (pre-merge normalization) ==="
if ! "$PYTHON_SCRIPT_PATH" --step step1; then
  log_fatal "Python step 1 failed (check logs above)"
fi
log_info "=== Step 2: [Python Step 1] completed ==="

# ============================================================================
# 9. 合并函数
# ============================================================================
merge_group() {
  local GROUP_NAME=$1
  shift
  local URLS=("$@")
  local LOCAL_JSON_FILE="${SOURCE_DIR}/${GROUP_NAME}.json"

  local merge_log
  merge_log=$(mktemp "${TEMP_DIR}/merge-${GROUP_NAME}-XXXXXX.log") || return 1

  cleanup_merge() {
    rm -f "${TEMP_DIR}/input-${GROUP_NAME}-"*.json
    rm -f "${TEMP_DIR}/merged-${GROUP_NAME}.json"
    rm -f "$merge_log"
  }
  trap cleanup_merge RETURN

  log_info "Starting merge for group: $GROUP_NAME"

  local file_index=1
  local pids=()

  # 第一遍：处理本地文件
  for url in "${URLS[@]}"; do
    [ -z "$url" ] && continue

    if is_local_path "$url"; then
      local output_file="${TEMP_DIR}/input-${GROUP_NAME}-${file_index}.json"
      if [ -f "$url" ] && [ -s "$url" ]; then
        cp "$url" "$output_file"
        log_info "Copied local file: $url"

        if validate_and_fix_json "$output_file" "$GROUP_NAME" "false"; then
          ((file_index++))
        else
          log_error "Local file validation failed: $url"
          rm -f "$output_file"
        fi
      else
        log_error "Local file not found or empty: $url"
      fi
    fi
  done

  # 第二遍：并发下载远程文件
  local download_start_index=$file_index

  for url in "${URLS[@]}"; do
    [ -z "$url" ] && continue

    if ! is_local_path "$url"; then
      if [ ${#pids[@]} -ge $MAX_CONCURRENT_DOWNLOADS ]; then
        log_info "Waiting for download batch (${#pids[@]} jobs)..."
        local failed=0
        for pid in "${pids[@]}"; do
          if ! wait "$pid"; then
            failed=1
          fi
        done

        if [ $failed -eq 1 ]; then
          log_error "Some downloads failed for group $GROUP_NAME"
          return 1
        fi

        pids=()
      fi

      (
        local output_file="${TEMP_DIR}/input-${GROUP_NAME}-${file_index}.json"

        log_info "Downloading: $url"
        if download_file "$url" "$output_file" "$DOWNLOAD_TIMEOUT"; then
          log_info "Downloaded: $url"

          if validate_and_fix_json "$output_file" "$GROUP_NAME" "true"; then
            log_info "Validated: $url"
          else
            log_error "Validation failed: $url"
            rm -f "$output_file"
            exit 1
          fi
        else
          log_error "Download failed: $url"
          rm -f "$output_file"
          exit 1
        fi
      ) &

      pids+=($!)
      ((file_index++))
    fi
  done

  # 等待所有下载
  if [ ${#pids[@]} -gt 0 ]; then
    log_info "Waiting for final download batch (${#pids[@]} jobs)..."
    local failed=0
    for pid in "${pids[@]}"; do
      if ! wait "$pid"; then
        failed=1
      fi
    done

    if [ $failed -eq 1 ]; then
      log_fatal "Group $GROUP_NAME has failed downloads"
    fi
  fi

  # 检查输入
  shopt -s nullglob
  local inputs=("${TEMP_DIR}/input-${GROUP_NAME}-"*.json)
  shopt -u nullglob

  if [ "${#inputs[@]}" -eq 0 ]; then
    log_fatal "Group $GROUP_NAME has no available input files"
  fi

  # 合并&捕获到日志
  log_info "Merging ${#inputs[@]} files for group $GROUP_NAME..."
  local merged_tmp="${TEMP_DIR}/merged-${GROUP_NAME}.json"
  local config_flags=()
  for input_file in "${inputs[@]}"; do
    config_flags+=("-c" "$input_file")
  done

  if ! sing-box rule-set merge "$merged_tmp" "${config_flags[@]}" > "$merge_log" 2>&1; then
    log_error "sing-box merge failed for $GROUP_NAME" "$(cat "$merge_log")"
    return 1
  fi

  # 时间戳
  if [ -f "$LOCAL_JSON_FILE" ]; then
    local TIMESTAMP
    if date --version 2>&1 | grep -q GNU; then
      TIMESTAMP=$(date -u +%Y%m%dT%H%M%S%NZ)
    else
      # macOS: 秒级 + PID
      TIMESTAMP=$(date -u +%Y%m%dT%H%M%S)-$$
    fi
    local backup_file="${SOURCE_DIR}/${TIMESTAMP}-${GROUP_NAME}.json"
    mv -f "$LOCAL_JSON_FILE" "$backup_file"
    log_info "Backed up old source to: $backup_file"
  fi

  mv -f "$merged_tmp" "$LOCAL_JSON_FILE"
  log_info "Saved merged JSON to: $LOCAL_JSON_FILE"
  log_info "Completed merge for $GROUP_NAME"
}

# ============================================================================
# 10. 编译函数
# ============================================================================
compile_srs_file() {
  local GROUP_NAME=$1
  local LOCAL_JSON_FILE="${SOURCE_DIR}/${GROUP_NAME}.json"
  local OUTPUT_SRS_FILE="${SRS_DIR}/${GROUP_NAME}.srs"

  local compile_log
  compile_log=$(mktemp "${TEMP_DIR}/compile-${GROUP_NAME}-XXXXXX.log") || return 1

  cleanup_compile() {
    rm -f "$compile_log"
  }
  trap cleanup_compile RETURN

  if [ ! -f "$LOCAL_JSON_FILE" ]; then
    log_warn "Compile skipped: not found $LOCAL_JSON_FILE"
    return 0
  fi

  # 查找最新备份
  local json_backup
  json_backup=$(find "$SOURCE_DIR" -name "*-${GROUP_NAME}.json" -type f 2>/dev/null | sort -r | head -n 1)

  log_info "Compiling SRS file for $GROUP_NAME..."

  if sing-box rule-set compile "$LOCAL_JSON_FILE" -o "$OUTPUT_SRS_FILE" > "$compile_log" 2>&1; then
    log_info "Successfully compiled: $OUTPUT_SRS_FILE"
    return 0
  else
    log_error "Compilation failed for $GROUP_NAME" "$(cat "$compile_log")"
    # 回滚
    if [ -n "$json_backup" ] && [ -f "$json_backup" ]; then
      log_info "Attempting restore from backup: $json_backup"
      cp -a "$json_backup" "$LOCAL_JSON_FILE"

      if sing-box rule-set compile "$LOCAL_JSON_FILE" -o "$OUTPUT_SRS_FILE" > "$compile_log" 2>&1; then
        log_info "Successfully compiled from backup"
        return 0
      else
        log_error "Backup compilation failed" "$(cat "$compile_log")"
        return 1
      fi
    else
      log_error "No backup for recovery"
      return 1
    fi
  fi
}

compile_all_srs() {
  log_info "=== Step 5: Compiling all SRS files ==="
  local groups=("ads" "games-cn" "games-noncn" "ai-cn" "ai-noncn" "media" "network-cn" "network-noncn" "cdn" "hkmotw" "private")

  local pids=()
  local failed_groups=()

  for group in "${groups[@]}"; do
    if [ ${#pids[@]} -ge $MAX_CONCURRENT_COMPILES ]; then
      log_info "Waiting for compile batch..."
      for pid in "${pids[@]}"; do
        wait "$pid" || failed_groups+=("$group")
      done
      pids=()
    fi

    compile_srs_file "$group" &
    pids+=($!)
  done

  if [ ${#pids[@]} -gt 0 ]; then
    log_info "Waiting for final compile batch..."
    for pid in "${pids[@]}"; do
      wait "$pid" || true
    done
  fi

  if [ ${#failed_groups[@]} -gt 0 ]; then
    log_error "Failed to compile: ${failed_groups[*]}"
    log_fatal "Some compilation tasks failed"
  fi

  log_info "=== Step 5: SRS compilation completed ==="
}

# ============================================================================
# 11. 清理旧备份
# ============================================================================
cleanup_old_backups() {
  log_info "=== Step 6: Cleaning old backups (keeping $BACKUP_KEEP_COUNT per group) ==="
  local groups=("ads" "games-cn" "games-noncn" "ai-cn" "ai-noncn" "media" "network-cn" "network-noncn" "cdn" "hkmotw" "private")

  for group in "${groups[@]}"; do
    local backup_count
    backup_count=$(find "$SOURCE_DIR" -name "*-${group}.json" -type f 2>/dev/null | wc -l)

    if [ "$backup_count" -gt "$BACKUP_KEEP_COUNT" ]; then
      log_info "Cleaning backups for $group (found: $backup_count, keeping: $BACKUP_KEEP_COUNT)"
      find "$SOURCE_DIR" -name "*-${group}.json" -type f 2>/dev/null | \
        sort -r | \
        tail -n +$((BACKUP_KEEP_COUNT + 1)) | \
        xargs -r rm -f 2>/dev/null || true
    fi
  done

  log_info "=== Step 6: Backup cleanup completed ==="
}

# ============================================================================
# 12. URL 定义
# ============================================================================
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
ai_cn_urls=(
  "${SOURCE_DIR}/ai-cn.json"
  "${SUBSET_DIR}/doubao@cn.json"
  "${SUBSET_DIR}/geosite-category-ai-cn@cn.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-aixcoder.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-apple-intelligence.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-deepseek.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-jetbrains@cn.json"
)
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
media_urls=(
  "${SOURCE_DIR}/media.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-netflix.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-disney.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-netflix.json"
)
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
cdn_urls=(
  "${SOURCE_DIR}/cdn.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-cloudflare.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-cloudfront.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-fastly.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-google.json"
)
hkmotw_urls=(
  "${SOURCE_DIR}/hkmotw.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-hk.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-mo.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-tw.json"
)
private_urls=(
  "${SOURCE_DIR}/private.json"
  "${SUBSET_DIR}/geoip-private-manual.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-private.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-private.json"
)
# ============================================================================
# 13. 执行主流程
# ============================================================================

log_info "=== Step 3: Running main merge... ==="

if [ ${#ads_urls[@]} -gt 0 ]; then
  merge_group "ads" "${ads_urls[@]}" || log_error "Failed to merge ads"
fi
if [ ${#games_cn_urls[@]} -gt 0 ]; then
  merge_group "games-cn" "${games_cn_urls[@]}" || log_error "Failed to merge games-cn"
fi
if [ ${#games_noncn_urls[@]} -gt 0 ]; then
  merge_group "games-noncn" "${games_noncn_urls[@]}" || log_error "Failed to merge games-noncn"
fi
if [ ${#ai_cn_urls[@]} -gt 0 ]; then
  merge_group "ai-cn" "${ai_cn_urls[@]}" || log_error "Failed to merge ai-cn"
fi
if [ ${#ai_noncn_urls[@]} -gt 0 ]; then
  merge_group "ai-noncn" "${ai_noncn_urls[@]}" || log_error "Failed to merge ai-noncn"
fi
if [ ${#media_urls[@]} -gt 0 ]; then
  merge_group "media" "${media_urls[@]}" || log_error "Failed to merge media"
fi
if [ ${#network_cn_urls[@]} -gt 0 ]; then
  merge_group "network-cn" "${network_cn_urls[@]}" || log_error "Failed to merge network-cn"
fi
if [ ${#network_noncn_urls[@]} -gt 0 ]; then
  merge_group "network-noncn" "${network_noncn_urls[@]}" || log_error "Failed to merge network-noncn"
fi
if [ ${#cdn_urls[@]} -gt 0 ]; then
  merge_group "cdn" "${cdn_urls[@]}" || log_error "Failed to merge cdn"
fi
if [ ${#hkmotw_urls[@]} -gt 0 ]; then
  merge_group "hkmotw" "${hkmotw_urls[@]}" || log_error "Failed to merge hkmotw"
fi
if [ ${#private_urls[@]} -gt 0 ]; then
  merge_group "private" "${private_urls[@]}" || log_error "Failed to merge private"
fi

log_info "=== Step 3: Main merge completed ==="

# ============================================================================
# 步骤 4: Python 后处理
# ============================================================================
log_info "=== Step 4: Running [Python Step 2] (post-merge processing) ==="
if ! "$PYTHON_SCRIPT_PATH" --step step2; then
  log_fatal "Python step 2 failed (check logs above)"
fi
log_info "=== Step 4: [Python Step 2] completed ==="

# ============================================================================
# 步骤 5 & 6: 编译和清理
# ============================================================================
compile_all_srs
cleanup_old_backups

# ============================================================================
# 完成
# ============================================================================
log_info "==========================================="
log_info "All groups processed successfully!"
log_info "==========================================="
log_info "Source JSON files: $SOURCE_DIR/"
log_info "Subset JSON files: $SUBSET_DIR/"
log_info "Common JSON files: $COMMON_DIR/"
log_info "Compiled SRS files: $SRS_DIR/"
log_info "Log file: $LOG_FILE"
log_info "==========================================="
log_info "Script completed at $(date)"
