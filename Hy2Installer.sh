#!/bin/bash

export LANG=en_US.UTF-8

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

red(){
    echo -e "\033[31m\033[01m$1\033[0m"
}

green(){
    echo -e "\033[32m\033[01m$1\033[0m"
}

yellow(){
    echo -e "\033[33m\033[01m$1\033[0m"
}

REGEX=("debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "amazon linux" "fedora")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Fedora")
PACKAGE_UPDATE=("apt-get update" "apt-get update" "yum -y update" "yum -y update" "yum -y update")
PACKAGE_INSTALL=("apt -y install" "apt -y install" "yum -y install" "yum -y install" "yum -y install")

[[ $EUID -ne 0 ]] && red "注意: 请在root用户下运行脚本" && exit 1

CMD=("$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)" "$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2)" "$(lsb_release -sd 2>/dev/null)" "$(grep -i description /etc/lsb-release 2>/dev/null | cut -d \" -f2)" "$(grep . /etc/redhat-release 2>/dev/null)" "$(grep . /etc/issue 2>/dev/null | cut -d \\ -f1 | sed '/^[ ]*$/d')")

SYS=""
for i in "${CMD[@]}"; do
    SYS="$i" && [[ -n $SYS ]] && break
done

SYSTEM=""
int=0
for ((int = 0; int < ${#REGEX[@]}; int++)); do
    if [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]]; then
        SYSTEM="${RELEASE[int]}"
        [[ -n $SYSTEM ]] && break
    fi
done

[[ -z $SYSTEM ]] && red "目前暂不支持你的VPS的操作系统！" && exit 1

if [[ -z $(type -P curl) ]]; then
    if [[ ! $SYSTEM == "CentOS" ]]; then
        ${PACKAGE_UPDATE[int]}
    fi
    ${PACKAGE_INSTALL[int]} curl
fi

# URL编码函数
urlencode() {
    local string="$1"
    local strlen=${#string}
    local encoded=""
    local pos c o

    for (( pos=0 ; pos<strlen ; pos++ )); do
        c=${string:$pos:1}
        case "$c" in
            [-_.~a-zA-Z0-9] ) o="$c" ;;
            * ) printf -v o '%%%02X' "'$c" ;;
        esac
        encoded+="$o"
    done
    echo "$encoded"
}

realip(){
    ip=$(curl -s4m8 ip.sb -k) || ip=$(curl -s6m8 ip.sb -k)
}

save_iptables_rules(){
    if [[ $SYSTEM == "CentOS" ]]; then
        if [[ -f /usr/libexec/iptables/iptables.init ]]; then
            service iptables save >/dev/null 2>&1
            service ip6tables save >/dev/null 2>&1
        else
            iptables-save > /etc/sysconfig/iptables 2>/dev/null
            ip6tables-save > /etc/sysconfig/ip6tables 2>/dev/null
        fi
    else
        netfilter-persistent save >/dev/null 2>&1
    fi
}

install_iptables_persistent(){
    if [[ $SYSTEM == "CentOS" ]]; then
        ${PACKAGE_INSTALL[int]} iptables-services
        systemctl enable iptables >/dev/null 2>&1
        systemctl enable ip6tables >/dev/null 2>&1
        systemctl start iptables >/dev/null 2>&1
        systemctl start ip6tables >/dev/null 2>&1
    else
        # 非交互式安装 iptables-persistent
        echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections 2>/dev/null
        echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections 2>/dev/null
        DEBIAN_FRONTEND=noninteractive ${PACKAGE_INSTALL[int]} iptables-persistent netfilter-persistent
    fi
}

fix_permissions(){
    if id "hysteria" &>/dev/null; then
        chown -R hysteria:hysteria /etc/hysteria
    fi
    chmod 755 /etc/hysteria
    if [[ -f /etc/hysteria/cert.crt ]]; then
        chmod 644 /etc/hysteria/cert.crt
    fi
    if [[ -f /etc/hysteria/private.key ]]; then
        chmod 600 /etc/hysteria/private.key
    fi
}

inst_cert(){
    mkdir -p /etc/hysteria

    green "将自动使用自签证书（www.apple.com）"

    cert_path="/etc/hysteria/cert.crt"
    key_path="/etc/hysteria/private.key"

    openssl ecparam -genkey -name prime256v1 -out /etc/hysteria/private.key
    openssl req -new -x509 -days 36500 -key /etc/hysteria/private.key -out /etc/hysteria/cert.crt -subj "/CN=www.apple.com"

    hy_domain="www.apple.com"
    domain="www.apple.com"
    insecure=1
}

inst_port_config(){
    iptables -t nat -F PREROUTING >/dev/null 2>&1
    ip6tables -t nat -F PREROUTING >/dev/null 2>&1

    firstport=30000
    endport=40000
    hop_interval=25

    port=""
    for candidate_port in $(seq $firstport $endport); do
        if [[ -z $(ss -tunlp | grep -w udp | awk '{print $5}' | sed 's/.*://g' | grep -w "$candidate_port") ]]; then
            port=$candidate_port
            break
        fi
    done

    if [[ -z $port ]]; then
        red "30000-40000 范围内未找到可用 UDP 端口，请检查端口占用后重试"
        exit 1
    fi

    iptables -t nat -A PREROUTING -p udp --dport $firstport:$endport -j DNAT --to-destination :$port
    ip6tables -t nat -A PREROUTING -p udp --dport $firstport:$endport -j DNAT --to-destination :$port

    iptables -I INPUT -p udp --dport $firstport:$endport -j ACCEPT
    ip6tables -I INPUT -p udp --dport $firstport:$endport -j ACCEPT
    save_iptables_rules

    yellow "已启用端口跳跃：$firstport - $endport (主监听端口: $port, 跳跃间隔: ${hop_interval}s)"
}

inst_pwd(){
    auth_pwd=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
    yellow "已生成 32 位随机密码：$auth_pwd"
}

inst_site(){
    masq_type="string"
    proxysite=""
    green "已启用默认伪装：Nginx 私有服务器 403 页面"
}

inst_bandwidth(){
    limit_bandwidth="no"
    bandwidth_value=""
    yellow "已默认使用：不限制带宽模式"
}

generate_config(){
    mkdir -p /etc/hysteria

    cat << EOF > /etc/hysteria/config.yaml
listen: :$port

tls:
  cert: $cert_path
  key: $key_path

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
        cat << EOF >> /etc/hysteria/config.yaml
bandwidth:
  up: ${bandwidth_value:-100} mbps
  down: ${bandwidth_value:-100} mbps

EOF
    fi

    cat << EOF >> /etc/hysteria/config.yaml
masquerade:
EOF
    if [[ $masq_type == "proxy" ]]; then
        cat << EOF >> /etc/hysteria/config.yaml
  type: proxy
  proxy:
    url: https://$proxysite
    rewriteHost: true
EOF
    else
        cat << EOF >> /etc/hysteria/config.yaml
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
}

generate_client_config(){
    realip
    
    if [[ -n $firstport && -n $endport ]]; then
        server_port_string="$port,$firstport-$endport"
    else
        server_port_string=$port
    fi

    if [[ -n $(echo $ip | grep ":") ]]; then
        last_ip="[$ip]"
    else
        last_ip=$ip
    fi

    # 根据 insecure 变量设置布尔值
    if [[ $insecure == 1 ]]; then
        insecure_bool="true"
    else
        insecure_bool="false"
    fi

    mkdir -p /root/hy
    
    # 生成 YAML 客户端配置
    cat << EOF > /root/hy/hy-client.yaml
server: $last_ip:$server_port_string

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
  listen: 127.0.0.1:5678

EOF

    # 仅在端口跳跃模式下添加 transport 配置
    if [[ -n $firstport && -n $endport ]]; then
        cat << EOF >> /root/hy/hy-client.yaml
transport:
  udp:
    hopInterval: ${hop_interval:-25}s
EOF
    fi
    
    # 生成 JSON 配置
    if [[ -n $firstport && -n $endport ]]; then
        cat << EOF > /root/hy/hy-client.json
{
  "server": "$last_ip:$server_port_string",
  "auth": "$auth_pwd",
  "tls": {
    "sni": "$hy_domain",
    "insecure": $insecure_bool
  },
  "quic": {
    "initStreamReceiveWindow": 16777216,
    "maxStreamReceiveWindow": 16777216,
    "initConnReceiveWindow": 33554432,
    "maxConnReceiveWindow": 33554432
  },
  "socks5": {
    "listen": "127.0.0.1:5678"
  },
  "transport": {
    "udp": {
      "hopInterval": "${hop_interval:-25}s"
    }
  }
}
EOF
    else
        cat << EOF > /root/hy/hy-client.json
{
  "server": "$last_ip:$server_port_string",
  "auth": "$auth_pwd",
  "tls": {
    "sni": "$hy_domain",
    "insecure": $insecure_bool
  },
  "quic": {
    "initStreamReceiveWindow": 16777216,
    "maxStreamReceiveWindow": 16777216,
    "initConnReceiveWindow": 33554432,
    "maxConnReceiveWindow": 33554432
  },
  "socks5": {
    "listen": "127.0.0.1:5678"
  }
}
EOF
    fi

    # URL编码密码
    encoded_pwd=$(urlencode "$auth_pwd")
    
    # 生成订阅链接 - 按照标准格式
    if [[ -n $firstport && -n $endport ]]; then
        # 端口跳跃模式
        url="hysteria2://${encoded_pwd}@${last_ip}:${port}?security=tls&mportHopInt=${hop_interval:-25}&insecure=${insecure}&mport=${firstport}-${endport}&sni=${hy_domain}#Hysteria2"
    else
        # 单端口模式
        url="hysteria2://${encoded_pwd}@${last_ip}:${port}?security=tls&insecure=${insecure}&sni=${hy_domain}#Hysteria2"
    fi
    
    echo "$url" > /root/hy/url.txt

    if [[ -n $firstport && -n $endport ]]; then
        cat << EOF > /root/hy/clash-verge-line.yaml
- {name: "Hysteria2", type: hysteria2, server: "$last_ip", port: $port, ports: "$firstport-$endport", hop-interval: ${hop_interval:-25}, password: "$auth_pwd", sni: "$hy_domain", skip-cert-verify: $insecure_bool, udp: true}
EOF
    else
        cat << EOF > /root/hy/clash-verge-line.yaml
- {name: "Hysteria2", type: hysteria2, server: "$last_ip", port: $port, password: "$auth_pwd", sni: "$hy_domain", skip-cert-verify: $insecure_bool, udp: true}
EOF
    fi

    if command -v qrencode >/dev/null 2>&1; then
        qrencode -t ANSIUTF8 "$url" > /root/hy/nekobox-qr.txt
    fi
}

read_current_config(){
    if [[ -f /etc/hysteria/config.yaml ]]; then
        # 更准确的端口解析
        port=$(grep "^listen:" /etc/hysteria/config.yaml | sed 's/listen://g' | sed 's/[[:space:]]//g' | sed 's/\[.*\]//g' | sed 's/://g')
        cert_path=$(grep "cert:" /etc/hysteria/config.yaml | awk '{print $2}')
        key_path=$(grep "key:" /etc/hysteria/config.yaml | awk '{print $2}')
        auth_pwd=$(grep "password:" /etc/hysteria/config.yaml | awk '{print $2}' | sed 's/"//g')
        
        if grep -q "type: proxy" /etc/hysteria/config.yaml; then
            masq_type="proxy"
            proxysite=$(grep "url:" /etc/hysteria/config.yaml | sed 's/.*https:\/\///g' | sed 's/[[:space:]]//g')
        else
            masq_type="string"
            proxysite=""
        fi
        
        if grep -q "bandwidth:" /etc/hysteria/config.yaml; then
            limit_bandwidth="yes"
            bandwidth_value=$(grep "up:" /etc/hysteria/config.yaml | head -1 | awk '{print $2}')
        else
            limit_bandwidth="no"
            bandwidth_value=""
        fi
        
        if [[ -f /root/hy/hy-client.yaml ]]; then
            hy_domain=$(grep "sni:" /root/hy/hy-client.yaml | awk '{print $2}')
            # 读取跳跃间隔
            hop_interval=$(grep "hopInterval:" /root/hy/hy-client.yaml | awk '{print $2}' | sed 's/s$//')
            # 读取 insecure 设置
            insecure_value=$(grep "insecure:" /root/hy/hy-client.yaml | awk '{print $2}')
            if [[ $insecure_value == "true" ]]; then
                insecure=1
            else
                insecure=0
            fi
        else
            hy_domain=$(openssl x509 -in "$cert_path" -noout -subject 2>/dev/null | sed 's/.*CN = //;s/,.*//' | sed 's/.*CN=//;s/,.*//')
            [[ -z $hy_domain ]] && hy_domain="www.apple.com"
            hop_interval=25
            # 如果是 apple.com 则认为是自签证书
            if [[ $hy_domain == "www.apple.com" ]]; then
                insecure=1
            else
                insecure=0
            fi
        fi
        
        # 使用兼容的方式检测端口跳跃规则
        port_hop_rule=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep "dpts:" | head -1)
        if [[ -n $port_hop_rule ]]; then
            # 提取端口范围，如 "dpts:2500:2575"
            port_range=$(echo "$port_hop_rule" | grep -o 'dpts:[0-9]*:[0-9]*' | sed 's/dpts://')
            if [[ -n $port_range ]]; then
                firstport=$(echo "$port_range" | cut -d: -f1)
                endport=$(echo "$port_range" | cut -d: -f2)
            else
                firstport=""
                endport=""
            fi
        else
            firstport=""
            endport=""
        fi
        
        return 0
    else
        return 1
    fi
}

