Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

function Get-CodexNodeCommand {
    $node = Get-Command 'node.exe' -ErrorAction SilentlyContinue
    if (-not $node) { $node = Get-Command 'node' -ErrorAction SilentlyContinue }
    if (-not $node) { throw 'Node.js is required to run the hotpatch.' }
    return $node.Source
}

function Get-CodexHotpatchInjectorVersion([string]$InjectorPath) {
    $node = Get-CodexNodeCommand
    if (-not (Test-Path -LiteralPath $InjectorPath -PathType Leaf)) {
        throw "热补丁注入器不存在：$InjectorPath"
    }
    $output = & $node $InjectorPath '--version'
    if ($LASTEXITCODE -ne 0) { throw "读取热补丁版本失败，退出码：$LASTEXITCODE" }
    return [string](($output | ConvertFrom-Json).patchVersion)
}

function Invoke-CodexHotpatchInjector(
    [string]$InjectorPath,
    [string]$InjectorMode,
    [int]$Port
) {
    $node = Get-CodexNodeCommand
    if (-not (Test-Path -LiteralPath $InjectorPath -PathType Leaf)) {
        throw "热补丁注入器不存在：$InjectorPath"
    }
    $output = & $node $InjectorPath $InjectorMode $Port
    if ($LASTEXITCODE -ne 0) { throw "热补丁注入失败，退出码：$LASTEXITCODE" }
    return $output | ConvertFrom-Json
}

