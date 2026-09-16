$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'manage-hotpatch.ps1')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("codex-launch-recovery-$PID-$([Guid]::NewGuid().ToString('N'))")
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    & {
        $script:testCliPath = Join-Path $testRoot 'codex.exe'
        [IO.File]::WriteAllText($script:testCliPath, 'fixture: never execute')
        function Get-CodexDesktopOfficialCliPath { return $script:testCliPath }
        function Get-CodexCliBinaryVersion { param($Path) return '0.153.2' }
        function Get-CodexActiveDesktopCliPaths { throw 'Exact selection must skip active discovery.' }
        function Get-CodexStagedCliPaths { throw 'Usable selection must skip staged discovery.' }
        $selected = Get-CodexOperationalCli
        Assert-True ($selected.ExactDesktopMatch -and $selected.Source -eq 'CurrentDesktopStable') 'A usable exact candidate must short-circuit discovery.'

        function Get-CodexDesktopOfficialCliPath { return $null }
        function Get-CodexActiveDesktopCliPaths { return @($script:testCliPath) }
        function Test-CodexOpenAiNpmCliPath { param($Path) return $Path -eq $script:testCliPath }
        $selected = Get-CodexOperationalCli
        Assert-True ($selected.Source -eq 'ActiveDesktopChild' -and -not $selected.ExactDesktopMatch) 'A usable active candidate must short-circuit staged discovery without claiming exact validation.'

        function Get-CodexActiveDesktopCliPaths { return @() }
        function Test-CodexOpenAiNpmCliPath { param($Path) return $false }
        function Get-CodexStagedCliPaths { return @($script:testCliPath) }
        $selected = Get-CodexOperationalCli
        Assert-True ($selected.Source -eq 'PreviousDesktopBootstrap' -and -not $selected.ExactDesktopMatch) 'Cold update must permit a usable staged bootstrap without claiming exact validation.'

        function Get-CodexDesktopOfficialCliPath { return $script:testCliPath }
        function Get-CodexCliBinaryVersion { param($Path) return $null }
        Assert-True ($null -eq (Get-CodexOperationalCli)) 'An unexecutable exact or fallback binary must not be selected.'
    }

    & {
        $WatchdogStartupShortcutPath = Join-Path $testRoot 'startup.lnk'
        $CodexConfigPath = Join-Path $testRoot 'config.toml'
        $script:testRunning = $false
        $script:testActions = [Collections.Generic.List[string]]::new()
        function Get-Process { param($Name, $ErrorAction) if ($script:testRunning) { return [pscustomobject]@{ Id = 123 } } }
        function Get-CodexDesktopExecutable { return 'mock-desktop.exe' }
        function Set-CodexWatchdogStartupShortcut {
            param($CodexExecutable)
            [IO.File]::WriteAllText($WatchdogStartupShortcutPath, 'startup fixture')
        }
        function Install-CodexHttpTransport { return [pscustomobject]@{ Enabled = $true; Reason = 'mock' } }
        function Sync-CodexProxyEnv {
            param([switch]$VerifyRemote, [switch]$ForceNative)
            Assert-True $VerifyRemote.IsPresent 'Cold optimized launch must verify the route.'
            return [pscustomobject]@{ NetworkMode = 'VpnExplicitHttps'; ProxyUri = [Uri]'http://127.0.0.1:57777'; Reason = 'mock' }
        }
        function Set-CodexProxyEnvironment { param($ProxyUri) $script:testActions.Add('proxy'); return 'mock-proxy' }
        function Clear-CodexProxyEnvironment { $script:testActions.Add('native') }
        function Remove-ManagedCodexProxyEnv { }
        function Start-CodexDesktopProcess {
            $script:testActions.Add('desktop')
            return [pscustomobject]@{ DebugPort = 9222; CliOverrideReason = 'mock' }
        }
        function Start-CodexNetworkWatchdog { $script:testActions.Add('watchdog'); return [pscustomobject]@{ Id = 456 } }
        function Stop-CodexNetworkWatchdog { $script:testActions.Add('stop-watchdog') }
        function Invoke-CodexDesktopActivation { $script:testActions.Add('activate') }
        function Set-CodexOfficialTransportFallback {
            param($ExistingText, $RollbackText, $RollbackExists)
            Assert-True (-not (Test-Path -LiteralPath $WatchdogStartupShortcutPath)) 'Safe mode must remove automatic re-enabling before restoring official config.'
            return [pscustomobject]@{ ProviderDefinitionPreserved = $true }
        }

        Start-CodexWithProxy | Out-Null
        Assert-True (($script:testActions -join ',') -eq 'proxy,desktop,watchdog') 'Cold optimized launch must select environment before starting desktop and watchdog.'
        Assert-True (Test-Path -LiteralPath $WatchdogStartupShortcutPath) 'Optimized launch must enable startup.'

        $script:testActions.Clear()
        $script:testRunning = $true
        Start-CodexWithProxy | Out-Null
        Assert-True (($script:testActions -join ',') -eq 'activate,watchdog') 'Update-started desktop must be activated without changing its inherited environment.'

        $script:testActions.Clear()
        $blocked = $false
        try { Start-CodexSafeFallback | Out-Null } catch { $blocked = $true }
        Assert-True ($blocked -and $script:testActions.Count -eq 0) 'Safe launch must not change a running desktop.'

        $script:testRunning = $false
        Start-CodexSafeFallback | Out-Null
        Assert-True (($script:testActions -join ',') -eq 'stop-watchdog,native,desktop') 'Safe launch must stop watchdog before restoring native launch.'
        Assert-True (-not (Test-Path -LiteralPath $WatchdogStartupShortcutPath)) 'Safe mode must persist across logins.'

        $script:testActions.Clear()
        Start-CodexWithProxy | Out-Null
        Assert-True (Test-Path -LiteralPath $WatchdogStartupShortcutPath) 'Returning to optimized launch must restore startup.'
    }
}
finally {
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    if (-not $resolvedTestRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolvedTestRoot) -notlike 'codex-launch-recovery-*') {
        throw 'Refusing to clean an unexpected test directory.'
    }
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
}

'launch-recovery tests: PASS (isolated orchestration, not a live GUI cold start)'
