#!/bin/bash

# =========================================================
# Mihomo 通用安装脚本 (VM/LXC 自适应 + CN加速 + 通知中心)
# =========================================================

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

clear
echo -e "${BLUE}#################################################${NC}"
echo -e "${BLUE}#      Mihomo 裸核网关安装 (全环境通用版)       #${NC}"
echo -e "${BLUE}#################################################${NC}"
echo ""

# =========================================================
# 1. 虚拟化环境检测与 TUN 适配
# =========================================================
echo -e "${YELLOW}>>> [1/6] 检测虚拟化环境...${NC}"

# 检测虚拟化类型 (依赖 systemd)
if command -v systemd-detect-virt >/dev/null 2>&1; then
    VIRT_TYPE=$(systemd-detect-virt)
else
    # 备用检测方案
    VIRT_TYPE="unknown"
fi

echo -e "当前环境识别为: ${GREEN}${VIRT_TYPE}${NC}"

if [[ "$VIRT_TYPE" == "lxc" ]]; then
    # === LXC 环境逻辑 ===
    echo -e "检测到 LXC 容器，正在检查宿主机设备映射..."
    if [ ! -c /dev/net/tun ]; then
        echo -e "${RED}[FATAL] 致命错误：无法访问 /dev/net/tun 设备。${NC}"
        echo -e "--------------------------------------------------------"
        echo -e "LXC 容器需要宿主机授权 TUN 设备权限。"
        echo -e "请登录 **PVE 宿主机 (Host)** 的 Shell，执行以下操作："
        echo -e "1. 编辑配置文件: ${GREEN}nano /etc/pve/lxc/<你的容器ID>.conf${NC}"
        echo -e "2. 添加两行："
        echo -e "${YELLOW}lxc.cgroup2.devices.allow: c 10:200 rwm${NC}"
        echo -e "${YELLOW}lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file${NC}"
        echo -e "3. 保存并 **重启此容器**。"
        echo -e "--------------------------------------------------------"
        exit 1
    else
        echo -e "${GREEN}[OK] LXC TUN 权限检查通过。${NC}"
    fi
else
    # === VM 或 物理机 环境逻辑 ===
    echo -e "检测为 VM/实体机，尝试加载 TUN 内核模块..."
    modprobe tun >/dev/null 2>&1
    
    # 再次检查
    if [ ! -c /dev/net/tun ]; then
        # 尝试创建设备节点 (某些极简 VM 系统可能缺这个)
        mkdir -p /dev/net
        mknod /dev/net/tun c 10 200
        chmod 666 /dev/net/tun
    fi

    if [ ! -c /dev/net/tun ]; then
        echo -e "${RED}[错误] 无法创建或访问 /dev/net/tun。请检查内核是否支持 TUN/TAP。${NC}"
        exit 1
    else
        echo -e "${GREEN}[OK] TUN 设备就绪。${NC}"
    fi
fi

# =========================================================
# 2. 环境配置与依赖
# =========================================================
echo -e "\n${YELLOW}>>> [2/6] 系统环境准备...${NC}"

PACKAGES="curl gzip tar nano"
if [ -f /etc/debian_version ]; then
    apt update -q && dpkg -s $PACKAGES >/dev/null 2>&1 || apt install -y $PACKAGES -q
elif [ -f /etc/alpine-release ]; then
    apk add $PACKAGES bash grep
elif [ -f /etc/redhat-release ]; then
    yum install -y $PACKAGES
else
    echo -e "${RED}不支持的系统类型${NC}"; exit 1
fi

# 开启 IP 转发
echo "配置 sysctl 转发..."
NEED_RELOAD=0
if ! sysctl net.ipv4.ip_forward | grep -q "1"; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf; NEED_RELOAD=1
fi
if ! sysctl net.ipv6.conf.all.forwarding | grep -q "1"; then
    echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf; NEED_RELOAD=1
fi
[ "$NEED_RELOAD" -eq 1 ] && sysctl -p >/dev/null 2>&1

