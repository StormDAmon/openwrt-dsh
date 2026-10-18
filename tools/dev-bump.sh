#!/bin/sh
# 开发期打包前的版本自增:PKG_RELEASE + 1,并同步引擎版本标记(形态 X.Y.Z-rN)。
# 由打包.bat 每次构建前调用。为什么独立成脚本而不塞进 build-ipk.sh:release.sh
# 的第 5 步同样调 build-ipk.sh,发布构建的版本必须钉死在 tag 对应的 r1,在构建器
# 里自增会让 tag 内容与产物版本分叉——自增只属于「开发期重新打包」这个动作,
# 详见 docs/porting-notes.md §19。
#
# 号只增不减、构建失败也不回收:路由器上 opkg 按「版本更高才升级」判断,复用旧号
# 会做出「装了也不生效」的假升级包(与 porting-notes §14 selfupdate 比版本同源)。
set -eu
cd "$(dirname "$0")/.." || exit 1

MK="openwrt-dsh/Makefile"
VERFILE="openwrt-dsh/files/usr/lib/openwrt-dsh/version"

# 三件套现状(提取逻辑与 dev-check.sh 同款,tr 掉可能的 CR/空白,容忍 CRLF)
ver="$(tr -d ' \r\n' < VERSION)"
mkv="$(sed -n 's/^PKG_VERSION:=//p' "$MK" | tr -d ' \r')"
mkr="$(sed -n 's/^PKG_RELEASE:=//p' "$MK" | tr -d ' \r')"

[ -n "$mkv" ] || { echo "✗ $MK 里没找到 PKG_VERSION"; exit 1; }
case "$mkr" in
    ''|*[!0-9]*) echo "✗ PKG_RELEASE 不是纯数字(当前:$mkr),拒绝自增;手改 $MK 后重试"; exit 1 ;;
esac
if [ "$ver" != "$mkv" ]; then
    echo "(警告) VERSION=$ver 与 PKG_VERSION=$mkv 不一致,本次只自增修订号,正本版本不动"
fi

new=$((mkr + 1))
# 两处一把改:ipk 文件名读 Makefile,LuCI 徽标/status/selfupdate 读标记文件,
# 分头改会出现「文件名 r10、页面徽标 r9」的劈叉
sed -i "s/^PKG_RELEASE:=.*/PKG_RELEASE:=$new/" "$MK"
printf '%s\n' "$mkv-r$new" > "$VERFILE"
echo "版本自增: $mkv-r$mkr → $mkv-r$new"
