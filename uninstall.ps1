# Claude Code + DeepSeek 一键卸载脚本 (uninstall.ps1)
# 卸载 Node.js, Git, Claude Code, 清理环境变量、残留文件及桌面快捷方式
#Requires -Version 5.1

# -DryRun: 干跑模式。所有破坏性动作（删目录 / 删文件 / 删注册表键 / 改写 PATH /
#          终止进程）只打印不执行，用于在真机上安全地核验"本次会删掉什么"。
#          干跑模式不需要管理员权限，也不触发 UAC。
param([switch]$DryRun)

$ErrorActionPreference = "Stop"

# ═══════════════════════════════════════════════════════════════
# 输出编码 —— 简体中文 Windows 的控制台默认代码页是 936(GBK)。
# GBK 里既没有 emoji（✅ ❌ ⚠️ 🔒 …）也没有 U+2713(✓)，PowerShell 5.1
# 会把它们输出成 '?'，让满屏提示变成问号海。
# 这里在启动时把控制台切到 UTF-8(65001)，退出前恢复原来的代码页。
# 用 Win32 API 直接改控制台代码页：只设 [Console]::OutputEncoding 在
# .NET Framework 下不保证同步改动控制台本身，会出现"编码对了、代码页没对"
# 从而中文反而乱码的情况。
#
# ⚠️ 已知边界：输出被【另一个进程捕获】时（管道 / CI / 存进 PowerShell 变量），
#    本脚本写出的是 UTF-8 字节；捕获方若按自己的 GBK 去解码就会满屏乱码。
#    捕获端先执行这一行即可：
#        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
#    双击运行不受影响 —— 而那才是本脚本的主要使用方式。
#    详见 install.ps1 同段落里对「为什么不按是否重定向来切换编码」的说明。
# ═══════════════════════════════════════════════════════════════
$script:OriginalCodePage = $null
try {
    if (-not ('CCInstaller.ConsoleCodePage' -as [type])) {
        Add-Type -Namespace 'CCInstaller' -Name 'ConsoleCodePage' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern uint GetConsoleOutputCP();
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern bool SetConsoleOutputCP(uint wCodePageID);
'@
    }
    $script:OriginalCodePage = [CCInstaller.ConsoleCodePage]::GetConsoleOutputCP()
    if ($script:OriginalCodePage -ne 65001) {
        [void][CCInstaller.ConsoleCodePage]::SetConsoleOutputCP(65001)
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    }
} catch {
    # 改不动就保持原样 —— 顶多还是显示 '?'，绝不能让脚本因此失败
    $script:OriginalCodePage = $null
}

# 恢复控制台代码页。所有 exit 路径都应经过它。
function Restore-ConsoleCodePage {
    if ($script:OriginalCodePage -and $script:OriginalCodePage -ne 65001) {
        try {
            [void][CCInstaller.ConsoleCodePage]::SetConsoleOutputCP($script:OriginalCodePage)
            [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding([int]$script:OriginalCodePage)
        } catch { }
    }
}

$script:DryRun = [bool]$DryRun
# 是否已获得用户对"删除非本脚本安装的软件"的明确授权（见 Test-InstalledByUs）
$script:UninstallUnconfirmed = $false
$script:UninstallReport = [System.Collections.Generic.List[string]]::new()

# 全局 trap —— 必须定义在任何运行时语句之前。
# 之前的版本没有 trap：以 $ErrorActionPreference = "Stop" 运行时一旦中途抛异常，
# 脚本会直接中止，连结尾的验证报告都不会执行，用户只能面对「半清理状态」却没有任何结论。
#
# 注意：trap 内只使用已经初始化的变量和内置 cmdlet，不要调用后面才定义的函数
# （早期错误时会因函数尚未定义而二次抛错，把原始错误掩盖掉）。
trap {
    $errMsg = $_.Exception.Message
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host "  ❌ 卸载过程中发生异常，已中止" -ForegroundColor Red
    Write-Host "     $errMsg" -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Red

    # 回放已完成的操作，避免用户不知道"到底清掉了什么"
    if ($script:UninstallReport -and $script:UninstallReport.Count -gt 0) {
        Write-Host "  本次已执行的操作：" -ForegroundColor White
        foreach ($reportLine in $script:UninstallReport) {
            Write-Host "    $reportLine" -ForegroundColor Gray
        }
    }
    Write-Host ""
    if ($script:DryRun) {
        Write-Host "  （干跑模式：未修改任何内容）" -ForegroundColor Magenta
    } else {
        Write-Host "  建议：重新运行本脚本继续清理，或到「设置 → 应用」手动检查残留。" -ForegroundColor Yellow
    }
    Restore-ConsoleCodePage
    exit 1
}

# ============================================================
# 自动获取管理员权限
# ============================================================
function Test-IsAdmin {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal   = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin) -and -not $script:DryRun) {
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
    if ($script:DryRun) { $argList += "-DryRun" }   # 透传干跑开关

    try {
        $process = Start-Process PowerShell -Verb RunAs -ArgumentList $argList -Wait -PassThru
    } catch {
        # 用户在 UAC 弹窗点了「取消」。这是正常操作，不是故障，不要触发全局 trap 弹出报错
        Write-Host ""
        Write-Host "  已取消提权，未做任何修改。" -ForegroundColor Yellow
        Restore-ConsoleCodePage
        exit 1
    }
    Restore-ConsoleCodePage
    exit $process.ExitCode
}

if ($script:DryRun) {
    Write-Host "=== 干跑模式 (-DryRun)：只打印将要执行的操作，不会修改任何内容 ===" -ForegroundColor Magenta
    Write-Host "    干跑不需要管理员权限，因此不触发 UAC 提权。" -ForegroundColor DarkGray
} else {
    Write-Host "=== 管理员权限已确认 ===" -ForegroundColor Green
}
Write-Host ""

