[CmdletBinding()]
param(
    [ValidateRange(1, 10)]
    [int]$Iterations = 3,

    [ValidateSet('ExplicitHttpsAll', 'ExplicitHttpsMinimal', 'NativeHttps', 'NativeHttpsSystemProxy', 'ExplicitWebSocket', 'NativeWebSocket')]
    [string[]]$Candidates = @('ExplicitHttpsAll', 'ExplicitHttpsMinimal', 'NativeHttps', 'NativeHttpsSystemProxy'),

    [ValidateSet('Minimal', 'Subagent')]
    [string]$Workload = 'Minimal',

    [string]$Model = 'gpt-5.6-luna'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'manage-hotpatch.ps1')

function Get-ExplicitMinimalEnvText {
    param(
        [AllowEmptyString()][string]$ExistingText,
        [Parameter(Mandatory = $true)][string]$ProxyValue
    )

    $nativeText = Convert-CodexProxyEnvText -ExistingText $ExistingText -NetworkMode OfficialDirect
    $lines = New-Object 'System.Collections.Generic.List[string]'
    if (-not [string]::IsNullOrWhiteSpace($nativeText)) {
        foreach ($line in @($nativeText.TrimEnd("`r", "`n") -split "`r?`n")) { $lines.Add($line) }
        $lines.Add('')
    }
    $lines.Add($EnvBlockStart)
    $lines.Add("HTTP_PROXY=$ProxyValue")
    $lines.Add("HTTPS_PROXY=$ProxyValue")
    $lines.Add("NO_PROXY=$NoProxyValue")
    $lines.Add($EnvBlockEnd)
    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function Get-MedianValue {
    param([double[]]$Values)
    if ($Values.Count -eq 0) { return $null }
    $sorted = @($Values | Sort-Object)
    $middle = [Math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2 -eq 1) { return [double]$sorted[$middle] }
    return ([double]$sorted[$middle - 1] + [double]$sorted[$middle]) / 2
}

function Get-PercentileValue {
    param([double[]]$Values, [double]$Percentile)
    if ($Values.Count -eq 0) { return $null }
    $sorted = @($Values | Sort-Object)
    $index = [Math]::Ceiling(($Percentile / 100) * $sorted.Count) - 1
    $index = [Math]::Max(0, [Math]::Min($sorted.Count - 1, $index))
    return [double]$sorted[$index]
}

function Invoke-CandidateRun {
    param(
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)][int]$Iteration,
        [Parameter(Mandatory = $true)][string]$OriginalEnvText,
        [Parameter(Mandatory = $true)][string]$ProxyValue,
        [Parameter(Mandatory = $true)][string]$Prompt
    )

    $usesExplicitProxy = $Candidate -like 'Explicit*'
    $usesHttpsOnly = $Candidate -like '*Https*'
    $usesMinimalProxy = $Candidate -eq 'ExplicitHttpsMinimal'
    $usesSystemProxyFeature = $Candidate -eq 'NativeHttpsSystemProxy'

    $envText = if ($usesExplicitProxy) {
        if ($usesMinimalProxy) {
            Get-ExplicitMinimalEnvText -ExistingText $OriginalEnvText -ProxyValue $ProxyValue
        }
        else {
            Convert-CodexProxyEnvText -ExistingText $OriginalEnvText -NetworkMode VpnProxy -ProxyValue $ProxyValue
        }
    }
    else {
        Convert-CodexProxyEnvText -ExistingText $OriginalEnvText -NetworkMode OfficialDirect
    }
    Write-CodexEnvTextAtomically -Text $envText
    Clear-CodexProxyEnvironment

    $arguments = New-Object 'System.Collections.Generic.List[string]'
    foreach ($argument in @(
        'exec', '--ephemeral', '--ignore-user-config', '--ignore-rules', '--skip-git-repo-check',
        '--sandbox', 'read-only', '--json', '-m', $Model
    )) {
        $arguments.Add($argument)
    }
    if ($usesHttpsOnly) {
        $arguments.Add('-c')
        $arguments.Add('model_provider="hotpatch-http"')
        $arguments.Add('-c')
        $arguments.Add('model_providers.hotpatch-http={ name="OpenAI HTTP", wire_api="responses", requires_openai_auth=true, supports_websockets=false, supports_standalone_web_search=true }')
    }
    if ($usesSystemProxyFeature) {
        $arguments.Add('--enable')
        $arguments.Add('respect_system_proxy')
    }
    $arguments.Add($Prompt)

    $lines = New-Object 'System.Collections.Generic.List[string]'
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $firstOutputMs = $null
    $codexCommand = (Get-Command codex -ErrorAction Stop).Source
    $argumentArray = [string[]]$arguments.ToArray()
    & $codexCommand @argumentArray 2>&1 | ForEach-Object {
        if ($null -eq $firstOutputMs) { $firstOutputMs = $stopwatch.ElapsedMilliseconds }
        $lines.Add($_.ToString())
    }
    $exitCode = $LASTEXITCODE
    $stopwatch.Stop()
    $joined = $lines -join "`n"

    return [pscustomobject]@{
        Candidate = $Candidate
        Workload = $Workload
        Iteration = $Iteration
        ExitCode = $exitCode
        FirstOutputMs = $firstOutputMs
        TotalMs = $stopwatch.ElapsedMilliseconds
        ReconnectSignals = ([regex]::Matches($joined, '(?i)reconnect|stream disconnected|falling back')).Count
        TransportErrors = ([regex]::Matches($joined, '(?i)websocket closed|error sending request|request timed out|error decoding response body')).Count
        SpawnObserved = $joined -match '(?i)spawn_agent|subagent|collaboration'
        Completed = $joined -match 'turn.completed|task_complete|"type":"item.completed"'
        ErrorHint = if ($exitCode -ne 0 -and $lines.Count -gt 0) { $lines[0].Substring(0, [Math]::Min(200, $lines[0].Length)) } else { $null }
    }
}

