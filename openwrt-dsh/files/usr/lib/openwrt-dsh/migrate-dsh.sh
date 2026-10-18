#!/bin/sh
# openwrt-dsh 引擎：安装目录迁移任务脚本
# 用法: migrate-dsh.sh <目标目录>
# 由 task.sh 包裹执行（锁 + 状态落盘 + 日志重定向），也可手动直跑观察输出。
# 迁移语义（与安装/卸载同一套幂等三原则：先探测后采用 / 失败零损伤 / 可重跑）：
#   迁移对象 = <install_dir> 下的全部托管内容（runtime/ 运行时 + dsh.version 版本标记）。
#   「整体搬家」可行的前提：三级垫片的 LD 路径全相对（$0 自算，见 porting-notes §4）、
#   Alpine 三件套与 musl 原生件都是普通文件——整树 cp -a 到新路径后照常能跑，
#   唯一的绝对路径依赖是 ELF 补丁机的 $HOME/.s/ld|g 短链（见第 4 步，重指即可）。
#   流程刻意做成「先复制后切换」，顺序不能倒：
#     目标分区暂存目录整拷 → 校验（字节数 + 关键件）→ mv 到位（同分区 rename，秒级）
#     → 短链重指 + 旧树改名挪开 → 新位置 dsh --version 实载自检 → 改 UCI install_dir
#     → 删旧树。中途任何一步失败：旧树改名送回、短链还原、UCI 未动，绝不出现
#     「旧的已删、新的不全」的中间态。
# 边界：
#   - 引擎（/usr/lib/openwrt-dsh）与 /usr/bin/dsh wrapper、profile.d 归 openwrt-dsh
#     包管，不参与迁移；wrapper/CLI/LuCI/profile.d 都动态读 UCI，切换后自动指新位置
#   - 迁移期间请勿运行 dsh：已在跑的进程靠已打开的 inode 不受影响，但「旧树挪开」
#     到删旧之间的窗口里旧路径短暂不在位，新启动一律走新路径
#   - /tmp/openwrt-dsh 任务状态与本迁移无关（tmpfs，不随安装目录走）
set -u

MODDIR="$(cd "$(dirname "$0")" && pwd)"
. "$MODDIR/lib.sh"

