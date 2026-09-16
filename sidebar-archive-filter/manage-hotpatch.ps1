[CmdletBinding()]
param(
    [ValidateSet('Install', 'Uninstall', 'RunOnce', 'Watch', 'Status')]
    [string]$Mode = 'Status'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PatchName = 'CodexSidebarArchiveFilterHotpatch'
$InstallRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\hotpatches\sidebar-archive-filter'
$InstalledManager = Join-Path $InstallRoot 'manage-hotpatch.ps1'
$InstalledInjector = Join-Path $InstallRoot 'codex-sidebar-archive-filter-hotpatch.mjs'
$InstalledArchiveIndex = Join-Path $InstallRoot 'archived-thread-index.mjs'
$InstalledTransport = Join-Path (Split-Path $InstallRoot -Parent) 'shared\codex-devtools-transport.mjs'
$InstalledLifecycle = Join-Path (Split-Path $InstallRoot -Parent) 'shared\codex-hotpatch-lifecycle.psm1'
$StartupLink = Join-Path ([Environment]::GetFolderPath('Startup')) ($PatchName + '.lnk')
$LifecycleModule = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\shared\codex-hotpatch-lifecycle.psm1'))
if (-not (Test-Path -LiteralPath $LifecycleModule -PathType Leaf)) {
    throw "缺少热补丁生命周期模块：$LifecycleModule"
}
Import-Module -Name $LifecycleModule -Force

function Install-Hotpatch {
    $sourceInjector = Join-Path $PSScriptRoot 'codex-sidebar-archive-filter-hotpatch.mjs'
    $sourceArchiveIndex = Join-Path $PSScriptRoot 'archived-thread-index.mjs'
    $sourceTransport = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\shared\codex-devtools-transport.mjs'))
    $sourceLifecycle = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\shared\codex-hotpatch-lifecycle.psm1'))
    foreach ($source in @($sourceInjector, $sourceArchiveIndex, $sourceTransport, $sourceLifecycle)) {
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "缺少热补丁文件：$source"
        }
    }

    $patchVersion = Get-CodexHotpatchInjectorVersion -InjectorPath $sourceInjector
    Stop-CodexHotpatchHelpers -InstalledManager $InstalledManager -InstalledInjector $InstalledInjector
    New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
    New-Item -ItemType Directory -Force -Path (Split-Path $InstalledTransport -Parent) | Out-Null
    $managerText = [IO.File]::ReadAllText($PSCommandPath)
    [IO.File]::WriteAllText($InstalledManager, $managerText, [Text.UTF8Encoding]::new($true))
    Copy-Item -LiteralPath $sourceInjector -Destination $InstalledInjector -Force
    Copy-Item -LiteralPath $sourceArchiveIndex -Destination $InstalledArchiveIndex -Force
    Copy-Item -LiteralPath $sourceTransport -Destination $InstalledTransport -Force
    Copy-Item -LiteralPath $sourceLifecycle -Destination $InstalledLifecycle -Force

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($StartupLink)
    $shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $shortcut.Arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' +
        $InstalledManager + '" -Mode Watch'
    $shortcut.WorkingDirectory = $InstallRoot
    $shortcut.WindowStyle = 7
    $shortcut.Description = 'Codex 归档任务侧栏过滤运行时热补丁'
    $shortcut.Save()

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
    }
    else {
        'Codex 当前未运行；下次从带 DevTools 的入口启动时自动注入。'
    }

    Start-CodexHotpatchWatcher -InstalledManager $InstalledManager `
        -InstalledInjector $InstalledInjector -InstallRoot $InstallRoot
    "热补丁 $patchVersion 已安装（仅修正 renderer 内存过滤，不修改任务归档状态）。"
}

function Uninstall-Hotpatch {
    if (Test-Path -LiteralPath $StartupLink -PathType Leaf) {
        [IO.File]::Delete($StartupLink)
    }
    Stop-CodexHotpatchHelpers -InstalledManager $InstalledManager -InstalledInjector $InstalledInjector
    $port = Get-CodexDebugPort
    if ($port -and (Test-Path -LiteralPath $InstalledInjector -PathType Leaf)) {
        $null = Invoke-CodexHotpatchInjector -InjectorPath $InstalledInjector `
            -InjectorMode '--remove' -Port $port
    }
    '热补丁已停用；没有取消归档、删除或改写任何任务。'
}

