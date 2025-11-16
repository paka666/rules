import requests
from urllib.parse import urlparse
import re
from ipaddress import IPv6Address, IPv4Address, AddressValueError
import os
import time
import glob
import shutil

# List of URLs
urls = [
    "http://github.itzmx.com/1265578519/OpenTracker/master/tracker.txt",
    "https://cf.trackerslist.com/all.txt",
    "https://cf.trackerslist.com/best.txt",
    "https://cf.trackerslist.com/http.txt",
    "https://cf.trackerslist.com/nohttp.txt",
    "https://github.itzmx.com/1265578519/OpenTracker/master/tracker.txt",
    "https://newtrackon.com/api/10",
    "https://newtrackon.com/api/all",
    "https://newtrackon.com/api/http",
    "https://newtrackon.com/api/live",
    "https://newtrackon.com/api/stable",
    "https://newtrackon.com/api/udp",
    "https://raw.githubusercontent.com/DeSireFire/animeTrackerList/master/AT_all.txt",
    "https://raw.githubusercontent.com/DeSireFire/animeTrackerList/master/AT_all_http.txt",
    "https://raw.githubusercontent.com/DeSireFire/animeTrackerList/master/AT_all_https.txt",
    "https://raw.githubusercontent.com/DeSireFire/animeTrackerList/master/AT_all_ip.txt",
    "https://raw.githubusercontent.com/DeSireFire/animeTrackerList/master/AT_all_udp.txt",
    "https://raw.githubusercontent.com/DeSireFire/animeTrackerList/master/AT_all_ws.txt",
    "https://raw.githubusercontent.com/DeSireFire/animeTrackerList/master/AT_bad.txt",
    "https://raw.githubusercontent.com/DeSireFire/animeTrackerList/master/AT_best.txt",
    "https://raw.githubusercontent.com/DeSireFire/animeTrackerList/master/AT_best_ip.txt",
    "https://raw.githubusercontent.com/XIU2/TrackersListCollection/master/all.txt",
    "https://raw.githubusercontent.com/XIU2/TrackersListCollection/master/best.txt",
    "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all.txt",
    "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all_http.txt",
    "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all_https.txt",
    "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all_i2p.txt",
    "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all_ip.txt",
    "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all_udp.txt",
    "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all_ws.txt",
    "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best.txt",
    "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best_ip.txt",
    "https://torrends.to/torrent-tracker-list/?download=latest",
    "https://trackerslist.com/all.txt",
    "https://trackerslist.com/best.txt",
    "https://trackerslist.com/http.txt"
]

# Fetch contents from URLs
contents = []
for url in urls:
    try:
        r = requests.get(url, timeout=10)
        r.raise_for_status()
        contents.append(r.text)
    except Exception as e:
        print(f"Failed to fetch {url}: {e}")

# Read local file if exists
local_file = "trackers/trackers-back.txt"
if os.path.exists(local_file):
    with open(local_file, "r", encoding="utf-8") as f:
        contents.append(f.read())

# Combine all contents
all_text = "\n".join(contents)

# Split into lines and clean
lines = all_text.splitlines()
cleaned = []
for line in lines:
    # Remove comments
    line = re.split(r"[#!;]", line)[0].strip()
    if not line:
        continue
    # Split by commas, semicolons, spaces and remove blanks
    parts = [p.strip() for p in re.split(r"[ ,;]", line) if p.strip()]
    cleaned.extend(parts)

# Define protocols and fixes
protocols = ["http:/", "https:/", "udp:/", "ws:/", "wss:/"]
fixed_protos = {
    "http:/": "http://",
    "https:/": "https://",
    "udp:/": "udp://",
    "ws:/": "ws://",
    "wss:/": "wss://",
}

# First fix starting protocols if missing /
for i in range(len(cleaned)):
    for proto in protocols:
        if cleaned[i].startswith(proto):
            cleaned[i] = fixed_protos[proto] + cleaned[i][len(proto):]
            break

# A: Split concatenated trackers
new_cleaned = []
for t in cleaned:
    current = t
    while True:
        found = False
        for proto in protocols:
            pos = current.find(proto, 1)
            if pos > 0:
                first = current[:pos]
                rest = fixed_protos[proto] + current[pos + len(proto):]
                new_cleaned.append(first)
                current = rest
                found = True
                break
        if not found:
            new_cleaned.append(current)
            break
cleaned = [t for t in new_cleaned if t]

