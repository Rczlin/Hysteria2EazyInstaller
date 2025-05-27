#!/bin/bash
# 用法: 
#   ./script.sh          - 安装或重新安装
#   ./script.sh -start   - 启动服务
#   ./script.sh -stop    - 停止服务
#   ./script.sh -status  - 查看状态

set -e

show_disclaimer() {
    clear
    echo "========================================"
    echo -e "${RED}        重要免责声明${NC}"
    echo "========================================"
    echo ""
    echo -e "${YELLOW}请仔细阅读以下免责声明:${NC}"
    echo ""
    echo "1. 本脚本仅供学习和技术研究使用"
    echo "2. 使用者必须遵守当地法律法规"
    echo "3. 禁止用于任何违法违规活动"
    echo "4. 作者不对使用本脚本产生的任何后果负责"
    echo "5. 使用者应自行承担所有风险和责任"
    echo "6. 如不同意此声明，请立即停止使用"
    echo ""
    echo -e "${YELLOW}网络安全提醒:${NC}"
    echo "• 请确保在合法合规的环境下使用"
    echo "• 建议仅在测试环境中部署"
    echo "• 生产环境使用需遵循相关安全规范"
    echo ""
    echo -e "${YELLOW}技术支持说明:${NC}"
    echo "• 本脚本按现状提供，不提供任何保证"
    echo "• 作者不承担技术支持义务"
    echo ""
    echo "========================================"
    echo -e "${RED}继续使用即表示您完全理解并同意上述条款${NC}"
    echo "========================================"
    echo ""
    echo -n -e "${BLUE}您是否同意上述免责声明并继续? (输入 'YES' 继续，其他任意键退出): ${NC}"
    read -r agreement
    
    if [[ "$agreement" != "YES" ]]; then
        echo ""
        log_warn "用户未同意免责声明，脚本退出"
        echo "感谢您的理解，再见!"
        exit 0
    fi
    
    clear
    log_info "用户已同意免责声明，继续执行..."
    sleep 1
}

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# 检查是否已安装Hysteria 2
check_installation() {
    if command -v hysteria &> /dev/null && [[ -f /etc/systemd/system/hysteria2.service ]]; then
        return 0  # 已安装
    else
        return 1  # 未安装
    fi
}

# 启动服务
start_service() {
    show_disclaimer
    log_step "启动Hysteria 2服务..."
    if check_installation; then
        systemctl start hysteria2.service
        if systemctl is-active --quiet hysteria2.service; then
            log_info "Hysteria 2服务启动成功"
        else
            log_error "Hysteria 2服务启动失败"
            systemctl status hysteria2.service
        fi
    else
        log_error "Hysteria 2未安装，请先运行安装"
    fi
}

# 停止服务
stop_service() {
    show_disclaimer
    log_step "停止Hysteria 2服务..."
    if check_installation; then
        systemctl stop hysteria2.service
        log_info "Hysteria 2服务已停止"
    else
        log_error "Hysteria 2未安装"
    fi
}

# 查看服务状态
show_status() {
    log_step "查看Hysteria 2服务状态..."
    if check_installation; then
        echo ""
        echo -e "${BLUE}服务状态:${NC}"
        systemctl status hysteria2.service --no-pager
        echo ""
        echo -e "${BLUE}服务日志 (最近10行):${NC}"
        journalctl -u hysteria2.service -n 10 --no-pager
    else
        log_error "Hysteria 2未安装"
    fi
}

# 询问是否重新安装
ask_reinstall() {
    log_warn "检测到Hysteria 2已经安装"
    echo -n "是否要重新安装? (y/N): "
    read -r response
    case "$response" in
        [yY][eE][sS]|[yY])
            log_info "开始重新安装..."
            return 0
            ;;
        *)
            log_info "取消安装，退出脚本"
            exit 0
            ;;
    esac
}
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要root权限运行，请使用sudo执行"
        exit 1
    fi
}

# 检查系统是否为Debian
check_system() {
    if [[ ! -f /etc/debian_version ]]; then
        log_error "此脚本仅支持Debian系统"
        exit 1
    fi
    log_info "系统检查通过: $(cat /etc/debian_version)"
}

# 生成随机密码
generate_password() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-32
}

# 获取服务器IP
get_server_ip() {
    local ip
    ip=$(curl -s -4 ifconfig.me) || ip=$(curl -s -4 icanhazip.com) || ip=$(wget -qO- -4 ifconfig.me)
    echo "$ip"
}

# 更新系统包
update_system() {
    log_step "更新系统包..."
    apt update && apt upgrade -y
    apt install -y curl wget openssl ufw python3 qrencode
}

