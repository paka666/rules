#!/usr/bin/env bash
set -euo pipefail

# --- 脚本配置 ---
# 定义新的目录结构
SOURCE_DIR="srs/json/source"
SUBSET_DIR="srs/json/subset"
COMMON_DIR="srs/json/common"
SRS_DIR="srs"
TEMP_DIR="temp"
PYTHON_SCRIPT_PATH="${TEMP_DIR}/process_rules.py"

# --- 步骤 0: 创建目录和 Python 脚本 ---
echo "--- 步骤 0: 正在设置环境 ---"
mkdir -p "$TEMP_DIR" "$SRS_DIR" "$SOURCE_DIR" "$SUBSET_DIR" "$COMMON_DIR"

# Heretic Doc: 将 Python 脚本写入临时文件
# 这确保了脚本的单一文件分发
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

# -----------------------------------------------------------------------------
# 路径配置 (从 Bash 脚本的定义派生)
# -----------------------------------------------------------------------------
BASE_DIR = Path.cwd()
SOURCE_DIR = BASE_DIR / "srs/json/source"
SUBSET_DIR = BASE_DIR / "srs/json/subset"
COMMON_DIR = BASE_DIR / "srs/json/common"

# -----------------------------------------------------------------------------
# 核心功能：IP CIDR 合并
# -----------------------------------------------------------------------------
def merge_cidrs(cidrs_list: Set[str]) -> List[str]:
    """
    合并重叠和相邻的 IP CIDR。
    使用 ipaddress.collapse_addresses 来高效处理 IPv4 和 IPv6。
    将单个 IP 转换为 /32 (v4) 或 /128 (v6)。
    """
    v4_nets = []
    v6_nets = []

    for cidr_str in cidrs_list:
        if not cidr_str:
            continue
        try:
            # strict=False 允许 "1.1.1.1" 这种单个 IP
            # ip_network 会自动将其转换为 "1.1.1.1/32"
            net = ipaddress.ip_network(cidr_str.strip(), strict=False)
            if net.version == 4:
                v4_nets.append(net)
            else:
                v6_nets.append(net)
        except ValueError as e:
            print(f"    [警告] 忽略无效的 IP/CIDR: '{cidr_str}' ({e})", file=sys.stderr)

    # 分别合并 v4 和 v6
    merged_v4 = list(ipaddress.collapse_addresses(v4_nets))
    merged_v6 = list(ipaddress.collapse_addresses(v6_nets))

    # 排序以确保一致的输出
    merged_v4.sort(key=lambda n: (n.network_address, n.prefixlen))
    merged_v6.sort(key=lambda n: (n.network_address, n.prefixlen))

    # 转换回字符串列表
    return [str(n) for n in merged_v4] + [str(n) for n in merged_v6]

# -----------------------------------------------------------------------------
# 核心功能：Domain/Suffix 规范化
# -----------------------------------------------------------------------------
def normalize_domains_and_suffixes(
    all_domains: Set[str],
    all_domain_suffixes: Set[str]
) -> Tuple[List[str], List[str]]:
    """
    执行 Domain/Suffix 的 www 移除和交叉规范化。
    """

    def strip_www(domain_set: Set[str]) -> Set[str]:
        """移除 www. 和 .www. 前缀"""
        normalized_set = set()
        for d in domain_set:
            d_stripped = d.strip()
            if not d_stripped:
                continue

            # 移除 ".www." 或 "www." 前缀
            # 1. ".www.foo.com" -> "foo.com"
            # 2. "www.foo.com" -> "foo.com"
            # 3. ".foo.com" -> ".foo.com" (re.sub 不匹配)
            # 4. "foo.com" -> "foo.com" (re.sub 不匹配)
            d_normalized = re.sub(r'^(?:\.www\.|www\.)', '', d_stripped)

            if d_normalized:
                normalized_set.add(d_normalized)
        return normalized_set

    # 1. 移除 'www'
    # 第一次去重：在 www 规范化后
    domains_no_www = strip_www(all_domains)
    suffixes_no_www = strip_www(all_domain_suffixes)

    final_domains = set()
    final_domain_suffixes = set()

    # 2. 交叉规范化

    # 将 domain_suffix -> domain
    for s in suffixes_no_www:
        clean_s = s.lstrip('.')
        if clean_s:
            final_domains.add(clean_s)
            final_domain_suffixes.add(f".{clean_s}") # 确保自身格式正确

    # 将 domain -> domain_suffix
    for d in domains_no_www:
        clean_d = d.lstrip('.')
        if clean_d:
            final_domains.add(clean_d) # 确保自身格式正确
            final_domain_suffixes.add(f".{clean_d}")

    # 3. 排序和去重（通过 set 已完成去重）
    return sorted(list(final_domains)), sorted(list(final_domain_suffixes))

