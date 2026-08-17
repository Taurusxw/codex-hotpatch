$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'manage-hotpatch.ps1')

function Assert-True {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw $Message }
}

$managedText = @"
USER_SETTING=preserve

# BEGIN CodexNetworkProxyHotpatch
HTTP_PROXY=http://127.0.0.1:57777
HTTPS_PROXY=http://127.0.0.1:57777
ALL_PROXY=http://127.0.0.1:57777
NO_PROXY=localhost,127.0.0.1,::1
# END CodexNetworkProxyHotpatch
"@

$vpnText = Convert-CodexProxyEnvText -ExistingText $managedText -NetworkMode VpnProxy -ProxyValue 'http://127.0.0.1:57777'
Assert-True ($vpnText.Contains('USER_SETTING=preserve')) 'VPN 同步必须保留非托管 .env 内容。'
Assert-True ((@($vpnText -split "`r?`n" | Where-Object { $_ -eq $EnvBlockStart }).Count) -eq 1) 'VPN 同步必须只保留一个托管区块。'
Assert-True ($vpnText.Contains('HTTPS_PROXY=http://127.0.0.1:57777')) 'VPN 同步必须写入 HTTPS_PROXY。'

$directText = Convert-CodexProxyEnvText -ExistingText $vpnText -NetworkMode OfficialDirect
Assert-True ($directText -eq "USER_SETTING=preserve$([Environment]::NewLine)") '官方直连必须只移除托管区块并保留其他内容。'
Assert-True ($directText -notmatch 'CodexNetworkProxyHotpatch|HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY') '官方直连不得残留托管代理键。'

$legacyText = "USER_SETTING=preserve`nHTTP_PROXY=http://legacy:8888`nNO_PROXY=legacy"
$legacyDirectText = Convert-CodexProxyEnvText -ExistingText $legacyText -NetworkMode OfficialDirect
Assert-True ($legacyDirectText -eq "USER_SETTING=preserve$([Environment]::NewLine)") '官方直连必须清除旧版或重复的独立代理键。'

$malformedRejected = $false
try {
    Convert-CodexProxyEnvText -ExistingText "$EnvBlockStart`nHTTP_PROXY=http://127.0.0.1:57777" -NetworkMode OfficialDirect | Out-Null
}
catch {
    $malformedRejected = $true
}
Assert-True $malformedRejected '不完整托管区块必须 fail-closed。'

function Get-WinInetProxyUri { return [Uri]'http://127.0.0.1:57777' }
function Test-ProxyListener { param([Uri]$ProxyUri) return $true }
$vpnSelection = Resolve-CodexNetworkMode
Assert-True ($vpnSelection.NetworkMode -eq 'VpnProxy') '本地代理健康时必须优先选择 VPN。'

function Test-ProxyListener { param([Uri]$ProxyUri) return $false }
$directSelection = Resolve-CodexNetworkMode
Assert-True ($directSelection.NetworkMode -eq 'OfficialDirect') '本地监听不可连接时必须回退官方直连。'
Assert-True ($directSelection.Reason -match '本地 VPN 代理监听') '回退原因必须可观察。'

function Get-WinInetProxyUri { throw 'Windows 用户代理未启用。' }
$invalidWinInetSelection = Resolve-CodexNetworkMode
Assert-True ($invalidWinInetSelection.NetworkMode -eq 'OfficialDirect') 'WinINET 无效时必须回退官方直连。'
Assert-True ($invalidWinInetSelection.Reason -match 'WinINET 代理不可用') 'WinINET 回退原因必须可观察。'

$detailsWithoutHandshake = [pscustomobject]@{ endpoint = 'wss://example.invalid/redacted' }
Assert-True ($null -eq (Get-OptionalObjectProperty -InputObject $detailsWithoutHandshake -Name 'handshake result')) '最新版 doctor 缺少 handshake result 时不得触发 StrictMode 属性异常。'

$runtimeFailureUtc = [DateTimeOffset]::Parse('2026-08-17T01:00:00Z').UtcDateTime
$nativeCore = [pscustomobject]@{ ProcessId = 101; ParentProcessId = 1; StartedUtc = $runtimeFailureUtc.AddMinutes(1) }
$oldExplicitCore = [pscustomobject]@{ ProcessId = 102; ParentProcessId = 1; StartedUtc = $runtimeFailureUtc.AddMinutes(-1) }
$openRuntimeState = [pscustomobject]@{
    LastFailureUtc = $runtimeFailureUtc
    LastFailureKind = 'RuntimeStream'
    LastSuccessUtc = $runtimeFailureUtc.AddHours(-1)
}
$fallbackAssignments = @(Get-CodexCoreRouteAssignments -CoreProcesses @($nativeCore, $oldExplicitCore) `
    -HealthState $openRuntimeState -ExplicitRoutePrepared:$false)
Assert-True (($fallbackAssignments | Where-Object ProcessId -eq 101).Route -eq 'VpnNativeHttps') '熔断后启动的核心必须归属 VPN 原生路径。'
Assert-True (($fallbackAssignments | Where-Object ProcessId -eq 102).Route -eq 'VpnExplicitHttps') '熔断前已运行的核心必须保留显式路径归属。'

$earlyRecoveryState = [pscustomobject]@{
    LastFailureUtc = $runtimeFailureUtc
    LastFailureKind = 'RuntimeStream'
    LastSuccessUtc = $runtimeFailureUtc.AddMinutes(2)
}
$newExplicitCore = [pscustomobject]@{ ProcessId = 103; ParentProcessId = 1; StartedUtc = $runtimeFailureUtc.AddMinutes(3) }
$recoveryAssignments = @(Get-CodexCoreRouteAssignments -CoreProcesses @($nativeCore, $newExplicitCore) `
    -HealthState $earlyRecoveryState -ExplicitRoutePrepared:$true)
Assert-True (($recoveryAssignments | Where-Object ProcessId -eq 101).Route -eq 'VpnNativeHttps') '提前恢复只改变新进程环境，不得把仍运行的原生核心误标为显式。'
Assert-True (($recoveryAssignments | Where-Object ProcessId -eq 103).Route -eq 'VpnExplicitHttps') '提前恢复后新启动的核心必须归属显式路径。'

$configText = @"
model = "gpt-5.6-sol"
model_provider = "openai"

[model_providers.custom]
name = "preserve me"
wire_api = "responses"
"@
$installedConfigText = Convert-CodexTransportConfigText -ExistingText $configText -Action Install
Assert-True ($installedConfigText.Contains('model_provider = "codex-hotpatch-http"')) '安装必须选择独立 HTTPS-only provider。'
Assert-True ($installedConfigText.Contains('[model_providers.codex-hotpatch-http]')) '安装必须声明独立 provider，不能覆盖保留的内置 openai。'
Assert-True ($installedConfigText.Contains('[model_providers.custom]')) '安装必须保留用户已有的自定义 provider。'
Assert-True ($installedConfigText.Contains('supports_websockets = false')) '稳定传输 provider 必须禁用 Responses WebSocket。'
Assert-True ($installedConfigText.Contains('request_max_retries = 6')) 'HTTPS-only provider 必须提高请求级瞬时故障重试预算。'
Assert-True ($installedConfigText.Contains('stream_max_retries = 8')) 'HTTPS-only provider 必须提高 SSE 流重连预算。'
$reinstalledConfigText = Convert-CodexTransportConfigText -ExistingText $installedConfigText -Action Install
Assert-True ($reinstalledConfigText -eq $installedConfigText) 'HTTPS-only provider 安装必须幂等。'
$removedConfigText = Convert-CodexTransportConfigText -ExistingText $installedConfigText -Action Remove
Assert-True ($removedConfigText.Contains('model_provider = "openai"')) '移除时必须恢复原 model_provider。'
Assert-True ($removedConfigText.Contains('[model_providers.custom]')) '移除时必须保留用户自定义 provider。'
Assert-True ($removedConfigText -notmatch 'CodexNetworkProxyHotpatch transport|codex-hotpatch-http') '移除后不得残留托管 provider 或标记。'

