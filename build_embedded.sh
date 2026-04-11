#!/bin/bash
set -e
set -o pipefail

# --- 1. 架构与内核精准自适应 ---
case "$TARGET_ARCH" in
    *"x86-64"*)             CORE="amd64-compatible" ;;
    *"armv8"*|*"aarch64"*)  CORE="arm64" ;;
    *"mediatek-filogic"*)   CORE="arm64" ;;
    *"ramips"*|*"ath79"*)   CORE="mipsle-softfloat" ;;
    *"mips"*)               CORE="mips-softfloat" ;;
    *)                      CORE="arm64" ;; 
esac
echo ">>> 🌍 架构识别: $TARGET_ARCH | 内核适配: $CORE"

# --- 2. 安全清理目录 ---
[ -d files ] && find files -mindepth 1 -delete 2>/dev/null || true
mkdir -p files/root files/etc/uci-defaults files/etc/openclash/core

# --- 3. 插件下载 ---
echo ">>> 📥 正在获取 OpenClash APK..."
OC_URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases/latest | grep "browser_download_url" | grep ".apk" | head -n 1 | cut -d '"' -f 4)

if [[ "$OC_URL" != http* ]]; then
    echo "❌ 致命错误: 下载链接异常，构建强制中止。"
    exit 1
fi
wget -qO files/root/luci-app-openclash.apk "$OC_URL"

# --- 4. 豪华版与精简版的命运分水岭 ---
if [ "$BUILD_MODE" == "Lite" ]; then
    echo "⚠️ 用户指令 [Lite 精简模式]：跳过内核注入，防止小 Flash 设备变砖。"
else
    echo ">>> 💎 用户指令 [Deluxe 豪华模式]：全功率全开！正在注入 Meta 内核..."
    wget -qO- "https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-${CORE}.tar.gz" | tar -zxf - -C files/etc/openclash/core/
    mv files/etc/openclash/core/clash files/etc/openclash/core/clash_meta 2>/dev/null || true
    chmod +x files/etc/openclash/core/clash_meta 2>/dev/null || true
fi

# --- 5. 编写静默初始化脚本 ---
cat << EOF > files/etc/uci-defaults/99-custom-setup
#!/bin/sh
uci set network.lan.ipaddr='$MANAGEMENT_IP'
uci set system.@system[0].hostname='ImmortalWrt'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci commit system

sed -i 's/downloads.openwrt.org/mirrors.ustc.edu.cn\/openwrt/g' /etc/apk/repositories.d/*.list 2>/dev/null || true
apk add -q --allow-untrusted /root/*.apk 2>/dev/null || true
rm -f /root/*.apk /etc/uci-defaults/99-custom-setup
exit 0
EOF
chmod +x files/etc/uci-defaults/99-custom-setup

# --- 6. 装备库 ---
# 基础必备包
PKGS="-dnsmasq dnsmasq-full luci-app-openclash luci-app-ttyd luci-i18n-ttyd-zh-cn"

if [ "$BUILD_MODE" == "Lite" ]; then
    # 极简版：只拔掉占用空间较大且不影响网络的 USB 挂载驱动，保留 PPPoE 拨号！
    PKGS="$PKGS -kmod-usb-core -kmod-usb3"
else
    # 豪华版：全功能拉满，带主题和统计
    PKGS="$PKGS luci-theme-argon luci-app-argon-config luci-app-statistics luci-i18n-statistics-zh-cn bash curl"
fi

# --- 7. 【稳健傻瓜化】品牌+型号双重锁死与智能翻译逻辑 ---
echo ">>> 🛠️ 执行最高级别安全 Profile 校验..."
ALL_PROFILES=$(make info | grep "^[a-zA-Z0-9_-]*:" | cut -d ':' -f 1)

# 第一道门：优先尝试精确命中 (如果用户直接填了准确的底层 ID)
if echo "$ALL_PROFILES" | grep -qx "$DEVICE_PROFILE"; then
    echo "✅ 精确匹配命中: $DEVICE_PROFILE"
else
    echo "⚠️ 未命中精确 ID，启动【智能翻译 + 唯一性安全校验】引擎..."
    
    # 📝 字典区：全站统一的翻译配置
    BRAND_DICT="
    小米 mi            (xiaomi)
    红米               (redmi)
    华硕 败家之眼      (asus)
    普联 tp            (tplink|tp-link)
    京东云 jd          (jdcloud)
    网件               (netgear)
    领势               (linksys)
    腾达               (tenda)
    水星               (mercury)
    友善 nanopi        (friendlyarm)
    新路由             (newifi|d-team)
    极路由             (hiwifi)
    中兴               (zte)
    华三               (h3c)
    锐捷               (ruijie)
    "
    
    # ⚙️ 翻译引擎函数
    translate_input() {
        local input_str="$1"
        local parsed_str="$input_str"
        while read -r -a words; do
            [ ${#words[@]} -lt 2 ] && continue
            local target="${words[-1]}"
            for (( i=0; i<${#words[@]}-1; i++ )); do
                local alias="${words[$i]}"
                parsed_str="${parsed_str//$alias/$target}"
            done
        done <<< "$BRAND_DICT"
        echo "${parsed_str// /.*}"
    }

    # 翻译品牌和型号
    PARSED_BRAND=$(translate_input "$BRAND")
    PARSED_PROFILE=$(translate_input "$DEVICE_PROFILE")
    
    echo ">>> 引擎转化规则: 品牌[$PARSED_BRAND] + 型号[$PARSED_PROFILE]"

    # 执行严苛的交叉匹配
    if [ -n "$PARSED_BRAND" ]; then
        MATCH_LIST=$(echo "$ALL_PROFILES" | grep -iE "$PARSED_BRAND" | grep -iE "$PARSED_PROFILE" || true)
    else
        MATCH_LIST=$(echo "$ALL_PROFILES" | grep -iE "$PARSED_PROFILE" || true)
    fi
    
    MATCH_COUNT=$(echo "$MATCH_LIST" | grep -v '^$' | wc -l || echo 0)

    # 第二道门：铁腕唯一性拦截
    if [ "$MATCH_COUNT" -eq 1 ]; then
        DEVICE_PROFILE=$(echo "$MATCH_LIST" | tr -d '[:space:]')
        echo "✅ 安全替换通过：找到唯一绝对匹配目标 -> $DEVICE_PROFILE"
    elif [ "$MATCH_COUNT" -gt 1 ]; then
        echo "❌ 危险动作中止：发现 $MATCH_COUNT 个可能的目标！"
        echo "为坚守【稳定为主】原则，程序拒绝为您盲猜。请从以下列表中挑选一个精确的 ID 填入："
        echo "$MATCH_LIST"
        exit 1
    else
        echo "❌ 匹配失败：当前架构下不存在该设备。请检查品牌或型号是否拼写错误。"
        exit 1
    fi
fi

# --- 8. 执行最终构建 ---
echo ">>> 🚀 [${BUILD_MODE}] 模式启动，安全护航，为您打包固件..."
make image PROFILE="$DEVICE_PROFILE" PACKAGES="$PKGS" FILES="files"