# 安装speedtest-cli进行网络测速
install_speedtest() {
    log_step "安装speedtest工具..."
    
    # 安装speedtest-cli
    if ! command -v speedtest-cli &> /dev/null; then
        apt install -y speedtest-cli
    fi
    
    log_info "speedtest工具安装完成"
}

# 进行网络测速
run_speedtest() {
    log_step "正在进行最近节点的网络测速..."
    
    local speedtest_result
    speedtest_result=$(speedtest-cli --simple 2>/dev/null | grep -E "Download|Upload|Ping" || echo "测速失败")

    if [[ "$speedtest_result" != "测速失败" ]]; then
        # 解析原始结果
        local download_raw=$(echo "$speedtest_result" | grep "Download" | awk '{print $2}')
        local download_unit=$(echo "$speedtest_result" | grep "Download" | awk '{print $3}')
        local upload_raw=$(echo "$speedtest_result" | grep "Upload" | awk '{print $2}')
        local upload_unit=$(echo "$speedtest_result" | grep "Upload" | awk '{print $3}')
        local ping=$(echo "$speedtest_result" | grep "Ping" | awk '{print $2, $3}')

        # 转换为 MB/s（如果单位是 Mbit/s）
        local download_converted=""
        local upload_converted=""

        if [[ "$download_unit" == "Mbit/s" ]]; then
            download_converted=$(awk "BEGIN {printf \"%.2f MB/s\", $download_raw / 8}")
        else
            download_converted="${download_raw} ${download_unit}"
        fi

        if [[ "$upload_unit" == "Mbit/s" ]]; then
            upload_converted=$(awk "BEGIN {printf \"%.2f MB/s\", $upload_raw / 8}")
        else
            upload_converted="${upload_raw} ${upload_unit}"
        fi

        # 保存测速结果到临时文件
        cat > /tmp/speedtest_result << EOF
下载速度: $download_converted
上传速度: $upload_converted
延迟: $ping
EOF
    else
        cat > /tmp/speedtest_result << EOF
下载速度: 测速失败
上传速度: 测速失败
延迟: 测速失败
EOF
    fi

    log_info "网络测速完成"
}


