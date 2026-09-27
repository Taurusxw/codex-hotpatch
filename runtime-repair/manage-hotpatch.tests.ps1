$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'manage-hotpatch.ps1')
function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-runtime-lifecycle-' + [Guid]::NewGuid().ToString('N'))
$fixture = $null
try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $InstallRoot = $testRoot
    $WatchdogPath = Join-Path $testRoot 'runtime-watchdog.ps1'
    $StartupPath = Join-Path $testRoot 'fixture.lnk'
    [IO.File]::WriteAllText($WatchdogPath, 'Start-Sleep -Seconds 120')
    $initial = Get-RuntimeRepairStatus
    Assert-True (-not $initial.Ready -and $initial.ProcessIds.Count -eq 0) 'Missing watcher is not ready.'
    $fixture = Start-Process -FilePath $PowerShellPath -ArgumentList ('-NoProfile -WindowStyle Hidden -File "' + $WatchdogPath + '"') -WindowStyle Hidden -PassThru
    $state = @{ ProcessId = $fixture.Id; Ready = $true; CheckedAtUtc = [DateTime]::UtcNow.ToString('o') }
    $statusPath = Join-Path $testRoot 'runtime-status.json'
    [IO.File]::WriteAllText($statusPath, ($state | ConvertTo-Json))
    $status = Get-RuntimeRepairStatus
    Assert-True ($status.Ready -and $fixture.Id -in $status.ProcessIds) 'Exact fixture watcher must be found.'
    $state.CheckedAtUtc = [DateTime]::UtcNow.AddMinutes(-10).ToString('o')
    [IO.File]::WriteAllText($statusPath, ($state | ConvertTo-Json))
    Assert-True (-not (Get-RuntimeRepairStatus).Ready) 'Stale status must not be reported ready.'
    Stop-RuntimeRepairProcess
    Assert-True ($fixture.WaitForExit(5000)) 'Stop must terminate the observed fixture process.'
    Assert-True (-not (Get-RuntimeRepairStatus).Ready) 'Retained status file does not make a stopped watcher ready.'
    Write-Output 'runtime lifecycle tests passed'
}
finally {
    if ($null -ne $fixture -and -not $fixture.HasExited) { $fixture | Stop-Process -ErrorAction SilentlyContinue; $fixture.WaitForExit() }
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\codex-runtime-lifecycle-'
    if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe lifecycle fixture cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
