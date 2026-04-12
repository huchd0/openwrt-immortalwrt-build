#!/bin/bash
set -e
set -o pipefail

# ==========================================
# 📝 1. 品牌容错字典
# ==========================================
BRAND_DICT="
小米|mi                (xiaomi)
红米                  (redmi)
华硕|败家之眼|asus     (asus)
普联|tp|tplink         (tplink|tp-link)
网件|netgear           (netgear)
领势|linksys           (linksys)
腾达|tenda             (tenda)
水星|mercury           (mercury)
中兴|zte               (zte)
华为|huawei            (huawei)
华三|h3c               (h3c)
锐捷|ruijie            (ruijie)
京东云|jd|无线宝       (jdcloud)
斐讯|phicomm           (phicomm)
新路由|newifi|dteam    (newifi|d-team)
极路由|hiwifi          (hiwifi)
奇虎|360               (qihoo)
移动|中国移动|cmcc     (cmcc)
友善|nanopi|friendlyarm(friendlyarm)
"

RAW_BRAND=$(echo "$BRAND_INPUT" | xargs | tr '[:upper:]' '[:lower:]')
EXACT_PROFILE=$(echo "$DEVICE_PROFILE" | xargs)

translate_brand() {
  local input="$1"
  local dict="$2"
  [ -z "$input" ] && return
  for word in $input; do
    local matched=0
    while IFS= read -r line; do
      [[ ! "$line" =~ [^[:space:]] ]] && continue
      local target=$(echo "${line##*\(}" | tr -d ')')
      local aliases_str=$(echo "${line%\(*}" | tr '[:upper:]' '[:lower:]')
      IFS='|' read -ra ALIAS_ARRAY <<< "$aliases_str"
      for raw_alias in "${ALIAS_ARRAY[@]}"; do
        local clean_alias=$(echo "$raw_alias" | xargs)
        if [[ "$word" == "$clean_alias" ]]; then
          echo "$target"
          return
        fi
      done
    done <<< "$dict"
    if [ $matched -eq 0 ]; then echo "$word"; fi
  done
}

BRAND_KEYWORD=$(translate_brand "$RAW_BRAND" "$BRAND_DICT" | tr ' ' '|')

# ==========================================
# ⚙️ 2. 架构内核精准适配
# ==========================================
case "$TARGET_ARCH" in
    *"x86-64"*)             CORE="amd64-compatible" ;;
    *"armv8"*|*"aarch64"*)  CORE="arm64" ;;
    *"mediatek-filogic"*)   CORE="arm64" ;;
    *"ramips"*|*"ath79"*)   CORE="mipsle-softfloat" ;;
    *)                      CORE="arm64" ;; 
esac
echo ">>> 🌍 架构识别: $TARGET_ARCH | 内核适配: $CORE"

# ==========================================
# 📁 3. 目录初始化
# ==========================================
mkdir -p files/etc/uci-defaults files/etc/openclash/core

# ==========================================
# 📥 4. 模式化分流：Meta 内核注入
# ==========================================
if [ "$BUILD_MODE" == "Lite" ]; then
    echo "⚠️ [Lite 丐版模式] 启动：跳过 Meta 内核注入，为您极限压缩固件体积..."
    echo "💡 提示：刷入后若需使用 OpenClash，请在后台插件面板手动下载内核。"
else
    echo ">>> 💎 [Deluxe 豪华模式] 启动：正在为您预置 Meta 内核..."
    wget -qO- "https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-${CORE}.tar.gz" | tar -zxf - -C files/etc/openclash/core/
    mv files/etc/openclash/core/clash files/etc/openclash/core/clash_meta 2>/dev/null || true
    chmod +x files/etc/openclash/core/clash_meta 2>/dev/null || true
fi

# ==========================================
# 🔧 5. 静默配置脚本
# ==========================================
cat << EOF > files/etc/uci-defaults/99-custom-setup
#!/bin/sh
uci set network.lan.ipaddr='$MANAGEMENT_IP'
uci set system.@system[0].hostname='ImmortalWrt'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci commit system

sed -i 's/downloads.openwrt.org/mirrors.ustc.edu.cn\/openwrt/g' /etc/apk/repositories.d/*.list 2>/dev/null || true
rm -f /etc/uci-defaults/99-custom-setup
exit 0
EOF
chmod +x files/etc/uci-defaults/99-custom-setup

# ==========================================
# 📦 6. 模式化分流：软件包策略 (通用化核心)
# ==========================================
PKGS="-dnsmasq dnsmasq-full luci-app-openclash luci-app-ttyd luci-i18n-ttyd-zh-cn"

if [ "$BUILD_MODE" == "Lite" ]; then
    echo ">>> 🗑️ [Lite 丐版模式] 正在强行剔除 USB 驱动及非核心组件以防变砖..."
    PKGS="$PKGS -ppp -ppp-mod-pppoe -kmod-usb-core -kmod-usb3 -kmod-usb2"
else
    echo ">>> 🔌 [Deluxe 豪华模式] 注入 USB 挂载与文件系统包 (支持 U盘扩容)..."
    # 注入 Argon 主题，以及 U 盘扩容/挂载必须的驱动环境
    PKGS="$PKGS luci-theme-argon luci-app-argon-config block-mount e2fsprogs kmod-fs-ext4"
fi

# ==========================================
# 🛡️ 7. 严苛防爆：全字匹配与双保险
# ==========================================
echo ">>> 🛠️ 安全校验：严格 Profile 匹配与品牌双保险..."
ALL_PROFILES=$(make info | grep "^[a-zA-Z0-9_-]*:" | cut -d ':' -f 1)

FINAL_PROFILE=$(echo "$ALL_PROFILES" | grep -ix "$EXACT_PROFILE" || true)
MATCH_COUNT=$(echo "$FINAL_PROFILE" | grep -v '^$' | wc -l || echo 0)

if [ "$MATCH_COUNT" -eq 1 ]; then
    FINAL_PROFILE=$(echo "$FINAL_PROFILE" | tr -d '[:space:]')
    echo "✅ 第一重校验通过：锁定设备代号 -> $FINAL_PROFILE"
elif [ "$MATCH_COUNT" -gt 1 ]; then
    echo "❌ 严重错误：数据库代号异常，安全锁死。"
    exit 1
else
    echo "❌ 致命错误：当前架构下不存在该设备代号 [$EXACT_PROFILE]！"
    exit 1
fi

if [ -n "$BRAND_KEYWORD" ]; then
    if echo "$FINAL_PROFILE" | grep -iqE "$BRAND_KEYWORD"; then
        echo "✅ 第二重校验通过：品牌匹配无误！"
    else
        echo "❌ 刷砖预警：输入的品牌 [$BRAND_INPUT] 与代号 [$FINAL_PROFILE] 不匹配！"
        exit 1
    fi
fi

# ==========================================
# 🚀 8. 终极打包与智能超载拦截机制
# ==========================================
echo ">>> 🚀 正在以【$BUILD_MODE】模式全速打包固件..."
make image PROFILE="$FINAL_PROFILE" PACKAGES="$PKGS" FILES="files"

# 核心保护逻辑：如果找不到 .bin 或 .img.gz 文件，说明体积超载被官方构建引擎静默抛弃了
if ! ls bin/targets/*/*/*.{bin,img.gz} 1> /dev/null 2>&1; then
    echo "================================================================"
    echo "❌ 🚨 致命错误：固件编译失败！"
    echo "原因：在【$BUILD_MODE】模式下，固件体积超出了【$FINAL_PROFILE】的物理 Flash 上限！"
    echo "ImageBuilder 出于防刷砖保护机制，拒绝生成危险的超容 .bin 文件。"
    echo ""
    if [ "$BUILD_MODE" == "Deluxe" ]; then
        echo "💡 智能降级建议：您的设备可能存储空间极小（如 16MB/32MB）。"
        echo "👉 请回到 GitHub Actions 界面，将【4. 构建模式】切换为【Lite 丐版】重新编译。"
    else
        echo "💡 极限挽救建议：您当前已是 Lite 丐版，如果仍超容，说明该版本 OpenWrt 底层内核过大。"
        echo "👉 请尝试切换到更老的固件版本（如 23.05.4）再次尝试。"
    fi
    echo "================================================================"
    exit 1
fi

echo ">>> 🏷️ 正在为生成的固件注入架构标识..."
cd bin/targets/*/* || true
for img in *.{bin,img.gz}; do
    if [ -f "$img" ]; then
        base="${img%.*}"
        ext="${img##*.}"
        if [[ "$img" == *.img.gz ]]; then
            base="${img%.img.gz}"
            ext="img.gz"
        fi
        new_name="${base}-${TARGET_ARCH}.${ext}"
        echo "✅ 成功重命名: $new_name"
        mv "$img" "$new_name"
    fi
done
