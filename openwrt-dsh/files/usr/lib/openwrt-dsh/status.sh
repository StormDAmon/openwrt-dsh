#!/bin/sh
# openwrt-dsh 引擎：状态收集（key=value 逐行输出，rpcd 后端/CLI 共用）
# 快路径优先：版本读安装期落盘的标记文件，不拉起 node（LuCI 每 2s 轮询，拉 node 太重）；
# 标记缺失（老安装/手工装）才退慢路径探测并回写标记。

MODDIR="$(cd "$(dirname "$0")" && pwd)"
. "$MODDIR/lib.sh"

INSTALL_ROOT="$(odw_install_dir)"
RUNTIME="$(odw_runtime_dir)"

odw_detect

echo "install_dir=$INSTALL_ROOT"
echo "free=$(odw_free_bytes "$INSTALL_ROOT")"
echo "registry=$(odw_npm_registry)"
echo "min_node=$ODW_MIN_NODE"

# Node 版本:标记 → 运行时目录探测。目录扫描独立于标记(供 dsh 探测与 node_dir 字段用)。
# 取「最新」:新版本 >= 当前才替换(odw_node_ge v newest)——比较方向写反会永远挑中最旧运行时,
# 慢路径的 dsh 探测也会去拉旧目录(LTS 升级链保留旧版本目录,真机升级后必踩)
newest=""
newest_v=""
for d in "$RUNTIME"/node-v*; do
    [ -x "$d/bin/node" ] || continue
    v="${d##*/node-v}"
    case "$v" in ''|*[!0-9.]*) continue ;; esac
    if [ -z "$newest" ] || odw_node_ge "$v" "$newest_v"; then newest="$d"; newest_v="$v"; fi
done
node_v=""
if [ -f "$RUNTIME/node.version" ]; then
    node_v="$(head -n 1 "$RUNTIME/node.version" 2>/dev/null)"
fi
if [ -z "$node_v" ] && [ -x "$newest/bin/node" ]; then
    node_v="$("$newest/bin/node" -v 2>/dev/null)"
    [ -n "$node_v" ] && printf '%s\n' "$node_v" > "$RUNTIME/node.version" 2>/dev/null
fi
echo "node_version=${node_v:-}"
echo "node_dir=${newest:-}"

# dsh 版本:标记 → dsh --version 探测(慢,约 1-2s,只在标记缺失时走一次)
dsh_v=""
if [ -f "$INSTALL_ROOT/dsh.version" ]; then
    dsh_v="$(head -n 1 "$INSTALL_ROOT/dsh.version" 2>/dev/null)"
fi
if [ -z "$dsh_v" ] && [ -x "$newest/bin/dsh" ]; then
    dsh_v="$("$newest/bin/dsh" --version 2>/dev/null)"
    [ -n "$dsh_v" ] && printf '%s\n' "$dsh_v" > "$INSTALL_ROOT/dsh.version" 2>/dev/null
fi
echo "dsh_version=${dsh_v:-}"

# 任务状态
phase="$(odw_state_get phase)"
echo "task_phase=${phase:-idle}"
echo "task_rc=$(odw_state_get rc)"
echo "task_name=$(odw_state_get task)"
echo "task_ts=$(odw_state_get ts)"

# 插件包版本与 GitHub 更新检查缓存——本快照路径绝不联网:
# 包版本第一真源是包自带的版本标记(缺失才退 opkg 库的 mtime 缓存),
# 检查结果只读 odw_update_check 落盘的缓存文件
echo "pkg_version=$(odw_pkg_version)"
uv_status=""; uv_latest=""; uv_avail=""; uv_ts=""
if [ -f "$ODW_UPDATE_CACHE" ]; then
    uv_status="$(sed -n 's/^status=//p' "$ODW_UPDATE_CACHE" 2>/dev/null | head -n 1)"
    uv_latest="$(sed -n 's/^latest=//p' "$ODW_UPDATE_CACHE" 2>/dev/null | head -n 1)"
    uv_avail="$(sed -n 's/^available=//p' "$ODW_UPDATE_CACHE" 2>/dev/null | head -n 1)"
    uv_ts="$(sed -n 's/^ts=//p' "$ODW_UPDATE_CACHE" 2>/dev/null | head -n 1)"
fi
echo "gh_check_status=$uv_status"
echo "gh_latest=$uv_latest"
echo "gh_available=$uv_avail"
echo "gh_check_ts=$uv_ts"

# dsh 运行时检查缓存(同 gh 模式:只读「更新 dsh」前置检查落盘的 dsh-check 缓存,绝不联网)
dv_status=""; dv_latest=""; dv_avail=""; dv_ts=""
if [ -f "$ODW_DSH_CACHE" ]; then
    dv_status="$(sed -n 's/^status=//p' "$ODW_DSH_CACHE" 2>/dev/null | head -n 1)"
    dv_latest="$(sed -n 's/^latest=//p' "$ODW_DSH_CACHE" 2>/dev/null | head -n 1)"
    dv_avail="$(sed -n 's/^available=//p' "$ODW_DSH_CACHE" 2>/dev/null | head -n 1)"
    dv_ts="$(sed -n 's/^ts=//p' "$ODW_DSH_CACHE" 2>/dev/null | head -n 1)"
fi
echo "dsh_check_status=$dv_status"
echo "dsh_latest=$dv_latest"
echo "dsh_available=$dv_avail"
echo "dsh_check_ts=$dv_ts"
