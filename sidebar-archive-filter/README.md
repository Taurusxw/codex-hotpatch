# Codex 归档任务侧栏过滤热补丁

当前版本：**0.2.2**

此组件修复 Codex Desktop 启动后“已归档任务重新出现在活动侧栏”以及幽灵任务悬浮卡显示“56 年”的问题。Node 注入端以 SQLite 只读模式从 `state_5.sqlite` 加载本地线程清单、归档 ID 和毫秒时间作为冷启动种子，renderer 再累计自身归档 API 的增量批次并补齐内存排除集合；对于数据库中不存在、以 UUID 为标题、`recencyAt=0` 且已超过创建缓冲期的孤儿本地摘要，也只在 renderer 内存中排除。不会取消归档、删除任务，也不会写 Codex SQLite、JSONL、任务正文或 `app.asar`。

## 使用

```powershell
& '.\sidebar-archive-filter\manage-hotpatch.ps1' -Mode Status
& '.\sidebar-archive-filter\manage-hotpatch.ps1' -Mode Install
& '.\sidebar-archive-filter\manage-hotpatch.ps1' -Mode RunOnce
& '.\sidebar-archive-filter\manage-hotpatch.ps1' -Mode Uninstall
```

`Install` 会创建独立的用户级隐藏启动项，并立即尝试修复当前 Codex renderer；不需要重启设备，也不会主动重启 Codex。Codex 必须由已开启本地 DevTools 的入口运行，守护进程才能在后续启动时重新接管。

正常状态应显示：

- `VerificationState : local-archive-seed-applied`
- `ArchiveSeedLoadedPages` 与 `PatchedPages` 相等，`ArchiveSeedError` 为空
- `SeededArchivedThreads` 表示 SQLite 只读冷启动种子，`ApiObservedArchivedThreads` 表示 renderer API 的本轮累计观察
- `KnownLocalThreads` 表示 SQLite 中全部本地线程的只读清单；`OrphanPlaceholderThreads` 与 `SuppressedOrphanPlaceholderThreads` 应相等
- `ObservedArchivedThreads` 与 `SuppressedObservedArchivedThreads` 相等
- `LatestArchiveBatchThreads` 仅表示最近一次局部返回，不能当作归档总数
- `RendererError` 和 `StatusError` 为空

如果只读数据库暂时不可用，补丁会降级到原有 renderer API 路径，此时 `VerificationState` 为 `archive-coverage-unverified`，具体原因记录在 `ArchiveSeedError`，不会阻止 Codex 启动。

## 实现与回退边界

- Node 端只以 `DatabaseSync(..., { readOnly: true })` 加 `PRAGMA query_only = ON` 查询 `threads.archived = 1`；数据库内容、归档位和任务正文均不写入。缺少新时间列时会安全回退到秒字段并仅在内存中换算为毫秒。
- renderer 仍只调用现有的 `listArchivedThreads`、`getSuppressedArchivedConversationIds`、`suppressArchivedConversation` 与事件监听接口。当前桌面版的 `listArchivedThreads` 可能连续返回 `9 → 0 → 1` 一类局部/增量批次，因此任何单批相等都不再被解释为全量健康。
- 首次同步、归档/取消归档事件、窗口重新聚焦以及约 30 秒低频自愈都会重新核对；成功批次只增量合并，空批不会清除已观察 ID 或补丁所有权，查询失败时也保留已有排除状态。
- 只对 SQLite 已证明为归档的线程修正 renderer 内存摘要中为 `0` 或误用秒值的 `createdAt`、`updatedAt`、`recencyAt`。这会修复 Unix 纪元导致的“56 年”，不会改正常活动线程或持久数据。
- 取消归档或删除事件会立即释放本补丁拥有的 suppression，并建立本 renderer 生命周期内的排除标记；即使 API 随后返回过期批次，也不会把该线程误压回去。再次归档事件会正常解除该标记。
- `Uninstall` 只撤回本组件补入的内存排除项并停止独立 watcher；原本由 Codex 管理的排除项保持不变。
- `0.2.0` 新增 SQLite 只读冷启动种子与归档摘要时间修复；已有 suppression 的历史所有权仍不会从排除集合反推，回退只覆盖本实例实际补入项。
- `0.2.1` 排除新版 renderer 遗留的孤儿 `local:<UUID>` 占位摘要：必须同时满足 SQLite 无记录、UUID 占位标题、`recencyAt=0`、超过五分钟缓冲期且不是活动/当前任务；仍只修改 renderer 内存并可回退。
- `0.2.2` watcher 每轮核验 renderer 中的实际装载状态；即使 DevTools target ID 在页面重载后保持不变，也会重新注入。未完成的注入不会被缓存，诊断会记录状态或安装失败原因。
- 此补丁依赖未公开的 renderer 对象结构。Codex 更新若改变线程管理器契约，状态会停在 `waiting-for-manager` 或 `reconciliation-error`，此时应先做兼容检查，不要操作任务数据。

## 测试

```powershell
node --test `
  '.\sidebar-archive-filter\archived-thread-index.test.mjs' `
  '.\sidebar-archive-filter\sidebar-archive-filter-renderer.test.mjs'
```
