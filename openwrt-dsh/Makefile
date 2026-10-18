# SPDX-License-Identifier: MIT
#
# openwrt-dsh 包:引擎脚本 + rpcd 后端 + CLI + LuCI 页面 + musl pty 原生件资产
# (2026-10-15 起单包形态:引擎与 LuCI 页面合并分发,装一个 ipk 全都有)
# 构建:把整个仓库放进 OpenWrt SDK/buildroot 的 package/ 目录后
#   make package/openwrt-dsh/compile V=s

include $(TOPDIR)/rules.mk

PKG_NAME:=openwrt-dsh
PKG_VERSION:=0.1.0
PKG_RELEASE:=26
PKG_MAINTAINER:=openwrt-dsh contributors
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

# LuCI 视图文件名带全版本（点换下划线，视图路径不允许点段——加载器会 name.replace(/\./g,'/')
# 把点当目录分隔）。为什么必须带版本：LuCI 加载视图的缓存穿透符 ?v= 只取 luci-base 的
# resource_version，我们升包它不变；uhttpd 又不发 Cache-Control，浏览器按启发式缓存把
# 旧视图 JS 「新鲜」数小时——升级后普通刷新仍执行旧代码，用户对着修好的页面依旧
# 「按钮点不开」（2026-10-18 真机实锤）。文件名随版本变 = URL 变 = 必定重新拉取，
# opkg 升级还会自动删掉旧版本名文件，不留垃圾。
ODSH_VIEW_SUFFIX:=-$(subst .,_,$(PKG_VERSION))-r$(PKG_RELEASE)
ODSH_VIEW_NAME:=main$(ODSH_VIEW_SUFFIX).js

define Package/openwrt-dsh
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=dsh (DeepSeek Harness) bootstrap engine + LuCI app for OpenWrt/iStoreOS
  URL:=https://github.com/StormDAmon/openwrt-dsh
  # curl:主下载器(busybox wget 兜底可用,但 curl 更稳);ca-*:HTTPS 必需。
  # luci-base:LuCI 页面依赖(菜单/视图机制);纯 CLI 场景它也随 opkg 自动装上。
  # libstdc++/libgcc 不依赖系统包——引擎自带 Alpine 三件套(见 docs/porting-notes.md)
  DEPENDS:=+curl +ca-bundle +ca-certificates +luci-base
  # 合并前的旧 luci-app-openwrt-dsh(从未发布,仅早期真机装过)与本包双写视图/菜单/ACL
  # 同一文件,残留会互相顶掉(旧页面占位文案「检查中…」就是它)——禁共存。
  CONFLICTS:=luci-app-openwrt-dsh
  PKGARCH:=all
endef

define Package/openwrt-dsh/description
  在 OpenWrt/iStoreOS(x86_64 musl)上安装与更新 dsh 的引擎:
  musl Node unofficial 构建 + Alpine 三件套运行库 + 三级垫片 + PT_INTERP/DT_NEEDED
  双 ELF 补丁 + koffi/node-pty musl 修复。含 SSH CLI(openwrt-dsh)、rpcd 后端
  与 LuCI 页面(服务 → DeepSeek Harness)。
endef

# pty.node 是 Alpine musl 预构建,NEEDED 的是 libc.musl-x86_64.so.1 / libstdc++.so.6
# (Alpine 的 musl 改了 SONAME,OpenWrt 的 musl 永远不会提供这个名字)。
# 引擎自带 Alpine 三件套、刻意不依赖系统 libstdc++,所以这里向 buildroot 的
# ELF 依赖扫描(gen-dependencies)声明「这两个 SONAME 本包自带」,否则打包直接
# 报 missing dependencies 失败(24.10.8 SDK 实测,详见 docs/porting-notes.md)。
# 注意:extra_provides 只影响扫描校验,不会往 ipk 的 Depends 字段里塞系统库。
define Package/openwrt-dsh/extra_provides
	echo "libc.musl-x86_64.so.1"; \
	echo "libstdc++.so.6"
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
endef

