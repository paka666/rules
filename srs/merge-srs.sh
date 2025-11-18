#!/usr/bin/env bash
set -euo pipefail

# --- 脚本配置 ---
SOURCE_DIR="srs/json/source"
SUBSET_DIR="srs/json/subset"
COMMON_DIR="srs/json/common"
SRS_DIR="srs"
TEMP_DIR="temp"
PYTHON_SCRIPT_PATH="${TEMP_DIR}/process_rules.py"

# --- 自动清理临时目录 ---
cleanup_temp() {
  rm -rf "$TEMP_DIR"
}
trap cleanup_temp EXIT

# --- 检测系统工具 ---
HAS_FLOCK=false
if command -v flock &>/dev/null; then
  HAS_FLOCK=true
fi

# 依赖检查
for cmd in sing-box jq python3; do
  command -v "$cmd" &>/dev/null || { echo "❌ Missing $cmd"; exit 1; }
done

# --- 检测下载工具 ---
DOWNLOAD_TOOL=""
if command -v curl &>/dev/null; then
  DOWNLOAD_TOOL="curl"
  echo "✓ 检测到 curl，将使用 curl 进行下载"
elif command -v wget &>/dev/null; then
  if wget --help 2>&1 | grep -q -- '--fail'; then
    DOWNLOAD_TOOL="wget"
    echo "✓ 检测到 wget (支持 --fail)，将使用 wget 进行下载"
  else
    DOWNLOAD_TOOL="wget-basic"
    echo "⚠ 检测到 wget (不支持 --fail)，将使用基础模式"
  fi
else
  echo "❌ 错误：未找到 curl 或 wget，请安装其中之一"
  exit 1
fi

# --- 通用下载函数 ---
download_file() {
  local url="$1"
  local output="$2"
  local timeout="${3:-120}"

  case "$DOWNLOAD_TOOL" in
    curl)
      if ! curl -fsSL --max-time "$timeout" --retry 3 "$url" -o "$output"; then
        echo "    [错误] curl 下载失败: $url" >&2
        return 1
      fi
      ;;
    wget)
      if ! wget -q --timeout="$timeout" --tries=3 --fail "$url" -O "$output"; then
        echo "    [错误] wget 下载失败: $url" >&2
        return 1
      fi
      ;;
    wget-basic)
      if ! wget -q --timeout="$timeout" --tries=3 "$url" -O "$output"; then
        echo "    [错误] wget-basic 下载失败: $url" >&2
        return 1
      fi
      ;;
  esac
  return 0
}

# --- 步骤 0: 创建目录和 Python 脚本 ---
echo "--- 步骤 0: 正在设置环境 ---"
mkdir -p "$TEMP_DIR" "$SRS_DIR" "$SOURCE_DIR" "$SUBSET_DIR" "$COMMON_DIR" "${SUBSET_DIR}/tmp"

cat << 'EOF' > "$PYTHON_SCRIPT_PATH"
#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import json
import ipaddress
import sys
import re
import argparse
from pathlib import Path
from typing import List, Set, Dict, Any, Tuple

BASE_DIR = Path.cwd()
SOURCE_DIR = BASE_DIR / "srs/json/source"
SUBSET_DIR = BASE_DIR / "srs/json/subset"
COMMON_DIR = BASE_DIR / "srs/json/common"

def merge_cidrs(cidrs_list: Set[str]) -> List[str]:
    v4_nets = []
    v6_nets = []

    for cidr_str in cidrs_list:
        if not cidr_str:
            continue
        try:
            net = ipaddress.ip_network(cidr_str.strip(), strict=False)
            if net.version == 4:
                v4_nets.append(net)
            else:
                v6_nets.append(net)
        except ValueError as e:
            print(f"    [错误] 忽略无效的 IP/CIDR: '{cidr_str}' ({e})", file=sys.stderr)

    merged_v4 = list(ipaddress.collapse_addresses(v4_nets))
    merged_v6 = list(ipaddress.collapse_addresses(v6_nets))

    merged_v4.sort(key=lambda n: (n.network_address, n.prefixlen))
    merged_v6.sort(key=lambda n: (n.network_address, n.prefixlen))

    return [str(n) for n in merged_v4] + [str(n) for n in merged_v6]

