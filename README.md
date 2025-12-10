# VPS 端口限速工具

## 简介
这是一个基于 Linux 系统的端口限速管理工具，使用 TC (Traffic Control) 和 iptables 实现对指定端口的流量控制。适用于需要对 VPS 特定端口进行带宽管理的场景。

## 特性
- 支持多端口同时限速
- 可设置总带宽限制
- 支持单个 IP 限速
- 支持最大带宽限制
- 配置持久化保存
- 完整的日志记录
- 简单的命令行界面

## 安装要求
- Linux 系统（推荐 Ubuntu/Debian/CentOS）
- root 权限
- iproute2 包（提供 tc 命令）
- iptables 包

## 快速安装
使用以下命令一键安装并运行：
```bash
sudo bash -c "wget -O Throttle.sh https://github.com/suxayii/vps-port-speed-limit/raw/refs/heads/master/Throttle.sh && chmod +x Throttle.sh && bash Throttle.sh"
```

## 使用说明

### 1. 启动脚本
```bash
sudo ./Throttle.sh
```

### 2. 主要功能
脚本提供以下功能：

#### 2.1 设置端口限速
- 输入目标端口（支持多个，用逗号分隔）
- 设置总带宽（单位：KBps）
- 设置单个 IP 的限速值（单位：KBps）
- 设置允许的最大速率（单位：KBps）

#### 2.2 清除限速规则
- 清除所有限速规则
- 清除指定端口的限速规则

#### 2.3 查看当前配置
- 显示当前所有限速设置
- 查看受限端口列表

### 3. 配置说明

配置文件位置：`/etc/port-limit/settings.conf`

配置参数说明：
- `PORTS`: 限速端口列表
- `TOTAL_BANDWIDTH`: 总带宽限制
- `RATE`: 单个 IP 限速值
- `CEIL`: 允许的最大速率

### 4. 日志
- 日志文件位置：`/etc/port-limit/port-limit.log`
- 记录所有操作和错误信息

## 常见问题

### 1. 权限问题
确保使用 root 权限运行脚本：
```bash
sudo ./Throttle.sh
```

### 2. 依赖包缺失
如果提示缺少必要的软件包，按照提示进行安装：
```bash
# Debian/Ubuntu 系统
sudo apt-get update
sudo apt-get install iproute2 iptables

# CentOS 系统
sudo yum install iproute iptables
```

### 3. 网卡名称不匹配
如果默认的 eth0 不是你的网卡名称，请修改脚本中的 INTERFACE 变量：
```bash
INTERFACE="your_interface_name"
```

## 注意事项
1. 请谨慎设置限速参数，避免影响正常服务
2. 建议定期备份配置文件
3. 系统重启后需要重新应用限速规则
4. 确保有足够的系统资源来运行流量控制

## 技术支持
如有问题或建议，请通过以下方式联系：
1. 在 GitHub 上提交 Issue
2. Pull Request 贡献代码

## 许可证
本项目基于 MIT 许可证开源。

## 更新日志

### v1.0.0 (2023-09-16)
- 初始版本发布
- 支持基本的端口限速功能
- 添加配置文件持久化
- 添加日志功能

### v1.1.0 (2023-09-17)
- 优化错误处理
- 添加自动依赖检查
- 改进用户界面
- 添加配置备份功能
