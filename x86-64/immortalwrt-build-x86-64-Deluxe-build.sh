#!/bin/bash
set -e

# 接收环境变量
ROOTFS_SIZE=${ROOTFS_SIZE:-1024}
MANAGEMENT_IP=${MANAGEMENT_IP:-192.168.100.1}

echo ">>> 1. 固件底层参数 <<<"
{
    echo "CONFIG_TARGET_KERNEL_PARTSIZE=64"
    echo "CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_SIZE"
    echo "CONFIG_TARGET_ROOTFS_EXT4FS=n"
    echo "CONFIG_TARGET_ROOTFS_TARGZ=n"
    echo "CONFIG_GRUB_IMAGES=n"
} >> .config

echo ">>> 2. 准备组件与驱动 (编译时注入) <<<"
mkdir -p files/etc/uci-defaults files/etc/init.d files/etc/openclash/core files/lib/firmware/mediatek/mt7925

# 预下载驱动和内核 (这些文件大且重要，建议编译时放入)
( wget -qO- "https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-compatible.tar.gz" | tar xOvz > files/etc/openclash/core/clash_meta && chmod +x files/etc/openclash/core/clash_meta ) &
( wget -qO files/lib/firmware/mediatek/mt7925/WIFI_RAM_CODE_MT7925_1_1.bin "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/mediatek/mt7925/WIFI_RAM_CODE_MT7925_1_1.bin" ) &
wait

echo ">>> 3. 创建开机自动安装服务 (直到成功为止) <<<"
# 创建后台安装脚本
cat << 'EOF' > files/etc/auto_install.sh
#!/bin/sh

# 检查网络是否通畅
check_network() {
    ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1
}

# 延迟等待网络拨号
sleep 10

if check_network; then
    echo "网络已就绪，开始后台增量安装..."
    apk update
    
    # 在线安装剩余的大型插件
    # 你可以在这里继续添加你想在后台偷偷装的包
    apk add luci-app-openclash \
            dockerd docker-compose luci-app-dockerman \
            kmod-mt7925e kmod-mt7925-firmware kmod-btusb wpad-openssl
    
    if [ $? -eq 0 ]; then
        echo "安装成功，迁移 Docker 数据目录..."
        mkdir -p /mnt/sda3/docker
        uci set dockerd.globals.data_root='/mnt/sda3/docker'
        uci commit dockerd
        
        # 任务完成，删除自启动服务
        rm -f /etc/init.d/auto_install
        /etc/init.d/auto_install disable
        rm -f /etc/auto_install.sh
        echo "所有增量包安装完毕，脚本已自毁。"
    fi
else
    echo "当前无网络，等待下次开机尝试..."
fi
EOF
chmod +x files/etc/auto_install.sh

# 创建自启动服务文件
cat << 'EOF' > files/etc/init.d/auto_install
#!/bin/sh /etc/rc.common
START=99
start() {
    /etc/auto_install.sh &
}
EOF
chmod +x files/etc/init.d/auto_install

echo ">>> 4. 编写基础初始化脚本 <<<"
cat << EOF > files/etc/uci-defaults/99-custom-setup
#!/bin/sh
uci set network.lan.ipaddr='$MANAGEMENT_IP'
uci set system.@system[0].hostname='Tanxm'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci commit system

# 基础磁盘分区
if ! lsblk | grep -q sda3; then
    echo -e "n\n3\n\n\nw" | fdisk /dev/sda >/dev/null 2>&1
    partprobe /dev/sda >/dev/null 2>&1 || true
    sleep 2
    mkfs.ext4 -F /dev/sda3 >/dev/null 2>&1
fi

# 激活基础 UI
uci set luci.main.mediaurlbase='/luci-static/argon'
uci commit luci

# 启用后台安装服务
/etc/init.d/auto_install enable

rm -f /etc/uci-defaults/99-custom-setup
exit 0
EOF

echo ">>> 5. 软件列表 (编译时安装的基础包) <<<"
# 这些包会在构建时直接打入固件，保证开机即用
PACKAGES="base-files libc libgcc apk-openssl block-mount fdisk e2fsprogs kmod-fs-ext4 bash curl jq htop \
luci-theme-argon luci-app-argon-config \
luci-i18n-package-manager-zh-cn \
luci-i18n-ttyd-zh-cn \
luci-i18n-samba4-zh-cn \
luci-i18n-base-zh-cn luci-i18n-firewall-zh-cn"

# 官方源提速黑科技
if [ -f "repositories.conf" ]; then
    sed -i 's/https:\/\//http:\/\//g' repositories.conf
    echo "104.21.75.148 downloads.immortalwrt.org" >> /etc/hosts
fi

echo ">>> 6. 开始打包 <<<"
make image -j$(nproc) PROFILE="generic" PACKAGES="$PACKAGES" FILES="files" EXTRA_IMAGE_NAME="efi-J4125"

echo ">>> 7. 提取固件 <<<"
find bin/targets/x86/64/ -type f -not -name "*combined-efi*.img.gz" -not -name "*sha256sums" -delete
