# 本地冒烟测试：编译服务器 → 起临时实例 → 跑端到端用例 → 关停
# 用法：
#   powershell -ExecutionPolicy Bypass -File scripts\smoke.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\smoke.ps1 -Port 19000
#
# 前置：Go 1.22+（或把 go 放进 PATH；也可用 -GoBin 指定）
param(
    [int]$Port = 18443,
    [string]$GoBin = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$serverDir = Join-Path $root "server"
$distDir = Join-Path $root "dist\server"
$smokeDir = Join-Path $root "dist\smoke"

function Step($msg) {
    Write-Host ""
    Write-Host "==> $msg" -ForegroundColor Cyan
}

Step "定位 Go"
$go = $null
if ($GoBin -and (Test-Path $GoBin)) {
    $go = $GoBin
} else {
    $g = Get-Command go -ErrorAction SilentlyContinue
    if ($g) { $go = $g.Source }
}
if (-not $go) {
    $tools = Join-Path (Split-Path -Parent $root) ".tools\go\bin\go.exe"
    if (Test-Path $tools) { $go = $tools } else { $tools = Join-Path $root ".tools\go\bin\go.exe"; if (Test-Path $tools) { $go = $tools } }
}
if (-not $go) {
    Write-Host "  [X] 未找到 go。请安装 Go 1.22+，或用 -GoBin 指定路径。" -ForegroundColor Red
    exit 1
}
Write-Host "    $go" -ForegroundColor DarkGray
& $go version

Step "编译服务器"
New-Item -ItemType Directory -Force -Path $distDir, $smokeDir | Out-Null
Push-Location $serverDir
try {
    & $go mod tidy 2>&1 | Out-Null
    $exe = Join-Path $distDir "remotedesk-server-windows-amd64.exe"
    & $go build -trimpath -ldflags "-s -w" -o $exe .
    if ($LASTEXITCODE -ne 0) { throw "编译失败" }
    Write-Host ("    产物 {0} ({1} MB)" -f $exe, [math]::Round((Get-Item $exe).Length / 1MB, 1)) -ForegroundColor Green
}
finally {
    Pop-Location
}

Step "启动临时服务器（端口 $Port）"
$env:RD_LISTEN = ":$Port"
$env:RD_DB = Join-Path $smokeDir "smoke.db"
$env:RD_JWT_SECRET = "smoke-" + ([guid]::NewGuid().ToString("N"))
$env:RD_TURN_LISTEN = ":" + ($Port + 1000)
$env:RD_PUBLIC = "https://localhost:$Port"
Remove-Item $env:RD_DB -ErrorAction SilentlyContinue

$proc = Start-Process -FilePath (Join-Path $distDir "remotedesk-server-windows-amd64.exe") `
    -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput (Join-Path $smokeDir "server.out.log") `
    -RedirectStandardError (Join-Path $smokeDir "server.err.log")

try {
    $ready = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 300
        try {
            $r = Invoke-WebRequest "http://127.0.0.1:$Port/healthz" -UseBasicParsing -TimeoutSec 2
            if ($r.StatusCode -eq 200) { $ready = $true; break }
        } catch { }
        if ($proc.HasExited) { break }
    }
    if (-not $ready) {
        Write-Host "  [X] 服务器未能启动，日志：" -ForegroundColor Red
        Get-Content (Join-Path $smokeDir "server.out.log"), (Join-Path $smokeDir "server.err.log") -ErrorAction SilentlyContinue | ForEach-Object { "    $_" }
        exit 1
    }
    Write-Host "    /healthz -> ok" -ForegroundColor Green

    Step "运行端到端用例"
    Push-Location $root
    try {
        & node (Join-Path $root "scripts\e2e-test.mjs") "http://127.0.0.1:$Port"
        $code = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    if ($code -ne 0) {
        Write-Host ""
        Write-Host "  端到端用例存在失败项" -ForegroundColor Red
        exit $code
    }
    Write-Host ""
    Write-Host "  冒烟测试全部通过" -ForegroundColor Green
}
finally {
    if ($proc -and -not $proc.HasExited) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        Write-Host "  已停止临时服务器 (pid=$($proc.Id))" -ForegroundColor DarkGray
    }
}