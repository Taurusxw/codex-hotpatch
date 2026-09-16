[CmdletBinding()]
param(
    [ValidateSet('Install', 'Uninstall', 'SyncEnv', 'Launch', 'SafeLaunch', 'Doctor', 'Status')]
    [string]$Mode = 'Status'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PatchName = 'CodexNetworkProxyHotpatch'
$PatchVersion = '1.14.21'
$ManagerSourcePath = $PSCommandPath
$InstallRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\hotpatches\network-proxy'
$ExplicitProxyDisabledPath = Join-Path $InstallRoot 'explicit-proxy.disabled'
$HttpTransportDisabledPath = Join-Path $InstallRoot 'https-only.disabled'
$InstalledManager = Join-Path $InstallRoot 'manage-hotpatch.ps1'
$NetworkHealthModulePath = Join-Path $PSScriptRoot 'network-health.psm1'
$NetworkRuntimeObserverPath = Join-Path $PSScriptRoot 'network-runtime-observer.psm1'
$NetworkWatchdogPath = Join-Path $PSScriptRoot 'network-watchdog.ps1'
$InstalledNetworkHealthModule = Join-Path $InstallRoot 'network-health.psm1'
$InstalledNetworkRuntimeObserver = Join-Path $InstallRoot 'network-runtime-observer.psm1'
$InstalledNetworkWatchdog = Join-Path $InstallRoot 'network-watchdog.ps1'
$LegacyCliCompatRoot = Join-Path $InstallRoot 'cli-compat'
$LegacyDesktopCliRoot = Join-Path $InstallRoot 'desktop-cli'
$LegacyDesktopCliPath = Join-Path $LegacyDesktopCliRoot 'codex.exe'
$LegacyDesktopCliEnvironmentBackupPath = Join-Path $LegacyDesktopCliRoot 'environment-backup.json'
$DesktopOfficialCliRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
$NetworkHealthPath = Join-Path $InstallRoot 'network-health.json'
$TransportStatePath = Join-Path $InstallRoot 'transport-state.json'
$NetworkRuntimeCursorPath = Join-Path $InstallRoot 'network-runtime-cursor.json'
$CoreRouteStatePath = Join-Path $InstallRoot 'network-core-routes.json'
$CodexRuntimeLogsPath = Join-Path $env:USERPROFILE '.codex\logs_2.sqlite'
$ShortcutPath = Join-Path ([Environment]::GetFolderPath('Programs')) 'Codex（代理优化）.lnk'
$SafeShortcutPath = Join-Path ([Environment]::GetFolderPath('Programs')) 'Codex（官方兼容兜底）.lnk'
$WatchdogStartupShortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'Codex 网络自愈守护.lnk'
$CodexEnvPath = Join-Path $env:USERPROFILE '.codex\.env'
$CodexConfigPath = Join-Path $env:USERPROFILE '.codex\config.toml'
$CodexModelCatalogCachePath = Join-Path $env:USERPROFILE '.codex\models_cache.json'
$EnvBlockStart = '# BEGIN CodexNetworkProxyHotpatch'
$EnvBlockEnd = '# END CodexNetworkProxyHotpatch'
$TransportSelectorStart = '# BEGIN CodexNetworkProxyHotpatch transport selector'
$TransportSelectorEnd = '# END CodexNetworkProxyHotpatch transport selector'
$TransportProviderStart = '# BEGIN CodexNetworkProxyHotpatch HTTP provider'
$TransportProviderEnd = '# END CodexNetworkProxyHotpatch HTTP provider'
$TransportProviderId = 'codex-hotpatch-http'
$NoProxyValue = 'localhost,127.0.0.1,::1'
$RequiredHealthyVpnProbes = 3
$RequiredHealthyNativeProbes = 2
$RequiredRecoveryVpnProbes = 5
$VpnProbeIntervalMilliseconds = 750
$VpnFailureThreshold = 2
$VpnFailureWindow = [TimeSpan]::FromMinutes(10)
$VpnOpenCooldown = [TimeSpan]::FromMinutes(30)
$RuntimeFailureBaseCooldown = [TimeSpan]::FromHours(24)
$RuntimeFailureMaxCooldown = [TimeSpan]::FromDays(7)
$NativeRuntimeFailureThreshold = 2
$NativeRuntimeFailureWindow = [TimeSpan]::FromMinutes(10)
$WatchdogProbeIntervalSeconds = 45
$WatchdogRuntimePollSeconds = 5
$TransportRequestMaxRetries = 6
$TransportStreamMaxRetries = 8
$NativeAuthenticatedProbeTimeoutMilliseconds = 45000
$NativeAuthenticatedProbeCacheTtl = [TimeSpan]::FromMinutes(2)
$AuthenticatedProbeModel = 'gpt-5.6-luna'
$AuthenticatedProbeDisabledFeatures = @(
    'apps',
    'plugins',
    'remote_plugin',
    'recommended_plugins',
    'browser_use',
    'browser_use_external',
    'skill_search',
    'hooks',
    'shell_snapshot'
)
$ValidatedDesktopPackageVersion = [Version]'26.908.4834.0'
$script:NativeAuthenticatedFallbackCache = $null
$script:ExplicitAuthenticatedProbeCache = $null

if (-not (Test-Path -LiteralPath $NetworkHealthModulePath -PathType Leaf)) {
    throw "缺少网络健康模块：$NetworkHealthModulePath"
}
if (-not (Test-Path -LiteralPath $NetworkRuntimeObserverPath -PathType Leaf)) {
    throw "缺少运行期网络日志观察模块：$NetworkRuntimeObserverPath"
}
Import-Module -Name $NetworkHealthModulePath -Force -ErrorAction Stop
Import-Module -Name $NetworkRuntimeObserverPath -Force -ErrorAction Stop

function Get-WinInetProxyUri {
    $settingsPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $settings = Get-ItemProperty -LiteralPath $settingsPath

    if ([int]$settings.ProxyEnable -ne 1) {
        throw 'Windows 用户代理未启用。请先启动代理软件并启用系统代理。'
    }

    $rawProxy = ([string]$settings.ProxyServer).Trim()
    if ([string]::IsNullOrWhiteSpace($rawProxy)) {
        throw 'Windows 用户代理已启用，但 ProxyServer 为空。'
    }

    $endpoint = $rawProxy
    $selectedScheme = 'http'
    if ($rawProxy.Contains('=')) {
        $entries = @{}
        foreach ($part in ($rawProxy -split ';')) {
            if ($part -match '^\s*(?<scheme>https?|socks4?|socks5)\s*=\s*(?<endpoint>[^;]+)\s*$') {
                $entries[$Matches.scheme.ToLowerInvariant()] = $Matches.endpoint.Trim()
            }
        }

        foreach ($candidate in @('https', 'http', 'socks5', 'socks', 'socks4')) {
            if ($entries.ContainsKey($candidate)) {
                $selectedScheme = $candidate
                $endpoint = [string]$entries[$candidate]
                break
            }
        }

        if ($endpoint -eq $rawProxy) {
            throw "不支持的 Windows ProxyServer 格式：$rawProxy"
        }
    }

    if ($endpoint -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
        if ($selectedScheme -like 'socks*') {
            $endpoint = "${selectedScheme}://$endpoint"
        }
        else {
            # WinINET 的 host:port 代理通过 HTTP CONNECT 承载 HTTPS/WSS。
            $endpoint = "http://$endpoint"
        }
    }

    try {
        $proxyUri = [Uri]$endpoint
    }
    catch {
        throw "Windows ProxyServer 不是有效 URI：$endpoint"
    }

    if (-not $proxyUri.IsAbsoluteUri -or [string]::IsNullOrWhiteSpace($proxyUri.Host) -or $proxyUri.Port -le 0) {
        throw "Windows ProxyServer 必须包含主机和端口：$endpoint"
    }
    if (-not [string]::IsNullOrWhiteSpace($proxyUri.UserInfo)) {
        throw '本补丁拒绝读取 ProxyServer 中的明文代理凭据。'
    }
    if ($proxyUri.Scheme -notin @('http', 'https', 'socks', 'socks4', 'socks5')) {
        throw "不支持的代理协议：$($proxyUri.Scheme)"
    }

    return $proxyUri
}

function Test-ProxyListener {
    param(
        [Parameter(Mandatory = $true)][Uri]$ProxyUri,
        [int]$TimeoutMilliseconds = 1500
    )

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($ProxyUri.Host, $ProxyUri.Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMilliseconds)) {
            return $false
        }
        $client.EndConnect($async)
        return $true
    }
    catch {
        return $false
    }
    finally {
        $client.Close()
    }
}

function Invoke-CodexResponsesEndpointProbe {
    param(
        [AllowNull()][Uri]$ProxyUri,
        [ValidateRange(1000, 30000)][int]$TimeoutMilliseconds = 5000
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $response = $null
    try {
        $request = [Net.HttpWebRequest][Net.WebRequest]::Create('https://chatgpt.com/backend-api/codex/responses')
        $request.Method = 'GET'
        $request.AllowAutoRedirect = $false
        $request.Timeout = $TimeoutMilliseconds
        $request.ReadWriteTimeout = $TimeoutMilliseconds
        $request.UserAgent = "CodexNetworkProxyHotpatch/$PatchVersion"
        $request.Proxy = if ($null -ne $ProxyUri) {
            [Net.WebProxy]::new($ProxyUri, $true)
        }
        else {
            $null
        }
        try {
            $response = [Net.HttpWebResponse]$request.GetResponse()
        }
        catch [Net.WebException] {
            if ($null -eq $_.Exception.Response) { throw }
            $response = [Net.HttpWebResponse]$_.Exception.Response
        }
        $statusCode = [int]$response.StatusCode
        return [pscustomobject]@{
            Healthy = $statusCode -ge 200 -and $statusCode -lt 500 -and $statusCode -ne 407
            StatusCode = $statusCode
            DurationMs = $stopwatch.ElapsedMilliseconds
            Error = $null
        }
    }
    catch {
        return [pscustomobject]@{
            Healthy = $false
            StatusCode = $null
            DurationMs = $stopwatch.ElapsedMilliseconds
            Error = $_.Exception.Message
        }
    }
    finally {
        if ($null -ne $response) { $response.Close() }
        $stopwatch.Stop()
    }
}

function Set-CodexProxyEnvironment {
    param([Parameter(Mandatory = $true)][Uri]$ProxyUri)

    $proxyValue = $ProxyUri.AbsoluteUri.TrimEnd('/')
    $env:HTTP_PROXY = $proxyValue
    $env:HTTPS_PROXY = $proxyValue
    $env:ALL_PROXY = $proxyValue
    $env:NO_PROXY = $NoProxyValue
    return $proxyValue
}

function Clear-CodexProxyEnvironment {
    Remove-Item Env:HTTP_PROXY,Env:HTTPS_PROXY,Env:ALL_PROXY,Env:NO_PROXY -ErrorAction SilentlyContinue
}

function Get-OptionalObjectProperty {
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Convert-CodexProxyEnvText {
    param(
        [AllowEmptyString()][string]$ExistingText,
        [Parameter(Mandatory = $true)][ValidateSet('VpnProxy', 'OfficialDirect')][string]$NetworkMode,
        [string]$ProxyValue
    )

    if ($NetworkMode -eq 'VpnProxy' -and [string]::IsNullOrWhiteSpace($ProxyValue)) {
        throw 'VPN 代理模式必须提供代理地址。'
    }

    $existingLines = if ([string]::IsNullOrEmpty($ExistingText)) { @() } else { @($ExistingText -split "`r?`n") }
    $startCount = @($existingLines | Where-Object { $_.Trim() -eq $EnvBlockStart }).Count
    $endCount = @($existingLines | Where-Object { $_.Trim() -eq $EnvBlockEnd }).Count
    if ($startCount -ne $endCount -or $startCount -gt 1) {
        throw 'Codex .env 中的网络补丁托管区块标记不完整或重复；为避免覆盖其他配置，已停止同步。'
    }

    $keptLines = New-Object 'System.Collections.Generic.List[string]'
    $insideManagedBlock = $false
    foreach ($line in $existingLines) {
        if ($line.Trim() -eq $EnvBlockStart) {
            $insideManagedBlock = $true
            continue
        }
        if ($insideManagedBlock) {
            if ($line.Trim() -eq $EnvBlockEnd) {
                $insideManagedBlock = $false
            }
            continue
        }
        if ($line -match '^\s*(?i:HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY)\s*=') {
            # These four keys are this module's interface; one authoritative definition avoids dotenv ambiguity.
            continue
        }
        $keptLines.Add($line)
    }

    while ($keptLines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($keptLines[$keptLines.Count - 1])) {
        $keptLines.RemoveAt($keptLines.Count - 1)
    }
    if ($NetworkMode -eq 'VpnProxy') {
        if ($keptLines.Count -gt 0) {
            $keptLines.Add('')
        }
        $keptLines.Add($EnvBlockStart)
        $keptLines.Add("HTTP_PROXY=$ProxyValue")
        $keptLines.Add("HTTPS_PROXY=$ProxyValue")
        $keptLines.Add("ALL_PROXY=$ProxyValue")
        $keptLines.Add("NO_PROXY=$NoProxyValue")
        $keptLines.Add($EnvBlockEnd)
    }

    if ($keptLines.Count -eq 0) {
        return ''
    }
    return ($keptLines -join [Environment]::NewLine) + [Environment]::NewLine
}

function Write-FileBytesAtomically {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes
    )

    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $nonce = [Guid]::NewGuid().ToString('N')
    $tempPath = "$Path.$nonce.tmp"
    $backupPath = "$Path.$nonce.bak"
    try {
        [IO.File]::WriteAllBytes($tempPath, $Bytes)
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [IO.File]::Replace($tempPath, $Path, $backupPath)
        }
        else {
            [IO.File]::Move($tempPath, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) { [IO.File]::Delete($tempPath) }
        if (Test-Path -LiteralPath $backupPath -PathType Leaf) { [IO.File]::Delete($backupPath) }
    }
}

function Test-CodexOriginalProviderLine {
    param([AllowNull()][string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line) -or $Line.Contains("`r") -or $Line.Contains("`n")) {
        return $false
    }
    if ($Line -notmatch '^\s*model_provider\s*=\s*["''](?<provider>[^"'']+)["'']\s*$') {
        return $false
    }
    return $Matches.provider -ne $TransportProviderId
}

function Get-CodexTransportRecoveryState {
    if (-not (Test-Path -LiteralPath $TransportStatePath -PathType Leaf)) { return $null }

    try {
        $state = [IO.File]::ReadAllText($TransportStatePath) | ConvertFrom-Json
        $schemaVersion = Get-OptionalObjectProperty -InputObject $state -Name 'SchemaVersion'
        $patchNameValue = Get-OptionalObjectProperty -InputObject $state -Name 'PatchName'
        $originalProviderWasAbsent = Get-OptionalObjectProperty -InputObject $state -Name 'OriginalProviderWasAbsent'
        $originalProviderLine = Get-OptionalObjectProperty -InputObject $state -Name 'OriginalProviderLine'
        if ([int]$schemaVersion -ne 1 -or [string]$patchNameValue -ne $PatchName -or
            $null -eq $originalProviderWasAbsent) {
            throw '状态架构或补丁标识不匹配。'
        }
        $wasAbsent = [bool]$originalProviderWasAbsent
        if ($wasAbsent) {
            if ($null -ne $originalProviderLine -and -not [string]::IsNullOrWhiteSpace([string]$originalProviderLine)) {
                throw '状态同时声明原 provider 缺失并保存了 provider 行。'
            }
            $originalProviderLine = $null
        }
        elseif (-not (Test-CodexOriginalProviderLine -Line ([string]$originalProviderLine))) {
            throw '状态中的原 model_provider 行无效。'
        }
        return [pscustomobject]@{
            OriginalProviderWasAbsent = $wasAbsent
            OriginalProviderLine = if ($wasAbsent) { $null } else { [string]$originalProviderLine }
        }
    }
    catch {
        throw "Codex 网络传输恢复状态损坏；为避免覆盖用户配置，已停止：$($_.Exception.Message)"
    }
}

function Write-CodexTransportRecoveryState {
    param(
        [AllowNull()][string]$OriginalProviderLine,
        [Parameter(Mandatory = $true)][bool]$OriginalProviderWasAbsent
    )

    if ($OriginalProviderWasAbsent) {
        $OriginalProviderLine = $null
    }
    elseif (-not (Test-CodexOriginalProviderLine -Line $OriginalProviderLine)) {
        throw '拒绝保存无效的原 model_provider 恢复行。'
    }
    $state = [ordered]@{
        SchemaVersion = 1
        PatchName = $PatchName
        OriginalProviderWasAbsent = $OriginalProviderWasAbsent
        OriginalProviderLine = $OriginalProviderLine
    }
    $json = ($state | ConvertTo-Json -Depth 3) + [Environment]::NewLine
    Write-FileBytesAtomically -Path $TransportStatePath -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($json))
}

function Get-CodexTransportOriginalProviderRecord {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    $metadataMatches = [regex]::Matches(
        $Text,
        '(?m)^\s*#\s*original-model-provider-base64:\s*(?<value>\S+)\s*$'
    )
    if ($metadataMatches.Count -ne 1) {
        throw 'Codex 网络传输托管配置缺少唯一的原 model_provider 恢复信息。'
    }
    $encoded = $metadataMatches[0].Groups['value'].Value
    if ($encoded -eq '__ABSENT__') {
        return [pscustomobject]@{ OriginalProviderWasAbsent = $true; OriginalProviderLine = $null }
    }
    try {
        $line = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
    }
    catch {
        throw 'Codex 网络传输托管配置的原 model_provider 恢复信息损坏。'
    }
    if (-not (Test-CodexOriginalProviderLine -Line $line)) {
        throw 'Codex 网络传输托管配置的原 model_provider 恢复行无效。'
    }
    return [pscustomobject]@{ OriginalProviderWasAbsent = $false; OriginalProviderLine = $line }
}

function Get-FileSnapshot {
    param([Parameter(Mandatory = $true)][string]$Path)

    $exists = Test-Path -LiteralPath $Path -PathType Leaf
    [byte[]]$bytes = $null
    if ($exists) {
        $bytes = [IO.File]::ReadAllBytes($Path)
    }
    return [pscustomobject]@{
        Path = $Path
        Exists = $exists
        Bytes = $bytes
    }
}

function Restore-FileSnapshot {
    param([Parameter(Mandatory = $true)]$Snapshot)

    if ($Snapshot.Exists) {
        Write-FileBytesAtomically -Path $Snapshot.Path -Bytes $Snapshot.Bytes
    }
    elseif (Test-Path -LiteralPath $Snapshot.Path -PathType Leaf) {
        [IO.File]::Delete($Snapshot.Path)
    }
}

function Write-CodexEnvTextAtomically {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    Write-FileBytesAtomically -Path $CodexEnvPath -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($Text))
}

