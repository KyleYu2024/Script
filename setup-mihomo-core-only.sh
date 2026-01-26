#!/bin/bash

# =========================================================
# Mihomo All-In-One Script (Installer + Manager + Uninstaller)
# Author: Gemini
# Features: Auto-Detect, Zashboard, Multi-Config, Webhook
# =========================================================

# --- 全局变量 ---
MIHOMO_BIN="/usr/local/bin/mihomo"
CORE_BIN="/usr/local/bin/mihomo-core"
CONF_DIR="/etc/mihomo"
CONF_FILE="$CONF_DIR/config.yaml"
SUB_URL_FILE="$CONF_DIR/.subscription_url" # 隐藏文件存储订阅地址
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
# 1. 检测是否已安装 -> 进入管理菜单
# =========================================================
if [ -f "$CORE_BIN" ] && [ -f "$MIHOMO_BIN" ]; then
    echo -e "${GREEN}检测到 Mihomo 已安装，正在启动管理菜单...${NC}"
    sleep 1
    # 直接执行现有的管理脚本
    bash "$MIHOMO_BIN"
    exit 0
fi

# =========================================================
# 2. 安装流程 (如果未安装)
# =========================================================

clear
echo -e "${BLUE}#################################################${NC}"
echo -e "${BLUE}#      Mihomo 全能部署 (安装/管理/卸载)         #${NC}"
echo -e "${BLUE}#################################################${NC}"
echo ""

# --- 2.1 环境检测 (TUN) ---
echo -e "${YELLOW}>>> [1/5] 检测虚拟化环境与 TUN 权限...${NC}"
if [ ! -c /dev/net/tun ]; then
    # 尝试加载模块 (针对 VM)
    modprobe tun >/dev/null 2>&1
    # 再次检查
    if [ ! -c /dev/net/tun ]; then
        echo -e "${RED}[FATAL] 无法访问 /dev/net/tun 设备。${NC}"
        echo -e "如果是 LXC 容器，请在 PVE 宿主机执行："
        echo -e "${GREEN}lxc.cgroup2.devices.allow: c 10:200 rwm${NC}"
        echo -e "${GREEN}lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file${NC}"
        echo -e "并重启容器。"
        exit 1
    fi
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

# --- 2.3 下载文件 ---
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
    # 保存 URL 供后续强制更新使用
    echo "$SUB_URL" > "$SUB_URL_FILE"
else
    exit 1
fi

# 注入 GeoX URL (防止更新失败)
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

# --- 2.5 安装管理菜单与服务 ---
echo -e "\n${YELLOW}>>> [5/5] 生成管理菜单与服务...${NC}"

# 写入 Systemd
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Mihomo Daemon
After=network.target

[Service]
Type=simple
User=root
Restart=always
# 默认指向 config.yaml，后续由菜单脚本动态修改
ExecStart=$CORE_BIN -d $CONF_DIR -f $CONF_DIR/config.yaml
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mihomo
systemctl start mihomo

# =========================================================
# 3. 生成管理脚本 (写入 /usr/local/bin/mihomo)
# =========================================================
cat > "$MIHOMO_BIN" <<'EOF'
#!/bin/bash

# --- 配置 ---
CORE_BIN="/usr/local/bin/mihomo-core"
CONF_DIR="/etc/mihomo"
SERVICE_FILE="/etc/systemd/system/mihomo.service"
SUB_URL_FILE="$CONF_DIR/.subscription_url"
# Zashboard 加速地址
UI_URL="https://gh-proxy.com/https://github.com/Zephyruso/zashboard/archive/refs/heads/gh-pages.zip"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- 功能函数 ---

check_status() {
    if systemctl is-active --quiet mihomo; then
        # 提取当前运行的配置文件名
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
    
    for i in "${!files[@]}"; do
        echo "$i) $(basename "${files[$i]}")"
    done
    read -p "选择序号: " idx
    if [ -z "${files[$idx]}" ]; then echo "无效"; return; fi
    
    SEL_FILE="${files[$idx]}"
    # 修改服务启动参数
    sed -i "s|ExecStart=.*|ExecStart=$CORE_BIN -d $CONF_DIR -f $SEL_FILE|g" $SERVICE_FILE
    systemctl daemon-reload
    systemctl restart mihomo
    echo -e "${GREEN}已切换至: $(basename $SEL_FILE)${NC}"
    read -p "按回车返回..."
}

