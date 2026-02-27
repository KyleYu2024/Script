#!/bin/bash

# ==========================================
# Docker Macvlan 自动配置脚本 (Debian/Ubuntu)
# 功能：一键创建 Macvlan 网络 + 宿主机互通 Shim
# ==========================================

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- 权限检查 ---
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}错误: 请使用 sudo -i 切换到 root 用户后再运行！${NC}"
  exit 1
fi

clear
echo -e "${BLUE}#################################################${NC}"
echo -e "${BLUE}#     Docker Macvlan 智能一键配置工具   #${NC}"
echo -e "${BLUE}#################################################${NC}"

# ==========================================
# 1. 智能获取网卡
# ==========================================
echo -e "\n${YELLOW}[1/5] 智能检测物理网卡...${NC}"

# 排除虚拟网卡，只显示物理网卡列表供参考
INTERFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -vE "lo|docker|veth|shim|macvlan|tun|virbr")

# 核心改进：自动推断当前出网的主网卡
DEFAULT_IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1)
if [ -z "$DEFAULT_IFACE" ]; then
    # 备用方案：查默认路由
    DEFAULT_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -n 1)
fi

echo "------------------------------------------------------------"
echo "系统检测到以下物理网卡:"
echo -e "${GREEN}${INTERFACES}${NC}"
echo "------------------------------------------------------------"

if [ -n "$DEFAULT_IFACE" ]; then
    echo -e "💡 系统推测你的主网卡是: ${GREEN}$DEFAULT_IFACE${NC}"
    read -p "请输入网卡名称 [直接回车默认使用: $DEFAULT_IFACE]: " INPUT_IFACE
    PARENT_INTERFACE=${INPUT_IFACE:-$DEFAULT_IFACE}
else
    echo -e "小白提示：请直接从上方${GREEN}绿字${NC}中复制名称 (如 eth0, enp3s0)"
    read -p "请输入网卡名称: " PARENT_INTERFACE
fi

# 验证网卡是否存在
if ! ip link show "$PARENT_INTERFACE" > /dev/null 2>&1; then
    echo -e "${RED}错误: 找不到网卡 $PARENT_INTERFACE，请检查拼写！${NC}"
    exit 1
fi

# ==========================================
# 2. 自动分析网络环境
# ==========================================
echo -e "\n${YELLOW}[2/5] 分析网络环境...${NC}"

HOST_IP_CIDR=$(ip -o -f inet addr show $PARENT_INTERFACE | awk '{print $4}' | head -n 1)
NETWORK_CIDR=$(ip route show dev $PARENT_INTERFACE scope link | awk '{print $1}' | head -n 1)
GATEWAY_IP=$(ip route | grep default | grep $PARENT_INTERFACE | awk '{print $3}' | head -n 1)
SUBNET_PREFIX=$(echo $GATEWAY_IP | awk -F. '{print $1"."$2"."$3}')

echo -e "  - 当前网卡 IP:   ${GREEN}$HOST_IP_CIDR${NC}"
echo -e "  - 所在网段 CIDR: ${GREEN}$NETWORK_CIDR${NC} (将用于 Docker 网络)"
echo -e "  - 网关地址:      ${GREEN}$GATEWAY_IP${NC}"
echo -e "  - IP 前缀:       ${GREEN}$SUBNET_PREFIX.x${NC}"

if [ -z "$NETWORK_CIDR" ] || [ -z "$GATEWAY_IP" ]; then
    echo -e "${RED}错误: 无法自动获取网络信息，请检查网络连接！${NC}"
    exit 1
fi

# ==========================================
# 3. 配置用户参数 (小白防呆版)
# ==========================================
echo -e "\n${YELLOW}[3/5] 规划 Macvlan 专属 IP 地址段...${NC}"
echo "------------------------------------------------------------"
echo -e "⚠️  ${RED}防断网警告：${NC}为了防止 IP 冲突导致设备掉线，我们需要从你家的"
echo "局域网中，划出一小段【绝对没有被路由器分配给其他设备】的空闲 IP。"
echo "（建议这一段 IP 的数字尽量大一点，比如 200 以后）"
echo "------------------------------------------------------------"