# C: Fix endings like /announce+108, /announce", //announce
for i in range(len(cleaned)):
    cleaned[i] = cleaned[i].replace("//announce", "/announce")
    cleaned[i] = re.sub(r"/announce(\+\d*|\"| \+)?$", "/announce", cleaned[i])

# Fetch TLD list
try:
    tld_text = requests.get("https://data.iana.org/TLD/tlds-alpha-by-domain.txt", timeout=10).text
    tlds = {line.lower() for line in tld_text.splitlines() if line and not line.startswith("#")}
except Exception:
    tlds = set()
    print("Failed to fetch TLD list, using empty set.")
tlds.add("i2p")  # Add custom for I2P

def is_valid_host(host, tlds):
    try:
        IPv4Address(host)
        return True
    except AddressValueError:
        pass
    try:
        IPv6Address(host)
        return True
    except AddressValueError:
        pass
    if "." in host:
        tld = host.rsplit(".", 1)[-1].lower()
        return tld in tlds
    return False

# C & D: Fix [] , concatenated ports, remove invalid no TLD
valid_trackers = []
for t in cleaned:
    parsed = urlparse(t)
    if not parsed.scheme or not parsed.netloc:
        continue

    # C: Fix [] if not valid IPv6
    netloc = parsed.netloc
    port_part = None
    if ":" in netloc:
        addr_part, port_part = netloc.rsplit(":", 1)
    else:
        addr_part = netloc
    if addr_part.startswith("[") and addr_part.endswith("]"):
        inside = addr_part[1:-1]
        try:
            IPv6Address(inside)
            # valid, keep
        except AddressValueError:
            # remove []
            new_addr = inside
            new_netloc = new_addr
            if port_part:
                new_netloc += ":" + port_part
            parsed = parsed._replace(netloc=new_netloc)

    # D: Fix concatenated port
    if parsed.port is None:
        netloc = parsed.netloc
        match = re.match(r"^(.+?)(\d+)$", netloc)
        if match:
            base = match.group(1)
            port_str = match.group(2)
            try:
                port = int(port_str)
                if 1 <= port <= 65535 and is_valid_host(base, tlds):
                    new_netloc = base + ":" + port_str
                    parsed = parsed._replace(netloc=new_netloc)
            except ValueError:
                pass

    # Check valid host
    host = parsed.hostname
    if host is None:
        continue
    if not is_valid_host(host, tlds):
        continue

    t = parsed.geturl()
    valid_trackers.append(t)

cleaned = valid_trackers

# B: Append /announce if not matching suffix
suffix_pattern = re.compile(r"(\.i2p(:\d+)?/a|/announce(\.php)?(\?(passkey|authkey)=[^?&]+(&[^?&]+)*)?|announce(\.php)?/[^/]+)$")
for i in range(len(cleaned)):
    if not suffix_pattern.search(cleaned[i]):
        cleaned[i] += "/announce"

# E: Remove default ports (precise, not for 8080 etc.)
default_ports = {
    "http": 80,
    "https": 443,
    "ws": 80,
    "wss": 443,
}
new_cleaned = []
for t in cleaned:
    parsed = urlparse(t)
    if parsed.scheme in default_ports and parsed.port == default_ports[parsed.scheme]:
        new_netloc = parsed.hostname
        if parsed.username:
            auth = parsed.username
            if parsed.password:
                auth += ":" + parsed.password
            new_netloc = auth + "@" + new_netloc
        t = parsed._replace(netloc=new_netloc).geturl()
    new_cleaned.append(t)
cleaned = new_cleaned

# Dedup and sort
unique = sorted(set(cleaned))

# F: Backup and update local, keep last 3 backups
dir_path = "trackers"
os.makedirs(dir_path, exist_ok=True)
local = os.path.join(dir_path, "trackers-back.txt")
if os.path.exists(local):
    timestamp = time.strftime("%Y%m%d_%H%M%S")
    backup = os.path.join(dir_path, f"{timestamp}-trackers-back.txt")
    shutil.copy(local, backup)

with open(local, "w", encoding="utf-8") as f:
    f.write("\n".join(unique) + "\n")

# Clean old backups
backups = glob.glob(os.path.join(dir_path, "*-trackers-back.txt"))
backups.sort(key=os.path.getmtime, reverse=True)
for old_backup in backups[3:]:
    os.remove(old_backup)

print("Processing complete. Updated trackers-back.txt")
