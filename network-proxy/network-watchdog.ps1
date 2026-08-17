[CmdletBinding()]
param(
    [ValidateRange(0, [int]::MaxValue)][int]$RootProcessId = 0,
    [ValidateRange(15, 600)][int]$ProbeIntervalSeconds = 45,
    [ValidateRange(2, 60)][int]$RuntimePollSeconds = 5,
    [switch]$Persistent
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'manage-hotpatch.ps1')

$watchdogLogPath = Join-Path $InstallRoot 'network-watchdog.log'
$watchdogPreviousLogPath = Join-Path $InstallRoot 'network-watchdog.previous.log'
$runPersistently = $Persistent -or $RootProcessId -eq 0

function Write-NetworkWatchdogLog {
    param([Parameter(Mandatory = $true)][string]$Message)

    New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
    if ((Test-Path -LiteralPath $watchdogLogPath -PathType Leaf) -and
        (Get-Item -LiteralPath $watchdogLogPath).Length -ge 262144) {
        if (Test-Path -LiteralPath $watchdogPreviousLogPath -PathType Leaf) {
            [IO.File]::Delete($watchdogPreviousLogPath)
        }
        [IO.File]::Move($watchdogLogPath, $watchdogPreviousLogPath)
    }
    $rootLabel = if ($runPersistently) { 'auto' } else { [string]$RootProcessId }
    $line = '{0} root={1} {2}{3}' -f [DateTime]::UtcNow.ToString('o'), $rootLabel, $Message, [Environment]::NewLine
    [IO.File]::AppendAllText($watchdogLogPath, $line, [Text.UTF8Encoding]::new($false))
}

function Test-WatchdogExplicitRoutePrepared {
    $candidate = Resolve-CodexNetworkMode
    if ($candidate.NetworkMode -ne 'VpnProxy' -or $null -eq $candidate.ProxyUri) { return $false }
    $status = Get-CodexProxyEnvStatus -ExpectedProxyUri $candidate.ProxyUri
    return $status.Managed -and $status.Matches
}

function Register-WatchdogExplicitRuntimeEvents {
    param([Parameter(Mandatory = $true)][object[]]$Events)

    $currentState = Get-VpnHealthState
    if ($currentState.CircuitState -eq 'Open' -and $currentState.LastFailureKind -eq 'RuntimeStream') {
        $latestEvent = @($Events | Sort-Object LogId | Select-Object -Last 1)
        if ($latestEvent.Count -gt 0) {
            Write-NetworkWatchdogLog -Message "runtime_event route=explicit log_id=$($latestEvent[0].LogId) core=$($latestEvent[0].ProcessId) ignored=runtime_circuit_already_open"
        }
        return $currentState
    }

    $lastState = $null
    foreach ($event in @($Events | Sort-Object LogId)) {
        $reason = "Codex 真实 HTTPS/SSE 长流故障 [$($event.Class)]：$($event.Error)"
        $lastState = Register-VpnHealthFailure -Reason $reason -FailureKind RuntimeStream -Immediate
        Write-NetworkWatchdogLog -Message "runtime_event route=explicit log_id=$($event.LogId) core=$($event.ProcessId) turn=$($event.TurnId) retry=$($event.Retry) class=$($event.Class) circuit=$($lastState.CircuitState)"
        if ($lastState.CircuitState -eq 'Open') { break }
    }
    return $lastState
}

