[CmdletBinding()]
param(
    [ValidateSet('Install', 'Uninstall', 'RunOnce', 'Watch', 'Status')]
    [string]$Mode = 'Status',
    [ValidateRange(2, 60)]
    [int]$PollSeconds = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SupervisorVersion = '1.0.3'
$HotpatchRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\hotpatches'
$InstallRoot = Join-Path $HotpatchRoot 'ui-hotpatch-supervisor'
$InstalledManager = Join-Path $InstallRoot 'manage-hotpatch.ps1'
$StartupDirectory = [Environment]::GetFolderPath('Startup')
$StartupLink = Join-Path $StartupDirectory 'CodexUiHotpatchSupervisor.lnk'
$SupervisorLog = Join-Path $InstallRoot 'supervisor.log'
$SupervisorPreviousLog = Join-Path $InstallRoot 'supervisor.previous.log'
$SupervisorMutexName = 'Local\CodexUiHotpatchSupervisor'
$script:RetryStates = @{}

function Get-ManagedComponentDefinitions {
    param(
        [string]$Root = $HotpatchRoot,
        [string]$StartupRoot = $StartupDirectory
    )

    return @(
        [pscustomobject]@{
            Name = 'sidebar-archive-filter'
            ManagerPath = Join-Path $Root 'sidebar-archive-filter\manage-hotpatch.ps1'
            InjectorPath = Join-Path $Root 'sidebar-archive-filter\codex-sidebar-archive-filter-hotpatch.mjs'
            StartupPath = Join-Path $StartupRoot 'CodexSidebarArchiveFilterHotpatch.lnk'
        }
        [pscustomobject]@{
            Name = 'subagent-status'
            ManagerPath = Join-Path $Root 'subagent-status\manage-hotpatch.ps1'
            InjectorPath = Join-Path $Root 'subagent-status\codex-subagent-status-hotpatch.mjs'
            StartupPath = Join-Path $StartupRoot 'CodexSubagentStatusHotpatch.lnk'
        }
    )
}

function Test-ManagedComponentInstalled {
    param([Parameter(Mandatory = $true)]$Component)

    return (Test-Path -LiteralPath $Component.ManagerPath -PathType Leaf) -and
        (Test-Path -LiteralPath $Component.InjectorPath -PathType Leaf) -and
        (Test-Path -LiteralPath $Component.StartupPath -PathType Leaf)
}

function Get-UiHotpatchProcessSnapshot {
    return @(
        Get-CimInstance -ClassName Win32_Process `
            -Filter "Name='powershell.exe' OR Name='pwsh.exe' OR Name='node.exe' OR Name='ChatGPT.exe'" `
            -OperationTimeoutSec 4 -ErrorAction Stop
    )
}

function Test-WatchProcessMatch {
    param(
        [Parameter(Mandatory = $true)]$Process,
        [Parameter(Mandatory = $true)][string]$ManagerPath
    )

    return $Process.Name -in @('powershell.exe', 'pwsh.exe') -and
        -not [string]::IsNullOrWhiteSpace([string]$Process.CommandLine) -and
        $Process.CommandLine -like "*$ManagerPath*" -and
        $Process.CommandLine -match '(?i)-Mode\s+Watch(?:\s|$)'
}

function Test-InjectorProcessMatch {
    param(
        [Parameter(Mandatory = $true)]$Process,
        [Parameter(Mandatory = $true)][string]$InjectorPath
    )

    return $Process.Name -eq 'node.exe' -and
        -not [string]::IsNullOrWhiteSpace([string]$Process.CommandLine) -and
        $Process.CommandLine -like "*$InjectorPath*" -and
        $Process.CommandLine -match '(?i)--watch-port\s+\d+'
}

function Get-ManagedComponentRuntimeState {
    param(
        [Parameter(Mandatory = $true)]$Component,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Processes
    )

    $watchers = @($Processes | Where-Object {
        Test-WatchProcessMatch -Process $_ -ManagerPath $Component.ManagerPath
    })
    $injectors = @($Processes | Where-Object {
        Test-InjectorProcessMatch -Process $_ -InjectorPath $Component.InjectorPath
    })
    $watcherProcessIds = @($watchers | Select-Object -ExpandProperty ProcessId)
    $orphanInjectorProcessIds = @($injectors | Where-Object {
        $parentProcessId = if ($_.PSObject.Properties['ParentProcessId']) {
            [int]$_.ParentProcessId
        }
        else {
            0
        }
        $parentProcessId -notin $watcherProcessIds
    } | Select-Object -ExpandProperty ProcessId)
    $injectorPorts = @($injectors | ForEach-Object {
        if ($_.CommandLine -match '(?i)--watch-port\s+(\d+)') { [int]$Matches[1] }
    } | Sort-Object -Unique)
    return [pscustomobject]@{
        Name = $Component.Name
        Installed = Test-ManagedComponentInstalled -Component $Component
        WatcherRunning = $watchers.Count -gt 0
        WatcherProcessIds = $watcherProcessIds
        InjectorRunning = $injectors.Count -gt 0
        InjectorProcessIds = @($injectors | Select-Object -ExpandProperty ProcessId)
        InjectorPorts = $injectorPorts
        OrphanInjectorProcessIds = $orphanInjectorProcessIds
        ManagerPath = $Component.ManagerPath
    }
}

function Get-RetryDelaySeconds {
    param([ValidateRange(0, 30)][int]$FailureCount)

    if ($FailureCount -le 0) { return 0 }
    return [int][Math]::Min(60, 2 * [Math]::Pow(2, $FailureCount - 1))
}

function Get-ObservedCodexDebugPorts {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Processes)

    return @($Processes | Where-Object {
        $_.Name -eq 'ChatGPT.exe' -and $_.CommandLine -and $_.CommandLine -notmatch '--type='
    } | ForEach-Object {
        if ($_.CommandLine -match '--remote-debugging-port=(\d+)') { [int]$Matches[1] }
    } | Sort-Object -Unique)
}

function Read-ManagedComponentRendererStatus {
    param(
        [Parameter(Mandatory = $true)][string]$InjectorPath,
        [Parameter(Mandatory = $true)][int]$Port
    )

    $node = Get-Command 'node.exe' -ErrorAction SilentlyContinue
    if (-not $node) { $node = Get-Command 'node' -ErrorAction SilentlyContinue }
    if (-not $node) { throw 'Node.js is unavailable for renderer status.' }
    $output = & $node.Source $InjectorPath '--status' $Port 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "renderer status exited with code ${LASTEXITCODE}: $($output -join ' ')"
    }
    return $output | ConvertFrom-Json
}

function Get-ManagedComponentRendererState {
    param(
        [Parameter(Mandatory = $true)]$Component,
        [int[]]$Ports = @(),
        [scriptblock]$StatusReader
    )

    $activePorts = @($Ports | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
    if ($activePorts.Count -eq 0) {
        return [pscustomobject]@{
            RendererCheckAttempted = $false
            RendererInstalled = $null
            RendererState = 'NoActiveInjectorPort'
            RendererPorts = @()
            RendererPatchedPages = 0
            RendererError = ''
        }
    }

    $checkedPorts = @()
    $patchedPages = 0
    $errors = @()
    foreach ($port in $activePorts) {
        try {
            $status = if ($StatusReader) {
                & $StatusReader $Component.InjectorPath $port
            }
            else {
                Read-ManagedComponentRendererStatus -InjectorPath $Component.InjectorPath -Port $port
            }
            $targets = @($status.targets)
            $patched = @($targets | Where-Object { $_.result -and $_.result.installed }).Count
            $checkedPorts += $port
            $patchedPages += $patched
            if ($patched -gt 0) { continue }
            if ($targets.Count -eq 0) { $errors += "port ${port}: no renderer target" }
            else { $errors += "port ${port}: renderer not installed" }
        }
        catch {
            $errors += "port ${port}: $($_.Exception.Message)"
        }
    }

    $installed = $patchedPages -gt 0
    return [pscustomobject]@{
        RendererCheckAttempted = $true
        RendererInstalled = $installed
        RendererState = if ($installed) { 'Installed' } elseif ($checkedPorts.Count -gt 0) { 'NotInstalled' } else { 'StatusError' }
        RendererPorts = $activePorts
        RendererPatchedPages = $patchedPages
        RendererError = $errors -join '; '
    }
}

function Write-SupervisorLog {
    param([Parameter(Mandatory = $true)][string]$Message)

    New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
    if ((Test-Path -LiteralPath $SupervisorLog -PathType Leaf) -and
        (Get-Item -LiteralPath $SupervisorLog).Length -gt 1048576) {
        if (Test-Path -LiteralPath $SupervisorPreviousLog -PathType Leaf) {
            [IO.File]::Delete($SupervisorPreviousLog)
        }
        [IO.File]::Move($SupervisorLog, $SupervisorPreviousLog)
    }
    $line = '{0} {1}{2}' -f [DateTime]::UtcNow.ToString('o'), $Message, [Environment]::NewLine
    [IO.File]::AppendAllText($SupervisorLog, $line, [Text.UTF8Encoding]::new($false))
}

function Get-SupervisorProcesses {
    param([object[]]$Processes = $(Get-UiHotpatchProcessSnapshot))

    return @($Processes | Where-Object {
        Test-WatchProcessMatch -Process $_ -ManagerPath $InstalledManager
    })
}

function Wait-ManagedComponentWatcherReady {
    param(
        [Parameter(Mandatory = $true)]$Component,
        [ValidateRange(500, 15000)][int]$TimeoutMilliseconds = 5000,
        [ValidateRange(100, 2000)][int]$StabilityMilliseconds = 500
    )

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $processes = Get-UiHotpatchProcessSnapshot
        $state = Get-ManagedComponentRuntimeState -Component $Component -Processes $processes
        if ($state.WatcherRunning) {
            $watcherId = [int]$state.WatcherProcessIds[0]
            Start-Sleep -Milliseconds $StabilityMilliseconds
            $confirmation = Get-ManagedComponentRuntimeState -Component $Component `
                -Processes (Get-UiHotpatchProcessSnapshot)
            if ($confirmation.WatcherProcessIds -contains $watcherId) { return $confirmation }
        }
        Start-Sleep -Milliseconds 100
    }
    throw "组件 watcher 未能稳定启动：$($Component.Name)"
}

function Start-ManagedComponentWatcher {
    param([Parameter(Mandatory = $true)]$Component)

    $componentRoot = Split-Path -Parent $Component.ManagerPath
    $outputLog = Join-Path $componentRoot 'watch.log'
    $errorLog = Join-Path $componentRoot 'watch.err.log'
    $powerShellPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $arguments = @(
        '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
        '-File', ('"' + $Component.ManagerPath + '"'), '-Mode', 'Watch'
    )
    Start-Process -FilePath $powerShellPath -ArgumentList $arguments -WindowStyle Hidden `
        -WorkingDirectory $componentRoot -RedirectStandardOutput $outputLog `
        -RedirectStandardError $errorLog | Out-Null
    return Wait-ManagedComponentWatcherReady -Component $Component
}

function Stop-OrphanComponentInjectors {
    param(
        [Parameter(Mandatory = $true)]$Component,
        [Parameter(Mandatory = $true)]$State
    )

    $stopped = @()
    foreach ($processId in @($State.OrphanInjectorProcessIds)) {
        $candidate = Get-CimInstance Win32_Process -Filter "ProcessId=$processId" `
            -OperationTimeoutSec 3 -ErrorAction SilentlyContinue
        if (-not $candidate -or
            -not (Test-InjectorProcessMatch -Process $candidate `
                -InjectorPath $Component.InjectorPath)) {
            continue
        }
        Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
        $stopped += [int]$processId
    }
    if ($stopped.Count -gt 0) {
        $deadline = [DateTime]::UtcNow.AddSeconds(3)
        while ([DateTime]::UtcNow -lt $deadline) {
            $remaining = @(Get-UiHotpatchProcessSnapshot | Where-Object {
                $_.ProcessId -in $stopped
            })
            if ($remaining.Count -eq 0) { break }
            Start-Sleep -Milliseconds 100
        }
    }
    return $stopped
}

function Repair-ManagedComponentWatcher {
    param(
        [Parameter(Mandatory = $true)]$Component,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Processes,
        [DateTime]$NowUtc = [DateTime]::UtcNow
    )

    $state = Get-ManagedComponentRuntimeState -Component $Component -Processes $Processes
    if (-not $state.Installed) {
        $script:RetryStates.Remove($Component.Name)
        return [pscustomobject]@{ Name = $Component.Name; Action = 'NotInstalled'; Error = $null }
    }
    $stoppedOrphans = @(Stop-OrphanComponentInjectors -Component $Component -State $state)
    if ($state.WatcherRunning) {
        $script:RetryStates[$Component.Name] = [pscustomobject]@{
            FailureCount = 0
            NextAttemptUtc = [DateTime]::MinValue
        }
        return [pscustomobject]@{
            Name = $Component.Name
            Action = if ($stoppedOrphans.Count -gt 0) { 'CleanedOrphans' } else { 'AlreadyRunning' }
            Error = $null
            StoppedOrphanInjectorProcessIds = $stoppedOrphans
        }
    }

    $retry = if ($script:RetryStates.ContainsKey($Component.Name)) {
        $script:RetryStates[$Component.Name]
    }
    else {
        [pscustomobject]@{ FailureCount = 0; NextAttemptUtc = [DateTime]::MinValue }
    }
    if ($retry.NextAttemptUtc -gt $NowUtc) {
        return [pscustomobject]@{
            Name = $Component.Name
            Action = 'Backoff'
            Error = "next=$($retry.NextAttemptUtc.ToString('o'))"
        }
    }

    try {
        $started = Start-ManagedComponentWatcher -Component $Component
        $script:RetryStates[$Component.Name] = [pscustomobject]@{
            FailureCount = 0
            NextAttemptUtc = [DateTime]::MinValue
        }
        return [pscustomobject]@{
            Name = $Component.Name
            Action = 'Started'
            Error = $null
            WatcherProcessIds = $started.WatcherProcessIds
        }
    }
    catch {
        $failureCount = [Math]::Min(30, [int]$retry.FailureCount + 1)
        $delay = Get-RetryDelaySeconds -FailureCount $failureCount
        $script:RetryStates[$Component.Name] = [pscustomobject]@{
            FailureCount = $failureCount
            NextAttemptUtc = $NowUtc.AddSeconds($delay)
        }
        return [pscustomobject]@{
            Name = $Component.Name
            Action = 'Failed'
            Error = $_.Exception.Message
        }
    }
}

function Invoke-UiHotpatchRepairPass {
    $processes = Get-UiHotpatchProcessSnapshot
    return @(Get-ManagedComponentDefinitions | ForEach-Object {
        Repair-ManagedComponentWatcher -Component $_ -Processes $processes
    })
}

function Wait-SupervisorReady {
    param([ValidateRange(500, 15000)][int]$TimeoutMilliseconds = 6000)

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $supervisors = @(Get-SupervisorProcesses)
        if ($supervisors.Count -gt 0) {
            $processId = [int]$supervisors[0].ProcessId
            Start-Sleep -Milliseconds 500
            if (@(Get-SupervisorProcesses | Where-Object { $_.ProcessId -eq $processId }).Count -gt 0) {
                return $processId
            }
        }
        Start-Sleep -Milliseconds 100
    }
    throw 'UI 热补丁总监督未能稳定启动。'
}

function Stop-SupervisorProcesses {
    $supervisors = @(Get-SupervisorProcesses)
    foreach ($process in $supervisors) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }
    if ($supervisors.Count -eq 0) { return }

    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (@(Get-SupervisorProcesses).Count -eq 0) { return }
        Start-Sleep -Milliseconds 100
    }
    throw '旧 UI 热补丁总监督未能及时退出。'
}

function Install-SupervisorStartup {
    New-Item -ItemType Directory -Force -Path $StartupDirectory | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($StartupLink)
    $shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $shortcut.Arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' +
        $InstalledManager + '" -Mode Watch -PollSeconds 3'
    $shortcut.WorkingDirectory = $InstallRoot
    $shortcut.WindowStyle = 7
    $shortcut.Description = 'Codex 界面热补丁自恢复总监督'
    $shortcut.Save()

    $shellApplication = New-Object -ComObject Shell.Application
    try {
        $shellApplication.ShellExecute($StartupLink, '', '', 'open', 0)
    }
    finally {
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shellApplication)
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
    }
}

function Install-HotpatchSupervisor {
    Stop-SupervisorProcesses
    New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
    $managerText = [IO.File]::ReadAllText($PSCommandPath)
    [IO.File]::WriteAllText($InstalledManager, $managerText, [Text.UTF8Encoding]::new($true))
    Install-SupervisorStartup
    $supervisorPid = Wait-SupervisorReady
    $repair = Invoke-UiHotpatchRepairPass
    [pscustomobject]@{
        Version = $SupervisorVersion
        Installed = $true
        SupervisorProcessId = $supervisorPid
        StartedComponents = @($repair | Where-Object Action -eq 'Started' |
            Select-Object -ExpandProperty Name) -join ', '
        AlreadyRunningComponents = @($repair | Where-Object {
            $_.Action -in @('AlreadyRunning', 'CleanedOrphans')
        } |
            Select-Object -ExpandProperty Name) -join ', '
        FailedComponents = @($repair | Where-Object Action -eq 'Failed' |
            Select-Object -ExpandProperty Name) -join ', '
        InstallRoot = $InstallRoot
    } | Format-List
}

function Uninstall-HotpatchSupervisor {
    if (Test-Path -LiteralPath $StartupLink -PathType Leaf) {
        [IO.File]::Delete($StartupLink)
    }
    Stop-SupervisorProcesses
    'UI 热补丁总监督已停用；各组件文件、启动项和当前 renderer 状态保持不变。'
}

function Start-UiHotpatchSupervisor {
    $createdNew = $false
    $mutex = [Threading.Mutex]::new($true, $SupervisorMutexName, [ref]$createdNew)
    if (-not $createdNew) {
        $mutex.Dispose()
        return
    }
    try {
        Write-SupervisorLog -Message "started version=$SupervisorVersion poll_seconds=$PollSeconds"
        while ($true) {
            try {
                $results = Invoke-UiHotpatchRepairPass
                foreach ($result in $results | Where-Object {
                    $_.Action -in @('Started', 'CleanedOrphans', 'Failed')
                }) {
                    Write-SupervisorLog -Message (
                        "component=$($result.Name) action=$($result.Action) error=$($result.Error)"
                    )
                }
            }
            catch {
                Write-SupervisorLog -Message "repair_pass=failed error=$($_.Exception.Message)"
            }
            Start-Sleep -Seconds $PollSeconds
        }
    }
    finally {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

function Show-SupervisorStatus {
    $processes = Get-UiHotpatchProcessSnapshot
    $supervisors = @(Get-SupervisorProcesses -Processes $processes)
    $debugPorts = @(Get-ObservedCodexDebugPorts -Processes $processes)
    $rendererChecksRequired = $debugPorts.Count -gt 0
    $components = @(Get-ManagedComponentDefinitions | ForEach-Object {
        $runtime = Get-ManagedComponentRuntimeState -Component $_ -Processes $processes
        $rendererPorts = @($runtime.InjectorPorts | Where-Object { $_ -in $debugPorts })
        $renderer = Get-ManagedComponentRendererState -Component $_ -Ports $rendererPorts
        [pscustomobject]@{
            Name = $runtime.Name
            Installed = $runtime.Installed
            WatcherRunning = $runtime.WatcherRunning
            WatcherProcessIds = $runtime.WatcherProcessIds
            InjectorRunning = $runtime.InjectorRunning
            InjectorProcessIds = $runtime.InjectorProcessIds
            InjectorPorts = $runtime.InjectorPorts
            OrphanInjectorProcessIds = $runtime.OrphanInjectorProcessIds
            RendererCheckAttempted = $renderer.RendererCheckAttempted
            RendererInstalled = $renderer.RendererInstalled
            RendererState = $renderer.RendererState
            RendererPatchedPages = $renderer.RendererPatchedPages
            RendererError = $renderer.RendererError
        }
    })
    $installedComponents = @($components | Where-Object Installed)
    $healthyWatchers = @($installedComponents | Where-Object WatcherRunning)
    $healthyRenderers = if ($rendererChecksRequired) {
        @($installedComponents | Where-Object RendererInstalled)
    }
    else {
        $installedComponents
    }
    [pscustomobject]@{
        Version = $SupervisorVersion
        Installed = (Test-Path -LiteralPath $InstalledManager -PathType Leaf) -and
            (Test-Path -LiteralPath $StartupLink -PathType Leaf)
        SupervisorRunning = $supervisors.Count -gt 0
        SupervisorProcessIds = @($supervisors | Select-Object -ExpandProperty ProcessId) -join ', '
        StartupInstalled = Test-Path -LiteralPath $StartupLink -PathType Leaf
        ManagedComponents = $installedComponents.Count
        HealthyWatchers = $healthyWatchers.Count
        RendererChecksRequired = $rendererChecksRequired
        HealthyRenderers = $healthyRenderers.Count
        Healthy = $supervisors.Count -gt 0 -and
            $healthyWatchers.Count -eq $installedComponents.Count -and
            $healthyRenderers.Count -eq $installedComponents.Count
        CurrentCodexDebugPorts = $debugPorts -join ', '
        InstallRoot = $InstallRoot
    } | Format-List
    $components | Select-Object Name, Installed, WatcherRunning, WatcherProcessIds,
        InjectorRunning, InjectorProcessIds, InjectorPorts, RendererCheckAttempted,
        RendererInstalled, RendererState, RendererPatchedPages, RendererError,
        OrphanInjectorProcessIds | Format-Table -AutoSize
}

if ($MyInvocation.InvocationName -ne '.') {
    switch ($Mode) {
        'Install' { Install-HotpatchSupervisor }
        'Uninstall' { Uninstall-HotpatchSupervisor }
        'RunOnce' { Invoke-UiHotpatchRepairPass | Format-Table -AutoSize }
        'Watch' { Start-UiHotpatchSupervisor }
        'Status' { Show-SupervisorStatus }
    }
}
