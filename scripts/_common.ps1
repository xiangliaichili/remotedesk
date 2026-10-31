# scripts/_common.ps1 —— 各脚本共用的环境自愈与通用工具，用 . 引入（dot-source）
#
#   $common = Join-Path $PSScriptRoot "_common.ps1"
#   if (Test-Path $common) { . $common }

# ---------- 输出 ----------
function Step($msg) { Write-Host ""; Write-Host "==> $msg" -ForegroundColor Cyan }
function Info($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }
function Good($msg) { Write-Host "    $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  [!] $msg" -ForegroundColor Yellow }
function Bad($msg) { Write-Host "  [X] $msg" -ForegroundColor Red }

# ---------- 工具定位 ----------
function Find-Tool($name, $extraPaths) {
    $c = Get-Command $name -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in $extraPaths) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    return $null
}

# Go：PATH 里没有就退到仓库内（或上级目录）的 .tools\go
function Find-Go([string]$Root, [string]$GoBin) {
    if ($GoBin -and (Test-Path $GoBin)) { return $GoBin }
    return Find-Tool "go" @(
        (Join-Path $Root ".tools\go\bin\go.exe"),
        (Join-Path (Split-Path -Parent $Root) ".tools\go\bin\go.exe")
    )
}

# Node：PATH 里没有就退到常见安装位置。
# 逐项判空再 Join-Path —— 精简环境里 ProgramFiles(x86) 之类可能不存在，
# 直接拼会抛 "Cannot bind argument to parameter 'Path'"。
function Find-Node {
    $cands = @()
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if ($base) { $cands += (Join-Path $base "nodejs\node.exe") }
    }
    return Find-Tool "node" $cands
}

# ---------- 环境自愈 ----------
# PATHEXT 缺 .EXE 时 .exe 会被当成「文档」而不是可执行程序，后果很隐蔽：
# 输出全捕获不到、$LASTEXITCODE 永远为空（脚本会报「退出码 」）、
# 一接管道就抛 CantActivateDocumentInPipeline。常见于精简 CI / 计划任务 / 沙箱。
function Repair-PathExt {
    $parts = @()
    if ($env:PATHEXT) {
        $parts = @($env:PATHEXT -split ';' | Where-Object { $_ } | ForEach-Object { $_.Trim() })
    }
    $has = $false
    foreach ($p in $parts) {
        if ($p.TrimStart('.').ToUpperInvariant() -eq 'EXE') { $has = $true; break }
    }
    if (-not $has) {
        foreach ($e in @('.COM', '.EXE', '.BAT', '.CMD', '.VBS', '.JS', '.WSF', '.WSH', '.MSC', '.CPL')) {
            if ($parts -notcontains $e) { $parts += $e }
        }
        $env:PATHEXT = ($parts -join ';')
    }
}

# 受限账户下 %TEMP% 可能不可写：MSVC 链接器会报 LNK1104 无法打开 ...\Temp\lnk{...}.tmp，
# go 也会建不了临时目录。先探测可写性，不行就切到仓库内的 .tools\tmp。
function Repair-TempDir {
    param([string]$Root)

    if (-not $Root) { return }
    $fallback = Join-Path $Root ".tools\tmp"
    if (-not (Test-Path $fallback)) {
        New-Item -ItemType Directory -Path $fallback -Force -ErrorAction SilentlyContinue | Out-Null
    }
    if (-not (Test-Path $fallback)) { return }

    $usable = $false
    if ($env:TEMP) {
        try {
            $probe = Join-Path $env:TEMP ("rd-probe-" + [guid]::NewGuid().ToString("N") + ".tmp")
            [System.IO.File]::WriteAllText($probe, "x")
            Remove-Item $probe -Force -ErrorAction SilentlyContinue
            $usable = $true
        } catch { $usable = $false }
    }
    if (-not $usable) {
        $env:TMP = $fallback
        $env:TEMP = $fallback
    }
}

