#!/bin/bash

# =========================================================
# 0. 云端预处理：预下载 OpenClash 核心 (修正下载链接与解压逻辑)
# =========================================================
mkdir -p files/etc/openclash/core
if [ "$APP_OPENCLASH" = "true" ]; then
    echo ">>> 正在下载 OpenClash Meta 内核..."
    # 使用 OpenClash 官方 core 分支的真实直链 (适配 x86_64 架构)
    CORE_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64.tar.gz"
    curl -sL --retry 3 "$CORE_URL" -o meta.tar.gz
    
    # 检查压缩包是否有效 (防止下载到 404 网页)
    if tar -tzf meta.tar.gz >/dev/null 2>&1; then
        tar -zxf meta.tar.gz
        # 官方包解压出来的文件叫 clash，必须重命名为 clash_meta
        mv clash files/etc/openclash/core/clash_meta
        chmod +x files/etc/openclash/core/clash_meta
        rm -f meta.tar.gz
        echo "✅ OpenClash Meta 内核下载并配置成功！"
    else
        echo "⚠️ 警告: OpenClash 内核下载失败，文件损坏或链接失效。"
        rm -f meta.tar.gz
    fi
fi

# =========================================================
# 1. 准备初始化脚本与强化包
# =========================================================
mkdir -p files/etc/uci-defaults
DYNAMIC_SCRIPT="files/etc/uci-defaults/99-dynamic-settings"
echo "#!/bin/sh" > $DYNAMIC_SCRIPT

BASE_PACKAGES=""
# 磁盘与备份核心
BASE_PACKAGES="$BASE_PACKAGES base-files block-mount default-settings-chn luci-i18n-base-zh-cn"
BASE_PACKAGES="$BASE_PACKAGES sgdisk parted e2fsprogs fdisk lsblk blkid tar"
BASE_PACKAGES="$BASE_PACKAGES luci-i18n-package-manager-zh-cn"

# =========================================================
# 🌟 核心魔法：绝对精准的网络分配、安全扩容、数据保护
# =========================================================
cat >> $DYNAMIC_SCRIPT << EOF
# --- A. 智能接口绝对覆盖分配 (解决 eth0 冲突) ---
INTERFACES=\$(ls /sys/class/net 2>/dev/null | grep -E '^eth|^enp|^eno' | sort)
ETH_COUNT=\$(echo "\$INTERFACES" | grep -c '^')

if [ "\$ETH_COUNT" -gt 0 ]; then
    FIRST_ETH=\$(echo "\$INTERFACES" | head -n 1)
    
    # 1. 斩草除根：彻底删除 OpenWrt 原生的所有 LAN/WAN 配置
    uci -q delete network.lan.device
    uci -q delete network.lan.ifname
    uci -q delete network.lan.ports
    uci -q delete network.wan
    uci -q delete network.wan6
    uci -q delete network.br_lan
    
    # 2. 重新建立干净的 br-lan 桥接设备
    uci set network.br_lan=device
    uci set network.br_lan.name='br-lan'
    uci set network.br_lan.type='bridge'
    
    # 3. 设定默认 IP 与子网掩码，并将其绑定到新建的桥接设备
    uci set network.lan.device='br-lan'
    uci set network.lan.ipaddr='$CUSTOM_IP'
    uci set network.lan.netmask='255.255.255.0'

    if [ "\$ETH_COUNT" -eq 1 ]; then
        # 单网口模式：没有 WAN，把唯一的网口加入 LAN 网桥
        uci add_list network.br_lan.ports="\$FIRST_ETH"
    else
        # 多网口模式：eth0 绝对独占 WAN/WAN6
        uci set network.wan=interface
        uci set network.wan.proto='dhcp'
        uci set network.wan.device="\$FIRST_ETH"

        uci set network.wan6=interface
        uci set network.wan6.proto='dhcpv6'
        uci set network.wan6.device="\$FIRST_ETH"

        # 剩下的所有网口，通过循环全部加入 LAN 网桥
        for eth in \$(echo "\$INTERFACES" | grep -v "^\$FIRST_ETH\$"); do
            uci add_list network.br_lan.ports="\$eth"
        done
    fi
    uci commit network
fi

# --- B. 系统盘在线拉伸 ---
ROOT_DISK=\$(lsblk -d -n -o NAME | grep -E 'sda|nvme[0-9]n[0-9]' | head -n 1)
if [ -n "\$ROOT_DISK" ]; then
    DISK_DEV="/dev/\$ROOT_DISK"
    echo "\$ROOT_DISK" | grep -q "nvme" && P2="\${DISK_DEV}p2" && P3="\${DISK_DEV}p3" || P2="\${DISK_DEV}2" && P3="\${DISK_DEV}3"

    # 1. 修复 GPT 表
    sgdisk -e \$DISK_DEV || true
    sync && sleep 2

    # 2. 扩容分区表至你设定的 10240MB
    parted -s \$DISK_DEV resizepart 2 ${ROOTFS_SIZE}MiB || true
    sync && sleep 2
    
    # 3. 纯粹的在线拉伸文件系统 (不能带 -f)
    resize2fs \$P2 || true
    sync

    # --- C. 数据盘绝对安全挂载 (sda3) ---
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
            
            # --- D. 配置备份与 Collectd 路径转移 ---
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

