#!/bin/bash

# =========================================================
# Mihomo 全能部署脚本
# 功能: 自动检测环境 / 安装 / 管理菜单 / 卸载 / 自动修复
# =========================================================

# --- 全局变量 ---
MIHOMO_BIN="/usr/local/bin/mihomo"
CORE_BIN="/usr/local/bin/mihomo-core"
CONF_DIR="/etc/mihomo"
CONF_FILE="$CONF_DIR/config.yaml"
SUB_URL_FILE="$CONF_DIR/.subscription_url"
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

# =========================================================
# 0. 自检防止覆盖错误
# =========================================================
SCRIPT_NAME=$(basename "$0")
if [ "$SCRIPT_NAME" == "mihomo" ]; then
    echo -e "${RED}[错误] 请不要将安装脚本命名为 'mihomo'。${NC}"
    echo -e "这会导致安装过程中无法写入管理命令。"
    echo -e "请重命名脚本 (例如: mv mihomo install.sh) 后重试。"
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
echo -e "${BLUE}#      Mihomo 全能部署 (安装/管理/卸载)         #${NC}"
echo -e "${BLUE}#################################################${NC}"
echo ""

# --- 2.1 环境检测 (TUN) - 已修复提示文案 ---
echo -e "${YELLOW}>>> [1/5] 检测虚拟化环境与 TUN 权限...${NC}"

# 如果设备不存在，尝试为 VM 加载模块
if [ ! -c /dev/net/tun ]; then
    modprobe tun >/dev/null 2>&1
fi

# 再次检查，如果还是没有，则报错
if [ ! -c /dev/net/tun ]; then
    echo -e "${RED}[FATAL] 无法访问 /dev/net/tun 设备。${NC}"
    echo -e "--------------------------------------------------------"
    echo -e "检测到您正在 LXC 容器中运行，且没有 TUN 权限。"
    echo -e "请登录 **PVE 宿主机 (Host)** 的 Shell，执行以下步骤："
    echo -e "1. 找到该容器的 ID (例如 100, 101...)"
    echo -e "2. 编辑配置文件: ${GREEN}nano /etc/pve/lxc/<容器ID>.conf${NC}"
    echo -e "3. 在文件末尾添加以下两行："
    echo -e "${YELLOW}lxc.cgroup2.devices.allow: c 10:200 rwm${NC}"
    echo -e "${YELLOW}lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file${NC}"
    echo -e "4. 保存退出，并 **重启此容器**。"
    echo -e "--------------------------------------------------------"
    exit 1
fi
echo -e "${GREEN}[OK] TUN 设备就绪。${NC}"

# --- 2.2 安装依赖 ---
echo -e "\n${YELLOW}>>> [2/5] 安装必要组件...${NC}"
PACKAGES="curl gzip tar nano unzip"
if [ -f /etc/debian_version ]; then
    apt update -q && apt install -y $PACKAGES -q
elif [ -f /etc/alpine-release ]; then
    apk add $PACKAGES bash grep
else
    echo -e "${RED}不支持的系统${NC}"; exit 1
fi

# 开启转发
if ! sysctl net.ipv4.ip_forward | grep -q "1"; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
fi

# --- 2.3 下载核心与数据库 ---
echo -e "\n${YELLOW}>>> [3/5] 下载核心与数据库 (CN加速)...${NC}"
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
# 下载数据库
curl -sL -o "$CONF_DIR/Country.mmdb" "${GH_PROXY}https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country-lite.mmdb"
curl -sL -o "$CONF_DIR/geosite.dat" "${GH_PROXY}https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat"

# --- 2.4 配置文件向导 ---
echo -e "\n${YELLOW}>>> [4/5] 初始化配置${NC}"
echo "1) 粘贴配置 (新建空文件，手动粘贴)"
echo "2) 托管链接 (Sub-Store/订阅链接)"
read -p "请输入 [1-2]: " CHOICE

if [ "$CHOICE" == "1" ]; then
    echo -e "${GREEN}请粘贴 YAML 内容，按 Ctrl+O 保存，Ctrl+X 退出。${NC}"
    read -p "按回车开始..."
    nano "$CONF_FILE"
    if [ ! -s "$CONF_FILE" ]; then echo -e "${RED}文件为空!${NC}"; exit 1; fi
elif [ "$CHOICE" == "2" ]; then
    read -p "请输入托管 URL: " SUB_URL
    echo "正在下载配置..."
    curl -L -s -o "$CONF_FILE" "$SUB_URL"
    if [ ! -s "$CONF_FILE" ]; then echo -e "${RED}下载失败!${NC}"; exit 1; fi
    # 保存 URL
    echo "$SUB_URL" > "$SUB_URL_FILE"
else
    exit 1
fi

# 注入 GeoX URL
sed -i -e '$a\' "$CONF_FILE"
cat >> "$CONF_FILE" <<EOF

# --- INJECTED BY INSTALLER ---
geox-url:
  geosite: "${GH_PROXY}https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat"
  geoip: "${GH_PROXY}https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip-lite.dat"
  mmdb: "${GH_PROXY}https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country-lite.mmdb"
  asn: "${GH_PROXY}https://github.com/xishang0128/geoip/releases/download/latest/GeoLite2-ASN.mmdb"