$partialTransportMarkerRejected = $false
try {
    Convert-CodexTransportConfigText -ExistingText "$TransportSelectorStart`nmodel_provider = `"$TransportProviderId`"" -Action Install | Out-Null
}
catch {
    $partialTransportMarkerRejected = $true
}
Assert-True $partialTransportMarkerRejected '不完整 config.toml 托管标记必须 fail-closed。'

$originalCodexEnvPath = $CodexEnvPath
$originalNetworkHealthPath = $NetworkHealthPath
$originalVpnProbeIntervalMilliseconds = $VpnProbeIntervalMilliseconds
$CodexEnvPath = Join-Path ([IO.Path]::GetTempPath()) ("codex-hotpatch-network-test-$PID.env")
$NetworkHealthPath = Join-Path ([IO.Path]::GetTempPath()) ("codex-hotpatch-network-health-test-$PID.json")
$VpnProbeIntervalMilliseconds = 0
try {
    function Resolve-CodexNetworkMode {
        return [pscustomobject]@{
            NetworkMode = 'VpnProxy'
            Reason = 'test VPN listener ready'
            ProxyUri = [Uri]'http://127.0.0.1:57777'
        }
    }
    function New-TestProbe {
        param(
            [bool]$ProviderHealthy,
            [bool]$WebSocketHealthy,
            [double]$ProviderDurationMs = 100,
            [string]$ProviderStatus = $(if ($ProviderHealthy) { 'ok' } else { 'error' }),
            [string]$WebSocketStatus = $(if ($WebSocketHealthy) { 'ok' } else { 'warning' })
        )
        return [pscustomobject]@{
            Available = $true
            Healthy = $ProviderHealthy -and $WebSocketHealthy
            TransportHealthy = $ProviderHealthy
            ProviderHealthy = $ProviderHealthy
            WebSocketHealthy = $WebSocketHealthy
            ProviderStatus = $ProviderStatus
            ProviderSummary = if ($ProviderHealthy) { 'provider ok' } else { 'provider unavailable' }
            ProviderDurationMs = $ProviderDurationMs
            WebSocketStatus = $WebSocketStatus
            WebSocketSummary = if ($WebSocketHealthy) { 'websocket ok' } else { 'HTTPS fallback may still work' }
            WebSocketHandshake = if ($WebSocketHealthy) { 'HTTP 101 Switching Protocols' } else { $null }
            WebSocketDurationMs = 10
            DoctorOverallStatus = if ($ProviderHealthy) { 'warning' } else { 'fail' }
            Error = $null
        }
    }
    function Invoke-CodexDoctorProbe {
        $script:doctorProbeCount += 1
        $result = $script:doctorProbeResults[$script:doctorProbeCount - 1]
        if (-not $result) { throw 'unexpected doctor probe' }
        return $result
    }

    # A healthy explicit route is selected without paying for an unnecessary native probe series.
    $script:doctorProbeCount = 0
    $script:doctorProbeResults = @(
        (New-TestProbe -ProviderHealthy $true -WebSocketHealthy $true -ProviderDurationMs 100),
        (New-TestProbe -ProviderHealthy $true -WebSocketHealthy $true -ProviderDurationMs 105),
        (New-TestProbe -ProviderHealthy $true -WebSocketHealthy $true -ProviderDurationMs 95)
    )
    $explicitFastSelection = Sync-CodexProxyEnv -VerifyRemote
    Assert-True ($explicitFastSelection.NetworkMode -eq 'VpnExplicitHttps') '两条路径均健康时必须选择经端到端基准验证的显式 VPN HTTPS 主路径。'
    Assert-True $explicitFastSelection.RouteHealthy '显式主路径必须报告健康。'
    Assert-True ($script:doctorProbeCount -eq 3) '显式代理稳定时必须只完成三次主路采样，避免无意义启动延迟。'
    $explicitFastText = [IO.File]::ReadAllText($CodexEnvPath)
    Assert-True ($explicitFastText.Contains('HTTPS_PROXY=http://127.0.0.1:57777')) '显式路径胜出时必须保留当前 VPN 端口。'

    # A tiny native doctor probe cannot overrule the stable explicit primary route.
    $script:doctorProbeCount = 0
    $script:doctorProbeResults = @(
        (New-TestProbe -ProviderHealthy $true -WebSocketHealthy $true -ProviderDurationMs 200),
        (New-TestProbe -ProviderHealthy $true -WebSocketHealthy $true -ProviderDurationMs 210),
        (New-TestProbe -ProviderHealthy $true -WebSocketHealthy $true -ProviderDurationMs 205)
    )
    $nativeProbeFastSelection = Sync-CodexProxyEnv -VerifyRemote
    Assert-True ($nativeProbeFastSelection.NetworkMode -eq 'VpnExplicitHttps') '单次轻量探测中 VPN 原生更快时仍必须保留经真实负载验证的显式主路径。'
    Assert-True $nativeProbeFastSelection.RouteHealthy '显式主路径必须报告健康。'
    $nativeProbeFastText = [IO.File]::ReadAllText($CodexEnvPath)
    Assert-True ($nativeProbeFastText.Contains('ALL_PROXY=http://127.0.0.1:57777')) '显式主路径必须保留完整代理变量。'

    # An unknown desktop major or parser fallback must pair the official provider with native VPN.
    $script:doctorProbeCount = 0
    $script:doctorProbeResults = @(
        (New-TestProbe -ProviderHealthy $true -WebSocketHealthy $false -ProviderDurationMs 70),
        (New-TestProbe -ProviderHealthy $true -WebSocketHealthy $false -ProviderDurationMs 75)
    )
    $forcedNativeSelection = Sync-CodexProxyEnv -VerifyRemote -ForceNative
    Assert-True ($forcedNativeSelection.NetworkMode -eq 'VpnNativeHttps') '兼容门禁必须强制使用 VPN 原生网络环境。'
    Assert-True ($script:doctorProbeCount -eq 2) '兼容门禁不得探测或注入显式代理。'
    $forcedNativeText = [IO.File]::ReadAllText($CodexEnvPath)
    Assert-True ($forcedNativeText -notmatch 'HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY|CodexNetworkProxyHotpatch') '官方 provider 兜底不得残留强制代理环境。'

    # Explicit failure falls back to a healthy native route.
    $script:doctorProbeCount = 0
    $script:doctorProbeResults = @(
        (New-TestProbe -ProviderHealthy $false -WebSocketHealthy $false),
        (New-TestProbe -ProviderHealthy $true -WebSocketHealthy $true -ProviderDurationMs 80),
        (New-TestProbe -ProviderHealthy $true -WebSocketHealthy $true -ProviderDurationMs 85)
    )
    $fallbackSelection = Sync-CodexProxyEnv -VerifyRemote
    Assert-True ($fallbackSelection.NetworkMode -eq 'VpnNativeHttps') '显式代理失败时必须自动回退健康的 VPN 原生 HTTPS 路径。'
    Assert-True $fallbackSelection.RouteHealthy '健康后备路径必须报告可用。'

    # If both HTTPS/SSE routes fail, never leave Codex pinned to the failed explicit proxy.
    $script:doctorProbeCount = 0
    $script:doctorProbeResults = @(
        (New-TestProbe -ProviderHealthy $false -WebSocketHealthy $false),
        (New-TestProbe -ProviderHealthy $false -WebSocketHealthy $false)
    )
    $degradedSelection = Sync-CodexProxyEnv -VerifyRemote
    Assert-True ($degradedSelection.NetworkMode -eq 'VpnNativeHttps') '两条路径失败后必须退回无强制代理键的 VPN 原生环境。'
    Assert-True (-not $degradedSelection.RouteHealthy) '两条路径均未通过时必须报告降级而非假报健康。'
    $degradedText = [IO.File]::ReadAllText($CodexEnvPath)
    Assert-True ($degradedText -notmatch 'HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY|CodexNetworkProxyHotpatch') '显式代理失败后不得残留强制代理键。'
    Assert-True (Test-Path -LiteralPath $NetworkHealthPath -PathType Leaf) '显式代理失败必须留下可观察的私有健康记录。'

    # The now-open circuit must survive a new call and skip all explicit probes during cooldown.
    $script:doctorProbeCount = 0
    $script:doctorProbeResults = @(
        (New-TestProbe -ProviderHealthy $true -WebSocketHealthy $false -ProviderDurationMs 70),
        (New-TestProbe -ProviderHealthy $true -WebSocketHealthy $false -ProviderDurationMs 75)
    )
    $openCircuitSelection = Sync-CodexProxyEnv -VerifyRemote
    Assert-True ($openCircuitSelection.NetworkMode -eq 'VpnNativeHttps') '熔断冷却期必须直接选择 VPN 原生 HTTPS/SSE。'
    Assert-True ($script:doctorProbeCount -eq 2) '熔断冷却期必须跳过显式代理，只采样两次原生路径。'
    Assert-True ($openCircuitSelection.CircuitState -eq 'Open') '跨调用读取必须保持熔断状态。'

    # Material degradation on the active native route may open one verified early recovery window.
    $script:doctorProbeCount = 0
    $script:doctorProbeResults = @(
        (New-TestProbe -ProviderHealthy $true -WebSocketHealthy $true -ProviderDurationMs 100),
        (New-TestProbe -ProviderHealthy $true -WebSocketHealthy $true -ProviderDurationMs 101),
        (New-TestProbe -ProviderHealthy $true -WebSocketHealthy $true -ProviderDurationMs 99),
        (New-TestProbe -ProviderHealthy $true -WebSocketHealthy $true -ProviderDurationMs 102),
        (New-TestProbe -ProviderHealthy $true -WebSocketHealthy $true -ProviderDurationMs 98)
    )
    $earlyRecoverySelection = Sync-CodexProxyEnv -VerifyRemote -AllowEarlyRecovery
    Assert-True ($earlyRecoverySelection.NetworkMode -eq 'VpnExplicitHttps') '原生路径实质性退化后必须允许在冷却期内验证备用显式路径。'
    Assert-True ($script:doctorProbeCount -eq 5) '提前恢复必须使用五次连续探测，不能由一次短成功翻转。'
    Assert-True ($earlyRecoverySelection.CircuitState -eq 'Closed') '五次验证通过后必须为下次启动重新准备显式路径。'
    $earlyRecoveryText = [IO.File]::ReadAllText($CodexEnvPath)
    Assert-True ($earlyRecoveryText.Contains('ALL_PROXY=http://127.0.0.1:57777')) '提前恢复成功必须写回完整显式代理环境。'

    # After cooldown, only a stronger five-probe half-open series may restore explicit VPN.
    $pastRetry = [DateTime]::UtcNow.AddMinutes(-1)
    $openStateText = [ordered]@{
        Version = 2
        CircuitState = 'Open'
        ConsecutiveFailures = 2
        WindowStartedUtc = [DateTime]::UtcNow.AddMinutes(-32).ToString('o')
        LastFailureUtc = [DateTime]::UtcNow.AddMinutes(-31).ToString('o')
        LastFailureReason = 'test cooldown elapsed'
        RetryAfterUtc = $pastRetry.ToString('o')
        LastSuccessUtc = $null
    } | ConvertTo-Json -Compress
    [IO.File]::WriteAllText($NetworkHealthPath, $openStateText, [Text.UTF8Encoding]::new($false))
    $script:doctorProbeCount = 0
    $script:doctorProbeResults = @(
        (New-TestProbe -ProviderHealthy $true -WebSocketHealthy $true -ProviderDurationMs 100),
        (New-TestProbe -ProviderHealthy $true -WebSocketHealthy $true -ProviderDurationMs 101),
        (New-TestProbe -ProviderHealthy $true -WebSocketHealthy $true -ProviderDurationMs 99),
        (New-TestProbe -ProviderHealthy $true -WebSocketHealthy $true -ProviderDurationMs 102),
        (New-TestProbe -ProviderHealthy $true -WebSocketHealthy $true -ProviderDurationMs 98)
    )
    $recoveredSelection = Sync-CodexProxyEnv -VerifyRemote
    Assert-True ($recoveredSelection.NetworkMode -eq 'VpnExplicitHttps') '冷却后五次连续成功必须恢复显式 VPN。'
    Assert-True ($script:doctorProbeCount -eq 5) '半开恢复必须使用五次连续探测。'
    Assert-True ($recoveredSelection.CircuitState -eq 'Closed') '半开恢复成功后必须持久关闭熔断器。'
}
finally {
    if (Test-Path -LiteralPath $CodexEnvPath -PathType Leaf) { [IO.File]::Delete($CodexEnvPath) }
    if (Test-Path -LiteralPath $NetworkHealthPath -PathType Leaf) { [IO.File]::Delete($NetworkHealthPath) }
    $CodexEnvPath = $originalCodexEnvPath
    $NetworkHealthPath = $originalNetworkHealthPath
    $VpnProbeIntervalMilliseconds = $originalVpnProbeIntervalMilliseconds
}

$originalCodexConfigPath = $CodexConfigPath
$CodexConfigPath = Join-Path ([IO.Path]::GetTempPath()) ("codex-hotpatch-config-compat-test-$PID.toml")
try {
    function Get-CodexDesktopPackageVersion { return [Version]'26.810.7004.0' }
    [IO.File]::WriteAllText($CodexConfigPath, $installedConfigText, [Text.UTF8Encoding]::new($false))
    function Test-CodexConfigLoads {
        $currentText = [IO.File]::ReadAllText($CodexConfigPath)
        return -not $currentText.Contains('[model_providers.codex-hotpatch-http]')
    }
    $compatibilityResult = Install-CodexHttpTransport
    Assert-True (-not $compatibilityResult.Enabled) '大版本拒绝托管 provider 时不得继续报告 HTTPS-only 已启用。'
    Assert-True $compatibilityResult.CompatibilityFallback '大版本拒绝托管 provider 时必须进入兼容兜底。'
    $recoveredConfigText = [IO.File]::ReadAllText($CodexConfigPath)
    Assert-True ($recoveredConfigText.Contains('model_provider = "openai"')) '兼容兜底必须恢复原 model_provider。'
    Assert-True ($recoveredConfigText -notmatch 'CodexNetworkProxyHotpatch transport|codex-hotpatch-http') '兼容兜底不得残留新版无法解析的托管 provider。'

    # A desktop major update must fall back before trusting a potentially stale PATH CLI.
    [IO.File]::WriteAllText($CodexConfigPath, $installedConfigText, [Text.UTF8Encoding]::new($false))
    function Get-CodexDesktopPackageVersion { return [Version]'27.0.0.0' }
    function Test-CodexConfigLoads { return $true }
    $majorFallbackResult = Install-CodexHttpTransport
    Assert-True (-not $majorFallbackResult.Enabled) '未经验证的桌面主版本不得继续启用自定义 provider。'
    Assert-True $majorFallbackResult.CompatibilityFallback '桌面主版本变化必须进入官方 provider 兼容兜底。'
    $majorRecoveredText = [IO.File]::ReadAllText($CodexConfigPath)
    Assert-True ($majorRecoveredText.Contains('model_provider = "openai"')) '桌面主版本变化必须恢复原 model_provider。'
    Assert-True ($majorRecoveredText -notmatch 'CodexNetworkProxyHotpatch transport|codex-hotpatch-http') '桌面主版本变化后不得残留自定义 provider。'
}
finally {
    if (Test-Path -LiteralPath $CodexConfigPath -PathType Leaf) { [IO.File]::Delete($CodexConfigPath) }
    $CodexConfigPath = $originalCodexConfigPath
}

'manage-hotpatch tests: PASS'
