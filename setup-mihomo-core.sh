#!/bin/bash

# =========================================================
# Mihomo Gateway - Auto-healing Edition (中文彩色定制版)
# =========================================================

MIHOMO_BIN="/usr/local/bin/mihomo"
CORE_BIN="/usr/local/bin/mihomo-core"
UPDATE_SCRIPT="/usr/local/bin/mihomo-update.sh"
WATCHDOG_SCRIPT="/usr/local/bin/mihomo-watchdog.sh"
NOTIFY_SCRIPT="/usr/local/bin/mihomo-notify.sh"
CONF_DIR="/etc/mihomo"
CONF_FILE="$CONF_DIR/config.yaml"
SUB_INFO_FILE="$CONF_DIR/.subscription_info"
SERVICE_FILE="/etc/systemd/system/mihomo.service"

# 定义颜色
C_RED="\e[1;31m"
C_GREEN="\e[1;32m"
C_YELLOW="\e[1;33m"
C_BLUE="\e[1;34m"
C_MAGENTA="\e[1;35m"
C_CYAN="\e[1;36m"
C_RESET="\e[0m"

# =================================================================
# 函数：检查 LXC 容器是否已配置 TUN 设备
# =================================================================
check_lxc_tun() {
    if [ ! -c /dev/net/tun ]; then
        clear
        echo -e "${C_RED}[错误] 检测到当前 LXC 容器未开启 TUN 设备支持！${C_RESET}"
        echo -e "${C_YELLOW}Mihomo 和网络相关服务需要 TUN 支持才能正常运行。${C_RESET}"
        echo ""
        echo -e "${C_MAGENTA}=================================================================${C_RESET}"
        echo -e "请按照以下步骤修改 PVE 宿主机配置，然后重启容器并重新运行此脚本："
        echo -e "${C_MAGENTA}=================================================================${C_RESET}"
        echo -e "1. 登录到 ${C_CYAN}PVE 宿主机${C_RESET} (注意：不是当前容器)。"
        echo -e "2. 找到当前容器的 ID (例如 100)，编辑其配置文件："
        echo -e "   ${C_CYAN}nano /etc/pve/lxc/<你的容器ID>.conf${C_RESET}"
        echo -e "3. 在文件末尾添加以下两行："
        echo -e "   ${C_GREEN}lxc.cgroup2.devices.allow: c 10:200 rwm${C_RESET}"
        echo -e "   ${C_GREEN}lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file${C_RESET}"
        echo -e "4. 保存并退出。"
        echo -e "5. 重启该 LXC 容器 (在 PVE Web 界面操作，或运行 ${C_CYAN}pct reboot <你的容器ID>${C_RESET})。"
        echo ""
        echo -e "${C_RED}脚本已终止。请在完成上述修改并重启 LXC 后，重新运行本脚本。${C_RESET}"
        exit 1
    fi
}

# --- 基础权限与环境检查 ---
if [ "$EUID" -ne 0 ]; then
    echo -e "${C_RED}错误: 必须使用 root 权限运行此脚本。${C_RESET}"
    exit 1
fi
if [ "$(basename "$0")" == "mihomo" ]; then
    echo -e "${C_RED}错误: 脚本名称不能为 'mihomo'，请重命名为 install.sh。${C_RESET}"
    exit 1
fi
if [ -f "$CORE_BIN" ] && [ -f "$MIHOMO_BIN" ]; then
    bash "$MIHOMO_BIN"
    exit 0
fi

# =========================================================
# 执行 LXC TUN 检查
# =========================================================
check_lxc_tun

clear
echo -e "${C_MAGENTA}==========================================${C_RESET}"
echo -e "${C_CYAN}    >>> Mihomo 网关一键安装脚本 (自愈版) <<<${C_RESET}"
echo -e "${C_MAGENTA}==========================================${C_RESET}"

# 1. 依赖与环境
echo -e "\n${C_YELLOW}[1/7] 正在安装系统依赖环境...${C_RESET}"
PACKAGES="curl gzip tar nano unzip jq gawk bc"
if [ -f /etc/debian_version ]; then
    apt update -q && apt install -y $PACKAGES -q
elif [ -f /etc/alpine-release ]; then
    apk add $PACKAGES bash grep
fi

