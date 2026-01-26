#!/bin/bash

# =========================================================
# Mihomo 增强版部署脚本 (交互式 + 全能管理菜单)
# =========================================================

# --- 1. 全局变量 ---
MIHOMO_BIN="/usr/local/bin/mihomo"
CORE_BIN="/usr/local/bin/mihomo-core"
UPDATE_SCRIPT="/usr/local/bin/mihomo-update.sh"
CONF_DIR="/etc/mihomo"
CONF_FILE="$CONF_DIR/config.yaml"
SUB_INFO_FILE="$CONF_DIR/.subscription_info"
SERVICE_FILE="/etc/systemd/system/mihomo.service"

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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
echo -e "${BLUE}#      Mihomo 裸核网关 (全能配置与 Notify)      #${NC}"
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

# =========================================================
# 4. 核心与数据库拉取 (升级核心版本以修复 IP-ASN 报错)
# =========================================================
echo -e "\n${YELLOW}>>> [2/5] 下载核心与数据库...${NC}"
GH_PROXY="https://gh-proxy.com/"
ARCH=$(uname -m)
# 已升级到 v1.18.10，解决你日志中的 unsupported rule type IP-ASN 报错
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
# 5. 生成自动更新脚本 (防卡死机制 + 动态读取配置)
# =========================================================
cat > "$UPDATE_SCRIPT" <<'EOF'
#!/bin/bash
CONF_DIR="/etc/mihomo"
CONF_FILE="$CONF_DIR/config.yaml"
SUB_INFO_FILE="$CONF_DIR/.subscription_info"

send_notify() {
    [ -f "$SUB_INFO_FILE" ] && source "$SUB_INFO_FILE"
    # 如果没配置 NOTIFY_URL，直接跳过
    if [ -z "$NOTIFY_URL" ]; then return; fi
    # 设置 5秒超时，防止网络不通卡死
    curl -s --max-time 5 -X POST "$NOTIFY_URL" -H "Content-Type: application/json" -d "{\"title\":\"$1\", \"content\":\"$2\"}" > /dev/null 2>&1
}

if [ -f "$SUB_INFO_FILE" ]; then source "$SUB_INFO_FILE"; else exit 1; fi
if [ -z "$SUB_URL" ]; then exit 1; fi

echo ">>> [后台] 正在从 $SUB_URL 下载配置..."
# 设置 30秒下载超时
curl -L -s --max-time 30 -o "${CONF_FILE}.tmp" "$SUB_URL"

if [ $? -eq 0 ] && [ -s "${CONF_FILE}.tmp" ]; then
    echo ">>> [后台] 配置下载成功，正在应用并发送通知..."
    mv "${CONF_FILE}.tmp" "$CONF_FILE"
    systemctl try-restart mihomo
    send_notify "Mihomo 订阅更新成功" "节点数据已更新并重启服务。时间: $(date '+%Y-%m-%d %H:%M:%S')"
else
    echo ">>> [后台] ❌ 配置下载超时或失败！正在发送报错通知..."
    send_notify "Mihomo 订阅更新失败" "无法从 $SUB_URL 获取配置，请检查链接有效性。"
    rm -f "${CONF_FILE}.tmp"
fi
EOF
chmod +x "$UPDATE_SCRIPT"

# =========================================================
# 6. 交互式配置订阅与通知 (初次安装)
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
# 7. 注册 Systemd 服务 (含动态通知读取)
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
ExecStopPost=/usr/bin/bash -c 'source $SUB_INFO_FILE; if [ "\$EXIT_STATUS" != "0" ] && [ -n "\$NOTIFY_URL" ]; then curl -s --max-time 5 -X POST "\$NOTIFY_URL" -H "Content-Type: application/json" -d "{\"title\":\"Mihomo 运行异常\", \"content\":\"内核崩溃或意外退出，退出码: \$EXIT_STATUS\"}"; fi'
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
# 8. 写入全能管理菜单 (支持二次修改配置)
# =========================================================
echo -e "\n${YELLOW}>>> [5/5] 生成全能管理菜单...${NC}"

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
CYAN='\033[0;36m'
NC='\033[0m'