# 设置 Shim IP
echo -e "\n${GREEN}▶ 第一步：给宿主机分配一个“虚拟通讯 IP”${NC}"
echo "原因：在 Macvlan 模式下，宿主机和容器默认是失联的。我们需要给宿主机"
echo "      分配一个专属的替身 IP，让它俩能互相说话。"
read -p "请输入此虚拟 IP 的最后一位数字 (推荐空闲数字，如 220): " SHIM_HOST_ID
SHIM_HOST_ID=${SHIM_HOST_ID:-220}
SHIM_IP="${SUBNET_PREFIX}.${SHIM_HOST_ID}"

# 设置容器范围
echo -e "\n${GREEN}▶ 第二步：划定 Docker 容器的专属 IP 范围${NC}"
echo "原因：以后新建的 Macvlan 容器，都会在这个范围里排队领 IP。"
read -p "请输入【容器起始 IP】最后一位数字 (如 221): " START_ID
START_ID=${START_ID:-221}

read -p "请输入【容器结束 IP】最后一位数字 (如 230): " END_ID
END_ID=${END_ID:-230}

# 逻辑冲突检查
if [ $START_ID -ge $END_ID ]; then
    echo -e "${RED}错误: 起始数字必须小于结束数字！(例如 221 -> 230)${NC}"
    exit 1
fi
if [ "$SHIM_HOST_ID" -ge "$START_ID" ] && [ "$SHIM_HOST_ID" -le "$END_ID" ]; then
    echo -e "${YELLOW}警告: 宿主机的虚拟 IP ($SHIM_HOST_ID) 包含在了容器的 IP 范围内！${NC}"
    echo "为了稳定，强烈建议宿主机 IP 和容器 IP 范围错开。"
    read -p "按回车键强行继续，或按 Ctrl+C 退出重来..."
fi

echo -e "\n------------------------------------------------------------"
echo -e "你的最终网络规划如下："
echo -e "宿主机虚拟 IP (用于互相访问): ${GREEN}${SHIM_IP}${NC}"
echo -e "Docker 容器可用 IP 范围:      ${GREEN}${SUBNET_PREFIX}.${START_ID} 到 ${SUBNET_PREFIX}.${END_ID}${NC}"
echo -e "------------------------------------------------------------"

# ==========================================
# 4. 部署 Shim 脚本 (开机自启)
# ==========================================
echo -e "\n${YELLOW}[4/5] 部署宿主机互通服务 (Shim)...${NC}"

SCRIPT_PATH="/usr/local/bin/macvlan_shim.sh"
SERVICE_PATH="/etc/systemd/system/macvlan-shim.service"

cat > $SCRIPT_PATH <<EOF
#!/bin/bash
PARENT="$PARENT_INTERFACE"
SHIM_NAME="macvlan-shim"
SHIM_IP="$SHIM_IP/32"
PREFIX="$SUBNET_PREFIX"
START=$START_ID
END=$END_ID

sleep 5
ip link show \$SHIM_NAME > /dev/null 2>&1 && ip link delete \$SHIM_NAME
ip link add link \$PARENT dev \$SHIM_NAME type macvlan mode bridge
ip addr add \$SHIM_IP dev \$SHIM_NAME
ip link set \$SHIM_NAME up

for ((i=START; i<=END; i++)); do
    ip route add "\${PREFIX}.\$i" dev \$SHIM_NAME
done
EOF

chmod +x $SCRIPT_PATH

cat > $SERVICE_PATH <<EOF
[Unit]
Description=Macvlan Shim Logic
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash $SCRIPT_PATH
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable macvlan-shim.service >/dev/null 2>&1
echo "正在启动后台路由服务..."
systemctl restart macvlan-shim.service

if systemctl is-active --quiet macvlan-shim.service; then
    echo -e "${GREEN}√ Shim 服务启动成功！宿主机现已打通 Macvlan 接口。${NC}"
