# Claude Code + DeepSeek 一键卸载脚本 (uninstall.ps1)
# 卸载 Node.js, Git, Claude Code, 清理环境变量、残留文件及桌面快捷方式
#Requires -Version 5.1

$ErrorActionPreference = "Stop"
$script:UninstallReport = [System.Collections.Generic.List[string]]::new()

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

    $argList = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`""
    )
    if ($args.Count -gt 0) {
        $argList += $args
    }

    $process = Start-Process PowerShell -Verb RunAs -ArgumentList $argList -Wait -PassThru
    exit $process.ExitCode
}

Write-Host "=== 管理员权限已确认 ===" -ForegroundColor Green
Write-Host ""

# ============================================================
# 架构检测：32位进程在64位系统上自动切换到原生64位
# ============================================================
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    Write-Host "⚠️ 正在切换到 64 位 PowerShell..." -ForegroundColor Yellow
    $argList = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`""
    )
    $process = Start-Process -FilePath "$env:SystemRoot\SysNative\WindowsPowerShell\v1.0\powershell.exe" `
        -Verb RunAs -ArgumentList $argList -Wait -PassThru
    exit $process.ExitCode
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "   Claude Code + DeepSeek 一键卸载" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ═══════════════════════════════════════════════════════════════
# 读取安装标记（由 install.ps1 写入）— 区分脚本安装 vs 预装软件
# ═══════════════════════════════════════════════════════════════
$script:SentinelKey  = "HKCU:\SOFTWARE\ClaudeCodeDeepSeekInstaller"
$script:HasSentinel  = Test-Path $script:SentinelKey
$script:InstalledByUs = @{}

if ($script:HasSentinel) {
    Write-Host "  📋 检测到安装标记：" -ForegroundColor Cyan
    $props = Get-ItemProperty -Path $script:SentinelKey -ErrorAction SilentlyContinue
    if ($props) {
        foreach ($prop in $props.PSObject.Properties) {
            if ($prop.Name -ne 'PSPath' -and $prop.Name -ne 'PSParentPath' -and
                $prop.Name -ne 'PSChildName' -and $prop.Name -ne 'PSDrive' -and
                $prop.Name -ne 'PSProvider') {
                $script:InstalledByUs[$prop.Name] = $prop.Value
                Write-Host "     $($prop.Name): $($prop.Value)" -ForegroundColor Gray
            }
        }
    }
    Write-Host ""
    Write-Host "  将仅卸载由本安装脚本部署的软件。" -ForegroundColor Green
    Write-Host "  如果检测到预装的 Node.js / Git，将保留不删除。" -ForegroundColor Green
} else {
    Write-Host "  ⚠️  未检测到安装标记。" -ForegroundColor Yellow
    Write-Host "  这意味着可能是手动安装，或安装标记已被删除。" -ForegroundColor Yellow
    Write-Host "  卸载脚本将尝试移除所有检测到的 Node.js / Git（可能包含预装软件）。" -ForegroundColor Yellow
    Write-Host "  建议：重新运行 install.ps1 后再卸载，或手动确认卸载范围。" -ForegroundColor Yellow
}
Write-Host ""

# ── 执行策略检查 ──
try {
    $currentPolicy = Get-ExecutionPolicy -Scope CurrentUser -ErrorAction SilentlyContinue
    if ($currentPolicy -eq 'RemoteSigned') {
        Write-Host "  ⚠️  CurrentUser 执行策略仍为 RemoteSigned" -ForegroundColor Yellow
        Write-Host "     这可能是 install.ps1 设定后未恢复的残留。" -ForegroundColor Yellow
        Write-Host "     如需恢复默认：Set-ExecutionPolicy Undefined -Scope CurrentUser -Force" -ForegroundColor Gray
        Write-Host ""
    }
} catch { }
Write-Host ""

# 检查某个组件是否由本安装脚本部署
function Test-InstalledByUs {
    param([string]$ComponentKey)
    # 无标记 → 无法确认，保守处理：当作是我们装的
    if (-not $script:HasSentinel) { return $true }
    # 有标记 → 检查是否记录了这个组件
    return $script:InstalledByUs.ContainsKey($ComponentKey) -and $script:InstalledByUs[$ComponentKey]
}

# ═══════════════════════════════════════════════════════════════
# 工具函数
# ═══════════════════════════════════════════════════════════════

function Write-Step {
    param([string]$Title, [int]$Step, [int]$Total)
    Write-Host ""
    Write-Host ("━" * 60) -ForegroundColor Cyan
    Write-Host "  [$Step/$Total] $Title" -ForegroundColor Cyan
    Write-Host ("━" * 60) -ForegroundColor Cyan
    Write-Host ""
}

function Write-OK {
    param([string]$Msg)
    Write-Host "  ✅ $Msg" -ForegroundColor Green
    $script:UninstallReport.Add("✅ $Msg")
}

function Write-Warn {
    param([string]$Msg)
    Write-Host "  ⚠️  $Msg" -ForegroundColor Yellow
    $script:UninstallReport.Add("⚠️ $Msg")
}

function Write-Info {
    param([string]$Msg)
    Write-Host "  ℹ️  $Msg" -ForegroundColor Gray
    $script:UninstallReport.Add("ℹ️ $Msg")
}

function Write-Detail {
    param([string]$Msg)
    Write-Host "    $Msg" -ForegroundColor Gray
}

# 安全删除目录：先杀占用进程，再删除，失败时记录而非静默
function Remove-DirectorySafe {
    param(
        [string]$Path,
        [string]$Label = $Path
    )

    if (-not (Test-Path $Path)) { return $false }

    Write-Detail "清理目录: $Path"

    # 终止该目录下正在运行的进程
    # 使用路径分隔符检查防止前缀碰撞（如 Git 误杀 GitHub Desktop）
    $pathWithSep = if ($Path.EndsWith('\')) { $Path } else { "$Path\" }
    $dirProcesses = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
    foreach ($proc in Get-Process) {
        try {
            $procPath = $proc.Path  # 某些保护进程会抛异常
            if ($procPath -and ($procPath.StartsWith($pathWithSep, [StringComparison]::OrdinalIgnoreCase) -or $procPath -eq $Path)) {
                $dirProcesses.Add($proc)
            }
        } catch {
            # 无法查询此进程（保护进程/其他会话），跳过
        }
    }
    foreach ($proc in $dirProcesses) {
        try {
            Write-Detail "  终止进程: $($proc.ProcessName) (PID: $($proc.Id))"
            $proc.Kill()
            $proc.WaitForExit(5000)
        } catch {
            Write-Detail "  无法终止进程 $($proc.ProcessName): $_"
        }
    }
    if ($dirProcesses.Count -gt 0) {
        Start-Sleep -Seconds 2
    }

    try {
        Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
        Write-OK "已删除: $Label"
        return $true
    } catch {
        Write-Warn "无法完全删除: $Label — $_"
        Write-Detail "  建议重启后手动删除: $Path"
        return $false
    }
}

# 安全删除文件
function Remove-FileSafe {
    param(
        [string]$Path,
        [string]$Label = $Path
    )

    if (-not (Test-Path $Path)) { return $false }

    try {
        Remove-Item -Path $Path -Force -ErrorAction Stop
        Write-Detail "  已删除: $Label"
        return $true
    } catch {
        Write-Detail "  无法删除: $Label — $_"
        return $false
    }
}

# 安全删除注册表键
function Remove-RegKeySafe {
    param([string]$Path)

    if (-not (Test-Path $Path)) { return $false }

    try {
        Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
        Write-Detail "  清理注册表: $Path"
        return $true
    } catch {
        Write-Detail "  无法清理注册表: $Path — $_"
        return $false
    }
}

# 通过注册表获取卸载命令（安全方式，不使用 Win32_Product）
function Get-UninstallEntry {
    param(
        [string]$DisplayNamePattern,
        [string[]]$ExcludePattern = @()
    )

    $results = @()
    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )

    foreach ($regPath in $regPaths) {
        if (-not (Test-Path $regPath)) { continue }

        foreach ($key in Get-ChildItem $regPath -ErrorAction SilentlyContinue) {
            try {
                $displayName = $key.GetValue("DisplayName")
                if (-not $displayName) { continue }
                if ($displayName -notmatch $DisplayNamePattern) { continue }

                # 排除匹配
                $excluded = $false
                foreach ($pat in $ExcludePattern) {
                    if ($displayName -match $pat) { $excluded = $true; break }
                }
                if ($excluded) { continue }

                $results += [PSCustomObject]@{
                    DisplayName     = $displayName
                    DisplayVersion  = $key.GetValue("DisplayVersion")
                    UninstallString = $key.GetValue("UninstallString")
                    QuietUninstallString = $key.GetValue("QuietUninstallString")
                    PSChildName     = $key.PSChildName
                    Publisher       = $key.GetValue("Publisher")
                    RegistryPath    = $key.PSPath
                }
            } catch { }
        }
    }

    return $results
}

# ═══════════════════════════════════════════════════════════════
# Step 0: 终止所有相关进程（在任何卸载操作之前）
# ═══════════════════════════════════════════════════════════════

$totalSteps = 5
$currentStep = 0

Write-Step "终止相关进程" $currentStep $totalSteps

$processesToKill = @(
    # Node.js 相关
    "node",
    "npm",
    "npx",
    # Git 相关
    "git",
    "bash",
    "sh",
    # 注意: ssh-agent / gpg-agent 是系统级服务，被 Git 之外的很多工具使用
    # 不在此处终止，避免破坏用户的 SSH 密钥会话和 GPG 签名操作
    # Claude Code 相关
    "claude",
    # Git GUI 工具
    "gitk",
    "git-gui",
    "git-credential-manager"
)

$killedCount = 0
foreach ($procName in $processesToKill) {
    try {
        $procs = Get-Process -Name $procName -ErrorAction SilentlyContinue
        foreach ($p in $procs) {
            try {
                $p.Kill()
                # 等待进程完全退出，防止文件句柄残留
                if (-not $p.WaitForExit(3000)) {
                    Write-Detail "  进程未在 3s 内退出: $procName (PID: $($p.Id))"
                }
                Write-Detail "已终止进程: $procName (PID: $($p.Id))"
                $killedCount++
            } catch { }
        }
    } catch { }
}

if ($killedCount -gt 0) {
    Write-OK "已终止 $killedCount 个相关进程"
    Start-Sleep -Seconds 2
} else {
    Write-Info "没有发现需要终止的进程"
}

# ═══════════════════════════════════════════════════════════════
# Step 1: 卸载 Claude Code (npm)
# ═══════════════════════════════════════════════════════════════
$currentStep++

Write-Step "卸载 Claude Code" $currentStep $totalSteps

# 查找 npm 可执行文件
$npmPath = $null
try {
    $npmPath = (Get-Command npm -ErrorAction Stop).Source
} catch {
    $candidatePaths = @(
        "${env:ProgramFiles}\nodejs\npm.cmd",
        "${env:ProgramFiles}\nodejs\npm",
        "${env:ProgramFiles(x86)}\nodejs\npm.cmd",
        "${env:ProgramFiles(x86)}\nodejs\npm",
        "${env:APPDATA}\npm\npm.cmd",
        "${env:LOCALAPPDATA}\Programs\nodejs\npm.cmd"
    )
    foreach ($p in $candidatePaths) {
        if (Test-Path $p) { $npmPath = $p; break }
    }
}

if ($npmPath -and (Test-Path $npmPath)) {
    Write-Detail "找到 npm: $npmPath"

    # 先查看是否已安装
    $ccInstalled = $false
    try {
        $listOutput = & $npmPath list -g "@anthropic-ai/claude-code" 2>&1 | Out-String
        if ($listOutput -match "@anthropic-ai/claude-code") {
            $ccInstalled = $true
        }
    } catch { }

    if ($ccInstalled) {
        Write-Detail "正在卸载 @anthropic-ai/claude-code..."
        $prevExit = $LASTEXITCODE
        # npm 经常输出 stderr（warnings/audit），ErrorActionPreference=Stop 下
        # 需临时降级防止这些非致命输出导致整个卸载脚本中止
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $uninstallOutput = & $npmPath uninstall -g "@anthropic-ai/claude-code" 2>&1
            $ccExit = $LASTEXITCODE
        } finally {
            $LASTEXITCODE = $prevExit
            $ErrorActionPreference = $prevEAP
        }

        foreach ($line in $uninstallOutput) {
            if ($line -match "removed|up to date|added|audited") {
                Write-Detail "  $line"
            }
        }

        if ($ccExit -eq 0) {
            Write-OK "Claude Code: 已通过 npm 卸载"
        } else {
            Write-Warn "Claude Code: npm 卸载返回代码 $ccExit（可能已不存在）"
        }
    } else {
        Write-Info "Claude Code: npm 全局列表中未找到，跳过 npm 卸载"
    }
} else {
    Write-Warn "npm 未找到，跳过 Claude Code npm 卸载"
    Write-Detail "如需手动清理，请检查: %APPDATA%\npm\node_modules\@anthropic-ai"
}

# 清理 Claude Code 全局安装残留目录
$claudeResidualDirs = @(
    "${env:APPDATA}\npm\node_modules\@anthropic-ai\claude-code",
    "${env:APPDATA}\npm\node_modules\@anthropic-ai",
    "${env:ProgramFiles}\nodejs\node_modules\@anthropic-ai\claude-code",
    "${env:ProgramFiles}\nodejs\node_modules\@anthropic-ai",
    "${env:ProgramFiles(x86)}\nodejs\node_modules\@anthropic-ai\claude-code",
    "${env:ProgramFiles(x86)}\nodejs\node_modules\@anthropic-ai",
    "${env:LOCALAPPDATA}\pnpm\global\5\node_modules\@anthropic-ai\claude-code",
    "${env:LOCALAPPDATA}\pnpm\global\5\node_modules\@anthropic-ai"
)

Write-Detail "清理 Claude Code 残留目录..."
$ccResidualCleaned = 0
foreach ($dir in $claudeResidualDirs) {
    if (Test-Path $dir) {
        if (Remove-DirectorySafe -Path $dir -Label $dir) {
            $ccResidualCleaned++
        }
    }
}

# 清理 claude / claude-code 可执行文件（npm 全局 bin 目录）
$npmBinDirs = @(
    "${env:APPDATA}\npm",
    "${env:ProgramFiles}\nodejs",
    "${env:ProgramFiles(x86)}\nodejs",
    "${env:LOCALAPPDATA}\pnpm"
)
$claudeExeNames = @("claude", "claude.cmd", "claude.ps1", "claude-code", "claude-code.cmd")
foreach ($binDir in $npmBinDirs) {
    if (-not (Test-Path $binDir)) { continue }
    foreach ($exeName in $claudeExeNames) {
        $exePath = Join-Path $binDir $exeName
        Remove-FileSafe -Path $exePath -Label $exePath | Out-Null
    }
}

if ($ccResidualCleaned -eq 0) {
    Write-Info "Claude Code: 无残留目录需要清理"
}

# 清理 Claude Code 配置和数据目录（用户目录下）
Write-Detail "清理 Claude Code 用户数据..."
$claudeUserDirs = @(
    "$env:USERPROFILE\.claude",
    "$env:USERPROFILE\.claude-code"
)
foreach ($dir in $claudeUserDirs) {
    if (Test-Path $dir) {
        Remove-DirectorySafe -Path $dir -Label $dir | Out-Null
    }
}

# ═══════════════════════════════════════════════════════════════
# Step 2: 卸载 Git for Windows（含 Credential Manager + 用户配置）
# ═══════════════════════════════════════════════════════════════
$currentStep++

Write-Step "卸载 Git for Windows" $currentStep $totalSteps

# 哨兵检查：如果 Git 不是我们安装的，跳过卸载
if (-not (Test-InstalledByUs "GitVersion")) {
    Write-Info "Git: 非本脚本安装（安装标记中无记录），跳过卸载。仅清理环境变量和 PATH。"
    $gitUninstalled = $false
    # 跳转到 Git 注册表和 PATH 清理（不执行 MSI/Inno 卸载）
} else {
    Write-Detail "Git: 确认为本脚本安装，执行卸载..."

    # 注意：按依赖关系，Git 应在 Node.js 之前卸载
    # 因为某些 Node.js 工具可能依赖 Git，而 Git 不依赖 Node.js

    $gitUninstalled = $false

# ── 2a. 单独卸载 Git Credential Manager（它可能有独立卸载条目）──
Write-Detail "检查 Git Credential Manager 独立安装..."
$gcmEntries = Get-UninstallEntry -DisplayNamePattern "Git Credential Manager"
foreach ($entry in $gcmEntries) {
    Write-Detail "找到: $($entry.DisplayName) v$($entry.DisplayVersion)"

    if ($entry.UninstallString) {
        $uninstallCmd = $entry.UninstallString.Trim('"')
        Write-Detail "卸载命令: $uninstallCmd"

        if ($uninstallCmd -match "msiexec") {
            $args = $uninstallCmd -replace 'msiexec\.exe\s*', ''
            if ($args -notmatch '/quiet') { $args += ' /quiet /norestart' }
            $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $args -Wait -PassThru
        } else {
            $proc = Start-Process -FilePath $uninstallCmd -ArgumentList "/VERYSILENT /NORESTART /SUPPRESSMSGBOXES" -Wait -PassThru
        }

        Write-Detail "  卸载程序完成 (exit: $($proc.ExitCode))"
    }
}

# ── 2b. 卸载 Git for Windows 主体 ──
Write-Detail "查找 Git for Windows 安装..."

# 方法1: 通过注册表
$gitEntries = Get-UninstallEntry -DisplayNamePattern "^Git$"

if ($gitEntries.Count -eq 0) {
    # 更宽松的匹配
    $gitEntries = Get-UninstallEntry -DisplayNamePattern "Git for Windows"
}

foreach ($entry in $gitEntries) {
    Write-Detail "找到: $($entry.DisplayName) v$($entry.DisplayVersion)"

    if (-not $entry.UninstallString) { continue }

    $uninstallCmd = $entry.UninstallString.Trim('"')
    Write-Detail "卸载命令: $uninstallCmd"

    try {
        if ($uninstallCmd -match "unins\d+\.exe" -or $uninstallCmd -match "uninstall\.exe") {
            # Inno Setup 卸载程序
            $proc = Start-Process -FilePath $uninstallCmd `
                -ArgumentList "/VERYSILENT /NORESTART /SUPPRESSMSGBOXES" `
                -Wait -PassThru -NoNewWindow
            Write-Detail "Inno Setup 卸载完成 (exit: $($proc.ExitCode))"
        } else {
            # 通用卸载程序
            $proc = Start-Process -FilePath $uninstallCmd `
                -ArgumentList "/S" `
                -Wait -PassThru -NoNewWindow
            Write-Detail "卸载程序执行完成 (exit: $($proc.ExitCode))"
        }
    } catch {
        Write-Warn "Git 卸载程序执行失败: $_"
    }
}

# ── 2c. 直接查找卸载程序 ──
$gitUninstallerPaths = @(
    "${env:ProgramFiles}\Git\unins000.exe",
    "${env:ProgramFiles}\Git\uninstall.exe",
    "${env:ProgramFiles(x86)}\Git\unins000.exe",
    "${env:ProgramFiles(x86)}\Git\uninstall.exe",
    "${env:LOCALAPPDATA}\Programs\Git\unins000.exe",
    "${env:LOCALAPPDATA}\Programs\Git\uninstall.exe"
)

foreach ($unPath in $gitUninstallerPaths) {
    if (-not (Test-Path $unPath)) { continue }

    Write-Detail "找到卸载程序: $unPath"
    try {
        $proc = Start-Process -FilePath $unPath `
            -ArgumentList "/VERYSILENT /NORESTART /SUPPRESSMSGBOXES" `
            -Wait -PassThru -NoNewWindow
        Write-Detail "卸载完成 (exit: $($proc.ExitCode))"
    } catch {
        Write-Warn "卸载程序执行失败: $_"
    }
}

# ── 2d. 等待卸载完成，再检查目录是否仍然存在 ──
Start-Sleep -Seconds 3

# 覆盖所有可能的 Git 安装路径
$gitInstallDirs = @(
    "${env:ProgramFiles}\Git",
    "${env:ProgramFiles(x86)}\Git",
    "${env:LOCALAPPDATA}\Programs\Git",
    "C:\Git"
)

$gitDirsCleaned = 0
foreach ($dir in $gitInstallDirs) {
    if (Test-Path $dir) {
        if (Remove-DirectorySafe -Path $dir -Label $dir) {
            $gitDirsCleaned++
            $gitUninstalled = $true
        }
    }
}

}  # 结束 if (Test-InstalledByUs "GitVersion") — 注册表和 PATH 清理始终执行

# ── 2e. 清理 Git 注册表键 ──
$gitRegKeys = @(
    "HKLM:\SOFTWARE\GitForWindows",
    "HKLM:\SOFTWARE\WOW6432Node\GitForWindows",
    "HKCU:\SOFTWARE\GitForWindows",
    "HKLM:\SOFTWARE\GitExtensions",
    "HKLM:\SOFTWARE\WOW6432Node\GitExtensions"
)
foreach ($key in $gitRegKeys) {
    Remove-RegKeySafe -Path $key | Out-Null
}

# ── 2f. 清理 Git 用户配置文件（逐文件确认后再删除）──
$gitUserConfigs = @(
    "$env:USERPROFILE\.gitconfig",
    "$env:USERPROFILE\.git-credentials"
)

Write-Host ""
Write-Host "  Git 用户配置文件检测:" -ForegroundColor Yellow
$gitConfigsCleaned = 0
foreach ($cfg in $gitUserConfigs) {
    if (Test-Path $cfg) {
        Write-Host "    $cfg" -ForegroundColor White
        Write-Host "    ⚠️  此文件包含你的 Git 全局配置，可能含用户名/邮箱/凭据。" -ForegroundColor Yellow
        Write-Host "    删除后无法恢复。是否删除？[y/N]" -ForegroundColor Red
        $confirm = Read-Host "    请输入"
        if ($confirm -eq 'y' -or $confirm -eq 'Y') {
            if (Remove-FileSafe -Path $cfg -Label $cfg) {
                $gitConfigsCleaned++
            }
        } else {
            Write-Info "已跳过: $cfg"
        }
    }
}

# SSH 和 GPG 目录：可能被其他工具使用，只提示不删除
$sharedDirs = @("$env:USERPROFILE\.ssh", "$env:USERPROFILE\.gnupg")
foreach ($dir in $sharedDirs) {
    if (Test-Path $dir) {
        Write-Info "目录 $dir 仍存在（可能被其他工具使用，未删除）"
    }
}

if ($gitDirsCleaned -eq 0 -and $gitConfigsCleaned -eq 0) {
    Write-Info "Git: 未检测到残留安装目录或配置文件"
}

if ($gitUninstalled -or $gitDirsCleaned -gt 0) {
    Write-OK "Git: 已卸载 ($gitDirsCleaned 个目录已清理)"
}

# ═══════════════════════════════════════════════════════════════
# Step 3: 卸载 Node.js（加强版：移除 WMI 方法，多版本处理，验证安装目录）
# ═══════════════════════════════════════════════════════════════
$currentStep++

Write-Step "卸载 Node.js" $currentStep $totalSteps

$nodeUninstalled = $false
$nodeDirsCleaned = 0

# 哨兵检查：如果 Node.js 不是我们安装的，跳过 MSI/Inno 卸载
if (-not (Test-InstalledByUs "NodeVersion")) {
    Write-Info "Node.js: 非本脚本安装（安装标记中无记录），跳过卸载程序调用。仅清理 npm 数据和 PATH。"
} else {
    Write-Detail "Node.js: 确认为本脚本安装，执行卸载..."

# ── 3a. 通过注册表查找所有 Node.js 卸载条目（排除工具类）──
Write-Detail "查找所有 Node.js 安装..."

$nodeEntries = Get-UninstallEntry `
    -DisplayNamePattern "^Node\.js" `
    -ExcludePattern @("Tools for Visual Studio", "Nodemon", "Node\.js Tool")

if ($nodeEntries.Count -eq 0) {
    Write-Info "注册表中未找到 Node.js 卸载条目"
} else {
    Write-Detail "找到 $($nodeEntries.Count) 个 Node.js 条目"

    foreach ($entry in $nodeEntries) {
        Write-Detail ""
        Write-Detail ">>> $($entry.DisplayName) v$($entry.DisplayVersion)"
        Write-Detail "    Publisher: $($entry.Publisher)"

        if (-not $entry.UninstallString) {
            Write-Warn "没有卸载命令，跳过"
            continue
        }

        $uninstallCmd = $entry.UninstallString
        Write-Detail "    卸载命令: $uninstallCmd"

        try {
            if ($uninstallCmd -match "msiexec") {
                # MSI 卸载
                # 提取 GUID 或 /x 参数
                if ($uninstallCmd -match '/x\s*\{?([A-Fa-f0-9\-]+)\}?') {
                    $guid = $matches[1]
                    $args = "/x {$guid} /quiet /norestart"
                } elseif ($uninstallCmd -match '/i\s*\{?([A-Fa-f0-9\-]+)\}?') {
                    $guid = $matches[1]
                    $args = "/x {$guid} /quiet /norestart"
                } else {
                    $args = ($uninstallCmd -replace 'msiexec\.exe\s*', '') + ' /quiet /norestart'
                }

                Write-Detail "    执行 msiexec $args"
                $proc = Start-Process -FilePath "msiexec.exe" `
                    -ArgumentList $args -Wait -PassThru -NoNewWindow

                if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
                    Write-OK "Node.js MSI 卸载完成 ($($entry.DisplayVersion))"
                    $nodeUninstalled = $true
                } else {
                    Write-Warn "MSI 卸载返回代码: $($proc.ExitCode)"
                }

            } elseif ($uninstallCmd -match "\.exe") {
                # EXE 卸载程序
                $proc = Start-Process -FilePath $uninstallCmd `
                    -ArgumentList "/S" -Wait -PassThru -NoNewWindow
                Write-Detail "    卸载程序执行完成 (exit: $($proc.ExitCode))"
                $nodeUninstalled = $true

            } else {
                Write-Warn "无法识别的卸载命令格式: $uninstallCmd"
            }
        } catch {
            Write-Warn "执行卸载命令时出错: $_"
        }
    }
}

# ── 3b. 等待卸载完成后再验证 ──
Start-Sleep -Seconds 3

# ── 3c. 验证并清理残留的安装目录 ──
Write-Detail ""
Write-Detail "验证 Node.js 安装目录..."

$nodeInstallDirs = @(
    "${env:ProgramFiles}\nodejs",
    "${env:ProgramFiles(x86)}\nodejs",
    "${env:LOCALAPPDATA}\Programs\nodejs"
)

# 检查所有版本（Node.js 可能安装在不同版本目录中）
foreach ($dir in $nodeInstallDirs) {
    if (Test-Path $dir) {
        # 先验证 node.exe 确实在里面（防止误删）
        $nodeExe = Join-Path $dir "node.exe"
        if (Test-Path $nodeExe) {
            Write-Detail "发现 Node.js 安装: $dir (node.exe 存在)"
            if (Remove-DirectorySafe -Path $dir -Label $dir) {
                $nodeDirsCleaned++
                $nodeUninstalled = $true
            }
        } else {
            Write-Detail "目录存在但无 node.exe: $dir（可能是空目录或残留）"
            if (Remove-DirectorySafe -Path $dir -Label "$dir (残留)") {
                $nodeDirsCleaned++
            }
        }
    }
}

# ── 3d. 清理 Node.js 注册表键 ──
$nodeRegKeys = @(
    "HKLM:\SOFTWARE\Node.js",
    "HKLM:\SOFTWARE\WOW6432Node\Node.js",
    "HKCU:\SOFTWARE\Node.js"
)
foreach ($key in $nodeRegKeys) {
    Remove-RegKeySafe -Path $key | Out-Null
}

}  # 结束 if (Test-InstalledByUs "NodeVersion") — npm 数据和 PATH 清理始终执行

# ── 3e. 清理 npm / npm-cache 全局目录 ──
$npmGlobalDirs = @(
    "${env:APPDATA}\npm",
    "${env:APPDATA}\npm-cache",
    "${env:LOCALAPPDATA}\npm-cache"
)
foreach ($dir in $npmGlobalDirs) {
    if (Test-Path $dir) {
        Write-Detail "清理 npm 数据目录: $dir"
        Remove-DirectorySafe -Path $dir -Label $dir | Out-Null
    }
}

# 清理 pnpm 目录（如果存在）
$pnpmDir = "${env:LOCALAPPDATA}\pnpm"
if (Test-Path $pnpmDir) {
    Write-Detail "清理 pnpm 数据目录: $pnpmDir"
    Remove-DirectorySafe -Path $pnpmDir -Label $pnpmDir | Out-Null
}

if ($nodeUninstalled -or $nodeDirsCleaned -gt 0) {
    Write-OK "Node.js: $nodeDirsCleaned 个目录已清理"
} elseif ($nodeEntries.Count -eq 0) {
    Write-Info "Node.js: 未检测到安装"
}

# ═══════════════════════════════════════════════════════════════
# Step 4: 清理环境变量 & PATH & 残留文件
# ═══════════════════════════════════════════════════════════════
$currentStep++

Write-Step "清理环境变量 & PATH & 残留文件" $currentStep $totalSteps

# ── 4a. 清理用户环境变量 ──
# 注意：API Key 可能以 DPAPI 加密 blob 形式存储（ANTHROPIC_AUTH_TOKEN_ENC）
#       也可能以明文形式存储（ANTHROPIC_AUTH_TOKEN，旧版本残留）
$envVarsToRemove = @(
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_AUTH_TOKEN_ENC",      # DPAPI 加密版本（install.ps1 v2+ 使用）
    "ANTHROPIC_MODEL",
    "ANTHROPIC_DEFAULT_OPUS_MODEL",
    "ANTHROPIC_DEFAULT_SONNET_MODEL",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    "CLAUDE_CODE_SUBAGENT_MODEL",
    "CLAUDE_CODE_EFFORT_LEVEL",
    "CLAUDE_CODE_ATTRIBUTION_HEADER"
)

# 敏感变量名列表 — 这些变量的值不应显示
$sensitiveVarNames = @("ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_AUTH_TOKEN_ENC")

Write-Detail "清理 Claude Code / DeepSeek 环境变量..."
$cleanedEnvCount = 0
foreach ($varName in $envVarsToRemove) {
    $currentValue = [System.Environment]::GetEnvironmentVariable($varName, "User")
    if ($null -ne $currentValue) {  # 用 $null 检查而非 truthiness，确保空字符串也能被清理
        [System.Environment]::SetEnvironmentVariable($varName, $null, "User")
        Remove-Item -Path "env:$varName" -ErrorAction SilentlyContinue
        # 敏感变量不显示值，仅显示已删除
        if ($varName -in $sensitiveVarNames) {
            Write-Detail "  已删除: `$env:$varName (敏感信息，值已隐去)"
        } else {
            Write-Detail "  已删除: `$env:$varName = $currentValue"
        }
        $cleanedEnvCount++
    }
}

if ($cleanedEnvCount -eq 0) {
    Write-Info "环境变量: 无需清理"
} else {
    Write-OK "环境变量: 已清理 $cleanedEnvCount 项"
}

# ── 4b. 清理桌面快捷方式和日志文件 ──
Write-Detail ""
Write-Detail "清理桌面文件..."

$desktopPath = [Environment]::GetFolderPath("Desktop")

# 快捷方式
$shortcuts = @(
    (Join-Path $desktopPath "Claude Code.lnk"),
    (Join-Path $desktopPath "Claude Code - DeepSeek.lnk")
)
foreach ($sc in $shortcuts) {
    if (Test-Path $sc) {
        Remove-FileSafe -Path $sc -Label $sc | Out-Null
    }
}

# 安装日志 + 临时环境变量文件
$logPatterns = @("install-log-*.txt", "install-success-*.txt", "claude-code-env*.ps1")
$cleanedLogs = 0
foreach ($pattern in $logPatterns) {
    # 使用 foreach 语句而非 ForEach-Object，避免作用域 bug（ForEach-Object 内 $cleanedLogs++ 操作的是局部变量）
    $files = Get-ChildItem -Path $desktopPath -Filter $pattern -ErrorAction SilentlyContinue
    foreach ($file in $files) {
        if (Remove-FileSafe -Path $file.FullName -Label $file.Name) {
            $cleanedLogs++
        }
    }
}

