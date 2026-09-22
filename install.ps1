# Claude Code + DeepSeek 一键安装脚本 (install.ps1)
# 安装 Node.js 18+, Git, Claude Code, 并配置 DeepSeek API 后端
#Requires -Version 5.1

# -DryRun: 干跑模式。不下载、不安装、不写注册表/环境变量，只打印将要执行的操作。
#          干跑不需要管理员权限，也不触发 UAC。
param(
    [switch]$DryRun,
    # 提权时父进程会把自己的脚本哈希传进来，子进程据此确认「跑的还是同一个文件」。
    # 详见下方「脚本自身完整性校验」一节。
    [string]$ExpectedScriptHash
)

$ErrorActionPreference = "Stop"

# 脚本级变量
$Script:DryRun            = [bool]$DryRun
$Script:EnvTempFile       = $null    # 仅用于清理旧版本残留的 %TEMP% 文件（本版已不再写入）
$Script:OriginalCodePage  = $null    # 控制台原代码页，脚本退出前恢复（见下）

# ═══════════════════════════════════════════════════════════════
# 输出编码 —— 简体中文 Windows 的控制台默认代码页是 936(GBK)。
# GBK 里既没有 emoji（✅ ❌ ⚠️ 🔒 …）也没有 U+2713(✓)，PowerShell 5.1
# 会把这些字符输出成 '?'，让满屏提示变成问号海。
# 这里在启动时把控制台切到 UTF-8(65001)，退出前恢复原来的代码页。
#
# 用 Win32 API 直接改控制台代码页：只设 [Console]::OutputEncoding 在
# .NET Framework 下不保证同步改动控制台本身的代码页，会出现"编码对了、
# 代码页没对"从而中文反而乱码的情况。
#
# ⚠️ 已知边界：输出被【另一个进程捕获】时（管道 / CI / 存进 PowerShell 变量），
#    本脚本写出的是 UTF-8 字节；捕获方若按自己的 GBK 去解码就会满屏乱码。
#    捕获端先执行这一行即可：
#        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
#    双击运行不受影响 —— 而那才是本脚本的主要使用方式。
#    之所以不改成「被重定向时就用 GBK」：那会把「重定向到文件、再用编辑器打开」
#    这个同样常见的场景从正确变成乱码。两种捕获方对编码的期望正好相反，
#    脚本无法同时满足，所以固定为 UTF-8 这个现代默认值，并在此写明。
# ═══════════════════════════════════════════════════════════════
try {
    if (-not ('CCInstaller.ConsoleCodePage' -as [type])) {
        Add-Type -Namespace 'CCInstaller' -Name 'ConsoleCodePage' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern uint GetConsoleOutputCP();
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern bool SetConsoleOutputCP(uint wCodePageID);
'@
    }
    $Script:OriginalCodePage = [CCInstaller.ConsoleCodePage]::GetConsoleOutputCP()
    if ($Script:OriginalCodePage -ne 65001) {
        [void][CCInstaller.ConsoleCodePage]::SetConsoleOutputCP(65001)
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    }
} catch {
    # 改不动就保持原样 —— 顶多还是显示 '?'，绝不能让脚本因此失败
    $Script:OriginalCodePage = $null
}

# 恢复控制台代码页。任何 exit 路径都应经过它（见文件末尾与各提权分支）。
function Restore-ConsoleCodePage {
    if ($Script:OriginalCodePage -and $Script:OriginalCodePage -ne 65001) {
        try {
            [void][CCInstaller.ConsoleCodePage]::SetConsoleOutputCP($Script:OriginalCodePage)
            [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding([int]$Script:OriginalCodePage)
        } catch { }
    }
}

# ── 本次是否真的由本脚本安装了该组件（用于写安装标记/哨兵）──
# 关键：用户已预装、被「跳过安装」的组件必须保持 0。
# 如果无条件写入（例如记录回读到的版本号），卸载脚本会把用户预装的 Node.js / Git
# 误判为"本脚本安装的"并删除。
$Script:NodeInstalledByUs       = $false
$Script:GitInstalledByUs        = $false
$Script:ClaudeCodeInstalledByUs = $false

# 全局 trap — 必须在任何运行时语句之前定义。
# 注意：trap 内要判断函数是否已定义 —— 在文件前段（函数定义之前）抛错时，
# 直接调用 Write-ErrorLog / Invoke-ScriptCleanup 会因为函数不存在而二次抛错，
# 把原始错误掩盖掉，而这恰恰是最需要日志生效的时候。
trap {
    if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
        Write-ErrorLog -Reason "脚本异常终止: $($_.Exception.Message)"
    } else {
        Write-Host "脚本异常终止: $($_.Exception.Message)" -ForegroundColor Red
    }
    if (Get-Command Invoke-ScriptCleanup -ErrorAction SilentlyContinue) {
        Invoke-ScriptCleanup
    }
    exit 1
}

# 加载 System.Security 程序集（DPAPI 加密/解密需要 ProtectedData 类）
# PowerShell 5.1 不会自动加载此程序集，必须显式引入，否则后续所有
# ProtectData/UnprotectData 调用都会因找不到类型而失败
Add-Type -AssemblyName System.Security

# ============================================================
# 脚本自身完整性校验
# 提权链的薄弱点：脚本可能位于用户可写目录（桌面 / 下载），而 UAC 弹窗
# 恰好给了攻击者一个替换文件的时间窗。父进程在提权前算出自己的 SHA256
# 传给子进程，子进程（已是管理员身份）重新计算后比对 —— 不一致就中止，
# 避免「用户批准的是一个脚本、实际以管理员跑的是另一个」。
# 注意：它挡不住「用户在运行之前文件就已被替换」—— 那种情况下父进程算到的
# 也是被替换之后的哈希。它挡的是 UAC 等待期间的那段窗口。
# ============================================================
# ── 自己实现 SHA256，不依赖 Get-FileHash ──
# Get-FileHash 属于 Microsoft.PowerShell.Utility 模块。在 PSModulePath 被
# PowerShell 7 污染过的机器上（%ProgramFiles%\PowerShell\7\Modules 混进了
# PS 5.1 的搜索路径，本机实测就是这种情况），PS 5.1 会去加载为 .NET Core
# 编译的那份二进制模块、加载失败，于是 Get-FileHash 直接 CommandNotFound。
# 那样一来整条完整性校验链会全部失效 —— 而校验正是本脚本最关键的一环。
# 所以这里直接用 .NET 的 SHA256 算，输出去掉连字符的大写十六进制，
# 与 Get-FileHash 的 .Hash 格式一致。
function Get-Sha256Hex {
    param([string]$FilePath)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($FilePath)
        try {
            return ([System.BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '')
        } finally {
            $stream.Dispose()
        }
    } finally {
        $sha.Dispose()
    }
}

function Get-ScriptHash {
    try {
        return Get-Sha256Hex -FilePath $PSCommandPath
    } catch {
        return $null
    }
}

# 算不出自身哈希时必须【中止】，不能"降级为不校验"。
# 否则这就是个 fail-open：一旦哈希计算失败（例如有进程对脚本文件持有独占读锁
# —— 攻击者恰好可以制造这种状态），提权照常进行、子进程却因为参数为空而整段
# 跳过一致性校验，安全控制在最需要它的时候被静默关掉。
function Get-ScriptHashOrExit {
    $hash = Get-ScriptHash
    if (-not $hash) {
        Write-Host ""
        Write-Host "============================================================" -ForegroundColor Red
        Write-Host "  ❌ 无法计算本脚本的 SHA256，已中止" -ForegroundColor Red
        Write-Host "============================================================" -ForegroundColor Red
        Write-Host "  脚本: $PSCommandPath" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  提权/重启分支必须能算出脚本哈希 —— 它用来让子进程复核" -ForegroundColor Yellow
        Write-Host "  「管理员身份跑的还是同一个文件」。算不出来就不该继续。" -ForegroundColor Yellow
        Write-Host "  常见原因：文件被其他程序独占锁定（杀毒软件、编辑器、同步盘）。" -ForegroundColor Yellow
        Write-Host "  请关闭可能占用它的程序后重试。" -ForegroundColor Yellow
        Write-Host ""
        Restore-ConsoleCodePage
        Read-Host "按 Enter 键退出..."
        exit 1
    }
    return $hash
}

if ($ExpectedScriptHash) {
    $actualScriptHash = Get-ScriptHash
    if (-not $actualScriptHash -or $actualScriptHash -ne $ExpectedScriptHash) {
        Write-Host ""
        Write-Host "============================================================" -ForegroundColor Red
        Write-Host "  ❌ 脚本文件在提权前后发生变化，已中止安装" -ForegroundColor Red
        Write-Host "============================================================" -ForegroundColor Red
        Write-Host "  提权前哈希: $ExpectedScriptHash" -ForegroundColor Yellow
        Write-Host "  当前哈希  : $actualScriptHash" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  文件在 UAC 等待期间被修改过。请从可信来源重新获取本脚本后再运行。" -ForegroundColor Yellow
        Write-Host ""
        Restore-ConsoleCodePage
        Read-Host "按 Enter 键退出..."
        exit 1
    }
}

# ============================================================
# 安装摘要 —— 提权父进程与子进程共用同一份实现
#
# 之前这两处各抄了一份，文案已经开始漂移（父进程是"🎉 安装完成！"，子进程是
# "🎉 安装完成！最终状态"），而且父进程那份只显示 Node/Claude/Git/DeepSeek，
# 子进程那份显示 Node/npm/Git/Claude —— 两份 UI 各自演化只会越来越不一致。
# 收敛成一个函数，加一个组件就同时生效。
# ============================================================
function Show-InstallSummary {
    param(
        # 提权父进程会把子进程的退出码传进来；子进程自己调用时不传（默认 0）
        [int]$ChildExitCode = 0
    )

    $desktop = [Environment]::GetFolderPath("Desktop")

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    if ($ChildExitCode -eq 0) {
        Write-Host "   🎉 安装完成！最终状态" -ForegroundColor Cyan
    } else {
        Write-Host "   ❌ 安装未成功完成（子进程退出码: $ChildExitCode）" -ForegroundColor Red
        Write-Host "      请查看桌面上的 install-log-*.txt 日志了解原因" -ForegroundColor Yellow
        Write-Host "      以下是当前实际状态：" -ForegroundColor Yellow
    }
    Write-Host "============================================================" -ForegroundColor Cyan

    $summaryNodeCmd = Get-Command node -ErrorAction SilentlyContinue
    if ($summaryNodeCmd) {
        Write-Host "  ✅ Node.js : $(& node -v)" -ForegroundColor Green
    } else {
        Write-Host "  ❌ Node.js : 未检测到（若刚装完，需重启终端）" -ForegroundColor Red
    }

    $summaryNpmCmd = Get-Command npm -ErrorAction SilentlyContinue
    if ($summaryNpmCmd) {
        Write-Host "  ✅ npm     : v$(& npm -v)" -ForegroundColor Green
    } else {
        Write-Host "  ❌ npm     : 未检测到（若刚装完，需重启终端）" -ForegroundColor Red
    }

    $summaryGitCmd = Get-Command git -ErrorAction SilentlyContinue
    if ($summaryGitCmd) {
        Write-Host "  ✅ Git     : $(& git --version)" -ForegroundColor Green
    } else {
        Write-Host "  ❌ Git     : 未检测到（若刚装完，需重启终端）" -ForegroundColor Red
    }

    $summaryClaudeCmd = Get-Command claude -ErrorAction SilentlyContinue
    if ($summaryClaudeCmd) {
        Write-Host "  ✅ Claude  : $(& claude --version)" -ForegroundColor Green
    } else {
        Write-Host "  ❌ Claude  : 未检测到（若刚装完，需重启终端）" -ForegroundColor Red
    }

    $summaryDsUrl = [System.Environment]::GetEnvironmentVariable("ANTHROPIC_BASE_URL", "User")
    $summaryDsEnc = [System.Environment]::GetEnvironmentVariable("ANTHROPIC_AUTH_TOKEN_ENC", "User")
    if ($summaryDsEnc -and $summaryDsUrl) {
        Write-Host "  ✅ DeepSeek: 已配置 (DPAPI 加密) → $summaryDsUrl" -ForegroundColor Green
    } elseif ($summaryDsUrl) {
        Write-Host "  ✅ DeepSeek: 已配置 → $summaryDsUrl" -ForegroundColor Green
    } else {
        Write-Host "  ⚠️  DeepSeek: 未配置（重新运行本脚本并选择 Y）" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "  项目目录    : $desktop\my-project" -ForegroundColor Gray
    Write-Host "  桌面快捷方式: $desktop\Claude Code.lnk" -ForegroundColor Gray
    Write-Host "  双击快捷方式即可在项目目录启动 Claude Code" -ForegroundColor White
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
}

# ============================================================
# 自动获取管理员权限
# ============================================================
function Test-IsAdmin {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal   = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin) -and -not $Script:DryRun) {
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
    if ($Script:DryRun) { $argList += "-DryRun" }   # 透传干跑开关
    # 把自己的脚本哈希传给子进程 —— 子进程以管理员身份复核文件没被调包。
    # 算不出来就直接中止（见 Get-ScriptHashOrExit 的说明），不许静默降级。
    $parentScriptHash = Get-ScriptHashOrExit
    $argList += @("-ExpectedScriptHash", $parentScriptHash)

    # 以管理员身份重新启动 PowerShell 并等待完成
    try {
        $process = Start-Process PowerShell -Verb RunAs -ArgumentList $argList -Wait -PassThru
    } catch {
        # 用户在 UAC 弹窗点了「取消」——这是正常操作，不是安装失败
        Write-Host ""
        Write-Host "  已取消提权，未做任何修改。" -ForegroundColor Yellow
        exit 1
    }

    # ═══════════════════════════════════════════════════════════════
    # 子进程已完成。
    # 注意：这里**不再**去 dot-source %TEMP%\claude-code-env-<pid>.ps1。
    # 所有环境变量都已由子进程持久化到注册表（HKCU\Environment），
    # 父进程本来就直接从注册表读取，那个临时文件通道没有任何作用，
    # 却引入了"dot-source 一个位于用户可写目录、仅按大小粗略校验的文件"的风险面。
    # ═══════════════════════════════════════════════════════════════

    # ── 父进程【不再】解密 API Key ──
    # 旧实现在这里把明文 Key 放进 $env:ANTHROPIC_AUTH_TOKEN。但父进程紧接着
    # 只做两件事：刷新 PATH、打印状态摘要。而摘要里的 `claude --version` /
    # `node -v` / `npm -v` / `git --version` 都是子进程，会继承这个明文 Key ——
    # 为了一个马上要 exit 的进程，白白扩大了明文的暴露面。
    # 真正需要 Key 的是桌面启动器（claude-launcher.ps1），它自己会解密。

    # 刷新 PATH（子进程可能安装了 Node.js / Git）
    try {
        $mPath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
        $uPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
        $env:Path = ($mPath, $uPath | Where-Object { $_ } ) -join ";"
    } catch {
        Write-Host "  ⚠️  PATH 刷新失败: $_" -ForegroundColor DarkYellow
    }

    # ── 快速状态摘要 ──
    # 先看子进程的真实退出码，不能无条件打印"安装完成" ——
    # 否则子进程失败后，用户会在同一个窗口里先看到失败、紧接着看到"安装完成"。
    # 摘要本身与子进程共用 Show-InstallSummary，避免两份 UI 各自漂移。
    Show-InstallSummary -ChildExitCode $process.ExitCode

    Read-Host "按 Enter 键退出..."

    Restore-ConsoleCodePage
    exit $process.ExitCode
}

