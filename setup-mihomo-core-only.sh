#!/bin/bash

# =========================================================
# Mihomo 部署脚本 (动态追踪 + 编辑功能增强版)
# =========================================================

# --- 1. 全局配置 ---
MIHOMO_BIN="/usr/local/bin/mihomo"
CORE_BIN="/usr/local/bin/mihomo-core"
UPDATE_SCRIPT="/usr/local/bin/mihomo-update.sh"
WATCHDOG_SCRIPT="/usr/local/bin/mihomo-watchdog.sh"
NOTIFY_SCRIPT="/usr/local/bin/mihomo-notify.sh"
CONF_DIR="/etc/mihomo"
DEFAULT_CONF="$CONF_DIR/config.yaml"
SUB_INFO_FILE="$CONF_DIR/.subscription_info"
SERVICE_FILE="/etc/systemd/system/mihomo.service"

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 权限与环境检查 ---
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}错误: 请使用 root 权限运行此脚本！${NC}"
  exit 1
fi
if [ "$(basename "$0")" == "mihomo" ]; then
    echo -e "${RED}[错误] 脚本名不能为 'mihomo'，请重命名为 install.sh 后重试。${NC}"
    exit 1
fi

# 拦截检测：若已安装直接进入管理菜单
if [ -f "$CORE_BIN" ] && [ -f "$MIHOMO_BIN" ]; then
    bash "$MIHOMO_BIN"
    exit 0
fi

clear
echo -e "${BLUE}#################################################${NC}"
echo -e "${BLUE}#     Mihomo 裸核网关 (自动更新与状态监控)      #${NC}"
echo -e "${BLUE}#################################################${NC}"

# =========================================================
# 2. 环境与依赖安装
# =========================================================
echo -e "\n${YELLOW}>>> [1/7] 安装系统依赖...${NC}"
PACKAGES="curl gzip tar nano unzip jq gawk bc"
if [ -f /etc/debian_version ]; then
    apt update -q && apt install -y $PACKAGES -q
elif [ -f /etc/alpine-release ]; then
    apk add $PACKAGES bash grep
fi

# 开启 IP 转发
if ! sysctl net.ipv4.ip_forward | grep -q "1"; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
fi

# =========================================================
# 3. 核心与数据库拉取 (适配 IP-ASN)
# =========================================================
echo -e "\n${YELLOW}>>> [2/7] 下载核心与数据库...${NC}"
GH_PROXY="https://gh-proxy.com/"
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
echo -e "\n${YELLOW}>>> [3/7] 配置订阅与通知...${NC}"
read -p "请输入订阅链接 (Sub-Store/机场): " USER_URL
read -p "请输入自动更新间隔 (分钟, 默认60): " USER_INTERVAL
[ -z "$USER_INTERVAL" ] && USER_INTERVAL=60

echo -e "${BLUE}提示: 例如 http://10.10.1.9:18088/api/v1/notify/mihomo ${NC}"
read -p "请输入 Notify 通知接口地址: " USER_NOTIFY

echo "SUB_URL=\"$USER_URL\"" > "$SUB_INFO_FILE"
echo "SUB_INTERVAL=\"$USER_INTERVAL\"" >> "$SUB_INFO_FILE"
echo "NOTIFY_URL=\"$USER_NOTIFY\"" >> "$SUB_INFO_FILE"

# =========================================================
# 5. 核心脚本生成 (通知、监控、动态更新)
# =========================================================
echo -e "\n${YELLOW}>>> [4/7] 部署监控与更新系统...${NC}"

# A. 通知函数
cat > "$NOTIFY_SCRIPT" <<'EOF'
#!/bin/bash
source /etc/mihomo/.subscription_info
if [ -n "$NOTIFY_URL" ]; then
    curl -s --max-time 5 -X POST "$NOTIFY_URL" -H "Content-Type: application/json" -d "{\"title\":\"$1\", \"content\":\"$2\"}" > /dev/null 2>&1
fi
EOF
chmod +x "$NOTIFY_SCRIPT"

# B. Watchdog 监控脚本 (动态读取端口)
cat > "$WATCHDOG_SCRIPT" <<'EOF'
#!/bin/bash
source /etc/mihomo/.subscription_info
NOTIFY="/usr/local/bin/mihomo-notify.sh"

if ! systemctl is-active --quiet mihomo; then exit 0; fi 

MEM_USAGE=$(free | grep Mem | awk '{printf "%.0f", $3/$2 * 100.0}')
if [ "$MEM_USAGE" -ge 85 ]; then
    $NOTIFY "⚠️ 内存占用过高" "当前内存占用已达 $MEM_USAGE%，可能会影响服务运行。时间: $(date '+%Y-%m-%d %H:%M:%S')"
fi

