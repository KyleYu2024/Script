#!/bin/bash

# =========================================================
# Mihomo 全能部署脚本
# =========================================================

# --- 全局变量 ---
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
NC='\033[0m'

# --- Root 检查 ---
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}错误: 请使用 root 权限运行此脚本！${NC}"
  exit 1
fi

if [ "$(basename "$0")" == "mihomo" ]; then
    echo -e "${RED}[错误] 脚本名不能为 'mihomo'，请重命名为 install.sh 后重试。${NC}"
    exit 1
fi

# =========================================================
# 1. 检测是否已安装 -> 进入管理菜单
# =========================================================
if [ -f "$CORE_BIN" ] && [ -f "$MIHOMO_BIN" ]; then
    echo -e "${GREEN}检测到 Mihomo 已安装，正在启动管理菜单...${NC}"
    sleep 1
    bash "$MIHOMO_BIN"
    exit 0
fi

# =========================================================
# 2. 安装流程
# =========================================================

clear
echo -e "${BLUE}#################################################${NC}"
echo -e "${BLUE}#     Mihomo 裸核网关 (自动更新+UI提示)         #${NC}"
echo -e "${BLUE}#################################################${NC}"
echo ""

# --- 2.1 环境检测 ---
echo -e "${YELLOW}>>> [1/6] 检测虚拟化环境与 TUN 权限...${NC}"
if [ ! -c /dev/net/tun ]; then modprobe tun >/dev/null 2>&1; fi
if [ ! -c /dev/net/tun ]; then
    echo -e "${RED}[FATAL] 无法访问 /dev/net/tun 设备。${NC}"
    echo -e "LXC 容器请在宿主机配置文件添加: lxc.cgroup2.devices.allow: c 10:200 rwm 和 lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file"
    exit 1
fi
echo -e "${GREEN}[OK] TUN 设备就绪。${NC}"

# --- 2.2 安装依赖 ---
echo -e "\n${YELLOW}>>> [2/6] 安装必要组件...${NC}"
PACKAGES="curl gzip tar nano unzip"
if [ -f /etc/debian_version ]; then
    apt update -q && apt install -y $PACKAGES -q
elif [ -f /etc/alpine-release ]; then
    apk add $PACKAGES bash grep
else
    echo -e "${RED}不支持的系统${NC}"; exit 1
fi

if ! sysctl net.ipv4.ip_forward | grep -q "1"; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
fi

# --- 2.3 下载核心 ---
echo -e "\n${YELLOW}>>> [3/6] 下载核心与数据库 (CN加速)...${NC}"
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
curl -sL -o "$CONF_DIR/geosite.dat" "${GH_PROXY}https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat"

# --- 2.4 生成更新脚本 ---
cat > "$UPDATE_SCRIPT" <<'EOF'
#!/bin/bash
CONF_DIR="/etc/mihomo"
CONF_FILE="$CONF_DIR/config.yaml"
SUB_INFO_FILE="$CONF_DIR/.subscription_info"
GH_PROXY="https://gh-proxy.com/"

if [ -f "$SUB_INFO_FILE" ]; then source "$SUB_INFO_FILE"; else echo "无订阅信息"; exit 1; fi
if [ -z "$SUB_URL" ]; then echo "订阅链接为空"; exit 1; fi

echo "从 $SUB_URL 更新配置..."
curl -L -s -o "${CONF_FILE}.tmp" "$SUB_URL"

if [ $? -eq 0 ] && [ -s "${CONF_FILE}.tmp" ]; then
    # 注入 GeoX
    if ! grep -q "^geox-url:" "${CONF_FILE}.tmp"; then
        cat >> "${CONF_FILE}.tmp" <<INNEREOF

geox-url:
  geosite: "${GH_PROXY}https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat"
  geoip: "${GH_PROXY}https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip-lite.dat"
  mmdb: "${GH_PROXY}https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country-lite.mmdb"
  asn: "${GH_PROXY}https://github.com/xishang0128/geoip/releases/download/latest/GeoLite2-ASN.mmdb"
INNEREOF
    fi
    # 注入 TUN
    if ! grep -q "^tun:" "${CONF_FILE}.tmp"; then
        cat >> "${CONF_FILE}.tmp" <<INNEREOF

tun:
  enable: true
  stack: system
  device: mihomo-tun
  auto-route: true
  auto-detect-interface: true
  dns-hijack:
    - any:53
dns:
  enable: true
  listen: 0.0.0.0:53
  ipv6: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver:
    - https://doh.pub/dns-query
    - https://dns.alidns.com/dns-query
  fallback:
    - https://1.1.1.1/dns-query
    - https://8.8.8.8/dns-query
