# AGENTS.md —— 开发者/Agent 交接指南

本文件写给接手开发的下一个 agent 或人类。**开工前按顺序读**：
`README.md` → `docs/porting-notes.md`（护城河，必读）→ `docs/architecture.md` → `docs/roadmap.md`。

## 项目现状（2026-10-19 更新）

脚手架完成并通过 **24.10 / 22.03 双官方容器全矩阵实测**（全新安装链、垫片/补丁、
doctor、PATH 集成、官方 npm 路径 + doctor 收尾，全绿；详见 porting-notes §12 与
roadmap P0 勾选记录，过程中修掉三个真 bug）。SDK 构建已打通（ipk 可产出并随
GitHub Release 分发）；2026-10-18 起新增 `work/full-e2e.sh` 单容器全功能 e2e，
双版本容器各跑一遍成为标准回归（详见 porting-notes §16），首跑修掉四个真 bug
（status 多运行时取旧 / doctor 无 dsh 假绿写「未知」标记 / selfupdate 降级 /
uninstall 环境毒化 §4 再犯）。2026-10-19 起 e2e 补浏览器真实链路（stage ui-http：
登录会话→ACL→admin/ubus），并新增 `work/uitest/ui-regression.mjs` 真 Chrome UI
回归台（双 LuCI 版本各跑，24.10 新 LuCI 的 showModal 签名变更曾把全插件弹窗炸成
「点不开+永久转圈」，见 porting-notes §17——动 LuCI 视图必跑）。**尚未做过：真机
验证**（roadmap P0 是接力起点）。

全功能容器回归跑法（约 2 分钟/容器；基座与假升级包都从**当前树**现打、全走 `work/`，
**dist/ 全程零污染**——release.sh 会把 dist/*.ipk 全量挂上真发布；wsl 原生 docker 需要
`--add-host=host.docker.internal:host-gateway`，编排脚本已带）：

```sh
# 全功能 e2e 一键编排(24.10/22.03 各跑一遍;含 stage ui-http 浏览器真实链路)
wsl -u root bash /mnt/c/.../work/run-full-e2e.sh 24.10

# LuCI 前端交互回归(真 Chrome 驱动;先起一个装了当前树的容器并映射端口,见
# work/uitest/ui-regression.mjs 头注释;双 LuCI 版本各跑,24.10 新 LuCI 曾炸全弹窗)
wsl -u root bash /mnt/c/.../work/start-2203.sh          # 或手工 docker run -p 18091:80 …
node work/uitest/ui-regression.mjs                      # BASE=http://127.0.0.1:18091 切 22.03
```

已实现：

- 引擎八脚本 + elf-patch.js/web-patch.sh（`openwrt-dsh/files/usr/lib/openwrt-dsh/`）
  - install-dsh.sh 主链路 install|update|doctor 三动作：运行时保障 → ELF 双补丁 →
    libexec 真身 npm（allow-scripts 列表形态）→ 孤儿 bin 清理 → koffi 重编重试 →
    koffi/pty 实载校验 → 版本标记；doctor 不下载不重装，只自愈/顶替/校验/落标记
  - uninstall-dsh.sh 卸载动作 keep|purge：npm uninstall 修剪 + 直接清理兜底 + 标记清除；
    keep 保留托管运行时（重装免下载），purge 连 <install_dir>/runtime 一起删
  - migrate-dsh.sh 安装目录迁移（2026-10-19，LuCI「迁移」按钮 + CLI migrate）：暂存
    整拷→校验→新位置实载自检→UCI 切换→删旧，失败旧目录分毫不动；为什么必须先复制
    后切换见 porting-notes §18
  - selfupdate.sh 软件包自更新：查 GitHub Releases 最新 tag（302 终址法，见 §14）→
    下载 ipk → sha256 → opkg 安装；task.sh 以 /tmp 副本重入执行（opkg 会截断替换
    运行中的脚本，见 porting-notes §14）
  - localinstall.sh 上传包本地安装（2026-10-19，LuCI「上传安装」按钮/拖放）：cgi-io
    上传 ipk 到 /etc/luci-uploads 固定落点 → 预检（gzip 魔数+control 成员）→ 版本对照
    → opkg --force-reinstall --force-downgrade（升级/降级/重装均可，见 §21）；
    task.sh 以 /tmp 副本重入执行（同 §14）
  - runtime.sh：Alpine 三件套、三级垫片（路径全相对）、垫片自愈、LTS 升级链
    （node 解析 + awk 兜底，busybox awk 无花括号正则——见 §8）
  - web-run.sh dsh Web 服务进程包装（2026-10-19，LuCI「Web 界面」区）：procd 前台
    exec dsh web --patch web-lan.patch.yml（LAN 绑定）+ stdout 落盘供令牌链接提取
    + 自动选端口（UCI port 留空/非法/旧固定 3080 = 每次启动在 3081-3099 现选
    第一个空闲，§25）；
    配套 /etc/init.d/openwrt-dsh-web（双门禁：UCI enabled 默认关 + dsh 已装），
    见 §22
  - web-patch.sh LAN 设置解锁补丁（2026-10-21，§26）：dsh 的设置页只认本机回环
    打开的浏览器页面（web 客户端单点判定、看地址栏主机名），LAN IP 打开时
    「设置→模型」整页拒载。给 dsh 的 client.js 涂恒真单点补丁：awk 字面量替换
    （锚点含正则元字符不过 sed）、幂等标记 /* odw-web-lan */、.odw-orig 备份、
    锚点不在整体不动；**默认涂抹**——install/update/doctor 无条件重涂（npm 重装
    整包替换文件会冲掉补丁；同日拍板撤销 UCI 开关与 web_remote_set，§26 补记）
