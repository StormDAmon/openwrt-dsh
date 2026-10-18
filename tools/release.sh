#!/bin/sh
# 一键发布:校验 → 对齐版本 → release 提交 → 打 tag → 构建 ipk → push → GitHub Release。
# 用法: tools/release.sh <vX.Y.Z> [--draft] [--dry-run] [--no-open]
#
#   vX.Y.Z    本次发布的 tag(也是唯一版本号来源,写进 VERSION 与包 Makefile)
#   --draft   gh 路径下创建草稿 release(先看一眼再手动 Publish)
#   --dry-run 全流程预演:只打印将要做的事,不写任何文件、不提交、不推送
#   --no-open 兜底路径不自动开浏览器
#
# gh 已安装且已登录 → 全自动(gh release create 连附件一起传);
# gh 没装/没登录   → 兜底:push 完自动打开 GitHub「新建 release」预填页,
#                    发布说明已生成在 dist/RELEASE-NOTES-<tag>.md,粘贴+拖入
#                    dist/ 附件点 Publish 即可(装 gh:winget install GitHub.cli)。
set -eu
cd "$(dirname "$0")/.." || exit 1

DRYRUN=0
DRAFT=0
OPEN=1
TAG=""
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRYRUN=1 ;;
        --draft)   DRAFT=1 ;;
        --no-open) OPEN=0 ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        -*)        echo "✗ 未知选项: $arg"; exit 1 ;;
        *)         TAG="$arg" ;;
    esac
done
if [ -z "$TAG" ]; then
    echo "用法: tools/release.sh <vX.Y.Z> [--draft] [--dry-run] [--no-open]"
    exit 1
fi

# tag 即发布物的唯一命名,格式必须严格 vX.Y.Z
if ! printf '%s\n' "$TAG" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "✗ 版本号格式必须是 vX.Y.Z(如 v0.1.0),收到: $TAG"
    exit 1
fi
VER="${TAG#v}"

run() {  # 有副作用的动作统一走这里;dry-run 只打印意图
    if [ "$DRYRUN" -eq 1 ]; then
        echo "   [dry-run] $*"
    else
        "$@"
    fi
}

slug_from_remote() {  # git@github.com:O/R.git | https://github.com/O/R.git → O/R
    url=$(git config --get remote.origin.url)
    case "$url" in
        git@github.com:*)        slug="${url#git@github.com:}" ;;
        https://github.com/*)    slug="${url#https://github.com/}" ;;
        ssh://git@github.com/*)  slug="${url#ssh://git@github.com/}" ;;
        *) slug="" ;;
    esac
    echo "${slug%.git}"
}

open_url() {  # 跨平台开浏览器;失败不打断(手动开链接即可)
    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$1" >/dev/null 2>&1 || true
    elif command -v open >/dev/null 2>&1; then
        open "$1" >/dev/null 2>&1 || true
    elif command -v cmd.exe >/dev/null 2>&1; then
        # Git Bash 里 //c 会被转成 /c;start 的第一个引号参数是窗口标题,给空串
        cmd.exe //c start "" "$1" >/dev/null 2>&1 || true
    fi
}

echo "== [1/7] 语法与资产检查(dev-check)=="
tools/dev-check.sh

echo
echo "== [2/7] 发布前检查 =="
if [ -n "$(git status --porcelain)" ]; then
    echo "✗ 工作区有未提交改动,先提交或 stash(发布内容必须可追溯到提交):"
    git status --short
    exit 1
fi
echo "   工作区干净"

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then
    echo "✗ 本地已有 tag $TAG(确认废弃后: git tag -d $TAG)"
    exit 1
fi
echo "   本地无 $TAG"

if git ls-remote --tags origin "refs/tags/$TAG" 2>/dev/null | grep -q .; then
    echo "✗ 远端已存在 $TAG,换一个版本号"
    exit 1
fi
echo "   远端无 $TAG"

