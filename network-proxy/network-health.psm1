Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-CodexUtcDate {
    param([AllowNull()]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    return [DateTime]::Parse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    )
}

function New-CodexNetworkCircuitState {
    param(
        [ValidateSet('Closed', 'Open')][string]$CircuitState = 'Closed',
        [int]$ConsecutiveFailures = 0,
        [AllowNull()][Nullable[DateTime]]$WindowStartedUtc = $null,
        [AllowNull()][Nullable[DateTime]]$LastFailureUtc = $null,
        [AllowNull()][string]$LastFailureReason = $null,
        [ValidateSet('Probe', 'RuntimeStream', 'Unknown')][string]$LastFailureKind = 'Unknown',
        [AllowNull()][Nullable[DateTime]]$RetryAfterUtc = $null,
        [AllowNull()][Nullable[DateTime]]$LastSuccessUtc = $null,
        [int]$RuntimeFailureCount = 0,
        [AllowNull()][Nullable[DateTime]]$LastRuntimeFailureUtc = $null,
        [bool]$IsCorrupt = $false,
        [DateTime]$NowUtc = [DateTime]::UtcNow
    )

    $now = $NowUtc.ToUniversalTime()
    $retryAfter = if ($null -ne $RetryAfterUtc) { $RetryAfterUtc.ToUniversalTime() } else { $null }
    $open = $CircuitState -eq 'Open'
    return [pscustomobject]@{
        Version = 3
        CircuitState = $CircuitState
        ConsecutiveFailures = $ConsecutiveFailures
        WindowStartedUtc = if ($null -ne $WindowStartedUtc) { $WindowStartedUtc.ToUniversalTime() } else { $null }
        LastFailureUtc = if ($null -ne $LastFailureUtc) { $LastFailureUtc.ToUniversalTime() } else { $null }
        LastFailureReason = $LastFailureReason
        LastFailureKind = $LastFailureKind
        RetryAfterUtc = $retryAfter
        LastSuccessUtc = if ($null -ne $LastSuccessUtc) { $LastSuccessUtc.ToUniversalTime() } else { $null }
        RuntimeFailureCount = $RuntimeFailureCount
        LastRuntimeFailureUtc = if ($null -ne $LastRuntimeFailureUtc) { $LastRuntimeFailureUtc.ToUniversalTime() } else { $null }
        IsCorrupt = $IsCorrupt
        SuppressExplicit = $IsCorrupt -or ($open -and $null -ne $retryAfter -and $retryAfter -gt $now)
        HalfOpenEligible = -not $IsCorrupt -and $open -and $null -ne $retryAfter -and $retryAfter -le $now
    }
}

