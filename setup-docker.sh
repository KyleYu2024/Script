#!/bin/bash

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # 恢复默认颜色

echo -e "${GREEN}=== Docker Compose 一键部署脚本 ===${NC}"

# 1. 提示用户输入安装路径，支持回车默认当前目录
read -p "请输入安装路径 [直接回车默认当前目录]: " install_path

# 如果用户未输入任何内容（直接回车），则使用当前目录
if [ -z "$install_path" ]; then
  install_path="$PWD"
  echo -e "${YELLOW}未输入路径，默认使用当前目录: $install_path${NC}"
fi

# 创建并进入目录
mkdir -p "$install_path"
echo -e "${GREEN}已准备使用目录: $install_path${NC}"

# 2. 接收多行 docker-compose.yaml 内容
yaml_file="$install_path/docker-compose.yaml"

echo -e "${YELLOW}请输入 docker-compose.yaml 的内容。${NC}"
echo -e "${YELLOW}(粘贴全部内容后，请在新的一行手动输入 EOF 并按回车键结束)：${NC}"

# 清空或创建文件
> "$yaml_file"

# 读取用户输入直到遇到 EOF
while IFS= read -r line; do
    if [[ "$line" == "EOF" ]]; then
        break
    fi
    echo "$line" >> "$yaml_file"
done

echo -e "${GREEN}配置文件已成功保存至 $yaml_file${NC}"

# 3. 执行安装/启动命令
cd "$install_path" || { echo -e "${RED}无法进入目录 $install_path${NC}"; exit 1; }

echo -e "${GREEN}正在启动 Docker 容器...${NC}"

# 检查 docker compose (V2) 或 docker-compose (V1) 并运行
if docker compose version >/dev/null 2>&1; then
    docker compose up -d
elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose up -d
else
    echo -e "${RED}错误: 未检测到 Docker Compose。请先安装 Docker 环境！${NC}"
    exit 1
fi

echo -e "${GREEN}部署完成！容器已在后台运行。${NC}"
