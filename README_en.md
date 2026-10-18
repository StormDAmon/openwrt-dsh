# openwrt-dsh

English | [简体中文](README.md)

A package to install and run **dsh** (DeepSeek Harness, npm package `@deepseek-ai/dsh`) on **OpenWrt / iStoreOS** (x86_64 musl): a single ipk containing both the engine (SSH CLI + rpcd backend) and the LuCI page — once installed, dsh can be installed / updated / uninstalled / migrated with one click from the router's admin UI.

dsh and its dependencies are designed for ordinary Linux (glibc, systemd, bash); routers are musl libc, busybox ash, no systemd, tiny overlay partitions, and often no toolchain at all. The entire value of this project is making that path work — the cause and fix of every pitfall has been verified in real testing, see [docs/porting-notes.md](docs/porting-notes.md).

## Features

- **LuCI page** (Services → **DeepSeek Harness**): status overview (platform / libc / disk space / Node version / dsh version, with the plugin's own version badge next to the page title), one-click **Install dsh / Update dsh / Uninstall dsh** (uninstall keeps the Node runtime by default, optionally wiping it too), **Migrate** (next to the install directory, clickable only when installed: moves everything to a new location such as a data disk; on failure the old directory is left untouched), **verify & repair installed dsh (doctor)**, **package update** ("Check for updates / Update now" buttons: query the latest GitHub Release → download the ipk → sha256 verify → opkg install, with optional GitHub acceleration proxy and fork repository settings), live task progress (the "task status" row in the status table; detailed logs via SSH `openwrt-dsh log`), graphical install-directory browse/create, and npm registry settings
- **SSH CLI**: `openwrt-dsh status|install|update|doctor|uninstall|migrate|check-update|selfupdate|log|node|dsh` — equally usable without a browser
- **Same usage as ordinary Linux**: after installation, `node` / `npm` / `dsh` work directly in the login shell (`/etc/profile.d` integration); `/usr/bin/dsh` is an entry wrapper that resolves the bundled runtime, so cron / procd / non-login shells work too
- The engine handles the whole chain on musl automatically:
  - Node runtime: unofficial musl builds (with automatic mirror failover), auto-upgraded to the latest LTS that satisfies dsh's requirement
  - musl runtime libraries: the Alpine trio (libstdc++ / libgcc / musl loader) shipped along — nothing written to system directories, no opkg dependency
  - Three-level shims + dual ELF patching of PT_INTERP/DT_NEEDED (rescues real-machine segfaults on the older loaders of the OpenWrt 22.03 series)
  - musl fixes for the native koffi / node-pty modules (including a self-compiled musl `pty.node` distributed with the package) + post-install load verification
  - Runtime-level npmrc (allow-scripts package list + mirror registry): even following the official docs and running `npm i -g @deepseek-ai/dsh` raw, the native modules install

## Platform support

| Platform | Status |
|---|---|
| OpenWrt / iStoreOS x86_64 (musl, soft routers / boxes) | ✅ Target platform |
| glibc x86_64 (e.g. Debian containers) | ⚠️ Engine compatible (official Node builds), not the primary test surface |
| ARM routers | ❌ Not supported (no ARM builds exist for the unofficial musl Node or the native modules, see roadmap) |

Prerequisites: `curl` (the engine's main download channel) and CA certificates; about 300MB of writable space (flash overlay usually cannot fit it — **point the install directory at a data disk**, changeable in LuCI settings).

## Installation

Single-package layout (since 2026-10-15): **one ipk contains engine + CLI + rpcd + LuCI page**, iStoreOS compatible; install it manually via iStore or with `opkg install`:

- `openwrt-dsh_*_all.ipk` — engine + CLI + rpcd backend + LuCI page (`arch=all`, works across releases)

Build from source (OpenWrt SDK / buildroot):

```sh
# Example with the 24.10 x86_64 SDK
./scripts/feeds update -a && ./scripts/feeds install -a
cp -r /path/to/openwrt-dsh package/
make package/openwrt-dsh/compile V=s
# Output lands under bin/packages/*/
```

A wrapper script is also available: `tools/build-sdk.sh <SDK root>` (for daily use, `tools/build-ipk.sh` is fully automatic).

## Usage

1. After installing, open LuCI in a browser → Services → **DeepSeek Harness**
2. (Optional) In "Settings", point the **install directory** to a data-disk partition (default `/opt/openwrt-dsh`)
3. Click **Install dsh**; the log area shows live progress (download → runtime libs → shims/patches → npm install → load verification)
4. When done, `dsh`, `node`, `npm` work directly over SSH (login shells get PATH via `/etc/profile.d`; non-login contexts such as cron/procd fall back to the `/usr/bin/dsh` entry wrapper)
5. Want to move to another partition later (e.g. the overlay is getting tight): click **Migrate** next to the install directory and pick a new one — the installed contents move as a whole, and the old directory is untouched on failure; SSH equivalent: `openwrt-dsh migrate <directory>`
6. Upgrading the plugin itself: in LuCI's "Package update (GitHub)" click **Check for updates → Update now**, or over SSH `openwrt-dsh check-update && openwrt-dsh selfupdate` (on CN networks, configure a GitHub acceleration proxy in settings; the repository must be public)

### Two ways to install dsh

- **Recommended: one click in LuCI, or `openwrt-dsh install`** — the official install steps plus every musl fix; ready to use immediately, idempotent, safe to re-run.
- **Advanced: follow the official docs manually** (once Node is ready):

  ```sh
  npm install -g @deepseek-ai/dsh
  openwrt-dsh doctor   # mandatory on musl: replaces node-pty's glibc prebuilt + load verification
  ```

  The official command does install (the runtime npmrc whitelists the native postinstall scripts), but npm re-extracts node-pty's glibc prebuilt — on musl this means "installation reports no error, yet the terminal crashes the moment it opens". `doctor` exists precisely to fix that. **A raw install without running doctor ≠ installed.**

## Origin & disclaimer

The engine logic of this project was shaped through many rounds of real testing on iStoreOS/OpenWrt hardware and the official OpenWrt rootfs containers. The dsh package itself is DeepSeek's npm package; this project neither modifies nor distributes its code. `pty.node` is a musl self-compilation of node-pty (MIT) built on Alpine. This project's own code is released under the MIT license.

## Documentation

- [docs/architecture.md](docs/architecture.md) — package layout, data flow, rpcd/UCI interfaces
- [docs/porting-notes.md](docs/porting-notes.md) — **porting notes (required reading)**: the real-test evidence behind every technical decision
- [docs/roadmap.md](docs/roadmap.md) — ARM support, the dsh web service, iStore listing, and more
- [AGENTS.md](AGENTS.md) — developer/agent handoff guide (current status, conventions, next steps)
