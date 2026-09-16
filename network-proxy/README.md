# Codex VPN 网络补丁

当前版本：1.14.21

1.14.21 修正停用语义：存在 `https-only.disabled` 时，守护、安装和启动不再写传输配置，也不启动 CLI 解析探测；不会把用户手动选择的 provider 再改回历史默认值。守护记录 `mode=user_managed`，运行时更新修复和显式代理停用设置保留。固定线路上已复现 WebSocket 连接超时而 HTTP 可完成，可通过独立的用户 HTTP provider 绕过该握手等待；这不是自动选路补丁，也不代表原有五分钟 HTTP 长流中断已经根治。旧任务 provider 不自动迁移。

1.14.20 增加 `https-only.disabled` 持久开关：该文件存在时，安装、启动、Doctor 和守护恢复安装前的默认 provider，不再自动重选 `codex-hotpatch-http`。`Status` 分别显示 `HttpsOnlyEnabled` 与 `ExplicitProxyEnabled`，两个选择互不替代。保留旧任务依赖的 HTTPS provider 定义、运行时缓存更新修复和显式代理停用设置；不修改任务数据库或重启正在运行的核心。旧任务若已绑定补丁 provider，不会因默认值恢复而自动迁移，故这只是撤除默认传输干预，不是长连接稳定性保证。当前机器恢复 `openai`；长任务仍需在下次正常重启后验证。

1.14.19 增加显式代理的持久停用设置：安装目录存在 `explicit-proxy.disabled` 时，启动、安装、同步与 Doctor 只选择 VPN 原生 HTTPS/SSE；守护不探测显式线路，冷却到期和原生退化均不自动恢复显式代理。`Status` 显示 `ExplicitProxyEnabled=False`。该设置独立于故障冷却记录，运行文件更新不会覆盖；本机按用户要求启用停用设置。VPN、Windows 系统代理、HTTPS-only provider 与 CLI/Node/rg 更新修复保持原样。不再拥有显式代理备用路径；原生线路故障仍由 Codex 重试，需要时人工处理 VPN。

1.14.18 修复移除旧 npm CLI 后 Doctor 仍通过 PATH 查找 `codex` 的遗漏，统一使用现有可信绝对路径解析器。Doctor 子进程隐藏运行，30 秒超时后只结束自身；工具不可用时仍保留 Responses 端点检查，并在 CLI 可用时允许既有登录态复核。诊断不可用不再单独累计线路熔断，未验证的健康状态报告 `unknown`；跳过显式线路时不再误称“两条路径均失败”。路线准备提示明确只影响新进程，保留既有运行期断流证据与冷却时间，不强制重启桌面。

同次审查在 Desktop `26.908.4834.0` 新进程日志中确认 `rg.exe` 也发生 `rename_staging EPERM`。启动、激活及版本变化守护现将文件搜索组件纳入同一原子修复流程，使用其独立的官方内容哈希目录，不改变 CLI 四件套的哈希。Node 在本次真实重启中已正常解析；另一个任务的 `os error 267` 对应已不存在的工作目录，不能用网络换路或重写运行时修复。

1.14.17 适配 Desktop `26.908.4834.0`：本次启动日志中 Node / node-repl 的 `cua_node` 也出现 `rename_staging EPERM`。沿用逐文件校验和原子发布，新增完整 CUA 运行时及依赖树检查；内容目录名使用官方 `manifest.json`、`bin/node.exe`、`bin/node_repl.exe` 三文件哈希，依赖先于入口发布。启动入口和版本变化守护同时准备 CLI 与 Node，保留现有独立 CLI、会话与其他版本目录。已运行桌面的缺失运行时状态可能需要完整重启才能重新解析；自动更新瞬间的检查竞态边界不变。

1.14.16 针对 Desktop `26.903.9818.0` 更新重启日志中重复出现的 `rename_staging EPERM`：启动/激活入口先按官方哈希算法校验并补齐 CLI、code-mode host、sandbox setup、command runner 四件套，直接逐文件原子发布到官方内容哈希目录，不再依赖整目录改名。匹配文件不重写，不删除其他版本或修改 Appx；已有独立 CLI 用户覆盖保持原策略。守护在启动及 Appx/用户覆盖变化后执行同一检查，失败保留待重试状态，45 秒后再试。原始图标和应用内更新重启不能被守护同步拦截，因此更新完成到守护检查之间仍有竞态窗口；不承诺所有未来版本零报错。

