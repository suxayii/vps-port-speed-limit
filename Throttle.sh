#!/bin/bash

# ==========================================
# 端口流量限制工具 (优化版)
# 功能：使用 TC + IPTables 对指定端口进行出站带宽限制
# ==========================================

# 配置文件路径
CONFIG_DIR="/etc/port-limit"
CONFIG_FILE="$CONFIG_DIR/settings.conf"
LOG_FILE="$CONFIG_DIR/port-limit.log"

# 自动获取默认网卡名称 (访问公共DNS来确定主出口网卡)
INTERFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5; exit}')
MARK=10

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 如果找不到网卡，手动指定一个回退值
if [ -z "$INTERFACE" ]; then
    INTERFACE="eth0"
fi

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# 检查 Root 权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误: 请使用 root 权限运行此脚本${PLAIN}"
        exit 1
    fi
}

# 初始化
init_config() {
    if [ ! -d "$CONFIG_DIR" ]; then
        mkdir -p "$CONFIG_DIR"
    fi
    touch "$LOG_FILE"
    if [ ! -f "$CONFIG_FILE" ]; then
        # 初始化空配置
        cat > "$CONFIG_FILE" << EOF
PORTS=""
TOTAL_BANDWIDTH="0"
TARGET_BANDWIDTH="0"
CEIL_BANDWIDTH="0"
EOF
    fi
}

# 检查依赖
check_dependencies() {
    local missing_deps=()
    
    if ! command -v tc &> /dev/null; then missing_deps+=("iproute2"); fi
    if ! command -v iptables &> /dev/null; then missing_deps+=("iptables"); fi
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo -e "${YELLOW}检测到缺少必要软件包: ${missing_deps[*]}${PLAIN}"
        read -p "是否自动安装? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            if command -v apt &> /dev/null; then
                apt update && apt install -y "${missing_deps[@]}"
            elif command -v yum &> /dev/null; then
                yum install -y "${missing_deps[@]}"
            else
                echo -e "${RED}无法识别包管理器，请手动安装: ${missing_deps[*]}${PLAIN}"
                exit 1
            fi
        else
            echo "取消安装，脚本退出。"
            exit 1
        fi
    fi
}

# 验证数字
validate_number() {
    if ! [[ "$1" =~ ^[0-9]+$ ]] || [ "$1" -le 0 ]; then
        return 1
    fi
    return 0
}

# 验证端口格式
validate_ports() {
    local ports=$1
    if [[ -z "$ports" ]]; then return 1; fi
    local IFS=','
    read -ra PORT_ARRAY <<< "$ports"
    for port in "${PORT_ARRAY[@]}"; do
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            echo -e "${RED}错误：端口号 $port 无效${PLAIN}"
            return 1
        fi
    done
    return 0
}

# 清理当前规则 (只清理本脚本相关的规则，不暴力清空表)
# 参数 1: "quiet" 可选，不输出日志
remove_rules() {
    local quiet=$1
    
    # 读取旧配置以确定要删除哪些 iptables 规则
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        if [ -n "$PORTS" ]; then
            IFS=',' read -ra OLD_PORT_ARRAY <<< "$PORTS"
            for PORT in "${OLD_PORT_ARRAY[@]}"; do
                # 尝试删除规则，忽略错误信息
                iptables -t mangle -D PREROUTING -i "$INTERFACE" -p tcp --dport "$PORT" -j MARK --set-mark $MARK 2>/dev/null
                iptables -t mangle -D PREROUTING -i "$INTERFACE" -p udp --dport "$PORT" -j MARK --set-mark $MARK 2>/dev/null
                iptables -t mangle -D OUTPUT -o "$INTERFACE" -p tcp --sport "$PORT" -j MARK --set-mark $MARK 2>/dev/null
                iptables -t mangle -D OUTPUT -o "$INTERFACE" -p udp --sport "$PORT" -j MARK --set-mark $MARK 2>/dev/null
            done
        fi
    fi

    # 删除 TC 规则 (TC 规则通常可以直接删除 root qdisc)
    if tc qdisc show dev "$INTERFACE" | grep -q "htb"; then
        tc qdisc del dev "$INTERFACE" root 2>/dev/null
    fi

    if [ "$quiet" != "quiet" ]; then
        log "旧规则已清理 (网卡: $INTERFACE)"
    fi
}

