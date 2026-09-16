$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'manage-hotpatch.ps1')

function Assert-True {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Actual, $Expected, [Parameter(Mandatory = $true)][string]$Message)
    if ($Actual -ne $Expected) { throw "$Message Expected=[$Expected] Actual=[$Actual]" }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    "codex-ui-supervisor-$PID-$([Guid]::NewGuid().ToString('N'))"
)
$testHotpatchRoot = Join-Path $testRoot 'hotpatches'
$testStartupRoot = Join-Path $testRoot 'startup'
New-Item -ItemType Directory -Force -Path $testHotpatchRoot, $testStartupRoot | Out-Null

try {
    $definitions = @(Get-ManagedComponentDefinitions -Root $testHotpatchRoot `
        -StartupRoot $testStartupRoot)
    Assert-Equal $definitions.Count 2 '必须监督两个界面补丁。'
    Assert-Equal (@($definitions.Name | Sort-Object -Unique).Count) 2 '组件名称必须唯一。'

    $component = $definitions[0]
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $component.ManagerPath) | Out-Null
    [IO.File]::WriteAllText($component.ManagerPath, 'manager')
    [IO.File]::WriteAllText($component.InjectorPath, 'injector')
    [IO.File]::WriteAllText($component.StartupPath, 'shortcut')
    Assert-True (Test-ManagedComponentInstalled -Component $component) `
        '管理器、注入器和独立启动项齐全时应视为已安装。'
    [IO.File]::Delete($component.StartupPath)
    Assert-True (-not (Test-ManagedComponentInstalled -Component $component)) `
        '缺少组件启动项时不得由总监督复活，避免撤销卸载意图。'
    [IO.File]::WriteAllText($component.StartupPath, 'shortcut')

    $watcherPid = 1234
    $injectorPid = 2345
    $fakeProcesses = @(
        [pscustomobject]@{
            ProcessId = $watcherPid
            ParentProcessId = 100
            Name = 'powershell.exe'
            CommandLine = "powershell.exe -File `"$($component.ManagerPath)`" -Mode Watch"
        }
        [pscustomobject]@{
            ProcessId = $injectorPid
            ParentProcessId = $watcherPid
            Name = 'node.exe'
            CommandLine = "node.exe `"$($component.InjectorPath)`" --watch-port 27503"
        }
        [pscustomobject]@{
            ProcessId = 3456
            ParentProcessId = 100
            Name = 'ChatGPT.exe'
            CommandLine = 'ChatGPT.exe --remote-debugging-port=27503'
        }
    )
    $runtime = Get-ManagedComponentRuntimeState -Component $component -Processes $fakeProcesses
    Assert-True $runtime.Installed '运行状态必须保留安装判定。'
    Assert-True $runtime.WatcherRunning '必须识别匹配组件管理器的 Watch 进程。'
    Assert-True $runtime.InjectorRunning '必须识别匹配组件注入器的动态端口进程。'
    Assert-Equal $runtime.WatcherProcessIds[0] $watcherPid 'watcher PID 必须准确。'
    Assert-Equal $runtime.InjectorProcessIds[0] $injectorPid 'injector PID 必须准确。'
    Assert-Equal $runtime.InjectorPorts[0] 27503 'injector 端口必须从当前命令行解析。'
    Assert-Equal $runtime.OrphanInjectorProcessIds.Count 0 `
        '由当前 watcher 派生的 injector 不得视为孤儿。'
    Assert-Equal (Get-ObservedCodexDebugPorts -Processes $fakeProcesses)[0] 27503 `
        'DevTools 端口必须来自当前进程命令行而不是固定值。'

    $rendererInstalled = Get-ManagedComponentRendererState -Component $component -Ports @(27503) `
        -StatusReader {
            param($InjectorPath, $Port)
            [pscustomobject]@{ targets = @([pscustomobject]@{ result = [pscustomobject]@{ installed = $true } }) }
        }
    Assert-True $rendererInstalled.RendererCheckAttempted '活跃 injector 端口必须触发只读 renderer 检查。'
    Assert-True $rendererInstalled.RendererInstalled '已装载 renderer 必须报告为健康。'
    Assert-Equal $rendererInstalled.RendererPatchedPages 1 '已装载页面数必须准确。'

    $rendererMissing = Get-ManagedComponentRendererState -Component $component -Ports @(27503) `
        -StatusReader {
            param($InjectorPath, $Port)
            [pscustomobject]@{ targets = @([pscustomobject]@{ result = [pscustomobject]@{ installed = $false } }) }
        }
    Assert-True (-not $rendererMissing.RendererInstalled) '活跃 renderer 未装载时不得被总监督判为健康。'
    Assert-Equal $rendererMissing.RendererState 'NotInstalled' '未装载 renderer 必须有可诊断状态。'

    $orphanPid = 4567
    $runtimeWithOrphan = Get-ManagedComponentRuntimeState -Component $component -Processes @(
        $fakeProcesses
        [pscustomobject]@{
            ProcessId = $orphanPid
            ParentProcessId = 9999
            Name = 'node.exe'
            CommandLine = "node.exe `"$($component.InjectorPath)`" --watch-port 27503"
        }
    )
    Assert-Equal $runtimeWithOrphan.OrphanInjectorProcessIds[0] $orphanPid `
        '父 watcher 已不存在的 injector 必须被识别为孤儿。'

    $expectedDelays = @(2, 4, 8, 16, 32, 60, 60)
    for ($index = 0; $index -lt $expectedDelays.Count; $index++) {
        Assert-Equal (Get-RetryDelaySeconds -FailureCount ($index + 1)) $expectedDelays[$index] `
            '崩溃重试必须指数退避并封顶。'
    }

    $script:RetryStates = @{}
    $alreadyRunning = Repair-ManagedComponentWatcher -Component $component `
        -Processes $fakeProcesses -NowUtc ([DateTime]::UtcNow)
    Assert-Equal $alreadyRunning.Action 'AlreadyRunning' `
        '已运行 watcher 不得重复启动。'

    $notInstalled = $definitions[1]
    $notInstalledResult = Repair-ManagedComponentWatcher -Component $notInstalled `
        -Processes @() -NowUtc ([DateTime]::UtcNow)
    Assert-Equal $notInstalledResult.Action 'NotInstalled' `
        '未安装组件不得被创建或复活。'

    $integrationRoot = Join-Path $testRoot 'integration-component'
    $integrationManager = Join-Path $integrationRoot 'manage-hotpatch.ps1'
    $integrationInjector = Join-Path $integrationRoot 'fake-injector.mjs'
    $integrationShortcut = Join-Path $testStartupRoot 'IntegrationHotpatch.lnk'
    New-Item -ItemType Directory -Force -Path $integrationRoot | Out-Null
    [IO.File]::WriteAllText(
        $integrationManager,
        @'
[CmdletBinding()]
param([string]$Mode = 'Status')
if ($Mode -eq 'Watch') {
    while ($true) { Start-Sleep -Seconds 1 }
}
'@,
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText($integrationInjector, '// test injector')
    [IO.File]::WriteAllText($integrationShortcut, 'shortcut')
    $integrationComponent = [pscustomobject]@{
        Name = 'integration-component'
        ManagerPath = $integrationManager
        InjectorPath = $integrationInjector
        StartupPath = $integrationShortcut
    }

    $firstWatcher = Start-ManagedComponentWatcher -Component $integrationComponent
    $firstPid = [int]$firstWatcher.WatcherProcessIds[0]
    Assert-True ($firstPid -gt 0) '真实 watcher 必须稳定启动。'
    Stop-Process -Id $firstPid -Force
    $firstProcess = Get-Process -Id $firstPid -ErrorAction SilentlyContinue
    if ($firstProcess) {
        $null = $firstProcess.WaitForExit(3000)
        $firstProcess.Dispose()
    }

    $script:RetryStates = @{}
    $restarted = Repair-ManagedComponentWatcher -Component $integrationComponent `
        -Processes (Get-UiHotpatchProcessSnapshot) -NowUtc ([DateTime]::UtcNow)
    Assert-Equal $restarted.Action 'Started' 'watcher 被终止后必须自动启动替代进程。'
    $secondPid = [int]$restarted.WatcherProcessIds[0]
    Assert-True ($secondPid -gt 0 -and $secondPid -ne $firstPid) `
        '自恢复必须产生新的稳定 watcher PID。'
    Stop-Process -Id $secondPid -Force -ErrorAction SilentlyContinue
}
finally {
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -in @('powershell.exe', 'pwsh.exe') -and
        $_.CommandLine -like "*$testRoot*" -and
        $_.CommandLine -match '(?i)-Mode\s+Watch(?:\s|$)'
    } | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        [IO.Directory]::Delete($testRoot, $true)
    }
}

'ui hotpatch supervisor tests: PASS'
