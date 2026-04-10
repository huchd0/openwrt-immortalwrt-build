#!/bin/bash
set -e

# 1. 架构识别
case "$TARGET_ARCH" in
    *"x86-64"*)    CORE="amd64-compatible" ;;
    *"armv8"*|*"aarch64"*) CORE="arm64" ;;
    *"armv7"*)     CORE="armv7" ;;
    *"ramips"*)    CORE="mipsle-softfloat" ;;
    *"mips"*)      CORE="mips-softfloat" ;;
    *)             CORE="mipsle-softfloat" ;; 
esac

echo ">>> 架构: $TARGET_ARCH | 选用内核: $CORE <<<"

# 2. 准备目录 (修复 Device or resource busy)
# 不要 rm -rf files，而是清理其内部文件并重新创建子目录
find files -mindepth 1 -delete 2>/dev/null || true
mkdir -p files/root files/etc/uci-defaults files/etc/openclash/core

# 3. 下载 OpenClash APK
echo ">>> 正在获取 OpenClash APK..."
OC_URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases | grep "browser_download_url" | grep ".apk" | head -n 1 | cut -d '"' -f 4)

if [ -z "$OC_URL" ]; then
    echo "❌ 错误: 无法获取 OpenClash 下载链接"
    exit 1
fi

# 确保目标目录存在再下载
wget -qO files/root/luci-app-openclash.apk "$OC_URL"

# 4. 针对小容量设备的处理 (16MB Flash 必须跳过内核)
if [[ "$TARGET_ARCH" == *"ramips"* ]]; then
    echo ">>> 检测到 16MB 级别设备，跳过内核集成以确保构建成功 <<<"
else
    echo ">>> 正在下载 OpenClash 内核..."
    wget -qO- "https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-${CORE}.tar.gz" | tar -zxf - -C files/etc/openclash/core/
    mv files/etc/openclash/core/clash files/etc/openclash/core/clash_meta 2>/dev/null || true
    chmod +x files/etc/openclash/core/clash_meta 2>/dev/null || true
fi

# 5. 编写初始化脚本
cat << EOF > files/etc/uci-defaults/99-custom-setup
#!/bin/sh
uci set network.lan.ipaddr='$MANAGEMENT_IP'
uci set system.@system[0].hostname='ImmortalWrt'
uci commit system

# 修复软件源
sed -i 's/downloads.openwrt.org/mirrors.ustc.edu.cn\/openwrt/g' /etc/apk/repositories.d/*.list 2>/dev/null || true

# 安装插件
apk add -q --allow-untrusted /root/*.apk 2>/dev/null || true
rm -f /root/*.apk
rm -f /etc/uci-defaults/99-custom-setup
exit 0
EOF
chmod +x files/etc/uci-defaults/99-custom-setup

# 6. 定义软件包 (精简掉占用大的无用包)
# 1. 移除不必要的目录清理报错，改用更温和的方式
[ -d files ] && find files -mindepth 1 -delete

# ... (中间下载 APK 的代码保持不变) ...

# 2. 极致精简软件包列表
# 关键点：
# - 移除所有 IPv6 相关包 (节省约 1MB+)
# - 移除所有 USB 支持 (节省约 1.5MB+)
# - 移除所有统计和不常用工具
PKGS="-dnsmasq dnsmasq-full \
-ppp -ppp-mod-pppoe \
-ip6tables -odhcp6c -kmod-ipv6 -kmod-ipt-nat6 \
-kmod-usb-core -kmod-usb3 -kmod-usb-ledtrig-usbport \
-kmod-usb-storage -kmod-usb-storage-uas \
-kmod-fs-autofs4 -kmod-fs-msdos -kmod-fs-vfat \
-kmod-nft-offload -luci-app-statistics -luci-app-ttyd \
luci-app-openclash"

# 3. 执行构建
make image PROFILE="$DEVICE_PROFILE" PACKAGES="$PKGS" FILES="files"
