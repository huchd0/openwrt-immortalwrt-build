#!/bin/bash
# 查询固件是否在这存在：https://hub.docker.com/r/immortalwrt/imagebuilder/tags
# 界面填写 设备架构arch，如：ASUS 4G-AX56 使用的是 Mediatek MT7621 芯片，所以你的 arch 应该填 ramips-mt7621。
# 界面填写 设备Profile，如：afoundry_ew1200，查询方式--->>>禁用执行构建后，临时使本页代码最后一行生效运行。
#!/bin/bash
# 开启严谨模式
set -e

# 1. 自动识别架构
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

# 3. 下载插件
echo ">>> 正在获取 OpenClash APK..."
OC_APK=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases | jq -r '.assets[] | select(.name | endswith(".apk")) | .browser_download_url' | head -n 1)
wget -qO files/root/luci-app-openclash.apk "$OC_APK"

# 【核心修复】针对小容量设备的处理逻辑
# 如果是 ramips (通常是16MB Flash)，跳过内核下载，防止 Image too big
if [[ "$TARGET_ARCH" == *"ramips"* ]]; then
    echo ">>> 检测到嵌入式架构，跳过内核预装以节省空间。请在刷机后手动上传内核。 <<<"
else
    echo ">>> 正在下载 OpenClash 内核..."
    wget -qO- "https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-${CORE}.tar.gz" | tar -zxf - -C files/etc/openclash/core/
    mv files/etc/openclash/core/clash files/etc/openclash/core/clash_meta 2>/dev/null || true
    chmod +x files/etc/openclash/core/clash_meta 2>/dev/null || true
fi

# 4. 编写初始化脚本
cat << EOF > files/etc/uci-defaults/99-custom-setup
#!/bin/sh
# 设置 IP 和 主机名
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

# 5. 定义软件包
# 如果编译报错说固件太大，会出现 "Image too big" 错误，就去 make info 里找那些 kmod- 开头的驱动包
# 把不用的（比如蓝牙驱动、USB 驱动）统统加个 - 减掉
# 不要减掉 luci字样的核心包
# 使用反斜杠拼接，确保 -dnsmasq 后面紧跟需要剔除的包
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

# 6. 执行构建
# 注意：如果要查询 Profile，请将下面这一行改为 make info
make image PROFILE="$DEVICE_PROFILE" PACKAGES="$PKGS" FILES="files"

# 禁掉上面的执行构建语句，执行下面语句make info，第四步Run Builder的时候，
# 中间有一行Available Profiles:下面，有很多路由器信息块，
# 第一行冒號左側的字符串（例如 xiaomi_mi-router-4g）就是界面中要填入 device_profile 輸入框的值
# make info
