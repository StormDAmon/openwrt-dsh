@echo off
rem ============================================================
rem  openwrt-dsh 一键打包（双击运行）
rem  流程：tools/dev-bump.sh（每次打包自动递增修订号：PKG_RELEASE+1 并同步引擎
rem        版本标记；号只增不减，构建失败也不回收。正式发布仍走 tools/release.sh，
rem        发布时会重置 r1）
rem   → tools/build-ipk.sh（Git Bash 里跑，Windows 下自动经
rem        WSL Ubuntu 构建，产物 ipk 落在 dist\）
rem  完成后自动打开资源管理器并选中最新 ipk。
rem
rem  依赖：Git for Windows（自带 bash）、WSL、work\openwrt-sdk-*.tar.zst
rem  日志：work\packaging-last.log（每次覆盖）
rem ============================================================
setlocal
chcp 65001 >nul
title openwrt-dsh 一键打包
cd /d "%~dp0"

rem ---- 定位 bash：优先 Git Bash 自带；system32 的 bash.exe 是 WSL 入口，
rem ---- 不能用来跑本仓库脚本（进去就变成 Linux 形态、缺参数），必须排除
set "BASH_EXE="
if exist "%ProgramFiles%\Git\bin\bash.exe" set "BASH_EXE=%ProgramFiles%\Git\bin\bash.exe"
if not defined BASH_EXE if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" set "BASH_EXE=%ProgramFiles(x86)%\Git\bin\bash.exe"
if not defined BASH_EXE if exist "%LOCALAPPDATA%\Programs\Git\bin\bash.exe" set "BASH_EXE=%LOCALAPPDATA%\Programs\Git\bin\bash.exe"
if not defined BASH_EXE (
    for /f "delims=" %%P in ('where bash 2^>nul') do (
        if not defined BASH_EXE if /i not "%%P"=="%SystemRoot%\system32\bash.exe" set "BASH_EXE=%%P"
    )
)
if not defined BASH_EXE (
    echo [错误] 没找到可用的 bash。请先安装 Git for Windows（自带 bash）后重试。
    pause
    exit /b 1
)

rem ---- 预检 SDK 包（build-ipk.sh 只认 work\openwrt-sdk-*.tar.zst）----
set "SDK_TAR="
for /f "delims=" %%F in ('dir /b /a-d "work\openwrt-sdk-*.tar.zst" 2^>nul') do set "SDK_TAR=%%F"
if not defined SDK_TAR (
    echo [错误] 缺少 SDK 包 work\openwrt-sdk-*.tar.zst
    echo   下载: https://downloads.openwrt.org/releases/24.10.8/targets/x86/64/
    pause
    exit /b 1
)

rem ---- 开发期版本自增：每次打包 PKG_RELEASE+1 并同步引擎版本标记，失败即中止 ----
"%BASH_EXE%" tools/dev-bump.sh
if errorlevel 1 (
    echo [失败] 版本自增没跑成，见上方输出；已中止打包。
    pause
    exit /b 1
)

echo ============================================================
echo  开始打包 openwrt-dsh（SDK: %SDK_TAR%）
echo  首次构建要解压 SDK + 克隆 feeds，耗时较长；增量重跑很快。
echo  实时日志同时写入 work\packaging-last.log
echo ============================================================
"%BASH_EXE%" -c "set -o pipefail; tools/build-ipk.sh 2>&1 | tee work/packaging-last.log"
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" (
    echo [失败] 打包退出码 %RC%。完整日志见 work\packaging-last.log
    echo 常见原因:
    echo   1. WSL 不可用/未装 —— 管理员 PowerShell 执行: wsl --install
    echo      （若报虚拟化错误，需在"启用或关闭 Windows 功能"里开虚拟机平台）
    echo   2. WSL 内依赖没装齐或网络不通（脚本会自动走国内镜像补依赖）
    pause
    exit /b %RC%
)

echo [成功] 产物在 dist\
rem ---- 找最新的 ipk（/o-d 按时间倒序，取第一个），资源管理器里直接选中它
set "NEWEST="
for /f "delims=" %%F in ('dir /b /a-d /o-d "dist\openwrt-dsh_*.ipk" 2^>nul') do (
    if not defined NEWEST set "NEWEST=%%F"
)
if defined NEWEST (
    echo 打开资源管理器并选中: dist\%NEWEST%
    explorer /select,"%~dp0dist\%NEWEST%"
) else (
    echo 没找到 ipk（可能构建部分失败），打开 dist 目录查看。
    explorer "%~dp0dist"
)
endlocal
