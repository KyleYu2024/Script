#!/bin/bash

# 定义颜色输出
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== 开始检查 Docker 环境 ===${NC}"

# 1. 判断系统是否有 Docker 环境
if ! command -v docker &> /dev/null; then
    echo -e "${YELLOW}未检测到 Docker，正在自动安装...${NC}"
    
    # 使用官方脚本自动安装 Docker
    if curl -fsSL https://get.docker.com | bash; then
        echo -e "${GREEN}Docker 安装成功！${NC}"
        # 尝试启动 Docker 并设置开机自启
        systemctl enable --now docker
    else
        echo -e "\033[0;31mDocker 安装失败，请检查网络或系统源。${NC}"
        exit 1
    fi
else
    echo -e "${GREEN}检测到 Docker 已安装，跳过安装步骤。${NC}"
fi

echo -e "${GREEN}=== 配置容器参数 ===${NC}"

# 2. 提示输入端口号 (默认 52534)
read -p "请输入宿主机端口号 (默认: 52534，直接回车使用默认值): " input_port

# 如果输入为空，则使用默认值
HOST_PORT=${input_port:-52534}

echo -e "将使用端口: ${GREEN}${HOST_PORT}${NC}"

# 3. 安装并启动容器
echo -e "${GREEN}=== 正在启动容器 wxchat ===${NC}"

# 检查是否已有同名容器，如果有则停止并删除，防止冲突报错
if [ "$(docker ps -aq -f name=wxchat)" ]; then
    echo -e "${YELLOW}发现同名容器，正在停止并删除旧容器...${NC}"
    docker stop wxchat >/dev/null 2>&1
    docker rm wxchat >/dev/null 2>&1
fi

# 执行 Docker 命令
docker run -d \
    --name wxchat \
    --restart=always \
    -p "${HOST_PORT}:80" \
    ddsderek/wxchat:latest

# 4. 检查结果
if [ $? -eq 0 ]; then
    echo -e "${GREEN}=== 安装完成！ ===${NC}"
    echo -e "容器状态: 已启动"
    echo -e "访问端口: ${HOST_PORT}"
else
    echo -e "\033[0;31m容器启动失败，请检查报错信息。${NC}"
fi
