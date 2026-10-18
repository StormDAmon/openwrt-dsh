# openwrt-dsh

简体中文 | [English](README_en.md)

在 **OpenWrt / iStoreOS**（x86_64 musl）上安装与运行 **dsh**（DeepSeek Harness，npm 包 `@deepseek-ai/dsh`）的软件包：一个 ipk 同时包含引擎（SSH CLI + rpcd 后端）与 LuCI 页面，装好后可在路由器管理页里一键安装/更新/卸载/迁移 dsh。

dsh 及其依赖是为常规 Linux（glibc、systemd、bash）设计的；路由器是 musl libc、busybox ash、无 systemd、overlay 分区小、还常常没有编译工具。本项目的全部价值就在于把这条链路打通——每一个坑的成因与修法都实测过，见 [docs/porting-notes.md](docs/porting-notes.md)。

## 功能

- **LuCI 页面**（服务 → **DeepSeek Harness**）：状态总览（平台/libc/空间/Node 版本/dsh 版本，页面标题旁常驻显示插件自身版本号）、一键**安装 dsh / 更新 dsh / 卸载 dsh**（卸载默认保留 Node 运行时，可选连运行时一起清）、**迁移**（安装目录旁，仅已安装可点：把已装内容整体搬到数据盘等新目录，失败不动旧目录）、**校验修复已装 dsh（doctor）**、**软件包更新**（「检查更新 / 立即更新」按钮：查 GitHub Releases 最新版 → 下载 ipk → sha256 校验 → opkg 安装，可配加速代理与 fork 仓库）、实时任务进度（状态表「任务状态」行，日志明细走 SSH `openwrt-dsh log`）、安装目录（图形化浏览/新建）与 npm 源设置
- **SSH CLI**：`openwrt-dsh status|install|update|doctor|uninstall|migrate|check-update|selfupdate|log|node|dsh`，无浏览器场景同样可用
- **与普通 Linux 一致的使用方式**：安装后登录 shell 里 `node` / `npm` / `dsh` 直接可用（`/etc/profile.d` 集成），`/usr/bin/dsh` 是自带运行时解析的入口脚本，cron / procd / 非登录 shell 里同样可用
- 引擎自动处理 musl 机全链路：
  - Node 运行时：unofficial musl 构建（镜像自动 failover），自动升到满足 dsh 要求的最新 LTS
  - musl 运行库：Alpine 三件套（libstdc++ / libgcc / musl 加载器）自备，不写系统目录、不依赖 opkg
  - 三级垫片 + PT_INTERP/DT_NEEDED 双 ELF 补丁（救 OpenWrt 22.03 系老加载器真机段错误）
  - koffi / node-pty 原生件 musl 修复（含随包分发的自编译 musl 版 `pty.node`）+ 装后实载校验
  - 运行时级 npmrc（allow-scripts 包名列表 + 镜像源）：照官方文档裸跑 `npm i -g @deepseek-ai/dsh` 也能装上原生件

## 平台支持

| 平台 | 状态 |
|---|---|
| OpenWrt / iStoreOS x86_64（musl，软路由/盒子） | ✅ 目标平台 |
| glibc x86_64（如 Debian 容器） | ⚠️ 引擎兼容（走官方 Node 构建），非主要测试面 |
| ARM 路由器 | ❌ 未支持（unofficial musl 构建与原生件均无 ARM 版，见 roadmap） |

安装前置：`curl`（引擎依赖它做主下载通道）与 ca 证书；约 300MB 可写空间（flash overlay 通常放不下，**建议把安装目录设到数据盘**，LuCI 设置里可改）。

## 安装

单包形态（2026-10-15 起）：**一个 ipk 包含引擎 + CLI + rpcd + LuCI 页面**，iStoreOS 兼容，可用 iStore 手动安装或 `opkg install`：

- `openwrt-dsh_*_all.ipk` —— 引擎 + CLI + rpcd 后端 + LuCI 页面（`arch=all`，跨版本通用）

从源码构建（OpenWrt SDK / buildroot）：

```sh
# 以 24.10 x86_64 SDK 为例
./scripts/feeds update -a && ./scripts/feeds install -a
cp -r /path/to/openwrt-dsh package/
make package/openwrt-dsh/compile V=s
# 产物在 bin/packages/*/ 下
```

也可用封装脚本：`tools/build-sdk.sh <SDK根目录>`（日常请用 `tools/build-ipk.sh`，全自动）。

## 使用

1. 装好后浏览器打开 LuCI → 服务 → **DeepSeek Harness**
2. （可选）「设置」里把**安装目录**改到数据盘分区（默认 `/opt/openwrt-dsh`）
3. 点**安装 dsh**，日志区实时显示进度（下载 → 运行库 → 垫片/补丁 → npm 安装 → 实载校验）
4. 完成后 SSH 里直接 `dsh`、`node`、`npm`（登录 shell 由 `/etc/profile.d` 集成 PATH；cron/procd 等非登录场景由 `/usr/bin/dsh` 入口脚本兜底）
5. 装完想换分区（比如 overlay 吃紧了）：安装目录旁点**迁移**选个新目录即可，已装内容整体搬家、失败不动旧目录；SSH 里等价 `openwrt-dsh migrate <目录>`
6. 插件自身升级：LuCI「软件包更新（GitHub）」点**检查更新 → 立即更新**，或 SSH 里 `openwrt-dsh check-update && openwrt-dsh selfupdate`（CN 网络可在设置里配 GitHub 加速代理；仓库需公开）

### 安装 dsh 的两种方式

- **推荐：LuCI 一键或 `openwrt-dsh install`**——官方安装步骤 + 全部 musl 修复，装完即用，幂等可重跑。
- **进阶：照官方文档裸跑**（Node 就绪后）：

  ```sh
  npm install -g @deepseek-ai/dsh
  openwrt-dsh doctor   # musl 机必跟：顶替 node-pty 的 glibc 预构建 + 实载校验
  ```

  官方指令能装上（npmrc 已放行原生件脚本），但 npm 会重新解出 node-pty 的 glibc 预构建——musl 上「安装不报错、终端一开就崩」，`doctor` 专修这个。**裸装后不跑 doctor ≠ 装好了。**

## 项目来源与声明

本项目的引擎逻辑在 iStoreOS/OpenWrt 真机与 OpenWrt 官方 rootfs 容器上历经多轮实测定型。dsh 本体是 DeepSeek 的 npm 包，本项目不修改、不分发其代码；`pty.node` 为 node-pty（MIT）在 Alpine 上的 musl 自编译产物。本项目代码以 MIT 许可发布。

## 文档

- [docs/architecture.md](docs/architecture.md) —— 包结构、数据流、rpcd/UCI 接口
- [docs/porting-notes.md](docs/porting-notes.md) —— **踩坑笔记（必读）**：每个技术决策的实测依据
- [docs/roadmap.md](docs/roadmap.md) —— ARM 支持、dsh web 服务、iStore 上架等
- [AGENTS.md](AGENTS.md) —— 开发者/agent 交接指南（现状、约定、待办）
