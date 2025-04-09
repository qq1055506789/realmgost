#!/bin/bash

# Lee增强版 Realm & GOST 一键管理脚本
# 功能：支持多条转发规则、备注管理、状态查看
# 版本：v2.1
# 修改说明：更新Realm下载地址为 x86_64-unknown-linux-gnu 格式

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
        yum install -y wget unzip curl tar jq
    else
        apt-get update
        apt-get install -y wget unzip curl tar jq
    fi
    
    if ! command -v wget &> /dev/null || ! command -v jq &> /dev/null; then
        echo -e "${RED}依赖安装失败，请手动安装wget和jq后重试！${NC}"
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
    
    # 修改为 x86_64-unknown-linux-gnu 格式下载地址
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
        x86_64)
            arch="amd64"
            ;;
        aarch64)
            arch="arm64"
            ;;
        *)
            echo -e "${RED}不支持的架构: $arch${NC}"
            exit 1
            ;;
    esac
    
    local download_url="https://github.com/ginuerzh/gost/releases/download/${latest_version}/gost-linux-${arch}-${latest_version}.gz"
    
    if ! wget -O /tmp/gost.gz "$download_url"; then
        echo -e "${RED}下载GOST失败！${NC}"
        exit 1
    fi
    
    gzip -d /tmp/gost.gz
    mv /tmp/gost /usr/local/bin/gost
    chmod +x /usr/local/bin/gost
    
    if ! command -v gost &> /dev/null; then
        echo -e "${RED}GOST安装失败！${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}GOST安装成功！版本: $latest_version${NC}"
}

# 其余函数保持不变（add_forward_rule、delete_forward_rule、configure_services等）
# ...（保持原有函数不变）...

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
            1)
                check_root
                check_system
                install_dependencies
                init_config_dir
                install_realm
                install_gost
                ;;
            2)
                add_rule_menu
                ;;
            3)
                delete_rule_menu
                ;;
            4)
                update_note_menu
                ;;
            5)
                show_all_rules
                ;;
            6)
                show_service_status
                ;;
            7)
                start_services
                ;;
            8)
                systemctl stop realm.service 2>/dev/null
                systemctl stop gost.service 2>/dev/null
                echo -e "${GREEN}已停止所有服务${NC}"
                ;;
            9)
                systemctl restart realm.service 2>/dev/null
                systemctl restart gost.service 2>/dev/null
                echo -e "${GREEN}已重启所有服务${NC}"
                ;;
            10)
                read -p "确定要卸载Realm和GOST吗？(y/n): " confirm
                if [ "$confirm" = "y" ]; then
                    systemctl stop realm.service 2>/dev/null
                    systemctl stop gost.service 2>/dev/null
                    systemctl disable realm.service 2>/dev/null
                    systemctl disable gost.service 2>/dev/null
                    rm -f /etc/systemd/system/realm.service
                    rm -f /etc/systemd/system/gost.service
                    rm -f /usr/local/bin/realm
                    rm -f /usr/local/bin/gost
                    rm -rf "$CONFIG_DIR"
                    systemctl daemon-reload
                    echo -e "${GREEN}已卸载Realm和GOST及相关配置！${NC}"
                fi
                ;;
            0)
                echo -e "${GREEN}退出脚本。${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选项！${NC}"
                ;;
        esac
        
        read -p "按Enter键继续..."
        clear
    done
}

# 主函数
main() {
    check_root
    check_system
    init_config_dir
    main_menu
}

main
