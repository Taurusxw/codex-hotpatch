# Codex 运行时更新修复

组件版本 **1.0.0**。从旧网络补丁中保留的唯一功能：按官方包内容准备 CLI、Node/CUA 和 ripgrep 缓存，缓解桌面更新后运行时目录发布失败、文件缺失或损坏导致的启动报错。

## 工作方式

- Windows 登录后隐藏启动一个守护进程，每 45 秒检查当前用户的 `OpenAI.Codex` Appx 版本与已完成的 Stage 事件。
- 首次启动、注册版本变化或发现尚未准备的新版 Stage 时，校验官方包内容并补齐缓存；普通轮询不重复扫描全部运行时文件。
- 复用桌面应用的内容哈希目录。CLI 四个同包文件、完整 Node/CUA 依赖树和独立的 `rg.exe` 分别校验；已有且一致的文件保持不动。
- 不重命名运行时目录。仅对不一致的文件执行同目录临时复制、哈希校验和原子发布；保留旧版本缓存。遇到占用或未完成的更新，下轮重试。

不连接网络，不修改代理、provider、模型、登录态、会话或 Codex 安装包，不启动或重启 Codex。它无法修复服务端或网络链路引起的流中断。

## 命令

在 Windows PowerShell 5.1 中运行（PowerShell 7 测试亦通过；安装使用 Windows PowerShell 承载 Appx 守护）：

```powershell
& '.\runtime-repair\manage-hotpatch.ps1' -Mode Status
& '.\runtime-repair\manage-hotpatch.ps1' -Mode Install
& '.\runtime-repair\manage-hotpatch.ps1' -Mode Repair
& '.\runtime-repair\manage-hotpatch.ps1' -Mode Disable
```

`Install` 先准备当前运行时，再安装守护和 `Codex 运行时修复.lnk` 启动项。`Repair` 手动复核并修复当前版本，适用于同版本缓存后来损坏的情况。`Disable` 停止本组件守护并移除启动项，保留脚本、日志和已准备的官方缓存。

安装目录为 `%LOCALAPPDATA%\OpenAI\Codex\hotpatches\runtime-repair`。`runtime-status.json` 区分当前注册版本的准备结果与 Stage 检查错误；`runtime-watchdog.log` 仅记录准备结果或错误变化，单文件上限约 256 KiB，保留一份轮转日志。`Ready` 表示本守护最近成功准备了当前版本，不等价于所有 Codex 功能健康。

## 兼容边界

当前提取逻辑已在 Codex Desktop `26.924.2738.0` 验证。它依赖官方 Windows x64 Appx 目录和运行时哈希规则；将来布局变化需要重新核对，不能保证覆盖所有更新错误。Stage 日志不可读取时，仍处理注册版本变化，但提前准备不可用。

测试覆盖缓存完整性、文件占用、旧版本保留、Stage 选择、更新失败重试、空闲轮询和进程生命周期；不触碰真实 Codex 会话或网络配置。
