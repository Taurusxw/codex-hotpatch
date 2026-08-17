[CmdletBinding()]
param(
    [ValidateSet('Install', 'Uninstall', 'SyncEnv', 'Launch', 'SafeLaunch', 'Doctor', 'Status')]
    [string]$Mode = 'Status'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PatchName = 'CodexNetworkProxyHotpatch'
$PatchVersion = '1.9.0'
$ManagerSourcePath = $PSCommandPath
$InstallRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\hotpatches\network-proxy'
$InstalledManager = Join-Path $InstallRoot 'manage-hotpatch.ps1'
$NetworkHealthModulePath = Join-Path $PSScriptRoot 'network-health.psm1'
$NetworkRuntimeObserverPath = Join-Path $PSScriptRoot 'network-runtime-observer.psm1'
$NetworkWatchdogPath = Join-Path $PSScriptRoot 'network-watchdog.ps1'
$InstalledNetworkHealthModule = Join-Path $InstallRoot 'network-health.psm1'
$InstalledNetworkRuntimeObserver = Join-Path $InstallRoot 'network-runtime-observer.psm1'
$InstalledNetworkWatchdog = Join-Path $InstallRoot 'network-watchdog.ps1'
$NetworkHealthPath = Join-Path $InstallRoot 'network-health.json'
$NetworkRuntimeCursorPath = Join-Path $InstallRoot 'network-runtime-cursor.json'
$CodexRuntimeLogsPath = Join-Path $env:USERPROFILE '.codex\logs_2.sqlite'
$ShortcutPath = Join-Path ([Environment]::GetFolderPath('Programs')) 'Codex（代理优化）.lnk'
$SafeShortcutPath = Join-Path ([Environment]::GetFolderPath('Programs')) 'Codex（官方兼容兜底）.lnk'
$WatchdogStartupShortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'Codex 网络自愈守护.lnk'
$CodexEnvPath = Join-Path $env:USERPROFILE '.codex\.env'
$CodexConfigPath = Join-Path $env:USERPROFILE '.codex\config.toml'
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
$NativeRuntimeFailureThreshold = 3
$NativeRuntimeFailureWindow = [TimeSpan]::FromMinutes(10)
$WatchdogProbeIntervalSeconds = 45
$WatchdogRuntimePollSeconds = 5
$TransportRequestMaxRetries = 6
$TransportStreamMaxRetries = 8
$ValidatedDesktopPackageVersion = [Version]'26.810.7004.0'

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
            [Net.WebRequest]::GetSystemWebProxy()
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

function Convert-CodexTransportConfigText {
    param(
        [AllowEmptyString()][string]$ExistingText,
        [Parameter(Mandatory = $true)][ValidateSet('Install', 'Remove')][string]$Action
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

    $hasManagedBlocks = $selectorStarts.Count -eq 1 -and $selectorEnds.Count -eq 1 -and
        $providerStarts.Count -eq 1 -and $providerEnds.Count -eq 1
    $hasAnyManagedMarker = ($selectorStarts.Count + $selectorEnds.Count + $providerStarts.Count + $providerEnds.Count) -gt 0
    if ($hasAnyManagedMarker -and -not $hasManagedBlocks) {
        throw 'Codex config.toml 中的网络传输托管标记不完整或重复；为避免覆盖用户配置，已停止。'
    }
    if ($hasManagedBlocks -and ($selectorStarts[0] -ge $selectorEnds[0] -or $providerStarts[0] -ge $providerEnds[0])) {
        throw 'Codex config.toml 中的网络传输托管标记顺序无效；为避免覆盖用户配置，已停止。'
    }

    $baseLines = New-Object 'System.Collections.Generic.List[string]'
    if ($hasManagedBlocks) {
        $originalProviderLine = $null
        for ($index = $selectorStarts[0] + 1; $index -lt $selectorEnds[0]; $index++) {
            if ($lines[$index] -match '^\s*#\s*original-model-provider-base64:\s*(?<value>\S+)\s*$') {
                if ($Matches.value -ne '__ABSENT__') {
                    try {
                        $originalProviderLine = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches.value))
                    }
                    catch {
                        throw 'Codex config.toml 的原始 model_provider 恢复信息损坏；已停止修改。'
                    }
                }
                break
            }
        }
        if ($null -eq $originalProviderLine -and -not (@($lines[($selectorStarts[0] + 1)..($selectorEnds[0] - 1)]) -match 'original-model-provider-base64:\s*__ABSENT__')) {
            throw 'Codex config.toml 的托管选择器缺少原始 model_provider 恢复信息；已停止修改。'
        }

        $index = 0
        while ($index -lt $lines.Count) {
            if ($index -eq $selectorStarts[0]) {
                if ($null -ne $originalProviderLine) { $baseLines.Add($originalProviderLine) }
                $index = $selectorEnds[0] + 1
                continue
            }
            if ($index -eq $providerStarts[0]) {
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
    if ($Action -eq 'Remove') {
        if ($baseLines.Count -eq 0) { return '' }
        return ($baseLines -join [Environment]::NewLine) + [Environment]::NewLine
    }

    if (@($baseLines | Where-Object { $_.Trim() -eq "[model_providers.$TransportProviderId]" }).Count -gt 0) {
        throw "Codex config.toml 已存在 model_providers.$TransportProviderId；已停止安装以避免覆盖。"
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

    $originalLine = if ($rootProviderIndices.Count -eq 1) { $baseLines[$rootProviderIndices[0]] } else { $null }
    $originalEncoded = if ($null -eq $originalLine) {
        '__ABSENT__'
    }
    else {
        [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($originalLine))
    }
    $selectorBlock = @(
        $TransportSelectorStart
        "# original-model-provider-base64: $originalEncoded"
        "model_provider = `"$TransportProviderId`""
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
    foreach ($line in @(
        $TransportProviderStart
        "[model_providers.$TransportProviderId]"
        'name = "OpenAI HTTP (Codex hotpatch)"'
        'wire_api = "responses"'
        'requires_openai_auth = true'
        'supports_websockets = false'
        'supports_standalone_web_search = true'
        "request_max_retries = $TransportRequestMaxRetries"
        "stream_max_retries = $TransportStreamMaxRetries"
        $TransportProviderEnd
    )) {
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
        $codexCommand = Get-Command codex -ErrorAction Stop
        & $codexCommand.Source features list *> $null
        return $LASTEXITCODE -eq 0
    }
    catch {
        return $false
    }
}

function Install-CodexHttpTransport {
    $originalExists = Test-Path -LiteralPath $CodexConfigPath -PathType Leaf
    $originalText = if ($originalExists) { [IO.File]::ReadAllText($CodexConfigPath) } else { '' }
    $alreadyManaged = $originalText.Contains($TransportSelectorStart) -and $originalText.Contains($TransportProviderStart)
    $desktopCompatibility = Get-CodexDesktopCompatibility
    if (-not $desktopCompatibility.Compatible) {
        if ($alreadyManaged) {
            $recoveredText = Convert-CodexTransportConfigText -ExistingText $originalText -Action Remove
            Write-CodexConfigTextAtomically -Text $recoveredText
            if (-not (Test-CodexConfigLoads)) {
                Write-CodexConfigTextAtomically -Text $originalText
                throw '桌面主版本兼容门禁已恢复官方 provider，但恢复后的用户配置未通过解析；已原子恢复现场。'
            }
        }
        return [pscustomobject]@{
            Enabled = $false
            CompatibilityFallback = $true
            Reason = $desktopCompatibility.Reason
        }
    }
    if ($alreadyManaged -and -not (Test-CodexConfigLoads)) {
        $recoveredText = Convert-CodexTransportConfigText -ExistingText $originalText -Action Remove
        Write-CodexConfigTextAtomically -Text $recoveredText
        if (Test-CodexConfigLoads) {
            return [pscustomobject]@{
                Enabled = $false
                CompatibilityFallback = $true
                Reason = '当前 Codex 版本不再接受托管 HTTPS-only provider；已在启动前恢复原 model_provider。'
            }
        }
        Write-CodexConfigTextAtomically -Text $originalText
        throw '当前 Codex 无法解析托管配置，移除补丁托管块后仍无法解析用户配置；已恢复现场并停止启动。'
    }

    $newText = Convert-CodexTransportConfigText -ExistingText $originalText -Action Install
    Write-CodexConfigTextAtomically -Text $newText
    if (-not (Test-CodexConfigLoads)) {
        if ($originalExists) { Write-CodexConfigTextAtomically -Text $originalText }
        elseif (Test-Path -LiteralPath $CodexConfigPath -PathType Leaf) { [IO.File]::Delete($CodexConfigPath) }
        if (-not $originalExists -or (Test-CodexConfigLoads)) {
            return [pscustomobject]@{
                Enabled = $false
                CompatibilityFallback = $true
                Reason = '当前 Codex 版本不接受 HTTPS-only provider；已保留官方内置 provider。'
            }
        }
        throw 'HTTPS-only provider 配置未通过 Codex 解析，且原 config.toml 也无法由当前版本解析；已恢复现场。'
    }
    return [pscustomobject]@{
        Enabled = $true
        CompatibilityFallback = $false
        Reason = '当前 Codex 已接受 HTTPS-only provider。'
    }
}

function Remove-CodexHttpTransport {
    if (-not (Test-Path -LiteralPath $CodexConfigPath -PathType Leaf)) { return }
    $originalText = [IO.File]::ReadAllText($CodexConfigPath)
    $newText = Convert-CodexTransportConfigText -ExistingText $originalText -Action Remove
    Write-CodexConfigTextAtomically -Text $newText
    if (-not (Test-CodexConfigLoads)) {
        Write-CodexConfigTextAtomically -Text $originalText
        throw '移除 HTTPS-only provider 后 Codex 配置未通过解析，已恢复移除前状态。'
    }
}

function Get-CodexHttpTransportStatus {
    if (-not (Test-Path -LiteralPath $CodexConfigPath -PathType Leaf)) {
        return [pscustomobject]@{ Managed = $false; Selected = $false }
    }
    $text = [IO.File]::ReadAllText($CodexConfigPath)
    return [pscustomobject]@{
        Managed = $text.Contains($TransportSelectorStart) -and $text.Contains($TransportProviderStart)
        Selected = $text -match "(?m)^\s*model_provider\s*=\s*`"$([regex]::Escape($TransportProviderId))`"\s*$"
    }
}

function Resolve-CodexNetworkMode {
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

    try {
        $codexCommand = Get-Command codex -ErrorAction Stop
        $doctorOutput = (& $codexCommand.Source doctor --json --summary | Out-String)
        $doctor = $doctorOutput | ConvertFrom-Json
        $providerCheck = $doctor.checks.'network.provider_reachability'
        $websocketCheck = $doctor.checks.'network.websocket_reachability'
        if (-not $providerCheck -or -not $websocketCheck) {
            throw 'Codex doctor 未返回完整的网络检查。'
        }
        $providerStatus = [string](Get-OptionalObjectProperty -InputObject $providerCheck -Name 'status')
        $websocketStatus = [string](Get-OptionalObjectProperty -InputObject $websocketCheck -Name 'status')
        $websocketDetails = Get-OptionalObjectProperty -InputObject $websocketCheck -Name 'details'
        $responsesProbe = if ($providerStatus -eq 'ok') {
            [pscustomobject]@{ Healthy = $true; StatusCode = $null; DurationMs = $null; Error = $null }
        }
        else {
            Invoke-CodexResponsesEndpointProbe -ProxyUri $preparedProxyUri
        }
        $providerHealthy = $providerStatus -eq 'ok' -or $responsesProbe.Healthy
        return [pscustomobject]@{
            Available = $true
            Healthy = $providerHealthy -and $websocketStatus -eq 'ok'
            TransportHealthy = $providerHealthy
            ProviderHealthy = $providerHealthy
            WebSocketHealthy = $websocketStatus -eq 'ok'
            ProviderStatus = if ($providerHealthy) { 'ok' } else { $providerStatus }
            ProviderSummary = if ($providerStatus -eq 'ok') {
                Get-OptionalObjectProperty -InputObject $providerCheck -Name 'summary'
            }
            elseif ($responsesProbe.Healthy) {
                "doctor 根地址检查失败，但真实 Responses 路径已连通（HTTP $($responsesProbe.StatusCode)）。"
            }
            else {
                Get-OptionalObjectProperty -InputObject $providerCheck -Name 'summary'
            }
            ProviderDurationMs = if ($providerStatus -eq 'ok') {
                Get-OptionalObjectProperty -InputObject $providerCheck -Name 'durationMs'
            }
            else {
                $responsesProbe.DurationMs
            }
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
    $explicitSuppressed = ($healthState.SuppressExplicit -and -not $AllowEarlyRecovery) -or $ForceNative
    $recoveryProbe = ($healthState.HalfOpenEligible -or $AllowEarlyRecovery) -and -not $ForceNative

    if (-not $VerifyRemote) {
        # An open or half-open circuit may only recover through the stronger verified probe series.
        $useExplicit = $null -ne $explicitText -and $healthState.CircuitState -eq 'Closed' -and -not $ForceNative
        Write-CodexEnvTextAtomically -Text $(if ($useExplicit) { $explicitText } else { $nativeText })
        return [pscustomobject]@{
            NetworkMode = if ($useExplicit) { 'VpnExplicitHttps' } else { 'VpnNativeHttps' }
            Reason = if ($useExplicit) {
                '已同步当前显式 VPN 代理；HTTPS-only 传输避免 WebSocket 长流重连。'
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
    if ($null -ne $explicitText -and -not $explicitSuppressed) {
        Write-CodexEnvTextAtomically -Text $explicitText
        $explicitProbeCount = if ($recoveryProbe) { $RequiredRecoveryVpnProbes } else { $RequiredHealthyVpnProbes }
        $explicitSeries = Invoke-CodexDoctorProbeSeries -ProbeCount $explicitProbeCount -ProbeIntervalMilliseconds $VpnProbeIntervalMilliseconds
        $explicitMedian = Get-ProbeSeriesMedianProviderDuration -ProbeSeries $explicitSeries
        if ($explicitSeries.Stable) {
            $healthState = Register-VpnHealthSuccess
            return [pscustomobject]@{
                NetworkMode = 'VpnExplicitHttps'
                Reason = "显式 VPN HTTPS/SSE 路径连续 $explicitProbeCount 次通过，HTTP 中位耗时 $([Math]::Round($explicitMedian)) ms；运行期监测器会在连续故障时为新进程自动准备 VPN 原生路径。"
                ProxyUri = $explicitProxyCandidate.ProxyUri
                NetworkProbe = $explicitSeries.LastProbe
                RouteHealthy = $true
                ExplicitProxyMedianMs = $explicitMedian
                NativeMedianMs = $null
                CircuitState = $healthState.CircuitState
                CircuitFailures = $healthState.ConsecutiveFailures
                CircuitRetryAfterUtc = $healthState.RetryAfterUtc
                CircuitHalfOpen = $healthState.HalfOpenEligible
            }
        }
        $explicitFailure = "显式 VPN HTTPS/SSE 检查失败：$(Get-CodexDoctorProbeReason -Probe $explicitSeries.LastProbe)"
        if (-not ($AllowEarlyRecovery -and $healthState.CircuitState -eq 'Open')) {
            $healthState = Register-VpnHealthFailure -Reason $explicitFailure
        }
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
    if ($nativeSeries.Stable) {
        return [pscustomobject]@{
            NetworkMode = 'VpnNativeHttps'
            Reason = "$explicitFailure；VPN 原生 HTTPS/SSE 路径连续 $RequiredHealthyNativeProbes 次通过并已自动接管。"
            ProxyUri = $null
            NetworkProbe = $nativeSeries.LastProbe
            RouteHealthy = $true
            ExplicitProxyMedianMs = if ([double]::IsPositiveInfinity($explicitMedian)) { $null } else { $explicitMedian }
            NativeMedianMs = $nativeMedian
            CircuitState = $healthState.CircuitState
            CircuitFailures = $healthState.ConsecutiveFailures
            CircuitRetryAfterUtc = $healthState.RetryAfterUtc
            CircuitHalfOpen = $healthState.HalfOpenEligible
        }
    }

    return [pscustomobject]@{
        NetworkMode = 'VpnNativeHttps'
        Reason = "两条 VPN HTTPS/SSE 路径均未通过；已保留无强制代理键的 VPN 原生环境。显式路径：$explicitFailure；原生路径：$(Get-CodexDoctorProbeReason -Probe $nativeSeries.LastProbe)"
        ProxyUri = $null
        NetworkProbe = $nativeSeries.LastProbe
        RouteHealthy = $false
        ExplicitProxyMedianMs = if ([double]::IsPositiveInfinity($explicitMedian)) { $null } else { $explicitMedian }
        NativeMedianMs = $nativeMedian
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

function Get-CodexCoreRouteAssignments {
    param(
        [object[]]$CoreProcesses = @(),
        [Parameter(Mandatory = $true)]$HealthState,
        [Parameter(Mandatory = $true)][bool]$ExplicitRoutePrepared
    )

    $lastFailureUtc = $HealthState.LastFailureUtc
    $lastSuccessUtc = $HealthState.LastSuccessUtc
    return @(
        foreach ($process in @($CoreProcesses)) {
            $startedUtc = ([DateTime]$process.StartedUtc).ToUniversalTime()
            $route = 'Unknown'
            $reason = '无法从当前持久路由边界确定该核心的启动环境。'
            if ($ExplicitRoutePrepared) {
                $startedDuringNativeInterval = $HealthState.LastFailureKind -eq 'RuntimeStream' -and
                    $null -ne $lastFailureUtc -and $null -ne $lastSuccessUtc -and
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
    $shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $InstalledNetworkWatchdog +
        '" -Persistent -ProbeIntervalSeconds ' + $WatchdogProbeIntervalSeconds +
        ' -RuntimePollSeconds ' + $WatchdogRuntimePollSeconds
    $shortcut.WorkingDirectory = $InstallRoot
    $shortcut.IconLocation = $CodexExecutable + ',0'
    $shortcut.Description = '持续识别 Codex/Codex++ 重启并根据真实 HTTPS/SSE 长流错误切换 VPN 路径'
    $shortcut.Save()
}

function Start-CodexDesktopProcess {
    $codexExe = Get-CodexDesktopExecutable
    $debugPort = Get-AvailableLoopbackPort
    $arguments = @(
        '--remote-debugging-address=127.0.0.1'
        "--remote-debugging-port=$debugPort"
        "--remote-allow-origins=http://127.0.0.1:$debugPort"
    )
    $process = Start-Process -FilePath $codexExe -ArgumentList $arguments `
        -WorkingDirectory (Split-Path -Parent $codexExe) -PassThru
    return [pscustomobject]@{
        Process = $process
        DebugPort = $debugPort
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

function Start-CodexNetworkWatchdog {
    if (-not (Test-Path -LiteralPath $InstalledNetworkWatchdog -PathType Leaf)) {
        throw "运行期网络监测器未安装：$InstalledNetworkWatchdog"
    }
    $existing = @(Get-CodexNetworkWatchdogProcesses | Select-Object -First 1)
    if ($existing.Count -gt 0) {
        return Get-Process -Id ([int]$existing[0].ProcessId) -ErrorAction Stop
    }
    $powershellPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $InstalledNetworkWatchdog +
        '" -Persistent -ProbeIntervalSeconds ' + $WatchdogProbeIntervalSeconds +
        ' -RuntimePollSeconds ' + $WatchdogRuntimePollSeconds
    return Start-Process -FilePath $powershellPath -ArgumentList $arguments -WindowStyle Hidden -PassThru
}

function Stop-CodexNetworkWatchdog {
    foreach ($watchdogProcess in @(Get-CodexNetworkWatchdogProcesses)) {
        Stop-Process -Id ([int]$watchdogProcess.ProcessId) -Force -ErrorAction SilentlyContinue
    }
}

function Install-Hotpatch {
    $watchdogWasRunning = Test-CodexNetworkWatchdogRunning
    $snapshotPaths = @(
        $CodexConfigPath,
        $CodexEnvPath,
        $NetworkHealthPath,
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
    "NetworkMode: $($selection.NetworkMode)"
    "Reason: $($selection.Reason)"
    if ($selection.ProxyUri) { "Codex 专属 .env 已同步显式 VPN 代理：$($selection.ProxyUri.AbsoluteUri.TrimEnd('/'))" }
    else { 'Codex 专属 .env 已移除强制代理键；继续使用当前 VPN 的原生系统/TUN 路径。' }
    '未写入 Windows 用户级或系统级永久环境变量，也未修改 Codex 安装目录。'
}

function Uninstall-Hotpatch {
    Stop-CodexNetworkWatchdog
    foreach ($path in @($ShortcutPath, $SafeShortcutPath, $WatchdogStartupShortcutPath)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) { [IO.File]::Delete($path) }
    }
    Remove-ManagedCodexProxyEnv
    Remove-CodexHttpTransport
    '网络代理补丁已停用；两个开始菜单入口、登录自启守护、.env 托管区块和 HTTPS-only provider 已移除，原 model_provider 已恢复，已安装脚本保留以便审计。'
}

function Start-CodexWithProxy {
    if (Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue) {
        throw 'Codex 已在运行。请先从托盘完全退出 Codex，再使用“Codex（代理优化）”启动。'
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
    $watchdog = Start-CodexNetworkWatchdog
    "持续网络自愈守护 PID：$($watchdog.Id)"
}

function Start-CodexSafeFallback {
    if (Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue) {
        throw 'Codex 已在运行。请先从托盘完全退出 Codex，再使用“Codex（官方兼容兜底）”启动。'
    }

    Remove-CodexHttpTransport
    Remove-ManagedCodexProxyEnv
    Clear-CodexProxyEnvironment
    'CompatibilityMode: OfficialBuiltInVpnNative'
    '已在启动前移除本补丁的 provider 与代理托管块；使用当前 VPN 和 Codex 官方内置网络行为。'
    $launch = Start-CodexDesktopProcess
    "本地 DevTools 端口：$($launch.DebugPort)"
}

function Invoke-CodexDoctor {
    $transport = Install-CodexHttpTransport
    $selection = Sync-CodexProxyEnv -VerifyRemote -ForceNative:(-not $transport.Enabled)
    $probe = $selection.NetworkProbe
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
        DoctorOverallStatus = $probe.DoctorOverallStatus
        RouteHealthy = $selection.RouteHealthy
        ExplicitProxyMedianMs = $selection.ExplicitProxyMedianMs
        NativeMedianMs = $selection.NativeMedianMs
        CircuitState = $selection.CircuitState
        CircuitFailures = $selection.CircuitFailures
        CircuitRetryAfterUtc = $selection.CircuitRetryAfterUtc
        Note = '两条路径均使用 HTTPS/SSE；doctor 根地址失败时会以无凭据的真实 Responses 路径响应作为连通兜底，避免把可用传输误判为离线。真实长流错误仍会立即熔断显式路径。doctor 总状态可能被非网络终端检查影响。'
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
    $runtimeCursorStatus = Get-CodexRuntimeNetworkCursorStatus -CursorPath $NetworkRuntimeCursorPath
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
        -HealthState $healthState -ExplicitRoutePrepared:($preparedMode -eq 'VpnExplicitHttps'))
    $nativeCoreProcessIds = @($routeAssignments | Where-Object Route -eq 'VpnNativeHttps' | ForEach-Object ProcessId)
    $recentNative = if ($nativeCoreProcessIds.Count -gt 0) {
        Get-CodexRecentRuntimeNetworkEvents -DatabasePath $CodexRuntimeLogsPath `
            -ActiveProcessIds $nativeCoreProcessIds -ExpectedMaxRetries $TransportStreamMaxRetries `
            -FailureWindow $NativeRuntimeFailureWindow
    }
    else {
        [pscustomobject]@{ Available = $true; Error = $null; Events = @() }
    }
    $nativeDegradation = Get-CodexRuntimeNetworkDegradation -Events @($recentNative.Events) `
        -FailureThreshold $NativeRuntimeFailureThreshold -FailureWindow $NativeRuntimeFailureWindow
    $currentCoreRoutes = @($routeAssignments | Select-Object -ExpandProperty Route -Unique)
    $preparedRouteRequiresRestart = @($routeAssignments | Where-Object Route -ne 'Unknown' | Where-Object Route -ne $preparedMode).Count -gt 0

    [pscustomobject]@{
        PatchVersion = $PatchVersion
        DesktopPackageVersion = if ($desktopCompatibility.Version) { $desktopCompatibility.Version.ToString() } else { $null }
        ValidatedDesktopPackageVersion = $ValidatedDesktopPackageVersion.ToString()
        DesktopMajorCompatible = $desktopCompatibility.Compatible
        NetworkMode = $preparedMode
        Reason = if ($preparedMode -eq 'VpnNativeHttps') {
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
        CodexConfigPath = $CodexConfigPath
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
        LastNativeRuntimeFailureUtc = $nativeDegradation.LastFailureUtc
        LastNativeRuntimeFailureReason = $nativeDegradation.LastFailureReason
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
