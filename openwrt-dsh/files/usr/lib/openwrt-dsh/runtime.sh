#!/bin/sh
# openwrt-dsh 引擎：Node 运行时引导（musl 机三件套运行库 + 三级垫片 + PT_INTERP/DT_NEEDED 双补丁 + LTS 升级链）
# 踩坑背景与"为什么必须这么做"见 docs/porting-notes.md —— 本文件的每个顺序、每级探测都有
# 真机/容器实测依据，勿凭直觉精简。

# musl 判别（OpenWrt/iStoreOS/Alpine）：glibc 系没有 /lib/ld-musl-*.so.1。
# 结果进全局 ODW_MUSL（"1"=musl）
odw_detect_musl() {
    ODW_MUSL=""
    for f in /lib/ld-musl-*.so.1; do [ -e "$f" ] && ODW_MUSL=1; done
}

# —— musl 目标机的运行库三件套：拉 Alpine 的 libstdc++/libgcc/musl 三个小包（合计约 1.4MB），
# 解出 .so 放进 <目标目录>/lib。修两类实况：
#   ① 库完全缺失（裸 OpenWrt）:「Error loading shared library libstdc++.so.6」；
#   ② 库在但太旧:「Error relocating ... symbol not found」（musl 按符号名直查、忽略版本;
#     OpenWrt 22.03 的 libstdc++ 裁掉 dual ABI，没有 std::__cxx11 符号）。opkg install
#     libstdcpp6 只回「已安装」不升级，包管理器救不了——所以自带。
# 文件名从 APKINDEX 索引推「包名-版本.apk」（目录列表的 HTML 转义各镜像不一——阿里云把 +
# 转成 &#43;——直解析不可靠）。apk 本体是多段 gzip tar，**符号链接条目排在实体文件之前**，
# tar 按序解压会在建链时报错并整体失败（MSYS GNU tar 实测复现；busybox 1.36 与新版 GNU tar
# 不复现）——解压报错不中断，实体文件解出来即可，链接随后显式 ln -sf 补齐（幂等）。
# 全部实体文件就位才算该镜像成功；一个镜像整链失败自动换下一个。函数体在子壳里跑：
# 意外失败都等于该镜像不成功（换下一个），不脏外层变量
odw_fix_runtime_libs() { (
    dest="$1"
    idx="$(mktemp /tmp/odw-aidx.XXXXXX)" || return 1
    work="$(mktemp -d /tmp/odw-alp.XXXXXX)" || { rm -f "$idx"; return 1; }
    for base in $ODW_ALPINE_MIRRORS; do
        odw_fetch "$base/$ODW_ALPINE_SERIES/main/x86_64/APKINDEX.tar.gz" "$idx" || continue
        [ -s "$idx" ] || continue
        rm -rf "$work/idx"
        mkdir -p "$work/idx"
        tar -xzf "$idx" -C "$work/idx" 2>/dev/null || continue
        [ -f "$work/idx/APKINDEX" ] || continue
        ok=1
        # musl 包 = Alpine 的动态加载器 ld-musl-x86_64.so.1 + libc 本体：垫片用它显式拉起
        # node，node 与全部依赖就都落在自带这套上，与目标机系统库零耦合
        # （APKINDEX 坑：V: 行必须随 P: 行重置，否则前排 libcrypto3 的版本会污染下一包）
        for p in libstdc++ libgcc musl; do
            apk="$(awk -F: -v want="$p" '$1 == "P" { pkg = $2; ver = "" } $1 == "V" { ver = $2 } pkg == want && ver != "" { print want "-" ver ".apk"; exit }' "$work/idx/APKINDEX")"
            [ -n "$apk" ] || { ok=""; break; }
            odw_dl "$base/$ODW_ALPINE_SERIES/main/x86_64/$apk" "$work/$p.apk" || { ok=""; break; }
            rm -rf "$work/$p"
            mkdir -p "$work/$p"
            if ! tar -xzf "$work/$p.apk" -C "$work/$p"; then
                echo "  (apk 内符号链接顺序导致 tar 报错,实体文件通常已解出,继续)"
            fi
            if [ -d "$work/$p/usr/lib" ]; then
                cp -a "$work/$p/usr/lib/." "$dest/" || { ok=""; break; }
            fi
            if [ -d "$work/$p/lib" ]; then
                cp -a "$work/$p/lib/." "$dest/" || { ok=""; break; }
            fi
        done
        [ -n "$ok" ] || continue
        # 显式补符号链接:实体文件名带版本(libstdc++.so.6.0.x),链接名固定
        real="$(ls "$dest"/libstdc++.so.6.* 2>/dev/null | grep -v 'so\.6$' | head -n 1)"
        if [ -n "$real" ]; then ln -sf "$(basename "$real")" "$dest/libstdc++.so.6"; fi
        # musl 本体(加载器+libc)单独收进 musl/ 子目录:垫片走真身直拉/显式加载器,
        # 自带 libc 绝不能落在 LD_LIBRARY_PATH 里(系统加载器配自带 libc 会版本错配)
        mkdir -p "$dest/musl"
        for f in "$dest"/ld-musl-*.so.1 "$dest"/libc.musl-*.so.1; do
            if [ -e "$f" ]; then mv "$f" "$dest/musl/" 2>/dev/null; fi
        done
        if [ -e "$dest/musl/ld-musl-x86_64.so.1" ] && [ ! -e "$dest/musl/libc.musl-x86_64.so.1" ]; then
            ln -sf ld-musl-x86_64.so.1 "$dest/musl/libc.musl-x86_64.so.1"
        fi
        # 成功判据:libstdc++/libgcc 就位 + 自带加载器收进 musl/(老系统加载器拉不动时的兜底)
        if [ -e "$dest/libstdc++.so.6" ] && [ -e "$dest/libgcc_s.so.1" ] && [ -e "$dest/musl/ld-musl-x86_64.so.1" ]; then
            rm -rf "$work" "$idx"
            exit 0
        fi
    done
    rm -rf "$work" "$idx"
    exit 1
) }

