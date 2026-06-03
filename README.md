# Claude Code + DeepSeek 一键安装/卸载

Windows 一键安装和卸载 Claude Code（DeepSeek 后端）。

## 文件说明

| 文件 | 说明 | 大小 |
|------|------|------|
| `build-installer.exe` | 一键安装：Node.js + Git + Claude Code + DeepSeek 配置 | 91.6 MB |
| `uninstaller.exe` | 一键卸载：清理 Claude Code + Node.js + Git + 环境变量 | 130 KB |

## 使用方法

### 安装
双击运行 `build-installer.exe`，按提示操作即可。

安装内容包括：
- Node.js 18+
- Git for Windows
- Claude Code（@anthropic-ai/claude-code）
- DeepSeek API 环境变量配置（可选）

### 卸载
双击运行 `uninstaller.exe`，自动清理所有安装内容。

## 注意事项

- 需要 **管理员权限**（脚本会自动提权）
- 安装包已内置 Node.js 和 Git 离线安装包，无需联网
- 作者：cynch18
