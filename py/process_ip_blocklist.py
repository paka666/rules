#!/usr/bin/env python3
import os
import re
import zipfile
import tempfile
import requests
import ipaddress
import json
import gzip
import unicodedata
import logging
import chardet
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
from ipaddress import IPv4Address, IPv6Address, IPv4Network, IPv6Network, AddressValueError, NetmaskValueError
from time import sleep
from typing import List, Tuple, Set
from urllib.parse import urlparse

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)

# 组和 URL 映射
GROUPS = {
    'a': [
        "https://raw.githubusercontent.com/bitwire-it/ipblocklist/main/inbound.txt",
        "https://raw.githubusercontent.com/bitwire-it/ipblocklist/main/ip-list.txt",
        "https://raw.githubusercontent.com/bitwire-it/ipblocklist/main/outbound.txt",
    ],
    'b1': [
        "https://iplists.firehol.org/files/bds_atif.ipset",
        "https://iplists.firehol.org/files/bitcoin_nodes.ipset",
        "https://iplists.firehol.org/files/bitcoin_nodes_1d.ipset",
        "https://iplists.firehol.org/files/bitcoin_nodes_7d.ipset",
        "https://iplists.firehol.org/files/bitcoin_nodes_30d.ipset",
        "https://iplists.firehol.org/files/blocklist_de.ipset",
        "https://iplists.firehol.org/files/blocklist_de_ftp.ipset",
        "https://iplists.firehol.org/files/blocklist_de_sip.ipset",
        "https://iplists.firehol.org/files/blocklist_de_ssh.ipset",
        "https://iplists.firehol.org/files/blocklist_net_ua.ipset",
        "https://iplists.firehol.org/files/blocklist_de_bots.ipset",
        "https://iplists.firehol.org/files/blocklist_de_imap.ipset",
        "https://iplists.firehol.org/files/blocklist_de_mail.ipset",
        "https://iplists.firehol.org/files/blocklist_de_apache.ipset",
        "https://iplists.firehol.org/files/blocklist_de_strongips.ipset",
        "https://iplists.firehol.org/files/blocklist_de_bruteforce.ipset",
        "https://iplists.firehol.org/files/botscout.ipset",
        "https://iplists.firehol.org/files/botscout_1d.ipset",
        "https://iplists.firehol.org/files/botscout_7d.ipset",
        "https://iplists.firehol.org/files/botscout_30d.ipset",
        "https://iplists.firehol.org/files/bruteforceblocker.ipset",
        "https://iplists.firehol.org/files/ciarmy.ipset",
        "https://iplists.firehol.org/files/cybercrime.ipset",
        "https://iplists.firehol.org/files/cta_cryptowall.ipset",
        "https://iplists.firehol.org/files/cleantalk.ipset",
        "https://iplists.firehol.org/files/cleantalk_1d.ipset",
        "https://iplists.firehol.org/files/cleantalk_7d.ipset",
        "https://iplists.firehol.org/files/cleantalk_30d.ipset",
        "https://iplists.firehol.org/files/cleantalk_new.ipset",
        "https://iplists.firehol.org/files/cleantalk_top20.ipset",
        "https://iplists.firehol.org/files/cleantalk_new_1d.ipset",
        "https://iplists.firehol.org/files/cleantalk_new_7d.ipset",
        "https://iplists.firehol.org/files/cleantalk_new_30d.ipset",
        "https://iplists.firehol.org/files/cleantalk_updated.ipset",
        "https://iplists.firehol.org/files/cleantalk_updated_1d.ipset",
        "https://iplists.firehol.org/files/cleantalk_updated_7d.ipset",
        "https://iplists.firehol.org/files/cleantalk_updated_30d.ipset",
        "https://iplists.firehol.org/files/dshield.netset",
        "https://iplists.firehol.org/files/dshield_1d.netset",
        "https://iplists.firehol.org/files/dshield_7d.netset",
        "https://iplists.firehol.org/files/darklist_de.netset",
        "https://iplists.firehol.org/files/dshield_30d.netset",
        "https://iplists.firehol.org/files/et_block.netset",
        "https://iplists.firehol.org/files/et_dshield.netset",
        "https://iplists.firehol.org/files/et_spamhaus.netset",
        "https://iplists.firehol.org/files/et_compromised.ipset",
        "https://iplists.firehol.org/files/feodo.ipset",
        "https://iplists.firehol.org/files/feodo_badips.ipset",
        "https://iplists.firehol.org/files/firehol_level1.netset",
        "https://iplists.firehol.org/files/firehol_level2.netset",
        "https://iplists.firehol.org/files/firehol_level3.netset",
        "https://iplists.firehol.org/files/firehol_level4.netset",
        "https://iplists.firehol.org/files/firehol_webclient.netset",
        "https://iplists.firehol.org/files/firehol_webserver.netset",
        "https://iplists.firehol.org/files/firehol_abusers_1d.netset",
        "https://iplists.firehol.org/files/firehol_abusers_30d.netset",
        "https://iplists.firehol.org/files/greensnow.ipset",
        "https://iplists.firehol.org/files/gpf_comics.ipset",
        "https://iplists.firehol.org/files/graphiclineweb.netset",
        "https://iplists.firehol.org/files/iblocklist_malc0de.netset",
        "https://iplists.firehol.org/files/iblocklist_pedophiles.netset",
        "https://iplists.firehol.org/files/iblocklist_abuse_zeus.netset",
        "https://iplists.firehol.org/files/iblocklist_abuse_palevo.netset",
        "https://iplists.firehol.org/files/iblocklist_abuse_spyeye.netset",
        "https://iplists.firehol.org/files/iblocklist_yoyo_adservers.netset",
        "https://iplists.firehol.org/files/iblocklist_spamhaus_drop.netset",
        "https://iplists.firehol.org/files/iblocklist_ciarmy_malicious.netset",
        "https://iplists.firehol.org/files/iblocklist_cruzit_web_attacks.netset",
        "https://iplists.firehol.org/files/myip.ipset",
        "https://iplists.firehol.org/files/php_dictionary.ipset",
        "https://iplists.firehol.org/files/php_dictionary_1d.ipset",
        "https://iplists.firehol.org/files/php_dictionary_7d.ipset",
        "https://iplists.firehol.org/files/php_dictionary_30d.ipset",
        "https://iplists.firehol.org/files/php_harvesters.ipset",
        "https://iplists.firehol.org/files/php_harvesters_1d.ipset",
        "https://iplists.firehol.org/files/php_harvesters_7d.ipset",
        "https://iplists.firehol.org/files/php_harvesters_30d.ipset",
        "https://iplists.firehol.org/files/php_spammers.ipset",
        "https://iplists.firehol.org/files/php_spammers_1d.ipset",
        "https://iplists.firehol.org/files/php_spammers_7d.ipset",
        "https://iplists.firehol.org/files/php_spammers_30d.ipset",
        "https://iplists.firehol.org/files/php_commenters.ipset",
        "https://iplists.firehol.org/files/php_commenters_1d.ipset",
        "https://iplists.firehol.org/files/php_commenters_7d.ipset",
        "https://iplists.firehol.org/files/php_commenters_30d.ipset",
        "https://iplists.firehol.org/files/sblam.ipset",
        "https://iplists.firehol.org/files/spamhaus_drop.netset",
        "https://iplists.firehol.org/files/spamhaus_edrop.netset",
        "https://iplists.firehol.org/files/stopforumspam.ipset",
        "https://iplists.firehol.org/files/stopforumspam_1d.ipset",
        "https://iplists.firehol.org/files/stopforumspam_7d.ipset",
        "https://iplists.firehol.org/files/stopforumspam_30d.ipset",
        "https://iplists.firehol.org/files/stopforumspam_90d.ipset",
        "https://iplists.firehol.org/files/stopforumspam_180d.ipset",
        "https://iplists.firehol.org/files/stopforumspam_365d.ipset",
        "https://iplists.firehol.org/files/stopforumspam_toxic.netset",
        "https://iplists.firehol.org/files/vxvault.ipset",
        "https://iplists.firehol.org/files/yoyo_adservers.ipset",
        "https://cinsscore.com/list/ci-badguys.txt",
        "https://www.spamhaus.org/drop/drop.txt",
        "https://www.spamhaus.org/drop/edrop.txt",
        "https://pgl.yoyo.org/as/iplist.php?showintro=0&mimetype=plaintext",
        "https://rules.emergingthreats.net/fwrules/emerging-Block-IPs.txt",
        "https://raw.githubusercontent.com/paka666/rules/main/adh/backup/ip.txt",
        "https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/botvrij_dst.ipset",
    ],
    'b2': [
        "https://team-cymru.org/Services/Bogons/fullbogons-ipv4.txt",
        "https://team-cymru.org/Services/Bogons/fullbogons-ipv6.txt",
#       "https://iplists.firehol.org/files/cidr_report_bogons.netset",
#       "https://iplists.firehol.org/files/iblocklist_cidr_report_bogons.netset",
    ],
    'b3': [
        "https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/feodo.ipset",
        "https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/botvrij_src.ipset",
    ],
    'c': [
        "https://dataplane.org/signals/dnsrd.txt",
        "https://dataplane.org/signals/vncrfb.txt",
        "https://dataplane.org/signals/sipquery.txt",
        "https://dataplane.org/signals/sshclient.txt",
        "https://dataplane.org/signals/dnsrdany.txt",
        "https://dataplane.org/signals/sshpwauth.txt",
        "https://dataplane.org/signals/dnsversion.txt",
        "https://dataplane.org/signals/sipinvitation.txt",
        "https://dataplane.org/signals/sipregistration.txt",
    ],
    'd1': [
#       "http://list.iblocklist.com/?list=cwworuawihqvocglcoss&fileformat=p2p&archiveformat=gz",
		"http://storage.iblocklist.com/t5j1mwxwpmwt6ihp4iau/files/gwknwy19vwix6af01346/cwworuawihqvocglcoss.gz",
#       "http://list.iblocklist.com/?list=czvaehmjpsnwwttrdoyl&fileformat=p2p&archiveformat=gz",
		"http://storage.iblocklist.com/t5j1mwxwpmwt6ihp4iau/files/8ubmtdv6ydoum44tapu9/czvaehmjpsnwwttrdoyl.gz",
#       "http://list.iblocklist.com/?list=dgxtneitpuvgqqcpfulq&fileformat=p2p&archiveformat=gz",
		"http://storage.iblocklist.com/t5j1mwxwpmwt6ihp4iau/files/434dtps2q3qqas45x8yu/dgxtneitpuvgqqcpfulq.gz",
#       "http://list.iblocklist.com/?list=dufcxgnbjsdwmwctgfuj&fileformat=p2p&archiveformat=gz",
		"http://storage.iblocklist.com/t5j1mwxwpmwt6ihp4iau/files/92k2apytmhqpw144jgvp/dufcxgnbjsdwmwctgfuj.gz",
#       "http://list.iblocklist.com/?list=ficutxiwawokxlcyoeye&fileformat=p2p&archiveformat=gz",
        "http://storage.iblocklist.com/t5j1mwxwpmwt6ihp4iau/files/wlfv9k6axpaljol9ifh8/ficutxiwawokxlcyoeye.gz",
#       "http://list.iblocklist.com/?list=ghlzqtqxnzctvvajwwag&fileformat=p2p&archiveformat=gz",
        "http://storage.iblocklist.com/t5j1mwxwpmwt6ihp4iau/files/5k10a31gwjqkrb34tmpo/ghlzqtqxnzctvvajwwag.gz",
#       "http://list.iblocklist.com/?list=gyisgnzbhppbvsphucsw&fileformat=p2p&archiveformat=gz",
        "http://storage.iblocklist.com/t5j1mwxwpmwt6ihp4iau/files/1pqcsolyww7n8g2rx40d/gyisgnzbhppbvsphucsw.gz",
#       "http://list.iblocklist.com/?list=llvtlsjyoyiczbkjsxpf&fileformat=p2p&archiveformat=gz",
        "http://storage.iblocklist.com/t5j1mwxwpmwt6ihp4iau/files/eihywd6wl6j75qq594cg/llvtlsjyoyiczbkjsxpf.gz",
#       "http://list.iblocklist.com/?list=mcvxsnihddgutbjfbghy&fileformat=p2p&archiveformat=gz",
        "http://storage.iblocklist.com/t5j1mwxwpmwt6ihp4iau/files/j4k4zw8py2lcqnw6ibi3/mcvxsnihddgutbjfbghy.gz",
#       "http://list.iblocklist.com/?list=npkuuhuxcsllnhoamkvm&fileformat=p2p&archiveformat=gz",
        "http://storage.iblocklist.com/t5j1mwxwpmwt6ihp4iau/files/n8p4njhzou8pfwwdocy7/npkuuhuxcsllnhoamkvm.gz",
#       "http://list.iblocklist.com/?list=pbqcylkejciyhmwttify&fileformat=p2p&archiveformat=gz",
        "http://storage.iblocklist.com/t5j1mwxwpmwt6ihp4iau/files/6wnxy6orh9e4obvdm6ss/pbqcylkejciyhmwttify.gz",
#       "http://list.iblocklist.com/?list=usrcshglbiilevmyfhse&fileformat=p2p&archiveformat=gz",
        "http://storage.iblocklist.com/t5j1mwxwpmwt6ihp4iau/files/4xevuyt50057hiws91o7/usrcshglbiilevmyfhse.gz",
#       "http://list.iblocklist.com/?list=uwnukjqktoggdknzrhgh&fileformat=p2p&archiveformat=gz",
        "http://storage.iblocklist.com/t5j1mwxwpmwt6ihp4iau/files/bk5hlv19u32ld9jenfp7/uwnukjqktoggdknzrhgh.gz",
#       "http://list.iblocklist.com/?list=xpbqleszmajjesnzddhv&fileformat=p2p&archiveformat=gz",
        "http://storage.iblocklist.com/t5j1mwxwpmwt6ihp4iau/files/ckurfflb4d5qor36kyrw/xpbqleszmajjesnzddhv.gz",
#       "http://list.iblocklist.com/?list=ydxerpxkpcfqjaybcssw&fileformat=p2p&archiveformat=gz",
        "http://storage.iblocklist.com/t5j1mwxwpmwt6ihp4iau/files/6pkf7nyjo8qshtgxen2d/ydxerpxkpcfqjaybcssw.gz",
#       "http://list.iblocklist.com/?list=zbdlwrqkabxbcppvrnos&fileformat=p2p&archiveformat=gz",
        "http://storage.iblocklist.com/t5j1mwxwpmwt6ihp4iau/files/bzqiax84lkx33byqxwgd/zbdlwrqkabxbcppvrnos.gz",
#       "http://list.iblocklist.com/?list=zhogegszwduurnvsyhdf&fileformat=p2p&archiveformat=gz",
        "http://storage.iblocklist.com/t5j1mwxwpmwt6ihp4iau/files/mznl4bs003h34jsf73xb/zhogegszwduurnvsyhdf.gz",
    ],
    'd2': [
#       "http://list.iblocklist.com/?list=cwworuawihqvocglcoss&fileformat=cidr&archiveformat=gz",
        "http://storage.iblocklist.com/t5j1mwxwpmwt6ihp4iau/files/b8xc1b9hrydgt7ruxmh0/cwworuawihqvocglcoss.gz",
#       "http://list.iblocklist.com/?list=czvaehmjpsnwwttrdoyl&fileformat=cidr&archiveformat=gz",
        "http://storage.iblocklist.com/t5j1mwxwpmwt6ihp4iau/files/dvk87c6ya349s1mvr2om/czvaehmjpsnwwttrdoyl.gz",
#       "http://list.iblocklist.com/?list=dgxtneitpuvgqqcpfulq&fileformat=cidr&archiveformat=gz",
        "http://storage.iblocklist.com/t5j1mwxwpmwt6ihp4iau/files/dfrvd6nl31nb00naqq3f/dgxtneitpuvgqqcpfulq.gz",
#       "http://list.iblocklist.com/?list=dufcxgnbjsdwmwctgfuj&fileformat=cidr&archiveformat=gz",
        "http://storage.iblocklist.com/t5j1mwxwpmwt6ihp4iau/files/eofij3nq61z87b5jdn2g/dufcxgnbjsdwmwctgfuj.gz",
#       "http://list.iblocklist.com/?list=ficutxiwawokxlcyoeye&fileformat=cidr&archiveformat=gz",
        "http://storage.iblocklist.com/t5j1mwxwpmwt6ihp4iau/files/niv0jmqk6x25nqwapffz/ficutxiwawokxlcyoeye.gz",
#       "http://list.iblocklist.com/?list=ghlzqtqxnzctvvajwwag&fileformat=cidr&archiveformat=gz",
        "http://storage.iblocklist.com/t5j1mwxwpmwt6ihp4iau/files/m76sr1usssrbjf5jftvi/ghlzqtqxnzctvvajwwag.gz",
#       "http://list.iblocklist.com/?list=gyisgnzbhppbvsphucsw&fileformat=cidr&archiveformat=gz",
        "http://storage.iblocklist.com/t5j1mwxwpmwt6ihp4iau/files/qtryds3oa33xep2o7hah/gyisgnzbhppbvsphucsw.gz",
#       "http://list.iblocklist.com/?list=llvtlsjyoyiczbkjsxpf&fileformat=cidr&archiveformat=gz",
        "http://storage.iblocklist.com/t5j1mwxwpmwt6ihp4iau/files/6xq3u16vomgd8a2lq3ve/llvtlsjyoyiczbkjsxpf.gz",
#       "http://list.iblocklist.com/?list=mcvxsnihddgutbjfbghy&fileformat=cidr&archiveformat=gz",
        "http://storage.iblocklist.com/t5j1mwxwpmwt6ihp4iau/files/qbshlz21410mjp29iedn/mcvxsnihddgutbjfbghy.gz",
#       "http://list.iblocklist.com/?list=npkuuhuxcsllnhoamkvm&fileformat=cidr&archiveformat=gz",
        "http://storage.iblocklist.com/t5j1mwxwpmwt6ihp4iau/files/28pbgt8m8vrei4e9l2vs/npkuuhuxcsllnhoamkvm.gz",
#       "http://list.iblocklist.com/?list=pbqcylkejciyhmwttify&fileformat=cidr&archiveformat=gz",
        "http://storage.iblocklist.com/t5j1mwxwpmwt6ihp4iau/files/9j65dw5731guhegn1aqx/pbqcylkejciyhmwttify.gz",
#       "http://list.iblocklist.com/?list=usrcshglbiilevmyfhse&fileformat=cidr&archiveformat=gz",
        "http://storage.iblocklist.com/t5j1mwxwpmwt6ihp4iau/files/59xwp6jxwfjmoyv2xk6v/usrcshglbiilevmyfhse.gz",
#       "http://list.iblocklist.com/?list=uwnukjqktoggdknzrhgh&fileformat=cidr&archiveformat=gz",
        "http://storage.iblocklist.com/t5j1mwxwpmwt6ihp4iau/files/snudhxbpd7ddvyrl70id/uwnukjqktoggdknzrhgh.gz",
#       "http://list.iblocklist.com/?list=xpbqleszmajjesnzddhv&fileformat=cidr&archiveformat=gz",
        "http://storage.iblocklist.com/t5j1mwxwpmwt6ihp4iau/files/t65s3qfzp6tbp06uoj5x/xpbqleszmajjesnzddhv.gz",
#       "http://list.iblocklist.com/?list=ydxerpxkpcfqjaybcssw&fileformat=cidr&archiveformat=gz",
        "http://storage.iblocklist.com/t5j1mwxwpmwt6ihp4iau/files/j2yqd405xd96skkoiljg/ydxerpxkpcfqjaybcssw.gz",
#       "http://list.iblocklist.com/?list=zbdlwrqkabxbcppvrnos&fileformat=cidr&archiveformat=gz",
        "http://storage.iblocklist.com/t5j1mwxwpmwt6ihp4iau/files/i8c63um9fphity2wlvdq/zbdlwrqkabxbcppvrnos.gz",
#       "http://list.iblocklist.com/?list=zhogegszwduurnvsyhdf&fileformat=cidr&archiveformat=gz",
        "http://storage.iblocklist.com/t5j1mwxwpmwt6ihp4iau/files/zk7nrmh0mcesmkovyj74/zhogegszwduurnvsyhdf.gz",
    ],
    'e': [
        "https://www.spamhaus.org/drop/drop_v4.json",
        "https://www.spamhaus.org/drop/drop_v6.json",
    ],
    'f1': [
        "https://rules.emergingthreats.net/fwrules/emerging-IPF-ALL.rules",
        "https://rules.emergingthreats.net/fwrules/emerging-IPF-CC.rules",
        "https://rules.emergingthreats.net/fwrules/emerging-IPF-DROP.rules",
        "https://rules.emergingthreats.net/fwrules/emerging-IPF-DSHIELD.rules",
    ],
    'f2': [
        "https://rules.emergingthreats.net/fwrules/emerging-IPTABLES-ALL.rules",
        "https://rules.emergingthreats.net/fwrules/emerging-IPTABLES-CC.rules",
        "https://rules.emergingthreats.net/fwrules/emerging-IPTABLES-DROP.rules",
        "https://rules.emergingthreats.net/fwrules/emerging-IPTABLES-DSHIELD.rules",
    ],
    'f3': [
        "https://rules.emergingthreats.net/fwrules/emerging-PF-ALL.rules",
        "https://rules.emergingthreats.net/fwrules/emerging-PF-CC.rules",
        "https://rules.emergingthreats.net/fwrules/emerging-PF-DROP.rules",
        "https://rules.emergingthreats.net/fwrules/emerging-PF-DSHIELD.rules",
    ],
    'f4': [
        "https://rules.emergingthreats.net/fwrules/emerging-PIX-ALL.rules",
        "https://rules.emergingthreats.net/fwrules/emerging-PIX-CC.rules",
        "https://rules.emergingthreats.net/fwrules/emerging-PIX-DROP.rules",
        "https://rules.emergingthreats.net/fwrules/emerging-PIX-DSHIELD.rules",
    ],
    'g': [
        "https://codeload.github.com/stamparm/maltrail/zip/refs/heads/master",
    ],
    'h': [
        "https://public-dns.info/nameservers.txt",
        "https://raw.githubusercontent.com/bitwire-it/ip_list_fetch/refs/heads/main/dns.txt"
    ],
    'proxy': [
        "https://iplists.firehol.org/files/et_tor.ipset",
        "https://iplists.firehol.org/files/dm_tor.ipset",
        "https://iplists.firehol.org/files/tor_exits.ipset",
        "https://iplists.firehol.org/files/tor_exits_1d.ipset",
        "https://iplists.firehol.org/files/tor_exits_7d.ipset",
        "https://iplists.firehol.org/files/tor_exits_30d.ipset",
        "https://iplists.firehol.org/files/sslproxies.ipset",
        "https://iplists.firehol.org/files/sslproxies_1d.ipset",
        "https://iplists.firehol.org/files/sslproxies_7d.ipset",
        "https://iplists.firehol.org/files/sslproxies_30d.ipset",
        "https://iplists.firehol.org/files/socks_proxy.ipset",
        "https://iplists.firehol.org/files/socks_proxy_1d.ipset",
        "https://iplists.firehol.org/files/socks_proxy_7d.ipset",
        "https://iplists.firehol.org/files/socks_proxy_30d.ipset",
        "https://iplists.firehol.org/files/firehol_proxies.netset",
        "https://iplists.firehol.org/files/firehol_anonymous.netset",
        "https://iplists.firehol.org/files/iblocklist_onion_router.netset",
        "https://iplists.firehol.org/files/geolite2_country/satellite.netset",
        "https://iplists.firehol.org/files/geolite2_country/anonymous.netset",
    ]
}