def normalize_domains_and_suffixes(
    all_domains: Set[str],
    all_domain_suffixes: Set[str]
) -> Tuple[List[str], List[str]]:
    def strip_www(domain_set: Set[str]) -> Set[str]:
        normalized_set = set()
        for d in domain_set:
            d_stripped = d.strip()
            if not d_stripped:
                continue
            d_normalized = re.sub(r'^(?:\.www\.|www\.)', '', d_stripped)
            if d_normalized:
                normalized_set.add(d_normalized)
        return normalized_set

    domains_no_www = strip_www(all_domains)
    suffixes_no_www = strip_www(all_domain_suffixes)

    final_domains = set()
    final_domain_suffixes = set()

    for s in suffixes_no_www:
        clean_s = s.lstrip('.')
        if clean_s:
            final_domains.add(clean_s)
            final_domain_suffixes.add(f".{clean_s}")

    for d in domains_no_www:
        clean_d = d.lstrip('.')
        if clean_d:
            final_domains.add(clean_d)
            final_domain_suffixes.add(f".{clean_d}")

    return sorted(list(final_domains)), sorted(list(final_domain_suffixes))

def process_json_file(file_path: Path):
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            data = json.load(f)
    except json.JSONDecodeError as e:
        print(f"    [错误] 无法解析 JSON: {file_path.name} ({e})", file=sys.stderr)
        return
    except IOError as e:
        print(f"    [错误] 无法读取文件: {file_path.name} ({e})", file=sys.stderr)
        return

    if 'rules' not in data or not isinstance(data['rules'], list):
        print(f"    [错误] 格式无效，跳过 (无 'rules' 列表): {file_path.name}", file=sys.stderr)
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
            print(f"[致命错误] 在 {file_path.name} 中发现未知的规则键: {unknown_keys}", file=sys.stderr)
            print("脚本已中止。请检查 JSON 格式或更新脚本中的 'allowed_keys'。", file=sys.stderr)
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
        print(f"    [错误] 无法写入文件: {file_path.name} ({e})", file=sys.stderr)

def get_rule_data(file_path: Path) -> Dict[str, Dict[str, Any]]:
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
                # 改进的类型检查
                if isinstance(values, list):
                    all_keys_obj.setdefault(key, set()).update(values)
                elif isinstance(values, str):
                    all_keys_obj.setdefault(key, set()).add(values)
                else:
                    print(f"    [错误] 规则键 '{key}' 的值类型无效 ({type(values).__name__}): {values}", file=sys.stderr)

            if 'ip_cidr' in rule:
                ip_obj = rule
            else:
                domain_obj.update(rule)

    except Exception as e:
        print(f"    [错误] 加载规则数据时出错: {file_path.name} ({e})", file=sys.stderr)
        return {"domain": {}, "ip": {}, "all_keys": {}}

    all_keys_list_obj = {k: list(v) for k, v in all_keys_obj.items()}

    return {"domain": domain_obj, "ip": ip_obj, "all_keys": all_keys_list_obj}

