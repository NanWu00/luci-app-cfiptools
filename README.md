## 安装指南

> **⚠️ 环境要求**：本项目专为 **ImmortalWrt 25.12 Snapshot** 及以上版本开发，底层已完全适配 Alpine/APK 包管理器。如果你使用的是老旧的 OPKG 环境（如 OpenWrt 23.05 及以下），请勿安装。


### 上传安装包

从 [Releases](#) 下载最新编译的 `luci-app-cfiptools_x.x-x_all.apk` 安装包。
使用 WinSCP、MobaXterm 或其他 SFTP 工具，将 `.apk` 文件上传至路由器的 `/tmp/` 目录中。


### 执行安装命令
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
```

安装完成后，刷新浏览器（Ctrl + F5），即可在 LuCI 后台的 服务 (Services) 菜单下看到 CFIP优选。


## 卸载与清理指南
在更新插件或排查问题时，可以通过以下脚本进行“无痕卸载”，这将彻底清理插件产生的测速进程、缓存文件、配置数据以及防火墙动态规则：

通过 SSH 登录到路由器，直接复制并执行整段代码：

```bash
# 1. 停止服务并清理 Cron 计划任务
/etc/init.d/cfiptools stop 2>/dev/null
/etc/init.d/cron restart 2>/dev/null

# 2. 强制击杀驻留的测速进程
pkill -f '/usr/share/cfiptools/update.py' 2>/dev/null
pkill -f 'curl.*speed.cloudflare.com' 2>/dev/null
pkill -f 'cfiptools/run.sh' 2>/dev/null

# 3. 通过 APK 引擎卸载插件
apk del luci-app-cfiptools 2>/dev/null

# 4. 彻底擦除 UCI 用户配置文件与缓存数据
rm -f /etc/config/cfiptools
uci delete cfiptools 2>/dev/null
uci commit 2>/dev/null
rm -rf /usr/share/cfiptools
rm -f /var/log/cfiptools.log
rm -f /var/run/cfiptools.pid
rm -f /var/run/cfiptools.status

# 5. 重载防火墙以清除 nftables 动态绕过规则
fw4 reload 2>/dev/null || /etc/init.d/firewall restart 2>/dev/null

# 6. 清理 LuCI 缓存以消除左侧幽灵菜单
rm -rf /tmp/luci-indexcache*
rm -rf /tmp/luci-modulecache/
rm -rf /tmp/luci-sessions/* 2>/dev/null

echo "卸载与清理完成！路由器已恢复纯净状态。"
```
