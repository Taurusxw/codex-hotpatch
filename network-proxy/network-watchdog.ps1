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

function Get-WatchdogTransportIntegritySignature {
    $desktopVersion = Get-CodexDesktopPackageVersion
    $configSignature = if (Test-Path -LiteralPath $CodexConfigPath -PathType Leaf) {
        $item = Get-Item -LiteralPath $CodexConfigPath
        "$($item.Length):$($item.LastWriteTimeUtc.Ticks)"
    }
    else {
        'missing'
    }
    $stateSignature = if (Test-Path -LiteralPath $TransportStatePath -PathType Leaf) {
        $item = Get-Item -LiteralPath $TransportStatePath
        "$($item.Length):$($item.LastWriteTimeUtc.Ticks)"
    }
    else {
        'missing'
    }
    $httpsOnlyDisabled = Test-Path -LiteralPath $HttpTransportDisabledPath -PathType Leaf
    return "$desktopVersion|$configSignature|$stateSignature|$httpsOnlyDisabled"
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

    $nativeFallback = Invoke-CodexNativeFallbackVerification
    if (-not $nativeFallback.Stable) {
        $latestEvent = @($Events | Sort-Object LogId | Select-Object -Last 1)
        $nativeReason = Get-CodexNativeFallbackVerificationReason -Verification $nativeFallback
        if ($latestEvent.Count -gt 0) {
            Write-NetworkWatchdogLog -Message "runtime_event route=explicit log_id=$($latestEvent[0].LogId) core=$($latestEvent[0].ProcessId) action=keep_explicit failover_suppressed=native_unhealthy reason=$nativeReason"
        }
        return $currentState
    }

    $lastState = $null
    foreach ($event in @($Events | Sort-Object LogId)) {
        $reason = "Codex 真实 HTTPS/SSE 长流故障 [$($event.Class)]：$($event.Error)"
        $lastState = Register-VpnHealthFailure -Reason $reason -FailureKind RuntimeStream -Immediate
        Write-NetworkWatchdogLog -Message "runtime_event route=explicit log_id=$($event.LogId) core=$($event.ProcessId) turn=$($event.TurnId) retry=$($event.Retry) class=$($event.Class) circuit=$($lastState.CircuitState) native_verification=$($nativeFallback.VerificationMode)"
        if ($lastState.CircuitState -eq 'Open') { break }
    }
    return $lastState
}

function Test-WatchdogRecoveryDue {
    param(
        [bool]$ExplicitRoutePrepared,
        [Parameter(Mandatory = $true)]$HealthState,
        [DateTime]$LastAttemptUtc = [DateTime]::MinValue,
        [bool]$NativeFailureObserved = $false,
        [DateTime]$NowUtc = [DateTime]::UtcNow
    )
    return (Test-CodexExplicitProxyEnabled) -and -not $ExplicitRoutePrepared -and -not $HealthState.IsCorrupt -and
        ($NowUtc - $LastAttemptUtc).TotalSeconds -ge 120 -and
        ($HealthState.HalfOpenEligible -or $NativeFailureObserved)
}

