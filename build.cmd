@echo off
rem ============================================================
rem  remotedesk 环境体检 + 一键构建（Windows / Android / 服务器）
rem  双击即可运行；装好对应工具链的端才会构建，缺的会提示缺什么
rem ============================================================
setlocal
cd /d "%~dp0"

set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PSEXE%" set "PSEXE=powershell.exe"

echo ============================================================
echo   remotedesk  环境体检 ^& 构建
echo ============================================================
"%PSEXE%" -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%~dp0scripts\setup.ps1" %*
set "CODE=%ERRORLEVEL%"

echo.
if not "%CODE%"=="0" (
  echo [失败] 退出码 %CODE%
) else (
  echo [完成] 产物在 windows\src-tauri\target\release 与 android\app\build\outputs\apk
)
echo.
pause
exit /b %CODE%
