include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-cfiptools
PKG_VERSION:=1.0
PKG_RELEASE:=1

LUCI_TITLE:=LuCI support for CF IP Tools
# 注意：这里**故意不写 +python3**。目标机需要 python3 运行时（run.sh 会检查并给出提示），
# 但把它写进 DEPENDS 会让 `make package/.../compile` 连带编译 host python3，
# 而 ImmortalWrt snapshot 的 host python3 在 PGO profile-run 阶段会跑 CPython 回归测试，
# 在 CI 上稳定失败（test_xml_etree FAILURE → profile-run-stamp Error 2）。
# 装包后用 `apk add python3` 或已在固件里自带的 python3 即可。
LUCI_DEPENDS:=+luci-base +luci-compat +curl
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature