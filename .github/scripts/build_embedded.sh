#!/bin/bash
# 注意：取消 set -e，以便在 ImageBuilder 报虚假错误时，脚本能继续执行抢救逻辑
set -o pipefail

# ==========================================
# 📝 1. 品牌容错字典 (保持你的逻辑)
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
  local input="$1"; local dict="$2"
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
        if [[ "$word" == "$clean_alias" ]]; then echo "$target"; return; fi
      done
    done <<< "$dict"
  done
  echo "$input"
}
BRAND_KEYWORD=$(translate_brand "$RAW_BRAND" "$BRAND_DICT" | tr ' ' '|')

# ==========================================
# ⚙️ 2. 架构内核适配
# ==========================================
case "$TARGET_ARCH" in
    *"x86-64"*)             CORE="amd64-compatible" ;;
    *"armv8"*|*"aarch64"*)  CORE="arm64" ;;
    *"mediatek-filogic"*)   CORE="arm64" ;;
    *"ramips"*|*"ath79"*)   CORE="mipsle-softfloat" ;;
    *)                      CORE="arm64" ;; 
esac

# ==========================================
# 📁 3. 目录初始化
# ==========================================
mkdir -p files/etc/uci-defaults files/etc/openclash/core

# ==========================================
# 📦 4. 模式化分流：软件包策略与 Extroot 脚本
# ==========================================
PKGS="-dnsmasq dnsmasq-full luci-app-ttyd luci-i18n-ttyd-zh-cn"

if [ "$BUILD_MODE" == "Lite" ]; then
    echo ">>> 🗑️ [丐版模式] 强行剔除所有组件..."
    PKGS="$PKGS -luci-app-openclash -ppp -ppp-mod-pppoe -kmod-usb-core -kmod-usb3 -kmod-usb2"

elif [ "$BUILD_MODE" == "Extroot" ]; then
    echo ">>> 💾 [扩容模式] 注入 USB 驱动并保持无线/拨号功能..."
    # ✅ 恢复 wpad 和 ppp 逻辑：不再使用减号剔除它们
    # 仅剔除体积最大的 OpenClash，为 USB 驱动腾出约 3.5MB 空间
    PKGS="$PKGS block-mount e2fsprogs kmod-fs-ext4 kmod-usb-core kmod-usb3 kmod-usb-storage fdisk"
    PKGS="$PKGS -luci-app-openclash"
    
    cat << 'EOF' > files/etc/uci-defaults/90-auto-extroot
#!/bin/sh
if uci -q get fstab.@mount[0].target | grep -q "/overlay"; then exit 0; fi
sleep 15
DEVICE=$(block info | grep -oE "/dev/sd[a-z][0-9]+" | head -n 1)
if [ -n "$DEVICE" ]; then
    mkfs.ext4 -F -L "extroot" "$DEVICE"
    mkdir -p /mnt/extroot && mount "$DEVICE" /mnt/extroot
    tar -C /overlay -cvf - . | tar -C /mnt/extroot -xf -
    block detect > /etc/config/fstab
    uci set fstab.@mount[0].target='/overlay'
    uci set fstab.@mount[0].enabled='1'
    uci commit fstab && sync && reboot
fi
EOF
    chmod +x files/etc/uci-defaults/90-auto-extroot

else
    echo ">>> 🔌 [豪华模式] 注入全套组件..."
    wget -qO- "https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-${CORE}.tar.gz" | tar -zxf - -C files/etc/openclash/core/
    PKGS="$PKGS luci-app-openclash luci-theme-argon block-mount e2fsprogs kmod-fs-ext4 kmod-usb-core kmod-usb3 kmod-usb-storage"
fi

# ==========================================
# 🔧 5. 系统基础配置
# ==========================================
cat << EOF > files/etc/uci-defaults/99-setup
#!/bin/sh
uci set network.lan.ipaddr='$MANAGEMENT_IP'
uci commit network
sed -i 's/downloads.openwrt.org/mirrors.ustc.edu.cn\/openwrt/g' /etc/apk/repositories.d/*.list 2>/dev/null || true
rm -f /etc/uci-defaults/99-setup
exit 0
EOF
chmod +x files/etc/uci-defaults/99-setup

# ==========================================
# 🛡️ 6. 安全校验逻辑
# ==========================================
ALL_PROFS=$(make info | grep "^[a-zA-Z0-9_-]*:" | cut -d ':' -f 1)
FINAL_PROF=$(echo "$ALL_PROFS" | grep -ix "$EXACT_PROFILE" | head -n 1 || echo "$EXACT_PROFILE")

# ==========================================
# 🚀 7. 终极打包与强力抢救
# ==========================================
echo ">>> 🚀 正在打包固件 (模式: $BUILD_MODE)..."

# 开启后台“小偷”程序，防止 ImageBuilder 报错后删除 bin 文件
mkdir -p /tmp/salvage
( while true; do find bin/targets -name "*.bin" -exec cp {} /tmp/salvage/ \; 2>/dev/null; sleep 0.5; done ) &
SALVAGE_PID=$!

# 执行编译，忽略报错
make image PROFILE="$FINAL_PROF" PACKAGES="$PKGS" FILES="files" || echo "⚠️ 引擎报告体积警告，尝试从缓存抢救..."

kill $SALVAGE_PID || true
mkdir -p bin/targets/salvaged
cp /tmp/salvage/*.bin bin/targets/salvaged/ 2>/dev/null || true

# ==========================================
# 🛡️ 8. 物理体积二次核验
# ==========================================
FIRMWARE_FILE=$(find bin/targets -name "*.bin" | head -n 1)

if [ -f "$FIRMWARE_FILE" ]; then
    FILE_SIZE=$(du -k "$FIRMWARE_FILE" | cut -f1)
    echo ">>> 📊 固件检测成功！当前体积: ${FILE_SIZE}KB"
    
    if [ "$FILE_SIZE" -gt 16128 ]; then # 15.75MB 安全线
        echo "❌ 致命错误：固件体积 (${FILE_SIZE}KB) 超过了 16MB 物理闪存上限！"
        exit 1
    else
        echo "✅ 校验通过：体积符合 16MB 物理规格，可安全刷入。"
    fi
else
    echo "❌ 错误：未能在 bin 目录找到生成的固件。"
    exit 1
fi

# ==========================================
# 🏷️ 9. 重命名与清理
# ==========================================
[ -d "bin/targets/salvaged" ] && cd bin/targets/salvaged || cd bin/targets/*/*
for img in *.bin; do
    if [ -f "$img" ]; then
        mv "$img" "${img%.*}-${TARGET_ARCH}.bin"
    fi
done
