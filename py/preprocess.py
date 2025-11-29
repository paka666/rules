#!/usr/bin/env python3
import ipaddress
import os
import json
import requests
import gzip

def download(url, path):
    r = requests.get(url, stream=True)
    with open(path, 'wb') as f:
        for chunk in r.iter_content(chunk_size=8192):
            f.write(chunk)

def merge_with_existing(new_content, output_file):
    existing = []
    if os.path.exists(output_file):
        with open(output_file, 'r', encoding='utf-8', errors='ignore') as f:
            for line in f:
                cleaned = line.strip()
                if cleaned and not cleaned.startswith(('#', '!', ';')):
                    existing.append(cleaned)
    all_lines = set(existing + new_content)
    sorted_lines = sorted(all_lines)
    os.makedirs(os.path.dirname(output_file), exist_ok=True)
    with open(output_file, 'w', encoding='utf-8') as f:
        f.write('\n'.join(sorted_lines) + '\n')

def ip_to_int(ip):
    return int(ipaddress.IPv4Address(ip))

def int_to_ip(n):
    return str(ipaddress.IPv4Address(n))

def parse_p2p_line(line):
    line = line.strip()
    if not line or line.startswith("#"):
        return None
    ip_part = line.rsplit(':', 1)[-1].strip() if ':' in line else line
    if '-' in ip_part:
        try:
            start, end = map(str.strip, ip_part.split('-'))
            return ip_to_int(start), ip_to_int(end)
        except:
            return None
    else:
        try:
            ip_int = ip_to_int(ip_part.strip())
            return ip_int, ip_int
        except:
            return None

def merge_ranges(ranges):
    if not ranges:
        return []
    ranges.sort()
    merged = [ranges[0]]
    for start, end in ranges[1:]:
        if start <= merged[-1][1] + 1:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))
    return merged

def ranges_to_cidrs(merged):
    cidrs = []
    for start, end in merged:
        try:
            cidrs.extend(ipaddress.summarize_address_range(ipaddress.IPv4Address(start), ipaddress.IPv4Address(end)))
        except:
            pass
    return [str(c) for c in cidrs]

def read_cidr_file(filepath):
    cidrs = []
    if os.path.exists(filepath):
        with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#'):
                    cidr_str = line.split()[0]
                    try:
                        cidrs.append(ipaddress.ip_network(cidr_str, strict=False))
                    except:
                        pass
    return cidrs

def process_list(p2p_file, cidr_file):
    ranges = []
    if os.path.exists(p2p_file):
        with open(p2p_file, 'r', encoding='utf-8', errors='ignore') as f:
            for line in f:
                range_data = parse_p2p_line(line)
                if range_data:
                    ranges.append(range_data)
    p2p_cidrs = ranges_to_cidrs(merge_ranges(ranges))
    cidr_networks = read_cidr_file(cidr_file)
    all_cidrs = []
    for cidr_str in p2p_cidrs:
        try:
            all_cidrs.append(ipaddress.ip_network(cidr_str, strict=False))
        except:
            pass
    all_cidrs.extend(cidr_networks)
    if all_cidrs:
        merged_cidrs = list(ipaddress.collapse_addresses(all_cidrs))
    else:
        merged_cidrs = []
    merged_cidrs_sorted = sorted(merged_cidrs, key=lambda x: (int(x.network_address), x.prefixlen))
    return [str(network) for network in merged_cidrs_sorted]

def process_asndrop(input_file):
    with open(input_file, 'r') as f:
        lines = f.readlines()
    domains = set()
    for line in lines:
        if line.strip() and not line.startswith('{"type":"metadata"'):
            try:
                data = json.loads(line)
                domain = data.get('domain', '').strip().lower()
                if domain:
                    domains.add(domain if domain.endswith('.') else f'{domain}.')
            except json.JSONDecodeError:
                continue
    return sorted(domains)

def merge_hosts(temp_file, output_file):
    new_lines = []
    if os.path.exists(temp_file):
        with open(temp_file, 'r', encoding='utf-8', errors='ignore') as f:
            for line in f:
                cleaned = line.strip()
                if cleaned and not cleaned.startswith(('#', '!', ';')):
                    new_lines.append(cleaned)
    merge_with_existing(new_lines, output_file)

def unzip_gz(gz_path, txt_path):
    with gzip.open(gz_path, 'rb') as f_in:
        with open(txt_path, 'wb') as f_out:
            f_out.write(f_in.read())

def main():
    os.makedirs('temp', exist_ok=True)
    os.makedirs('adh/tmp', exist_ok=True)

#   download("https://sysctl.org/cameleon/hosts", "temp/sysctl-hosts.txt")
    download("https://www.spamhaus.org/drop/asndrop.json", "temp/asndrop.json")
    download("http://list.iblocklist.com/?list=qlprgwgdkojunfdlzsiv&fileformat=hosts&archiveformat=gz", "temp/iblocklist-hosts.gz")
    download("http://list.iblocklist.com/?list=xshktygkujudfnjfioro&fileformat=p2p&archiveformat=gz", "temp/microsoft-p2p.gz")
    download("http://list.iblocklist.com/?list=xshktygkujudfnjfioro&fileformat=cidr&archiveformat=gz", "temp/microsoft-cidr.gz")
    download("http://list.iblocklist.com/?list=xoebmbyexwuiogmbyprb&fileformat=p2p&archiveformat=gz", "temp/proxy-p2p.gz")
    download("http://list.iblocklist.com/?list=xoebmbyexwuiogmbyprb&fileformat=cidr&archiveformat=gz", "temp/proxy-cidr.gz")

    unzip_gz("temp/iblocklist-hosts.gz", "temp/iblocklist-hosts.txt")
    unzip_gz("temp/microsoft-p2p.gz", "temp/microsoft-p2p.txt")
    unzip_gz("temp/microsoft-cidr.gz", "temp/microsoft-cidr.txt")
    unzip_gz("temp/proxy-p2p.gz", "temp/proxy-p2p.txt")
    unzip_gz("temp/proxy-cidr.gz", "temp/proxy-cidr.txt")

#   merge_hosts("temp/sysctl-hosts.txt", "adh/tmp/sysctl-hosts.txt")
    merge_hosts("temp/iblocklist-hosts.txt", "adh/tmp/iblocklist-hosts.txt")

    domains = process_asndrop('temp/asndrop.json')
    merge_with_existing(domains, 'adh/tmp/spamhaus-asndrop.txt')

    microsoft_cidrs = process_list("temp/microsoft-p2p.txt", "temp/microsoft-cidr.txt")
    merge_with_existing(microsoft_cidrs, "adh/tmp/iblocklist-microsoftip.txt")

    proxy_cidrs = process_list("temp/proxy-p2p.txt", "temp/proxy-cidr.txt")
    merge_with_existing(proxy_cidrs, "adh/tmp/iblocklist-proxyip.txt")

    temp_files = [
#       "temp/sysctl-hosts.txt", "temp/iblocklist-hosts.txt", "temp/iblocklist-hosts.gz",
        "temp/microsoft-p2p.txt", "temp/microsoft-cidr.txt",
        "temp/proxy-p2p.txt", "temp/proxy-cidr.txt",
        "temp/microsoft-p2p.gz", "temp/microsoft-cidr.gz",
        "temp/proxy-p2p.gz", "temp/proxy-cidr.gz",
        "temp/asndrop.json"
    ]
    for temp_file in temp_files:
        if os.path.exists(temp_file):
            os.remove(temp_file)

if __name__ == "__main__":
    main()