1.14.15 修复缺少端点日志时 `error decoding response body` 被归为未知传输的问题：仅在没有明确传输归属且没有 WebSocket 标记时，将这一 HTTP 响应体错误识别为 HTTP/SSE。近期窗口内，同一核心、同一任务的不同重试若跨越至少五分钟，也会触发既有的登录态备用线路验证；短时抖动、重复日志和未知传输不会触发此新增条件。备用线路验证通过后仍只为新进程准备路由，不强制结束当前任务。

1.14.14 适配 Codex Desktop `26.903.8094.0` 的配置迁移：新版可能只移除传输选择器的起始标记和原 provider 注释，却留下结束标记、所选 provider 与完整 provider 托管块。补丁仅在完整 provider 定义、当前选择和独立恢复状态三者一致时清理孤立标记并重建选择器；恢复状态缺失、用户已改选 provider、provider 内容变化或出现重复标记时继续 fail-closed。

1.14.13 补齐启动与恢复流程：CLI 验证找到第一个可运行的可信候选后立即返回，跳过其余版本探测；无法执行的精确匹配核心不再被误当可用。周期探测与启动使用同一登录态 HTTPS/SSE 复核，不要求 WebSocket 同时健康。熔断冷却到期后守护主动复检；原生线路已退化而备用验证未通过时，至少间隔两分钟再尝试，不再限制为每组核心只尝试一次。恢复只准备后续进程的线路，正在运行的核心仍需完整退出重启才能换路。

“官方兼容兜底”现在同时停用守护和登录自启，避免官方配置随后被守护重新接管；再次使用“代理优化”或安装时恢复守护。健康状态兼容 PowerShell 7 的 JSON 日期对象，保留精确时间；回滚测试隔离全部状态路径，新增启动分支与守护测试。`Status` 的 `ValidationCliSource`、`ValidationCliVersion` 和 `ValidationMatchesCurrentDesktop` 区分实际验证器与当前桌面核心；兜底 CLI 解析成功不代表新版 Appx 核心已通过精确兼容验证。

该组件面向“必须开启 VPN 才能稳定连接 Codex”的 Windows 环境。它不再把一次 WebSocket `101` 当成长期稳定，也不把无 VPN 的裸直连当成主要回退；每次安装、同步、诊断或专用入口启动前，会在当前 VPN 下按需检查并选择两条 HTTPS/SSE 路径：

1. `VpnExplicitHttps`：自动读取 WinINET/365VPN 当前本地端口，为 Codex 写入显式代理环境。
2. `VpnNativeHttps`：移除补丁托管的代理键，让当前 VPN 的系统/TUN 路径承载 Codex。

补丁在 `~/.codex/config.toml` 中以可回退托管块选择独立的 `codex-hotpatch-http` provider。该 provider 继续使用 ChatGPT 登录态和 Codex 官方端点，但设置 `supports_websockets = false`，直接使用 HTTPS/SSE，避开已知的 `websocket closed by server before response.completed` 重连路径；同时把请求重试和 SSE 重连预算分别提高到 6 和 8。首次或正常启动要求显式代理连续采样 3 次；显式路径失败后才采样 VPN 原生路径 2 次，避免每次启动无意义地重复测试后备路由。

1.14.12 适配 Codex Desktop `26.901.4073.0` 的更新启动竞态：更新程序已经拉起 Codex 时，“Codex（代理优化）”改为激活现有窗口，不再直接报“已在运行”并退出；若新版官方核心尚未写入内容哈希稳定目录，配置验证和登录态探测会按当前桌面子核心、可信 OpenAI npm CLI、上一稳定桌面核心的顺序临时兜底。任意自定义 CLI 仍不会被自动执行，完整退出后再次从优化入口启动仍是让新核心继承代理环境的边界。

1.14.11 按核心 PID、父进程和启动时间持久记录首次观察到的启动线路。补丁重装或换路后，仍在运行的旧核心不会再被重新归类；原生断流不会误记到显式线路，显式断流也不会误记到原生线路。

1.14.10 修复“线路其实能完成主回答，却被远程插件目录、Apps MCP、分析上报或模型目录刷新失败误判为主流断线”的探针缺陷：登录态强探针现在使用本地模型目录缓存、低延迟模型、零重试和最小功能集，只把 Responses 主流自身的重连/传输证据计入裁决。旁路服务波动不再错误熔断更快的显式线路，也不再让一次换路验证额外等待多轮无关请求。

1.14.9 适配 Codex Desktop `26.901.2854.0` 的配置迁移：新版应用可能保留 `codex-hotpatch-http` provider 定义和选择值，却剥离顶层选择器的注释标记，使旧版 Doctor、重装和卸载全部 fail-closed。补丁现在把原 `model_provider` 的最小恢复记录独立保存在安装目录，并由守护器同时监听 Appx 版本、配置和恢复状态变化；只有 provider 托管块、当前选择和独立恢复记录相互一致时才自动重建选择器。恢复证据缺失、状态损坏或用户另行选择 provider 时仍拒绝覆盖。该状态也纳入安装事务和卸载清理，更新后不再依赖 TOML 注释这一处恢复证据。

1.14.8 将 1.14.7 的登录态 HTTPS/SSE 裁决扩展到显式代理与 VPN 原生两条候选线路：任一路径出现“provider 和 WebSocket 正常、无凭据 Responses GET 超时”的被动假阴性时，都用当前 Appx 官方 CLI 对实际候选线路执行一次零重连真实请求；结果缓存两分钟，显式线路缓存同时绑定代理 URI，端口变化后必须重新验证。Doctor 现在展示实际选中线路的裁决结果，并把 Codex 自身的全项 Doctor 总状态单列，避免健康网络线路继承无关检查的 `fail`；空错误也会保留退出码、重连和传输错误摘要。VPN 原生运行期退化门槛由十分钟内跨 3 个任务降为 2 个任务；达到门槛后守护只会准备已验证可用的显式 HTTPS/SSE 线路，当前进程不被强制终止。

1.14.7 统一 Doctor、安装选择与运行期切换的原生线路裁决：当 provider 根路径和 WebSocket 能力检查正常、无凭据 Responses GET 却超时时，不再把实际可工作的 VPN 原生 SSE 误判为离线，而是使用当前 Appx 官方 CLI 发起一次有界、只读、登录态且要求零重连的真实 HTTPS/SSE 请求；成功结果在当前管理/守护进程内缓存两分钟。Doctor 会单独报告无凭据与登录态结果，自动切换门禁继续拒绝任何含重连或传输错误的探测。

1.14.6 修复高并发时的传输识别盲区：1.14.5 只向前关联 2,000 条运行日志，本机多个并发任务在 15 秒内可产生超过 10,000 条日志，导致已知 WebSocket 超时被误记为 `Unknown`，也可能使真正的 HTTPS/SSE 故障错过自动换路。新版按同一核心、同一 turn 和五分钟时间窗口关联端点记录，使用 Codex 日志库已有的 `(process_uuid, ts)` 索引；只读边界、动态重试预算和 WebSocket/HTTPS 隔离策略不变。

1.14.5 适配 Codex Desktop `26.831.1445.0` / `codex-cli 0.152.0` 的运行日志变化：官方 provider 的流重试预算为 5，而补丁 HTTPS-only provider 仍为 8。观察器不再把单一固定预算当作 provider 身份，而是从每条当前核心日志动态解析预算、重试进度和实际 `responses_websocket` / `responses_http` 传输；WebSocket 故障只作为旧任务仍绑定官方 provider 的漂移证据，不再误伤 HTTPS 线路熔断。VPN 原生 HTTPS/SSE 在单个任务耗尽全部重试时，不必再等待三个不同任务失败，守护会立即用既有强探测验证显式 HTTPS 备用线路；普通瞬时抖动仍按十分钟三个任务的门槛处理。

1.14.4 修复原生备用线路的假阴性门禁：部分 VPN 原生线路能够稳定完成带登录态的 Responses HTTPS/SSE 请求，但无凭据 `GET /backend-api/codex/responses` 会固定超时；旧守护因此在显式长流反复截断时仍记录 `native_unhealthy`，拒绝打开熔断。新版只在 doctor 的 HTTP 与 WebSocket 均健康、无凭据 Responses 探测却失败这一矛盾状态下，使用当前 Appx 对应的官方稳定 CLI 发起一次 45 秒有界、`--ephemeral`、只读且不落会话的最小登录态 HTTPS/SSE 请求；只有零重连、零传输错误并完整结束才允许切换，结果缓存 2 分钟以避免重复请求。基准脚本也固定使用当前桌面官方核心，不再误取 PATH 中的旧 npm CLI。

