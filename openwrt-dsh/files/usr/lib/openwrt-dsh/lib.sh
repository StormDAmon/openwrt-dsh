#!/bin/sh
# openwrt-dsh 引擎公共库（busybox ash 兼容，全体 POSIX 语法）
# 由 task.sh / rpcd 后端 / cli 入口 source。
# 踩坑背景见 docs/porting-notes.md，勿凭直觉改动探测与垫片顺序。

ODW_HOME="${ODW_HOME:-/usr/lib/openwrt-dsh}"
ODW_STATE_DIR="${ODW_STATE_DIR:-/tmp/openwrt-dsh}"
ODW_STATE_FILE="$ODW_STATE_DIR/state"
ODW_LOCK_DIR="$ODW_STATE_DIR/lock"
ODW_LOG_FILE="$ODW_STATE_DIR/task.log"
ODW_ASSET_DIR="${ODW_ASSET_DIR:-/usr/share/openwrt-dsh}"

# 包自带版本标记（随 ipk 装入；内容形如 0.1.0-r6，release.sh 与 VERSION/Makefile 同步）。
# 插件版本的第一真源：跟着实际部署的文件走——scp 手工部署、opkg 库无记录也报得准
ODW_VERSION_FILE="${ODW_VERSION_FILE:-/usr/lib/openwrt-dsh/version}"

# dsh 依赖树(undici@8 / pi-ai 等)要求的 node 下限；不足时升级链会把运行时升到最新 LTS
ODW_MIN_NODE="${ODW_MIN_NODE:-22.19.0}"

# —— 下载源（顺序即尝试顺序，任一成功即止）——
# glibc 官方构建镜像（本包在 OpenWrt 上恒为 musl，仅保留作完整性/在 Alpine chroot 测试用）
ODW_NODE_MIRRORS="
https://registry.npmmirror.com/-/binary/node
https://mirrors.huaweicloud.com/nodejs
https://mirrors.tuna.tsinghua.edu.cn/nodejs-release
https://mirrors.aliyun.com/nodejs-release
https://nodejs.org/dist
"
# musl unofficial 构建镜像：这棵树只有 npmmirror 镜像（清华/华为云/阿里云/USTC 实测 404，
# 它们只镜像官方 dist），官方源兜底
ODW_NODE_MIRRORS_MUSL="
https://registry.npmmirror.com/-/binary/node-unofficial-builds
https://cdn.npmmirror.com/binaries/node-unofficial-builds
https://unofficial-builds.nodejs.org/download/release
"
# musl 版 node 的运行库（libstdc++/libgcc/musl 本体）取自 Alpine main 仓库。
# 固定 v3.21 系列（GCC 14.2 / musl 1.2.5，符号够新；已发布系列的仓库永久保留不失踪）。
# 阿里云放首位（清华/USTC 对 busybox wget 的 UA 回 403，实测踩过）
ODW_ALPINE_SERIES="v3.21"
ODW_ALPINE_MIRRORS="
https://mirrors.aliyun.com/alpine
https://mirrors.tuna.tsinghua.edu.cn/alpine
https://mirrors.ustc.edu.cn/alpine
https://mirrors.huaweicloud.com/alpine
https://dl-cdn.alpinelinux.org/alpine
"

# —— 配置（/etc/config/openwrt-dsh，UCI）——
# 安装根目录默认 /opt/openwrt-dsh：路由器 overlay 常偏小，装不下 300MB 级运行时+dsh，
# iStoreOS 用户典型做法是装在数据盘；改 UCI 即可迁移。所有大文件都在 INSTALL_DIR 下。
# 经 uci CLI 读取（不经 /lib/functions.sh 的 config_load：部分版本与 set -u 脚本有兼容
# 风险，且子壳调用更干净）；值缺省或显式为空都回默认
odw_config_get() { # odw_config_get <option> <默认值>
    local key="$1" def="$2" val=""
    if command -v uci >/dev/null 2>&1; then
        val="$(uci -q get "openwrt-dsh.core.$key" 2>/dev/null)"
    fi
    printf '%s' "${val:-$def}"
}

odw_install_dir() {
    local d
    d="$(odw_config_get install_dir /opt/openwrt-dsh)"
    d="${d%/}"
    [ -n "$d" ] || d="/opt/openwrt-dsh"
    printf '%s' "$d"
}

odw_runtime_dir() {
    printf '%s/runtime' "$(odw_install_dir)"
}

odw_npm_registry() {
    odw_config_get npm_registry "https://registry.npmmirror.com"
}

