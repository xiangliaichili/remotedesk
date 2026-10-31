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

# 环境自愈（PATHEXT / 工具链缓存目录）与 Step、Info、Good、Bad 都在 _common 里
$common = Join-Path $PSScriptRoot "_common.ps1"
if (Test-Path $common) { . $common }
$distDir = Join-Path $root "dist\server"
$smokeDir = Join-Path $root "dist\smoke"

Step "定位 Go"
$go = Find-Go $root $GoBin
if (-not $go) {
    Bad "未找到 go。请安装 Go 1.22+，或用 -GoBin 指定路径。"
    exit 1
}
Info "$go"
$goVer = & $go version 2>&1
Info "$goVer"

New-Item -ItemType Directory -Force -Path $distDir, $smokeDir | Out-Null

# ---------- 编译 ----------
# 冒烟必须重新编一次，否则测到的是上一次的二进制
$exe = Join-Path $distDir "remotedesk-server-windows-amd64.exe"
Build-Server -Root $root -Go $go -OutFile $exe -Version (Get-SrcVersion $root) -Force | Out-Null

Step "启动临时服务器（端口 $Port）"
$env:RD_LISTEN = ":$Port"
$env:RD_DB = Join-Path $smokeDir "smoke.db"
$env:RD_JWT_SECRET = "smoke-" + ([guid]::NewGuid().ToString("N"))
$env:RD_TURN_LISTEN = ":" + ($Port + 1000)
$env:RD_PUBLIC = "https://localhost:$Port"
# e2e 的第 12 组会验证「手机验证码 / 微信扫码」，这些开关必须和它对齐，
# 否则会以为脚本坏了（其实是服务端没开对应能力）。
$env:RD_SMS_PROVIDER = "mock"
$env:RD_SMS_DEV = "1"
$env:RD_WECHAT_APP_ID = "wxtest"
$env:RD_WECHAT_APP_SECRET = "secret"
$env:RD_AUTH_DEV = "1"
Remove-Item $env:RD_DB -ErrorAction SilentlyContinue

$outLog = Join-Path $smokeDir "server.out.log"
$errLog = Join-Path $smokeDir "server.err.log"
$proc = $null
try {
    $proc = Start-Process -FilePath $exe -WorkingDirectory $smokeDir -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog
}
catch {
    Info "改用 .NET 启动（$($_.Exception.Message)）"
    # 这里不能用 quickstart 那套 WMI（Win32_Process.Create）：它不继承当前进程的环境变量，
    # 上面设的 RD_* 会全部丢失。UseShellExecute 会继承，正是我们需要的。
    # 工作目录也要固定到 smokeDir，否则服务器会在仓库根读到 server/.env（quickstart 生成的），
    # 把端口和库路径换成别人那套，冒烟结果就不可信了。
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.WorkingDirectory = $smokeDir
    $psi.UseShellExecute = $true
    $psi.WindowStyle = 'Hidden'
    $proc = [System.Diagnostics.Process]::Start($psi)
}

try {
    $ready = Wait-Health -Port $Port -Times 30 -IntervalMs 300 -Proc $proc
    if (-not $ready) {
        Bad "服务器未能启动，日志："
        # -Encoding UTF8：Go 写的是 UTF-8，按默认的 ANSI 读会变成乱码
        Get-Content $outLog, $errLog -Encoding UTF8 -ErrorAction SilentlyContinue |
            ForEach-Object { "    $_" }
        exit 1
    }
    Good "/healthz -> ok"

    Step "运行端到端用例"
    $node = Find-Node
    if (-not $node) {
        Bad "未找到 node（跑 e2e 需要 Node 18+）。装一个再来：https://nodejs.org"
        exit 1
    }
    Info "$node"

    Push-Location $root
    try {
        & $node (Join-Path $root "scripts\e2e-test.mjs") "http://127.0.0.1:$Port"
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