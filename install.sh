#!/bin/bash
# ============================================================
# install.sh - PMTA 站群版一键安装（Debian/Ubuntu，多 IP / 多域名）
#
# 用法:
#   bash install.sh <domains> <main_ip> <password> <dkim_selector> \
#                   <panel_port|0> <tls:yes|no> <email_prefix> [ip_map_file]
#
#   domains       : 逗号分隔域名，如 "a.com,b.com"（主域排第一）
#   main_ip       : 服务器主 IP（已绑定的外网 IP）
#   password      : smtp-user 密码
#   dkim_selector : DKIM selector（如 default）
#   panel_port    : PMTA HTTP 面板端口，0 = 关闭
#   tls           : yes/no（自签证书 + use-starttls）
#   email_prefix  : 邮箱前缀，如 mail
#   ip_map_file   : 附加 IP 列表，默认 ./conf/ip_map.example.txt
#                   格式见 conf/ip_map.example.txt（支持 CIDR 段 / 起止段 / 指定域名）
#
# 重新生成配置（新增/删除 IP 后）:
#   bash install.sh --reconfigure [ip_map_file] [domains_override]
#
# 可选环境变量:
#   PMTA_INTERNAL_IP  内部监听 IP（dummy-smtp-ip），默认等于 main_ip
#   PMTA_ZIP_URL      自定义 PMTA 安装包下载地址
# ============================================================
set -euo pipefail

GIT_REPO="https://github.com/joedavid1688/pmta-zhanqun.git"
REPO_DIR="pmta-zhanqun"
PMTA_ZIP_URL="${PMTA_ZIP_URL:-https://github.com/uniappzy2025/youjupm/raw/refs/heads/main/pmta5.0r3.zip}"
ARGS_FILE="/etc/pmta/zhanqun.env"

export DEBIAN_FRONTEND=noninteractive

# ======================== 参数解析 ========================
RECONFIGURE=0
if [ "${1:-}" = "--reconfigure" ]; then
  RECONFIGURE=1
  shift
fi

if [ "$RECONFIGURE" = "1" ]; then
  [ -f "$ARGS_FILE" ] || { echo "[ERR] 未找到 $ARGS_FILE，请先完整安装一次"; exit 1; }
  # shellcheck disable=SC1090
  . "$ARGS_FILE"
  IP_MAP="${1:-${IP_MAP:-./conf/ip_map.example.txt}}"
  # 可选域名覆盖（站群同机新增域名时使用）
  if [ -n "${2:-}" ]; then
    DOMAINS="$2"
    MAIN_DOMAIN=$(echo "$DOMAINS" | cut -d, -f1)
    sed -i "s|^DOMAINS=.*|DOMAINS=\"$DOMAINS\"|" "$ARGS_FILE"
    sed -i "s|^MAIN_DOMAIN=.*|MAIN_DOMAIN=\"$MAIN_DOMAIN\"|" "$ARGS_FILE"
  fi