# —— 环境探测（输出 key=value 逐行）——
odw_detect() {
    echo "arch=$(uname -m 2>/dev/null || echo unknown)"
    echo "kernel=$(uname -r 2>/dev/null)"
    . /etc/openwrt_release 2>/dev/null && echo "distro=${DISTRIB_DESCRIPTION:-}"
    if ls /lib/ld-musl-*.so.1 >/dev/null 2>&1; then echo "libc=musl"; else echo "libc=glibc"; fi
    if command -v curl >/dev/null 2>&1; then echo "curl=yes"; else echo "curl=no"; fi
    if command -v wget >/dev/null 2>&1; then echo "wget=yes"; else echo "wget=no"; fi
    # 支持面：仅 linux x86_64（musl unofficial 构建与自带 musl 原生件都只有 x86_64）。
    # ARM 路由器明确报不支持（见 docs/roadmap.md），不假装能装
    if [ "$(uname -s 2>/dev/null)" = "Linux" ] && [ "$(uname -m 2>/dev/null)" = "x86_64" ]; then
        echo "supported=yes"
    else
        echo "supported=no"
    fi
}

odw_free_bytes() { # 分区可用空间（字节）；目录不存在时查其父目录
    local d="$1"
    while [ ! -d "$d" ] && [ "$d" != "/" ]; do d="$(dirname "$d")"; done
    df -Pk "$d" 2>/dev/null | awk 'NR==2 { print $4 * 1024 }'
}

# —— 任务状态（/tmp/openwrt-dsh/state，key=value 逐行）——
odw_state_get() { # <key>
    sed -n "s/^$1=//p" "$ODW_STATE_FILE" 2>/dev/null | tail -n 1
}

odw_state_write() { # <phase> <rc> <task>
    mkdir -p "$ODW_STATE_DIR"
    {
        echo "phase=$1"
        echo "rc=$2"
        echo "task=$3"
        echo "ts=$(date +%s)"
    } > "$ODW_STATE_FILE"
}

# —— 日志 ——
odw_log() {
    printf '%s %s\n' "$(date '+%m-%d %H:%M:%S')" "$*"
}

odw_log_tail() { # <字节数>：取日志尾部（按块读，避免整文件进内存）
    local n="${1:-16384}" size
    [ -f "$ODW_LOG_FILE" ] || return 0
    size="$(wc -c < "$ODW_LOG_FILE" 2>/dev/null || echo 0)"
    [ "$size" -gt "$n" ] && tail -c "$n" "$ODW_LOG_FILE" || cat "$ODW_LOG_FILE"
}

# —— 下载（带进度，curl/wget 统一自绘单行进度；自 SH_NODE_HELPERS 原样移植）——
odw_human() {
    awk -v n="${1:-0}" 'BEGIN { split("B KB MB GB TB", u, " "); i = 1;
        while (n >= 1024 && i < 5) { n /= 1024; i++ }
        printf (i == 1 ? "%d %s" : "%.1f %s"), n, u[i] }'
}

odw_dl() { # odw_dl <url> <out> [期望字节数]
    local url="$1" out="$2" want="${3:-0}" pid="" size=0 prev=0 rate=0 t0 t1 dt t_start rc
    printf '  开始下载 %s\n' "$url"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 2 -m 1800 -o "$out" "$url" &
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 120 -O "$out" "$url" &
    else
        return 127
    fi
    pid=$!
    t0=$(date +%s)
    t_start=$t0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
        size="$(stat -c %s "$out" 2>/dev/null || wc -c 2>/dev/null < "$out" || echo 0)"
        t1=$(date +%s); dt=$((t1 - t0))
        if [ "$dt" -gt 0 ]; then rate=$(( (size - prev) / dt )); prev=$size; t0=$t1; fi
        if [ "${want:-0}" -gt 0 ] 2>/dev/null; then
            printf '\r  %s / %s (%d%%) · %s/s   ' "$(odw_human "$size")" "$(odw_human "$want")" "$((size * 100 / want))" "$(odw_human "$rate")"
        else
            printf '\r  %s · %s/s   ' "$(odw_human "$size")" "$(odw_human "$rate")"
        fi
    done
    rc=0; wait "$pid" || rc=$?
    size="$(stat -c %s "$out" 2>/dev/null || wc -c 2>/dev/null < "$out" || echo 0)"
    dt=$(( $(date +%s) - t_start ))
    if [ "$rc" -ne 0 ]; then printf '\r\033[K  下载失败(退出码 %s)\n' "$rc"; return "$rc"; fi
    [ "$dt" -lt 1 ] && dt=1
    printf '\r\033[K  下载完成:%s,用时 %ss,均速 %s/s\n' "$(odw_human "$size")" "$dt" "$(odw_human $((size / dt)))"
    return 0
}