# -----------------------------------------------------------------------------
# 核心功能：“操作 A” - JSON 规范化
# -----------------------------------------------------------------------------
def process_json_file(file_path: Path):
    """
    执行“操作 A”：
    1. 合并所有 rules 对象。
    2. 检查并报告未知键。
    3. 规范化 domain 和 domain_suffix (包括 www 移除)。
    4. 合并和规范化 ip_cidr。
    5. 移除空项并重写文件。
    """
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
        print(f"    [警告] 格式无效，跳过 (无 'rules' 列表): {file_path.name}", file=sys.stderr)
        return

    # 允许的 sing-box 规则键
    allowed_keys = {
        'domain',
        'domain_suffix',
        'domain_keyword',
        'domain_regex',
        'ip_cidr'
    }

    # 1. 合并所有 rules 对象
    all_domains = set()
    all_domain_suffixes = set()
    all_domain_keywords = set()
    all_domain_regex = set()
    all_ip_cidrs = set()

    for rule_obj in data.get('rules', []):
        if not isinstance(rule_obj, dict):
            continue

        # 2. 检查未知键
        unknown_keys = set(rule_obj.keys()) - allowed_keys
        if unknown_keys:
            print(f"[致命错误] 在 {file_path.name} 中发现未知的规则键: {unknown_keys}", file=sys.stderr)
            print("脚本已中止。请检查 JSON 格式或更新脚本中的 'allowed_keys'。", file=sys.stderr)
            sys.exit(1) # 按要求中止脚本

        all_domains.update(rule_obj.get('domain', []))
        all_domain_suffixes.update(rule_obj.get('domain_suffix', []))
        all_domain_keywords.update(rule_obj.get('domain_keyword', []))
        all_domain_regex.update(rule_obj.get('domain_regex', []))
        all_ip_cidrs.update(rule_obj.get('ip_cidr', []))

    # 3. 规范化 domain 和 domain_suffix (包含 'www' 逻辑)
    sorted_domains, sorted_suffixes = normalize_domains_and_suffixes(all_domains, all_domain_suffixes)

    # 其余字段排序
    sorted_keywords = sorted(list(all_domain_keywords))
    sorted_regex = sorted(list(all_domain_regex))

    # 4. 合并和规范化 ip_cidr
    sorted_ips = merge_cidrs(all_ip_cidrs)

    # 5. 重构 JSON 对象
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
    if domain_rule_obj: # 仅当存在至少一个域规则时才添加
        new_rules.append(domain_rule_obj)
    if ip_rule_obj: # 仅当存在 IP 规则时才添加
        new_rules.append(ip_rule_obj)

    # 按照您的“已处理”示例格式化
    new_data = {"version": 1, "rules": new_rules}

    # 6. 写回文件
    try:
        with open(file_path, 'w', encoding='utf-8') as f:
            json.dump(new_data, f, indent=2, ensure_ascii=False)
    except IOError as e:
        print(f"    [错误] 无法写入文件: {file_path.name} ({e})", file=sys.stderr)

# -----------------------------------------------------------------------------
# 核心功能：加载规则数据
# -----------------------------------------------------------------------------
def get_rule_data(file_path: Path) -> Dict[str, Dict[str, Any]]:
    """
    从已处理的文件加载域和 IP 规则对象。
    返回 {"domain": {...}, "ip": {...}, "all_keys": {...}}
    """
    domain_obj = {}
    ip_obj = {}
    all_keys_obj = {} # 用于合并所有键

    if not file_path.exists():
        return {"domain": {}, "ip": {}, "all_keys": {}}

    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            data = json.load(f)

        for rule in data.get('rules', []):
            if not isinstance(rule, dict):
                continue

            # 将所有键的值合并到 all_keys_obj
            for key, values in rule.items():
                if isinstance(values, list):
                    all_keys_obj.setdefault(key, set()).update(values)

            # 分离 IP 和 Domain
            if 'ip_cidr' in rule:
                ip_obj = rule
            else:
                # 假设所有非 IP 规则都是域规则
                domain_obj.update(rule)

    except Exception as e:
        print(f"    [警告] 加载规则数据时出错: {file_path.name} ({e})", file=sys.stderr)
        return {"domain": {}, "ip": {}, "all_keys": {}}

    # 将 all_keys_obj 中的 set 转换为 list
    all_keys_list_obj = {k: list(v) for k, v in all_keys_obj.items()}

    return {"domain": domain_obj, "ip": ip_obj, "all_keys": all_keys_list_obj}

