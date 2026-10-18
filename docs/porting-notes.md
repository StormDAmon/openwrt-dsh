# 踩坑笔记（musl 机跑 dsh 的全部实测知识）

> 来源：本引擎在 iStoreOS 真机（OpenWrt 22.03 系 musl 1.2.3）、OpenWrt 官方 rootfs
> 容器（`openwrt/rootfs:x86-64-22.03.7` / `x86-64-24.10.8`，musl 1.2.3 / 1.2.5，opkg，
> 构建工具全缺）与 Alpine chroot（3.20 / 3.21，busybox ash）上的多轮实测，2026-09 ~ 2026-10。
> 引擎代码的每个顺序与探测级位都对应下面某一条；**改动前先读对应条目，别凭直觉精简**。
> 公开社区（截至 2026-10）搜不到这些记录——它们就是本项目的护城河。

## 0. 问题全景：为什么路由器上装 dsh 不是 `npm install -g` 一句话的事

dsh 依赖树（undici@8、pi-ai、koffi、node-pty 等）要求 node ≥ 22.19，且带原生模块。
OpenWrt/iStoreOS 是 musl libc + busybox，五连坑：

1. 官方 Node linux-x64 包是 glibc 链接（INTERP=`/lib64/ld-linux-x86-64.so.2`），musl 机上
   直接「No such file or directory」起不来；
2. musl 版 Node 有 unofficial-builds，但它动态链接 libstdc++/libgcc，而裸 OpenWrt 没有
   libstdc++、22.03 的 libstdc++ 还是裁剪过的（见 §2）；
3. 原生模块预构建基本只有 glibc 版（koffi 例外，node-pty 不例外，见 §5 §6）；
4. 没有 systemd、没有 bash、没有 cmake，overlay 分区常 <100MB；
5. 老 musl 加载器（1.2.3）连 musl 版 node 真身都拉不动（见 §3）。

## 1. Node 运行时获取

- **musl 构建**：`node-vX-linux-x64-musl.tar.gz`，来自 nodejs **unofficial-builds**。
  逐版本核过 v18/v20/v22/v24，x86_64 只有 `glibc-217` 与 `musl` 两变体，没有静态构建可用。
- **镜像**：这棵树**只有 npmmirror 镜像**（`registry.npmmirror.com/-/binary/node-unofficial-builds`
  与 `cdn.npmmirror.com/binaries/node-unofficial-builds`）；清华/华为云/阿里云/USTC 只镜像
  官方 dist，实测 404。官方源作兜底。
- **must 实测 `node -v` 成功才算下载成功**：下载/解压都成功但跑不起来是常态（缺库/库旧），
  不能把「文件就位」当成功，否则会误报「该源不可用」继续换源（各源同一份文件，换源无用）。
  换源触发条件要限定在**下载/解压失败**。
- **版本升级链**：取最新 LTS（index.json 里 `lts != false`），最多试 3 个候选（个别版本
  musl 构建 404）。解出的目录名 `node-vX-linux-x64-musl` 收敛成 `node-vX` 再用。
- **wget 超时**：busybox wget 静默且默认无总超时，黑洞地址会永久挂住——`-T 120/60` 必带。

## 2. musl 运行库三件套（引擎 `odw_fix_runtime_libs`）

musl 版 node 跑不起来有两类报错，**opkg 都救不了**：

- ① 库完全缺失：`Error loading shared library libstdc++.so.6`（OpenWrt 包名 `libstdcpp6`，
  且 opkg 装的是 22.03 老版，见②，还是救不了）；
- ② 库在但太旧：`Error relocating …: symbol not found`（全是 `std::__cxx11` 符号）。
  musl 加载器**按符号名直查、忽略版本**；OpenWrt 22.03 的 libstdc++ 11.2 是**裁掉 dual ABI**
  编译的，没有 `__cxx11` 符号。opkg install 只回「已安装」不升级。

修法（主路径）：从 **Alpine main 仓库**取三个 .apk（本来就为 musl 编，合计约 1.4MB）：
`libstdc++`、`libgcc`、**`musl`（自带加载器 ld-musl + libc 本体）**，解出 .so 放进运行时
`lib/`。固定 **v3.21 系列**（GCC 14.2 / musl 1.2.5，符号够新；Alpine 已发布系列的仓库永久
保留不失踪）。**不写系统目录、不依赖包管理器**，「缺失」「过旧」两种情形都救。

实测细节（每条都真踩过）：

- **APKINDEX 推文件名**，不解析目录列表 HTML：各镜像转义不一（阿里云把 `+` 转成 `&#43;`）。
  从 APKINDEX 按 `P:`（包名）/`V:`（版本）行推「包名-版本.apk」。**`V:` 值必须在遇到新 `P:`
  行时重置**——APKINDEX 前排 `libcrypto3` 的 `V:3.3.7-r1` 会污染下一个包，曾解出
  `libstdc++-3.3.7-r1.apk` 全线 404。
- **镜像顺序**：阿里云放首位——清华/USTC 对 busybox wget 的 UA 回 403。
- **apk 是多段 gzip tar 且符号链接条目排在实体文件之前**：MSYS/GNU tar 按序解压在建链时报
  「Cannot create symlink … No such file or directory」并整体失败（busybox 1.36 与新版
  GNU tar 不复现）。旧代码 `2>/dev/null || ok=""` 会把它静默吞掉。现在解压报错不中断
  （实体文件通常已解出），随后显式 `ln -sf` 补齐 `libstdc++.so.6` 等链接名（幂等），以
  实体文件齐全为成功判据。
- **自带 libc 绝不能进 LD_LIBRARY_PATH**（收进 `lib/musl/` 子目录）：系统加载器配自带
  libc 会版本错配。三件套整链在子壳里跑，一个镜像失败自动换下一个。

## 3. 老 musl 加载器拉不动真身 → PT_INTERP/DT_NEEDED 双 ELF 补丁

22.03 真机（musl 1.2.3）上，musl 版 node 真身**直拉本身就段错误**（退出码 139），
Docker `openwrt/rootfs:x86-64-22.03.7` 原样复现；24.10（musl 1.2.5）无此问题。

修法（引擎 `odw_patch_runtime` + `elf-patch.js`，仅当「直拉探测失败 + 自带件齐全」时触发）：

- **① PT_INTERP → `$HOME/.s/ld`**：自带加载器的 HOME 下短路径符号链接。新路径必须塞得进
  原 interp 段（按 `p_filesz` 预算），塞不下就放弃。
- **② DT_NEEDED `libgcc_s.so.1` → `$HOME/.s/g`**：**②不可省**——见 §4，libgcc 不能走环境。
- 加载器即 libc，配自带 libstdc++ 后直拉自洽；`process.execPath` 回归真身（cnoke 校验可过）。
- 补丁写新文件 → `chmod 755` → 探测通过才 `mv` 原子顶替；失败零损伤（加载器垫片不吃
  interp/NEEDED，node 照常能跑）。幂等：直拉已通（含补丁过的旧目录）整段跳过。
- 补丁器只认小端 ELF64 且 interp 含 `ld-musl` 的文件（glibc 构建不动）；单测矩阵见
  roadmap（双改写/幂等/非 musl 拒改/超段长/无动态段）。

## 4. 环境毒性：libgcc_s 进 LD_LIBRARY_PATH 会毒化全机

22.03 容器实测：**环境里出现自带（Alpine，musl 1.2.5/GCC 14.2）的 libgcc_s 时，同机一切
动态 busybox 子进程（sed/env/sh -c/npm 链）10/10 段错误；只放 libstdc++ 则 0/10 无害。**

结论：**环境里只允许出现 libstdc++ 专属目录（`lib/lstd/`）**；node 的 libgcc 走 §3 的
DT_NEEDED 补丁绝对路径进 node，绝不进环境。这就是三级垫片的存在理由：

1. **①直拉 + 仅 lstd/**：系统有 libgcc_s（openwrt/iStoreOS 必有，busybox 依赖）→ 纯 lstd；
   极简机（无系统 libgcc_s）补全 lib 兜底。
2. **②直拉 + 全 lib**：给新 musl 机上①不够用的情形（其系统库与自带同源，无害）。
3. **③显式自带加载器**：`exec ld-musl --library-path lib node.bin`，保底；
   代价是 `process.execPath` 变成加载器（见 §5）。

垫片探测的壳层写法（busybox ash 特性，两处都是实测踩的）：

- 探测用 `( :; <cmd>; ST=$?; :; [ "$ST" -eq 0 ] ) 2>/dev/null` 形态：子壳内信号死亡时
  ash 的提示会从父壳 stderr 冒出，且**子壳末命令会被 exec 优化**导致 `$?` 语义丢失——
  前插冒号 + 末尾内建测试压住；
- `set -u` 脚本里垫片函数自引用未定义变量会整脚本炸掉，垫片生成模板里的变量必须全部有值。
- 上面这条的 2026-10-11 新变种（24.10 容器实测，rc=2 整装失败）：垫片模板想输出 `$L` 时
  生成侧写成 `LD1="$L/lstd"`——生成器上下文里 `$L` 不存在，`set -u` 当场击杀。修法：生成侧
  用**单引号字面量**（`LDL='$L/lstd'`）让 `$L` 原样进模板，由垫片运行时自己解析。
- **垫片绝不能烘焙绝对路径**：wrap_node 在「解压目录 → 正式版本目录」改名**之前**执行，
  烘焙了旧路径的垫片在改名后指向不存在的目录。更阴险的是安装期全绿掩盖它——探针全走
  libexec 硬链 + 安装脚本显式 export 的 env，垫片根本没被外部踩过；任何外部调用（登录
  shell/wrapper/doctor）一碰就「Error relocating node.bin: symbol not found」满屏炸
  （24.10 容器实测）。修法：垫片内一律相对路径（`$D`/`$L` 从 `$0` 自算），③ 级本来
  就是这么写的，①② 级已统一；doctor 的垫片自愈（-v 失败即重包）是这类残局的兜底。

## 5. koffi 的 execPath 坑 → libexec 真身硬链

koffi 的 cnoke 校验预构建用 `spawnSync(process.execPath, ["-e", …])`。垫片形态下
`process.execPath` 是**加载器本体**，于是变成 `ld-musl -e …` → `cannot load -e`（探针
从 cnoke 内部抓到原文）→ 判预构建无效 → 回源码编译 → OpenWrt 无 cmake → 整装失败。
**koffi 的 musl 预构建其实就在平台包 `@koromix/koffi-linux-x64` 里（`musl_x64/`），装得上
却被判失败**——这是 24.10 容器实测 A/B 实证的（同一棵 koffi 树：PATH 首为垫片 cnoke
exit 1，PATH 首为真身 exit 0）。

且 npm **不会**把 execPath 所在目录前插 PATH，生命周期脚本里的裸 `node` 由外层 PATH 决定，
真身与垫片同住 `bin/` 时裸 node 必落回垫片——只改 PATH 不够。修法（引擎 §3 of
install-dsh.sh）：`libexec/node` **硬链真身**（失败退 cp）+ 前插 PATH + `LD_LIBRARY_PATH`
只喂 lstd，npm 与校验全经它执行。**硬链每次重建**：真身可能上轮刚被补丁换过 inode，旧链
会钉在补丁前的老文件上。直拉探测不过就全程留在垫片上（代价仅 cnoke 绕不过），**绝不**在
探测失败的机器上直跑真身（那就是 §3 的段错误死法）。

## 6. node-pty 的 musl 断档 → 随包分发自编译原生件 + 实载探针

上游 node-pty 1.2.0-beta.15 自带预构建**只有 glibc 版**（`DT_NEEDED` 为
libc.so.6/libpthread/libutil；无 interp/RUNPATH）。在 musl 上「懒解析能 dlopen、一调用
即 SIGSEGV」——`pty.open()` 当场崩，node22/24 表现一致（24.10 容器实测，排除 node 版本
因素；同版本 addon 在 glibc 上交互正常作对照）。

修法：在 **Alpine 3.21**（`npm_config_build_from_source=true` + `nodedir` 走 nodejs-dev
头文件）源码编译出 musl 原生件，`DEP` 恰为
`libc.musl-x86_64.so.1/libstdc++.so.6/libgcc_s.so.1`——与自带三件套同源，零系统依赖。
该文件随 ipk 分发（`/usr/share/openwrt-dsh/node-pty/linux-x64/pty.node`，76KB），安装任务
在 musl x86_64 上顶替 `prebuilds/linux-x64/pty.node` 后**跑真实 pty 探针**（spawn /bin/sh
+ 写入 echo + 断言回显）。顶替过仍失败判任务失败（宁可红不给假绿）；本机无件可用（非
musl/架构缺）只提示不改判。

## 7. npm 层的坑

- **allowScripts 闸**：npm ≥ 11.19 起全局安装默认跳过未登记的依赖生命周期脚本。
  **2026-10-11 在 24.10.8 容器（npm 11.19.0）上把取值形态逐一实测**：`--allow-scripts=true`
  （无论 CLI 末尾还是 npmrc）**不生效**——npm 只把值当包名列表解析，`true` 和通配 `*` 都不是
  包名；**唯一生效形态是显式包名列表**（如 `--allow-scripts=@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs`，
  或 npmrc `allow-scripts=<列表>`；两者同给时 CLI 覆盖 npmrc 并打一条 warn）。旧版 npm
  视未知配置无害。本条早先记录的「`=true` 加在命令末尾才生效」在 11.19.0 上不再成立，
  应是 npm 语义后来收紧——引擎 RUN_LINE 与运行时 npmrc 已改为列表形态（同一份变量）。
  放行的意义不变：koffi 的 cnoke 预构建校验在安装期就真跑（缺构建工具等问题显式暴露）；
  跳过看似温和实则更糟，node-pty 缺原生件 dsh 终端运行时才炸。
- **孤儿 bin/dsh EEXIST**：上轮安装在 bin 链接落盘后中途暴毙（npm 段错误/被杀，回滚半途
  而废）会留下孤儿 `bin/dsh`。npm 全局装 bin 前必查既有项，非「指向本包内目标」的一律
  EEXIST 拒装且不随重装自愈——重装从此次次卡死（真机 139 时代正是这类死法）。装前
  `rm -rf bin/dsh`（有效链接也会原样重建，包目录交给 npm 自己替换）。
- **koffi 定向重编**：安装失败十有八九是 koffi 预构建加载失败又没编过；找到它的包目录跑
  `node cnoke.cjs -P . -D src/koffi --prebuild --release` 成了就重试一次。
- **装后实载校验**：koffi `require()` 探针 + node-pty pty 探针，失败宁可判红不给假绿。

## 8. 版本索引（index.json）解析

2026 起官方/镜像 index.json 改**一行一个对象**的多行排版（老格式整行 `},{` 相连）。
三处实测坑（awk 兜底里都修了）：

- 切分对象**不能再用含 `{` 的正则**：24.10.8 容器的 busybox awk（自研正则引擎，非 libc
  regcomp）`gsub(/},{/,…)` 直接报「Invalid contents of {}」（把 `{` 当区间表达式解析），
  `[{]` 括号字面量能编译但**永远匹配不上**，`/\},{/` 转义花括号直接拒编译——三种写法全灭
  （2026-10-11 逐一实测）。现在改用 `index(s, "},{")` 纯字符串查找循环切分，零正则、
  GNU/busybox/musl awk 通吃；好在 `"lts"`/`"version"` 的取值仍走 `match+substr`（不含花括号，安全）；
- `"lts":false` 是**不带引号的布尔值**，按引号切字段会跳到下一字段名上，Current 线全被
  误判成 LTS——改 `match+substr` 取值；
- 降序 Top-3 用 awk **插入排序**，不用 sort：多键 `-k` 与全局 `-r` 的覆盖语义 GNU/busybox
  不一（逐键 `-k1,1n` 才能压掉）。

引擎实现：有能跑的 node 用 node 解析，**一个 node 都跑不动时 awk 兜底照样成立**
（这个函数存在的意义就是救 node，不能依赖 node 存在）。

## 9. 安装目录与空间

- flash overlay 常 <100MB；运行时+dsh 要 300MB 级。**空间预检查目标分区**
  （`df -Pk`，目录不存在时查父目录），不足明确报错并指路改 UCI。
- 支持自定义安装根（数据盘典型 `/mnt/nvme0n1-4/...`）。实测教训：**运行时目录锚定
  server 真实安装根而不是猜 `$HOME`**——procd/后台任务壳里 HOME 可能是 /root 而安装却
  在数据盘，按 $HOME 找 runtime 永远扑空（自愈/选择/解压全扑空）。本项目引擎统一经
  `odw_runtime_dir()` 从 UCI 取，不猜 HOME；仅 ELF 补丁的 `$HOME/.s` 短链接用 HOME
  （补丁路径长度受限，HOME 路径短才能塞进 interp 段）。

## 10. 平台与 Busybox 壳层守则

- **全体 POSIX**：无进程替换、无 `[[ ]]`、无数组；`local` 可用（busybox ash 支持）。
- 语法检查最低门槛：`sh -n`（ash 语义）+ `bash -n` 双过（见 tools/dev-check.sh；
  更严的用 busybox ash 或 dash 再过一遍）。
- 字符串比较别用 `[ a \> b ]`（busybox test 不可靠），版本比较走 `odw_node_ge`（awk）。
- **musl 判别**只看 `/lib/ld-musl-*.so.1` 存在，不 exec、不猜发行版。
- 引擎所有「探测」都遵循**先探测后采用、失败零损伤、幂等可重跑**三原则——路由器上任务
  中途断电/被杀是常态，重跑必须能自愈（垫片自愈、补丁幂等、孤儿 bin 清理都是为此）。

## 11. 验证方法学（如何在新机器/新版本上复验）

**项目约定：本工程所有的测试都通过 OpenWrt 官方 Docker 进行**（`openwrt/rootfs:x86-64-*`
官方镜像；下述容器层即默认验收环境）。不在宿主机上裸测。

本引擎定型时的验证矩阵，继续沿用：

1. **语法层**：生成/手写脚本 `bash -n` + `sh -n` 双过；JS `node --check`。
2. **单元层**：ELF 补丁器矩阵（合法补丁/幂等/glibc 拒改/段长超限/非 ELF/无动态段）；
   index.json 三种排版（unofficial musl 线/官方 glibc 线/单行合成）node 与 awk 解析
   逐字节一致。
3. **容器层**（与真机同底 musl 才有效）：`docker run openwrt/rootfs:x86-64-22.03.7`
   复现老加载器死法 → 修复后整链安装全绿；`24.10` 回归补丁块应整段跳过。
4. **chroot 层**：Alpine minirootfs + `unshare --map-root-user` + chroot，清空代理 env，
   验证「裸机缺库」与「自动补齐」。
5. **真机层**：iStoreOS/OpenWrt 真机端到端（安装→更新→卸载重装→断电重跑幂等）。

已知测试环境坑：宿主 `HOME`/代理 env 会泄漏进 chroot；`127.0.0.1` 代理在容器内不通；
测试假 opkg/fake node 时注意 dash/ash 对信号死亡提示的差异。
另：容器内 `opkg` 前要 `mkdir -p /var/lock`（真机 tmpfs 自带）；24.10 rootfs 无 `nohup`。

## 12. 与普通 Linux 的一致性：PATH 集成与官方安装路径（2026-10-11 双容器实测定型）

目标是「装完本包后，用户装/用 dsh 的方式与普通 Linux 一致」。实测定型为三层：

1. **使用一致（登录 shell）**：OpenWrt 22.03/24.10 的 `/etc/profile` 都会 source
   `/etc/profile.d/*.sh`（两个分支 base-files 同款循环，容器确认）。包里自带
   `profile.d/openwrt-dsh.sh`：从 UCI 锚定安装目录（数据盘迁移后仍成立，别猜 `$HOME`），
   动态挑最新 `node-v*`（不写死版本目录，引擎升 LTS 会换目录；主版本同为两位数时字典序
   即大小序），node 与 dsh 都在才前插 PATH（半装状态不遮蔽系统 node），幂等不重复前插。
2. **使用一致（无 PATH 的调用方）**：npm 产出的 `bin/dsh` 指向 `lib/bin.js`，其 shebang 是
   `#!/usr/bin/env node`——**软链 `/usr/bin/dsh` 在 cron/procd/ubus/非登录 SSH 里必死**。
   所以 ipk 直接把 `/usr/bin/dsh` 装成一个 wrapper 脚本（解析 UCI + 挑最新运行时 + 补 PATH
   再 exec），`env -i` 空环境实测可用。它归 opkg 管，引擎不再插手（旧版引擎的 `ln -sfn`
   收尾已删）。
3. **安装一致（官方指令的诚实上限）**：跑过一次 `openwrt-dsh install` 后，运行时里有
   `etc/npmrc`（allow-scripts 包名列表 + 镜像源，见 §7），此后**照官方文档裸跑
   `npm install -g @deepseek-ai/dsh` 能装上且原生件脚本会跑**。但 npm 重装会重新解出
   node-pty 的 glibc 预构建（§6：懒解析骗过安装期，`pty.open()` 才 SIGSEGV）——我们没有
   dsh 包的 postinstall 钩子，无法在官方指令内部介入，**裸装后必须跟一次
   `openwrt-dsh doctor`**（不下载不重装：垫片自愈 → pty 顶替 → koffi/pty 实载 → 落标记；
   koffi 实载失败且机器有 cmake/make 时定向重编一次再复测）。这就是「与普通 Linux 一致」
   在 musl 机上的诚实上限：官方指令可用，但要加一条修复尾巴； LuCI 一键 `install` 仍是
   保证全绿的主路径。

2026-10-11 双容器验收记录（均为官方镜像全新安装 rc=0）：`x86-64-24.10.8` 主链路 +
ELF 补丁块整段跳过；`x86-64-22.03.7` 老加载器 → 垫片退 ③ 级 → PT_INTERP/DT_NEEDED
双补丁生效（interp→`$HOME/.s/ld`，DT_NEEDED→`$HOME/.s/g`）→ 直拉恢复 → cnoke 可用。
两机四场景（登录 shell / `/usr/bin/dsh` / `env -i` / `sh -c`）`dsh --version` 全过；
官方 `npm i -g` + doctor 收尾链路两机同过。过程中新修三个真 bug，见 §4（垫片绝对路径 +
生成器 `$L` set -u）、§7（allow-scripts 列表形态）、§8（busybox awk 花括号正则）——
全部是「代码看起来对、容器一跑就炸」的类型，P0 容器冒烟的价值实证。

## 13. SDK 构建的坑：自带 ELF 资产会撞上 buildroot 依赖扫描（24.10.8 实测）

首次真打 ipk（官方 SDK 24.10.8 x86_64，tools/build-ipk.sh）时，core 包在
ipk 元数据生成阶段直接失败：

```
Package openwrt-dsh is missing dependencies for the following libraries:
libc.musl-x86_64.so.1
libstdc++.so.6
```

机制（include/package-pack.mk 的 `CheckDependencies` + scripts/gen-dependencies.sh）：
打包前用 `file` 魔数扫 install 目录里的**每个 ELF**，抽 NEEDED SONAME，逐个对照
「本包自带(仅收 `lib*.so*`/`*.ko` 文件名) + DEPENDS 闭包 provides + extra_provides」，
有一个对不上就拒打包。`pty.node` 是 Alpine musl 预构建，NEEDED 的是
`libc.musl-x86_64.so.1`（Alpine 给 musl 改的 SONAME，OpenWrt 的 musl 永远不会有这个
文件名）和 `libstdc++.so.6`（引擎自带三件套、刻意不依赖系统库，DEPENDS 里没有
libstdcpp6）——扫描器不懂「自带」哲学，两个都判 missing。

修法是走 buildroot 的官方扩展点 `Package/openwrt-dsh/extra_provides`：声明这两个
SONAME 本包自带。要点：**extra_provides 只喂扫描校验，不会往 ipk 的 Depends 控制字段
加东西**，`opkg info` 看到的依赖仍然是 curl/ca-bundle/ca-certificates——自带运行库的
设计原样保留。两个候选的错误修法记下来防回头：加 `+libstdcpp6` 依赖（给路由器强塞
系统 libstdc++，违背 §2 的自备原则，且 libc.musl-* 那条还是过不去）；改 pty.node 的
NEEDED（§3 的双补丁就是干这个的，别在资产上动手）。

另记 SDK 构建的两个非坑事实：DEPENDED 闭包里 curl/ca-* 不在 SDK 预选里会刷一片
`WARNING: ... dependency on 'curl', which does not exist`——arch=all 包不编依赖本体，
警告无害，ipk 的 Depends 字段照写；luci feed 只需 `feeds update luci && feeds install
luci`（luci.mk 就位即可），不必 `update -a`。

## 14. 软件包自更新（GitHub Releases）的坑（2026-10-16，24.10.8 容器端到端实测）

LuCI「检查更新/立即更新」走 GitHub Releases 的实现层，四个非直觉点，全都在
官方 24.10.8 rootfs 容器里实测过（含真 opkg 升级链 0.1.0-r3 → 0.1.0-r4）：

1. **探测最新 tag 不走 api.github.com，走 `releases/latest` 的 302**。CN 网络对
   api.github.com 基本不可达，且 gh-proxy 系加速代理只代 `github.com/*` 路径形态；
   `curl -w '%{url_effective}'` 拿重定向终址（必含 `/releases/tag/vX.Y.Z`），代理前缀
   形态下终址同样含 tag，正则与代理无关。**curl 别带 `-f`**：老版 curl（22.03 的 7.x）
   在 `--fail` 时不输出 `-w` 结果，终址就丢了；404/私有仓靠「解析不出 tag 即失败」兜住，
   不需要 -f。
2. **OpenWrt 的 `wget` 不是 busybox，是 uclient-fetch 的符号链接**。它没有 `-S`（传了
   直接 `unrecognized option`），会自动跟 302，但对非 200 终页**不吐正文**；且不带
   libustream 时没有 TLS 能力（本包硬依赖 curl，wget 路只是兜底）。所以 wget 兜底路
   不能抄「-S 抓 Location 头」的 busybox 套路，要退化成「取终页正文，grep canonical 里
   的 `/releases/tag/vX.Y.Z`」——GitHub 标签页 200 正文必含 canonical/og:url，Alpine 的
   真 busybox wget 同样适用。Alpine/Debian 的 busybox wget 有 `-S`，OpenWrt 没有，
   「busybox ash」不等于「busybox 一切」。
3. **opkg 升级会原地截断替换引擎脚本，而 ash 按文件偏移增量读脚本**。selfupdate 任务
   跑到一半，`task.sh`/`selfupdate.sh` 自己就是被替换对象——tar 解包对已存在文件是
   O_TRUNC 打开（同 inode 截断），运行中的 ash 随后从旧偏移继续读，读到的是新文件的
   错位字节，收尾的状态落盘会执行成垃圾。修法：task.sh 第一趟把 `task.sh/lib.sh/
   selfupdate.sh` 复制到 `/tmp/openwrt-dsh/selfrun` 后 `exec` 副本重入（`ODW_SELF_RUN=1`），
   自此运行期不再读引擎目录里的任何脚本；exec 会清掉退出 trap，副本里要补回锁清理。
   删副本（`rm -rf` 自身正在执行的脚本目录）是安全的——ash 持有已打开 inode。
4. **发布资产的文件名可推断的前提是 PKG_RELEASE 每次发布重置为 1**（release.sh 已做）：
   ipk 版本串 = `$(PKG_VERSION)-r$(PKG_RELEASE)`（include/package-defaults.mk 实锤），
   所以 tag `vX.Y.Z` 对应资产 `openwrt-dsh_X.Y.Z-r1_all.ipk`。资产定位仍以
   `sha256sums.txt`（release.sh 固定上传）为第一优先——里面有确切文件名与哈希，推断名
   只是清单缺失时的兜底；哈希校验不过就放弃安装，宁缺毋滥。

版本比较只取 `X.Y.Z` 三段（`0.1.0-r3` 去掉 `-rN`、`v0.2.0` 去掉 `v`，复用 `odw_node_ge`）；
opkg 无本包记录（手工部署）时 available=unknown 交用户决断，不假装「已是最新」。
status 快照路径只读 `/tmp` 缓存（`update-check`/`pkg.version`），绝不联网——这是 §11
快路径纪律在自更新上的延伸。仓库必须公开：私有仓匿名 404，表现为「检查失败」，
提示语已引导配加速代理。

## 15. 装完「按钮没反应」：rpcd 只在启动/SIGHUP 时扫描 /usr/libexec/rpcd（2026-10-17 真机实锤）

现象：ipk 覆盖安装后包文件全部就位（引擎/LuCI/后端/ACL 逐字节核对一致），但 LuCI
页面的安装/更新/doctor/卸载/自更新按钮点了毫无反应，SSH 里任务也从没跑过。

实锤链（家中路由器 iStoreOS）：`/usr/lib/opkg/info/openwrt-dsh.control` 显示 r4 已装、
包内文件与仓库逐一比对一致，但 `/tmp/openwrt-dsh` 不存在——task.sh 一被拉起就必然
`mkdir -p $ODW_STATE_DIR` 并落状态，目录不存在 = rpcd 后端压根没被调用过 =
`luci.openwrt-dsh` ubus 对象没注册。

根因：**rpcd 是常驻进程，只在启动与 SIGHUP 时扫描 `/usr/libexec/rpcd/*` 并用 `list`
参数枚举各脚本的 ubus 方法**；装包/覆盖安装只落文件，不重扫。本包 2026-10-15 起为
rules.mk 单包形态、不走 luci.mk，而 **luci.mk 默认会给每个包生成一段 postinst
（清 `/tmp/luci-indexcache.*`、`/tmp/luci-modulecache/` + `/etc/init.d/rpcd reload`）**，
脱离 luci.mk 这层就丢了，必须在自己的 Makefile 里补 `Package/openwrt-dsh/postinst`
（内容见 Makefile，IPKG_INSTROOT 守卫防固件构建期误跑）。官方 rpcd 包对
rpcd-mod-\* 也是同样的 postinst reload（openwrt 提交 "reload rpcd on installation"，
选 reload 不选 restart 是为了不断 LuCI 会话；rpcd 的 init 脚本 reload = procd_send_signal
= SIGHUP）。清缓存那两行同不可省：menu.d/视图变了，LuCI 的 index/module 缓存不清，
新菜单/新页面不出现。

验证姿势：覆盖安装新包后**不重启**，直接刷新 LuCI 页面按钮应即生效；SSH 侧可用
`ubus call luci.openwrt-dsh status` 一键判定后端是否注册（报
"Unknown object" 就是没 reload）。

前端侧的伴生坑（r6 补记）：LuCI 的 rpc 层（luci-base 的 rpc.js）对 ubus 错误
（对象未注册/权限拒绝/后端崩溃）**默认不 reject**——`req.raise` 未开时，错误应答
`result=[错误码]` 经 `expect` 合并被静默吞成 `{}`，status 调用看起来「成功」了。
所以后端死活在前端长得一模一样，`applyStatus` 只能靠 `!st.arch` 误报后端不可用。
r6 起横幅文案改为给出真实补救动作（reload rpcd + 强刷，重装是最后手段——对
r4 及更早的已装包，重装多少遍都不会好）；并把请求层失败（HTTP 错误/超时的
reject 路径）也接进同一横幅——此前那条路是纯静默，按钮灰死且无任何提示。

桥层第二坑：exec 插件的调用约定（r7 实锤，2026-10-17 双容器）。现行 rpcd
（22.03.7 的 2022-12-15 与 24.10.8 的 2025.09.01 均实测）拉起脚本的形态是
**`<脚本> call <方法名>`**——JSON 参数走 stdin，stdout 第一个完整 JSON 对象即
应答（`rpc_plugin_call_stdout_cb` 是增量 json_tokener，解析到第一个完整值即封口，
所以 stdout 必须干净，JSON 前不能有任何杂输出）；签名扫描仍是 `<脚本> list`。
后端原先只写了 `<脚本> <方法名>` 的旧形态——**对象注册成功、方法调用必回落到
`*` 分支输出 `{}`**：即使 postinst/reload 把注册修好，页面依旧误报后端不可用。
两种死法（未注册 vs 协议不匹配）在前端无法区分，因为 rpc.js 把它们都吞成空对象。
这意味着桥层在所有目标平台从未工作过——2026-10-11 的容器矩阵只测了引擎层，
漏掉的正是这层。回归脚本 `work/luci-rpcd-test.sh`（red=装无 postinst 的旧包复现
注册失败；green=升级新包零手工自愈 + status/mkdir/listdir 带参验证 + uhttpd 静态
层 200），跑法见脚本头注释；**凡动 rpcd 桥/LuCI 层，双版本容器各跑一遍**。
已知小欠账：postrm 未补 reload（remove 后 ubus 对象残留到 rpcd 下次重启，菜单
随 fs 依赖消失、实际调不到，危害趋零）。

## 16. 全量 e2e 复测修掉的四个真 bug（2026-10-18，双容器 full-e2e.sh）

r8 打包了 `work/full-e2e.sh`（单容器全功能 e2e：打包/postinst/引擎 install 全链路/
入口四场景/doctor/官方 npm 路径/update/uninstall keep+purge/selfupdate 全链/锁与忙/
JSON 转义/listdir/mkdir 边界/CLI 全家/22.03 ELF 补丁回归，双版本各一份跑法见脚本头），
首跑即抓出四个「代码看着对、容器一跑就炸」的真 bug——全是老朋友的新变种：

1. **status.sh 多运行时取最旧**：目录扫描的比较方向写反（`odw_node_ge newest v`），
   挑中**最小**版本目录；LTS 升级链保留旧目录，升级后 status 的 node_dir 与慢路径
   dsh 探测全指向旧运行时。修法：新版本 >= 当前才替换（与 odw_pick_runtime 同向）。
   此前没暴露只因测试环境永远只有一个运行时目录。
2. **doctor 在「只有运行时、没有 dsh」时报通过**：卸载 keep 之后点 doctor，koffi/pty
   探针双双因目录缺失而「提示后跳过」，RC 保持 0，一路走到写标记，把 `dsh.version`
   写成「未知」——状态页从此误显已装。修法：doctor 开头先验 `$CHOOSE/bin/dsh` 存在，
   收尾对 `dsh --version` 的空输出判失败（宁红勿假绿，标记永不写「未知」）。
3. **selfupdate 会降级**：版本比较只判「等于即跳过」，本机比远端最新发布还新
   （fork 指旧 tag/上游回滚）时会照装旧包。修法：`odw_node_ge latest now` 不成立
   即「只升不降」收工。
4. **uninstall 的 npm 环境毒化全脚本（§4 的活体再犯，22.03 实锤）**：
   `run_npm_uninstall` 里 `ldexec="${ODW_LDEXEC_ENV:-$d/lib}"`——本函数不被
   prepare_runtime 包着，环境变量恒空，默认把**整个 lib（含自带 libgcc_s）**导进
   LD_LIBRARY_PATH。此后脚本 exec 的每个 busybox 工具（rm/ls/sleep/ps）按 §4
   **概率性段错误**，而且全家桶式连环伪装：
   - `rm -f 版本标记` 段错误 → 文件根本没删，紧接着的「已移除版本标记」是谎言
     → 表现为「卸载后 dsh.version 复生」（实为从未离开）；
   - `ls` 段错误输出为空 → 「1s 后已不在」的取证也是谎言；
   - `sleep` 段错误即退 → 仪器化的 sleep 1/sleep 4 形同虚设，时序全部失真；
   - 诊断过程中这些段错误被误读成「npm 的残留子进程」「标记复生的写者」，
     抓了十几轮幽灵。**破案钥匙：干净环境重跑 + 只信文件的 mtime，不信任何
     工具的退出码**。24.10（musl 1.2.5，系统 libgcc 较新）全程不触发，双容器
     矩阵缺一不可。修法：uninstall 的 ldexec 与 install 的 prepare_runtime 同语义
     （lstd 优先、仅无系统 libgcc_s 的极简机追加全 lib 兜底）；install 的同名
     兜底一并加固；版本标记删除后复核存在性，删不掉如实报错退出 1。

另记两条测试工程学（都真烧过时间）：
- **SDK 打包会自动 strip 掉随包 ELF**（`pty.node` 76KB→60KB，去 section header）：
  BuildID/DT_NEEDED 不变，dlopen 不受影响，e2e 已实测 strip 版实载通过；但
  「仓库资产 ≠ 发布物字节」这件事要心里有数，比对发布物时以 NEEDED/BuildID 为准。
- **登录 shell（`ash -lc`）会先吐 /etc/profile 的 OpenWrt 横幅**，脚本断言取输出
  末行；卸载 keep 之后 profile.d 按「node+dsh 都在才前插」的设计不再导运行时
  PATH，官方 npm 路径的测试要自己补 PATH——这两个都是测试脚本的坑，不是引擎的。

## 17. 新版 LuCI 上弹窗全灭：showModal 签名变更 + createHandlerFn 转圈卡死（2026-10-19，真浏览器双版本实测）

用户真机报「浏览按钮点不开，点了转圈」。用 headless Chrome 对着官方 24.10 容器
（luci-base 26.286，2026 master feed）完整复现：点「浏览…」→ 按钮永久转圈、弹窗空白、
控制台 `InvalidCharacterError: DOMTokenList.add`。三个叠加成因：

1. **`ui.showModal` 签名变了**：从 `(title, children, buttons)` 改成
   `(title, children, ...classes)`——第三参起被 `dlg.classList.add(...classes)` 消化。
   旧三参用法把按钮数组塞进去 → 抛 InvalidCharacterError，`dom.content/append` 都没
   执行到 → 弹窗 DOM 常驻但永远空白（「点不开」的真相）。
2. **`ui.createHandlerFn` 转圈语义变了**：新版**先** `classList.add('spinning')+disabled`
   **再**调函数，靠 `Promise.resolve(fn.apply(...)).finally(...)` 摘转圈；函数**同步抛异常**
   时 `Promise.resolve` 根本执行不到 → `.finally` 永远挂不上 → 转圈永久卡死。
   旧版只有「返回值 instanceof Promise」才转圈，同步异常不留痕——同一个异常两种 LuCI
   表现完全不同。
3. 全插件的 5 个弹窗（安装/更新确认、doctor、卸载、立即更新、浏览）全是旧三参用法，
   **一炸全炸**；用户只是先点了浏览。

**修法（跨版本通吃）**：一律两参调用，按钮栏以 `E('div', { 'class': 'button-row' }, …)`
放进 children——旧版 showModal 给第三参按钮套的正是 `button-row`（样式不变），
新版 LuCI 自家对话框（上传/展示变更）也这么写，`cancelModal` 的 Esc 查找选择器同样认
`.button-row > .btn`。两代 LuCI 的 ui-regression 均 10/10 过。

**连带修掉**（同一次浏览器实测暴露）：listdir/mkdir 根目录双斜杠——`p="${p%/}"` 对
`/` 不起作用，`"$p"/*` 变 `//bin`；前端带着 `//` 逐层下钻，且挂载点徽标比对
（/proc/mounts 是单斜杠）在根目录层**从未生效过**（/dev 的「内存盘」标注一直缺席）。
修法：`p="/"` 时条目 `f="${f#/}"`；mkdir 的目标路径 `tgt="/$nm"` 特判。

**测试盲区与补法**（这次的元教训）：full-e2e 之前只测 `ubus call` CLI 直调——root
旁路了会话与 ACL，静态层只测 main.js HTTP 200，浏览器真实路径（登录→uhttpd→
admin/ubus→ACL→rpcd→前端 JS）**零覆盖**。补两层：

- `work/full-e2e.sh` 新增 **stage ui-http**：curl 表单登录拿 `sysauth_http` 会话 →
  JSON-RPC 打 admin/ubus 调 status/listdir/mkdir，断言根目录无双斜杠、公共会话
  （全 0 sid）必须 `Access denied`（证明 ACL 门真在拦）。
- `work/uitest/ui-regression.mjs`：真 Chrome（puppeteer-core 驱动本机 Chrome）回归
  全部弹窗 + 浏览全流程（进子目录/上一级/新建文件夹/选择此目录/填回输入框）+
  **全程零 pageerror 断言**，登录后的事件才计数（LuCI 登录页自带 uci/get 403 噪音）。
  跑法：容器 `-p 18090:80` 起好 → `node work/uitest/ui-regression.mjs`
  （`BASE=http://127.0.0.1:18091` 切目标，24.10/22.03 双版本各跑一遍）。

**宿主工程坑三条（wsl 原生 docker 环境）**：`wsl.exe` 走 Win32 argv 解析会吞引号
（单引号不保护），带引号/管道/`$var` 的命令一律写成脚本文件再 `wsl bash <file>`；
WSL VM 空闲 ~60s 自动关停，会把容器和 /tmp 一起带走（表现为容器 Exited 255、
容器内 opkg 忽然 command not found），长测试要挂 `wsl -u root -- sleep <N>` 常驻
会话钉住 VM；原生 docker 没有 `host.docker.internal`，e2e 容器要加
`--add-host=host.docker.internal:host-gateway`，假 release 源才可达。

## 18. 安装目录迁移：为什么必须「先复制后切换」（2026-10-19）

「迁移」是把 `<install_dir>` 整树搬到新目录再切 UCI。它能成立的物理前提要先想清楚，
否则容易写成「 mv 一把梭」然后在新机器上炸：

- **垫片路径全相对**（§4 的设计红利在这里兑现）：bin/node 垫片运行时从 `$0` 自算
  `../lib`，LD 路径从不烘焙绝对路径——整树 `cp -a` 到任何路径都照常能跑。
  反例教训就是 §4 的「垫片烘焙绝对路径死于目录改名」：迁移本质上就是一次目录改名，
  任何绝对路径残留（垫片、npmrc、ELF interp 短链 `$HOME/.s` 等）都会在搬家后暴雷。
  现有布局里 interp 短链在 `$HOME/.s`（HOME 不随迁移变）、npmrc 只有 registry 键、
  ELF 补丁长在 node.bin 本体里——全部迁移安全，这是逐项核对过的，不是想当然。
- **`cp -a` 不是 `cp -r`**：垫片是软链链（bin/node → 垫片脚本、libstdc++.so.6 →
  带版本真身），`-r` 解引软链会把结构复制成两份实体文件，链断；`-a`（=-dR -p）保链。
- **暂存目录必须落在目标分区**（`$TARGET/.odw-migrate-stage`）：切换步是同分区
  `mv`（rename，秒级、原子）。把暂存放 /tmp 再 mv 过去，跨文件系统时 mv 会退化成
  「copy+delete」，那前面暂存的意义就没了。暂存名是保留命名空间，上次任务中途暴毙
  的残留下次重跑开头 `rm -rf` 自清（可重跑原则）。
- **校验用 10% 容差而非逐字节**：du 跨文件系统块尺寸有差（overlay 4K vs FAT 簇），
  硬等必假红；拦的目标是「拷了一半」（差 50% 那种），10% 足够。关键件（dsh.version、
  最新 node-v*/bin 的 node+dsh）另做存在性断言。
- **实载自检卡在动 UCI 与删旧之前**：`dsh --version` 在新位置真跑一次（PATH 前插新
  运行时 bin，与 wrapper 同款——bin/dsh 的 shebang 是 `#!/usr/bin/env node`）。
  这一步放最后发现问题就晚了：宁可在「目标已 mv 完、旧目录未删」的窗口里失败，
  回滚目标整体，也不带着病切配置。宁红勿假绿在迁移上的具体化。
- **UCI commit 失败要 `uci revert`**：`uci set` 只进 /tmp/.uci 暂存，commit 才落
  /etc/config；commit 失败不 revert，残存的暂存改动会在下次任何人 commit 这个包时
  意外生效。
- **删旧只删迁移过的顶层条目、根目录 rmdir 不掉就保留**：与 uninstall purge 同款
  语义——install_dir 里可能混着用户自己的数据，rm -rf 整个根目录是越权。
- **守卫面用「带尾斜杠比前缀」判嵌套**：`case "$TARGET/" in "$INSTALL_ROOT"/*)`——
  不带 `/` 的话 `/opt/openwrt-dsh` 会把亲兄弟 `/opt/openwrt-dsh2` 误判成自己儿子。
- **UI 侧**：迁移按钮复用浏览弹窗（openDirPicker 参数化：标题/提示/确认文案/起始层
  可配），选完还要过一道确认框才起任务——数分钟级的搬家动作不能一次点击就开跑。
  迁移成功收尾后前端要把设置里的安装目录输入框同步成新值，否则用户随手「保存设置」
  会把刚迁好的 UCI 改回旧路径（下次安装又装回去）；任务运行期间干脆禁存设置。
- **e2e 覆盖**：full-e2e 新增 stage migrate——守卫面（缺参 64/相对路径 invalid_target/
  同目录/迁往父目录/目标同名冲突）+ 主链往返（CLI 迁走去、rpcd 异步迁回，各断言
  UCI/标记/运行时/旧目录清空/wrapper 可用）。容器里没有第二块分区，跨分区实拷路径
  靠逻辑同构覆盖（cp -a 对跨分区自动实拷，代码路径只有一份）。

**首跑实锤的三个真 bug（2026-10-19，24.10/22.03 双容器各炸一遍才凑齐）**：

1. **自检拿着暂存路径必假红**：校验阶段的 `newbin` 指向 `$STAGE/runtime/...`，mv 切换
   之后暂存已空，自检 `dsh --version` 找不到文件 → 必失败必回滚 → 任务永远红。
   教训：**路径会过期的变量不能跨阶段复用**，切换后必须在 `$TARGET` 下重扫。
2. **`$HOME/.s/ld|g` 短链是全树唯一的绝对路径依赖，删旧即悬**（22.03 实锤，24.10
   不打补丁所以测不出来）：ELF 补丁把 PT_INTERP/DT_NEEDED 改指 `$HOME/.s/ld|g`，
   而 `ln -sfn` 建的是**指向旧安装目录的绝对软链**。自检在删旧前跑，从旧树假绿通过；
   删旧一执行，node 直接起不来（`/usr/bin/dsh --version` 静默为空）。修法：迁移时
   必须把短链重指到新运行时（只在短链已存在时做——没打补丁的机器没有这两个链）；
   且**自检前把旧树整棵 `mv` 改名挪开**，让旧路径物理不在位，自检结果才可信
   （挪开是 rename，可逆；自检不过就连短链一起原样还原）。凡「整树搬家」类功能
   都要逐项核对绝对路径残留——这次核对出了 `$HOME/.s`，下次换布局还得再核对。
3. **e2e 异步任务的等待竞态**：rpcd 拉起 task.sh 到写 `phase=running` 有一个窗口，
   轮询先读到上一个任务留下的 `done` 就提前放行，后面一串断言全在迁移进行中跑掉
   （连带 purge 撞锁吃 rc=2、selfupdate busy——表象像连环事故，根因是测试没等
   任务起步）。修法：起任务前先给 state 文件放哨兵（task=none），等 `phase=running`
   出现后再等终态，终态断言同时校验 task 名。任何「轮询后台任务状态」的测试都
   必须过这道闸，否则比不测更误导。

## 19. 开发期打包自增修订号：为什么是独立脚本而不是塞进 build-ipk.sh（2026-10-19）

打包.bat 每次构建前先跑 `tools/dev-bump.sh`：PKG_RELEASE+1 并同步引擎版本标记。
此前版本号没有任何自动递增环节，r4→r9 全靠手改两处未提交文件，忘了改标记就会出现
「ipk 文件名已经 r10、LuCI 徽标还停在 r9」的劈叉（LuCI/status/selfupdate 优先读
标记文件，ipk 文件名读 Makefile——两处一把改是本脚本存在的意义）。设计上有三条
不是想当然：

- **自增不能住在 build-ipk.sh 里**：release.sh 的第 5 步同样调 build-ipk.sh，
  发布构建的版本必须钉死在 tag 对应的 r1；在构建器里自增会让 tag 内容与产物版本
  分叉。自增是「开发期重新打包」的语义，所以由打包入口（打包.bat）显式调用独立
  脚本，失败即中止构建（半同步的版本号比旧版本号更糟）。
- **号只增不减，失败的构建也不回收**：路由器上 opkg 按「版本更高才升级」判断
  （§14 selfupdate 比版本同源），复用旧号会做出「装了也不生效」的假升级包。
  每次点打包必然消耗一个号，是特性不是浪费。
- **ipk 版本串里的 `r` 是 buildroot 加的**：Makefile 里 `PKG_RELEASE:=9`（纯数字），
  SDK 产物即 `openwrt-dsh_0.1.0-r9_all.ipk`（`-r` 由 package-defaults 拼接，
  HEAD 停在 `:=3` 时代的 r3 产物可证）。标记文件与其同构，dev-check.sh 校验
  三方一致（VERSION = PKG_VERSION = 标记去掉 `-rN`）。

## 20. 「修好了还是点不开」：视图 JS 的浏览器缓存陷阱（2026-10-18 真机实锤，机制性修复）

§17 修复（r9/r10）发到真机（iStoreOS 22.03.7，luci-base git-24.339.46321-5f9267c，
istorenas 主题）后，用户回报「浏览按钮**还是**点不开」。真机逐层排查（远程
shell + 文件读回）后服务端四层全部干净：

1. 磁盘上的 `/www/.../view/openwrt-dsh/main.js` md5 与本地修复版**逐字节一致**；
2. `curl -s http://127.0.0.1/.../main.js | md5sum` —— uhttpd **HTTP 层发的也是修复版**；
3. 设备 ui.js 的 `showModal:function(title,children)` / `createHandlerFn` 与新代码完全
   兼容（iStoreOS 把 UI 库拆成独立 ui.js，和官方容器打包进 luci.js 的形态不同，但
   签名同代）；
4. `ubus call luci.openwrt-dsh listdir` 正常返回目录项。

那用户浏览器里跑的为什么还是旧代码？**URL 从来不变**：

- LuCI 加载视图的缓存穿透符是 `?v=env.resource_version`（luci.js require 实现：
  `url='%s/%s.js%s'.format(env.base_url, name.replace(/\./g,'/'), version?'?v='+version:'')`）
  ——**只跟 luci-base 包版本走**，我们升 openwrt-dsh 它纹丝不动；
- uhttpd 发 `ETag + Last-Modified` 但**不发 `Cache-Control`**，浏览器按 RFC 启发式
  给无缓存头的资源估算新鲜期（约「已老化时长的 10%」——视图 JS 三天没改就是数小时的
  「新鲜」窗口，窗口内连条件请求都不发）。

于是升级后的普通刷新（甚至 F5）拿到的一直是升级前缓存的旧 main.js——代码在服务端
修好了，用户看到的却还是坏的。这不是个别环境问题：**每一个升级了本包的路由器浏览器
都会中招数小时**，且表象完全复刻 §17 的「点不开」。

**机制性修复（Makefile `ODSH_VIEW_NAME`）**：视图文件在打包期改名成带全版本的形式
`main-0_1_0-rN.js`（点必须换下划线——加载器 `name.replace(/\./g,'/')` 会把点当目录
分隔），menu.d 同步 sed 改写 action.path。这样：

- 每次升级视图 URL 必然变化 → 浏览器**必定**重新拉取，普通刷新即生效，不再依赖
  用户记得 Ctrl+F5；
- opkg 升级自动剪掉旧版名文件，postinst 再兜一道 `rm -f .../main.js`（双保险，
  fresh install 上是无害空操作）；
- dev-bump 每次构建递增修订号（§19），同一 rN 不会出现「同名不同内容」的缓存歧义；
- 回滚安装旧版也自洽（旧 ipk 自带自己的文件名与对应 menu.d）。

代价与边界：源码树里文件仍叫 `main.js`、menu.d 源文件仍是 `openwrt-dsh/main`（开发
态所见即所得），改名只发生在 Makefile 打包期；凡硬编码 `main.js` HTTP 路径的测试
（full-e2e ui-http 阶段）都要按 `TREE_VER` 换算新名字。`?v=` 穿透符的短板是 LuCI
上游设计，不动 uhttpd 全局配置（那是用户机器），在我们自己的包内闭环解决。

## 21. 上传包本地安装：cgi-io 的四条铁律与 opkg 本地包的脾气（2026-10-19，双容器实测）

LuCI「上传安装」（检查更新左侧按钮 / 拖 ipk 到按钮上）的浏览器→路由器上传链，四条
实测铁律（源码 openwrt/cgi-io main.c + 双容器实验互证）：

1. **上传走 LuCI 自带 cgi-io，别自造服务端端点**。`POST /cgi-bin/cgi-upload`
   （multipart：`sessionid`/`filename`/`filedata`，可选 `filemode`）——`filename` 就是
   落盘路径，成功应答 `{size, checksum, sha256sum}`。两个 LuCI 版本（22.03.7 与
   24.10 的 26.286）行为一致，且 luci-base 的 write ACL 自带 `cgi-io: ["upload"]`，
   管理会话天然可用。
2. **落盘路径受会话 ACL 按路径管控，`/tmp` 上不去**。cgi-io 在收文件前先
   `session_access(sid, "file", <filename>, "write")`——luci-base 只放行
   `/etc/luci-uploads/*`。传 `/tmp/xxx.ipk` 实测应答
   `{"message":"Access to path denied by ACL","failure":[0,…]}`。所以固定落点只能选
   `/etc/luci-uploads/`（该目录归 luci-base 包所有，带 `.placeholder`，随我们的硬依赖
   必然存在）；前端固定写 `openwrt-dsh-upload.ipk` 一个名字，rpcd 桥/task.sh/
   localinstall.sh 三道白名单闸都按它校验——不收第二个路径，防止这把 root 手电筒
   被拿来装任意文件。
3. **cgi-io 的临时文件是 `open("/tmp", O_TMPFILE)`，overlayfs 上必炸**。容器实验：
   目标路径过 ACL 后报 `Failed to create temporary file`、`failure:[95, "Not
   supported"]`——WSL docker 的 overlayfs 不支持 O_TMPFILE；真机 /tmp 恒为 tmpfs
   （内核 3.11+ 支持），不受影响。**推论：浏览器级上传全链的容器测试必须
   `docker run --tmpfs /tmp`**，否则永远假红；而 full-e2e 只测「包已就位」之后的
   引擎链（cp 放包），不需要 tmpfs。
4. **失败应答是 HTTP 200 + body 里的 `failure` 字段**（response() 恒打
   `Status: 200 OK`）——前端不能靠 HTTP 状态码/reject 路径判失败，必须
   `res.json()` 后看 `reply.failure`。

前端不用 `ui.uploadFile`：那是 24.10 才有的 helper（且自带「选文件」弹窗，与「拖到
按钮上」的交互对不上）。两版通用的写法是 `request.post(L.env.cgi_base + '/cgi-upload',
FormData, {timeout: 0, progress})`——22.03 自己的 ui.js（FileUpload 控件）就是这个
用法；`rpc.getSessionID()` 与 `L.env.cgi_base` 双版本都在。拖放靠原生
dragover/drop：**dragover 不 preventDefault 浏览器就不允许 drop**；用
`dataTransfer.types` 含 `Files` 过滤非文件拖拽，高亮类（odw-dropok）给「可松手」反馈。

opkg 对**本地文件**安装的脾气（容器实测，r11→r3 降级与 r11 同版本重装）：

- 同版本重装：裸 `opkg install <file>` 直接跳过（Package is already installed）——
  必须 `--force-reinstall`，开发期「重装同一个包验证」是本按钮的核心场景之一；
- 降级：裸装报 `Not downgrading package …`——必须 `--force-downgrade`。selfupdate
  的「只升不降」是自动更新的安全护栏（§16-3），上传安装是用户亲自指定文件的显式
  回退，语义不同：照装，但版本对照（尽力从包内 control 读 Version）发现降级时打
  明确警示日志；
- 包完整性预检自己做一道（gzip 魔数 `1f 8b` 比对 + tar 列表含 control.tar.gz）——
  busybox 不一定有 od/xxd，魔数用 `head -c 2` 与 `printf '\037\213'` 比对；上传中断/
  传错文件在进 opkg 前就被可读地拦下；
- 成功后删上传包（不占 /etc 分区），失败保留供重试；包内版本读取是「尽力而为」，
  busybox tar 双写法兼容 `./control.tar.gz` 与 `control.tar.gz`，读不出就跳过对照，
  opkg 装时自会报版本。

task.sh 侧沿用 §14 的 /tmp 副本重入铁律（opkg 原地截断替换正在运行的脚本），副本
清单加 `localinstall.sh`；selfrun 目录名不变（两动作共用，跑完即删的断言也共用）。
UI 侧收尾提示：本页无日志区，装完/失败都由 2s 轮询观测 `task=localinstall` 的
done/failed 主动弹通知（提示刷新页面——视图文件名随版本变，不刷新就一直是旧 JS，
§20 的机制在这里是「装完不刷新」的日常形态）。

## 22. dsh Web 服务：绑定两值论、进程内令牌与 procd 壳的坑（2026-10-19，源码级确认 + 容器验证）

「路由器当 dsh web 主机用」（roadmap P1）落地时的硬约束，全部来自 @deepseek-ai/dsh
源码（0.2.0-rc.2，node_modules 内 dsh-host-webserver / dsh-web-app / dsh-client-connection /
dsh-cmdline），每条都决定了实现形态，动这块前重读：

1. **监听地址是两值论**：`WebServer.Config.host = union(const("127.0.0.1"), const("0.0.0.0"))`
   ——没有「绑某个具体 LAN IP」的中间态。CLI（web-startup.js）又显式拒绝
   `--host 0.0.0.0`（"intentionally not supported yet for safety"），但配置层合法：
   dsh-web-app 自带 cordis.patch.yml 里 webserver 行的 host/port 都是 `!!js` 表达式
   （`ctx.webStartup.host ?? '127.0.0.1'`），补丁层整体替换 config 即可钉值，且绑定
   0.0.0.0 后 dsh 会自动把全部非回环 IPv4 字面量加进浏览器信任栅栏
   （resolveLanTrust），启动行还附带 `(LAN: http://<ip>:<port>/?token=…)`。结论：
   LAN 直连是一等部署形态，只是没开 CLI 旗子——openwrt-dsh 走 `--patch`（官方
   launcher 参数，`dsh web --patch x.yml` 可与 profile 名混用）钉 host，端口仍走
   `--port`（UCI 可配）。
2. **令牌只在进程内存与启动行**。首访鉴权是硬闸：index 请求要么带
   `?token=<launch-token>`（32 字节随机/进程，`randomBytes`，WeakMap 挂在进程对象
   上——不落盘、不进环境变量），拿 303 + 签名 cookie；要么带有效 cookie；否则一律
   401。所以 LuCI「打开」按钮必须拿到启动行：web-run.sh 以 exec 前重定向把
   stdout/stderr 落 `/tmp/openwrt-dsh-web/out.log`（每次启动清零、停止连目录删——
   旧令牌随旧进程失效，残留链接只会误导），rpcd status 运行中才读。
3. **补丁语义是「整体替换目标行的 config」**，不是合并。overlay 里只写 host 一个键
   会把 port/compression 全部抹掉——web-lan.patch.yml 必须把 webserver 行全部键按
   dsh 自带值原样重述（port 表达式 `!!js ctx.webStartup.port ?? 3080` 也照抄，保住
   `--port` 旗子的覆盖通道）。dsh 未来增改这些键的默认值时这里要跟着同步，症状是
   端口/压缩行为回退出厂值。
4. **procd 壳的两个静默坑**：(a) OpenWrt init 脚本首行必须是
   `#!/bin/sh /etc/rc.common`——写成普通 `#!/bin/sh` 的话 `/etc/init.d/x start` 把
   整个文件当普通脚本跑一遍、什么都不做（静默无效）；(b) procd 实例环境没有登录壳
   的 `HOME`，dsh 的 DSH_HOME 解析依赖它——`procd_set_param env HOME=/root` 显式给
   （与 porting-notes 引擎侧 HOME 坑同源：后台壳里的 HOME 不能赌）。
5. **浏览器信任栅栏只认回环 + IP 字面量**。域名 Host（哪怕 openwrt.lan）一律拒
   （DNS rebinding 防线），表现为页面能加载但 /api 全 401——所以 LuCI「打开」优先用
   「浏览器当前 IP + 端口 + 令牌」拼链接，其次后端 LAN 链接，绝不给回环链接（在用户
   PC 上指向用户自己的机器）。
6. **web-run.sh 必须用 exec 重定向而非管道**：`exec dsh … >>log 2>&1` 让 fd 随 exec
   传给 node 本体，procd 跟踪的 pid 就是 dsh；`dsh | tee log` 形态会让 procd 跟踪
   sh、kill 时 node 成孤儿。`--no-open` 必带：headless 路由器上 open 包必然失败报错
   还污染日志。
7. **防火墙口径**：LAN only 靠 OpenWrt 默认防火墙（WAN 入站全拒）+ 绑定即得，本包
   不加防火墙规则；令牌 + 默认关 + 默认防火墙三道闸兜住暴露面。安全模型上要清醒：
   打开这个服务 = 局域网内拿到令牌链接的人能通过 AI 在路由器上执行操作（这正是产品
   用途），所以默认关、LuCI 文案显式警示、不做任何「方便传播链接」的复制入口。

e2e 覆盖（full-e2e.sh stage web，24.10/22.03 各跑）：enabled=0 门禁（显式 start 不拉
起）→ **web 段缺失自愈（§24，删段复现）** → web_set 启用 → 启动行落盘 → `netstat`
断言监听 0.0.0.0:3080 → status web_running/web_url（LAN 链接）→ 真实 HTTP 链
401→303→200 → 停用后实例消失/状态目录清/rc.d 链接摘 → **端口被占全链（§24：手起
dsh web 占 3080 → web_error 透出 → 解除后可恢复）** → purge 后 web_set 拒启
（not_installed）。

## 23. 任务「执行过程」子窗口：把后台任务的可视性还给用户（2026-10-19）

需求原话「安装 dsh 点了之后应当是打开一个子窗口终端显示执行过程」。此前起任务只给
一条「进度见状态表」通知，用户对着一行字等几分钟——日志明细明明就在 /tmp 的
task.log 里，rpcd `log` 方法（64KB 日志尾）也从早期版本就在、ACL 一直放行，只是
视图层曾刻意删掉调用（「页面不展示任务日志」的旧决策）。本次把数据面接回 UI，
**后端零改动**，全部工作在前端视图：

1. **形态选模态弹窗而非 window.open**：LuCI 会话/rpc 同源直接复用、不被弹窗拦截器
   拦、ui-regression（puppeteer）驱动得到；新开浏览器窗口要自己解决鉴权与 LuCI
   样式，零收益。终端样态（黑底等宽 320px）只是观感，实现仍是 §17 的两参
   showModal + children 内 button-row。
2. **tail -f 形态：1s 一拍整窗替换 + 贴底滚动**（用户上翻就不拖，回底继续贴）。
   不做增量 append：日志尾是滑动窗口（`tail -c 65536`），增量拼接要对齐裁剪偏移，
   复杂度全在错排上；320px 窗口整窗替换毫无性能压力。`\r` 进度行后端 json_escape
   已展开成行、ESC 已删，textContent 直填无注入面。
3. **终局判定的「新鲜闸」**：开窗瞬间页面 2s 轮询可能还揣着上一个任务的
   done/failed 旧快照，直接判终局会「开窗即报上次任务完成」。只认 seenRunning
   （本窗口亲眼见过 running）或 task_ts 晚于开窗时刻（状态是开窗后才落盘的）。
   终局与最后一次日志可能错拍（log/status 并发请求），判终局时补拉一次日志尾。
4. **interval 不泄漏**：窗口被任何途径关掉（收起按钮/Esc/被新弹窗顶掉）由
   `document.body.contains(pane)` 在下一拍探测到并自停；终局自停；双保险。
5. **双轮询无害**：status.sh 是纯文件读快路径（铁律 4），窗口存活期的 1s status +
   页面 2s status 合计每秒约 1.5 次文件读，路由器无压力；不碰 node。
6. **重开入口**：任务进行中状态区出「查看执行过程」按钮（applyStatus 控制显隐，
   任务名→标题映射含 localinstall），覆盖「关掉过窗口」与「任务起跑后才刷新页面」
   两种场景；任务结束即隐。
7. **回归台的连带坑**：doctor 是执行过程链路的天然触发器（不下载、未装容器秒级
   明确失败退出），ui-regression §7 用它做全链断言；UPLOAD_IPK 真链路里「执行
   过程窗口顶掉上传进度弹窗」本身就是任务已启动的信号——老的「等弹窗关闭」断言
   会被新窗口卡死。教训：**每加一种任务反馈形态，都要回头查旧断言的隐含前提**。
   真链路首跑还实锤两个测试台自己的坑：(a) 产品文件名白名单
   `^openwrt-dsh_*.ipk$` 在 handleUploadPicked 第一步就拦，喂给选框的测试包必须
   先暂存成合规文件名，否则真包永远被拒、而残留的假包确认框反被点中；
   (b) 新版 LuCI hideModal 只摘遮罩不清 `.modal` DOM——残留弹窗的按钮**仍可点**
   （闭包还攥着当时的 File），按文本全局找按钮会点到幽灵按钮把 4 字节假包传上去。
   正解：点弹窗内按钮一律限定 `body.modal-overlay-active` 下的当前 `.modal`，并先
   对弹窗文本做版本断言。

## 24. 「点启用没反应也没报错」三连：conffile 丢段、假 ok、崩溃原因黑洞（2026-10-20 真机实锤）

真机（iStoreOS 路由器，插件 0.1.0-r18）点 LuCI「启用 Web 服务」全程无效果也无报错。
三个环环相扣的坑，单独看每个都「理所当然」，合起来就是静默失败：

1. **conffile 丢段是常态，不是异常**。`/etc/config/openwrt-dsh` 是 conffile，opkg
   升级时用户改过/旧版没有的段落**永远不会自动补**——web 段是 2026-10-19 才加进
   conffile 的，所有从早期版本升上来的机器都没有它。而 uci 的三段式 set
   （`uci set openwrt-dsh.web.enabled='1'`）对**不存在的具名段直接报
   `Invalid argument`，不会自动建段**；具名段只能用两段式
   `uci set openwrt-dsh.web='web'` 创建（`uci get openwrt-dsh.web` 对存在的具名段
   返回其类型名，正好当存在性探测用）。所以凡是用三段式写 web.* 的代码，都必须
   先自愈建段——`web_set` 两个方向都要（停用路径同样，幂等无害）。fresh 容器永远
   带全段，这正是 e2e 此前测不出它的原因；**测 conffile 升级陷阱必须先 delete 段**。
2. **rpcd 后端失败必须回 error，绝不能吞了还回 ok**。此前 web_set 的 `uci set`
   失败（stderr 进 rpcd 日志，前端永远看不见）后继续走完 enable+start 并回
   `{"status":"ok"}`——init 脚本门禁（enabled≠1 不启动）把它原样弹回去，日志里一句
   「未启用」，UI 上「启用中」。铁律落成形态：**写 UCI 的同步调用，写失败必须让
   前端拿到非 ok 的 status**（本包 web_set 现有 ok/not_installed/no_init/error/
   invalid 五态）；前端对非 ok 一律弹窗（ui.showModal），通知条在用户「等一个结果」
   的场景里太轻。
3. **崩溃原因必须自己找出口，且健康判据不能信 procd 注册表**。就算 UCI 写成功了，
   端口被占（真机上 127.0.0.1:3080 被用户手起的 dsh web 实例占着；内核实测通配
   绑定撞回环 LISTEN 必 EADDRINUSE，SO_REUSEADDR 对 LISTEN 态无豁免）会让 dsh
   秒崩、procd respawn 5 次后放弃。两个实锤：(a) 崩溃输出只在 out.log/logread，
   syslog 里 procd 一声不吭；(b) **procd 放弃 respawn 后 instance 永久留在
   service list（`running:false`，用 /bin/false 崩溃服务实测 80s 不注销）**——运行
   判据若只看注册表，崩溃循环期「web_running」恒为 1，UI 永远「运行中（正在生成
   访问链接…）」，第一版 web_error（要求 running≠1）就是这么在 e2e 里 75s 等空的。
   还有一层：dsh 会把绑定失败包成 `dsh: startup failed: 2 required plugins did not
   activate`——节点原生 EADDRINUSE 栈未必透出，弹窗/断言都按这个包装形态预期。
   正解：健康判据改看 web-run.sh 的 out.log（每次拉起清零，天然新鲜）——**有本进程
   启动行（`dsh web:`）= 健康；非空且无启动行 = 起来就崩**，取首个错误行（无错误
   样式行取尾部，令牌 `token=` 脱敏、截 500 字节）作为 `web_error` 回传，UI 状态行
   标红直显 + 启用后 1s 一拍的守望弹窗拍给用户。**截断必须在转义之前**（先 head -c
   原始字节再 json_escape，反过来会把 `\"` `\n` 转义序列拦腰切断造出非法 JSON）。
   UI 显示优先级必须是「错误 > 运行中」：崩溃循环期 web_running=1 会把错误盖成
   「正在生成访问链接」。有了原因还得有出路：Web 区补「监听端口」输入框（前端
   uci 通道，web 段缺失时 `uci.add` 具名段同款陷阱），改完 save+apply 由 procd
   config trigger 自动重启。

验证：full-e2e.sh stage web 增两段（删段复现→自愈启用；手起 dsh web 占 3080→
web_error 透出→解除后恢复；占端口不能用 nc——busybox applet 在 rootfs 里不可赌，
首跑实锤没占住），ui-regression 补端口控件在位断言。真机复验：老配置路由器上点
「启用」必须要么跑起来、要么把原因拍用户脸上，不允许第三种沉默状态。

## 25. 端口冲突第二课：真因被概括行吞掉、3080 不能赌空闲（2026-10-20 真机实锤 II）

真机（iStoreOS 路由器，插件 0.1.0-r21）点启用后，状态行红字只有「dsh: startup
failed: 2 required plugins did not activate」——§24 的 web_error 机制工作了，但
透出的是天书。out.log 里真凶就在概括行下方几行：`Error: listen EADDRINUSE:
address already in use 0.0.0.0:3080`。三个新知：

1. **dsh 崩溃输出的结构是「概括行在前、逐插件原因在后」，提取必须按特异性分层**。
   dsh-app-boot 的启动审计先打一行计数概括，再逐条列每个插件的原生错误
   （`dsh web` 场景下会整段落进 stdout/stderr，web-run.sh 已接住）。「2 required
   plugins」里只有一个是真凶（webserver 绑定失败），必需的 connection 等
   webRuntime→webServer 链条是连锁 pending——看着吓人，根因只有一个。§24 曾按
   最坏假设写「节点原生 EADDRINUSE 栈未必透出」，真机证明它透出；真正吞掉它的是
   自己的 grep：`grep -i -m1 -E 'error|failed|…'` 永远先命中概括行（它含 failed），
   `-m1` 一停，后面的真因永远轮不到。修法：EADDRINUSE → EACCES → 原始错误行三层
   递减，前两层给中文人话+自救指引（顺手取行内最后一个 `:数字` 抠出端口号写进
   文案），e2e 用负向断言钉死「概括行不得原样透出」。
2. **「N required plugins did not activate」大概率是端口冲突的包装皮**：别按字面
   去查 N 个插件，先看 out.log 里 webserver 的原生错误行。
3. **3080 不能赌空闲——这是结构性的，不是巧**。dsh web 的缺省端口 3080 与生态
   撞车：dsh 宿主自己的 web 控制台也用 3080（本机 GUI 即
   127.0.0.1:3080），NAS 全家桶
   （docker 容器等）也爱占 30xx。谁先起谁占，openwrt-dsh web 不该赌赢它。所以
   web_set 受理前 netstat 预检：被占直接回新六态 `port_busy`（附 port+detail 占用
   行当线索，e2e 断言「拒启不写 enabled、不拉实例」），把「秒崩→respawn 5 次→
   放弃」盲区整个消灭在受理之前；崩溃透明路径（§24）改由「enabled=1 直启 init」
   （等价于启用后端口才被占/重启重绑）继续覆盖。预检的跳过条件必须是 procd 实例
   `running=true` 而非「实例存在」——§24 实锤崩溃放弃后实例永久驻留注册表，按
   存在性跳过会让重试永远绕过预检。同日拍板并落地**自动选端口**（用户口径「不要
   固定」）：UCI `port` 缺省/留空/非法/**旧固定 3080** 一律并入自动——web-run.sh
   每次启动在 **3081-3099** 现选第一个空闲口。四个为什么：(a) 段从 3081 起而非
   3080——dsh 生态自己吃 3080，本服务开机序（S99openwrt-dsh-web）又排在
   宿主控制台进程之前，自动抢下 3080 会反过来饿死宿主控制台；(b) 段压在 32768
   以下——39080 之类落在内核临时端口区（32768-60999），会被出站连接源端口/
   docker -P 随机占用；(c) 每次启动现选、不选好写回 UCI——start_service 里写
   UCI 会再触发 openwrt-dsh 的 config trigger 重启本服务，往复空转；且访问链接
   以 out.log 启动行为唯一真源（status 的 web_port 只报配置语义、自动时为空，
   前端从 web_url 解析实际口拼「打开」链接）；(d) 「探测→绑定」竞窗输了由
   procd respawn 重跑重挑，自愈。显式指定 1-65535 仍固定使用（被占走 port_busy
   拒启）。老 conffile 保留的 `port '3080'` 由「3080 并入自动」规则就地升级，
   用户无需动手；真机占用者身份以 `netstat -tlnp` 为准。

## 26. LAN 设置解锁：设置页的回环门、单点补丁与「不去 token」的决策（2026-10-21，源码级定位）

真机用户报：LAN IP 打开 dsh Web 界面，「设置→模型」整页报「加载提供商目录失败:
settings are unavailable in this browser」。逐层读 dsh 源码定位到机制，做成
UCI `web.remote_settings`（默认关）授权的单点补丁（`web-patch.sh`）。全部知识：

1. **门只有一道，且全在客户端**。判定真源只有一行——`dsh-client-connection/
   lib/client.js` 的 `installConnection`：`isLoopback: transport?.ownsHost === true
   || pageLocation === void 0 || isLoopbackHostname(pageLocation.hostname)`，其中
   `isLoopbackHostname` 只认 `localhost`/`[::1]`/`127.x`，**看的是浏览器地址栏**。
   消费方全部转发它：`$host.isLoopback`（dsh-api-gateway）→ 设置镜像的
   `persistence = isLoopback ? "host" : "memory"`（dsh-client-ui-settings）——非回环
   时镜像以终态 `unavailable` 起步、**从不发请求**，模型页遂报「提供商目录加载
   失败」。服务端 `dsh-api-settings-controller` 没有第二道闸（上游 README 自认
   「form writes are inert even though Connection authentication covers the API」
   ——纯客户端自我设限）。所以客户端单点恒真补丁即可全解锁，主题/通用/外观一并
   恢复持久化。残留边界：DeepSeek **账号**登录上游仍只承诺回环/SSH 转发，与本门
   无关；第三方 API-Key 提供商（设置→模型）不受影响。
2. **补丁形态**：dsh 的浏览器代码是**未压缩的 `lib/*.js` 直接伺服**（用户看到的
   错误文案能在包内逐字 grep 到就是铁证），锚点稳定 → `web-patch.sh` 用 awk
   index/substr 做纯字面量替换（锚点含 `?`/`|`/`[`，过 sed 正则必炸），幂等标记
   `/* odw-web-lan */`，首涂落 `.odw-orig` 备份，锚点不在整体不动。`state` 动词
   只试最新运行时的两个既定 npm 布局落点（纯 `[ -f ]`+`grep -F`）供 status 2s
   轮询；`apply`/`revert` 才全树 find（多运行时并存时「都涂」，web 服务挑哪套都
   对）。npm 重装整包替换文件会冲掉补丁 → install/update/doctor 每次按 UCI 重涂。
   字节级陷阱：**client.js 末尾没有换行符**（实测末字节是代码字符），awk 的
   `print` 会对末条记录补 `\n` 多出 1 字节——wp_replace 对末条记录必须 printf
   原样输出（CRLF 的 \r 属记录本体不受影响）；逆向还原以 cmp 字节级一致为验收。
3. **rpcd `web_remote_set` 的顺序是「先补丁后 commit」**：openwrt-dsh 的 config
   trigger 在 commit 后自动重启 Web 服务，重启拉起的一定是已涂/已撤的文件；反序
   则可能重启完才涂上，已打开的页面仍旧代码。失败不落开关（UCI 保持原值）——
   「开着但补丁没涂上」的半态只该出现在升级冲刷窗口期（install/doctor 自动重涂），
   不该由开关制造。
4. **Token 的知识（用户拍板「不去 token」，只记录机制）**：`?token=` 是进程级
   launch token，只用来**换**一枚签名 cookie（HttpOnly、SameSite=Strict，默认
   `cookieMaxAgeDays=30`，签名密钥持久在 dsh 凭据库、重启不失效）——所以令牌
   本就「每浏览器一次」，之后裸地址直接进。真正的坑是 **cookie 绑定 `IP:端口`
   权威**：§25 的自动端口每次启动现选，端口一换 cookie 全作废，「老要令牌」的
   体感源于此；要长期免登就把 UCI `port` 钉死（路由器 IP 也固定）。彻底去
   token 在服务端（`dsh-client-connection/lib/index.js` 的 `authorizeIndex`/
   `requestRejection`）也可补，但 dsh web 的 operator 对话=路由器 shell，上游
   拒绝 CLI `--host 0.0.0.0` 的原话即「it would expose remote code execution to
   the network」——我们已经用 config overlay 开过一次 0.0.0.0，再去 token 就是
   LAN 内免鉴权 RCE，明确不做。
5. **UI 纪律**：开启必须过确认框（后果=放行含 API 密钥的设置读写；令牌会更换）；
   状态行三态文案（未开启/已开启+补丁实况/锚点失效指引 doctor）；按钮三态
   （开启/关闭/重涂）。补丁相关字段（`web_remote`/`web_remote_state`）只在开关
   开启时才计算，快路径纪律同全 status。

**2026-10-21 补记（用户拍板：开关撤销，补丁默认涂抹）**：上面第 3/5 条里的开关
设计当日即废——「局域网设置解锁」按钮/安全确认框/状态行、rpcd `web_remote_set`、
UCI `web.remote_settings`（含 lib.sh 的 `odw_web_remote`）全部删除，install/
update/doctor 改为**无条件**重涂补丁；status 只留 `web_remote_state`（改无条件
计算，`state` 本就是 `[ -f ]`+`grep -F` 毫秒级，不违快路径纪律）。为什么：(a)
路由器当 dsh Web 主机的核心场景就是「局域网设备浏览器打开用」，设置页在 LAN
打不开等于功能自废，授权门槛挡住的恰是主路径；(b) 暴露面没有变大——设置页本就
受 Connection 认证保护（第 1 条：服务端无第二道闸，客户端那道是自我设限），
安全边界仍由「服务默认关 + 令牌 + 默认防火墙」三道闸承担（同日已删端口输入框，
同一口径：UI 收敛、引擎自动兜底）；(c) conffile 里残留的 `remote_settings '0'`
一律忽略，不做迁移——老配置用户升级后即得默认解锁，正是拍板要的行为。
`web-patch.sh revert` 保留为手工维护工具（SSH 下可手动撤补丁回上游行为）。
ui-regression 补负向断言钉死「开关不得复活」。

**2026-10-21 补记 II（真机仍报错 → 伺服链解剖，「涂了不生效」的完整闭环）**：
撤销开关后真机依旧弹「settings are unavailable in this browser」。逐层解剖
`dsh-client-modules` 找到根因——**补丁涂了，但到不了浏览器**：

1. **client 代码的伺服链**：浏览器 GUI 的 client 插件不在 Vite dist 里（dist 只有
   壳 + langs），由 `dsh-client-modules` 的 Host 半边把每个包的 `lib/client.js`
   组合成 **`/plugins/??...&rev=<rev>` combo 路由**伺服；chunk 走
   `/plugins/<包>/client.<name>.js?rev=<rev>`。frontend-static 只伺服 dist 根
   （越界 403），与它无关。
2. **rev 由文件 mtimeMs/ctimeMs/size 派生，且只在 Host 启动扫描 / HMR rebuilt()
   时计算**——外部改文件不触发重扫；**/plugins 响应带
   `cache-control: public, max-age=31536000, immutable`**（rev 即缓存键，注释原话
   「mismatched revisions are rejected instead of serving newer bytes」）。推论：
   **涂完补丁必须重启 dsh web 服务**——重启才重扫 → rev 变 → boot 清单换新 URL
   → 浏览器（哪怕有一年 immutable 缓存）拉到的是新 URL = 补后代码。不重启则
   清单还是旧 rev 旧包体，怎么刷新页面都没用。我们 `cat tmp > file` 的原地覆写
   顺带更新了 mtime，正好喂给 rev 机制（若保 mtime 反而永远不生效）。
3. **两条触发路各缺一半**（真机正是踩在这里）：插件包升级走 opkg postinst——
   只重启了 Web 服务没人涂补丁；「更新 dsh / 校验修复」走 install-dsh.sh——
   只涂了补丁没人重启服务。修复：postinst 在重启**前**加 `web-patch.sh apply`
   （dsh 不在时 no-dsh 无害）；install-dsh.sh 在涂成功后查 ubus 服务表，
   running=true 且 init 脚本在就自动 `restart`（令牌随重启更换，状态行刷新新链接）。
   SSH 即时救援（不等新包）：`sh /usr/lib/openwrt-dsh/web-patch.sh apply &&
   /etc/init.d/openwrt-dsh-web restart`。

## 27. 真发布把 dist/ 历史包全传上了 Release：发布清单必须精确点名（2026-10-21 实测）

用户报：发布流程跑完，GitHub Release 上冒出二十来个 ipk，而本次版本只有一个。
机制与修复：

1. **dist/ 天然是历史包堆积地**：开发期每次「打包.bat」→ dev-bump.sh 把
   PKG_RELEASE +1 → build-ipk.sh 产出一个新 ipk 落 dist/，旧的从不清理（号只增
   不减、失败也不回收，见 §19——所以 r1…r26 中间还有跳号）。到发布时 dist/ 已
   堆了 23 个 0.1.0-r* 包。
2. **旧版 release.sh 的 gh 路径按 `dist/*.ipk` 全量 glob 组附件列表**，sha256sums
   .txt 也是全量算法——`gh release create` 遂把 23 个历史包连同校验和一起传上
   Release。AGENTS.md 里「dist/ 全程零污染」的旧警告正是冲着这个行为写的（当时
   只是给 e2e 的纪律），发布脚本自己没有防呆。
3. **修复**：发布物只认精确文件名 `openwrt-dsh_${VER}-r1_all.ipk`，附件 =
   它 + sha256sums.txt 两个。为什么文件名可精确预测：发布构建在第 3 步被钉死
   PKG_RELEASE=1（§19：自增只属于开发期），而 ipk 版本串里的 `-rN` 由 buildroot
   按 PKG_RELEASE 拼（AGENTS.md 版本管理约定），故恒为 `openwrt-dsh_<VER>-r1
   _all.ipk`。sha256sums 同步只覆盖这一个文件；非 dry-run 下发布物不存在就报错
   退出——宁挂不静默（防产物命名变更后拿旧包/空列表发布）。dry-run 不做存在性
   断言（dry-run 本就不构建，只打印将挂的附件）。
4. **教训**：「开发期产物目录」和「发布物清单」必须是两个集合。凡把目录 glob
   直接当发布清单的脚本，目录里堆了什么就发布什么；发布类脚本要点名具体文件并
   做存在性断言才算防呆。兜底（无 gh）路径的提示文案同步只列这两个附件，防止
   人工拖拽时把 dist/ 一股脑拖上去。

## 28. 发布说明曝光了一整行压扁的 commit 命令：多行 message 用 -F，发布前预检 subject（2026-10-21 实测）

v0.1.0 发布当天，Release 页「变更」第一条是一条十几行的「命令」——从
`git add` 一直到 `EOF )"` 原样公开（截图级社死）。链条与修复：

1. **根因在 message 的创建方式，不在 release.sh**：给 §27 修复提交写 message
   时用了 `git commit -m "$(cat <<'EOF' …)"` 形态，经单行 shell 层传输
   （PowerShell `-Command`/编码管道）后换行全部丢失，heredoc 不再生效，整段
   命令文本——连 `git add` 前缀带进去——原样成了 subject。
2. **发布说明是 subject 的放大器**：release.sh 按 `git log --format='- %s'`
   把 subject 原样搬进 RELEASE-NOTES，`gh release create --notes-file` 直上
   公开页。垃圾进什么就放大什么，中间没有任何人眼检查。
3. **修复（三道）**：
   - 该提交 amend 重写 message，连同 tag v0.1.0 一起 force-push（发布刚一小时
     无消费者，Source code 归档随新 tag 重生成、哈希变化可接受；ipk/sha256sums
     附件不受影响——修复只动 docs/tools，不进包）；
   - release.sh 第 6 步发布前**预检变更区间 subject**：出现 `$(`、`<<'EOF'`、
     `git commit -m` 等命令残渣即报错退出，宁挂不静默（与 §27 的存在性断言同
     哲学），同时打印变更预览供人眼过一遍；
   - AGENTS.md 写回纪律：**多行 commit message 一律先写文件再
     `git commit -F <file>`**，禁止在命令替换里嵌 heredoc——它活不过任何
     单行 shell 层。
4. **教训**：凡面向公开页的内容（Release 说明、changelog）由仓库元数据自动
   生成，「自动生成」不是免检通道——生成前必须预览一遍原料；而原料的质量
   靠创建时就用不会压扁的方式（-F 文件）来保证，事后补救要动历史。




