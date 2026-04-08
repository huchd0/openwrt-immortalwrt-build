#!/bin/bash
set -e 

# 终端输出颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 无颜色

echo "========================================================="
echo -e "🕒 [$(date '+%Y-%m-%d %H:%M:%S')] ${BLUE}开始构建流程...${NC}"
echo -e "📦 目标分区大小: ${GREEN}$PROFILE MB${NC}"
echo "========================================================="

# >>> 1. 自定义固件参数 (注入 .config) <<<
echo -e "${YELLOW}⚙️ 正在精简固件配置并设置分区大小...${NC}"

# 使用 cat 一次性注入，避免多次调用 echo 导致 IO 碎片
cat >> .config <<EOF
# 设置内核分区大小
CONFIG_TARGET_KERNEL_PARTSIZE=64
# 禁用不需要的镜像格式 (精简输出)
CONFIG_TARGET_ROOTFS_EXT4FS=n
CONFIG_TARGET_ROOTFS_TARGZ=n
CONFIG_VMDK_IMAGES=n
CONFIG_VDI_IMAGES=n
CONFIG_VHDX_IMAGES=n
CONFIG_QCOW2_IMAGES=n
CONFIG_ISO_IMAGES=n
CONFIG_GRUB_IMAGES=n
EOF

echo "✅ 底层配置参数写入完成。"

# >>> 2. 读取外部自定义包列表 <<<
if [ -f "shell/custom-packages.sh" ]; then
    echo "📜 加载自定义包脚本..."
    source shell/custom-packages.sh
fi

# >>> 3. 自动化初始化脚本 (UCI Defaults) <<<
echo -e "${YELLOW}🔧 写入系统初始化配置 (LAN IP: $CUSTOM_ROUTER_IP)...${NC}"
INIT_SETTING="/home/build/immortalwrt/files/etc/uci-defaults/99-init-settings"
mkdir -p "$(dirname "$INIT_SETTING")"

cat << EOF > "$INIT_SETTING"
#!/bin/sh
# 设置 LAN 口 IP
uci set network.lan.ipaddr='$CUSTOM_ROUTER_IP'
uci commit network
# 运行一次后自删除
rm -f /etc/uci-defaults/99-init-settings
exit 0
EOF

# 确保初始化脚本有执行权限
chmod +x "$INIT_SETTING"

# >>> 4. 软件包组合策略 <<<
# 基础常用工具
BASE_PKGS="curl wget iperf3 luci-i18n-diskman-zh-cn luci-i18n-filemanager-zh-cn luci-i18n-package-manager-zh-cn luci-i18n-ttyd-zh-cn openssh-sftp-server"
# 主题与 UI
THEME_PKGS="luci-theme-argon luci-app-argon-config luci-i18n-argon-config-zh-cn"
# 网络插件 (UPnP, 防火墙, 定时重启)
NET_PKGS="luci-i18n-firewall-zh-cn luci-i18n-upnp-zh-cn luci-i18n-autoreboot-zh-cn"
# 科学上网
PROXY_PKGS="luci-app-openclash"

# 合并所有包
PACKAGES="$BASE_PKGS $THEME_PKGS $NET_PKGS $PROXY_PKGS $CUSTOM_PACKAGES"

# >>> 5. OpenClash 核心预集成 (优化版) <<<
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo -e "${YELLOW}⬇️ 正在为 OpenClash 准备核心文件...${NC}"
    CORE_PATH="files/etc/openclash/core"
    mkdir -p "$CORE_PATH"
    
    # 镜像站加速地址
    META_URL="https://mirror.ghproxy.com/https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64.tar.gz"
    
    # 下载并解压，带超时保护
    if wget -q --show-progress -T 10 -t 2 -O- "$META_URL" | tar xOvz > "$CORE_PATH/clash_meta"; then
        chmod +x "$CORE_PATH/clash_meta"
        echo -e "${GREEN}✅ Meta 核心预装成功${NC}"
    else
        echo -e "${YELLOW}⚠️ 核心下载失败或超时，编译将继续，请稍后手动更新。${NC}"
    fi
fi

# >>> 6. 执行镜像打包 <<<
echo -e "${BLUE}🛠️ 正在调用镜像构建器 (使用多核加速)...${NC}"

# 自动获取 CPU 核心数加速打包进程
make image PROFILE="generic" \
           PACKAGES="$PACKAGES" \
           FILES="/home/build/immortalwrt/files" \
           ROOTFS_PARTSIZE=$PROFILE \
           -j$(nproc)

# >>> 7. 结束提示 <<<
echo "========================================================="
echo -e "🎉 [$(date '+%Y-%m-%d %H:%M:%S')] ${GREEN}固件编译成功！${NC}"
echo -e "📂 固件存放位置: ${BLUE}bin/targets/x86/64/${NC} (以实际架构为准)"
echo "========================================================="