# ============================================================
# 架构检测：32位进程在64位系统上自动切换到原生64位
# ============================================================
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess -and -not $script:DryRun) {
    Write-Host "⚠️ 正在切换到 64 位 PowerShell..." -ForegroundColor Yellow
    $argList = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`""
    )
    $process = Start-Process -FilePath "$env:SystemRoot\SysNative\WindowsPowerShell\v1.0\powershell.exe" `
        -Verb RunAs -ArgumentList $argList -Wait -PassThru
    Restore-ConsoleCodePage
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
}

# ── 哨兵是否「可信」──
# 只有 install.ps1 写入的显式布尔标记（XxxInstalledByUs）才能区分
# 「本脚本安装的」和「用户自己预装的」。旧版哨兵只记录 NodeVersion / GitVersion
# 这类「检测到的版本号」，无论软件是谁装的都会写入 —— 那种格式不可信，
# 一旦据此删除，就会把用户预装的软件连根拔掉。
$script:HasTrustedMarkers = $script:InstalledByUs.ContainsKey('NodeInstalledByUs') -or
                            $script:InstalledByUs.ContainsKey('GitInstalledByUs') -or
                            $script:InstalledByUs.ContainsKey('ClaudeCodeInstalledByUs')

if ($script:HasTrustedMarkers) {
    Write-Host "  ✅ 安装标记完整：将仅卸载由本安装脚本部署的软件。" -ForegroundColor Green
    Write-Host "     标记为 0 的组件（用户预装）会被保留。" -ForegroundColor Green
} else {
    if ($script:HasSentinel) {
        Write-Host "  ⚠️  安装标记为旧格式：只记录了版本号，无法区分预装与自装。" -ForegroundColor Yellow
    } else {
        Write-Host "  ⚠️  未检测到安装标记：无法确认哪些软件由本安装脚本部署。" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "  为避免误删你自己的软件，默认只做下列「无风险清理」：" -ForegroundColor White
    Write-Host "    · Claude Code / DeepSeek 相关环境变量" -ForegroundColor Gray
    Write-Host "    · 桌面快捷方式、安装日志、临时文件" -ForegroundColor Gray
    Write-Host "    · PATH 中指向本脚本安装目录的条目（不影响其他软件）" -ForegroundColor Gray
    Write-Host "    · 保留所有 Node.js / Git 安装目录" -ForegroundColor Gray
    Write-Host "    · 保留你的用户数据（含 ~/.claude 会话历史与配置）" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  如果确实要连同下列内容一起移除，需要显式授权：" -ForegroundColor Yellow
    Write-Host "    · C:\Program Files\nodejs 等 Node.js 安装目录" -ForegroundColor DarkGray
    Write-Host "    · C:\Program Files\Git 等 Git 安装目录" -ForegroundColor DarkGray
    Write-Host "    · HKLM\SOFTWARE\Node.js、GitForWindows 注册表键" -ForegroundColor DarkGray
    Write-Host ""
    if ($script:DryRun) {
        Write-Host "  [干跑] 此处本会要求输入确认；干跑模式按「未授权」处理（最保守）。" -ForegroundColor Magenta
        $script:UninstallUnconfirmed = $false
    } else {
        Write-Host "  请输入 uninstall（全词）后回车以授权；直接回车 = 只做无风险清理：" -ForegroundColor Red
        $confirmAll = Read-Host "  请输入"
        if ($confirmAll -eq 'uninstall') {
            $script:UninstallUnconfirmed = $true
            Write-Host "  ⚠️  已授权：将卸载全部检测到的 Node.js / Git。" -ForegroundColor Red
        } else {
            Write-Host "  ✅ 已选择保守路径：保留 Node.js / Git。" -ForegroundColor Green
        }
    }
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

    # 无哨兵 / 旧格式哨兵 → 无法确认 → 不删（fail-close）。
    # 仅当用户在开头显式输入 uninstall 全词授权后，才允许进入删除分支。
    if (-not $script:HasTrustedMarkers) { return $script:UninstallUnconfirmed }

    # 可信哨兵 → 只看安装脚本写入的显式布尔标记，不再看版本号字符串。
    # 注意：哨兵值经注册表读写后是字符串，而 [bool]"0" 在 PowerShell 里等于 $true，
    # 因此必须做字符串比较，不能用强制类型转换。
    if (-not $script:InstalledByUs.ContainsKey($ComponentKey)) { return $false }
    $val = "$($script:InstalledByUs[$ComponentKey])".Trim()
    return ($val -eq '1' -or $val -eq 'true')
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

# 干跑专用输出 —— 带统一前缀，并写入汇总报告，便于一眼扫出「本来会做什么」
function Write-DryRun {
    param([string]$Msg)
    Write-Host "  [干跑] $Msg" -ForegroundColor Magenta
    $script:UninstallReport.Add("[干跑] $Msg")
}

# 安全删除目录：先杀占用进程，再删除，失败时记录而非静默
function Remove-DirectorySafe {
    param(
        [string]$Path,
        [string]$Label = $Path
    )

    if (-not (Test-Path $Path)) { return $false }

    # 干跑：只报告，不删目录、也不终止进程
    if ($script:DryRun) {
        Write-DryRun "[将删除目录] $Path"
        return $true
    }

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

    # 干跑：只报告，不删文件
    if ($script:DryRun) {
        Write-DryRun "[将删除文件] $Path"
        return $true
    }

    try {
        Remove-Item -Path $Path -Force -ErrorAction Stop
        Write-Detail "  已删除: $Label"
        return $true
    } catch {
        # 失败必须进汇总报告（Write-Detail 不会写入报告，用户就看不到）
        Write-Warn "无法删除: $Label — $_"
        return $false
    }
}

# 安全删除注册表键
function Remove-RegKeySafe {
    param([string]$Path)

    if (-not (Test-Path $Path)) { return $false }

    # 干跑：只报告，不删注册表键
    if ($script:DryRun) {
        Write-DryRun "[将删除注册表键] $Path"
        return $true
    }

    try {
        Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
        Write-Detail "  清理注册表: $Path"
        return $true
    } catch {
        # 失败必须进汇总报告（Write-Detail 不会写入报告，用户就看不到）
        Write-Warn "无法清理注册表: $Path — $_"
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
    # ⚠️ 查 HKCU 是为了让用户级安装（per-user 的 Node.js 装在
    #    %LOCALAPPDATA%\Programs\nodejs）也能被发现。
    #    但 HKCU 里的内容是【不可信输入】：同账户的普通进程可以往里塞一条
    #    DisplayName="Git"、UninstallString="C:\Users\me\evil.exe" 的伪造条目，
    #    而本脚本是以管理员身份运行的 —— 照单执行就等于给攻击者一条提权路径。
    #    所以每个条目都带上 Source，执行前必须过 Test-UninstallEntryExecutableSafe。
    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    )

    foreach ($regPath in $regPaths) {
        if (-not (Test-Path $regPath)) { continue }

        $source = if ($regPath.StartsWith('HKCU:')) { 'HKCU' } else { 'HKLM' }

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
                    Source          = $source      # 'HKLM' 或 'HKCU' —— 决定能不能执行，见下
                }
            } catch { }
        }
    }

    return $results
}

