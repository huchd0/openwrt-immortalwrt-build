#!/bin/bash
# 查询固件是否在这存在：https://hub.docker.com/r/immortalwrt/imagebuilder/tags
# 界面填写 设备架构arch，如：ramips-mt7621
# 界面填写 设备Profile，如：afoundry_ew1200，查询方式临时使本页代码最后一行生效运行，禁用执行构建。

注：ASUS 4G-AX56 使用的是 Mediatek MT7621 芯片，所以你的 arch 应该填 ramips-mt7621。

填写 Profile：
在 device_profile 输入框填入：asus_4g-ax56。
set -e

# 1. 自动识别架构下载 OpenClash 内核
case "$TARGET_ARCH" in
    *"x86-64"*)    CORE="amd64-compatible" ;;
    *"armv8"*|*"aarch64"*) CORE="arm64" ;;
    *"armv7"*)     CORE="armv7" ;;
    *"ramips"*)    CORE="mipsle-softfloat" ;;
    *"mips"*)      CORE="mips-softfloat" ;;
    *)             CORE="arm64" ;; # 默认
esac

echo ">>> 架构: $TARGET_ARCH | 选用内核: $CORE <<<"

# 2. 准备目录
mkdir -p files/root files/etc/uci-defaults files/etc/openclash/core

# 3. 下载插件
# 下载 OpenClash APK
OC_APK=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases | grep -m 1 "browser_download_url.*\.apk" | cut -d '"' -f 4)
wget -qO files/root/luci-app-openclash.apk "$OC_APK"

# 下载对应内核
wget -qO- "https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-${CORE}.tar.gz" | tar -zxf - -C files/etc/openclash/core/
mv files/etc/openclash/core/clash files/etc/openclash/core/clash_meta 2>/dev/null || true
chmod +x files/etc/openclash/core/clash_meta 2>/dev/null || true

# 4. 编写初始化脚本 (极其简洁)
cat << EOF > files/etc/uci-defaults/99-custom-setup
#!/bin/sh
# 设置 IP 和 主机名
uci set network.lan.ipaddr='$MANAGEMENT_IP'
uci set system.@system[0].hostname='ImmortalWrt'
uci commit system

# 修复软件源
sed -i 's/downloads.openwrt.org/mirrors.ustc.edu.cn\/openwrt/g' /etc/apk/repositories.d/*.list 2>/dev/null || true

# 安装插件
apk add -q --allow-untrusted /root/*.apk
rm -f /root/*.apk /etc/uci-defaults/99-custom-setup
exit 0
EOF
chmod +x files/etc/uci-defaults/99-custom-setup

# 5. 定义软件包
# 如果编译报错说固件太大，会出现 "Image too big" 错误，就去 make info 里找那些 kmod- 开头的驱动包
# 把不用的（比如蓝牙驱动、USB 驱动）统统加个 - 减掉
# 不要减掉 luci字样的核心包
PKGS="-dnsmasq \
luci luci-base luci-compat luci-i18n-base-zh-cn luci-i18n-firewall-zh-cn \
bash jq curl ca-bundle luci-app-ttyd luci-i18n-ttyd-zh-cn \
luci-app-statistics luci-i18n-statistics-zh-cn \
coreutils-nohup block-mount kmod-fs-ext4"

# 6. 执行构建
make image PROFILE="$DEVICE_PROFILE" PACKAGES="$PKGS" FILES="files"

# 禁掉上面的执行构建语句，执行下面语句make info，第四步Run Builder的时候，
#中间有一行Available Profiles:下面，有很多路由器信息块，
#第一行冒號左側的字符串（例如 xiaomi_mi-router-4g）就是界面中要填入 device_profile 輸入框的值
# make info
