## 1. 微信转发服务 (Wxchat)
在 VPS 上一键安装微信转发容器，用于配置可信 IP。

```bash
bash <(curl -sL [https://ghproxy.net/https://raw.githubusercontent.com/KyleYu2024/Script/main/wxchat.sh](https://ghproxy.net/https://raw.githubusercontent.com/KyleYu2024/Script/main/wxchat.sh))
```
## 2. PVE LXC Docker 初始化模板
新建一个编号为 199 的 Proxmox VE LXC 容器，自动安装 Docker 环境并开启 IP 转发。

```bash
bash <(curl -sL [https://ghproxy.net/https://raw.githubusercontent.com/KyleYu2024/Script/main/setup-lxc-docker.sh](https://ghproxy.net/https://raw.githubusercontent.com/KyleYu2024/Script/main/setup-lxc-docker.sh))
```

## 3. mihomo裸核安装（Linux/lxc）

```bash
bash <(curl -sL [https://ghproxy.net/https://raw.githubusercontent.com/KyleYu2024/Script/main/setup-mihomo-core-only.sh](https://ghproxy.net/https://raw.githubusercontent.com/KyleYu2024/Script/main/setup-mihomo-core-only.sh))
```
