# Uninstall Node.js + Git + Claude Code PowerShell Script
#Requires -Version 5.1

$ErrorActionPreference = "Continue"

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

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "   Claude Code + DeepSeek 一键卸载" -ForegroundColor Cyan
Write-Host "   作者: cynch18" -ForegroundColor Gray
Write-Host "   版本: 1.0" -ForegroundColor Gray
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================
# 架构检测
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

# ============================================================
# 主卸载流程
# ============================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  🧹 开始卸载 Git + Node.js + Claude Code" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

$uninstallSummary = @()

# ═══════════════════════════════════════════════════════════════
# 1. 卸载 Claude Code (通过 npm)
# ═══════════════════════════════════════════════════════════════
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "  [1/4] 卸载 Claude Code" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host ""

# 先查找 npm
$npmPath = $null
try {
    $npmPath = (Get-Command npm -ErrorAction Stop).Source
} catch {
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

if ($npmPath -and (Test-Path $npmPath)) {
    Write-Host "  找到 npm: $npmPath" -ForegroundColor Gray

    # 卸载 Claude Code 全局包
    Write-Host "  正在卸载 @anthropic-ai/claude-code..." -ForegroundColor Yellow
    $prevExit = $LASTEXITCODE
    & $npmPath uninstall -g @anthropic-ai/claude-code 2>&1 | ForEach-Object {
        $line = "$_"
        if ($line -match "removed|up to date") {
            Write-Host "    $line" -ForegroundColor Gray
        }
    }
    $ccExit = $LASTEXITCODE
    $LASTEXITCODE = $prevExit

    if ($ccExit -eq 0) {
        Write-Host "  ✅ Claude Code 已卸载" -ForegroundColor Green
        $uninstallSummary += "✅ Claude Code: 已通过 npm 卸载"
    } else {
        Write-Host "  ⚠️  npm 卸载返回代码: $ccExit (可能已不存在)" -ForegroundColor Yellow
        $uninstallSummary += "⚠️ Claude Code: npm 卸载异常 (可能已不存在)"
    }

    # 清理 Claude Code 全局安装残留
    $claudeDirs = @(
        "${env:APPDATA}\npm\node_modules\@anthropic-ai\claude-code",
        "${env:APPDATA}\npm\node_modules\@anthropic-ai",
        "${env:ProgramFiles}\nodejs\node_modules\@anthropic-ai\claude-code",
        "${env:ProgramFiles}\nodejs\node_modules\@anthropic-ai",
        "${env:LOCALAPPDATA}\pnpm\global\5\node_modules\@anthropic-ai\claude-code"
    )
    foreach ($dir in $claudeDirs) {
        if (Test-Path $dir) {
            Write-Host "  清理残留目录: $dir" -ForegroundColor Gray
            try {
                Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "  ✅ 已删除" -ForegroundColor Green
            } catch {
                Write-Host "  ⚠️ 无法删除: $_" -ForegroundColor Yellow
            }
        }
    }

    # 清理 claude 命令（npm 全局 bin 目录）
    $npmBinDirs = @(
        "${env:APPDATA}\npm",
        "${env:ProgramFiles}\nodejs",
        "${env:LOCALAPPDATA}\pnpm"
    )
    $claudeExes = @("claude", "claude.cmd", "claude.ps1", "claude-code", "claude-code.cmd")
    foreach ($binDir in $npmBinDirs) {
        foreach ($exe in $claudeExes) {
            $exePath = Join-Path $binDir $exe
            if (Test-Path $exePath) {
                try {
                    Remove-Item -Path $exePath -Force -ErrorAction SilentlyContinue
                    Write-Host "  清理命令: $exePath" -ForegroundColor Gray
                } catch { }
            }
        }
    }
} else {
    Write-Host "  ⚠️ npm 未找到，跳过 Claude Code 卸载" -ForegroundColor Yellow
    Write-Host "  如需手动清理，请删除以下目录：" -ForegroundColor Gray
    Write-Host "    %APPDATA%\npm\node_modules\@anthropic-ai" -ForegroundColor Gray
    $uninstallSummary += "⚠️ Claude Code: npm 不可用，需手动清理"
}

# ═══════════════════════════════════════════════════════════════
# 2. 卸载 Node.js
# ═══════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "  [2/4] 卸载 Node.js" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host ""

$nodeUninstalled = $false

# 方法1: 通过注册表查找 Node.js 卸载信息
$nodeRegPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)