echo
echo "== [3/7] 版本对齐 → $VER(VERSION + 包 Makefile + 引擎版本标记,PKG_RELEASE 重置 1)=="
bumped=0
if [ "$(cat VERSION)" != "$VER" ]; then
    run sh -c "printf '%s\n' '$VER' > VERSION"
    bumped=1
fi
for mk in openwrt-dsh/Makefile; do
    cur=$(sed -n 's/^PKG_VERSION:=//p' "$mk")
    if [ "$cur" != "$VER" ]; then
        run sed -i "s/^PKG_VERSION:=.*/PKG_VERSION:=$VER/" "$mk"
        bumped=1
    fi
    # 包修订号随版本重置:同版本内的修订才递增 PKG_RELEASE
    run sed -i "s/^PKG_RELEASE:=.*/PKG_RELEASE:=1/" "$mk"
done
# 引擎版本标记(LuCI 标题徽标/CLI status/自更新比版本的插件版本第一真源)一并对齐;
# 形态 = PKG_VERSION-PKG_RELEASE,与 opkg 报告的版本串同构。dev-check.sh 校验三方一致
VERFILE="openwrt-dsh/files/usr/lib/openwrt-dsh/version"
if [ "$(cat "$VERFILE")" != "$VER-r1" ]; then
    run sh -c "printf '%s\n' '$VER-r1' > '$VERFILE'"
    bumped=1
fi
[ "$bumped" -eq 0 ] && echo "   版本已是 $VER,无需改动(重复发布场景,直接给当前 HEAD 打 tag)"

echo
echo "== [4/7] release 提交 + tag =="
if [ "$bumped" -eq 1 ]; then
    run git add VERSION openwrt-dsh/Makefile "$VERFILE"
    run git commit -m "release: $TAG"
else
    echo "   [跳过] 无版本改动需要提交"
fi
run git tag -a "$TAG" -m "openwrt-dsh $TAG"

echo
echo "== [5/7] 构建 ipk 二进制包 =="
# ipk 是唯一交付物(别人后台直装);源码包不手工打——GitHub 对每个 tag 自动提供
# Source code 归档,repo 里留着 .gitattributes 的 LF 规范保证它也是干净的。
if ls work/openwrt-sdk-*.tar.zst >/dev/null 2>&1; then
    run tools/build-ipk.sh
else
    echo "✗ 未找到 work/openwrt-sdk-*.tar.zst;发布以 ipk 为唯一交付物,必须构建。"
    echo "  首次运行 tools/build-ipk.sh 会自动下载官方 SDK。"
    exit 1
fi

# 发布说明:上一 tag..本次 的提交列表;首个发布列出全部
OUTDIR=dist
NOTES="$OUTDIR/RELEASE-NOTES-$TAG.md"
PREV=$(git describe --tags --abbrev=0 "$TAG^" 2>/dev/null || true)
gen_notes() {
    {
        echo "# openwrt-dsh $TAG"
        echo
        echo "OpenWrt/iStoreOS(x86_64 musl)上的 dsh 引擎:单 ipk 含引擎 + SSH CLI + rpcd 后端 + LuCI 页面。"
        echo
        echo "## 安装"
        echo
        echo "1. 下载 \`openwrt-dsh_${VER}-r1_all.ipk\` 拷到路由器"
        echo "2. \`opkg install openwrt-dsh_${VER}-r1_all.ipk\`(依赖 curl/ca 证书会自动从源拉取)"
        echo "3. LuCI → 服务 → DeepSeek Harness;或 SSH 里 \`openwrt-dsh install\` 安装 dsh 运行时"
        echo
        echo "## 变更"
        echo
        if [ -n "$PREV" ]; then
            echo "自 $PREV 以来:"
            git log --format='- %s' "$PREV..$TAG"
        else
            echo "首个发布,全部提交:"
            git log --format='- %s' "$TAG"
        fi
        echo
        echo "校验:\`sha256sum -c sha256sums.txt\`"
    } > "$NOTES"
}
echo
echo "== [6/7] 生成发布说明 =="
if [ "$DRYRUN" -eq 1 ]; then
    echo "   [dry-run] 写 $NOTES"