INNEREOF
    fi
    mv "${CONF_FILE}.tmp" "$CONF_FILE"
    systemctl restart mihomo
    echo "更新成功: $(date)"
else
    rm -f "${CONF_FILE}.tmp"
    exit 1
fi
EOF
chmod +x "$UPDATE_SCRIPT"

# --- 2.5 订阅向导 ---
echo -e "\n${YELLOW}>>> [4/6] 订阅配置向导${NC}"
echo "1) 输入订阅链接 (自动更新)"
echo "2) 手动粘贴配置 (无自动更新)"
read -p "请选择 [1-2]: " CHOICE

if [ "$CHOICE" == "1" ]; then
    read -p "请输入订阅链接 (Sub-Store/机场): " USER_URL
    read -p "请输入自动更新间隔 (分钟, 默认60): " USER_INTERVAL
    [ -z "$USER_INTERVAL" ] && USER_INTERVAL=60

    echo "SUB_URL=\"$USER_URL\"" > "$SUB_INFO_FILE"
    echo "SUB_INTERVAL=\"$USER_INTERVAL\"" >> "$SUB_INFO_FILE"

    echo "正在首次下载..."
    bash "$UPDATE_SCRIPT"

    cat > /etc/systemd/system/mihomo-update.service <<EOF
[Unit]
Description=Auto Update Mihomo Config
[Service]
Type=oneshot
ExecStart=$UPDATE_SCRIPT
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
    systemctl daemon-reload
    systemctl enable --now mihomo-update.timer
    echo -e "${GREEN}自动更新已激活。${NC}"

else
    echo -e "${GREEN}请粘贴 YAML 内容，保存按 Ctrl+O, 退出按 Ctrl+X${NC}"
    read -p "按回车开始..."
    nano "$CONF_FILE"
    # 模拟注入
    if ! grep -q "^tun:" "$CONF_FILE"; then
        cat >> "$CONF_FILE" <<EOF
tun:
  enable: true
  stack: system
  device: mihomo-tun
  auto-route: true
  auto-detect-interface: true
  dns-hijack:
    - any:53
EOF
    fi
fi

# --- 2.6 服务注册 ---
echo -e "\n${YELLOW}>>> [5/6] 注册服务...${NC}"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Mihomo Daemon
After=network.target

[Service]
Type=simple
User=root
Restart=always
ExecStart=$CORE_BIN -d $CONF_DIR -f $CONF_FILE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mihomo
systemctl start mihomo

# =========================================================
# 3. 写入管理菜单 (集成面板地址提示)
# =========================================================
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
    # 获取本机局域网IP
    IP=$(hostname -I | awk '{print $1}')
    if [ -z "$IP" ]; then IP="<IP>"; fi

    if systemctl is-active --quiet mihomo; then
        CUR_CONF=$(grep "ExecStart" $SERVICE_FILE | sed -n 's/.*-f \(.*\)/\1/p' | xargs basename 2>/dev/null)
        [ -z "$CUR_CONF" ] && CUR_CONF="config.yaml"
        echo -e "状态: ${GREEN}● 运行中${NC} | 配置: ${YELLOW}$CUR_CONF${NC}"
        echo -e "面板: ${GREEN}http://${IP}:9090/ui${NC}"
    else
        echo -e "状态: ${RED}● 已停止${NC}"
    fi
}

