# Codex 子智能体状态同步热补丁

这是一个独立于 Codex 安装目录的用户级运行时补丁，用于修复“子智能体已经完成，但侧栏仍显示处理中”的显示状态滞留。当前版本为 **1.3.12**。

## 工作方式

- 只连接 Codex 自身已开启的本地 DevTools 端口。
- 不使用全页面 `MutationObserver`；空闲时只有事件监听器和一个每秒仅查询面板标识的轻量探针，不遍历子智能体列表。
- 只读索引 `~/.codex/sessions` 中每个子智能体自身 JSONL 的尾部，不改写会话；只有其**最新生命周期事件**明确为 `task_complete`，才会成为刷新候选。
- Codex 每次启动后都会从这些持久完成证据重建状态，并在侧栏打开前把已验证条目的 React 状态投影为 `done`；因此不再依赖上一次 renderer 的临时内存，也不会在重启后重新显示为处理中。
- renderer 适配器不再绑定单一 `subagents` 属性名，而是在子智能体控件的 React 近邻中按 `conversationId`、`parentConversationId` 和 `status` 结构识别代理数组，兼容新版 `backgroundAgents` 及后续等价改名。
- 折叠摘要会与同一份完成证据同步：已完成项从“运行中”计数中移除；React 在重启后重建代理对象时会再次投影，摘要文本同时提供低风险即时兜底，无需先打开详情面板才能纠正。
- 优先从当前侧栏按钮的 React 数据提取精确 `conversationId`，再沿 `parentConversationId` 父链确认它属于当前任务的直接或多级后代；新界面不暴露 ID 时，仅允许使用已验证后代清单内唯一且完全相同的显示名称兜底，重复或模糊名称仍跳过。
- 用户打开“子智能体”侧栏、补丁注入时侧栏已经打开，或当前侧栏中的子智能体刚产生完成证据时，都会启动同步，不再依赖一次容易错过的按钮点击。
- 最新事件为 `task_started` 的正在运行或重新连接子智能体一律跳过；记录正在写入、JSON 不完整、身份无法确认或证据未知时也一律跳过。
- 会话文件一发生变化，就先撤销该子智能体的完成资格；等待写入稳定并重新确认最新事件后，才可能恢复资格。
- 超大列表按低优先级小批次续跑，直到已展开范围处理完；每批之间让出渲染时间，用户一交互就取消后续批次。
- 每个条目之间主动让出渲染时间并限速；用户点击、按键、切换页面、关闭面板或出现模态对话框时会立即中止本轮处理。
- 单次打开最多检查 128 个条目；极端情况下超过该数量，只需关闭并重新打开侧栏继续，避免一次修复长时间占用界面。
- 已完成的子智能体优先在侧栏打开前直接归入“完成”；旧界面无法提供预打开数据时，才回退为逐项打开详情并让 Codex 自身迁移。真正仍在运行或重新连接的条目不会被投影或打开。
- 不修改 WindowsApps 中的 Codex 文件，不写 SQLite、会话 JSONL 或任务内容，也不点击批准、拒绝、停止或发送消息按钮。

## 管理命令

```powershell
# 从仓库根目录运行
Set-Location '<repo-root>'

# 安装并立即启用；同时创建当前用户启动项
& '.\subagent-status\manage-hotpatch.ps1' -Mode Install

# 查看状态
& '.\subagent-status\manage-hotpatch.ps1' -Mode Status

# 对当前 Codex 页面重新安装轻量事件监听器
& '.\subagent-status\manage-hotpatch.ps1' -Mode RunOnce

# 停用并移除启动项；不删除审计文件
& '.\subagent-status\manage-hotpatch.ps1' -Mode Uninstall
```

补丁由四个可审计文件组成：管理脚本、渲染器注入器、只读完成证据索引模块和共享 DevTools transport。安装副本与日志位于：

`%LOCALAPPDATA%\OpenAI\Codex\hotpatches\subagent-status`

启动项名称为 `CodexSubagentStatusHotpatch.lnk`。Codex 更新或重启后，共享生命周期模块会按当前进程、动态调试端口与 `app://-/index.html` renderer 自动识别 Codex，并监督 injector 重启与定期自愈；不依赖 Microsoft Store 包版本号或固定安装路径。若端点暂时不可用，安装仍会完成并低频重试，不会反复重建会话索引。补丁会探测注入时已经打开的“子智能体”侧栏，也会在完成证据更新时触发同步，无需强制关闭重开。若界面结构在未来版本发生变化，补丁会按“无法确认即跳过”的原则停止本轮同步，不会修改底层会话数据。