get_hysteria_latest_version(){
    local latest_version
    latest_version=$(curl -fsSL "https://api.github.com/repos/apernet/hysteria/releases/latest" \
        | grep '"tag_name"' \
        | head -1 \
        | sed -E 's/.*"tag_name":[[:space:]]*"app\/([^"]+)".*/\1/')

    if [[ -z $latest_version ]]; then
        red "获取 Hysteria 最新版本失败，请检查网络后重试"
        exit 1
    fi

    echo "$latest_version"
}

install_hysteria_binary(){
    local machine hy_arch version bin_url tmp_bin
    machine=$(uname -m)
    case "$machine" in
        i386|i686) hy_arch="386" ;;
        x86_64|amd64) hy_arch="amd64" ;;
        armv5tel|armv6l|armv7|armv7l) hy_arch="arm" ;;
        armv8|aarch64|arm64) hy_arch="arm64" ;;
        mips|mipsle|mips64|mips64le) hy_arch="mipsle" ;;
        s390x) hy_arch="s390x" ;;
        *)
            red "不支持的 CPU 架构：$machine"
            exit 1
            ;;
    esac

    version=$(get_hysteria_latest_version)
    bin_url="https://github.com/apernet/hysteria/releases/download/app/${version}/hysteria-linux-${hy_arch}"
    tmp_bin="/tmp/hysteria-linux-${hy_arch}"

    rm -f "$tmp_bin"
    if ! curl -fsSL --connect-timeout 15 -o "$tmp_bin" "$bin_url"; then
        red "下载 Hysteria 2 二进制失败：$bin_url"
        exit 1
    fi

    chmod +x "$tmp_bin"
    mv -f "$tmp_bin" /usr/local/bin/hysteria

    if ! /usr/local/bin/hysteria version >/dev/null 2>&1; then
        red "Hysteria 2 二进制校验失败，请重试"
        exit 1
    fi

    green "已安装 Hysteria 2 版本：$version"
}

