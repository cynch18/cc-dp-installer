# Install Node.js 18+ and Git + Claude Code PowerShell Script
#Requires -Version 5.1

$ErrorActionPreference = "Stop"

# ============================================================
# 自动获取管理员权限
# ============================================================
function Test-IsAdmin {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal   = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host "  🔒 此脚本需要管理员权限，正在自动提权..." -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host ""

    # 构建参数：保留当前脚本路径和所有传入参数
    $argList = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`""
    )
    if ($args.Count -gt 0) {
        $argList += $args
    }

    # 以管理员身份重新启动 PowerShell 并等待完成
    $process = Start-Process PowerShell -Verb RunAs -ArgumentList $argList -Wait -PassThru

    # ═══════════════════════════════════════════════════════════════
    # 子进程已完成。从临时文件加载环境变量到当前会话（自动，无需手动操作）
    # ═══════════════════════════════════════════════════════════════
    $envTempFile = Join-Path $env:TEMP "claude-code-env.ps1"
    if (Test-Path $envTempFile) {
        . $envTempFile
        Remove-Item $envTempFile -Force -ErrorAction SilentlyContinue
    }

    # 刷新 PATH（子进程可能安装了 Node.js / Git）
    try {
        $mPath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
        $uPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
        $env:Path = ($mPath, $uPath | Where-Object { $_ } ) -join ";"
    } catch {}

    # ── 快速状态摘要 ──
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "   🎉 安装完成！" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    $nVer = try { & node -v 2>$null } catch { $null }
    $cVer = try { & claude --version 2>$null } catch { $null }
    $gVer = try { & git --version 2>$null } catch { $null }
    $dsUrl = [System.Environment]::GetEnvironmentVariable("ANTHROPIC_BASE_URL", "User")
    if ($nVer)  { Write-Host "  ✅ Node.js  : $nVer" -ForegroundColor Green } else { Write-Host "  ❌ Node.js  : 未检测到 (需重启终端)" -ForegroundColor Red }
    if ($cVer)  { Write-Host "  ✅ Claude   : $cVer" -ForegroundColor Green } else { Write-Host "  ❌ Claude   : 未检测到 (需重启终端)" -ForegroundColor Red }
    if ($gVer)  { Write-Host "  ✅ Git      : $gVer" -ForegroundColor Green } else { Write-Host "  ❌ Git      : 未检测到 (需重启终端)" -ForegroundColor Red }
    if ($dsUrl) { Write-Host "  ✅ DeepSeek : 已配置 → $dsUrl" -ForegroundColor Green } else { Write-Host "  ⚠️  DeepSeek : 未配置 (重新运行脚本并输入 Y)" -ForegroundColor Yellow }
    Write-Host ""
    Write-Host "  项目目录: $([Environment]::GetFolderPath("Desktop"))\my-project" -ForegroundColor Gray
    Write-Host "  cd '$([Environment]::GetFolderPath("Desktop"))\my-project'" -ForegroundColor White
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
    Read-Host "按 Enter 键退出..."

    exit $process.ExitCode
}

Write-Host "=== 管理员权限已确认 ===" -ForegroundColor Green
Write-Host ""

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "   Claude Code + DeepSeek 一键安装" -ForegroundColor Cyan
Write-Host "   作者: cynch18" -ForegroundColor Gray
Write-Host "   版本: 1.0" -ForegroundColor Gray
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================
# 架构检测 — 32位PowerShell在64位OS上会导致 "%1 不是有效的 Win32 应用程序" 错误
# ============================================================
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host "  ⚠️  检测到当前运行在 32 位 PowerShell 中（64 位 OS）" -ForegroundColor Red
    Write-Host "  这会导致 npm/cmd 调用出现 '%1 不是有效的 Win32 应用程序' 错误" -ForegroundColor Red
    Write-Host "  正在尝试以 64 位 PowerShell 重新启动..." -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host ""

    # 构建参数，使用 64 位 PowerShell 路径重新启动
    $argList = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`""
    )
    if ($args.Count -gt 0) {
        $argList += $args
    }

    $process = Start-Process -FilePath "$env:SystemRoot\SysNative\WindowsPowerShell\v1.0\powershell.exe" `
        -Verb RunAs -ArgumentList $argList -Wait -PassThru
    exit $process.ExitCode
}

Write-Host "  架构: $(if ([Environment]::Is64BitProcess) { '64-bit' } else { '32-bit' }) PowerShell" -ForegroundColor Gray

# 设置 PowerShell 执行策略（避免脚本执行被阻止）
try {
    Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
    Write-Host "  ExecutionPolicy: RemoteSigned (CurrentUser)" -ForegroundColor Gray
} catch {
    Write-Host "  ⚠ 无法设置 ExecutionPolicy: $_" -ForegroundColor DarkYellow
}
Write-Host ""

# ============================================================
# 错误日志 — 执行失败时自动生成到桌面
# ============================================================
$Script:LogPath   = $null
$Script:StartTime = Get-Date

function Write-ErrorLog {
    param([string]$Reason = "未知错误")

    # 只生成一次（避免多次 exit 重复写日志）
    if ($Script:LogPath) { return }

    $Script:LogPath = Join-Path ([Environment]::GetFolderPath("Desktop")) `
                              "install-log-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"

    $osInfo  = try { (Get-CimInstance Win32_OperatingSystem).Caption } catch { "N/A" }
    $lastErr = $Error[0..4] | ForEach-Object { "  $_" } | Out-String

    $log = @"
============================================================
  安装失败日志
============================================================
  时间         : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
  脚本         : install-nodejs.ps1
  失败原因     : $Reason
  PowerShell   : $($PSVersionTable.PSVersion)
  操作系统     : $osInfo
------------------------------------------------------------
  错误详情:
$lastErr
------------------------------------------------------------
  环境:
  计算机名     : $env:COMPUTERNAME
  用户名       : $env:USERNAME
  桌面路径     : $([Environment]::GetFolderPath("Desktop"))
============================================================
"@

    try {
        $log | Out-File -FilePath $Script:LogPath -Encoding UTF8 -Force
        Write-Host ""
        Write-Host "============================================================" -ForegroundColor Red
        Write-Host "  ❌ 安装失败，日志已保存到桌面:" -ForegroundColor Red
        Write-Host "     $Script:LogPath" -ForegroundColor Yellow
        Write-Host "============================================================" -ForegroundColor Red
    }
    catch {
        Write-Host "  ⚠ 无法写入日志文件: $_" -ForegroundColor DarkYellow
    }

    Write-Host ""
    Read-Host "按 Enter 键退出..."
}

