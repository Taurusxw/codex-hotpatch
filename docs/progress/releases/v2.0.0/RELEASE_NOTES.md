# codex-hotpatch v2.0.0

发布日期：2026-09-27。此版本将项目收敛为 Windows Codex Desktop 运行时更新修复，移除旧 UI 和网络管理入口，因此采用新的主版本号。

## 变更

- 独立组件 **runtime-repair 1.0.0** 保留官方 CLI 四个同包文件、完整 Node/CUA 依赖树和 ripgrep 的缓存校验与原子补齐。匹配文件及旧官方缓存保持原样。
- 保留 Appx Stage 预热及注册版本变化后的修复。隐藏守护每 45 秒检查更新，空闲时不重复扫描整个缓存；准备失败可在后续轮询重试。
- 管理入口收敛为 `Status`、`Install`、`Repair`、`Disable`，与网络、模型和登录状态无关。
- 移除子智能体状态、侧栏归档过滤、UI 总监督、共用 DevTools 层及旧网络模块，包括网络探测、自动传输切换和代理启动器。
- 当前源码树仅保留有效组件与本版发行文档；历史源码和发行记录仍可通过原 Git 标签获取。

## 安装与迁移

在 Windows PowerShell 5.1 中，从解压后的源码根目录运行：

```powershell
& '.\runtime-repair\manage-hotpatch.ps1' -Mode Install
& '.\runtime-repair\manage-hotpatch.ps1' -Mode Status
```

安装器只部署新组件，不会自动删除已有旧补丁。已有用户应先保存旧文件与配置，停止旧补丁所属守护并移除旧启动项，再清理不再使用的组件。不要终止 Codex 或其他更新工具。不要为了清理旧模块而调用会改写代理或 provider 的旧网络卸载流程。

保留当前可用的 `.codex/.env` 代理值和 `config.toml` 模型/provider 设置；旧任务可能仍引用历史 provider ID。新组件不接管这些配置，也不恢复显式代理或切换节点。

`Disable` 停止新守护并移除其启动项，保留脚本、日志和官方运行时缓存。需要恢复历史组件时，从旧 Git 标签取得代码并使用私有备份恢复对应状态；不可用旧默认配置覆盖现有配置。

## 验证与限制

本机已移除旧组件并部署新守护，注册版本为 Codex Desktop **26.924.2738.0**；CLI、Node、ripgrep 校验通过且本次无需改写。PowerShell 5.1 与 7 的三组测试通过，详见 [ACCEPTANCE.md](ACCEPTANCE.md)。

本组件不修复服务端或网络链路引起的对话断流。它依赖官方 Windows x64 Appx 布局及运行时哈希规则；未来布局变化需重新核对。Stage 日志不可用时无法提前预热，仍处理注册版本变化。本次没有通过强制重启或真实下一次产品升级来验证冷更新。
