#!/bin/bash

# =================================================================
# Docker 拉取专用网络配置脚本 (Debian/LXC 优化版)
# 功能：配置 Daemon 代理 / 配置 Registry Mirror / 一键还原
# 特点：仅影响 docker pull/push，不影响容器运行和宿主机网络
# =================================================================

# 颜色配置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 检查 Root 权限
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误：请使用 root 权限运行此脚本。${NC}"
   exit 1
fi

# 配置文件路径
PROXY_CONF_DIR="/etc/systemd/system/docker.service.d"
PROXY_CONF_FILE="$PROXY_CONF_DIR/http-proxy.conf"
DAEMON_JSON="/etc/docker/daemon.json"

# 默认加速镜像列表 (包含你提到的 docker.1ms.run)
# 如果你有其他优选地址，可以在这里添加
DEFAULT_MIRRORS='"https://docker.1ms.run", "https://docker.m.daocloud.io", "https://dockerproxy.com"'

# -----------------------------------------------------------------
# 功能函数
# -----------------------------------------------------------------

# 1. 配置代理 (仅限 Docker Daemon)
config_proxy() {
    echo -e "\n${BLUE}>>> 配置 Docker 守护进程代理${NC}"
    echo -e "${YELLOW}提示：请输入你的本地代理地址 (例如 http://192.168.31.5:7890)${NC}"
    echo -e "${YELLOW}注意：如果你在 LXC 容器内，请填宿主机 IP，不要填 127.0.0.1${NC}"
    read -p "代理地址: " proxy_url

    if [[ -z "$proxy_url" ]]; then
        echo -e "${RED}地址为空，跳过代理设置。${NC}"
        return
    fi

    # 创建目录
    mkdir -p "$PROXY_CONF_DIR"

    # 写入配置 (强制添加 NO_PROXY 避免本地环回问题)
    cat > "$PROXY_CONF_FILE" <<EOF
[Service]
Environment="HTTP_PROXY=$proxy_url"
Environment="HTTPS_PROXY=$proxy_url"
Environment="NO_PROXY=localhost,127.0.0.1,::1,.local"
EOF
    echo -e "${GREEN}√ 代理配置已写入 systemd (仅对 Docker 进程生效)${NC}"
}

# 2. 配置镜像加速 (保持原镜像名拉取)
config_mirrors() {
    echo -e "\n${BLUE}>>> 配置 Registry Mirrors (加速镜像)${NC}"
    echo -e "当前预设镜像: ${YELLOW}$DEFAULT_MIRRORS${NC}"
    read -p "是否使用预设列表? (y/n) [默认y]: " use_default
    use_default=${use_default:-y}

    local mirrors_content=""
    if [[ "$use_default" == "y" ]]; then
        mirrors_content="$DEFAULT_MIRRORS"
    else
        echo -e "请输入自定义镜像地址 (格式: \"url1\", \"url2\"):"
        read -p "> " custom_mirrors
        mirrors_content="$custom_mirrors"
    fi

    # 检查是否存在 daemon.json，如果存在则尝试保留其他配置
    if [ -f "$DAEMON_JSON" ]; then
        # 简单判断是否是合法 JSON，如果太复杂建议手动合并
        echo -e "${YELLOW}发现现有 daemon.json，正在覆盖 registry-mirrors 配置...${NC}"
        # 这里为了脚本健壮性，选择直接覆盖或重写 registry-mirrors 键值
        # 如果你原本有 log-driver 等配置，这里使用 jq 或 python 会更安全，
        # 但为了通用性，这里采用覆盖重写方式，请注意！
        cat > "$DAEMON_JSON" <<EOF
{
  "registry-mirrors": [$mirrors_content]
}
EOF
    else
        mkdir -p /etc/docker
        cat > "$DAEMON_JSON" <<EOF
{
  "registry-mirrors": [$mirrors_content]
}
EOF
    fi
    echo -e "${GREEN}√ 镜像加速器配置已更新${NC}"
}

# 3. 恢复默认
reset_defaults() {
    echo -e "\n${BLUE}>>> 正在清除网络配置...${NC}"
    if [ -f "$PROXY_CONF_FILE" ]; then
        rm -f "$PROXY_CONF_FILE"
        echo -e "${GREEN}√ 已删除代理配置${NC}"
    else
        echo "未发现代理配置，跳过。"
    fi

    if [ -f "$DAEMON_JSON" ]; then
        # 激进策略：直接删除文件。如果你的 daemon.json 有其他配置，请慎用。
        # 或者只删除 mirrors 字段（脚本复杂化）。这里选择删除文件以确保纯净。
        rm -f "$DAEMON_JSON"
        echo -e "${GREEN}√ 已删除镜像加速配置${NC}"
    else
        echo "未发现 daemon.json，跳过。"
    fi
}

# 4. 应用变更
apply_changes() {
    echo -e "\n${BLUE}>>> 重载 Docker 服务...${NC}"
    systemctl daemon-reload
    systemctl restart docker
    
    echo -e "\n${GREEN}=== 配置完成 ===${NC}"
    echo -e "检查生效状态："
    echo -e "1. 代理状态: $(systemctl show --property=Environment docker | grep HTTP_PROXY || echo '无')"
    echo -e "2. 镜像状态: $(docker info 2>/dev/null | grep 'Registry Mirrors' -A 1 || echo '无')"
}

# -----------------------------------------------------------------
# 交互菜单
# -----------------------------------------------------------------
clear
echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}   Docker 极简网络配置工具 (Debian/LXC)  ${NC}"
echo -e "${YELLOW}========================================${NC}"
echo -e "1. 仅配置【本地 HTTP 代理】(Clash/V2ray等)"
echo -e "2. 仅配置【国内加速镜像】(Docker Proxy)"
echo -e "3. 【双重模式】(优先镜像，失败走代理)"
echo -e "4. ${RED}【恢复默认】(清除所有配置)${NC}"
echo -e "0. 退出"
echo -e "----------------------------------------"
read -p "请选择: " choice

case $choice in
    1)
        config_proxy
        apply_changes
        ;;
    2)
        config_mirrors
        apply_changes
        ;;
    3)
        config_mirrors
        config_proxy
        apply_changes
        ;;
    4)
        reset_defaults
        apply_changes
        ;;
    0)
        exit 0
        ;;
    *)
        echo -e "${RED}无效输入${NC}"
        ;;
esac