def detect_encoding(file_path: Path) -> str:
    """检测文件编码"""
    try:
        with open(file_path, 'rb') as f:
            raw_data = f.read()
            result = chardet.detect(raw_data)
            encoding = result['encoding'] or 'utf-8'
            # 确保编码是Python支持的
            if encoding.lower() in ['utf-8', 'ascii', 'latin-1', 'iso-8859-1', 'windows-1252']:
                return encoding
            else:
                return 'utf-8'
    except Exception as e:
        logging.warning(f"Encoding detection failed for {file_path}: {e}")
        return 'utf-8'

def enhanced_universal_clean(line: str) -> str:
    """增强的清理函数，彻底处理各种字符和格式问题"""
    if not isinstance(line, str):
        return ""
    # 深度Unicode标准化
    line = unicodedata.normalize('NFKD', line)
    # 全角转半角
    line = ''.join(
        chr(ord(c) - 65248) if 65281 <= ord(c) <= 65374 else c 
        for c in line
    )

    # 移除BOM和其他控制字符（保留\t, \n, \r）
    line = re.sub(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', '', line)
    # 移除行内注释（#!;）并保留第一个部分
    line = re.split(r'[#!;]', line, 1)[0]
    # 彻底去除首尾空白字符
    line = line.strip()
    # 标准化行内空白（多个空白字符替换为单个空格）
    line = re.sub(r'\s+', ' ', line)
    # 再次去除首尾空白
    line = line.strip()
    # 检查是否为空或注释行
    if not line or line.startswith(('#', '!', ';')):
        return ""
    return line

def clean_lines(lines: List[str]) -> List[str]:
    """清理多行文本"""
    if not lines:
        return []
    cleaned_set: Set[str] = set()
    for line in lines:
        cleaned = enhanced_universal_clean(line)
        if cleaned:
            cleaned_set.add(cleaned)
    # 先按自然顺序排序，然后按IP类型排序
    return sorted(cleaned_set)

def download_file(url: str, path: Path, retries: int = 3) -> bool:
    """下载文件，支持重试"""
    headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36'
    }
    for attempt in range(1, retries + 1):
        try:
            # 对于跳转链接，允许重定向
            response = requests.get(
                url,
                stream=True,
                timeout=60,
                headers=headers,
                allow_redirects=True
            )
            response.raise_for_status()

            with open(path, 'wb') as f:
                for chunk in response.iter_content(chunk_size=8192):
                    if chunk:
                        f.write(chunk)
            # 验证文件是否成功下载（非空）
            if path.stat().st_size > 0:
                logging.info(f"Successfully downloaded {url} to {path}")
                return True
            else:
                logging.warning(f"Downloaded empty file from {url}")
                continue
        except requests.exceptions.RequestException as e:
            logging.warning(f"Download failed for {url} (attempt {attempt}/{retries}): {e}")
            if attempt < retries:
                sleep_time = 2 ** attempt
                sleep(sleep_time)
    logging.error(f"Failed to download {url} after {retries} attempts")
    return False

def extract_gz(gz_path: Path, retries: int = 2) -> List[str]:
    """解压.gz文件，支持重试"""
    for attempt in range(retries):
        try:
            with gzip.open(gz_path, 'rt', encoding='utf-8', errors='ignore') as f:
                return f.readlines()
        except Exception as e:
            logging.warning(f"GZ extraction failed for {gz_path} (attempt {attempt + 1}/{retries}): {e}")
            if attempt < retries - 1:
                sleep(1)
    return []

def extract_zip(zip_path: Path, extract_to: Path, retries: int = 2) -> bool:
    """解压.zip文件，支持重试"""
    for attempt in range(retries):
        try:
            with zipfile.ZipFile(zip_path, 'r') as z:
                z.extractall(extract_to)
            logging.info(f"Successfully extracted {zip_path}")
            return True
        except Exception as e:
            logging.warning(f"ZIP extraction failed for {zip_path} (attempt {attempt + 1}/{retries}): {e}")
            if attempt < retries - 1:
                sleep(1)
    return False

def diff_rules(a_file: str, b_file: str, output_file: str = 'adh/ip-blocklist.txt') -> int:
    """计算 a - b：从 blocklist.txt 减去 domain-blocklist.txt，输出 IP 规则，去除 || 和 ^"""
    b_rules = set()
    a_path = Path(a_file)
    b_path = Path(b_file)
    # 检查输入文件是否存在
    if not a_path.exists():
        logging.error(f"Input file {a_file} does not exist")
        return 0
    if not b_path.exists():
        logging.error(f"Input file {b_file} does not exist")
        return 0
    # 加载 domain-blocklist.txt 到 set
    enc_b = detect_encoding(b_path)
    try:
        with open(b_path, 'r', encoding=enc_b, errors='ignore') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith(('#', '!')):
                    b_rules.add(line)
    except Exception as e:
        logging.error(f"Failed to read {b_file}: {e}")
        return 0
    # 遍历 blocklist.txt，输出不在 domain-blocklist.txt 的行
    ip_count = 0
    enc_a = detect_encoding(a_path)
    try:
        with open(a_path, 'r', encoding=enc_a, errors='ignore') as a_f, \
             open(output_file, 'w', encoding='utf-8') as out_f:
            for line in a_f:
                line = line.strip()
                if line and not line.startswith(('#', '!')) and line not in b_rules:
                    cleaned_line = line
                    if cleaned_line.startswith('||'):
                        cleaned_line = cleaned_line[2:]
                    if cleaned_line.endswith('^'):
                        cleaned_line = cleaned_line[:-1]
                    if cleaned_line:
                        out_f.write(cleaned_line + '\n')
                        ip_count += 1
    except Exception as e:
        logging.error(f"Failed to process diff_rules: {e}")
        return 0
    logging.info(f"Generated {output_file} with {ip_count} IP rules")
    return ip_count

