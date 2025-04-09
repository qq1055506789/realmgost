#!/bin/bash

# 增强版 Realm & GOST 一键管理脚本
# 功能：支持多条转发规则、备注管理、状态查看
# 版本：v2.7
# 修改说明：
#   1. 修复GOST域名解析问题（启动时预解析为IP）
#   2. 统一Realm和GOST的地址处理逻辑
#   3. 增强错误处理和日志提示
#   4. 添加临时文件清理
#   5. 使用 ss 替代 netstat
#   6. 改进服务配置逻辑（空配置时停止并禁用服务）
#   7. 移除不必要的错误抑制

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
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        SYSTEM=$ID
    elif type lsb_release >/dev/null 2>&1; then
        SYSTEM=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
    elif [ -f /etc/lsb-release ]; then
        . /etc/lsb-release
        SYSTEM=$DISTRIB_ID | tr '[:upper:]' '[:lower:]'
    elif [ -f /etc/debian_version ]; then
        SYSTEM="debian"
    elif [ -f /etc/redhat-release ]; then
        SYSTEM="centos" # 或考虑更具体的如 fedora
    else
        SYSTEM=$(uname -s | tr '[:upper:]' '[:lower:]')
    fi

    case "$SYSTEM" in
        ubuntu|debian)
            PKG_MANAGER="apt-get"
            DNS_UTILS="dnsutils"
            IP_ROUTE_PKG="iproute2"
            ;;
        centos|rhel|fedora)
            PKG_MANAGER="yum"
            if [ -f /usr/bin/dnf ]; then
                PKG_MANAGER="dnf"
            fi
            DNS_UTILS="bind-utils"
            IP_ROUTE_PKG="iproute"
            ;;
        *)
            echo -e "${RED}不支持的系统: $SYSTEM！请手动安装依赖。${NC}"
            # 尝试继续，但可能失败
            PKG_MANAGER="echo" # 防止后续命令出错
            DNS_UTILS="dnsutils"
            IP_ROUTE_PKG="iproute2"
            ;;
    esac
}

# 安装依赖
install_dependencies() {
    echo -e "${YELLOW}正在安装必要依赖...${NC}"
    if [ "$PKG_MANAGER" = "apt-get" ]; then
        $PKG_MANAGER update
    fi
    $PKG_MANAGER install -y wget unzip curl tar jq $DNS_UTILS $IP_ROUTE_PKG

    local missing_deps=()
    command -v wget &> /dev/null || missing_deps+=("wget")
    command -v jq &> /dev/null || missing_deps+=("jq")
    command -v dig &> /dev/null || missing_deps+=("dig ($DNS_UTILS)")
    command -v ss &> /dev/null || missing_deps+=("ss ($IP_ROUTE_PKG)")

    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo -e "${RED}以下依赖安装失败或未找到，请手动安装后重试: ${missing_deps[*]}${NC}"
        exit 1
    fi
    echo -e "${GREEN}依赖安装完成。${NC}"
}

# 初始化配置目录
init_config_dir() {
    mkdir -p "$CONFIG_DIR"
    touch "$REALM_CONFIG" "$GOST_CONFIG" "$NOTES_CONFIG"
    chmod 600 "$REALM_CONFIG" "$GOST_CONFIG" "$NOTES_CONFIG"
}

# 清理临时文件
cleanup_temp_files() {
    rm -f /tmp/realm.tar.gz /tmp/realm /tmp/gost.tar.gz /tmp/gost_*
    # 尝试删除可能的解压目录
    find /tmp -maxdepth 1 -name "gost_*" -type d -exec rm -rf {} + 2>/dev/null
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
        cleanup_temp_files
        exit 1
    fi

    local download_url="https://github.com/zhboner/realm/releases/download/${latest_version}/realm-x86_64-unknown-linux-gnu.tar.gz"

    echo "正在下载: $download_url"
    if ! wget --progress=bar:force -O /tmp/realm.tar.gz "$download_url" 2>&1 | grep --line-buffered "%" | sed -u -e "s,\.,,g" | awk '{printf("\b\b\b\b%4s", $2)}'; then
        echo -e "\n${RED}下载Realm失败！${NC}"
        cleanup_temp_files
        exit 1
    fi
    echo -e "\n下载完成。"

    echo "正在解压..."
    if ! tar -xzf /tmp/realm.tar.gz -C /tmp; then
        echo -e "${RED}解压Realm失败！${NC}"
        cleanup_temp_files
        exit 1
    fi

    mv /tmp/realm /usr/local/bin/realm
    chmod +x /usr/local/bin/realm

    if ! command -v realm &> /dev/null; then
        echo -e "${RED}Realm安装失败！${NC}"
        cleanup_temp_files
        exit 1
    fi

    cleanup_temp_files
    echo -e "${GREEN}Realm安装成功！版本: $latest_version${NC}"
}