TARGET="${1:-}"
case "$TARGET" in
    /*) : ;;
    *) [ -n "$TARGET" ] && echo "✗ 非法的迁移目标:$TARGET(需以 / 开头的绝对路径)" >&2
       [ -n "$TARGET" ] || echo "用法: migrate-dsh.sh <目标目录>" >&2
       exit 64 ;;
esac
TARGET="${TARGET%/}"
[ -n "$TARGET" ] || TARGET="/"
# .. / . 段防越级（rpcd/task.sh 已有同款校验，这里兜底：手工直跑也过同一道闸）
case "$TARGET" in
    "/.."|*/../*|*/..|"/."|*/./*) echo "✗ 非法的迁移目标:$TARGET(不允许 . .. 路径段)" >&2; exit 64 ;;
esac

INSTALL_ROOT="$(odw_install_dir)"
HIDE="$INSTALL_ROOT.odw-migrating"

# 上次迁移在「旧树已改名挪开」窗口暴毙的自愈：配置还指旧目录但目录不在位，把挪开的
# 树送回去（可重跑原则）。UCI 已切到新目录的场景这里不触发（INSTALL_ROOT=新目录在位），
# 残骸由第 7 步的 rm -rf 清
if [ ! -e "$INSTALL_ROOT" ] && [ -e "$HIDE" ]; then
    if mv "$HIDE" "$INSTALL_ROOT" 2>/dev/null; then
        echo "发现上次迁移残骸,已还原:$HIDE → $INSTALL_ROOT"
    fi
fi

echo "== openwrt-dsh 任务:migrate(迁移安装目录)=="
echo "当前安装目录:$INSTALL_ROOT"
echo "迁移目标:$TARGET"

# ---- 0) 前置检查（全部动手之前探明，失败即止零损伤） ----
[ "$INSTALL_ROOT" = "/" ] && { echo "✗ 安装根目录配置为 /,拒绝迁移(请先在 UCI 里配置正常的安装目录)" >&2; exit 1; }
[ "$TARGET" = "/" ] && { echo "✗ 迁移目标不能是根目录 /" >&2; exit 1; }
if [ "$TARGET" = "$INSTALL_ROOT" ]; then
    echo "✗ 迁移目标与当前安装目录相同,无需迁移" >&2
    exit 1
fi
# 嵌套防护：目标在当前目录内（搬进去会被第 7 步删旧误伤）/当前目录在目标内（把家搬进
# 家里）。比一刀切的字符串前缀判断多带一个 /，/opt/openwrt-dsh 与 /opt/openwrt-dsh2
# 这种「前缀相同但非嵌套」的兄弟目录才不会误拒
case "$TARGET/" in
    "$INSTALL_ROOT"/*) echo "✗ 迁移目标($TARGET)在当前安装目录($INSTALL_ROOT)内,拒绝迁移" >&2; exit 1 ;;
esac
case "$INSTALL_ROOT/" in
    "$TARGET"/*) echo "✗ 当前安装目录($INSTALL_ROOT)在迁移目标($TARGET)内,拒绝迁移" >&2; exit 1 ;;
esac

if ! command -v uci >/dev/null 2>&1; then
    echo "✗ 没有 uci 命令,迁移后无法切换 install_dir 配置(非 OpenWrt 环境?)" >&2
    exit 1
fi

# 已装判定与状态页同一真源：dsh.version 标记（uninstall 会清标记，有标记即「已安装」）
if [ ! -f "$INSTALL_ROOT/dsh.version" ]; then
    echo "✗ $INSTALL_ROOT/dsh.version 缺失:当前目录没有已安装的 dsh,无需迁移" >&2
    exit 1
fi
if [ ! -d "$INSTALL_ROOT" ]; then
    echo "✗ 安装目录不存在:$INSTALL_ROOT" >&2
    exit 1
fi

# 目标就位：不存在则创建（选目录弹窗只能选已存在的目录，这里兜 CLI 直跑的场景）
if [ -e "$TARGET" ] && [ ! -d "$TARGET" ]; then
    echo "✗ 迁移目标已存在且不是目录:$TARGET" >&2
    exit 1
fi
if ! mkdir -p "$TARGET" 2>/dev/null; then
    echo "✗ 无法创建迁移目标目录:$TARGET(分区没挂载/只读?)" >&2
    exit 1
fi

# 顶层条目遍历（含隐藏文件；glob 不匹配时原样保留字面量，靠 [ -e ]/[ -L ] 过滤——
# 先探测后采用）。清点/冲突/复制/切换/回滚各轮都重跑同一 glob 而不是存名单：
# 名单拼串总有分隔符边界（目录名含换行之类），glob 每轮结果有序且一致

count=0
for f in "$INSTALL_ROOT"/* "$INSTALL_ROOT"/.[!.]* "$INSTALL_ROOT"/..?* ; do
    { [ -e "$f" ] || [ -L "$f" ]; } || continue
    count=$((count + 1))
done
if [ "$count" -eq 0 ]; then
    echo "✗ 安装目录为空(只有 dsh.version 标记,没有可搬的内容),请先 install/update 或 uninstall" >&2
    exit 1
fi

# 目标同名冲突：暂存切换是 rename 进目标目录，撞名 = 必然覆盖用户数据，宁可不迁
conflict=""
for f in "$INSTALL_ROOT"/* "$INSTALL_ROOT"/.[!.]* "$INSTALL_ROOT"/..?* ; do
    { [ -e "$f" ] || [ -L "$f" ]; } || continue
    name="${f##*/}"
    if [ -e "$TARGET/$name" ] || [ -L "$TARGET/$name" ]; then
        conflict="$conflict
  $TARGET/$name"
    fi
done
if [ -n "$conflict" ]; then
    echo "✗ 目标目录已有同名内容,为免覆盖请先清理或换一个目录:$conflict" >&2
    exit 1
fi

# 空间预检：现有内容体积 + 20MB 余量（文件系统记账/碎片开销），不够就在复制前明说
used_kb="$(du -sk "$INSTALL_ROOT" 2>/dev/null | awk '{ print $1 }')"
[ -n "$used_kb" ] || used_kb=0
free_kb="$(odw_free_bytes "$TARGET" 2>/dev/null | awk '{ print int($1 / 1024) }')"
[ -n "$free_kb" ] || free_kb=0
if [ "$((free_kb - used_kb))" -lt 20480 ]; then
    echo "✗ 目标分区可用空间不足:约 $(odw_human $((free_kb * 1024))),现有内容 $(odw_human $((used_kb * 1024))) + 20MB 余量放不下" >&2
    exit 1
fi