install_hysteria_service(){
    if ! id "hysteria" &>/dev/null; then
        useradd -r -d /var/lib/hysteria -m hysteria
    fi

    cat > /etc/systemd/system/hysteria-server.service << EOF
[Unit]
Description=Hysteria 2 Server Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/var/lib/hysteria
User=hysteria
Group=hysteria
Environment=HYSTERIA_LOG_LEVEL=info
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/hysteria-server@.service << EOF
[Unit]
Description=Hysteria 2 Server Service (%i.yaml)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/var/lib/hysteria
User=hysteria
Group=hysteria
Environment=HYSTERIA_LOG_LEVEL=info
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/%i.yaml
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

insthysteria(){
    warpv6=$(curl -s6m8 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
    warpv4=$(curl -s4m8 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
    if [[ $warpv4 =~ on|plus || $warpv6 =~ on|plus ]]; then
        wg-quick down wgcf >/dev/null 2>&1
        systemctl stop warp-go >/dev/null 2>&1
        realip
        systemctl start warp-go >/dev/null 2>&1
        wg-quick up wgcf >/dev/null 2>&1
    else
        realip
    fi

    if [[ ! ${SYSTEM} == "CentOS" ]]; then
        ${PACKAGE_UPDATE[int]}
    fi
    ${PACKAGE_INSTALL[int]} curl sudo qrencode procps openssl

    install_iptables_persistent

    install_hysteria_binary
    install_hysteria_service

    if [[ ! -f /usr/local/bin/hysteria ]]; then
        red "Hysteria 2 安装失败！"
        exit 1
    fi

    inst_cert
    inst_port_config
    inst_pwd
    inst_site
    inst_bandwidth
    generate_config
    generate_client_config

    fix_permissions

    systemctl daemon-reload
    systemctl enable hysteria-server
    
    echo "正在等待网络环境就绪..."
    sleep 5
    systemctl start hysteria-server
    
    if [[ ! -f /usr/bin/hy2 ]]; then
        cp -f "$0" /usr/bin/hy2
        chmod +x /usr/bin/hy2
    fi

    sleep 2
    if [[ -n $(systemctl status hysteria-server 2>/dev/null | grep -w active) && -f '/etc/hysteria/config.yaml' ]]; then
        green "Hysteria 2 服务启动成功"
    else
        red "Hysteria 2 服务启动失败，请检查日志：journalctl -u hysteria-server -e" && exit 1
    fi
    red "======================================================================================"
    green "Hysteria 2 代理服务安装完成"
    
    green "======================================================================================"
    green "               管理命令：${YELLOW}hy2${GREEN} (直接输入 hy2 即可)"
    green "        输入 ${YELLOW}hy2${GREEN} 即可再次召唤本主界面，进行配置管理"
    green "======================================================================================"
    
    yellow "Hysteria 2 客户端 YAML 配置文件 hy-client.yaml 内容如下"
    red "$(cat /root/hy/hy-client.yaml)"
    yellow "Hysteria 2 客户端 JSON 配置文件 hy-client.json 内容如下"
    red "$(cat /root/hy/hy-client.json)"
    yellow "Hysteria 2 节点分享链接如下"
    red "$(cat /root/hy/url.txt)"
    if [[ -f /root/hy/clash-verge-line.yaml ]]; then
        yellow "Clash Verge YAML 单行节点（粘贴到 proxies: 下）如下"
        red "$(cat /root/hy/clash-verge-line.yaml)"
    fi
    if [[ -f /root/hy/nekobox-qr.txt ]]; then
        yellow "NekoBox 扫码二维码（终端预览）如下"
        cat /root/hy/nekobox-qr.txt
    fi
}

unsthysteria(){
    systemctl stop hysteria-server.service >/dev/null 2>&1
    systemctl disable hysteria-server.service >/dev/null 2>&1
    rm -f /lib/systemd/system/hysteria-server.service /lib/systemd/system/hysteria-server@.service
    rm -f /etc/systemd/system/hysteria-server.service /etc/systemd/system/hysteria-server@.service
    rm -rf /usr/local/bin/hysteria /etc/hysteria /root/hy /root/hysteria.sh
    rm -f /usr/bin/hy2
    iptables -t nat -F PREROUTING >/dev/null 2>&1
    ip6tables -t nat -F PREROUTING >/dev/null 2>&1
    save_iptables_rules
    systemctl daemon-reload
    green "Hysteria 2 已彻底卸载完成！"
}

starthysteria(){
    systemctl start hysteria-server
    systemctl enable hysteria-server >/dev/null 2>&1
    if [[ -n $(systemctl status hysteria-server 2>/dev/null | grep -w active) ]]; then
        green "Hysteria 2 启动成功"
    else
        red "Hysteria 2 启动失败，请查看日志：journalctl -u hysteria-server -e"
    fi
}

stophysteria(){
    systemctl stop hysteria-server
    systemctl disable hysteria-server >/dev/null 2>&1
    green "Hysteria 2 已停止"
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
        1 ) starthysteria ;;
        2 ) stophysteria ;;
        3 ) stophysteria && starthysteria ;;
        * ) exit 1 ;;
    esac
}

