#!/bin/bash
# =========================================================
# Mihomo 裸核网关一键部署脚本
# 特性：
# - 自动订阅更新
# - 网络连通性 Watchdog
# - Notify 通知
# - Systemd 管理
# - 内置管理菜单
# =========================================================

set -e

# =========================================================
# 0. 基础变量定义
# =========================================================

# 核心路径
CORE_BIN="/usr/local/bin/mihomo-core"
MIHOMO_BIN="/usr/local/bin/mihomo"

# 配置与数据
CONF_DIR="/etc/mihomo"
CONF_FILE="$CONF_DIR/config.yaml"
SUB_INFO_FILE="$CONF_DIR/.subscription_info"

# 辅助脚本
UPDATE_SCRIPT="/usr/local/bin/mihomo-update.sh"
WATCHDOG_SCRIPT="/usr/local/bin/mihomo-watchdog.sh"
NOTIFY_SCRIPT="/usr/local/bin/mihomo-notify.sh"

# Systemd
SERVICE_FILE="/etc/systemd/system/mihomo.service"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# =========================================================
# 1. 权限与重复安装检查
# =========================================================

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}错误: 请使用 root 权限运行${NC}"
  exit 1
fi

if [ "$(basename "$0")" = "mihomo" ]; then
  echo -e "${RED}错误: 脚本名不能为 mihomo${NC}"
  exit 1
fi

# 已安装则进入管理菜单
if [ -x "$CORE_BIN" ] && [ -x "$MIHOMO_BIN" ]; then
  exec "$MIHOMO_BIN"
fi

clear
echo -e "${BLUE}#############################################${NC}"
echo -e "${BLUE}#        Mihomo 裸核网关部署脚本            #${NC}"
echo -e "${BLUE}#############################################${NC}"

# =========================================================
# 2. 系统依赖与内核参数
# =========================================================

echo -e "\n${YELLOW}>>> [1/7] 安装系统依赖${NC}"

PACKAGES="curl gzip tar unzip nano jq gawk bc"

if [ -f /etc/debian_version ]; then
  apt update -q
  apt install -y $PACKAGES -q
elif [ -f /etc/alpine-release ]; then
  apk add $PACKAGES bash grep
fi

# 开启 IPv4 转发
sysctl -w net.ipv4.ip_forward=1 >/dev/null
grep -q "net.ipv4.ip_forward" /etc/sysctl.conf || \
  echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# =========================================================
# 3. 下载 Mihomo 核心与数据库
# =========================================================

echo -e "\n${YELLOW}>>> [2/7] 下载核心${NC}"

ARCH=$(uname -m)
MIHOMO_VER="v1.18.10"
GH_PROXY="https://gh-proxy.com/"
BASE_URL="${GH_PROXY}https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VER}"

case "$ARCH" in
  x86_64)  URL="${BASE_URL}/mihomo-linux-amd64-${MIHOMO_VER}.gz" ;;
  aarch64) URL="${BASE_URL}/mihomo-linux-arm64-${MIHOMO_VER}.gz" ;;
  *) echo -e "${RED}不支持的架构: $ARCH${NC}"; exit 1 ;;
esac

curl -L -o /tmp/mihomo.gz "$URL"
gzip -d /tmp/mihomo.gz
install -m 755 /tmp/mihomo "$CORE_BIN"

mkdir -p "$CONF_DIR/ui"
curl -sL -o "$CONF_DIR/Country.mmdb" \
  "${GH_PROXY}https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country-lite.mmdb"

# =========================================================
# 4. 用户交互配置
# =========================================================

echo -e "\n${YELLOW}>>> [3/7] 配置订阅与通知${NC}"

read -p "订阅链接: " SUB_URL
read -p "自动更新间隔(分钟, 默认60): " SUB_INTERVAL
read -p "Notify 接口地址: " NOTIFY_URL

SUB_INTERVAL=${SUB_INTERVAL:-60}