- 运行时级 npmrc（allow-scripts 包名列表 + 镜像源）：官方 `npm i -g` 路径的尽力等价
- rpcd 后端（status/log/install/update/doctor/uninstall/migrate/selfupdate/localinstall，后台任务 + JSON
  转义处理；check_update 为同步查 GitHub，check_dsh 为同步查 npm 源 dsh 最新版
  （「更新 dsh」前置检查）；web_set 同步启/停 dsh Web 服务（conffile 丢段自愈 +
  失败如实回 error + 启用前端口预检（固定口查占用、自动段查空闲）
  port_busy 拒启，六态
  ok/not_installed/no_init/port_busy/error/invalid，见 §24/§25）；
  status 快照带 web_* 字段（enabled/port/running/带令牌访问 URL/web_error
  崩溃原因——EADDRINUSE 等已人话化并带自救指引，全本地读；web_remote_state
  补丁实况无条件计算，web_remote 开关字段与 web_remote_set 随开关撤销一并删除，
  §26 补记）；另有 listdir/mkdir 供
  LuCI 图形化选安装目录/迁移目标）
- CLI（`/usr/bin/openwrt-dsh`，含 doctor、uninstall [--purge]、migrate <目录>、check-update、selfupdate）
- `/usr/bin/dsh` 托管入口 wrapper + `/etc/profile.d/openwrt-dsh.sh` PATH 集成
  （`dsh`/`node`/`npm` 与普通 Linux 同形同位，cron/procd/非登录 shell 也可用）
- LuCI 视图（状态轮询 2s / 安装·更新·卸载按钮 / 迁移按钮（仅已安装可点，与浏览共用
  选目录弹窗 + 确认框）/ doctor 按钮 / 软件包更新·检查更新+
  立即更新（GitHub）+ 上传安装（检查更新左侧：选 ipk 或拖到按钮上→cgi-io 上传→
  后台 opkg 安装，升级/降级/重装均可）/ UCI 设置含 GitHub 仓库与加速代理 / 标题旁插件版本徽标；
  「更新 dsh」先 check_dsh 前置检查、确认有新版才弹「更新到 X」确认框；
  「Web 界面」区（2026-10-19，2026-10-20 按真机反馈加固见 §24）：启/停 dsh web 服务
  （失败一律弹窗 + 启用后 1s 守望，启动失败原因红字亮在状态行）+ 「打开」按钮
  （仅已安装显示，运行且拿到带令牌链接才可点，新标签直达 dsh 浏览器界面，见 §22）
  + 端口全自动（2026-10-20 起监听端口输入框已删：每次启动自动在 3081-3099 选
    空闲，旧固定 3080 并入自动，§25；固定端口只留手工 UCI 通道
    openwrt-dsh.web.port，实际端口以启动行 web_url 为真源）
  + LAN 设置解锁补丁默认涂抹（2026-10-21 拍板撤销开关：曾有的「局域网设置解锁」
    按钮/安全确认框/状态行已删，§26 补记——设置页在局域网页面开箱可用）；
  任务「执行过程」子窗口（2026-10-19：起后台任务即弹终端样态弹窗 1s 轮询 rpc log
  实时滚日志，收起不断任务，任务进行中状态区「查看执行过程」可重开，见 §23）；
  视图文件打包期改带版本名 main-0_1_0-rN.js + menu.d 同步改写——LuCI 的 ?v= 穿透符
  只跟 luci-base 走，不改名则升级后浏览器数小时内仍跑旧 JS「点不开」，见 §20）
- 包 Makefile（rules.mk 单包形态，2026-10-15 起引擎与 LuCI 页面合并，不走 luci.mk）+ UCI conffile
- 文档四件 + dev-check.sh