if ($Script:DryRun) {
    Write-Host "=== 干跑模式 (-DryRun)：不下载 / 不安装 / 不写注册表，只打印将要执行的操作 ===" -ForegroundColor Magenta
    Write-Host "    干跑不需要管理员权限，因此不触发 UAC 提权。" -ForegroundColor DarkGray
} else {
    Write-Host "=== 管理员权限已确认 ===" -ForegroundColor Green
}
Write-Host ""

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "   Claude Code + DeepSeek 一键安装" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================
# 架构检测 — 32位PowerShell在64位OS上会导致 "%1 不是有效的 Win32 应用程序" 错误
# ============================================================
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess -and -not $Script:DryRun) {
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
    # 与提权分支同样把脚本哈希透传下去（本分支在干跑模式下不会进入）。
    # 同样不许降级：算不出哈希就中止。
    $relaunchHash = Get-ScriptHashOrExit
    $argList += @("-ExpectedScriptHash", $relaunchHash)

    $process = Start-Process -FilePath "$env:SystemRoot\SysNative\WindowsPowerShell\v1.0\powershell.exe" `
        -Verb RunAs -ArgumentList $argList -Wait -PassThru
    Restore-ConsoleCodePage
    exit $process.ExitCode
}

Write-Host "  架构: $(if ([Environment]::Is64BitProcess) { '64-bit' } else { '32-bit' }) PowerShell" -ForegroundColor Gray

# ── 执行策略：本版【不再修改】它 ──
# 旧版本把 CurrentUser 执行策略改成 RemoteSigned、退出前再恢复。但脚本被强杀、
# 窗口被关闭、或者断电时恢复语句根本不会执行，策略就永久残留成被弱化的状态
# （uninstall.ps1 里那段"检测到 RemoteSigned 残留"的提示正是这个坑留下的）。
# 而桌面快捷方式本来就用 -ExecutionPolicy Bypass 启动，这一步毫无必要。
# 这里只做只读检查：发现旧版本留下的残留就告诉用户怎么恢复。
Write-Host ""
try {
    $currentPolicy = Get-ExecutionPolicy -Scope CurrentUser -ErrorAction SilentlyContinue
    if ($currentPolicy -eq 'RemoteSigned') {
        Write-Host "  ⚠ CurrentUser 执行策略为 RemoteSigned（可能是旧版安装脚本的残留）" -ForegroundColor DarkYellow
        Write-Host "    如需恢复默认：Set-ExecutionPolicy Undefined -Scope CurrentUser -Force" -ForegroundColor Gray
    }
} catch { }
Write-Host ""

# ============================================================
# 错误日志 — 执行失败时自动生成到桌面
# ============================================================
$Script:LogPath   = $null
$Script:StartTime = Get-Date

function Write-ErrorLog {
    param([string]$Reason = "未知错误")

    # 先清理敏感临时文件 + 恢复控制台代码页，确保即使后续退出也不残留
    if ($Script:EnvTempFile -and (Test-Path $Script:EnvTempFile)) {
        Remove-Item $Script:EnvTempFile -Force -ErrorAction SilentlyContinue
    }
    Restore-ConsoleCodePage

    # 干跑模式不往桌面写日志文件：干跑承诺"不写任何文件"，而且干跑途中报出的
    # 多半是"本机还缺某前置条件"，并不是真的安装失败，写一份失败日志只会误导。
    if ($Script:DryRun) {
        Write-Host ""
        Write-Host "  [干跑] 这里本会记录失败原因并写日志到桌面: $Reason" -ForegroundColor Magenta
        return
    }

    # 只生成一次（避免多次 exit 重复写日志）
    if ($Script:LogPath) { return }

    $Script:LogPath = Join-Path ([Environment]::GetFolderPath("Desktop")) `
                              "install-log-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"

    $osInfo  = try { (Get-CimInstance Win32_OperatingSystem).Caption } catch { "N/A" }
    $lastErr = $Error[0..4] | ForEach-Object { "  $_" } | Out-String

    # 脱敏：移除可能出现在错误消息中的 API Key / Token 片段。
    # 只匹配 'sk-' 前缀是不够的：不同厂商的 Key 前缀不同，而且 Key 可能出现在
    # 任意上下文里（HTTP 头、JSON body、命令行回显、异常消息）。这里改成
    # 「按敏感变量名兜底 + 按常见密钥形态兜底」双保险。
    $sensitiveNames = 'ANTHROPIC_AUTH_TOKEN(_ENC)?|API_?KEY|AUTH_?TOKEN|SECRET|PASSWORD|PASSWD'
    # 形如 NAME=value / NAME: value 的赋值，只要 NAME 命中敏感名单，值一律打码
    $lastErr = $lastErr -replace ('(?im)^(\s*)(\$env:)?(' + $sensitiveNames + ')(\s*[:=]\s*).*$'), '$1$3$4[REDACTED]'
    # 常见密钥形态（sk-/rk-/pk- 前缀的长串）
    $lastErr = $lastErr -replace '\b(?:sk|rk|pk)-[a-zA-Z0-9_\-]{16,}\b', '[REDACTED-API-KEY]'
    # Authorization: Bearer <token>
    $lastErr = $lastErr -replace '(?i)(Bearer\s+)[A-Za-z0-9_\-\.]{16,}', '${1}[REDACTED]'

    $log = @"
============================================================
  安装失败日志
============================================================
  时间         : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
  脚本         : install.ps1
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
    # 只在有交互控制台时等待按键。无交互环境（stdin 被重定向、计划任务、管道）
    # 下 Read-Host 会抛 "Cannot read keys when ... console input has been redirected"。
    # 这个函数本来就在失败路径上被调用，一旦它抛错，异常会沿着调用栈被更高层的
    # catch 吞掉，把"该退出"变成"继续往下跑" —— 那正是要避免的。
    $canPrompt = $true
    try { $canPrompt = -not [Console]::IsInputRedirected } catch { }
    if ($canPrompt) {
        Read-Host "按 Enter 键退出..."
    }
}

# 全局清理函数 — 确保敏感临时文件在执行策略恢复前被删除
function Invoke-ScriptCleanup {
    # 清理可能残留的环境变量临时文件
    if ($Script:EnvTempFile -and (Test-Path $Script:EnvTempFile)) {
        Remove-Item $Script:EnvTempFile -Force -ErrorAction SilentlyContinue
    }
    # 使用 PID 模式清理（兼容旧版本或异常路径）
    $pidTempFile = Join-Path $env:TEMP "claude-code-env-${PID}.ps1"
    if (Test-Path $pidTempFile) {
        Remove-Item $pidTempFile -Force -ErrorAction SilentlyContinue
    }
    # 恢复控制台代码页
    Restore-ConsoleCodePage
}

