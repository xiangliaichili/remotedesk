# remotedesk 环境体检 + 一键构建
#
# 用法（在仓库根目录执行，任何一步失败都会给出具体修法）：
#   powershell -ExecutionPolicy Bypass -File scripts\setup.ps1                 # 只体检
#   powershell -ExecutionPolicy Bypass -File scripts\setup.ps1 -Target windows # 体检 + 构建 Windows 客户端
#   powershell -ExecutionPolicy Bypass -File scripts\setup.ps1 -Target all     # 全量构建（有哪个工具就编哪个）
#   powershell -ExecutionPolicy Bypass -File scripts\setup.ps1 -Target windows -SkipInstall
#
# 设计原则：
#   · 只体检不联网装东西（除了 npm install），避免卡在下载上；
#   · 缺工具时明确告诉你缺什么、去哪装，而不是抛一堆红字；
#   · 多目标构建时，某个端缺工具只跳过该端，不影响其它端。
param(
    [ValidateSet("check", "server", "windows", "android", "harmony", "all")]
    [string]$Target = "check",
    [switch]$SkipInstall
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

function Step($msg) {
    Write-Host ""
    Write-Host "==> $msg" -ForegroundColor Cyan
}
function Row($name, $ok, $detail) {
    $mark = if ($ok) { "OK " } else { "-- " }
    $color = if ($ok) { "Green" } else { "DarkGray" }
    Write-Host ("  [{0}] {1,-10} {2}" -f $mark, $name, $detail) -ForegroundColor $color
}

function Find-Tool($name, $extraPaths) {
    $c = Get-Command $name -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in $extraPaths) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    return $null
}

# ---------- 体检 ----------
Step "环境体检"
$tools = @{}

$tools.node = Find-Tool "node" @()
$tools.npm = Find-Tool "npm" @()
$tools.cargo = Find-Tool "cargo" @(
    (Join-Path $root ".tools\cargo\bin\cargo.exe"),
    (Join-Path $env:USERPROFILE ".cargo\bin\cargo.exe")
)
$tools.go = Find-Tool "go" @(
    (Join-Path $root ".tools\go\bin\go.exe"),
    (Join-Path (Split-Path -Parent $root) ".tools\go\bin\go.exe")
)
# JDK：优先找真正的 JDK 根目录（不要被 Oracle 的 javapath 转发器坑到）
function Resolve-JavaHome {
    $patterns = @("Microsoft\jdk-*", "Eclipse Adoptium\jdk-*", "Zulu\zulu-*", "Java\jdk-17*", "Java\jdk-21*")
    foreach ($pat in $patterns) {
        $hit = Get-ChildItem (Join-Path $env:ProgramFiles $pat) -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
        if ($hit -and (Test-Path (Join-Path $hit.FullName "bin\java.exe"))) { return $hit.FullName }
    }
    if ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME "bin\java.exe"))) { return $env:JAVA_HOME }
    $c = Get-Command java -ErrorAction SilentlyContinue
    if ($c) {
        # 只有形如 <jdk>\bin\java.exe 才算 JDK 根目录；javapath 这类转发器要排除
        $home = Split-Path -Parent (Split-Path -Parent $c.Source)
        if ((Split-Path -Leaf (Split-Path -Parent $c.Source)) -eq "bin" -and
            (Test-Path (Join-Path $home "bin\java.exe"))) { return $home }
    }
    return $null
}
$tools.javaHome = Resolve-JavaHome
$tools.java = if ($tools.javaHome) { Join-Path $tools.javaHome "bin\java.exe" } else { Find-Tool "java" @() }
$tools.gradle = Find-Tool "gradle" @(
    (Join-Path $root ".tools\gradle-home\gradle-8.9\bin\gradle.bat"),
    (Join-Path $env:USERPROFILE ".gradle\wrapper\dists\gradle-8.9-bin\*\gradle-8.9\bin\gradle.bat")
)
$tools.adb = Find-Tool "adb" @(
    (Join-Path $env:LOCALAPPDATA "Android\Sdk\platform-tools\adb.exe")
)

# 把工具位置回填成标准环境变量，后面的构建脚本直接复用
if ($tools.javaHome) { $env:JAVA_HOME = $tools.javaHome }
elseif ($tools.java) { $env:JAVA_HOME = Split-Path -Parent (Split-Path -Parent $tools.java) }
$env:ANDROID_HOME = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { Join-Path $env:LOCALAPPDATA "Android\Sdk" }
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
if ($tools.cargo) {
    $cargoHome = Split-Path -Parent (Split-Path -Parent $tools.cargo)
    if (Test-Path (Join-Path $cargoHome "..\rustup")) {
        $env:CARGO_HOME = $cargoHome
        $env:RUSTUP_HOME = (Resolve-Path (Join-Path $cargoHome "..\rustup")).Path
    }
}

function Ver($path, [string]$flag) {
    if (-not $path) { return "未找到" }
    # java -version 输出在 stderr，且全局 ErrorActionPreference=Stop 会把它当异常，
    # 这里局部放宽，保证能读到版本号。
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & $path $flag 2>&1 | Select-Object -First 1
        if (-not $out) { return "$path  (已安装)" }
        return "$path  ($out)"
    }
    catch { return $path }
    finally { $ErrorActionPreference = $prevEap }
}

