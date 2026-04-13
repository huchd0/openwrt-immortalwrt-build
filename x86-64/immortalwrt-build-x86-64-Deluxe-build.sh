#!/bin/bash
set -e

# 接收 GitHub Actions 传来的环境变量
ROOTFS_SIZE=${ROOTFS_SIZE:-1024}
MANAGEMENT_IP=${MANAGEMENT_IP:-192.168.100.1}

if [[ ! "$MANAGEMENT_IP" == *"/"* ]]; then
    MANAGEMENT_IP="${MANAGEMENT_IP}/24"
fi

echo ">>> 1. 自定义固件参数 (专属 J4125 互刷保护) <<<"
echo "CONFIG_TARGET_KERNEL_PARTSIZE=64" >> .config
echo "CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_SIZE" >> .config

# 极致优化：只生成 UEFI 的 squashfs 格式
echo "CONFIG_TARGET_ROOTFS_EXT4FS=n" >> .config
echo "CONFIG_TARGET_ROOTFS_TARGZ=n" >> .config
echo "CONFIG_VMDK_IMAGES=n" >> .config
echo "CONFIG_VDI_IMAGES=n" >> .config
echo "CONFIG_VHDX_IMAGES=n" >> .config
echo "CONFIG_QCOW2_IMAGES=n" >> .config
echo "CONFIG_ISO_IMAGES=n" >> .config
echo "CONFIG_GRUB_IMAGES=n" >> .config

echo ">>> 2. 准备初始化文件夹 <<<"
mkdir -p files/root
mkdir -p files/etc/uci-defaults
mkdir -p files/etc/init.d
mkdir -p files/usr/bin

echo ">>> 3. 下载第三方 APK 插件与核心组件 (离线准备) <<<"
# 提前下载离线安装包，扔进 /root，彻底避开 Make Image 编译期依赖检查
OPENCLASH_URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases | grep -m 1 "browser_download_url.*\.apk" | cut -d '"' -f 4)
if [ -n "$OPENCLASH_URL" ]; then
    wget -qO files/root/luci-app-openclash.apk "$OPENCLASH_URL"
fi

