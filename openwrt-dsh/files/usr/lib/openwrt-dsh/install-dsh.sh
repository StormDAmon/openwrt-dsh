#!/bin/sh
# openwrt-dsh 引擎：安装/更新 dsh 任务脚本
# 用法: install-dsh.sh <install|update|doctor> [dsh版本,默认 @latest]
# 由 task.sh 包裹执行（锁 + 状态落盘 + 日志重定向），也可手动直跑观察输出。
# doctor = 校验修复：不下载、不跑 npm，对已装 dsh 做自愈/原生件顶替/实载校验/标记重建，
# 给「照官方文档裸跑 npm i -g @deepseek-ai/dsh」的用户当收尾步骤用（musl 机裸装必留病根）。
# 链路（坑位说明见 docs/porting-notes.md）：
#   0. 前置检查（架构/libc/磁盘/下载工具）
#   1. Node 运行时保障：托管目录挑满足下限的最新版本；没有则升级到最新 LTS
#      （musl 机取 unofficial 构建 + Alpine 三件套运行库 + 三级垫片）
#   2. 老 musl 机 PT_INTERP/DT_NEEDED 双补丁（救 22.03 系真机直拉段错误）
#   3. npm 经 libexec 真身执行（垫片 execPath 坑）+ --allow-scripts 放行原生件
#   4. 残留 bin/dsh 清理（npm 对非自有既有 bin 一律 EEXIST 拒装）
#   5. 安装失败时 koffi 定向重编一次再重试；装完 koffi/node-pty 实载校验（宁可红不给假绿）
#   6. musl 机 node-pty 换自带 musl 原生件 + 真实 pty 探针
#   7. 运行时级 npmrc（allow-scripts + registry）：官方安装路径的尽力等价（§3b）
set -u

MODDIR="$(cd "$(dirname "$0")" && pwd)"
. "$MODDIR/lib.sh"
. "$MODDIR/runtime.sh"

ACTION="${1:-install}"
case "$ACTION" in install|update|doctor) : ;; *) echo "非法动作:$ACTION(用法: install-dsh.sh install|update|doctor [dsh版本])" >&2; exit 64 ;; esac
DSH_SPEC="${2:-@deepseek-ai/dsh@latest}"
case "$DSH_SPEC" in
    @deepseek-ai/dsh@*) : ;;
    *[!A-Za-z0-9.@/_-]*) echo "✗ 非法的 dsh 版本串:$DSH_SPEC" >&2; exit 64 ;;
    @*) DSH_SPEC="@deepseek-ai/dsh$DSH_SPEC" ;;
    *) DSH_SPEC="@deepseek-ai/dsh@$DSH_SPEC" ;;
esac

INSTALL_ROOT="$(odw_install_dir)"
RUNTIME="$(odw_runtime_dir)"
MARKER_NODE="$RUNTIME/node.version"
MARKER_DSH="$INSTALL_ROOT/dsh.version"

if [ "$ACTION" = "doctor" ]; then
    echo "== openwrt-dsh 任务:doctor(校验修复已装 dsh,不改版本) =="
else
    echo "== openwrt-dsh 任务:$ACTION(dsh $DSH_SPEC) =="
fi
echo "安装根目录:$INSTALL_ROOT"

# ---- 0) 前置检查 ----
SYS="$(uname -s 2>/dev/null || echo unknown)"
ARCH="$(uname -m 2>/dev/null || echo unknown)"
if [ "$SYS" != "Linux" ] || [ "$ARCH" != "x86_64" ]; then
    echo "✗ 不支持的平台:$SYS/$ARCH(目前仅 Linux x86_64,ARM 见 docs/roadmap.md)"
    exit 1
fi
odw_detect_musl
if [ -z "$ODW_MUSL" ]; then
    echo "提示:本机不是 musl(libc=glibc)。引擎按 musl 优化但兼容 glibc(走官方 Node 构建)"
fi
# doctor 不下载不装大件,空间/下载工具预检只属 install/update
if [ "$ACTION" != "doctor" ]; then
    free="$(odw_free_bytes "$INSTALL_ROOT")"
    if [ -n "$free" ] && [ "$free" -lt 314572800 ] 2>/dev/null; then
        echo "✗ $INSTALL_ROOT 所在分区可用空间不足(约 $(odw_human "$free"),建议 ≥ 300MB)。"
        echo "  路由器 overlay 常放不下;在 LuCI「设置」里把安装目录改到数据盘后重试"
        exit 1
    fi
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        echo "✗ 无 curl/wget,无法下载(opkg install curl 后重试)"
        exit 1
    fi
