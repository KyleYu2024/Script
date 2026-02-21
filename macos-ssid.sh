#!/bin/bash

# ============================================================
# macOS WiFi 静态IP/DNS 自动切换工具 (支持多 SSID)
# ============================================================

# 1. 定义文件路径
WORK_DIR="$HOME/.local/bin"
CONF_FILE="$HOME/.wifi_configs"
AGENT_PLIST="$HOME/Library/LaunchAgents/com.user.wifi.switcher.plist"
SCRIPT_FILE="$WORK_DIR/wifi_switcher.sh"

echo "========================================"
echo "  🚀 开始安装 macOS WiFi 自动切换工具  "
echo "========================================"

# 2. 创建必要目录和文件
mkdir -p "$WORK_DIR"
touch "$CONF_FILE"

# 3. 交互式配置录入函数
add_config() {
    echo ""
    read -p "请输入要绑定静态配置的 WiFi 名称 (SSID): " ssid
    read -p "请输入静态 IP (例如 10.10.1.101): " ip
    read -p "请输入子网掩码 (默认 255.255.255.0，直接回车使用默认): " mask
    mask=${mask:-255.255.255.0}
    read -p "请输入网关/路由器地址 (例如 10.10.1.1): " router
    read -p "请输入 DNS (如 223.5.5.5，多个用空格隔开): " dns
    
    # 将配置以 SSID|IP|MASK|ROUTER|DNS 的格式写入文件
    echo "$ssid|$ip|$mask|$router|$dns" >> "$CONF_FILE"
    echo "✅ 成功添加配置: $ssid"
}

# 判断是否需要引导用户添加配置
if [ ! -s "$CONF_FILE" ]; then
    echo "检测到配置文件为空，请添加你的第一个专属网络配置："
    add_config
else
    echo "检测到已有配置文件 ($CONF_FILE)。"
    read -p "是否需要添加新的 WiFi 配置？(y/n，默认 n): " choice
    if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
        add_config
    fi
fi

# 4. 生成后台执行逻辑脚本 (核心)
cat << 'EOF' > "$SCRIPT_FILE"
#!/bin/bash

# 等待 3 秒确保 WiFi 连接状态已稳定更新
sleep 3

CONF_FILE="$HOME/.wifi_configs"
# 获取 Wi-Fi 网卡设备号 (通常是 en0)
WIFI_IF=$(networksetup -listallhardwareports | awk '/Hardware Port: Wi-Fi/{getline; print $2}')
# 获取当前连接的 SSID
CURRENT_SSID=$(networksetup -getairportnetwork "$WIFI_IF" | awk -F': ' '{print $2}')

# 如果没有连接任何 WiFi，直接退出
if [ -z "$CURRENT_SSID" ] || [[ "$CURRENT_SSID" == *"You are not associated"* ]]; then
    exit 0
fi

# 在配置文件中查找当前 SSID (精确匹配)
MATCH=$(grep "^$CURRENT_SSID|" "$CONF_FILE")

if [ -n "$MATCH" ]; then
    # 匹配成功，拆分参数
    IFS='|' read -r ssid ip mask router dns <<< "$MATCH"
    
    # 应用静态设置
    sudo networksetup -setmanual "$WIFI_IF" "$ip" "$mask" "$router"
    if [ -n "$dns" ]; then
        sudo networksetup -setdnsservers "$WIFI_IF" $dns
    fi
    # 发送系统通知
    osascript -e "display notification \"已应用静态网络配置 (DNS: $dns)\" with title \"WiFi 已切换至: $ssid\""
else
    # 匹配失败，恢复自动获取 (DHCP)
    sudo networksetup -setdhcp "$WIFI_IF"
    sudo networksetup -setdnsservers "$WIFI_IF" "Empty"
    # 可选：如果觉得每次连其他 WiFi 都通知太吵，可以把下面这行注释掉
    osascript -e "display notification \"已恢复 DHCP 自动获取\" with title \"WiFi 切换器: 未匹配网络\""
fi
EOF

# 赋予执行权限
chmod +x "$SCRIPT_FILE"

# 5. 生成 LaunchAgent 守护进程 (监听网络变化)
cat << EOF > "$AGENT_PLIST"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.wifi.switcher</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SCRIPT_FILE</string>
    </array>
    <key>WatchPaths</key>
    <array>
        <string>/Library/Preferences/SystemConfiguration/com.apple.airport.preferences.plist</string>
        <string>/Library/Preferences/SystemConfiguration/com.apple.wifi.message-tracer.plist</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF

# 6. 加载并启动守护进程
launchctl unload "$AGENT_PLIST" 2>/dev/null
launchctl load "$AGENT_PLIST"

# 7. 打印最终提示与免密设置教程
echo "========================================"
echo "🎉 安装与部署完成！"
echo "📂 配置文件路径: $CONF_FILE"
echo " (以后可直接用 nano ~/.wifi_configs 修改或添加配置)"
echo "----------------------------------------"
echo "⚠️ 【非常重要】最后一步：设置免密切换"
echo "由于修改 IP 需要管理员权限，为了让脚本在后台完全无感运行，请执行以下操作："
echo "1. 在终端输入命令并回车: sudo visudo"
echo "2. 按下方向键，滚到文件最末尾"
echo "3. 按下键盘上的 'i' 键进入编辑模式"
echo "4. 粘贴下面这行代码 (请把里面的 yourusername 换成你现在的电脑用户名 ${USER})："
echo ""
echo "${USER} ALL=(ALL) NOPASSWD: /usr/sbin/networksetup"
echo ""
echo "5. 按下 'esc' 键，然后输入 ':wq' 并回车保存即可。"
echo "========================================"