function Get-CodexNetworkCircuitStateCore {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][DateTime]$NowUtc
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return New-CodexNetworkCircuitState -NowUtc $NowUtc
    }

    try {
        $raw = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
        $version = if ($null -ne $raw.PSObject.Properties['Version']) { [int]$raw.Version } else { 1 }
        if ($version -eq 1) {
            $legacyFailureUtc = ConvertTo-CodexUtcDate -Value $raw.LastVpnFailureUtc
            return New-CodexNetworkCircuitState `
                -CircuitState Closed `
                -ConsecutiveFailures $(if ($null -ne $legacyFailureUtc) { 1 } else { 0 }) `
                -WindowStartedUtc $legacyFailureUtc `
                -LastFailureUtc $legacyFailureUtc `
                -LastFailureReason ([string]$raw.LastVpnFailureReason) `
                -LastFailureKind Probe `
                -NowUtc $NowUtc
        }
        if ($version -notin @(2, 3)) { throw "不支持的网络健康状态版本：$version" }

        $circuitState = [string]$raw.CircuitState
        if ($circuitState -notin @('Closed', 'Open')) { throw 'CircuitState 无效。' }
        $failureCount = [int]$raw.ConsecutiveFailures
        if ($failureCount -lt 0) { throw 'ConsecutiveFailures 无效。' }
        $lastFailureKind = if ($version -eq 3 -and $null -ne $raw.PSObject.Properties['LastFailureKind']) {
            [string]$raw.LastFailureKind
        }
        else {
            'Probe'
        }
        if ($lastFailureKind -notin @('Probe', 'RuntimeStream', 'Unknown')) { throw 'LastFailureKind 无效。' }
        $runtimeFailureCount = if ($version -eq 3 -and $null -ne $raw.PSObject.Properties['RuntimeFailureCount']) {
            [int]$raw.RuntimeFailureCount
        }
        else {
            0
        }
        if ($runtimeFailureCount -lt 0) { throw 'RuntimeFailureCount 无效。' }
        $retryAfterUtc = ConvertTo-CodexUtcDate -Value $raw.RetryAfterUtc
        if ($circuitState -eq 'Open' -and $null -eq $retryAfterUtc) { throw 'Open 状态缺少 RetryAfterUtc。' }

        return New-CodexNetworkCircuitState `
            -CircuitState $circuitState `
            -ConsecutiveFailures $failureCount `
            -WindowStartedUtc (ConvertTo-CodexUtcDate -Value $raw.WindowStartedUtc) `
            -LastFailureUtc (ConvertTo-CodexUtcDate -Value $raw.LastFailureUtc) `
            -LastFailureReason ([string]$raw.LastFailureReason) `
            -LastFailureKind $lastFailureKind `
            -RetryAfterUtc $retryAfterUtc `
            -LastSuccessUtc (ConvertTo-CodexUtcDate -Value $raw.LastSuccessUtc) `
            -RuntimeFailureCount $runtimeFailureCount `
            -LastRuntimeFailureUtc $(if ($version -eq 3) { ConvertTo-CodexUtcDate -Value $raw.LastRuntimeFailureUtc } else { $null }) `
            -NowUtc $NowUtc
    }
    catch {
        return New-CodexNetworkCircuitState `
            -CircuitState Open `
            -ConsecutiveFailures 0 `
            -LastFailureUtc $NowUtc `
            -LastFailureReason "网络健康状态损坏：$($_.Exception.Message)" `
            -LastFailureKind Unknown `
            -IsCorrupt $true `
            -NowUtc $NowUtc
    }
}

function Get-CodexNetworkMutexName {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalized = [IO.Path]::GetFullPath($Path).ToUpperInvariant()
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized))
    }
    finally {
        $sha.Dispose()
    }
    return 'Local\CodexNetworkCircuit-' + ([BitConverter]::ToString($hash).Replace('-', '').Substring(0, 24))
}

function Invoke-WithCodexNetworkMutex {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    $mutex = [Threading.Mutex]::new($false, (Get-CodexNetworkMutexName -Path $Path))
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds(5))
        }
        catch [Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) { throw '等待网络健康状态互斥锁超时。' }
        return & $Action
    }
    finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Write-CodexNetworkCircuitStateCore {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$State
    )

    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $record = [ordered]@{
        Version = 3
        CircuitState = $State.CircuitState
        ConsecutiveFailures = [int]$State.ConsecutiveFailures
        WindowStartedUtc = if ($null -ne $State.WindowStartedUtc) { $State.WindowStartedUtc.ToUniversalTime().ToString('o') } else { $null }
        LastFailureUtc = if ($null -ne $State.LastFailureUtc) { $State.LastFailureUtc.ToUniversalTime().ToString('o') } else { $null }
        LastFailureReason = $State.LastFailureReason
        LastFailureKind = $State.LastFailureKind
        RetryAfterUtc = if ($null -ne $State.RetryAfterUtc) { $State.RetryAfterUtc.ToUniversalTime().ToString('o') } else { $null }
        LastSuccessUtc = if ($null -ne $State.LastSuccessUtc) { $State.LastSuccessUtc.ToUniversalTime().ToString('o') } else { $null }
        RuntimeFailureCount = [int]$State.RuntimeFailureCount
        LastRuntimeFailureUtc = if ($null -ne $State.LastRuntimeFailureUtc) { $State.LastRuntimeFailureUtc.ToUniversalTime().ToString('o') } else { $null }
    }
    $text = $record | ConvertTo-Json -Compress
    $nonce = [Guid]::NewGuid().ToString('N')
    $tempPath = "$Path.$nonce.tmp"
    $backupPath = "$Path.$nonce.bak"
    try {
        [IO.File]::WriteAllText($tempPath, $text, [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [IO.File]::Replace($tempPath, $Path, $backupPath)
        }
        else {
            [IO.File]::Move($tempPath, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) { [IO.File]::Delete($tempPath) }
        if (Test-Path -LiteralPath $backupPath -PathType Leaf) { [IO.File]::Delete($backupPath) }
    }
}

function Get-CodexNetworkCircuitState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [DateTime]$NowUtc = [DateTime]::UtcNow
    )

    $now = $NowUtc.ToUniversalTime()
    return Invoke-WithCodexNetworkMutex -Path $Path -Action {
        Get-CodexNetworkCircuitStateCore -Path $Path -NowUtc $now
    }
}

function Update-CodexNetworkCircuitState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('Success', 'Failure')][string]$Outcome,
        [string]$Reason,
        [ValidateSet('Probe', 'RuntimeStream')][string]$FailureKind = 'Probe',
        [ValidateRange(1, 20)][int]$FailureThreshold = 2,
        [TimeSpan]$FailureWindow = ([TimeSpan]::FromMinutes(10)),
        [TimeSpan]$OpenCooldown = ([TimeSpan]::FromMinutes(30)),
        [TimeSpan]$RuntimeFailureDecay = ([TimeSpan]::FromDays(7)),
        [TimeSpan]$RuntimeFailureMaxCooldown = ([TimeSpan]::FromDays(7)),
        [DateTime]$NowUtc = [DateTime]::UtcNow
    )

    if ($FailureWindow -le [TimeSpan]::Zero) { throw 'FailureWindow 必须大于零。' }
    if ($OpenCooldown -le [TimeSpan]::Zero) { throw 'OpenCooldown 必须大于零。' }
    if ($RuntimeFailureDecay -le [TimeSpan]::Zero) { throw 'RuntimeFailureDecay 必须大于零。' }
    if ($RuntimeFailureMaxCooldown -lt $OpenCooldown) { throw 'RuntimeFailureMaxCooldown 不得小于 OpenCooldown。' }
    if ($Outcome -eq 'Failure' -and [string]::IsNullOrWhiteSpace($Reason)) { throw '登记失败必须提供原因。' }

    $now = $NowUtc.ToUniversalTime()
    return Invoke-WithCodexNetworkMutex -Path $Path -Action {
        $current = Get-CodexNetworkCircuitStateCore -Path $Path -NowUtc $now
        if ($Outcome -eq 'Success') {
            $next = New-CodexNetworkCircuitState `
                -CircuitState Closed `
                -ConsecutiveFailures 0 `
                -LastFailureUtc $(if ($current.IsCorrupt) { $null } else { $current.LastFailureUtc }) `
                -LastFailureReason $(if ($current.IsCorrupt) { $null } else { $current.LastFailureReason }) `
                -LastFailureKind $(if ($current.IsCorrupt) { 'Unknown' } else { $current.LastFailureKind }) `
                -LastSuccessUtc $now `
                -RuntimeFailureCount $(if ($current.IsCorrupt) { 0 } else { $current.RuntimeFailureCount }) `
                -LastRuntimeFailureUtc $(if ($current.IsCorrupt) { $null } else { $current.LastRuntimeFailureUtc }) `
                -NowUtc $now
            Write-CodexNetworkCircuitStateCore -Path $Path -State $next
            return $next
        }

        if ($current.IsCorrupt) {
            $failureCount = $FailureThreshold
            $windowStarted = $now
        }
        elseif ($null -ne $current.LastFailureUtc -and
            $now -ge $current.LastFailureUtc -and
            ($now - $current.LastFailureUtc) -le $FailureWindow) {
            $failureCount = [Math]::Max(1, [int]$current.ConsecutiveFailures + 1)
            $windowStarted = if ($null -ne $current.WindowStartedUtc) { $current.WindowStartedUtc } else { $current.LastFailureUtc }
        }
        else {
            $failureCount = 1
            $windowStarted = $now
        }

        $runtimeFailureCount = [int]$current.RuntimeFailureCount
        $lastRuntimeFailureUtc = $current.LastRuntimeFailureUtc
        $effectiveCooldown = $OpenCooldown
        if ($FailureKind -eq 'RuntimeStream') {
            if ($null -eq $lastRuntimeFailureUtc -or $now -lt $lastRuntimeFailureUtc -or
                ($now - $lastRuntimeFailureUtc) -gt $RuntimeFailureDecay) {
                $runtimeFailureCount = 1
            }
            else {
                $runtimeFailureCount = [Math]::Max(1, $runtimeFailureCount + 1)
            }
            $lastRuntimeFailureUtc = $now
            $multiplier = [Math]::Pow(2, [Math]::Min(20, $runtimeFailureCount - 1))
            $cooldownTicks = [Math]::Min(
                [double]$RuntimeFailureMaxCooldown.Ticks,
                [double]$OpenCooldown.Ticks * $multiplier
            )
            $effectiveCooldown = [TimeSpan]::FromTicks([long]$cooldownTicks)
        }

        $shouldOpen = $current.CircuitState -eq 'Open' -or $failureCount -ge $FailureThreshold
        $retryAfter = if ($shouldOpen) {
            $candidateRetryAfter = $now.Add($effectiveCooldown)
            if ($current.CircuitState -eq 'Open' -and $null -ne $current.RetryAfterUtc -and
                $current.RetryAfterUtc -gt $candidateRetryAfter) {
                $current.RetryAfterUtc
            }
            else {
                $candidateRetryAfter
            }
        }
        else {
            $null
        }
        $next = New-CodexNetworkCircuitState `
            -CircuitState $(if ($shouldOpen) { 'Open' } else { 'Closed' }) `
            -ConsecutiveFailures $failureCount `
            -WindowStartedUtc $windowStarted `
            -LastFailureUtc $now `
            -LastFailureReason $Reason `
            -LastFailureKind $FailureKind `
            -RetryAfterUtc $retryAfter `
            -LastSuccessUtc $current.LastSuccessUtc `
            -RuntimeFailureCount $runtimeFailureCount `
            -LastRuntimeFailureUtc $lastRuntimeFailureUtc `
            -NowUtc $now
        Write-CodexNetworkCircuitStateCore -Path $Path -State $next
        return $next
    }
}

Export-ModuleMember -Function Get-CodexNetworkCircuitState, Update-CodexNetworkCircuitState