# 全局捕获未预期的终止性错误
trap {
    Write-ErrorLog -Reason "脚本异常终止: $($_.Exception.Message)"
    exit 1
}

# ============================================================
# 通用下载函数 — 支持重试和多源镜像
# ============================================================
function Invoke-DownloadWithRetry {
    <#
    .SYNOPSIS
        带重试和多镜像源的下载函数
    .PARAMETER Urls
        下载 URL 列表（按优先级排列，第一个成功即停止）
    .PARAMETER OutFile
        保存到本地的文件路径
    .PARAMETER MaxRetries
        每个 URL 的最大重试次数（默认 3）
    .PARAMETER Description
        下载内容的描述（用于日志显示）
    #>
    param(
        [string[]]$Urls,
        [string]$OutFile,
        [int]$MaxRetries = 3,
        [string]$Description = ""
    )

    $label = if ($Description) { " ($Description)" } else { "" }
    $totalUrls = $Urls.Count

    for ($urlIdx = 0; $urlIdx -lt $totalUrls; $urlIdx++) {
        $url = $Urls[$urlIdx]
        $urlLabel = if ($totalUrls -gt 1) { " [源 $($urlIdx+1)/$totalUrls]" } else { "" }

        for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
            $attemptLabel = if ($MaxRetries -gt 1) { " (第 $attempt/$MaxRetries 次尝试)" } else { "" }
            Write-Host "  下载${label}${urlLabel}${attemptLabel}..." -ForegroundColor Gray

            try {
                # 使用 TLS 1.2，提高成功率（Tls13 在旧 .NET Framework 上不存在，用 try/catch 兜底）
                try {
                    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
                } catch {
                    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                }
                Invoke-WebRequest -Uri $url -OutFile $OutFile -UseBasicParsing `
                    -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" `
                    -TimeoutSec 120

                # 验证文件是否完整下载（> 1KB）
                if ((Test-Path $OutFile) -and ((Get-Item $OutFile).Length -gt 1024)) {
                    Write-Host "  ✓ 下载成功: $OutFile" -ForegroundColor Green
                    return $true
                }
                else {
                    Write-Host "  ⚠ 下载文件不完整，重试..." -ForegroundColor Yellow
                    Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
                }
            }
            catch {
                Write-Host "  ⚠ 下载失败: $_" -ForegroundColor DarkYellow
                Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
            }

            # 如果不是最后一次尝试，等待后重试
            if ($attempt -lt $MaxRetries -or $urlIdx -lt $totalUrls - 1) {
                $waitSeconds = 2 * $attempt
                Write-Host "  等待 ${waitSeconds}s 后重试..." -ForegroundColor Gray
                Start-Sleep -Seconds $waitSeconds
            }
        }
    }

    Write-Host "  ❌ 所有下载源均失败" -ForegroundColor Red
    return $false
}

# ============================================================
# 本地安装包查找函数 — 联网失败时自动回退到脚本目录中的安装包
# ============================================================
function Find-LocalInstaller {
    <#
    .SYNOPSIS
        在脚本所在目录查找本地安装包
    .PARAMETER Pattern
        文件名匹配模式，如 "node*.msi" 或 "Git*.exe"
    .PARAMETER Description
        描述文字（用于日志显示）
    .OUTPUTS
        返回找到的最新安装包的完整路径，未找到则返回 $null
    #>
    param(
        [string]$Pattern,
        [string]$Description = ""
    )

    $label = if ($Description) { " ($Description)" } else { "" }
    Write-Host "  🔍 正在脚本目录搜索本地安装包${label}..." -ForegroundColor Yellow
    Write-Host "     匹配模式: $Pattern" -ForegroundColor Gray

    # 获取脚本所在目录（兼容 PowerShell 2.0+）
    $scriptDir = $PSScriptRoot
    if (-not $scriptDir) {
        $scriptDir = Split-Path -Parent $PSCommandPath
    }

    Write-Host "     搜索目录: $scriptDir" -ForegroundColor Gray

    $candidates = Get-ChildItem -Path $scriptDir -Filter $Pattern -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending

    if ($candidates -and $candidates.Count -gt 0) {
        $best = $candidates[0]
        Write-Host "  📦 在脚本目录找到本地安装包: $($best.Name)" -ForegroundColor Green
        Write-Host "     完整路径: $($best.FullName)" -ForegroundColor Gray
        Write-Host "     文件大小: $([math]::Round($best.Length/1MB, 1)) MB" -ForegroundColor Gray
        Write-Host "     修改时间: $($best.LastWriteTime)" -ForegroundColor Gray
        if ($candidates.Count -gt 1) {
            Write-Host "     (共找到 $($candidates.Count) 个匹配文件，使用最新的)" -ForegroundColor Gray
        }
        return $best.FullName
    }

    Write-Host "  ⚠ 未在脚本目录找到匹配 '$Pattern' 的本地安装包" -ForegroundColor Yellow
    Write-Host "     (请将安装包放在脚本同目录下)" -ForegroundColor Gray
    return $null
}