# TEMP 目录 — 清理所有 PID 模式的临时环境变量文件
$tempPatterns = @("claude-code-env-*.ps1", "claude-code-env.ps1")
foreach ($pattern in $tempPatterns) {
    $tempFiles = Get-ChildItem -Path $env:TEMP -Filter $pattern -ErrorAction SilentlyContinue
    foreach ($tf in $tempFiles) {
        Remove-FileSafe -Path $tf.FullName -Label "TEMP\$($tf.Name)" | Out-Null
    }
}

if ($cleanedLogs -gt 0) {
    Write-Detail "  已清理 $cleanedLogs 个日志文件"
}

# ── 4c. 清理 PATH 环境变量（精确匹配，白名单保护）──
Write-Detail ""
Write-Detail "清理 PATH 环境变量..."

# 需要从 PATH 中移除的精确子路径匹配规则
# ⚠️ 规则说明：只匹配确切的子路径，避免误删
$pathBlocklist = @(
    # Node.js 相关
    [regex]"(?i)\\nodejs(\\|$)",               # C:\...\nodejs\ 或 C:\...\nodejs（结尾）
    [regex]"(?i)\\node_modules\\\.bin",         # ...\node_modules\.bin
    [regex]"(?i)\\AppData\\Roaming\\npm",       # npm 全局 bin
    [regex]"(?i)\\AppData\\Local\\pnpm",        # pnpm

    # Git 相关
    [regex]"(?i)\\Git\\bin(\\|$)",              # ...\Git\bin
    [regex]"(?i)\\Git\\cmd(\\|$)",              # ...\Git\cmd
    [regex]"(?i)\\Git\\mingw64\\bin(\\|$)",     # ...\Git\mingw64\bin
    [regex]"(?i)\\Git\\usr\\bin(\\|$)",         # ...\Git\usr\bin
    [regex]"(?i)\\Git\\mingw32\\bin(\\|$)"      # ...\Git\mingw32\bin (32位)
)