function Get-CodexTransportProviderDefinitionLines {
    return @(
        "[model_providers.$TransportProviderId]"
        'name = "OpenAI HTTP (Codex hotpatch)"'
        'wire_api = "responses"'
        'requires_openai_auth = true'
        'supports_websockets = false'
        'supports_standalone_web_search = true'
        "request_max_retries = $TransportRequestMaxRetries"
        "stream_max_retries = $TransportStreamMaxRetries"
    )
}

function Convert-CodexTransportConfigText {
    param(
        [AllowEmptyString()][string]$ExistingText,
        [Parameter(Mandatory = $true)][ValidateSet('Install', 'Fallback', 'Remove')][string]$Action,
        [AllowNull()]$RecoveryState
    )

    $lines = if ([string]::IsNullOrEmpty($ExistingText)) { @() } else { @($ExistingText -split "`r?`n") }
    $selectorStarts = New-Object 'System.Collections.Generic.List[int]'
    $selectorEnds = New-Object 'System.Collections.Generic.List[int]'
    $providerStarts = New-Object 'System.Collections.Generic.List[int]'
    $providerEnds = New-Object 'System.Collections.Generic.List[int]'
    for ($index = 0; $index -lt $lines.Count; $index++) {
        switch ($lines[$index].Trim()) {
            $TransportSelectorStart { $selectorStarts.Add($index) }
            $TransportSelectorEnd { $selectorEnds.Add($index) }
            $TransportProviderStart { $providerStarts.Add($index) }
            $TransportProviderEnd { $providerEnds.Add($index) }
        }
    }

    $hasSelectorBlock = $selectorStarts.Count -eq 1 -and $selectorEnds.Count -eq 1
    $hasProviderBlock = $providerStarts.Count -eq 1 -and $providerEnds.Count -eq 1
    $hasAnySelectorMarker = ($selectorStarts.Count + $selectorEnds.Count) -gt 0
    $hasAnyProviderMarker = ($providerStarts.Count + $providerEnds.Count) -gt 0
    $recoverableDamagedSelector = -not $hasSelectorBlock -and $hasProviderBlock -and
        (($selectorStarts.Count -eq 1 -and $selectorEnds.Count -eq 0) -or
         ($selectorStarts.Count -eq 0 -and $selectorEnds.Count -eq 1))
    $detachedSelector = (-not $hasAnySelectorMarker -or $recoverableDamagedSelector) -and $hasProviderBlock
    if (($hasAnySelectorMarker -and -not $hasSelectorBlock -and -not $recoverableDamagedSelector) -or
        ($hasAnyProviderMarker -and -not $hasProviderBlock) -or
        ($hasSelectorBlock -and -not $hasProviderBlock)) {
        throw 'Codex config.toml 中的网络传输托管标记不完整或重复；为避免覆盖用户配置，已停止。'
    }
    if (($hasSelectorBlock -and $selectorStarts[0] -ge $selectorEnds[0]) -or
        ($hasProviderBlock -and $providerStarts[0] -ge $providerEnds[0])) {
        throw 'Codex config.toml 中的网络传输托管标记顺序无效；为避免覆盖用户配置，已停止。'
    }
    $hasManagedBlocks = $hasSelectorBlock -and $hasProviderBlock

    $baseLines = New-Object 'System.Collections.Generic.List[string]'
    $originalProviderLine = $null
    $originalProviderWasAbsent = $false
    if ($hasManagedBlocks) {
        $originalRecord = Get-CodexTransportOriginalProviderRecord -Text $ExistingText
        $originalProviderLine = $originalRecord.OriginalProviderLine
        $originalProviderWasAbsent = $originalRecord.OriginalProviderWasAbsent
    }
    elseif ($detachedSelector) {
        if ($null -eq $RecoveryState) {
            throw 'Codex 更新已移除网络传输选择器标记，且没有可验证的独立恢复状态；为避免覆盖用户配置，已停止。'
        }
        $recoveryWasAbsent = Get-OptionalObjectProperty -InputObject $RecoveryState -Name 'OriginalProviderWasAbsent'
        $recoveryLine = Get-OptionalObjectProperty -InputObject $RecoveryState -Name 'OriginalProviderLine'
        if ($null -eq $recoveryWasAbsent) {
            throw 'Codex 网络传输恢复状态缺少原 provider 存在性信息。'
        }
        $originalProviderWasAbsent = [bool]$recoveryWasAbsent
        if ($originalProviderWasAbsent) {
            if ($null -ne $recoveryLine -and -not [string]::IsNullOrWhiteSpace([string]$recoveryLine)) {
                throw 'Codex 网络传输恢复状态同时声明原 provider 缺失并保存了 provider 行。'
            }
            $originalProviderLine = $null
        }
        else {
            $originalProviderLine = [string]$recoveryLine
            if (-not (Test-CodexOriginalProviderLine -Line $originalProviderLine)) {
                throw 'Codex 网络传输恢复状态中的原 model_provider 行无效。'
            }
        }
    }

    if ($hasSelectorBlock -or $hasProviderBlock) {
        $index = 0
        while ($index -lt $lines.Count) {
            if ($recoverableDamagedSelector -and
                ($lines[$index].Trim() -in @($TransportSelectorStart, $TransportSelectorEnd) -or
                 $lines[$index].Trim() -match '^# original-model-provider-base64:\s*')) {
                $index++
                continue
            }
            if ($hasSelectorBlock -and $index -eq $selectorStarts[0]) {
                if ($null -ne $originalProviderLine) { $baseLines.Add($originalProviderLine) }
                $index = $selectorEnds[0] + 1
                continue
            }
            if ($hasProviderBlock -and $index -eq $providerStarts[0]) {
                $index = $providerEnds[0] + 1
                continue
            }
            $baseLines.Add($lines[$index])
            $index++
        }
    }
    else {
        foreach ($line in $lines) { $baseLines.Add($line) }
    }

    while ($baseLines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($baseLines[$baseLines.Count - 1])) {
        $baseLines.RemoveAt($baseLines.Count - 1)
    }
    if ($Action -eq 'Remove' -and -not $detachedSelector) {
        if ($baseLines.Count -eq 0) { return '' }
        return ($baseLines -join [Environment]::NewLine) + [Environment]::NewLine
    }

    $orphanProviderIndices = @(
        for ($index = 0; $index -lt $baseLines.Count; $index++) {
            if ($baseLines[$index].Trim() -eq "[model_providers.$TransportProviderId]") { $index }
        }
    )
    if ($orphanProviderIndices.Count -gt 1) {
        throw "Codex config.toml 存在多个 model_providers.$TransportProviderId；已停止修改以避免覆盖。"
    }
    if ($orphanProviderIndices.Count -eq 1) {
        $providerStartIndex = $orphanProviderIndices[0]
        $providerEndIndex = $baseLines.Count
        for ($index = $providerStartIndex + 1; $index -lt $baseLines.Count; $index++) {
            if ($baseLines[$index].Trim() -match '^\[.*\]$') {
                $providerEndIndex = $index
                break
            }
        }
        $actualProviderLines = New-Object 'System.Collections.Generic.List[string]'
        for ($index = $providerStartIndex; $index -lt $providerEndIndex; $index++) {
            $actualProviderLines.Add($baseLines[$index].Trim())
        }
        while ($actualProviderLines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($actualProviderLines[$actualProviderLines.Count - 1])) {
            $actualProviderLines.RemoveAt($actualProviderLines.Count - 1)
        }
        $expectedProviderLines = @(Get-CodexTransportProviderDefinitionLines)
        $providerMatches = $actualProviderLines.Count -eq $expectedProviderLines.Count
        if ($providerMatches) {
            for ($index = 0; $index -lt $expectedProviderLines.Count; $index++) {
                if ($actualProviderLines[$index] -ne $expectedProviderLines[$index]) {
                    $providerMatches = $false
                    break
                }
            }
        }
        if (-not $providerMatches) {
            throw "Codex config.toml 已存在非托管的 model_providers.$TransportProviderId，且内容与补丁定义不一致；已停止修改以避免覆盖。"
        }

        $withoutOrphanProvider = New-Object 'System.Collections.Generic.List[string]'
        for ($index = 0; $index -lt $baseLines.Count; $index++) {
            if ($index -ge $providerStartIndex -and $index -lt $providerEndIndex) { continue }
            $withoutOrphanProvider.Add($baseLines[$index])
        }
        $baseLines = $withoutOrphanProvider
        while ($baseLines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($baseLines[$baseLines.Count - 1])) {
            $baseLines.RemoveAt($baseLines.Count - 1)
        }
    }

    $rootProviderIndices = New-Object 'System.Collections.Generic.List[int]'
    $insideTable = $false
    for ($index = 0; $index -lt $baseLines.Count; $index++) {
        $trimmed = $baseLines[$index].Trim()
        if ($trimmed -match '^\[.*\]$') {
            $insideTable = $true
            continue
        }
        if (-not $insideTable -and $trimmed -match '^model_provider\s*=') {
            $rootProviderIndices.Add($index)
        }
    }
    if ($rootProviderIndices.Count -gt 1) {
        throw 'Codex config.toml 中存在多个顶层 model_provider；已停止安装以避免改变配置优先级。'
    }
    if ($detachedSelector -and $rootProviderIndices.Count -eq 1) {
        $currentRootProviderLine = $baseLines[$rootProviderIndices[0]].Trim()
        $hotpatchSelectorPattern = '^model_provider\s*=\s*["'']{0}["'']\s*$' -f [regex]::Escape($TransportProviderId)
        $selectsHotpatch = $currentRootProviderLine -match $hotpatchSelectorPattern
        $matchesRecovery = -not $originalProviderWasAbsent -and
            $currentRootProviderLine -eq $originalProviderLine.Trim()
        if (-not $selectsHotpatch -and -not $matchesRecovery) {
            throw 'Codex 更新后检测到用户另行修改了 model_provider；为避免覆盖该选择，已停止自动修复。'
        }
    }
    if ($Action -eq 'Remove' -and $detachedSelector) {
        $removedDetachedLines = New-Object 'System.Collections.Generic.List[string]'
        if ($rootProviderIndices.Count -eq 1) {
            for ($index = 0; $index -lt $baseLines.Count; $index++) {
                if ($index -eq $rootProviderIndices[0]) {
                    if ($null -ne $originalProviderLine) { $removedDetachedLines.Add($originalProviderLine) }
                    continue
                }
                $removedDetachedLines.Add($baseLines[$index])
            }
        }
        else {
            if ($null -ne $originalProviderLine) {
                $removedDetachedLines.Add($originalProviderLine)
                if ($baseLines.Count -gt 0) { $removedDetachedLines.Add('') }
            }
            foreach ($line in $baseLines) { $removedDetachedLines.Add($line) }
        }
        while ($removedDetachedLines.Count -gt 0 -and
            [string]::IsNullOrWhiteSpace($removedDetachedLines[$removedDetachedLines.Count - 1])) {
            $removedDetachedLines.RemoveAt($removedDetachedLines.Count - 1)
        }
        if ($removedDetachedLines.Count -eq 0) { return '' }
        return ($removedDetachedLines -join [Environment]::NewLine) + [Environment]::NewLine
    }

    $originalLine = if ($hasManagedBlocks -or $detachedSelector) {
        $originalProviderLine
    }
    elseif ($rootProviderIndices.Count -eq 1) {
        $baseLines[$rootProviderIndices[0]]
    }
    else {
        $null
    }
    $originalEncoded = if ($null -eq $originalLine) {
        '__ABSENT__'
    }
    else {
        [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($originalLine))
    }
    $selectorBlock = @(
        $TransportSelectorStart
        "# original-model-provider-base64: $originalEncoded"
        if ($Action -eq 'Install') {
            "model_provider = `"$TransportProviderId`""
        }
        elseif ($null -ne $originalLine) {
            $originalLine
        }
        $TransportSelectorEnd
    )
    if ($rootProviderIndices.Count -eq 1) {
        $replacement = New-Object 'System.Collections.Generic.List[string]'
        for ($index = 0; $index -lt $baseLines.Count; $index++) {
            if ($index -eq $rootProviderIndices[0]) {
                foreach ($line in $selectorBlock) { $replacement.Add($line) }
            }
            else {
                $replacement.Add($baseLines[$index])
            }
        }
        $baseLines = $replacement
    }
    else {
        $replacement = New-Object 'System.Collections.Generic.List[string]'
        foreach ($line in $selectorBlock) { $replacement.Add($line) }
        if ($baseLines.Count -gt 0) { $replacement.Add('') }
        foreach ($line in $baseLines) { $replacement.Add($line) }
        $baseLines = $replacement
    }

    if ($baseLines.Count -gt 0) { $baseLines.Add('') }
    foreach ($line in @($TransportProviderStart) + @(Get-CodexTransportProviderDefinitionLines) + @($TransportProviderEnd)) {
        $baseLines.Add($line)
    }
    return ($baseLines -join [Environment]::NewLine) + [Environment]::NewLine
}

function Write-CodexConfigTextAtomically {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    Write-FileBytesAtomically -Path $CodexConfigPath -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($Text))
}

function Test-CodexConfigLoads {
    try {
        $cli = Get-CodexOperationalCli
        if ($null -eq $cli) { return $false }
        & $cli.Path features list *> $null
        return $LASTEXITCODE -eq 0
    }
    catch {
        return $false
    }
}

function Set-CodexOfficialTransportFallback {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExistingText,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RollbackText,
        [Parameter(Mandatory = $true)][bool]$RollbackExists
    )

    $recoveryState = Get-CodexTransportRecoveryState
    $fallbackText = Convert-CodexTransportConfigText -ExistingText $ExistingText -Action Fallback `
        -RecoveryState $recoveryState
    Write-CodexConfigTextAtomically -Text $fallbackText
    if (Test-CodexConfigLoads) {
        $originalRecord = Get-CodexTransportOriginalProviderRecord -Text $fallbackText
        Write-CodexTransportRecoveryState `
            -OriginalProviderLine $originalRecord.OriginalProviderLine `
            -OriginalProviderWasAbsent $originalRecord.OriginalProviderWasAbsent
        return [pscustomobject]@{ ProviderDefinitionPreserved = $true }
    }

    $removedText = Convert-CodexTransportConfigText -ExistingText $fallbackText -Action Remove `
        -RecoveryState $recoveryState
    Write-CodexConfigTextAtomically -Text $removedText
    if (Test-CodexConfigLoads) {
        return [pscustomobject]@{ ProviderDefinitionPreserved = $false }
    }

    if ($RollbackExists) { Write-CodexConfigTextAtomically -Text $RollbackText }
    elseif (Test-Path -LiteralPath $CodexConfigPath -PathType Leaf) { [IO.File]::Delete($CodexConfigPath) }
    throw '官方 provider 兼容兜底配置未通过解析；已原子恢复现场。'
}

function Install-CodexHttpTransport {
    if (Test-Path -LiteralPath $HttpTransportDisabledPath -PathType Leaf) {
        return [pscustomobject]@{
            Enabled = $false
            CompatibilityFallback = $false
            Reason = '用户已停用补丁传输接管；保留当前 provider 配置，不重写、不探测、不重启核心。'
        }
    }
    $originalExists = Test-Path -LiteralPath $CodexConfigPath -PathType Leaf
    $originalText = if ($originalExists) { [IO.File]::ReadAllText($CodexConfigPath) } else { '' }
    $alreadyManaged = $originalText.Contains($TransportSelectorStart) -and $originalText.Contains($TransportProviderStart)
    $desktopCompatibility = Get-CodexDesktopCompatibility
    if (-not $desktopCompatibility.Compatible) {
        $fallback = Set-CodexOfficialTransportFallback -ExistingText $originalText -RollbackText $originalText -RollbackExists $originalExists
        $fallbackReason = if ($fallback.ProviderDefinitionPreserved) {
            '旧任务依赖的 provider 定义已保留，但新任务仍使用官方 provider。'
        }
        else {
            '当前版本拒绝该 provider 定义，已退回纯官方配置；引用旧 provider 的任务可能仍需迁移。'
        }
        return [pscustomobject]@{
            Enabled = $false
            CompatibilityFallback = $true
            Reason = "$($desktopCompatibility.Reason) $fallbackReason"
        }
    }
    if ($alreadyManaged -and -not (Test-CodexConfigLoads)) {
        $fallback = Set-CodexOfficialTransportFallback -ExistingText $originalText -RollbackText $originalText -RollbackExists $originalExists
        return [pscustomobject]@{
            Enabled = $false
            CompatibilityFallback = $true
            Reason = if ($fallback.ProviderDefinitionPreserved) {
                '当前 Codex 不再接受热补丁 provider 作为默认值；已恢复原 model_provider，并保留旧任务兼容定义。'
            }
            else {
                '当前 Codex 不再接受热补丁 provider 定义；已退回纯官方配置。'
            }
        }
    }

    $recoveryState = Get-CodexTransportRecoveryState
    $newText = Convert-CodexTransportConfigText -ExistingText $originalText -Action Install `
        -RecoveryState $recoveryState
    Write-CodexConfigTextAtomically -Text $newText
    if (-not (Test-CodexConfigLoads)) {
        $fallback = Set-CodexOfficialTransportFallback -ExistingText $newText -RollbackText $originalText -RollbackExists $originalExists
        return [pscustomobject]@{
            Enabled = $false
            CompatibilityFallback = $true
            Reason = if ($fallback.ProviderDefinitionPreserved) {
                '当前 Codex 不接受 HTTPS-only provider 作为默认值；已保留官方内置 provider 和旧任务兼容定义。'
            }
            else {
                '当前 Codex 不接受 HTTPS-only provider 定义；已退回纯官方配置。'
            }
        }
    }
    $originalRecord = Get-CodexTransportOriginalProviderRecord -Text $newText
    Write-CodexTransportRecoveryState `
        -OriginalProviderLine $originalRecord.OriginalProviderLine `
        -OriginalProviderWasAbsent $originalRecord.OriginalProviderWasAbsent
    return [pscustomobject]@{
        Enabled = $true
        CompatibilityFallback = $false
        Reason = '当前 Codex 已接受 HTTPS-only provider。'
    }
}

function Remove-CodexHttpTransport {
    if (-not (Test-Path -LiteralPath $CodexConfigPath -PathType Leaf)) { return }
    $originalText = [IO.File]::ReadAllText($CodexConfigPath)
    $recoveryState = Get-CodexTransportRecoveryState
    $newText = Convert-CodexTransportConfigText -ExistingText $originalText -Action Remove `
        -RecoveryState $recoveryState
    Write-CodexConfigTextAtomically -Text $newText
    if (-not (Test-CodexConfigLoads)) {
        Write-CodexConfigTextAtomically -Text $originalText
        throw '移除 HTTPS-only provider 后 Codex 配置未通过解析，已恢复移除前状态。'
    }
    if (Test-Path -LiteralPath $TransportStatePath -PathType Leaf) {
        [IO.File]::Delete($TransportStatePath)
    }
}

function Get-CodexHttpTransportStatus {
    if (-not (Test-Path -LiteralPath $CodexConfigPath -PathType Leaf)) {
        return [pscustomobject]@{
            Managed = $false
            Selected = $false
            DetachedSelector = $false
            Repairable = $false
            RecoveryStatePresent = Test-Path -LiteralPath $TransportStatePath -PathType Leaf
            RecoveryStateHealthy = $false
            RecoveryStateError = $null
        }
    }
    $text = [IO.File]::ReadAllText($CodexConfigPath)
    $selectorStartCount = [regex]::Matches($text, "(?m)^\s*$([regex]::Escape($TransportSelectorStart))\s*$").Count
    $selectorEndCount = [regex]::Matches($text, "(?m)^\s*$([regex]::Escape($TransportSelectorEnd))\s*$").Count
    $providerStartCount = [regex]::Matches($text, "(?m)^\s*$([regex]::Escape($TransportProviderStart))\s*$").Count
    $providerEndCount = [regex]::Matches($text, "(?m)^\s*$([regex]::Escape($TransportProviderEnd))\s*$").Count
    $selectorComplete = $selectorStartCount -eq 1 -and $selectorEndCount -eq 1
    $providerComplete = $providerStartCount -eq 1 -and $providerEndCount -eq 1
    $recoverableDamagedSelector = -not $selectorComplete -and $providerComplete -and
        (($selectorStartCount -eq 1 -and $selectorEndCount -eq 0) -or
         ($selectorStartCount -eq 0 -and $selectorEndCount -eq 1))
    $detachedSelector = (($selectorStartCount -eq 0 -and $selectorEndCount -eq 0) -or
        $recoverableDamagedSelector) -and $providerComplete
    $recoveryStatePresent = Test-Path -LiteralPath $TransportStatePath -PathType Leaf
    $recoveryStateHealthy = $false
    $recoveryStateError = $null
    if ($recoveryStatePresent) {
        try {
            [void](Get-CodexTransportRecoveryState)
            $recoveryStateHealthy = $true
        }
        catch {
            $recoveryStateError = $_.Exception.Message
        }
    }
    return [pscustomobject]@{
        Managed = $selectorComplete -and $providerComplete
        Selected = $text -match "(?m)^\s*model_provider\s*=\s*`"$([regex]::Escape($TransportProviderId))`"\s*$"
        DetachedSelector = $detachedSelector
        Repairable = $detachedSelector -and $recoveryStateHealthy
        RecoveryStatePresent = $recoveryStatePresent
        RecoveryStateHealthy = $recoveryStateHealthy
        RecoveryStateError = $recoveryStateError
    }
}

function Test-CodexExplicitProxyEnabled {
    # Persistent user opt-out: runtime installation must not reset this preference.
    return -not (Test-Path -LiteralPath $ExplicitProxyDisabledPath)
}

function Resolve-CodexNetworkMode {
    if (-not (Test-CodexExplicitProxyEnabled)) {
        return [pscustomobject]@{
            NetworkMode = 'OfficialDirect'
            Reason = '用户已停用显式代理；仅使用 VPN 原生 HTTPS/SSE，不自动切回。'
            ProxyUri = $null
        }
    }
    try {
        $proxyUri = Get-WinInetProxyUri
    }
    catch {
        return [pscustomobject]@{
            NetworkMode = 'OfficialDirect'
            Reason = "WinINET 代理不可用：$($_.Exception.Message)"
            ProxyUri = $null
        }
    }

    if (-not (Test-ProxyListener -ProxyUri $proxyUri)) {
        return [pscustomobject]@{
            NetworkMode = 'OfficialDirect'
            Reason = "本地 VPN 代理监听不可连接：$($proxyUri.Host):$($proxyUri.Port)"
            ProxyUri = $null
        }
    }
    return [pscustomobject]@{
        NetworkMode = 'VpnProxy'
        Reason = 'WinINET 代理有效且本地代理监听可连接（未验证远端 WebSocket）。'
        ProxyUri = $proxyUri
    }
}

function Invoke-CodexDoctorCommand {
    param(
        [Parameter(Mandatory = $true)][string]$CliPath,
        [ValidateRange(1000, 60000)][int]$TimeoutMilliseconds = 30000
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $CliPath
    $startInfo.Arguments = 'doctor --json --summary'
    $startInfo.WorkingDirectory = [IO.Path]::GetTempPath()
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    try {
        $process.StartInfo = $startInfo
        [void]$process.Start()
        $process.StandardInput.Close()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            throw "Codex doctor 在 $TimeoutMilliseconds ms 后超时；诊断未完成，不代表线路断开。"
        }
        if (-not $stdoutTask.Wait(1000) -or -not $stderrTask.Wait(1000)) {
            throw 'Codex doctor 输出未及时关闭；诊断未完成。'
        }
        # Doctor may exit nonzero for unrelated failed checks; valid JSON is still useful.
        return $stdoutTask.GetAwaiter().GetResult() | ConvertFrom-Json -ErrorAction Stop
    }
    finally {
        # Only this diagnostic child is owned here; never stop a Desktop/core process.
        try { if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(1000) } } catch { }
        $process.Dispose()
    }
}

