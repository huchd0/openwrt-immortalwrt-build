#!/bin/bash
set -e 

echo "========================================================="
echo "🕒 [$(date '+%Y-%m-%d %H:%M:%S')] 开始构建固件..."
echo "📦 固件大小: $PROFILE MB"
echo "========================================================="

# 读取外部自定义包配置
if [ -f "shell/custom-packages.sh" ]; then
    source shell/custom-packages.sh
fi

# ================= 配置首次开机初始化脚本 =================
echo "🔧 生成开机初始化脚本 (LAN IP设置)..."
mkdir -p /home/build/immortalwrt/files/etc/uci-defaults

cat << EOF > /home/build/immortalwrt/files/etc/uci-defaults/99-init-settings
#!/bin/sh
# 配置 LAN 口 IP
uci set network.lan.ipaddr='$CUSTOM_ROUTER_IP'
uci commit network

# 脚本执行完毕后自动删除
rm -f /etc/uci-defaults/99-init-settings
exit 0
EOF

chmod +x /home/build/immortalwrt/files/etc/uci-defaults/99-init-settings


# ================= 插件组合 =================
# 基础包与系统工具
PACKAGES="curl wget luci-i18n-diskman-zh-cn luci-i18n-filemanager-zh-cn luci-i18n-package-manager-zh-cn luci-i18n-ttyd-zh-cn openssh-sftp-server"
# 主题与外观
PACKAGES="$PACKAGES luci-theme-argon luci-app-argon-config luci-i18n-argon-config-zh-cn"
# 网络与防火墙
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
# 科学上网相关
PACKAGES="$PACKAGES xray-core hysteria luci-i18n-passwall-zh-cn luci-app-openclash luci-i18n-homeproxy-zh-cn"
# 合并自定义包
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"


# ================= 下载 OpenClash 核心 =================
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "⬇️ 检测到 OpenClash，正在预下载 Meta 内核及 Geo 数据..."
    mkdir -p files/etc/openclash/core
    
    META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-compatible.tar.gz"
    if wget -q --show-progress -O- "$META_URL" | tar xOvz > files/etc/openclash/core/clash_meta; then
        chmod +x files/etc/openclash/core/clash_meta
        echo "✅ Meta 核心下载完成"
    else
        echo "⚠️ Meta 核心下载失败，不影响固件编译，但后续需手动更新核心。"
    fi

    wget -q --show-progress https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -O files/etc/openclash/GeoIP.dat || true
    wget -q --show-progress https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O files/etc/openclash/GeoSite.dat || true
fi

# ================= 开始执行 ImageBuilder =================
echo "🛠️ 正在打包镜像，包含以下组件:"
echo "$PACKAGES"

make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files" ROOTFS_PARTSIZE=$PROFILE

echo "🎉 [$(date '+%Y-%m-%d %H:%M:%S')] 固件构建成功完成！"
