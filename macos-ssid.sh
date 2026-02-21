#!/bin/bash

# ============================================================
# macOS WiFi 静态IP/DNS 自动切换工具 (终极版)
# 特性: 自动免密配置、绕过最新macOS定位权限抓取SSID
# ============================================================

WORK_DIR="$HOME/.local/bin"
CONF_FILE="$HOME/.wifi_configs"
AGENT_PLIST="$HOME/Library/LaunchAgents/com.user.wifi.switcher.plist"
SCRIPT_FILE="$WORK_DIR/wifi_switcher.sh"

echo "================================================="
echo "  🚀 开始安装 macOS WiFi 自动切换工具 (终极版)  "
echo "================================================="

# 1. 自动配置后台免密权限 (替代手动 visudo)
echo "正在配置后台静默切换权限..."
echo "⚠️ 请输入你的 Mac 开机密码 (输入时屏幕不显示，输完回车即可):"
# 将免密规则安全地写入 sudoers.d 独立文件夹，不污染原系统文件
echo "$USER ALL=(ALL) NOPASSWD: /usr/sbin/networksetup" | sudo tee "/etc/sudoers.d/wifi_switcher_$USER" > /dev/null
sudo chmod 440 "/etc/sudoers.d/wifi_switcher_$USER"
echo "✅ 免密权限配置成功！"

# 2. 创建必要目录和文件
mkdir -p "$WORK_DIR"
touch "$CONF_FILE"

# 3. 交互式配置录入
add_config() {
    echo "-------------------------------------------------"
    read -p "请输入要绑定静态配置的 WiFi 名称 (SSID): " ssid
    read -p "请输入静态 IP (例如 10.10.1.155): " ip
    read -p "请输入子网掩码 (默认 255.255.255.0，直接回车使用默认): " mask
    mask=${mask:-255.255.255.0}
    read -p "请输入网关/路由器地址 (例如 10.10.1.1): " router
    read -p "请输入 DNS (如 127.0.0.1，多个用空格隔开): " dns
    
    # 覆盖或追加配置
    grep -v "^$ssid|" "$CONF_FILE" > "${CONF_FILE}.tmp" && mv "${CONF_FILE}.tmp" "$CONF_FILE"
    echo "$ssid|$ip|$mask|$router|$dns" >> "$CONF_FILE"
    echo "✅ 成功保存网络配置: $ssid"
}

if [ ! -s "$CONF_FILE" ]; then
    echo "检测到你还没有配置网络，请添加你的 mosdns 环境："
    add_config
else
    echo "-------------------------------------------------"
    echo "检测到已有配置文件 ($CONF_FILE)。"
    read -p "是否需要覆盖/添加新的 WiFi 配置？(y/n，默认 n): " choice
    if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
        add_config
    fi
fi

# 4. 生成后台执行逻辑脚本 (核心)
cat << 'EOF' > "$SCRIPT_FILE"
#!/bin/bash

# 延迟3秒，等网络握手完成
sleep 3

CONF_FILE="$HOME/.wifi_configs"
WIFI_IF="en0" # 强制锁定 Mac Wi-Fi 网卡

# [绝招] 使用 system_profiler 绕过定位权限抓取 SSID，稳如老狗
CURRENT_SSID=$(system_profiler SPAirPortDataType 2>/dev/null | awk -F': ' '/Current Network Information:/{getline; print $1}' | sed 's/^[ \t]*//')

# 如果实在没抓到，直接退出
if [ -z "$CURRENT_SSID" ]; then
    exit 0
fi

# 在配置文件中精确查找当前 SSID
MATCH=$(grep "^$CURRENT_SSID|" "$CONF_FILE")

if [ -n "$MATCH" ]; then
    IFS='|' read -r ssid ip mask router dns <<< "$MATCH"
    
    # 应用静态设置 (因为配置了免密，这里 sudo 不会卡住)
    sudo networksetup -setmanual "$WIFI_IF" "$ip" "$mask" "$router"
    if [ -n "$dns" ]; then
        sudo networksetup -setdnsservers "$WIFI_IF" $dns
    fi
    osascript -e "display notification \"已切换至静态IP (DNS: $dns)\" with title \"WiFi: $ssid\""
else
    # 恢复 DHCP 自动获取
    sudo networksetup -setdhcp "$WIFI_IF"
    sudo networksetup -setdnsservers "$WIFI_IF" "Empty"
    # osascript -e "display notification \"已恢复自动获取 IP 和 DNS\" with title \"WiFi: $CURRENT_SSID\""
fi
EOF

chmod +x "$SCRIPT_FILE"

# 5. 生成守护进程
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

# 6. 重启服务
launchctl unload "$AGENT_PLIST" 2>/dev/null
launchctl load "$AGENT_PLIST"

echo "================================================="
echo "🎉 终极版部署完成！"
echo "✅ 现在后台会自动监听 WiFi 变化，完全无感切换。"
echo "📝 若想查看或修改配置表，可随时运行: cat ~/.wifi_configs"
echo "================================================="
# 立即触发一次检测
bash "$SCRIPT_FILE" &