def process_group(urls: List[str], group_name: str, temp_dir: Path) -> List[str]:
    """处理标准文本组"""
    all_lines = []
    def download_and_process(url_idx):
        url, idx = url_idx
        filename = f"{group_name}_{idx}.txt"
        filepath = temp_dir / filename
        if download_file(url, filepath):
            enc = detect_encoding(filepath)
            try:
                with open(filepath, 'r', encoding=enc, errors='ignore') as f:
                    return f.readlines()
            except Exception as e:
                logging.warning(f"Failed to read {filepath}: {e}")
        return []
    with ThreadPoolExecutor(max_workers=8) as executor:
        futures = [executor.submit(download_and_process, (url, i)) for i, url in enumerate(urls)]
        for future in as_completed(futures):
            lines = future.result()
            if lines:
                all_lines.extend(lines)
    return clean_lines(all_lines)

def process_c(urls: List[str], temp_dir: Path) -> List[str]:
    """处理c组（管道分隔格式）"""
    ips = []
    with ThreadPoolExecutor(max_workers=4) as ex:
        future_to_path = {
            ex.submit(download_file, url, temp_dir / f"c_{i}.txt"): temp_dir / f"c_{i}.txt" 
            for i, url in enumerate(urls)
        }
        for future in as_completed(future_to_path):
            path = future_to_path[future]
            if future.result():
                enc = detect_encoding(path)
                try:
                    with open(path, 'r', encoding=enc, errors='ignore') as f:
                        for line in f:
                            parts = [p.strip() for p in line.split('|')]
                            if len(parts) >= 3 and parts[2]:
                                ips.append(parts[2])
                except IOError as e:
                    logging.warning(f"Failed to read {path}: {e}")
    return clean_lines(ips)

def range_to_cidrs(range_str: str) -> List[str]:
    """将IP范围转换为CIDR"""
    if '-' not in range_str:
        return [range_str.strip()]
    try:
        start_str, end_str = range_str.split('-')
        start_ip = IPv4Address(start_str.strip())
        end_ip = IPv4Address(end_str.strip())
        return [str(net) for net in ipaddress.summarize_address_range(start_ip, end_ip)]
    except (ValueError, TypeError, AddressValueError):
        return []

def process_d(group: str, urls: List[str], is_p2p: bool, temp_dir: Path) -> List[str]:
    """处理d组（gzip压缩格式）"""
    lines = []
    with ThreadPoolExecutor(max_workers=4) as ex:
        future_to_path = {
            ex.submit(download_file, url, temp_dir / f"{group}_{i}.gz"): temp_dir / f"{group}_{i}.gz"
            for i, url in enumerate(urls)
        }
        for future in as_completed(future_to_path):
            gz_path = future_to_path[future]
            if future.result():
                gz_lines = extract_gz(gz_path)
                if is_p2p:
                    for line in gz_lines:
                        if ':' in line:
                            range_part = line.rsplit(':', 1)[-1].strip()
                            cidrs = range_to_cidrs(range_part)
                            lines.extend(cidrs)
                else:
                    lines.extend(gz_lines)
    return clean_lines(lines)

