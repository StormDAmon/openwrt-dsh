#!/bin/sh
# 构建 ipk 二进制包(引擎 + LuCI,全部 arch=all,跨 OpenWrt 版本通用)。
# 产物是别人能直接 opkg install / iStore 一键安装的成品包,挂 GitHub Release 用。
#
# 用法:
#   Windows Git Bash:  tools/build-ipk.sh                  # 全自动借道 WSL
#   Linux/WSL/容器内:  tools/build-ipk.sh <SDK的tar.zst> [输出目录] [仓库根]
#
# SDK 下载(宿主机任意方式,脚本只认文件):
#   https://downloads.openwrt.org/releases/24.10.8/targets/x86/64/
#
# 为什么 Windows 下要整包拷进 WSL ext4 再构建:SDK 解压上万个小文件,直接在
# /mnt/c(9P 跨界文件系统)上做是数量级级别的慢;拷进去只花几秒,产物 ipk
# 只有几十 KB,回拷瞬间完成。
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"

# ---------- Windows 桥接:转交 WSL 执行(-u root 免密,便于自动补依赖) ----------
if [ -z "${BUILD_IPK_INNER:-}" ] && uname -s | grep -qE 'MINGW|MSYS|CYGWIN'; then
    SDK_TAR="${1:-$(ls "$REPO"/work/openwrt-sdk-*.tar.zst 2>/dev/null | head -1)}"
    if [ -z "$SDK_TAR" ] || [ ! -f "$SDK_TAR" ]; then
        echo "✗ 未找到 SDK 包(work/openwrt-sdk-*.tar.zst)"
        echo "  下载: https://downloads.openwrt.org/releases/24.10.8/targets/x86/64/"
        exit 1
    fi
    to_wsl() { echo "$1" | sed -E 's#^/([a-z])/#/mnt/\1/#'; }
    WSL_REPO="$(to_wsl "$REPO")"
    WSL_SDK="$(to_wsl "$SDK_TAR")"
    WSL_DIST="$(to_wsl "$REPO/dist")"
    echo "== Windows 检测到:经 WSL 构建(仓库与 SDK 用 ext4,避免 9P 慢 IO)=="
    wsl.exe -u root bash -c "set -e; BUILD_IPK_INNER=1 sh '$WSL_REPO/tools/build-ipk.sh' '$WSL_SDK' '$WSL_DIST' '$WSL_REPO'"
    exit 0
fi

# ---------- Linux 本体 ----------
SDK_TAR="${1:?用法: build-ipk.sh <SDK的tar.zst> [输出目录] [仓库根]}"
OUT="${2:-$(pwd)/dist}"
SRC="${3:-$(cd "$(dirname "$0")/.." && pwd)}"

# SDK 完整性:已知版本对官方 sha256,未知版本警告跳过
case "$(basename "$SDK_TAR")" in
    *24.10.8*) WANT="ac4a0405d2eea821b06f93c14ba13ffa90ad0457648903df7dde02570027ab21" ;;
    *) WANT=""; echo "(警告:未知 SDK 版本,跳过 sha256 校验)" ;;
esac
if [ -n "$WANT" ]; then
    if ! echo "$WANT  $SDK_TAR" | sha256sum -c - >/dev/null 2>&1; then
        echo "✗ SDK sha256 不匹配: $SDK_TAR"
        exit 1
    fi
    echo "SDK sha256 校验通过"
fi

# 依赖:有 apt 就自动补齐。apt 源按项目惯例切国内镜像(见 porting-notes 的镜像实测)
if command -v apt-get >/dev/null 2>&1 && [ "$(id -u)" = "0" ]; then
    sed -i.bak -E 's#http://(cn\.archive|archive|security)\.ubuntu\.com#http://mirrors.aliyun.com#g' \
        /etc/apt/sources.list /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list 2>/dev/null || true
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        flex bison zstd unzip build-essential libncurses-dev libssl-dev \
        gettext rsync git python3 file >/dev/null
    echo "依赖就绪(apt)"
fi
for t in make gcc g++ gawk flex bison gettext git python3 rsync zstd unzip file tar; do
    command -v "$t" >/dev/null 2>&1 || { echo "✗ 缺构建依赖: $t(请先安装)"; exit 1; }
done

# 构建目录持久化(~/openwrt-dsh-build):SDK 解压与 feeds 克隆是大头,只做一次;
# 重跑只刷新源码副本 + git pull feeds。想从零重来:删掉该目录即可。
BUILD="$HOME/openwrt-dsh-build"
mkdir -p "$BUILD"

if [ ! -f "$BUILD/sdk/include/toplevel.mk" ]; then
    echo "== 解压 SDK =="
    rm -rf "$BUILD/sdk"
    mkdir "$BUILD/sdk"
    tar -I zstd -xf "$SDK_TAR" -C "$BUILD/sdk" --strip-components=1
fi

# 源码拷进 ext4 再构建;build-sdk.sh 按自身位置定位仓库,所以跑副本
echo "== 拷入源码 =="
rm -rf "$BUILD/repo"
cp -r "$SRC" "$BUILD/repo"

# feeds:必须 base+packages+luci 全装。luci 的依赖(liblua/rpcd/ucode/uhttpd…)
# 住在 base/packages feed 里,只装 luci 会让 lucihttp 们在缺 lua 头文件的状态下
# 硬编必死(24.10.8 实测,详见 docs/porting-notes.md §13)。首次克隆大,耐心。
#
# 已就绪就跳过更新:SDK 的 feed 锁定在发布版本(detached HEAD),重跑 update
# 的 git pull 会报 "not currently on a branch" 而失败——锁版本本就不该追新。
if [ -f "$BUILD/sdk/feeds/luci.index" ] && [ -f "$BUILD/sdk/feeds/base.index" ] \
    && [ -f "$BUILD/sdk/feeds/packages.index" ]; then
    echo "== feeds 已就绪(锁定 24.10.8,跳过更新)=="
else
    echo "== feeds(base packages luci,首次克隆较慢)=="
    (
        cd "$BUILD/sdk"
        ./scripts/feeds update base packages luci
        ./scripts/feeds install base packages luci
    )
fi

echo "== 编译 =="
# 部分成功也留住产物:core 过了 luci 挂时,core 的 ipk 照样收集,失败码最后再返
set +e
sh "$BUILD/repo/tools/build-sdk.sh" "$BUILD/sdk" x86_64
BUILD_RC=$?
set -e

echo "== 收集产物 → $OUT =="
mkdir -p "$OUT"
# 只收自家的包:构建时 SDK 会顺带编出整个依赖闭包(libc/luci-base/rpcd/
# 全部 i18n 语言包…),那些是官方仓库的包,不该混进我们的发布物
find "$BUILD/sdk/bin/packages" "$BUILD/sdk/bin/targets" \
    -name 'openwrt-dsh_*.ipk' \
    -exec cp -f {} "$OUT/" \; 2>/dev/null
ls -lh "$OUT"/openwrt-dsh_*.ipk 2>/dev/null || true

if [ "$BUILD_RC" -ne 0 ]; then
    echo "✗ 构建失败(已生成的 ipk 见上;重跑只做增量)"
    exit "$BUILD_RC"
fi