# ============================================================
# npm 安装函数 — 支持镜像回退
# ============================================================
function Invoke-NpmInstallWithRetry {
    <#
    .SYNOPSIS
        带重试和镜像回退的 npm install -g 函数（内置异常保护）
    .PARAMETER Package
        要安装的包名
    .PARAMETER MaxRetries
        每个源的最大重试次数
    #>
    param(
        [string]$Package,
        [int]$MaxRetries = 3
    )

    # 临时关闭 Stop 模式，避免 npm 报错触发全局 trap
    $prevErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    try {
        # 先解析 npm 的完整路径（避免依赖 PATH 中的模糊匹配）
        $npmPath = $null
        try {
            $npmPath = (Get-Command npm -ErrorAction Stop).Source
        } catch {
            # 尝试常见安装位置
            $candidatePaths = @(
                "${env:ProgramFiles}\nodejs\npm.cmd",
                "${env:ProgramFiles}\nodejs\npm",
                "${env:APPDATA}\npm\npm.cmd",
                "${env:LOCALAPPDATA}\Programs\nodejs\npm.cmd"
            )
            foreach ($p in $candidatePaths) {
                if (Test-Path $p) { $npmPath = $p; break }
            }
        }
        if (-not $npmPath) { $npmPath = "npm" }  # 最后回退

        Write-Host "  npm 路径: $npmPath" -ForegroundColor Gray

        # npm 源列表：主源 + 国内镜像
        $registries = @(
            @{ Name = "npm 官方源"; Args = @("install", "-g") },
            @{ Name = "npmmirror 镜像"; Args = @("install", "-g", "--registry=https://registry.npmmirror.com") }
        )

        foreach ($reg in $registries) {
            for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
                $attemptLabel = if ($MaxRetries -gt 1) { " (第 $attempt/$MaxRetries 次尝试)" } else { "" }
                Write-Host "  npm install -g $Package (来源: $($reg.Name))${attemptLabel}..." -ForegroundColor Gray

                try {
                    # 参考成功案例：直接使用 & 调用 npm（PowerShell 原生支持 .cmd）
                    # Start-Process 不能直接执行 .cmd 文件，而 & 操作符可以
                    $fullArgs = $reg.Args + $Package
                    $prevExit = $LASTEXITCODE
                    & $npmPath @fullArgs 2>&1 | ForEach-Object {
                        # 实时输出 npm 的安装进度
                        $line = "$_"
                        if ($line -match "added|updated|removed|audited|found") {
                            Write-Host "    $line" -ForegroundColor Gray
                        }
                    }
                    $exitCode = $LASTEXITCODE
                    $LASTEXITCODE = $prevExit  # 恢复，避免污染外层判断

                    if ($exitCode -eq 0) {
                        Write-Host "  ✓ npm 安装成功 (来源: $($reg.Name))" -ForegroundColor Green
                        return $true
                    }

                    Write-Host "  ⚠ npm 安装失败 (exit: $exitCode)" -ForegroundColor DarkYellow
                }
                catch {
                    Write-Host "  ⚠ npm 执行异常: $_" -ForegroundColor DarkYellow
                }

                if ($attempt -lt $MaxRetries) {
                    $waitSeconds = 3 * $attempt
                    Write-Host "  等待 ${waitSeconds}s 后重试..." -ForegroundColor Gray
                    Start-Sleep -Seconds $waitSeconds
                }
            }
        }

        Write-Host "  ❌ 所有 npm 源均安装失败" -ForegroundColor Red
        return $false
    }
    finally {
        $ErrorActionPreference = $prevErrorAction
    }
}

Write-Host "=== Node.js 18+ & Git & Claude Code Installation Script ===" -ForegroundColor Cyan
Write-Host "   ✓ 已确认管理员权限" -ForegroundColor Green
Write-Host ""

# Function to compare version numbers
function Get-LatestNodeVersion {
    param([int]$MinMajor = 18)

    Write-Host "Fetching latest Node.js versions..." -ForegroundColor Yellow

    try {
        $releases = Invoke-RestMethod -Uri "https://nodejs.org/dist/index.json" -TimeoutSec 10
    }
    catch {
        Write-Host "Failed to fetch version list. Falling back to known LTS URL." -ForegroundColor Red
        return $null
    }

    # Filter for versions >= 18, prefer LTS, take the latest
    $filtered = $releases | Where-Object {
        [int]($_.version -replace '^v', '' -split '\.')[0] -ge $MinMajor
    }

    $lts = $filtered | Where-Object { $_.lts } | Select-Object -First 1
    if ($lts) {
        return $lts.version
    }

    $latest = $filtered | Select-Object -First 1
    return $latest.version
}