# —— 把 bin/node 换成垫片，真身挪成 node.bin。**首选「真身直拉」**：直接 exec node.bin，
# process.execPath 是真 node.bin——koffi 的 cnoke 校验预构建用的就是
# spawnSync(process.execPath, ["-e", ...])（旧式「exec ld-musl」垫片会让 execPath 变成
# 加载器本身，校验必败：koffi 平台包里的 musl 预构建明明存在却被判无效，OpenWrt 实锤）。
# 垫片按探测结果三级取一，探测到能用即停：
#   ①直拉+仅 lstd/：libstdc++ 单独目录进环境。node 的 libgcc 走 elf-patch.js 的
#     DT_NEEDED 短路径补丁（$HOME/.s/g），**不进环境**——老 musl 系统（如 22.03 的 1.2.3）
#     的动态进程（sed/env/sh -c/npm 链）从 LD_LIBRARY_PATH 撞见新版 libgcc_s 会当场段错误
#     （22.03 容器实测 10/10；只 libstdc++ 则无害 0/10），全 lib 目录不能进环境；
#   ②直拉+全 lib：libstdc++/libgcc 都进环境，给 ① 不够用的新 musl 机（其系统进程
#     与自带库同源，无害）；
#   ③显式自带加载器（execPath 会是加载器，cnoke 校验绕不过，属保底）。
# 垫片落在 PATH 里的 node 上（自启配置/手动调用/CLI 全透明生效）。幂等：node.bin 已在
# （上次已包过）就不再 mv，防止把垫片自己挪成真身导致无限递归。
# 探测走子壳并静音：busybox ash 对子壳内信号死亡的提示会从父壳 stderr 冒出，且子壳末命令
# 会被 exec 优化，不这样压不住
odw_wrap_node() {
    [ -f "$1/bin/node" ] || return 1
    if [ ! -f "$1/bin/node.bin" ]; then
        mv "$1/bin/node" "$1/bin/node.bin" || return 1
    fi
    # lstd 目录（libstdc++ 专属，对系统 musl 进程惰性）；没有就现造
    if [ -e "$1/lib/libstdc++.so.6" ] && [ ! -d "$1/lib/lstd" ]; then
        mkdir -p "$1/lib/lstd" 2>/dev/null && cp -a "$1"/lib/libstdc++.so* "$1/lib/lstd/" 2>/dev/null || true
    fi
    # 系统 libgcc_s 在（openwrt/iStoreOS 必有，busybox 依赖它）→ 纯 lstd；
    # 极简机（最小 Alpine 等）追加全 lib 兜底。
    # LD 路径必须写 $L（垫片运行时从 $0 自算的相对路径），不能烘焙 $1 绝对路径：
    # wrap_node 在「解压目录 → 正式版本目录」改名之前执行，烘焙绝对路径会在改名后全部失效
    # （安装期探针全走 libexec+显式 env，绿灯掩盖到任何外部调用才炸——24.10 容器实测踩中）。
    # 注意 §4 的教训：生成器上下文里 $L 不存在，set -u 下直接炸——所以 LDL 用单引号让
    # $L 原样进入垫片文本，由垫片运行时自己解析；生成器变量必须全部有值
    if [ -e /lib/libgcc_s.so.1 ] || [ -e /usr/lib/libgcc_s.so.1 ]; then
        LDL='$L/lstd'
    else
        LDL='$L/lstd:$L'
    fi
    {
        printf '#!/bin/sh\n'
        printf 'D="$(cd "$(dirname "$0")" && pwd)"\n'
        printf 'L="$D/../lib"\n'
        printf 'LD_LIBRARY_PATH="%s${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"\n' "$LDL"
        printf 'export LD_LIBRARY_PATH\n'
        printf 'exec "$D/node.bin" "$@"\n'
    } > "$1/bin/node" || return 1
    chmod +x "$1/bin/node" || return 1
    if ( :; "$1/bin/node" -v >/dev/null 2>&1; ST=$?; :; [ "$ST" -eq 0 ] ) 2>/dev/null; then
        return 0
    fi
    # ②直拉+全 lib：系统 libgcc_s 缺失/过老而 lstd 不够用时（node 自己要 libgcc）。
    # 老 musl 系统上直拉本身就败，轮不到这级
    {
        printf '#!/bin/sh\n'
        printf 'D="$(cd "$(dirname "$0")" && pwd)"\n'
        printf 'L="$D/../lib"\n'
        printf 'LD_LIBRARY_PATH="$L${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"\n'
        printf 'export LD_LIBRARY_PATH\n'
        printf 'exec "$D/node.bin" "$@"\n'
    } > "$1/bin/node" || return 1
    chmod +x "$1/bin/node" || return 1
    if ( :; "$1/bin/node" -v >/dev/null 2>&1; ST=$?; :; [ "$ST" -eq 0 ] ) 2>/dev/null; then
        return 0
    fi
    # ③显式自带加载器：系统 musl 太老（22.03 = musl 1.2.3）连真身都拉不动时的保底
    if [ -f "$1/lib/musl/ld-musl-x86_64.so.1" ]; then
        {
            printf '#!/bin/sh\n'
            printf 'D="$(cd "$(dirname "$0")" && pwd)"\n'
            printf 'L="$D/../lib"\n'
            printf 'exec "$L/musl/ld-musl-x86_64.so.1" --library-path "$L" "$D/node.bin" "$@"\n'
        } > "$1/bin/node" || return 1
        chmod +x "$1/bin/node" || return 1
        if ( :; "$1/bin/node" -v >/dev/null 2>&1; ST=$?; :; [ "$ST" -eq 0 ] ) 2>/dev/null; then
            echo "  (系统 musl 加载器拉不动 node,垫片退回自带加载器直拉)"
            return 0
        fi
    fi
    return 1
}

