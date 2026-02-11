#!/bin/bash

# ==========================================
# 微信转发代理 (WxChat Proxy) 一键安装脚本
# 开源地址: https://github.com/KyleYu2024/Script
# ==========================================

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 检查 Root 权限
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误: 请使用 root 权限运行此脚本！${PLAIN}"
    echo -e "示例: sudo bash $0"
    exit 1
fi

echo -e "${GREEN}==============================================${PLAIN}"
echo -e "${GREEN}      微信转发代理 (WxChat) 一键安装工具      ${PLAIN}"
echo -e "${GREEN}==============================================${PLAIN}"

# 1. 检查并安装必要依赖
install_base() {
    echo -e "${YELLOW}正在检查系统依赖...${PLAIN}"
    if [ -f /etc/debian_version ]; then
        apt-get update
        apt-get install -y nginx curl
    elif [ -f /etc/redhat-release ]; then
        if ! command -v nginx >/dev/null 2>&1; then
             yum install -y epel-release
             yum install -y nginx curl
        fi
    elif [ -f /etc/alpine-release ]; then
        apk add --no-cache nginx curl
    else
        echo -e "${RED}不支持的操作系统，请手动安装 Nginx 后重试。${PLAIN}"
        exit 1
    fi
}

install_base

# 2. 获取用户端口 (交互部分)
# 使用 /dev/tty 确保即使在管道模式下也能读取输入
echo -e "${YELLOW}请设置服务端口 (默认为 80)${PLAIN}"
read -p "端口号: " input_port < /dev/tty
PORT=${input_port:-80}

if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}端口必须是数字，脚本退出。${PLAIN}"
    exit 1
fi

echo -e "${GREEN}已选择端口: ${PORT}${PLAIN}"

# 3. 部署静态资源
WEB_DIR="/opt/wxchat/web"
mkdir -p "$WEB_DIR"

# 写入 index.html
cat > "$WEB_DIR/index.html" <<EOF
<html>
<head>
    <meta charset="utf-8">
    <title>微信代理</title>
</head>
<body>
    <h1>微信代理搭建成功！</h1>
    <p>当前监听端口: ${PORT}</p>
</body>
</html>
EOF

# 设置权限
chmod -R 755 /opt/wxchat

# 4. 生成 Nginx 配置
# 适配不同系统的 Nginx 配置目录
if [ -d "/etc/nginx/conf.d" ]; then
    CONF_PATH="/etc/nginx/conf.d/wxchat.conf"
elif [ -d "/etc/nginx/http.d" ]; then
    CONF_PATH="/etc/nginx/http.d/wxchat.conf"
elif [ -d "/etc/nginx/sites-available" ]; then
    CONF_PATH="/etc/nginx/sites-available/wxchat.conf"
    ln -sf "$CONF_PATH" /etc/nginx/sites-enabled/
else
    echo -e "${RED}找不到 Nginx 配置目录，请手动配置。${PLAIN}"
    exit 1
fi

cat > "$CONF_PATH" <<EOF
server {
    listen       ${PORT};
    listen  [::]:${PORT};
    server_name  _;

    # 静态页面
    location / {
        root   ${WEB_DIR};
        index  index.html index.htm;
    }

    # 微信企业号接口转发
    location /cgi-bin/gettoken { proxy_pass https://qyapi.weixin.qq.com; }
    location /cgi-bin/message/send { proxy_pass https://qyapi.weixin.qq.com; }
    location /cgi-bin/menu/create { proxy_pass https://qyapi.weixin.qq.com; }
    location /cgi-bin/media/upload { proxy_pass https://qyapi.weixin.qq.com; }
    location /cgi-bin/media/get { proxy_pass https://qyapi.weixin.qq.com; }
}
EOF

# 5. 放行防火墙 (可选)
if command -v ufw >/dev/null 2>&1; then
    ufw allow "$PORT"/tcp >/dev/null 2>&1
elif command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --zone=public --add-port="$PORT"/tcp --permanent >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
fi

# 6. 重启服务
echo -e "${YELLOW}正在重启 Nginx 服务...${PLAIN}"
if command -v systemctl >/dev/null 2>&1; then
    systemctl enable nginx
    systemctl restart nginx
elif command -v rc-service >/dev/null 2>&1; then
    rc-service nginx enable
    rc-service nginx restart
else
    nginx -s reload 2>/dev/null || nginx
fi

# 7. 完成提示
IP=$(curl -s4 ifconfig.me || echo "127.0.0.1")
echo -e "${GREEN}==============================================${PLAIN}"
echo -e "${GREEN} 安装成功！${PLAIN}"
echo -e " 访问地址: http://${IP}:${PORT}"
echo -e " 静态文件: ${WEB_DIR}"
echo -e " 配置文件: ${CONF_PATH}"
echo -e "${GREEN}==============================================${PLAIN}"