odw_fetch() { # 静默取小响应(版本索引等;大文件一律走 odw_dl 带进度)。用法: odw_fetch <url> <out>
    if command -v curl >/dev/null 2>&1; then curl -fsSL --retry 2 -m 60 -o "$2" "$1"; return $?
    elif command -v wget >/dev/null 2>&1; then wget -q -T 60 -O "$2" "$1"; return $?
    else return 127; fi
}

# —— 版本比较:odw_node_ge <a> <b> = a >= b(三段数字;不依赖 sort -V,busybox 不一定有)——
odw_node_ge() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        split(a, x, "."); split(b, y, ".")
        for (i = 1; i <= 3; i++) {
            if ((x[i] + 0) > (y[i] + 0)) exit 0
            if ((x[i] + 0) < (y[i] + 0)) exit 1
        }
        exit 0
    }'
}

# —— 软件包自更新（LuCI「检查更新/立即更新」与 CLI check-update/selfupdate 共用）——
# 刻意不走 api.github.com：CN 网络常不可达，且加速代理服务基本只代 github.com。
# 改用 releases/latest 的 302 → /releases/tag/vX.Y.Z 重定向取最新 tag（curl -w 取终址，
# 代理转发后的终址同样含 tag，解析与代理形态无关）；资产与校验文件都在
# releases/download/<tag>/ 固定路径下。ODW_GH_BASE 仅供测试时把整棵树指到本地假源。
ODW_GH_SLUG_DEFAULT="StormDAmon/openwrt-dsh"
ODW_GH_BASE="${ODW_GH_BASE:-https://github.com}"
ODW_OPKG_DB="${ODW_OPKG_DB:-/usr/lib/opkg/status}"
ODW_UPDATE_CACHE="$ODW_STATE_DIR/update-check"

odw_gh_slug() { # 仓库 owner/repo（UCI github_repo 可指 fork）；白名单校验，防注入 URL
    local s
    s="$(odw_config_get github_repo "$ODW_GH_SLUG_DEFAULT")"
    case "$s" in
        ''|*[!A-Za-z0-9._-]*|*/*/*) s="" ;;
        */*) : ;;
        *) s="" ;;
    esac
    printf '%s' "${s:-$ODW_GH_SLUG_DEFAULT}"
}

