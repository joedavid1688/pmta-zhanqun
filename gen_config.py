#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
pmta-zhanqun - PMTA 站群配置生成器

读取 IP 列表文件（见 conf/ip_map.example.txt），为每个 IP 生成独立的
<virtual-mta>（多 IP 绑定出站），按域名生成 <domain-key>（DKIM）与
<smtp-user>，所有 vmta 加入 pmta-pool 池做轮询，mail-from 按域名路由。

用法:
    python3 gen_config.py <domains> <main_ip> <internal_ip> <password> \
        <dkim_selector> <panel_port> <use_tls> <email_prefix> \
        <ip_map_file> <template> <output> [bind_result_file|-]

domains      : 逗号分隔的域名列表，如 "a.com,b.com"（主域排第一）
main_ip      : 服务器主 IP（本身已绑定，不重复绑定，但会生成 vmta）
internal_ip  : PMTA 内部监听 IP（dummy-smtp-ip）
password     : smtp-user 密码
dkim_selector: DKIM selector
panel_port   : PMTA HTTP 面板端口，0 = 关闭
use_tls      : yes/no
email_prefix : 邮箱前缀，如 "mail"
ip_map_file  : IP 列表（参考 conf/ip_map.example.txt）
template     : conf/config 模板路径
output       : 输出 /etc/pmta/config
bind_result_file: bind_ips.sh 生成的 /etc/pmta/bind_result.txt，
                  其中的 FAILED IP 会被剔除不写进配置（传 - 跳过）