check_status() {
    IP=$(hostname -I | awk '{print $1}')
    [ -z "$IP" ] && IP="<IP>"
    if systemctl is-active --quiet mihomo; then
        echo -e "状态: ${GREEN}● 运行中${NC}"
        echo -e "面板: ${GREEN}http://${IP}:9090/ui${NC}"
    else
        echo -e "状态: ${RED}● 已停止${NC} (按 1 启动)"
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

# 二次配置管理功能
modify_config() {
    source "$SUB_INFO_FILE"
    while true; do
        clear
        echo -e "${BLUE}================ 修改配置参数 =================${NC}"
        echo -e "1) 订阅链接: ${YELLOW}$SUB_URL${NC}"
        echo -e "2) 更新频率: ${YELLOW}${SUB_INTERVAL} 分钟${NC}"
        echo -e "3) 通知接口: ${YELLOW}${NOTIFY_URL:-未配置}${NC}"
        echo -e "-----------------------------------------------"
        echo -e "s) ${GREEN}保存并应用${NC}"
        echo -e "q) 返回主菜单"
        echo -e "==============================================="
        read -p "请选择要修改的项目 (1/2/3/s/q): " m_choice

        case $m_choice in
            1) read -p "请输入新的订阅链接: " SUB_URL ;;
            2) read -p "请输入新的更新间隔 (分钟): " SUB_INTERVAL ;;
            3) read -p "请输入新的 Notify 接口地址: " NOTIFY_URL ;;
            s|S)
                echo "SUB_URL=\"$SUB_URL\"" > "$SUB_INFO_FILE"
                echo "SUB_INTERVAL=\"$SUB_INTERVAL\"" >> "$SUB_INFO_FILE"
                echo "NOTIFY_URL=\"$NOTIFY_URL\"" >> "$SUB_INFO_FILE"
                # 更新 Systemd 定时器以使新频率生效
                cat > /etc/systemd/system/mihomo-update.timer <<EOF2
[Unit]
Description=Timer for Mihomo Update
[Timer]
OnBootSec=5min
OnUnitActiveSec=${SUB_INTERVAL}min
[Install]
WantedBy=timers.target
EOF2
                systemctl daemon-reload
                systemctl restart mihomo-update.timer
                echo -e "${GREEN}配置已保存，定时器已重载！${NC}"
                sleep 2
                return ;;
            q|Q) return ;;
        esac
    done
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
    echo -e "5. 切换本地配置文件"
    echo -e "6. 立即强制更新订阅"
    echo -e "7. ${CYAN}修改订阅/通知/更新频率 (二次配置)${NC}"
    echo -e "8. 重装 Web 面板"
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
        7) modify_config ;;
        8) update_ui ;;
        9) systemctl stop mihomo; systemctl disable mihomo; rm -rf /etc/mihomo /usr/local/bin/mihomo* /etc/systemd/system/mihomo*; systemctl daemon-reload; exit 0 ;;
        0) exit 0 ;;
    esac
done
EOF
chmod +x "$MIHOMO_BIN"

# --- 9. 完成与最后一次通知 ---
source "$SUB_INFO_FILE"
if [ -n "$NOTIFY_URL" ]; then
    curl -s --max-time 5 -X POST "$NOTIFY_URL" -H "Content-Type: application/json" -d "{\"title\":\"Mihomo 部署完成\", \"content\":\"安装脚本已成功在 $(hostname) 执行完毕。\"}" > /dev/null 2>&1
fi

echo -e "\n${GREEN}安装完成！${NC}"
bash -c "source $MIHOMO_BIN; update_ui auto >/dev/null 2>&1"
sleep 1
bash "$MIHOMO_BIN"