Row "node" ([bool]$tools.node) (Ver $tools.node "--version")
Row "npm" ([bool]$tools.npm) (Ver $tools.npm "--version")
Row "cargo" ([bool]$tools.cargo) (Ver $tools.cargo "--version")
Row "go" ([bool]$tools.go) (Ver $tools.go "version")
Row "java" ([bool]$tools.java) (Ver $tools.java "-version")
Row "gradle" ([bool]$tools.gradle) (Ver $tools.gradle "--version")
Row "adb" ([bool]$tools.adb) (Ver $tools.adb "version")

Write-Host ""
Write-Host "  装什么看这里：" -ForegroundColor Gray
Write-Host "    node    https://nodejs.org            （Windows 客户端前端 + 测试脚本）" -ForegroundColor Gray
Write-Host "    cargo   https://rustup.rs             （Windows 客户端外壳，需 VS Build Tools C++）" -ForegroundColor Gray
Write-Host "    go      https://go.dev/dl/            （服务器）" -ForegroundColor Gray
Write-Host "    java    https://adoptium.net          （Android，JDK 17）" -ForegroundColor Gray
Write-Host "    gradle  https://gradle.org/releases    （Android 8.9；也可放到 .tools\gradle-home）" -ForegroundColor Gray
Write-Host "    adb     随 Android SDK platform-tools 安装（真机调试用）" -ForegroundColor Gray

if ($Target -eq "check") {
    Write-Host ""
    Write-Host "体检完成。构建某一端：" -ForegroundColor Cyan
    Write-Host "  scripts\setup.ps1 -Target windows|android|harmony|server|all" -ForegroundColor Cyan
    Write-Host "只想在本机跑起来给别人连？  scripts\quickstart.ps1" -ForegroundColor Cyan
    exit 0
}

# ---------- 公共依赖 ----------
Step "安装前端依赖"
if ($SkipInstall) {
    Write-Host "  已跳过（-SkipInstall）" -ForegroundColor DarkGray
} elseif ($tools.npm) {
    $winDir = Join-Path $root "windows"
    Push-Location $winDir
    try {
        if (Test-Path (Join-Path $winDir "node_modules")) {
            Write-Host "  node_modules 已存在，跳过 npm install（要重装请手动删目录）" -ForegroundColor DarkGray
        } else {
            & $tools.npm install
            if ($LASTEXITCODE -ne 0) { throw "npm install 失败" }
        }
    }
    finally {
        Pop-Location
    }
} else {
    Write-Host "  未找到 npm，跳过" -ForegroundColor DarkGray
}

# ---------- 按目标构建 ----------
$results = @()

function Invoke-Build($name, $scriptPath, $need, $hint) {
    $missing = @()
    foreach ($t in $need) {
        if (-not $tools[$t]) { $missing += $t }
    }
    if ($missing.Count -gt 0) {
        Write-Host ("  [跳过] {0}：缺少 {1}。{2}" -f $name, ($missing -join ", "), $hint) -ForegroundColor Yellow
        $script:results += [pscustomobject]@{ Name = $name; Ok = $false; Note = "缺少 " + ($missing -join ", ") }
        return
    }
    Step "构建 $name"
    & powershell -ExecutionPolicy Bypass -File $scriptPath
    $code = $LASTEXITCODE
    $ok = ($code -eq 0)
    $script:results += [pscustomobject]@{ Name = $name; Ok = $ok; Note = if ($ok) { "成功" } else { "失败，见上方日志" } }
}

$targets = if ($Target -eq "all") { @("server", "windows", "android", "harmony") } else { @($Target) }

foreach ($t in $targets) {
    switch ($t) {
        "server" {
            Invoke-Build "服务器" (Join-Path $root "scripts\build-server.sh") @("go") "装 Go 即可"
        }
        "windows" {
            Invoke-Build "Windows 客户端" (Join-Path $root "scripts\build-windows.ps1") @("node", "cargo") "需要 node + cargo + VS Build Tools"
        }
        "android" {
            Invoke-Build "Android 客户端" (Join-Path $root "scripts\build-android.ps1") @("java", "gradle") "需要 JDK 17 + Android SDK + Gradle 8.9"
        }
        "harmony" {
            Invoke-Build "HarmonyOS 客户端" (Join-Path $root "scripts\build-harmony.ps1") @() "需要 DevEco Studio（脚本会自动找）"
        }
    }
}

Write-Host ""
Write-Host "==> 结果" -ForegroundColor Cyan
$results | ForEach-Object {
    $mark = if ($_.Ok) { "OK " } else { "-- " }
    $color = if ($_.Ok) { "Green" } else { "Yellow" }
    Write-Host ("  [{0}] {1,-18} {2}" -f $mark, $_.Name, $_.Note) -ForegroundColor $color
}

Write-Host ""
Write-Host "  产物位置：" -ForegroundColor Gray
Write-Host "    dist\server\remotedesk-server-*         服务器" -ForegroundColor Gray
Write-Host "    windows\src-tauri\target\release\remotedesk.exe" -ForegroundColor Gray
Write-Host "    android\app\build\outputs\apk\debug\app-debug.apk" -ForegroundColor Gray
Write-Host "    dist\harmony\*.hap" -ForegroundColor Gray
