Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$DesktopOfficialCliRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'

function Get-CodexDesktopPackage {
    $packages = @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop | Sort-Object { [Version]$_.Version } -Descending)
    if ($packages.Count -eq 0) { throw '未找到当前用户的 OpenAI.Codex Appx 包。' }
    return $packages[0]
}

function Get-CodexDesktopBundledCliPath {
    param([AllowNull()]$Package = (Get-CodexDesktopPackage))

    if ($null -eq $Package) { return $null }
    foreach ($relativePath in @('app\resources\codex.exe', 'app\resources\bin\codex.exe', 'app\resources\bin\codex')) {
        $candidate = Join-Path ([string]$Package.InstallLocation) $relativePath
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Get-CodexDesktopRuntimeManifest {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDirectory,
        [string[]]$Names = @('codex.exe', 'codex-code-mode-host.exe', 'codex-windows-sandbox-setup.exe', 'codex-command-runner.exe')
    )

    # Same order and UTF-8 hash input as Desktop 26.903.9818's bundled resolver.
    $inputText = New-Object Text.StringBuilder
    $files = @(foreach ($name in $names) {
        $source = Join-Path $SourceDirectory $name
        $item = Get-Item -LiteralPath $source -ErrorAction Stop
        $digest = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
        [void]$inputText.Append($name).Append([char]0).Append($digest).Append([char]0)
        [pscustomobject]@{ Name = $name; Source = $source; Length = $item.Length; Digest = $digest }
    })
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($inputText.ToString()))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    return [pscustomobject]@{ Hash = $digest.Substring(0, 16); Files = $files }
}

function Test-CodexDesktopRuntimeFile {
    param([string]$Path, $Descriptor)
    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    return $null -ne $item -and -not $item.PSIsContainer -and $item.Length -eq $Descriptor.Length -and
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash -eq $Descriptor.Digest
}

function Repair-CodexDesktopRuntimeCache {
    param(
        [string]$SourceDirectory = (Split-Path -Parent (Get-CodexDesktopBundledCliPath)),
        [string]$DestinationRoot = $DesktopOfficialCliRoot,
        [ValidateSet('Cli', 'Node', 'Ripgrep')][string]$RuntimeKind = 'Cli',
        [switch]$IncludeNode,
        [switch]$IncludeRipgrep
    )

    $entryPoint = 'codex.exe'
    if ($RuntimeKind -eq 'Node') {
        # Desktop 26.908 hashes these identities, but copies the entire CUA tree.
        $identities = @('manifest.json', 'bin/node.exe', 'bin/node_repl.exe')
        $manifest = Get-CodexDesktopRuntimeManifest -SourceDirectory $SourceDirectory -Names $identities
        $entries = @(Get-ChildItem -LiteralPath $SourceDirectory -Recurse -Force -ErrorAction Stop)
        if (@($entries | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count -gt 0) {
            throw 'Linked CUA runtime entries require explicit compatibility review.'
        }
        $prefix = [IO.Path]::GetFullPath($SourceDirectory).TrimEnd('\') + '\'
        $dependencyNames = @($entries | Where-Object { -not $_.PSIsContainer } | ForEach-Object {
            $_.FullName.Substring($prefix.Length).Replace('\', '/')
        } | Where-Object { $_ -notin $identities })
        $dependencies = Get-CodexDesktopRuntimeManifest -SourceDirectory $SourceDirectory -Names $dependencyNames
        # Publish dependencies before the identities accepted by the official resolver.
        $manifest.Files = @($dependencies.Files) + @($manifest.Files | Sort-Object { $_.Name -eq 'manifest.json' })
        $entryPoint = 'bin\node.exe'
    }
    elseif ($RuntimeKind -eq 'Ripgrep') {
        $manifest = Get-CodexDesktopRuntimeManifest -SourceDirectory $SourceDirectory -Names @('rg.exe')
        $entryPoint = 'rg.exe'
    }
    else { $manifest = Get-CodexDesktopRuntimeManifest -SourceDirectory $SourceDirectory }
    $destination = Join-Path $DestinationRoot $manifest.Hash
    $mutex = New-Object Threading.Mutex($false, ('Local\CodexRuntimeCache-' + $manifest.Hash))
    $acquired = $false
    $repaired = 0
    try {
        try { $acquired = $mutex.WaitOne(10000) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'Desktop runtime preparation is busy; retry on the next check.' }
        # Do not rename/delete a runtime directory: the official rename_staging operation
        # repeatedly failed with EPERM here. Publish only mismatching files atomically.
        New-Item -ItemType Directory -Path $destination -Force -ErrorAction Stop | Out-Null
        foreach ($file in $manifest.Files) {
            $target = Join-Path $destination $file.Name
            if (Test-CodexDesktopRuntimeFile -Path $target -Descriptor $file) { continue }
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force -ErrorAction Stop | Out-Null
            $temporary = Join-Path $destination ($file.Name + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
            try {
                Copy-Item -LiteralPath $file.Source -Destination $temporary -ErrorAction Stop
                if (-not (Test-CodexDesktopRuntimeFile -Path $temporary -Descriptor $file)) {
                    throw "Runtime copy verification failed: $($file.Name)"
                }
                # Another official resolver may have completed while this copy was made.
                if (-not (Test-CodexDesktopRuntimeFile -Path $target -Descriptor $file)) {
                    if ([IO.File]::Exists($target)) { [IO.File]::Replace($temporary, $target, [NullString]::Value) }
                    else { [IO.File]::Move($temporary, $target) }
                    $repaired++
                }
            }
            finally {
                if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
            }
        }
        foreach ($file in $manifest.Files) {
            if (-not (Test-CodexDesktopRuntimeFile -Path (Join-Path $destination $file.Name) -Descriptor $file)) {
                throw "Desktop runtime changed during preparation: $($file.Name)"
            }
        }
        $nodeRuntime = $null
        $ripgrepRuntime = $null
        if ($IncludeRipgrep -and $RuntimeKind -eq 'Cli') {
            $ripgrepRuntime = Repair-CodexDesktopRuntimeCache -RuntimeKind Ripgrep `
                -SourceDirectory $SourceDirectory -DestinationRoot $DestinationRoot
        }
        if ($IncludeNode -and $RuntimeKind -eq 'Cli') {
            $nodeRuntime = Repair-CodexDesktopRuntimeCache -RuntimeKind Node `
                -SourceDirectory (Join-Path $SourceDirectory 'cua_node') `
                -DestinationRoot (Join-Path (Split-Path -Parent $DestinationRoot) 'runtimes\cua_node')
        }
        return [pscustomobject]@{ Path = (Join-Path $destination $entryPoint); Hash = $manifest.Hash; RepairedFiles = $repaired; NodeRuntime = $nodeRuntime; RipgrepRuntime = $ripgrepRuntime }
    }
    finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
