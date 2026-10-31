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

# 环境自愈（PATHEXT / 工具链缓存目录）与 Step、Info、Good、Bad 都在 _common 里
$common = Join-Path $PSScriptRoot "_common.ps1"
if (Test-Path $common) { . $common }
$serverDir = Join-Path $root "server"
$distDir = Join-Path $root "dist\server"
$dataDir = Join-Path $root "dist\quickstart"
$pidFile = Join-Path $dataDir "server.pid"

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

$ver = Get-SrcVersion $root

# ---------- 定位 Go ----------
Step "查找 Go 工具链"
$go = Find-Go $root $GoBin
if (-not $go) {
    Bad "未找到 go。装一个再来：https://go.dev/dl/（或用 -GoBin 指定路径）"
    exit 1
}
Info "$go"
$goVer = & $go version 2>&1
Info "$goVer"

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
        "RD_JWT_SECRET=$secret",
        "",
        "# ---------- 登录方式 ----------",
        "# 手机验证码：mock=不发真短信，验证码写进日志并在响应里回 dev_code（本机试用刚好）",
        "# 换真实短信：改成 aliyun，并填下面两行的 Key 与签名/模板",
        "RD_SMS_PROVIDER=mock",
        "RD_SMS_DEV=1",
        "#RD_SMS_SIGN=",
        "#RD_SMS_TEMPLATE=",
        "#RD_ALIYUN_KEY_ID=",
        "#RD_ALIYUN_KEY_SECRET=",
        "",
        "# 微信扫码登录：需要微信开放平台「网站应用」的 AppID/AppSecret，且回调域必须是备案域名，",
        "# 局域网 IP 用不了，所以默认关着。要用就取消下面三行注释并填真实值。",
        "#RD_WECHAT_APP_ID=",
        "#RD_WECHAT_APP_SECRET=",
        "#RD_WECHAT_REDIRECT=",
        "RD_AUTH_DEV=0"
    )
    # -Encoding utf8 在 PS 5.1 下会写 BOM，Go 读第一行会带上 \ufeff，这里显式写无 BOM 的 UTF-8
    [System.IO.File]::WriteAllLines($envPath, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
    Good "已写入 server/.env"
}

# 把 .env 读进当前进程
foreach ($line in Get-Content $envPath) {
    if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
    $kv = $line -split '=', 2
    Set-Item -Path ("Env:" + $kv[0].Trim()) -Value $kv[1].Trim()
}

# 端口优先级：命令行 -Port > .env 里的 RD_LISTEN > 默认 8443。
# 不这样对齐的话，.env 里写的端口会盖掉 -Port，健康检查就会等到超时。
if ($PSBoundParameters.ContainsKey('Port')) {
    $env:RD_LISTEN = ":$Port"
    $env:RD_PUBLIC = "http://${ip}:$Port"
    # 同步回 .env：兜底启动方式（WMI）不会继承本进程环境变量，只能靠文件
    if (Test-Path $envPath) {
        $text = [System.IO.File]::ReadAllText($envPath)
        $text = [regex]::Replace($text, '(?m)^RD_LISTEN=.*$', "RD_LISTEN=:$Port")
        $text = [regex]::Replace($text, '(?m)^RD_PUBLIC=.*$', "RD_PUBLIC=http://${ip}:$Port")
        [System.IO.File]::WriteAllText($envPath, $text, (New-Object System.Text.UTF8Encoding($false)))
        Info "已把端口 $Port 同步进 server/.env"
    }
} elseif ($env:RD_LISTEN -match ':(\d+)\s*$') {
    $Port = [int]$Matches[1]
    Info "端口取自 server/.env：$Port（要换用 -Port 指定）"
}

# ---------- 编译 ----------
$exe = Join-Path $distDir "remotedesk-server-windows-amd64.exe"
Build-Server -Root $root -Go $go -OutFile $exe -Version $ver -Force:$Force | Out-Null

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
# 优先 Start-Process（能把 stdout/stderr 落到日志）。但环境里同时存在
# HTTP_PROXY 与 http_proxy（代理软件很常见）时它会抛「已添加项。字典中的关键字...」，
# 此时退回 WMI：子进程脱离控制台（关窗口也带不走服务），代价是不重定向日志——
# 配置是从 server/.env 读的，不依赖环境变量继承。
$serverPid = 0
$noLog = $false
try {
    $serverPid = (Start-Process -FilePath $exe -WorkingDirectory $serverDir -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog).Id
}
catch {
    Info "Start-Process 不可用（$($_.Exception.Message)）"
    Info "改用后台方式启动（脱离窗口，本次不写日志文件）"
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine      = '"' + $exe + '"'
        CurrentDirectory = $serverDir
    }
    if (-not $r -or $r.ReturnValue -ne 0) {
        Bad "后台启动失败（Win32_Process 返回 $($r.ReturnValue)）"
        exit 1
    }
    $serverPid = [int]$r.ProcessId
    $noLog = $true
}
Set-Content -Path $pidFile -Value $serverPid -Encoding utf8

$ready = Wait-Health -Port $Port -Times 40 -IntervalMs 250 -ProcId $serverPid
if (-not $ready) {
    if ($noLog) {
        Bad "服务器没起来（本次没有日志文件，可手动在 server 目录执行二进制看输出）"
        Bad "常见原因：端口 $Port 被占用、.env 里 RD_LISTEN 写错、防火墙/杀软拦截"
    } else {
        Bad "服务器没起来，日志："
        Get-Content $outLog, $errLog -ErrorAction SilentlyContinue | Select-Object -Last 20 | ForEach-Object { "      $_" }
    }
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    exit 1
}
Good "/healthz -> ok (pid=$serverPid)"

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
if ($noLog) {
    Write-Host " 日志：    未落盘（本次用了后台兜底启动），要日志可手动在 server 目录跑一次二进制" -ForegroundColor Gray
} else {
    Write-Host " 日志：    $outLog" -ForegroundColor Gray
}
Write-Host " 停止：    双击 stop.cmd（或 start.cmd -Stop）" -ForegroundColor Gray
Write-Host ""
Write-Host " 下一步：登录/注册同一个账号 → 两台设备互相可见 → 点「连接」" -ForegroundColor White
Write-Host ""