else
    echo -e "${RED}X 服务启动失败，请使用 systemctl status macvlan-shim.service 检查报错！${NC}"
fi

# ==========================================
# 5. Docker 网络预检与创建 (智能复用逻辑)
# ==========================================
echo -e "\n${YELLOW}[5/5] Docker 网络预检与配置...${NC}"

NET_NAME="macvlan" # 默认名称
CREATE_DOCKER="y"

if ! docker info >/dev/null 2>&1; then
    echo -e "${RED}警告: 无法连接到 Docker 服务！可能是未安装或未启动。${NC}"
    echo -e "已跳过 Docker 网络创建步骤。"
    CREATE_DOCKER="n"
else
    # 查找是否有挂载在当前网卡上的 macvlan
    MATCHED_NET=""
    EXISTING_MACVLANS=$(docker network ls --filter driver=macvlan --format "{{.Name}}")
    
    for net in $EXISTING_MACVLANS; do
        NET_PARENT=$(docker network inspect "$net" --format '{{index .Options "parent"}}' 2>/dev/null)
        if [ "$NET_PARENT" == "$PARENT_INTERFACE" ]; then
            MATCHED_NET="$net"
            break
        fi
    done

    if [ -n "$MATCHED_NET" ]; then
        echo -e "🎉 ${GREEN}好消息：检测到网卡 $PARENT_INTERFACE 上已经存在名为 '$MATCHED_NET' 的 Macvlan 网络！${NC}"
        echo -e "同网卡同网段无需重复创建，脚本将自动复用该网络。"
        NET_NAME="$MATCHED_NET"
        CREATE_DOCKER="n"
    else
        read -p "请输入你想创建的网络名称 [直接回车默认: macvlan]: " USER_NET_NAME
        NET_NAME=${USER_NET_NAME:-macvlan}
        
        # 检查名字是否被非当前网卡的网络占用了
        if docker network inspect "$NET_NAME" >/dev/null 2>&1; then
            echo -e "${RED}错误: 网络名称 '$NET_NAME' 已被其他网络占用，请先删除或更换名称。${NC}"
            CREATE_DOCKER="n"
        else
            echo "正在执行 Docker Macvlan 创建命令..."
            docker network create -d macvlan \
                --subnet="$NETWORK_CIDR" \
                --gateway="$GATEWAY_IP" \
                -o parent="$PARENT_INTERFACE" \
                "$NET_NAME"

            if [ $? -eq 0 ]; then
                echo -e "${GREEN}√ Docker 网络 '$NET_NAME' 创建成功！${NC}"
            else
                echo -e "${RED}X Docker 网络创建失败。请检查上方报错信息。${NC}"
            fi
        fi
    fi
fi

# ==========================================
# 6. 生成 Compose 模板 (终极提示)
# ==========================================
echo -e "\n${BLUE}============================================================${NC}"
echo -e "${GREEN}                  🎉 全部配置完成！ 🎉                   ${NC}"
echo -e "${BLUE}============================================================${NC}"

echo -e "\n在未来编写 ${YELLOW}docker-compose.yml${NC} 时，请参考以下模板："
echo -e "务必注意 ${RED}红色部分${NC} 是必须要加的配置！"
echo "------------------------------------------------------------"

echo "services:"
echo "  your_service:"
echo "    image: nginx:latest"
echo "    container_name: macvlan_test"
echo "    restart: always"
echo -e "${RED}    networks:"
echo -e "      ${NET_NAME}_net:"
echo -e "        # 你必须手动给容器指定一个 IP，范围是: ${START_ID} - ${END_ID}"
echo -e "        ipv4_address: ${SUBNET_PREFIX}.${START_ID}${NC}"
echo ""
echo -e "${RED}networks:"
echo -e "  ${NET_NAME}_net:"
echo -e "    external:"
echo -e "      name: ${NET_NAME}${NC}"
echo "------------------------------------------------------------"
echo -e "${YELLOW}提示: 如果后续增加容器，只需把 ipv4_address 换成范围内的新 IP 即可。${NC}\n"
