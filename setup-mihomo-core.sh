#!/bin/bash

# =========================================================
# Mihomo 部署脚本 (全加速 + 完整管理菜单 + 终极自愈版)
# =========================================================

# --- 1. 全局配置 ---
MIHOMO_BIN="/usr/local/bin/mihomo"
CORE_BIN="/usr/local/bin/mihomo-core"
UPDATE_SCRIPT="/usr/local/bin/mihomo-update.sh"
WATCHDOG_SCRIPT="/usr/local/bin/mihomo-watchdog.sh"
NOTIFY_SCRIPT="/usr/local/bin/mihomo-notify.sh"
CONF_DIR="/etc/mihomo"
CONF_FILE="$CONF_DIR/config.yaml"
SUB_INFO_FILE="$CONF_DIR/.subscription_info"
SERVICE_FILE="/etc/systemd/system/mihomo.service"

# 国内加速镜像源
GH_PROXY="https://mirror.ghproxy.com/"

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- 权限检查 ---
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}错误: 请使用 root 权限运行此脚本！${NC}"
  exit 1
fi

clear
echo -e "${BLUE}#################################################${NC}"
echo -e "${BLUE}#      Mihomo 裸核网关 (全加速自愈完整版)      #${NC}"
echo -e "${BLUE}#################################################${NC}"

# =========================================================
# 2. 环境与依赖安装
# =========================================================
echo -e "\n${YELLOW}>>> [1/7] 安装系统依赖与网络优化...${NC}"
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

# =========================================================
# 3. 核心与数据库拉取
# =========================================================
echo -e "\n${YELLOW}>>> [2/7] 下载核心与数据库 (加速镜像)...${NC}"
ARCH=$(uname -m)
MIHOMO_VER="v1.18.10"
BASE_URL="${GH_PROXY}https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VER}"

case $ARCH in
    x86_64) DL_URL="${BASE_URL}/mihomo-linux-amd64-${MIHOMO_VER}.gz" ;;
    aarch64) DL_URL="${BASE_URL}/mihomo-linux-arm64-${MIHOMO_VER}.gz" ;;
    *) echo -e "${RED}不支持的架构: $ARCH${NC}"; exit 1 ;;
esac

curl -L -o /tmp/mihomo.gz "$DL_URL" && gzip -d /tmp/mihomo.gz
mv /tmp/mihomo "$CORE_BIN" && chmod +x "$CORE_BIN"

mkdir -p "$CONF_DIR/ui"
curl -sL -o "$CONF_DIR/Country.mmdb" "${GH_PROXY}https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country-lite.mmdb"

# =========================================================
# 4. 交互式配置
# =========================================================
echo -e "\n${YELLOW}>>> [3/7] 配置参数...${NC}"
read -p "请输入订阅链接: " USER_URL
read -p "请输入更新间隔 (分钟, 默认60): " USER_INTERVAL
[ -z "$USER_INTERVAL" ] && USER_INTERVAL=60
read -p "请输入 Notify 通知接口地址: " USER_NOTIFY

echo "SUB_URL=\"$USER_URL\"" > "$SUB_INFO_FILE"
echo "SUB_INTERVAL=\"$USER_INTERVAL\"" >> "$SUB_INFO_FILE"
echo "NOTIFY_URL=\"$USER_NOTIFY\"" >> "$SUB_INFO_FILE"

# =========================================================
# 5. 核心脚本生成 (通知、监控、更新)
# =========================================================

# A. 通知脚本
cat > "$NOTIFY_SCRIPT" <<'EOF'
#!/bin/bash
source /etc/mihomo/.subscription_info
if [ -n "$NOTIFY_URL" ]; then
    CURRENT_TIME=$(date "+%Y-%m-%d %H:%M:%S")
    curl -s --max-time 5 -X POST "$NOTIFY_URL" -H "Content-Type: application/json" -d "{\"title\":\"$1\", \"content\":\"$2\\n时间: $CURRENT_TIME\"}" > /dev/null 2>&1
fi
EOF
chmod +x "$NOTIFY_SCRIPT"

