#!/bin/bash

# 增强版 Realm & GOST 一键管理脚本
# 功能：支持多条转发规则、备注管理、状态查看
# 版本：v2.6
# 修改说明：
#   1. 修复GOST域名解析问题（启动时预解析为IP）
#   2. 统一Realm和GOST的地址处理逻辑
#   3. 增强错误处理和日志提示

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 配置文件路径
CONFIG_DIR="/etc/forward_tools"
REALM_CONFIG="$CONFIG_DIR/realm_rules.conf"
GOST_CONFIG="$CONFIG_DIR/gost_rules.conf"
NOTES_CONFIG="$CONFIG_DIR/forward_notes.conf"

# 检查root权限
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}错误：此脚本必须以root权限运行！${NC}" >&2
        exit 1
    fi
}

# 检查系统
check_system() {
    if [ -f /etc/redhat-release ]; then
        SYSTEM="centos"
    elif grep -Eqi "debian" /etc/issue; then
        SYSTEM="debian"
    elif grep -Eqi "ubuntu" /etc/issue; then
        SYSTEM="ubuntu"
    elif grep -Eqi "centos|red hat|redhat" /etc/issue; then
        SYSTEM="centos"
    elif grep -Eqi "debian" /proc/version; then
        SYSTEM="debian"
    elif grep -Eqi "ubuntu" /proc/version; then
        SYSTEM="ubuntu"
    elif grep -Eqi "centos|red hat|redhat" /proc/version; then
        SYSTEM="centos"
    else
        echo -e "${RED}不支持的系统！${NC}"
        exit 1
    fi
}

# 安装依赖
install_dependencies() {
    echo -e "${YELLOW}正在安装必要依赖...${NC}"
    if [ "$SYSTEM" = "centos" ]; then
        yum install -y wget unzip curl tar jq bind-utils
    else
        apt-get update
        apt-get install -y wget unzip curl tar jq dnsutils
    fi
    
    if ! command -v wget &> /dev/null || ! command -v jq &> /dev/null || ! command -v dig &> /dev/null; then
        echo -e "${RED}依赖安装失败，请手动安装wget、jq和dnsutils后重试！${NC}"
        exit 1
    fi
}

# 初始化配置目录
init_config_dir() {
    mkdir -p "$CONFIG_DIR"
    touch "$REALM_CONFIG" "$GOST_CONFIG" "$NOTES_CONFIG"
    chmod 600 "$REALM_CONFIG" "$GOST_CONFIG" "$NOTES_CONFIG"
}

