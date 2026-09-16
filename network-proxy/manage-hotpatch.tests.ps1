$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'manage-hotpatch.ps1')
$ExplicitProxyDisabledPath = Join-Path ([IO.Path]::GetTempPath()) ('codex-proxy-optout-test-' + [Guid]::NewGuid().ToString('N'))
$HttpTransportDisabledPath = Join-Path ([IO.Path]::GetTempPath()) ('codex-http-optout-test-' + [Guid]::NewGuid().ToString('N'))

function Assert-True {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw $Message }
}

& {
    # Exercise subprocess lifetime without launching or terminating any real Codex process.
    $script:doctorCommandFinished = $true
    $script:doctorCommandJson = '{"checks":{}}'
    function New-Object {
        param([string]$TypeName)
        if ($TypeName -ne 'Diagnostics.Process') { throw "Unexpected construction: $TypeName" }
        $reader = [pscustomobject]@{}
        $reader | Add-Member ScriptMethod ReadToEndAsync {
            return [Threading.Tasks.Task]::FromResult([string]$script:doctorCommandJson)
        }
        $inputWriter = [pscustomobject]@{}
        $inputWriter | Add-Member ScriptMethod Close { }
        $script:doctorChild = [pscustomobject]@{
            StartInfo = $null; StandardInput = $inputWriter; StandardOutput = $reader
            StandardError = $reader; HasExited = $false; Killed = $false; Disposed = $false
        }
        $script:doctorChild | Add-Member ScriptMethod Start { return $true }
        $script:doctorChild | Add-Member ScriptMethod WaitForExit {
            param($Milliseconds)
            $this.HasExited = $script:doctorCommandFinished -or $this.Killed
            return $this.HasExited
        }
        $script:doctorChild | Add-Member ScriptMethod Kill { $this.Killed = $true }
        $script:doctorChild | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
        return $script:doctorChild
    }
    Invoke-CodexDoctorCommand -CliPath 'C:\verified\codex.exe' | Out-Null
    Assert-True ($script:doctorChild.StartInfo.FileName -eq 'C:\verified\codex.exe') 'Doctor must execute the resolved absolute CLI.'
    Assert-True ($script:doctorChild.StartInfo.CreateNoWindow -and -not $script:doctorChild.StartInfo.UseShellExecute) 'Doctor must not open a console or resolve through a shell.'
    Assert-True ($script:doctorChild.Disposed -and -not $script:doctorChild.Killed) 'Completed doctor must be disposed without killing another process.'
    $script:doctorCommandFinished = $false
    $timedOut = $false
    try { Invoke-CodexDoctorCommand -CliPath 'C:\verified\codex.exe' -TimeoutMilliseconds 1000 | Out-Null }
    catch { $timedOut = $_.Exception.Message -match '1000 ms' }
    Assert-True ($timedOut -and $script:doctorChild.Killed -and $script:doctorChild.Disposed) 'Timeout must stop and dispose only the owned diagnostic child.'
    $script:doctorCommandFinished = $true
    $script:doctorCommandJson = 'invalid-json'
    $malformed = $false
    try { Invoke-CodexDoctorCommand -CliPath 'C:\verified\codex.exe' | Out-Null } catch { $malformed = $true }
    Assert-True ($malformed -and $script:doctorChild.Disposed) 'Invalid doctor JSON must be rejected and disposed.'
}

& {
    function Clear-CodexProxyEnvironment { }
    function Resolve-CodexNetworkMode { return [pscustomobject]@{ NetworkMode = 'OfficialDirect' } }
    function Get-CodexOperationalCli { return [pscustomobject]@{ Path = 'C:\verified\codex.exe' } }
    function Get-Command { throw 'Doctor must not search PATH.' }
    function Invoke-CodexDoctorCommand {
        param($CliPath)
        Assert-True ($CliPath -eq 'C:\verified\codex.exe') 'Probe must use the existing trusted resolver.'
        return '{"checks":{"network.provider_reachability":{"status":"ok"},"network.websocket_reachability":{"status":"warning"}}}' | ConvertFrom-Json
    }
    function Invoke-CodexResponsesEndpointProbe {
        param($ProxyUri)
        return [pscustomobject]@{ Healthy = $true; StatusCode = 405; DurationMs = 10; Error = $null }
    }
    $probe = Invoke-CodexDoctorProbe
    Assert-True ($probe.DoctorAvailable -and $probe.ProviderHealthy) 'A missing PATH codex command must not prevent healthy diagnostics.'
    function Invoke-CodexDoctorCommand { param($CliPath) throw 'simulated doctor timeout' }
    $probe = Invoke-CodexDoctorProbe
    Assert-True ($probe.Available -and $probe.ProviderHealthy -and -not $probe.DoctorAvailable) 'A successful endpoint probe must survive doctor failure.'
    function Invoke-CodexResponsesEndpointProbe {
        param($ProxyUri)
        return [pscustomobject]@{ Healthy = $false; StatusCode = $null; DurationMs = 5000; Error = 'timeout' }
    }
    $probe = Invoke-CodexDoctorProbe
    $series = [pscustomobject]@{ Stable = $false; LastProbe = $probe }
    Assert-True (Test-CodexProbeNeedsAuthenticatedVerification -ProbeSeries $series) 'Unavailable doctor with a usable CLI must allow authenticated verification.'
    Assert-True (-not (Test-CodexProbeHasFailureEvidence -ProbeSeries $series)) 'Diagnostic failure alone must not trip the circuit.'
    Assert-True (Test-CodexProbeHasFailureEvidence -ProbeSeries $series -AuthenticatedProbe ([pscustomobject]@{ TransportErrors = 1 })) 'Actual authenticated transport errors remain network evidence.'
    function Get-CodexOperationalCli { return $null }
    $probe = Invoke-CodexDoctorProbe
    $series.LastProbe = $probe
    Assert-True (-not $probe.Available -and -not $probe.DiagnosticCliAvailable) 'Missing CLI and failed passive probe must remain unverified.'
    Assert-True (-not (Test-CodexProbeNeedsAuthenticatedVerification -ProbeSeries $series)) 'Missing CLI must not trigger an impossible authenticated probe.'
    $selection = [pscustomobject]@{ RouteHealthy = $null }
    Assert-True ((Get-CodexNetworkDoctorOverallStatus -Selection $selection -Probe $probe -AuthenticatedHealthy $null) -match '^unknown') 'Unavailable diagnosis must have an explicit unknown status.'
}

