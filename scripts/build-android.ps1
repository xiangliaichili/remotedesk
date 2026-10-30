# Android 客户端构建脚本（无需打开 Android Studio）
# 用法：
#   powershell -ExecutionPolicy Bypass -File scripts\build-android.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\build-android.ps1 -Release   # 出 release APK
#
# 前置：
#   - JDK 17（AGP 8.x 要求 17，18/21 亦可但推荐 17）
#   - Android SDK：Platform 34 + Build-Tools 34.0.0
#   - Gradle 8.9（脚本会在找不到时提示；也可用 Android Studio 自带的 gradle）
#
# 可用环境变量覆盖：JAVA_HOME / ANDROID_HOME / GRADLE_BIN
param(
    [switch]$Release,
    [string]$Task = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$dir = Join-Path $root "android"

function Fail($msg) {
    Write-Host ""
    Write-Host "  [X] $msg" -ForegroundColor Red
    exit 1
}

function Step($msg) {
    Write-Host ""
    Write-Host "==> $msg" -ForegroundColor Cyan
}

Step "定位 JDK"
if (-not $env:JAVA_HOME -or -not (Test-Path (Join-Path $env:JAVA_HOME "bin\java.exe"))) {
    $candidates = @(
        "D:\Java\jdk-17",
        "C:\Program Files\Java\jdk-17",
        "C:\Program Files\Microsoft\jdk-17.0.10.7-hotspot",
        "C:\Program Files\Android\Android Studio\jbr",
        "$env:LOCALAPPDATA\Programs\Android Studio\jbr"
    )
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c "bin\java.exe")) { $env:JAVA_HOME = $c; break }
    }
}
if (-not $env:JAVA_HOME) {
    Fail "未找到 JDK 17。请安装后设置 JAVA_HOME，例如：`$env:JAVA_HOME='D:\Java\jdk-17'"
}
Write-Host "    JAVA_HOME = $env:JAVA_HOME" -ForegroundColor DarkGray
$env:PATH = "$env:JAVA_HOME\bin;$env:PATH"
Write-Host ("    java      {0}" -f ((& "$env:JAVA_HOME\bin\java.exe" -version 2>&1) | Select-Object -First 1))

Step "定位 Android SDK"
if (-not $env:ANDROID_HOME -or -not (Test-Path $env:ANDROID_HOME)) {
    foreach ($c in @("$env:LOCALAPPDATA\Android\Sdk", "C:\Android\Sdk", "$env:USERPROFILE\Android\Sdk")) {
        if (Test-Path $c) { $env:ANDROID_HOME = $c; break }
    }
}
if (-not $env:ANDROID_HOME) {
    Fail "未找到 Android SDK。请安装 Android Studio 或在 local.properties 里写 sdk.dir"
}
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
Write-Host "    ANDROID_HOME = $env:ANDROID_HOME" -ForegroundColor DarkGray

$platforms = Join-Path $env:ANDROID_HOME "platforms\android-34"
$buildTools = Join-Path $env:ANDROID_HOME "build-tools\34.0.0"
if (-not (Test-Path $platforms)) { Write-Host "    [!] 缺少 platforms\android-34，请在 SDK Manager 里安装" -ForegroundColor Yellow }
if (-not (Test-Path $buildTools)) { Write-Host "    [!] 缺少 build-tools\34.0.0，请在 SDK Manager 里安装" -ForegroundColor Yellow }

Step "写入 local.properties"
$localProps = Join-Path $dir "local.properties"
$sdkEscaped = $env:ANDROID_HOME.Replace("\", "\\").Replace(":", "\:")
Set-Content -Path $localProps -Encoding UTF8 -Value @(
    "## 由 scripts/build-android.ps1 自动生成",
    "sdk.dir=$sdkEscaped"
)
Write-Host "    $localProps" -ForegroundColor DarkGray

Step "定位 Gradle"
$gradle = $null
if ($env:GRADLE_BIN -and (Test-Path $env:GRADLE_BIN)) {
    $gradle = $env:GRADLE_BIN
} elseif (Test-Path (Join-Path $dir "gradlew.bat")) {
    $gradle = Join-Path $dir "gradlew.bat"
} else {
    $tools = Join-Path (Split-Path -Parent $root) ".tools"
    foreach ($c in @((Join-Path $tools "gradle-8.9\bin\gradle.bat"), (Join-Path $tools "gradle\bin\gradle.bat"))) {
        if (Test-Path $c) { $gradle = $c; break }
    }
    if (-not $gradle) {
        $g = Get-Command gradle -ErrorAction SilentlyContinue
        if ($g) { $gradle = $g.Source }
    }
}
if (-not $gradle) {
    Fail @"
未找到 Gradle。三选一：
  1) 用 Android Studio 打开 android 目录（最简单）
  2) 安装 Gradle 8.9 并加入 PATH
  3) 下载解压到 <workspace>\.tools\gradle-8.9，脚本会自动发现
"@
}
Write-Host "    $gradle" -ForegroundColor DarkGray

$taskName = $Task
if (-not $taskName) { $taskName = if ($Release) { "assembleRelease" } else { "assembleDebug" } }

Step "执行 gradle $taskName"
Push-Location $dir
try {
    & $gradle $taskName --no-daemon --console=plain
    if ($LASTEXITCODE -ne 0) { Fail "Gradle 构建失败，请查看上面的报错" }
}
finally {
    Pop-Location
}

Step "构建产物"
$apkDir = Join-Path $dir "app\build\outputs\apk"
if (Test-Path $apkDir) {
    Get-ChildItem $apkDir -Recurse -File -Filter *.apk | ForEach-Object {
        $size = [math]::Round($_.Length / 1MB, 1)
        Write-Host ("    APK  {0}  ({1} MB)" -f $_.FullName, $size) -ForegroundColor Green
    }
    Write-Host ""
    Write-Host "安装到手机：adb install -r <上面的 apk>" -ForegroundColor Green
    Write-Host "被控端记得在 系统设置 → 无障碍 → RemoteDesk 里开启服务。" -ForegroundColor Yellow
} else {
    Write-Host "    未找到 APK 输出目录：$apkDir" -ForegroundColor Yellow
}