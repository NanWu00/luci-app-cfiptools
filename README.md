## 📦 安装指南

> **⚠️ 环境要求**：本项目专为 **ImmortalWrt 25.12 Snapshot** 及以上版本开发，底层已完全适配 Alpine/APK 包管理器。如果你使用的是老旧的 OPKG 环境（如 OpenWrt 23.05 及以下），请勿安装。

### 1. 上传安装包
从 [Releases](#) 下载最新编译的 `luci-app-cfiptools_x.x-x_all.apk` 安装包。
使用 WinSCP、MobaXterm 或其他 SFTP 工具，将 `.apk` 文件上传至路由器的 `/tmp/` 目录中。

### 2. 执行安装命令
通过 SSH 登录到路由器后台，依次执行以下指令：

```bash
# 1. 进入临时目录
cd /tmp/

# 2. 强制安装（本地包必须添加 --allow-untrusted 参数）
apk add --allow-untrusted luci-app-cfiptools_*.apk

# 3. 清理 LuCI 界面缓存
rm -rf /tmp/luci-indexcache*
rm -rf /tmp/luci-modulecache/

# 4. 重启 RPC 与 Web 服务以应用权限和菜单
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart

# 5. 删除临时安装包
rm -f /tmp/luci-app-cfiptools*.apk
