$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'network-health.psm1') -Force

function Assert-True {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Actual, $Expected, [Parameter(Mandatory = $true)][string]$Message)
    if ($Actual -ne $Expected) { throw "$Message Expected=[$Expected] Actual=[$Actual]" }
}

$statePath = Join-Path ([IO.Path]::GetTempPath()) ("codex-network-circuit-test-$PID.json")
$start = [DateTimeOffset]::Parse('2026-08-16T10:00:00Z').UtcDateTime
try {
    $preciseTime = [DateTimeOffset]::Parse('2026-09-04T08:09:54.6731003Z').UtcDateTime
    Update-CodexNetworkCircuitState -Path $statePath -Outcome Success -NowUtc $preciseTime | Out-Null
    $preciseState = Get-CodexNetworkCircuitState -Path $statePath -NowUtc $preciseTime
    Assert-Equal $preciseState.LastSuccessUtc.Ticks $preciseTime.Ticks 'JSON 读取不得丢失用于核心归属判断的亚秒时间。'
    [IO.File]::Delete($statePath)
    $initial = Get-CodexNetworkCircuitState -Path $statePath -NowUtc $start
    Assert-Equal $initial.CircuitState 'Closed' '缺省状态必须关闭熔断器。'
    Assert-Equal $initial.ConsecutiveFailures 0 '缺省状态不得包含失败次数。'

    $first = Update-CodexNetworkCircuitState -Path $statePath -Outcome Failure -Reason 'first failure' `
        -NowUtc $start -FailureThreshold 2 -FailureWindow ([TimeSpan]::FromMinutes(10)) -OpenCooldown ([TimeSpan]::FromMinutes(30))
    Assert-Equal $first.CircuitState 'Closed' '单次失败不得立即锁死显式 VPN。'
    Assert-Equal $first.ConsecutiveFailures 1 '首次失败必须被持久记录。'

    $secondTime = $start.AddMinutes(1)
    $second = Update-CodexNetworkCircuitState -Path $statePath -Outcome Failure -Reason 'second failure' `
        -NowUtc $secondTime -FailureThreshold 2 -FailureWindow ([TimeSpan]::FromMinutes(10)) -OpenCooldown ([TimeSpan]::FromMinutes(30))
    Assert-Equal $second.CircuitState 'Open' '窗口内连续两次失败必须打开熔断器。'
    Assert-True $second.SuppressExplicit '冷却期内必须跳过显式 VPN。'
    Assert-Equal $second.RetryAfterUtc $secondTime.AddMinutes(30) '熔断恢复时间必须使用固定冷却期。'

    $cooling = Get-CodexNetworkCircuitState -Path $statePath -NowUtc $secondTime.AddMinutes(5)
    Assert-True $cooling.SuppressExplicit '重启读取状态后仍必须保持熔断，不能回到进行中。'
    $halfOpen = Get-CodexNetworkCircuitState -Path $statePath -NowUtc $secondTime.AddMinutes(31)
    Assert-True $halfOpen.HalfOpenEligible '冷却到期后必须进入可恢复探测状态。'
    Assert-True (-not $halfOpen.SuppressExplicit) '冷却到期后不得永久跳过恢复探测。'

    $recovered = Update-CodexNetworkCircuitState -Path $statePath -Outcome Success -NowUtc $secondTime.AddMinutes(31)
    Assert-Equal $recovered.CircuitState 'Closed' '强恢复成功必须关闭熔断器。'
    Assert-Equal $recovered.ConsecutiveFailures 0 '恢复后必须清零连续失败。'
    Assert-True ($null -ne $recovered.LastSuccessUtc) '恢复时间必须持久化。'

    [IO.File]::WriteAllText($statePath, '{"Version":1,"LastVpnFailureUtc":"2026-08-16T09:00:00Z","LastVpnFailureReason":"legacy"}', [Text.UTF8Encoding]::new($false))
    $legacy = Get-CodexNetworkCircuitState -Path $statePath -NowUtc $start
    Assert-Equal $legacy.CircuitState 'Closed' '旧版单次失败状态必须兼容迁移为关闭状态。'
    Assert-Equal $legacy.ConsecutiveFailures 1 '旧版失败记录必须保留为一次失败。'
    Assert-Equal $legacy.LastFailureReason 'legacy' '旧版失败原因必须保留。'

    [IO.File]::WriteAllText($statePath, '{broken-json', [Text.UTF8Encoding]::new($false))
    $corrupt = Get-CodexNetworkCircuitState -Path $statePath -NowUtc $start
    Assert-True $corrupt.IsCorrupt '损坏状态必须显式报告。'
    Assert-True $corrupt.SuppressExplicit '损坏状态必须 fail-safe 跳过显式 VPN。'
    $repaired = Update-CodexNetworkCircuitState -Path $statePath -Outcome Failure -Reason 'repair corrupt state' `
        -NowUtc $start -FailureThreshold 2 -FailureWindow ([TimeSpan]::FromMinutes(10)) -OpenCooldown ([TimeSpan]::FromMinutes(30))
    Assert-Equal $repaired.CircuitState 'Open' '损坏状态必须被修复为有冷却期的持久熔断状态。'
    Assert-True (-not $repaired.IsCorrupt) '修复后的状态必须可解析。'

    if (Test-Path -LiteralPath $statePath -PathType Leaf) { [IO.File]::Delete($statePath) }
    $outsideWindowFirst = Update-CodexNetworkCircuitState -Path $statePath -Outcome Failure -Reason 'old' `
        -NowUtc $start -FailureThreshold 2 -FailureWindow ([TimeSpan]::FromMinutes(10)) -OpenCooldown ([TimeSpan]::FromMinutes(30))
    $outsideWindow = Update-CodexNetworkCircuitState -Path $statePath -Outcome Failure -Reason 'new' `
        -NowUtc $start.AddMinutes(11) -FailureThreshold 2 -FailureWindow ([TimeSpan]::FromMinutes(10)) -OpenCooldown ([TimeSpan]::FromMinutes(30))
    Assert-Equal $outsideWindow.CircuitState 'Closed' '失败窗口外的新故障必须重新计数。'
    Assert-Equal $outsideWindow.ConsecutiveFailures 1 '失败窗口外计数必须重置为一。'

    [IO.File]::WriteAllText($statePath, (@{
        Version = 2
        CircuitState = 'Closed'
        ConsecutiveFailures = 0
        WindowStartedUtc = $null
        LastFailureUtc = $null
        LastFailureReason = $null
        RetryAfterUtc = $null
        LastSuccessUtc = $start.ToString('o')
    } | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    $versionTwo = Get-CodexNetworkCircuitState -Path $statePath -NowUtc $start
    Assert-Equal $versionTwo.Version 3 '版本 2 健康状态必须无损迁移到当前结构。'
    Assert-Equal $versionTwo.RuntimeFailureCount 0 '旧状态不得伪造运行期长流故障。'

    if (Test-Path -LiteralPath $statePath -PathType Leaf) { [IO.File]::Delete($statePath) }
    $runtimeFirst = Update-CodexNetworkCircuitState -Path $statePath -Outcome Failure `
        -FailureKind RuntimeStream -Reason 'response body truncated' -FailureThreshold 1 `
        -OpenCooldown ([TimeSpan]::FromHours(24)) -RuntimeFailureMaxCooldown ([TimeSpan]::FromDays(7)) -NowUtc $start
    Assert-Equal $runtimeFirst.CircuitState 'Open' '一次真实长流故障必须立即熔断，不能等待短探测重复失败。'
    Assert-Equal $runtimeFirst.LastFailureKind 'RuntimeStream' '长流故障类型必须持久化。'
    Assert-Equal $runtimeFirst.RuntimeFailureCount 1 '首次长流故障必须计入自适应退避历史。'
    Assert-Equal $runtimeFirst.RetryAfterUtc $start.AddHours(24) '首次长流故障必须至少隔离显式代理 24 小时。'

    $runtimeRecovered = Update-CodexNetworkCircuitState -Path $statePath -Outcome Success -NowUtc $start.AddHours(24)
    Assert-Equal $runtimeRecovered.CircuitState 'Closed' '冷却后验证成功必须允许恢复显式路径。'
    Assert-Equal $runtimeRecovered.RuntimeFailureCount 1 '短验证成功不得擦除长期故障历史。'
    $runtimeSecondTime = $start.AddHours(25)
    $runtimeSecond = Update-CodexNetworkCircuitState -Path $statePath -Outcome Failure `
        -FailureKind RuntimeStream -Reason 'response body truncated again' -FailureThreshold 1 `
        -OpenCooldown ([TimeSpan]::FromHours(24)) -RuntimeFailureMaxCooldown ([TimeSpan]::FromDays(7)) -NowUtc $runtimeSecondTime
    Assert-Equal $runtimeSecond.RuntimeFailureCount 2 '七天内复发必须升级退避级别。'
    Assert-Equal $runtimeSecond.RetryAfterUtc $runtimeSecondTime.AddHours(48) '第二次复发必须把隔离期指数提高到 48 小时。'
}
finally {
    if (Test-Path -LiteralPath $statePath -PathType Leaf) { [IO.File]::Delete($statePath) }
}

'network-health tests: PASS'
