#!/bin/bash

# ==========================================
# Linux 端口限速工具 (循环菜单 + Bug修复版)
# ==========================================

CONFIG_DIR="/etc/port-limit"
CONFIG_FILE="$CONFIG_DIR/settings.conf"
LOG_FILE="$CONFIG_DIR/port-limit.log"
MARK=10

# 自动获取网卡
INTERFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5; exit}')
[ -z "$INTERFACE" ] && INTERFACE="eth0"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# --- 基础函数 ---

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误: 必须使用 Root 权限运行${PLAIN}"
        exit 1
    fi
}

check_dependencies() {
    local missing=()
    [ ! -x "$(command -v tc)" ] && missing+=("iproute2")
    [ ! -x "$(command -v iptables)" ] && missing+=("iptables")
    
    if [ ${#missing[@]} -ne 0 ]; then
        if [ -x "$(command -v apt)" ]; then apt update && apt install -y "${missing[@]}"; 
        elif [ -x "$(command -v yum)" ]; then yum install -y "${missing[@]}"; 
        else echo "请手动安装: ${missing[*]}"; exit 1; fi
    fi
}

init_config() {
    mkdir -p "$CONFIG_DIR"
    touch "$LOG_FILE"
}

validate_number() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -gt 0 ]
}

# 暂停并按回车继续
pause() {
    echo ""
    read -p "按回车键返回主菜单..."
}

# --- 核心逻辑 ---

remove_rules() {
    local quiet=$1
    # 临时读取旧配置来删除规则，使用局部变量避免污染全局
    if [ -f "$CONFIG_FILE" ]; then
        # 仅读取 PORTS 变量，不 source 整个文件，防止覆盖
        local OLD_PORTS=$(grep "^PORTS=" "$CONFIG_FILE" | cut -d'=' -f2)
        
        if [ -n "$OLD_PORTS" ]; then
            IFS=',' read -ra PORT_ARR <<< "$OLD_PORTS"
            for PORT in "${PORT_ARR[@]}"; do
                iptables -t mangle -D OUTPUT -o "$INTERFACE" -p tcp --sport "$PORT" -j MARK --set-mark $MARK 2>/dev/null
                iptables -t mangle -D OUTPUT -o "$INTERFACE" -p udp --sport "$PORT" -j MARK --set-mark $MARK 2>/dev/null
                if [ -x "$(command -v ip6tables)" ]; then
                    ip6tables -t mangle -D OUTPUT -o "$INTERFACE" -p tcp --sport "$PORT" -j MARK --set-mark $MARK 2>/dev/null
                    ip6tables -t mangle -D OUTPUT -o "$INTERFACE" -p udp --sport "$PORT" -j MARK --set-mark $MARK 2>/dev/null
                fi
            done
        fi
    fi
    tc qdisc del dev "$INTERFACE" root 2>/dev/null
    [ "$quiet" != "quiet" ] && log "旧规则已清理"
}

add_firewall_rules() {
    local port=$1
    iptables -t mangle -A OUTPUT -o "$INTERFACE" -p tcp --sport "$port" -j MARK --set-mark $MARK
    iptables -t mangle -A OUTPUT -o "$INTERFACE" -p udp --sport "$port" -j MARK --set-mark $MARK
    if [ -f /proc/net/if_inet6 ] && [ -x "$(command -v ip6tables)" ]; then
        ip6tables -t mangle -A OUTPUT -o "$INTERFACE" -p tcp --sport "$port" -j MARK --set-mark $MARK 2>/dev/null
        ip6tables -t mangle -A OUTPUT -o "$INTERFACE" -p udp --sport "$port" -j MARK --set-mark $MARK 2>/dev/null
    fi
}

