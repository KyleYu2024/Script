#!/bin/bash

# =========================================================
# Mihomo 全能部署脚本 (Notify 通知集成版)
# =========================================================

# --- 1. 全局变量与配置 ---
MIHOMO_BIN="/usr/local/bin/mihomo"
CORE_BIN="/usr/local/bin/mihomo-core"
UPDATE_SCRIPT="/usr/local/bin/mihomo-update.sh"
CONF_DIR="/etc/mihomo"
CONF_FILE="$CONF_DIR/config.yaml"
SUB_INFO_FILE="$CONF_DIR/.subscription_info"
SERVICE_FILE="/etc/systemd/system/mihomo.service"

# ---> 【通知配置区】 <---
NOTIFY_URL="http://10.10.1.9:18088/api/v1/notify/mihomo"

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Root 检查与脚本名检查 ---
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}错误: 请使用 root 权限运行此脚本！${NC}"
  exit 1
fi
if [ "$(basename "$0")" == "mihomo" ]; then
    echo -e "${RED}[错误] 脚本名不能为 'mihomo'，请重命名为 install.sh 后重试。${NC}"
    exit 1
fi

# =========================================================
# 2. 拦截检测 (若已安装直接进入菜单)
# =========================================================
if [ -f "$CORE_BIN" ] && [ -f "$MIHOMO_BIN" ]; then
    bash "$MIHOMO_BIN"
    exit 0
fi

clear
echo -e "${BLUE}#################################################${NC}"
echo -e "${BLUE}#      Mihomo 裸核网关 (集成 Notify 通知)       #${NC}"
echo -e "${BLUE}#################################################${NC}"

# =========================================================
# 3. 环境与依赖安装
# =========================================================
echo -e "\n${YELLOW}>>> [1/5] 安装必要组件与系统调优...${NC}"
PACKAGES="curl gzip tar nano unzip jq"
if [ -f /etc/debian_version ]; then
    apt update -q && apt install -y $PACKAGES -q
elif [ -f /etc/alpine-release ]; then
    apk add $PACKAGES bash grep
fi

if ! sysctl net.ipv4.ip_forward | grep -q "1"; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
fi

if [ ! -c /dev/net/tun ]; then
    echo -e "${RED}[警告] TUN 设备未就绪，这可能导致部分功能失效。${NC}"
fi

# =========================================================
# 4. 核心与数据库拉取
# =========================================================
echo -e "\n${YELLOW}>>> [2/5] 下载核心与数据库...${NC}"
GH_PROXY="https://gh-proxy.com/"
ARCH=$(uname -m)
MIHOMO_VER="v1.18.1"
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
# 5. 生成自动更新脚本 (含 Notify 推送逻辑)
# =========================================================
cat > "$UPDATE_SCRIPT" <<EOF
#!/bin/bash
CONF_DIR="$CONF_DIR"
CONF_FILE="$CONF_FILE"
SUB_INFO_FILE="$SUB_INFO_FILE"
NOTIFY_URL="$NOTIFY_URL"

send_notify() {
    curl -s -X POST "\$NOTIFY_URL" -H "Content-Type: application/json" -d "{\"title\":\"\$1\", \"content\":\"\$2\"}" > /dev/null 2>&1
}

if [ -f "\$SUB_INFO_FILE" ]; then source "\$SUB_INFO_FILE"; else exit 1; fi

curl -L -s -o "\${CONF_FILE}.tmp" "\$SUB_URL"
if [ \$? -eq 0 ] && [ -s "\${CONF_FILE}.tmp" ]; then
    mv "\${CONF_FILE}.tmp" "\$CONF_FILE"
    systemctl restart mihomo
    send_notify "Mihomo 订阅更新成功" "节点数据已更新并重启服务。时间: \$(date)"
else
    send_notify "Mihomo 订阅更新失败" "无法从 \$SUB_URL 获取配置，请检查链接。"
    rm -f "\${CONF_FILE}.tmp"
fi
EOF
chmod +x "$UPDATE_SCRIPT"

# =========================================================
# 6. 配置订阅与服务注册 (含异常监控)
# =========================================================
echo -e "\n${YELLOW}>>> [3/5] 配置订阅...${NC}"
read -p "请输入订阅链接 (Sub-Store/机场): " USER_URL
read -p "请输入自动更新间隔 (分钟, 默认60): " USER_INTERVAL
[ -z "$USER_INTERVAL" ] && USER_INTERVAL=60

echo "SUB_URL=\"$USER_URL\"" > "$SUB_INFO_FILE"
echo "SUB_INTERVAL=\"$USER_INTERVAL\"" >> "$SUB_INFO_FILE"

# 立即执行首次更新
bash "$UPDATE_SCRIPT"

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
# 核心功能：当非正常退出时，通过 POST 触发 Notify
ExecStopPost=/usr/bin/bash -c 'if [ "\$EXIT_STATUS" != "0" ]; then curl -s -X POST "$NOTIFY_URL" -H "Content-Type: application/json" -d "{\"title\":\"Mihomo 运行异常\", \"content\":\"内核崩溃或意外退出，退出码: \$EXIT_STATUS\"}"; fi'
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
systemctl enable --now mihomo
systemctl enable --now mihomo-update.timer

# =========================================================
# 7. 写入全能管理菜单
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
        echo -e "状态: ${GREEN}● 运行中${NC}"
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
        9) systemctl stop mihomo; systemctl disable mihomo; rm -rf /etc/mihomo /usr/local/bin/mihomo* /etc/systemd/system/mihomo*; systemctl daemon-reload; exit 0 ;;
        0) exit 0 ;;
    esac
done
EOF
chmod +x "$MIHOMO_BIN"

# --- 8. 完成通知 ---
curl -s -X POST "$NOTIFY_URL" -H "Content-Type: application/json" -d "{\"title\":\"Mihomo 部署完成\", \"content\":\"安装脚本已成功在 $(hostname) 执行完毕。\"}" > /dev/null 2>&1

echo -e "\n${GREEN}安装完成！已发送部署完成通知。${NC}"
bash -c "source $MIHOMO_BIN; update_ui auto >/dev/null 2>&1"
sleep 1
bash "$MIHOMO_BIN"