def process_e(urls: List[str], temp_dir: Path) -> List[str]:
    """处理e组（JSON格式）"""
    cidrs = []
    with ThreadPoolExecutor(max_workers=2) as ex:
        future_to_path = {
            ex.submit(download_file, url, temp_dir / f"e_{i}.json"): temp_dir / f"e_{i}.json"
            for i, url in enumerate(urls)
        }
        for future in as_completed(future_to_path):
            path = future_to_path[future]
            if future.result():
                enc = detect_encoding(path)
                try:
                    with open(path, 'r', encoding=enc) as f:
                        for line in f:
                            try:
                                data = json.loads(line)
                                if 'cidr' in data and data.get('type') != 'metadata':
                                    cidrs.append(data['cidr'])
                            except json.JSONDecodeError:
                                continue
                except IOError as e:
                    logging.warning(f"Failed to read {path}: {e}")
    return clean_lines(cidrs)

def process_f(group: str, urls: List[str], regex: str, temp_dir: Path) -> List[str]:
    """处理f组（防火墙规则格式）"""
    items = []
    with ThreadPoolExecutor(max_workers=4) as ex:
        future_to_path = {
            ex.submit(download_file, url, temp_dir / f"{group}_{i}.rules"): temp_dir / f"{group}_{i}.rules"
            for i, url in enumerate(urls)
        }
        for future in as_completed(future_to_path):
            path = future_to_path[future]
            if future.result():
                enc = detect_encoding(path)
                try:
                    with open(path, 'r', encoding=enc, errors='ignore') as f:
                        content = f.read()
                        matches = re.findall(regex, content)
                        if group == 'f3':
                            for m in matches:
                                items.extend([
                                    item.strip() for item in m.split(',')
                                    if item.strip() and not item.strip().startswith('#')
                                ])
                        elif group == 'f4':
                            for ip, mask in matches:
                                try:
                                    prefix = bin(int(IPv4Address(mask))).count('1')
                                    items.append(f"{ip}/{prefix}")
                                except ValueError:
                                    continue
                        else:
                            items.extend(matches)
                except IOError as e:
                    logging.warning(f"Failed to read {path}: {e}")
    return clean_lines(items)

def extract_maltrail_ips_domains(lines: List[str]) -> Tuple[List[str], List[str]]:
    """
    专门处理maltrail格式的复杂规则
    提取IP/CIDR到ip_list，非IP到domain_list
    整合了a.py和b.py的最佳实践，并参考2.md的完善建议
    """
    # IPv4模式（精确匹配）
    ipv4_pattern = r'^((?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?))(?:/(?:0|[1-9]|[12][0-9]|3[0-2])(?!\d))?$'

    # IPv6模式（精确匹配）
    ipv6_pattern = r'^(?:(([0-9A-Fa-f]{1,4}:){7}([0-9A-Fa-f]{1,4}|:))|(([0-9A-Fa-f]{1,4}:){6}(:[0-9A-Fa-f]{1,4}|((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3})|:))|(([0-9A-Fa-f]{1,4}:){5}(((:[0-9A-Fa-f]{1,4}){1,2})|:((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3})|:))|(([0-9A-Fa-f]{1,4}:){4}(((:[0-9A-Fa-f]{1,4}){1,3})|((:[0-9A-Fa-f]{1,4})?:((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}))|:))|(([0-9A-Fa-f]{1,4}:){3}(((:[0-9A-Fa-f]{1,4}){1,4})|((:[0-9A-Fa-f]{1,4}){0,2}:((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}))|:))|(([0-9A-Fa-f]{1,4}:){2}(((:[0-9A-Fa-f]{1,4}){1,5})|((:[0-9A-Fa-f]{1,4}){0,3}:((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}))|:))|(([0-9A-Fa-f]{1,4}:){1}(((:[0-9A-Fa-f]{1,4}){1,6})|((:[0-9A-Fa-f]{1,4}){0,4}:((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}))|:))|(:(((:[0-9A-Fa-f]{1,4}){1,7})|((:[0-9A-Fa-f]{1,4}){0,5}:((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}))|:)))(/(?:0|[1-9]|[1-9][0-9]|1[0-1][0-9]|12[0-8])(?!\d))?$'

    ip_list = []
    domain_list = []

    for line in lines:
        original_line = line
        added = False

        # 1. 检查纯IPv4/IPv4 CIDR
        match = re.match(ipv4_pattern, line)
        if match:
            candidate = match.group(1)
            try:
                if '/' in candidate:
                    net = IPv4Network(candidate, strict=True)
                    if str(net) == candidate:
                        ip_list.append(candidate)
                        added = True
                else:
                    addr = IPv4Address(candidate)
                    if str(addr) == candidate:
                        ip_list.append(candidate)
                        added = True
                continue
            except (ValueError, AddressValueError, NetmaskValueError):
                pass

        # 2. 检查纯IPv6/IPv6 CIDR
        match = re.match(ipv6_pattern, line, re.IGNORECASE)
        if match:
            candidate = match.group(0)
            try:
                if '/' in candidate:
                    net = IPv6Network(candidate, strict=True)
                    if str(net) == candidate:
                        ip_list.append(candidate)
                        added = True
                else:
                    addr = IPv6Address(candidate)
                    if str(addr) == candidate:
                        ip_list.append(candidate)
                        added = True
            except (ValueError, AddressValueError, NetmaskValueError):
                pass

        if added:
            continue

        # 3. 处理逗号分隔格式（如：103.29.68.0/22,linode）
        if ',' in line:
            parts = line.split(',', 1)
            candidate = parts[0].strip()
            # 验证第一部分是否为有效的IP/CIDR
            try:
                if '/' in candidate:
                    net = ipaddress.ip_network(candidate, strict=False)
                    if net.prefixlen > 0:
                        ip_list.append(str(net))
                        added = True
                else:
                    addr = ipaddress.ip_address(candidate)
                    ip_list.append(str(addr))
                    added = True
            except (ValueError, AddressValueError, NetmaskValueError):
                pass

        if added:
            continue

        # 4. 处理HTTP/HTTPS URL中的IP
        if line.startswith('http://') or line.startswith('https://'):
            # 提取主机部分
            try:
                parsed = urlparse(line)
                host = parsed.netloc
                # 处理IPv6地址（在方括号中）
                if host.startswith('[') and ']' in host:
                    ip_end = host.index(']')
                    ip_candidate = host[1:ip_end]
                    try:
                        addr = IPv6Address(ip_candidate)
                        ip_list.append(str(addr))
                        added = True
                    except (ValueError, AddressValueError):
                        pass
                else:
                    # 处理IPv4地址或域名
                    host_parts = host.split(':')
                    ip_candidate = host_parts[0]
                    try:
                        addr = IPv4Address(ip_candidate)
                        ip_list.append(str(addr))
                        added = True
                    except (ValueError, AddressValueError):
                        pass
            except Exception:
                pass

        if added:
            continue

        # 5. 使用正则表达式匹配非纯IP行中的IP，但避免误匹配域名中的IP
        # IPv4匹配（带端口等）- 基于c.py的改进版本
        ipv4_with_context = re.search(
            r'\b((?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?))\b',
            line
        )
        if ipv4_with_context:
            ip_candidate = ipv4_with_context.group(1)
            try:
                IPv4Address(ip_candidate)
                # 检查上下文，避免误匹配（如C91.196.152.28）
                start_pos = ipv4_with_context.start()
                end_pos = ipv4_with_context.end()
                # 检查前后字符，确保不是域名的一部分
                prev_char = line[start_pos - 1] if start_pos > 0 else ''
                next_char = line[end_pos] if end_pos < len(line) else ''
                # 如果IP前后是字母数字（非分隔符），则可能是域名的一部分
                if (prev_char and prev_char.isalnum() and not prev_char.isdigit()) or \
                   (next_char and next_char.isalnum() and not next_char.isdigit()):
                    pass  # 可能是域名，跳过
                else:
                    # 进一步检查：确保IP位于行首或特定分隔符之后
                    if start_pos == 0 or line[start_pos - 1] in ['/', ':', ' ']:
                        ip_list.append(ip_candidate)
                        added = True
            except (ValueError, AddressValueError):
                pass

        if added:
            continue

        # IPv6匹配 - 基于c.py的改进版本
        ipv6_with_context = re.search(ipv6_pattern, line, re.IGNORECASE)
        if ipv6_with_context:
            ip_candidate = ipv6_with_context.group(0)
            try:
                IPv6Address(ip_candidate)
                # 类似上下文检查
                start_pos = ipv6_with_context.start()
                end_pos = ipv6_with_context.end()
                prev_char = line[start_pos - 1] if start_pos > 0 else ''
                next_char = line[end_pos] if end_pos < len(line) else ''
                if (prev_char and prev_char.isalnum()) or (next_char and next_char.isalnum()):
                    pass
                else:
                    # 进一步检查：确保IP位于行首或特定分隔符之后
                    if start_pos == 0 or line[start_pos - 1] in ['/', ':', ' ']:
                        ip_list.append(ip_candidate)
                        added = True
            except (ValueError, AddressValueError):
                pass

        if not added:
            domain_list.append(original_line)

    return ip_list, domain_list