# ============================================================
# DPAPI 加密/解密函数 — API Key 安全存储
# 使用 Windows Data Protection API，加密绑定到当前用户+当前机器
# 解密无需密钥 — Windows 自动使用用户登录凭据解锁
# ============================================================
function Protect-ApiKey {
    <#
    .SYNOPSIS
        使用 DPAPI 加密 API Key（绑定当前用户）
    .OUTPUTS
        返回 Base64 编码的加密字符串，可安全存储到注册表
    #>
    param([string]$PlainText)
    $bytes   = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
    $encrypted = [System.Security.Cryptography.ProtectedData]::Protect(
        $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    return [System.Convert]::ToBase64String($encrypted)
}

function Unprotect-ApiKey {
    <#
    .SYNOPSIS
        使用 DPAPI 解密 API Key（需同一用户身份）
    .OUTPUTS
        返回明文 — 仅在内存中存在，不写入磁盘
    #>
    param([string]$Base64)
    $bytes     = [System.Convert]::FromBase64String($Base64)
    $decrypted = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    return [System.Text.Encoding]::UTF8.GetString($decrypted)
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
# SHA256 哈希校验函数 — 验证下载文件完整性
# ============================================================
function Test-FileHash {
    <#
    .SYNOPSIS
        比对文件的 SHA256 哈希
    .OUTPUTS
        返回一个带 Outcome 字段的对象，有三种取值：
          'Match'       —— 哈希一致，校验通过
          'Mismatch'    —— 哈希算出来了但对不上（这才叫"可能被篡改"）
          'Unavailable' —— 压根没算出哈希（文件读不了、哈希实现不可用…）
    .NOTES
        必须把 'Unavailable' 和 'Mismatch' 分开。旧实现把两者都返回 $false，
        而调用方把 $false 一律当成"校验失败/可能被篡改" —— 在 Get-FileHash
        不可用的机器上（PSModulePath 被 PowerShell 7 污染时很常见）就会报出
        误导性的"安装包已被篡改"，并让安装彻底无法进行。
        "没能校验"要走人工确认，"校验失败"才该直接中止。
    #>
    param(
        [string]$FilePath,
        [string]$ExpectedHash,
        [string]$Description = ""
    )

    $result = [PSCustomObject]@{
        Outcome = 'Unavailable'
        Actual  = $null
        Error   = $null
    }

    if (-not $ExpectedHash) {
        $result.Error = "没有可用的预期哈希值"
        return $result
    }
    if (-not (Test-Path $FilePath)) {
        $result.Error = "文件不存在: $FilePath"
        return $result
    }

    $label = if ($Description) { " ($Description)" } else { "" }
    Write-Host "  🔐 正在验证 SHA256 哈希${label}..." -ForegroundColor Gray

    try {
        $actualHash = Get-Sha256Hex -FilePath $FilePath
    } catch {
        $result.Error = "无法计算哈希: $($_.Exception.Message)"
        Write-Host "  ⚠ SHA256 校验无法执行 —— $($result.Error)" -ForegroundColor DarkYellow
        return $result
    }

    if (-not $actualHash) {
        $result.Error = "哈希计算结果为空"
        return $result
    }

    $result.Actual = $actualHash
    if ($actualHash -eq $ExpectedHash) {
        $result.Outcome = 'Match'
        Write-Host "  ✓ SHA256 哈希验证通过" -ForegroundColor Green
    }
    else {
        $result.Outcome = 'Mismatch'
        Write-Host "  ❌ SHA256 哈希不匹配!" -ForegroundColor Red
        Write-Host "     预期: $ExpectedHash" -ForegroundColor Red
        Write-Host "     实际: $actualHash" -ForegroundColor Red
    }
    return $result
}

# ── 取得可安全拼接进命令行的临时目录 ──
# %TEMP% 是用户可控的环境变量，而它会被拼进 Start-Process -ArgumentList 的
# 带引号参数里（"$msiLogPath"）。如果路径里含双引号，就能提前闭合引号、
# 把后面的内容注入成安装器的参数（例如覆盖 /DIR，造成管理员任意文件写入）。
# 这里做一次校验：为空或含双引号一律拒绝。
function Get-SafeTempDir {
    param([string]$Purpose = "安装")

    $tempDir = $env:TEMP
    if (-not $tempDir -or $tempDir.Contains('"')) {
        Write-ErrorLog -Reason "环境变量 TEMP 为空或含双引号，无法安全拼接 $Purpose 参数（TEMP='$tempDir'）"
        exit 1
    }
    return $tempDir
}

# ── 这个可执行文件是不是「普通用户能替换掉」的？ ──
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
        if ($Path.StartsWith($rootWithSep, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

# ── 取可执行文件的版本，但【不执行用户可写位置的程序】──
# 本脚本是管理员身份。如果从注册表值（HKCU\SOFTWARE\Node.js\InstallPath 之类）
# 或写死的用户可写目录里拿到一个 exe 就 & 起来问版本，攻击者只要在这些位置
# 放一个同名 exe，用户运行本脚本就等于让攻击者以管理员身份执行代码。
# node.exe / git.exe 都带版本资源，读文件版本信息完全够用，不值得为此执行任意程序。
function Get-ExecutableVersionString {
    param(
        [string]$ExePath,
        [string]$Argument = '-v'
    )

    if (-not $ExePath -or -not (Test-Path -LiteralPath $ExePath -ErrorAction SilentlyContinue)) {
        return $null
    }

    # 受保护目录里的可以放心执行（拿到的版本也更准）
    if (Test-PathIsProtected -Path $ExePath) {
        try { return (& $ExePath $Argument 2>$null) } catch { return $null }
    }

    try {
        $vi = (Get-Item -LiteralPath $ExePath -ErrorAction Stop).VersionInfo
        $v = if ($vi.ProductVersion) { $vi.ProductVersion } elseif ($vi.FileVersion) { $vi.FileVersion } else { $null }
        if ($v) {
            Write-Host "    (未执行用户可写位置的 $ExePath，改用文件版本信息: $v)" -ForegroundColor DarkGray
        }
        return $v
    } catch {
        return $null
    }
}

# ── 从证书 Subject 里取出 CN（通用名）──
# 用于【精确比对】签名主体。不要改成 -like 子串匹配：那样
# "O=Git for Windows Ltd" 这类主体也能混过白名单。
function Get-CertificateCommonName {
    param([string]$Subject)

    if (-not $Subject) { return $null }

    # 形如: CN="Johannes Schindelin", O="Johannes Schindelin", C=DE
    if ($Subject -match '(?:^|,)\s*CN\s*=\s*"([^"]+)"') { return $matches[1].Trim() }
    if ($Subject -match '(?:^|,)\s*CN\s*=\s*([^,]+)')    { return $matches[1].Trim() }
    return $null
}

# ============================================================
# 无法校验时的处置 —— fail-closed
# 旧实现在取不到校验和时只打印一句"跳过验证"就继续以管理员身份静默安装。
# 这恰恰在最需要校验的场景（官方域不可达、安装包只能来自第三方镜像）下放行，
# 而且"校验代码存在"反而给用户制造了「已经验过了」的错觉。
# 这里改为必须由用户显式输入 yes 才继续；其余任何输入都中止安装。
# ============================================================
function Confirm-UnverifiedInstaller {
    param(
        [string]$Name,
        [string]$Path,
        [string]$Detail
    )

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host "  ❌ $Name 安装包无法完成完整性校验" -ForegroundColor Red
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host "  文件: $Path" -ForegroundColor Yellow
    Write-Host "  原因: $Detail" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  继续安装 = 以管理员权限运行一个未经校验的文件。" -ForegroundColor Red
    Write-Host "  建议先排查网络 / 代理后重试，或手动下载官方安装包放在脚本同目录。" -ForegroundColor Yellow
    Write-Host ""

    # 说明：本函数在干跑模式下【不可达】—— 两个调用点都被干跑守卫拦在前面
    # （Install-Git 入口、Node 安装分支）。所以这里不再放 DryRun 分支，
    # 免得留下一段永远不会执行的"保护"。
    Write-Host "  如确认要继续，请输入 yes 后回车；直接回车 = 中止安装：" -ForegroundColor White
    $answer = Read-Host "  请输入"
    # 用 -ceq 精确比较：-eq 对字符串是大小写不敏感的，YES / Yes 都会被放行
    return ($answer -ceq 'yes')
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
        # 离线回退路径信任的是「脚本同目录」这个前提。校验策略要说清楚，
        # 免得用户以为这里"什么都没验"或者反过来以为"一定验过"：
        #   · 本地包文件名与待下载版本一致 → 走正常哈希比对
        #   · 文件名不同（多半是另一个版本）→ 跳过哈希比对，改用签名校验
        Write-Host "     ℹ️  本地安装包若与待下载版本同名则照常做哈希比对；" -ForegroundColor Gray
        Write-Host "        版本不同则跳过哈希比对，改用 Authenticode 签名校验。" -ForegroundColor Gray
        Write-Host "     ⚠️  请自行确认它来自官方渠道；若脚本所在目录不可信（如下载目录），" -ForegroundColor Yellow
        Write-Host "        建议改用联网安装。" -ForegroundColor DarkYellow
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

    # 干跑：不执行 npm，只报告
    if ($Script:DryRun) {
        Write-Host "  [干跑] 将执行: npm install -g $Package（官方源失败则回退 registry.npmmirror.com）" -ForegroundColor Magenta
        return $true
    }

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
        # 把全局前缀也打出来。装过 nvm / Volta / fnm / scoop，或者装了自带
        # node 的软件时，PATH 里排前面的可能是「别人的 npm」—— 那样包会装进
        # 一个用户实际不会用到的前缀，表现为"装完了却敲不到 claude"。
        # 官方 Node 安装器的全局前缀是 %APPDATA%\npm，打出来一眼就能核对。
        if ($npmPath -ne "npm") {
            try {
                $npmPrefix = & $npmPath prefix -g 2>$null | Select-Object -First 1
                if ($npmPrefix) {
                    Write-Host "  npm 全局前缀: $("$npmPrefix".Trim())" -ForegroundColor Gray
                }
            } catch { }
        }

        # npm 源列表：主源 + 国内镜像
        # ⚠️ 注意：npmmirror.com 为第三方镜像，存在供应链风险。仅在官方源不可用时作为备用。
        $registries = @(
            @{ Name = "npm 官方源"; Args = @("install", "-g") },
            @{ Name = "npmmirror 镜像 (第三方)"; Args = @("install", "-g", "--registry=https://registry.npmmirror.com") }
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
                    try {
                        & $npmPath @fullArgs 2>&1 | ForEach-Object {
                            # 实时输出 npm 的安装进度
                            $line = "$_"
                            if ($line -match "added|updated|removed|audited|found") {
                                Write-Host "    $line" -ForegroundColor Gray
                            }
                        }
                        $exitCode = $LASTEXITCODE
                    }
                    finally {
                        $LASTEXITCODE = $prevExit  # 确保恢复，避免污染外层判断
                    }

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

# ═══════════════════════════════════════════════════════════════
# 配置区 —— 会随上游变化的值集中在这里，不要再散落进流程代码
# ═══════════════════════════════════════════════════════════════
$Script:Config = @{
    # ── DeepSeek API 后端 ──
    ApiBaseUrl   = "https://api.deepseek.com/anthropic"
    ModelPrimary = "deepseek-v4-pro[1m]"    # 主模型（同时用于 Opus / Sonnet 档）
    ModelSmall   = "deepseek-v4-flash"      # 小模型（Haiku 档与子代理）

    # ── 上游不可达时的兜底版本 ──
    # 只在 nodejs.org / 镜像的版本清单都取不到时才会用到。
    # Node 兜底刻意选一个「确认存在」的 LTS，而不是猜一个更新的版本号：
    # 猜错的话三镜像全 404，比装到旧版本更糟。升级时请一并核实。
    NodeFallbackVersion = "v20.19.0"
    GitFallbackTag      = "v2.47.1.windows.1"
    GitFallbackBaseVer  = "2.47.1"

    # ── 安装包签名白名单（写 CN 通用名，精确比对）──
    # Authenticode 只判 'Valid' 是不够的：任何一家受信任 CA 签发的有效证书
    # 都能签出一个伪装包，状态同样是 'Valid'。必须同时确认签名主体。
    # 这里存的是 CN 值，比较时用「相等」而不是子串匹配 —— 子串匹配会让
    # "O=Git for Windows Ltd" 这类主体也通过。
    # ⚠️ Node 那两条未能用真实安装包验证（本机无安装包、且该 cmdlet 在
    #    污染环境下不可用），属保守猜测；不匹配时不会误放行，只是会多问一次。
    GitAllowedSigners  = @("Johannes Schindelin")
    NodeAllowedSigners = @("OpenJS Foundation", "Node.js Foundation")
}

Write-Host "=== Node.js 18+ & Git & Claude Code Installation Script ===" -ForegroundColor Cyan
Write-Host "   ✓ 已确认管理员权限" -ForegroundColor Green
Write-Host ""

# Function to compare version numbers
function Get-LatestNodeVersion {
    param([int]$MinMajor = 18)

    # 版本清单也从镜像链取：nodejs.org 不可达正是脚本内置国内镜像的原因，
    # 只依赖 nodejs.org 会让「镜像下载」这条主路径拿不到版本号。
    $indexUrls = @(
        "https://nodejs.org/dist/index.json",
        "https://npmmirror.com/mirrors/node/index.json"
    )

    $releases = $null
    foreach ($indexUrl in $indexUrls) {
        try {
            Write-Host "  获取 Node.js 版本列表: $indexUrl" -ForegroundColor Gray
            $releases = Invoke-RestMethod -Uri $indexUrl -TimeoutSec 10
            if ($releases) { break }
        } catch {
            Write-Host "  ⚠ 该来源不可用: $indexUrl" -ForegroundColor DarkGray
        }
    }

    if (-not $releases) {
        Write-Host "  ⚠ 所有版本清单来源均不可用，将使用内置兜底版本" -ForegroundColor Yellow
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
                $ver = Get-ExecutableVersionString -ExePath $nodeExe -Argument '-v'
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
                        $ver = Get-ExecutableVersionString -ExePath $nodeExe -Argument '-v'
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
    $nvmPath = $null
    try { $nvmPath = (Get-Command nvm -ErrorAction Stop).Source } catch { }
    if (-not $nvmPath) {
        $nvmPath = "${env:ProgramFiles}\nvm\nvm.exe"
        if (-not (Test-Path $nvmPath)) { $nvmPath = "${env:LOCALAPPDATA}\nvm\nvm.exe" }
    }
    if ($nvmPath -and (Test-Path $nvmPath)) {
        # 不执行 nvm.exe —— nvm 的安装位置（%LOCALAPPDATA%\nvm 等）普通用户可写，
        # 而本脚本是管理员身份。直接枚举它的版本目录，再读 node.exe 的文件版本。
        $nvmHome = if ($env:NVM_HOME) { $env:NVM_HOME } else { Split-Path -Parent $nvmPath }
        foreach ($verDir in @(Get-ChildItem -Path $nvmHome -Directory -Filter 'v*' -ErrorAction SilentlyContinue)) {
            if ($verDir.Name -notmatch '^v(\d+\.\d+\.\d+)$') { continue }
            $ver = $matches[1]
            $nvmNodePath = Join-Path $verDir.FullName "node.exe"
            if ((Test-Path $nvmNodePath) -and ($nvmNodePath -notin $checkedPaths)) {
                $checkedPaths += $nvmNodePath
                $foundNodes += [PSCustomObject]@{
                    Source   = "nvm-windows"
                    Version  = $ver
                    Path     = $nvmNodePath
                    NpmVersion = $null
                    Is18Plus = [int]($ver -split '\.')[0] -ge 18
                }
                Write-Host "    nvm 管理的: v$ver" -ForegroundColor Gray
            }
        }
    }

    # fnm
    $fnmPath = $null
    try { $fnmPath = (Get-Command fnm -ErrorAction Stop).Source } catch { }
    if ($fnmPath) {
        # 不执行 fnm —— 理由同 nvm：它在用户可写目录里，而我们是管理员身份。
        # fnm 默认路径: $FNM_DIR/node-versions/v<ver>/installation/node.exe
        $fnmDir = if ($env:FNM_DIR) { $env:FNM_DIR } else { "${env:LOCALAPPDATA}\fnm" }
        $fnmVersionsRoot = Join-Path $fnmDir "node-versions"
        foreach ($verDir in @(Get-ChildItem -Path $fnmVersionsRoot -Directory -Filter 'v*' -ErrorAction SilentlyContinue)) {
            if ($verDir.Name -notmatch '^v(\d+\.\d+\.\d+)$') { continue }
            $ver = $matches[1]
            $fnmNodePath = Join-Path $verDir.FullName "installation\node.exe"
            if ((Test-Path $fnmNodePath) -and ($fnmNodePath -notin $checkedPaths)) {
                $checkedPaths += $fnmNodePath
                $foundNodes += [PSCustomObject]@{
                    Source   = "fnm"
                    Version  = $ver
                    Path     = $fnmNodePath
                    NpmVersion = $null
                    Is18Plus = [int]($ver -split '\.')[0] -ge 18
                }
                Write-Host "    fnm 管理的: v$ver" -ForegroundColor Gray
            }
        }
    }

    # volta
    $voltaPath = $null
    try { $voltaPath = (Get-Command volta -ErrorAction Stop).Source } catch { }
    if ($voltaPath) {
        # 不执行 volta —— 理由同 nvm：它在用户可写目录里，而我们是管理员身份。
        # Volta 把 node 放在 %LOCALAPPDATA%\Volta\tools\image\node\<version>\node.exe
        $voltaImageRoot = Join-Path "${env:LOCALAPPDATA}\Volta" "tools\image\node"
        foreach ($verDir in @(Get-ChildItem -Path $voltaImageRoot -Directory -ErrorAction SilentlyContinue)) {
            $voltaNode = Join-Path $verDir.FullName "node.exe"
            if (-not (Test-Path $voltaNode)) { continue }
            if ($voltaNode -in $checkedPaths) { continue }

            $ver = Get-ExecutableVersionString -ExePath $voltaNode -Argument '-v'
            $verClean = "$ver" -replace '^v', ''
            if (-not ($verClean -match '^\d+\.\d+\.\d+')) { continue }

            $checkedPaths += $voltaNode
            $foundNodes += [PSCustomObject]@{
                Source   = "Volta"
                Version  = $verClean
                Path     = $voltaNode
                NpmVersion = $null
                Is18Plus = ([int](($verClean -split '\.')[0])) -ge 18
            }
            Write-Host "    Volta 管理的: v$verClean" -ForegroundColor Gray
        }
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
                $ver = Get-ExecutableVersionString -ExePath $gitExe -Argument '--version'
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
                            $ver = Get-ExecutableVersionString -ExePath $gitExe -Argument '--version'
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

    # 干跑：不联网、不下载、不安装，只报告将要做什么。
    # 注意要放在版本查询之前 —— 否则干跑还是会去请求 GitHub API。
    if ($Script:DryRun) {
        Write-Host "  [干跑] 本机没有可用的 Git，实际运行时会执行：" -ForegroundColor Magenta
        Write-Host "         1. 查询最新版本（GitHub Releases API；失败则用内置兜底版本 $($Script:Config.GitFallbackTag)）" -ForegroundColor DarkGray
        Write-Host "         2. 下载 Git-<版本>-64-bit.exe（GitHub 官方 → 清华 TUNA → 南大 NJU）" -ForegroundColor DarkGray
        Write-Host "         3. 校验 SHA256（.sha256sum 同样三源回退，全取不到则须人工确认后才继续）" -ForegroundColor DarkGray
        Write-Host "         4. 校验 Authenticode 签名（签名主体须在允许名单内）" -ForegroundColor DarkGray
        Write-Host "         5. 静默安装：/VERYSILENT /NORESTART /DIR=`"${env:ProgramFiles}\Git`"" -ForegroundColor DarkGray
        Write-Host "  [干跑] 未查询版本、未下载、未安装。" -ForegroundColor Magenta
        return $true
    }

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
        $gitFullTag = $Script:Config.GitFallbackTag
        $gitBaseVer = $Script:Config.GitFallbackBaseVer
    }

    # 版本标识来自网络（GitHub API）或内置兜底，会被拼进下载 URL 与文件名。
    # 用字符白名单卡住形状，挡住引号 / 空白 / 路径分隔符等非预期字符 ——
    # 这样即便 API 被投毒返回了奇怪字符串，也进不了 URL 和命令行。
    if ($gitFullTag -notmatch '^[A-Za-z0-9._-]+$' -or $gitBaseVer -notmatch '^\d+\.\d+\.\d+$') {
        Write-ErrorLog -Reason "Git 版本标识格式异常，拒绝使用（tag='$gitFullTag' base='$gitBaseVer'）"
        exit 1
    }

    $tempDir = Get-SafeTempDir -Purpose "Git 安装"
    $installerPath = Join-Path $tempDir "Git-Installer_$([guid]::NewGuid().ToString()).exe"

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

    # 记录「最终用的是本地离线包还是下载来的包」——哈希校验要不要跳过，
    # 必须以这个标志为准，不能靠文件名推断（见下方哈希段的说明）。
    $usingLocalInstaller = $false

    $downloadSuccess = Invoke-DownloadWithRetry -Urls $downloadUrls -OutFile $installerPath `
        -MaxRetries 3 -Description "Git for Windows"

    if (-not $downloadSuccess) {
        Write-Host ""
        Write-Host ">>> 联网下载失败，尝试使用本地安装包..." -ForegroundColor Yellow

        $localInstaller = Find-LocalInstaller -Pattern "Git*.exe" -Description "Git for Windows"
        if ($localInstaller) {
            $installerPath = $localInstaller
            $usingLocalInstaller = $true
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

    # 0. SHA256 哈希校验 + Authenticode 数字签名验证
    Write-Host "  🔐 正在验证 Git 安装包完整性..." -ForegroundColor Gray
    $gitVerified = $false
    $gitVerifyReason = "所有校验通道均不可用"
    # 哈希不匹配的处置必须放到 try/catch 之外做（见循环后面的说明）
    $gitHashMismatch = $false
    $gitMismatchSource = ""
    $gitMismatchExpected = ""
    $gitMismatchActual = ""

    # 方案 A：下载 SHA256 校验文件（GitHub 官方 → 清华 TUNA → 南大 NJU）
    # 校验和来源与安装包来源「不同源」才是最理想的（官方哈希 + 镜像二进制），
    # 所以官方源优先；但官方源不可达恰恰是脚本内置镜像的原因，此时若直接
    # "跳过验证"，就在最需要校验的场景下放行了。因此这里的镜像回退是必要的
    # ——它弱一些（镜像能同时改包和改哈希），但强于零校验。
    $gitChecksumUrls = @(
        "https://github.com/git-for-windows/git/releases/download/$gitFullTag/$gitFileName.sha256sum",
        "https://mirrors.tuna.tsinghua.edu.cn/github-release/git-for-windows/git/$gitFullTag/$gitFileName.sha256sum",
        "https://mirrors.nju.edu.cn/github-release/git-for-windows/git/$gitFullTag/$gitFileName.sha256sum"
    )
    foreach ($gitChecksumUrl in $gitChecksumUrls) {
        try {
            $gitChecksumContent = Invoke-WebRequest -Uri $gitChecksumUrl -UseBasicParsing -TimeoutSec 15 |
                                  Select-Object -ExpandProperty Content
            if (-not $gitChecksumContent) { continue }
            $expectedHash = ($gitChecksumContent -split '\s+')[0].Trim().ToLowerInvariant()
            if (-not $expectedHash) { continue }

            # 只有「确实在用本地离线包」时才跳过哈希比对：本地包多半是另一个
            # 版本，与待下载版本的 .sha256sum 天然对不上 —— 那不是篡改，只是
            # 版本不同，硬比对会误报"已被篡改"并中止安装。
            #
            # ⚠️ 判据必须是这个显式标志，绝不能写成「文件名是否等于官方名」：
            #    下载路径把文件存成 GUID 临时名（Git-Installer_<guid>.exe），
            #    文件名永远不等于官方名，那样写会把【下载后的哈希校验整条关死】，
            #    让下面所有多源校验逻辑变成死代码。这是踩过的坑。
            if ($usingLocalInstaller) {
                $gitInstallerLeaf = Split-Path -Path $installerPath -Leaf
                $gitVerifyReason = "使用的是本地离线包（$gitInstallerLeaf），版本可能与待下载版本不同，跳过哈希比对"
                Write-Host "  ℹ️  $gitVerifyReason（改用签名校验）" -ForegroundColor DarkYellow
                break
            }

            $gitHashResult = Test-FileHash -FilePath $installerPath -ExpectedHash $expectedHash -Description "Git"
            if ($gitHashResult.Outcome -eq 'Match') {
                $gitVerified = $true
                break
            }
            if ($gitHashResult.Outcome -eq 'Mismatch') {
                # 只记状态、跳出循环；真正的中止放到 try/catch 之外执行。
                # ⚠️ 不能在这里直接 exit 1：Write-ErrorLog 末尾会 Read-Host，
                #    在输入被重定向的环境（管道 / 计划任务）里它会抛
                #    "Cannot read keys when ... redirected"，异常会被本层的
                #    catch 吞掉 —— 于是"已中止"被跳过、循环继续试下一个校验和
                #    来源，那正是"哈希不匹配却继续安装"的路径。
                $gitHashMismatch   = $true
                $gitMismatchSource = $gitChecksumUrl
                $gitMismatchExpected = $expectedHash
                $gitMismatchActual = $gitHashResult.Actual
                break
            }
            # 'Unavailable' = 校验和拿到了，但本机算不出哈希。换别的校验和来源
            # 解决不了这个问题，所以记下原因后跳出，交给 Authenticode 或人工确认。
            # 注意这里绝不能当成"校验失败"处理 —— 那会报出误导性的"已被篡改"。
            $gitVerifyReason = "校验和已取到，但本机无法计算哈希：$($gitHashResult.Error)"
            Write-Host "  ⚠️  本机无法计算哈希，跳过哈希通道" -ForegroundColor DarkYellow
            break
        } catch {
            Write-Host "  ⚠️  该校验和来源不可用: $gitChecksumUrl" -ForegroundColor DarkGray
        }
    }

    # ── 哈希不匹配：在 try/catch 之外中止 ──
    # 哈希算出来了但对不上，这比"拿不到哈希"严重得多，不给任何"继续安装"的机会。
    if ($gitHashMismatch) {
        Write-Host "  ❌ Git 安装包 SHA256 与校验文件不符，已中止安装。" -ForegroundColor Red
        Write-Host "     校验和来源: $gitMismatchSource" -ForegroundColor Yellow
        Write-ErrorLog -Reason "Git 安装包 SHA256 校验不通过（预期 $gitMismatchExpected，实际 $gitMismatchActual，可能已被篡改）"
        exit 1
    }

    # 方案 B：Authenticode 数字签名验证 —— 必须同时匹配官方签名主体
    if (-not $gitVerified) {
        try {
            $sig = Get-AuthenticodeSignature -FilePath $installerPath -ErrorAction SilentlyContinue
            $signerSubject = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { "" }
            if ($sig.Status -eq 'Valid') {
                # ⚠️ 只判 'Valid' 是不够的：任何一家受信任 CA 签发的有效证书都能
                #    签出一个伪装包，状态同样是 'Valid'。必须确认签名主体。
                #    比较用【精确 CN 相等】，不用 -like 子串 —— 子串会让
                #    "O=Git for Windows Ltd" 这类主体混过去。
                #    （自签证书走不到这里：那种情况 Status 是 NotTrusted。）
                $signerCn = Get-CertificateCommonName -Subject $signerSubject
                $signerAllowed = $false
                foreach ($allowed in $Script:Config.GitAllowedSigners) {
                    if ($signerCn -and $signerCn -eq $allowed) { $signerAllowed = $true; break }
                }
                if ($signerAllowed) {
                    Write-Host "  ✓ Authenticode 数字签名验证通过" -ForegroundColor Green
                    Write-Host "    签名者: $signerSubject" -ForegroundColor Gray
                    $gitVerified = $true
                } else {
                    $gitVerifyReason = "签名有效，但签名主体 CN 不在允许名单内（实际 CN: $signerCn）"
                    Write-Host "  ⚠️  $gitVerifyReason" -ForegroundColor Yellow
                }
            } elseif ($sig.Status -eq 'NotSigned') {
                $gitVerifyReason = "安装包没有数字签名（可能不是官方构建）"
                Write-Host "  ⚠️  $gitVerifyReason" -ForegroundColor Yellow
            } else {
                $gitVerifyReason = "签名状态异常: $($sig.Status)"
                Write-Host "  ⚠️  $gitVerifyReason" -ForegroundColor Yellow
            }
        } catch {
            $gitVerifyReason = "Authenticode 验证异常: $_"
            Write-Host "  ⚠️  $gitVerifyReason" -ForegroundColor DarkYellow
        }
    }

    # 方案 C：两条通道都失败 → fail-closed
    # 旧实现在这里只打印一句警告就继续安装 —— 等于把最需要校验的场景直接放行，
    # 同时让"校验代码存在"制造出「已经验过了」的错觉。
    if (-not $gitVerified) {
        if (-not (Confirm-UnverifiedInstaller -Name "Git" -Path $installerPath -Detail $gitVerifyReason)) {
            Write-ErrorLog -Reason "Git 安装包无法校验（$gitVerifyReason），用户选择中止安装"
            exit 1
        }
    }

    # 1. 解除 "Mark of the Web"（下载的文件被 Windows 安全阻止）
    try {
        Unblock-File -Path $installerPath -ErrorAction SilentlyContinue
        Write-Host "  ✓ 已解除文件安全阻止" -ForegroundColor Gray
    } catch {
        Write-Host "  ⚠ Unblock-File 失败（非关键）: $_" -ForegroundColor DarkYellow
    }

    # 2. 校验安装包完整性
    if (-not (Test-Path $installerPath)) {
        Write-ErrorLog -Reason "Git 安装包不存在: $installerPath"; exit 1
    }
    $gitFileSize = (Get-Item $installerPath).Length
    if ($gitFileSize -lt 1048576) {
        Write-ErrorLog -Reason "Git 安装包过小 ($gitFileSize bytes)，可能下载不完整"; exit 1
    }
    Write-Host "  ✓ Git 安装包大小: $([math]::Round($gitFileSize/1MB, 1)) MB" -ForegroundColor Gray

    # 3. Git 静默安装参数
    # ⚠️ 含空格的参数必须自己加引号：Start-Process -ArgumentList 收到数组时是
    #    用空格拼接成一个命令行字符串，并不会替你加引号。于是 Program Files
    #    里的空格会把 /DIR 截断成 C:\Program（/LOG 同理）。
    #    同一个文件对 MSI 参数就正确加了引号（见 Node 段的 "/l*v" "`"$msiLogPath`""），
    #    所以这里是遗漏，不是有意为之。
    # ⚠️ 日志文件名带 GUID：固定的文件名落在公共 %TEMP% 里，会让同机器的
    #    低权限用户有机会预置符号链接 / 硬链接，诱导以管理员运行的安装器
    #    覆写任意文件。随机名让"预置"无法实施。
    $gitLogPath = Join-Path $tempDir "git-install-$([guid]::NewGuid().ToString()).log"
    $installArgs = @(
        "/VERYSILENT",
        "/NORESTART",
        "/CLOSEAPPLICATIONS",
        "/SUPPRESSMSGBOXES",
        "/LOG=`"$gitLogPath`"",
        "/DIR=`"${env:ProgramFiles}\Git`""
    )

    $gitSuccess = $false
    $maxGitRetries = 2

    for ($gitAttempt = 1; $gitAttempt -le $maxGitRetries; $gitAttempt++) {
        if ($gitAttempt -gt 1) {
            Write-Host "  等待 10s 后重试 Git 安装 (第 $gitAttempt/$maxGitRetries 次)..." -ForegroundColor Yellow
            Start-Sleep -Seconds 10
        }

        Write-Host "  执行: $installerPath /VERYSILENT (第 $gitAttempt/$maxGitRetries 次)" -ForegroundColor Gray

        $gitExitCode = -1
        try {
            $process = Start-Process -FilePath $installerPath -ArgumentList $installArgs -Wait -PassThru -NoNewWindow
            $gitExitCode = $process.ExitCode
        } catch {
            Write-Host "  ⚠ Start-Process 异常: $_" -ForegroundColor DarkYellow
            $gitExitCode = -999
        }

        Write-Host "  Git 安装退出码: $gitExitCode" -ForegroundColor Gray

        if ($gitExitCode -eq 0) {
            Write-Host "  ✓ Git 安装成功" -ForegroundColor Green
            $gitSuccess = $true
            break
        } else {
            Write-Host "  ⚠ Git 安装返回非零退出码: $gitExitCode" -ForegroundColor Yellow
            if (Test-Path $gitLogPath) {
                Write-Host "  日志: $gitLogPath" -ForegroundColor Gray
            }
        }
    }

    # 刷新环境变量
    $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath    = [System.Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = ($machinePath, $userPath | Where-Object { $_ } ) -join ";"

    # 4. 验证安装（检查实际文件，不只看退出码）
    Write-Host "`n=== Verifying Git Installation ===" -ForegroundColor Cyan

    # 检查 git.exe 是否真的写入了磁盘（更可靠的方式）
    $gitExeCandidatePaths = @(
        "${env:ProgramFiles}\Git\bin\git.exe",
        "${env:ProgramFiles}\Git\cmd\git.exe",
        "${env:ProgramFiles(x86)}\Git\bin\git.exe",
        "${env:ProgramFiles(x86)}\Git\cmd\git.exe"
    )
    $gitVerified = $false
    foreach ($testPath in $gitExeCandidatePaths) {
        if (Test-Path $testPath) {
            try {
                $ver = & $testPath --version 2>$null
                Write-Host "✓ Git 验证成功: $ver ($testPath)" -ForegroundColor Green
                $gitVerified = $true
                break
            } catch { }
        }
    }

    if (-not $gitVerified) {
        $gitCmd = Get-Command git -ErrorAction SilentlyContinue
        if ($gitCmd) {
            $gitVersionOut = & git --version 2>$null
            Write-Host "Git version: $gitVersionOut" -ForegroundColor Green
            Write-Host "`n✓ Git installed successfully!" -ForegroundColor Green
            $gitVerified = $true
        }
    }

    if (-not $gitVerified) {
        Write-Host "⚠ Git installation may have issues — 未检测到 git.exe" -ForegroundColor Yellow
        Write-Host "  Check log: $gitLogPath" -ForegroundColor Gray
        Write-Host "  Please restart your terminal, or run:" -ForegroundColor Yellow
        Write-Host "  `$env:Path = ([System.Environment]::GetEnvironmentVariable('Path','Machine'), [System.Environment]::GetEnvironmentVariable('Path','User') | Where-Object { `$_ } ) -join ';'" -ForegroundColor Gray
    }

    # 清理
    Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue
    Write-Host "`nCleaned up Git installer file." -ForegroundColor Gray

    # 返回真实结果：之前无论成功失败都 return $true，
    # 调用方也就不可能发现安装失败
    return [bool]$gitVerified
}

# ============================================================
# 创建桌面快捷方式 — 自动切换到任务文件夹启动 Claude Code
# ============================================================
function New-ClaudeShortcut {
    <#
    .SYNOPSIS
        在桌面生成 Claude Code 快捷方式，双击通过安全启动器启动 Claude Code
    .DESCRIPTION
        快捷方式 → powershell.exe → claude-launcher.ps1 → DPAPI 内存解密 API Key → claude
        API Key 全程不落盘，仅在内存中解密后传递给 Claude Code 进程
    .PARAMETER ProjectDir
        项目/任务文件夹路径
    .PARAMETER ShortcutName
        快捷方式显示名称（默认 "Claude Code"）
    #>
    param(
        [string]$ProjectDir,
        [string]$ShortcutName = "Claude Code"
    )

    $desktop = [Environment]::GetFolderPath("Desktop")
    $shortcutPath = Join-Path $desktop "$ShortcutName.lnk"
    $launcherPath = Join-Path $ProjectDir "claude-launcher.ps1"

    Write-Host ""
    Write-Host ">>> 正在生成桌面快捷方式（安全启动器模式）..." -ForegroundColor Yellow

    try {
        $wsShell = New-Object -ComObject WScript.Shell
        $shortcut = $wsShell.CreateShortcut($shortcutPath)

        # 两种模式的实际行为完全不同，先记下来 —— 否则回退模式下也会打印
        # "API Key 内存解密"，而回退模式根本不解密、也没有 Key 可解密。
        $usesLauncher = Test-Path $launcherPath

        # 首选：通过启动器脚本启动（启动器在内存中解密 API Key 后启动 Claude Code）
        if ($usesLauncher) {
            $shortcut.TargetPath       = "powershell.exe"
            $shortcut.Arguments        = "-NoProfile -ExecutionPolicy Bypass -File `"$launcherPath`""
            $shortcut.Description      = "Claude Code — DPAPI 加密启动 (内存解密 API Key)"
        }
        else {
            # 回退：没有启动器脚本（未配置 API Key，或启动器生成失败），直接启动 claude
            $shortcut.TargetPath       = "cmd.exe"
            $shortcut.Arguments        = "/k `"cd /d `"$ProjectDir`" && claude`""
            $shortcut.Description      = "Claude Code — 自动切换到 $ProjectDir"
        }
        $shortcut.WorkingDirectory = $ProjectDir
        $shortcut.WindowStyle      = 1  # 正常窗口

        # 尝试使用 Node.js 图标（如果存在），否则使用默认 PowerShell 图标
        $nodeIcon = "${env:ProgramFiles}\nodejs\node.exe"
        if (Test-Path $nodeIcon) {
            $shortcut.IconLocation = "$nodeIcon,0"
        }

        $shortcut.Save()

        # Save() 没抛异常不等于文件真的落盘了，必须校验
        if (-not (Test-Path $shortcutPath)) {
            Write-Host "  ⚠️  快捷方式 Save() 未报错，但文件并未生成: $shortcutPath" -ForegroundColor Yellow
            return $null
        }

        Write-Host "  ✅ 桌面快捷方式已创建: $shortcutPath" -ForegroundColor Green
        if ($usesLauncher) {
            Write-Host "     双击即可安全启动 Claude Code (API Key 内存解密)" -ForegroundColor Gray
            Write-Host "     目标: powershell.exe → claude-launcher.ps1 → claude" -ForegroundColor Gray
        } else {
            Write-Host "     目标: cmd.exe → claude（未使用启动器，不会解密 API Key）" -ForegroundColor Gray
            Write-Host "     ⚠️  未找到启动器脚本，此快捷方式不会注入 API Key。" -ForegroundColor Yellow
            Write-Host "        如果你用 DPAPI 保存过 Key，请重新运行安装脚本以生成启动器。" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "  ⚠️  快捷方式生成失败: $_" -ForegroundColor DarkYellow
        Write-Host "     可手动创建快捷方式，目标设为:" -ForegroundColor Yellow
        Write-Host "     powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$launcherPath`"" -ForegroundColor White
    }

    return $shortcutPath
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
elseif ($Script:DryRun) {
    # 干跑：不联网、不下载、不安装。这里单独成一个分支，避免把下面
    # 三百行的安装主体整体缩进一层（diff 会变得没法读）。
    Write-Host "  [干跑] 本机没有可用的 Node.js 18+，实际运行时会执行：" -ForegroundColor Magenta
    Write-Host "         1. 获取最新 LTS 版本号（nodejs.org → npmmirror 回退；都取不到则用内置兜底 $($Script:Config.NodeFallbackVersion)）" -ForegroundColor DarkGray
    Write-Host "         2. 下载 node-<版本>-win-x64.msi（官方 → npmmirror ×2 回退）" -ForegroundColor DarkGray
    Write-Host "         3. 校验 SHA256（SHASUMS256.txt 三源回退，全取不到则须人工确认后才继续）" -ForegroundColor DarkGray
    Write-Host "         4. msiexec /i <msi> /quiet /norestart ADDLOCAL=ALL（失败会重试并回退到直接运行 MSI）" -ForegroundColor DarkGray
    Write-Host "  [干跑] 未联网、未下载、未安装。" -ForegroundColor Magenta
    Write-Host ""
}
else {
    # 记录「安装前 node.exe 是否已经存在」。
    # 用途见下面 MSI 失败后的兜底检查：光凭"磁盘上有 node.exe"不能证明
    # 是【本次】装上去的 —— 本机可能早就有一个（旧版本）Node。
    $nodeExistedBeforeInstall = @(
        "${env:ProgramFiles}\nodejs\node.exe",
        "${env:ProgramFiles(x86)}\nodejs\node.exe"
    ) | Where-Object { Test-Path $_ }

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
        # 内置兜底版本（见文件顶部配置区）。只在 nodejs.org 与 npmmirror
        # 的版本清单都取不到时才会走到这里。
        $latestVersion = $Script:Config.NodeFallbackVersion
        Write-Host "使用内置兜底版本: $latestVersion（可能不是最新 LTS）" -ForegroundColor Yellow
    }
    else {
        Write-Host "Latest Node.js 18+ version: $latestVersion" -ForegroundColor Green
    }

    # 版本号来自网络（或内置兜底），会被拼进下载 URL、文件名与日志路径。
    # Node 的版本号形状是固定的，用严格正则卡住。
    if ($latestVersion -notmatch '^v\d+\.\d+\.\d+$') {
        Write-ErrorLog -Reason "Node.js 版本号格式异常，拒绝使用: '$latestVersion'"
        exit 1
    }

    # 本地路径加 GUID 防冲突（比 Get-Random 更安全的唯一性保证）
    $tempDir = Get-SafeTempDir -Purpose "Node.js 安装"
    $installerPath = Join-Path $tempDir "node-$latestVersion-win-$arch-$([guid]::NewGuid().ToString()).msi"

    Write-Host "Downloading Node.js $latestVersion ..." -ForegroundColor Yellow

    # 构建多源下载 URL 列表（官方 → 国内镜像）
    # ⚠️ 注意: 镜像源为第三方维护，存在文件被篡改风险。脚本会在下载后验证 SHA256 哈希。
    $nodeUrlFilename = "node-$latestVersion-$arch.msi"
    $nodeDownloadUrls = @(
        "https://nodejs.org/dist/$latestVersion/$nodeUrlFilename",
        "https://npmmirror.com/mirrors/node/$latestVersion/$nodeUrlFilename",
        "https://registry.npmmirror.com/-/binary/node/$latestVersion/$nodeUrlFilename"
    )

    # 同 Git 段：哈希校验要不要跳过，以这个显式标志为准（见下方哈希段的说明）
    $usingLocalInstaller = $false

    $downloadSuccess = Invoke-DownloadWithRetry -Urls $nodeDownloadUrls -OutFile $installerPath `
        -MaxRetries 3 -Description "Node.js $latestVersion"

    if (-not $downloadSuccess) {
        Write-Host ""
        Write-Host ">>> 联网下载失败，尝试使用本地安装包..." -ForegroundColor Yellow

        $localInstaller = Find-LocalInstaller -Pattern "node*.msi" -Description "Node.js"
        if ($localInstaller) {
            $installerPath = $localInstaller
            $usingLocalInstaller = $true
            Write-Host "  ✓ 将使用本地安装包: $installerPath" -ForegroundColor Green
        }
        else {
            Write-Host "❌ Node.js 下载失败 — 所有在线源均不可用，且未找到本地安装包" -ForegroundColor Red
            Write-Host "  请将 Node.js 的 .msi 安装包放置在脚本同目录下后重试" -ForegroundColor Yellow
            Write-ErrorLog -Reason "Node.js 下载失败（在线源+本地均不可用）"; exit 1
        }
    }

    Write-Host "Installing Node.js $latestVersion (this may take a few minutes)..." -ForegroundColor Yellow

    # ═══════════════════════════════════════════════════════════════
    # 安装前准备：哈希校验 + 解锁文件 + 大小校验
    # ═══════════════════════════════════════════════════════════════

    # 0. SHA256 哈希校验（官方源优先，镜像回退）
    #    理想设计是「校验和来源 ≠ 二进制来源」（官方哈希 + 镜像二进制），
    #    所以 nodejs.org 优先。但 nodejs.org 不可达恰恰是脚本内置国内镜像的
    #    原因 —— 旧实现此时打印一句"跳过验证"就继续安装，于是最需要校验的
    #    场景（镜像下载 + 零校验）必然被放行。这里改为按镜像链回退取哈希，
    #    全取不到才进入 fail-closed 的人工确认。
    Write-Host "  🔐 正在验证 Node.js 安装包完整性..." -ForegroundColor Gray
    $nodeVerified = $false
    $nodeVerifyReason = "所有 SHASUMS256.txt 来源均不可达"
    # 哈希不匹配的处置同样放到 try/catch 之外（理由见 Git 段）
    $nodeHashMismatch = $false
    $nodeMismatchSource = ""
    $nodeMismatchExpected = ""
    $nodeMismatchActual = ""
    $nodeFileName = "node-$latestVersion-$arch.msi"
    $shasumsUrls = @(
        "https://nodejs.org/dist/$latestVersion/SHASUMS256.txt",
        "https://npmmirror.com/mirrors/node/$latestVersion/SHASUMS256.txt",
        "https://registry.npmmirror.com/-/binary/node/$latestVersion/SHASUMS256.txt"
    )
    foreach ($shasumsUrl in $shasumsUrls) {
        try {
            $shasumsContent = Invoke-WebRequest -Uri $shasumsUrl -UseBasicParsing -TimeoutSec 15 |
                              Select-Object -ExpandProperty Content
            if (-not $shasumsContent) { continue }
            # 用行尾锚点确保精确匹配文件名（防止 foo.msi 误匹配 foo.msi.sig）
            $expectedHash = ($shasumsContent -split "`n" |
                             Where-Object { $_ -match ([regex]::Escape($nodeFileName) + '\s*$') }) `
                             -replace '\s+\*.*$', '' -replace '\s+.*$', '' -replace '\s', ''
            if (-not $expectedHash) { continue }

            # 判据必须是显式标志，理由与 Git 段完全相同 ——
            # 下载路径存成 node-<ver>-win-x64-<guid>.msi，文件名永远不等于
            # 官方名 node-<ver>-x64.msi，用文件名判断会把哈希校验整条关死。
            if ($usingLocalInstaller) {
                $nodeInstallerLeaf = Split-Path -Path $installerPath -Leaf
                $nodeVerifyReason = "使用的是本地离线包（$nodeInstallerLeaf），版本可能与待下载版本不同，跳过哈希比对"
                Write-Host "  ℹ️  $nodeVerifyReason（改用签名校验）" -ForegroundColor DarkYellow
                break
            }

            $nodeHashResult = Test-FileHash -FilePath $installerPath -ExpectedHash $expectedHash -Description "Node.js"
            if ($nodeHashResult.Outcome -eq 'Match') {
                $nodeVerified = $true
                break
            }
            if ($nodeHashResult.Outcome -eq 'Mismatch') {
                # 同上：只记状态，中止放到 try/catch 之外
                $nodeHashMismatch   = $true
                $nodeMismatchSource = $shasumsUrl
                $nodeMismatchExpected = $expectedHash
                $nodeMismatchActual = $nodeHashResult.Actual
                break
            }
            # 'Unavailable' = 本机算不出哈希，换校验和来源也没用，
            # 记下原因后跳出，交给人工确认（绝不能当成"已被篡改"）
            $nodeVerifyReason = "校验和已取到，但本机无法计算哈希：$($nodeHashResult.Error)"
            Write-Host "  ⚠️  本机无法计算哈希，跳过哈希通道" -ForegroundColor DarkYellow
            break
        } catch {
            Write-Host "  ⚠️  该校验和来源不可用: $shasumsUrl" -ForegroundColor DarkGray
        }
    }

    # ── 哈希不匹配：在 try/catch 之外中止（理由见 Git 段）──
    if ($nodeHashMismatch) {
        Write-Host "  ❌ Node.js 安装包 SHA256 与校验文件不符，已中止安装。" -ForegroundColor Red
        Write-Host "     校验和来源: $nodeMismatchSource" -ForegroundColor Yellow
        Write-ErrorLog -Reason "Node.js SHA256 校验不通过（预期 $nodeMismatchExpected，实际 $nodeMismatchActual，可能已被篡改）"
        exit 1
    }

    # 第二道独立闸：Authenticode 签名主体（与 Git 段对称）。
    # 哈希取不到时它是【另一条验证通道】，而不是"跳过校验直接装"。
    # 这一点在 Node 上尤其重要 —— Node 的安装包会来自第三方镜像
    # （npmmirror），哈希来源也允许镜像回退。
    if (-not $nodeVerified) {
        try {
            $nodeSig = Get-AuthenticodeSignature -FilePath $installerPath -ErrorAction SilentlyContinue
            $nodeSignerSubject = if ($nodeSig.SignerCertificate) { $nodeSig.SignerCertificate.Subject } else { "" }
            if ($nodeSig.Status -eq 'Valid') {
                $nodeSignerCn = Get-CertificateCommonName -Subject $nodeSignerSubject
                $nodeSignerAllowed = $false
                foreach ($allowed in $Script:Config.NodeAllowedSigners) {
                    if ($nodeSignerCn -and $nodeSignerCn -eq $allowed) { $nodeSignerAllowed = $true; break }
                }
                if ($nodeSignerAllowed) {
                    Write-Host "  ✓ Authenticode 数字签名验证通过" -ForegroundColor Green
                    Write-Host "    签名者: $nodeSignerSubject" -ForegroundColor Gray
                    $nodeVerified = $true
                } else {
                    $nodeVerifyReason = "签名有效，但签名主体 CN 不在允许名单内（实际 CN: $nodeSignerCn）"
                    Write-Host "  ⚠️  $nodeVerifyReason" -ForegroundColor Yellow
                }
            } else {
                $nodeVerifyReason = "签名状态: $($nodeSig.Status)"
                Write-Host "  ⚠️  $nodeVerifyReason" -ForegroundColor Yellow
            }
        } catch {
            $nodeVerifyReason = "Authenticode 验证异常: $_"
            Write-Host "  ⚠️  $nodeVerifyReason" -ForegroundColor DarkYellow
        }
    }

    if (-not $nodeVerified) {
        # fail-closed —— 见 Confirm-UnverifiedInstaller 的说明
        if (-not (Confirm-UnverifiedInstaller -Name "Node.js" -Path $installerPath -Detail $nodeVerifyReason)) {
            Write-ErrorLog -Reason "Node.js 安装包无法校验（$nodeVerifyReason），用户选择中止安装"
            exit 1
        }
    }

    # 1. 解除 "Mark of the Web"（下载的文件被 Windows 阻止执行）
    try {
        Unblock-File -Path $installerPath -ErrorAction SilentlyContinue
        Write-Host "  ✓ 已解除文件安全阻止" -ForegroundColor Gray
    } catch {
        Write-Host "  ⚠ Unblock-File 失败（非关键）: $_" -ForegroundColor DarkYellow
    }

    # 2. 校验 MSI 文件完整性（MSI 文件头应为 D0 CF 11 E0）
    if (-not (Test-Path $installerPath)) {
        Write-ErrorLog -Reason "Node.js MSI 文件不存在: $installerPath"; exit 1
    }
    $fileSize = (Get-Item $installerPath).Length
    if ($fileSize -lt 1024) {
        Write-ErrorLog -Reason "Node.js MSI 文件过小 ($fileSize bytes)，可能下载不完整"; exit 1
    }
    Write-Host "  ✓ MSI 文件大小: $([math]::Round($fileSize/1MB, 1)) MB" -ForegroundColor Gray

    # ============================================================
    # 执行 MSI 安装（带重试 + 日志 + 完整退出码处理）
    # ============================================================
    # 日志名带 GUID，理由与 Git 段相同（防公共 %TEMP% 里的符号链接 / 硬链接预置）
    $msiLogPath = Join-Path $tempDir "node-install-$latestVersion-$([guid]::NewGuid().ToString()).log"
    $maxMsiRetries = 3
    $msiSuccess = $false
    # switch 里的 break 只跳出 switch、不跳出外层 for（PowerShell 语义如此），
    # 所以"不再重试"必须靠这个标志传达给外层循环。
    $msiStopRetry = $false

    for ($msiAttempt = 1; $msiAttempt -le $maxMsiRetries; $msiAttempt++) {
        if ($msiAttempt -gt 1) {
            $waitSec = 10 * $msiAttempt
            Write-Host "  等待 ${waitSec}s 后重试 MSI 安装 (第 $msiAttempt/$maxMsiRetries 次)..." -ForegroundColor Yellow
            Start-Sleep -Seconds $waitSec
        }

        # 安装参数说明：
        #   /i           安装 MSI
        #   /quiet       静默安装（无 UI）
        #   /norestart   不自动重启
        #   /l*v         详细日志（关键！用于诊断失败原因）
        #   ADDLOCAL=ALL 安装所有特性
        $installArgs = @(
            "/i", "`"$installerPath`"",
            "/quiet",
            "/norestart",
            "/l*v", "`"$msiLogPath`"",
            "ADDLOCAL=ALL"
        )

        Write-Host "  执行: msiexec /i ... /l*v $msiLogPath (第 $msiAttempt/$maxMsiRetries 次)" -ForegroundColor Gray

        $msiExitCode = -1
        try {
            $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $installArgs -Wait -PassThru -NoNewWindow
            $msiExitCode = $process.ExitCode
        } catch {
            Write-Host "  ⚠ Start-Process 异常: $_" -ForegroundColor DarkYellow
            $msiExitCode = -999
        }

        Write-Host "  MSI 退出码: $msiExitCode" -ForegroundColor Gray

        # 完整退出码处理（参考 Microsoft 官方文档）
        switch ($msiExitCode) {
            0 {
                Write-Host "  ✓ Node.js MSI 安装成功" -ForegroundColor Green
                $msiSuccess = $true
                break
            }
            3010 {
                Write-Host "  ✓ Node.js MSI 安装成功（需要重启以完成）" -ForegroundColor Green
                $msiSuccess = $true
                break
            }
            1618 {
                Write-Host "  ⚠ 另一个 MSI 安装正在进行中，等待后重试..." -ForegroundColor Yellow
                continue  # 重试
            }
            1602 {
                Write-Host "  ❌ 用户取消了安装" -ForegroundColor Red
                $msiStopRetry = $true
                break
            }
            1603 {
                Write-Host "  ❌ MSI 安装致命错误 (1603) — 检查日志: $msiLogPath" -ForegroundColor Red
                # 输出日志尾部帮助诊断
                if (Test-Path $msiLogPath) {
                    Write-Host "  ── 日志尾部 ──" -ForegroundColor Gray
                    try {
                        $logTail = Get-Content $msiLogPath -Tail 20 -ErrorAction SilentlyContinue
                        foreach ($logLine in $logTail) { Write-Host "    $logLine" -ForegroundColor DarkGray }
                    } catch { }
                }
                $msiStopRetry = $true
                break
            }
            1619 {
                Write-Host "  ❌ MSI 文件无法打开 (1619) — 路径: $installerPath" -ForegroundColor Red
                Write-Host "    可能原因: 路径权限不足、文件被锁定、杀软拦截" -ForegroundColor Yellow
                $msiStopRetry = $true
                break
            }
            default {
                Write-Host "  ❌ MSI 安装失败 (退出码: $msiExitCode)" -ForegroundColor Red
                Write-Host "    完整日志: $msiLogPath" -ForegroundColor Gray
                if (Test-Path $msiLogPath) {
                    Write-Host "  ── 日志尾部 ──" -ForegroundColor Gray
                    try {
                        $logTail = Get-Content $msiLogPath -Tail 15 -ErrorAction SilentlyContinue
                        foreach ($logLine in $logTail) { Write-Host "    $logLine" -ForegroundColor DarkGray }
                    } catch { }
                }
                $msiStopRetry = $true
                break
            }
        }

        # 跳出 for 循环不能只靠 switch 里的 break —— 那出不了 switch。
        # 1618（另一个安装进行中）时两个标志都为 false，循环会正常重试，这是对的。
        if ($msiSuccess -or $msiStopRetry) { break }
    }

    # ═══════════════════════════════════════════════════════════════
    # 安装失败 → 尝试备用方案：直接执行 MSI（绕过 msiexec 路径解析问题）
    # ═══════════════════════════════════════════════════════════════
    if (-not $msiSuccess) {
        Write-Host ""
        Write-Host "  ⚠ msiexec 方式安装失败，尝试备用方案：直接运行 MSI..." -ForegroundColor Yellow

        try {
            # 直接调用 .msi 文件，让 Windows Installer 服务处理
            $fallbackArgs = @("/quiet", "/norestart", "/l*v", "`"$msiLogPath-fallback`"")
            $fbProcess = Start-Process -FilePath $installerPath -ArgumentList $fallbackArgs -Wait -PassThru -NoNewWindow
            Write-Host "  备用方案退出码: $($fbProcess.ExitCode)" -ForegroundColor Gray

            if ($fbProcess.ExitCode -eq 0 -or $fbProcess.ExitCode -eq 3010) {
                Write-Host "  ✓ 备用方案安装成功" -ForegroundColor Green
                $msiSuccess = $true
            }
        } catch {
            Write-Host "  ❌ 备用方案也失败: $_" -ForegroundColor Red
        }
    }

    # ═══════════════════════════════════════════════════════════════
    # 最终检查：验证 node.exe 是否已安装到目标目录
    # ═══════════════════════════════════════════════════════════════
    if (-not $msiSuccess) {
        # 即使 MSI 返回非零，也可能部分安装成功 — 检查实际文件
        $possibleNodeExes = @(
            "${env:ProgramFiles}\nodejs\node.exe",
            "${env:ProgramFiles(x86)}\nodejs\node.exe"
        )
        $foundNode = $false
        foreach ($testExe in $possibleNodeExes) {
            if (Test-Path $testExe) {
                if ($nodeExistedBeforeInstall.Count -gt 0) {
                    # ⚠️ 这个 node.exe 在本次安装【之前】就在了，它出现在磁盘上
                    #    不能证明本次安装成功。若不区分，就会把用户早就装好的 Node
                    #    记成"本脚本安装的"，卸载时连根拔掉 —— 正是哨兵机制要防的事。
                    Write-Host "  ⚠ 发现已存在的 node（本次安装前就在）: $testExe" -ForegroundColor Yellow
                    Write-Host "     不能据此判定本次安装成功" -ForegroundColor Yellow
                    continue
                }
                try {
                    $testVer = Get-ExecutableVersionString -ExePath $testExe -Argument '-v'
                    Write-Host "  ℹ️ 虽然 MSI 返回非零，但发现已安装的 node: $testVer ($testExe)" -ForegroundColor Yellow
                    $foundNode = $true
                    $msiSuccess = $true
                } catch { }
            }
        }

        if (-not $foundNode) {
            Write-Host ""
            Write-Host "============================================================" -ForegroundColor Red
            Write-Host "  ❌ Node.js 安装失败" -ForegroundColor Red
            Write-Host "============================================================" -ForegroundColor Red
            Write-Host "  诊断日志: $msiLogPath" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  常见原因:" -ForegroundColor Yellow
            Write-Host "  1. Windows Installer 服务未运行" -ForegroundColor White
            Write-Host "  2. 杀毒软件拦截了安装程序" -ForegroundColor White
            Write-Host "  3. C 盘空间不足" -ForegroundColor White
            Write-Host "  4. 系统策略禁止 MSI 安装" -ForegroundColor White
            Write-Host ""
            Write-Host "  手动排查:" -ForegroundColor Yellow
            Write-Host "    sc query msiserver          # 检查 Windows Installer 服务" -ForegroundColor Gray
            Write-Host "    msiexec /i $installerPath   # 手动运行安装（查看错误）" -ForegroundColor Gray
            Write-Host "============================================================" -ForegroundColor Red
            Write-ErrorLog -Reason "Node.js MSI 安装失败 (退出码: $msiExitCode, 日志: $msiLogPath)"; exit 1
        }
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

    # 记录：Node.js 确实由本脚本安装（供卸载脚本判断，避免误删用户预装的 Node.js）
    if (-not $Script:DryRun) { $Script:NodeInstalledByUs = $true }

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
    $gitOk = Install-Git
    if ($Script:DryRun) {
        # 干跑模式 Install-Git 只报告不安装，不据其返回值判定失败
    }
    elseif ($gitOk) {
        # 记录：Git 确实由本脚本安装（供卸载脚本判断，避免误删用户预装的 Git）
        $Script:GitInstalledByUs = $true
    }
    else {
        Write-Host ""
        Write-Host "❌ Git 安装失败 — 未能确认 git.exe 已就绪" -ForegroundColor Red
        Write-ErrorLog -Reason "Git 安装失败（安装程序返回失败，或安装后未检测到 git.exe）"
        exit 1
    }
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
    if ($Script:DryRun) {
        # 干跑下这只是"当前环境缺前置条件"，不该中止整个干跑报告
        Write-Host "  [干跑] 未检测到 npm —— 实际运行时这里会中止（缺 npm 就装不上 Claude Code）。" -ForegroundColor Magenta
    } else {
        Write-Host "❌ npm 不可用，无法安装 Claude Code。" -ForegroundColor Red
        # 不能只打印一行就继续 —— 否则脚本会一路走到"安装完成"横幅，退出码还是 0
        Write-ErrorLog -Reason "npm 不可用，无法安装 Claude Code（Node.js 可能未正确安装或 PATH 未生效）"
        exit 1
    }
}
else {
    # 先检查是否已安装
    $existingClaude = Get-Command claude -ErrorAction SilentlyContinue
    if ($existingClaude) {
        Write-Host ">>> Claude Code 已存在: $(& claude --version)，跳过安装。" -ForegroundColor Green
    }
    else {
        Write-Host ">>> 安装 @anthropic-ai/claude-code (支持重试和镜像)..." -ForegroundColor Yellow
        Write-Host "  ⚠️  注意: 若官方源失败将回退到第三方 npmmirror 镜像" -ForegroundColor DarkYellow

        $ccSuccess = Invoke-NpmInstallWithRetry -Package "@anthropic-ai/claude-code" -MaxRetries 3

        if ($ccSuccess) {
            if (-not $Script:DryRun) { Write-Host "✓ @anthropic-ai/claude-code 安装成功" -ForegroundColor Green }
            if (-not $Script:DryRun) { $Script:ClaudeCodeInstalledByUs = $true }

            # 核对包确实进了全局列表。
            # 旧实现在这里跑 `npm audit`，但传进作业的 $npmPath / $Package 是
            # Invoke-NpmInstallWithRetry 的局部变量，在主流程作用域里都是 $null，
            # 作业必然以 BadExpression 失败、再被 catch 吞掉 —— 一段从未生效过的死代码。
            # 而且 npm audit 对全局安装的包本来就不适用（它需要项目上下文）。
            # 换成 npm ls -g：没有作用域问题，而且真正回答了「装上了没有」。
            Write-Host "  🔍 正在核对全局包列表..." -ForegroundColor Gray
            try {
                $globalListJob = Start-Job -ScriptBlock {
                    param($npm)
                    & $npm ls -g --depth=0 2>&1 | Out-String
                } -ArgumentList $npmCmd.Source
                $globalList = $globalListJob | Wait-Job -Timeout 30 | Receive-Job
                Remove-Job $globalListJob -Force -ErrorAction SilentlyContinue

                if ($globalList -match '@anthropic-ai/claude-code') {
                    Write-Host "  ✓ 全局包列表已确认包含 @anthropic-ai/claude-code" -ForegroundColor Green
                } else {
                    Write-Host "  ⚠️  npm 全局列表中未看到 @anthropic-ai/claude-code，建议手动核对: npm ls -g" -ForegroundColor Yellow
                }
            } catch {
                Write-Host "  ℹ️  全局包列表核对不可用或超时，跳过（不影响安装结果）" -ForegroundColor Gray
            }

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
            # 最后一个回退也失败时必须中止，不能继续走到"安装完成"横幅
            Write-ErrorLog -Reason "Claude Code 安装失败（npm 官方源与第三方镜像均不可用）"
            exit 1
        }
    }
}

# ── DeepSeek 环境变量配置 ──
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  DeepSeek API 配置（Claude Code 后端）" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
if ($Script:DryRun) {
    # 干跑不读取、不加密、不写入任何密钥。这里直接把选择定成 N，
    # 下面自然走「跳过」分支，不碰注册表也不碰环境变量。
    Write-Host "  [干跑] 略过 API Key 输入与保存 —— 干跑不读取、不加密、不写任何密钥。" -ForegroundColor Magenta
    Write-Host "  [干跑] 实际运行时会询问是否配置 DeepSeek，并把 DPAPI 加密后的 Key 写入用户注册表。" -ForegroundColor Magenta
    Write-Host ""
    $configureDeepseek = 'N'
} else {
    Write-Host "是否配置 DeepSeek 作为 Claude Code 的 API 后端？" -ForegroundColor Yellow
    Write-Host "  [Y] 是，输入 API Key 进行配置" -ForegroundColor White
    Write-Host "  [N] 跳过（默认）" -ForegroundColor White
    Write-Host ""
    $configureDeepseek = Read-Host "请输入选择"
}

if ($configureDeepseek -eq 'Y' -or $configureDeepseek -eq 'y') {
    Write-Host ""
    Write-Host "  🔐 安全存储方案: Windows DPAPI 加密" -ForegroundColor Cyan
    Write-Host "  · API Key 使用 Windows 数据保护 API 加密后存入注册表" -ForegroundColor Gray
    Write-Host "  · 加密绑定到当前 Windows 用户 — 其他用户/机器无法解密" -ForegroundColor Gray
    Write-Host "  · 解密仅在内存中发生 — API Key 永不落盘为明文" -ForegroundColor Gray
    Write-Host "  · 桌面快捷方式 → 启动器脚本 → 内存解密 → 传给 claude" -ForegroundColor Gray
    Write-Host ""

    $secureKey = Read-Host "请输入你的 DeepSeek API Key" -AsSecureString
    $apiKey = [System.Net.NetworkCredential]::new('', $secureKey).Password

    if ($apiKey) {
        # ── 使用 DPAPI 加密 API Key ──
        Write-Host ""
        Write-Host "正在使用 DPAPI 加密 API Key..." -ForegroundColor Yellow
        $encryptedKey = Protect-ApiKey -PlainText $apiKey

        # ── 非敏感变量（模型名、URL）— 明文存注册表 ──
        # 取值集中在文件顶部的配置区，换模型 / 换端点不用翻流程代码
        $nonSensitiveVars = @{
            "ANTHROPIC_BASE_URL"              = $Script:Config.ApiBaseUrl
            "ANTHROPIC_MODEL"                 = $Script:Config.ModelPrimary
            "ANTHROPIC_DEFAULT_OPUS_MODEL"    = $Script:Config.ModelPrimary
            "ANTHROPIC_DEFAULT_SONNET_MODEL"  = $Script:Config.ModelPrimary
            "ANTHROPIC_DEFAULT_HAIKU_MODEL"   = $Script:Config.ModelSmall
            "CLAUDE_CODE_SUBAGENT_MODEL"      = $Script:Config.ModelSmall
            "CLAUDE_CODE_EFFORT_LEVEL"        = "max"
        }

        Write-Host "正在写入环境变量（用户级别注册表，持久化）..." -ForegroundColor Yellow

        # 写入加密的 API Key 到注册表，并【回读验证】。
        # 只写不读的话，万一写入被组策略/权限拦住、或 DPAPI 在当前上下文档
        # 解不开，安装阶段照样显示"✅ 已配置"，用户第一次双击快捷方式才发现
        # 解密失败 —— 最坏的"能启动但无法认证"。这里当场验证，把静默失败变显式。
        [System.Environment]::SetEnvironmentVariable("ANTHROPIC_AUTH_TOKEN_ENC", $encryptedKey, "User")
        $tokenReadBack = [System.Environment]::GetEnvironmentVariable("ANTHROPIC_AUTH_TOKEN_ENC", "User")
        $tokenReadBackOk = $false
        if ($tokenReadBack) {
            try {
                $tokenReadBackOk = ((Unprotect-ApiKey -Base64 $tokenReadBack) -eq $apiKey)
            } catch {
                Write-Host "  ❌ 回读校验失败：无法解密刚写入的密文 — $_" -ForegroundColor Red
            }
        }
        if (-not $tokenReadBackOk) {
            Write-Host "  ❌ API Key 回读校验失败：写入的值读不回、或解不开。" -ForegroundColor Red
            Write-Host "     可能是注册表写入被策略拦截，或 DPAPI 在当前上下文不可用。" -ForegroundColor Yellow
            Write-Host "     请以管理员身份重试；或临时设置 `$env:ANTHROPIC_AUTH_TOKEN 后直接启动。" -ForegroundColor Yellow
            Write-ErrorLog -Reason "API Key 写入后回读校验失败（密文不可读或无法解密）"
            exit 1
        }
        Write-Host "  ✓ `$env:ANTHROPIC_AUTH_TOKEN_ENC (DPAPI 加密，已回读验证可解密)" -ForegroundColor Green

        foreach ($varName in $nonSensitiveVars.Keys) {
            $varValue = $nonSensitiveVars[$varName]
            [System.Environment]::SetEnvironmentVariable($varName, $varValue, "User")
            # 同时设置当前会话
            Set-Item -Path "env:$varName" -Value $varValue -ErrorAction SilentlyContinue
            # 回读确认真的落到了用户注册表（理由同上面的 API Key 回读验证）
            $varReadBack = [System.Environment]::GetEnvironmentVariable($varName, "User")
            if ($varReadBack -eq $varValue) {
                Write-Host "  ✓ `$env:$varName" -ForegroundColor Green
            } else {
                Write-Host "  ❌ `$env:$varName 写入后回读不一致（读到: '$varReadBack'）" -ForegroundColor Red
                Write-ErrorLog -Reason "环境变量 $varName 写入用户注册表后回读校验失败"
                exit 1
            }
        }

        # 当前会话也设置解密的 API Key（内存中，不落盘）
        $env:ANTHROPIC_AUTH_TOKEN = $apiKey

        # ⚠️ 这里【不再】写 %TEMP%\claude-code-env-<pid>.ps1。
        # 那个临时文件通道已被父进程废弃（父进程现在直接从注册表读取并解密），
        # 继续写入没有任何作用，却持续留着一条「dot-source 用户可写目录里的 .ps1」
        # 的风险面。删掉它比加固它更省事、也更安全。
        Write-Host ""
        Write-Host "  ✓ 非敏感环境变量已写入注册表（不再使用临时文件通道）" -ForegroundColor Green
        Write-Host "    (API Key 不在任何文件中 — 仅加密 blob 存于注册表)" -ForegroundColor Gray

        # 清除内存中的明文 Key（函数返回后由 GC 回收；此变量不再引用）
        # 注意: $apiKey 和 $secureKey 将在作用域退出时释放
    }
    else {
        Write-Host "⚠ 未输入 API Key，跳过 DeepSeek 配置。" -ForegroundColor Yellow
    }
}
else {
    Write-Host ">>> 跳过 DeepSeek 配置。" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  后续可手动设置以下环境变量：" -ForegroundColor Gray
    Write-Host "  `$env:ANTHROPIC_AUTH_TOKEN='<你的 DeepSeek API Key>'" -ForegroundColor DarkGray
    Write-Host "    提示: 设置后 API Key 将以明文存入注册表，建议使用本脚本自动加密" -ForegroundColor DarkYellow
    Write-Host "  `$env:ANTHROPIC_BASE_URL='$($Script:Config.ApiBaseUrl)'" -ForegroundColor DarkGray
    Write-Host "  `$env:ANTHROPIC_MODEL='$($Script:Config.ModelPrimary)'" -ForegroundColor DarkGray
    Write-Host "  `$env:ANTHROPIC_DEFAULT_OPUS_MODEL='$($Script:Config.ModelPrimary)'" -ForegroundColor DarkGray
    Write-Host "  `$env:ANTHROPIC_DEFAULT_SONNET_MODEL='$($Script:Config.ModelPrimary)'" -ForegroundColor DarkGray
    Write-Host "  `$env:ANTHROPIC_DEFAULT_HAIKU_MODEL='$($Script:Config.ModelSmall)'" -ForegroundColor DarkGray
    Write-Host "  `$env:CLAUDE_CODE_SUBAGENT_MODEL='$($Script:Config.ModelSmall)'" -ForegroundColor DarkGray
    Write-Host "  `$env:CLAUDE_CODE_EFFORT_LEVEL='max'" -ForegroundColor DarkGray
    Write-Host ""
}

# ── Claude Code 归属标头（用户偏好，默认不改） ──
# 旧实现在这里【无条件】把 CLAUDE_CODE_ATTRIBUTION_HEADER=0 写进用户注册表，
# 不论用户是否配置了 DeepSeek。这是用户偏好项，不是安装必需项，不该替用户决定。
# 现在改为显式询问，默认保持系统默认（不动注册表）。
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Claude Code 归属标头 (隐私偏好)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Claude Code 默认会在请求里带一个归属标头，用于向上游标识客户端。" -ForegroundColor Gray
Write-Host "  关闭它会少发送一点信息，但不再帮助 Anthropic 改进产品。" -ForegroundColor Gray
Write-Host "  这是你的个人偏好，脚本默认不动它。" -ForegroundColor Gray
Write-Host ""

if ($Script:DryRun) {
    Write-Host "  [干跑] 此处本会询问是否关闭归属标头；干跑按「保持默认」处理，不写注册表。" -ForegroundColor Magenta
} else {
    Write-Host "  [Y] 关闭归属标头（设 CLAUDE_CODE_ATTRIBUTION_HEADER=0）" -ForegroundColor White
    Write-Host "  [N] 保持默认，不修改注册表（默认）" -ForegroundColor White
    Write-Host ""
    $setAttributionHeader = Read-Host "请输入选择"

    if ($setAttributionHeader -eq 'Y' -or $setAttributionHeader -eq 'y') {
        [System.Environment]::SetEnvironmentVariable("CLAUDE_CODE_ATTRIBUTION_HEADER", "0", "User")
        $env:CLAUDE_CODE_ATTRIBUTION_HEADER = "0"
        Write-Host "  ✓ 已关闭归属标头并持久化到用户注册表" -ForegroundColor Green
        Write-Host "    如需恢复默认，删除该环境变量即可" -ForegroundColor Gray
    } else {
        Write-Host "  ✅ 未修改归属标头设置（保持系统默认）" -ForegroundColor Green
    }
}
Write-Host ""

# ═══════════════════════════════════════════════════════════════
# 干跑模式到此收口 —— 以下全部是「写」操作
# 旧版 install.ps1 虽然接受 -DryRun，但只用它来跳过提权、跳过安装标记：
# 下载、装 Git / Node / Claude Code、写注册表、生成启动器与快捷方式
# 在干跑下全都会真实执行。一个声称"不下载 / 不安装 / 不写注册表"的开关
# 其实什么都写，比根本没有这个开关更危险。所以在进入写操作阶段前停下。
# ═══════════════════════════════════════════════════════════════
if ($Script:DryRun) {
    $dryRunDesktop    = [Environment]::GetFolderPath("Desktop")
    $dryRunProjectDir = Join-Path $dryRunDesktop "my-project"
    $dryRunLauncher   = Join-Path $dryRunProjectDir "claude-launcher.ps1"

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Magenta
    Write-Host "  干跑报告：以下操作在实际运行时才会执行" -ForegroundColor Magenta
    Write-Host "============================================================" -ForegroundColor Magenta
    Write-Host ""
    Write-Host "  1. 安装摘要日志：$dryRunDesktop\install-success-<时间戳>.txt" -ForegroundColor Gray
    Write-Host "  2. 项目目录：$dryRunProjectDir" -ForegroundColor Gray
    Write-Host "  3. 安全启动器：$dryRunLauncher（DPAPI 内存解密 API Key）" -ForegroundColor Gray
    Write-Host "     3b. 对该文件做 ACL 加固：仅当前用户 + SYSTEM 可修改" -ForegroundColor Gray
    Write-Host "     3c. 对项目目录做同样的 ACL 加固（只加固文件会被「删掉重建」绕过）" -ForegroundColor Gray
    Write-Host "  4. 桌面快捷方式：$dryRunDesktop\Claude Code.lnk" -ForegroundColor Gray
    Write-Host "  5. 安装标记（哨兵）：HKCU:\SOFTWARE\ClaudeCodeDeepSeekInstaller" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  本次干跑：未下载、未安装、未修改任何注册表项 / 环境变量 / 文件。" -ForegroundColor Magenta
    Write-Host "============================================================" -ForegroundColor Magenta
    Write-Host ""

    Invoke-ScriptCleanup
    Read-Host "按 Enter 键退出..."
    exit 0
}

# ── 成功摘要日志 ──
# 清除 API Key 环境变量后再运行验证命令（node -v, claude --version 等
# 不需要 API Key，避免敏感值被子进程和 $Error 日志捕获）
Remove-Item env:ANTHROPIC_AUTH_TOKEN -ErrorAction SilentlyContinue
$successLog = Join-Path ([Environment]::GetFolderPath("Desktop")) `
                      "install-success-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
try {
    $nodeVersion   = try { & node -v 2>$null } catch { "N/A" }
    $npmVersion    = try { & npm -v 2>$null } catch { "N/A" }
    $gitVersion    = try { & git --version 2>$null } catch { "N/A" }
    $claudeVersion = try { & claude --version 2>$null } catch { "N/A" }
    $keyEncrypted  = [System.Environment]::GetEnvironmentVariable("ANTHROPIC_AUTH_TOKEN_ENC", "User")
    $dsStatus      = if ($keyEncrypted) { "已配置 (DPAPI 加密)" } else { "未配置" }
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
  DeepSeek API : $dsStatus
  安全存储     : API Key 使用 Windows DPAPI 加密，永不落盘明文
  启动器       : claude-launcher.ps1 (内存解密 → 启动 claude)
============================================================
"@ | Out-File -FilePath $successLog -Encoding UTF8 -Force
}
catch { }

# 成功日志原来只是默默写到桌面，从不告诉用户（失败日志倒是有明确提示）。
# 结果就是"桌面多了一个文件，用户不知道它是干嘛的"，排错时也不会想到去看它。
if (Test-Path $successLog) {
    Write-Host "  ℹ️  安装摘要已保存到桌面: $(Split-Path -Leaf $successLog)" -ForegroundColor Gray
    Write-Host "     （若安装失败，桌面上的是 install-log-*.txt，那才是排错日志）" -ForegroundColor DarkGray
} else {
    Write-Host "  ⚠️  安装摘要日志未能写入桌面（不影响安装结果）" -ForegroundColor DarkYellow
}

# ── 最终汇总 ──
# 与提权父进程共用同一份实现（见文件上方的 Show-InstallSummary）
Show-InstallSummary

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

# ── 生成启动器脚本（内存解密 API Key，安全启动 Claude Code） ──
$launcherPath = Join-Path $projectDir "claude-launcher.ps1"
Write-Host ""
Write-Host ">>> 正在生成安全启动器脚本..." -ForegroundColor Yellow
try {
    @'
# Claude Code Launcher — 内存解密 API Key，安全启动
# 由 install.ps1 自动生成，请勿手动修改
# 每次双击桌面快捷方式时执行：解密 → 设环境变量 → 启动 claude

$ErrorActionPreference = "Stop"

# 加载 System.Security 程序集（DPAPI 解密需要 ProtectedData 类）
Add-Type -AssemblyName System.Security

# 从注册表读取 DPAPI 加密的 API Key 并在内存中解密
$encryptedKey = [System.Environment]::GetEnvironmentVariable("ANTHROPIC_AUTH_TOKEN_ENC", "User")
if ($encryptedKey) {
    try {
        $bytes = [System.Convert]::FromBase64String($encryptedKey)
        $decrypted = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        $env:ANTHROPIC_AUTH_TOKEN = [System.Text.Encoding]::UTF8.GetString($decrypted)
    } catch {
        Write-Host "❌ API Key 解密失败。请重新运行安装脚本配置。" -ForegroundColor Red
        Write-Host "   错误: $($_.Exception.Message)" -ForegroundColor DarkGray
        Read-Host "按 Enter 键退出..."
        exit 1
    }
} else {
    Write-Host "⚠️  未检测到已配置的 API Key。" -ForegroundColor Yellow
    Write-Host "   请重新运行安装脚本并选择配置 DeepSeek API。" -ForegroundColor Yellow
    Read-Host "按 Enter 键退出..."
    exit 1
}

# 加载其他非敏感环境变量（模型名、URL 等）
$envNames = @(
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_MODEL",
    "ANTHROPIC_DEFAULT_OPUS_MODEL",
    "ANTHROPIC_DEFAULT_SONNET_MODEL",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    "CLAUDE_CODE_SUBAGENT_MODEL",
    "CLAUDE_CODE_EFFORT_LEVEL",
    "CLAUDE_CODE_ATTRIBUTION_HEADER"
)
foreach ($name in $envNames) {
    $val = [System.Environment]::GetEnvironmentVariable($name, "User")
    if ($val) {
        Set-Item -Path "env:$name" -Value $val -ErrorAction SilentlyContinue
    }
}

# 启动 Claude Code（找不到时显示友好错误，避免窗口闪退）
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Host ""
    Write-Host "❌ Claude Code 未在 PATH 中找到。" -ForegroundColor Red
    Write-Host "   请重启终端后重试，或重新运行安装脚本。" -ForegroundColor Yellow
    Write-Host ""
    Read-Host "按 Enter 键退出..."
    exit 1
}

try {
    claude
} catch {
    Write-Host ""
    Write-Host "❌ Claude Code 启动失败: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "   请检查安装是否完整，或重新运行安装脚本。" -ForegroundColor Yellow
    Write-Host ""
    Read-Host "按 Enter 键退出..."
    exit 1
}
'@ | Out-File -FilePath $launcherPath -Encoding UTF8 -Force
    Write-Host "  ✅ 启动器脚本已生成: $launcherPath" -ForegroundColor Green
    Write-Host "     每次启动时在内存中解密 API Key，不写入磁盘" -ForegroundColor Gray

    # 加固 ACL：仅当前用户和 SYSTEM 可修改。
    # ⚠️ 必须【文件和目录一起加固】：只加固 claude-launcher.ps1 文件的话，
    #    任何能写 my-project 目录的进程都可以把文件删掉重建，重建出来的文件
    #    继承的是目录的默认 ACL —— 之前做的加固就被完全绕过了。
    try {
        $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        foreach ($aclTarget in @($launcherPath, $projectDir)) {
            $acl = Get-Acl -Path $aclTarget
            $acl.SetAccessRuleProtection($true, $false)  # 禁用继承
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                $currentUser, "Modify", "Allow"
            )))
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                "NT AUTHORITY\SYSTEM", "FullControl", "Allow"
            )))
            Set-Acl -Path $aclTarget -AclObject $acl
        }
        Write-Host "  🔒 启动器与项目目录 ACL 已加固（仅当前用户 + SYSTEM 可修改）" -ForegroundColor Gray
    } catch {
        # 失败必须说清楚"加固不完整"，不能只报一句无害的"非关键"
        Write-Host "  ⚠️  ACL 加固未完成: $_" -ForegroundColor DarkYellow
        Write-Host "     启动器仍可正常使用，但「仅当前用户可写」的保护不完整。" -ForegroundColor DarkYellow
    }
} catch {
    Write-Host "  ⚠️  启动器脚本生成失败: $_" -ForegroundColor DarkYellow
}

# ── 生成桌面快捷方式 ──
$null = New-ClaudeShortcut -ProjectDir $projectDir -ShortcutName "Claude Code"

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan

# ── 写入安装标记（供卸载脚本识别哪些软件由本脚本安装）──
# ⚠️ 这里的 *InstalledByUs 布尔值是卸载脚本唯一的可信依据：
#    只有真正由本脚本安装的组件才写 1；用户已预装、被"跳过安装"的必须写 0。
#    版本号（NodeVersion 等）仅作展示，卸载脚本不再依据它们做判断 ——
#    因为"检测到的版本号"无法区分"我们装的"和"用户本来就有的"。
$sentinelPath = "HKCU:\SOFTWARE\ClaudeCodeDeepSeekInstaller"

if ($Script:DryRun) {
    Write-Host "  [干跑] 将写入安装标记: $sentinelPath" -ForegroundColor Magenta
    Write-Host "         NodeInstalledByUs=$([int]$Script:NodeInstalledByUs) GitInstalledByUs=$([int]$Script:GitInstalledByUs) ClaudeCodeInstalledByUs=$([int]$Script:ClaudeCodeInstalledByUs)" -ForegroundColor Magenta
}
else {
try {
    if (-not (Test-Path $sentinelPath)) {
        New-Item -Path $sentinelPath -Force | Out-Null
    }
    $nodeVer    = try { & node -v 2>$null } catch { "" }
    $gitVer     = try { & git --version 2>$null } catch { "" }
    $claudeVer  = try { & claude --version 2>$null } catch { "" }
    Set-ItemProperty -Path $sentinelPath -Name "InstallDate"       -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Force
    Set-ItemProperty -Path $sentinelPath -Name "ProjectDirectory"  -Value $projectDir -Force
    Set-ItemProperty -Path $sentinelPath -Name "NodeVersion"       -Value $nodeVer -Force
    Set-ItemProperty -Path $sentinelPath -Name "GitVersion"        -Value $gitVer -Force
    Set-ItemProperty -Path $sentinelPath -Name "ClaudeVersion"     -Value $claudeVer -Force
    Set-ItemProperty -Path $sentinelPath -Name "LauncherPath"      -Value $launcherPath -Force
    Set-ItemProperty -Path $sentinelPath -Name "ShortcutPath"      -Value (Join-Path ([Environment]::GetFolderPath("Desktop")) "Claude Code.lnk") -Force
    # 显式布尔标记（卸载脚本只看这三个）
    Set-ItemProperty -Path $sentinelPath -Name "NodeInstalledByUs"       -Value $(if ($Script:NodeInstalledByUs)       { 1 } else { 0 }) -Force
    Set-ItemProperty -Path $sentinelPath -Name "GitInstalledByUs"        -Value $(if ($Script:GitInstalledByUs)        { 1 } else { 0 }) -Force
    Set-ItemProperty -Path $sentinelPath -Name "ClaudeCodeInstalledByUs" -Value $(if ($Script:ClaudeCodeInstalledByUs) { 1 } else { 0 }) -Force
    Write-Host "  📋 安装标记已写入注册表: $sentinelPath" -ForegroundColor Gray
    Write-Host "     Node=$([int]$Script:NodeInstalledByUs) Git=$([int]$Script:GitInstalledByUs) ClaudeCode=$([int]$Script:ClaudeCodeInstalledByUs) （1=由本脚本安装，0=保留你的预装版本）" -ForegroundColor Gray
} catch {
    Write-Host ""
    Write-Host "  ⚠️  安装标记写入失败: $_" -ForegroundColor Red
    Write-Host "     这很重要，不是「非关键」：安装标记是卸载脚本判断" -ForegroundColor Yellow
    Write-Host "     『哪些软件由本安装器部署』的唯一依据。缺少它时，卸载脚本" -ForegroundColor Yellow
    Write-Host "     无法区分你预装的软件，只能采取最保守的策略：保留 Node.js / Git。" -ForegroundColor Yellow
    Write-Host ""
}
}

# ── 清理：恢复执行策略 + 删除临时文件 ──
Invoke-ScriptCleanup

Write-Host ""
Read-Host "按 Enter 键退出..."