# 生成二维码(使用ASCII字符)
generate_qrcode() {
    local connection_url="$1"
    log_step "生成连接二维码..."
    
    # 使用qrencode生成二维码
    if command -v qrencode &> /dev/null; then
        echo ""
        echo -e "${BLUE}连接二维码:${NC}"
        echo "----------------------------------------"
        qrencode -t ANSIUTF8 "$connection_url"
        echo "----------------------------------------"
    else
        log_warn "qrencode未安装，跳过二维码生成"
    fi
}
install_hysteria2() {
    log_step "安装Hysteria 2..."
    
    # 下载安装脚本
    bash <(curl -fsSL https://get.hy2.sh/)
    
    # 检查安装是否成功
    if ! command -v hysteria &> /dev/null; then
        log_error "Hysteria 2 安装失败"
        exit 1
    fi
    
    log_info "Hysteria 2 安装成功"
}

# 生成自签证书
generate_certificate() {
    log_step "生成自签名证书..."
    
    local cert_dir="/etc/hysteria2"
    mkdir -p "$cert_dir"
    
    # 生成私钥
    openssl genrsa -out "$cert_dir/private.key" 2048
    
    # 生成证书
    openssl req -new -x509 -key "$cert_dir/private.key" -out "$cert_dir/cert.crt" -days 365 -subj "/C=US/ST=State/L=City/O=Organization/CN=www.csdn.net"
    
    # 设置权限
    chmod 600 "$cert_dir/private.key"
    chmod 644 "$cert_dir/cert.crt"
    
    log_info "证书生成完成"
}

# 配置Hysteria 2
configure_hysteria2() {
    log_step "配置Hysteria 2..."
    
    local config_dir="/etc/hysteria2"
    local config_file="$config_dir/config.yaml"
    local password=$(generate_password)
    
    mkdir -p "$config_dir"
    
    # 创建配置文件
    cat > "$config_file" << EOF
listen: :443

tls:
  cert: /etc/hysteria2/cert.crt
  key: /etc/hysteria2/private.key

auth:
  type: password
  password: $password

masquerade:
  type: proxy
  proxy:
    url: https://www.csdn.net/
    rewriteHost: true

udpIdleTimeout: 60s
udpHopInterval: 30s

ignoreClientBandwidth: true
disableUDP: false
EOF

    # 设置配置文件权限
    chmod 600 "$config_file"
    
    # 保存密码到临时文件供后续使用
    echo "$password" > /tmp/hy2_password
    
    log_info "配置文件创建完成"
}

create_systemd_service() {
    log_step "创建systemd服务..."
    
    cat > /etc/systemd/system/hysteria2.service << EOF
[Unit]
Description=Hysteria 2 Server
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria2/config.yaml
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    # 重新加载systemd
    systemctl daemon-reload
    
    # 启用并启动服务
    systemctl enable hysteria2.service
    systemctl start hysteria2.service
    
    log_info "systemd服务创建并启动完成"
}

# 配置防火墙
configure_firewall() {
    log_step "检查防火墙配置..."

    if ! command -v ufw &> /dev/null; then
        log_warn "未安装ufw，跳过防火墙配置"
        return
    fi

    local status
    status=$(ufw status 2>/dev/null | grep -i "Status:" | awk '{print $2}')
    if [[ "$status" != "active" ]]; then
        log_warn "ufw 未启用（当前状态: $status），跳过防火墙配置"
        return
    fi

    log_step "配置防火墙规则..."

    # 允许SSH连接
    ufw allow ssh

    # 允许443端口
    ufw allow 443/tcp
    ufw allow 443/udp

    ufw reload

    log_info "防火墙规则配置完成"
}


check_service_status() {
    log_step "检查服务状态..."
    
    if systemctl is-active --quiet hysteria2.service; then
        log_info "Hysteria 2 服务运行正常"
        return 0
    else
        log_error "Hysteria 2 服务启动失败"
        systemctl status hysteria2.service
        return 1
    fi
}

# 输出连接信息
output_connection_info() {
    log_step "生成连接信息..."
    
    local server_ip=$(get_server_ip)
    local password=$(cat /tmp/hy2_password)
    local connection_url="hysteria2://$password@$server_ip:443/?insecure=1&sni=www.csdn.net#HY2-Server"
    
    echo ""
    echo "========================================"
    echo -e "${GREEN}Hysteria 2 安装配置完成!${NC}"
    echo "========================================"
    echo ""
    echo -e "${BLUE}服务器信息:${NC}"
    echo "服务器IP: $server_ip"
    echo "端口: 443"
    echo "密码: $password"
    echo "伪装URL: https://www.csdn.net/"
    echo "端口跳跃: 已启用"
    echo "流量限制: 无限制"
    echo ""
    echo -e "${BLUE}连接链接:${NC}"
    echo "$connection_url"
    echo ""
    
    # 生成二维码
    generate_qrcode "$connection_url"
    
    echo ""
    echo -e "${BLUE}网络测速结果:${NC}"
    if [[ -f /tmp/speedtest_result ]]; then
        cat /tmp/speedtest_result
    fi
    echo ""
    echo -e "${BLUE}客户端配置信息:${NC}"
    cat << EOF
server: $server_ip:443
auth: $password
tls:
  sni: www.csdn.net
  insecure: true
EOF
    echo ""
    echo -e "${YELLOW}注意事项:${NC}"
    echo "1. 请妥善保存上述连接信息"
    echo "2. 服务已设置为开机自启动"
    echo "3. 如需重启服务: systemctl restart hysteria2"
    echo "4. 查看服务状态: systemctl status hysteria2"
    echo "5. 查看服务日志: journalctl -u hysteria2 -f"
    echo ""
    echo -e "${RED}重要提醒:${NC}"
    echo "• 请合法合规使用，遵守当地法律法规"
    echo "• 本工具仅供学习和技术研究使用"
    echo "• 作者不承担任何使用后果和法律责任"
    echo ""
    
    # 清理临时文件
    rm -f /tmp/hy2_password /tmp/speedtest_result
}

main() {
    case "${1:-}" in
        -start)
            check_root
            start_service
            exit 0
            ;;
        -stop)
            check_root
            stop_service
            exit 0
            ;;
        -status)
            show_status
            exit 0
            ;;
        "")
            # 默认执行安装流程
            show_disclaimer
            ;;
        *)
            echo "用法: $0 [-start|-stop|-status]"
            echo "  无参数    - 安装或重新安装Hysteria 2"
            echo "  -start    - 启动Hysteria 2服务"
            echo "  -stop     - 停止Hysteria 2服务"
            echo "  -status   - 查看Hysteria 2服务状态"
            exit 1
            ;;
    esac
    
    log_info "开始安装和配置Hysteria 2..."
    
    check_root
    check_system
    
    # 检查是否已安装，如果已安装则询问是否重新安装
    if check_installation; then
        ask_reinstall
    fi
    
    update_system
    install_speedtest
    install_hysteria2
    generate_certificate
    configure_hysteria2
    create_systemd_service
    configure_firewall
    
    # 等待服务启动
    sleep 3
    
    if check_service_status; then
        # 进行网络测速
        run_speedtest
        output_connection_info
        log_info "安装完成! 请查看上方的连接信息"
    else
        log_error "安装过程中出现错误，请检查日志"
        exit 1
    fi
}
trap 'log_error "脚本执行过程中发生错误，退出码: $?"' ERR
main "$@"