fi

# ---- 1) Node 运行时保障(doctor 只自愈+挑选,绝不触发下载:没装过就明说,不悄悄拉 300MB) ----
if [ "$ACTION" = "doctor" ]; then
    echo "== Node 运行时检查(doctor 只校验自愈,不下载;要求 >= v$ODW_MIN_NODE) =="
    odw_shim_selfheal "$RUNTIME"
    odw_pick_runtime "$RUNTIME" "$ODW_MIN_NODE"
    if [ -z "$ODW_NODE_DIR" ]; then
        echo "✗ 没有可用的托管运行时(尚未安装,或低于 v$ODW_MIN_NODE):先执行 install/update"
        exit 1
    fi
else
    if ! odw_ensure_runtime "$ODW_MIN_NODE"; then
        echo "✗ Node 运行时未能就绪(见上方日志)"
        exit 1
    fi
fi
CHOOSE="$ODW_NODE_DIR"
CHOOSE_V="$ODW_NODE_VER"

# doctor 校验的对象是「已装 dsh」:运行时在而 dsh 不在(卸载 keep 之后/纯运行时)必须
# 明确判失败,绝不能一路走到尾还报「doctor 通过」并把版本标记写成「未知」
# (状态页快路径读标记,会把「未知」一直显示成已装——实测踩过)
if [ "$ACTION" = "doctor" ] && [ ! -e "$CHOOSE/bin/dsh" ]; then
    echo "✗ 所选运行时里没有 dsh($CHOOSE/bin/dsh 缺失):doctor 用于校验修复已装的 dsh,尚未安装请先执行 install/update"
    exit 1
fi

# ---- 2) 选定运行时的收尾准备(幂等):lstd/补丁,回填 ODW_LDEXEC_ENV ----
odw_prepare_runtime "$CHOOSE"

# ---- 3) npm 执行环境:bin 前插 PATH(生命周期脚本裸调 node 受益);musl 机的垫片是 ----
# exec 自带 ld-musl 显式拉起,node 的 process.execPath 落在加载器上而非 node.bin;npm 生态里
# spawnSync(process.execPath, -e, …) 一类调用(koffi cnoke 校验预构建)会把 -e 当程序路径必败
# (OpenWrt 24.10 容器实测)。且 npm 不把 execPath 所在目录前插 PATH,真身与垫片同住 bin/ 时
# 裸 node 必落回垫片——故造一个只含真身的 libexec/(node.bin 硬链接)、前插 PATH,npm 经它执行:
# 裸 node 与 process.execPath 双双落回真身。硬链每次重建:真身可能上轮刚被补丁换过 inode。
# 真身能不能直拉必须先探测——系统 musl 加载器太老的机器上直跑就是段错误(22.03 真机实测,
# 退出码 139;上面第 2 步的补丁专救这类机器,救不回的就全程留在垫片上,代价仅 cnoke 绕不过)
NODE_BIN="$CHOOSE/bin/node"
NPM_CLI="$CHOOSE/lib/node_modules/npm/bin/npm-cli.js"
export PATH="$CHOOSE/bin:$PATH"
if [ -x "$CHOOSE/bin/node.bin" ]; then
    LEXEC="$CHOOSE/libexec"
    mkdir -p "$LEXEC"
    rm -f "$LEXEC/node"
    ln "$CHOOSE/bin/node.bin" "$LEXEC/node" 2>/dev/null || cp "$CHOOSE/bin/node.bin" "$LEXEC/node"
    # 与 prepare_runtime 同语义:环境只进 lstd(libstdc++ 专属),全 lib 仅无系统 libgcc_s 的
    # 极简机兜底(§4:自带 libgcc_s 进环境会毒化同机动态 busybox 子进程)
    if [ -d "$CHOOSE/lib/lstd" ]; then
        LDEXEC="${ODW_LDEXEC_ENV:-$CHOOSE/lib/lstd}"
    else
        LDEXEC="${ODW_LDEXEC_ENV:-$CHOOSE/lib}"
    fi
    if [ -x "$LEXEC/node" ] && ( :; LD_LIBRARY_PATH="$LDEXEC" "$LEXEC/node" -v >/dev/null 2>&1; ST=$?; :; [ "$ST" -eq 0 ] ) 2>/dev/null; then
        export LD_LIBRARY_PATH="$LDEXEC"
        export PATH="$LEXEC:$PATH"
        NODE_BIN="$LEXEC/node"
    else
        echo "提示:真身直拉探测失败,npm 全程改经运行垫片(koffi 预构建校验可能绕不过)"
    fi