else
    gen_notes
    echo "   已生成 $NOTES"
fi

echo
echo "== [7/7] 推送 + GitHub Release =="
run git push origin main "$TAG"

# gh 的 auth 校验和建 release 都要访问 api.github.com;直连不通而本机代理
# (如 Clash 混合端口)可达的环境很常见。探测必须放在 gh auth status 之前——
# 否则离线误判「未登录」走兜底(实测坑:tag 推完 release 却没建出来)。
# 已有 HTTPS_PROXY 时尊重现状;没有才探测常见端口,探到哪个通就走哪个。
if [ -z "${HTTPS_PROXY:-}" ] && [ -z "${https_proxy:-}" ]; then
    for ghp in 7890 7897 10809 1080; do
        if curl -sS -m 2 -x "http://127.0.0.1:$ghp" -o /dev/null https://api.github.com 2>/dev/null; then
            export HTTPS_PROXY="http://127.0.0.1:$ghp"
            export HTTP_PROXY="http://127.0.0.1:$ghp"
            echo "(检测到本机代理 127.0.0.1:$ghp 可达 api.github.com,gh 走该代理)"
            break
        fi
    done
fi

GH_OK=0
if command -v gh >/dev/null 2>&1; then
    if gh auth status >/dev/null 2>&1; then
        GH_OK=1
    else
        echo "(gh 已安装但未登录或网络不通,走兜底路径;先 gh auth login 可全自动)"
    fi
else
    echo "(未安装 gh,走兜底路径;安装后可全自动: winget install GitHub.cli)"
fi

if [ "$GH_OK" -eq 1 ]; then
    # sha256 覆盖发布物(当前 = ipk);放这生成,构建产物一到位就能算
    if [ "$DRYRUN" -eq 1 ]; then
        echo "   [dry-run] 写 $OUTDIR/sha256sums.txt(覆盖 dist 内全部交付物)"
    else
        ( cd "$OUTDIR" && sha256sum openwrt-dsh_*.ipk > sha256sums.txt )
    fi
    ATT=""
    [ -f "$OUTDIR/sha256sums.txt" ] && ATT="$ATT $OUTDIR/sha256sums.txt"
    for ipk in "$OUTDIR"/*.ipk; do
        [ -f "$ipk" ] && ATT="$ATT $ipk"
    done
    if [ "$DRAFT" -eq 1 ]; then
        run gh release create "$TAG" --draft --title "openwrt-dsh $TAG" --notes-file "$NOTES" $ATT
    else
        run gh release create "$TAG" --title "openwrt-dsh $TAG" --notes-file "$NOTES" $ATT
    fi
    echo "== 发布完成: $(git config --get remote.origin.url | sed 's#git@github.com:#https://github.com/#; s#\.git$##')/releases/tag/$TAG =="
else
    SLUG=$(slug_from_remote)
    [ -n "$SLUG" ] || SLUG=$(printf '%s' "$(git config --get remote.origin.url)")
    URL="https://github.com/$SLUG/releases/new?tag=$TAG&title=openwrt-dsh+$TAG"
    if [ "$DRYRUN" -eq 1 ]; then
        echo "   [dry-run] 打开预填发布页: $URL"
    else
        echo "   已推送到远端;最后一步需你确认:"
        echo "   1. 发布页(已预填 tag 与标题): $URL"
        echo "   2. 说明从 $NOTES 粘贴,附件拖入 $OUTDIR 下的 ipk 与 sha256sums.txt"
        echo "   3. 点 Publish release,完成"
        if [ "$OPEN" -eq 1 ]; then
            open_url "$URL"
            echo "   (已尝试打开浏览器;没弹窗就手动开上面的链接)"
        else
            echo "   (未自动开浏览器,手动打开上面链接)"
        fi
    fi
fi

echo
if [ "$DRYRUN" -eq 1 ]; then
    echo "== dry-run 结束:以上为发布 $TAG 的完整计划,未做任何改动 =="
else
    echo "== $TAG 发布流程执行完毕 =="
fi
