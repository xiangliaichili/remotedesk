@echo off
rem ============================================================
rem  remotedesk 停止本机服务器（start.cmd 启动的那个）
rem ============================================================
setlocal
cd /d "%~dp0"

set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PSEXE%" set "PSEXE=powershell.exe"

echo ============================================================
echo   remotedesk  停止本机服务器
echo ============================================================
"%PSEXE%" -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%~dp0scripts\quickstart.ps1" -Stop
set "CODE=%ERRORLEVEL%"

echo.
pause
exit /b %CODE%