# -----------------------------------------------------------------------------
# 核心功能：查找和移除 cn/!cn 之间的重复项 (增量更新)
# -----------------------------------------------------------------------------
def find_and_remove_dupes(file_cn_path: Path, file_noncn_path: Path, common_path: Path):
    """
    对比 cn 和 non-cn 文件：
    1. 加载 cn, noncn 和 *旧的* common 数据。
    2. 找到 cn 和 noncn 之间的 *新* 共同项。
    3. 将 *新* 共同项与 *旧* 共同项合并，写入 common_path (非规范化)。
    4. 从 cn 和 non-cn 文件中移除 *所有* 共同项 (包括旧的) 并保存。
    """

    data_cn = get_rule_data(file_cn_path)
    data_noncn = get_rule_data(file_noncn_path)
    data_common_old = get_rule_data(common_path) # 加载已有的共同文件

    new_common_all_keys = {}
    all_rule_keys = ['domain', 'domain_suffix', 'domain_keyword', 'domain_regex', 'ip_cidr']

    # --- 对比所有键 ---
    for key in all_rule_keys:
        set_cn = set(data_cn["all_keys"].get(key, []))
        set_noncn = set(data_noncn["all_keys"].get(key, []))
        set_common_old = set(data_common_old["all_keys"].get(key, []))

        # 1. 找到 *新* 的共同项
        common_items_new = set_cn.intersection(set_noncn)

        # 2. 合并 *新*、*旧* 共同项
        common_items_all = common_items_new.union(set_common_old)

        if common_items_all:
            # 3. 准备写入 common 文件 (增量)
            new_common_all_keys[key] = list(common_items_all) # 使用 list, 稍后规范化

            # 4. 更新 cn/noncn 对象 (移除 *所有* 共同项)
            remaining_cn = set_cn - common_items_all
            remaining_noncn = set_noncn - common_items_all

            # 更新 data_cn["all_keys"] 以便写回
            if remaining_cn:
                data_cn["all_keys"][key] = list(remaining_cn)
            else:
                data_cn["all_keys"].pop(key, None)

            # 更新 data_noncn["all_keys"] 以便写回
            if remaining_noncn:
                data_noncn["all_keys"][key] = list(remaining_noncn)
            else:
                data_noncn["all_keys"].pop(key, None)

    # --- 写回文件 ---

    def write_rules_from_all_keys(file_path: Path, all_keys_data: Dict[str, Any]):
        """根据 all_keys dict 重构并写入 JSON 文件"""
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
                    print(f"    [警告] 在 write_rules_from_all_keys 中排序 IP 时出错: {e}", file=sys.stderr)
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

    # 1. 保存 *增量更新* 后的 common 文件 (稍后由步骤 2C 统一规范化)
    if new_common_all_keys:
        write_rules_from_all_keys(common_path, new_common_all_keys)

    # 2. 保存更新后的 cn 文件 (已移除共同项)
    write_rules_from_all_keys(file_cn_path, data_cn["all_keys"])

    # 3. 保存更新后的 non-cn 文件 (已移除共同项)
    write_rules_from_all_keys(file_noncn_path, data_noncn["all_keys"])


