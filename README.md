# Claude Code + DeepSeek 安装/卸载脚本说明

---

## 概述

这两个 PowerShell 脚本用于在 **Windows 10/11** 上一键安装或卸载完整的 Claude Code 开发环境，并使用 **DeepSeek API** 作为后端，通过 **Windows DPAPI** 实现 API Key 的安全存储（不落盘明文）。

---

## ⚠️ 免责声明

1. **第三方服务风险**：本脚本配置的 API 后端为 **DeepSeek**（`api.deepseek.com`），这是一个独立的第三方 AI 服务提供商，与 Anthropic 无关。使用 DeepSeek API 即表示你同意其服务条款和隐私政策。Anthropic 对 DeepSeek 的服务质量、数据安全及隐私保护不承担任何责任。

2. **代码执行风险**：本脚本需要 **管理员权限** 运行。脚本会：
   - 修改系统环境变量（PATH）
   - 写入 Windows 注册表
   - 下载并执行来自互联网的安装程序
   - 安装系统级软件（Node.js、Git）
   请在运行前仔细阅读脚本内容，确认你信任这些操作。

3. **供应链安全**：
   - 当官方下载源不可用时，脚本会自动回退到 **第三方国内镜像**（如 `npmmirror.com`、TUNA 镜像），这些镜像由第三方维护，存在文件被篡改的理论风险。
   - 脚本已内置 SHA256 哈希校验和 Authenticode 数字签名验证以降低此风险，但**无法完全消除**。
   - 建议优先从官方源下载，仅在网络受限时使用镜像。

4. **API Key 安全**：脚本使用 Windows DPAPI 加密存储 API Key（绑定当前用户+机器），此方案基于 Windows 用户登录凭据保护密钥。如果你的 Windows 账户被攻破，API Key 可能被解密。DPAPI 加密的 Key 无法跨机器或跨用户迁移。

5. **npm 全局安装**：Claude Code 通过 `npm install -g` 全局安装，这意味着它写入全局 `node_modules` 目录。npm 供应链攻击是已知风险，请确保你的 npm 环境安全。

6. **数据隐私**：
   - 使用 DeepSeek 作为后端时，你与 Claude Code 的对话内容将**发送至 DeepSeek 服务器**，而非 Anthropic。
   - 默认关闭了 `CLAUDE_CODE_ATTRIBUTION_HEADER`，Claude Code 不会在请求中发送归属信息。
   - 请勿在对话中分享敏感个人信息或机密数据。

7. **"按原样"提供**：本脚本集“按原样”提供，不附带任何明示或暗示的担保。作者不对因使用本脚本而导致的任何直接或间接损失负责，包括但不限于：
   - API Key 泄露
   - 数据丢失
   - 系统配置错误
   - 软件安装失败
   - 第三方服务中断

8. **许可证合规**：本脚本安装的软件（Node.js、Git、Claude Code）各自受其原始许可证约束。使用前请确认你遵守了相关许可证条款。

---

## 一、install.ps1 — 安装脚本

### 1.1 功能概述

| 步骤 | 内容 |
|------|------|
| 自动提权 | 检测管理员权限，不足时自动以 `RunAs` 重新启动 |
| 架构检测 | 32位 PowerShell 在 64位 OS 上自动切换到 64位 |
| 环境检测 | 全面扫描 Node.js / Git 是否已安装 |
| 安装 Node.js | 下载并静默安装 Node.js 18+（MSI） |
| 安装 Git | 下载并静默安装 Git for Windows |
| 安装 Claude Code | 通过 `npm install -g @anthropic-ai/claude-code` |
| 配置 DeepSeek API | DPAPI 加密 API Key → 注册表，非敏感变量 → 注册表 |
| 生成启动器 | 创建 `claude-launcher.ps1`（内存解密 → 启动 claude） |
| 桌面快捷方式 | 生成指向启动器的 `.lnk` 快捷方式 |
| 安装标记 | 写入注册表 `HKCU:\SOFTWARE\ClaudeCodeDeepSeekInstaller` |

### 1.2 脚本架构

