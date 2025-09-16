#!/bin/bash

# 配置文件路径
CONFIG_DIR="/etc/port-limit"
CONFIG_FILE="$CONFIG_DIR/settings.conf"
LOG_FILE="$CONFIG_DIR/port-limit.log"

# 固定网卡名称
INTERFACE="eth0"
MARK=10

# 创建日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# 检查是否为 root 用户
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "错误: 请使用 root 权限运行此脚本"
        exit 1
    fi
}

# 初始化配置目录和文件
init_config() {
    if [ ! -d "$CONFIG_DIR" ]; then
        mkdir -p "$CONFIG_DIR"
    fi
    touch "$LOG_FILE"
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "PORTS=" > "$CONFIG_FILE"
        echo "TOTAL_BANDWIDTH=0" >> "$CONFIG_FILE"
        echo "RATE=0" >> "$CONFIG_FILE"
        echo "CEIL=0" >> "$CONFIG_FILE"
    fi
}

# 检查必要的软件包
check_dependencies() {
    local missing_deps=()
    
    if ! command -v tc &> /dev/null; then
        missing_deps+=("iproute2")
    fi
    
    if ! command -v iptables &> /dev/null; then
        missing_deps+=("iptables")
    fi
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo "缺少必要的软件包："
        printf '%s\n' "${missing_deps[@]}"
        read -p "是否自动安装这些包？(y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            if command -v apt &> /dev/null; then
                apt update && apt install -y "${missing_deps[@]}"
            elif command -v yum &> /dev/null; then
                yum install -y "${missing_deps[@]}"
            else
                echo "无法确定包管理器，请手动安装所需包"
                exit 1
            fi
        else
            exit 1
        fi
    fi
}

# 验证输入的数值
validate_number() {
    local input=$1
    local field_name=$2
    
    if ! [[ "$input" =~ ^[0-9]+$ ]]; then
        log "错误：$field_name 必须是正整数"
        return 1
    fi
    if [ "$input" -le 0 ]; then
        log "错误：$field_name 必须大于 0"
        return 1
    fi
    return 0
}

# 验证端口号
validate_ports() {
    local ports=$1
    local IFS=','
    read -ra PORT_ARRAY <<< "$ports"
    
    for port in "${PORT_ARRAY[@]}"; do
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            log "错误：端口号 $port 无效 (必须在 1-65535 之间)"
            return 1
        fi
    done
    return 0
}

# 设置限速规则
set_limit() {
    read -p "请输入目标端口(用逗号分隔，如 443,80,22): " PORTS
    if ! validate_ports "$PORTS"; then
        return 1
    fi
    
    read -p "请输入总带宽 (单位 KBps，只输入数值): " TOTAL_BANDWIDTH
    read -p "请输入单个 IP 的限速 (单位 KBps，只输入数值): " RATE
    read -p "请输入允许的最大速率 (单位 KBps，只输入数值): " CEIL
    
    # 验证输入值
    for param in "$TOTAL_BANDWIDTH" "$RATE" "$CEIL"; do
        if ! validate_number "$param" "带宽值"; then
            return 1
        fi
    done
    
    echo -e "\n您已设置以下参数："
    echo "目标端口: $PORTS"
    echo "总带宽: ${TOTAL_BANDWIDTH}KBps"
    echo "单个 IP 的限速: ${RATE}KBps"
    echo "允许的最大速率: ${CEIL}KBps"
    read -p "确认限速请回车，取消请按 Ctrl+C..."
    
    # 清除现有规则
    tc qdisc del dev $INTERFACE root 2>/dev/null
    iptables -t mangle -F
    
    # 设置 TC 规则
    tc qdisc add dev $INTERFACE root handle 1: htb default 30
    tc class add dev $INTERFACE parent 1: classid 1:1 htb rate "${TOTAL_BANDWIDTH}KBps"
    tc class add dev $INTERFACE parent 1:1 classid 1:10 htb rate "${RATE}KBps" ceil "${CEIL}KBps"
    
    # 设置 iptables 规则
    IFS=',' read -ra PORT_ARRAY <<< "$PORTS"
    for PORT in "${PORT_ARRAY[@]}"; do
        iptables -t mangle -A PREROUTING -i $INTERFACE -p tcp --dport "$PORT" -j MARK --set-mark $MARK
        iptables -t mangle -A PREROUTING -i $INTERFACE -p udp --dport "$PORT" -j MARK --set-mark $MARK
        iptables -t mangle -A OUTPUT -o $INTERFACE -p tcp --sport "$PORT" -j MARK --set-mark $MARK
        iptables -t mangle -A OUTPUT -o $INTERFACE -p udp --sport "$PORT" -j MARK --set-mark $MARK
    done
    
    # 设置过滤规则
    tc filter add dev $INTERFACE protocol ip parent 1:0 prio 1 handle $MARK fw flowid 1:10
    
    # 保存配置
    cat > "$CONFIG_FILE" << EOF
PORTS=$PORTS
TOTAL_BANDWIDTH=$TOTAL_BANDWIDTH
RATE=$RATE
CEIL=$CEIL
EOF
    
    log "已成功设置限速规则"
}