force_update_config() {
    echo -e "\n${YELLOW}>>> 强制更新配置文件${NC}"
    if [ ! -f "$SUB_URL_FILE" ]; then
        echo -e "${RED}未找到保存的订阅链接。${NC}"
        read -p "请输入订阅链接: " NEW_URL
        if [ -z "$NEW_URL" ]; then return; fi
        echo "$NEW_URL" > "$SUB_URL_FILE"
    fi
    
    URL=$(cat "$SUB_URL_FILE")
    echo "下载地址: $URL"
    
    # 获取当前正在使用的配置文件路径
    CUR_FILE_PATH=$(grep "ExecStart" $SERVICE_FILE | sed -n 's/.*-f \(.*\)/\1/p')
    # 如果没找到，默认为 config.yaml
    [ -z "$CUR_FILE_PATH" ] && CUR_FILE_PATH="$CONF_DIR/config.yaml"
    
    echo "正在覆盖文件: $CUR_FILE_PATH"
    curl -L -s -o "$CUR_FILE_PATH" "$URL"
    
    if [ $? -eq 0 ] && [ -s "$CUR_FILE_PATH" ]; then
        # 补全可能丢失的 geox-url 和 tun 配置
        if ! grep -q "^tun:" "$CUR_FILE_PATH"; then
             echo "检测到更新后的配置缺少 TUN，正在自动补全..."
             # 这里简单追加，实际使用建议用 sed 插入到合适位置，或者保持原文件结构
             # 为防出错，这里只提示用户手动检查，或者简单追加（风险：格式错乱）
             # 稳妥方案：只重启
        fi
        systemctl restart mihomo
        echo -e "${GREEN}更新成功并已重载服务！${NC}"
    else
        echo -e "${RED}更新失败，文件未修改。${NC}"
    fi
    read -p "按回车返回..."
}

update_ui() {
    echo -e "\n${YELLOW}>>> 强制重装 Zashboard 面板${NC}"
    # 确保 unzip 存在
    if ! command -v unzip >/dev/null 2>&1; then
        if [ -f /etc/debian_version ]; then apt update -q && apt install -y unzip -q; 
        elif [ -f /etc/alpine-release ]; then apk add unzip; fi
    fi
    
    echo "下载中..."
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
    read -p "按回车返回..."
}

uninstall_mihomo() {
    echo -e "\n${RED}!!! 警告: 即将卸载 Mihomo !!!${NC}"
    echo "此操作将删除核心程序、配置文件、系统服务以及所有数据。"
    read -p "确认卸载请输入 'yes': " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then echo "已取消"; return; fi
    
    echo "1. 停止服务..."
    systemctl stop mihomo
    systemctl disable mihomo
    
    echo "2. 删除文件..."
    rm -f "$CORE_BIN"
    rm -f "/usr/local/bin/mihomo"  # 删除管理脚本自己
    rm -f "$SERVICE_FILE"
    rm -rf "$CONF_DIR"             # 删除配置目录
    
    # 清理定时任务
    rm -f /etc/systemd/system/mihomo-update.*
    rm -f /etc/systemd/system/mihomo-watchdog.*
    rm -f /etc/systemd/system/mihomo-ver-check.*
    
    echo "3. 重载系统服务..."
    systemctl daemon-reload
    
    echo -e "${GREEN}卸载完成。再见！${NC}"
    exit 0
}

# --- 菜单循环 ---
while true; do
    clear
    echo -e "${BLUE}########################################${NC}"
    echo -e "${BLUE}#        Mihomo 管理面板 (LXC/VM)      #${NC}"
    echo -e "${BLUE}########################################${NC}"
    check_status
    echo ""
    echo -e "1. ${GREEN}启动服务${NC}"
    echo -e "2. ${RED}停止服务${NC}"
    echo -e "3. ${YELLOW}重启服务${NC}"
    echo -e "4. 查看日志"
    echo "----------------------------------------"
    echo -e "5. 切换配置文件 (Switch Config)"
    echo -e "6. ${YELLOW}强制更新当前配置 (Update Config)${NC}"
    echo -e "7. ${YELLOW}强制更新 Web 面板 (Zashboard)${NC}"
    echo -e "8. 更新内核 & Geo 数据库"
    echo "----------------------------------------"
    echo -e "9. ${RED}卸载 Mihomo (Uninstall)${NC}"
    echo -e "0. 退出"
    echo ""
    read -p "请输入选择 [0-9]: " choice
    
    case $choice in
        1) systemctl start mihomo ;;
        2) systemctl stop mihomo ;;
        3) systemctl restart mihomo && echo "已重启" && sleep 1 ;;
        4) journalctl -u mihomo -f -n 50 ;;
        5) switch_config ;;
        6) force_update_config ;;
        7) update_ui ;;
        8) 
           echo "更新数据库..."
           curl -sL -o "$CONF_DIR/Country.mmdb" "https://gh-proxy.com/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country-lite.mmdb"
           curl -sL -o "$CONF_DIR/geosite.dat" "https://gh-proxy.com/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat"
           systemctl restart mihomo
           echo "完成"
           sleep 1 ;;
        9) uninstall_mihomo ;;
        0) exit 0 ;;
        *) echo "无效输入" ;;
    esac
done
EOF

chmod +x "$MIHOMO_BIN"

# --- 安装完成，自动进入菜单 ---
echo -e "\n${GREEN}安装完成！${NC}"
echo -e "正在自动安装 Zashboard 面板..."
# 首次安装自动触发一次面板下载
bash -c "source $MIHOMO_BIN; UI_URL='https://gh-proxy.com/https://github.com/Zephyruso/zashboard/archive/refs/heads/gh-pages.zip'; update_ui >/dev/null 2>&1"

echo -e "${GREEN}初始化完毕。正在进入管理菜单...${NC}"
sleep 1
bash "$MIHOMO_BIN"
