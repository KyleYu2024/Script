#!/bin/bash

# =========================================================
# Mihomo 全能部署脚本 (极速纯净核心版 + Notify通知)
# =========================================================

# --- 1. 全局变量 ---
MIHOMO_BIN="/usr/local/bin/mihomo"
CORE_BIN="/usr/local/bin/mihomo-core"
UPDATE_SCRIPT="/usr/local/bin/mihomo-update.sh"
CONF_DIR="/etc/mihomo"
CONF_FILE="$CONF_DIR/config.yaml"
SUB_INFO_FILE="$CONF_DIR/.subscription_info"
SERVICE_FILE="/etc/systemd/system/mihomo.service"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then echo -e "${RED}错误: 请使用 root 权限运行此脚本！${NC}"; exit 1; fi
if [ "$(basename "$0")" == "mihomo" ]; then echo -e "${RED}[错误] 脚本名不能为 'mihomo'。${NC}"; exit 1; fi

# =========================================================
# 2. 拦截检测
# =========================================================
if [ -f "$CORE_BIN" ] && [ -f "$MIHOMO_BIN" ]; then bash "$MIHOMO_BIN"; exit 0; fi

clear
echo -e "${BLUE}#################################################${NC}"
echo -e "${BLUE}#   Mihomo 裸核网关 (极速纯净核心 + Notify)     #${NC}"
echo -e "${BLUE}#################################################${NC}"

# =========================================================
# 3. 环境与依赖
# =========================================================
echo -e "\n${YELLOW}>>> [1/5] 安装必要组件与系统调优...${NC}"
PACKAGES="curl gzip tar nano unzip jq"
if [ -f /etc/debian_version ]; then apt update -q && apt install -y $PACKAGES -q; elif [ -f /etc/alpine-release ]; then apk add $PACKAGES bash grep; fi
if ! sysctl net.ipv4.ip_forward | grep -q "1"; then echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf; sysctl -p >/dev/null 2>&1; fi

# =========================================================
# 4. 仅下载纯净核心 (✅已移除数据库下载步骤)
# =========================================================
echo -e "\n${YELLOW}>>> [2/5] 下载 Mihomo 核心...${NC}"
GH_PROXY="https://gh-proxy.com/"
ARCH=$(uname -m)
MIHOMO_VER="v1.18.1"
BASE_URL="${GH_PROXY}https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VER}"

case $ARCH in
    x86_64) DL_URL="${BASE_URL}/mihomo-linux-amd64-${MIHOMO_VER}.gz" ;;
    aarch64) DL_URL="${BASE_URL}/mihomo-linux-arm64-${MIHOMO_VER}.gz" ;;
    *) echo -e "${RED}不支持架构: $ARCH${NC}"; exit 1 ;;
esac

echo -e "${GREEN}正在下载核心文件 (带超时防卡死)...${NC}"
curl -L --max-time 120 -# -o /tmp/mihomo.gz "$DL_URL" && gzip -d /tmp/mihomo.gz
mv /tmp/mihomo "$CORE_BIN" && chmod +x "$CORE_BIN"
mkdir -p "$CONF_DIR/ui"

# =========================================================
# 5. 生成自动更新脚本 (✅保留了配置注入，由内核自下载数据库)
# =========================================================
cat > "$UPDATE_SCRIPT" <<'EOF'
#!/bin/bash
CONF_DIR="/etc/mihomo"
CONF_FILE="$CONF_DIR/config.yaml"
SUB_INFO_FILE="$CONF_DIR/.subscription_info"

send_notify() {
    if [ -z "$NOTIFY_URL" ]; then return; fi
    curl -s --max-time 5 -X POST "$NOTIFY_URL" -H "Content-Type: application/json" -d "{\"title\":\"$1\", \"content\":\"$2\"}" > /dev/null 2>&1
}

if [ -f "$SUB_INFO_FILE" ]; then source "$SUB_INFO_FILE"; else exit 1; fi
if [ -z "$SUB_URL" ]; then exit 1; fi

echo ">>> [后台] 正在从 $SUB_URL 下载配置..."
curl -L -s --max-time 30 -o "${CONF_FILE}.tmp" "$SUB_URL"