## 目录地图

```
openwrt-dsh/                     # 单包（引擎 + rpcd + CLI + LuCI 页面 + 资产 + UCI）
├── Makefile                     # rules.mk；DEPENDS 含 +luci-base
└── files/…                      # 安装清单即目录结构，见 docs/architecture.md
                                 #   files/www/luci-static/… 为 LuCI 视图
                                 #   files/usr/share/{luci/menu.d,rpcd/acl.d}/ 为菜单与 ACL
docs/                            # architecture / porting-notes / roadmap
tools/                           # dev-check.sh / build-sdk.sh / release.sh / build-ipk.sh
```

## 铁律（改引擎前必读）

1. **引擎脚本全体 POSIX（busybox ash）**：无 `[[ ]]`/进程替换/数组；新改动必须过
   `tools/dev-check.sh`（bash -n + sh -n + node --check + JSON 校验）。
2. **porting-notes.md 里的每个坑都不是理论**——垫片级位顺序、libgcc 不进环境、
   下载成功 ≠ 运行成功、幂等三原则（先探测后采用/失败零损伤/可重跑）。
   与这些记录冲突的「优化」默认是错的，先重读对应条目。
3. **镜像顺序有实测依据**（npmmirror 是 unofficial-builds 唯一镜像；Alpine 阿里云首位因
   清华/USTC 403 busybox UA），别乱调。
4. **status 快路径不拉 node**：版本走标记文件；LuCI 2s 轮询，拉 node 会把路由器拖死。
5. 中文注释与日志；注释里保留「为什么」，删注释前确认它不在
   porting-notes 里有对应条目，否则把知识搬进文档再删。

## 构建与验证

**测试环境约定（项目铁则）：本工程所有的测试都通过 OpenWrt 官方 Docker 进行**
（`openwrt/rootfs:x86-64-*` 官方镜像，版本矩阵见 porting-notes §11）。
不在宿主机上裸测，也不用第三方镜像替代官方镜像。

```sh
# 本地语法检查（Windows Git Bash / Linux 通用）
tools/dev-check.sh

# OpenWrt SDK 构建（P0 待办：打通并修 Makefile 兼容性）
tools/build-sdk.sh /path/to/openwrt-sdk-x86_64

# 容器冒烟（容器层已完成，见 roadmap P0 勾选；本命令作单容器快速复验用）
docker run --rm -it openwrt/rootfs:x86-64-24.10.8   # 内装 ipk → openwrt-dsh install

# 构建 ipk 二进制包（Windows 自动借道 WSL Ubuntu；首次自动下载官方 SDK 24.10.8）
tools/build-ipk.sh                # → dist/openwrt-dsh_*.ipk（唯一交付物，arch=all 跨版本通用）

# 一键发布：dev-check → 版本对齐 → release 提交+tag → 构建 ipk → push → GitHub Release
tools/release.sh v0.2.0           # --dry-run 预演；源码包不手工打（GitHub 对 tag 自带源码归档）
```

版本管理约定：版本号唯一真源 = 根目录 `VERSION`，包 Makefile 的 `PKG_VERSION`
与引擎版本标记 `files/usr/lib/openwrt-dsh/version`（LuCI/CLI 展示的插件版本，
形态 `X.Y.Z-rN`）由 release 脚本同步（PKG_RELEASE 随版本重置 1），
dev-check.sh 校验三方一致，tag 一律 `vX.Y.Z`（annotated）。
开发期重复打包（打包.bat）由 `tools/dev-bump.sh` 每次自动递增 PKG_RELEASE 并
同步引擎标记（号只增不减、构建失败也不回收——opkg 按更高版本才升级，复用旧号
= 假升级包）；正式发布仍走 release.sh（重置 r1）。ipk 版本串里的 `r` 是
buildroot 加的（Makefile 里 PKG_RELEASE 只写数字）。
发布脚本未装/未登录 `gh` 时走兜底路径（自动开预填发布页，人工点 Publish）；
装有并登录 `gh` 的机器上全自动（release 连附件一起传）。gh 访问 api.github.com
常需代理，release.sh 会自动探测环境代理。

验证矩阵与测试环境坑见 porting-notes §11。真机验收前不要宣称「已完成」。

## 接力起点

`docs/roadmap.md` P0：~~24.10 容器冒烟~~、~~22.03 补丁链回归~~、~~SDK 构建打通~~
（2026-10-11 tools/build-ipk.sh 起实现，ipk 已能产出并随 release 发布）；
下一棒 = **真机验收**。
构建若报依赖相关错误，优先核对 SDK 的 luci feed 版本与 `LUCI_DEPENDS` 写法。
