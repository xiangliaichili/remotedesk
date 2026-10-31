# 把构建产物整理进 dist/（发布包）
#
# 用法（仓库根目录）：
#   powershell -ExecutionPolicy Bypass -File scripts\package-dist.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\package-dist.ps1 -Version 1.2.0
#   powershell -ExecutionPolicy Bypass -File scripts\package-dist.ps1 -Force      # 跳过"产物比源码旧"的检查
#
# 做的事：
#   1. 把 windows / android 的产物按 remotedesk-<版本>-<平台>-<arch> 归位到 dist/
#   2. 服务端二进制（dist/server/remotedesk-server-*）保持原样，只在缺失时提示
#   3. 复制 server/.env.example，让服务端目录可直接跑
#   4. 写 dist/VERSION（产物版本 + 源码版本 + 构建时间）
#   5. 重算 dist/SHA256SUMS.txt（相对路径，cd dist 后可直接 sha256sum -c）
#
# 设计原则：宁可提示"产物可能过期"，也不要把旧二进制标成新版本。
param(
    [string]$Version = "",
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

# 环境自愈（PATHEXT / 工具链缓存目录）与 Step、Info、Good、Warn、Bad 都在 _common 里
$common = Join-Path $PSScriptRoot "_common.ps1"
if (Test-Path $common) { . $common }
$dist = Join-Path $root "dist"

if (-not $Version) {
    $Version = Read-JsonVersion (Join-Path $root "windows\package.json")
    if (-not $Version) { $Version = "0.0.0" }
}
Info "打包版本：$Version"

# ---------- 目录 ----------
foreach ($d in @("", "windows", "android", "server")) {
    $p = if ($d) { Join-Path $dist $d } else { $dist }
    New-Item -ItemType Directory -Force -Path $p | Out-Null
}

$copied = @()
$missing = @()

# ---------- Windows ----------
# dist 里只放**安装包**（双击出安装向导），不放裸 exe：
#   - NSIS setup.exe：普通用户双击安装（开始菜单 + 卸载器）
#   - MSI：企业/批量部署用
# 裸 exe（便携版）只在 target\release\remotedesk.exe，不进 dist。
Step "整理 Windows 产物"
$bundleDir = Join-Path $root "windows\src-tauri\target\release\bundle"
$nsisExe = Get-ChildItem (Join-Path $bundleDir "nsis") -Filter "*-setup.exe" -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
$msiFile = Get-ChildItem (Join-Path $bundleDir "msi") -Filter "*.msi" -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1

if (-not $nsisExe -and -not $msiFile) {
    $missing += "windows/src-tauri/target/release/bundle/nsis/*-setup.exe"
    Warn "未找到 Windows 安装包（先跑 scripts\build-windows.ps1，注意不要加 -SkipBundle）"
} else {
    $refFile = if ($nsisExe) { $nsisExe } else { $msiFile }
    $exeTime = $refFile.LastWriteTime
    $newer = Get-ChildItem (Join-Path $root "windows\src"), (Join-Path $root "windows\src-tauri\src") -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -gt $exeTime } | Select-Object -First 3
    if ($newer -and -not $Force) {
        Warn "安装包早于这些源码改动，可能不是最新构建："
        $newer | ForEach-Object { Write-Host "        $($_.FullName)" -ForegroundColor DarkYellow }
        Warn "先执行 scripts\build-windows.ps1，或加 -Force 强制打包"
    }
}

if ($nsisExe) {
    $winDst = Join-Path $dist "windows\remotedesk-$Version-windows-x64-setup.exe"
    Copy-Item $nsisExe.FullName $winDst -Force
    $copied += $winDst
    Good ("windows/{0}  ({1} MB)" -f (Split-Path $winDst -Leaf), [math]::Round((Get-Item $winDst).Length / 1MB, 1))
}
if ($msiFile) {
    $winDst = Join-Path $dist "windows\remotedesk-$Version-windows-x64.msi"
    Copy-Item $msiFile.FullName $winDst -Force
    $copied += $winDst
    Good ("windows/{0}  ({1} MB)" -f (Split-Path $winDst -Leaf), [math]::Round((Get-Item $winDst).Length / 1MB, 1))
}

# 清理旧版打包方式遗留的裸 exe（点开直接跑、不安装的那个）
Get-ChildItem (Join-Path $dist "windows") -Filter "remotedesk-*-windows-x64.exe" -File -ErrorAction SilentlyContinue |
    ForEach-Object {
        Remove-Item $_.FullName -Force
        Info "已移除旧便携版 $($_.Name)（改为发布安装包）"
    }

# ---------- Android ----------
Step "整理 Android 产物"
$apkSrc = Join-Path $root "android\app\build\outputs\apk\debug\app-debug.apk"
$apkDst = Join-Path $dist "android\remotedesk-$Version-debug.apk"
if (Test-Path $apkSrc) {
    $apkTime = (Get-Item $apkSrc).LastWriteTime
    $newer = Get-ChildItem (Join-Path $root "android\app\src") -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -gt $apkTime } | Select-Object -First 3
    if ($newer -and -not $Force) {
        Warn "app-debug.apk 早于这些源码改动，可能不是最新构建："
        $newer | ForEach-Object { Write-Host "        $($_.FullName)" -ForegroundColor DarkYellow }
        Warn "先执行 scripts\build-android.ps1，或加 -Force 强制打包"
    }
    Copy-Item $apkSrc $apkDst -Force
    $copied += $apkDst
    Good ("android/{0}  ({1} MB)" -f (Split-Path $apkDst -Leaf), [math]::Round((Get-Item $apkDst).Length / 1MB, 1))
} else {
    $missing += "android/app/build/outputs/apk/debug/app-debug.apk"
    Warn "未找到 Android 产物（先跑 scripts\build-android.ps1）"
}

