# Codex 热补丁

本项目集中维护四个彼此独立的用户级 Codex 运行时补丁。界面补丁只连接 Codex 已开启的本地 DevTools 端口；界面总监督负责 watcher 进程自恢复；网络补丁在显式 VPN 与 VPN 原生 HTTPS/SSE 之间采用持久熔断、运行期监测和版本兼容门禁。它们都不修改、替换或重打包 `app.asar`。

当前项目版本：**v1.2.0**；[发行说明](docs/progress/releases/v1.2.0/RELEASE_NOTES.md)。这是非官方社区项目，与 OpenAI 无隶属关系；补丁依赖 Codex Desktop 的运行时结构，升级后应先执行状态与针对性测试。

## 组件

| 目录 | 当前版本 | 用途 |
|---|---:|---|
| `subagent-status/` | 1.3.22 | 从活动、归档会话与只含线程 UUID 的持久缓存重建完成证据；新版 renderer 不再暴露条目 ID 时，只读使用 `state_5.sqlite` 的父子线程和 `agent_path` 元数据做唯一映射，完成判断仍只信任 rollout 生命周期。隐藏启动项由 Explorer 外壳托管并等待 watcher 稳定就绪；文件监听先规范化 Windows 短路径，避免 Node 原生断言崩溃。 |
| `sidebar-archive-filter/` | 0.2.2 | 从 `state_5.sqlite` 只读加载本地线程与归档冷启动种子，再累计 renderer API 的局部批次；同时排除数据库中不存在且超过缓冲期的 UUID 孤儿摘要，修复幽灵行和“56 年”误显；每轮核验 renderer 状态并处理 target ID 不变的页面重载；不取消归档、不删除或改写任务。 |
| `ui-hotpatch-supervisor/` | 1.0.3 | 持续监督两个已安装界面 watcher；缺失时清理孤儿 injector、隐藏拉起并指数退避，同时在 Codex 运行时只读报告 renderer 实际装载状态，避免“进程正常即健康”的误报。 |
| `network-proxy/` | 1.14.21 | 分别持久停用显式代理与传输配置接管；停用后不再改写用户选择的 provider。保留旧任务 provider 定义、运行时缓存更新修复和只读故障观察；不热切换正在运行的任务。 |

四个组件分别安装、运行和回退；合并项目不改变其用户级安装目录、启动项或运行边界。
两个界面 injector 共用 `shared/codex-devtools-transport.mjs`，统一本地 DevTools 的主机回退、目标发现、WebSocket 生命周期、超时和逐页面错误收集；两个界面管理脚本共用 `shared/codex-hotpatch-lifecycle.psm1`，统一版本读取、注入调用、helper 进程启停，并按当前 Codex 进程、动态 DevTools 端口和 renderer 目标进行版本无关的自动识别、自愈。

## 管理命令

```powershell
# 克隆后进入仓库根目录
git clone https://github.com/Taurusxw/codex-hotpatch.git
Set-Location '.\codex-hotpatch'

# 子智能体状态
& '.\subagent-status\manage-hotpatch.ps1' -Mode Status
& '.\subagent-status\manage-hotpatch.ps1' -Mode Install
& '.\subagent-status\manage-hotpatch.ps1' -Mode Uninstall

# 归档任务侧栏过滤
& '.\sidebar-archive-filter\manage-hotpatch.ps1' -Mode Status
& '.\sidebar-archive-filter\manage-hotpatch.ps1' -Mode Install
& '.\sidebar-archive-filter\manage-hotpatch.ps1' -Mode Uninstall

# 界面热补丁 watcher 自恢复总监督
& '.\ui-hotpatch-supervisor\manage-hotpatch.ps1' -Mode Status
& '.\ui-hotpatch-supervisor\manage-hotpatch.ps1' -Mode Install
& '.\ui-hotpatch-supervisor\manage-hotpatch.ps1' -Mode Uninstall

# 网络代理与 WebSocket 启动优化
& '.\network-proxy\manage-hotpatch.ps1' -Mode Status
& '.\network-proxy\manage-hotpatch.ps1' -Mode Install
& '.\network-proxy\manage-hotpatch.ps1' -Mode SyncEnv
& '.\network-proxy\manage-hotpatch.ps1' -Mode Doctor
& '.\network-proxy\manage-hotpatch.ps1' -Mode Uninstall
```

## 维护边界

- 本地交接、环境文件、日志、数据库和安装副本均不进入 Git；公开仓库只包含可审计源码、测试和文档。
- 兼容修复必须保持最小化；不修改 Codex 安装目录、会话数据或 `app.asar`。
- 网络补丁只接管 Codex 专属 `.codex/.env` 中四个代理键、新 Codex 进程的网络环境，以及 `.codex/config.toml` 中一个带标记的 `model_provider` 选择器和独立 HTTPS-only provider。它不再持久接管 `CODEX_CLI_PATH`；升级时清除已确认落后于当前 Appx 官方核心的旧补丁恢复值或标准 OpenAI npm CLI，补丁启动入口也在桌面子进程中忽略继承覆盖。`NO_PROXY` 仅覆盖 loopback，代理键不得写入 Windows 用户级或系统级永久环境。
- Codex 更新后先运行四个组件的 `Status`、相应语法/测试检查和实际验收，再决定是否需要兼容修改。

## 开源与安全

本项目采用 [MIT License](LICENSE)。贡献前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)；敏感漏洞请按 [SECURITY.md](SECURITY.md) 私下报告。不要在 issue、测试夹具或日志中提交 Codex 登录态、代理凭据、会话内容或本机路径。