def process_g(temp_dir: Path) -> Tuple[List[str], List[str], List[str]]:
    """处理g组（maltrail仓库）"""
    url = GROUPS['g'][0]
    zip_path = temp_dir / "maltrail.zip"
    if not download_file(url, zip_path):
        return [], [], []
    extract_dir = temp_dir / "maltrail_extract"
    if not extract_zip(zip_path, extract_dir):
        return [], [], []
    master_dir = next(extract_dir.glob("maltrail-master"), None)
    if not master_dir:
        logging.warning("Could not find maltrail-master directory")
        return [], [], []
    # 收集所有需要处理的文件
    mixed_lines = []
    files_to_process = [
        master_dir / "misc/worst_asns.txt",
        master_dir / "trails/custom/dprk.txt"
    ]
    static_trails_dir = master_dir / "trails/static"
    if static_trails_dir.is_dir():
        for path in static_trails_dir.rglob("*"):
            if path.is_file() and path.name != "__init__.py":
                files_to_process.append(path)
    # 读取所有文件内容
    for path in files_to_process:
        if path.exists():
            enc = detect_encoding(path)
            try:
                with open(path, 'r', encoding=enc, errors='ignore') as f:
                    mixed_lines.extend(f.readlines())
            except Exception as e:
                logging.warning(f"Failed to read {path}: {e}")
    # 使用专门的maltrail处理函数
    cleaned_mixed = clean_lines(mixed_lines)
    temp9, non_ip_from_maltrail = extract_maltrail_ips_domains(cleaned_mixed)
    temp9 = clean_lines(temp9)
    # 更新customBL.txt
    custom_bl_path = Path("adh/backup/customBL.txt")
    custom_bl_path.parent.mkdir(parents=True, exist_ok=True)
    existing_non_ip = []
    if custom_bl_path.exists():
        enc = detect_encoding(custom_bl_path)
        try:
            with open(custom_bl_path, 'r', encoding=enc, errors='ignore') as f:
                existing_non_ip = clean_lines(f.readlines())
        except Exception as e:
            logging.warning(f"Failed to read customBL: {e}")
    updated_non_ip = sorted(set(non_ip_from_maltrail + existing_non_ip))
    try:
        with open(custom_bl_path, 'w', encoding='utf-8') as f:
            f.write('\n'.join(updated_non_ip) + '\n')
        logging.info(f"Updated custom blocklist with {len(updated_non_ip)} entries")
    except Exception as e:
        logging.error(f"Failed to write customBL: {e}")
    # 处理whitelist.txt
    temp10 = []
    whitelist_path = master_dir / "misc/whitelist.txt"
    if whitelist_path.exists():
        enc = detect_encoding(whitelist_path)
        try:
            with open(whitelist_path, 'r', encoding=enc, errors='ignore') as f:
                lines = f.readlines()
            # 找到corp之后开始处理
            start_index = -1
            for i, line in enumerate(lines):
                if "corp" in line.lower():
                    start_index = i + 1
                    break
            if start_index != -1:
                for line in lines[start_index:]:
                    cleaned = enhanced_universal_clean(line)
                    if cleaned and not cleaned.startswith('#'):
                        # 移除www.前缀
                        domain = cleaned.lstrip('www.')
                        if domain:
                            temp10.append(domain)
                temp10 = clean_lines(temp10)
        except Exception as e:
            logging.warning(f"Failed to process maltrail whitelist: {e}")
    # 处理domain-blocklist.txt中的@@规则
    temp11 = []
    domain_block_path = Path("adh/domain-blocklist.txt")
    if domain_block_path.exists():
        enc = detect_encoding(domain_block_path)
        try:
            with open(domain_block_path, 'r', encoding=enc, errors='ignore') as f:
                for line in f:
                    line_clean = line.strip()
                    if line_clean.startswith('@@'):
                        # 移除@@前缀
                        domain = re.sub(r'^@@(?:\|\||://|\|)?', '', line_clean)
                        # 移除后缀
                        domain = re.sub(r'[\|\^/].*$', '', domain)
                        # 移除www.前缀
                        domain = domain.lstrip('www.')
                        if domain:
                            temp11.append(domain)
            temp11 = clean_lines(temp11)
        except Exception as e:
            logging.warning(f"Failed to process domain blocklist: {e}")
    return temp9, temp10, temp11

def process_h(urls: List[str], temp_dir: Path) -> List[str]:
    """处理h组（白名单）"""
    return process_group(GROUPS['h'], 'h', temp_dir)

def consolidate_networks(ip_list: List[str]) -> List[str]:
    """合并和优化网络列表"""
    networks = set()
    invalid_count = 0
    for ip_str in ip_list:
        # 移除IPv6 Zone ID
        ip_str = ip_str.split('%')[0]
        try:
            if '/' in ip_str:
                net = ipaddress.ip_network(ip_str, strict=False)
            else:
                addr = ipaddress.ip_address(ip_str)
                net = ipaddress.ip_network(f"{addr}/{addr.max_prefixlen}")
            # 排除全范围网络
            if net.prefixlen > 0:
                networks.add(net)
        except ValueError:
            invalid_count += 1
    if invalid_count > 0:
        logging.info(f"Skipped {invalid_count} invalid IP/CIDR entries")
    if not networks:
        return []
    # 分离v4和v6,合并相邻网络
    ipv4_nets = [n for n in networks if n.version == 4]
    ipv6_nets = [n for n in networks if n.version == 6]
    ipv4_nets.sort(key=lambda n: int(n.network_address))
    ipv6_nets.sort(key=lambda n: int(n.network_address))
    collapsed_v4 = list(ipaddress.collapse_addresses(ipv4_nets))
    collapsed_v6 = list(ipaddress.collapse_addresses(ipv6_nets))
    # 格式化输出
    result = []
    for net in collapsed_v4:
        result.append(str(net.network_address) if net.prefixlen == 32 else str(net))
    for net in collapsed_v6:
        result.append(str(net.network_address) if net.prefixlen == 128 else str(net))
    result.sort(key=lambda x: ipaddress.ip_network(x).network_address.packed)
    return result