# ---------- 服务端 ----------
Step "检查服务端产物"
$srv = Get-ChildItem (Join-Path $dist "server") -Filter "remotedesk-server-*" -File -ErrorAction SilentlyContinue
if ($srv) {
    foreach ($f in $srv) {
        $copied += $f.FullName
        Good ("server/{0}  ({1} MB)" -f $f.Name, [math]::Round($f.Length / 1MB, 1))
    }
} else {
    $missing += "dist/server/remotedesk-server-*"
    Warn "未找到服务端二进制（跑 scripts/build-server.sh，或把已有产物放进 dist/server）"
}

# 让服务端目录自足
$envExample = Join-Path $root "server\.env.example"
if (Test-Path $envExample) {
    Copy-Item $envExample (Join-Path $dist "server\.env.example") -Force
    Info "已复制 server/.env.example"
}

# ---------- VERSION ----------
Step "写 VERSION"
$buildDate = (Get-Date).ToString("yyyy-MM-dd HH:mm")
$srcVersion = Read-JsonVersion (Join-Path $root "windows\package.json")
$verText = @(
    "# 发布包版本信息（由 scripts/package-dist.ps1 生成）",
    "",
    "SERVER_VERSION=$Version",
    "CLIENT_VERSION=$Version",
    "HARMONY_VERSION=$Version（源码；需 DevEco Studio 编译，dist 内不含 hap）",
    "SOURCE_VERSION=$srcVersion",
    "PACKAGED_AT=$buildDate",
    "",
    "# SERVER_VERSION：server/ 下四个平台的服务端二进制",
    "# CLIENT_VERSION：windows/ 的 EXE 与 android/ 的 APK",
    "# SOURCE_VERSION：打包时源码树的版本（windows/package.json）",
    "# 三者不一致说明源码已更新但未重新构建，请先构建再打包。"
) -join "`n"
[System.IO.File]::WriteAllText((Join-Path $dist "VERSION"), $verText + "`n", (New-Object System.Text.UTF8Encoding($true)))
Good "dist/VERSION"

# ---------- 校验和 ----------
Step "重算 SHA256SUMS.txt"
# 运行时目录（dist\quickstart 里放着 quickstart 起的库与 pid、dist\smoke 放着冒烟
# 临时库与日志）不是发布内容，别算进清单，否则别人拿到 dist 会看到一堆临时文件。
# 另外清掉 `xxx~` 这类编辑器/工具留下的备份文件。
$files = Get-ChildItem $dist -Recurse -File |
    Where-Object {
        $_.Name -ne "SHA256SUMS.txt" -and
        $_.Name -notlike "*~" -and
        $_.FullName -notlike "*\quickstart\*" -and
        $_.FullName -notlike "*\smoke\*" -and
        # server\data 是有人在 dist\server 目录直接跑二进制留下的运行时库
        $_.FullName -notlike "*\server\data\*"
    } |
    Sort-Object FullName

$stale = Get-ChildItem $dist -Recurse -File -Filter "*~" -ErrorAction SilentlyContinue
foreach ($f in $stale) {
    Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
    Info ("清掉残留备份 " + $f.Name)
}

$lines = New-Object System.Collections.Generic.List[string]
foreach ($f in $files) {
    $rel = $f.FullName.Substring($dist.Length + 1) -replace '\\', '/'
    $hash = (Get-FileHash $f.FullName -Algorithm SHA256).Hash.ToLower()
    $lines.Add("$hash  $rel")
}
$sumPath = Join-Path $dist "SHA256SUMS.txt"
[System.IO.File]::WriteAllText($sumPath, ($lines -join "`n") + "`n", (New-Object System.Text.UTF8Encoding($false)))
Good ("SHA256SUMS.txt  {0} 个文件" -f $lines.Count)

# ---------- 汇总 ----------
Write-Host ""
Write-Host "==============================================================" -ForegroundColor Green
Write-Host " dist/ 已整理（版本 $Version）" -ForegroundColor Green
Write-Host "==============================================================" -ForegroundColor Green
Get-ChildItem $dist -Recurse -File |
    Where-Object {
        $_.Name -ne "SHA256SUMS.txt" -and
        $_.Name -notlike "*~" -and
        $_.FullName -notlike "*\quickstart\*" -and
        $_.FullName -notlike "*\smoke\*" -and
        # server\data 是有人在 dist\server 目录直接跑二进制留下的运行时库
        $_.FullName -notlike "*\server\data\*"
    } |
    Sort-Object FullName |
    ForEach-Object {
        $rel = $_.FullName.Substring($dist.Length + 1)
        Write-Host ("  {0,-56} {1,8:N1} MB" -f $rel, ($_.Length / 1MB))
    }

if ($missing.Count -gt 0) {
    Write-Host ""
    Warn "缺少这些产物（其余已打包）："
    $missing | ForEach-Object { Write-Host "        $_" -ForegroundColor DarkYellow }
    exit 0
}

Write-Host ""
Write-Host " 校验：" -ForegroundColor Gray
Write-Host "   cd dist && sha256sum -c SHA256SUMS.txt" -ForegroundColor Gray
Write-Host " 说明文档：dist/README.md（记得随包一起发）" -ForegroundColor Gray