1.14.3 修复重复健康探测刷新 `LastSuccessUtc`、进而把仍走显式代理的活动核心误判为 VPN 原生线路的问题。熔断器已经关闭、失败计数为零且存在成功边界时，普通复检保持原边界；只有首次成功或从失败、熔断、损坏状态恢复时才写入新的成功时间，运行期断流因此仍能归属正确线路并触发对应切换策略。

1.14.2 修复安装命令退出后网络守护被桌面执行宿主连带回收的问题：管理器不再用普通子进程直接拉起守护，而是交给 Windows 进程服务创建脱离实例，并校验 PID、命令行和父进程边界。登录自启入口保持不变；安装、修复或 Codex 专用入口启动后的守护不再依赖发起命令继续存活。

1.14.1 修复 1.14.0 恢复出的旧用户 CLI 覆盖：当 `CODEX_CLI_PATH` 是旧补丁保存的原值或标准 OpenAI npm CLI，且可验证版本落后于当前 Appx 对应的官方内容哈希核心时，安装器会清除覆盖并广播环境变化；无法比较的版本、任意自定义路径及不落后的 CLI 都会保留。守护器持续监听“Appx 版本 + 用户覆盖”签名，Store 静默升级后会自动重算一次策略。Codex++ 的应用路径保持自动模式后，每次从管理工具重启都会重新枚举当前 Appx 最高版本，桌面进程再使用该版本自带的官方核心，不保存旧包路径或核心版本号。

1.14.0 淘汰已被当前 Codex Desktop 覆盖的两层 CLI 补丁：不再下载归档兼容 CLI，也不再复制 Appx 核心和辅助程序到自建稳定镜像。当前桌面已经把核心和 code-mode host 搬运到内容哈希稳定目录，启动入口会在桌面子进程中忽略继承的 `CODEX_CLI_PATH`，让官方发现逻辑接管；配置解析会按当前 Appx 源文件哈希定位对应的官方稳定副本，不会被 PATH 中的旧全局 CLI 误导。升级安装仅在用户级变量仍指向旧镜像时恢复接管前的原值，随后立即删除 `cli-compat` 和严格匹配旧同步器格式、可独占打开的事务备份；若旧 `desktop-cli` 正被当前 Codex 使用，守护器会等待活动文件解除占用后回收。测试夹具的 Python 解析也改为逐个验证解释器确实可启动并包含 `sqlite3`，不会停在 PATH 中已失效的入口。

1.13.0 为运行期熔断增加“备用线路先验健康门禁”：显式代理发生真实长流错误或周期探测失败时，守护器先在临时 `.env` 中验证 VPN 原生 Responses 路径，并在 `finally` 中精确恢复原路由；只有备用线路通过才允许打开熔断并为新进程准备切换。无代理探测明确禁用 `HttpWebRequest` 的系统代理，且 doctor 无论根地址结果如何都必须再通过真实 Responses 路径，避免把 WinINET 代理成功误报为 VPN 原生成功。若原生 DNS、TCP 或目标路径也已失效，则保留仍能重试的当前显式代理并记录 `failover_suppressed=native_unhealthy`，避免一次代理抖动把下次启动永久切到已知离线线路。

1.11.1 将登录自启的“Codex 网络自愈守护”改为隐藏 PowerShell 窗口，并把快捷方式设为最小化启动，避免电脑重启后留下持续可见的黑色控制台；守护逻辑、日志和网络切换行为不变。

1.9.1 修复 Codex 更新或兼容兜底后的旧任务加载回归：兜底入口与桌面主版本门禁现在只恢复原 `model_provider`，同时保留不被新任务选中的 `codex-hotpatch-http` 兼容定义，让历史任务中保存的 provider ID 仍可解析。安装器还能幂等接管内容完全一致、但缺少托管标记的临时兼容定义；若未来 Codex 连该定义本身也不接受，才原子移除并退回纯官方配置。

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

`Install` 会以可回滚事务安装管理器、健康模块、只读运行日志观察器、持续守护器和 HTTPS-only provider，同步当前可用网络路径，并创建“Codex（代理优化）”“Codex（官方兼容兜底）”和登录自启守护三个入口。当前已实测桌面版为 `26.901.2854.0`：同一主版本的后续构建继续自动识别和预检；若无法识别桌面版本、桌面主版本变化，或当前 Appx 核心不再接受该 provider 作为默认值，会在启动进程前原子恢复原 `model_provider`，并同时强制移除显式代理环境，以官方 provider + VPN 原生网络继续启动。只要当前版本仍能解析兼容定义，旧任务依赖的 `codex-hotpatch-http` 表会保留但不被新任务选中；只有定义本身不再受支持时才完全移除。兜底入口同样使用官方 provider 和 VPN 原生网络，并始终交由 Codex Desktop 的官方核心发现逻辑启动。

