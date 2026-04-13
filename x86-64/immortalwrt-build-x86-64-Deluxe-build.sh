#!/bin/bash
set -e

# 接收环境变量
ROOTFS_SIZE=${ROOTFS_SIZE:-1024}
MANAGEMENT_IP=${MANAGEMENT_IP:-192.168.100.1}

echo ">>> 1. 固件底层参数配置 <<<"
{
    echo "CONFIG_TARGET_KERNEL_PARTSIZE=64"
    echo "CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_SIZE"
    echo "CONFIG_TARGET_ROOTFS_EXT4FS=n"
    echo "CONFIG_TARGET_ROOTFS_TARGZ=n"
    echo "CONFIG_GRUB_IMAGES=n"
} >> .config

echo ">>> 2. 准备组件目录 <<<"
mkdir -p files/etc/uci-defaults files/etc/init.d files/etc/openclash/core

# 预载 OpenClash Meta 内核 (直连下载)
wget -qO- "https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-compatible.tar.gz" | tar xOvz > files/etc/openclash/core/clash_meta
chmod +x files/etc/openclash/core/clash_meta

echo ">>> 3. 创建开机后台增量安装脚本 <<<"
cat << 'EOF' > files/etc/auto_install.sh
#!/bin/sh
check_net() { ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; }
sleep 15
if check_net; then
    apk update
    # 将最重的包移到开机后安装
    apk add luci-app-openclash luci-i18n-homeproxy-zh-cn \
            dockerd docker-compose luci-app-dockerman \
            kmod-mt7925e kmod-mt7925-firmware kmod-btusb wpad-openssl
    if [ $? -eq 0 ]; then
        mkdir -p /mnt/sda3/docker
        uci set dockerd.globals.data_root='/mnt/sda3/docker'
        uci commit dockerd
        /etc/init.d/auto_install disable
        rm -f /etc/init.d/auto_install /etc/auto_install.sh
    fi
fi
EOF
chmod +x files/etc/auto_install.sh

cat << 'EOF' > files/etc/init.d/auto_install
#!/bin/sh /etc/rc.common
START=99
start() { /etc/auto_install.sh & }
EOF
chmod +x files/etc/init.d/auto_install

echo ">>> 4. 编写基础初始化 <<<"
cat << EOF > files/etc/uci-defaults/99-custom-setup
#!/bin/sh
uci set network.lan.ipaddr='$MANAGEMENT_IP'
uci set system.@system[0].hostname='Tanxm'
uci commit system
if ! lsblk | grep -q sda3; then
    echo -e "n\n3\n\n\nw" | fdisk /dev/sda >/dev/null 2>&1
    partprobe /dev/sda >/dev/null 2>&1 || true
    sleep 2
    mkfs.ext4 -F /dev/sda3 >/dev/null 2>&1
fi
uci set luci.main.mediaurlbase='/luci-static/argon'
uci commit luci
/etc/init.d/auto_install enable
rm -f /etc/uci-defaults/99-custom-setup
exit 0
EOF

echo ">>> 5. 软件列表 (极简基础版) <<<"
# 排除所有多余 kmod 驱动，减轻依赖计算负担
PACKAGES="base-files libc libgcc apk-openssl block-mount fdisk e2fsprogs kmod-fs-ext4 \
bash curl jq htop luci-theme-argon luci-i18n-package-manager-zh-cn luci-i18n-ttyd-zh-cn \
luci-i18n-base-zh-cn luci-i18n-firewall-zh-cn luci-i18n-samba4-zh-cn \
kmod-igc kmod-r8125 kmod-r8169 -kmod-amazon-ena -kmod-bnx2 -kmod-i40e -kmod-ixgbe -kmod-tg3 -kmod-vmxnet3"

# --- 🚨 暴力核心：物理删除冗余包文件，让索引秒开 🚨 ---
# ImageBuilder 默认带了 3000 多个包，这是卡住 120 秒的根本原因
BASE_PKG_DIR="bin/packages/x86_64/base"
if [ -d "$BASE_PKG_DIR" ]; then
    echo ">>> 5.5 [物理清场] 正在删除冗余驱动包以加速索引..."
    cd "$BASE_PKG_DIR"
    # 物理删除所有 kmod 包，但保留你 J4125 必需的驱动
    find . -name "kmod-*" ! -name "*igc*" ! -name "*r8125*" ! -name "*r8169*" ! -name "*fs-ext4*" -delete 2>/dev/null || true
    cd ../../../..
fi

# 提速配置 (HTTP 降级避开握手风暴)
if [ -f "repositories.conf" ]; then
    sed -i 's/https:\/\//http:\/\//g' repositories.conf
    echo "104.21.75.148 downloads.immortalwrt.org" >> /etc/hosts
fi
echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf 2>/dev/null || true

echo ">>> 6. 开始打包 <<<"
make image -j$(nproc) PROFILE="generic" PACKAGES="$PACKAGES" FILES="files" EXTRA_IMAGE_NAME="efi-J4125"

echo ">>> 7. 提取固件 <<<"
find bin/targets/x86/64/ -type f -not -name "*combined-efi*.img.gz" -not -name "*sha256sums" -delete
