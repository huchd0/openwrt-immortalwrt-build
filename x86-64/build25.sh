#!/bin/bash
# 终止脚本执行如果发生错误
set -e

echo "开始执行自定义构建脚本 build25.sh..."

# =========================================================
# [新增] 0. 自定义底层固件参数 (锁定 64MB 内核分区)
# =========================================================
echo "⚙️ 正在精简固件配置并锁定内核分区大小..."
cat >> .config <<EOF
CONFIG_TARGET_KERNEL_PARTSIZE=64
CONFIG_TARGET_ROOTFS_EXT4FS=n
CONFIG_TARGET_ROOTFS_TARGZ=n
CONFIG_VMDK_IMAGES=n
CONFIG_VDI_IMAGES=n
CONFIG_VHDX_IMAGES=n
CONFIG_QCOW2_IMAGES=n
CONFIG_ISO_IMAGES=n
EOF
echo "✅ 底层配置参数写入完成。"

# =========================================================
# 1. 定义基础插件与依赖 (针对 x86-64 优化)
# =========================================================
# 包含基础语言包、挂载工具、网卡驱动 (e1000e, igb, r8169) 以及 OpenClash 必需依赖
PACKAGES="luci luci-i18n-base-zh-cn luci-i18n-firewall-zh-cn \
block-mount fdisk blkid curl wget-ssl ca-bundle ca-certificates \
kmod-e1000e kmod-igb kmod-r8169 kmod-tun \
luci-app-openclash coreutils-nohup bash dnsmasq-full ipset ip-full libcap libcap-bin ruby ruby-yaml unzip kmod-nft-tproxy iptables-nft"

# =========================================================
# 2. 动态注入 Docker 组件 (兼容 24.10+ apk 系统)
# =========================================================
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    echo "🐳 检测到 Docker 集成需求，正在添加相关包..."
    # 移除了已被淘汰的 iptables-mod-*，只保留核心和虚拟网卡驱动
    PACKAGES="$PACKAGES luci-app-dockerman luci-i18n-dockerman-zh-cn docker docker-compose dockerd kmod-veth"
fi

# =========================================================
# 3. 生成 99-init-settings 开机自动化脚本
# =========================================================
# 注意：直接在 sh 文件中用 cat 生成该文件，可以彻底避免 Windows/Mac 编辑器导致的 CRLF 换行符报错问题。
mkdir -p files/etc/uci-defaults

cat << 'EOF' > files/etc/uci-defaults/99-init-settings
#!/bin/sh

# 读取在 YAML 中动态生成的配置文件
[ -f /etc/config/custom_router_ip.txt ] && CUSTOM_IP=$(cat /etc/config/custom_router_ip.txt) || CUSTOM_IP="192.168.100.1"

# [1] 配置 LAN 口 IP
uci set network.lan.ipaddr="$CUSTOM_IP"

# [2] 读取环境变量并配置宽带
if [ -f /etc/config/build_env.txt ]; then
    . /etc/config/build_env.txt
    
    if [ -n "$PPPOE_ACCOUNT" ] && [ -n "$PPPOE_PASSWORD" ]; then
        uci set network.wan.proto='pppoe'
        uci set network.wan.username="$PPPOE_ACCOUNT"
        uci set network.wan.password="$PPPOE_PASSWORD"
        uci set network.wan.ipv6='1' # 默认开启 IPv6 支持
    fi

    # [3] Docker 网络与防火墙打通 (真正的上手即用)
    if [ "$INCLUDE_DOCKER" = "yes" ]; then
        # 创建 Docker 专属防火墙区域
        uci set firewall.docker=zone
        uci set firewall.docker.name='docker'
        uci set firewall.docker.network='docker0'
        uci set firewall.docker.input='ACCEPT'
        uci set firewall.docker.output='ACCEPT'
        uci set firewall.docker.forward='ACCEPT'

        # 允许 Docker 访问外网 (拉取镜像)
        uci add firewall forwarding
        uci set firewall.@forwarding[-1].src='docker'
        uci set firewall.@forwarding[-1].dest='wan'

        # 允许 LAN 访问 Docker (访问容器服务)
        uci add firewall forwarding
        uci set firewall.@forwarding[-1].src='lan'
        uci set firewall.@forwarding[-1].dest='docker'
        
        # 允许 Docker 访问 LAN (容器反向代理或访问内网设备)
        uci add firewall forwarding
        uci set firewall.@forwarding[-1].src='docker'
        uci set firewall.@forwarding[-1].dest='lan'
    fi
fi

# 默认主题设置为 argon (如果固件自带的话)
uci set luci.main.mediaurlbase='/luci-static/argon'
uci commit

# 清理痕迹，完成无痕部署
rm -f /etc/config/custom_router_ip.txt
rm -f /etc/config/build_env.txt
rm -f /etc/uci-defaults/99-init-settings
exit 0
EOF

chmod +x files/etc/uci-defaults/99-init-settings

# =========================================================
# 4. 传递 YAML 环境变量给开机脚本
# =========================================================
# 将 Action 传入的变量固化到文件，供上述 99-init-settings 首次开机时读取
echo "PPPOE_ACCOUNT='$PPPOE_ACCOUNT'" > files/etc/config/build_env.txt
echo "PPPOE_PASSWORD='$PPPOE_PASSWORD'" >> files/etc/config/build_env.txt
echo "INCLUDE_DOCKER='$INCLUDE_DOCKER'" >> files/etc/config/build_env.txt

# =========================================================
# 5. 执行 ImmortalWrt 镜像构建
# =========================================================
echo "🚀 开始编译固件..."
# [新增] 在打包参数中强制加入 KERNEL_PARTSIZE=64
make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="files" EXTRA_IMAGE_NAME="efi" KERNEL_PARTSIZE=64 ROOTFS_PARTSIZE="$ROOTFS_SIZE"

echo "✅ 编译完成！"