foreach ($regPath in $nodeRegPaths) {
    if (Test-Path (Split-Path $regPath -Parent)) {
        $nodeEntries = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue |
                       Where-Object { $_.DisplayName -match "Node\.js" }

        foreach ($entry in $nodeEntries) {
            Write-Host "  找到 Node.js: $($entry.DisplayName) (v$($entry.DisplayVersion))" -ForegroundColor Yellow

            if ($entry.UninstallString) {
                # 解析卸载命令（通常是 msiexec）
                $uninstallCmd = $entry.UninstallString
                Write-Host "  卸载命令: $uninstallCmd" -ForegroundColor Gray

                if ($uninstallCmd -match "msiexec") {
                    # MSI 卸载: msiexec /x {GUID} /quiet /norestart
                    $uninstallArgs = $uninstallCmd -replace 'msiexec\.exe\s*', ''
                    $uninstallArgs += " /quiet /norestart"

                    Write-Host "  正在卸载 Node.js (静默模式)..." -ForegroundColor Yellow
                    $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $uninstallArgs -Wait -PassThru

                    if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
                        Write-Host "  ✅ Node.js 已卸载" -ForegroundColor Green
                        $nodeUninstalled = $true
                        $uninstallSummary += "✅ Node.js ($($entry.DisplayVersion)): 已通过 MSI 卸载"
                    } else {
                        Write-Host "  ⚠️  MSI 卸载返回代码: $($proc.ExitCode)" -ForegroundColor Yellow
                    }
                } elseif ($uninstallCmd -match "\.exe") {
                    # EXE 卸载程序
                    Write-Host "  正在运行卸载程序..." -ForegroundColor Yellow
                    $proc = Start-Process -FilePath $uninstallCmd -ArgumentList "/S" -Wait -PassThru
                    Write-Host "  ✅ Node.js 卸载程序已执行" -ForegroundColor Green
                    $nodeUninstalled = $true
                    $uninstallSummary += "✅ Node.js ($($entry.DisplayVersion)): 已通过卸载程序移除"
                }
            }
        }
    }
}

# 方法2: 直接通过 msiexec 查找 Node.js 产品代码
if (-not $nodeUninstalled) {
    Write-Host "  注册表未找到卸载条目，尝试通过 msiexec 卸载..." -ForegroundColor Yellow

    $nodeMsiProducts = @(
        # Node.js 常见产品代码前缀
        @{ Name = "Node.js" }
    )

    # 使用 WMI 查找已安装的 Node.js MSI 产品
    try {
        $products = Get-WmiObject -Class Win32_Product -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match "Node\.js" }
        foreach ($product in $products) {
            Write-Host "  找到 MSI 产品: $($product.Name)" -ForegroundColor Yellow
            $result = $product.Uninstall()
            if ($result.ReturnValue -eq 0) {
                Write-Host "  ✅ Node.js 已通过 WMI 卸载" -ForegroundColor Green
                $nodeUninstalled = $true
                $uninstallSummary += "✅ Node.js: 已通过 WMI 卸载"
            }
        }
    } catch {
        Write-Host "  ⚠️ WMI 查询失败: $_" -ForegroundColor Yellow
    }
}

# 方法3: 手动清理 Node.js 安装目录
$nodeInstallDirs = @(
    "${env:ProgramFiles}\nodejs",
    "${env:ProgramFiles(x86)}\nodejs"
)

