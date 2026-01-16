#!/bin/bash
set -e

# =================配置区域=================
# 目标 LXC ID (根据需要修改)
TID=199
# 自定义 Docker 镜像加速地址
DOCKER_MIRROR="https://docker.1ms.run"
# =========================================

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=====================================================${NC}"
echo -e "${BLUE}   LXC Debian 13 Docker 黄金模板一键构建脚本   ${NC}"
echo -e "${BLUE}   适配: HUST源 | Docker国内安装 | 自动验证清理      ${NC}"
echo -e "${BLUE}=====================================================${NC}"

# === 0. 环境检查 ===
if [ ! -f "/etc/pve/lxc/$TID.conf" ]; then
    echo -e "${RED}[Error] LXC $TID 配置文件不存在，请先在 PVE 创建容器。${NC}"
    exit 1
fi

STATUS=$(pct status $TID | awk '{print $2}')
if [ "$STATUS" != "running" ]; then
    echo -e "${YELLOW}[Info] LXC $TID 未运行，正在启动...${NC}"
    pct start $TID
    sleep 5
fi

# 定义一个在容器内执行命令的函数，简化代码
function run_in_lxc() {
    pct exec $TID -- bash -c "$1"
}

echo -e "${GREEN}==> Step 1: 基础系统优化 (换源 & Locale)${NC}"
# 1.1 修复 Locale (防止 perl 警告)
run_in_lxc "apt update -y && apt install -y locales && echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen && locale-gen && update-locale LANG=en_US.UTF-8"

# 1.2 替换为华中科大 (HUST) 源 (Debian 13 Trixie)
run_in_lxc "
if [ -f /etc/apt/sources.list ]; then mv /etc/apt/sources.list /etc/apt/sources.list.bak; fi
cat > /etc/apt/sources.list <<EOF
deb http://mirrors.hust.edu.cn/debian/ trixie main non-free-firmware
deb-src http://mirrors.hust.edu.cn/debian/ trixie main non-free-firmware
deb http://mirrors.hust.edu.cn/debian/ trixie-updates main non-free-firmware
deb-src http://mirrors.hust.edu.cn/debian/ trixie-updates main non-free-firmware
deb http://mirrors.hust.edu.cn/debian-security/ trixie-security main non-free-firmware
deb-src http://mirrors.hust.edu.cn/debian-security/ trixie-security main non-free-firmware
EOF
"

echo -e "${GREEN}==> Step 2: 安装常用工具 & 设置时区${NC}"
run_in_lxc "
apt update -y &&
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime &&
echo 'Asia/Shanghai' > /etc/timezone &&
apt install -y curl ca-certificates gnupg vim htop net-tools iputils-ping
"

echo -e "${GREEN}==> Step 3: 安装 Docker (使用 HUST 内网源)${NC}"
# 注意：Debian 13 尚未发布，Docker 官方源无 trixie 分支。
# 策略：强制使用 bookworm (Debian 12) 分支进行安装，完美兼容。
run_in_lxc "
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://mirrors.hust.edu.cn/docker-ce/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo \
  \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://mirrors.hust.edu.cn/docker-ce/linux/debian \
  bookworm stable\" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

apt update -y
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
"

echo -e "${GREEN}==> Step 4: 配置 Docker (镜像加速: $DOCKER_MIRROR)${NC}"
run_in_lxc "
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<EOF
{
  \"log-driver\": \"json-file\",
  \"log-opts\": {
    \"max-size\": \"10m\",
    \"max-file\": \"3\"
  },
  \"registry-mirrors\": [
    \"$DOCKER_MIRROR\"
  ]
}
EOF
systemctl restart docker
"

echo -e "${GREEN}==> Step 5: 安全与权限配置 (SSH & LXC)${NC}"
# 5.1 SSH Root 登录
run_in_lxc "
apt install -y openssh-server &&
systemctl enable ssh &&
systemctl start ssh &&
sed -i 's/#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config &&
sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config &&
sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config &&
sed -i 's/PermitRootLogin no/PermitRootLogin yes/' /etc/ssh/sshd_config &&
systemctl restart ssh
"

# 5.2 LXC 宿主机配置文件修改
LXC_CONF="/etc/pve/lxc/$TID.conf"
if ! grep -q "lxc.capabilities: sys_admin" $LXC_CONF; then
    cat >> $LXC_CONF <<EOF

# Docker 必需权限
lxc.apparmor.profile: unconfined
lxc.cap.drop:
lxc.cgroup2.devices.allow: a
lxc.capabilities: sys_admin sys_resource sys_ptrace sys_time sys_tty_config mknod audit_write
lxc.mount.auto: cgroup:rw
lxc.apparmor.allow_nesting: 1
EOF
    echo " -> PVE 侧 LXC 权限已添加"
else
    echo " -> PVE 侧 LXC 权限已存在，跳过"
fi

# 5.3 容器内 IP 转发
run_in_lxc "grep -qxF 'net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf && sysctl -p"

echo -e "${GREEN}==> Step 6: 最终验证 (自检)${NC}"
ERROR_COUNT=0

# 验证函数
check_item() {
    if run_in_lxc "$2" > /dev/null 2>&1; then
        echo -e "[${GREEN}OK${NC}] $1"
    else
        echo -e "[${RED}FAIL${NC}] $1"
        ERROR_COUNT=$((ERROR_COUNT+1))
    fi
}

check_item "系统源 (HUST)" "grep -q 'hust.edu.cn' /etc/apt/sources.list"
check_item "Docker 运行状态" "systemctl is-active docker"
check_item "Docker 镜像加速生效" "docker info | grep -q '$DOCKER_MIRROR'"
check_item "SSH Root 登录" "sshd -T | grep -q 'permitrootlogin yes'"
check_item "IP 转发开启" "sysctl net.ipv4.ip_forward | grep -q '1'"

if [ $ERROR_COUNT -eq 0 ]; then
    echo -e "${GREEN}==> 验证通过！准备执行模板清理...${NC}"
    
    # === Step 7: 清理 ===
    run_in_lxc "
    apt autoremove -y && apt clean &&
    rm -rf /var/lib/apt/lists/* &&
    rm -rf /var/log/*.log &&
    > /root/.bash_history &&
    truncate -s 0 /etc/machine-id
    "
    
    echo -e "${GREEN}==> 清理完成。正在停止容器 LXC $TID ...${NC}"
    pct stop $TID
    echo -e "${BLUE}=====================================================${NC}"
    echo -e "${GREEN} SUCCESS! 模板制作完成。 ${NC}"
    echo -e "${GREEN} 请在 PVE 界面右键 LXC $TID -> Convert to template ${NC}"
    echo -e "${BLUE}=====================================================${NC}"
else
    echo -e "${RED}==> 警告：检测到 $ERROR_COUNT 个错误，请检查上方日志，容器未停止。${NC}"
    exit 1
fi
