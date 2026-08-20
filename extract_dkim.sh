#!/bin/bash
# ============================================================
# extract_dkim.sh - 提取 PMTA 站群所有域名的 DKIM DNS 记录
#
# 用法:
#   bash extract_dkim.sh            # 输出所有域名
#   bash extract_dkim.sh a.com      # 只输出指定域名
#
# 输出格式（每域名两行）:
#   # domain=a.com selector=default
#   v=DKIM1; k=rsa; p=...
# ============================================================

TARGET="${1:-}"

# 从 /etc/pmta/config 的 domain-key 行提取 selector,domain,pem 路径
# 形如: domain-key default,a.com,/etc/pmta/dkim/a.com.pem
grep -o 'domain-key [^ ]*' /etc/pmta/config 2>/dev/null | awk '{print $2}' \
  | sort -u | while IFS=, read -r selector domain pem; do
    [ -n "$domain" ] || continue
    [ -n "$TARGET" ] && [ "$domain" != "$TARGET" ] && continue

    DKIM_FILE="/etc/pmta/dkim/${domain}-dkim.txt"
    if [ ! -f "$DKIM_FILE" ]; then
      echo "DKIM file not found: $DKIM_FILE" >&2
      continue
    fi

    full_value=$(sed -n 's/.*"\([^"]*\)".*/\1/p' "$DKIM_FILE" | tr -d ' \t\n\r')
    dkim_p=$(echo "$full_value" | sed 's/.*p=//g')

    if [ -n "$dkim_p" ]; then
      echo "# domain=$domain selector=$selector"
      echo "v=DKIM1; k=rsa; p=$dkim_p"
    else
      echo "No valid DKIM record found in $DKIM_FILE" >&2
    fi
done
