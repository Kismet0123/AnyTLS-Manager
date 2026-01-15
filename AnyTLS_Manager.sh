#!/usr/bin/env bash
PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

# 颜色定义
Green_font_prefix="\033[32m" && Red_font_prefix="\033[31m" && Yellow_font_prefix="\033[0;33m" && Cyan_font_prefix="\033[0;36m" && RESET="\033[0m"

# 信息前缀
INFO="${Green_font_prefix}[信息]${RESET}"
ERROR="${Red_font_prefix}[错误]${RESET}"
WARNING="${Yellow_font_prefix}[警告]${RESET}"

# 全局变量
INSTALL_DIR="/usr/local/bin"
BINARY_NAME="anytls-server"
CONFIG_DIR="/etc/anytls"
CONFIG_FILE="${CONFIG_DIR}/config"
SERVICE_FILE="/etc/systemd/system/anytls.service"
LISTEN_ADDR="[::]"  # 默认监听地址
LISTEN_PORT="8443"  # 默认监听端口
PASSWORD=""
TMP_DIR="/tmp/anytls"
RELEASE=""
VERSION=""          # 用于存储下载的版本号
SNI=""              # 默认使用本机 IP 作为 SNI
INSECURE="1"        # 默认启用不安全连接

# 检查是否以 root 权限运行
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${ERROR} 请以 root 或使用 sudo 运行此脚本"
        exit 1
    fi
}

# 检查系统发行版类型
check_system_type() {
    if [[ -f /etc/redhat-release ]]; then
        RELEASE="centos"
    elif grep -q -E -i "debian|ubuntu" /etc/issue; then
        RELEASE="debian"
    elif grep -q -E -i "centos|red hat|redhat" /etc/issue; then
        RELEASE="centos"
    elif grep -q -E -i "debian|ubuntu" /proc/version; then
        RELEASE="debian"
    else
        RELEASE="unknown"
    fi
    if [[ "$RELEASE" == "unknown" ]]; then
        echo -e "${ERROR} 无法识别的系统发行版，请检查兼容性"
        exit 1
    fi
    echo -e "${INFO} 检测到系统发行版: $RELEASE"
}

# 检查并安装依赖工具
install_tools() {
    local missing_tools=()
    for tool in wget curl unzip openssl; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done

    if [[ ${#missing_tools[@]} -eq 0 ]]; then
        echo -e "${INFO} 所有依赖工具已安装"
        return 0
    fi

    echo -e "${INFO} 检测到缺少工具: ${missing_tools[*]}，开始安装..."
    check_system_type
    case "$RELEASE" in
        debian)
            apt update && apt install -y "${missing_tools[@]}" || {
                echo -e "${ERROR} 安装依赖失败"
                exit 1
            }
            ;;
        centos)
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y "${missing_tools[@]}" || {
                    echo -e "${ERROR} 安装依赖失败"
                    exit 1
                }
            else
                yum install -y "${missing_tools[@]}" || {
                    echo -e "${ERROR} 安装依赖失败"
                    exit 1
                }
            fi
            ;;
        *)
            echo -e "${WARNING} 未知发行版，尝试使用 apt 安装..."
            apt update && apt install -y "${missing_tools[@]}" || {
                echo -e "${ERROR} 安装依赖失败"
                exit 1
            }
            ;;
    esac
    echo -e "${INFO} 依赖工具安装完成"
}

# 检查系统架构
get_system_architecture() {
    case "$(uname -m)" in
        x86_64) echo "amd64" ;;
        aarch64) echo "arm64" ;;
        *) echo -e "${ERROR} 不支持的系统架构: $(uname -m)"; exit 1 ;;
    esac
}