# Go 默认把模块缓存放 ~/go、构建缓存放 %LOCALAPPDATA%，受限账户下常不可写：
#   go: could not create module cache: mkdir C:\Users\xxx\go: Access is denied.
function Set-GoEnv {
    param([string]$Root)

    if (-not $Root) { return }
    $tools = Join-Path $Root ".tools"
    foreach ($d in @("gopath", "gocache", "gotmp", "tmp")) {
        $p = Join-Path $tools $d
        if (-not (Test-Path $p)) {
            New-Item -ItemType Directory -Path $p -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }
    $env:GOPATH = Join-Path $tools "gopath"
    $env:GOCACHE = Join-Path $tools "gocache"
    $env:GOTMPDIR = Join-Path $tools "gotmp"
    if (-not $env:GOPROXY) { $env:GOPROXY = "https://goproxy.cn,direct" }
    if (-not $env:GOSUMDB) { $env:GOSUMDB = "off" }
}

# rustup / cargo 同理默认住在 ~/.rustup 与 ~/.cargo，受限账户下会报
#   error: could not create home directory: 'C:\Users\xxx\.rustup': 拒绝访问。(os error 5)
function Set-RustEnv {
    param([string]$Root)

    if (-not $Root) { return }
    $tools = Join-Path $Root ".tools"
    $rustup = Join-Path $tools "rustup"
    $cargo = Join-Path $tools "cargo"
    foreach ($p in @($rustup, $cargo)) {
        if (-not (Test-Path $p)) {
            New-Item -ItemType Directory -Path $p -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }
    if (-not $env:RUSTUP_HOME) { $env:RUSTUP_HOME = $rustup }
    if (-not $env:CARGO_HOME) { $env:CARGO_HOME = $cargo }
    $cargoBin = Join-Path $cargo "bin"
    if ((Test-Path $cargoBin) -and ($env:PATH -notlike "*$cargoBin*")) {
        $env:PATH = $cargoBin + ";" + $env:PATH
    }
}

# ---------- 版本 ----------
# 从 package.json 取 version。不用 ConvertFrom-Json：PS 5.1 下 -Raw 按 ANSI 读，
# 中文包名会乱掉导致解析失败。
function Read-JsonVersion($path) {
    if (-not (Test-Path $path)) { return "" }
    try {
        $txt = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        if ($txt -match '"version"\s*:\s*"([^"]+)"') { return $Matches[1] }
    } catch { }
    return ""
}

# 构建时要注入的版本号：优先 windows/package.json（与 dist/VERSION 同源），
# 拿不到就 dev。不注入的话 /version 会返回 "dev"，排查时对不上是哪个构建。
function Get-SrcVersion {
    param([string]$Root)

    if (-not $Root) { return "dev" }
    $v = Read-JsonVersion (Join-Path $Root "windows\package.json")
    if ($v) { return $v }

    $vf = Join-Path $Root "dist\VERSION"
    if (Test-Path $vf) {
        $hit = Select-String -Path $vf -Pattern '^SERVER_VERSION=([0-9][^\s]*)' |
            Select-Object -First 1 -ErrorAction SilentlyContinue
        if ($hit) { return $hit.Matches[0].Groups[1].Value }
    }
    return "dev"
}

# ---------- 构建 ----------
# 编译 Go 服务器。产物比源码新、且没给 -Force 时直接复用。
function Build-Server {
    param(
        [string]$Root,
        [string]$Go,
        [string]$OutFile,
        [string]$Version,
        [switch]$Force
    )

    $serverDir = Join-Path $Root "server"
    Set-GoEnv $Root
    Repair-TempDir $Root

    $skip = $false
    if ((Test-Path $OutFile) -and -not $Force) {
        $exeTime = (Get-Item $OutFile).LastWriteTime
        $newer = Get-ChildItem $serverDir -Recurse -Include *.go -File |
            Where-Object { $_.LastWriteTime -gt $exeTime }
        $skip = -not $newer
    }
    if ($skip) {
        Step "复用已有二进制"
        Info $OutFile
        return $OutFile
    }

    Step "编译服务器"
    Push-Location $serverDir
    # 外部命令写进 stderr 的内容（go 的 "go: downloading ..."）在 EAP=Stop 下会被当成
    # NativeCommandError 直接中断脚本，这里局部放宽，成败只看 $LASTEXITCODE。
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        # mod tidy 只用于对齐 go.mod，断网失败不该拦住构建（依赖已在本地缓存就直接编）
        $tidy = & $Go mod tidy 2>&1
        if ($LASTEXITCODE -ne 0) {
            $msg = (($tidy | Select-Object -First 2) -join " ").Trim()
            if (-not $msg) { $msg = "退出码 $LASTEXITCODE" }
            Info "go mod tidy 跳过（$msg）——依赖若已缓存不影响下面的构建"
        }
        $build = & $Go build -trimpath -ldflags "-s -w -X main.version=$Version" -o $OutFile . 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $OutFile)) {
            $ErrorActionPreference = $prevEap
            ($build | Select-Object -First 8) | ForEach-Object { "      $_" }
            throw "go build 失败（退出码 $LASTEXITCODE）"
        }
        $ErrorActionPreference = $prevEap
        Good ("产物 {0}（{1} MB）" -f $OutFile, [math]::Round((Get-Item $OutFile).Length / 1MB, 1))
    }
    finally {
        $ErrorActionPreference = $prevEap
        Pop-Location
    }
    return $OutFile
}

# 轮询 /healthz 直到 200。
# 传 -ProcId（只有 pid）或 -Proc（有进程对象）时，进程一退出就提前放弃。
function Wait-Health {
    param([int]$Port, [int]$Times, [int]$IntervalMs, [int]$ProcId = 0, $Proc = $null)

    for ($i = 0; $i -lt $Times; $i++) {
        Start-Sleep -Milliseconds $IntervalMs
        if ($Proc -and $Proc.HasExited) { return $false }
        if ($ProcId -gt 0 -and -not (Get-Process -Id $ProcId -ErrorAction SilentlyContinue)) { return $false }
        try {
            $r = Invoke-WebRequest "http://127.0.0.1:$Port/healthz" -UseBasicParsing -TimeoutSec 2
            if ($r.StatusCode -eq 200) { return $true }
        } catch { }
    }
    return $false
}

# 关掉进度条，否则健康检查那几行会被「正在读取 Web 响应…(读取的字节数: 0)」冲掉
$ProgressPreference = "SilentlyContinue"

Repair-PathExt
