# Codex WebSocket Proxy Setup

一个面向 Windows 的 Codex Desktop 代理配置工具。它会检测并验证本机 HTTP 代理，将代理设置安全地写入当前用户的 `%USERPROFILE%\.codex\.env`，并在用户确认后尝试重启 Codex Desktop。

## 适用场景

- Codex Desktop 的 WebSocket 连接需要经过本机代理；
- 不想手动查找代理端口或编辑 `.env`；
- 希望保留 `.env` 中与代理无关的已有配置；
- 需要在失败时自动恢复原文件，避免留下不完整配置。

## 文件说明

| 文件 | 用途 |
| --- | --- |
| `setup-codex-websocket-proxy.cmd` | 单文件发布版，适合普通用户直接运行；内部包含压缩后的 PowerShell 逻辑。 |
| `src/setup-codex-websocket-proxy.ps1` | 可直接审阅的 PowerShell 源码。 |

## 系统要求

- Windows 10 或 Windows 11；
- Windows PowerShell 5.1 或更高版本；
- 已安装 Codex Desktop；
- 本机存在支持 HTTP `CONNECT` 的代理。

## 使用方法

### 推荐：运行单文件版本

1. 下载 `setup-codex-websocket-proxy.cmd`；
2. 在文件上右键，选择“以管理员身份运行”；
3. 脚本会自动检测并验证代理；
4. 如果无法自动检测，可按提示手动输入代理端口；
5. 配置写入后，根据提示决定是否立即重启 Codex Desktop。

> 不要从 Codex 内部启动该脚本。脚本需要关闭并重新启动 Codex，应从文件资源管理器中运行。

### 运行可审阅源码

自动检测代理：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\setup-codex-websocket-proxy.ps1
```

明确指定代理：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\setup-codex-websocket-proxy.ps1 -ProxyHost 127.0.0.1 -ProxyPort 7890
```

## 脚本会做什么

1. 确认脚本以管理员身份运行，并检查当前交互用户；
2. 从环境变量、Windows 系统代理、常见代理进程和本地端口中查找代理；
3. 通过 TCP 与 HTTP `CONNECT api.openai.com:443` 验证代理可用性；
4. 创建或更新 `%USERPROFILE%\.codex\.env`：

   ```dotenv
   HTTP_PROXY="http://127.0.0.1:端口"
   HTTPS_PROXY="http://127.0.0.1:端口"
   NO_PROXY="localhost,127.0.0.1,::1"
   ```

5. 保留 `.env` 中其他配置，并合并重复的代理变量；
6. 写入失败时恢复原文件；
7. 获得用户确认后，尝试安全关闭并重新启动 Codex Desktop。

## 安全说明

- 脚本需要管理员权限，用于识别和控制 Codex Desktop 的应用包及相关进程；
- 只允许目标文件严格位于当前用户的 `.codex\.env`，并拒绝符号链接、目录联接、只读文件和异常大小文件；
- 不会覆盖 `.env` 中与代理无关的内容；
- 不会自动使用无法通过 HTTP `CONNECT` 验证的代理；
- 正常成功时不生成日志；失败时可能在 `%TEMP%\CodexWebSocketProxy` 中生成错误日志；
- 单文件 `.cmd` 会在内存中解压并运行嵌入的 PowerShell。审阅时请以 `src/setup-codex-websocket-proxy.ps1` 为准。

## 已知限制

- 自动重启依赖 Windows 能够识别 Codex 的 MSIX/Appx 包；
- 企业策略或安全软件可能阻止进程枚举、包级终止或应用启动；
- 当脚本无法可靠判断 Codex 进程归属时，会停止自动重启，避免误关其他程序或启动重复实例；
- 代理必须支持访问 `api.openai.com:443` 的 HTTP `CONNECT`。

## 开发与发布

修改 `src/setup-codex-websocket-proxy.ps1` 后，需要重新生成单文件 `.cmd`，并验证嵌入载荷与源码完全一致。不要直接编辑 `.cmd` 中的 Base64/GZip 载荷。

## 免责声明

请在了解脚本行为后使用，并在运行前保存重要工作。脚本会在获得确认后关闭并重新启动 Codex Desktop。