def find_and_remove_dupes(file_cn_path: Path, file_noncn_path: Path, common_path: Path):
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
             if key in all_keys_data:
                try:
                    ip_nets = [ipaddress.ip_network(ip_str, strict=False) for ip_str in all_keys_data[key] if ip_str]
                    v4_nets = sorted([n for n in ip_nets if n.version == 4], key=lambda n: (n.network_address, n.prefixlen))
                    v6_nets = sorted([n for n in ip_nets if n.version == 6], key=lambda n: (n.network_address, n.prefixlen))
                    ip_rule_obj[key] = [str(n) for n in v4_nets] + [str(n) for n in v6_nets]
                except ValueError as e:
                    print(f"    [错误] 在 write_rules_from_all_keys 中排序 IP 时出错: {e}", file=sys.stderr)
                    ip_rule_obj[key] = sorted(all_keys_data[key])

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
            print(f"    [错误] 无法写入文件: {file_path.name} ({e})", file=sys.stderr)

    if new_common_all_keys:
        write_rules_from_all_keys(common_path, new_common_all_keys)

    write_rules_from_all_keys(file_cn_path, data_cn["all_keys"])
    write_rules_from_all_keys(file_noncn_path, data_noncn["all_keys"])

def run_step1_pre_merge():
    print("  --- 步骤 1 (Python): 正在规范化 'source' 目录... ---")
    SOURCE_DIR.mkdir(exist_ok=True)
    for f in SOURCE_DIR.glob("*.json"):
        if f.is_file():
            print(f"    正在处理 (source): {f.name}")
            process_json_file(f)

    print("  --- 步骤 1 (Python): 正在规范化 'subset' 目录... ---")
    SUBSET_DIR.mkdir(exist_ok=True)
    for f in SUBSET_DIR.glob("*.json"):
        if f.is_file():
            print(f"    正在处理 (subset): {f.name}")
            process_json_file(f)

def run_step2_post_merge():
    print("  --- 步骤 2A (Python): 正在规范化新合并的 'source' 文件... ---")
    for f in SOURCE_DIR.glob("*.json"):
        if f.is_file() and not re.match(r'^\d{8}T\d{6}Z-', f.name):
            print(f"    正在处理 (source): {f.name}")
            process_json_file(f)

    print("  --- 步骤 2B (Python): 正在对比 cn/non-cn 并更新 'common' ... ---")
    pairs = [
        ("ai-cn", "ai-noncn", "ai-common"),
        ("games-cn", "games-noncn", "games-common"),
        ("network-cn", "network-noncn", "network-common")
    ]

    for cn_name, noncn_name, common_name in pairs:
        cn_path = SOURCE_DIR / f"{cn_name}.json"
        noncn_path = SOURCE_DIR / f"{noncn_name}.json"
        common_path = COMMON_DIR / f"{common_name}.json"

        if cn_path.exists() and noncn_path.exists():
            print(f"    正在对比: {cn_name}.json 和 {noncn_name}.json")
            find_and_remove_dupes(cn_path, noncn_path, common_path)
        else:
            print(f"    [跳过] 缺少文件对: {cn_name}.json / {noncn_name}.json")

    print("  --- 步骤 2C (Python): 正在规范化 'common' 目录... ---")
    COMMON_DIR.mkdir(exist_ok=True)
    for f in COMMON_DIR.glob("*.json"):
        if f.is_file():
            print(f"    正在处理 (common): {f.name}")
            process_json_file(f)

def main():
    parser = argparse.ArgumentParser(description="sing-box 规则 JSON 处理脚本")
    parser.add_argument(
        '--step',
        type=str,
        choices=['step1', 'step2'],
        required=True,
        help="要执行的处理步骤 ('step1' 预合并, 'step2' 合并后)"
    )
    args = parser.parse_args()

    if args.step == 'step1':
        print("--- 正在执行 [Python 步骤 1: 预合并] 规范化 ---")
        run_step1_pre_merge()
        print("--- [Python 步骤 1: 预合并] 完成 ---")
    elif args.step == 'step2':
        print("--- 正在执行 [Python 步骤 2: 合并后] 处理 ---")
        run_step2_post_merge()
        print("--- [Python 步骤 2: 合并后] 完成 ---")

if __name__ == "__main__":
    main()
EOF

chmod +x "$PYTHON_SCRIPT_PATH"
echo "Python 脚本已创建于: $PYTHON_SCRIPT_PATH"