function Get-CodexDevToolsTargets([int]$Port) {
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.UseProxy = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromMilliseconds(1200)
    try {
        $json = $client.GetStringAsync("http://127.0.0.1:$Port/json/list").GetAwaiter().GetResult()
        return @($json | ConvertFrom-Json)
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

function Get-CodexDebugPort {
    try {
        $processes = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'ChatGPT.exe'" `
            -OperationTimeoutSec 3 -ErrorAction Stop | Where-Object {
                $_.CommandLine -and
                $_.CommandLine -notmatch '--type=' -and
                $_.CommandLine -match '--remote-debugging-port=\d+'
            } | Sort-Object CreationDate -Descending)
    }
    catch {
        return $null
    }

    $fallbackPort = $null
    foreach ($process in $processes) {
        if ($process.CommandLine -notmatch '--remote-debugging-port=(\d+)') { continue }
        $port = [int]$Matches[1]
        try {
            $targets = @(Get-CodexDevToolsTargets -Port $port)
            if (@($targets | Where-Object {
                $_.type -eq 'page' -and
                $_.url -like 'app://-/index.html*' -and
                $_.webSocketDebuggerUrl
            }).Count -gt 0) {
                return $port
            }
        }
        catch {
            # The root process may exist before Electron exposes /json/list.
        }

        if (-not $fallbackPort -and
            ($process.ExecutablePath -match '(?i)\\WindowsApps\\OpenAI\.Codex_' -or
             $process.CommandLine -match '(?i)\\OpenAI\.Codex_')) {
            $fallbackPort = $port
        }
    }
    return $fallbackPort
}

function Get-CodexHotpatchHelperProcesses(
    [string]$InstalledManager,
    [string]$InstalledInjector
) {
    $processes = @(Get-CimInstance Win32_Process)
    return [pscustomobject]@{
        WatcherProcesses = @($processes | Where-Object {
            $_.Name -in @('powershell.exe', 'pwsh.exe') -and
            $_.CommandLine -like "*$InstalledManager*" -and
            $_.CommandLine -match '-Mode\s+Watch'
        })
        InjectorProcesses = @($processes | Where-Object {
            $_.Name -eq 'node.exe' -and
            $_.CommandLine -like "*$InstalledInjector*" -and
            $_.CommandLine -match '--watch-port\s+\d+'
        })
    }
}

function Stop-CodexHotpatchHelpers(
    [string]$InstalledManager,
    [string]$InstalledInjector
) {
    $helpers = Get-CodexHotpatchHelperProcesses -InstalledManager $InstalledManager `
        -InstalledInjector $InstalledInjector
    $processIds = @(
        @($helpers.WatcherProcesses) + @($helpers.InjectorProcesses) |
            Select-Object -ExpandProperty ProcessId -Unique
    )
    if ($processIds.Count -eq 0) { return }

    $trackedProcesses = @($processIds | ForEach-Object {
        Get-Process -Id $_ -ErrorAction SilentlyContinue
    })
    foreach ($process in $trackedProcesses) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }

    # Wait for process teardown so named mutexes are released before a replacement
    # watcher starts. Without this barrier a rapid reinstall can launch a watcher
    # that observes the old mutex, exits cleanly, and leaves no supervisor running.
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    $timedOut = @()
    foreach ($process in $trackedProcesses) {
        try {
            $remainingMilliseconds = [int][Math]::Max(
                0,
                [Math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            )
            if (-not $process.HasExited -and -not $process.WaitForExit($remainingMilliseconds)) {
                $timedOut += $process.Id
            }
        }
        catch {
            # A process that disappeared between discovery and waiting is stopped.
        }
        finally {
            $process.Dispose()
        }
    }
    if ($timedOut.Count -gt 0) {
        throw "Timed out waiting for old hotpatch helpers to exit: $($timedOut -join ', ')"
    }
}

function Wait-CodexHotpatchWatcherReady(
    [string]$InstalledManager,
    [string]$InstalledInjector,
    [int]$TimeoutMilliseconds = 5000,
    [int]$StabilityMilliseconds = 500
) {
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $helpers = Get-CodexHotpatchHelperProcesses -InstalledManager $InstalledManager `
            -InstalledInjector $InstalledInjector
        $watcher = @($helpers.WatcherProcesses | Sort-Object CreationDate -Descending | Select-Object -First 1)
        if ($watcher.Count -gt 0) {
            $watcherId = [int]$watcher[0].ProcessId
            Start-Sleep -Milliseconds $StabilityMilliseconds
            $confirmation = Get-CodexHotpatchHelperProcesses -InstalledManager $InstalledManager `
                -InstalledInjector $InstalledInjector
            if (@($confirmation.WatcherProcesses | Where-Object {
                [int]$_.ProcessId -eq $watcherId
            }).Count -gt 0) {
                return
            }
        }
        Start-Sleep -Milliseconds 100
    }
    throw 'Hotpatch watcher did not remain running after launch.'
}

function Start-CodexHotpatchWatcher(
    [string]$InstalledManager,
    [string]$InstalledInjector,
    [string]$InstallRoot
) {
    $helpers = Get-CodexHotpatchHelperProcesses -InstalledManager $InstalledManager `
        -InstalledInjector $InstalledInjector
    if (@($helpers.WatcherProcesses).Count -gt 0) { return }
    $log = Join-Path $InstallRoot 'watch.log'
    $errorLog = Join-Path $InstallRoot 'watch.err.log'
    $arguments = @(
        '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
        '-File', ('"' + $InstalledManager + '"'), '-Mode', 'Watch'
    )
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden `
        -WorkingDirectory $InstallRoot `
        -RedirectStandardOutput $log -RedirectStandardError $errorLog | Out-Null
    Wait-CodexHotpatchWatcherReady -InstalledManager $InstalledManager `
        -InstalledInjector $InstalledInjector
}

function Stop-CodexInjectorProcess([Diagnostics.Process]$Process) {
    if (-not $Process) { return }
    try {
        if (-not $Process.HasExited) {
            Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
            $null = $Process.WaitForExit(2000)
        }
    }
    finally {
        $Process.Dispose()
    }
}

function Start-CodexInjectorProcess([string]$NodePath, [string]$InjectorPath, [int]$Port) {
    $arguments = @('"' + $InjectorPath + '"', '--watch-port', [string]$Port)
    return Start-Process -FilePath $NodePath -ArgumentList $arguments -PassThru -WindowStyle Hidden `
        -WorkingDirectory (Split-Path -Parent $InjectorPath)
}

function Test-CodexInjectorInstalled([string]$NodePath, [string]$InjectorPath, [int]$Port) {
    try {
        $output = & $NodePath $InjectorPath '--status' $Port 2>$null
        if ($LASTEXITCODE -ne 0) { return $false }
        $status = $output | ConvertFrom-Json
        $targets = @($status.targets)
        return $targets.Count -gt 0 -and
            @($targets | Where-Object { $_.result -and $_.result.installed }).Count -gt 0
    }
    catch {
        return $false
    }
}

function Invoke-CodexInjectorOnce([string]$NodePath, [string]$InjectorPath, [int]$Port) {
    $output = & $NodePath $InjectorPath '--once' $Port 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Hotpatch self-heal failed with exit code ${LASTEXITCODE}: $($output -join ' ')"
    }
}

function Start-CodexInjectorSupervisor {
    param([Parameter(Mandatory = $true)][string]$InjectorPath)

    if (-not (Test-Path -LiteralPath $InjectorPath -PathType Leaf)) {
        throw "Hotpatch injector not found: $InjectorPath"
    }

    $node = Get-CodexNodeCommand
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $hasher.ComputeHash(
            [Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($InjectorPath).ToLowerInvariant())
        )
    }
    finally {
        $hasher.Dispose()
    }
    $mutexSuffix = ((@($hashBytes | ForEach-Object { $_.ToString('x2') })) -join '').Substring(0, 20)
    $createdNew = $false
    $mutex = [Threading.Mutex]::new($true, "Local\CodexHotpatchSupervisor_$mutexSuffix", [ref]$createdNew)
    if (-not $createdNew) {
        $mutex.Dispose()
        return
    }

    $injectorProcess = $null
    $activePort = $null
    $nextVerificationAt = [DateTime]::MinValue
    try {
        while ($true) {
            $port = Get-CodexDebugPort
            $injectorExited = -not $injectorProcess
            if ($injectorProcess) {
                try { $injectorExited = $injectorProcess.HasExited } catch { $injectorExited = $true }
            }

            if (-not $port) {
                if ($injectorProcess) {
                    Stop-CodexInjectorProcess -Process $injectorProcess
                    $injectorProcess = $null
                    $activePort = $null
                }
                Start-Sleep -Seconds 2
                continue
            }

            if ($injectorExited -or $activePort -ne $port) {
                if ($injectorProcess) {
                    Stop-CodexInjectorProcess -Process $injectorProcess
                }
                try {
                    $injectorProcess = Start-CodexInjectorProcess -NodePath $node `
                        -InjectorPath $InjectorPath -Port $port
                    $activePort = $port
                    $nextVerificationAt = [DateTime]::UtcNow.AddSeconds(8)
                    "$(Get-Date -Format o) supervising Codex DevTools port $port (injector PID $($injectorProcess.Id))"
                }
                catch {
                    $injectorProcess = $null
                    $activePort = $null
                    Write-Error -ErrorAction Continue "$(Get-Date -Format o) injector start failed: $($_.Exception.Message)"
                }
            }

            if ($activePort -eq $port -and [DateTime]::UtcNow -ge $nextVerificationAt) {
                if (-not (Test-CodexInjectorInstalled -NodePath $node -InjectorPath $InjectorPath -Port $port)) {
                    try {
                        Invoke-CodexInjectorOnce -NodePath $node -InjectorPath $InjectorPath -Port $port
                        "$(Get-Date -Format o) renderer self-heal completed on DevTools port $port"
                    }
                    catch {
                        Write-Error -ErrorAction Continue "$(Get-Date -Format o) renderer self-heal failed: $($_.Exception.Message)"
                    }
                }
                $nextVerificationAt = [DateTime]::UtcNow.AddSeconds(10)
            }
            Start-Sleep -Seconds 2
        }
    }
    finally {
        if ($injectorProcess) {
            Stop-CodexInjectorProcess -Process $injectorProcess
        }
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

Export-ModuleMember -Function Get-CodexNodeCommand, Get-CodexDebugPort, `
    Get-CodexHotpatchInjectorVersion, Invoke-CodexHotpatchInjector, `
    Get-CodexHotpatchHelperProcesses, Stop-CodexHotpatchHelpers, `
    Wait-CodexHotpatchWatcherReady, Start-CodexHotpatchWatcher, Start-CodexInjectorSupervisor