# -----------------------------------------------------------------------------
# 流程控制
# -----------------------------------------------------------------------------
def run_step1_pre_merge():
    """
    步骤 1: 预合并处理。
    规范化 source 和 subset 目录中的所有 .json 文件。
    """
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
    """
    步骤 2: 合并后处理。
    A. 再次规范化 'source' 目录 (处理新合并的未规范化文件)。
    B. 执行 'cn/noncn' 对比，增量更新 'common'，并从 'source' 中移除共同项。
    C. 规范化 'common' 目录 (处理增量更新后的文件)。
    """

    # 步骤 2A: 规范化 'source' 目录
    print("  --- 步骤 2A (Python): 正在规范化新合并的 'source' 文件... ---")
    for f in SOURCE_DIR.glob("*.json"):
        # 排除带时间戳的备份 (YYYYMMDDTHHMMSSZ-...)
        if f.is_file() and not re.match(r'^\d{8}T\d{6}Z-', f.name):
            print(f"    正在处理 (source): {f.name}")
            process_json_file(f)

    # 步骤 2B: 对比 cn/non-cn 对，增量更新 common
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

    # 步骤 2C: 规范化 'common' 目录
    print("  --- 步骤 2C (Python): 正在规范化 'common' 目录... ---")
    COMMON_DIR.mkdir(exist_ok=True)
    for f in COMMON_DIR.glob("*.json"):
        if f.is_file():
            print(f"    正在处理 (common): {f.name}")
            process_json_file(f)

# -----------------------------------------------------------------------------
# 主执行函数
# -----------------------------------------------------------------------------
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
# --- 步骤 0: 结束 ---

chmod +x "$PYTHON_SCRIPT_PATH"
echo "Python 脚本已创建于: $PYTHON_SCRIPT_PATH"

# --- 步骤 1: 预处理 (下载 subset 文件) ---
# 1. 使用 mktemp 修复了并行下载时的文件名冲突
# 2. 增加了 --fail 和 JSON 校验来处理 wget 下载 404 页面导致的 "Bad JSON" 错误
# 3. 将 exclude (排除) URL 的下载设为可选，如果下载失败（如 404），则使用空规则代替
preprocess_ruleset() {
  local base_url="$1"
  local exclude_url="$2"
  local output_file="$3"
  local output_type="$4"

  echo "Preprocessing subset: $output_file"

  # --- 修复 1: 使用 mktemp 创建唯一临时文件 ---
  # 这修复了并行执行时所有进程写入同一个 $$ 文件的竞态条件
  local base_temp
  base_temp=$(mktemp "${TEMP_DIR}/base_XXXXXX.json")
  local exclude_temp
  exclude_temp=$(mktemp "${TEMP_DIR}/exclude_XXXXXX.json")

  # 确保此函数返回时，无论成功还是失败，都删除临时文件
  trap 'rm -f "$base_temp" "$exclude_temp"' RETURN

  # --- 优化 1: 强制 Base URL 下载和校验 ---
  echo "  Downloading base: $base_url"
  # 使用 --fail 确保 wget 在遇到 404 等服务器错误时返回非零退出码
  if ! wget -q --timeout=180 --tries=1 --fail "$base_url" -O "$base_temp"; then
    echo "Error: [致命] 无法下载 $base_url (wget failed)"
    return 1 # 返回错误，让 'wait' 捕捉
  fi
  # 校验下载的 base 文件是否为有效 JSON
  if ! jq empty "$base_temp" >/dev/null 2>&1; then
     echo "Error: [致命] $base_url 下载了无效的 JSON (可能是 404 页面)"
     return 1
  fi

  # --- 优化 2: 使 Exclude URL 下载变为可选且健壮 ---
  echo "  Downloading exclude: $exclude_url"
  if ! wget -q --timeout=180 --tries=1 --fail "$exclude_url" -O "$exclude_temp" 2>/dev/null; then
    # 如果下载失败（404, DNS 错误等），不要退出，而是使用空规则
    echo "    [警告] 无法下载 exclude: $exclude_url. 将使用空规则列表。"
    echo '{"version": 1, "rules": []}' > "$exclude_temp"
  elif ! jq empty "$exclude_temp" >/dev/null 2>&1; then
    # 如果下载成功，但内容不是 JSON (例如 404 页面)，也使用空规则
    echo "    [警告] $exclude_url 下载了无效的 JSON. 将使用空规则列表。"
    echo '{"version": 1, "rules": []}' > "$exclude_temp"
  fi

  # --- JQ 逻辑：从 base_rules 中移除 exclude_rules 中存在的规则 ---
  # 此逻辑不变，现在它能安全地处理空的 exclude_temp
  jq --slurpfile exclude "$exclude_temp" '
    .rules as $base_rules |
    $exclude[0].rules as $exclude_rules |
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
  ' "$base_temp" > "$output_file"

  # 临时文件将由 'trap' 自动清理

  # 最终校验生成的 $output_file
  if jq empty "$output_file" >/dev/null 2>&1; then
    echo "  Successfully generated subset: $output_file"
  else
    echo "Error: [致命] 为 $output_file 生成了无效的 JSON"
    return 1 # 返回错误
  fi
}

