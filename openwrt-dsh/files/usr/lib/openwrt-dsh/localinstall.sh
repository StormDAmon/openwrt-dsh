#!/bin/sh
# openwrt-dsh 引擎：上传包本地安装——把 LuCI「上传安装」传到路由器的 ipk 用 opkg 装上
# 用法: localinstall.sh <ipk路径>
# 由 task.sh 执行；注意 task.sh 会先把本脚本与 lib.sh 复制到 /tmp 再跑：opkg 安装会原地
# 截断替换 /usr/lib/openwrt-dsh 下的脚本，而 ash 是按文件偏移增量读脚本的，原地执行会在
# 替换后读到错位内容（见 docs/porting-notes.md §14，与 selfupdate 同一条铁律）。
# 链路（幂等三原则：先探测后采用 / 失败零损伤 / 可重跑）：
#   1. 路径白名单（只认 LuCI 上传通道的固定落点）+ 包完整性预检（gzip 魔数 + control 成员）
#   2. 版本对照（尽力从包内 control 读版本）：同版本→重装、更低→显式回退（警示但继续，
#      这是用户亲自选的文件，不是自动更新，不沿用 selfupdate 的「只升不降」）
#   3. opkg --force-reinstall --force-downgrade 安装（同版本重装/降级都是本按钮的合法诉求）
#   4. 成功后同步检查缓存、清理上传文件、提示刷新页面；失败保留上传包供重试
set -u

MODDIR="$(cd "$(dirname "$0")" && pwd)"
. "$MODDIR/lib.sh"

IPK="${1:-}"
# 上传包路径白名单：LuCI 的 cgi-io 落盘路径受会话 ACL 按路径管控（luci-base 只放行
# /etc/luci-uploads/*），前端固定写这个文件名；rpcd 桥与 task.sh 已各有一道闸，这里第三道，
# 防手工误调 task.sh 乱装文件
UPLOADED="/etc/luci-uploads/openwrt-dsh-upload.ipk"
[ "$IPK" = "$UPLOADED" ] || { echo "✗ 非法的安装包路径:$IPK(只接受上传通道固定落点 $UPLOADED)"; exit 64; }

echo "== openwrt-dsh 任务:上传包本地安装 =="

WORK="$ODW_STATE_DIR/localinstall-work"
rm -rf "$WORK" 2>/dev/null
mkdir -p "$WORK" 2>/dev/null || { echo "✗ 无法创建工作目录:$WORK(/tmp 可写?)" >&2; exit 1; }
trap 'rm -rf "$WORK" 2>/dev/null' EXIT

# ---- 1) 文件有效性 ----
if [ ! -s "$IPK" ]; then
    echo "✗ 上传的包不存在或为空:$IPK(可能已被清理,请回 LuCI 重新上传)"
    exit 1
fi
# OpenWrt 的 ipk 是 gzip 压缩的 tar。head 取前 2 字节与 gzip 魔数(1f 8b)比对——
# busybox 不一定带 od/xxd，用 printf 八进制转义生成期望值；命令替换会剥尾部换行，
# 1f/8b 都不是换行，比对成立
magic="$(head -c 2 "$IPK" 2>/dev/null)"
if [ "$magic" != "$(printf '\037\213')" ]; then
    echo "✗ 不是有效的 ipk 包（缺 gzip 头）：文件损坏或上传不完整，放弃安装"
    exit 1
fi
if ! tar -tzf "$IPK" 2>/dev/null | grep -q 'control\.tar\.gz'; then
    echo "✗ 不是有效的 ipk 包（缺 control.tar.gz 成员）：放弃安装"
    exit 1
fi
size="$(wc -c < "$IPK" 2>/dev/null)"
echo "包完整性预检通过:$(odw_human "${size:-0}")"

# ---- 2) 版本对照（尽力而为；读不到就跳过，opkg 安装时自会报出版本）----
# 成员名有两种形态（./control.tar.gz 与 control.tar.gz），照 tar 实际列出的用；
# 内层 control 也有 ./ 前缀差异，两个名字一起给 busybox tar，取到哪个算哪个
upver=""
ctl_member="$(tar -tzf "$IPK" 2>/dev/null | grep 'control\.tar\.gz' | head -n 1)"
if [ -n "$ctl_member" ] && tar -xzOf "$IPK" "$ctl_member" > "$WORK/control.tar.gz" 2>/dev/null; then
    upver="$(tar -xzOf "$WORK/control.tar.gz" ./control control 2>/dev/null | \
        sed -n 's/^Version:[ \t]*//p' | head -n 1 | tr -d '\r')"
fi
now="$(odw_pkg_version)"
nowb="$(odw_ver_base "$now")"
upb="$(odw_ver_base "$upver")"
if [ -n "$nowb" ] && [ -n "$upb" ]; then
    echo "当前包版本:$now,上传包版本:$upver"
    if [ "$upb" != "$nowb" ] && ! odw_node_ge "$upb" "$nowb"; then
        echo "⚠ 降级安装:$now → $upver(显式回退,继续执行)"
    else
        # 三段数字相同再看包修订号 -rN：opkg 的降级判定含修订号（0.1.0-r14 → 0.1.0-r8
        # 在它眼里就是降级），警示口径与之一致；任一侧没有 -rN 就按同版本处理
        upr="$(printf '%s' "$upver" | sed -n 's/.*-r\([0-9][0-9]*\)$/\1/p')"
        nowr="$(printf '%s' "$now" | sed -n 's/.*-r\([0-9][0-9]*\)$/\1/p')"
        case "$upr" in ''|*[!0-9]*) upr="" ;; esac
        case "$nowr" in ''|*[!0-9]*) nowr="" ;; esac
        if [ -n "$upr" ] && [ -n "$nowr" ] && [ "$upr" -lt "$nowr" ]; then
            echo "⚠ 降级安装:$now → $upver(显式回退,继续执行)"
        else
            echo "同版本安装(重装),opkg 走 --force-reinstall"
        fi
    fi
else
    echo "当前包版本:${now:-未知},上传包版本:${upver:-未知(将按 opkg 实际安装结果为准)}"
fi

# ---- 3) opkg 安装 ----
command -v opkg >/dev/null 2>&1 || { echo "✗ 找不到 opkg:本动作用于 OpenWrt/iStoreOS"; exit 1; }
# 容器/极简环境没有 /var/lock 时 opkg 会失败;真机 tmpfs 自带,mkdir -p 幂等无害(见 porting-notes §11)
mkdir -p /var/lock 2>/dev/null
echo "== opkg 安装(--force-reinstall --force-downgrade,输出如下) =="
if opkg install --force-reinstall --force-downgrade "$IPK"; then
    # opkg 刚装好:版本标记随包更新,odw_pkg_version 现读即为新版本
    new="$(odw_pkg_version)"
    # 就地修正检查缓存(刚装了可能不同版本),省一次联网检查;不做也不影响正确性,只影响即时显示
    [ -f "$ODW_UPDATE_CACHE" ] && \
        sed -i -e "s/^installed=.*/installed=${new:-}/" -e "s/^available=.*/available=no/" "$ODW_UPDATE_CACHE" 2>/dev/null
    rm -f "$IPK" 2>/dev/null
    echo "== 安装完成:${now:-未知} → ${new:-未知};上传包已清理;刷新浏览器页面加载新版 LuCI 界面 =="
    exit 0
fi
echo "✗ opkg 安装失败(原因见上方 opkg 输出);上传包保留在 $IPK,可修正后重试"
exit 1
