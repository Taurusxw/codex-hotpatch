# Codex VPN 网络补丁

当前版本：1.9.0

该组件面向“必须开启 VPN 才能稳定连接 Codex”的 Windows 环境。它不再把一次 WebSocket `101` 当成长期稳定，也不把无 VPN 的裸直连当成主要回退；每次安装、同步、诊断或专用入口启动前，会在当前 VPN 下按需检查并选择两条 HTTPS/SSE 路径：

1. `VpnExplicitHttps`：自动读取 WinINET/365VPN 当前本地端口，为 Codex 写入显式代理环境。
2. `VpnNativeHttps`：移除补丁托管的代理键，让当前 VPN 的系统/TUN 路径承载 Codex。

补丁在 `~/.codex/config.toml` 中以可回退托管块选择独立的 `codex-hotpatch-http` provider。该 provider 继续使用 ChatGPT 登录态和 Codex 官方端点，但设置 `supports_websockets = false`，直接使用 HTTPS/SSE，避开已知的 `websocket closed by server before response.completed` 重连路径；同时把请求重试和 SSE 重连预算分别提高到 6 和 8。首次或正常启动要求显式代理连续采样 3 次；显式路径失败后才采样 VPN 原生路径 2 次，避免每次启动无意义地重复测试后备路由。

1.8.0 把运行期保护改成用户会话级单实例守护：它通过 Windows 自带 `winsqlite3.dll` 以只读方式增量读取 `~/.codex/logs_2.sqlite`，只接受“当前桌面 `codex.exe` + 托管 provider 的 8 次 SSE 重试预算 + 非 WebSocket”的错误。`error decoding response body`、请求发送失败、TLS EOF 或请求超时任一真实长流故障都会立即熔断，不再被下一次短 doctor 成功清零；`.env` 会原子切为 VPN 原生 HTTPS/SSE。首次长流故障隔离显式代理 24 小时，七天内复发按 24h、48h、96h 递增，最高 7 天；短探测故障仍保持 10 分钟内两次失败、30 分钟冷却的较轻策略。

1.9.0 补齐了反向监测：守护器会按每个桌面核心的启动时间，把错误归属到它实际继承的显式或原生环境，而不是拿随后变化的 `.env` 猜测。VPN 原生路径的单个任务重连仍交给 Codex 自愈；只有 10 分钟内至少 3 个不同任务发生受控 HTTPS/SSE 断流，才判定为实质性退化。达到阈值后，显式备用路径必须连续 5 次探测通过才会为新进程提前恢复，并且同一组核心只尝试一次，避免单次抖动和两条线路来回翻转；备用路径未通过时继续保留仍可重试的原生路径。

新版还修正 doctor 的误判：`network.provider_reachability` 检查的 `/backend-api/` 根地址超时时，会再对真正的 `/backend-api/codex/responses` 做一次无凭据 GET；HTTP 2xx-4xx（本机当前为 405）只表示 TLS、代理和目标路径已连通，不发送模型请求或登录令牌。这样不会因非关键根地址超时，把实际可工作的 Responses 传输错误标成离线。

守护器有独立登录自启入口，不再随某个根 `ChatGPT.exe` 退出，因此从 Codex++、原始图标或优化入口重启后都会重新识别当前桌面核心。日志游标持久化并原子更新，重启不会重复统计历史错误；启动时的有界近期扫描只用于判断当前活动核心是否已跨任务退化，不推进游标，也不会重放旧进程。环境变量仍无法热切换到已经运行的核心进程，因此换路不会强制结束当前任务：当前重试仍由 Codex 自身完成，完整退出并重启一次后才会采用已准备的新路径。

## 本机 A/B 实测

2026-08-16 使用同一 VPN、同一 `gpt-5.6-luna`、`--ephemeral` 且不落会话文件。四个 HTTPS/SSE 候选各交叉运行 3 次，偶数轮反转顺序：

| 路径 | 成功 | 中位耗时 | P95 | 传输错误信号 | 结论 |
|---|---:|---:|---:|---:|---|
| 显式 VPN + HTTPS/SSE + 完整代理变量 | 3/3 | 5.54 s | 5.66 s | 0 | 最快且稳定，选为主路 |
| 显式 VPN + HTTPS/SSE，不设 `ALL_PROXY` | 3/3 | 10.12 s | 14.65 s | 2 | 淘汰 |
| VPN 原生 + HTTPS/SSE | 3/3 | 9.53 s | 13.96 s | 0 | 主路故障时接管 |
| VPN 原生 + HTTPS/SSE + 实验性系统代理 | 3/3 | 12.87 s | 19.05 s | 0 | 淘汰 |

WebSocket 基线再次复现：显式 VPN 为 6.44 秒、零重连；VPN 原生为 115.55 秒、11 次重连和 10 个传输错误，与此前 118.21 秒/11 次重连的独立样本一致。再以“派生一个子代理并等待完成”各运行 2 次：显式 HTTPS/SSE 两次均完成、耗时中位数 22.75 秒且零错误；VPN 原生虽完成且中位数 21.85 秒，但两次各出现 1 个传输错误。因此生产选择按“完整成功与零错误优先，其次比较中位耗时”确定，不追逐偶然的单次快值。