# 设置限速
set_limit() {
    echo -e "${YELLOW}提示: 此设置将重置当前脚本已设置的规则。${PLAIN}"
    read -p "请输入目标端口 (用逗号分隔，如 443,8080): " INPUT_PORTS
    if ! validate_ports "$INPUT_PORTS"; then return 1; fi
    
    # 物理网卡最大带宽（用于计算 Default Class）
    read -p "请输入服务器物理最大带宽 (单位 MB/s, 用于非限速端口): " PHY_LIMIT
    if ! validate_number "$PHY_LIMIT"; then PHY_LIMIT=1000; fi # 默认给个大数值
    
    # 转换物理带宽为 KBps (TC单位)
    local ROOT_LIMIT=$((PHY_LIMIT * 1024))

    echo -e "\n${YELLOW}--- 限速组配置 ---${PLAIN}"
    echo "说明: 以下数值单位均为 KB/s (千字节每秒)"
    read -p "限速组-保证速率 (Rate, 即使网络拥堵也能达到的速度): " TARGET_RATE
    read -p "限速组-最大速率 (Ceil, 网络空闲时允许突发到的最大速度): " TARGET_CEIL
    
    if ! validate_number "$TARGET_RATE" || ! validate_number "$TARGET_CEIL"; then
        echo -e "${RED}输入数值无效${PLAIN}"
        return 1
    fi

    # 清理旧规则
    remove_rules "quiet"

    # 1. 创建 HTB 根队列，默认流量走 30
    tc qdisc add dev "$INTERFACE" root handle 1: htb default 30
    
    # 2. 创建主类 (总带宽)
    tc class add dev "$INTERFACE" parent 1: classid 1:1 htb rate "${ROOT_LIMIT}kbps"
    
    # 3. 创建限速类 (1:10) - 针对目标端口
    # 注意：在 tc 中 kbps = kilobytes per second
    tc class add dev "$INTERFACE" parent 1:1 classid 1:10 htb rate "${TARGET_RATE}kbps" ceil "${TARGET_CEIL}kbps"
    
    # 4. 创建默认类 (1:30) - 针对其他所有端口 (如 SSH)，给足带宽，避免卡顿
    # 默认类给予剩余的大部分带宽，优先级(prio)设为 0 (最高) 保证管理通畅，限速类设为 1
    tc class add dev "$INTERFACE" parent 1:1 classid 1:30 htb rate "$((ROOT_LIMIT - 100))kbps" ceil "${ROOT_LIMIT}kbps" prio 0
    tc class change dev "$INTERFACE" parent 1:1 classid 1:10 htb rate "${TARGET_RATE}kbps" ceil "${TARGET_CEIL}kbps" prio 1

    # 5. 设置过滤器，将标记为 MARK(10) 的包导向类 1:10
    tc filter add dev "$INTERFACE" protocol ip parent 1:0 prio 1 handle $MARK fw flowid 1:10

    # 6. 使用 iptables 打标
    IFS=',' read -ra PORT_ARRAY <<< "$INPUT_PORTS"
    for PORT in "${PORT_ARRAY[@]}"; do
        # 限制发送 (Egress/OUTPUT) - 这是服务器发出数据被限制（如下载文件）
        iptables -t mangle -A OUTPUT -o "$INTERFACE" -p tcp --sport "$PORT" -j MARK --set-mark $MARK
        iptables -t mangle -A OUTPUT -o "$INTERFACE" -p udp --sport "$PORT" -j MARK --set-mark $MARK
        
        # 尝试限制转发流量 (如果服务器作为网关/代理)
        # 注意：TC 只能控制发出的流量。对于入站流量，我们打标后，如果是转发出去，会在发出时被 TC 捕获。
        iptables -t mangle -A PREROUTING -i "$INTERFACE" -p tcp --dport "$PORT" -j MARK --set-mark $MARK
        iptables -t mangle -A PREROUTING -i "$INTERFACE" -p udp --dport "$PORT" -j MARK --set-mark $MARK
    done

    # 保存配置
    cat > "$CONFIG_FILE" << EOF
PORTS=$INPUT_PORTS
TOTAL_BANDWIDTH=$ROOT_LIMIT
TARGET_BANDWIDTH=$TARGET_RATE
CEIL_BANDWIDTH=$TARGET_CEIL
EOF

    log "规则已应用。端口: $INPUT_PORTS | 限制: ${TARGET_CEIL} KB/s"
    echo -e "${GREEN}限速设置成功！${PLAIN}"
    echo "当前监听网卡: $INTERFACE"
}

# 显示状态
show_status() {
    echo -e "${YELLOW}=== 当前网卡: $INTERFACE ===${PLAIN}"
    
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        echo "当前配置端口: $PORTS"
        echo "限制最大速率: ${CEIL_BANDWIDTH} KB/s"
    else
        echo "暂无配置文件。"
    fi
    
    echo -e "\n${YELLOW}=== TC 类规则 (Qdisc) ===${PLAIN}"
    tc -s class show dev "$INTERFACE" | grep -A 5 "htb"
    
    echo -e "\n${YELLOW}=== Iptables 标记规则 (Mangle) ===${PLAIN}"
    iptables -t mangle -L OUTPUT -v -n | grep "MARK set 0x$((MARK))"
    iptables -t mangle -L PREROUTING -v -n | grep "MARK set 0x$((MARK))"
}

# 完全清除
clear_all() {
    read -p "确定要清除所有本脚本建立的限速规则吗? [y/n]: " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        remove_rules
        rm -f "$CONFIG_FILE"
        # 重新初始化空文件
        init_config
        echo -e "${GREEN}所有限速规则已清除，恢复默认网络状态。${PLAIN}"
    else
        echo "取消操作。"
    fi
}

# 主菜单
main() {
    check_root
    check_dependencies
    init_config
    
    clear
    echo "=================================="
    echo "    Linux 端口限速管理脚本 (Pro)  "
    echo "    当前网卡: $INTERFACE          "
    echo "=================================="
    echo " 1. 设置/更新 端口限速"
    echo " 2. 查看当前状态"
    echo " 3. 清除所有限速"
    echo " 0. 退出"
    echo "=================================="
    read -p "请输入选项 [0-3]: " CHOICE
    
    case $CHOICE in
        1) set_limit ;;
        2) show_status ;;
        3) clear_all ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${PLAIN}" ;;
    esac
}

main
