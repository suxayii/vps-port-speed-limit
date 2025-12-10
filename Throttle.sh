#!/bin/bash

# ==========================================
# Linux 端口限速工具 (MB/s 版 | IPv4+IPv6)
# ==========================================

# --- 配置区 ---
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
        echo -e "${YELLOW}正在安装依赖...${PLAIN}"
        if [ -x "$(command -v apt)" ]; then
            apt update && apt install -y "${missing[@]}"
        elif [ -x "$(command -v yum)" ]; then
            yum install -y "${missing[@]}"
        else
            echo -e "${RED}请手动安装: ${missing[*]}${PLAIN}"
            exit 1
        fi
    fi
}

init_config() {
    mkdir -p "$CONFIG_DIR"
    touch "$LOG_FILE"
}

validate_number() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -gt 0 ]
}

# --- 核心逻辑 ---

remove_rules() {
    local quiet=$1
    
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        if [ -n "$PORTS" ]; then
            IFS=',' read -ra PORT_ARR <<< "$PORTS"
            for PORT in "${PORT_ARR[@]}"; do
                # IPv4
                iptables -t mangle -D OUTPUT -o "$INTERFACE" -p tcp --sport "$PORT" -j MARK --set-mark $MARK 2>/dev/null
                iptables -t mangle -D OUTPUT -o "$INTERFACE" -p udp --sport "$PORT" -j MARK --set-mark $MARK 2>/dev/null
                
                # IPv6
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
    
    # === 修改点：单位改为 MB ===
    read -p "请输入限制速率 (单位 MB/s, 仅输入整数): " LIMIT_MB
    if ! validate_number "$LIMIT_MB"; then echo "数值无效"; return; fi
    
    # 转换为 KB (1 MB = 1024 KB)
    local LIMIT_KB=$((LIMIT_MB * 1024))
    
    # 物理带宽设为 10GB/s (单位 KBps) 保证非限速端口畅通
    local PHY_LIMIT=$((10 * 1024 * 1024)) 
    
    remove_rules "quiet"
    
    # 1. TC 根队列
    tc qdisc add dev "$INTERFACE" root handle 1: htb default 30
    
    # 2. 总带宽类
    tc class add dev "$INTERFACE" parent 1: classid 1:1 htb rate "${PHY_LIMIT}kbps"
    
    # 3. 限速类 (1:10) - 使用转换后的 KB 数值
    # 注意: tc 的 kbps = kilobytes per second
    tc class add dev "$INTERFACE" parent 1:1 classid 1:10 htb rate "${LIMIT_KB}kbps" ceil "${LIMIT_KB}kbps" prio 1
    
    # 4. 默认畅通类 (1:30)
    tc class add dev "$INTERFACE" parent 1:1 classid 1:30 htb rate "${PHY_LIMIT}kbps" ceil "${PHY_LIMIT}kbps" prio 0
    
    # 5. 过滤器
    tc filter add dev "$INTERFACE" protocol ip parent 1:0 prio 1 handle $MARK fw flowid 1:10
    tc filter add dev "$INTERFACE" protocol ipv6 parent 1:0 prio 1 handle $MARK fw flowid 1:10 2>/dev/null

    # 6. 防火墙打标
    IFS=',' read -ra PORT_ARR <<< "$INPUT_PORTS"
    for PORT in "${PORT_ARR[@]}"; do
        add_firewall_rules "$PORT"
    done
    
    # 保存配置
    cat > "$CONFIG_FILE" << EOF
PORTS=$INPUT_PORTS
LIMIT_MB=$LIMIT_MB
LIMIT_KB=$LIMIT_KB
EOF
    
    log "已限速: 端口 [$INPUT_PORTS] -> $LIMIT_MB MB/s ($LIMIT_KB KB/s)"
    echo -e "${GREEN}设置成功！当前限制: $LIMIT_MB MB/s${PLAIN}"
}

show_status() {
    echo -e "${YELLOW}--- 当前状态 ($INTERFACE) ---${PLAIN}"
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        echo -e "当前配置端口: ${GREEN}$PORTS${PLAIN}"
        echo -e "当前限制速率: ${GREEN}$LIMIT_MB MB/s${PLAIN} ($LIMIT_KB KB/s)"
    else
        echo "无配置文件"
    fi
    
    echo -e "\n${YELLOW}--- TC 流量统计 ---${PLAIN}"
    # 显示限速类 1:10 的统计信息
    tc -s class show dev "$INTERFACE" | grep -A 5 "class htb 1:10"
}

clear_all() {
    remove_rules
    rm -f "$CONFIG_FILE"
    echo -e "${GREEN}已清除所有限制。${PLAIN}"
}

# --- 菜单 ---
main() {
    check_root
    check_dependencies
    init_config
    
    echo "1. 设置端口限速 (MB/s)"
    echo "2. 查看状态"
    echo "3. 清除限制"
    echo "0. 退出"
    read -p "选择: " OPT
    case $OPT in
        1) set_limit ;;
        2) show_status ;;
        3) clear_all ;;
        0) exit 0 ;;
        *) echo "无效选择" ;;
    esac
}

main