function Invoke-WatchdogExplicitProbe {
    if (-not (Test-CodexExplicitProxyEnabled)) { return }
    $series = Invoke-CodexDoctorProbeSeries -ProbeCount 1 -ProbeIntervalMilliseconds 0
    $healthy = $series.Stable
    $verificationMode = 'Passive'
    $authenticatedProbe = $null
    if (-not $healthy -and (Test-CodexProbeNeedsAuthenticatedVerification -ProbeSeries $series)) {
        $candidate = Resolve-CodexNetworkMode
        if ($null -ne $candidate.ProxyUri) {
            $verification = Get-CodexExplicitAuthenticatedProbeVerification -ProxyUri $candidate.ProxyUri
            $authenticatedProbe = $verification.Probe
            $healthy = $verification.Probe.Healthy
            $verificationMode = $verification.Mode
        }
    }
    if ($healthy) {
        $state = Get-VpnHealthState
        if ($state.CircuitState -eq 'Closed' -and $state.ConsecutiveFailures -gt 0) {
            Register-VpnHealthSuccess | Out-Null
        }
        Write-NetworkWatchdogLog -Message "probe=ok verification=$verificationMode provider_ms=$($series.LastProbe.ProviderDurationMs)"
        return
    }

    if (-not (Test-CodexProbeHasFailureEvidence -ProbeSeries $series -AuthenticatedProbe $authenticatedProbe)) {
        Write-NetworkWatchdogLog -Message "probe=unavailable action=keep_explicit reason=$(Get-CodexDoctorProbeReason -Probe $series.LastProbe)"
        return
    }
    $reason = "运行期显式 VPN HTTPS 检查失败：$(Get-CodexDoctorProbeReason -Probe $series.LastProbe)"
    $nativeFallback = Invoke-CodexNativeFallbackVerification
    if ($nativeFallback.Stable) {
        $state = Register-VpnHealthFailure -Reason $reason
        Write-NetworkWatchdogLog -Message "probe=failed count=$($state.ConsecutiveFailures) circuit=$($state.CircuitState) native_fallback=healthy verification=$($nativeFallback.VerificationMode) reason=$reason"
        if ($state.CircuitState -eq 'Open') {
            Remove-ManagedCodexProxyEnv
            Write-NetworkWatchdogLog -Message "circuit=open kind=Probe retry_after=$($state.RetryAfterUtc.ToString('o')); prepared verified VPN-native HTTPS for all new processes; current Codex requires one full restart"
        }
    }
    else {
        $nativeReason = Get-CodexNativeFallbackVerificationReason -Verification $nativeFallback
        Write-NetworkWatchdogLog -Message "probe=failed action=keep_explicit failover_suppressed=native_unhealthy explicit_reason=$reason native_reason=$nativeReason"
    }
}