EOF

# 检查并注入 TUN
if ! grep -q "^tun:" "$CONF_FILE"; then
    echo -e "${GREEN}自动注入透明网关(TUN/FakeIP)配置...${NC}"
    cat >> "$CONF_FILE" <<EOF
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
EOF
fi

# --- 2.5 生成服务与菜单 ---
echo -e "\n${YELLOW}>>> [5/5] 生成管理菜单与服务...${NC}"

# 写入 Systemd (ExecStart 指向 config.yaml)
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
# 3. 写入管理脚本 (到 /usr/local/bin/mihomo)
# =========================================================
cat > "$MIHOMO_BIN" <<'EOF'
#!/bin/bash

# --- 配置 ---
CORE_BIN="/usr/local/bin/mihomo-core"
CONF_DIR="/etc/mihomo"
SERVICE_FILE="/etc/systemd/system/mihomo.service"
SUB_URL_FILE="$CONF_DIR/.subscription_url"
UI_URL="https://gh-proxy.com/https://github.com/Zephyruso/zashboard/archive/refs/heads/gh-pages.zip"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

check_status() {
    if systemctl is-active --quiet mihomo; then
        CUR_CONF=$(grep "ExecStart" $SERVICE_FILE | sed -n 's/.*-f \(.*\)/\1/p' | xargs basename 2>/dev/null)
        [ -z "$CUR_CONF" ] && CUR_CONF="config.yaml"
        echo -e "状态: ${GREEN}● 运行中${NC} | 当前配置: ${YELLOW}$CUR_CONF${NC}"
    else
        echo -e "状态: ${RED}● 已停止${NC}"
    fi
}

switch_config() {
    echo -e "\n${YELLOW}>>> 切换配置文件${NC}"
    files=($(ls $CONF_DIR/*.yaml 2>/dev/null))
    if [ ${#files[@]} -eq 0 ]; then echo "没有找到yaml文件"; return; fi
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

force_update_config() {
    echo -e "\n${YELLOW}>>> 强制更新当前配置${NC}"
    if [ ! -f "$SUB_URL_FILE" ]; then
        echo -e "${RED}未找到保存的订阅链接。${NC}"
        read -p "请输入订阅链接: " NEW_URL
        if [ -z "$NEW_URL" ]; then return; fi
        echo "$NEW_URL" > "$SUB_URL_FILE"
    fi
    URL=$(cat "$SUB_URL_FILE")
    # 获取当前正在运行的配置文件路径
    CUR_FILE_PATH=$(grep "ExecStart" $SERVICE_FILE | sed -n 's/.*-f \(.*\)/\1/p')
    [ -z "$CUR_FILE_PATH" ] && CUR_FILE_PATH="$CONF_DIR/config.yaml"
    
    echo "覆盖文件: $CUR_FILE_PATH"
    curl -L -s -o "$CUR_FILE_PATH" "$URL"
    if [ $? -eq 0 ] && [ -s "$CUR_FILE_PATH" ]; then
        systemctl restart mihomo
        echo -e "${GREEN}更新成功！${NC}"
    else
        echo -e "${RED}更新失败。${NC}"
    fi
    read -p "按回车返回..."
}

update_ui() {
    echo -e "\n${YELLOW}>>> 更新 Zashboard 面板${NC}"
    if ! command -v unzip >/dev/null 2>&1; then
        if [ -f /etc/debian_version ]; then apt update -q && apt install -y unzip -q; 
        elif [ -f /etc/alpine-release ]; then apk add unzip; fi
    fi
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
    echo -e "\n${RED}!!! 警告: 即将卸载 Mihomo !!!${NC}"
    read -p "确认卸载请输入 'yes': " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then return; fi
    systemctl stop mihomo; systemctl disable mihomo
    rm -f "$CORE_BIN" "/usr/local/bin/mihomo" "$SERVICE_FILE"
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
    echo -e "5. 切换配置文件 (Switch Config)"
    echo -e "6. 强制更新当前配置 (Update Config)"
    echo -e "7. ${YELLOW}重装 Web 面板 (Update UI)${NC}"
    echo "----------------------------------------"
    echo -e "9. ${RED}卸载 (Uninstall)${NC}"
    echo -e "0. 退出"
    echo ""
    read -p "选择: " choice
    case $choice in
        1) systemctl start mihomo ;;
        2) systemctl stop mihomo ;;
        3) systemctl restart mihomo && echo "已重启" && sleep 1 ;;
        4) journalctl -u mihomo -f -n 50 ;;
        5) switch_config ;;
        6) force_update_config ;;
        7) update_ui ;;
        9) uninstall_mihomo ;;
        0) exit 0 ;;
        *) echo "无效" ;;
    esac
done
EOF

chmod +x "$MIHOMO_BIN"

# --- 安装完成 ---
echo -e "\n${GREEN}安装完成！${NC}"
echo "正在自动部署 Zashboard 面板..."
# 使用新生成的管理脚本自动安装 UI
bash -c "source $MIHOMO_BIN; update_ui auto >/dev/null 2>&1"

echo -e "\n${GREEN}初始化完毕。正在进入管理菜单...${NC}"
sleep 1
bash "$MIHOMO_BIN"