def update_whitelist_with_h(temp10: List[str], temp11: List[str], h_whitelist: List[str]) -> None:
    """更新白名单，包含h组内容"""
    whitelist_path = Path("adh/backup/whitelist.txt")
    whitelist_path.parent.mkdir(parents=True, exist_ok=True)
    # 合并所有白名单源
    new_items = set(temp10 + temp11 + h_whitelist)
    skip_lines = []
    existing_items = set()
    # 读取现有白名单
    if whitelist_path.exists():
        enc = detect_encoding(whitelist_path)
        try:
            with open(whitelist_path, 'r', encoding=enc, errors='ignore') as f:
                lines = f.readlines()
            # 查找并保留跳过区域
            start_idx = -1
            end_idx = -1
            for i, line in enumerate(lines):
                if '# skip start' in line.lower():
                    start_idx = i
                elif '# skip end' in line.lower():
                    end_idx = i
                    break
            if start_idx != -1 and end_idx != -1 and start_idx < end_idx:
                skip_lines = lines[start_idx:end_idx + 1]
                # 获取跳过区域外的项目
                other_lines = lines[:start_idx] + lines[end_idx + 1:]
                existing_items = set(clean_lines(other_lines))
            else:
                existing_items = set(clean_lines(lines))
        except Exception as e:
            logging.warning(f"Failed to read whitelist: {e}")
    # 合并所有项目
    all_items = list(new_items | existing_items)
    all_items.sort()
    ipv4_items = []
    ipv6_items = []
    domain_items = []
    for item in all_items:
        try:
            # 尝试解析为IP地址
            ip = ipaddress.ip_address(item)
            if ip.version == 4:
                ipv4_items.append(item)
            else:
                ipv6_items.append(item)
        except ValueError:
            try:
                # 尝试解析为网络
                net = ipaddress.ip_network(item, strict=False)
                if net.prefixlen > 0:
                    if net.version == 4:
                        ipv4_items.append(str(net))
                    else:
                        ipv6_items.append(str(net))
            except ValueError:
                # 作为域名处理
                if item:
                    domain_items.append(item)
    # 写入更新后的白名单
    try:
        with open(whitelist_path, 'w', encoding='utf-8') as f:
            # 保留跳过区域
            if skip_lines:
                f.writelines(skip_lines)
                f.write('\n')
            # 写入IPv4项目
            if ipv4_items:
                f.write('# ipv4\n')
                f.write('\n'.join(sorted(ipv4_items, key=lambda x: ipaddress.ip_network(x, strict=False).network_address)) + '\n\n')
            # 写入IPv6项目
            if ipv6_items:
                f.write('# ipv6\n')
                f.write('\n'.join(sorted(ipv6_items, key=lambda x: ipaddress.ip_network(x, strict=False).network_address)) + '\n\n')
            # 写入域名项目
            if domain_items:
                f.write('# domain\n')
                f.write('\n'.join(sorted(domain_items)) + '\n')
        logging.info(f"Updated whitelist with {len(ipv4_items)} IPv4, {len(ipv6_items)} IPv6, {len(domain_items)} domains")
    except Exception as e:
        logging.error(f"Failed to write whitelist: {e}")

def process_part1(whitelist_path: str, exclusions_ip_path: str):
    path = Path(whitelist_path)
    if not path.exists():
        logging.warning(f"{whitelist_path} does not exist")
        return
    enc = detect_encoding(path)
    with open(path, 'r', encoding=enc, errors='ignore') as f:
        lines = f.readlines()
    cleaned = clean_lines(lines)
    ip_lines = []
    for line in cleaned:
        try:
            net = ipaddress.ip_network(line, strict=False)
            if net.prefixlen > 0:
                ip_lines.append(line)
        except ValueError:
            pass
    excl_path = Path(exclusions_ip_path)
    existing_excl_ip = []
    if excl_path.exists():
        enc = detect_encoding(excl_path)
        with open(excl_path, 'r', encoding=enc, errors='ignore') as f:
            existing_lines = f.readlines()
        existing_excl_ip = clean_lines(existing_lines)
    all_excl_ip = ip_lines + existing_excl_ip
    consolidated_excl_ip = consolidate_networks(all_excl_ip)
    excl_path.parent.mkdir(parents=True, exist_ok=True)
    with open(excl_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(consolidated_excl_ip) + '\n')
    logging.info(f"Updated {exclusions_ip_path} with {len(consolidated_excl_ip)} entries")

def process_part2(whitelist_path: str, exclusions_ip_path: str, exclusions_path: str, temp_dir: Path):
    path = Path(whitelist_path)
    if not path.exists():
        logging.warning(f"{whitelist_path} does not exist")
        return
    enc = detect_encoding(path)
    with open(path, 'r', encoding=enc, errors='ignore') as f:
        lines = f.readlines()
    cleaned = clean_lines(lines)
    non_ip_lines = []
    for line in cleaned:
        try:
            net = ipaddress.ip_network(line, strict=False)
            if net.prefixlen > 0:
                continue
        except ValueError:
            non_ip_lines.append(line)
    regex_lines = [l for l in non_ip_lines if l.startswith('/')]
    domain_lines = [l.lstrip('www.') for l in non_ip_lines if not l.startswith('/')]
    formatted_domains = ['|' + d for d in domain_lines if d]
    excl_ip_path_obj = Path(exclusions_ip_path)
    excl_ip_lines = []
    if excl_ip_path_obj.exists():
        enc = detect_encoding(excl_ip_path_obj)
        with open(excl_ip_path_obj, 'r', encoding=enc, errors='ignore') as f:
            excl_ip_lines = [l.strip() for l in f if l.strip()]
    excl_path = Path(exclusions_path)
    existing_excl = []
    if excl_path.exists():
        enc = detect_encoding(excl_path)
        with open(excl_path, 'r', encoding=enc, errors='ignore') as f:
            existing_lines = f.readlines()
        existing_excl = clean_lines(existing_lines)
    all_excl = set(regex_lines + formatted_domains + excl_ip_lines + existing_excl)
    sorted_excl = sorted(all_excl)
    temp_excl = temp_dir / "exclusions_temp.txt"
    with open(temp_excl, 'w', encoding='utf-8') as f:
        f.write('\n'.join(sorted_excl) + '\n')
    with open(temp_excl, 'r', encoding='utf-8') as f:
        lines = [l.strip() for l in f if l.strip()]
    cidr_lines = []
    non_cidr_lines = []
    for line in lines:
        try:
            net = ipaddress.ip_network(line, strict=False)
            if net.prefixlen > 0:
                cidr_lines.append(str(net))
            else:
                non_cidr_lines.append(line)
        except ValueError:
            non_cidr_lines.append(line)
    consolidated_cidr = consolidate_networks(cidr_lines)
    formatted_cidr = []
    for c in consolidated_cidr:
        net = ipaddress.ip_network(c)
        if net.version == 4:
            formatted_cidr.append('|' + c)
        else:
            formatted_cidr.append(c)
    all_updated_excl = sorted(set(non_cidr_lines + formatted_cidr))
    excl_path.parent.mkdir(parents=True, exist_ok=True)
    with open(excl_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(all_updated_excl) + '\n')
    logging.info(f"Updated {exclusions_path} with {len(all_updated_excl)} entries")

def process_part3(ip_txt: str, exclusions_ip_path: str):
    ip_path = Path(ip_txt)
    if not ip_path.exists():
        logging.warning(f"{ip_txt} does not exist")
        return
    enc = detect_encoding(ip_path)
    with open(ip_path, 'r', encoding=enc, errors='ignore') as f:
        ip_lines = clean_lines(f.readlines())
    excl_ip_path_obj = Path(exclusions_ip_path)
    excl_ip_set = set()
    if excl_ip_path_obj.exists():
        enc = detect_encoding(excl_ip_path_obj)
        with open(excl_ip_path_obj, 'r', encoding=enc, errors='ignore') as f:
            excl_lines = f.readlines()
        excl_ip_set = set(clean_lines(excl_lines))
    filtered_ip = [l for l in ip_lines if l not in excl_ip_set]
    consolidated_filtered = consolidate_networks(filtered_ip)
    with open(ip_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(consolidated_filtered) + '\n')
    logging.info(f"Updated {ip_txt} with {len(consolidated_filtered)} entries")

def process_part4(proxy_urls: List[str], proxy_local: str, anonymous_proxy: str, exclusions_ip_path: str, temp_dir: Path):
    temp_proxy = process_group(proxy_urls, 'proxy', temp_dir)
    local_proxy_lines = []
    local_path = Path(proxy_local)
    if local_path.exists():
        enc = detect_encoding(local_path)
        with open(local_path, 'r', encoding=enc, errors='ignore') as f:
            local_proxy_lines = clean_lines(f.readlines())
    all_proxy = temp_proxy + local_proxy_lines
    anon_path = Path(anonymous_proxy)
    existing_anon = []
    if anon_path.exists():
        enc = detect_encoding(anon_path)
        with open(anon_path, 'r', encoding=enc, errors='ignore') as f:
            existing_anon = clean_lines(f.readlines())
    all_anon = all_proxy + existing_anon
    excl_ip_path_obj = Path(exclusions_ip_path)
    excl_ip_set = set()
    if excl_ip_path_obj.exists():
        enc = detect_encoding(excl_ip_path_obj)
        with open(excl_ip_path_obj, 'r', encoding=enc, errors='ignore') as f:
            excl_lines = f.readlines()
        excl_ip_set = set(clean_lines(excl_lines))
    filtered_anon = [l for l in all_anon if l not in excl_ip_set]
    consolidated_anon = consolidate_networks(filtered_anon)
    anon_path.parent.mkdir(parents=True, exist_ok=True)
    with open(anon_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(consolidated_anon) + '\n')
    logging.info(f"Updated {anonymous_proxy} with {len(consolidated_anon)} entries")