set_limit() {
    echo -e "${YELLOW}提示：设置将覆盖旧规则。${PLAIN}"
    read -p "请输入端口 (逗号分隔): " INPUT_PORTS
    [ -z "$INPUT_PORTS" ] && return
    
    # 使用明确的变量名 INPUT_MB
    read -p "请输入限制速率 (单位 MB/s, 仅输入整数): " INPUT_MB
    if ! validate_number "$INPUT_MB"; then echo "数值无效"; return; fi
    
    # --- 计算区 ---
    local LIMIT_KB=$((INPUT_MB * 1024))
    local SHOW_MBPS=$((INPUT_MB * 8))
    
    # 将物理总带宽限制设为 1000MB/s (1Gbps)
    local PHY_LIMIT=$((1000 * 1024)) 
    
    # 清理旧规则 (此时不会再覆盖 INPUT_MB)
    remove_rules "quiet"
    
    # --- TC 规则区 ---
    
    # 1. Root
    tc qdisc add dev "$INTERFACE" root handle 1: htb default 30
    
    # 2. 主类 (1:1): 增加 quantum 200000 消除 "quantum is big" 警告
    tc class add dev "$INTERFACE" parent 1: classid 1:1 htb rate "${PHY_LIMIT}kbps" quantum 200000
    
    # 3. 限速类 (1:10): 目标端口
    tc class add dev "$INTERFACE" parent 1: classid 1:10 htb rate "${LIMIT_KB}kbps" ceil "${LIMIT_KB}kbps" burst 15k quantum 3000 prio 1
    
    # 4. 默认畅通类 (1:30): 其他端口
    tc class add dev "$INTERFACE" parent 1: classid 1:30 htb rate "${PHY_LIMIT}kbps" ceil "${PHY_LIMIT}kbps" burst 15k quantum 200000 prio 0
    
    # 5. 过滤器
    tc filter add dev "$INTERFACE" protocol ip parent 1:0 prio 1 handle $MARK fw flowid 1:10
    tc filter add dev "$INTERFACE" protocol ipv6 parent 1:0 prio 1 handle $MARK fw flowid 1:10 2>/dev/null

    # --- 防火墙区 ---
    IFS=',' read -ra PORT_ARR <<< "$INPUT_PORTS"
    for PORT in "${PORT_ARR[@]}"; do
        add_firewall_rules "$PORT"
    done
    
    # 保存配置
    cat > "$CONFIG_FILE" << EOF
PORTS=$INPUT_PORTS
LIMIT_MB=$INPUT_MB
EOF
    
    log "已限速: 端口 [$INPUT_PORTS] -> $INPUT_MB MB/s"
    echo -e "${GREEN}设置成功！${PLAIN}"
    echo -e "当前限制: ${YELLOW}$INPUT_MB MB/s${PLAIN} (相当于约 ${YELLOW}$SHOW_MBPS Mbps${PLAIN})"
    
    # 暂停
    pause
}

show_status() {
    echo -e "${YELLOW}--- 当前配置 ($INTERFACE) ---${PLAIN}"
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        echo "监听端口: $PORTS"
        local CUR_MBPS=$((LIMIT_MB * 8))
        echo "限制速率: $LIMIT_MB MB/s (约 $CUR_MBPS Mbps)"
    else
        echo "无配置文件"
    fi
    
    echo -e "\n${YELLOW}--- 流量统计 ---${PLAIN}"
    # 显示类 1:10 (限速类) 的信息
    tc -s class show dev "$INTERFACE" | grep -A 5 "class htb 1:10"
    
    echo -e "\n${YELLOW}--- 命中包数 (pkts) ---${PLAIN}"
    iptables -t mangle -L OUTPUT -v -n | grep "MARK set 0x$((MARK))"
    
    pause
}

clear_all() {
    remove_rules
    rm -f "$CONFIG_FILE"
    echo -e "${GREEN}已清除所有限制。${PLAIN}"
    pause
}

# --- 循环主菜单 ---
main() {
    check_root
    check_dependencies
    init_config
    
    while true; do
        clear
        echo "=================================="
        echo "    Linux 端口限速工具 (Pro)      "
        echo "    当前网卡: $INTERFACE          "
        echo "=================================="
        echo " 1. 设置/更新 端口限速 (MB/s)"
        echo " 2. 查看状态 (排查故障)"
        echo " 3. 清除限制"
        echo " 0. 退出"
        echo "=================================="
        read -p "请输入选项 [0-3]: " CHOICE
        
        case $CHOICE in
            1) set_limit ;;
            2) show_status ;;
            3) clear_all ;;
            0) exit 0 ;;
            *) echo "无效选项"; sleep 1 ;;
        esac
    done
}

main
