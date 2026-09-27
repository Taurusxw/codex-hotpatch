# Codex 运行时修复

本项目现仅维护 Windows Codex Desktop 的运行时更新修复。组件从旧网络补丁中独立出来，准备官方 CLI、完整 Node/CUA 和 ripgrep 缓存，以缓解更新后文件发布失败导致的启动报错。

当前项目版本 **v2.0.0**，仅包含 [runtime-repair 1.0.0](runtime-repair/README.md)。安装迁移说明见 [v2.0.0 发行说明](docs/progress/releases/v2.0.0/RELEASE_NOTES.md)。当前工作树仅保留有效组件和最新发行文档；旧源码及发行记录可从历史 Git 标签获取。

## 当前范围

| 保留 | 行为 |
|---|---|
| 当前版本修复 | 按官方内容哈希准备 CLI、Node/CUA、ripgrep；匹配文件保持原样，损坏或缺失文件原子补齐 |
| 更新预热 | 从已完成的 Appx Stage 事件识别新版，在桌面应用重启前准备运行时 |
| 轻量守护 | 每 45 秒检查更新；仅首次运行或版本变化时完整校验；失败下轮重试 |

已移除子智能体状态注入、归档侧栏过滤、UI 总监督、DevTools 共用层、网络探测与自动切换，以及旧代理启动器。现有 `.codex/.env` 静态代理值和 `config.toml` provider 定义由用户管理，不属于运行时修复组件。旧任务可能仍引用历史 provider ID，不能据名称将它们删除。

## 使用

在 Windows PowerShell 5.1 中从仓库根目录运行：

```powershell
& '.\runtime-repair\manage-hotpatch.ps1' -Mode Status
& '.\runtime-repair\manage-hotpatch.ps1' -Mode Install
& '.\runtime-repair\manage-hotpatch.ps1' -Mode Repair
& '.\runtime-repair\manage-hotpatch.ps1' -Mode Disable
```

`Install` 安装当前用户的隐藏守护和启动项；`Repair` 手动复核当前运行时；`Disable` 停止守护并移除启动项，保留脚本与缓存。细节、状态含义和兼容边界见[组件说明](runtime-repair/README.md)。

## 维护边界

- 不修改 Codex 安装目录或 `app.asar`，不改写会话、数据库、模型或代理配置，不重启 Codex。
- 不删除旧官方缓存；正在使用且内容正确的执行文件不会被替换。
- 依赖 Windows x64 官方 Appx 布局和运行时哈希规则；新版布局变化需要针对性核对。
- 运行时文件修复不解决服务端或网络链路造成的对话断流。
- 本地交接、恢复备份、环境文件、日志和安装副本不提交 Git。

这是非官方社区项目，与 OpenAI 无隶属关系，采用 [MIT License](LICENSE)。贡献与测试见 [CONTRIBUTING.md](CONTRIBUTING.md)，敏感漏洞按 [SECURITY.md](SECURITY.md) 报告。