# 安装Realm
install_realm() {
    if command -v realm &> /dev/null; then
        echo -e "${YELLOW}Realm 已安装，跳过安装步骤。${NC}"
        return
    fi
    
    echo -e "${YELLOW}正在安装Realm...${NC}"
    local latest_version=$(curl -s https://api.github.com/repos/zhboner/realm/releases/latest | grep 'tag_name' | cut -d\" -f4)
    
    if [ -z "$latest_version" ]; then
        echo -e "${RED}无法获取Realm最新版本！${NC}"
        exit 1
    fi
    
    local download_url="https://github.com/zhboner/realm/releases/download/${latest_version}/realm-x86_64-unknown-linux-gnu.tar.gz"
    
    if ! wget -O /tmp/realm.tar.gz "$download_url"; then
        echo -e "${RED}下载Realm失败！${NC}"
        exit 1
    fi
    
    tar -xzf /tmp/realm.tar.gz -C /tmp
    mv /tmp/realm /usr/local/bin/realm
    chmod +x /usr/local/bin/realm
    
    if ! command -v realm &> /dev/null; then
        echo -e "${RED}Realm安装失败！${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}Realm安装成功！版本: $latest_version${NC}"
}

# 安装GOST
install_gost() {
    if command -v gost &> /dev/null; then
        echo -e "${YELLOW}GOST 已安装，跳过安装步骤。${NC}"
        return
    fi
    
    echo -e "${YELLOW}正在安装GOST...${NC}"
    local latest_version=$(curl -s https://api.github.com/repos/ginuerzh/gost/releases/latest | grep 'tag_name' | cut -d\" -f4)
    
    if [ -z "$latest_version" ]; then
        echo -e "${RED}无法获取GOST最新版本！${NC}"
        exit 1
    fi
    
    local arch=$(uname -m)
    case $arch in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *) echo -e "${RED}不支持的架构: $arch${NC}"; exit 1 ;;
    esac
    
    local download_url="https://github.com/ginuerzh/gost/releases/download/${latest_version}/gost_${latest_version#v}_linux_${arch}.tar.gz"
    
    if ! wget -O /tmp/gost.tar.gz "$download_url"; then
        echo -e "${RED}下载GOST失败！${NC}"
        exit 1
    fi
    
    tar -xzf /tmp/gost.tar.gz -C /tmp
    if [ -f "/tmp/gost" ]; then
        mv /tmp/gost /usr/local/bin/gost
    elif [ -d "/tmp/gost_${latest_version#v}_linux_${arch}" ]; then
        mv "/tmp/gost_${latest_version#v}_linux_${arch}/gost" /usr/local/bin/gost
    else
        echo -e "${RED}无法找到GOST可执行文件！${NC}"
        exit 1
    fi
    
    chmod +x /usr/local/bin/gost
    
    if ! command -v gost &> /dev/null; then
        echo -e "${RED}GOST安装失败！${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}GOST安装成功！版本: $latest_version${NC}"
}

# 解析域名获取IP地址
resolve_domain() {
    local domain=$1
    local ip=$(dig +short "$domain" | head -n1)
    
    if [ -z "$ip" ]; then
        echo -e "${RED}无法解析域名: $domain${NC}"
        return 1
    fi
    
    echo "$ip"
}

# 验证端口和地址格式
validate_input() {
    local port=$1
    local addr=$2
    
    # 验证端口
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "${RED}错误：端口号必须是1-65535之间的数字！${NC}"
        return 1
    fi
    
    # 分离地址和端口
    local remote_host=${addr%:*}
    local remote_port=${addr##*:}
    
    # 验证远程端口
    if ! [[ "$remote_port" =~ ^[0-9]+$ ]] || [ "$remote_port" -lt 1 ] || [ "$remote_port" -gt 65535 ]; then
        echo -e "${RED}错误：远程端口号必须是1-65535之间的数字！${NC}"
        return 1
    fi
    
    # 验证远程主机
    if [[ "$remote_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 0  # 是IP地址
    elif [[ "$remote_host" =~ ^[a-zA-Z0-9.-]+$ ]]; then
        # 是域名，尝试解析
        if ! resolve_domain "$remote_host" >/dev/null; then
            return 1
        fi
        return 0
    else
        echo -e "${RED}错误：远程地址格式应为 IP:端口 或 域名:端口！${NC}"
        return 1
    fi
}

# 添加转发规则
add_forward_rule() {
    local tool=$1
    local local_port=$2
    local remote_addr=$3
    local note=$4
    
    # 验证输入
    if ! validate_input "$local_port" "$remote_addr"; then
        return 1
    fi
    
    case $tool in
        realm|gost)
            config_file="$CONFIG_DIR/${tool}_rules.conf"
            if grep -q "^$local_port " "$config_file"; then
                echo -e "${RED}错误：端口 $local_port 的转发规则已存在！${NC}"
                return 1
            fi
            echo "$local_port $remote_addr" >> "$config_file"
            ;;
        *)
            echo -e "${RED}未知工具: $tool${NC}"
            return 1
            ;;
    esac
    
    # 添加备注
    if [ -n "$note" ]; then
        echo "$tool $local_port $remote_addr $note" >> "$NOTES_CONFIG"
    fi
    
    echo -e "${GREEN}成功添加 $tool 转发规则: 本地端口 $local_port -> $remote_addr${NC}"
    if [ -n "$note" ]; then
        echo -e "${CYAN}备注: $note${NC}"
    fi
}

# 删除转发规则
delete_forward_rule() {
    local tool=$1
    local local_port=$2
    
    case $tool in
        realm|gost)
            config_file="$CONFIG_DIR/${tool}_rules.conf"
            if ! grep -q "^$local_port " "$config_file"; then
                echo -e "${RED}错误：找不到端口 $local_port 的转发规则！${NC}"
                return 1
            fi
            sed -i "/^$local_port /d" "$config_file"
            sed -i "/^$tool $local_port /d" "$NOTES_CONFIG"
            ;;
        *)
            echo -e "${RED}未知工具: $tool${NC}"
            return 1
            ;;
    esac
    
    echo -e "${GREEN}已删除 $tool 端口 $local_port 的转发规则${NC}"
}

# 更新备注
update_note() {
    local tool=$1
    local local_port=$2
    local new_note=$3
    
    case $tool in
        realm|gost)
            config_file="$CONFIG_DIR/${tool}_rules.conf"
            if ! grep -q "^$local_port " "$config_file"; then
                echo -e "${RED}错误：找不到端口 $local_port 的转发规则！${NC}"
                return 1
            fi
            remote_addr=$(grep "^$local_port " "$config_file" | awk '{print $2}')
            sed -i "/^$tool $local_port /d" "$NOTES_CONFIG"
            if [ -n "$new_note" ]; then
                echo "$tool $local_port $remote_addr $new_note" >> "$NOTES_CONFIG"
                echo -e "${GREEN}已更新 $tool 端口 $local_port 的备注${NC}"
            fi
            ;;
        *)
            echo -e "${RED}未知工具: $tool${NC}"
            return 1
            ;;
    esac
}

