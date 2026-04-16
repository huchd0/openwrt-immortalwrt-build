#!/bin/bash

# =========================================================
# 0. 云端预处理：预下载 OpenClash 核心 (修正版本与命名)
# =========================================================
mkdir -p files/etc/openclash/core
if [ "$APP_OPENCLASH" = "true" ]; then
    echo ">>> 正在下载 OpenClash Meta 核心 (amd64)..."
    CORE_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64.tar.gz"
    curl -sL --retry 3 "$CORE_URL" -o meta.tar.gz
    if tar -tzf meta.tar.gz >/dev/null 2>&1; then
        tar -zxf meta.tar.gz
        mv clash files/etc/openclash/core/clash_meta
        chmod +x files/etc/openclash/core/clash_meta
        rm -f meta.tar.gz
    fi
fi

# =========================================================
# 1. 准备初始化脚本
# =========================================================
mkdir -p files/etc/uci-defaults
DYNAMIC_SCRIPT="files/etc/uci-defaults/99-dynamic-settings"
echo "#!/bin/sh" > $DYNAMIC_SCRIPT

# 基础软件包强化
BASE_PACKAGES="base-files block-mount default-settings-chn luci-i18n-base-zh-cn sgdisk parted e2fsprogs fdisk lsblk blkid tar"
BASE_PACKAGES="$BASE_PACKAGES luci-i18n-package-manager-zh-cn irqbalance htop curl wget-ssl kmod-vmxnet3"

# =========================================================
# 🌟 核心魔法：接口彻底隔离、安全扩容、数据保护挂载
# =========================================================
cat >> $DYNAMIC_SCRIPT << EOF
# --- 1. 彻底隔离 eth0 并重新构建网络 ---
INTERFACES=\$(ls /sys/class/net 2>/dev/null | grep -E '^eth|^enp|^eno' | sort)
ETH_COUNT=\$(echo "\$INTERFACES" | grep -c '^')

if [ "\$ETH_COUNT" -gt 0 ]; then
    FIRST_ETH=\$(echo "\$INTERFACES" | head -n 1)
    
    # 暴力清空默认网络配置，防止 eth0 冲突
    uci -q delete network.lan
    uci -q delete network.wan
    uci -q delete network.wan6
    uci -q delete network.br_lan
    
    # 重建 LAN 网桥设备
    uci set network.br_lan=device
    uci set network.br_lan.name='br-lan'
    uci set network.br_lan.type='bridge'
    
    # 绑定 LAN 接口
    uci set network.lan=interface
    uci set network.lan.proto='static'
    uci set network.lan.ipaddr='$CUSTOM_IP'
    uci set network.lan.netmask='255.255.255.0'
    uci set network.lan.device='br-lan'

    if [ "\$ETH_COUNT" -eq 1 ]; then
        # 单网口模式：把唯一的网口加入网桥
        uci add_list network.br_lan.ports="\$FIRST_ETH"
    else
        # 多网口模式：eth0 锁定为 WAN，其余加入 LAN
        uci set network.wan=interface
        uci set network.wan.proto='dhcp'
        uci set network.wan.device="\$FIRST_ETH"
        
        uci set network.wan6=interface
        uci set network.wan6.proto='dhcpv6'
        uci set network.wan6.device="\$FIRST_ETH"

        for eth in \$(echo "\$INTERFACES" | grep -v "^\$FIRST_ETH\$"); do
            uci add_list network.br_lan.ports="\$eth"
        done
    fi
    uci commit network
fi