```
install.ps1
├── 全局 trap（异常捕获 → 错误日志 → 清理 → 退出）
├── 自动提权（Test-IsAdmin → Start-Process -Verb RunAs）
├── 架构检测（32→64 位切换）
├── 函数定义区
│   ├── Protect-ApiKey / Unprotect-ApiKey       # DPAPI 加解密
│   ├── Invoke-DownloadWithRetry               # 带重试+多镜像下载
│   ├── Test-FileHash                          # SHA256 哈希校验
│   ├── Find-LocalInstaller                    # 本地安装包查找
│   ├── Invoke-NpmInstallWithRetry             # npm 安装（多源回退）
│   ├── Test-NodeExists                        # 全面扫描 Node.js 安装
│   ├── Test-GitExists                         # 全面扫描 Git 安装
│   ├── Install-Git                            # Git 安装逻辑
│   ├── New-ClaudeShortcut                     # 桌面快捷方式生成
│   ├── Write-ErrorLog                         # 错误日志（脱敏）
│   └── Invoke-ScriptCleanup                   # 全局清理
├── 主流程
│   ├── [1] Node.js 检测 → 安装/跳过
│   ├── [2] Git 检测 → 安装/跳过
│   ├── [3] Claude Code 安装（npm）
│   ├── [4] DeepSeek API 配置（交互式 Y/N）
│   ├── [5] 启动器脚本生成 + ACL 加固
│   ├── [6] 桌面快捷方式创建
│   └── [7] 安装标记写入注册表
└── 清理 & 退出
```

### 1.3 安全设计

#### API Key 存储（DPAPI 加密）

```
用户输入 API Key
       │
       ▼
┌─────────────────────────────────────────────┐
│  Protect-ApiKey (DPAPI)                      │
│  · 加密绑定到当前 Windows 用户 + 当前机器      │
│  · 输出 Base64 字符串                         │
└─────────────────────────────────────────────┘
       │
       ▼
  写入注册表 (HKCU\Environment)
  ANTHROPIC_AUTH_TOKEN_ENC = "<Base64加密密文>"
       │
       ▼
  桌面快捷方式 → claude-launcher.ps1
  → Unprotect-ApiKey (内存解密)
  → $env:ANTHROPIC_AUTH_TOKEN = "明文" (仅内存)
  → 启动 claude
```

**关键点：**
- API Key **永不**以明文写入磁盘
- 解密仅在内存中发生
- 加密绑定到当前 Windows 用户，其他用户/机器无法解密
- 非敏感变量（URL、模型名）明文存注册表

#### 下载安全

| 措施 | 说明 |
|------|------|
| SHA256 校验 | Node.js → 官方 `SHASUMS256.txt`；Git → 官方 `.sha256sum` |
| Authenticode 签名验证 | Git 安装包回退方案 |
| 多源镜像 | 官方源 → TUNA 镜像 → NJU 镜像，自动回退 |
| 本地安装包回退 | 联网失败时搜索脚本同目录的安装包 |

#### ACL 加固

启动器脚本 `claude-launcher.ps1` 生成后：
- 禁用继承权限
- 仅允许 **当前用户** 和 **SYSTEM** 修改

### 1.4 错误处理

| 机制 | 说明 |
|------|------|
| 全局 `trap` | 捕获所有未处理异常 |
| 错误日志 | 写入桌面 `install-log-yyyyMMdd-HHmmss.txt` |
| API Key 脱敏 | 日志中 `sk-xxx` 模式自动替换为 `[REDACTED-API-KEY]` |
| MSI 退出码处理 | 完整处理 0/3010/1602/1603/1618/1619 等 |
| 安装后验证 | 检查 `node.exe` 实际文件存在（不只看退出码） |

### 1.5 下载源列表

| 软件 | 主源 | 备用源 |
|------|------|--------|
| Node.js | `https://nodejs.org/dist/` | `npmmirror.com/mirrors/node/` |
| Git | `https://github.com/git-for-windows/git/releases/` | TUNA 镜像、NJU 镜像 |
| Claude Code (npm) | npm 官方源 | `registry.npmmirror.com` |

### 1.6 环境变量（写入注册表）