changebandwidth(){
    if ! read_current_config; then
        red "未找到配置文件，请先安装 Hysteria 2"
        return 1
    fi
    
    echo ""
    green "请选择是否开启带宽限速 (推荐开启以防止阻断)："
    echo -e " ${GREEN}1.${PLAIN} 开启 100 Mbps 限制"
    echo -e " ${GREEN}2.${PLAIN} 自定义限速数值"
    echo -e " ${GREEN}3.${PLAIN} 关闭限速 (不限制)"
    echo ""
    read -rp "请输入选项 [1-3]: " bwChange
    
    if [[ $bwChange == 1 ]]; then
        limit_bandwidth="yes"
        bandwidth_value="100"
        yellow "已设置为：100 Mbps 限速"
    elif [[ $bwChange == 2 ]]; then
        read -p "请输入限速数值 (单位 mbps，例如 50): " custBw
        [[ -z $custBw ]] && custBw=100
        limit_bandwidth="yes"
        bandwidth_value="$custBw"
        yellow "已设置为：$custBw Mbps 限速"
    else
        limit_bandwidth="no"
        bandwidth_value=""
        yellow "已关闭带宽限制"
    fi

    generate_config
    fix_permissions
    stophysteria && starthysteria
    green "带宽限制配置已更新！"
}