function Invoke-CodexDoctorProbe {
    Clear-CodexProxyEnvironment
    $preparedProxyUri = $null
    try {
        $proxyCandidate = Resolve-CodexNetworkMode
        if ($proxyCandidate.NetworkMode -eq 'VpnProxy' -and $null -ne $proxyCandidate.ProxyUri) {
            $preparedStatus = Get-CodexProxyEnvStatus -ExpectedProxyUri $proxyCandidate.ProxyUri
            if ($preparedStatus.Managed -and $preparedStatus.Matches) {
                $preparedProxyUri = $proxyCandidate.ProxyUri
            }
        }
    }
    catch { }

    $operationalCli = $null
    try {
        $operationalCli = Get-CodexOperationalCli
        if ($null -eq $operationalCli) { throw '未找到可运行的官方 Codex CLI；网络诊断不可用。' }
        $doctor = Invoke-CodexDoctorCommand -CliPath $operationalCli.Path
        $providerCheck = $doctor.checks.'network.provider_reachability'
        $websocketCheck = $doctor.checks.'network.websocket_reachability'
        if (-not $providerCheck -or -not $websocketCheck) {
            throw 'Codex doctor 未返回完整的网络检查。'
        }
        $providerStatus = [string](Get-OptionalObjectProperty -InputObject $providerCheck -Name 'status')
        $websocketStatus = [string](Get-OptionalObjectProperty -InputObject $websocketCheck -Name 'status')
        $websocketDetails = Get-OptionalObjectProperty -InputObject $websocketCheck -Name 'details'
        $responsesProbe = Invoke-CodexResponsesEndpointProbe -ProxyUri $preparedProxyUri
        $providerHealthy = $responsesProbe.Healthy
        return [pscustomobject]@{
            Available = $true
            DoctorAvailable = $true
            DiagnosticCliAvailable = $true
            Healthy = $providerHealthy -and $websocketStatus -eq 'ok'
            TransportHealthy = $providerHealthy
            ProviderHealthy = $providerHealthy
            WebSocketHealthy = $websocketStatus -eq 'ok'
            ProviderStatus = if ($providerHealthy) { 'ok' } else { $providerStatus }
            ProviderSummary = if ($responsesProbe.Healthy) {
                "真实 Responses 路径已连通（HTTP $($responsesProbe.StatusCode)；doctor 根地址=$providerStatus）。"
            }
            else {
                Get-OptionalObjectProperty -InputObject $providerCheck -Name 'summary'
            }
            ProviderDurationMs = $responsesProbe.DurationMs
            ResponsesEndpointHealthy = $responsesProbe.Healthy
            ResponsesEndpointStatusCode = $responsesProbe.StatusCode
            ResponsesEndpointError = $responsesProbe.Error
            WebSocketStatus = $websocketStatus
            WebSocketSummary = Get-OptionalObjectProperty -InputObject $websocketCheck -Name 'summary'
            WebSocketHandshake = Get-OptionalObjectProperty -InputObject $websocketDetails -Name 'handshake result'
            WebSocketDurationMs = Get-OptionalObjectProperty -InputObject $websocketCheck -Name 'durationMs'
            DoctorOverallStatus = Get-OptionalObjectProperty -InputObject $doctor -Name 'overallStatus'
            Error = $null
        }
    }
    catch {
        $doctorError = $_.Exception.Message
        $responsesProbe = Invoke-CodexResponsesEndpointProbe -ProxyUri $preparedProxyUri
        return [pscustomobject]@{
            Available = $responsesProbe.Healthy
            DoctorAvailable = $false
            DiagnosticCliAvailable = $null -ne $operationalCli
            Healthy = $responsesProbe.Healthy
            TransportHealthy = $responsesProbe.Healthy
            ProviderHealthy = $responsesProbe.Healthy
            WebSocketHealthy = $null
            ProviderStatus = if ($responsesProbe.Healthy) { 'ok' } else { $null }
            ProviderSummary = if ($responsesProbe.Healthy) {
                "Codex doctor 不可用，但真实 Responses 路径已连通（HTTP $($responsesProbe.StatusCode)）。"
            }
            else {
                $null
            }
            ProviderDurationMs = $responsesProbe.DurationMs
            ResponsesEndpointHealthy = $responsesProbe.Healthy
            ResponsesEndpointStatusCode = $responsesProbe.StatusCode
            ResponsesEndpointError = $responsesProbe.Error
            WebSocketStatus = $null
            WebSocketSummary = $null
            WebSocketHandshake = $null
            WebSocketDurationMs = $null
            DoctorOverallStatus = $null
            Error = $doctorError
        }
    }
}

function Invoke-CodexDoctorProbeSeries {
    param(
        [int]$ProbeCount = $RequiredHealthyVpnProbes,
        [int]$ProbeIntervalMilliseconds = $VpnProbeIntervalMilliseconds,
        [switch]$RequireWebSocket
    )

    $probes = New-Object 'System.Collections.Generic.List[object]'
    for ($index = 1; $index -le $ProbeCount; $index++) {
        $probe = Invoke-CodexDoctorProbe
        $probes.Add($probe)
        $transportHealthy = $probe.Available -and $probe.ProviderHealthy -eq $true -and
            (-not $RequireWebSocket -or $probe.WebSocketHealthy -eq $true)
        if (-not $transportHealthy) { break }
        if ($index -lt $ProbeCount -and $ProbeIntervalMilliseconds -gt 0) {
            Start-Sleep -Milliseconds $ProbeIntervalMilliseconds
        }
    }

    $completed = $probes.Count -eq $ProbeCount
    $unavailable = $probes.Count -gt 0 -and -not $probes[$probes.Count - 1].Available
    $unstable = @($probes | Where-Object {
        -not $_.Available -or $_.ProviderHealthy -ne $true -or ($RequireWebSocket -and $_.WebSocketHealthy -ne $true)
    }).Count
    $stable = $completed -and -not $unavailable -and $unstable -eq 0
    return [pscustomobject]@{
        Stable = $stable
        Unavailable = $unavailable
        RequireWebSocket = [bool]$RequireWebSocket
        Probes = @($probes.ToArray())
        LastProbe = if ($probes.Count -gt 0) { $probes[$probes.Count - 1] } else { $null }
    }
}

function Invoke-CodexNativeFallbackProbeSeries {
    param(
        [int]$ProbeCount = $RequiredHealthyNativeProbes,
        [int]$ProbeIntervalMilliseconds = $VpnProbeIntervalMilliseconds
    )

    $snapshot = Get-FileSnapshot -Path $CodexEnvPath
    $existingText = if ($snapshot.Exists) {
        [Text.UTF8Encoding]::new($false).GetString($snapshot.Bytes)
    }
    else {
        ''
    }
    $nativeText = Convert-CodexProxyEnvText -ExistingText $existingText `
        -NetworkMode OfficialDirect
    try {
        Write-CodexEnvTextAtomically -Text $nativeText
        return Invoke-CodexDoctorProbeSeries -ProbeCount $ProbeCount `
            -ProbeIntervalMilliseconds $ProbeIntervalMilliseconds
    }
    finally {
        Restore-FileSnapshot -Snapshot $snapshot
    }
}

function Invoke-CodexNativeAuthenticatedFallbackProbe {
    $snapshot = Get-FileSnapshot -Path $CodexEnvPath
    $existingText = if ($snapshot.Exists) {
        [Text.UTF8Encoding]::new($false).GetString($snapshot.Bytes)
    }
    else {
        ''
    }
    $nativeText = Convert-CodexProxyEnvText -ExistingText $existingText `
        -NetworkMode OfficialDirect
    try {
        Write-CodexEnvTextAtomically -Text $nativeText
        Clear-CodexProxyEnvironment
        return Invoke-CodexAuthenticatedResponsesProbe `
            -TimeoutMilliseconds $NativeAuthenticatedProbeTimeoutMilliseconds
    }
    finally {
        Restore-FileSnapshot -Snapshot $snapshot
    }
}

function Invoke-CodexExplicitAuthenticatedProbe {
    param([Parameter(Mandatory = $true)][Uri]$ProxyUri)

    return Invoke-CodexAuthenticatedResponsesProbe `
        -TimeoutMilliseconds $NativeAuthenticatedProbeTimeoutMilliseconds `
        -ProxyUri $ProxyUri
}

function Test-CodexProbeNeedsAuthenticatedVerification {
    param([Parameter(Mandatory = $true)]$ProbeSeries)

    if ($ProbeSeries.Stable -or $null -eq $ProbeSeries.LastProbe) { return $false }
    $lastProbe = $ProbeSeries.LastProbe
    $responsesHealthy = Get-OptionalObjectProperty -InputObject $lastProbe -Name 'ResponsesEndpointHealthy'
    $doctorUnavailable = (Get-OptionalObjectProperty -InputObject $lastProbe -Name 'DoctorAvailable') -eq $false -and
        (Get-OptionalObjectProperty -InputObject $lastProbe -Name 'DiagnosticCliAvailable') -eq $true
    return $responsesHealthy -eq $false -and ($doctorUnavailable -or ($lastProbe.Available -and
        [string](Get-OptionalObjectProperty -InputObject $lastProbe -Name 'ProviderStatus') -eq 'ok'))
}

function Test-CodexProbeHasFailureEvidence {
    param([Parameter(Mandatory = $true)]$ProbeSeries, [AllowNull()]$AuthenticatedProbe)

    # A failed tool invocation is not evidence for a network circuit transition.
    return ($null -ne $ProbeSeries.LastProbe -and $ProbeSeries.LastProbe.Available) -or
        (Get-OptionalObjectProperty -InputObject $AuthenticatedProbe -Name 'TransportErrors') -gt 0 -or
        (Get-OptionalObjectProperty -InputObject $AuthenticatedProbe -Name 'ReconnectSignals') -gt 0
}

function Get-CodexNativeAuthenticatedProbeVerification {
    $nowUtc = [DateTime]::UtcNow
    if ($null -ne $script:NativeAuthenticatedFallbackCache -and
        $script:NativeAuthenticatedFallbackCache.ExpiresUtc -gt $nowUtc) {
        return [pscustomobject]@{
            Mode = 'AuthenticatedCache'
            Probe = $script:NativeAuthenticatedFallbackCache.Probe
        }
    }

    $probe = Invoke-CodexNativeAuthenticatedFallbackProbe
    $script:NativeAuthenticatedFallbackCache = [pscustomobject]@{
        ExpiresUtc = $nowUtc.Add($NativeAuthenticatedProbeCacheTtl)
        Probe = $probe
    }
    return [pscustomobject]@{
        Mode = 'Authenticated'
        Probe = $probe
    }
}

function Get-CodexExplicitAuthenticatedProbeVerification {
    param([Parameter(Mandatory = $true)][Uri]$ProxyUri)

    $nowUtc = [DateTime]::UtcNow
    $proxyValue = $ProxyUri.AbsoluteUri.TrimEnd('/')
    if ($null -ne $script:ExplicitAuthenticatedProbeCache -and
        $script:ExplicitAuthenticatedProbeCache.ExpiresUtc -gt $nowUtc -and
        $script:ExplicitAuthenticatedProbeCache.ProxyUri -eq $proxyValue) {
        return [pscustomobject]@{
            Mode = 'AuthenticatedCache'
            Probe = $script:ExplicitAuthenticatedProbeCache.Probe
        }
    }

    $probe = Invoke-CodexExplicitAuthenticatedProbe -ProxyUri $ProxyUri
    $script:ExplicitAuthenticatedProbeCache = [pscustomobject]@{
        ExpiresUtc = $nowUtc.Add($NativeAuthenticatedProbeCacheTtl)
        ProxyUri = $proxyValue
        Probe = $probe
    }
    return [pscustomobject]@{
        Mode = 'Authenticated'
        Probe = $probe
    }
}