# ============================================================
# 全面检测电脑中是否存在 Node.js 18+
# ============================================================
function Test-NodeExists {
    <#
    .SYNOPSIS
        全面扫描电脑中所有 Node.js 安装，检测是否存在 18+ 版本
    .DESCRIPTION
        依次检查: PATH → 常见安装目录 → 注册表 → 包管理工具(nvm/fnm/volta)
    .OUTPUTS
        返回找到的 Node.js 信息对象数组
    #>

    $foundNodes = @()
    $checkedPaths = @()  # 防止重复检查同一个 exe

    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "   🔍 正在全面检测电脑中的 Node.js 安装情况..." -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""

    # ── 1. 检查当前 PATH 中的 node ──
    Write-Host "[1/5] 检查 PATH 环境变量中的 node..." -ForegroundColor Yellow
    $pathNode = Get-Command node -ErrorAction SilentlyContinue
    if ($pathNode) {
        try {
            $ver = & node -v 2>$null
            $fullPath = (Get-Command node).Source
            # npm 可能不存在于 PATH（边缘环境），独立获取避免拖垮整个检测
            $npmVer = $null
            try { $npmVer = & npm -v 2>$null } catch { }
            if ($fullPath -notin $checkedPaths) {
                $checkedPaths += $fullPath
                $foundNodes += [PSCustomObject]@{
                    Source   = "PATH"
                    Version  = $ver -replace '^v', ''
                    Path     = $fullPath
                    NpmVersion = $npmVer
                    Is18Plus = ([int](($ver -replace '^v', '') -split '\.')[0]) -ge 18
                }
            }
        } catch { Write-Host "  ⚠ 扫描跳过: $_" -ForegroundColor DarkGray }
    }

    # ── 2. 扫描常见安装目录 ──
    Write-Host "[2/5] 扫描常见安装目录..." -ForegroundColor Yellow
    $commonPaths = @(
        "${env:ProgramFiles}\nodejs",
        "${env:ProgramFiles(x86)}\nodejs",
        "${env:LOCALAPPDATA}\Programs\nodejs",
        "${env:APPDATA}\npm\node_modules\node\bin",
        "C:\nodejs",
        "D:\nodejs"
    )

    foreach ($basePath in $commonPaths) {
        $nodeExe = Join-Path $basePath "node.exe"
        if ((Test-Path $nodeExe) -and ($nodeExe -notin $checkedPaths)) {
            $checkedPaths += $nodeExe
            try {
                $ver = & $nodeExe -v 2>$null
                $foundNodes += [PSCustomObject]@{
                    Source   = "目录扫描 [$basePath]"
                    Version  = $ver -replace '^v', ''
                    Path     = $nodeExe
                    NpmVersion = $null
                    Is18Plus = ([int](($ver -replace '^v', '') -split '\.')[0]) -ge 18
                }
            } catch { Write-Host "  ⚠ 扫描跳过: $_" -ForegroundColor DarkGray }
        }
    }

    # ── 3. 检查注册表中的 Node.js 安装信息 ──
    Write-Host "[3/5] 检查 Windows 注册表..." -ForegroundColor Yellow
    $regPaths = @(
        "HKLM:\SOFTWARE\Node.js",
        "HKLM:\SOFTWARE\WOW6432Node\Node.js",
        "HKCU:\SOFTWARE\Node.js"
    )

    foreach ($regPath in $regPaths) {
        if (Test-Path $regPath) {
            try {
                $regProps = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
                $installPath = $regProps.InstallPath
                if ($installPath) {
                    $nodeExe = Join-Path $installPath "node.exe"
                    if ((Test-Path $nodeExe) -and ($nodeExe -notin $checkedPaths)) {
                        $checkedPaths += $nodeExe
                        $ver = & $nodeExe -v 2>$null
                        $foundNodes += [PSCustomObject]@{
                            Source   = "注册表 [$regPath]"
                            Version  = $ver -replace '^v', ''
                            Path     = $nodeExe
                            NpmVersion = $null
                            Is18Plus = ([int](($ver -replace '^v', '') -split '\.')[0]) -ge 18
                        }
                    }
                }
            } catch { Write-Host "  ⚠ 扫描跳过: $_" -ForegroundColor DarkGray }
        }
    }

    # ── 4. 检查包管理工具安装的 Node.js ──
    Write-Host "[4/5] 检查包管理工具 (nvm-windows / fnm / volta)..." -ForegroundColor Yellow

    # nvm-windows
    $nvmPath = Get-Command nvm -ErrorAction SilentlyContinue
    if ($nvmPath) {
        $nvmPath = $nvmPath.Source   # 提取真实路径（Get-Command 返回对象，不能直接传 Test-Path）
    }
    else {
        $nvmPath = "${env:ProgramFiles}\nvm\nvm.exe"
        if (-not (Test-Path $nvmPath)) { $nvmPath = "${env:LOCALAPPDATA}\nvm\nvm.exe" }
    }
    if ($nvmPath -and (Test-Path $nvmPath)) {
        try {
            $nvmList = & $nvmPath list 2>$null
            foreach ($line in $nvmList) {
                if ($line -match '(\d+\.\d+\.\d+)') {
                    $ver = $matches[1]
                    # 从 nvm.exe 路径反推 home，比硬编码 ProgramFiles 更健壮
                    $nvmHome = if ($env:NVM_HOME) { $env:NVM_HOME } else { Split-Path -Parent $nvmPath }
                    $nvmNodePath = Join-Path $nvmHome "v$ver\node.exe"
                    if ((Test-Path $nvmNodePath) -and ($nvmNodePath -notin $checkedPaths)) {
                        $checkedPaths += $nvmNodePath
                        $foundNodes += [PSCustomObject]@{
                            Source   = "nvm-windows"
                            Version  = $ver
                            Path     = $nvmNodePath
                            NpmVersion = $null
                            Is18Plus = [int]($ver -split '\.')[0] -ge 18
                        }
                    }
                    Write-Host "    nvm 管理的: v$ver" -ForegroundColor Gray
                }
            }
        } catch { Write-Host "  ⚠ 扫描跳过: $_" -ForegroundColor DarkGray }
    }

    # fnm
    $fnmPath = Get-Command fnm -ErrorAction SilentlyContinue
    if ($fnmPath) {
        try {
            $fnmList = & fnm list 2>$null
            $fnmDir = if ($env:FNM_DIR) { $env:FNM_DIR } else { "${env:LOCALAPPDATA}\fnm" }
            foreach ($line in $fnmList) {
                if ($line -match '(\d+\.\d+\.\d+)') {
                    $ver = $matches[1]
                    # fnm 默认路径: $FNM_DIR/node-versions/v<ver>/installation/node.exe
                    $fnmNodePath = Join-Path $fnmDir "node-versions\v$ver\installation\node.exe"
                    if ((Test-Path $fnmNodePath) -and ($fnmNodePath -notin $checkedPaths)) {
                        $checkedPaths += $fnmNodePath
                        $foundNodes += [PSCustomObject]@{
                            Source   = "fnm"
                            Version  = $ver
                            Path     = $fnmNodePath
                            NpmVersion = $null
                            Is18Plus = [int]($ver -split '\.')[0] -ge 18
                        }
                    }
                    Write-Host "    fnm 管理的: v$ver" -ForegroundColor Gray
                }
            }
        } catch { Write-Host "  ⚠ 扫描跳过: $_" -ForegroundColor DarkGray }
    }

    # volta
    $voltaPath = Get-Command volta -ErrorAction SilentlyContinue
    if ($voltaPath) {
        try {
            $voltaNode = & volta which node 2>$null
            if ($voltaNode -and (Test-Path $voltaNode) -and ($voltaNode -notin $checkedPaths)) {
                $checkedPaths += $voltaNode
                $ver = & $voltaNode -v 2>$null
                $foundNodes += [PSCustomObject]@{
                    Source   = "Volta"
                    Version  = $ver -replace '^v', ''
                    Path     = $voltaNode
                    NpmVersion = $null
                    Is18Plus = ([int](($ver -replace '^v', '') -split '\.')[0]) -ge 18
                }
            }
        } catch { Write-Host "  ⚠ 扫描跳过: $_" -ForegroundColor DarkGray }
    }

    # ── 5. 汇总报告 ──
    Write-Host "[5/5] 生成检测报告..." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "   📋 检测结果" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan

    if ($foundNodes.Count -eq 0) {
        Write-Host "  ❌ 未在电脑中找到任何 Node.js 安装。" -ForegroundColor Red
    }
    else {
        Write-Host ("  共找到 {0} 个 Node.js 安装:" -f $foundNodes.Count) -ForegroundColor White
        Write-Host ""

        $found18Plus = $false
        foreach ($node in $foundNodes) {
            $icon = if ($node.Is18Plus) { "✅" } else { "⚠️ " }
            $color = if ($node.Is18Plus) { "Green" } else { "Yellow" }
            Write-Host "  $icon v$($node.Version)  [$($node.Source)]" -ForegroundColor $color
            Write-Host "       路径: $($node.Path)" -ForegroundColor Gray
            if ($node.NpmVersion) {
                Write-Host "       npm : v$($node.NpmVersion)" -ForegroundColor Gray
            }
            Write-Host ""
            if ($node.Is18Plus) { $found18Plus = $true }
        }

        if ($found18Plus) {
            Write-Host "  ✅ 已存在 Node.js 18+ 版本，无需安装！" -ForegroundColor Green
        }
        else {
            Write-Host "  ⚠️  未找到 Node.js 18+ 版本，需要安装/升级。" -ForegroundColor Yellow
            Write-Host ""
        }
    }

    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""

    return $foundNodes
}

