#!/bin/bash

# =========================================================
# Mihomo 终极生产力版 - 一键部署脚本 (LXC / Linux)
# =========================================================

# --- 1. 全局配置与路径 ---
MIHOMO_BIN="/usr/local/bin/mihomo"
CORE_BIN="/usr/local/bin/mihomo-core"
CONF_DIR="/etc/mihomo"
CONF_FILE="$CONF_DIR/config.yaml"
SUB_INFO_FILE="$CONF_DIR/.subscription_info"
SERVICE_FILE="/etc/systemd/system/mihomo.service"
SCRIPTS_DIR="$CONF_DIR/scripts"

NOTIFY_SCRIPT="$SCRIPTS_DIR/notify.sh"
UPDATE_SCRIPT="$SCRIPTS_DIR/update.sh"
WATCHDOG_SCRIPT="$SCRIPTS_DIR/watchdog.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

clear
echo -e "${BLUE}#################################################${NC}"
echo -e "${BLUE}#        Mihomo 终极守护网关 (生产力全能版)     #${NC}"
echo -e "${BLUE}#################################################${NC}"

# --- 2. 环境自检 (LXC 智能识别) ---
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误: 请使用 root 权限运行此脚本${NC}"
    exit 1
fi

if [ -f /dev/virtcontainer ] || grep -qa container=lxc /proc/1/environ; then
    echo -e "${YELLOW}>>> 检测到当前环境为 LXC 容器${NC}"
    if [ ! -c /dev/net/tun ]; then
        CTID=$(cat /proc/self/cgroup | head -1 | cut -d '/' -f 3 | cut -d '-' -f 2 | cut -d '.' -f 1)
        [ -z "$CTID" ] && CTID="<你的容器ID>"
        echo -e "${RED}[!] 致命错误: 未检测到 TUN 设备，Mihomo 无法运行${NC}"
        echo -e "${CYAN}--- PVE 宿主机修复指引 ---${NC}"
        echo -e "1. 停止此容器"
        echo -e "2. 在 PVE 宿主机执行: ${YELLOW}nano /etc/pve/lxc/${CTID}.conf${NC}"
        echo -e "3. 在文件末尾添加以下两行："
        echo -e "   ${GREEN}lxc.cgroup2.devices.allow: c 10:200 rwm${NC}"
        echo -e "   ${GREEN}lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file${NC}"
        echo -e "4. 保存后重启容器，再次运行本脚本"
        exit 1
    else
        echo -e "${GREEN}>>> LXC TUN 穿透检查通过${NC}"
    fi
fi

# --- 3. 依赖安装与核心下载 ---
echo -e "\n${YELLOW}>>> [1/5] 安装依赖与核心...${NC}"
apt update -q && apt install -y curl gzip tar nano unzip jq bc -q

ARCH=$(uname -m)
[ "$ARCH" == "x86_64" ] && AT="amd64" || AT="arm64"
URL="https://gh-proxy.com/https://github.com/MetaCubeX/mihomo/releases/download/v1.18.10/mihomo-linux-${AT}-v1.18.10.gz"
curl -L "$URL" | gzip -d > "$CORE_BIN" && chmod +x "$CORE_BIN"
mkdir -p "$CONF_DIR/ui" "$SCRIPTS_DIR"

# --- 4. 交互式配置 ---
echo -e "\n${YELLOW}>>> [2/5] 配置信息...${NC}"
read -p "请输入订阅链接: " SUB_URL
read -p "请输入通知接口 (例如 http://10.10.2.11:8088/api/v1/notify/mihomo): " NOTIFY_URL
read -p "请输入更新频率 (分钟, 默认 60): " SUB_INTERVAL
[ -z "$SUB_INTERVAL" ] && SUB_INTERVAL=60

echo "SUB_URL=\"$SUB_URL\"" > "$SUB_INFO_FILE"
echo "NOTIFY_URL=\"$NOTIFY_URL\"" >> "$SUB_INFO_FILE"
echo "SUB_INTERVAL=\"$SUB_INTERVAL\"" >> "$SUB_INFO_FILE"

# --- 5. 生成配套脚本 ---
echo -e "\n${YELLOW}>>> [3/5] 生成自动化脚本...${NC}"