# --- JSON 验证和修复 (内存安全 & FD 修复版) ---
validate_and_fix_json() {
  local file="$1"
  local group_name="${2:-unknown}"
  local temp_file
  temp_file=$(mktemp "${TEMP_DIR}/validate.tmp.XXXXXX.json")
  local jq_err_file
  jq_err_file=$(mktemp "${TEMP_DIR}/validate.err.XXXXXX.log")
  local lock_file="${file}.lock"

  # mktemp 失败检查
  if [ -z "$temp_file" ] || [ -z "$jq_err_file" ]; then
    echo "Error: mktemp failed for temp_file or jq_err_file" >&2
    return 1
  fi

  # 清理函数
  cleanup_validate() {
    rm -f "$temp_file" "$jq_err_file" "$lock_file"
  }
  trap cleanup_validate RETURN

  # 使用子shell隔离文件描述符操作，避免FD泄漏
  (
    if [ "$HAS_FLOCK" = true ]; then
      exec 200>"$lock_file"
      if ! flock -n 200; then
        echo "    [错误] 文件 $file 正在被其他进程处理" >&2
        exit 1
      fi
    fi

    # 基本检查
    if [ ! -f "$file" ] || [ ! -s "$file" ]; then
      echo "    [错误] 文件未找到或为空: $file" >&2
      exit 1
    fi

    # 检查HTML错误页面 (只检查内容，忽略 head 的错误输出)
    if head -n 1 "$file" 2>/dev/null | grep -qi "<!DOCTYPE\|<html"; then
      echo "    [错误] $file 是HTML页面,删除" >&2
      rm -f "$file"
      exit 1
    fi

    # 验证JSON - 使用临时文件存储 stderr 以避免大变量内存问题
    if jq empty "$file" >/dev/null 2> "$jq_err_file"; then
      # 检查并添加version字段
      if ! jq -e '.version' "$file" >/dev/null 2>&1; then
        echo "    [修复] 为 $file 添加 'version' 字段"
        # 直接重定向到文件，避免 var=$(...)
        if jq '.version = 1' "$file" > "$temp_file" 2> "$jq_err_file"; then
          if [ -s "$temp_file" ]; then
            mv -f "$temp_file" "$file"
          else
            echo "    [错误] 无法添加 version 字段: 输出为空" >&2
            cat "$jq_err_file" >&2
            exit 1
          fi
        else
          echo "    [错误] 无法添加 version 字段" >&2
          cat "$jq_err_file" >&2
          exit 1
        fi
      fi
      exit 0
    else
      # jq验证失败，显示错误
      echo "    [错误] $file JSON无效" >&2
      cat "$jq_err_file" >&2
    fi

    # 尝试修复
    echo "    [错误] 尝试修复 $file ..." >&2

    # 方法1: 使用jq格式化 (流式处理)
    if jq '.' "$file" > "$temp_file" 2> "$jq_err_file"; then
      if [ -s "$temp_file" ]; then
        mv -f "$temp_file" "$file"
        echo "    [修复] 使用 'jq .' 成功修复"
        exit 0
      fi
    fi

    # 方法2: 包装裸数组 (流式处理)
    if jq 'if type == "array" then {version: 1, rules: .} else . end' "$file" > "$temp_file" 2> "$jq_err_file"; then
      if [ -s "$temp_file" ]; then
        mv -f "$temp_file" "$file"
        echo "    [修复] 成功包装裸数组"
        exit 0
      fi
    fi

    echo "    [错误] 无法修复JSON: $file" >&2
    cat "$jq_err_file" >&2
    rm -f "$file"
    exit 1

  )

  # 捕获子shell的退出码
  local ret=$?
  return $ret
}