# 获取最新版本号，失败时回退到默认版本 0.0.12，确保不含 v 前缀
get_latest_version() {
    local version
    version=$(curl -s "https://api.github.com/repos/anytls/anytls-go/releases/latest" | grep -oP '"tag_name": "\K[^"]+')
    version=${version#v}
    if [[ -z "$version" ]]; then
        echo -e "${WARNING} 无法获取最新版本，使用默认版本 0.0.12"
        echo "0.0.12"
    else
        echo "$version"
    fi
}

# 下载并解压 anytls 二进制文件
download_anytls() {
    VERSION=$(get_latest_version)
    local arch_str=$(get_system_architecture)
    local zip_file="anytls_${VERSION}_linux_${arch_str}.zip"
    local download_url="https://github.com/anytls/anytls-go/releases/download/v${VERSION}/${zip_file}"
    
    echo -e "${INFO} 正在下载 ${zip_file} ..."
    mkdir -p "${TMP_DIR}"
    wget -O "${TMP_DIR}/${zip_file}" "$download_url" || {
        echo -e "${ERROR} 下载失败，请检查网络或 URL"
        exit 1
    }
    
    echo -e "${INFO} 解压 ${zip_file} ..."
    unzip -o "${TMP_DIR}/${zip_file}" -d "${TMP_DIR}" || {
        echo -e "${ERROR} 解压失败，请确保 unzip 已安装"
        exit 1
    }
    
    mv "${TMP_DIR}/anytls-server" "${INSTALL_DIR}/"
    chmod +x "${INSTALL_DIR}/${BINARY_NAME}"
    
    rm -rf "${TMP_DIR}"
    echo -e "${INFO} 下载并安装完成"
}

# 检测端口是否被占用
check_port_in_use() {
    if [ -n "$(ss -ltnH "sport = :$1")" ]; then
        return 0  # 端口被占用
    else
        return 1  # 端口未被占用
    fi
}

# 配置防火墙规则
configure_firewall() {
    if command -v ufw >/dev/null && ufw status | grep -q "active"; then
        ufw allow "$LISTEN_PORT/tcp" && echo -e "${INFO} $LISTEN_PORT/tcp 外部监听端口已放行"
    elif command -v firewall-cmd >/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --add-port="$LISTEN_PORT/tcp" --permanent && firewall-cmd --reload && echo -e "${INFO} $LISTEN_PORT/tcp 外部监听端口已放行"
    else
        echo -e "${WARNING} 未检测到启用的防火墙工具（ufw 或 firewalld），请手动配置防火墙以允许端口 $LISTEN_PORT"
    fi
}

# 移除防火墙规则
remove_firewall_rules() {
    local port=$1
    if [ -z "$port" ]; then
        echo -e "${ERROR} 未提供端口号，无法移除防火墙规则"
        return 1
    fi
    if command -v ufw >/dev/null && ufw status | grep -q "active"; then
        ufw delete allow "$port/tcp" && echo -e "${INFO} 已撤销 ufw 对 $port/tcp 的放行规则"
    elif command -v firewall-cmd >/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --remove-port="$port/tcp" --permanent && firewall-cmd --reload && echo -e "${INFO} 已撤销 firewalld 对 $port/tcp 的放行规则"
    else
        echo -e "${WARNING} 未检测到启用的防火墙工具，无需移除规则"
    fi
    return 0
}

# 配置监听端口和密码
configure_anytls() {
    local input_port server_ips ip_array default_port="8443"

    # 配置监听端口
    while true; do
        read -rp "请输入监听端口 (默认: ${default_port}): " input_port
        input_port="${input_port:-$default_port}"  # 如果用户未输入，使用默认值
        if ! [[ "$input_port" =~ ^[0-9]+$ ]] || [ "$input_port" -lt 1 ] || [ "$input_port" -gt 65535 ]; then
            echo -e "${ERROR} 端口号必须是 1-65535 之间的数字"
        elif check_port_in_use "$input_port"; then
            echo -e "${ERROR} 端口 ${input_port} 已被占用，请选择其他端口"
        else
            LISTEN_PORT="$input_port"  # 仅在端口有效时更新全局变量
            break
        fi
    done

    # 配置密码
    read -rp "请输入 AnyTLS 密码 (留空则自动生成): " input_password
    if [[ -z "$input_password" ]]; then
        PASSWORD=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 16)
        echo -e "${Cyan_font_prefix}自动生成的密码为: ${PASSWORD}${RESET}"
    else
        PASSWORD="$input_password"
    fi

    # 设置默认值并优化 SNI
    server_ips=$(get_server_ip) || { echo -e "${ERROR} 获取服务器 IP 失败"; exit 1; }
    IFS=' ' read -r -a ip_array <<< "$server_ips"
    SNI="${ip_array[0]}"  # 默认使用第一个 IP（通常是 IPv4）作为 SNI
    INSECURE="1"          # 默认启用不安全连接

    # 配置防火墙
    configure_firewall

    # 提示用户当前配置
    echo -e "${INFO} 配置完成："
    echo -e "  监听地址: ${LISTEN_ADDR}:${LISTEN_PORT}"
    echo -e "  密码: ${PASSWORD}"
    echo -e "  默认 SNI: ${SNI}"
    echo -e "  不安全连接: ${INSECURE} (1=启用, 0=禁用)"
}

