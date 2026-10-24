@echo off
setlocal enabledelayedexpansion
chcp 936 >nul
title 双网卡分流一键配置

rem ==========================================================
rem  双网卡分流：外网接口走外网，Wi-Fi 只走内网
rem
rem  用法：双击运行（会自动申请管理员权限）
rem  还原：命令行执行  一键双网卡分流.bat /restore
rem
rem  同事的 NAS 网段不同时，改下面三行即可
rem ==========================================================
set "NAS_NET=192.168.1.0"
set "NAS_MASK=255.255.255.0"
set "NAS_IP=192.168.1.100"

set "ARGS=%*"
if /i "%~1"=="/restore" set "MODE=restore"

rem ---- 管理员权限检查 ----
net session >nul 2>&1
if errorlevel 1 (
    echo 需要管理员权限，正在申请……
    set "SELF=%~f0"
    set "TMPVBS=%TEMP%\getadmin_%RANDOM%.vbs"
    >"!TMPVBS!" echo Set UAC = CreateObject^("Shell.Application"^)
    >>"!TMPVBS!" echo UAC.ShellExecute "cmd.exe", "/c ""!SELF!"" !ARGS!", "", "runas", 1
    cscript //nologo "!TMPVBS!"
    exit /b
)

set "WORK=%TEMP%\net_split_%RANDOM%"
mkdir "%WORK%" 2>nul

echo ==========================================
if defined MODE (echo   还原双网卡设置) else (echo   双网卡分流配置)
echo ==========================================
echo.

rem ---- 识别当前连接的无线接口名 ----
netsh wlan show interfaces > "%WORK%\wlan.txt" 2>nul
findstr /r /c:"^ *Name *:" "%WORK%\wlan.txt" > "%WORK%\wlan_name.txt" 2>nul
set "WLAN_RAW="
set "WLAN_NAME="
for /f "usebackq tokens=2 delims=:" %%g in ("%WORK%\wlan_name.txt") do set "WLAN_RAW=%%g"
if defined WLAN_RAW for /f "tokens=* delims= " %%g in ("!WLAN_RAW!") do set "WLAN_NAME=%%g"

if not defined WLAN_NAME (
    echo [错误] 没有检测到已连接的无线网卡，请先连上公司 Wi-Fi。
    goto :fail
)

rem ---- 遍历已连接接口，取出网关 ----
netsh interface ipv4 show interfaces > "%WORK%\ifs.txt" 2>nul

set "WAN_IDX="
set "WAN_GW="
set "LAN_IDX="
set "LAN_GW="

for /f "usebackq skip=2 tokens=1,4*" %%a in ("%WORK%\ifs.txt") do (
    if /i "%%b"=="connected" (
        call :GETGW %%a
        if defined GW (
            if /i "%%c"=="!WLAN_NAME!" (
                set "LAN_IDX=%%a"
                set "LAN_GW=!GW!"
            ) else (
                if not defined WAN_IDX (
                    set "WAN_IDX=%%a"
                    set "WAN_GW=!GW!"
                )
            )
        )
    )
)

if defined MODE goto :DO_RESTORE

if not defined WAN_IDX (
    echo [错误] 没有找到独立的外网接口。
    echo        请先连接外网（USB 共享 / 手机共享 / 外网网线）后再运行。
    goto :fail
)
if not defined LAN_IDX (
    echo [错误] 无法识别内网 Wi-Fi 的网关，请确认 Wi-Fi 已获取到 IP。
    goto :fail
)

echo 外网接口  : 编号 !WAN_IDX!    网关 !WAN_GW!
echo 内网 Wi-Fi: 编号 !LAN_IDX!    网关 !LAN_GW!
echo.

rem ---- 备份当前配置 ----
route print -4 > "%~dp0网络配置备份.txt" 2>nul
netsh interface ipv4 show interfaces >> "%~dp0网络配置备份.txt" 2>nul

rem ---- 应用 ----
echo 正在应用……
netsh interface ipv4 set interface !WAN_IDX! metric=5 >nul
netsh interface ipv4 set interface !LAN_IDX! metric=999 >nul
if errorlevel 1 (
    echo [错误] 设置失败，请确认以管理员身份运行。
    goto :fail
)

route delete %NAS_NET% mask %NAS_MASK% >nul 2>&1
route -p add %NAS_NET% mask %NAS_MASK% !LAN_GW! metric 1 >nul
if errorlevel 1 echo [警告] NAS 路由添加失败（可能已存在相同路由）。

echo.
echo ========== 验证 ==========
ping -n 2 -w 1500 8.8.8.8 >nul 2>&1 && echo [OK]   外网 8.8.8.8 可达 || echo [失败] 外网 8.8.8.8 不可达
ping -n 2 -w 1500 !LAN_GW! >nul 2>&1 && echo [OK]   内网网关 !LAN_GW! 可达 || echo [失败] 内网网关不可达
ping -n 1 -w 1500 %NAS_IP% >nul 2>&1 && echo [OK]   NAS %NAS_IP% 可达 || echo [提示] NAS 未响应（没有 NAS 可忽略）
echo.
route print -4 | findstr /c:"0.0.0.0" /c:"%NAS_NET%"
echo.
echo 配置完成。备份文件：%~dp0网络配置备份.txt
goto :done

:DO_RESTORE
if defined WAN_IDX netsh interface ipv4 set interface !WAN_IDX! metric=automatic >nul 2>&1
if defined LAN_IDX netsh interface ipv4 set interface !LAN_IDX! metric=automatic >nul 2>&1
route delete %NAS_NET% mask %NAS_MASK% >nul 2>&1
echo 已还原：接口跃点数恢复为自动，NAS 路由已删除。
goto :done

:GETGW
set "GW="
set "GWTMP="
netsh interface ipv4 show config %1 > "%WORK%\cfg.txt" 2>nul
findstr /c:"Default Gateway:" "%WORK%\cfg.txt" > "%WORK%\gw.txt" 2>nul
for /f "usebackq tokens=2 delims=:" %%g in ("%WORK%\gw.txt") do set "GWTMP=%%g"
if defined GWTMP for /f "tokens=* delims= " %%g in ("!GWTMP!") do set "GW=%%g"
exit /b

:done
echo.
rd /s /q "%WORK%" >nul 2>&1
pause
exit /b

:fail
echo.
rd /s /q "%WORK%" >nul 2>&1
pause
exit /b