fi
REGISTRY="$(odw_npm_registry)"
if [ -n "$REGISTRY" ]; then
    export NPM_CONFIG_REGISTRY="$REGISTRY"
    echo "npm registry:$REGISTRY(可在 LuCI 设置或 UCI openwrt-dsh.core.npm_registry 修改)"
fi

# ---- 3b) 运行时级 npmrc:让「照官方文档裸跑 npm i -g @deepseek-ai/dsh」也装得上原生件 ----
# npm >= 11.19 起全局安装默认跳过未登记的依赖生命周期脚本(allowScripts 闸)。24.10 容器
# 实测(npm 11.19.0):「=true」无论 CLI 还是 npmrc 都不生效(npm 只认包名列表,通配 * 也不
# 认),老版 npm 视未知配置无害。列表 = 当前 dsh 依赖树里带生命周期脚本的包;dsh 未来换
# 依赖时 npm 会重新打 warn 提示,不影响成败。放行的意义:让 koffi 的 cnoke 预构建校验在
# 安装期就真跑起来(缺构建工具等问题显式暴露),而不是跳过后只靠装后探针兜底。
# 定义必须先于使用(§4 教训:set -u 下引用未赋值变量即死)
ODW_ALLOW_SCRIPTS="@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs"
# 作用域仅托管运行时里这份 npm(npm 的全局配置 = <prefix>/etc/npmrc);顺手把 UCI 的
# npm 源也写进去,官方路径同样走镜像
NPMRC="$CHOOSE/etc/npmrc"
if [ ! -f "$NPMRC" ]; then
    mkdir -p "$CHOOSE/etc" 2>/dev/null
    {
        echo "; openwrt-dsh: 放行依赖生命周期脚本(koffi/node-pty 等原生件需要;npm >= 11.19 默认跳过)"
        echo "; 列表形态经 24.10 容器实测生效;=true 与 * 均无效。dsh 换依赖后按 npm warn 提示补"
        echo "allow-scripts=$ODW_ALLOW_SCRIPTS"
        [ -n "$REGISTRY" ] && echo "registry=$REGISTRY"
    } > "$NPMRC" 2>/dev/null && echo "已写 $NPMRC(allow-scripts+registry,官方安装路径的尽力等价)"
fi

RC=0
# doctor 到此为止:运行时/补丁/npmrc 就绪后直接进底下的实载校验,不下载不重装
if [ "$ACTION" != "doctor" ]; then
RUN_LINE="\"$NODE_BIN\" \"$NPM_CLI\" install -g $DSH_SPEC"
RUN_LINE="$RUN_LINE --allow-scripts=$ODW_ALLOW_SCRIPTS"

# ---- 4) 残留 bin 清理:上轮安装在 bin 链接落盘后中途暴毙(npm 段错误/被杀,回滚半途 ----
# 而废)会留下孤儿 bin/dsh。npm 全局装 bin 前必查既有项:非「指向本包内目标」的符号链接或
# 实文件一律 EEXIST 拒装且不随重装自愈——重装从此次次卡死。装前移除(有效链接也会原样重建)
if [ -e "$CHOOSE/bin/dsh" ] || [ -L "$CHOOSE/bin/dsh" ]; then
    rm -rf "$CHOOSE/bin/dsh"
    echo "清理上轮安装残留的 bin/dsh(npm 对非自有既有 bin 一律 EEXIST 拒装)"
fi

echo "== 安装 dsh($DSH_SPEC)=="
echo "----"
sh -c "$RUN_LINE"
RC=$?

