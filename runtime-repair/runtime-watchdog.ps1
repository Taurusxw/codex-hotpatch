[CmdletBinding()]
param(
    [switch]$Once,
    [ValidateRange(15, 3600)][int]$IntervalSeconds = 45,
    [string]$StateRoot
)

if ([string]::IsNullOrWhiteSpace($StateRoot)) { $StateRoot = $PSScriptRoot }
. (Join-Path $PSScriptRoot 'runtime-cache.ps1')

function Get-WatchdogStagedRuntimeSource {
    param(
        [object[]]$Events,
        [string]$RegisteredVersion,
        [string]$PackageRoot
    )

    $registered = [Version]$RegisteredVersion
    foreach ($event in $Events) {
        # AppXDeploymentServer event 400: operation 4 is a completed Stage.
        if ($event.Properties.Count -lt 4 -or [string]$event.Properties[0].Value -ne '4') { continue }
        $name = [string]$event.Properties[1].Value
        if ($name -notmatch '^OpenAI\.Codex_(\d+\.\d+\.\d+\.\d+)_x64__2p2nqsd0c76g0$' -or
            [Version]$Matches[1] -le $registered) { continue }
        $mountPoint = [string]$event.Properties[3].Value
        if ($mountPoint.TrimEnd('\') -ne [IO.Path]::GetPathRoot($PackageRoot).TrimEnd('\')) { continue }
        $source = Join-Path (Join-Path $PackageRoot $name) 'app\resources'
        if (Test-Path -LiteralPath (Join-Path $source 'codex.exe') -PathType Leaf) {
            return [pscustomobject]@{ Name = $name; Source = $source }
        }
    }
    return $null
}

function Write-RuntimeRepairLog {
    param([string]$Message)
    $path = Join-Path $StateRoot 'runtime-watchdog.log'
    if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -ge 262144) {
        $previous = Join-Path $StateRoot 'runtime-watchdog.previous.log'
        if (Test-Path -LiteralPath $previous) { [IO.File]::Delete($previous) }
        [IO.File]::Move($path, $previous)
    }
    [IO.File]::AppendAllText($path, ([DateTime]::UtcNow.ToString('o') + ' ' + $Message + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
}

function Invoke-RuntimeRepairCycle {
    param([Parameter(Mandatory = $true)][hashtable]$State)
    $package = Get-CodexDesktopPackage
    $signature = [string]$package.PackageFullName
    if ($State.RegisteredPackage -ne $signature) {
        $source = Split-Path -Parent (Get-CodexDesktopBundledCliPath -Package $package)
        $runtime = Repair-CodexDesktopRuntimeCache -SourceDirectory $source -IncludeNode -IncludeRipgrep
        $State.RegisteredPackage = $signature
        $State.Runtime = $runtime
        Write-RuntimeRepairLog "registered=ready package=$signature repaired=$($runtime.RepairedFiles),$($runtime.NodeRuntime.RepairedFiles),$($runtime.RipgrepRuntime.RepairedFiles)"
    }
    try {
        # Stage can complete before Appx registration changes; prepare it before restart.
        $events = @(Get-WinEvent -LogName 'Microsoft-Windows-AppXDeploymentServer/Operational' `
            -FilterXPath "*[System[(EventID=400)] and EventData[Data[@Name='DeploymentOperation']='4']]" `
            -MaxEvents 200 -ErrorAction Stop)
        $staged = Get-WatchdogStagedRuntimeSource -Events $events -RegisteredVersion ([string]$package.Version) `
            -PackageRoot (Split-Path -Parent ([string]$package.InstallLocation))
        if ($null -ne $staged -and $State.StagedPackage -ne $staged.Name) {
            $prepared = Repair-CodexDesktopRuntimeCache -SourceDirectory $staged.Source -IncludeNode -IncludeRipgrep
            $State.StagedPackage = $staged.Name
            Write-RuntimeRepairLog "staged=ready package=$($staged.Name) repaired=$($prepared.RepairedFiles),$($prepared.NodeRuntime.RepairedFiles),$($prepared.RipgrepRuntime.RepairedFiles)"
        }
        $State.StageError = $null
    }
    catch {
        # Unavailable deployment logs must not block the registered runtime repair.
        $message = $_.Exception.Message
        if ($message -ne $State.StageError) { Write-RuntimeRepairLog "staged=pending reason=$message" }
        $State.StageError = $message
    }
}

if ($MyInvocation.InvocationName -eq '.') { return }

New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null
$mutex = New-Object Threading.Mutex($false, 'Local\CodexRuntimeRepairWatchdog')
$acquired = $false
try {
    try { $acquired = $mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) { return }
    $state = @{ RegisteredPackage = $null; StagedPackage = $null; Runtime = $null; StageError = $null }
    $lastError = $null
    do {
        $errorMessage = $null
        try { Invoke-RuntimeRepairCycle -State $state }
        catch {
            $errorMessage = $_.Exception.Message
            if ($errorMessage -ne $lastError) { Write-RuntimeRepairLog "registered=pending reason=$errorMessage" }
        }
        $lastError = $errorMessage
        $status = [ordered]@{
            Version = '1.0.0'; ProcessId = $PID; CheckedAtUtc = [DateTime]::UtcNow.ToString('o')
            Ready = ($null -eq $errorMessage -and $null -ne $state.Runtime)
            RegisteredPackage = $state.RegisteredPackage; StagedPackage = $state.StagedPackage
            Runtime = $state.Runtime; Error = $errorMessage; StageError = $state.StageError
        }
        $statusPath = Join-Path $StateRoot 'runtime-status.json'
        $temporary = $statusPath + '.tmp'
        [IO.File]::WriteAllText($temporary, ($status | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $statusPath) { [IO.File]::Replace($temporary, $statusPath, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $statusPath) }
        if ($Once) { if (-not $status.Ready) { throw $errorMessage }; break }
        Start-Sleep -Seconds $IntervalSeconds
    } while ($true)
}
finally {
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