# 保存配置到文件
save_config() {
    mkdir -p "${CONFIG_DIR}"
    cat > "$CONFIG_FILE" <<EOF
listen_addr=${LISTEN_ADDR}
listen_port=${LISTEN_PORT}
password=${PASSWORD}
version=${VERSION}
sni=${SNI}
insecure=${INSECURE}
EOF
    echo -e "${INFO} 配置已保存至 ${CONFIG_FILE}"
}

# 创建或更新 systemd 服务文件
create_or_update_service() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=AnyTLS Server Service
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
ExecStart=${INSTALL_DIR}/${BINARY_NAME} -l ${LISTEN_ADDR}:${LISTEN_PORT} -p ${PASSWORD}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable anytls
    echo -e "${INFO} systemd 服务已创建或更新"
}

# 启动服务
start_service() {
    systemctl start anytls
    sleep 2
    if systemctl is-active --quiet anytls; then
        echo -e "${INFO} AnyTLS 服务已启动"
    else
        echo -e "${ERROR} AnyTLS 服务启动失败，请检查日志"
        journalctl -u anytls -n 20 --no-pager
    fi
}

# 停止服务
stop_service() {
    systemctl stop anytls
    echo -e "${INFO} AnyTLS 服务已停止"
}

# 重启服务
restart_service() {
    systemctl restart anytls
    sleep 2
    if systemctl is-active --quiet anytls; then
        echo -e "${INFO} AnyTLS 服务已重启"
    else
        echo -e "${ERROR} AnyTLS 服务重启失败，请检查日志"
        journalctl -u anytls -n 20 --no-pager
    fi
}