`SyncEnv` 适用于 365VPN 端口或路由变化；`Doctor` 输出所选 `NetworkMode`、实际采样路径的中位耗时、熔断状态和网络检查。`Status` 还会显示官方内置 CLI、旧 CLI 回收是否仍在等待占用解除、原生路径 10 分钟跨任务故障数、退化阈值、准备路径是否需要重启、冷却时间和监测器状态。完整退出 Codex 后从相应入口重新启动，才能保证新的 `.env`、provider 和进程环境全部生效；补丁不会自动结束正在运行的任务。

## 开发验证

在本目录分别用 Windows PowerShell 5.1 和 PowerShell 7 执行以下隔离测试（启动测试使用替身，不会关闭或冷启动真实 Codex）：

```powershell
& '.\manage-hotpatch.tests.ps1'
& '.\network-health.tests.ps1'
& '.\network-runtime-observer.tests.ps1'
& '.\install-rollback.tests.ps1'
& '.\network-watchdog.tests.ps1'
& '.\launch-recovery.tests.ps1'
```

## 写入与回退边界

- `.codex/.env`：仅接管 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY`、`NO_PROXY` 和带标记托管块；保留其他内容，异常或重复标记时 fail-closed。
- `.codex/config.toml`：仅接管一个带标记的顶层 `model_provider` 选择器和 `[model_providers.codex-hotpatch-http]`。原 `model_provider` 行同时保存在托管块和安装目录的 `transport-state.json`；应用更新剥离顶层标记后，只有两处所有权与恢复记录一致才自动重建。安装和移除后均调用当前 Codex 解析配置，失败则原子恢复。
- `CODEX_CLI_PATH`：当前版本不写永久覆盖。若从 1.10–1.13 升级，仅在用户级变量仍指向补丁旧镜像时读取当时保存的原值；恢复值或标准 OpenAI npm CLI 已落后于当前 Appx 官方核心时会被清除。两个补丁启动入口只对其创建的桌面子进程移除继承值，以使用官方核心。
- 安装目录中的 `network-health.json` 只保存熔断状态，`transport-state.json` 只保存原 provider 的可逆恢复行，`network-runtime-cursor.json` 只保存最后已观察的日志行号，`network-watchdog.log` 只保存有界运行诊断；状态更新使用进程间互斥和原子替换。`logs_2.sqlite` 始终以只读标志打开。
- `Uninstall` 会停止持续守护器，移除上述两个托管块、恢复原 `model_provider` 并删除两个开始菜单快捷方式和登录自启入口；旧 CLI 目录仅在不再被进程占用且环境不再引用时删除。它不修改 Windows 用户级/系统级永久代理环境、Codex 安装目录、会话数据库或 `app.asar`。
- `NO_PROXY=localhost,127.0.0.1,::1` 保护本地 DevTools；动态 VPN 端口无需重装，下一次 `SyncEnv` 或专用启动会重新识别。

## 已知边界

历史排障参考包括 OpenAI 官方仓库的 [#24533](https://github.com/openai/codex/issues/24533)、[#30933](https://github.com/openai/codex/issues/30933) 和 [#36059](https://github.com/openai/codex/issues/36059)，其当前状态应以原页面为准。本补丁通过 HTTPS/SSE 避开已复现的 WebSocket 路径，并用可归属的真实长流错误驱动显式 VPN 熔断，但无法承诺外部 VPN 节点、运营商或服务端始终无波动，也不能把已运行进程热切换到另一组环境变量。安装前已创建且保存了官方 provider 的历史任务，也可能在后续回合继续优先尝试 WebSocket；补丁会将其报告为 `LegacyThreadProviderDriftDetected`，但不会通过改写 SQLite 或 rollout 强制迁移任务。守护启用时会识别各入口启动的桌面核心，保留故障历史，并在备用线路通过验证后为下次完整重启准备环境；日志缺失或传输归属未知时不作确定性切换。两条线路都未通过时不宣称恢复成功。独立兜底入口恢复官方 provider、停用守护，并尽可能保留旧任务依赖的 provider 定义；配置恢复失败则报错，不强行覆盖。