# Dot-sourcing exposes behavior for isolated tests without starting the persistent loop.
if ($MyInvocation.InvocationName -eq '.') { return }

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
    $lastRecoveryAttemptUtc = [DateTime]::MinValue
    $lastNativeEvaluationUtc = [DateTime]::MinValue
    $lastLegacyCliCleanupUtc = [DateTime]::MinValue
    $lastLegacyCliCleanupMessage = $null
    $legacyCliCleanupPending = $true
    $lastCliEnvironmentPolicyCheckUtc = [DateTime]::MinValue
    $lastCliEnvironmentPolicySignature = $null
    $lastTransportIntegrityCheckUtc = [DateTime]::MinValue
    $lastTransportIntegritySignature = $null
    $lastTransportIntegrityError = $null
    $lastCoreRouteAssignmentSignature = $null
    Write-NetworkWatchdogLog -Message "started persistent=$runPersistently probe_interval=${ProbeIntervalSeconds}s runtime_poll=${RuntimePollSeconds}s"
    Write-NetworkWatchdogLog -Message "explicit_proxy_enabled=$(Test-CodexExplicitProxyEnabled)"
    while ($true) {
        if (-not $runPersistently -and $null -eq (Get-Process -Id $RootProcessId -ErrorAction SilentlyContinue)) { break }

        $legacyCleanupNowUtc = [DateTime]::UtcNow
        if ($legacyCliCleanupPending -and
            ($legacyCleanupNowUtc - $lastLegacyCliCleanupUtc).TotalSeconds -ge $ProbeIntervalSeconds) {
            $lastLegacyCliCleanupUtc = $legacyCleanupNowUtc
            $legacyCleanup = Invoke-CodexLegacyCliCleanupSafely
            if ($legacyCleanup.DesktopCliOrphanFilesRemoved -gt 0) {
                Write-NetworkWatchdogLog -Message "legacy_cli_orphans removed=$($legacyCleanup.DesktopCliOrphanFilesRemoved) bytes=$($legacyCleanup.DesktopCliOrphanBytesRemoved)"
            }
            if ($legacyCleanup.Complete) {
                Write-NetworkWatchdogLog -Message "legacy_cli_cleanup=complete environment_restored=$($legacyCleanup.EnvironmentRestored) stale_environment_cleared=$($legacyCleanup.StaleEnvironmentCleared) archive_removed=$($legacyCleanup.ArchiveCompatRemoved) desktop_removed=$($legacyCleanup.DesktopCliRemoved)"
                $legacyCliCleanupPending = $false
                $lastLegacyCliCleanupMessage = $null
            }
            else {
                $cleanupMessage = if ($legacyCleanup.Error) {
                    "error=$($legacyCleanup.Error)"
                }
                elseif ($legacyCleanup.DesktopCliReason) {
                    "pending=$($legacyCleanup.DesktopCliReason)"
                }
                else {
                    'pending=legacy CLI state remains'
                }
                if ($cleanupMessage -ne $lastLegacyCliCleanupMessage) {
                    Write-NetworkWatchdogLog -Message "legacy_cli_cleanup=$cleanupMessage"
                    $lastLegacyCliCleanupMessage = $cleanupMessage
                }
            }
        }

        $cliPolicyNowUtc = [DateTime]::UtcNow
        if (($cliPolicyNowUtc - $lastCliEnvironmentPolicyCheckUtc).TotalSeconds -ge $ProbeIntervalSeconds) {
            $lastCliEnvironmentPolicyCheckUtc = $cliPolicyNowUtc
            $userCliOverride = [Environment]::GetEnvironmentVariable('CODEX_CLI_PATH', 'User')
            $desktopPackageVersion = Get-CodexDesktopPackageVersion
            $cliPolicySignature = "$userCliOverride|$desktopPackageVersion"
            if ($cliPolicySignature -ne $lastCliEnvironmentPolicySignature) {
                $runtimeReady = $false
                try {
                    $runtime = Repair-CodexDesktopRuntimeCache -IncludeNode -IncludeRipgrep
                    $runtimeReady = $true
                    Write-NetworkWatchdogLog -Message "desktop_runtime=ready package=$desktopPackageVersion hash=$($runtime.Hash) repaired=$($runtime.RepairedFiles)"
                    Write-NetworkWatchdogLog -Message "node_runtime=ready hash=$($runtime.NodeRuntime.Hash) repaired=$($runtime.NodeRuntime.RepairedFiles)"
                    Write-NetworkWatchdogLog -Message "ripgrep_runtime=ready hash=$($runtime.RipgrepRuntime.Hash) repaired=$($runtime.RipgrepRuntime.RepairedFiles)"
                }
                catch {
                    Write-NetworkWatchdogLog -Message "desktop_runtime=pending package=$desktopPackageVersion retry_seconds=$ProbeIntervalSeconds reason=$($_.Exception.Message)"
                }
                $cliEnvironmentRepair = Repair-CodexStaleCliEnvironment
                if ($cliEnvironmentRepair.Cleared) {
                    Write-NetworkWatchdogLog -Message "cli_environment action=clear_stale old_version=$($cliEnvironmentRepair.PreviousVersion) official_version=$($cliEnvironmentRepair.OfficialCliVersion)"
                    $userCliOverride = [Environment]::GetEnvironmentVariable('CODEX_CLI_PATH', 'User')
                    $cliPolicySignature = "$userCliOverride|$desktopPackageVersion"
                }
                if ($runtimeReady) { $lastCliEnvironmentPolicySignature = $cliPolicySignature }
            }
        }

        $transportIntegrityNowUtc = [DateTime]::UtcNow
        if (($transportIntegrityNowUtc - $lastTransportIntegrityCheckUtc).TotalSeconds -ge $ProbeIntervalSeconds) {
            $lastTransportIntegrityCheckUtc = $transportIntegrityNowUtc
            $transportIntegritySignature = Get-WatchdogTransportIntegritySignature
            if ($transportIntegritySignature -ne $lastTransportIntegritySignature) {
                try {
                    $transportRepair = Install-CodexHttpTransport
                    $transportStatus = Get-CodexHttpTransportStatus
                    Write-NetworkWatchdogLog -Message "transport_integrity=ok mode=$(if (Test-Path -LiteralPath $HttpTransportDisabledPath -PathType Leaf) { 'user_managed' } elseif ($transportRepair.Enabled) { 'https_only' } else { 'official_fallback' }) detached_selector=$($transportStatus.DetachedSelector) recovery_state=$($transportStatus.RecoveryStateHealthy)"
                    $lastTransportIntegrityError = $null
                }
                catch {
                    $transportIntegrityError = $_.Exception.Message
                    if ($transportIntegrityError -ne $lastTransportIntegrityError) {
                        Write-NetworkWatchdogLog -Message "transport_integrity=blocked reason=$transportIntegrityError"
                        $lastTransportIntegrityError = $transportIntegrityError
                    }
                }
                $lastTransportIntegritySignature = Get-WatchdogTransportIntegritySignature
            }
        }

        $coreProcesses = @(Get-CodexDesktopCoreProcesses)
        $activeCoreProcessIds = @($coreProcesses | ForEach-Object ProcessId)
        $explicitRoutePrepared = Test-WatchdogExplicitRoutePrepared
        $healthState = Get-VpnHealthState
        $coreRouteState = Get-CodexCoreRouteState
        $routeAssignments = @(Get-CodexCoreRouteAssignments -CoreProcesses $coreProcesses `
            -HealthState $healthState -ExplicitRoutePrepared:$explicitRoutePrepared `
            -PersistedAssignments $coreRouteState.Assignments)
        $coreRouteAssignmentSignature = @($routeAssignments | Sort-Object ProcessId | ForEach-Object {
            "$($_.ProcessId):$($_.StartedUtc.Ticks):$($_.Route)"
        }) -join ','
        if ($coreRouteAssignmentSignature -ne $lastCoreRouteAssignmentSignature) {
            Write-CodexCoreRouteState -Assignments $routeAssignments
            $lastCoreRouteAssignmentSignature = $coreRouteAssignmentSignature
            if (-not $coreRouteState.Healthy) {
                Write-NetworkWatchdogLog -Message "core_route_state=recovered reason=$($coreRouteState.Error)"
            }
        }
        $nativeCoreProcessIds = @($routeAssignments | Where-Object Route -eq 'VpnNativeHttps' | ForEach-Object ProcessId)
        $explicitCoreProcessIds = @($routeAssignments | Where-Object Route -eq 'VpnExplicitHttps' | ForEach-Object ProcessId)
        $nativeCoreSignature = (@($nativeCoreProcessIds | Sort-Object) -join ',')
        $nativeEvaluationDue = $nativeCoreProcessIds.Count -gt 0 -and $nativeCoreSignature -ne $lastNativeCoreSignature
        if ($nativeCoreSignature -ne $lastNativeCoreSignature) {
            $lastNativeCoreSignature = $nativeCoreSignature
        }
        $runtimeBatch = Get-CodexRuntimeNetworkEvents `
            -DatabasePath $CodexRuntimeLogsPath `
            -CursorPath $NetworkRuntimeCursorPath `
            -ActiveProcessIds $activeCoreProcessIds `
            -IncludeWebSocket

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
                $explicitRouteEvents = @($runtimeBatch.Events | Where-Object { $explicitSet.Contains([int]$_.ProcessId) })
                $explicitEvents = @($explicitRouteEvents | Where-Object Transport -ne 'WebSocket')
                $explicitWebSocketEvents = @($explicitRouteEvents | Where-Object Transport -eq 'WebSocket')
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
                if ($explicitWebSocketEvents.Count -gt 0) {
                    $latestWebSocket = @($explicitWebSocketEvents | Sort-Object LogId | Select-Object -Last 1)[0]
                    Write-NetworkWatchdogLog -Message "runtime_event route=explicit transport=websocket log_id=$($latestWebSocket.LogId) core=$($latestWebSocket.ProcessId) retry=$($latestWebSocket.Retry)/$($latestWebSocket.MaxRetries) ignored=thread_provider_bound"
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

        $recoveryDue = Test-WatchdogRecoveryDue -ExplicitRoutePrepared $explicitRoutePrepared `
            -HealthState (Get-VpnHealthState) -LastAttemptUtc $lastRecoveryAttemptUtc
        if ($recoveryDue -and (Get-CodexHttpTransportStatus).Selected) {
            $lastRecoveryAttemptUtc = [DateTime]::UtcNow
            $selection = Sync-CodexProxyEnv -VerifyRemote
            $explicitRoutePrepared = $selection.NetworkMode -eq 'VpnExplicitHttps'
            Write-NetworkWatchdogLog -Message "recovery=cooldown_elapsed prepared=$($selection.NetworkMode) healthy=$($selection.RouteHealthy); running core retains its startup route"
        }

        $nativeRetryDue = Test-WatchdogRecoveryDue -ExplicitRoutePrepared $explicitRoutePrepared `
            -HealthState (Get-VpnHealthState) -LastAttemptUtc $lastRecoveryAttemptUtc -NativeFailureObserved:$true
        if ($nativeCoreProcessIds.Count -gt 0 -and -not $explicitRoutePrepared -and
            ($nativeEvaluationDue -or ($lastRecoveryAttemptUtc -ne [DateTime]::MinValue -and $nativeRetryDue -and
                ([DateTime]::UtcNow - $lastNativeEvaluationUtc).TotalSeconds -ge 120))) {
            $lastNativeEvaluationUtc = [DateTime]::UtcNow
            $recentNative = Get-CodexRecentRuntimeNetworkEvents `
                -DatabasePath $CodexRuntimeLogsPath `
                -ActiveProcessIds $nativeCoreProcessIds `
                -IncludeWebSocket `
                -FailureWindow $NativeRuntimeFailureWindow
            if (-not $recentNative.Available) {
                Write-NetworkWatchdogLog -Message "native_runtime_scan=unavailable error=$($recentNative.Error)"
            }
            else {
                $nativeHttpEvents = @($recentNative.Events | Where-Object Transport -eq 'HttpSse')
                $nativeWebSocketEvents = @($recentNative.Events | Where-Object Transport -eq 'WebSocket')
                $nativeUnknownEvents = @($recentNative.Events | Where-Object Transport -eq 'Unknown')
                $degradation = Get-CodexRuntimeNetworkDegradation -Events $nativeHttpEvents `
                    -FailureThreshold $NativeRuntimeFailureThreshold `
                    -FailureWindow $NativeRuntimeFailureWindow
                $webSocketDegradation = Get-CodexRuntimeNetworkDegradation -Events $nativeWebSocketEvents `
                    -FailureThreshold $NativeRuntimeFailureThreshold `
                    -FailureWindow $NativeRuntimeFailureWindow
                Write-NetworkWatchdogLog -Message "native_runtime http_turns=$($degradation.DistinctTurnCount)/$NativeRuntimeFailureThreshold http_events=$($degradation.EventCount) http_exhausted_turns=$($degradation.ExhaustedTurnCount) ws_turns=$($webSocketDegradation.DistinctTurnCount) ws_events=$($webSocketDegradation.EventCount) unknown_events=$($nativeUnknownEvents.Count) failover=$($degradation.FailoverRequired) cores=$nativeCoreSignature"
                if ($degradation.FailoverRequired -and $nativeRetryDue -and (Get-CodexHttpTransportStatus).Selected) {
                    $lastRecoveryAttemptUtc = [DateTime]::UtcNow
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
            Invoke-WatchdogExplicitProbe
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