changeport(){
    if ! read_current_config; then
        red "未找到配置文件，请先安装 Hysteria 2"
        return 1
    fi
    inst_port_config
    generate_config
    generate_client_config
    fix_permissions
    stophysteria && starthysteria
    green "Hysteria 2 端口配置已更新！"
    showconf
}

changepasswd(){
    if ! read_current_config; then
        red "未找到配置文件，请先安装 Hysteria 2"
        return 1
    fi
    read -p "设置 Hysteria 2 密码（回车自动生成32位随机密码）：" new_pwd
    [[ -z $new_pwd ]] && new_pwd=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
    auth_pwd=$new_pwd
    generate_config
    generate_client_config
    fix_permissions
    stophysteria && starthysteria
    green "Hysteria 2 节点密码已成功修改为：$auth_pwd"
    showconf
}

change_cert(){
    if ! read_current_config; then
        red "未找到配置文件，请先安装 Hysteria 2"
        return 1
    fi
    inst_cert
    generate_config
    generate_client_config
    fix_permissions
    stophysteria && starthysteria
    green "Hysteria 2 节点证书类型已成功修改"
    showconf
}

changeproxysite(){
    if ! read_current_config; then
        red "未找到配置文件，请先安装 Hysteria 2"
        return 1
    fi
    inst_site
    generate_config
    fix_permissions
    stophysteria && starthysteria
    green "Hysteria 2 节点伪装形式已修改成功！"
}

