$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'network-watchdog.ps1')
$ExplicitProxyDisabledPath = Join-Path ([IO.Path]::GetTempPath()) ('codex-watchdog-optout-test-' + [Guid]::NewGuid().ToString('N'))
$HttpTransportDisabledPath = Join-Path ([IO.Path]::GetTempPath()) ('codex-watchdog-http-optout-test-' + [Guid]::NewGuid().ToString('N'))

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

& {
    function Get-CodexDesktopPackageVersion { return '26.908.9136.0' }
    $CodexConfigPath = $HttpTransportDisabledPath + '.missing-config'
    $TransportStatePath = $HttpTransportDisabledPath + '.missing-state'
    $before = Get-WatchdogTransportIntegritySignature
    try {
        [IO.File]::WriteAllText($HttpTransportDisabledPath, 'user opt-out')
        Assert-True ((Get-WatchdogTransportIntegritySignature) -ne $before) 'Changing transport opt-out must trigger the existing integrity check.'
    }
    finally { [IO.File]::Delete($HttpTransportDisabledPath) }
}

& {
    function Write-NetworkWatchdogLog { param($Message) }
    function Invoke-CodexDoctorProbeSeries {
        param($ProbeCount, $ProbeIntervalMilliseconds)
        return [pscustomobject]@{
            Stable = $false
            LastProbe = [pscustomobject]@{
                Available = $true; ProviderStatus = 'ok'; WebSocketHealthy = $false
                ResponsesEndpointHealthy = $false; ProviderDurationMs = 5000
                ProviderHealthy = $false; WebSocketStatus = 'fail'
            }
        }
    }
    function Resolve-CodexNetworkMode { return [pscustomobject]@{ ProxyUri = [Uri]'http://127.0.0.1:57777' } }
    function Get-VpnHealthState { return [pscustomobject]@{ CircuitState = 'Closed'; ConsecutiveFailures = 0 } }
    function Get-CodexExplicitAuthenticatedProbeVerification {
        param($ProxyUri)
        return [pscustomobject]@{ Mode = 'Authenticated'; Probe = [pscustomobject]@{ Healthy = $true } }
    }
    function Invoke-CodexNativeFallbackVerification { throw 'Healthy authenticated primary must not probe/switch to native.' }
    function Register-VpnHealthFailure { throw 'False-negative passive check must not trip the circuit.' }
    Invoke-WatchdogExplicitProbe

    function Get-CodexExplicitAuthenticatedProbeVerification {
        param($ProxyUri)
        return [pscustomobject]@{ Mode = 'Authenticated'; Probe = [pscustomobject]@{ Healthy = $false } }
    }
    function Invoke-CodexNativeFallbackVerification { return [pscustomobject]@{ Stable = $true; VerificationMode = 'Passive' } }
    function Register-VpnHealthFailure {
        param($Reason)
        return [pscustomobject]@{ ConsecutiveFailures = 2; CircuitState = 'Open'; RetryAfterUtc = [DateTime]::UtcNow.AddMinutes(30) }
    }
    $script:testRouteRemoved = $false
    function Remove-ManagedCodexProxyEnv { $script:testRouteRemoved = $true }
    Invoke-WatchdogExplicitProbe
    Assert-True $script:testRouteRemoved 'Verified primary failure with a healthy fallback must prepare native.'

    function Invoke-CodexDoctorProbeSeries {
        param($ProbeCount, $ProbeIntervalMilliseconds)
        return [pscustomobject]@{
            Stable = $false
            LastProbe = [pscustomobject]@{
                Available = $false; ProviderHealthy = $false; ResponsesEndpointHealthy = $false
                DoctorAvailable = $false; DiagnosticCliAvailable = $false; Error = 'CLI unavailable'
            }
        }
    }
    function Register-VpnHealthFailure { throw 'Unavailable diagnostic must not change circuit history.' }
    function Invoke-CodexNativeFallbackVerification { throw 'Unavailable diagnostic must not trigger speculative failover.' }
    function Remove-ManagedCodexProxyEnv { throw 'Unavailable diagnostic must preserve the prepared route.' }
    Invoke-WatchdogExplicitProbe
}

$now = [DateTime]::UtcNow
$state = [pscustomobject]@{ IsCorrupt = $false; HalfOpenEligible = $true }
Assert-True (Test-WatchdogRecoveryDue -HealthState $state -ExplicitRoutePrepared:$false -NowUtc $now) 'Expired circuit must recover without new runtime errors.'
Assert-True (-not (Test-WatchdogRecoveryDue -HealthState $state -ExplicitRoutePrepared:$true -NowUtc $now)) 'Prepared explicit route must not be probed as native recovery.'
Assert-True (-not (Test-WatchdogRecoveryDue -HealthState $state -LastAttemptUtc $now.AddSeconds(-119) -NowUtc $now)) 'Recovery must respect its two-minute retry interval.'
$state.HalfOpenEligible = $false
Assert-True (-not (Test-WatchdogRecoveryDue -HealthState $state -NowUtc $now)) 'A healthy native route must not bypass a still-open circuit.'
Assert-True (Test-WatchdogRecoveryDue -HealthState $state -NativeFailureObserved:$true -LastAttemptUtc $now.AddSeconds(-121) -NowUtc $now) 'Ongoing native failure must permit another bounded recovery attempt.'
$state.IsCorrupt = $true
Assert-True (-not (Test-WatchdogRecoveryDue -HealthState $state -NativeFailureObserved:$true -NowUtc $now)) 'Corrupt history must not permit speculative recovery.'

& {
    function Test-CodexExplicitProxyEnabled { return $false }
    function Invoke-CodexDoctorProbeSeries { throw 'Disabled explicit route must never be probed.' }
    $eligible = [pscustomobject]@{ IsCorrupt = $false; HalfOpenEligible = $true }
    Assert-True (-not (Test-WatchdogRecoveryDue -HealthState $eligible -NowUtc $now)) 'Expired cooldown must not override user opt-out.'
    Assert-True (-not (Test-WatchdogRecoveryDue -HealthState $eligible -NativeFailureObserved:$true -NowUtc $now)) 'Native degradation must not override user opt-out.'
    Invoke-WatchdogExplicitProbe
}

'network-watchdog tests: PASS'