if [ $? -eq 0 ] && [ -s "${CONF_FILE}.tmp" ]; then
    # 这里会自动把数据库下载地址写进配置，Mihomo启动时会自动拉取缺失的库
    if ! grep -q "^geox-url:" "${CONF_FILE}.tmp"; then
        cat >> "${CONF_FILE}.tmp" <<INNEREOF

geox-url:
  mmdb: "https://gh-proxy.com/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country-lite.mmdb"
  asn: "https://gh-proxy.com/https://github.com/xishang0128/geoip/releases/download/latest/GeoLite2-ASN.mmdb"
  geosite: "https://gh-proxy.com/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat"
  geoip: "https://gh-proxy.com/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip-lite.dat"
INNEREOF
    fi

    mv "${CONF_FILE}.tmp" "$CONF_FILE"
    systemctl try-restart mihomo
    send_notify "Mihomo 更新成功" "节点已更新。Mihomo将在后台自动完善Geo数据库。时间: $(date)"
else
    send_notify "Mihomo 更新失败" "无法从 $SUB_URL 获取配置，请检查链接。"
    rm -f "${CONF_FILE}.tmp"
fi
EOF
chmod +x "$UPDATE_SCRIPT"

# =========================================================
# 6. 交互式配置
# =========================================================
echo -e "\n${YELLOW}>>> [3/5] 配置订阅与通知...${NC}"
read -p "请输入订阅链接 (Sub-Store/机场): " USER_URL
read -p "请输入自动更新间隔 (分钟, 默认60): " USER_INTERVAL
[ -z "$USER_INTERVAL" ] && USER_INTERVAL=60

echo -e "${BLUE}提示: 例如 http://10.10.1.9:18088/api/v1/notify/mihomo (留空则不启用通知)${NC}"
read -p "请输入 Notify 通知接口地址: " USER_NOTIFY

echo "SUB_URL=\"$USER_URL\"" > "$SUB_INFO_FILE"
echo "SUB_INTERVAL=\"$USER_INTERVAL\"" >> "$SUB_INFO_FILE"
echo "NOTIFY_URL=\"$USER_NOTIFY\"" >> "$SUB_INFO_FILE"

# =========================================================
# 7. 注册系统服务
# =========================================================
echo -e "\n${YELLOW}>>> [4/5] 注册 Systemd 服务...${NC}"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Mihomo Daemon
After=network.target

[Service]
Type=simple
User=root
Restart=always
ExecStart=$CORE_BIN -d $CONF_DIR -f $CONF_FILE
ExecStopPost=/usr/bin/bash -c 'source $SUB_INFO_FILE; if [ "\$EXIT_STATUS" != "0" ] && [ -n "\$NOTIFY_URL" ]; then curl -s --max-time 5 -X POST "\$NOTIFY_URL" -H "Content-Type: application/json" -d "{\"title\":\"Mihomo 运行异常\", \"content\":\"内核崩溃，退出码: \$EXIT_STATUS\"}"; fi'
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW

[Install]
WantedBy=multi-user.target
EOF

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
Description=Auto Update Mihomo Config
[Service]
Type=oneshot
ExecStart=$UPDATE_SCRIPT
EOF

systemctl daemon-reload
bash "$UPDATE_SCRIPT"
systemctl enable --now mihomo-update.timer

# =========================================================
# 8. 全能管理菜单
# =========================================================
echo -e "\n${YELLOW}>>> [5/5] 生成管理菜单...${NC}"

cat > "$MIHOMO_BIN" <<'EOF'
#!/bin/bash
CORE_BIN="/usr/local/bin/mihomo-core"
CONF_DIR="/etc/mihomo"
SERVICE_FILE="/etc/systemd/system/mihomo.service"
SUB_INFO_FILE="$CONF_DIR/.subscription_info"
UPDATE_SCRIPT="/usr/local/bin/mihomo-update.sh"
UI_URL="https://gh-proxy.com/https://github.com/Zephyruso/zashboard/archive/refs/heads/gh-pages.zip"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