function Invoke-CodexNativeFallbackVerification {
    param(
        [int]$ProbeCount = $RequiredHealthyNativeProbes,
        [int]$ProbeIntervalMilliseconds = $VpnProbeIntervalMilliseconds
    )

    $passiveSeries = Invoke-CodexNativeFallbackProbeSeries -ProbeCount $ProbeCount `
        -ProbeIntervalMilliseconds $ProbeIntervalMilliseconds
    $verificationMode = 'Passive'
    $authenticatedProbe = $null
    $stable = $passiveSeries.Stable
    if (-not $stable -and (Test-CodexProbeNeedsAuthenticatedVerification -ProbeSeries $passiveSeries)) {
        $authenticatedVerification = Get-CodexNativeAuthenticatedProbeVerification
        $authenticatedProbe = $authenticatedVerification.Probe
        $verificationMode = $authenticatedVerification.Mode
        $stable = (Get-OptionalObjectProperty -InputObject $authenticatedProbe -Name 'Healthy') -eq $true
    }

    return [pscustomobject]@{
        Stable = $stable
        Unavailable = $passiveSeries.Unavailable
        RequireWebSocket = $passiveSeries.RequireWebSocket
        Probes = $passiveSeries.Probes
        LastProbe = $passiveSeries.LastProbe
        VerificationMode = $verificationMode
        AuthenticatedProbe = $authenticatedProbe
    }
}

function Get-CodexAuthenticatedProbeFailureSummary {
    param([AllowNull()]$Probe)

    if ($null -eq $Probe) { return '未生成登录态探测结果' }
    $errorText = [string](Get-OptionalObjectProperty -InputObject $Probe -Name 'Error')
    if (-not [string]::IsNullOrWhiteSpace($errorText)) {
        $detail = ($errorText -replace '\s+', ' ').Trim()
        if ($detail.Length -gt 240) { $detail = $detail.Substring(0, 240) }
        return $detail
    }

    $completed = Get-OptionalObjectProperty -InputObject $Probe -Name 'Completed'
    $exitCode = Get-OptionalObjectProperty -InputObject $Probe -Name 'ExitCode'
    $reconnectSignals = Get-OptionalObjectProperty -InputObject $Probe -Name 'ReconnectSignals'
    $transportErrors = Get-OptionalObjectProperty -InputObject $Probe -Name 'TransportErrors'
    $durationMs = Get-OptionalObjectProperty -InputObject $Probe -Name 'DurationMs'
    return "completed=$completed, exit=$exitCode, reconnect=$reconnectSignals, transport=$transportErrors, duration_ms=$durationMs"
}

function Get-CodexNativeFallbackVerificationReason {
    param([Parameter(Mandatory = $true)]$Verification)

    if ($null -eq $Verification.AuthenticatedProbe) {
        return Get-CodexDoctorProbeReason -Probe $Verification.LastProbe
    }
    $probe = $Verification.AuthenticatedProbe
    if ((Get-OptionalObjectProperty -InputObject $probe -Name 'Healthy') -eq $true) {
        $durationMs = Get-OptionalObjectProperty -InputObject $probe -Name 'DurationMs'
        return "真实登录态 HTTPS/SSE 检查通过（$durationMs ms，模式=$($Verification.VerificationMode)）。"
    }
    $detail = Get-CodexAuthenticatedProbeFailureSummary -Probe $probe
    return "真实登录态 HTTPS/SSE 检查失败（模式=$($Verification.VerificationMode)：$detail）。"
}

function Get-VpnHealthState {
    return Get-CodexNetworkCircuitState -Path $NetworkHealthPath
}

function Register-VpnHealthFailure {
    param(
        [Parameter(Mandatory = $true)][string]$Reason,
        [ValidateSet('Probe', 'RuntimeStream')][string]$FailureKind = 'Probe',
        [switch]$Immediate
    )

    $failureThreshold = if ($Immediate) { 1 } else { $VpnFailureThreshold }
    $openCooldown = if ($FailureKind -eq 'RuntimeStream') { $RuntimeFailureBaseCooldown } else { $VpnOpenCooldown }
    $maximumCooldown = if ($FailureKind -eq 'RuntimeStream') { $RuntimeFailureMaxCooldown } else { $VpnOpenCooldown }

    return Update-CodexNetworkCircuitState `
        -Path $NetworkHealthPath `
        -Outcome Failure `
        -Reason $Reason `
        -FailureKind $FailureKind `
        -FailureThreshold $failureThreshold `
        -FailureWindow $VpnFailureWindow `
        -OpenCooldown $openCooldown `
        -RuntimeFailureMaxCooldown $maximumCooldown
}

function Register-VpnHealthSuccess {
    return Update-CodexNetworkCircuitState `
        -Path $NetworkHealthPath `
        -Outcome Success `
        -PreserveStableSuccessBoundary `
        -FailureThreshold $VpnFailureThreshold `
        -FailureWindow $VpnFailureWindow `
        -OpenCooldown $VpnOpenCooldown
}

function Get-CodexDoctorProbeReason {
    param([Parameter(Mandatory = $true)]$Probe)

    if (-not $Probe.Available) { return "远端检查不可用：$($Probe.Error)" }
    if ($Probe.ProviderHealthy) {
        return "Codex HTTPS/SSE 远端检查通过（WebSocket 诊断=$($Probe.WebSocketStatus)）。"
    }
    return "HTTPS/SSE 远端检查失败（HTTP=$($Probe.ProviderStatus), WebSocket 诊断=$($Probe.WebSocketStatus)）。"
}

function Get-ProbeSeriesMedianProviderDuration {
    param([Parameter(Mandatory = $true)]$ProbeSeries)

    $durations = @($ProbeSeries.Probes | ForEach-Object {
        if ($null -ne $_.ProviderDurationMs) { [double]$_.ProviderDurationMs }
    } | Sort-Object)
    if ($durations.Count -eq 0) { return [double]::PositiveInfinity }
    $middle = [Math]::Floor($durations.Count / 2)
    if ($durations.Count % 2 -eq 1) { return $durations[$middle] }
    return ($durations[$middle - 1] + $durations[$middle]) / 2
}

function Sync-CodexProxyEnv {
    param(
        [switch]$VerifyRemote,
        [switch]$ForceNative,
        [switch]$AllowEarlyRecovery
    )

    if ($AllowEarlyRecovery -and (-not $VerifyRemote -or $ForceNative)) {
        throw 'AllowEarlyRecovery 只能用于经过远端验证的显式路径恢复。'
    }

    $nativeOnly = -not (Test-CodexExplicitProxyEnabled)
    $explicitProxyCandidate = Resolve-CodexNetworkMode
    $healthState = Get-VpnHealthState
    if ($healthState.IsCorrupt) {
        $healthState = Register-VpnHealthFailure -Reason $healthState.LastFailureReason
    }
    $existingText = if (Test-Path -LiteralPath $CodexEnvPath -PathType Leaf) {
        [IO.File]::ReadAllText($CodexEnvPath)
    }
    else {
        ''
    }
    $nativeText = Convert-CodexProxyEnvText -ExistingText $existingText -NetworkMode OfficialDirect
    $explicitText = $null
    if ($explicitProxyCandidate.NetworkMode -eq 'VpnProxy' -and $explicitProxyCandidate.ProxyUri) {
        $proxyValue = $explicitProxyCandidate.ProxyUri.AbsoluteUri.TrimEnd('/')
        $explicitText = Convert-CodexProxyEnvText -ExistingText $nativeText -NetworkMode VpnProxy -ProxyValue $proxyValue
    }
    $explicitSuppressed = ($healthState.SuppressExplicit -and -not $AllowEarlyRecovery) -or $ForceNative -or $nativeOnly
    $recoveryProbe = ($healthState.HalfOpenEligible -or $AllowEarlyRecovery) -and -not $ForceNative

    if (-not $VerifyRemote) {
        # An open or half-open circuit may only recover through the stronger verified probe series.
        $useExplicit = $null -ne $explicitText -and $healthState.CircuitState -eq 'Closed' -and -not $ForceNative -and -not $nativeOnly
        Write-CodexEnvTextAtomically -Text $(if ($useExplicit) { $explicitText } else { $nativeText })
        return [pscustomobject]@{
            NetworkMode = if ($useExplicit) { 'VpnExplicitHttps' } else { 'VpnNativeHttps' }
            Reason = if ($useExplicit) {
                '已同步当前显式 VPN 代理；HTTPS-only 传输避免 WebSocket 长流重连。'
            }
            elseif ($nativeOnly) {
                '用户已停用显式代理；仅使用 VPN 原生 HTTPS/SSE，不自动切回。'
            }
            elseif ($ForceNative) {
                'Codex 兼容门禁已选择官方 provider；当前强制准备 VPN 原生网络环境。'
            }
            elseif ($healthState.CircuitState -eq 'Open') {
                '显式 VPN 熔断状态需要远端验证后才能恢复；当前准备 VPN 原生 HTTPS 路径。'
            }
            else {
                '未发现显式代理候选；使用 VPN 原生 HTTPS 路径。'
            }
            ProxyUri = if ($useExplicit) { $explicitProxyCandidate.ProxyUri } else { $null }
            NetworkProbe = $null
            RouteHealthy = $null
            ExplicitProxyMedianMs = $null
            NativeMedianMs = $null
            CircuitState = $healthState.CircuitState
            CircuitFailures = $healthState.ConsecutiveFailures
            CircuitRetryAfterUtc = $healthState.RetryAfterUtc
            CircuitHalfOpen = $healthState.HalfOpenEligible
        }
    }

    $explicitSeries = $null
    $explicitMedian = [double]::PositiveInfinity
    $explicitFailure = $null
    $explicitVerificationMode = 'Passive'
    $explicitAuthenticatedProbe = $null
    if ($null -ne $explicitText -and -not $explicitSuppressed) {
        Write-CodexEnvTextAtomically -Text $explicitText
        $explicitProbeCount = if ($recoveryProbe) { $RequiredRecoveryVpnProbes } else { $RequiredHealthyVpnProbes }
        $explicitSeries = Invoke-CodexDoctorProbeSeries -ProbeCount $explicitProbeCount -ProbeIntervalMilliseconds $VpnProbeIntervalMilliseconds
        $explicitMedian = Get-ProbeSeriesMedianProviderDuration -ProbeSeries $explicitSeries
        if (-not $explicitSeries.Stable -and
            (Test-CodexProbeNeedsAuthenticatedVerification -ProbeSeries $explicitSeries)) {
            $authenticatedVerification = Get-CodexExplicitAuthenticatedProbeVerification `
                -ProxyUri $explicitProxyCandidate.ProxyUri
            $explicitVerificationMode = $authenticatedVerification.Mode
            $explicitAuthenticatedProbe = $authenticatedVerification.Probe
        }
        $explicitAuthenticatedHealthy = $null -ne $explicitAuthenticatedProbe -and
            (Get-OptionalObjectProperty -InputObject $explicitAuthenticatedProbe -Name 'Healthy') -eq $true
        $explicitRouteHealthy = $explicitSeries.Stable -or
            $explicitAuthenticatedHealthy
        if ($explicitRouteHealthy) {
            $healthState = Register-VpnHealthSuccess
            $explicitReason = if ($explicitSeries.Stable) {
                "显式 VPN HTTPS/SSE 路径连续 $explicitProbeCount 次通过，HTTP 中位耗时 $([Math]::Round($explicitMedian)) ms"
            }
            else {
                $durationMs = Get-OptionalObjectProperty -InputObject $explicitAuthenticatedProbe -Name 'DurationMs'
                "显式 VPN 无凭据检查与当前运行环境矛盾，但真实登录态 HTTPS/SSE 检查通过（$durationMs ms，模式=$explicitVerificationMode）"
            }
            return [pscustomobject]@{
                NetworkMode = 'VpnExplicitHttps'
                Reason = "$explicitReason；运行期监测器会在连续故障时为新进程自动准备 VPN 原生路径。"
                ProxyUri = $explicitProxyCandidate.ProxyUri
                NetworkProbe = $explicitSeries.LastProbe
                RouteHealthy = $true
                ExplicitProxyMedianMs = if ($explicitVerificationMode -ne 'Passive' -and $null -ne $explicitAuthenticatedProbe) {
                    Get-OptionalObjectProperty -InputObject $explicitAuthenticatedProbe -Name 'DurationMs'
                }
                else {
                    $explicitMedian
                }
                ExplicitVerificationMode = $explicitVerificationMode
                ExplicitAuthenticatedProbe = $explicitAuthenticatedProbe
                NativeMedianMs = $null
                CircuitState = $healthState.CircuitState
                CircuitFailures = $healthState.ConsecutiveFailures
                CircuitRetryAfterUtc = $healthState.RetryAfterUtc
                CircuitHalfOpen = $healthState.HalfOpenEligible
            }
        }
        $explicitFailure = if ($null -ne $explicitAuthenticatedProbe) {
            "显式 VPN 登录态 HTTPS/SSE 检查失败：$(Get-CodexAuthenticatedProbeFailureSummary -Probe $explicitAuthenticatedProbe)"
        }
        else {
            "显式 VPN HTTPS/SSE 检查失败：$(Get-CodexDoctorProbeReason -Probe $explicitSeries.LastProbe)"
        }
        if ((Test-CodexProbeHasFailureEvidence -ProbeSeries $explicitSeries -AuthenticatedProbe $explicitAuthenticatedProbe) -and
            -not ($AllowEarlyRecovery -and $healthState.CircuitState -eq 'Open')) {
            $healthState = Register-VpnHealthFailure -Reason $explicitFailure
        }
    }
    elseif ($nativeOnly) {
        $explicitFailure = '用户已停用显式代理，本次跳过且不自动恢复'
    }
    elseif ($ForceNative) {
        $explicitFailure = 'Codex 兼容门禁已选择官方 provider，已跳过显式代理'
    }
    elseif ($explicitSuppressed) {
        $explicitFailure = "显式 VPN 熔断至 $($healthState.RetryAfterUtc.ToString('o'))：$($healthState.LastFailureReason)"
    }
    else {
        $explicitFailure = $explicitProxyCandidate.Reason
    }

    Write-CodexEnvTextAtomically -Text $nativeText
    $nativeSeries = Invoke-CodexDoctorProbeSeries -ProbeCount $RequiredHealthyNativeProbes -ProbeIntervalMilliseconds $VpnProbeIntervalMilliseconds
    $nativeMedian = Get-ProbeSeriesMedianProviderDuration -ProbeSeries $nativeSeries
    $nativeVerificationMode = 'Passive'
    $nativeAuthenticatedProbe = $null
    if (-not $nativeSeries.Stable -and (Test-CodexProbeNeedsAuthenticatedVerification -ProbeSeries $nativeSeries)) {
        $authenticatedVerification = Get-CodexNativeAuthenticatedProbeVerification
        $nativeVerificationMode = $authenticatedVerification.Mode
        $nativeAuthenticatedProbe = $authenticatedVerification.Probe
    }
    $nativeAuthenticatedHealthy = $null -ne $nativeAuthenticatedProbe -and
        (Get-OptionalObjectProperty -InputObject $nativeAuthenticatedProbe -Name 'Healthy') -eq $true
    $nativeRouteHealthy = $nativeSeries.Stable -or
        $nativeAuthenticatedHealthy
    if ($nativeRouteHealthy) {
        $nativeReason = if ($nativeSeries.Stable) {
            "VPN 原生 HTTPS/SSE 路径连续 $RequiredHealthyNativeProbes 次通过，已为后续新进程准备。"
        }
        else {
            $durationMs = Get-OptionalObjectProperty -InputObject $nativeAuthenticatedProbe -Name 'DurationMs'
            "VPN 原生被动诊断未通过，但真实登录态 HTTPS/SSE 检查通过（$durationMs ms，模式=$nativeVerificationMode），已为后续新进程准备。"
        }
        return [pscustomobject]@{
            NetworkMode = 'VpnNativeHttps'
            Reason = "$explicitFailure；$nativeReason"
            ProxyUri = $null
            NetworkProbe = $nativeSeries.LastProbe
            RouteHealthy = $true
            ExplicitProxyMedianMs = if ([double]::IsPositiveInfinity($explicitMedian)) { $null } else { $explicitMedian }
            NativeMedianMs = if ($nativeVerificationMode -ne 'Passive' -and $null -ne $nativeAuthenticatedProbe) {
                Get-OptionalObjectProperty -InputObject $nativeAuthenticatedProbe -Name 'DurationMs'
            }
            else {
                $nativeMedian
            }
            NativeVerificationMode = $nativeVerificationMode
            NativeAuthenticatedProbe = $nativeAuthenticatedProbe
            CircuitState = $healthState.CircuitState
            CircuitFailures = $healthState.ConsecutiveFailures
            CircuitRetryAfterUtc = $healthState.RetryAfterUtc
            CircuitHalfOpen = $healthState.HalfOpenEligible
        }
    }

    $nativeFailure = if ($null -ne $nativeAuthenticatedProbe) {
        "登录态检查未通过：$(Get-CodexAuthenticatedProbeFailureSummary -Probe $nativeAuthenticatedProbe)"
    }
    else { Get-CodexDoctorProbeReason -Probe $nativeSeries.LastProbe }
    $nativeFailureConfirmed = Test-CodexProbeHasFailureEvidence -ProbeSeries $nativeSeries -AuthenticatedProbe $nativeAuthenticatedProbe
    return [pscustomobject]@{
        NetworkMode = 'VpnNativeHttps'
        Reason = "本次未验证到可用的 VPN HTTPS/SSE 路径；已保留无强制代理键的 VPN 原生环境。显式路径：$explicitFailure；原生路径：$nativeFailure"
        ProxyUri = $null
        NetworkProbe = $nativeSeries.LastProbe
        RouteHealthy = if ($nativeFailureConfirmed) { $false } else { $null }
        ExplicitProxyMedianMs = if ([double]::IsPositiveInfinity($explicitMedian)) { $null } else { $explicitMedian }
        NativeMedianMs = $nativeMedian
        NativeVerificationMode = $nativeVerificationMode
        NativeAuthenticatedProbe = $nativeAuthenticatedProbe
        CircuitState = $healthState.CircuitState
        CircuitFailures = $healthState.ConsecutiveFailures
        CircuitRetryAfterUtc = $healthState.RetryAfterUtc
        CircuitHalfOpen = $healthState.HalfOpenEligible
    }
}

function Remove-ManagedCodexProxyEnv {
    if (-not (Test-Path -LiteralPath $CodexEnvPath -PathType Leaf)) { return }
    $newText = Convert-CodexProxyEnvText -ExistingText ([IO.File]::ReadAllText($CodexEnvPath)) -NetworkMode OfficialDirect
    Write-CodexEnvTextAtomically -Text $newText
}

function Get-CodexProxyEnvStatus {
    param([Uri]$ExpectedProxyUri)

    if (-not (Test-Path -LiteralPath $CodexEnvPath -PathType Leaf)) {
        return [pscustomobject]@{
            Exists = $false
            Managed = $false
            Matches = $false
            LoopbackBypass = $false
        }
    }
    $lines = @([IO.File]::ReadAllLines($CodexEnvPath))
    $managed = ($lines -contains $EnvBlockStart) -and ($lines -contains $EnvBlockEnd)
    $expected = if ($ExpectedProxyUri) { $ExpectedProxyUri.AbsoluteUri.TrimEnd('/') } else { $null }
    $values = @{}
    foreach ($line in $lines) {
        if ($line -match '^\s*(?<key>(?i:HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY))\s*=\s*(?<value>.*)\s*$') {
            $values[$Matches.key.ToUpperInvariant()] = $Matches.value.Trim()
        }
    }
    $loopbackBypass = $values['NO_PROXY'] -eq $NoProxyValue
    $matches = [bool]($expected -and $loopbackBypass -and
        $values['HTTP_PROXY'] -eq $expected -and
        $values['HTTPS_PROXY'] -eq $expected -and
        $values['ALL_PROXY'] -eq $expected)
    return [pscustomobject]@{
        Exists = $true
        Managed = $managed
        Matches = $matches
        LoopbackBypass = $loopbackBypass
    }
}

function Get-CodexDesktopPackage {
    $packages = @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop | Sort-Object { [Version]$_.Version } -Descending)
    if ($packages.Count -eq 0) { throw '未找到当前用户的 OpenAI.Codex Appx 包。' }
    return $packages[0]
}

