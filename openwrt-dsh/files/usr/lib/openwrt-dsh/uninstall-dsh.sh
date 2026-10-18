#!/bin/sh
# openwrt-dsh 引擎：卸载 dsh 任务脚本
# 用法: uninstall-dsh.sh [keep|purge]（默认 keep）
# 由 task.sh 包裹执行（锁 + 状态落盘 + 日志重定向），也可手动直跑观察输出。
# 卸载语义（与安装同一套幂等三原则：先探测后动手 / 失败零损伤 / 可重跑）：
#   keep  = 只移除 dsh 本体（npm 产物）与版本标记，保留托管 Node 运行时——
#           重装时运行时直接复用，免重新下载数百 MB（路由器上最常走的路）
#   purge = 连整个托管运行时目录（<install_dir>/runtime）一起移除，释放全部空间
# 边界：
#   - 优先 npm uninstall -g（正常修剪 dsh 独占依赖；npm uninstall 是本地操作，不联网），
#     npm 跑不了/跑失败时直接清目录兜底
#   - 不动 opkg 管的文件：/usr/bin/dsh wrapper、profile.d、LuCI 页面都随 openwrt-dsh 包走，
#     卸载 dsh 后 wrapper 再被调用会提示「dsh 尚未安装」
#   - 不动用户 HOME 下的 dsh 配置与凭据
set -u

MODDIR="$(cd "$(dirname "$0")" && pwd)"
. "$MODDIR/lib.sh"
. "$MODDIR/runtime.sh"

MODE="${1:-keep}"
case "$MODE" in keep|purge) : ;; *) echo "非法参数:$MODE(用法: uninstall-dsh.sh [keep|purge])" >&2; exit 64 ;; esac

INSTALL_ROOT="$(odw_install_dir)"
RUNTIME="$(odw_runtime_dir)"

echo "== openwrt-dsh 任务:uninstall(卸载 dsh,模式:$MODE)=="
echo "安装根目录:$INSTALL_ROOT"

# 与 install-dsh.sh §3 同源的 npm 执行环境（垫片 execPath 坑：npm 生态会裸用
# process.execPath，必须让真身可直拉或在 libexec 垫真身）。没条件跑 npm 返回非 0，
# 调用方走直接清理兜底——卸载不许因为 npm 半残而失败
run_npm_uninstall() { # run_npm_uninstall <运行时目录>
    local d="$1" node_bin npm_cli lexec ldexec
    npm_cli="$d/lib/node_modules/npm/bin/npm-cli.js"
    node_bin="$d/bin/node"
    [ -f "$npm_cli" ] || return 1
    [ -x "$node_bin" ] || return 1
    ( :; "$node_bin" -v >/dev/null 2>&1; ST=$?; :; [ "$ST" -eq 0 ] ) 2>/dev/null || return 1
    export PATH="$d/bin:$PATH"
    if [ -x "$d/bin/node.bin" ]; then
        lexec="$d/libexec"
        mkdir -p "$lexec" 2>/dev/null
        rm -f "$lexec/node"
        ln "$d/bin/node.bin" "$lexec/node" 2>/dev/null || cp "$d/bin/node.bin" "$lexec/node"
        # 环境只允许 libstdc++ 专属目录(lstd)——与 install 的 prepare_runtime 同语义。
        # 本函数不被 prepare_runtime 包着,ODW_LDEXEC_ENV 恒空,旧写法默认落到 $d/lib:
        # 整个 lib(含自带 libgcc_s)进了 LD_LIBRARY_PATH,此后本脚本 exec 的每个
        # busybox 工具(rm/ls/sleep/ps)在老 musl 机(22.03)上概率性段错误——
        # rm 段错误会让「已移除版本标记」变成谎言,文件根本没删掉(2026-10-17 双容器
        # 实测,详见 porting-notes §4;24.10 系统库较新不触发,极易漏测)
        if [ -d "$d/lib/lstd" ]; then
            ldexec="$d/lib/lstd"
        else
            ldexec="$d/lib"
        fi
        # 极简机(无系统 libgcc_s)才把全 lib 兜底进 env(与 install 的 prepare_runtime 一致)
        if [ ! -e /lib/libgcc_s.so.1 ] && [ ! -e /usr/lib/libgcc_s.so.1 ]; then
            ldexec="$ldexec:$d/lib"
        fi
        if ( :; LD_LIBRARY_PATH="$ldexec" "$lexec/node" -v >/dev/null 2>&1; ST=$?; :; [ "$ST" -eq 0 ] ) 2>/dev/null; then
            export LD_LIBRARY_PATH="$ldexec"
            export PATH="$lexec:$PATH"
            node_bin="$lexec/node"
        fi
    fi
    echo "== npm uninstall -g @deepseek-ai/dsh(修剪 dsh 独占依赖,不联网)=="
    "$node_bin" "$npm_cli" uninstall -g @deepseek-ai/dsh
}