odw_gh_url() { # odw_gh_url <github 绝对路径 url>：可选加速代理（UCI github_proxy）前缀形态
    local p
    p="$(odw_config_get github_proxy '')"
    p="$(printf '%s' "$p" | tr -d ' ')"
    p="${p%/}"
    case "$p" in
        https://*|http://*) printf '%s/%s\n' "$p" "$1" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

odw_pkg_version() { # 本插件包版本（形如 0.1.0-r6；两个来源都没有时输出空）
    # 第一真源 = 包自带的版本标记（本地小文件，读它与缓存命中同价；随 ipk 装入，
    # 跟着「实际部署的文件」走——scp 手工部署、opkg 库无记录也报得准）。
    # 标记缺失（老版 ipk 装的/未带标记的部署）才退 opkg 库：纯 awk 毫秒级
    # （status 2s 轮询的快路径纪律），结果按库 mtime 缓存进 /tmp——opkg 动过库
    # （安装/升级）缓存立即失效重算
    local v=""
    if [ -r "$ODW_VERSION_FILE" ]; then
        v="$(head -n 1 "$ODW_VERSION_FILE" 2>/dev/null | tr -d '\r')"
    fi
    if [ -n "$v" ]; then
        printf '%s' "$v"
        return 0
    fi
    local cache="$ODW_STATE_DIR/pkg.version"
    if [ -f "$cache" ] && [ -f "$ODW_OPKG_DB" ] && [ "$cache" -nt "$ODW_OPKG_DB" ]; then
        head -n 1 "$cache" 2>/dev/null
        return 0
    fi
    if [ -r "$ODW_OPKG_DB" ]; then
        v="$(awk '/^Package: openwrt-dsh$/ { f = 1; next } /^Package: / { f = 0 } f && /^Version:/ { sub(/^Version:[ \t]*/, ""); print; exit }' "$ODW_OPKG_DB" 2>/dev/null)"
    fi
    if [ -z "$v" ] && command -v opkg >/dev/null 2>&1; then
        v="$(opkg info openwrt-dsh 2>/dev/null | sed -n 's/^Version:[ \t]*//p' | head -n 1)"
    fi
    v="$(printf '%s' "$v" | tr -d '\r')"
    mkdir -p "$ODW_STATE_DIR" 2>/dev/null
    printf '%s\n' "$v" > "$cache" 2>/dev/null
    printf '%s' "$v"
}

odw_ver_base() { # 0.1.0-r3 → 0.1.0 / v0.2.0 → 0.2.0（比较只看三段数字，-rN 包修订不参与）
    printf '%s' "${1%%-*}" | tr -d 'v'
}

odw_gh_latest_tag() { # 最新发布 tag（stdout = vX.Y.Z）；失败 rc!=0
    # 尝试顺序：配了加速代理先走代理（配它就是因为直连不通），失败再试直连兜底。
    # 单次限 12s，两跳共 24s——rpcd 同步应答要赶在 LuCI rpc 超时（30s）内回来
    local top="$ODW_GH_BASE/$(odw_gh_slug)/releases/latest"
    local p url eff tag try
    p="$(odw_config_get github_proxy '')"
    p="$(printf '%s' "$p" | tr -d ' ')"
    p="${p%/}"
    case "$p" in
        https://*|http://*) : ;;
        *) p="" ;;
    esac
    for try in proxy direct; do
        if [ "$try" = "proxy" ]; then
            [ -n "$p" ] || continue
            url="$p/$top"
        else
            url="$top"
        fi
        if command -v curl >/dev/null 2>&1; then
            # 不带 -f：老版 curl(22.03 的 7.x)在 --fail 时可能连 -w 输出都不给；
            # 终址正则本身就兜住了 404/私有仓（解析不出 tag 即失败），无需 -f
            eff="$(curl -sSL -m 12 -o /dev/null -w '%{url_effective}' "$url" 2>/dev/null)"
        elif command -v wget >/dev/null 2>&1; then
            # OpenWrt 的 wget 是 uclient-fetch（无 -S，但会跟 302；无 TLS 支持时 https 直接
            # 失败——本包硬依赖 curl，这条只是 curl 被移除后的兜底）——取终页正文，从
            # GitHub 标签页 canonical/og:url 必含的 /releases/tag/<tag> 提取；
            # Alpine 的 busybox wget 同样适用
            eff="$(wget -q -T 12 -O - "$url" 2>/dev/null | grep -oE '/releases/tag/v[0-9][0-9.]*' | head -n 1)"
        else
            return 127
        fi
        tag="$(printf '%s\n' "${eff:-}" | sed -n 's#.*/releases/tag/\(v[0-9][0-9.]*\).*#\1#p' | head -n 1)"
        if [ -n "$tag" ]; then
            printf '%s\n' "$tag"
            return 0
        fi
    done
    return 1
}

odw_update_check() { # 完整检查（联网，秒级）。输出 key=value 并写缓存；不抛错，错误走字段
    # 只由「检查更新」按钮 / rpcd check_update / CLI / selfupdate 调用；
    # status 轮询只读本函数落盘的缓存（ODW_UPDATE_CACHE），绝不联网——快路径纪律同版本标记
    local now nowb latest="" avail="unknown" status="error" err="" ts
    now="$(odw_pkg_version)"
    nowb="$(odw_ver_base "$now")"
    case "$nowb" in [0-9]*.[0-9]*.[0-9]*) : ;; *) nowb="" ;; esac
    latest="$(odw_gh_latest_tag 2>/dev/null)"
    case "$latest" in
        v[0-9]*.[0-9]*.[0-9]*)
            status="ok"
            if [ -z "$nowb" ]; then
                avail="unknown" # 版本标记与 opkg 库都没有（完全裸部署），无法比较，交用户决断
            elif [ "${latest#v}" != "$nowb" ] && odw_node_ge "${latest#v}" "$nowb"; then
                avail="yes"
            else
                avail="no"
            fi
            ;;
        *)
            err="无法获取 GitHub 最新发布（网络不通、被墙、仓库未公开或还没有发布；可在设置里配加速代理）"
            # 保留上次成功取到的 latest：一次网络抖动不该抹掉「已知有新版」
            [ -f "$ODW_UPDATE_CACHE" ] && latest="$(sed -n 's/^latest=//p' "$ODW_UPDATE_CACHE" 2>/dev/null | head -n 1)"
            ;;
    esac
    ts="$(date +%s)"
    mkdir -p "$ODW_STATE_DIR" 2>/dev/null
    {
        echo "status=$status"
        echo "installed=$now"
        echo "latest=$latest"
        echo "available=$avail"
        echo "error=$err"
        echo "ts=$ts"
    } > "$ODW_UPDATE_CACHE" 2>/dev/null
    printf 'status=%s\ninstalled=%s\nlatest=%s\navailable=%s\nerror=%s\nts=%s\n' \
        "$status" "$now" "$latest" "$avail" "$err" "$ts"
}

