$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'manage-hotpatch.ps1')

function Assert-True {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-FileText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Message 文件不存在：$Path" }
    $actual = [IO.File]::ReadAllText($Path)
    if ($actual -ne $Expected) { throw "$Message Expected=[$Expected] Actual=[$actual]" }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("codex-hotpatch-install-rollback-$PID-$([Guid]::NewGuid().ToString('N'))")
New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
try {
    $InstallRoot = Join-Path $testRoot 'install'
    $ExplicitProxyDisabledPath = Join-Path $InstallRoot 'explicit-proxy.disabled'
    $InstalledManager = Join-Path $InstallRoot 'manage-hotpatch.ps1'
    $InstalledNetworkHealthModule = Join-Path $InstallRoot 'network-health.psm1'
    $InstalledNetworkRuntimeObserver = Join-Path $InstallRoot 'network-runtime-observer.psm1'
    $InstalledNetworkWatchdog = Join-Path $InstallRoot 'network-watchdog.ps1'
    $NetworkHealthPath = Join-Path $InstallRoot 'network-health.json'
    $TransportStatePath = Join-Path $InstallRoot 'transport-state.json'
    $CoreRouteStatePath = Join-Path $InstallRoot 'network-core-routes.json'
    $CodexConfigPath = Join-Path $testRoot 'config.toml'
    $CodexEnvPath = Join-Path $testRoot '.env'
    $ShortcutPath = Join-Path $testRoot 'optimized.lnk'
    $SafeShortcutPath = Join-Path $testRoot 'safe.lnk'
    $WatchdogStartupShortcutPath = Join-Path $testRoot 'watchdog-startup.lnk'
    New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null

    $baseline = [ordered]@{
        $CodexConfigPath = 'config-before'
        $CodexEnvPath = ''
        $NetworkHealthPath = 'health-before'
        $TransportStatePath = 'transport-before'
        $CoreRouteStatePath = 'routes-before'
        $InstalledManager = 'manager-before'
        $InstalledNetworkHealthModule = 'module-before'
        $InstalledNetworkRuntimeObserver = 'observer-before'
        $InstalledNetworkWatchdog = 'watchdog-before'
        $ShortcutPath = 'shortcut-before'
    }
    foreach ($entry in $baseline.GetEnumerator()) {
        [IO.File]::WriteAllText([string]$entry.Key, [string]$entry.Value, [Text.UTF8Encoding]::new($false))
    }

    function Install-CodexHttpTransport {
        [IO.File]::WriteAllText($CodexConfigPath, 'config-mutated', [Text.UTF8Encoding]::new($false))
        return [pscustomobject]@{ Enabled = $true; Reason = 'test' }
    }
    function Sync-CodexProxyEnv {
        param([switch]$VerifyRemote, [switch]$ForceNative)
        [IO.File]::WriteAllText($CodexEnvPath, 'env-mutated', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($NetworkHealthPath, 'health-mutated', [Text.UTF8Encoding]::new($false))
        return [pscustomobject]@{
            NetworkMode = 'VpnNativeHttps'
            Reason = 'test'
            ProxyUri = $null
        }
    }
    function Get-CodexDesktopExecutable { return "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
    $script:shortcutWrites = 0
    function Set-CodexLaunchShortcut {
        param([string]$Path, [string]$LaunchMode, [string]$Description, [string]$CodexExecutable)
        $script:shortcutWrites++
        [IO.File]::WriteAllText($Path, "shortcut-mutated-$script:shortcutWrites", [Text.UTF8Encoding]::new($false))
        if ($script:shortcutWrites -eq 2) { throw 'injected shortcut failure' }
    }

    $failed = $false
    try {
        Install-Hotpatch | Out-Null
    }
    catch {
        $failed = $true
        Assert-True ($_.Exception.Message -match '已恢复安装前状态') '安装失败必须明确报告已回滚。'
    }
    Assert-True $failed '测试必须命中注入的安装失败。'
    foreach ($entry in $baseline.GetEnumerator()) {
        Assert-FileText -Path ([string]$entry.Key) -Expected ([string]$entry.Value) -Message '安装失败后必须恢复每个既有文件。'
    }
    Assert-True ((Get-Item -LiteralPath $CodexEnvPath).Length -eq 0) '安装失败后必须把原有空 .env 恢复为 0 字节文件。'
    Assert-True (-not (Test-Path -LiteralPath $SafeShortcutPath -PathType Leaf)) '安装前不存在的安全快捷方式必须在回滚后保持不存在。'
    Assert-True (-not (Test-Path -LiteralPath $WatchdogStartupShortcutPath -PathType Leaf)) '安装前不存在的守护自启入口必须在回滚后保持不存在。'
}
finally {
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        [IO.Directory]::Delete($testRoot, $true)
    }
}

'install rollback tests: PASS'