foreach ($dir in $nodeInstallDirs) {
    if (Test-Path $dir) {
        Write-Host "  清理安装目录: $dir" -ForegroundColor Gray
        try {
            Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "  ✅ 已删除" -ForegroundColor Green
            $nodeUninstalled = $true
        } catch {
            Write-Host "  ⚠️ 无法完全删除 (可能有文件被占用): $_" -ForegroundColor Yellow
            Write-Host "    建议重启后手动删除: $dir" -ForegroundColor Gray
        }
    }
}

# 清理 Node.js 相关的 PATH 中的残留
$nodePathPatterns = @(
    "${env:ProgramFiles}\nodejs",
    "${env:ProgramFiles(x86)}\nodejs",
    "${env:APPDATA}\npm",
    "${env:LOCALAPPDATA}\pnpm"
)

# 清理注册表中的 Node.js 条目
$nodeRegKeys = @(
    "HKLM:\SOFTWARE\Node.js",
    "HKLM:\SOFTWARE\WOW6432Node\Node.js",
    "HKCU:\SOFTWARE\Node.js"
)
foreach ($key in $nodeRegKeys) {
    if (Test-Path $key) {
        try {
            Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "  清理注册表: $key" -ForegroundColor Gray
        } catch { }
    }
}

if (-not $nodeUninstalled) {
    Write-Host "  ℹ️  未检测到 Node.js 安装" -ForegroundColor Gray
    $uninstallSummary += "ℹ️ Node.js: 未检测到安装"
}

# ═══════════════════════════════════════════════════════════════
# 3. 卸载 Git for Windows
# ═══════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "  [3/4] 卸载 Git for Windows" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host ""

$gitUninstalled = $false

# 方法1: 通过注册表查找 Git 卸载信息
$gitRegPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)

foreach ($regPath in $gitRegPaths) {
    if (Test-Path (Split-Path $regPath -Parent)) {
        $gitEntries = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue |
                      Where-Object { $_.DisplayName -match "^Git$|Git for Windows" }

        foreach ($entry in $gitEntries) {
            Write-Host "  找到 Git: $($entry.DisplayName)" -ForegroundColor Yellow

            if ($entry.UninstallString) {
                $uninstallCmd = $entry.UninstallString
                Write-Host "  卸载命令: $uninstallCmd" -ForegroundColor Gray

                # Git 使用 Inno Setup 或自定义卸载程序
                if ($uninstallCmd -match "unins\d+\.exe" -or $uninstallCmd -match "uninstall\.exe") {
                    # Inno Setup 卸载程序，支持 /VERYSILENT
                    $uninstallArgs = "/VERYSILENT /NORESTART /SUPPRESSMSGBOXES"
                    if ($uninstallCmd -match '^"') {
                        # 路径已有引号
                        $proc = Start-Process -FilePath $uninstallCmd -ArgumentList $uninstallArgs -Wait -PassThru
                    } else {
                        $proc = Start-Process -FilePath $uninstallCmd -ArgumentList $uninstallArgs -Wait -PassThru
                    }

                    Write-Host "  ✅ Git 卸载程序已执行 (exit: $($proc.ExitCode))" -ForegroundColor Green
                    $gitUninstalled = $true
                    $uninstallSummary += "✅ Git ($($entry.DisplayVersion)): 已通过卸载程序移除"
                } else {
                    # 尝试直接带 /S 参数运行
                    $proc = Start-Process -FilePath $uninstallCmd -ArgumentList "/S" -Wait -PassThru
                    Write-Host "  ✅ Git 卸载程序已执行" -ForegroundColor Green
                    $gitUninstalled = $true
                    $uninstallSummary += "✅ Git: 已通过卸载程序移除"
                }
            }
        }
    }
}

# 方法2: 通过 Git 自带的卸载程序
$gitUninstallPaths = @(
    "${env:ProgramFiles}\Git\unins000.exe",
    "${env:ProgramFiles}\Git\uninstall.exe",
    "${env:ProgramFiles(x86)}\Git\unins000.exe",
    "${env:ProgramFiles(x86)}\Git\uninstall.exe"
)

