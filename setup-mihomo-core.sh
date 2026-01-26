#!/bin/bash
# =========================================================
# Mihomo 裸核网关一键部署脚本（2025-2026 推荐版，带 CLI 管理菜单）
# 目标：干净、可靠、可维护、自动跟进最新版 + 简单 SSH CLI 管理
# 新增：核心下载支持中国国内加速镜像（优先 https://ghproxy.net）
# =========================================================
set -euo pipefail

# 颜色定义
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m'
BLUE='\033[0;34m' CYAN='\033[0;36m' NC='\033[0m'

# 核心路径（内核用 mihomo-core，mihomo 是 CLI 管理入口）
CORE_BIN="/usr/local/bin/mihomo-core"
MIHOMO_CLI="/usr/local/bin/mihomo"  # CLI 管理脚本
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

# 如果已经安装 CLI 入口 → 直接执行它（弹出菜单）
if [[ -x "$MIHOMO_CLI" && -f "$CONF_FILE" ]]; then
    exec "$MIHOMO_CLI"
fi

clear
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}     Mihomo 裸核网关一键部署（CLI 版）    ${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# 日志开始
exec 1> >(tee -a "$LOG_FILE") 2>&1
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 安装开始"

# =========================================================
# 1. 系统依赖
# =========================================================
echo -e "\n${YELLOW}>>> [1/7] 安装依赖${NC}"
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
# 2. 下载最新 Mihomo 核心（支持国内加速镜像）
# =========================================================
echo -e "\n${YELLOW}>>> [2/7] 下载最新 Mihomo 核心${NC}"

ARCH=$(uname -m)
case $ARCH in
    x86_64)  ARCH_SUFFIX="amd64" ;;
    aarch64) ARCH_SUFFIX="arm64" ;;
    *) echo -e "${RED}不支持的架构: $ARCH${NC}"; exit 1 ;;
esac

# 自动获取最新版本
LATEST_TAG=$(curl -sL --max-time 15 \
    "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest" | \
    jq -r '.tag_name' || echo "v1.18.10")

if [[ $LATEST_TAG == "null" || -z $LATEST_TAG ]]; then
    echo -e "${YELLOW}获取最新版本失败，使用 fallback v1.18.10${NC}"
    LATEST_TAG="v1.18.10"
fi

echo "将使用版本: ${LATEST_TAG}"

# 国内加速镜像列表（按优先级排序，支持自动 fallback，优先 https://ghproxy.net）
MIRRORS=(
    "https://ghproxy.net/https://"
    "https://mirror.ghproxy.com/"
    "https://ghps.cc/https://"
    "https://gh.ddlc.top/"
    ""  # 空字符串表示直连 GitHub
)

# 原始 URL
ORIG_BASE_URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_TAG}"
ORIG_FILE_NAME="mihomo-linux-${ARCH_SUFFIX}-${LATEST_TAG}.gz"

# 下载函数（尝试每个镜像）
download_with_mirrors() {
    local url_path="$1"
    local output="$2"
    for mirror in "${MIRRORS[@]}"; do
        local full_url="${mirror}${url_path}"
        echo -e "${CYAN}尝试下载: ${full_url}${NC}"
        if curl --fail --location --max-time 60 -o "$output" "$full_url"; then
            echo -e "${GREEN}下载成功，使用镜像: ${mirror}${NC}"
            return 0
        fi
        echo -e "${YELLOW}此镜像失败，尝试下一个...${NC}"
    done
    echo -e "${RED}所有镜像下载失败，请检查网络${NC}"
    exit 1
}

# 下载核心
download_with_mirrors "${ORIG_BASE_URL}/${ORIG_FILE_NAME}" "/tmp/mihomo.gz"

gzip -dc /tmp/mihomo.gz > /tmp/mihomo-core
install -m 755 /tmp/mihomo-core "$CORE_BIN"
rm -f /tmp/mihomo*