if ! sysctl net.ipv4.ip_forward | grep -q "1"; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    echo -e "${C_GREEN}已开启 IPv4 转发${C_RESET}"
fi

# 2. 二进制与资源
echo -e "${C_YELLOW}[2/7] 正在获取核心组件和 Geo 数据...${C_RESET}"
GH_PROXY="https://gh-proxy.com/"
ARCH=$(uname -m)
MIHOMO_VER="v1.18.10"
BASE_URL="${GH_PROXY}https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VER}"

case $ARCH in
    x86_64) DL_URL="${BASE_URL}/mihomo-linux-amd64-${MIHOMO_VER}.gz" ;;
    aarch64) DL_URL="${BASE_URL}/mihomo-linux-arm64-${MIHOMO_VER}.gz" ;;
    *) echo -e "${C_RED}不支持的架构: $ARCH${C_RESET}"; exit 1 ;;
esac

curl -L -o /tmp/mihomo.gz "$DL_URL" && gzip -d /tmp/mihomo.gz
mv /tmp/mihomo "$CORE_BIN" && chmod +x "$CORE_BIN"

mkdir -p "$CONF_DIR/ui"
curl -sL -o "$CONF_DIR/Country.mmdb" "${GH_PROXY}https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country-lite.mmdb"

# 3. 基础配置
echo -e "${C_YELLOW}[3/7] 请配置基础参数...${C_RESET}"
read -p $'\e[1;36m请输入机场订阅链接 (Sub URL): \e[0m' USER_URL
read -p $'\e[1;36m更新间隔 (分钟，直接回车默认60): \e[0m' USER_INTERVAL
[ -z "$USER_INTERVAL" ] && USER_INTERVAL=60
read -p $'\e[1;36m通知 API 地址 (可选，不需要则直接回车): \e[0m' USER_NOTIFY

echo "SUB_URL=\"$USER_URL\"" > "$SUB_INFO_FILE"
echo "SUB_INTERVAL=\"$USER_INTERVAL\"" >> "$SUB_INFO_FILE"
echo "NOTIFY_URL=\"$USER_NOTIFY\"" >> "$SUB_INFO_FILE"

# 4. 辅助脚本
echo -e "${C_YELLOW}[4/7] 正在生成后台守护脚本...${C_RESET}"

# Notify
cat > "$NOTIFY_SCRIPT" <<'EOF'
#!/bin/bash
source /etc/mihomo/.subscription_info
[ -z "$NOTIFY_URL" ] && exit 0
TS=$(date "+%Y-%m-%d %H:%M:%S")
curl -s --max-time 5 -X POST "$NOTIFY_URL" -H "Content-Type: application/json" -d "{\"title\":\"$1\", \"content\":\"$2\\nTime: $TS\"}" > /dev/null
EOF
chmod +x "$NOTIFY_SCRIPT"

# Watchdog
cat > "$WATCHDOG_SCRIPT" <<'EOF'
#!/bin/bash
NOTIFY="/usr/local/bin/mihomo-notify.sh"
STATE_FILE="/run/mihomo_net_fail_count"
CONF_FILE="/etc/mihomo/config.yaml"

MEM_USAGE=$(free | grep Mem | awk '{printf "%.0f", $3/$2 * 100.0}')
[ "$MEM_USAGE" -ge 85 ] && $NOTIFY "内存警告" "使用率: $MEM_USAGE%"

if ! grep -q "proxies:" "$CONF_FILE" && ! grep -q "proxy-providers:" "$CONF_FILE"; then
    if [ ! -f /run/mihomo_empty_notify ]; then
        $NOTIFY "看门狗暂停" "配置文件中没有找到有效代理。"
        touch /run/mihomo_empty_notify
    fi
    exit 0
fi
rm -f /run/mihomo_empty_notify

if ! systemctl is-active --quiet mihomo; then
    systemctl start mihomo
    sleep 15
fi

PROXY_PORT=$(grep "mixed-port" "$CONF_FILE" | awk '{print $2}' | tr -d '\r')
[ -z "$PROXY_PORT" ] && PROXY_PORT=7890

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -x "http://127.0.0.1:$PROXY_PORT" --max-time 5 "http://cp.cloudflare.com/generate_204")