# =========================================================
# 3. 下载核心组件 (CN加速)
# =========================================================
echo -e "\n${YELLOW}>>> [3/6] 下载组件 (CN加速)...${NC}"

ARCH=$(uname -m)
MIHOMO_VER="v1.18.1"
GH_PROXY="https://gh-proxy.com/"
BASE_URL="${GH_PROXY}https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VER}"

case $ARCH in
    x86_64) DL_URL="${BASE_URL}/mihomo-linux-amd64-${MIHOMO_VER}.gz" ;;
    aarch64) DL_URL="${BASE_URL}/mihomo-linux-arm64-${MIHOMO_VER}.gz" ;;
    *) echo -e "${RED}不支持的架构: $ARCH${NC}"; exit 1 ;;
esac

if [ ! -f /usr/local/bin/mihomo ]; then
    echo "下载 Mihomo 内核..."
    curl -L -o /tmp/mihomo.gz "$DL_URL" && gzip -d /tmp/mihomo.gz
    chmod +x /tmp/mihomo && mv /tmp/mihomo /usr/local/bin/mihomo
fi

mkdir -p /etc/mihomo/ui
# 数据库下载
GEO_MMDB="${GH_PROXY}https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country-lite.mmdb"
GEO_SITE="${GH_PROXY}https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat"

echo "下载数据库..."
curl -sL -o /etc/mihomo/Country.mmdb "$GEO_MMDB"
curl -sL -o /etc/mihomo/geosite.dat "$GEO_SITE"

if [ ! -d /etc/mihomo/ui/assets ]; then
    echo "下载 Web UI..."
    UI_URL="${GH_PROXY}https://github.com/MetaCubeX/metacubexd/releases/download/v1.139.1/compressed-dist.tgz"
    curl -sL -o /tmp/ui.tgz "$UI_URL"
    tar -xzf /tmp/ui.tgz -C /etc/mihomo/ui && rm /tmp/ui.tgz
fi

# =========================================================
# 4. 配置文件处理
# =========================================================
echo -e "\n${YELLOW}>>> [4/6] 配置文件设置${NC}"
CONFIG_FILE="/etc/mihomo/config.yaml"

echo "请选择配置来源："
echo "1) 粘贴配置 (手动粘贴 YAML)"
echo "2) 托管链接 (Sub-Store/订阅链接)"
read -p "请输入 [1-2]: " CHOICE

if [ "$CHOICE" == "1" ]; then
    echo -e "${GREEN}即将打开编辑器，粘贴后按 Ctrl+O 保存，Ctrl+X 退出。${NC}"
    read -p "按回车开始..."
    nano "$CONFIG_FILE"
    if [ ! -s "$CONFIG_FILE" ]; then echo -e "${RED}文件为空，退出。${NC}"; exit 1; fi

elif [ "$CHOICE" == "2" ]; then
    read -p "请输入托管 URL: " SUB_URL
    read -p "请输入自动更新间隔 (分钟): " UPDATE_MIN
    
    echo "正在下载..."
    curl -L -s -o "$CONFIG_FILE" "$SUB_URL"
    if [ ! -s "$CONFIG_FILE" ]; then echo -e "${RED}下载失败！${NC}"; exit 1; fi

    # 自动更新脚本
    cat > /usr/local/bin/update_mihomo.sh <<EOF
#!/bin/bash
curl -L -s -o /etc/mihomo/config.yaml "$SUB_URL" && systemctl restart mihomo
EOF
    chmod +x /usr/local/bin/update_mihomo.sh

    # Timer
    cat > /etc/systemd/system/mihomo-update.service <<EOF
[Unit]
Description=Update Mihomo Config
[Service]
Type=oneshot
ExecStart=/usr/local/bin/update_mihomo.sh
EOF
    cat > /etc/systemd/system/mihomo-update.timer <<EOF