$proxyUri = Get-WinInetProxyUri
if (-not (Test-ProxyListener -ProxyUri $proxyUri)) {
    throw "当前 VPN 显式代理监听不可连接：$($proxyUri.Host):$($proxyUri.Port)"
}
$proxyValue = $proxyUri.AbsoluteUri.TrimEnd('/')
$originalExists = Test-Path -LiteralPath $CodexEnvPath -PathType Leaf
$originalText = if ($originalExists) { [IO.File]::ReadAllText($CodexEnvPath) } else { '' }
$originalHash = if ($originalExists) { (Get-FileHash -LiteralPath $CodexEnvPath -Algorithm SHA256).Hash } else { $null }
$prompt = if ($Workload -eq 'Subagent') {
    'Use exactly one subagent to return the word OK. Wait for it, then reply with exactly OK. Do not use shell or filesystem tools.'
}
else {
    'Reply with exactly OK. Do not use tools.'
}

$results = New-Object 'System.Collections.Generic.List[object]'
try {
    for ($iteration = 1; $iteration -le $Iterations; $iteration++) {
        $orderedCandidates = @($Candidates)
        if ($iteration % 2 -eq 0) { [array]::Reverse($orderedCandidates) }
        foreach ($candidate in $orderedCandidates) {
            $results.Add((Invoke-CandidateRun -Candidate $candidate -Iteration $iteration `
                -OriginalEnvText $originalText -ProxyValue $proxyValue -Prompt $prompt))
        }
    }
}
finally {
    if ($originalExists) {
        Write-CodexEnvTextAtomically -Text $originalText
    }
    elseif (Test-Path -LiteralPath $CodexEnvPath -PathType Leaf) {
        [IO.File]::Delete($CodexEnvPath)
    }
}

$summary = New-Object 'System.Collections.Generic.List[object]'
foreach ($candidate in $Candidates) {
    $candidateResults = @($results | Where-Object Candidate -eq $candidate)
    $completedResults = @($candidateResults | Where-Object {
        $_.ExitCode -eq 0 -and $_.Completed -and ($Workload -ne 'Subagent' -or $_.SpawnObserved)
    })
    $durations = [double[]]@($completedResults | ForEach-Object TotalMs)
    $summary.Add([pscustomobject]@{
        Candidate = $candidate
        Runs = $candidateResults.Count
        SuccessfulRuns = $completedResults.Count
        SuccessRate = if ($candidateResults.Count -gt 0) { [Math]::Round(100 * $completedResults.Count / $candidateResults.Count, 1) } else { 0 }
        MedianMs = Get-MedianValue -Values $durations
        P95Ms = Get-PercentileValue -Values $durations -Percentile 95
        ReconnectSignals = (@($candidateResults | Measure-Object -Property ReconnectSignals -Sum).Sum)
        TransportErrors = (@($candidateResults | Measure-Object -Property TransportErrors -Sum).Sum)
    })
}
$eligible = @($summary | Where-Object { $_.SuccessRate -eq 100 -and $_.ReconnectSignals -eq 0 -and $_.TransportErrors -eq 0 -and $null -ne $_.MedianMs })
$winner = $eligible | Sort-Object MedianMs | Select-Object -First 1
$restored = if ($originalExists) {
    (Get-FileHash -LiteralPath $CodexEnvPath -Algorithm SHA256).Hash -eq $originalHash
}
else {
    -not (Test-Path -LiteralPath $CodexEnvPath -PathType Leaf)
}

[pscustomobject]@{
    Model = $Model
    Workload = $Workload
    Iterations = $Iterations
    Proxy = $proxyValue
    Results = @($results.ToArray())
    Summary = @($summary.ToArray())
    Winner = if ($winner) { $winner.Candidate } else { $null }
    EnvRestored = $restored
} | ConvertTo-Json -Depth 6