def main() -> None:
    """主函数"""
    try:
        # 创建目录
        adh_dir = Path('adh')
        backup_dir = adh_dir / 'backup'
        adh_dir.mkdir(parents=True, exist_ok=True)
        backup_dir.mkdir(parents=True, exist_ok=True)
        logging.info("Starting IP blocklist processing...")
        # Generate ip-blocklist.txt from diff
        a_file = 'adh/blocklist.txt'
        b_file = 'adh/domain-blocklist.txt'
        output_file = 'adh/ip-blocklist.txt'
        if Path(a_file).exists() and Path(b_file).exists():
            ip_count = diff_rules(a_file, b_file, output_file)
            logging.info(f"Generated ip-blocklist.txt with {ip_count} IP rules")
        else:
            logging.warning("Missing blocklist.txt or domain-blocklist.txt, skipping ip-blocklist generation")
        with tempfile.TemporaryDirectory() as temp_dir_str:
            temp_dir = Path(temp_dir_str)
            # 定义防火墙规则正则
            regex_map = {
                'f1': r'from\s+([0-9a-fA-F:./]+)',
                'f2': r'--src\s+([0-9a-fA-F:./]+)',
                'f3': r'\{([^}]+)\}',
                'f4': r'access-list\s+ET-all\s+deny\s+ip\s+([0-9.]+)\s+([0-9.]+)\s+any'
            }
            # 并行处理所有组
            with ThreadPoolExecutor(max_workers=10) as executor:
                # 提交所有任务
                future_to_group = {
                    executor.submit(
                        process_group,
                        GROUPS['a'] + GROUPS['b1'] + GROUPS['b2'] + GROUPS['b3'],
                        'a_b',
                        temp_dir
                    ): 'a_b',
                    executor.submit(process_c, GROUPS['c'], temp_dir): 'c',
                    executor.submit(
                        lambda: clean_lines(
                            process_d('d1', GROUPS['d1'], True, temp_dir) +
                            process_d('d2', GROUPS['d2'], False, temp_dir)
                        )
                    ): 'd',
                    executor.submit(process_e, GROUPS['e'], temp_dir): 'e',
                    executor.submit(process_f, 'f1', GROUPS['f1'], regex_map['f1'], temp_dir): 'f1',
                    executor.submit(process_f, 'f2', GROUPS['f2'], regex_map['f2'], temp_dir): 'f2',
                    executor.submit(process_f, 'f3', GROUPS['f3'], regex_map['f3'], temp_dir): 'f3',
                    executor.submit(process_f, 'f4', GROUPS['f4'], regex_map['f4'], temp_dir): 'f4',
                    executor.submit(process_g, temp_dir): 'g',
                    executor.submit(process_h, GROUPS['h'], temp_dir): 'h',
                    executor.submit(process_group, GROUPS['proxy'], 'proxy', temp_dir): 'proxy'
                }
                # 收集结果
                results = {}
                for future in as_completed(future_to_group):
                    group_name = future_to_group[future]
                    try:
                        result = future.result()
                        if group_name == 'g':
                            results[group_name] = result
                            logging.info(f"Group {group_name} processed: {len(result[0])} IPs, {len(result[1])} domains, {len(result[2])} rules")
                        else:
                            results[group_name] = result
                            logging.info(f"Group {group_name} processed: {len(result)} entries")
                    except Exception as e:
                        logging.error(f"Error processing group {group_name}: {e}")
                        results[group_name] = [] if group_name != 'g' else ([], [], [])
            # 提取各组结果
            temp1 = results.get('a_b', [])
            temp2 = results.get('c', [])
            temp3 = results.get('d', [])
            temp4 = results.get('e', [])
            temp5 = results.get('f1', [])
            temp6 = results.get('f2', [])
            temp7 = results.get('f3', [])
            temp8 = results.get('f4', [])
            temp9, temp10, temp11 = results.get('g', ([], [], []))
            h_whitelist = results.get('h', [])
            temp_proxy = results.get('proxy', [])
            logging.info(
                f"Processing complete. Found:\n"
                f"- Group a/b: {len(temp1)} entries\n"
                f"- Group c: {len(temp2)} entries\n"
                f"- Group d: {len(temp3)} entries\n"
                f"- Group e: {len(temp4)} entries\n"
                f"- Group f: {len(temp5) + len(temp6) + len(temp7) + len(temp8)} entries\n"
                f"- Group g: {len(temp9)} IPs, {len(temp10)} domains, {len(temp11)} rules\n"
                f"- Group h: {len(h_whitelist)} whitelist entries\n"
                f"- Group proxy: {len(temp_proxy)} entries"
            )
            # 合并所有IP列表（包括生成的ip-blocklist.txt）
            all_temp_ips = (
                temp1 + temp2 + temp3 + temp4 + temp5 +
                temp6 + temp7 + temp8 + temp9
            )
            # 读取生成的ip-blocklist.txt
            ip_blocklist_file = 'adh/ip-blocklist.txt'
            ip_blocklist_path = Path(ip_blocklist_file)
            generated_blocklist = []
            if ip_blocklist_path.exists():
                enc = detect_encoding(ip_blocklist_path)
                try:
                    with open(ip_blocklist_path, 'r', encoding=enc, errors='ignore') as f:
                        generated_blocklist = clean_lines(f.readlines())
                    logging.info(f"Read generated ip-blocklist: {len(generated_blocklist)} entries")
                except Exception as e:
                    logging.warning(f"Failed to read generated ip-blocklist: {e}")
            # 合并所有IP（包括生成的ip-blocklist）
            all_ips = all_temp_ips + generated_blocklist
            # 合并并优化IP列表
            consolidated_temp = consolidate_networks(all_ips)
            logging.info(f"Consolidated IPs: {len(consolidated_temp)} entries")
            # 读取并合并备份文件
            backup_ip_path = Path("adh/backup/ip.txt")
            existing_backup = []
            if backup_ip_path.exists():
                enc = detect_encoding(backup_ip_path)
                try:
                    with open(backup_ip_path, 'r', encoding=enc, errors='ignore') as f:
                        existing_backup = clean_lines(f.readlines())
                    logging.info(f"Read existing backup: {len(existing_backup)} entries")
                except Exception as e:
                    logging.warning(f"Failed to read backup ip: {e}")
            final_ip_list = consolidate_networks(consolidated_temp + existing_backup)
            # 写入最终IP列表
            try:
                with open(backup_ip_path, 'w', encoding='utf-8') as f:
                    f.write('\n'.join(final_ip_list) + '\n')
                logging.info(f"Updated main IP blocklist with {len(final_ip_list)} entries")
            except Exception as e:
                logging.error(f"Failed to write IP blocklist: {e}")
            # 更新白名单（包含h组）
            update_whitelist_with_h(temp10, temp11, h_whitelist)
            # Additional parts
            whitelist = 'adh/backup/whitelist.txt'
            exclusions_ip = 'adh/backup/exclusions-ip.txt'
            exclusions = 'adh/backup/exclusions.txt'
            ip_txt = 'adh/backup/ip.txt'
            anonymous_proxy_txt = 'adh/backup/anonymous&proxy.txt'
            proxy_local = 'adh/tmp/iblocklist-proxyip.txt'
            process_part1(whitelist, exclusions_ip)
            process_part2(whitelist, exclusions_ip, exclusions, temp_dir)
            process_part3(ip_txt, exclusions_ip)
            process_part4(GROUPS['proxy'], proxy_local, anonymous_proxy_txt, exclusions_ip, temp_dir)
        logging.info("All tasks completed successfully")
    except Exception as e:
        logging.error(f"Script execution failed: {e}")
        raise

if __name__ == "__main__":
    main()