# 通知脚本 (带时间戳换行，去句号)
cat > "$NOTIFY_SCRIPT" <<'EOF'
#!/bin/bash
source /etc/mihomo/.subscription_info
if [ -n "$NOTIFY_URL" ]; then
    TIME=$(date "+%Y-%m-%d %H:%M:%S")
    curl -s -X POST "$NOTIFY_URL" -H "Content-Type: application/json" -d "{\"title\":\"$1\", \"content\":\"$2\\n时间: $TIME\"}" > /dev/null 2>&1
fi
EOF

# 更新脚本
cat > "$UPDATE_SCRIPT" <<'EOF'
#!/bin/bash
source /etc/mihomo/.subscription_info
NOTIFY="/etc/mihomo/scripts/notify.sh"
TEMP="/etc/mihomo/config.yaml.tmp"
curl -L -s --max-time 30 -o "$TEMP" "$SUB_URL"
if [ $? -eq 0 ] && grep -q "proxies:" "$TEMP"; then
    mv "$TEMP" "/etc/mihomo/config.yaml"
    touch /tmp/.mihomo_mute
    systemctl restart mihomo
    rm -f /tmp/.mihomo_mute
    $NOTIFY "🔄 订阅配置已更新" "检测到配置变更，已应用并重启服务"
else
    $NOTIFY "⚠️ 订阅更新异常" "下载成功，但配置中无有效节点数据"
    rm -f "$TEMP"
fi
EOF

# Watchdog 脚本
cat > "$WATCHDOG_SCRIPT" <<'EOF'
#!/bin/bash
if ! systemctl is-active --quiet mihomo; then exit 0; fi
PORT=$(grep "mixed-port" /etc/mihomo/config.yaml | awk '{print $2}')
[ -z "$PORT" ] && PORT=7890
CODE=$(curl -s -o /dev/null -w "%{http_code}" -x "http://127.0.0.1:$PORT" --max-time 5 "http://cp.cloudflare.com/generate_204")
if [ "$CODE" != "204" ]; then
    /etc/mihomo/scripts/notify.sh "🌐 网络连通性丢失" "节点超时，尝试重启服务以恢复网络"
    systemctl restart mihomo
fi
EOF
chmod +x "$NOTIFY_SCRIPT" "$UPDATE_SCRIPT" "$WATCHDOG_SCRIPT"

# --- 6. 生成极致守护 Systemd ---
echo -e "\n${YELLOW}>>> [4/5] 部署极致守护服务...${NC}"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Mihomo High Availability Daemon
After=network-online.target

[Service]
Type=simple
User=root
Restart=always
RestartSec=5s
StartLimitIntervalSec=0
ExecStart=$CORE_BIN -d $CONF_DIR -f $CONF_FILE

ExecStartPost=/usr/bin/bash -c 'if [ ! -f /tmp/.mihomo_mute ]; then $NOTIFY_SCRIPT "✅ Mihomo 服务已启动" "服务已成功启动或重启"; fi'
ExecStopPost=/usr/bin/bash -c 'if [ "\$SERVICE_RESULT" != "success" ]; then $NOTIFY_SCRIPT "❌ Mihomo 异常退出" "内核崩溃，退出码: \$EXIT_CODE"; fi'

CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/mihomo-update.timer <<EOF
[Timer]
OnBootSec=5min
OnUnitActiveSec=${SUB_INTERVAL}min
[Install]
WantedBy=timers.target
EOF
cat > /etc/systemd/system/mihomo-update.service <<EOF
[Service]
Type=oneshot
ExecStart=$UPDATE_SCRIPT
EOF

# --- 7. 生成全能管理菜单 (包含 WebUI 安装) ---
echo -e "\n${YELLOW}>>> [5/5] 生成全能管理菜单...${NC}"

cat > "$MIHOMO_BIN" <<'EOF'
#!/bin/bash
CONF_DIR="/etc/mihomo"
SUB_INFO="$CONF_DIR/.subscription_info"
UPDATE_SH="$CONF_DIR/scripts/update.sh"
UI_URL="https://gh-proxy.com/https://github.com/Zephyruso/zashboard/archive/refs/heads/gh-pages.zip"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

install_ui() {
    echo -e "${YELLOW}>>> 正在下载并安装 Zashboard 面板...${NC}"
    curl -L -o /tmp/ui.zip "$UI_URL"
    if [ $? -eq 0 ]; then
        rm -rf "$CONF_DIR/ui"/*
        unzip -q -o /tmp/ui.zip -d /tmp/ui_extract
        cp -r /tmp/ui_extract/*/* "$CONF_DIR/ui/"
        rm -rf /tmp/ui.zip /tmp/ui_extract
        echo -e "${GREEN}Web 面板安装成功。${NC}"
    else
        echo -e "${RED}面板下载失败。${NC}"
    fi
}

