@echo off
rem ============================================================
rem  remotedesk 打包 dist 发布包（按版本命名 + 写 VERSION + 校验和）
rem  前置：先双击 build.cmd 构建过客户端，或 dist\server 里已有服务端二进制
rem ============================================================
setlocal
cd /d "%~dp0"

set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PSEXE%" set "PSEXE=powershell.exe"

echo ============================================================
echo   remotedesk  整理 dist 发布包
echo ============================================================
"%PSEXE%" -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%~dp0scripts\package-dist.ps1" %*
set "CODE=%ERRORLEVEL%"

echo.
if not "%CODE%"=="0" (
  echo [失败] 退出码 %CODE%
) else (
  echo [完成] 见 dist\README.md
)
echo.
pause
exit /b %CODE%
