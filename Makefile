include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-cfiptools
PKG_VERSION:=1.0
PKG_RELEASE:=48

LUCI_TITLE:=LuCI support for CF IP Tools
LUCI_DEPENDS:=+luci-base +luci-compat +curl +python3
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature