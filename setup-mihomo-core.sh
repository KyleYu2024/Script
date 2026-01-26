#!/bin/bash
# =========================================================
# Mihomo 裸核网关一键部署脚本（2025-2026 推荐版）
# 目标：干净、可靠、可维护、自动跟进最新版
# =========================================================
set -euo pipefail

# 颜色定义
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m'
BLUE='\033[0;34m' CYAN='\033[0;36m' NC='\033[0m'

# 核心路径（统一只用 mihomo 一个名字）
MIHOMO_BIN="/usr/local/bin/mihomo"
CONF_DIR="/etc/mihomo"
CONF_FILE="$CONF_DIR/config.yaml"
SUB_INFO_FILE="$CONF_DIR/.subscription_info"
LOG_FILE="$CONF_DIR/install.log"

UPDATE_SCRIPT="/usr/local/bin/mihomo-update.sh"
WATCHDOG_SCRIPT="/usr/local/bin/mihomo-watchdog.sh"
NOTIFY_SCRIPT="/usr/local/bin/mihomo-notify.sh"
SERVICE_FILE="/etc/systemd/system/mihomo.service"

# =========================================================
# 0. 权限 & 重复运行保护
# =========================================================
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}请使用 root 权限运行${NC}" >&2
    exit 1
fi

# 如果已经安装核心 → 直接进入管理菜单（你原有的 mihomo 脚本）
if [[ -x "$MIHOMO_BIN" && -f "$CONF_FILE" ]]; then
    exec "$MIHOMO_BIN"
fi

clear
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}     Mihomo 裸核网关一键部署（推荐版）    ${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# 日志开始
exec 1> >(tee -a "$LOG_FILE") 2>&1
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 安装开始"

# =========================================================
# 1. 系统依赖
# =========================================================
echo -e "\n${YELLOW}>>> [1/6] 安装依赖${NC}"
PACKAGES="curl tar gzip unzip jq nano bc coreutils"
if [[ -f /etc/debian_version ]]; then
    apt update -qq && apt install -yqq $PACKAGES
elif [[ -f /etc/alpine-release ]]; then
    apk add --no-cache $PACKAGES bash grep
else
    echo -e "${RED}不支持的系统发行版${NC}" >&2
    exit 1
fi

# 开启 IP 转发
sysctl -w net.ipv4.ip_forward=1 >/dev/null
grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null || \
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

# =========================================================
# 2. 下载最新 Mihomo 核心
# =========================================================
echo -e "\n${YELLOW}>>> [2/6] 下载最新 Mihomo 核心${NC}"

ARCH=$(uname -m)
case $ARCH in
    x86_64)  ARCH_SUFFIX="amd64" ;;
    aarch64) ARCH_SUFFIX="arm64" ;;
    *) echo -e "${RED}不支持的架构: $ARCH${NC}"; exit 1 ;;
esac

# 自动获取最新版本（比写死 v1.18.x 更推荐）
LATEST_TAG=$(curl -sL --max-time 15 \
    "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest" | \
    jq -r '.tag_name' || echo "v1.18.10")

if [[ $LATEST_TAG == "null" || -z $LATEST_TAG ]]; then
    echo -e "${YELLOW}获取最新版本失败，使用 fallback v1.18.10${NC}"
    LATEST_TAG="v1.18.10"
fi

echo "将使用版本: ${LATEST_TAG}"

GH_PROXY="https://gh-proxy.com/"
BASE_URL="${GH_PROXY}https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_TAG}"
FILE_NAME="mihomo-linux-${ARCH_SUFFIX}-${LATEST_TAG}.gz"

curl --fail --location --max-time 60 -o /tmp/mihomo.gz "${BASE_URL}/${FILE_NAME}" || {
    echo -e "${RED}下载失败，请检查网络或尝试更换代理${NC}"
    exit 1
}

gzip -dc /tmp/mihomo.gz > /tmp/mihomo
install -m 755 /tmp/mihomo "$MIHOMO_BIN"
rm -f /tmp/mihomo*

# 地理数据库（推荐用 lite 版，体积小更新快）
curl -sL -o "$CONF_DIR/Country.mmdb" \
    "${GH_PROXY}https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country-lite.mmdb"

mkdir -p "$CONF_DIR/ui"

# =========================================================
# 3. 用户配置
# =========================================================
echo -e "\n${YELLOW}>>> [3/6] 配置订阅与通知${NC}"
read -rp "订阅链接: " SUB_URL
read -rp "自动更新间隔(分钟, 默认 60): " SUB_INTERVAL
read -rp "Notify 接口地址 (留空禁用): " NOTIFY_URL

SUB_INTERVAL=${SUB_INTERVAL:-60}
: "${NOTIFY_URL:=""}"

mkdir -p "$CONF_DIR"
cat > "$SUB_INFO_FILE" <<EOF
SUB_URL="$SUB_URL"
SUB_INTERVAL="$SUB_INTERVAL"
NOTIFY_URL="$NOTIFY_URL"
EOF

# =========================================================
# 4. 生成辅助脚本
# =========================================================
echo -e "\n${YELLOW}>>> [4/6] 生成辅助脚本${NC}"

# 通知脚本
cat > "$NOTIFY_SCRIPT" <<'EOF'
#!/bin/bash
source /etc/mihomo/.subscription_info
[ -z "$NOTIFY_URL" ] && exit 0
[ -f /tmp/.mihomo_mute_notify ] && exit 0

TIME=$(date '+%Y-%m-%d %H:%M:%S')
curl -s -m 8 -X POST "$NOTIFY_URL" \
    -H "Content-Type: application/json" \
    -d "{\"title\":\"Mihomo - $1\",\"content\":\"$2\n\n时间: $TIME\"}" >/dev/null 2>&1
EOF
chmod +x "$NOTIFY_SCRIPT"

# 更新脚本
cat > "$UPDATE_SCRIPT" <<'EOF'
#!/bin/bash
set -euo pipefail
source /etc/mihomo/.subscription_info
CONF="/etc/mihomo/config.yaml"
TMP="${CONF}.tmp"
NOTIFY="/usr/local/bin/mihomo-notify.sh"

curl -s --max-time 30 -o "$TMP" "$SUB_URL" || exit 0

if grep -qE 'proxies:|proxy-providers:' "$TMP"; then
    if cmp -s "$CONF" "$TMP"; then
        rm -f "$TMP"
        exit 0
    fi
    mv "$TMP" "$CONF"
    touch /tmp/.mihomo_mute_notify
    systemctl try-restart mihomo
    sleep 2
    rm -f /tmp/.mihomo_mute_notify
    $NOTIFY "订阅已更新" "配置变更已自动应用"
else
    rm -f "$TMP"
    $NOTIFY "订阅格式异常" "未检测到有效 proxies / proxy-providers"
fi
EOF
chmod +x "$UPDATE_SCRIPT"

# Watchdog 脚本（内存 + 连通性检测）
cat > "$WATCHDOG_SCRIPT" <<'EOF'
#!/bin/bash
NOTIFY="/usr/local/bin/mihomo-notify.sh"
[ "$(systemctl is-active mihomo)" != "active" ] && exit 0

# 内存使用率告警
MEM=$(free | awk '/Mem:/ {printf "%.0f", $3/$2*100}')
[ "$MEM" -ge 88 ] && $NOTIFY "内存占用过高" "当前使用率 ${MEM}%"

# 出口连通性检查
PORT=$(awk '/^mixed-port:/ {print $2}' /etc/mihomo/config.yaml 2>/dev/null || echo 7890)
CODE=$(curl -s -m 6 -o /dev/null -w "%{http_code}" \
    -x "http://127.0.0.1:$PORT" "http://www.gstatic.com/generate_204" \
    || echo "000")

[ "$CODE" != "204" ] && {
    $NOTIFY "网络出口异常" "连通性检测失败 (code=$CODE)，即将重启"
    systemctl restart mihomo
}
EOF
chmod +x "$WATCHDOG_SCRIPT"

# =========================================================
# 5. systemd 服务 & 定时任务
# =========================================================
echo -e "\n${YELLOW}>>> [5/6] 注册 systemd 服务与定时器${NC}"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Mihomo (MetaCubeX) Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$MIHOMO_BIN -d $CONF_DIR -f $CONF_FILE
Restart=always
RestartSec=3
LimitNOFILE=65535
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
Environment="HOME=/root"
ExecStartPost=/bin/bash -c 'sleep 3 && [ ! -f /tmp/.mihomo_mute_notify ] && $NOTIFY_SCRIPT "Mihomo 已启动" "服务运行正常"'

[Install]
WantedBy=multi-user.target
EOF

# 简单起见，这里用 systemd timer（更推荐）或 cron 都行
# 这里只放服务，定时更新建议后续手动加 cron 或 timer
systemctl daemon-reload
systemctl enable --now mihomo

# =========================================================
# 6. 首次更新 & 完成
# =========================================================
echo -e "\n${YELLOW}>>> [6/6] 首次更新配置 & 启动${NC}"
bash "$UPDATE_SCRIPT" || true

"$NOTIFY_SCRIPT" "部署完成" "Mihomo 已安装并启动\n版本: $LATEST_TAG\n更新间隔: ${SUB_INTERVAL}分钟"

echo -e "\n${GREEN}部署完成！核心版本：${LATEST_TAG}${NC}"
echo -e "管理命令：  ${CYAN}$MIHOMO_BIN${NC}"
echo -e "配置文件：  ${CYAN}$CONF_FILE${NC}"
echo -e "查看日志：  ${CYAN}journalctl -u mihomo -f${NC}"
echo -e "安装日志：  ${CYAN}$LOG_FILE${NC}\n"

# 清理安装脚本（可选）
# rm -f "$0"

# 如果你有管理菜单脚本，可以在这里 exec 它
# exec "$MIHOMO_BIN"   # ← 如果 mihomo 本身就是管理入口
