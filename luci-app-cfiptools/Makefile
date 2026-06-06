include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-cfiptools
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

LUCI_TITLE:=LuCI Support for CFIPTools

LUCI_PKGARCH:=all

LUCI_DEPENDS:=+luci-base +luci-compat +curl +python3

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature