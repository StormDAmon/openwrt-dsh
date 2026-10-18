# 架构

## 总览

```
┌────────────────────────────────────────────────────────────┐
│ LuCI 页面 (luci-app-openwrt-dsh)                            │
│   view: htdocs/.../view/openwrt-dsh/main-N.js（源码 main.js，  │
│   打包期带版本改名，见 porting-notes §20 浏览器缓存陷阱）      │
│   轮询 2s → status/log；按钮 → install/update/doctor/       │
│   uninstall/migrate/check_update/check_dsh/selfupdate/      │
│   localinstall/web_set；「更新 dsh」先走                     │
│   check_dsh 前置检查，确认有新版才弹确认框；「上传安装」=      │
│   cgi-io 上传 ipk + 后台任务；「Web 界面」区启停 dsh web 服务  │
│   + 「打开」直达令牌链接（LAN 设置解锁补丁默认涂抹，无开关）    │
└──────────────┬─────────────────────────────────────────────┘
               │ ubus: luci.openwrt-dsh（ACL 见 acl.d/*.json）
┌──────────────▼─────────────────────────────────────────────┐
│ rpcd 后端 /usr/libexec/rpcd/luci.openwrt-dsh（POSIX sh）     │
│   status → status.sh（快路径，读标记文件，不拉 node）+        │
│     web_*（UCI/ubus 服务表/令牌链接文件，全本地读）           │
│   install/update/doctor/uninstall/migrate/selfupdate/       │
│     localinstall → 后台拉起 task.sh（stdout 脱离管道）       │
│   check_update → 同步查 GitHub（单跳限 12s，两跳共 24s）      │
│   check_dsh → 同步查 npm 源 dsh 最新版（单跳限 12s）          │
│   web_set → 同步写 UCI + 托管 init 脚本 enable/start 等      │
│   （web_remote_set 已删，§26 补记：补丁默认涂抹、无开关）     │
└──────────────┬─────────────────────────────────────────────┘
┌──────────────▼─────────────────────────────────────────────┐
│ procd 服务 openwrt-dsh-web（默认关，UCI enabled 门 + 已装门） │
│   web-run.sh → exec dsh web --patch web-lan.patch.yml       │
│   --no-open --port N，stdout 落 /tmp/openwrt-dsh-web/out.log │
└──────────────┬─────────────────────────────────────────────┘
┌──────────────▼─────────────────────────────────────────────┐
│ 引擎 /usr/lib/openwrt-dsh/（POSIX sh，busybox ash 兼容）     │
│   task.sh      锁(mkdir) + 状态落盘 + 日志重定向             │
│   install-dsh.sh  主链路（前置检查→运行时→补丁→npm→校验）     │
│                  action=install|update|doctor                │
│   uninstall-dsh.sh 卸载（npm 修剪+直接清理兜底+标记清除；     │
│                  keep=留运行时 / purge=连运行时删）           │
│   migrate-dsh.sh 安装目录迁移（暂存整拷→校验→UCI 切换→删旧；  │
│                  失败旧目录分毫不动，见「安装目录迁移」节）    │
│   selfupdate.sh 软件包自更新（GitHub Releases 查新版→        │
│                  下载 ipk→sha256→opkg 安装）                 │
│   localinstall.sh 上传包本地安装（预检→版本对照→              │
│                  opkg --force-reinstall --force-downgrade）  │
│   runtime.sh   运行库三件套/三级垫片/ELF 补丁编排/LTS 升级链  │
│   elf-patch.js PT_INTERP/DT_NEEDED 双补丁器（由托管 node 执行）│
│   web-patch.sh LAN 设置解锁补丁（dsh web 客户端回环门单点放行， │
│                  awk 字面量替换幂等涂改；默认涂抹，§26 补记）│
│   lib.sh       镜像表/下载器(带进度)/配置读取/状态与日志/     │
│                GitHub 自更新辅助(见下「软件包自更新」节)      │
└────────────────────────────────────────────────────────────┘
```

## ipk 的文件清单(单包:引擎 + LuCI 页面,2026-10-15 起合并)

**openwrt-dsh**（`PKGARCH:=all`，依赖 `+curl +ca-bundle +ca-certificates +luci-base`，
rules.mk 构建，不走 luci.mk——单包后无需 feed 专用机制）

```
/usr/lib/openwrt-dsh/{lib,runtime,install-dsh,uninstall-dsh,migrate-dsh,selfupdate,localinstall,web-run,web-patch,task,status}.sh
/usr/lib/openwrt-dsh/elf-patch.js
/usr/lib/openwrt-dsh/version               # 插件包版本标记（LuCI 徽标/CLI/自更新比版本的第一真源，
                                           #  release.sh 与 VERSION/Makefile 同步）
/usr/libexec/rpcd/luci.openwrt-dsh        # rpcd 插件（需可执行位）
/usr/bin/openwrt-dsh                      # SSH CLI
/usr/bin/dsh                              # 托管入口 wrapper（动态解析运行时+补 PATH；
                                          #  npm 产物 shebang 是 env node，软链必死）
/usr/share/openwrt-dsh/node-pty/linux-x64/pty.node   # musl 自编译原生件
/usr/share/openwrt-dsh/web-lan.patch.yml  # dsh web 的 LAN 绑定 overlay（--patch 官方通道钉
                                          #  host=0.0.0.0；CLI 拒绝该值但配置层合法，见
                                          #  「Web 界面（dsh web 服务）」节与文件头注释）
/etc/init.d/openwrt-dsh-web               # dsh Web 服务 procd init（首行 rc.common；默认不自启）
/etc/config/openwrt-dsh                   # UCI（conffile）
/etc/profile.d/openwrt-dsh.sh             # 登录 shell PATH 集成（动态解析，幂等）
/www/luci-static/resources/view/openwrt-dsh/main-<版本>.js  # LuCI 视图（源码 main.js，
                                                           #  打包期改名 main-0_1_0-rN.js：
                                                           #  每次升级 URL 必变，穿透浏览器
                                                           #  对视图 JS 的启发式缓存，
                                                           #  见 porting-notes §20）
/usr/share/luci/menu.d/openwrt-dsh.json   # 菜单注册（服务 → DeepSeek Harness；打包期
                                           #  sed 改写 action.path 与视图文件名对应）
/usr/share/rpcd/acl.d/openwrt-dsh.json    # rpcd ACL（ubus luci.openwrt-dsh 读写）
```

## 运行期布局（安装根目录，默认 /opt/openwrt-dsh，UCI 可改）

```
<install_dir>/
├── runtime/
│   ├── node-v22.x/            # 一个或多个托管 Node 运行时
│   │   ├── bin/node           # 垫片（三级之一，见 porting-notes §4；路径全相对，改名免疫）
│   │   ├── bin/node.bin       # musl 真身（可能已被 ELF 补丁）
│   │   ├── bin/dsh            # npm -g 的 dsh 入口
│   │   ├── etc/npmrc          # 运行时级 npm 配置（allow-scripts 列表 + registry；
│   │   │                      #  官方 npm i -g 路径的尽力等价，见 porting-notes §7/§12）
│   │   ├── lib/               # 自带 Alpine 三件套 + lstd/ + musl/
│   │   └── libexec/node       # 真身硬链（npm 专用，垫片 execPath 坑）
│   └── node.version           # 版本标记（状态快路径）
└── dsh.version                # dsh 版本标记
```

任务运行态（tmpfs，重启即清，有意为之）：

```
/tmp/openwrt-dsh/
├── state          # phase=running|done|failed / rc / task / ts
├── task.log       # 当前或上次任务日志
├── lock/          # mkdir 原子锁；残留且 phase≠running 判为残锁可抢
├── update-check   # 「检查更新」结果缓存（status/installed/latest/available/error/ts）
├── dsh-check      # 「更新 dsh」前置检查缓存（同上字段；npm 源查 @deepseek-ai/dsh 最新版）
├── pkg.version    # opkg 包版本缓存（仅版本标记缺失时使用；按 /usr/lib/opkg/status 的 mtime 失效）
├── localinstall-work/  # 上传包本地安装的临时目录（读包内 control 用，跑完即删）
└── selfrun/       # selfupdate / localinstall 任务的引擎脚本副本（跑完即删，见 porting-notes §14）

/tmp/openwrt-dsh-web/
└── out.log        # dsh web 服务进程的 stdout/stderr（web-run.sh 重定向；启动行含带令牌
                    #  访问链接，rpcd status 从中取。每次启动清零，服务停止连目录一起删）
```

## rpcd 接口（ubus object `luci.openwrt-dsh`）

| 方法 | 入参 | 出参 | 说明 |
|---|---|---|---|
| `status` | — | `{arch,libc,distro,supported,install_dir,free,registry,min_node,node_version,node_dir,dsh_version,task_phase,task_rc,task_name,task_ts,pkg_version,gh_check_status,gh_latest,gh_available,gh_check_ts,dsh_check_status,dsh_latest,dsh_available,dsh_check_ts,web_enabled,web_port,web_running,web_url,web_error,web_remote_state,log}` | log 为尾部 8KB；pkg_version 读包自带版本标记（缺失退 opkg 库缓存）、gh_*/dsh_* 只读各自检查缓存——绝不联网；web_* 全本地读（UCI + ubus 服务表 + 令牌链接文件）；`web_remote_state` 无条件计算（web-patch.sh state，纯 `[ -f ]`+`grep -F`，快路径纪律同上；曾有的 `web_remote` 开关字段已删，§26 补记） |
| `log` | — | `{log}` | 尾部 64KB；LuCI 任务「执行过程」子窗口的数据面（前端开窗期 1s 轮询，见 porting-notes §23） |
| `install` | `{version?}` | `{status: started\|busy}` | 后台执行；版本串白名单校验 |
| `update` | `{version?}` | 同上 | 与 install 同一执行体 |
| `doctor` | — | 同上 | 校验修复已装 dsh（垫片自愈/pty 顶替/实载校验/标记重建，不下载不重装） |
| `uninstall` | `{runtime?}` | 同上 | 卸载 dsh + 版本标记；`runtime:"1"` 连托管 Node 运行时一起删（purge），缺省保留运行时 |
| `migrate` | `{target}` | `{status: started\|busy\|invalid_target}` | 迁移安装目录到 `target`（后台任务）：暂存整拷→校验→UCI 切换→删旧，失败旧目录分毫不动（详见「安装目录迁移」节） |
| `check_update` | — | `{status: ok\|error, installed, latest, available: yes\|no\|unknown, error, ts}` | 同步查 GitHub 最新发布（LuCI「检查更新」）；结果写缓存供 status 展示 |
| `check_dsh` | — | `{status: ok\|error, installed, latest, available: yes\|no\|unknown, error, ts}` | 同步查 npm 源（UCI `npm_registry`）上 `@deepseek-ai/dsh` 最新稳定版，与本机 `dsh.version` 标记比对（LuCI「更新 dsh」的前置检查——确认真有新版才由前端弹「更新到 X」确认框）；单跳限 12s；结果写 `dsh-check` 缓存供 status 展示 |
| `selfupdate` | — | `{status: started\|busy}` | 后台任务：查新版 → 下载 ipk → sha256 → opkg 安装（详见「软件包自更新」节） |
| `localinstall` | `{path}` | `{status: started\|busy\|invalid_path\|missing_file}` | 上传包本地安装（后台任务）：`path` 只认 LuCI 上传通道固定落点 `/etc/luci-uploads/openwrt-dsh-upload.ipk`（三道白名单闸：rpcd 桥/task.sh/localinstall.sh）；引擎预检 gzip 魔数 + control 成员，opkg 带 `--force-reinstall --force-downgrade`（升级/降级/重装都是本动作的合法诉求，降级有日志警示）；成功清理上传包，失败保留供重试（详见「上传包本地安装」节） |
| `web_set` | `{on}` | `{status: ok\|not_installed\|invalid}` | 启/停 dsh Web 服务（同步，本地毫秒级）：`on:"1"` 先查已装（未装拒启，防 respawn 循环）→ UCI enabled=1 + init enable+start；`on:"0"` → enabled=0 + stop+disable。procd 拉起是异步的，运行状态以 status 的 `web_running` 为准 |
| `listdir` | `{path}` | `{path,free,mount,tmpfs,entries[]}` | LuCI 图形化选安装目录的数据源（列子目录 + 挂载/内存盘/空间标注） |
| `mkdir` | `{dir,name}` | `{path}` 或 `{error}` | 选目录弹窗里的新建文件夹（名称禁 `/ . ..`，父目录禁 `..` 段） |

JSON 转义注意（后端已处理）：日志里的下载进度行含 `\r` 与 ESC 清色序列，是非法 JSON 控制字符——先 `tr '\r' '\n'` 展开为多行、`tr -d` 删其余控制字符，再 awk 转义反斜杠/引号/tab。

## UCI（/etc/config/openwrt-dsh，core 段与 web 段）

### core 段

| 项 | 默认 | 说明 |
|---|---|---|
| `install_dir` | `/opt/openwrt-dsh` | 安装根目录；flash overlay 放不下时改数据盘。已装内容的搬家不用手改配置——用 LuCI 安装目录旁的「迁移」按钮（或 CLI `openwrt-dsh migrate <目录>`），引擎会连内容带配置一起切过去 |
| `npm_registry` | `https://registry.npmmirror.com` | npm 源；显式设 `https://registry.npmjs.org` 回官方 |
| `github_repo` | `StormDAmon/openwrt-dsh` | 自更新检查的仓库（owner/repo），可指 fork |
| `github_proxy` | （空） | GitHub 加速代理，前缀形态：`https://ghfast.top` → `https://ghfast.top/https://github.com/...`；留空直连 |

### web 段（dsh Web 服务）

| 项 | 默认 | 说明 |
|---|---|---|
| `enabled` | `0` | 服务总开关（默认关：开启 = 局域网可达的 dsh 界面，必须用户显式开）。rpcd `web_set` 托管写入并同步 init 脚本 enable/disable |
| `port` | （缺省=自动） | 监听端口：缺省/留空/非法/旧固定 `3080` = **自动选择**（每次启动在 3081-3099 取第一个空闲，端口真源 = out.log 启动行，§25）；显式指定 1-65535 则固定使用，被占在启用时被拒（`port_busy`）。改动后经 init 的 config trigger 自动重启生效。LuCI 页面不提供端口输入框（2026-10-20 删）——本项只能手工 `uci set` 配置 |

（曾有的 `remote_settings` 选项已废，2026-10-21 §26 补记：LAN 设置解锁补丁默认涂抹、无开关，残留配置值被忽略）

## 软件包自更新（GitHub Releases）

LuCI「软件包更新」区与 CLI `check-update` / `selfupdate` 的数据面，全部住在 lib.sh：

1. **探测最新 tag**：不走 api.github.com（CN 常不可达，加速代理也基本不代它）。请求
   `<repo>/releases/latest`，GitHub 302 到 `/releases/tag/vX.Y.Z`——curl 用
   `-w '%{url_effective}'` 取终址，OpenWrt 的 wget（uclient-fetch，无 `-S` 但会跟 302）
   退化为取终页正文 grep canonical；两路都靠 `/releases/tag/\(v[0-9.]*\)` 正则出 tag。
2. **比版本**：本包已装版本读包自带的版本标记 `/usr/lib/openwrt-dsh/version`
   （`0.1.0-r3` 形态，缺失才退 opkg 库；去 `-rN` 只比三段数字，复用 `odw_node_ge`）；
   两处都取不到时 available=unknown 交用户决断。
3. **定位资产**：优先 `releases/download/<tag>/sha256sums.txt`（release.sh 固定上传，
   内含确切 ipk 文件名 + 哈希）；取不到再按命名规则推断 `openwrt-dsh_<版本>-r1_all.ipk`
   （release.sh 每次发布把 PKG_RELEASE 重置为 1，tag 对应的 ipk 文件名因此确定）。
4. **下载与校验**：`odw_dl` 带进度下载，sha256 校验不过即放弃安装。
5. **opkg 安装**：装前 `mkdir -p /var/lock`（容器/极简环境缺它）；只替换插件文件，
   `<install_dir>` 下的 dsh 与 Node 运行时不受影响；conffile 由 opkg 规则保留现配。

两处调用形态：`check_update` 同步应答（单跳限 12s、代理+直连两跳共 24s，赶在 LuCI
rpc 超时内），结果落 `/tmp/openwrt-dsh/update-check` 缓存，之后的 status 轮询只读缓存；
`selfupdate` 走 task.sh 后台任务（与安装/卸载同一把锁、同一个日志区），执行时**现查**
不信任缓存。CN 直连 GitHub 不通属常态：先在设置里配 `github_proxy`，仓库必须公开
（私有仓匿名 404，表现为「检查失败」）。

## 安装目录迁移（LuCI「迁移」按钮 / CLI `openwrt-dsh migrate <目录>`）

把 `<install_dir>` 下的全部托管内容（`runtime/` + `dsh.version` 标记）整体搬到目标
目录，收尾把 UCI `install_dir` 切过去——wrapper/CLI/LuCI/profile.d 都动态读 UCI，
切换后自动指新位置，引擎目录（`/usr/lib/openwrt-dsh`）归包管不参与迁移。

「整体搬家」可行的前提：三级垫片的 LD 路径全相对（`$0` 自算，porting-notes §4）、
ELF 补丁长在 `node.bin` 本体里、三件套与原生件都是普通文件——整树 `cp -a` 到新路径
照常能跑，无绝对路径残留。

流程刻意做成**先复制后切换**，顺序不能倒（`migrate-dsh.sh`）：

1. **守卫面**：目标需绝对路径、禁 `. ..` 段；拒绝同目录、`/`、与当前目录互相嵌套
   （多带一个 `/` 比前缀，`/opt/openwrt-dsh` 与 `/opt/openwrt-dsh2` 兄弟目录不误拒）；
   目标已有同名内容（撞名=必覆盖用户数据）直接拒绝；已装判定与状态页同一真源
   （`dsh.version` 标记）；目标分区空间 ≥ 现有内容 + 20MB 余量。
2. **暂存整拷**：目标分区上建 `.odw-migrate-stage`（保留命名，残留下次重跑自清），
   顶层条目逐个 `cp -a`（保软链——垫片是软链链），失败即 `rm -rf` 暂存回滚。
3. **暂存校验**：`du` 字节数 10% 容差（跨分区块尺寸有差，拦的是「拷了一半」）+
   关键件（`dsh.version`、最新运行时 `bin/node`+`bin/dsh`）。
4. **切换**：暂存条目逐个 `mv` 进目标（同分区 rename 秒级；跨分区已在 cp 阶段实拷完）。
5. **新位置实载自检**：`dsh --version`（PATH 前插新运行时 bin，与 wrapper 同款）。
   失败 = 刚搬的内容整体回滚，旧目录未动。
6. **UCI 切换**：`uci set/commit openwrt-dsh.core.install_dir`；commit 失败会
   `uci revert` 退掉暂存改动。
7. **删旧**：只删迁移过的顶层条目，根目录删空后 `rmdir` 顺手清（混有别的数据则保留，
   与 uninstall purge 同款语义）。

任何一步失败旧目录都分毫不动，绝不出现「旧的已删、新的不全」的中间态。UI 侧只有
**已安装**（读到 dsh 版本）时「迁移」按钮才可点；弹窗复用「浏览」的选目录器，选完
还要过一道确认框才起任务。迁移期间请勿运行 dsh（在跑的进程靠已打开 inode 不受影响，
删旧之后的新启动一律走新路径）。

## 状态快路径设计

LuCI 每 2s 轮询 status；在路由器上拉起一次 node 以秒计，所以 `status.sh` 只读安装期落盘的 `node.version` / `dsh.version` 标记；标记缺失才做一次慢探测并回写。**改版本采集逻辑时不要破坏这条**。

同一纪律覆盖检查类字段：`pkg_version` 第一真源是包自带的版本标记（本地小文件，读它与缓存命中同价），缺失才退 opkg 库（纯 awk，结果按库 mtime 缓存进 `/tmp`，opkg 动过库才重算）；`gh_*` 只读「检查更新」落盘的 `update-check` 缓存；`dsh_*` 只读「更新 dsh」前置检查落盘的 `dsh-check` 缓存——**status 快照路径绝不发起网络请求**，联网检查只发生在 check_update / check_dsh / selfupdate 被显式调用时。

## dsh 运行时更新（LuCI「更新 dsh」按钮的前置检查）

「更新 dsh」更新的是 npm 包 `@deepseek-ai/dsh`，与插件包自更新（GitHub Releases）是
两条独立的链，刻意不共用：源不同（npm registry vs GitHub）、缓存不同（`dsh-check` vs
`update-check`）、入口不同（update 按钮前置 vs 检查更新按钮）。

交互是**先检查后确认**：点「更新 dsh」→ 同步 rpc `check_dsh`（npm 源单跳限 12s，赶在
LuCI rpc 超时内）→ `available=yes` 才弹「更新到 X」确认框，确认后走 update 后台任务
（装最新版，检查与执行间的秒级窗口由 @latest 语义兜底）；`available=no` 只报「已是最新」
不给按钮；检查失败也只报错不更新——用户要的是「确认有更新才动手」。缓存里的 latest
同时驱动状态表「dsh 版本」行的「可更新到 X」标记，前端用三段数字比较挡住「装完新版
但缓存还没重查」的过期显示。

## 上传包本地安装（LuCI「上传安装」按钮 / 拖 ipk 到按钮上）

「软件包更新」区里「检查更新」左侧的「上传安装」按钮：点它选本机 ipk，或把 ipk 直接
拖到按钮上（dragover/drop 原生事件，高亮提示可松手）。与「立即更新」（GitHub）互补：
离线环境、装旧版回退、开发期装本地构建物。

前端链路（main.js）：文件名校验（`openwrt-dsh_*.ipk`）+ 8MB 上限（本插件 ipk 只有几十
KB，超大必是拿错文件；且上传会整个落进 /tmp 的 tmpfs）→ 确认弹窗（文件名/大小/包内
版本）→ `request.post(L.env.cgi_base + '/cgi-upload', FormData)` → rpc `localinstall`。

上传通道刻意走 LuCI 自带的 **cgi-io**（`/www/cgi-bin/cgi-upload`，luci-base 硬依赖），
不另造服务端端点：multipart 字段 `sessionid`/`filename`/`filedata`，落盘路径就是
`filename` 字段，但受会话 ACL **按路径**管控（rpcd `file.write` 权限匹配），luci-base
只放行 `/etc/luci-uploads/*`——所以固定落点 `/etc/luci-uploads/openwrt-dsh-upload.ipk`，
三道白名单闸（rpcd 桥 / task.sh / localinstall.sh）都按它校验。cgi-io 成功应答
`{size, checksum, sha256sum}`；失败应答是 **HTTP 200 + `{failure:[errno,str]}`**
（response() 恒打 Status: 200），前端必须看 body 的 failure 字段。cgi-io 的临时文件用
`open("/tmp", O_TMPFILE)`——真机 /tmp 是 tmpfs 没问题；overlayfs /tmp（本项目测试容器）
会 EOPNOTSUPP，浏览器级全链测试要用 `--tmpfs /tmp` 起容器。也不用 24.10 才有的
`ui.uploadFile` helper（自带选文件弹窗与拖放对不上），两版 LuCI 通用的
`request.post + FormData` 即可（22.03 自家 ui.js 同款用法）。

引擎链路（localinstall.sh，经 task.sh 以 /tmp 副本重入——opkg 会原地截断替换引擎脚本，
同 selfupdate 的 §14 铁律）：包完整性预检（gzip 魔数 + tar 列表含 control.tar.gz）→
版本对照（尽力从包内 control 读版本；同版本重装、更低版本显式回退都放行——用户亲自
选的文件，不沿用 selfupdate 的「只升不降」，但降级打日志警示）→
`opkg install --force-reinstall --force-downgrade` → 成功后同步检查缓存、删除上传包、
提示刷新页面；失败保留上传包供重试。opkg 收尾会触发本包 postinst（rpcd reload + 清
LuCI 缓存），新界面文件名随版本变，浏览器刷新后才加载新 JS（§20）。

## Web 界面（dsh web 服务，LuCI「Web 界面」区）

把路由器当 dsh Web 主机：局域网设备浏览器打开 dsh 界面即可使用。由三块组成：

- **procd 服务** `openwrt-dsh-web`（init 脚本，首行 rc.common）：双门禁——UCI
  `web.enabled=1`（默认关）与 dsh 已装（与 `/usr/bin/dsh` wrapper 同一套运行时解析，
  未装拒启防 respawn 循环）；`procd_set_param env HOME=/root`（procd 实例环境无登录
  壳，dsh 解析 DSH_HOME 依赖它）+ respawn 限次；config trigger（`config.change` on
  `openwrt-dsh`）让 LuCI 保存设置/手改 UCI 后自动重启生效。
- **进程包装** `web-run.sh`：procd 的 command 是直接 exec 的 argv 没有重定向，而带令牌
  链接只存在于 dsh web 的启动行 stdout——包装在 exec 前把 stdout/stderr 接到
  `/tmp/openwrt-dsh-web/out.log`（每次启动清零，停止连目录删），exec 后 fd 传给 node
  本体，procd 跟踪的就是 dsh 进程。
- **LAN 绑定 overlay** `web-lan.patch.yml`：dsh web 的 WebServer host 只认
  `127.0.0.1`/`0.0.0.0` 两值，CLI 显式拒绝 `0.0.0.0`（上游「暂不为安全开放」），但配置
  层合法且绑定后 dsh 自动把全部非回环 IPv4 加进浏览器信任栅栏、启动行附带
  `(LAN: http://<ip>:<port>/?token=…)`。本包经 `--patch` 官方通道钉 host，端口仍走
  `--port`（UCI 可配）。补丁语义是整体替换目标行 config，overlay 里必须把 webserver
  行全部键按 dsh 自带值重述（porting-notes §22）。
- **LAN 设置解锁** `web-patch.sh`（默认涂抹，2026-10-21 拍板撤销开关，§26 补记）：
  dsh 的设置页只认本机回环打开的浏览器页面（判定在 web 客户端单点，看地址栏主机名），
  LAN IP 打开时「设置→模型」整页拒载。install/update/doctor 无条件重涂单点补丁
  （awk 字面量替换、幂等、锚点不在整体不动），**涂成功且 Web 服务在跑就自动重启**
  ——/plugins 包体 rev 由文件 mtime 派生、响应 immutable 缓存一年，只有重启才重扫
  进 boot 清单（§26 补记 II）；插件包升级的 postinst 也先涂后重启（升级不动 dsh
  本体，install-dsh.sh 不会跑）。实况经 status 的 `web_remote_state`
  透出（`changed` = dsh 上游改码锚点漂移，重跑「校验修复已装 dsh」即愈）。
  曾有的 UCI `web.remote_settings` 开关、rpcd `web_remote_set` 与 LuCI 按钮/确认框/
  状态行一并删除。残留边界：DeepSeek 账号登录上游仍只承诺回环/SSH 转发。

**rpcd status 的 web_* 字段**（全本地读，快路径纪律同版本标记）：`web_enabled`/`web_port`
读 UCI；`web_running` 查 ubus 服务表实例；`web_url` 在运行中才从 out.log 提取——优先
LAN 链接（回环链接在用户 PC 上指向用户自己的机器），剔除引号/反斜杠再进 JSON。

**「打开」按钮**（仅已安装时显示）：运行且拿到链接才可点，`window.open` 新标签直达。
地址取法：浏览器当前以 IP 字面量访问 LuCI 时用同一 IP + 端口 + 令牌（该 IP 就是用户
可达的接口，且 IP 字面量 Host 必过 dsh 信任栅栏）；否则退后端 LAN 链接；都没有则置灰
（不给只会误导的回环链接）。令牌即「操作路由器的钥匙」，不做复制/展示扩散。

**安全边界**：默认关；令牌 32 字节随机/进程，无令牌一律 401；OpenWrt 默认防火墙拒
WAN 入站——LAN only 靠默认防火墙 + 绑定即得，本包不加任何防火墙规则，LuCI 文案警示
勿做端口转发。卸载 dsh 后服务若在运行会随进程老化（respawn 放弃后停在已停止），
`web_set` 在未装态直接拒启。LAN 设置解锁补丁放宽的是 dsh 自己的「设置仅本机」边界
（含 API 密钥），默认涂抹是产品拍板（局域网使用是主场景，§26 补记）——暴露面仍由
「默认关 + 令牌 + 默认防火墙」三道闸兜住；而「彻底去令牌」明确不做——operator
对话=路由器 shell，LAN 免鉴权即 RCE（porting-notes §26 第 4 条）。

## 设计取舍（有意不做/新增）

- 不做 SSH 向导/宿主侧代码——脚本直跑在路由器上，rpcd 替代 SSH 通道
- 不保留旧式垫片迁移——新装项目无历史布局包袱
- 后台服务只有**可选**的 dsh Web 服务（openwrt-dsh-web，默认关、双门禁，见上一节），
  刻意不加防火墙规则、不做反代/端口管理；dsh web 的暴露面靠「默认关 + 令牌 + 默认
  防火墙」三道闸兜住。dsh 托管入口仍走 `/usr/bin/dsh` wrapper（非软链，见
  porting-notes §12）+ profile.d PATH 集成 + 版本标记
- 新增：版本标记快路径、UCI 配置、npm registry 可配置、任务锁与状态机、
  doctor 校验修复动作、uninstall 卸载动作（keep/purge 两档）、运行时级 npmrc（官方安装路径的尽力等价）、
  dsh Web 服务（procd + LAN overlay + 令牌链接透出）、LAN 设置解锁（web-patch.sh
  单点补丁默认涂抹，无开关，§26 补记）；
  明确不做：去掉 Web 令牌（LAN 免鉴权 = RCE，porting-notes §26 第 4 条）
