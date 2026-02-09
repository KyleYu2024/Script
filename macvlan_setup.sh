#!/bin/bash

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- 权限检查 ---
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}错误: 请先切换到 root 用户再运行此脚本！${NC}"
  echo -e "请先执行: ${YELLOW}sudo -i${NC} 然后再次运行此命令。"
  exit 1
fi

clear
echo -e "${BLUE}#################################################${NC}"
echo -e "${BLUE}#     Docker Macvlan 自动配置脚本 (linux版)   #${NC}"
echo -e "${BLUE}#################################################${NC}"
echo ""

# --- 1. 获取网卡 ---
echo -e "${YELLOW}[1/4] 选择物理网卡...${NC}"
echo "-------------------------------------"
# 尝试自动列出可能的物理网卡，排除虚拟网卡
ip -o link show | awk -F': ' '{print $2}' | grep -vE "lo|docker|veth|shim|macvlan|tun"
echo "-------------------------------------"
read -p "请输入物理网卡名称 (如 bridge0): " PARENT_INTERFACE

# 简单验证
if [ -z "$PARENT_INTERFACE" ]; then
    echo -e "${RED}错误: 网卡名称不能为空！${NC}"
    exit 1
fi

# --- 2. 配置 IP 信息 ---
echo -e "\n${YELLOW}[2/4] 配置网络参数...${NC}"

# 自动猜测网关
DEFAULT_GATEWAY=$(ip route | grep default | awk '{print $3}' | head -n 1)
read -p "请输入网关 IP [默认: $DEFAULT_GATEWAY]: " GATEWAY
GATEWAY=${GATEWAY:-$DEFAULT_GATEWAY}

# 自动猜测子网前缀
SUBNET_PREFIX=$(echo $GATEWAY | cut -d'.' -f1-3)

echo -e "-------------------------------------"
echo -e "说明: 下面的 IP 将用于 NAS 宿主机与容器通信 (Shim)"
read -p "请输入 NAS Shim IP [推荐: ${SUBNET_PREFIX}.200]: " SHIM_IP
SHIM_IP=${SHIM_IP:-"${SUBNET_PREFIX}.200"}

echo -e "-------------------------------------"
echo -e "说明: 下面的范围用于您的 Macvlan 容器"
read -p "容器起始 IP (数字) [推荐: 201]: " START_IP
START_IP=${START_IP:-201}

read -p "容器结束 IP (数字) [推荐: 210]: " END_IP
END_IP=${END_IP:-210}

# --- 3. 生成并部署 Shim 脚本 ---
echo -e "\n${YELLOW}[3/4] 部署系统服务...${NC}"

SCRIPT_PATH="/root/setup_macvlan_shim.sh"
SERVICE_PATH="/etc/systemd/system/macvlan-shim.service"

# 写入执行脚本
cat > $SCRIPT_PATH <<EOF
#!/bin/bash
# Auto-generated macvlan shim script

PARENT_INTERFACE="$PARENT_INTERFACE"
SHIM_INTERFACE="macvlan-shim"
SHIM_IP="$SHIM_IP/32"
START_IP=$START_IP
END_IP=$END_IP
SUBNET_PREFIX="$SUBNET_PREFIX"

# 等待网络就绪
sleep 5

# 清理旧接口
if ip link show \$SHIM_INTERFACE > /dev/null 2>&1; then
    ip link delete \$SHIM_INTERFACE
fi

# 创建接口
ip link add link \$PARENT_INTERFACE dev \$SHIM_INTERFACE type macvlan mode bridge
ip addr add \$SHIM_IP dev \$SHIM_INTERFACE
ip link set \$SHIM_INTERFACE up

# 添加路由
for ((i=START_IP; i<=END_IP; i++)); do
    TARGET="\${SUBNET_PREFIX}.\$i"
    ip route add \$TARGET dev \$SHIM_INTERFACE
done
EOF

chmod +x $SCRIPT_PATH

# 写入 Systemd 服务文件
cat > $SERVICE_PATH <<EOF
[Unit]
Description=Macvlan Shim Service
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash $SCRIPT_PATH
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# 启用服务
systemctl daemon-reload
systemctl enable macvlan-shim.service >/dev/null 2>&1
echo -e "${GREEN}√ 服务已安装并设为开机自启${NC}"

# 立即运行测试
echo "正在尝试启动服务..."
systemctl restart macvlan-shim.service

if systemctl is-active --quiet macvlan-shim.service; then
    echo -e "${GREEN}√ Shim 服务启动成功!${NC}"
else
    echo -e "${RED}X 服务启动失败，请检查网卡名是否正确。${NC}"
    # 这里不退出，允许用户继续尝试创建 Docker 网络
fi

# --- 4. Docker 网络配置 ---
echo -e "\n${YELLOW}[4/4] Docker 网络设置...${NC}"
read -p "是否现在创建 Docker macvlan 网络? (y/n) [默认: y]: " CREATE_NET
CREATE_NET=${CREATE_NET:-y}

if [[ "$CREATE_NET" == "y" || "$CREATE_NET" == "Y" ]]; then
    read -p "请输入网络名称 [默认: macvlan]: " NET_NAME
    NET_NAME=${NET_NAME:-macvlan}
    
    SUBNET="${SUBNET_PREFIX}.0/24"
    
    # 检查并删除同名网络
    if docker network inspect $NET_NAME >/dev/null 2>&1; then
        echo -e "${YELLOW}警告: 网络 '$NET_NAME' 已存在，正在删除旧网络...${NC}"
        docker network rm $NET_NAME >/dev/null
    fi
    
    echo "正在创建 Docker 网络..."
    docker network create -d macvlan \
      --subnet=$SUBNET \
      --gateway=$GATEWAY \
      -o parent=$PARENT_INTERFACE \
      $NET_NAME >/dev/null
      
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}√ Docker 网络 '$NET_NAME' 创建成功!${NC}"
    else
        echo -e "${RED}X Docker 网络创建失败!${NC}"
    fi
else
    echo "跳过 Docker 网络创建。"
fi

echo -e "\n${BLUE}===========================================${NC}"
echo -e "${GREEN}   全部配置完成！请检查上方是否有报错。   ${NC}"
echo -e "${BLUE}===========================================${NC}"