# --- 2. 磁盘扩容 (sda2) 容错机制 ---
ROOT_DISK=\$(lsblk -d -n -o NAME | grep -E 'sda|nvme[0-9]n[0-9]' | head -n 1)
if [ -n "\$ROOT_DISK" ]; then
    DISK_DEV="/dev/\$ROOT_DISK"
    echo "\$ROOT_DISK" | grep -q "nvme" && P2="\${DISK_DEV}p2" && P3="\${DISK_DEV}p3" || P2="\${DISK_DEV}2" && P3="\${DISK_DEV}3"

    sgdisk -e \$DISK_DEV || true
    sync && sleep 2

    # 拉伸分区表
    parted -s \$DISK_DEV resizepart 2 ${ROOTFS_SIZE}MiB || true
    sync && sleep 2
    
    # 在线拉伸文件系统 (无需 e2fsck，防止中断)
    resize2fs \$P2 || true
    sync

    # --- 3. /opt 安全挂载 (不分区，不格式化) ---
    if [ -b "\$P3" ]; then
        P3_UUID=\$(blkid -s UUID -o value \$P3)
        if [ -n "\$P3_UUID" ]; then
            uci -q delete fstab.opt_mount || true
            uci set fstab.opt_mount='mount'
            uci set fstab.opt_mount.uuid="\$P3_UUID"
            uci set fstab.opt_mount.target='/opt'
            uci set fstab.opt_mount.fstype='ext4'
            uci set fstab.opt_mount.enabled='1'
            uci commit fstab
            
            mkdir -p /opt/collectd_rrd /opt/backup /opt/docker
            mount \$P3 /opt 2>/dev/null || true
            
            if mountpoint -q /opt; then
                [ ! -f /opt/backup/factory_config.tar.gz ] && tar -czf /opt/backup/factory_config.tar.gz /etc/config /etc/passwd /etc/shadow 2>/dev/null
                if [ -f /etc/config/statistics ]; then
                    uci set statistics.collectd.Datadir='/opt/collectd_rrd'
                    uci commit statistics
                fi
            fi
        fi
    fi
fi

# --- 4. 恢复出厂指令 ---
cat > /bin/restore-factory << 'RE'
#!/bin/sh
if [ -f /opt/backup/factory_config.tar.gz ]; then
    rm -rf /etc/config/*
    tar -xzf /opt/backup/factory_config.tar.gz -C /
    reboot
else
    echo "未发现备份文件，请检查 /opt 挂载。"
fi
RE
chmod +x /bin/restore-factory
EOF

# =========================================================
# 2. 插件组装
# =========================================================
[ "$THEME_ARGON" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-theme-argon"
[ "$APP_HOMEPROXY" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-homeproxy luci-i18n-homeproxy-zh-cn"
[ "$APP_OPENCLASH" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-openclash"
[ "$APP_KSMBD" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-ksmbd luci-i18n-ksmbd-zh-cn"
[ "$APP_STATISTICS" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-statistics luci-i18n-statistics-zh-cn collectd collectd-mod-cpu collectd-mod-interface collectd-mod-memory"
[ "$INCLUDE_DOCKER" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-dockerman luci-i18n-dockerman-zh-cn docker-compose"
[ "$KMOD_IGC" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES kmod-igc"

# =========================================================
# 4. 极限打包
# =========================================================
echo "uci commit" >> $DYNAMIC_SCRIPT
echo "exit 0" >> $DYNAMIC_SCRIPT
chmod +x $DYNAMIC_SCRIPT

sed -i "s/CONFIG_TARGET_ROOTFS_PARTSIZE=.*/CONFIG_TARGET_ROOTFS_PARTSIZE=1024/g" .config || echo "CONFIG_TARGET_ROOTFS_PARTSIZE=1024" >> .config
sed -i "s/CONFIG_TARGET_KERNEL_PARTSIZE=.*/CONFIG_TARGET_KERNEL_PARTSIZE=64/g" .config || echo "CONFIG_TARGET_KERNEL_PARTSIZE=64" >> .config

echo "CONFIG_TARGET_ROOTFS_EXT4FS=y" >> .config
echo "CONFIG_TARGET_ROOTFS_SQUASHFS=n" >> .config
echo "CONFIG_GRUB_IMAGES=n" >> .config
echo "CONFIG_ISO_IMAGES=n" >> .config

make image PROFILE="generic" PACKAGES="$BASE_PACKAGES" FILES="files"
