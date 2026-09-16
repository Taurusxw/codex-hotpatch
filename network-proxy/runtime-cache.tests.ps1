$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'manage-hotpatch.ps1')
function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-runtime-cache-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $source = Join-Path $testRoot 'source'
    $cache = Join-Path $testRoot 'cache'
    New-Item -ItemType Directory -Path $source | Out-Null
    $names = @('codex.exe', 'codex-code-mode-host.exe', 'codex-windows-sandbox-setup.exe', 'codex-command-runner.exe')
    foreach ($name in $names) { [IO.File]::WriteAllText((Join-Path $source $name), "fixture $name") }
    $first = Repair-CodexDesktopRuntimeCache -SourceDirectory $source -DestinationRoot $cache
    Assert-True ($first.RepairedFiles -eq 4) 'Cold update must prepare every sibling.'
    $directory = Split-Path -Parent $first.Path
    $initialTime = (Get-Item -LiteralPath $first.Path).LastWriteTimeUtc
    $second = Repair-CodexDesktopRuntimeCache -SourceDirectory $source -DestinationRoot $cache
    Assert-True ($second.RepairedFiles -eq 0 -and (Get-Item -LiteralPath $first.Path).LastWriteTimeUtc -eq $initialTime) 'A valid runtime must never be rewritten.'

    # Reproduce an existing incomplete destination and a same-size wrong sibling.
    $broken = Join-Path $directory $names[1]
    $original = [IO.File]::ReadAllText($broken)
    [IO.File]::WriteAllText($broken, ('x' * $original.Length))
    [IO.File]::Delete((Join-Path $directory $names[2]))
    $manifest = Get-CodexDesktopRuntimeManifest -SourceDirectory $source
    Assert-True (-not (Test-CodexDesktopRuntimeFile $broken $manifest.Files[1])) 'Size alone cannot establish compatibility.'
    # A running matching CLI remains locked: repair must leave it untouched.
    $lock = [IO.File]::Open($first.Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { $fixed = Repair-CodexDesktopRuntimeCache -SourceDirectory $source -DestinationRoot $cache }
    finally { $lock.Dispose() }
    Assert-True ($fixed.RepairedFiles -eq 2) 'Incomplete directory must heal without renaming it or replacing the active CLI.'
    Assert-True ((Get-Item -LiteralPath $first.Path).LastWriteTimeUtc -eq $initialTime) 'Active CLI was changed.'

    # A locked corrupt target must fail clearly and be retryable after release.
    [IO.File]::WriteAllText($broken, 'corrupt')
    $lock = [IO.File]::Open($broken, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $blocked = $false
    try {
        try { $null = Repair-CodexDesktopRuntimeCache -SourceDirectory $source -DestinationRoot $cache }
        catch { $blocked = $true }
    } finally { $lock.Dispose() }
    Assert-True $blocked 'Locked corruption must not be reported ready.'
    $retry = Repair-CodexDesktopRuntimeCache -SourceDirectory $source -DestinationRoot $cache
    Assert-True ($retry.RepairedFiles -eq 1) 'Retry must heal after the lock is released.'
    Assert-True (@(Get-ChildItem $directory -Filter '*.tmp').Count -eq 0) 'Failed publication left a temporary file.'

    [IO.File]::AppendAllText((Join-Path $source $names[3]), ' next release')
    $updated = Repair-CodexDesktopRuntimeCache -SourceDirectory $source -DestinationRoot $cache
    Assert-True ($updated.Hash -ne $first.Hash -and $updated.RepairedFiles -eq 4) 'A sibling-only update must select a new full runtime.'
    Assert-True (Test-Path -LiteralPath $first.Path) 'Preparing an update must preserve the previous active runtime.'

    $nodeSource = Join-Path $source 'cua_node'
    $moduleDirectory = Join-Path $nodeSource 'bin\node_modules\fixture'
    New-Item -ItemType Directory -Path $moduleDirectory -Force | Out-Null
    foreach ($relative in @('manifest.json', 'bin/node.exe', 'bin/node_repl.exe', 'bin/node_modules/fixture/index.js')) {
        [IO.File]::WriteAllText((Join-Path $nodeSource $relative), "fixture $relative")
    }
    $combined = Repair-CodexDesktopRuntimeCache -SourceDirectory $source -DestinationRoot $cache -IncludeNode
    Assert-True ($combined.NodeRuntime.RepairedFiles -eq 4) 'Node preparation must include the dependency tree.'
    $nodeRoot = Split-Path -Parent (Split-Path -Parent $combined.NodeRuntime.Path)
    $dependencyPath = Join-Path $nodeRoot 'bin/node_modules/fixture/index.js'
    [IO.File]::WriteAllText($dependencyPath, 'damaged module')
    $healed = Repair-CodexDesktopRuntimeCache -SourceDirectory $source -DestinationRoot $cache -IncludeNode
    Assert-True ($healed.NodeRuntime.Hash -eq $combined.NodeRuntime.Hash -and $healed.NodeRuntime.RepairedFiles -eq 1) 'Dependency corruption must heal even when the official identity is unchanged.'
    $unchanged = Repair-CodexDesktopRuntimeCache -SourceDirectory $source -DestinationRoot $cache -IncludeNode
    Assert-True ($unchanged.NodeRuntime.RepairedFiles -eq 0) 'Matching Node runtime must be preserved.'

    [IO.File]::WriteAllText((Join-Path $source 'rg.exe'), 'fixture ripgrep')
    $withSearch = Repair-CodexDesktopRuntimeCache -SourceDirectory $source -DestinationRoot $cache -IncludeRipgrep
    Assert-True ($withSearch.RipgrepRuntime.RepairedFiles -eq 1) 'Cold update must prepare the search executable.'
    Assert-True ($withSearch.Hash -eq $unchanged.Hash -and $withSearch.RipgrepRuntime.Hash -ne $withSearch.Hash) 'Ripgrep must keep its separate official hash directory, without changing CLI identity.'
    $searchTime = (Get-Item -LiteralPath $withSearch.RipgrepRuntime.Path).LastWriteTimeUtc
    $searchAgain = Repair-CodexDesktopRuntimeCache -SourceDirectory $source -DestinationRoot $cache -IncludeRipgrep
    Assert-True ($searchAgain.RipgrepRuntime.RepairedFiles -eq 0 -and (Get-Item -LiteralPath $withSearch.RipgrepRuntime.Path).LastWriteTimeUtc -eq $searchTime) 'Matching search executable must not be rewritten.'
    [IO.File]::WriteAllText($withSearch.RipgrepRuntime.Path, 'corrupt ripgrep')
    $searchRepair = Repair-CodexDesktopRuntimeCache -SourceDirectory $source -DestinationRoot $cache -IncludeRipgrep
    Assert-True ($searchRepair.RipgrepRuntime.RepairedFiles -eq 1 -and $searchRepair.RepairedFiles -eq 0) 'Search repair must not touch matching CLI files.'
    [IO.File]::AppendAllText((Join-Path $source 'rg.exe'), ' update')
    $searchUpdate = Repair-CodexDesktopRuntimeCache -SourceDirectory $source -DestinationRoot $cache -IncludeRipgrep
    Assert-True ($searchUpdate.RipgrepRuntime.Hash -ne $withSearch.RipgrepRuntime.Hash -and (Test-Path -LiteralPath $withSearch.RipgrepRuntime.Path)) 'Search update must use a new identity and preserve the old runtime.'

    & {
        $script:runtimePrepared = $false
        function Get-CodexDesktopExecutable { return 'C:\fixture\ChatGPT.exe' }
        function Get-AvailableLoopbackPort { return 12345 }
        function Repair-CodexDesktopRuntimeCache {
            param([switch]$IncludeNode, [switch]$IncludeRipgrep)
            Assert-True $IncludeNode.IsPresent 'Both desktop launch paths must include Node preparation.'
            Assert-True $IncludeRipgrep.IsPresent 'Both desktop launch paths must include search preparation.'
            $script:runtimePrepared = $true
        }
        function Start-Process {
            param($FilePath, $ArgumentList, $WorkingDirectory, [switch]$PassThru)
            Assert-True $script:runtimePrepared 'Runtime preparation must precede desktop launch.'
            return [pscustomobject]@{ Id = 1 }
        }
        $null = Start-CodexDesktopProcess
        $script:runtimePrepared = $false
        $null = Invoke-CodexDesktopActivation
    }
    Write-Output 'runtime-cache tests passed'
}
finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\codex-runtime-cache-'
    if (-not $resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