check_status() {
    IP=$(hostname -I | awk '{print $1}')
    [ -z "$IP" ] && IP="<IP>"
    if systemctl is-active --quiet mihomo; then
        MEM=$(ps -o rss= -p $(pidof mihomo-core) | awk '{printf "%.1fMB", $1/1024}')
        echo -e "状态: ${GREEN}● 运行中${NC} (内存占用: ${YELLOW}${MEM}${NC})"
        echo -e "面板: ${GREEN}http://${IP}:9090/ui${NC}"
    else
        echo -e "状态: ${RED}● 已停止${NC}"
    fi
}

update_ui() {
    echo -e "\n${YELLOW}>>> 重装 Zashboard 面板${NC}"
    curl -L -o /tmp/ui.zip "$UI_URL"
    if [ $? -eq 0 ]; then
        rm -rf "$CONF_DIR/ui"/*
        unzip -q -o /tmp/ui.zip -d /tmp/ui_extract
        cp -r /tmp/ui_extract/*/* "$CONF_DIR/ui/"
        rm -rf /tmp/ui.zip /tmp/ui_extract
        echo -e "${GREEN}面板已更新。${NC}"
    fi
    if [ "$1" != "auto" ]; then read -p "按回车返回..."; fi
}

change_notify() {
    source "$SUB_INFO_FILE"
    echo -e "\n${YELLOW}>>> 当前 Notify 接口: ${NC}${NOTIFY_URL:-未配置}"
    read -p "请输入新的 Notify 接口地址 (留空则清除): " NEW_NOTIFY
    sed -i '/NOTIFY_URL=/d' "$SUB_INFO_FILE"
    echo "NOTIFY_URL=\"$NEW_NOTIFY\"" >> "$SUB_INFO_FILE"
    echo -e "${GREEN}通知接口已更新。${NC}"
    read -p "按回车返回..."
}

while true; do
    clear
    echo -e "${BLUE}########################################${NC}"
    echo -e "${BLUE}#      Mihomo 管理面板 (Zashboard)     #${NC}"
    echo -e "${BLUE}########################################${NC}"
    check_status
    echo ""
    echo -e "1. ${GREEN}启动${NC}  2. ${RED}停止${NC}  3. ${YELLOW}重启${NC}  4. 查看日志"
    echo "----------------------------------------"
    echo -e "5. 切换配置文件"
    echo -e "6. 立即更新订阅配置"
    echo -e "7. 重装 Web 面板"
    echo -e "8. ${YELLOW}修改 Notify 通知接口${NC}"
    echo "----------------------------------------"
    echo -e "9. ${RED}卸载 Mihomo${NC}"
    echo -e "0. 退出"
    echo ""
    read -p "选择: " choice
    case $choice in
        1) systemctl start mihomo ;;
        2) systemctl stop mihomo ;;
        3) systemctl restart mihomo ;;
        4) journalctl -u mihomo -f -n 50 ;;
        5) 
            files=($(ls $CONF_DIR/*.yaml 2>/dev/null))
            for i in "${!files[@]}"; do echo "$i) $(basename "${files[$i]}")"; done
            read -p "选择序号: " idx
            if [ -n "${files[$idx]}" ]; then
                sed -i "s|ExecStart=.*|ExecStart=$CORE_BIN -d $CONF_DIR -f ${files[$idx]}|g" $SERVICE_FILE
                systemctl daemon-reload && systemctl restart mihomo
            fi ;;
        6) bash "$UPDATE_SCRIPT" ; read -p "按回车返回..." ;;
        7) update_ui ;;
        8) change_notify ;;
        9) systemctl stop mihomo; systemctl disable mihomo; rm -rf /etc/mihomo /usr/local/bin/mihomo* /etc/systemd/system/mihomo*; systemctl daemon-reload; exit 0 ;;
        0) exit 0 ;;
    esac
done
EOF
chmod +x "$MIHOMO_BIN"

# --- 9. 完成 ---
source "$SUB_INFO_FILE"
if [ -n "$NOTIFY_URL" ]; then
    curl -s --max-time 5 -X POST "$NOTIFY_URL" -H "Content-Type: application/json" -d "{\"title\":\"Mihomo 部署完成\", \"content\":\"安装及全库修复已成功执行完毕。\"}" > /dev/null 2>&1
fi

echo -e "\n${GREEN}安装完成！${NC}"
bash -c "source $MIHOMO_BIN; update_ui auto >/dev/null 2>&1"
sleep 1
bash "$MIHOMO_BIN"