| 变量名 | 值 | 敏感 |
|--------|-----|------|
| `ANTHROPIC_AUTH_TOKEN_ENC` | DPAPI 加密的 API Key | ✅ |
| `ANTHROPIC_BASE_URL` | `https://api.deepseek.com/anthropic` | ❌ |
| `ANTHROPIC_MODEL` | `deepseek-v4-pro[1m]` | ❌ |
| `ANTHROPIC_DEFAULT_OPUS_MODEL` | `deepseek-v4-pro[1m]` | ❌ |
| `ANTHROPIC_DEFAULT_SONNET_MODEL` | `deepseek-v4-pro[1m]` | ❌ |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL` | `deepseek-v4-flash` | ❌ |
| `CLAUDE_CODE_SUBAGENT_MODEL` | `deepseek-v4-flash` | ❌ |
| `CLAUDE_CODE_EFFORT_LEVEL` | `max` | ❌ |
| `CLAUDE_CODE_ATTRIBUTION_HEADER` | `0` | ❌ |

### 1.7 生成的文件

| 文件 | 路径 | 说明 |
|------|------|------|
| 启动器脚本 | `项目目录/claude-launcher.ps1` | DPAPI 内存解密 + 启动 claude |
| 桌面快捷方式 | `桌面/Claude Code.lnk` | 指向启动器脚本 |
| 成功日志 | `桌面/install-success-yyyyMMdd-HHmmss.txt` | 安装成功摘要 |
| 错误日志 | `桌面/install-log-yyyyMMdd-HHmmss.txt` | 仅在失败时生成 |
| 注册表标记 | `HKCU:\SOFTWARE\ClaudeCodeDeepSeekInstaller` | 供卸载脚本识别 |

---

## 二、uninstall.ps1 — 卸载脚本

### 2.1 功能概述

| 步骤 | 内容 |
|------|------|
| Step 0 | 终止所有相关进程（node, git, claude 等） |
| Step 1 | 卸载 Claude Code（npm uninstall + 残留清理） |
| Step 2 | 卸载 Git for Windows（含 Credential Manager） |
| Step 3 | 卸载 Node.js（MSI/EXE 卸载 + 残留目录清理） |
| Step 4 | 清理环境变量、PATH、桌面快捷方式、日志文件 |
| Step 5 | 验证卸载结果 + 汇总报告 |

### 2.2 脚本架构

```
uninstall.ps1
├── 自动提权
├── 架构检测
├── 读取安装标记（HKCU:\SOFTWARE\ClaudeCodeDeepSeekInstaller）
│   └── 决定：仅卸载本脚本安装的软件 vs 全部卸载
├── 工具函数
│   ├── Test-InstalledByUs     # 哨兵检查（区分脚本安装 vs 预装）
│   ├── Write-Step / Write-OK / Write-Warn / Write-Info
│   ├── Remove-DirectorySafe   # 安全删除目录（先杀进程）
│   ├── Remove-FileSafe        # 安全删除文件
│   ├── Remove-RegKeySafe      # 安全删除注册表键
│   ├── Get-UninstallEntry     # 通过注册表获取卸载命令
│   ├── Test-ShouldRemovePath  # PATH 黑名单/白名单检查
│   └── Update-PathVariable    # PATH 精确清理
├── Step 0: 终止相关进程
├── Step 1: 卸载 Claude Code
│   ├── npm uninstall -g
│   ├── 清理 node_modules 残留
│   └── 清理 ~/.claude ~/.claude-code
├── Step 2: 卸载 Git
│   ├── MSI/Inno Setup 卸载
│   ├── 清理安装目录
│   ├── 清理注册表
│   └── 交互式清理 .gitconfig / .git-credentials
├── Step 3: 卸载 Node.js
│   ├── MSI/EXE 卸载
│   ├── 清理安装目录
│   ├── 清理 npm-cache / pnpm
│   └── 清理注册表
├── Step 4: 清理环境变量 & PATH
│   ├── 删除 9 个 Claude Code 环境变量
│   ├── PATH 黑名单精确匹配删除
│   ├── PATH 白名单保护（Windows/System32/dotnet 等）
│   ├── 清理桌面快捷方式
│   ├── 清理日志文件
│   └── 清理 TEMP 临时文件
├── Step 5: 验证报告
│   ├── 检查安装目录是否仍存在
│   ├── 检查命令是否仍在 PATH
│   ├── 检查环境变量残留
│   └── 清理 my-project 目录（若为空）
└── 汇总报告 + 建议
```

### 2.3 安全设计

#### 哨兵机制（区分脚本安装 vs 预装软件）

| 情况 | 行为 |
|------|------|
| 有安装标记 + 组件有记录 | 正常卸载 |
| 有安装标记 + 组件无记录 | 跳过卸载程序调用（保留预装软件） |
| 无安装标记 | 尝试全部卸载（保守策略，发出警告） |

#### PATH 清理策略

- **黑名单**（精准正则匹配）：
  - `\nodejs\`、`\node_modules\.bin`、`\AppData\Roaming\npm`
  - `\Git\bin`、`\Git\cmd`、`\Git\mingw64\bin`、`\Git\usr\bin`
- **白名单**（永久保护）：
  - 包含 `Windows`、`System32`、`PowerShell`、`Microsoft`、`dotnet`、`Docker` 的路径

#### 安全的目录删除

- 删除前先终止该目录下正在运行的进程
- 使用路径前缀精确匹配（防止 `Git` 误杀 `GitHub Desktop`）

### 2.4 交互式确认

| 项目 | 说明 |
|------|------|
| `.gitconfig` | 逐文件确认，含用户名/邮箱警告 |
| `.git-credentials` | 逐文件确认，提醒凭据泄露风险 |
| `.ssh` / `.gnupg` | 仅提示，不删除（可能被其他工具使用） |

---

## 三、生成文件的依赖关系

```
install.ps1 运行后生成:
│
├── claude-launcher.ps1    ← 启动器（DPAPI 内存解密 API Key）
├── Claude Code.lnk        ← 桌面快捷方式（指向启动器）
├── install-success-*.txt  ← 成功日志
├── install-log-*.txt      ← 错误日志（仅失败时）
└── 注册表:
    ├── HKCU\Environment\ANTHROPIC_AUTH_TOKEN_ENC  ← DPAPI 加密的 API Key
    ├── HKCU\Environment\ANTHROPIC_BASE_URL        ← 非敏感环境变量 (×8)
    └── HKCU\SOFTWARE\ClaudeCodeDeepSeekInstaller  ← 安装标记