[Unit]
Description=Update Mihomo every ${UPDATE_MIN} min
[Timer]
OnBootSec=5min
OnUnitActiveSec=${UPDATE_MIN}min
[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now mihomo-update.timer
    echo -e "${GREEN}自动更新已配置。${NC}"
else
    exit 1
fi

# --- 智能校验与注入 ---
echo -e "\n优化配置中..."

# 1. 注入 GeoX URL (保证国内更新正常)
sed -i -e '$a\' "$CONFIG_FILE" # 确保文件末尾有空行
cat >> "$CONFIG_FILE" <<EOF

# --- INJECTED BY INSTALLER ---
geox-url:
  geosite: "${GH_PROXY}https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat"
  geoip: "${GH_PROXY}https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip-lite.dat"
  mmdb: "${GH_PROXY}https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country-lite.mmdb"
  asn: "${GH_PROXY}https://github.com/xishang0128/geoip/releases/download/latest/GeoLite2-ASN.mmdb"
EOF

# 2. 注入 TUN/DNS (透明网关必需)
HAS_TUN=$(grep -E "^tun:" "$CONFIG_FILE")
if [ -z "$HAS_TUN" ]; then
    echo -e "${RED}[提示] 未检测到 TUN 配置，正在注入网关参数...${NC}"
    cat >> "$CONFIG_FILE" <<EOF
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
  fallback-filter:
    geoip: true
    ipcidr:
      - 240.0.0.0/4
EOF
    echo -e "${GREEN}网关参数已注入。${NC}"
else
    echo -e "${GREEN}检测到已有 TUN 配置，跳过注入。${NC}"
fi

# =========================================================
# 5. 通知中心配置 (Watchdog)
# =========================================================
echo -e "\n${YELLOW}>>> [5/6] 故障报警配置${NC}"
echo -e "示例格式: ${BLUE}POST http://10.10.1.9:18088/api/v1/notify/mihomo${NC}"
read -p "请输入通知接口 URL (留空跳过): " NOTIFY_URL

if [ ! -z "$NOTIFY_URL" ]; then
    cat > /usr/local/bin/check_mihomo.sh <<EOF
#!/bin/bash
if ! systemctl is-active --quiet mihomo; then
    curl -s -X POST -H "Content-Type: application/json" \\
         -d '{"title":"Mihomo服务告警","content":"检测到服务停止，正在自动重启。"}' \\
         "$NOTIFY_URL"
    systemctl restart mihomo
fi
EOF
    chmod +x /usr/local/bin/check_mihomo.sh

    cat > /etc/systemd/system/mihomo-watchdog.service <<EOF
[Unit]
Description=Check Mihomo Status
[Service]
Type=oneshot
ExecStart=/usr/local/bin/check_mihomo.sh
EOF
    cat > /etc/systemd/system/mihomo-watchdog.timer <<EOF
[Unit]
Description=Watchdog every 3 minutes
[Timer]
OnBootSec=2min
OnUnitActiveSec=3min
[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now mihomo-watchdog.timer
    echo -e "${GREEN}报警监控已开启。${NC}"
fi

# =========================================================
# 6. 启动与总结
# =========================================================
echo -e "\n${YELLOW}>>> [6/6] 启动服务${NC}"

cat > /etc/systemd/system/mihomo.service <<EOF
[Unit]
Description=Mihomo Daemon
After=network.target

[Service]
Type=simple
User=root
Restart=always
ExecStart=/usr/local/bin/mihomo -d /etc/mihomo
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mihomo
systemctl start mihomo

sleep 2
if systemctl is-active --quiet mihomo; then
    IP=$(hostname -I | awk '{print $1}')
    echo -e "\n${GREEN}=== 安装成功 ===${NC}"
    echo -e "Web 面板: http://${IP}:9090/ui"
    echo -e "配置文件: /etc/mihomo/config.yaml"
    if [ ! -z "$NOTIFY_URL" ]; then
        echo -e "通知配置: 已启用"
    fi
    echo -e "------------------------------"
    echo -e "请将局域网网关/DNS指向: ${YELLOW}${IP}${NC}"
else
    echo -e "${RED}启动失败，请检查配置。${NC}"
fi
