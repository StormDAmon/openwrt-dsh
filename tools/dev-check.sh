#!/bin/sh
# 开发期语法检查：引擎 shell 脚本（bash/sh 双 -n）+ JS（node --check）+ JSON 合法性。
# 在开发机（Windows Git Bash / Linux）即可跑，不依赖 OpenWrt。
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0

echo "== shell 语法（bash -n / sh -n）=="
for f in openwrt-dsh/files/usr/lib/openwrt-dsh/*.sh \
         openwrt-dsh/files/etc/init.d/openwrt-dsh-web \
         openwrt-dsh/files/usr/libexec/rpcd/luci.openwrt-dsh \
         openwrt-dsh/files/usr/bin/openwrt-dsh \
         openwrt-dsh/files/usr/bin/dsh \
         openwrt-dsh/files/etc/profile.d/openwrt-dsh.sh \
         tools/dev-check.sh tools/build-sdk.sh tools/release.sh tools/build-ipk.sh \
         tools/dev-bump.sh; do
    for sh in bash sh; do
        if ! "$sh" -n "$f" 2>&1; then
            echo "✗ [$sh -n] $f"
            fail=1
        fi
    done
done
[ "$fail" -eq 0 ] && echo "OK"

echo "== JS（node --check）=="
if command -v node >/dev/null 2>&1; then
    for f in openwrt-dsh/files/usr/lib/openwrt-dsh/elf-patch.js \
             openwrt-dsh/files/www/luci-static/resources/view/openwrt-dsh/main.js; do
        if ! node --check "$f" 2>&1; then
            echo "✗ [node --check] $f"
            fail=1
        fi
    done
    [ "$fail" -eq 0 ] && echo "OK"
else
    echo "(无 node，跳过)"
fi

echo "== JSON（menu.d / acl.d）=="
if command -v node >/dev/null 2>&1; then
    for f in openwrt-dsh/files/usr/share/luci/menu.d/*.json \
             openwrt-dsh/files/usr/share/rpcd/acl.d/*.json; do
        if ! node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$f" 2>&1; then
            echo "✗ [JSON] $f"
            fail=1
        fi
    done
    [ "$fail" -eq 0 ] && echo "OK"
fi

echo "== 版本一致性（VERSION = Makefile PKG_VERSION/PKG_RELEASE = 引擎版本标记）=="
ver="$(tr -d ' \r\n' < VERSION)"
mkv="$(sed -n 's/^PKG_VERSION:=//p' openwrt-dsh/Makefile | tr -d ' \r')"
mkr="$(sed -n 's/^PKG_RELEASE:=//p' openwrt-dsh/Makefile | tr -d ' \r')"
fv="$(tr -d ' \r\n' < openwrt-dsh/files/usr/lib/openwrt-dsh/version)"
if [ "$ver" = "$mkv" ] && [ -n "$mkr" ] && [ "$fv" = "$mkv-r$mkr" ]; then
    echo "OK: $ver（包版本 $fv）"
else
    echo "✗ 版本不一致: VERSION=$ver / Makefile=$mkv-r$mkr / version 文件=$fv"
    fail=1
fi

echo "== 资产存在性 =="
[ -f openwrt-dsh/files/usr/share/openwrt-dsh/node-pty/linux-x64/pty.node ] && echo "OK: pty.node" || { echo "✗ pty.node 缺失"; fail=1; }

if [ "$fail" -eq 0 ]; then
    echo "== 全部通过 =="
else
    echo "== 存在失败项 =="
fi
exit "$fail"
