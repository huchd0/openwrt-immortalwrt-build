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

# 2. 准备目录
rm -rf files && mkdir -p files/root files/etc/uci-defaults files/etc/openclash/core

# 3. 下载 OpenClash APK (使用不依赖 jq 的方式)
echo ">>> 正在获取 OpenClash APK..."
# 通过 grep 和 cut 强行提取第一个 .apk 的下载地址
OC_URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases | grep "browser_download_url" | grep ".apk" | head -n 1 | cut -d '"' -f 4)

if [ -z "$OC_URL" ]; then
    echo "❌ 无法获取 OpenClash 下载链接，请检查网络或 GitHub API 限制"
    exit 1
fi

wget -qO files/root/luci-app-openclash.apk "$OC_URL"

# 4. 针对小容量设备的处理逻辑
if [[ "$TARGET_ARCH" == *"ramips"* ]]; then
    echo ">>> 检测到嵌入式小内存架构，跳过内核预装以防止固件超大。 <<<"
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
rm -f /root/*.apk /etc/uci-defaults/99-custom-setup
exit 0
EOF
chmod +x files/etc/uci-defaults/99-custom-setup

# 6. 定义软件包 (针对 16MB Flash 极致精简)
# 移除了所有不需要的 USB、拨号、统计插件
PKGS="-dnsmasq dnsmasq-full \
-ppp -ppp-mod-pppoe \
-kmod-usb-core -kmod-usb3 -kmod-usb-ledtrig-usbport \
-kmod-usb-storage -kmod-usb-storage-uas \
-kmod-fs-autofs4 -kmod-fs-msdos -kmod-fs-vfat \
-kmod-nft-offload \
-luci-app-statistics \
luci-app-openclash \
luci-app-ttyd \
luci-i18n-ttyd-zh-cn"

# 7. 执行构建
# make image PROFILE="$DEVICE_PROFILE" PACKAGES="$PKGS" FILES="files"
make info 用这个更改