else
  if [ $# -lt 7 ]; then
    echo "用法: bash install.sh <domains> <main_ip> <password> <dkim_selector> <panel_port|0> <tls:yes|no> <email_prefix> [ip_map_file]"
    exit 1
  fi
  DOMAINS="$1"
  MAIN_IP="$2"
  PASSWORD="$3"
  DKIM_SELECTOR="$4"
  PANEL_PORT="$5"
  USE_TLS="$6"
  EMAIL_PREFIX="$7"
  IP_MAP="${8:-./conf/ip_map.example.txt}"
  MAIN_DOMAIN=$(echo "$DOMAINS" | cut -d, -f1)
  INTERNAL_IP="${PMTA_INTERNAL_IP:-$MAIN_IP}"

  mkdir -p /etc/pmta
  cat > "$ARGS_FILE" <<EOF
DOMAINS="$DOMAINS"
MAIN_IP="$MAIN_IP"
PASSWORD="$PASSWORD"
DKIM_SELECTOR="$DKIM_SELECTOR"
PANEL_PORT="$PANEL_PORT"
USE_TLS="$USE_TLS"
EMAIL_PREFIX="$EMAIL_PREFIX"
IP_MAP="$IP_MAP"
MAIN_DOMAIN="$MAIN_DOMAIN"
INTERNAL_IP="$INTERNAL_IP"
EOF
fi

CONFIG_TEMPLATE="conf/config"

# ======================== 工具函数 ========================
is_cmd() { command -v "$1" >/dev/null 2>&1; }

detect_os() {
  if [ -f /etc/debian_version ] && is_cmd apt-get; then
    echo "debian"
  elif [ -f /etc/redhat-release ] && (is_cmd yum || is_cmd dnf); then
    echo "redhat"
  else
    echo "unknown"
  fi
}

pkg_install_debian() {
  apt-get update
  apt-get install -y --no-install-recommends \
    git wget unzip opendkim opendkim-tools \
    python3 iproute2 curl ca-certificates net-tools openssl
}

pkg_install_redhat() {
  local PM=dnf
  is_cmd yum && PM=yum
  $PM -y install epel-release || true
  $PM -y install \
    git wget unzip opendkim opendkim-tools \
    python3 iproute curl ca-certificates net-tools openssl
}

systemd_try() {
  local action="$1"; shift
  if [[ "$action" == "daemon-reload" ]]; then
    systemctl daemon-reload 2>/dev/null || true
    return 0
  fi
  if [[ "$action" == "enable" ]]; then
    systemctl daemon-reload 2>/dev/null || true
  fi
  local svc alt
  for svc in "$@"; do
    alt="$svc"
    [[ "$svc" == "pmtahttp" ]] && alt="pmtahttpd"
    systemctl "$action" "$alt" 2>/dev/null || true
    if [[ "$action" == "restart" ]]; then
      if ! systemctl is-active --quiet "$alt" 2>/dev/null; then
        systemctl start "$alt" 2>/dev/null || true
      fi
    fi
  done
}

ensure_pmta_user() {
  getent group pmta >/dev/null 2>&1 || groupadd -r pmta
  id -u pmta >/dev/null 2>&1 || useradd -r -g pmta -d /etc/pmta -s /usr/sbin/nologin pmta
}

prepare_repo() {
  # 已在仓库目录内则直接使用，否则克隆
  if [ -f "./install.sh" ] && [ -f "./gen_config.py" ]; then
    REPO_DIR="."
    return 0
  fi
  rm -rf "$REPO_DIR"
  git clone "$GIT_REPO" "$REPO_DIR"
}

# ======================== 开始 ========================
OS=$(detect_os)
echo "[INFO] OS: $OS"
[ "$OS" = "unknown" ] && { echo "[ERR] Unsupported OS."; exit 1; }

mkdir -p /etc/pmta/dkim /etc/pmta/tls /var/log/pmta /var/spool/pmta
ensure_pmta_user

# ======================== 依赖 ========================
echo "[STEP] Installing dependencies"
if [ "$OS" = "debian" ]; then
  pkg_install_debian
else
  pkg_install_redhat
fi

# ======================== 准备仓库文件 ========================
prepare_repo

# ======================== 多 IP 绑定 ========================
echo "[STEP] 绑定附加 IP（$IP_MAP）"
cd "$REPO_DIR"
sed -i 's/\r$//' bind_ips.sh gen_config.py
bash bind_ips.sh "$IP_MAP" "$MAIN_IP"

# ======================== 生成 PMTA 配置 ========================
# 剔除绑定失败的 IP（bind_result.txt 中 FAILED 的行不会写进配置）
BIND_RESULT_ARGS="-"
if [ -f /etc/pmta/bind_result.txt ]; then
  BIND_RESULT_ARGS="/etc/pmta/bind_result.txt"
fi
echo "[STEP] 生成 /etc/pmta/config"
python3 gen_config.py \
  "$DOMAINS" "$MAIN_IP" "$INTERNAL_IP" "$PASSWORD" \
  "$DKIM_SELECTOR" "$PANEL_PORT" "$USE_TLS" "$EMAIL_PREFIX" \
  "$IP_MAP" "$CONFIG_TEMPLATE" /etc/pmta/config "$BIND_RESULT_ARGS"

# Panel 开关
if [ "$PANEL_PORT" = "0" ]; then
  sed -i "s|#__PANEL_TOGGLE__||g" /etc/pmta/config
  sed -i "s|^http-access|#http-access|g" /etc/pmta/config
else
  sed -i "s|#__PANEL_TOGGLE__||g" /etc/pmta/config
fi

# ======================== DKIM（每域名一把） ========================
echo "[STEP] Generating DKIM key (selector: ${DKIM_SELECTOR})"
DKIM_DIR="/etc/pmta/dkim"
pushd "$DKIM_DIR" >/dev/null
for DOMAIN in $(echo "$DOMAINS" | tr ',' ' '); do
  # 已有密钥则跳过（reconfigure 不重建，避免 DNS 记录失效）
  if [ -f "${DOMAIN}.pem" ]; then
    echo "  [SKIP] $DOMAIN (已存在)"
    continue
  fi
  rm -f "${DKIM_SELECTOR}.private" "${DKIM_SELECTOR}.txt" || true
  opendkim-genkey -s "$DKIM_SELECTOR" -d "$DOMAIN"
  mv "${DKIM_SELECTOR}.private" "${DOMAIN}.pem"
  mv "${DKIM_SELECTOR}.txt"     "${DOMAIN}-dkim.txt"
  chmod 600 "${DOMAIN}.pem"
  echo "  [OK]   $DOMAIN"
done
popd >/dev/null

# ======================== TLS（可选，主域自签证书） ========================
if [ "$USE_TLS" = "yes" ]; then
  echo "[STEP] Generating self-signed TLS certificate"
  TLS_DIR="/etc/pmta/tls"
  openssl req -new -x509 -nodes -days 3650 \
    -keyout "${TLS_DIR}/${MAIN_DOMAIN}.key" \
    -out "${TLS_DIR}/${MAIN_DOMAIN}.crt" \
    -subj "/CN=${MAIN_DOMAIN}" 2>/dev/null
  cat "${TLS_DIR}/${MAIN_DOMAIN}.crt" "${TLS_DIR}/${MAIN_DOMAIN}.key" > "${TLS_DIR}/${MAIN_DOMAIN}.pem"
  chmod 600 "${TLS_DIR}/${MAIN_DOMAIN}.key" "${TLS_DIR}/${MAIN_DOMAIN}.pem"
  echo "[OK] TLS cert: ${TLS_DIR}/${MAIN_DOMAIN}.pem"
fi

chown -R pmta:pmta /etc/pmta || true

# ======================== 安装 PMTA ========================
if ! is_cmd pmtad; then
  echo "[STEP] Downloading PMTA package"
  wget -q -O pmta5.0r3.zip "$PMTA_ZIP_URL"
  rm -rf pmta5.0r3
  unzip -q pmta5.0r3.zip

  systemd_try stop pmta pmtahttp pmtahttpd

  echo "[STEP] Installing PowerMTA"
  pushd pmta5.0r3 >/dev/null
  if [ "$OS" = "debian" ]; then
    DEB_FILE=$(ls -1 *.deb 2>/dev/null | head -n1 || true)
    if [ -n "${DEB_FILE:-}" ]; then
      apt-get install -y -o Dpkg::Options::="--force-confold" "./$DEB_FILE"
    else
      RPM_FILE=$(ls -1 *.rpm 2>/dev/null | head -n1 || true)
      if [ -n "${RPM_FILE:-}" ]; then
        apt-get install -y alien
        alien -i "$RPM_FILE"
      else
        echo "[ERR] No PowerMTA package found."; exit 1
      fi
    fi
  else
    local_pm=dnf
    is_cmd yum && local_pm=yum
    RPM_FILE=$(ls -1 *.rpm 2>/dev/null | head -n1 || true)
    [ -n "${RPM_FILE:-}" ] || { echo "[ERR] No RPM found."; exit 1; }
    $local_pm -y install "./$RPM_FILE"
  fi

  [ -f usr/sbin/pmtad ]     && cp -f usr/sbin/pmtad /usr/sbin/pmtad
  [ -f usr/sbin/pmtahttpd ] && cp -f usr/sbin/pmtahttpd /usr/sbin/pmtahttpd
  popd >/dev/null

  cp -f "pmta5.0r3/license" /etc/pmta/license 2>/dev/null || true
  chown pmta:pmta /etc/pmta/license 2>/dev/null || true
  chmod 600 /etc/pmta/license 2>/dev/null || true
  chown -R pmta:pmta /etc/pmta || true
else
  echo "[SKIP] PowerMTA 已安装"
fi

# ======================== 启动 ========================
echo "[STEP] Starting PMTA"
systemd_try daemon-reload
systemd_try enable pmta

if [ "$PANEL_PORT" != "0" ]; then
  systemd_try enable pmtahttp pmtahttpd
  systemd_try restart pmta pmtahttp pmtahttpd
else
  systemd_try restart pmta
fi

# ======================== 输出 ========================
echo "[STEP] Service status"
systemctl --no-pager --full status pmta || true
echo "[STEP] Listening ports"
is_cmd netstat && netstat -tulnp | grep -E ":25|:2525|:${PANEL_PORT:-8937}" || true

echo
echo "============================ DKIM TXT ============================"
for DOMAIN in $(echo "$DOMAINS" | tr ',' ' '); do
  echo "---- $DOMAIN ----"
  cat "${DKIM_DIR}/${DOMAIN}-dkim.txt" 2>/dev/null || true
done
echo "=================================================================="
echo "[DONE] PowerMTA 站群版安装完成。"
echo "[INFO] Config : /etc/pmta/config"
echo "[INFO] IP 列表: /etc/pmta/ip_map.txt"
echo "[INFO] 新增 IP 后重跑: bash install.sh --reconfigure /path/to/ip_map.txt"
