# Codex 热补丁

本项目集中维护三个彼此独立的用户级 Codex 运行时补丁。界面补丁只连接 Codex 已开启的本地 DevTools 端口；网络补丁在显式 VPN 与 VPN 原生 HTTPS/SSE 之间采用持久熔断、运行期监测和版本兼容门禁。它们都不修改、替换或重打包 `app.asar`。

当前公开发行版：**v1.0.0**。这是非官方社区项目，与 OpenAI 无隶属关系；补丁依赖 Codex Desktop 的运行时结构，升级后应先执行状态与针对性测试。

## 组件

| 目录 | 当前版本 | 用途 |
|---|---:|---|
| `reasoning-labels/` | 1.0.9 | 将六档推理强度显示为带序号和英文原名的中文标签，并在 Codex 更新、进程或端口变化后自动重接管。 |
| `subagent-status/` | 1.3.12 | 每次启动从完成证据重建子智能体状态，按代理对象结构兼容新旧 renderer 属性并同步折叠摘要，修复重启后已完成项重新显示“处理中”，同时监督注入自愈；面板关闭时不再重复执行完整状态投影，并保留缺少新版 tab ID 的旧界面探测。 |
| `network-proxy/` | 1.9.0 | 启动时验证显式 VPN + HTTPS/SSE；守护按核心启动边界区分实际路径，显式长流故障立即切回原生，原生路径仅在 10 分钟内跨 3 个任务退化后才五次验证备用显式路径，避免单次抖动与线路翻转；桌面主版本门禁和独立入口提供官方兼容兜底。 |

三个组件分别安装、运行和回退；合并项目不改变其用户级安装目录、启动项或运行边界。
两个 injector 共用 `shared/codex-devtools-transport.mjs`，统一本地 DevTools 的主机回退、目标发现、WebSocket 生命周期、超时和逐页面错误收集；两个管理脚本共用 `shared/codex-hotpatch-lifecycle.psm1`，统一版本读取、注入调用、helper 进程启停，并按当前 Codex 进程、动态 DevTools 端口和 renderer 目标进行版本无关的自动识别、自愈。

## 管理命令

```powershell
# 克隆后进入仓库根目录
git clone https://github.com/Taurusxw/codex-hotpatch.git
Set-Location '.\codex-hotpatch'

# 推理强度标签
& '.\reasoning-labels\manage-hotpatch.ps1' -Mode Status
& '.\reasoning-labels\manage-hotpatch.ps1' -Mode Install
& '.\reasoning-labels\manage-hotpatch.ps1' -Mode Uninstall

# 子智能体状态
& '.\subagent-status\manage-hotpatch.ps1' -Mode Status
& '.\subagent-status\manage-hotpatch.ps1' -Mode Install
& '.\subagent-status\manage-hotpatch.ps1' -Mode Uninstall

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
- 网络补丁只接管 Codex 专属 `.codex/.env` 中四个代理键、新 Codex 进程环境，以及 `.codex/config.toml` 中一个带标记的 `model_provider` 选择器和独立 HTTPS-only provider；原值可原子恢复。`NO_PROXY` 仅覆盖 loopback，不得写入 Windows 用户级或系统级永久代理环境。
- Codex 更新后先运行三个组件的 `Status`、相应语法/测试检查和实际验收，再决定是否需要兼容修改。

## 开源与安全

本项目采用 [MIT License](LICENSE)。贡献前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)；敏感漏洞请按 [SECURITY.md](SECURITY.md) 私下报告。不要在 issue、测试夹具或日志中提交 Codex 登录态、代理凭据、会话内容或本机路径。
