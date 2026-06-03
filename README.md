# Claude Code + DeepSeek 一键部署工具

Windows 一键安装/卸载 **Claude Code** + **DeepSeek**，无需联网，双击即用。

---

## 💿 一键安装（推荐）

下载 `build-installer.exe`，双击运行：

1. 弹出提示 → 点「是」
2. 自动安装 Node.js + Git + Claude Code
3. 询问是否配置 DeepSeek API Key（可跳过）
4. 完成！

**安装内容包括：**
- Node.js 18+（内置离线包）
- Git for Windows（内置离线包）
- Claude Code（通过 npm 安装）
- DeepSeek API 环境变量（可选）

---

## 🗑️ 一键卸载

下载 `uninstaller.exe`，双击运行：

1. 弹出提示 → 点「是」
2. 自动清理 Claude Code + Node.js + Git
3. 清理 PATH 和环境变量残留
4. 完成！

**卸载内容包括：**
- Claude Code（npm 卸载 + 残留目录）
- Node.js（注册表卸载 + 目录清理）
- Git（卸载程序 + 目录清理）
- DeepSeek 环境变量
- PATH 中相关的残留条目
- 桌面安装日志文件

---

## 🖥️ 仅使用 PS1 脚本

如果只想下载脚本自己运行：

### 下载
- `install.ps1` — 安装脚本
- `uninstall.ps1` — 卸载脚本

### 运行方式

**右键运行：** 右键 `.ps1` 文件 →「使用 PowerShell 运行」

**命令行运行：**
```powershell
# 安装
powershell -ExecutionPolicy Bypass -File .\install.ps1

# 卸载
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

> ⚠️ 单独使用 `.ps1` 脚本需要**联网**才能下载 Node.js 和 Git。  
> 如果网络不好，把 `node-v*.msi` 和 `Git-*.exe` 放在脚本同目录下，脚本会自动使用离线包。

---

## ⚠️ 免责声明

本工具仅供学习和合法用途使用。

- 使用本工具即表示你已了解其功能并自愿承担一切风险。
- 安装过程中会修改系统环境变量和注册表，卸载脚本会删除相关条目。
- 作者对因使用本工具造成的任何直接或间接损失不承担任何责任。
- DeepSeek API Key 由用户自行提供，请妥善保管。
- Claude Code 和 DeepSeek 为各自所有者的商标。

---

## 👤 作者

cynch18