# B. Watchdog 脚本 (纠错重启逻辑)
cat > "$WATCHDOG_SCRIPT" <<'EOF'
#!/bin/bash
NOTIFY="/usr/local/bin/mihomo-notify.sh"
FAIL_COUNT_FILE="/tmp/mihomo_fail_count"

if ! systemctl is-active --quiet mihomo; then
    systemctl start mihomo
    sleep 5
    if ! systemctl is-active --quiet mihomo; then
        systemctl daemon-reload && systemctl restart mihomo
    fi
fi

PROXY_PORT=$(grep "mixed-port" /etc/mihomo/config.yaml | awk '{print $2}' | tr -d '\r')
[ -z "$PROXY_PORT" ] && PROXY_PORT=7890
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -x "http://127.0.0.1:$PROXY_PORT" --max-time 10 "http://cp.cloudflare.com/generate_204")

if [ "$HTTP_CODE" != "204" ] && [ "$HTTP_CODE" != "200" ]; then
    COUNT=$(cat $FAIL_COUNT_FILE 2>/dev/null || echo 0)
    COUNT=$((COUNT + 1))
    echo $COUNT > $FAIL_COUNT_FILE
    if [ "$COUNT" -ge 3 ]; then
        $NOTIFY "🚨 终极修复：重启系统" "连续 3 次尝试自愈失败，正在重启虚拟机"
        rm -f $FAIL_COUNT_FILE
        sync && sleep 2 && reboot
    else
        $NOTIFY "🌐 网络异常 ($COUNT/3)" "检测到断网，重启服务中..."
        systemctl restart mihomo
    fi
else
    echo 0 > $FAIL_COUNT_FILE
fi
EOF
chmod +x "$WATCHDOG_SCRIPT"

# C. 自动更新脚本
cat > "$UPDATE_SCRIPT" <<'EOF'
#!/bin/bash
source /etc/mihomo/.subscription_info
CONF_FILE="/etc/mihomo/config.yaml"
NOTIFY="/usr/local/bin/mihomo-notify.sh"

curl -L -s --max-time 30 -o "${CONF_FILE}.tmp" "$SUB_URL"
if [ $? -eq 0 ] && [ -s "${CONF_FILE}.tmp" ]; then
    if grep -q "proxies:" "${CONF_FILE}.tmp" || grep -q "proxy-providers:" "${CONF_FILE}.tmp"; then
        mv "${CONF_FILE}.tmp" "$CONF_FILE"
        touch /tmp/.mihomo_mute_notify
        systemctl try-restart mihomo
        rm -f /tmp/.mihomo_mute_notify
        $NOTIFY "🔄 订阅配置已更新" "检测到配置变更，已应用并重启服务"
    fi
fi
EOF
chmod +x "$UPDATE_SCRIPT"

# =========================================================
# 6. 注册 Systemd 服务
# =========================================================
cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=Mihomo Daemon
After=network.target

[Service]
Type=simple
User=root
Restart=always
RestartSec=5
ExecStart=/usr/local/bin/mihomo-core -d /etc/mihomo -f /etc/mihomo/config.yaml
ExecStartPost=/usr/bin/bash -c 'if [ ! -f /tmp/.mihomo_mute_notify ]; then /usr/local/bin/mihomo-notify.sh "✅ Mihomo 服务已启动" "服务运行正常"; fi'
ExecStopPost=/usr/bin/bash -c 'if [ "$SERVICE_RESULT" != "success" ]; then /usr/local/bin/mihomo-notify.sh "❌ Mihomo 异常退出" "状态: $SERVICE_RESULT"; fi'

CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW

[Install]
WantedBy=multi-user.target
EOF

# 定时器单元
cat > /etc/systemd/system/mihomo-update.timer <<EOF
[Unit]
Description=Timer for Mihomo Update
[Timer]
OnBootSec=5min
OnUnitActiveSec=${USER_INTERVAL}min
[Install]
WantedBy=timers.target
EOF
cat > /etc/systemd/system/mihomo-update.service <<EOF
[Unit]
Description=Auto Update Mihomo
[Service]
Type=oneshot
ExecStart=$UPDATE_SCRIPT
EOF
cat > /etc/systemd/system/mihomo-watchdog.timer <<EOF
[Unit]
Description=Timer for Mihomo Watchdog
[Timer]
OnBootSec=2min
OnUnitActiveSec=3min
[Install]
WantedBy=timers.target
EOF
cat > /etc/systemd/system/mihomo-watchdog.service <<EOF
[Unit]
Description=Mihomo Watchdog
[Service]
Type=oneshot
ExecStart=$WATCHDOG_SCRIPT
EOF

systemctl daemon-reload

# =========================================================
# 7. 写入完整管理菜单脚本
# =========================================================
cat > "$MIHOMO_BIN" <<'EOF'
#!/bin/bash
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

check_status() {
    IP=$(hostname -I | awk '{print $1}')
    if systemctl is-active --quiet mihomo; then
        echo -e "状态: ${GREEN}● 运行中${NC}"
        echo -e "面板: ${GREEN}http://${IP}:9090/ui${NC}"
    else
        echo -e "状态: ${RED}● 已停止${NC}"
    fi
}

update_ui() {
    echo -e "${YELLOW}正在更新 Web 面板...${NC}"
    GH_PROXY="https://mirror.ghproxy.com/"
    UI_URL="${GH_PROXY}https://github.com/Zephyruso/zashboard/archive/refs/heads/gh-pages.zip"
    curl -L -o /tmp/ui.zip "$UI_URL"
    unzip -q -o /tmp/ui.zip -d /tmp/ui_extract
    mkdir -p /etc/mihomo/ui
    cp -r /tmp/ui_extract/*/* /etc/mihomo/ui/
    rm -rf /tmp/ui.zip /tmp/ui_extract
    echo -e "${GREEN}面板更新完成！${NC}"
}

while true; do
    clear
    echo -e "${BLUE}########################################${NC}"
    echo -e "${BLUE}#           Mihomo 管理面板            #${NC}"
    echo -e "${BLUE}########################################${NC}"
    check_status
    echo ""
    echo "1. 启动服务  2. 停止服务  3. 重启服务"
    echo "4. 查看日志  5. 立即更新订阅 6. 更新Web面板"
    echo "7. 卸载程序  0. 退出"
    echo ""
    read -p "选择操作: " choice
    case $choice in
        1) systemctl start mihomo ;;
        2) systemctl stop mihomo ;;
        3) systemctl restart mihomo ;;
        4) journalctl -u mihomo -f -n 50 ;;
        5) bash /usr/local/bin/mihomo-update.sh ;;
        6) update_ui ;;
        7) systemctl stop mihomo mihomo-update.timer mihomo-watchdog.timer
           systemctl disable mihomo mihomo-update.timer mihomo-watchdog.timer
           rm -rf /etc/mihomo /usr/local/bin/mihomo* /etc/systemd/system/mihomo*
           systemctl daemon-reload
           echo "已卸载。"; exit 0 ;;
        0) exit 0 ;;
    esac
done
EOF
chmod +x "$MIHOMO_BIN"

# =========================================================
# 8. 最终部署与启动
# =========================================================
echo -e "\n${YELLOW}>>> [7/7] 正在初始化服务...${NC}"

systemctl enable mihomo
systemctl enable mihomo-update.timer
systemctl enable mihomo-watchdog.timer

# 首次面板下载
GH_PROXY="https://mirror.ghproxy.com/"
UI_URL="${GH_PROXY}https://github.com/Zephyruso/zashboard/archive/refs/heads/gh-pages.zip"
curl -L -o /tmp/ui.zip "$UI_URL" && unzip -q -o /tmp/ui.zip -d /tmp/ui_extract
cp -r /tmp/ui_extract/*/* "$CONF_DIR/ui/" && rm -rf /tmp/ui.zip /tmp/ui_extract

# 发送通知 (严格顺序)
$NOTIFY_SCRIPT "🎉 Mihomo 已部署完成" "全加速镜像已生效，自愈监控已就绪"
sleep 3
bash "$UPDATE_SCRIPT"

systemctl start mihomo-update.timer
systemctl start mihomo-watchdog.timer

rm -f "$0"
echo -e "${GREEN}恭喜！全部安装已完成。${NC}"
bash "$MIHOMO_BIN"