# 安装GOST
install_gost() {
    if command -v gost &> /dev/null; then
        echo -e "${YELLOW}GOST 已安装，跳过安装步骤。${NC}"
        return
    fi

    echo -e "${YELLOW}正在安装GOST...${NC}"
    # 尝试从API获取直接的下载链接
    local release_info=$(curl -s https://api.github.com/repos/ginuerzh/gost/releases/latest)
    local latest_version=$(echo "$release_info" | grep 'tag_name' | cut -d\" -f4)

    if [ -z "$latest_version" ]; then
        echo -e "${RED}无法获取GOST最新版本！${NC}"
        cleanup_temp_files
        exit 1
    fi

    local arch=$(uname -m)
    case $arch in
        x86_64) arch_suffix="amd64" ;;
        aarch64) arch_suffix="arm64" ;;
        *) echo -e "${RED}不支持的架构: $arch${NC}"; cleanup_temp_files; exit 1 ;;
    esac

    local download_url=$(echo "$release_info" | jq -r ".assets[] | select(.name | contains(\"linux_${arch_suffix}.tar.gz\")) | .browser_download_url")

    if [ -z "$download_url" ]; then
        # 如果API没有直接链接，则回退到拼接URL
        echo -e "${YELLOW}无法从API获取直接下载链接，尝试拼接URL...${NC}"
        download_url="https://github.com/ginuerzh/gost/releases/download/${latest_version}/gost-linux-${arch_suffix}-${latest_version#v}.tar.gz"
        # 检查另一种可能的命名格式
        if ! curl -s --head "$download_url" | head -n 1 | grep "200 OK" > /dev/null; then
             download_url="https://github.com/ginuerzh/gost/releases/download/${latest_version}/gost_${latest_version#v}_linux_${arch_suffix}.tar.gz"
        fi
    fi


    echo "正在下载: $download_url"
    if ! wget --progress=bar:force -O /tmp/gost.tar.gz "$download_url" 2>&1 | grep --line-buffered "%" | sed -u -e "s,\.,,g" | awk '{printf("\b\b\b\b%4s", $2)}'; then
        echo -e "\n${RED}下载GOST失败！尝试的URL: $download_url ${NC}"
        cleanup_temp_files
        exit 1
    fi
     echo -e "\n下载完成。"

    echo "正在解压..."
    if ! tar -xzf /tmp/gost.tar.gz -C /tmp; then
         echo -e "${RED}解压GOST失败！${NC}"
         cleanup_temp_files
         exit 1
    fi

    # 查找解压后的gost可执行文件
    local gost_executable=$(find /tmp -maxdepth 2 -name gost -type f -executable 2>/dev/null | head -n 1)

    if [ -z "$gost_executable" ]; then
        echo -e "${RED}无法在解压文件中找到GOST可执行文件！${NC}"
        cleanup_temp_files
        exit 1
    fi

    mv "$gost_executable" /usr/local/bin/gost
    chmod +x /usr/local/bin/gost

    if ! command -v gost &> /dev/null; then
        echo -e "${RED}GOST安装失败！${NC}"
        cleanup_temp_files
        exit 1
    fi

    cleanup_temp_files
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
    local local_port_to_update=$2 # Renamed to avoid conflict with loop var
    local new_note=$3
    local found_rule=0
    local remote_addr=""

    case $tool in
        realm|gost)
            config_file="$CONFIG_DIR/${tool}_rules.conf"
            temp_notes_file=$(mktemp) # Create a temporary file for notes

            # Read the config file to find the remote address for the given port
            while IFS= read -r line || [[ -n "$line" ]]; do
                [[ -z "$line" || "$line" =~ ^\s*# ]] && continue
                local current_port current_remote rest
                read -r current_port current_remote rest <<< "$line"
                if [[ "$current_port" == "$local_port_to_update" ]]; then
                    remote_addr="$current_remote"
                    found_rule=1
                    break # Found the rule, no need to read further
                fi
            done < "$config_file"

            if [ $found_rule -eq 0 ]; then
                echo -e "${RED}错误：在 ${config_file} 中找不到端口 $local_port_to_update 的 ${tool^^} 转发规则！${NC}"
                rm -f "$temp_notes_file"
                return 1
            fi

            # Process the notes file, excluding the old note for the target rule
            if [ -f "$NOTES_CONFIG" ]; then
                 while IFS= read -r note_line || [[ -n "$note_line" ]]; do
                     local note_tool note_port rest_of_note
                     read -r note_tool note_port rest_of_note <<< "$note_line"
                     # Keep notes that don't match the tool and port being updated
                     if [[ "$note_tool" != "$tool" || "$note_port" != "$local_port_to_update" ]]; then
                         echo "$note_line" >> "$temp_notes_file"
                     fi
                 done < "$NOTES_CONFIG"
            fi

            # Add the new note if provided
            if [ -n "$new_note" ]; then
                echo "$tool $local_port_to_update $remote_addr $new_note" >> "$temp_notes_file"
            fi

            # Replace the old notes file with the temporary one
            # Use cat and redirect to handle potential permission issues with mv
            cat "$temp_notes_file" > "$NOTES_CONFIG"
            rm -f "$temp_notes_file"
            chmod 600 "$NOTES_CONFIG" # Ensure permissions are correct

            if [ -n "$new_note" ]; then
                 echo -e "${GREEN}已更新 $tool 端口 $local_port_to_update 的备注${NC}"
            else
                 echo -e "${GREEN}已删除 $tool 端口 $local_port_to_update 的备注${NC}"
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
    local service_file="/etc/systemd/system/realm.service"

    if [ ! -s "$config_file" ]; then
        echo -e "${YELLOW}Realm配置文件为空或不存在，将停止并禁用服务。${NC}"
        if systemctl is-active --quiet realm.service; then
            systemctl stop realm.service
        fi
        if systemctl is-enabled --quiet realm.service; then
            systemctl disable realm.service
        fi
        rm -f "$service_file"
        systemctl daemon-reload
        return 0 # 不是错误，是预期行为
    fi


    local cmd_args=""
    local has_error=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        # 跳过空行或注释行
        [[ -z "$line" || "$line" =~ ^\s*# ]] && continue

        # 使用 read 替代 awk
        local local_port remote_addr rest
        read -r local_port remote_addr rest <<< "$line"

        # 验证一下读取的数据是否有效
        if [ -z "$local_port" ] || [ -z "$remote_addr" ]; then
             echo -e "${YELLOW}警告：跳过配置文件中的无效行: '$line'${NC}"
             continue
        fi


        # 解析域名
        local remote_host=${remote_addr%:*}
        local remote_port=${remote_addr##*:}
        if [[ ! "$remote_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            local resolved_ip=$(resolve_domain "$remote_host")
            if [ $? -ne 0 ]; then
                 echo -e "${RED}错误：无法解析Realm规则中的域名 '$remote_host' (来自行: '$line')。请检查网络或域名。${NC}"
                 has_error=1
                 continue # 跳过此规则，但标记错误
            fi
            remote_addr="$resolved_ip:$remote_port"
        fi

        cmd_args+=" -l :$local_port -r $remote_addr"
    done < "$config_file"

    if [ $has_error -eq 1 ]; then
        echo -e "${RED}由于域名解析错误，Realm服务配置未完成或部分完成。${NC}"
        return 1
    fi

    if [ -z "$cmd_args" ]; then
        echo -e "${YELLOW}没有有效的Realm规则生成，将停止并禁用服务。${NC}"
        if systemctl is-active --quiet realm.service; then
            systemctl stop realm.service
        fi
        if systemctl is-enabled --quiet realm.service; then
            systemctl disable realm.service
        fi
        rm -f "$service_file"
        systemctl daemon-reload
        return 0
    fi


    cat > "$service_file" <<EOF
[Unit]
Description=REALM Port Forwarding Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/realm$cmd_args
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

   chmod 644 "$service_file"
   echo -e "${GREEN}Realm服务文件已生成/更新。${NC}"
   return 0
}

# 生成GOST服务配置文件
generate_gost_service() {
    local config_file="$GOST_CONFIG"
    local service_file="/etc/systemd/system/gost.service"

    if [ ! -s "$config_file" ]; then
        echo -e "${YELLOW}GOST配置文件为空或不存在，将停止并禁用服务。${NC}"
        if systemctl is-active --quiet gost.service; then
            systemctl stop gost.service
        fi
        if systemctl is-enabled --quiet gost.service; then
            systemctl disable gost.service
        fi
        rm -f "$service_file"
        systemctl daemon-reload
        return 0
    fi

    local cmd_args=""
    local has_error=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" =~ ^\s*# ]] && continue

        # 使用 read 替代 awk
        local local_port remote_addr rest
        read -r local_port remote_addr rest <<< "$line"

        if [ -z "$local_port" ] || [ -z "$remote_addr" ]; then
             echo -e "${YELLOW}警告：跳过配置文件中的无效行: '$line'${NC}"
             continue
        fi

        # 解析域名
        local remote_host=${remote_addr%:*}
        local remote_port=${remote_addr##*:}
        if [[ ! "$remote_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            local resolved_ip=$(resolve_domain "$remote_host")
            if [ $? -ne 0 ]; then
                echo -e "${RED}错误：无法解析GOST规则中的域名 '$remote_host' (来自行: '$line')。请检查网络或域名。${NC}"
                has_error=1
                continue
            fi
            remote_addr="$resolved_ip:$remote_port"
        fi

        cmd_args+=" -L=tcp://:$local_port/$remote_addr"
    done < "$config_file"

    if [ $has_error -eq 1 ]; then
        echo -e "${RED}由于域名解析错误，GOST服务配置未完成或部分完成。${NC}"
        return 1
    fi

    if [ -z "$cmd_args" ]; then
        echo -e "${YELLOW}没有有效的GOST规则生成，将停止并禁用服务。${NC}"
        if systemctl is-active --quiet gost.service; then
            systemctl stop gost.service
        fi
        if systemctl is-enabled --quiet gost.service; then
            systemctl disable gost.service
        fi
        rm -f "$service_file"
        systemctl daemon-reload
        return 0
    fi

    cat > "$service_file" <<EOF
[Unit]
Description=GOST Port Forwarding Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/gost$cmd_args
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "$service_file"
    echo -e "${GREEN}GOST服务文件已生成/更新。${NC}"
    return 0
}

# 配置服务
configure_services() {
    echo -e "${YELLOW}正在配置服务...${NC}"
    local realm_success=0
    local gost_success=0
    local reload_needed=0

    # 配置Realm
    if generate_realm_service; then
        if [ -f /etc/systemd/system/realm.service ]; then
            systemctl enable realm.service
            echo -e "${GREEN}Realm服务配置完成！${NC}"
            realm_success=1
            reload_needed=1
        else
            echo -e "${YELLOW}Realm服务未配置（无规则或已被移除）。${NC}"
            realm_success=1 # 认为成功，因为是预期操作
        fi
    else
        echo -e "${RED}Realm服务配置失败！${NC}"
    fi

    # 配置GOST
    if generate_gost_service; then
         if [ -f /etc/systemd/system/gost.service ]; then
            systemctl enable gost.service
            echo -e "${GREEN}GOST服务配置完成！${NC}"
            gost_success=1
            reload_needed=1
        else
            echo -e "${YELLOW}GOST服务未配置（无规则或已被移除）。${NC}"
            gost_success=1 # 认为成功
        fi
    else
        echo -e "${RED}GOST服务配置失败！${NC}"
    fi

    if [ $reload_needed -eq 1 ]; then
        systemctl daemon-reload
    fi

    # 如果任一配置失败，则返回错误
    if [ $realm_success -eq 0 ] || [ $gost_success -eq 0 ]; then
        return 1
    else
        return 0
    fi
}

# 启动服务
start_services() {
    local success=1
    for tool in realm gost; do
        if [ -f "/etc/systemd/system/${tool}.service" ]; then
            echo -e "${YELLOW}正在启动 ${tool} 服务...${NC}"
            if systemctl start ${tool}.service; then
                # 短暂等待确认服务是否稳定启动
                sleep 1
                if systemctl is-active --quiet ${tool}.service; then
                    echo -e "${GREEN}${tool} 服务启动成功！${NC}"
                else
                    echo -e "${RED}${tool} 服务启动后未能保持活动状态！请检查日志。${NC}"
                    journalctl -u ${tool}.service -n 10 --no-pager
                    success=0
                fi
            else
                echo -e "${RED}${tool} 服务启动命令执行失败！${NC}"
                journalctl -u ${tool}.service -n 10 --no-pager
                success=0
            fi
        elif [ -s "$CONFIG_DIR/${tool}_rules.conf" ]; then
             # 如果有规则但服务文件不存在，说明配置阶段可能出错了
             echo -e "${YELLOW}警告：${tool} 有规则但服务文件不存在，可能配置失败。${NC}"
        fi
    done
    return $success
}

# 显示所有转发规则
show_all_rules() {
    echo -e "\n${BLUE}====== 所有转发规则 ======${NC}"

    for tool in realm gost; do
        config_file="$CONFIG_DIR/${tool}_rules.conf"
        if [ -s "$config_file" ]; then
            echo -e "\n${PURPLE}${tool^^} 转发规则:${NC}"
            while IFS= read -r line || [[ -n "$line" ]]; do # Handle last line without newline
                 [[ -z "$line" || "$line" =~ ^\s*# ]] && continue

                # 使用 read 替代 awk
                local local_port remote_addr rest
                read -r local_port remote_addr rest <<< "$line"

                # 检查是否成功读取到端口和地址
                if [ -z "$local_port" ] || [ -z "$remote_addr" ]; then
                     echo -e "${YELLOW}警告：跳过配置文件中的格式错误行: '$line'${NC}"
                     continue
                fi

                # 查找备注 - 使用 grep 仍然是查找备注较简单的方式
                # 但确保 grep 查找的是以 tool 和 port 开头的行
                local note=""
                if [ -f "$NOTES_CONFIG" ]; then
                    note=$(grep "^$tool $local_port " "$NOTES_CONFIG" | sed -e "s/^$tool $local_port $remote_addr //" -e "s/^$tool $local_port [^ ]* //") # 移除前缀以获取备注
                fi

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
        else
             echo -e "\n${YELLOW}${tool^^} 服务未配置或已移除。${NC}"
        fi
    done

    echo -e "\n${BLUE}====== 监听端口 (TCP/UDP) ======${NC}"
    # 使用 ss 替代 netstat，更现代且通常默认安装
    if command -v ss &> /dev/null; then
        ss -tulnp | grep -E 'realm|gost' || echo -e "${YELLOW}未检测到 Realm 或 GOST 监听端口。${NC}"
    else
        echo -e "${RED}错误：无法找到 'ss' 命令。无法检查监听端口。${NC}"
    fi
}

# 主菜单
main_menu() {
    while true; do
        # 清屏前先显示菜单，防止用户输入时界面跳动
        clear
        echo -e "\n${BLUE}====== Realm & GOST 管理脚本 (v2.7) ======${NC}"
        echo "1) 安装/更新 转发工具"
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
            7)
                echo "正在尝试启动所有服务..."
                if start_services; then
                     echo -e "${GREEN}所有可配置的服务已尝试启动。${NC}"
                else
                     echo -e "${RED}部分服务启动失败，请检查上面的日志。${NC}"
                fi
                ;;
            8)
                echo "正在停止 Realm 服务..."
                systemctl stop realm.service
                echo "正在停止 GOST 服务..."
                systemctl stop gost.service
                echo -e "${GREEN}已尝试停止所有服务 (如果存在)。${NC}"
                ;;
            9)
                echo "正在重启 Realm 服务..."
                systemctl restart realm.service
                echo "正在重启 GOST 服务..."
                systemctl restart gost.service
                 # 短暂等待确认服务是否稳定
                sleep 1
                echo -e "${GREEN}已尝试重启所有服务 (如果存在)。${NC}"
                # 可以选择性地添加状态检查
                show_service_status
                ;;
            10) uninstall_services ;;
            0) echo -e "${GREEN}退出脚本。${NC}"; exit 0 ;;
            *) echo -e "${RED}无效选项！${NC}" ;;
        esac

        # 在循环末尾等待用户确认，而不是在 case 内部
        echo # 添加一个空行增加可读性
        read -n 1 -s -r -p "按任意键继续..."
        # 不需要 clear，因为循环开始时会清屏
    done
}

# 卸载服务
uninstall_services() {
    read -p "确定要卸载Realm和GOST及其配置文件吗？这将删除所有规则！(y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${YELLOW}操作已取消。${NC}"
        return
    fi

    echo "正在停止服务..."
    systemctl stop realm.service gost.service

    echo "正在禁用服务..."
    systemctl disable realm.service gost.service

    echo "正在删除服务文件..."
    rm -f /etc/systemd/system/realm.service /etc/systemd/system/gost.service

    echo "正在删除可执行文件..."
    rm -f /usr/local/bin/realm /usr/local/bin/gost

    echo "正在删除配置文件目录..."
    rm -rf "$CONFIG_DIR"

    echo "正在重载 systemd..."
    systemctl daemon-reload

    echo "正在清理临时文件 (以防万一)..."
    cleanup_temp_files

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
            # 添加规则后，重新配置并启动服务
            echo "正在应用配置..."
            if configure_services; then
                echo "正在启动/重启相关服务..."
                if start_services; then
                    echo -e "${GREEN}服务配置和启动完成。${NC}"
                else
                    echo -e "${RED}服务配置完成但启动失败，请检查日志。${NC}"
                fi
            else
                echo -e "${RED}服务配置失败，请检查错误信息。服务可能未运行或配置不正确。${NC}"
            fi
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
            # 先尝试删除规则
            if delete_forward_rule "$tool" "$local_port"; then
                # 删除成功后，重新配置并尝试重启
                echo "正在应用配置..."
                if configure_services; then
                    echo "正在尝试重启 ${tool} 服务 (如果仍然存在)..."
                    # 检查服务文件是否存在，因为configure_services可能已将其删除
                    if [ -f "/etc/systemd/system/${tool}.service" ]; then
                         if systemctl restart "${tool}.service"; then
                              echo -e "${GREEN}${tool} 服务已重启。${NC}"
                         else
                              echo -e "${RED}${tool} 服务重启失败！请检查日志。${NC}"
                              journalctl -u ${tool}.service -n 10 --no-pager
                         fi
                    else
                         echo -e "${YELLOW}${tool} 服务已被禁用或移除（因为没有剩余规则）。${NC}"
                    fi
                else
                     echo -e "${RED}应用配置失败！请检查之前的错误。${NC}"
                fi
            else
                # 删除规则失败（例如端口不存在）
                echo -e "${YELLOW}删除规则操作未执行或失败，未更改服务状态。${NC}"
            fi
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
            read -p "请输入需要更新备注的本地端口: " local_port

            # 检查规则是否存在
            config_file="$CONFIG_DIR/${tool}_rules.conf"
            if ! grep -q "^$local_port " "$config_file"; then
                echo -e "${RED}错误：找不到端口 $local_port 的 ${tool^^} 转发规则！${NC}"
                return # 直接返回，不继续执行
            fi

            read -p "请输入新的备注 (留空则删除备注): " new_note
            update_note "$tool" "$local_port" "$new_note"
            # 更新备注不需要重启服务，所以这里不需要调用 configure_services 或 restart
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
