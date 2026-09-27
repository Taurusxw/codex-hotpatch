$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'runtime-watchdog.ps1')
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

& {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('codex-staged-runtime-' + [Guid]::NewGuid().ToString('N'))
    $name = 'OpenAI.Codex_26.917.8451.0_x64__2p2nqsd0c76g0'
    $source = Join-Path (Join-Path $root $name) 'app\resources'
    try {
        New-Item -ItemType Directory -Path $source -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $source 'codex.exe'), 'fixture')
        function New-StageEvent { param($Operation, $PackageName, $MountPoint)
            return [pscustomobject]@{ Properties = @(
                [pscustomobject]@{ Value = $Operation },
                [pscustomobject]@{ Value = $PackageName },
                [pscustomobject]@{ Value = '' },
                [pscustomobject]@{ Value = $MountPoint }
            ) }
        }
        $mountPoint = [IO.Path]::GetPathRoot($root).TrimEnd('\')
        $register = New-StageEvent 1 $name $mountPoint
        $wrongVolume = New-StageEvent 4 $name 'Z:'
        $stage = New-StageEvent 4 $name $mountPoint
        $candidate = Get-WatchdogStagedRuntimeSource -Events @($register, $wrongVolume, $stage) `
            -RegisteredVersion '26.917.6896.0' -PackageRoot $root
        Assert-True ($candidate.Name -eq $name -and $candidate.Source -eq $source) 'Completed Stage must select only the newer package on the current volume.'
        Assert-True ($null -eq (Get-WatchdogStagedRuntimeSource -Events @($stage) `
            -RegisteredVersion '26.917.8451.0' -PackageRoot $root)) 'Registered package is not a pending update.'
        [IO.File]::Delete((Join-Path $source 'codex.exe'))
        Assert-True ($null -eq (Get-WatchdogStagedRuntimeSource -Events @($stage) `
            -RegisteredVersion '26.917.6896.0' -PackageRoot $root)) 'Incomplete staged package must not be prepared.'
    }
    finally {
        $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\codex-staged-runtime-'
        if (-not ([IO.Path]::GetFullPath($root)).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe staged fixture cleanup path.' }
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

& {
    $script:testVersion = '26.924.2738.0'
    $script:repairCalls = 0
    $script:testStaged = $null
    $script:failRepair = $false
    $script:failEvents = $false
    function Get-CodexDesktopPackage {
        return [pscustomobject]@{ Version = $script:testVersion; PackageFullName = "OpenAI.Codex_$script:testVersion"; InstallLocation = 'C:\fixture\package' }
    }
    function Get-CodexDesktopBundledCliPath { param($Package) return 'C:\fixture\package\app\resources\codex.exe' }
    function Get-WinEvent {
        param($LogName, $FilterXPath, $MaxEvents, $ErrorAction)
        if ($script:failEvents) { throw 'Deployment log unavailable' }
        return @()
    }
    function Get-WatchdogStagedRuntimeSource { param($Events, $RegisteredVersion, $PackageRoot) return $script:testStaged }
    function Write-RuntimeRepairLog { param($Message) }
    function Repair-CodexDesktopRuntimeCache {
        param($SourceDirectory, [switch]$IncludeNode, [switch]$IncludeRipgrep)
        $script:repairCalls++
        Assert-True ($IncludeNode -and $IncludeRipgrep) 'Every preparation must cover CLI, Node and search.'
        if ($script:failRepair) { throw 'Retryable fixture lock' }
        return [pscustomobject]@{ RepairedFiles = 0; NodeRuntime = [pscustomobject]@{ RepairedFiles = 0 }; RipgrepRuntime = [pscustomobject]@{ RepairedFiles = 0 } }
    }
    $state = @{ RegisteredPackage = $null; StagedPackage = $null; Runtime = $null; StageError = $null }
    Invoke-RuntimeRepairCycle $state
    Assert-True ($script:repairCalls -eq 1 -and $null -ne $state.Runtime) 'Initial registered runtime must be prepared.'
    Invoke-RuntimeRepairCycle $state
    Assert-True ($script:repairCalls -eq 1) 'Idle polling must not rehash an unchanged runtime.'
    $script:testStaged = [pscustomobject]@{ Name = 'newer-staged'; Source = 'C:\fixture\next' }
    $script:failRepair = $true
    Invoke-RuntimeRepairCycle $state
    Assert-True ($null -eq $state.StagedPackage -and $null -ne $state.StageError) 'Failed staging must remain retryable.'
    $script:failRepair = $false
    Invoke-RuntimeRepairCycle $state
    Assert-True ($state.StagedPackage -eq 'newer-staged' -and $null -eq $state.StageError) 'Staging must recover on the next cycle.'
    Invoke-RuntimeRepairCycle $state
    Assert-True ($script:repairCalls -eq 3) 'Prepared staged runtime must not be copied repeatedly.'
    $previous = $state.RegisteredPackage
    $script:testVersion = '26.925.1000.0'
    $script:failRepair = $true
    $failed = $false
    try { Invoke-RuntimeRepairCycle $state } catch { $failed = $true }
    Assert-True ($failed -and $state.RegisteredPackage -eq $previous) 'A failed update must not be reported prepared.'
    $script:failRepair = $false
    $script:failEvents = $true
    Invoke-RuntimeRepairCycle $state
    Assert-True ($state.RegisteredPackage -ne $previous -and $null -ne $state.StageError) 'Registered update repair must work even if staging logs are unavailable.'
}
Write-Output 'runtime-watchdog tests passed'
