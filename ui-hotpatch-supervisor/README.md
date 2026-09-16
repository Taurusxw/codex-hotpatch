# Codex 界面热补丁总监督

当前版本：**1.0.3**

此组件补齐两个界面热补丁的进程生命周期：`sidebar-archive-filter` 和 `subagent-status` 各自仍拥有独立 watcher、injector、安装与回退边界；总监督在缺失时隐藏拉起 watcher，并在 Codex 正运行时通过只读状态查询报告 renderer 是否实际装载。它不注入 renderer、不读取或写入任务数据库、JSONL、正文，也不修改 Codex、Codex++ 或 `app.asar`。

总监督不保存 Store 包版本、Codex++ 版本或 DevTools 端口。组件 watcher 继续通过共享生命周期模块从当前 `ChatGPT.exe` 命令行和 `app://-/index.html` 目标动态识别端口，因此 Codex++ 重启、随机端口变化和兼容的 Store 更新无需重新配置。总监督还会按父 PID 清理由已退出 watcher 遗留的孤儿 injector，再启动替代 watcher，避免反复崩溃后累积 Node 进程。若 watcher 连续崩溃，总监督采用 2、4、8、16、32、60 秒退避，避免不兼容新版界面时形成重启风暴；组件卸载会移除自己的启动项，总监督据此停止复活该组件。

## 使用

```powershell
& '.\ui-hotpatch-supervisor\manage-hotpatch.ps1' -Mode Install
& '.\ui-hotpatch-supervisor\manage-hotpatch.ps1' -Mode Status
& '.\ui-hotpatch-supervisor\manage-hotpatch.ps1' -Mode RunOnce
& '.\ui-hotpatch-supervisor\manage-hotpatch.ps1' -Mode Uninstall
```

`Install` 创建当前用户隐藏启动项，并通过 Explorer 外壳启动独立总监督，避免继承短生命周期安装命令的进程作业。总监督在 Codex 未运行时也保持在线并确保组件 watcher 已就绪；Codex++ 随后启动或更换 DevTools 端口时，组件 watcher 自己完成重新注入。`Uninstall` 只停止总监督并移除其启动项，不停止两个独立组件、不撤销已注入 renderer 状态。

正常状态应显示 `Installed=True`、`SupervisorRunning=True`、`Healthy=True`，并且两个已安装组件的 `WatcherRunning=True`。带 DevTools 的 Codex 会话运行时，两个组件还应显示 `RendererInstalled=True`；若 watcher 存活但 renderer 未装载，`Healthy=False` 并保留 `RendererState` 与错误摘要供诊断。`InjectorRunning` 仅在带 DevTools 的 Codex 会话运行时为真。

## 兼容与失败边界

- 只监督安装目录和用户启动项仍齐全的已安装组件，不扫描或执行任意脚本。
- 不绑定固定端口、WindowsApps 版本路径或 Codex++ 可执行文件路径。
- 不掩盖 injector 的兼容错误；renderer 契约变化会由组件 `Status` 与总监督的只读 renderer 状态共同报告，并安全停止本轮注入。
- 日志仅记录组件名、动作与错误，位于 `%LOCALAPPDATA%\OpenAI\Codex\hotpatches\ui-hotpatch-supervisor`，不记录任务正文或登录态。