# ---- 1) 暂存整拷：落在目标分区上（同分区 rename 才是秒级）；暂存名是我们保留的 ----
# 命名空间，上次任务中途暴毙的残留直接清掉再开（可重跑）
STAGE="$TARGET/.odw-migrate-stage"
rm -rf "$STAGE"
if ! mkdir "$STAGE" 2>/dev/null; then
    echo "✗ 无法创建暂存目录:$STAGE" >&2
    exit 1
fi
echo "== 复制到暂存目录($STAGE)=="
for f in "$INSTALL_ROOT"/* "$INSTALL_ROOT"/.[!.]* "$INSTALL_ROOT"/..?* ; do
    { [ -e "$f" ] || [ -L "$f" ]; } || continue
    name="${f##*/}"
    printf '  %s … ' "$name"
    # cp -a：递归 + 保软链（垫片是软链链，解引就全废）+ 保权限时间戳；跨分区自动实拷
    if cp -a "$f" "$STAGE/$name" 2>/dev/null; then
        echo "ok"
    else
        echo "失败"
        rm -rf "$STAGE"
        echo "✗ 复制失败:$f(目标分区空间不足/IO 错误?);旧目录未动,暂存已回滚" >&2
        exit 1
    fi
done

# ---- 2) 暂存校验：字节数（10% 容差，跨分区块尺寸有差，拦的是「拷了一半」）+ 关键件 ----
stage_kb="$(du -sk "$STAGE" 2>/dev/null | awk '{ print $1 }')"
if [ -z "$stage_kb" ] || [ "$stage_kb" -lt $((used_kb * 9 / 10)) ]; then
    rm -rf "$STAGE"
    echo "✗ 暂存校验失败(源 $used_kb KB / 暂存 ${stage_kb:-0} KB,复制不完整);旧目录未动,暂存已回滚" >&2
    exit 1
fi
if [ ! -f "$STAGE/dsh.version" ]; then
    rm -rf "$STAGE"
    echo "✗ 暂存校验失败(dsh.version 未复制到位);旧目录未动,暂存已回滚" >&2
    exit 1
fi
echo "暂存校验通过($used_kb KB → $stage_kb KB,关键件在位)"

# ---- 3) 切换：同分区 rename，逐条目移入目标目录（此时旧目录仍原封不动） ----
echo "== 切换到新目录 =="
for f in "$INSTALL_ROOT"/* "$INSTALL_ROOT"/.[!.]* "$INSTALL_ROOT"/..?* ; do
    { [ -e "$f" ] || [ -L "$f" ]; } || continue
    name="${f##*/}"
    if ! mv "$STAGE/$name" "$TARGET/$name" 2>/dev/null; then
        echo "✗ 切换失败:$name(旧目录未动);可重跑,届时暂存残留会自动清掉" >&2
        exit 1
    fi
done
rmdir "$STAGE" 2>/dev/null

# ---- 4) 短链重指 + 旧树挪开 + 新位置实载自检（在动 UCI 与删旧之前，宁可红不给假绿） ----
# $HOME/.s/ld|g 是 ELF 补丁写进 node.bin 的 PT_INTERP/DT_NEEDED 终点，绝对路径指向旧
# 安装目录——不重指的话删旧即悬、node 起不来（2026-10-19 22.03 双容器首跑实锤：自检
# 从仍在位的旧树假绿通过，删旧后 wrapper --version 直接空）。自检前把旧树整棵「改名
# 挪开」：旧路径不在位，自检结果才可信（挪开是 rename，可逆；自检不过就连短链一起
# 原样还原，UCI 与数据分毫未动）
HOME="${HOME:-/root}"
OLD_LD=""; OLD_G=""
[ -L "$HOME/.s/ld" ] && OLD_LD="$(readlink "$HOME/.s/ld" 2>/dev/null)"
[ -L "$HOME/.s/g" ] && OLD_G="$(readlink "$HOME/.s/g" 2>/dev/null)"
newbin=""
for b in "$TARGET"/runtime/node-v*/bin ; do
    # 与 /usr/bin/dsh wrapper 同一套挑选逻辑：循环不 break，取最后一个（最新版本目录）
    [ -x "$b/node" ] && [ -e "$b/dsh" ] && newbin="$b"
done
newrt="$(dirname "$newbin")"

# 旧树改名挪开（HIDE 名是我们保留的命名空间，残骸在第 0 步已自愈/清除）
rm -rf "$HIDE" 2>/dev/null
HIDE_OK=""
if mv "$INSTALL_ROOT" "$HIDE" 2>/dev/null; then
    HIDE_OK=1