# --- E. 恢复系统指令注入 ---
cat > /bin/restore-factory << 'RE'
#!/bin/sh
echo "========================================="
echo "☢️  正在执行系统恢复操作..."
echo "========================================="
if [ -f /opt/backup/factory_config.tar.gz ]; then
    echo "[1/3] 清理当前异常配置..."
    rm -rf /etc/config/*
    echo "[2/3] 应用出厂纯净配置..."
    tar -xzf /opt/backup/factory_config.tar.gz -C /
    echo "[3/3] 恢复成功，系统即将重启..."
    sleep 2
    reboot
else
    echo "❌ 错误: 未找到备份文件。请确认数据盘(/opt)已正确挂载。"
fi
RE
chmod +x /bin/restore-factory
EOF

# =========================================================
# 2. 插件包动态组装
# =========================================================
BASE_PACKAGES="$BASE_PACKAGES irqbalance zram-swap iperf3 htop curl wget-ssl kmod-vmxnet3"

[ "$THEME_ARGON" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-theme-argon"
[ "$APP_HOMEPROXY" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-homeproxy luci-i18n-homeproxy-zh-cn"
[ "$APP_OPENCLASH" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-openclash"
[ "$APP_PASSWALL" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-passwall luci-i18n-passwall-zh-cn"
[ "$APP_KSMBD" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-ksmbd luci-i18n-ksmbd-zh-cn"
[ "$APP_ADGUARDHOME" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-adguardhome"
[ "$APP_ALIST" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-alist"
[ "$APP_QBITTORRENT" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-qbittorrent luci-i18n-qbittorrent-zh-cn"
[ "$APP_MWAN3" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-mwan3 luci-i18n-mwan3-zh-cn"
[ "$APP_VLMCSD" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-vlmcsd luci-i18n-vlmcsd-zh-cn"
[ "$APP_STATISTICS" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-statistics luci-i18n-statistics-zh-cn collectd collectd-mod-cpu collectd-mod-interface collectd-mod-memory"
[ "$APP_SQM" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-sqm luci-i18n-sqm-zh-cn"
[ "$APP_WIREGUARD" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-proto-wireguard"
[ "$APP_TAILSCALE" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES tailscale"
[ "$APP_ZEROTIER" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-zerotier luci-i18n-zerotier-zh-cn"
[ "$APP_FRPC" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-frpc luci-i18n-frpc-zh-cn"

[ "$KMOD_IGC" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES kmod-igc"
[ "$KMOD_IXGBE" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES kmod-ixgbe"
[ "$KMOD_E1000E" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES kmod-e1000e"
[ "$KMOD_R8169" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES kmod-r8169"
[ "$KMOD_R8125" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES kmod-r8125"
[ "$INCLUDE_DOCKER" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-dockerman luci-i18n-dockerman-zh-cn docker-compose"

# =========================================================
# 4. 锁定物理参数并执行极限精简打包
# =========================================================
echo "uci commit" >> $DYNAMIC_SCRIPT
echo "exit 0" >> $DYNAMIC_SCRIPT
chmod +x $DYNAMIC_SCRIPT

sed -i "s/CONFIG_TARGET_ROOTFS_PARTSIZE=.*/CONFIG_TARGET_ROOTFS_PARTSIZE=1024/g" .config || echo "CONFIG_TARGET_ROOTFS_PARTSIZE=1024" >> .config
sed -i "s/CONFIG_TARGET_KERNEL_PARTSIZE=.*/CONFIG_TARGET_KERNEL_PARTSIZE=64/g" .config || echo "CONFIG_TARGET_KERNEL_PARTSIZE=64" >> .config

echo "CONFIG_TARGET_ROOTFS_EXT4FS=y" >> .config
echo "CONFIG_TARGET_ROOTFS_SQUASHFS=n" >> .config
echo "CONFIG_TARGET_ROOTFS_TARGZ=n" >> .config
echo "CONFIG_GRUB_IMAGES=n" >> .config
echo "CONFIG_VDI_IMAGES=n" >> .config
echo "CONFIG_VMDK_IMAGES=n" >> .config
echo "CONFIG_VHDX_IMAGES=n" >> .config
echo "CONFIG_QCOW2_IMAGES=n" >> .config
echo "CONFIG_ISO_IMAGES=n" >> .config

make image PROFILE="generic" PACKAGES="$BASE_PACKAGES" FILES="files"