# ── 白名单：绝对不会被移除的路径关键词 ──
$pathWhitelist = @(
    "Windows", "System32", "SysWOW64", "PowerShell", "Wbem",
    "Microsoft", "dotnet", "Microsoft SQL Server", "Docker"
)

function Test-ShouldRemovePath {
    param([string]$Entry)

    $normalized = $Entry.Trim().TrimEnd('\').Replace('/', '\')

    # 空条目
    if ([string]::IsNullOrWhiteSpace($normalized)) { return $false }

    # 白名单检查
    foreach ($safe in $pathWhitelist) {
        if ($normalized -match [regex]::Escape($safe)) {
            return $false
        }
    }

    # 黑名单检查
    foreach ($pattern in $pathBlocklist) {
        if ($normalized -match $pattern) {
            return $true
        }
    }

    return $false
}

function Update-PathVariable {
    param(
        [string]$Scope  # "Machine" or "User"
    )

    try {
        $currentPath = [System.Environment]::GetEnvironmentVariable("Path", $Scope)
    } catch {
        Write-Detail "  无法读取 $Scope PATH: $_"
        return @{ Removed = 0; Errors = 1 }
    }

    if ([string]::IsNullOrWhiteSpace($currentPath)) {
        return @{ Removed = 0; Errors = 0 }
    }

    $entries = $currentPath -split ';'
    $cleanEntries = [System.Collections.Generic.List[string]]::new()
    $removed = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in $entries) {
        if (Test-ShouldRemovePath -Entry $entry) {
            $removed.Add($entry)
        } else {
            $cleanEntries.Add($entry)
        }
    }

    if ($removed.Count -eq 0) {
        return @{ Removed = 0; Errors = 0 }
    }

    Write-Detail "  [$Scope PATH] 将移除 $($removed.Count) 个条目:"
    foreach ($r in $removed) {
        Write-Detail "    ❌ $r"
    }

    $newPath = $cleanEntries -join ';'

    try {
        [System.Environment]::SetEnvironmentVariable("Path", $newPath, $Scope)

        # 立即验证写入结果
        $verifyPath = [System.Environment]::GetEnvironmentVariable("Path", $Scope)
        $stillPresent = $removed | Where-Object {
            $verifyPath -and $verifyPath.ToLowerInvariant().Contains($_.ToLowerInvariant())
        }

        if ($stillPresent.Count -eq 0) {
            Write-OK "$Scope PATH: 已移除 $($removed.Count) 个条目（已验证写入注册表）"
            return @{ Removed = $removed.Count; Errors = 0 }
        } else {
            Write-Warn "$Scope PATH: $($stillPresent.Count) 个条目清除失败"
            return @{ Removed = ($removed.Count - $stillPresent.Count); Errors = $stillPresent.Count }
        }
    } catch {
        Write-Warn "$Scope PATH 写入失败: $_"
        return @{ Removed = 0; Errors = 1 }
    }
}