uninstall.ps1 读取:
│
├── 注册表安装标记 ──→ 决定卸载范围
├── 注册表卸载条目 ──→ 执行 MSI/EXE 卸载
└── 清理以上所有生成物
```

---

## 四、使用方式

### 安装

```powershell
# 右键以管理员身份运行，或直接双击
.\install.ps1
```

### 卸载

```powershell
# 右键以管理员身份运行，或直接双击
.\uninstall.ps1
```

### 日常使用

双击桌面的 **Claude Code** 快捷方式即可启动。启动流程：

```
双击 Claude Code.lnk
  → powershell.exe -File claude-launcher.ps1
    → 从注册表读取加密的 API Key
    → 内存中 DPAPI 解密
    → 设置 $env:ANTHROPIC_AUTH_TOKEN
    → 加载其他环境变量
    → 启动 claude
```

---

## 五、关键设计决策

| 决策 | 原因 |
|------|------|
| DPAPI 而非明文存储 | 防止 API Key 以明文形式存在于磁盘或环境变量中 |
| 启动器脚本分离 | 解密逻辑独立于快捷方式，方便维护和审计 |
| API Key 不入临时文件 | 提权 IPC 时仅传递非敏感变量，加密 blob 从注册表直接读取 |
| 哨兵标记 | 区分脚本安装 vs 用户预装软件，防止误卸载 |
| 多源下载 + 哈希校验 | 提高国内下载成功率的同时保障文件完整性 |
| npm audit 超时保护 | 30 秒超时防止 audit 卡住安装流程 |
| 执行策略自动恢复 | 脚本退出前恢复 `CurrentUser` 原始 ExecutionPolicy |
| PATH 白名单 | 防止误删系统关键路径 |