# 获取 VPS 的公网 IP 地址
get_server_ip() {
    local ipv4=""
    local ipv6=""

    if command -v ip >/dev/null 2>&1; then
        ipv4=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+' | grep -v '^127\.' | head -n 1)
        ipv6=$(ip -6 addr show scope global | grep -oP '(?<=inet6\s)[0-9a-f:]+' | grep -v '^fe80:' | head -n 1)
    elif command -v ifconfig >/dev/null 2>&1; then
        ipv4=$(ifconfig | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+' | grep -v '^127\.' | head -n 1)
        ipv6=$(ifconfig | grep -oP '(?<=inet6\s)[0-9a-f:]+' | grep -v '^fe80:' | head -n 1)
    fi

    if [[ -z "$ipv4" && -z "$ipv6" ]]; then
        ipv4=$(curl -s -4 ip.sb 2>/dev/null)
        ipv6=$(curl -s -6 ip.sb 2>/dev/null)
    fi

    if [[ -n "$ipv4" && -n "$ipv6" ]]; then
        echo "$ipv4 $ipv6"
    elif [[ -n "$ipv4" ]]; then
        echo "$ipv4"
    elif [[ -n "$ipv6" ]]; then
        echo "$ipv6"
    else
        echo -e "${ERROR} 无法获取服务器 IP"
        return 1
    fi
    return 0
}

# 生成 AnyTLS 配置信息
generate_anytls_config() {
    local server_ips="$1"
    local listen_port="$2"
    local password="$3"
    local sni="$4"
    local insecure="$5"
    
    IFS=' ' read -r -a ip_array <<< "$server_ips"
    
    for server_ip in "${ip_array[@]}"; do
        local ip_type="IPv4"
        local display_ip="$server_ip"
        if [[ "$server_ip" =~ : ]]; then
            ip_type="IPv6"
            display_ip="[$server_ip]"
        fi
        
        # 构造参数
        local uri_params=""
        local surge_insecure="false"
        
        if [[ -n "$sni" ]]; then
            uri_params="sni=${sni}"
            if [[ "$insecure" == "1" ]]; then
                uri_params="${uri_params}&insecure=1"
                surge_insecure="true"
            else
                uri_params="${uri_params}&insecure=0"
            fi
        else
            if [[ "$insecure" == "1" ]]; then
                uri_params="insecure=1"
                surge_insecure="true"
            else
                uri_params="insecure=0"
            fi
        fi
        
        local share_link="anytls://${password}@${display_ip}:${listen_port}?${uri_params}"
        
        echo -e "\n${Yellow_font_prefix}================== 服务器配置 ($ip_type) ==================${RESET}"
        echo -e "${Green_font_prefix}服务器 IP：${RESET}${server_ip}"
        echo -e "${Green_font_prefix}端口：${RESET}${listen_port}"
        echo -e "${Green_font_prefix}密码：${RESET}${password}"
        echo -e "${Green_font_prefix}SNI：${RESET}${sni}"
        echo -e "${Green_font_prefix}跳过证书验证 (Insecure)：${RESET}$([[ "$insecure" == "1" ]] && echo "是" || echo "否")"

        echo -e "\n${Yellow_font_prefix}------------------ 通用 / Shadowrocket 配置 ($ip_type) ------------------${RESET}"
        echo -e "${Green_font_prefix}AnyTLS 链接：${RESET}"
        echo -e "${share_link}"
        echo -e "${Green_font_prefix}二维码链接（复制到浏览器生成）：${RESET}"
        echo -e "https://api.cl2wm.cn/api/qrcode/code?text=${share_link}"

        echo -e "\n${Yellow_font_prefix}------------------ Surge 配置 ($ip_type) ------------------${RESET}"
        echo -e "${Green_font_prefix}AnyTLS = anytls, ${display_ip}, ${listen_port}, password=${password}, sni=${sni}, skip-cert-verify=${surge_insecure}${RESET}"

        echo -e "\n${Yellow_font_prefix}------------------ Mihomo (Clash Meta) 配置 ($ip_type) ------------------${RESET}"
        echo -e "${Green_font_prefix}proxies:${RESET}"
        echo -e "  - name: anytls-$ip_type"
        echo -e "    type: anytls"
        echo -e "    server: ${display_ip}"
        echo -e "    port: ${listen_port}"
        echo -e "    password: \"${password}\""
        echo -e "    client-fingerprint: chrome"
        echo -e "    udp: true"
        echo -e "    sni: \"${sni}\""
        echo -e "    alpn:"
        echo -e "      - h2"
        echo -e "      - http/1.1"
        if [[ "$insecure" == "1" ]]; then
            echo -e "    skip-cert-verify: true"
        else
            echo -e "    skip-cert-verify: false"
        fi

        echo -e "\n${Yellow_font_prefix}------------------ Sing-box 配置 ($ip_type) ------------------${RESET}"
        echo -e "${Green_font_prefix}{${RESET}"
        echo -e "  \"type\": \"anytls\","
        echo -e "  \"tag\": \"anytls-out-$ip_type\","
        echo -e "  \"server\": \"${server_ip}\","
        echo -e "  \"server_port\": ${listen_port},"
        echo -e "  \"password\": \"${password}\","
        echo -e "  \"idle_session_check_interval\": \"30s\","
        echo -e "  \"idle_session_timeout\": \"30s\","
        echo -e "  \"min_idle_session\": 5,"
        echo -e "  \"tls\": {"
        echo -e "    \"enabled\": true,"
        echo -e "    \"server_name\": \"${sni}\","
        if [[ "$insecure" == "1" ]]; then
            echo -e "    \"insecure\": true"
        else
            echo -e "    \"insecure\": false"
        fi
        echo -e "  }"
        echo -e "}"
    done
}

# 查看配置
view_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # 读取配置参数
        local listen_port=$(grep '^listen_port=' "$CONFIG_FILE" | cut -d'=' -f2)
        local password=$(grep '^password=' "$CONFIG_FILE" | cut -d'=' -f2)
        local sni=$(grep '^sni=' "$CONFIG_FILE" | cut -d'=' -f2)
        local insecure=$(grep '^insecure=' "$CONFIG_FILE" | cut -d'=' -f2)
        local version=$(grep '^version=' "$CONFIG_FILE" | cut -d'=' -f2)
        local server_ips=$(get_server_ip) || { echo -e "${ERROR} 获取服务器 IP 失败"; return 1; }

        echo -e "${Cyan_font_prefix}AnyTLS 当前安装版本：${version}${RESET}"
        
        generate_anytls_config "$server_ips" "$listen_port" "$password" "$sni" "$insecure"
    else
        echo -e "${ERROR} 未找到配置文件，请先安装 AnyTLS"
    fi
}

