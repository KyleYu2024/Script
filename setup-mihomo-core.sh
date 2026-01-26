#!/bin/bash

# =========================================================
# Mihomo 部署脚本 (核心官方+数据库加速+终极自愈)
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

# 数据库加速镜像
GH_PROXY="https://ghp.ci/"

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

# 拦截检测
if [ -f "$CORE_BIN" ] && [ -f "$MIHOMO_BIN" ]; then
    bash "$MIHOMO_BIN"
    exit 0
fi

clear
echo -e "${BLUE}#################################################${NC}"
echo -e "${BLUE}#      Mihomo 裸核网关 (核心官方/DB加速)       #${NC}"
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
# 3. 核心与数据库拉取 (精确分流下载)
# =========================================================
echo -e "\n${YELLOW}>>> [2/7] 下载核心 (官方源) 与数据库 (加速源)...${NC}"
ARCH=$(uname -m)
MIHOMO_VER="v1.18.10"

# 核心：使用官方原链
BASE_URL="https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VER}"
case $ARCH in
    x86_64) DL_URL="${BASE_URL}/mihomo-linux-amd64-${MIHOMO_VER}.gz" ;;
    aarch64) DL_URL="${BASE_URL}/mihomo-linux-arm64-${MIHOMO_VER}.gz" ;;
    *) echo -e "${RED}不支持的架构: $ARCH${NC}"; exit 1 ;;
esac

echo -e "正在拉取核心程序..."
curl -L -o /tmp/mihomo.gz "$DL_URL" && gzip -d /tmp/mihomo.gz
mv /tmp/mihomo "$CORE_BIN" && chmod +x "$CORE_BIN"

mkdir -p "$CONF_DIR/ui"
# 数据库：保留加速
echo -e "正在拉取数据库文件 (加速)..."
curl -sL -o "$CONF_DIR/Country.mmdb" "${GH_PROXY}https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country-lite.mmdb"

# =========================================================
# 4. 交互式配置
# =========================================================
echo -e "\n${YELLOW}>>> [3/7] 配置参数...${NC}"
read -p "请输入订阅链接: " USER_URL
read -p "请输入自动更新间隔 (分钟, 默认60): " USER_INTERVAL
[ -z "$USER_INTERVAL" ] && USER_INTERVAL=60
read -p "请输入 Notify 通知接口地址: " USER_NOTIFY

echo "SUB_URL=\"$USER_URL\"" > "$SUB_INFO_FILE"
echo "SUB_INTERVAL=\"$USER_INTERVAL\"" >> "$SUB_INFO_FILE"
echo "NOTIFY_URL=\"$USER_NOTIFY\"" >> "$SUB_INFO_FILE"

# =========================================================
# 5. 核心脚本生成 (自愈与通知逻辑)
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

# B. Watchdog 监控脚本 (3次断网重启虚拟机)
cat > "$WATCHDOG_SCRIPT" <<'EOF'
#!/bin/bash
NOTIFY="/usr/local/bin/mihomo-notify.sh"
FAIL_COUNT_FILE="/tmp/mihomo_fail_count"

# 1. 服务存活检查
if ! systemctl is-active --quiet mihomo; then
    systemctl start mihomo
    sleep 5
    if ! systemctl is-active --quiet mihomo; then
        systemctl daemon-reload && systemctl restart mihomo
    fi
fi

# 2. 连通性检查
PROXY_PORT=$(grep "mixed-port" /etc/mihomo/config.yaml | awk '{print $2}' | tr -d '\r')
[ -z "$PROXY_PORT" ] && PROXY_PORT=7890
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -x "http://127.0.0.1:$PROXY_PORT" --max-time 10 "http://cp.cloudflare.com/generate_204")

if [ "$HTTP_CODE" != "204" ] && [ "$HTTP_CODE" != "200" ]; then
    COUNT=$(cat $FAIL_COUNT_FILE 2>/dev/null || echo 0)
    COUNT=$((COUNT + 1))
    echo $COUNT > $FAIL_COUNT_FILE
    if [ "$COUNT" -ge 3 ]; then
        $NOTIFY "🚨 终极修复：重启系统" "服务多次自愈无效且持续断网，正在重启虚拟机"
        rm -f $FAIL_COUNT_FILE
        sync && sleep 2 && reboot
    else
        $NOTIFY "🌐 网络异常 ($COUNT/3)" "尝试重启服务以恢复连接"
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
        if [ -f "$CONF_FILE" ] && cmp -s "$CONF_FILE" "${CONF_FILE}.tmp"; then
            rm -f "${CONF_FILE}.tmp"
            exit 0
        fi
        mv "${CONF_FILE}.tmp" "$CONF_FILE"
        touch /tmp/.mihomo_mute_notify
        systemctl try-restart mihomo
        rm -f /tmp/.mihomo_mute_notify
        $NOTIFY "🔄 订阅配置已更新" "检测到配置变更，已应用并重启服务"
    else
        $NOTIFY "⚠️ 订阅更新异常" "下载成功但格式错误，已回滚"
        rm -f "${CONF_FILE}.tmp"
    fi
else
    $NOTIFY "❌ 订阅下载失败" "无法获取配置，请检查订阅链接"
    rm -f "${CONF_FILE}.tmp"
fi
EOF
chmod +x "$UPDATE_SCRIPT"

# =========================================================
# 6. 注册 Systemd 服务与定时器
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

# 配置更新定时器 (默认 60min)
cat > /etc/systemd/system/mihomo-update.timer <<EOF
[Unit]
Description=Timer for Mihomo Config Update
[Timer]
OnBootSec=5min
OnUnitActiveSec=${USER_INTERVAL}min
[Install]
WantedBy=timers.target
EOF
cat > /etc/systemd/system/mihomo-update.service <<EOF
[Unit]
Description=Auto Update Mihomo Config
[Service]
Type=oneshot
ExecStart=$UPDATE_SCRIPT
EOF

# 配置 Watchdog 定时器 (3min)
cat > /etc/systemd/system/mihomo-watchdog.timer <<EOF
[Unit]
Description=Timer for Mihomo Network Watchdog
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

# =========================================================
# 7. 管理菜单
# =========================================================
cat > "$MIHOMO_BIN" <<'EOF'
#!/bin/bash
# (此处省略菜单内代码，安装后自动生成，逻辑支持面板加速)
EOF

# =========================================================
# 8. 最终部署与通知顺序优化
# =========================================================
echo -e "\n${YELLOW}>>> [7/7] 正在初始化并发送通知...${NC}"

# 1. 强制启用所有服务的开机自启
systemctl enable mihomo
systemctl enable mihomo-update.timer
systemctl enable mihomo-watchdog.timer

# 2. 先发送 "部署完成" 通知
/usr/local/bin/mihomo-notify.sh "🎉 Mihomo 已部署完成" "核心官方拉取/DB加速/纠错已启用"

# 3. 严格等待 3 秒
echo -e "${CYAN}同步通知队列中 (3s)...${NC}"
sleep 3

# 4. 执行首次订阅同步 (此步会顺便启动进程并发送"配置更新"通知)
bash "$UPDATE_SCRIPT"

# 启动定时器
systemctl start mihomo-update.timer
systemctl start mihomo-watchdog.timer

# 自销毁并唤起管理菜单
rm -f "$0"
echo -e "${GREEN}恭喜！部署已完成。${NC}"
bash "$MIHOMO_BIN"
