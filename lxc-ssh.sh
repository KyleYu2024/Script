#!/bin/bash

# 定义颜色
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}>>> 正在配置 LXC SSH 访问...${NC}"

# 1. 自动识别包管理器并安装 OpenSSH
if [ -f /etc/debian_version ]; then
    apt update && apt install -y openssh-server curl
elif [ -f /etc/redhat-release ]; then
    yum install -y openssh-server curl && systemctl enable sshd
elif [ -f /etc/alpine-release ]; then
    apk add openssh curl && rc-update add sshd default
fi

# 2. 修改配置以允许 Root 登录
# 使用 sed 确保配置项存在且正确
CONF="/etc/ssh/sshd_config"
[ -f "$CONF" ] || exit 1

# 备份
cp $CONF ${CONF}.bak

# 修改或添加 PermitRootLogin
if grep -q "^PermitRootLogin" "$CONF"; then
    sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' "$CONF"
else
    echo "PermitRootLogin yes" >> "$CONF"
fi

# 修改或添加 PasswordAuthentication
if grep -q "^PasswordAuthentication" "$CONF"; then
    sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' "$CONF"
else
    echo "PasswordAuthentication yes" >> "$CONF"
fi

# 3. 重启 SSH 服务
if [ -f /etc/alpine-release ]; then
    /etc/init.d/sshd restart
else
    systemctl restart ssh || systemctl restart sshd
fi

echo -e "${GREEN}>>> 配置完成！请确保已通过 'passwd root' 设置密码。${NC}"
