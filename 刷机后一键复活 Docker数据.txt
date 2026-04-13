echo "🚀 开始 Docker 一条龙配置..."

# 1. 更新软件源并安装 Docker 及中文面板全家桶
echo "📦 正在安装依赖包..."
apk update
apk add dockerd docker docker-compose luci-app-dockerman luci-i18n-dockerman-zh-cn

# 2. 强制停止可能正在运行的 Docker 服务
echo "🛑 停止 Docker 服务..."
/etc/init.d/dockerd stop 2>/dev/null

# 3. 彻底清理系统默认路径下产生的“无用骨架”（加了 2>/dev/null 屏蔽找不到文件的提示）
echo "🧹 清理默认路径下的无用数据..."
rm -rf /var/lib/docker/* 2>/dev/null
rm -rf /opt/docker/* 2>/dev/null

# 4. 创建目标新家，并确保新家是绝对干净的
echo "🏠 准备新硬盘数据目录 /mnt/sda3/docker..."
mkdir -p /mnt/sda3/docker
rm -rf /mnt/sda3/docker/* 2>/dev/null

# 5. 迁移旧数据 (带安全判断)
echo "🚚 检查并迁移旧数据..."
if [ -d "/mnt/sdb1/old_docker" ] && [ "$(ls -A /mnt/sdb1/old_docker 2>/dev/null)" ]; then
    echo "✅ 发现旧数据，正在进行无损迁移 (这可能需要几分钟，请耐心等待)..."
    cp -a /mnt/sdb1/old_docker/* /mnt/sda3/docker/
else
    echo "⚠️ 未找到旧数据 /mnt/sdb1/old_docker 或目录为空，将为您创建一个纯净的新 Docker 环境。"
fi

# 6. 配置 UCI 参数 (面板与底层对接)
echo "⚙️ 配置 Docker 路径与网络基础参数..."
uci set dockerman.docker.data_root='/mnt/sda3/docker'
# 设置日志级别为 warn，防止日志塞满路由器空间
uci set dockerman.docker.log_level='warn'
# 提交保存配置
uci commit dockerman

# 7. 设置开机自启并启动服务
echo "🟢 启动 Docker 服务..."
/etc/init.d/dockerd enable
/etc/init.d/dockerd start

echo "🎉 一条龙配置全部完成！"
echo "👉 请进入 OpenWrt 后台 -> 服务 -> Docker，检查运行状态和数据路径是否正常。"
