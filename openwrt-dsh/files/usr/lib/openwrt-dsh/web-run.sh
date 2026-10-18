#!/bin/sh
# openwrt-dsh：dsh Web 服务的 procd 前台包装（由 /etc/init.d/openwrt-dsh-web 拉起）
#
# 为什么要有这层壳：procd 的 command 是直接 exec 的 argv，没有 shell 重定向；而
# dsh web 的带令牌访问链接（launch token 每次进程启动随机生成、只存在于内存与
# 启动行 stdout）必须被落盘 rpcd 才能取到给 LuCI「打开」按钮。所以这里以 exec 前
# 重定向的方式把 stdout/stderr 接到 tmpfs 状态文件——exec 之后重定向随 fd 传给
# node 本体，procd 跟踪的 pid 就是 dsh 进程，SIGTERM/kill 语义不走样。
#
# 端口解析（2026-10-20 真机实锤 §25，ODSH_WEB_PORT 由 init 注入）：
#   - 数字 1-65535：固定端口，原样使用（被占由 rpcd 启用前预检拦下，运行期被占
#     则走 dsh 崩溃 → web_error 人话透出）；
#   - auto（未设/非法/旧版固定 3080）：自动选择——在 3081-3099 里取第一个空闲者。
#     为什么不是 3080：dsh 生态自己就吃 3080（宿主控制台/桌面 GUI），且本服务开机
#     序（S99openwrt-dsh-web）排在宿主控制台进程之前，自动抢下 3080 会反过来饿死
#     宿主控制台；为什么段压在 32768 以下：39080 之类落在内核临时端口区
#     （32768-60999），会被出站连接源端口/docker -P 随机占用。
#     为什么每次启动现选、不选好写回 UCI：在 start_service 里写 UCI 会再次触发
#     openwrt-dsh 的 config trigger 重启本服务，往复空转；且端口本就随令牌每次
#     启动重新生效，LuCI 的访问链接以 out.log 启动行为唯一真源，无须记住旧口。
#   - 探测到绑定之间有竞窗（check-then-bind）：输了竞窗 dsh 秒崩，procd respawn
#     会重跑本脚本重新挑选——自愈，不需要额外状态。
#
# 环境变量：
#   ODSH_WEB_PORT  监听端口（UCI openwrt-dsh.web.port；auto = 自动选择）
#   HOME           固定 /root——procd 实例环境不带登录壳的 HOME，dsh 的 DSH_HOME
#                  解析依赖它（porting-notes 垫片/HOME 同源的坑：后台壳里 HOME
#                  不能赌，显式给）
set -u

STATE_DIR=/tmp/openwrt-dsh-web
PORT="${ODSH_WEB_PORT:-auto}"
case "$PORT" in
    ''|*[!0-9]*) PORT="auto" ;;
esac
if [ "$PORT" -lt 1 ] 2>/dev/null || [ "$PORT" -gt 65535 ] 2>/dev/null; then
    PORT="auto"
fi
# 旧版固定默认 3080 并入自动：老 conffile 升级被 opkg 原样保留 port='3080'，
# 正是 2026-10-20 真机撞车现场（§25），不迁移它，自动选端口就永远轮不到
if [ "$PORT" = "3080" ]; then
    PORT="auto"
fi

# 状态目录与日志每次启动清零：out.log 里只保留本次进程的启动行——rpcd 按
# 「服务在运行才读日志」取 URL，陈旧日志不该跨进程存活（旧 token 已随旧进程失效）
if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
    logger -t openwrt-dsh-web "无法创建状态目录 $STATE_DIR，放弃启动"
    exit 1
fi
: > "$STATE_DIR/out.log" 2>/dev/null

if [ "$PORT" = "auto" ]; then
    PORT=""
    p=3081
    while [ "$p" -le 3099 ]; do
        if ! netstat -tln 2>/dev/null | grep -q "[.:]${p}[[:space:]]"; then
            PORT="$p"
            break
        fi
        p=$((p + 1))
    done
    if [ -z "$PORT" ]; then
        # 19 个连号空闲口全缺极难发生；发生了也要让人话进 out.log（status 的
        # web_error 兜底路径按「失败」样式行取尾部）与 syslog
        printf '%s\n' "openwrt-dsh-web: 自动选端口失败：3081-3099 全被占用，请停掉占用这些端口的程序，或在 UCI 手工指定固定端口（openwrt-dsh.web.port）" >> "$STATE_DIR/out.log"
        logger -t openwrt-dsh-web "自动选端口失败：3081-3099 全被占用，请停掉占用这些端口的程序，或在 UCI 手工指定固定端口（openwrt-dsh.web.port）"
        exit 1
    fi
    printf '%s\n' "openwrt-dsh-web: 自动选择监听端口 ${PORT}（3081-3099 第一个空闲）" >> "$STATE_DIR/out.log"
    logger -t openwrt-dsh-web "自动选择监听端口 ${PORT}"
fi

# /usr/bin/dsh 是托管 wrapper（自行解析最新运行时并补 PATH），exec 链到 node 本体；
# --patch overlay 钉 0.0.0.0（见 web-lan.patch.yml 头注释），--no-open 防它在路由器
# 上尝试拉浏览器（headless 机器上 open 包必然失败报错，还会污染日志）
exec /usr/bin/dsh web \
    --patch /usr/share/openwrt-dsh/web-lan.patch.yml \
    --no-open \
    --port "$PORT" \
    >>"$STATE_DIR/out.log" 2>&1