# ---- 5) 安装失败:十有八九是 koffi 预构建加载失败又没编过。定向补编它的 cnoke,成了重试一次 ----
if [ "$RC" -ne 0 ]; then
    KOFFI=""
    for c in "$CHOOSE/lib/node_modules/@deepseek-ai/dsh/node_modules/koffi" "$CHOOSE/lib/node_modules/koffi"; do
        [ -f "$c/package.json" ] && KOFFI="$c" && break
    done
    if [ -n "$KOFFI" ] && [ -x "$NODE_BIN" ] && command -v cmake >/dev/null 2>&1 && command -v make >/dev/null 2>&1; then
        echo "== koffi 定向重编:$KOFFI =="
        if ( cd "$KOFFI" && "$NODE_BIN" ./cnoke.cjs -P . -D src/koffi --prebuild --release ); then
            echo "koffi 重编完成,重试安装"
            sh -c "$RUN_LINE"
            RC=$?
        fi
    fi
fi
fi # install/update 才跑 npm;doctor 落到底下的实载校验

# koffi 实载校验:装完必须能 require(一键安装的硬指标;失败宁可红不给假绿)
KOFFI=""
for c in "$CHOOSE/lib/node_modules/@deepseek-ai/dsh/node_modules/koffi" "$CHOOSE/lib/node_modules/koffi"; do
    [ -f "$c/package.json" ] && KOFFI="$c" && break
done
if [ -z "$KOFFI" ]; then
    [ "$RC" -eq 0 ] && echo "提示:koffi 目录未找到(上游可能已不依赖,跳过校验)"
elif "$NODE_BIN" -e "require(process.argv[1])" "$KOFFI" 2>&1; then
    echo "koffi 校验通过($KOFFI)"
elif [ "$ACTION" = "doctor" ] && [ -x "$NODE_BIN" ] && command -v cmake >/dev/null 2>&1 && command -v make >/dev/null 2>&1 && ( cd "$KOFFI" && "$NODE_BIN" ./cnoke.cjs -P . -D src/koffi --prebuild --release ); then
    # doctor 修复语义:实载失败十有八九是预构建加载失败,定向重编一次后复测,过了照样给绿
    echo "koffi 定向重编完成,复测"
    if "$NODE_BIN" -e "require(process.argv[1])" "$KOFFI" 2>&1; then
        echo "koffi 校验通过(重编后,$KOFFI)"
    else
        echo "✗ koffi 实载失败(报错如上),任务判失败"
        RC=1
    fi
else
    echo "✗ koffi 实载失败(报错如上),任务判失败;musl 机多为缺 libstdc++,glibc 机看 dlopen 细节"
    RC=1
fi

# ---- 6) node-pty:musl 机的自带预构建是 glibc 链接(懒解析能 dlopen、一调用 open/fork ----
# 即段错误)——用随包下发的 musl 原生件顶替;顶替后跑真实 pty 探针(开窗+回显),顶替过仍失败
# 即判任务失败(OpenWrt 容器实测:glibc 预构建在 musl 上 pty.open 立 SIGSEGV,node22/24 同)
NPTY=""
for c in "$CHOOSE/lib/node_modules/@deepseek-ai/dsh/node_modules/node-pty" "$CHOOSE/lib/node_modules/node-pty"; do
    [ -f "$c/package.json" ] && NPTY="$c" && break
done
PTY_ASSET="$ODW_ASSET_DIR/node-pty/linux-x64/pty.node"
PTY_FIXED=""
if [ -n "$NPTY" ] && [ -n "$ODW_MUSL" ] && [ -f "$PTY_ASSET" ]; then
    if mkdir -p "$NPTY/prebuilds/linux-x64" && cp "$PTY_ASSET" "$NPTY/prebuilds/linux-x64/pty.node"; then
        PTY_FIXED=1
        echo "node-pty 已换用自带 musl 原生件($PTY_ASSET)"
    fi
fi
if [ -n "$NPTY" ]; then
    PROBE_JS="$(mktemp /tmp/odw-pty.XXXXXX)"
    cat > "$PROBE_JS" <<'PTYPROBE'
