# Roadmap

按优先级排序；「接力起点」标记建议下一个开发者/agent 从哪开始。

## P0 — 打磨与验证（容器层已过，剩 SDK 构建与真机）

- [x] **SDK 构建打通**（2026-10-11，官方 SDK 24.10.8 x86_64，`tools/build-ipk.sh`
      全自动借道 WSL）：两个 ipk 构建成功。修掉一个真坑:自带 Alpine musl 预构建
      `pty.node` 撞上 buildroot ELF 依赖扫描（`libc.musl-*` SONAME 永远无法解析），
      用 `Package/openwrt-dsh/extra_provides` 声明自带 SONAME 解决（见 porting-notes
      §13）。ipk 随 GitHub Release v0.1.0 分发
- [x] **容器冒烟**（2026-10-11，官方镜像 `openwrt/rootfs:x86-64-24.10.8`）：全新安装链
      rc=0；登录 shell/wrapper/env -i 四场景 `dsh` 可用；`doctor` 自愈+校验通过；
      官方 `npm i -g` + doctor 收尾链路通过。过程中修掉三个真 bug（见 porting-notes
      §4/§7/§8：busybox awk 花括号正则、垫片烘焙绝对路径死于目录改名、allow-scripts
      列表形态）
- [x] **容器回归**（2026-10-11，`x86-64-22.03.7`）：老加载器探测 → 垫片退 ③ 级 →
      PT_INTERP/DT_NEEDED 双补丁生效 → cnoke 可用；koffi/pty 实载全绿；doctor/官方
      路径同过
- [x] **全功能 e2e 常态化**（2026-10-18，`work/full-e2e.sh` 双容器各一）：打包/postinst
      自动注册/引擎全链路（真下载）/入口四场景/doctor/官方 npm 路径/update/uninstall
      keep+purge/selfupdate 全链（真 opkg 升级链）/锁与忙/JSON 转义/listdir·mkdir
      边界/CLI 全家/22.03 ELF 补丁回归，双绿；首跑修掉四个真 bug（status 多运行时取
      旧、doctor 无 dsh 假绿、selfupdate 降级、uninstall 环境毒化 §4 再犯——见
      porting-notes §16）。此脚本自此为标准回归，凡动引擎/桥层必跑
- [x] **LuCI 弹窗跨版本兼容修复 + 浏览器层回归台**（2026-10-19）：用户真机报「浏览按钮
      点不开、点了转圈」——LuCI master（26.x）把 `ui.showModal` 第三参从 buttons 改成
      `...classes`、`createHandlerFn` 改成先转圈再调函数，旧三参弹窗全灭且转圈永久卡死
      （见 porting-notes §17）。弹窗改两参 + children 内 button-row（两代 LuCI 通吃）；
      连带修掉 listdir/mkdir 根目录双斜杠与挂载徽标失效。回归台两层：full-e2e 新增
      stage ui-http（curl 登录→ACL→admin/ubus 真实链路+公共会话必拒）；
      `work/uitest/ui-regression.mjs` 真 Chrome 全弹窗+浏览全流程+零 pageerror，
      24.10/22.03 双 LuCI 版本各 10/10 绿
- [ ] **真机验收**：iStoreOS/OpenWrt x86_64 真机：安装 → 更新 → 断电重跑幂等 →
      卸载（opkg remove 后 `<install_dir>` 残留策略要明确：保留数据，文档说明）
- [ ] LuCI 视图在真机浏览器过一遍（容器浏览器回归台已建：work/uitest，双 LuCI 版本；
      真机还要看主题适配、中文串抽成 po 或保持内联的取舍）

## P1 — 功能补全

- [ ] **ELF 补丁器单测**：porting-notes §11 的六用例矩阵；index.json 三排版解析一致性测试
- [x] **卸载任务**（2026-10-16）：`openwrt-dsh uninstall [--purge]`（keep 保留托管运行时 /
      purge 连运行时删；npm uninstall 修剪 + 直接清理兜底，见 uninstall-dsh.sh）
- [x] **安装目录迁移**（2026-10-19）：LuCI 安装目录旁「迁移」按钮（仅已安装可点，复用
      浏览弹窗选目标 + 确认框两道闸）+ CLI `openwrt-dsh migrate <目录>`——暂存整拷→
      校验→新位置实载自检→UCI 切换→删旧，失败旧目录分毫不动（见 migrate-dsh.sh 与
      architecture「安装目录迁移」节）。overlay 装不下换数据盘不再需要重装
- [x] **软件包自更新**（2026-10-16）：LuCI「检查更新 / 立即更新」+ CLI
      `check-update` / `selfupdate`——查 GitHub Releases 最新 tag（302 终址法，可配
      加速代理/fork 仓库）→ 下载 ipk → sha256 → opkg 安装；status 快路径只读缓存
      不联网。24.10 容器端到端实测含真 opkg 升级链（见 porting-notes §14）
- [ ] **任务取消**：running 时终止任务进程（kill 任务进程组 + 清锁）
- [x] **dsh web 服务（可选 procd 服务）**（2026-10-19）：LuCI「Web 界面」区——UCI 开关
      （默认关）+ procd init（openwrt-dsh-web，双门禁：enabled + dsh 已装）+ 页面端口/
      访问地址显示 + 「打开」按钮（仅已安装显示，直达带令牌链接）——路由器当 dsh web
      主机用。防火墙口径按「LAN only」落成三道闸：默认关 + 令牌硬闸（无令牌一律 401）
      + 默认防火墙拒 WAN 入站，本包不加任何防火墙规则；LAN 绑定经 --patch 官方通道
      （CLI 拒 0.0.0.0 但配置层合法，见 porting-notes §22 与 architecture「Web 界面」节）。
      full-e2e stage web 双版本全绿（含 401→303→200 真实访问链）；真机待验
- [ ] rpcd `install/update` 支持传 npm spec 全格式（当前白名单已够版本号）

## P2 — 平台扩展

- [ ] **ARM (aarch64) 支持**：三个前置——unofficial-builds 是否有 arm64 musl 变体（若无
      要自建 node 或用 Alpine 的 node 包）、koffi musl arm64 预构建验证、自编译
      node-pty arm64 原生件并按 `uname -m` 选择资产目录
- [ ] glibc 通用 Linux 路径的正名（当前兼容但非目标）

## P3 — 发布

- [ ] iStore 应用市场上架（iStore 提交流程：仓库 + ipk 发布通道）
- [ ] GitHub Actions：SDK 矩阵构建（24.10 / 23.05 × x86_64）+ ipk 产物上传 release
- [ ] 真机截图进 README