# --- 预处理 subset 文件 (内存安全 & 并发安全版) ---
preprocess_ruleset() {
  local base_url="$1"
  local exclude_url="$2"
  local output_file="$3"

  echo "Preprocessing subset: $output_file"

  # CRITICAL FIX: 使用 mktemp 创建真正唯一的临时文件
  local base_temp
  base_temp=$(mktemp "${TEMP_DIR}/base_XXXXXX.json")
  local exclude_temp
  exclude_temp=$(mktemp "${TEMP_DIR}/exclude_XXXXXX.json")
  local jq_err_file
  jq_err_file=$(mktemp "${TEMP_DIR}/jq_err_XXXXXX.log")

  # mktemp 失败检查
  if [ -z "$base_temp" ] || [ -z "$exclude_temp" ] || [ -z "$jq_err_file" ]; then
    echo "Error: mktemp failed for base/exclude/jq_err" >&2
    return 1
  fi

  # 清理函数
  cleanup_preprocess() {
    rm -f "$base_temp" "$exclude_temp" "$jq_err_file"
  }
  # 仅使用 RETURN，避免与全局 EXIT trap 冲突
  trap cleanup_preprocess RETURN

  # 判断 base_url
  if [[ "$base_url" == /* ]] || [[ "$base_url" == ./* ]] || \
     [[ "$base_url" == *"${SUBSET_DIR}"* ]] || [[ "$base_url" == *"${SOURCE_DIR}"* ]]; then
    echo "  Using local base file: $base_url"
    if [ -f "$base_url" ] && [ -s "$base_url" ]; then
      cp "$base_url" "$base_temp"
    else
      echo "Error: [致命错误] 本地文件不存在或为空: $base_url" >&2
      return 1
    fi
  else
    echo "  Downloading base: $base_url"
    if ! download_file "$base_url" "$base_temp" 120; then
      echo "Error: [致命错误] 无法下载 $base_url" >&2
      return 1
    fi
  fi

  # 验证base文件 (避免变量捕获)
  if ! jq empty "$base_temp" >/dev/null 2> "$jq_err_file"; then
     echo "Error: [致命错误] $base_url 返回无效JSON" >&2
     cat "$jq_err_file" >&2
     return 1
  fi

  # 判断 exclude_url
  if [[ "$exclude_url" == /* ]] || [[ "$exclude_url" == ./* ]] || \
     [[ "$exclude_url" == *"${SUBSET_DIR}"* ]] || [[ "$exclude_url" == *"${SOURCE_DIR}"* ]]; then
    echo "  Using local exclude file: $exclude_url"
    if [ -f "$exclude_url" ] && [ -s "$exclude_url" ]; then
      cp "$exclude_url" "$exclude_temp"
    else
      echo "    [错误] 本地exclude文件不存在: $exclude_url, 使用空规则" >&2
      echo '{"version": 1, "rules": []}' > "$exclude_temp"
    fi
  else
    echo "  Downloading exclude: $exclude_url"
    if ! download_file "$exclude_url" "$exclude_temp" 120; then
      echo "    [错误] 无法下载exclude: $exclude_url, 使用空规则" >&2
      echo '{"version": 1, "rules": []}' > "$exclude_temp"
    fi
  fi

  # 验证exclude文件
  if ! jq empty "$exclude_temp" >/dev/null 2> "$jq_err_file"; then
    echo "    [错误] $exclude_url 返回无效JSON, 使用空规则" >&2
    cat "$jq_err_file" >&2
    echo '{"version": 1, "rules": []}' > "$exclude_temp"
  fi

  # 处理规则 (直接重定向到文件，不经过变量)
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
  ' "$base_temp" > "$output_file" 2> "$jq_err_file"; then
    echo "Error: [致命错误] jq处理失败" >&2
    cat "$jq_err_file" >&2
    return 1
  fi

  # 验证输出文件
  if ! jq empty "$output_file" >/dev/null 2> "$jq_err_file"; then
    echo "Error: [致命错误] $output_file 生成的JSON无效" >&2
    cat "$jq_err_file" >&2
    return 1
  fi

  echo "  Successfully generated subset: $output_file"
}

# --- 预处理配置 ---
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

echo "--- 步骤 1: 正在运行 'subset' 文件预处理 (下载) ---"
pids=()
for ((i=0; i<${#preprocess_configs[@]}; i+=3)); do
  preprocess_ruleset "${preprocess_configs[i]}" "${preprocess_configs[i+1]}" "${preprocess_configs[i+2]}" &
  pids+=($!)
done
echo "  Waiting for ${#pids[@]} subset generation jobs..."

# 等待所有预处理任务并检查错误
failed=0
for pid in "${pids[@]}"; do
  if ! wait "$pid"; then
    failed=1
  fi
done

if [ $failed -eq 1 ]; then
  echo "Error: [致命错误] 某些预处理任务失败" >&2
  exit 1
fi
echo "--- 步骤 1: 'subset' 文件预处理完成 ---"

echo "--- 步骤 2: 正在运行 [Python 步骤 1] (预合并规范化) ---"
if ! "$PYTHON_SCRIPT_PATH" --step step1; then
  echo "Error: [致命错误] Python 步骤 1 失败" >&2
  exit 1
fi
echo "--- 步骤 2: [Python 步骤 1] 完成 ---"

# --- 合并函数 (使用文件日志，内存安全) ---
merge_group() {
  local GROUP_NAME=$1
  shift
  local URLS=("$@")
  local LOCAL_JSON_FILE="${SOURCE_DIR}/${GROUP_NAME}.json"
  local MAIN_PID=$$

  # 使用 mktemp 创建唯一的日志文件
  local merge_log
  merge_log=$(mktemp "${TEMP_DIR}/merge-${GROUP_NAME}-XXXXXX.log")

  # 清理函数
  cleanup_merge() {
    rm -f "${TEMP_DIR}/input-${GROUP_NAME}-"*.json
    rm -f "${TEMP_DIR}/merged-${GROUP_NAME}.json"
    rm -f "$merge_log"
  }
  trap cleanup_merge EXIT INT TERM

  echo "Starting merge for group: $GROUP_NAME"

  local i=1
  local pids=()
  local local_files=()
  local remote_urls=()

  # 分类URL
  for url in "${URLS[@]}"; do
    [ -z "$url" ] && continue
    if [[ "$url" == ${SOURCE_DIR}/* ]] || [[ "$url" == ${SUBSET_DIR}/* ]] || \
       [[ "$url" == ./* ]] || [[ "$url" == /* ]]; then
      local_files+=("$url")
    else
      remote_urls+=("$url")
    fi
  done

  # 处理本地文件
  for file_path in "${local_files[@]}"; do
    local output_file="${TEMP_DIR}/input-$GROUP_NAME-$i.json"
    if [ -f "$file_path" ] && [ -s "$file_path" ]; then
      cp "$file_path" "$output_file"
      echo "  Copied local file: $file_path"
      if validate_and_fix_json "$output_file" "$GROUP_NAME"; then
        ((i++))
      else
        echo "  [错误] 本地文件 $file_path 验证失败, 跳过。" >&2
        rm -f "$output_file"
      fi
    else
      echo "  [错误] 本地文件 $file_path 未找到或为空, 跳过。" >&2
    fi
  done

  # 处理远程URL - 修复并行索引问题
  local idx=0
  for url in "${remote_urls[@]}"; do
    local url_copy="$url"
    local file_index=$((i + idx))
    (
      local output_file="${TEMP_DIR}/input-$GROUP_NAME-$file_index.json"

      echo "  Downloading: $url_copy"
      if download_file "$url_copy" "$output_file" 120; then
        echo "    Downloaded: $url_copy"
        if validate_and_fix_json "$output_file" "$GROUP_NAME"; then
          echo "    Validated: $url_copy"
        else
          echo "    [错误] $url_copy 验证失败, 已删除。" >&2
          rm -f "$output_file"
          exit 1
        fi
      else
        echo "Error: [致命错误] 无法下载 $url_copy (group $GROUP_NAME)" >&2
        rm -f "$output_file"
        kill -s TERM $MAIN_PID
        exit 1
      fi
    ) &
    pids+=($!)
    ((idx++))
  done

  # 更新索引
  i=$((i + idx))

  # 等待所有下载完成并检查错误
  if [ ${#pids[@]} -gt 0 ]; then
    echo "  Waiting for ${#pids[@]} downloads for group $GROUP_NAME..."
    local failed=0
    for pid in "${pids[@]}"; do
      if ! wait "$pid"; then failed=1; fi
    done
    if [ $failed -eq 1 ]; then
      echo "Error: [致命错误] 组 $GROUP_NAME 有下载失败" >&2
      exit 1
    fi
    echo "  Downloads for $GROUP_NAME finished."
  fi

  # 检查可用输入
  shopt -s nullglob
  local inputs=("${TEMP_DIR}/input-${GROUP_NAME}-"*.json)
  shopt -u nullglob

  if [ "${#inputs[@]}" -eq 0 ]; then
    echo "Error: [致命错误] 组 $GROUP_NAME 没有可用的输入文件，停止合并。" >&2
    exit 1
  fi

  # 合并文件
  echo "  Merging ${#inputs[@]} files for group $GROUP_NAME..."
  local merged_tmp="${TEMP_DIR}/merged-${GROUP_NAME}.json"
  local config_flags=()
  for input_file in "${inputs[@]}"; do
    config_flags+=("-c" "$input_file")
  done

  # sing-box 合并，日志输出到文件
  if ! sing-box rule-set merge "$merged_tmp" "${config_flags[@]}" > "$merge_log" 2>&1; then
    echo "Error: [致命错误] sing-box 合并 $GROUP_NAME 失败" >&2
    cat "$merge_log" >&2
    exit 1
  fi

  # 备份与保存
  if [ -f "$LOCAL_JSON_FILE" ]; then
    local TIMESTAMP
    TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
    local backup_file="${SOURCE_DIR}/${TIMESTAMP}-${GROUP_NAME}.json"
    mv -f "$LOCAL_JSON_FILE" "$backup_file"
    echo "  Backed up old source to: $backup_file"
  fi

  mv -f "$merged_tmp" "$LOCAL_JSON_FILE"
  echo "  Saved merged JSON to: $LOCAL_JSON_FILE"
  echo "Completed merge for $GROUP_NAME"
}

# --- 编译函数 (使用文件日志，修复日志显示) ---
compile_srs_file() {
  local GROUP_NAME=$1
  local LOCAL_JSON_FILE="${SOURCE_DIR}/${GROUP_NAME}.json"
  local OUTPUT_SRS_FILE="${SRS_DIR}/${GROUP_NAME}.srs"

  # 使用 mktemp
  local compile_log
  compile_log=$(mktemp "${TEMP_DIR}/compile-${GROUP_NAME}-XXXXXX.log")

  if [ ! -f "$LOCAL_JSON_FILE" ]; then
    echo "  [错误] 编译跳过: 未找到 $LOCAL_JSON_FILE" >&2
    return
  fi

  # 查找备份文件 - 显示find错误
  local json_backup
  local find_output
  if ! find_output=$(find "$SOURCE_DIR" -name "*-${GROUP_NAME}.json" -type f 2>&1); then
    echo "    [错误] 查找备份时出错: $find_output" >&2
    json_backup=""
  else
    json_backup=$(echo "$find_output" | sort -r | head -n 1)
  fi

  echo "  Compiling SRS file for $GROUP_NAME..."

  # 编译并重定向输出到文件
  if sing-box rule-set compile "$LOCAL_JSON_FILE" -o "$OUTPUT_SRS_FILE" > "$compile_log" 2>&1; then
    echo "    Successfully compiled: $OUTPUT_SRS_FILE"
    rm -f "$compile_log"
  else
    echo "    Error: [致命错误] 编译 $GROUP_NAME 失败" >&2
    cat "$compile_log" >&2

    if [ -n "$json_backup" ] && [ -f "$json_backup" ]; then
      cp -a "$json_backup" "$LOCAL_JSON_FILE"
      echo "    Restored JSON from most recent backup: $json_backup"

      if sing-box rule-set compile "$LOCAL_JSON_FILE" -o "$OUTPUT_SRS_FILE" > "$compile_log" 2>&1; then
        echo "    Successfully compiled restored backup."
        rm -f "$compile_log"
      else
        echo "    Error: [致命错误] 连备份 $json_backup 都编译失败！" >&2
        cat "$compile_log" >&2
        exit 1
      fi
    else
      echo "    Error: [致命错误] 编译失败且未找到备份文件可恢复。" >&2
      exit 1
    fi
  fi
}

compile_all_srs() {
  echo "--- 步骤 5: 正在编译所有 SRS 文件 ---"
  local groups=("ads" "games-cn" "games-noncn" "ai-cn" "ai-noncn" "media" "network-cn" "network-noncn" "cdn" "hkmotw" "private")

  local pids=()
  for group in "${groups[@]}"; do
    compile_srs_file "$group" &
    pids+=($!)
  done

  echo "  Waiting for ${#pids[@]} compile jobs..."

  local failed=0
  for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
      failed=1
    fi
  done

  if [ $failed -eq 1 ]; then
    echo "Error: [致命错误] 某些编译任务失败" >&2
    exit 1
  fi

  echo "--- 步骤 5: SRS 编译完成 ---"
}

cleanup_old_backups() {
  echo "--- 步骤 6: 正在清理旧备份 (每组保留 3 个) ---"
  local groups=("ads" "games-cn" "games-noncn" "ai-cn" "ai-noncn" "media" "network-cn" "network-noncn" "cdn" "hkmotw" "private")

  for group in "${groups[@]}"; do
    find "$SOURCE_DIR" -name "*-${group}.json" -type f 2>/dev/null | sort -r | tail -n +4 | xargs -r rm -f || true
  done
  echo "--- 步骤 6: 备份清理完成 ---"
}

# --- URL 定义 ---
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

# --- 步骤 3: 主合并 ---
echo "--- 步骤 3: 正在运行主合并... ---"
merge_group "ads" "${ads_urls[@]}"
merge_group "games-cn" "${games_cn_urls[@]}"
merge_group "games-noncn" "${games_noncn_urls[@]}"
merge_group "ai-cn" "${ai_cn_urls[@]}"
merge_group "ai-noncn" "${ai_noncn_urls[@]}"
merge_group "media" "${media_urls[@]}"
merge_group "network-cn" "${network_cn_urls[@]}"
merge_group "network-noncn" "${network_noncn_urls[@]}"
merge_group "cdn" "${cdn_urls[@]}"
merge_group "hkmotw" "${hkmotw_urls[@]}"
merge_group "private" "${private_urls[@]}"
echo "--- 步骤 3: 主合并完成 ---"

# --- 步骤 4: Python 合并后处理 ---
echo "--- 步骤 4: 正在运行 [Python 步骤 2] (合并后处理) ---"
if ! "$PYTHON_SCRIPT_PATH" --step step2; then
  echo "Error: [致命错误] Python 步骤 2 失败" >&2
  exit 1
fi
echo "--- 步骤 4: [Python 步骤 2] 完成 ---"

# --- 步骤 5: 编译 SRS ---
compile_all_srs

# --- 步骤 6: 清理备份 ---
cleanup_old_backups

echo "All groups processed successfully!"
echo "Source JSON files are in: $SOURCE_DIR/"
echo "Subset JSON files are in: $SUBSET_DIR/"
echo "Common JSON files are in: $COMMON_DIR/"
echo "Compiled SRS files are in: $SRS_DIR/"