removed=0
if [ "$MODE" = "keep" ]; then
    # dsh 的 npm 产物可能分布在任意一个托管运行时里，逐个扫（通常只有一个）
    for d in "$RUNTIME"/node-v*; do
        [ -d "$d" ] || continue
        present=0
        if [ -e "$d/bin/dsh" ] || [ -L "$d/bin/dsh" ] || [ -d "$d/lib/node_modules/@deepseek-ai/dsh" ]; then
            present=1
        fi
        [ "$present" -eq 1 ] || continue
        removed=1
        echo "== 卸载 dsh:$d =="
        if ! run_npm_uninstall "$d"; then
            echo "  (npm 修剪未执行或失败,走直接清理兜底)"
        fi
        # 直接清理兜底：不管 npm 成败都扫一遍（幂等；npm 半残/安装中断的残局也覆盖）
        for p in "$d/bin/dsh" \
                 "$d/bin/dsh-subprocess-local" \
                 "$d/lib/node_modules/@deepseek-ai/dsh" \
                 "$d/lib/node_modules/@deepseek-ai/dsh-subprocess-local"; do
            if [ -e "$p" ] || [ -L "$p" ]; then
                rm -rf "$p"
                echo "  已移除 $p"
            fi
        done
        rmdir "$d/lib/node_modules/@deepseek-ai" 2>/dev/null || :
    done
fi

# 版本标记必清：状态页快路径读它，不清 LuCI 会一直显示已安装。
# 删除后必须复核:rm 曾在毒环境下段错误导致「已移除」谎报(见上方 ldexec 注释),宁红勿假绿
if [ -e "$INSTALL_ROOT/dsh.version" ] || [ -L "$INSTALL_ROOT/dsh.version" ]; then
    rm -f "$INSTALL_ROOT/dsh.version"
    if [ -e "$INSTALL_ROOT/dsh.version" ] || [ -L "$INSTALL_ROOT/dsh.version" ]; then
        echo "✗ 版本标记删除失败:$INSTALL_ROOT/dsh.version(子进程异常?),请手动检查" >&2
        exit 1
    fi
    echo "已移除版本标记:$INSTALL_ROOT/dsh.version"
fi

if [ "$MODE" = "purge" ]; then
    # 路径护栏：只认 <install_dir>/runtime 形态，防御 install_dir 被配成怪值后误删
    case "$RUNTIME" in */runtime) : ;; *) echo "✗ 运行时路径异常,拒绝删除:$RUNTIME" >&2; exit 1 ;; esac
    if [ -d "$RUNTIME" ]; then
        echo "== purge:移除托管 Node 运行时($RUNTIME)=="
        rm -rf "$RUNTIME"
        echo "  已移除 $RUNTIME"
    fi
    # 安装根目录空了顺手清掉；非空说明里面有别的数据，不动
    rmdir "$INSTALL_ROOT" 2>/dev/null && echo "安装根目录已空,一并移除:$INSTALL_ROOT"
fi

if [ "$MODE" = "purge" ]; then
    echo "== 卸载完成:dsh 与托管运行时已移除,空间已释放 =="
elif [ "$removed" -eq 1 ]; then
    echo "== 卸载完成:dsh 已移除(Node 运行时保留,重装免下载;要彻底清空间可再执行 purge)=="
else
    echo "== 卸载完成:未发现已安装的 dsh(幂等,按成功处理)=="
fi
exit 0