# 生成Realm服务配置文件
generate_realm_service() {
    local config_file="$REALM_CONFIG"
    local cmd_args=""
    
    while read -r line; do
        local_port=$(echo "$line" | awk '{print $1}')
        remote_addr=$(echo "$line" | awk '{print $2}')
        
        # 解析域名
        remote_host=${remote_addr%:*}
        remote_port=${remote_addr##*:}
        if [[ ! "$remote_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            remote_host=$(resolve_domain "$remote_host") || return 1
            remote_addr="$remote_host:$remote_port"
        fi
        
        cmd_args+=" -l :$local_port -r $remote_addr"
    done < "$config_file"
    
    cat > /etc/systemd/system/realm.service <<EOF
[Unit]
Description=REALM Port Forwarding Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/realm$cmd_args
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

# 生成GOST服务配置文件
generate_gost_service() {
    local config_file="$GOST_CONFIG"
    local cmd_args=""
    
    while read -r line; do
        local_port=$(echo "$line" | awk '{print $1}')
        remote_addr=$(echo "$line" | awk '{print $2}')
        
        # 解析域名
        remote_host=${remote_addr%:*}
        remote_port=${remote_addr##*:}
        if [[ ! "$remote_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            remote_host=$(resolve_domain "$remote_host") || return 1
            remote_addr="$remote_host:$remote_port"
        fi
        
        cmd_args+=" -L=tcp://:$local_port/$remote_addr"
    done < "$config_file"
    
    cat > /etc/systemd/system/gost.service <<EOF
[Unit]
Description=GOST Port Forwarding Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/gost$cmd_args
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

# 配置服务
configure_services() {
    echo -e "${YELLOW}正在配置服务...${NC}"
    
    # 配置Realm
    if [ -s "$REALM_CONFIG" ]; then
        if ! generate_realm_service; then
            echo -e "${RED}Realm服务配置失败！${NC}"
            return 1
        fi
        systemctl daemon-reload
        systemctl enable realm.service
        echo -e "${GREEN}Realm服务配置完成！${NC}"
    fi
    
    # 配置GOST
    if [ -s "$GOST_CONFIG" ]; then
        if ! generate_gost_service; then
            echo -e "${RED}GOST服务配置失败！${NC}"
            return 1
        fi
        systemctl daemon-reload
        systemctl enable gost.service
        echo -e "${GREEN}GOST服务配置完成！${NC}"
    fi
}

# 启动服务
start_services() {
    for tool in realm gost; do
        if [ -f "/etc/systemd/system/${tool}.service" ]; then
            echo -e "${YELLOW}正在启动${tool}服务...${NC}"
            systemctl start ${tool}.service
            if systemctl is-active --quiet ${tool}.service; then
                echo -e "${GREEN}${tool}服务启动成功！${NC}"
            else
                echo -e "${RED}${tool}服务启动失败！${NC}"
                journalctl -u ${tool}.service -n 10 --no-pager
            fi
        fi
    done
}

# 显示所有转发规则
show_all_rules() {
    echo -e "\n${BLUE}====== 所有转发规则 ======${NC}"
    
    for tool in realm gost; do
        config_file="$CONFIG_DIR/${tool}_rules.conf"
        if [ -s "$config_file" ]; then
            echo -e "\n${PURPLE}${tool^^} 转发规则:${NC}"
            while read -r line; do
                local_port=$(echo "$line" | awk '{print $1}')
                remote_addr=$(echo "$line" | awk '{print $2}')
                note=$(grep "^$tool $local_port " "$NOTES_CONFIG" | cut -d' ' -f4-)
                
                echo -e "本地端口: ${GREEN}$local_port${NC} -> 远程地址: ${GREEN}$remote_addr${NC}"
                [ -n "$note" ] && echo -e "备注: ${CYAN}$note${NC}"
                echo "------------------------"
            done < "$config_file"
        else
            echo -e "\n${YELLOW}没有配置${tool^^}转发规则${NC}"
        fi
    done
}

# 显示服务状态
show_service_status() {
    echo -e "\n${BLUE}====== 服务状态 ======${NC}"
    for tool in realm gost; do
        if [ -f "/etc/systemd/system/${tool}.service" ]; then
            echo -e "\n${YELLOW}${tool^^} 服务状态:${NC}"
            systemctl status ${tool}.service --no-pager -l
        fi
    done
    
    echo -e "\n${BLUE}====== 监听端口 ======${NC}"
    netstat -tulnp | grep -E "realm|gost"
}

# 主菜单
main_menu() {
    while true; do
        echo -e "\n${BLUE}====== Realm & GOST 管理脚本 ======${NC}"
        echo "1) 安装转发工具"
        echo "2) 添加转发规则"
        echo "3) 删除转发规则"
        echo "4) 更新规则备注"
        echo "5) 查看所有规则"
        echo "6) 查看服务状态"
        echo "7) 启动所有服务"
        echo "8) 停止所有服务"
        echo "9) 重启所有服务"
        echo "10) 卸载所有服务"
        echo "0) 退出"
        read -p "请输入选项(0-10): " choice
        
        case $choice in
            1) check_root; check_system; install_dependencies; init_config_dir; install_realm; install_gost ;;
            2) add_rule_menu ;;
            3) delete_rule_menu ;;
            4) update_note_menu ;;
            5) show_all_rules ;;
            6) show_service_status ;;
            7) start_services ;;
            8) systemctl stop realm.service gost.service 2>/dev/null; echo -e "${GREEN}已停止所有服务${NC}" ;;
            9) systemctl restart realm.service gost.service 2>/dev/null; echo -e "${GREEN}已重启所有服务${NC}" ;;
            10) uninstall_services ;;
            0) echo -e "${GREEN}退出脚本。${NC}"; exit 0 ;;
            *) echo -e "${RED}无效选项！${NC}" ;;
        esac
        
        read -p "按Enter键继续..."
        clear
    done
}