$machineResult = Update-PathVariable -Scope "Machine"
$userResult = Update-PathVariable -Scope "User"

$totalPathRemoved = $machineResult.Removed + $userResult.Removed
if ($totalPathRemoved -eq 0) {
    Write-Info "PATH: 未检测到需要清理的条目"
} else {
    Write-OK "PATH: 总计移除 $totalPathRemoved 个条目 (Machine: $($machineResult.Removed), User: $($userResult.Removed))"
}

# 同步当前会话的 PATH
Write-Detail ""
Write-Detail "刷新当前会话 PATH..."
try {
    $freshMachine = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $freshUser    = [System.Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = ($freshMachine, $freshUser | Where-Object { $_ } ) -join ";"
    Write-Detail "  当前会话 PATH 已刷新"
} catch {
    Write-Detail "  当前会话 PATH 刷新失败: $_"
}

# ═══════════════════════════════════════════════════════════════
# Step 5: 验证报告
# ═══════════════════════════════════════════════════════════════
$currentStep++

Write-Step "验证卸载结果" $currentStep $totalSteps

Write-Detail "──────────────────────────────────────────────"
Write-Detail "  检查安装目录是否仍然存在..."
Write-Detail "──────────────────────────────────────────────"
Write-Detail ""

# 验证函数：检查目录而非命令
function Test-InstallationRemoved {
    param(
        [string]$Name,
        [string[]]$CheckExePaths,
        [string[]]$CheckDirectories,
        [string[]]$CheckCommands = @()
    )

    $remaining = @()

    # 检查可执行文件路径
    foreach ($exePath in $CheckExePaths) {
        if (Test-Path $exePath) {
            $remaining += $exePath
        }
    }

    # 检查安装目录
    foreach ($dir in $CheckDirectories) {
        if (Test-Path $dir) {
            $remaining += $dir
        }
    }

    # 检查命令是否仍在 PATH 中
    foreach ($cmd in $CheckCommands) {
        $found = Get-Command $cmd -ErrorAction SilentlyContinue
        if ($found) {
            $remaining += "$cmd -> $($found.Source)"
        }
    }

    if ($remaining.Count -eq 0) {
        Write-OK "${Name}: 已完全移除"
    } else {
        Write-Warn "${Name}: 仍有 $($remaining.Count) 处残留"
        foreach ($r in $remaining) {
            Write-Detail "  ⚠️  $r"
        }
    }

    return ($remaining.Count -eq 0)
}

# ── 验证 Node.js ──
Test-InstallationRemoved -Name "Node.js" `
    -CheckExePaths @(
        "${env:ProgramFiles}\nodejs\node.exe",
        "${env:ProgramFiles(x86)}\nodejs\node.exe",
        "${env:LOCALAPPDATA}\Programs\nodejs\node.exe"
    ) `
    -CheckCommands @("node", "npm", "npx")

# ── 验证 Git ──
Test-InstallationRemoved -Name "Git" `
    -CheckExePaths @(
        "${env:ProgramFiles}\Git\bin\git.exe",
        "${env:ProgramFiles}\Git\cmd\git.exe",
        "${env:ProgramFiles(x86)}\Git\bin\git.exe",
        "${env:LOCALAPPDATA}\Programs\Git\bin\git.exe"
    ) `
    -CheckCommands @("git")

# ── 验证 Claude Code ──
Test-InstallationRemoved -Name "Claude Code" `
    -CheckExePaths @(
        "${env:APPDATA}\npm\claude.cmd",
        "${env:APPDATA}\npm\claude.ps1",
        "${env:ProgramFiles}\nodejs\claude.cmd"
    ) `
    -CheckDirectories @(
        "${env:APPDATA}\npm\node_modules\@anthropic-ai\claude-code"
    ) `
    -CheckCommands @("claude", "claude-code")

# ── 验证残留环境变量 ──
Write-Detail ""
$remainingVars = @()
foreach ($varName in $envVarsToRemove) {
    if ([System.Environment]::GetEnvironmentVariable($varName, "User")) {
        $remainingVars += $varName
    }
}
if ($remainingVars.Count -gt 0) {
    Write-Warn "环境变量: 仍有 $($remainingVars.Count) 项残留 — $($remainingVars -join ', ')"
    Write-Detail "  可手动删除：系统属性 → 环境变量 → 用户变量"
} else {
    Write-OK "环境变量: 全部清理完毕"
}

# ── my-project 目录及启动器脚本清理 ──
Write-Detail ""
$projectDir = Join-Path $desktopPath "my-project"
if (Test-Path $projectDir) {
    # 先清理启动器脚本
    $launcherPath = Join-Path $projectDir "claude-launcher.ps1"
    if (Test-Path $launcherPath) {
        Remove-FileSafe -Path $launcherPath -Label "claude-launcher.ps1" | Out-Null
    }

    # 检查目录是否为空，为空则自动删除
    $remainingFiles = Get-ChildItem -Path $projectDir -ErrorAction SilentlyContinue
    if (-not $remainingFiles -or $remainingFiles.Count -eq 0) {
        try {
            Remove-Item -Path $projectDir -Force -ErrorAction Stop
            Write-OK "my-project 目录已自动删除（已清空）"
        } catch {
            Write-Warn "my-project 目录无法自动删除: $_"
        }
    } else {
        Write-Warn "桌面 my-project 目录仍有 $($remainingFiles.Count) 个文件"
        Write-Detail "  $projectDir"
        Write-Detail "  如不再需要，请手动删除："
        Write-Detail "  Remove-Item -Path '$projectDir' -Recurse -Force"
    }
}

# ── 清理安装标记 ──
if ($script:HasSentinel) {
    try {
        Remove-Item -Path $script:SentinelKey -Recurse -Force -ErrorAction Stop
        Write-Detail "安装标记已清理: $($script:SentinelKey)"
    } catch {
        Write-Detail "安装标记清理失败: $_"
    }
}

# ═══════════════════════════════════════════════════════════════
# 汇总报告
# ═══════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  🎉 卸载完成！汇总报告" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

foreach ($line in $script:UninstallReport) {
    Write-Host "  $line" -ForegroundColor White
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  💡 建议" -ForegroundColor Cyan
Write-Host "────────────────────────────────────────────────────────────" -ForegroundColor Gray
Write-Host "  1. 重启计算机以清除所有内存中的环境变量" -ForegroundColor White
Write-Host "  2. 打开"系统属性 → 环境变量"确认 PATH 已清理干净" -ForegroundColor White
Write-Host "  3. 如仍有残留目录，重启后手动删除" -ForegroundColor White
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan

Read-Host "按 Enter 键退出..."
