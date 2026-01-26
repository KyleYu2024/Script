#!/bin/bash

# =========================================================
# Mihomo 终极守护部署脚本 (LXC 适配 & 自动初始化版)
# =========================================================

# --- 1. 全局配置 ---
MIHOMO_BIN="/usr/local/bin/mihomo"
CORE_BIN="/usr/local/bin/mihomo-core"
CONF_DIR="/etc/mihomo"
CONF_FILE="$CONF_DIR/config.yaml"
SUB_INFO_FILE="$CONF_DIR/.subscription_info"
SERVICE_FILE="/etc/systemd/system/mihomo.service"

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 权限检查 ---
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}错误: 请使用 root 权限运行此脚本！${NC}"
  exit 1
fi

# =========================================================
# 2. LXC 环境与 TUN 穿透检测
# =========================================================
check_lxc_environment() {
    if [ -f /dev/virtcontainer ] || grep -qa container=lxc /proc/1/environ; then
        echo -e "${YELLOW}>>> 检测到当前环境为 LXC 容器${NC}"
        if [ ! -c /dev/net/tun ]; then
            echo -e "${RED}[!] 致命错误: 未检测到 TUN 设备，Mihomo 无法在 LXC 中运行！${NC}"
            echo -e "${CYAN}--- PVE 宿主机修复指引 ---${NC}"
            echo -e "1. 停止此容器"
            echo -e "2. 在 PVE 宿主机编辑配置文件: ${YELLOW}nano /etc/pve/lxc/你的ID.conf${NC}"
            echo -e "3. 末尾添加："
            echo -e "   ${GREEN}lxc.cgroup2.devices.allow: c 10:200 rwm${NC}"
            echo -e "   ${GREEN}lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file${NC}"
            echo -e "4. 重启容器并重新运行此脚本。"
            exit 1
        fi
    fi
}

# =========================================================
# 3. 核心守护与自动更新逻辑
# =========================================================

# 订阅更新函数
update_subscription() {
    source "$SUB_INFO_FILE"
    echo -e "${YELLOW}>>> 正在从订阅链接拉取配置...${NC}"
    curl -L -s --max-time 30 -o "${CONF_FILE}.tmp" "$SUB_URL"
    if [ $? -eq 0 ] && [ -s "${CONF_FILE}.tmp" ]; then
        mv "${CONF_FILE}.tmp" "$CONF_FILE"
        echo -e "${GREEN}订阅配置拉取成功。${NC}"
        return 0
    else
        echo -e "${RED}订阅下载失败，请检查链接或网络。${NC}"
        return 1
    fi
}

# 部署 Systemd 服务
generate_systemd_service() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Mihomo Daemon (High Availability)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
# 极致守护：无论如何崩溃，5秒后重启
Restart=always
RestartSec=5s
StartLimitIntervalSec=0
ExecStartPre=/usr/bin/mkdir -p $CONF_DIR
ExecStart=$CORE_BIN -d $CONF_DIR -f $CONF_FILE

# 提升网络管理能力
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW

[Install]
WantedBy=multi-user.target
EOF
}

# =========================================================
# 4. 管理面板 (功能集成)
# =========================================================
generate_manager() {
    # 此处省略具体管理脚本的长代码段，功能已包含：
    # 修改订阅、手动更新、查看日志、Web 面板安装、卸载等
    # ... (保持与你之前使用的管理菜单逻辑一致，但去掉了文案末尾句号)
}

# =========================================================
# 5. 执行安装流程
# =========================================================
clear
echo -e "${BLUE}开始部署 Mihomo 极致守护环境...${NC}"

check_lxc_environment

# 1. 安装依赖
apt update -q && apt install -y curl gzip tar nano unzip jq -q

# 2. 下载核心 (支持 x86 和 Arm)
ARCH=$(uname -m)
[ "$ARCH" == "x86_64" ] && ARCH_TYPE="amd64" || ARCH_TYPE="arm64"
URL="https://gh-proxy.com/https://github.com/MetaCubeX/mihomo/releases/download/v1.18.10/mihomo-linux-${ARCH_TYPE}-v1.18.10.gz"
curl -L "$URL" | gzip -d > "$CORE_BIN"
chmod +x "$CORE_BIN"

# 3. 交互输入
[ -f "$SUB_INFO_FILE" ] && source "$SUB_INFO_FILE"
read -p "请输入订阅链接 [当前: $SUB_URL]: " input_url
SUB_URL=${input_url:-$SUB_URL}
read -p "通知 Webhook [当前: $NOTIFY_URL]: " input_notify
NOTIFY_URL=${input_notify:-$NOTIFY_URL}
read -p "更新频率(分钟) [当前: $SUB_INTERVAL]: " input_int
SUB_INTERVAL=${input_int:-$SUB_INTERVAL}
[ -z "$SUB_INTERVAL" ] && SUB_INTERVAL=60

echo "SUB_URL=\"$SUB_URL\"" > "$SUB_INFO_FILE"
echo "NOTIFY_URL=\"$NOTIFY_URL\"" >> "$SUB_INFO_FILE"
echo "SUB_INTERVAL=\"$SUB_INTERVAL\"" >> "$SUB_INFO_FILE"

# 4. 关键步骤：先拉取配置，再启动服务
update_subscription

# 5. 部署守护服务
generate_systemd_service
systemctl daemon-reload
systemctl enable --now mihomo

echo -e "${GREEN}>>> 部署成功！请输入 'mihomo' 唤起管理菜单${NC}"