# 修改配置
set_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${ERROR} 未找到配置文件，请先安装 AnyTLS"
        return
    fi
    # 读取当前版本号和已有配置
    local current_version=$(grep '^version=' "$CONFIG_FILE" | cut -d'=' -f2)
    SNI=$(grep '^sni=' "$CONFIG_FILE" | cut -d'=' -f2)
    INSECURE=$(grep '^insecure=' "$CONFIG_FILE" | cut -d'=' -f2)
    echo -e "你要修改什么？\n1. 修改监听端口\n2. 修改密码\n3. 修改全部配置"
    read -rp "选择操作: " choice
    case "$choice" in
        1)
            configure_port
            configure_firewall
            ;;
        2)
            configure_password
            ;;
        3)
            configure_anytls
            ;;
        *)
            echo -e "${ERROR} 无效的选择"
            return
            ;;
    esac
    # 保存配置时保留版本号、sni 和 insecure
    mkdir -p "${CONFIG_DIR}"
    cat > "$CONFIG_FILE" <<EOF
listen_addr=${LISTEN_ADDR}
listen_port=${LISTEN_PORT}
password=${PASSWORD}
version=${current_version}
sni=${SNI}
insecure=${INSECURE}
EOF
    echo -e "${INFO} 配置已更新至 ${CONFIG_FILE}"
    create_or_update_service
    restart_service
}

configure_port() {
    local input_port
    while true; do
        read -rp "请输入新的监听端口 (当前: ${LISTEN_PORT}): " input_port
        if ! [[ "$input_port" =~ ^[0-9]+$ ]] || [ "$input_port" -lt 1 ] || [ "$input_port" -gt 65535 ]; then
            echo -e "${ERROR} 端口号必须是 1-65535 之间的数字"
        elif check_port_in_use "$input_port"; then
            echo -e "${ERROR} 端口 ${input_port} 已被占用，请选择其他端口"
        else
            LISTEN_PORT="$input_port"
            break
        fi
    done
}

configure_password() {
    read -rp "请输入新的 AnyTLS 密码 (留空则自动生成): " input_password
    if [[ -z "$input_password" ]]; then
        PASSWORD=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 16)
        echo -e "${Cyan_font_prefix}自动生成的密码为: ${PASSWORD}${RESET}"
    else
        PASSWORD="$input_password"
    fi
}

# 卸载 AnyTLS
uninstall_anytls() {
    echo -e "${WARNING} 正在卸载 AnyTLS..."
    read -rp "确认卸载吗？(y/n): " confirm
    if [[ "${confirm,,}" == "y" ]]; then
        systemctl stop anytls
        systemctl disable anytls
        if [[ -f "$CONFIG_FILE" ]]; then
            local port=$(grep '^listen_port=' "$CONFIG_FILE" | cut -d'=' -f2)
            remove_firewall_rules "$port"
        else
            echo -e "${WARNING} 无法读取配置文件，跳过防火墙规则撤销"
        fi
        rm -f "${INSTALL_DIR}/${BINARY_NAME}"
        rm -rf "${CONFIG_DIR}"
        rm -f "${SERVICE_FILE}"
        systemctl daemon-reload
        echo -e "${INFO} AnyTLS 已成功卸载"
    else
        echo -e "${WARNING} 取消卸载"
    fi
}