同日对 `26.810.7004.0` 的长会话复核补充了启动基准未覆盖的故障：显式本地代理监听和大量现有连接仍在，但约 22 分钟内跨多个任务出现 20 次请求发送失败和 3 次响应体解码失败；相同 VPN 下临时绕过显式代理后，HTTPS/SSE provider 在 1373 ms 内通过。由此不再把一次启动成功视为整段会话永久健康：显式路径仍可在健康时作为低延迟主路，但运行期证据可以打开熔断器并持久切换后续进程。

可用 `benchmark-hotpatch.ps1` 重跑同样的临时基准。脚本每轮只临时切换 Codex 专属 `.env`，在 `finally` 中恢复原始内容并校验 SHA-256；子代理负载只有实际观察到派生证据才计为成功样本。测速代表当时网络，不能保证外部线路永远保持同一延迟。

## 使用

```powershell
# 从仓库根目录运行
Set-Location '<repo-root>'
& '.\network-proxy\manage-hotpatch.ps1' -Mode Install
& '.\network-proxy\manage-hotpatch.ps1' -Mode Status
& '.\network-proxy\manage-hotpatch.ps1' -Mode SyncEnv
& '.\network-proxy\manage-hotpatch.ps1' -Mode Doctor
& '.\network-proxy\manage-hotpatch.ps1' -Mode Uninstall
```

`Install` 会以可回滚事务安装管理器、健康模块、只读运行日志观察器、持续守护器和 HTTPS-only provider，同步当前可用路径，并创建“Codex（代理优化）”“Codex（官方兼容兜底）”和登录自启守护三个入口。优化入口每次启动动态识别当前 Appx 版本，并让当前 PATH CLI 解析托管配置。当前已实测桌面版为 `26.810.7004.0`：同一主版本的后续构建继续自动识别和预检；若无法识别桌面版本、桌面主版本变化，或 CLI 不再接受该 provider，会在启动进程前原子移除托管块、恢复原 `model_provider`，并同时强制移除显式代理环境，以官方 provider + VPN 原生网络继续启动。这一主版本门禁避免桌面核心已更新、外部 CLI 尚未同步时出现假兼容。兜底入口不加载自定义 provider，直接移除本补丁的 provider 与代理托管块，以“VPN 开启、无热补丁”的已知可连接状态启动动态识别到的当前 Appx 版本。

`SyncEnv` 适用于 365VPN 端口或路由变化；`Doctor` 输出所选 `NetworkMode`、实际采样路径的中位耗时、熔断状态和网络检查。`Status` 还会显示当前核心实际路径、原生路径 10 分钟跨任务故障数、退化阈值、准备路径是否需要重启、冷却时间和监测器状态。完整退出 Codex 后从相应入口重新启动，才能保证新的 `.env`、provider 和进程环境全部生效；补丁不会自动结束正在运行的任务。

## 写入与回退边界

- `.codex/.env`：仅接管 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY`、`NO_PROXY` 和带标记托管块；保留其他内容，异常或重复标记时 fail-closed。
- `.codex/config.toml`：仅接管一个带标记的顶层 `model_provider` 选择器和 `[model_providers.codex-hotpatch-http]`。原 `model_provider` 行以可逆元数据保存在托管块内；安装和移除后均调用当前 Codex 解析配置，失败则原子恢复。
- 安装目录中的 `network-health.json` 只保存熔断状态，`network-runtime-cursor.json` 只保存最后已观察的日志行号，`network-watchdog.log` 只保存有界运行诊断；状态更新使用进程间互斥和原子替换。`logs_2.sqlite` 始终以只读标志打开。
- `Uninstall` 会停止持续守护器，移除上述两个托管块、恢复原 `model_provider` 并删除两个开始菜单快捷方式和登录自启入口；不修改 Windows 用户级/系统级永久代理环境、Codex 安装目录、会话数据库或 `app.asar`。
- `NO_PROXY=localhost,127.0.0.1,::1` 保护本地 DevTools；动态 VPN 端口无需重装，下一次 `SyncEnv` 或专用启动会重新识别。

## 已知边界

OpenAI 官方仓库仍有未关闭的 WebSocket/流恢复问题，例如 [#24533](https://github.com/openai/codex/issues/24533)、[#30933](https://github.com/openai/codex/issues/30933) 和 [#36059](https://github.com/openai/codex/issues/36059)。本补丁通过 HTTPS/SSE 避开已复现的 WebSocket 路径，并用真实长流错误驱动显式 VPN 熔断，但无法承诺外部 VPN 节点、运营商或服务端始终无波动，也不能把已运行进程热切换到另一组环境变量。它能保证的是：任意入口启动的桌面核心都能被持续守护重新识别；不兼容大版本恢复官方 provider；真实 HTTP/SSE 截断不会被短探测掩盖或在重启后丢失；下一次完整重启使用 VPN 原生环境；另保留完全移除托管配置的独立兜底入口。
