#!/bin/sh
# 用 OpenWrt SDK 构建单包 ipk(引擎 + LuCI 页面已合并,2026-10-15 起)。
# 用法: tools/build-sdk.sh <SDK根目录> [x86_64]
# 前提: SDK 已解压且 feeds 已就绪(SDK 首次使用:
#   ./scripts/feeds update -a && ./scripts/feeds install -a)
# 日常构建用 tools/build-ipk.sh(自动下载 SDK + 借道 WSL,免手动准备)。
set -eu
SDK="${1:?用法: build-sdk.sh <SDK根目录>}"
ARCH="${2:-x86_64}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

[ -f "$SDK/include/toplevel.mk" ] || { echo "✗ $SDK 不像 OpenWrt SDK(缺 include/toplevel.mk)"; exit 1; }

# 仓库整体链入 package/(符号链接保留包目录结构)
ln -sfn "$REPO/openwrt-dsh" "$SDK/package/openwrt-dsh"

make -C "$SDK" defconfig
make -C "$SDK" package/openwrt-dsh/compile V=s

echo "== 产物 =="
find "$SDK/bin/packages" -name 'openwrt-dsh*.ipk' 2>/dev/null || true
echo "安装: 将 ipk 拷到路由器后 opkg install ./<文件名>"
