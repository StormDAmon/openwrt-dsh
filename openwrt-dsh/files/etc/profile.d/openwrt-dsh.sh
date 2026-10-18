#!/bin/sh
# openwrt-dsh PATH 集成（登录 shell）：/etc/profile 会 source 本目录下 *.sh
# （OpenWrt 22.03 与 24.10 的 base-files /etc/profile 均带该循环，官方容器实测过）。
# 把托管运行时 bin 动态前插进 PATH，使 node / npm / dsh 与普通 Linux 同形同位。
# 设计约束（勿凭直觉精简）：
#   - 安装目录以 UCI 为准（数据盘迁移后仍成立），不猜 $HOME（见 docs/porting-notes.md §9）；
#   - 动态挑最新 node-v* 目录，不写死版本路径——引擎 LTS 升级链会换目录；
#     用字典序取最大：引擎只装 v22.19+ 的运行时，主版本同为两位数时字典序即大小序；
#   - node 与 dsh 都在才前插：半装状态（只有裸运行时）不遮蔽系统里的 node；
#   - 幂等：PATH 已含该目录就不重复前插。
odw_profile_path() {
	local d b
	d="$(uci -q get openwrt-dsh.core.install_dir 2>/dev/null)"
	[ -n "$d" ] || d="/opt/openwrt-dsh"
	b=""
	for d in "${d%/}"/runtime/node-v*/bin; do
		[ -x "$d/node" ] && [ -e "$d/dsh" ] && b="$d"
	done
	[ -n "$b" ] || return 0
	case ":$PATH:" in
		*":$b:"*) : ;;
		*) PATH="$b:$PATH"; export PATH ;;
	esac
}
odw_profile_path
unset -f odw_profile_path
