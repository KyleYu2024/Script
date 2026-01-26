#!/bin/bash

# =========================================================
# Mihomo Gateway - Auto-healing Edition
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

# =================================================================
# 函数：检查 LXC 容器是否已配置 TUN 设备
# =================================================================
check_lxc_tun() {
    # 检查 /dev/net/tun 是否存在且为字符设备
    if [ ! -c /dev/net/tun ]; then
        clear
        echo -e "\e[31m[错误] 检测到当前 LXC 容器未开启 TUN 设备支持！\e[0m"
        echo -e "\e[33mMihomo 和网络相关服务需要 TUN 支持才能正常运行。\e[0m"
        echo ""
        echo -e "================================================================="
        echo -e "请按照以下步骤修改 PVE 宿主机配置，然后重启容器并重新运行此脚本："
        echo -e "================================================================="
        echo -e "1. 登录到 \e[1mPVE 宿主机\e[0m (注意：不是当前容器)。"
        echo -e "2. 找到当前容器的 ID (例如 100)，编辑其配置文件："
        echo -e "   \e[36mnano /etc/pve/lxc/<你的容器ID>.conf\e[0m"
        echo -e "3. 在文件末尾添加以下两行："
        echo -e "   \e[1;32mlxc.cgroup2.devices.allow: c 10:200 rwm\e[0m"
        echo -e "   \e[1;32mlxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file\e[0m"
        echo -e "4. 保存并退出。"
        echo -e "5. 重启该 LXC 容器 (在 PVE Web 界面操作，或运行 \e[36mpct reboot <你的容器ID>\e[0m)。"
        echo ""
        echo -e "\e[31m脚本已终止。请在完成上述修改并重启 LXC 后，重新运行本脚本。\e[0m"
        exit 1 # 退出脚本，不再继续执行
    fi
}

# --- 基础权限与环境检查 ---
if [ "$EUID" -ne 0 ]; then
    echo "Error: Root privileges required."
    exit 1
fi
if [ "$(basename "$0")" == "mihomo" ]; then
    echo "Error: Script cannot be named 'mihomo'. Rename to install.sh."
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
echo ">>> Mihomo Gateway Installer"

# 1. 依赖与环境
echo "[1/7] Installing dependencies..."
PACKAGES="curl gzip tar nano unzip jq gawk bc"
if [ -f /etc/debian_version ]; then
    apt update -q && apt install -y $PACKAGES -q
elif [ -f /etc/alpine-release ]; then
    apk add $PACKAGES bash grep
fi

if ! sysctl net.ipv4.ip_forward | grep -q "1"; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
fi

# 2. 二进制与资源
echo "[2/7] Fetching core and MMDB..."
GH_PROXY="https://gh-proxy.com/"
ARCH=$(uname -m)
MIHOMO_VER="v1.18.10"
BASE_URL="${GH_PROXY}https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VER}"

case $ARCH in
    x86_64) DL_URL="${BASE_URL}/mihomo-linux-amd64-${MIHOMO_VER}.gz" ;;
    aarch64) DL_URL="${BASE_URL}/mihomo-linux-arm64-${MIHOMO_VER}.gz" ;;
    *) echo "Unsupported arch: $ARCH"; exit 1 ;;
esac

curl -L -o /tmp/mihomo.gz "$DL_URL" && gzip -d /tmp/mihomo.gz
mv /tmp/mihomo "$CORE_BIN" && chmod +x "$CORE_BIN"

mkdir -p "$CONF_DIR/ui"
curl -sL -o "$CONF_DIR/Country.mmdb" "${GH_PROXY}https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country-lite.mmdb"

# 3. 基础配置
echo "[3/7] Configuration..."
read -p "Sub URL: " USER_URL
read -p "Update Interval (mins, def:60): " USER_INTERVAL
[ -z "$USER_INTERVAL" ] && USER_INTERVAL=60
read -p "Notify API URL (Optional): " USER_NOTIFY

echo "SUB_URL=\"$USER_URL\"" > "$SUB_INFO_FILE"
echo "SUB_INTERVAL=\"$USER_INTERVAL\"" >> "$SUB_INFO_FILE"
echo "NOTIFY_URL=\"$USER_NOTIFY\"" >> "$SUB_INFO_FILE"

# 4. 辅助脚本
echo "[4/7] Generating scripts..."

# Notify
cat > "$NOTIFY_SCRIPT" <<'EOF'
#!/bin/bash
source /etc/mihomo/.subscription_info
[ -z "$NOTIFY_URL" ] && exit 0
TS=$(date "+%Y-%m-%d %H:%M:%S")
curl -s --max-time 5 -X POST "$NOTIFY_URL" -H "Content-Type: application/json" -d "{\"title\":\"$1\", \"content\":\"$2\\nTime: $TS\"}" > /dev/null
EOF
chmod +x "$NOTIFY_SCRIPT"

# Watchdog (Refactored)
cat > "$WATCHDOG_SCRIPT" <<'EOF'
#!/bin/bash
NOTIFY="/usr/local/bin/mihomo-notify.sh"
# State kept in memory, cleared on VM reboot
STATE_FILE="/run/mihomo_net_fail_count"
CONF_FILE="/etc/mihomo/config.yaml"

# 1. RAM Check
MEM_USAGE=$(free | grep Mem | awk '{printf "%.0f", $3/$2 * 100.0}')
[ "$MEM_USAGE" -ge 85 ] && $NOTIFY "RAM Alert" "Usage: $MEM_USAGE%"