const pty = require(process.argv[2]);
const t = pty.spawn("/bin/sh", [], { name: "xterm", cols: 80, rows: 24 });
let out = "";
t.onData((d) => { out += d; });
t.write("echo ODW_PTY_PROBE_OK\r\n");
setTimeout(() => { try { t.kill(); } catch (e) {} process.exit(out.includes("ODW_PTY_PROBE_OK") ? 0 : 3); }, 1500);
PTYPROBE
    if "$NODE_BIN" "$PROBE_JS" "$NPTY" >/dev/null 2>&1; then
        echo "node-pty 实载通过(pty 开窗与回显正常)"
    else
        echo "✗ node-pty 实载失败:dsh 终端不可用(报错见上,探针输出已静默)"
        if [ -n "$PTY_FIXED" ]; then
            echo "  已顶替自带 musl 原生件仍失败,任务判失败"
            RC=1
        else
            echo "  本机无可用自带件(非 musl 或架构暂缺),仅提示不改判;dsh 其余功能不受影响"
        fi
    fi
    rm -f "$PROBE_JS"
fi

# ---- 7) LAN 设置解锁补丁（默认涂抹，2026-10-21 拍板撤销开关，§26 补记）----
# dsh 的设置页只认本机回环打开的浏览器页面，LAN IP 打开时「设置→模型」等整页拒载
# （porting-notes §26）。曾有的 UCI web.remote_settings 开关已删——LAN 使用是主场景，
# 设置页必须开箱可用；这里在 npm 装完/doctor 校验后无条件重涂单点补丁——npm
# install/update 会整包替换 dsh 文件冲掉补丁，所以每次任务都要重涂。
# 补丁失败只提示不判失败：不能拖死安装主链路（status 的 web_remote_state 会显示
# 补丁实况，锚点失效时重跑本动作即可）
if [ "$RC" -eq 0 ]; then
    echo "== LAN 设置解锁补丁(默认涂抹)=="
    if sh "$MODDIR/web-patch.sh" apply; then
        # 涂完必须重启 Web 服务：/plugins 包体的 rev 由文件 mtime/ctime/size 派生，
        # 只在 Host 启动扫描时计算，响应又带 immutable 一年缓存——不重启的话 boot
        # 清单还是旧 rev 旧包体，浏览器永远拿不到补后代码（§26 补记）。令牌随重启
        # 更换，LuCI 状态行会刷新出新的访问链接
        if command -v ubus >/dev/null 2>&1 && command -v jsonfilter >/dev/null 2>&1 && \
           [ -x /etc/init.d/openwrt-dsh-web ] && \
           ubus call service list 2>/dev/null | jsonfilter -e '@["openwrt-dsh-web"].instances.web.running' 2>/dev/null | grep -q true; then
            echo "Web 服务运行中:重启以加载补丁(令牌将更换,访问链接以状态行为准)"
            /etc/init.d/openwrt-dsh-web restart 2>/dev/null
        fi
    else
        echo "提示:补丁未完全就位(明细如上),局域网页面的设置解锁可能不生效;可稍后重跑「校验修复已装 dsh」"
    fi
fi

# ---- 收尾:dsh --version 落版本标记(LuCI 状态页快路径读标记,不重复拉起 node)----
# /usr/bin/dsh 由 ipk 以 wrapper 形式提供(files/usr/bin/dsh):npm 产物的 bin/dsh 走
# #!/usr/bin/env node,软链在无 PATH 的调用方(cron/procd/非登录 SSH)里起不来,wrapper
# 自带运行时解析;它归 opkg 管,引擎不再插手
if [ "$RC" -eq 0 ]; then
    # 入口自检:--version 拿不到输出就判失败,绝不落「未知」标记(宁红勿假绿)
    DSH_V="$("$CHOOSE/bin/dsh" --version 2>/dev/null)"
    if [ -z "$DSH_V" ]; then
        echo "✗ dsh 入口自检失败($CHOOSE/bin/dsh --version 无输出),任务判失败"
        RC=1
    fi
fi
if [ "$RC" -eq 0 ]; then
    mkdir -p "$INSTALL_ROOT"
    printf '%s\n' "$DSH_V" > "$MARKER_DSH" 2>/dev/null || true
    printf '%s\n' "$CHOOSE_V" > "$MARKER_NODE" 2>/dev/null || true
    if [ "$ACTION" = "doctor" ]; then
        echo "== doctor 通过:dsh $DSH_V(node v$CHOOSE_V),入口/原生件实载均可用 =="
    else
        echo "== 完成:dsh $DSH_V(node v$CHOOSE_V)=="
    fi
else
    echo "== 任务失败(退出码 $RC),见上方日志 =="
fi
exit "$RC"