# 升级 AnyTLS
upgrade_anytls() {
    local current_version latest_version
    if [[ -f "$CONFIG_FILE" ]]; then
        current_version=$(grep '^version=' "$CONFIG_FILE" | cut -d'=' -f2)
        current_version=${current_version:-"未知"}
    else
        current_version="未安装"
    fi
    latest_version=$(get_latest_version)

    if [[ "$current_version" == "$latest_version" ]]; then
        echo -e "${INFO} 当前已是最新版本 ($current_version)，无需升级。"
    else
        echo -e "${INFO} 检测到新版本：当前版本 $current_version，最新版本 $latest_version。"
        read -rp "是否升级到最新版本？(y/n): " choice
        if [[ "${choice,,}" == "y" ]]; then
            echo -e "${INFO} 正在升级 AnyTLS..."
            systemctl stop anytls
            download_anytls  # 下载新版本并更新 VERSION
            save_config      # 更新配置文件中的版本号
            create_or_update_service
            systemctl start anytls
            if systemctl is-active --quiet anytls; then
                echo -e "${INFO} AnyTLS 已成功升级并启动"
            else
                echo -e "${ERROR} AnyTLS 升级后启动失败，请检查日志"
                journalctl -u anytls -n 20 --no-pager
            fi
        else
            echo -e "${WARNING} 取消升级"
        fi
    fi
}

# 安装 AnyTLS
install_anytls() {
    install_tools
    download_anytls  # VERSION 会被设置为全局变量
    configure_anytls
    save_config      # 保存配置时包含版本号
    create_or_update_service
    start_service

    # 清屏并显示配置信息
    clear
    echo -e "${Green_font_prefix}=== AnyTLS 安装完成，以下为配置信息 ===${RESET}"
    local server_ip=$(get_server_ip) || { echo -e "${ERROR} 获取服务器 IP 失败"; exit 1; }
    generate_anytls_config "$server_ip" "$LISTEN_PORT" "$PASSWORD" "$SNI" "$INSECURE"
}

# 主菜单
main_menu() {
    while true; do
        clear
        echo -e "\n${Cyan_font_prefix}AnyTLS 管理菜单${RESET}"
        echo -e "=================================="
        echo -e " 安装与更新"
        echo -e "=================================="
        echo -e "${Yellow_font_prefix}1. 安装 AnyTLS${RESET}"
        echo -e "${Yellow_font_prefix}2. 升级 AnyTLS${RESET}"
        echo -e "${Yellow_font_prefix}3. 卸载 AnyTLS${RESET}"
        echo -e "=================================="
        echo -e " 配置管理"
        echo -e "=================================="
        echo -e "${Yellow_font_prefix}4. 查看 AnyTLS 配置信息${RESET}"
        echo -e "${Yellow_font_prefix}5. 修改 AnyTLS 配置${RESET}"
        echo -e "=================================="
        echo -e " 服务控制"
        echo -e "=================================="
        echo -e "${Yellow_font_prefix}6. 启动 AnyTLS${RESET}"
        echo -e "${Yellow_font_prefix}7. 停止 AnyTLS${RESET}"
        echo -e "${Yellow_font_prefix}8. 重启 AnyTLS${RESET}"
        echo -e "=================================="
        echo -e " 退出"
        echo -e "=================================="
        echo -e "${Yellow_font_prefix}0. 退出${RESET}"
        
        # 检测 AnyTLS 运行状态
        if [[ -e "${INSTALL_DIR}/${BINARY_NAME}" ]]; then
            if systemctl is-active --quiet anytls; then
                echo -e " 当前状态：${Green_font_prefix}已安装并已启动${RESET}"
            else
                echo -e " 当前状态：${Green_font_prefix}已安装${RESET} 但 ${Red_font_prefix}未启动${RESET}"
            fi
        else
            echo -e " 当前状态：${Red_font_prefix}未安装${RESET}"
        fi
        
        read -rp "请选择操作 [0-8]: " choice
        case "$choice" in
            1) install_anytls ;;
            2) upgrade_anytls ;;
            3) uninstall_anytls ;;
            4) view_config ;;
            5) set_config ;;
            6) start_service ;;
            7) stop_service ;;
            8) restart_service ;;
            0) exit 0 ;;
            *) echo -e "${ERROR} 无效的选择" ;;
        esac
        echo -e "\n按任意键返回主菜单..."
        read -n1 -s
    done
}

# 执行主菜单
check_root
main_menu
