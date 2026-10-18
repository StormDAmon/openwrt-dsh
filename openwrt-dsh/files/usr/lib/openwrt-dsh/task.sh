#!/bin/sh
# openwrt-dsh 引擎：任务包裹（互斥锁 + 状态落盘 + 日志重定向）
# 用法: task.sh install|update|doctor [dsh版本] | uninstall [keep|purge] | selfupdate | migrate <目标目录> | localinstall <上传包路径>
# 由 rpcd 后端或 CLI 后台拉起； LuCI 轮询 status 读状态与日志尾部。

MODDIR="$(cd "$(dirname "$0")" && pwd)"
. "$MODDIR/lib.sh"

ACTION="${1:-install}"
case "$ACTION" in install|update|doctor|uninstall|selfupdate|migrate|localinstall) : ;; *) echo "用法: task.sh install|update|doctor [dsh版本] | uninstall [keep|purge] | selfupdate | migrate <目标目录> | localinstall <上传包路径>" >&2; exit 64 ;; esac
# 版本参数(可空)白名单:会拼进 npm install 规格,只放行安全字符
VER="${2:-}"
IPKPATH=""
if [ "$ACTION" = "migrate" ]; then
    # 迁移目标：绝对路径 + 禁 . .. 段。白名单比版本串宽（目标路径来自我们自己的
    # 选目录弹窗，含空格/中文的合法目录名不能拒）；深校验与嵌套/冲突/空间护栏
    # 全在 migrate-dsh.sh，这里只拦明显乱传的
    TARGET="$VER"
    case "$TARGET" in
        /*) : ;;
        *) [ -n "$TARGET" ] && echo "非法的迁移目标:$TARGET(需以 / 开头的绝对路径)" >&2
           [ -n "$TARGET" ] || echo "用法: task.sh migrate <目标目录>" >&2
           exit 64 ;;
    esac
    T="${TARGET%/}"; [ -n "$T" ] || T="/"
    case "$T" in
        "/.."|*/../*|*/..|"/."|*/./*) echo "非法的迁移目标:$TARGET(不允许 . .. 路径段)" >&2; exit 64 ;;
    esac
elif [ "$ACTION" = "localinstall" ]; then
    # 上传包固定落点白名单：LuCI 上传通道（cgi-io）的落盘路径受会话 ACL 按路径管控
    # （luci-base 只放行 /etc/luci-uploads/*），前端固定写这一个文件名，引擎不接受其他
    # 任何路径——三道闸（rpcd 桥 / 这里 / localinstall.sh）都按它校验，防误装任意文件
    IPKPATH="$VER"
    case "$IPKPATH" in
        /etc/luci-uploads/openwrt-dsh-upload.ipk) : ;;
        *) echo "非法的上传包路径:$IPKPATH(只接受 /etc/luci-uploads/openwrt-dsh-upload.ipk)" >&2; exit 64 ;;
    esac
else
    case "$VER" in
        ''|*[!A-Za-z0-9.@/_-]*) [ -n "$VER" ] && { echo "非法的 dsh 版本串:$VER" >&2; exit 64; } ;;
    esac
fi

mkdir -p "$ODW_STATE_DIR"

# 互斥：mkdir 原子锁。锁在而状态不是 running = 上次被 kill -9 的残锁，抢回来。
# selfupdate 重入趟（ODW_SELF_RUN=1）不抢锁——锁是 exec 前那趟拿的，目录还在；
# 但 exec 会清掉原进程的 trap，这里必须补回退出清理，否则锁泄漏
if [ -n "${ODW_SELF_RUN:-}" ]; then
    trap 'rmdir "$ODW_LOCK_DIR" 2>/dev/null' EXIT
else
    if ! mkdir "$ODW_LOCK_DIR" 2>/dev/null; then
        phase="$(odw_state_get phase)"
        if [ "$phase" != "running" ]; then
            rmdir "$ODW_LOCK_DIR" 2>/dev/null
            if ! mkdir "$ODW_LOCK_DIR" 2>/dev/null; then
                echo "另一个任务似乎刚启动,请稍后在 LuCI 查看进度" >&2
                exit 2
            fi
        else
            echo "已有任务在跑(phase=running),请稍后再试" >&2
            exit 2
        fi
    fi
    trap 'rmdir "$ODW_LOCK_DIR" 2>/dev/null' EXIT
fi

: > "$ODW_LOG_FILE"
odw_state_write running "" "$ACTION"
case "$ACTION" in
    uninstall)
        # uninstall 走独立脚本(第 2 参是 keep|purge 档位)
        sh "$MODDIR/uninstall-dsh.sh" "${VER:-keep}" > "$ODW_LOG_FILE" 2>&1
        rc=$?
        ;;
    selfupdate)
        if [ -n "${ODW_SELF_RUN:-}" ]; then
            # 重入趟:已在 /tmp 副本里(MODDIR 指向副本),放心跑——opkg 随便替换引擎目录
            sh "$MODDIR/selfupdate.sh" > "$ODW_LOG_FILE" 2>&1
            rc=$?
            # 副本使命完成就清场(自身正在执行的文件被删是安全的:ash 持有已打开的 inode)
            rm -rf "$MODDIR" 2>/dev/null
        else
            # 第一趟:opkg 会截断替换 /usr/lib/openwrt-dsh 下的脚本(含正在运行的 task.sh
            # 与 selfupdate.sh),而 ash 是按文件偏移增量读脚本的——替换后后续行读到的是
            # 新文件的错位字节,收尾的状态落盘会执行成垃圾。所以把 task.sh/lib.sh/
            # selfupdate.sh 复制到 /tmp 后 exec 副本重入,自此运行期不再读引擎目录里的
            # 任何脚本(exec 之后原 task.sh 的余行永远不会被执行)(见 porting-notes §14)
            T="$ODW_STATE_DIR/selfrun"
            rm -rf "$T" 2>/dev/null
            if mkdir -p "$T" 2>/dev/null && cp "$MODDIR"/lib.sh "$MODDIR"/task.sh "$MODDIR"/selfupdate.sh "$T/" 2>/dev/null; then
                ODW_SELF_RUN=1
                export ODW_SELF_RUN
                exec sh "$T/task.sh" selfupdate
            fi
            echo "✗ 无法准备自更新副本($T 不可写?)" >&2
            rc=1
        fi
        ;;
    migrate)
        # 迁移安装目录(第 2 参是目标目录;独立脚本,详见 migrate-dsh.sh)
        sh "$MODDIR/migrate-dsh.sh" "$TARGET" > "$ODW_LOG_FILE" 2>&1
        rc=$?
        ;;
    localinstall)
        # 上传包本地安装(第 2 参是上传包固定落点;独立脚本 localinstall.sh)。与 selfupdate
        # 同一条铁律:opkg 会原地截断替换 /usr/lib/openwrt-dsh 下的脚本(含正在运行的
        # task.sh 本身),ash 按偏移增量读脚本会读到错位字节——第一趟先把要用的脚本复制到
        # /tmp 后 exec 副本重入,自此运行期不再读引擎目录(见 porting-notes §14)
        if [ -n "${ODW_SELF_RUN:-}" ]; then
            # 重入趟:已在 /tmp 副本里(MODDIR 指向副本),放心跑——opkg 随便替换引擎目录
            sh "$MODDIR/localinstall.sh" "$IPKPATH" > "$ODW_LOG_FILE" 2>&1
            rc=$?
            # 副本使命完成就清场(自身正在执行的文件被删是安全的:ash 持有已打开的 inode)
            rm -rf "$MODDIR" 2>/dev/null
        else
            T="$ODW_STATE_DIR/selfrun"
            rm -rf "$T" 2>/dev/null
            if mkdir -p "$T" 2>/dev/null && cp "$MODDIR"/lib.sh "$MODDIR"/task.sh "$MODDIR"/localinstall.sh "$T/" 2>/dev/null; then
                ODW_SELF_RUN=1
                export ODW_SELF_RUN
                exec sh "$T/task.sh" localinstall "$IPKPATH"
            fi
            echo "✗ 无法准备本地安装副本($T 不可写?)" >&2
            rc=1
        fi
        ;;
    *)
        # install/update/doctor 仍进 install-dsh.sh 主链路
        sh "$MODDIR/install-dsh.sh" "$@" > "$ODW_LOG_FILE" 2>&1
        rc=$?
        ;;
esac
if [ "$rc" -eq 0 ]; then
    odw_state_write done 0 "$ACTION"
else
    odw_state_write failed "$rc" "$ACTION"
fi
exit "$rc"