# —— 垫片自愈：目录在而 bin/node 缺失或起不动（上轮任务半途中断的残局）时重包一遍再探。
# wrap_node 幂等（node.bin 已在不挪真身）；垫片本体没了先补空壳供它重写
odw_shim_selfheal() { # odw_shim_selfheal <runtime根目录>
    local root="$1" d
    for d in "$root"/node-v*; do
        [ -f "$d/bin/node.bin" ] || continue
        if "$d/bin/node" -v >/dev/null 2>&1; then continue; fi
        echo "  托管运行时垫片损坏或缺失,重包:$d"
        [ -f "$d/bin/node" ] || : > "$d/bin/node"
        if odw_wrap_node "$d" && "$d/bin/node" -v >/dev/null 2>&1; then
            echo "  垫片重包后可用:$d"
        else
            echo "  垫片重包未奏效:$d(该目录按无可用 node 处理)"
        fi
    done
}

# —— musl 机真身直拉的最后一公里：系统 musl 加载器太老直拉必段错误（垫片退回加载器版
# ③级就是信号）时，把真身改造成「零系统耦合」：
#   ①PT_INTERP → $HOME/.s/ld（自带加载器，HOME 下短路径符号链接；新路径须塞得进原 interp
#     段，补丁器按 p_filesz 校验）；
#   ②DT_NEEDED libgcc_s.so.1 → $HOME/.s/g（自带 libgcc 短路径符号链接）。②不可省：
#     libstdc++/libgcc 若靠 LD_LIBRARY_PATH 进环境，同机一切动态 busybox 子进程会从环境里
#     撞见新版 libgcc_s 并当场段错误——所以 libgcc 走补丁进 node，环境里只放惰性的 lstd/。
#   加载器即 libc，配 libstdc++ 后直拉自洽，process.execPath 回归真身，cnoke 预构建校验
#   照常过，npm 的 libexec 直拉段也不用降级。
# 补丁写新文件、探测通过才 chmod+mv 原子顶替，失败零损伤（加载器垫片不吃 interp/NEEDED，
# node 照常能跑）。直拉已通（含补丁过的旧目录）整段跳过，幂等。
odw_patch_runtime() { # odw_patch_runtime <运行时目录>
    local d="$1"
    HOME="${HOME:-/root}"
    [ -f "$d/bin/node.bin" ] || return 0
    [ -f "$d/lib/musl/ld-musl-x86_64.so.1" ] || return 0
    [ -f "$d/lib/libgcc_s.so.1" ] || return 0
    [ -d "$d/lib/lstd" ] || return 0
    # 直拉已通（纯 lstd 或全 lib）就没什么可补
    if ( :; LD_LIBRARY_PATH="$d/lib/lstd" "$d/bin/node.bin" -v >/dev/null 2>&1; ST=$?; :; [ "$ST" -eq 0 ] ) 2>/dev/null; then
        return 0
    fi
    echo "真身直拉探测失败(系统 musl 加载器拉不动真身),尝试 PT_INTERP/DT_NEEDED 双补丁改用自带运行库"
    local elfjs="$ODW_HOME/elf-patch.js"
    [ -f "$elfjs" ] || { echo "提示:补丁器缺失($elfjs),继续用加载器垫片"; return 0; }
    if mkdir -p "$HOME/.s" 2>/dev/null \
       && ln -sfn "$d/lib/musl/ld-musl-x86_64.so.1" "$HOME/.s/ld" \
       && ln -sfn "$d/lib/libgcc_s.so.1" "$HOME/.s/g" \
       && "$d/bin/node" "$elfjs" "$d/bin/node.bin" "$HOME/.s/ld" "$HOME/.s/g" "$d/bin/node.bin.new" \
       && chmod 755 "$d/bin/node.bin.new" 2>/dev/null \
       && [ -f "$d/bin/node.bin.new" ]; then
        NEWP_ENV=""
        if ( :; LD_LIBRARY_PATH="$d/lib/lstd" "$d/bin/node.bin.new" -v >/dev/null 2>&1; ST=$?; :; [ "$ST" -eq 0 ] ) 2>/dev/null; then
            NEWP_ENV="$d/lib/lstd"
        elif ( :; LD_LIBRARY_PATH="$d/lib" "$d/bin/node.bin.new" -v >/dev/null 2>&1; ST=$?; :; [ "$ST" -eq 0 ] ) 2>/dev/null; then
            NEWP_ENV="$d/lib"
        fi
        if [ -n "$NEWP_ENV" ]; then
            mv -f "$d/bin/node.bin.new" "$d/bin/node.bin"
            ODW_LDEXEC_ENV="$NEWP_ENV"
            if odw_wrap_node "$d"; then
                echo "真身直拉补丁生效(interp/libgcc → 自带件,系统进程零暴露),cnoke 预构建校验可用"
            fi
        else
            rm -f "$d/bin/node.bin.new"
            echo "提示:PT_INTERP/DT_NEEDED 补丁后直拉仍不动,继续用加载器垫片(koffi 校验会绕源码编译,无 cmake 则装不上)"
        fi
    else
        rm -f "$d/bin/node.bin.new"
        echo "提示:补丁未就位(短链接/补丁器失败,如 HOME 路径放不进 interp 段),继续用加载器垫片"
    fi
    return 0
}