# 卸载服务
uninstall_services() {
    read -p "确定要卸载Realm和GOST吗？(y/n): " confirm
    if [ "$confirm" != "y" ]; then return; fi
    
    systemctl stop realm.service gost.service 2>/dev/null
    systemctl disable realm.service gost.service 2>/dev/null
    rm -f /etc/systemd/system/{realm,gost}.service
    rm -f /usr/local/bin/{realm,gost}
    rm -rf "$CONFIG_DIR"
    systemctl daemon-reload
    echo -e "${GREEN}已卸载Realm和GOST及相关配置！${NC}"
}

# 添加规则菜单
add_rule_menu() {
    echo -e "\n${BLUE}====== 添加转发规则 ======${NC}"
    echo "1) 添加Realm转发规则"
    echo "2) 添加GOST转发规则"
    echo "0) 返回主菜单"
    read -p "请选择操作(0-2): " choice
    
    case $choice in
        1|2)
            tool=$([ "$choice" -eq 1 ] && echo "realm" || echo "gost")
            while true; do
                read -p "请输入本地监听端口: " local_port
                read -p "请输入远程目标地址(格式: IP或域名:端口): " remote_addr
                if validate_input "$local_port" "$remote_addr"; then break; fi
            done
            read -p "请输入备注(可选): " note
            add_forward_rule "$tool" "$local_port" "$remote_addr" "$note"
            configure_services
            start_services
            ;;
        0) return ;;
        *) echo -e "${RED}无效选择！${NC}" ;;
    esac
}

# 删除规则菜单
delete_rule_menu() {
    echo -e "\n${BLUE}====== 删除转发规则 ======${NC}"
    echo "1) 删除Realm转发规则"
    echo "2) 删除GOST转发规则"
    echo "0) 返回主菜单"
    read -p "请选择操作(0-2): " choice
    
    case $choice in
        1|2)
            tool=$([ "$choice" -eq 1 ] && echo "realm" || echo "gost")
            read -p "请输入要删除的本地端口: " local_port
            delete_forward_rule "$tool" "$local_port"
            configure_services
            systemctl restart "$tool.service" 2>/dev/null
            ;;
        0) return ;;
        *) echo -e "${RED}无效选择！${NC}" ;;
    esac
}

# 更新备注菜单
update_note_menu() {
    echo -e "\n${BLUE}====== 更新备注 ======${NC}"
    echo "1) 更新Realm规则备注"
    echo "2) 更新GOST规则备注"
    echo "0) 返回主菜单"
    read -p "请选择操作(0-2): " choice
    
    case $choice in
        1|2)
            tool=$([ "$choice" -eq 1 ] && echo "realm" || echo "gost")
            read -p "请输入本地端口: " local_port
            read -p "请输入新备注: " new_note
            update_note "$tool" "$local_port" "$new_note"
            ;;
        0) return ;;
        *) echo -e "${RED}无效选择！${NC}" ;;
    esac
}

# 主函数
main() {
    check_root
    check_system
    init_config_dir
    main_menu
}

main