# 预处理配置数组 (输出到 SUBSET_DIR)
preprocess_configs=(
# game
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-games-cn.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-games-cn@!cn.json"
  "srs/json/subset/geosite-category-games-cn@cn2.json"
  "cn"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-games-!cn.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-games-!cn@cn.json"
  "srs/json/subset/geosite-category-games-!cn@!cn.json"
  "!cn"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-game-platforms-download.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-game-platforms-download@cn.json"
  "srs/json/subset/game-platforms-download@!cn.json"
  "!cn"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-epicgames.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-epicgames@cn.json"
  "srs/json/subset/geosite-epicgames@!cn.json"
  "!cn"
# ai
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-ai-cn.json"
  "https://raw.githubusercontent.com/paka666/rules/main/srs/json/subset/tmp/geosite-category-ai-cn@!cn.json"
  "srs/json/subset/geosite-category-ai-cn@cn.json"
  "cn"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-doubao.json"
  "https://raw.githubusercontent.com/paka666/rules/main/srs/json/subset/tmp/geosite-doubao@!cn.json"
  "srs/json/subset/doubao@cn.json"
  "cn"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-jetbrains.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-jetbrains@cn.json"
  "srs/json/subset/jetbrains@!cn.json"
  "!cn"
# network
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-social-media-cn.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-social-media-cn@!cn.json"
  "srs/json/subset/geosite-category-social-media-cn@cn.json"
  "cn"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-bank-cn.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-bank-cn@!cn.json"
  "srs/json/subset/geosite-category-bank-cn@cn.json"
  "cn"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-dev-cn.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-dev-cn@!cn.json"
  "srs/json/subset/geosite-category-dev-cn@cn2.json"
  "cn"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-entertainment-cn.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-entertainment-cn@!cn.json"
  "srs/json/subset/geosite-category-entertainment-cn@cn2.json"
  "cn"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-social-media-!cn.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-social-media-!cn@cn.json"
  "srs/json/subset/geosite-category-social-media-!cn@!cn.json"
  "!cn"
)