if (-not $gitUninstalled) {
    foreach ($unPath in $gitUninstallPaths) {
        if (Test-Path $unPath) {
            Write-Host "  找到 Git 卸载程序: $unPath" -ForegroundColor Yellow
            try {
                $proc = Start-Process -FilePath $unPath -ArgumentList "/VERYSILENT /NORESTART /SUPPRESSMSGBOXES" -Wait -PassThru
                Write-Host "  ✅ Git 卸载完成 (exit: $($proc.ExitCode))" -ForegroundColor Green
                $gitUninstalled = $true
                $uninstallSummary += "✅ Git: 已通过 unins000.exe 卸载"
            } catch {
                Write-Host "  ⚠️ 卸载程序执行失败: $_" -ForegroundColor Yellow
            }
        }
    }
}

# 方法3: 手动清理 Git 安装目录
$gitInstallDirs = @(
    "${env:ProgramFiles}\Git",
    "${env:ProgramFiles(x86)}\Git",
    "C:\Git"
)

if (-not $gitUninstalled) {
    foreach ($dir in $gitInstallDirs) {
        if (Test-Path $dir) {
            Write-Host "  清理安装目录: $dir" -ForegroundColor Gray
            try {
                # 先尝试停止 git 相关进程
                Get-Process | Where-Object { $_.Path -like "*$dir*" } | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 1
                Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "  ✅ 已删除" -ForegroundColor Green
                $gitUninstalled = $true
            } catch {
                Write-Host "  ⚠️ 无法完全删除 (可能有文件被占用): $_" -ForegroundColor Yellow
                Write-Host "    建议重启后手动删除: $dir" -ForegroundColor Gray
            }
        }
    }
}

# 清理 Git 注册表信息
$gitRegKeys = @(
    "HKLM:\SOFTWARE\GitForWindows",
    "HKLM:\SOFTWARE\WOW6432Node\GitForWindows",
    "HKCU:\SOFTWARE\GitForWindows"
)
foreach ($key in $gitRegKeys) {
    if (Test-Path $key) {
        try {
            Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "  清理注册表: $key" -ForegroundColor Gray
        } catch { }
    }
}

if (-not $gitUninstalled) {
    Write-Host "  ℹ️  未检测到 Git 安装" -ForegroundColor Gray
    $uninstallSummary += "ℹ️ Git: 未检测到安装"
}

# ═══════════════════════════════════════════════════════════════
# 4. 清理环境变量 & 其他残留
# ═══════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "  [4/4] 清理环境变量 & 残留文件" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host ""

# 清理 DeepSeek / Claude Code 环境变量（用户级别）
$envVarsToRemove = @(
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_MODEL",
    "ANTHROPIC_DEFAULT_OPUS_MODEL",
    "ANTHROPIC_DEFAULT_SONNET_MODEL",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    "CLAUDE_CODE_SUBAGENT_MODEL",
    "CLAUDE_CODE_EFFORT_LEVEL",
    "CLAUDE_CODE_ATTRIBUTION_HEADER"
)

Write-Host "  正在清理环境变量 (用户级别)..." -ForegroundColor Yellow
$cleanedEnvCount = 0
foreach ($varName in $envVarsToRemove) {
    $currentValue = [System.Environment]::GetEnvironmentVariable($varName, "User")
    if ($currentValue) {
        [System.Environment]::SetEnvironmentVariable($varName, $null, "User")
        # 同时清除当前会话
        Remove-Item -Path "env:$varName" -ErrorAction SilentlyContinue
        Write-Host "  ✅ 已删除: `$env:$varName" -ForegroundColor Green
        $cleanedEnvCount++
    }
}

if ($cleanedEnvCount -eq 0) {
    Write-Host "  ℹ️  未找到需要清理的环境变量" -ForegroundColor Gray
    $uninstallSummary += "ℹ️ 环境变量: 无需清理"
} else {
    $uninstallSummary += "✅ 环境变量: 已清理 $cleanedEnvCount 项"
}