define Package/openwrt-dsh/install
	$(INSTALL_DIR) $(1)/usr/lib/openwrt-dsh
	$(INSTALL_BIN) $(CURDIR)/files/usr/lib/openwrt-dsh/*.sh $(1)/usr/lib/openwrt-dsh/
	$(INSTALL_DATA) $(CURDIR)/files/usr/lib/openwrt-dsh/elf-patch.js $(1)/usr/lib/openwrt-dsh/
	# 引擎版本标记：release.sh 与 VERSION/PKG_VERSION 同步（形态 0.1.0-r6）。LuCI 标题徽标、
	# 「当前包版本」与 CLI status、自更新比版本都优先读它，opkg 库兜底
	$(INSTALL_DATA) $(CURDIR)/files/usr/lib/openwrt-dsh/version $(1)/usr/lib/openwrt-dsh/
	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) $(CURDIR)/files/usr/libexec/rpcd/luci.openwrt-dsh $(1)/usr/libexec/rpcd/
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(CURDIR)/files/usr/bin/openwrt-dsh $(1)/usr/bin/
	$(INSTALL_BIN) $(CURDIR)/files/usr/bin/dsh $(1)/usr/bin/
	$(INSTALL_DIR) $(1)/usr/share/openwrt-dsh/node-pty/linux-x64
	$(INSTALL_DATA) $(CURDIR)/files/usr/share/openwrt-dsh/node-pty/linux-x64/pty.node \
		$(1)/usr/share/openwrt-dsh/node-pty/linux-x64/
	# dsh Web 服务（procd）的 LAN 绑定 overlay：经 --patch 官方通道钉 host=0.0.0.0
	# （CLI 拒绝 0.0.0.0，配置层合法；为什么与安全边界见该文件头注释）
	$(INSTALL_DATA) $(CURDIR)/files/usr/share/openwrt-dsh/web-lan.patch.yml \
		$(1)/usr/share/openwrt-dsh/
	# dsh Web 服务的 init 脚本：默认不自启（UCI enabled=0），LuCI「Web 界面」区
	# 开启时由 rpcd web_set 走 enable+start
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) $(CURDIR)/files/etc/init.d/openwrt-dsh-web $(1)/etc/init.d/
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) $(CURDIR)/files/etc/config/openwrt-dsh $(1)/etc/config/
	$(INSTALL_DIR) $(1)/etc/profile.d
	$(INSTALL_DATA) $(CURDIR)/files/etc/profile.d/openwrt-dsh.sh $(1)/etc/profile.d/
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/openwrt-dsh
	$(INSTALL_DATA) $(CURDIR)/files/www/luci-static/resources/view/openwrt-dsh/main.js \
		$(1)/www/luci-static/resources/view/openwrt-dsh/$(ODSH_VIEW_NAME)
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	# menu.d 里的视图路径与上面的版本化文件名一一对应（源文件里写的是 openwrt-dsh/main，
	# 打包期改写；模式带尾引号只命中 action.path，不碰 admin/services/openwrt-dsh 键名）
	sed 's/openwrt-dsh\/main"/openwrt-dsh\/main$(ODSH_VIEW_SUFFIX)"/' \
		$(CURDIR)/files/usr/share/luci/menu.d/openwrt-dsh.json \
		> $(1)/usr/share/luci/menu.d/openwrt-dsh.json
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) $(CURDIR)/files/usr/share/rpcd/acl.d/openwrt-dsh.json $(1)/usr/share/rpcd/acl.d/
endef

define Package/openwrt-dsh/conffiles
/etc/config/openwrt-dsh
endef

# 安装/升级后收尾(r5 起,2026-10-17 真机实锤)。本包不走 luci.mk,luci.mk 默认生成
# 的这段 postinst 必须自己补,否则:
#   - rpcd 只在启动/SIGHUP 时扫描 /usr/libexec/rpcd 并枚举 ubus 方法,装完不 reload
#     的话 luci.openwrt-dsh 对象没注册,LuCI 页面所有按钮点了都没反应(后台任务根本
#     没启动,/tmp/openwrt-dsh 都不会出现——真机上就是这么实锤的);
#   - menu.d/视图更新后还要清 LuCI 的 index/module 缓存,新菜单才出现。
#   (详见 docs/porting-notes.md §15 与其中「前端侧的伴生坑」一节)
# IPKG_INSTROOT 非空 = SDK 固件构建期,目标机尚未运行,跳过运行期动作(官方同款守卫);
# reload 而非 restart:不断 LuCI 会话(官方 rpcd 包 postinst 同款取舍,procd 转 SIGHUP)。
define Package/openwrt-dsh/postinst
[ -n "$${IPKG_INSTROOT}" ] || { \
	rm -f /tmp/luci-indexcache.*; \
	rm -rf /tmp/luci-modulecache/; \
	# 视图文件名随版本变（Makefile ODSH_VIEW_NAME），旧版名的文件 opkg 升级会剪；
	# 这里再兜一道，防个别 opkg 行为不剪时留下孤儿 main.js 混淆排查
	rm -f /www/luci-static/resources/view/openwrt-dsh/main.js; \
	/etc/init.d/rpcd reload 2>/dev/null; \
	# LAN 设置解锁补丁（§26）：插件包升级不动 dsh 本体（install-dsh.sh 不会跑），
	# 这里对已装 dsh 无条件重涂——dsh 不在时 apply 回 no-dsh，无害。必须先涂后重启：
	# /plugins 的 rev 由文件 mtime 派生、响应 immutable 缓存一年，只有重启才重扫
	# 进 boot 清单，浏览器才拿得到补后的客户端代码
	sh /usr/lib/openwrt-dsh/web-patch.sh apply 2>/dev/null || true; \
	# dsh Web 服务若在运行：opkg 换了磁盘上的 web-run.sh/overlay 而进程还握着旧
	# inode，重启一次才真正吃到新文件（enabled 才动，未启用保持零存在感）
	if /etc/init.d/openwrt-dsh-web enabled 2>/dev/null; then \
		/etc/init.d/openwrt-dsh-web restart 2>/dev/null; \
	fi; \
	exit 0; \
}
endef

$(eval $(call BuildPackage,openwrt-dsh))