# —— 现有托管运行时里挑「满足下限的最新版本目录」。结果进全局 ODW_NODE_DIR/ODW_NODE_VER
odw_pick_runtime() { # odw_pick_runtime <最低版本>
    local root="$1" min="$2" d v
    ODW_NODE_DIR=""
    ODW_NODE_VER=""
    for d in "$root"/node-v*; do
        [ -x "$d/bin/node" ] || continue
        v="$("$d/bin/node" -v 2>/dev/null)" || continue
        v="${v#v}"
        case "$v" in ''|*[!0-9.]*) continue ;; esac
        if odw_node_ge "$v" "$min"; then
            if [ -z "$ODW_NODE_DIR" ] || ! odw_node_ge "$ODW_NODE_VER" "$v"; then
                ODW_NODE_DIR="$d"; ODW_NODE_VER="$v"
            fi
        fi
    done
}

# —— index.json → 最新 LTS 候选（最多 3 个，新到旧，一行一个）。
# 有能跑的 node 用 node 解析；一个 node 都跑不动时 awk 兜底（本函数存在的意义就是救 node）。
# awk 兜底的两个实测坑：
#   ① 2026 起官方/镜像 index.json 改一行一个对象的多行排版，老格式整行 JSON 里 },{ 相连，
#      统一 gsub 切成一行一对象兼容两种；
#   ② "lts":false 是不带引号的布尔值，按引号切字段会跳到下一字段名上，Current 线全被
#      误判成 LTS——改 match+substr 取值。降序 Top-3 用 awk 插入排序，不用 sort
#      （多键 -k 与 -r 的覆盖语义 GNU/busybox 不一）
odw_lts_candidates() { # odw_lts_candidates <index.json路径> <能跑的node路径,可空>
    local idx="$1" noderun="$2" cands=""
    if [ -n "$noderun" ] && [ -x "$noderun" ]; then
        cands="$("$noderun" -e '
            const a = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
            const key = (v) => String(v).replace(/^v/, "").split(".").map((n) => parseInt(n, 10) || 0);
            a.filter((r) => r.lts)
              .map((r) => r.version)
              .sort((p, q) => { const x = key(p), y = key(q); for (let i = 0; i < 3; i++) { if (x[i] !== y[i]) return y[i] - x[i]; } return 0; })
              .slice(0, 3)
              .forEach((v) => console.log(v.replace(/^v/, "")));
        ' "$idx" 2>/dev/null)"
    fi
    if [ -z "$cands" ]; then
        cands="$(awk '
            function lt(a, b,   x, y, i) {
                split(a, x, "."); split(b, y, ".")
                for (i = 1; i <= 3; i++) {
                    if ((x[i] + 0) < (y[i] + 0)) return 1
                    if ((x[i] + 0) > (y[i] + 0)) return 0
                }
                return 0
            }
            {
                # 切分对象绝不能用含 { 的正则:busybox awk(24.10 容器实测)自研正则引擎里,
                # /},{/ 报「Invalid contents of {}」(区间表达式解析),[{] 字面花括号解析过但不匹配,
                # /}\,{/ 转义花括号直接拒编译。index() 是纯字符串查找,零方言差异,三种 awk 通吃
                s = $0
                n = 0
                while (1) {
                    p = index(s, "},{")
                    if (p == 0) break
                    n++
                    objs[n] = substr(s, 1, p)
                    s = substr(s, p + 2)
                }
                n++
                objs[n] = s
                for (j = 1; j <= n; j++) {
                    rec = objs[j]
                    ver = ""
                    if (match(rec, /"version"[ \t]*:[ \t]*"/)) {
                        rest = substr(rec, RSTART + RLENGTH)
                        q = index(rest, "\"")
                        if (q > 1) ver = substr(rest, 1, q - 1)
                    }
                    if (ver == "") continue
                    lts = 0
                    if (match(rec, /"lts"[ \t]*:[ \t]*"/)) lts = 1
                    if (!lts) continue
                    sub(/^v/, "", ver)
                    if (c1 == "") c1 = ver
                    else if (lt(c1, ver)) { c3 = c2; c2 = c1; c1 = ver }
                    else if (c2 == "") c2 = ver
                    else if (lt(c2, ver)) { c3 = c2; c2 = ver }
                    else if (c3 == "") c3 = ver
                    else if (lt(c3, ver)) c3 = ver
                }
            }
            END { if (c1 != "") print c1; if (c2 != "") print c2; if (c3 != "") print c3 }
        ' "$idx")"
    fi
    printf '%s' "$cands"
}

# —— 确保有满足下限的 Node 运行时；没有则升级到最新 LTS 稳定版。
# 结果进全局 ODW_NODE_DIR/ODW_NODE_VER（失败为空，调用方决定是否继续）。
# 仅 Linux x86_64 自动升级（musl 用 unofficial 构建，glibc 走官方构建）；其余架构只提示
odw_ensure_runtime() { # odw_ensure_runtime <最低版本>
    local min="$1" root d v cands idx idx_ok cand canddir
    root="$(odw_runtime_dir)"
    mkdir -p "$root" 2>/dev/null

    echo "== Node 运行时检查(要求 >= v$min) =="
    odw_shim_selfheal "$root"
    odw_pick_runtime "$root" "$min"
    if [ -n "$ODW_NODE_DIR" ]; then
        echo "Node 运行时 $ODW_NODE_DIR(v$ODW_NODE_VER)满足要求,直接使用"
        return 0
    fi

    # 现有目录都不满足（或全坏）：逐个实测挑真能跑的 node（托管运行时 → PATH）。
    # 不盲信任何"看起来是 node"的路径——垫片/加载器/残局都可能让 -v 假失败或假成功
    local noderun=""
    for cand in "$root"/node-v*/bin/node "$(command -v node 2>/dev/null)"; do
        [ -n "$cand" ] && [ -x "$cand" ] || continue
        v="$("$cand" -v 2>/dev/null)" || continue
        case "$v" in v[0-9]*) noderun="$cand"; break ;; esac
    done
    local cur_v="$("$noderun" -v 2>/dev/null || echo 未知)"
    cur_v="${cur_v#v}"
    echo "现有 Node v$cur_v 低于要求或不可用,尝试升级到最新 LTS 稳定版"

    local sys arch
    sys="$(uname -s 2>/dev/null || echo unknown)"
    arch="$(uname -m 2>/dev/null || echo unknown)"
    if [ "$sys" != "Linux" ]; then
        echo "提示:非 Linux 环境($sys)不自动安装 Node"; return 1
    elif [ "$arch" != "x86_64" ]; then
        echo "提示:暂无 $arch 的 Node 自动安装通道(仅 x86_64)"; return 1
    elif ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        echo "提示:本机无 curl/wget,无法下载 Node"; return 1
    fi

    odw_detect_musl
    local bases suffix
    if [ -n "$ODW_MUSL" ]; then
        suffix="-musl"
        bases="$ODW_NODE_MIRRORS_MUSL"
    else
        suffix=""
        bases="$ODW_NODE_MIRRORS"
    fi

    idx="$(mktemp /tmp/odw-nidx.XXXXXX)" || return 1
    idx_ok=""
    for b in $bases; do
        if odw_fetch "$b/index.json" "$idx" && [ -s "$idx" ]; then idx_ok=1; break; fi
    done
    if [ -z "$idx_ok" ]; then
        rm -f "$idx"
        echo "提示:版本索引获取失败(各镜像均不通)"; return 1
    fi
    cands="$(odw_lts_candidates "$idx" "$noderun")"
    [ -z "$cands" ] && echo "  提示:版本索引解析失败(node 与 awk 兜底均无果)"
    rm -f "$idx"

    local tgz dl_ok extracted newp new_v
    for VER in $cands; do
        tgz="$(mktemp /tmp/odw-ntgz.XXXXXX)" || continue
        if ! mkdir -p "$root" 2>/dev/null; then rm -f "$tgz"; continue; fi
        dl_ok=""
        for b in $bases; do
            if odw_dl "$b/v$VER/node-v$VER-linux-x64$suffix.tar.gz" "$tgz"; then dl_ok=1; break; fi
        done
        if [ -z "$dl_ok" ]; then rm -f "$tgz"; echo "  v$VER 各镜像下载失败,试下一个候选"; continue; fi
        if ! tar -xzf "$tgz" -C "$root"; then rm -f "$tgz"; echo "  v$VER 解压失败,试下一个候选"; continue; fi
        rm -f "$tgz"
        extracted="$root/node-v$VER-linux-x64$suffix"
        newp="$root/node-v$VER"
        if [ ! -x "$extracted/bin/node" ]; then rm -rf "$extracted"; echo "  v$VER 解压布局不合预期,试下一个候选"; continue; fi
        # musl 机:先自带 Alpine 运行库 + 垫片包装,再用垫片验证——下载/解压成功但跑不起来
        # 不算成功(挡住 libc 换过之后残留的旧运行时被复用)
        if [ -n "$ODW_MUSL" ]; then
            mkdir -p "$extracted/lib"
            if ! odw_fix_runtime_libs "$extracted/lib" || ! odw_wrap_node "$extracted"; then
                rm -rf "$extracted"; echo "  v$VER 的 musl 运行库/垫片未能就位,试下一个候选"; continue
            fi
        fi
        new_v="$("$extracted/bin/node" -v 2>/dev/null)"
        new_v="${new_v#v}"
        if [ -z "$new_v" ] || ! odw_node_ge "$new_v" "$min"; then
            rm -rf "$extracted"; echo "  v$VER 就位后无法执行或不满足下限,试下一个候选"; continue
        fi
        rm -rf "$newp"
        if ! mv "$extracted" "$newp"; then rm -rf "$extracted"; echo "  v$VER 就位失败,试下一个候选"; continue; fi
        ODW_NODE_DIR="$newp"
        ODW_NODE_VER="$new_v"
        echo "Node 运行时已就绪: v$new_v($newp)"
        break
    done
    [ -n "$ODW_NODE_DIR" ] && return 0
    return 1
}

# —— 为选定运行时补最后两步(幂等):ELF 双补丁(救老 musl 机)。
# lstd 在 odw_wrap_node 里已建,这里只做补丁。ODW_LDEXEC_ENV 由补丁步骤按机器能力回填:
#   有系统 libgcc_s → 纯 lstd(libstdc++ 专属目录,系统 musl 进程零暴露);
#   极简机(无系统 libgcc_s)→ lstd:lib 兜底;补丁失败 → 全 lib(垫片机不直拉,环境只是不碍事)
odw_prepare_runtime() { # odw_prepare_runtime <运行时目录>
    local d="$1"
    if [ -d "$d/lib/lstd" ]; then ODW_LDEXEC_ENV="$d/lib/lstd"; else ODW_LDEXEC_ENV="$d/lib"; fi
    if [ ! -e /lib/libgcc_s.so.1 ] && [ ! -e /usr/lib/libgcc_s.so.1 ]; then
        ODW_LDEXEC_ENV="$ODW_LDEXEC_ENV:$d/lib"
    fi
    odw_patch_runtime "$d"
    return 0
}