# ============================================================
# 全面检测电脑中是否存在 Git
# ============================================================
function Test-GitExists {
    <#
    .SYNOPSIS
        全面扫描电脑中所有 Git 安装
    .DESCRIPTION
        依次检查: PATH → 常见安装目录 → 注册表
    .OUTPUTS
        返回找到的 Git 信息对象数组
    #>

    $foundGits = @()
    $checkedPaths = @()

    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "   🔍 正在全面检测电脑中的 Git 安装情况..." -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""

    # ── 1. 检查当前 PATH 中的 git ──
    Write-Host "[1/4] 检查 PATH 环境变量中的 git..." -ForegroundColor Yellow
    $pathGit = Get-Command git -ErrorAction SilentlyContinue
    if ($pathGit) {
        try {
            $ver = & git --version 2>$null
            $fullPath = (Get-Command git).Source
            if ($fullPath -notin $checkedPaths) {
                $checkedPaths += $fullPath
                $foundGits += [PSCustomObject]@{
                    Source  = "PATH"
                    Version = if ($ver -match '(\d+\.\d+\.\d+)') { $matches[1] } else { $ver }
                    Path    = $fullPath
                }
            }
        } catch { Write-Host "  ⚠ 扫描跳过: $_" -ForegroundColor DarkGray }
    }

    # ── 2. 扫描常见安装目录 ──
    Write-Host "[2/4] 扫描常见安装目录..." -ForegroundColor Yellow
    $commonPaths = @(
        "${env:ProgramFiles}\Git\bin",
        "${env:ProgramFiles}\Git\cmd",
        "${env:ProgramFiles(x86)}\Git\bin",
        "${env:ProgramFiles(x86)}\Git\cmd",
        "${env:LOCALAPPDATA}\Programs\Git\bin",
        "${env:LOCALAPPDATA}\Programs\Git\cmd",
        "C:\Git\bin",
        "C:\Git\cmd"
    )

    foreach ($basePath in $commonPaths) {
        $gitExe = Join-Path $basePath "git.exe"
        if ((Test-Path $gitExe) -and ($gitExe -notin $checkedPaths)) {
            $checkedPaths += $gitExe
            try {
                $ver = & $gitExe --version 2>$null
                $foundGits += [PSCustomObject]@{
                    Source  = "目录扫描 [$basePath]"
                    Version = if ($ver -match '(\d+\.\d+\.\d+)') { $matches[1] } else { $ver }
                    Path    = $gitExe
                }
            } catch { Write-Host "  ⚠ 扫描跳过: $_" -ForegroundColor DarkGray }
        }
    }

    # ── 3. 检查注册表中的 Git 安装信息 ──
    Write-Host "[3/4] 检查 Windows 注册表..." -ForegroundColor Yellow
    $regPaths = @(
        "HKLM:\SOFTWARE\GitForWindows",
        "HKLM:\SOFTWARE\WOW6432Node\GitForWindows",
        "HKCU:\SOFTWARE\GitForWindows"
    )

    foreach ($regPath in $regPaths) {
        if (Test-Path $regPath) {
            try {
                $regProps = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
                $installPath = $regProps.InstallPath
                if ($installPath) {
                    foreach ($subDir in @("bin", "cmd")) {
                        $gitExe = Join-Path $installPath "$subDir\git.exe"
                        if ((Test-Path $gitExe) -and ($gitExe -notin $checkedPaths)) {
                            $checkedPaths += $gitExe
                            $ver = & $gitExe --version 2>$null
                            $foundGits += [PSCustomObject]@{
                                Source  = "注册表 [$regPath]"
                                Version = if ($ver -match '(\d+\.\d+\.\d+)') { $matches[1] } else { $ver }
                                Path    = $gitExe
                            }
                        }
                    }
                }
            } catch { Write-Host "  ⚠ 扫描跳过: $_" -ForegroundColor DarkGray }
        }
    }

    # ── 4. 汇总报告 ──
    Write-Host "[4/4] 生成检测报告..." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "   📋 Git 检测结果" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan

    if ($foundGits.Count -eq 0) {
        Write-Host "  ❌ 未在电脑中找到任何 Git 安装。" -ForegroundColor Red
    }
    else {
        Write-Host ("  共找到 {0} 个 Git 安装:" -f $foundGits.Count) -ForegroundColor White
        Write-Host ""
        foreach ($g in $foundGits) {
            Write-Host "  ✅ v$($g.Version)  [$($g.Source)]" -ForegroundColor Green
            Write-Host "       路径: $($g.Path)" -ForegroundColor Gray
            Write-Host ""
        }
    }

    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""

    return $foundGits
}

# ============================================================
# 安装 Git for Windows
# ============================================================
function Install-Git {
    Write-Host ">>> 开始安装 Git for Windows..." -ForegroundColor Yellow
    Write-Host ""

    $arch = if ([Environment]::Is64BitOperatingSystem) { "64" } else { "32" }

    # 获取 Git for Windows 最新版本
    $gitFullTag = $null
    $gitBaseVer = $null
    try {
        $releaseUrl = "https://api.github.com/repos/git-for-windows/git/releases/latest"
        $releaseInfo = Invoke-RestMethod -Uri $releaseUrl -TimeoutSec 10
        $gitFullTag = $releaseInfo.tag_name
        $gitBaseVer = $gitFullTag -replace '^v', '' -replace '\.windows\.\d+$', ''
        Write-Host "Latest Git version: $gitBaseVer (tag: $gitFullTag)" -ForegroundColor Green
    }
    catch {
        Write-Host "Failed to fetch latest Git version. Using fallback." -ForegroundColor Yellow
        $gitFullTag = "v2.47.1.windows.1"
        $gitBaseVer = "2.47.1"
    }

    $tempDir = $env:TEMP
    $installerPath = Join-Path $tempDir "Git-Installer_$(Get-Random).exe"

    # 构建多源下载 URL 列表（GitHub 官方 → 国内镜像）
    # 注意: Git 文件名格式为 Git-2.54.0-64-bit.exe (有横线)
    $gitFileName = "Git-$gitBaseVer-$($arch)-bit.exe"
    $downloadUrls = @(
        # 源 1: GitHub 官方
        "https://github.com/git-for-windows/git/releases/download/$gitFullTag/$gitFileName",
        # 源 2: 清华大学 TUNA 镜像（教育网/国内较稳）
        "https://mirrors.tuna.tsinghua.edu.cn/github-release/git-for-windows/git/$gitFullTag/$gitFileName",
        # 源 3: 南京大学镜像
        "https://mirrors.nju.edu.cn/github-release/git-for-windows/git/$gitFullTag/$gitFileName"
    )

    $downloadSuccess = Invoke-DownloadWithRetry -Urls $downloadUrls -OutFile $installerPath `
        -MaxRetries 3 -Description "Git for Windows"

    if (-not $downloadSuccess) {
        Write-Host ""
        Write-Host ">>> 联网下载失败，尝试使用本地安装包..." -ForegroundColor Yellow

        $localInstaller = Find-LocalInstaller -Pattern "Git*.exe" -Description "Git for Windows"
        if ($localInstaller) {
            $installerPath = $localInstaller
            Write-Host "  ✓ 将使用本地安装包: $installerPath" -ForegroundColor Green
        }
        else {
            Write-Host ""
            Write-Host "============================================================" -ForegroundColor Red
            Write-Host "  ❌ Git 下载失败 — 所有在线源均不可用，且未找到本地安装包" -ForegroundColor Red
            Write-Host "============================================================" -ForegroundColor Red
            Write-Host "  请手动下载并安装 Git，或将 Git 安装包放置在脚本同目录下:" -ForegroundColor Yellow
            Write-Host "    官网: https://git-scm.com/download/win" -ForegroundColor White
            Write-Host "    镜像: https://npmmirror.com/mirrors/git-for-windows/" -ForegroundColor White
            Write-Host ""
            Write-ErrorLog -Reason "Git 下载失败（在线源+本地均不可用）"; exit 1
        }
    }

    Write-Host "Installing Git (this may take a few minutes)..." -ForegroundColor Yellow

    # Git 静默安装参数
    $installArgs = @(
        "/VERYSILENT",
        "/NORESTART",
        "/CLOSEAPPLICATIONS",
        "/LOG=`"$tempDir\git-install.log`"",
        "/DIR=`"${env:ProgramFiles}\Git`""
    )

    $process = Start-Process -FilePath $installerPath -ArgumentList $installArgs -Wait -PassThru

    if ($process.ExitCode -ne 0) {
        Write-Host "Git installation may have issues (exit code: $($process.ExitCode))." -ForegroundColor Yellow
        Write-Host "Check log: $tempDir\git-install.log" -ForegroundColor Gray
    }

    # 刷新环境变量
    $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath    = [System.Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = ($machinePath, $userPath | Where-Object { $_ } ) -join ";"

    # 验证安装
    Write-Host "`n=== Verifying Git Installation ===" -ForegroundColor Cyan

    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if ($gitCmd) {
        $gitVersionOut = & git --version 2>$null
        Write-Host "Git version: $gitVersionOut" -ForegroundColor Green
        Write-Host "`n✓ Git installed successfully!" -ForegroundColor Green
    }
    else {
        Write-Host "⚠ Git installation completed but git is not available in PATH yet." -ForegroundColor Yellow
        Write-Host "  Please restart your terminal, or run:" -ForegroundColor Yellow
        Write-Host "  `$env:Path = ([System.Environment]::GetEnvironmentVariable('Path','Machine'), [System.Environment]::GetEnvironmentVariable('Path','User') | Where-Object { `$_ } ) -join ';'" -ForegroundColor Gray
    }

    # 清理
    Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue
    Write-Host "`nCleaned up Git installer file." -ForegroundColor Gray

    return $true
}