else
    echo "提示:旧树改名挪开失败($INSTALL_ROOT → $HIDE),自检改由重指后的短链保证可信"
fi

migrate_restore() {
    # 还原 = 旧树送回 + 短链还原（此刻 UCI 未动、目标里是我们刚搬入的副本，一并清掉）
    [ -n "$HIDE_OK" ] && mv "$HIDE" "$INSTALL_ROOT" 2>/dev/null
    [ -n "$OLD_LD" ] && ln -sfn "$OLD_LD" "$HOME/.s/ld" 2>/dev/null
    [ -n "$OLD_G" ] && ln -sfn "$OLD_G" "$HOME/.s/g" 2>/dev/null
    for f in "$INSTALL_ROOT"/* "$INSTALL_ROOT"/.[!.]* "$INSTALL_ROOT"/..?* ; do
        { [ -e "$f" ] || [ -L "$f" ]; } || continue
        rm -rf "$TARGET/${f##*/}"
    done
    rmdir "$TARGET" 2>/dev/null
    :
}

if [ -n "$OLD_LD" ]; then
    if ! ln -sfn "$newrt/lib/musl/ld-musl-x86_64.so.1" "$HOME/.s/ld" 2>/dev/null; then
        migrate_restore
        echo "✗ 短链重指失败($HOME/.s/ld),旧树与短链已还原,目标已回滚" >&2
        exit 1
    fi
fi
if [ -n "$OLD_G" ]; then
    if ! ln -sfn "$newrt/lib/libgcc_s.so.1" "$HOME/.s/g" 2>/dev/null; then
        migrate_restore
        echo "✗ 短链重指失败($HOME/.s/g),旧树与短链已还原,目标已回滚" >&2
        exit 1
    fi
fi
[ -n "$OLD_LD" ] && echo "短链已重指:$HOME/.s/ld → 新运行时(ELF 补丁机)"
[ -n "$OLD_G" ] && echo "短链已重指:$HOME/.s/g → 新运行时(ELF 补丁机)"

# 实载自检：bin/dsh 的 shebang 是 #!/usr/bin/env node，与 wrapper 同款把运行时 bin
# 前插 PATH。必须用 $TARGET 下重扫的运行时路径（mv 之后暂存已空，拿暂存路径自检
# 必空必假红——首跑实锤）
DSH_V=""
if [ -n "$newbin" ]; then
    DSH_V="$(PATH="$newbin:$PATH" "$newbin/dsh" --version 2>/dev/null)"
fi
if [ -z "$DSH_V" ]; then
    migrate_restore
    echo "✗ 新位置实载自检失败(dsh --version 无输出),旧树与短链已还原,目标已回滚" >&2
    exit 1
fi
echo "新位置实载自检通过:dsh $DSH_V(旧树不在位,结果可信)"

# ---- 5) 配置切换：UCI install_dir 指向新路径（此步之后 wrapper/CLI/LuCI 自动指新） ----
echo "== 更新配置(openwrt-dsh.core.install_dir → $TARGET)=="
if ! uci set openwrt-dsh.core.install_dir="$TARGET"; then
    migrate_restore
    echo "✗ uci set 失败:旧树与短链已还原,目标已回滚" >&2
    exit 1
fi
if ! uci commit openwrt-dsh; then
    # set 只进 /tmp 暂存，commit 失败 = 磁盘配置未变，把暂存也退掉保持干净
    uci revert openwrt-dsh 2>/dev/null
    migrate_restore
    echo "✗ uci commit 失败:旧树与短链已还原,目标已回滚" >&2
    exit 1
fi

# ---- 6) 删旧：旧树此刻是 HIDE 改名体（内容已整体复制到目标并自检通过），整树删除 ----
# 等价于逐条目清理且更快；「混着用户别的数据」的场景不受损——那些条目已随迁移一起
# 搬到目标目录（同名冲突在第 0 步就拒绝了，不存在覆盖）
if [ -n "$HIDE_OK" ]; then
    if rm -rf "$HIDE"; then
        echo "旧树已删除:$HIDE(内容已在 $TARGET)"
    else
        echo "⚠ 旧树删除失败(不影响新目录使用,可手动删):$HIDE"
    fi
fi

echo "== 迁移完成:dsh $DSH_V 已驻 $TARGET(旧树已清,UCI 已切换)=="
exit 0