# 清理桌面生成的安装日志
Write-Host ""
Write-Host "  正在清理桌面日志文件..." -ForegroundColor Yellow
$desktopPath = [Environment]::GetFolderPath("Desktop")
$logPatterns = @("install-log-*.txt", "install-success-*.txt", "claude-code-env.ps1")
$cleanedLogs = 0
foreach ($pattern in $logPatterns) {
    Get-ChildItem -Path $desktopPath -Filter $pattern -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
            Write-Host "  ✅ 已删除: $($_.Name)" -ForegroundColor Green
            $cleanedLogs++
        } catch { }
    }
}
# 也检查 TEMP 目录
$tempLogPath = Join-Path $env:TEMP "claude-code-env.ps1"
if (Test-Path $tempLogPath) {
    try {
        Remove-Item -Path $tempLogPath -Force -ErrorAction SilentlyContinue
        Write-Host "  ✅ 已删除: $tempLogPath" -ForegroundColor Green
        $cleanedLogs++
    } catch { }
}

if ($cleanedLogs -eq 0) {
    Write-Host "  ℹ️  未找到日志文件" -ForegroundColor Gray
}

# 清理 npm 缓存中的 Claude Code
Write-Host ""
Write-Host "  正在清理 npm 缓存..." -ForegroundColor Yellow
try {
    $npmCacheDir = "${env:APPDATA}\npm-cache"
    if (Test-Path $npmCacheDir) {
        # 只清理 claude 相关的缓存，不影响其他包
        $cacheClaudeDir = Join-Path $npmCacheDir "_cacache"
        Write-Host "  npm 缓存保留（可能被其他项目使用），跳过清理" -ForegroundColor Gray
    }
} catch { }

# ═══════════════════════════════════════════════════════════════
# 清理 PATH 环境变量（注册表级持久化清除）
# ═══════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "  正在清理 PATH 环境变量（注册表层）..." -ForegroundColor Yellow
Write-Host ""

# 构建需要匹配的关键词列表（不依赖具体盘符/大小写）
# 用关键词 + 子路径组合，确保覆盖所有安装变体
$pathKeywords = @(
    "nodejs",           # C:\Program Files\nodejs\, C:\Program Files (x86)\nodejs\
    "Git",              # C:\Program Files\Git\bin, \cmd, \mingw64\bin
    "Program Files",
    "Program Files (x86)"
)

# 具体要去除的子路径特征
$pathSubstrings = @(
    "\nodejs",                  # 任何盘符下的 nodejs 目录
    "\Git\bin",                 # Git bin
    "\Git\cmd",                 # Git cmd
    "\Git\mingw64\bin",         # Git mingw64
    "\Git\usr\bin",             # Git usr/bin
    "AppData\Roaming\npm",      # npm 全局 bin
    "node_modules\.bin"         # 局部 node_modules (非系统 PATH 但防残留)
)

# 初始化结果汇总
$totalRemovedMachine = 0
$totalRemovedUser = 0

# ── 处理 Machine PATH ──
$machinePath = $null
try {
    $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
} catch {
    Write-Host "  ⚠️ 无法读取 Machine PATH: $_" -ForegroundColor Yellow
}

