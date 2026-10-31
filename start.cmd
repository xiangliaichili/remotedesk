@echo off
rem ============================================================
rem  remotedesk 一键启动（本机 / 内网服务器）
rem  双击即可运行；也可在命令行调用：start.cmd -Port 9443
rem  停止：start.cmd -Stop
rem ============================================================
setlocal
cd /d "%~dp0"

set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PSEXE%" set "PSEXE=powershell.exe"

echo ============================================================
echo   remotedesk  启动本机服务器
echo ============================================================
"%PSEXE%" -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%~dp0scripts\quickstart.ps1" %*
set "CODE=%ERRORLEVEL%"

echo.
if not "%CODE%"=="0" (
  echo [失败] 退出码 %CODE% ，把上面的报错发出来即可定位。
) else (
  echo [完成] 服务器已在后台运行。停止请双击 stop.cmd，或执行 start.cmd -Stop
)
echo.
pause
exit /b %CODE%
