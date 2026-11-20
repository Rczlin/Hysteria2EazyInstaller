#!/usr/bin/env bash
#
# Hysteria 2 一键安装 / 管理 / 排查脚本（仅支持 Debian 11+）
# https://github.com/Rczlin/Hysteria2EazyInstaller
#

export LANG=en_US.UTF-8

SCRIPT_VERSION="2.0.0"
SCRIPT_RAW_URL="https://raw.githubusercontent.com/Rczlin/Hysteria2EazyInstaller/refs/heads/main/Hy2Installer.sh"

HY_DIR="${HY_DIR:-/etc/hysteria}"
HY_CONF="$HY_DIR/config.yaml"
HY_ENV="$HY_DIR/hy2.env"
HY_BIN="${HY_BIN:-/usr/local/bin/hysteria}"
HY_SERVICE="hysteria-server"
HY_UNIT="/etc/systemd/system/${HY_SERVICE}.service"
HY_USER="hysteria"
HY_HOME="/var/lib/hysteria"
HY_SYSCTL="/etc/sysctl.d/99-hysteria.conf"
HY2_CMD="/usr/bin/hy2"
CERT_PATH="$HY_DIR/cert.crt"
KEY_PATH="$HY_DIR/private.key"

MIN_HOP_INTERVAL=5
UDP_BUF_SIZE=16777216
REQUIRED_PKGS=(curl ca-certificates openssl qrencode nftables iproute2)

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

red(){    echo -e "\033[31m\033[01m$1\033[0m"; }
green(){  echo -e "\033[32m\033[01m$1\033[0m"; }
yellow(){ echo -e "\033[33m\033[01m$1\033[0m"; }

# 运行时变量（由 load_state / 交互输入填充）
port=""
firstport=""
endport=""
hop_interval=""
auth_pwd=""
hy_domain=""
insecure=1
masq_type="string"
proxysite=""
limit_bandwidth="no"
bandwidth_value=""
ufw_rule=""
ip=""

client_yaml_output=""
client_json_output=""
client_url_output=""
client_official_url_output=""
clash_line_output=""
qr_text_output=""

# ============================================================================
# 基础检查
# ============================================================================

check_root(){
    [[ $EUID -ne 0 ]] && red "注意: 请在 root 用户下运行脚本" && exit 1
}

check_os(){
    if [[ ! -r /etc/os-release ]]; then
        red "无法识别系统（缺少 /etc/os-release），本脚本仅支持 Debian 11 及以上"
        exit 1
    fi
    # shellcheck source=/dev/null
    . /etc/os-release
    if [[ ${ID:-} != "debian" ]]; then
        red "当前系统为 ${PRETTY_NAME:-未知}，本脚本仅支持 Debian 11 及以上"
        exit 1
    fi
    local major="${VERSION_ID%%.*}"
    if [[ -z $major ]]; then
        yellow "检测到 Debian testing/sid（${PRETTY_NAME:-}），继续运行但未经充分测试"
    elif (( major < 11 )); then
        red "当前为 ${PRETTY_NAME}，本脚本仅支持 Debian 11 及以上"
        exit 1
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        red "未检测到 systemd，本脚本需要 systemd 管理服务"
        exit 1
    fi
}

