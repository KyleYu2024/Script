## 1. 微信转发服务 (Wxchat)
在 VPS 上一键安装微信转发容器，用于配置可信 IP

```bash
bash <(wget -qO- https://ghproxy.net/https://raw.githubusercontent.com/KyleYu2024/Script/main/install_wxchat.sh)
```
## 2. PVE LXC Docker 初始化模板
新建一个编号为 199 的 Proxmox VE LXC 容器，自动安装 Docker 环境并开启 IP 转发

```bash
bash <(wget -qO- https://ghproxy.net/https://raw.githubusercontent.com/KyleYu2024/Script/main/setup-lxc-docker.sh)
```

## 3. Linux 安装setproxy
制作setproxy，用于临时给Linux系统调用局域网内的http代理

```bash
bash <(wget -qO- https://ghproxy.net/https://raw.githubusercontent.com/KyleYu2024/Script/refs/heads/main/setproxy.sh)
```

## 4.Linux添加docker代理和加速镜像

```bash
bash <(wget -qO- https://ghproxy.net/https://raw.githubusercontent.com/KyleYu2024/Script/refs/heads/main/docker_pull_proxy.sh)
```

## 5.docker配置macvlan
配置macvlan，自启动，并且能让宿主机调用，网卡查询：ip route get 10.10.1.1 | grep dev，ip改成主路由的

```bash
bash <(wget -qO- https://ghproxy.net/https://raw.githubusercontent.com/KyleYu2024/Script/refs/heads/main/macvlan_setup.sh)
```