changeconf(){
    green "Hysteria 2 配置变更选择如下:"
    echo -e " ${GREEN}1.${PLAIN} 修改端口 (重新配置)"
    echo -e " ${GREEN}2.${PLAIN} 修改密码"
    echo -e " ${GREEN}3.${PLAIN} 修改证书类型"
    echo -e " ${GREEN}4.${PLAIN} 修改伪装形式"
    echo -e " ${GREEN}5.${PLAIN} 编辑带宽限速"
    echo ""
    read -p " 请选择操作 [1-5]：" confAnswer
    case $confAnswer in
        1 ) changeport ;;
        2 ) changepasswd ;;
        3 ) change_cert ;;
        4 ) changeproxysite ;;
        5 ) changebandwidth ;;
        * ) exit 1 ;;
    esac
}

showconf(){
    if [[ ! -f /root/hy/hy-client.yaml ]]; then
        red "未找到客户端配置文件，请先安装 Hysteria 2"
        return 1
    fi
    yellow "Hysteria 2 客户端 YAML 配置文件 hy-client.yaml 内容如下"
    red "$(cat /root/hy/hy-client.yaml)"
    yellow "Hysteria 2 客户端 JSON 配置文件 hy-client.json 内容如下"
    red "$(cat /root/hy/hy-client.json)"
    yellow "Hysteria 2 节点分享链接如下"
    red "$(cat /root/hy/url.txt)"
    if [[ -f /root/hy/clash-verge-line.yaml ]]; then
        yellow "Clash Verge YAML 单行节点（粘贴到 proxies: 下）如下"
        red "$(cat /root/hy/clash-verge-line.yaml)"
    fi
    if [[ -f /root/hy/nekobox-qr.txt ]]; then
        yellow "NekoBox 扫码二维码（终端预览）如下"
        cat /root/hy/nekobox-qr.txt
    fi
}

menu() {
    clear
    echo "#############################################################"
    echo -e "#                  ${GREEN}Hysteria 2 一键安装脚本${PLAIN}                  #"
    echo "#############################################################"
    echo ""
    echo -e " ${GREEN}1.${PLAIN} ${GREEN}安装 Hysteria 2${PLAIN}"
    echo -e " ${RED}2.${PLAIN} ${RED}卸载 Hysteria 2${PLAIN}"
    echo " ------------------------------------------------------------"
    echo -e " 3. 关闭、开启、重启 Hysteria 2"
    echo -e " 4. 修改 Hysteria 2 配置"
    echo -e " 5. 显示 Hysteria 2 配置文件"
    echo " ------------------------------------------------------------"
    echo -e " 0. 退出脚本"
    echo ""
    read -rp "请输入选项 [0-5]: " menuInput
    case $menuInput in
        1 ) insthysteria ;;
        2 ) unsthysteria ;;
        3 ) hysteriaswitch ;;
        4 ) changeconf ;;
        5 ) showconf ;;
        0 ) exit 0 ;;
        * ) exit 1 ;;
    esac
}

menu
