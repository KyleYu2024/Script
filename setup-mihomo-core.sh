#!/bin/bash

# =========================================================
# Mihomo 部署脚本
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

GH_PROXY="https://mirror.ghproxy.com/"

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}错误: 请使用 root 权限运行此脚本！${NC}"
  exit 1
fi

clear
echo -e "${BLUE}#################################################${NC}"
echo -e "${BLUE}#      Mihomo 裸核网关 (最终逻辑修正版)        #${NC}"
echo -e "${BLUE}#################################################${NC}"

# =========================================================
# 2. 环境与依赖
# =========================================================
echo -e "\n${YELLOW}>>> [1/7] 安装系统依赖...${NC}"
PACKAGES="curl gzip tar nano unzip jq gawk bc"
if [ -f /etc/debian_version ]; then
    apt update -q && apt install -y $PACKAGES -q
elif [ -f /etc/alpine-release ]; then
    apk add $PACKAGES bash grep
fi

# =========================================================
# 3. 下载核心与数据库
# =========================================================
echo -e "\n${YELLOW}>>> [2/7] 下载核心与数据库...${NC}"
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
# 4. 交互配置
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
# 5. 核心脚本 (使用 EOF 确保不解释变量)
# =========================================================

# 通知
cat > "$NOTIFY_SCRIPT" << 'EOF'
#!/bin/bash
source /etc/mihomo/.subscription_info
if [ -n "$NOTIFY_URL" ]; then
    CURRENT_TIME=$(date "+%Y-%m-%d %H:%M:%S")
    curl -s --max-time 5 -X POST "$NOTIFY_URL" -H "Content-Type: application/json" -d "{\"title\":\"$1\", \"content\":\"$2\\n时间: $CURRENT_TIME\"}" > /dev/null 2>&1
fi
EOF
chmod +x "$NOTIFY_SCRIPT"

# Watchdog (含虚拟机重启逻辑)
cat > "$WATCHDOG_SCRIPT" << 'EOF'
#!/bin/bash
NOTIFY="/usr/local/bin/mihomo-notify.sh"
FAIL_COUNT_FILE="/tmp/mihomo_fail_count"

if ! systemctl is-active --quiet mihomo; then
    systemctl start mihomo
    sleep 5
fi

PROXY_PORT=$(grep "mixed-port" /etc/mihomo/config.yaml | awk '{print $2}' | tr -d '\r')
[ -z "$PROXY_PORT" ] && PROXY_PORT=7890
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -x "http://127.0.0.1:$PROXY_PORT" --max-time 10 "http://cp.cloudflare.com/generate_204")

if [ "$HTTP_CODE" != "204" ] && [ "$HTTP_CODE" != "200" ]; then
    COUNT=$(cat $FAIL_COUNT_FILE 2>/dev/null || echo 0)
    COUNT=$((COUNT + 1))
    echo $COUNT > $FAIL_COUNT_FILE
    if [ "$COUNT" -ge 3 ]; then
        $NOTIFY "🚨 终极修复：重启系统" "网络持续断开，正在重启虚拟机"
        rm -f $FAIL_COUNT_FILE
        sync && reboot
    else
        $NOTIFY "🌐 网络异常 ($COUNT/3)" "正在尝试重启服务..."
        systemctl restart mihomo
    fi
else
    echo 0 > $FAIL_COUNT_FILE
fi
EOF
chmod +x "$WATCHDOG_SCRIPT"

# 更新脚本
cat > "$UPDATE_SCRIPT" << 'EOF'
#!/bin/bash
source /etc/mihomo/.subscription_info
CONF_FILE="/etc/mihomo/config.yaml"
NOTIFY="/usr/local/bin/mihomo-notify.sh"
curl -L -s --max-time 30 -o "${CONF_FILE}.tmp" "$SUB_URL"
if [ $? -eq 0 ] && [ -s "${CONF_FILE}.tmp" ]; then
    mv "${CONF_FILE}.tmp" "$CONF_FILE"
    touch /tmp/.mihomo_mute_notify
    systemctl restart mihomo
    rm -f /tmp/.mihomo_mute_notify
    $NOTIFY "🔄 订阅配置已更新" "检测到配置变更，已应用"
fi
EOF
chmod +x "$UPDATE_SCRIPT"

# =========================================================
# 6. 系统服务
# =========================================================
cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Mihomo Daemon
After=network.target

[Service]
Type=simple
User=root
Restart=always
ExecStart=$CORE_BIN -d $CONF_DIR -f $CONF_FILE
ExecStartPost=/usr/bin/bash -c 'if [ ! -f /tmp/.mihomo_mute_notify ]; then $NOTIFY_SCRIPT "✅ Mihomo 已启动" "服务运行正常"; fi'

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/mihomo-update.timer << EOF
[Unit]
Description=Timer for Update
[Timer]
OnUnitActiveSec=${USER_INTERVAL}min
[Install]
WantedBy=timers.target
EOF
cat > /etc/systemd/system/mihomo-update.service << EOF
[Service]
Type=oneshot
ExecStart=$UPDATE_SCRIPT
EOF
cat > /etc/systemd/system/mihomo-watchdog.timer << EOF
[Unit]
Description=Timer for Watchdog
[Timer]
OnUnitActiveSec=3min
[Install]
WantedBy=timers.target
EOF
cat > /etc/systemd/system/mihomo-watchdog.service << EOF
[Service]
Type=oneshot
ExecStart=$WATCHDOG_SCRIPT
EOF

systemctl daemon-reload

# =========================================================
# 7. 写入管理脚本 (关键修正：使用 'EOF' 防止变量被提前解析)
# =========================================================
cat > "$MIHOMO_BIN" << 'EOF'
#!/bin/bash
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

while true; do
    clear
    echo -e "${BLUE}Mihomo 管理面板${NC}"
    systemctl is-active --quiet mihomo && echo -e "状态: ${GREEN}运行中${NC}" || echo -e "状态: ${RED}已停止${NC}"
    echo "1. 启动  2. 停止  3. 重启  4. 日志  5. 更新订阅  6. 卸载  0. 退出"
    read -p "选择: " c
    case $c in
        1) systemctl start mihomo ;;
        2) systemctl stop mihomo ;;
        3) systemctl restart mihomo ;;
        4) journalctl -u mihomo -f -n 50 ;;
        5) bash /usr/local/bin/mihomo-update.sh ;;
        6) systemctl disable --now mihomo mihomo-update.timer mihomo-watchdog.timer; rm -rf /etc/mihomo /usr/local/bin/mihomo*; echo "已卸载"; exit 0 ;;
        0) exit 0 ;;
    esac
done
EOF
chmod +x "$MIHOMO_BIN"

# =========================================================
# 8. 启动流程
# =========================================================
echo -e "\n${YELLOW}>>> [7/7] 正在初始化服务...${NC}"

systemctl enable --now mihomo-update.timer
systemctl enable --now mihomo-watchdog.timer

# 通知顺序优化
$NOTIFY_SCRIPT "🎉 Mihomo 已部署完成" "自动更新与监控已就绪"
echo -e "${CYAN}等待通知队列 (3s)...${NC}"
sleep 3
bash "$UPDATE_SCRIPT"

# 确保主服务自启
systemctl enable mihomo

echo -e "${GREEN}安装完成！现在你可以输入 'mihomo' 进入菜单。${NC}"
# 自动进入菜单
bash "$MIHOMO_BIN"