$mutex = [Threading.Mutex]::new($false, 'Local\CodexNetworkWatchdog-Persistent')
$acquired = $false
try {
    try {
        $acquired = $mutex.WaitOne(0)
    }
    catch [Threading.AbandonedMutexException] {
        $acquired = $true
    }
    if (-not $acquired) { exit 0 }

    $lastProbeUtc = [DateTime]::MinValue
    $lastObserverError = $null
    $lastNativeCoreSignature = $null
    $nativeRecoveryAttemptedSignature = $null
    Write-NetworkWatchdogLog -Message "started persistent=$runPersistently probe_interval=${ProbeIntervalSeconds}s runtime_poll=${RuntimePollSeconds}s"
    while ($true) {
        if (-not $runPersistently -and $null -eq (Get-Process -Id $RootProcessId -ErrorAction SilentlyContinue)) { break }

        $coreProcesses = @(Get-CodexDesktopCoreProcesses)
        $activeCoreProcessIds = @($coreProcesses | ForEach-Object ProcessId)
        $explicitRoutePrepared = Test-WatchdogExplicitRoutePrepared
        $healthState = Get-VpnHealthState
        $routeAssignments = @(Get-CodexCoreRouteAssignments -CoreProcesses $coreProcesses `
            -HealthState $healthState -ExplicitRoutePrepared:$explicitRoutePrepared)
        $nativeCoreProcessIds = @($routeAssignments | Where-Object Route -eq 'VpnNativeHttps' | ForEach-Object ProcessId)
        $explicitCoreProcessIds = @($routeAssignments | Where-Object Route -eq 'VpnExplicitHttps' | ForEach-Object ProcessId)
        $nativeCoreSignature = (@($nativeCoreProcessIds | Sort-Object) -join ',')
        $nativeEvaluationDue = $nativeCoreProcessIds.Count -gt 0 -and $nativeCoreSignature -ne $lastNativeCoreSignature
        if ($nativeCoreSignature -ne $lastNativeCoreSignature) {
            $lastNativeCoreSignature = $nativeCoreSignature
            $nativeRecoveryAttemptedSignature = $null
        }
        $runtimeBatch = Get-CodexRuntimeNetworkEvents `
            -DatabasePath $CodexRuntimeLogsPath `
            -CursorPath $NetworkRuntimeCursorPath `
            -ActiveProcessIds $activeCoreProcessIds `
            -ExpectedMaxRetries $TransportStreamMaxRetries

        if (-not $runtimeBatch.Available) {
            if ($runtimeBatch.Error -ne $lastObserverError) {
                Write-NetworkWatchdogLog -Message "runtime_observer=unavailable error=$($runtimeBatch.Error); short probes remain active"
                $lastObserverError = $runtimeBatch.Error
            }
        }
        else {
            if ($runtimeBatch.CursorRecovered -or $runtimeBatch.ScanTruncated -or $runtimeBatch.Error) {
                Write-NetworkWatchdogLog -Message "runtime_observer=recovered cursor_recovered=$($runtimeBatch.CursorRecovered) scan_truncated=$($runtimeBatch.ScanTruncated) note=$($runtimeBatch.Error)"
            }
            $lastObserverError = $null
            if (@($runtimeBatch.Events).Count -gt 0) {
                $nativeSet = [Collections.Generic.HashSet[int]]::new()
                foreach ($processId in $nativeCoreProcessIds) { [void]$nativeSet.Add([int]$processId) }
                $explicitSet = [Collections.Generic.HashSet[int]]::new()
                foreach ($processId in $explicitCoreProcessIds) { [void]$explicitSet.Add([int]$processId) }
                $nativeEvents = @($runtimeBatch.Events | Where-Object { $nativeSet.Contains([int]$_.ProcessId) })
                $explicitEvents = @($runtimeBatch.Events | Where-Object { $explicitSet.Contains([int]$_.ProcessId) })
                $unknownEvents = @($runtimeBatch.Events | Where-Object {
                    -not $nativeSet.Contains([int]$_.ProcessId) -and -not $explicitSet.Contains([int]$_.ProcessId)
                })
                if ($unknownEvents.Count -gt 0) {
                    $latestUnknown = @($unknownEvents | Sort-Object LogId | Select-Object -Last 1)[0]
                    Write-NetworkWatchdogLog -Message "runtime_event route=unknown log_id=$($latestUnknown.LogId) core=$($latestUnknown.ProcessId) ignored=ambiguous_startup_environment"
                }
                if ($nativeEvents.Count -gt 0) {
                    $nativeEvaluationDue = $true
                }
                $state = if ($explicitEvents.Count -gt 0) {
                    Register-WatchdogExplicitRuntimeEvents -Events $explicitEvents
                }
                else {
                    $null
                }
                if ($null -ne $state -and $state.CircuitState -eq 'Open') {
                    Remove-ManagedCodexProxyEnv
                    Write-NetworkWatchdogLog -Message "circuit=open kind=RuntimeStream runtime_failures=$($state.RuntimeFailureCount) retry_after=$($state.RetryAfterUtc.ToString('o')); prepared VPN-native HTTPS for all new processes; current Codex requires one full restart"
                    $explicitRoutePrepared = $false
                }
            }
        }

        if ($nativeEvaluationDue -and $nativeCoreProcessIds.Count -gt 0 -and
            $nativeRecoveryAttemptedSignature -ne $nativeCoreSignature) {
            $recentNative = Get-CodexRecentRuntimeNetworkEvents `
                -DatabasePath $CodexRuntimeLogsPath `
                -ActiveProcessIds $nativeCoreProcessIds `
                -ExpectedMaxRetries $TransportStreamMaxRetries `
                -FailureWindow $NativeRuntimeFailureWindow
            if (-not $recentNative.Available) {
                Write-NetworkWatchdogLog -Message "native_runtime_scan=unavailable error=$($recentNative.Error)"
            }
            else {
                $degradation = Get-CodexRuntimeNetworkDegradation -Events @($recentNative.Events) `
                    -FailureThreshold $NativeRuntimeFailureThreshold `
                    -FailureWindow $NativeRuntimeFailureWindow
                Write-NetworkWatchdogLog -Message "native_runtime turns=$($degradation.DistinctTurnCount)/$NativeRuntimeFailureThreshold events=$($degradation.EventCount) degraded=$($degradation.Degraded) cores=$nativeCoreSignature"
                if ($degradation.Degraded) {
                    $nativeRecoveryAttemptedSignature = $nativeCoreSignature
                    $selection = Sync-CodexProxyEnv -VerifyRemote -AllowEarlyRecovery
                    if ($selection.NetworkMode -eq 'VpnExplicitHttps' -and $selection.RouteHealthy) {
                        $explicitRoutePrepared = $true
                        $lastProbeUtc = [DateTime]::UtcNow
                        Write-NetworkWatchdogLog -Message "native_runtime=degraded action=prepare_explicit_https probe_count=$RequiredRecoveryVpnProbes median_ms=$($selection.ExplicitProxyMedianMs); current Codex remains native and requires one full restart"
                    }
                    else {
                        $explicitRoutePrepared = $false
                        Write-NetworkWatchdogLog -Message "native_runtime=degraded action=keep_native reason=$($selection.Reason); no verified alternate route, current Codex continues its own retries"
                    }
                }
            }
        }

        $nowUtc = [DateTime]::UtcNow
        if ($explicitRoutePrepared -and $activeCoreProcessIds.Count -gt 0 -and
            ($nowUtc - $lastProbeUtc).TotalSeconds -ge $ProbeIntervalSeconds) {
            $lastProbeUtc = $nowUtc
            $series = Invoke-CodexDoctorProbeSeries -ProbeCount 1 -ProbeIntervalMilliseconds 0
            if ($series.Stable) {
                $state = Get-VpnHealthState
                if ($state.CircuitState -eq 'Closed' -and $state.ConsecutiveFailures -gt 0) {
                    Register-VpnHealthSuccess | Out-Null
                }
                Write-NetworkWatchdogLog -Message "probe=ok provider_ms=$($series.LastProbe.ProviderDurationMs)"
            }
            else {
                $reason = "运行期显式 VPN HTTPS 检查失败：$(Get-CodexDoctorProbeReason -Probe $series.LastProbe)"
                $state = Register-VpnHealthFailure -Reason $reason
                Write-NetworkWatchdogLog -Message "probe=failed count=$($state.ConsecutiveFailures) circuit=$($state.CircuitState) reason=$reason"
                if ($state.CircuitState -eq 'Open') {
                    Remove-ManagedCodexProxyEnv
                    Write-NetworkWatchdogLog -Message "circuit=open kind=Probe retry_after=$($state.RetryAfterUtc.ToString('o')); prepared VPN-native HTTPS for all new processes; current Codex requires one full restart"
                }
            }
        }

        Start-Sleep -Seconds $RuntimePollSeconds
    }
    Write-NetworkWatchdogLog -Message 'stopped because the bound Codex root exited'
}
catch {
    try { Write-NetworkWatchdogLog -Message "watchdog_error=$($_.Exception.Message)" } catch { }
    exit 1
}
finally {
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}

exit 0
