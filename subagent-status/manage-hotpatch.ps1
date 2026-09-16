[CmdletBinding()]
param(
    [ValidateSet('Install', 'Uninstall', 'RunOnce', 'Watch', 'Status')]
    [string]$Mode = 'Status'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PatchName = 'CodexSubagentStatusHotpatch'
$InstallRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\hotpatches\subagent-status'
$InstalledManager = Join-Path $InstallRoot 'manage-hotpatch.ps1'
$InstalledInjector = Join-Path $InstallRoot 'codex-subagent-status-hotpatch.mjs'
$InstalledEvidence = Join-Path $InstallRoot 'completion-evidence.mjs'
$InstalledTransport = Join-Path (Split-Path $InstallRoot -Parent) 'shared\codex-devtools-transport.mjs'
$InstalledLifecycle = Join-Path (Split-Path $InstallRoot -Parent) 'shared\codex-hotpatch-lifecycle.psm1'
$StartupLink = Join-Path ([Environment]::GetFolderPath('Startup')) ($PatchName + '.lnk')
$LifecycleModule = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\shared\codex-hotpatch-lifecycle.psm1'))
if (-not (Test-Path -LiteralPath $LifecycleModule -PathType Leaf)) {
    throw "缺少热补丁生命周期模块：$LifecycleModule"
}
Import-Module -Name $LifecycleModule -Force

function Get-RunningCodexDesktopRootProcesses {
    try {
        return @(
            Get-CimInstance -ClassName Win32_Process -Filter "Name = 'ChatGPT.exe'" `
                -OperationTimeoutSec 3 -ErrorAction Stop | Where-Object {
                    $_.ExecutablePath -match '(?i)\\WindowsApps\\OpenAI\.Codex_' -and
                    $_.CommandLine -and $_.CommandLine -notmatch '--type='
                }
        )
    }
    catch {
        return @()
    }
}

function Install-HotpatchStartup {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($StartupLink)
    $shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $shortcut.Arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' +
        $InstalledManager + '" -Mode Watch'
    $shortcut.WorkingDirectory = $InstallRoot
    $shortcut.WindowStyle = 7
    $shortcut.Description = 'Codex 子智能体侧栏状态同步热补丁'
    $shortcut.Save()

    # Ask the Explorer shell to launch the shortcut so the watcher does not inherit
    # the short-lived install command's process job. The shortcut itself stays hidden.
    $shellApplication = New-Object -ComObject Shell.Application
    try {
        $shellApplication.ShellExecute($StartupLink, '', '', 'open', 0)
    }
    finally {
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shellApplication)
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
    }
    Wait-CodexHotpatchWatcherReady -InstalledManager $InstalledManager `
        -InstalledInjector $InstalledInjector
}

function Install-Hotpatch {
    $sourceInjector = Join-Path $PSScriptRoot 'codex-subagent-status-hotpatch.mjs'
    $sourceEvidence = Join-Path $PSScriptRoot 'completion-evidence.mjs'
    $sourceTransport = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\shared\codex-devtools-transport.mjs'))
    $sourceLifecycle = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\shared\codex-hotpatch-lifecycle.psm1'))
    if (-not (Test-Path -LiteralPath $sourceInjector -PathType Leaf)) {
        throw "缺少热补丁注入器：$sourceInjector"
    }
    if (-not (Test-Path -LiteralPath $sourceEvidence -PathType Leaf)) {
        throw "缺少完成证据模块：$sourceEvidence"
    }
    if (-not (Test-Path -LiteralPath $sourceTransport -PathType Leaf)) {
        throw "缺少 DevTools transport：$sourceTransport"
    }
    if (-not (Test-Path -LiteralPath $sourceLifecycle -PathType Leaf)) {
        throw "缺少热补丁生命周期模块：$sourceLifecycle"
    }
    $patchVersion = Get-CodexHotpatchInjectorVersion -InjectorPath $sourceInjector

    # Stop only this patch's helpers so an older watcher cannot re-inject stale logic.
    Stop-CodexHotpatchHelpers -InstalledManager $InstalledManager -InstalledInjector $InstalledInjector
    New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
    New-Item -ItemType Directory -Force -Path (Split-Path $InstalledTransport -Parent) | Out-Null
    $managerText = [IO.File]::ReadAllText($PSCommandPath)
    [IO.File]::WriteAllText($InstalledManager, $managerText, [Text.UTF8Encoding]::new($true))
    Copy-Item -LiteralPath $sourceInjector -Destination $InstalledInjector -Force
    Copy-Item -LiteralPath $sourceEvidence -Destination $InstalledEvidence -Force
    Copy-Item -LiteralPath $sourceTransport -Destination $InstalledTransport -Force
    Copy-Item -LiteralPath $sourceLifecycle -Destination $InstalledLifecycle -Force

    Install-HotpatchStartup

    $desktopRoots = @(Get-RunningCodexDesktopRootProcesses)
    $port = Get-CodexDebugPort
    if ($port) {
        try {
            $result = Invoke-CodexHotpatchInjector -InjectorPath $InstalledInjector `
                -InjectorMode '--once' -Port $port
            $patchedPages = @($result.targets | Where-Object { $_.result.installed }).Count
            "当前 Codex 会话已注入：$patchedPages 个页面"
        }
        catch {
            'Codex 本地调试端点暂不可用；补丁已安装，守护进程会在端点恢复后自动注入。'
        }
    } elseif ($desktopRoots.Count -gt 0) {
        'Codex 正通过未启用本地 DevTools 的官方入口运行；当前会话无法注入。请完全退出 Codex 后使用“Codex（代理优化）”启动，守护进程会自动接管。'
    } else {
        'Codex 当前未运行；下次通过“Codex（代理优化）”启动时自动注入。'
    }
    "热补丁 $patchVersion 已安装（用户级，不修改 Codex 安装目录、数据库或会话文件）。"
}

function Uninstall-Hotpatch {
    if (Test-Path -LiteralPath $StartupLink -PathType Leaf) {
        [IO.File]::Delete($StartupLink)
    }
    Stop-CodexHotpatchHelpers -InstalledManager $InstalledManager -InstalledInjector $InstalledInjector
    $port = Get-CodexDebugPort
    if ($port -and (Test-Path -LiteralPath $InstalledInjector)) {
        try {
            $null = Invoke-CodexHotpatchInjector -InjectorPath $InstalledInjector `
                -InjectorMode '--remove' -Port $port
        }
        catch { }
    }
    '热补丁已停用；已安装文件保留，便于审计或重新启用。'
}

function Show-Status {
    $helpers = Get-CodexHotpatchHelperProcesses -InstalledManager $InstalledManager `
        -InstalledInjector $InstalledInjector
    $watchers = @($helpers.WatcherProcesses)
    $injectors = @($helpers.InjectorProcesses)
    $desktopRoots = @(Get-RunningCodexDesktopRootProcesses)
    $port = Get-CodexDebugPort
    $pageStatus = @()
    $statusError = $null
    if ($port -and (Test-Path -LiteralPath $InstalledInjector)) {
        try {
            $pageStatus = @(Invoke-CodexHotpatchInjector -InjectorPath $InstalledInjector `
                -InjectorMode '--status' -Port $port).targets
        }
        catch {
            $statusError = $_.Exception.Message
        }
    }
    elseif ($desktopRoots.Count -gt 0) {
        $statusError = 'Codex 正通过未启用本地 DevTools 的官方入口运行；热补丁已配置但当前会话未接管。完全退出后请使用“Codex（代理优化）”启动。'
    }
    $patchVersions = @($pageStatus | ForEach-Object {
        if ($_.result.PSObject.Properties['version']) { [string]$_.result.version }
    } | Select-Object -Unique)
    $triggerModes = @($pageStatus | ForEach-Object {
        if ($_.result.PSObject.Properties['trigger']) { [string]$_.result.trigger }
    } | Select-Object -Unique)
    $filterModes = @($pageStatus | ForEach-Object {
        if ($_.result.PSObject.Properties['filter']) { [string]$_.result.filter }
    } | Select-Object -Unique)
    $patchVersion = if (Test-Path -LiteralPath $InstalledInjector -PathType Leaf) {
        Get-CodexHotpatchInjectorVersion -InjectorPath $InstalledInjector
    } else { '' }
    $patchedPages = @($pageStatus | Where-Object { $_.result.installed }).Count
    $launchMode = if ($desktopRoots.Count -eq 0) {
        'NotRunning'
    }
    elseif ($port) {
        'DevToolsEnabled'
    }
    else {
        'OfficialEntryNoDevTools'
    }
    [pscustomobject]@{
        Installed = (Test-Path -LiteralPath $StartupLink -PathType Leaf) -and
            (Test-Path -LiteralPath $InstalledManager -PathType Leaf) -and
            (Test-Path -LiteralPath $InstalledInjector -PathType Leaf) -and
            (Test-Path -LiteralPath $InstalledEvidence -PathType Leaf) -and
            (Test-Path -LiteralPath $InstalledTransport -PathType Leaf) -and
            (Test-Path -LiteralPath $InstalledLifecycle -PathType Leaf)
        WatcherRunning = $watchers.Count -gt 0
        InjectorRunning = $injectors.Count -gt 0
        RuntimeReady = [bool]($port -and -not $statusError -and $patchedPages -gt 0)
        LaunchMode = $launchMode
        RunningDesktopProcesses = $desktopRoots.Count
        CodexDebugPort = $port
        EndpointReachable = [bool]($port -and -not $statusError)
        PatchVersion = $patchVersion
        RendererVersion = $patchVersions -join ', '
        TriggerMode = $triggerModes -join ', '
        FilterMode = $filterModes -join ', '
        PatchedPages = $patchedPages
        ObserverPages = @($pageStatus | Where-Object {
            $_.result.PSObject.Properties['observerInstalled'] -and $_.result.observerInstalled
        }).Count
        ProcessingPages = @($pageStatus | Where-Object {
            $_.result.PSObject.Properties['processing'] -and $_.result.processing
        }).Count
        RepairedItems = (@($pageStatus | ForEach-Object {
            if ($_.result.PSObject.Properties['repairedCount']) { [int]$_.result.repairedCount } else { 0 }
        }) | Measure-Object -Sum).Sum
        ProjectedCompletedItems = (@($pageStatus | ForEach-Object {
            if ($_.result.PSObject.Properties['projectedCompletedCount']) {
                [int]$_.result.projectedCompletedCount
            } else { 0 }
        }) | Measure-Object -Sum).Sum
        ProjectedSummaryCompletedItems = (@($pageStatus | ForEach-Object {
            if ($_.result.PSObject.Properties['projectedSummaryCompletedCount']) {
                [int]$_.result.projectedSummaryCompletedCount
            } else { 0 }
        }) | Measure-Object -Sum).Sum
        ProjectionRuns = (@($pageStatus | ForEach-Object {
            if ($_.result.PSObject.Properties['projectionRuns']) { [int]$_.result.projectionRuns } else { 0 }
        }) | Measure-Object -Sum).Sum
        SummaryProjectionRuns = (@($pageStatus | ForEach-Object {
            if ($_.result.PSObject.Properties['summaryProjectionRuns']) {
                [int]$_.result.summaryProjectionRuns
            } else { 0 }
        }) | Measure-Object -Sum).Sum
        CompletionEvidenceItems = (@($pageStatus | ForEach-Object {
            if ($_.result.PSObject.Properties['completionEvidenceCount']) {
                [int]$_.result.completionEvidenceCount
            } else { 0 }
        }) | Measure-Object -Sum).Sum
        AgentMetadataItems = (@($pageStatus | ForEach-Object {
            if ($_.result.PSObject.Properties['agentMetadataCount']) {
                [int]$_.result.agentMetadataCount
            } else { 0 }
        }) | Measure-Object -Sum).Sum
        MetadataResolvedItems = (@($pageStatus | ForEach-Object {
            if ($_.result.PSObject.Properties['lastMetadataResolvedIds']) {
                @($_.result.lastMetadataResolvedIds).Count
            } else { 0 }
        }) | Measure-Object -Sum).Sum
        AgentMetadataErrors = @($pageStatus | ForEach-Object {
            if ($_.result.PSObject.Properties['agentMetadataError'] -and
                $_.result.agentMetadataError) {
                [string]$_.result.agentMetadataError
            }
        } | Select-Object -Unique) -join ', '
        VisibleActiveItems = (@($pageStatus | ForEach-Object {
            if ($_.result.PSObject.Properties['visibleActiveCount'] -and
                $null -ne $_.result.visibleActiveCount) {
                [int]$_.result.visibleActiveCount
            } else { 0 }
        }) | Measure-Object -Sum).Sum
        VisibleCompletedItems = (@($pageStatus | ForEach-Object {
            if ($_.result.PSObject.Properties['visibleCompletedCount'] -and
                $null -ne $_.result.visibleCompletedCount) {
                [int]$_.result.visibleCompletedCount
            } else { 0 }
        }) | Measure-Object -Sum).Sum
        StatusError = $statusError
        InstallRoot = $InstallRoot
    } | Format-List
}

switch ($Mode) {
    'Install' { Install-Hotpatch }
    'Uninstall' { Uninstall-Hotpatch }
    'RunOnce' {
        $port = Get-CodexDebugPort
        if (-not $port) {
            if (@(Get-RunningCodexDesktopRootProcesses).Count -gt 0) {
                throw 'Codex 正通过未启用本地 DevTools 的官方入口运行；无法对当前会话注入。请完全退出后使用“Codex（代理优化）”启动。'
            }
            throw 'Codex 当前未运行。'
        }
        if (-not (Test-Path -LiteralPath $InstalledInjector -PathType Leaf)) {
            throw '热补丁尚未安装。请先使用 -Mode Install。'
        }
        Invoke-CodexHotpatchInjector -InjectorPath $InstalledInjector `
            -InjectorMode '--once' -Port $port | ConvertTo-Json -Depth 6
    }
    'Watch' { Start-CodexInjectorSupervisor -InjectorPath $InstalledInjector }
    'Status' { Show-Status }
}