& {
    function Get-WinInetProxyUri { throw 'Native-only must not read a proxy candidate.' }
    try {
        [IO.File]::WriteAllText($ExplicitProxyDisabledPath, 'user opt-out')
        Assert-True (-not (Test-CodexExplicitProxyEnabled)) 'Persistent opt-out must disable explicit proxy.'
        $candidate = Resolve-CodexNetworkMode
        Assert-True ($candidate.NetworkMode -eq 'OfficialDirect' -and $null -eq $candidate.ProxyUri) 'Opt-out must suppress even an available system proxy.'
    }
    finally { [IO.File]::Delete($ExplicitProxyDisabledPath) }
    Assert-True (Test-CodexExplicitProxyEnabled) 'Absent opt-out must preserve existing routing behavior.'
}

$shortcutTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-watchdog-shortcut-' + [Guid]::NewGuid().ToString('N'))
$shortcutTestPath = Join-Path $shortcutTestRoot 'watchdog.lnk'
$originalWatchdogStartupShortcutPath = $WatchdogStartupShortcutPath
try {
    New-Item -ItemType Directory -Path $shortcutTestRoot | Out-Null
    $WatchdogStartupShortcutPath = $shortcutTestPath
    Set-CodexWatchdogStartupShortcut -CodexExecutable "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $shortcutShell = New-Object -ComObject WScript.Shell
    $watchdogShortcut = $shortcutShell.CreateShortcut($shortcutTestPath)
    Assert-True ($watchdogShortcut.Arguments -match '(?i)(?:^|\s)-WindowStyle\s+Hidden(?:\s|$)') '登录自启守护必须使用隐藏 PowerShell 窗口。'
    Assert-True ($watchdogShortcut.WindowStyle -eq 7) '登录自启快捷方式必须以最小化样式启动，避免隐藏参数生效前出现黑框。'
    $watchdogLaunch = Get-CodexNetworkWatchdogLaunchSpec
    Assert-True ($watchdogLaunch.CommandLine.StartsWith('"')) '脱离式守护命令必须显式引用 PowerShell 可执行文件。'
    Assert-True ($watchdogLaunch.Arguments -match '(?i)(?:^|\s)-WindowStyle\s+Hidden(?:\s|$)') '脱离式守护必须保持隐藏窗口。'
    Assert-True ($watchdogLaunch.Arguments -match '(?i)(?:^|\s)-Persistent(?:\s|$)') '脱离式守护必须使用持久模式。'
    Assert-True ($watchdogLaunch.Arguments.Contains($InstalledNetworkWatchdog)) '脱离式守护必须启动当前安装副本。'
}
finally {
    $WatchdogStartupShortcutPath = $originalWatchdogStartupShortcutPath
    if (Test-Path -LiteralPath $shortcutTestPath -PathType Leaf) { Remove-Item -LiteralPath $shortcutTestPath -Force }
    if (Test-Path -LiteralPath $shortcutTestRoot -PathType Container) { Remove-Item -LiteralPath $shortcutTestRoot -Force }
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

$auxiliaryProbeDiagnostics = Get-CodexResponsesTransportDiagnostics -Text @'
ERROR codex_models_manager::manager: failed to refresh available models: timeout waiting for child process to exit
WARN codex_core_plugins::manager: error sending request for url (https://chatgpt.com/backend-api/ps/plugins/list)
WARN codex_analytics::client: error sending request for url (https://chatgpt.com/backend-api/codex/analytics-events/events)
{"type":"turn.completed"}
'@
Assert-True ($auxiliaryProbeDiagnostics.ReconnectSignals -eq 0) '模型目录、插件和分析旁路失败不得误报主流重连。'
Assert-True ($auxiliaryProbeDiagnostics.TransportErrors -eq 0) '模型目录、插件和分析旁路失败不得误报 Responses 主流传输错误。'

$responsesProbeDiagnostics = Get-CodexResponsesTransportDiagnostics -Text @'
WARN stream disconnected before completion: error sending request for url (https://chatgpt.com/backend-api/codex/responses)
{"type":"item.completed","item":{"type":"error","message":"network error"}}
'@
Assert-True ($responsesProbeDiagnostics.ReconnectSignals -gt 0) 'Responses 主流断开必须继续计入重连证据。'
Assert-True ($responsesProbeDiagnostics.TransportErrors -gt 0) 'Responses 主流断开必须继续计入传输错误。'

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

$probeFailureUtc = $runtimeFailureUtc.AddHours(1)
$probeRecoveryState = [pscustomobject]@{
    LastFailureUtc = $probeFailureUtc
    LastFailureKind = 'Probe'
    LastSuccessUtc = $probeFailureUtc.AddMinutes(2)
}
$probeFallbackCore = [pscustomobject]@{
    ProcessId = 104
    ParentProcessId = 2
    StartedUtc = $probeFailureUtc.AddMinutes(1)
}
$probeRecoveryAssignments = @(Get-CodexCoreRouteAssignments -CoreProcesses @($probeFallbackCore) `
    -HealthState $probeRecoveryState -ExplicitRoutePrepared:$true)
Assert-True ($probeRecoveryAssignments[0].Route -eq 'VpnNativeHttps') 'Probe 熔断后、显式恢复前启动的旧核心必须继续归属原生路径。'

$persistedNativeAssignment = [pscustomobject]@{
    ProcessId = $nativeCore.ProcessId
    ParentProcessId = $nativeCore.ParentProcessId
    StartedUtc = $nativeCore.StartedUtc
    Route = 'VpnNativeHttps'
}
$laterExplicitState = [pscustomobject]@{
    LastFailureUtc = $null
    LastFailureKind = $null
    LastSuccessUtc = [DateTime]::UtcNow
}
$persistedAssignments = @(Get-CodexCoreRouteAssignments -CoreProcesses @($nativeCore) `
    -HealthState $laterExplicitState -ExplicitRoutePrepared:$true `
    -PersistedAssignments @($persistedNativeAssignment))
Assert-True ($persistedAssignments[0].Route -eq 'VpnNativeHttps') '持久路由必须覆盖后来变化的 .env/健康状态。'

$samePidDifferentParent = [pscustomobject]@{
    ProcessId = $nativeCore.ProcessId
    ParentProcessId = 999
    StartedUtc = $nativeCore.StartedUtc
}
$differentParentAssignments = @(Get-CodexCoreRouteAssignments -CoreProcesses @($samePidDifferentParent) `
    -HealthState $laterExplicitState -ExplicitRoutePrepared:$true `
    -PersistedAssignments @($persistedNativeAssignment))
Assert-True ($differentParentAssignments[0].Route -eq 'VpnExplicitHttps') '持久路由匹配必须同时校验 PID、父进程和启动时间。'

$exactCliCandidate = [pscustomobject]@{
    Path = 'C:\desktop-current\codex.exe'
    Version = '0.154.0'
    Source = 'CurrentDesktopStable'
    Available = $true
    Trusted = $true
}
$trustedFallbackCandidate = [pscustomobject]@{
    Path = 'C:\trusted-npm\codex.exe'
    Version = '0.154.1'
    Source = 'TrustedOpenAiNpm'
    Available = $true
    Trusted = $true
}
$selectedExactCli = Select-CodexOperationalCli -ExactDesktopCandidate $exactCliCandidate `
    -FallbackCandidates @($trustedFallbackCandidate)
Assert-True ($selectedExactCli.Path -eq $exactCliCandidate.Path) '当前桌面精确匹配核心可用时必须保持最高优先级。'
$selectedUpdateFallbackCli = Select-CodexOperationalCli -ExactDesktopCandidate $null `
    -FallbackCandidates @($trustedFallbackCandidate)
Assert-True ($selectedUpdateFallbackCli.Path -eq $trustedFallbackCandidate.Path) '更新后稳定核心尚未落盘时必须允许可信 OpenAI CLI 完成启动前验证。'
$untrustedFallbackCandidate = [pscustomobject]@{
    Path = 'C:\custom\codex.exe'
    Version = '9.9.9'
    Source = 'Custom'
    Available = $true
    Trusted = $false
}
$selectedUntrustedCli = Select-CodexOperationalCli -ExactDesktopCandidate $null `
    -FallbackCandidates @($untrustedFallbackCandidate)
Assert-True ($null -eq $selectedUntrustedCli) '更新兜底不得执行任意不可信 CLI。'

$originalCoreRouteStatePath = $CoreRouteStatePath
$CoreRouteStatePath = Join-Path ([IO.Path]::GetTempPath()) ("codex-core-route-state-test-$PID.json")
try {
    Write-CodexCoreRouteState -Assignments @($persistedNativeAssignment)
    $loadedCoreRouteState = Get-CodexCoreRouteState
    Assert-True $loadedCoreRouteState.Present '写入后必须能发现核心路由状态。'
    Assert-True $loadedCoreRouteState.Healthy '写入后的核心路由状态必须可健康读取。'
    Assert-True ($loadedCoreRouteState.Assignments.Count -eq 1) '核心路由状态必须只恢复当前写入的有效记录。'
    Assert-True ($loadedCoreRouteState.Assignments[0].ProcessId -eq $nativeCore.ProcessId) '核心路由状态必须无损恢复 PID。'
    Assert-True ($loadedCoreRouteState.Assignments[0].ParentProcessId -eq $nativeCore.ParentProcessId) '核心路由状态必须无损恢复父进程。'
    Assert-True ($loadedCoreRouteState.Assignments[0].StartedUtc -eq $nativeCore.StartedUtc) '核心路由状态必须无损恢复启动时间。'
    Assert-True ($loadedCoreRouteState.Assignments[0].Route -eq 'VpnNativeHttps') '核心路由状态必须无损恢复启动线路。'
}
finally {
    if (Test-Path -LiteralPath $CoreRouteStatePath -PathType Leaf) { [IO.File]::Delete($CoreRouteStatePath) }
    $CoreRouteStatePath = $originalCoreRouteStatePath
}

$inheritedCliPolicy = Get-CodexDesktopLaunchCliPolicy -ExistingOverridePath 'C:\legacy-global\codex.exe'
Assert-True $inheritedCliPolicy.ClearOverride '启动入口必须在桌面子进程中忽略继承的 CLI 覆盖。'
Assert-True ($inheritedCliPolicy.Source -eq 'OfficialStable') '启动入口必须交回 Codex Desktop 官方核心发现。'
$bundledCliPolicy = Get-CodexDesktopLaunchCliPolicy -ExistingOverridePath ''
Assert-True (-not $bundledCliPolicy.ClearOverride) '没有继承 CLI 覆盖时不应伪报清理动作。'

$npmCliPath = Join-Path $env:APPDATA 'npm\node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe'
$staleNpmPolicy = Get-CodexCliOverridePolicy -OverridePath $npmCliPath -OverrideVersion '0.147.0' `
    -OfficialCliPath 'C:\official\codex.exe' -OfficialCliVersion '0.151.0-alpha.7.2' -RestoredOriginalPath $null
Assert-True $staleNpmPolicy.ClearOverride '落后于桌面官方核心的官方 npm CLI 覆盖必须清除。'
Assert-True ($staleNpmPolicy.VersionComparison -lt 0) 'CLI 版本比较必须识别带预发行后缀的新桌面核心。'
$currentNpmPolicy = Get-CodexCliOverridePolicy -OverridePath $npmCliPath -OverrideVersion '0.151.0' `
    -OfficialCliPath 'C:\official\codex.exe' -OfficialCliVersion '0.151.0-alpha.7.2' -RestoredOriginalPath $null
Assert-True (-not $currentNpmPolicy.ClearOverride) '不落后于桌面核心的官方 npm CLI 不得被清除。'
$customCliPath = 'C:\custom-codex\codex.exe'
$customPolicy = Get-CodexCliOverridePolicy -OverridePath $customCliPath -OverrideVersion '0.100.0' `
    -OfficialCliPath 'C:\official\codex.exe' -OfficialCliVersion '0.151.0-alpha.7.2' -RestoredOriginalPath $null
Assert-True (-not $customPolicy.ClearOverride) '任意用户自定义 CLI 即使版本较旧也必须保留。'
$restoredPolicy = Get-CodexCliOverridePolicy -OverridePath $customCliPath -OverrideVersion '0.100.0' `
    -OfficialCliPath 'C:\official\codex.exe' -OfficialCliVersion '0.151.0-alpha.7.2' -RestoredOriginalPath $customCliPath
Assert-True $restoredPolicy.ClearOverride '旧补丁刚恢复且已确认落后的原值必须清除。'

$legacyCleanupTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-legacy-cli-cleanup-' + [Guid]::NewGuid().ToString('N'))
$originalInstallRoot = $InstallRoot
$originalLegacyCliCompatRoot = $LegacyCliCompatRoot
$originalLegacyDesktopCliRoot = $LegacyDesktopCliRoot
$originalLegacyDesktopCliPath = $LegacyDesktopCliPath
$originalLegacyDesktopCliEnvironmentBackupPath = $LegacyDesktopCliEnvironmentBackupPath
try {
    $InstallRoot = $legacyCleanupTestRoot
    $LegacyCliCompatRoot = Join-Path $InstallRoot 'cli-compat'
    $LegacyDesktopCliRoot = Join-Path $InstallRoot 'desktop-cli'
    $LegacyDesktopCliPath = Join-Path $LegacyDesktopCliRoot 'codex.exe'
    $LegacyDesktopCliEnvironmentBackupPath = Join-Path $LegacyDesktopCliRoot 'environment-backup.json'
    New-Item -ItemType Directory -Path $LegacyCliCompatRoot, $LegacyDesktopCliRoot -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $LegacyCliCompatRoot 'obsolete.txt'), 'obsolete')
    [IO.File]::WriteAllText($LegacyDesktopCliPath, 'obsolete')
    $legacyOrphanPath = Join-Path $LegacyDesktopCliRoot '.codex.exe-0123456789abcdef0123456789abcdef.bak'
    $unmanagedBackupPath = Join-Path $LegacyDesktopCliRoot '.notes.bak'
    [IO.File]::WriteAllText($legacyOrphanPath, 'orphan')
    [IO.File]::WriteAllText($unmanagedBackupPath, 'preserve')

    $orphanCleanup = Remove-CodexLegacyDesktopCliOrphans
    Assert-True ($orphanCleanup.RemovedCount -eq 1) '旧同步器的未占用事务备份必须按严格格式回收。'
    Assert-True (-not (Test-Path -LiteralPath $legacyOrphanPath)) '已确认的旧事务备份不得残留。'
    Assert-True (Test-Path -LiteralPath $unmanagedBackupPath -PathType Leaf) '不匹配旧同步器命名格式的文件必须保留。'

    $legacyCleanup = Invoke-CodexLegacyCliCleanupSafely
    Assert-True $legacyCleanup.Complete '无人占用且不再被环境引用的旧 CLI 目录必须完整回收。'
    Assert-True $legacyCleanup.ArchiveCompatRemoved '旧归档兼容目录必须被删除。'
    Assert-True $legacyCleanup.DesktopCliRemoved '旧桌面 CLI 镜像必须被删除。'
}
finally {
    $InstallRoot = $originalInstallRoot
    $LegacyCliCompatRoot = $originalLegacyCliCompatRoot
    $LegacyDesktopCliRoot = $originalLegacyDesktopCliRoot
    $LegacyDesktopCliPath = $originalLegacyDesktopCliPath
    $LegacyDesktopCliEnvironmentBackupPath = $originalLegacyDesktopCliEnvironmentBackupPath
    if (Test-Path -LiteralPath $legacyCleanupTestRoot -PathType Container) {
        Remove-Item -LiteralPath $legacyCleanupTestRoot -Recurse -Force
    }
}
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
$fallbackConfigText = Convert-CodexTransportConfigText -ExistingText $installedConfigText -Action Fallback
Assert-True ($fallbackConfigText.Contains('model_provider = "openai"')) '兼容兜底必须恢复原 model_provider。'
Assert-True ($fallbackConfigText.Contains('[model_providers.codex-hotpatch-http]')) '兼容兜底必须保留旧任务依赖的 provider 定义。'
Assert-True ($fallbackConfigText -notmatch '(?m)^\s*model_provider\s*=\s*"codex-hotpatch-http"\s*$') '兼容兜底不得继续选择热补丁 provider。'
$refallbackConfigText = Convert-CodexTransportConfigText -ExistingText $fallbackConfigText -Action Fallback
Assert-True ($refallbackConfigText -eq $fallbackConfigText) '兼容兜底配置必须幂等。'
$orphanProviderConfigText = $configText.TrimEnd() + @"


[model_providers.codex-hotpatch-http]
name = "OpenAI HTTP (Codex hotpatch)"
wire_api = "responses"
requires_openai_auth = true
supports_websockets = false
supports_standalone_web_search = true
request_max_retries = 6
stream_max_retries = 8
"@
$adoptedProviderConfigText = Convert-CodexTransportConfigText -ExistingText $orphanProviderConfigText -Action Install
Assert-True ((@($adoptedProviderConfigText -split "`r?`n" | Where-Object { $_.Trim() -eq '[model_providers.codex-hotpatch-http]' }).Count) -eq 1) '安装必须接管完全匹配的无标记兼容定义，不能生成重复 provider。'
Assert-True ($adoptedProviderConfigText.Contains($TransportProviderStart)) '接管无标记兼容定义后必须补齐托管标记。'
$conflictingOrphanRejected = $false
try {
    Convert-CodexTransportConfigText -ExistingText ($orphanProviderConfigText -replace 'stream_max_retries = 8', 'stream_max_retries = 99') -Action Install | Out-Null
}
catch {
    $conflictingOrphanRejected = $true
}
Assert-True $conflictingOrphanRejected '内容不一致的无标记 provider 必须 fail-closed，不能覆盖用户配置。'
$detachedConfigText = [regex]::Replace(
    $installedConfigText,
    '(?ms)^# BEGIN CodexNetworkProxyHotpatch transport selector\r?\n.*?^# END CodexNetworkProxyHotpatch transport selector\r?\n',
    "model_provider = `"$TransportProviderId`"$([Environment]::NewLine)"
)
$recoveryState = [pscustomobject]@{
    OriginalProviderWasAbsent = $false
    OriginalProviderLine = 'model_provider = "openai"'
}
$repairedDetachedConfigText = Convert-CodexTransportConfigText -ExistingText $detachedConfigText `
    -Action Install -RecoveryState $recoveryState
Assert-True ($repairedDetachedConfigText.Contains($TransportSelectorStart)) '更新剥离选择器标记后，独立恢复状态必须能重建托管选择器。'
Assert-True ((@($repairedDetachedConfigText -split "`r?`n" | Where-Object { $_.Trim() -eq '[model_providers.codex-hotpatch-http]' }).Count) -eq 1) '修复更新迁移后不得复制 provider。'
$fallbackDetachedConfigText = Convert-CodexTransportConfigText -ExistingText $detachedConfigText `
    -Action Fallback -RecoveryState $recoveryState
Assert-True ($fallbackDetachedConfigText.Contains('model_provider = "openai"')) '更新剥离选择器标记后，官方兜底必须使用独立状态恢复原 provider。'
$removedDetachedConfigText = Convert-CodexTransportConfigText -ExistingText $detachedConfigText `
    -Action Remove -RecoveryState $recoveryState
Assert-True ($removedDetachedConfigText.Contains('model_provider = "openai"')) '更新剥离选择器标记后，卸载必须使用独立状态恢复原 provider。'
Assert-True ($removedDetachedConfigText -notmatch 'CodexNetworkProxyHotpatch|codex-hotpatch-http') '更新剥离选择器标记后，卸载不得残留托管 provider。'
$detachedWithoutStateRejected = $false
try {
    Convert-CodexTransportConfigText -ExistingText $detachedConfigText -Action Install | Out-Null
}
catch {
    $detachedWithoutStateRejected = $true
}
Assert-True $detachedWithoutStateRejected '选择器被剥离且没有独立恢复状态时必须 fail-closed。'
$detachedProviderDriftRejected = $false
try {
    $driftedDetachedConfigText = $detachedConfigText -replace 'model_provider = "codex-hotpatch-http"', 'model_provider = "custom"'
    Convert-CodexTransportConfigText -ExistingText $driftedDetachedConfigText `
        -Action Install -RecoveryState $recoveryState | Out-Null
}
catch {
    $detachedProviderDriftRejected = $true
}
Assert-True $detachedProviderDriftRejected '更新后用户另行选择 provider 时不得由恢复状态覆盖。'
$damagedSelectorConfigText = [regex]::Replace(
    $installedConfigText,
    '(?m)^# BEGIN CodexNetworkProxyHotpatch transport selector\r?\n^# original-model-provider-base64:.*\r?\n',
    ''
)
$repairedDamagedSelectorText = Convert-CodexTransportConfigText -ExistingText $damagedSelectorConfigText `
    -Action Install -RecoveryState $recoveryState
Assert-True ((@($repairedDamagedSelectorText -split "`r?`n" | Where-Object { $_.Trim() -eq $TransportSelectorStart }).Count) -eq 1) '更新只剥离选择器起始标记时必须精确重建一次。'
Assert-True ((@($repairedDamagedSelectorText -split "`r?`n" | Where-Object { $_.Trim() -eq $TransportSelectorEnd }).Count) -eq 1) '重建不应保留孤立的选择器结束标记。'
Assert-True ((@($repairedDamagedSelectorText -split "`r?`n" | Where-Object { $_.Trim() -eq '[model_providers.codex-hotpatch-http]' }).Count) -eq 1) '重建损坏选择器不得复制 provider。'
$damagedSelectorWithoutStateRejected = $false
try {
    Convert-CodexTransportConfigText -ExistingText $damagedSelectorConfigText -Action Install | Out-Null
}
catch {
    $damagedSelectorWithoutStateRejected = $true
}
Assert-True $damagedSelectorWithoutStateRejected '孤立选择器标记没有独立恢复状态时必须 fail-closed。'
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

$originalTransportStatePath = $TransportStatePath
$TransportStatePath = Join-Path ([IO.Path]::GetTempPath()) ("codex-hotpatch-transport-state-test-$PID.json")
try {
    Write-CodexTransportRecoveryState -OriginalProviderLine 'model_provider = "openai"' -OriginalProviderWasAbsent $false
    $loadedRecoveryState = Get-CodexTransportRecoveryState
    Assert-True ($loadedRecoveryState.OriginalProviderLine -eq 'model_provider = "openai"') '独立恢复状态必须无损保存原 model_provider。'
    [IO.File]::WriteAllText($TransportStatePath, '{"SchemaVersion":99}', [Text.UTF8Encoding]::new($false))
    $corruptRecoveryStateRejected = $false
    try { Get-CodexTransportRecoveryState | Out-Null } catch { $corruptRecoveryStateRejected = $true }
    Assert-True $corruptRecoveryStateRejected '损坏的独立恢复状态必须 fail-closed。'
}
finally {
    if (Test-Path -LiteralPath $TransportStatePath -PathType Leaf) { [IO.File]::Delete($TransportStatePath) }
    $TransportStatePath = $originalTransportStatePath
}

$originalCodexEnvPath = $CodexEnvPath
$originalNetworkHealthPath = $NetworkHealthPath
$originalVpnProbeIntervalMilliseconds = $VpnProbeIntervalMilliseconds
$CodexEnvPath = Join-Path ([IO.Path]::GetTempPath()) ("codex-hotpatch-network-test-$PID.env")
$NetworkHealthPath = Join-Path ([IO.Path]::GetTempPath()) ("codex-hotpatch-network-health-test-$PID.json")
$VpnProbeIntervalMilliseconds = 0
try {
    $stableRouteBoundaryUtc = [DateTimeOffset]::Parse('2026-08-17T02:00:00Z').UtcDateTime
    $stableHealthText = [ordered]@{
        Version = 3
        CircuitState = 'Closed'
        ConsecutiveFailures = 0
        WindowStartedUtc = $null
        LastFailureUtc = $null
        LastFailureReason = $null
        LastFailureKind = 'Unknown'
        RetryAfterUtc = $null
        LastSuccessUtc = $stableRouteBoundaryUtc.ToString('o')
        RuntimeFailureCount = 0
        LastRuntimeFailureUtc = $null
    } | ConvertTo-Json -Compress
    [IO.File]::WriteAllText($NetworkHealthPath, $stableHealthText, [Text.UTF8Encoding]::new($false))
    $stableRecheck = Register-VpnHealthSuccess
    Assert-True ($stableRecheck.LastSuccessUtc -eq $stableRouteBoundaryUtc) '普通健康复检不得移动已稳定显式线路的成功边界。'

    $script:testProxyUri = [Uri]'http://127.0.0.1:57777'
    function Resolve-CodexNetworkMode {
        return [pscustomobject]@{
            NetworkMode = 'VpnProxy'
            Reason = 'test VPN listener ready'
            ProxyUri = $script:testProxyUri
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
            ResponsesEndpointHealthy = $ProviderHealthy
            ResponsesEndpointStatusCode = if ($ProviderHealthy) { 405 } else { $null }
            ResponsesEndpointError = if ($ProviderHealthy) { $null } else { 'simulated unauthenticated timeout' }
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
    function Invoke-CodexNativeAuthenticatedFallbackProbe {
        $script:authenticatedProbeCount += 1
        return $script:authenticatedProbeResult
    }
    function Invoke-CodexExplicitAuthenticatedProbe {
        param([Parameter(Mandatory = $true)][Uri]$ProxyUri)

        $script:explicitAuthenticatedProbeCount += 1
        $script:lastExplicitAuthenticatedProxyUri = $ProxyUri.AbsoluteUri.TrimEnd('/')
        return $script:explicitAuthenticatedProbeResult
    }
    $script:NativeAuthenticatedFallbackCache = $null
    $script:ExplicitAuthenticatedProbeCache = $null
    $script:authenticatedProbeCount = 0
    $script:explicitAuthenticatedProbeCount = 0
    $script:lastExplicitAuthenticatedProxyUri = $null
    $script:authenticatedProbeResult = [pscustomobject]@{
        Healthy = $true
        Completed = $true
        ExitCode = 0
        DurationMs = 6500
        ReconnectSignals = 0
        TransportErrors = 0
        Error = $null
    }
    $script:explicitAuthenticatedProbeResult = $script:authenticatedProbeResult

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

    # The explicit route gets the same authenticated false-negative verdict and a proxy-keyed cache.
    $script:ExplicitAuthenticatedProbeCache = $null
    $script:explicitAuthenticatedProbeCount = 0
    $script:doctorProbeCount = 0
    $script:doctorProbeResults = @(
        (New-TestProbe -ProviderHealthy $false -WebSocketHealthy $true -ProviderStatus 'ok')
    )
    $authenticatedExplicitSelection = Sync-CodexProxyEnv -VerifyRemote
    Assert-True ($authenticatedExplicitSelection.NetworkMode -eq 'VpnExplicitHttps') '显式无凭据 GET 假阴性时，登录态 HTTPS/SSE 成功必须保留显式线路。'
    Assert-True $authenticatedExplicitSelection.RouteHealthy '登录态裁决成功的显式线路必须报告健康。'
    Assert-True ($authenticatedExplicitSelection.ExplicitVerificationMode -eq 'Authenticated') '显式线路首次真实探测必须报告 Authenticated。'
    Assert-True ($authenticatedExplicitSelection.ExplicitAuthenticatedProbe.Healthy) '显式线路必须保留登录态探测证据。'
    Assert-True ($script:explicitAuthenticatedProbeCount -eq 1) '显式矛盾门禁只能触发一次登录态探测。'
    Assert-True ($script:lastExplicitAuthenticatedProxyUri -eq 'http://127.0.0.1:57777') '显式登录态探测必须使用实际候选代理 URI。'
    $explicitCacheRemaining = $script:ExplicitAuthenticatedProbeCache.ExpiresUtc - [DateTime]::UtcNow
    Assert-True ($explicitCacheRemaining.TotalSeconds -gt 110 -and $explicitCacheRemaining.TotalSeconds -le 120) '显式登录态结果必须使用两分钟短时缓存。'
    $doctorVerification = Get-CodexSelectedAuthenticatedVerification -Selection $authenticatedExplicitSelection
    Assert-True ($doctorVerification.Route -eq 'VpnExplicitHttps') 'Doctor 必须读取实际选中的显式线路裁决。'
    Assert-True ($doctorVerification.Mode -eq 'Authenticated') 'Doctor 必须展示显式线路的登录态裁决模式。'
    Assert-True ($doctorVerification.Probe.Healthy) 'Doctor 必须展示显式线路的登录态探测结果。'
    $rawDoctorFailProbe = [pscustomobject]@{ DoctorOverallStatus = 'fail' }
    Assert-True ((Get-CodexNetworkDoctorOverallStatus -Selection $authenticatedExplicitSelection `
        -Probe $rawDoctorFailProbe -AuthenticatedHealthy $true) -eq 'ok (authenticated HTTPS/SSE)') '登录态路由健康时不得继承无关 Codex Doctor 的 fail 总状态。'
    $passiveHealthySelection = [pscustomobject]@{ RouteHealthy = $true }
    Assert-True ((Get-CodexNetworkDoctorOverallStatus -Selection $passiveHealthySelection `
        -Probe $rawDoctorFailProbe -AuthenticatedHealthy $null) -eq 'ok (HTTPS/SSE)') '被动路由健康时 Doctor 必须报告 HTTPS/SSE 正常。'
    $unhealthyRouteSelection = [pscustomobject]@{ RouteHealthy = $false }
    Assert-True ((Get-CodexNetworkDoctorOverallStatus -Selection $unhealthyRouteSelection `
        -Probe $rawDoctorFailProbe -AuthenticatedHealthy $null) -eq 'fail') '路由失败时必须保留底层 Doctor 失败状态。'

    $script:doctorProbeCount = 0
    $script:doctorProbeResults = @(
        (New-TestProbe -ProviderHealthy $false -WebSocketHealthy $true -ProviderStatus 'ok')
    )
    $cachedExplicitSelection = Sync-CodexProxyEnv -VerifyRemote
    Assert-True ($cachedExplicitSelection.ExplicitVerificationMode -eq 'AuthenticatedCache') '同一代理 URI 必须复用两分钟登录态缓存。'
    Assert-True ($script:explicitAuthenticatedProbeCount -eq 1) '同一代理 URI 的缓存窗口内不得重复真实请求。'

    $script:testProxyUri = [Uri]'http://127.0.0.1:57778'
    $script:doctorProbeCount = 0
    $script:doctorProbeResults = @(
        (New-TestProbe -ProviderHealthy $false -WebSocketHealthy $true -ProviderStatus 'ok')
    )
    $newProxyExplicitSelection = Sync-CodexProxyEnv -VerifyRemote
    Assert-True ($newProxyExplicitSelection.ExplicitVerificationMode -eq 'Authenticated') '代理 URI 变化后必须重新执行真实登录态探测。'
    Assert-True ($script:explicitAuthenticatedProbeCount -eq 2) '显式登录态缓存必须以代理 URI 为键。'
    Assert-True ($script:lastExplicitAuthenticatedProxyUri -eq 'http://127.0.0.1:57778') '代理 URI 变化后必须验证新候选线路。'
    $script:testProxyUri = [Uri]'http://127.0.0.1:57777'

    $emptyExplicitFailure = [pscustomobject]@{
        Healthy = $false
        Completed = $false
        ExitCode = 1
        DurationMs = 45000
        ReconnectSignals = 1
        TransportErrors = 2
        Error = $null
    }
    $emptyExplicitFailureSummary = Get-CodexAuthenticatedProbeFailureSummary -Probe $emptyExplicitFailure
    Assert-True ($emptyExplicitFailureSummary -match 'exit=1') '显式探测 Error 为空时必须回退到退出码摘要。'
    Assert-True ($emptyExplicitFailureSummary -match 'reconnect=1') '显式探测 Error 为空时必须保留重连计数。'
    Assert-True ($emptyExplicitFailureSummary -match 'transport=2') '显式探测 Error 为空时必须保留传输错误计数。'

    # A diagnostic tool failure must not increase health failures or claim both routes failed.
    $beforeUnavailableState = [IO.File]::ReadAllText($NetworkHealthPath)
    $unavailableProbe = New-TestProbe -ProviderHealthy $false -WebSocketHealthy $false
    $unavailableProbe.Available = $false
    $unavailableProbe.Error = 'official CLI unavailable'
    $script:doctorProbeCount = 0
    $script:doctorProbeResults = @($unavailableProbe, $unavailableProbe)
    $unavailableSelection = Sync-CodexProxyEnv -VerifyRemote
    Assert-True ($null -eq $unavailableSelection.RouteHealthy) 'Unavailable diagnostics must leave route health unknown.'
    Assert-True ($unavailableSelection.Reason -notmatch '两条.*均未通过') 'Untested routes must not be described as two failed routes.'
    Assert-True ([IO.File]::ReadAllText($NetworkHealthPath) -eq $beforeUnavailableState) 'Unavailable diagnostics must preserve existing circuit history.'

    & {
        function Test-CodexExplicitProxyEnabled { return $false }
        $script:doctorProbeCount = 0
        $selection = Sync-CodexProxyEnv
        Assert-True ($selection.NetworkMode -eq 'VpnNativeHttps' -and $script:doctorProbeCount -eq 0) 'Unverified sync must never restore an opted-out explicit route.'
        $script:doctorProbeResults = @(
            (New-TestProbe -ProviderHealthy $true -WebSocketHealthy $false),
            (New-TestProbe -ProviderHealthy $true -WebSocketHealthy $false)
        )
        $selection = Sync-CodexProxyEnv -VerifyRemote -AllowEarlyRecovery
        Assert-True ($selection.NetworkMode -eq 'VpnNativeHttps' -and $script:doctorProbeCount -eq 2) 'Even early recovery must probe only native when explicit is disabled.'
        Assert-True ($selection.Reason -match '用户已停用') 'Opt-out reason must remain visible.'
        Assert-True ([IO.File]::ReadAllText($CodexEnvPath) -notmatch 'HTTPS_PROXY|ALL_PROXY') 'Opt-out must leave no managed proxy keys.'
    }

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

    # Route selection and Doctor must use the same authenticated verdict as runtime failover.
    $script:NativeAuthenticatedFallbackCache = $null
    $script:authenticatedProbeCount = 0
    $script:doctorProbeCount = 0
    $script:doctorProbeResults = @(
        (New-TestProbe -ProviderHealthy $false -WebSocketHealthy $true -ProviderStatus 'ok')
    )
    $authenticatedNativeSelection = Sync-CodexProxyEnv -VerifyRemote -ForceNative
    Assert-True $authenticatedNativeSelection.RouteHealthy '无凭据 GET 假阴性时，登录态 HTTPS/SSE 成功必须让 Doctor 与安装选择报告健康。'
    Assert-True ($authenticatedNativeSelection.NativeVerificationMode -eq 'Authenticated') '路由选择必须暴露登录态裁决模式。'
    Assert-True ($authenticatedNativeSelection.NativeAuthenticatedProbe.Healthy) '路由选择必须保留登录态探测证据。'
    Assert-True ($script:authenticatedProbeCount -eq 1) '路由选择的矛盾门禁只能触发一次登录态探测。'

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

    # Alternate-route checks are temporary and must restore the exact prepared route.
    $explicitBeforeFallbackProbe = [IO.File]::ReadAllBytes($CodexEnvPath)
    $script:doctorProbeCount = 0
    $script:doctorProbeResults = @(
        (New-TestProbe -ProviderHealthy $false -WebSocketHealthy $false)
    )
    $unhealthyNativeFallback = Invoke-CodexNativeFallbackProbeSeries
    Assert-True (-not $unhealthyNativeFallback.Stable) '不可用原生线路不得被报告为可接管。'
    $explicitAfterFallbackProbe = [IO.File]::ReadAllBytes($CodexEnvPath)
    Assert-True ([Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
        $explicitBeforeFallbackProbe,
        $explicitAfterFallbackProbe
    )) '原生备用探测结束后必须逐字节恢复原显式代理环境。'

    # A passive false negative may be overruled only by a real authenticated HTTPS/SSE probe.
    $script:NativeAuthenticatedFallbackCache = $null
    $script:authenticatedProbeCount = 0
    $script:authenticatedProbeResult = [pscustomobject]@{
        Healthy = $true
        Completed = $true
        ExitCode = 0
        DurationMs = 6500
        ReconnectSignals = 0
        TransportErrors = 0
        Error = $null
    }
    $script:doctorProbeCount = 0
    $script:doctorProbeResults = @(
        (New-TestProbe -ProviderHealthy $false -WebSocketHealthy $true -ProviderStatus 'ok')
    )
    $explicitBeforeAuthenticatedProbe = [IO.File]::ReadAllBytes($CodexEnvPath)
    $authenticatedNativeFallback = Invoke-CodexNativeFallbackVerification
    Assert-True $authenticatedNativeFallback.Stable '被动 GET 假阴性后，真实登录态 HTTPS/SSE 成功必须允许原生线路接管。'
    Assert-True ($authenticatedNativeFallback.VerificationMode -eq 'Authenticated') '首次真实探测必须报告 Authenticated。'
    Assert-True ($script:authenticatedProbeCount -eq 1) '矛盾门禁只能触发一次真实登录态探测。'
    $explicitAfterAuthenticatedProbe = [IO.File]::ReadAllBytes($CodexEnvPath)
    Assert-True ([Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
        $explicitBeforeAuthenticatedProbe,
        $explicitAfterAuthenticatedProbe
    )) '真实登录态原生探测结束后必须逐字节恢复原显式代理环境。'

    $script:doctorProbeCount = 0
    $script:doctorProbeResults = @(
        (New-TestProbe -ProviderHealthy $false -WebSocketHealthy $true -ProviderStatus 'ok')
    )
    $cachedNativeFallback = Invoke-CodexNativeFallbackVerification
    Assert-True $cachedNativeFallback.Stable '短时缓存中的成功登录态探测必须继续允许接管。'
    Assert-True ($cachedNativeFallback.VerificationMode -eq 'AuthenticatedCache') '重复矛盾门禁必须使用短时缓存。'
    Assert-True ($script:authenticatedProbeCount -eq 1) '缓存窗口内不得重复消耗真实登录态请求。'

    $script:NativeAuthenticatedFallbackCache = $null
    $script:authenticatedProbeCount = 0
    $script:authenticatedProbeResult = [pscustomobject]@{
        Healthy = $false
        Completed = $false
        ExitCode = 1
        DurationMs = 45000
        ReconnectSignals = 1
        TransportErrors = 1
        Error = 'simulated authenticated failure'
    }
    $script:doctorProbeCount = 0
    $script:doctorProbeResults = @(
        (New-TestProbe -ProviderHealthy $false -WebSocketHealthy $true -ProviderStatus 'ok')
    )
    $failedAuthenticatedFallback = Invoke-CodexNativeFallbackVerification
    Assert-True (-not $failedAuthenticatedFallback.Stable) '真实登录态 HTTPS/SSE 失败时仍不得切换到原生线路。'
    Assert-True ($script:authenticatedProbeCount -eq 1) '真实失败必须留下一个有界探测结果。'

    $script:NativeAuthenticatedFallbackCache = $null
    $script:authenticatedProbeCount = 0
    $script:doctorProbeCount = 0
    $script:doctorProbeResults = @(
        (New-TestProbe -ProviderHealthy $false -WebSocketHealthy $false -ProviderStatus 'error')
    )
    $offlineNativeFallback = Invoke-CodexNativeFallbackVerification
    Assert-True (-not $offlineNativeFallback.Stable) '被动检查一致判定离线时不得误报健康。'
    Assert-True ($script:authenticatedProbeCount -eq 0) '明确离线时不得额外消耗真实登录态请求。'

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
$originalCompatibilityTransportStatePath = $TransportStatePath
$CodexConfigPath = Join-Path ([IO.Path]::GetTempPath()) ("codex-hotpatch-config-compat-test-$PID.toml")
$TransportStatePath = Join-Path ([IO.Path]::GetTempPath()) ("codex-hotpatch-transport-compat-test-$PID.json")
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
    Assert-True ($majorRecoveredText.Contains('[model_providers.codex-hotpatch-http]')) '桌面主版本变化后必须保留旧任务依赖的 provider 定义。'
    Assert-True ($majorRecoveredText -notmatch '(?m)^\s*model_provider\s*=\s*"codex-hotpatch-http"\s*$') '桌面主版本变化后不得继续选择热补丁 provider。'

    [IO.File]::WriteAllText($HttpTransportDisabledPath, 'user opt-out')
    [IO.File]::WriteAllText($CodexConfigPath, $installedConfigText, [Text.UTF8Encoding]::new($false))
    function Get-CodexDesktopCompatibility { throw 'Opt-out must take precedence over compatibility and auto-repair.' }
    $optOutResult = Install-CodexHttpTransport
    $optOutText = [IO.File]::ReadAllText($CodexConfigPath)
    Assert-True (-not $optOutResult.Enabled -and -not $optOutResult.CompatibilityFallback) 'User opt-out is not a compatibility failure.'
    Assert-True ($optOutText -eq $installedConfigText) 'Opt-out must leave current provider and config untouched.'
    Assert-True ($optOutText.Contains('[model_providers.codex-hotpatch-http]')) 'Old tasks must keep their provider definition.'
    Install-CodexHttpTransport | Out-Null
    Assert-True ([IO.File]::ReadAllText($CodexConfigPath) -eq $optOutText) 'Watchdog and repeat installation must not undo opt-out.'

    $userConfigText = 'model_provider = "user-http"'
    [IO.File]::WriteAllText($CodexConfigPath, $userConfigText, [Text.UTF8Encoding]::new($false))
    function Test-CodexConfigLoads { throw 'Disabled transport management must not launch a CLI.' }
    function Write-CodexConfigTextAtomically { throw 'Disabled transport management must not write config.' }
    Install-CodexHttpTransport | Out-Null
    Assert-True ([IO.File]::ReadAllText($CodexConfigPath) -eq $userConfigText) 'Manual provider selection must survive watchdog repair.'
}
finally {
    if (Test-Path -LiteralPath $HttpTransportDisabledPath -PathType Leaf) { [IO.File]::Delete($HttpTransportDisabledPath) }
    if (Test-Path -LiteralPath $CodexConfigPath -PathType Leaf) { [IO.File]::Delete($CodexConfigPath) }
    if (Test-Path -LiteralPath $TransportStatePath -PathType Leaf) { [IO.File]::Delete($TransportStatePath) }
    $CodexConfigPath = $originalCodexConfigPath
    $TransportStatePath = $originalCompatibilityTransportStatePath
}

'manage-hotpatch tests: PASS'
