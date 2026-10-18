#!/bin/sh
# openwrt-dsh 引擎：LAN 设置解锁补丁（默认涂抹，2026-10-21 拍板撤销开关，§26 补记）
# 用法: web-patch.sh state [运行时目录] | apply | revert（revert 留作手工维护工具）
#
# 为什么存在（porting-notes §26 源码级定位）：dsh 的「设置→模型/通用/外观」在浏览器
# 地址栏非回环（localhost/127.x/[::1] 之外）时整页拒载——web 客户端把「页面是否回环」
# 当安全边界，非回环页面的设置镜像直接终态 unavailable、从不发请求，LAN 打开就报
# 「加载提供商目录失败: settings are unavailable in this browser」。判定全在客户端
# 侧且只有一处真源：
#   dsh-client-connection/lib/client.js（installConnection 的 connection handle）
#     isLoopback: transport?.ownsHost === true || pageLocation === void 0
#                 || isLoopbackHostname(pageLocation.hostname),
# 其余消费方（dsh-api-gateway 的 $host.isLoopback、dsh-client-ui-settings 的
# persistence 选择等）全部转发它；服务端 settings 控制器没有第二道闸（Connection
# 认证覆盖 API，上游 README 自认）。所以给这一行打「恒真」单点补丁，LAN 页面的
# 设置读写即刻可用。残留边界：DeepSeek 账号登录上游仍只承诺回环/SSH 转发，与本
# 补丁无关；第三方 API-Key 提供商（设置→模型）不受影响。
#
# 纪律（同 elf-patch.js 与引擎全体）：
#   - 幂等：补丁行带 odw-web-lan 标记，重复执行原样退出；首次涂改前落 .odw-orig 备份
#   - 失败零损伤：锚点不在（dsh 上游变了）整体不动只报告；替换先写临时文件、校验
#     标记在场后原地覆写，失败回滚
#   - 全程 POSIX + busybox：锚点含 ?/|/[ ] 等 sed 正则元字符，字面量替换用 awk 的
#     index/substr 实现，不经正则
#   - 不拉 node：rpcd status 每 2s 轮询 state，必须毫秒级（state 只试最新运行时的
#     两个既定 npm 布局落点，纯 [ -f ] + grep -F；apply/revert 是用户操作，才全树 find）
# 目标文件随 npm 包走：install-dsh.sh install/update/doctor 无条件重涂（npm 重装
# 会整包替换 dsh 文件冲掉补丁，所以每次任务都要重涂；无 UCI 开关）。

set -u

MODDIR="$(cd "$(dirname "$0")" && pwd)"
. "$MODDIR/lib.sh"

# 补丁锚点与替换串（与 dsh 0.2.0-rc.2 的 client.js 逐字一致；上游改代码时 state
# 会报 changed，此时按新形态更新这三个值）
WP_ANCHOR='isLoopback: transport?.ownsHost === true || pageLocation === void 0 || isLoopbackHostname(pageLocation.hostname),'
WP_MARK='odw-web-lan'
WP_PATCHED='isLoopback: !0, /* odw-web-lan */'
WP_ORIG='.odw-orig'

# 纯字面量替换：<文件> 里每一处 WP_FROM → WP_TO。awk 的 -v 会二次解释 \n 等转义，
# 所以值经 ENVIRON 传（同 rpcd listdir 的做法）；WP_FROM/WP_TO 由调用方 export。
# 末条记录必须 printf 原样输出：npm 包内的 client.js 末尾**没有换行符**（实测末字节
# 为代码字符），print 会对它补 \n 多出 1 字节——还原校验（cmp）就过不去。CRLF 的
# \r 属于记录本体，print 补的是 \n，行尾形态天然保留（Git Bash gawk 实证）
wp_replace() {
	awk '
		BEGIN { a = ENVIRON["WP_FROM"]; b = ENVIRON["WP_TO"] }
		{
			r = $0; out = ""
			while ((i = index(r, a)) > 0) {
				out = out substr(r, 1, i - 1) b
				r = substr(r, i + length(a))
			}
			cur = out r
			while ((getline nxt) > 0) {
				print cur
				r = nxt; out = ""
				while ((i = index(r, a)) > 0) {
					out = out substr(r, 1, i - 1) b
					r = substr(r, i + length(a))
				}
				cur = out r
			}
			printf "%s", cur
		}
	' "$1"
}

# 全部目标：遍历安装目录下所有托管运行时。dsh 是 npm 包、可能同时存在多套运行时
# （LTS 升级链保留旧目录），补丁按「都涂上」处理，避免 web 服务挑中未涂的那套
wp_all_targets() {
	local inst
	inst="$(odw_install_dir)"
	find "$inst/runtime" -path '*dsh-client-connection*' -name client.js -type f 2>/dev/null
}

# 快路径目标（仅 state 用）：只试最新运行时的两个既定 npm 布局落点（包内嵌套 /
# 提升到顶层两种形态），纯 [ -f ] 判存——2s 轮询里绝不跑 find 全树扫
wp_fast_targets() {
	local r="$1"
	[ -n "$r" ] && [ -d "$r" ] || return 0
	local f
	for f in \
		"$r/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-client-connection/lib/client.js" \
		"$r/lib/node_modules/@deepseek-ai/dsh-client-connection/lib/client.js"
	do
		[ -f "$f" ] && printf '%s\n' "$f"
	done
	return 0
}