# ============================================================
# 主流程
# ============================================================

# ── Node.js ──
# 执行全面检测
$foundNodes = Test-NodeExists

# 根据检测结果决定是否需要安装（双重检测，避免函数返回值在管道中丢失）
$hasNode18Plus = ($foundNodes | Where-Object { $_.Is18Plus }).Count -gt 0
# 二次把关：直接用 node -v 验证（绕过 PSCustomObject 管道问题）
if (-not $hasNode18Plus) {
    try {
        $directVer = & node -v 2>$null
        if ($directVer -and ([int](($directVer -replace '^v', '') -split '\.')[0]) -ge 18) {
            $hasNode18Plus = $true
        }
    } catch { }
}

if ($hasNode18Plus) {
    Write-Host ">>> 电脑中已存在 Node.js 18+，跳过 Node 安装。" -ForegroundColor Green
    $nodes18 = $foundNodes | Where-Object { $_.Is18Plus }
    foreach ($n in $nodes18) {
        Write-Host "    路径: $($n.Path)  (v$($n.Version))" -ForegroundColor Gray
    }
    Write-Host ""
}
else {
    # 检查 PATH 中是否有低于 18 的版本
    $pathNode = Get-Command node -ErrorAction SilentlyContinue
    if ($pathNode) {
        $currentVersion = (node -v) -replace '^v', ''
        $majorVersion = [int]($currentVersion -split '\.')[0]
        if ($majorVersion -lt 18) {
            Write-Host ">>> PATH 中的 Node.js v$currentVersion 低于 18，将进行升级..." -ForegroundColor Yellow
        }
    }
    else {
        Write-Host ">>> 未在 PATH 中找到 node，将进行全新安装..." -ForegroundColor Yellow
    }
    Write-Host ""

    # Determine architecture
    $arch = if ([Environment]::Is64BitOperatingSystem) { "x64" } else { "x86" }
    Write-Host "Architecture: $arch" -ForegroundColor Gray

    # Get latest Node.js 18+ version
    $latestVersion = Get-LatestNodeVersion -MinMajor 18

    if (-not $latestVersion) {
        # Fallback: use a known LTS URL (最后更新: 2025-05)
        $latestVersion = "v20.19.0"
        Write-Host "Using fallback version: $latestVersion" -ForegroundColor Yellow
    }
    else {
        Write-Host "Latest Node.js 18+ version: $latestVersion" -ForegroundColor Green
    }

    # 本地路径加随机数防冲突
    $tempDir = $env:TEMP
    $installerPath = Join-Path $tempDir "node-$latestVersion-win-$arch-$(Get-Random).msi"

    Write-Host "Downloading Node.js $latestVersion ..." -ForegroundColor Yellow

    # 构建多源下载 URL 列表（官方 → 国内镜像）
    $nodeUrlFilename = "node-$latestVersion-$arch.msi"
    $nodeDownloadUrls = @(
        "https://nodejs.org/dist/$latestVersion/$nodeUrlFilename",
        "https://npmmirror.com/mirrors/node/$latestVersion/$nodeUrlFilename",
        "https://registry.npmmirror.com/-/binary/node/$latestVersion/$nodeUrlFilename"
    )

    $downloadSuccess = Invoke-DownloadWithRetry -Urls $nodeDownloadUrls -OutFile $installerPath `
        -MaxRetries 3 -Description "Node.js $latestVersion"

    if (-not $downloadSuccess) {
        Write-Host ""
        Write-Host ">>> 联网下载失败，尝试使用本地安装包..." -ForegroundColor Yellow

        $localInstaller = Find-LocalInstaller -Pattern "node*.msi" -Description "Node.js"
        if ($localInstaller) {
            $installerPath = $localInstaller
            Write-Host "  ✓ 将使用本地安装包: $installerPath" -ForegroundColor Green
        }
        else {
            Write-Host "❌ Node.js 下载失败 — 所有在线源均不可用，且未找到本地安装包" -ForegroundColor Red
            Write-Host "  请将 Node.js 的 .msi 安装包放置在脚本同目录下后重试" -ForegroundColor Yellow
            Write-ErrorLog -Reason "Node.js 下载失败（在线源+本地均不可用）"; exit 1
        }
    }

    Write-Host "Installing Node.js $latestVersion (this may take a few minutes)..." -ForegroundColor Yellow

    # Run MSI installer silently
    $installArgs = @(
        "/i", $installerPath,
        "/quiet",
        "/norestart",
        "ADDLOCAL=ALL"
    )

    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $installArgs -Wait -PassThru

    if ($process.ExitCode -ne 0) {
        Write-Host "Installation failed with exit code: $($process.ExitCode)" -ForegroundColor Red
        Write-ErrorLog -Reason "Node.js MSI 安装返回非零退出码"; exit 1
    }

    # Refresh environment variables
    $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath    = [System.Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = ($machinePath, $userPath | Where-Object { $_ } ) -join ";"

    # Verify installation
    Write-Host "`n=== Verifying Node.js Installation ===" -ForegroundColor Cyan

    $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
    if ($nodeCmd) {
        $nodeVersion = & node -v 2>$null
        # npm 独立获取，避免 npm 未注册到 PATH 时终止脚本
        $npmVersion = $null
        $npmCmd = Get-Command npm -ErrorAction SilentlyContinue
        if ($npmCmd) { $npmVersion = & npm -v 2>$null }
        Write-Host "Node.js version: $nodeVersion" -ForegroundColor Green
        if ($npmVersion) {
            Write-Host "npm version:     v$npmVersion" -ForegroundColor Green
        } else {
            Write-Host "npm version:     (未检测到)" -ForegroundColor Yellow
        }

        $major = [int](($nodeVersion -replace '^v', '') -split '\.')[0]
        if ($major -ge 18) {
            Write-Host "`n✓ Node.js 18+ installed successfully!" -ForegroundColor Green
        }
        else {
            Write-Host "`n⚠ Installed version is below 18. Please check manually." -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "⚠ Installation completed but node is not available in PATH yet." -ForegroundColor Yellow
        Write-Host "  Please restart your terminal, or run:" -ForegroundColor Yellow
        Write-Host "  `$env:Path = ([System.Environment]::GetEnvironmentVariable('Path','Machine'), [System.Environment]::GetEnvironmentVariable('Path','User') | Where-Object { `$_ } ) -join ';'" -ForegroundColor Gray
    }

    # Cleanup
    Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue
    Write-Host "`nCleaned up Node.js installer file." -ForegroundColor Gray
}

# ── Git ──
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Git 部分" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# 执行 Git 检测
$foundGits = Test-GitExists
$hasGit = $foundGits.Count -gt 0

if ($hasGit) {
    Write-Host ">>> 电脑中已存在 Git，跳过安装。" -ForegroundColor Green
    foreach ($g in $foundGits) {
        Write-Host "    路径: $($g.Path)  (v$($g.Version))" -ForegroundColor Gray
    }
}
else {
    Write-Host ">>> 未找到 Git，开始安装..." -ForegroundColor Yellow
    Write-Host ""
    Install-Git
}

# ── Claude Code ──
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Claude Code 部分" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# 检查 npm 是否可用
$npmCmd = Get-Command npm -ErrorAction SilentlyContinue
if (-not $npmCmd) {
    Write-Host "❌ npm 不可用，无法安装 Claude Code。" -ForegroundColor Red
}
else {
    # 先检查是否已安装
    $existingClaude = Get-Command claude -ErrorAction SilentlyContinue
    if ($existingClaude) {
        Write-Host ">>> Claude Code 已存在: $(& claude --version)，跳过安装。" -ForegroundColor Green
    }
    else {
        Write-Host ">>> 安装 @anthropic-ai/claude-code (支持重试和镜像)..." -ForegroundColor Yellow

        $ccSuccess = Invoke-NpmInstallWithRetry -Package "@anthropic-ai/claude-code" -MaxRetries 3

        if ($ccSuccess) {
            Write-Host "✓ @anthropic-ai/claude-code 安装成功" -ForegroundColor Green

            # 刷新 PATH（npm 全局安装可能添加了新路径）
            $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
            $userPath    = [System.Environment]::GetEnvironmentVariable("Path", "User")
            $env:Path = ($machinePath, $userPath | Where-Object { $_ } ) -join ";"

            # 验证安装
            $claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
            if ($claudeCmd) {
                Write-Host "`n=== Verifying Claude Code ===" -ForegroundColor Cyan
                $claudeVersion = & claude --version 2>$null
                Write-Host "Claude Code version: $claudeVersion" -ForegroundColor Green
            }
            else {
                Write-Host "⚠ Claude Code installed but 'claude' not found in PATH." -ForegroundColor Yellow
                Write-Host "  Please restart your terminal and run 'claude --version'." -ForegroundColor Yellow
            }
        }
        else {
            Write-Host "❌ Claude Code 安装失败 — 所有 npm 源均不可用" -ForegroundColor Red
            Write-Host "  请手动执行: npm install -g @anthropic-ai/claude-code" -ForegroundColor Red
            Write-Host "  使用镜像: npm install -g @anthropic-ai/claude-code --registry=https://registry.npmmirror.com" -ForegroundColor Red
        }
    }
}

# ── DeepSeek 环境变量配置 ──
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  DeepSeek API 配置（Claude Code 后端）" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "是否配置 DeepSeek 作为 Claude Code 的 API 后端？" -ForegroundColor Yellow
Write-Host "  [Y] 是，输入 API Key 进行配置" -ForegroundColor White
Write-Host "  [N] 跳过（默认）" -ForegroundColor White
Write-Host ""
$configureDeepseek = Read-Host "请输入选择"

if ($configureDeepseek -eq 'Y' -or $configureDeepseek -eq 'y') {
    $secureKey = Read-Host "请输入你的 DeepSeek API Key" -AsSecureString
    $apiKey = [System.Net.NetworkCredential]::new('', $secureKey).Password

    if ($apiKey) {
        $deepseekVars = @{
            "ANTHROPIC_BASE_URL"              = "https://api.deepseek.com/anthropic"
            "ANTHROPIC_AUTH_TOKEN"            = $apiKey
            "ANTHROPIC_MODEL"                 = "deepseek-v4-pro[1m]"
            "ANTHROPIC_DEFAULT_OPUS_MODEL"    = "deepseek-v4-pro[1m]"
            "ANTHROPIC_DEFAULT_SONNET_MODEL"  = "deepseek-v4-pro[1m]"
            "ANTHROPIC_DEFAULT_HAIKU_MODEL"   = "deepseek-v4-flash"
            "CLAUDE_CODE_SUBAGENT_MODEL"      = "deepseek-v4-flash"
            "CLAUDE_CODE_EFFORT_LEVEL"        = "max"
        }

        Write-Host ""
        Write-Host "正在写入环境变量（用户级别注册表，持久化）..." -ForegroundColor Yellow

        # 构建临时文件内容（纯 $env:XXX = '...' 命令，供父进程 dot-source）
        $envLines = @()

        foreach ($varName in $deepseekVars.Keys) {
            $varValue = $deepseekVars[$varName]
            # 写入注册表（持久化，新终端自动生效）
            [System.Environment]::SetEnvironmentVariable($varName, $varValue, "User")
            # 同时设置当前会话
            Set-Item -Path "env:$varName" -Value $varValue -ErrorAction SilentlyContinue
            # 收集命令行（供父进程加载）
            $envLines += "`$env:${varName} = '${varValue}'"
            Write-Host "  ✓ `$env:$varName" -ForegroundColor Green
        }

        # 写入临时文件 — 父进程（非提权）将在子进程退出后自动加载
        $envTempFile = Join-Path $env:TEMP "claude-code-env.ps1"
        try {
            $envLines -join "`n" | Out-File -FilePath $envTempFile -Encoding UTF8 -Force
            Write-Host ""
            Write-Host "  ✓ 环境变量已写入注册表 + 临时文件" -ForegroundColor Green
            Write-Host "    退出脚本后父进程将自动加载，无需手动操作" -ForegroundColor Gray
        } catch {
            Write-Host "  ⚠ 无法写入临时文件: $_" -ForegroundColor DarkYellow
        }
    }
    else {
        Write-Host "⚠ 未输入 API Key，跳过 DeepSeek 配置。" -ForegroundColor Yellow
    }
}
else {
    Write-Host ">>> 跳过 DeepSeek 配置。" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  后续可手动设置以下环境变量：" -ForegroundColor Gray
    Write-Host "  `$env:ANTHROPIC_BASE_URL='https://api.deepseek.com/anthropic'" -ForegroundColor DarkGray
    Write-Host "  `$env:ANTHROPIC_AUTH_TOKEN='<你的 DeepSeek API Key>'" -ForegroundColor DarkGray
    Write-Host "  `$env:ANTHROPIC_MODEL='deepseek-v4-pro[1m]'" -ForegroundColor DarkGray
    Write-Host "  `$env:ANTHROPIC_DEFAULT_OPUS_MODEL='deepseek-v4-pro[1m]'" -ForegroundColor DarkGray
    Write-Host "  `$env:ANTHROPIC_DEFAULT_SONNET_MODEL='deepseek-v4-pro[1m]'" -ForegroundColor DarkGray
    Write-Host "  `$env:ANTHROPIC_DEFAULT_HAIKU_MODEL='deepseek-v4-flash'" -ForegroundColor DarkGray
    Write-Host "  `$env:CLAUDE_CODE_SUBAGENT_MODEL='deepseek-v4-flash'" -ForegroundColor DarkGray
    Write-Host "  `$env:CLAUDE_CODE_EFFORT_LEVEL='max'" -ForegroundColor DarkGray
    Write-Host "  `$env:CLAUDE_CODE_ATTRIBUTION_HEADER='0'" -ForegroundColor DarkGray
    Write-Host ""
}

# ── 设置 Claude Code 归属标头（始终关闭） ──
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Claude Code 归属标头" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
[System.Environment]::SetEnvironmentVariable("CLAUDE_CODE_ATTRIBUTION_HEADER", "0", "User")
$env:CLAUDE_CODE_ATTRIBUTION_HEADER = "0"
Write-Host "  ✓ `$env:CLAUDE_CODE_ATTRIBUTION_HEADER = '0' (已持久化到用户注册表)" -ForegroundColor Green
Write-Host ""

# ── 成功摘要日志 ──
$successLog = Join-Path ([Environment]::GetFolderPath("Desktop")) `
                      "install-success-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
try {
    $nodeVersion   = try { & node -v 2>$null } catch { "N/A" }
    $npmVersion    = try { & npm -v 2>$null } catch { "N/A" }
    $gitVersion    = try { & git --version 2>$null } catch { "N/A" }
    $claudeVersion = try { & claude --version 2>$null } catch { "N/A" }
    @"
============================================================
  安装成功摘要
============================================================
  时间         : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
  耗时         : $(((Get-Date) - $Script:StartTime).TotalSeconds.ToString('0')) 秒
  Node.js      : $nodeVersion
  npm          : $npmVersion
  Git          : $gitVersion
  Claude Code  : $claudeVersion
============================================================
"@ | Out-File -FilePath $successLog -Encoding UTF8 -Force
}
catch { }

# ── 最终汇总 ──
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "   🎉 安装完成！最终状态" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# Node.js 状态
$finalNodeCmd = Get-Command node -ErrorAction SilentlyContinue
if ($finalNodeCmd) {
    Write-Host "  ✅ Node.js : $(& node -v)" -ForegroundColor Green
} else {
    Write-Host "  ❌ Node.js : 未检测到" -ForegroundColor Red
}

# npm 状态
$finalNpmCmd = Get-Command npm -ErrorAction SilentlyContinue
if ($finalNpmCmd) {
    Write-Host "  ✅ npm     : v$(& npm -v)" -ForegroundColor Green
} else {
    Write-Host "  ❌ npm     : 未检测到" -ForegroundColor Red
}

# Git 状态
$finalGitCmd = Get-Command git -ErrorAction SilentlyContinue
if ($finalGitCmd) {
    Write-Host "  ✅ Git     : $(& git --version)" -ForegroundColor Green
} else {
    Write-Host "  ❌ Git     : 未检测到" -ForegroundColor Red
}

# Claude Code 状态
$finalClaudeCmd = Get-Command claude -ErrorAction SilentlyContinue
if ($finalClaudeCmd) {
    Write-Host "  ✅ Claude  : $(& claude --version)" -ForegroundColor Green
} else {
    Write-Host "  ❌ Claude  : 未检测到" -ForegroundColor Red
}

Write-Host ""

# ── 项目目录准备 ──
$projectDir = Join-Path ([Environment]::GetFolderPath("Desktop")) "my-project"
if (-not (Test-Path $projectDir)) {
    Write-Host ">>> 创建项目目录: $projectDir" -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $projectDir -Force | Out-Null
    Write-Host "✓ 目录已创建" -ForegroundColor Green
}
else {
    Write-Host ">>> 项目目录已存在: $projectDir" -ForegroundColor Green
}
Write-Host ""
Write-Host "  切换到项目目录：" -ForegroundColor Yellow
Write-Host "    cd '$projectDir'" -ForegroundColor White

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan

Write-Host ""
Read-Host "按 Enter 键退出..."
