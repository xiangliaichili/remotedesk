# Windows 客户端构建脚本（Tauri v2）
# 用法：
#   powershell -ExecutionPolicy Bypass -File scripts\build-windows.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\build-windows.ps1 -SkipBundle    # 只出裸 exe，跳过 NSIS/MSI
#
# 前置：
#   - Node.js 18+
#   - Rust（rustup，MSVC 工具链）：https://rustup.rs
#   - Visual Studio Build Tools（勾选“使用 C++ 的桌面开发”）
param(
    [switch]$SkipBundle,
    [string]$Target = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

# 环境自愈（PATHEXT / 工具链缓存目录）与 Step、Info、Good、Warn、Bad 都在 _common 里
$common = Join-Path $PSScriptRoot "_common.ps1"
if (Test-Path $common) { . $common }
$dir = Join-Path $root "windows"

function Fail($msg) {
    Write-Host ""
    Write-Host "  [X] $msg" -ForegroundColor Red
    exit 1
}


Step "检查构建环境"
foreach ($c in @("node", "npm", "cargo")) {
    $exe = Get-Command $c -ErrorAction SilentlyContinue
    if (-not $exe) {
        Fail "未找到 $c。请先安装：node -> https://nodejs.org ；cargo -> https://rustup.rs"
    }
    Write-Host ("    {0,-6} {1}" -f $c, $exe.Source) -ForegroundColor DarkGray
}
Write-Host ("    node   {0}" -f (& node --version))
Write-Host ("    cargo  {0}" -f (& cargo --version))

Step "安装前端依赖"
Push-Location $dir
try {
    if (Test-Path "package-lock.json") {
        & npm ci --no-audit --no-fund
    } else {
        & npm install --no-audit --no-fund
    }
    if ($LASTEXITCODE -ne 0) { Fail "npm 依赖安装失败" }

    Step "编译 Tauri 应用"
    $args = @("run", "tauri", "--", "build")
    if ($SkipBundle) { $args += "--no-bundle" }
    if ($Target) { $args += @("--target", $Target) }
    & npm @args
    if ($LASTEXITCODE -ne 0) { Fail "Tauri 构建失败（常见原因：缺少 MSVC 工具链，或 xcap/enigo 版本 API 变动，见 README 常见问题）" }

    Step "构建产物"
    $rel = Join-Path $dir "src-tauri\target\release"
    $exe = Join-Path $rel "remotedesk.exe"
    if (Test-Path $exe) {
        $size = [math]::Round((Get-Item $exe).Length / 1MB, 1)
        Write-Host ("    EXE  {0}  ({1} MB)" -f $exe, $size) -ForegroundColor Green
    }
    if (-not $SkipBundle) {
        $bundle = Join-Path $rel "bundle"
        if (Test-Path $bundle) {
            Get-ChildItem $bundle -Recurse -File -Include *.exe, *.msi |
                ForEach-Object { Write-Host ("    安装包  {0}" -f $_.FullName) -ForegroundColor Green }
        }
    }
    Write-Host ""
    Write-Host "完成。首次运行请在登录页填入服务器地址（如 https://desk.example.com）。" -ForegroundColor Green
}
finally {
    Pop-Location
}