if [ "$HTTP_CODE" == "204" ] || [ "$HTTP_CODE" == "200" ]; then
    rm -f "$STATE_FILE"
    exit 0
fi

FAIL_COUNT=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
FAIL_COUNT=$((FAIL_COUNT + 1))
echo "$FAIL_COUNT" > "$STATE_FILE"

case $FAIL_COUNT in
    1) exit 0 ;;
    2) $NOTIFY "网络中断" "正在重启 mihomo 服务。" ; systemctl restart mihomo ;;
    3) $NOTIFY "严重网络故障" "服务重启无效，正在重启虚拟机。" ; sleep 3 ; reboot ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$WATCHDOG_SCRIPT"

# Auto Update
cat > "$UPDATE_SCRIPT" <<'EOF'
#!/bin/bash
source /etc/mihomo/.subscription_info
CONF="/etc/mihomo/config.yaml"
NOTIFY="/usr/local/bin/mihomo-notify.sh"

curl -L -s --max-time 30 -o "${CONF}.tmp" "$SUB_URL"

if [ $? -eq 0 ] && [ -s "${CONF}.tmp" ]; then
    if grep -q "proxies:" "${CONF}.tmp" || grep -q "proxy-providers:" "${CONF}.tmp"; then
        [ -f "$CONF" ] && cmp -s "$CONF" "${CONF}.tmp" && rm -f "${CONF}.tmp" && exit 0
        mv "${CONF}.tmp" "$CONF"
        touch /tmp/.mihomo_mute
        systemctl try-restart mihomo
        rm -f /tmp/.mihomo_mute
        $NOTIFY "配置已更新" "新配置已成功应用。"
    else
        $NOTIFY "更新失败" "下载的配置中不含节点信息。"
        rm -f "${CONF}.tmp"
    fi
else
    $NOTIFY "更新错误" "无法获取订阅配置。"
    rm -f "${CONF}.tmp"
fi
EOF
chmod +x "$UPDATE_SCRIPT"

# 5. Systemd Services
echo -e "${C_YELLOW}[5/7] 正在注册系统服务...${C_RESET}"
cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=Mihomo Daemon
After=network.target

[Service]
Type=simple
User=root
Restart=always
ExecStart=/usr/local/bin/mihomo-core -d /etc/mihomo -f /etc/mihomo/config.yaml
ExecStartPost=/usr/bin/bash -c 'if [ ! -f /tmp/.mihomo_mute ]; then /usr/local/bin/mihomo-notify.sh "Mihomo 已启动" "PID: $MAINPID"; fi'
ExecStopPost=/usr/bin/bash -c 'if [ "$SERVICE_RESULT" != "success" ]; then /usr/local/bin/mihomo-notify.sh "Mihomo 已崩溃" "Exit Code: $EXIT_CODE"; fi'
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/mihomo-update.timer <<EOF
[Unit]
Description=Mihomo Config Update Timer
[Timer]
OnBootSec=5min
OnUnitActiveSec=${USER_INTERVAL}min
[Install]
WantedBy=timers.target
EOF
cat > /etc/systemd/system/mihomo-update.service <<EOF
[Unit]
Description=Mihomo Config Update
[Service]
Type=oneshot
ExecStart=$UPDATE_SCRIPT
EOF

cat > /etc/systemd/system/mihomo-watchdog.timer <<EOF
[Unit]
Description=Mihomo Watchdog Timer
[Timer]
OnBootSec=2min
OnUnitActiveSec=3min
[Install]
WantedBy=timers.target
EOF
cat > /etc/systemd/system/mihomo-watchdog.service <<EOF
[Unit]
Description=Mihomo Network Watchdog
[Service]
Type=oneshot
ExecStart=$WATCHDOG_SCRIPT
EOF

systemctl daemon-reload

# 6. CLI Manager
echo -e "${C_YELLOW}[6/7] 正在生成管理控制台...${C_RESET}"
cat > "$MIHOMO_BIN" <<'EOF'
#!/bin/bash
CONF_DIR="/etc/mihomo"
SUB_FILE="$CONF_DIR/.subscription_info"

# 控制台颜色定义
C_RED="\e[1;31m"
C_GREEN="\e[1;32m"
C_YELLOW="\e[1;33m"
C_BLUE="\e[1;34m"
C_MAGENTA="\e[1;35m"
C_CYAN="\e[1;36m"
C_RESET="\e[0m"

