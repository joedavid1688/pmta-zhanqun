# pmta-zhanqun

PowerMTA 站群版一键安装脚本（Debian/Ubuntu）。

与单邮局版（[mogaipmtafajian](https://github.com/joedavid1688/mogaipmtafajian)）的区别：

- **一台服务器绑定多个 IP**：支持粘贴一个或多个 IP 段（CIDR / 起止段 / 单个 IP），自动展开、自动绑定到主网卡、自动配置开机重新绑定（systemd oneshot）
- **多域名支持**：每个域名独立 DKIM、独立 vmta-group，IP 按域名轮询分配（也可在列表里用 `=>` 指定归属域名）
- **每个 IP 一个独立 `<virtual-mta>`**，全部加入 `pmta-pool` 池轮流出站；mail-from 域名自动路由到对应域名组
- 其余逻辑（DKIM、TLS、自签证书、退信规则、backoff 规则）与单邮局版保持一致

## 快速开始

```bash
# 1. 准备 IP 列表（复制一份示例再改）
cp conf/ip_map.example.txt /root/ip_map.txt
vim /root/ip_map.txt

# 2. 安装
bash install.sh a.com,b.com <主IP> <密码> default 0 no mail /root/ip_map.txt
#                 └── 域名列表（逗号分隔，主域在前）
#                        └── 主IP └─ 密码 └DKIM └面板端口(0=关) └TLS └邮箱前缀 └IP列表

# 3. 输出末尾会打印每个域名的 DKIM TXT 记录，配置到 DNS
```

参数说明：

| 位置 | 参数 | 说明 |
|---|---|---|
| 1 | domains | 逗号分隔的域名，如 `a.com,b.com` |
| 2 | main_ip | 服务器主 IP（已绑定，脚本自动跳过） |
| 3 | password | smtp-user 密码 |
| 4 | dkim_selector | DKIM selector，如 `default` |
| 5 | panel_port | PMTA HTTP 面板端口，`0` = 关闭 |
| 6 | tls | `yes` / `no` |
| 7 | email_prefix | 邮箱前缀，如 `mail` |
| 8 | ip_map_file | IP 列表文件（可选，默认 `conf/ip_map.example.txt`） |

## IP 列表格式

```txt
45.77.10.0/24                  # CIDR 段
45.77.11.5-45.77.11.20        # 起止段
45.77.12.8                    # 单个 IP
45.77.13.0/24 => b.com        # 指定这段 IP 归 b.com
```

## 新增 / 删除 IP 后重新生成配置

```bash
bash install.sh --reconfigure /root/ip_map.txt
```

会重新绑定 IP（幂等）并重新生成 `/etc/pmta/config`，DKIM 密钥保留不动。

## 出站 IP 控制

- 默认：FCPanel 等发送端连 `127.0.0.1:2525`，不指定 vmta → PMTA 从 `pmta-pool` 轮询选 IP
- 指定 IP：发送端可带 `x-virtual-mta: vmta_<域名去特殊字符>_<IP去点>` 头强制指定出站 IP（如域名 `a.com` + IP `45.77.1.8` → `vmta_a_com_457718`），需要在 SMTP 提交时传入该头

## SMTP 凭据

- 端口：`2525`
- 用户名：`{email_prefix}@{domain}`（每个域名各一个 smtp-user）
- 密码：安装时传入的 password

## 文件说明

```
install.sh           一键安装 / --reconfigure 重新生成
bind_ips.sh          IP 批量绑定（幂等，含开机自启服务）
gen_config.py        PMTA 配置生成器（vmta / DKIM / pool / 路由规则）
extract_dkim.sh      提取 DKIM DNS 记录
conf/config          PMTA 配置模板
conf/ip_map.example.txt  IP 列表示例
```
