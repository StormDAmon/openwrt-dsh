#!/bin/sh
# openwrt-dsh 引擎：软件包自更新——查 GitHub 最新发布，下载 ipk，校验后 opkg 安装
# 用法: selfupdate.sh（无参数）
# 由 task.sh 执行；注意 task.sh 会先把本脚本与 lib.sh 复制到 /tmp 再跑：opkg 安装会原地
# 截断替换 /usr/lib/openwrt-dsh 下的脚本，而 ash 是按文件偏移增量读脚本的，原地执行会在
# 替换后读到错位内容（见 docs/porting-notes.md §14）。
# 链路（幂等三原则：先探测后采用 / 失败零损伤 / 可重跑）：
#   1. 现查最新发布（不信「检查更新」的缓存——缓存可能陈旧）
#   2. 比版本：已装且不落后就收工
#   3. 定位资产：sha256sums.txt 优先（发布脚本固定上传，内有确切 ipk 名+哈希）；
#      没有再按命名规则推 openwrt-dsh_<版本>-r1_all.ipk（release.sh 每次发布把
#      PKG_RELEASE 重置为 1，所以 tag 对应的 ipk 文件名是确定的）
#   4. 下载（带进度）+ sha256 校验
#   5. opkg 安装（只替换插件文件，不碰 <install_dir> 下的 dsh 与 Node 运行时）
set -u

MODDIR="$(cd "$(dirname "$0")" && pwd)"
. "$MODDIR/lib.sh"

WORK="$ODW_STATE_DIR/selfupdate-work"
rm -rf "$WORK" 2>/dev/null
mkdir -p "$WORK" 2>/dev/null || { echo "✗ 无法创建工作目录:$WORK(/tmp 可写?)" >&2; exit 1; }
trap 'rm -rf "$WORK" 2>/dev/null' EXIT

echo "== openwrt-dsh 任务:软件包自更新(GitHub Releases) =="

# ---- 1) 现查最新发布 ----
echo "== 查询 GitHub 最新发布 =="
out="$(odw_update_check 2>/dev/null)"
ck_status="$(printf '%s\n' "$out" | sed -n 's/^status=//p' | head -n 1)"
ck_latest="$(printf '%s\n' "$out" | sed -n 's/^latest=//p' | head -n 1)"
ck_error="$(printf '%s\n' "$out" | sed -n 's/^error=//p' | head -n 1)"
if [ "$ck_status" != "ok" ] || [ -z "$ck_latest" ]; then
    echo "✗ ${ck_error:-GitHub 检查失败}"
    exit 1
fi
latest_base="$(odw_ver_base "$ck_latest")"
case "$latest_base" in
    [0-9]*.[0-9]*.[0-9]*) : ;;
    *) echo "✗ 异常版本串:$ck_latest" >&2; exit 1 ;;
esac

# ---- 2) 比版本 ----
now="$(odw_pkg_version)"
now_base="$(odw_ver_base "$now")"
case "$now_base" in
    [0-9]*.[0-9]*.[0-9]*) : ;;
    *) now_base="" ;;
esac
if [ -n "$now_base" ]; then
    echo "当前包版本:$now,目标版本:$ck_latest"
    if [ "$now_base" = "$latest_base" ]; then
        echo "已是最新,无需更新"
        exit 0
    fi
    # 本机比远端最新发布还新(fork 指向旧 tag/上游回滚)时不降级:更新只升不降,
    # 真要回退请手工 opkg 装历史 ipk
    if ! odw_node_ge "$latest_base" "$now_base"; then
        echo "本机包版本($now)比远端最新发布($ck_latest)还新,跳过更新(不降级)"
        exit 0
    fi
else
    echo "本机包版本未知(版本标记与 opkg 均无记录),目标版本:$ck_latest(将安装为 opkg 托管)"
fi

# ---- 3) 定位资产 ----
slug="$(odw_gh_slug)"
base="$ODW_GH_BASE/$slug/releases/download/$ck_latest"
sums="$WORK/sha256sums.txt"
ipk_name=""
ipk_sha=""
if odw_fetch "$(odw_gh_url "$base/sha256sums.txt")" "$sums" 2>/dev/null; then
    # sha256sums.txt 行形如 "<hash>  <文件名>"（二进制模式多一个 * 前缀，都兼容）
    ipk_name="$(awk '{ n = $2; sub(/^\*/, "", n); if (n ~ /^openwrt-dsh_.*_all\.ipk$/) { print n; exit } }' "$sums" 2>/dev/null)"
    if [ -n "$ipk_name" ]; then
        ipk_sha="$(awk -v n="$ipk_name" '{ f = $2; sub(/^\*/, "", f); if (f == n) { print $1; exit } }' "$sums" 2>/dev/null)"
        echo "资产定位:发布清单 sha256sums.txt → $ipk_name"
    fi
fi
if [ -z "$ipk_name" ]; then
    echo "未取到发布清单,按命名规则推断:openwrt-dsh_${latest_base}-r1_all.ipk(将跳过哈希校验)"
    ipk_name="openwrt-dsh_${latest_base}-r1_all.ipk"
    ipk_sha=""
fi

# ---- 4) 下载 + 校验 ----
ipk="$WORK/$ipk_name"
if ! odw_dl "$(odw_gh_url "$base/$ipk_name")" "$ipk"; then
    echo "✗ ipk 下载失败(网络不通或加速代理失效;资产页: $base)"
    exit 1
fi
if [ -n "$ipk_sha" ] && command -v sha256sum >/dev/null 2>&1; then
    printf '%s  %s\n' "$ipk_sha" "$ipk" > "$WORK/check.txt"
    if ! sha256sum -c "$WORK/check.txt" >/dev/null 2>&1; then
        echo "✗ sha256 校验不通过:下载不完整或被篡改,放弃安装"
        exit 1
    fi
    echo "sha256 校验通过"
else
    echo "(无哈希或无 sha256sum 工具,跳过校验)"
fi

# ---- 5) opkg 安装 ----
command -v opkg >/dev/null 2>&1 || { echo "✗ 找不到 opkg:本动作用于 OpenWrt/iStoreOS"; exit 1; }
# 容器/极简环境没有 /var/lock 时 opkg 会失败;真机 tmpfs 自带,mkdir -p 幂等无害(见 porting-notes §11)
mkdir -p /var/lock 2>/dev/null
echo "== opkg 安装(输出如下) =="
if opkg install "$ipk"; then
    # opkg 刚装好新版:版本标记随包更新,odw_pkg_version 现读即为新版本
    # (opkg 库兜底路径的 pkg.version 缓存也按库 mtime 自动失效重算)
    new="$(odw_pkg_version)"
    # 就地修正检查缓存(刚装了新版),省一次联网检查;不做也不影响正确性,只影响即时显示
    [ -f "$ODW_UPDATE_CACHE" ] && \
        sed -i -e "s/^installed=.*/installed=${new:-}/" -e "s/^available=.*/available=no/" "$ODW_UPDATE_CACHE" 2>/dev/null
    echo "== 更新完成:${now:-未知} → ${new:-$latest_base};刷新浏览器页面加载新版 LuCI 界面 =="
    exit 0
fi
echo "✗ opkg 安装失败(原因见上方 opkg 输出)"
exit 1