function Show-Status {
    $helpers = Get-CodexHotpatchHelperProcesses -InstalledManager $InstalledManager `
        -InstalledInjector $InstalledInjector
    $watchers = @($helpers.WatcherProcesses)
    $injectors = @($helpers.InjectorProcesses)
    $port = Get-CodexDebugPort
    $pageStatus = @()
    $statusError = $null
    if ($port -and (Test-Path -LiteralPath $InstalledInjector -PathType Leaf)) {
        try {
            $pageStatus = @(Invoke-CodexHotpatchInjector -InjectorPath $InstalledInjector `
                -InjectorMode '--status' -Port $port).targets
        }
        catch {
            $statusError = $_.Exception.Message
        }
    }

    $rendererVersions = @($pageStatus | ForEach-Object {
        if ($_.result -and $_.result.PSObject.Properties['version']) { [string]$_.result.version }
    } | Select-Object -Unique)
    $verificationStates = @($pageStatus | ForEach-Object {
        if ($_.result -and $_.result.PSObject.Properties['verification']) {
            [string]$_.result.verification
        }
    } | Select-Object -Unique)
    $archiveSeedLoaded = @($pageStatus | Where-Object {
        $_.result -and $_.result.PSObject.Properties['archiveSeedLoaded'] -and
            $_.result.archiveSeedLoaded
    }).Count
    $archiveSeedSources = @($pageStatus | ForEach-Object {
        if ($_.result -and $_.result.PSObject.Properties['archiveSeedSource'] -and
            $_.result.archiveSeedSource) {
            [string]$_.result.archiveSeedSource
        }
    } | Select-Object -Unique)
    $archiveSeedErrors = @($pageStatus | ForEach-Object {
        if ($_.result -and $_.result.PSObject.Properties['archiveSeedError'] -and
            $_.result.archiveSeedError) {
            [string]$_.result.archiveSeedError
        }
    } | Select-Object -Unique)
    $archiveApiErrors = @($pageStatus | ForEach-Object {
        if ($_.result -and $_.result.PSObject.Properties['archiveApiError'] -and
            $_.result.archiveApiError) {
            [string]$_.result.archiveApiError
        }
    } | Select-Object -Unique)
    $seededArchivedThreads = @($pageStatus | ForEach-Object {
        if ($_.result -and $_.result.PSObject.Properties['seededArchivedThreads']) {
            [int]$_.result.seededArchivedThreads
        }
    } | Measure-Object -Sum).Sum
    $apiObservedArchivedThreads = @($pageStatus | ForEach-Object {
        if ($_.result -and $_.result.PSObject.Properties['apiObservedArchivedThreads']) {
            [int]$_.result.apiObservedArchivedThreads
        }
    } | Measure-Object -Sum).Sum
    $knownLocalThreads = @($pageStatus | ForEach-Object {
        if ($_.result -and $_.result.PSObject.Properties['knownLocalThreads']) {
            [int]$_.result.knownLocalThreads
        }
    } | Measure-Object -Sum).Sum
    $latestArchiveBatchThreads = @($pageStatus | ForEach-Object {
        if ($_.result -and $_.result.PSObject.Properties['latestArchiveBatchThreads']) {
            [int]$_.result.latestArchiveBatchThreads
        }
        elseif ($_.result -and $_.result.PSObject.Properties['archivedThreads']) {
            [int]$_.result.archivedThreads
        }
    } | Measure-Object -Sum).Sum
    $observedArchivedThreads = @($pageStatus | ForEach-Object {
        if ($_.result -and $_.result.PSObject.Properties['observedArchivedThreads']) {
            [int]$_.result.observedArchivedThreads
        }
        elseif ($_.result -and $_.result.PSObject.Properties['archivedThreads']) {
            [int]$_.result.archivedThreads
        }
    } | Measure-Object -Sum).Sum
    $suppressedObservedArchivedThreads = @($pageStatus | ForEach-Object {
        if ($_.result -and $_.result.PSObject.Properties['suppressedObservedArchivedThreads']) {
            [int]$_.result.suppressedObservedArchivedThreads
        }
        elseif ($_.result -and $_.result.PSObject.Properties['suppressedArchivedThreads']) {
            [int]$_.result.suppressedArchivedThreads
        }
    } | Measure-Object -Sum).Sum
    $suppressedConversations = @($pageStatus | ForEach-Object {
        if ($_.result -and $_.result.PSObject.Properties['suppressedConversations']) {
            [int]$_.result.suppressedConversations
        }
    } | Measure-Object -Sum).Sum
    $orphanPlaceholderThreads = @($pageStatus | ForEach-Object {
        if ($_.result -and $_.result.PSObject.Properties['orphanPlaceholderThreads']) {
            [int]$_.result.orphanPlaceholderThreads
        }
    } | Measure-Object -Sum).Sum
    $suppressedOrphanPlaceholderThreads = @($pageStatus | ForEach-Object {
        if ($_.result -and $_.result.PSObject.Properties['suppressedOrphanPlaceholderThreads']) {
            [int]$_.result.suppressedOrphanPlaceholderThreads
        }
    } | Measure-Object -Sum).Sum
    $repairs = @($pageStatus | ForEach-Object {
        if ($_.result -and $_.result.PSObject.Properties['repairs']) { [int]$_.result.repairs }
    } | Measure-Object -Sum).Sum
    $managedSuppressions = @($pageStatus | ForEach-Object {
        if ($_.result -and $_.result.PSObject.Properties['managedSuppressions']) {
            [int]$_.result.managedSuppressions
        }
    } | Measure-Object -Sum).Sum
    $timestampRepairs = @($pageStatus | ForEach-Object {
        if ($_.result -and $_.result.PSObject.Properties['timestampRepairs']) {
            [int]$_.result.timestampRepairs
        }
    } | Measure-Object -Sum).Sum
    $rendererErrors = @($pageStatus | ForEach-Object {
        if ($_.result -and $_.result.PSObject.Properties['lastError'] -and $_.result.lastError) {
            [string]$_.result.lastError
        }
    } | Select-Object -Unique)
    $patchVersion = if (Test-Path -LiteralPath $InstalledInjector -PathType Leaf) {
        Get-CodexHotpatchInjectorVersion -InjectorPath $InstalledInjector
    }
    else { '' }

    [pscustomobject]@{
        Installed = (Test-Path -LiteralPath $StartupLink -PathType Leaf) -and
            (Test-Path -LiteralPath $InstalledManager -PathType Leaf) -and
            (Test-Path -LiteralPath $InstalledInjector -PathType Leaf) -and
            (Test-Path -LiteralPath $InstalledArchiveIndex -PathType Leaf) -and
            (Test-Path -LiteralPath $InstalledTransport -PathType Leaf) -and
            (Test-Path -LiteralPath $InstalledLifecycle -PathType Leaf)
        WatcherRunning = $watchers.Count -gt 0
        InjectorRunning = $injectors.Count -gt 0
        CodexDebugPort = $port
        EndpointReachable = [bool]($port -and -not $statusError)
        PatchVersion = $patchVersion
        RendererVersion = $rendererVersions -join ', '
        PatchedPages = @($pageStatus | Where-Object { $_.result -and $_.result.installed }).Count
        VerificationState = $verificationStates -join ', '
        ArchiveSeedLoadedPages = [int]$archiveSeedLoaded
        ArchiveSeedSource = $archiveSeedSources -join ', '
        SeededArchivedThreads = [int]$seededArchivedThreads
        KnownLocalThreads = [int]$knownLocalThreads
        ApiObservedArchivedThreads = [int]$apiObservedArchivedThreads
        LatestArchiveBatchThreads = [int]$latestArchiveBatchThreads
        ObservedArchivedThreads = [int]$observedArchivedThreads
        SuppressedObservedArchivedThreads = [int]$suppressedObservedArchivedThreads
        SuppressedConversations = [int]$suppressedConversations
        OrphanPlaceholderThreads = [int]$orphanPlaceholderThreads
        SuppressedOrphanPlaceholderThreads = [int]$suppressedOrphanPlaceholderThreads
        ManagedSuppressions = [int]$managedSuppressions
        CumulativeRepairs = [int]$repairs
        TimestampRepairs = [int]$timestampRepairs
        ArchiveSeedError = $archiveSeedErrors -join '; '
        ArchiveApiError = $archiveApiErrors -join '; '
        RendererError = $rendererErrors -join '; '
        StatusError = $statusError
        InstallRoot = $InstallRoot
    } | Format-List
}

switch ($Mode) {
    'Install' { Install-Hotpatch }
    'Uninstall' { Uninstall-Hotpatch }
    'RunOnce' {
        $port = Get-CodexDebugPort
        if (-not $port) { throw 'Codex 当前未运行。' }
        Invoke-CodexHotpatchInjector -InjectorPath $InstalledInjector `
            -InjectorMode '--once' -Port $port | ConvertTo-Json -Depth 6
    }
    'Watch' { Start-CodexInjectorSupervisor -InjectorPath $InstalledInjector }
    'Status' { Show-Status }
}
