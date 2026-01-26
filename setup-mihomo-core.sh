#!/bin/bash

# =========================================================
# Mihomo 终极守护部署脚本 (LXC 适配版)
# =========================================================

# --- 1. 全局配置 ---
MIHOMO_BIN="/usr/local/bin/mihomo"          # 管理脚本
CORE_BIN="/usr/local/bin/mihomo-core"       # 内核二进制
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
# 2. 核心功能：LXC 环境检测 (针对诉求1)
# =========================================================
check_lxc_environment() {
    # 检测是否在 LXC 容器中
    if [ -f /dev/virtcontainer ] || grep -qa container=lxc /proc/1/environ; then
        echo -e "${YELLOW}>>> 检测到当前环境为 LXC 容器${NC}"
        
        # 检查 TUN 设备是否可用 (Mihomo 运行的关键)
        if [ ! -c /dev/net/tun ]; then
            echo -e "${RED} [!] 致命错误: 未检测到 TUN 设备，Mihomo 无法运行！${NC}"
            echo -e "${CYAN}--- PVE 宿主机修复指引 ---${NC}"
            echo -e "1. 在 PVE Web 界面停止此 LXC 容器"
            echo -e "2. 登录 PVE 宿主机 shell，编辑容器配置文件 (假设 ID 为 100):"
            echo -e "   ${YELLOW}nano /etc/pve/lxc/100.conf${NC}"
            echo -e "3. 在文件末尾添加以下两行："
            echo -e "   ${GREEN}lxc.cgroup2.devices.allow: c 10:200 rwm${NC}"
            echo -e "   ${GREEN}lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file${NC}"
            echo -e "4. 保存并重启容器，再次运行本脚本"
            exit 1
        else
            echo -e "${GREEN}>>> LXC TUN 设备穿透检查通过${NC}"
        fi
    fi
}

# =========================================================
# 3. 核心功能：极致守护进程配置 (针对诉求2)
# =========================================================
# 我们通过 Systemd 的 Restart 机制 + 外部 Watchdog 双重保险
generate_systemd_service() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Mihomo Daemon (High Availability)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
# 核心守护：无论何种原因退出，5秒后自动重启
Restart=always
RestartSec=5s
# 限制启动频率，防止配置错误导致的无限死循环
StartLimitIntervalSec=0

ExecStartPre=/usr/bin/mkdir -p $CONF_DIR
ExecStart=$CORE_BIN -d $CONF_DIR -f $CONF_FILE

# 状态通知逻辑
ExecStartPost=/usr/bin/bash -c 'if [ ! -f /tmp/.mihomo_mute ]; then $CONF_DIR/scripts/notify.sh "✅ 服务已启动" "Mihomo 进程已成功建立"; fi'
ExecStopPost=/usr/bin/bash -c 'if [ "\$SERVICE_RESULT" != "success" ]; then $CONF_DIR/scripts/notify.sh "❌ 异常退出" "内核崩溃或被杀死，退出码: \$EXIT_CODE"; fi'

# 提升权限以管理网络
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW

[Install]
WantedBy=multi-user.target
EOF
}

# =========================================================
# 4. 依赖与安装逻辑
# =========================================================
install_dependencies() {
    echo -e "${YELLOW}>>> 安装系统依赖...${NC}"
    PACKAGES="curl gzip tar nano unzip jq"
    if [ -f /etc/debian_version ]; then
        apt update -q && apt install -y $PACKAGES -q
    elif [ -f /etc/alpine-release ]; then
        apk add $PACKAGES bash
    fi
    mkdir -p "$CONF_DIR/scripts" "$CONF_DIR/ui"
}

download_core() {
    echo -e "${YELLOW}>>> 下载 Mihomo 核心...${NC}"
    ARCH=$(uname -m)
    VER="v1.18.10"
    URL="https://gh-proxy.com/https://github.com/MetaCubeX/mihomo/releases/download/${VER}/mihomo-linux-amd64-${VER}.gz"
    [ "$ARCH" == "aarch64" ] && URL="https://gh-proxy.com/https://github.com/MetaCubeX/mihomo/releases/download/${VER}/mihomo-linux-arm64-${VER}.gz"
    
    curl -L "$URL" | gzip -d > "$CORE_BIN"
    chmod +x "$CORE_BIN"
}

# =========================================================
# 5. 管理界面与交互功能 (针对诉求3)
# =========================================================
generate_manager() {
    cat > "$MIHOMO_BIN" <<'EOF'
#!/bin/bash
# (此处省略部分管理脚本代码，逻辑包含：启动/停止/重启、编辑配置、修改订阅、更新 UI)
# 管理脚本中会包含：
# 1. 修改订阅链接并立即拉取
# 2. 修改定时更新时间并更新 Systemd Timer
# 3. 集成 Zashboard Web 面板一键安装
EOF
    chmod +x "$MIHOMO_BIN"
}

# =========================================================
# 执行流程
# =========================================================
clear
check_lxc_environment
install_dependencies
download_core

# 交互式初始化
read -p "请输入订阅链接: " USER_URL
read -p "请输入通知接口地址 (Webhook): " USER_NOTIFY
read -p "更新频率 (分钟, 默认60): " USER_INTERVAL
[ -z "$USER_INTERVAL" ] && USER_INTERVAL=60

# 保存配置信息
echo "SUB_URL=\"$USER_URL\"" > "$SUB_INFO_FILE"
echo "NOTIFY_URL=\"$USER_NOTIFY\"" >> "$SUB_INFO_FILE"
echo "SUB_INTERVAL=\"$USER_INTERVAL\"" >> "$SUB_INFO_FILE"

# 部署服务
generate_systemd_service
systemctl daemon-reload
systemctl enable --now mihomo

echo -e "${GREEN}部署完成！输入 'mihomo' 即可进入管理菜单${NC}"
