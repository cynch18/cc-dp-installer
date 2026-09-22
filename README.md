# Claude Code + DeepSeek 一键安装器

在 Windows 10/11 上安装 Claude Code 开发环境，配置 [DeepSeek API](https://api.deepseek.com/anthropic) 作为后端，使用 Windows DPAPI 加密存储 API Key。

## 仓库内容

本仓库只有脚本源码，**不包含**预编译的可执行文件：

| 文件 | 说明 |
|------|------|
| `install.ps1` | 安装脚本（支持 `-DryRun` 干跑） |
| `uninstall.ps1` | 卸载脚本（支持 `-DryRun` 干跑） |
| `README.md` | 本文档 |
| `LICENSE` | MIT |

> **关于 `Install.exe` / `Uninstall.exe`**：那两个是将上面两个 `.ps1` 打包成自解压包后的
> **发布产物**，不在本仓库中，仓库里也没有产出它们的构建脚本（离线包体积过大，不适合入库）。
> 从源码使用请见下面的「快速开始」。若你拿到的是 `.exe`，请以发布页给出的校验值为准，
> 不要从第三方转发处下载。

## 快速开始

### 安装（源码方式）

1. 下载本仓库（或 `git clone`）
2. 右键 `install.ps1` → **使用 PowerShell 运行**
3. UAC 弹窗点「是」→ 按提示输入 DeepSeek API Key

想先确认它到底会动什么，可以先干跑：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -DryRun
```

干跑模式**不下载、不安装、不写注册表或环境变量、不生成任何文件**，只打印将要执行的操作。
干跑不需要管理员权限，也不会弹 UAC。

### 卸载

```powershell
# 强烈建议先干跑看一眼这次的删除范围
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 -DryRun

# 确认无误后再真正执行
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

### 日常使用

双击桌面 **Claude Code** 快捷方式即可启动。

## 功能概览

### 安装脚本（install.ps1）

- ✅ 自动检测并安装 **Node.js 18+**（官方源 + 国内镜像多源回退，支持离线安装包）
- ✅ 自动检测并安装 **Git for Windows**（同上）
- ✅ 安装 **Claude Code**（`npm install -g @anthropic-ai/claude-code`）
- ✅ 配置 **DeepSeek API** 作为后端
- ✅ **DPAPI 加密**存储 API Key（不落盘明文），写入后回读验证确实可解密
- ✅ 生成桌面快捷方式 + 安全启动器脚本（启动器与项目目录均做 ACL 加固）
- ✅ **完整性校验 fail-closed**：哈希取不到时**中止安装**，不会静默跳过
- ✅ 校验和来源与安装包来源**不同源优先**（官方哈希 + 镜像二进制）
- ✅ 失败时写日志到桌面；成功摘要也会明确告知位置

### 卸载脚本（uninstall.ps1）

- ✅ 卸载 Claude Code / Node.js / Git —— **只卸本脚本装的那些**
- ✅ 清理环境变量与 PATH（只删除目标目录已不存在的条目；改写前备份原值、保持注册表类型）
- ✅ 清理桌面快捷方式、日志、临时文件
- ✅ **哨兵机制**：只记录「本脚本实际安装了哪些组件」，用户预装的 Node.js / Git 一律保留
- ✅ **交互式确认**：`~/.claude`、`.gitconfig` 等用户数据逐项确认后删除，**默认保留**
- ✅ 终止进程时按**可执行文件路径**匹配，不会误杀你自己开的 Git Bash / dev server

## 安全设计

```
用户输入 API Key
       │
       ▼
┌─────────────────────────────────────┐
│  Windows DPAPI 加密                  │
│  DataProtectionScope::CurrentUser    │
└─────────────────────────────────────┘
       │
       ▼
  加密密文存入注册表
  (ANTHROPIC_AUTH_TOKEN_ENC)
       │
       ▼
  桌面快捷方式 → claude-launcher.ps1
  → DPAPI 内存解密 → $env:ANTHROPIC_AUTH_TOKEN
  → 启动 claude
```

### DPAPI 的威胁边界（请如实理解，别当它是把锁）

**能挡住：**

- **其他 Windows 账户** —— 换个账户登录解不开
- **离线数据泄漏** —— 注册表导出文件、磁盘镜像、备份被别人拿到，没有你的登录凭据也解不开
- **误截图、误分享**

**挡不住：**

- **同一账户下的其他进程。** `DataProtectionScope::CurrentUser` 的解密密钥由你的登录凭据派生，
  同一账户下的任何程序（包括恶意软件）都能**无提示地**解密出明文 Key。
- **解密之后。** Key 会被放进 `$env:ANTHROPIC_AUTH_TOKEN`，对 Claude Code 启动的全部子进程可见。

一句话：它保证的是「**Key 在磁盘上不以明文存在**」，不是「Key 在本机读不到」。

### 其他安全措施

- **校验链**：下载后校验 SHA256（自己用 .NET 的 SHA256 实现，不依赖 `Get-FileHash` 这类可能加载失败的 cmdlet）。
  校验和优先取官方站（与二进制不同源），官方站不可达时按镜像链回退；
  全都取不到时**中止安装并要求人工确认**，不会静默跳过。
  Git 与 Node 两侧都会额外校验 Authenticode 签名**主体 CN** 是否为官方发布者。
  「哈希算出来了但对不上」与「压根没算出哈希」是两回事：前者直接中止，后者走人工确认。
- **提权链自校验**：父进程在提权前计算自身脚本的 SHA256 并传给子进程，子进程以管理员身份复核，
  不一致就中止 —— 防御 UAC 等待期间脚本被替换。
- **卸载哨兵**：安装脚本只把「**真正由本脚本安装**」的组件记为 1；用户预装的 Node.js / Git 记为 0，
  卸载时直接保留。安装标记缺失或为旧格式时一律按「无法确认」处理（fail-close），默认不删任何安装目录。

## 环境变量

| 变量 | 值 | 说明 |
|------|-----|------|
| `ANTHROPIC_AUTH_TOKEN_ENC` | DPAPI 加密密文 | API Key（加密存储） |
| `ANTHROPIC_BASE_URL` | `https://api.deepseek.com/anthropic` | API 端点 |
| `ANTHROPIC_MODEL` | `deepseek-v4-pro[1m]` | 默认模型 |
| `ANTHROPIC_DEFAULT_OPUS_MODEL` | `deepseek-v4-pro[1m]` | Opus 模型 |
| `ANTHROPIC_DEFAULT_SONNET_MODEL` | `deepseek-v4-pro[1m]` | Sonnet 模型 |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL` | `deepseek-v4-flash` | Haiku 模型 |
| `CLAUDE_CODE_SUBAGENT_MODEL` | `deepseek-v4-flash` | 子代理模型 |
| `CLAUDE_CODE_EFFORT_LEVEL` | `max` | 执行力度 |
| `CLAUDE_CODE_ATTRIBUTION_HEADER` | 可选 `0` | 关闭归属标头。**安装时询问，默认不改动** |

> 模型名与 API 端点集中在 `install.ps1` 顶部的**配置区**，换模型不用翻流程代码。
>
> ⚠️ 模型名是否为服务端合法值**未经校验**。如果写错，症状是**静默 404** 而不是明确报错。
> 建议首次配置完成后直接运行一次 `claude` 确认能正常对话。

## 系统要求

- Windows 10/11（64 位）
- 管理员权限（安装过程中自动提权）
- PowerShell 5.1+

## 依赖项

| 软件 | 版本要求 | 说明 |
|------|----------|------|
| Node.js | ≥ 18 | 运行 Claude Code 的运行时 |
| Git | 任意 | 版本管理（可选但推荐） |
| Claude Code | 最新 | 通过 npm 全局安装 |

## 下载源

| 资源 | 主源 | 备用镜像 |
|------|------|----------|
| Node.js | [nodejs.org](https://nodejs.org) | npmmirror.com |
| Git | [GitHub Releases](https://github.com/git-for-windows/git/releases) | TUNA 镜像 / NJU 镜像 |
| Claude Code | npm 官方源 | registry.npmmirror.com |

> 镜像源与 SHA256 校验和同样多源回退。哈希来自镜像时，防护强度弱于来自官方站
> （镜像方能同时改包和改哈希），但仍强于零校验 —— 这是刻意的取舍：官方站被墙
> 恰恰是脚本内置镜像的原因，若此时"跳过验证"就等于在最需要校验时放行。

## 常见问题

### Q: 为什么需要管理员权限？

脚本需要安装 Node.js 和 Git（写入 `Program Files`）、修改系统 PATH 环境变量、写入注册表。
只想看它要做什么的话用 `-DryRun`，干跑不需要管理员权限。

### Q: API Key 存在哪里？安全吗？

API Key 用 Windows DPAPI 加密后存入用户注册表（`HKCU\Environment`），解密只在内存中进行。

但请注意它的边界：DPAPI 保证的是「磁盘上不含明文」，**不保证同一账户下的其他进程读不到**。
详见上面的「DPAPI 的威胁边界」。

### Q: 干跑模式会改东西吗？

不会。`-DryRun` 只打印将要执行的操作，不下载、不安装、不写注册表 / 环境变量、不生成文件，
也不读取或保存任何 API Key。

### Q: 安装失败怎么办？

查看桌面生成的 `install-log-*.txt`（安装成功时生成的是 `install-success-*.txt`，里面是各组件版本）。
常见原因：

- 杀毒软件拦截 → 临时关闭后重试
- 网络问题 → 脚本会自动尝试国内镜像
- C 盘空间不足 → 清理后重试
- 提示"无法完成完整性校验" → 官方校验和站点不可达。排查网络 / 代理后重试，
  或手动下载官方安装包放到脚本同目录。**离线包如果是与当前目标版本同名的，照常做哈希比对；
  版本不同则跳过哈希比对、改用 Authenticode 签名校验** —— 无论哪种，都请自行确认它来自官方渠道

### Q: 卸载不干净怎么办？

卸载脚本已覆盖常见残留路径。如仍有残留，重启计算机后手动删除：

- Node.js: `C:\Program Files\nodejs`
- Git: `C:\Program Files\Git`
- Claude Code: `%APPDATA%\npm\node_modules\@anthropic-ai`

### Q: 能用其他 API 后端吗？

可以。安装时跳过 DeepSeek 配置，然后手动设置环境变量指向你的端点：

```powershell
$env:ANTHROPIC_BASE_URL = "https://your-api-endpoint.com/anthropic"
$env:ANTHROPIC_AUTH_TOKEN = "your-api-key"
```

### Q: 卸载会不会把我自己装的 Node.js / Git 删掉？

不会。安装脚本只把「**本次真正由它安装**」的组件写进安装标记；你预先装好的 Node.js / Git
会被标记为 0，卸载时原样保留。

如果安装标记缺失或来自旧版本（旧版本只记录"检测到的版本号"，无法区分谁装的），
卸载脚本会**按最保守的方式处理**：默认只清理环境变量、快捷方式与 PATH 中失效的条目，
不碰任何安装目录。确需连安装目录一起删时，需要按提示输入 `uninstall` 全词显式授权。

不放心的话先跑 `uninstall.ps1 -DryRun`，它会列出本次会删什么、会留什么。

## 已知限制

- **⚠️ 从零安装的完整链路尚未在干净机器上验证过（最重要的一条）**

  目前只在「Node.js / Git / Claude Code 都已经装好」的机器上做过完整验证。也就是说：

  | | 状态 |
  |---|---|
  | 不误删你已装的软件（哨兵语义、保守路径） | ✅ 已实测验证 |
  | 干跑零改动、删除范围符合预期 | ✅ 已实测验证 |
  | 哈希校验、安全闸门、卸载取舍逻辑 | ✅ 已单测 + 沙盒验证 |
  | **在没有 Node.js / Git 的机器上从零装通** | ❌ **尚未验证** |

  所以：**如果你的机器上已经有 Node.js 18+ 和 Git，可以放心用**；
  **如果是全新环境，建议先在一台可回滚的虚拟机里试一遍** ——
  从下载 → 校验 → 安装 Node/Git → 装 Claude Code → 写安装标记 这整条链路，
  还从没在一次真实运行里走通过。

- **提权链**只能防御 UAC 等待期间的脚本替换（父子进程互校验哈希），**无法防御**
  「你在运行之前文件就已经被替换」。请从可信来源获取脚本。
- **TOCTOU**：安装包在 `%TEMP%` 完成校验后才交给安装器执行。已通过随机文件名 +
  校验后紧邻执行缩小窗口，但未根除 —— 同账户的低权限进程理论上仍可在窗口内替换文件。
- **PATH 修改不可逆**：卸载会改写 Machine / User 级 PATH。改动前会把原值备份到桌面
  `path-backup-*.txt`，但 PATH 本身的读-改-写无法做到绝对安全（本机实测就见过
  `C:\Pro;ram Files\...` 这类历史损坏）。
- **模型名未经校验**：写错会表现为静默 404，见上面的「环境变量」一节。
- 脚本**没有端到端自动化测试**（会真实改动系统，不适合在 CI 里跑）。CI 只做语法解析、
  编码校验与 PSScriptAnalyzer 静态检查。
- **捕获脚本输出时注意编码**：脚本会把控制台切到 UTF-8（简体中文 Windows 默认的 GBK
  里没有 emoji，不切的话满屏 `?`）。若你用另一个进程捕获它的输出（管道 / CI / 存进
  PowerShell 变量），请在捕获端先执行：
  ```powershell
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  ```
  否则捕获到的中文会是乱码。双击运行不受影响。
  （不按"是否被重定向"自动切换，是因为"重定向到文件再用编辑器打开"这个场景期望 UTF-8，
  而"被 PowerShell 捕获"这个场景期望系统编码 —— 两者相反，脚本只能选其一并写明白。）

## 免责声明

1. **第三方服务**：本脚本配置的 API 后端为 DeepSeek（独立第三方），与 Anthropic 无关。
   使用即表示你同意 DeepSeek 的服务条款和隐私政策。

2. **数据隐私**：使用 DeepSeek 作为后端时，对话内容将发送至 DeepSeek 服务器而非 Anthropic。
   请勿分享敏感信息。

3. **供应链安全**：当官方源不可用时，脚本会回退到第三方国内镜像（npmmirror、TUNA）。
   校验和同样按镜像链回退 —— 来自镜像的哈希只能防传输损坏，防不住恶意镜像。
   脚本在完全无法校验时**会中止**（可人工确认后继续），但无法完全消除风险。

4. **按原样提供**：本脚本集不附带任何明示或暗示的担保。作者不对因使用本脚本而导致的任何损失负责。

## 许可证

[MIT](LICENSE)