# 动态获取当前配置文件的端口
CURRENT_CONF=$(grep 'ExecStart=' /etc/systemd/system/mihomo.service | sed 's/.*-f \([^ ]*\).*/\1/')
PROXY_PORT=$(grep "mixed-port" "$CURRENT_CONF" | awk '{print $2}' | tr -d '\r')
[ -z "$PROXY_PORT" ] && PROXY_PORT=7890

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -x "http://127.0.0.1:$PROXY_PORT" --max-time 5 "http://cp.cloudflare.com/generate_204")

if [ "$HTTP_CODE" != "204" ] && [ "$HTTP_CODE" != "200" ]; then
    $NOTIFY "🌐 网络连通性丢失" "所有节点超时，正在尝试重启服务以恢复网络。时间: $(date '+%Y-%m-%d %H:%M:%S')"
    systemctl restart mihomo
fi
EOF
chmod +x "$WATCHDOG_SCRIPT"

# C. 自动更新脚本 (智能动态追踪当前文件 + 对比锁)
cat > "$UPDATE_SCRIPT" <<'EOF'
#!/bin/bash
source /etc/mihomo/.subscription_info
NOTIFY="/usr/local/bin/mihomo-notify.sh"

# 【核心修复】：动态获取当前正在运行的配置文件，解决改名报错问题
CURRENT_CONF=$(grep 'ExecStart=' /etc/systemd/system/mihomo.service | sed 's/.*-f \([^ ]*\).*/\1/')
[ -z "$CURRENT_CONF" ] && CURRENT_CONF="/etc/mihomo/config.yaml"

# 下载到临时文件
curl -L -s --max-time 30 -o "${CURRENT_CONF}.tmp" "$SUB_URL"

if [ $? -eq 0 ] && [ -s "${CURRENT_CONF}.tmp" ]; then
    # 校验数据有效性
    if grep -q "proxies:" "${CURRENT_CONF}.tmp" || grep -q "proxy-providers:" "${CURRENT_CONF}.tmp"; then
        
        # 智能对比：无变化则静默退出
        if [ -f "$CURRENT_CONF" ] && cmp -s "$CURRENT_CONF" "${CURRENT_CONF}.tmp"; then
            rm -f "${CURRENT_CONF}.tmp"
            exit 0
        fi

        # 覆盖当前正在使用的配置文件
        mv "${CURRENT_CONF}.tmp" "$CURRENT_CONF"
        
        # 创建静默锁并重启
        touch /tmp/.mihomo_mute_notify
        systemctl try-restart mihomo
        rm -f /tmp/.mihomo_mute_notify
        
        $NOTIFY "🔄 订阅配置已更新" "检测到配置变更，已应用至 [$(basename "$CURRENT_CONF")] 并重启服务。时间: $(date '+%Y-%m-%d %H:%M:%S')"
    else
        $NOTIFY "⚠️ 订阅更新异常" "下载成功，但配置中无有效节点数据，更新已回滚。时间: $(date '+%Y-%m-%d %H:%M:%S')"
        rm -f "${CURRENT_CONF}.tmp"
    fi
else
    $NOTIFY "❌ 订阅下载失败" "无法从订阅源获取配置 (网络超时或链接失效)。时间: $(date '+%Y-%m-%d %H:%M:%S')"
    rm -f "${CURRENT_CONF}.tmp"
fi
EOF
chmod +x "$UPDATE_SCRIPT"

# =========================================================
# 6. 注册 Systemd 服务
# =========================================================
echo -e "\n${YELLOW}>>> [5/7] 注册 Systemd 服务...${NC}"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Mihomo Daemon
After=network.target

[Service]
Type=simple
User=root
Restart=always
ExecStart=$CORE_BIN -d $CONF_DIR -f $DEFAULT_CONF

# 启动通知 (检查静默锁)
ExecStartPost=/usr/bin/bash -c 'if [ ! -f /tmp/.mihomo_mute_notify ]; then /usr/local/bin/mihomo-notify.sh "✅ Mihomo 服务已启动" "服务已成功启动或重启。时间: $(date +\"%%Y-%%m-%%d %%H:%%M:%%S\")"; fi'

# 停止通知 (异常退出强制报警 / 正常停止检查静默锁)
ExecStopPost=/usr/bin/bash -c 'if [ "$SERVICE_RESULT" != "success" ]; then /usr/local/bin/mihomo-notify.sh "❌ Mihomo 异常退出" "内核意外退出，退出码: $EXIT_CODE ($EXIT_STATUS)。时间: $(date +\"%%Y-%%m-%%d %%H:%%M:%%S\")"; elif [ ! -f /tmp/.mihomo_mute_notify ]; then /usr/local/bin/mihomo-notify.sh "⏸️ Mihomo 服务已停止" "服务已被正常停止。时间: $(date +\"%%Y-%%m-%%d %%H:%%M:%%S\")"; fi'

CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW

[Install]
WantedBy=multi-user.target
EOF

# 配置更新定时器
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

# 定时器：Watchdog 网络连通性检测
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
# 7. 全能管理菜单 (新增编辑配置文件功能)
# =========================================================
echo -e "\n${YELLOW}>>> [6/7] 生成管理菜单...${NC}"

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

# 获取服务状态与当前配置文件
check_status() {
    IP=$(hostname -I | awk '{print $1}')
    [ -z "$IP" ] && IP="<IP>"
    CURRENT_CONF=$(grep 'ExecStart=' $SERVICE_FILE | sed 's/.*-f \([^ ]*\).*/\1/')
    CONF_NAME=$(basename "$CURRENT_CONF")

    if systemctl is-active --quiet mihomo; then
        echo -e "状态: ${GREEN}● 运行中${NC} [当前配置: ${CYAN}$CONF_NAME${NC}]"
        echo -e "面板: ${GREEN}http://${IP}:9090/ui${NC}"
    else
        echo -e "状态: ${RED}● 已停止${NC} (按 1 启动)"
    fi
    
    if systemctl is-active --quiet mihomo-watchdog.timer; then
        echo -e "网络监控: ${GREEN}已启用${NC}"
    else
        echo -e "网络监控: ${RED}已禁用${NC}"
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

# 【新增】编辑当前配置文件
edit_config() {
    CURRENT_CONF=$(grep 'ExecStart=' $SERVICE_FILE | sed 's/.*-f \([^ ]*\).*/\1/')
    if [ -f "$CURRENT_CONF" ]; then
        nano "$CURRENT_CONF"
        echo -e "\n${YELLOW}配置文件已保存。${NC}"
        read -p "是否立即重启服务以应用更改? [y/n]: " confirm
        if [ "$confirm" == "y" ]; then
            systemctl restart mihomo
            echo -e "${GREEN}服务已重启！${NC}"
        fi
    else
        echo -e "${RED}未找到当前配置文件：$CURRENT_CONF${NC}"
    fi
    sleep 1
}

# 二次配置修改向导
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
                echo -e "${GREEN}配置已保存，定时器已重载。${NC}"
                sleep 2
                return ;;
            q|Q) return ;;
        esac
    done
}

# 主菜单循环
while true; do
    clear
    echo -e "${BLUE}########################################${NC}"
    echo -e "${BLUE}#           Mihomo 管理面板            #${NC}"
    echo -e "${BLUE}########################################${NC}"
    check_status
    echo ""
    echo -e "1. ${GREEN}启动${NC}  2. ${RED}停止${NC}  3. ${YELLOW}重启${NC}  4. 查看日志"
    echo "----------------------------------------"
    echo -e "5. 切换本地配置文件"
    echo -e "6. ${CYAN}编辑当前配置文件 (nano)${NC}"
    echo -e "7. 立即更新订阅"
    echo -e "8. 修改订阅/通知/更新频率"
    echo -e "9. 重装 Web 面板"
    echo "----------------------------------------"
    echo -e "10. ${RED}卸载 Mihomo${NC}"
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
        6) edit_config ;;
        7) bash "$UPDATE_SCRIPT" ; read -p "已触发后台更新，按回车返回..." ;;
        8) modify_config ;;
        9) update_ui ;;
        10) systemctl stop mihomo mihomo-update.timer mihomo-watchdog.timer; systemctl disable mihomo mihomo-update.timer mihomo-watchdog.timer; rm -rf /etc/mihomo /usr/local/bin/mihomo* /etc/systemd/system/mihomo*; systemctl daemon-reload; exit 0 ;;
        0) exit 0 ;;
    esac
done
EOF
chmod +x "$MIHOMO_BIN"

# =========================================================
# 8. 完成启动与发送初始通知
# =========================================================
echo -e "\n${YELLOW}>>> [7/7] 正在启动并检查服务...${NC}"

# 发送第一条 "已上线" 通知
/usr/local/bin/mihomo-notify.sh "🎉 Mihomo 已部署完成" "自动更新与网络监控已启用。时间: $(date '+%Y-%m-%d %H:%M:%S')"

# 执行首次配置拉取 (自动覆盖到默认配置)
bash "$UPDATE_SCRIPT" 

# 启用并启动各类定时器
systemctl enable --now mihomo-update.timer
systemctl enable --now mihomo-watchdog.timer

# 初始化 Web 面板
bash -c "source $MIHOMO_BIN; update_ui auto >/dev/null 2>&1"
sleep 1

# 脚本自我销毁机制
rm -f "$0"

# 进入交互式菜单
bash "$MIHOMO_BIN"
