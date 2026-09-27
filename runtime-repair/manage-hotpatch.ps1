[CmdletBinding()]
param([ValidateSet('Status', 'Repair', 'Install', 'Disable')][string]$Mode = 'Status')

. (Join-Path $PSScriptRoot 'runtime-cache.ps1')

$PatchVersion = '1.0.0'
$InstallRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\hotpatches\runtime-repair'
$WatchdogPath = Join-Path $InstallRoot 'runtime-watchdog.ps1'
$StartupPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'Codex 运行时修复.lnk'
$PowerShellPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Get-RuntimeRepairProcess {
    $pattern = '(?i)-File\s+"' + [regex]::Escape($WatchdogPath) + '"(?:\s|$)'
    @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match $pattern })
}

function Stop-RuntimeRepairProcess {
    foreach ($watcher in @(Get-RuntimeRepairProcess)) {
        # Bind the stop to the observed process lifetime, never a reused PID.
        $process = Get-Process -Id $watcher.ProcessId -ErrorAction SilentlyContinue
        if ($null -ne $process -and [Math]::Abs($process.StartTime.ToUniversalTime().Ticks - $watcher.CreationDate.ToUniversalTime().Ticks) -lt 10) {
            $process | Stop-Process -ErrorAction Stop
            $process.WaitForExit()
        }
    }
}

function Get-RuntimeRepairStatus {
    $watchers = @(Get-RuntimeRepairProcess)
    $statusPath = Join-Path $InstallRoot 'runtime-status.json'
    $state = if (Test-Path -LiteralPath $statusPath) { Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json } else { $null }
    $ready = $false
    if ($null -ne $state -and $state.ProcessId -in @($watchers | ForEach-Object { $_.ProcessId })) {
        $ready = $state.Ready -and ([DateTime]::UtcNow - ([DateTime]$state.CheckedAtUtc).ToUniversalTime()).TotalSeconds -lt 180
    }
    [pscustomobject]@{
        Version = $PatchVersion; Installed = (Test-Path -LiteralPath $WatchdogPath)
        StartupEnabled = (Test-Path -LiteralPath $StartupPath)
        ProcessIds = @($watchers | ForEach-Object { $_.ProcessId }); Ready = $ready; State = $state
    }
}

if ($MyInvocation.InvocationName -eq '.') { return }

switch ($Mode) {
    'Status' { Get-RuntimeRepairStatus | ConvertTo-Json -Depth 8 }
    'Repair' { Repair-CodexDesktopRuntimeCache -IncludeNode -IncludeRipgrep | ConvertTo-Json -Depth 6 }
    'Install' {
        # Fail before replacing a working installation if this Appx layout is unsupported.
        $null = Repair-CodexDesktopRuntimeCache -IncludeNode -IncludeRipgrep
        Stop-RuntimeRepairProcess
        New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
        foreach ($name in @('runtime-cache.ps1', 'runtime-watchdog.ps1', 'manage-hotpatch.ps1', 'README.md')) {
            $source = Join-Path $PSScriptRoot $name
            $target = Join-Path $InstallRoot $name
            if ([IO.Path]::GetFullPath($source) -ne [IO.Path]::GetFullPath($target)) {
                Copy-Item -LiteralPath $source -Destination $target -Force -ErrorAction Stop
            }
        }
        $arguments = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $WatchdogPath + '"'
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($StartupPath)
        $shortcut.TargetPath = $PowerShellPath
        $shortcut.Arguments = $arguments
        $shortcut.WorkingDirectory = $InstallRoot
        $shortcut.Description = 'Prepare official Codex runtime caches after desktop updates.'
        $shortcut.Save()
        $process = Start-Process -FilePath $PowerShellPath -ArgumentList $arguments -WindowStyle Hidden -PassThru
        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        do {
            Start-Sleep -Milliseconds 500
            $status = Get-RuntimeRepairStatus
            if ($status.Ready -and $process.Id -in $status.ProcessIds) { $status | ConvertTo-Json -Depth 8; return }
            if ($process.HasExited) { throw 'Runtime repair watchdog exited during startup.' }
        } while ([DateTime]::UtcNow -lt $deadline)
        throw "Runtime preparation is still pending; inspect $InstallRoot\runtime-watchdog.log."
    }
    'Disable' {
        Stop-RuntimeRepairProcess
        if (Test-Path -LiteralPath $StartupPath) { Remove-Item -LiteralPath $StartupPath -Force }
        Get-RuntimeRepairStatus | ConvertTo-Json -Depth 8
    }
}