switch_config() {
    echo -e "\n${YELLOW}>>> 切换配置文件${NC}"
    files=($(ls $CONF_DIR/*.yaml 2>/dev/null))
    if [ ${#files[@]} -eq 0 ]; then echo "没找到 yaml 文件"; return; fi
    for i in "${!files[@]}"; do echo "$i) $(basename "${files[$i]}")"; done
    read -p "选择序号: " idx
    if [ -z "${files[$idx]}" ]; then echo "无效"; return; fi
    SEL_FILE="${files[$idx]}"
    sed -i "s|ExecStart=.*|ExecStart=$CORE_BIN -d $CONF_DIR -f $SEL_FILE|g" $SERVICE_FILE
    systemctl daemon-reload
    systemctl restart mihomo
    echo -e "${GREEN}已切换至: $(basename $SEL_FILE)${NC}"
    read -p "按回车返回..."
}

force_update_now() {
    echo -e "\n${YELLOW}>>> 立即更新订阅${NC}"
    if [ ! -f "$SUB_INFO_FILE" ]; then
        echo -e "${RED}未配置订阅信息，请使用选项 6 设置。${NC}"
    else
        bash "$UPDATE_SCRIPT"
    fi
    read -p "按回车返回..."
}

change_subscription() {
    echo -e "\n${YELLOW}>>> 设置/更换 订阅链接${NC}"
    read -p "请输入新订阅链接: " NEW_URL
    read -p "自动更新间隔 (分钟): " NEW_INTERVAL
    
    if [ -z "$NEW_URL" ] || [ -z "$NEW_INTERVAL" ]; then echo "输入不能为空"; return; fi
    
    echo "SUB_URL=\"$NEW_URL\"" > "$SUB_INFO_FILE"
    echo "SUB_INTERVAL=\"$NEW_INTERVAL\"" >> "$SUB_INFO_FILE"
    
    cat > /etc/systemd/system/mihomo-update.timer <<INNEREOF
[Unit]
Description=Timer for Mihomo Update
[Timer]
OnBootSec=5min
OnUnitActiveSec=${NEW_INTERVAL}min
[Install]
WantedBy=timers.target
INNEREOF
    systemctl daemon-reload
    systemctl restart mihomo-update.timer
    
    echo -e "${GREEN}设置已更新！正在立即执行一次下载...${NC}"
    bash "$UPDATE_SCRIPT"
    read -p "按回车返回..."
}

update_ui() {
    echo -e "\n${YELLOW}>>> 重装 Zashboard 面板${NC}"
    if ! command -v unzip >/dev/null 2>&1; then apt install -y unzip -q 2>/dev/null || apk add unzip 2>/dev/null; fi
    curl -L -o /tmp/ui.zip "$UI_URL"
    if [ $? -eq 0 ]; then
        rm -rf "$CONF_DIR/ui"/*
        unzip -q -o /tmp/ui.zip -d /tmp/ui_extract
        cp -r /tmp/ui_extract/*/* "$CONF_DIR/ui/"
        rm /tmp/ui.zip && rm -rf /tmp/ui_extract
        echo -e "${GREEN}面板已更新。请强制刷新浏览器 (Ctrl+F5)。${NC}"
    else
        echo -e "${RED}下载失败。${NC}"
    fi
    if [ "$1" != "auto" ]; then read -p "按回车返回..."; fi
}

uninstall_mihomo() {
    echo -e "\n${RED}!!! 警告: 即将卸载 !!!${NC}"
    read -p "输入 'yes' 确认: " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then return; fi
    systemctl stop mihomo; systemctl disable mihomo
    systemctl stop mihomo-update.timer; systemctl disable mihomo-update.timer
    rm -f "$CORE_BIN" "/usr/local/bin/mihomo" "$SERVICE_FILE" "$UPDATE_SCRIPT"
    rm -rf "$CONF_DIR"
    rm -f /etc/systemd/system/mihomo*
    systemctl daemon-reload
    echo "卸载完成。"
    exit 0
}

while true; do
    clear
    echo -e "${BLUE}########################################${NC}"
    echo -e "${BLUE}#     Mihomo 管理面板 (Zashboard)      #${NC}"
    echo -e "${BLUE}########################################${NC}"
    check_status
    echo ""
    echo -e "1. ${GREEN}启动${NC}  2. ${RED}停止${NC}  3. ${YELLOW}重启${NC}"
    echo -e "4. 查看日志"
    echo "----------------------------------------"
    echo -e "5. 切换配置文件"
    echo -e "6. ${YELLOW}更换订阅链接 & 频率${NC}"
    echo -e "7. 立即执行订阅更新"
    echo -e "8. 重装 Web 面板"
    echo "----------------------------------------"
    echo -e "9. ${RED}卸载${NC}"
    echo -e "0. 退出"
    echo ""
    read -p "选择: " choice
    case $choice in
        1) systemctl start mihomo ;;
        2) systemctl stop mihomo ;;
        3) systemctl restart mihomo && echo "已重启" && sleep 1 ;;
        4) journalctl -u mihomo -f -n 50 ;;
        5) switch_config ;;
        6) change_subscription ;;
        7) force_update_now ;;
        8) update_ui ;;
        9) uninstall_mihomo ;;
        0) exit 0 ;;
        *) echo "无效" ;;
    esac
done
EOF

chmod +x "$MIHOMO_BIN"

# --- 2.7 结束 ---
echo -e "\n${GREEN}安装完成！${NC}"
bash -c "source $MIHOMO_BIN; update_ui auto >/dev/null 2>&1"
IP=$(hostname -I | awk '{print $1}')
echo -e "面板地址: ${YELLOW}http://${IP}:9090/ui${NC}"
echo -e "${GREEN}正在进入管理菜单...${NC}"
sleep 1
bash "$MIHOMO_BIN"