echo "--- 步骤 1: 正在运行 'subset' 文件预处理 (下载) ---"
# 并行执行 preprocess_ruleset
pids=()
for ((i=0; i<${#preprocess_configs[@]}; i+=4)); do
  preprocess_ruleset "${preprocess_configs[i]}" "${preprocess_configs[i+1]}" "${preprocess_configs[i+2]}" "${preprocess_configs[i+3]}" &
  pids+=($!)
done
# 等待所有后台下载任务完成
echo "  Waiting for ${#pids[@]} subset generation jobs..."
wait "${pids[@]}"
echo "--- 步骤 1: 'subset' 文件预处理完成 ---"

# --- 步骤 2: 运行 Python 预合并规范化 ---
echo "--- 步骤 2: 正在运行 [Python 步骤 1] (预合并规范化) ---"
"$PYTHON_SCRIPT_PATH" --step step1
echo "--- 步骤 2: [Python 步骤 1] 完成 ---"

# --- JSON 验证和修复 (用于下载的文件) ---
validate_and_fix_json() {
  local file="$1"
  local group_name="$2"

  if [ ! -f "$file" ] || [ ! -s "$file" ]; then
    echo "    [警告] 文件未找到或为空: $file"
    return 1
  fi

  if jq empty "$file" >/dev/null 2>&1; then
    # JSON 有效，检查 'version'
    if ! jq 'has("version")' "$file" 2>/dev/null | grep -q true; then
      echo "    [修复] 正在为 $file 添加 'version' 字段"
      jq '.version = 1' "$file" > "${file}.tmp.$$" && mv "${file}.tmp.$$" "$file"
    fi
    return 0
  else
    echo "    [警告] $file 中 JSON 无效, 尝试修复..."
    local temp_file="${file}.fixed.$$"

    # 尝试 1: 简单格式化
    if jq '.' "$file" > "$temp_file" 2>/dev/null; then
      mv "$temp_file" "$file"
      echo "    [修复] 使用 'jq .' 成功修复"
      return 0
    fi

    # 尝试 2: 包装数组
    if jq 'if type == "array" then {version: 1, rules: .} else . end' "$file" > "$temp_file" 2>/dev/null; then
      mv "$temp_file" "$file"
      echo "    [修复] 成功包装了裸数组"
      # 再次调用以确保 version 存在 (如果它不是数组)
      validate_and_fix_json "$file" "$group_name"
      return 0
    fi

    echo "    [错误] 无法修复 JSON: $file"
    rm -f "$file" "$temp_file"
    return 1
  fi
}

# --- 合并函数 (仅合并，不编译) ---
merge_group() {
  local GROUP_NAME=$1
  shift
  local URLS=("$@")
  # 目标文件现在是 SOURCE_DIR
  local LOCAL_JSON_FILE="${SOURCE_DIR}/${GROUP_NAME}.json"

  rm -f "${TEMP_DIR}/input-${GROUP_NAME}-"*.json

  echo "Starting merge for group: $GROUP_NAME"

  local i=1
  local pids=()
  local local_files=()
  local remote_urls=()

  # 区分本地源和 URL 源
  for url in "${URLS[@]}"; do
    if [ -z "$url" ]; then
      continue
    fi
    # 检查是否为本地路径 (srs/, ./, /)
    if [[ "$url" == ${SOURCE_DIR}/* ]] || [[ "$url" == ${SUBSET_DIR}/* ]] || [[ "$url" == ./* ]] || [[ "$url" == /* ]]; then
      local_files+=("$url")
    else
      remote_urls+=("$url")
    fi
  done

  # --- 1. 处理本地文件 (复制) ---
  for file_path in "${local_files[@]}"; do
    local output_file="${TEMP_DIR}/input-$GROUP_NAME-$i.json"
    if [ -f "$file_path" ] && [ -s "$file_path" ]; then
      cp "$file_path" "$output_file"
      echo "  Copied local file: $file_path"
      ((i++))
    else
      echo "  [警告] 本地文件 $file_path 未找到或为空, 跳过。"
    fi
  done

  # --- 2. 处理远程 URL (并行下载) ---
  for url in "${remote_urls[@]}"; do
    local current_i=$i
    (
      local file_index=$current_i
      local output_file="${TEMP_DIR}/input-$GROUP_NAME-$file_index.json"

      echo "  Downloading: $url"
      # 优化：添加 --fail 以处理 404
      if wget -q --timeout=180 --tries=1 --fail "$url" -O "$output_file"; then
        echo "    Downloaded: $url"
        # 立即验证下载的文件
        if ! validate_and_fix_json "$output_file" "$GROUP_NAME"; then
          echo "    [错误] 下载的 $url 无效, 已删除。"
          rm -f "$output_file"
        fi
      else
        echo "Error: [致命] 无法下载 $url (group $GROUP_NAME)"
        # 杀死父脚本
        kill -s TERM $$
      fi
    ) &
    pids+=($!)
    ((i++))
  done

  # 等待所有下载完成
  if [ ${#pids[@]} -gt 0 ]; then
    echo "  Waiting for ${#pids[@]} downloads for group $GROUP_NAME..."
    # 'wait' 会在 'set -e' 下自动检查失败的子进程
    wait "${pids[@]}"
    echo "  Downloads for $GROUP_NAME finished."
  fi

  # --- 3. 合并 ---
  shopt -s nullglob
  local inputs=("${TEMP_DIR}/input-${GROUP_NAME}-"*.json)
  shopt -u nullglob

  if [ "${#inputs[@]}" -eq 0 ]; then
    echo "Error: [致命] 组 $GROUP_NAME 没有可用的输入文件 — 停止合并。"
    exit 1
  fi

  echo "  Merging ${#inputs[@]} files for group $GROUP_NAME..."
  local merged_tmp="${TEMP_DIR}/merged-${GROUP_NAME}.json"
  local config_flags=()
  for input_file in "${inputs[@]}"; do
    config_flags+=("-c" "$input_file")
  done

  if ! sing-box rule-set merge "$merged_tmp" "${config_flags[@]}"; then
    echo "Error: [致命] sing-box 合并 $GROUP_NAME 失败"
    exit 1
  fi

  # --- 4. 备份和替换 ---
  # 规范化 (步骤 1) 后的 $LOCAL_JSON_FILE 现在是旧文件
  if [ -f "$LOCAL_JSON_FILE" ]; then
    local TIMESTAMP
    TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
    local backup_file="${SOURCE_DIR}/${TIMESTAMP}-${GROUP_NAME}.json"
    mv -f "$LOCAL_JSON_FILE" "$backup_file"
    echo "  Backed up old source to: $backup_file"
  fi

  # 移动新合并的 (未规范化的) 文件
  mv -f "$merged_tmp" "$LOCAL_JSON_FILE"
  echo "  Saved merged UNPROCESSED JSON to: $LOCAL_JSON_FILE"

  rm -f "${TEMP_DIR}/input-${GROUP_NAME}-"*.json
  echo "Completed merge for $GROUP_NAME"
}

# --- 编译函数 (单独) ---
compile_srs_file() {
  local GROUP_NAME=$1
  local LOCAL_JSON_FILE="${SOURCE_DIR}/${GROUP_NAME}.json"
  local OUTPUT_SRS_FILE="${SRS_DIR}/${GROUP_NAME}.srs"

  if [ ! -f "$LOCAL_JSON_FILE" ]; then
    echo "  [警告] 编译跳过: 未找到 $LOCAL_JSON_FILE"
    return
  fi

  # 查找此组的最新备份
  local json_backup
  json_backup=$(find "$SOURCE_DIR" -name "*-${GROUP_NAME}.json" -type f | sort -r | head -n 1)

  echo "  Compiling SRS file for $GROUP_NAME..."
  if sing-box rule-set compile "$LOCAL_JSON_FILE" -o "$OUTPUT_SRS_FILE"; then
    echo "    Successfully compiled: $OUTPUT_SRS_FILE"
  else
    echo "    Error: [致命] 编译 $GROUP_NAME 失败"
    if [ -n "$json_backup" ] && [ -f "$json_backup" ]; then
      cp -a "$json_backup" "$LOCAL_JSON_FILE"
      echo "    Restored JSON from most recent backup: $json_backup"
      # 尝试用备份重新编译
      if sing-box rule-set compile "$LOCAL_JSON_FILE" -o "$OUTPUT_SRS_FILE"; then
        echo "    Successfully compiled restored backup."
      else
        echo "    Error: [致命] 连备份 $json_backup 都编译失败！"
        exit 1
      fi
    else
      echo "    Error: [致命] 编译失败且未找到备份文件可恢复。"
      exit 1
    fi
  fi
}

compile_all_srs() {
  echo "--- 步骤 5: 正在编译所有 SRS 文件 ---"
  local groups=("ads" "games-cn" "games-noncn" "ai-cn" "ai-noncn" "media" "network-cn" "network-noncn" "cdn" "hkmotw" "private")

  local pids=()
  for group in "${groups[@]}"; do
    # 并行编译
    compile_srs_file "$group" &
    pids+=($!)
  done

  echo "  Waiting for ${#pids[@]} compile jobs..."
  wait "${pids[@]}"
  echo "--- 步骤 5: SRS 编译完成 ---"
}

# --- 清理备份 ---
cleanup_old_backups() {
  echo "--- 步骤 6: 正在清理旧备份 (每组保留 3 个) ---"
  local groups=("ads" "games-cn" "games-noncn" "ai-cn" "ai-noncn" "media" "network-cn" "network-noncn" "cdn" "hkmotw" "private")

  for group in "${groups[@]}"; do
    # 查找、排序、跳过前 3 个，然后删除其余的
    find "$SOURCE_DIR" -name "*-${group}.json" -type f | sort -r | tail -n +4 | xargs -r rm -f 2>/dev/null || true
  done
  echo "--- 步骤 6: 备份清理完成 ---"
}

# --- URL 定义 (路径已更新) ---
# *** 脚本会使用您在下面数组中定义的 ${SOURCE_DIR} 和 ${SUBSET_DIR} 中的本地文件 ***
# *** 以及在此处添加的任何远程 URL ***

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
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-win-spy.json"
)
games_cn_urls=(
  "${SOURCE_DIR}/games-cn.json"
  "${SUBSET_DIR}/geosite-category-games-cn@cn2.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-bilibili-game@cn.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-bluepoch-games@cn.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-gamersky.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-herogame.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-kurogames@cn.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-epicgames@cn.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-tencent-games@cn.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-game-accelerator-cn.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-game-platforms-download@cn.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-games-!cn@cn.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-games@cn.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-games-cn@cn.json"
)
games_noncn_urls=(
  "${SOURCE_DIR}/games-noncn.json"
  "${SUBSET_DIR}/geosite-category-games-!cn@!cn.json"
  "${SUBSET_DIR}/game-platforms-download@!cn.json"
  "${SUBSET_DIR}/geosite-epicgames@!cn.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-games@!cn.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-cygames.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-steam.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-2kgames.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-tencent-games@!cn.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-wbgames.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-games-cn@!cn.json"
)
ai_cn_urls=(
  "${SOURCE_DIR}/ai-cn.json"
  "${SUBSET_DIR}/doubao@cn.json"
  "${SUBSET_DIR}/geosite-category-ai-cn@cn.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-jetbrains@cn.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-deepseek.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-aixcoder.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-apple-intelligence.json"
)
ai_noncn_urls=(
  "${SOURCE_DIR}/ai-noncn.json"
  "${SUBSET_DIR}/jetbrains@!cn.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-ai-!cn.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-ai-chat-!cn.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-category-ai-cn@!cn.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-openai.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-xai.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-google-gemini.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-meta.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-perplexity.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-poe.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-anthropic.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-jetbrains-ai.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-doubao@!cn.json"
)
media_urls=(
  "${SOURCE_DIR}/media.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-netflix.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-netflix.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-disney.json"
)
network_cn_urls=(
  "${SOURCE_DIR}/network-cn.json"
  "${SUBSET_DIR}/geosite-category-social-media-cn@cn.json"
  "${SUBSET_DIR}/geosite-category-bank-cn@cn.json"
  "${SUBSET_DIR}/geosite-category-dev-cn@cn2.json"
  "${SUBSET_DIR}/geosite-category-entertainment-cn@cn2.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-cn.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-china-list.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-cn.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-geolocation-cn.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-geolocation-cn@cn.json"
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
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-bilibili@cn.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-bing@cn.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-bluearchive@cn.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-bluepoch@cn.json"
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
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-cisco@cn.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-clearasil@cn.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-cloudflare-cn.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-cloudflare-cn@cn.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-cloudflare@cn.json"
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
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-facebook.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-telegram.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-twitter.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-github.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-gitlab.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-geolocation-!cn.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-gfw.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-win-extra.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-win-update.json"
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
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-trae@!cn.json"
  "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-vivo@!cn.json"
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

# --- 步骤 3: 运行主合并 ---
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


# --- 步骤 4: 运行 Python 合并后处理 (规范化, cn/!cn 对比) ---
echo "--- 步骤 4: 正在运行 [Python 步骤 2] (合并后处理) ---"
"$PYTHON_SCRIPT_PATH" --step step2
echo "--- 步骤 4: [Python 步骤 2] 完成 ---"


# --- 步骤 5: 编译所有 SRS 文件 ---
# (已移至单独的函数 compile_all_srs)
compile_all_srs


# --- 步骤 6: 清理旧备份 ---
# (已移至单独的函数 cleanup_old_backups)
cleanup_old_backups


# --- 结束 ---
echo "All groups processed successfully!"
echo "Source JSON files are in: $SOURCE_DIR/"
echo "Subset JSON files are in: $SUBSET_DIR/"
echo "Common JSON files are in: $COMMON_DIR/"
echo "Compiled SRS files are in: $SRS_DIR/"

# --- Git 提交 (注释掉了，按需启用) ---
# echo "Committing changes..."
# git config --global user.name "GitHub Actions"
# git config --global user.email "actions@github.com"
# git add "${SRS_DIR}/"*.srs "${SOURCE_DIR}/"*.json "${COMMON_DIR}/"*.json
# git commit -m "Daily rule update: $(date -u +%Y-%m-%dT%H%M%SZ)" || echo "No changes to commit"
# git push origin main