# —— dsh 运行时更新检查(LuCI「更新 dsh」按钮的前置检查,与插件包检查分开)——
# 「更新 dsh」更新的是 npm 包 @deepseek-ai/dsh,查的是 npm 源(UCI npm_registry,默认
# npmmirror)而非 GitHub——插件包(本 ipk)走 GitHub Releases,dsh 走 npm registry,
# 两条检查链的源、缓存、入口全部分开,别混。
ODW_DSH_CACHE="$ODW_STATE_DIR/dsh-check"

odw_dsh_latest() { # npm 源上 @deepseek-ai/dsh 的最新稳定版(stdout = x.y.z;失败 rc!=0)
    # scoped 包路径必须把 / 编码成 %2F(registry 约定,npmmirror/npmjs 同形);
    # /latest 端点只回 latest dist-tag 的单个 manifest,几 KB,比整包文档(MB 级)轻。
    # 单跳限 12s:本函数跑在同步 rpc 应答里,要赶在 LuCI rpc 超时(30s)内回来
    local reg body
    reg="$(odw_npm_registry)"
    reg="${reg%/}"
    if command -v curl >/dev/null 2>&1; then
        body="$(curl -fsSL -m 12 "$reg/@deepseek-ai%2Fdsh/latest" 2>/dev/null)" || return 1
    elif command -v wget >/dev/null 2>&1; then
        body="$(wget -q -T 12 -O - "$reg/@deepseek-ai%2Fdsh/latest" 2>/dev/null)" || return 1
    else
        return 127
    fi
    printf '%s' "$body" | sed -n 's/.*"version"[ \t]*:[ \t]*"\([^"]*\)".*/\1/p' | head -n 1
}

odw_dsh_check() { # 完整检查(联网,秒级):npm 源最新版 vs 本机 dsh 版本标记
    # 只由 rpcd check_dsh(LuCI「更新 dsh」前置)调用;status 轮询只读本函数落盘的
    # 缓存(ODW_DSH_CACHE),绝不联网——快路径纪律同插件包的 update-check
    local cur="${1:-}" latest="" avail="unknown" status="error" err="" ts nowb latestb
    latest="$(odw_dsh_latest 2>/dev/null)"
    case "$latest" in
        [0-9]*.[0-9]*.[0-9]*)
            status="ok"
            # 两边都归一到三段数字主干再比(odw_ver_base 剥 -后缀/v 前缀)。只归一
            # 本机一边会误报:本机装 0.2.0-rc.2 且 latest 恰为 0.2.0-rc.2 时,
            # 原串 "0.2.0-rc.2" != 主干 "0.2.0" 恒成立,会把同版本判成「有更新」
            nowb="$(odw_ver_base "$cur")"
            case "$nowb" in [0-9]*.[0-9]*.[0-9]*) : ;; *) nowb="" ;; esac
            latestb="$(odw_ver_base "$latest")"
            if [ -z "$nowb" ]; then
                avail="unknown" # 版本标记缺失(裸装等),无法比较,交用户决断
            elif [ "$latestb" != "$nowb" ] && odw_node_ge "$latestb" "$nowb"; then
                avail="yes"
            else
                # 相等(已是最新)或本机更新(装过 beta 等)都不给更新按钮
                avail="no"
            fi
            ;;
        *)
            err="无法获取 npm 源上的最新版本(网络不通或源不可达;可在设置里换 npm 源)"
            # 保留上次成功取到的 latest:一次网络抖动不该抹掉「已知有新版」
            [ -f "$ODW_DSH_CACHE" ] && latest="$(sed -n 's/^latest=//p' "$ODW_DSH_CACHE" 2>/dev/null | head -n 1)"
            ;;
    esac
    ts="$(date +%s)"
    mkdir -p "$ODW_STATE_DIR" 2>/dev/null
    {
        echo "status=$status"
        echo "installed=$cur"
        echo "latest=$latest"
        echo "available=$avail"
        echo "error=$err"
        echo "ts=$ts"
    } > "$ODW_DSH_CACHE" 2>/dev/null
    printf 'status=%s\ninstalled=%s\nlatest=%s\navailable=%s\nerror=%s\nts=%s\n' \
        "$status" "$cur" "$latest" "$avail" "$err" "$ts"
}
