# =============================================================================
#  RemoteDesk · HarmonyOS 客户端打包脚本
# -----------------------------------------------------------------------------
#  作用：用 DevEco Studio 自带的 hvigor + SDK 在命令行构建 .hap
#  前置：安装 DevEco Studio 5.0+（含 HarmonyOS SDK API 12）与 Node 18+
#
#  用法：
#    .\scripts\build-harmony.ps1                  # 构建 debug HAP
#    .\scripts\build-harmony.ps1 -Release         # 构建 release HAP（需签名配置）
#    .\scripts\build-harmony.ps1 -DevEcoHome "D:\DevEco Studio"
#    .\scripts\build-harmony.ps1 -SkipInstall     # 跳过 ohpm install
#
#  产物：harmony\entry\build\default\outputs\default\entry-default-signed.hap
#        （debug 为 entry-default-unsigned.hap）
# =============================================================================

[CmdletBinding()]
param(
    [switch]$Release,
    [switch]$SkipInstall,
    [string]$DevEcoHome = "",
    [string]$NodeHome  = ""
)

$ErrorActionPreference = "Stop"

$Root    = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Harmony = Join-Path $Root "harmony"

function Info($m) { Write-Host "[harmony] $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "[harmony] $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "[harmony] 错误：$m" -ForegroundColor Red; exit 1 }

if (-not (Test-Path $Harmony)) { Die "找不到 harmony 工程目录：$Harmony" }

# ----------------------------------------------------------------------------
# 1. 定位 DevEco Studio
# ----------------------------------------------------------------------------
$candidates = @(
    $DevEcoHome,
    "C:\Program Files\Huawei\DevEco Studio",
    "D:\Program Files\Huawei\DevEco Studio",
    "C:\Program Files\Huawei\DevEco Studio 5.0",
    "$env:LOCALAPPDATA\Huawei\DevEco Studio"
) | Where-Object { $_ -and (Test-Path $_) }

if (-not $candidates) {
    Die @"
未找到 DevEco Studio。请先安装后再运行：
  下载：https://developer.huawei.com/consumer/cn/deveco-studio/
  或用参数指定：.\scripts\build-harmony.ps1 -DevEcoHome "你的安装路径"

也可以直接在 DevEco Studio 里打开 harmony 目录，点 Build > Build Hap(s)。
"@
}

$DevEco = $candidates[0]
Info "DevEco Studio: $DevEco"

$HvigorW  = Join-Path $DevEco "tools\hvigor\bin\hvigorw.bat"
$NodeExe  = Join-Path $DevEco "tools\node\node.exe"
$Ohpm     = Join-Path $DevEco "tools\ohpm\bin\ohpm.bat"

if (-not (Test-Path $HvigorW)) {
    # 新版 DevEco 把 hvigor 放在 tools\hvigor\bin，旧版在 tools\hvigorw.bat
    $alt = Join-Path $DevEco "tools\hvigorw.bat"
    if (Test-Path $alt) { $HvigorW = $alt } else { Die "找不到 hvigorw.bat，路径：$HvigorW" }
}
Info "hvigor: $HvigorW"

# ----------------------------------------------------------------------------
# 2. 环境变量（hvigor 依赖 node 与 SDK）
# ----------------------------------------------------------------------------
if ($NodeHome) {
    $env:PATH = "$NodeHome;$env:PATH"
} elseif (Test-Path $NodeExe) {
    $env:PATH = "$(Split-Path $NodeExe);$env:PATH"
    Info "node: $(Split-Path $NodeExe)"
}

$sdkCandidates = @(
    (Join-Path $DevEco "sdk"),
    "$env:LOCALAPPDATA\Huawei\Sdk",
    "C:\Program Files\Huawei\HarmonyOS\Sdk"
) | Where-Object { Test-Path $_ }

if ($sdkCandidates) {
    $env:DEVECO_SDK_HOME = $sdkCandidates[0]
    Info "SDK: $($sdkCandidates[0])"
} else {
    Warn "未自动定位 HarmonyOS SDK，若构建报 SDK 缺失请在 DevEco 里配置后重试"
}

$env:NODE_OPTIONS = "--max-old-space-size=4096"

Push-Location $Harmony
try {
    # ------------------------------------------------------------------------
    # 3. 依赖安装
    # ------------------------------------------------------------------------
    if (-not $SkipInstall) {
        if (Test-Path $Ohpm) {
            Info "ohpm install ..."
            & cmd /c "`"$Ohpm`" install"
            if ($LASTEXITCODE -ne 0) { Warn "ohpm install 退出码 $LASTEXITCODE，继续尝试构建" }
        } else {
            Warn "未找到 ohpm，跳过依赖安装"
        }
    }

    # ------------------------------------------------------------------------
    # 4. 构建
    # ------------------------------------------------------------------------
    $module = if ($Release) { "entry@default -p product=default -p buildMode=release" } else { "entry@default -p product=default -p buildMode=debug" }
    $args   = "--mode module -p module=$module -p debuggable=$(if($Release){'false'}else{'true'})"

    Info "hvigor assembleHap ($($(if($Release){'release'}else{'debug'}))) ..."
    & cmd /c "`"$HvigorW`" $args assembleHap --no-daemon"
    $code = $LASTEXITCODE

    if ($code -ne 0) {
        Die @"
构建失败（退出码 $code）。常见原因：
  1. 未配置签名      → DevEco: File > Project Structure > Signing Configs > 勾选 Automatically generate signature
  2. SDK API 版本不符 → 工程要求 compatibleSdkVersion 5.0.0(12)
  3. 首次构建要联网下载 hvigor 依赖（hvigor-ohos-plugin 5.0.2）
"@
    }

    # ------------------------------------------------------------------------
    # 5. 收集产物
    # ------------------------------------------------------------------------
    $outDirs = @(
        (Join-Path $Harmony "entry\build\default\outputs\default"),
        (Join-Path $Harmony "entry\build\default\outputs")
    ) | Where-Object { Test-Path $_ }

    $haps = @()
    foreach ($d in $outDirs) { $haps += Get-ChildItem -Path $d -Filter "*.hap" -File -ErrorAction SilentlyContinue }
    $haps = $haps | Sort-Object FullName -Unique

    if (-not $haps) {
        Warn "构建成功但没找到 .hap，请到 harmony\entry\build\ 下自行查找"
        exit 0
    }

    $distDir = Join-Path $Root "dist\harmony"
    New-Item -ItemType Directory -Force -Path $distDir | Out-Null

    Write-Host ""
    Info "构建成功，产物："
    foreach ($h in $haps) {
        $tag  = if ($Release) { "release" } else { "debug" }
        $dest = Join-Path $distDir ("remotedesk-0.1.0-harmony-$tag.hap")
        Copy-Item $h.FullName $dest -Force
        $size = [math]::Round($h.Length / 1MB, 2)
        Write-Host ("  {0}  ({1} MB)" -f $dest, $size) -ForegroundColor Green
    }

    Write-Host ""
    Info "安装到鸿蒙设备（需已开启开发者模式与 USB 调试）："
    Write-Host "  hdc install `"$distDir\remotedesk-0.1.0-harmony-debug.hap`""
}
finally {
    Pop-Location
}