# 2. Config Validation
if ! grep -q "proxies:" "$CONF_FILE" && ! grep -q "proxy-providers:" "$CONF_FILE"; then
    if [ ! -f /run/mihomo_empty_notify ]; then
        $NOTIFY "Watchdog Suspended" "No valid proxies found in config."
        touch /run/mihomo_empty_notify
    fi
    exit 0
fi
rm -f /run/mihomo_empty_notify

# 3. Service Status
if ! systemctl is-active --quiet mihomo; then
    systemctl start mihomo
    sleep 15 # Wait for service warmup
fi

# 4. Net Check
PROXY_PORT=$(grep "mixed-port" "$CONF_FILE" | awk '{print $2}' | tr -d '\r')
[ -z "$PROXY_PORT" ] && PROXY_PORT=7890

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -x "http://127.0.0.1:$PROXY_PORT" --max-time 5 "http://cp.cloudflare.com/generate_204")

if [ "$HTTP_CODE" == "204" ] || [ "$HTTP_CODE" == "200" ]; then
    rm -f "$STATE_FILE"
    exit 0
fi

# 5. Fault Handler
FAIL_COUNT=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
FAIL_COUNT=$((FAIL_COUNT + 1))
echo "$FAIL_COUNT" > "$STATE_FILE"

case $FAIL_COUNT in
    1)  # Fluctuation, pass.
        exit 0 ;;
    2)  # Level 1: Restart Service
        $NOTIFY "Net Drop" "Restarting mihomo service."
        systemctl restart mihomo ;;
    3)  # Level 2: Reboot VM
        $NOTIFY "Critical Net Fail" "Service restart failed. Rebooting VM now."
        sleep 3
        reboot ;;
    *)  # Fallback
        exit 0 ;;
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
        $NOTIFY "Config Updated" "New configuration applied."
    else
        $NOTIFY "Update Failed" "No proxies in downloaded config."
        rm -f "${CONF}.tmp"
    fi
else
    $NOTIFY "Update Error" "Failed to fetch subscription."
    rm -f "${CONF}.tmp"
fi
EOF
chmod +x "$UPDATE_SCRIPT"

# 5. Systemd Services
echo "[5/7] Registering Systemd..."
cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=Mihomo Daemon
After=network.target

[Service]
Type=simple
User=root
Restart=always
ExecStart=/usr/local/bin/mihomo-core -d /etc/mihomo -f /etc/mihomo/config.yaml
ExecStartPost=/usr/bin/bash -c 'if [ ! -f /tmp/.mihomo_mute ]; then /usr/local/bin/mihomo-notify.sh "Mihomo Started" "PID: $MAINPID"; fi'
ExecStopPost=/usr/bin/bash -c 'if [ "$SERVICE_RESULT" != "success" ]; then /usr/local/bin/mihomo-notify.sh "Mihomo Crashed" "Exit Code: $EXIT_CODE"; fi'
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
echo "[6/7] Generating CLI manager..."
cat > "$MIHOMO_BIN" <<'EOF'
#!/bin/bash
CONF_DIR="/etc/mihomo"
SUB_FILE="$CONF_DIR/.subscription_info"

check_status() {
    IP=$(hostname -I | awk '{print $1}')
    [ -z "$IP" ] && IP="<IP>"
    if systemctl is-active --quiet mihomo; then
        echo "Status: Running | UI: http://${IP}:9090/ui"
    else
        echo "Status: Stopped"
    fi
}

update_ui() {
    echo "Updating Zashboard..."
    curl -L -o /tmp/ui.zip "https://gh-proxy.com/https://github.com/Zephyruso/zashboard/archive/refs/heads/gh-pages.zip"
    if [ $? -eq 0 ]; then
        rm -rf "$CONF_DIR/ui"/*
        unzip -q -o /tmp/ui.zip -d /tmp/ui_extract
        cp -r /tmp/ui_extract/*/* "$CONF_DIR/ui/"
        rm -rf /tmp/ui.zip /tmp/ui_extract
        echo "UI Updated."
    fi
    [ "$1" != "auto" ] && read -p "Press Enter..."
}

while true; do
    clear
    echo "=== Mihomo Gateway CLI ==="
    check_status
    echo "--------------------------"
    echo "1. Start      2. Stop       3. Restart"
    echo "4. Logs       5. Edit Conf  6. Force Sub"
    echo "7. Web UI     8. Uninstall  0. Exit"
    echo "--------------------------"
    read -p "Choice: " choice
    case $choice in
        1) systemctl start mihomo ;;
        2) systemctl stop mihomo ;;
        3) systemctl restart mihomo ;;
        4) journalctl -u mihomo -f -n 50 ;;
        5) nano /etc/mihomo/config.yaml && systemctl restart mihomo ;;
        6) /usr/local/bin/mihomo-update.sh ; read -p "Done..." ;;
        7) update_ui ;;
        8) systemctl stop mihomo mihomo-update.timer mihomo-watchdog.timer; systemctl disable mihomo mihomo-update.timer mihomo-watchdog.timer; rm -rf /etc/mihomo /usr/local/bin/mihomo* /etc/systemd/system/mihomo*; systemctl daemon-reload; exit 0 ;;
        0) exit 0 ;;
    esac
done
EOF
chmod +x "$MIHOMO_BIN"

# 7. Finalize
echo "[7/7] Starting services..."
/usr/local/bin/mihomo-notify.sh "System Online" "Mihomo Watchdog Init."
bash "$UPDATE_SCRIPT"
systemctl enable --now mihomo-update.timer
systemctl enable --now mihomo-watchdog.timer
bash -c "source $MIHOMO_BIN; update_ui auto >/dev/null 2>&1"

rm -f "$0"
bash "$MIHOMO_BIN"