case "${1:-}" in
	state)
		# state [运行时目录] → state=patched|clean|changed|absent（rpcd status 快路径）。
		# changed = 有文件既非已涂又无锚点（dsh 上游改了代码），或已涂/未涂混杂——
		# 统一交 UI 引导重跑 doctor/重涂，本脚本不猜
		lst="$(mktemp /tmp/odw-wp.XXXXXX)" || { echo "state=changed"; exit 1; }
		wp_fast_targets "${2:-}" > "$lst"
		p=0; c=0; x=0
		while IFS= read -r f; do
			[ -n "$f" ] || continue
			if grep -qF "$WP_MARK" "$f" 2>/dev/null; then
				p=$((p + 1))
			elif grep -qF "$WP_ANCHOR" "$f" 2>/dev/null; then
				c=$((c + 1))
			else
				x=$((x + 1))
			fi
		done < "$lst"
		rm -f "$lst"
		if [ "$x" -gt 0 ] || { [ "$p" -gt 0 ] && [ "$c" -gt 0 ]; }; then
			echo "state=changed"
		elif [ "$p" -gt 0 ]; then
			echo "state=patched"
		elif [ "$c" -gt 0 ]; then
			echo "state=clean"
		else
			echo "state=absent"
		fi
		;;
	apply)
		# 涂补丁：先全体预检（任何文件既非已涂又无锚点 → 一概不动，保持状态可读），
		# 再逐文件备份→替换→校验→原地覆写。输出 result=ok|no-dsh|anchor-missing|error
		lst="$(mktemp /tmp/odw-wp.XXXXXX)" || { echo "result=error"; exit 1; }
		wp_all_targets > "$lst"
		tot=0; bad=0
		while IFS= read -r f; do
			[ -n "$f" ] || continue
			tot=$((tot + 1))
			if grep -qF "$WP_MARK" "$f" 2>/dev/null; then :
			elif grep -qF "$WP_ANCHOR" "$f" 2>/dev/null; then :
			else
				bad=$((bad + 1))
				printf 'unsure=%s\n' "$f"
			fi
		done < "$lst"
		if [ "$tot" -eq 0 ]; then
			rm -f "$lst"
			echo "result=no-dsh"
			exit 4
		fi
		if [ "$bad" -gt 0 ]; then
			rm -f "$lst"
			echo "result=anchor-missing"
			exit 5
		fi
		rc=0
		while IFS= read -r f; do
			[ -n "$f" ] || continue
			grep -qF "$WP_MARK" "$f" 2>/dev/null && continue
			t="$(mktemp /tmp/odw-wp.XXXXXX)"
			if [ ! -f "$t" ]; then rc=1; break; fi
			if ! ( export WP_FROM="$WP_ANCHOR" WP_TO="$WP_PATCHED"; wp_replace "$f" ) > "$t"; then
				rm -f "$t"; rc=1; break
			fi
			if ! grep -qF "$WP_MARK" "$t" 2>/dev/null; then
				rm -f "$t"; rc=1; break
			fi
			if [ ! -f "$f$WP_ORIG" ]; then
				if ! cp -p "$f" "$f$WP_ORIG" 2>/dev/null; then
					rm -f "$t"; rc=1; break
				fi
			fi
			if cat "$t" > "$f"; then
				printf 'patched=%s\n' "$f"
			else
				# 覆写失败（只可能是磁盘满/权限）：回滚备份，不留半涂文件
				[ -f "$f$WP_ORIG" ] && cat "$f$WP_ORIG" > "$f" 2>/dev/null
				rm -f "$t"; rc=1; break
			fi
			rm -f "$t"
		done < "$lst"
		rm -f "$lst"
		if [ "$rc" -ne 0 ]; then echo "result=error"; exit 1; fi
		echo "result=ok"
		;;
	revert)
		# 撤补丁：优先还原 .odw-orig 备份；备份丢了（迁移拷贝截断等）就按字面量逆向
		# 还原（补丁是确定性单串替换，可逆）。没有目标 = 本来就没开，照常 ok
		lst="$(mktemp /tmp/odw-wp.XXXXXX)" || { echo "result=error"; exit 1; }
		wp_all_targets > "$lst"
		rc=0
		while IFS= read -r f; do
			[ -n "$f" ] || continue
			if [ -f "$f$WP_ORIG" ]; then
				if cat "$f$WP_ORIG" > "$f" 2>/dev/null; then
					rm -f "$f$WP_ORIG"
					printf 'reverted=%s\n' "$f"
				else
					rc=1; break
				fi
			elif grep -qF "$WP_MARK" "$f" 2>/dev/null; then
				t="$(mktemp /tmp/odw-wp.XXXXXX)"
				if [ ! -f "$t" ]; then rc=1; break; fi
				if ! ( export WP_FROM="$WP_PATCHED" WP_TO="$WP_ANCHOR"; wp_replace "$f" ) > "$t"; then
					rm -f "$t"; rc=1; break
				fi
				if grep -qF "$WP_MARK" "$t" 2>/dev/null; then
					rm -f "$t"; rc=1; break
				fi
				if cat "$t" > "$f"; then
					printf 'reverted=%s\n' "$f"
				else
					rm -f "$t"; rc=1; break
				fi
				rm -f "$t"
			fi
		done < "$lst"
		rm -f "$lst"
		if [ "$rc" -ne 0 ]; then echo "result=error"; exit 1; fi
		echo "result=ok"
		;;
	*)
		echo "用法: web-patch.sh state [运行时目录] | apply | revert" >&2
		exit 64
		;;
esac
exit 0