# ── 路径是否位于「普通用户不可写」的受保护目录 ──
# 用来回答一个问题：这个可执行文件是不是普通用户能替换掉的？
# 能替换 → 不能以管理员身份执行它。
function Test-PathIsProtected {
    param([string]$Path)

    if (-not $Path) { return $false }

    $protectedRoots = @(
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:ProgramW6432,
        $env:SystemRoot
    ) | Where-Object { $_ }

    foreach ($root in $protectedRoots) {
        $rootWithSep = if ($root.EndsWith('\')) { $root } else { "$root\" }
        if ($Path.StartsWith($rootWithSep, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

# ── 从 UninstallString 里解析出可执行文件路径 ──
# 解析不出来时返回 $null —— 调用方必须把它当成「不安全」。
function Get-UninstallExecutablePath {
    param([string]$CommandLine)

    if (-not $CommandLine) { return $null }
    $cmd = $CommandLine.Trim()

    # 加了引号的路径：最常见也最可靠
    if ($cmd -match '^\s*"([^"]+)"') { return $matches[1].Trim() }

    # 没加引号：可能是 "C:\Program Files\...\unins000.exe /S" 这种含空格的路径。
    # 逐段累积、找到第一个真实存在的文件为止；找不到就返回 $null（视为不安全）。
    $candidate = ''
    foreach ($part in ($cmd -split '\s+')) {
        $candidate = if ($candidate) { "$candidate $part" } else { $part }
        if (Test-Path -LiteralPath $candidate -ErrorAction SilentlyContinue) {
            return $candidate
        }
    }
    return $null
}

# ── 能不能执行这个卸载条目的 UninstallString ──
# 判据不是「它在哪个注册表分支」，而是「它指向的程序普通用户能不能替换」：
#   · HKLM 条目：写 HKLM 本身就需要管理员，不构成提权 → 允许
#   · HKCU 条目：内容可被任意同账户进程伪造 → 只有指向受保护目录里的程序
#     才允许执行；否则只报告，不执行（安装目录仍会照常清理）
function Test-UninstallEntryExecutableSafe {
    param([PSCustomObject]$Entry)

    if ($Entry.Source -eq 'HKLM') { return $true }

    $exePath = Get-UninstallExecutablePath -CommandLine $Entry.UninstallString
    if (-not $exePath) { return $false }

    return (Test-PathIsProtected -Path $exePath)
}

# ═══════════════════════════════════════════════════════════════
# Step 0: 终止所有相关进程（在任何卸载操作之前）
# ═══════════════════════════════════════════════════════════════

$totalSteps = 5
$currentStep = 0

Write-Step "终止相关进程" $currentStep $totalSteps

# 只要终止这些名字的进程 —— 但"名字匹配"只是缩小扫描范围，
# 真正的判据是下面那个「可执行文件位于将要删除的目录里」的路径检查。
$processNamesToCheck = @(
    # Node.js 相关
    "node", "npm", "npx",
    # Git 相关
    "git", "bash", "sh",
    # 注意: ssh-agent / gpg-agent 是系统级服务，被 Git 之外的很多工具使用，
    # 不在此处终止，避免破坏用户的 SSH 密钥会话和 GPG 签名操作
    # Claude Code 相关
    "claude",
    # Git GUI 工具
    "gitk", "git-gui", "git-credential-manager"
)

$killedCount = 0

# 只有在「确实要删除 Node.js / Git 安装目录」时，才有必要终止相关进程。
# 否则（例如用户没授权、只做无风险清理）按名字裸杀 node/git/bash 会误伤无关程序
# —— 正在跑的 dev server、其他软件内置的 Node、以及用户的 Git Bash 会话。
$willRemoveNode = Test-InstalledByUs "NodeInstalledByUs"
$willRemoveGit  = Test-InstalledByUs "GitInstalledByUs"

# ── 本次真正要删除的安装目录 ──
# 进程终止只针对「可执行文件就在这些目录里」的进程 —— 它们才会占用文件句柄
# 导致删除失败。按【进程名】裸杀是错误的：用户正在用的 Git Bash（bash.exe）、
# 任意来源的 node（开发中的 dev server、其他软件内置的 Node）、以及正在运行的
# Claude Code 自身都会被误杀，而它们和我们要删的目录毫无关系。
# Remove-DirectorySafe 早就在用正确的「路径前缀匹配」，Step 0 应该复用同一判据。
$targetInstallDirs = @()
if ($willRemoveNode) {
    $targetInstallDirs += @(
        "${env:ProgramFiles}\nodejs",
        "${env:ProgramFiles(x86)}\nodejs",
        "${env:LOCALAPPDATA}\Programs\nodejs"
    )
}
if ($willRemoveGit) {
    $targetInstallDirs += @(
        "${env:ProgramFiles}\Git",
        "${env:ProgramFiles(x86)}\Git",
        "${env:LOCALAPPDATA}\Programs\Git",
        "C:\Git"
    )
}

if ($script:DryRun) {
    Write-DryRun "[将终止相关进程] 仅限可执行文件位于下列目录内的进程："
    foreach ($dir in $targetInstallDirs) { Write-DryRun "             $dir" }
}
elseif (-not ($willRemoveNode -or $willRemoveGit)) {
    Write-Info "本次不会删除 Node.js / Git 安装目录，跳过终止进程（避免误杀无关程序）"
}
else {
    foreach ($procName in $processNamesToCheck) {
        $procs = @(Get-Process -Name $procName -ErrorAction SilentlyContinue)
        foreach ($p in $procs) {
            # 取不到路径说明是保护进程 / 其他会话，直接跳过
            $procPath = $null
            try { $procPath = $p.Path } catch { continue }
            if (-not $procPath) { continue }

            $inTargetDir = $false
            foreach ($dir in $targetInstallDirs) {
                $dirWithSep = if ($dir.EndsWith('\')) { $dir } else { "$dir\" }
                if ($procPath.StartsWith($dirWithSep, [StringComparison]::OrdinalIgnoreCase)) {
                    $inTargetDir = $true
                    break
                }
            }
            if (-not $inTargetDir) {
                Write-Detail "  跳过无关进程: $procName (PID: $($p.Id)) $procPath"
                continue
            }

            try {
                $p.Kill()
                # 等待进程完全退出，防止文件句柄残留
                if (-not $p.WaitForExit(3000)) {
                    Write-Detail "  进程未在 3s 内退出: $procName (PID: $($p.Id))"
                }
                Write-Detail "已终止进程: $procName (PID: $($p.Id)) $procPath"
                $killedCount++
            } catch { }
        }
    }

    if ($killedCount -gt 0) {
        Write-OK "已终止 $killedCount 个相关进程"
        Start-Sleep -Seconds 2
    } else {
        Write-Info "没有发现需要终止的进程"
    }
}

# ═══════════════════════════════════════════════════════════════
# Step 1: 卸载 Claude Code (npm)
# ═══════════════════════════════════════════════════════════════
$currentStep++

Write-Step "卸载 Claude Code" $currentStep $totalSteps

# ── 解析「该用哪个 npm」──
# 直接取 Get-Command npm 是有坑的：装了 nvm / Volta / fnm / scoop，或者装了
# 自带 node 的软件（各种 IDE、工具链）时，PATH 里排在前面的是「别人的 npm」。
# 后果有两层：
#   · 预检会得出"没装 claude-code"的错误结论（其实装在另一个全局前缀里）
#   · npm uninstall -g 会打到错误的前缀上，等于什么也没卸
# 做法：把候选 npm 都列出来，读各自的全局前缀，优先选「前缀下真的存在
# @anthropic-ai/claude-code」的那个；一个都没有才退回 PATH 里的那个，
# 并把路径与前缀都打印出来，让结论可核对。
#
# 注：`npm prefix -g` 是只读查询，不修改任何东西，干跑下执行它不违反干跑承诺。
function Get-NpmGlobalPrefix {
    param([string]$NpmPath)
    if (-not $NpmPath) { return $null }
    try {
        $prefix = & $NpmPath prefix -g 2>$null | Select-Object -First 1
        if ($prefix) { return "$prefix".Trim() }
    } catch { }
    return $null
}

function Resolve-NpmForClaudeCode {
    $candidates = [System.Collections.Generic.List[string]]::new()

    $onPath = Get-Command npm -ErrorAction SilentlyContinue
    if ($onPath -and $onPath.Source) { $candidates.Add($onPath.Source) }

    foreach ($p in @(
        "${env:ProgramFiles}\nodejs\npm.cmd",
        "${env:ProgramFiles(x86)}\nodejs\npm.cmd",
        "${env:APPDATA}\npm\npm.cmd",
        "${env:LOCALAPPDATA}\Programs\nodejs\npm.cmd"
    )) {
        if ((Test-Path $p) -and ($p -notin $candidates)) { $candidates.Add($p) }
    }

    if ($candidates.Count -eq 0) { return $null }

    $withPackage = $null
    $fallback    = $null
    foreach ($cand in $candidates) {
        $prefix = Get-NpmGlobalPrefix -NpmPath $cand
        Write-Detail "  候选 npm: $cand  (全局前缀: $(if ($prefix) { $prefix } else { '未知' }))"
        if (-not $fallback) { $fallback = $cand }
        if ($prefix) {
            $pkgDir = Join-Path $prefix "node_modules\@anthropic-ai\claude-code"
            if (Test-Path $pkgDir) {
                $withPackage = $cand
                break
            }
        }
    }

    if ($withPackage) {
        Write-Detail "  选用（其全局前缀下确有 @anthropic-ai/claude-code）: $withPackage"
        return $withPackage
    }

    Write-Detail "  ⚠️ 没有一个候选 npm 的全局前缀下找到 @anthropic-ai/claude-code"
    return $fallback
}

# 查找 npm 可执行文件
$npmPath = Resolve-NpmForClaudeCode

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

    if ($ccInstalled -and $script:DryRun) {
        Write-DryRun "[将执行] npm uninstall -g @anthropic-ai/claude-code"
    }
    elseif ($ccInstalled) {
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

# ── 清理 Claude Code 配置和数据目录（用户目录下）──
# ⚠️ 这两个目录装的是「用户自己的东西」：会话历史、settings.json、自定义 agents/commands/skills。
#    它的价值高于 .gitconfig，因此享受与 .gitconfig 同等的待遇：逐项确认，默认保留。
#    注意：即使 Claude Code 是本脚本装的，~/.claude 里的内容仍是用户资产，
#    所以这里不按哨兵放行，一律要求确认。
Write-Detail "Claude Code 用户数据目录检测..."
$claudeUserDirs = @(
    "$env:USERPROFILE\.claude",
    "$env:USERPROFILE\.claude-code"
)
foreach ($dir in $claudeUserDirs) {
    if (-not (Test-Path $dir)) { continue }

    if ($script:DryRun) {
        Write-DryRun "[需人工确认，干跑默认保留] $dir"
        continue
    }

    # 先统计里面有什么，让用户知道自己要放弃多少东西
    $sizeMB = 0; $sessions = 0; $agents = 0; $commands = 0
    try {
        $sumBytes = (Get-ChildItem -Path $dir -Recurse -Force -File -ErrorAction SilentlyContinue |
                     Measure-Object -Property Length -Sum).Sum
        if (-not $sumBytes) { $sumBytes = 0 }
        $sizeMB   = [math]::Round($sumBytes / 1MB, 1)
        $sessions = @(Get-ChildItem -Path (Join-Path $dir "projects") -Recurse -Filter *.jsonl -File -ErrorAction SilentlyContinue).Count
        $agents   = @(Get-ChildItem -Path (Join-Path $dir "agents")   -File -ErrorAction SilentlyContinue).Count
        $commands = @(Get-ChildItem -Path (Join-Path $dir "commands") -File -ErrorAction SilentlyContinue).Count
    } catch { }

    Write-Host "    $dir" -ForegroundColor White
    Write-Host "      体积: $sizeMB MB　会话记录: $sessions 个　自定义 agents: $agents　自定义 commands: $commands" -ForegroundColor Gray
    Write-Host "    ⚠️  此目录含你的 Claude Code 会话历史、设置与自定义内容，删除后无法恢复。" -ForegroundColor Yellow
    Write-Host "    默认保留。是否删除？[y/N]" -ForegroundColor Red
    $confirm = Read-Host "    请输入"
    if ($confirm -eq 'y' -or $confirm -eq 'Y') {
        if (Remove-DirectorySafe -Path $dir -Label $dir) {
            Write-Warn "已删除用户数据目录: $dir（会话历史与配置已不可恢复）"
        }
    } else {
        Write-Info "已保留: $dir"
    }
}

# ═══════════════════════════════════════════════════════════════
# Step 2: 卸载 Git for Windows（含 Credential Manager + 用户配置）
# ═══════════════════════════════════════════════════════════════
$currentStep++

Write-Step "卸载 Git for Windows" $currentStep $totalSteps

# 哨兵检查：只有确认 Git 是由本脚本安装的，才执行卸载
# 计数器必须在分支外初始化 —— 跳过卸载分支时它仍是 $null，
# 会让后面 $gitDirsCleaned -eq 0 恒为 $false，汇总提示失效。
$gitDirsCleaned = 0
if (-not (Test-InstalledByUs "GitInstalledByUs")) {
    Write-Info "Git: 未确认由本脚本安装，跳过卸载（保留 Git 及其注册表键）。"
    $gitUninstalled = $false
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

    if ($script:DryRun) {
        Write-DryRun "[将运行卸载程序] $($entry.DisplayName) v$($entry.DisplayVersion)"
        continue
    }

    # 安全闸：见 Test-UninstallEntryExecutableSafe —— HKCU 卸载表里的字符串
    # 是可被任意同账户进程伪造的不可信输入，不能直接以管理员身份执行
    if (-not (Test-UninstallEntryExecutableSafe -Entry $entry)) {
        Write-Warn "$($entry.DisplayName): 条目来自 $($entry.Source) 且指向用户可写位置，出于安全不予执行（仅报告）"
        Write-Detail "  注册表位置: $($entry.RegistryPath)"
        Write-Detail "  卸载命令  : $($entry.UninstallString)"
        Write-Detail "  如需卸载它，请到「设置 → 应用」手动操作。"
        continue
    }

    if ($entry.UninstallString) {
        $uninstallCmd = $entry.UninstallString.Trim('"')
        Write-Detail "卸载命令: $uninstallCmd"

        if ($uninstallCmd -match "msiexec") {
            # 注意：变量名不要用 $args —— 那是 PowerShell 的自动变量，覆盖它会遮蔽脚本自身参数
            $msiArgs = $uninstallCmd -replace 'msiexec\.exe\s*', ''
            if ($msiArgs -notmatch '/quiet') { $msiArgs += ' /quiet /norestart' }
            $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru
        } else {
            $proc = Start-Process -FilePath $uninstallCmd -ArgumentList "/VERYSILENT /NORESTART /SUPPRESSMSGBOXES" -Wait -PassThru
        }

        if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
            Write-Detail "  卸载程序完成 (exit: $($proc.ExitCode))"
        } else {
            Write-Warn "Git Credential Manager 卸载器返回非零退出码: $($proc.ExitCode)"
        }
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

    if ($script:DryRun) {
        Write-DryRun "[将运行卸载程序] $($entry.DisplayName) v$($entry.DisplayVersion)"
        continue
    }

    # 安全闸：见 Test-UninstallEntryExecutableSafe
    if (-not (Test-UninstallEntryExecutableSafe -Entry $entry)) {
        Write-Warn "$($entry.DisplayName): 条目来自 $($entry.Source) 且指向用户可写位置，出于安全不予执行（仅报告）"
        Write-Detail "  注册表位置: $($entry.RegistryPath)"
        Write-Detail "  卸载命令  : $($entry.UninstallString)"
        Write-Detail "  安装目录仍会照常清理；如需卸载它，请到「设置 → 应用」手动操作。"
        continue
    }

    if (-not $entry.UninstallString) { continue }

    $uninstallCmd = $entry.UninstallString.Trim('"')
    Write-Detail "卸载命令: $uninstallCmd"

    try {
        if ($uninstallCmd -match "unins\d+\.exe" -or $uninstallCmd -match "uninstall\.exe") {
            # Inno Setup 卸载程序
            $proc = Start-Process -FilePath $uninstallCmd `
                -ArgumentList "/VERYSILENT /NORESTART /SUPPRESSMSGBOXES" `
                -Wait -PassThru -NoNewWindow
            if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
                Write-Detail "Inno Setup 卸载完成 (exit: $($proc.ExitCode))"
            } else {
                Write-Warn "Git 卸载器（Inno Setup）返回非零退出码: $($proc.ExitCode)"
            }
        } else {
            # 通用卸载程序
            $proc = Start-Process -FilePath $uninstallCmd `
                -ArgumentList "/S" `
                -Wait -PassThru -NoNewWindow
            if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
                Write-Detail "卸载程序执行完成 (exit: $($proc.ExitCode))"
            } else {
                Write-Warn "Git 卸载程序返回非零退出码: $($proc.ExitCode)"
            }
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

    if ($script:DryRun) {
        Write-DryRun "[将运行卸载程序] $unPath /VERYSILENT /NORESTART /SUPPRESSMSGBOXES"
        continue
    }

    try {
        $proc = Start-Process -FilePath $unPath `
            -ArgumentList "/VERYSILENT /NORESTART /SUPPRESSMSGBOXES" `
            -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
            Write-Detail "卸载完成 (exit: $($proc.ExitCode))"
        } else {
            Write-Warn "卸载器 $unPath 返回非零退出码: $($proc.ExitCode)"
        }
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

}  # 结束 if (Test-InstalledByUs "GitInstalledByUs")

# ── 2e. 清理 Git 注册表键（仅在确认卸载了本脚本安装的 Git 时才做）──
# HKLM\SOFTWARE\GitForWindows 是 Git for Windows 自身用来定位安装目录的配置键。
# 如果 Git 是用户预装的（我们按哨兵保留了它），删这个键会破坏 Git 自己的配置查找，
# 所以必须跟着哨兵判断走。
# 另外：GitExtensions 是「另一个产品」（Git Extensions 图形客户端）的键，
# 本脚本从未安装过它，不该由本脚本删除。
if (Test-InstalledByUs "GitInstalledByUs") {
    $gitRegKeys = @(
        "HKLM:\SOFTWARE\GitForWindows",
        "HKLM:\SOFTWARE\WOW6432Node\GitForWindows",
        "HKCU:\SOFTWARE\GitForWindows"
    )
    foreach ($key in $gitRegKeys) {
        Remove-RegKeySafe -Path $key | Out-Null
    }
} else {
    Write-Info "Git: 未确认由本脚本安装，保留 GitForWindows 注册表键"
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
        if ($script:DryRun) {
            Write-DryRun "[需人工确认，干跑默认保留] $cfg"
            continue
        }
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
    # 计数在干跑下也会加（Remove-DirectorySafe 干跑返回 $true），
    # 所以这里必须按模式分开说，否则干跑会报"已卸载"、随后验证步骤又说"仍有残留"。
    if ($script:DryRun) {
        Write-DryRun "[将清理] Git: $gitDirsCleaned 个安装目录（实际运行时才会删）"
    } else {
        Write-OK "Git: 已卸载 ($gitDirsCleaned 个目录已清理)"
    }
}

# ═══════════════════════════════════════════════════════════════
# Step 3: 卸载 Node.js（加强版：移除 WMI 方法，多版本处理，验证安装目录）
# ═══════════════════════════════════════════════════════════════
$currentStep++

Write-Step "卸载 Node.js" $currentStep $totalSteps

$nodeUninstalled = $false
$nodeDirsCleaned = 0

# 哨兵检查：只有确认 Node.js 是由本脚本安装的，才执行卸载
if (-not (Test-InstalledByUs "NodeInstalledByUs")) {
    Write-Info "Node.js: 未确认由本脚本安装，跳过卸载程序调用（保留 Node.js 及注册表键）。"
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

        if ($script:DryRun) {
            Write-DryRun "[将运行卸载程序] $($entry.DisplayName) v$($entry.DisplayVersion)"
            continue
        }

        # 安全闸：见 Test-UninstallEntryExecutableSafe
        if (-not (Test-UninstallEntryExecutableSafe -Entry $entry)) {
            Write-Warn "$($entry.DisplayName): 条目来自 $($entry.Source) 且指向用户可写位置，出于安全不予执行（仅报告）"
            Write-Detail "  注册表位置: $($entry.RegistryPath)"
            Write-Detail "  卸载命令  : $($entry.UninstallString)"
            Write-Detail "  安装目录仍会照常清理；如需卸载它，请到「设置 → 应用」手动操作。"
            continue
        }

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
                # 变量名不要用 $args —— 那是 PowerShell 的自动变量，
                # 覆盖它会遮蔽脚本自身的参数（本文件顶部就用 $args 透传过命令行）。
                if ($uninstallCmd -match '/x\s*\{?([A-Fa-f0-9\-]+)\}?') {
                    $guid = $matches[1]
                    $msiArgs = "/x {$guid} /quiet /norestart"
                } elseif ($uninstallCmd -match '/i\s*\{?([A-Fa-f0-9\-]+)\}?') {
                    $guid = $matches[1]
                    $msiArgs = "/x {$guid} /quiet /norestart"
                } else {
                    $msiArgs = ($uninstallCmd -replace 'msiexec\.exe\s*', '') + ' /quiet /norestart'
                }

                Write-Detail "    执行 msiexec $msiArgs"
                $proc = Start-Process -FilePath "msiexec.exe" `
                    -ArgumentList $msiArgs -Wait -PassThru -NoNewWindow

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
                # 不能无条件置成功 —— 退出码非零时必须如实上报
                if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
                    Write-Detail "    卸载程序执行完成 (exit: $($proc.ExitCode))"
                    $nodeUninstalled = $true
                } else {
                    Write-Warn "Node.js 卸载器返回非零退出码: $($proc.ExitCode)"
                }

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

}  # 结束 if (Test-InstalledByUs "NodeInstalledByUs")

# ── 3e. 清理 npm 缓存目录 ──
# ⚠️ 不要删 %APPDATA%\npm —— 那是 npm 的「全局前缀」，是所有 npm install -g 装的东西的家，
#    并不是 Claude Code 的残留。删它会连带抹掉用户的其他全局工具（例如 opencode、@openai）。
#    Claude Code 的残留已经在本节之前按 @anthropic-ai 子树精准清理过（见上面的 $claudeResidualDirs）。
#    同理不要删 %LOCALAPPDATA%\pnpm（那是 pnpm 的全局目录）。
#    这里只清理纯缓存：删掉无副作用，下次安装会自动重建。
$npmCacheDirs = @(
    "${env:APPDATA}\npm-cache",
    "${env:LOCALAPPDATA}\npm-cache"
)
foreach ($dir in $npmCacheDirs) {
    if (Test-Path $dir) {
        Write-Detail "清理 npm 缓存目录: $dir"
        Remove-DirectorySafe -Path $dir -Label $dir | Out-Null
    }
}

# pnpm 全局目录：只清理其中属于 @anthropic-ai 的子树，不整目录删
$pnpmClaudeResiduals = @(
    "${env:LOCALAPPDATA}\pnpm\global\5\node_modules\@anthropic-ai",
    "${env:LOCALAPPDATA}\pnpm\node_modules\@anthropic-ai"
)
foreach ($dir in $pnpmClaudeResiduals) {
    if (Test-Path $dir) {
        Write-Detail "清理 pnpm 中的 Claude Code 残留: $dir"
        Remove-DirectorySafe -Path $dir -Label $dir | Out-Null
    }
}

if ($nodeUninstalled -or $nodeDirsCleaned -gt 0) {
    if ($script:DryRun) {
        Write-DryRun "[将清理] Node.js: $nodeDirsCleaned 个安装目录（实际运行时才会删）"
    } else {
        Write-OK "Node.js: $nodeDirsCleaned 个目录已清理"
    }
} elseif (-not (Test-InstalledByUs "NodeInstalledByUs")) {
    Write-Info "Node.js: 未由本脚本安装，已按要求保留"
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

        # 干跑：只报告，不动注册表
        if ($script:DryRun) {
            if ($varName -in $sensitiveVarNames) {
                Write-DryRun "[将删除环境变量] `$env:$varName (敏感信息，值已隐去)"
            } else {
                Write-DryRun "[将删除环境变量] `$env:$varName = $currentValue"
            }
            $cleanedEnvCount++
            continue
        }

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
    if ($script:DryRun) {
        Write-DryRun "[将清理] 环境变量: $cleanedEnvCount 项（实际运行时才会删）"
    } else {
        Write-OK "环境变量: 已清理 $cleanedEnvCount 项"
    }
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

    # 白名单检查：按「完整路径段」匹配，而不是子串匹配。
    # 子串写法会把 D:\Tools\WindowsStuff\nodejs 这种路径误判为受保护（含 Windows）。
    foreach ($safe in $pathWhitelist) {
        if ($normalized -match ("(^|\\)" + [regex]::Escape($safe) + "(\\|$)")) {
            return $false
        }
    }

    # 黑名单检查
    $matched = $false
    foreach ($pattern in $pathBlocklist) {
        if ($normalized -match $pattern) { $matched = $true; break }
    }
    if (-not $matched) { return $false }

    # ── 关键一步：只有「该条目指向的目录已经不存在」时才移除它 ──
    # 否则会出现「软件还在、命令却失效」：例如用户预装的 Git 在 D:\Git，
    # 我们按哨兵保留了目录，却把 D:\Git\cmd 从 PATH 里剪掉。
    # 先展开 %VAR% 再做存在性判断（PATH 里常存字面量 %APPDATA%\npm 这类写法）。
    $expanded = [System.Environment]::ExpandEnvironmentVariables($normalized)
    if (Test-Path -LiteralPath $expanded -ErrorAction SilentlyContinue) { return $false }

    return $true
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

    # 干跑：只报告，不碰注册表
    if ($script:DryRun) {
        Write-DryRun "[将改写 $Scope PATH] 从 $($entries.Count) 个条目中移除上面的 $($removed.Count) 个"
        return @{ Removed = $removed.Count; Errors = 0 }
    }

    # 改动前先备份原值，给用户留一条退路
    try {
        $backupPath = Join-Path ([Environment]::GetFolderPath("Desktop")) `
                               "path-backup-$Scope-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
        $currentPath | Out-File -FilePath $backupPath -Encoding UTF8 -Force
        Write-Detail "  已备份原 $Scope PATH → $backupPath"
    } catch {
        Write-Detail "  ⚠️ 无法写入 $Scope PATH 备份: $_"
    }

    try {
        # 用注册表 API 写回，并保持原有的值类型。
        # 不能用 [System.Environment]::SetEnvironmentVariable —— 它会把 PATH 的
        # REG_EXPAND_SZ 降级成 REG_SZ，导致 PATH 里 %VAR%\... 形式的条目不再展开。
        # 注意：注册表 API 不会广播 WM_SETTINGCHANGE，其他已运行的进程要等重新登录/
        # 重启才会看到新 PATH（脚本结尾本来就建议重启）。
        $hivePath = if ($Scope -eq "Machine") {
            "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment"
        } else {
            "HKCU:\Environment"
        }

        $kind = "ExpandString"
        try {
            $kind = (Get-Item -Path $hivePath -ErrorAction Stop).GetValueKind("Path")
        } catch {
            Write-Detail "  无法读取 $Scope PATH 原类型，按 ExpandString 处理: $_"
        }

        Set-ItemProperty -Path $hivePath -Name "Path" -Value $newPath -Type $kind

        # 立即验证写入结果
        $verifyPath = [System.Environment]::GetEnvironmentVariable("Path", $Scope)
        $stillPresent = $removed | Where-Object {
            $verifyPath -and $verifyPath.ToLowerInvariant().Contains($_.ToLowerInvariant())
        }

        if ($stillPresent.Count -eq 0) {
            Write-OK "$Scope PATH: 已移除 $($removed.Count) 个条目（已写入注册表，原值类型 $kind）"
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
    if ($script:DryRun) {
        Write-DryRun "[将移除] PATH: $totalPathRemoved 个条目 (Machine: $($machineResult.Removed), User: $($userResult.Removed))（实际运行时才会改）"
    } else {
        Write-OK "PATH: 总计移除 $totalPathRemoved 个条目 (Machine: $($machineResult.Removed), User: $($userResult.Removed))"
    }
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

if ($script:DryRun) {
    Write-DryRun "干跑模式没有执行任何删除，因此下面列出的「残留」是预期结果；"
    Write-DryRun "它恰好是一份「本次会保留哪些内容」的清单，便于你核对删除范围。"
}

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
# 只对「本次确实要卸载」的组件做残留校验。
# 被哨兵判定为"用户预装、应保留"的组件必然还在磁盘上，
# 把它算成「残留」会误报警告，并导致哨兵永远无法清理（见文件末尾的哨兵删除逻辑）。
if (Test-InstalledByUs "NodeInstalledByUs") {
    Test-InstallationRemoved -Name "Node.js" `
        -CheckExePaths @(
            "${env:ProgramFiles}\nodejs\node.exe",
            "${env:ProgramFiles(x86)}\nodejs\node.exe",
            "${env:LOCALAPPDATA}\Programs\nodejs\node.exe"
        ) `
        -CheckCommands @("node", "npm", "npx") | Out-Null
} else {
    Write-Info "Node.js: 已按要求保留，跳过残留校验"
}

# ── 验证 Git ──
if (Test-InstalledByUs "GitInstalledByUs") {
    Test-InstallationRemoved -Name "Git" `
        -CheckExePaths @(
            "${env:ProgramFiles}\Git\bin\git.exe",
            "${env:ProgramFiles}\Git\cmd\git.exe",
            "${env:ProgramFiles(x86)}\Git\bin\git.exe",
            "${env:LOCALAPPDATA}\Programs\Git\bin\git.exe"
        ) `
        -CheckCommands @("git") | Out-Null
} else {
    Write-Info "Git: 已按要求保留，跳过残留校验"
}

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
    -CheckCommands @("claude", "claude-code") | Out-Null

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
    # 干跑下这些变量本来就没被动过，"全部清理完毕"是错的（干跑没清任何东西）
    if ($script:DryRun) {
        Write-DryRun "环境变量: 当前无残留（本次干跑未做任何清理）"
    } else {
        Write-OK "环境变量: 全部清理完毕"
    }
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

    # 检查目录是否为空，为空则自动删除。
    # 干跑下要按「启动器会被删掉之后」的状态来算 —— 否则会先说
    # "将删除 claude-launcher.ps1"、紧接着说"目录仍有 1 个文件"，自相矛盾。
    $remainingFiles = @(Get-ChildItem -Path $projectDir -ErrorAction SilentlyContinue)
    if ($script:DryRun) {
        $remainingFiles = @($remainingFiles | Where-Object { $_.FullName -ne $launcherPath })
    }
    if ($remainingFiles.Count -eq 0) {
        if ($script:DryRun) {
            Write-DryRun "[将删除空目录] $projectDir"
        } else {
            try {
                Remove-Item -Path $projectDir -Force -ErrorAction Stop
                Write-OK "my-project 目录已自动删除（已清空）"
            } catch {
                Write-Warn "my-project 目录无法自动删除: $_"
            }
        }
    } else {
        Write-Warn "桌面 my-project 目录仍有 $($remainingFiles.Count) 个文件"
        Write-Detail "  $projectDir"
        Write-Detail "  如不再需要，请手动删除："
        Write-Detail "  Remove-Item -Path '$projectDir' -Recurse -Force"
    }
}

# ── 清理安装标记 ──
# 只有「本次卸载没有任何未完成的清理项」时才删除哨兵。
# 否则必须保留 —— 否则用户重启后再运行本脚本时，会因为「没有哨兵」而走 fail-open 路径，
# 把上次正确保留的软件误删（破坏幂等性）。
if ($script:HasSentinel) {
    $pendingWarnings = @($script:UninstallReport | Where-Object { $_ -like '⚠️*' })
    if ($script:DryRun) {
        Write-DryRun "[将删除安装标记] $($script:SentinelKey)"
    } elseif ($pendingWarnings.Count -gt 0) {
        Write-Info "安装标记保留（本次有 $($pendingWarnings.Count) 项未完成，便于再次运行继续清理）: $($script:SentinelKey)"
    } else {
        try {
            Remove-Item -Path $script:SentinelKey -Recurse -Force -ErrorAction Stop
            Write-Detail "安装标记已清理: $($script:SentinelKey)"
        } catch {
            Write-Warn "安装标记清理失败: $_"
        }
    }
}

# ═══════════════════════════════════════════════════════════════
# 汇总报告
# ═══════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
if ($script:DryRun) {
    # 干跑什么都没执行 —— 显示"卸载完成"是错的
    Write-Host "  [干跑] 结束 —— 本次未修改任何内容" -ForegroundColor Magenta
} else {
    Write-Host "  🎉 卸载完成！汇总报告" -ForegroundColor Cyan
}
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

foreach ($line in $script:UninstallReport) {
    Write-Host "  $line" -ForegroundColor White
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  💡 建议" -ForegroundColor Cyan
Write-Host "────────────────────────────────────────────────────────────" -ForegroundColor Gray
if ($script:DryRun) {
    # 干跑什么都没干，让用户"重启计算机"是荒谬的
    Write-Host "  1. 上面就是实际运行时会做的事，请核对删除范围是否符合预期" -ForegroundColor White
    Write-Host "  2. 确认无误后，去掉 -DryRun 再运行一次即会真正执行" -ForegroundColor White
} else {
    Write-Host "  1. 重启计算机以清除所有内存中的环境变量" -ForegroundColor White
    Write-Host "  2. 打开「系统属性 → 环境变量」确认 PATH 已清理干净" -ForegroundColor White
    Write-Host "  3. 如仍有残留目录，重启后手动删除" -ForegroundColor White
}
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan

# 恢复控制台代码页（改过就要还原，别把用户的终端留在 65001）
Restore-ConsoleCodePage

# 干跑模式下无人值守，不阻塞等待按键
if (-not $script:DryRun) {
    Read-Host "按 Enter 键退出..."
}