if ($machinePath) {
    Write-Host "  [Machine PATH] 扫描中..." -ForegroundColor Gray

    # 按分号拆分，保留原始格式
    $entries = $machinePath -split ';'
    $cleanEntries = @()
    $removed = @()

    foreach ($entry in $entries) {
        $e = $entry.Trim()
        if ($e -eq "") { continue }

        $shouldRemove = $false
        $normalized = $e.ToLowerInvariant().TrimEnd('\').Replace('/', '\')

        foreach ($sub in $pathSubstrings) {
            $normSub = $sub.ToLowerInvariant().TrimEnd('\').Replace('/', '\')
            # 匹配规则：条目包含该子路径（不区分大小写 + 斜杠统一）
            if ($normalized.Contains($normSub)) {
                $shouldRemove = $true
                break
            }
        }

        if (-not $shouldRemove) {
            $cleanEntries += $e
        } else {
            $removed += $e
        }
    }

    if ($removed.Count -gt 0) {
        Write-Host "    将移除 Machine PATH 中的 $($removed.Count) 个条目:" -ForegroundColor Yellow
        foreach ($r in $removed) {
            Write-Host "      ❌ $r" -ForegroundColor Red
        }

        $newMachinePath = $cleanEntries -join ';'

        try {
            [System.Environment]::SetEnvironmentVariable("Path", $newMachinePath, "Machine")
            $totalRemovedMachine = $removed.Count

            # —— 写入后立即回读验证 ——
            $verifyPath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
            $stillPresent = @()
            foreach ($r in $removed) {
                if ($verifyPath -and $verifyPath.ToLowerInvariant().Contains($r.ToLowerInvariant())) {
                    $stillPresent += $r
                }
            }
            if ($stillPresent.Count -eq 0) {
                Write-Host "  ✅ Machine PATH 已更新并验证: 移除 $($removed.Count) 个条目" -ForegroundColor Green
                $uninstallSummary += "✅ Machine PATH: 移除 $($removed.Count) 个条目（已验证写入注册表）"
            } else {
                Write-Host "  ⚠️ Machine PATH 部分条目未能清除: $stillPresent" -ForegroundColor Yellow
                $uninstallSummary += "⚠️ Machine PATH: $($stillPresent.Count) 个条目写入注册表失败"
            }
        } catch {
            Write-Host "  ❌ Machine PATH 写入失败: $_" -ForegroundColor Red
            Write-Host "    请以管理员身份手动运行：" -ForegroundColor Yellow
            Write-Host "    [Environment]::SetEnvironmentVariable('Path', ..., 'Machine')" -ForegroundColor Gray
            $uninstallSummary += "❌ Machine PATH: 写入失败 ($_)"
        }
    } else {
        Write-Host "  ✅ Machine PATH: 无需清理" -ForegroundColor Gray
    }
}

# ── 处理 User PATH ──
$userPath = $null
try {
    $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
} catch {
    Write-Host "  ⚠️ 无法读取 User PATH: $_" -ForegroundColor Yellow
}

if ($userPath) {
    Write-Host "  [User PATH] 扫描中..." -ForegroundColor Gray

    $entries = $userPath -split ';'
    $cleanEntries = @()
    $removed = @()

    foreach ($entry in $entries) {
        $e = $entry.Trim()
        if ($e -eq "") { continue }

        $shouldRemove = $false
        $normalized = $e.ToLowerInvariant().TrimEnd('\').Replace('/', '\')

        foreach ($sub in $pathSubstrings) {
            $normSub = $sub.ToLowerInvariant().TrimEnd('\').Replace('/', '\')
            if ($normalized.Contains($normSub)) {
                $shouldRemove = $true
                break
            }
        }

        if (-not $shouldRemove) {
            $cleanEntries += $e
        } else {
            $removed += $e
        }
    }

    if ($removed.Count -gt 0) {
        Write-Host "    将移除 User PATH 中的 $($removed.Count) 个条目:" -ForegroundColor Yellow
        foreach ($r in $removed) {
            Write-Host "      ❌ $r" -ForegroundColor Red
        }

        $newUserPath = $cleanEntries -join ';'

        try {
            [System.Environment]::SetEnvironmentVariable("Path", $newUserPath, "User")
            $totalRemovedUser = $removed.Count

            # —— 写入后立即回读验证 ——
            $verifyPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
            $stillPresent = @()
            foreach ($r in $removed) {
                if ($verifyPath -and $verifyPath.ToLowerInvariant().Contains($r.ToLowerInvariant())) {
                    $stillPresent += $r
                }
            }
            if ($stillPresent.Count -eq 0) {
                Write-Host "  ✅ User PATH 已更新并验证: 移除 $($removed.Count) 个条目" -ForegroundColor Green
                $uninstallSummary += "✅ User PATH: 移除 $($removed.Count) 个条目（已验证写入注册表）"
            } else {
                Write-Host "  ⚠️ User PATH 部分条目仍存在: $stillPresent" -ForegroundColor Yellow
                $uninstallSummary += "⚠️ User PATH: $($stillPresent.Count) 个条目写入注册表失败"
            }
        } catch {
            Write-Host "  ❌ User PATH 写入失败: $_" -ForegroundColor Red
            $uninstallSummary += "❌ User PATH: 写入失败 ($_)"
        }
    } else {
        Write-Host "  ✅ User PATH: 无需清理" -ForegroundColor Gray
    }
}

# ── 同步当前会话的 $env:Path（让验证和后续命令立即可用）──
Write-Host ""
Write-Host "  正在刷新当前会话的 `$env:Path..." -ForegroundColor Yellow
try {
    $freshMachine = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $freshUser    = [System.Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = ($freshMachine, $freshUser | Where-Object { $_ } ) -join ";"
    Write-Host "  ✅ 当前会话 PATH 已从注册表刷新" -ForegroundColor Green
} catch {
    Write-Host "  ⚠️ 当前会话 PATH 刷新失败: $_" -ForegroundColor Yellow
}

if ($totalRemovedMachine -eq 0 -and $totalRemovedUser -eq 0) {
    Write-Host "  ℹ️  PATH 中没有检测到需要清理的残留条目" -ForegroundColor Gray
} else {
    $total = $totalRemovedMachine + $totalRemovedUser
    Write-Host "  ✅ 总共从 PATH 中移除了 $total 个残留条目 (Machine: $totalRemovedMachine, User: $totalRemovedUser)" -ForegroundColor Green
}

# ═══════════════════════════════════════════════════════════════
# 汇总报告
# ═══════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  🎉 卸载完成！汇总报告" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

foreach ($line in $uninstallSummary) {
    Write-Host "  $line" -ForegroundColor White
}

Write-Host ""

# ── my-project 目录提醒（不静默删除，里面可能有用户代码）──
$projectDir = Join-Path ([Environment]::GetFolderPath("Desktop")) "my-project"
if (Test-Path $projectDir) {
    Write-Host "  ⚠️  桌面 my-project 目录仍然存在" -ForegroundColor Yellow
    Write-Host "     $projectDir" -ForegroundColor Gray
    Write-Host "     如不再需要，请手动删除：" -ForegroundColor Gray
    Write-Host "     Remove-Item -Path '$projectDir' -Recurse -Force" -ForegroundColor DarkGray
    Write-Host ""
}

Write-Host "────────────────────────────────────────────────────────────" -ForegroundColor Gray
Write-Host "  📋 验证卸载结果" -ForegroundColor Cyan
Write-Host "────────────────────────────────────────────────────────────" -ForegroundColor Gray
Write-Host ""

# 验证 Node.js
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if ($nodeCmd) {
    Write-Host "  ❌ Node.js 仍存在: $($nodeCmd.Source)" -ForegroundColor Red
} else {
    Write-Host "  ✅ Node.js: 已完全移除" -ForegroundColor Green
}

# 验证 Git
$gitCmd = Get-Command git -ErrorAction SilentlyContinue
if ($gitCmd) {
    Write-Host "  ❌ Git 仍存在: $($gitCmd.Source)" -ForegroundColor Red
} else {
    Write-Host "  ✅ Git: 已完全移除" -ForegroundColor Green
}

# 验证 Claude Code
$claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
if ($claudeCmd) {
    Write-Host "  ❌ Claude Code 仍存在: $($claudeCmd.Source)" -ForegroundColor Red
} else {
    Write-Host "  ✅ Claude Code: 已完全移除" -ForegroundColor Green
}

# 验证环境变量
Write-Host ""
$remainingVars = @()
foreach ($varName in $envVarsToRemove) {
    if ([System.Environment]::GetEnvironmentVariable($varName, "User")) {
        $remainingVars += $varName
    }
}
if ($remainingVars.Count -gt 0) {
    Write-Host "  ⚠️ 以下环境变量仍存在: $($remainingVars -join ', ')" -ForegroundColor Yellow
} else {
    Write-Host "  ✅ 所有 Claude Code 环境变量已清理" -ForegroundColor Green
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Read-Host "按 Enter 键退出..."