ensure_packages(){
    local missing=() p
    for p in "${REQUIRED_PKGS[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed"; then
            missing+=("$p")
        fi
    done
    (( ${#missing[@]} == 0 )) && return 0

    yellow "正在安装依赖：${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get update -qq; then
        red "apt-get update 失败，请检查软件源和网络"
        return 1
    fi
    if ! apt-get install -y -qq --no-install-recommends "${missing[@]}"; then
        red "依赖安装失败：${missing[*]}"
        return 1
    fi
}

# ============================================================================
# 工具函数
# ============================================================================

urlencode(){
    local string="$1" encoded="" pos c o
    for (( pos=0 ; pos<${#string} ; pos++ )); do
        c=${string:$pos:1}
        case "$c" in
            [-_.~a-zA-Z0-9] ) o="$c" ;;
            * ) printf -v o '%%%02X' "'$c" ;;
        esac
        encoded+="$o"
    done
    echo "$encoded"
}

read_input_with_default(){
    local target_var="$1" prompt="$2" default_value="$3" input_value
    read -rp "$prompt [$default_value]: " input_value
    printf -v "$target_var" '%s' "${input_value:-$default_value}"
}

confirm(){
    local answer
    read -rp "$1 [y/N]: " answer
    [[ $answer =~ ^[Yy]$ ]]
}

is_positive_integer(){ [[ $1 =~ ^[0-9]+$ ]] && (( 10#$1 > 0 )); }
is_valid_port(){ is_positive_integer "$1" && (( 10#$1 <= 65535 )); }

# 密码只允许这些字符：写入 YAML/JSON/URL/Clash 都不需要额外转义
is_valid_password(){ [[ $1 =~ ^[A-Za-z0-9._~@+=-]{8,128}$ ]]; }
is_valid_domain(){ [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]]; }
is_valid_proxysite(){ [[ $1 =~ ^[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/%-]*)?$ ]]; }

random_password(){ tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32; }

is_range_mode(){ [[ -n $firstport && -n $endport ]]; }

port_display(){
    if is_range_mode; then echo "$firstport-$endport"; else echo "$port"; fi
}

parse_port_config(){
    local input_value="${1//[[:space:]]/}"
    if [[ $input_value =~ ^([0-9]+)[-~]([0-9]+)$ ]]; then
        local s="${BASH_REMATCH[1]}" e="${BASH_REMATCH[2]}"
        is_valid_port "$s" && is_valid_port "$e" && (( 10#$e > 10#$s )) || return 1
        firstport=$((10#$s)); endport=$((10#$e)); port="$firstport"
        return 0
    elif [[ $input_value =~ ^([0-9]+)$ ]]; then
        local p="${BASH_REMATCH[1]}"
        is_valid_port "$p" || return 1
        port=$((10#$p)); firstport=""; endport=""
        return 0
    fi
    return 1
}

# 列出占用 UDP 端口（或区间）的非 hysteria 进程
udp_port_occupants(){
    local s="$1" e="${2:-$1}"
    ss -Hulpn 2>/dev/null | awk -v s="$s" -v e="$e" '
        { n = split($4, a, ":"); p = a[n] + 0
          if (p >= s && p <= e && $0 !~ /"hysteria"/) print }'
}

valid_ip(){
    [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || [[ $1 =~ ^[0-9A-Fa-f:]+$ && $1 == *:* ]]
}

realip(){
    local u r
    ip=""
    for u in https://api.ipify.org https://ip.sb https://ifconfig.me/ip; do
        r=$(curl -fs4m6 "$u" 2>/dev/null | tr -d '[:space:]')
        valid_ip "$r" && ip="$r" && return 0
    done
    for u in https://api64.ipify.org https://ip.sb https://ifconfig.me/ip; do
        r=$(curl -fs6m6 "$u" 2>/dev/null | tr -d '[:space:]')
        valid_ip "$r" && ip="$r" && return 0
    done
    return 1
}

service_active(){ systemctl is-active --quiet "$HY_SERVICE" 2>/dev/null; }

show_recent_errors(){
    echo ""
    yellow "最近的服务日志："
    journalctl -u "$HY_SERVICE" -n "${1:-20}" --no-pager 2>/dev/null | sed 's/^/  /'
    echo ""
    yellow "可运行 ${GREEN}hy2 diag${YELLOW} 进行一键排查"
}

restart_service(){
    systemctl restart "$HY_SERVICE"
    sleep 2
    if service_active; then
        green "Hysteria 2 已重启并运行中"
        return 0
    fi
    red "Hysteria 2 启动失败"
    show_recent_errors 20
    return 1
}

# ============================================================================
# 状态文件：所有配置参数存在 hy2.env，避免从 YAML 反向解析
# ============================================================================

save_state(){
    local tmp="$HY_ENV.tmp"
    mkdir -p "$HY_DIR"
    (
        umask 077
        {
            echo "# hy2 管理脚本状态文件（由脚本自动生成，请勿手动编辑）"
            printf 'port=%q\n' "$port"
            printf 'firstport=%q\n' "$firstport"
            printf 'endport=%q\n' "$endport"
            printf 'hop_interval=%q\n' "$hop_interval"
            printf 'auth_pwd=%q\n' "$auth_pwd"
            printf 'hy_domain=%q\n' "$hy_domain"
            printf 'insecure=%q\n' "$insecure"
            printf 'masq_type=%q\n' "$masq_type"
            printf 'proxysite=%q\n' "$proxysite"
            printf 'limit_bandwidth=%q\n' "$limit_bandwidth"
            printf 'bandwidth_value=%q\n' "$bandwidth_value"
            printf 'ufw_rule=%q\n' "$ufw_rule"
        } > "$tmp"
    )
    mv -f "$tmp" "$HY_ENV"
    chmod 600 "$HY_ENV"
}

# 兼容旧版脚本生成的配置：解析一次后写入 hy2.env
migrate_legacy_config(){
    local listen_value
    listen_value=$(grep -m1 "^listen:" "$HY_CONF" | awk '{print $2}')
    if [[ $listen_value =~ ^:?([0-9]+)[-~]([0-9]+)$ ]]; then
        firstport="${BASH_REMATCH[1]}"; endport="${BASH_REMATCH[2]}"; port="$firstport"
    else
        port="${listen_value##*:}"; firstport=""; endport=""
    fi
    auth_pwd=$(sed -n 's/^[[:space:]]*password:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' "$HY_CONF" | head -1)
    if grep -q "type: proxy" "$HY_CONF"; then
        masq_type="proxy"
        proxysite=$(sed -n 's#^[[:space:]]*url:[[:space:]]*https://\(.*\)$#\1#p' "$HY_CONF" | head -1 | tr -d '[:space:]')
    else
        masq_type="string"; proxysite=""
    fi
    if grep -q "^bandwidth:" "$HY_CONF"; then
        limit_bandwidth="yes"
        bandwidth_value=$(sed -n '/^bandwidth:/,/^$/s/^[[:space:]]*up:[[:space:]]*\([0-9]*\).*/\1/p' "$HY_CONF" | head -1)
    else
        limit_bandwidth="no"; bandwidth_value=""
    fi
    hy_domain=$(openssl x509 -in "$CERT_PATH" -noout -subject 2>/dev/null | sed 's/.*CN *= *//;s/,.*//')
    [[ -z $hy_domain ]] && hy_domain="www.apple.com"
    hop_interval=$(grep "^# hy2_hop_interval:" "$HY_CONF" | awk '{print $3}')
    is_positive_integer "$hop_interval" || hop_interval=25
    (( hop_interval < MIN_HOP_INTERVAL )) && hop_interval=$MIN_HOP_INTERVAL
    insecure=1
    ufw_rule=""
    save_state
    yellow "已将旧版配置迁移到 $HY_ENV"
}

load_state(){
    if [[ -f $HY_ENV ]]; then
        # shellcheck source=/dev/null
        . "$HY_ENV"
        return 0
    fi
    if [[ -f $HY_CONF ]]; then
        migrate_legacy_config
        return 0
    fi
    return 1
}

require_installed(){
    if ! load_state; then
        red "未找到配置文件，请先安装 Hysteria 2"
        return 1
    fi
}

fix_permissions(){
    local grp="root"
    id "$HY_USER" &>/dev/null && grp="$HY_USER"
    chown root:"$grp" "$HY_DIR"
    chmod 750 "$HY_DIR"
    [[ -f $HY_CONF ]]   && chown root:"$grp" "$HY_CONF"  && chmod 640 "$HY_CONF"
    [[ -f $KEY_PATH ]]  && chown root:"$grp" "$KEY_PATH" && chmod 640 "$KEY_PATH"
    [[ -f $CERT_PATH ]] && chown root:root "$CERT_PATH"  && chmod 644 "$CERT_PATH"
    [[ -f $HY_ENV ]]    && chown root:root "$HY_ENV"     && chmod 600 "$HY_ENV"
}

# ============================================================================
# 交互输入
# ============================================================================

inst_cert_input(){
    local default_domain="${hy_domain:-www.apple.com}"
    while true; do
        read_input_with_default hy_domain "请输入自签证书/SNI 域名，回车使用默认值" "$default_domain"
        is_valid_domain "$hy_domain" && break
        yellow "域名格式无效，请重新输入"
    done
    insecure=1
}

gen_cert(){
    mkdir -p "$HY_DIR"
    openssl ecparam -genkey -name prime256v1 -out "$KEY_PATH" 2>/dev/null &&
    openssl req -new -x509 -days 36500 -key "$KEY_PATH" -out "$CERT_PATH" -subj "/CN=$hy_domain" 2>/dev/null
    if [[ ! -s $CERT_PATH || ! -s $KEY_PATH ]]; then
        red "自签证书生成失败"
        return 1
    fi
    green "已生成自签证书（CN=$hy_domain）"
}

inst_port_config(){
    local default_port_config port_input occupants default_hop
    if is_range_mode; then
        default_port_config="$firstport-$endport"
    elif [[ -n $port ]]; then
        default_port_config="$port"
    else
        default_port_config="30000-40000"
    fi

    while true; do
        read_input_with_default port_input "请输入端口配置，支持 30000-40000、30000~40000 或单端口 443，回车使用默认值" "$default_port_config"
        if ! parse_port_config "$port_input"; then
            yellow "端口格式无效，请重新输入"
            continue
        fi
        if is_range_mode; then
            occupants=$(udp_port_occupants "$firstport" "$endport")
        else
            occupants=$(udp_port_occupants "$port")
        fi
        if [[ -n $occupants ]]; then
            yellow "以下 UDP 端口已被其他程序占用："
            echo "$occupants" | sed 's/^/  /'
            continue
        fi
        break
    done

    if is_range_mode; then
        default_hop="${hop_interval:-25}"
        while true; do
            read_input_with_default hop_interval "请输入端口跳跃间隔秒数（最小 ${MIN_HOP_INTERVAL}），回车使用默认值" "$default_hop"
            is_positive_integer "$hop_interval" && (( 10#$hop_interval >= MIN_HOP_INTERVAL )) && break
            yellow "跳跃间隔必须是 ≥ ${MIN_HOP_INTERVAL} 的整数"
        done
        hop_interval=$((10#$hop_interval))
        yellow "已启用 Hysteria 2 原生端口跳跃：$firstport - $endport（跳跃间隔 ${hop_interval}s）"
    else
        hop_interval="${hop_interval:-25}"
        yellow "已使用单端口模式：$port"
    fi
}

inst_pwd(){
    local default_pwd input
    default_pwd=$(random_password)
    while true; do
        read -rp "设置 Hysteria 2 密码（8-128 位，可用字母数字和 ._~@+=-），回车随机生成: " input
        if [[ -z $input ]]; then
            auth_pwd="$default_pwd"; break
        fi
        is_valid_password "$input" && auth_pwd="$input" && break
        yellow "密码不符合要求，请重新输入"
    done
    yellow "已设置 Hysteria 2 密码：$auth_pwd"
}

inst_site(){
    local input_site
    while true; do
        read -rp "请输入反代伪装站点（如 www.bing.com，回车使用默认 403 页面）: " input_site
        input_site="${input_site#http://}"
        input_site="${input_site#https://}"
        input_site="${input_site%/}"
        if [[ -z $input_site ]]; then
            masq_type="string"; proxysite=""
            green "已启用默认伪装：Nginx 403 页面"
            return
        fi
        if is_valid_proxysite "$input_site"; then
            masq_type="proxy"; proxysite="$input_site"
            green "已启用反代伪装：https://$proxysite"
            return
        fi
        yellow "站点格式无效，请重新输入"
    done
}

inst_bandwidth(){
    local bandwidth_input
    while true; do
        read -rp "请输入带宽限速数值（单位 Mbps，回车不限制）: " bandwidth_input
        if [[ -z $bandwidth_input ]]; then
            limit_bandwidth="no"; bandwidth_value=""
            yellow "不限制带宽"
            return
        fi
        if is_positive_integer "$bandwidth_input"; then
            limit_bandwidth="yes"; bandwidth_value=$((10#$bandwidth_input))
            yellow "已设置带宽限速：$bandwidth_value Mbps"
            return
        fi
        yellow "请输入正整数"
    done
}

# ============================================================================
# 配置生成
# ============================================================================

generate_config(){
    local tmp="$HY_CONF.tmp" listen_value
    mkdir -p "$HY_DIR"
    if is_range_mode; then listen_value=":${firstport}-${endport}"; else listen_value=":$port"; fi

    {
        cat << EOF
# 由 hy2 管理脚本生成，参数保存在 $HY_ENV
listen: $listen_value

tls:
  cert: $CERT_PATH
  key: $KEY_PATH

quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 33554432

auth:
  type: password
  password: "$auth_pwd"

EOF
        if [[ $limit_bandwidth == "yes" ]]; then
            cat << EOF
bandwidth:
  up: ${bandwidth_value} mbps
  down: ${bandwidth_value} mbps

EOF
        fi
        echo "masquerade:"
        if [[ $masq_type == "proxy" ]]; then
            cat << EOF
  type: proxy
  proxy:
    url: https://$proxysite
    rewriteHost: true
EOF
        else
            cat << 'EOF'
  type: string
  string:
    content: |
      <!doctype html>
      <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width,initial-scale=1" />
        <title>403 Forbidden</title>
        <style>
          body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:radial-gradient(circle at 20% 20%,#1e293b 0,#0b1220 45%,#060b16 100%);font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;color:#e5e7eb}
          .card{width:min(92vw,760px);background:rgba(15,23,42,.88);border:1px solid rgba(148,163,184,.25);border-radius:18px;padding:34px 30px;box-shadow:0 18px 50px rgba(2,6,23,.55)}
          h1{margin:0 0 14px;font-size:40px;letter-spacing:.02em}
          p{margin:0 0 10px;line-height:1.75;color:#cbd5e1}
          .tag{display:inline-block;margin-top:6px;padding:7px 12px;border-radius:999px;border:1px solid rgba(148,163,184,.35);background:#0a1222;color:#93c5fd;font:600 12px ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
          hr{margin:24px 0;border:0;border-top:1px solid rgba(148,163,184,.22)}
          .foot{color:#94a3b8;font-size:14px}
        </style>
      </head>
      <body>
        <main class="card">
          <h1>403 Forbidden</h1>
          <p>Access to this private service is denied.</p>
          <p>Please contact the system administrator if you believe this is unexpected.</p>
          <span class="tag">Request-ID: 403-NGX-PRIVATE</span>
          <hr />
          <div class="foot">nginx/1.25.5 (private gateway)</div>
        </main>
      </body>
      </html>
    headers:
      Content-Type: text/html; charset=utf-8
      Server: nginx
    statusCode: 403
EOF
        fi
    } > "$tmp"
    mv -f "$tmp" "$HY_CONF"
    save_state
    fix_permissions
}

generate_client_config(){
    local server_port_string last_ip insecure_bool transport_yaml="" transport_json="" encoded_pwd encoded_sni
    if ! realip; then
        yellow "获取公网 IP 失败，分享链接中使用 YOUR_SERVER_IP 占位"
        ip="YOUR_SERVER_IP"
    fi
    server_port_string=$(port_display)
    if [[ $ip == *:* ]]; then last_ip="[$ip]"; else last_ip="$ip"; fi
    if [[ $insecure == 1 ]]; then insecure_bool="true"; else insecure_bool="false"; fi

    if is_range_mode; then
        transport_yaml=$'\n\ntransport:\n  udp:\n    hopInterval: '"${hop_interval}s"
        transport_json=$',\n  "transport": {\n    "udp": {\n      "hopInterval": "'"${hop_interval}s"$'"\n    }\n  }'
    fi

    client_yaml_output="server: $last_ip:$server_port_string

auth: $auth_pwd

tls:
  sni: $hy_domain
  insecure: $insecure_bool

quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 33554432

fastOpen: true

socks5:
  listen: 127.0.0.1:5678${transport_yaml}"

    client_json_output="{
  \"server\": \"$last_ip:$server_port_string\",
  \"auth\": \"$auth_pwd\",
  \"tls\": {
    \"sni\": \"$hy_domain\",
    \"insecure\": $insecure_bool
  },
  \"quic\": {
    \"initStreamReceiveWindow\": 16777216,
    \"maxStreamReceiveWindow\": 16777216,
    \"initConnReceiveWindow\": 33554432,
    \"maxConnReceiveWindow\": 33554432
  },
  \"socks5\": {
    \"listen\": \"127.0.0.1:5678\"
  }${transport_json}
}"

    encoded_pwd=$(urlencode "$auth_pwd")
    encoded_sni=$(urlencode "$hy_domain")
    # 兼容链接使用纯数字端口 + mport，避免部分客户端把端口范围当作非法 URI 端口；
    # 官方链接保留 Hysteria 2 原生多端口地址格式。
    if is_range_mode; then
        client_url_output="hy2://${encoded_pwd}@${last_ip}:${port}/?mport=${server_port_string}&insecure=${insecure}&sni=${encoded_sni}#Hysteria2"
        client_official_url_output="hysteria2://${encoded_pwd}@${last_ip}:${server_port_string}/?insecure=${insecure}&sni=${encoded_sni}#Hysteria2"
        clash_line_output="- {name: \"Hysteria2\", type: hysteria2, server: \"$ip\", port: $port, ports: \"$firstport-$endport\", hop-interval: ${hop_interval}, password: \"$auth_pwd\", sni: \"$hy_domain\", skip-cert-verify: $insecure_bool, udp: true}"
    else
        client_url_output="hy2://${encoded_pwd}@${last_ip}:${port}/?insecure=${insecure}&sni=${encoded_sni}#Hysteria2"
        client_official_url_output="$client_url_output"
        clash_line_output="- {name: \"Hysteria2\", type: hysteria2, server: \"$ip\", port: $port, password: \"$auth_pwd\", sni: \"$hy_domain\", skip-cert-verify: $insecure_bool, udp: true}"
    fi

    qr_text_output=""
    command -v qrencode >/dev/null 2>&1 && qr_text_output=$(qrencode -t ANSIUTF8 "$client_url_output")
}

print_client_config(){
    yellow "Hysteria 2 客户端 YAML 配置如下"
    red "$client_yaml_output"
    yellow "Hysteria 2 客户端 JSON 配置如下"
    red "$client_json_output"
    yellow "Hysteria 2 兼容节点分享链接（推荐导入 NekoBox 等客户端）如下"
    red "$client_url_output"
    if [[ $client_official_url_output != "$client_url_output" ]]; then
        yellow "Hysteria 2 官方原生端口跳跃链接如下"
        red "$client_official_url_output"
    fi
    yellow "Clash Verge YAML 单行节点（粘贴到 proxies: 下）如下"
    red "$clash_line_output"
    if [[ -n $qr_text_output ]]; then
        yellow "NekoBox 扫码二维码（终端预览）如下"
        echo "$qr_text_output"
    fi
}

# ============================================================================
# 系统集成：二进制、服务、sysctl、ufw、hy2 命令
# ============================================================================

get_hysteria_latest_version(){
    local v
    # 先走 releases/latest 的 302 跳转，不受 GitHub API 限流影响
    v=$(curl -fsSLI -o /dev/null -w '%{url_effective}' -m 15 "https://github.com/apernet/hysteria/releases/latest" 2>/dev/null \
        | sed -n 's#.*/tag/app/\(v[^/?]*\)$#\1#p')
    if [[ -z $v ]]; then
        v=$(curl -fsSL -m 15 "https://api.github.com/repos/apernet/hysteria/releases/latest" 2>/dev/null \
            | grep -m1 '"tag_name"' | sed -E 's/.*"app\/([^"]+)".*/\1/')
    fi
    echo "$v"
}

hy_arch(){
    case "$(uname -m)" in
        i386|i686) echo "386" ;;
        x86_64|amd64) echo "amd64" ;;
        armv7|armv7l|armv6l) echo "arm" ;;
        armv8|aarch64|arm64) echo "arm64" ;;
        s390x) echo "s390x" ;;
        riscv64) echo "riscv64" ;;
        *) return 1 ;;
    esac
}

install_hysteria_binary(){
    local arch version base tmp_bin expected actual
    if ! arch=$(hy_arch); then
        red "不支持的 CPU 架构：$(uname -m)"
        return 1
    fi
    version=$(get_hysteria_latest_version)
    if [[ -z $version ]]; then
        red "获取 Hysteria 最新版本失败，请检查服务器到 GitHub 的网络"
        return 1
    fi

    base="https://github.com/apernet/hysteria/releases/download/app/${version}"
    tmp_bin=$(mktemp /tmp/hysteria.XXXXXX)
    yellow "正在下载 Hysteria 2 ${version}（linux-${arch}）"
    if ! curl -fL --progress-bar -m 300 -o "$tmp_bin" "$base/hysteria-linux-${arch}"; then
        rm -f "$tmp_bin"
        red "下载 Hysteria 2 二进制失败：$base/hysteria-linux-${arch}"
        return 1
    fi

    expected=$(curl -fsSL -m 15 "$base/hashes.txt" 2>/dev/null \
        | awk -v f="hysteria-linux-${arch}" '{ n = split($2, a, "/"); if (a[n] == f) { print $1; exit } }')
    if [[ -n $expected ]]; then
        actual=$(sha256sum "$tmp_bin" | awk '{print $1}')
        if [[ $actual != "$expected" ]]; then
            rm -f "$tmp_bin"
            red "SHA256 校验失败（期望 $expected，实际 $actual），已放弃安装"
            return 1
        fi
        green "SHA256 校验通过"
    else
        yellow "未能获取 hashes.txt，跳过 SHA256 校验"
    fi

    chmod 755 "$tmp_bin"
    if ! "$tmp_bin" version >/dev/null 2>&1; then
        rm -f "$tmp_bin"
        red "Hysteria 2 二进制无法运行，请检查架构"
        return 1
    fi
    mv -f "$tmp_bin" "$HY_BIN"
    green "已安装 Hysteria 2 ${version}"
}

install_hysteria_service(){
    if ! id "$HY_USER" &>/dev/null; then
        useradd -r -d "$HY_HOME" -m -s /usr/sbin/nologin "$HY_USER"
    fi
    rm -f /etc/systemd/system/hysteria-server@.service

    # CAP_NET_ADMIN：内置端口跳跃需要写 nftables/iptables 规则
    # CAP_NET_RAW：iptables 回退路径需要
    cat > "$HY_UNIT" << EOF
[Unit]
Description=Hysteria 2 Server Service
Documentation=https://v2.hysteria.network/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$HY_HOME
User=$HY_USER
Group=$HY_USER
Environment=HYSTERIA_LOG_LEVEL=info
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true
ExecStart=$HY_BIN server -c $HY_CONF
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

apply_sysctl(){
    cat > "$HY_SYSCTL" << EOF
# Hysteria 2 / QUIC UDP 缓冲区（由 hy2 管理脚本写入）
net.core.rmem_max = $UDP_BUF_SIZE
net.core.wmem_max = $UDP_BUF_SIZE
EOF
    if sysctl -q -p "$HY_SYSCTL" >/dev/null 2>&1; then
        green "已调优 UDP 缓冲区（rmem/wmem_max = 16MB）"
    else
        yellow "UDP 缓冲区调优未生效（容器类 VPS 常见，不影响使用）"
    fi
}

ufw_active(){ command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"; }

ufw_remove_rule(){
    if [[ -n $ufw_rule ]] && command -v ufw >/dev/null 2>&1; then
        ufw delete allow "$ufw_rule" >/dev/null 2>&1
    fi
    ufw_rule=""
}

ufw_apply_rule(){
    ufw_remove_rule
    ufw_active || return 0
    if is_range_mode; then ufw_rule="${firstport}:${endport}/udp"; else ufw_rule="${port}/udp"; fi
    if ufw allow "$ufw_rule" >/dev/null 2>&1; then
        green "已在 ufw 放行 $ufw_rule"
    else
        yellow "ufw 放行 $ufw_rule 失败，请手动检查"
        ufw_rule=""
    fi
}

install_hy2_command(){
    local src="" tmp
    if [[ -n ${BASH_SOURCE[0]:-} && -f ${BASH_SOURCE[0]} && -s ${BASH_SOURCE[0]} ]]; then
        src="${BASH_SOURCE[0]}"
    fi
    [[ $src == /dev/fd/* || $src == /proc/*/fd/* ]] && src=""
    [[ $(readlink -f "$src" 2>/dev/null) == "$(readlink -f "$HY2_CMD" 2>/dev/null)" ]] && return 0

    if [[ -n $src ]]; then
        cp -f "$src" "$HY2_CMD"
    else
        # 通过管道运行时没有本地文件，直接从仓库下载一份
        tmp=$(mktemp)
        if ! curl -fsSL -m 30 -o "$tmp" "$SCRIPT_RAW_URL" || ! bash -n "$tmp"; then
            rm -f "$tmp"
            yellow "hy2 命令注册失败（无法获取脚本），可稍后用本地脚本运行菜单 6 重新注册"
            return 1
        fi
        mv -f "$tmp" "$HY2_CMD"
    fi
    chmod 755 "$HY2_CMD"
}

# ============================================================================
# 安装 / 卸载
# ============================================================================

insthysteria(){
    check_os
    if [[ -f $HY_CONF ]]; then
        confirm "检测到已安装 Hysteria 2，重新安装会覆盖现有配置，是否继续？" || return 0
        load_state >/dev/null 2>&1    # 用现有参数作为默认值
    fi

    # 1) 先收集全部输入，中途 Ctrl+C 不会留下任何改动
    inst_cert_input
    inst_port_config
    inst_pwd
    inst_site
    inst_bandwidth

    echo ""
    green "即将安装：端口 $(port_display)，SNI $hy_domain，伪装 ${proxysite:-403 页面}，限速 ${bandwidth_value:-不限}"
    confirm "确认开始安装？" || { yellow "已取消"; return 0; }

    # 2) 再执行系统改动
    trap 'echo ""; red "安装被中断，可能留有残留，可重新运行脚本选择『卸载』清理后再装"; exit 130' INT TERM

    ensure_packages || exit 1
    install_hysteria_binary || exit 1
    install_hysteria_service
    apply_sysctl
    gen_cert || exit 1
    ufw_remove_rule_from_old_state
    ufw_apply_rule
    generate_config
    systemctl enable "$HY_SERVICE" >/dev/null 2>&1

    trap - INT TERM

    if ! restart_service; then
        red "安装已完成但服务未能启动，请根据上面的日志或 hy2 diag 排查"
        exit 1
    fi

    install_hy2_command
    generate_client_config

    green "======================================================================================"
    green "               Hysteria 2 安装完成，管理命令：${YELLOW}hy2${GREEN}"
    green "               一键排查：${YELLOW}hy2 diag${GREEN}    查看日志：${YELLOW}hy2 log${GREEN}"
    green "======================================================================================"
    print_client_config
    yellow "提示：如果是云服务器，请在控制台安全组放行 UDP $(port_display)"
}

# 重装时清理旧状态里记录的 ufw 规则
ufw_remove_rule_from_old_state(){
    local new_rule_backup="$ufw_rule"
    if [[ -f $HY_ENV ]]; then
        ufw_rule=$(bash -c ". '$HY_ENV' >/dev/null 2>&1; echo \"\$ufw_rule\"")
        ufw_remove_rule
    fi
    ufw_rule="$new_rule_backup"
}

unsthysteria(){
    confirm "确定要彻底卸载 Hysteria 2（删除配置、证书、服务和用户）？" || { yellow "已取消"; return 0; }
    load_state >/dev/null 2>&1
    systemctl stop "$HY_SERVICE" >/dev/null 2>&1
    systemctl disable "$HY_SERVICE" >/dev/null 2>&1
    ufw_remove_rule
    rm -f "$HY_UNIT" /etc/systemd/system/hysteria-server@.service \
          /lib/systemd/system/hysteria-server.service /lib/systemd/system/hysteria-server@.service
    systemctl daemon-reload
    rm -rf "$HY_BIN" "$HY_DIR" "$HY_SYSCTL"
    if id "$HY_USER" &>/dev/null; then
        userdel -r "$HY_USER" >/dev/null 2>&1 || userdel "$HY_USER" >/dev/null 2>&1
    fi
    rm -rf "$HY_HOME"
    rm -f "$HY2_CMD"
    green "Hysteria 2 已彻底卸载完成"
}

# ============================================================================
# 服务控制与配置修改
# ============================================================================

registerhy2(){
    if install_hy2_command; then green "hy2 命令已注册到 $HY2_CMD"; else red "hy2 命令注册失败"; return 1; fi
}

unregisterhy2(){
    if [[ -f $HY2_CMD ]]; then rm -f "$HY2_CMD"; green "hy2 命令已卸载"; else yellow "hy2 命令不存在，无需卸载"; fi
}

hysteriaswitch(){
    yellow "请选择你需要的操作："
    echo ""
    echo -e " ${GREEN}1.${PLAIN} 启动 Hysteria 2"
    echo -e " ${GREEN}2.${PLAIN} 关闭 Hysteria 2"
    echo -e " ${GREEN}3.${PLAIN} 重启 Hysteria 2"
    echo ""
    read -rp "请输入选项 [1-3]: " switchInput
    case $switchInput in
        1 ) systemctl enable "$HY_SERVICE" >/dev/null 2>&1; restart_service ;;
        2 ) systemctl stop "$HY_SERVICE"; systemctl disable "$HY_SERVICE" >/dev/null 2>&1; green "Hysteria 2 已停止" ;;
        3 ) restart_service ;;
        * ) return 1 ;;
    esac
}

apply_and_restart(){
    generate_config
    restart_service
}

changebandwidth(){
    require_installed || return 1
    echo ""
    green "请选择带宽限速："
    echo -e " ${GREEN}1.${PLAIN} 100 Mbps"
    echo -e " ${GREEN}2.${PLAIN} 自定义数值"
    echo -e " ${GREEN}3.${PLAIN} 不限制"
    echo ""
    read -rp "请输入选项 [1-3]: " bwChange
    case $bwChange in
        1 ) limit_bandwidth="yes"; bandwidth_value=100 ;;
        2 )
            local custBw
            while true; do
                read -rp "请输入限速数值（单位 Mbps，例如 50）: " custBw
                is_positive_integer "$custBw" && break
                yellow "请输入正整数"
            done
            limit_bandwidth="yes"; bandwidth_value=$((10#$custBw)) ;;
        3 ) limit_bandwidth="no"; bandwidth_value="" ;;
        * ) return 1 ;;
    esac
    apply_and_restart && green "带宽限速已更新：${bandwidth_value:-不限制}${bandwidth_value:+ Mbps}"
}

changeport(){
    require_installed || return 1
    inst_port_config
    ufw_apply_rule
    apply_and_restart || return 1
    green "端口配置已更新"
    showconf
}

changepasswd(){
    require_installed || return 1
    inst_pwd
    apply_and_restart || return 1
    showconf
}

change_cert(){
    require_installed || return 1
    inst_cert_input
    gen_cert || return 1
    apply_and_restart || return 1
    showconf
}

changeproxysite(){
    require_installed || return 1
    inst_site
    apply_and_restart && green "伪装形式已更新"
}

changeconf(){
    green "Hysteria 2 配置变更选择如下:"
    echo -e " ${GREEN}1.${PLAIN} 修改端口"
    echo -e " ${GREEN}2.${PLAIN} 修改密码"
    echo -e " ${GREEN}3.${PLAIN} 修改证书 SNI 域名"
    echo -e " ${GREEN}4.${PLAIN} 修改伪装形式"
    echo -e " ${GREEN}5.${PLAIN} 修改带宽限速"
    echo ""
    read -rp " 请选择操作 [1-5]：" confAnswer
    case $confAnswer in
        1 ) changeport ;;
        2 ) changepasswd ;;
        3 ) change_cert ;;
        4 ) changeproxysite ;;
        5 ) changebandwidth ;;
        * ) return 1 ;;
    esac
}

showconf(){
    require_installed || return 1
    generate_client_config
    print_client_config
}

# ============================================================================
# 故障排查
# ============================================================================

DIAG_OK=0
DIAG_WARN=0
DIAG_FAIL=0
DIAG_HINTS=()

d_title(){ echo ""; echo -e "${YELLOW}━━ $1 ━━${PLAIN}"; }
d_ok(){   echo -e "  ${GREEN}[ OK ]${PLAIN} $1"; DIAG_OK=$((DIAG_OK + 1)); }
d_warn(){ echo -e "  ${YELLOW}[WARN]${PLAIN} $1"; DIAG_WARN=$((DIAG_WARN + 1)); [[ -n ${2:-} ]] && DIAG_HINTS+=("$2"); }
d_fail(){ echo -e "  ${RED}[FAIL]${PLAIN} $1"; DIAG_FAIL=$((DIAG_FAIL + 1)); [[ -n ${2:-} ]] && DIAG_HINTS+=("$2"); }
d_info(){ echo -e "  ${PLAIN}[INFO]${PLAIN} $1"; }

mask(){ local s="$1"; (( ${#s} <= 6 )) && { echo "******"; return; }; echo "${s:0:3}******${s: -2}"; }

# 用本机 hysteria 客户端连自己，验证 鉴权 / TLS / 出站 整条链路
diag_selftest(){
    local tmpdir sport code cpid
    if [[ ! -x $HY_BIN ]] || ! service_active; then
        d_warn "服务未运行，跳过本机自连测试"
        return
    fi
    if ! ss -Hulpn "sport = :$port" 2>/dev/null | grep -q '"hysteria"'; then
        d_fail "本机自连失败：UDP $port 上没有 hysteria 在监听" "服务没在配置的端口上运行，查看下方日志"
        return
    fi
    tmpdir=$(mktemp -d)
    chmod 700 "$tmpdir"
    sport=$(( (RANDOM % 10000) + 40000 ))
    cat > "$tmpdir/client.yaml" << EOF
server: 127.0.0.1:$port
auth: "$auth_pwd"
tls:
  sni: $hy_domain
  insecure: true
socks5:
  listen: 127.0.0.1:$sport
EOF
    "$HY_BIN" client -c "$tmpdir/client.yaml" >"$tmpdir/client.log" 2>&1 &
    cpid=$!
    sleep 3
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 --socks5-hostname "127.0.0.1:$sport" \
        https://www.gstatic.com/generate_204 2>/dev/null)
    kill "$cpid" >/dev/null 2>&1
    wait "$cpid" 2>/dev/null

    if [[ $code == "204" ]]; then
        d_ok "本机自连测试通过（鉴权、TLS、服务器出站均正常）"
        DIAG_SELFTEST_OK=1
    else
        if grep -qi "auth" "$tmpdir/client.log"; then
            d_fail "本机自连失败：鉴权错误" "配置文件与 hy2.env 里的密码可能不一致，用 hy2 → 4 → 2 重新设置密码"
        elif grep -qiE "connect|timeout|refused" "$tmpdir/client.log"; then
            d_fail "本机自连失败：无法连接 127.0.0.1:$port" "服务没有在 UDP $port 上正常监听，查看下方日志"
        else
            d_fail "本机自连失败（HTTP 状态 ${code:-无}）" "服务器自身可能无法访问外网，检查 VPS 出站网络 / DNS"
        fi
        grep -iE "error|fatal|fail" "$tmpdir/client.log" | tail -3 | sed 's/^/         /'
    fi
    rm -rf "$tmpdir"
}

diagnose(){
    local v active enabled nrestarts listen_line occupants rules nft_ruleset logs pub4 pub6 ntp rmem code virt
    DIAG_OK=0; DIAG_WARN=0; DIAG_FAIL=0; DIAG_HINTS=(); DIAG_SELFTEST_OK=0

    echo -e "${GREEN}Hysteria 2 一键排查${PLAIN}   脚本版本 $SCRIPT_VERSION   $(date '+%F %T %Z')"

    # ---- 系统 ----
    d_title "系统环境"
    # shellcheck source=/dev/null
    [[ -r /etc/os-release ]] && . /etc/os-release
    if [[ ${ID:-} == "debian" ]]; then d_ok "系统：${PRETTY_NAME:-Debian}"; else d_fail "系统：${PRETTY_NAME:-未知}（仅支持 Debian）"; fi
    d_info "内核 $(uname -r)，架构 $(uname -m)"
    virt=$(systemd-detect-virt 2>/dev/null || echo none)
    if [[ $virt == "openvz" || $virt == "lxc" || $virt == "lxc-libvirt" ]]; then
        d_warn "虚拟化类型：$virt（容器环境，nftables/sysctl 可能受限）" "容器 VPS 可能无法使用内置端口跳跃，若跳跃不工作请改为单端口"
    else
        d_info "虚拟化类型：$virt"
    fi

    # ---- 安装状态 ----
    d_title "安装状态"
    if [[ -x $HY_BIN ]]; then
        v=$("$HY_BIN" version 2>/dev/null | awk '/^Version:/{print $2}')
        d_ok "Hysteria 二进制：$HY_BIN ${v:-（版本未知）}"
    else
        d_fail "未找到 Hysteria 二进制 $HY_BIN" "重新运行脚本选择『安装』"
    fi
    if [[ -f $HY_CONF ]]; then d_ok "配置文件：$HY_CONF"; else d_fail "未找到配置文件 $HY_CONF" "重新运行脚本选择『安装』"; fi
    if [[ -f $HY_UNIT ]]; then d_ok "systemd 服务文件存在"; else d_fail "未找到服务文件 $HY_UNIT" "重新运行脚本选择『安装』"; fi
    if [[ -x $HY2_CMD ]]; then d_ok "hy2 管理命令已注册"; else d_warn "hy2 管理命令未注册" "运行脚本菜单 6 注册 hy2 命令"; fi

    if ! load_state >/dev/null 2>&1; then
        d_fail "无法读取配置参数，后续检查跳过"
        diag_summary
        return
    fi
    d_info "端口 $(port_display)$(is_range_mode && echo "（端口跳跃，间隔 ${hop_interval}s）")，SNI $hy_domain，密码 $(mask "$auth_pwd")"

    # ---- 服务 ----
    d_title "服务状态"
    active=$(systemctl is-active "$HY_SERVICE" 2>/dev/null)
    enabled=$(systemctl is-enabled "$HY_SERVICE" 2>/dev/null)
    nrestarts=$(systemctl show -p NRestarts --value "$HY_SERVICE" 2>/dev/null)
    if [[ $active == "active" ]]; then
        d_ok "服务运行中（启动于 $(systemctl show -p ActiveEnterTimestamp --value "$HY_SERVICE" 2>/dev/null)）"
    else
        d_fail "服务未运行（状态：${active:-unknown}）" "查看下方日志里的报错，修复后执行 hy2 → 3 → 3 重启"
    fi
    if [[ $enabled == "enabled" ]]; then d_ok "已设置开机自启"; else d_warn "未设置开机自启（$enabled）" "执行 systemctl enable $HY_SERVICE"; fi
    if [[ -n $nrestarts && $nrestarts =~ ^[0-9]+$ ]] && (( nrestarts > 0 )); then
        d_warn "服务已自动重启 $nrestarts 次，可能在反复崩溃" "查看下方日志找崩溃原因"
    fi

    # ---- 配置与证书 ----
    d_title "配置与证书"
    if [[ -f $CERT_PATH && -f $KEY_PATH ]]; then
        if openssl x509 -in "$CERT_PATH" -noout -checkend 86400 >/dev/null 2>&1; then
            d_ok "证书有效，到期 $(openssl x509 -in "$CERT_PATH" -noout -enddate 2>/dev/null | cut -d= -f2)"
        else
            d_fail "证书已过期或无法解析" "用 hy2 → 4 → 3 重新生成证书"
        fi
        if [[ $(openssl x509 -in "$CERT_PATH" -noout -pubkey 2>/dev/null | sha256sum) == "$(openssl pkey -in "$KEY_PATH" -pubout 2>/dev/null | sha256sum)" ]]; then
            d_ok "证书与私钥匹配"
        else
            d_fail "证书与私钥不匹配" "用 hy2 → 4 → 3 重新生成证书"
        fi
    else
        d_fail "证书或私钥文件缺失" "用 hy2 → 4 → 3 重新生成证书"
    fi
    if id "$HY_USER" &>/dev/null; then
        if runuser -u "$HY_USER" -- test -r "$HY_CONF" && runuser -u "$HY_USER" -- test -r "$KEY_PATH"; then
            d_ok "服务用户 $HY_USER 可读取配置和私钥"
        else
            d_fail "服务用户 $HY_USER 无法读取配置或私钥（权限问题）" "运行任意一项『修改配置』会自动修复权限，或重新安装"
        fi
    else
        d_fail "服务用户 $HY_USER 不存在" "重新运行脚本选择『安装』"
    fi
    if [[ -f $HY_CONF ]] && (( $(stat -c '%a' "$HY_CONF") % 10 != 0 )); then
        d_warn "配置文件对所有用户可读（含明文密码）" "执行 chmod 640 $HY_CONF"
    fi
    if is_range_mode && (( hop_interval < MIN_HOP_INTERVAL )); then
        d_fail "跳跃间隔 ${hop_interval}s 小于官方下限 ${MIN_HOP_INTERVAL}s" "用 hy2 → 4 → 1 重新设置端口和跳跃间隔"
    fi

    # ---- 端口监听 ----
    d_title "端口监听"
    listen_line=$(ss -Hulpn "sport = :$port" 2>/dev/null)
    if grep -q '"hysteria"' <<< "$listen_line"; then
        d_ok "hysteria 正在监听 UDP $port"
    elif [[ -n $listen_line ]]; then
        d_fail "UDP $port 被其他程序占用：$(awk '{print $NF}' <<< "$listen_line" | head -1)" "停掉占用程序，或用 hy2 → 4 → 1 换端口"
    else
        d_fail "UDP $port 没有程序在监听" "服务没起来或启动失败，查看下方日志"
    fi
    if is_range_mode; then
        occupants=$(udp_port_occupants "$((firstport + 1))" "$endport")
        [[ -n $occupants ]] && d_warn "跳跃区间内有其他程序监听：$(awk '{print $4}' <<< "$occupants" | tr '\n' ' ')" "这些端口上的流量会被跳跃规则劫持，建议换一个区间"
    fi

    # ---- 端口跳跃 ----
    if is_range_mode; then
        d_title "端口跳跃规则"
        nft_ruleset=$(nft list ruleset 2>/dev/null)
        rules=$(grep -E "dport[^0-9]*${firstport}-${endport}|redirect to :${port}\b" <<< "$nft_ruleset")
        if [[ -z $rules ]]; then
            rules=$(iptables-save -t nat 2>/dev/null | grep -E -- "--dport ${firstport}:${endport}")
        fi
        if [[ -n $rules ]]; then
            d_ok "已找到 ${firstport}-${endport} → ${port} 的转发规则"
        elif service_active; then
            d_fail "服务在运行，但没有找到端口跳跃转发规则" "hysteria 未能写入 nftables 规则：确认已安装 nftables（apt install nftables），容器 VPS 可能不支持，必要时改为单端口"
        else
            d_warn "未找到端口跳跃规则（服务未运行，规则只在服务运行时存在）"
        fi
        command -v nft >/dev/null 2>&1 || d_fail "未安装 nft 命令" "执行 apt install -y nftables 后重启服务"
    fi

    # ---- 防火墙 ----
    d_title "防火墙"
    if ufw_active; then
        local ufw_need
        if is_range_mode; then ufw_need="${firstport}:${endport}/udp"; else ufw_need="${port}/udp"; fi
        if ufw status 2>/dev/null | grep -q "^${ufw_need}"; then
            d_ok "ufw 已放行 $ufw_need"
        else
            d_fail "ufw 已启用但没有放行 $ufw_need" "执行 ufw allow $ufw_need"
        fi
    else
        d_info "ufw 未启用"
    fi
    if nft list ruleset 2>/dev/null | grep -qE "hook input.*policy drop"; then
        d_warn "nftables 存在默认 DROP 的 input 链" "确认 nftables 规则放行了 UDP $(port_display)"
    fi
    if iptables -S INPUT 2>/dev/null | grep -q "^-P INPUT DROP"; then
        d_warn "iptables INPUT 默认策略为 DROP" "确认 iptables 放行了 UDP $(port_display)"
    fi
    d_info "云服务器（阿里云/腾讯云/AWS/GCP/Oracle 等）还需在控制台安全组放行 UDP $(port_display)，脚本无法检测"

    # ---- 网络 ----
    d_title "网络"
    pub4=$(curl -fs4m6 https://api.ipify.org 2>/dev/null)
    pub6=$(curl -fs6m6 https://api64.ipify.org 2>/dev/null)
    if valid_ip "$pub4" || valid_ip "$pub6"; then
        d_ok "公网 IP：${pub4:-无 IPv4} / ${pub6:-无 IPv6}"
    else
        d_fail "无法获取公网 IP，服务器出站网络可能有问题" "检查 VPS 网络、DNS（/etc/resolv.conf）"
    fi
    if getent hosts github.com >/dev/null 2>&1; then d_ok "DNS 解析正常"; else d_fail "DNS 解析失败（github.com）" "检查 /etc/resolv.conf"; fi
    ntp=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
    if [[ $ntp == "yes" ]]; then
        d_ok "系统时间已同步"
    else
        d_warn "系统时间未确认同步（当前 $(date '+%F %T')）" "时间偏差过大会导致 TLS 握手失败，可执行 apt install -y systemd-timesyncd"
    fi
    rmem=$(sysctl -n net.core.rmem_max 2>/dev/null)
    if [[ $rmem =~ ^[0-9]+$ ]] && (( rmem >= UDP_BUF_SIZE )); then
        d_ok "UDP 接收缓冲区 rmem_max = $rmem"
    else
        d_warn "UDP 接收缓冲区偏小（rmem_max = ${rmem:-未知}），可能影响速度" "重新安装会写入 $HY_SYSCTL，或手动 sysctl -w net.core.rmem_max=$UDP_BUF_SIZE"
    fi
    if [[ $masq_type == "proxy" ]]; then
        code=$(curl -s -o /dev/null -w '%{http_code}' -m 8 "https://$proxysite" 2>/dev/null)
        if [[ $code =~ ^[23] ]]; then
            d_ok "伪装站点 https://$proxysite 可访问（HTTP $code）"
        else
            d_warn "伪装站点 https://$proxysite 访问异常（HTTP ${code:-超时}）" "换一个可访问的伪装站点：hy2 → 4 → 4"
        fi
    fi

    # ---- 自连测试 ----
    d_title "本机自连测试"
    diag_selftest

    # ---- 日志 ----
    d_title "服务日志（最近 200 行中的 ERROR/FATAL）"
    logs=$(journalctl -u "$HY_SERVICE" -n 200 --no-pager -o cat 2>/dev/null)
    local errs
    errs=$(grep -E "[[:space:]](ERROR|FATAL)[[:space:]]|panic:" <<< "$logs" | tail -8)
    if [[ -z $errs ]]; then
        d_ok "最近日志无报错"
    else
        echo "$errs" | sed 's/^/    /'
        grep -qi "address already in use" <<< "$errs" && d_fail "日志：端口已被占用" "停掉占用 UDP $port 的程序，或换端口"
        grep -qiE "permission denied|operation not permitted" <<< "$errs" && d_fail "日志：权限不足" "检查证书/配置权限，容器 VPS 可能不允许写防火墙规则"
        grep -qiE "no such file|failed to load" <<< "$errs" && d_fail "日志：文件缺失或加载失败" "证书或配置文件路径有误，重新生成证书或重装"
        grep -qiE "nft|iptables" <<< "$errs" && d_fail "日志：端口跳跃防火墙规则设置失败" "确认已安装 nftables，容器 VPS 请改用单端口"
        grep -qiE "yaml|unmarshal|invalid config" <<< "$errs" && d_fail "日志：配置文件格式错误" "用任意『修改配置』项重写配置，或重装"
    fi

    diag_summary
}

diag_summary(){
    d_title "结论"
    echo -e "  ${GREEN}通过 $DIAG_OK${PLAIN}   ${YELLOW}警告 $DIAG_WARN${PLAIN}   ${RED}失败 $DIAG_FAIL${PLAIN}"
    if (( DIAG_FAIL == 0 && DIAG_SELFTEST_OK == 1 )); then
        echo ""
        green "  服务端工作正常。客户端仍连不上时，问题通常在服务器之外："
        echo "    1. 云服务器安全组 / 面板防火墙没有放行 UDP $(port_display)"
        echo "    2. 本地网络或运营商限制 UDP / QoS（可试试端口跳跃、换端口或开启限速）"
        echo "    3. 客户端配置与服务端不一致（hy2 → 5 重新导入链接）"
    fi
    if (( ${#DIAG_HINTS[@]} > 0 )); then
        echo ""
        yellow "  建议处理："
        printf '%s\n' "${DIAG_HINTS[@]}" | awk '!seen[$0]++ { print "    - " $0 }'
    fi
}

diag_with_report(){
    local report tmp
    report="/root/hy2-diag-$(date +%Y%m%d-%H%M%S).txt"
    tmp=$(mktemp)
    diagnose 2>&1 | tee "$tmp"
    load_state >/dev/null 2>&1
    sed -e 's/\x1b\[[0-9;]*m//g' "$tmp" > "$report"
    {
        echo ""
        echo "===== journalctl -u $HY_SERVICE -n 80 ====="
        journalctl -u "$HY_SERVICE" -n 80 --no-pager 2>/dev/null
    } >> "$report"
    if [[ -n $auth_pwd ]]; then
        local esc
        esc=$(printf '%s' "$auth_pwd" | sed 's/[][\.*^$/]/\\&/g')
        sed -i "s/${esc}/******/g" "$report"
    fi
    chmod 600 "$report"
    rm -f "$tmp"
    echo ""
    green "排查报告已保存：$report（密码已打码，可直接发给别人帮忙看）"
}

diagmenu(){
    green "故障排查："
    echo -e " ${GREEN}1.${PLAIN} 一键排查（同时生成报告）"
    echo -e " ${GREEN}2.${PLAIN} 查看最近 100 行日志"
    echo -e " ${GREEN}3.${PLAIN} 实时跟踪日志（Ctrl+C 退出）"
    echo ""
    read -rp " 请选择操作 [1-3]：" diagAnswer
    case $diagAnswer in
        1 ) diag_with_report ;;
        2 ) journalctl -u "$HY_SERVICE" -n 100 --no-pager ;;
        3 ) journalctl -u "$HY_SERVICE" -f ;;
        * ) return 1 ;;
    esac
}

# ============================================================================
# 菜单与入口
# ============================================================================

status_line(){
    if [[ ! -x $HY_BIN ]]; then
        echo -e " 状态：${YELLOW}未安装${PLAIN}"
    elif service_active; then
        echo -e " 状态：${GREEN}运行中${PLAIN}"
    else
        echo -e " 状态：${RED}未运行${PLAIN}（可选 8 排查）"
    fi
}

menu(){
    clear
    echo "#############################################################"
    echo -e "#           ${GREEN}Hysteria 2 一键安装脚本（Debian）${PLAIN} v$SCRIPT_VERSION          #"
    echo "#############################################################"
    status_line
    echo ""
    echo -e " ${GREEN}1.${PLAIN} ${GREEN}安装 Hysteria 2${PLAIN}"
    echo -e " ${RED}2.${PLAIN} ${RED}卸载 Hysteria 2${PLAIN}"
    echo " ------------------------------------------------------------"
    echo -e " 3. 关闭、开启、重启 Hysteria 2"
    echo -e " 4. 修改 Hysteria 2 配置"
    echo -e " 5. 显示 Hysteria 2 客户端配置"
    echo -e " 6. 单独注册 hy2 命令（强制覆盖）"
    echo -e " 7. 单独卸载 hy2 命令"
    echo -e " ${YELLOW}8. 故障排查 / 查看日志${PLAIN}"
    echo " ------------------------------------------------------------"
    echo -e " 0. 退出脚本"
    echo ""
    read -rp "请输入选项 [0-8]: " menuInput
    case $menuInput in
        1 ) insthysteria ;;
        2 ) unsthysteria ;;
        3 ) hysteriaswitch ;;
        4 ) changeconf ;;
        5 ) showconf ;;
        6 ) registerhy2 ;;
        7 ) unregisterhy2 ;;
        8 ) diagmenu ;;
        0 ) exit 0 ;;
        * ) exit 1 ;;
    esac
}

usage(){
    cat << EOF
用法：hy2 [命令]
  (无参数)   打开管理菜单
  diag       一键排查并生成报告
  log        实时跟踪服务日志
  status     查看服务状态
  restart    重启服务
  show       显示客户端配置 / 分享链接
EOF
}

main(){
    check_root
    case "${1:-}" in
        "" )        check_os; menu ;;
        diag )      diag_with_report ;;
        log|logs )  journalctl -u "$HY_SERVICE" -f ;;
        status )    systemctl status "$HY_SERVICE" --no-pager ;;
        restart )   restart_service ;;
        show )      showconf ;;
        -h|--help|help ) usage ;;
        * )         usage; exit 1 ;;
    esac
}

if [[ -z ${BASH_SOURCE[0]:-} || ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