"""
import ipaddress
import re
import sys
from collections import OrderedDict

PASSWORD = ""
EMAIL_PREFIX = ""


def read_ip_map(path):
    """读取 IP 列表，返回 [(条目文本, 归属域名或None), ...]。

    每行一个 IP / CIDR 段 / 起止段，可选 "=>" 指定归属域名:
        192.168.10.0/24
        10.0.0.5-10.0.0.9
        45.77.1.0/24 => a.com
    """
    entries = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            domain = None
            if "=>" in line:
                line, domain = [p.strip() for p in line.split("=>", 1)]
            entries.append((line, domain))
    return entries


def expand_entry(text, domain_override):
    """把一行 IP 条目展开为 [(ip_str, domain), ...] 列表。

    支持 109.66.77.2-254 简写段（末位补全起 IP 前三段）。
    """
    result = []
    domain = domain_override
    try:
        if "-" in text and "/" not in text:
            start, end = text.split("-", 1)
            start = start.strip()
            end = end.strip()
            start_ip = ipaddress.ip_address(start)
            if start_ip.version != 4:
                raise ValueError("只支持 IPv4: %s" % text)
            if end.isdigit():
                # 简写段：109.66.77.2-254 → 109.66.77.2 ~ 109.66.77.254
                end_ip = ipaddress.ip_address(
                    ".".join(str(start_ip).split(".")[:3]) + "." + end)
            else:
                end_ip = ipaddress.ip_address(end)
            if end_ip.version != 4:
                raise ValueError("只支持 IPv4: %s" % text)
            cur = int(start_ip)
            while cur <= int(end_ip):
                result.append((str(ipaddress.ip_address(cur)), domain))
                cur += 1
        elif "/" in text:
            net = ipaddress.ip_network(text.strip(), strict=False)
            if net.version != 4:
                raise ValueError("只支持 IPv4: %s" % text)
            hosts = [net.network_address] if net.prefixlen >= 32 else list(net.hosts())
            for ip in hosts:
                result.append((str(ip), domain))
        else:
            ip = ipaddress.ip_address(text.strip())
            if ip.version != 4:
                raise ValueError("只支持 IPv4: %s" % text)
            result.append((str(ip), domain))
    except ValueError as e:
        print("[WARN] 跳过无效条目 '%s': %s" % (text, e), file=sys.stderr)
    return result


def vmta_name(domain, ip):
    """vmta 命名：vmta_<域名去特殊字符>_<IP去点>，如 vmta_a_com_4577108。"""
    base = re.sub(r"[^a-z0-9]+", "_", domain.lower()).strip("_")
    return "vmta_%s_%s" % (base, ip.replace(".", ""))


def vmta_group_name(domain):
    """域名对应的 vmta-group 命名：group_<域名去特殊字符>。"""
    base = re.sub(r"[^a-z0-9]+", "_", domain.lower()).strip("_")
    return "group_%s" % base


def source_name(domain):
    return "source_" + re.sub(r"[^a-z0-9]+", "_", domain.lower()).strip("_")


def build_blocks(domain_ips, selector, main_ip, dkim_dir="/etc/pmta/dkim"):
    """生成 <virtual-mta> / <virtual-mta-group> / <source> / <smtp-user> 块。

    host-name 规则（与面板 CF DNS 记录一一对应）:
        - 域名只有 1 个 IP，或 IP 为主 IP → host-name = 域名（根 A 记录覆盖）
        - 其余 → host-name = <IP去点变横杠>.<域名>（每 IP 一条 A 记录，如
          109-66-77-2.a.com），HELO/A/PTR 三点对齐

    返回 dict: vmtas / groups / pool / sources / users 文本。
    """
    vmta_lines = []
    group_lines = []
    pool_lines = []
    source_lines = []
    user_lines = []

    for domain, ips in domain_ips.items():
        if not ips:
            continue
        grp = vmta_group_name(domain)
        group_lines.append("<virtual-mta-group %s>" % grp)
        for ip in ips:
            name = vmta_name(domain, ip)
            hostname = domain if (len(ips) == 1 or ip == main_ip) else ip.replace(".", "-") + "." + domain
            group_lines.append("    virtual-mta %s" % name)
            pool_lines.append("virtual-mta %s" % name)
            vmta_lines.append("<virtual-mta %s>" % name)
            vmta_lines.append("    smtp-source-host %s %s" % (ip, hostname))
            vmta_lines.append("    host-name %s" % hostname)
            vmta_lines.append("    domain-key %s,%s,%s/%s.pem" % (selector, domain, dkim_dir, domain))
            vmta_lines.append("</virtual-mta>")
            vmta_lines.append("")
        group_lines.append("</virtual-mta-group>")
        group_lines.append("")

        src = source_name(domain)
        source_lines.append("<source %s>" % src)
        source_lines.append("    default-virtual-mta %s" % grp)
        source_lines.append("</source>")
        source_lines.append("")

        user_lines.append("<smtp-user %s@%s>" % (EMAIL_PREFIX, domain))
        user_lines.append("    password %s" % PASSWORD)
        user_lines.append("    source %s" % src)
        user_lines.append("</smtp-user>")
        user_lines.append("")

    return {
        "vmtas": "\n".join(vmta_lines),
        "groups": "\n".join(group_lines),
        "pool": "\n".join(pool_lines),
        "sources": "\n".join(source_lines),
        "users": "\n".join(user_lines),
    }


def build_pattern_list(domains):
    """mail-from 按域名路由到对应 vmta-group。

    mail-from 支持主域与任意子域（如 pmta-01.a.com），
    POSIX 基本正则：/@\([^.@]*\.\)\?a\.com$/
    """
    lines = ["<pattern-list pmta-pattern>"]
    for domain in domains:
        escaped = domain.replace(".", "\\.")
        grp = vmta_group_name(domain)
        lines.append("mail-from /@\\([^.@]*\\.\\)\\?%s$/ virtual-mta=%s" % (escaped, grp))
    lines.append("</pattern-list>")
    return "\n".join(lines)


def main():
    global PASSWORD, EMAIL_PREFIX
    if len(sys.argv) != 13:
        print(__doc__)
        sys.exit(1)
    (_, domains_arg, main_ip, internal_ip, password, selector,
     panel_port, use_tls, email_prefix, ip_map_file, template, output,
     bind_result_file) = sys.argv

    PASSWORD = password
    EMAIL_PREFIX = email_prefix

    domains = [d.strip() for d in domains_arg.split(",") if d.strip()]
    if not domains:
        print("[ERR] 至少需要 1 个域名")
        sys.exit(1)

    # 绑定结果过滤：bind_result.txt 中 FAILED 的 IP 不写进配置
    # （机房未路由到本机的 IP 出站必然失败，宁可少配不可错配）
    failed_bound = set()
    if bind_result_file and bind_result_file != "-":
        try:
            with open(bind_result_file, encoding="utf-8") as f:
                for line in f:
                    parts = line.split()
                    if len(parts) >= 2 and parts[0] == "FAILED":
                        failed_bound.add(parts[1])
        except OSError:
            pass
    if failed_bound:
        print("[WARN] %d 个 IP 绑定失败，已从配置剔除: %s" %
              (len(failed_bound), ",".join(sorted(failed_bound)[:10])), file=sys.stderr)

    # IP 收集：主 IP 固定归主域；列表中显式指定域名的按指定归属，
    # 其余 IP 按域名轮询分配。
    all_ips = OrderedDict()  # ip -> domain(或 None)
    all_ips[main_ip] = domains[0]
    entries = read_ip_map(ip_map_file)
    flat = []
    for text, override in entries:
        flat.extend(expand_entry(text, override))
    for ip, domain in flat:
        if ip == main_ip:
            continue
        if ip in failed_bound:
            continue
        if ip in all_ips:
            print("[WARN] 重复 IP %s，忽略" % ip, file=sys.stderr)
            continue
        all_ips[ip] = domain

    buckets = OrderedDict((d, []) for d in domains)
    unassigned = []
    for ip, domain in all_ips.items():
        if domain and domain in buckets:
            buckets[domain].append(ip)
        else:
            unassigned.append(ip)
    for i, ip in enumerate(unassigned):
        buckets[domains[i % len(domains)]].append(ip)

    blocks = build_blocks(buckets, selector, main_ip)

    with open(template, encoding="utf-8") as f:
        content = f.read()

    content = (content
               .replace("__BLOCKS__", "\n".join([
                   blocks["vmtas"], blocks["groups"], blocks["sources"],
                   blocks["users"], build_pattern_list(domains)]))
               .replace("__POOL_ENTRIES__", blocks["pool"])
               .replace("__HTTP_PORT__", panel_port)
               .replace("__USE_STARTTLS__", "yes" if use_tls == "yes" else "no")
               .replace("__INTERNAL_IP__", internal_ip)
               .replace("__MAIN_DOMAIN__", domains[0])
               .replace("__EMAIL_PREFIX__", email_prefix))

    with open(output, "w", encoding="utf-8") as f:
        f.write(content)
    print("[OK] 已生成 %s，共 %d 个 IP / %d 个域名" %
          (output, len(all_ips), len(buckets)))


if __name__ == "__main__":
    main()