# 地理数据库（同样用镜像下载）
ORIG_GEO_URL="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country-lite.mmdb"
download_with_mirrors "$ORIG_GEO_URL" "$CONF_DIR/Country.mmdb"

mkdir -p "$CONF_DIR/ui"  # 预留给未来 Dashboard，如果需要

# =========================================================
# 3. 用户配置
# =========================================================
echo -e "\n${YELLOW}>>> [3/7] 配置订阅与通知${NC}"
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
echo -e "\n${YELLOW}>>> [4/7] 生成辅助脚本${NC}"

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

# Watchdog 脚本
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
# 5. 生成 CLI 管理菜单脚本
# =========================================================
echo -e "\n${YELLOW}>>> [5/7] 生成 CLI 管理菜单${NC}"

cat > "$MIHOMO_CLI" <<'EOF'
#!/bin/bash
# Mihomo CLI 管理菜单（简单 SSH 操作界面）

RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m'

while true; do
    clear
    echo -e "${YELLOW}=== Mihomo 管理菜单 ===${NC}"
    echo "1. 启动服务"
    echo "2. 停止服务"
    echo "3. 重启服务"
    echo "4. 查看服务状态"
    echo "5. 更新订阅配置"
    echo "6. 编辑配置文件"
    echo "7. 查看服务日志"
    echo "8. 运行 Watchdog 检查"
    echo "9. 发送测试通知"
    echo "0. 退出菜单"
    read -rp "选择选项: " choice

    case $choice in
        1) systemctl start mihomo && echo -e "${GREEN}服务已启动${NC}" ;;
        2) systemctl stop mihomo && echo -e "${GREEN}服务已停止${NC}" ;;
        3) systemctl restart mihomo && echo -e "${GREEN}服务已重启${NC}" ;;
        4) systemctl status mihomo ;;
        5) /usr/local/bin/mihomo-update.sh && echo -e "${GREEN}订阅已更新${NC}" ;;
        6) nano /etc/mihomo/config.yaml && systemctl restart mihomo ;;
        7) journalctl -u mihomo -f ;;
        8) /usr/local/bin/mihomo-watchdog.sh && echo -e "${GREEN}Watchdog 检查完成${NC}" ;;
        9) /usr/local/bin/mihomo-notify.sh "测试通知" "这是一个测试消息" && echo -e "${GREEN}测试通知已发送${NC}" ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项，按任意键返回${NC}" ;;
    esac
    read -rp "按任意键继续..."
done
EOF
chmod +x "$MIHOMO_CLI"

# =========================================================
# 6. systemd 服务 & 定时任务
# =========================================================
echo -e "\n${YELLOW}>>> [6/7] 注册 systemd 服务${NC}"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Mihomo (MetaCubeX) Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$CORE_BIN -d $CONF_DIR -f $CONF_FILE
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

systemctl daemon-reload
systemctl enable --now mihomo

# =========================================================
# 7. 首次更新 & 完成
# =========================================================
echo -e "\n${YELLOW}>>> [7/7] 首次更新配置 & 启动${NC}"
bash "$UPDATE_SCRIPT" || true

"$NOTIFY_SCRIPT" "部署完成" "Mihomo 已安装并启动\n版本: $LATEST_TAG\n更新间隔: ${SUB_INTERVAL}分钟"

echo -e "\n${GREEN}部署完成！核心版本：${LATEST_TAG}${NC}"
echo -e "管理命令：  ${CYAN}mihomo${NC}  （输入此命令弹出菜单）"
echo -e "配置文件：  ${CYAN}$CONF_FILE${NC}"
echo -e "查看日志：  ${CYAN}journalctl -u mihomo -f${NC}"
echo -e "安装日志：  ${CYAN}$LOG_FILE${NC}\n"

# 清理安装脚本（可选）
rm -f "$0"

# 进入管理菜单
exec "$MIHOMO_CLI"