check_status() {
    IP=$(hostname -I | awk '{print $1}')
    [ -z "$IP" ] && IP="<当前IP>"
    if systemctl is-active --quiet mihomo; then
        echo -e "核心状态: ${C_GREEN}● 运行中${C_RESET} | 面板地址: ${C_BLUE}http://${IP}:9090/ui${C_RESET}"
    else
        echo -e "核心状态: ${C_RED}○ 已停止${C_RESET}"
    fi
}

update_ui() {
    echo -e "${C_YELLOW}正在更新 Zashboard 面板...${C_RESET}"
    curl -L -o /tmp/ui.zip "https://gh-proxy.com/https://github.com/Zephyruso/zashboard/archive/refs/heads/gh-pages.zip"
    if [ $? -eq 0 ]; then
        rm -rf "$CONF_DIR/ui"/*
        unzip -q -o /tmp/ui.zip -d /tmp/ui_extract
        cp -r /tmp/ui_extract/*/* "$CONF_DIR/ui/"
        rm -rf /tmp/ui.zip /tmp/ui_extract
        echo -e "${C_GREEN}面板已更新完毕。${C_RESET}"
    fi
    [ "$1" != "auto" ] && read -p $'\e[1;36m按回车键继续... \e[0m'
}

while true; do
    clear
    echo -e "${C_MAGENTA}=============================================${C_RESET}"
    echo -e "${C_CYAN}         ✨ Mihomo 网关管理控制台 ✨         ${C_RESET}"
    echo -e "${C_MAGENTA}=============================================${C_RESET}"
    check_status
    echo -e "${C_MAGENTA}---------------------------------------------${C_RESET}"
    echo -e " ${C_GREEN}1. 启动服务${C_RESET}       ${C_RED}2. 停止服务${C_RESET}       ${C_YELLOW}3. 重启服务${C_RESET}"
    echo -e " ${C_CYAN}4. 查看日志${C_RESET}       ${C_CYAN}5. 编辑配置${C_RESET}       ${C_CYAN}6. 强制更新订阅${C_RESET}"
    echo -e " ${C_CYAN}7. 更新面板${C_RESET}       ${C_RED}8. 彻底卸载${C_RESET}       ${C_MAGENTA}0. 退出管理${C_RESET}"
    echo -e "${C_MAGENTA}---------------------------------------------${C_RESET}"
    read -p $'\e[1;32m请输入选项数字 [0-8]: \e[0m' choice
    case $choice in
        1) systemctl start mihomo ; echo -e "${C_GREEN}服务已启动${C_RESET}" ; sleep 1 ;;
        2) systemctl stop mihomo ; echo -e "${C_RED}服务已停止${C_RESET}" ; sleep 1 ;;
        3) systemctl restart mihomo ; echo -e "${C_YELLOW}服务已重启${C_RESET}" ; sleep 1 ;;
        4) journalctl -u mihomo -f -n 50 ;;
        5) nano /etc/mihomo/config.yaml && systemctl restart mihomo ;;
        6) /usr/local/bin/mihomo-update.sh ; read -p $'\e[1;36m更新完成，按回车键继续... \e[0m' ;;
        7) update_ui ;;
        8) systemctl stop mihomo mihomo-update.timer mihomo-watchdog.timer; systemctl disable mihomo mihomo-update.timer mihomo-watchdog.timer; rm -rf /etc/mihomo /usr/local/bin/mihomo* /etc/systemd/system/mihomo*; systemctl daemon-reload; echo -e "${C_GREEN}卸载完成！${C_RESET}"; exit 0 ;;
        0) exit 0 ;;
    esac
done
EOF
chmod +x "$MIHOMO_BIN"

# 7. Finalize
echo -e "${C_YELLOW}[7/7] 正在启动所有服务...${C_RESET}"
/usr/local/bin/mihomo-notify.sh "系统上线" "Mihomo 看门狗初始化完毕。"
bash "$UPDATE_SCRIPT"
systemctl enable --now mihomo-update.timer
systemctl enable --now mihomo-watchdog.timer
bash -c "source $MIHOMO_BIN; update_ui auto >/dev/null 2>&1"

rm -f "$0"
bash "$MIHOMO_BIN"
