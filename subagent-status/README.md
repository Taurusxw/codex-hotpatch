# Codex 子智能体状态同步热补丁

这是一个独立于 Codex 安装目录的用户级运行时补丁，用于修复“子智能体已经完成，但侧栏仍显示处理中”的显示状态滞留。当前版本为 **1.3.22**。

1.3.22 在建立文件监听前将 Windows 8.3 短路径解析为真实路径，避免 Node/libuv 的目录名断言导致进程崩溃；PowerShell 源文件统一使用 UTF-8 BOM，兼容 Windows PowerShell 5.1。

## 工作方式

- 只连接 Codex 自身已开启的本地 DevTools 端口。
- `Status` 会区分“文件已配置”和“当前 renderer 已接管”；若 Codex 从官方 `ChatGPT` 入口启动且没有本地 DevTools，会明确报告 `RuntimeReady=False` 和 `LaunchMode=OfficialEntryNoDevTools`，不再把它误报为“Codex 未运行”或静默假成功。
- 不使用全页面 `MutationObserver`；空闲时只有事件监听器和一个每秒仅查询面板标识的轻量探针，不遍历子智能体列表。
- 只读索引 `~/.codex/sessions` 与 `~/.codex/archived_sessions` 中每个子智能体自身 JSONL 的尾部，不改写会话；明确的 `task_complete` 会原子写入补丁自己的 `completion-evidence-cache.json`。缓存内容只有线程 UUID，不含标题、正文或会话路径；Codex 后续清理归档临时 JSONL 时，已确认完成证据仍会保留。
- 若同一线程同时存在活动与归档/缓存证据，活动目录优先；活动副本最新事件为 `task_started`、未知或不完整时会撤销缓存资格。缓存损坏或不可读时安全降级为空，不据此投影任何完成状态。
- Codex `26.818.5229.0` 的 `state_5.sqlite/thread_spawn_edges.status` 仍可能让已完成子智能体长期停在 `open`。补丁只以 SQLite 只读模式取得 `parent_thread_id`、`child_thread_id` 和 `agent_path`，把新版侧栏显示名唯一映射回线程 UUID；它绝不把该表的 `open` 当成运行证据，完成与重新开始仍只由 rollout 最新生命周期判定。
- Codex 每次启动后都会从活动会话、仍存在的归档文件和补丁持久缓存合并重建状态，并在侧栏打开前把已验证条目的 React 状态投影为 `done`；因此不再依赖上一次 renderer 的临时内存，也不会因归档文件被自动清理而重新显示为处理中。
- renderer 适配器不再绑定单一 `subagents` 属性名，而是在子智能体控件的 React 近邻中按 `conversationId`、`parentConversationId` 和 `status` 结构识别代理数组；受限深度扫描同时覆盖直接属性和 `children.props.backgroundAgents` 等嵌套 React 元素，兼容无 `aria-label` 的当前摘要按钮及后续等价改名。
- 折叠摘要会与同一份完成证据同步：已完成项从“运行中”计数中移除；“运行中”和“完成”两个文本节点成对更新，避免短暂出现重复的完成计数。
- 线程切换后的可信用户交互会触发一次延迟重投影；每秒轻量探针只判断子智能体面板是否首次出现，不再在面板保持打开时重复遍历 React 代理数组。
- 优先从当前侧栏按钮的 React 数据提取精确 `conversationId`，再沿 `parentConversationId` 父链确认它属于当前任务的直接或多级后代；新界面不再暴露 ID 时，使用只读 spawn 元数据将当前父任务下的 `agent_path` 末段与显示名称做规范化唯一匹配。重复、模糊、跨父任务或没有 rollout 完成证据的名称仍跳过。
- 用户打开“子智能体”侧栏、补丁注入时侧栏已经打开，或当前侧栏中的子智能体刚产生完成证据时，都会启动同步，不再依赖一次容易错过的按钮点击。
- 最新事件为 `task_started` 的正在运行或重新连接子智能体一律跳过；记录正在写入、JSON 不完整、身份无法确认或证据未知时也一律跳过。
- 会话文件一发生变化，就先撤销该子智能体的完成资格；等待写入稳定并重新确认最新事件后，才可能恢复资格。
- 超大列表按低优先级小批次续跑，直到已展开范围处理完；每批之间让出渲染时间，用户一交互就取消后续批次。
- 打开面板后立即进入迁移等待；每个条目之间短暂让出渲染时间并限速。用户点击、按键、切换页面、关闭面板或出现模态对话框时会立即中止本轮处理。
- 用户点击、按键或切换窗口导致迁移中止后，面板仍可见时会在 2 秒空闲后自动续跑；无需再次关闭、重开面板。状态诊断同时报告真实可见的“已开启/完成”计数，不再把仅修改 React 对象但尚未渲染的候选数当作完成验收。
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

当前用户的隐藏启动项名称为 `CodexSubagentStatusHotpatch.lnk`。安装时由 Explorer 外壳立即启动，避免守护进程继承短生命周期安装命令的进程作业；管理器会先等待旧 watcher/injector 完全退出和互斥锁释放，再确认新 watcher 稳定存活，连续快速安装也不会留下“文件已更新但监督进程未接管”的假成功。登录后仍由 Windows“启动”目录自动运行，全程不显示控制台窗口。Codex 更新或重启后，共享生命周期模块会按当前进程、动态调试端口与 `app://-/index.html` renderer 自动识别 Codex，并监督 injector 重启与定期自愈；不依赖 Microsoft Store 包版本号或固定安装路径。运行中的 Electron 无法事后补加 DevTools 参数，因此必须在完全退出 Codex 后通过开始菜单的“Codex（代理优化）”启动；若误用官方 `ChatGPT` 入口，watcher 会继续等待下一次正确启动，`Status` 会明确显示当前会话尚未接管。补丁会探测注入时已经打开的“子智能体”侧栏，也会在完成证据或只读映射更新时触发同步，无需再次关闭重开面板。若界面结构或 SQLite 元数据表在未来版本发生变化，补丁会报告映射错误并按“无法确认即跳过”的原则停止本轮同步，不会修改底层数据库或会话数据。