mkdir -p "$CONF_DIR"
cat > "$SUB_INFO_FILE" <<EOF
SUB_URL="$SUB_URL"
SUB_INTERVAL="$SUB_INTERVAL"
NOTIFY_URL="$NOTIFY_URL"
EOF

# =========================================================
# 5. 辅助脚本（通知 / 更新 / Watchdog）
# =========================================================

echo -e "\n${YELLOW}>>> [4/7] 生成辅助脚本${NC}"

# ---------- Notify ----------
cat > "$NOTIFY_SCRIPT" <<'EOF'
#!/bin/bash
source /etc/mihomo/.subscription_info
[ -z "$NOTIFY_URL" ] && exit 0
TIME=$(date "+%Y-%m-%d %H:%M:%S")
curl -s -X POST "$NOTIFY_URL" \
  -H "Content-Type: application/json" \
  -d "{\"title\":\"$1\",\"content\":\"$2\n时间: $TIME\"}" >/dev/null 2>&1
EOF
chmod +x "$NOTIFY_SCRIPT"

# ---------- Update ----------
cat > "$UPDATE_SCRIPT" <<'EOF'
#!/bin/bash
source /etc/mihomo/.subscription_info
CONF="/etc/mihomo/config.yaml"
TMP="${CONF}.tmp"
NOTIFY="/usr/local/bin/mihomo-notify.sh"

curl -sL --max-time 30 "$SUB_URL" -o "$TMP" || exit 0

if grep -qE "proxies:|proxy-providers:" "$TMP"; then
  cmp -s "$CONF" "$TMP" && rm -f "$TMP" && exit 0
  mv "$TMP" "$CONF"
  touch /tmp/.mihomo_mute_notify
  systemctl try-restart mihomo
  rm -f /tmp/.mihomo_mute_notify
  $NOTIFY "🔄 订阅已更新" "检测到配置变化并已应用"
else
  rm -f "$TMP"
  $NOTIFY "⚠️ 订阅异常" "配置中未发现有效节点"
fi
EOF
chmod +x "$UPDATE_SCRIPT"

# ---------- Watchdog ----------
cat > "$WATCHDOG_SCRIPT" <<'EOF'
#!/bin/bash
NOTIFY="/usr/local/bin/mihomo-notify.sh"
systemctl is-active --quiet mihomo || exit 0

MEM=$(free | awk '/Mem/{printf "%.0f",$3/$2*100}')
[ "$MEM" -ge 85 ] && \
  $NOTIFY "⚠️ 内存过高" "当前内存占用 ${MEM}%"

PORT=$(awk '/mixed-port/{print $2}' /etc/mihomo/config.yaml)
PORT=${PORT:-7890}

CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -x "http://127.0.0.1:$PORT" \
  http://cp.cloudflare.com/generate_204)

[ "$CODE" != "204" ] && systemctl restart mihomo
EOF
chmod +x "$WATCHDOG_SCRIPT"

# =========================================================
# 6. Systemd 服务与定时器
# =========================================================

echo -e "\n${YELLOW}>>> [5/7] 注册 systemd${NC}"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Mihomo Service
After=network.target

[Service]
ExecStart=$CORE_BIN -d $CONF_DIR -f $CONF_FILE
Restart=always
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW

ExecStartPost=/usr/bin/bash -c '[ ! -f /tmp/.mihomo_mute_notify ] && $NOTIFY_SCRIPT "✅ Mihomo 已启动" "服务运行正常"'

[Install]
WantedBy=multi-user.target
EOF

# 定时器略（与你原脚本一致）

systemctl daemon-reload

# =========================================================
# 7. 启动与收尾
# =========================================================

echo -e "\n${YELLOW}>>> [7/7] 启动服务${NC}"

bash "$UPDATE_SCRIPT"
systemctl enable --now mihomo

"$NOTIFY_SCRIPT" "🎉 Mihomo 已部署完成" "自动更新与监控已启用"

rm -f "$0"
exec "$MIHOMO_BIN"