# 清除限速规则
clear_limit() {
    echo "请选择清除规则的方式："
    echo "1. 清除所有限速规则"
    echo "2. 输入端口清除指定规则"
    read -p "请输入选项 (1 或 2): " CLEAR_CHOICE
    
    case $CLEAR_CHOICE in
        1)
            tc qdisc del dev $INTERFACE root 2>/dev/null
            iptables -t mangle -F
            rm -f "$CONFIG_FILE"
            init_config
            log "已清除所有限速规则"
            ;;
        2)
            echo "当前限速端口："
            iptables -t mangle -L PREROUTING -v -n | grep "MARK set 0x$MARK" | awk '{print $13}' | sort -u
            read -p "请输入要解除限速的端口(用逗号分隔): " REMOVE_PORTS
            
            if ! validate_ports "$REMOVE_PORTS"; then
                return 1
            fi
            
            IFS=',' read -ra REMOVE_PORT_ARRAY <<< "$REMOVE_PORTS"
            for PORT in "${REMOVE_PORT_ARRAY[@]}"; do
                iptables -t mangle -D PREROUTING -i $INTERFACE -p tcp --dport "$PORT" -j MARK --set-mark $MARK 2>/dev/null
                iptables -t mangle -D PREROUTING -i $INTERFACE -p udp --dport "$PORT" -j MARK --set-mark $MARK 2>/dev/null
                iptables -t mangle -D OUTPUT -o $INTERFACE -p tcp --sport "$PORT" -j MARK --set-mark $MARK 2>/dev/null
                iptables -t mangle -D OUTPUT -o $INTERFACE -p udp --sport "$PORT" -j MARK --set-mark $MARK 2>/dev/null
            done
            
            log "已解除端口 $REMOVE_PORTS 的限速规则"
            ;;
        *)
            echo "无效选项"
            return 1
            ;;
    esac
}

# 显示当前配置
show_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        echo "当前限速配置："
        echo "目标端口: $PORTS"
        echo "总带宽: ${TOTAL_BANDWIDTH}KBps"
        echo "单个 IP 限速: ${RATE}KBps"
        echo "允许的最大速率: ${CEIL}KBps"
    else
        echo "没有找到有效的限速配置文件"
    fi
    
    echo -e "\n当前限速端口:"
    iptables -t mangle -L PREROUTING -v -n | grep "MARK set 0x$MARK" | awk '{print $13}' | sort -u
}

# 主程序
main() {
    check_root
    check_dependencies
    init_config
    
    echo "端口限速管理工具"
    echo "=================="
    echo "1. 设置端口限速"
    echo "2. 清除限速规则"
    echo "3. 查看当前配置"
    echo "4. 退出"
    read -p "请输入选项 (1-4): " CHOICE
    
    case $CHOICE in
        1) set_limit ;;
        2) clear_limit ;;
        3) show_config ;;
        4) exit 0 ;;
        *) echo "无效选项，请输入 1-4" ;;
    esac
}

main
