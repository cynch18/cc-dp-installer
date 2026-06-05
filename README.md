# Claude Code + DeepSeek 一键安装器

在 Windows 10/11 上一键安装 Claude Code 开发环境，配置 [DeepSeek API](https://api.deepseek.com/anthropic) 作为后端，使用 Windows DPAPI 安全存储 API Key。

## 快速开始

### 安装

```powershell
# 方式一：双击运行（推荐）
双击 Install.exe → UAC 弹窗点"是" → 按提示输入 DeepSeek API Key

# 方式二：源码运行
右键 install.ps1 → "使用 PowerShell 运行"
```

### 卸载

```powershell
双击 Uninstall.exe → UAC 弹窗点"是"
```

### 日常使用

双击桌面 **Claude Code** 快捷方式即可启动。

## 文件说明

| 文件 | 说明 |
|------|------|
| `Install.exe` | 一键安装器（7-Zip SFX，内嵌离线安装包，无需联网） |
| `Uninstall.exe` | 一键卸载器（7-Zip SFX） |
| `install.ps1` | 安装脚本源码 |
| `uninstall.ps1` | 卸载脚本源码 |

## 功能概览

### 安装脚本（install.ps1）

- ✅ 自动检测并安装 **Node.js 18+**（支持离线安装包回退）
- ✅ 自动检测并安装 **Git for Windows**（支持离线安装包回退）
- ✅ 安装 **Claude Code**（`npm install -g @anthropic-ai/claude-code`）
- ✅ 配置 **DeepSeek API** 作为后端
- ✅ **DPAPI 加密**存储 API Key（永不落盘明文）
- ✅ 生成桌面快捷方式 + 安全启动器脚本
- ✅ SHA256 哈希校验 + 多源下载镜像 + 自动重试

### 卸载脚本（uninstall.ps1）

- ✅ 完整卸载 Claude Code / Node.js / Git
- ✅ 清理所有环境变量和 PATH
- ✅ 清理桌面快捷方式、日志、临时文件
- ✅ 哨兵机制：区分脚本安装 vs 用户预装软件，防止误卸载
- ✅ 交互式确认：`.gitconfig` 等敏感配置逐文件确认后删除

## 安全设计

```
用户输入 API Key
       │
       ▼
┌─────────────────────────────┐
│  Windows DPAPI 加密          │
│  (绑定当前用户 + 当前机器)    │
└─────────────────────────────┘
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

**关键点：**
- API Key **永不**以明文写入磁盘
- 解密仅在内存中进行
- 加密绑定到当前 Windows 用户，其他用户/机器无法解密
- 启动器脚本 ACL 加固（仅当前用户和 SYSTEM 可修改）

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
| `CLAUDE_CODE_ATTRIBUTION_HEADER` | `0` | 关闭归属标头 |

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

## 常见问题

### Q: 为什么需要管理员权限？

脚本需要安装 Node.js 和 Git（写入 `Program Files`）、修改系统 PATH 环境变量、写入注册表。

### Q: API Key 存在哪里？安全吗？

API Key 使用 Windows DPAPI 加密后存入用户注册表（`HKCU\Environment`），解密仅在内存中进行。DPAPI 加密绑定到你的 Windows 登录凭据——只有你的账户在当前机器上才能解密。

### Q: 安装失败怎么办？

检查桌面生成的 `install-log-*.txt` 日志文件。常见原因：
- 杀毒软件拦截 → 临时关闭后重试
- 网络问题 → 脚本会自动尝试国内镜像
- C 盘空间不足 → 清理后重试

### Q: 卸载不干净怎么办？

卸载脚本已经覆盖了常见残留路径。如仍有残留，重启计算机后手动删除：
- Node.js: `C:\Program Files\nodejs`
- Git: `C:\Program Files\Git`
- Claude Code: `%APPDATA%\npm\node_modules\@anthropic-ai`

### Q: 可以用其他 API 后端吗？

可以。安装时跳过 DeepSeek 配置，然后手动设置环境变量指向你的 API 端点：

```powershell
$env:ANTHROPIC_BASE_URL = "https://your-api-endpoint.com/anthropic"
$env:ANTHROPIC_AUTH_TOKEN = "your-api-key"
```

### Q: Git-2.54.0-64-bit.exe 是什么？

Git for Windows 的离线安装包。当联网下载失败时，安装脚本会自动回退使用这个本地文件。如果不需要离线安装，可以删除。

## 免责声明

1. **第三方服务**：本脚本配置的 API 后端为 DeepSeek（独立第三方），与 Anthropic 无关。使用即表示你同意 DeepSeek 的服务条款和隐私政策。

2. **数据隐私**：使用 DeepSeek 作为后端时，对话内容将发送至 DeepSeek 服务器而非 Anthropic。请勿分享敏感信息。

3. **供应链安全**：当官方源不可用时，脚本会回退到第三方国内镜像（npmmirror、TUNA）。脚本已内置 SHA256 校验以降低风险，但无法完全消除。

4. **按原样提供**：本脚本集不附带任何明示或暗示的担保。作者不对因使用本脚本而导致的任何损失负责。

## 许可证

本项目中的脚本（`install.ps1`、`uninstall.ps1`、`claude-launcher.ps1`）按 MIT 许可证发布。

本脚本安装的第三方软件（Node.js、Git、Claude Code）各自受其原始许可证约束。
