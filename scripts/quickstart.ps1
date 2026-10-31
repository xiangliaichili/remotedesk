# 一条命令在本机/内网起 remotedesk 服务器
#
# 用法（在仓库根目录执行）：
#   powershell -ExecutionPolicy Bypass -File scripts\quickstart.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\quickstart.ps1 -Port 9443
#   powershell -ExecutionPolicy Bypass -File scripts\quickstart.ps1 -Stop        # 停掉上次启动的实例
#
# 它会做四件事：
#   1. 生成 server/.env（随机 JWT 密钥、自动探测内网 IP）
#   2. 编译 Go 服务器（有缓存则跳过）
#   3. 后台启动并做 /healthz 健康检查
#   4. 打印「客户端该填的服务器地址」——Windows 客户端直接复制粘贴即可
#
# 前置：Go 1.22+（https://go.dev/dl/）。没有 Go 时脚本会提示，不会静默失败。
param(
    [int]$Port = 8443,
    [string]$GoBin = "",
    [switch]$Stop,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$serverDir = Join-Path $root "server"
$distDir = Join-Path $root "dist\server"
$dataDir = Join-Path $root "dist\quickstart"
$pidFile = Join-Path $dataDir "server.pid"

function Step($msg) {
    Write-Host ""
    Write-Host "==> $msg" -ForegroundColor Cyan
}
function Info($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }
function Good($msg) { Write-Host "    $msg" -ForegroundColor Green }
function Bad($msg) { Write-Host "  [X] $msg" -ForegroundColor Red }

# ---------- 停止 ----------
if ($Stop) {
    if (Test-Path $pidFile) {
        $old = (Get-Content $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($old) {
            $p = Get-Process -Id ([int]$old) -ErrorAction SilentlyContinue
            if ($p) {
                Stop-Process -Id $p.Id -Force
                Good "已停止服务器 (pid=$($p.Id))"
            } else {
                Info "进程 $old 已不存在"
            }
        }
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    } else {
        Info "没有找到 quickstart 启动的实例（$pidFile）"
    }
    exit 0
}

New-Item -ItemType Directory -Force -Path $distDir, $dataDir | Out-Null

# ---------- 定位 Go ----------
Step "查找 Go 工具链"
$go = $null
if ($GoBin -and (Test-Path $GoBin)) {
    $go = $GoBin
} else {
    $g = Get-Command go -ErrorAction SilentlyContinue
    if ($g) { $go = $g.Source }
}
if (-not $go) {
    foreach ($cand in @((Join-Path $root ".tools\go\bin\go.exe"), (Join-Path (Split-Path -Parent $root) ".tools\go\bin\go.exe"))) {
        if (Test-Path $cand) { $go = $cand; break }
    }
}
if (-not $go) {
    Bad "未找到 go。装一个再来：https://go.dev/dl/（或用 -GoBin 指定路径）"
    exit 1
}
Info "$go"
& $go version | ForEach-Object { Info $_ }

# ---------- 内网 IP ----------
Step "准备配置"
$ip = $null
try {
    $ip = (Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" -and $_.PrefixOrigin -ne "WellKnown" } |
        Sort-Object -Property InterfaceMetric -ErrorAction SilentlyContinue |
        Select-Object -First 1).IPAddress
} catch { }
if (-not $ip) {
    try {
        $ip = [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
            Where-Object { $_.AddressFamily -eq "InterNetwork" -and -not $_.IPAddressToString.StartsWith("127.") } |
            Select-Object -First 1 |
            ForEach-Object { $_.IPAddressToString }
    } catch { }
}
if (-not $ip) { $ip = "127.0.0.1" }
Info "内网 IP：$ip"

$envPath = Join-Path $serverDir ".env"
if ((Test-Path $envPath) -and -not $Force) {
    Info "沿用已有 server/.env（想重写加 -Force）"
} else {
    $secret = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 48 | ForEach-Object { [char]$_ })
    $lines = @(
        "# 由 scripts/quickstart.ps1 生成，可直接改",
        "RD_LISTEN=:$Port",
        "RD_PUBLIC=http://${ip}:$Port",
        "RD_TURN_LISTEN=:3478",
        "RD_TURN_RELAY_IP=$ip",
        "RD_DB=$((Join-Path $dataDir 'remotedesk.db') -replace '\\','/')",
        "RD_JWT_SECRET=$secret"
    )
    Set-Content -Path $envPath -Value $lines -Encoding utf8
    Good "已写入 server/.env"
}

# 把 .env 读进当前进程
foreach ($line in Get-Content $envPath) {
    if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
    $kv = $line -split '=', 2
    Set-Item -Path ("Env:" + $kv[0].Trim()) -Value $kv[1].Trim()
}

# ---------- 编译 ----------
$exe = Join-Path $distDir "remotedesk-server-windows-amd64.exe"
$needBuild = $true
if ((Test-Path $exe) -and -not $Force) {
    $exeTime = (Get-Item $exe).LastWriteTime
    $newer = Get-ChildItem $serverDir -Recurse -Include *.go -File | Where-Object { $_.LastWriteTime -gt $exeTime }
    if (-not $newer) { $needBuild = $false }
}
if ($needBuild) {
    Step "编译服务器"
    Push-Location $serverDir
    try {
        & $go mod tidy 2>&1 | Out-Null
        & $go build -trimpath -ldflags "-s -w" -o $exe .
        if ($LASTEXITCODE -ne 0) { throw "go build 失败" }
        Good ("产物 {0}（{1} MB）" -f $exe, [math]::Round((Get-Item $exe).Length / 1MB, 1))
    }
    finally {
        Pop-Location
    }
} else {
    Step "复用已有二进制"
    Info $exe
}

# ---------- 启动 ----------
Step "启动服务器（端口 $Port）"
if (Test-Path $pidFile) {
    $old = Get-Content $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($old -and (Get-Process -Id ([int]$old) -ErrorAction SilentlyContinue)) {
        Bad "已有实例在跑 (pid=$old)，先执行 -Stop 或换个端口"
        exit 1
    }
}

$outLog = Join-Path $dataDir "server.out.log"
$errLog = Join-Path $dataDir "server.err.log"
$proc = Start-Process -FilePath $exe -WorkingDirectory $serverDir -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $outLog -RedirectStandardError $errLog
Set-Content -Path $pidFile -Value $proc.Id -Encoding utf8

$ready = $false
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    if ($proc.HasExited) { break }
    try {
        $r = Invoke-WebRequest "http://127.0.0.1:$Port/healthz" -UseBasicParsing -TimeoutSec 2
        if ($r.StatusCode -eq 200) { $ready = $true; break }
    } catch { }
}
if (-not $ready) {
    Bad "服务器没起来，日志："
    Get-Content $outLog, $errLog -ErrorAction SilentlyContinue | Select-Object -Last 20 | ForEach-Object { "      $_" }
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    exit 1
}
Good "/healthz -> ok (pid=$($proc.Id))"

$lan = "http://${ip}:$Port"
$loop = "http://127.0.0.1:$Port"

Write-Host ""
Write-Host "==============================================================" -ForegroundColor Green
Write-Host " 本机服务器已就绪" -ForegroundColor Green
Write-Host "==============================================================" -ForegroundColor Green
Write-Host ""
Write-Host " 客户端「服务器地址」填：" -ForegroundColor White
Write-Host "   本机使用      $loop" -ForegroundColor Yellow
Write-Host "   同一 WiFi 的设备  $lan" -ForegroundColor Yellow
Write-Host ""
Write-Host " 手机能连上但无画面时，检查 Windows 防火墙是否放行：" -ForegroundColor Gray
Write-Host "   TCP $Port（信令/API）、UDP+TCP 3478（TURN 中继）" -ForegroundColor Gray
Write-Host ""
Write-Host " 数据目录：$dataDir" -ForegroundColor Gray
Write-Host " 日志：    $outLog" -ForegroundColor Gray
Write-Host " 停止：    powershell -ExecutionPolicy Bypass -File scripts\quickstart.ps1 -Stop" -ForegroundColor Gray
Write-Host ""
Write-Host " 下一步：登录/注册同一个账号 → 两台设备互相可见 → 点「连接」" -ForegroundColor White
Write-Host ""