edit_config() {
    source "$SUB_INFO"
    while true; do
        clear
        echo -e "${CYAN}========== 修改配置 ==========${NC}"
        echo -e "1) 订阅链接: ${YELLOW}$SUB_URL${NC}"
        echo -e "2) 通知接口: ${YELLOW}$NOTIFY_URL${NC}"
        echo -e "3) 更新频率: ${YELLOW}${SUB_INTERVAL} 分钟${NC}"
        echo -e "s) 保存并应用"
        echo -e "q) 返回"
        read -p "选择修改项 (1/2/3/s/q): " ch
        case $ch in
            1) read -p "新订阅链接: " SUB_URL ;;
            2) read -p "新通知接口: " NOTIFY_URL ;;
            3) read -p "新更新频率(分钟): " SUB_INTERVAL ;;
            s) 
               echo "SUB_URL=\"$SUB_URL\"" > "$SUB_INFO"
               echo "NOTIFY_URL=\"$NOTIFY_URL\"" >> "$SUB_INFO"
               echo "SUB_INTERVAL=\"$SUB_INTERVAL\"" >> "$SUB_INFO"
               cat > /etc/systemd/system/mihomo-update.timer <<EOF2
[Timer]
OnBootSec=5min
OnUnitActiveSec=${SUB_INTERVAL}min
[Install]
WantedBy=timers.target
EOF2
               systemctl daemon-reload
               systemctl restart mihomo-update.timer
               echo -e "${GREEN}设置已保存并生效。${NC}" ; sleep 1 ; break ;;
            q) break ;;
        esac
    done
}

while true; do
    clear
    IP=$(hostname -I | awk '{print $1}')
    echo -e "${BLUE}================ Mihomo 管理面板 ================${NC}"
    if systemctl is-active --quiet mihomo; then
        echo -e "状态: ${GREEN}● 运行中${NC} | 面板: ${GREEN}http://${IP}:9090/ui${NC}"
    else
        echo -e "状态: ${RED}● 已停止${NC} (服务将在5秒内自动重启)"
    fi
    echo -e "------------------------------------------------"
    echo -e "1. ${GREEN}启动${NC}  2. ${RED}停止${NC}  3. ${YELLOW}重启${NC}  4. 查看运行日志"
    echo -e "5. ${CYAN}修改配置 (订阅/通知/频率)${NC}"
    echo -e "6. 立即更新订阅配置"
    echo -e "7. 高级: 手动编辑 config.yaml"
    echo -e "8. 安装/更新 Web 管理面板 (Zashboard)"
    echo -e "------------------------------------------------"
    echo -e "9. ${RED}完全卸载${NC}  0. 退出"
    read -p "请输入选项: " opt
    case $opt in
        1) systemctl start mihomo ;;
        2) systemctl stop mihomo ;;
        3) systemctl restart mihomo ;;
        4) journalctl -u mihomo -f -n 50 ;;
        5) edit_config ;;
        6) bash "$UPDATE_SH"; read -p "按回车返回..." ;;
        7) nano /etc/mihomo/config.yaml; systemctl restart mihomo ;;
        8) install_ui; read -p "按回车返回..." ;;
        9) systemctl disable --now mihomo mihomo-update.timer; rm -rf /etc/mihomo /usr/local/bin/mihomo* /etc/systemd/system/mihomo*; systemctl daemon-reload; exit 0 ;;
        0) exit 0 ;;
    esac
done
EOF
chmod +x "$MIHOMO_BIN"

# --- 8. 首次启动初始化 ---
echo -e "\n${YELLOW}>>> 正在拉取首次订阅配置...${NC}"
bash "$UPDATE_SCRIPT"

# 自动安装 Web 面板
bash -c "source $MIHOMO_BIN; install_ui" >/dev/null 2>&1

systemctl daemon-reload
systemctl enable --now mihomo mihomo-update.timer

echo -e "\n${GREEN}===============================================${NC}"
echo -e "${GREEN}部署完成！${NC}"
echo -e "服务已通过 Systemd 守护，崩溃后 5 秒内自动重启。"
echo -e "请输入指令 ${YELLOW}mihomo${NC} 进入管理菜单。"
echo -e "${GREEN}===============================================${NC}"
rm -f "$0"
