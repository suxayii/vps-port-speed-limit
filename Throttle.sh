#!/bin/bash

# ==========================================
# Linux 端口限速工具 (修复 r2q 警告版)
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

# --- 核心逻辑 ---

remove_rules() {
    local quiet=$1
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        if [ -n "$PORTS" ]; then
            IFS=',' read -ra PORT_ARR <<< "$PORTS"
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
    
    read -p "请输入限制速率 (单位 MB/s, 仅输入整数): " LIMIT_MB
    if ! validate_number "$LIMIT_MB"; then echo "数值无效"; return; fi
    
    # 转换计算
    local LIMIT_KB=$((LIMIT_MB * 1024))
    # 换算成 Mbps 用于显示给用户对比
    local SHOW_MBPS=$((LIMIT_MB * 8))
    
    # 物理带宽设为 10GB/s
    local PHY_LIMIT=$((10 * 1024 * 1024)) 
    
    remove_rules "quiet"
    
    # 1. TC 根队列 (添加 r2q 这里的 r2q 参数有助于避免警告，但后面我们会手动指定 quantum)
    tc qdisc add dev "$INTERFACE" root handle 1: htb default 30 r2q 10
    
    # 2. 总带宽类
    tc class add dev "$INTERFACE" parent 1: classid 1:1 htb rate "${PHY_LIMIT}kbps"
    
    # 3. 限速类 (1:10) - 增加 burst 和 quantum 参数修复警告
    # burst: 允许突发的大小，通常设为 15k-30k 左右
    # quantum: 设为 MTU 左右的值 (如 1500-3000)
    tc class add dev "$INTERFACE" parent 1:1 classid 1:10 htb rate "${LIMIT_KB}kbps" ceil "${LIMIT_KB}kbps" burst 15k quantum 3000 prio 1
    
    # 4. 默认畅通类 (1:30)
    tc class add dev "$INTERFACE" parent 1:1 classid 1:30 htb rate "${PHY_LIMIT}kbps" ceil "${PHY_LIMIT}kbps" burst 15k quantum 3000 prio 0
    
    # 5. 过滤器
    tc filter add dev "$INTERFACE" protocol ip parent 1:0 prio 1 handle $MARK fw flowid 1:10
    tc filter add dev "$INTERFACE" protocol ipv6 parent 1:0 prio 1 handle $MARK fw flowid 1:10 2>/dev/null

    # 6. 防火墙打标
    IFS=',' read -ra PORT_ARR <<< "$INPUT_PORTS"
    for PORT in "${PORT_ARR[@]}"; do
        add_firewall_rules "$PORT"
    done
    
    cat > "$CONFIG_FILE" << EOF
PORTS=$INPUT_PORTS
LIMIT_MB=$LIMIT_MB
EOF
    
    log "已限速: 端口 [$INPUT_PORTS] -> $LIMIT_MB MB/s"
    echo -e "${GREEN}设置成功！${PLAIN}"
    echo -e "当前限制物理速度: ${YELLOW}$LIMIT_MB MB/s${PLAIN}"
    echo -e "对应测速网站读数: ${YELLOW}约 $SHOW_MBPS Mbps${PLAIN}"
    echo -e "(如果你的测速结果小于 $SHOW_MBPS，说明并未达到限速阈值)"
}

show_status() {
    echo -e "${YELLOW}--- 当前配置 ($INTERFACE) ---${PLAIN}"
    [ -f "$CONFIG_FILE" ] && cat "$CONFIG_FILE"
    
    echo -e "\n${YELLOW}--- TC 流量统计 (Sent = 已发送字节) ---${PLAIN}"
    tc -s class show dev "$INTERFACE" | grep -A 5 "class htb 1:10"
    
    echo -e "\n${YELLOW}--- 防火墙命中统计 (pkts = 命中包数) ---${PLAIN}"
    echo "如果是 0 pkts，说明流量没有走这些端口，或者被其他规则拦截。"
    iptables -t mangle -L OUTPUT -v -n | grep "MARK set 0x$((MARK))"
}

clear_all() {
    remove_rules
    rm -f "$CONFIG_FILE"
    echo -e "${GREEN}已清除所有限制。${PLAIN}"
}

main() {
    check_root
    check_dependencies
    init_config
    echo "1. 设置端口限速 (MB/s)"
    echo "2. 查看状态 (排查故障)"
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