function Get-CodexDesktopPackageVersion {
    try {
        return [Version](Get-CodexDesktopPackage).Version
    }
    catch {
        return $null
    }
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

function Get-CodexDesktopOfficialCliPath {
    $package = Get-CodexDesktopPackage
    $packagedPath = Get-CodexDesktopBundledCliPath -Package $package
    if ([string]::IsNullOrWhiteSpace($packagedPath) -or
        -not (Test-Path -LiteralPath $DesktopOfficialCliRoot -PathType Container)) {
        return $null
    }

    $manifest = Get-CodexDesktopRuntimeManifest -SourceDirectory (Split-Path -Parent $packagedPath)
    $directory = Join-Path $DesktopOfficialCliRoot $manifest.Hash
    foreach ($file in $manifest.Files) {
        if (-not (Test-CodexDesktopRuntimeFile -Path (Join-Path $directory $file.Name) -Descriptor $file)) { return $null }
    }
    return Join-Path $directory 'codex.exe'
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

function ConvertTo-CodexCommandLineArgument {
    param([AllowEmptyString()][string]$Value)

    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes += 1
            continue
        }
        if ($character -eq '"') {
            if ($backslashes -gt 0) {
                [void]$builder.Append((('\' * ($backslashes * 2 + 1)) -join ''))
            }
            else {
                [void]$builder.Append('\')
            }
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append((('\' * $backslashes) -join ''))
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) {
        [void]$builder.Append((('\' * ($backslashes * 2)) -join ''))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Get-CodexAuthenticatedProbeModelCatalogOverride {
    if (-not (Test-Path -LiteralPath $CodexModelCatalogCachePath -PathType Leaf)) {
        return $null
    }

    try {
        $catalog = [IO.File]::ReadAllText($CodexModelCatalogCachePath) | ConvertFrom-Json
        $probeModel = @($catalog.models | Where-Object {
            $_.slug -eq $AuthenticatedProbeModel
        } | Select-Object -First 1)
        if ($probeModel.Count -eq 0) { return $null }

        $escapedPath = $CodexModelCatalogCachePath.Replace('\', '\\').Replace('"', '\"')
        return "model_catalog_json=`"$escapedPath`""
    }
    catch {
        return $null
    }
}

function Get-CodexResponsesTransportDiagnostics {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    $responseEvidenceLines = @($Text -split "`r?`n" | Where-Object {
        $_ -match '(?i)/backend-api/codex/responses' -or
        $_ -match '(?i)stream disconnected before completion' -or
        $_ -match '(?i)error decoding response body' -or
        $_ -match '(?i)websocket closed by server before response\.completed' -or
        ($_ -match '"type"\s*:\s*"error"' -and
            $_ -match '(?i)network error|request timed out|error sending request')
    })
    $responseEvidence = $responseEvidenceLines -join "`n"

    return [pscustomobject]@{
        ReconnectSignals = ([regex]::Matches(
            $responseEvidence,
            '(?i)reconnect|stream disconnected|falling back'
        )).Count
        TransportErrors = ([regex]::Matches(
            $responseEvidence,
            '(?i)websocket closed|error sending request|request timed out|error decoding response body|network error|stream disconnected'
        )).Count
        Evidence = $responseEvidence
    }
}

function Invoke-CodexAuthenticatedResponsesProbe {
    param(
        [ValidateRange(5000, 120000)]
        [int]$TimeoutMilliseconds = $NativeAuthenticatedProbeTimeoutMilliseconds,
        [AllowNull()][Uri]$ProxyUri = $null
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $process = $null
    try {
        $operationalCli = Get-CodexOperationalCli
        if ($null -eq $operationalCli) {
            throw '未找到当前 Codex Desktop 对应的官方稳定 CLI 或可信 OpenAI CLI 兜底。'
        }
        $officialCliPath = $operationalCli.Path
        $probeProviderId = if ($null -ne $ProxyUri) {
            'codex-hotpatch-explicit-probe'
        }
        else {
            'codex-hotpatch-native-probe'
        }
        $arguments = @(
            'exec', '--ephemeral', '--ignore-user-config', '--ignore-rules', '--skip-git-repo-check',
            '--sandbox', 'read-only', '--json',
            '-m', $AuthenticatedProbeModel,
            '-c', 'model_reasoning_effort="low"',
            '-c', 'analytics.enabled=false',
            '-c', "model_provider=`"$probeProviderId`"",
            '-c', "model_providers.$probeProviderId={ name=`"OpenAI HTTP Probe`", wire_api=`"responses`", requires_openai_auth=true, supports_websockets=false, request_max_retries=0, stream_max_retries=0 }"
        )
        $catalogOverride = Get-CodexAuthenticatedProbeModelCatalogOverride
        if (-not [string]::IsNullOrWhiteSpace($catalogOverride)) {
            $arguments += @('-c', $catalogOverride)
        }
        foreach ($feature in $AuthenticatedProbeDisabledFeatures) {
            $arguments += @('--disable', $feature)
        }
        $arguments += '-'
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = $officialCliPath
        $startInfo.Arguments = (@($arguments | ForEach-Object {
            ConvertTo-CodexCommandLineArgument -Value $_
        }) -join ' ')
        $startInfo.WorkingDirectory = [IO.Path]::GetTempPath()
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY', 'CODEX_CLI_PATH')) {
            if ($startInfo.EnvironmentVariables.ContainsKey($name)) {
                $startInfo.EnvironmentVariables.Remove($name)
            }
        }
        if ($null -ne $ProxyUri) {
            $proxyValue = $ProxyUri.AbsoluteUri.TrimEnd('/')
            $startInfo.EnvironmentVariables['HTTP_PROXY'] = $proxyValue
            $startInfo.EnvironmentVariables['HTTPS_PROXY'] = $proxyValue
            $startInfo.EnvironmentVariables['ALL_PROXY'] = $proxyValue
            $startInfo.EnvironmentVariables['NO_PROXY'] = $NoProxyValue
        }

        $process = New-Object Diagnostics.Process
        $process.StartInfo = $startInfo
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.WriteLine('Reply with exactly OK. Do not use tools.')
        $process.StandardInput.Close()
        $finished = $process.WaitForExit($TimeoutMilliseconds)
        if (-not $finished) {
            try { $process.Kill() } catch { }
            $process.WaitForExit()
        }
        else {
            $process.WaitForExit()
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $joined = "$stdout`n$stderr"
        $completed = $stdout -match '"type"\s*:\s*"turn\.completed"'
        $transportDiagnostics = Get-CodexResponsesTransportDiagnostics -Text $joined
        $reconnectSignals = $transportDiagnostics.ReconnectSignals
        $transportErrors = $transportDiagnostics.TransportErrors
        $exitCode = if ($finished) { $process.ExitCode } else { $null }
        $healthy = $finished -and $exitCode -eq 0 -and $completed -and
            $reconnectSignals -eq 0 -and $transportErrors -eq 0
        $errorText = if (-not $finished) {
            "官方 CLI 登录态 HTTPS/SSE 探测在 $TimeoutMilliseconds ms 后超时。"
        }
        elseif (-not $healthy) {
            $candidate = @($stderr -split "`r?`n" | Where-Object {
                -not [string]::IsNullOrWhiteSpace($_)
            } | Select-Object -First 1)
            if ($candidate.Count -gt 0) { $candidate[0].Trim() } else { '探测未完成或包含重连/传输错误。' }
        }
        else {
            $null
        }
        return [pscustomobject]@{
            Healthy = $healthy
            Completed = $completed
            ExitCode = $exitCode
            DurationMs = $stopwatch.ElapsedMilliseconds
            ReconnectSignals = $reconnectSignals
            TransportErrors = $transportErrors
            Error = $errorText
        }
    }
    catch {
        return [pscustomobject]@{
            Healthy = $false
            Completed = $false
            ExitCode = $null
            DurationMs = $stopwatch.ElapsedMilliseconds
            ReconnectSignals = 0
            TransportErrors = 0
            Error = $_.Exception.Message
        }
    }
    finally {
        if ($null -ne $process) { $process.Dispose() }
        $stopwatch.Stop()
    }
}

function Get-CodexCliBinaryVersion {
    param([AllowNull()][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $versionOutput = @(& $Path --version 2>$null)
        if ($LASTEXITCODE -ne 0) { return $null }
        $versionText = ($versionOutput -join [Environment]::NewLine).Trim()
        if ($versionText -notmatch '^codex-cli\s+(?<version>\S+)$') { return $null }
        return [string]$Matches.version
    }
    catch {
        return $null
    }
}

function Compare-CodexCliReleaseVersion {
    param(
        [AllowNull()][AllowEmptyString()][string]$Left,
        [AllowNull()][AllowEmptyString()][string]$Right
    )

    $pattern = '^(?<version>\d+(?:\.\d+){1,3})'
    if ([string]::IsNullOrWhiteSpace($Left) -or $Left -notmatch $pattern) { return $null }
    $leftVersion = [Version]$Matches.version
    if ([string]::IsNullOrWhiteSpace($Right) -or $Right -notmatch $pattern) { return $null }
    $rightVersion = [Version]$Matches.version
    return $leftVersion.CompareTo($rightVersion)
}

function Test-CodexOpenAiNpmCliPath {
    param([AllowNull()][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($env:APPDATA)) { return $false }
    try {
        $fullPath = [IO.Path]::GetFullPath($Path)
        $npmPackageRoot = [IO.Path]::GetFullPath(
            (Join-Path $env:APPDATA 'npm\node_modules\@openai\codex')
        ).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        return $fullPath.StartsWith($npmPackageRoot, [StringComparison]::OrdinalIgnoreCase) -and
            $fullPath.EndsWith(
                [IO.Path]::DirectorySeparatorChar + 'bin' + [IO.Path]::DirectorySeparatorChar + 'codex.exe',
                [StringComparison]::OrdinalIgnoreCase
            )
    }
    catch {
        return $false
    }
}

function Test-CodexPathUnderRoot {
    param(
        [AllowNull()][AllowEmptyString()][string]$Path,
        [AllowNull()][AllowEmptyString()][string]$Root
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) { return $false }
    try {
        $rootPrefix = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar) +
            [IO.Path]::DirectorySeparatorChar
        return [IO.Path]::GetFullPath($Path).StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        return $false
    }
}

function Select-CodexOperationalCli {
    param(
        [AllowNull()]$ExactDesktopCandidate,
        [object[]]$FallbackCandidates = @()
    )

    if ($null -ne $ExactDesktopCandidate -and
        (Get-OptionalObjectProperty -InputObject $ExactDesktopCandidate -Name 'Available') -eq $true -and
        -not [string]::IsNullOrWhiteSpace([string](Get-OptionalObjectProperty -InputObject $ExactDesktopCandidate -Name 'Version')) -and
        -not [string]::IsNullOrWhiteSpace([string](Get-OptionalObjectProperty -InputObject $ExactDesktopCandidate -Name 'Path'))) {
        return $ExactDesktopCandidate
    }
    foreach ($candidate in @($FallbackCandidates)) {
        if ((Get-OptionalObjectProperty -InputObject $candidate -Name 'Available') -ne $true -or
            (Get-OptionalObjectProperty -InputObject $candidate -Name 'Trusted') -ne $true -or
            [string]::IsNullOrWhiteSpace([string](Get-OptionalObjectProperty -InputObject $candidate -Name 'Path')) -or
            [string]::IsNullOrWhiteSpace([string](Get-OptionalObjectProperty -InputObject $candidate -Name 'Version'))) {
            continue
        }
        return $candidate
    }
    return $null
}

function Get-CodexActiveDesktopCliPaths {
    try {
        $chatGptProcessIds = [Collections.Generic.HashSet[int]]::new()
        foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name = 'ChatGPT.exe'" -ErrorAction Stop)) {
            [void]$chatGptProcessIds.Add([int]$process.ProcessId)
        }
        return @(
            Get-CimInstance Win32_Process -Filter "Name = 'codex.exe'" -ErrorAction Stop |
                Where-Object {
                    $chatGptProcessIds.Contains([int]$_.ParentProcessId) -and
                    -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
                    (Test-Path -LiteralPath ([string]$_.ExecutablePath) -PathType Leaf)
                } |
                Sort-Object CreationDate -Descending |
                ForEach-Object { [string]$_.ExecutablePath }
        )
    }
    catch {
        return @()
    }
}

function Get-CodexStagedCliPaths {
    if (-not (Test-Path -LiteralPath $DesktopOfficialCliRoot -PathType Container)) { return @() }
    return @(
        Get-ChildItem -LiteralPath $DesktopOfficialCliRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { -not $_.Name.StartsWith('.staging-', [StringComparison]::OrdinalIgnoreCase) } |
            ForEach-Object {
                $cliPath = Join-Path $_.FullName 'codex.exe'
                $hostPath = Join-Path $_.FullName 'codex-code-mode-host.exe'
                if ((Test-Path -LiteralPath $cliPath -PathType Leaf) -and
                    (Test-Path -LiteralPath $hostPath -PathType Leaf)) {
                    Get-Item -LiteralPath $cliPath
                }
            } |
            Sort-Object LastWriteTimeUtc -Descending |
            ForEach-Object { $_.FullName }
    )
}

function Get-CodexOperationalCli {
    $exactPath = Get-CodexDesktopOfficialCliPath
    $exactCandidate = if (-not [string]::IsNullOrWhiteSpace($exactPath) -and
        (Test-Path -LiteralPath $exactPath -PathType Leaf)) {
        [pscustomobject]@{
            Path = $exactPath
            Version = Get-CodexCliBinaryVersion -Path $exactPath
            Source = 'CurrentDesktopStable'
            Available = $true
            Trusted = $true
            ExactDesktopMatch = $true
        }
    }
    else {
        $null
    }
    $selected = Select-CodexOperationalCli -ExactDesktopCandidate $exactCandidate
    if ($null -ne $selected) { return $selected }

    $fallbacks = New-Object 'System.Collections.Generic.List[object]'
    $seenPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($activePath in @(Get-CodexActiveDesktopCliPaths)) {
        if (-not $seenPaths.Add($activePath)) { continue }
        $activeTrusted = (Test-CodexOpenAiNpmCliPath -Path $activePath) -or
            (Test-CodexPathUnderRoot -Path $activePath -Root $DesktopOfficialCliRoot)
        $fallbacks.Add([pscustomobject]@{
            Path = $activePath
            Version = if ($activeTrusted) { Get-CodexCliBinaryVersion -Path $activePath } else { $null }
            Source = 'ActiveDesktopChild'
            Available = Test-Path -LiteralPath $activePath -PathType Leaf
            Trusted = $activeTrusted
            ExactDesktopMatch = $false
        })
        $selected = Select-CodexOperationalCli -FallbackCandidates @($fallbacks[$fallbacks.Count - 1])
        if ($null -ne $selected) { return $selected }
    }
    foreach ($npmPath in @(
        [Environment]::GetEnvironmentVariable('CODEX_CLI_PATH', 'User'),
        [Environment]::GetEnvironmentVariable('CODEX_CLI_PATH', 'Process')
    )) {
        if ([string]::IsNullOrWhiteSpace($npmPath) -or -not $seenPaths.Add($npmPath)) { continue }
        $npmTrusted = Test-CodexOpenAiNpmCliPath -Path $npmPath
        $fallbacks.Add([pscustomobject]@{
            Path = $npmPath
            Version = if ($npmTrusted) { Get-CodexCliBinaryVersion -Path $npmPath } else { $null }
            Source = 'TrustedOpenAiNpm'
            Available = Test-Path -LiteralPath $npmPath -PathType Leaf
            Trusted = $npmTrusted
            ExactDesktopMatch = $false
        })
        $selected = Select-CodexOperationalCli -FallbackCandidates @($fallbacks[$fallbacks.Count - 1])
        if ($null -ne $selected) { return $selected }
    }
    foreach ($stagedPath in @(Get-CodexStagedCliPaths)) {
        if (-not $seenPaths.Add($stagedPath)) { continue }
        $fallbacks.Add([pscustomobject]@{
            Path = $stagedPath
            Version = Get-CodexCliBinaryVersion -Path $stagedPath
            Source = 'PreviousDesktopBootstrap'
            Available = Test-Path -LiteralPath $stagedPath -PathType Leaf
            Trusted = $true
            ExactDesktopMatch = $false
        })
        $selected = Select-CodexOperationalCli -FallbackCandidates @($fallbacks[$fallbacks.Count - 1])
        if ($null -ne $selected) { return $selected }
    }
    return $null
}

function Get-CodexCliOverridePolicy {
    param(
        [AllowNull()][AllowEmptyString()][string]$OverridePath,
        [AllowNull()][AllowEmptyString()][string]$OverrideVersion,
        [AllowNull()][AllowEmptyString()][string]$OfficialCliPath,
        [AllowNull()][AllowEmptyString()][string]$OfficialCliVersion,
        [AllowNull()][AllowEmptyString()][string]$RestoredOriginalPath
    )

    if ([string]::IsNullOrWhiteSpace($OverridePath)) {
        return [pscustomobject]@{
            ClearOverride = $false
            TrustedSource = $false
            VersionComparison = $null
            Reason = '用户级 CODEX_CLI_PATH 未设置；Codex++ 将按当前 Appx 动态选择桌面官方核心。'
        }
    }

    $matchesRestoredOriginal = -not [string]::IsNullOrWhiteSpace($RestoredOriginalPath) -and
        [string]::Equals($OverridePath, $RestoredOriginalPath, [StringComparison]::OrdinalIgnoreCase)
    $trustedSource = $matchesRestoredOriginal -or (Test-CodexOpenAiNpmCliPath -Path $OverridePath)
    if (-not $trustedSource) {
        return [pscustomobject]@{
            ClearOverride = $false
            TrustedSource = $false
            VersionComparison = $null
            Reason = '用户级 CODEX_CLI_PATH 不是旧补丁恢复值或官方 npm CLI；已保留用户自定义覆盖。'
        }
    }

    $comparison = Compare-CodexCliReleaseVersion -Left $OverrideVersion -Right $OfficialCliVersion
    if ($null -eq $comparison) {
        return [pscustomobject]@{
            ClearOverride = $false
            TrustedSource = $true
            VersionComparison = $null
            Reason = '无法可靠比较用户 CLI 与桌面官方核心版本；已保留覆盖并拒绝猜测。'
        }
    }

    $clear = $comparison -lt 0
    return [pscustomobject]@{
        ClearOverride = $clear
        TrustedSource = $true
        VersionComparison = $comparison
        Reason = if ($clear) {
            "用户 CLI $OverrideVersion 落后于当前桌面官方核心 $OfficialCliVersion；已清除覆盖，使 Codex++ 重启时动态使用最新 Appx 核心。"
        }
        else {
            "用户 CLI $OverrideVersion 不落后于当前桌面官方核心 $OfficialCliVersion；未改写覆盖。"
        }
    }
}

function Publish-CodexEnvironmentChange {
    if (-not ('CodexHotpatch.EnvironmentBroadcast' -as [type])) {
        $typeDefinition = @(
            'using System;'
            'using System.Runtime.InteropServices;'
            'namespace CodexHotpatch {'
            '    public static class EnvironmentBroadcast {'
            '        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]'
            '        private static extern IntPtr SendMessageTimeout('
            '            IntPtr hWnd, uint msg, IntPtr wParam, string lParam,'
            '            uint flags, uint timeout, out IntPtr result);'
            '        public static void Notify() {'
            '            IntPtr result;'
            '            SendMessageTimeout(new IntPtr(0xffff), 0x001A, IntPtr.Zero, "Environment", 2, 5000, out result);'
            '        }'
            '    }'
            '}'
        ) -join [Environment]::NewLine
        Add-Type -TypeDefinition $typeDefinition
    }
    [CodexHotpatch.EnvironmentBroadcast]::Notify()
}

function Assert-CodexManagedChildPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $rootPrefix = [IO.Path]::GetFullPath($InstallRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "拒绝操作补丁安装目录外的路径：$fullPath"
    }
    return $fullPath
}

function Get-CodexLegacyDesktopCliProcessStatus {
    if (-not (Test-Path -LiteralPath $LegacyDesktopCliRoot -PathType Container)) {
        return [pscustomobject]@{ Available = $true; Error = $null; Processes = @() }
    }

    try {
        $rootPrefix = [IO.Path]::GetFullPath($LegacyDesktopCliRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) +
            [IO.Path]::DirectorySeparatorChar
        $processes = @(
            Get-CimInstance Win32_Process -ErrorAction Stop |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
                    [IO.Path]::GetFullPath([string]$_.ExecutablePath).StartsWith(
                        $rootPrefix,
                        [StringComparison]::OrdinalIgnoreCase
                    )
                } |
                Select-Object ProcessId, Name, ExecutablePath
        )
        return [pscustomobject]@{ Available = $true; Error = $null; Processes = $processes }
    }
    catch {
        return [pscustomobject]@{ Available = $false; Error = $_.Exception.Message; Processes = @() }
    }
}

function Get-CodexLegacyCliCleanupStatus {
    $archivePresent = Test-Path -LiteralPath $LegacyCliCompatRoot -PathType Container
    $desktopPresent = Test-Path -LiteralPath $LegacyDesktopCliRoot -PathType Container
    $processStatus = Get-CodexLegacyDesktopCliProcessStatus
    $userPath = [Environment]::GetEnvironmentVariable('CODEX_CLI_PATH', 'User')
    $processPath = [Environment]::GetEnvironmentVariable('CODEX_CLI_PATH', 'Process')
    $userUsesMirror = [string]::Equals($userPath, $LegacyDesktopCliPath, [StringComparison]::OrdinalIgnoreCase)
    $processUsesMirror = [string]::Equals($processPath, $LegacyDesktopCliPath, [StringComparison]::OrdinalIgnoreCase)
    $inUse = -not $processStatus.Available -or @($processStatus.Processes).Count -gt 0

    return [pscustomobject]@{
        Complete = -not $archivePresent -and -not $desktopPresent -and -not $userUsesMirror
        CleanupPending = $archivePresent -or $desktopPresent -or $userUsesMirror
        ArchiveCompatPresent = $archivePresent
        DesktopCliPresent = $desktopPresent
        DesktopCliInUse = $inUse
        DesktopCliProcessScanAvailable = $processStatus.Available
        DesktopCliProcessScanError = $processStatus.Error
        DesktopCliProcessIds = @($processStatus.Processes | ForEach-Object ProcessId)
        EnvironmentBackupPresent = Test-Path -LiteralPath $LegacyDesktopCliEnvironmentBackupPath -PathType Leaf
        UserEnvironmentPath = $userPath
        UserEnvironmentUsesMirror = $userUsesMirror
        ProcessEnvironmentUsesMirror = $processUsesMirror
    }
}

function Restore-CodexLegacyCliEnvironment {
    $currentValue = [Environment]::GetEnvironmentVariable('CODEX_CLI_PATH', 'User')
    if (-not [string]::Equals($currentValue, $LegacyDesktopCliPath, [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{
            Restored = $false
            Reason = '用户级 CODEX_CLI_PATH 已不再指向旧镜像，未改写用户设置。'
        }
    }
    if (-not (Test-Path -LiteralPath $LegacyDesktopCliEnvironmentBackupPath -PathType Leaf)) {
        throw '旧镜像仍被用户级 CODEX_CLI_PATH 引用，但恢复备份缺失；已拒绝清空用户设置。'
    }

    try {
        $backup = [IO.File]::ReadAllText($LegacyDesktopCliEnvironmentBackupPath) | ConvertFrom-Json
    }
    catch {
        throw "无法读取旧 CLI 环境备份；已拒绝改写用户设置：$($_.Exception.Message)"
    }
    $originalExistsValue = Get-OptionalObjectProperty -InputObject $backup -Name 'OriginalExists'
    if ($null -eq $originalExistsValue) {
        throw '旧 CLI 环境备份缺少 OriginalExists；已拒绝改写用户设置。'
    }
    $originalExists = [bool]$originalExistsValue
    $originalValue = if ($originalExists) {
        [string](Get-OptionalObjectProperty -InputObject $backup -Name 'OriginalValue')
    }
    else {
        $null
    }

    [Environment]::SetEnvironmentVariable('CODEX_CLI_PATH', $originalValue, 'User')
    Publish-CodexEnvironmentChange
    return [pscustomobject]@{
        Restored = $true
        Reason = if ($originalExists) {
            '已恢复补丁接管前的用户级 CODEX_CLI_PATH；网络补丁启动入口会在子进程中忽略该覆盖并使用桌面官方核心。'
        }
        else {
            '补丁接管前不存在用户级 CODEX_CLI_PATH；已移除旧镜像覆盖。'
        }
    }
}

function Get-CodexLegacyCliOriginalEnvironmentPath {
    if (-not (Test-Path -LiteralPath $LegacyDesktopCliEnvironmentBackupPath -PathType Leaf)) { return $null }
    try {
        $backup = [IO.File]::ReadAllText($LegacyDesktopCliEnvironmentBackupPath) | ConvertFrom-Json
        $originalExistsValue = Get-OptionalObjectProperty -InputObject $backup -Name 'OriginalExists'
        if ($null -eq $originalExistsValue -or -not [bool]$originalExistsValue) { return $null }
        return [string](Get-OptionalObjectProperty -InputObject $backup -Name 'OriginalValue')
    }
    catch {
        return $null
    }
}

function Repair-CodexStaleCliEnvironment {
    $currentValue = [Environment]::GetEnvironmentVariable('CODEX_CLI_PATH', 'User')
    if ([string]::IsNullOrWhiteSpace($currentValue)) {
        return [pscustomobject]@{
            Cleared = $false
            PreviousPath = $null
            PreviousVersion = $null
            OfficialCliPath = $null
            OfficialCliVersion = $null
            Reason = '用户级 CODEX_CLI_PATH 未设置；Codex++ 将按当前 Appx 动态选择桌面官方核心。'
        }
    }
    $officialCliPath = Get-CodexDesktopOfficialCliPath
    $currentVersion = Get-CodexCliBinaryVersion -Path $currentValue
    $officialVersion = Get-CodexCliBinaryVersion -Path $officialCliPath
    $restoredOriginalPath = Get-CodexLegacyCliOriginalEnvironmentPath
    $policy = Get-CodexCliOverridePolicy -OverridePath $currentValue -OverrideVersion $currentVersion `
        -OfficialCliPath $officialCliPath -OfficialCliVersion $officialVersion `
        -RestoredOriginalPath $restoredOriginalPath

    if ($policy.ClearOverride) {
        [Environment]::SetEnvironmentVariable('CODEX_CLI_PATH', $null, 'User')
        Publish-CodexEnvironmentChange
    }
    return [pscustomobject]@{
        Cleared = $policy.ClearOverride
        PreviousPath = $currentValue
        PreviousVersion = $currentVersion
        OfficialCliPath = $officialCliPath
        OfficialCliVersion = $officialVersion
        Reason = $policy.Reason
    }
}

function Remove-CodexLegacyDesktopCliOrphans {
    if (-not (Test-Path -LiteralPath $LegacyDesktopCliRoot -PathType Container)) {
        return [pscustomobject]@{ RemovedCount = 0; RemovedBytes = [Int64]0; SkippedFiles = @() }
    }

    $runtimeNames = @(
        'codex.exe'
        'codex-code-mode-host.exe'
        'codex-command-runner.exe'
        'codex-windows-sandbox-setup.exe'
        'rg.exe'
    )
    $runtimePattern = @($runtimeNames | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $orphanPattern = '^\.(?:' + $runtimePattern + ')-[0-9a-f]{32}\.bak$'
    $removedCount = 0
    [Int64]$removedBytes = 0
    $skippedFiles = New-Object 'System.Collections.Generic.List[string]'

    foreach ($file in @(Get-ChildItem -LiteralPath $LegacyDesktopCliRoot -File -Force -ErrorAction Stop |
            Where-Object Name -Match $orphanPattern)) {
        $managedPath = Assert-CodexManagedChildPath -Path $file.FullName
        $stream = $null
        try {
            $stream = [IO.File]::Open($managedPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $stream.Dispose()
            $stream = $null
            [IO.File]::Delete($managedPath)
            $removedCount++
            $removedBytes += [Int64]$file.Length
        }
        catch {
            $skippedFiles.Add($file.Name)
        }
        finally {
            if ($null -ne $stream) { $stream.Dispose() }
        }
    }

    return [pscustomobject]@{
        RemovedCount = $removedCount
        RemovedBytes = $removedBytes
        SkippedFiles = @($skippedFiles)
    }
}

function Invoke-CodexLegacyCliCleanup {
    $environment = Restore-CodexLegacyCliEnvironment
    $staleEnvironment = Repair-CodexStaleCliEnvironment
    $orphanCleanup = Remove-CodexLegacyDesktopCliOrphans
    $archiveRemoved = $false
    $desktopRemoved = $false

    if (Test-Path -LiteralPath $LegacyCliCompatRoot -PathType Container) {
        $managedArchiveRoot = Assert-CodexManagedChildPath -Path $LegacyCliCompatRoot
        Remove-Item -LiteralPath $managedArchiveRoot -Recurse -Force
        $archiveRemoved = $true
    }

    $desktopReason = $null
    if (Test-Path -LiteralPath $LegacyDesktopCliRoot -PathType Container) {
        $status = Get-CodexLegacyCliCleanupStatus
        if (-not $status.DesktopCliProcessScanAvailable) {
            $desktopReason = "无法确认旧镜像是否仍被占用：$($status.DesktopCliProcessScanError)"
        }
        elseif ($status.DesktopCliInUse) {
            $desktopReason = "旧镜像仍被进程 $(@($status.DesktopCliProcessIds) -join ',') 使用；完整退出 Codex 后由守护器继续回收。"
        }
        elseif ($status.UserEnvironmentUsesMirror) {
            $desktopReason = '用户级 CODEX_CLI_PATH 仍指向旧镜像；为避免留下失效路径，已拒绝删除。'
        }
        else {
            $managedDesktopRoot = Assert-CodexManagedChildPath -Path $LegacyDesktopCliRoot
            Remove-Item -LiteralPath $managedDesktopRoot -Recurse -Force
            $desktopRemoved = $true
        }
    }

    $finalStatus = Get-CodexLegacyCliCleanupStatus
    return [pscustomobject]@{
        Complete = $finalStatus.Complete
        Pending = $finalStatus.CleanupPending
        EnvironmentRestored = $environment.Restored
        StaleEnvironmentCleared = $staleEnvironment.Cleared
        EnvironmentReason = @($environment.Reason, $staleEnvironment.Reason) -join ' '
        ArchiveCompatRemoved = $archiveRemoved
        DesktopCliRemoved = $desktopRemoved
        DesktopCliReason = $desktopReason
        DesktopCliOrphanFilesRemoved = $orphanCleanup.RemovedCount
        DesktopCliOrphanBytesRemoved = $orphanCleanup.RemovedBytes
        DesktopCliOrphanFilesSkipped = @($orphanCleanup.SkippedFiles)
        Status = $finalStatus
    }
}

function Invoke-CodexLegacyCliCleanupSafely {
    try {
        $result = Invoke-CodexLegacyCliCleanup
        $result | Add-Member -NotePropertyName Error -NotePropertyValue $null
        return $result
    }
    catch {
        return [pscustomobject]@{
            Complete = $false
            Pending = $true
            EnvironmentRestored = $false
            StaleEnvironmentCleared = $false
            EnvironmentReason = $null
            ArchiveCompatRemoved = $false
            DesktopCliRemoved = $false
            DesktopCliReason = $null
            DesktopCliOrphanFilesRemoved = 0
            DesktopCliOrphanBytesRemoved = [Int64]0
            DesktopCliOrphanFilesSkipped = @()
            Status = Get-CodexLegacyCliCleanupStatus
            Error = $_.Exception.Message
        }
    }
}

function Get-CodexDesktopLaunchCliPolicy {
    param(
        [AllowNull()][AllowEmptyString()][string]$ExistingOverridePath =
            ([Environment]::GetEnvironmentVariable('CODEX_CLI_PATH', 'Process'))
    )

    $suppressed = -not [string]::IsNullOrWhiteSpace($ExistingOverridePath)
    return [pscustomobject]@{
        ClearOverride = $suppressed
        Source = 'OfficialStable'
        Reason = if ($suppressed) {
            '启动子进程已忽略继承的 CODEX_CLI_PATH，由当前 Codex Desktop 使用官方内容哈希稳定核心。'
        }
        else {
            '当前 Codex Desktop 使用官方内容哈希稳定核心。'
        }
    }
}
function Get-CodexDesktopCompatibility {
    $version = Get-CodexDesktopPackageVersion
    if ($null -eq $version) {
        return [pscustomobject]@{
            Compatible = $false
            Version = $null
            Reason = "无法识别当前 Codex 桌面包版本；为防止未知大版本被补丁阻断，已保留官方内置 provider。已验证版本为 $ValidatedDesktopPackageVersion。"
        }
    }
    if ($version.Major -ne $ValidatedDesktopPackageVersion.Major) {
        return [pscustomobject]@{
            Compatible = $false
            Version = $version
            Reason = "当前 Codex 桌面主版本 $($version.Major) 未经此补丁验证（已验证主版本 $($ValidatedDesktopPackageVersion.Major)）；已在启动前恢复官方内置 provider。"
        }
    }
    return [pscustomobject]@{
        Compatible = $true
        Version = $version
        Reason = "当前 Codex 桌面版本 $version 与已验证主版本 $($ValidatedDesktopPackageVersion.Major) 兼容。"
    }
}

function Get-CodexDesktopExecutable {
    $package = Get-CodexDesktopPackage
    $codexExe = Join-Path $package.InstallLocation 'app\ChatGPT.exe'
    if (-not (Test-Path -LiteralPath $codexExe -PathType Leaf)) {
        throw "未找到 Codex 桌面程序：$codexExe"
    }
    return $codexExe
}

function Get-CodexDesktopCoreProcesses {
    try {
        $chatGptProcessIds = [Collections.Generic.HashSet[int]]::new()
        foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name = 'ChatGPT.exe'" -ErrorAction Stop)) {
            [void]$chatGptProcessIds.Add([int]$process.ProcessId)
        }
        return @(
            Get-CimInstance Win32_Process -Filter "Name = 'codex.exe'" -ErrorAction Stop |
                Where-Object { $chatGptProcessIds.Contains([int]$_.ParentProcessId) } |
                ForEach-Object {
                    $nativeProcess = Get-Process -Id ([int]$_.ProcessId) -ErrorAction Stop
                    [pscustomobject]@{
                        ProcessId = [int]$_.ProcessId
                        ParentProcessId = [int]$_.ParentProcessId
                        StartedUtc = $nativeProcess.StartTime.ToUniversalTime()
                    }
                }
        )
    }
    catch {
        return @()
    }
}

function Get-CodexCoreRouteState {
    if (-not (Test-Path -LiteralPath $CoreRouteStatePath -PathType Leaf)) {
        return [pscustomobject]@{
            Present = $false
            Healthy = $true
            Assignments = @()
            Error = $null
        }
    }

    try {
        $raw = [IO.File]::ReadAllText($CoreRouteStatePath) | ConvertFrom-Json
        if ([int]$raw.Version -ne 1) { throw "不支持的核心路由状态版本：$($raw.Version)" }
        $assignments = @(
            foreach ($item in @($raw.Assignments)) {
                $processId = [int]$item.ProcessId
                $parentProcessId = [int]$item.ParentProcessId
                $startedUtc = ([DateTime]$item.StartedUtc).ToUniversalTime()
                $route = [string]$item.Route
                if ($processId -le 0 -or $parentProcessId -le 0) { throw '核心路由状态包含无效进程标识。' }
                if ($route -notin @('VpnExplicitHttps', 'VpnNativeHttps')) { throw "核心路由状态包含无效线路：$route" }
                [pscustomobject]@{
                    ProcessId = $processId
                    ParentProcessId = $parentProcessId
                    StartedUtc = $startedUtc
                    Route = $route
                    Reason = '该核心沿用首次观察时持久记录的启动线路。'
                }
            }
        )
        return [pscustomobject]@{
            Present = $true
            Healthy = $true
            Assignments = $assignments
            Error = $null
        }
    }
    catch {
        return [pscustomobject]@{
            Present = $true
            Healthy = $false
            Assignments = @()
            Error = $_.Exception.Message
        }
    }
}

function Write-CodexCoreRouteState {
    param([object[]]$Assignments = @())

    $records = @(
        foreach ($assignment in @($Assignments | Where-Object {
            $_.Route -in @('VpnExplicitHttps', 'VpnNativeHttps')
        })) {
            [ordered]@{
                ProcessId = [int]$assignment.ProcessId
                ParentProcessId = [int]$assignment.ParentProcessId
                StartedUtc = ([DateTime]$assignment.StartedUtc).ToUniversalTime().ToString('o')
                Route = [string]$assignment.Route
            }
        }
    )
    $record = [ordered]@{
        Version = 1
        Assignments = $records
    }
    $json = $record | ConvertTo-Json -Depth 4 -Compress
    Write-FileBytesAtomically -Path $CoreRouteStatePath -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($json))
}

function Get-CodexCoreRouteAssignments {
    param(
        [object[]]$CoreProcesses = @(),
        [Parameter(Mandatory = $true)]$HealthState,
        [Parameter(Mandatory = $true)][bool]$ExplicitRoutePrepared,
        [object[]]$PersistedAssignments = @()
    )

    $lastFailureUtc = $HealthState.LastFailureUtc
    $lastSuccessUtc = $HealthState.LastSuccessUtc
    $persistedByProcess = @{}
    foreach ($assignment in @($PersistedAssignments)) {
        $assignmentStartedUtc = ([DateTime]$assignment.StartedUtc).ToUniversalTime()
        $key = '{0}|{1}|{2}' -f ([int]$assignment.ProcessId), ([int]$assignment.ParentProcessId), $assignmentStartedUtc.Ticks
        $persistedByProcess[$key] = $assignment
    }
    return @(
        foreach ($process in @($CoreProcesses)) {
            $startedUtc = ([DateTime]$process.StartedUtc).ToUniversalTime()
            $processKey = '{0}|{1}|{2}' -f ([int]$process.ProcessId), ([int]$process.ParentProcessId), $startedUtc.Ticks
            $route = 'Unknown'
            $reason = '无法从当前持久路由边界确定该核心的启动环境。'
            if ($persistedByProcess.ContainsKey($processKey)) {
                $route = [string]$persistedByProcess[$processKey].Route
                $reason = '该核心沿用首次观察时持久记录的启动线路。'
            }
            elseif ($ExplicitRoutePrepared) {
                $startedDuringNativeInterval = $null -ne $lastFailureUtc -and $null -ne $lastSuccessUtc -and
                    $lastSuccessUtc -gt $lastFailureUtc -and
                    $startedUtc -gt $lastFailureUtc -and $startedUtc -lt $lastSuccessUtc
                if ($startedDuringNativeInterval) {
                    $route = 'VpnNativeHttps'
                    $reason = '该核心启动于显式路径熔断后、提前恢复前，仍保留 VPN 原生启动环境。'
                }
                else {
                    $route = 'VpnExplicitHttps'
                    $reason = '该核心在显式路径准备完成后启动。'
                }
            }
            elseif ($null -eq $lastFailureUtc -or $startedUtc -gt $lastFailureUtc) {
                $route = 'VpnNativeHttps'
                $reason = '该核心在 VPN 原生环境准备完成后启动。'
            }
            elseif ($HealthState.LastFailureKind -eq 'RuntimeStream') {
                $route = 'VpnExplicitHttps'
                $reason = '该核心早于显式路径运行期熔断，仍保留原显式启动环境。'
            }

            [pscustomobject]@{
                ProcessId = [int]$process.ProcessId
                ParentProcessId = [int]$process.ParentProcessId
                StartedUtc = $startedUtc
                Route = $route
                Reason = $reason
            }
        }
    )
}

function Get-AvailableLoopbackPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return [int]$listener.LocalEndpoint.Port
    }
    finally {
        $listener.Stop()
    }
}

function Set-CodexLaunchShortcut {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('Launch', 'SafeLaunch')][string]$LaunchMode,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][string]$CodexExecutable
    )

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $InstalledManager + '" -Mode ' + $LaunchMode
    $shortcut.WorkingDirectory = $InstallRoot
    $shortcut.IconLocation = $CodexExecutable + ',0'
    $shortcut.Description = $Description
    $shortcut.Save()
}

function Set-CodexWatchdogStartupShortcut {
    param([Parameter(Mandatory = $true)][string]$CodexExecutable)

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($WatchdogStartupShortcutPath)
    $shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $shortcut.Arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $InstalledNetworkWatchdog +
        '" -Persistent -ProbeIntervalSeconds ' + $WatchdogProbeIntervalSeconds +
        ' -RuntimePollSeconds ' + $WatchdogRuntimePollSeconds
    $shortcut.WorkingDirectory = $InstallRoot
    $shortcut.IconLocation = $CodexExecutable + ',0'
    $shortcut.Description = '持续识别 Codex/Codex++ 重启并根据真实 HTTPS/SSE 长流错误切换 VPN 路径'
    $shortcut.WindowStyle = 7
    $shortcut.Save()
}

function Start-CodexDesktopProcess {
    $codexExe = Get-CodexDesktopExecutable
    $null = Repair-CodexDesktopRuntimeCache -IncludeNode -IncludeRipgrep
    $cliPolicy = Get-CodexDesktopLaunchCliPolicy
    $debugPort = Get-AvailableLoopbackPort
    $arguments = @(
        '--remote-debugging-address=127.0.0.1'
        "--remote-debugging-port=$debugPort"
        "--remote-allow-origins=http://127.0.0.1:$debugPort"
    )
    $hadExistingCliOverride = Test-Path Env:CODEX_CLI_PATH
    $previousCliOverride = if ($hadExistingCliOverride) { $env:CODEX_CLI_PATH } else { $null }
    try {
        Remove-Item Env:CODEX_CLI_PATH -ErrorAction SilentlyContinue
        $process = Start-Process -FilePath $codexExe -ArgumentList $arguments `
            -WorkingDirectory (Split-Path -Parent $codexExe) -PassThru
    }
    finally {
        if ($hadExistingCliOverride) { $env:CODEX_CLI_PATH = $previousCliOverride }
        else { Remove-Item Env:CODEX_CLI_PATH -ErrorAction SilentlyContinue }
    }
    return [pscustomobject]@{
        Process = $process
        DebugPort = $debugPort
        CliOverridePath = $null
        CliOverrideSource = $cliPolicy.Source
        CliOverrideReason = $cliPolicy.Reason
    }
}

function Invoke-CodexDesktopActivation {
    $codexExe = Get-CodexDesktopExecutable
    $null = Repair-CodexDesktopRuntimeCache -IncludeNode -IncludeRipgrep
    $hadExistingCliOverride = Test-Path Env:CODEX_CLI_PATH
    $previousCliOverride = if ($hadExistingCliOverride) { $env:CODEX_CLI_PATH } else { $null }
    try {
        Remove-Item Env:CODEX_CLI_PATH -ErrorAction SilentlyContinue
        return Start-Process -FilePath $codexExe -WorkingDirectory (Split-Path -Parent $codexExe) -PassThru
    }
    finally {
        if ($hadExistingCliOverride) { $env:CODEX_CLI_PATH = $previousCliOverride }
        else { Remove-Item Env:CODEX_CLI_PATH -ErrorAction SilentlyContinue }
    }
}

function Install-HotpatchRuntimeFiles {
    New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
    $runtimeFiles = @(
        [pscustomobject]@{ Source = $ManagerSourcePath; Target = $InstalledManager }
        [pscustomobject]@{ Source = $NetworkHealthModulePath; Target = $InstalledNetworkHealthModule }
        [pscustomobject]@{ Source = $NetworkRuntimeObserverPath; Target = $InstalledNetworkRuntimeObserver }
        [pscustomobject]@{ Source = $NetworkWatchdogPath; Target = $InstalledNetworkWatchdog }
    )
    foreach ($runtimeFile in $runtimeFiles) {
        if (-not (Test-Path -LiteralPath $runtimeFile.Source -PathType Leaf)) {
            throw "缺少待安装运行文件：$($runtimeFile.Source)"
        }
        if ([IO.Path]::GetFullPath($runtimeFile.Source) -ne [IO.Path]::GetFullPath($runtimeFile.Target)) {
            Write-FileBytesAtomically -Path $runtimeFile.Target -Bytes ([IO.File]::ReadAllBytes($runtimeFile.Source))
        }
        $sourceHash = (Get-FileHash -LiteralPath $runtimeFile.Source -Algorithm SHA256).Hash
        $targetHash = (Get-FileHash -LiteralPath $runtimeFile.Target -Algorithm SHA256).Hash
        if ($sourceHash -ne $targetHash) {
            throw "运行文件安装校验失败：$($runtimeFile.Target)"
        }
    }
}

function Get-CodexNetworkWatchdogProcesses {
    try {
        $watchdogPattern = '(?i)(?:^|\s)-File\s+"?' + [regex]::Escape([IO.Path]::GetFullPath($InstalledNetworkWatchdog)) + '"?(?:\s|$)'
        return @(
            Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction Stop |
                Where-Object { $_.CommandLine -and $_.CommandLine -match $watchdogPattern }
        )
    }
    catch {
        return @()
    }
}

function Get-CodexNetworkWatchdogLaunchSpec {
    $powershellPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $InstalledNetworkWatchdog +
        '" -Persistent -ProbeIntervalSeconds ' + $WatchdogProbeIntervalSeconds +
        ' -RuntimePollSeconds ' + $WatchdogRuntimePollSeconds
    return [pscustomobject]@{
        ExecutablePath = $powershellPath
        Arguments = $arguments
        CommandLine = '"' + $powershellPath + '" ' + $arguments
        WorkingDirectory = $InstallRoot
    }
}

function Start-CodexNetworkWatchdog {
    if (-not (Test-Path -LiteralPath $InstalledNetworkWatchdog -PathType Leaf)) {
        throw "运行期网络监测器未安装：$InstalledNetworkWatchdog"
    }
    $existing = @(Get-CodexNetworkWatchdogProcesses | Select-Object -First 1)
    if ($existing.Count -gt 0) {
        return Get-Process -Id ([int]$existing[0].ProcessId) -ErrorAction Stop
    }
    $launch = Get-CodexNetworkWatchdogLaunchSpec
    $creation = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine = $launch.CommandLine
        CurrentDirectory = $launch.WorkingDirectory
    } -ErrorAction Stop
    if ($null -eq $creation -or [int]$creation.ReturnValue -ne 0 -or [int]$creation.ProcessId -le 0) {
        $returnValue = if ($null -ne $creation) { [int]$creation.ReturnValue } else { -1 }
        throw "无法通过 Windows 进程服务创建脱离式网络守护，返回值 $returnValue。"
    }

    $processId = [int]$creation.ProcessId
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        Start-Sleep -Milliseconds 100
        $registered = @(Get-CodexNetworkWatchdogProcesses | Where-Object { [int]$_.ProcessId -eq $processId })
        if ($registered.Count -gt 0) { break }
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
    } while ($null -ne $process -and [DateTime]::UtcNow -lt $deadline)

    if ($registered.Count -eq 0) {
        Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
        throw '脱离式网络守护已创建，但未通过命令行单实例检查。'
    }
    if ([int]$registered[0].ParentProcessId -eq $PID) {
        Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
        throw '网络守护仍直接从安装进程派生；已拒绝留下可能随宿主退出的实例。'
    }
    $process = Get-Process -Id $processId -ErrorAction Stop
    return $process
}

function Stop-CodexNetworkWatchdog {
    $watchdogProcesses = @(Get-CodexNetworkWatchdogProcesses)
    foreach ($watchdogProcess in $watchdogProcesses) {
        Stop-Process -Id ([int]$watchdogProcess.ProcessId) -Force -ErrorAction SilentlyContinue
    }
    foreach ($watchdogProcess in $watchdogProcesses) {
        $processId = [int]$watchdogProcess.ProcessId
        try {
            Wait-Process -Id $processId -Timeout 10 -ErrorAction Stop
        }
        catch {
            if ($null -ne (Get-Process -Id $processId -ErrorAction SilentlyContinue)) {
                throw "网络守护进程 $processId 未在 10 秒内停止。"
            }
        }
    }
    $remaining = @(Get-CodexNetworkWatchdogProcesses)
    if ($remaining.Count -gt 0) {
        throw "网络守护仍有 $($remaining.Count) 个实例未停止。"
    }
}

function Install-Hotpatch {
    $watchdogWasRunning = Test-CodexNetworkWatchdogRunning
    $legacyCleanup = $null
    $snapshotPaths = @(
        $CodexConfigPath,
        $CodexEnvPath,
        $NetworkHealthPath,
        $TransportStatePath,
        $CoreRouteStatePath,
        $InstalledManager,
        $InstalledNetworkHealthModule,
        $InstalledNetworkRuntimeObserver,
        $InstalledNetworkWatchdog,
        $ShortcutPath,
        $SafeShortcutPath,
        $WatchdogStartupShortcutPath
    )
    $snapshots = @($snapshotPaths | ForEach-Object { Get-FileSnapshot -Path $_ })
    try {
        if ($watchdogWasRunning) { Stop-CodexNetworkWatchdog }
        Install-HotpatchRuntimeFiles
        $transport = Install-CodexHttpTransport
        $selection = Sync-CodexProxyEnv -VerifyRemote -ForceNative:(-not $transport.Enabled)

        $codexExe = Get-CodexDesktopExecutable
        Set-CodexLaunchShortcut -Path $ShortcutPath -LaunchMode Launch `
            -Description '启动前验证 HTTPS-only 路由；显式 VPN 熔断后自动准备原生 VPN，并由运行期监测持续保护' -CodexExecutable $codexExe
        Set-CodexLaunchShortcut -Path $SafeShortcutPath -LaunchMode SafeLaunch `
            -Description '移除网络热补丁托管配置，以当前 VPN 和 Codex 官方内置传输启动' -CodexExecutable $codexExe
        Set-CodexWatchdogStartupShortcut -CodexExecutable $codexExe
        $legacyCleanup = Invoke-CodexLegacyCliCleanupSafely
        $watchdog = Start-CodexNetworkWatchdog
    }
    catch {
        $installError = $_.Exception.Message
        $rollbackErrors = New-Object 'System.Collections.Generic.List[string]'
        for ($index = $snapshots.Count - 1; $index -ge 0; $index--) {
            try {
                Restore-FileSnapshot -Snapshot $snapshots[$index]
            }
            catch {
                $rollbackErrors.Add("$($snapshots[$index].Path): $($_.Exception.Message)")
            }
        }
        if ($watchdogWasRunning) {
            try {
                Start-CodexNetworkWatchdog | Out-Null
            }
            catch {
                $rollbackErrors.Add("恢复旧版网络守护失败：$($_.Exception.Message)")
            }
        }
        if ($rollbackErrors.Count -gt 0) {
            throw "网络补丁安装失败且回滚不完整。原始错误：$installError；回滚错误：$($rollbackErrors -join ' | ')"
        }
        throw "网络补丁安装失败，已恢复安装前状态：$installError"
    }

    "网络代理补丁 $PatchVersion 已安装：$ShortcutPath"
    "兼容兜底入口已安装：$SafeShortcutPath"
    "持续网络自愈守护已安装并启动（PID $($watchdog.Id)）：$WatchdogStartupShortcutPath"
    "TransportMode: $(if ($transport.Enabled) { 'HttpsOnly' } else { 'OfficialBuiltInFallback' })"
    "TransportReason: $($transport.Reason)"
    "LegacyCliCleanup: $(if ($legacyCleanup.Complete) { 'Complete' } else { 'Pending' })"
    if ($legacyCleanup.EnvironmentReason) { "LegacyCliEnvironment: $($legacyCleanup.EnvironmentReason)" }
    if ($legacyCleanup.DesktopCliOrphanFilesRemoved -gt 0) {
        "LegacyCliOrphansRemoved: $($legacyCleanup.DesktopCliOrphanFilesRemoved) files, $([Math]::Round($legacyCleanup.DesktopCliOrphanBytesRemoved / 1MB, 2)) MiB"
    }
    if ($legacyCleanup.DesktopCliReason) { "LegacyDesktopCli: $($legacyCleanup.DesktopCliReason)" }
    if ($legacyCleanup.Error) { "LegacyCliCleanupError: $($legacyCleanup.Error)" }
    "NetworkMode: $($selection.NetworkMode)"
    "Reason: $($selection.Reason)"
    if ($selection.ProxyUri) { "Codex 专属 .env 已同步显式 VPN 代理：$($selection.ProxyUri.AbsoluteUri.TrimEnd('/'))" }
    else { 'Codex 专属 .env 已移除强制代理键；继续使用当前 VPN 的原生系统/TUN 路径。' }
    '启动入口不再注入 CLI 覆盖；Codex Desktop 将使用官方内容哈希稳定核心。'
}

function Uninstall-Hotpatch {
    Stop-CodexNetworkWatchdog
    foreach ($path in @($ShortcutPath, $SafeShortcutPath, $WatchdogStartupShortcutPath)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) { [IO.File]::Delete($path) }
    }
    Remove-ManagedCodexProxyEnv
    Remove-CodexHttpTransport
    $legacyCleanup = Invoke-CodexLegacyCliCleanupSafely
    "网络代理补丁已停用；原 model_provider 已恢复。旧 CLI 清理完成=$($legacyCleanup.Complete)。已安装脚本保留以便审计。"
    if ($legacyCleanup.Error) { "旧 CLI 清理错误：$($legacyCleanup.Error)" }
    elseif ($legacyCleanup.DesktopCliReason) { $legacyCleanup.DesktopCliReason }
}

function Start-CodexWithProxy {
    Set-CodexWatchdogStartupShortcut -CodexExecutable (Get-CodexDesktopExecutable)
    if (Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue) {
        Invoke-CodexDesktopActivation | Out-Null
        $watchdog = Start-CodexNetworkWatchdog
        'Codex 更新后已有实例正在运行；已激活现有窗口，不再把正常更新重启误报为启动失败。'
        '若要让该实例重新继承已准备的代理环境，请从托盘完整退出一次，再使用此快捷方式启动。'
        "持续网络自愈守护 PID：$($watchdog.Id)"
        return
    }

    $transport = Install-CodexHttpTransport
    $selection = Sync-CodexProxyEnv -VerifyRemote -ForceNative:(-not $transport.Enabled)
    if ($selection.NetworkMode -eq 'VpnExplicitHttps') {
        $proxyValue = Set-CodexProxyEnvironment -ProxyUri $selection.ProxyUri
    }
    else {
        Clear-CodexProxyEnvironment
        $proxyValue = $null
    }
    "TransportMode: $(if ($transport.Enabled) { 'HttpsOnly' } else { 'OfficialBuiltInFallback' })"
    "TransportReason: $($transport.Reason)"
    "NetworkMode: $($selection.NetworkMode)"
    "Reason: $($selection.Reason)"
    if ($proxyValue) { "正在使用进程级 VPN 代理启动 Codex：$proxyValue" }
    else { '正在使用 VPN 原生系统/TUN 路径启动 Codex（不强制代理环境）。' }
    $launch = Start-CodexDesktopProcess
    "本地 DevTools 端口：$($launch.DebugPort)"
    "核心 CLI：$($launch.CliOverrideReason)"
    $watchdog = Start-CodexNetworkWatchdog
    "持续网络自愈守护 PID：$($watchdog.Id)"
}

function Start-CodexSafeFallback {
    if (Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue) {
        throw 'Codex 已在运行。请先从托盘完全退出 Codex，再使用“Codex（官方兼容兜底）”启动。'
    }

    # Keep the explicit opt-out effective across logins until Launch or Install enables it again.
    Stop-CodexNetworkWatchdog
    if (Test-Path -LiteralPath $WatchdogStartupShortcutPath -PathType Leaf) {
        [IO.File]::Delete($WatchdogStartupShortcutPath)
    }

    $configExists = Test-Path -LiteralPath $CodexConfigPath -PathType Leaf
    $configText = if ($configExists) { [IO.File]::ReadAllText($CodexConfigPath) } else { '' }
    $transportFallback = Set-CodexOfficialTransportFallback -ExistingText $configText -RollbackText $configText -RollbackExists $configExists
    Remove-ManagedCodexProxyEnv
    Clear-CodexProxyEnvironment
    '已停用网络守护及其登录自启；下次使用代理优化入口或重新安装时恢复。'
    'CompatibilityMode: OfficialBuiltInVpnNative'
    if ($transportFallback.ProviderDefinitionPreserved) {
        '已恢复官方 model_provider，并保留旧任务依赖的 provider 兼容定义；使用当前 VPN 和 Codex 官方内置网络行为。'
    }
    else {
        '当前版本拒绝旧 provider 定义，已退回纯官方配置；使用当前 VPN 和 Codex 官方内置网络行为。'
    }
    $launch = Start-CodexDesktopProcess
    "本地 DevTools 端口：$($launch.DebugPort)"
    "核心 CLI：$($launch.CliOverrideReason)"
}

function Get-CodexSelectedAuthenticatedVerification {
    param([Parameter(Mandatory = $true)]$Selection)

    $networkMode = [string](Get-OptionalObjectProperty -InputObject $Selection -Name 'NetworkMode')
    $propertyPrefix = if ($networkMode -eq 'VpnExplicitHttps') { 'Explicit' } else { 'Native' }
    return [pscustomobject]@{
        Route = $networkMode
        Mode = Get-OptionalObjectProperty -InputObject $Selection -Name "${propertyPrefix}VerificationMode"
        Probe = Get-OptionalObjectProperty -InputObject $Selection -Name "${propertyPrefix}AuthenticatedProbe"
    }
}

function Get-CodexNetworkDoctorOverallStatus {
    param(
        [Parameter(Mandatory = $true)]$Selection,
        [AllowNull()]$Probe,
        [AllowNull()]$AuthenticatedHealthy
    )

    if ((Get-OptionalObjectProperty -InputObject $Selection -Name 'RouteHealthy') -eq $true) {
        if ($AuthenticatedHealthy -eq $true) { return 'ok (authenticated HTTPS/SSE)' }
        return 'ok (HTTPS/SSE)'
    }
    if ($null -eq (Get-OptionalObjectProperty -InputObject $Selection -Name 'RouteHealthy')) {
        return 'unknown (diagnostic unavailable)'
    }
    return Get-OptionalObjectProperty -InputObject $Probe -Name 'DoctorOverallStatus'
}

function Invoke-CodexDoctor {
    $transport = Install-CodexHttpTransport
    $selection = Sync-CodexProxyEnv -VerifyRemote -ForceNative:(-not $transport.Enabled)
    $probe = $selection.NetworkProbe
    $authenticatedVerification = Get-CodexSelectedAuthenticatedVerification -Selection $selection
    $authenticatedProbe = $authenticatedVerification.Probe
    $authenticatedHealthy = if ($null -ne $authenticatedProbe) {
        (Get-OptionalObjectProperty -InputObject $authenticatedProbe -Name 'Healthy') -eq $true
    }
    else {
        $null
    }
    [pscustomobject]@{
        PatchVersion = $PatchVersion
        TransportMode = if ($transport.Enabled) { 'HttpsOnly' } else { 'OfficialBuiltInFallback' }
        TransportReason = $transport.Reason
        NetworkMode = $selection.NetworkMode
        Reason = $selection.Reason
        ProxyUri = if ($selection.ProxyUri) { $selection.ProxyUri.AbsoluteUri.TrimEnd('/') } else { $null }
        ProxySource = $CodexEnvPath
        ProviderReachability = $probe.ProviderStatus
        ProviderSummary = $probe.ProviderSummary
        ResponsesEndpointReachability = $probe.ResponsesEndpointHealthy
        ResponsesEndpointStatusCode = $probe.ResponsesEndpointStatusCode
        ResponsesEndpointError = $probe.ResponsesEndpointError
        WebSocketReachability = $probe.WebSocketStatus
        WebSocketSummary = $probe.WebSocketSummary
        WebSocketHandshake = $probe.WebSocketHandshake
        WebSocketDurationMs = $probe.WebSocketDurationMs
        AuthenticatedResponsesReachability = $authenticatedHealthy
        AuthenticatedResponsesDurationMs = Get-OptionalObjectProperty -InputObject $authenticatedProbe -Name 'DurationMs'
        AuthenticatedResponsesError = Get-OptionalObjectProperty -InputObject $authenticatedProbe -Name 'Error'
        AuthenticatedResponsesRoute = if ($null -ne $authenticatedProbe) { $authenticatedVerification.Route } else { $null }
        RouteVerificationMode = $authenticatedVerification.Mode
        ExplicitVerificationMode = Get-OptionalObjectProperty -InputObject $selection -Name 'ExplicitVerificationMode'
        NativeVerificationMode = Get-OptionalObjectProperty -InputObject $selection -Name 'NativeVerificationMode'
        CodexDoctorOverallStatus = Get-OptionalObjectProperty -InputObject $probe -Name 'DoctorOverallStatus'
        DoctorOverallStatus = Get-CodexNetworkDoctorOverallStatus -Selection $selection -Probe $probe `
            -AuthenticatedHealthy $authenticatedHealthy
        RouteHealthy = $selection.RouteHealthy
        ExplicitProxyMedianMs = $selection.ExplicitProxyMedianMs
        NativeMedianMs = $selection.NativeMedianMs
        CircuitState = $selection.CircuitState
        CircuitFailures = $selection.CircuitFailures
        CircuitRetryAfterUtc = $selection.CircuitRetryAfterUtc
        Note = '两条路径均使用 HTTPS/SSE；无凭据 Responses 检查与 provider/传输证据矛盾时，对实际候选线路使用当前官方 CLI 的登录态、零重连真实请求裁决并按线路短时缓存。真实长流错误仍会触发备用线路验证。'
    } | Format-List

    if (-not $selection.RouteHealthy) {
        exit 1
    }
    exit 0
}

function Test-CodexNetworkWatchdogRunning {
    return @(Get-CodexNetworkWatchdogProcesses).Count -gt 0
}

function Show-Status {
    $explicitProxyCandidate = Resolve-CodexNetworkMode
    $proxyUri = $explicitProxyCandidate.ProxyUri
    $envStatus = Get-CodexProxyEnvStatus -ExpectedProxyUri $proxyUri
    $healthState = Get-VpnHealthState
    $transportStatus = Get-CodexHttpTransportStatus
    $desktopCompatibility = Get-CodexDesktopCompatibility
    $desktopOfficialCliPath = Get-CodexDesktopOfficialCliPath
    $desktopOfficialCliVersion = Get-CodexCliBinaryVersion -Path $desktopOfficialCliPath
    $operationalCli = Get-CodexOperationalCli
    $legacyCliStatus = Get-CodexLegacyCliCleanupStatus
    $userCliEnvironmentVersion = Get-CodexCliBinaryVersion -Path $legacyCliStatus.UserEnvironmentPath
    $userCliEnvironmentPolicy = Get-CodexCliOverridePolicy `
        -OverridePath $legacyCliStatus.UserEnvironmentPath `
        -OverrideVersion $userCliEnvironmentVersion `
        -OfficialCliPath $desktopOfficialCliPath `
        -OfficialCliVersion $desktopOfficialCliVersion `
        -RestoredOriginalPath (Get-CodexLegacyCliOriginalEnvironmentPath)
    $runtimeCursorStatus = Get-CodexRuntimeNetworkCursorStatus -CursorPath $NetworkRuntimeCursorPath
    $coreRouteState = Get-CodexCoreRouteState
    $preparedMode = if ($envStatus.Managed -and $envStatus.Matches) {
        'VpnExplicitHttps'
    }
    elseif (-not $envStatus.Managed) {
        'VpnNativeHttps'
    }
    else {
        'StaleExplicitProxy'
    }
    $coreProcesses = @(Get-CodexDesktopCoreProcesses)
    $routeAssignments = @(Get-CodexCoreRouteAssignments -CoreProcesses $coreProcesses `
        -HealthState $healthState -ExplicitRoutePrepared:($preparedMode -eq 'VpnExplicitHttps') `
        -PersistedAssignments $coreRouteState.Assignments)
    $nativeCoreProcessIds = @($routeAssignments | Where-Object Route -eq 'VpnNativeHttps' | ForEach-Object ProcessId)
    $recentNative = if ($nativeCoreProcessIds.Count -gt 0) {
        Get-CodexRecentRuntimeNetworkEvents -DatabasePath $CodexRuntimeLogsPath `
            -ActiveProcessIds $nativeCoreProcessIds -IncludeWebSocket `
            -FailureWindow $NativeRuntimeFailureWindow
    }
    else {
        [pscustomobject]@{ Available = $true; Error = $null; Events = @() }
    }
    $nativeHttpEvents = @($recentNative.Events | Where-Object Transport -eq 'HttpSse')
    $nativeWebSocketEvents = @($recentNative.Events | Where-Object Transport -eq 'WebSocket')
    $nativeUnknownEvents = @($recentNative.Events | Where-Object Transport -eq 'Unknown')
    $nativeDegradation = Get-CodexRuntimeNetworkDegradation -Events $nativeHttpEvents `
        -FailureThreshold $NativeRuntimeFailureThreshold -FailureWindow $NativeRuntimeFailureWindow
    $nativeWebSocketDegradation = Get-CodexRuntimeNetworkDegradation -Events $nativeWebSocketEvents `
        -FailureThreshold $NativeRuntimeFailureThreshold -FailureWindow $NativeRuntimeFailureWindow
    $currentCoreRoutes = @($routeAssignments | Select-Object -ExpandProperty Route -Unique)
    $preparedRouteRequiresRestart = @($routeAssignments | Where-Object Route -ne 'Unknown' | Where-Object Route -ne $preparedMode).Count -gt 0

    [pscustomobject]@{
        PatchVersion = $PatchVersion
        DesktopPackageVersion = if ($desktopCompatibility.Version) { $desktopCompatibility.Version.ToString() } else { $null }
        ValidatedDesktopPackageVersion = $ValidatedDesktopPackageVersion.ToString()
        DesktopMajorCompatible = $desktopCompatibility.Compatible
        NetworkMode = $preparedMode
        ExplicitProxyEnabled = Test-CodexExplicitProxyEnabled
        HttpsOnlyEnabled = -not (Test-Path -LiteralPath $HttpTransportDisabledPath -PathType Leaf)
        ExplicitProxyDisabledPath = $ExplicitProxyDisabledPath
        Reason = if ($preparedMode -eq 'VpnNativeHttps' -and -not (Test-CodexExplicitProxyEnabled)) {
            '用户已停用显式代理；VPN 原生 HTTPS/SSE 为唯一启用路径，冷却到期或原生断流均不会自动切回。'
        }
        elseif ($preparedMode -eq 'VpnNativeHttps') {
            if ($healthState.CircuitState -eq 'Open') {
                $retryText = if ($null -ne $healthState.RetryAfterUtc) { $healthState.RetryAfterUtc.ToString('o') } else { '状态修复后' }
                "显式 VPN 已熔断；Codex 为新进程准备 VPN 原生 HTTPS/SSE 路径，最早恢复探测时间 $retryText。"
            }
            else {
                'Codex 使用 VPN 原生 HTTPS/SSE 路径。'
            }
        }
        elseif ($preparedMode -eq 'VpnExplicitHttps') {
            if ($preparedRouteRequiresRestart) {
                '已为新进程准备显式 VPN HTTPS/SSE；当前 VPN 原生核心需完整重启后才会采用。'
            }
            else {
                'Codex 使用显式 VPN 代理承载 HTTPS/SSE。'
            }
        }
        else {
            'Codex .env 中的显式代理与当前 WinINET 代理不一致；请运行 SyncEnv。'
        }
        Installed = (Test-Path -LiteralPath $InstalledManager -PathType Leaf) -and
            (Test-Path -LiteralPath $InstalledNetworkHealthModule -PathType Leaf) -and
            (Test-Path -LiteralPath $InstalledNetworkRuntimeObserver -PathType Leaf) -and
            (Test-Path -LiteralPath $InstalledNetworkWatchdog -PathType Leaf) -and
            (Test-Path -LiteralPath $TransportStatePath -PathType Leaf) -and
            (Test-Path -LiteralPath $ShortcutPath -PathType Leaf) -and
            (Test-Path -LiteralPath $SafeShortcutPath -PathType Leaf) -and
            (Test-Path -LiteralPath $WatchdogStartupShortcutPath -PathType Leaf)
        ShortcutPath = $ShortcutPath
        SafeShortcutPath = $SafeShortcutPath
        SafeShortcutInstalled = Test-Path -LiteralPath $SafeShortcutPath -PathType Leaf
        ProxyUri = if ($proxyUri) { $proxyUri.AbsoluteUri.TrimEnd('/') } else { $null }
        ExplicitProxyCandidate = if ($proxyUri) { $proxyUri.AbsoluteUri.TrimEnd('/') } else { $null }
        ProxyListenerReady = [bool]$proxyUri
        ProxyError = if ($explicitProxyCandidate.NetworkMode -eq 'VpnProxy') { $null } else { $explicitProxyCandidate.Reason }
        CodexEnvPath = $CodexEnvPath
        CodexEnvExists = $envStatus.Exists
        CodexEnvManaged = $envStatus.Managed
        CodexEnvMatchesCurrentProxy = $envStatus.Matches
        VpnNativePrepared = $preparedMode -eq 'VpnNativeHttps'
        LoopbackBypassConfigured = $envStatus.LoopbackBypass
        HttpOnlyTransportManaged = $transportStatus.Managed
        HttpOnlyTransportSelected = $transportStatus.Selected
        HttpOnlyTransportDetachedSelector = $transportStatus.DetachedSelector
        HttpOnlyTransportRepairable = $transportStatus.Repairable
        TransportRecoveryStatePath = $TransportStatePath
        TransportRecoveryStatePresent = $transportStatus.RecoveryStatePresent
        TransportRecoveryStateHealthy = $transportStatus.RecoveryStateHealthy
        TransportRecoveryStateError = $transportStatus.RecoveryStateError
        CodexConfigPath = $CodexConfigPath
        DesktopCliSource = 'OfficialStable'
        DesktopOfficialCliPath = $desktopOfficialCliPath
        DesktopOfficialCliVersion = $desktopOfficialCliVersion
        ValidationCliPath = Get-OptionalObjectProperty -InputObject $operationalCli -Name 'Path'
        ValidationCliSource = Get-OptionalObjectProperty -InputObject $operationalCli -Name 'Source'
        ValidationCliVersion = Get-OptionalObjectProperty -InputObject $operationalCli -Name 'Version'
        ValidationMatchesCurrentDesktop = (Get-OptionalObjectProperty -InputObject $operationalCli -Name 'ExactDesktopMatch') -eq $true
        LegacyCliCleanupPending = $legacyCliStatus.CleanupPending
        LegacyArchiveCompatPresent = $legacyCliStatus.ArchiveCompatPresent
        LegacyDesktopCliPresent = $legacyCliStatus.DesktopCliPresent
        LegacyDesktopCliInUse = $legacyCliStatus.DesktopCliInUse
        LegacyDesktopCliProcessIds = @($legacyCliStatus.DesktopCliProcessIds) -join ','
        LegacyCliEnvironmentBackupPresent = $legacyCliStatus.EnvironmentBackupPresent
        UserCliEnvironmentPath = $legacyCliStatus.UserEnvironmentPath
        UserCliEnvironmentVersion = $userCliEnvironmentVersion
        UserCliEnvironmentRequiresCleanup = $userCliEnvironmentPolicy.ClearOverride
        UserCliEnvironmentPolicy = $userCliEnvironmentPolicy.Reason
        UserCliEnvironmentUsesLegacyMirror = $legacyCliStatus.UserEnvironmentUsesMirror
        ProcessCliEnvironmentUsesLegacyMirror = $legacyCliStatus.ProcessEnvironmentUsesMirror
        CircuitState = $healthState.CircuitState
        CircuitFailures = $healthState.ConsecutiveFailures
        CircuitSuppressesExplicit = $healthState.SuppressExplicit
        CircuitHalfOpenEligible = $healthState.HalfOpenEligible
        CircuitRetryAfterUtc = $healthState.RetryAfterUtc
        LastExplicitProxyFailureUtc = $healthState.LastFailureUtc
        LastExplicitProxyFailureReason = $healthState.LastFailureReason
        LastExplicitProxyFailureKind = $healthState.LastFailureKind
        LastExplicitProxySuccessUtc = $healthState.LastSuccessUtc
        RuntimeStreamFailureCount = $healthState.RuntimeFailureCount
        LastRuntimeStreamFailureUtc = $healthState.LastRuntimeFailureUtc
        CurrentCoreRoutes = if ($currentCoreRoutes.Count -gt 0) { $currentCoreRoutes -join ',' } else { $null }
        NativeCoreProcessIds = $nativeCoreProcessIds -join ','
        NativeRuntimeFailureTurns = $nativeDegradation.DistinctTurnCount
        NativeRuntimeFailureEvents = $nativeDegradation.EventCount
        NativeRuntimeFailureThreshold = $NativeRuntimeFailureThreshold
        NativeRuntimeFailureWindowMinutes = [int]$NativeRuntimeFailureWindow.TotalMinutes
        NativeRuntimeDegraded = $nativeDegradation.Degraded
        NativeRuntimeFailoverRequired = $nativeDegradation.FailoverRequired
        NativeRuntimeExhaustedTurns = $nativeDegradation.ExhaustedTurnCount
        NativeRuntimePersistentTurns = $nativeDegradation.PersistentTurnCount
        LastNativeRuntimeFailureUtc = $nativeDegradation.LastFailureUtc
        LastNativeRuntimeFailureReason = $nativeDegradation.LastFailureReason
        NativeWebSocketFailureTurns = $nativeWebSocketDegradation.DistinctTurnCount
        NativeWebSocketFailureEvents = $nativeWebSocketDegradation.EventCount
        NativeUnknownTransportEvents = $nativeUnknownEvents.Count
        LegacyThreadProviderDriftDetected = $transportStatus.Selected -and $nativeWebSocketDegradation.EventCount -gt 0
        NativeRuntimeScanAvailable = $recentNative.Available
        NativeRuntimeScanError = $recentNative.Error
        NetworkHealthStateCorrupt = $healthState.IsCorrupt
        NetworkWatchdogInstalled = Test-Path -LiteralPath $InstalledNetworkWatchdog -PathType Leaf
        NetworkWatchdogRunning = Test-CodexNetworkWatchdogRunning
        NetworkWatchdogStartupInstalled = Test-Path -LiteralPath $WatchdogStartupShortcutPath -PathType Leaf
        NetworkWatchdogStartupPath = $WatchdogStartupShortcutPath
        RuntimeLogObserverInstalled = Test-Path -LiteralPath $InstalledNetworkRuntimeObserver -PathType Leaf
        RuntimeLogDatabasePath = $CodexRuntimeLogsPath
        RuntimeLogDatabaseExists = Test-Path -LiteralPath $CodexRuntimeLogsPath -PathType Leaf
        RuntimeLogCursorHealthy = $runtimeCursorStatus.Healthy
        RuntimeLogCursorLastId = $runtimeCursorStatus.LastLogId
        RuntimeLogCursorError = $runtimeCursorStatus.Error
        CoreRouteStatePath = $CoreRouteStatePath
        CoreRouteStatePresent = $coreRouteState.Present
        CoreRouteStateHealthy = $coreRouteState.Healthy
        CoreRouteStateError = $coreRouteState.Error
        FallbackPreparedForNextFullRestart = $preparedMode -eq 'VpnNativeHttps' -and $healthState.CircuitState -eq 'Open'
        PreparedRouteRequiresRestart = $preparedRouteRequiresRestart
        CodexRunning = [bool](Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue)
        InstallRoot = $InstallRoot
    } | Format-List
}

if ($MyInvocation.InvocationName -ne '.') {
    switch ($Mode) {
        'Install' { Install-Hotpatch }
        'Uninstall' { Uninstall-Hotpatch }
        'SyncEnv' {
            $transport = Install-CodexHttpTransport
            $selection = Sync-CodexProxyEnv -VerifyRemote -ForceNative:(-not $transport.Enabled)
            [pscustomobject]@{
                PatchVersion = $PatchVersion
                TransportMode = if ($transport.Enabled) { 'HttpsOnly' } else { 'OfficialBuiltInFallback' }
                TransportReason = $transport.Reason
                NetworkMode = $selection.NetworkMode
                Reason = $selection.Reason
                ProxyUri = if ($selection.ProxyUri) { $selection.ProxyUri.AbsoluteUri.TrimEnd('/') } else { $null }
                CodexEnvPath = $CodexEnvPath
                CircuitState = $selection.CircuitState
                CircuitFailures = $selection.CircuitFailures
                CircuitRetryAfterUtc = $selection.CircuitRetryAfterUtc
            } | Format-List
        }
        'Launch' { Start-CodexWithProxy }
        'SafeLaunch' { Start-CodexSafeFallback }
        'Doctor' { Invoke-CodexDoctor }
        'Status' { Show-Status }
    }
}