ARGON_URL=$(curl -s https://api.github.com/repos/jerrykuku/luci-theme-argon/releases | grep -m 1 "browser_download_url.*\.apk" | cut -d '"' -f 4)
if [ -n "$ARGON_URL" ]; then
    wget -qO files/root/luci-theme-argon.apk "$ARGON_URL"
fi

echo "正在下载 OpenClash Meta 兼容版内核..."
mkdir -p files/etc/openclash/core
wget -qO files/etc/openclash/core/meta.tar.gz "https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-compatible.tar.gz"
tar -zxf files/etc/openclash/core/meta.tar.gz -C files/etc/openclash/core/
mv files/etc/openclash/core/clash files/etc/openclash/core/clash_meta
chmod +x files/etc/openclash/core/clash_meta
rm -f files/etc/openclash/core/meta.tar.gz

echo "正在注入 MT7925 官方底层固件..."
mkdir -p files/lib/firmware/mediatek/mt7925
wget -qO files/lib/firmware/mediatek/mt7925/BT_RAM_CODE_MT7925_1_1_hdr.bin "https://gitlab.com/kernel-firmware/linux-firmware/-/raw/53539c0625c5dbdd2308146e3435f06b51f68c01/mediatek/mt7925/BT_RAM_CODE_MT7925_1_1_hdr.bin"
wget -qO files/lib/firmware/mediatek/mt7925/WIFI_MT7925_PATCH_MCU_1_1_hdr.bin "https://gitlab.com/kernel-firmware/linux-firmware/-/raw/53539c0625c5dbdd2308146e3435f06b51f68c01/mediatek/mt7925/WIFI_MT7925_PATCH_MCU_1_1_hdr.bin"
wget -qO files/lib/firmware/mediatek/mt7925/WIFI_RAM_CODE_MT7925_1_1.bin "https://gitlab.com/kernel-firmware/linux-firmware/-/raw/53539c0625c5dbdd2308146e3435f06b51f68c01/mediatek/mt7925/WIFI_RAM_CODE_MT7925_1_1.bin"

echo ">>> 4. 编写全自动静默升级脚本 (防冲突独立文件) <<<"
cat << 'EOF_UPGRADE' > files/usr/bin/upg
#!/bin/sh
LOGFILE="/root/upg.log"
if [ -f "$LOGFILE" ] && [ $(wc -c < "$LOGFILE") -gt 1048576 ]; then
    echo "日志过大，已清空重建" > "$LOGFILE"
fi
echo "===== Auto Upgrade Start: $(date) =====" >> "$LOGFILE"

if command -v apk >/dev/null 2>&1; then
    openclash_before=$(apk info -v luci-app-openclash 2>/dev/null)
    apk update >> "$LOGFILE" 2>&1
    apk upgrade >> "$LOGFILE" 2>&1
    openclash_after=$(apk info -v luci-app-openclash 2>/dev/null)
else
    echo "仅支持 apk 包管理器。" >> "$LOGFILE"
    exit 1
fi

if [ -n "$openclash_before" ] && [ "$openclash_before" != "$openclash_after" ]; then
    echo "OpenClash 已升级，正在重启服务..." >> "$LOGFILE"
    /etc/init.d/openclash restart >> "$LOGFILE" 2>&1
fi
echo "===== Auto Upgrade End: $(date) =====" >> "$LOGFILE"
EOF_UPGRADE
chmod +x files/usr/bin/upg


echo ">>> 5. 编写全自动开机初始化脚本 <<<"

# --- 🎯 智能后台 Wi-Fi 注入模块 ---
cat << 'EOF_WIFI' > files/etc/init.d/wifi-auto-patch
#!/bin/sh /etc/rc.common
START=99

start() {
    (
        WAIT=0
        while [ $WAIT -lt 30 ]; do
            wifi config
            if uci get wireless.radio0 >/dev/null 2>&1; then
                break
            fi
            sleep 2
            WAIT=$((WAIT+1))
        done

        if uci get wireless.radio0 >/dev/null 2>&1; then
            uci set wireless.radio0.band='5g'
            uci set wireless.radio0.channel='149'
            uci set wireless.radio0.htmode='EHT80'
            uci set wireless.radio0.country='AU'
            uci set wireless.radio0.cell_density='0'
            uci set wireless.radio0.txpower='23'
            
            for iface in $(uci show wireless | grep '=wifi-iface' | cut -d'.' -f2 | cut -d'=' -f1); do
                uci set wireless.${iface}.ssid='mywifi7'
                uci set wireless.${iface}.encryption='sae-mixed'
                uci set wireless.${iface}.key='Aa666666'
                uci set wireless.${iface}.ieee80211w='1'
                uci set wireless.${iface}.network='lan'
                uci set wireless.${iface}.mode='ap'
            done
            uci commit wireless
        fi
        
        /etc/init.d/wifi-auto-patch disable
        rm -f /etc/init.d/wifi-auto-patch
    ) &
}
EOF_WIFI
chmod +x files/etc/init.d/wifi-auto-patch

# --- 🎯 首开机总控逻辑 ---
cat << EOF > files/etc/uci-defaults/99-custom-setup
#!/bin/sh

/etc/init.d/wifi-auto-patch enable

# A1. 核心网络设置
uci set network.lan.ipaddr='$MANAGEMENT_IP'
uci delete network.@device[0].ports 2>/dev/null
uci set network.lan.device='br-lan'
uci delete network.lan.type 2>/dev/null

# A2. 时区与专属主机名设置
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci set system.@system[0].hostname='Tanxm'
uci commit system

# B. 智能网口分配逻辑
INTERFACES=\$(ls /sys/class/net | grep -E '^eth[0-9]+' | sort)
PORT_COUNT=\$(echo "\$INTERFACES" | wc -w)

if [ "\$PORT_COUNT" -eq 1 ]; then
    uci add_list network.@device[0].ports='eth0'
    uci delete network.wan 2>/dev/null
    uci delete network.wan6 2>/dev/null
else
    for iface in \$INTERFACES; do
        if [ "\$iface" = "eth0" ]; then
            uci set network.wan='interface'
            uci set network.wan.proto='dhcp'
            uci set network.wan.device='eth0'
            uci set network.wan6='interface'
            uci set network.wan6.proto='dhcpv6'
            uci set network.wan6.device='eth0'
        else
            uci add_list network.@device[0].ports="\$iface" 
        fi
    done
fi
uci commit network

# C. 强制挂载大分区
if ! lsblk | grep -q sda3; then
    echo -e "w" | fdisk /dev/sda >/dev/null 2>&1
    echo -e "n\n3\n\n\nw" | fdisk /dev/sda >/dev/null 2>&1
    partprobe /dev/sda >/dev/null 2>&1 || true
    sleep 3
    if lsblk | grep -q sda3; then
        mkfs.ext4 -F /dev/sda3 >/dev/null 2>&1
    fi
fi

TARGET_UUID=\$(blkid -s UUID -o value /dev/sda3 2>/dev/null)
if [ -n "\$TARGET_UUID" ]; then
    echo "config 'global'" > /etc/config/fstab
    echo "  option  anon_swap   '0'" >> /etc/config/fstab
    echo "  option  anon_mount  '0'" >> /etc/config/fstab
    echo "  option  auto_swap   '1'" >> /etc/config/fstab
    echo "  option  auto_mount  '1'" >> /etc/config/fstab
    echo "  option  delay_root  '5'" >> /etc/config/fstab
    echo "  option  check_fs    '0'" >> /etc/config/fstab
    
    uci add fstab mount
    uci set fstab.@mount[-1].uuid="\$TARGET_UUID"
    uci set fstab.@mount[-1].target='/mnt/sda3'
    uci set fstab.@mount[-1].enabled='1'
    uci commit fstab
    
    mkdir -p /mnt/sda3
    mount /dev/sda3 /mnt/sda3 2>/dev/null || true
fi

# D. 统计图表假死修复与初始化 (MQTT 占位神操作)
if [ -x "/etc/init.d/collectd" ] && [ ! -f "/etc/collectd_inited" ]; then
    [ ! -f "/etc/config/luci_statistics" ] && touch /etc/config/luci_statistics
    
    uci set luci_statistics.collectd=statistics
    uci set luci_statistics.collectd.BaseDir='/var/run/collectd'
    uci set luci_statistics.collectd.Include='/etc/collectd/conf.d'
    uci set luci_statistics.collectd.PIDFile='/var/run/collectd.pid'
    uci set luci_statistics.collectd.PluginDir='/usr/lib/collectd'
    uci set luci_statistics.collectd.TypesDB='/usr/share/collectd/types.db'
    uci set luci_statistics.collectd.Interval='30'
    uci set luci_statistics.collectd.ReadThreads='2'
    uci set luci_statistics.collectd.enable='1'
    
    uci del luci_statistics.collectd_network.enable 2>/dev/null || true
    uci set luci_statistics.collectd_mqtt=statistics

    if [ -d "/mnt/sda3/" ]; then
        mkdir -p /mnt/sda3/collectd_rrd
        chmod -R 777 /mnt/sda3/collectd_rrd
        uci set luci_statistics.collectd_rrdtool=statistics
        uci set luci_statistics.collectd_rrdtool.enable='1'
        uci set luci_statistics.collectd_rrdtool.DataDir='/mnt/sda3/collectd_rrd'
    fi

    uci set luci_statistics.collectd_thermal=statistics
    uci set luci_statistics.collectd_thermal.enable='1'
    uci set luci_statistics.collectd_sensors=statistics
    uci set luci_statistics.collectd_sensors.enable='1'
    uci set luci_statistics.collectd_interface=statistics
    uci set luci_statistics.collectd_interface.enable='1'
    uci set luci_statistics.collectd_interface.ignoreselected='0'
    uci set luci_statistics.collectd_cpu=statistics
    uci set luci_statistics.collectd_cpu.enable='1'
    uci set luci_statistics.collectd_ping=statistics
    uci set luci_statistics.collectd_ping.enable='1'
    uci delete luci_statistics.collectd_ping.Hosts 2>/dev/null
    uci add_list luci_statistics.collectd_ping.Hosts='114.114.114.114'
    uci add_list luci_statistics.collectd_ping.Hosts='8.8.8.8'

    uci commit luci_statistics
    
    /etc/init.d/luci_statistics enable
    /etc/init.d/luci_statistics restart
    /etc/init.d/collectd enable
    /etc/init.d/collectd restart
    touch /etc/collectd_inited
fi

# E. 计划任务写入 (完美绕过文件归属权红线)
echo "0 2 */2 * * /usr/bin/upg" >> /etc/crontabs/root
/etc/init.d/cron restart 2>/dev/null || true

# F. 离线环境第三方插件动态安装
if [ -d "/etc/apk/repositories.d" ]; then
    sed -i 's/downloads.openwrt.org/mirrors.ustc.edu.cn\/openwrt/g' /etc/apk/repositories.d/*.list
fi

# 等待网络就绪后安装依赖与插件
(
    WAIT_NET=0
    while [ \$WAIT_NET -lt 30 ]; do
        if ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1; then
            apk update
            # 补装 ttyd
            apk add luci-app-ttyd luci-i18n-ttyd-zh-cn
            # 安装开机前下载好的离线包
            apk add -q --allow-untrusted /root/*.apk
            rm -f /root/*.apk
            
            # 激活 Argon 主题
            if uci get luci.themes.Argon >/dev/null 2>&1; then
                uci set luci.main.mediaurlbase='/luci-static/argon'
                uci commit luci
            fi
            break
        fi
        sleep 5
        WAIT_NET=\$((WAIT_NET+1))
    done
) &

rm -f /etc/uci-defaults/99-custom-setup
exit 0
EOF
chmod +x files/etc/uci-defaults/99-custom-setup


echo ">>> 6. 配置官方纯净软件列表 (视觉字典模式) <<<"

RAW_PACKAGES="
    # === 【1. 核心系统与后台界面】 ===
    -dnsmasq                                # 卸载默认的简易版 dnsmasq
    dnsmasq-full                            # 安装完整版 dnsmasq (防污染必备)
    luci                                    # OpenWrt 网页后台基础框架
    luci-base                               # 网页后台核心依赖库
    luci-compat                             # 兼容层库 (确保老版本插件正常运行)
    luci-i18n-base-zh-cn                    # 基础界面【中文】
    luci-i18n-firewall-zh-cn                # 防火墙设置【中文】
    luci-i18n-package-manager-zh-cn         # 软件包管理器【中文】

    # === 【2. 磁盘挂载与文件系统支持】 ===
    block-mount                             # 开机自动挂载磁盘和 Swap 分区
    blkid                                   # 提取磁盘 UUID
    lsblk                                   # 树状查询磁盘结构
    parted                                  # 现代大硬盘分区工具
    fdisk                                   # 经典分区工具
    e2fsprogs                               # Ext4 格式化维护工具
    kmod-usb-storage                        # USB 存储设备基础驱动
    kmod-usb-storage-uas                    # USB UAS 协议加速驱动 (提升硬盘速度)
    kmod-fs-ext4                            # Ext4 挂载支持
    kmod-fs-ntfs3                           # 新版高性能 NTFS 挂载支持
    kmod-fs-vfat                            # FAT32 挂载支持
    kmod-fs-exfat                           # exFAT 挂载支持

    # === 【3. 科学插件底层依赖与基础工具】 ===
    coreutils-nohup                         # 后台挂机运行工具
    coreutils-base64                        # Base64 编解码 (订阅解析需要)
    coreutils-sort                          # 文本排序工具
    bash                                    # 强大的终端环境
    jq                                      # JSON 解析工具
    curl                                    # 网络请求工具
    ca-bundle                               # 根证书包 (防 SSL 报错)
    libcap                                  # Linux 进程权限控制库
    libcap-bin                              # 权限管理命令行 (OpenClash 提权用)
    ruby                                    # Ruby 环境
    ruby-yaml                               # YAML 解析库
    unzip                                   # ZIP 解压工具

    # === 【4. 网络驱动与流量调度增强】 ===
    ip-full                                 # 完整版 iproute2 (策略路由)
    iptables-mod-tproxy                     # iptables 透明代理模块
    iptables-mod-extra                      # iptables 扩展模块
    kmod-tun                                # 虚拟隧道网卡驱动
    kmod-inet-diag                          # 网络连接诊断模块
    kmod-nft-tproxy                         # nftables 透明代理模块
    kmod-igc                                # Intel 2.5G 网卡驱动 (i225/i226)
    kmod-igb                                # Intel 千兆网卡驱动
    kmod-r8169                              # Realtek 系列通用驱动
    iwinfo                                  # 无线状态查询工具

    # === 【5. Wi-Fi 7 与 蓝牙 硬件支持 (MT7925)】 ===
    -wpad-basic-mbedtls                     # 卸载默认简易版无线守护进程
    -wpad-basic-wolfssl                     # 卸载默认简易版无线守护进程
    wpad-openssl                            # 完整版无线守护进程 (支持 WPA3)
    kmod-mt7925e                            # MT7925 Wi-Fi 7 PCI-E 驱动
    kmod-mt7925-firmware                    # MT7925 无线网卡闭源固件
    kmod-btusb                              # USB 蓝牙基础驱动
    bluez-daemon                            # 蓝牙官方协议栈
    kmod-input-uinput                       # 用户空间输入驱动 (蓝牙键鼠支持)

    # === 【6. 系统监控与网络排错神器】 ===
    nano                                    # 简易文本编辑器
    htop                                    # 彩色交互式系统监控
    ethtool                                 # 网卡物理状态调试工具
    tcpdump                                 # 强大的网络抓包工具
    mtr                                     # 进阶版路由追踪工具
    conntrack                               # 连接追踪状态查询
    iftop                                   # 实时网络流量监控
    screen                                  # 终端多路复用防断线保护
    collectd-mod-thermal                    # 硬件温度采集模块
    collectd-mod-sensors                    # 传感器采集模块
    collectd-mod-cpu                        # CPU 采集模块
    collectd-mod-ping                       # 延迟采集模块
    collectd-mod-interface                  # 网卡流量采集模块
    collectd-mod-rrdtool                    # 监控数据存储引擎
    collectd-mod-iwinfo                     # 无线信号采集模块

    # === 【7. LuCI 网页后台插件】 ===
    luci-app-ksmbd                          # 高性能轻量网络共享 (取代 Samba)
    luci-i18n-ksmbd-zh-cn                   # 网络共享【中文】
    luci-app-nlbwmon                        # 局域网主机流量统计监控
    luci-i18n-nlbwmon-zh-cn                 # 流量统计【中文】
    luci-app-statistics                     # 状态实时监控与历史统计图表
    luci-i18n-statistics-zh-cn              # 统计图表【中文】
"

# 🎯 动态过滤引擎：
# 用 sed 清洗掉所有 # 及后面的注释，再用 tr 把换行和多余空格压缩成单空格，最终喂给 Image Builder
PACKAGES=$(echo "$RAW_PACKAGES" | sed 's/#.*//g' | tr -s ' \n' ' ')

echo ">>> 7. 开始 Make Image 打包 <<<"
make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="files" EXTRA_IMAGE_NAME="efi-Deluxe" KERNEL_PARTSIZE=64 ROOTFS_PARTSIZE="$ROOTFS_SIZE"

echo ">>> 8. 提取固件 <<<"
mkdir -p output-firmware
cp bin/targets/x86/64/*combined-efi-Deluxe.img.gz output-firmware/ 2>/dev/null || true
echo ">>> 全部构建任务已圆满完成！ <<<"
