#!/bin/bash
# ============================================================
# bind_ips.sh - PMTA 站群 IP 批量绑定脚本（Debian/Ubuntu）
#
# 读取 IP 列表文件（见 conf/ip_map.example.txt）：
#   - 每行一个 IP / CIDR 段 / 起止段，可选 "=> domain" 指定归属域名
#   - 自动识别主网卡，逐个绑定 IP（/32 + 源路由，幂等可重复执行）
#   - 生成 systemd oneshot 服务，重启后自动重新绑定
#
# 用法:
#   bash bind_ips.sh <ip_map_file> [main_ip]
#
# 环境变量:
#   BIND_IFACE=eth0   手动指定网卡（默认自动识别）
# ============================================================
set -euo pipefail

IP_MAP="${1:?用法: bash bind_ips.sh <ip_map_file> [main_ip]}"
MAIN_IP="${2:-}"
[ -f "$IP_MAP" ] || { echo "[ERR] IP 列表文件不存在: $IP_MAP"; exit 1; }

is_cmd() { command -v "$1" >/dev/null 2>&1; }

# ---------- 依赖 ----------
if ! is_cmd python3; then
  echo "[STEP] 安装 python3（IP 段展开需要）"
  apt-get update -y
  apt-get install -y --no-install-recommends python3
fi
if ! is_cmd ip; then
  echo "[STEP] 安装 iproute2"
  apt-get install -y --no-install-recommends iproute2
fi

# ---------- 识别主网卡 ----------
if [ -n "${BIND_IFACE:-}" ]; then
  IFACE="$BIND_IFACE"
else
  IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  [ -n "$IFACE" ] || IFACE=$(ip -4 -o addr show scope global | head -1 | awk '{print $2}')
fi
[ -n "$IFACE" ] || { echo "[ERR] 无法识别主网卡，请 BIND_IFACE=eth0 手动指定"; exit 1; }
echo "[INFO] 主网卡: $IFACE"

# 主 IP 前缀长度（用于子网绑定的附加 IP）
if [ -z "$MAIN_IP" ]; then
  MAIN_IP=$(ip -4 -o addr show dev "$IFACE" scope global | head -1 | awk '{print $4}' | cut -d/ -f1)
fi
PREFIX_LEN=$(ip -4 -o addr show dev "$IFACE" scope global | grep -F " $MAIN_IP/" | head -1 | awk '{print $4}' | cut -d/ -f2)
PREFIX_LEN="${PREFIX_LEN:-24}"

# ---------- 展开 IP 列表（python3 处理 CIDR / 起止段 / 简写段） ----------
EXPAND_PY='
import sys
entries = []
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    if "=>" in line:
        line = line.split("=>", 1)[0].strip()
    try:
        import ipaddress
        if "-" in line and "/" not in line:
            s, e = line.split("-", 1)
            s = s.strip(); e = e.strip()
            a = ipaddress.ip_address(s)
            if e.isdigit():
                # 简写段：109.66.77.2-254 → 末位补全
                b = ipaddress.ip_address(".".join(str(a).split(".")[:3]) + "." + e)
            else:
                b = ipaddress.ip_address(e)
            cur = int(a)
            while cur <= int(b):
                entries.append(str(ipaddress.ip_address(cur))); cur += 1
        elif "/" in line:
            net = ipaddress.ip_network(line, strict=False)
            for ip in net.hosts() if net.prefixlen < 32 else [net.network_address]:
                entries.append(str(ip))
        else:
            entries.append(str(ipaddress.ip_address(line)))
    except ValueError as e:
        print("skip %s: %s" % (line, e), file=sys.stderr)
# 多行展开结果去重，剔除 .0/.255（单 IP 显式输入不剔除，这里统一按段处理）
seen = set()
out = []
for ip in entries:
    if ip in seen:
        continue
    seen.add(ip)
    if (ip.endswith(".0") or ip.endswith(".255")) and len(entries) > 1:
        continue
    out.append(ip)
print("\n".join(out))
'
IP_LIST=$(python3 -c "$EXPAND_PY" "$IP_MAP" | sort -u) || { echo "[ERR] IP 列表解析失败"; exit 1; }
[ -n "$IP_LIST" ] || { echo "[ERR] IP 列表为空"; exit 1; }

TOTAL=$(echo "$IP_LIST" | wc -l)
BOUND=0
SKIPPED=0
FAILED=0

echo "[STEP] 绑定 IP（网卡 $IFACE，共 $TOTAL 个）"
BIND_RESULT="/etc/pmta/bind_result.txt"
mkdir -p /etc/pmta
: > "$BIND_RESULT"
for ip in $IP_LIST; do
  # 主 IP 本身已绑定，跳过
  if [ "$ip" = "$MAIN_IP" ]; then
    echo "  [SKIP] $ip (主 IP)"
    echo "BOUND $ip" >> "$BIND_RESULT"
    SKIPPED=$((SKIPPED+1))
    continue
  fi
  if ip -4 addr show dev "$IFACE" | grep -qF " ${ip}/"; then
    echo "  [SKIP] $ip (已绑定)"
    echo "BOUND $ip" >> "$BIND_RESULT"
    SKIPPED=$((SKIPPED+1))
    continue
  fi
  # /32 绑定 + 源路由：出站包以该 IP 为源，兼容同子网与路由型附加段
  if ip addr add "${ip}/${PREFIX_LEN}" dev "$IFACE" 2>/dev/null \
     || ip addr add "${ip}/32" dev "$IFACE" 2>/dev/null; then
    ip route replace "${ip}/32" dev "$IFACE" src "$ip" 2>/dev/null || true
    echo "  [OK]   $ip"
    echo "BOUND $ip" >> "$BIND_RESULT"
    BOUND=$((BOUND+1))
  else
    echo "  [FAIL] $ip"
    echo "FAILED $ip" >> "$BIND_RESULT"
    FAILED=$((FAILED+1))
  fi
done

# ---------- 开机持久化：systemd oneshot ----------
BOOT_SCRIPT="/usr/local/bin/pmta-bind-ip.sh"
SERVICE_FILE="/etc/systemd/system/pmta-bind-ip.service"
mkdir -p /etc/pmta
cp -f "$IP_MAP" /etc/pmta/ip_map.txt
cp -f "$(readlink -f "$0")" "$BOOT_SCRIPT"
chmod 755 "$BOOT_SCRIPT"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=PMTA zhanqun multi-IP binding
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash $BOOT_SCRIPT /etc/pmta/ip_map.txt $MAIN_IP

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload 2>/dev/null || true
systemctl enable pmta-bind-ip.service 2>/dev/null || true

echo
echo "======================================================"
echo "[DONE] 绑定完成: 新增 $BOUND / 跳过 $SKIPPED / 失败 $FAILED"
echo "[INFO] IP 列表已存至 /etc/pmta/ip_map.txt"
echo "[INFO] 绑定结果明细: $BIND_RESULT（BOUND/FAILED 逐行）"
echo "[INFO] 开机自动绑定服务: pmta-bind-ip.service"
if [ "$FAILED" -gt 0 ]; then
  echo "[WARN] 有 $FAILED 个 IP 绑定失败（可能机房未路由到本机），"
  echo "[WARN] 失败 IP 不会写进 PMTA 配置，请与机房确认后重跑本脚本。"
fi
echo "======================================================"
exit 0
